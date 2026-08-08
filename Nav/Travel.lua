-- Master Mounts travel guidance: turns "your goal is on another continent"
-- into a concrete next step — which portal room, which portal, or whether to
-- just use your Hearthstone.
local _, MM = ...
local U = MM.Util

MM.Travel = {}
local T = MM.Travel

-- Continent instance IDs (returned by C_Map.GetWorldPosFromMapPos)
local EK, KALIMDOR = 0, 1

-- Faction capital portal rooms (approximate entrances; the arrow only needs
-- direction, and the instruction text carries the detail).
local CAPITAL = {
	Alliance = {
		continent = EK, city = "Stormwind City", mapID = 84, x = 49.5, y = 86.5,
		room = "the Wizard's Sanctum portal room (Mage Quarter)",
	},
	Horde = {
		-- REPORTED FROM PLAY, three separate mistakes in one instruction.
		--
		-- Pathfinder's Den is NOT in the Cleft of Shadow -- it is its own
		-- subzone, reached from the Gates of Orgrimmar, and the Cleft does not
		-- connect to it at all. Our own access notes said so already; this line
		-- simply disagreed with them.
		--
		-- The point is the one those notes researched, rather than a rounder
		-- number in the middle of the room.
		--
		-- AND THE FLOOR IS IN THE TEXT BECAUSE AN ARROW CANNOT SAY IT. A
		-- waypoint has no vertical axis, so it points at the room and a player
		-- standing on the wrong level is told they have arrived. Naming the
		-- stairs is the only fix available; pretending the arrow can do it is
		-- what made this read as a wrong location rather than a flat map.
		continent = KALIMDOR, city = "Orgrimmar", mapID = 85, x = 55.2, y = 92.0,
		room = "the Pathfinder's Den portal room, in the Gates of Orgrimmar "
			.. "-- take the stairs DOWN, the portals are not on the top floor",
	},
}

-- What to ride through in the capital portal room, per target continent.
local PORTAL_LABEL = {
	[530]  = "Shattrath portal",
	[571]  = "Dalaran (Northrend) portal",
	[870]  = "Jade Forest portal",
	[1116] = "Ashran portal",
	[1220] = "Azsuna portal",
	-- The portal is LABELLED Zuldazar in game, whatever the map is called.
	-- Reported from play: being told to take the Dazar'alor portal and finding
	-- no such thing is a worse instruction than no instruction.
	[1642] = "Zuldazar portal",
	[1643] = "Boralus portal",
	[2222] = "Oribos portal",
	[2444] = "Valdrakken portal",
	[2552] = "Dornogal portal",
	[EK]   = "Eastern Kingdoms portal",
	[KALIMDOR] = "Kalimdor portal",
}

-- Known portal hubs around the world. The arrow steers to the NEAREST hub on
-- the player's continent. Continents are resolved at runtime, so this adapts
-- to client changes automatically (e.g. wherever Midnight's Silvermoon lives).
local NODES = {
	-- neutral hubs
	{ mapID = 2112, x = 59.5, y = 41.5, name = "Valdrakken portal room", note = "Portal to the capital" },
	{ mapID = 2339, x = 57.0, y = 50.0, name = "Dornogal portal wall", note = "Portal to the capital" },
	{ mapID = 111, x = 57.0, y = 48.0, name = "Shattrath portals", note = "Portal to the capital" },
	-- Horde
	{ faction = "Horde", mapID = 1165, x = 51.3, y = 46.7, name = "Dazar'alor portal room", note = "Portal to Orgrimmar" },
	-- zoneName nodes resolve against EVERY map with that name on this client,
	-- so they keep working when an expansion revamps a city onto a new map
	-- (e.g. Midnight's Silvermoon).
	{ faction = "Horde", zoneName = "Silvermoon City", x = 55, y = 50, name = "Silvermoon City portals", note = "Portal to Orgrimmar" },
	{ faction = "Horde", zoneName = "Silvermoon", x = 55, y = 50, name = "Silvermoon portals", note = "Portal to Orgrimmar" },
	-- Alliance
	{ faction = "Alliance", mapID = 1161, x = 70.5, y = 17.2, name = "Boralus portal room", note = "Portal to Stormwind" },
}

local function candidatesFor(node)
	if node.candidates then return node.candidates end
	node.candidates = {}
	if node.mapID then
		local continent, world = U.GetWorldPos(node.mapID, node.x, node.y)
		if world then tinsert(node.candidates, { continent = continent, world = world }) end
	elseif node.zoneName then
		for _, mapID in ipairs(U.ResolveMapsByName(node.zoneName)) do
			local continent, world = U.GetWorldPos(mapID, node.x or 50, node.y or 50)
			if world then tinsert(node.candidates, { continent = continent, world = world }) end
		end
	end
	return node.candidates
end

local function nearestNode(playerContinent, playerWorld)
	if not (playerContinent and playerWorld) then return nil end
	local best, bestWorld, bestDist
	for _, node in ipairs(NODES) do
		if not node.faction or node.faction == MM.playerFaction then
			for _, cand in ipairs(candidatesFor(node)) do
				if cand.continent == playerContinent then
					local d = U.WorldDistance(playerWorld, cand.world) or math.huge
					if not bestDist or d < bestDist then
						best, bestWorld, bestDist = node, cand.world, d
					end
				end
			end
		end
	end
	return best, bestWorld
end

local function hearthSuggestion(targetContinent)
	local bindZone = MM.Util.ReadableString(GetBindLocation and GetBindLocation())
	if not bindZone or bindZone == "" then return nil end
	local mapID = U.ResolveMapByName(bindZone)
	if not mapID then return nil end
	local continent = U.GetWorldPos(mapID, 50, 50)
	if continent ~= targetContinent then return nil end
	-- hearth would land on the right continent; check its cooldown (spell 8690)
	local onCooldown = false
	pcall(function()
		local cd = C_Spell.GetSpellCooldown(8690)
		if cd and cd.duration and cd.duration > 300
			and (cd.startTime + cd.duration - GetTime()) > 300 then
			onCooldown = true
		end
	end)
	if onCooldown then return nil end
	return bindZone
end

-- Returns: subWorldPos (same-continent point to steer toward, or nil),
-- primary instruction (short, bold), secondary instruction (detail line).
function T.Guide(targetContinent, targetZoneName, playerContinent, playerWorld)
	targetZoneName = targetZoneName or "your goal"

	-- Hearthstone shortcut beats everything when it applies
	local hearthZone = hearthSuggestion(targetContinent)
	if hearthZone then
		return nil, "Use your Hearthstone",
			("Bound to %s — the right continent"):format(hearthZone)
	end

	local capital = CAPITAL[MM.playerFaction or "Alliance"]
	local portal = PORTAL_LABEL[targetContinent]
		or ("portal toward " .. tostring(targetZoneName))

	if playerContinent == capital.continent then
		local _, world = U.GetWorldPos(capital.mapID, capital.x, capital.y)
		return world, capital.city .. " portal room",
			("Take the %s (%s)"):format(portal, capital.room)
	end

	if not playerWorld then
		playerWorld = select(2, U.PlayerWorldPos())
	end
	local node, nodeWorld = nearestNode(playerContinent, playerWorld)
	if node then
		return nodeWorld, node.name,
			("%s, then the %s"):format(node.note, portal)
	end

	return nil, "Get to " .. capital.city,
		("Hearthstone, portal, or toy — then the %s"):format(portal)
end
