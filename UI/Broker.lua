-- Master Mounts broker: LibDataBroker feed (Titan Panel, Bazooka, etc. pick
-- this up automatically) plus our own gorgeous minimap button.
local _, MM = ...
local U = MM.Util

-- Our own art, converted from mm-worldTourIcon.png by tools/make_icon_tga.py.
-- The 64px copy exists because this draws at 20px: handing the client a
-- 1024-wide texture to render a thumbnail wastes video memory, and WoW does not
-- mipmap addon textures.
local ICON = MM.MEDIA .. "icon-minimap"

local function summaryTooltip(tt)
	-- THE ACCENT COMES FROM THE THEME, not from a literal.
	--
	-- This was the branding blue written inline, so the tooltip stayed that
	-- colour under Blizzard and under ElvUI -- which reads its accent from the
	-- user's own value colour. AddLine takes r,g,b, so no escape is needed at
	-- all here.
	local accent = (MM.Theme and MM.Theme.Colors and MM.Theme.Colors().accent)
		or { 0.2, 0.76, 1 }
	tt:AddLine("Master Mounts", accent[1], accent[2], accent[3])
	local c, t = MM.Scanner.collectedCount, MM.Scanner.totalCount
	tt:AddLine(("Collected: |cffffffff%d / %d|r (%d%%)"):format(c, t, t > 0 and (c * 100 / t) or 0), 1, 0.82, 0.2)

	local plan = MM.Planner:GetPlan()
	tt:AddLine(("Farm plan: |cffffffff%d|r goals"):format(#plan), 1, 0.82, 0.2)

	local cur = MM.Router:Current()
	if cur then
		tt:AddLine(("Route: goal %d/%d — %s"):format(MM.cdb.routeIndex, #MM.Router.route, cur.label), 0.4, 0.8, 1)
		-- what the rest of the route is worth, in the same terms as the planner
		local totals = MM.Router.totals
		if totals and totals.stops > 0 then
			tt:AddLine(("Remaining: about %s · ~%.1f mounts"):format(
				U.FormatSeconds(totals.minutes * 60), totals.mounts), 0.6, 0.6, 0.7)
		end
	end

	if MM.Timewalking.IsActive() then
		tt:AddLine("Timewalking is ACTIVE this week — " .. U.Comma(MM.Timewalking.Badges())
			.. " badges banked", 0.5, 1, 0.5)
	end

	tt:AddLine(" ")
	tt:AddLine("Left-click: open Master Mounts", 0.7, 0.7, 0.7)
	tt:AddLine("Right-click: quick menu", 0.7, 0.7, 0.7)
end

-- `anchor` is accepted and deliberately unused: both call sites pass their
-- button, and the menu is anchored to the screen instead. See below.
local function quickMenu(anchor)  -- luacheck: ignore anchor
	if MenuUtil and MenuUtil.CreateContextMenu then
		-- REPORTED FROM PLAY: "the minimap button menu constantly closes before
		-- I can scroll down past the first two options."
		--
		-- Anchored to UIParent rather than to the button. A minimap button sits
		-- against the edge of the screen by definition, so a menu anchored to it
		-- opens into whatever room is left -- which is why it arrived squashed
		-- and scrolling, and why reaching for the third entry took the pointer
		-- across the gap that dismisses it. Opening at the cursor in open space
		-- is the usual answer for exactly this reason.
		--
		-- Said plainly: I could not reproduce the dismissal here, so this fixes
		-- the cause I can demonstrate -- seven entries and a title have no
		-- business scrolling at all -- rather than claiming to have found it.
		MenuUtil.CreateContextMenu(UIParent, function(_, root)
			root:CreateTitle("Master Mounts")
			root:CreateButton("Collection", function() MM:Fire("MM_TOGGLE_MAIN", 1) end)
			root:CreateButton("Planner", function() MM:Fire("MM_TOGGLE_MAIN", 2) end)
			root:CreateButton("Monitor HUD", function() MM:Fire("MM_TOGGLE_MONITOR") end)
			root:CreateButton("Compact mode", function() MM:Fire("MM_TOGGLE_COMPACT") end)
			root:CreateButton(MM.cdb.routeActive and "Stop route" or "Start route",
				function() MM:Fire("MM_ROUTE_TOGGLE") end)
			root:CreateButton("Easiest mounts (chat)", function() MM:Fire("MM_EASIEST") end)
			root:CreateButton("Options", function() MM.OpenOptions() end)
		end)
	else
		-- ancient client fallback: just toggle the monitor
		MM:Fire("MM_TOGGLE_MONITOR")
	end
end

------------------------------------------------------------
-- LibDataBroker data source
------------------------------------------------------------
local dataObj
local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
if LDB then
	dataObj = LDB:NewDataObject("MasterMounts", {
		type = "data source",
		text = "Master Mounts",
		icon = ICON,
		-- WHAT A DISPLAY ADDON SHOWS AS THE NAME, separately from the value.
		-- Titan lets the player toggle label and text independently; with no
		-- label it falls back to the data object's name and reads
		-- "MasterMounts", jammed together, in someone's top bar.
		label = "Master Mounts",
		-- THE ADDON FOLDER, WHICH IS NOT THE DATA OBJECT'S NAME.
		--
		-- Titan resolves a plugin's category, version and notes with
		-- GetAddOnMetadata(obj.tocname or objectName). The object is called
		-- "MasterMounts" and the folder is "MasterMountsWorldTour", so every
		-- one of those lookups returned nil and the plugin would have appeared
		-- in Titan's config uncategorised and with no version -- the same
		-- folder-name mismatch that once silently broke four textures.
		tocname = "MasterMountsWorldTour",
		OnClick = function(self, button)
			if button == "RightButton" then quickMenu(self) else MM:Fire("MM_TOGGLE_MAIN") end
		end,
		OnTooltipShow = summaryTooltip,
	})
end

local function updateBrokerText()
	if not dataObj then return end
	local cur = MM.Router:Current()
	if cur then
		dataObj.text = ("%d/%d %s"):format(MM.cdb.routeIndex, #MM.Router.route, cur.label)
	else
		dataObj.text = ("%d/%d"):format(MM.Scanner.collectedCount, MM.Scanner.totalCount)
	end
end

MM:On("MM_SCANNED", updateBrokerText)
MM:On("MM_ROUTE_ADVANCED", updateBrokerText)
-- A finished build changes the stop count this line reports, which a goal
-- change does not. They were one event; separating them means each surface
-- subscribes to the one it actually depends on.
MM:On("MM_ROUTE_BUILT", updateBrokerText)
MM:On("MM_ROUTE_STARTED", updateBrokerText)
MM:On("MM_ROUTE_STOPPED", updateBrokerText)

------------------------------------------------------------
-- Minimap button: classic gold-ring style, draggable around the rim
------------------------------------------------------------
local button

local function positionButton()
	local angle = math.rad(MM.db.minimapAngle or 215)
	local radius = (Minimap:GetWidth() / 2) + 5
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER",
		math.cos(angle) * radius, math.sin(angle) * radius)
end

local function buildMinimapButton()
	if button then return end
	button = CreateFrame("Button", "MasterMountsMinimapButton", Minimap)
	button:SetSize(32, 32)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	-- the mount icon, masked round, inside the classic gold ring
	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetPoint("CENTER", -1, 1)
	icon:SetTexture(ICON)
	-- No border crop: that trim exists to cut the frame off a Blizzard icon, and
	-- our art has none -- cropping it would just shave the edges off.
	icon:SetTexCoord(0, 1, 0, 1)
	local mask = button:CreateMaskTexture()
	mask:SetAllPoints(icon)
	mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
		"CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	icon:AddMaskTexture(mask)

	local ring = button:CreateTexture(nil, "OVERLAY")
	ring:SetSize(54, 54)
	ring:SetPoint("TOPLEFT")
	ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	button:SetScript("OnClick", function(self, mouse)
		if mouse == "RightButton" then quickMenu(self) else MM:Fire("MM_TOGGLE_MAIN") end
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		summaryTooltip(GameTooltip)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)

	-- drag around the minimap rim
	button:SetScript("OnDragStart", function(self)
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			cx, cy = cx / scale, cy / scale
			MM.db.minimapAngle = math.deg(math.atan2 and math.atan2(cy - my, cx - mx)
				or math.atan(cy - my, cx - mx))
			positionButton()
		end)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	positionButton()
end

MM:On("MM_LOGIN", function()
	C_Timer.After(3, function()
		if MM.db.minimapAngle == nil then MM.db.minimapAngle = 215 end
		MM.db.minimap = MM.db.minimap or { hide = false }

		-- LibDBIcon is bundled, so this is the normal path: minimap-button
		-- collectors/hiders (MBB, MBF, ElvUI, etc.) only know how to manage
		-- buttons registered through it. Our own button is a fallback.
		local LDBIcon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)
		if LDBIcon and dataObj then
			local ok = pcall(LDBIcon.Register, LDBIcon, "MasterMounts", dataObj, MM.db.minimap)
			if ok then
				MM.usingLDBIcon = true
				return
			end
		end
		buildMinimapButton()
	end)
end)

-- Let other addons/macros hide our own button if they can't manage it.
function MM.SetMinimapShown(shown)
	MM.db.minimap = MM.db.minimap or {}
	MM.db.minimap.hide = not shown
	local LDBIcon = LibStub and LibStub:GetLibrary("LibDBIcon-1.0", true)
	if MM.usingLDBIcon and LDBIcon then
		pcall(shown and LDBIcon.Show or LDBIcon.Hide, LDBIcon, "MasterMounts")
	elseif button then
		button:SetShown(shown)
	end
end
