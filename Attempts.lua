-- Master Mounts: how many times you have actually tried.
--
-- Two problems, and the second one is the interesting one.
--
-- 1. THEY WERE COUNTED PER CHARACTER. Mounts are account-wide; killing a boss
--    thirty times on your main and twenty on an alt read as thirty. For an
--    addon that tells you which character to do a thing on, counting only one
--    of them is incoherent. Counts now live on the account, and each
--    character's existing tally is folded in once, the first time it logs in.
--
-- 2. WHAT THE NUMBER MEANS. "You have tried this 47 times" is a fact with no
--    handle on it. The useful question is *where that sits* -- 47 tries at 1 in
--    50 is ordinary; 47 tries at 1 in 5 would be remarkable.
--
--    So the honest statistic is P(still nothing after n attempts) = (1-p)^n.
--    If that comes to 2%, then 98 collectors in 100 would have it by now.
--
--    AND THE ODDS NEXT TIME ARE UNCHANGED. Drops are memoryless. Plenty of
--    addons imply a pity timer that does not exist, and a collector who
--    believes they are "due" makes worse decisions than one who knows they are
--    not. Saying both things in the same breath is the only honest framing:
--    you have been unlucky, and that buys you nothing.
local _, MM = ...

MM.Attempts = {}
local A = MM.Attempts
local U = MM.Util

local function charKey()
	return ("%s-%s"):format(UnitName("player") or "?", GetRealmName() or "?")
end

------------------------------------------------------------
-- Storage
------------------------------------------------------------
local function store()
	MM.db.attempts = MM.db.attempts or {}
	return MM.db.attempts
end

-- Fold a character's old per-character tally into the account total, once.
--
-- Summing is right: they are genuinely separate attempts at the same mount.
-- The flag is per character rather than global, so an alt that has not logged
-- in since the change still contributes when it does.
function A.Migrate()
	if not (MM.db and MM.cdb) then return 0 end
	MM.db.attemptsMerged = MM.db.attemptsMerged or {}
	local key = charKey()
	if MM.db.attemptsMerged[key] then return 0 end

	local moved = 0
	local acct = store()
	for spellID, n in pairs(MM.cdb.attempts or {}) do
		if type(n) == "number" and n > 0 then
			acct[spellID] = (acct[spellID] or 0) + n
			moved = moved + n
		end
	end
	MM.db.attemptsMerged[key] = true
	if moved > 0 then
		MM:Print("Folded %d attempt%s from %s into the account-wide total.",
			moved, moved == 1 and "" or "s", key)
		MM:Fire("MM_ATTEMPT")
	end
	return moved
end

function A.Get(spellID)
	if not spellID then return 0 end
	return store()[spellID] or 0
end

function A.Record(spellID)
	if not spellID then return end
	local acct = store()
	acct[spellID] = (acct[spellID] or 0) + 1
	-- The per-character count is kept as a local tally so "how many on THIS
	-- character" stays answerable, but it is no longer the number anyone reads.
	if MM.cdb and MM.cdb.attempts then
		MM.cdb.attempts[spellID] = (MM.cdb.attempts[spellID] or 0) + 1
	end
	A.RecordTime(spellID)
	MM:Fire("MM_ATTEMPT", spellID, acct[spellID])
	return acct[spellID]
end

------------------------------------------------------------
-- One kill, every mount it could have dropped
------------------------------------------------------------
-- A BOSS THAT DROPS TWO MOUNTS IS ONE KILL AND TWO ATTEMPTS.
--
-- Twelve npc ids in the database carry more than one kill-source record --
-- Coren Direbrew has both Brewfest mounts, three ids carry three mounts each --
-- and the watch list held one spellID per npc, so the later record overwrote
-- the earlier one and only ever counted the survivor. On a Brewfest kill one
-- mount's odds moved and the other's did not.
--
-- The dedupe lives HERE rather than at each call site, because there are four
-- call sites and several of them see the same kill through different signals.
local SOURCE_MEMORY = 900        -- how long a source is remembered, seconds

-- A KILL SEEN THROUGH TWO SIGNALS IS STILL ONE KILL.
--
-- ENCOUNTER_END knows the boss NAME. LOOT_OPENED knows the corpse GUID, and so
-- the creature id. Nothing links those two directly, and the first attempt at
-- this compared spellIDs inside a two-minute window -- so looting the corpse at
-- 121 seconds counted the kill twice, and the number 120 was doing the work.
--
-- The link is modelled instead. Whichever signal arrives first CLAIMS a source
-- against the creature it concerns; the second finds that claim and files
-- itself under the same source, which has already paid. Nothing about elapsed
-- time decides it -- the claim is consumed by the counterpart that matches it,
-- so a corpse looted twenty seconds after the kill and one looted five minutes
-- after behave identically.
--
-- CLAIMS ARE ONLY EVER HONOURED ACROSS PATHS. Two corpses of one rare are two
-- loots of the same creature and must stay two attempts, so a loot never
-- inherits another loot's source.
local claims = {}       -- token -> { key = sourceKey, path = path, at = seconds }
local creditedBy = {}   -- sourceKey -> { at = seconds, [spellID] = true }

local function nowSeconds()
	return (GetTime and GetTime()) or (time and time()) or 0
end

-- Cleanup, NOT correlation. Correlation is the claim being consumed; this only
-- stops a kill nobody ever looted from holding a claim for the rest of the
-- session. Long enough that no real pairing is torn apart by it.
local function sweep(now)
	for k, v in pairs(creditedBy) do
		if now - (v.at or 0) > SOURCE_MEMORY then creditedBy[k] = nil end
	end
	for k, v in pairs(claims) do
		if now - (v.at or 0) > SOURCE_MEMORY then claims[k] = nil end
	end
end

-- Exposed so a check can prove the dedupe without waiting out its memory.
function A.ForgetSources()
	wipe(creditedBy)
	wipe(claims)
end

-- Record one attempt per mount for a single source.
--
-- THIS IS THE OWNER OF SOURCE DEDUPLICATION. Callers say what happened and
-- where; whether it counts is decided here and nowhere else. A caller keeping
-- its own "have I seen this corpse" table may skip work, but it must not be
-- what makes the answer right.
--
--   sourceKey  the thing that produced the attempt: a corpse GUID, an encounter
--              identity, a quest id. A source pays each mount at most once.
--   path       "loot" | "kill" | "quest" -- which signal saw it.
--   link       correlation tokens ("npc:1234", "spell:5678") naming what this
--              concerns, so the other signal for the same kill can find it.
--
-- Returns how many attempts were actually recorded, which is not always how
-- many were offered -- that difference IS the dedupe working.
function A.RecordMany(spellIDs, sourceKey, path, link)
	if type(spellIDs) ~= "table" then return 0 end
	local now = nowSeconds()
	sweep(now)

	-- The same kill arriving down the other pipe: adopt the source it has
	-- already paid under rather than opening a second one.
	local key, adopted = sourceKey, false
	if link then
		for _, token in ipairs(link) do
			local c = claims[token]
			if c and c.path ~= path then
				key, adopted = c.key, true
				claims[token] = nil   -- a claim links two signals, not three
				break
			end
		end
	end

	local seen
	if key then
		seen = creditedBy[key]
		if not seen then seen = { at = now } creditedBy[key] = seen end
		seen.at = now
	end

	local recorded = 0
	for _, spellID in ipairs(spellIDs) do
		if not (seen and seen[spellID]) then
			if seen then seen[spellID] = true end
			A.Record(spellID)
			recorded = recorded + 1
		end
	end

	-- Leave a claim for a counterpart that has not arrived yet. Not after
	-- adopting one: that pairing is complete, and re-claiming would let a third
	-- signal chain onto it.
	if link and key and not adopted then
		for _, token in ipairs(link) do
			claims[token] = { key = key, path = path, at = now }
		end
	end
	return recorded
end

------------------------------------------------------------
-- How long an attempt actually takes
------------------------------------------------------------
-- Only ~22% of records state a timePerAttempt, so for most of the collection
-- the time model ran on a category default -- a better guess, but still a
-- guess, and every downstream estimate inherited it.
--
-- The addon is already standing right where the answer is. It knows when each
-- attempt happened; the gap between consecutive attempts IS how long one cycle
-- takes for that content. Nobody has to time anything or fill anything in.
--
-- MEDIAN, not mean. Attempt gaps are full of logouts, dinner and alt-tabs, and
-- a single overnight gap would drag a mean into nonsense. The median ignores
-- them by construction.
local MAX_SANE_GAP = 180 * 60 -- 3h: past this you stopped playing, not farming
local MIN_SAMPLES  = 3        -- below this it is an anecdote, not a measurement
local KEEP         = 21       -- 21 stamps -> up to 20 gaps

function A.RecordTime(spellID)
	local now = GetServerTime and GetServerTime() or nil
	if not (spellID and now) then return end
	MM.db.attemptTimes = MM.db.attemptTimes or {}
	local list = MM.db.attemptTimes[spellID]
	if not list then list = {}; MM.db.attemptTimes[spellID] = list end
	list[#list + 1] = now
	while #list > KEEP do tremove(list, 1) end
end

-- Measured minutes per attempt, or nil when there is not enough to say.
-- Returning nil is the honest answer and the caller falls back -- a number
-- invented from one sample would be indistinguishable from a real one.
function A.MeasuredVisitMinutes(spellID)
	local list = spellID and MM.db and MM.db.attemptTimes and MM.db.attemptTimes[spellID]
	if not list or #list < MIN_SAMPLES + 1 then return nil end
	local gaps = {}
	for i = 2, #list do
		local g = list[i] - list[i - 1]
		if g > 0 and g <= MAX_SANE_GAP then gaps[#gaps + 1] = g end
	end
	if #gaps < MIN_SAMPLES then return nil end
	table.sort(gaps)
	local mid = #gaps % 2 == 1 and gaps[(#gaps + 1) / 2]
		or (gaps[#gaps / 2] + gaps[#gaps / 2 + 1]) / 2
	return math.max(mid / 60, 1), #gaps
end

------------------------------------------------------------
-- What the number means
------------------------------------------------------------
-- Returns the probability that a collector with this drop rate would STILL
-- have nothing after this many attempts, or nil when we cannot say.
--
-- This is the whole point: it converts a raw count into "you have been
-- unluckier than X% of people", which is the thing a collector actually wants
-- to know and cannot work out in their head.
function A.Unluckiness(rec, tries)
	if not (rec and rec.dropRate and tries and tries > 0) then return nil end
	local p = rec.dropRate / 100
	if p <= 0 or p >= 1 then return nil end
	return (1 - p) ^ tries
end

-- The human line. Deliberately says BOTH things.
function A.Line(rec, spellID)
	local tries = A.Get(spellID)
    if tries <= 0 then return nil end
	local base = ("You have tried this %d time%s"):format(tries, tries == 1 and "" or "s")

	local still = A.Unluckiness(rec, tries)
	if not still then return base end

	local luckier = (1 - still) * 100
	-- Only speak up when the streak is genuinely remarkable.
	--
	-- The offline harness caught this: two tries at a 50% drop reports
	-- "unluckier than 75% of collectors", which is arithmetically true and
	-- editorially false. Two tries is nothing. Framing it as misfortune
	-- manufactures a grievance out of an ordinary Tuesday, and an addon that
	-- does that trains people to distrust the numbers that DO matter.
	--
	-- The bar is the unluckiest tenth, and at least a handful of attempts --
	-- because "unluckier than 90% of collectors" after two tries at a common
	-- drop is a statement about small numbers, not about luck.
	if luckier < 90 or tries < 5 then
		return base .. (" — about par for a %s drop"):format(
			U.Percent and U.Percent(rec.dropRate) or (rec.dropRate .. "%"))
	end
	return ("%s — unluckier than %.0f%% of collectors. The odds next time are "
		.. "still %s; there is no pity timer."):format(base, luckier,
		U.Percent and U.Percent(rec.dropRate) or (rec.dropRate .. "%"))
end

------------------------------------------------------------
-- Wiring
------------------------------------------------------------
MM:On("MM_LOGIN", function() C_Timer.After(2, function() pcall(A.Migrate) end) end)

------------------------------------------------------------
-- Reported, not just stored
------------------------------------------------------------
MM:On("MM_ATTEMPTS_DEBUG", function()
	local acct = store()
	local rows, total = {}, 0
	for spellID, n in pairs(acct) do
		total = total + n
		local rec = MM.DBBySpell and MM.DBBySpell[spellID]
		rows[#rows + 1] = {
			name = (rec and rec.name) or ("spell " .. tostring(spellID)),
			n = n, rec = rec,
		}
	end
	table.sort(rows, function(a, b) return a.n > b.n end)

	local merged = 0
	for _ in pairs(MM.db.attemptsMerged or {}) do merged = merged + 1 end
	MM:Print("Attempts: %d recorded across %d mount%s, account-wide "
		.. "(%d character%s folded in).", total, #rows, #rows == 1 and "" or "s",
		merged, merged == 1 and "" or "s")

	-- WHAT IS BEING WATCHED, AND WHERE ONE KILL PAYS TWICE.
	--
	-- The watch list was one mount per npc, so a shared source silently counted
	-- only the last one planned. A count of the shared ones is the trace that
	-- was missing: without it, "attempts: 0" for one Brewfest mount and a
	-- healthy number for the other reads as bad luck rather than a bug.
	if MM.Scanner and MM.Scanner.WatchedCounts then
		local npcs, pairsWatched, shared = MM.Scanner.WatchedCounts()
		MM:Print("   Watching %d npc%s for %d planned mount%s%s.",
			npcs, npcs == 1 and "" or "s",
			pairsWatched, pairsWatched == 1 and "" or "s",
			shared > 0 and (", %d of which drop more than one"):format(shared) or "")
		if shared > 0 then
			MM:Print("   A kill at a shared source counts for every mount it owes.")
		end
	end
	if #rows == 0 then
		MM:Print("   Nothing tracked yet. Kills of a planned mount's source are")
		MM:Print("   counted automatically -- no setup, and no clicking.")
		return
	end
	for i = 1, math.min(#rows, 12) do
		local r = rows[i]
		local still = r.rec and A.Unluckiness(r.rec, r.n)
		MM:Print("   %-34s %4d  %s", r.name, r.n,
			still and ("unluckier than %.0f%% of collectors"):format((1 - still) * 100)
				or "no rate recorded, so no context")
	end
	if #rows > 12 then MM:Print("   ...and %d more", #rows - 12) end
	MM:Print("   Drops are memoryless: a long streak changes nothing about the")
	MM:Print("   next attempt. This is context, never a prediction.")
end)

------------------------------------------------------------
-- Paragon caches: a completion the client volunteers
------------------------------------------------------------
-- Asked directly: are paragon and chest mounts registering their completion
-- and moving the route on? They were not, and the reason is bigger than
-- paragon. An attempt is recorded from exactly three places -- a combat-log
-- npc kill, an encounter name, and a record's `trackingQuest`. The first is
-- REGISTERED ONLY ON PRE-12.0 CLIENTS, and no record in the database carries a
-- trackingQuest, so on Midnight the only live source is a boss kill by name.
-- Fifteen paragon goals and twenty-one chest goals registered nothing at all.
--
-- Paragon is the half that can be fixed exactly, with no invented ids. The
-- client already answers `hasRewardPending` per faction, and the addon already
-- reads it -- Conditions.evalRep uses it to stop a paragon mount being ranked
-- as a pickup. Opening the cache flips it true -> false, and that transition is
-- the completion: the cache is gone, the bar has reset, and there is nothing
-- more to do at that vendor today.
--
-- The chest half is NOT fixed here and is not pretended to be. It needs a
-- tracking quest id per treasure, and inventing 21 of them is exactly the
-- failure mode this database refuses.
local paragonPending = {}     -- [factionID] = cache waiting, last time we looked
local paragonGoals            -- [factionID] = { spellID, ... }, built once

local function buildParagonGoals()
	paragonGoals = {}
	for _, rec in ipairs(MM.DBList or {}) do
		if rec.spellID and rec.obtainable then
			for _, cond in ipairs(rec.conditions or {}) do
				if cond.type == "REP" and cond.standingName == "Paragon"
					and cond.factionID then
					paragonGoals[cond.factionID] = paragonGoals[cond.factionID] or {}
					tinsert(paragonGoals[cond.factionID], rec.spellID)
				end
			end
		end
	end
	return paragonGoals
end

local function pollParagon()
	if not (C_Reputation and C_Reputation.GetFactionParagonInfo) then return end
	for factionID, spellIDs in pairs(paragonGoals or buildParagonGoals()) do
		local ok, _, _, _, hasRewardPending =
			pcall(C_Reputation.GetFactionParagonInfo, factionID)
		local now = (ok and hasRewardPending) or false
		local was = paragonPending[factionID]
		paragonPending[factionID] = now
		-- ONLY the true -> false edge. `nil -> false` is the first look at a
		-- faction with no cache waiting, which is not a completion, and
		-- treating it as one would record an attempt at every login.
		if was == true and now == false then
			for _, spellID in ipairs(spellIDs) do
				A.paragonSpent = spellID   -- read by the router's advance rule
				A.Record(spellID)
			end
			A.paragonSpent = nil
		end
	end
end

-- Opening a cache changes bags and reputation, and both fire already. The
-- delayed bag event is the reliable one -- the cache is looted, then the items
-- land -- and UPDATE_FACTION covers earning the next one.
MM:RegisterGameEvent("BAG_UPDATE_DELAYED", pollParagon)
MM:RegisterGameEvent("UPDATE_FACTION", pollParagon)
MM:On("MM_LOGIN", function()
	-- Seed the baseline without recording anything: the first look establishes
	-- what is pending, and only later changes mean a cache was opened.
	C_Timer.After(5, function() buildParagonGoals() pollParagon() end)
end)
MM:On("MM_SCANNED", function() paragonGoals = nil end)

-- Is this goal gated on a paragon cache? The router needs to know, because a
-- spent cache means "nothing more here today" exactly like a daily lockout,
-- and a paragon record carries no `attempts` field to say so.
function A.IsParagonGoal(rec)
	if not rec then return false end
	for _, cond in ipairs(rec.conditions or {}) do
		if cond.type == "REP" and cond.standingName == "Paragon" then return true end
	end
	return false
end
