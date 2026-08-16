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

MM.VERSION = "1.2.0"
MM.PREFIX = "|cff33c1ffMaster Mounts|r: "

-- WHEN THIS IS THE RIGHT TOOL, AND WHEN IT IS NOT.
--
-- Chat is shared with the guild, the group, loot, combat and everyone else's
-- addons. Every line spent here is a line of someone else's conversation
-- pushed off the screen, so a line has to earn its place. Three things do:
--
--   1. You asked. Everything under /mm is a direct answer to a command.
--   2. Something happened that you would want to know and cannot see -- a
--      mount dropped, a rare is up, the route moved on.
--   3. Something failed, or did nothing, where silence and success look
--      identical. A button that plays no sound is the example: without a
--      line, a working setting and a broken one read the same.
--
-- What does NOT earn a line: narrating a window that is already on screen,
-- confirming an action whose own effect is the confirmation, or repeating at
-- every login something that was true the first time. Each of those has been
-- written here at some point and each has been taken out again.
function MM:Print(msg, ...)
	if select("#", ...) > 0 then msg = msg:format(...) end
	print(MM.PREFIX .. tostring(msg))
end

-- Say it when there is something new to say.
--
-- For notices that are useful the first time and noise on repeat: which theme
-- was picked up, that flight points have now been harvested.
--
-- NOT "once, ever". Silencing a line permanently is its own bug: a player who
-- learns flight points in a new expansion, or comes back after a year, gets
-- nothing -- and the reason they get nothing is a decision taken months ago
-- that they cannot see. Two things lift the silence:
--
--   * THE MESSAGE CHANGED. Different text means different news. "learned 40
--     zones" after "learned 12" is worth saying; the same sentence twice is
--     not. This is what makes the flight-point notice self-managing.
--   * ENOUGH TIME PASSED. For text that never varies, this is the only thing
--     that can ever repeat it. A month is long enough that nobody reads it as
--     spam and short enough that a returning player is re-oriented.
--
-- Written to SavedVariables rather than a local, because "once per session" is
-- still once per login and that was the original complaint.
--
-- Returns true if it actually printed, so callers can tell the difference.
local REPEAT_AFTER = 30 * 24 * 60 * 60

function MM:PrintIfNew(key, msg, ...)
	if not (key and MM.db) then return false end
	if select("#", ...) > 0 then msg = msg:format(...) end
	MM.db.saidBefore = MM.db.saidBefore or {}
	local last = MM.db.saidBefore[key]
	local now = (time and time()) or 0
	if last and last.msg == msg and now - (last.at or 0) < REPEAT_AFTER then
		return false
	end
	MM.db.saidBefore[key] = { msg = msg, at = now }
	MM:Print(msg)
	return true
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

-- One line per distinct (event, error). Session-scoped on purpose: a reload is
-- how someone checks whether a fix took, and a persisted list would stay quiet
-- and make it look like it had.
local reportedErrors = {}
-- Counted as well as deduped, so the report can say "no handler has thrown this
-- session" and mean it. Silence is otherwise indistinguishable from the dedupe
-- working, which is exactly the thing being validated.
MM.handlerErrors = {}

eventFrame:SetScript("OnEvent", function(_, event, ...)
	local list = eventHandlers[event]
	if not list then return end
	for i = 1, #list do
		local ok, err = pcall(list[i], ...)
		if not ok then
			-- SAY IT IN CHAT AS WELL AS TO THE ERROR HANDLER.
			--
			-- Retail hides Lua errors by default, so a handler that threw left
			-- the player with nothing at all: /mm routertest printed "Modelling
			-- the router..." and then silence -- no window, no output, no
			-- error. The command looked like it did nothing, which is the
			-- hardest kind of failure to report and the easiest to fix.
			--
			-- IT NAMED NOTHING, AND IT NEVER STOPPED.
			--
			-- `message` is not a variable in this function -- the parameters
			-- are (_, event, ...) -- so it was a global nil and every line read
			-- "nil failed:". Reported from outside as exactly that, repeated
			-- down the chat frame, which is the least useful form this line
			-- could take: it says something broke and refuses to say what.
			--
			-- And a game event repeats. One handler throwing on a combat event
			-- printed once per event for the rest of the session, so the addon
			-- buried its own output. Errors here ARE rare -- that was the
			-- assumption behind printing every one -- but "rare" is a property
			-- of the bug, not of the event, and the event fires regardless.
			--
			-- Now: named, and once per distinct problem. The full error still
			-- goes to the error handler every time, so nothing is hidden from
			-- anyone actually looking.
			local key = tostring(event) .. "\0" .. tostring(err)
			if not reportedErrors[key] then
				reportedErrors[key] = true
				tinsert(MM.handlerErrors, {
					event = tostring(event),
					err = tostring(err):gsub("^.*[\\/]", ""):sub(1, 120),
				})
				MM:Print("|cffff5555%s failed:|r %s", tostring(event),
					tostring(err):gsub("^.*[\\/]", ""):sub(1, 160))
			end
			geterrorhandler()(err)
		end
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
		if not ok then
			-- SAY IT IN CHAT AS WELL AS TO THE ERROR HANDLER.
			--
			-- Retail hides Lua errors by default, so a handler that threw left
			-- the player with nothing at all: /mm routertest printed "Modelling
			-- the router..." and then silence. No window, no output, no error.
			-- The command looked like it simply did nothing, which is the
			-- hardest kind of failure to report and among the easiest to fix.
			--
			-- One line naming the command that broke. Errors here are rare; a
			-- silent one costs far more than a noisy one.
			if MM.Print then
				MM:Print("|cffff5555%s failed|r -- %s", tostring(message),
					tostring(err):sub(-160))
			end
			geterrorhandler()(err)
		end
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

------------------------------------------------------------
-- Travel capability: one fingerprint, one signal
------------------------------------------------------------
-- Route order, journey plans and origin searches are all cached against what
-- this character can currently do -- which teleports are owned and switched on,
-- where the hearthstone points, which flight points are known. Each cache used
-- to decide for itself when that had changed, and each decided differently.
-- Switching a teleport off fired MM_PLAN_CHANGED, which rebuilt the route,
-- which took a cache hit because the route signature could not see teleports at
-- all: the option moved and the route did not.
--
-- Three scopes, in increasing severity. The distinction is what stops a
-- hearthstone cooling down from throwing away a graph of 29,000 edges:
--
--   cooldown    a teleport got closer to ready. Prices move, options do not.
--   capability  what the character can press changed: gained, lost, switched
--               off, or rebound to somewhere else.
--   topology    the MAP changed: a flight point learned, the graph rebuilt.
local TRAVEL_SCOPES = { cooldown = true, capability = true, topology = true }

-- A FINGERPRINT, NOT A COUNTER.
--
-- A counter restarts at 1 on every reload, so a chart saved under revision 3
-- could never match again and every login would re-chart from scratch -- the
-- exact regression the stored chart exists to prevent. A fingerprint of what
-- the character can actually do is the same string across a reload, and a
-- different one the moment a teleport is gained, lost, switched off or rebound.
local travelPrint, travelPrintFrom

-- djb2, folded to stay inside a double. The signature is written to saved
-- variables and quoted back in cache diagnostics, so the component has to be
-- short: the raw input is a couple of thousand characters of teleport keys.
local function fold(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 4294967296
	end
	return h
end

function MM.TravelFingerprint()
	local TP = MM.Teleports
	local options = (TP and TP.Options) and TP.Options() or nil
	-- KEYED ON THE SNAPSHOT ITSELF, not on a timer and not on an event alone.
	--
	-- The teleport layer rebuilds that table whenever anything could have
	-- changed what the character can press -- on its own events, and on its own
	-- thirty-second cooldown TTL. A new table is therefore the one honest signal
	-- that this needs recomputing. Caching against events alone left the
	-- fingerprint stale for any capability change that fired none of them, which
	-- is a route signature quietly describing a character who no longer exists.
	if travelPrint and travelPrintFrom == options then return travelPrint end
	local parts = {}
	-- WHICH teleports, and where each one lands -- never WHEN it is ready.
	-- A cooldown ticking down changes what a route costs, not which routes are
	-- legal, and folding it in here would re-chart the whole plan every thirty
	-- seconds for no change anybody asked for.
	if options then
		local keys = {}
		for _, landing in ipairs(options) do
			-- The destination belongs in the key as much as the option does: a
			-- hearthstone rebound to another city is the same key pointing
			-- somewhere else, and a route built for the old city is wrong.
			keys[#keys + 1] = tostring(landing.key) .. ">" .. tostring(landing.place or "?")
		end
		table.sort(keys)
		parts[#parts + 1] = table.concat(keys, ",")
	else
		parts[#parts + 1] = "tp?"
	end
	-- Flight points, by count. Learning one changes what the graph can reach,
	-- and an order built without it was built for a world this character has
	-- already left behind.
	local maps, legs = 0, 0
	for _ in pairs(MM.db and MM.db.taxi or {}) do maps = maps + 1 end
	for _ in pairs(MM.db and MM.db.taxiLearned or {}) do legs = legs + 1 end
	parts[#parts + 1] = ("%d/%d"):format(maps, legs)
	travelPrint = tostring(fold(table.concat(parts, ";")))
	travelPrintFrom = options
	return travelPrint
end

-- THE ONE PLACE THAT SAYS TRAVEL CHANGED.
--
-- Callers name what changed and nothing else. Each layer subscribes to
-- MM_TRAVEL_CHANGED and forgets exactly what it owns -- the router its order,
-- the journey planner its answers, the graph itself only when the map moved.
function MM.TravelChanged(scope, why)
	if not TRAVEL_SCOPES[scope] then scope = "capability" end
	-- Dropped as well as keyed, because the taxi counts folded into the print
	-- are not part of the teleport snapshot and nothing else would notice them.
	travelPrint, travelPrintFrom = nil, nil
	MM:Fire("MM_TRAVEL_CHANGED", scope, why)
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
-- ONCE PER DISTINCT CALL, AND COUNTED.
--
-- Reported from a delve: MasterMountsArrowAction:Hide() blocked, repeated until
-- it filled the chat frame. Both faults are worth separating. The block itself
-- was a real bug, fixed in Arrow.lua. Printing it every single time was this
-- line's own -- a blocked call happens inside combat, combat is where an addon
-- is busiest, and "rare" describes the bug rather than the number of chances it
-- gets to fire. The handler-error reporter above learned this already; this one
-- was written before it and never revisited.
--
-- Kept as a list as well as printed, so a self-test can assert nobody's client
-- refused us anything, rather than the evidence living only in a chat frame the
-- player has to notice and paste.
MM.blockedCalls = {}
local reportedBlocks = {}
local function noteProtected(kind, colour, addonName, func)
	if not (addonName and addonName:find("MasterMounts")) then return end
	local captured = tostring(func)
	local key = kind .. "\0" .. captured
	if reportedBlocks[key] then return end
	reportedBlocks[key] = true
	tinsert(MM.blockedCalls, { kind = kind, func = captured })
	-- Deferred out of the secure execution path: printing DURING the forbidden
	-- event spreads our taint into the chat frame's secure buffers.
	C_Timer.After(0.5, function()
		MM:Print("|cff%s%s call captured:|r %s — please report this exact text!",
			colour, kind, captured)
	end)
end

MM:RegisterGameEvent("ADDON_ACTION_FORBIDDEN", function(addonName, func)
	noteProtected("FORBIDDEN", "ff4444", addonName, func)
end)
MM:RegisterGameEvent("ADDON_ACTION_BLOCKED", function(addonName, func)
	noteProtected("Blocked", "ff9a3c", addonName, func)
end)

------------------------------------------------------------
-- Saved variables
------------------------------------------------------------
local accountDefaults = {
	celebration = true,       -- big splash when a hunted mount drops
	celebrationShot = true,   -- take a screenshot during the splash
	celebrateAll = false,     -- celebrate every new mount, not only planned ones
	-- OFF. TomTom has one crazy arrow and plenty of addons write to it, so a
	-- route could be steered off mid-leg by something unrelated to mounts and
	-- look, from the outside, like Master Mounts pointing at the wrong place.
	-- Our own arrow answers to nobody else. Tick the box to hand waypoints over
	-- anyway -- the handover works live, in both directions.
	useTomTom = false,
	tomTomDefaultReset = nil, -- stamped once when the default above flipped
	autoMonitor = true,       -- open the monitor HUD when a route starts
	theme = nil,             -- nil = auto (ElvUI if installed, else Modern)
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
	-- Two surfaces, two switches, both on. `mapPins` is the world map and keeps
	-- its old name so nobody's saved setting resets; the minimap is its own.
	mapPinsMinimap = true,
	mapPinsShowCollected = false,
	-- CONTINENT ROLLUP, OFF BY DEFAULT.
	--
	-- Projecting every child zone's pins onto the continent map exists so a
	-- continent is not blank, and it works -- on some continents. The round trip
	-- through world space succeeds for Pandaria and the Broken Isles and
	-- silently produces nothing for Outland, Zandalar and the Dragon Isles,
	-- because those parent maps are not a simple projection of their children.
	--
	-- Reported from play as both symptoms at once: two continents buried under
	-- overlapping icons, and mounts "missing" on the others. Half a feature
	-- reads as two different bugs, so it is off unless asked for; the zone maps
	-- have always shown everything.
	mapPinsChildZones = false,
	-- Teleports the player has switched off by hand, keyed by option key. A
	-- saving they would rather not take -- M+ charges being the case that asked
	-- for it -- is not something the router can work out on its own.
	teleportsOff = {},
	zoneAlert = true,         -- on entering a zone, list what's farmable here
	zoneAlertSeconds = 12,
	zoneAlertSticky = false,   -- pin the zone window open instead of auto-hiding
	zoneAlertAutoOpen = true,  -- open it on entering a zone that has mounts
	groupSync = { share = "none" }, -- opt-in collection sharing: none/group
	rareAlert = true,         -- pop an alert when a needed rare is up
	rareAlertWaypoint = true, -- and drop a waypoint on it
	-- Lift the master volume for the length of the alert and put it back. On by
	-- default: someone who turned rare alerts ON wants to hear them, and a
	-- muted client is the one case where a working alert is indistinguishable
	-- from a broken one.
	rareAlertForceAudible = true,
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
	-- `plan` lives here for compatibility only -- on load it is REPLACED by a
	-- reference to the account-wide plan. See adoptAccountPlan below.
	plan = {},                -- array of { spellID = n, added = serverTime }
	routeIndex = 1,
	routeActive = false,
	attempts = {},            -- [spellID] = recorded attempt count
	-- A weekly event's first run is per character, so its completion is too.
	weeklyDone = {},          -- [gate key] = when it stops being true
}

-- THE PLAN BELONGS TO THE ACCOUNT, NOT THE CHARACTER.
--
-- Mounts are collected account-wide, and the router can report that another
-- character already qualifies -- so following its advice meant logging into a
-- character with an empty plan and no idea where you were. The plan followed
-- you nowhere.
--
-- `routeGoal` is the anchor for resuming, and it is a spellID rather than an
-- index on purpose: the route is REBUILT per character, from a different
-- position with different teleports and different things reachable. Index 7 on
-- one character is not index 7 on another, so position cannot survive the
-- switch. Identity can.
local function accountPlanDefaults(db)
	db.plan = db.plan or nil            -- nil until migrated, so we can tell
	db.routeGoal = db.routeGoal or nil  -- spellID we were heading to
end

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
	accountPlanDefaults(MM.db)
	MM.db.themeAutoFallback = nil -- remove the superseded pre-release migration key

	-- THE TOMTOM DEFAULT FLIPPED, SO EXISTING INSTALLS GET MOVED ONCE.
	--
	-- Leaving saved settings alone is normally the right instinct, and it is
	-- wrong here: `useTomTom = true` was OUR choice, not the player's, and the
	-- reason it changed is that it actively misbehaves -- other addons take
	-- TomTom's single arrow and the route silently points somewhere else. A
	-- default nobody chose, which produces a bug, is worth moving.
	--
	-- ONCE, and recorded, so a player who ticks the box straight back is never
	-- un-ticked again on a later login. There is no way to tell an inherited
	-- `true` from a deliberate one -- that distinction was never stored -- so
	-- this is announced in the changelog and the checkbox is left in plain
	-- sight rather than pretending the change was invisible.
	if not MM.db.tomTomDefaultReset then
		MM.db.tomTomDefaultReset = time()
		MM.db.useTomTom = false
	end

	-- A weekly completion moved to the character it belongs to, so the account
	-- copy is dead data nothing reads. Dropped rather than left to sit in saved
	-- variables forever looking like state.
	MM.db.weeklyDone = nil

	-- MIGRATE ONCE, THEN SHARE.
	--
	-- The first character to log in after the upgrade donates its plan; every
	-- later one MERGES rather than overwrites, because two characters with
	-- different plans both meant them and silently discarding one is the sort
	-- of data loss nobody reports, they just stop trusting the addon.
	if not MM.db.plan then MM.db.plan = {} end
	if MM.cdb.plan and #MM.cdb.plan > 0 then
		local have = {}
		for _, item in ipairs(MM.db.plan) do have[item.spellID] = true end
		for _, item in ipairs(MM.cdb.plan) do
			if item.spellID and not have[item.spellID] then
				MM.db.plan[#MM.db.plan + 1] = item
				have[item.spellID] = true
			end
		end
		wipe(MM.cdb.plan)
	end
	-- One table, two names. Every existing call site reads MM.cdb.plan and now
	-- gets the account list; nothing assigns to it, only mutates, so the
	-- reference holds.
	MM.cdb.plan = MM.db.plan
	MM.dbReady = true
	MM:Fire("MM_DB_READY")
end)

-- IS A SECOND COPY OF THIS ADDON LOADED?
--
-- An old folder left beside the current one loads as a separate addon, and
-- every symptom that produces looks like a bug in this one:
--
--   the celebration prints twice, because two copies handle NEW_MOUNT_ADDED
--   two plan windows appear, in two different styles, because both draw one
--   the plan appears to rewrite itself, because two planners are chartinng
--
-- It cost a bug report and a screenshot to work out, and none of it was
-- visible from inside: an addon cannot see another addon's frames, but it CAN
-- read the addon list. So it does.
--
-- Matched on the folder name AND on the TOC title, because a renamed folder is
-- exactly the case that produces this and the title usually survives a rename.
function MM.ConflictingCopies()
	local out = {}
	local api = C_AddOns
	if not (api and api.GetNumAddOns and api.GetAddOnInfo) then return out end
	local ok, n = pcall(api.GetNumAddOns)
	if not (ok and n) then return out end
	for i = 1, n do
		local okI, name, title = pcall(api.GetAddOnInfo, i)
		if okI and name and name ~= ADDON_NAME then
			local folder = name:lower()
			local label = (title or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):lower()
			if folder:find("mastermount", 1, true) or label:find("master mounts", 1, true) then
				local okL, loaded = pcall(api.IsAddOnLoaded, i)
				if okL and loaded then out[#out + 1] = name end
			end
		end
	end
	return out
end

MM:RegisterGameEvent("PLAYER_LOGIN", function()
	MM.playerFaction = UnitFactionGroup("player") -- "Alliance" / "Horde"
	-- Said BEFORE anything else this addon prints, because it changes what
	-- every later line means. PrintIfNew rather than Print: the folder name is
	-- in the message, so a different conflict speaks and the same one stays
	-- quiet until it is dealt with.
	local dupes = MM.ConflictingCopies()
	if #dupes > 0 then
		MM:PrintIfNew("conflict", "|cffff5555Another copy of Master Mounts is "
			.. "loaded|r (%s). Two copies double every message, draw two of "
			.. "every window and chart two plans. Delete the old AddOns folder.",
			table.concat(dupes, ", "))
	end
	-- pick the right side of every faction-split record before anything reads
	-- vendors, coordinates or requirements from the database
	if MM.ResolveFactionVariants then
		pcall(MM.ResolveFactionVariants, MM.playerFaction)
	end
	MM:Fire("MM_LOGIN")
end)

------------------------------------------------------------
-- Wowhead link popup (addons cannot open browsers; best possible
-- is a select-all editbox the player copies from)
------------------------------------------------------------
-- THE FIELD IS `EditBox` NOW, NOT `editBox`.
--
-- Reported from outside as a hard error the moment anyone clicked a row to get
-- a Wowhead link: "attempt to index field 'editBox' (a nil value)". Blizzard's
-- StaticPopup rewrite (Blizzard_StaticPopup_Game/GameDialog) renamed the
-- member, and the lowercase name has been nil since. The error dump proves it
-- -- the frame it printed lists `EditBox=StaticPopup1EditBox` and no `editBox`.
--
-- All four spellings are accepted rather than just the new one. This is a
-- cosmetic dialog on a popup Blizzard has already renamed once; hard-coding
-- whichever name is current today buys another silent break on the next pass,
-- and the global lookup is the one that has worked since Wrath.
local function popupEditBox(self)
	if not self then return nil end
	return self.EditBox or self.editBox
		or (self.GetEditBox and self:GetEditBox())
		or _G[(self.GetName and self:GetName() or "") .. "EditBox"]
end

StaticPopupDialogs["MASTERMOUNTS_WOWHEAD"] = {
	text = "Wowhead page for %s\n(Ctrl+C to copy, then paste in your browser)",
	button1 = CLOSE or "Close",
	hasEditBox = true,
	editBoxWidth = 320,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	OnShow = function(self, data)
		local box = popupEditBox(self)
		-- No box is a dialog with nothing to copy from, which is worth saying
		-- once. It is NOT worth throwing over: the popup is already on screen
		-- and an error here leaves it there, unusable and unexplained.
		if not box then
			MM:Print("Could not open the copy box — the link is: %s", tostring(data))
			return
		end
		box:SetText(data or "")
		box:HighlightText()
		box:SetFocus()
	end,
	EditBoxOnTextChanged = function(self, data)
		if self:GetText() ~= data then
			self:SetText(data or "")
			self:HighlightText()
		end
	end,
	-- StaticPopup_Hide names the dialog rather than assuming the edit box is a
	-- direct child of it. Under the new GameDialog frames it is not.
	EditBoxOnEscapePressed = function()
		StaticPopup_Hide("MASTERMOUNTS_WOWHEAD")
	end,
	preferredIndex = 3,
}

-- REPORTED FROM PLAY: Cobalt Pterrordax opened wowhead.com/spell=27, and
-- Spectral Pterrorwing opened spell=24. Both records carry the right id --
-- 275837 and 244712 -- so whatever this was handed was not the record, and I
-- have not been able to reproduce which caller does it.
--
-- Two changes, neither of which pretends to know: the record's own id wins over
-- whatever the row is carrying, and an id too small to be a mount spell is
-- refused rather than turned into a link. A name search always resolves, so the
-- fallback is a working page instead of a wrong one -- and the anomaly is
-- printed, so if it happens again it arrives with the number attached.
local MIN_PLAUSIBLE_SPELL = 1000

function MM:ShowWowheadLink(entry)
	if not entry then return end
	local spellID = (entry.rec and entry.rec.spellID) or entry.spellID
	if spellID and spellID < MIN_PLAUSIBLE_SPELL then
		MM:Print("|cffff9a3cThat link looked wrong|r -- %q offered spell id %d, "
			.. "which is too small to be a mount. Searching by name instead; "
			.. "please report this.", tostring(entry.name or "?"), spellID)
		spellID = nil
	end
	local url
	if spellID then
		url = ("https://www.wowhead.com/spell=%d#comments"):format(spellID)
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
	-- One copy, in Diagnostics, because Tests.lua needs the same thing for the
	-- full check and this file cannot be depended on from there.
	if not (D and D.Windowed) then return fn() end
	return D.Windowed(title, fn)
end

-- Report-shaped commands: everything whose answer is a page rather than a line.
--
-- ONE LINE PER COMMAND BEATS TWENTY-TWO COPIES OF FOUR. Every one of these
-- printed to a chat frame that cannot be selected and drops its oldest lines,
-- which is exactly the fault already fixed for the report, for the id export,
-- and for remaining gaps -- three times, one command at a time, while the rest
-- kept doing it.
--
-- DELIBERATELY NOT EVERYTHING. `bags`, `theme`, `attempts` and `group` answer in
-- one or two lines, and Capture strips colour, so a window would cost them their
-- highlighting to solve a problem they do not have. Length is the test, and it is
-- applied by hand because it is a judgement about reading, not a measurement.
local WINDOWED_COMMANDS = {
	release     = { "MM_RELEASE_DEBUG",     "Release readiness" },
	audit       = { "MM_AUDIT",             "Database audit" },
	travel      = { "MM_TRAVEL_DEBUG",      "Travel options" },
	fixes       = { "MM_FIXES_DEBUG",       "Fixes in this build" },
	layers      = { "MM_LAYERS_DEBUG",      "Layered ordering" },
	routeinfo   = { "MM_ROUTE_DEBUG",       "Route" },
	whynot      = { "MM_WHYNOT_DEBUG",      "Why a goal is not on the route" },
	gates       = { "MM_GATES_DEBUG",       "Prerequisite gates" },
	assaults    = { "MM_ASSAULTS_DEBUG",    "Assaults" },
	events      = { "MM_EVENTS_DEBUG",      "Events and Timewalking" },
	post        = { "MM_TRADINGPOST_DEBUG", "Trading Post" },
	score       = { "MM_SCORE_DEBUG",       "Scorecard" },
	known       = { "MM_KNOWN_DEBUG",       "Known and unknowable" },
	costs       = { "MM_COSTS_DEBUG",       "Cost coverage" },
	timemodel   = { "MM_TIMEMODEL_DEBUG",   "Time model" },
	crafting    = { "MM_CRAFTING_DEBUG",    "Crafting" },
	flightpoints= { "MM_FLIGHTPOINTS_DEBUG","Flight points" },
	queue       = { "MM_QUEUE_DEBUG",       "Queueable goals" },
	rarity      = { "MM_RARITY_DEBUG",      "Rarity coverage" },
	weights     = { "MM_WEIGHTS_DEBUG",     "Weights and priorities" },
	zone        = { "MM_ZONE_DEBUG",        "Zone alerts" },
	rowprobe    = { "MM_ROWPROBE_DEBUG",    "Planner left pane" },
	onboarding  = { "MM_ONBOARDING_DEBUG",  "Onboarding" },
}

SlashCmdList.MASTERMOUNTS = function(input)
	input = (input or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	-- Report-shaped commands first, so each is one table row rather than a
	-- branch that has to remember to ask for a window.
	local win = WINDOWED_COMMANDS[input]
	if win then
		windowed(win[2], function() MM:Fire(win[1]) end)
		return
	end
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
	elseif input == "callings" then
		MM.Callings.Request()
		MM:Fire("MM_CALLINGS_DEBUG")
	elseif input == "callings clear" then
		MM:Fire("MM_CALLINGS_CLEAR")
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
	elseif input == "bags" then
		MM:Fire("MM_CARRIED_DEBUG")
	elseif input == "onboard" or input == "welcome" then
		MM:Fire("MM_ONBOARDING")
	elseif input:match("^session") then
		MM:Fire("MM_SESSION", strtrim(input:sub(8)))
	elseif input == "contribute" then
		MM:Fire("MM_CONTRIBUTE")
	elseif input == "contribute import" then
		MM:Fire("MM_CONTRIBUTE_IMPORT")
	elseif input == "contribute clear" then
		MM.Contribute.Clear()
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
	elseif input == "zone show" then
		-- so the window can be summoned on demand rather than by walking
		-- somewhere, which is the only way it used to be testable
		MM:Fire("MM_ZONE_SHOW")
	elseif input == "compare" then
		MM.GroupSync.Request()
	elseif input == "group" then
		MM:Fire("MM_GROUPSYNC_DEBUG")
	elseif input == "theme" then
		MM:Fire("MM_THEME_DEBUG")
	elseif input == "theme elvui" then
		MM.Theme.Set("elvui")
	elseif input == "theme modern" then
		MM.Theme.Set("modern")
	elseif input == "theme blizzard" then
		MM.Theme.Set("blizzard")
	elseif input == "theme auto" then
		MM.Theme.Set("auto")
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
		MM:Print("          |cff40d860/mm fixes|r — is everything this build claims to fix still fixed?")
		MM:Print("          /mm audit | events | callings | post | travel | bags | gates | assaults | weights | routeinfo | layers | whynot | matrix | zone | zone show | onboard | welcome | onboarding | crafting | known | release | score | sources")
		MM:Print("          /mm contribute [import|clear] — fill the data gaps")
		MM:Print("          /mm session [20|45|90|180|stop] — a plan that fits the time you have")
		MM:Print("          /mm ids | resolve | export | stubs | spells | selftest")
	end
end
