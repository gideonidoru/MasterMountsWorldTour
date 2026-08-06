-- Master Mounts Planner tab: build the farm plan, see effort estimates,
-- and launch the optimized route.
local _, MM = ...
local U = MM.Util
local UI = MM.UI

local missingBox, planBox, summaryText, routeButton

------------------------------------------------------------
-- Missing-list rows (left pane)
------------------------------------------------------------
local function initMissingRow(row, entry)
	if not row.built then
		row.built = true
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row.hl = row:CreateTexture(nil, "HIGHLIGHT")
		row.hl:SetAllPoints()
		row.hl:SetColorTexture(1, 0.82, 0.2, 0.08)

		-- ONE ICON SIZE ACROSS THE ADDON.
		--
		-- The missing list drew 28, the plan drew 30 and the collection window
		-- 36, so the same mount changed size depending on which pane it sat in
		-- and the two halves of one window read as two different addons. 32 in
		-- both planner panes matches the collection's proportions without
		-- touching row height -- the spacing is deliberate and stays.
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(32, 32)
		row.icon:SetPoint("LEFT", 6, 0)
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

		-- THE NAME AND ITS LINE ARE ONE BLOCK.
		--
		-- The name was pinned to the icon's TOP and the description to its
		-- BOTTOM. With a 32px icon in a 34px row that put one at each edge, so
		-- the gap between a mount and its own description was larger than the
		-- gap between rows -- and every name read as belonging to the
		-- description above it.
		--
		-- The description now hangs off the NAME, not off the icon, so the two
		-- stay together whatever the icon does. The row is taller to give them
		-- somewhere to sit.
		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
		row.name:SetPoint("RIGHT", -46, 0)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)

		row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
		row.sub:SetPoint("RIGHT", -46, 0)
		row.sub:SetJustifyH("LEFT")
		row.sub:SetTextColor(0.6, 0.6, 0.6)
		row.sub:SetWordWrap(false)

		row.add = UI.MakeRowAction(row)
		row.add:SetPoint("RIGHT", -6, 0)
		row.add:SetScript("OnClick", function(self)
			local e = self:GetParent().entry
			if MM.Planner:InPlan(e.spellID) then
				MM.Planner:Remove(e.spellID)
			else
				MM.Planner:Add(e.spellID)
			end
		end)

		row:SetScript("OnEnter", function(self) UI.ShowMountTooltip(self, self.entry) end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row:SetScript("OnClick", function(self, mouse) UI.RowClick(self.entry, mouse) end)
	end

	row.entry = entry
	row.icon:SetTexture(entry.icon or 134400)
	row.name:SetText(entry.name)
	local status = MM.Availability.GetStatus(entry)
	row.sub:SetText(U.Color(status, U.STATUS_LABEL[status] or status)
		.. "|cff9a9a9a — " .. (entry.rec.source or "") .. "|r")
	row.add:mmSet(MM.Planner:InPlan(entry.spellID))
end

------------------------------------------------------------
-- Plan rows (right pane)
------------------------------------------------------------
local function initPlanRow(row, data)
	local entry, index = data.entry, data.index
	if not row.built then
		row.built = true
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row.hl = row:CreateTexture(nil, "HIGHLIGHT")
		row.hl:SetAllPoints()
		row.hl:SetColorTexture(1, 0.82, 0.2, 0.08)

		-- gold bar marking the active route goal
		row.cur = row:CreateTexture(nil, "ARTWORK")
		row.cur:SetWidth(4)
		row.cur:SetPoint("TOPLEFT", 0, -2)
		row.cur:SetPoint("BOTTOMLEFT", 0, 2)
		row.cur:SetColorTexture(1, 0.82, 0.2, 0.9)

		row.num = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.num:SetPoint("LEFT", 6, 0)
		-- Wide enough for THREE digits and the full stop. A hundred-stop route
		-- is normal and 22px truncated every one of them past 99 to "1...",
		-- so the end of a long plan lost its numbering entirely.
		row.num:SetWidth(30)
		row.num:SetJustifyH("RIGHT")

		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(32, 32)
		row.icon:SetPoint("LEFT", 40, 0)
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
		-- 66px was three buttons wide. With the arrows gone only the
		-- [-] remains, so the name gets 20px back -- these truncate.
		row.name:SetPoint("RIGHT", -46, 0)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)

		row.est = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.est:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
		row.est:SetPoint("RIGHT", -46, 0)
		row.est:SetJustifyH("LEFT")
		row.est:SetTextColor(0.4, 0.8, 1)
		row.est:SetWordWrap(false)

		-- The SAME control the missing list uses, so one gesture means one
		-- thing everywhere: [+] puts a mount on the plan, [-] takes it off.
		-- This was an [x] close glyph, which reads as "dismiss this row"
		-- rather than "take this off the plan".
		row.remove = UI.MakeRowAction(row)
		row.remove:SetPoint("RIGHT", -6, 0)
		row.remove:mmSet(true)
		row.remove.mmTooltip = "Remove from plan"
		row.remove:SetScript("OnClick", function(self)
			MM.Planner:Remove(self:GetParent().entry.spellID)
		end)

		-- NO UP/DOWN ARROWS.
		--
		-- The plan charts itself now: every add, removal and lockout re-slots
		-- the order by preference, shared stops and travel time. An arrow that
		-- nudges a row one place would be undone by the next change, so it did
		-- not give you control -- it implied control that was not there, and a
		-- misleading affordance is worse than an absent one.
		--
		-- Removing a goal is the real control, and it is the same [-] the
		-- missing-mounts list uses.

		row:SetScript("OnEnter", function(self) UI.ShowMountTooltip(self, self.entry) end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row:SetScript("OnClick", function(self, mouse) UI.RowClick(self.entry, mouse) end)
	end

	row.entry = entry
	row.num:SetText(index .. ".")
	row.icon:SetTexture(entry.icon or 134400)
	row.icon:SetDesaturated(data.waiting and true or false)
	row.name:SetText(entry.name)
	local tier, _, reason = MM.Planner.Rank(entry)
	-- `reason` was preferred here and it restates the tier label it sits next to:
	-- "[Outdoor rare] Rare spawn kill" says one thing twice and tells you nothing
	-- about THIS mount. Progress first, then what it is, and the generic reason
	-- only when we have neither.
	local detail = MM.Planner:EstimateLine(entry)
		or (entry.rec and entry.rec.source) or reason or ""
	local tierLabel = MM.Planner.TIER_LABEL[tier] or "?"
	if U.Restates(detail, tierLabel) then detail = (entry.rec and entry.rec.source) or "" end
	local est = ("|cff8888c8[%s]|r %s"):format(tierLabel, detail)
	-- urgency drives the route order, so lead with it when it's the reason
	local urgency, urgencyReason = MM.Planner.Urgency(entry)
	if urgency == MM.Planner.URGENCY.EXPIRING then
		est = "|cffff5555[ending soon]|r " .. est
	elseif urgency == MM.Planner.URGENCY.LOCKOUT then
		est = "|cffffd84d[resets - do it now]|r " .. est
	end
	if data.opportunistic then
		est = "|cff5cb8ff[on the way]|r " .. est
	end
	if data.noLocation then
		est = "|cff9a9a9a[no map location]|r " .. est
	end
	if data.waiting then
		est = "|cffff9a3c[waiting: " .. (U.STATUS_LABEL[data.waiting] or data.waiting):lower()
			.. "]|r " .. est
	end
	row.est:SetText(est)
	local step = MM.cdb.routeActive and MM.Router.route[MM.cdb.routeIndex]
	local isCurrent = step and step.entry == entry
	row.cur:SetShown(isCurrent or false)
	row.num:SetTextColor(isCurrent and 1 or 1, isCurrent and 0.82 or 1, isCurrent and 0.2 or 1)
end

------------------------------------------------------------
-- Panel
------------------------------------------------------------
function UI.BuildPlanner(panel)
	-- Restored at LOGIN now, not here -- see Planner.RestoreFilters. Doing it
	-- at panel-build time meant the login warm-up used the defaults and its
	-- work was thrown away the moment the window opened. Still called here so
	-- the panel cannot draw against unrestored filters if it somehow builds
	-- before the first scan.
	MM.Planner.RestoreFilters()
	local saved = MM.db and MM.db.ui or {}

	-- toolbar band behind the button row
	local band = panel:CreateTexture(nil, "BORDER")
	band:SetPoint("TOPLEFT")
	band:SetPoint("TOPRIGHT")
	band:SetHeight(30)
	band:SetColorTexture(0, 0, 0, 0.35)

	-- "All Missing" trimmed to "All": the row is 1000px of window and the long
	-- form put the last control within a few pixels of the edge.
	local autoBtn = UI.MakeButton(panel, "Auto-Plan All")
	autoBtn:SetPoint("TOPLEFT", 8, -4)
	autoBtn:SetScript("OnClick", function()
		-- Returns what it WILL add: the adding now runs across frames so the
		-- progress bar can actually move, so it has not finished by the time
		-- this returns.
		local n = MM.Planner:AutoPlanAll()
		if n == 0 then
			MM:Print("Everything plannable is already on your plan.")
		else
			MM:Print("Adding %d mounts to the plan...", n)
		end
	end)

	local easyBtn = UI.MakeButton(panel, "Add 10 Easiest")
	easyBtn:SetPoint("LEFT", autoBtn, "RIGHT", 6, 0)
	easyBtn:SetScript("OnClick", function()
		for _, entry in ipairs(MM.Planner:Easiest(10)) do
			MM.Planner:Add(entry.spellID)
		end
	end)

	-- NO "Optimize" BUTTON. The route is always optimized.
	--
	-- Optimize called Router:Build() and then reordered cdb.plan to match the
	-- route it had just built. The route was never the thing being improved --
	-- Build reads the plan as an unordered SET and applies its own three layers
	-- every time, pressed or not. All the button did was overwrite your manual
	-- plan order (the up/down arrows on each row) with the router's.
	--
	-- So it improved nothing and destroyed something, while implying your route
	-- was second-rate until you found it. The slot is better spent on the
	-- session picker, which changes the route for real.
	-- TOOLBAR ORDER: act, then set, then look.
	--
	--   [Auto-Plan] [Add 10 Easiest] [Clear Plan] | [Session] | [Available] [Category] [Sort]
	--    -------- change the plan ------------      -setting-   ---- change the view ----
	--
	-- Clear Plan belongs beside the two buttons it undoes, not stranded after
	-- an unrelated control -- and destructive actions sit at the END of their
	-- own group, which is where people expect to find them and where they are
	-- least likely to be hit by accident.
	--
	-- Session is neither an action on the plan nor a filter on the list: it
	-- changes how the plan gets EXECUTED. It gets its own slot between the two
	-- groups, with a wider gap on each side to say so.
	-- The plan view is now session-dependent, so it has to repaint when the
	-- session does. Without this you pick a length and the list sits unchanged
	-- until something else happens to refresh it -- which is exactly how this
	-- looked broken.
	MM:On("MM_SESSION_CHANGED", function()
		if UI.RefreshPlanner then UI.RefreshPlanner() end
	end)

	-- THE PANES SWAP ON ANY PLAN CHANGE, not just on a click in this window.
	--
	-- Now that a planned mount leaves the missing list, the list has to be
	-- rebuilt whenever the plan moves -- and clicking a row is only one of the
	-- ways it moves. A goal retired for a lockout, a mount collected, a plan
	-- edit from a slash command: each of those has to hand the mount back, or
	-- it stays hidden from both panes and looks like the addon lost it.
	--
	-- Guarded on visibility so a plan edit while the window is shut costs
	-- nothing; opening it refreshes anyway.
	MM:On("MM_PLAN_CHANGED", function()
		if panel:IsShown() and UI.RefreshPlanner then UI.RefreshPlanner() end
	end)

	local clearBtn = UI.MakeButton(panel, "Clear Plan")
	clearBtn:SetPoint("LEFT", easyBtn, "RIGHT", 6, 0)

	-- SESSION SITS OVER THE PLAN, because that is what it changes.
	--
	-- It used to sit in the middle of the toolbar, between the plan buttons and
	-- the list filters, on the reasoning that it was neither. But the two
	-- filters beside it act on the LEFT pane and the session acts on the RIGHT
	-- one, so the toolbar read as one row of unrelated controls and the only
	-- way to learn which did what was to try them. Each group now sits above
	-- the pane it affects.
	local sessionDrop = UI.MakeSessionPicker(panel)
	-- Anchored to the RIGHT EDGE, not a fixed x. A fixed 446 put it exactly
	-- where the Type filter lands once the checkbox before it is laid out, and
	-- the two drew on top of each other -- "NAllimit", with both arrows.
	-- Anchoring to the edge it belongs to cannot collide with a group that
	-- grows from the other side.
	sessionDrop:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -12, -2)
	panel.sessionDrop = sessionDrop
	clearBtn:SetScript("OnClick", function() MM.Planner:Clear() end)

	local availChk = UI.MakeCheck(panel, "Available now", function(v)
		MM.Planner.filters.onlyAvailable = v
		MM.db.ui.plnAvailable = v
		UI.RefreshPlanner()
	end)
	availChk:SetPoint("LEFT", clearBtn, "RIGHT", 14, 0)
	availChk:SetChecked(MM.Planner.filters.onlyAvailable)

	local catValues = { "GROUP_DROPS", "GROUP_BUY", "GROUP_ACH" }
	local catLabels = {}
	for k, v in pairs(MM.CATEGORY_GROUP_LABEL) do catLabels[k] = v end
	for _, c in ipairs(MM.CATEGORIES) do
		if MM.PLANNABLE[c.key] then
			tinsert(catValues, c.key)
			catLabels[c.key] = c.label
		end
	end
	local catBtn = UI.MakePicker(panel, "Type", catValues, catLabels, function(v)
		MM.Planner.filters.category = v
		MM.db.ui.plnCategory = v or false
		UI.RefreshPlanner()
	end, MM.Planner.filters.category, "All types", 140)
	catBtn:SetPoint("LEFT", availChk.labelText, "RIGHT", 12, 0)

	local sortBtn = UI.MakePicker(panel, "Sort", { "EASE", "STATUS", "EXPANSION" },
		{ EASE = "Sort by easiest", STATUS = "Sort by status",
		  EXPANSION = "Sort by expansion" }, function(v)
			MM.Planner.filters.sort = v
			MM.db.ui.plnSort = v or false
			UI.RefreshPlanner()
		end, MM.Planner.filters.sort, "Sort by name", 150)
	sortBtn:SetPoint("LEFT", catBtn, "RIGHT", 6, 0)

	-- left pane: missing
	-- A header ROW rather than free-floating anchors. Two widgets that must sit
	-- level need to share one vertical reference; anchoring each to the panel
	-- separately is how they drift apart by a few pixels and look untidy.
	local leftHeader = CreateFrame("Frame", nil, panel)
	leftHeader:SetPoint("TOPLEFT", 10, -28)
	leftHeader:SetPoint("TOPRIGHT", panel, "TOPLEFT", 436, -28)
	leftHeader:SetHeight(22)

	local leftLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	leftLabel:SetPoint("LEFT", leftHeader, "LEFT", 0, 0)
	leftLabel:SetText("Missing Mounts")
	local leftLine = panel:CreateTexture(nil, "ARTWORK")
	leftLine:SetPoint("TOPLEFT", 8, -60)
	leftLine:SetSize(430, 1)
	leftLine:SetColorTexture(0.85, 0.65, 0.2, 0.4)

	-- Right-aligned to the end of its own column rather than butted against the
	-- label. Anchored to the label's RIGHT edge, its position depended on the
	-- label's text width, so it read as shoved in: it had no relationship to
	-- the column it filters. Aligning it to the column edge gives it a margin
	-- on both sides and lets the header breathe.
	local missingSearch = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
	missingSearch:SetSize(210, 20)
	missingSearch:SetPoint("RIGHT", leftHeader, "RIGHT", 0, 0)
	missingSearch:SetAutoFocus(false)
	missingSearch:HookScript("OnTextChanged", function(self)
		MM.Planner.filters.search = self:GetText() or ""
		UI.RefreshPlanner()
	end)
	-- Deliberately not persisted, and cleared on build: a search left over from
	-- a previous session hides most of the list while looking like an empty
	-- box, which reads as lost mounts rather than an active filter.
	MM.Planner.filters.search = ""

	panel.missingEmpty = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	panel.missingEmpty:SetPoint("TOPLEFT", 40, -140)
	panel.missingEmpty:SetWidth(360)
	panel.missingEmpty:SetText("No missing mounts match these filters.")
	panel.missingEmpty:SetTextColor(0.55, 0.55, 0.6)
	panel.missingEmpty:Hide()

	missingBox = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
	missingBox:SetPoint("TOPLEFT", 4, -66)
	-- Full height. Only the plan column gives up space for the action strip
	-- below it; reserving the same gap on this side bought nothing and left a
	-- band of empty window under the missing list.
	missingBox:SetPoint("BOTTOMLEFT", 4, 6)
	missingBox:SetWidth(430)

	local missingBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
	missingBar:SetPoint("TOPLEFT", missingBox, "TOPRIGHT", 4, 0)
	missingBar:SetPoint("BOTTOMLEFT", missingBox, "BOTTOMRIGHT", 4, 0)

	local mview = CreateScrollBoxListLinearView()
	-- Room for a 32px icon and a two-line block without either touching an
	-- edge. 34 left no margin at all once the icons matched the rest of the
	-- addon.
	mview:SetElementExtent(46)
	mview:SetElementInitializer("Button", initMissingRow)
	ScrollUtil.InitScrollBoxListWithScrollBar(missingBox, missingBar, mview)
	missingBox.emptyText = panel.missingEmpty

	-- right pane: the plan
	local rightLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	local rightHeader = CreateFrame("Frame", nil, panel)
	rightHeader:SetPoint("TOPLEFT", 470, -28)
	rightHeader:SetPoint("TOPRIGHT", -26, -28)
	rightHeader:SetHeight(22)

	rightLabel:SetPoint("LEFT", rightHeader, "LEFT", 0, 0)
	rightLabel:SetText("Farm Plan (route order)")
	local rightLine = panel:CreateTexture(nil, "ARTWORK")
	rightLine:SetPoint("TOPLEFT", 470, -60)
	rightLine:SetSize(480, 1)
	rightLine:SetColorTexture(0.85, 0.65, 0.2, 0.4)

	panel.planEmpty = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	panel.planEmpty:SetPoint("TOPLEFT", 540, -140)
	panel.planEmpty:SetWidth(360)
	-- There is no Optimize button any more -- the plan charts itself the moment
	-- you change it -- and this line was still telling people to press one.
	panel.planEmpty:SetText("Your farm plan is empty.\n\nAdd mounts with the [+] buttons,"
		.. " or use Auto-Plan / Add 10 Easiest. The plan charts itself as soon as"
		.. " you add something; then press Start Route.")
	panel.planEmpty:SetTextColor(0.55, 0.55, 0.6)
	panel.planEmpty:Hide()
	panel.planEmptyRef = panel.planEmpty

	-- WORKING NOTICE, in the middle of the plan pane.
	--
	-- Auto-Plan walks the whole collection and then charts it, which is a
	-- visible pause with nothing on screen -- and a UI that goes quiet under
	-- load reads as broken rather than busy.
	--
	-- There is NO progress bar. The add sweep can be counted and is; the
	-- charting is one call into the router that cannot report from inside, and
	-- a bar sweeping through it would be measuring nothing while looking like
	-- it measured something. So the counted part shows its count, the
	-- uncountable part says plainly that the client will feel stuck, and the
	-- whole notice is replaced by the plan itself when the work lands.
	local notice = CreateFrame("Frame", nil, panel)
	notice:SetPoint("TOPLEFT", 470, -66)
	notice:SetPoint("BOTTOMRIGHT", -26, 48)
	notice:SetFrameLevel(panel:GetFrameLevel() + 10)

	notice.bg = notice:CreateTexture(nil, "BACKGROUND")
	notice.bg:SetAllPoints()
	notice.bg:SetColorTexture(0.03, 0.03, 0.05, 0.88)

	notice.head = notice:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	notice.head:SetPoint("CENTER", 0, 22)
	notice.head:SetTextColor(1, 0.82, 0.2)

	notice.body = notice:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	notice.body:SetPoint("TOP", notice.head, "BOTTOM", 0, -14)
	notice.body:SetWidth(380)
	notice.body:SetJustifyH("CENTER")
	notice.body:SetTextColor(0.75, 0.75, 0.8)
	notice:Hide()
	panel.notice = notice

	MM:On("MM_PLAN_PROGRESS", function(done, total, phase)
		if not phase then notice:Hide() return end
		notice:Show()
		if done and total and total > 0 and done < total then
			notice.head:SetText(("Adding mounts -- %d of %d"):format(done, total))
			notice.body:SetText("")
		else
			notice.head:SetText("Charting the optimal route")
			notice.body:SetText(total and total > 0
				and (("%d goals. This may take a moment, and your client may feel "
					.. "unresponsive until it finishes."):format(total))
				or "This may take a moment, and your client may feel unresponsive "
					.. "until it finishes.")
		end
	end)

	-- The primary action on this screen, and it looked like every other button.
	-- Everything else here is preparation; this is the one that starts you
	-- moving, so it is bigger, gold, and carries a glow while idle. When a
	-- route IS running the emphasis is wrong -- stopping is not what you are
	-- being encouraged to do -- so it drops back to a plain button.
	-- Bottom right, not top right. In the header it sat on the same row as the
	-- plan's ETA and squeezed it until it truncated mid-word, and a primary
	-- action wedged between a heading and a window edge has nowhere to breathe.
	-- At the foot of the panel it gets margin on every side, it reads as the
	-- end of the flow (plan above, act below), and the ETA gets the whole row.
	routeButton = UI.MakeButton(panel, "Start Route", 170)
	routeButton:SetHeight(32)
	routeButton:SetScript("OnClick", function() MM:Fire("MM_ROUTE_TOGGLE") end)

	-- A thin accent EDGE, not a glow.
	--
	-- The first version was a filled rectangle bleeding 5px out behind the
	-- button. Bleeding colour around a control is the visual language of an
	-- error highlight, so it read as something being wrong rather than as the
	-- primary action -- in both skins.
	--
	-- It was also hardcoded gold, which fights ElvUI's blue accent outright.
	-- Four one-pixel edges in T.Accent() give the same "this is the one" and
	-- belong to whichever theme is running.
	local edges = {}
	for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
		local e = routeButton:CreateTexture(nil, "OVERLAY")
		if side == "TOP" or side == "BOTTOM" then
			e:SetPoint(side .. "LEFT", 1, 0)
			e:SetPoint(side .. "RIGHT", -1, 0)
			e:SetHeight(1)
		else
			e:SetPoint("TOP" .. side, 0, -1)
			e:SetPoint("BOTTOM" .. side, 0, 1)
			e:SetWidth(1)
		end
		edges[#edges + 1] = e
	end
	routeButton.mmEdges = edges

	-- Re-tinted on demand rather than set once: the theme can change while
	-- this window is open, and a gold edge left behind in an ElvUI window is
	-- exactly the sort of stale detail that reads as a bug.
	-- `active` is passed in rather than read back from cdb: SetRouteState is
	-- called BEFORE the flag is written on some paths, so reading it here made
	-- the text colour disagree with the label sitting next to it.
	function routeButton:ApplyAccent(active)
		if active == nil then active = MM.cdb and MM.cdb.routeActive end
		local r, g, b = 1, 0.82, 0.2
		if MM.Theme and MM.Theme.Accent then r, g, b = MM.Theme.Accent() end
		for _, e in ipairs(self.mmEdges or {}) do e:SetColorTexture(r, g, b, 0.85) end
		local fs = self:GetFontString()
		if fs then
			if active then fs:SetTextColor(0.85, 0.85, 0.85)
			else fs:SetTextColor(r, g, b) end
		end
	end

	function routeButton:SetRouteState(active)
		self:SetText(active and "Stop Route" or "Start Route")
		-- The edge marks the PRIMARY action. Once a route is running, stopping
		-- is not what the player is being encouraged to do, so it comes off.
		for _, e in ipairs(self.mmEdges or {}) do e:SetShown(not active) end
		self:ApplyAccent(active)
	end
	routeButton:ApplyAccent()
	MM:On("MM_THEME_CHANGED", function()
		if routeButton and routeButton.ApplyAccent then routeButton:ApplyAccent() end
	end)
	routeButton:SetRouteState(MM.cdb and MM.cdb.routeActive)

	-- bounded on BOTH sides so it truncates instead of overlapping the label
	summaryText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	summaryText:SetPoint("LEFT", rightLabel, "RIGHT", 14, 0)
	summaryText:SetPoint("RIGHT", rightHeader, "RIGHT", 0, 0)
	summaryText:SetJustifyH("RIGHT")
	summaryText:SetWordWrap(false)

	planBox = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
	planBox:SetPoint("TOPLEFT", 470, -66)
	planBox:SetPoint("BOTTOMRIGHT", -26, 48)

	local planBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
	planBar:SetPoint("TOPLEFT", planBox, "TOPRIGHT", 6, 0)
	planBar:SetPoint("BOTTOMLEFT", planBox, "BOTTOMRIGHT", 6, 0)

	local pview = CreateScrollBoxListLinearView()
	pview:SetElementExtent(46)
	pview:SetElementInitializer("Button", initPlanRow)
	ScrollUtil.InitScrollBoxListWithScrollBar(planBox, planBar, pview)
	planBox.emptyText = panel.planEmpty

	-- Anchored HERE, not where the button is created. planBox is an upvalue
	-- that is still nil further up this function, and SetPoint against a nil
	-- relative frame throws at run time -- invisible to a syntax check, and
	-- the button is built well before the list it belongs to.
	--
	-- Anchored to BOTH edges of the plan column rather than given a fixed
	-- width and centred. Two anchors make the width fall out of the layout, so
	-- it stays centred and correctly proportioned however the column is sized
	-- -- and it fills the empty band that a 170px button left on either side.
	-- The inset is what keeps it a button rather than a bar.
	routeButton:ClearAllPoints()
	routeButton:SetPoint("BOTTOMLEFT", planBox, "BOTTOMLEFT", 76, -42)
	routeButton:SetPoint("BOTTOMRIGHT", planBox, "BOTTOMRIGHT", -76, -42)

	routeButton:SetHeight(34)
end

function UI.RefreshPlanner()
	if not missingBox then return end

	-- THE TWO PANES ARE NOT CHOSEN AND CHOSEN.
	--
	-- The missing list used to show everything you do not own, INCLUDING what
	-- was already on the plan -- so a player who had planned most of their
	-- list looked at a left pane where every single row said "IN PLAN" and
	-- offered to remove it. The pane meant to answer "what could I add" was
	-- answering "what have you already added", which the right pane was
	-- answering better, in route order, at the same time.
	--
	-- Moving it across takes it out of the left list; taking it off the plan
	-- puts it back. One mount is in exactly one place, the [-] on this side
	-- becomes unreachable by construction, and the panes stop competing to
	-- describe the same thing.
	local all = MM.Planner:GetMissing()
	local missing = {}
	for _, entry in ipairs(all) do
		if not MM.Planner:InPlan(entry.spellID) then missing[#missing + 1] = entry end
	end
	missingBox:SetDataProvider(CreateDataProvider(missing),
		ScrollBoxConstants.RetainScrollPosition)
	if missingBox.emptyText then
		missingBox.emptyText:SetShown(#missing == 0)
		-- An empty list here means something GOOD -- everything reachable is
		-- planned -- and it has to say so, or it reads as a filter that broke.
		if #missing == 0 and missingBox.emptyText.SetText then
			missingBox.emptyText:SetText(#all > 0
				and "Everything here is already on your plan."
				or "Nothing matches those filters.")
		end
	end

	-- ordered as the route would run it
	MM.Router:Build()
	-- A SESSION CONSTRAINS THIS LIST.
	--
	-- Picking "45 minutes" was computing the right answer, announcing it in
	-- chat, and then showing all 106 stops anyway -- so the one surface the
	-- player is actually looking at contradicted the choice they had just made.
	-- Constraining the plan view is what "plan for the time I have" MEANS; the
	-- goal counter agreeing was never the point.
	--
	-- The rest of the plan is not deleted, only hidden behind the limit, and
	-- the header says how many are held back so nothing disappears silently.
	local items, zones = {}, {}
	local sess = MM.Session and MM.Session.Active and MM.Session.Active()
	local limit = (sess and sess.planned and sess.planned > 0) and sess.planned or nil
	local hiddenBySession = limit and math.max(0, #MM.Router.route - limit) or 0
	for i, step in ipairs(MM.Router.route) do
		if limit and i > limit then break end
		-- one stop, every mount it yields — sharing the stop's index so the
		-- numbering reflects trips made rather than mounts wanted
		for _, m in ipairs(step.members or { step }) do
			tinsert(items, { entry = m.entry, index = i,
				opportunistic = step.opportunistic, noLocation = step.noLocation,
				batched = #(step.members or {}) > 1 })
			if m.rec and m.rec.zone and m.rec.zone.name then
				zones[m.rec.zone.name] = true
			end
		end
	end
	-- unrouted goals are already appended to the route itself now
	local offRoute = #MM.Router.unrouted
	-- Deferred goals are counted, not listed.
	--
	-- The router refuses to route them -- locked, not up today, prereq unmet --
	-- so showing them in the plan advertised targets the plan will not take you
	-- to. `waiting` still reports how many are held back, which is the honest
	-- version: they have not been forgotten, they just are not actionable now.
	local waiting = #MM.Router.deferred
	planBox:SetDataProvider(CreateDataProvider(items), ScrollBoxConstants.RetainScrollPosition)
	if planBox.emptyText then planBox.emptyText:SetShown(#items == 0) end

	local zoneCount = 0
	for _ in pairs(zones) do zoneCount = zoneCount + 1 end
	local goalCount = 0
	for i, step in ipairs(MM.Router.route) do
		if limit and i > limit then break end
		goalCount = goalCount + #(step.members or { step })
	end
	-- "153 stops" answers a question nobody asked. What a collector wants to
	-- know before committing an evening is how long it takes and whether they
	-- end it with a mount, so lead with time and expectation and keep the counts
	-- as supporting detail.
	local t = MM.Router.totals
	local head = ""
	if t and t.stops > 0 then
		local mountText = t.mounts >= 1 and ("~%.1f mounts"):format(t.mounts)
			or ("~%d%% for a mount"):format(math.min(99, math.floor(t.mounts * 100 + 0.5)))
		-- Time on the route leads: that is the question a collector is asking.
		-- The full commitment sits behind it, not instead of it.
		head = ("|cffffd84d%s · %s|r |cff9a9a9a(%s to finish all)|r · "):format(
			U.FormatSeconds((t.routeMinutes or t.minutes) * 60), mountText,
			U.FormatSeconds(t.minutes * 60))
	end
	summaryText:SetText(head .. ("%d mounts · %d stops · %d zones%s%s%s"):format(
		goalCount, limit or #MM.Router.route, zoneCount,
		hiddenBySession > 0 and (" · " .. hiddenBySession .. " beyond this session") or "",
		offRoute > 0 and (" · " .. offRoute .. " unplaced") or "",
		waiting > 0 and (" · " .. waiting .. " waiting") or ""))
	routeButton:SetRouteState(MM.cdb.routeActive)
end

MM:On("MM_ROUTE_STARTED", function() if routeButton then routeButton:SetRouteState(true) end end)
MM:On("MM_ROUTE_STOPPED", function() if routeButton then routeButton:SetRouteState(false) end end)
