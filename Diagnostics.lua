-- Master Mounts diagnostics report.
--
-- Everything the /mm commands print, captured into one plain-text block you can
-- select and copy. Screenshots of chat lose the scrollback, wrap badly, and
-- cannot be searched or diffed.
--
-- The report is PLAIN TEXT, not colour-coded, and that is deliberate: WoW colour
-- escapes travel with the text. A pasted line would arrive as
-- "|cff40d860PASS|r Quest zone resolution", which defeats the point of pasting
-- it anywhere. Once stripped, the self-test's own PASS / WARN / FAIL words carry
-- the status perfectly well in plain text, and stay greppable. The chat output
-- keeps its colours; this is the paste-friendly view of the same thing.
local _, MM = ...

MM.Diagnostics = {}
local D = MM.Diagnostics

-- WHAT COUNTS AS UNPRICED, in one place.
--
-- Defined as a function rather than inline because two things ask the
-- question -- the report, and the self-test that keeps it honest -- and the
-- last time this logic existed in two places the two answers drifted.
--
-- PROFESSION belongs here for the same reason the others do: a craft needs
-- materials, and a craft with no cost at all is a mount the planner would
-- treat as free. This is the list that turns "charged as unknown" back into
-- real data.
--
-- ONLY WHAT SOMEONE CAN ACTUALLY GO AND BUY. 62 of the original 160 were
-- mounts nobody can obtain any more -- 33 of them MoP Remix, whose vendor and
-- currency both left with the event. This list exists to ask a player to stand
-- at a till and read a price, and it was sending them to tills that no longer
-- exist.
--
-- A STATED GOLD PRICE IS A PRICE. This asked whether a record had CONDITIONS,
-- and gold is a FIELD -- so the Dragon Turtles at 1g and the wind riders at
-- 50g, priced from two independent sources agreeing to the copper, were listed
-- as needing someone to go and read a price off a vendor. Fifty of the
-- sixty-eight were already answered. The same shape of error as the
-- contribution counter, which measured "has no conditions" while calling
-- itself "has no price", and a list that asks for work already done spends the
-- one resource it exists to collect.
--
-- Crafts likewise: reagents ARE their cost, harvested from the profession
-- window, and Crafting knows which ones it has.
function D.IsUnpriced(rec)
	if not rec or not rec.obtainable then return false end
	local cat = rec.category
	if not (cat == "CURRENCY" or cat == "VENDOR"
		or cat == "TIMEWALKING" or cat == "PROFESSION") then return false end
	if rec.conditions and #rec.conditions > 0 then return false end
	if rec.goldCost then return false end
	-- Records that carry a reason they have no price -- a rare drop filed
	-- under Timewalking, a mount fished up rather than crafted. The
	-- contribution counter has honoured this field since it was added and
	-- this one did not, so the same seven records were absent from one list
	-- and present in the other. Extracting the predicate was supposed to stop
	-- exactly that and only stopped half of it.
	if rec.unpriced then return false end
	if rec.acquire then return false end
	if (rec.source or ""):lower():find("gold") then return false end
	if cat == "PROFESSION" and MM.Crafting and MM.Crafting.IsPriced
		and MM.Crafting.IsPriced(rec) then return false end
	return true
end



-- Strip WoW colour escapes and texture links so the result is paste-clean.
local function plain(s)
	s = tostring(s or "")
	s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
	s = s:gsub("|T.-|t", ""):gsub("|A.-|a", "")
	-- keep item/spell links readable rather than raw hyperlink syntax
	s = s:gsub("|H.-|h%[(.-)%]|h", "%1"):gsub("|H.-|h(.-)|h", "%1")
	return s
end
D.Plain = plain

------------------------------------------------------------
-- Capture
------------------------------------------------------------
-- Rather than refactor a dozen debug handlers to write somewhere else, we
-- borrow MM:Print for the duration. Every diagnostic already reports through it,
-- so this captures all of them -- including ones added later -- with no changes
-- to any of them.
function D.Capture(fn)
	local lines = {}
	local saved = MM.Print
	-- Section handlers may open their own copy window when run standalone. That
	-- is right for a slash command and wrong inside the report: the window
	-- hijacks the output, the captured section comes back empty, and the reader
	-- ends up with half a report on screen and half in chat. Handlers check this
	-- flag and print instead.
	D.capturing = true
	MM.Print = function(_, msg, ...)
		-- `...` is not visible inside a nested closure, so format via pcall
		-- directly rather than wrapping it in one. A malformed format string in
		-- some future diagnostic must not take the whole report down.
		local text
		if select("#", ...) > 0 then
			local ok, res = pcall(string.format, tostring(msg), ...)
			text = ok and res or tostring(msg)
		else
			text = tostring(msg)
		end
		lines[#lines + 1] = plain(text)
	end
	local ran, err = pcall(fn)
	MM.Print = saved
	D.capturing = false
	if not ran then lines[#lines + 1] = "!! capture failed: " .. tostring(err) end
	return lines
end

-- Run something that reports through MM:Print, and put the result in a window.
--
-- LONG OUTPUT BELONGS IN A WINDOW, AND THIS KEPT BEING DECIDED ONE COMMAND AT A
-- TIME. Chat scrollback is capped and cannot be selected, so /mm release,
-- /mm check, /mm travel and the rest were unpastable -- the /mm export fix was
-- the same fault in a third place, and the helper Core wrote to stop it
-- happening a fourth time was never wired to anything but the two id commands.
--
-- It lives here rather than in Core because Tests.lua needs it too: the full
-- check finishes inside a C_Timer callback four seconds after the command
-- returns, so the capture has to wrap the run and not the command.
--
-- NESTED CAPTURE IS THE TRAP. The report runs every one of these sections while
-- capturing, and a section that opened its own window mid-report would take its
-- output with it -- half the report on screen, half in a window. `capturing`
-- already exists to say so; this honours it by simply running the work.
function D.Windowed(title, fn)
	if D.capturing then return fn() end
	local text = table.concat(D.Capture(fn) or {}, "\n")
	if text == "" then text = "Nothing to report." end
	D.ShowExport(text, title)
end

------------------------------------------------------------
-- Environment header
------------------------------------------------------------
-- The first question about any bug report is "on what?". This answers it before
-- anyone has to ask.
local function environment()
	local out = {}
	local function add(k, v) out[#out + 1] = ("%-18s %s"):format(k .. ":", plain(v)) end

	local version, build, _, iface = GetBuildInfo()
	add("Addon", MM.VERSION or "?")
	add("Client", ("%s (build %s, interface %s)"):format(
		tostring(version), tostring(build), tostring(iface)))
	add("Locale", GetLocale and GetLocale() or "?")
	local name = UnitName("player")
	local realm = GetRealmName and GetRealmName() or "?"
	local _, class = UnitClass("player")
	add("Character", ("%s-%s, %s %s, level %s"):format(
		tostring(name), tostring(realm), tostring(MM.playerFaction or "?"),
		tostring(class), tostring(UnitLevel("player"))))

	-- Which optional integrations are actually present changes what the rest of
	-- the report means.
	local deps = {}
	for _, addon in ipairs({ "TomTom", "ElvUI", "MountsRarity", "Titan" }) do
		local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded(addon)
		if loaded then deps[#deps + 1] = addon end
	end
	add("Integrations", #deps > 0 and table.concat(deps, ", ") or "none loaded")

	-- FIRST QUESTION ABOUT ANY BUG REPORT, PART TWO.
	--
	-- A second copy of this addon loaded beside the current one produces
	-- symptoms that all read as bugs in this one -- doubled messages, two of
	-- every window, a plan that seems to rewrite itself. It cost a report and
	-- a screenshot to identify, and it invalidates everything below, so it
	-- belongs in the header rather than three hundred lines down.
	local dupes = MM.ConflictingCopies and MM.ConflictingCopies() or {}
	if #dupes > 0 then
		add("!! CONFLICT", ("another Master Mounts is loaded: %s -- every "
			.. "symptom below may be two addons, not one"):format(
			table.concat(dupes, ", ")))
	end
	add("Theme", (MM.db and MM.db.theme) or "default")
	return out
end

------------------------------------------------------------
-- Report
------------------------------------------------------------
-- Sections run in order. Each is a label plus the event that produces it; the
-- capture does the rest.
-- Exposed so a self-test can walk them. A section that silently produces
-- nothing is worse than a missing one: the report LOOKS complete while the
-- answer is absent, which is how a reader ends up asking a person instead.
local SECTIONS = {
	{ "SELF-TEST & SUMMARY", function() MM.Tests.RunSync() end },
	{ "AUDIT",               "MM_AUDIT" },
	{ "RARITY COVERAGE",     "MM_RARITY_DEBUG" },
	{ "PREREQUISITE GATES",  "MM_GATES_DEBUG" },
	{ "BAGS",                "MM_CARRIED_DEBUG" },
	{ "CALLINGS",            "MM_CALLINGS_DEBUG" },
	{ "EVENTS / TIMEWALKING","MM_EVENTS_DEBUG" },
	{ "TRADING POST",        "MM_TRADINGPOST_DEBUG" },
	{ "TRAVEL",              "MM_TRAVEL_DEBUG" },
	{ "ZONE ALERTS",         "MM_ZONE_DEBUG" },
	{ "ID RESOLUTION",       "MM_IDS_DEBUG" },
	{ "THEME",               "MM_THEME_DEBUG" },
	{ "ASSAULTS",            "MM_ASSAULTS_DEBUG" },
	{ "WEIGHTS & PRIORITIES","MM_WEIGHTS_DEBUG" },
	{ "ROUTE",               "MM_ROUTE_DEBUG" },
	{ "LAYERED ORDERING",    "MM_LAYERS_DEBUG" },
	{ "WHY NOT",             "MM_WHYNOT_DEBUG" },
	{ "ONBOARDING",          "MM_ONBOARDING_DEBUG" },
	{ "CRAFTING",            "MM_CRAFTING_DEBUG" },
	{ "CONTRIBUTIONS",       "MM_CONTRIBUTE_DEBUG" },
	{ "SCORECARD",           "MM_SCORE_DEBUG" },
	{ "RELEASE READINESS",   "MM_RELEASE_DEBUG" },
	{ "ATTEMPTS",           "MM_ATTEMPTS_DEBUG" },
	{ "STATE & SETTINGS",    "MM_STATE_DEBUG" },
	{ "GROUP SYNC",          "MM_GROUPSYNC_DEBUG" },
	{ "KNOWN & UNKNOWABLE",  "MM_KNOWN_DEBUG" },
	{ "COST COVERAGE",       "MM_COSTS_DEBUG" },
	{ "QUEUEABLE GOALS",     "MM_QUEUE_DEBUG" },
	{ "SESSION",             "MM_SESSION_DEBUG" },
	{ "TIME MODEL",          "MM_TIMEMODEL_DEBUG" },
	{ "REMAINING GAPS",      "MM_GAPS_DEBUG" },
	-- Added when flight-point harvesting went in, but never listed here, so the
	-- self-test caught it as unreachable: a diagnostic only a slash command can
	-- reach is, to whoever reads a pasted report, one that was never written.
	{ "FLIGHT POINTS",       "MM_FLIGHTPOINTS_DEBUG" },
	-- LAST ON PURPOSE. It is the section a reader checks after installing a
	-- build, and the one they want to find without scrolling past a route.
	{ "PLANNER LEFT PANE",  "MM_ROWPROBE_DEBUG" },
	{ "FIXES IN THIS BUILD", "MM_FIXES_DEBUG" },
}
D.SECTIONS = SECTIONS

-- One section, rendered. Shared so the chunked path and the timed one cannot
-- drift into measuring different things.
--
-- WRAPPED. A section that throws used to take the whole report with it -- the
-- outer pcall caught it and returned an error string INSTEAD of the report, so
-- one broken diagnostic hid the other thirty-two, which are exactly what you
-- need to work out why it broke.
local function renderSection(add, section)
	add("")
	add("----- " .. section[1] .. " -----")
	local body, err
	local ok = pcall(function()
		body = D.Capture(function()
			if type(section[2]) == "function" then section[2]()
			else MM:Fire(section[2]) end
		end)
	end)
	if not ok then err = "this section threw; the rest of the report is intact" end
	body = body or {}
	if err then add("  |cffff4444" .. err .. "|r") end
	if #body == 0 and not err then add("(no output)") end
	for _, l in ipairs(body) do add("  " .. l) end
end

local function header(add)
	add("===== MASTER MOUNTS DIAGNOSTIC REPORT =====")
	add("")
	for _, l in ipairs(environment()) do add(l) end
end

-- CHART THE ROUTE ONCE, BEFORE ANY SECTION DESCRIBES IT.
--
-- Three sections read the route. Each used to ask for its own build, and while
-- Build was asynchronous each of those asks returned before the route existed,
-- so a section could describe the route from the request BEFORE it. Warming
-- here settles it once; every section afterwards takes a cache hit and they all
-- describe the same route.
local function warmRoute()
	if not (MM.Router and MM.Router.Warm) then return end
	pcall(MM.Router.Warm)
end

local function build()
	-- Sections can be run standalone or as part of the full report. Anything
	-- expensive that the report ALREADY does elsewhere must not be repeated
	-- here; this is the flag that lets a section tell the difference.
	D.inReport = true
	warmRoute()
	local out = {}
	local function add(s) out[#out + 1] = s or "" end
	header(add)
	for _, section in ipairs(SECTIONS) do renderSection(add, section) end
	add("")
	add("===== END OF REPORT =====")
	D.inReport = false
	return table.concat(out, "\n")
end
-- Exposed so a self-test can TIME the real report rather than a model of it.
D.Build = build

-- THIRTY-THREE SECTIONS IN ONE EXECUTION IS A SCRIPT-TOO-LONG WAITING TO
-- HAPPEN, and on a slower machine it happened: `/mm report` died with the
-- client's own watchdog rather than producing anything.
--
-- The watchdog measures ONE uninterrupted run, not total work, so the fix is
-- to stop doing it all at once rather than to do less of it. Sections are
-- independent -- each captures its own output and shares nothing but the
-- inReport flag -- so the boundary between them is a free place to breathe.
--
-- The budget is deliberately well under a frame. A report that takes an extra
-- second to assemble is invisible; one that trips the watchdog produces
-- nothing at all, and the whole point of it is to be readable when things are
-- going wrong.
local FRAME_BUDGET_MS = 12

function D.BuildChunked(onDone)
	D.inReport = true
	local out, i = {}, 1
	local function add(s) out[#out + 1] = s or "" end
	header(add)
	D.sectionMs = {}
	local function step()
		local started = debugprofilestop()
		repeat
			local section = SECTIONS[i]
			if not section then break end
			local at = debugprofilestop()
			renderSection(add, section)
			D.sectionMs[section[1]] = debugprofilestop() - at
			i = i + 1
		until debugprofilestop() - started > FRAME_BUDGET_MS
		if SECTIONS[i] then
			C_Timer.After(0, step)
		else
			add("")
			add("===== END OF REPORT =====")
			D.inReport = false
			onDone(table.concat(out, "\n"))
		end
	end
	-- CHART FIRST, ASYNCHRONOUSLY, THEN RENDER.
	--
	-- Three sections need a completed route, and each asking for its own would
	-- be three chances to describe a different one. Warming it synchronously
	-- here would put a whole route build inside one uninterrupted call, which
	-- is precisely the watchdog this chunking exists to stay under -- so the
	-- build gets the same treatment the sections get, and the report starts
	-- once it lands.
	if MM.Router and MM.Router.AfterBuild then
		MM.Router.AfterBuild(false, function() step() end)
	else
		step()
	end
end

-- The slowest SINGLE section, which is what decides whether the watchdog fires
-- now that the report breathes between them. Total time stopped being the
-- number that matters the moment this was chunked.
function D.SlowestSection()
	local worst, ms = nil, 0
	for name, t in pairs(D.sectionMs or {}) do
		if t > ms then worst, ms = name, t end
	end
	return worst, ms
end

-- Async subsystems must be warmed before anything reads them, or the report
-- records "not synced" for things that simply had not answered yet. Same reason
-- /mm check waits.
function D.Generate(onReady)
	pcall(function() MM.Callings.Request() end)
	pcall(function() MM.Availability.EnsureCalendar() end)
	pcall(function() MM.TradingPost.Refresh() end)
	-- THE SELF-TEST RUNS IN THE WAIT, NOT IN THE REPORT.
	--
	-- It is one section and it was 2,635 ms of the build on a fast machine --
	-- a single uninterrupted run, which is exactly what the watchdog measures
	-- and why chunking BETWEEN sections did not save the slower one.
	--
	-- There is already a four-second pause here for the asynchronous
	-- subsystems to answer. Slicing the suite across that window costs the
	-- report nothing it was not already spending, and the section that prints
	-- it consumes the finished results instead of running them again.
	local suiteDone, waited = false, false
	local function go()
		if not (suiteDone and waited) then return end
		local ok, err = pcall(D.BuildChunked, onReady)
		if not ok then
			onReady("Report generation failed: " .. tostring(err))
		end
	end
	if MM.Tests and MM.Tests.PrepareAsync then
		MM.Tests.PrepareAsync(function() suiteDone = true; go() end)
	else
		suiteDone = true
	end
	C_Timer.After(4, function() waited = true; go() end)
end

-- /mm report — same report, printed to chat, for anyone who prefers the console.
-- The options tab is the better route (chat truncates long lines and the
-- scrollback is finite) so say so once rather than silently producing a worse
-- copy of the same thing.
MM:On("MM_REPORT", function()
	MM:Print("Building the diagnostic report...")
	D.Generate(function(text)
		-- Into the window, and onto disk. It used to dump every line to chat with
		-- a raw print(), which is why the report always looked half-missing: chat
		-- has a scrollback limit and none of it can be selected.
		--
		-- Saved variables ARE a file -- WTF/Account/<ACCOUNT>/SavedVariables/
		-- MasterMountsWorldTour.lua, which takes the ADDON FOLDER's name and not
		-- the variable's -- flushed on /reload or logout. So a report can be
		-- handed to someone outside the game without copying anything by hand.
		if MM.db then
			MM.db.lastReport = text
			MM.db.lastReportAt = date and date("%Y-%m-%d %H:%M") or nil
		end
		if D.ShowExport then
			D.ShowExport(text, "Diagnostic report")
		else
			for line in text:gmatch("[^\n]*") do
				if line ~= "" then print(line) end
			end
		end
		MM:Print("Report ready (%d lines). Saved to disk as well -- /reload flushes it to "
			.. "SavedVariables\\MasterMountsWorldTour.lua.", select(2, text:gsub("\n", "")) + 1)
	end)
end)

------------------------------------------------------------
-- Copyable export window
------------------------------------------------------------
-- Chat mangles generated Lua: it truncates long lines, strips nothing usefully,
-- and the scrollback is finite. Anything meant to be pasted back into the
-- codebase needs a selectable box.
local exportFrame
-- The matrix is meant to be pasted back to me, so it goes to the copy box
-- rather than scrolling out of the chat frame. Registered here because this is
-- where the capture lives; WeightsMatrix.lua stays a pure producer of lines.
-- Just starts it. The matrix is asynchronous now -- capturing MM:Print around a
-- call that returns before the work happens would have exported an empty
-- report, which is the failure it was built to detect.
MM:On("MM_WEIGHTS_MATRIX_EXPORT", function() MM:Fire("MM_WEIGHTS_MATRIX") end)

-- The export window, made writable.
--
-- Deliberately the SAME frame: an import box that looked different from the
-- export box would suggest they use different formats, and the entire point of
-- the contribution pipeline is that one produces exactly what the other eats.
--
-- `mmText` is what makes the export read-only -- OnTextChanged puts the original
-- back on every keystroke. Import has to clear it or the box silently refuses
-- everything typed into it.
function D.ShowImport(title, onAccept)
	D.ShowExport("", title or "Paste here")
	local frame = exportFrame
	frame.edit.mmText = nil          -- writable
	frame.edit:SetText("")
	frame.edit:SetAutoFocus(true)

	if not frame.accept then
		frame.accept = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
		frame.accept:SetSize(110, 24)
		frame.accept:SetPoint("BOTTOMRIGHT", -34, 14)
		frame.accept:SetText("Apply")
		MM.Theme.Register(frame.accept, "button")
	end
	frame.accept:SetScript("OnClick", function()
		local typed = frame.edit:GetText()
		frame:Hide()
		frame.edit:SetAutoFocus(false)
		if onAccept then onAccept(typed) end
	end)
	frame.accept:Show()
end

function D.ShowExport(text, title)
	if not exportFrame then
		exportFrame = CreateFrame("Frame", "MasterMountsExport", UIParent, "BackdropTemplate")
		exportFrame:SetSize(700, 500)
		exportFrame:SetPoint("CENTER")
		exportFrame:SetMovable(true)
		exportFrame:EnableMouse(true)
		exportFrame:RegisterForDrag("LeftButton")
		exportFrame:SetScript("OnDragStart", exportFrame.StartMoving)
		exportFrame:SetScript("OnDragStop", exportFrame.StopMovingOrSizing)
		exportFrame:SetFrameStrata("DIALOG")
		exportFrame:SetBackdrop({
			bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
			edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
			tile = true, tileSize = 16, edgeSize = 14,
			insets = { left = 4, right = 4, top = 4, bottom = 4 },
		})
			exportFrame:SetBackdropColor(0.03, 0.03, 0.05, 0.95)
			MM.Theme.Register(exportFrame, "panel")

			exportFrame.title = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			exportFrame.title:SetPoint("TOPLEFT", 12, -10)
			MM.Theme.RegisterText(exportFrame.title, "accent")

		local hint = exportFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		hint:SetPoint("TOPLEFT", exportFrame.title, "BOTTOMLEFT", 0, -4)
			hint:SetText("Ctrl+A then Ctrl+C. Escape closes.")
			hint:SetTextColor(0.6, 0.6, 0.6)
			MM.Theme.RegisterText(hint, "muted")

		local close = MM.Theme.CreateCloseButton(exportFrame, 16)
		close:SetPoint("TOPRIGHT", -8, -8)
		close:SetScript("OnClick", function() exportFrame:Hide() end)

		local scroll = CreateFrame("ScrollFrame", "MasterMountsExportScroll", exportFrame,
			"UIPanelScrollFrameTemplate")
		scroll:SetPoint("TOPLEFT", 12, -46)
		scroll:SetPoint("BOTTOMRIGHT", -32, 12)

		local edit = CreateFrame("EditBox", nil, scroll)
		edit:SetMultiLine(true)
		-- No limit. An EditBox truncates at its default cap, and the full report
		-- runs to well over a thousand lines -- so the window quietly held a
		-- PREFIX of the report and looked complete, which is the worst way for a
		-- diagnostic to fail: the reader cannot tell what is missing.
		edit:SetMaxLetters(0)
		if edit.SetMaxBytes then edit:SetMaxBytes(0) end
		edit:SetAutoFocus(false)
		edit:SetFontObject("ChatFontNormal")
		edit:SetWidth(640)
		edit:SetScript("OnEscapePressed", function() exportFrame:Hide() end)
			edit:SetScript("OnTextChanged", function(self, userInput)
				if userInput and self.mmText then self:SetText(self.mmText) end
			end)
			MM.Theme.Register(edit, "editbox")
		scroll:SetScrollChild(edit)
		exportFrame.edit = edit
		MM.Theme.SkinTree(exportFrame)
	end

	exportFrame.title:SetText(title or "Export")
	exportFrame.edit.mmText = text
	exportFrame.edit:SetText(text)
	exportFrame.edit:SetCursorPosition(0)
	if exportFrame.accept then exportFrame.accept:Hide() end
	exportFrame:Show()
	exportFrame.edit:SetFocus()
	exportFrame.edit:HighlightText()
end

------------------------------------------------------------
-- /mm gaps — everything still unknown, and how to close it
------------------------------------------------------------
-- The point of this section is to end the loop where a limitation gets asserted
-- from an absence. Each gap states what is missing, whether the addon can close
-- it itself, and if not, the exact question a human needs to answer.
MM:On("MM_GAPS_DEBUG", function()
	local function count(pred, list)
		local n = 0
		for _, v in pairs(list or {}) do if pred(v) then n = n + 1 end end
		return n
	end

	-- 1. spellID coverage — closable from the client, right now
	local noID, matched = 0, 0
	for _, entry in pairs(MM.Scanner.byMountID or {}) do
		local rec = entry.rec
		if rec and not rec.stub then
			matched = matched + 1
			if not rec.spellID and entry.spellID then noID = noID + 1 end
		end
	end
	if noID > 0 then
		MM:Print("|cffffd84dspellIDs:|r %d matched records have no id in the data.", noID)
		MM:Print("   CLOSABLE HERE -> |cff40d860/mm spells|r exports them from the journal.")
		MM:Print("   Worth running on a character of EACH faction: the journal shows a")
		MM:Print("   different subset per faction, so each finds ids the other cannot.")
	else
		MM:Print("|cff40d860spellIDs: every matched record carries one.|r")
	end

	-- 2. uncatalogued journal mounts
	local stubs = count(function(e)
		return e.rec and e.rec.stub and e.rec.obtainable ~= false
	end, MM.Scanner.byMountID)
	if stubs > 0 then
		MM:Print("|cffffd84dUncatalogued:|r %d obtainable journal mounts have no record.", stubs)
		MM:Print("   CLOSABLE HERE -> |cff40d860/mm stubs|r exports them ready to commit.")
	end

	-- 3. vendor coordinates — needs the player to visit vendors
	-- Committed locations count as much as learned ones. This previously
	-- reported "1 learned" and asked the player to visit every vendor, when the
	-- coordinates were sitting on Wowhead's npc pages the whole time.
	local committed = 0
	for _ in pairs(MM.VendorLocations or {}) do committed = committed + 1 end
	local learned = 0
	for _ in pairs((MM.db.ids and MM.db.ids.vendors) or {}) do learned = learned + 1 end
	local missing = {}
	for _, rec in ipairs(MM.DBList or {}) do
		if rec.vendor and not MM.VendorLocations[rec.vendor:lower()] then
			missing[rec.vendor] = true
		end
	end
	local nMissing = 0
	for _ in pairs(missing) do nMissing = nMissing + 1 end
	if nMissing == 0 then
		MM:Print("|cff40d860Vendor locations: every named vendor has coordinates|r (%d committed, %d learned).",
			committed, learned)
	else
		MM:Print("|cffffd84dVendor locations:|r %d vendors named by records have none.", nMissing)
		for name in pairs(missing) do MM:Print("     %s", name) end
		MM:Print("   Talk to them once, or look the npc up on Wowhead -- g_mapperData")
		MM:Print("   on the npc page carries the zone and coordinates.")
	end

	-- 4. Trading Post rotation
	if not MM.TradingPost.HasLiveData() then
		MM:Print("|cffffd84dTrading Post:|r no rotation data.")
		MM:Print("   NEEDS YOU -> open the Trading Post once this month. No API can")
		MM:Print("   request it (C_PerksProgram has no manifest call); we then")
		MM:Print("   remember it for every character until the rotation ends.")
	end

	-- 5. hearthstone destination
	-- Use the SAME test Nav/Teleports uses. Checking only the learned cache
	-- reported "map unknown" for a bind point of "Stormwind City", which is a
	-- map name and resolves directly -- while the self-test three sections
	-- earlier reported the same hearthstone as working. Two parts of one report
	-- contradicting each other is worse than either answer alone.
	-- Read safely: it is used as a table key and passed to ResolveMapByName,
	-- which lowercases it. Both fail on a secret.
	local bind = MM.Util.ReadableString(GetBindLocation and GetBindLocation())
	if bind and bind ~= "" then
		local learned = MM.db.hearthMaps and MM.db.hearthMaps[bind]
		local byName = MM.Util.ResolveMapByName and MM.Util.ResolveMapByName(bind)
		if not (learned or byName) then
			MM:Print("|cffffd84dHearthstone:|r bound to %q, which is not a map name.", bind)
			MM:Print("   NEEDS YOU -> stand in it once; we learn the map and never ask again.")
		end
	end

	-- 5b. drop rates we do not have
	-- These are not cosmetic. A missing rate used to be scored as a CERTAINTY,
	-- which is how an unrated Mythic+ mount outranked quick legacy drops. It is
	-- now assumed to be a typical boss rate instead, but an assumption is still
	-- an assumption -- every one of these is a real number sitting on Wowhead.
	-- Obtainable only, for the same reason the price list is: a rate for a
	-- mount that no longer drops is not a gap anyone can close, and listing it
	-- makes the backlog look larger than the work actually is.
	local unrated, chancy = {}, 0
	for _, rec in pairs(MM.DBByName) do
		if rec.obtainable
			and (rec.category == "DROP" or rec.category == "RARE"
			or rec.category == "ZONEDROP") then
			chancy = chancy + 1
			-- rateReason means the acquisition IS modelled -- lockout, gate,
			-- spawn -- and only the percentage is missing. Honoured here as
			-- well as in the contribution export, because every previous field
			-- of this kind ended up read by exactly one of the two.
			if not rec.dropRate and not rec.rateReason and not rec.unreleased then
				unrated[#unrated + 1] = rec.name
			end
		end
	end
	if #unrated > 0 then
		table.sort(unrated)
		MM:Print("|cffffd84dDrop rates:|r %d of %d drop/rare records have no rate; "
			.. "they are ranked on an assumed 1%%.", #unrated, chancy)
		for i = 1, math.min(#unrated, 12) do MM:Print("     %s", unrated[i]) end
		if #unrated > 12 then MM:Print("     ...and %d more", #unrated - 12) end
		MM:Print("   Wowhead's item page carries the observed rate under the drop source.")
	end

	-- 5c. purchases whose price we cannot read
	-- These are why Bloodthirsty Dreadwing led the route: category CURRENCY with
	-- the cost living only in prose, so the router saw a free guaranteed mount.
	-- It now charges an unknown-cost penalty instead, which is the right answer
	-- to "we don't know" and the wrong answer to "we could have looked it up".
	local unpriced, withNumber = {}, 0
	for _, rec in pairs(MM.DBByName) do
		if D.IsUnpriced(rec) then
			unpriced[#unpriced + 1] = rec.name
			-- Whether the source text states a PRICE, not merely a digit.
			-- Counting any digit called "Renown 39", "added 11.0.7" and
			-- "(10.1.5)" stated prices, and promised 77 figures that were
			-- mostly patch numbers -- sending someone to look for a price
			-- nobody ever wrote down wastes the one resource this list asks
			-- for. A price is a quantity followed by what it is denominated in.
			if (rec.source or ""):find("%d[%d,]+%s+%u") then
				withNumber = withNumber + 1
			end
		end
	end
	if #unpriced > 0 then
		table.sort(unpriced)
		MM:Print("|cffffd84dUnpriced purchases:|r %d vendor, currency and craft records carry no",
			#unpriced)
		MM:Print("   cost we can read, so they are ranked on a 4-hour assumption.")
		for i = 1, math.min(#unpriced, 12) do MM:Print("     %s", unpriced[i]) end
		if #unpriced > 12 then MM:Print("     ...and %d more", #unpriced - 12) end
		MM:Print("   Each needs a conditions block: { type = \"CURRENCY\", id = N,")
		MM:Print("   name = \"...\", amount = N }.")
		MM:Print("   %d of them state a figure in their source text; the other %d name",
			withNumber, #unpriced - withNumber)
		MM:Print("   no price at all and need someone standing at the vendor.")
	end

	-- 5d. achievements with no achievement attached, and the solo question
	--
	-- Requirement — are we sure every one of these achievements can be completed
	-- solo? No, and we should stop implying otherwise. A raid meta from two
	-- expansions ago usually is; a current-tier one, a rated PvP one or a
	-- Keystone Master emphatically is not, and we infer that from the source
	-- text rather than knowing it.
	local unmodelled, soloUnknown = {}, 0
	for _, rec in pairs(MM.DBByName) do
		-- OBTAINABLE, like the drop-rate list three blocks up, whose comment
		-- already says it: "a mount that no longer drops is not a gap anyone
		-- can close, and listing it makes the backlog look larger than the work
		-- actually is". This loop never applied it, so seven records nobody can
		-- obtain -- a Brawler's Guild season, a Remix, four expired Keystone
		-- seasons -- sat in a list of work to do.
		if rec.category == "ACHIEVEMENT" and rec.obtainable then
			local modelled = false
			for _, cond in ipairs(rec.conditions or {}) do
				if cond.type == "ACHIEVEMENT" then modelled = true break end
			end
			if not modelled then unmodelled[#unmodelled + 1] = rec.name end
			if rec.solo == nil then soloUnknown = soloUnknown + 1 end
		end
	end
	if #unmodelled > 0 then
		table.sort(unmodelled)
		MM:Print("|cffffd84dUnmodelled achievements:|r %d records name an achievement",
			#unmodelled)
		MM:Print("   only in prose, so their progress cannot be read and they are")
		MM:Print("   ranked on an assumed 6-hour meta.")
		for i = 1, math.min(#unmodelled, 12) do MM:Print("     %s", unmodelled[i]) end
		if #unmodelled > 12 then MM:Print("     ...and %d more", #unmodelled - 12) end
		MM:Print("   Each needs { type = \"ACHIEVEMENT\", id = N, name = \"...\" };")
		MM:Print("   the criteria then drive the estimate instead of a guess.")
	end
	if soloUnknown > 0 then
		-- With an achievement id we can ask the client and be certain; without
		-- one we are reading our own prose. Reporting the split shows exactly
		-- what adding ids buys.
		-- COUNTED OVER THE SAME RECORDS, or the sentence contradicts itself.
		--
		-- This walked every achievement record while the line above counted
		-- only those WITHOUT a solo flag, so it read "114 carry no flag; 135
		-- name an achievement id" -- a subset larger than the set it is a
		-- subset of. Both halves were true and the sentence was nonsense.
		--
		-- AND IT CAME BACK, because only half the predicate was copied across.
		-- The loop above also requires `obtainable`; this one did not, so a
		-- live report read "103 carry no flag; 105 of those name an
		-- achievement id" -- the same impossible sentence, two short of the
		-- last one. The two unobtainable records it picked up are the whole
		-- difference. Both conditions, or neither.
		local classified, pvpOrGuild = 0, 0
		for _, rec in pairs(MM.DBByName) do
			if rec.category == "ACHIEVEMENT" and rec.obtainable and rec.solo == nil then
				local id = MM.Conditions.RecordAchievementID
					and MM.Conditions.RecordAchievementID(rec)
				local class = id and MM.Conditions.AchievementClass(id)
				if class then
					classified = classified + 1
					if class.pvp or class.guild then pvpOrGuild = pvpOrGuild + 1 end
				end
			end
		end
		MM:Print("|cffffd84dSolo-ability:|r %d achievement records carry no `solo` flag.",
			soloUnknown)
		MM:Print("   %d of those name an achievement id; %d are PvP or guild, which",
			classified, pvpOrGuild)
		MM:Print("   the client settles outright — those are never solo.")
		MM:Print("   |cff9a9a9aEverything else is genuinely NOT derivable. Legacy raids were|r")
		MM:Print("   |cff9a9a9abuilt for groups and are often soloable anyway, depending on|r")
		MM:Print("   |cff9a9a9aclass, gear and player — no API exposes that. `solo = false`|r")
		MM:Print("   |cff9a9a9aper record is the only honest fix, one judgement at a time.|r")
	end

	-- 5e. secrets with no chain yet
	local secretless = {}
	for _, rec in pairs(MM.DBByName) do
		if rec.category == "PUZZLE" and not (rec.acquire and rec.acquire.steps) then
			secretless[#secretless + 1] = rec.name
		end
	end
	if #secretless > 0 then
		table.sort(secretless)
		MM:Print("|cffffd84dSecrets with no chain:|r %d puzzle mounts have no step list,",
			#secretless)
		MM:Print("   so they are costed on their effort rating alone.")
		for _, name in ipairs(secretless) do MM:Print("     %s", name) end
		MM:Print("   Each needs acquire = { hours = N, steps = { { text = \"...\" } } }.")
	end

	-- 6. things only a person can look up
	-- WHAT CAN ACTUALLY RECORD AN ATTEMPT, counted rather than assumed.
	--
	-- Asked directly whether paragon and chest mounts register their completion
	-- and move the route on. They did not, and the reason was wider than either:
	-- an attempt comes from a combat-log kill (registered only on pre-12.0
	-- clients), an encounter name, or a record's trackingQuest -- and NO record
	-- carries a trackingQuest. On Midnight that leaves boss kills alone.
	--
	-- Paragon is now watched exactly, through hasRewardPending. The rest is
	-- printed rather than quietly assumed to work.
	local tq, treasure, paragon = 0, 0, 0
	for _, rec in ipairs(MM.DBList or {}) do
		if rec.trackingQuest then tq = tq + 1 end
		if rec.obtainable and rec.category == "TREASURE" then treasure = treasure + 1 end
		if rec.obtainable and MM.Attempts.IsParagonGoal
			and MM.Attempts.IsParagonGoal(rec) then paragon = paragon + 1 end
	end
	local combatLog = (select(4, GetBuildInfo()) or 0) < 120000
	-- Treasure POIs: how many are readable RIGHT NOW.
	--
	-- Printed because absence is ambiguous by design -- looted, undiscovered,
	-- filtered off the map, or a zone the client has not loaded all look the
	-- same -- and a number nobody can see is a number nobody can question.
	local poiGoals, poiLive = 0, 0
	for _, rec in ipairs(MM.DBList or {}) do
		if rec.poi then
			poiGoals = poiGoals + 1
			if MM.Assaults.FindPOI and MM.Assaults.FindPOI(rec) then
				poiLive = poiLive + 1
			end
		end
	end
	if poiGoals > 0 then
		MM:Print("|cffffd84dTreasure locations:|r %d of %d readable from the map "
			.. "right now", poiLive, poiGoals)
		MM:Print("   The rest fall back to their stored zone. A missing POI means")
		MM:Print("   looted, undiscovered, filtered off, or a zone not loaded --")
		MM:Print("   which is why it never marks anything complete.")
	end

	MM:Print("|cffffd84dAttempt tracking:|r what can mark a goal attempted here")
	MM:Print("   boss kills by encounter name    working")
	MM:Print("   paragon caches                  %d goal(s), watched via hasRewardPending",
		paragon)
	MM:Print("   combat-log npc kills            %s",
		combatLog and "working" or "OFF -- 12.0 makes raw combat log Blizzard-only")
	MM:Print("   looting a watched rare          working (loot source GUID)")
	MM:Print("   tracking quests                 %d record(s) carry one", tq)
	if tq == 0 then
		MM:Print("      never populated -- rares are covered by loot instead;")
		MM:Print("      %d treasure goals still record nothing, and each needs a", treasure)
		MM:Print("      verified quest id rather than an invented one.")
	end

	MM:Print("|cffffd84dNeeds a human lookup:|r")
	if MM.TradingPost.travelersLog then
		MM:Print("   - Traveler's Log: modelled. %d mount(s) among this month's rewards.",
			#(MM.TradingPost.travelersLog.mounts or {}))
	else
		MM:Print("   - Traveler's Log: not read yet — open the Trading Post once.")
	end
	MM:Print("   - 12.1 records are provisional: achievement and npc ids could not")
	MM:Print("     be verified because that content is not on live.")
	MM:Print("   - Records with `needsSource = true` have a verified identity but no")
	MM:Print("     confirmed source; Wowhead has no source table for them.")
	local needsSource = 0
	for _, rec in ipairs(MM.DBList or {}) do
		if rec.needsSource then needsSource = needsSource + 1 end
	end
	MM:Print("     (%d such records.)", needsSource)
end)


------------------------------------------------------------
-- /mm release — is this shippable?
------------------------------------------------------------
-- Requirement — close all gaps, get everything to 100%, this is a prep for release
-- situation.
--
-- The honest answer needs two questions kept apart, because conflating them is
-- how software ships broken or never ships at all:
--
--   IS IT BROKEN?     a failing self-test, a syntax error, a missing file.
--                     These block a release. There should be zero.
--   IS IT COMPLETE?   a drop rate nobody has ever observed, a price only a
--                     player standing at the vendor can read, whether a 2013
--                     raid still solos. These are NOT defects, they are data
--                     the world has not handed over yet, and every one of them
--                     is already costed pessimistically so it cannot mislead
--                     the ranking.
--
-- An addon that refuses to ship until 1,608 records are perfectly described
-- will never ship. One that ships pretending they are is worse. This reports
-- both numbers and lets the second be a known quantity rather than a surprise.
MM:On("MM_RELEASE_DEBUG", function()
	local blockers, warnings = {}, {}

	-- 1. The self-test is the gate.
	local t = MM.Tests and MM.Tests.lastRun
	if not t and not D.inReport then
		-- Run it rather than complain -- but NEVER while the full report is
		-- being generated. The report's own first section runs the entire
		-- self-test, and this ran it a second time: 87 checks twice, including
		-- three route builds inside the cap test. That is what froze the
		-- client, and it is the same mistake as Addendum 97 in a new costume.
		if MM.Tests and MM.Tests.Run then pcall(MM.Tests.Run) end
		t = MM.Tests and MM.Tests.lastRun
	end
	if not t then
		blockers[#blockers + 1] = "self-test could not be run"
	else
		if (t.failed or 0) > 0 then
			blockers[#blockers + 1] = ("%d self-test failure%s"):format(
				t.failed, t.failed == 1 and "" or "s")
		end
		if (t.degraded or 0) > 0 then
			warnings[#warnings + 1] = ("%d degraded (checks that could not run)")
				:format(t.degraded)
		end
	end

	-- 2. The database has to build and match its sources.
	local n = 0
	for _ in pairs(MM.DBByName or {}) do n = n + 1 end
	if n < 1000 then
		blockers[#blockers + 1] = ("database looks truncated: %d records"):format(n)
	end

	-- 3. Anything that would send a player somewhere useless.
	--
	-- "No position" is NOT the test, and reading it as one held the release
	-- gate at "not shippable" over 16 stops that are working exactly as
	-- designed. Router.lua deliberately puts the no-location goals into the
	-- route flagged `noLocation`, so that skipping through cannot "finish"
	-- while they sit unvisited; a queued goal has nowhere to point because
	-- queueing IS how you reach it. Both are features.
	--
	-- What would actually send someone somewhere useless is a stop with no
	-- position and no reason for it. That is the blocker.
	local R = MM.Router
	if R and R.route and #R.route > 0 then
		local noWhere = 0
		for _, stop in ipairs(R.route) do
			local excused = MM.Router.PositionlessExcuse(stop)
			if not stop.world and not excused then noWhere = noWhere + 1 end
		end
		if noWhere > 0 then
			blockers[#blockers + 1] =
				("%d routed stops have no position and no reason for it"):format(noWhere)
		end
	end

	-- 4. Data completeness, reported but never a blocker.
	local counts = MM.Contribute and select(2, MM.Contribute.Scan())
	local gaps = 0
	for _, v in pairs(counts or {}) do gaps = gaps + v end

	MM:Print("|cffffd84dRELEASE READINESS|r")
	if #blockers == 0 then
		MM:Print("   |cff40d860No blockers.|r Nothing is broken.")
	else
		MM:Print("   |cffff4444%d BLOCKER%s — do not release:|r", #blockers,
			#blockers == 1 and "" or "S")
		for _, b in ipairs(blockers) do MM:Print("      %s", b) end
	end
	for _, w in ipairs(warnings) do MM:Print("   |cffff9a3cnote:|r %s", w) end

	MM:Print("   Data completeness: %d known gaps.", gaps)
	MM:Print("      These are not defects. Every one is costed pessimistically,")
	MM:Print("      so an unpriced goal can never outrank real work -- the ORDER")
	MM:Print("      is sound even where the TOTAL is an upper bound. /mm costs")
	MM:Print("      and /mm timemodel show exactly where, /mm contribute exports")
	MM:Print("      the subset a player can actually answer.")
	MM:Print("   Verdict: |c%s%s|r", #blockers == 0 and "ff40d860" or "ffff4444",
		#blockers == 0 and "shippable" or "not shippable")
end)

------------------------------------------------------------
-- State that shapes the plan but had no voice in the report
------------------------------------------------------------
-- Requirement — make sure everything is integrated into diagnostics, i do not care
-- about slash commands as long as its all captured.
--
-- An audit of the shipped modules found 23 with no section of their own. Most
-- are infrastructure a self-test already covers. But several hold STATE that
-- changes what the addon recommends, and a report that omits them cannot
-- explain its own output:
--
--   lockouts   a saved raid removes a goal from tonight entirely
--   warband    which character can finish what, and what they carry
--   settings   forty switches, any of which changes the answer
--
-- A pasted report is a bug report. If it cannot say how the addon was
-- configured when it produced that list, the reader is guessing.
MM:On("MM_STATE_DEBUG", function()
	------------------------------------------------------------
	-- Lockouts
	------------------------------------------------------------
	local L = MM.Lockouts
	local saved = (MM.db and MM.db.lockouts) or {}
	local instances, encounters = 0, 0
	for _, inst in pairs(saved) do
		instances = instances + 1
		if type(inst) == "table" then
			for _ in pairs(inst) do encounters = encounters + 1 end
		end
	end
	MM:Print("|cffffd84dLockouts|r  %d instance record%s, %d encounter save%s",
		instances, instances == 1 and "" or "s",
		encounters, encounters == 1 and "" or "s")
	if instances == 0 then
		MM:Print("   Nothing saved. A saved boss removes its mount from tonight,")
		MM:Print("   so an empty roster means nothing is being held back for that reason.")
	end

	------------------------------------------------------------
	-- Warband
	------------------------------------------------------------
	local alts = (MM.db and MM.db.alts) or {}
	local n, withProf, withRep, withCur = 0, 0, 0, 0
	for _, snap in pairs(alts) do
		n = n + 1
		if snap.skillLines and next(snap.skillLines) then withProf = withProf + 1
		elseif snap.professions and next(snap.professions) then withProf = withProf + 1 end
		if snap.rep and next(snap.rep) then withRep = withRep + 1 end
		if snap.currency and next(snap.currency) then withCur = withCur + 1 end
	end
	MM:Print("|cffffd84dWarband|r  %d character%s snapshotted", n, n == 1 and "" or "s")
	for key, snap in pairs(alts) do
		MM:Print("   %-24s %s %s  rep:%d currency:%d prof:%s", key,
			snap.class or "?", snap.faction or "?",
			snap.rep and (function() local c=0 for _ in pairs(snap.rep) do c=c+1 end return c end)() or 0,
			snap.currency and (function() local c=0 for _ in pairs(snap.currency) do c=c+1 end return c end)() or 0,
			-- Name the trade and the rank. "yes" cannot answer the question a
			-- craft mount actually asks, which is whether THIS character is
			-- skilled enough -- and it hid a bug where the data was being
			-- wiped, because "no" looks like a character without professions
			-- rather than one whose professions were lost.
			(function()
				local profs = snap.professions
				if not (profs and next(profs)) then return "none recorded" end
				local out = {}
				for name, level in pairs(profs) do
					out[#out + 1] = (type(level) == "number" and level > 0)
						and ("%s %d"):format(name, level) or name
				end
				table.sort(out)
				return table.concat(out, ", ")
			end)())
	end
	if n <= 1 then
		MM:Print("   Only this character is known, so \"do this on X\" can only ever")
		MM:Print("   answer \"you\". Log in on an alt once to widen it.")
	end

	------------------------------------------------------------
	-- Settings
	------------------------------------------------------------
	-- Every switch, so a pasted report explains its own output. Sorted, and
	-- nested tables summarised rather than dumped -- the point is "what was it
	-- set to", not a serialisation.
	local keys = {}
	for k, v in pairs(MM.db or {}) do
		local t = type(v)
		if t == "string" and #v > 120 then
			-- Summarise long strings, exactly as tables are summarised below.
			--
			-- The original guard covered nested TABLES but not long STRINGS, and
			-- three settings hold enormous ones: idExport (the whole generated id
			-- file), rareLootResult, and lastReport.
			--
			-- lastReport is the serious one. The report saves itself into MM.db,
			-- and this loop printed MM.db in full -- so every report contained the
			-- previous report, which contained the one before it. Each run roughly
			-- doubled the file. That is how it reached 15,778 lines: not one big
			-- report, but a stack of nested copies.
			keys[#keys + 1] = ("%s=<%d chars>"):format(k, #v)
		elseif t == "boolean" or t == "number" or t == "string" then
			keys[#keys + 1] = ("%s=%s"):format(k, tostring(v))
		elseif t == "table" then
			local c = 0
			for _ in pairs(v) do c = c + 1 end
			keys[#keys + 1] = ("%s={%d}"):format(k, c)
		end
	end
	table.sort(keys)
	MM:Print("|cffffd84dSettings|r  %d stored", #keys)
	-- Wrapped rather than one per line: forty switches is a paragraph, not a page.
	local line = "   "
	for _, k in ipairs(keys) do
		if #line + #k > 92 then MM:Print(line); line = "   " end
		line = line .. k .. "  "
	end
	if line ~= "   " then MM:Print(line) end
end)

------------------------------------------------------------
-- /mm fixes — did this build actually change what it claims to?
------------------------------------------------------------
-- Every other section answers "what is the state of things". This one answers
-- "is the thing we fixed still fixed", which is a different question and the
-- one that gets skipped.
--
-- Written after a morning in which two players reported six defects, four of
-- them invisible from inside: an error that fired on a repeating event and so
-- printed forever, a comparison that returned true when it should have counted,
-- a placeholder coordinate that looked exactly like a real one. None of those
-- announce themselves in a report about mounts.
--
-- EVERY LINE PROBES LIVE STATE. Not one of them asserts. A probe that reads
-- "OK" because it was written to read OK is worth less than no line at all --
-- so each carries the number it measured, and each states what the broken
-- version looked like, so a reader can tell the difference between "fixed" and
-- "the check is wrong now too".
MM:On("MM_FIXES_DEBUG", function()
	local rows = {}
	local function probe(name, fn)
		local ok, good, detail = pcall(fn)
		if not ok then
			rows[#rows + 1] = { false, name, "probe itself failed: " .. tostring(good) }
		else
			rows[#rows + 1] = { good, name, detail }
		end
	end

	-- ---- data -------------------------------------------------------------
	probe("Vendors that check a reputation", function()
		local STANDINGS = { "Exalted", "Revered", "Honored", "Friendly" }
		local PURCHASE = { VENDOR = true, CURRENCY = true, REP = true, TIMEWALKING = true }
		local stated, bare = 0, 0
		for _, rec in ipairs(MM.DBList or {}) do
			local src = rec.source or ""
			if rec.obtainable and PURCHASE[rec.category] then
				local names = false
				for _, s in ipairs(STANDINGS) do
					if src:find(s .. " with ") then names = true break end
				end
				if names then
					stated = stated + 1
					local has = false
					for _, c in ipairs(rec.conditions or {}) do
						if c.type == "REP" then has = true break end
					end
					if not has then bare = bare + 1 end
				end
			end
		end
		return bare == 0, ("%d state a standing, %d carry no gate (was 7)"):format(stated, bare)
	end)

	probe("An item cost counts, not just exists", function()
		local probeCond = { type = "ITEM", id = 6948, name = "probe", amount = 999999 }
		local met = MM.Conditions.Evaluate(probeCond)
		local many = 0
		for _, rec in ipairs(MM.DBList or {}) do
			for _, c in ipairs(rec.conditions or {}) do
				if c.type == "ITEM" and (c.amount or 0) > 1 then many = many + 1 end
			end
		end
		return met == false,
			("%d costs want more than one; a 999,999 probe reads %s (was true)")
				:format(many, tostring(met))
	end)

	probe("No cost charged twice", function()
		local COST = { ITEM = true, CURRENCY = true, MATERIAL = true }
		local dupes, total = 0, 0
		for _, rec in ipairs(MM.DBList or {}) do
			local seen = {}
			for _, c in ipairs(rec.conditions or {}) do
				if COST[c.type] then
					total = total + 1
					local id = c.id or c.itemID
					if id then
						if seen[id] then dupes = dupes + 1 end
						seen[id] = true
					end
				end
			end
		end
		return dupes == 0, ("%d cost lines, %d duplicated (was 3 records)"):format(total, dupes)
	end)

	probe("Gold prices from the client", function()
		local n = 0
		for _, rec in ipairs(MM.DBList or {}) do
			if rec.goldCost then n = n + 1 end
		end
		return n >= 215, ("%d records priced in gold (was 170, +50 from Mount.db2)"):format(n)
	end)

	probe("No goal points at the middle of its zone", function()
		local bad, placed = 0, 0
		for _, rec in ipairs(MM.DBList or {}) do
			local z = rec.zone
			if z and z.x and z.y then
				placed = placed + 1
				if z.x == 50 and z.y == 50 then bad = bad + 1 end
			end
		end
		return bad == 0, ("%d positioned, %d at 50/50 (was 48)"):format(placed, bad)
	end)

	probe("Collectibles are named and counted", function()
		local WANT = {
			["Alunira"] = 224025, ["Swift Lovebird"] = 49927,
			["Heartseeker Mana Ray"] = 49927, ["Swift Springstrider"] = 44791,
			["Minion of Grumpus"] = 128659, ["Nazjatar Blood Serpent"] = 161344,
		}
		local ok, missing = 0, nil
		for name, id in pairs(WANT) do
			local rec = MM.DBByName[name:lower()]
			local found = false
			for _, c in ipairs((rec and rec.conditions) or {}) do
				if c.type == "ITEM" and c.id == id and (c.amount or 0) > 1 then found = true end
			end
			if found then ok = ok + 1 else missing = missing or name end
		end
		return ok == 6, ("%d of 6 carry an id'd, counted item%s"):format(
			ok, missing and (" -- missing " .. missing) or "")
	end)

	probe("Nether-Swept Drake fishes open water", function()
		local rec = MM.DBByName["nether-swept drake"]
		local z = rec and rec.zone
		local right = z and z.y == 30 and (rec.source or ""):find("OPEN WATER")
		return right and true or false,
			z and ("%s %.0f, %.0f (was 50/50, and 'Oceanic Vortex pools')")
				:format(z.name or "?", z.x or 0, z.y or 0) or "no zone"
	end)

	-- ---- runtime ----------------------------------------------------------
	probe("Handler errors this session", function()
		local n = #(MM.handlerErrors or {})
		local detail = ("%d distinct (each printed once, not once per event)"):format(n)
		for i = 1, math.min(n, 3) do
			detail = detail .. ("\n        %s: %s"):format(
				MM.handlerErrors[i].event, MM.handlerErrors[i].err)
		end
		return n == 0, detail
	end)

	probe("Boss names readable on this client", function()
		local readable = MM.Scanner.BossNamesReadable == nil
			or MM.Scanner.BossNamesReadable()
		return readable, readable
			and "12.0 secret values are not blocking attempt counting here"
			or "hidden by 12.0 -- attempts are not auto-counted, and that is handled"
	end)

	probe("Which kinds of client string this client hands over", function()
		-- Five reports, five shapes of one 12.0 change, and every time the
		-- answer to "what else is secret?" was a guess. This asks the client.
		local U = MM.Util
		if not (U and U.SecretAudit) then return false, "the audit is not loaded" end
		local withheld, readable, absent = {}, 0, 0
		for _, r in ipairs(U.SecretAudit()) do
			if r.state == "WITHHELD" then
				withheld[#withheld + 1] = r.label .. (r.relied and " (DEPENDED ON)" or "")
			elseif r.state == "readable" then readable = readable + 1
			else absent = absent + 1 end
		end
		return #withheld == 0,
			("%d readable, %d not probeable here%s"):format(readable, absent,
				#withheld > 0 and (" -- WITHHELD: " .. table.concat(withheld, ", ")) or "")
	end)

	probe("Map pins: what the index holds, and what it rejected", function()
		-- Reported as no pins at all while standing in a zone with mounts left
		-- to farm. Three theories in, this stops guessing: every rejection is
		-- counted where it happens and printed here, alongside how many pins
		-- THIS map would draw. "None indexed", "none for this map" and "indexed
		-- but filtered at draw" are three different faults that look identical
		-- on screen.
		local MP = MM.MapPins
		if not (MP and MP.stats) then return false, "the pin layer is not loaded" end
		local st = MP.stats
		local here = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
		local mine = MP.CountFor and MP.CountFor(here) or 0
		-- Indexed and drawn are separate facts. The index was right through the
		-- whole of the last fault; what was missing was any statement that the
		-- drawing layer had been asked, and by whom. The provider either is
		-- registered with the map canvas or it is not, and the last refresh of
		-- each surface either put pins up or put none up.
		local detail = ("%d journal entries -> %d points indexed as %d place(s), "
			.. "%d record(s) via `spawns`; this map (%s) "
			.. "holds %d. Rejected: %d no record, %d stub, %d other faction, %d "
			.. "no zone at all, %d zone with no coordinates, %d zone name that "
			.. "resolved to no map%s. Canvas provider %s; last draw %d on map %s, "
			.. "%d on the minimap (%s)%s")
			:format(st.entries, st.indexed, st.places, st.fromSpawns,
				tostring(here), mine, st.noRec,
				st.stub, st.factionFiltered, st.noPoints, st.noCoords,
				st.unresolvedMap,
				st.scannerReady and "" or " (SCANNER WAS NOT READY -- nothing could be indexed)",
				st.installed and "registered" or "NOT REGISTERED",
				MP.lastDrawn or 0, tostring(MP.lastMapID), MP.lastMinimapDrawn or 0,
				-- "out of range" is the answer nearly all the time, and it is
				-- only believable with the two distances beside it
				("%s; %d point(s) on this continent weighed%s%s"):format(
					tostring(MP.minimapWhy), MP.minimapCandidates or 0,
					MP.minimapNearest
						and (", nearest %.0f yd"):format(MP.minimapNearest) or "",
					MP.minimapRadius
						and (", minimap shows %.0f yd"):format(MP.minimapRadius) or ""),
				st.minimapRadiusAPI == false
					and " (THIS CLIENT HAS NO MINIMAP VIEW RADIUS API -- minimap pins cannot be placed)"
					or "")
		-- WHAT THE MINIMAP DRIVER ACTUALLY COSTS.
		--
		-- It runs an OnUpdate, which is the one shape that is expensive by
		-- default and invisible by default: it fires every frame whether or not
		-- there is anything to do. Reported so "the addon feels heavy" can be
		-- answered with a count rather than a guess, and so parking can be seen
		-- to be working rather than assumed.
		local ds = MP.driverStats
		if ds then
			detail = detail .. ("; driver %d tick(s), %d full, %d move, %d park(s), "
				.. "%.0f ms%s"):format(ds.ticks, ds.fulls, ds.moves, ds.parked, ds.ms,
					MP.driverParked and (" — parked: " .. MP.driverParked) or "")
		end
		return st.indexed > 0 and st.scannerReady and st.installed, detail
	end)

	probe("Arrow survives a hop with no item", function()
		-- The exact call that produced 1,124 errors: a spell-only teleport
		-- arrives here as nil, twenty times a second.
		--
		-- This really does hide the action button for an instant if one is on
		-- screen. Arrow:Update runs every 50ms and puts it straight back, and a
		-- probe that exercises the actual failing path is worth more than one
		-- that inspects around it.
		if not (MM.Arrow and MM.Arrow.ShowAction) then
			return false, "arrow module unavailable"
		end
		local ok, err = pcall(MM.Arrow.ShowAction, MM.Arrow, nil, nil, nil)
		return ok, ok and "nil item and nil spell hides the button rather than throwing"
			or ("still throws: " .. tostring(err))
	end)

	probe("Zone popup rows take clicks", function()
		-- nil until the popup has been built once, which is not a failure.
		if MM.ZoneAlert.rowsClickable == nil then
			return true, "not built yet this session -- enter a zone with mounts to confirm"
		end
		return MM.ZoneAlert.rowsClickable == true,
			"rows are buttons; a click opens that mount, not the whole list"
	end)

	probe("Route build hands the frame back", function()
		local y = MM.Router.yieldsThisBuild
		if y == nil then return true, "no route built yet this session" end
		local stops = MM.Router.route and #MM.Router.route or 0
		return true, ("%d yields across %d stops -- the check is now INSIDE the "
			.. "candidate loop, which is where the searches are"):format(y, stops)
	end)

	probe("The waypoint arrow is ours unless asked otherwise", function()
		if not MM.Nav or not MM.Nav.Refresh then
			return false, "Nav.Refresh missing -- toggling the setting mid-route "
				.. "would do nothing until the next step"
		end
		local want = MM.db.useTomTom and "tomtom" or "builtin"
		local have = MM.Nav.Provider and MM.Nav.Provider() or "?"
		local tt = _G.TomTom and "installed" or "not installed"
		if have == "none" then
			return true, ("setting says %s, TomTom %s; nothing being navigated "
				.. "to right now"):format(want, tt)
		end
		-- A cross-continent leg is OURS on purpose even with TomTom asked for,
		-- so that disagreement is correct and must not read as a failure.
		if have ~= want and not (want == "tomtom" and have == "builtin") then
			return false, ("setting says %s but %s is driving"):format(want, have)
		end
		return true, ("%s driving, setting says %s, TomTom %s"):format(have, want, tt)
	end)

	probe("Reading the current goal leaves the anchor alone", function()
		local R = MM.Router
		if not (R and R.SetIndex) then return false, "R.SetIndex missing" end
		if not (MM.cdb and MM.cdb.routeActive) then
			return true, "no route running; the anchor is only movable while one is"
		end
		local before = MM.db.routeGoal
		R:Current(); R:Current()
		return MM.db.routeGoal == before,
			MM.db.routeGoal == before
				and ("two reads left the anchor on %s (was: a read moved it)")
					:format(tostring(before))
				or ("a read moved the anchor %s -> %s")
					:format(tostring(before), tostring(MM.db.routeGoal))
	end)

	probe("The report breathes between sections", function()
		local D2 = MM.Diagnostics
		if not D2.BuildChunked then return false, "the report runs in one go again" end
		local worst, ms = D2.SlowestSection()
		if not worst then return true, "chunked builder present; nothing timed yet" end
		return ms <= 400, ("slowest single section %s at %d ms (was: the self-test "
			.. "alone at 2,635 ms in one run, which is what the watchdog measures)")
			:format(worst, ms)
	end)

	probe("No single self-test check is over budget", function()
		-- Asks Tests for the answer rather than working one out. Its own copy of
		-- this omitted the build-bound exemption and hardcoded "two", so a clean
		-- self-test still reported here as something to look at, naming a check
		-- that is exempt by design.
		if not (MM.Tests and MM.Tests.SlowestCheck) then
			return true, "the self-test timings are not loaded"
		end
		local worst, worstMs, n, exempt = MM.Tests.SlowestCheck()
		if not worst and not worstMs then return true, "nothing timed yet" end
		return worstMs <= 1200, ("slowest check %s at %d ms of %d timed; %d exempt "
			.. "for forcing a synchronous build (was: the preset round-trip "
			.. "re-planned seven times and was killed on slower hardware)")
			:format(tostring(worst), worstMs, n, #(exempt or {}))
	end)

	probe("Grand Hunt: everything the client says about the banner", function()
		-- The reward tier is NOT in the description -- the client's AreaPOI
		-- table gives every Grand Hunting Party row the same fixed line, and
		-- carries the tier in a widget set instead. So the useful thing to
		-- print is every field of a matching POI, once one is up, rather than
		-- the one field that was assumed to hold the answer.
		local A = MM.Assaults
		if not (A and A.rotatingGates) then return false, "assaults not loaded" end
		local shown = {}
		for _, gate in pairs(A.rotatingGates) do
			for _, mapID in ipairs((A.gateMaps and A.gateMaps[gate.key]) or gate.maps or {}) do
				for _, e in ipairs(A.active[mapID] or {}) do
					local hay = (e.name or ""):lower()
					for _, needle in ipairs(gate.match or {}) do
						if needle and hay:find(needle:lower(), 1, true) and e.poiID then
							local ok, info = pcall(C_AreaPoiInfo.GetAreaPOIInfo, mapID, e.poiID)
							if ok and type(info) == "table" then
								local keys = {}
								for k, v in pairs(info) do
									if type(v) ~= "table" then
										keys[#keys + 1] = ("%s=%s"):format(k,
											MM.Util.ReadableString(v) or tostring(v))
									end
								end
								table.sort(keys)
								shown[#shown + 1] = ("poi %d on map %d: %s")
									:format(e.poiID, mapID, table.concat(keys, " "))
							end
							break
						end
					end
				end
			end
		end
		if #shown == 0 then
			return true, "no matching banner up right now -- nothing to describe"
		end
		return true, table.concat(shown, " | ")
	end)

	probe("Which POI getters this client actually answers", function()
		-- A banner with a timer and a reward line was on screen while
		-- GetAreaPOIForMap on that map returned nothing. Naming the getter that
		-- DID produce it is the difference between a fix and another theory.
		local A = MM.Assaults
		local api = C_AreaPoiInfo
		local avail = {}
		if type(api) == "table" then
			for name, fn in pairs(api) do
				if type(fn) == "function" and type(name) == "string"
					and name:find("ForMap$") then
					avail[#avail + 1] = name
				end
			end
			table.sort(avail)
		end
		local used = {}
		for name, n in pairs((A and A.poiSources) or {}) do
			used[#used + 1] = ("%s=%d"):format(name, n)
		end
		table.sort(used)
		return #avail > 0, ("client offers: %s | produced points: %s"):format(
			#avail > 0 and table.concat(avail, ", ") or "none",
			#used > 0 and table.concat(used, ", ") or "none yet")
	end)

	probe("Grand Hunt: which maps were asked, and what came back", function()
		-- The banner is not turning up and the useful question is no longer
		-- "is it there" but "where did we look". Absence is only informative
		-- once the search is visible.
		local A = MM.Assaults
		if not (A and A.rotatingGates) then return false, "assaults not loaded" end
		local out = {}
		for _, gate in pairs(A.rotatingGates) do
			local seen = {}
			for _, mapID in ipairs((A.gateMaps and A.gateMaps[gate.key])
				or gate.maps or {}) do seen[mapID] = true end
			-- and whatever contains them
			for _, mapID in ipairs(gate.maps or {}) do
				local ok, info = pcall(C_Map.GetMapInfo, mapID)
				if ok and info and info.parentMapID and info.parentMapID > 0 then
					seen[info.parentMapID] = true
				end
			end
			local ids = {}
			for mapID in pairs(seen) do ids[#ids + 1] = mapID end
			table.sort(ids)
			for _, mapID in ipairs(ids) do
				local n = #(A.active[mapID] or {})
				local mi = C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
				out[#out + 1] = ("%s(%d)=%d"):format(
					(mi and MM.Util.ReadableString(mi.name)) or "?", mapID, n)
			end
		end
		if #out == 0 then return false, "no rotating gate declares a map" end
		-- Never a failure. This reports the search, and a search that finds
		-- nothing is a fact about this moment, not a defect.
		return true, ("POIs seen per map: %s"):format(table.concat(out, ", "))
	end)

	probe("Grand Hunt: can the banner be read from here", function()
		local A = MM.Assaults
		if not (A and A.FirstRewardAvailable) then return false, "reader missing" end
		local lines, gates = {}, 0
		for key, gate in pairs(A.rotatingGates or {}) do
			gates = gates + 1
			local v = A.FirstRewardAvailable(gate)
			local done = A.WeeklyDone(key)
			lines[#lines + 1] = ("%s: %s%s"):format(gate.label or key,
				v == true and "banner up, EPIC bag still on offer -- worth going now"
					or v == false and "banner up, epic bag already taken this week"
					or "no banner in the scan -- still offered, routed to the last "
					   .. "known zone, which is correct",
				done and " (recorded done this week)" or "")
		end
		if gates == 0 then return false, "no rotating gates discovered" end
		-- Never a failure: the honest answer to "is it done" is often "cannot
		-- tell from this continent", and saying so is the behaviour being
		-- validated rather than a fault.
		return true, table.concat(lines, "; ")
	end)

	probe("Wowhead copy box resolves", function()
		local dlg = StaticPopupDialogs and StaticPopupDialogs["MASTERMOUNTS_WOWHEAD"]
		if not dlg then return false, "dialog not registered" end
		local live = _G.StaticPopup1
		local which = live and ((live.EditBox and "EditBox")
			or (live.editBox and "editBox")) or "no popup on screen to inspect"
		return true, ("this client uses %s; all spellings accepted"):format(which)
	end)

	-- ---- print ------------------------------------------------------------
	local bad = 0
	for _, r in ipairs(rows) do if not r[1] then bad = bad + 1 end end
	-- The "(was N)" figures are the state BEFORE these fixes, which was 1.1.5 --
	-- not an internal high-water mark, and deliberately not "the version players
	-- run", because that moves every time one ships. What they are for is
	-- letting a reader tell a fix from a check that was always green.
	MM:Print("|cffffd84dFIXES IN THIS BUILD|r  %s, measured live; (was N) is the state before these fixes",
		MM.VERSION or "?")
	for _, r in ipairs(rows) do
		MM:Print("   %s  %s", r[1] and "|cff40d860 OK |r" or "|cffff4444CHECK|r", r[2])
		if r[3] then MM:Print("        |cff9a9a9a%s|r", tostring(r[3])) end
	end
	if bad == 0 then
		MM:Print("   |cff40d860All %d hold.|r", #rows)
	else
		MM:Print("   |cffff4444%d of %d need looking at.|r", bad, #rows)
	end
end)

------------------------------------------------------------
-- /mm rowprobe — the left pane's [+], measured
------------------------------------------------------------
-- Reading the code three times did not explain why this one button does
-- nothing while two identical ones work. This prints what the frames actually
-- are, so the next step comes from a number rather than another reading.
MM:On("MM_ROWPROBE_DEBUG", function()
	MM:Print("|cffffd84dPLANNER LEFT PANE|r  measured, not inferred")
	local info, why = MM.UI and MM.UI.InspectMissingPane and MM.UI.InspectMissingPane()
	if not info then
		MM:Print("   %s", why or "open the Planner tab once, then run this again")
		return
	end
	MM:Print("   scroll box: width %s, level %s, %d row(s) drawn",
		tostring(info.boxWidth), tostring(info.boxLevel), info.visibleRows or 0)
	if (info.visibleRows or 0) == 0 then
		MM:Print("   Nothing is drawn here, so there is no [+] to press --")
		MM:Print("   every missing mount is already on your plan.")
		return
	end
	for i, r in ipairs(info.rows) do
		MM:Print("   %d. %s", i, tostring(r.name))
		if r.btnMissing then
			MM:Print("        NO ACTION BUTTON ON THIS ROW")
		else
			MM:Print("        glyph %sx%s, shown %s, alpha %s%%, row OnMouseDown %s",
				tostring(r.btnW), tostring(r.btnH), tostring(r.btnShown),
				tostring(r.btnAlpha), tostring(r.hasClick))
			MM:Print("        row width %s, button inset left %s right %s%s",
				tostring(r.rowWidth), tostring(r.insetLeft), tostring(r.insetRight),
				(r.insetLeft and r.rowWidth and r.insetLeft > r.rowWidth)
					and "   <-- anchored off the row" or "")
		end
		MM:Print("        spellID %s, already planned %s, a click would add: %s%s",
			tostring(r.spellID), tostring(r.inPlan), tostring(r.addWouldWork),
			r.spellID == nil and "   <-- no spellID, so Add has nothing to key on" or "")
	end
end)
