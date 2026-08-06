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
end

-- Nodes usable by this character. A faction-locked portal is not a shortcut.
local function usable(n)
	if not n.faction then return true end
	local f = UnitFactionGroup and UnitFactionGroup("player")
	if not f then return true end
	return n.faction:upper() == f:upper()
end

-- Nearest network node on a given map, in yards, or nil if that map has none.
function NW.Nearest(mapID, x, y)
	build()
	local list = byMap and byMap[mapID]
	if not list then return nil end
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
function NW.TravelMinutes(fromMapID, fromX, fromY, toMapID, toX, toY)
	build()
	if not (graph and fromMapID and toMapID) then return nil end
	local depart = NW.Nearest(fromMapID, fromX, fromY)
	local arrive = NW.Nearest(toMapID, toX, toY)
	if not (depart and arrive) then return nil end
	if depart.key == arrive.key then return nil end

	local secs, path = NW.NodeSeconds(depart.key, arrive.key)
	if not secs then return nil end

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
