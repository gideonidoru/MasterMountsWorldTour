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
-- The three zones where an ASSAULT runs. Kept separate from WATCHED because
-- WATCHED now also holds every map a treasure or a rotating event sits on, and
-- only these three want their world quests read.
local ASSAULT_MAPS = { [1543] = true, [1527] = true, [1530] = true }

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
-- EVERY WAY THIS CLIENT WILL HAND OUT POINTS OF INTEREST, not the one we knew.
--
-- A Grand Hunts banner sat on the Dragon Isles map, on screen, with a timer and
-- a reward line, while GetAreaPOIForMap on that same map returned nothing at
-- all in the same session. So that function is not where this kind of POI
-- lives -- Blizzard has split retrieval into typed getters, and we were asking
-- exactly one of them.
--
-- The names are DISCOVERED rather than listed. Writing out a guess at
-- "GetEventsForMap" would be the same mistake as guessing a quest id: it might
-- be right today and it is not knowledge. Anything the client exposes ending
-- in ForMap is asked, and only what comes back as a list of numbers is used.
A.poiSources = A.poiSources or {}

local function poiIDs(mapID)
	local api = C_AreaPoiInfo
	if type(api) ~= "table" then return nil end
	local seen, out = {}, {}
	for name, fn in pairs(api) do
		if type(fn) == "function" and type(name) == "string" and name:find("ForMap$") then
			local ok, ids = pcall(fn, mapID)
			if ok and type(ids) == "table" then
				local got = 0
				for _, id in ipairs(ids) do
					if type(id) == "number" then
						got = got + 1
						if not seen[id] then seen[id] = true; out[#out + 1] = id end
					end
				end
				-- Which getter actually produced anything, for the report.
				if got > 0 then
					A.poiSources[name] = (A.poiSources[name] or 0) + got
				end
			end
		end
	end
	return out
end

local function poiNames(mapID)
	local api = C_AreaPoiInfo
	if not api then return end
	local ids = poiIDs(mapID)
	if not ids or #ids == 0 then return end
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
					-- THE TWO FIELDS SEPARATELY, as well as joined.
					-- `text` above concatenates name and description so an
					-- assault whose wording sits in either one still matches.
					-- A portal carries its destination in ONE of them --
					-- Eversong's portal room reads name "Portal Room",
					-- description "Portal to Orgrimmar" -- so a reader
					-- looking for a destination needs them unglued.
					rawName = MM.Util.ReadableString(info.name),
					rawDesc = MM.Util.ReadableString(info.description),
					timeString = info.timeString, position = info.position,
					-- WHERE THE REWARD LINE ACTUALLY IS. AreaPOIInfo carries no
					-- reward field at all -- checked against the client's own
					-- structure -- and the "Rewards available:" line a player
					-- reads comes out of this widget set. Kept, not read: this
					-- runs for every POI on seventeen maps, and only the one
					-- that matches a gate is worth expanding.
					widgetSet = info.tooltipWidgetSet,
					mapID = mapID }
			end
		end
	end
	return out
end

-- Points of interest on any map, for readers other than the assault gate.
-- The portal learner uses this to read both ends of a portal from its POIs.
A.PoisForMap = poiNames

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
		-- QUESTS ONLY WHERE ASSAULTS LIVE.
		--
		-- questEntries calls RequestLoadQuestByID for every world quest on the
		-- map, and this table grew from three maps to seventeen when treasures
		-- and the Grand Hunt were added. Firing a burst of quest-load requests
		-- across fourteen extra maps is the kind of cost that gets reported as
		-- "this addon is heavy".
		--
		-- THE ROTATING ZONES REALLY DO NOT NEED IT, and the reason is worth
		-- stating because this was briefly widened on the theory that they
		-- might. Whether a Grand Hunt is a task quest underneath is beside the
		-- point: the banner's own description says which bag is on offer, the
		-- Epic one is what carries the mount, and it is only on offer for a
		-- player who has not taken it this week. That is the entire signal --
		-- available, and worth going to -- and it comes off the POI list.
		local quests = ASSAULT_MAPS[mapID] and questEntries(mapID) or nil
		if entries or quests then
			any = true
			entries = entries or {}
			for _, e in ipairs(quests or {}) do entries[#entries + 1] = e end
			A.active[mapID] = entries
		end
	end
	A.scanned = any
	-- The banner answers a question the turn-in watcher can only answer live.
	--
	-- MARKS ONLY, NEVER UNMARKS. A recorded turn-in is direct evidence that the
	-- player did the thing; this is an inference from a reward tier. Direct
	-- evidence wins, so a downgraded bag can close a gate but a full one is not
	-- allowed to reopen one -- the weekly store expires on its own at reset,
	-- which is the honest way for it to come back.
	for key, gate in pairs(A.rotatingGates) do
		if not A.WeeklyDone(key) and A.FirstRewardAvailable(gate) == false then
			A.MarkWeeklyDone(key)
			MM:Print("%s: the first run this week is already spent — off the "
				.. "plan until the weekly reset.", gate.label or key)
		end
	end
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
	for _, mapID in ipairs(A.gateMaps[gate.key] or gate.maps or {}) do
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
							-- CARRIED, or the reward read below is dead code.
							-- This table is rebuilt from the entry rather than
							-- passed through, so anything the caller needs has
							-- to be named here -- and the widget set is where
							-- the reward tier lives.
							widgetSet = e.widgetSet, poiID = e.poiID,
						}
					end
				end
			end
		end
	end
	return nil
end

-- Has the first completion of the week been spent?
--
--   true   the banner is up and still offering the first-run reward
--   false  the banner is up and offering something lesser -- it has been taken
--   nil    CANNOT TELL, and that is most of the time
--
-- The nil case is the whole discipline here. A hunt runs in ONE of four zones
-- and rotates, so a missing banner means it is running elsewhere, or the zone
-- is not loaded, or the map is filtered -- none of which is "done". Absence
-- already hid this very goal once by being read as an answer; it is not one.
-- Every string a widget set will give up, without naming a single widget type.
--
-- A set is a list of {widgetID, widgetType}, and the text lives behind a
-- different Get...VisualizationInfo call per type -- around thirty of them.
-- Mapping type numbers to function names would be a table of guesses that
-- rots the first time Blizzard adds a type. Asking every visualization
-- function and keeping what answers costs a few dozen pcalls, happens only for
-- a POI that already matched a gate, and cannot go stale.
function A.WidgetText(setID)
	local W = C_UIWidgetManager
	if not (setID and type(W) == "table" and W.GetAllWidgetsBySetID) then return nil end
	local ok, widgets = pcall(W.GetAllWidgetsBySetID, setID)
	if not (ok and type(widgets) == "table") then return nil end
	local parts = {}
	for _, w in ipairs(widgets) do
		local id = w and w.widgetID
		if id then
			for name, fn in pairs(W) do
				if type(fn) == "function" and type(name) == "string"
					and name:find("^Get") and name:find("VisualizationInfo$") then
					local ok2, info = pcall(fn, id)
					if ok2 and type(info) == "table" then
						for _, v in pairs(info) do
							-- Client strings, so through the safe read: a
							-- secret one must degrade rather than throw.
							local str = type(v) == "string" and MM.Util.ReadableString(v)
							if str and str ~= "" then parts[#parts + 1] = str end
						end
					end
				end
			end
		end
	end
	if #parts == 0 then return nil end
	return table.concat(parts, " ")
end

function A.FirstRewardAvailable(gate)
	if not (gate and A.scanned and gate.firstReward) then return nil end
	-- FindRotating walks every map the gate declares, so this inherits the
	-- rotation rather than guessing which zone to look in.
	local live = A.FindRotating(gate)
	if not (live and live.name) then return nil end
	-- The banner's own text, PLUS whatever its tooltip widgets say. The reward
	-- tier is only ever in the second of those.
	local hay = live.name
	local extra = live.widgetSet and A.WidgetText(live.widgetSet)
	if extra then hay = hay .. " " .. extra end
	hay = hay:lower()
	for _, needle in ipairs(gate.firstReward) do
		if needle and hay:find(needle:lower(), 1, true) then return true end
	end
	-- A banner with no readable tooltip at all is not evidence that the reward
	-- was taken -- it is the same nothing as no banner. Only text we could
	-- actually read may say "already spent".
	if not extra then return nil end
	return false
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
-- PER CHARACTER, because the lockout is.
--
-- This lived on the account, and that is the one thing it cannot be: a Grand
-- Hunt's first run each week is per character, which is the entire premise of
-- reading the banner -- the reward tier it shows is what THIS character would
-- get. Marking it done on one character therefore told every other character
-- the hunt was spent, hiding work they had not done. Exactly the failure the
-- gate exists to prevent, pointed the wrong way.
--
-- The old account-wide table is left where it is rather than migrated. It
-- cannot be split back into per-character truth -- one entry, six characters,
-- no way to know which one earned it -- and inventing an answer for five of
-- them is worse than letting a stale week expire on its own.
local function weeklyStore()
	MM.cdb.weeklyDone = MM.cdb.weeklyDone or {}
	return MM.cdb.weeklyDone
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
-- Per gate: every map worth SEARCHING, which includes the one the zones sit in.
A.gateMaps = {}

-- The map a zone SITS IN, asked of the client rather than written down.
--
-- A Grand Hunt banner is not on any of the four zone maps -- a scan from
-- inside the Dragon Isles returns Dreamsurge, the fishing holes, Maruukai and
-- no hunt -- so the four maps a record names are not, on their own, where the
-- thing being looked for lives. Event POIs plainly do come back remotely, so
-- the gap is WHICH map is asked, not whether asking works.
--
-- The containing map is the obvious next place and it must not be a number
-- typed in from memory: parentMapID comes from the client, so this keeps
-- working when Blizzard renumbers something, and costs one POI call per map.
local function parentOf(mapID)
	if not (C_Map and C_Map.GetMapInfo) then return nil end
	local ok, info = pcall(C_Map.GetMapInfo, mapID)
	if not (ok and info and info.parentMapID and info.parentMapID > 0) then return nil end
	return info.parentMapID, MM.Util.ReadableString(info.name)
end

local function collectRotating()
	wipe(A.rotatingGates)
	for _, rec in ipairs(MM.DBList or {}) do
		if rec.rotating and rec.rotating.key then
			A.rotatingGates[rec.rotating.key] = rec.rotating
			-- WHERE TO LOOK, which is not the same as where the event runs.
			--
			-- A record names the four zones a Grand Hunt rotates between, and
			-- that is correct -- but the banner announcing it sits on the map
			-- ABOVE them. The scan already covers that map; the search did not,
			-- so the POI was found, listed in the report, and then not seen by
			-- the only code that wanted it.
			--
			-- Declared maps plus whatever contains them, kept beside the gate
			-- rather than written into the shipped record.
			local look = {}
			for _, mapID in ipairs(rec.rotating.maps or {}) do
				look[#look + 1] = mapID
				local parent = parentOf(mapID)
				if parent then
					local dupe = false
					for _, m in ipairs(look) do if m == parent then dupe = true break end end
					if not dupe then look[#look + 1] = parent end
				end
			end
			A.gateMaps[rec.rotating.key] = look
			-- Watch what contains the declared zones as well as the zones.
			-- POI ONLY -- these do not join the quest scan, which is the
			-- expensive half and is not what is missing here.
			for _, mapID in ipairs(rec.rotating.maps or {}) do
				local parent = parentOf(mapID)
				if parent and not WATCHED[parent] then
					local pi = C_Map.GetMapInfo and C_Map.GetMapInfo(parent)
					WATCHED[parent] = (pi and MM.Util.ReadableString(pi.name))
						or ("map " .. parent)
				end
			end
		end
	end
	-- Every map a record wants watched, gathered from the records themselves.
	-- A treasure names an object on ONE map -- its own zone -- so the scan has
	-- to cover those maps too, and hardcoding a second list would go stale the
	-- first time a record moved.
	for _, rec in ipairs(MM.DBList or {}) do
		-- Ask the CLIENT for the name rather than printing "map 1970". Several
		-- records store a mapID with no name, and the report listed four of
		-- them as bare numbers -- which is the diagnostic being less readable
		-- than the thing it describes.
		local function label(mapID, fallback)
			if fallback then return fallback end
			local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
			return (info and MM.Util.ReadableString(info.name)) or ("map " .. mapID)
		end
		if rec.poi and rec.zone and rec.zone.mapID and not WATCHED[rec.zone.mapID] then
			WATCHED[rec.zone.mapID] = label(rec.zone.mapID, rec.zone.name)
		end
		for _, mapID in ipairs((rec.rotating and rec.rotating.maps) or {}) do
			if not WATCHED[mapID] then WATCHED[mapID] = label(mapID) end
		end
	end
end
MM:On("MM_LOGIN", function()
	collectRotating()
	-- Gates first, THEN ask about them: the refresh only looks at keys that are
	-- currently declared, so the order is load-bearing rather than tidy.
	-- Resolved at call time, which is long after this file finishes loading.
	local caughtUp = A.RefreshWeeklyFromQuests and A.RefreshWeeklyFromQuests() or 0
	if caughtUp > 0 then
		MM:Print("%d weekly event%s already done this week — taken off the plan.",
			caughtUp, caughtUp == 1 and "" or "s")
	end
end)

------------------------------------------------------------
-- A named object on one map: treasures
------------------------------------------------------------
-- A treasure sits at a fixed point, but the record only stores the ZONE for
-- most of them -- so the route aimed at a zone centre or a hand-typed guess.
-- The map POI carries the exact point, and the client only shows it while the
-- treasure is still there for YOU.
--
-- ABSENCE PROVES NOTHING, and nothing here treats it as proof. A POI can be
-- missing because the treasure is looted, or undiscovered, or filtered off the
-- map, or the zone is not loaded. So this only ever IMPROVES a location; it
-- never gates a goal, never marks one complete and never hides one. A miss
-- falls back to whatever the record already said.
function A.FindPOI(rec)
	if not (rec and rec.poi and A.scanned) then return nil end
	local mapID = rec.zone and rec.zone.mapID
	if not mapID then return nil end
	local list = needles(rec.poi)
	for _, e in ipairs(A.active[mapID] or {}) do
		local hay = e.name and e.name:lower()
		if hay and e.position then
			for _, needle in ipairs(list) do
				if needle and hay:find(needle:lower(), 1, true) then
					return {
						mapID = mapID,
						zone = rec.zone.name or WATCHED[mapID],
						x = e.position.x and (e.position.x * 100),
						y = e.position.y and (e.position.y * 100),
						name = e.name,
					}
				end
			end
		end
	end
	return nil
end

-- A LEARNED QUEST ID IS NOT AN INVENTED ONE.
--
-- Completion was only ever seen live, on QUEST_TURNED_IN. Turn the hunt in
-- while the addon is not watching -- another session, before this shipped, an
-- alt -- and it stays at the top of the plan all week with no way to say
-- otherwise. Writing a quest id into the data was refused, and rightly: nobody
-- had verified one.
--
-- Watching one arrive is a different thing entirely. The id the CLIENT hands
-- us on a turn-in that matched by title is observed, not guessed, so it is
-- kept and asked about on later logins. The first completion still has to be
-- seen; every one after it is answerable cold.
local function questStore()
	MM.db.rotatingQuests = MM.db.rotatingQuests or {}
	return MM.db.rotatingQuests
end

-- Ask the client about the ids it taught us. Cheap, and only for gates that
-- are not already known to be done.
function A.RefreshWeeklyFromQuests()
	if not (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) then return 0 end
	local learned, found = questStore(), 0
	for key, id in pairs(learned) do
		if A.rotatingGates[key] and not A.WeeklyDone(key) then
			local ok, done = pcall(C_QuestLog.IsQuestFlaggedCompleted, id)
			if ok and done then
				A.MarkWeeklyDone(key)
				found = found + 1
			end
		end
	end
	return found
end

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
					if questID then questStore()[key] = questID end
					MM:Print("%s done for the week — it comes off the plan until "
						.. "the weekly reset.", gate.label or key)
					return
				end
			end
		end
	end
end)
