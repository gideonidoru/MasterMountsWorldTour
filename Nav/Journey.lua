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
-- Suffixed spellings ("beastwatch, gorgrond") that point at an EXISTING node
-- table rather than being nodes of their own. They carry no edges -- edges are
-- keyed through canon() -- so a walk over pairs(graph) sees each of the 767 of
-- them as its own one-node island. That is what made the component count read
-- 614 when the real figure is a fraction of it.
local aliasKey


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
-- mapA/mapB are optional and WIN over resolving the zone name. A node on a
-- floor is on its own map: resolving its zone name gives the floor-0 map and
-- measures its coordinate against the wrong one.
local function yards(zoneA, ax, ay, zoneB, bx, by, mapA, mapB)
	local U = MM.Util
	if U and U.GetWorldPos and U.WorldDistance then
		local ma, mb = mapA or mapFor(zoneA), mapB or mapFor(zoneB)
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
			-- SAY SO WHEN THE ANSWER BELOW IS NOT A DISTANCE.
			--
			-- Falling through to the planar estimate across two continents
			-- produces a small, plausible, entirely fictional number -- the
			-- same shape of fault that once put Bastion six seconds from The
			-- Maw. 176 zone names now span more than one map, so the caller
			-- gets told, and the one caller that must not guess acts on it.
			if wa and wb and ca ~= cb then
				local dx, dy = (ax - bx) * (ZONE_YARDS / 100), (ay - by) * (ZONE_YARDS / 100)
				return math.sqrt(dx * dx + dy * dy), true
			end
		end
	end
	local dx, dy = (ax - bx) * (ZONE_YARDS / 100), (ay - by) * (ZONE_YARDS / 100)
	return math.sqrt(dx * dx + dy * dy)
end

-- `resource` names a ONE-USE charge this edge spends, when it spends one.
--
-- Carried as structured data rather than recovered later from the mode string.
-- The router used to decide whether a journey had spent a teleport by looking
-- for "teleport:" at the front of a human-readable label -- so the answer
-- depended on prose, and the actual key it spent was not recoverable at all.
local function addEdge(from, to, secs, mode, resource)
	if not (from and to) or from == to then return end
	edges[from] = edges[from] or {}
	local cur = edges[from][to]
	if not cur or secs < cur.secs then
		edges[from][to] = { secs = secs, mode = mode, resource = resource }
	end
end

-- Where a place joins the graph: the nodes worth attaching a journey end to.
--
-- Hoisted to file scope because the single-source travel search needs it too.
-- While it was a local inside J.Plan it was invisible to every other caller,
-- and a reference to it from outside resolves as a GLOBAL -- nil at run time,
-- and silent to luac.
local function attachPoints(zone, x, y, knownMapID)
	local out = {}
	for _, name in ipairs(byZone[zone] or {}) do
		local n = graph[name]
		if n and n.x and n.y then
			-- Each end against its OWN map. A node on floor 5 carries the
			-- floor-5 map; measuring its coordinate against the zone's
			-- floor-0 map is the same mistake as measuring across
			-- continents, just quieter.
			out[#out + 1] = { name = name,
				d = yards(zone, x or 50, y or 50, zone, n.x, n.y,
					knownMapID, n.mapID) }
		end
	end
	if #out > 0 then return out end
	-- Cache by the map actually used, not the name, for the same reason the
	-- plan cache is.
	local cacheKey = zone .. "#" .. tostring(knownMapID or "?")
	local cached = nearZoneCache[cacheKey]
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
	-- The caller's map id wins over anything re-derived from the name.
	local originMap, ox, oy = knownMapID or mapFor(zone), x or 50, y or 50
	local info = originMap and C_Map and C_Map.GetMapInfo
		and C_Map.GetMapInfo(originMap)
	-- REFUSE ONLY WHAT IS ACTUALLY AN INTERIOR.
	--
	-- This demanded mapType Zone or Continent, which is a guess about which
	-- maps are outdoors. The Forbidden Reach is neither and is very much
	-- outdoors, so it could not be entered at all -- "no way to reach the
	-- forbidden reach from the graph" while the same leg was happily priced
	-- by a direct flight, which needs the very world position this refused
	-- to ask for.
	--
	-- The continent comparison below is the real protection: an interior's
	-- coordinate space reports a continent that matches no outdoor node, so
	-- its candidates are rejected on their own merits rather than on a guess
	-- about the map's type. Only a declared Dungeon is refused outright, and
	-- those have doors.
	local mapType = info and info.mapType
	local worldly = info and not (Enum and Enum.UIMapType
		and mapType == Enum.UIMapType.Dungeon)

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
						local thereContinent, there =
							nodeWorld(name, n.mapID or mz, n.x, n.y)
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
	if #best == 0 then
		out.why = (not info and ("no map info for " .. tostring(originMap)))
			or (not worldly and ("map %s is an instance interior and has no door")
				:format(tostring(originMap)))
			or (not here and ("no world position for map " .. tostring(originMap)))
			or "no node anywhere shares its continent"
	end
	for i = 1, math.min(#best, 8) do out[i] = best[i] end
	-- Record the continent this actually measured from. An audit that
	-- re-derives it independently will get a DIFFERENT answer for an
	-- instance, because the origin used here is the door's outdoor map and
	-- not the interior -- and it will then report mismatches that are its
	-- own. Store the value used; check against that.
	out.originContinent = hereContinent
	nearZoneCache[cacheKey] = out
	return out
end

-- Built once, lazily. Rebuilt when the player learns a flight point, because
-- what is reachable changes and a graph that never notices is a graph that
-- slowly becomes fiction.
-- Clears the PLANS as well as the graph. Dropping the graph alone left every
-- previously computed route cached against a world that no longer exists --
-- so a rebuild silently changed nothing, which is the worst kind of stale.
local planCache
-- Counted rather than measured on demand: `#` does not work on a string-keyed
-- table and walking it to find out how big it is would cost more than the cap
-- saves. Declared here, beside the cache, so everything that empties one
-- empties the other.
local planCacheSize = 0
-- Clears the nearest-node caches too. They are derived from the graph, so a
-- rebuild that left them standing would answer for nodes that no longer exist.
function J.Forget()
	graph = nil
	planCache = {}
	planCacheSize = 0
	nodeWorldCache = {}
	nearZoneCache = {}
	planWhy = {}
	-- The single-origin search is a result computed FROM the graph, so a
	-- rebuild that left it standing would keep answering "how far is
	-- everything from here" out of the map that was just thrown away. Called
	-- through J rather than touching the local, which is declared six hundred
	-- lines below this one.
	if J.ForgetTravelFrom then J.ForgetTravelFrom() end
end

-- Throw away the ANSWERS but keep the map.
--
-- The graph does not depend on which teleports you own: build() lays down
-- flight points, transit links and taxi edges, and Plan() wires the teleports
-- into START each time it runs. So the capability harness was calling Forget()
-- between profiles and rebuilding 29,593 within-zone edges, 1,360 transit links
-- and 4,068 taxi hops eight times per run, to arrive at exactly the same graph.
--
-- That is what "script ran too long" was: not a slow search, a map redrawn from
-- scratch for every question asked of it.
function J.ForgetPlans()
	planCache = {}
	planCacheSize = 0
	planWhy = {}
end

-- AN ISLAND WITH NO DOOR IS STILL SOMEWHERE YOU CAN FLY TO.
--
-- 47 zones had no edge into the rest of the graph at all, so every journey to
-- one of them reported "no path" and fell through to a flat flight estimate --
-- including one that priced a Shadowlands-to-Dragon-Isles trip at 6.3 minutes,
-- which is not a flight that exists.
--
-- The cross-zone fly edge is deliberately absent above, and that is right:
-- all-pairs would be a complete graph that teaches nothing. But a component
-- with NO way in is the one case where "you just fly there" is the real
-- answer. The Forbidden Reach is an island off the Dragon Isles, and no
-- portal, boat or flight master reaches it in ANY source we have -- because
-- none is needed. Zygor does not record one for the same reason.
--
-- So: only for components that nothing else reaches, only ONE edge each, and
-- only to the nearest node ON THE SAME CONTINENT, priced at the real world
-- distance. Never across a continent -- that is not a flight, and pricing it
-- as one is exactly how Bastion came out six seconds from The Maw.
--
-- A component with nothing on its continent stays stranded and says so, in
-- J.bridgeSkipped. An island we cannot honestly connect is not one we invent
-- a bridge to.
local function bridgeIslands(ypm)
	local U = MM.Util
	if not (U and U.GetWorldPos and U.WorldDistance) then return end

	-- Components, cheapest way: one walk over every node.
	local comp, order, sizes = {}, {}, {}
	local nc = 0
	-- Aliases are spellings, not places. Seeding the walk from one invents a
	-- one-node island that can never be bridged and never needed to be.
	for name in pairs(graph) do
		if not aliasKey[name] then order[#order + 1] = name end
	end
	for _, seed in ipairs(order) do
		if not comp[seed] then
			nc = nc + 1
			local stack, n = { seed }, 0
			comp[seed] = nc
			while #stack > 0 do
				local cur = table.remove(stack)
				n = n + 1
				for to in pairs(edges[cur] or {}) do
					if not comp[to] then comp[to] = nc stack[#stack + 1] = to end
				end
			end
			sizes[nc] = n
		end
	end
	-- The mainland is the biggest component, not a named node: naming one
	-- would strand everything if that node ever moved.
	local main, best = nil, -1
	for id, n in pairs(sizes) do if n > best then main, best = id, n end end
	J.components, J.mainComponent = nc, best
	if nc < 2 then J.bridges, J.bridgeSkipped = 0, 0 return end

	-- Mainland candidates are FLIGHT POINTS ONLY, bucketed by continent.
	--
	-- Two reasons, and the second is the one that matters. It is what a player
	-- actually does -- you fly to the nearest flight master, not to an
	-- arbitrary dock or portal mouth. And it is ~800 nodes instead of ~4,900,
	-- which is the difference between a scan that finishes and one that trips
	-- the watchdog: every stranded component has to search this list.
	local byContinent = {}
	for name, n in pairs(graph) do
		if comp[name] == main and n.kind == "flight" and n.x and n.y then
			local c, w = nodeWorld(name, n.mapID or (n.zone and mapFor(n.zone)), n.x, n.y)
			if c and w then
				byContinent[c] = byContinent[c] or {}
				local t = byContinent[c]
				t[#t + 1] = { name = name, world = w }
			end
		end
	end

	-- A GRID, BECAUSE THERE ARE 614 COMPONENTS AND 561 FLIGHT POINTS.
	--
	-- Scanning every flight point for every stranded component is 688,000
	-- distance calls inside build(), which is what pushed the report and the
	-- router model past the watchdog. World positions are in yards, so they
	-- bucket: look in the candidate's own cell, widen a ring at a time, and
	-- stop one ring after the first hit -- a point just over a cell boundary
	-- can beat one in the corner of the cell that found it.
	--
	-- The linear scan stays as the fallback. An island far from any flight
	-- point would otherwise find nothing and be reported unbridgeable, which
	-- would be a lie told by an optimisation.
	--
	-- The stopping rule is NOT "one ring past the first hit" -- that was the
	-- first version and it was wrong: a point found in the far corner of ring
	-- R can be beaten by one several rings further out. Checked against brute
	-- force on random layouts, it disagreed on 49 of 1,600 queries, by up to
	-- 16,700 yards. Any cell in ring R+1 is at least R*CELL away, so the sound
	-- rule is to stop only once the best distance found beats that bound.
	local CELL = 2000
	local grid = {}
	for c, list in pairs(byContinent) do
		local g = {}
		for _, m in ipairs(list) do
			local cx = math.floor(m.world.x / CELL)
			local cy = math.floor(m.world.y / CELL)
			g[cx] = g[cx] or {}
			g[cx][cy] = g[cx][cy] or {}
			table.insert(g[cx][cy], m)
		end
		grid[c] = g
	end

	local MAX_RING = 48
	local function nearestFlight(c, w)
		local g, bucket = grid[c], byContinent[c]
		if not (g and w) then return nil end
		local cx = math.floor(w.x / CELL)
		local cy = math.floor(w.y / CELL)
		local bestD, bestName
		for ring = 0, MAX_RING do
			for ix = cx - ring, cx + ring do
				local col = g[ix]
				if col then
					for iy = cy - ring, cy + ring do
						-- only the perimeter: the interior was done last ring
						if ring == 0 or ix == cx - ring or ix == cx + ring
							or iy == cy - ring or iy == cy + ring then
							for _, m in ipairs(col[iy] or {}) do
								local d = U.WorldDistance(w, m.world)
								if d and (not bestD or d < bestD) then
									bestD, bestName = d, m.name
								end
							end
						end
					end
				end
			end
			if bestD and bestD <= ring * CELL then return bestD, bestName end
		end
		if bestD then return bestD, bestName end
		-- Nothing within MAX_RING cells: answer exactly rather than not at all.
		for _, m in ipairs(bucket or {}) do
			local d = U.WorldDistance(w, m.world)
			if d and (not bestD or d < bestD) then bestD, bestName = d, m.name end
		end
		return bestD, bestName
	end

	-- ONLY THE COMPONENTS A GOAL CAN ACTUALLY LAND IN.
	--
	-- The graph is 614 components, and the first cut bridged all 613 of the
	-- minor ones. That was 150x the necessary work -- and worse than wasteful,
	-- because each bridge pulls its component into the searchable set, so
	-- every Dijkstra afterwards walked ~700 extra nodes belonging to places no
	-- mount is in. `push()` became the hot spot and both the report and the
	-- router model stopped finishing.
	--
	-- Measured: of 614 components, exactly 5 contain a zone that an obtainable
	-- record names, and 4 of those are not the mainland. Four bridges is the
	-- whole job. The rest are positionless taxi fragments and sub-zones no
	-- goal has ever referenced, and connecting them buys nothing but frontier.
	local goalZones = {}
	local anyGoalZone = false
	-- NOT a table constructor plus ipairs.
	--
	-- { rec.zone and rec.zone.name, rec.instance and ..., rec.vendor and ... }
	-- has a nil hole whenever a record lacks the first of the three, and ipairs
	-- stops dead at the first nil -- so every record without a `zone` field
	-- contributed nothing, and the set came out empty. That is what "no goal
	-- zones known when the graph was built" was: not a load-order problem, a
	-- Lua one.
	local function noteZone(z)
		if z and z ~= "" then
			goalZones[z:lower()] = true
			anyGoalZone = true
		end
	end
	for _, rec in ipairs(MM.DBList or {}) do
		if rec.obtainable then
			noteZone(rec.zone and rec.zone.name)
			noteZone(rec.instance and rec.instance.name)
			noteZone(rec.vendor and rec.vendor.zone)
		end
	end
	local wanted = {}
	if anyGoalZone then
		for zone, names in pairs(byZone) do
			if goalZones[zone] then
				-- comp[k] is nil for an alias; never index `wanted` with it.
				for _, k in ipairs(names) do
					if comp[k] then wanted[comp[k]] = true end
				end
			end
		end
	end
	-- If the database is not loaded yet there is nothing to be relevant TO,
	-- and bridging every component "just in case" is the behaviour this
	-- replaces. Say so instead.
	-- NOT `anyGoalZone and nil or "..."`. The and/or ternary cannot carry a
	-- nil: `true and nil` is falsy, so `or` takes over and the message is
	-- returned in BOTH cases. The report duly printed "no goal zones known"
	-- next to "13 of them hold a goal", which is a straight contradiction.
	if anyGoalZone then
		J.bridgeWhy = nil
	else
		J.bridgeWhy = "no goal zones known when the graph was built"
	end

	-- Candidate ends per stranded component, capped: one good edge connects a
	-- component, and scanning every node of every island is how the graph
	-- rebuild became "script ran too long" the last time.
	local CANDIDATES = 2
	local cands = {}
	for name, n in pairs(graph) do
		local id = comp[name]
		-- `id` IS NIL FOR AN ALIAS, because the walk above deliberately does not
		-- seed from one. An alias shares its node's table, so it passes the x/y
		-- test, and `cands[nil]` is "table index is nil" -- which is exactly how
		-- Router:Build() started throwing at Journey.lua:348. Excluding aliases
		-- in one place and not the other is the whole bug.
		if id and id ~= main and n.x and n.y then
			cands[id] = cands[id] or {}
			if #cands[id] < CANDIDATES then cands[id][#cands[id] + 1] = name end
		end
	end

	-- NO BRIDGE IS EVER FREE.
	--
	-- The first cut priced a bridge at its raw distance, and Raven Hill's
	-- flight point sits on exactly the same ground as a Raven Hill transit
	-- endpoint that landed in another component -- distance 0, so the edge
	-- cost 0. A zero-cost edge is teleportation: Dijkstra pops the whole of
	-- both components at the same distance, and the search that used to
	-- finish started tripping the watchdog at Journey.lua:836. It also broke
	-- the invariant outright, which is how it was caught.
	--
	-- Same ground still costs something to cross, and BorderData already
	-- decided what: 5 seconds, "the two coordinates are the same piece of
	-- ground seen from either side". A bridge is the same statement.
	local MIN_BRIDGE_SECONDS = 5

	local made, skipped, compares = 0, 0, 0
	J.bridgeDetail = {}
	J.bridgeRelevant = 0
	for id in pairs(sizes) do
		if id ~= main and wanted[id] then
			J.bridgeRelevant = J.bridgeRelevant + 1
			local bestD, bestA, bestB
			for _, name in ipairs(cands[id] or {}) do
				local n = graph[name]
				local c, w = nodeWorld(name, n.mapID or (n.zone and mapFor(n.zone)),
					n.x, n.y)
				compares = compares + 1
				local d, to = nearestFlight(c, w)
				if d and (not bestD or d < bestD) then
					bestD, bestA, bestB = d, name, to
				end
			end
			if bestA then
				local secs = math.max(bestD / ypm * 60, MIN_BRIDGE_SECONDS)
				addEdge(bestA, bestB, secs, "fly")
				addEdge(bestB, bestA, secs, "fly")
				made = made + 1
				J.bridgeDetail[#J.bridgeDetail + 1] = {
					from = graph[bestA].name, to = graph[bestB].name,
					yards = bestD, minutes = secs / 60,
				}
			else
				skipped = skipped + 1
			end
		end
	end
	J.bridges, J.bridgeSkipped, J.bridgeCompares = made, skipped, compares
end

local function build()
	if graph then return end
	graph, byZone, edges = {}, {}, {}
	aliasKey = {}

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
			if not graph[alias] then
				graph[alias] = graph[key]
				aliasKey[alias] = true
			end
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
	local function transitNode(idx, side, zone, x, y, mapID)
		local zl = zone:lower()
		local key = ("\2%d%s"):format(idx, side)
		graph[key] = { name = zone, zone = zl, x = x, y = y, kind = "transit",
			mapID = mapID }
		byZone[zl] = byZone[zl] or {}
		table.insert(byZone[zl], key)
		linkNodes = linkNodes + 1
		return key
	end
	for i, L in ipairs(MM.TransitLinks or {}) do
		if L.faction and myFaction and L.faction ~= myFaction then
			gatedOut = gatedOut + 1
		else
			-- AN "INSIDE" END IS AT ITS DOOR.
			--
			-- 0,0 means "inside the instance" rather than a coordinate, and
			-- these links were skipped entirely to avoid planting a node in the
			-- map's corner. But skipping them threw away the DOORS -- the only
			-- edges connecting the outdoor world to an instance -- so a goal in
			-- Tazavesh, the Veiled Market could be left and never entered. The
			-- report said it plainly: 14 goal attachments and no path.
			--
			-- Where you stand to enter is the far end of the link. So an inside
			-- end takes the outside end's map and coordinate: not invented, just
			-- the door's own position, which is the honest answer to "where do I
			-- go for this".
			local ax, ay, amap = L.ax, L.ay, L.amap
			local bx, by, bmap = L.bx, L.by, L.bmap
			if L.ainside then ax, ay, amap = bx, by, bmap end
			if L.binside then bx, by, bmap = L.ax, L.ay, L.amap end
			local ka = transitNode(i, "a", L.a, ax, ay, amap)
			local kb = transitNode(i, "b", L.b, bx, by, bmap)
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
	local crossSkipped = 0
	for _, names in pairs(byZone) do
		for i = 1, #names do
			for k = i + 1, #names do
				local a, b = graph[names[i]], graph[names[k]]
				local d, crossContinent = yards(a.zone, a.x, a.y, b.zone, b.x, b.y,
					a.mapID, b.mapID)
				-- You cannot fly between continents. Two nodes sharing a zone
				-- NAME across two continents are not one zone, and an edge
				-- between them is a route that does not exist.
				if crossContinent then
					crossSkipped = crossSkipped + 1
				else
					local secs = d / ypm * 60
					addEdge(names[i], names[k], secs, "fly")
					addEdge(names[k], names[i], secs, "fly")
				end
			end
		end
	end
	J.crossContinentSkipped = crossSkipped

	bridgeIslands(ypm)
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
-- One cached attachment, scored: how many of its entry points share the
-- continent it was measured from, and how many do not.
--
-- MEASURE AGAINST THE MAP THE ROUTER USED. nodeWorld converts with
-- `n.mapID or mapFor(n.zone)`, and a transit node's own map is not always its
-- zone's canonical one -- a link whose far end sits in a sub-map is still filed
-- under the parent zone's name, because that is what the link states. Reading
-- mapFor alone converted those coordinates against the wrong rectangle, so this
-- could invent an offender, or miss a real one, entirely on its own doing.
local function scoreAttachment(cached)
	local U = MM.Util
	local hereC = cached.originContinent
	if not hereC then return nil, cached.why or "no origin continent recorded" end
	local same, other = 0, 0
	for _, p in ipairs(cached) do
		local n = graph[p.name]
		local mz = n and (n.mapID or (n.zone and mapFor(n.zone)))
		local c = mz and select(1, U.GetWorldPos(mz, n.x or 50, n.y or 50))
		if c == hereC then same = same + 1 else other = other + 1 end
	end
	return same, other
end

-- EVERY attachment the route actually made, rather than a few chosen zones.
--
-- The check that owns this invariant named four zones. Four cannot speak for
-- two hundred, and the ones worth probing are exactly the ones nobody thinks to
-- list: a zone whose continent holds almost no nodes, where "nearest" has least
-- to choose from and the most room to be wrong. Deepholm is one -- its
-- continent carries five nodes and not one flight point, because the client has
-- no flight master there at all and the way in is a portal.
--
-- Walking the cache costs nothing and covers whatever the player's own route
-- touched, which is the only set that ever mattered.
function J.AttachAuditAll()
	build()
	local zones, offending, worst, worstN = 0, 0, nil, 0
	for key, cached in pairs(nearZoneCache) do
		if type(cached) == "table" then
			local same, other = scoreAttachment(cached)
			if same then
				zones = zones + 1
				if other > 0 then
					offending = offending + other
					if other > worstN then
						worstN, worst = other, (key:gsub("#[^#]*$", ""))
					end
				end
			end
		end
	end
	return zones, offending, worst
end

function J.AttachAudit(zone, x, y, mapID)
	build()
	if not zone then return nil end
	local zl = zone:lower()
	local own = byZone[zl]
	if own and #own > 0 then return #own, 0, "own zone" end
	-- Same key attachPoints used, including the map, or this reads someone
	-- else's answer and reports on a plan that never happened.
	local cached = nearZoneCache[zl .. "#" .. tostring(mapID or "?")]
	if not cached then return nil end
	-- THE CONTINENT attachPoints ACTUALLY MEASURED FROM.
	--
	-- For an instance that is its DOOR's outdoor map, not the interior. This
	-- check first re-derived it from the zone name, got the interior, and
	-- reported 16 attachments on "another continent" that were entirely its own
	-- doing -- a false alarm on working code, which costs as much trust as a
	-- missed fault. Read the value that was used; never reconstruct it.
	local same, other, why = scoreAttachment(cached)
	if not same then return 0, 0, why end
	-- A ZERO STILL HAS TO EXPLAIN ITSELF. The reason was recorded and then only
	-- returned when the origin continent was missing -- so the one case left
	-- standing, "nothing anywhere shares its continent", printed as a bare 0 and
	-- cost another round to identify.
	if same == 0 and other == 0 then
		return 0, 0, cached.why or "nearest elsewhere, but nothing qualified"
	end
	return same, other, "nearest elsewhere"
end

------------------------------------------------------------
-- Travel from where you are standing, to everywhere, in one search
------------------------------------------------------------
-- WHY THIS EXISTS.
--
-- "Add 10 Easiest" was instant, and that was the tell: it did no routing at
-- all. Its only travel input was a three-valued flag -- 0 same continent, 1
-- another, 0.5 unknown -- so on your own continent every candidate scored
-- travel 0, and a mount 30 seconds away ranked identically to one 8 minutes
-- away. Ordering could be fixed later by the route's third layer; SELECTION
-- could not, because layer 3 can only reorder what it was handed.
--
-- The reason it was a flag is that pricing N candidates looked like N
-- searches. It is not. Travel FROM ONE PLACE to everywhere is a single
-- Dijkstra with no goal -- the same cost as one route leg -- and every node's
-- distance falls out of it at once. This is that search, cached until you
-- move, so the ease score can use real minutes.
local fromCache, fromCacheKey = nil, nil

function J.ForgetTravelFrom()
	fromCache, fromCacheKey = nil, nil
end

-- seconds-from-here for every node, or nil if we cannot stand anywhere known.
local function travelFrom(zone, x, y, mapID)
	if not zone then return nil end
	-- The travel fingerprint belongs here even though this search wires no
	-- teleports: its edges come from the graph, and a learned flight point
	-- changes the graph. J.Forget drops this cache as well, so the fingerprint
	-- is the second line of defence rather than the first -- and the cheap one
	-- to be wrong about.
	local key = ("%s#%s#%.1f#%.1f#%s"):format(zone:lower(), tostring(mapID or "?"),
		x or -1, y or -1, MM.TravelFingerprint and MM.TravelFingerprint() or "?")
	if fromCacheKey == key and fromCache then return fromCache end
	build()

	local ypm = J.SpeedFor(nil)
	local SRC = "\1from"
	edges[SRC] = {}
	local attached = 0
	for _, p in ipairs(attachPoints(zone:lower(), x, y, mapID)) do
		addEdge(SRC, p.name, p.d / ypm * 60, "fly")
		attached = attached + 1
	end
	if attached == 0 then edges[SRC] = nil return nil end

	-- Plain Dijkstra, no early exit: we want every node, not one.
	local dist, visited = { [SRC] = 0 }, {}
	local heap, hn = { { SRC, 0 } }, 1
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
		heap[1], heap[hn], hn = heap[hn], nil, hn - 1
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
	while hn > 0 do
		local cur = pop()
		if cur and not visited[cur] then
			visited[cur] = true
			local d = dist[cur]
			for nb, e in pairs(edges[cur] or {}) do
				local alt = d + e.secs
				if not dist[nb] or alt < dist[nb] then
					dist[nb] = alt
					push(nb, alt)
				end
			end
		end
	end
	edges[SRC] = nil
	dist[SRC] = nil
	fromCache, fromCacheKey = dist, key
	return dist
end

-- MINUTES from where you stand to a place, using the one-search table.
--
-- Returns nil rather than a number when the place cannot be reached or is not
-- in the graph. A caller that cannot tell "far" from "unknown" will charge a
-- guess as if it were a measurement, which is the mistake this whole layer
-- exists to stop making.
function J.MinutesFrom(fromZone, fromX, fromY, fromMapID, toZone, toX, toY, toMapID)
	if not (fromZone and toZone) then return nil end
	local dist = travelFrom(fromZone, fromX, fromY, fromMapID)
	if not dist then return nil end
	local ypm = J.SpeedFor(nil)
	local best
	for _, p in ipairs(attachPoints(toZone:lower(), toX, toY, toMapID)) do
		local d = dist[p.name]
		if d then
			local total = d + (p.d / ypm * 60)
			if not best or total < best then best = total end
		end
	end
	return best and (best / 60) or nil
end

function J.Stats()
	build()
	local n, e = 0, 0
	for _ in pairs(graph) do n = n + 1 end
	for _, t in pairs(edges) do for _ in pairs(t) do e = e + 1 end end
	return n, e
end

-- Plan a journey. Returns total MINUTES and an ordered list of legs.
-- fromMapID/toMapID are OPTIONAL but strongly preferred. The caller already
-- knows which map it is routing to; resolving the zone NAME back to a map here
-- can land on a different one. "The Forbidden Reach" is two maps, the router
-- meant 2118, and the name resolved to the other -- which has no world
-- position, so the destination could not be attached at all and every journey
-- there reported "no way to reach the forbidden reach from the graph".
-- EVERY INPUT THAT MOVES THE ANSWER IS IN THE KEY.
--
-- The key was zone names and map ids. The answer also depends on the exact
-- COORDINATES at each end (they decide which node the journey attaches to and
-- how far the walk to it is), on the direct-flight cost handed in as a rival
-- edge, on which teleports this character currently has, and on which of them
-- the caller has already spent. None of those were in it, so:
--
--   two stops in one zone shared one answer, and the second got the first's
--   route -- including its ENTRY NODE, which may be on the far side
--   a cheaper direct flight could not beat a cached answer computed without it
--   a teleport switched off stayed in a plan that had already been cached
--   a "no path" for one corner of a zone suppressed a real route from another
--
-- 0.1 of a coordinate unit is the rounding, which at ~40 yards per unit is
-- about four yards -- an order of magnitude finer than the distance at which
-- any entry-node choice could change, and fine enough that the reuse that
-- matters (the same leg asked twice) is still an exact hit.
local function planKey(fromZone, fromX, fromY, fromMapID,
		toZone, toX, toY, toMapID, directFlyMinutes, used)
	local spent = ""
	if used then
		local keys = {}
		for k in pairs(used) do keys[#keys + 1] = tostring(k) end
		table.sort(keys)
		spent = table.concat(keys, ",")
	end
	return ("%s#%s@%.1f,%.1f|%s#%s@%.1f,%.1f|f%.2f|t%s|u%s"):format(
		fromZone, tostring(fromMapID or "?"), fromX or -1, fromY or -1,
		toZone, tostring(toMapID or "?"), toX or -1, toY or -1,
		directFlyMinutes or -1,
		MM.TravelFingerprint and MM.TravelFingerprint() or "?",
		spent)
end

-- A COMPLETE KEY IS AN UNBOUNDED KEY, so the cache needs a ceiling.
--
-- Keyed on zone pairs, this could only ever hold as many entries as there are
-- pairs of zones. Keyed on coordinates it can hold one per leg per origin per
-- spent-charge set, which across a long session is unbounded growth in a
-- process that never restarts.
--
-- Cleared wholesale rather than evicted one at a time: the entries are worth a
-- Dijkstra each, they are all cheap to recompute on demand, and an LRU over a
-- table this size costs more bookkeeping than it saves. The cap is generous
-- enough that a single route build -- roughly two entries per stop -- never
-- reaches it.
local PLAN_CACHE_MAX = 4000

local function rememberPlan(key, value)
	if planCacheSize >= PLAN_CACHE_MAX then
		planCache, planWhy, planCacheSize = {}, {}, 0
		J.planCacheFlushes = (J.planCacheFlushes or 0) + 1
	end
	if planCache[key] == nil then planCacheSize = planCacheSize + 1 end
	planCache[key] = value
	return value
end

function J.Plan(fromZone, fromX, fromY, toZone, toX, toY, directFlyMinutes,
		fromMapID, toMapID, used)
	build()
	planCache = planCache or {}
	if not (fromZone and toZone) then return nil, nil, "no zone name at one end" end
	fromZone, toZone = fromZone:lower(), toZone:lower()

	local key = planKey(fromZone, fromX, fromY, fromMapID,
		toZone, toX, toY, toMapID, directFlyMinutes, used)
	local hit = planCache[key]
	if hit ~= nil then
		if hit == false then return nil, nil, planWhy[key] end
		-- minutes, legs, why, spends. `why` stays in third position because a
		-- failure already answers there and a caller reading it must not
		-- suddenly receive a table.
		return hit[1], hit[2], nil, hit[3]
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

	local fromCount, toCount = 0, 0
	for _, p in ipairs(attachPoints(fromZone, fromX, fromY, fromMapID)) do
		addEdge(START, p.name, p.d / ypm * 60, "fly")
		fromCount = fromCount + 1
	end
	-- REMEMBER EXACTLY WHAT WAS ATTACHED, so exactly that can be removed.
	local goalAttached = {}
	for _, p in ipairs(attachPoints(toZone, toX, toY, toMapID)) do
		addEdge(p.name, GOAL, p.d / ypm * 60, "fly")
		goalAttached[#goalAttached + 1] = p.name
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
			-- ALREADY SPENT IS NOT AVAILABLE.
			--
			-- A one-use teleport offered on leg two is gone by leg nine, and
			-- the planner had no way to be told so -- it re-offered the same
			-- hearthstone for every leg of a route, and the route was costed
			-- as though the player owned one per stop.
			local spent = used and landing.key and used[landing.key]
			local lz = (not spent) and landing.place and landing.place:lower() or nil
			local target = lz and (byZone[lz] and lz or nil)
			if target then
				-- Land at every node in the destination zone; the graph sorts
				-- out which one is actually worth walking to.
				for _, name in ipairs(byZone[target]) do
					addEdge(START, name, (landing.waitMinutes or 0) * 60 + 30,
						"teleport:" .. (landing.name or "?"), landing.key)
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

	-- TEAR DOWN EVERY GOAL EDGE THIS PLAN ADDED, not just the ones in the
	-- destination's own zone.
	--
	-- The cleanup walked byZone[toZone]. When the goal attached through the
	-- nearest-elsewhere fallback, its entry points are by definition NOT in
	-- that zone -- so their "-> GOAL" edges were never removed and stayed in
	-- the graph for the rest of the session. Every later plan then found a
	-- stale, cheap edge to a goal that no longer existed and routed to it.
	--
	-- That is why four legs with different origins AND different destinations
	-- came back with the same route and the same 1.7 minutes, and why a
	-- destination with 21 entry points of its own still ended at a node in the
	-- Emerald Dream: the graph was answering a question from several plans ago.
	edges[START] = nil
	for _, name in ipairs(goalAttached) do
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
		rememberPlan(key, false)
		planWhy[key] = why
		return nil, nil, why
	end

	local legs, node = {}, GOAL
	local spends = nil
	while prev[node] do
		local from, e = prev[node][1], prev[node][2]
		local label = temp[node] and "your goal" or (graph[node] and graph[node].name or node)
		-- The resource travels WITH the leg. A caller that needs to know what
		-- this journey costs in charges reads it here rather than parsing the
		-- description it is about to show a player.
		table.insert(legs, 1, { mode = e.mode, to = label, minutes = e.secs / 60,
			resource = e.resource })
		if e.resource then
			spends = spends or {}
			spends[e.resource] = true
		end
		node = from
	end
	rememberPlan(key, { best / 60, legs, spends })
	return best / 60, legs, nil, spends
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
	-- A PORTAL IS NOT FREE JUST BECAUSE IT ROUNDS TO ZERO.
	--
	-- Every leg printed "(%.0f min)", so a 15-second portal read "0 min" and a
	-- thirteen-leg chain read as thirteen free steps and a one-minute total.
	-- The arithmetic was right the whole time; the rendering made the router
	-- look broken, and made a long chain look costless when it is the thing
	-- most worth questioning.
	local function legTime(m)
		if not m or m <= 0 then return "0s" end
		if m < 1 then return ("%.0fs"):format(m * 60) end
		return ("%.0f min"):format(m)
	end
	local bits, total = {}, 0
	for _, leg in ipairs(out) do
		total = total + (leg.minutes or 0)
		bits[#bits + 1] = ("%s %s (%s)"):format(VERB[leg.mode] or leg.mode,
			leg.to, legTime(leg.minutes))
	end
	local text = table.concat(bits, ", then ")
	-- The hop count is the part a player judges the route by. Say it.
	if #out > 1 then
		text = ("%s  [%d legs, %s]"):format(text, #out, legTime(total))
	end
	return text
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
