-- Master Mounts options panel (Settings > AddOns > Master Mounts).
--
-- The settings container is a fixed size and does NOT scroll for you, so the
-- content lives in a scroll child whose height is accumulated as widgets are
-- placed. Anything anchored straight to the panel silently runs off the
-- bottom once the list grows.
local _, MM = ...

-- Slider templates have churned across expansions, so probe rather than assume;
-- the manual build at the end always works.
local function makeSlider(parent)
	for _, template in ipairs({ "UISliderTemplateWithLabels", "OptionsSliderTemplate",
		"UISliderTemplate" }) do
		local ok, s = pcall(CreateFrame, "Slider", nil, parent, template)
		if ok and s then return s, template end
	end
	local s = CreateFrame("Slider", nil, parent)
	s:SetOrientation("HORIZONTAL")
	s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
	local bg = s:CreateTexture(nil, "BACKGROUND")
	bg:SetColorTexture(0, 0, 0, 0.4)
	bg:SetPoint("TOPLEFT", 0, -8)
	bg:SetPoint("BOTTOMRIGHT", 0, 8)
	return s, nil
end

local function buildPanel()
	local panel = CreateFrame("Frame")
	panel.name = "Master Mounts"

	-- An opaque backing behind the panel.
	--
	-- Blizzard's Settings frame is transparent, so everything here was being read
	-- against the 3D world and the player's own character model -- moving, lit
	-- differently every second, and impossible to read against. Text contrast is
	-- not a property of the text when the background is a rotating night elf.
	local backing = panel:CreateTexture(nil, "BACKGROUND")
	backing:SetAllPoints(panel)
	backing:SetColorTexture(0.05, 0.05, 0.06, 0.94)

	local scroll = CreateFrame("ScrollFrame", "MasterMountsOptionsScroll", panel,
		"UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 3, -4)
	scroll:SetPoint("BOTTOMRIGHT", -27, 4)

	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)

	-- running layout cursor; every helper advances it and returns its widget
	local y = -8
	local LEFT = 16

	local function place(widget, height, indent)
		widget:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT + (indent or 0), y)
		y = y - (height or 26)
		return widget
	end

	local function heading(text, gap)
		y = y - (gap or 10)
		local fs = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		fs:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
		fs:SetText(text)
		y = y - 22
		return fs
	end

	local function label(text, size)
		local fs = content:CreateFontString(nil, "OVERLAY", size or "GameFontHighlightSmall")
		fs:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
		fs:SetWidth(560)
		fs:SetJustifyH("LEFT")
		fs:SetText(text)
		y = y - (fs:GetStringHeight() + 8)
		return fs
	end

	local function check(text, key, tip, indent)
		local c = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
		c:SetSize(26, 26)
		local t = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		t:SetPoint("LEFT", c, "RIGHT", 4, 1)
		t:SetText(text)
		c.tooltipText = tip
		c:SetScript("OnShow", function(self) self:SetChecked(MM.db[key] and true or false) end)
		c:SetScript("OnClick", function(self)
			MM.db[key] = self:GetChecked() and true or false
			if key == "mapPins" or key == "mapPinsShowCollected" then
				if MM.MapPins then MM.MapPins.Refresh() end
			elseif key == "useTomTom" then
				-- Hand the leg being travelled to the other provider NOW.
				-- Without this the box only takes effect at the next step,
				-- which mid-route reads as the setting doing nothing.
				if MM.Nav and MM.Nav.Refresh then MM.Nav.Refresh() end
			end
		end)
		return place(c, 26, indent)
	end

	-- nested under MM.db.announce
	local function announceCheck(text, key, tip, indent)
		local c = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
		c:SetSize(26, 26)
		local t = c:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		t:SetPoint("LEFT", c, "RIGHT", 4, 1)
		t:SetText(text)
		c.tooltipText = tip
		c:SetScript("OnShow", function(self)
			self:SetChecked(MM.db.announce and MM.db.announce[key] and true or false)
		end)
		c:SetScript("OnClick", function(self)
			MM.db.announce = MM.db.announce or {}
			MM.db.announce[key] = self:GetChecked() and true or false
		end)
		return place(c, 24, indent)
	end

	------------------------------------------------------------
	local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
	title:SetText("|cff33c1ffMaster Mounts|r  " .. MM.VERSION)
	y = y - 24
	label("/mm  —  show | plan | monitor | compact | route | easiest | audit | zone | compare")

	heading("|cffffd84dCollecting|r", 4)
	check("Celebration splash when a hunted mount drops", "celebration",
		"Full-screen fanfare with the mount's model.")
	check("Take a screenshot during the celebration", "celebrationShot",
		"Fires Screenshot() one second into the splash.", 16)
	check("Celebrate every new mount, not just planned ones", "celebrateAll", nil, 16)
	check("Hide ignored mounts (Ctrl-click a row to ignore)", "hideIgnored",
		"Ignoring always marks a mount red; this also removes it from lists.")

	heading("|cffffd84dWhile you play|r")
	check("Alert me when a needed rare is up nearby", "rareAlert",
		"Reads the game's own vignette markers, so it fires before you see the rare.")
	check("Drop a waypoint on alerted rares", "rareAlertWaypoint", nil, 16)
	check("Play the alert even if the game is muted", "rareAlertForceAudible",
		"Raises the master volume, the global sound switch and the play-while-"
		.. "alt-tabbed setting for the length of the alert, then puts all three "
		.. "back exactly as they were. Nothing else is touched.", 16)
	check("On entering a zone, list what's farmable there", "zoneAlert",
		"Uncollected mounts in the zone you just entered, rarest first.")
	check("Open it whenever I enter a zone that has mounts", "zoneAlertAutoOpen",
		"On by default. Turn it off to keep the window entirely on demand — "
		.. "it then only appears when you ask for it with /mm zone show, which "
		.. "suits players who would rather nothing opened itself.", 16)
	check("Keep the zone window open until I close it", "zoneAlertSticky",
		"Pinned, it stays put instead of fading, and says so when a zone has "
		.. "nothing left to farm. Close it with the X or a right-click; it "
		.. "comes back in the next zone. /mm zone show summons it any time.", 16)
	check("Show mount locations on the world map", "mapPins")
	check("Include mounts I already own on the map", "mapPinsShowCollected", nil, 16)
	check("Hand waypoints to TomTom instead of the built-in arrow", "useTomTom",
		"Off by default. TomTom has a single arrow that any addon can write "
		.. "to, so whichever wrote last owns it — which can steer you off "
		.. "route mid-leg and look like Master Mounts pointing at the wrong "
		.. "place. The built-in arrow answers to nothing else. Switching this "
		.. "takes effect immediately, either way, on the step you are on.")

	-- Arrow size.
	--
	-- Scales the whole arrow frame -- pointer, mount name, distance and step pill
	-- together -- because those are one object to the person reading them.
	-- Applied live on drag, so the slider shows its own effect rather than
	-- asking you to close the panel and guess.
	local scaleLabel = content:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	scaleLabel:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
	y = y - 20
	local scale = makeSlider(content)
	scale:SetSize(300, 18)
	scale:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT, y)
	scale:SetMinMaxValues(0.5, 2.5)
	scale:SetValueStep(0.05)
	scale:SetObeyStepOnDrag(true)
	if scale.Low then scale.Low:SetText("Smaller") end
	if scale.High then scale.High:SetText("Bigger") end
	if scale.Text then scale.Text:SetText("") end
	local function scaleText()
		local v = MM.db.arrowScale or 1
		scaleLabel:SetText(("Navigation arrow size: |cffffd84d%.2fx|r%s")
			:format(v, math.abs(v - 1) < 0.001 and "  (default)" or ""))
	end
	-- SetValue fires OnValueChanged, so guard the refresh against recursing.
	local applyingScale = false
	scale:SetScript("OnValueChanged", function(_, v)
		if applyingScale then return end
		if MM.Arrow and MM.Arrow.SetScale then MM.Arrow:SetScale(v) else MM.db.arrowScale = v end
		scaleText()
	end)
	scale:SetScript("OnShow", function(self)
		applyingScale = true
		self:SetValue(MM.db.arrowScale or 1)
		applyingScale = false
		scaleText()
	end)
	scaleText()
	y = y - 34

	local minimap = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
	minimap:SetSize(26, 26)
	local mmText = minimap:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	mmText:SetPoint("LEFT", minimap, "RIGHT", 4, 1)
	mmText:SetText("Show the minimap button")
	minimap:SetScript("OnShow", function(self)
		self:SetChecked(not (MM.db.minimap and MM.db.minimap.hide))
	end)
	minimap:SetScript("OnClick", function(self)
		MM.SetMinimapShown(self:GetChecked() and true or false)
	end)
	place(minimap, 26)

	heading("|cffffd84dAnnounce new mounts in chat|r")
	announceCheck("Announce when I collect a mount", "enabled",
		"Master switch. Everything below is ignored while this is off.")
	announceCheck("Only announce mounts from my farm plan", "plannedOnly", nil, 16)
	announceCheck("Guild", "guild", nil, 16)
	announceCheck("Party / Raid", "group", nil, 16)
	announceCheck("Say (nearby players)", "say", nil, 16)
	announceCheck("Trade channel", "trade",
		"Public channel - many realms consider this spam. Off by default.", 16)
	announceCheck("General channel", "general",
		"Public channel - many realms consider this spam. Off by default.", 16)

	heading("|cffffd84dSharing|r")
	local shareBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	shareBtn:SetSize(240, 24)
	local SHARE = { "none", "group" }
	local SHARE_LABEL = { none = "Never share my collection", group = "Share with my group on request" }
	local function shareText()
		local cur = (MM.db.groupSync and MM.db.groupSync.share) or "none"
		shareBtn:SetText(SHARE_LABEL[cur] or SHARE_LABEL.none)
	end
	shareBtn:SetScript("OnClick", function()
		MM.db.groupSync = MM.db.groupSync or {}
		local cur = MM.db.groupSync.share or "none"
		MM.db.groupSync.share = (cur == "none") and "group" or "none"
		shareText()
	end)
	shareBtn:SetScript("OnShow", shareText)
	shareText()
	place(shareBtn, 26)
	label("Sharing is opt-in. Your collection is whispered only to a player who asks, never broadcast.")

	heading("|cffffd84dAppearance|r")
	local THEMES = { "auto", "blizzard", "elvui" }
	local THEME_LABEL = { auto = "Auto", blizzard = "Blizzard", elvui = "ElvUI" }
	-- A DROPDOWN, like every other list of choices in the addon.
	--
	-- This was a button that opened a radio menu -- the same gesture the
	-- planner and collection filters used, and the same problem: a control that
	-- opens a list should look like one. The "(ElvUI)" suffix on Auto stays,
	-- because Auto without saying what it resolved to is a setting you cannot
	-- check.
	local themeBtn
	local function themeLabel()
		local set = MM.db.theme
		local text = THEME_LABEL[set or "auto"] or "Auto"
		if not set then
			text = text .. " (" .. (MM.Theme.HasElvUI() and "ElvUI" or "Blizzard") .. ")"
		end
		return "Theme: " .. text
	end
	local function themeText()
		if not themeBtn then return end
		if themeBtn.SetDefaultText then themeBtn:SetDefaultText(themeLabel())
		elseif themeBtn.SetText then themeBtn:SetText(themeLabel()) end
	end
	local function setTheme(value)
		MM.db.theme = (value ~= "auto") and value or nil
		MM.Theme.ReskinAll()
		themeText()
	end
	local ok, drop = pcall(CreateFrame, "DropdownButton", nil, content,
		"WowStyle1DropdownTemplate")
	if ok and drop and drop.SetupMenu then
		themeBtn = drop
		themeBtn:SetSize(240, 24)
		themeBtn:SetupMenu(function(_, root)
			root:CreateTitle("Theme")
			for _, v in ipairs(THEMES) do
				local labelText = THEME_LABEL[v]
				if v == "auto" then
					labelText = labelText .. " ("
						.. (MM.Theme.HasElvUI() and "ElvUI" or "Blizzard") .. ")"
				elseif v == "elvui" and not MM.Theme.HasElvUI() then
					-- Offered on purpose, and honest about what it gives you.
					-- The palette is ours; only ElvUI's own skinning of
					-- Blizzard widgets needs ElvUI present. Hiding the option
					-- would take away a look that works perfectly well.
					labelText = labelText .. " (colours only)"
				end
				root:CreateRadio(labelText,
					function() return (MM.db.theme or "auto") == v end,
					function() setTheme(v) end)
			end
		end)
	else
		-- pre-dropdown clients: a button that cycles. Same reach, fewer
		-- affordances, and it still says what it is set to.
		themeBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
		themeBtn:SetSize(240, 24)
		themeBtn:SetScript("OnClick", function()
			local cur = MM.db.theme or "auto"
			local i = 1
			for n, v in ipairs(THEMES) do if v == cur then i = n end end
			setTheme(THEMES[(i % #THEMES) + 1])
		end)
	end
	themeBtn:SetScript("OnShow", themeText)
	themeText()
	place(themeBtn, 26)
	label(MM.Theme.HasElvUI()
		and "ElvUI detected - used automatically on Auto."
		or "ElvUI is not installed; Auto uses the Blizzard look.")

	heading("|cffffd84dTry it|r")
	local testBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	testBtn:SetSize(180, 24)
	testBtn:SetScript("OnClick", function() MM.Celebration:Test() end)
	testBtn:SetText("Preview Celebration")
	place(testBtn, 26)
	label("Uses a random mount you own. Never screenshots and never announces.")

	local rareTestBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	rareTestBtn:SetSize(180, 24)
	rareTestBtn:SetScript("OnClick", function() MM.RareAlert.Test() end)
	rareTestBtn:SetText("Preview Rare Alert")
	place(rareTestBtn, 26)

	-- Sound picker sits beside the test button rather than under it: choosing a
	-- sound and hearing it are one decision, so they belong on one line.
	local function currentSound()
		local key = MM.db.rareAlertSoundKey or (MM.RareAlert.SOUNDS[1] and MM.RareAlert.SOUNDS[1].key)
		for _, s in ipairs(MM.RareAlert.SOUNDS) do
			if s.key == key then return s end
		end
		return MM.RareAlert.SOUNDS[1]
	end

	local soundBtn = MM.Theme.CreateDropdown(content, 150,
		function() local s = currentSound() return s and s.label or "Sound" end,
		function(root)
			root:CreateTitle("Alert sound")
			for _, s in ipairs(MM.RareAlert.SOUNDS) do
				root:CreateRadio(s.label,
					function() return (MM.db.rareAlertSoundKey or MM.RareAlert.SOUNDS[1].key) == s.key end,
					function()
						MM.db.rareAlertSoundKey = s.key
						MM.RareAlert.PlaySound(s.key)   -- hear it as you pick it
					end)
			end
		end)
	soundBtn:SetPoint("LEFT", rareTestBtn, "RIGHT", 8, 0)

	local playBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	playBtn:SetSize(70, 24)
	playBtn:SetPoint("LEFT", soundBtn, "RIGHT", 6, 0)
	playBtn:SetText("Play")
	playBtn:SetScript("OnClick", function()
		local played = MM.RareAlert.PlaySound(MM.db.rareAlertSoundKey)
		-- SILENCE ON SUCCESS. You pressed Play and you heard it; a chat line
		-- saying so is the addon talking to itself.
		--
		-- The failure case is the opposite: nothing playing is indistinguishable
		-- from a broken button, so that one is worth a line. The resolved id
		-- goes with it, because six menu entries sharing one id is the bug this
		-- list replaced and identical ids are how you would spot it returning.
		if played then return end
		local s
		for _, e in ipairs(MM.RareAlert.SOUNDS) do
			if e.key == (MM.db.rareAlertSoundKey or MM.RareAlert.SOUNDS[1].key) then s = e end
		end
		MM:Print("That sound did not play on this client (id %s) - pick another.",
			tostring(s and (s.id or s.file)))
	end)

	label("Shows a rare you still need, so the preview matches the real thing. Works even with alerts switched off.")

	-- the scroll child must know how tall the content actually is
	content:SetHeight(math.abs(y) + 20)
	content:SetWidth(580)

	return panel
end

------------------------------------------------------------
-- Weights & Priorities subcategory
------------------------------------------------------------
-- Two controls, because "prioritise rares over achievements" and "I don't mind
-- travelling" are different kinds of statement:
--
--   the ORDERED LIST is absolute -- whatever sits higher wins outright
--   the SLIDERS are relative    -- they shuffle things inside a band
--
-- Every change re-runs the ranking and redraws a live preview of the next five
-- goals, so the effect of a setting is visible in the same glance as the
-- setting. Sliders whose consequence you cannot see are sliders nobody moves.


local function buildWeights()
	local W = MM.Weights
	local panel = CreateFrame("Frame")
	panel.name = "Weights & Priorities"

	-- Opaque backing; the Settings frame itself is transparent.
	local backing = panel:CreateTexture(nil, "BACKGROUND")
	backing:SetAllPoints(panel)
	backing:SetColorTexture(0.05, 0.05, 0.06, 0.94)

	local scroll = CreateFrame("ScrollFrame", "MasterMountsWeightsScroll", panel,
		"UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 3, -4)
	scroll:SetPoint("BOTTOMRIGHT", -27, 4)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)

	local LEFT, WIDTH, ROW_H = 16, 560, 30

	-- Anchor-chained layout, NOT a manual y cursor.
	--
	-- The cursor version collided: it advanced by GetStringHeight(), which knows
	-- nothing about the low/high captions a slider draws BELOW its bar, so every
	-- slider's description landed on top of "Distance is free" / "Stay local".
	-- Chaining each widget to the bottom of the last one lets the layout engine
	-- account for whatever a widget actually occupies.
	local prev, prevGap = nil, 0
	local function attach(widget, gap, indent)
		if prev then
			widget:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", (indent or 0) - prevGap, -(gap or 8))
		else
			widget:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT + (indent or 0), -12)
		end
		prev, prevGap = widget, indent or 0
		return widget
	end

	local function para(text, font, gap, indent)
		local fs = content:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
		fs:SetWidth(WIDTH - (indent or 0))
		fs:SetJustifyH("LEFT")
		fs:SetText(text)
		return attach(fs, gap, indent)
	end

	local title = para("Weights & Priorities", "GameFontNormalLarge", 0)
	para("These are the opinions behind every recommendation. The defaults "
		.. "are what we'd tell a new collector; change them to match how you actually play.", nil, 8)

	------------------------------------------------------------
	-- Presets
	------------------------------------------------------------
	-- Seven sliders and a reorderable list is a good tool and a poor starting
	-- point. A preset is a sentence about how you play; the numbers behind it
	-- are the addon's problem.
	para("Start from how you play", "GameFontNormal", 12)
	local presetRow = CreateFrame("Frame", nil, content)
	presetRow:SetSize(WIDTH, 26)
	attach(presetRow, 6)

	local presetBlurb = para("", "GameFontDisableSmall", 6, 4)
	local presetButtons, refresh = {}, nil
	local px = 0
	for _, preset in ipairs(W.PRESETS) do
		local b = CreateFrame("Button", nil, presetRow, "UIPanelButtonTemplate")
		local width = math.max(90, #preset.name * 7 + 16)
		b:SetSize(width, 22)
		b:SetPoint("LEFT", presetRow, "LEFT", px, 0)
		px = px + width + 5
		b:SetText(preset.name)
		b:SetScript("OnClick", function()
			W.ApplyPreset(preset.key)
			if refresh then refresh() end
		end)
		b:SetScript("OnEnter", function()
			presetBlurb:SetText(("|cffffd84d%s|r  %s  |cff8fbf8f%s|r")
				:format(preset.name, preset.blurb, preset.expect))
		end)
		b:SetScript("OnLeave", function() if refresh then refresh() end end)
		presetButtons[preset.key] = b
	end

	local resetBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	resetBtn:SetSize(150, 22)
	resetBtn:SetText("Reset to defaults")
	attach(resetBtn, 14)

	local dirty = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	dirty:SetPoint("LEFT", resetBtn, "RIGHT", 10, 0)

	------------------------------------------------------------
	-- Priority order
	------------------------------------------------------------
	para("Priority order", "GameFontNormal", 18)
	para("Top of the list is offered first. This beats everything below it — "
		.. "a rare above achievements means no achievement outranks a rare, however easy.",
		"GameFontDisableSmall", 6)

	local rows = {}

	for i = 1, #W.DEFAULT_ORDER do
		local row = CreateFrame("Frame", nil, content)
		row:SetSize(WIDTH, ROW_H)
		attach(row, i == 1 and 8 or 0)

		local num = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		num:SetPoint("LEFT", 2, 0)
		num:SetWidth(18)
		num:SetJustifyH("RIGHT")
		num:SetText(i .. ".")

		local up = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		up:SetSize(22, 20)
		up:SetPoint("LEFT", num, "RIGHT", 6, 0)
		up:SetText("|TInterface\\Buttons\\Arrow-Up-Up:12:12|t")
		local down = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		down:SetSize(22, 20)
		down:SetPoint("LEFT", up, "RIGHT", 2, 0)
		down:SetText("|TInterface\\Buttons\\Arrow-Down-Up:12:12|t")

		local name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		name:SetPoint("LEFT", down, "RIGHT", 10, 0)
		name:SetWidth(150)
		name:SetJustifyH("LEFT")

		local hint = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		hint:SetPoint("LEFT", name, "RIGHT", 6, 0)
		hint:SetWidth(320)
		hint:SetJustifyH("LEFT")

		up:SetScript("OnClick", function() if W.Move(i, -1) then refresh() end end)
		down:SetScript("OnClick", function() if W.Move(i, 1) then refresh() end end)

		rows[i] = { frame = row, name = name, hint = hint, up = up, down = down }
	end

	------------------------------------------------------------
	-- Sliders
	------------------------------------------------------------
	para("Emphasis", "GameFontNormal", 20)
	para(W.SCALE_HINT .. " Every default below is the number the addon "
		.. "was already using, so leaving them alone changes nothing.",
		"GameFontDisableSmall", 6)

	local sliders = {}
	for _, def in ipairs(W.SLIDERS) do
		local caption = para(def.label, "GameFontHighlight", 16, 4)
		local value = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		value:SetPoint("LEFT", caption, "LEFT", 180, 0)

		local s = makeSlider(content)
		s:SetSize(430, 18)
		attach(s, 6, 8)
		s:SetMinMaxValues(def.min, def.max)
		s:SetValueStep(def.step or 0.05)
		s:SetObeyStepOnDrag(true)
		if s.Low then s.Low:SetText(def.lowText or tostring(def.min)) end
		if s.High then s.High:SetText(def.highText or tostring(def.max)) end
		if s.Text then s.Text:SetText("") end

		-- The low/high captions hang below the bar and are NOT part of the
		-- slider's height, so the next widget has to clear them by hand. This is
		-- the gap the cursor layout got wrong.
		local desc = para(def.desc, "GameFontDisableSmall", 22, 8)

		-- What the number currently MEANS, in a sentence, updated as it moves. A
		-- raw coefficient is honest but not yet informative; this is the half
		-- that makes it a decision rather than a guess.
		local reading = para("", "GameFontHighlightSmall", 4, 8)

		-- Guard the write: SetValue() during a refresh fires OnValueChanged, which
		-- would call Changed() and refresh again. Left unguarded that recurses.
		local applying = false
		s:SetScript("OnValueChanged", function(self, v)
			if applying then return end
			W.Set(def.key, v)
			refresh()
		end)
		sliders[def.key] = { slider = s, value = value, caption = caption, def = def,
			reading = reading,
			apply = function(v)
				applying = true
				s:SetValue(v)
				applying = false
			end }
	end

	------------------------------------------------------------
	-- Live preview
	------------------------------------------------------------
	para("With these settings, next up", "GameFontNormal", 22)
	local preview = para("", "GameFontHighlightSmall", 6, 8)
	preview:SetSpacing(3)

	-- Scroll height. Anchor chaining does not give us a total, and asking the
	-- frame before it has laid out returns nothing useful, so measure on the
	-- next frame and keep it in step with the preview, which is the only part
	-- whose height changes after build.
	local function fitHeight()
		local top, bottom = content:GetTop(), preview:GetBottom()
		if top and bottom and top > bottom then
			content:SetHeight(top - bottom + 24)
		end
	end
	content:SetHeight(1200)   -- generous until the real measurement lands

	------------------------------------------------------------
	-- Redraw
	------------------------------------------------------------
	local function previewText()
		if not (MM.Planner and MM.Scanner and #MM.Scanner.mounts > 0) then
			return "|cff9a9a9aScanning your collection…|r"
		end
		-- Show the top of the PLAN, which is what these settings reorder.
		-- Easiest() deliberately skips anything already planned, so on a full
		-- plan it returned nothing and the preview read "Nothing plannable is
		-- missing" -- next to 286 planned goals.
		local list = MM.Planner:GetPlan()
		if #list == 0 then list = MM.Planner:Easiest(5) end
		if #list == 0 then return "|cff9a9a9aYour plan is empty — add some mounts first.|r" end
		local out = {}
		for i = 1, math.min(5, #list) do
			local entry = list[i]
			local tier = MM.Planner.Rank(entry)
			out[i] = ("|cffffd200%d.|r %s  |cff9a9a9a— priority %d, %s|r")
				:format(i, entry.name, W.TierRank(tier), MM.Planner.TIER_LABEL[tier] or "")
		end
		if MM.cdb and MM.cdb.routeActive then
			out[#out + 1] = "|cff40d860Applied — your route has been re-ordered.|r"
		end
		return table.concat(out, "\n")
	end

	refresh = function()
		local order = W.Order()
		for i, row in ipairs(rows) do
			local key = order[i]
			row.name:SetText(MM.Planner.TIER_LABEL[MM.Planner.TIER[key]] or key)
			row.hint:SetText(W.TIER_HINT[key] or "")
			row.up:SetEnabled(i > 1)
			row.down:SetEnabled(i < #order)
		end
		for key, s in pairs(sliders) do
			local v = W.Get(key)
			s.apply(v)
			local shown = ("%s %s"):format(W.Format(s.def, v), s.def.unit or "")
			local isDefault = math.abs(v - s.def.default) < ((s.def.step or 0.05) / 2)
			s.value:SetText(isDefault
				and ("|cff9a9a9a%s  (default)|r"):format(shown)
				or ("|cffffd200%s|r  |cff9a9a9a(default %s)|r")
					:format(shown, W.Format(s.def, s.def.default)))
			s.reading:SetText(s.def.reading and ("|cff8fbf8f%s|r"):format(s.def.reading(v)) or "")
		end
		-- Which preset you are on, or that you have moved past all of them.
		local current = W.CurrentPreset()
		for key, button in pairs(presetButtons) do
			button:SetEnabled(not (current and current.key == key))
		end
		if current then
			dirty:SetText(("|cff8fbf8f%s|r"):format(current.name))
			presetBlurb:SetText(("%s  |cff8fbf8f%s|r"):format(current.blurb, current.expect))
		else
			dirty:SetText("|cffffd200Your own settings.|r")
			presetBlurb:SetText("|cff9a9a9aPick a preset above to start from somewhere, "
				.. "or keep tuning — nothing here is lost either way.|r")
		end
		preview:SetText(previewText())
		C_Timer.After(0, fitHeight)
	end

	resetBtn:SetScript("OnClick", function() W.Reset() refresh() end)
	-- Paint once at build time. OnShow alone was not enough: Settings shows and
	-- hides a canvas panel during registration, so by the time the player actually
	-- navigated to it the event had already been spent and the page sat empty
	-- until something else forced a redraw.
	refresh()
	panel:SetScript("OnShow", refresh)
	MM:On("MM_SCANNED", function() if panel:IsShown() then refresh() end end)
	-- The plan is rewritten a moment after a change (debounced), so redraw when
	-- it lands: otherwise the preview shows the order from before the edit and
	-- quietly contradicts the plan window.
	MM:On("MM_PLAN_CHANGED", function() if panel:IsShown() then refresh() end end)

	return panel
end

------------------------------------------------------------
-- Travel subcategory: which teleports the router may spend
------------------------------------------------------------
-- ASKED FOR DIRECTLY: "I don't want it to suggest my M+ dungeon teleports."
--
-- The router is not wrong to price them -- they genuinely are the fastest way
-- into those instances -- but a player saving the charges for a key would
-- rather walk, and nothing the addon can measure will ever tell it that. So it
-- is a switch, not a heuristic.
--
-- Lists only what this character can actually press. The catalogue is over
-- eighty teleports; a page of ones nobody has earned is a wall rather than a
-- setting, and the ones being suggested are exactly the ones worth switching.
local function buildTravel()
	local panel = CreateFrame("Frame")
	panel.name = "Travel"

	local backing = panel:CreateTexture(nil, "BACKGROUND")
	backing:SetAllPoints(panel)
	backing:SetColorTexture(0.05, 0.05, 0.06, 0.94)

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Teleports the route may use")

	local blurb = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	blurb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	blurb:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	blurb:SetJustifyH("LEFT")
	blurb:SetText("Unticked teleports are never suggested and never priced into a "
		.. "route. Only what this character can use is listed. The plan redraws "
		.. "as you change them.")

	local group = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	group:SetSize(210, 24)
	group:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -12)

	local scroll = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", group, "BOTTOMLEFT", 0, -12)
	scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -34, 16)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(1, 1)
	scroll:SetScrollChild(content)

	local rows = {}
	local function refresh()
		local TP = MM.Teleports
		if not (TP and TP.Switchable) then return end
		local list = TP.Switchable()
		local anyDungeonOn = false
		for _, item in ipairs(list) do
			if item.dungeon and not item.off then anyDungeonOn = true break end
		end
		group:SetText(anyDungeonOn and "Turn off all dungeon teleports"
			or "Turn on all dungeon teleports")
		group:SetShown(#list > 0)
		group.turnOff = anyDungeonOn

		for _, row in ipairs(rows) do row:Hide() end
		local y, lastDungeon = 0, nil
		for i, item in ipairs(list) do
			local row = rows[i]
			if not row then
				row = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
				row.label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
				row.label:SetPoint("LEFT", row, "RIGHT", 2, 0)
				row.heading = row:CreateFontString(nil, "ARTWORK", "GameFontNormal")
				row.heading:SetPoint("BOTTOMLEFT", row, "TOPLEFT", 0, 4)
				rows[i] = row
			end
			-- A heading only where the kind changes, so the two groups read as
			-- groups without a separate frame for each.
			if lastDungeon ~= item.dungeon then
				row.heading:SetText(item.dungeon and "Dungeon & raid teleports"
					or "Items, hearthstones and class spells")
				row.heading:Show()
				y = y + (i > 1 and 26 or 14)
				lastDungeon = item.dungeon
			else
				row.heading:Hide()
			end
			row:SetSize(24, 24)
			row:SetPoint("TOPLEFT", content, "TOPLEFT", 4, -y)
			row.label:SetText(item.place and item.place ~= ""
				and ("%s  |cff9d9d9d-> %s|r"):format(item.name, item.place)
				or item.name)
			row:SetChecked(not item.off)
			row.mmKey = item.key
			row:SetScript("OnClick", function(self)
				MM.Teleports.SetOff(self.mmKey, not self:GetChecked())
				refresh()
			end)
			row:Show()
			y = y + 24
		end
		content:SetSize(math.max(scroll:GetWidth() - 4, 1), math.max(y, 1))
	end

	group:SetScript("OnClick", function()
		local TP = MM.Teleports
		if not (TP and TP.DungeonKeys) then return end
		local off = group.turnOff
		for _, key in ipairs(TP.DungeonKeys()) do TP.SetOff(key, off) end
		refresh()
	end)

	panel:SetScript("OnShow", refresh)
	-- Learning a teleport, or logging in on a character who has different ones,
	-- changes what belongs on this list.
	MM:On("MM_SCANNED", function() if panel:IsShown() then refresh() end end)
	return panel
end

------------------------------------------------------------
-- Diagnostics subcategory
------------------------------------------------------------
-- Registered as a Settings SUBcategory rather than an in-panel tab: that is the
-- native shape in the modern Settings UI, so it gets the tree entry, the search
-- indexing and the back button for free.
local function buildDiagnostics()
	local panel = CreateFrame("Frame")
	panel.name = "Diagnostics"

	-- Opaque backing; the Settings frame itself is transparent.
	local backing = panel:CreateTexture(nil, "BACKGROUND")
	backing:SetAllPoints(panel)
	backing:SetColorTexture(0.05, 0.05, 0.06, 0.94)

	local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -16)
	title:SetText("Diagnostics report")

	local blurb = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	blurb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	blurb:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
	blurb:SetJustifyH("LEFT")
	blurb:SetText("Runs every check and collects the output here as plain text. "
		.. "Click Generate, wait a moment, then Select All and press Ctrl+C.")

	local generate = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	generate:SetSize(150, 24)
	generate:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -12)
	generate:SetText("Generate report")

	-- Export buttons sit beside Generate: the report tells you a gap exists, and
	-- these produce the paste-ready data that closes it, without needing to know
	-- the slash commands.
	local exports = {
		{ "Export spellIDs", "MM_SPELLS_EXPORT" },
		{ "Export new mounts", "MM_STUBS_EXPORT" },
		-- Deliberately a button and not a report section: it builds a dozen
		-- routes and prints several hundred lines, which nobody wants attached
		-- to every diagnostic paste.
		{ "Weights matrix", "MM_WEIGHTS_MATRIX_EXPORT" },
	}

	local selectAll = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	selectAll:SetSize(110, 24)
	selectAll:SetPoint("LEFT", generate, "RIGHT", 8, 0)
	selectAll:SetText("Select All")
	selectAll:Disable()

	local status = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	status:SetPoint("TOPLEFT", generate, "BOTTOMLEFT", 0, -2)
	status:SetTextColor(0.6, 0.6, 0.6)

	-- Wrap instead of chaining forever. Four buttons in one row ran off the
	-- right edge of the settings panel, which is a fixed width -- the last one
	-- was half outside the window and unclickable.
	local ROW_WIDTH = 560
	local prev, rowUsed = selectAll, 150 + 8 + 110 + 8
	-- wrapped rows start BELOW the status line, which already sits under the
	-- first row
	local rowAnchor, lastRow = status, nil
	for _, e in ipairs(exports) do
		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetSize(140, 24)
		if rowUsed + 140 > ROW_WIDTH then
			b:SetPoint("TOPLEFT", rowAnchor, "BOTTOMLEFT", 0, -6)
			rowAnchor, rowUsed, lastRow = b, 140 + 8, b
		else
			b:SetPoint("LEFT", prev, "RIGHT", 8, 0)
			rowUsed = rowUsed + 140 + 8
		end
		b:SetText(e[1])
		b:SetScript("OnClick", function() MM:Fire(e[2]) end)
		prev = b
	end

	local box = CreateFrame("Frame", nil, panel, "BackdropTemplate")
	-- below whatever the last row turned out to be, so adding a button never
	-- pushes one under the text box again
	box:SetPoint("TOPLEFT", lastRow or generate, "BOTTOMLEFT", 0, -12)
	box:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -16, 16)
	box:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 14,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	box:SetBackdropColor(0.03, 0.03, 0.05, 0.9)

	local scroll = CreateFrame("ScrollFrame", "MasterMountsDiagScroll", box,
		"UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 8, -8)
	scroll:SetPoint("BOTTOMRIGHT", -30, 8)

	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetAutoFocus(false)
	edit:SetFontObject("ChatFontNormal")
	edit:SetWidth(560)
	edit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	-- Read-only in effect: typing would corrupt a report someone is about to
	-- paste, and there is nothing useful to type here.
	edit:SetScript("OnTextChanged", function(self, userInput)
		if userInput and self.mmText then self:SetText(self.mmText) end
	end)
	scroll:SetScrollChild(edit)
	edit:SetText("Click Generate report.")

	panel:SetScript("OnSizeChanged", function(_, w)
		edit:SetWidth(math.max(200, (w or 600) - 90))
	end)

	generate:SetScript("OnClick", function(self)
		self:Disable()
		selectAll:Disable()
		status:SetText("collecting — waiting for the server to answer...")
		edit:SetText("Running every check. This takes a few seconds.")
		MM.Diagnostics.Generate(function(text)
			edit.mmText = text
			edit:SetText(text)
			edit:SetCursorPosition(0)
			self:Enable()
			selectAll:Enable()
			local _, newlines = text:gsub("\n", "\n")
			status:SetText(("%d lines — Select All, then Ctrl+C"):format(newlines + 1))
		end)
	end)

	selectAll:SetScript("OnClick", function()
		edit:SetFocus()
		edit:HighlightText()
	end)

	return panel
end

MM:On("MM_LOGIN", function()
	C_Timer.After(5, function()
		local panel = buildPanel()
		if Settings and Settings.RegisterCanvasLayoutCategory then
			local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
			Settings.RegisterAddOnCategory(category)
			MM.optionsCategory = category
			if Settings.RegisterCanvasLayoutSubcategory then
				local weights = buildWeights()
				pcall(Settings.RegisterCanvasLayoutSubcategory, category, weights, weights.name)
				local travel = buildTravel()
				pcall(Settings.RegisterCanvasLayoutSubcategory, category, travel, travel.name)
				local diag = buildDiagnostics()
				pcall(Settings.RegisterCanvasLayoutSubcategory, category, diag, diag.name)
			end
		elseif InterfaceOptions_AddCategory then
			InterfaceOptions_AddCategory(panel)
		end
	end)
end)

-- Open our settings page from the gear button / minimap menu.
function MM.OpenOptions()
	if Settings and Settings.OpenToCategory and MM.optionsCategory then
		local id = MM.optionsCategory.GetID and MM.optionsCategory:GetID() or MM.optionsCategory.ID
		if pcall(Settings.OpenToCategory, id) then return end
	end
	if InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory("Master Mounts")
		InterfaceOptionsFrame_OpenToCategory("Master Mounts") -- classic double-call quirk
	else
		MM:Print("Options: Game Menu > Options > AddOns > Master Mounts")
	end
end
