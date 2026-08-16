-- Master Mounts: portals learned from the map, rather than asked for.
--
-- Data/TravelNetwork.lua ships 1,156 endpoints and 238 connections, extracted
-- once. Content keeps arriving, and every new zone that arrives is off the
-- network until somebody records its portal by hand. Voidstorm and K'aresh both
-- sat in that state: every journey into them was priced as leave-and-return,
-- so travel to all fourteen Voidstorm goals cost the same and none of them
-- could be grouped by geography.
--
-- Asking a player to stand at each end and read coordinates off the screen is
-- not the answer. THE CLIENT ALREADY PUBLISHES BOTH ENDS. A zone's map carries
-- its portals as points of interest, each with a name and a position:
--
--   Eversong Woods (2395)   "Portal to Voidstorm"
--   Voidstorm      (2405)   "Portal to Silvermoon"
--   K'aresh        (2371)   "Portal to Dornogal"
--
-- Two of those are the same portal seen from its two ends, which is exactly an
-- edge. This module reads them and joins the zone to the graph.
--
-- WHAT IS ASSUMED, stated plainly: that a portal POI is where you both arrive
-- and depart. They are the same object on the ground, so the position is one
-- position. Nothing else here is inferred -- names, coordinates and map ids all
-- come from C_AreaPoiInfo and C_Map, and a pair that cannot be matched is left
-- alone rather than guessed at.
local _, MM = ...

MM.PortalLearn = {}
local PL = MM.PortalLearn

------------------------------------------------------------
-- Reading a destination out of a point of interest
------------------------------------------------------------
-- The verbs the client actually uses on travel POIs, and the travel method
-- each one is. The method decides the leg's duration through
-- MM.TravelDefaultSeconds, so calling a zeppelin a portal would price a
-- two-minute flight at fifteen seconds.
--
-- Lowercased keys; the match is case-folded so wording changes in either
-- direction still land.
local VERBS = {
	["portal"]    = "portal",
	["teleporter"]= "portal",
	["waystone"]  = "portal",
	["rootway"]   = "portal",
	["gateway"]   = "portal",
	["zeppelin"]  = "zeppelin",
	["boat"]      = "ship",
	["ship"]      = "ship",
	["ferry"]     = "ship",
	["tram"]      = "tram",
}

-- "Portal to Voidstorm" -> "Voidstorm", "portal"
-- "Zeppelin to Orgrimmar" -> "Orgrimmar", "zeppelin"
-- "Portal Room" -> nil (names no destination)
--
-- ONLY the "<verb> to <place>" shape. "Eversong Rootway" names a rootway
-- without saying where it goes, and inventing the other end from the zone it
-- sits in is how you get a portal that points at itself.
function PL.Parse(text)
	if type(text) ~= "string" then return nil end
	local verb, dest = text:match("^%s*([%a']+)%s+[Tt][Oo]%s+(.+)%s*$")
	if not (verb and dest) then return nil end
	local method = VERBS[verb:lower()]
	if not method then return nil end
	dest = dest:gsub("%s+$", "")
	if dest == "" then return nil end
	return dest, method
end

------------------------------------------------------------
-- Pairing the two ends
------------------------------------------------------------
-- PURE, and separated from every client call on purpose: this is the part that
-- can be wrong in a way no amount of staring finds, so it is exercised offline
-- against the exact strings the client was observed to produce.
--
--   pois      array of { mapID, rawName, rawDesc, position = { x, y } }
--   resolve   function(name) -> mapID or nil          (C_Map name index)
--   parentOf  function(mapID) -> mapID or nil         (containing map)
--
-- Returns an array of links, each naming both ends:
--   { fromMap, fromX, fromY, toMap, toX, toY, method, dest, back }
--
-- A link is emitted ONLY when both ends were actually read. One end plus an
-- assumption about the other is how a route sends somebody into open water.
function PL.Pair(pois, resolve, parentOf)
	resolve = resolve or function() return nil end
	parentOf = parentOf or function() return nil end

	-- Same map, or one contains the other. Silvermoon City is its own map
	-- inside Eversong Woods, so Voidstorm's "Portal to Silvermoon" names a
	-- CHILD of the map holding the portal that points back at it. Requiring
	-- exact equality would refuse the one pair this was written for.
	local function related(a, b)
		if not (a and b) then return false end
		if a == b then return true end
		return parentOf(a) == b or parentOf(b) == a
	end

	-- Parse every POI once. A portal may name its destination in either the
	-- name or the description.
	local parsed, byMap = {}, {}
	for _, poi in ipairs(pois or {}) do
		local pos = poi.position
		local x = pos and (pos.x or pos[1])
		local y = pos and (pos.y or pos[2])
		if poi.mapID and x and y then
			local dest, method = PL.Parse(poi.rawName)
			if not dest then dest, method = PL.Parse(poi.rawDesc) end
			if dest then
				local entry = {
					mapID = poi.mapID, x = x, y = y,
					dest = dest, destMap = resolve(dest), method = method,
				}
				parsed[#parsed + 1] = entry
				byMap[poi.mapID] = byMap[poi.mapID] or {}
				local list = byMap[poi.mapID]
				list[#list + 1] = entry
			end
		end
	end

	local links, seen = {}, {}
	for _, out in ipairs(parsed) do
		local far = out.destMap
		if far and not related(far, out.mapID) then
			local candidates = byMap[far]
			local back
			if candidates then
				-- The return leg names this map, or a map containing it.
				for _, c in ipairs(candidates) do
					if related(c.destMap, out.mapID) then back = c; break end
				end
				-- ONE PORTAL AND NOTHING ELSE.
				--
				-- Voidstorm's return portal reads "Portal to Silvermoon", and
				-- whether that name resolves at all depends on the client's
				-- index. When the far side has exactly one travel POI there is
				-- nothing to be ambiguous about: the only portal in a zone
				-- this portal points into IS the way back. With two or more,
				-- picking one would be a guess, so nothing is emitted.
				if not back and #candidates == 1 then back = candidates[1] end
			end
			if back then
					-- ONE LINK PER UNORDERED PAIR OF ENDPOINTS.
					--
					-- Both ends are normally found, because both maps get
					-- scanned: K'aresh names Dornogal and Dornogal names
					-- K'aresh, so the same portal is discovered twice, once
					-- from each side. The key therefore has to describe the
					-- PAIR regardless of which side was walked first -- each
					-- endpoint written out in full, and the two sorted.
					local e1 = ("%d:%.4f:%.4f"):format(out.mapID, out.x, out.y)
					local e2 = ("%d:%.4f:%.4f"):format(far, back.x, back.y)
					local key = (e1 < e2) and (e1 .. ">" .. e2)
						or (e2 .. ">" .. e1)
				if not seen[key] then
					seen[key] = true
					links[#links + 1] = {
						fromMap = out.mapID, fromX = out.x, fromY = out.y,
						toMap = far, toX = back.x, toY = back.y,
						method = out.method or back.method or "portal",
						dest = out.dest, back = back.dest,
					}
				end
			end
		end
	end
	table.sort(links, function(a, b)
		if a.toMap ~= b.toMap then return a.toMap < b.toMap end
		return (a.dest or "") < (b.dest or "")
	end)
	return links
end

------------------------------------------------------------
-- Turning links into network nodes and edges
------------------------------------------------------------
local function nodeKey(mapID, x, y, dest)
	-- Destination names carry apostrophes, spaces and dashes -- K'aresh,
	-- "Dalaran - Northrend" -- and the key is read back in diagnostics, so
	-- anything that is not a letter or a digit becomes an underscore.
	local place = (dest or "PORTAL"):upper():gsub("%W", "_")
	return ("LEARNED_%d_%s_%d_%d"):format(mapID, place,
		math.floor(x * 10000), math.floor(y * 10000))
end

-- The group an added node belongs to, so the graph can fly between it and the
-- rest of its zone. Taken from a node ALREADY on that map -- never invented. A
-- zone with no nodes at all (which is the whole point here) gets none, and
-- that costs nothing: its single portal is reached through the portal edge,
-- and travel onward from it is priced by distance like any other arrival.
local function groupFor(mapID)
	for _, n in pairs(MM.TravelNodes or {}) do
		if tonumber(n.mapID) == mapID and n.group then return n.group end
	end
	return nil
end

-- Add one learned link to the live network. Returns the two keys, or nil if
-- either endpoint was already present.
function PL.Apply(link)
	if not (MM.TravelNodes and MM.TravelEdges and link) then return nil end
	local aKey = nodeKey(link.fromMap, link.fromX, link.fromY, link.dest)
	local bKey = nodeKey(link.toMap, link.toX, link.toY, link.back)
	if MM.TravelNodes[aKey] or MM.TravelNodes[bKey] then return nil end

	local aName = ("Portal to %s"):format(link.dest or "?")
	local bName = ("Portal to %s"):format(link.back or "?")
	-- x/y are stored 0-1 here exactly as the rest of the table stores them.
	MM.TravelNodes[aKey] = { name = aName, mapID = link.fromMap,
		x = link.fromX, y = link.fromY, group = groupFor(link.fromMap),
		learned = true }
	MM.TravelNodes[bKey] = { name = bName, mapID = link.toMap,
		x = link.toX, y = link.toY, group = groupFor(link.toMap),
		learned = true }
	-- BOTH DIRECTIONS. A portal read from both ends is a portal you can walk
	-- back through; that is what having read both ends establishes. A one-way
	-- zeppelin is never emitted, because only one end of it would be found.
	local edges = MM.TravelEdges
	edges[#edges + 1] = { from = aKey, to = bKey, method = link.method, learned = true }
	edges[#edges + 1] = { from = bKey, to = aKey, method = link.method, learned = true }
	return aKey, bKey
end

------------------------------------------------------------
-- Scanning
------------------------------------------------------------
PL.learned = PL.learned or {}   -- links applied this session
PL.scanned = false

-- Maps worth asking about: every zone holding a planned goal that the network
-- cannot reach, plus every map those zones' portals name. The second pass is
-- what finds the far end -- K'aresh names Dornogal, and Dornogal is where the
-- portal back to K'aresh lives.
local function candidateMaps()
	local maps = {}
	local J = MM.Journey
	if not (J and J.ZoneOnNetwork) then return maps end
	for _, rec in pairs(MM.DBByName or {}) do
		local z = rec.zone
		if z and z.mapID and not J.ZoneOnNetwork(z.mapID) then
			local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(z.mapID)
			-- A raid is entered by its own door, never by a portal on a zone
			-- map, so there is nothing here to find. mapType 3 is a zone.
			if not info or not info.mapType or info.mapType <= 3 then
				maps[z.mapID] = true
			end
		end
	end
	return maps
end

-- Read every candidate map's POIs, then every map they point at.
function PL.Scan()
	local A = MM.Assaults
	if not (A and A.PoisForMap and MM.TravelNodes) then return 0 end
	local U = MM.Util
	local resolve = function(name)
		return U and U.ResolveMapByName and U.ResolveMapByName(name) or nil
	end
	local parentOf = function(mapID)
		local info = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
		return info and info.parentMapID
	end

	local pois, asked = {}, {}
	local function ask(mapID)
		if not mapID or asked[mapID] then return end
		asked[mapID] = true
		local ok, list = pcall(A.PoisForMap, mapID)
		if ok and type(list) == "table" then
			for _, poi in ipairs(list) do pois[#pois + 1] = poi end
		end
	end

	for mapID in pairs(candidateMaps()) do ask(mapID) end
	-- Second pass: whatever the first pass' portals named.
	local reach = {}
	for _, poi in ipairs(pois) do
		local dest = PL.Parse(poi.rawName) or PL.Parse(poi.rawDesc)
		if dest then
			local m = resolve(dest)
			if m then reach[m] = true end
		end
	end
	for mapID in pairs(reach) do ask(mapID) end

	local links = PL.Pair(pois, resolve, parentOf)
	local added = 0
	for _, link in ipairs(links) do
		if PL.Apply(link) then
			added = added + 1
			PL.learned[#PL.learned + 1] = link
		end
	end
	PL.scanned = true
	PL.mapsAsked = 0
	for _ in pairs(asked) do PL.mapsAsked = PL.mapsAsked + 1 end
	if added > 0 then
		-- The graph is memoised on first use and the route is cached against a
		-- fingerprint that now describes a different world.
		if MM.Network and MM.Network.Invalidate then MM.Network.Invalidate() end
		if MM.InvalidateTravelFingerprint then MM.InvalidateTravelFingerprint() end
		if MM.Router and MM.Router.InvalidateTravelTopology then
			MM.Router.InvalidateTravelTopology()
		end
	end
	return added
end

-- How many portals were learned, for the cache signature. A route ordered
-- before a zone joined the graph was ordered around a world that no longer
-- exists, the same way a newly learned flight point invalidates one.
function PL.Count() return #PL.learned end

------------------------------------------------------------
-- When this runs
------------------------------------------------------------
-- ONCE, AND LATE. C_AreaPoiInfo answers for any map from anywhere, so there is
-- no reason to run this on a handler or on a timer -- and every reason not to:
-- the one time this addon froze a client, it was a loop over maps running
-- eagerly during login. It reads a couple of dozen maps a single time, well
-- after the world has settled, and never again in the session.
local done = false
MM:RegisterGameEvent("PLAYER_ENTERING_WORLD", function()
	if done then return end
	done = true
	C_Timer.After(8, function()
		local ok, added = pcall(PL.Scan)
		if ok and added and added > 0 then
			MM:Debug("portals learned from the map: %d", added)
		end
	end)
end)
