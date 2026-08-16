-- Master Mounts celebration: full-screen splash with the actual mount model,
-- fanfare, and an automatic screenshot when a hunted mount is finally yours.
local _, MM = ...

MM.Celebration = {}
local CB = MM.Celebration

local overlay
-- Bumped on every splash; a deferred callback only acts if it is still the
-- splash that scheduled it. See the note at the show below.
local generation = 0

local function build()
	if overlay then return end

	overlay = CreateFrame("Button", "MasterMountsCelebration", UIParent)
	overlay:SetAllPoints(UIParent)
	overlay:SetFrameStrata("FULLSCREEN_DIALOG")
	overlay:EnableMouse(true)
	overlay:Hide()
	overlay:SetScript("OnClick", function(self) self:Hide() end)

	local vignette = overlay:CreateTexture(nil, "BACKGROUND")
	vignette:SetAllPoints()
	vignette:SetColorTexture(0, 0, 0, 0.45)

	-- spinning glow behind the model
	local glow = overlay:CreateTexture(nil, "ARTWORK", nil, 1)
	glow:SetPoint("CENTER", 0, -20)
	glow:SetSize(520, 520)
	glow:SetTexture("Interface\\Cooldown\\star4")
	glow:SetBlendMode("ADD")
	glow:SetVertexColor(1, 0.85, 0.3, 0.9)
	overlay.glow = glow

	local spinGroup = glow:CreateAnimationGroup()
	spinGroup:SetLooping("REPEAT")
	local spin = spinGroup:CreateAnimation("Rotation")
	spin:SetDegrees(360)
	spin:SetDuration(14)
	overlay.spinGroup = spinGroup

	local model = CreateFrame("PlayerModel", nil, overlay)
	model:SetPoint("CENTER", 0, -20)
	model:SetSize(480, 480)
	overlay.model = model

	local header = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	header:SetPoint("TOP", 0, -110)
	header:SetText("MOUNT COLLECTED!")
	header:SetTextColor(1, 0.84, 0.1)
	header:SetTextScale(2)
	overlay.header = header

	local nameText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	nameText:SetPoint("TOP", header, "BOTTOM", 0, -14)
	nameText:SetTextColor(1, 1, 1)
	nameText:SetTextScale(1.3)
	overlay.nameText = nameText

	local hint = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("BOTTOM", 0, 140)
	hint:SetText("Click anywhere to dismiss")
	hint:SetTextColor(0.8, 0.8, 0.8)

	-- entrance pop
	local popGroup = overlay:CreateAnimationGroup()
	local fadeIn = popGroup:CreateAnimation("Alpha")
	fadeIn:SetFromAlpha(0)
	fadeIn:SetToAlpha(1)
	fadeIn:SetDuration(0.35)
	fadeIn:SetSmoothing("OUT")
	overlay.popGroup = popGroup

	tinsert(UISpecialFrames, "MasterMountsCelebration")
end

function CB:Show(mountID, mountName, noScreenshot)
	build()

	overlay.nameText:SetText(mountName or "")
	local displayID = mountID and C_MountJournal.GetMountInfoExtraByID(mountID)
	overlay.model:ClearModel()
	if displayID then
		pcall(overlay.model.SetDisplayInfo, overlay.model, displayID)
		pcall(overlay.model.SetRotation, overlay.model, 0.4)
	end

	-- WHICH SPLASH THIS IS. The overlay is a singleton, so "is it still shown"
	-- cannot tell a splash that is still up from a DIFFERENT one that went up
	-- after it. Collect two mounts within nine seconds -- an ordinary thing on
	-- a shared stop -- and the first mount's timer hid the second mount's
	-- splash, and its screenshot caught the wrong mount.
	generation = generation + 1
	local mine = generation

	overlay:Show()
	overlay.popGroup:Play()
	overlay.spinGroup:Play()

	if SOUNDKIT and SOUNDKIT.UI_LEGENDARY_LOOT_TOAST then
		PlaySound(SOUNDKIT.UI_LEGENDARY_LOOT_TOAST)
	elseif SOUNDKIT and SOUNDKIT.UI_EPICLOOT_TOAST then
		PlaySound(SOUNDKIT.UI_EPICLOOT_TOAST)
	end

	if MM.db.celebrationShot and not noScreenshot then
		-- give the pop-in a beat so the screenshot catches the full splash
		C_Timer.After(1.0, function()
			if generation == mine and overlay:IsShown() then Screenshot() end
		end)
	end

	C_Timer.After(9, function()
		-- Only this splash may retire itself. A newer one owns the overlay now.
		if generation == mine and overlay:IsShown() then overlay:Hide() end
	end)
end

-- Preview from the options panel: random collected mount, never screenshots.
function CB:Test()
	local pool = {}
	for _, entry in ipairs(MM.Scanner.mounts) do
		if entry.collected then tinsert(pool, entry) end
	end
	local pick = pool[math.random(math.max(#pool, 1))] or MM.Scanner.mounts[1]
	if not pick then
		MM:Print("Mount journal not scanned yet — try again in a moment.")
		return
	end
	CB:Show(pick.mountID, pick.name, true)
end

------------------------------------------------------------
-- Chat announcements (opt-in)
------------------------------------------------------------
local function mountLink(spellID, name)
	if spellID then
		local ok, link
		if C_Spell and C_Spell.GetSpellLink then
			ok, link = pcall(C_Spell.GetSpellLink, spellID)
		end
		if not (ok and link) and _G.GetSpellLink then
			ok, link = pcall(_G.GetSpellLink, spellID)
		end
		if ok and link then return link end
	end
	return name or "a new mount"
end

-- Numeric channel index for a named chat channel ("Trade", "General").
local function numberedChannel(needle)
	local id = GetChannelName and select(1, GetChannelName(needle))
	if id and id > 0 then return id end
	-- names are localized/suffixed ("Trade - City"); scan the joined list
	if not GetChannelList then return nil end
	local list = { GetChannelList() }
	for i = 1, #list, 3 do
		local index, name = list[i], list[i + 1]
		if type(name) == "string" and name:lower():find(needle:lower(), 1, true) then
			return index
		end
	end
	return nil
end

function CB.Announce(spellID, name)
	local cfg = MM.db and MM.db.announce
	if not (cfg and cfg.enabled) then return end

	local msg = ("Mount collected: %s  (%d/%d)"):format(
		mountLink(spellID, name), MM.Scanner.collectedCount, MM.Scanner.totalCount)

	local function send(channel, target)
		pcall(SendChatMessage, msg, channel, nil, target)
	end

	if cfg.guild and IsInGuild() then send("GUILD") end

	if cfg.group then
		if IsInRaid() then
			send(IsInRaid(LE_PARTY_CATEGORY_INSTANCE) and "INSTANCE_CHAT" or "RAID")
		elseif IsInGroup() then
			send(IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and "INSTANCE_CHAT" or "PARTY")
		end
	end

	if cfg.say then send("SAY") end

	for key, needle in pairs({ trade = "Trade", general = "General" }) do
		if cfg[key] then
			local index = numberedChannel(needle)
			if index then send("CHANNEL", index) end
		end
	end
end

-- Announcing is independent of the on-screen celebration: you may want one
-- without the other.
MM:On("MM_MOUNT_LEARNED", function(mountID, spellID)
	local cfg = MM.db and MM.db.announce
	if not (cfg and cfg.enabled) then return end
	if cfg.plannedOnly and not (spellID and MM.Planner:InPlan(spellID)) then return end
	local name = mountID and C_MountJournal.GetMountInfoByID(mountID)
	CB.Announce(spellID, name)
end)

MM:On("MM_MOUNT_LEARNED", function(mountID, spellID)
	if not MM.db.celebration then return end
	local planned = spellID and MM.Planner:InPlan(spellID)
	if not planned and not MM.db.celebrateAll then return end

	local name = mountID and C_MountJournal.GetMountInfoByID(mountID)
	CB:Show(mountID, name)
	if name then
		MM:Print("|cff40d860%s|r joins the stable! (%d / %d collected)",
			name, MM.Scanner.collectedCount, MM.Scanner.totalCount)
	end
	if planned and spellID then
		MM.Planner:Remove(spellID)
	end
end)
