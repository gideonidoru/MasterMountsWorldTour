-- Master Mounts Planner tab: build the farm plan, see effort estimates,
-- and launch the optimized route.
local _, MM = ...
local U = MM.Util
local UI = MM.UI

local missingBox, planBox, summaryText, routeButton

------------------------------------------------------------
-- Missing-list rows (left pane)
------------------------------------------------------------
-- THE GLYPH HAS TO BEHAVE LIKE THE BUTTON IT REPLACED.
--
-- Dropping the child Button fixed the click and lost two things with it: a
-- FontString has no OnEnter, so it cannot light up or raise a tooltip of its
-- own. The Collection tab still does both, and one control that behaves two
-- ways depending on which pane it is in is its own small bug.
--
-- The row knows when the cursor is on it, so it polls WHILE HOVERED and only
-- then -- the script is attached on OnEnter and removed on OnLeave, so exactly
-- one row in the addon is ever running it, and none are when the pointer is
-- somewhere else. That is the same cost the old OnEnter had, spread over the
-- moments it is actually needed.
--
-- Matching the Collection tab's numbers on purpose: 0.75 at rest, 1.0 under
-- the pointer.
local PLUS_REST, PLUS_HOT = 0.75, 1
local PLUS_DIM = 0.35          -- a row the plan cannot key on

local function plusCanPlan(entry) return entry and entry.spellID ~= nil end

-- Returns true only when the state CHANGED, so the tooltip is rebuilt on the
-- crossing rather than on every frame.
local function setPlusHot(row, hot)
	if row.mmPlusHot == hot then return false end
	row.mmPlusHot = hot
	local planable = plusCanPlan(row.entry)
	if hot then
		row.plus:SetTextColor(0.75, 1, 0.8)
		row.plus:SetAlpha(planable and PLUS_HOT or PLUS_DIM)
	else
		row.plus:SetTextColor(0.45, 1, 0.5)
		row.plus:SetAlpha(planable and PLUS_REST or PLUS_DIM)
	end
	return true
end

local function plusTooltip(row)
	if row.mmPlusHot then
		GameTooltip:SetOwner(row, "ANCHOR_TOP")
		GameTooltip:SetText(plusCanPlan(row.entry) and "Add to farm plan"
			or "Cannot be planned")
		if not plusCanPlan(row.entry) then
			GameTooltip:AddLine("The mount journal gives this one no spell id, "
				.. "and the plan is keyed on one.", 0.8, 0.8, 0.8, true)
		end
		GameTooltip:Show()
	else
		UI.ShowMountTooltip(row, row.entry)
	end
end

local function initMissingRow(row, entry)
	if not row.built then
		row.built = true
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		row.hl = row:CreateTexture(nil, "HIGHLIGHT")
		row.hl:SetAllPoints()
		MM.Theme.RegisterTint(row.hl, "accent", 0.10)

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
		MM.Theme.RoundIcon(row, row.icon)

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
		MM.Theme.RegisterText(row.name, "primary")

		row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
		row.sub:SetPoint("RIGHT", -46, 0)
		row.sub:SetJustifyH("LEFT")
		row.sub:SetTextColor(0.6, 0.6, 0.6)
		row.sub:SetWordWrap(false)
		MM.Theme.RegisterText(row.sub, "muted")

		-- NO CHILD BUTTON HERE. THAT IS THE FIX.
		--
		-- [+] in this pane has now failed across four attempts, each of which
		-- assumed a different part of the child-Button machinery: the handler,
		-- the frame level, the click registration, the scroll box's anchors.
		-- The handlers are identical to the two that work, so every one of
		-- those was a guess, and guessing has cost five rounds.
		--
		-- So the machinery goes. A child Button brings a hit test against its
		-- parent, a frame level, a click registration, an anchor whose width is
		-- derived from a scroll box, and a mouse-down/mouse-up pair that must
		-- land on the SAME frame -- and a scroll view is entitled to recycle
		-- that frame underneath the cursor between the two. Any one of those
		-- fails silently and looks exactly like a dead button.
		--
		-- What replaces it cannot fail in any of those ways:
		--
		--   * the glyph is a FontString on the row, so it has no hit test, no
		--     frame level and no click registration of its own
		--   * the region that responds is the GLYPH'S OWN RECT, so what you see
		--     and what you can press are the same rectangle by construction --
		--     they cannot drift apart however the row is sized
		--   * it acts on OnMouseDown, so it does not need a press and a release
		--     to land on one frame that survives both
		--
		-- The row already receives mouse events -- its tooltip has worked
		-- throughout -- so this rests on the one thing observed to work.
		row.plus = row:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
		row.plus:SetPoint("RIGHT", -12, 0)
		row.plus:SetText("+")
		row.plus:SetTextColor(0.45, 1, 0.5)

		row.mmToggle = function(self)
			local e = self.entry
			-- A SILENT DECLINE LOOKS EXACTLY LIKE A DEAD BUTTON. Planner:Add
			-- opens `if not spellID ... then return end`, and a journal entry
			-- can genuinely have none -- Scanner guards for it. Such a row can
			-- never leave this pane either: InPlan(nil) is falsy, so the
			-- refresh filter keeps it and the glyph stays [+]. Say so.
			if not (e and e.spellID) then
				MM:Print("Cannot plan %s -- the mount journal gives it no spell "
					.. "id, and the plan is keyed on one.",
					(e and e.name) or "this mount")
				return
			end
			if MM.Planner:InPlan(e.spellID) then
				MM.Planner:Remove(e.spellID)
			else
				MM.Planner:Add(e.spellID)
			end
		end

		row:SetScript("OnEnter", function(self)
			setPlusHot(self, UI.CursorOver(self.plus))
			plusTooltip(self)
			-- Polling starts here and stops on OnLeave, so it runs on one row
			-- at a time and on none when the pointer is elsewhere.
			self:SetScript("OnUpdate", function(s)
				if setPlusHot(s, UI.CursorOver(s.plus)) then plusTooltip(s) end
			end)
		end)
		row:SetScript("OnLeave", function(self)
			self:SetScript("OnUpdate", nil)
			setPlusHot(self, false)
			GameTooltip:Hide()
		end)
		row:SetScript("OnMouseDown", function(self, button)
			-- Recorded so OnClick does not ALSO open the journal for the same
			-- press, and recomputed every time so a stale flag cannot leak into
			-- the next click.
			self.mmHitPlus = (button == "LeftButton") and UI.CursorOver(self.plus) or false
			if self.mmHitPlus then self.mmToggle(self) end
		end)
		row:SetScript("OnClick", function(self, mouse)
			if self.mmHitPlus then self.mmHitPlus = false return end
			UI.RowClick(self.entry, mouse)
		end)
		-- Scroll rows are born after the window's initial SkinTree pass. Register
		-- them at creation time so every recycled row receives its card surface,
		-- not only the handful that happened to exist during a later reskin.
		MM.Theme.Register(row, "row", false)
	end

	row.entry = entry
	row.icon:SetTexture(entry.icon or 134400)
	row.name:SetText(entry.name)
	local status = MM.Availability.GetStatus(entry)
	row.sub:SetText(U.Color(status, U.STATUS_LABEL[status] or status)
		.. "|cff9a9a9a — " .. (entry.rec.source or "") .. "|r")
	-- This pane only ever contains mounts that are NOT on the plan -- the
	-- refresh filters on exactly that -- so the glyph is always [+] and saying
	-- so is simpler than asking. A row that cannot be planned at all is dimmed,
	-- because a control that will refuse should not look like one that will not.
	--
	-- Cleared rather than assumed: rows are recycled, and one that was under
	-- the pointer when the list last rebuilt would otherwise keep its hover
	-- colour while describing a different mount.
	row.mmPlusHot = nil
	setPlusHot(row, false)
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
		MM.Theme.RegisterTint(row.hl, "accent", 0.10)

		-- gold bar marking the active route goal
		row.cur = row:CreateTexture(nil, "ARTWORK")
		row.cur:SetWidth(4)
		row.cur:SetPoint("TOPLEFT", 0, -2)
		row.cur:SetPoint("BOTTOMLEFT", 0, 2)
		MM.Theme.RegisterRule(row.cur, "strong")

		row.num = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.num:SetPoint("LEFT", 6, 0)
		-- Wide enough for THREE digits and the full stop. A hundred-stop route
		-- is normal and 22px truncated every one of them past 99 to "1...",
		-- so the end of a long plan lost its numbering entirely.
		row.num:SetWidth(30)
		row.num:SetJustifyH("RIGHT")
		MM.Theme.RegisterText(row.num, "primary")

		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(32, 32)
		row.icon:SetPoint("LEFT", 40, 0)
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		MM.Theme.RoundIcon(row, row.icon)

		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -1)
		-- 66px was three buttons wide. With the arrows gone only the
		-- [-] remains, so the name gets 20px back -- these truncate.
		row.name:SetPoint("RIGHT", -46, 0)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)
		MM.Theme.RegisterText(row.name, "primary")

		row.est = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.est:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -2)
		row.est:SetPoint("RIGHT", -46, 0)
		row.est:SetJustifyH("LEFT")
		row.est:SetTextColor(0.4, 0.8, 1)
		row.est:SetWordWrap(false)
		MM.Theme.RegisterText(row.est, "info")

		-- The SAME control the missing list uses, so one gesture means one
		-- thing everywhere: [+] puts a mount on the plan, [-] takes it off.
		-- This was an [x] close glyph, which reads as "dismiss this row"
		-- rather than "take this off the plan".
		row.remove = UI.MakeRowAction(row)
		row.remove:SetPoint("RIGHT", -6, 0)
		row.remove:mmSet(true)
		row.remove.mmTooltip = "Remove from plan"
		-- Same shape as the left pane. This one works today, which is exactly
		-- why it should not be left resting on which frame won a hit test.
		row.mmToggle = function(self)
			local e = self.entry
			if not (e and e.spellID) then return end
			MM.Planner:Remove(e.spellID)
		end
		row.remove:SetScript("OnClick", function(self) row.mmToggle(self:GetParent()) end)

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
		row:SetScript("OnClick", function(self, mouse)
			if UI.CursorOver(self.remove) then return self.mmToggle(self) end
			UI.RowClick(self.entry, mouse)
		end)
		MM.Theme.Register(row, "row", false)
	end

	row.entry = entry
	-- ONE NUMBER PER STOP, not per mount.
	--
	-- Five mounts sharing the Dazar'alor trip all carried "1.", so the column
	-- read "1. 1. 1. 1. 1." and looked like a counter that had stuck. The
	-- number means TRIPS, and repeating it said the opposite of what it meant.
	-- Only the first row of a group is numbered; the rest sit blank beneath it,
	-- which is what "these are one stop" looks like.
	row.num:SetText(data.sameStopAsPrevious and "" or (index .. "."))
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
	-- THE TIER LABEL IS GONE FROM THE ROW.
	--
	-- "[Dungeon / legacy raid]" opened every line, said the same thing a
	-- hundred times, and was wrong on the Island Expedition rows -- those share
	-- a tier with dungeons and inherited its name. The route order already
	-- expresses the ranking, and the estimate that follows is what the line is
	-- for. It is still used to spot a detail that merely restates it.
	local tierLabel = MM.Planner.TIER_LABEL[tier] or "?"
	if U.Restates(detail, tierLabel) then detail = (entry.rec and entry.rec.source) or "" end
	local est = detail
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
	local accent = MM.Theme.Color("accent")
	local primary = MM.Theme.Color("text")
	local numberColor = isCurrent and accent or primary
	row.num:SetTextColor(numberColor[1], numberColor[2], numberColor[3])
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

	-- The two halves are different semantic regions, not merely coordinates on
	-- one black canvas. Texture regions stay below every FontString/ScrollBox,
	-- while Theme maps them to Vaultloom stone, Blizzard pane tint, or ElvUI
	-- flat surfaces. This also gives a short list a deliberate resting surface
	-- instead of the large accidental black void visible in the first pass.
	local leftSurface = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
	leftSurface:SetPoint("TOPLEFT", 4, -62)
	leftSurface:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT", 438, 4)
	MM.Theme.RegisterSurface(leftSurface, "sidebar")
	local rightSurface = panel:CreateTexture(nil, "BACKGROUND", nil, 1)
	rightSurface:SetPoint("TOPLEFT", 464, -62)
	rightSurface:SetPoint("BOTTOMRIGHT", -24, 4)
	MM.Theme.RegisterSurface(rightSurface, "content")

	-- Each pane is a real visual region, not merely a differently coloured half
	-- of the same canvas. Hairline edges provide the nested structure seen in
	-- polished Warcraft interfaces without building heavy boxes around every
	-- control. Because the rules are semantic, ElvUI and Blizzard inherit the
	-- same hierarchy with their own accent colour.
	panel.mmLeftPaneRules = MM.Theme.BorderSurface(panel, leftSurface, "subtle")
	panel.mmRightPaneRules = MM.Theme.BorderSurface(panel, rightSurface, "subtle")

	-- toolbar band behind the button row
	local band = panel:CreateTexture(nil, "BORDER")
	band:SetPoint("TOPLEFT")
	band:SetPoint("TOPRIGHT")
	band:SetHeight(30)
	MM.Theme.RegisterSurface(band, "utility")

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

	-- THE ROUTE ARRIVES LATER THAN THE REQUEST.
	--
	-- Build is chunked: it returns with the work still in flight, so the plan
	-- pane painted from a route that had not been built yet. After Clear Plan
	-- that route was EMPTY, so Auto-Plan All moved every mount out of the left
	-- list and then showed "your farm plan is empty" -- with 286 goals in the
	-- plan. Changing tabs appeared to fix it only because that re-rendered
	-- after the build had finished.
	--
	-- The router says when it lands. Repainting then is what makes an async
	-- build invisible instead of confusing.
	--
	-- TWO EVENTS, TWO MEANINGS. MM_ROUTE_BUILT is "a new route exists";
	-- MM_ROUTE_ADVANCED is "the current goal moved". One event used to carry
	-- both, so nothing could listen for a finished build without also being
	-- woken by every step along it.
	local repainting = false
	local function repaintForRoute()
		-- RefreshPlanner asks the router for a route, which on a cache hit is
		-- free and on a miss starts a build that lands here again. The guard
		-- makes that at most one repaint deep rather than a chain of them.
		if repainting then return end
		if not (panel:IsShown() and UI.RefreshPlanner) then return end
		repainting = true
		local ok, err = pcall(UI.RefreshPlanner)
		repainting = false
		if not ok then error(err, 0) end
	end
	MM:On("MM_ROUTE_BUILT", repaintForRoute)
	MM:On("MM_ROUTE_ADVANCED", repaintForRoute)

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
	MM.Theme.RegisterText(leftLabel, "accent")

	-- Right-aligned to the end of its own column rather than butted against the
	-- label. Anchored to the label's RIGHT edge, its position depended on the
	-- label's text width, so it read as shoved in: it had no relationship to
	-- the column it filters. Aligning it to the column edge gives it a margin
	-- on both sides and lets the header breathe.
	local missingSearch = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
	missingSearch:SetSize(210, 20)
	missingSearch:SetPoint("RIGHT", leftHeader, "RIGHT", 0, 0)
	missingSearch:SetAutoFocus(false)
	MM.Theme.Register(missingSearch, "editbox")
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
	MM.Theme.RegisterText(panel.missingEmpty, "muted")
	panel.missingEmpty:Hide()

	-- TWO OPPOSITE CORNERS, LIKE EVERY OTHER LIST IN THE ADDON.
	--
	-- This is why [+] worked in the Collection tab and in the plan pane and did
	-- nothing here. Both of those anchor TOPLEFT and BOTTOMRIGHT. This one
	-- anchored TOPLEFT and BOTTOMLEFT -- both on the SAME edge -- and took its
	-- horizontal extent from SetWidth instead.
	--
	-- A WowScrollBoxList lays its element frames out against the width it
	-- derives from its own anchors. With two left-edge anchors there is no
	-- anchored width to derive, so the rows are sized against something other
	-- than the 430 the box was told to be. The row still DRAWS correctly --
	-- its contents are anchored to the row, so they follow it wherever it is --
	-- but the action button hangs off the row's RIGHT edge, which is now
	-- somewhere other than where the glyph appears, and the click lands where
	-- the button is not.
	--
	-- Four passes over the handlers found nothing because the handlers were
	-- never wrong. The geometry was, in the one pane that described itself
	-- differently from the two that work.
	--
	-- Same rectangle, stated the same way as its neighbours: left 4, right 434,
	-- top -66, bottom 6. Full height on this side -- only the plan column gives
	-- up space for the action strip below it.
	missingBox = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
	missingBox:SetPoint("TOPLEFT", 4, -66)
	missingBox:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT", 434, 6)

	local missingBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
	missingBar:SetPoint("TOPLEFT", missingBox, "TOPRIGHT", 4, 0)
	missingBar:SetPoint("BOTTOMLEFT", missingBox, "BOTTOMRIGHT", 4, 0)
	MM.Theme.Register(missingBar, "scrollbar", false)

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
	MM.Theme.RegisterText(rightLabel, "accent")

	panel.planEmpty = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	panel.planEmpty:SetPoint("TOPLEFT", 540, -140)
	panel.planEmpty:SetWidth(360)
	-- There is no Optimize button any more -- the plan charts itself the moment
	-- you change it -- and this line was still telling people to press one.
	panel.planEmpty:SetText("Your farm plan is empty.\n\nAdd mounts with the [+] buttons,"
		.. " or use Auto-Plan / Add 10 Easiest. The plan charts itself as soon as"
		.. " you add something; then press Start Route.")
	panel.planEmpty:SetTextColor(0.55, 0.55, 0.6)
	MM.Theme.RegisterText(panel.planEmpty, "muted")
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
	MM.Theme.RegisterSurface(notice.bg, "card")

	notice.head = notice:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	notice.head:SetPoint("CENTER", 0, 22)
	notice.head:SetTextColor(1, 0.82, 0.2)
	MM.Theme.RegisterText(notice.head, "accent")

	notice.body = notice:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	notice.body:SetPoint("TOP", notice.head, "BOTTOM", 0, -14)
	notice.body:SetWidth(380)
	notice.body:SetJustifyH("CENTER")
	notice.body:SetTextColor(0.75, 0.75, 0.8)
	MM.Theme.RegisterText(notice.body, "muted")
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
	routeButton.mmStartWidth, routeButton.mmStartHeight = 204, 32
	routeButton.mmStopWidth, routeButton.mmStopHeight = 168, 28
	routeButton:SetSize(routeButton.mmStartWidth, routeButton.mmStartHeight)
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
			local muted = MM.Theme.Color("muted")
			if active then fs:SetTextColor(muted[1], muted[2], muted[3])
			else fs:SetTextColor(r, g, b) end
		end
	end

	function routeButton:SetRouteState(active)
		self:SetText(active and "Stop Route" or "Start Route")
		self:SetSize(
			active and self.mmStopWidth or self.mmStartWidth,
			active and self.mmStopHeight or self.mmStartHeight)
		-- The edge marks the PRIMARY action. Once a route is running, stopping
		-- is not what the player is being encouraged to do, so it comes off.
		for _, e in ipairs(self.mmEdges or {}) do e:SetShown(not active) end
		self:ApplyAccent(active)
	end
	routeButton:ApplyAccent()
	MM:On("MM_THEME_CHANGED", function()
		if routeButton and routeButton.ApplyAccent then routeButton:ApplyAccent() end
		if panel:IsShown() and UI.RefreshPlanner then UI.RefreshPlanner() end
	end)
	routeButton:SetRouteState(MM.cdb and MM.cdb.routeActive)

	-- bounded on BOTH sides so it truncates instead of overlapping the label
	summaryText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	summaryText:SetPoint("LEFT", rightLabel, "RIGHT", 14, 0)
	summaryText:SetPoint("RIGHT", rightHeader, "RIGHT", 0, 0)
	summaryText:SetJustifyH("RIGHT")
	summaryText:SetWordWrap(false)
	MM.Theme.RegisterText(summaryText, "muted")

	-- THE SUMMARY TRUNCATES, SO IT HAS TO BE READABLE SOME OTHER WAY.
	--
	-- "2d 8h · ~22.5 mounts (30d 15h to finish all) · 132 mounts · 101 sto..."
	-- is the densest line in the addon and the first thing to lose its tail
	-- when the window is anything but wide. Wrapping it would cost a row of
	-- height on every plan; a tooltip costs nothing until it is wanted.
	--
	-- A FontString cannot take mouse input, so an invisible frame sits over it.
	local summaryHit = CreateFrame("Frame", nil, panel)
	summaryHit:SetPoint("TOPLEFT", summaryText, "TOPLEFT", 0, 2)
	summaryHit:SetPoint("BOTTOMRIGHT", summaryText, "BOTTOMRIGHT", 0, -2)
	summaryHit:EnableMouse(true)
	summaryHit:SetScript("OnEnter", function(self)
		if not (summaryText.mmLines and #summaryText.mmLines > 0) then return end
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText("This plan", 1, 0.82, 0.2)
		for _, pair in ipairs(summaryText.mmLines or {}) do
			GameTooltip:AddDoubleLine(pair[1], pair[2],
				0.75, 0.75, 0.8, 1, 1, 1)
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Times are what it takes YOU where we have watched,"
			.. " and a pessimistic guess where we have not -- so the order is"
			.. " sound even when the total is a ceiling.", 0.6, 0.6, 0.65, true)
		GameTooltip:Show()
	end)
	summaryHit:SetScript("OnLeave", function() GameTooltip:Hide() end)

	planBox = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
	planBox:SetPoint("TOPLEFT", 470, -66)
	planBox:SetPoint("BOTTOMRIGHT", -26, 48)

	local planBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
	planBar:SetPoint("TOPLEFT", planBox, "TOPRIGHT", 6, 0)
	planBar:SetPoint("BOTTOMLEFT", planBox, "BOTTOMRIGHT", 6, 0)
	MM.Theme.Register(planBar, "scrollbar", false)

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
	-- Keep the primary action compact and centered. The stop state is deliberately
	-- quieter than the start state; a wide disabled-looking footer made stopping
	-- the route more visually important than the route being followed.
	routeButton:ClearAllPoints()
	routeButton:SetPoint("BOTTOM", planBox, "BOTTOM", 0, -39)
end

-- ONE REFRESH PER FRAME, AND NEVER INSIDE ANOTHER.
--
-- Auto-Plan All adds 286 mounts and each one fires MM_PLAN_CHANGED. Every
-- event refreshed the whole window, which builds the route, which fires
-- MM_ROUTE_ADVANCED, which refreshes again -- re-entrantly, hundreds of times,
-- each pass writing a data provider and an empty-state flag computed from a
-- different moment.
--
-- The result was a window arguing with itself: rows in the missing list with
-- "everything here is already on your plan" drawn over them, and a plan pane
-- that was blank while its own header said 132 mounts across 101 stops. Both
-- halves were correct when they were written and stale by the time they were
-- seen. A reload fixed it because that ran exactly one refresh.
--
-- Collapsing a burst into a single pass on the next frame makes the whole
-- class impossible: whatever the state settles to is what gets drawn, once.
local refreshQueued, refreshing
local function doRefresh()
	refreshQueued = nil
	if refreshing then return end
	refreshing = true
	local ok, err = pcall(UI.RefreshPlannerNow)
	refreshing = nil
	if not ok and MM.Print then
		MM:Print("|cffff5555planner refresh failed|r -- %s", tostring(err):sub(-140))
	end
end

function UI.RefreshPlanner()
	if refreshQueued then return end
	refreshQueued = true
	if C_Timer and C_Timer.After then
		C_Timer.After(0, doRefresh)
	else
		doRefresh()
	end
end

-- Exposed so the check can assert the tooltip actually carries what the label
-- stopped saying, rather than trusting that it does.
function UI.SummaryLines()
	return summaryText and summaryText.mmLines
end

-- THE TIME ROWS, FROM A TOTALS TABLE AND NOTHING ELSE.
--
-- Extracted so the arithmetic can be checked against known numbers without a
-- window, a route, or a build. The travel row was wrong for exactly as long as
-- the only way to see it was to open the planner and read it.
--
-- "Of which travel" is `travelMinutes`, which Measure produces by walking the
-- route and totalling the legs. It used to be `minutes - routeMinutes`, and
-- those two totals do not differ by travel -- both contain all of it. `minutes`
-- counts every attempt a mount is expected to need; `routeMinutes` counts
-- travel plus ONE visit each. The remainder is the grind, so a plan of long
-- farms reported nearly all its time as flying to someone using that figure to
-- decide whether an evening was worth it.
--
-- That subtraction keeps its own row under the name it always deserved. Both
-- totals it sits between are already on screen, so the gap between them was
-- visible and unexplained.
function UI.PlanTimeRows(t)
	local rows = {}
	local function add(k, v) rows[#rows + 1] = { k, v } end
	if not (t and (t.stops or 0) > 0) then return rows end
	add("On the route", U.FormatSeconds((t.routeMinutes or t.minutes or 0) * 60))
	if (t.travelMinutes or 0) > 1 then
		add("Of which travel", U.FormatSeconds(t.travelMinutes * 60))
	end
	local farming = (t.minutes or 0) - (t.routeMinutes or t.minutes or 0)
	if farming > 1 then
		add("Repeated farming", U.FormatSeconds(farming * 60))
	end
	add("Expected mounts", ("%.1f"):format(t.mounts or 0))
	add("To finish everything", U.FormatSeconds((t.minutes or 0) * 60))
	return rows
end

function UI.RefreshPlannerNow()
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

	-- Ordered as the route would run it.
	--
	-- ASYNCHRONOUS ON PURPOSE, and the read below is deliberately of whatever
	-- route is currently complete: a repaint must never freeze the window to
	-- chart a plan. While a build is in flight this pane shows the previous
	-- complete route, and the empty-state text below says "charting" rather
	-- than "empty" so a route that has not landed yet cannot read as a plan
	-- that lost its goals. MM_ROUTE_BUILT brings us back when it lands.
	MM.Router:Build()   -- audit-allow: the stale read is the intended behaviour here
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
		for mi, m in ipairs(step.members or { step }) do
			tinsert(items, { entry = m.entry, index = i,
				opportunistic = step.opportunistic, noLocation = step.noLocation,
				-- Only the first mount of a shared stop carries the number.
				sameStopAsPrevious = mi > 1,
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
	if planBox.emptyText then
		planBox.emptyText:SetShown(#items == 0)
		-- "Empty" and "not charted yet" look identical and mean opposite
		-- things. Saying the wrong one over a plan of 286 goals is how a
		-- working addon reads as a broken one.
		if #items == 0 and planBox.emptyText.SetText then
			local planned = MM.cdb and MM.cdb.plan and #MM.cdb.plan or 0
			if planned > 0 and MM.Router.IsBuilding and MM.Router.IsBuilding() then
				planBox.emptyText:SetText(
					("Charting %d mounts into a route\226\128\166"):format(planned))
			elseif planned > 0 then
				planBox.emptyText:SetText("Nothing in your plan can be routed from here"
					.. " right now.\n\nSee /mm whynot for what is holding each one back.")
			else
				planBox.emptyText:SetText("Your farm plan is empty.\n\nAdd mounts with the"
					.. " [+] buttons, or use Auto-Plan / Add 10 Easiest. The plan charts"
					.. " itself as soon as you add something; then press Start Route.")
			end
		end
	end

	local zoneCount = 0
	for _ in pairs(zones) do zoneCount = zoneCount + 1 end
	local goalCount = 0
	-- Gathered in the walk that was already happening. A second pass over a
	-- hundred stops to fill a tooltip nobody may open is work for nothing.
	local firstStop, sharedStops, urgentCount = nil, 0, 0
	for i, step in ipairs(MM.Router.route) do
		if limit and i > limit then break end
		local members = step.members or { step }
		goalCount = goalCount + #members
		if #members > 1 then sharedStops = sharedStops + 1 end
		if not firstStop then
			local m = members[1]
			firstStop = (m and m.entry and m.entry.name)
				or (step.entry and step.entry.name)
		end
		for _, m in ipairs(members) do
			local e = m.entry or m
			-- EXPIRING or LOCKOUT only. There is no URGENCY.NONE -- the tiers
			-- are EXPIRING, LOCKOUT, ANYTIME and BLOCKED -- so testing against
			-- one would have counted every goal as urgent and made the line
			-- meaningless in the most confident possible way.
			local u = e and MM.Planner.Urgency and select(1, MM.Planner.Urgency(e))
			if u == MM.Planner.URGENCY.EXPIRING or u == MM.Planner.URGENCY.LOCKOUT then
				urgentCount = urgentCount + 1
			end
		end
	end
	-- "153 stops" answers a question nobody asked. What a collector wants to
	-- know before committing an evening is how long it takes and whether they
	-- end it with a mount, so lead with time and expectation and keep the counts
	-- as supporting detail.
	-- THE LABEL ANSWERS ONE QUESTION. THE TOOLTIP ANSWERS THE REST.
	--
	-- "how long, and do I end it with a mount" is what a collector is deciding
	-- before committing an evening. Everything else -- stops, zones, what is
	-- held back and why -- is supporting detail that was making the line long
	-- enough to truncate, which cost the two facts that mattered.
	local t = MM.Router.totals
	local stopCount = limit or #MM.Router.route
	if t and t.stops > 0 then
		local mountText = t.mounts >= 1
			and ("~%.1f mounts"):format(t.mounts)
			or ("~%d%% chance of a mount"):format(
				math.min(99, math.floor(t.mounts * 100 + 0.5)))
		summaryText:SetText(("|cffffd84d%s · %s|r"):format(
			U.FormatSeconds((t.routeMinutes or t.minutes) * 60), mountText))
	else
		summaryText:SetText("")
	end

	-- Built as label/value pairs rather than one string split on a separator:
	-- the tooltip can then align them, and a value containing the separator
	-- cannot break the layout.
	local lines = {}
	local function add(k, v) lines[#lines + 1] = { k, v } end
	if t and t.stops > 0 then
		for _, row in ipairs(UI.PlanTimeRows(t)) do lines[#lines + 1] = row end
	end
	add("Mounts on this plan", tostring(goalCount))
	add("Stops", tostring(stopCount))
	add("Zones", tostring(zoneCount))
	if firstStop then add("Starts with", firstStop) end
	if sharedStops > 0 then
		add("Stops with more than one mount", tostring(sharedStops))
	end
	if urgentCount > 0 then
		-- The one number that changes what you do TONIGHT rather than
		-- eventually: work whose window closes before the next reset.
		add("Resets soon \226\128\148 do these first", tostring(urgentCount))
	end
	if hiddenBySession > 0 then
		add("Beyond this session", tostring(hiddenBySession))
	end
	if offRoute > 0 then add("No location to route to", tostring(offRoute)) end
	if waiting > 0 then add("Waiting on something", tostring(waiting)) end
	summaryText.mmLines = lines
	routeButton:SetRouteState(MM.cdb.routeActive)
	-- NOTHING TO ROUTE, NOTHING TO START.
	--
	-- Start Route stayed pressable with an empty plan, which offered to walk a
	-- route that does not exist. A control that cannot do anything should say
	-- so before it is pressed rather than after.
	--
	-- Only when the route is STOPPED: an active route must always be stoppable,
	-- including in the moment after the plan empties underneath it.
	if not MM.cdb.routeActive then
		if #items > 0 then
			routeButton:Enable()
			routeButton.mmTooltip = nil
		else
			routeButton:Disable()
			routeButton.mmTooltip = "Add some mounts to your plan first."
		end
	else
		routeButton:Enable()
	end
end

MM:On("MM_ROUTE_STARTED", function() if routeButton then routeButton:SetRouteState(true) end end)
MM:On("MM_ROUTE_STOPPED", function() if routeButton then routeButton:SetRouteState(false) end end)

------------------------------------------------------------
-- What is actually on screen in the left pane
------------------------------------------------------------
-- Written because [+] in this pane does nothing and three rounds of reading the
-- code did not explain it. The three call sites are identical -- same helper,
-- same anchor, same handler, same Add -- and the refresh path is correct, so
-- reasoning about the source has run out of road.
--
-- Nothing here is a fix or a theory. It reports what the live frames ARE:
-- levels, geometry, whether the scripts exist, and what the click would do if
-- it arrived. If the button is behind the row, the numbers say so. If the entry
-- has no spellID, Add cannot key a plan entry on it and the numbers say that
-- instead. Either way the next answer comes from a measurement.
function UI.InspectMissingPane()
	if not missingBox then return nil, "planner has not been built this session" end
	local out = { rows = {} }

	out.boxWidth = missingBox.GetWidth and math.floor(missingBox:GetWidth() or 0)
	out.boxLevel = missingBox.GetFrameLevel and missingBox:GetFrameLevel()

	local frames = {}
	if missingBox.GetFrames then
		local ok, f = pcall(missingBox.GetFrames, missingBox)
		if ok and type(f) == "table" then frames = f end
	end
	out.visibleRows = #frames

	for i = 1, math.min(#frames, 3) do
		local row = frames[i]
		local b = row and row.plus
		local e = row and row.entry
		local r = {}
		r.name = e and e.name or "?"
		r.spellID = e and e.spellID or nil
		r.rowLevel = row.GetFrameLevel and row:GetFrameLevel()
		r.rowWidth = row.GetWidth and math.floor(row:GetWidth() or 0)
		r.rowMouse = row.IsMouseEnabled and row:IsMouseEnabled()
		if b then
			-- A FontString now, not a Button: no level, no mouse, no OnClick of
			-- its own. What matters is where its rect is, because that rect IS
			-- the region that responds.
			r.btnShown = b.IsShown and b:IsShown()
			r.btnAlpha = b.GetAlpha and math.floor((b:GetAlpha() or 0) * 100)
			r.btnW = b.GetWidth and math.floor(b:GetWidth() or 0)
			r.btnH = b.GetHeight and math.floor(b:GetHeight() or 0)
			r.hasClick = row.GetScript and row:GetScript("OnMouseDown") ~= nil
			-- Where the button sits INSIDE its row. A negative left or a right
			-- edge past the row's width means it is anchored off the row.
			local okL, bl = pcall(b.GetLeft, b)
			local okR, br = pcall(b.GetRight, b)
			local okRL, rl = pcall(row.GetLeft, row)
			local okRR, rr = pcall(row.GetRight, row)
			if okL and okR and okRL and okRR and bl and br and rl and rr then
				r.insetLeft = math.floor(bl - rl)
				r.insetRight = math.floor(rr - br)
			end
		else
			r.btnMissing = true
		end
		-- What the click would DO, evaluated the same way the handler does.
		if e then
			r.inPlan = MM.Planner:InPlan(e.spellID) ~= nil
			r.addWouldWork = (e.spellID ~= nil) and not r.inPlan
		end
		out.rows[i] = r
	end
	return out
end
