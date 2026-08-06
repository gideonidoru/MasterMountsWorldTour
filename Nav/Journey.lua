-- Master Mounts: the whole journey, as one graph.
--
-- Until now each travel mode was a separate candidate: fly OR taxi OR boat OR
-- teleport, whichever single option was cheapest. Real travel is not like
-- that. Getting from Nazjatar to Zereth Mortis is fly-to-the-flight-master,
-- taxi, portal, fly again -- and no amount of comparing single modes will ever
-- discover that chain, because every individual leg looks worse than flying.
--
-- So: one graph, every mode as a typed edge, Dijkstra across the lot.
--
-- NODES     flight points (from the shipped list or the live client) and
--           transit endpoints (docks, portals), each with a map and a
--           coordinate.
-- EDGES     taxi legs and transit legs at their measured seconds, plus "fly"
--           edges between nodes that share a zone, priced at the player's own
--           flight speed.
-- ENDPOINTS the start and the goal join as temporary nodes wired into their
--           own zone, plus one direct fly edge between them -- so flying the
--           whole way is always a candidate and never assumed.
local _, MM = ...

MM.Journey = {}
local J = MM.Journey

local graph, byZone      -- node name -> { mapID, x, y, zone }, and zone -> {names}
local edges              -- from -> { to -> {secs, mode} }


-- Real yards when the client can give them, a defensible approximation when it
-- cannot. The first cut multiplied zone coordinates by 10, which treats a whole
-- zone as about a thousand yards -- most are three to six thousand. That made
-- walking seven zones look like four minutes and would have had the router
-- recommend a cross-continent stroll over a portal.
local ZONE_YARDS = 4000     -- a typical zone edge to edge; 1 coord unit ~= 40 yd
local mapCache = {}
local function mapFor(zone)
	if mapCache[zone] ~= nil then return mapCache[zone] or nil end
	local U = MM.Util
	local id = U and U.ResolveMapByName and U.ResolveMapByName(zone) or false
	mapCache[zone] = id or false
	return id or nil
end

-- Yards between two points, preferring the client's own world coordinates.
local function yards(zoneA, ax, ay, zoneB, bx, by)
	local U = MM.Util
	if U and U.GetWorldPos and U.WorldDistance then
		local ma, mb = mapFor(zoneA), mapFor(zoneB)
		if ma and mb then
			local _, wa = U.GetWorldPos(ma, ax, ay)
			local _, wb = U.GetWorldPos(mb, bx, by)
			if wa and wb then
				local d = U.WorldDistance(wa, wb)
				if d then return d end
			end
		end
	end
	local dx, dy = (ax - bx) * (ZONE_YARDS / 100), (ay - by) * (ZONE_YARDS / 100)
	return math.sqrt(dx * dx + dy * dy)
end

local function addEdge(from, to, secs, mode)
	if not (from and to) or from == to then return end
	edges[from] = edges[from] or {}
	local cur = edges[from][to]
	if not cur or secs < cur.secs then edges[from][to] = { secs = secs, mode = mode } end
end

-- Built once, lazily. Rebuilt when the player learns a flight point, because
-- what is reachable changes and a graph that never notices is a graph that
-- slowly becomes fiction.
-- Clears the PLANS as well as the graph. Dropping the graph alone left every
-- previously computed route cached against a world that no longer exists --
-- so a rebuild silently changed nothing, which is the worst kind of stale.
local planCache
function J.Forget() graph = nil planCache = {} end

local function build()
	if graph then return end
	graph, byZone, edges = {}, {}, {}

	-- Nodes: every flight point we know of, from the shipped list.
	for zone, list in pairs(MM.FlightPointData or {}) do
		for _, p in ipairs(list) do
			local key = p.name:lower()
			if not graph[key] then
				graph[key] = { name = p.name, zone = zone, x = p.x, y = p.y, kind = "flight" }
				byZone[zone] = byZone[zone] or {}
				table.insert(byZone[zone], key)
			end
			-- The taxi table disambiguates with a zone suffix ("beastwatch,
			-- gorgrond") where the flight point list is bare ("beastwatch").
			-- Only 184 of 758 names joined before this alias; the graph was
			-- almost entirely disconnected and every journey fell back to
			-- flying, which is exactly the answer it was built to improve on.
			local alias = (p.name .. ", " .. zone):lower()
			if not graph[alias] then graph[alias] = graph[key] end
		end
	end

	-- Taxi edges, at their measured seconds.
	-- Edges are added against the CANONICAL key so an alias and its bare name
	-- do not become two unconnected nodes.
	local function canon(n)
		local g = graph[n]
		if not g then return nil end
		return g.name:lower()
	end
	-- MEASURED FLIGHT TIMES FIRST, shipped graph as the fallback.
	--
	-- THE MISSING WIRE. Everything else was built -- 4,068 observed hop times,
	-- 795 nodes, a name index, a 100% projection -- and this line still read the
	-- old shipped graph. The router's real travel pricing runs through
	-- Journey.Plan, so the measured data was loaded, correct, verified and fed
	-- nothing that decided a route. `/mm routertest` said "taxi 0 · network 0"
	-- for six runs and it was right every time.
	--
	-- MeasuredGraph is the same name-keyed shape, so this is a source swap
	-- rather than new logic. Where it has no entry, TaxiGraphData still answers.
	local taxiSource = (MM.Taxi and MM.Taxi.MeasuredGraph and MM.Taxi.MeasuredGraph())
		or MM.TaxiGraphData or {}
	local measuredEdges = 0
	for from, ns in pairs(taxiSource) do
		local a = canon(from)
		if a then
			for to, secs in pairs(ns) do
				local b = canon(to)
				if b then addEdge(a, b, secs, "taxi") measuredEdges = measuredEdges + 1 end
			end
		end
	end
	-- Anything the measured set does not cover still comes from the shipped
	-- graph: coverage is a gradient, not a switch.
	if taxiSource ~= MM.TaxiGraphData then
		for from, ns in pairs(MM.TaxiGraphData or {}) do
			local a = canon(from)
			if a then
				for to, secs in pairs(ns) do
					local b = canon(to)
					if b then addEdge(a, b, secs, "taxi") end
				end
			end
		end
	end
	MM.Journey.measuredEdges = measuredEdges

	-- Transit endpoints become nodes in their own right: a dock is a place you
	-- have to physically reach, not a property of the zone.
	local mine = UnitFactionGroup and UnitFactionGroup("player")
	local tag = (mine == "Horde") and "H" or "A"
	for i, l in ipairs(MM.TransitData or {}) do
		if l.faction == "B" or l.faction == tag then
			local ka = ("%s@%d.a"):format(l.mode:lower(), i)
			local kb = ("%s@%d.b"):format(l.mode:lower(), i)
			graph[ka] = { name = l.a, zone = l.a:lower(), x = l.ax, y = l.ay, kind = l.mode }
			graph[kb] = { name = l.b, zone = l.b:lower(), x = l.bx, y = l.by, kind = l.mode }
			byZone[l.a:lower()] = byZone[l.a:lower()] or {} ; table.insert(byZone[l.a:lower()], ka)
			byZone[l.b:lower()] = byZone[l.b:lower()] or {} ; table.insert(byZone[l.b:lower()], kb)
			addEdge(ka, kb, l.secs, l.mode)
			addEdge(kb, ka, l.secs, l.mode)
		end
	end

	-- BORDERS. The edges that make this a world instead of a set of islands.
	--
	-- Every "no route" across a continent traced back to their absence: the
	-- Orgrimmar zeppelin tower was unreachable from Durotar, the zone it sits
	-- inside, because nothing connected one zone to the next. The crossing
	-- itself costs a few seconds -- the two coordinates are the same ground
	-- seen from either side -- and reaching it is priced by the ordinary
	-- within-zone edges below.
	for i, br in ipairs(MM.BorderData or {}) do
		if br.faction == "B" or br.faction == tag then
			local ka, kb = ("border@%d.a"):format(i), ("border@%d.b"):format(i)
			local za, zb = br.a:lower(), br.b:lower()
			graph[ka] = { name = br.a, zone = za, x = br.ax, y = br.ay, kind = "border" }
			graph[kb] = { name = br.b, zone = zb, x = br.bx, y = br.by, kind = "border" }
			byZone[za] = byZone[za] or {} ; table.insert(byZone[za], ka)
			byZone[zb] = byZone[zb] or {} ; table.insert(byZone[zb], kb)
			addEdge(ka, kb, 5, "walk")
			addEdge(kb, ka, 5, "walk")
		end
	end

	-- Fly edges WITHIN a zone only. Across zones the graph would be complete
	-- and useless -- every pair connected, nothing learned. Within a zone it is
	-- exactly right: you really can fly from the dock to the flight master.
	local ypm = MM.YARDS_PER_MINUTE or 1500
	for _, names in pairs(byZone) do
		for i = 1, #names do
			for k = i + 1, #names do
				local a, b = graph[names[i]], graph[names[k]]
				local secs = yards(a.zone, a.x, a.y, b.zone, b.x, b.y) / ypm * 60
				addEdge(names[i], names[k], secs, "fly")
				addEdge(names[k], names[i], secs, "fly")
			end
		end
	end
end

function J.Stats()
	build()
	local n, e = 0, 0
	for _ in pairs(graph) do n = n + 1 end
	for _, t in pairs(edges) do for _ in pairs(t) do e = e + 1 end end
	return n, e
end

-- Plan a journey. Returns total MINUTES and an ordered list of legs.
function J.Plan(fromZone, fromX, fromY, toZone, toX, toY, directFlyMinutes)
	build()
	planCache = planCache or {}
	if not (fromZone and toZone) then return nil end
	fromZone, toZone = fromZone:lower(), toZone:lower()

	local key = ("%s|%s"):format(fromZone, toZone)
	local hit = planCache[key]
	if hit ~= nil then return hit ~= false and hit[1] or nil, hit ~= false and hit[2] or nil end

	local ypm = J.SpeedFor(nil)
	local START, GOAL = "\1start", "\1goal"
	local temp = { [START] = true, [GOAL] = true }
	edges[START] = {}
	local function flySecs(zone, ax, ay, bx, by)
		return yards(zone, ax, ay, zone, bx, by) / ypm * 60
	end
	for _, name in ipairs(byZone[fromZone] or {}) do
		local n = graph[name]
		addEdge(START, name, flySecs(fromZone, fromX or 50, fromY or 50, n.x, n.y), "fly")
	end
	for _, name in ipairs(byZone[toZone] or {}) do
		local n = graph[name]
		addEdge(name, GOAL, flySecs(toZone, toX or 50, toY or 50, n.x, n.y), "fly")
	end
	-- Flying the whole way is always on the table, never assumed.
	if directFlyMinutes then addEdge(START, GOAL, directFlyMinutes * 60, "fly") end

	-- TELEPORTS AS EDGES, not as a rival candidate.
	--
	-- While a teleport was judged separately it could only ever be the WHOLE
	-- journey. It could never be the first leg of one -- hearth to Valdrakken,
	-- taxi onward, fly in -- which is exactly the chain a real player uses.
	-- As an edge out of START it competes and combines.
	local TP = MM.Teleports
	if TP and TP.Options then
		for _, landing in ipairs(TP.Options() or {}) do
			local lz = landing.place and landing.place:lower()
			local target = lz and (byZone[lz] and lz or nil)
			if target then
				-- Land at every node in the destination zone; the graph sorts
				-- out which one is actually worth walking to.
				for _, name in ipairs(byZone[target]) do
					local n = graph[name]
					local secs = (landing.waitMinutes or 0) * 60 + 30
						
					addEdge(START, name, secs, "teleport:" .. (landing.name or "?"))
				end
			end
		end
	end

	-- Dijkstra with a binary heap.
	--
	-- This picked the next node with a linear scan over every distance recorded
	-- so far -- O(V^2), about 570,000 comparisons per search across a 755-node
	-- graph. That was invisible while the router was accidentally short-circuiting
	-- to a flat constant and never calling this at all. The moment the planner
	-- was actually consulted, the optimiser started running one search per zone
	-- pair and a route build took nineteen seconds.
	--
	-- Same algorithm and same answers -- only the queue changed. Stale heap
	-- entries are tolerated and skipped on pop, which is cheaper than
	-- decrease-key and standard for this shape.
	local dist, prev, visited = { [START] = 0 }, {}, {}
	local heap, hn = { { START, 0 } }, 1

	local function push(node, d)
		hn = hn + 1
		heap[hn] = { node, d }
		local i = hn
		while i > 1 do
			local p = math.floor(i / 2)
			if heap[p][2] <= heap[i][2] then break end
			heap[p], heap[i] = heap[i], heap[p]
			i = p
		end
	end

	local function pop()
		if hn == 0 then return nil end
		local top = heap[1]
		heap[1] = heap[hn]
		heap[hn] = nil
		hn = hn - 1
		local i = 1
		while true do
			local l, r, small = i * 2, i * 2 + 1, i
			if l <= hn and heap[l][2] < heap[small][2] then small = l end
			if r <= hn and heap[r][2] < heap[small][2] then small = r end
			if small == i then break end
			heap[i], heap[small] = heap[small], heap[i]
			i = small
		end
		return top[1], top[2]
	end

	local best
	while true do
		local cur, d = pop()
		if not cur then break end
		if not visited[cur] then
			if cur == GOAL then best = d break end
			visited[cur] = true
			for nb, e in pairs(edges[cur] or {}) do
				local alt = d + e.secs
				if not dist[nb] or alt < dist[nb] then
					dist[nb] = alt
					prev[nb] = { cur, e }
					push(nb, alt)
				end
			end
		end
	end

	edges[START] = nil
	for _, name in ipairs(byZone[toZone] or {}) do
		if edges[name] then edges[name][GOAL] = nil end
	end
	if not best then planCache[key] = false return nil end

	local legs, node = {}, GOAL
	while prev[node] do
		local from, e = prev[node][1], prev[node][2]
		local label = temp[node] and "your goal" or (graph[node] and graph[node].name or node)
		table.insert(legs, 1, { mode = e.mode, to = label, minutes = e.secs / 60 })
		node = from
	end
	planCache[key] = { best / 60, legs }
	return best / 60, legs
end

-- One line a player can act on.
local VERB = { taxi = "taxi to", fly = "fly to", SHIP = "ship to",
	ZEPPELIN = "zeppelin to", PORTAL = "portal to", TRAM = "tram to" }
function J.Describe(legs)
	if not legs or #legs == 0 then return nil end
	local out = {}
	for _, leg in ipairs(legs) do
		-- Consecutive flights are one flight; nobody lands to think about it.
		local last = out[#out]
		if last and last.mode == "fly" and leg.mode == "fly" then
			last.to, last.minutes = leg.to, last.minutes + leg.minutes
		else
			out[#out + 1] = { mode = leg.mode, to = leg.to, minutes = leg.minutes }
		end
	end
	local bits = {}
	for _, leg in ipairs(out) do
		bits[#bits + 1] = ("%s %s (%.0f min)"):format(VERB[leg.mode] or leg.mode, leg.to, leg.minutes)
	end
	return table.concat(bits, ", then ")
end

------------------------------------------------------------
-- How fast can this player ACTUALLY move here?
------------------------------------------------------------
-- Flying is not a given. It needs the riding skill, it needs a flying mount,
-- and plenty of zones forbid it outright regardless -- the Maw, Korthia,
-- Timeless Isle, a new expansion before its Pathfinder unlocks. Assuming
-- flight everywhere makes every estimate optimistic in the one direction that
-- hurts: a player stuck on a ground mount is the slowest case there is, and a
-- route built on wings they do not have will send them the long way round.
--
-- So flyability is LEARNED, per zone, from the client's own IsFlyableArea()
-- as the player travels, and persisted. Unknown means GROUND speed, because
-- being pessimistic about an unknown is the only safe direction -- the same
-- rule the rest of this addon costs by.
local GROUND_YPM = 14 * 60      -- 100% ground mount, yards per minute
local FLY_YPM    = 28 * 60      -- ~310% flying

local function flyStore()
	if not MM.db then return {} end
	MM.db.flyable = MM.db.flyable or {}
	return MM.db.flyable
end

-- Can this character fly at all? Cheap, and it short-circuits everything.
function J.CanFlyAtAll()
	if not IsSpellKnown then return nil end
	-- Expert Riding (34090) or Master Riding (90265). Either means wings.
	local ok = pcall(IsSpellKnown, 34090)
	if not ok then return nil end
	return IsSpellKnown(34090) or IsSpellKnown(90265) or false
end

MM:RegisterGameEvent("ZONE_CHANGED_NEW_AREA", function()
	if not (C_Map and C_Map.GetBestMapForUnit and IsFlyableArea) then return end
	local mapID = C_Map.GetBestMapForUnit("player")
	if mapID then flyStore()[mapID] = IsFlyableArea() and true or false end
end)

function J.SpeedFor(mapID)
	if J.CanFlyAtAll() == false then return GROUND_YPM, "ground" end
	local known = mapID and flyStore()[mapID]
	if known == true then return FLY_YPM, "fly" end
	if known == false then return GROUND_YPM, "no flying here" end
	-- Never visited: assume the worst rather than the best.
	return GROUND_YPM, "flying unconfirmed here"
end
