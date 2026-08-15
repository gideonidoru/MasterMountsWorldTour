-- Master Mounts compact mode: a slim, movable plan overview for everyday play.
local _, MM = ...
local U = MM.Util

local frame, rows
local ROWS_SHOWN = 12
local offset = 0

local function build()
	if frame then return end

	frame = CreateFrame("Frame", "MasterMountsCompact", UIParent, "BackdropTemplate")
	frame:SetSize(300, 24 + ROWS_SHOWN * 24 + 8)
	frame:SetPoint("LEFT", UIParent, "LEFT", 40, 0)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 14,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	frame:SetBackdropColor(0.05, 0.05, 0.08, 0.9)
	frame:SetBackdropBorderColor(0.35, 0.35, 0.45)
	MM.Theme.Register(frame, "panel")
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		MM.db.compactPos = { point = point, relPoint = relPoint, x = x, y = y }
	end)
	if MM.db.compactPos then
		frame:ClearAllPoints()
		frame:SetPoint(MM.db.compactPos.point, UIParent, MM.db.compactPos.relPoint,
			MM.db.compactPos.x, MM.db.compactPos.y)
	end

	local band = frame:CreateTexture(nil, "BORDER")
	band:SetPoint("TOPLEFT", 4, -4)
	band:SetPoint("TOPRIGHT", -4, -4)
	band:SetHeight(18)
	local hc = MM.Theme.Colors().header
	band:SetColorTexture(hc[1], hc[2], hc[3], hc[4] or 0.12)
	frame.mmBand = band

	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.title:SetPoint("TOPLEFT", 10, -7)
	frame.title:SetText("Master Mounts")
	MM.Theme.RegisterText(frame.title, "accent")
	frame.mode = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.mode:SetPoint("LEFT", frame.title, "RIGHT", 4, 0)
	frame.mode:SetText("— Plan")
	MM.Theme.RegisterText(frame.mode, "muted")

	local close = MM.Theme.CreateCloseButton(frame, 16)
	close:SetPoint("TOPRIGHT", -6, -4)
	close.mmTooltip = "Close compact mode"
	close:SetScript("OnClick", function()
		frame:Hide()
		MM.db.compactShown = false
	end)

	local expand = MM.Theme.CreateExpandButton(frame, 16)
	expand:SetPoint("RIGHT", close, "LEFT", -5, 0)

	-- Stop the route from the HUD you are actually looking at while running
	-- one. Without it, stopping meant re-opening the full window purely to
	-- press a button and close it again.
	--
	-- The gap is 10px rather than the 5px used between close and expand, and
	-- deliberately so: this button ENDS the route and its neighbour opens a
	-- window, so a misclick is not a cosmetic mistake. Cheap insurance for one
	-- row of pixels.
	local stopBtn = MM.Theme.CreateStopButton(frame, 16)
	stopBtn:SetPoint("RIGHT", expand, "LEFT", -10, 0)
	stopBtn.mmTooltip = "Stop the route (closes the plan, arrow and Next Up)"
	stopBtn:SetScript("OnClick", function()
		if MM.cdb and MM.cdb.routeActive then MM:Fire("MM_ROUTE_TOGGLE") end
	end)
	-- Only meaningful while a route runs; otherwise it is a dead control that
	-- invites a click that does nothing.
	stopBtn:SetShown(MM.cdb and MM.cdb.routeActive or false)
	frame.mmStopButton = stopBtn
	expand.mmTooltip = "Open the full Master Mounts window"
	expand:SetScript("OnClick", function()
		frame:Hide()
		MM:Fire("MM_TOGGLE_MAIN")
	end)

	rows = {}
	for i = 1, ROWS_SHOWN do
		local row = CreateFrame("Button", nil, frame)
		row:SetSize(276, 24)
		row:SetPoint("TOPLEFT", 10, -24 - (i - 1) * 24)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

		row.hl = row:CreateTexture(nil, "HIGHLIGHT")
		row.hl:SetAllPoints()
		MM.Theme.RegisterTint(row.hl, "accent", 0.10)

		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(18, 18)
		row.icon:SetPoint("LEFT", 0, 0)
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		MM.Theme.RoundIcon(row, row.icon)

		row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.text:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
		row.text:SetPoint("RIGHT", -20, 0)
		row.text:SetJustifyH("LEFT")
		row.text:SetWordWrap(false)
		MM.Theme.RegisterText(row.text, "primary")

		row.remove = MM.Theme.CreateCloseButton(row, 14)
		row.remove:SetPoint("RIGHT", -2, 0)
		row.remove.mmTooltip = "Remove from plan"
		row.remove:SetScript("OnClick", function(self)
			local e = self:GetParent().entry
			if e then MM.Planner:Remove(e.spellID) end
		end)

		row:SetScript("OnEnter", function(self)
			if self.entry then MM.UI.ShowMountTooltip(self, self.entry, "compact") end
		end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row:SetScript("OnClick", function(self, mouse)
			if self.entry then MM.UI.RowClick(self.entry, mouse) end
		end)
		MM.Theme.Register(row, "row", false)
		rows[i] = row
	end

	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, delta)
		offset = math.max(0, offset - delta)
		MM.UI.RefreshCompact()
	end)

	------------------------------------------------------------
	-- Scrollbar
	------------------------------------------------------------
	-- The gutter was always there and nothing was drawn in it, so a list of 286
	-- goals looked like a list of 12 unless you happened to try the wheel. A
	-- scrollbar is not decoration; it is the only thing that says "there is
	-- more". Built by hand rather than with a Slider template: vertical sliders
	-- disagree with each other about which end is zero, and a scrollbar that
	-- runs backwards is worse than none.
	local track = CreateFrame("Frame", nil, frame)
	track:SetPoint("TOPRIGHT", -5, -24)
	track:SetPoint("BOTTOMRIGHT", -5, 6)
	track:SetWidth(8)
	local trackTex = track:CreateTexture(nil, "BACKGROUND")
	trackTex:SetAllPoints()
	MM.Theme.RegisterTint(trackTex, "muted", 0.12)

	local thumb = CreateFrame("Button", nil, track)
	thumb:SetWidth(8)
	thumb:SetPoint("TOP", track, "TOP", 0, 0)
	local thumbTex = thumb:CreateTexture(nil, "ARTWORK")
	thumbTex:SetAllPoints()
	local function tintThumb(hot)
		local color = MM.Theme.Color(hot and "accent" or "muted")
		thumbTex:SetColorTexture(color[1], color[2], color[3], hot and 0.95 or 0.82)
	end
	tintThumb(false)
	thumb:SetScript("OnEnter", function() tintThumb(true) end)
	thumb:SetScript("OnLeave", function() tintThumb(false) end)
	MM:On("MM_THEME_CHANGED", function() tintThumb(thumb:IsMouseOver()) end)

	local dragging
	thumb:RegisterForDrag("LeftButton")
	thumb:SetScript("OnDragStart", function() dragging = true end)
	thumb:SetScript("OnDragStop", function() dragging = nil end)
	thumb:SetScript("OnUpdate", function(self)
		if not dragging then return end
		local total = frame.mmTotal or 0
		local maxOffset = math.max(0, total - ROWS_SHOWN)
		if maxOffset == 0 then return end
		local _, cursorY = GetCursorPosition()
		local scale = self:GetEffectiveScale()
		local top, height = track:GetTop(), track:GetHeight()
		if not (top and height and height > 0) then return end
		local frac = (top - cursorY / scale) / height
		local want = math.floor(frac * maxOffset + 0.5)
		want = math.max(0, math.min(maxOffset, want))
		if want ~= offset then
			offset = want
			MM.UI.RefreshCompact()
		end
	end)

	-- click the empty track to page toward the click
	track:EnableMouse(true)
	track:SetScript("OnMouseDown", function(self)
		local _, cursorY = GetCursorPosition()
		local thumbTop = thumb:GetTop()
		if not thumbTop then return end
		offset = offset + ((cursorY / self:GetEffectiveScale() > thumbTop)
			and -ROWS_SHOWN or ROWS_SHOWN)
		offset = math.max(0, offset)
		MM.UI.RefreshCompact()
	end)

	frame.mmTrack, frame.mmThumb = track, thumb

	MM.Theme.SkinTree(frame)
	frame:Hide()
end

-- Compact must show the SAME order as the Planner tab.
--
-- MM.cdb.plan is INSERTION order, and Auto-Plan All Missing walks the
-- alphabetically-sorted journal — so raw plan order is alphabetical, while
-- the Planner tab displays route order. Showing one list two different ways
-- reads as a bug even though both are "the plan".
local function orderedPlan()
	local plan = MM.Planner:GetPlan()
	if #plan == 0 then return plan end

	-- Reuse the route the Planner already built. Do NOT build one here.
	--
	-- This ran during MM_SCANNED, before any route exists, so refreshing a panel
	-- kicked off a full multi-modal route build -- seconds of work, synchronously,
	-- inside a UI refresh. It was also why the client froze BEFORE the "resuming
	-- your route" message: this handler runs ahead of the router's own, so the
	-- pause happened before anything could announce it.
	--
	-- With no route we fall through to plan order, which is a real answer and
	-- costs nothing. MM_ROUTE_STARTED refreshes the panel once the build lands.
	if #MM.Router.route == 0 then return plan end

	local out, seen = {}, {}
	for _, step in ipairs(MM.Router.route) do
		-- a stop can carry several mounts; list them all, in stop order
		for _, m in ipairs(step.members or { step }) do
			if m.entry and not seen[m.entry] then
				seen[m.entry] = true
				tinsert(out, m.entry)
			end
		end
	end
	-- Deferred goals are deliberately NOT listed.
	--
	-- The router already refuses to route them -- locked, not up today, prereq
	-- unmet -- so listing them anyway put things in the plan that the plan will
	-- not take you to. A player reading the list cannot tell those apart from
	-- the real targets, and acting on one wastes the trip.
	--
	-- They are counted, not silently dropped: vanishing entries are their own
	-- kind of confusion, and the count is how you know the plan still holds them.
	local hidden = 0
	for _, d in ipairs(MM.Router.deferred) do
		if d.entry and not seen[d.entry] then
			seen[d.entry] = true   -- claim it so the plan loop below cannot re-add it
			hidden = hidden + 1
		end
	end
	frame.mmHidden = hidden
	-- anything the router didn't place still belongs in the list
	for _, entry in ipairs(plan) do
		if not seen[entry] then
			seen[entry] = true
			tinsert(out, entry)
		end
	end
	return out
end

function MM.UI.RefreshCompact()
	if not frame or not frame:IsShown() then return end
	local plan = orderedPlan()
	local maxOffset = math.max(0, #plan - ROWS_SHOWN)
	if offset > maxOffset then offset = maxOffset end
	frame.mmTotal = #plan

	-- Size the thumb to the fraction on screen and put it where we are. Hidden
	-- entirely when everything fits, so the gutter is not a lie about there
	-- being more.
	local track, thumb = frame.mmTrack, frame.mmThumb
	if track and thumb then
		if maxOffset == 0 then
			track:Hide()
		else
			track:Show()
			local height = track:GetHeight()
			local visible = math.min(1, ROWS_SHOWN / math.max(#plan, 1))
			local thumbH = math.max(20, height * visible)
			thumb:SetHeight(thumbH)
			thumb:ClearAllPoints()
			thumb:SetPoint("TOP", track, "TOP", 0,
				-(height - thumbH) * (offset / maxOffset))
		end
	end

	if frame.title then
		frame.title:SetText(("|cff33c1ffMaster Mounts|r — Plan  |cff9a9a9a%d-%d of %d|r")
			:format(math.min(offset + 1, #plan), math.min(offset + ROWS_SHOWN, #plan), #plan))
	end

	for i = 1, ROWS_SHOWN do
		local row = rows[i]
		local entry = plan[i + offset]
		row.entry = entry
		row.remove:SetShown(entry ~= nil)
		if entry then
			local status = MM.Availability.GetStatus(entry)
			row.icon:SetTexture(entry.icon or 134400)
			row.icon:Show()
			local marker = ""
			local cur = MM.Router:Current()
			if cur and cur.entry == entry then marker = "|cffffd84d> |r" end
			-- Where your evening runs out, if you told us how long it is. Marked,
			-- never cut: someone who turns out to have longer should still be
			-- able to see what comes next.
			local stop = MM.Router.StopFor and MM.Router.StopFor(entry.spellID)
			if stop and stop.sessionBoundary then marker = "|cffff8040— |r" .. marker end
			row.text:SetText(marker .. entry.name .. "  "
				.. U.Color(status, U.STATUS_LABEL[status] or status))
			row:Show()
		else
			row:Hide()
			row.icon:Hide()
		end
	end
end

-- Explicit, so the route lifecycle can drive visibility without going through
-- a toggle and guessing at the current state.
function MM.UI.SetCompactShown(show)
	build()
	if show then
		frame:Show()
		MM.UI.RefreshCompact()
	else
		frame:Hide()
	end
	MM.db.compactShown = show and true or false
end

MM:On("MM_TOGGLE_COMPACT", function()
	build()
	if frame:IsShown() then frame:Hide() else frame:Show() MM.UI.RefreshCompact() end
	MM.db.compactShown = frame:IsShown()
end)

-- restore the compact HUD if it was open at logout
MM:On("MM_SCANNED", function()
	if MM.db.compactShown and not (frame and frame:IsShown()) then
		build()
		frame:Show()
		MM.UI.RefreshCompact()
	end
end)
local function syncStopButton()
	if frame and frame.mmStopButton then
		frame.mmStopButton:SetShown(MM.cdb and MM.cdb.routeActive or false)
	end
end
MM:On("MM_ROUTE_STARTED", syncStopButton)
-- The panel now shows plan order until a route exists, so it has to refresh
-- once one does -- otherwise it would sit on the pre-route ordering forever.
MM:On("MM_ROUTE_STARTED", function() MM.UI.RefreshCompact() end)
MM:On("MM_ROUTE_STOPPED", syncStopButton)

MM:On("MM_PLAN_CHANGED", function() MM.UI.RefreshCompact() end)
MM:On("MM_ROUTE_ADVANCED", function() MM.UI.RefreshCompact() end)
-- The route landing is its own event now. Without this the compact list would
-- keep showing the previous route until the player happened to advance.
MM:On("MM_ROUTE_BUILT", function() MM.UI.RefreshCompact() end)
MM:On("MM_SCANNED", function() MM.UI.RefreshCompact() end)
MM:On("MM_TRADINGPOST", function() MM.UI.RefreshCompact() end)
