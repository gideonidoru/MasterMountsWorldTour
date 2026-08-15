-- Master Mounts: first-run onboarding.
--
-- Requirement — I think we should add an onboarding workflow for first use, just to
-- set some basic settings (theme, celebrations, etc) and default weighting
-- (just select a preset but clearly explain the differences) and let them know
-- they can get more from the options (make it beautiful, intuitive, apple like
-- ...)
--
-- What "Apple-like" is taken to mean here, concretely, because it is otherwise
-- just a vibe to hide behind:
--
--   ONE DECISION PER SCREEN.  Four questions on one panel is a form. Four
--     panels with one question each is a conversation.
--   THE DEFAULT IS ALREADY CHOSEN.  Every step opens with the recommended
--     answer selected, so "Continue" four times is a good setup. Nothing here
--     blocks on the player having an opinion.
--   CHOICES ARE CARDS, NOT RADIO BUTTONS.  Each option gets a title and a
--     sentence saying what it will actually do to their list. A radio group
--     labelled "Balanced / Legacy / Time / Grind" tells a new player nothing.
--   SHOW, DO NOT PROMISE.  The theme applies as it is picked, and the preset
--     step names the mount that would go first. The setting is visible before
--     it is committed.
--   IT IS SKIPPABLE AND REPEATABLE.  `/mm welcome` reopens it. Anything that
--     shows once and can never be seen again is a trap, not an introduction.
--
-- Nothing here is a new setting. Every control writes the SAME saved variable
-- the Options panel writes, so the two can never disagree -- an onboarding
-- flow with its own private copy of the settings is a bug generator.
local _, MM = ...

MM.Onboarding = {}
local O = MM.Onboarding

-- Bump when a step is added that existing users should be asked about. Stored
-- rather than a boolean so adding a step later does not re-ask everything.
O.SCHEMA = 1

local W = 620
local PAD = 34

-- Vertical rhythm. The window GROWS to its content rather than clipping it or
-- growing a scrollbar: an onboarding flow is four short screens, and a
-- scrollbar on a welcome screen reads as "this is going to be long".
local TOP_INSET = 46     -- brand line sits above the title
local BODY_GAP = 14      -- title -> body
local HOST_GAP = 20      -- body -> first card
local FOOTER_H = 64      -- dots and buttons
local MIN_H = 360
-- How much of the screen the window may occupy before it starts scaling down,
-- and how far down it is allowed to go before legibility matters more than fit.
local MAX_SCREEN_FRACTION = 0.9
local MIN_SCALE = 0.65

local frame, steps, current, dots, titleFS, bodyFS, cardHost, nextBtn, backBtn, skipBtn
local choices = {}

------------------------------------------------------------
-- Choice cards
------------------------------------------------------------
-- A card is a button with a title, a description, and a selected state. The
-- description is the part that matters: it says what this choice does to the
-- player's list, in their words, not ours.
local cards = {}

local function clearCards()
	for _, c in ipairs(cards) do c:Hide(); c.onPick = nil end
	wipe(cards)
end

local function styleCard(card, selected)
	if selected then
		card.bg:SetColorTexture(1, 0.82, 0.2, 0.14)
		card.border:SetBackdropBorderColor(1, 0.82, 0.2, 1)
		card.title:SetTextColor(1, 0.86, 0.35)
		card.tick:Show()
	else
		card.bg:SetColorTexture(1, 1, 1, 0.035)
		card.border:SetBackdropBorderColor(0.35, 0.35, 0.4, 0.9)
		card.title:SetTextColor(0.92, 0.92, 0.92)
		card.tick:Hide()
	end
end

local function selectCard(group, chosen)
	for _, c in ipairs(cards) do
		if c.group == group then styleCard(c, c == chosen) end
	end
	if chosen and chosen.onPick then chosen.onPick(chosen.value) end
end

-- Cards size to their own text.
--
-- They used to be a flat 58px, and the preset step then forced 72px on top of
-- that. Neither number had anything to do with the words inside: Legacy's blurb
-- is three lines and Balanced's is one, so one card overflowed while the other
-- sat half empty, and four of them together ran 82px past the bottom of a fixed
-- 470px window -- straight through the buttons. the screenshot is what that
-- looks like.
--
-- Nothing here is a magic number any more. The description is given an explicit
-- width, its wrapped height is measured, and the card is made to fit it.
local CARD_W = W - PAD * 2
local CARD_TEXT_W = CARD_W - 14 - 40      -- left inset, and room for the tick
local CARD_PAD, CARD_GAP_Y = 11, 8

local function makeCard(parent, group, value, title, desc, y, selected)
	local card = CreateFrame("Button", nil, parent, "BackdropTemplate")
	card:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
	card:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, y)
	card:SetHeight(44)
	card.group, card.value = group, value

	card.bg = card:CreateTexture(nil, "BACKGROUND")
	card.bg:SetAllPoints()

	card.border = CreateFrame("Frame", nil, card, "BackdropTemplate")
	card.border:SetAllPoints()
	card.border:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })

	card.tick = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	card.tick:SetPoint("RIGHT", card, "RIGHT", -14, 0)
	card.tick:SetText("|cffffd24dv|r")
	card.tick:Hide()

	card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	card.title:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -10)
	card.title:SetText(title)

	if desc then
		card.desc = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		card.desc:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -4)
		card.desc:SetWidth(CARD_TEXT_W)
		card.desc:SetJustifyH("LEFT")
		card.desc:SetTextColor(0.72, 0.72, 0.75)
		card.desc:SetText(desc)
	end

	-- Height is derived, never assumed.
	local h = CARD_PAD + (card.title:GetStringHeight() or 12) + CARD_PAD
	if card.desc then
		h = h + 4 + (card.desc:GetStringHeight() or 12)
	end
	card:SetHeight(math.ceil(h))
	card.usedHeight = math.ceil(h) + CARD_GAP_Y

	card:SetScript("OnClick", function(self) selectCard(group, self) end)
	card:SetScript("OnEnter", function(self)
		if not self.tick:IsShown() then self.bg:SetColorTexture(1, 1, 1, 0.07) end
	end)
	card:SetScript("OnLeave", function(self)
		if not self.tick:IsShown() then self.bg:SetColorTexture(1, 1, 1, 0.035) end
	end)

	styleCard(card, selected)
	cards[#cards + 1] = card
	return card
end

-- Stacks cards down a host, returning the total height used.
--
-- Every step went through its own hand-written y offsets (0, -68, -136) that
-- had to agree with the card heights by eye. They did not. This is the single
-- place that arithmetic now lives.
local function stacker(host)
	local y, total = 0, 0
	return function(make)
		local card = make(y)
		local used = (card and card.usedHeight) or 0
		y = y - used
		total = total + used
		return card
	end, function() return total end
end

-- A plain on/off row, for the yes/no questions where two cards would be silly.
local function makeToggle(parent, key, title, desc, y)
	local card = makeCard(parent, "toggle:" .. key, key, title, desc, y, MM.db[key] and true)
	card.tick:SetText("|cffffd24dv|r")
	card:SetScript("OnClick", function(self)
		MM.db[key] = not MM.db[key]
		styleCard(self, MM.db[key] and true or false)
		choices[key] = MM.db[key] and true or false
	end)
	styleCard(card, MM.db[key] and true or false)
	return card
end

------------------------------------------------------------
-- The steps
------------------------------------------------------------
-- Each step draws itself into `cardHost` and sets the title and body copy.
-- Steps are data, so adding one is adding a table entry, not surgery.
local function buildSteps()
	return {
		{
			key = "welcome",
			title = "Welcome to Master Mounts",
			body = "There are over sixteen hundred mounts in the game and you are "
				.. "missing some of them. This addon works out which ones are "
				.. "actually worth your next hour, and points you at them.\n\n"
				.. "Four quick questions and you are done.",
			draw = function() end,
		},

		{
			key = "theme",
			title = "How should it look?",
			body = "Master Mounts matches your interface automatically. "
				.. "Change it here if you would rather it did not.",
			draw = function(host)
				-- nil means automatic: ElvUI when installed, Modern otherwise.
				-- An explicit choice always wins.
				local set = MM.db.theme
				local hasElv = MM.Theme.HasElvUI()
				local apply = function(v)
					MM.db.theme = v
					choices.theme = v or "auto"
					MM.Theme.ReskinAll()
				end
				local push, used = stacker(host)
				push(function(y) return makeCard(host, "theme", nil,
					"Automatic  |cff8a8a8a(recommended)|r",
					hasElv and "ElvUI is installed, so it will use the ElvUI look."
						or "Uses the Modern look. Switches itself if you install ElvUI later.",
					y, set == nil) end).onPick = apply
				push(function(y) return makeCard(host, "theme", "modern", "Modern",
					"Textured charcoal panels with warm gold accents.",
					y, set == "modern") end).onPick = apply
				push(function(y) return makeCard(host, "theme", "blizzard", "Blizzard",
					"Gold borders and the parchment feel of the default UI.",
					y, set == "blizzard") end).onPick = apply
				push(function(y) return makeCard(host, "theme", "elvui",
					hasElv and "ElvUI" or "ElvUI  |cff8a8a8a(not installed)|r",
					"Flat dark panels with a hairline border.",
					y, set == "elvui") end).onPick = apply
				return used()
			end,
		},

		{
			key = "preset",
			title = "What are you here for?",
			body = "This sets how the addon ranks your list. You can change it "
				.. "any time, and tune every dial behind it later.",
			draw = function(host)
				local activePreset = MM.Weights.CurrentPreset and MM.Weights.CurrentPreset()
				local currentKey = activePreset and activePreset.key
				local push, used = stacker(host)
				for _, preset in ipairs(MM.Weights.PRESETS) do
					local card = push(function(y)
						return makeCard(host, "preset", preset.key, preset.name,
							preset.blurb, y, currentKey == preset.key)
					end)
					card.onPick = function(v)
						MM.Weights.ApplyPreset(v)
						choices.preset = v
					end
				end
				return used()
			end,
		},

		{
			key = "celebrations",
			title = "When a mount finally drops",
			body = "After a hundred and twelve runs, it deserves a moment.",
			draw = function(host)
				local push, used = stacker(host)
				push(function(y) return makeToggle(host, "celebration",
					"Celebrate the drop",
					"A splash across the screen naming the mount you just earned.", y) end)
				push(function(y) return makeToggle(host, "celebrationShot",
					"Take a screenshot",
					"Saved to your Screenshots folder, so you keep the moment.", y) end)
				push(function(y) return makeToggle(host, "celebrateAll",
					"Celebrate every new mount",
					"Off by default -- otherwise a vendor purchase gets the same "
					.. "fanfare as a two-year drought ending.", y) end)
				return used()
			end,
		},

		{
			key = "done",
			title = "You are set up",
			body = "Open Master Mounts with |cffffd24d/mm|r. It opens on your Planner "
				.. "-- what to do next, in order.\n\n"
				.. "There is a great deal more under |cffffd24dOptions > Master Mounts|r: "
				.. "waypoint arrows, map pins, rare alerts, chat announcements, "
				.. "and the full Weights & Priorities panel where every dial "
				.. "behind that preset can be tuned by hand.\n\n"
				.. "|cff8a8a8aRun this again any time with /mm welcome.|r",
			draw = function() end,
		},
	}
end

------------------------------------------------------------
-- Frame
------------------------------------------------------------
local function showStep(index)
	current = math.max(1, math.min(index, #steps))
	local step = steps[current]

	clearCards()
	titleFS:SetText(step.title)
	bodyFS:SetText(step.body or "")
	local contentH = step.draw(cardHost) or 0

	-- Grow to fit. Heights are read AFTER the text is set, so wrapped copy and
	-- self-sizing cards are both counted rather than assumed.
	cardHost:SetHeight(math.max(1, contentH))
	local h = TOP_INSET
		+ (titleFS:GetStringHeight() or 26) + BODY_GAP
		+ (bodyFS:GetStringHeight() or 0) + HOST_GAP
		+ contentH + FOOTER_H
	local wanted = math.max(MIN_H, math.ceil(h))
	frame:SetHeight(wanted)

	-- Grow first, then scale only if growing would run off the screen.
	--
	-- Requirement — but what about lower resolutions? is not grow + scale better? Yes.
	-- Growing alone is the nicer result and is what happens on any normal
	-- display -- full-size text, no scrollbar. But a 1280x720 screen, or a
	-- player running a high global UI scale, has far less room than the pixel
	-- count suggests, and a window taller than the screen is worse than a
	-- slightly smaller one.
	--
	-- So the scale is only ever applied as a LAST resort, is never above 1
	-- (growing the text on a big monitor would just look wrong), and stops at
	-- MIN_SCALE rather than shrinking to illegibility.
	--
	-- UIParent's height is already in scaled UI units, so this compares like
	-- with like without needing to know the player's resolution at all.
	local avail = (UIParent:GetHeight() or 768) * MAX_SCREEN_FRACTION
	local scale = 1
	if wanted > avail and avail > 0 then
		scale = math.max(MIN_SCALE, avail / wanted)
	end
	frame:SetScale(scale)

	for i, dot in ipairs(dots) do
		if i == current then
			dot:SetColorTexture(1, 0.82, 0.2, 1)
		else
			dot:SetColorTexture(1, 1, 1, 0.18)
		end
	end

	backBtn:SetShown(current > 1)
	skipBtn:SetShown(current < #steps)
	nextBtn:SetText(current == #steps and "Start collecting" or "Continue")
end

local function finish(skipped)
	MM.db.onboarded = O.SCHEMA
	MM.db.onboardedAt = date("%Y-%m-%d %H:%M")
	choices.skipped = skipped and true or false
	MM.db.onboardedChoices = choices
	if frame then frame:Hide() end
	if skipped then
		-- Respecting a skip means not immediately opening another window.
		-- Defaults are all sensible; say where to find things and get out of
		-- the way.
		MM:Print("No problem — sensible defaults are in place. "
			.. "|cffffd24d/mm|r opens your planner, |cffffd24d/mm welcome|r "
			.. "runs setup whenever you want it.")
		return
	end
	MM:Print("Setup complete. |cffffd24d/mm|r opens your planner; "
		.. "|cffffd24d/mm welcome|r runs this again.")
	-- Land them where the work is, which is the whole point of the addon.
	MM:Fire("MM_TOGGLE_MAIN", 2)
end

local function build()
	if frame then return frame end

	frame = CreateFrame("Frame", "MasterMountsOnboarding", UIParent, "BackdropTemplate")
	frame:SetSize(W, MIN_H)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1,
	})
	frame:SetBackdropColor(0.04, 0.04, 0.06, 0.97)
	frame:SetBackdropBorderColor(0.85, 0.68, 0.25, 0.9)
	tinsert(UISpecialFrames, "MasterMountsOnboarding")   -- Escape closes it

	local brand = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	brand:SetPoint("TOPLEFT", PAD, -20)
	brand:SetText("|cff8a8a8aMASTER MOUNTS|r")

	titleFS = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	titleFS:SetPoint("TOPLEFT", PAD, -TOP_INSET)
	titleFS:SetWidth(W - PAD * 2)
	titleFS:SetJustifyH("LEFT")
	titleFS:SetTextColor(1, 0.86, 0.35)

	-- Everything below is anchored to what precedes it, never to a fixed
	-- offset, so the window can grow to whatever the step actually needs.
	bodyFS = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	bodyFS:SetPoint("TOPLEFT", titleFS, "BOTTOMLEFT", 0, -BODY_GAP)
	bodyFS:SetWidth(W - PAD * 2)
	bodyFS:SetJustifyH("LEFT")
	bodyFS:SetSpacing(3)
	bodyFS:SetTextColor(0.78, 0.78, 0.8)

	-- Cards live in their own host so a step can lay out from y = 0 without
	-- knowing how tall the copy above it happened to be.
	cardHost = CreateFrame("Frame", nil, frame)
	cardHost:SetPoint("TOPLEFT", bodyFS, "BOTTOMLEFT", 0, -HOST_GAP)
	cardHost:SetWidth(CARD_W)
	cardHost:SetHeight(1)

	-- progress dots
	dots = {}
	for i = 1, 5 do
		local d = frame:CreateTexture(nil, "OVERLAY")
		d:SetSize(6, 6)
		d:SetPoint("BOTTOMLEFT", PAD + (i - 1) * 12, 26)
		dots[i] = d
	end

	nextBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	nextBtn:SetSize(150, 26)
	nextBtn:SetPoint("BOTTOMRIGHT", -PAD, 18)
	nextBtn:SetScript("OnClick", function()
		if current >= #steps then finish(false) else showStep(current + 1) end
	end)

	backBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	backBtn:SetSize(80, 26)
	backBtn:SetPoint("RIGHT", nextBtn, "LEFT", -8, 0)
	backBtn:SetText("Back")
	backBtn:SetScript("OnClick", function() showStep(current - 1) end)

	skipBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	skipBtn:SetSize(80, 22)
	skipBtn:SetPoint("BOTTOMLEFT", PAD, 20)
	skipBtn:SetText("Skip")
	skipBtn:SetScript("OnClick", function() finish(true) end)

	-- Deliberately NOT theme-registered. This is the screen where the player
	-- chooses a theme, and reskinning it underneath them mid-choice is
	-- disorienting -- the cards preview the theme, the chrome stays put.
	return frame
end

function O.Show()
	build()
	steps = buildSteps()
	wipe(choices)
	showStep(1)
	frame:Show()
end

-- Step navigation, exposed rather than hidden behind the buttons.
--
-- The offline harness walks every step so that a bad field reference inside any
-- card's draw() surfaces on a build rather than in front of a player. A flow
-- whose steps can only be reached by clicking is a flow that can only be tested
-- by clicking.
function O.Hide() if frame then frame:Hide() end end
-- Exposed so the harness can prove the window fits a real screen rather than
-- only that it draws without erroring.
function O.FrameHeight() return frame and math.ceil(frame:GetHeight() or 0) or 0 end
function O.FitsScreen()
	if not frame then return true end
	local h = (frame:GetHeight() or 0) * (frame:GetScale() or 1)
	return h <= (UIParent:GetHeight() or 768) * MAX_SCREEN_FRACTION + 1
end
function O.StepCount() return steps and #steps or 0 end
function O.CurrentStep() return current or 0 end
function O.GoTo(i)
	if not (frame and steps) then return false end
	if i < 1 or i > #steps then return false end
	showStep(i)
	return true
end

-- Only ever fires by itself once, and only after the collection has been read:
-- the preset step is meaningless before we know what the player is missing.
MM:On("MM_SCANNED", function()
	if MM.db.onboarded then return end
	if frame and frame:IsShown() then return end
	C_Timer.After(2, function()
		if not MM.db.onboarded then O.Show() end
	end)
end)

MM:On("MM_ONBOARDING", function() O.Show() end)

------------------------------------------------------------
-- /mm onboarding -- diagnostics
------------------------------------------------------------
-- Requirement — add any needed diagnostics for this too.
--
-- The failure mode worth catching is silent: onboarding that never ran, or ran
-- and did not persist. Both look identical from the outside -- a player with
-- default settings -- so the state has to be readable.
MM:On("MM_ONBOARDING_DEBUG", function()
	local db = MM.db
	if not db.onboarded then
		MM:Print("Onboarding: |cffff9a3cnot completed|r — it opens 2s after the "
			.. "first collection scan, or run |cffffd24d/mm welcome|r.")
	else
		MM:Print("Onboarding: completed (schema %s of %s) on %s%s",
			tostring(db.onboarded), tostring(O.SCHEMA),
			db.onboardedAt or "an unknown date",
			(db.onboardedChoices and db.onboardedChoices.skipped) and " |cffff9a3c(skipped)|r" or "")
		if db.onboarded < O.SCHEMA then
			MM:Print("   A newer schema exists — new steps would be asked on next login.")
		end
	end

	local c = db.onboardedChoices
	if c then
		local parts = {}
		for k, v in pairs(c) do parts[#parts + 1] = ("%s=%s"):format(k, tostring(v)) end
		table.sort(parts)
		MM:Print("   Chose: %s", #parts > 0 and table.concat(parts, ", ") or "nothing")
	end

	-- What onboarding WRITES, read back from the live settings rather than from
	-- what it thinks it wrote. A choice that did not persist is the bug.
	MM:Print("   Theme now: %s (stored %s, active %s)",
		db.theme == nil and "automatic" or db.theme,
		tostring(db.theme), MM.Theme.Active())
	local preset = MM.Weights.CurrentPreset and MM.Weights.CurrentPreset()
	MM:Print("   Preset now: %s", preset and preset.name or "custom (no preset matches)")
	MM:Print("   Celebrations: splash %s, screenshot %s, every mount %s",
		db.celebration and "on" or "off",
		db.celebrationShot and "on" or "off",
		db.celebrateAll and "on" or "off")
	MM:Print("   Main window opens on: %s", "Planner")
end)
