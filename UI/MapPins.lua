-- Master Mounts map pins: mount locations on the world map and the minimap.
--
-- THE WORLD MAP HALF OWNS NO PLACEMENT ARITHMETIC AT ALL.
--
-- Blizzard's map canvas is a zoom/pan surface with its own coordinate space,
-- and the only supported way onto it is a MapCanvasDataProvider that acquires
-- pins from the canvas and hands each one NORMALISED 0-1 coordinates through
-- SetPosition. The canvas then owns placement, zoom, pin scaling and culling.
--
-- An earlier version created its own frames on WorldMapFrame.ScrollContainer.Child
-- and placed them with SetPoint offsets multiplied by the canvas width. That
-- competes with the canvas on all four of those, and it only agrees with it
-- where the canvas happens to be drawn at scale 1 -- so pins landed on some
-- continent maps and vanished on every zone map, while the index counter proved
-- the points were there. Three passes at the offsets each fixed one map and
-- broke another, which is what a structural fault looks like from the inside.
-- There is no offset maths left in this file for the world map: two divisions by
-- 100 to normalise, and Blizzard does the rest.
--
-- HereBeDragons-Pins-2.0, which HandyNotes draws with, is the model for both
-- halves: the provider and pin mixins here, and the minimap's distance,
-- rotation and shape handling, which is its drawMinimapPin in this addon's own
-- measured axis basis.
local _, MM = ...
local U = MM.Util

MM.MapPins = {}
local MP = MM.MapPins

local PIN_TEMPLATE = "MasterMountsWorldMapPinTemplate"
local WORLD_PIN_SIZE, MINIMAP_PIN_SIZE = 18, 14

local max, sqrt, sin, cos, floor = math.max, math.sqrt, math.sin, math.cos, math.floor

------------------------------------------------------------
-- Which mounts have a location on the displayed map
------------------------------------------------------------
-- Cache: [mapID] = { { mapID, x, y, entries = { entry, ... } }, ... }
--
-- ONE PIN PER PLACE, NOT ONE PER MOUNT. The database describes 649 points
-- across only 148 distinct places, because a shared source is the normal case
-- rather than an oddity: Witherbark Pango and Amani Sharptalon drop from the
-- same thirteen Zul'Aman rares, four Mana Ray variants from the same four, and
-- 103 Trading Post mounts from the same four kiosks. A pin per mount would
-- stack 105 frames on one kiosk, where only the top one can be seen or hovered
-- and the other 104 are invisible work. Grouped, that kiosk is one pin that
-- says what is sold there.
local byMap, indexBuilt = {}, false

-- WHY A PIN IS NOT THERE, counted rather than guessed at.
--
-- Reported as no pins at all while standing in a zone with mounts to farm, and
-- that has now been theorised about once too often. Every rejection is tallied
-- here and the report prints it, so the next question is answered by the client
-- instead of by reading code and picking the likeliest story.
MP.stats = { entries = 0, noRec = 0, stub = 0, factionFiltered = 0,
	noPoints = 0, noCoords = 0, unresolvedMap = 0, indexed = 0, places = 0,
	fromSpawns = 0, scannerReady = false, installed = false }

-- What the last refresh of each surface actually drew. The index counter proved
-- the data was sound while nothing appeared on screen; these two prove whether
-- the draw was even asked for, which is the other half of that answer.
MP.lastDrawn, MP.lastMapID, MP.lastMinimapDrawn = 0, nil, 0

-- WHERE A RECORD SAYS IT IS, IN ALL THREE OF THE PLACES IT MAY SAY IT.
--
-- `spawns` was the whole reason no rare ever pinned. 137 records carry it --
-- 649 points, extracted from HandyNotes into Data_99n_RareSpawns.lua and
-- Data_99zzV_RareSpawns.lua -- and `Router.lua` and `RareAlert.lua` both read
-- it, so the route could send you to a rare the map refused to draw. This index
-- read `patrolWaypoints` and `zone` only, and every Midnight rare keeps its
-- location in `spawns` while its `zone` carries a name and no coordinate. That
-- is why a zone full of rares drew a vendor, a treasure and nothing else.
--
-- `spawns` wins over `zone` where both exist because it is the superset: a
-- Trading Post record's `zone` is one kiosk and its `spawns` are all four.
local function pointsFor(rec)
	if rec.patrolWaypoints then return rec.patrolWaypoints end
	if rec.spawns then return rec.spawns, true end
	if rec.zone then return { rec.zone } end
	return nil
end

-- Places closer together than this are one place as far as a pin is concerned:
-- a pin is about 2% of the canvas wide, so points inside a tenth of a percent
-- are drawn on top of each other whatever we do.
local function quantise(v) return floor(v * 10 + 0.5) end

local function indexLocations()
	wipe(byMap)
	indexBuilt = true
	local st = MP.stats
	st.entries, st.noRec, st.stub, st.factionFiltered = 0, 0, 0, 0
	st.noPoints, st.noCoords, st.unresolvedMap, st.indexed = 0, 0, 0, 0
	st.places, st.fromSpawns = 0, 0
	st.scannerReady = MM.Scanner.ready and true or false
	if not MM.Scanner.ready then return end

	local placeByKey = {}
	for _, entry in ipairs(MM.Scanner.mounts) do
		local rec = entry.rec
		st.entries = st.entries + 1
		if not rec then st.noRec = st.noRec + 1
		elseif rec.stub then st.stub = st.stub + 1
		elseif not MM.Scanner:FactionOk(entry) then
			st.factionFiltered = st.factionFiltered + 1
		elseif not (rec.patrolWaypoints or rec.spawns or rec.zone) then
			st.noPoints = st.noPoints + 1
		end
		if rec and not rec.stub and MM.Scanner:FactionOk(entry) then
			local points, viaSpawns = pointsFor(rec)
			if points then
				if viaSpawns then st.fromSpawns = st.fromSpawns + 1 end
				for _, p in ipairs(points) do
					local mapID = p.mapID or (p.name and U.ResolveMapForRecord(p.name, rec))
						or (rec.zone and rec.zone.name and U.ResolveMapForRecord(rec.zone.name, rec))
					if mapID and p.x and p.y then
						st.indexed = st.indexed + 1
						local key = mapID .. ":" .. quantise(p.x) .. ":" .. quantise(p.y)
						local place = placeByKey[key]
						if not place then
							place = { mapID = mapID, x = p.x, y = p.y,
								label = p.label, entries = {} }
							placeByKey[key] = place
							byMap[mapID] = byMap[mapID] or {}
							tinsert(byMap[mapID], place)
							st.places = st.places + 1
						end
						-- one mount can reach the same place by two routes
						if place.entries[#place.entries] ~= entry then
							tinsert(place.entries, entry)
						end
					elseif not mapID then st.unresolvedMap = st.unresolvedMap + 1
					else st.noCoords = st.noCoords + 1
					end
				end
			end
		end
	end
end

------------------------------------------------------------
-- Appearance, shared by both surfaces
------------------------------------------------------------
local function shouldShow(entry)
	if not (entry and MM.db) then return false end
	local ignored = MM.db.ignored and MM.db.ignored[entry.spellID]
	if entry.collected and not MM.db.mapPinsShowCollected then return false end
	if ignored and MM.db.hideIgnored then return false end
	return true
end

-- MEMBERSHIP ONCE, NOT ONCE PER ENTRY PER SECOND.
--
-- Planner:InPlan is a linear scan of the plan and returns a POSITION, which two
-- callers in Planner genuinely need. Nothing here does -- a pin only asks "is
-- this planned" -- and asking it that way made the cost of one pin proportional
-- to the size of the plan. The minimap weighs every place on the continent once
-- a second and a Trading Post kiosk carries 105 mounts, so on a 287-goal plan
-- that single place cost thirty thousand comparisons a second to colour one
-- border.
--
-- Rebuilt on MM_PLAN_CHANGED with the rest of the index, which is the same
-- signal that already invalidates everything else here.
local plannedSet

local function isPlanned(spellID)
	if not plannedSet then
		plannedSet = {}
		for _, item in ipairs((MM.cdb and MM.cdb.plan) or {}) do
			plannedSet[item.spellID] = true
		end
	end
	return plannedSet[spellID]
end

-- Which mount speaks for a shared place. A kiosk selling one mount you are
-- hunting and a hundred you own should look like the one you are hunting.
local function rank(entry)
	if MM.db.ignored and MM.db.ignored[entry.spellID] then return 3 end
	if entry.collected then return 4 end
	if isPlanned(entry.spellID) then return 1 end
	return 2
end

-- The pin's headline mount and how many mounts it stands for, without building
-- a table -- this runs for every candidate on the minimap once a second.
local function placeStatus(place)
	local primary, best, count = nil, 99, 0
	for _, entry in ipairs(place.entries) do
		if shouldShow(entry) then
			count = count + 1
			local r = rank(entry)
			if r < best then primary, best = entry, r end
		end
	end
	return primary, count
end

local function dress(pin, entry, count)
	local ignored = MM.db.ignored and MM.db.ignored[entry.spellID]
	pin.icon:SetTexture(entry.icon or 134400)
	pin.icon:SetDesaturated(entry.collected or ignored or false)
	-- a plain coloured plate behind the icon keeps a pin readable against busy
	-- map art, and carries the mount's status without a second texture
	if entry.collected then
		pin.border:SetColorTexture(0.55, 0.55, 0.55, 0.9)
	elseif ignored then
		pin.border:SetColorTexture(0.75, 0.2, 0.2, 0.9)
	elseif isPlanned(entry.spellID) then
		pin.border:SetColorTexture(0.25, 0.85, 0.4, 0.95)
	else
		pin.border:SetColorTexture(1, 0.82, 0, 0.9)
	end
	-- Say when a pin is standing for more than itself, so a place holding six
	-- mounts does not read as a place holding one.
	if count > 1 then
		pin.count:SetText(count > 99 and "*" or count)
		pin.count:Show()
	else
		pin.count:Hide()
	end
end

local MAX_TOOLTIP_ROWS = 12

local function pinEnter(self)
	local place = self.data
	if not place then return end

	local primary, count = placeStatus(place)
	if not primary then return end
	if count == 1 then
		MM.UI.ShowMountTooltip(self, primary)
		return
	end

	-- Several mounts, one place. The full per-mount tooltip repeated six times
	-- would be taller than the screen, so this is a list: what is here, and
	-- what state each one is in. Hovering is the only time this is built.
	local shown = {}
	for _, entry in ipairs(place.entries) do
		if shouldShow(entry) then shown[#shown + 1] = entry end
	end
	table.sort(shown, function(a, b)
		local ra, rb = rank(a), rank(b)
		if ra ~= rb then return ra < rb end
		return (a.name or "") < (b.name or "")
	end)

	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:AddLine(("%d mounts here"):format(count), 1, 1, 1)
	local rows = math.min(#shown, MAX_TOOLTIP_ROWS)
	for i = 1, rows do
		local entry = shown[i]
		local status = MM.Availability.GetStatus(entry)
		GameTooltip:AddDoubleLine(entry.name,
			U.STATUS_LABEL[status] or status or "", 1, 0.82, 0, 0.7, 0.7, 0.7)
	end
	if #shown > rows then
		GameTooltip:AddLine(("...and %d more"):format(#shown - rows), 0.6, 0.6, 0.6)
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Click to open the topmost one in the journal", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function pinLeave()
	GameTooltip:Hide()
end

local function pinClick(self, button)
	if not self.data then return end
	local primary = placeStatus(self.data)
	if primary then MM.UI.RowClick(primary, button) end
end

------------------------------------------------------------
-- What to draw for one world map
------------------------------------------------------------
-- Continent view: project child-zone points up onto the parent map, so a
-- continent is not blank. The round trip through world space is the client's own
-- answer to "where is this zone point on that map", and it declines to answer
-- for some continents -- Outland, Zandalar and the Dragon Isles produce nothing
-- while Pandaria and the Broken Isles are complete. That is why the setting
-- behind it is off by default, and it is why the result is cached per map rather
-- than recomputed on every canvas refresh.
local projected = {}

local function projectChildren(mapID)
	local cached = projected[mapID]
	if cached then return cached end
	cached = {}
	projected[mapID] = cached
	for _, child in ipairs(C_Map.GetMapChildrenInfo(mapID, nil, true) or {}) do
		for _, place in ipairs(byMap[child.mapID] or {}) do
			local ok, continentID, worldPos = pcall(C_Map.GetWorldPosFromMapPos,
				child.mapID, CreateVector2D(place.x / 100, place.y / 100))
			if ok and continentID and worldPos then
				local ok2, _, vec = pcall(C_Map.GetMapPosFromWorldPos,
					continentID, worldPos, mapID)
				if ok2 and vec then
					local fx, fy = vec:GetXY()
					if fx and fy and fx >= 0 and fx <= 1 and fy >= 0 and fy <= 1 then
						-- the same entry list, at the parent map's coordinates
						tinsert(cached, {
							mapID = mapID, x = fx * 100, y = fy * 100,
							entries = place.entries, projected = true,
						})
					end
				end
			end
		end
	end
	return cached
end

------------------------------------------------------------
-- World map: canvas data provider
------------------------------------------------------------
local provider, pinPool, installed = nil, nil, false

local providerMethods = {}

function providerMethods:RemoveAllData()
	if self:GetMap() then
		self:GetMap():RemoveAllPinsByTemplate(PIN_TEMPLATE)
	end
end

-- Called by the canvas itself on show, on every map change and on zone change,
-- as well as by MP.Refresh. Nothing here hooks WorldMapFrame: the provider is
-- how the canvas asks for its own contents, so the lifecycle is not ours to
-- second-guess.
function providerMethods:RefreshAllData(fromOnShow)
	local map = self:GetMap()
	if not map then return end
	self:RemoveAllData()
	MP.lastDrawn, MP.lastMapID = 0, nil
	if not (MM.db and MM.db.mapPins ~= false) then return end
	if not indexBuilt then indexLocations() end

	local mapID = map:GetMapID()
	if not mapID then return end
	MP.lastMapID = mapID

	local drawn = 0
	for _, place in ipairs(byMap[mapID] or {}) do
		local primary, count = placeStatus(place)
		if primary then
			map:AcquirePin(PIN_TEMPLATE, place, place.x / 100, place.y / 100,
				primary, count)
			drawn = drawn + 1
		end
	end
	if MM.db.mapPinsChildZones then
		for _, place in ipairs(projectChildren(mapID)) do
			local primary, count = placeStatus(place)
			if primary then
				map:AcquirePin(PIN_TEMPLATE, place, place.x / 100, place.y / 100,
					primary, count)
				drawn = drawn + 1
			end
		end
	end
	MP.lastDrawn = drawn
end

local pinMethods = {}

function pinMethods:OnLoad()
	self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
	-- The canvas scales pins with the map between these bounds instead of
	-- letting them balloon at full zoom, and it is the reason this file does not
	-- counter-scale anything by hand.
	self:SetScalingLimits(1, 1.0, 1.2)
end

function pinMethods:OnAcquired(place, x, y, primary, count)
	self.data = place
	self:UseFrameLevelType("PIN_FRAME_LEVEL_AREA_POI")
	self:SetSize(WORLD_PIN_SIZE, WORLD_PIN_SIZE)
	self:SetPosition(x, y)
	dress(self, primary, count)
end

function pinMethods:OnReleased()
	self.data = nil
end

pinMethods.OnMouseEnter = pinEnter
pinMethods.OnMouseLeave = pinLeave
pinMethods.OnMouseUp = pinClick

-- The canvas calls this on its pins, and the real one throws in combat. Both
-- HandyNotes and HereBeDragons stub it for exactly that reason.
pinMethods.SetPassThroughButtons = function() end

local pinMixin

local function createWorldPin()
	local pin = CreateFrame("Frame", nil, WorldMapFrame:GetCanvas())
	pin:SetSize(WORLD_PIN_SIZE, WORLD_PIN_SIZE)
	pin:EnableMouse(true)

	pin.border = pin:CreateTexture(nil, "BACKGROUND")
	pin.border:SetPoint("TOPLEFT", -2, 2)
	pin.border:SetPoint("BOTTOMRIGHT", 2, -2)

	pin.icon = pin:CreateTexture(nil, "ARTWORK")
	pin.icon:SetAllPoints()
	pin.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)

	pin.count = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	pin.count:SetPoint("BOTTOMRIGHT", pin, "BOTTOMRIGHT", 3, -3)
	pin.count:Hide()

	return Mixin(pin, pinMixin)
end

local function resetWorldPin(_, pin)
	pin:Hide()
	pin:ClearAllPoints()
	pin:OnReleased()
	pin.pinTemplate = nil
	pin.owningMap = nil
end

-- Registering the pool under our template name is what lets AcquirePin work
-- without an XML template: the canvas looks the name up here first and only
-- falls back to instantiating the template itself, which does not exist.
local function ensurePinPool()
	if pinPool then return pinPool end
	if not WorldMapFrame.pinPools then return nil end
	if CreateUnsecuredRegionPoolInstance then
		pinPool = CreateUnsecuredRegionPoolInstance(PIN_TEMPLATE)
	elseif CreateFramePool then
		pinPool = CreateFramePool("FRAME")
	else
		return nil
	end
	pinPool.parent = WorldMapFrame:GetCanvas()
	pinPool.createFunc = createWorldPin
	pinPool.resetFunc = resetWorldPin
	-- the same two under their pre-11.0 names
	pinPool.creationFunc = pinPool.createFunc
	pinPool.resetterFunc = pinPool.resetFunc
	WorldMapFrame.pinPools[PIN_TEMPLATE] = pinPool
	return pinPool
end

------------------------------------------------------------
-- Minimap
------------------------------------------------------------
-- Blizzard has no provider for the minimap, so this is the one place that does
-- position pins by hand -- HereBeDragons' drawMinimapPin, which is real work
-- and not to be improvised.
--
-- Its distance maths needs the offset from the player to the pin in YARDS along
-- screen right and screen up. World coordinates give the offset, but which
-- world axis points north is an assumption this addon has already decided not to
-- make: the arrow measures the map's own east and south axes at runtime with two
-- probe offsets, and tracks exactly like TomTom because of it. The same
-- measurement is done here, once per map, so nothing below depends on the axis
-- convention.
-- activeInstance is what the offsets of the active pins were measured against.
-- A teleport changes it mid-second, and world coordinates from two different
-- instances subtract into nonsense, so the position pass checks it rather than
-- flinging pins around the rim until the next full pass.
local minimapFrames, activeCount, activeInstance = {}, 0, nil

local function cvarOn(name)
	local get = (C_CVar and C_CVar.GetCVar) or GetCVar
	return get and get(name) == "1" or false
end

local rotateMinimap = cvarOn("rotateMinimap")

-- HereBeDragons' table, unchanged: which corners a non-round minimap keeps.
-- GetMinimapShape is supplied by minimap-replacement addons; with no such addon
-- the shape is nil and every pin is treated as being on a round minimap.
local minimap_shapes = {
	-- { upper-left, lower-left, upper-right, lower-right }
	["SQUARE"]                = { false, false, false, false },
	["CORNER-TOPLEFT"]        = { true,  false, false, false },
	["CORNER-TOPRIGHT"]       = { false, false, true,  false },
	["CORNER-BOTTOMLEFT"]     = { false, true,  false, false },
	["CORNER-BOTTOMRIGHT"]    = { false, false, false, true },
	["SIDE-LEFT"]             = { true,  true,  false, false },
	["SIDE-RIGHT"]            = { false, false, true,  true },
	["SIDE-TOP"]              = { true,  false, true,  false },
	["SIDE-BOTTOM"]           = { false, true,  false, true },
	["TRICORNER-TOPLEFT"]     = { true,  true,  true,  false },
	["TRICORNER-TOPRIGHT"]    = { true,  false, true,  true },
	["TRICORNER-BOTTOMLEFT"]  = { true,  true,  false, true },
	["TRICORNER-BOTTOMRIGHT"] = { false, true,  true,  true },
}

-- Unit vectors, in world space, of one map's east and south. A map's projection
-- is linear, so this is a property of the map and not of where the player is
-- standing: probe it at the centre, where the offsets cannot fall off the edge,
-- and keep it.
local basisCache = {}

local function mapBasis(mapID)
	local cached = basisCache[mapID]
	if cached ~= nil then return cached or nil end
	local _, centre = U.GetWorldPos(mapID, 50, 50)
	local _, east = U.GetWorldPos(mapID, 51, 50)
	local _, south = U.GetWorldPos(mapID, 50, 51)
	if not (centre and east and south) then
		basisCache[mapID] = false
		return nil
	end
	local ex, ey = east.x - centre.x, east.y - centre.y
	local sx, sy = south.x - centre.x, south.y - centre.y
	local el, sl = sqrt(ex * ex + ey * ey), sqrt(sx * sx + sy * sy)
	if el == 0 or sl == 0 then
		basisCache[mapID] = false
		return nil
	end
	cached = { ex = ex / el, ey = ey / el, sx = sx / sl, sy = sy / sl }
	basisCache[mapID] = cached
	return cached
end

-- Yards east and yards south from the player to a point, both projected onto
-- the measured axes. World units are yards, so no scaling is involved.
local function offsetYards(basis, world, loc)
	local dx, dy = loc.wx - world.x, loc.wy - world.y
	return dx * basis.ex + dy * basis.ey, dx * basis.sx + dy * basis.sy
end

local function worldPosFor(place)
	if place.wx then return true end
	if place.noWorldPos then return false end
	local instance, world = U.GetWorldPos(place.mapID, place.x, place.y)
	if not world then
		place.noWorldPos = true
		return false
	end
	place.instance, place.wx, place.wy = instance, world.x, world.y
	return true
end

-- Everything indexed on the player's continent, in the player's instance. Pins
-- are chosen by world position rather than by matching mapID, so standing at a
-- zone border shows what is over the line -- which is the whole reason the
-- reference works in world coordinates.
local candidateKey, candidates = nil, {}

local function buildCandidates(playerMapID, playerInstance)
	local continent = U.GetContinentMapID(playerMapID)
	local key = tostring(continent) .. ":" .. tostring(playerInstance)
	if key == candidateKey then return candidates end
	candidateKey = key
	wipe(candidates)
	for mapID, list in pairs(byMap) do
		if U.GetContinentMapID(mapID) == continent then
			for _, place in ipairs(list) do
				if worldPosFor(place) and place.instance == playerInstance then
					tinsert(candidates, place)
				end
			end
		end
	end
	return candidates
end

-- Per-pass minimap facts, read once and shared by both passes below.
local mapRadius, halfWidth, halfHeight, minimapShape, mapSin, mapCos

-- How many yards the minimap shows. The reference carries a zoom-level-to-yards
-- table for clients without this API, and needs a SetZoom jiggle to tell indoor
-- zoom levels from outdoor ones -- a side effect on a frame that is not ours,
-- for a client generation this addon does not support. So: no table, no jiggle,
-- and the report SAYS SO if the API is ever missing rather than leaving the
-- minimap quietly blank and the setting quietly meaningless.
MP.stats.minimapRadiusAPI = (C_Minimap and C_Minimap.GetViewRadius) and true or false

local function readMinimap()
	if not MP.stats.minimapRadiusAPI then return false end
	mapRadius = C_Minimap.GetViewRadius()
	if not mapRadius or mapRadius <= 0 then return false end
	halfWidth, halfHeight = Minimap:GetWidth() / 2, Minimap:GetHeight() / 2
	minimapShape = GetMinimapShape and minimap_shapes[GetMinimapShape() or "ROUND"] or nil
	if rotateMinimap then
		local facing = GetPlayerFacing()
		if not facing then return false end
		mapSin, mapCos = sin(facing), cos(facing)
	else
		mapSin, mapCos = nil, nil
	end
	return true
end

-- The reference's culling and edge handling. Returns whether the pin is on the
-- minimap at all; out of range it hides rather than floating on the rim, so a
-- pin always means a place you can walk to from here.
local function placeMinimapPin(pin, east, south)
	local px, py = east, -south -- screen right, screen up
	if mapSin then
		-- a rotating minimap puts the facing direction at the top
		px, py = east * mapCos + py * mapSin, py * mapCos - east * mapSin
	end

	local diffX, diffY = px / mapRadius, py / mapRadius

	local isRound = true
	if minimapShape and diffX ~= 0 and diffY ~= 0 then
		isRound = (diffX < 0) and 1 or 3 -- left pair or right pair
		if diffY <= 0 then isRound = isRound + 1 end -- lower of the pair
		isRound = minimapShape[isRound]
	end

	-- 0.9 keeps an icon clear of the rim, exactly as the reference does
	local reach = 0.9 * 0.9
	local dist
	if isRound then
		dist = (diffX * diffX + diffY * diffY) / reach
	else
		dist = max(diffX * diffX, diffY * diffY) / reach
	end
	if dist > 1 then
		pin:Hide()
		return false
	end

	pin:ClearAllPoints()
	pin:SetPoint("CENTER", Minimap, "CENTER", diffX * halfWidth, diffY * halfHeight)
	pin:Show()
	return true
end

local function createMinimapPin()
	local pin = CreateFrame("Frame", nil, Minimap)
	pin:SetSize(MINIMAP_PIN_SIZE, MINIMAP_PIN_SIZE)
	pin:EnableMouse(true)

	pin.border = pin:CreateTexture(nil, "BACKGROUND")
	pin.border:SetPoint("TOPLEFT", -1, 1)
	pin.border:SetPoint("BOTTOMRIGHT", 1, -1)

	pin.icon = pin:CreateTexture(nil, "ARTWORK")
	pin.icon:SetAllPoints()
	pin.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)

	pin.count = pin:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	pin.count:SetPoint("BOTTOMRIGHT", pin, "BOTTOMRIGHT", 3, -3)
	pin.count:Hide()

	pin:SetScript("OnEnter", pinEnter)
	pin:SetScript("OnLeave", pinLeave)
	pin:SetScript("OnMouseUp", pinClick)
	return pin
end

-- Active pins are always the first `activeCount` frames, so the position pass
-- needs no list of its own and allocates nothing.
local function hideMinimapPins()
	for i = 1, activeCount do
		minimapFrames[i]:Hide()
		minimapFrames[i].data = nil
	end
	activeCount, activeInstance = 0, nil
	MP.lastMinimapDrawn = 0
end

local function minimapEnabled()
	return MM.db and MM.db.mapPinsMinimap ~= false
end

-- AN EMPTY MINIMAP IS TWO COMPLETELY DIFFERENT ANSWERS.
--
-- "Nothing is within 400 yards of you" is the correct and overwhelmingly common
-- one: a zone is minutes of flying across and the minimap shows a few hundred
-- yards of it, so most of the time a zone full of mounts still puts nothing on
-- the minimap. "The pass bailed before it looked" is a fault. On screen the two
-- are the same blank ring, which is precisely the shape of the fault this file
-- was rewritten for -- so the pass records which one happened, how many points
-- it weighed, and how far the closest of them was. A number that reads as
-- obviously-correct is worth more than a fix nobody can check.
MP.minimapWhy, MP.minimapCandidates, MP.minimapNearest = "has not run yet", 0, nil
MP.minimapRadius = nil

local function fullMinimapUpdate()
	hideMinimapPins()
	MP.minimapCandidates, MP.minimapNearest = 0, nil
	if not minimapEnabled() then MP.minimapWhy = "switched off" return end
	if not indexBuilt then indexLocations() end

	-- A PASS THAT COULD NOT RUN IS NOT A PASS THAT FOUND NOTHING.
	--
	-- These three are transient: the client withholds a position for a moment
	-- after a zone change, a map's world position resolves late, and the view
	-- radius is unreadable while the minimap is mid-resize. Each used to return
	-- exactly like a completed pass, and the driver read "no candidates" from
	-- them and parked -- so a stutter at the wrong moment silently switched
	-- minimap pins off until something else happened to re-arm it.
	--
	-- `false` means "ask again"; `true` means the answer below is real.
	local instance, world, mapID = U.PlayerWorldPos()
	if not (world and mapID) then
		MP.minimapWhy = "no player position here (instances do not report one)"
		return false
	end
	local basis = mapBasis(mapID)
	if not basis then
		MP.minimapWhy = ("map %d has no world position to measure against"):format(mapID)
		return false
	end
	if not readMinimap() then
		MP.minimapWhy = "could not read the minimap's view radius"
		return false
	end
	MP.minimapRadius = mapRadius

	local used, weighed, nearest = 0, 0, nil
	for _, place in ipairs(buildCandidates(mapID, instance)) do
		local primary, count = placeStatus(place)
		if primary then
			weighed = weighed + 1
			local east, south = offsetYards(basis, world, place)
			local away = sqrt(east * east + south * south)
			if not nearest or away < nearest then nearest = away end
			if away <= mapRadius then
				local pin = minimapFrames[used + 1] or createMinimapPin()
				minimapFrames[used + 1] = pin
				pin.data = place
				dress(pin, primary, count)
				if placeMinimapPin(pin, east, south) then
					used = used + 1
				else
					pin.data = nil
				end
			end
		end
	end
	activeCount, activeInstance = used, instance
	MP.lastMinimapDrawn = used
	MP.minimapCandidates, MP.minimapNearest = weighed, nearest
	if used > 0 then
		MP.minimapWhy = "drawing"
	elseif weighed == 0 then
		MP.minimapWhy = "nothing indexed on this continent, in this instance"
	else
		MP.minimapWhy = "everything is out of range"
	end
	return true
end

-- Between full passes only the offsets change, so only the offsets are redone.
local function moveMinimapPins()
	if activeCount == 0 then return end
	local instance, world, mapID = U.PlayerWorldPos()
	if not (world and mapID) or instance ~= activeInstance then hideMinimapPins() return end
	local basis = mapBasis(mapID)
	if not (basis and readMinimap()) then hideMinimapPins() return end
	for i = 1, activeCount do
		local pin = minimapFrames[i]
		if pin.data then
			local east, south = offsetYards(basis, world, pin.data)
			placeMinimapPin(pin, east, south)
		end
	end
end

local FULL_EVERY, MOVE_EVERY = 1.0, 0.05
local sinceFull, sinceMove = FULL_EVERY, 0
local driver

-- MEASURED BEFORE IT WAS CHANGED, and left in place so it stays measurable.
--
-- This ran an OnUpdate every frame for the whole session once installed, and a
-- full pass over the candidate list every second, whether or not this map has a
-- single pin on it. "It feels fine" is not evidence on a fast machine standing
-- somewhere with pins; a count is.
MP.driverStats = {
	ticks = 0,        -- OnUpdate calls
	fulls = 0,        -- full passes over the candidates
	moves = 0,        -- offset-only repositions
	transient = 0,    -- passes that could not run and were retried
	parked = 0,       -- times it stopped ticking entirely
	ms = 0,           -- time inside the handler
}

local function armDriver()
	if not driver then return end
	if driver:GetScript("OnUpdate") then return end
	driver:SetScript("OnUpdate", driver.mmTick)
end

-- STOP TICKING, rather than tick and return early.
--
-- An OnUpdate that leaves immediately is still an OnUpdate: the client calls it
-- every frame forever. Parking removes the script, so a character standing in a
-- zone with nothing indexed pays nothing at all until something says the answer
-- may have changed.
local function parkDriver(why)
	if not (driver and driver:GetScript("OnUpdate")) then return end
	driver:SetScript("OnUpdate", nil)
	MP.driverStats.parked = MP.driverStats.parked + 1
	MP.driverParked = why or "parked"
end

local function ensureDriver()
	if driver then armDriver() return end
	driver = CreateFrame("Frame")
	driver.mmTick = function(_, elapsed)
		local stats = MP.driverStats
		stats.ticks = stats.ticks + 1
		local started = debugprofilestop and debugprofilestop() or nil
		if not minimapEnabled() then
			if activeCount > 0 then hideMinimapPins() end
			-- The setting is off. Nothing will turn it back on but the setting,
			-- and that calls Refresh.
			parkDriver("minimap pins are switched off")
			if started then stats.ms = stats.ms + (debugprofilestop() - started) end
			return
		end
		-- nothing to do while the minimap is not on screen
		if not (Minimap and Minimap:IsVisible()) then
			if started then stats.ms = stats.ms + (debugprofilestop() - started) end
			return
		end
		sinceFull = sinceFull + elapsed
		sinceMove = sinceMove + elapsed
		if sinceFull >= FULL_EVERY then
			sinceFull, sinceMove = 0, 0
			local valid = fullMinimapUpdate()
			stats.fulls = stats.fulls + 1
			if not valid then
				-- The pass could not run. Try again on the next tick rather
				-- than reading a missing position as an empty zone.
				stats.transient = (stats.transient or 0) + 1
				sinceFull = FULL_EVERY
			elseif activeCount == 0 and (MP.minimapCandidates or 0) == 0 then
				-- NOTHING INDEXED HERE AT ALL is different from everything being
				-- out of range, and different again from a pass that failed. Out
				-- of range resolves by walking, so it keeps ticking; nothing
				-- indexed cannot resolve without a new map, a new scan or a plan
				-- edit, and each of those re-arms this.
				parkDriver(MP.minimapWhy or "nothing indexed here")
			end
		elseif sinceMove >= MOVE_EVERY then
			sinceMove = 0
			moveMinimapPins()
			stats.moves = stats.moves + 1
		end
		if started then stats.ms = stats.ms + (debugprofilestop() - started) end
	end
	armDriver()
end

------------------------------------------------------------
-- Public surface
------------------------------------------------------------
-- What the index holds for one map, for the report. Builds the index if it has
-- not been built, because "no pins" and "never indexed" are different answers.
function MP.CountFor(mapID)
	if not indexBuilt then indexLocations() end
	return #(byMap[mapID or -1] or {})
end

function MP.Clear()
	if provider then provider:RemoveAllData() end
	hideMinimapPins()
end

-- Start the minimap driver ticking again after it parked itself.
--
-- Safe to call when it is already running, and safe before the driver exists at
-- all -- Install creates it. Everything that could change "is there anything to
-- draw here" calls this rather than each caller knowing how the driver works.
function MP.Wake()
	sinceFull = FULL_EVERY   -- and do a full pass on the very next tick
	if driver and minimapEnabled() then
		MP.driverParked = nil
		armDriver()
	end
end

function MP.Refresh()
	MP.Install()
	if not indexBuilt then indexLocations() end
	if provider and WorldMapFrame and WorldMapFrame:IsShown() then
		provider:RefreshAllData()
	end
	if not minimapEnabled() then
		hideMinimapPins()
		-- The setting turning off is itself a reason to stop ticking.
		parkDriver("minimap pins are switched off")
	else
		MP.Wake()   -- redo the minimap on the next tick, ticking if parked
	end
end

function MP.Install()
	if installed then return end
	if not (WorldMapFrame and WorldMapFrame.AddDataProvider and WorldMapFrame.GetCanvas) then return end
	if not (MapCanvasDataProviderMixin and MapCanvasPinMixin) then return end
	pinMixin = pinMixin or CreateFromMixins(MapCanvasPinMixin, pinMethods)
	if not ensurePinPool() then return end
	provider = CreateFromMixins(MapCanvasDataProviderMixin, providerMethods)
	WorldMapFrame:AddDataProvider(provider)
	installed = true
	MP.stats.installed = true
	ensureDriver()
	-- The canvas refreshes its providers when it opens, so a provider registered
	-- while the map is already open would sit idle until the next map change.
	if WorldMapFrame:IsShown() then provider:RefreshAllData() end
end

------------------------------------------------------------
-- Hooks
------------------------------------------------------------
local function tryInstall()
	if C_AddOns and C_AddOns.IsAddOnLoaded and not C_AddOns.IsAddOnLoaded("Blizzard_WorldMap") then
		pcall(C_AddOns.LoadAddOn, "Blizzard_WorldMap")
	end
	MP.Install()
end

MM:RegisterGameEvent("ADDON_LOADED", function(name)
	if name == "Blizzard_WorldMap" then tryInstall() end
end)

MM:On("MM_LOGIN", function()
	-- The minimap does not go through the canvas and so does not wait on it: if
	-- the world map addon is missing or its provider cannot be registered, the
	-- minimap still draws.
	ensureDriver()
	tryInstall()
	-- and again once the rest of the interface has settled, in case the map
	-- addon was not there yet
	C_Timer.After(4, tryInstall)
end)

MM:RegisterGameEvent("CVAR_UPDATE", function(cvar, value)
	if cvar == "rotateMinimap" or cvar == "ROTATE_MINIMAP" then
		rotateMinimap = (value == "1")
		sinceFull = FULL_EVERY
	end
end)

local function invalidate()
	indexBuilt = false
	plannedSet = nil
	wipe(projected)
	candidateKey = nil
	sinceFull = FULL_EVERY
	-- WAKE IT. The driver parks itself when this map has nothing indexed, and
	-- every caller here is a reason that answer may have changed: a rescan, a
	-- plan edit, a new zone. Without this, parking once would be parking for
	-- good and the minimap would quietly stop showing pins.
	MP.Wake()
	if WorldMapFrame and WorldMapFrame:IsShown() then MP.Refresh() end
end
MM:On("MM_SCANNED", invalidate)
MM:On("MM_PLAN_CHANGED", invalidate)

-- A new map is the commonest reason a parked driver has something to do again,
-- and it raises none of the events above.
MM:RegisterGameEvent("ZONE_CHANGED_NEW_AREA", invalidate)
MM:RegisterGameEvent("PLAYER_ENTERING_WORLD", invalidate)
