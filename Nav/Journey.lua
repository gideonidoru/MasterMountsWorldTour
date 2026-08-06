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

-- A node's world position, worked out once. The nearest-node scan asks for
-- every node's position on each zone that has no flight point of its own, and
-- those answers do not change while the graph stands.
local nodeWorldCache = {}
-- Nearest entry points for a zone that has no flight point of its own.
-- Keyed by zone: every journey out of Tazavesh asks the same question.
local nearZoneCache = {}
-- Why a plan failed, kept beside the plan cache so a repeat query gets the
-- reason and not just another silent nil.
local planWhy = {}
-- Returns CONTINENT and position, never position alone.
--
-- A world position is continent-relative, so subtracting two of them across
-- continents is not a distance -- it is two unrelated numbers differenced, and
-- it usually comes out SMALL. Dropping the continent here made Bastion look
-- six seconds from The Maw and had the graph pick "nearest" nodes an ocean
-- away. Router.lua has always compared continents before measuring; this did
-- not, and the moment name resolution started working the mistake went live.
local function nodeWorld(name, mapID, x, y)
	local hit = nodeWorldCache[name]
	if hit ~= nil then
		if hit == false then return nil end
		return hit.continent, hit.world
	end
	local U = MM.Util
	local c, w = U.GetWorldPos(mapID, x, y)
	nodeWorldCache[name] = w and { continent = c, world = w } or false
	if not w then return nil end
	return c, w
end

-- Yards between two points, preferring the client's own world coordinates.
local function yards(zoneA, ax, ay, zoneB, bx, by)
	local U = MM.Util
	if U and U.GetWorldPos and U.WorldDistance then
		local ma, mb = mapFor(zoneA), mapFor(zoneB)
		if ma and mb then
			local ca, wa = U.GetWorldPos(ma, ax, ay)
			local cb, wb = U.GetWorldPos(mb, bx, by)
			-- SAME CONTINENT, OR THE MEASUREMENT IS MEANINGLESS.
			-- Two continent-relative positions differenced across continents
			-- produce a number, and that number is not a distance.
			if wa and wb and ca == cb then
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
-- Clears the nearest-node caches too. They are derived from the graph, so a
-- rebuild that left them standing would answer for nodes that no longer exist.
function J.Forget()
	graph = nil
	planCache = {}
	nodeWorldCache = {}
	nearZoneCache = {}
	planWhy = {}
end

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

	-- TRANSIT-ONLY NODES: flight masters we have measured times for but no
	-- position for.
	--
	-- canon() below returns nil for any name not already in the graph, and the
	-- graph was built purely from the 813 positioned flight points. So a hop
	-- between two real, named, measured flight masters was DISCARDED whenever
	-- either end lacked coordinates -- 903 of 3,964 usable hops, thrown away
	-- for want of an x,y that the route never actually needed.
	--
	-- It never needed it because a middle hop is not a place you stand. You buy
	-- one ticket and the taxi carries you through; the only nodes whose position
	-- matters are the one you board at and the one you get off at, and those are
	-- reached from byZone, which this deliberately does NOT join. A positionless
	-- node is therefore unreachable from START, cannot connect to GOAL, and is
	-- skipped by the within-zone fly edges -- all three read byZone, not graph.
	-- It can only ever sit in the middle of a taxi chain, priced at measured
	-- seconds, which is exactly what it is.
	--
	-- No coordinate is invented here. A node with no position keeps no position.
	local transit = 0
	for _, nodeName in pairs(MM.FlightNodeName or {}) do
		local key = nodeName:lower()
		if not graph[key] then
			graph[key] = { name = nodeName, kind = "transit" }
			transit = transit + 1
		end
	end
	J.transitNodes = transit

	-- PORTALS, SHIPS AND ZEPPELINS, AS EDGES IN THIS GRAPH.
	--
	-- The travel network held these already, but in a different module keyed by
	-- its own node identifiers -- and Journey is what actually prices a route.
	-- So the router had 4,068 measured flight hops and no way to cross an ocean
	-- except by falling back to a flat constant, which is why "network 0" won
	-- nothing and every awkward leg cost the same 8 minutes.
	--
	-- These state both ends as a zone name and a coordinate, so they join the
	-- graph the same way a flight point does: added to byZone, they gain the
	-- within-zone fly edges and can be reached from START and GOAL.
	--
	-- Faction gating is honoured. A Horde-only boat offered to an Alliance
	-- character is a route that cannot be walked.
	-- One-way stays one-way: a return trip that does not exist is not a saving.
	local myFaction = UnitFactionGroup and UnitFactionGroup("player")
	local linkCount, linkNodes, gatedOut = 0, 0, 0
	local function transitNode(idx, side, zone, x, y)
		local zl = zone:lower()
		local key = ("\2%d%s"):format(idx, side)
		graph[key] = { name = zone, zone = zl, x = x, y = y, kind = "transit" }
		byZone[zl] = byZone[zl] or {}
		table.insert(byZone[zl], key)
		linkNodes = linkNodes + 1
		return key
	end
	for i, L in ipairs(MM.TransitLinks or {}) do
		if L.faction and myFaction and L.faction ~= myFaction then
			gatedOut = gatedOut + 1
		-- An end written 0,0 means "inside the instance", not a coordinate.
		-- Those doors are handled where instances are handled; placing a node
		-- at the map's corner would measure every distance to it wrongly.
		elseif not (L.ainside or L.binside) then
			local ka = transitNode(i, "a", L.a, L.ax, L.ay)
			local kb = transitNode(i, "b", L.b, L.bx, L.by)
			local secs = (MM.TransitSeconds and MM.TransitSeconds[L.mode]) or 30
			addEdge(ka, kb, secs, L.mode)
			if not L.oneway then addEdge(kb, ka, secs, L.mode) end
			linkCount = linkCount + 1
		end
	end
	J.transitLinks, J.transitLinkNodes, J.transitGated = linkCount, linkNodes, gatedOut

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

-- Read-only views of the graph, so a test can assert the invariant that keeps
-- positionless transit nodes safe instead of taking it on faith.
function J.NodesByZone() build() return byZone end
function J.Node(name) build() return name and graph[name:lower()] end

-- How much of the graph can be reached from one node.
--
-- The number that matters and the one nothing was watching: a graph can hold
-- thousands of correct edges and still be a hundred islands, and a router on an
-- island quietly falls back to a flat constant for every leg it cannot plan.
-- Counting nodes and edges cannot see that. This can.
function J.Reachable(fromName)
	build()
	local start = fromName and graph[fromName:lower()] and fromName:lower()
	if not start then return nil end
	local seen, stack, n = { [start] = true }, { start }, 0
	while #stack > 0 do
		local cur = table.remove(stack)
		n = n + 1
		for to in pairs(edges[cur] or {}) do
			if not seen[to] then seen[to] = true stack[#stack + 1] = to end
		end
	end
	local total = 0
	for _ in pairs(graph) do total = total + 1 end
	return n, total
end

-- The attachment candidates for a zone, with the continent each sits on.
--
-- Exposed so a check can assert the invariant that broke: an entry point on
-- another continent is not an entry point, however small the arithmetic
-- between two continent-relative coordinates happens to come out.
function J.AttachAudit(zone, x, y)
	build()
	if not zone then return nil end
	local U = MM.Util
	local zl = zone:lower()
	local own = byZone[zl]
	if own and #own > 0 then return #own, 0, "own zone" end
	local cached = nearZoneCache[zl]
	if not cached then return nil end
	-- THE CONTINENT attachPoints ACTUALLY MEASURED FROM.
	--
	-- For an instance that is its DOOR's outdoor map, not the interior. This
	-- check first re-derived it from the zone name, got the interior, and
	-- reported 16 attachments on "another continent" that were entirely its own
	-- doing -- a false alarm on working code, which costs as much trust as a
	-- missed fault. Read the value that was used; never reconstruct it.
	local hereC = cached.originContinent
	if not hereC then return 0, 0, "no origin continent recorded" end
	local same, other = 0, 0
	for _, p in ipairs(cached) do
		local n = graph[p.name]
		local mz = n and n.zone and mapFor(n.zone)
		local c = mz and select(1, U.GetWorldPos(mz, n.x or 50, n.y or 50))
		if c == hereC then same = same + 1 else other = other + 1 end
	end
	return same, other, "nearest elsewhere"
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
	if not (fromZone and toZone) then return nil, nil, "no zone name at one end" end
	fromZone, toZone = fromZone:lower(), toZone:lower()

	local key = ("%s|%s"):format(fromZone, toZone)
	local hit = planCache[key]
	if hit ~= nil then
		if hit == false then return nil, nil, planWhy[key] end
		return hit[1], hit[2]
	end

	local ypm = J.SpeedFor(nil)
	local START, GOAL = "\1start", "\1goal"
	local temp = { [START] = true, [GOAL] = true }
	edges[START] = {}
	-- A ZONE WITH NO FLIGHT POINT IS NOT A ZONE YOU CANNOT LEAVE.
	--
	-- START only ever attached to nodes in its OWN zone. Tazavesh, Ny'alotha,
	-- Sanctum of Domination and the Forbidden Reach have no flight master of
	-- their own, so START had no edge into the graph at all and Plan returned
	-- nil -- whereupon travelMinutes charged the flat CROSS_CONTINENT_MINUTES.
	-- That constant is 8, cheaper than most genuine multi-leg routes, so the
	-- guess then BEAT every real answer: /mm routertest reported "network 0"
	-- across every leg while holding 4,068 measured hops.
	--
	-- A player in that situation flies to the nearest flight master. yards()
	-- already resolves both zones to world coordinates, so the nearest node
	-- anywhere is a real measured distance, not an approximation -- and no
	-- coordinate is invented, because it only ever uses nodes we already ship.
	-- Always { name = , d = }, whether the zone had its own points or we had to
	-- reach outside it -- one shape, so the caller cannot mix them up.
	local function attachPoints(zone, x, y)
		local out = {}
		for _, name in ipairs(byZone[zone] or {}) do
			local n = graph[name]
			if n and n.x and n.y then
				out[#out + 1] = { name = name,
					d = yards(zone, x or 50, y or 50, zone, n.x, n.y) }
			end
		end
		if #out > 0 then return out end
		local cached = nearZoneCache[zone]
		if cached then return cached end

		-- MEASURED ACROSS ZONES, OR NOT AT ALL.
		--
		-- yards() falls back to treating both points as if they were in one
		-- zone when a name will not resolve to a map, which is fine WITHIN a
		-- zone and nonsense between two. Six zone names do not resolve on this
		-- client, and for those the fallback would hand back a small number for
		-- an arbitrary far-away node -- a fabricated cheap edge, which Dijkstra
		-- would seize on and route the player through.
		--
		-- No world position, no candidate. Leaving the list empty costs a flat
		-- fallback for that leg; guessing costs a wrong route presented as fact.
		-- ONLY FROM A REAL WORLD MAP.
		--
		-- A dungeon or raid interior has its own coordinate space, so a world
		-- position taken inside one is not comparable to an outdoor node. A
		-- wrong LARGE distance would merely be ignored; a wrong SMALL one
		-- invents a cheap edge and Dijkstra routes the player straight through
		-- it. Instances reach the world through their door, which is a separate
		-- piece of data we already hold -- not through a coordinate guess.
		--
		-- Refusing here costs the flat fallback, which is what happens today.
		local U = MM.Util
		local here
		-- mapFor is the file-level cached resolver; calling ResolveMapByName
		-- per node would be 1,300 lookups per zone.
		local originMap, ox, oy = mapFor(zone), x or 50, y or 50
		local info = originMap and C_Map and C_Map.GetMapInfo
			and C_Map.GetMapInfo(originMap)
		local worldly = info and Enum and Enum.UIMapType
			and (info.mapType == Enum.UIMapType.Zone
				or info.mapType == Enum.UIMapType.Continent)

		-- AN INSTANCE LEAVES BY ITS DOOR.
		--
		-- Its interior has a private coordinate space, so measuring from inside
		-- it to an outdoor flight master is meaningless -- and a meaningless
		-- SMALL answer invents a cheap edge that Dijkstra will happily route
		-- through. But the door is a real outdoor place we already ship a map
		-- and a coordinate for, and it is where the player actually stands on
		-- the way out. Measure from there instead of refusing.
		if not worldly and MM.Network and MM.Network.EntranceNode then
			local key = MM.Network.EntranceNode(zone)
			local door = key and MM.TravelNodes and MM.TravelNodes[key]
			if door and door.mapID and door.x and door.y then
				local dx, dy = tonumber(door.x), tonumber(door.y)
				-- TravelNodes store 0..1; everything here is 0..100.
				if dx and dy then
					originMap = door.mapID
					ox = dx <= 1.0 and dx * 100 or dx
					oy = dy <= 1.0 and dy * 100 or dy
					worldly = true
				end
			end
		end

		local hereContinent
		if worldly and U and U.GetWorldPos and U.WorldDistance and originMap then
			hereContinent, here = U.GetWorldPos(originMap, ox, oy)
		end
		local best = {}
		if here then
			for z, names in pairs(byZone) do
				local mz = mapFor(z)
				if mz then
					for _, name in ipairs(names) do
						local n = graph[name]
						if n and n.x and n.y then
							-- You cannot fly to another continent. A candidate
							-- on a different one is not near, however small the
							-- arithmetic between their coordinates comes out.
							local thereContinent, there = nodeWorld(name, mz, n.x, n.y)
							local d = there and thereContinent == hereContinent
								and U.WorldDistance(here, there)
							if d then best[#best + 1] = { name = name, d = d } end
						end
					end
				end
			end
		end
		table.sort(best, function(a, b) return a.d < b.d end)
		-- A handful is enough. The graph decides which is genuinely worth the
		-- flight; carrying all of them only widens the search.
		for i = 1, math.min(#best, 8) do out[i] = best[i] end
		-- Record the continent this actually measured from. An audit that
		-- re-derives it independently will get a DIFFERENT answer for an
		-- instance, because the origin used here is the door's outdoor map and
		-- not the interior -- and it will then report mismatches that are its
		-- own. Store the value used; check against that.
		out.originContinent = hereContinent
		nearZoneCache[zone] = out
		return out
	end

	local fromCount, toCount = 0, 0
	for _, p in ipairs(attachPoints(fromZone, fromX, fromY)) do
		addEdge(START, p.name, p.d / ypm * 60, "fly")
		fromCount = fromCount + 1
	end
	for _, p in ipairs(attachPoints(toZone, toX, toY)) do
		addEdge(p.name, GOAL, p.d / ypm * 60, "fly")
		toCount = toCount + 1
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
	-- SAY WHY, and say which of the three it was.
	--
	-- A bare nil reads as "no route exists" when it usually means we could not
	-- get ON to the graph, or could not get OFF it at the far end -- three
	-- different faults needing three different fixes, and "-" tells them apart
	-- from nothing. The network layer already reports its reason; this one
	-- staying silent made it the harder of the two to diagnose despite being
	-- the one that decides the route.
	if not best then
		local why
		if fromCount == 0 then
			why = ("no way into the travel graph from %s"):format(fromZone)
		elseif toCount == 0 then
			why = ("no way to reach %s from the graph"):format(toZone)
		else
			why = ("no path %s -> %s (%d start / %d goal attachments)")
				:format(fromZone, toZone, fromCount, toCount)
		end
		planCache[key] = false
		planWhy[key] = why
		return nil, nil, why
	end

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
	ZEPPELIN = "zeppelin to", PORTAL = "portal to", TRAM = "tram to",
	WALK = "walk to", FLY = "fly to" }
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
