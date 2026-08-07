-- Master Mounts main window: Blizzard-native portrait frame with two tabs —
-- Collection and Planner — plus shared UI helpers.
local _, MM = ...
local U = MM.Util

MM.UI = MM.UI or {}
local UI = MM.UI

------------------------------------------------------------
-- Which tab a freshly-opened window lands on. 1 = Collection, 2 = Planner.
local DEFAULT_TAB = 2

-- Shared widget helpers (used by both tabs)
------------------------------------------------------------
-- Session length picker: a dropdown, not a row of buttons.
--
-- Four buttons plus a label ate a whole row and still looked like a toolbar of
-- unrelated actions. One control that states the current choice is smaller,
-- reads as a setting rather than four commands, and fits the top row beside
-- the other plan controls.
--
-- Built defensively. WowStyle1DropdownTemplate is the modern control and is
-- what this should use, but a missing template would take the whole Planner
-- tab down with it -- so a plain button that cycles the lengths stands in if
-- the template is not there. Degraded, not broken.
function UI.MakeSessionPicker(parent)
	local S = MM.Session
	-- What the control SAYS it is set to.
	--
	-- Shows the chosen length -- "45 minutes" -- not the time remaining. A
	-- countdown in a picker reads as a clock rather than as a setting, and the
	-- monitor already shows remaining time while a route runs. "No limit" is
	-- the off state, stated as a choice rather than as an absence.
	local function label()
		local st = S and S.Active and S.Active()
		if st then
			for _, len in ipairs(S.LENGTHS) do
				if len.minutes == st.minutes then return len.label end
			end
			return ("%d minutes"):format(st.minutes or 0)
		end
		return "No limit"
	end

	local ok, drop = pcall(CreateFrame, "DropdownButton", nil, parent,
		"WowStyle1DropdownTemplate")
	if ok and drop and drop.SetupMenu then
		drop:SetSize(128, 22)
		drop:SetupMenu(function(_, root)
			root:CreateTitle("How long have you got?")
			for _, len in ipairs(S.LENGTHS) do
				root:CreateButton(("%s — %s"):format(len.label, len.blurb), function()
					S.Start(len.minutes, true)  -- a setting, not a launch
				end)
			end
			-- No "End session" here. This control SETS a length, it does not
			-- start anything -- offering to end a session implies it started
			-- one, which is exactly the confusion the setOnly split existed to
			-- remove. "No limit" is the off state, and reads as a choice rather
			-- than an undo.
			root:CreateDivider()
			root:CreateButton("No limit", function() S.Stop(true) end)
		end)
		-- A DropdownButton is NOT a Button: SetText does nothing on it, which is
		-- why the toolbar kept saying "No limit" after a length was picked. The
		-- label setter is SetDefaultText; SetText is kept only as the fallback
		-- path's method.
		drop.mmSetLabel = function(self)
			local text = label()
			if self.SetDefaultText then self:SetDefaultText(text)
			elseif self.SetText then self:SetText(text) end
		end
	else
		-- Fallback: one button that cycles. Same reach, fewer affordances.
		drop = UI.MakeButton(parent, label(), 128)
		drop.mmIndex = 0
		drop:SetScript("OnClick", function(self)
			self.mmIndex = (self.mmIndex % #S.LENGTHS) + 1
			S.Start(S.LENGTHS[self.mmIndex].minutes, true)
		end)
		drop.mmSetLabel = function(self) self:SetText(label()) end
	end

	drop:mmSetLabel()
	drop.mmTooltip = "Plan for the time you actually have. "
		.. "The route is rebuilt to fit it."
	MM:On("MM_SESSION_CHANGED", function()
		if drop.mmSetLabel then drop:mmSetLabel() end
	end)
	return drop
end

function UI.MakeButton(parent, text, width)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetText(text)
	b:SetSize(width or (b:GetTextWidth() + 28), 22)
	return MM.Theme.Register(b, "button")
end

function UI.MakeCheck(parent, text, onClick)
	local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	c:SetSize(24, 24)
	local label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("LEFT", c, "RIGHT", 2, 1)
	label:SetText(text)
	c.labelText = label
	c:SetScript("OnClick", function(self) onClick(self:GetChecked() and true or false) end)
	return MM.Theme.Register(c, "checkbox")
end

-- A cycling filter button: click = next value, right-click = reset to "All".
-- `initial` restores a persisted selection.
-- A real dropdown, with the same contract as MakeCycler.
--
-- The cyclers already opened a radio menu on click, but they LOOKED like
-- buttons -- "Type: All" next to a genuine dropdown for the session length --
-- so the same gesture was hidden behind two different affordances and only one
-- of them announced itself. A control that opens a list should look like a
-- list.
--
-- Falls back to the cycler when the template is missing, which keeps one code
-- path for every caller rather than each deciding what to do without it.
-- The add/remove control, drawn quietly.
--
-- This was a red UIPanelButton with a "+" or "-" in it, repeated on every
-- visible row. Three hundred red pills made the most aggressive thing on the
-- screen also the least informative -- the eye went to the buttons instead of
-- the mounts, and a "-" is a poor word for "take this off my plan".
--
-- Now it is a glyph that rests at low alpha and comes up when the pointer is
-- on its row, so the control is there when it is wanted and out of the way
-- when it is not. The row already had OnEnter and OnLeave for the tooltip, so
-- this rides on hover the row was tracking anyway.
function UI.MakeRowAction(row)
	local b = CreateFrame("Button", nil, row)
	b:SetSize(22, 22)
	b.glyph = b:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	b.glyph:SetPoint("CENTER")
	-- Quiet, not invisible. 0.22 got out of the way so thoroughly that the
	-- control had to be hunted for; the point was to stop three hundred red
	-- buttons shouting, not to hide the only thing on the row you can click.
	b:SetAlpha(0.55)
	-- STILL + AND -, NOT A CROSS.
	--
	-- A cross was tried here before and deliberately replaced: [x] reads as
	-- "dismiss this row", which is not what the control does -- it takes the
	-- mount off the plan, and the row stays. The pair stays [+] and [-] so one
	-- gesture means one thing in both panes. What was wrong was never the
	-- glyph, it was the red button around it.
	b.mmSet = function(self, inPlan)
		if inPlan then
			self.glyph:SetText("-")
			self.glyph:SetTextColor(1, 0.45, 0.4)
		else
			self.glyph:SetText("+")
			self.glyph:SetTextColor(0.45, 1, 0.5)
		end
	end
	b:SetScript("OnEnter", function(self)
		self:SetAlpha(1)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Add / remove from farm plan")
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function(self)
		self:SetAlpha(row.mmHover and 0.9 or 0.55)
		GameTooltip:Hide()
	end)
	-- Hooked, not replaced: the row's own tooltip handlers still run.
	row:HookScript("OnEnter", function()
		row.mmHover = true
		b:SetAlpha(0.9)
	end)
	row:HookScript("OnLeave", function()
		row.mmHover = false
		b:SetAlpha(0.55)
	end)
	return b
end

function UI.MakePicker(parent, prefix, values, labels, onChange, initial, allLabel, width)
	local ok, drop = pcall(CreateFrame, "DropdownButton", nil, parent,
		"WowStyle1DropdownTemplate")
	if not (ok and drop and drop.SetupMenu) then
		return UI.MakeCycler(parent, prefix, values, labels, onChange, initial, allLabel)
	end
	drop:SetSize(width or 150, 22)
	drop.mmIndex = 0
	if initial ~= nil and initial ~= false then
		for i, v in ipairs(values) do
			if v == initial then drop.mmIndex = i break end
		end
	end
	local function text()
		local v = values[drop.mmIndex]
		return prefix .. ": " .. (v and labels[v] or allLabel or "All")
	end
	-- THE VALUES HAVE TO NAME THEMSELVES.
	--
	-- SetText does nothing on a DropdownButton, and SetDefaultText only shows
	-- while nothing is selected -- once a radio is ticked the template draws
	-- that entry's text and any prefix set here is gone. Two filters side by
	-- side both read "All" and nothing said which was which, which is worse
	-- than the cyclers they replaced.
	--
	-- So the prefix lives in the VALUE: "All expansions", "All types", "Sort
	-- by easiest". The menu title still names the filter, and the closed
	-- control reads as a sentence rather than a fragment.
	drop.mmSetLabel = function(self)
		if self.SetDefaultText then self:SetDefaultText(text())
		elseif self.SetText then self:SetText(text()) end
	end
	local function select(i)
		drop.mmIndex = i
		drop:mmSetLabel()
		onChange(values[i])
	end
	drop:SetupMenu(function(_, root)
		root:CreateTitle(prefix)
		root:CreateRadio(allLabel or "All",
			function() return drop.mmIndex == 0 end,
			function() select(0) end)
		for i, v in ipairs(values) do
			root:CreateRadio(labels[v] or tostring(v),
				function() return drop.mmIndex == i end,
				function() select(i) end)
		end
	end)
	drop:mmSetLabel()
	-- The initial value is already applied by the caller's saved settings, so
	-- this only publishes it -- it must NOT be treated as a change the player
	-- just made, or opening the window would rewrite their filters.
	return drop
end

function UI.MakeCycler(parent, prefix, values, labels, onChange, initial, allLabel)
	local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	b:SetSize(150, 22)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b.index = 0 -- 0 = All
	if initial ~= nil and initial ~= false then
		for i, v in ipairs(values) do
			if v == initial then b.index = i break end
		end
	end
	local function refresh()
		local v = values[b.index]
		b:SetText(prefix .. ": " .. (v and labels[v] or allLabel or "All"))
		onChange(v)
	end
	local function select(i)
		b.index = i
		refresh()
	end
	MM.Theme.Register(b, "button")
	b:SetScript("OnClick", function(_, mouse)
		if mouse == "RightButton" then select(0) return end
		if MenuUtil and MenuUtil.CreateContextMenu then
			-- proper dropdown with radio selection
			MenuUtil.CreateContextMenu(b, function(_, root)
				root:CreateTitle(prefix)
				root:CreateRadio(allLabel or "All",
					function() return b.index == 0 end,
					function() select(0) end)
				for i, v in ipairs(values) do
					root:CreateRadio(labels[v] or tostring(v),
						function() return b.index == i end,
						function() select(i) end)
				end
			end)
		else
			-- ancient client fallback: cycle
			select(b.index >= #values and 0 or b.index + 1)
		end
	end)
	refresh()
	return b
end

-- Standard mount tooltip used by every list in the addon.
-- mode "compact" adjusts the interaction hints for the compact list.
function UI.ShowMountTooltip(owner, entry, mode)
	local rec = entry.rec
	GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
	GameTooltip:AddLine(entry.name, 1, 1, 1)

	local status, detail, condLines = MM.Availability.GetStatus(entry)
	GameTooltip:AddLine(U.Color(status, U.STATUS_LABEL[status] or status))
	-- the availability detail is often literally the source line; say it once
	if detail and not (rec and detail == rec.source) then
		GameTooltip:AddLine(detail, 0.85, 0.85, 0.85, true)
	end

	if rec then
		if rec.source then GameTooltip:AddLine(" ") GameTooltip:AddLine(rec.source, 1, 0.82, 0.4, true) end
		-- Several ways in: name the one we recommend and, just as importantly,
		-- the ones still open. A player who runs the Mythic boss and gets
		-- nothing needs to know the weekly cache is a second roll THIS week,
		-- not next -- otherwise the plan just repeats the failed attempt.
		if rec.paths and MM.Paths then
			local lines, best = MM.Paths.Describe(rec)
			if lines and #lines > 1 then
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine("Ways in:", 0.7, 0.9, 1)
				for _, line in ipairs(lines) do
					GameTooltip:AddLine(line, 0.85, 0.85, 0.85, true)
				end
				local left = MM.Paths.Remaining(rec, best)
				if #left > 0 then
					GameTooltip:AddLine(("If that does not pay, %d other route%s stays open.")
						:format(#left, #left == 1 and "" or "s"), 0.6, 0.8, 0.6, true)
				end
			end
		end
		-- how to actually REACH it (instanced zones, phased areas, unlock quests)
		if rec.access then
			GameTooltip:AddLine("Getting there: " .. rec.access, 0.4, 0.9, 1, true)
		end
		if rec.expansion and MM.EXPANSIONS[rec.expansion] then
			GameTooltip:AddLine(MM.EXPANSIONS[rec.expansion] .. " — "
				.. (MM.CATEGORY_LABEL[rec.category] or rec.category or "?"), 0.6, 0.6, 0.9)
		end
		if rec.altSources then
			for _, alt in ipairs(rec.altSources) do
				if alt.source then
					GameTooltip:AddLine("Also: " .. alt.source, 0.55, 0.85, 0.85, true)
				end
			end
		end

		condLines = condLines or select(2, MM.Conditions.EvaluateAll(rec))
		if condLines and #condLines > 0 then
			GameTooltip:AddLine(" ")
			for _, l in ipairs(condLines) do
				local r, g, b = 1, 0.35, 0.35
				if l.met == true then r, g, b = 0.35, 1, 0.45
				elseif l.met == nil then r, g, b = 0.8, 0.8, 0.8 end
				GameTooltip:AddLine(l.text, r, g, b, true)
				if l.how then
					GameTooltip:AddLine("   > " .. l.how, 0.75, 0.75, 0.55, true)
				end
			end
		end

		if not entry.collected then
			-- who else on the account can still do this
			local available, locked = MM.Lockouts.AltsFor(rec)
			if #available > 0 or #locked > 0 then
				GameTooltip:AddLine(" ")
				if #available > 0 then
					GameTooltip:AddLine("Not yet locked: " .. table.concat(available, ", "),
						0.4, 0.9, 0.5, true)
				end
				if #locked > 0 then
					GameTooltip:AddLine("Already saved: " .. table.concat(locked, ", "),
						0.7, 0.5, 0.5, true)
				end
			end

			-- Which character should do this. One explicit recommendation.
			--
			-- Requirement — We should always recommend the best character to
			-- finish/get the mount ... maybe even as an explicit
			-- recommendation. It was two partial answers before -- Alts knew
			-- reputation and quests, Crafting knew professions -- and neither
			-- looked at currency, faction or class. Worse, both stayed SILENT
			-- when the current character was the right one, so a collector
			-- could not tell "you are already on the best character" from "this
			-- addon did not consider it".
			local rec_rec = MM.Alts.Recommend and MM.Alts.Recommend(rec)
			if rec_rec then
				if rec_rec.blocked then
					GameTooltip:AddLine("|cffff4444" .. rec_rec.why .. "|r", 1, 0.3, 0.3, true)
				elseif rec_rec.isYou then
					GameTooltip:AddLine(("Best on |cff40d860this character|r%s"):format(
						rec_rec.why and (" — " .. rec_rec.why) or ""), 0.6, 0.85, 0.6, true)
				else
					GameTooltip:AddLine(("Do this on %s%s"):format(rec_rec.colored,
						rec_rec.why and (" — " .. rec_rec.why) or ""), 0.6, 0.8, 1, true)
				end
			end

			-- What a craft still needs, itemised. "4 hours" tells a collector
			-- nothing they can act on; "8 Genesis Motes short" does.
			if MM.Crafting and MM.Crafting.IsCraft(rec) then
				local frac, mats = MM.Crafting.Progress(rec)
				if frac then
					local missing = {}
					for _, m in ipairs(mats) do
						if m.short > 0 then
							local nm = m.name or (C_Item and C_Item.GetItemNameByID
								and C_Item.GetItemNameByID(m.itemID)) or ("item " .. m.itemID)
							missing[#missing + 1] = ("%d x %s"):format(m.short, nm)
						end
					end
					if #missing > 0 then
						local mins = MM.Crafting.ShortfallMinutes(rec)
						GameTooltip:AddLine(("Still needs: %s%s"):format(
							table.concat(missing, ", "),
							mins and mins > 0 and ("  (~" .. MM.Util.FormatSeconds(mins * 60)
								.. ")") or ""), 1, 0.7, 0.3, true)
					else
						GameTooltip:AddLine("You have every reagent — go craft it.",
							0.4, 0.9, 0.4, true)
					end
				else
					GameTooltip:AddLine("Reagents unknown — open the profession "
						.. "window once to record them.", 0.7, 0.7, 0.7, true)
				end
			end

			-- Two things the planner now knows that a collector cannot work out
			-- by looking: how many weeks a capped currency really takes, and how
			-- many criteria are actually left. Both are the difference between
			-- a number and an answer.
			for _, cond in ipairs(rec.conditions or {}) do
				if cond.type == "CURRENCY" then
					local weeks, perWeek, remaining =
						MM.Conditions.CurrencyWeeks and MM.Conditions.CurrencyWeeks(cond)
					if weeks and weeks > 0 then
						GameTooltip:AddLine(("%s: %s more at %s/week — %d week%s, "
							.. "whatever you do"):format(cond.name or "Currency",
							MM.Util.Comma(remaining), MM.Util.Comma(perWeek),
							weeks, weeks == 1 and "" or "s"), 1, 0.7, 0.3, true)
					end
				elseif cond.type == "ACHIEVEMENT" then
					local left, total = MM.Conditions.AchievementCriteriaLeft
						and MM.Conditions.AchievementCriteriaLeft(cond)
					if left and total and total > 0 and left > 0 then
						GameTooltip:AddLine(("%s: %d of %d criteria left"):format(
							cond.name or "Achievement", left, total), 0.8, 0.8, 1, true)
					end
				end
			end

			local rarityText = MM.Rarity.Text(entry.mountID)
			if rarityText then GameTooltip:AddLine(rarityText, 1, 1, 1) end

			-- Progress toward the thing, BEFORE the ranking: "you have 3 of 5
			-- tokens" is what a collector wants first and the ranking is context
			-- for it. Suppressed when it only restates the source -- an exact
			-- match was already skipped, but "Achievement: Glory of the Uldir
			-- Raider" against a source of "Reward from the achievement Glory of
			-- the Uldir Raider" is the same sentence twice and slipped through.
			local est = MM.Planner:EstimateLine(entry)
			if est and rec.source and U.Restates(est, rec.source) then est = nil end
			local tries = MM.Attempts.Get(entry.spellID)
			if est or (tries and tries > 0) then
				GameTooltip:AddLine(" ")
				if est then GameTooltip:AddLine(est, 0.4, 0.85, 1, true) end
				if tries and tries > 0 then
					-- Says BOTH things: you have been unlucky, and that buys you
					-- nothing. A collector who believes in a pity timer that
					-- does not exist makes worse decisions than one who knows.
					GameTooltip:AddLine(MM.Attempts.Line(rec, entry.spellID)
						or ("You have tried this %d time%s"):format(
							tries, tries == 1 and "" or "s"), 1, 0.6, 0.2, true)
				end
			end

			-- Why it ranks where it does. Four lines, no repetition of anything
			-- above: the tier label, what promoted it, what it costs, what it
			-- pays. `reason` from Rank is deliberately NOT printed -- it says the
			-- same thing as the tier label in different words.
			GameTooltip:AddLine(" ")
			for _, line in ipairs(MM.Planner.Explain(entry)) do
				GameTooltip:AddLine((line.indent and "   " or "") .. line.text,
					line.r, line.g, line.b, true)
			end
		end
		if rec.notes then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(rec.notes, 0.7, 0.7, 0.7, true)
		end
	end

	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Left-click: view in the Mount Journal", 0.6, 0.8, 1)
	if mode == "compact" then
		GameTooltip:AddLine("[x] button: remove from your farm plan", 0.5, 0.9, 0.5)
	elseif not entry.collected then
		GameTooltip:AddLine("[+] button: add/remove from your farm plan", 0.5, 0.9, 0.5)
	end
	GameTooltip:AddLine("Right-click: Wowhead page (read the comments!)", 0.5, 0.7, 1)
	if not entry.collected then
		GameTooltip:AddLine(MM.db.ignored[entry.spellID]
			and "Ctrl-click: stop ignoring this mount"
			or "Ctrl-click: ignore this mount", 0.8, 0.5, 0.5)
	end
	GameTooltip:Show()
end

------------------------------------------------------------
-- Main frame
------------------------------------------------------------
local frame

local function buildMain()
	if frame then return frame end

	local ok
	ok, frame = pcall(CreateFrame, "Frame", "MasterMountsFrame", UIParent, "ButtonFrameTemplate")
	if not ok or not frame then
		frame = CreateFrame("Frame", "MasterMountsFrame", UIParent, "BasicFrameTemplateWithInset")
	end
	frame:SetSize(1000, 640)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:SetClampedToScreen(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
	frame:SetToplevel(true)

	pcall(function() frame:SetTitle("Master Mounts") end)
	if frame.TitleText then pcall(frame.TitleText.SetText, frame.TitleText, "Master Mounts") end

	-- Portrait: the API differs across client generations; try them all.
	local PORTRAIT = MM.MEDIA .. "icon"
	local portraitSet = false
	if frame.SetPortraitToAsset then
		portraitSet = pcall(frame.SetPortraitToAsset, frame, PORTRAIT)
	end
	-- Tag it as ours either way. The flat theme strips `portrait` and everything
	-- in PortraitContainer as Blizzard chrome, and our icon lives in that exact
	-- slot -- without the tag it vanishes the moment you leave the Blizzard skin.
	local function claim(tex)
		if type(tex) == "table" then tex.mmKeep = true end
		return tex
	end
	claim(frame.PortraitContainer and frame.PortraitContainer.portrait)
	claim(frame.portrait)

	if not portraitSet then
		local tex = claim((frame.PortraitContainer and frame.PortraitContainer.portrait)
			or frame.portrait)
		if tex then
			tex:SetTexture(PORTRAIT)
			tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
			portraitSet = true
		end
	end
	if not portraitSet then
		-- draw our own round badge in the corner
		local badge = frame:CreateTexture(nil, "OVERLAY")
		badge:SetSize(36, 36)
		badge:SetPoint("TOPLEFT", -5, 7)
		badge:SetTexture(PORTRAIT)
		local mask = frame:CreateMaskTexture()
		mask:SetAllPoints(badge)
		mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask",
			"CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
		badge:AddMaskTexture(mask)
	end

	-- Title-bar buttons: compact mode + options, left of the close button.
	-- Plain labeled buttons — they render identically on every client build.
	-- Header-area buttons (in the frame body, not the title bar — the title
	-- bar proved unreliable across client builds for anchoring custom buttons)
	local compactBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	compactBtn:SetSize(84, 22)
	compactBtn:SetText("Compact")
	compactBtn:SetFrameLevel(frame:GetFrameLevel() + 10)
	compactBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -26, -30)
	compactBtn:SetScript("OnClick", function()
		frame:Hide()
		MM:Fire("MM_TOGGLE_COMPACT")
	end)

	local gearBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	gearBtn:SetSize(72, 22)
	gearBtn:SetText("Options")
	gearBtn:SetFrameLevel(frame:GetFrameLevel() + 10)
	gearBtn:SetPoint("RIGHT", compactBtn, "LEFT", -4, 0)
	gearBtn:SetScript("OnClick", function() MM.OpenOptions() end)

	MM.Theme.Register(frame, "frame", false)
	-- panels sit inside the window; theme them too
	frame.mmIsWindow = true
	tinsert(UISpecialFrames, "MasterMountsFrame")

	-- collection progress, top right
	local progress = CreateFrame("StatusBar", nil, frame)
	progress:SetSize(220, 14)
	progress:SetPoint("TOPRIGHT", -196, -34)
	local pframe = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	pframe:SetPoint("TOPLEFT", progress, -3, 3)
	pframe:SetPoint("BOTTOMRIGHT", progress, 3, -3)
	pframe:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10 })
	pframe:SetBackdropBorderColor(0.85, 0.65, 0.25, 0.9)
	progress:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	progress:SetStatusBarColor(0.25, 0.85, 0.4)
	local pbg = progress:CreateTexture(nil, "BACKGROUND")
	pbg:SetAllPoints()
	pbg:SetColorTexture(0, 0, 0, 0.5)
	local ptext = progress:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	ptext:SetPoint("CENTER")
	local spark = progress:CreateTexture(nil, "OVERLAY")
	spark:SetSize(20, 30)
	spark:SetBlendMode("ADD")
	spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
	frame.progress, frame.progressText, frame.progressSpark = progress, ptext, spark
	MM.Theme.Register(progress, "statusbar")

	-- content panels fill the inset, with a moody gradient backdrop
	local function makePanel()
		local p = CreateFrame("Frame", nil, frame)
		p:SetPoint("TOPLEFT", 8, -60)
		p:SetPoint("BOTTOMRIGHT", -8, 30)
		local bg = p:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		local pc = MM.Theme.Colors()
		bg:SetColorTexture(pc.bg[1], pc.bg[2], pc.bg[3], pc.bg[4])
		pcall(function()
			bg:SetGradient("VERTICAL",
				CreateColor(0.02, 0.03, 0.07, 0.95),
				CreateColor(0.08, 0.09, 0.16, 0.95))
		end)
		p:Hide()
		return p
	end
	frame.CollectionPanel = makePanel()
	frame.PlannerPanel = makePanel()

	-- tabs
	frame.Tabs = {}
	local tabNames = { "Collection", "Planner" }
	for i, tabName in ipairs(tabNames) do
		local okTab, tab = pcall(CreateFrame, "Button", "MasterMountsFrameTab" .. i,
			frame, "PanelTabButtonTemplate")
		if not okTab or not tab then
			tab = CreateFrame("Button", "MasterMountsFrameTab" .. i, frame, "UIPanelButtonTemplate")
			tab:SetSize(110, 24)
		end
		tab:SetText(tabName)
		tab:SetID(i)
		if i == 1 then
			tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
		else
			tab:SetPoint("LEFT", frame.Tabs[i - 1], "RIGHT", 4, 0)
		end
		tab:SetScript("OnClick", function(self) UI:SelectTab(self:GetID()) end)
		MM.Theme.Register(tab, "button")
		frame.Tabs[i] = tab
	end
	pcall(PanelTemplates_SetNumTabs, frame, 2)

	frame:SetScript("OnShow", function() UI:Refresh() end)

	-- lazy-build tab contents
	UI.BuildCollection(frame.CollectionPanel)
	UI.BuildPlanner(frame.PlannerPanel)

	-- sweep everything the window contains, including widgets created
	-- directly rather than through the shared factories
	MM.Theme.SkinTree(frame)

	-- frames are born visible; start hidden so the first Toggle() SHOWS it
	-- instead of "toggling" a window nobody has seen yet
	frame:Hide()

	return frame
end

function UI:SelectTab(i)
	buildMain()
	frame.selectedTab = i
	pcall(PanelTemplates_SetTab, frame, i)
	frame.CollectionPanel:SetShown(i == 1)
	frame.PlannerPanel:SetShown(i == 2)
	UI:Refresh()
end

function UI:Refresh()
	if not frame or not frame:IsShown() then return end
	local c, t = MM.Scanner.collectedCount, MM.Scanner.totalCount
	frame.progress:SetMinMaxValues(0, math.max(t, 1))
	frame.progress:SetValue(c)
	frame.progressText:SetText(("%d / %d  (%d%%)"):format(c, t, t > 0 and (c * 100 / t) or 0))
	local pct = t > 0 and (c / t) or 0
	frame.progressSpark:ClearAllPoints()
	frame.progressSpark:SetPoint("CENTER", frame.progress, "LEFT", frame.progress:GetWidth() * pct, 0)
	-- warms from amber to green as the collection completes
	frame.progress:SetStatusBarColor(0.85 - 0.55 * pct, 0.55 + 0.3 * pct, 0.2 + 0.2 * pct)
	if frame.selectedTab == 2 then
		if UI.RefreshPlanner then UI.RefreshPlanner() end
	else
		if UI.RefreshCollection then UI.RefreshCollection() end
	end
end

function UI:Toggle(tabIndex)
	MM.Availability.EnsureCalendar() -- backstop; the background sync usually got there first
	buildMain()
	if frame:IsShown() and not tabIndex then
		frame:Hide()
		return
	end
	frame:Show()
	-- Planner, not Collection.
	--
	-- Requirement — we should also default to the planner tab with the main window.
	-- The Collection tab answers "what do we have"; the Planner answers "what
	-- should I do next", which is the reason to open the addon at all. The
	-- session still remembers a deliberate switch -- this only decides where a
	-- fresh window lands.
	UI:SelectTab(tabIndex or frame.selectedTab or DEFAULT_TAB)
end

function UI.HideMain()
	if frame and frame:IsShown() then frame:Hide() end
end

------------------------------------------------------------
-- The route lifecycle
------------------------------------------------------------
-- Starting a route is a mode change, and the windows should change with it
-- rather than leaving the player to arrange four frames by hand.
--
--   START  the three route windows appear -- the plan HUD, the arrow and the
--          next stop -- and the full window gets out of the way. You have
--          stopped planning and started travelling; a 900-pixel browser over
--          the middle of the screen is now in the way of the thing it asked
--          you to go and do.
--
--   STOP   the same three go away together. They exist to serve a route, and
--          leaving them behind after it ends is clutter the player has to
--          tidy up to get their screen back.
--
-- The arrow is not listed here because it already follows the route: SetTarget
-- shows it and Clear hides it, driven by the router itself.
--
-- The ZONE window is deliberately absent. It answers "is there anything to
-- farm where I am standing", which is true whether or not a route is running,
-- so it follows the player's own setting and nothing else.
MM:On("MM_ROUTE_STARTED", function()
	UI.HideMain()
	if MM.UI.SetCompactShown then MM.UI.SetCompactShown(true) end
	if MM.UI.ShowMonitor then MM.UI.ShowMonitor() end
end)

MM:On("MM_ROUTE_STOPPED", function()
	if MM.UI.SetCompactShown then MM.UI.SetCompactShown(false) end
	if MM.UI.HideMonitor then MM.UI.HideMonitor() end
end)

MM:On("MM_TOGGLE_MAIN", function(tabIndex) UI:Toggle(tabIndex) end)

-- Open on ONE mount, not on the list that contains it.
--
-- Reported from outside: "clicking on the notification or on one of the mounts
-- just brings me to the big list of all the mounts, would be super nice if the
-- addon would open directly on the mount in question, otherwise it is just one
-- more type-in-name-to-search."
--
-- Exactly right, and the popup already knew which mount it was -- the click
-- handler discarded it and fired the generic open. The search box is the
-- narrowing mechanism the tab already has, so this drives that rather than
-- inventing a second kind of selection that would then need its own clearing,
-- its own refresh and its own bugs.
MM:On("MM_SHOW_MOUNT", function(entry)
	-- TAB 1 IS COLLECTION. Tab 2 is the Planner, and this opened 2 with a
	-- comment claiming it was Collection -- so clicking a mount in the zone
	-- popup opened the PLANNER and then filtered a search box on a tab that was
	-- not on screen. The one line in this file that says which is which is
	-- DEFAULT_TAB at the top; both places now agree with it.
	UI:Toggle(1)                       -- 1 = Collection, 2 = Planner
	if not (entry and entry.name) then return end
	local box = UI.collectionSearch
	if not box then return end
	box:SetText(entry.name)
	-- SearchBoxTemplate draws its own placeholder and clear button off the
	-- text, and neither updates from SetText alone.
	if box.Instructions then box.Instructions:Hide() end
	if box.clearButton then box.clearButton:Show() end
	UI.RefreshCollection()
end)
MM:On("MM_SCANNED", function() if frame and frame:IsShown() then UI:Refresh() end end)
MM:On("MM_PLAN_CHANGED", function() if frame and frame:IsShown() then UI:Refresh() end end)
MM:On("MM_TRADINGPOST", function() if frame and frame:IsShown() then UI:Refresh() end end)
MM:On("MM_CALENDAR", function() if frame and frame:IsShown() then UI:Refresh() end end)

------------------------------------------------------------
-- Shared row click behavior
------------------------------------------------------------
-- Open the Blizzard Mount Journal focused on this mount.
function UI.OpenJournalTo(entry)
	if not entry or not entry.mountID then return end
	if C_AddOns and C_AddOns.LoadAddOn then
		pcall(C_AddOns.LoadAddOn, "Blizzard_Collections")
	elseif LoadAddOn then
		pcall(LoadAddOn, "Blizzard_Collections")
	end
	if CollectionsJournal and CollectionsJournal:IsShown() then
		pcall(CollectionsJournal_SetTab, CollectionsJournal, 1)
	elseif ToggleCollectionsJournal then
		pcall(ToggleCollectionsJournal, 1)
	end
	local selected = MountJournal_SelectByMountID
		and pcall(MountJournal_SelectByMountID, entry.mountID)
	if not selected and MountJournal and MountJournal.searchBox then
		pcall(MountJournal.searchBox.SetText, MountJournal.searchBox, entry.name)
	end
end

-- Left-click previews in the journal; the [+] buttons manage the plan.
function UI.RowClick(entry, mouseButton)
	if IsControlKeyDown() then
		UI.ToggleIgnore(entry)
		return
	end
	if mouseButton == "RightButton" or IsShiftKeyDown() then
		MM:ShowWowheadLink(entry)
		return
	end
	UI.OpenJournalTo(entry)
end

function UI.TogglePlan(entry)
	if not entry or entry.collected then return end
	if MM.Planner:InPlan(entry.spellID) then
		MM.Planner:Remove(entry.spellID)
	else
		MM.Planner:Add(entry.spellID)
	end
end

-- Ignoring MARKS a mount (row dims, border reddens). Hiding is a separate
-- filter, so you can flag things you'll never chase without them vanishing
-- until you actually ask for that.
function UI.ToggleIgnore(entry)
	if not entry or not entry.spellID then return end
	if MM.db.ignored[entry.spellID] then
		MM.db.ignored[entry.spellID] = nil
	else
		MM.db.ignored[entry.spellID] = true
		MM.Planner:Remove(entry.spellID)
	end
	MM:Fire("MM_PLAN_CHANGED")
end
