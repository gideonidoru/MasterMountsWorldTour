-- Master Mounts rare alert: tells you when a mount-dropping rare is ACTUALLY
-- UP near you.
--
-- Both competitors detect rares by comparing UnitName on your target or
-- nameplates, which only fires for a rare you already found and only for the
-- one you are actively hunting. Vignettes are the minimap/world markers the
-- game itself puts up for live rares, so reading them tells us a rare is up
-- before the player sees anything.
local _, MM = ...
local U = MM.Util

MM.RareAlert = {}
local RA = MM.RareAlert

-- Declared up here on purpose. RA.Test is defined above buildAlert, so a
-- `local alertFrame` further down would be a DIFFERENT variable -- Test would
-- close over a nil global and report "it did not show" about a frame that was
-- on screen the whole time. The diagnostic has to see the same frame.
local alertFrame

-- Alert sounds, in menu order -- built from SOUNDKIT at load, filtered to what
-- this client actually has.
--
-- The previous list used "Sound\\Doodad\\...ogg" paths. Retail dropped loose
-- path lookups for game audio years ago -- PlaySoundFile needs a FileDataID --
-- so every one of those silently returned willPlay=false and the code fell
-- through to the same fallback every time. Six choices, one sound.
--
-- Guessing FileDataIDs would repeat the mistake in a form that is harder to
-- see. SOUNDKIT is a table the client publishes, so we can ASK which names
-- exist and offer only those. A menu built this way cannot list a sound that
-- will not play.
local SOUND_CANDIDATES = {
	{ key = "horn",    label = "War Horn",     kits = { "UI_HORDE_WAR_HORN", "UI_ALLIANCE_WAR_HORN",
	                                                   "PVPTHROUGHQUEUE", "UI_PVP_QUEUE_POP" } },
	-- A rare alert competes with combat, music and whatever else is on screen.
	-- Polite UI chimes lose that fight, so the list favours sounds that are
	-- deliberately hard to ignore over ones that are pleasant.
	{ key = "queue",   label = "Queue Pop",    kits = { "PVPTHROUGHQUEUE", "UI_PVP_QUEUE_POP",
	                                                   "UI_BATTLEGROUND_COUNTDOWN_FINISHED" } },
	{ key = "flare",   label = "Air Horn",     kits = { "UI_BATTLEGROUND_COUNTDOWN_TIMER",
	                                                   "UI_SCENARIO_START", "IG_QUEST_FAILED" } },
	{ key = "raid",    label = "Raid Warning", kits = { "RAID_WARNING" } },
	{ key = "ready",   label = "Ready Check",  kits = { "READY_CHECK", "IG_PLAYER_INVITE" } },
	{ key = "alarm",   label = "Alarm Clock",  kits = { "ALARM_CLOCK_WARNING_3", "ALARM_CLOCK_WARNING_2",
	                                                   "ALARM_CLOCK_WARNING_1" } },
	{ key = "whisper", label = "Whisper Ping", kits = { "TELL_MESSAGE", "IG_PLAYER_INVITE" } },
}

RA.SOUNDS = {}
do
	for _, c in ipairs(SOUND_CANDIDATES) do
		local id
		for _, name in ipairs(c.kits) do
			if SOUNDKIT and SOUNDKIT[name] then id = SOUNDKIT[name] break end
		end
		if id then
			RA.SOUNDS[#RA.SOUNDS + 1] = { key = c.key, label = c.label, id = id }
		end
	end
	-- Never leave the menu empty: RAID_WARNING's literal id is stable enough to
	-- stand in if SOUNDKIT itself is unavailable.
	if #RA.SOUNDS == 0 then
		RA.SOUNDS[1] = { key = "raid", label = "Raid Warning", id = 8959 }
	end
	-- A SHIPPED FILE, WHICH IS WHY IT NEEDS NO KIT.
	--
	-- The murloc stayed out of the list for a long time because SOUNDKIT
	-- publishes no MURLOC_* entry and the game's own cry exists only as a raw
	-- FileDataID -- guessing one is what produced six menu entries that all
	-- played the same fallback. None of that applies to a file in the addon
	-- folder: PlaySoundFile takes a PATH, and the FileDataID requirement is on
	-- the game's own assets.
	--
	-- The file is mastered for the job rather than used as found: leading
	-- silence removed so the cry lands the instant the alert fires, and levels
	-- evened out so the quiet half is as audible as the loud half. A third of a
	-- second of dead air at the front of an alert is a third of a second the
	-- player spends not knowing.
	--
	-- FIRST IN THE LIST, because first is the default: RA.PlaySound falls back
	-- to SOUNDS[1] and the options menu reads the same slot.
	tinsert(RA.SOUNDS, 1, {
		key = "murloc", label = "Murloc",
		file = "Interface\\AddOns\\MasterMountsWorldTour\\Media\\murloc.mp3",
	})
end

-- Add a sound by raw FileDataID. Sounds the client has but SOUNDKIT does not
-- name -- the murloc cry among them -- are only reachable this way. Kept as an
-- explicit call rather than a guessed table entry so an id enters the list only
-- once someone has actually heard it play.
function RA.AddSoundByID(key, label, fileDataID)
	for _, s in ipairs(RA.SOUNDS) do
		if s.key == key then s.label, s.id = label, fileDataID return end
	end
	RA.SOUNDS[#RA.SOUNDS + 1] = { key = key, label = label, id = fileDataID }
end

------------------------------------------------------------
-- Making the alert audible regardless of the sound settings
------------------------------------------------------------
-- The Master channel escapes the SFX slider, and that is as far as a channel
-- can get you. Three settings sit BELOW it and silence everything:
--
--   Sound_EnableAllSound              sound switched off entirely
--   Sound_MasterVolume                the master slider, including 0
--   Sound_EnableSoundWhenGameIsInBG   alt-tabbed, which is exactly when an
--                                     audible alert is worth the most
--
-- So the alert raises those three for the length of the clip and puts them
-- back. Nothing else is touched: music, ambience and dialogue keep whatever
-- the player chose, and the SFX slider is not involved because the Master
-- channel never asked it.
local FORCED = { "Sound_EnableAllSound", "Sound_MasterVolume", "Sound_EnableSoundWhenGameIsInBG" }
local FORCE_TO = {
	Sound_EnableAllSound = "1",
	Sound_MasterVolume = "1",
	Sound_EnableSoundWhenGameIsInBG = "1",
}

-- Longest clip in the list, plus margin. Restoring early cuts the alert off
-- mid-cry, which is worse than holding the volume up a moment too long.
local FORCE_SECONDS = 3

local restoreTimer

-- THE SAVED VALUES LIVE IN SAVEDVARIABLES, NOT IN A LOCAL.
--
-- Raising someone's master volume and then losing the original because the
-- client crashed, or they alt-F4'd, or a UI error stopped the timer, would
-- leave the game permanently loud with no clue why. Written to disk before the
-- change and cleared after it, the next login can always finish the job.
local function restoreSound()
	restoreTimer = nil
	local saved = MM.db and MM.db.rareAlertCVarRestore
	if not saved then return end
	for _, cv in ipairs(FORCED) do
		if saved[cv] ~= nil then pcall(SetCVar, cv, saved[cv]) end
	end
	MM.db.rareAlertCVarRestore = nil
end
RA.RestoreSound = restoreSound

-- Returns true if anything was actually changed.
local function forceAudible()
	if not (GetCVar and SetCVar) then return false end
	-- Already forced by an alert that has not finished: keep the ORIGINAL
	-- values and just push the restore further out. Re-reading now would
	-- capture our own forced settings and make them permanent.
	if MM.db.rareAlertCVarRestore then
		if restoreTimer then restoreTimer:Cancel() end
		restoreTimer = C_Timer.NewTimer(FORCE_SECONDS, restoreSound)
		return true
	end
	local saved, changed = {}, false
	for _, cv in ipairs(FORCED) do
		local ok, cur = pcall(GetCVar, cv)
		if ok and cur ~= nil and cur ~= FORCE_TO[cv] then
			saved[cv] = cur
			changed = true
		end
	end
	if not changed then return false end
	MM.db.rareAlertCVarRestore = saved
	for cv in pairs(saved) do pcall(SetCVar, cv, FORCE_TO[cv]) end
	restoreTimer = C_Timer.NewTimer(FORCE_SECONDS, restoreSound)
	return true
end
RA.ForceAudible = forceAudible

-- Anything left forced by a session that ended mid-alert gets put back before
-- the player notices. Deliberately at login rather than on the next alert:
-- waiting for another rare could be days.
MM:On("MM_LOGIN", function()
	if MM.db and MM.db.rareAlertCVarRestore then restoreSound() end
end)

-- Play one entry. Returns the label that actually played, or nil if nothing did.
--
-- The return value is checked rather than pcall alone: PlaySound answers
-- willPlay=false for something the client cannot play, which is not an error,
-- so pcall would report success over silence.
function RA.PlaySound(key)
	local chosen
	for _, s in ipairs(RA.SOUNDS) do if s.key == key then chosen = s break end end
	chosen = chosen or RA.SOUNDS[1]
	if not chosen then return nil end
	-- Before the play call, never after: the channel volume is read when the
	-- sound starts, so raising it a frame later changes nothing.
	if MM.db.rareAlertForceAudible ~= false then forceAudible() end
	-- A shipped FILE plays by path; a game sound plays by id. Two different
	-- calls, and using the wrong one on either is silent rather than an error,
	-- which is how this went unnoticed the last time.
	if chosen.file then
		local ok, willPlay = pcall(PlaySoundFile, chosen.file, "Master")
		if ok and willPlay ~= false then return chosen.label end
		-- A file that will not play must not leave the alert mute. Fall through
		-- to the next entry, which is a kit sound the client published.
		local backup = RA.SOUNDS[2]
		if backup and backup.id then
			local ok2, w2 = pcall(PlaySound, backup.id, "Master")
			if ok2 and w2 ~= false then return backup.label end
		end
		return nil
	end
	local ok, willPlay = pcall(PlaySound, chosen.id, "Master")
	if ok and willPlay ~= false then return chosen.label end
	return nil
end

RA.seen = {}          -- [vignetteGUID] = timestamp, so we alert once per spawn
local ALERT_COOLDOWN = 600  -- per-rare re-alert floor, seconds
local lastAlertAt = {}

------------------------------------------------------------
-- Index of rare names we still need, built from the mount DB
------------------------------------------------------------
RA.wanted = {}      -- [lowercased npc name] = { entry = , rec = }
RA.wantedByID = {}  -- [creatureID]          = same table

-- The creature id a record's npc resolves to: its own field first, then the
-- client-resolved tables the ID resolver built.
local function npcIDFor(name, rec)
	if rec and rec.npc and rec.npc.id then return rec.npc.id end
	if not name then return nil end
	local key = name:lower()
	local resolved = MM.ResolvedIDs and MM.ResolvedIDs.npcs and MM.ResolvedIDs.npcs[key]
	if resolved then return resolved end
	local live = MM.db and MM.db.ids and MM.db.ids.npcs and MM.db.ids.npcs[key]
	return live
end

function RA.RebuildIndex()
	wipe(RA.wanted)
	wipe(RA.wantedByID)
	if not MM.Scanner.ready then return end

	local function want(name, hit)
		if not name then return end
		RA.wanted[name:lower()] = hit
		-- Matching on the creature id is exact and locale-proof; names differ
		-- on every non-English client and can collide.
		local id = npcIDFor(name, hit.rec)
		if id then RA.wantedByID[id] = hit end
	end

	-- Prewarm the creature models we might have to draw.
	--
	-- The retry above copes with a cold cache, but the FIRST alert is the one
	-- that matters and it is the most likely to be cold. Asking for each model
	-- once, quietly, means the client has usually cached it before a rare ever
	-- appears.
	--
	-- Deliberately slow and hidden: two per second through an off-screen frame.
	-- Requesting hundreds of models at once would hitch, which would be a worse
	-- bug than the blank portrait this is preventing. It also runs ONCE -- the
	-- cache persists for the session, so re-warming on every rescan is wasted
	-- work.
	if not RA.prewarmed then
		RA.prewarmed = true
		C_Timer.After(5, function()          -- let login settle first
			local warmer = CreateFrame("PlayerModel", nil, UIParent)
			warmer:SetSize(1, 1)
			warmer:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -500, 500)
			warmer:Hide()
			local ids, n = {}, 0
			for id in pairs(RA.wantedByID) do n = n + 1; ids[n] = id end
			local i = 0
			local ticker
			ticker = C_Timer.NewTicker(0.5, function()
				for _ = 1, 2 do
					i = i + 1
					if i > n then
						ticker:Cancel()
						warmer:Hide()
						return
					end
					pcall(function() warmer:SetCreature(ids[i]) end)
				end
			end)
		end)
	end

	for _, entry in ipairs(MM.Scanner.mounts) do
		local rec = entry.rec
		if not entry.collected and rec and rec.obtainable ~= false
			and MM.Scanner:FactionOk(entry) then
			if rec.npc and rec.npc.name then
				want(rec.npc.name, { entry = entry, rec = rec })
			end
			-- zone-wide pools: any rare in the zone can drop it
			if rec.sharedZonePool and rec.poolRares then
				for _, npcName in ipairs(rec.poolRares) do
					want(npcName, { entry = entry, rec = rec, pooled = true })
				end
			end
		end
	end
end

-- A preview of the real alert, driven by real data.
--
-- We prefer a rare the player is actually still hunting, so the preview shows
-- exactly what they will get in the field. If the index is empty -- everything
-- collected, or the scan has not run yet -- fall back to any rare-drop mount in
-- the database rather than inventing a fake NPC, which would preview a thing
-- that cannot happen.
function RA.Test()
	local npcName, hit, from

	for _, h in pairs(RA.wanted) do
		-- the index is keyed by lowercased name; take the display name off the record
		if h.rec and h.rec.npc and h.rec.npc.name then
			npcName, hit, from = h.rec.npc.name, h, "your wanted list"
			break
		end
	end

	if not hit and MM.Scanner and MM.Scanner.mounts then
		for _, entry in ipairs(MM.Scanner.mounts) do
			local rec = entry.rec
			if rec and rec.npc and rec.npc.name then
				npcName, hit, from = rec.npc.name, { entry = entry, rec = rec }, "the database"
				break
			end
		end
	end

	-- Say why nothing happened, in terms of what was actually checked. A preview
	-- that silently does nothing is indistinguishable from a broken button, and
	-- the two have completely different fixes.
	if not hit then
		MM:Print("Rare preview: nothing to show. wanted=%d, scanner=%s, scanned=%s.",
			(function() local n = 0 for _ in pairs(RA.wanted) do n = n + 1 end return n end)(),
			MM.Scanner and MM.Scanner.mounts and tostring(#MM.Scanner.mounts) or "nil",
			MM.Scanner and tostring(MM.Scanner.ready) or "nil")
		return
	end

	-- Feed the preview a real position so the off-plan arrow actually appears.
	-- Passing nil meant `pointAt` was never set, so the one thing the preview
	-- exists to demonstrate was the one thing it could not show.
	local rec = hit.rec
	local z = rec and (rec.zone or (rec.spawns and rec.spawns[1]))
	local mapPos
	if z and z.x and z.y then
		mapPos = { x = z.x / 100, y = z.y / 100 }
	else
		local m = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
		local p = m and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(m, "player")
		if p then mapPos = { x = p.x, y = p.y } end
	end

	RA.previewing = true
	RA.Alert(npcName, hit, mapPos, true)
	RA.previewing = false

	if alertFrame and alertFrame:IsShown() then
		MM:Print("Rare preview: %s (from %s). Drag it where you want it - the position is saved. "
			.. "Sound: %s. Arrow: %s.",
			npcName, from, tostring(RA.lastSound or "disabled"),
			RA.pointAt and "shown" or "no position available")
	else
		MM:Print("Rare preview: built the alert for %s but it did not show. "
			.. "Something is hiding the frame.", npcName)
	end
end

-- Did this record alert recently? The sweep asks before giving up on a spawn
-- point: an alert means the rare IS here and the player should stay.
function RA.RecentlyAlerted(rec, within)
	if not rec then return false end
	local cutoff = GetTime() - (within or 30)
	for name, at in pairs(lastAlertAt) do
		if at >= cutoff then
			local hit = RA.wanted[name:lower()]
			if hit and hit.rec == rec then return true end
		end
	end
	return false
end

-- Creature id out of a GUID.
local function npcIDFromGUID(guid)
	if not guid then return nil end
	local kind, _, _, _, _, id = strsplit("-", guid)
	if kind == "Creature" or kind == "Vehicle" then return tonumber(id) end
	return nil
end

-- id first, name as the fallback for anything not yet resolved
local function lookup(guid, name)
	local id = npcIDFromGUID(guid)
	if id and RA.wantedByID[id] then return RA.wantedByID[id], id end
	if name and RA.wanted[name:lower()] then return RA.wanted[name:lower()], id end
	return nil, id
end

------------------------------------------------------------
-- Alerting
------------------------------------------------------------
local function buildAlert()
	if alertFrame then return end
	alertFrame = CreateFrame("Frame", "MasterMountsRareAlert", UIParent, "BackdropTemplate")
	alertFrame:SetSize(430, 96)
	alertFrame:SetPoint("TOP", UIParent, "TOP", 0, -180)
	alertFrame:SetMovable(true)
	alertFrame:EnableMouse(true)
	alertFrame:RegisterForDrag("LeftButton")
	alertFrame:SetClampedToScreen(true)
	-- Above the default UI. A rare alert that renders behind a bag or a quest
	-- frame has technically fired and practically not.
	alertFrame:SetFrameStrata("HIGH")
	alertFrame:SetToplevel(true)
	alertFrame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 14,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	alertFrame:SetBackdropColor(0.05, 0.04, 0.02, 0.94)
	alertFrame:SetBackdropBorderColor(1, 0.55, 0.1)
	MM.Theme.Register(alertFrame, "panel")
	alertFrame:SetScript("OnDragStart", function(s) s:StartMoving() end)
	alertFrame:SetScript("OnDragStop", function(s)
		s:StopMovingOrSizing()
		local p, _, rp, x, y = s:GetPoint()
		MM.db.rareAlertPos = { point = p, relPoint = rp, x = x, y = y }
	end)

	alertFrame.icon = alertFrame:CreateTexture(nil, "ARTWORK")
	alertFrame.icon:SetSize(68, 68)
	alertFrame.icon:SetPoint("LEFT", 8, 0)
	alertFrame.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	-- A portrait of the actual creature, because "which one is that" is answered
	-- instantly by a model and slowly by a name. The mount's item icon stays as
	-- the fallback: not every rare has a creature we can display, and an empty
	-- model well looks broken in a way a wrong-but-present icon does not.
	local model = CreateFrame("PlayerModel", nil, alertFrame)
	model:SetSize(68, 68)
	model:SetPoint("LEFT", 8, 0)
	model:SetCamDistanceScale(1.6)
	model:SetPortraitZoom(0.85)
	model:Hide()
	alertFrame.model = model

	local ring = alertFrame:CreateTexture(nil, "OVERLAY")
	ring:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	ring:SetAllPoints(model)
	ring:SetVertexColor(0, 0, 0, 0)
	alertFrame.modelRing = ring

	alertFrame.title = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	-- Anchored to the MODEL, not the icon. They occupy the same rect now, but the
	-- model is what is usually visible and the text was starting underneath it.
	alertFrame.title:SetPoint("TOPLEFT", model, "TOPRIGHT", 12, -4)
	alertFrame.title:SetTextColor(1, 0.7, 0.15)
	alertFrame.title:SetText("RARE IS UP")

	alertFrame.body = alertFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	alertFrame.body:SetPoint("TOPLEFT", alertFrame.title, "BOTTOMLEFT", 0, -3)
	alertFrame.body:SetPoint("RIGHT", -34, 0)
	alertFrame.body:SetJustifyH("LEFT")

	-- The mount is named in the body text; make it a real link so it can be
	-- moused over. "drops Cartel Master's Gearglider" is a fact; a link is a
	-- thing the player can inspect without leaving the alert.
	alertFrame:SetHyperlinksEnabled(true)
	alertFrame:SetScript("OnHyperlinkEnter", function(self, link)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, link)
		if ok then GameTooltip:Show() else GameTooltip:Hide() end
	end)
	alertFrame:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)

	local close = MM.Theme.CreateCloseButton(alertFrame, 16)
	close:SetPoint("TOPRIGHT", -6, -6)
	close.mmTooltip = "Dismiss"
	close:SetScript("OnClick", function() alertFrame:Hide() end)
	alertFrame:HookScript("OnHide", function() if RA.StopMini then RA.StopMini() end end)

	-- A small arrow of our own, for rares that are not in the plan.
	--
	-- The main arrow belongs to whatever the player decided to go and do. A rare
	-- nobody planned for is an offer, not an instruction, so it gets its own
	-- pointer and leaves the route alone. Taking the main arrow for it would
	-- silently discard the thing they actually chose.
	local mini = CreateFrame("Frame", nil, alertFrame)
	mini:SetSize(34, 34)
	mini:SetPoint("BOTTOMRIGHT", -104, 10)
	mini.tex = mini:CreateTexture(nil, "ARTWORK")
	mini.tex:SetAllPoints()
	mini.tex:SetTexture("Interface\\Minimap\\Minimap-DeadArrow")
	mini.dist = mini:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	mini.dist:SetPoint("TOP", mini, "BOTTOM", 0, -1)
	mini:Hide()
	alertFrame.mini = mini

	-- Addons cannot call TargetUnit, but a secure macro button can.
	local target = CreateFrame("Button", "MasterMountsRareTargetButton", alertFrame,
		"SecureActionButtonTemplate,UIPanelButtonTemplate")
	target:SetSize(82, 22)
	target:SetPoint("BOTTOMRIGHT", -8, 6)
	target:SetAttribute("type", "macro")
	target:SetText("Target")
	alertFrame.targetButton = target

	if MM.db.rareAlertPos then
		alertFrame:ClearAllPoints()
		alertFrame:SetPoint(MM.db.rareAlertPos.point, UIParent,
			MM.db.rareAlertPos.relPoint, MM.db.rareAlertPos.x, MM.db.rareAlertPos.y)
	end
	MM.Theme.SkinTree(alertFrame)
	alertFrame:Hide()
end

-- `force` is for the options preview only. A preview that silently did nothing
-- because alerts were switched off, or because the same rare fired minutes ago,
-- would read as a broken button rather than a working setting.
function RA.Alert(npcName, hit, mapPos, force)
	if MM.db.rareAlert == false and not force then return end
	local now = GetTime()
	if not force then
		if lastAlertAt[npcName] and now - lastAlertAt[npcName] < ALERT_COOLDOWN then return end
	end
	lastAlertAt[npcName] = now

	buildAlert()
	local entry = hit.entry
	alertFrame.icon:SetTexture(entry.icon or 134400)

	-- Show the creature when we can identify it, the item icon when we cannot.
	local npcID = hit.rec and hit.rec.npc and hit.rec.npc.id
	if not npcID and MM.ResolvedIDs and MM.ResolvedIDs.npcs then
		npcID = MM.ResolvedIDs.npcs[npcName:lower()]
	end
	-- SetCreature is a REQUEST, not a guarantee.
	--
	-- pcall returning true only means the call did not error -- the model data
	-- may still be uncached, which leaves an empty frame while the code believes
	-- it succeeded. That is why the portrait sometimes came up blank: the alert
	-- fires the instant a vignette appears, which is exactly when the client is
	-- least likely to have that creature already loaded.
	--
	-- So ask, then VERIFY, then retry briefly. GetModelFileID() returns nil until
	-- the model is really there. If it never arrives we fall back to the icon,
	-- which is the honest outcome rather than a blank square.
	local shown = false
	if npcID and alertFrame.model then
		local model = alertFrame.model
		shown = pcall(function()
			model:ClearModel()
			model:SetCreature(npcID)
		end)
		if shown then
			local tries = 0
			local function verify()
				-- Frame may have been reused for a different rare while we waited.
				if model.mmNpcID ~= npcID then return end
				local id = model.GetModelFileID and model:GetModelFileID()
				if id then
					model:Show(); alertFrame.icon:Hide()
					return
				end
				tries = tries + 1
				if tries > 6 then          -- ~1.2s; the model is not coming
					model:Hide(); alertFrame.icon:Show()
					return
				end
				pcall(function() model:SetCreature(npcID) end)
				C_Timer.After(0.2, verify)
			end
			model.mmNpcID = npcID
			C_Timer.After(0.05, verify)
		end
	end
	alertFrame.model:SetShown(shown)
	alertFrame.icon:SetShown(not shown)
	-- Prefer a real link for the mount so the tooltip works; fall back to plain
	-- text rather than showing a broken link when the spell is not cached yet.
	local mountText = entry.name
	local sid = (hit.rec and hit.rec.spellID) or entry.spellID
	if sid then
		local link = (C_Spell and C_Spell.GetSpellLink and C_Spell.GetSpellLink(sid))
			or (GetSpellLink and GetSpellLink(sid))
		if link then mountText = link end
	end
	alertFrame.body:SetText(("|cffffffff%s|r is up — drops %s"):format(npcName, mountText))
	alertFrame:Show()

	-- secure attributes cannot be set in combat
	if not InCombatLockdown() then
		alertFrame.targetButton:SetAttribute("macrotext", "/targetexact " .. npcName)
		alertFrame.targetButton:Enable()
		alertFrame.targetButton:SetAlpha(1)
	else
		alertFrame.targetButton:Disable()
		alertFrame.targetButton:SetAlpha(0.5)
	end

	-- On the Master channel deliberately, and loud on purpose.
	--
	-- The old RAID_WARNING ping went out on the default channel, so it rode the
	-- player's SFX slider and vanished under combat noise -- which is exactly
	-- when a rare alert matters. Master ignores that slider. What Master does
	-- NOT ignore is the master volume, the global sound switch and the
	-- alt-tabbed setting, so PlaySound raises those three for the length of the
	-- clip and hands them straight back. A rare is up for minutes; an alert
	-- that loses to a muted client is an alert that did not happen.
	if MM.db.rareAlertSound ~= false then
		RA.lastSound = RA.PlaySound(MM.db.rareAlertSoundKey) or "NONE PLAYED"
	end
	if RaidNotice_AddMessage and RaidWarningFrame then
		pcall(RaidNotice_AddMessage, RaidWarningFrame,
			("%s is up! (%s)"):format(npcName, entry.name), ChatTypeInfo["RAID_WARNING"])
	end
	MM:Print("|cffff9a3cRare up:|r %s — drops %s", npcName, entry.name)

	-- Steer the plan, or merely point -- never both, and never the wrong one.
	--
	-- If this rare is a goal the player already chose, moving the route to it is
	-- an improvement: it is up NOW, and walking past it to preserve an order
	-- that assumed otherwise would be obedience to a stale decision. Order in
	-- the list does not matter here; being able to kill it does.
	--
	-- If it is not in the plan, the main arrow is not ours to take. It gets the
	-- small arrow instead, so the offer costs the player nothing.
	RA.pointAt = nil
	if mapPos and MM.db.rareAlertWaypoint ~= false then
		local mapID = C_Map.GetBestMapForUnit("player")
		if mapID then
			local x, y = mapPos.x * 100, mapPos.y * 100
			local continent, world = U.GetWorldPos(mapID, x, y)
			local planIndex = MM.Router and MM.Router.IndexOfRec
				and MM.Router:IndexOfRec(hit.rec) or nil
			-- A preview must never move the real route, and it should always
			-- show the small arrow -- that is the behaviour being previewed.
			if RA.previewing then planIndex = nil end

			if planIndex then
				MM.Router:JumpTo(planIndex)
				MM.Nav.SetWaypoint({
					mapID = mapID, x = x, y = y,
					label = npcName, rec = hit.rec, entry = entry,
					continent = continent, world = world,
				})
			else
				RA.pointAt = { mapID = mapID, x = x, y = y,
					continent = continent, world = world, label = npcName }
			end
		end
	end

	if alertFrame.mini then
		alertFrame.mini:SetShown(RA.pointAt ~= nil)
		if RA.pointAt then RA.StartMini() else RA.StopMini() end
	end

	-- A preview stays up until dismissed. It exists to be positioned, and a frame
	-- that vanishes after 45 seconds cannot be dragged anywhere deliberately.
	if not RA.previewing then
		C_Timer.After(45, function()
			if alertFrame and alertFrame:IsShown() then alertFrame:Hide() end
		end)
	end
end

-- Aim the small arrow. Runs only while the alert is up and only for rares that
-- are not in the plan, so it costs nothing in the common case.
local function updateMini()
	if not (alertFrame and alertFrame:IsShown() and RA.pointAt and alertFrame.mini) then return end
	local mini = alertFrame.mini
	local continent, world = U.PlayerWorldPos()
	if not (world and RA.pointAt.world and continent == RA.pointAt.continent) then
		mini.tex:SetRotation(0)
		mini.dist:SetText("")
		return
	end
	local dx = RA.pointAt.world.x - world.x
	local dy = RA.pointAt.world.y - world.y
	local facing = GetPlayerFacing()
	if not facing then return end
	-- world axes are rotated relative to the compass; atan2(dx, dy) matches the
	-- convention the main arrow already uses.
	mini.tex:SetRotation(math.atan2(dx, dy) - facing)
	local d = math.sqrt(dx * dx + dy * dy)
	mini.dist:SetText(("%d yd"):format(d))
end

-- The ticker exists only while an off-plan rare is being pointed at. A frame
-- that is hidden most of the session should not be paying a 10Hz cost for it.
local miniTicker

function RA.StartMini()
	if miniTicker then return end
	miniTicker = C_Timer.NewTicker(0.1, updateMini)
end

function RA.StopMini()
	if not miniTicker then return end
	miniTicker:Cancel()
	miniTicker = nil
end

------------------------------------------------------------
-- Vignette scanning — the game's own "a rare is here" markers
------------------------------------------------------------
local function scanVignettes()
	if not (C_VignetteInfo and C_VignetteInfo.GetVignettes) then return end
	if not next(RA.wanted) then return end

	local ok, guids = pcall(C_VignetteInfo.GetVignettes)
	if not ok or not guids then return end

	for _, guid in ipairs(guids) do
		if not RA.seen[guid] then
			local okInfo, info = pcall(C_VignetteInfo.GetVignetteInfo, guid)
			-- A 12.0 secret name would throw on the lookup and again on the
			-- alert text. The objectGUID is the reliable match anyway -- it
			-- carries the creature id, which is why it is passed first -- but
			-- an alert with no name to show is not worth raising.
			local vname = info and MM.Util.ReadableString(info.name)
			if okInfo and info and vname then
				-- objectGUID carries the creature id, so this matches exactly
				-- even on a client whose language we don't speak
				local hit = lookup(info.objectGUID, vname)
				if hit then
					RA.seen[guid] = GetTime()
					local pos
					local okPos, p = pcall(C_VignetteInfo.GetVignettePosition,
						guid, C_Map.GetBestMapForUnit("player"))
					if okPos then pos = p end
					RA.Alert(vname, hit, pos)
				else
					RA.seen[guid] = GetTime() -- remember misses too, don't re-check
				end
			end
		end
	end

	-- forget vignettes that have despawned so a respawn alerts again
	local live = {}
	for _, guid in ipairs(guids) do live[guid] = true end
	for guid in pairs(RA.seen) do
		if not live[guid] then RA.seen[guid] = nil end
	end
end

------------------------------------------------------------
-- Backstop: target / mouseover / nameplate name matching, for rares that
-- have no vignette at all.
------------------------------------------------------------
local function checkUnit(unit)
	if not unit or not UnitExists(unit) then return end
	local name = UnitName(unit)
	if not name then return end
	local hit = lookup(UnitGUID(unit), name)
	if not hit then return end
	local classification = UnitClassification(unit)
	if classification == "rare" or classification == "rareelite"
		or classification == "elite" or classification == "worldboss" then
		RA.Alert(name, hit, C_Map.GetPlayerMapPosition(C_Map.GetBestMapForUnit("player") or 0, "player"))
	end
end

------------------------------------------------------------
-- Wiring
------------------------------------------------------------
MM:RegisterGameEvent("VIGNETTE_MINIMAP_UPDATED", function() scanVignettes() end)
MM:RegisterGameEvent("VIGNETTES_UPDATED", function() scanVignettes() end)
MM:RegisterGameEvent("NAME_PLATE_UNIT_ADDED", function(unit) checkUnit(unit) end)
MM:RegisterGameEvent("UPDATE_MOUSEOVER_UNIT", function() checkUnit("mouseover") end)
MM:RegisterGameEvent("PLAYER_TARGET_CHANGED", function() checkUnit("target") end)

MM:On("MM_SCANNED", RA.RebuildIndex)
MM:On("MM_PLAN_CHANGED", RA.RebuildIndex)
-- newly resolved creature ids must enter the id index
MM:On("MM_IDS_RESOLVED", RA.RebuildIndex)

MM:RegisterGameEvent("ZONE_CHANGED_NEW_AREA", function()
	C_Timer.After(2, scanVignettes)
end)

MM:On("MM_LOGIN", function()
	C_Timer.After(12, scanVignettes)
end)
