-- Master Mounts: flight points, read from the client's own taxi map.
--
-- The single biggest quality gap in this addon is that most records carry a
-- ZONE but no coordinate, so the router aims at the zone centre. A centroid is
-- not a destination: it is frequently inside a mountain, a lake, or a piece of
-- geometry nobody can stand on, and "fly to roughly the middle of Nazjatar" is
-- not the standard this addon holds itself to.
--
-- A flight point is the opposite of a centroid. It is a real, reachable place
-- a player actually arrives at, its coordinates come from the client rather
-- than from anyone's guesswork, and it is where the journey to a zone-only
-- goal genuinely begins.
--
-- WHERE THE DATA COMES FROM. C_TaxiMap.GetAllTaxiNodes(uiMapID). This is
-- Blizzard's own table, per zone, live -- so it stays correct when a flight
-- point moves, and it needs no third-party addon and no subscription.
local _, MM = ...

MM.Taxi = {}
local TX = MM.Taxi

-- Per-map, because the API is not free and a route asks the same question
-- repeatedly. Dropped on world change: taxi availability is character and
-- progression dependent, so a cached "unreachable" must not outlive the flight
-- path being learned.
local cache = {}
function TX.Forget() wipe(cache) end
MM:RegisterGameEvent("PLAYER_ENTERING_WORLD", TX.Forget)

-- PERSISTED, because the API appears to answer only while a taxi map is open.
--
-- The first build read C_TaxiMap live and every stop still routed to a zone
-- centre: the call returns nothing standing in the world. That is the same
-- shape of problem as the Trading Post manifest and profession reagents --
-- the client will tell you, but only at the moment you are looking at it.
--
-- So: harvest when a flight master IS open, keep it in saved variables, and
-- read from there forever after. One visit to any flight master fills in
-- every zone at once.
local function store()
	-- MM.db does not exist until saved variables load, and NodesFor can be
	-- reached before that. A throwaway table means this session simply does
	-- not persist, rather than the whole nav layer throwing.
	if not MM.db then return {} end
	MM.db.taxi = MM.db.taxi or {}
	return MM.db.taxi
end

-- Is the client answering right now? Reported by the diagnostic, because
-- "we have no flight points" and "we cannot currently ask" are different
-- problems and only one of them is ours to fix.
function TX.APILive()
	if not (C_TaxiMap and C_TaxiMap.GetAllTaxiNodes) then return false, "no C_TaxiMap API" end
	local probe = { 84, 85, 2112, 1670 }   -- Stormwind, Orgrimmar, Valdrakken, Oribos
	for _, mapID in ipairs(probe) do
		local ok, raw = pcall(C_TaxiMap.GetAllTaxiNodes, mapID)
		if ok and type(raw) == "table" and #raw > 0 then return true end
	end
	return false, "the API returns nothing unless a flight master's map is open"
end

-- Blizzard has moved this field between `state` and `type` across expansions,
-- and the enum is not guaranteed present. Unknown is treated as REACHABLE on
-- purpose: hiding a flight point that actually works is worse than offering
-- one the player has not unlocked, which they can see for themselves.
local function reachable(node)
	local unreachable = Enum and Enum.FlightPathState and Enum.FlightPathState.Unreachable
	if unreachable == nil then return true end
	local v = node.state
	if v == nil then v = node.type end
	if v == nil then return true end
	return v ~= unreachable
end

-- Normalised 0-1 from the API; our records are 0-100. The position is a
-- Vector2DMixin on live and a plain table in some contexts, so both are read.
local function xy(node)
	local p = node and node.position
	if not p then return nil end
	if p.GetXY then
		local ok, x, y = pcall(p.GetXY, p)
		if ok and x and y then return x * 100, y * 100 end
	end
	if p.x and p.y then return p.x * 100, p.y * 100 end
	return nil
end

local function readLive(mapID)
	if not (C_TaxiMap and C_TaxiMap.GetAllTaxiNodes) then return nil end
	local ok, raw = pcall(C_TaxiMap.GetAllTaxiNodes, mapID)
	if not ok or type(raw) ~= "table" or #raw == 0 then return nil end
	local out = {}
	for _, node in ipairs(raw) do
		local x, y = xy(node)
		if node.name and node.name ~= "" and x and y then
			out[#out + 1] = {
				name = node.name, nodeID = node.nodeID,
				x = x, y = y, reachable = reachable(node),
			}
		end
	end
	if #out == 0 then return nil end
	return out
end

-- The shipped floor. Never claims to know what this character has unlocked --
-- static data cannot -- so points are marked assumed and the live API corrects
-- them the moment it can. Faction-filtered, because sending a Horde player to
-- an Alliance flight master is worse than sending them nowhere.
-- Zone names do not agree across sources. Ours say "Dalaran (Broken Isles)"
-- where the shipped list says "dalaran", and it carries sub-map suffixes like
-- "the forbidden reach/5". Two of five apparent gaps were this, not missing
-- data -- so the names are normalised on both sides before giving up.
local function normalise(name)
	name = (name or ""):lower()
	name = name:gsub("/%d+$", "")          -- sub-map suffix
	name = name:gsub("%s*%b()%s*$", "")    -- "(Broken Isles)"
	return (name:gsub("^%s+", ""):gsub("%s+$", ""))
end

local normIndex
local function lookup(name)
	local data = MM.FlightPointData
	if not data then return nil end
	local direct = data[(name or ""):lower()]
	if direct then return direct end

	if not normIndex then
		normIndex = {}
		for key, list in pairs(data) do
			local n = normalise(key)
			-- First writer wins: a real zone must not be shadowed by a suffixed
			-- variant of a different one.
			if n ~= "" and not normIndex[n] then normIndex[n] = list end
		end
	end
	local n = normalise(name)
	return normIndex[n] or normIndex[(n:gsub("^the%s+", ""))] or normIndex["the " .. n]
end

local function baseline(mapID)
	if not MM.FlightPointData then return nil end
	local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
	local name = info and info.name
	if not name then return nil end
	local list = lookup(name)
	if not list then return nil end

	local mine = UnitFactionGroup and UnitFactionGroup("player")
	local tag = (mine == "Horde") and "H" or "A"
	local out = {}
	for _, p in ipairs(list) do
		if p.faction == "B" or p.faction == tag then
			out[#out + 1] = { name = p.name, npc = p.npc, x = p.x, y = p.y,
				reachable = true, assumed = true }
		end
	end
	if #out == 0 then return nil end
	return out
end

function TX.NodesFor(mapID)
	if not mapID then return nil end
	if cache[mapID] then return cache[mapID] end

	-- Live first: it is current, and it knows what THIS character has unlocked.
	local out = readLive(mapID)
	if out then
		store()[mapID] = out
		cache[mapID] = out
		return out
	end

	-- Otherwise what we learned the last time a flight master was open. The
	-- coordinates do not change; only reachability does, and a saved point
	-- that turns out to be locked is still a real place on the map.
	local saved = store()[mapID]
	if saved and #saved > 0 then
		cache[mapID] = saved
		return saved
	end

	-- Last: the shipped baseline, so a fresh install that has never opened a
	-- flight master still routes to real places instead of zone centroids.
	local base = baseline(mapID)
	if base then cache[mapID] = base return base end

	-- STILL NOTHING? CLIMB OUT OF THE INSTANCE.
	--
	-- Raids and dungeons have no flight masters and never will. But a goal
	-- inside one is reached by flying to the zone OUTSIDE its door, and that
	-- zone does have them. Without this, every instanced goal reported no taxi
	-- option at all -- so 4,068 measured flight times went unused on precisely
	-- the stops with the longest journeys.
	--
	-- Bounded at 3 hops: far enough to reach the containing zone, not so far
	-- that it lands on the continent and picks a flight master a world away.
	if C_Map and C_Map.GetMapInfo then
		local cur = mapID
		for _ = 1, 3 do
			local info = C_Map.GetMapInfo(cur)
			local parent = info and info.parentMapID
			if not parent or parent == 0 then break end
			local up = readLive(parent) or store()[parent] or baseline(parent)
			if up and #up > 0 then
				cache[mapID] = up
				return up
			end
			cur = parent
		end
	end
	return nil
end

-- Fill in every zone our records care about, in one pass, while the client is
-- willing to answer. Chunked: this walks a couple of hundred maps and the one
-- time this addon froze a client it was a loop that did everything at once.
-- The node the player is STANDING AT. The client says so outright via
-- FlightPathState.Current, where guessing "nearest to my position" is wrong
-- the moment you are between two of them -- which is most of the time.
function TX.CurrentNode(mapID)
	if not (C_TaxiMap and C_TaxiMap.GetAllTaxiNodes and Enum and Enum.FlightPathState) then
		return nil
	end
	local ok, raw = pcall(C_TaxiMap.GetAllTaxiNodes, mapID or (GetTaxiMapID and GetTaxiMapID()))
	if not ok or type(raw) ~= "table" then return nil end
	for _, node in ipairs(raw) do
		if node.state == Enum.FlightPathState.Current and node.name then
			return node.name, node.nodeID
		end
	end
	return nil
end

-- What THIS character has actually unlocked. The shipped list cannot know it,
-- so every baseline point is flagged `assumed` until a real taxi map confirms
-- it. Recording the unlocked set turns that assumption into fact and never
-- expires: a flight path once learned is learned.
function TX.NoteKnown(nodes)
	if not (MM.db and nodes) then return end
	MM.db.taxiKnown = MM.db.taxiKnown or {}
	local n = 0
	for _, node in ipairs(nodes) do
		if node.name and node.name ~= "" and Enum and Enum.FlightPathState
			and node.state ~= Enum.FlightPathState.Unreachable then
			if not MM.db.taxiKnown[node.name:lower()] then n = n + 1 end
			MM.db.taxiKnown[node.name:lower()] = true
		end
	end
	return n
end

function TX.IsKnown(name)
	if not (name and MM.db and MM.db.taxiKnown) then return nil end
	return MM.db.taxiKnown[name:lower()] or false
end

function TX.Harvest()
	if not TX.APILive() then return end
	local U, maps, seen = MM.Util, {}, {}
	for _, rec in ipairs(MM.DBList or {}) do
		local mapID = U and U.GetRecordMapID and U.GetRecordMapID(rec)
		if mapID and not seen[mapID] then seen[mapID] = true maps[#maps + 1] = mapID end
	end
	local i, learned = 1, 0
	local function step()
		local stop = math.min(i + 40 - 1, #maps)
		for n = i, stop do
			local out = readLive(maps[n])
			if out then
				store()[maps[n]] = out
				learned = learned + 1
				TX.NoteKnown(out)
			end
		end
		i = stop + 1
		if i <= #maps then C_Timer.After(0, step)
		else
			wipe(cache)
			MM:Print("Flight points: learned %d zones from this flight master.", learned)
		end
	end
	step()
end
MM:RegisterGameEvent("TAXIMAP_OPENED", function() C_Timer.After(0, TX.Harvest) end)

-- The flight point nearest a target inside the zone. With no target, the one
-- nearest the centre -- which is still a real place, unlike the centre itself.
--
-- Reachable points win outright over unreachable ones regardless of distance:
-- a flight path you have not unlocked is not a shortcut, and sending someone
-- to one is worse than sending them somewhere further away that works.
function TX.Nearest(mapID, x, y)
	local nodes = TX.NodesFor(mapID)
	if not nodes or #nodes == 0 then return nil end
	x, y = x or 50, y or 50
	local best, bestScore
	for _, n in ipairs(nodes) do
		local dx, dy = n.x - x, n.y - y
		local d = dx * dx + dy * dy
		local score = n.reachable and d or (d + 1e6)
		if not best or score < bestScore then best, bestScore = n, score end
	end
	return best
end

-- One line for a nav card or a report.
function TX.Describe(node)
	if not node then return nil end
	local note = ""
	if not node.reachable then note = " — flight path not unlocked"
	elseif node.assumed then
		-- Confirmed by this character's own taxi map? Then it is not an
		-- assumption any more, whatever list it originally came from.
		if TX.IsKnown(node.name) then note = ""
		else note = " — from the shipped list, not yet confirmed here" end
	end
	return ("%s (%.1f, %.1f)%s"):format(node.name, node.x, node.y, note)
end

-- How much of the plan this can actually improve. Counts goals that name a
-- zone, carry no coordinate, and sit in a zone with a flight point.
function TX.Coverage()
	local helped, zoneOnly, noNodes = 0, 0, 0
	local U = MM.Util
	for _, entry in ipairs(MM.Scanner and MM.Scanner.mounts or {}) do
		local rec = entry.rec
		if rec and not entry.collected and rec.zone and rec.zone.name
			and not (rec.zone.x and rec.zone.y) then
			zoneOnly = zoneOnly + 1
			local mapID = U and U.GetRecordMapID and U.GetRecordMapID(rec)
			if mapID and TX.Nearest(mapID) then helped = helped + 1
			else noNodes = noNodes + 1 end
		end
	end
	return helped, zoneOnly, noNodes
end

MM:On("MM_FLIGHTPOINTS_DEBUG", function()
	if not (C_TaxiMap and C_TaxiMap.GetAllTaxiNodes) then
		MM:Print("This client has no C_TaxiMap.GetAllTaxiNodes.")
		return
	end
	local U = MM.Util
	local helped, missing = {}, {}
	local byZoneNoNode = {}

	for _, entry in ipairs(MM.Scanner and MM.Scanner.mounts or {}) do
		local rec = entry.rec
		if rec and not entry.collected and rec.zone and rec.zone.name
			and not (rec.zone.x and rec.zone.y) then
			local mapID = U and U.GetRecordMapID and U.GetRecordMapID(rec)
			local node = mapID and TX.Nearest(mapID)
			if node then
				helped[#helped + 1] = { name = entry.name, zone = rec.zone.name, node = node }
			else
				missing[#missing + 1] = { name = entry.name, zone = rec.zone.name }
				byZoneNoNode[rec.zone.name] = (byZoneNoNode[rec.zone.name] or 0) + 1
			end
		end
	end
	table.sort(helped, function(a, b)
		if a.zone == b.zone then return a.name < b.name end
		return a.zone < b.zone
	end)

	local live, why = TX.APILive()
	local known = 0
	for _ in pairs(MM.db.taxi or {}) do known = known + 1 end

	local L = { "# Master Mounts flight points", "",
		"Goals that name a ZONE but carry no coordinate. Without a flight point",
		"these aim at the zone centre, which is arithmetic rather than a place.",
		"Every coordinate below comes from C_TaxiMap, not from anyone's memory.",
		"" }
	L[#L + 1] = ("client answering right now: %s"):format(live and "yes" or ("NO -- " .. (why or "?")))
	L[#L + 1] = ("zones learned and saved so far: %d"):format(known)
	if not live and known == 0 then
		L[#L + 1] = ""
		L[#L + 1] = "NOTHING HAS BEEN LEARNED YET, and that is why the list below is empty."
		L[#L + 1] = "C_TaxiMap only answers while a flight master's map is open. Speak to"
		L[#L + 1] = "ANY flight master once -- every zone is harvested in that one visit and"
		L[#L + 1] = "kept in saved variables from then on."
	end
	L[#L + 1] = ""
	local total = #helped + #missing
	L[#L + 1] = ("%d such goals · %d now land on a real flight point · %d have none")
		:format(total, #helped, #missing)
	L[#L + 1] = ""

	-- EVERY one of them, not a sample. The point of a copyable window is that
	-- a human can check the coordinates, and a count is not checkable.
	L[#L + 1] = "## Landing on a flight point"
	local lastZone
	for _, h in ipairs(helped) do
		if h.zone ~= lastZone then
			L[#L + 1] = ""
			L[#L + 1] = "### " .. h.zone
			lastZone = h.zone
		end
		L[#L + 1] = ("  %-38s -> %s"):format(h.name, TX.Describe(h.node))
	end

	if #missing > 0 then
		L[#L + 1] = ""
		L[#L + 1] = "## No flight point in this zone"
		if live then
			-- Only claim this when we actually asked and got nothing. Saying it
			-- while the API is mute put Orgrimmar and Valdrakken under the
			-- heading "you do not fly in", which is plainly false and exactly
			-- the sort of confident wrong answer this report must not give.
			L[#L + 1] = "The client was asked and had none: instances, scenarios and phased"
			L[#L + 1] = "areas mostly. These need a real coordinate in the record."
		else
			L[#L + 1] = "NOT a judgement about these zones -- the client was never able to be"
			L[#L + 1] = "asked. Open any flight master once, then run this again."
		end
		local zones = {}
		for zone in pairs(byZoneNoNode) do zones[#zones + 1] = zone end
		table.sort(zones)
		for _, zone in ipairs(zones) do
			L[#L + 1] = ("  %-34s %d goal(s)"):format(zone, byZoneNoNode[zone])
		end
	end

	local text = table.concat(L, "\n")
	-- Inside the report, print so the section can be captured; standalone, open
	-- the copy window. Opening it during the report stole the report's own.
	-- ALWAYS print; never open a window from here.
	--
	-- This handler used to decide between printing and opening its own copy
	-- window based on whether a capture was running. Three different callers set
	-- that flag -- the report, a standalone capture, and a self-test that fires
	-- every section to check none are silent -- so the decision was made against
	-- state the handler could not actually see. Every other section just prints
	-- and lets the caller decide where it goes; this one now does the same.
	--
	-- /mm flightpoints wraps this in its own capture and window.
	for _, line in ipairs(L) do MM:Print(line) end

	MM:Print("Flight points: %d of %d zone-only goals now land on a real point — see the window.",
		#helped, total)
end)

------------------------------------------------------------
-- The taxi NETWORK
------------------------------------------------------------
-- Knowing where flight masters are is only half of it. A taxi is not a
-- straight line: it follows the network, hop by hop, and the only honest cost
-- is the sum of the measured legs. The principle, and it is correct: taxi
-- times must be OBSERVED, never derived from distance, because the bird flies
-- a wide curve at its own speed and neither of those is the player's.
--
-- Dijkstra rather than A*: with 755 nodes there is nothing to gain from a
-- heuristic, and a heuristic needs an admissible distance estimate which is
-- exactly what we do not have for a taxi.
local tripCache = {}

-- The measured graph, name-keyed, built once.
--
-- MM.FlightSeconds holds OBSERVED seconds per hop but is keyed by taxi nodeID;
-- the pathfinder below keys on lowercase flight-master name. This projects one
-- onto the other so the SAME Dijkstra runs over real durations instead of
-- distance/speed guesses -- including multi-hop routes, not just direct flights.
--
-- Measured edges win where they exist. Anything the measured set does not cover
-- falls through to the shipped graph, so coverage is a gradient rather than a
-- switch, and a missing node degrades one edge instead of the whole route.
local measuredGraph
local function measured()
	if measuredGraph ~= nil then return measuredGraph or nil end
	local secs, byName = MM.FlightSeconds, MM.FlightNodeByName
	if not (secs and byName) then measuredGraph = false return nil end
	-- Use the emitted reverse map, not an inversion of the name index.
	-- The index is first-wins, so inverting it silently dropped 46 nodes and
	-- 263 edges wherever two flight masters shared a name form.
	local idToName = MM.FlightNodeName
	if not idToName then
		idToName = {}
		for name, id in pairs(byName) do
			if not idToName[id] or #name > #idToName[id] then idToName[id] = name end
		end
	end
	local g, edges = {}, 0
	for id, nb in pairs(secs) do
		local from = idToName[id]
		if from then
			local row = g[from:lower()] or {}
			for otherID, s in pairs(nb) do
				local to = idToName[otherID]
				-- Lowercased on both sides: TripSeconds compares lowercase, and
				-- a graph keyed in mixed case would never match it.
				if to then row[to:lower()] = s edges = edges + 1 end
			end
			g[from:lower()] = row
		end
	end
	measuredGraph = edges > 0 and g or false
	return measuredGraph or nil
end
TX.MeasuredGraph = measured

-- Any known spelling of a flight master -> the one the graph is keyed by.
--
-- THE BUG THIS FIXES. Flight-point data names a master "Darkbreak Cove"; the
-- duration graph names it "Darkbreak Cove, Azsuna". TX.Nearest returned the
-- bare form, TripSeconds looked it up in a zone-qualified graph, missed, and
-- returned nil -- on every leg, so 4,068 measured hops were loaded and never
-- once used. /mm routertest said "taxi 0" for eight legs straight.
--
-- MM.FlightNodeByName already indexes BOTH forms against the same nodeID, so
-- this is a two-hop lookup rather than new data.
local function canonical(name)
	if not name then return nil end
	local low = name:lower()
	local byName, byID = MM.FlightNodeByName, MM.FlightNodeName
	if not (byName and byID) then return low end
	local id = byName[low]
	local canon = id and byID[id]
	return canon and canon:lower() or low
end
TX.CanonicalNodeName = canonical

function TX.TripSeconds(fromName, toName)
	local g = measured() or MM.TaxiGraphData
	if not (g and fromName and toName) then return nil end
	local a, b = canonical(fromName), canonical(toName)
	if a == b then return 0 end
	if not (g[a] and g[b]) then return nil end

	local key = a .. "\1" .. b
	local hit = tripCache[key]
	if hit ~= nil then return hit or nil end

	local dist, visited = { [a] = 0 }, {}
	while true do
		-- Linear scan for the nearest unvisited. A heap is the textbook answer
		-- and would matter at a hundred thousand nodes; here it would be more
		-- code for no measurable gain, and this result is memoised anyway.
		local cur, best = nil, math.huge
		for node, d in pairs(dist) do
			if not visited[node] and d < best then cur, best = node, d end
		end
		if not cur then break end
		if cur == b then
			tripCache[key] = best
			return best
		end
		visited[cur] = true
		for nb, secs in pairs(g[cur] or {}) do
			local alt = best + secs
			if not dist[nb] or alt < dist[nb] then dist[nb] = alt end
		end
	end
	tripCache[key] = false     -- no route: remember that too
	return nil
end

-- Total minutes for "fly to a flight master, take the taxi, fly the rest".
-- Returns the minutes and a description, or nil when no taxi route exists.
--
-- Deliberately includes BOTH ends. A taxi that lands on the far side of the
-- zone from the goal is not free, and costing only the flight itself is how a
-- router talks someone into a slower journey.
local routeCache = {}
function TX.ForgetRoutes() wipe(routeCache) wipe(tripCache) end

-- skipNetwork: price the TAXI GRAPH ALONE, ignoring portals and ships.
--
-- Only the diagnostic passes this. Normally the network competes here and the
-- cheaper answer wins, which is right for routing and useless for reporting:
-- a comparison whose columns already contain each other cannot show which one
-- is doing the work. /mm routertest needs the unmixed number to prove the
-- network is earning its place rather than merely loaded.
function TX.TravelMinutes(fromMapID, fromX, fromY, toMapID, toX, toY, skipNetwork,
		toInstance, fromInstance)
	local U = MM.Util
	if not (U and fromMapID and toMapID) then return nil end

	-- Memoised on the map PAIR. This is called from the router's inner loop,
	-- and the ground legs are computed from zone centres unless a caller has a
	-- real coordinate, so the answer barely moves within a pair. The one time
	-- this addon froze a client it was per-candidate work in a greedy loop.
	-- Separate cache line for the unmixed answer, or the diagnostic would poison
	-- the routing cache with taxi-only numbers.
	local key = fromMapID .. "\1" .. toMapID .. (skipNetwork and "\1n" or "")
		.. "\1" .. (toInstance or "") .. "\1" .. (fromInstance or "")
	local c = routeCache[key]
	if c ~= nil then
		if c == false then return nil end
		return c[1], c[2], c[3], c[4]
	end
	local depart = TX.Nearest(fromMapID, fromX, fromY)
	local arrive = TX.Nearest(toMapID, toX, toY)

	-- THE SAME DOOR FALLBACK THE NETWORK GOT, which I gave it and not this.
	--
	-- A raid interior has no flight master, and its map has no parent to climb
	-- to. But the travel network carries a node named after each instance,
	-- sitting in the zone OUTSIDE -- Tazavesh's door is on map 2472, Ny'alotha's
	-- is in Uldum. Resolve the door, then look for flight points on ITS map.
	--
	-- Without this every instanced goal reported no taxi option, so the measured
	-- flight times were unusable on exactly the stops that fly furthest.
	local NW = MM.Network
	if NW and NW.EntranceNode then
		if not depart and fromInstance then
			local k = NW.EntranceNode(fromInstance)
			local node = k and MM.TravelNodes and MM.TravelNodes[k]
			if node then depart = TX.Nearest(tonumber(node.mapID), node.x, node.y) end
		end
		if not arrive and toInstance then
			local k = NW.EntranceNode(toInstance)
			local node = k and MM.TravelNodes and MM.TravelNodes[k]
			if node then arrive = TX.Nearest(tonumber(node.mapID), node.x, node.y) end
		end
	end

	if not (depart and arrive) then routeCache[key] = false return nil end

	local secs = TX.TripSeconds(depart.name, arrive.name)
	if not secs then routeCache[key] = false return nil end

	-- Ground legs at each end, in the same yards-per-minute the router flies at.
	local ypm = MM.YARDS_PER_MINUTE or 1500
	local legs = 0
	local _, fromWorld = U.GetWorldPos(fromMapID, fromX or 50, fromY or 50)
	local _, departWorld = U.GetWorldPos(fromMapID, depart.x, depart.y)
	if fromWorld and departWorld then
		legs = legs + (U.WorldDistance(fromWorld, departWorld) or 0) / ypm
	end
	local _, toWorld = U.GetWorldPos(toMapID, toX or 50, toY or 50)
	local _, arriveWorld = U.GetWorldPos(toMapID, arrive.x, arrive.y)
	if toWorld and arriveWorld then
		legs = legs + (U.WorldDistance(toWorld, arriveWorld) or 0) / ypm
	end

	local total = legs + (secs / 60)
	local desc = ("fly to %s, taxi to %s (%d min), then fly in")
		:format(depart.name, arrive.name, math.max(1, math.floor(secs / 60 + 0.5)))

	-- THE PORTAL / SHIP / ZEPPELIN NETWORK COMPETES HERE.
	--
	-- A taxi is not always the answer and a straight line never was. A portal is
	-- fifteen seconds and half a world; the flight graph cannot express that,
	-- and distance actively lies about it. MM.Network routes the connections
	-- that are not distance at all, and whichever is genuinely faster wins.
	--
	-- It returns nil when it cannot connect the two points, so this only ever
	-- REPLACES an answer with a cheaper one -- never invents a leg where the
	-- taxi graph already had a real route.
	if not skipNetwork and MM.Network and MM.Network.TravelMinutes then
		local nMin, nDesc, nDep, nArr =
			MM.Network.TravelMinutes(fromMapID, fromX, fromY, toMapID, toX, toY,
				toInstance, fromInstance)
		if nMin and nMin < total then
			total, desc, depart, arrive = nMin, nDesc or desc, nDep or depart, nArr or arrive
		end
	end

	routeCache[key] = { total, desc, depart, arrive }
	return total, desc, depart, arrive
end

------------------------------------------------------------
-- Boats, zeppelins and portals
------------------------------------------------------------
-- A ship's cost is mostly the wait on the dock, which no distance calculation
-- can see. Costing a sea crossing as flight is how a router sends someone
-- swimming across an ocean.
local transitIndex
local function buildTransit()
	if transitIndex then return transitIndex end
	transitIndex = {}
	local mine = UnitFactionGroup and UnitFactionGroup("player")
	local tag = (mine == "Horde") and "H" or "A"
	for _, l in ipairs(MM.TransitData or {}) do
		if l.faction == "B" or l.faction == tag then
			local a, b = l.a:lower(), l.b:lower()
			-- Bidirectional: "-x-" in the source means it runs both ways.
			transitIndex[a] = transitIndex[a] or {}
			transitIndex[b] = transitIndex[b] or {}
			local fwd = { to = l.b, x = l.bx, y = l.by, fromX = l.ax, fromY = l.ay,
				mode = l.mode, secs = l.secs }
			local rev = { to = l.a, x = l.ax, y = l.ay, fromX = l.bx, fromY = l.by,
				mode = l.mode, secs = l.secs }
			if not transitIndex[a][b] or l.secs < transitIndex[a][b].secs then transitIndex[a][b] = fwd end
			if not transitIndex[b][a] or l.secs < transitIndex[b][a].secs then transitIndex[b][a] = rev end
		end
	end
	return transitIndex
end
function TX.ForgetTransit() transitIndex = nil end

local MODE_VERB = { SHIP = "take the ship", ZEPPELIN = "take the zeppelin",
	TRAM = "take the tram", PORTAL = "step through the portal" }

function TX.TransitMinutes(fromMapID, fromX, fromY, toMapID, toX, toY)
	local U = MM.Util
	if not (U and fromMapID and toMapID and C_Map and C_Map.GetMapInfo) then return nil end
	local fi, ti = C_Map.GetMapInfo(fromMapID), C_Map.GetMapInfo(toMapID)
	if not (fi and ti and fi.name and ti.name) then return nil end
	local link = (buildTransit()[fi.name:lower()] or {})[ti.name:lower()]
	if not link then return nil end

	-- Both ends again: reaching the dock and leaving the far one are real time.
	local ypm = MM.YARDS_PER_MINUTE or 1500
	local legs = 0
	local _, hereW = U.GetWorldPos(fromMapID, fromX or 50, fromY or 50)
	local _, dockW = U.GetWorldPos(fromMapID, link.fromX, link.fromY)
	if hereW and dockW then legs = legs + (U.WorldDistance(hereW, dockW) or 0) / ypm end
	local _, wantW = U.GetWorldPos(toMapID, toX or 50, toY or 50)
	local _, landW = U.GetWorldPos(toMapID, link.x, link.y)
	if wantW and landW then legs = legs + (U.WorldDistance(wantW, landW) or 0) / ypm end

	return legs + (link.secs / 60),
		("%s at %.1f,%.1f to %s"):format(MODE_VERB[link.mode] or "travel",
			link.fromX, link.fromY, link.to)
end

------------------------------------------------------------
-- Learning
------------------------------------------------------------
-- Time the player's OWN taxi trips and keep the result.
-- A shipped table is a starting point; the flight someone just took is a fact.
local flightStart, flightFrom
MM:RegisterGameEvent("PLAYER_CONTROL_LOST", function()
	if UnitOnTaxi and UnitOnTaxi("player") then
		flightStart = GetTime and GetTime() or nil
		local node = C_Map and C_Map.GetBestMapForUnit and TX.Nearest(C_Map.GetBestMapForUnit("player"))
		flightFrom = node and node.name or nil
	end
end)
MM:RegisterGameEvent("PLAYER_CONTROL_GAINED", function()
	if not (flightStart and flightFrom) then return end
	local secs = math.floor((GetTime() - flightStart) + 0.5)
	flightStart = nil
	-- A trip under 5s is a mount-up blip, not a flight; over 20 minutes means
	-- the player alt-tabbed away mid-air. Neither is a measurement.
	if secs < 5 or secs > 1200 then flightFrom = nil return end
	local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	local arrive = mapID and TX.Nearest(mapID)
	if arrive and arrive.name and MM.db and arrive.name:lower() ~= flightFrom:lower() then
		MM.db.taxiLearned = MM.db.taxiLearned or {}
		MM.db.taxiLearned[flightFrom:lower() .. "\1" .. arrive.name:lower()] = secs
		wipe(tripCache)
	end
	flightFrom = nil
end)

-- Learned times win over the shipped table: they came from this game, on this
-- patch, at this character's speed.
local shippedTrip = TX.TripSeconds
function TX.TripSeconds(fromName, toName)
	if fromName and toName and MM.db and MM.db.taxiLearned then
		local hit = MM.db.taxiLearned[fromName:lower() .. "\1" .. toName:lower()]
		if hit then return hit end
	end
	return shippedTrip(fromName, toName)
end
