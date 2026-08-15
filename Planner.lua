-- Master Mounts planner: the farm plan (what you're hunting), filters,
-- "easiest wins", and per-mount effort/attempt estimates.
local _, MM = ...
local U = MM.Util

MM.Planner = {}
local P = MM.Planner

-- Which expansion is "current" on this client (WoW major version - 1:
-- 12.x = Midnight = index 11). Used to judge whether mythic raids / world
-- bosses are still group-required or already trivially soloable legacy.
local CURRENT_EXPANSION = (tonumber((GetBuildInfo():match("^(%d+)"))) or 12) - 1

-- UI-driven filters over the missing list.
P.filters = {
	category = nil,        -- nil = all, or a category key
	expansion = nil,       -- nil = all, or expansion index
	onlyAvailable = false, -- only things actionable right now
	search = "",
}

------------------------------------------------------------
-- Missing mounts (filtered)
------------------------------------------------------------
-- The filtered list, memoised.
--
-- With "Available now" ticked this asks Availability.GetStatus for all ~1,300
-- uncollected mounts, and SortEntries can ask Rank for each of them too. That
-- is the cost of opening the window -- nothing to do with the router or the
-- chart, which is why fixing those never touched it.
--
-- IN MEMORY ONLY, DELIBERATELY. Status depends on lockouts, holidays,
-- rotations, currency and reputation, all of which move while you are logged
-- out. A list persisted to disk would come back claiming things are available
-- that reset overnight -- confidently wrong, which is worse than slow. The
-- epoch below is bumped by exactly the events Availability already invalidates
-- its own cache on, so this can never be staler than the answers it is built
-- from.
local missingCache, missingKey = nil, nil
local missingEpoch = 0

local function missingFingerprint()
	local f = P.filters
	return table.concat({
		missingEpoch,
		MM.Scanner and MM.Scanner.collectedCount or 0,
		tostring(f.category), tostring(f.expansion), tostring(f.sort),
		tostring(f.search), tostring(f.onlyAvailable),
		MM.db and MM.db.hideIgnored and "h" or "-",
	}, "|")
end

-- WARM IT WHILE THE LOADING SCREEN IS STILL UP.
--
-- The first GetMissing after a login evaluates ~1,300 statuses, and doing it
-- when the player clicks the icon puts that entire cost between the click and
-- the window. Doing it a few seconds after the journal scan puts it where a
-- pause is expected and nobody is waiting on it.
--
-- Deliberately AFTER a delay, not inline with the scan: logging in is already
-- the busiest moment the client has, and adding to it is how a warm-up becomes
-- the very stall it exists to remove.
-- The saved filter state, restored from MM.db.ui.
--
-- This lived inside UI.BuildPlanner, which does not run until the window is
-- first OPENED. So the warm-up below ran with the defaults -- "Available now"
-- off -- built the unfiltered list, and then opening the window restored the
-- real filters, changed the fingerprint, and rebuilt everything from scratch.
-- The warm-up was warming a list nobody was going to look at.
--
-- Restoring it at login instead means the warm-up and the first open agree.
function P.RestoreFilters()
	local saved = MM.db and MM.db.ui or {}
	P.filters.onlyAvailable = saved.plnAvailable or false
	P.filters.category = saved.plnCategory or nil
	P.filters.sort = saved.plnSort or nil
end

local warmed = false
MM:On("MM_SCANNED", function()
	if warmed then return end
	warmed = true
	P.RestoreFilters()
	C_Timer.After(4, function()
		-- Warms the list the player will actually open, not a default one.
		pcall(function() P:GetMissing() end)
	end)
end)

-- Exactly the messages Availability listens to. MM_CURRENCY and MM_REP were in
-- an earlier draft of this list and nothing fires either of them -- a listener
-- for a message nobody sends is decoration that reads like coverage.
for _, msg in ipairs({ "MM_SCANNED", "MM_LOCKS", "MM_CALENDAR", "MM_PLAN_CHANGED" }) do
	MM:On(msg, function() missingEpoch = missingEpoch + 1 end)
end

function P:GetMissing()
	local key = missingFingerprint()
	if missingKey == key and missingCache then return missingCache end
	local out = {}
	local f = P.filters
	local search = f.search ~= "" and f.search:lower() or nil
	for _, entry in ipairs(MM.Scanner.mounts) do
		local rec = entry.rec
		if not entry.collected and MM.Scanner:FactionOk(entry) and rec then
			local ok = true
			if MM.db.hideIgnored and MM.db.ignored[entry.spellID] then ok = false end
			if f.category and not MM.CategoryMatch(f.category, rec.category) then ok = false end
			if ok and f.expansion and rec.expansion ~= f.expansion then ok = false end
			if ok and search and not entry.name:lower():find(search, 1, true) then ok = false end
			if ok and f.onlyAvailable then
				local status = MM.Availability.GetStatus(entry)
				if status ~= "AVAILABLE" then ok = false end
			end
			if ok then tinsert(out, entry) end
		end
	end
	missingCache = P.SortEntries(out, f.sort)
	missingKey = key
	return missingCache
end

------------------------------------------------------------
-- The plan
------------------------------------------------------------
function P:InPlan(spellID)
	for i, item in ipairs(MM.cdb.plan) do
		if item.spellID == spellID then return i end
	end
	return nil
end

function P:Add(spellID)
	if not spellID or P:InPlan(spellID) then return end
	tinsert(MM.cdb.plan, { spellID = spellID, added = GetServerTime() })
	MM:Fire("MM_PLAN_CHANGED")
end

function P:Remove(spellID)
	-- Removing by hand cancels any debt the lockout bookkeeping was holding.
	-- Without this, a goal you deliberately dropped would reappear the moment
	-- its lockout lifted, which reads as the addon overruling you.
	if MM.db and MM.db.retired then MM.db.retired[spellID] = nil end
	local i = P:InPlan(spellID)
	if i then
		tremove(MM.cdb.plan, i)
		MM:Fire("MM_PLAN_CHANGED")
	end
end

function P:Move(spellID, delta)
	local i = P:InPlan(spellID)
	if not i then return end
	local j = i + delta
	if j < 1 or j > #MM.cdb.plan then return end
	MM.cdb.plan[i], MM.cdb.plan[j] = MM.cdb.plan[j], MM.cdb.plan[i]
	-- Exempt from the auto-optimize below. These arrows mean "I want this one
	-- first"; re-optimizing on the click would put it straight back and the
	-- button would appear broken.
	if P.SuppressAutoOptimize then
		P.SuppressAutoOptimize(function() MM:Fire("MM_PLAN_CHANGED") end)
	else
		MM:Fire("MM_PLAN_CHANGED")
	end
end

function P:Clear()
	-- CLEARING THE PLAN ENDS THE ROUTE.
	--
	-- A running route is a walk through the plan. Emptying the plan underneath
	-- it left the route "active" with nothing to visit -- an arrow pointing at
	-- a goal that was no longer wanted, and a monitor counting down a trip that
	-- had been cancelled. Stopping first is what the button already means.
	if MM.Router and MM.Router.Stop and MM.cdb and MM.cdb.routeActive then
		MM.Router:Stop()
	end
	wipe(MM.cdb.plan)
	MM:Fire("MM_PLAN_CHANGED")
end

-- Plan entries enriched with their scanner entries (drops collected ones).
function P:GetPlan()
	local out = {}
	for _, item in ipairs(MM.cdb.plan) do
		local entry = MM.Scanner.bySpell[item.spellID]
		if entry and not entry.collected then
			tinsert(out, entry)
		end
	end
	return out
end

------------------------------------------------------------
-- Auto-planning
------------------------------------------------------------
local function plannable(entry)
	local rec = entry.rec
	if not rec or rec.stub or rec.obtainable == false then return false end
	if not MM.Scanner:FactionOk(entry) then return false end
	if MM.PLANNABLE[rec.category] then return true end
	-- Trading Post mounts are only actionable while in the current rotation
	if rec.category == "TRADINGPOST" then
		return MM.TradingPost.Find(entry) ~= nil
	end
	return false
end

-- Everything missing that can actually be worked toward.
function P:AutoPlanAll()
	-- REAL COUNTS, NOT A SPINNER.
	--
	-- This walks every mount and then charts the result, which on a full
	-- collection is a visible pause. The scan below is genuinely countable, so
	-- it reports what it has actually done -- a bar that moves on a timer
	-- rather than on work is just a spinner claiming to know something.
	--
	-- InPlan is a linear scan of the plan, so adding N mounts one at a time was
	-- N*N/2 comparisons -- about 600,000 on a full sweep, and most of the wait.
	-- One index up front makes it N.
	local have = {}
	for _, item in ipairs(MM.cdb.plan) do have[item.spellID] = true end

	local pool = {}
	for _, entry in ipairs(MM.Scanner.mounts) do
		if not entry.collected and plannable(entry) and not have[entry.spellID] then
			pool[#pool + 1] = entry.spellID
		end
	end

	local total, now = #pool, GetServerTime()
	if total == 0 then
		MM:Fire("MM_PLAN_PROGRESS", nil)
		return 0
	end

	-- ADDED ACROSS FRAMES, OR THE BAR IS A LIE.
	--
	-- A synchronous loop cannot show progress: the client does not repaint
	-- until the call returns, so every update would land on one frame and the
	-- bar would jump from empty to full at the end -- exactly the freeze it is
	-- meant to explain. Chunking hands the frame back, so the count on screen
	-- is the count actually done.
	local CHUNK = 150
	local i = 0
	MM:Fire("MM_PLAN_PROGRESS", 0, total, "Adding mounts")
	local function step()
		local stop = math.min(i + CHUNK, total)
		while i < stop do
			i = i + 1
			tinsert(MM.cdb.plan, { spellID = pool[i], added = now })
		end
		if i < total then
			MM:Fire("MM_PLAN_PROGRESS", i, total, "Adding mounts")
			C_Timer.After(0, step)
		else
			MM:Fire("MM_PLAN_PROGRESS", i, total, "Adding mounts")
			-- Charting is announced by the optimize pass this fires.
			MM:Fire("MM_PLAN_CHANGED")
		end
	end
	step()
	return total
end

------------------------------------------------------------
-- Tiered ranking
--
-- Order mirrors how a collector actually spends an evening: things you can
-- simply go collect, then soloable instanced content, then outdoor rares,
-- then field work, then rep (nearest-to-target first), then long grinds,
-- then achievements (as hard as whatever they demand), then anything needing
-- other people, then things you literally cannot touch right now.
-- Within a tier, closer + cheaper wins.
------------------------------------------------------------
P.TIER = {
	PICKUP = 1, INSTANCE = 2, RARE = 3, FIELD = 4, REP = 5,
	GRIND = 6, ACHIEVE = 7, GROUP = 8, BLOCKED = 9,
}
P.TIER_LABEL = {
	[1] = "Ready to collect", [2] = "Dungeon / legacy raid", [3] = "Outdoor rare",
	[4] = "Field objective", [5] = "Reputation", [6] = "Long grind",
	[7] = "Achievement", [8] = "Needs a group", [9] = "Blocked right now",
}

-- memoized continent per record, for cheap proximity comparison
local recContinentCache = setmetatable({}, { __mode = "k" })
local function recContinent(rec)
	local cached = recContinentCache[rec]
	if cached ~= nil then return cached or nil end
	local mapID = U.GetRecordMapID(rec)
		or (rec.instance and rec.instance.name and U.ResolveMapForRecord(rec.instance.name, rec))
	local continent = mapID and (U.GetWorldPos(mapID, 50, 50)) or nil
	recContinentCache[rec] = continent or false
	return continent
end

-- 0 = your continent, 1 = elsewhere, 0.5 = unknown
-- How far away this is, as a 0-1 penalty.
--
-- THIS USED TO BE THREE VALUES: 0 same continent, 1 another, 0.5 unknown. So
-- on your own continent every candidate scored travel 0, and a mount 30
-- seconds away ranked identically to one 8 minutes away -- which is why "Add
-- 10 Easiest" was instant, and why it was not actually ranking on travel at
-- all. Ordering could be repaired later by the route's third layer; SELECTION
-- could not, because layer 3 can only reorder the ten it was handed.
--
-- It is now real minutes, from where you are standing, out of ONE Dijkstra
-- shared by every candidate (J.MinutesFrom). The 0-1 range is deliberately
-- kept so the `travel` weight still means what it meant and the default
-- calibration is untouched -- it is simply continuous now instead of a flag.
-- MEASURED FROM THE PLAN'S ANCHOR, NOT FROM WHERE YOU HAPPEN TO BE.
--
-- Reading the live player position made the plan re-chart as you walked --
-- fly to objective one and objectives two and three would reshuffle behind
-- you. A plan that moves while you follow it is not a plan.
--
-- So the anchor is frozen when the plan is charted and only moves when YOU
-- change the plan. The chain from each objective to the next is the router's
-- job (layer 3); this is only the starting point that chain is measured from.
local TRAVEL_FULL_PENALTY_MINUTES = 30

-- Memoised against the anchor.
--
-- Real travel in the ease score cost 1,136 ms a build -- MinutesFrom asked per
-- candidate, ~1,300 times, for every rank. The anchor is FROZEN by design, so
-- every one of those answers is the same until you edit the plan: the whole
-- point of anchoring is that this number holds still. Keyed by the anchor map
-- so it cannot outlive the position it was measured from.
local proxCache, proxAnchor = {}, nil
function P.Anchor()
	local a = MM.cdb and MM.cdb.planAnchor
	if a and a.mapID and a.name then return a end
	-- SET IT ONCE, LAZILY. Without this the anchor only ever appeared after a
	-- plan EDIT, so on a fresh login there was none -- proximityPenalty fell
	-- back to the continent flag and the ease score reported two distinct
	-- travel costs across 281 goals. Establishing it on first read is not the
	-- same as re-reading it as you move: it is set here and then held.
	if P.SetAnchor then P.SetAnchor() end
	a = MM.cdb and MM.cdb.planAnchor
	if a and a.mapID and a.name then return a end
	return nil
end

-- Re-anchor to where the player is standing NOW. Called only when the plan is
-- charted, never on movement.
function P.SetAnchor()
	local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
	local info = mapID and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
	if not (info and info.name) then return end
	local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
	-- PER CHARACTER, like the chart it feeds.
	--
	-- This lived in MM.db (account-wide), so charting on an alt in Icecrown
	-- overwrote the anchor for every character. Coming back to one standing in
	-- Zuldazar, its ease scores were measured from Icecrown and its signature
	-- had changed for a reason that had nothing to do with it.
	MM.cdb = MM.cdb or {}
	MM.cdb.planAnchor = {
		name = info.name, mapID = mapID,
		x = pos and pos.x and pos.x * 100 or nil,
		y = pos and pos.y and pos.y * 100 or nil,
		at = GetServerTime(),
	}
	if MM.Journey and MM.Journey.ForgetTravelFrom then MM.Journey.ForgetTravelFrom() end
	-- Re-anchoring invalidates every distance measured from the old one. The
	-- key check in proximityPenalty catches a MAP change on its own, but
	-- re-anchoring in the same zone keeps the map and moves the point.
	proxCache, proxAnchor = {}, nil
end

local function proximityPenalty(rec)
	local anchorNow = P.Anchor and P.Anchor()
	local anchorKey = anchorNow and anchorNow.mapID or "?"
	if proxAnchor ~= anchorKey then
		proxCache, proxAnchor = {}, anchorKey
	end
	local hit = proxCache[rec]
	if hit ~= nil then return hit end
	local value = P.ComputeProximity(rec)
	proxCache[rec] = value
	return value
end

function P.ComputeProximity(rec)
	local pc = select(1, U.PlayerWorldPos())
	local zone = rec.zone and rec.zone.name
	if zone and MM.Journey and MM.Journey.MinutesFrom then
		local anchor = P.Anchor()
		local hereName = anchor and anchor.name
		local here = anchor and anchor.mapID
		if hereName then
			local mins = MM.Journey.MinutesFrom(hereName, anchor.x, anchor.y, here,
				zone, rec.zone.x, rec.zone.y, rec.zone.mapID)
			if mins then
				return math.min(mins / TRAVEL_FULL_PENALTY_MINUTES, 1)
			end
		end
	end
	-- No route to it, or nowhere to route from: fall back to the continent
	-- flag. A nil answer must never read as "close" -- that is the one error
	-- that promotes an unreachable goal to the top of the list.
	local playerContinent = pc
	local c = recContinent(rec)
	if not (playerContinent and c) then return 0.5 end
	return c == playerContinent and 0 or 1
end

local function isGroupContent(rec, hay)
	if rec.solo == false then return true end
	if rec.category == "PVP" then return true end
	if hay:find("keystone") or hay:find("rated")
		or hay:find("arena") or hay:find("faction leader") or hay:find("city leader")
		or hay:find("enemy leader") or hay:find("for the horde")
		or hay:find("for the alliance") or hay:find("battleground") then
		return true
	end
	-- current/previous-tier mythic raiding needs a real group; legacy is solo
	if rec.instance and rec.instance.difficulty
		and rec.instance.difficulty:lower():find("mythic")
		and rec.expansion and rec.expansion >= CURRENT_EXPANSION - 1 then
		return true
	end
	-- A raid Glory meta needs a group while the raid is current and needs
	-- nobody once it is legacy. Treating "glory" as group content outright put
	-- Bloodgorged Crawg -- Glory of the Uldir Raider, a Battle for Azeroth raid
	-- our own record describes as "all criteria are soloable at current level"
	-- -- in the needs-a-group tier, which is both wrong and the bottom of the
	-- priority list. Records that genuinely still need help say so with
	-- `solo = false`, which is checked above and always wins.
	-- The category walk settles a NARROW slice and no more.
	--
	-- Requirement — the blizzard API will not tell you if its soloable, legacy content was
	-- designed for multiple people but can often be solo'd if youre the right
	-- class (e.g. hunter). Correct, and I overstated it. Player vs. Player
	-- needs opponents and Guild needs a guild group -- those two are genuinely
	-- decidable. "Dungeons & Raids" decides nothing: whether a legacy raid can
	-- be soloed depends on the class, the gear and the player, and no API
	-- exposes that. Everything outside those two cases stays a judgement call.
	local achID = MM.Conditions.RecordAchievementID and MM.Conditions.RecordAchievementID(rec)
	if achID then
		local class = MM.Conditions.AchievementClass(achID)
		if class and (class.pvp or class.guild) then return true end
	end

	-- the player, on the previous version of this: do not default to group if you can
	-- separate any class from some classes -- default to soloable.
	--
	-- Fair. Blanket-grouping every achievement punishes the many soloable ones
	-- to protect against the few that are not, and the few ARE identifiable:
	-- Wowhead's Soloist's Pocket Guide marks the metas that cannot be soloed due
	-- to game mechanics, and those carry `solo = false` in Data_99c. Anything
	-- else is assumed soloable, which is true far more often than not.
	if hay:find("glory") and rec.expansion and rec.expansion >= CURRENT_EXPANSION - 1 then
		return true
	end
	if hay:find("world boss") and rec.expansion and rec.expansion >= CURRENT_EXPANSION - 1 then
		return true
	end
	return false
end

-- The subscore, itemised.
--
-- Itemised rather than summed inline because a number nobody can take apart is
-- a number nobody can trust: the tooltip prints these parts verbatim, so what
-- the addon charges a goal and what it TELLS the player it charged cannot drift
-- apart. Each coefficient is a setting (Options > Weights & Priorities) whose
-- default is the number that used to be hard-coded here.
--
-- Returns total, parts. Each part is { label, points, detail }.
function P.CostParts(entry, prox)
	local rec = entry.rec
	if not rec then return 0, {} end
	local W = MM.Weights
	prox = prox or proximityPenalty(rec)

	local effort = rec.effort or 3
	local minutes = rec.timePerAttempt or 20
	local parts = {
		{ "Effort", effort * W.Get("effort"), ("rated %d of 5"):format(effort) },
		{ "Travel", prox * W.Get("travel"),
			prox == 0 and "on your continent"
				or prox >= 1 and "another continent" or "location unclear" },
		{ "Time per try", math.min(minutes, 200), ("about %d min"):format(minutes) },
	}
	-- empirical ownership rate beats our editorial effort guess when we have it
	local odds = MM.Rarity.Penalty(entry.mountID) * (W.Get("odds") / 2500)
	if odds ~= 0 then
		local pct = MM.Rarity.Get(entry.mountID)
		parts[#parts + 1] = { "Long odds", odds,
			pct and ("%.2f%% of players own it"):format(pct) or "rarely owned" }
	end
	local era = W.EraAdjust(rec)
	if era ~= 0 then
		parts[#parts + 1] = { "Era", era,
			era < 0 and "the era you asked for" or "not the era you asked for" }
	end

	local total = 0
	for _, part in ipairs(parts) do total = total + part[2] end
	return total, parts
end

-- The cost EXCEPT travel.
--
-- The router measures real distance in yards, so handing it the planner's
-- coarse continent penalty as well would charge for the same journey twice.
-- Everything else -- effort, time, long odds, era -- is a property of the goal
-- and is exactly what routing was missing: before this, four of the six weights
-- moved nothing but the "Easiest" list, and a player who dragged them and
-- watched their route sit still was reading the addon correctly.
function P.Handicap(entry)
	local _, parts = P.CostParts(entry, 0)
	local total = 0
	for _, part in ipairs(parts) do
		if part[1] ~= "Travel" then total = total + part[2] end
	end
	return total
end

------------------------------------------------------------
-- Ranking, memoized
------------------------------------------------------------
-- Rank is not cheap: a status lookup, a full condition evaluation, a continent
-- resolution and a rarity read. It is also called from everywhere -- the router
-- asks for it directly AND through ValuePerMinute AND through Handicap, so one
-- route build over a 286-goal plan was running it the better part of a thousand
-- times, and the weights matrix builds a dozen routes back to back.
--
-- Weak keys so a scanner refresh drops the entries with the table. The
-- generation counter is what actually makes this safe: anything that could
-- change an answer bumps it, and a stale entry can then never be read.
local rankCache = setmetatable({}, { __mode = "k" })
-- Declared HERE, beside the generation counter that governs it, NOT beside its
-- first use six hundred lines down. A `local` referenced above its declaration
-- silently resolves to a global -- so the invalidator would have found nil and
-- quietly never cleared the cache. Exactly the trap YARDS_PER_MINUTE fell into
-- in Addendum 98; the guard clause would have hidden it completely.
local timeCache = setmetatable({}, { __mode = "k" })
local rankGeneration = 0

function P.InvalidateRanks()
	rankGeneration = rankGeneration + 1
	wipe(rankCache)
	wipe(timeCache)
end

MM:On("MM_WEIGHTS_CHANGED", P.InvalidateRanks)
MM:On("MM_SCANNED", P.InvalidateRanks)
MM:On("MM_STATUS_INVALIDATED", P.InvalidateRanks)

local computeRank

-- Returns tier, subscore, reason text.
function P.Rank(entry)
	local hit = rankCache[entry]
	if hit and hit[4] == rankGeneration then return hit[1], hit[2], hit[3] end
	local tier, sub, reason = computeRank(entry)
	rankCache[entry] = { tier, sub, reason, rankGeneration }
	return tier, sub, reason
end

-- Logging out and back in. Cheap on its own, which is the point -- a
-- requirement an alt has already earned is a minute away, not a wall. It is
-- not FREE though: switches want batching, because every one of them breaks
-- the chain the route is built on.
local SWITCH_MINUTES = 1
-- Moving a warband-wide currency onto the character that will spend it. The
-- balance is shared; the vendor still checks the pocket in front of it.
local TRANSFER_MINUTES = 2

function computeRank(entry)
	local rec = entry.rec
	if not rec then return P.TIER.GRIND, 5000, "Uncatalogued" end

	local status = MM.Availability.GetStatus(entry)
	local hay = ((rec.source or "") .. " " .. (rec.notes or "")):lower()
	local allMet = MM.Conditions.EvaluateAll(rec)
	local prox = proximityPenalty(rec)
	-- Itemised in one place (P.CostParts) so the tooltip prints exactly what the
	-- ranking charged, never a second calculation of the same idea.
	local sub = P.CostParts(entry, prox)

	-- BLOCKED ON THIS CHARACTER IS NOT BLOCKED.
	--
	-- A requirement someone in the warband has already earned is not a wall,
	-- it is a character switch -- about a minute, and then you are standing in
	-- front of the same vendor with the standing you needed. Ranking it BLOCKED
	-- put a mount that is minutes away below things needing weeks, because the
	-- question asked was "can THIS character" when the useful one is "can I".
	--
	-- Only a PREREQ can be answered this way. A lockout is a lockout on every
	-- character; a rotation and a holiday are the world's state, not yours; and
	-- unobtainable is unobtainable.
	local altKey, altIsMe, altTransfer, altWhy
	if status == "PREREQ" then
		altKey, altIsMe, altTransfer, altWhy = MM.Alts and MM.Alts.WhoMeets
			and MM.Alts.WhoMeets(rec)
	end

	-- 9. blocked outright
	if (status == "LOCKED" or status == "HOLIDAY" or status == "ROTATION"
		or status == "UNOBTAINABLE")
		or (status == "PREREQ" and not (altKey and not altIsMe)) then
		return P.TIER.BLOCKED, sub, MM.Availability and status == "LOCKED"
			and "On lockout" or "Not available right now"
	end

	-- Reachable by switching. Charged for the switch, and for the currency move
	-- when the vendor will check the spending character's own balance rather
	-- than the warband's -- shared does not mean already in the right pocket.
	if altKey and not altIsMe then
		sub = sub + SWITCH_MINUTES + (altTransfer and TRANSFER_MINUTES or 0)
	end

	-- Daily Calling rotation. When today's Calling IS in the right zone this is
	-- genuinely cheap -- one daily you were likely doing anyway -- but it is a
	-- field objective, never an instance run. When we cannot confirm the zone we
	-- refuse to route it: an unverified guess is what sent the player to
	-- Maldraxxus on a day no egg could drop.
	if rec.calling then
		local zone = rec.calling.zone or "the right zone"
		if status ~= "AVAILABLE" then
			return P.TIER.BLOCKED, sub + 5000,
				("Only on days your Calling is in %s"):format(zone)
		end
		return P.TIER.FIELD, sub,
			("Today's Calling is in %s — its chest can hold the egg"):format(zone)
	end

	-- 0. it is already in your bags — nothing outranks a right-click
	if MM.Acquire.Carried(entry) then
		return P.TIER.PICKUP, 0, "In your bags — just use the item"
	end

	-- 8. needs other players
	if isGroupContent(rec, hay) then
		return P.TIER.GROUP, sub, "Needs a group or rated play"
	end

	-- 1a. Trading Post: live rotation + live Tender balance means we KNOW
	-- whether it's a simple purchase right now.
	if rec.category == "TRADINGPOST" then
		local item = MM.TradingPost.Find(entry)
		if item then
			if item.purchased then
				return P.TIER.PICKUP, prox * 250, "Already bought — claim it from the vendor"
			end
			local have, cost = MM.TradingPost.Tender(), item.price or 0
			if have >= cost then
				return P.TIER.PICKUP, prox * 250 + 50,
					("In this month's Trading Post — %s Tender, you have %s")
						:format(U.Comma(cost), U.Comma(have))
			end
			return P.TIER.GRIND, 3000 + (cost - have),
				("Trading Post: %s / %s Tender"):format(U.Comma(have), U.Comma(cost))
		end
	end

	-- 1. everything required is already satisfied — go collect it
	local PURCHASE = { VENDOR = true, CURRENCY = true, TIMEWALKING = true,
		TRADINGPOST = true, REP = true }
	if PURCHASE[rec.category] and status == "AVAILABLE"
		and rec.conditions and #rec.conditions > 0 and allMet == true then
		return P.TIER.PICKUP, prox * 250 + math.min(rec.timePerAttempt or 15, 100),
			"Requirements met — just go buy it"
	end

	-- 5. reputation: rank by how close you actually are
	local repFrac, repLabel = MM.Conditions.RecordRepProgress(rec)
	if repFrac and repFrac < 1 then
		-- (1 - progress) dominates so 90%-done factions sort above 0%-done ones
		return P.TIER.REP, (1 - repFrac) * 6000 + prox * 250, repLabel or "Reputation grind"
	end

	-- 7. achievements inherit the difficulty of what they actually demand:
	-- "loot 5 treasures" is field work, a multi-raid meta is a project.
	if rec.category == "ACHIEVEMENT" then
		local effort = rec.effort or 3
		-- A meta is never field work, whatever its effort rating says.
		--
		-- Bloodgorged Crawg is Glory of the Uldir Raider -- a thirteen-criteria
		-- raid meta -- and it led EVERY preset including the drops-only one,
		-- because its effort was recorded as 2 and `effort <= 2` short-circuited
		-- it straight into the field tier. One optimistic number in the data
		-- reclassified a raid meta as an errand.
		--
		-- Trusting the shape of the thing over a hand-entered rating: if the
		-- source names a Glory, a Raider, a Hero meta or a Keystone, it is a
		-- project by definition.
		local isMeta = hay:find("glory") or hay:find("raider") or hay:find("keystone")
			or hay:find("meta%-achievement") or hay:find("all .* achievements")
		if not isMeta and (effort <= 2 or hay:find("treasure") or hay:find("explore")) then
			return P.TIER.FIELD, sub, "Achievement: " .. (rec.source or "short objective")
		end
		return P.TIER.ACHIEVE, sub + math.max(effort, isMeta and 4 or 1) * 200,
			"Achievement: " .. (rec.source or "multi-step")
	end

	-- 2. instanced drops: soloable dungeons and legacy raids
	if rec.category == "DROP" or rec.instance then
		local legacy = not rec.expansion or rec.expansion <= CURRENT_EXPANSION - 2
		if legacy then
			local sub2 = sub
			if rec.dropRate then
				local mean = U.AttemptEstimates(rec.dropRate)
				sub2 = sub2 + math.min(mean or 0, 400)
			end
			return P.TIER.INSTANCE, sub2, "Soloable instance run"
		end
		return P.TIER.GROUP, sub, "Current-tier instance"
	end

	-- 3. outdoor rares
	if rec.category == "RARE" then
		local sub3 = sub
		if rec.dropRate then
			local mean = U.AttemptEstimates(rec.dropRate)
			sub3 = sub3 + math.min(mean or 0, 400)
		end
		return P.TIER.RARE, sub3, "Rare spawn kill"
	end

	-- 4. field work you can just go do
	local FIELD = { TREASURE = true, QUEST = true, PUZZLE = true,
		ZONEDROP = true, PROFESSION = true, GARRISON = true, CLASS = true }
	if FIELD[rec.category] then
		return P.TIER.FIELD, sub, "Go do it in the world"
	end

	-- 6. everything else is a grind of some size
	local sub6 = sub
	local reason = "Grind"
	if allMet == nil and rec.conditions and #rec.conditions > 0 then
		sub6 = sub6 + 900
		reason = "Requirements unverified"
	end
	if (rec.category == "VENDOR" or rec.category == "CURRENCY")
		and (not rec.conditions or #rec.conditions == 0)
		and not (rec.source or ""):lower():find("gold") then
		sub6 = sub6 + 800
		reason = "Cost unknown"
	end
	if rec.conditions then
		for _, cond in ipairs(rec.conditions) do
			if cond.type == "ITEM" and cond.cost then
				local gold = tonumber((cond.cost:gsub("[^%d]", ""))) or 0
				if gold >= 1000000 then sub6 = sub6 + 2500 reason = "Huge gold cost"
				elseif gold >= 100000 then sub6 = sub6 + 1200 reason = "Large gold cost"
				elseif gold >= 10000 then sub6 = sub6 + 400 end
			elseif cond.type == "CURRENCY" then
				reason = "Currency grind"
			end
		end
	end
	return P.TIER.GRIND, sub6, reason
end

-- Single sortable number: tier dominates, subscore orders within it.
-- This answers "what's EASIEST" — used by Add 10 Easiest and Sort: Easiest.
-- The tier's POSITION in the player's priority order leads, not its constant:
-- someone who puts rares above achievements means it absolutely, so no
-- achievement subscore may cross the boundary. P.TIER values stay fixed as
-- identities, which is what the router's semantic thresholds compare against.
-- EASE IS NOT PREFERENCE.
--
-- This used MM.Weights.TierRank, which orders tiers by the player's OWN
-- configured priority. So "the 10 easiest" was really "the 10 highest in the
-- order you already set", and a vendor mount you could buy standing still
-- ranked below a dungeon if you had put INSTANCE first. The button could only
-- ever tell you what you had already told it.
--
-- The DEFAULT order is the objective one -- pickup, instance, rare, field, rep,
-- grind, achievement, group -- roughly ascending in what the game asks of you.
-- Ease uses that; the ROUTE still uses your order, because which of two equally
-- easy things you want first is exactly the preference the route exists to
-- honour. Two different questions, two different orderings.
local DEFAULT_TIER_RANK
local function objectiveTierRank(tier)
	if not DEFAULT_TIER_RANK then
		DEFAULT_TIER_RANK = {}
		for i, key in ipairs(MM.Weights.DEFAULT_ORDER) do
			DEFAULT_TIER_RANK[P.TIER[key]] = i
		end
	end
	if tier == P.TIER.BLOCKED then return #MM.Weights.DEFAULT_ORDER + 1 end
	return DEFAULT_TIER_RANK[tier] or (#MM.Weights.DEFAULT_ORDER + 1)
end

local function easeScore(entry)
	local tier, sub = P.Rank(entry)
	return objectiveTierRank(tier) * 100000 + sub
end

------------------------------------------------------------
-- Session priority (a different question from difficulty)
--
-- Difficulty asks "what's easiest to get". Routing asks "how do I spend the
-- next few hours". The dominant fact there is EXPIRY: a weekly lockout you
-- skip is a roll gone forever, while a vendor mount you can already afford
-- waits for you indefinitely. So urgency leads, then value per minute, then
-- travel.
------------------------------------------------------------
P.URGENCY = { EXPIRING = 1, LOCKOUT = 2, ANYTIME = 3, BLOCKED = 4 }
P.URGENCY_LABEL = {
	[1] = "Event ending", [2] = "Resets — use it or lose it",
	[3] = "Always available", [4] = "Blocked",
}

-- Returns urgency level, reason.
function P.Urgency(entry)
	local rec = entry.rec
	if not rec then return P.URGENCY.ANYTIME, nil end
	local status = MM.Availability.GetStatus(entry)

	if status == "LOCKED" or status == "HOLIDAY" or status == "ROTATION"
		or status == "PREREQ" or status == "UNOBTAINABLE" then
		return P.URGENCY.BLOCKED, "Can't act on this right now"
	end

	-- limited-time windows: the whole opportunity disappears
	if rec.category == "HOLIDAY" or rec.category == "TIMEWALKING" then
		-- EXPIRING means "act now or lose it". That is only true if you could
		-- actually finish inside the window. Sitting at 0 of 5,000 badges, the
		-- event ending changes nothing -- it will come round again long before
		-- the currency does.
		local held = MM.Conditions.CurrencyProgress(rec)
		if held and held < 0.5 then
			return P.URGENCY.LOCKOUT,
				("Event is live, but you have %d%% of the cost"):format(held * 100)
		end
		return P.URGENCY.EXPIRING, "Event is live — gone when it ends"
	end
	if rec.category == "TRADINGPOST" then
		local ends = MM.TradingPost.TimeRemaining()
		if ends then
			return P.URGENCY.EXPIRING,
				"Trading Post rotation ends in " .. U.FormatSeconds(ends)
		end
		return P.URGENCY.EXPIRING, "This month's Trading Post rotation"
	end

	-- A Calling-gated mount is marked attempts = DAILY, but the daily roll only
	-- exists on days the right Calling is up. Without this it would score as
	-- "daily attempt available now" on every other day of the rotation.
	if rec.calling then
		if status ~= "AVAILABLE" then
			return P.URGENCY.BLOCKED, "Today's Calling isn't in the right zone"
		end
		return P.URGENCY.LOCKOUT, "Today's Calling can drop the egg — gone at reset"
	end

	-- attempt-gated: skipping today/this week wastes a roll permanently
	local lockout = rec.attempts or (rec.instance and rec.instance.lockout)
	if lockout == "DAILY" then
		return P.URGENCY.LOCKOUT, "Daily attempt available now"
	elseif lockout == "WEEKLY" then
		return P.URGENCY.LOCKOUT, "Weekly attempt available now"
	end

	return P.URGENCY.ANYTIME, nil
end

-- The chance a single visit yields this mount.
--
-- A mount that DROPS is never a certainty, so an unrecorded rate must not read
-- as one (Addendum 88). Kept in one place because the router, the estimate and
-- the tooltip all need the same answer and three copies would drift.
local UNRATED_DROP_CHANCE = 0.01
local CHANCY = { DROP = true, RARE = true, ZONEDROP = true }

function P.ExpectedMounts(entry)
	local rec = entry and entry.rec
	if not rec then return 0 end
	if rec.dropRate then return math.min(rec.dropRate / 100, 1) end
	if CHANCY[rec.category] then return UNRATED_DROP_CHANCE end
	-- "You go, you get it" is only true if you can actually pay. A vendor mount
	-- whose requirements are demonstrably unmet yields nothing from a visit.
	if rec.conditions and #rec.conditions > 0
		and MM.Conditions.EvaluateAll(rec) == false then
		return 0
	end

	-- GOLD IS A REQUIREMENT TOO, AND IT WAS NOT CHECKED HERE.
	--
	-- The line above rejects a goal whose CONDITIONS cannot be met, but a gold
	-- price is not a condition -- it is `rec.goldCost` -- so Bloodfang Widow at
	-- 2,000,000 gold fell straight past it and reported a GUARANTEED mount.
	-- TimeCommitment does charge the shortfall, but a session prices a stop by
	-- VisitMinutes, so the penalty was not in the denominator and a certainty
	-- divided by a short vendor visit beat everything else in the plan.
	--
	-- Same rule as everywhere else in this function: a visit only yields the
	-- mount if you can actually complete the purchase when you arrive.
	if rec.goldCost and rec.goldCost > 0 and GetMoney then
		local have = GetMoney()
		if have and have < rec.goldCost * 10000 then return 0 end
	end

	-- An achievement mount is NOT handed to you for showing up.
	--
	-- Requirement — Achievement mounts are still winning too often, especially in
	-- Legacy Dungeons & Raids. The mechanism was this line. An achievement
	-- record with nothing readable fell through to 1, so Hand of Hrestimorak --
	-- a meta -- was listed at a raid stop as **guaranteed**, and a guaranteed
	-- mount beats everything.
	--
	-- What this number means is "chance this goal completes on this visit".
	-- Squared progress, because a meta at half done is not half a mount away:
	-- the remaining criteria are usually the awkward ones. Unknown progress is
	-- deliberately small rather than 1 -- we cannot read it, so we must not
	-- claim it.
	if rec.category == "ACHIEVEMENT" then
		local progress = MM.Conditions.AchievementProgress
			and MM.Conditions.AchievementProgress(rec)
		if not progress then return 0.1 end
		if progress >= 1 then return 1 end     -- done; go and claim it
		return progress * progress
	end

	-- A QUEST YOU HAVE ALREADY TURNED IN CANNOT REWARD IT AGAIN.
	--
	-- Child of Torcali is the reward for "Wander Not Alone", the last step of a
	-- chain. Finish the chain without the mount and that door is shut -- but
	-- nothing checked, so it reported a GUARANTEED mount and led the plan.
	-- This is not a guess: the client knows which quests are flagged complete.
	--
	-- Where the quest id is UNKNOWN we cannot tell whether the chain is still
	-- open, and the rule is the same as everywhere else here -- we cannot read
	-- it, so we must not claim certainty.
	if rec.category == "QUEST" then
		local known, done = false, false
		-- A questChain names the exact quest that AWARDS the mount, which is
		-- the only one whose completion settles this. Child of Torcali carries
		-- `final = 55798` -- "Wander Not Alone" -- so the answer is readable
		-- rather than inferred from the chain's other twelve steps.
		local chain = rec.questChain
		if chain and chain.final then
			known = true
			if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted
				and C_QuestLog.IsQuestFlaggedCompleted(chain.final) then
				done = true
			end
		end
		for _, cond in ipairs(rec.conditions or {}) do
			if cond.type == "QUEST" and cond.id then
				known = true
				if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted
					and C_QuestLog.IsQuestFlaggedCompleted(cond.id) then
					done = true
				end
			end
		end
		if done then return 0 end          -- turned in; this path is spent
		if not known then return 0.1 end   -- cannot see whether it is open
	end

	-- A CONTAINER YOU CANNOT OPEN YIELDS NOTHING.
	--
	-- Ancestral War Bear and Hexed Vilefeather Eagle are looted from treasures
	-- -- the Honored Warrior's Cache, the Abandoned Ritual Skull -- that each
	-- need a set of items collected first. None of that is in the record, so
	-- "walk up and loot it" was scored as a certainty and both went straight to
	-- the top of a 45-minute session.
	--
	-- The items are not modelled anywhere, and inventing the list is exactly
	-- the mistake the secret chains taught. So: not zero, because the treasure
	-- is real and reachable -- but never a certainty either.
	-- A record that STATES its chain is costed by the chain, not by this
	-- blanket -- Ancestral War Bear's four keys and Hexed Vilefeather Eagle's
	-- 1,000 Vile Essence are real data and the acquire machinery reads them.
	-- The 0.1 is only for the ones whose gate is still unknown to us.
	if rec.category == "TREASURE" and not rec.acquire then return 0.1 end

	-- PVP IS AN ACCUMULATION, NOT AN ERRAND.
	--
	-- A Vicious saddle is a hundred wins. The record states that in prose and
	-- carries no readable condition, so it fell through to "you go, you get
	-- it" and scored a GUARANTEED mount for one visit -- the best density any
	-- goal can have. That is why switching to a 45-minute session put Vicious
	-- saddles on top: nothing else can beat a certainty.
	--
	-- Structurally this is a reputation grind, not a purchase: a long
	-- accumulation with a guaranteed end. One match advances it; one match does
	-- not finish it. Where the requirement IS readable the check above has
	-- already answered (0 when it cannot be met, 1 when it can), so this only
	-- catches the ones whose cost lives in prose -- and the rule there is the
	-- same as everywhere else in this file: we cannot read it, so we must not
	-- claim it.
	if rec.category == "PVP" then return 0.1 end

	return 1 -- a vendor, a quest: you go, you get it
end

------------------------------------------------------------
-- How long this really takes
------------------------------------------------------------
-- Requirement — the first mount in my list is Bloodthirsty Dreadwing which costs 1,000
-- honorbound service medals and we have 0. Why does it keep making this mistake?
-- ... Speed is important but the objective has to be able to be completed and
-- time to complete needs to factor in, if it takes hours to do a task (or is
-- impossible) it should not get prioritized just because its really fast to get
-- there.
--
-- The router was costing every goal at `timePerAttempt` -- the length of ONE
-- visit. For a drop that is right. For a purchase it is nonsense: it scored
-- "one guaranteed mount for fifteen minutes" for a mount costing a thousand
-- medals the player does not have, and nothing could beat that.
--
-- Three things go into the real number:
--
--   1. the shortfall on any modelled requirement, as remaining grind
--   2. a floor from the effort rating -- a five-star project is not a quarter
--      of an hour whatever `timePerAttempt` says
--   3. an UNKNOWN-COST penalty. Bloodthirsty Dreadwing is category CURRENCY
--      with no conditions block at all, so the price exists only in prose we
--      cannot read. Treating an unknown price as free is how it reached the top
--      of the list; an unverified assumption must never win. `/mm gaps` lists
--      these so the real costs can be modelled and the penalty stop applying.
-- Requirement — everything needs the time committment modeled, if its a specific
-- unique currency that needs farmed, if its a bunch of specific tasks that need
-- to be done (achievement) if its grinding a rep (and it is honored but it
-- requires exalted) these all factor into the total time equation.
--
-- So they do, and they are SEQUENTIAL. You grind the reputation, THEN you buy
-- the mount; you finish the criteria, THEN you collect. Prerequisites therefore
-- ADD -- taking the worst of them would say a mount needing both exalted AND a
-- thousand medals costs the same as one needing only the medals.
--
-- Each figure below is "hands-on hours for the whole thing from zero", scaled by
-- how much of it you have already done. They are estimates and openly so; being
-- twice out on a multi-week grind changes nothing about whether it belongs at
-- the top of tonight's list, which is the only question being asked.
local EFFORT_FLOOR_MINUTES = { [1] = 5, [2] = 15, [3] = 45, [4] = 120, [5] = 480 }
local REP_GRIND_MINUTES = 12 * 60          -- neutral to exalted, roughly
-- One full paragon bar. Shadowlands paragon thresholds are 10,000 rep, and a
-- zone's dailies plus world quests earn on the order of 2,000/hour, so five
-- hours is the honest figure. Charged per BAR; the odds of the mount dropping
-- from the resulting cache are accounted for separately, in expected mounts.
local PARAGON_BAR_MINUTES = 5 * 60
-- Per missing reagent unit. Deliberately blunt: a reagent's real cost depends
-- on whether it drops, gathers or is bought, and the recipe schematic does not
-- say which. Two minutes an item is the honest middle, and unlike the flat
-- four-hour charge it at least scales with how much is actually missing.
local MATERIAL_MINUTES_PER_UNIT = 2
local CURRENCY_GRIND_MINUTES = 8 * 60      -- a full unique-currency haul
-- What one week of a CAPPED currency costs in EFFORT, not in elapsed time.
--
-- A four-week cap does not mean four weeks at the keyboard; it means capping
-- out four times. The label carries the calendar reality ("4 weeks") so the
-- player sees they cannot have it sooner, while the ranking compares effort
-- with everything else on the same scale.
local WEEK_MINUTES_OF_EFFORT = 150
-- One day's worth of a daily-quest reputation: the dailies themselves, not the
-- day they are locked behind. Same reasoning as WEEK_MINUTES_OF_EFFORT above.
local DAILY_MINUTES_OF_EFFORT = 15
-- One PvP match, queue included. An assumption, and the same kind ClearTimes
-- already replaces with measured figures once it has watched a few.
local PVP_MATCH_MINUTES = 12
local ACHIEVEMENT_MINUTES = 6 * 60         -- a meta from nothing
-- One outstanding achievement criterion, scaled by the record's effort rating.
-- Twenty minutes is a boss feat or a rare kill; the effort rating stretches it
-- for the genuinely awkward ones. Charged PER CRITERION so a meta three feats
-- from done stops being priced like one that has not been started.
local CRITERION_MINUTES = 20
local CHAIN_STEP_MINUTES = 20              -- per outstanding item in a chain
local UNKNOWN_COST_MINUTES = 240
-- Walking up to a vendor you can already afford and clicking buy. Small, and
-- an assumption, but the alternative was ranking a 10 gold ram like a raid.
local PURCHASE_MINUTES = 2
-- Categories whose real cost is a PRICE -- currency, reputation, materials --
-- rather than a fight or a lockout. When one of these carries no conditions we
-- can read, it is charged as unknown rather than free, and reported in /mm gaps
-- so the guess can be replaced with data.
--
-- PROFESSION was missing, and the player caught what that produced: its showing
-- protoform synthesis mounts that I do not have materials for and would need to
-- farm but is not considering the farm. All 24 Protoform Synthesis records
-- carry no conditions and no chain, so each was a GUARANTEED mount costed at
-- the 45-minute effort floor -- a density nothing else in the plan could beat.
-- A craft always needs materials; pretending otherwise is the same hole that
-- unpriced vendor mounts and unmodelled achievements fell through.
-- PVP belongs here for the same reason CURRENCY does: the cost is real, it is
-- stated only in prose ("100 wins"), and nothing can read it. Without it a
-- Vicious mount carried no cost at all beyond its effort rating, so a grind
-- measured in DAYS fitted inside a three-hour session.
local PRICED = { CURRENCY = true, VENDOR = true, REP = true, TIMEWALKING = true,
	PROFESSION = true, PVP = true }

-- Expected attempts for a drop, so a 1% mount is not costed as one kill. Capped:
-- past a point "very many" is the only honest reading, and the exact number
-- stops changing any decision.
local MAX_MODELLED_ATTEMPTS = 40

-- Memoized on the same generation counter as Rank.
--
-- This walks every condition and, for achievements, every criterion -- a real
-- pile of C calls. The router asks for it through ExpectedMounts, EffortMinutes
-- AND Handicap, and the matrix builds twelve routes, which took build time from
-- 43 ms to 200. Computing it once per goal per generation puts that back.
-- How long ONE attempt takes when the record does not say.
--
-- This was a flat 15 everywhere, which is an assumption wearing no label: a
-- Blackwing Lair clear and a rare-spawn tag are not the same quarter hour, and
-- pretending they are distorted every downstream estimate in the same direction.
--
-- Only 22% of obtainable records carry a real timePerAttempt, so the fallback
-- decides most of the model. Making it read the category is not more invention
-- than the flat 15 -- it is the same assumption, better informed and, unlike a
-- bare literal, auditable in one place.
--
-- These are ASSUMPTIONS. They are deliberately not written into the records,
-- because a per-record value looks measured once it is sitting in the data
-- next to real ones. Anything here is a stand-in until someone times it.
local VISIT_DEFAULTS = {
	RARE       = 5,   -- find it, tag it; the waiting is modelled as attempts
	VENDOR     = 5,   -- walk to a vendor and buy
	CURRENCY   = 5,
	REP        = 5,
	PROFESSION = 10,  -- gather, craft
	ZONEDROP   = 10,  -- kill things in a zone until it drops
	HOLIDAY    = 10,
	DROP       = 15,  -- a dungeon-sized run, the old flat default
	QUEST      = 20,
	PUZZLE     = 20,
	ACHIEVEMENT= 20,
	-- One match or battleground. NOT the whole grind: a Vicious saddle is a
	-- hundred wins, and the accumulation is charged by the unknown-cost
	-- penalty above, not by pretending a single game takes days.
	PVP        = 15,
}

-- Authored value, then what we measured, then the category default. Measured
-- beats the category default because it is this player's real pace on this
-- content; an authored value beats both because someone checked it.
function P.BestVisitMinutes(rec, spellID)
	if rec and rec.timePerAttempt then return math.max(rec.timePerAttempt, 1), "measured" end
	local m = spellID and MM.Attempts and MM.Attempts.MeasuredVisitMinutes
		and MM.Attempts.MeasuredVisitMinutes(spellID)
	if m then return m, "measured" end
	return P.DefaultVisitMinutes(rec), "assumed"
end

-- Is this mount the end of a QUEST CHAIN, by data or by its own prose?
--
-- One test, used by both DefaultVisitMinutes and VisitMinutes, so a chain
-- cannot be recognised in one and missed in the other -- which is exactly how
-- Child of Torcali kept its ten-minute price after the chain rule went in.
local CHAIN_WORDS = { "storyline", "questline", "quest line", "quest chain",
	"campaign", "final step", "last step", "chain of quests", "series of quests" }

-- A paragon cache: the reward comes from filling a paragon bar, so the bar is
-- the unit of attempt. Detected from the record's own prose -- the conditions
-- do not always carry a readable paragon flag, but every one of these says so.
function P.IsParagon(rec)
	if not rec then return false end
	local hay = ((rec.source or "") .. " " .. (rec.notes or "")):lower()
	return hay:find("paragon", 1, true) ~= nil
end

-- What is ACTUALLY left to reach the next paragon cache, from where you stand.
--
-- A flat bar charged everyone the same, which is wrong in both directions:
-- someone 80% into a paragon bar is nearly there, and someone sitting at
-- Honored has two full standings to climb before a paragon bar even begins.
--
-- Read in that order -- paragon progress first because it is the most specific
-- thing the client will tell us, then plain reputation progress, and only if
-- neither answers do we charge the whole climb.
function P.ParagonRemainingMinutes(rec)
	return P.RepRemainingMinutes(rec)
end

-- WHAT IS LEFT TO EARN, for every reputation and renown mount alike.
--
-- This began as paragon-only, which was the wrong shape: paragon is not a
-- special case, it is just the last segment of one continuous bar. A renown
-- mount at Renown 18 of 20 and a paragon mount 80% through its bar are the
-- same situation -- nearly done -- and both were being charged the full grind.
--
-- So the rule is uniform: find how far along the player already is, and charge
-- only the remainder. Read most-specific first, because paragon progress is a
-- finer-grained answer than the standing it sits on top of.
-- Any mount whose gate is a standing: reputation, renown or paragon alike.
function P.IsRepGated(rec)
	if not rec then return false end
	if P.IsParagon and P.IsParagon(rec) then return true end
	for _, cond in ipairs(rec.conditions or {}) do
		if cond.type == "REP" then return true end
	end
	return false
end

function P.RepRemainingMinutes(rec)
	local C = MM.Conditions
	for _, cond in ipairs((rec and rec.conditions) or {}) do
		if C and C.ParagonProgress then
			local into, _, pending = C.ParagonProgress(cond)
			if into and pending then
				return 5          -- a cache is already waiting; go and open it
			elseif into then
				return PARAGON_BAR_MINUTES * (1 - into)
			end
		end
		if C and C.RepProgress then
			local frac = C.RepProgress(cond)
			if frac and frac < 1 then
				local remaining = REP_GRIND_MINUTES * (1 - frac)
				-- A paragon mount needs a FULL bar after exalted; a plain
				-- reputation or renown mount is done when the standing lands.
				if P.IsParagon and P.IsParagon(rec) then
					remaining = remaining + PARAGON_BAR_MINUTES
				end
				local gated = P.CalendarRepMinutes(rec, frac)
				return gated or remaining
			end
		end
	end
	-- Nothing readable: charge the whole climb. For paragon, a bar on top --
	-- never the bar alone, since assuming exalted is the optimistic error.
	if P.IsParagon and P.IsParagon(rec) then
		return REP_GRIND_MINUTES + PARAGON_BAR_MINUTES
	end
	return REP_GRIND_MINUTES
end

-- A PVP SEASON REWARD IS A BAR YOU FILL WITH MATCHES.
--
-- Same shape as reputation, counted in games instead of turn-ins: how much of
-- the bar is left, how much one match pays, therefore how many matches -- and
-- match length turns that into minutes.
--
-- Earnings per match are not fixed, since a win pays materially more than a
-- loss. rec.pvpPerWin/pvpPerLoss with the player's own win rate give the true
-- expected value; a record carrying only a flat pvpPerMatch uses that as-is.
function P.PvpRemainingMinutes(rec, fractionDone)
	if not (rec and rec.pvpBarTotal) then return nil end
	local perMatch = rec.pvpPerMatch
	if not perMatch and rec.pvpPerWin and rec.pvpPerLoss then
		-- No measured win rate yet: even odds is the neutral assumption, not a
		-- flattering one.
		local winRate = (MM.PvpStats and MM.PvpStats.WinRate and MM.PvpStats.WinRate()) or 0.5
		perMatch = rec.pvpPerWin * winRate + rec.pvpPerLoss * (1 - winRate)
	end
	if not perMatch or perMatch <= 0 then return nil end
	local remaining = rec.pvpBarTotal * (1 - (fractionDone or 0))
	if remaining <= 0 then return nil end
	local matches = math.ceil(remaining / perMatch)
	return matches * (rec.pvpMatchMinutes or PVP_MATCH_MINUTES), matches
end

-- Reputations that are GATED BY THE CALENDAR, not by how long you play.
--
-- Some factions only grant reputation through daily quests or a weekly cap.
-- You cannot sit down and grind them out -- doing every daily available today
-- earns the day's allowance and then the faucet closes until tomorrow. Such a
-- rep takes WEEKS whatever the session length, and pricing it in continuous
-- minutes tells the player they can finish tonight if they just commit six
-- hours. They cannot.
--
-- Priced the same way capped currencies already are: charge the EFFORT of the
-- days you must show up for, and carry the elapsed reality in the label. That
-- keeps it comparable with everything else in the ranking while being honest
-- that no session buys it outright.
--
-- Set rec.repDaysRemaining (days of dailies still to do) to engage this.
function P.RepIsCalendarGated(rec)
	return rec and rec.repPacing == "DAILY"
end

function P.CalendarRepMinutes(rec, fractionDone)
	local days = rec and rec.repDaysRemaining
	if not days then return nil end
	if fractionDone and fractionDone > 0 then
		days = days * (1 - fractionDone)
	end
	if days <= 0 then return nil end
	-- DAILY_MINUTES_OF_EFFORT mirrors WEEK_MINUTES_OF_EFFORT: what one day's
	-- allowance costs to claim, not the 24 hours it is spread across.
	return days * DAILY_MINUTES_OF_EFFORT, days
end

function P.IsQuestChain(rec)
	if not rec then return false end
	if rec.questChain and rec.questChain.steps then return true end
	if rec.category ~= "QUEST" then return false end
	local hay = ((rec.source or "") .. " " .. (rec.notes or "")):lower()
	for _, w in ipairs(CHAIN_WORDS) do
		if hay:find(w, 1, true) then return true end
	end
	return false
end

-- Minutes per quest in a chain. An assumption, and labelled: a step is a
-- turn-in, a short errand and a flight, and thirteen of them is an evening.
local QUEST_CHAIN_MINUTES = 6

function P.DefaultVisitMinutes(rec)
	-- A CHAIN IS NOT A VISIT.
	--
	-- Child of Torcali is the reward for the LAST of thirteen quests, and it
	-- was costed at the flat QUEST visit of 20 minutes while scoring as a
	-- guaranteed mount. One guaranteed mount for twenty minutes is the best
	-- density anything can have, which is how a thirteen-quest storyline beat
	-- an island run you are standing next to.
	--
	-- You cannot have the mount without finishing the chain, so the chain IS
	-- the cost of getting it.
	if rec and rec.questChain and rec.questChain.steps then
		return math.max(rec.questChain.steps, 1) * QUEST_CHAIN_MINUTES
	end
	-- A CHAIN WE CANNOT COUNT IS STILL NOT ONE QUEST.
	--
	-- 13 records carry a real questChain and are costed by its length above.
	-- Another 35 QUEST records only SAY they are a storyline -- "the final step
	-- of", "the campaign", "the questline" -- with no step list to read. Those
	-- were costed at the flat 20-minute QUEST visit, which is the same mistake
	-- Child of Torcali made, just without the data to catch it.
	--
	-- No step count is invented here. A chain of unknown length is a cost we
	-- cannot read, and this file already has one answer for that: charge the
	-- unknown-cost figure, so it can never outrank work we CAN account for.
	-- Supplying a real questChain replaces this with arithmetic.
	if P.IsQuestChain(rec) then return UNKNOWN_COST_MINUTES end
	-- WHAT YOU ACTUALLY TAKE, when we have watched you do it.
	--
	-- Everything below is a category average, and a category average is wrong
	-- for any specific player -- someone soloing a legacy raid in current gear
	-- is not taking 25 minutes. ClearTimes keeps a running mean of your real
	-- door-to-door time per instance, so once it has seen a run or two the
	-- plan is costed on you rather than on a table.
	if rec and rec.instance and rec.instance.name and MM.ClearTimes then
		local learned = MM.ClearTimes.Get(rec.instance.name)
		if learned then return learned end
	end
	-- A raid is the one case where the container, not the category, sets the
	-- length -- a full clear is not a dungeon run.
	if rec and rec.instance and rec.instance.raid then return 25 end
	return (rec and VISIT_DEFAULTS[rec.category]) or 15
end

local function computeTimeCommitment(entry)
	local rec = entry and entry.rec
	if not rec then return 15, {} end

	local parts = {}
	-- Every estimate records WHERE IT CAME FROM.
	--
	-- Requirement — check the optimization and realistic time/material costs. The
	-- honest answer needs the plan to be able to say how much of its own total
	-- is measured and how much is assumption. Without a tag that can only be
	-- reconstructed by string-matching labels, which breaks the first time
	-- anyone rewords one.
	--
	--   "measured"  read from the client or from verified data -- a drop rate,
	--               a currency balance, achievement criteria, harvested reagents
	--   "assumed"   a stand-in for data we do not have: the flat unknown-price
	--               charge, the unmodelled-achievement charge, the effort floor
	local function add(label, minutes, kind)
		if minutes and minutes >= 1 then
			parts[#parts + 1] = { label = label, minutes = minutes,
				kind = kind or "measured" }
		end
	end

	-- The doing of it, and how many times you can actually do it.
	--
	-- Repeat attempts only count when you can repeat them TODAY. A legacy raid
	-- at 1% on a weekly lockout is not a thirteen-hour commitment -- it is a
	-- twenty-minute run you do once a week, and the improbability is already
	-- carried by `mounts`. Multiplying the time by expected attempts as well
	-- charged for the same long odds twice and buried the single biggest pool of
	-- mounts most collectors have left. The preset simulator found it: "Legacy
	-- Dungeons & Raids" put zero instance runs in its own top ten.
	-- Authored -> measured -> category default. The middle term is new: the
	-- addon times its own attempts now, so a player's real pace on this content
	-- replaces the guess after a handful of tries, without anyone filling
	-- anything in. `kind` follows it, so the report keeps telling the truth
	-- about which is which rather than calling an assumption measured.
	local visit, visitKind = P.BestVisitMinutes(rec, entry and entry.spellID)
	visit = math.max(visit, 1)
	local lockout = rec.attempts or (rec.instance and rec.instance.lockout)
	local repeatable = not (lockout == "DAILY" or lockout == "WEEKLY")
	if repeatable and rec.dropRate and rec.dropRate > 0 and rec.dropRate < 100 then
		local mean = U.AttemptEstimates(rec.dropRate)
		local attempts = math.min(mean or 1, MAX_MODELLED_ATTEMPTS)
		add(("%d attempts"):format(attempts), visit * attempts, visitKind)
	else
		add(lockout and "one run, then it locks" or "the run itself", visit, visitKind)
	end

	-- EVERY unmet requirement, priced individually.
	--
	-- Per condition rather than per record, because two currencies are two
	-- grinds and a reputation on top of a currency is both. Taking the worst
	-- single fraction -- which is what the record-level helpers return -- would
	-- price a mount wanting Exalted AND a thousand medals the same as one
	-- wanting only the medals.
	local C = MM.Conditions
	for _, cond in ipairs(rec.conditions or {}) do
		if cond.type == "REP" then
			-- Paragon is priced on its own terms.
			--
			-- The generic rep model reads paragon as ~85% done and charges the
			-- remaining 15% of a neutral-to-exalted grind: about 108 minutes for
			-- what is really a full 10,000-rep bar. That is how three paragon
			-- mounts reached the top of the list.
			--
			-- ONE bar is priced here, not the eight a 12.5% cache implies. The
			-- chance already lives in expected mounts, so charging for the
			-- repeats as well would count the same rarity twice -- the exact
			-- double-count the odds lens was written to avoid.
			local into, _, pending = C.ParagonProgress and C.ParagonProgress(cond)
			if into and pending then
				add(("%s: cache ready"):format(cond.name or "paragon"), 5)
			elseif into then
				add(("%s, %d%% to the next cache")
					:format(cond.name or "paragon", into * 100),
					PARAGON_BAR_MINUTES * (1 - into))
			else
				local frac = C.RepProgress(cond)
				if frac and frac < 1 then
					add(("%s, %d%% done"):format(cond.name or "reputation", frac * 100),
						REP_GRIND_MINUTES * (1 - frac))
				elseif not frac then
					-- a standing we cannot read is still a standing to earn
					add(cond.name or "reputation", REP_GRIND_MINUTES * 0.5, "assumed")
				end
			end
		elseif cond.type == "CURRENCY" then
			-- A weekly cap makes this arithmetic rather than an estimate.
			-- Needing 3,000 of something capped at 750 a week is four weeks,
			-- and playing harder does not change it.
			local weeks, perWeek, remaining = C.CurrencyWeeks and C.CurrencyWeeks(cond)
			if weeks and weeks > 0 then
				add(("%s: %s more, capped at %s/week — %d week%s"):format(
					cond.name or "currency", U.Comma(remaining), U.Comma(perWeek),
					weeks, weeks == 1 and "" or "s"),
					weeks * WEEK_MINUTES_OF_EFFORT)
			else
				local frac = C.CurrencyProgressFor(cond)
				if frac and frac < 1 then
					add(("%s, %d%% saved"):format(cond.name or "currency", frac * 100),
						CURRENCY_GRIND_MINUTES * (1 - frac))
				elseif not frac then
					add(cond.name or "currency", CURRENCY_GRIND_MINUTES * 0.5, "assumed")
				end
			end
		elseif cond.type == "ACHIEVEMENT" then
			-- Count what is actually LEFT, when the client can say.
			--
			-- A meta with three criteria outstanding and one with thirty were
			-- charged identically before the ids resolved -- a flat six hours
			-- scaled by an editorial effort rating. Criteria are the real unit
			-- of work in an achievement, so they are what gets charged.
			local left, total = C.AchievementCriteriaLeft and C.AchievementCriteriaLeft(cond)
			if left and total and total > 0 and left > 0 then
				add(("%s: %d of %d criteria left"):format(
					cond.name or "achievement", left, total),
					left * CRITERION_MINUTES * ((rec.effort or 3) / 3))
			else
				local frac = C.AchievementProgressFor(cond)
				if frac and frac < 1 then
					add(("%s, %d%% complete"):format(cond.name or "achievement", frac * 100),
						ACHIEVEMENT_MINUTES * (1 - frac) * ((rec.effort or 3) / 3))
				end
			end
		end
	end

	-- A verified estimate for the whole thing beats anything derived. Secrets
	-- are the case that needs it: no drop rate, no currency, no criteria -- just
	-- a long sequence of things somebody worked out once.
	if rec.acquire and rec.acquire.hours then
		local doneFraction = 0
		if MM.Acquire and MM.Acquire.StepProgress then
			local _, _, done, total = MM.Acquire.StepProgress(rec)
			if done and total and total > 0 then doneFraction = done / total end
		end
		add(("the chain, %d%% done"):format(doneFraction * 100),
			rec.acquire.hours * 60 * (1 - doneFraction))
	elseif MM.Acquire and MM.Acquire.ChainProgress then
		-- Items still to collect for a trade-in or hatch chain.
		local _, remaining = MM.Acquire.ChainProgress(rec)
		if remaining and remaining > 0 then
			-- CHAIN_STEP_MINUTES is per ACQUISITION, not per item, and some
			-- chains hand you a stack at a time: 50 Leftover Elemental Slime at
			-- 0-5 a kill is about twenty kills, not fifty. Charging per item
			-- overstates those by the batch size and pushes a modest grind above
			-- real work in the order.
			--
			-- The midpoint of a stated range is an ASSUMPTION -- the drop
			-- distribution is not published -- so it is labelled as one and
			-- lands in the assumed column of /mm timemodel rather than passing
			-- for a measurement.
			local per = rec.acquire and rec.acquire.perAttempt
			local avg, assumed
			if type(per) == "table" and per.min and per.max then
				avg, assumed = (per.min + per.max) / 2, true
			elseif type(per) == "number" and per > 0 then
				avg = per
			end
			if avg and avg > 0 then
				local runs = math.ceil(remaining / avg)
				add(("%d to collect, about %d run%s at an %s%.1f each"):format(
					remaining, runs, runs == 1 and "" or "s",
					assumed and "assumed " or "", avg),
					CHAIN_STEP_MINUTES * runs)
			else
				add(("%d more to collect"):format(remaining), CHAIN_STEP_MINUTES * remaining)
			end
		end
	end

	-- A price that exists only in prose. Not free, and not guessed at either:
	-- charged as unknown and listed in /mm gaps so it can be replaced with data.
	-- A craft costs its MISSING reagents, once we know what they are.
	--
	-- Addendum 115 charged every unmodelled craft a flat four hours. That
	-- stopped them winning the list, but it is not an answer: the same number
	-- for a mount needing three herbs and one needing forty rare drops. Once
	-- the recipe has been harvested from C_TradeSkillUI the real shortfall is
	-- known, and the warband bank counts -- reagents sitting there are
	-- available to whoever ends up doing the crafting.
	local craftPriced = false
	if MM.Crafting and MM.Crafting.IsCraft and MM.Crafting.IsCraft(rec) then
		local frac, mats = MM.Crafting.Progress(rec)
		if frac then
			craftPriced = true
			-- Priced per reagent by how it is actually obtained -- an auction
			-- house trip is not a raid lockout -- rather than a flat rate that
			-- made a stack of herbs look like a stack of soulbound drops.
			local minutes, parts = MM.Crafting.ShortfallMinutes(rec)
			if minutes and parts and #parts > 0 then
				for _, part in ipairs(parts) do
					local nm = (C_Item and C_Item.GetItemNameByID
						and C_Item.GetItemNameByID(part.itemID)) or ("item " .. part.itemID)
					add(("%d x %s (%s)"):format(part.short, nm, part.why), part.minutes)
				end
			elseif minutes == 0 then
				-- every reagent in hand: the craft itself is the only cost left
				add("reagents all in hand", 5)
			else
				local short = 0
				for _, m in ipairs(mats) do short = short + m.short end
				if short > 0 then
					add(("%d reagents still to gather"):format(short),
						short * MATERIAL_MINUTES_PER_UNIT, "assumed")
				end
			end
		end
	end

	-- A STATED GOLD PRICE, CHECKED AGAINST WHAT YOU HAVE.
	--
	-- 86 vendor mounts name their price in prose -- "for about 10g" -- and were
	-- excluded from the assumption above by the `gold` test, which meant they
	-- carried no cost term at all and fell to the category effort rating. A ten
	-- gold ram and a raid grind were ranked by the same number.
	--
	-- Gold is neither a currency id nor a duration, so the useful question is
	-- not "how long is 10 gold" but "can this character already afford it",
	-- which the client answers exactly. If it can, the only real cost left is
	-- walking up and clicking. If it cannot, we are back to not knowing, because
	-- how long gold takes to earn depends on things no API exposes.
	local goldPriced = false
	if rec.goldCost and rec.goldCost > 0 then
		local have = GetMoney and GetMoney() or nil
		local need = rec.goldCost * 10000  -- copper
		if have then
			goldPriced = true
			if have >= need then
				add(("%s gold, which you already have"):format(U.Comma(rec.goldCost)),
					PURCHASE_MINUTES, "assumed")
			else
				add(("%s gold, and you are %s short"):format(
					U.Comma(rec.goldCost), U.Comma(math.ceil((need - have) / 10000))),
					UNKNOWN_COST_MINUTES, "assumed")
			end
		end
	end

	if not craftPriced and not goldPriced and PRICED[rec.category]
		and not (rec.conditions and #rec.conditions > 0)
		and not (rec.source or ""):lower():find("gold") then
		add("cost not yet modelled", UNKNOWN_COST_MINUTES, "assumed")
	end

	-- The same hole, in a different costume. Gorestrider Gronnling is category
	-- ACHIEVEMENT with the achievement -- Glory of the Draenor Raider, thirteen
	-- criteria across two raids -- named only in prose. With nothing to read, no
	-- time was charged and it scored as a guaranteed mount for three quarters of
	-- an hour, which is how it reached #2 under Balanced.
	if rec.category == "ACHIEVEMENT" then
		local modelled = false
		for _, cond in ipairs(rec.conditions or {}) do
			if cond.type == "ACHIEVEMENT" then modelled = true break end
		end
		if not modelled then
			add("achievement not yet modelled",
				ACHIEVEMENT_MINUTES * ((rec.effort or 3) / 3), "assumed")
		end
	end

	local total = 0
	for _, part in ipairs(parts) do total = total + part.minutes end

	-- Our own editorial estimate of size is a FLOOR, never a cap: it catches the
	-- things none of the above can see.
	local floor = EFFORT_FLOOR_MINUTES[rec.effort or 3] or 45
	if total < floor then
		add("effort rating " .. (rec.effort or 3), floor - total, "assumed")
		total = floor
	end

	return total, parts
end

function P.TimeCommitment(entry)
	local hit = timeCache[entry]
	if hit and hit[3] == rankGeneration then return hit[1], hit[2] end
	local total, parts = computeTimeCommitment(entry)
	timeCache[entry] = { total, parts, rankGeneration }
	return total, parts
end

function P.EffortMinutes(entry)
	return (P.TimeCommitment(entry))
end

-- Minutes for ONE go at it, with the odds left out.
--
-- EffortMinutes is the whole grind: visit x expected attempts. That is the
-- right number for "should I spend my evening on this" and the wrong one for
-- "am I already standing here" -- an island run is fifteen minutes whether the
-- mount lands on try one or try two hundred.
--
-- Same split the time model already makes internally; this just lets the
-- router see it too.
function P.VisitMinutes(entry)
	local rec = entry and entry.rec
	-- THE CHAIN COMES FIRST, before any per-attempt figure.
	--
	-- Child of Torcali carries timePerAttempt = 10 -- the length of the last
	-- quest, which is true and completely beside the point. You cannot have the
	-- mount without the other twelve, so a ten-minute visit priced a thirteen
	-- quest storyline as an errand and it outranked an island run standing next
	-- to the player.
	if P.IsQuestChain(rec) then
		return P.DefaultVisitMinutes(rec)
	end
	-- A PARAGON CACHE IS A WHOLE BAR, NOT A VISIT.
	--
	-- Beryl Shardhide and Fierce Razorwing are 12.5% from a Death's Advance
	-- paragon cache. One ATTEMPT is filling an entire paragon reputation bar --
	-- days of dailies -- but they carry a dropRate, so VisitMinutes fell to the
	-- REP default of five minutes and a session read two long grinds as the
	-- cheapest thing in the plan.
	--
	-- TimeCommitment has priced a paragon bar correctly all along; the session
	-- costs by VisitMinutes and never reached it.
	-- A PVP BAR IS A MATCH COUNT, not a visit.
	--
	-- Same failure as paragon: a Vicious mount carries a category default of a
	-- few minutes, when one "attempt" is 2,400 points of rated wins.
	if rec and rec.pvpBarTotal then
		local mins = P.PvpRemainingMinutes(rec, MM.PvpStats and MM.PvpStats.BarProgress
			and MM.PvpStats.BarProgress() or 0)
		if mins then return mins end
	end
	if rec and P.IsRepGated and P.IsRepGated(rec) then
		return P.RepRemainingMinutes(rec)
	end
	if rec and rec.timePerAttempt then
		return math.max(rec.timePerAttempt, 1)
	end
	-- Attempt-shaped content with no stated time: use the category default
	-- rather than the full commitment, or a repeatable grind reads as one
	-- enormous visit and loses its "you are already here" promotion.
	if rec and (rec.dropRate or rec.instance or rec.npc) then
		return P.DefaultVisitMinutes(rec)
	end
	-- No per-attempt time means the content is not attempt-shaped: a
	-- meta-achievement, a reputation, a campaign. For those, one go at it IS
	-- the whole thing, so the honest visit cost is the full commitment.
	--
	-- Defaulting these to fifteen minutes instead is what would have let Taivan
	-- back in -- it has no timePerAttempt, so a flat default called hundreds of
	-- hours a quarter-hour and handed it the promotion the tier gate existed to
	-- deny. The fallback has to fail safe, not fail cheap.
	return (P.TimeCommitment(entry))
end

-- True when nothing is standing between the player and the mount, false when
-- something demonstrably is, nil when we cannot tell.
function P.CompletableNow(entry)
	local rec = entry and entry.rec
	if not rec then return nil end
	if rec.conditions and #rec.conditions > 0 then
		return MM.Conditions.EvaluateAll(rec)
	end
	if PRICED[rec.category] then return nil end -- a price we cannot read
	if rec.category == "ACHIEVEMENT" then return nil end -- criteria we cannot read
	return true
end

-- Rough expected mounts per hour: chance per attempt over time per attempt.
-- Higher is better.
function P.ValuePerMinute(entry)
	local rec = entry.rec
	if not rec then return 0 end
	local chance = P.ExpectedMounts(entry)
	-- the SAME number the router uses, so the tooltip and the route can never
	-- tell the player two different stories about the same goal
	local minutes = P.EffortMinutes(entry)
	-- The rep and currency inflation that used to live here is inside
	-- EffortMinutes now. Doing it in both places would charge the shortfall
	-- twice, and having two copies of the rule is how they drift apart.
	local vpm = (chance / minutes) * 60

	-- Routing used to weigh payoff and travel and NOTHING ELSE, so the priority
	-- order the player set had no say in the order they were actually sent
	-- around -- it only sorted the "easiest" list. A goal's kind is part of what
	-- it costs: needing four other people is real time that never appears in
	-- timePerAttempt.
	--
	-- Discount, don't forbid. This is a blended route, so a superb GROUP payoff
	-- may still beat a dismal PICKUP; what it can no longer do is win on a
	-- fabricated certainty alone.
	local rank = MM.Weights.TierRank((P.Rank(entry)))
	return vpm / (1 + (rank - 1) * MM.Weights.Get("priority"))
end

-- Value-only score (0..10000, lower = better payoff per minute). Used INSIDE
-- an urgency band, where it must stay comparable to travel distance in yards.
-- Cost form of a value-per-minute figure: lower is better, on the same
-- numeric scale as travel distance so the router can blend the two.
function P.ValueScoreFromVPM(vpm)
	return 10000 / (1 + math.max(vpm or 0, 0) * 100)
end

function P.ValueScore(entry)
	return P.ValueScoreFromVPM(P.ValuePerMinute(entry))
end

-- One sortable number for routing: urgency band, then value per minute.
-- Deadline pressure scales the size of the urgency band. At 1.0 the bands are
-- impassable, which is the old behaviour; at 0 they collapse entirely and pure
-- payoff decides the route, which is what a collector with no interest in
-- chasing weeklies actually wants.
function P.SessionScore(entry)
	local band = 1000000 * MM.Weights.Get("urgency")
	return P.Urgency(entry) * band + P.ValueScore(entry)
end


function P.EaseScore(entry)
	return easeScore(entry)
end

------------------------------------------------------------
-- "Why is this here?"
------------------------------------------------------------
-- the player, on a #7-priority goal sitting near the top: i think its reasonable if
-- like a #7 sits with a high ranking opportunity because of grouping nearby
-- rewards/drops, or if its time bound, but this goes to our weights and its
-- still a little opaque.
--
-- Exactly right, and the fix is not to change the ranking -- batching and
-- deadlines SHOULD outrank priority -- but to stop making the player infer it.
-- Every line below names a real term and the points it contributed, in the same
-- currency as the sliders, so the answer to "why is this here" and the answer to
-- "what do I change" are the same screen.
--
-- Returns an array of { text, r, g, b, indent }.
--
-- Compact on purpose. The first draft printed the cost as five separate lines
-- and repeated the tier label the caller had already shown, which is exactly
-- the "repeats itself" problem: transparency is not the same as volume, and a
-- tooltip nobody finishes reading explains nothing.
function P.Explain(entry)
	local out = {}
	local function add(text, r, g, b, indent)
		out[#out + 1] = { text = text, r = r or 0.8, g = g or 0.8, b = b or 0.8,
			indent = indent }
	end

	local rec = entry.rec
	if not rec then
		add("Not catalogued — nothing to explain yet.", 0.6, 0.6, 0.6)
		return out
	end

	local tier = P.Rank(entry)
	local rank = MM.Weights.TierRank(tier)
	add(("Priority %d of %d: %s"):format(rank, #MM.Weights.DEFAULT_ORDER + 1,
		P.TIER_LABEL[tier] or "?"), 1, 0.82, 0.2)

	-- What is standing in the way, when something is. A blocked goal used to
	-- explain its priority and its time cost and then simply stop, because
	-- payoff is zero while it is blocked and the payoff line is what carried
	-- the "why". That left the one question the player actually has -- why can
	-- I not do this -- as the only thing the explanation would not answer.
	local status, statusDetail = MM.Availability.GetStatus(entry)
	if status and status ~= "AVAILABLE" and status ~= "COLLECTED" then
		add(statusDetail or U.STATUS_LABEL[status] or status, 1, 0.6, 0.35, true)
	end

	-- What can push a goal ABOVE its priority. Named explicitly, because these
	-- are the two cases that look like a bug and are not.
	local urgency, urgencyReason = P.Urgency(entry)
	local stop = MM.Router.StopFor and MM.Router.StopFor(entry.spellID)
	local batched = stop and stop.members and #stop.members or 1
	if urgency < P.URGENCY.ANYTIME and urgencyReason
		and not (statusDetail and U.Restates(statusDetail, urgencyReason)) then
		add(urgencyReason, 1, 0.5, 0.3, true)
	end
	if batched > 1 then
		add(("Batched with %d other%s here — one trip, every roll"):format(
			batched - 1, batched == 2 and "" or "s"), 0.4, 0.9, 0.5, true)
	elseif stop and stop.opportunistic then
		add(("Picked up on the way — %.0f min off your path")
			:format(stop.detourMinutes or 0), 0.4, 0.9, 0.5, true)
	end

	-- The internal cost breakdown is deliberately NOT shown here. "Costs -213
	-- - effort 160 - travel 250 - long odds -64" is the ranking's own
	-- arithmetic in the ranking's own units; it means nothing to a player
	-- deciding what to farm tonight, and a number nobody can act on is noise
	-- dressed as transparency.
	--
	-- It is still fully inspectable: CostParts drives /mm costs and the
	-- self-test that proves the breakdown matches the score actually used.
	-- Auditable on request, absent from the hover.

	-- What it will actually take. Itemised, because "about 14 hours" invites
	-- exactly one question and this answers it in the same breath.
	local minutes, timeParts = P.TimeCommitment(entry)
	if #timeParts > 0 then
		local bits = {}
		for _, part in ipairs(timeParts) do
			bits[#bits + 1] = ("%s %s"):format(U.FormatSeconds(part.minutes * 60), part.label)
		end
		add(("Time to finish: %s — %s"):format(
			U.FormatSeconds(minutes * 60), table.concat(bits, " + ")), 0.85, 0.7, 0.4)
	end

	-- Payoff, in the two forms people actually think in.
	local chance = P.ExpectedMounts(entry)
	local vpm = P.ValuePerMinute(entry)
	if chance > 0 then
		local perVisit = chance >= 1 and "guaranteed this visit"
			or ("%.3g%% per attempt"):format(chance * 100)
		local rate = vpm >= 1 and ("%.1f/hour"):format(vpm)
			or ("about 1 per %d hours"):format(math.max(1, math.floor(1 / math.max(vpm, 1e-6) + 0.5)))
		add(("Payoff: %s, %s"):format(perVisit, rate), 0.5, 0.8, 1)
	else
		-- Zero is an answer, and silence is not. A blocked goal yields nothing
		-- until it is unblocked, and saying so is what makes the difference
		-- between "this is worthless" and "this is not open to you yet".
		add(status and status ~= "AVAILABLE"
			and "Payoff: nothing until the requirement above is met"
			or "Payoff: no rate recorded yet — ranked pessimistically",
			0.6, 0.6, 0.65)
	end

	return out
end

-- Shared list sorting for every mount list in the addon.
-- mode: nil/"NAME" (journal order), "EASE", "STATUS", "EXPANSION"
local STATUS_RANK = {
	AVAILABLE = 1, LOCKED = 2, GATED = 3, HOLIDAY = 4, ROTATION = 5,
	PREREQ = 6, UNKNOWN = 7, UNOBTAINABLE = 8, COLLECTED = 9,
}

function P.SortEntries(list, mode)
	if not mode or mode == "NAME" then return list end
	local key = {}
	if mode == "EASE" then
		for _, e in ipairs(list) do key[e] = easeScore(e) end
	elseif mode == "STATUS" then
		for _, e in ipairs(list) do key[e] = STATUS_RANK[MM.Availability.GetStatus(e)] or 5 end
	elseif mode == "EXPANSION" then
		for _, e in ipairs(list) do key[e] = (e.rec and e.rec.expansion) or 99 end
	else
		return list
	end
	-- Total comparator. A sort comparator is the one place where bad data
	-- does not degrade -- it raises, and takes the whole list view down with
	-- it. The fallbacks cost nothing when the data is well formed and turn a
	-- broken UI into a merely odd order when it is not.
	table.sort(list, function(a, b)
		local ka, kb = key[a] or math.huge, key[b] or math.huge
		if ka == kb then return (a.name or "") < (b.name or "") end
		return ka < kb
	end)
	return list
end

-- The next-n easiest NOT already in the plan — so clicking "Add 10 Easiest"
-- repeatedly keeps feeding the plan in difficulty order.
function P:Easiest(n)
	n = n or 10
	local pool = {}
	for _, entry in ipairs(MM.Scanner.mounts) do
		if not entry.collected and plannable(entry) and not P:InPlan(entry.spellID) then
			tinsert(pool, { entry = entry, score = easeScore(entry) })
		end
	end
	table.sort(pool, function(a, b) return (a.score or 0) < (b.score or 0) end)
	local out = {}
	for i = 1, math.min(n, #pool) do tinsert(out, pool[i].entry) end
	return out
end

------------------------------------------------------------
-- Per-mount planning estimate (the "how long is this really" line)
------------------------------------------------------------
function P:EstimateLine(entry)
	local rec = entry.rec
	if not rec then return nil end

	-- Timewalking badge math beats the generic paths
	local _, _, twText = MM.Timewalking.Estimate(rec)
	if twText then return twText end

	if rec.dropRate then
		return U.DropEstimateText(rec, MM.Attempts.Get(entry.spellID))
	end

	if rec.conditions then
		for _, cond in ipairs(rec.conditions) do
			if cond.type == "REP" then
				local _, text = MM.Conditions.Evaluate(cond)
				return text
			end
		end
		for _, cond in ipairs(rec.conditions) do
			if cond.type == "ITEM" and cond.cost then
				return "Buy: " .. (cond.name or "item") .. " — " .. cond.cost
			end
			if cond.type == "CURRENCY" then
				local _, text = MM.Conditions.Evaluate(cond)
				return text
			end
		end
	end

	return rec.source
end

-- Rewrite the plan's stored order into the optimized route order:
-- actionable goals in travel order (cheap wins first), then locationless
-- actionable goals, then everything currently blocked (lockout/event).
-- Rewrite cdb.plan into the order the COMPLETED route puts it in.
--
-- Split out from Optimize so it can run as a build-completion callback. It must
-- never run against a route that is still being charted: doing so rewrote the
-- plan into the ORDER BEFORE LAST, which then looked like the optimizer
-- shuffling goals for no reason.
local function rewritePlanFromRoute()
	local R = MM.Router
	local order, seen = {}, {}
	local function push(spellID)
		if spellID and not seen[spellID] then
			seen[spellID] = true
			tinsert(order, spellID)
		end
	end
	-- EVERY MOUNT AT A STOP, IN THE STOP'S ORDER.
	--
	-- This pushed `step.entry.spellID` only -- one id per stop -- so the other
	-- four mounts at a five-mount stop fell through to the plan tail below and
	-- were scattered to the end, far from the trip that collects them. The plan
	-- claimed to be in route order and was not, wherever a stop is shared.
	for _, step in ipairs(R.route) do
		for _, m in ipairs(step.members or { step }) do
			push(m.entry and m.entry.spellID)
		end
	end
	for _, entry in ipairs(R.unrouted) do push(entry.spellID) end
	for _, d in ipairs(R.deferred) do push(d.entry.spellID) end
	for _, item in ipairs(MM.cdb.plan) do push(item.spellID) end

	-- KEEP EACH GOAL'S OWN `added` TIMESTAMP.
	--
	-- Every item was restamped with one fresh timestamp on every optimize, so
	-- "when did I plan this" became "when was the route last charted" -- the
	-- same value for all of them, rewritten several times an hour. Anything
	-- sorting or reporting by age was reading the chart clock.
	local addedFor = {}
	for _, item in ipairs(MM.cdb.plan) do
		if item.spellID and item.added then addedFor[item.spellID] = item.added end
	end

	wipe(MM.cdb.plan)
	local now = GetServerTime()
	for _, spellID in ipairs(order) do
		tinsert(MM.cdb.plan, { spellID = spellID, added = addedFor[spellID] or now })
	end
	return #R.route, #R.deferred
end

-- Rewrite the plan's stored order into the optimized route order:
-- actionable goals in travel order (cheap wins first), then locationless
-- actionable goals, then everything currently blocked (lockout/event).
--
-- `onDone` is called with (stops, deferred) once the rewrite has happened. The
-- rewrite waits on the build, so a caller that needs the counts must wait too.
function P:Optimize(onDone)
	-- Charting is the ONE moment the anchor moves. Everything downstream --
	-- the ease score's travel term, the route's first leg -- is measured from
	-- here, and it holds until you edit the plan again.
	if P.SetAnchor then P.SetAnchor() end
	-- THE REWRITE WAITS FOR THE ROUTE.
	--
	-- This called the asynchronous Build and reordered the plan on the next
	-- line, so it sorted the plan by the PREVIOUS route every single time.
	MM.Router.AfterBuild(false, function(_, ok)
		-- REWRITING FROM A ROUTE THAT WAS NEVER BUILT IS THE ORIGINAL BUG.
		--
		-- On failure the previous route is still published, and sorting the
		-- plan by it is exactly what this function was changed to stop doing --
		-- it would order the plan by the chart from before last, silently.
		-- `onDone` still runs, because the caller holds a lock on it.
		if not ok then
			if onDone then onDone(nil, nil) end
			return
		end
		local stops, waiting = rewritePlanFromRoute()
		-- ONE settled notification, after the plan is in its final shape.
		MM:Fire("MM_PLAN_CHANGED")
		if onDone then onDone(stops, waiting) end
	end)
end

------------------------------------------------------------
-- The plan optimizes itself
------------------------------------------------------------
-- Adding a mount re-slots it. Previously nothing called Optimize -- the button
-- was removed and the route was only rebuilt while one was RUNNING, so adding
-- three mounts left them in the order you clicked them and nothing worked out
-- where they belonged until you pressed Start Route.
--
-- Two hazards, both real:
--
-- 1. RECURSION. Optimize() ends by firing MM_PLAN_CHANGED, which is the event
--    that would trigger it. Guarded by `optimizing`.
-- 2. STORMS. "Add 10 Easiest" fires ten times and Auto-Plan can fire for
--    hundreds. Coalesced into one pass at the end of the frame, so N adds cost
--    one optimize rather than N.
--
-- Manual reordering is exempt: the up/down arrows exist to say "I want this
-- one first", and an optimize that immediately undid the click would make them
-- a button that does nothing.
local optimizing, queued = false, false
function P.SuppressAutoOptimize(fn)
	local prev = optimizing
	optimizing = true
	local ok, err = pcall(fn)
	optimizing = prev
	if not ok then error(err, 0) end
end

local function scheduleOptimize()
	if optimizing or queued then return end
	if not (MM.cdb and MM.cdb.plan and #MM.cdb.plan > 0) then return end
	queued = true
	-- END OF FRAME, DELIBERATELY.
	--
	-- Availability invalidates its status cache on these same events, and this
	-- must run AFTER that or it optimizes against the state before the lockout.
	-- Deferring to the end of the frame gets both: every synchronous handler
	-- has run, and a burst of adds collapses into one pass.
	C_Timer.After(0, function()
		queued = false
		-- Claim the lock NOW, not inside the second timer: between these two
		-- frames another plan edit could otherwise queue a second pass.
		optimizing = true
		local n = MM.cdb and MM.cdb.plan and #MM.cdb.plan or 0
		MM:Fire("MM_PLAN_PROGRESS", nil, n, "Charting the route")
		-- ONE MORE FRAME BEFORE THE BLOCKING CALL.
		--
		-- Optimize does not yield, so anything drawn in the same frame is
		-- never painted -- the warning about the client going unresponsive
		-- would itself only appear after the client had finished being
		-- unresponsive. Handing the frame back once lets it show first.
		C_Timer.After(0, function()
			local released = false
			local function done()
				if released then return end
				released = true
				optimizing = false
				MM:Fire("MM_PLAN_PROGRESS", nil)
			end
			-- THE LOCK IS HELD UNTIL THE REWRITE HAS ACTUALLY HAPPENED.
			--
			-- Optimize completes asynchronously and fires MM_PLAN_CHANGED at the
			-- end, which is the event that schedules it. Releasing when Optimize
			-- RETURNS rather than when it FINISHES would let its own notification
			-- queue the next pass, and that pass the one after: an endless
			-- build -> plan change -> build loop with nothing to end it.
			local ok, err = pcall(function() P:Optimize(done) end)
			if not ok then
				done()
				if MM.Print then
					MM:Print("|cffff5555auto-optimize failed|r -- %s", tostring(err):sub(-140))
				end
			end
		end)
	end)
end

-- ONLY A DELIBERATE EDIT RE-CHARTS THE PLAN.
--
-- The plan is a chart: from where you stand, to the first objective, then to
-- the next, and so on. It holds still while you follow it. Re-optimizing on
-- world events would reshuffle objectives two and three while you were flying
-- to objective one, which is the opposite of a plan.
--
-- So MM_LOCKS and MM_SCANNED deliberately do NOT re-chart, even though both
-- change what is actionable. Taking a lockout or learning a mount drops that
-- one goal out; the others keep the places they already had.
MM:On("MM_PLAN_CHANGED", scheduleOptimize)

-- Taking a lockout retires that goal for now, WITHOUT re-charting the rest.
--
-- Removal is suppressed from the auto-optimize above for exactly the reason
-- in that comment: this is the addon tidying up after the world, not you
-- changing your mind, so nothing else is allowed to move.
-- Retired by a lockout, and owed a place back when it lifts.
--
-- Kept account-wide, because the lockout is: a raid you are saved to is saved
-- on every character, and the plan already follows you between them.
local function retiredList()
	MM.db = MM.db or {}
	MM.db.retired = MM.db.retired or {}
	return MM.db.retired
end

local function status(spellID)
	local entry = MM.Scanner and MM.Scanner.bySpell and MM.Scanner.bySpell[spellID]
	if not entry then return nil, nil end
	return MM.Availability and MM.Availability.GetStatus(entry), entry
end

-- THE TWO HALVES ARE NOT SYMMETRICAL, AND THAT IS THE POINT.
--
-- Retiring is the addon tidying up after the world: that one goal leaves and
-- everything else keeps the place it already had, because you may be halfway
-- to objective one and nothing else should move under you.
--
-- Restoring is a new opportunity. By the time a lockout lifts you have almost
-- certainly moved, and the returning goal might now be the very next thing
-- worth doing or the fifth -- putting it back where it used to sit would drop
-- it somewhere that made sense from a position you left hours ago. So a
-- restore DOES re-chart, from where you are standing now.
local function reviewLockouts()
	if not MM.Scanner then return end
	local retired = retiredList()

	-- 1. retire what is newly locked -- quietly, nothing else moves
	local drop = {}
	for _, item in ipairs(MM.cdb and MM.cdb.plan or {}) do
		if status(item.spellID) == "LOCKED" then drop[#drop + 1] = item.spellID end
	end
	if #drop > 0 then
		P.SuppressAutoOptimize(function()
			for _, spellID in ipairs(drop) do
				P:Remove(spellID)                 -- clears any stale retired mark
				retired[spellID] = { at = GetServerTime() }
			end
		end)
		if MM.Print then
			MM:Print("%d goal%s on lockout -- off the plan until it lifts.",
				#drop, #drop == 1 and "" or "s")
		end
	end

	-- 2. restore what is no longer locked -- and let this one re-chart
	local back = {}
	for spellID in pairs(retired) do
		local st, entry = status(spellID)
		if not entry or (entry and entry.collected) then
			retired[spellID] = nil          -- learned it meanwhile; nothing owed
		elseif st and st ~= "LOCKED" then
			back[#back + 1] = spellID
		end
	end
	for _, spellID in ipairs(back) do
		retired[spellID] = nil
		P:Add(spellID)                      -- fires MM_PLAN_CHANGED -> re-chart
	end
	if #back > 0 and MM.Print then
		MM:Print("%d goal%s off lockout -- back on the plan, re-charted from here.",
			#back, #back == 1 and "" or "s")
	end
end

MM:On("MM_LOCKS", reviewLockouts)
-- A lockout usually lifts at a server reset that fires no event of its own, so
-- the restore cannot wait on MM_LOCKS alone. These are the moments the client
-- refreshes what you are saved to.
MM:On("MM_SCANNED", reviewLockouts)
C_Timer.NewTicker(300, reviewLockouts)

MM:On("MM_EASIEST", function()
	local list = P:Easiest(10)
	MM:Print("Easiest missing mounts right now:")
	for i, entry in ipairs(list) do
		local status = MM.Availability.GetStatus(entry)
		MM:Print("%d. %s — %s [%s]", i, entry.name,
			entry.rec.source or "?", U.STATUS_LABEL[status] or status)
	end
	if #list == 0 then MM:Print("Nothing plannable is missing. Impressive.") end
end)
