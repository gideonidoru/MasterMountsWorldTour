-- Master Mounts monitor: the compact HUD shown while running a route —
-- current goal, attempts, odds, and what's next.
local _, MM = ...
local U = MM.Util
local UI = MM.UI

local frame

local function build()
	if frame then return end

	frame = CreateFrame("Frame", "MasterMountsMonitor", UIParent, "BackdropTemplate")
	frame:SetSize(300, 170)
	frame:SetPoint("RIGHT", UIParent, "RIGHT", -60, 80)
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
	frame:SetBackdropColor(0.05, 0.05, 0.08, 0.92)
	frame:SetBackdropBorderColor(0.8, 0.65, 0.2)
	MM.Theme.Register(frame, "panel")
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		MM.db.monitorPos = { point = point, relPoint = relPoint, x = x, y = y }
	end)
	if MM.db.monitorPos then
		frame:ClearAllPoints()
		frame:SetPoint(MM.db.monitorPos.point, UIParent, MM.db.monitorPos.relPoint,
			MM.db.monitorPos.x, MM.db.monitorPos.y)
	end

	-- gold header band
	local band = frame:CreateTexture(nil, "BORDER")
	band:SetPoint("TOPLEFT", 4, -4)
	band:SetPoint("TOPRIGHT", -4, -4)
	band:SetHeight(20)
	local hc = MM.Theme.Colors().header
	band:SetColorTexture(hc[1], hc[2], hc[3], hc[4] or 0.15)
	frame.mmBand = band

	frame.step = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	frame.step:SetPoint("TOPLEFT", 10, -8)
	frame.step:SetTextColor(1, 0.82, 0.2)

	local close = MM.Theme.CreateCloseButton(frame, 16)
	close:SetPoint("TOPRIGHT", -6, -5)
	close.mmTooltip = "Hide the route monitor"
	close:SetScript("OnClick", function() frame:Hide() end)

	frame.iconPlate = frame:CreateTexture(nil, "BORDER")
	frame.iconPlate:SetColorTexture(0, 0, 0, 0.55)
	frame.icon = frame:CreateTexture(nil, "ARTWORK")
	frame.icon:SetSize(36, 36)
	frame.icon:SetPoint("TOPLEFT", 10, -26)
	frame.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	frame.iconPlate:SetPoint("TOPLEFT", frame.icon, -2, 2)
	frame.iconPlate:SetPoint("BOTTOMRIGHT", frame.icon, 2, -2)

	frame.name = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.name:SetPoint("TOPLEFT", frame.icon, "TOPRIGHT", 8, -2)
	frame.name:SetPoint("RIGHT", -10, 0)
	frame.name:SetJustifyH("LEFT")
	frame.name:SetWordWrap(false)

	frame.goal = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.goal:SetPoint("BOTTOMLEFT", frame.icon, "BOTTOMRIGHT", 8, 2)
	frame.goal:SetPoint("RIGHT", -10, 0)
	frame.goal:SetJustifyH("LEFT")
	frame.goal:SetWordWrap(false)

	frame.est = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.est:SetPoint("TOPLEFT", 10, -64)
	frame.est:SetPoint("RIGHT", -10, 0)
	frame.est:SetJustifyH("LEFT")
	frame.est:SetTextColor(0.4, 0.8, 1)

	-- Everything below the estimate FLOWS. The estimate wraps to two lines for
	-- any long drop-rate string ("~1 in 100 — median 69 tries, 90% by 230…"),
	-- and with fixed offsets the second line landed on top of the status.
	frame.status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.status:SetPoint("TOPLEFT", frame.est, "BOTTOMLEFT", 0, -4)
	frame.status:SetPoint("RIGHT", -10, 0)
	frame.status:SetJustifyH("LEFT")

	-- The other mounts at this stop are most of the reason to be standing here,
	-- so they get their own line rather than being crammed into the goal text.
	frame.also = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.also:SetPoint("TOPLEFT", frame.status, "BOTTOMLEFT", 0, -4)
	frame.also:SetPoint("RIGHT", -10, 0)
	frame.also:SetJustifyH("LEFT")
	frame.also:SetWordWrap(false)

	frame.nextUp = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	-- flows under `also`, which collapses to zero height when empty
	frame.nextUp:SetPoint("TOPLEFT", frame.also, "BOTTOMLEFT", 0, -6)  -- `also` is 0-high when empty
	frame.nextUp:SetPoint("RIGHT", -10, 0)
	frame.nextUp:SetJustifyH("LEFT")
	frame.nextUp:SetTextColor(0.6, 0.6, 0.6)

	local prev = UI.MakeButton(frame, "Back", 48)
	prev:SetPoint("BOTTOMLEFT", 8, 8)
	prev:SetScript("OnClick", function() MM.Router:Advance(-1) end)

	local skip = UI.MakeButton(frame, "Skip", 48)
	skip:SetPoint("LEFT", prev, "RIGHT", 4, 0)
	skip:SetScript("OnClick", function() MM.Router:Advance(1) end)

	local stop = UI.MakeButton(frame, "Stop Route", 90)
	stop:SetPoint("BOTTOMRIGHT", -8, 8)
	stop:SetScript("OnClick", function() MM.Router:Stop() end)

	-- one click to put you in the difficulty this goal actually drops at
	frame.diffBtn = UI.MakeButton(frame, "Set Difficulty", 104)
	frame.diffBtn:SetPoint("RIGHT", stop, "LEFT", -4, 0)
	frame.diffBtn:SetScript("OnClick", function(self)
		if self.difficultyID then MM.Lockouts.SetDifficulty(self.difficultyID) end
	end)
	frame.diffBtn:Hide()

	MM.Theme.SkinTree(frame)
	frame:Hide()
end

local function refresh()
	if not frame or not frame:IsShown() then return end
	local cur = MM.Router:Current()
	if not cur then
		frame.step:SetText("No active route")
		frame.name:SetText("Start a route from the Planner tab")
		frame.goal:SetText("")
		frame.est:SetText("")
		frame.status:SetText("")
		frame.also:SetText("")
		frame.nextUp:SetText("")
		return
	end

	-- A session's total is what FITS, not the whole plan.
	--
	-- This read #MM.Router.route unconditionally, so picking "20 minutes" still
	-- announced 107 goals -- the session promised one thing and the counter
	-- said another. The extra stops are still there, and stepping past the last
	-- session goal walks into them; the number just stops overstating what you
	-- signed up for.
	local st = MM.Session and MM.Session.Active and MM.Session.Active()
	local total = (st and st.planned and st.planned > 0) and st.planned
		or #MM.Router.route
	frame.step:SetText(("GOAL %d / %d%s"):format(MM.cdb.routeIndex, total,
		cur.opportunistic and "   |cff5cb8ff(on the way)|r" or ""))
	frame.icon:SetTexture(cur.entry.icon or 134400)
	frame.name:SetText(cur.label)

	-- context line: skip the zone suffix when the description already says it
	local desc = cur.desc or ""
	local zoneName = cur.rec.zone and cur.rec.zone.name
	if zoneName and zoneName ~= "" and not desc:lower():find(zoneName:lower(), 1, true) then
		desc = desc .. "  —  " .. zoneName
	end
	if cur.rec.access then
		desc = desc .. "  |cff5cb8ff(" .. cur.rec.access .. ")|r"
	end
	frame.goal:SetText(desc)

	-- every fact once: estimate line, then status (detail only if it adds info)
	local est = MM.Planner:EstimateLine(cur.entry)
	if est == desc then est = nil end
	frame.est:SetText(est or "")

	local status, detail = MM.Availability.GetStatus(cur.entry)
	if detail and (detail == est or detail == desc
		or (cur.rec and detail == cur.rec.source)) then
		detail = nil
	end
	frame.status:SetText(U.Color(status, U.STATUS_LABEL[status] or status)
		.. (detail and ("|cffbbbbbb — " .. detail .. "|r") or ""))

	local wantedDiff = MM.Lockouts.WantedDifficulty(cur.rec)
	if wantedDiff and MM.DIFFICULTY_LABEL[wantedDiff] then
		frame.diffBtn.difficultyID = wantedDiff
		frame.diffBtn:SetText(MM.DIFFICULTY_LABEL[wantedDiff])
		frame.diffBtn:Show()
	else
		frame.diffBtn:Hide()
	end

	-- When a stop yields several mounts, the other ones ARE the reason you are
	-- standing here — showing only the primary hides most of the trip's value.
	local also = {}
	for _, m in ipairs(cur.members or {}) do
		if m.entry ~= cur.entry and not m.entry.collected then
			tinsert(also, m.entry.name)
		end
	end
	frame.also:SetText(#also > 0
		and ("|cffffd84dAlso here:|r " .. table.concat(also, ", ")) or "")

	local nexts = {}
	for i = MM.cdb.routeIndex + 1, math.min(MM.cdb.routeIndex + 2, #MM.Router.route) do
		tinsert(nexts, MM.Router.route[i].label)
	end
	frame.nextUp:SetText(#nexts > 0 and ("Next:  " .. table.concat(nexts, "  >  "))
		or "Last goal of the route!")

	-- Size the window to the text rather than hoping 170px is enough. The
	-- buttons sit at the bottom, so the frame has to be tall enough for the
	-- flowed block plus their row.
	local BUTTON_ROW = 40
	local used = 64                                  -- header, icon, goal line
		+ (frame.est:GetStringHeight() or 0)
		+ 4 + (frame.status:GetStringHeight() or 0)
		+ 4 + (frame.also:GetStringHeight() or 0)
		+ 6 + (frame.nextUp:GetStringHeight() or 0)
	frame:SetHeight(math.max(170, math.ceil(used) + BUTTON_ROW + 12))
end

function MM.UI.ToggleMonitor()
	build()
	if frame:IsShown() then frame:Hide() else frame:Show() refresh() end
end

-- Show it without the toggle ambiguity.
function MM.UI.ShowMonitor()
	build()
	if not frame:IsShown() then frame:Show() end
	refresh()
end

function MM.UI.HideMonitor()
	if frame and frame:IsShown() then frame:Hide() end
end

-- Next Up answers "what is the next stop on my route". With no route running
-- there is no next stop, so the window had nothing to say and saying nothing
-- in a floating frame just looks broken.
MM:On("MM_TOGGLE_MONITOR", function()
	if not (MM.cdb and MM.cdb.routeActive) then
		MM:Print("Next Up follows an active route — press Start Route first.")
		return
	end
	MM.UI.ToggleMonitor()
end)
MM:On("MM_ROUTE_ADVANCED", refresh)
MM:On("MM_ROUTE_STOPPED", function() MM.UI.HideMonitor() end)
MM:On("MM_ATTEMPT", refresh)
MM:On("MM_SCANNED", refresh)

-- periodic refresh so lockout timers/currency stay fresh
C_Timer.NewTicker(30, refresh)
