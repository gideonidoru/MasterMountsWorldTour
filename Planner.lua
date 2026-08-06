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
function P:GetMissing()
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
	return P.SortEntries(out, f.sort)
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
	MM:Fire("MM_PLAN_CHANGED")
end

function P:Clear()
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
	local added = 0
	for _, entry in ipairs(MM.Scanner.mounts) do
		if not entry.collected and plannable(entry) and not P:InPlan(entry.spellID) then
			tinsert(MM.cdb.plan, { spellID = entry.spellID, added = GetServerTime() })
			added = added + 1
		end
	end
	if added > 0 then MM:Fire("MM_PLAN_CHANGED") end
	return added
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
local function proximityPenalty(rec)
	local playerContinent = select(1, U.PlayerWorldPos())
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

	-- the user, on the previous version of this: do not default to group if you can
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
-- The tier's POSITION in the user's priority order leads, not its constant:
-- someone who puts rares above achievements means it absolutely, so no
-- achievement subscore may cross the boundary. P.TIER values stay fixed as
-- identities, which is what the router's semantic thresholds compare against.
-- EASE IS NOT PREFERENCE.
--
-- This used MM.Weights.TierRank, which orders tiers by the user's OWN
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
-- PROFESSION was missing, and the user caught what that produced: its showing
-- protoform synthesis mounts that I do not have materials for and would need to
-- farm but is not considering the farm. All 24 Protoform Synthesis records
-- carry no conditions and no chain, so each was a GUARANTEED mount costed at
-- the 45-minute effort floor -- a density nothing else in the plan could beat.
-- A craft always needs materials; pretending otherwise is the same hole that
-- unpriced vendor mounts and unmodelled achievements fell through.
local PRICED = { CURRENCY = true, VENDOR = true, REP = true, TIMEWALKING = true,
	PROFESSION = true }

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

function P.DefaultVisitMinutes(rec)
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
-- the user, on a #7-priority goal sitting near the top: i think its reasonable if
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
function P:Optimize()
	MM.Router:Build()
	local order, seen = {}, {}
	local function push(spellID)
		if spellID and not seen[spellID] then
			seen[spellID] = true
			tinsert(order, spellID)
		end
	end
	for _, step in ipairs(MM.Router.route) do push(step.entry.spellID) end
	for _, entry in ipairs(MM.Router.unrouted) do push(entry.spellID) end
	for _, d in ipairs(MM.Router.deferred) do push(d.entry.spellID) end
	for _, item in ipairs(MM.cdb.plan) do push(item.spellID) end

	wipe(MM.cdb.plan)
	local now = GetServerTime()
	for _, spellID in ipairs(order) do
		tinsert(MM.cdb.plan, { spellID = spellID, added = now })
	end
	MM:Fire("MM_PLAN_CHANGED")
	return #MM.Router.route, #MM.Router.deferred
end

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
