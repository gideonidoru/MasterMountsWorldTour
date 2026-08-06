-- Master Mounts core: namespace, event dispatch, saved variables, slash commands.
local ADDON_NAME, MM = ...
_G.MasterMounts = MM

-- Where our own art lives, derived from the folder we are actually installed
-- in rather than typed out.
--
-- Four files hardcoded "Interface\\AddOns\\MasterMounts\\Media\\...". Renaming
-- the addon folder broke every one of them silently: WoW does not error on a
-- missing texture, it just draws nothing. The compact window lost its expand
-- button, the minimap icon and the main window portrait went blank, and the
-- navigation arrow -- the thing the whole route points with -- became
-- invisible. Nothing threw, so nothing said so.
--
-- ADDON_NAME is the folder name from WoW itself, so this cannot drift again.
MM.MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\"

MM.VERSION = "1.5.0"
MM.PREFIX = "|cff33c1ffMaster Mounts|r: "

function MM:Print(msg, ...)
	if select("#", ...) > 0 then msg = msg:format(...) end
	print(MM.PREFIX .. tostring(msg))
end

------------------------------------------------------------
-- Game event dispatch
------------------------------------------------------------
local eventFrame = CreateFrame("Frame")
local eventHandlers = {}

function MM:RegisterGameEvent(event, fn)
	if not eventHandlers[event] then
		eventHandlers[event] = {}
		pcall(eventFrame.RegisterEvent, eventFrame, event)
	end
	tinsert(eventHandlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = eventHandlers[event]
	if not list then return end
	for i = 1, #list do
		local ok, err = pcall(list[i], ...)
		if not ok then geterrorhandler()(err) end
	end
end)

------------------------------------------------------------
-- Internal messages (module-to-module signals)
------------------------------------------------------------
local listeners = {}
-- Exposed so a self-test can prove no diagnostic is unreachable from the
-- report. A diagnostic only a slash command can reach is, for the person
-- reading a pasted report, the same as one that was never written.
MM.Handlers = listeners

-- Which file registered each handler, so the profiler below can name a cost
-- instead of reporting an anonymous function. Resolved once, at registration,
-- because debug.getinfo is not something to call on a hot path.
local handlerSource = setmetatable({}, { __mode = "k" })

-- Per-handler cost, accumulated. This exists because "the addon feels slow at
-- login" is not actionable and guessing at the cause has a poor record: the
-- obvious suspect is usually the thing that was merely most recently added.
MM.Profile = {}

-- Attribution must never be able to break registration. The first version of
-- this called debug.getinfo, which does not exist in the WoW client at all --
-- the debug table is stripped from the addon environment -- so every single
-- MM:On threw and the addon did not load. It passed the offline harness only
-- because standalone Lua HAS debug, which is exactly the false confidence a
-- harness is supposed to remove.
--
-- debugstack is the client's own equivalent and is a plain global. Everything
-- here is guarded and falls back to "?" because a profiler label is worth
-- nothing and the event bus is worth everything.
-- Which file registered this handler.
--
-- Counting stack levels by hand was wrong and silently so: wrapping the call in
-- pcall adds a frame, so level 3 landed on noteSource itself and EVERY handler
-- was attributed to Core.lua. The profiler then reported one 19-second blob
-- named "Core", which is exactly as useful as no measurement at all.
--
-- So don't count frames. Take a slice of the stack and pick the first file that
-- is not this one -- that is the registering file whatever the frame depth.
local function noteSource(fn)
	if handlerSource[fn] then return end
	local name
	if debugstack then
		local ok, stack = pcall(debugstack, 2, 6, 0)
		if ok and type(stack) == "string" then
			for file in stack:gmatch("([%w_%-]+)%.lua") do
				if file ~= "Core" then name = file break end
			end
			-- a handler genuinely registered inside Core keeps that name
			name = name or stack:match("([%w_%-]+)%.lua")
		end
	end
	handlerSource[fn] = name or "?"
end

function MM:On(message, fn)
	listeners[message] = listeners[message] or {}
	tinsert(listeners[message], fn)
	noteSource(fn)
end

function MM:Fire(message, ...)
	local list = listeners[message]
	if not list then return end
	local clock = debugprofilestop
	for i = 1, #list do
		local fn = list[i]
		local startedAt = clock and clock() or nil
		local ok, err = pcall(fn, ...)
		if startedAt then
			local bucket = MM.Profile[message]
			if not bucket then bucket = {} MM.Profile[message] = bucket end
			local name = handlerSource[fn] or "?"
			local row = bucket[name]
			if not row then row = { calls = 0, ms = 0 } bucket[name] = row end
			row.calls = row.calls + 1
			row.ms = row.ms + (clock() - startedAt)
		end
		if not ok then geterrorhandler()(err) end
	end
end

-- Deferred work is the part that actually hurts. A login handler that calls
-- C_Timer.After returns in microseconds and looks free, while the job it
-- queued is what stalls the client two seconds later. Wrapping the queued
-- function is the only way to attribute that cost to whoever asked for it.
function MM.TimeIt(label, fn)
	return function(...)
		local clock = debugprofilestop
		local startedAt = clock and clock() or nil
		local results = { pcall(fn, ...) }
		if startedAt then
			local bucket = MM.Profile.DEFERRED
			if not bucket then bucket = {} MM.Profile.DEFERRED = bucket end
			local row = bucket[label]
			if not row then row = { calls = 0, ms = 0 } bucket[label] = row end
			row.calls = row.calls + 1
			row.ms = row.ms + (clock() - startedAt)
		end
		if not results[1] then geterrorhandler()(results[2]) return end
		return unpack(results, 2)
	end
end

-- Slowest first, because the only question worth asking of this report is
-- "what do I fix". Deferred work is listed separately: it does not block the
-- login frame, but it is what a player feels as the addon "loading".
MM:On("MM_LOADTIME", function()
	local rows = {}
	for message, bucket in pairs(MM.Profile) do
		for name, row in pairs(bucket) do
			rows[#rows + 1] = { message = message, name = name, ms = row.ms, calls = row.calls }
		end
	end
	if #rows == 0 then
		MM:Print("No timings recorded -- this client has no debugprofilestop.")
		return
	end
	table.sort(rows, function(a, b) return a.ms > b.ms end)

	local L = { "# Master Mounts handler cost", "",
		"Milliseconds spent inside each handler, slowest first.",
		"DEFERRED is work queued with C_Timer.After -- it does not block the",
		"login frame, but it is what a player feels as the addon loading.", "",
		("%10s  %-26s %-24s %s"):format("ms", "file", "message", "calls") }
	local total = 0
	for _, r in ipairs(rows) do
		total = total + r.ms
		L[#L + 1] = ("%10.1f  %-26s %-24s x%d"):format(r.ms, r.name, r.message, r.calls)
	end
	L[#L + 1] = ""
	L[#L + 1] = ("%10.1f  total across %d handler(s)"):format(total, #rows)

	local text = table.concat(L, "\n")
	if MM.Diagnostics and MM.Diagnostics.ShowExport then
		MM.Diagnostics.ShowExport(text, "Handler cost")
	else
		for _, line in ipairs(L) do MM:Print(line) end
	end
	MM:Print("Handler cost: %.0f ms across %d handler(s) — see the window.", total, #rows)
end)


------------------------------------------------------------
-- Taint self-diagnosis: if the client blames us for a forbidden/blocked
-- action, print the exact function so it can be reported and fixed.
------------------------------------------------------------
-- Defer the report out of the secure execution path: printing DURING the
-- forbidden event spreads our taint into the chat frame's secure buffers.
MM:RegisterGameEvent("ADDON_ACTION_FORBIDDEN", function(addonName, func)
	if addonName and addonName:find("MasterMounts") then
		local captured = tostring(func)
		C_Timer.After(0.5, function()
			MM:Print("|cffff4444FORBIDDEN call captured:|r %s — please report this exact text!", captured)
		end)
	end
end)
MM:RegisterGameEvent("ADDON_ACTION_BLOCKED", function(addonName, func)
	if addonName and addonName:find("MasterMounts") then
		local captured = tostring(func)
		C_Timer.After(0.5, function()
			MM:Print("|cffff9a3cBlocked call captured:|r %s — please report this exact text!", captured)
		end)
	end
end)

------------------------------------------------------------
-- Saved variables
------------------------------------------------------------
local accountDefaults = {
	celebration = true,       -- big splash when a hunted mount drops
	celebrationShot = true,   -- take a screenshot during the splash
	celebrateAll = false,     -- celebrate every new mount, not only planned ones
	useTomTom = true,         -- hand waypoints to TomTom when it is installed
	autoMonitor = true,       -- open the monitor HUD when a route starts
	theme = nil,             -- nil = auto (ElvUI if installed, else blizzard)
	-- First-run onboarding. Stores the SCHEMA it was completed against, not a
	-- boolean, so a future version that adds a step can re-ask without also
	-- re-asking everyone who already answered the old questions.
	onboarded = nil,         -- nil = never run; otherwise the schema completed
	onboardedAt = nil,       -- when, for diagnostics
	onboardedChoices = nil,  -- what they picked, so support can read it back
	-- Attempts are ACCOUNT-WIDE, because mounts are.
	--
	-- They lived on the character until now, so killing a boss thirty times on
	-- your main and twenty on an alt read as thirty. For an addon that tells you
	-- which character to do a thing on, counting only one of them is incoherent.
	-- Per-character counts are folded in as each character logs in.
	attempts = {},           -- [spellID] = total across the account
	attemptsMerged = {},     -- [charKey] = true, so a character folds in once
	-- Account-wide by design. The Trading Post rotation cannot be requested by
	-- an addon (see TradingPost.lua), so whichever character opens the vendor
	-- captures it for every character on the account. Learned hearthstone maps
	-- are shared for the same reason: "Wayfarer's Rest" is on the same map
	-- whoever is bound there.
	tradingPost = nil,       -- { expires, capturedBy, capturedAt, items }
	hearthMaps = nil,        -- [bind location name] = uiMapID
	arrowScale = 1,
	compactShown = false,
	ignored = {},             -- [spellID] = true, mounts you'll never chase
	hideIgnored = false,      -- ignoring MARKS; hiding is a separate filter
	mapPins = true,           -- draw mount locations on the world map
	mapPinsShowCollected = false,
	zoneAlert = true,         -- on entering a zone, list what's farmable here
	zoneAlertSeconds = 12,
	zoneAlertSticky = false,   -- pin the zone window open instead of auto-hiding
	zoneAlertAutoOpen = true,  -- open it on entering a zone that has mounts
	groupSync = { share = "none" }, -- opt-in collection sharing: none/group
	rareAlert = true,         -- pop an alert when a needed rare is up
	rareAlertWaypoint = true, -- and drop a waypoint on it
	lockouts = {},            -- account-wide per-encounter save roster
	alts = {},                -- per-character progress snapshots
	-- chat announcements when a mount is collected (opt-in; public channels
	-- are separately opt-in so nobody spams Trade by accident)
	announce = {
		enabled = false,
		guild = true, group = true,
		say = false, trade = false, general = false,
		plannedOnly = false,
	},
	monitorPos = nil,
	compactPos = nil,
	arrowPos = nil,
	-- persisted UI filter state (false = "All"/off; saved vars can't hold nil)
	ui = {
		colMissingOnly = false, colAvailableOnly = false,
		colExpansion = false, colCategory = false, colSort = false,
		plnAvailable = false, plnCategory = false, plnSort = false,
	},
}

local charDefaults = {
	plan = {},                -- array of { spellID = n, added = serverTime }
	routeIndex = 1,
	routeActive = false,
	attempts = {},            -- [spellID] = recorded attempt count
}

local function applyDefaults(dst, src)
	for k, v in pairs(src) do
		if dst[k] == nil then
			dst[k] = (type(v) == "table") and CopyTable(v) or v
		elseif type(v) == "table" and type(dst[k]) == "table" then
			applyDefaults(dst[k], v)
		end
	end
end

-- Point MM.db/MM.cdb at defaults IMMEDIATELY, before SavedVariables exist.
-- Roughly 120 call sites read these, and any handler that fires before
-- ADDON_LOADED (addon comms, forbidden-action reports, another addon calling
-- into us) would otherwise index a nil table and error. On ADDON_LOADED the
-- real saved tables take over.
MM.db = CopyTable(accountDefaults)
MM.cdb = CopyTable(charDefaults)

MM:RegisterGameEvent("ADDON_LOADED", function(name)
	if name ~= ADDON_NAME then return end
	MasterMountsDB = MasterMountsDB or {}
	MasterMountsCharDB = MasterMountsCharDB or {}
	applyDefaults(MasterMountsDB, accountDefaults)
	applyDefaults(MasterMountsCharDB, charDefaults)
	MM.db = MasterMountsDB
	MM.cdb = MasterMountsCharDB
	MM.dbReady = true
	MM:Fire("MM_DB_READY")
end)

MM:RegisterGameEvent("PLAYER_LOGIN", function()
	MM.playerFaction = UnitFactionGroup("player") -- "Alliance" / "Horde"
	-- pick the right side of every faction-split record before anything reads
	-- vendors, coordinates or requirements from the database
	if MM.ResolveFactionVariants then
		pcall(MM.ResolveFactionVariants, MM.playerFaction)
	end
	MM:Fire("MM_LOGIN")
end)

------------------------------------------------------------
-- Wowhead link popup (addons cannot open browsers; best possible
-- is a select-all editbox the user copies from)
------------------------------------------------------------
StaticPopupDialogs["MASTERMOUNTS_WOWHEAD"] = {
	text = "Wowhead page for %s\n(Ctrl+C to copy, then paste in your browser)",
	button1 = CLOSE or "Close",
	hasEditBox = true,
	editBoxWidth = 320,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnShow = function(self, data)
		self.editBox:SetText(data or "")
		self.editBox:HighlightText()
		self.editBox:SetFocus()
	end,
	EditBoxOnTextChanged = function(self, data)
		if self:GetText() ~= data then
			self:SetText(data or "")
			self:HighlightText()
		end
	end,
	EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
	preferredIndex = 3,
}

function MM:ShowWowheadLink(entry)
	if not entry then return end
	local url
	if entry.spellID then
		url = ("https://www.wowhead.com/spell=%d#comments"):format(entry.spellID)
	else
		url = "https://www.wowhead.com/search?q=" .. (entry.name or ""):gsub(" ", "+")
	end
	local dialog = StaticPopup_Show("MASTERMOUNTS_WOWHEAD", entry.name or "mount", nil, url)
	if dialog then dialog.data = url end
end

------------------------------------------------------------
-- Slash commands
------------------------------------------------------------
SLASH_MASTERMOUNTS1 = "/mm"
SLASH_MASTERMOUNTS2 = "/mastermounts"
-- Long diagnostic output belongs in a window, not the chat frame.
--
-- This kept being got wrong one command at a time -- report, then gaps, then
-- resolve -- so it is a helper now rather than a fourth copy of the same four
-- lines. Chat scrollback is capped and cannot be selected, and every one of
-- these exists to be read, pasted and acted on.
--
-- Capture returns a TABLE of lines. Handing that straight to ShowExport gave
-- SetText a table and drew an EMPTY window, which looked exactly like a
-- diagnostic that found nothing -- hence the concat, and hence saying so
-- explicitly when the result really is empty.
local function windowed(title, fn)
	local D = MM.Diagnostics
	if not (D and D.Capture and D.ShowExport) then return fn() end
	local text = table.concat(D.Capture(fn) or {}, "\n")
	if text == "" then text = "Nothing to report." end
	D.ShowExport(text, title)
end

SlashCmdList.MASTERMOUNTS = function(input)
	input = (input or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if input == "" or input == "show" then
		MM:Fire("MM_TOGGLE_MAIN")
	elseif input == "plan" then
		MM:Fire("MM_TOGGLE_MAIN", 2)
	elseif input == "monitor" then
		MM:Fire("MM_TOGGLE_MONITOR")
	elseif input == "compact" then
		MM:Fire("MM_TOGGLE_COMPACT")
	elseif input == "route" then
		MM:Fire("MM_ROUTE_TOGGLE")
	elseif input == "easiest" then
		MM:Fire("MM_EASIEST")
	elseif input == "audit" then
		MM:Fire("MM_AUDIT")
	elseif input == "events" then
		MM:Fire("MM_EVENTS_DEBUG")
	elseif input == "callings" then
		MM.Callings.Request()
		MM:Fire("MM_CALLINGS_DEBUG")
	elseif input == "callings clear" then
		MM:Fire("MM_CALLINGS_CLEAR")
	elseif input == "post" then
		MM:Fire("MM_TRADINGPOST_DEBUG")
	elseif input == "rarity" then
		MM:Fire("MM_RARITY_DEBUG")
	elseif input == "report" or input == "diag" then
		-- "diag" is the obvious name for it and doing nothing is a poor answer to
		-- a near miss.
		MM:Fire("MM_REPORT")
	elseif input == "check" then
		MM:Fire("MM_FULLCHECK")
	elseif input == "selftest" then
		MM:Fire("MM_SELFTEST")
	elseif input == "matrix" then
		MM:Fire("MM_WEIGHTS_MATRIX_EXPORT")
	elseif input == "layers" then
		MM:Fire("MM_LAYERS_DEBUG")
	elseif input == "routeinfo" then
		MM:Fire("MM_ROUTE_DEBUG")
	elseif input == "weights" then
		MM:Fire("MM_WEIGHTS_DEBUG")
	elseif input == "assaults" then
		MM:Fire("MM_ASSAULTS_DEBUG")
	elseif input == "gates" then
		MM:Fire("MM_GATES_DEBUG")
	elseif input == "bags" then
		MM:Fire("MM_CARRIED_DEBUG")
	elseif input == "travel" then
		MM:Fire("MM_TRAVEL_DEBUG")
	elseif input == "whynot" then
		MM:Fire("MM_WHYNOT_DEBUG")
	elseif input == "welcome" then
		MM:Fire("MM_ONBOARDING")
	elseif input:match("^session") then
		MM:Fire("MM_SESSION", strtrim(input:sub(8)))
	elseif input == "contribute" then
		MM:Fire("MM_CONTRIBUTE")
	elseif input == "contribute import" then
		MM:Fire("MM_CONTRIBUTE_IMPORT")
	elseif input == "contribute clear" then
		MM.Contribute.Clear()
	elseif input == "queue" then
		MM:Fire("MM_QUEUE_DEBUG")
	elseif input == "release" then
		MM:Fire("MM_RELEASE_DEBUG")
	elseif input == "sources" or input:match("^sources ") then
		MM:Fire("MM_SOURCES", input:match("^sources%s+([%d.]+)"))
	elseif input == "sourcesexport" or input:match("^sourcesexport ") then
		MM:Fire("MM_SOURCES_EXPORT", input:match("^sourcesexport%s+([%d.]+)"))
	elseif input == "routertest" or input:match("^routertest ") then
		MM:Fire("MM_ROUTERTEST", input:match("^routertest%s+(%d+)"))
	elseif input == "routertestexport" or input:match("^routertestexport ") then
		MM:Fire("MM_ROUTERTEST_EXPORT", input:match("^routertestexport%s+(%d+)"))
	elseif input == "loadtime" then
		MM:Fire("MM_LOADTIME")
	elseif input:match("^sounds") then
		-- Find a SOUNDKIT entry by name instead of guessing one.
		-- Two murloc guesses have already been wrong; the client holds the real
		-- list, so ask it.
		-- `/mm sounds try <id>` plays a raw FileDataID. SOUNDKIT does not name
		-- every sound the client owns, so this is the only way to find one --
		-- and hearing it is the only proof it is the right one.
		local tryID = input:match("^sounds%s+try%s+(%d+)$")
		if tryID then
			local ok, willPlay = pcall(PlaySoundFile, tonumber(tryID), "Master")
			MM:Print((ok and willPlay ~= false)
				and ("Played file %s. If that is the one, tell me and I will add it."):format(tryID)
				or ("File %s did not play on this client."):format(tryID))
			return
		end

		local pat = input:match("^sounds%s+(.+)$")
		if not pat then
			MM:Print("Usage: /mm sounds <text>   or  /mm sounds try <fileDataID>")
		elseif not SOUNDKIT then
			MM:Print("SOUNDKIT is not available on this client.")
		else
			local hits = {}
			for k, v in pairs(SOUNDKIT) do
				if type(k) == "string" and k:lower():find(pat:lower(), 1, true) then
					hits[#hits + 1] = ("%s = %s"):format(k, tostring(v))
				end
			end
			table.sort(hits)
			if #hits == 0 then
				MM:Print("No SOUNDKIT entry matching '%s'.", pat)
			else
				MM:Print("%d match(es) for '%s':", #hits, pat)
				for i = 1, math.min(#hits, 25) do MM:Print("   %s", hits[i]) end
				if #hits > 25 then MM:Print("   ...and %d more.", #hits - 25) end
			end
		end
	elseif input == "mountaudit" then
		-- The client is the only authority on which mounts exist. Comparing
		-- against another addon's tables only ever says what THEY have.
		if MM.MountAudit then MM.MountAudit()
		else MM:Print("Dev command: add tools/RareLootResolve.lua to the .toc first.") end
	elseif input == "rareloot show" then
		-- Reopen the last result. The pass takes minutes; losing the window
		-- should not mean running it again.
		local text = MM.RareLootResult or (MM.db and MM.db.rareLootResult)
		if text and MM.Diagnostics and MM.Diagnostics.ShowExport then
			MM.Diagnostics.ShowExport(text, "Rare loot resolution")
		else
			MM:Print("No stored result - run /mm rareloot first.")
		end
	elseif input == "rareloot" then
		-- Dev only, and absent unless the harvest files are in the .toc, so the
		-- shipped build neither carries the data nor advertises the command.
		if MM.RareLootResolve then
			MM.RareLootResolve()
		else
			MM:Print("Dev command: add tools/RareLootHarvest.lua and tools/RareLootResolve.lua to the .toc first.")
		end
	elseif input == "flightpoints" then
		MM:Fire("MM_FLIGHTPOINTS_DEBUG")
	elseif input == "score" then
		MM:Fire("MM_SCORE_DEBUG")
	elseif input == "known" then
		MM:Fire("MM_KNOWN_DEBUG")
	elseif input == "costs" then
		MM:Fire("MM_COSTS_DEBUG")
	elseif input == "timemodel" then
		MM:Fire("MM_TIMEMODEL_DEBUG")
	elseif input == "crafting" then
		MM:Fire("MM_CRAFTING_DEBUG")
	elseif input == "zone show" then
		-- so the window can be summoned on demand rather than by walking
		-- somewhere, which is the only way it used to be testable
		MM:Fire("MM_ZONE_SHOW")
	elseif input == "onboarding" then
		MM:Fire("MM_ONBOARDING_DEBUG")
	elseif input == "zone" then
		MM:Fire("MM_ZONE_DEBUG")
	elseif input == "compare" then
		MM.GroupSync.Request()
	elseif input == "group" then
		MM:Fire("MM_GROUPSYNC_DEBUG")
	elseif input == "theme" then
		MM:Fire("MM_THEME_DEBUG")
	elseif input == "theme elvui" then
		MM.Theme.Set("elvui")
	elseif input == "theme blizzard" then
		MM.Theme.Set("blizzard")
	elseif input == "ids" then
		windowed("ID coverage", function() MM:Fire("MM_IDS_DEBUG") end)
	elseif input == "resolve" then
		-- Resolve runs across frames, so the window has to wait for the result
		-- rather than wrap the call. Say something now so the delay reads as
		-- work rather than as nothing happening.
		MM:Print("Resolving ids — this runs over several frames...")
		MM.IDs.Resolve(true, function(summary)
			windowed("ID resolution", function()
				MM:Print(summary)
				MM:Fire("MM_IDS_DEBUG")
			end)
		end)
	elseif input == "gaps" then
		-- Into a window, not the chat frame. This is a long list whose whole
		-- purpose is to be acted on -- pasted, worked through, sent back -- and
		-- chat scrollback cannot be selected.
		if MM.Diagnostics and MM.Diagnostics.Capture and MM.Diagnostics.ShowExport then
			-- Capture returns a TABLE of lines, not a string. Handing it straight
			-- to ShowExport gave SetText a table and drew an empty window --
			-- which looked exactly like a diagnostic that found nothing.
			local lines = MM.Diagnostics.Capture(function() MM:Fire("MM_GAPS_DEBUG") end)
			local text = table.concat(lines or {}, "\n")
			if text == "" then text = "No gaps reported." end
			MM.Diagnostics.ShowExport(text, "Remaining gaps")
		else
			MM:Fire("MM_GAPS_DEBUG")
		end
	elseif input == "spells" then
		MM:Fire("MM_SPELLS_EXPORT")
	elseif input == "stubs" then
		MM:Fire("MM_STUBS_EXPORT")
	elseif input == "export" then
		MM.IDs.Export()
	else
		MM:Print("Commands: /mm show | plan | monitor | compact | route | easiest")
		MM:Print("          |cff40d860/mm check|r — run every diagnostic and report")
		MM:Print("          |cff40d860/mm report|r — full copyable log (also Options > Diagnostics)")
		MM:Print("          /mm audit | events | callings | post | travel | bags | gates | assaults | weights | routeinfo | layers | whynot | matrix | zone | zone show | welcome | onboarding | crafting | known | release | score | sources")
		MM:Print("          /mm contribute [import|clear] — fill the data gaps")
		MM:Print("          /mm session [20|45|90|180|stop] — a plan that fits the time you have")
		MM:Print("          /mm ids | resolve | export | stubs | spells | selftest")
	end
end
