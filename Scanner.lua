-- Master Mounts scanner: reads the Mount Journal, links journal mounts to the
-- database, tracks collected state, and counts kill attempts.
local _, MM = ...

MM.Scanner = {}
local S = MM.Scanner

S.mounts = {}        -- array of enriched entries, sorted by name
S.bySpell = {}       -- [spellID] = entry
S.byMountID = {}     -- [mountID] = entry
S.collectedCount = 0
S.hiddenCount = 0    -- journal entries this character cannot use
S.byName = {}        -- [lowercased name] = entry, INCLUDING hidden ones
S.totalCount = 0
S.ready = false

-- Journal sourceType -> our category, for mounts the database doesn't know.
local SOURCETYPE_CATEGORY = {
	[1] = "DROP", [2] = "QUEST", [3] = "VENDOR", [4] = "PROFESSION",
	[6] = "ACHIEVEMENT", [7] = "PVP", [8] = "PROMOTION", [9] = "TCG",
	[10] = "STORE",
}

local function stripColors(text)
	if not text then return nil end
	-- Colour AND texture escapes. A vendor cost arrives as "Cost: 1|TInterface\\
	-- MoneyFrame\\UI-GoldIcon:12|t", and leaving the texture in makes the source
	-- unreadable the moment it is truncated for display.
	return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
		:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("%s+$", ""))
end

function S:Rescan()
	wipe(S.mounts); wipe(S.bySpell); wipe(S.byMountID); wipe(S.byName)
	S.hiddenCount = 0
	S.collectedCount, S.totalCount = 0, 0

	local ids = C_MountJournal.GetMountIDs()
	if not ids or #ids == 0 then return end

	-- Several journal entries can share one mount spell, and only one of them
	-- reports isCollected. Build a name set of everything collected first, so
	-- a duplicate entry doesn't show as missing when you already own it.
	local collectedNames = {}
	for _, mountID in ipairs(ids) do
		local n, _, _, _, _, _, _, _, _, _, isCollected = C_MountJournal.GetMountInfoByID(mountID)
		if n and isCollected then collectedNames[n:lower()] = true end
	end

	for _, mountID in ipairs(ids) do
		local name, spellID, icon, _, _, sourceType, _, isFactionSpecific,
			faction, shouldHide, isCollected = C_MountJournal.GetMountInfoByID(mountID)
		-- shouldHideOnChar is true for mounts THIS character cannot use: the other
		-- faction's, other classes' and race-locked ones. Skipping them entirely
		-- meant they were absent from every index, so our perfectly correct
		-- records for them were reported as "no journal entry" -- 246 of them --
		-- and journal coverage was measured against a filtered subset, which
		-- flattered it to 99.9%.
		--
		-- They are still indexed for MATCHING; they are just kept out of the
		-- displayed list, which is what shouldHide is actually asking for.
		if name then
			local rec = (spellID and MM.DBBySpell[spellID]) or MM.DBByName[name:lower()]
			local entry = {
				mountID = mountID,
				spellID = spellID,
				name = name,
				icon = icon,
				collected = isCollected or collectedNames[name:lower()] or false,
				rec = rec,
				sourceType = sourceType,
				-- journal faction: 0 = Horde, 1 = Alliance
				faction = isFactionSpecific and (faction == 1 and "Alliance" or "Horde") or nil,
			}
			if not rec then
				-- Auto-stub anything the database doesn't cover (e.g. brand-new
				-- patch mounts) using the journal's own source text.
				local sourceText = select(3, C_MountJournal.GetMountInfoExtraByID(mountID))
				local cleanSource = stripColors(sourceText) or ""
				-- Not everything in the journal is a mount you can collect.
				--
				--   "Legacy"     Blizzard's own marker for removed content. It
				--                covers the Swift Spectral corpse-run flight
				--                forms and old racial vendor stock alike.
				--   "[DND]"      developer test entries ("[DND] Test Mount JZB").
				--   empty source system entries such as Soar, the Dracthyr
				--                racial, and the unnamed Whelpling rows.
				--
				-- Marking these obtainable inflated the "needs cataloguing" list
				-- with 20-odd things nobody can ever collect, and would have put
				-- them in the plan.
				-- Placeholder and developer entries. Blizzard ships these in the
				-- journal with the marker right in the name:
				--   "[PH] Alliance Wolf Mount", "Green Rocket Mount [PH]",
				--   "(PH) Legion Remix Mount", "[DND] Test Mount JZB"
				-- The marker can be anywhere in the name, so all three forms are
				-- checked rather than just a prefix.
				local isTest = name:find("[DND]", 1, true) ~= nil
					or name:find("[PH]", 1, true) ~= nil
					or name:find("(PH)", 1, true) ~= nil
				local isLegacy = cleanSource:lower():find("^legacy") ~= nil
				local isSystem = cleanSource == ""
				-- sourceType leaves Trading Post and shop mounts as UNKNOWN, which
				-- is a shame because the source TEXT names them outright. A
				-- correctly categorised stub is genuinely useful: a TRADINGPOST
				-- one reports against the live rotation instead of looking like
				-- an uncatalogued mystery.
				local lower = cleanSource:lower()
				local fromText = lower:find("trading post", 1, true) and "TRADINGPOST"
					or lower:find("in-game shop", 1, true) and "STORE"
					or lower:find("promotion", 1, true) and "PROMOTION"
					or lower:find("world event", 1, true) and "HOLIDAY"
					or nil

				entry.rec = {
					name = name, spellID = spellID, stub = true,
					category = (isTest or isSystem) and "REMOVED"
						or isLegacy and "REMOVED"
						or fromText
						or SOURCETYPE_CATEGORY[sourceType] or "UNKNOWN",
					source = isTest and "Developer test entry — not obtainable"
						or isLegacy and "Legacy — no longer obtainable"
						or isSystem and "System mount — not collectible"
						or cleanSource,
					obtainable = not (isTest or isLegacy or isSystem),
					notCollectible = isTest or isSystem,
				}
			end
			entry.hidden = shouldHide or false
			if spellID then S.bySpell[spellID] = entry end
			S.byMountID[mountID] = entry
			S.byName[name:lower()] = entry
			if shouldHide then
				S.hiddenCount = S.hiddenCount + 1
			else
				tinsert(S.mounts, entry)
				S.totalCount = S.totalCount + 1
				if entry.collected then S.collectedCount = S.collectedCount + 1 end
			end
		end
	end

	table.sort(S.mounts, function(a, b) return (a.name or "") < (b.name or "") end)
	S.ready = true
	MM:Fire("MM_SCANNED")
end

-- Entries usable by this character's faction.
function S:FactionOk(entry)
	return not entry.faction or entry.faction == MM.playerFaction
end

function S:GetDisplayID(entry)
	if not entry or not entry.mountID then return nil end
	local displayID = C_MountJournal.GetMountInfoExtraByID(entry.mountID)
	return displayID
end

------------------------------------------------------------
-- Attempt tracking
------------------------------------------------------------
-- Count a kill of a planned mount's target npc as an attempt.
local function npcIDFromGUID(guid)
	if not guid then return nil end
	local kind, _, _, _, _, npcID = strsplit("-", guid)
	if kind == "Creature" or kind == "Vehicle" then return tonumber(npcID) end
	return nil
end

local watchedNPCs = {} -- [npcID] = spellID

local function rebuildWatched()
	wipe(watchedNPCs)
	if not (MM.cdb and MM.cdb.plan) then return end
	for _, item in ipairs(MM.cdb.plan) do
		local entry = S.bySpell[item.spellID]
		local rec = entry and entry.rec
		if rec and rec.npc and rec.npc.id and MM.KILL_BASED[rec.category] then
			watchedNPCs[rec.npc.id] = item.spellID
		end
	end
end

local onEncounterEnd -- forward-declared; defined below

local function onCombatLog()
	local _, subevent, _, _, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
	if subevent ~= "UNIT_DIED" and subevent ~= "PARTY_KILL" then return end
	local npcID = npcIDFromGUID(destGUID)
	local spellID = npcID and watchedNPCs[npcID]
	if not spellID then return end
	MM.Attempts.Record(spellID)
end

-- 12.0 HANDS OUT SECRET VALUES, AND A SECRET IS NOT A STRING.
--
-- Reported from outside, next to a boss kill in the chat log:
--   "nil failed: attempt to perform string conversion on a secret value
--    (execution tainted by 'MasterMountsWorldTour')"
--
-- Midnight made several event payloads SECRET for a tainted addon, and
-- `encounterName` is one of them. Comparing it is fine; `encounterName:lower()`
-- is a string operation on a value the client will not let us read, and it
-- throws. This fires on every boss kill, so it repeated for the whole session.
--
-- The combat-log path two blocks down was already turned off for 12.0 for a
-- related reason. This is the same class of change arriving through a different
-- door, and the lesson is that a payload which has always been a string is not
-- guaranteed to still be one.
--
-- Degrade, do not throw. If the name cannot be read, attempts stop being
-- counted automatically from boss names -- which is a feature quietly doing
-- less, not an addon spraying errors. Said once, then silent.
local secretNames = false
local function readableName(name)
	if secretNames or name == nil then return nil end
	local ok, lowered = pcall(string.lower, name)
	if ok and type(lowered) == "string" then return lowered end
	secretNames = true
	MM:Print("This client hides boss names from addons, so kills will not be "
		.. "counted as attempts automatically. Everything else is unaffected.")
	return nil
end

-- Encounter kills (instance bosses) matched by npc name, since encounter IDs
-- aren't in the database.
function onEncounterEnd(_, encounterName, _, _, success)
	if success ~= 1 then return end
	local wanted = readableName(encounterName)
	if not wanted then return end
	if not (MM.cdb and MM.cdb.plan) then return end
	for _, item in ipairs(MM.cdb.plan) do
		local entry = S.bySpell[item.spellID]
		local rec = entry and entry.rec
		if rec and rec.npc and rec.npc.name and not entry.collected
			and rec.npc.name:lower() == wanted then
			MM.Attempts.Record(item.spellID)
		end
	end
end

------------------------------------------------------------
-- Wiring
------------------------------------------------------------
MM:On("MM_LOGIN", function()
	-- journal data can lag briefly at login
	C_Timer.After(2, MM.TimeIt("Scanner:Rescan", function() S:Rescan(); rebuildWatched() end))
end)

MM:On("MM_PLAN_CHANGED", rebuildWatched)

MM:RegisterGameEvent("NEW_MOUNT_ADDED", function(mountID)
	local entry = S.byMountID[mountID]
	S:Rescan()
	rebuildWatched()
	MM:Fire("MM_MOUNT_LEARNED", mountID, entry and entry.spellID)
end)

-- 12.0 (Midnight) made raw combat-log registration a Blizzard-only action —
-- registering it triggers ADDON_ACTION_FORBIDDEN even under pcall. Only hook
-- it on older clients; newer ones use the signals below instead.
local clientBuild = select(4, GetBuildInfo())
if clientBuild and clientBuild < 120000 then
	MM:RegisterGameEvent("COMBAT_LOG_EVENT_UNFILTERED", onCombatLog)
end
MM:RegisterGameEvent("ENCOUNTER_END", onEncounterEnd)

-- World/instance boss kills without the combat log (debounced vs ENCOUNTER_END).
local lastKillAt = {}
MM:RegisterGameEvent("BOSS_KILL", function(_, encounterName)
	-- Keyed on the READABLE name, never the raw payload: a secret value used as
	-- a table key is the same forbidden conversion one line earlier than the
	-- comparison that reported it.
	local key = readableName(encounterName)
	if not key then return end
	local now = GetTime()
	if lastKillAt[key] and now - lastKillAt[key] < 5 then return end
	lastKillAt[key] = now
	onEncounterEnd(nil, encounterName, nil, nil, 1)
end)

-- Outdoor rare attempts without the combat log: watch each planned mount's
-- attempt-tracking quest and count the false -> true flip.
--
-- This used to be an unconditional 10-second ticker that walked the entire plan
-- and queried the quest log for every record. On a 281-goal plan that is a few
-- hundred API calls a minute, forever, for a check that most plans never need --
-- only a handful of records carry a trackingQuest at all.
--
-- Now the tracked set is computed once when the plan changes, and the ticker
-- only exists while that set is non-empty.
local questState = {}
local tracked = {}
local attemptTicker

local function pollTracked()
	for i = 1, #tracked do
		local spellID = tracked[i]
		local rec = S.bySpell[spellID] and S.bySpell[spellID].rec
		local questID = rec and rec.trackingQuest
		if questID then
			local flagged = C_QuestLog.IsQuestFlaggedCompleted(questID) or false
			local prev = questState[spellID]
			questState[spellID] = flagged
			if flagged and prev == false then
				MM.Attempts.Record(spellID)
			end
		end
	end
end

local function rebuildTracked()
	wipe(tracked)
	if MM.cdb and MM.cdb.plan then
		for _, item in ipairs(MM.cdb.plan) do
			local entry = S.bySpell[item.spellID]
			if entry and entry.rec and entry.rec.trackingQuest then
				tinsert(tracked, item.spellID)
				-- seed the baseline so a quest already complete at login is not
				-- miscounted as a fresh attempt on the first poll
				if questState[item.spellID] == nil then
					questState[item.spellID] =
						C_QuestLog.IsQuestFlaggedCompleted(entry.rec.trackingQuest) or false
				end
			end
		end
	end
	if #tracked > 0 and not attemptTicker then
		attemptTicker = C_Timer.NewTicker(10, pollTracked)
	elseif #tracked == 0 and attemptTicker then
		attemptTicker:Cancel()
		attemptTicker = nil
	end
end

MM:On("MM_PLAN_CHANGED", rebuildTracked)
MM:On("MM_SCANNED", rebuildTracked)

------------------------------------------------------------
-- /mm audit — database <-> journal match report
------------------------------------------------------------
MM:On("MM_AUDIT", function()
	-- Count every journal entry, hidden ones included, so this agrees with the
	-- coverage figure in /mm check. Counting only the displayed list reported
	-- 1336 matched beside a summary saying 1565 — two numbers for one thing.
	local matched, stubbed = 0, 0
	for _, entry in pairs(S.byMountID) do
		if entry.rec and entry.rec.stub then stubbed = stubbed + 1 else matched = matched + 1 end
	end

	-- Canonical records only. MM.DBList holds every record in load order,
	-- including the duplicates AddMounts demoted to altSources; counting those
	-- inflates the total and is the same mistake the offline audit made once.
	local orphans, byCategory, realGaps, otherFaction, unreleased = 0, {}, {}, 0, 0
	local charLocked, noSpell = 0, 0
	local QG = MM.QuestGate
	for _, rec in ipairs(MM.DBList) do
		local canon = (rec.spellID and MM.DBBySpell[rec.spellID] == rec)
			or (rec.name and MM.DBByName[rec.name:lower()] == rec)
		if canon then
			-- S.byName includes hidden entries, so a record for the other
			-- faction's mount now matches the journal entry that exists for it.
			local hit = (rec.spellID and S.bySpell[rec.spellID])
				or (rec.name and S.byName[rec.name:lower()])
			if not hit then
				orphans = orphans + 1
				local key = rec.category or "(none)"
				byCategory[key] = (byCategory[key] or 0) + 1
				-- The mount journal does not list the OTHER faction's mounts, so
				-- those are expected to be absent and are not evidence of
				-- anything. Counting them as suspects reported 157 "likely wrong
				-- names" that were simply Alliance mounts on a Horde character.
				local locked = QG and ((QG.WrongClass and QG.WrongClass(rec))
					or (QG.WrongRace and QG.WrongRace(rec)))
				if rec.unreleased then
					-- Content from a patch that is not live. Its absence from the
					-- journal is the expected state, not a gap.
					unreleased = unreleased + 1
				elseif rec.faction and MM.playerFaction and rec.faction ~= MM.playerFaction then
					otherFaction = otherFaction + 1
				elseif locked then
					-- A Druid form or a heritage mount is absent from a Hunter's
					-- journal for the same reason the other faction's are, and
					-- listing it as a suspect sends someone looking for a typo
					-- in a name that is perfectly correct.
					charLocked = charLocked + 1
				elseif rec.obtainable ~= false then
					tinsert(realGaps, rec.name or "?")
					-- A record with no spellID can only be matched on its NAME,
					-- so a name that differs by a punctuation mark misses
					-- silently. Worth counting: it says which half of the list
					-- is a naming problem and which half is a real absence.
					if not rec.spellID then noSpell = noSpell + 1 end
				end
			end
		end
	end

	MM:Print("Audit: %d journal mounts matched, %d auto-stubbed, %d DB records with no journal entry.",
		matched, stubbed, orphans)
	-- List the auto-stubbed ones. This is the most actionable list in the whole
	-- audit -- mounts the player's own journal knows about that we have no record
	-- for -- and it was being reported only as a count. The journal's own source
	-- text is printed alongside, which is usually enough to write a record from.
	local realStubs = 0
	for _, entry in pairs(S.byMountID) do
		if entry.rec and entry.rec.stub and entry.rec.obtainable ~= false then
			realStubs = realStubs + 1
		end
	end
	if stubbed > 0 then
		MM:Print("  |cffffd84d%d journal mounts have no record|r (%d of them obtainable — the rest are legacy, system or test entries):",
			stubbed, realStubs)
		local shown = 0
		for _, entry in pairs(S.byMountID) do
			if entry.rec and entry.rec.stub and entry.rec.obtainable ~= false and shown < 30 then
				shown = shown + 1
				MM:Print("     %s |cff9a9a9a[%s]|r %s", entry.name,
					entry.rec.category or "?",
					(entry.rec.source or ""):sub(1, 60))
			end
		end
		-- count against what was actually LISTED, not the total; with 0
		-- obtainable stubs it printed an empty list followed by "...and 3 more"
		if realStubs > shown then MM:Print("     ...and %d more.", realStubs - shown) end
	end

	MM:Print("  (%d further journal entries are hidden for this character — other faction, class or race — and are matched but not listed.)",
		S.hiddenCount or 0)

	-- TWO DIFFERENT POPULATIONS, AND THEY WERE PRINTED AS ONE.
	--
	-- Above this line: journal mounts we have no record for. Below it: OUR
	-- records with no journal entry. Opposite directions, different fixes --
	-- and with no heading between them the category breakdown and the three
	-- lines that follow read as a continuation of the list above, so "20 are
	-- obtainable, this faction, and still missing" looked like twenty mounts
	-- the addon could not see. It is twenty records the journal does not list.
	if orphans > 0 then
		MM:Print("  |cffffd84d%d records of ours have no journal entry|r "
			.. "(the opposite direction to the list above):", orphans)
		local order = {}
		for cat in pairs(byCategory) do tinsert(order, cat) end
		table.sort(order, function(a, b) return byCategory[a] > byCategory[b] end)
		local parts = {}
		for _, cat in ipairs(order) do
			tinsert(parts, ("%s %d"):format(cat, byCategory[cat]))
		end
		MM:Print("     by category: %s", table.concat(parts, ", "))
		if unreleased > 0 then
			MM:Print("     %d are unreleased patch content — no journal entry exists yet.", unreleased)
		end
		if otherFaction > 0 then
			MM:Print("     %d are the other faction's mounts — the journal never lists those.",
				otherFaction)
		end
		if charLocked > 0 then
			MM:Print("     %d are locked to another class or race — absent from THIS "
				.. "character's journal, and still real work for the warband.", charLocked)
		end
	end

	-- For each genuine gap, suggest the journal mount it probably IS. Most of
	-- these are not missing mounts at all -- they are records filed under the
	-- ITEM name rather than the mount's ("Wick's Lead" for "Wick"), and that is
	-- only visible with the journal in front of you. Turning the list into
	-- name -> suggestion makes it a fix list instead of a mystery.
	local function normalise(text)
		return (text:lower():gsub("^the ", ""):gsub("^reins of the ", "")
			:gsub("^reins of ", ""):gsub("'s reins$", ""):gsub("'s harness$", "")
			:gsub("'s lead$", ""):gsub("'s bridle$", ""):gsub(" harness$", "")
			:gsub(" reins$", ""):gsub("[^%a%d ]", ""))
	end
	local journalNorm = {}
	for _, entry in ipairs(S.mounts) do
		journalNorm[#journalNorm + 1] = { norm = normalise(entry.name), name = entry.name }
	end

	local function suggest(recName)
		local want = normalise(recName)
		if want == "" then return nil end
		for _, j in ipairs(journalNorm) do
			if j.norm == want then return j.name, "same after stripping item wording" end
		end
		-- Substring matching was far too loose: it offered "Charger" ->
		-- "The Headless Horseman's Hallowed Charger" and "Prestigious Midnight
		-- Courser" -> "Midnight". A suggestion that is usually wrong is worse
		-- than none, because it invites bad edits.
		--
		-- Only accept a containment match when the LEFTOVER words are item
		-- wrapper words. "Disc of the Red Flying Cloud" -> "Red Flying Cloud"
		-- leaves "disc of", which qualifies; "Charger" vs the Horseman's mount
		-- leaves real words, which does not.
		local WRAPPER = {
			disc = true, reins = true, of = true, the = true, a = true,
			harness = true, bridle = true, lead = true, cap = true,
			saddle = true, whistle = true, horn = true, ["set"] = true,
		}
		for _, j in ipairs(journalNorm) do
			if #j.norm >= 6 and want:find(j.norm, 1, true) then
				local leftover = want:gsub(j.norm, " ")
				local onlyWrapper = true
				for word in leftover:gmatch("%a+") do
					if not WRAPPER[word] then onlyWrapper = false break end
				end
				if onlyWrapper then return j.name, "item wording around the mount name" end
			end
		end
		-- Name drift: our name is the journal's plus (or minus) one trailing
		-- word. "Skypaw Glimmerfur Prowler" against the journal's "Skypaw
		-- Glimmerfur" is exactly this, and the wrapper-word rule could not see
		-- it because "prowler" is not item wording. Requiring a shared prefix
		-- and a single extra word keeps it tight enough to avoid the
		-- "Charger" -> "Headless Horseman's Hallowed Charger" nonsense.
		for _, j in ipairs(journalNorm) do
			if #j.norm >= 6 then
				local longer, shorter = want, j.norm
				if #shorter > #longer then longer, shorter = shorter, longer end
				if longer:sub(1, #shorter) == shorter then
					local extra = longer:sub(#shorter + 1)
					if #extra > 0 and #extra <= 10 and not extra:find(" ") then
						return j.name, "one trailing word different"
					end
				end
			end
		end

		return nil
	end

	if #realGaps == 0 then
		MM:Print("     |cff40d860Every one is accounted for — unreleased, other faction, "
			.. "or locked to another class or race.|r")
	else
		MM:Print("     |cffffd84d%d are unaccounted for — this faction, this character, "
			.. "obtainable, and the journal still does not list them:|r", #realGaps)
		for i = 1, math.min(#realGaps, 25) do
			local name = realGaps[i]
			local match, why = suggest(name)
			MM:Print("        %s%s", name,
				match and ("  |cff40d860-> probably \"%s\"|r |cff9a9a9a(%s)|r"):format(match, why) or "")
		end
		if #realGaps > 25 then MM:Print("        ...and %d more.", #realGaps - 25) end
		-- WHICH HALF IS A NAMING PROBLEM.
		--
		-- A record carrying a spellID is matched on the spell, which is exact,
		-- so its absence is real. A record without one can only be matched on
		-- its name -- and a name differing by an apostrophe or a hyphen misses
		-- in silence, which looks identical to a mount that is genuinely not
		-- there. Splitting the list says which of the two to go and look for.
		if noSpell > 0 then
			MM:Print("        |cff9a9a9a%d of those carry no spellID, so only the NAME "
				.. "can match — check the spelling before assuming the mount is absent. "
				.. "The other %d are matched on their spell and are genuinely not listed.|r",
				noSpell, #realGaps - noSpell)
		end
	end
end)

------------------------------------------------------------
-- /mm stubs — export the uncatalogued journal mounts
------------------------------------------------------------
-- The journal knows things about these mounts that no external guide does: the
-- exact name, the source text Blizzard ships, and the sourceType. That is
-- usually enough to write a proper record, but only if it can get out of the
-- game. This emits ready-to-paste Lua rather than a list to retype.
--
-- Same shape as /mm export for resolved IDs: the client produces the data, a
-- human checks it, and it gets committed. Nothing is invented here -- every
-- field comes from the journal.
MM:On("MM_STUBS_EXPORT", function()
	local rows = {}
	for _, entry in pairs(S.byMountID) do
		-- Only what is actually collectible. Exporting the corpse-run forms and
		-- the developer test mount would be exporting work not worth doing.
		if entry.rec and entry.rec.stub and entry.rec.obtainable ~= false then
			rows[#rows + 1] = entry
		end
	end
	table.sort(rows, function(a, b) return (a.name or "") < (b.name or "") end)

	if #rows == 0 then
		MM:Print("Nothing uncatalogued — every journal mount has a record.")
		return
	end

	local out = { ("-- %d journal mounts with no record. Generated by /mm stubs."):format(#rows) }
	out[#out + 1] = "-- Names and spellIDs are the journal's own. `expansion` is left nil"
	out[#out + 1] = "-- because the journal does not state it."
	out[#out + 1] = "MM.AddMounts({"
	for _, entry in ipairs(rows) do
		local rec = entry.rec
		out[#out + 1] = ("  { name = %q, spellID = %s, expansion = nil, category = %q, obtainable = true,")
			:format(entry.name or "?", tostring(entry.spellID or "nil"), rec.category or "UNKNOWN")
		-- Blizzard's journal source text is multi-line and carries money icons.
		-- Emitting it raw produced Lua string literals with real newlines in
		-- them, which had to be cleaned by hand on the way back in.
		local src = (rec.source or "Unknown source"):gsub("%s*\n%s*", " — "):gsub("%s+", " ")
		out[#out + 1] = ("    source = %q,"):format(src)
		out[#out + 1] = ("    effort = 3 },")
	end
	out[#out + 1] = "})"

	MM.Diagnostics.ShowExport(table.concat(out, "\n"),
		("%d uncatalogued journal mounts"):format(#rows))
end)

------------------------------------------------------------
-- /mm spells — backfill spellIDs from the journal itself
------------------------------------------------------------
-- Roughly a third of records identify their mount by NAME alone, which is the
-- single weakness behind every duplicate and mismatch this project has found.
--
-- Scraping the fix out of Wowhead was the wrong instinct: the CLIENT already
-- holds the answer. Every journal entry carries its name and spellID, and the
-- Scanner has already matched each record to its entry. The id was there all
-- along and simply never written back.
--
-- This emits the backfill as ready-to-paste Lua. It is authoritative -- the
-- journal is the game's own data, not a third party's index of it -- and it
-- covers every matched record at once.
MM:On("MM_SPELLS_EXPORT", function()
	local rows, byName = {}, {}
	for _, entry in pairs(S.byMountID) do
		local rec = entry.rec
		-- only records that MATCHED a journal entry and lack an id of their own
		if rec and not rec.stub and not rec.spellID and entry.spellID and rec.name then
			byName[rec.name] = byName[rec.name] or {}
			tinsert(byName[rec.name], entry.spellID)
		end
	end
	-- A name covering SEVERAL journal entries cannot be given one id -- "Magic
	-- Rooster" is four separate journal mounts sharing a name. Emitting any of
	-- them would be arbitrary, so they are called out instead of guessed.
	local ambiguous = {}
	for name, ids in pairs(byName) do
		if #ids == 1 then
			rows[#rows + 1] = { name = name, spellID = ids[1] }
		else
			table.sort(ids)
			tinsert(ambiguous, ("%s -> %d journal entries (%s)")
				:format(name, #ids, table.concat(ids, ", ")))
		end
	end
	table.sort(rows, function(a, b) return a.name:lower() < b.name:lower() end)

	if #rows == 0 then
		MM:Print("Every matched record already carries a spellID.")
		return
	end

	local out = {
		("-- %d spellIDs backfilled from the mount journal. Generated by /mm spells."):format(#rows),
		"-- The journal is the game's own data: these are exact, not inferred.",
		"local _, MM = ...",
		"",
	}
	for _, r in ipairs(rows) do
		out[#out + 1] = ("MM.OverrideMount(%q, { spellID = %d })"):format(r.name, r.spellID)
	end
	if #ambiguous > 0 then
		out[#out + 1] = ""
		out[#out + 1] = "-- NOT emitted: one record name, several journal entries."
		out[#out + 1] = "-- These need splitting into separate records first."
		for _, line in ipairs(ambiguous) do out[#out + 1] = "--   " .. line end
	end
	MM.Diagnostics.ShowExport(table.concat(out, "\n"),
		("%d spellIDs from the journal"):format(#rows))
end)

