-- Master Mounts utility helpers: map resolution, world positions, math for
-- attempt estimates, formatting.
local _, MM = ...

MM.Util = {}
local U = MM.Util

------------------------------------------------------------
-- Zone name -> uiMapID resolution (records may carry only a zone name)
------------------------------------------------------------
local nameToMap, nameToMaps, lowerToMap

local function buildMapIndex()
	nameToMap, nameToMaps, lowerToMap = {}, {}, {}
	-- Index EVERY map type. Restricting to Zone/Continent/Dungeon/Micro used
	-- to drop battlegrounds and special maps (Alterac Valley, Stormshield,
	-- Telogrus Rift), which then resolved to nothing.
	--
	-- When several maps share a name (Karazhan matches 35, Dalaran 12), an
	-- OUTDOOR zone is almost always the travel destination we want, so
	-- prefer Zone/Continent over instance floors regardless of ID order.
	local RANK = {
		[Enum.UIMapType.Zone or 3] = 1,
		[Enum.UIMapType.Continent or 2] = 2,
		[Enum.UIMapType.Micro or 5] = 3,
		[Enum.UIMapType.Dungeon or 4] = 4,
	}
	local bestRank = {}

	for mapID = 1, 3000 do
		local info = C_Map.GetMapInfo(mapID)
		if info and info.name and info.name ~= "" then
			local rank = RANK[info.mapType] or 5
			local prev = bestRank[info.name]
			if not prev or rank < prev then
				bestRank[info.name] = rank
				nameToMap[info.name] = mapID
			end
			-- A CASE-FOLDED INDEX ALONGSIDE THE EXACT ONE.
			--
			-- The client names maps "The Forbidden Reach"; several callers hold
			-- the name lowercased, because they key their own tables that way.
			-- Those lookups all missed, silently, and the cost was not obvious:
			-- the travel graph fell back to a crude zone-size approximation for
			-- every cross-zone distance, and a zone with no flight point of its
			-- own became unreachable entirely -- "no way to reach the forbidden
			-- reach from the graph" with 2,180 positioned nodes loaded.
			--
			-- Same ranking, so an outdoor zone still beats an instance floor.
			local lower = info.name:lower()
			local prevLower = bestRank["\1" .. lower]
			if not prevLower or rank < prevLower then
				bestRank["\1" .. lower] = rank
				lowerToMap[lower] = mapID
			end
			nameToMaps[info.name] = nameToMaps[info.name] or {}
			tinsert(nameToMaps[info.name], mapID)
		end
	end
end

-- Zone strings in the data are sometimes qualified or compound:
--   "Blackrock Depths (Brewfest)"      -> "Blackrock Depths"
--   "Dalaran (Northrend)"              -> "Dalaran"
--   "Boralus / Dazar'alor"             -> "Boralus"
--   "Kelp'thar Forest, Vashj'ir"       -> "Kelp'thar Forest"
--   "Stratholme - Main Gate"           -> "Stratholme"
-- Yield progressively looser candidates so a qualified name still lands.
-- Names our data uses that are not map names on the client.
--
-- Each entry is an ORDERED fallback list, tried after the literal name and its
-- generated variants. Getting one wrong costs nothing -- an unresolvable
-- candidate is skipped and the next is tried -- so each list ends with the
-- containing zone, which always exists. That is why these are candidates rather
-- than a lookup table of IDs: a wrong ID misroutes silently, a wrong name simply
-- falls through.
local ZONE_ALIASES = {
	["King's Rest"] = { "Zuldazar" },
	["Trial of the Grand Crusader"] = { "Trial of the Crusader", "Icecrown" },
	["Return to Karazhan: Lower"] = { "Return to Karazhan", "Karazhan", "Deadwind Pass" },
	["Return to Karazhan: Upper"] = { "Return to Karazhan", "Karazhan", "Deadwind Pass" },
	["Operation: Mechagon"] = { "Operation: Mechagon - Workshop",
		"Operation: Mechagon - Junkyard", "Mechagon Island", "Mechagon" },
	["Temple of Ahn'Qiraj"] = { "Ahn'Qiraj: The Fallen Kingdom", "Ahn'Qiraj", "Silithus" },
	["Ruins of Ahn'Qiraj"] = { "Ahn'Qiraj: The Fallen Kingdom", "Ahn'Qiraj", "Silithus" },
	["Liberation of Undermine"] = { "Undermine" },
	-- A tiny islet off Legion Dalaran with no map of its own.
	["Margoss's Retreat"] = { "Dalaran", "Broken Isles" },
	-- Both spellings appear in the 12.1 data; neither exists until it ships.
	["Coiled Isle"] = { "The Coiled Isle" },
}

-- The garrison is whichever one your faction built.
local function garrisonNames()
	return (UnitFactionGroup and UnitFactionGroup("player") == "Horde")
		and { "Frostwall", "Frostwall Garrison" }
		or { "Lunarfall", "Lunarfall Garrison" }
end

local function nameCandidates(name)
	local out = { name }
	local stripped = name:gsub("%s*%b()", ""):gsub("^%s+", ""):gsub("%s+$", "")
	if stripped ~= name and stripped ~= "" then tinsert(out, stripped) end
	for _, sep in ipairs({ " / ", ", ", " - ", ": " }) do
		local head = stripped:match("^(.-)" .. sep:gsub("%p", "%%%0"))
		if head and head ~= "" then tinsert(out, head) end
	end
	-- Authored names that are not map names, tried last so a genuine map always
	-- wins over an alias.
	for _, alias in ipairs(ZONE_ALIASES[name] or ZONE_ALIASES[stripped] or {}) do
		tinsert(out, alias)
	end
	if name:find("Garrison", 1, true) then
		for _, g in ipairs(garrisonNames()) do tinsert(out, g) end
	end
	return out
end

-- When several maps share a name, the type ranking in buildMapIndex picks one,
-- but a map with no world position is useless for routing however well it ranks.
-- Check lazily and only for names that are actually ambiguous; the answer is
-- cached because GetWorldPosFromMapPos is not free.
local routableCache = {}
local function routableMap(name, fallback)
	local cached = routableCache[name]
	if cached ~= nil then return cached or fallback end
	local list = nameToMaps[name]
	if not list or #list < 2 then
		routableCache[name] = false
		return fallback
	end
	for _, id in ipairs(list) do
		local _, world = U.GetWorldPos(id, 50, 50)
		if world then
			routableCache[name] = id
			return id
		end
	end
	routableCache[name] = false
	return fallback
end

------------------------------------------------------------
-- Ambiguous names, resolved from the mount's own context
------------------------------------------------------------
-- "Dalaran" is two places. Which one a record means is not guessable from the
-- name -- but it IS derivable from the mount, because a Legion mount is in
-- Legion's Dalaran and a Wrath mount is in Northrend's.
--
-- Rather than hardcode an expansion-to-continent table (which would be a guess
-- that rots), calibrate from our own data: for each expansion, look at the zone
-- names its records use that resolve UNAMBIGUOUSLY, and record the mapIDs those
-- landed on. uiMapIDs are issued roughly chronologically, so those IDs describe
-- where that expansion lives in the ID space. An ambiguous candidate is then
-- scored by how well it fits.
--
-- Worked example: Legion records resolve Suramar, Azsuna, Val'sharah, Highmountain
-- and Stormheim into the 630-680 band. Of Dalaran's candidates, 125 (Northrend)
-- and 627 (Broken Isles), only 627 is anywhere near that band. Wrath's records
-- calibrate to 114-125, which picks 125. Neither answer was written down; both
-- fall out of the data.
local expansionBands  -- [expansion] = { lo, hi }

local function calibrateBands()
	expansionBands = {}
	local samples = {}
	for _, rec in ipairs(MM.DBList or {}) do
		local exp = rec.expansion
		local zoneName = rec.zone and rec.zone.name
		if exp and zoneName then
			local list = nameToMaps[zoneName]
			-- only unambiguous names inform the calibration; using an ambiguous
			-- one would be circular
			if list and #list == 1 then
				samples[exp] = samples[exp] or {}
				tinsert(samples[exp], list[1])
			end
		end
	end
	for exp, ids in pairs(samples) do
		table.sort(ids)
		-- trim the tails: one mis-tagged record should not stretch a band
		local lo = ids[math.max(1, math.floor(#ids * 0.1))]
		local hi = ids[math.min(#ids, math.ceil(#ids * 0.9))]
		if lo and hi then expansionBands[exp] = { lo, hi } end
	end
end

-- Distance from a mapID to an expansion's calibrated band; 0 means inside it.
local function bandDistance(mapID, exp)
    local band = expansionBands and expansionBands[exp]
    if not band then return nil end
    if mapID < band[1] then return band[1] - mapID end
    if mapID > band[2] then return mapID - band[2] end
    return 0
end

-- Best candidate for `name` given the record that referenced it.
local contextCache = {}
local function resolveForContext(name, rec)
	if not nameToMap then buildMapIndex() end
	local list = nameToMaps[name]
	if not list or #list < 2 then return nil end

	local exp = rec and rec.expansion
	if not exp then return nil end
	if not expansionBands then calibrateBands() end

	local key = name .. "#" .. exp
	local hit = contextCache[key]
	if hit ~= nil then return hit or nil end

	-- An instanced record wants the instance map; an outdoor one wants the zone.
	local wantDungeon = (rec.instance and rec.instance.name) ~= nil
	local best, bestScore
	for _, id in ipairs(list) do
		local info = C_Map.GetMapInfo(id)
		local dist = bandDistance(id, exp)
		if info and dist then
			local isDungeon = (info.mapType == (Enum.UIMapType.Dungeon or 4))
			-- band fit dominates; matching the right KIND of map breaks ties
			local score = dist + ((isDungeon == wantDungeon) and 0 or 500)
			-- A MAP THE ROUTER CANNOT POSITION IS A MAP IT CANNOT ROUTE TO.
			--
			-- "The Forbidden Reach" is four maps; the band-and-kind score picked
			-- one that C_Map cannot turn into world coordinates, so two goals
			-- reached the route with no arrow and a flat cross-continent travel
			-- price. Both were correct handling of a bad choice -- but the
			-- choice was avoidable, and a sibling map with the same name CAN be
			-- positioned.
			--
			-- Penalised rather than disqualified: if no candidate can be
			-- positioned, the best band fit is still the right answer, and the
			-- goal keeps a zone NAME rather than being dropped entirely.
			-- The SECOND return. GetWorldPos yields (continent, world), and
			-- `world` is precisely what Router tests to decide whether a stop
			-- has a position -- so this must ask the same question, or it
			-- would penalise a different thing than the one that matters.
			local _, world = U.GetWorldPos(id, 50, 50)
			if not world then score = score + 250 end
			if not bestScore or score < bestScore then best, bestScore = id, score end
		end
	end
	contextCache[key] = best or false
	return best
end

-- Recalibrate when the database or the client's map set could have changed.
function U.InvalidateMapCache()
	nameToMap, nameToMaps, expansionBands = nil, nil, nil
	wipe(contextCache)
	wipe(routableCache)
end

function U.ResolveMapByName(name)
	if not name then return nil end
	-- a committed, client-resolved ID always beats name lookup: it is
	-- unambiguous where a name is not (two maps are called "Dalaran")
	local resolved = MM.ResolvedIDs and MM.ResolvedIDs.maps and MM.ResolvedIDs.maps[name]
	if resolved then return resolved end
	if not nameToMap then buildMapIndex() end
	for _, candidate in ipairs(nameCandidates(name)) do
		local id = nameToMap[candidate]
		if id then return routableMap(candidate, id) end
	end
	-- Only after every exact match has been tried, so a correctly-cased name
	-- can never be beaten by a case-folded collision.
	for _, candidate in ipairs(nameCandidates(name)) do
		local id = lowerToMap[candidate:lower()]
		if id then return routableMap(candidate, id) end
	end
	-- LAST: a FLIGHT POINT by that name.
	--
	-- A Hearthstone is bound to an inn, and an inn is not a map -- so a bind
	-- in "Har'athir" resolved to nothing and the addon asked the player to go
	-- and stand there. We already ship that name: it is a flight master in
	-- Harandar, in our own flight-point table, and nobody was looking.
	--
	-- Tried only after every map-name match has failed, so a real map always
	-- wins. A flight point tells us the ZONE, which is what the router needs;
	-- it does not pretend to be the inn.
	if MM.FlightPointMapForName then
		local id = MM.FlightPointMapForName(name)
		if id then return id end
	end
	return nil
end

-- EVERY map with this name (a name can exist per-expansion, e.g. Silvermoon
-- City both pre- and post-Midnight). Returns an array, possibly empty.
function U.ResolveMapsByName(name)
	if not name then return {} end
	if not nameToMaps then buildMapIndex() end
	return nameToMaps[name] or {}
end

-- Best uiMapID for a record's zone info, if any.
function U.GetRecordMapID(rec)
	-- a record's own zone wins; otherwise inherit its vendor's location
	local zone = MM.GetRecordLocation and MM.GetRecordLocation(rec) or (rec and rec.zone)
	if not zone then return nil end
	if zone.mapID and C_Map.GetMapInfo(zone.mapID) then return zone.mapID end
	-- The record disambiguates its own zone name where the name cannot.
	local contextual = zone.name and resolveForContext(zone.name, rec)
	if contextual then return contextual end
	return U.ResolveMapByName(zone.name)
end

-- Same disambiguation for an instance name, which callers resolve separately.
function U.ResolveMapForRecord(name, rec)
	if not name then return nil end
	return resolveForContext(name, rec) or U.ResolveMapByName(name)
end

------------------------------------------------------------
-- Continent identity by walking the map parent chain. Version-proof: no
-- hardcoded continent table, so it survives expansions adding new ones.
------------------------------------------------------------
local continentCache = {}

function U.GetContinentMapID(mapID)
	if not mapID then return nil end
	if continentCache[mapID] then return continentCache[mapID] end
	local continentType = (Enum and Enum.UIMapType and Enum.UIMapType.Continent) or 2
	local current, guard = mapID, 0
	while current and guard < 10 do
		guard = guard + 1
		local ok, info = pcall(C_Map.GetMapInfo, current)
		if not ok or not info then break end
		if info.mapType and info.mapType <= continentType then break end
		if not info.parentMapID or info.parentMapID == 0 then break end
		current = info.parentMapID
	end
	continentCache[mapID] = current
	return current
end

function U.IsSameContinent(mapA, mapB)
	if not (mapA and mapB) then return nil end
	local a, b = U.GetContinentMapID(mapA), U.GetContinentMapID(mapB)
	return a ~= nil and a == b
end

------------------------------------------------------------
-- World positions (for routing distance + arrow bearing)
------------------------------------------------------------
function U.GetWorldPos(mapID, x, y) -- x/y in 0-100
	if not (mapID and x and y) then return nil end
	local ok, continent, world = pcall(C_Map.GetWorldPosFromMapPos, mapID,
		CreateVector2D(x / 100, y / 100))
	if not ok or not world then return nil end
	return continent, world
end

function U.PlayerWorldPos()
	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID then return nil end
	local pos = C_Map.GetPlayerMapPosition(mapID, "player")
	if not pos then return nil end
	local continent, world = U.GetWorldPos(mapID, pos.x * 100, pos.y * 100)
	return continent, world, mapID, pos
end

-- Does `a` say the same thing as `b`, only differently?
--
-- Tooltips assemble lines from several sources that each describe the mount, so
-- near-duplicates are the normal case rather than an oddity: a source of
-- "Reward from the achievement Glory of the Uldir Raider" and an estimate of
-- "Achievement: Glory of the Uldir Raider" are one sentence printed twice.
-- Exact-match checks never caught those.
--
-- The test is containment of the significant words, which is deliberately
-- conservative: a false negative prints one redundant line, a false positive
-- hides information. Only the former is acceptable.
local NOISE = {
	["the"] = true, ["a"] = true, ["an"] = true, ["from"] = true, ["of"] = true,
	["reward"] = true, ["drops"] = true, ["drop"] = true, ["for"] = true,
	["in"] = true, ["on"] = true, ["and"] = true, ["to"] = true, ["at"] = true,
}
local function significantWords(text)
	local words = {}
	for word in text:lower():gmatch("[%w'!]+") do
		if not NOISE[word] and #word > 2 then words[#words + 1] = word end
	end
	return words
end

-- "3 / 5" or "40%" is progress, and progress is never a restatement -- it is
-- the one thing on the line the source cannot know. Without this, "Test Token:
-- 0 / 5" was suppressed by "Collect 5 Test Tokens" and the player lost the only
-- number that told them where they stood.
local function carriesProgress(text)
	return text:find("%d+%s*/%s*%d+") ~= nil or text:find("%d+%%") ~= nil
end

function U.Restates(a, b)
	if not (a and b) then return false end
	if a == b then return true end
	if carriesProgress(a) and not carriesProgress(b) then return false end
	local wa = significantWords(a)
	if #wa == 0 then return false end
	local hay = " " .. b:lower() .. " "
	for _, word in ipairs(wa) do
		if not hay:find(word, 1, true) then return false end
	end
	return true
end

-- Ground speed, shared. Router and Teleports each declare this locally as
-- 25 yd/s; anything else needing it should read this rather than add a third
-- copy that can drift out of step with the two that decide travel time.
MM.YARDS_PER_SECOND = 25
MM.YARDS_PER_MINUTE = 25 * 60

function U.WorldDistance(a, b)
	if not (a and b) then return nil end
	local dx, dy = a.x - b.x, a.y - b.y
	return math.sqrt(dx * dx + dy * dy)
end

------------------------------------------------------------
-- Attempt estimates from a drop rate
------------------------------------------------------------
-- Returns mean, median (50% confidence), p90 (90% confidence) attempt counts.
function U.AttemptEstimates(dropPercent)
	if not dropPercent or dropPercent <= 0 or dropPercent >= 100 then return nil end
	local p = dropPercent / 100
	local ln = math.log(1 - p)
	local mean = math.ceil(1 / p)
	local median = math.ceil(math.log(0.5) / ln)
	local p90 = math.ceil(math.log(0.1) / ln)
	return mean, median, p90
end

-- Human line like "~1 in 100 — median 69 tries, 90% by 229 (≈ weeks at 1/week)"
function U.DropEstimateText(rec, attemptsSoFar)
	if not rec or not rec.dropRate then return nil end
	local mean, median, p90 = U.AttemptEstimates(rec.dropRate)
	if not mean then return nil end
	local line = ("~1 in %d — median %d tries, 90%% by %d"):format(mean, median, p90)
	local lockout = rec.attempts or (rec.instance and rec.instance.lockout)
	if lockout == "WEEKLY" then
		line = line .. (" (~%.1f years at 1/week for median)"):format(median / 52)
	elseif lockout == "DAILY" then
		line = line .. (" (~%d days at 1/day for median)"):format(median)
	end
	if attemptsSoFar and attemptsSoFar > 0 then
		line = line .. (" — %d attempts recorded"):format(attemptsSoFar)
	end
	return line
end

------------------------------------------------------------
-- Reputation helpers
------------------------------------------------------------
U.STANDING = {
	["Neutral"] = 4, ["Friendly"] = 5, ["Honored"] = 6,
	["Revered"] = 7, ["Exalted"] = 8,
}

-- Full rep needed from the START of a reaction level up to Exalted.
local BAND = { [4] = 3000, [5] = 6000, [6] = 12000, [7] = 21000 }

function U.RepRemainingToTarget(reaction, currentStanding, nextThreshold, targetReaction)
	if not reaction then return nil end
	targetReaction = targetReaction or 8
	if reaction >= targetReaction then return 0 end
	local remaining = 0
	if nextThreshold and currentStanding then
		remaining = math.max(0, nextThreshold - currentStanding)
	end
	for r = reaction + 1, targetReaction - 1 do
		remaining = remaining + (BAND[r] or 0)
	end
	return remaining
end

------------------------------------------------------------
-- Formatting
------------------------------------------------------------
U.STATUS_COLOR = {
	COLLECTED    = "ff40d860",
	AVAILABLE    = "ffffffff",
	LOCKED       = "ffff9a3c",
	GATED        = "ffffd84d",
	HOLIDAY      = "ff5cb8ff",
	ROTATION     = "ff8fb8e8",
	PREREQ       = "ffd08a5a",
	UNOBTAINABLE = "ff8a8a8a",
	UNKNOWN      = "ffb8a4e0",
}

U.STATUS_LABEL = {
	COLLECTED    = "Collected",
	AVAILABLE    = "Available",
	LOCKED       = "Locked",
	GATED        = "Requirements",
	HOLIDAY      = "Event inactive",
	ROTATION     = "Not today",
	PREREQ       = "Locked",
	UNOBTAINABLE = "Unobtainable",
	UNKNOWN      = "Uncatalogued",
}

function U.Color(status, text)
	local c = U.STATUS_COLOR[status] or "ffffffff"
	return "|c" .. c .. tostring(text) .. "|r"
end

function U.StatusRGB(status)
	local hex = U.STATUS_COLOR[status] or "ffffffff"
	return tonumber(hex:sub(3, 4), 16) / 255,
		tonumber(hex:sub(5, 6), 16) / 255,
		tonumber(hex:sub(7, 8), 16) / 255
end

function U.FormatSeconds(sec)
	if not sec or sec <= 0 then return "now" end
	if sec >= 86400 then return ("%dd %dh"):format(math.floor(sec / 86400), math.floor((sec % 86400) / 3600)) end
	if sec >= 3600 then return ("%dh %dm"):format(math.floor(sec / 3600), math.floor((sec % 3600) / 60)) end
	return ("%dm"):format(math.max(1, math.floor(sec / 60)))
end

function U.Comma(n)
	if not n then return "?" end
	local s, done = tostring(math.floor(n)), false
	repeat
		s, done = s:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
	until done == 0
	return s
end

------------------------------------------------------------
-- Reading a string the client may refuse to hand over
------------------------------------------------------------
-- 12.0 (Midnight) introduced SECRET VALUES. A payload that has always been a
-- string -- an encounter name, a vignette name, a POI name -- arrives as one
-- of these for an addon the client considers tainted, and any string operation
-- on it throws:
--
--   "attempt to perform string conversion on a secret value
--    (execution tainted by 'MasterMountsWorldTour')"
--
-- Reported twice from outside, and the second time from delve combat, which is
-- a different code path from the first: encounterName was fixed in Scanner and
-- the vignette name was not. Vignettes fire on VIGNETTE_MINIMAP_UPDATED, so
-- inside a delve that is a throw several times a second, forever.
--
-- Patching each site as it is reported is how the second one happened. This is
-- the ONE place that asks, so a site that reads a client-supplied name is
-- either using it or has been missed visibly rather than quietly.
--
-- CONCATENATION IS NOT THE OPERATION THAT FAILS, and believing it was is what
-- produced the third report of this. The function used to concatenate inside a
-- pcall and then test the result OUTSIDE it, reasoning that concatenation is
-- what throws. It is not. A secret concatenates perfectly happily and hands
-- back another secret; the comparison afterwards is what throws:
--
--   "attempt to compare local 's' (a secret string value)"
--
-- So the guard itself became the error site, and every caller carefully routed
-- through it inherited the fault -- worse than the scattered reads it replaced,
-- because now there was a single place to be wrong and everything used it.
--
-- EVERY operation on the value therefore happens INSIDE the pcall: the
-- concatenation, the type test, and both comparisons. What comes back out is a
-- plain string or nil, and nothing else ever touches the original. A value that
-- cannot even be compared is, by definition, one we cannot use.
--
-- NOT LATCHED. Taint in WoW is per-execution-path, not a permanent property of
-- the addon, so "we saw one secret" does not mean every later read fails. The
-- pcall is cheap and bounded -- a dozen vignettes per fire -- and being right
-- matters more here than saving it.
U.secretReads = 0

function U.ReadableString(v)
	if v == nil then return nil end
	local ok, s = pcall(function()
		local out = v .. ""
		-- Both of these are forbidden operations on a secret, which is
		-- exactly why they sit in here rather than below.
		if type(out) ~= "string" then return nil end
		if out == "" then return nil end
		return out
	end)
	if not ok then
		U.secretReads = U.secretReads + 1
		return nil
	end
	-- Plain string or nil; whatever the client withheld threw above.
	return s
end
