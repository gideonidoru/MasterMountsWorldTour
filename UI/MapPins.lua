-- Master Mounts world map pins.
--
-- Deliberately NOT the competitor's approach: they CreateFrame a new pin on
-- every map change and orphan the old ones with SetParent(nil), which leaks a
-- frame per pin forever (WoW frames are never garbage collected), and their
-- pins scale with the canvas so they balloon when you zoom in. We pool pins
-- and counter-scale them.
local _, MM = ...
local U = MM.Util

MM.MapPins = {}
local MP = MM.MapPins

local pinPool, activePins = nil, {}
local PIN_SIZE = 18

------------------------------------------------------------
-- Which mounts have a location on the displayed map
------------------------------------------------------------
-- Cache: [mapID] = { { entry, rec, x, y }, ... }
local byMap, indexBuilt = {}, false

-- WHY A PIN IS NOT THERE, counted rather than guessed at.
--
-- Reported as no pins at all while standing in a zone with mounts to farm, and
-- I have now theorised about this once too often. Every rejection is tallied
-- here and the report prints it, so the next question is answered by the client
-- instead of by me reading code and picking the likeliest story.
MP.stats = { entries = 0, noRec = 0, stub = 0, factionFiltered = 0,
	noPoints = 0, noCoords = 0, unresolvedMap = 0, indexed = 0, scannerReady = false }

local function indexLocations()
	wipe(byMap)
	indexBuilt = true
	local st = MP.stats
	st.entries, st.noRec, st.stub, st.factionFiltered = 0, 0, 0, 0
	st.noPoints, st.noCoords, st.unresolvedMap, st.indexed = 0, 0, 0, 0
	st.scannerReady = MM.Scanner.ready and true or false
	if not MM.Scanner.ready then return end

	for _, entry in ipairs(MM.Scanner.mounts) do
		local rec = entry.rec
		st.entries = st.entries + 1
		if not rec then st.noRec = st.noRec + 1
		elseif rec.stub then st.stub = st.stub + 1
		elseif not MM.Scanner:FactionOk(entry) then
			st.factionFiltered = st.factionFiltered + 1
		elseif not (rec.patrolWaypoints or rec.zone) then
			st.noPoints = st.noPoints + 1
		end
		if rec and not rec.stub and MM.Scanner:FactionOk(entry) then
			-- a record may carry several points (roaming rares)
			local points = rec.patrolWaypoints
			if not points and rec.zone then points = { rec.zone } end
			if points then
				for _, p in ipairs(points) do
					local mapID = p.mapID or (p.name and U.ResolveMapForRecord(p.name, rec))
						or (rec.zone and rec.zone.name and U.ResolveMapForRecord(rec.zone.name, rec))
					if mapID and p.x and p.y then
						st.indexed = st.indexed + 1
						byMap[mapID] = byMap[mapID] or {}
						tinsert(byMap[mapID], {
							entry = entry, rec = rec, x = p.x, y = p.y,
							label = p.label,
						})
					elseif not mapID then st.unresolvedMap = st.unresolvedMap + 1
					else st.noCoords = st.noCoords + 1
					end
				end
			end
		end
	end
end

------------------------------------------------------------
-- Pins
------------------------------------------------------------
local function pinTooltip(self)
	if not self.data then return end
	MM.UI.ShowMountTooltip(self, self.data.entry)
end

local function createPin()
	local canvas = WorldMapFrame and WorldMapFrame.ScrollContainer
		and WorldMapFrame.ScrollContainer.Child
	local pin = CreateFrame("Button", nil, canvas)
	pin:SetSize(PIN_SIZE, PIN_SIZE)
	-- NOT SetIgnoreParentScale, WHICH IS WHAT BROKE THIS.
	--
	-- Ignoring the parent's scale stops a pin growing as the map zooms, and it
	-- also means SetPoint offsets are measured in the PIN's coordinate space
	-- while the canvas width they were computed from is in the CANVAS's. Where
	-- the two happen to agree -- a continent at default zoom -- the pins land
	-- correctly; on a zone map, drawn at a different canvas scale, every pin is
	-- pushed off the canvas. Reported as pins on Pandaria and the Broken Isles
	-- and none in the zone the player was standing in, while the index reported
	-- six points for that very map.
	--
	-- Checked against HereBeDragons-Pins-2.0, which is what HandyNotes draws
	-- with: it never ignores parent scale and never multiplies by a canvas
	-- width. It hands NORMALISED coordinates to Blizzard's own pin provider via
	-- SetPosition, and bounds zoom growth with SetScalingLimits(1, 1.0, 1.2).
	-- Ours keeps its own frames, so it does the equivalent: share the canvas's
	-- scale, so one set of coordinates means one thing.

	pin.border = pin:CreateTexture(nil, "BACKGROUND")
	pin.border:SetPoint("TOPLEFT", -2, 2)
	pin.border:SetPoint("BOTTOMRIGHT", 2, -2)

	pin.icon = pin:CreateTexture(nil, "ARTWORK")
	pin.icon:SetAllPoints()
	pin.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)

	pin:SetScript("OnEnter", pinTooltip)
	pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
	pin:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	pin:SetScript("OnClick", function(self, button)
		if self.data then MM.UI.RowClick(self.data.entry, button) end
	end)
	return pin
end

local function resetPin(_, pin)
	pin:Hide()
	pin.data = nil
	pin:ClearAllPoints()
end

local function ensurePool()
	if pinPool then return pinPool end
	pinPool = CreateObjectPool(createPin, resetPin)
	return pinPool
end

function MP.Clear()
	for _, pin in ipairs(activePins) do
		if pinPool then pinPool:Release(pin) end
	end
	wipe(activePins)
end

-- What the index holds for one map, for the report. Builds the index if it has
-- not been built, because "no pins" and "never indexed" are different answers.
function MP.CountFor(mapID)
	if not indexBuilt then indexLocations() end
	return #(byMap[mapID or -1] or {})
end

function MP.Refresh()
	if not (WorldMapFrame and WorldMapFrame:IsShown()) then return end
	if not MM.db or MM.db.mapPins == false then MP.Clear() return end
	if not indexBuilt then indexLocations() end

	MP.Clear()
	local canvas = WorldMapFrame.ScrollContainer and WorldMapFrame.ScrollContainer.Child
	if not canvas then return end

	local mapID = WorldMapFrame.GetMapID and WorldMapFrame:GetMapID()
	if not mapID then return end

	-- Continent view: project child-zone points up onto the parent map so a
	-- continent isn't blank. The round trip through world space is what makes
	-- this correct for maps that aren't a simple linear subrectangle.
	local list = {}
	for _, loc in ipairs(byMap[mapID] or {}) do tinsert(list, loc) end

	if MM.db.mapPinsChildZones ~= false then
		local children = C_Map.GetMapChildrenInfo(mapID, nil, true)
		for _, child in ipairs(children or {}) do
			for _, loc in ipairs(byMap[child.mapID] or {}) do
				local ok, continentID, worldPos = pcall(C_Map.GetWorldPosFromMapPos,
					child.mapID, CreateVector2D(loc.x / 100, loc.y / 100))
				if ok and continentID and worldPos then
					local ok2, _, vec = pcall(C_Map.GetMapPosFromWorldPos,
						continentID, worldPos, mapID)
					if ok2 and vec then
						local fx, fy = vec:GetXY()
						if fx and fy and fx >= 0 and fx <= 1 and fy >= 0 and fy <= 1 then
							tinsert(list, {
								entry = loc.entry, rec = loc.rec,
								x = fx * 100, y = fy * 100, projected = true,
							})
						end
					end
				end
			end
		end
	end
	if #list == 0 then return end

	local pool = ensurePool()
	local width, height = canvas:GetWidth(), canvas:GetHeight()

	for _, loc in ipairs(list) do
		local entry = loc.entry
		local collected = entry.collected
		local ignored = MM.db.ignored[entry.spellID]
		local show = true
		if collected and not MM.db.mapPinsShowCollected then show = false end
		if ignored and MM.db.hideIgnored then show = false end

		if show then
			local pin = pool:Acquire()
			pin.data = loc
			pin.icon:SetTexture(entry.icon or 134400)
			pin.icon:SetDesaturated(collected or ignored or false)
			-- a plain colored plate behind the icon keeps pins readable against
			-- busy map art, which is the one visual idea worth copying
			if collected then
				pin.border:SetColorTexture(0.55, 0.55, 0.55, 0.9)
			elseif ignored then
				pin.border:SetColorTexture(0.75, 0.2, 0.2, 0.9)
			elseif MM.Planner:InPlan(entry.spellID) then
				pin.border:SetColorTexture(0.25, 0.85, 0.4, 0.95)
			else
				pin.border:SetColorTexture(1, 0.82, 0, 0.9)
			end
			-- Canvas width and canvas offsets, in one coordinate space.
			pin:SetPoint("CENTER", canvas, "TOPLEFT",
				width * (loc.x / 100), -height * (loc.y / 100))
			pin:SetFrameLevel(canvas:GetFrameLevel() + 10)
			pin:Show()
			tinsert(activePins, pin)
		end
	end
end

------------------------------------------------------------
-- Hooks
------------------------------------------------------------
local hooked = false

function MP.Install()
	if hooked or not WorldMapFrame then return end
	hooked = true
	WorldMapFrame:HookScript("OnShow", function() MP.Refresh() end)
	WorldMapFrame:HookScript("OnHide", function() MP.Clear() end)
	if WorldMapFrame.SetMapID then
		hooksecurefunc(WorldMapFrame, "SetMapID", function() MP.Refresh() end)
	end
end

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
	C_Timer.After(4, tryInstall)
end)

local function invalidate()
	indexBuilt = false
	if WorldMapFrame and WorldMapFrame:IsShown() then MP.Refresh() end
end
MM:On("MM_SCANNED", invalidate)
MM:On("MM_PLAN_CHANGED", invalidate)
