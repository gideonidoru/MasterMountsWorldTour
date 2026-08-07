-- Master Mounts: rotating zone assaults.
--
-- Several mounts drop only while a specific assault is running, and the assaults
-- rotate:
--
--   The Maw (9.1)   one covenant's assault per week. Cache of the Ascended,
--                   War Chest of the Undying Army, War Chest of the Wild Hunt
--                   and Harvester's War Chest each come from their own.
--   Uldum (8.3)     Aqir, Amathet and Black Empire assaults take turns, and
--                   each brings its own rare spawns -- Corpse Eater with the
--                   Aqir, Rotfeaster with the Amathet, Ishak of the Four Winds
--                   with the Black Empire.
--   Vale (8.3)      the Mogu assault carries all four of the Vale's mounts.
--
-- Recommending all of them at once is wrong in the same way the Necroray
-- Callings were: the rare is not in the world today, and routing the player
-- there achieves nothing.
--
-- Detection follows the pattern that finally worked for Callings -- ask what is
-- ACTUALLY live and read its name -- rather than hardcoding quest ids that would
-- rot. Two independent sources are read, because either can be empty:
--
--   1. C_AreaPoiInfo  the assault banner on the zone map. This is the strongest
--                     signal: it names the assault directly and is readable from
--                     anywhere in the world, which is exactly what a planner
--                     standing in Valdrakken needs.
--   2. C_TaskQuest    the assault's world quests, whose titles also carry the
--                     name. Backs up the POI when the POI is missing.
--
-- Anything unresolved fails to "unknown", never to "available".
local _, MM = ...

MM.Assaults = {}
local A = MM.Assaults

A.active = {}      -- [mapID] = { { name = ..., source = "poi"|"quest", questID = ... }, ... }
A.scanned = false

-- Zones whose assaults gate a mount. Nothing else is worth polling.
local WATCHED = {
	[1543] = "The Maw",
	[1527] = "Uldum",
	[1530] = "Vale of Eternal Blossoms",
	-- The four Dragonflight zones, for the Grand Hunt. It rotates between
	-- them, so a record cannot name one and be right for more than a few
	-- hours -- which is exactly what sent someone to the wrong waypoint.
	[2022] = "The Waking Shores",
	[2023] = "Ohn'ahran Plains",
	[2024] = "The Azure Span",
	[2025] = "Thaldraszus",
}

------------------------------------------------------------
-- Reading what is live
------------------------------------------------------------
local function poiNames(mapID)
	local api = C_AreaPoiInfo
	if not (api and api.GetAreaPOIForMap) then return end
	local ok, ids = pcall(api.GetAreaPOIForMap, mapID)
	if not (ok and type(ids) == "table") then return end
	local out = {}
	for _, poiID in ipairs(ids) do
		local ok2, info = pcall(api.GetAreaPOIInfo, mapID, poiID)
		if ok2 and info then
			-- description carries the assault's flavour line on some banners and
			-- the name on others, so both are worth matching against
			-- Both of these are client-supplied strings and both are
			-- concatenated below, so both go through the safe read.
			local text = MM.Util.ReadableString(info.name)
			local desc = MM.Util.ReadableString(info.description)
			if desc then
				text = (text and (text .. " " .. desc)) or desc
			end
			if text and text ~= "" then
				-- The POSITION, kept. A gate that only answers "is it running"
				-- is enough for an assault, which owns its whole zone. A Grand
				-- Hunt MOVES BETWEEN ZONES and sits at a point inside one, so
				-- the answer has to carry where as well as whether.
				out[#out + 1] = { name = text, source = "poi", poiID = poiID,
					timeString = info.timeString, position = info.position,
					mapID = mapID }
			end
		end
	end
	return out
end

local function questEntries(mapID)
	if not (C_TaskQuest and C_TaskQuest.GetQuestsForPlayerByMapID) then return end
	local ok, list = pcall(C_TaskQuest.GetQuestsForPlayerByMapID, mapID)
	if not (ok and type(list) == "table") then return end
	local out = {}
	for _, q in ipairs(list) do
		local questID = q.questId or q.questID
		if questID then
			-- Titles are unreadable until the quest is cached, the same trap that
			-- hid Calling titles for four rounds.
			if C_QuestLog.RequestLoadQuestByID then
				pcall(C_QuestLog.RequestLoadQuestByID, questID)
			end
			out[#out + 1] = {
				questID = questID, source = "quest",
				name = C_QuestLog.GetTitleForQuestID
					and C_QuestLog.GetTitleForQuestID(questID) or nil,
			}
		end
	end
	return out
end

function A.Scan()
	wipe(A.active)
	local any = false
	for mapID in pairs(WATCHED) do
		local entries = poiNames(mapID)
		local quests = questEntries(mapID)
		if entries or quests then
			any = true
			entries = entries or {}
			for _, e in ipairs(quests or {}) do entries[#entries + 1] = e end
			A.active[mapID] = entries
		end
	end
	A.scanned = any
	if MM.Availability and MM.Availability.InvalidateStatus then
		MM.Availability.InvalidateStatus()
	end
	MM:Fire("MM_ASSAULTS")
end

-- Fill in quest names as the server answers.
MM:RegisterGameEvent("QUEST_DATA_LOAD_RESULT", function(questID, success)
	if not success then return end
	for _, entries in pairs(A.active) do
		for _, e in ipairs(entries) do
			if e.questID == questID and not e.name and C_QuestLog.GetTitleForQuestID then
				e.name = C_QuestLog.GetTitleForQuestID(questID)
				if e.name then MM:Fire("MM_ASSAULTS") end
			end
		end
	end
end)

MM:On("MM_SCANNED", function() C_Timer.After(5, A.Scan) end)
MM:RegisterGameEvent("QUEST_LOG_UPDATE", function()
	-- cheap enough at this cadence, and assaults change on a weekly reset
	if not A.scanned then A.Scan() end
end)

------------------------------------------------------------
-- Gate
------------------------------------------------------------
-- rec.assault = { mapID = 1530, zone = "...", label = "Mogu", match = { "Mogu", "Warring Clans" } }
--
-- `match` is a list because the same assault is worded differently by its map
-- banner and by its world quests, and being wrong about the wording must not
-- read as "the assault isn't running". Any needle hitting is a hit.
local function needles(gate)
	local m = gate.match or gate.label
	if type(m) == "table" then return m end
	return { m }
end

-- Returns a status and detail. AVAILABLE only when something live in that zone
-- names the assault; ROTATION when the zone was read and it is not there;
-- UNKNOWN when the zone could not be read at all.
function A.Evaluate(gate)
	if not gate then return nil end
	local zone = gate.zone or "that zone"
	local label = gate.label or (type(gate.match) == "string" and gate.match) or zone
	local list = needles(gate)
	-- "assault" is wrong for a timed world event, and a gate that explains
	-- itself in the wrong words is a gate the player argues with.
	local kind = gate.kind or "assault"

	local entries = A.active[gate.mapID]
	if not (A.scanned and entries) then
		return "UNKNOWN",
				("Only while %s is running — what's live there isn't readable yet")
					:format(label)
	end

	local unnamed = 0
	for _, e in ipairs(entries) do
		if e.name then
			local hay = e.name:lower()
			for _, needle in ipairs(list) do
				if needle and hay:find(needle:lower(), 1, true) then
					local detail = ("%s is running — %s"):format(label, e.name)
					if e.timeString and e.timeString ~= "" then
						detail = detail .. (" (%s left)"):format(e.timeString)
					end
					return "AVAILABLE", detail
				end
			end
		elseif e.source == "quest" then
			unnamed = unnamed + 1
		end
	end

	-- A quest we could not name might be the one we are looking for.
	if unnamed > 0 then
		return "UNKNOWN",
			("Couldn't read %d of %s's active quests — can't confirm %s")
				:format(unnamed, zone, label)
	end

	return "ROTATION",
		("%s isn't running right now — it comes back on its %s"):format(label,
			kind == "event" and "timer" or "rotation")
end

-- /mm assaults — what is live in the watched zones, and under what name.
-- The names printed here are the ground truth for the `match` needles: if a
-- mount says ROTATION while its assault is visibly running, the wording below is
-- what the needle has to match.
MM:On("MM_ASSAULTS_DEBUG", function()
	A.Scan()
	MM:Print("Assault scan: %s", A.scanned and "zones readable" or "|cffff4444no data|r")
	for mapID, zoneName in pairs(WATCHED) do
		local entries = A.active[mapID]
		MM:Print("|cff33c1ff%s|r (map %d): %s", zoneName, mapID,
			entries and (#entries .. " live entries") or "unreadable")
		for _, e in ipairs(entries or {}) do
			MM:Print("    [%s] %s%s", e.source,
				e.name or "|cff9a9a9aname not cached yet|r",
				(e.timeString and e.timeString ~= "") and (" — " .. e.timeString) or "")
		end
	end
	MM:Print("Records gated on an assault report ROTATION until their name appears above.")
end)

------------------------------------------------------------
-- Rotating world events: the Grand Hunt
------------------------------------------------------------
-- An assault gate answers "is this running in THAT zone". A Grand Hunt is the
-- other shape: it is always running SOMEWHERE, and the question is which of
-- four zones and whereabouts inside it.
--
-- Reported from play: the route sent someone to a fixed Ohn'ahran Plains
-- coordinate, because that is what the record said. It is right roughly a
-- quarter of the time.
--
-- Nothing here is a guess about zones or quest ids. The hunt announces itself
-- as an area POI in whichever zone it is in, and the POI carries its own
-- position -- the same scan the assault gates already run, now keeping the
-- coordinate it was throwing away.
function A.FindRotating(gate)
	if not (gate and A.scanned) then return nil end
	local list = needles(gate)
	for _, mapID in ipairs(gate.maps or {}) do
		for _, e in ipairs(A.active[mapID] or {}) do
			local hay = e.name and e.name:lower()
			if hay then
				for _, needle in ipairs(list) do
					if needle and hay:find(needle:lower(), 1, true) then
						return {
							mapID = e.mapID or mapID,
							zone = WATCHED[e.mapID or mapID],
							x = e.position and e.position.x and (e.position.x * 100),
							y = e.position and e.position.y and (e.position.y * 100),
							name = e.name, timeString = e.timeString,
						}
					end
				end
			end
		end
	end
	return nil
end

------------------------------------------------------------
-- "Have I done this one this week?"
------------------------------------------------------------
-- NO QUEST ID IS INVENTED HERE, and none is needed.
--
-- The obvious approach is to look up the hunt's weekly quest and ask
-- IsQuestFlaggedCompleted. That means writing down a number nobody has
-- verified, which is the one thing this database does not do.
--
-- What the client will tell us without being asked: a quest was turned in, and
-- how long until the weekly reset. If a turn-in happens while a rotating gate
-- is live and the quest's title matches the gate, the player did the thing --
-- and `now + secondsUntilWeeklyReset` is exactly when that stops being true.
-- Stored per gate, self-healing, and wrong for at most one reset if the match
-- is ever a false positive.
local function weeklyStore()
	MM.db.weeklyDone = MM.db.weeklyDone or {}
	return MM.db.weeklyDone
end

function A.WeeklyDone(key)
	if not key then return false end
	local until_ = weeklyStore()[key]
	if not until_ then return false end
	local now = (time and time()) or 0
	if now >= until_ then
		weeklyStore()[key] = nil   -- reset has passed; forget it
		return false
	end
	return true, until_
end

function A.MarkWeeklyDone(key)
	if not key then return end
	local now = (time and time()) or 0
	local left = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset
		and C_DateAndTime.GetSecondsUntilWeeklyReset() or nil
	-- Without a reset time there is nothing honest to store: a completion with
	-- no expiry would hide the goal forever.
	if not left or left <= 0 then return end
	weeklyStore()[key] = now + left
	if MM.Availability and MM.Availability.InvalidateStatus then
		MM.Availability.InvalidateStatus()
	end
	MM:Fire("MM_PLAN_CHANGED")
end

-- Gates that want a weekly turn-in watched.
--
-- DISCOVERED, NOT REGISTERED. The data layer cannot call into a module: every
-- data file loads before every module, so a RegisterRotating() call at file
-- scope would be a nil index at best and a silent no-op at worst. Walking the
-- database once is the direction that actually works, and it means declaring
-- `rotating` on a record is the whole of adding one.
A.rotatingGates = {}

local function collectRotating()
	wipe(A.rotatingGates)
	for _, rec in ipairs(MM.DBList or {}) do
		if rec.rotating and rec.rotating.key then
			A.rotatingGates[rec.rotating.key] = rec.rotating
		end
	end
end
MM:On("MM_LOGIN", collectRotating)

MM:RegisterGameEvent("QUEST_TURNED_IN", function(questID)
	if not next(A.rotatingGates) then return end
	local title = MM.Util.ReadableString(C_QuestLog.GetTitleForQuestID
		and C_QuestLog.GetTitleForQuestID(questID))
	if not title then return end
	local hay = title:lower()
	for key, gate in pairs(A.rotatingGates) do
		if not A.WeeklyDone(key) then
			for _, needle in ipairs(needles(gate)) do
				if needle and hay:find(needle:lower(), 1, true) then
					A.MarkWeeklyDone(key)
					MM:Print("%s done for the week — it comes off the plan until "
						.. "the weekly reset.", gate.label or key)
					return
				end
			end
		end
	end
end)
