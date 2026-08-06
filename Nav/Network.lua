-- Master Mounts travel network: portals, ships, zeppelins and the tram.
--
-- The router already prices two kinds of movement well: self-flight by distance,
-- and taxi hops by MEASURED seconds (Data/FlightSeconds.lua). What it could not
-- price was the third kind -- stepping through a portal, taking a boat, riding
-- the zeppelin -- because those are not distance at all. A portal from Stormwind
-- to Oribos is fifteen seconds and half a world; a straight line says otherwise.
--
-- This routes over Data/TravelNetwork.lua: 1,156 endpoints with real coordinates
-- and 238 connections, so a leg can say "portal to Oribos, then fly 400 yards"
-- rather than charging a flat hub fee and hoping.
local _, MM = ...

MM.Network = {}
local NW = MM.Network
local U = MM.Util

-- COORDINATE CONVENTION. The source stores x/y as 0..1 fractions; every other
-- coordinate in this addon is 0..100. Getting this wrong does not error -- it
-- silently puts every node in the top-left corner of its zone, which looks like
-- a routing quirk rather than a units bug. Converted once, at index time.
local function pct(v)
	v = tonumber(v)
	if not v then return nil end
	return v <= 1.0 and v * 100 or v
end

local byMap, graph, built

-- Seconds for one edge: whatever the record states, else priced from the real
-- distance between its endpoints, else the labelled per-method default.
--
-- NEVER ZERO. `fly` and `flight` edges have no stated cost because the router
-- prices self-flight by distance elsewhere -- but inside a shortest-path search
-- a zero-weight edge is free teleportation, and Dijkstra will happily chain
-- them across the world at no charge and reorder the whole plan around a leg
-- that costs nothing because nobody priced it. The suite asserts this.
local FLOOR = 5

function NW.EdgeSeconds(edge)
	if not edge then return nil end
	if edge.cost and edge.cost > 0 then return edge.cost end

	local method = edge.method
	if method == "fly" or method == "flight" or method == "walk" then
		local a = MM.TravelNodes and MM.TravelNodes[edge.from]
		local b = MM.TravelNodes and MM.TravelNodes[edge.to]
		if a and b and U and U.GetWorldPos and U.WorldDistance then
			local _, wa = U.GetWorldPos(tonumber(a.mapID), pct(a.x), pct(a.y))
			local _, wb = U.GetWorldPos(tonumber(b.mapID), pct(b.x), pct(b.y))
			local dist = wa and wb and U.WorldDistance(wa, wb)
			if dist then
				local ypm = MM.YARDS_PER_MINUTE or 1500
				return math.max(FLOOR, (dist / ypm) * 60)
			end
		end
	end

	local d = MM.TravelDefaultSeconds
	return math.max(FLOOR, (d and d[method]) or 60)
end

local function build()
	if built then return end
	built = true
	byMap, graph = {}, {}
	local nodes, edges = MM.TravelNodes, MM.TravelEdges
	if not (nodes and edges) then return end

	for key, n in pairs(nodes) do
		local mid, x, y = tonumber(n.mapID), pct(n.x), pct(n.y)
		if mid and x and y then
			n.mapID, n.x, n.y, n.key = mid, x, y, key
			byMap[mid] = byMap[mid] or {}
			byMap[mid][#byMap[mid] + 1] = n
		end
	end

	for _, e in ipairs(edges) do
		local s = NW.EdgeSeconds(e)
		-- Directional as written. A zeppelin you can only board at one end is a
		-- one-way edge, and inventing the return trip would route the player
		-- onto a boat that is not there.
		graph[e.from] = graph[e.from] or {}
		graph[e.from][e.to] = { seconds = s, method = e.method }
	end

	-- SELF-FLIGHT EDGES BETWEEN NEARBY NODES.
	--
	-- Without these the network is islands. The 238 recorded connections are
	-- only the ones distance CANNOT derive -- portals, boats, zeppelins -- so on
	-- their own the largest connected component was six nodes out of 1,156, and
	-- NodeSeconds returned nil for essentially every pair. The data was correct
	-- and the graph was useless.
	--
	-- Two nodes close enough to fly between are connected, priced by the real
	-- distance. That is what makes a portal reachable: you fly to the portal,
	-- step through, and fly on from the far side.
	--
	-- Same-continent only, and capped: connecting everything to everything would
	-- be 1,156^2 comparisons and would also claim you can fly between continents.
	-- COST: 46 groups, 54,329 pair comparisons, 1,156 position lookups. The
	-- lookups are once per NODE (cached below), not once per pair, so the pair
	-- loop is arithmetic only. Built lazily on first route, never at login --
	-- the one time this addon froze a client it was a loop like this running
	-- eagerly in a handler.
	local MAX_YARDS = 3000
	if not (U and U.GetWorldPos and U.WorldDistance) then return end
	local ypm = MM.YARDS_PER_MINUTE or 1500
	local byGroup = {}
	for key, n in pairs(nodes) do
		if not n.interior and n.group then
			byGroup[n.group] = byGroup[n.group] or {}
			local g = byGroup[n.group]
			g[#g + 1] = { key = key, node = n }
		end
	end
	local added = 0
	for _, list in pairs(byGroup) do
		-- Cache world positions once per node rather than per comparison.
		for _, item in ipairs(list) do
			local _, w = U.GetWorldPos(item.node.mapID, item.node.x, item.node.y)
			item.world = w
		end
		for i = 1, #list do
			for j = i + 1, #list do
				local a2, b2 = list[i], list[j]
				if a2.world and b2.world
					and not (graph[a2.key] and graph[a2.key][b2.key])
					and not (graph[b2.key] and graph[b2.key][a2.key]) then
					local d = U.WorldDistance(a2.world, b2.world)
					if d and d <= MAX_YARDS then
						local secs = math.max(5, (d / ypm) * 60)
						graph[a2.key] = graph[a2.key] or {}
						graph[b2.key] = graph[b2.key] or {}
						graph[a2.key][b2.key] = { seconds = secs, method = "fly" }
						graph[b2.key][a2.key] = { seconds = secs, method = "fly" }
						added = added + 2
					end
				end
			end
		end
	end
	NW.autoEdges = added
end

-- Nodes usable by this character. A faction-locked portal is not a shortcut.
local function usable(n)
	if not n.faction then return true end
	local f = UnitFactionGroup and UnitFactionGroup("player")
	if not f then return true end
	return n.faction:upper() == f:upper()
end

-- Nearest network node on a given map, in yards, or nil if that map has none.
--
-- FALLS BACK TO THE CONTAINING MAP. There are no portals inside a raid, and
-- there never will be -- Ny'alotha (2379), the Tazavesh instance (1989) and
-- Sanctum of Domination (1543) all correctly have no network presence. But you
-- do not travel to the inside of a raid; you travel to its DOOR, which is in
-- the zone outside, which does have flight points and portals.
--
-- Without this every instanced goal reported "no node on map N" and the whole
-- network sat unused on exactly the stops it would help most. Climbing the map
-- parent chain finds the outdoor zone an instance sits in, for every instance,
-- without hand-listing entrances.
--
-- Bounded at 3 hops so this reaches the containing zone and not the continent.
local function nearestList(mapID)
	if not mapID then return nil, nil end
	local list = byMap and byMap[mapID]
	if list then return list, mapID end
	if not (C_Map and C_Map.GetMapInfo) then return nil, nil end
	local cur = mapID
	for _ = 1, 3 do
		local info = C_Map.GetMapInfo(cur)
		local parent = info and info.parentMapID
		if not parent or parent == 0 then break end
		local up = byMap and byMap[parent]
		if up then return up, parent end
		cur = parent
	end
	return nil, nil
end

function NW.Nearest(mapID, x, y)
	build()
	local list, onMap = nearestList(mapID)
	if not list then return nil end
	-- Coordinates belong to the ORIGINAL map; once we have climbed out of an
	-- instance they mean nothing on the parent, so fall back to its centre.
	if onMap ~= mapID then x, y = nil, nil end
	mapID = onMap
	if not (U and U.GetWorldPos and U.WorldDistance) then return list[1] end
	local _, here = U.GetWorldPos(mapID, x or 50, y or 50)
	if not here then return list[1] end
	local best, bestD
	for _, n in ipairs(list) do
		if usable(n) then
			local _, w = U.GetWorldPos(n.mapID, n.x, n.y)
			local d = w and U.WorldDistance(here, w)
			if d and (not bestD or d < bestD) then best, bestD = n, d end
		end
	end
	return best, bestD
end

-- INSTANCE NAME -> ITS DOOR.
--
-- Raid and dungeon interiors have no travel infrastructure and no useful map
-- parent -- climbing the parent chain does not escape an instance, which is why
-- that attempt changed nothing. But the network already carries 184 entrance
-- nodes named after the instances they open:
--
--   "Tazavesh, the Veiled Market" -> TAZAVESH_THE_VEILED_MARKET_DUNGEON (map 2472)
--   "Ny'alotha, the Waking City"  -> NYALOTHA_THE_WAKING_CITY_RAID_ULDUM
--
-- Those nodes sit OUTSIDE, in the zone you actually fly to. Matching the
-- record's instance name against them routes to the door, which is the thing
-- the player travels to.
local doorIndex
local function normaliseName(s)
	return (s or ""):upper():gsub("[^A-Z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
end

function NW.EntranceNode(instanceName)
	build()
	if not (instanceName and MM.TravelNodes) then return nil end
	if not doorIndex then
		doorIndex = {}
		for key, n in pairs(MM.TravelNodes) do
			-- Index by the node's own NAME, which is the instance's real name,
			-- rather than by parsing the key -- the key carries a _DUNGEON or
			-- _RAID_ZONE suffix that the record never has.
			local norm = normaliseName(n.name)
			if norm ~= "" and not doorIndex[norm] then doorIndex[norm] = key end
		end
	end
	return doorIndex[normaliseName(instanceName)]
end

local cache = {}

-- Seconds to get from one node to another across the network, plus the path.
-- Dijkstra: the graph is 238 edges, so the textbook heap would be more code for
-- no measurable gain, and results are memoised on the node pair.
function NW.NodeSeconds(fromKey, toKey)
	build()
	if not (graph and fromKey and toKey) then return nil end
	if fromKey == toKey then return 0, {} end
	local key = fromKey .. "\1" .. toKey
	local hit = cache[key]
	if hit ~= nil then
		if hit == false then return nil end
		return hit[1], hit[2]
	end

	local dist, prev, visited = { [fromKey] = 0 }, {}, {}
	while true do
		local cur, best = nil, math.huge
		for k, d in pairs(dist) do
			if not visited[k] and d < best then cur, best = k, d end
		end
		if not cur then break end
		if cur == toKey then break end
		visited[cur] = true
		for nxt, edge in pairs(graph[cur] or {}) do
			local node = MM.TravelNodes[nxt]
			if node and usable(node) then
				local alt = best + edge.seconds
				if alt < (dist[nxt] or math.huge) then
					dist[nxt] = alt
					prev[nxt] = { from = cur, method = edge.method }
				end
			end
		end
	end

	if not dist[toKey] then cache[key] = false return nil end
	local path, cur = {}, toKey
	while prev[cur] do
		tinsert(path, 1, { to = cur, method = prev[cur].method })
		cur = prev[cur].from
	end
	cache[key] = { dist[toKey], path }
	return dist[toKey], path
end

-- Minutes from one world position to another using the network, including the
-- ground legs at each end. nil when the network cannot connect them, so the
-- caller falls back to its own estimate rather than being handed a wrong number.
-- Second return on failure is the REASON, not just nil.
--
-- "network -" told me nothing three times running and I guessed wrong twice.
-- A nil here has four distinct causes and they need different fixes: no node
-- near the start, none near the end, both ends resolving to the same node, or
-- genuinely no path between them. The diagnostic prints whichever it was.
-- toInstance: the instance this goal is inside, if any. When the destination
-- map has no network presence -- every raid and dungeon interior -- the door
-- named after that instance is the real destination.
function NW.TravelMinutes(fromMapID, fromX, fromY, toMapID, toX, toY, toInstance, fromInstance)
	build()
	if not (graph and fromMapID and toMapID) then return nil, "no graph or map" end
	local depart = NW.Nearest(fromMapID, fromX, fromY)
	local arrive = NW.Nearest(toMapID, toX, toY)

	if not depart and fromInstance then
		local k = NW.EntranceNode(fromInstance)
		depart = k and MM.TravelNodes[k]
	end
	if not arrive and toInstance then
		local k = NW.EntranceNode(toInstance)
		arrive = k and MM.TravelNodes[k]
	end

	if not depart then return nil, ("no node on map %s"):format(tostring(fromMapID)) end
	if not arrive then return nil, ("no node on map %s"):format(tostring(toMapID)) end
	if depart.key == arrive.key then return nil, "same node both ends" end

	local secs, path = NW.NodeSeconds(depart.key, arrive.key)
	if not secs then
		return nil, ("no path %s -> %s"):format(depart.key, arrive.key)
	end

	local ypm = MM.YARDS_PER_MINUTE or 1500
	local legs = 0
	if U and U.GetWorldPos and U.WorldDistance then
		local _, a = U.GetWorldPos(fromMapID, fromX or 50, fromY or 50)
		local _, b = U.GetWorldPos(depart.mapID, depart.x, depart.y)
		if a and b then legs = legs + (U.WorldDistance(a, b) or 0) / ypm end
		local _, c = U.GetWorldPos(toMapID, toX or 50, toY or 50)
		local _, d = U.GetWorldPos(arrive.mapID, arrive.x, arrive.y)
		if c and d then legs = legs + (U.WorldDistance(c, d) or 0) / ypm end
	end

	local verbs = { portal = "portal", ship = "ship", zeppelin = "zeppelin",
		tram = "tram", walk = "walk", flight = "fly", fly = "fly" }
	local steps = {}
	for _, hop in ipairs(path or {}) do
		local n = MM.TravelNodes[hop.to]
		steps[#steps + 1] = ("%s to %s"):format(verbs[hop.method] or hop.method,
			(n and n.name) or hop.to)
	end
	local desc = #steps > 0 and table.concat(steps, ", then ") or nil
	return legs + (secs / 60), desc, depart, arrive
end

-- How much of the network this client can actually see, for the report. A count
-- nobody can check is a count nobody should trust.
function NW.Coverage()
	build()
	local nodes, edges, maps = 0, 0, 0
	for _ in pairs(MM.TravelNodes or {}) do nodes = nodes + 1 end
	for _ in pairs(MM.TravelEdges or {}) do edges = edges + 1 end
	for _ in pairs(byMap or {}) do maps = maps + 1 end
	return nodes, edges, maps
end
