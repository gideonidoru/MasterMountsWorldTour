-- Master Mounts Collection tab: the full journal-style audit — every mount,
-- collected and missing, with live status, filters, and search.
local _, MM = ...
local U = MM.Util
local UI = MM.UI

local filters = { missingOnly = false, availableOnly = false, search = "",
	expansion = nil, category = nil }

local scrollBox, countText

------------------------------------------------------------
-- Row
------------------------------------------------------------
local function initRow(row, entry)
	if not row.built then
		row.built = true
		row:SetHeight(46)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(1, 1, 1, 0.03)

		row.hl = row:CreateTexture(nil, "HIGHLIGHT")
		row.hl:SetAllPoints()
		row.hl:SetColorTexture(1, 0.82, 0.2, 0.08)

		-- status-colored edge bar
		row.edge = row:CreateTexture(nil, "ARTWORK")
		row.edge:SetWidth(4)
		row.edge:SetPoint("TOPLEFT", 0, -2)
		row.edge:SetPoint("BOTTOMLEFT", 0, 2)

		-- hairline separator between rows
		row.sep = row:CreateTexture(nil, "BORDER")
		row.sep:SetHeight(1)
		row.sep:SetPoint("BOTTOMLEFT", 8, 0)
		row.sep:SetPoint("BOTTOMRIGHT", -8, 0)
		row.sep:SetColorTexture(1, 1, 1, 0.05)

		-- dark plate behind the icon
		row.iconPlate = row:CreateTexture(nil, "BORDER")
		row.iconPlate:SetColorTexture(0, 0, 0, 0.55)

		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(32, 32)
		row.icon:SetPoint("LEFT", 10, 0)
		row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
		row.iconPlate:SetPoint("TOPLEFT", row.icon, -2, 2)
		row.iconPlate:SetPoint("BOTTOMRIGHT", row.icon, 2, -2)

		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 8, -2)
		row.name:SetJustifyH("LEFT")

		row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.sub:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 8, 2)
		row.sub:SetPoint("RIGHT", row, "RIGHT", -180, 0)
		row.sub:SetJustifyH("LEFT")
		row.sub:SetTextColor(0.65, 0.65, 0.65)
		row.sub:SetWordWrap(false)

		row.add = UI.MakeRowAction(row)
		row.add:SetPoint("RIGHT", -10, 0)
		row.add:SetScript("OnClick", function(self)
			MM.UI.TogglePlan(self:GetParent().entry)
		end)

		row.status = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		row.status:SetPoint("RIGHT", -42, 6)
		row.status:SetJustifyH("RIGHT")

		row.planned = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		row.planned:SetPoint("RIGHT", -42, -10)
		row.planned:SetTextColor(1, 0.82, 0.2)

		row:SetScript("OnEnter", function(self) UI.ShowMountTooltip(self, self.entry) end)
		row:SetScript("OnLeave", function() GameTooltip:Hide() end)
		row:SetScript("OnClick", function(self, mouse) UI.RowClick(self.entry, mouse) end)
	end

	row.entry = entry
	row.icon:SetTexture(entry.icon or 134400)
	row.icon:SetDesaturated(not entry.collected)

	if entry.collected then
		row.name:SetText(entry.name)
		row.name:SetTextColor(0.5, 0.95, 0.55)
	else
		row.name:SetText(entry.name)
		row.name:SetTextColor(1, 1, 1)
	end

	local rec = entry.rec
	local meta = ""
	if rec and rec.expansion and MM.EXPANSIONS[rec.expansion] then
		meta = "|cff8888c8" .. MM.EXPANSIONS[rec.expansion] .. " · "
			.. (MM.CATEGORY_LABEL[rec.category] or rec.category or "?") .. "|r — "
	end
	-- THE TIER TAG IS GONE.
	--
	-- "[1 Dungeon / legacy raid]" opened every row, in the brightest colour on
	-- screen, before anything worth reading. Three hundred times it said the
	-- same thing, the leading number read as a count rather than a rank, and on
	-- an Island Expedition it was simply wrong -- those share the tier with
	-- dungeons and inherited its name.
	--
	-- The order is already visible: the list IS sorted by ease, so position
	-- carries the rank. Printing it on every row spent the eye's first stop on
	-- something it could see for free. The expansion and source breadcrumb that
	-- follows is the part that says where to go.
	row.sub:SetText(meta .. (rec and rec.source or ""))

	local status = MM.Availability.GetStatus(entry)
	local ignored = MM.db.ignored[entry.spellID]
	if ignored then
		row.edge:SetColorTexture(0.75, 0.2, 0.2)
		row.name:SetTextColor(0.55, 0.4, 0.4)
		row.icon:SetDesaturated(true)
	else
		row.edge:SetColorTexture(U.StatusRGB(status))
	end
	-- "Available" is said on nearly every row, in a list that is usually
	-- filtered to available things. Three hundred repetitions of the expected
	-- case buries the handful that say something -- Requirements, Locked,
	-- Rotation -- which are the only ones worth a glance.
	--
	-- So the unremarkable case is silent and the exceptions still speak. The
	-- status colour stays on the row edge either way, so nothing is lost: the
	-- edge already carries it without spending a word.
	row.status:SetText(status == "AVAILABLE" and ""
		or U.Color(status, U.STATUS_LABEL[status] or status))
	row.planned:SetText((not entry.collected and MM.Planner:InPlan(entry.spellID)) and "IN PLAN" or "")
	if entry.collected then
		row.add:Hide()
	else
		row.add:Show()
		row.add:mmSet(MM.Planner:InPlan(entry.spellID))
	end
end

------------------------------------------------------------
-- Panel
------------------------------------------------------------
function UI.BuildCollection(panel)
	-- restore persisted filter state
	local saved = MM.db and MM.db.ui or {}
	filters.missingOnly = saved.colMissingOnly or false
	filters.availableOnly = saved.colAvailableOnly or false
	filters.expansion = (saved.colExpansion ~= false) and saved.colExpansion or nil
	filters.category = saved.colCategory or nil
	filters.sort = saved.colSort or nil

	-- toolbar band behind the filter row
	local band = panel:CreateTexture(nil, "BORDER")
	band:SetPoint("TOPLEFT")
	band:SetPoint("TOPRIGHT")
	band:SetHeight(30)
	band:SetColorTexture(0, 0, 0, 0.35)

	local search = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
	search:SetSize(180, 22)
	search:SetPoint("TOPLEFT", 8, -4)
	search:SetAutoFocus(false)
	search:HookScript("OnTextChanged", function(self)
		filters.search = self:GetText() or ""
		UI.RefreshCollection()
	end)

	local expValues, expLabels = {}, {}
	for i = 0, MM.MAX_EXPANSION do
		tinsert(expValues, i)
		expLabels[i] = MM.EXPANSIONS[i]
	end
	local expBtn = UI.MakePicker(panel, "Expansion", expValues, expLabels, function(v)
		filters.expansion = v
		MM.db.ui.colExpansion = v or false
		UI.RefreshCollection()
	end, filters.expansion, "All expansions", 170)
	expBtn:SetPoint("LEFT", search, "RIGHT", 12, 0)

	local catValues = { "GROUP_DROPS", "GROUP_BUY", "GROUP_ACH" }
	local catLabels = {}
	for k, v in pairs(MM.CATEGORY_GROUP_LABEL) do catLabels[k] = v end
	for _, c in ipairs(MM.CATEGORIES) do
		tinsert(catValues, c.key)
		catLabels[c.key] = c.label
	end
	local catBtn = UI.MakePicker(panel, "Type", catValues, catLabels, function(v)
		filters.category = v
		MM.db.ui.colCategory = v or false
		UI.RefreshCollection()
	end, filters.category, "All types", 140)
	catBtn:SetPoint("LEFT", expBtn, "RIGHT", 6, 0)

	local sortBtn = UI.MakePicker(panel, "Sort", { "EASE", "STATUS", "EXPANSION" },
		{ EASE = "Sort by easiest", STATUS = "Sort by status",
		  EXPANSION = "Sort by expansion" }, function(v)
			filters.sort = v
			MM.db.ui.colSort = v or false
			UI.RefreshCollection()
		end, filters.sort, "Sort by name", 150)
	sortBtn:SetPoint("LEFT", catBtn, "RIGHT", 6, 0)

	local missing = UI.MakeCheck(panel, "Missing only", function(v)
		filters.missingOnly = v
		MM.db.ui.colMissingOnly = v
		UI.RefreshCollection()
	end)
	missing:SetPoint("LEFT", sortBtn, "RIGHT", 8, 0)
	missing:SetChecked(filters.missingOnly)

	local avail = UI.MakeCheck(panel, "Available now", function(v)
		filters.availableOnly = v
		MM.db.ui.colAvailableOnly = v
		UI.RefreshCollection()
	end)
	avail:SetPoint("LEFT", missing.labelText, "RIGHT", 14, -1)
	avail:SetChecked(filters.availableOnly)

	-- lives in the frame's bottom bar, opposite the tabs — never overlaps filters
	countText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	countText:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, -20)

	panel.emptyText = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	panel.emptyText:SetPoint("CENTER", 0, 20)
	panel.emptyText:SetText("No mounts match these filters.")
	panel.emptyText:SetTextColor(0.55, 0.55, 0.6)
	panel.emptyText:Hide()
	MM.UI.collectionEmptyText = panel.emptyText

	-- the list
	scrollBox = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
	scrollBox:SetPoint("TOPLEFT", 4, -34)
	scrollBox:SetPoint("BOTTOMRIGHT", -26, 4)

	local scrollBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
	scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 6, 0)
	scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 6, 0)

	local view = CreateScrollBoxListLinearView()
	view:SetElementExtent(46)
	view:SetElementInitializer("Button", initRow)
	ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
end

function UI.RefreshCollection()
	if not scrollBox then return end
	local items = {}
	local shown, collected = 0, 0
	local searchText = filters.search ~= "" and filters.search:lower() or nil
	for _, entry in ipairs(MM.Scanner.mounts) do
		local rec = entry.rec
		local ok = true
		if filters.missingOnly and entry.collected then ok = false end
		if ok and filters.expansion and (not rec or rec.expansion ~= filters.expansion) then ok = false end
		if ok and filters.category and not (rec and MM.CategoryMatch(filters.category, rec.category)) then ok = false end
		if ok and searchText and not entry.name:lower():find(searchText, 1, true) then ok = false end
		if ok and MM.db.hideIgnored and MM.db.ignored[entry.spellID] then ok = false end
		if ok and filters.availableOnly then
			local status = MM.Availability.GetStatus(entry)
			if status ~= "AVAILABLE" then ok = false end
		end
		if ok then
			tinsert(items, entry)
			shown = shown + 1
			if entry.collected then collected = collected + 1 end
		end
	end
	MM.Planner.SortEntries(items, filters.sort)
	scrollBox:SetDataProvider(CreateDataProvider(items), ScrollBoxConstants.RetainScrollPosition)
	if MM.UI.collectionEmptyText then MM.UI.collectionEmptyText:SetShown(shown == 0) end
	countText:SetText(("%d shown — %d collected, %d missing"):format(shown, collected, shown - collected))
end
