-- Master Mounts availability: computes each mount's actionable state —
-- collected, available now, locked out (daily/weekly), requirement-gated,
-- holiday-inactive, or unobtainable.
local _, MM = ...
local U = MM.Util

MM.Availability = {}
local A = MM.Availability

-- Which build this is, read once. GetStatus runs for every mount in several
-- lists, and the answer cannot change without a client restart. Guarded because
-- a nil here would make unreleased content look released, which is the failure
-- worth avoiding: better to keep saying "not yet" than to route somebody at
-- something that is not there.
local interfaceVersion = select(4, GetBuildInfo())
if type(interfaceVersion) ~= "number" then interfaceVersion = 0 end

-- The next patch that has NOT shipped, in the client's own interface encoding
-- (major*10000 + minor*100 + patch: 12.0.7 is 120007, 12.1 is 120100).
--
-- BUMP THIS WHEN A PATCH SHIPS. It is the default for a record flagged
-- `unreleased = true` -- see GetStatus. Left pointing at a build that has
-- already arrived, that flag stops gating anything and does so silently.
local NEXT_UNRELEASED_BUILD = 120200

------------------------------------------------------------
-- Holiday detection (calendar scan)
------------------------------------------------------------
A.activeEvents = {}   -- [event title] = true, today's HOLIDAY calendar events

A.HOLIDAY_KEYWORDS = {
	"Brewfest", "Hallow's End", "Love is in the Air", "Noblegarden",
	"Midsummer", "Winter Veil", "Darkmoon Faire", "Lunar Festival",
	"Timewalking", "Anniversary", "Pilgrim", "Call of the Scarab",
}

A.calendarLoaded = false
A.twActive = false -- Timewalking week running right now
A.twEra = nil      -- era name if we could parse it, else nil (= unknown)

-- The Timewalking calendar entry only exists on its start/end Tuesdays
-- ("Begins"/"Ends" markers) — on any other weekday, today's calendar shows
-- nothing. So: a TW week is active if a Begins marker exists within the past
-- 7 days (scanning back across the month boundary when needed).
local function scanTimewalkingWindow(today)
	A.twActive, A.twEra, A.twEndingEra = false, nil, nil
	-- The month is already anchored by scanCalendar before this runs; anchoring
	-- again here was the second leg of a recursion.
	local prevInfo = C_Calendar.GetMonthInfo and select(2, pcall(C_Calendar.GetMonthInfo, -1))
	local prevDays = (type(prevInfo) == "table" and prevInfo.numDays) or 31

	-- A Timewalking week changes over on a Tuesday, and that Tuesday carries
	-- BOTH markers: the outgoing week's END and the incoming week's START. The
	-- old code took whichever era parsed first across a 7-day backward scan, so
	-- on changeover day it reported LAST week's era -- and then era-locked the
	-- vendor to the wrong expansion, dropping this week's purchasable mounts out
	-- of the plan entirely.
	--
	-- The era that matters is the one that STARTED. Never the one that ended.
	local startedToday, endedToday, ongoing

	for delta = 0, 7 do
		local monthOffset, day = 0, today.monthDay - delta
		if day < 1 then
			monthOffset, day = -1, prevDays + day
		end
		local ok, num = pcall(C_Calendar.GetNumDayEvents, monthOffset, day)
		for i = 1, (ok and num or 0) do
			local okEv, ev = pcall(C_Calendar.GetDayEvent, monthOffset, day, i)
			if okEv and ev and ev.title and ev.title:lower():find("timewalking", 1, true) then
				-- era comes from the holiday details, not the generic title
				local okHol, hol = pcall(C_Calendar.GetHolidayInfo, monthOffset, day, i)
				local era = MM.Timewalking.ParseEra((ev.title .. " "
					.. ((okHol and hol and hol.name) or "") .. " "
					.. ((okHol and hol and hol.description) or "")):lower())

				if delta == 0 then
					A.twActive = true -- any marker today means a week is running
					if ev.sequenceType == "END" then
						endedToday = endedToday or era
					else
						startedToday = startedToday or era
					end
				elseif ev.sequenceType ~= "END" then
					-- a week that began earlier and has not ended is still running
					A.twActive = true
					ongoing = ongoing or era
				end
			end
		end
	end

	-- Today's START beats anything older; an ongoing marker from earlier in the
	-- week beats today's END, which describes the week that just finished.
	A.twEra = startedToday or ongoing or endedToday
	A.twEndingEra = (startedToday and endedToday and endedToday ~= startedToday)
		and endedToday or nil
end

-- Point the calendar at the current month.
--
-- GetNumDayEvents(offset, day) is relative to the month the calendar is
-- CURRENTLY SHOWING, and nothing sets that for us. Reading offset 0 without
-- anchoring the month first can query a completely different month, which
-- returns 0 events for a day that has several -- exactly the symptom of
-- "no events today" while a Timewalking week is running.
-- CAUTION: SetAbsMonth FIRES CALENDAR_UPDATE_EVENT_LIST. Our handler for that
-- event calls scanCalendar, which calls this -- so calling it unconditionally
-- recurses until the C stack overflows and the client fails to load. That is
-- exactly what shipped in the previous build.
--
-- Two defences. Here: only move the pointer when it is actually in the wrong
-- month, so the steady state fires no events at all. And in scanCalendar: a
-- re-entrancy guard, because the first defence depends on GetMonthInfo being
-- truthful and a guard does not depend on anything.
local function anchorMonth(today)
	if not (C_Calendar and C_Calendar.SetAbsMonth and today) then return end
	local ok, info = pcall(C_Calendar.GetMonthInfo)
	if ok and type(info) == "table"
		and info.month == today.month and info.year == today.year then
		return -- already pointed at the right month; moving it would recurse
	end
	pcall(C_Calendar.SetAbsMonth, today.month, today.year)
end

-- Is the calendar's month pointer where we think it is? Reported by /mm events,
-- because a desync here silently poisons every read.
function A.CalendarMonthState()
	if not (C_Calendar and C_Calendar.GetMonthInfo) then return nil end
	local ok, info = pcall(C_Calendar.GetMonthInfo)
	if not (ok and type(info) == "table") then return nil end
	local today = C_DateAndTime.GetCurrentCalendarTime()
	return {
		month = info.month, year = info.year, numDays = info.numDays,
		todayMonth = today and today.month, todayYear = today and today.year,
		aligned = (info.month == (today and today.month))
			and (info.year == (today and today.year)),
	}
end

-- Has the server actually sent the EVENT LIST?
--
-- My previous attempt used GetMonthInfo, which returns the month's structure
-- (numDays, firstWeekday) whether or not any event data has arrived. It is
-- therefore always true, so it reported "synced" while the event list was still
-- empty -- masking the bug instead of measuring it. The only trustworthy signals
-- are having actually seen an event, or CALENDAR_UPDATE_EVENT_LIST arriving.
A.calendarEventsSeen = false
local function calendarHasData()
	return A.calendarEventsSeen == true
end
A.HasCalendarData = calendarHasData

local function doScanCalendar()
	if not (C_Calendar and C_Calendar.GetNumDayEvents) then return end
	wipe(A.activeEvents)
	local today = C_DateAndTime.GetCurrentCalendarTime()
	if not today then return end
	anchorMonth(today)
	local ok, num = pcall(C_Calendar.GetNumDayEvents, 0, today.monthDay)
	if not ok or not num then return end
	if num > 0 then
		A.calendarEventsSeen = true
		A.calendarLoaded = true
	end
	for i = 1, num do
		local ev
		ok, ev = pcall(C_Calendar.GetDayEvent, 0, today.monthDay, i)
		-- collect EVERY title; keyword matching decides relevance later
		--
		-- A 12.0 SECRET TITLE THROWS ON THE COMPARISON, not on a conversion:
		-- `ev.title ~= ""` is enough, and reported as "attempt to compare
		-- field 'title' (a secret string value)". It is then used as a TABLE
		-- KEY below, which would fail again. Reading it through the helper
		-- gives a real string or nothing, and an event we cannot name simply
		-- does not join the keyword matching.
		local title = ev and MM.Util.ReadableString(ev.title)
		if ok and ev and title then
			-- Record the type too. HOLIDAY covers Timewalking, Darkmoon Faire
			-- and micro-holidays; a guild raid someone scheduled is also an
			-- "event today" and must never be mistaken for one.
			A.activeEvents[title] = ev.calendarType or true
		end
	end
	scanTimewalkingWindow(today)
	if A.twActive then A.calendarLoaded, A.calendarEventsSeen = true, true end
	MM:Fire("MM_CALENDAR")
end

-- Re-entrancy guard, wrapped so the flag CANNOT leak.
--
-- Clearing it by hand at each exit worked, but a `return` added later would
-- leave it set and silently disable calendar scanning forever. pcall guarantees
-- the reset regardless of how the body exits, including on error.
local scanning = false
local function scanCalendar()
	if scanning then return end
	scanning = true
	local ok, err = pcall(doScanCalendar)
	scanning = false
	if not ok then geterrorhandler()(err) end
end

-- Calendar data must be REQUESTED before it can be read (OpenCalendar is a
-- data request, not a UI action). This runs automatically in the background
-- after login and retries until events actually arrive, so Timewalking and
-- holiday detection work without the player opening anything.
local calendarRequested = false

local function requestCalendar()
	if not (C_Calendar and C_Calendar.OpenCalendar) then return false end
	-- OpenCalendar lives in the Blizzard_Calendar module. Calling it before that
	-- module is loaded silently does nothing, which is exactly what a report of
	-- "calendar not synced, no events collected" looks like from the outside.
	local load = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_Calendar")
	if not loaded and load then pcall(load, "Blizzard_Calendar") end
	pcall(C_Calendar.OpenCalendar)
	return true
end

-- The server's answer arriving is itself proof the calendar is synced.
MM:RegisterGameEvent("CALENDAR_UPDATE_EVENT_LIST", function()
	A.calendarLoaded = true
	scanCalendar()
	MM:Fire("MM_CALENDAR")
end)

function A.EnsureCalendar()
	if calendarRequested then
		-- Re-request if the first attempt produced nothing; a bare re-scan of an
		-- empty cache just reports empty again.
		if not A.calendarLoaded then requestCalendar() end
		scanCalendar()
		return
	end
	calendarRequested = true
	requestCalendar()
	C_Timer.After(3, scanCalendar)
end

-- Background sync: request, then re-check a few times with backoff, since
-- calendar data streams in from the server and can lag well past login.
local function backgroundCalendarSync()
	calendarRequested = true
	requestCalendar()
	local attempt = 0
	local ticker
	ticker = C_Timer.NewTicker(4, function()
		attempt = attempt + 1
		scanCalendar()
		-- stop once we have real data, or after ~40 seconds of trying
		if A.calendarLoaded or A.twActive or attempt >= 10 then
			ticker:Cancel()
			return
		end
		if attempt % 3 == 0 then requestCalendar() end -- nudge the server again
	end)
end

-- True if any active calendar event title contains the keyword.
function A.IsEventActive(keyword)
	if not keyword then return false end
	keyword = keyword:lower()
	for title in pairs(A.activeEvents) do
		if title:lower():find(keyword, 1, true) then return true end
	end
	return false
end

-- Which holiday keyword (if any) a record depends on, from its text.
function A.HolidayKeywordFor(rec)
	local hay = ((rec.source or "") .. " " .. (rec.notes or "")):lower()
	for _, kw in ipairs(A.HOLIDAY_KEYWORDS) do
		if hay:find(kw:lower(), 1, true) then return kw end
	end
	return nil
end

MM:On("MM_LOGIN", function()
	C_Timer.After(6, function()
		pcall(RequestRaidInfo)
		backgroundCalendarSync()
	end)
end)

MM:RegisterGameEvent("CALENDAR_UPDATE_EVENT_LIST", function()
	C_Timer.After(1, scanCalendar)
end)

-- /mm events — what the calendar scan sees (for debugging event detection)
MM:On("MM_EVENTS_DEBUG", function()
	A.EnsureCalendar()
	local today = C_DateAndTime.GetCurrentCalendarTime()
	MM:Print("Today: %s-%02d-%02d (weekday %s)",
		tostring(today and today.year), tonumber(today and today.month) or 0,
		tonumber(today and today.monthDay) or 0, tostring(today and today.weekday))

	-- A month-pointer desync silently poisons every read, so state it plainly.
	local mstate = A.CalendarMonthState()
	if mstate then
		MM:Print("Calendar month: %s-%02d (%s days) — %s",
			tostring(mstate.year), tonumber(mstate.month) or 0, tostring(mstate.numDays),
			mstate.aligned and "|cff40d860aligned with today|r"
				or "|cffff4444DESYNCED from today — reads would hit the wrong month|r")
	else
		MM:Print("Calendar month: |cffff4444unavailable|r")
	end
	MM:Print("Event data received: %s", tostring(A.HasCalendarData()))

	-- Dump the WHOLE month. If any event data exists at all, it shows up here;
	-- if this is empty the server genuinely has not sent the list, and no amount
	-- of interpreting a single day's count will tell us that.
	local days = (mstate and mstate.numDays) or 31
	local total = 0
	for day = 1, days do
		local ok, num = pcall(C_Calendar.GetNumDayEvents, 0, day)
		for i = 1, (ok and num or 0) do
			local okEv, ev = pcall(C_Calendar.GetDayEvent, 0, day, i)
			if okEv and ev and ev.title then
				total = total + 1
				if total <= 40 then
					MM:Print("  %02d: %s  |cff9a9a9a[%s%s]|r", day, ev.title,
						tostring(ev.calendarType or "?"),
						ev.sequenceType and ev.sequenceType ~= "" and (" " .. ev.sequenceType) or "")
				end
			end
		end
	end
	if total == 0 then
		MM:Print("  |cffff4444No events anywhere this month — the server has not sent the event list.|r")
	else
		MM:Print("  %d event entries this month%s.", total,
			total > 40 and " (first 40 shown)" or "")
	end

	local n = 0
	for title in pairs(A.activeEvents) do
		n = n + 1
		MM:Print("  active today: %s", title)
	end
	MM:Print("Timewalking active: %s (window scan: %s) — era: %s",
		tostring(MM.Timewalking.IsActive()), tostring(A.twActive),
		tostring(MM.Timewalking.ActiveEra() or "unknown"))
	if A.twEndingEra then
		MM:Print("  |cffffd84dChangeover day:|r %s ended today, %s began.",
			A.twEndingEra, tostring(A.twEra))
	end
end)

------------------------------------------------------------
-- Instance lockouts
------------------------------------------------------------
local savedLocks = {} -- [lowercased instance name] = seconds until reset

MM:RegisterGameEvent("UPDATE_INSTANCE_INFO", function()
	wipe(savedLocks)
	for i = 1, GetNumSavedInstances() do
		local instName, _, reset, _, locked = GetSavedInstanceInfo(i)
		if instName and locked then
			savedLocks[instName:lower()] = reset
		end
	end
	MM:Fire("MM_LOCKS")
end)

local function instanceLockFor(rec)
	if not (rec.instance and rec.instance.name) then return nil end
	if rec.instance.lockout == "NONE" then return nil end
	return savedLocks[rec.instance.name:lower()]
end

local function resetTextFor(rec)
	local kind = rec.attempts or (rec.instance and rec.instance.lockout)
	if kind == "DAILY" then
		return U.FormatSeconds(C_DateAndTime.GetSecondsUntilDailyReset())
	end
	return U.FormatSeconds(C_DateAndTime.GetSecondsUntilWeeklyReset())
end

------------------------------------------------------------
-- Status
------------------------------------------------------------
------------------------------------------------------------
-- Status memo
--
-- GetStatus makes several API calls (reputation, quests, currency, lockouts).
-- Sorting the collection by difficulty evaluates it once per mount — about
-- 1,300 times in a single click — so an uncached call here is the difference
-- between an instant sort and a visible freeze. The memo is dropped whenever
-- anything that could change a status fires.
------------------------------------------------------------
-- weak keys: a rescan replaces every entry table, and we must not pin the
-- old ones in memory if an invalidation is ever missed
local statusCache = setmetatable({}, { __mode = "k" })
local cacheGeneration = 0

local function invalidateStatus()
	wipe(statusCache)
	cacheGeneration = cacheGeneration + 1
	-- Everything downstream of a status is now stale too. Announced rather than
	-- reached into, so a future cache does not have to be wired in here.
	MM:Fire("MM_STATUS_INVALIDATED")
end
A.InvalidateStatus = invalidateStatus

for _, msg in ipairs({ "MM_SCANNED", "MM_PLAN_CHANGED", "MM_LOCKS", "MM_CALENDAR",
	"MM_TRADINGPOST", "MM_MOUNT_LEARNED", "MM_IDS_RESOLVED", "MM_CARRIED", "MM_CALLINGS" }) do
	MM:On(msg, invalidateStatus)
end
for _, ev in ipairs({ "UPDATE_FACTION", "QUEST_TURNED_IN", "CURRENCY_DISPLAY_UPDATE",
	"CRITERIA_UPDATE", "PLAYER_MONEY", "BAG_UPDATE_DELAYED" }) do
	MM:RegisterGameEvent(ev, invalidateStatus)
end

-- Returns status key, detail text, conditionLines (for tooltips).
function A.GetStatus(entry)
	local cached = statusCache[entry]
	if cached then return cached[1], cached[2], cached[3] end
	local s, d, c = A.ComputeStatus(entry)
	statusCache[entry] = { s, d, c }
	return s, d, c
end

function A.ComputeStatus(entry)
	if entry.collected then return "COLLECTED", "In your collection", nil end
	local rec = entry.rec
	if not rec or rec.stub then
		return "UNKNOWN", rec and rec.source or "Not yet catalogued", nil
	end

	if rec.obtainable == false then
		-- A RECORD MAY STATE ITS OWN REASON, and when it does that wins.
		-- The generic fallback used to read "No longer obtainable", which
		-- asserts the thing was obtainable once -- true of retired TCG loot and
		-- past promotions, and untrue of anything that shipped in the files but
		-- was never switched on. Those are different facts and only one of them
		-- belongs in a status line a player reads.
		local why = rec.unobtainableReason
			or rec.category == "TCG" and "Retired TCG loot"
			or rec.category == "REMOVED" and "Removed from the game"
			or rec.category == "PROMOTION" and "Past promotion"
			or "Not obtainable"
		if rec.blackmarket then why = why .. " (watch the Black Market AH)" end
		return "UNOBTAINABLE", why, nil
	end

	-- The monthly Traveler's Log reward is earned by filling the activity bar,
	-- not bought, so it is available to anyone this month regardless of Tender.
	-- Checked before the vendor path because such a mount is usually catalogued
	-- TRADINGPOST and would otherwise report "not in this month's rotation".
	local logMount, log = MM.TradingPost.TravelersLogFind(entry)
	if logMount then
		return "AVAILABLE", ("THIS MONTH'S TRAVELER'S LOG REWARD — fill the %s bar%s")
			:format(log.month or "monthly", log.endsIn
				and (" (" .. U.FormatSeconds(log.endsIn) .. " left)") or ""), nil
	end

	-- Trading Post: read live from the Perks Program API
	if rec.category == "TRADINGPOST" then
		local TP = MM.TradingPost
		local item = TP.Find(entry)
		if item then
			local have = TP.Tender()
			local cost = item.price or 0
			local ends = TP.TimeRemaining()
			local when = ends and (" — ends in " .. U.FormatSeconds(ends)) or ""
			if item.purchased then
				return "AVAILABLE", "Already purchased this month — claim it from the vendor", nil
			end
			if have >= cost then
				return "AVAILABLE", ("IN THIS MONTH'S TRADING POST — %s Tender (you have %s)%s")
					:format(U.Comma(cost), U.Comma(have), when), nil
			end
			return "GATED", ("On the Trading Post now — %s Tender (you have %s)%s")
				:format(U.Comma(cost), U.Comma(have), when), nil
		end
		if TP.HasLiveData() then
			return "HOLIDAY", "Not in this month's Trading Post rotation", nil
		end
		return "HOLIDAY", "Trading Post rotation unknown — open the Trading Post once to sync", nil
	end

	-- A window gate that applies whatever the category says. Darkmoon Faire
	-- mounts are CURRENCY purchases -- you can hold the tickets all month, but
	-- the vendor only exists during the Faire, so category alone never caught it.
	if rec.holidayGate then
		if not A.calendarLoaded then
			return "HOLIDAY", rec.holidayGate .. " — event calendar still syncing", nil
		end
		if not A.IsEventActive(rec.holidayGate) then
			return "HOLIDAY", rec.holidayGate .. " isn't running right now", nil
		end
	end

	-- Holiday / Timewalking window
	if rec.category == "HOLIDAY" or rec.category == "TIMEWALKING" then
		local eventUp, eventName
		if rec.category == "TIMEWALKING" then
			eventUp, eventName = MM.Timewalking.IsActive(), "Timewalking"
		else
			local kw = A.HolidayKeywordFor(rec)
			eventUp, eventName = (not kw) or A.IsEventActive(kw), kw
		end
		if not eventUp then
			if not A.calendarLoaded then
				return "HOLIDAY", (eventName or "Event") .. " — event calendar still syncing", nil
			end
			return "HOLIDAY", (eventName or "This event") .. " is not active right now", nil
		end
		-- TW vendor stock is era-locked: badges spend only during the RIGHT
		-- week — EXCEPT the Turbulent Timeways rewards, which every era's
		-- vendor sells (rec.anyEra, or "every era" in the source text).
		-- Third copy of this rule, now retired. This one already handled "any
		-- era"; Router.lua's did not, and they disagreed for months on Infinite
		-- Timereaver. One resolver means they cannot drift apart again.
		if rec.category == "TIMEWALKING" and rec.conditions
			and not (MM.Timewalking.IsAnyEra and MM.Timewalking.IsAnyEra(rec)) then
			local badgeVendor = false
			for _, c in ipairs(rec.conditions) do
				if c.type == "CURRENCY" and c.id == MM.Timewalking.CURRENCY_ID then
					badgeVendor = true
					break
				end
			end
			if badgeVendor then
				local active = MM.Timewalking.ActiveEra()
				local needed = MM.Timewalking.EraForRecord(rec)
				if active and needed and not active:find(needed, 1, true)
					and not needed:find(active, 1, true) then
					return "HOLIDAY", ("This week is %s Timewalking — this vendor needs %s week")
						:format(active, needed), nil
				end
			end
		end
	end

	-- Content from a patch that is not live yet. Recorded so the database is
	-- ready on release day, but there is nothing to do about it today.
	--
	-- AND IT STOPS BEING TRUE BY ITSELF, WHICH IS THE WHOLE POINT.
	--
	-- This flag used to be unconditional, so every one of the 22 12.1 mounts
	-- would still have read "not in the game yet" on 12.1 launch day -- to a
	-- player looking at them in their own journal. Fixing that would have meant
	-- an edit, a rebuild and a CurseForge upload on the morning of the patch,
	-- which is the worst possible time to need one.
	--
	-- The client already knows. `select(4, GetBuildInfo())` is the interface
	-- number, and the .toc declares 120100 -- 12.1 -- as a supported build, so
	-- the same number that says "this addon runs here" says "this content has
	-- arrived". Scanner.lua gates the 12.0 combat-log restriction on exactly
	-- this call, for exactly this reason.
	--
	-- A BARE `true` HAS TO KEEP MEANING SOMETHING.
	--
	-- It used to resolve to 120100 -- 12.1, the patch that was pending when this
	-- was written. 12.1 has shipped, so that default now sits in the past and a
	-- record flagged `unreleased = true` for the NEXT patch would sail straight
	-- through: a gate that silently stopped gating, which is worse than no gate,
	-- because nothing about it looks wrong.
	--
	-- So the default names the next unreleased build instead of a fixed one, and
	-- moves when a patch ships. The encoding is the client's own -- major*10000
	-- + minor*100 + patch, which is how 12.0.7 reads 120007 and 12.1 reads
	-- 120100 -- so this is derived, not guessed at.
	--
	-- Prefer the numeric form in data: `unreleased = 120200` says which build it
	-- waits for and cannot be left behind by a bump here.
	if rec.unreleased then
		local arrives = rec.unreleased == true and NEXT_UNRELEASED_BUILD
			or rec.unreleased
		if (interfaceVersion or 0) < arrives then
			return "PREREQ", "Not in the game yet — arrives with the next patch", nil
		end
	end

	-- Prerequisites that going there cannot satisfy: wrong class or faction, a
	-- profession you never took, an unfinished unlock quest. These are reported
	-- separately from GATED so the router can refuse to send you.
	local blocked = MM.QuestGate.HardGate(rec)
	if blocked then return "PREREQ", blocked, nil end

	-- Already carrying the thing that teaches it. This beats every other
	-- consideration: no lockout, rotation or requirement matters when the
	-- mount is one right-click away.
	local carried = MM.Acquire.Carried(entry)
	if carried then
		return "AVAILABLE",
			("IN YOUR BAGS — use %s to learn this mount"):format(
				carried.link or "the item"), nil
	end

	-- A multi-step chain reports its own progress rather than pretending the
	-- mount is a single drop.
	local chain, stillNeed = MM.Acquire.ChainProgress(rec)
	if chain and stillNeed and stillNeed > 0 and rec.acquire and rec.acquire.count then
		return "GATED", chain, nil
	end

	-- Rotating zone assault. Same reasoning as the Calling gate: the chest that
	-- drops this mount only exists while its assault is running, so recommending
	-- it on any other week sends the player somewhere nothing can happen.
	-- A rotating world event: always running somewhere, done once a week.
	if rec.rotating then
		local key = rec.rotating.key
		if MM.Assaults.WeeklyDone and MM.Assaults.WeeklyDone(key) then
			return "LOCKED", ("%s is done for this week"):format(
				rec.rotating.label or "This event")
		end
		-- NOT FINDING IT IS NOT PROOF IT IS NOT RUNNING.
		--
		-- I was careful about this for treasures and then made exactly the
		-- mistake for rotating events one file away: a missing POI returned
		-- ROTATION, which HIDES the goal. The live report caught it -- the count
		-- went 14 to 15 and the Grand Hunt, which had been the top
		-- recommendation, vanished from the plan.
		--
		-- A Grand Hunt is ALWAYS running somewhere. The only thing that makes
		-- it unavailable is having already done it this week, which is checked
		-- above. Finding the POI is a bonus that improves the WAYPOINT; failing
		-- to find it must leave the goal exactly as it was.
		--
		-- (This once claimed that a zone you are not standing in returns only
		-- permanent landmarks. That was concluded from a single scan showing no
		-- hunt, which does not distinguish "cannot be read remotely" from "no
		-- hunt was running" -- and the same scan returned Iskaara and Loamm
		-- from another continent, so remote reads plainly work. Removed rather
		-- than left as a fact nobody checked.)
		local live = MM.Assaults.FindRotating and MM.Assaults.FindRotating(rec.rotating)
		if live then
			-- THE BANNER SAYS WHETHER IT IS WORTH THE TRIP, not merely where it
			-- is. Only the first hunt each week pays the bag that holds the
			-- mount, so a description still advertising it is the strongest
			-- form of "yes, go now" this event can produce -- and it reads the
			-- same from any continent.
			local unspent = MM.Assaults.FirstRewardAvailable
				and MM.Assaults.FirstRewardAvailable(rec.rotating)
			if unspent == true then
				return "AVAILABLE", ("%s is up in %s, and this week's first run "
					.. "-- the one that pays the mount -- is still yours to take")
					:format(rec.rotating.label or "It", live.zone or "a Dragonflight zone")
			end
			return "AVAILABLE", ("%s is up in %s"):format(
				rec.rotating.label or "It", live.zone or "a Dragonflight zone")
		end
		return "AVAILABLE", ("%s rotates between zones -- heading to the last "
			.. "known one"):format(rec.rotating.label or "This event")
	end

	if rec.assault then
		local state, detail = MM.Assaults.Evaluate(rec.assault)
		if state then return state, detail, nil end
	end

	-- Timed world events, gated the same way and for the same reason.
	--
	-- Requirement — Hand of Bahmethra requires an event to be live, can we check that
	-- and make sure we gate it... Same with mawsworn soulhunter. Both are Maw
	-- events on a timer -- Tormentors of Torghast and Hunt: Shadehounds -- and
	-- the chest and the boss simply do not exist between runs. Recommending
	-- either off-cycle sends the player to an empty zone, which is exactly the
	-- Necroray Calling failure wearing a different hat.
	--
	-- Same evaluator: it already reads what is genuinely live in the Maw from
	-- the map's own area POIs, and it already fails to UNKNOWN rather than to
	-- AVAILABLE when it cannot tell.
	if rec.event then
		local state, detail = MM.Assaults.Evaluate(rec.event)
		if state then return state, detail, nil end
	end

	-- Daily Calling rotation. Must run before the lockout and boss checks:
	-- these records have no boss and no instance, and letting them fall through
	-- to the drop logic is what made them look like soloable raid loot.
	if rec.calling then
		local state, detail = MM.Callings.Evaluate(rec.calling)
		return state, detail, nil
	end

	-- Per-ENCOUNTER lockout beats instance-name matching when the record
	-- carries numeric IDs: the boss may be dead while the instance is not.
	local encDone, encReset = MM.Lockouts.RecordState(rec)
	if encDone == true then
		return "LOCKED", ("%s already defeated — resets in %s"):format(
			(rec.npc and rec.npc.name) or "Boss",
			encReset and U.FormatSeconds(encReset) or resetTextFor(rec)), nil
	elseif encDone == false then
		-- explicitly still alive this lockout; skip the instance-level check
		local allMet, lines = MM.Conditions.EvaluateAll(rec)
		if allMet == false then
			local firstUnmet
			for _, l in ipairs(lines) do
				if l.met == false then firstUnmet = l.text break end
			end
			return "GATED", firstUnmet or "Requirements not met", lines
		end
		return "AVAILABLE", rec.source or "Boss is up for you this lockout", lines
	end

	-- Attempt lockouts
	if rec.trackingQuest and C_QuestLog.IsQuestFlaggedCompleted(rec.trackingQuest) then
		return "LOCKED", "Attempted — resets in " .. resetTextFor(rec), nil
	end
	local reset = instanceLockFor(rec)
	if reset then
		return "LOCKED", ("%s cleared — resets in %s"):format(rec.instance.name, U.FormatSeconds(reset)), nil
	end

	-- Requirements
	local allMet, lines = MM.Conditions.EvaluateAll(rec)
	if allMet == false then
		local firstUnmet
		for _, l in ipairs(lines) do
			if l.met == false then firstUnmet = l.text break end
		end
		return "GATED", firstUnmet or "Requirements not met", lines
	end

	-- A record that names its quest chain should say where you are in it
	-- rather than repeat the generic source text.
	local chainState, chainText = MM.QuestGate.ChainState(rec)
	if chainState and chainState ~= "DONE" then
		return "AVAILABLE", chainText, lines
	end

	return "AVAILABLE", rec.source or "Ready to farm", lines
end
