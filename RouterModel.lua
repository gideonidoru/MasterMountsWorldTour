-- Master Mounts: router modelling harness.
--
-- The router is the part of this addon a player cannot check. A wrong drop
-- rate shows up as bad luck; a wrong destination shows up as someone standing
-- in Dornogal wondering where the Shadowlands dungeon went. That bug was found
-- by a human reading a nav card, which is not a strategy.
--
-- So: pick goals that are most likely to break it, build the route under
-- several different sets of player capability, and assert the things that must
-- be true of every route regardless of what the player owns.
--
-- WHY VARY CAPABILITY. Travel time is the cost, not distance, and which
-- teleports someone owns changes every answer. A route that is optimal for a
-- veteran with every toy can be nonsense for a fresh character with a
-- hearthstone. Both have to be right, and only one of them is what we test on
-- by accident.
--
-- WHAT IT DOES NOT DO. It does not check that a coordinate points at the right
-- patch of ground -- nothing here can know that. It checks that the router
-- produced a coherent, ordered, reachable plan and that we have a precise
-- enough destination for the KIND of thing each goal is. Judging the actual
-- coordinates is why the output is built to be pasted at a human.
local _, MM = ...

MM.RouterModel = {}
local RM = MM.RouterModel

------------------------------------------------------------
-- How precise does arriving at this goal have to be?
------------------------------------------------------------
-- A vendor is a person standing on one tile: a zone name is not a destination,
-- it is a hint. A zone-wide drop is the opposite -- the zone IS the answer and
-- a coordinate would be false precision. Risk is the gap between the precision
-- a goal demands and the precision we hold for it.
local NEED = {
	VENDOR = 3, CURRENCY = 3, REP = 3, TIMEWALKING = 3, TRADINGPOST = 3,
	PUZZLE = 3, TREASURE = 3, GARRISON = 2, PROFESSION = 2, QUEST = 2,
	DROP = 2, RARE = 2, PVP = 2, HOLIDAY = 2, HOLIDAYBOSS = 2,
	ZONEDROP = 1, ACHIEVEMENT = 0, CLASS = 0,
}
-- No travel involved, so no destination to be wrong about.
local NO_TRAVEL = { STORE = true, TCG = true, PROMOTION = true, REMOVED = true }

function RM.Precision(rec)
	if not rec then return 0, 0 end
	local need = NEED[rec.category or ""] or 2
	local have = 0
	if rec.zone and rec.zone.x and rec.zone.y then have = 2
	elseif (rec.zone and rec.zone.name) or (rec.instance and rec.instance.name) then have = 1 end
	return need, have
end

-- CRITICAL: we would be sending them nowhere at all.
-- HIGH    : we would name a zone and expect them to find a person in it.
function RM.RiskOf(rec)
	if not rec or NO_TRAVEL[rec.category or ""] then return 0, "no travel" end

	-- Some goals have no zone in the RECORD and still route perfectly, because
	-- the router synthesises a destination at build time. Judging the record
	-- alone called those CRITICAL and filled the sample with them.
	--
	-- A queued goal has nowhere to point on purpose -- that IS the feature.
	if MM.Queue and MM.Queue.KindFor and MM.Queue.KindFor(rec) then
		return 0, "reached by queueing, not travelling"
	end
	-- Timewalking stock that sells every era follows the LIVE event vendor,
	-- so its destination changes weekly and cannot live in the record.
	if rec.category == "TIMEWALKING" and MM.Timewalking then
		local anyEra = rec.anyEra
			or (rec.source or ""):lower():find("every era", 1, true)
		if anyEra and MM.Timewalking.IsActive and MM.Timewalking.IsActive()
			and MM.Timewalking.VendorLocation and MM.Timewalking.VendorLocation() then
			return 0, "follows the live Timewalking vendor"
		end
	end

	local need, have = RM.Precision(rec)
	if need == 0 then return 0, "no travel" end
	if have == 0 then return 3, "no location at all" end
	if need >= 3 and have < 2 then return 2, "needs an exact spot, has only a zone" end
	if need >= 2 and have < 2 then return 1, "zone only" end
	return 0, "has coordinates"
end

------------------------------------------------------------
-- Capability profiles
------------------------------------------------------------
-- Built by FILTERING the player's live snapshot rather than inventing
-- landings. An invented teleport lands at an invented place and would prove
-- the router works on a world that does not exist; a filtered one keeps every
-- real destination and cooldown and only varies what is owned.
local PROFILES = {
	{ key = "none",    label = "no teleports at all (fresh character)",
	  allow = function() return false end },
	{ key = "hearth",  label = "hearthstone only",
	  allow = function(k) return k == "hearth" end },
	{ key = "typical", label = "hearthstone + the common portals",
	  allow = function(k)
		return k == "hearth" or k:find("portal") ~= nil or k:find("dalaran") ~= nil
			or k:find("garrison") ~= nil or k:find("hall") ~= nil
	  end },
	{ key = "all",     label = "everything this character actually owns",
	  allow = function() return true end },
}
RM.PROFILES = PROFILES

------------------------------------------------------------
-- Choosing what to model
------------------------------------------------------------
-- Deliberately NOT a random sample. A random draw is mostly zone drops, which
-- are the case that cannot really fail. We want the destinations that have to
-- be exactly right, plus a spread of categories so a whole class of goal
-- cannot silently regress.
function RM.Sample(n)
	n = n or 12
	local U = MM.Util
	local pool = {}
	for _, entry in ipairs(MM.Scanner and MM.Scanner.mounts or {}) do
		local rec = entry.rec
		if rec and not rec.stub and rec.obtainable ~= false and not entry.collected then
			local risk, why = RM.RiskOf(rec)
			if risk > 0 then
				-- Can the router put this anywhere at all? Same question
				-- makeStep asks, so the answer cannot disagree with it.
				local mapID = U and U.GetRecordMapID and U.GetRecordMapID(rec)
				if not mapID and rec.instance and rec.instance.name and U.ResolveMapForRecord then
					mapID = U.ResolveMapForRecord(rec.instance.name, rec)
				end
				pool[#pool + 1] = {
					entry = entry, rec = rec, risk = risk, why = why,
					routable = mapID and true or false,
				}
			end
		end
	end
	table.sort(pool, function(a, b)
		if a.risk ~= b.risk then return a.risk > b.risk end
		return (a.entry.name or "") < (b.entry.name or "")
	end)

	-- STRATIFIED, not just "the worst n".
	--
	-- Sorting by risk alone filled the entire sample with records that have no
	-- location at all. Those are worth surfacing -- they are the real data gap
	-- -- but a goal the router cannot place cannot exercise routing, so every
	-- capability profile produced an identical route and the one check worth
	-- having (travel must fall as teleports are added) was never tested.
	--
	-- So: a quarter of the sample may be unplaceable, and the rest must be
	-- goals the router can actually route, spread across categories.
	local unplaceableCap = math.max(1, math.floor(n / 4))
	local categoryCap = math.max(2, math.floor(n / 4))
	local out, perCategory, unplaceable = {}, {}, 0

	local function take(cand)
		local cat = cand.rec.category or "?"
		if (perCategory[cat] or 0) >= categoryCap then return false end
		if not cand.routable then
			if unplaceable >= unplaceableCap then return false end
			unplaceable = unplaceable + 1
		end
		perCategory[cat] = (perCategory[cat] or 0) + 1
		out[#out + 1] = cand
		return #out >= n
	end

	for _, cand in ipairs(pool) do if take(cand) then break end end
	-- Still short (a small or heavily collected plan): relax the category cap
	-- rather than return a thin sample, but never the unplaceable quota.
	if #out < n then
		local chosen = {}
		for _, c in ipairs(out) do chosen[c] = true end
		for _, cand in ipairs(pool) do
			if #out >= n then break end
			if not chosen[cand] and cand.routable then
				out[#out + 1] = cand
				chosen[cand] = true
			end
		end
	end
	-- Second return: how many candidates EXISTED, so the caller can tell
	-- "there were only 20" from "I truncated to 20".
	return out, #pool
end

------------------------------------------------------------
-- Running one model
------------------------------------------------------------
-- The plan is swapped by replacing the ACCESSOR, not the saved plan. Writing a
-- synthetic plan into MM.cdb.plan and restoring it afterwards would destroy a
-- real player's plan if anything in between threw.
local function withPlan(entries, fn)
	local P = MM.Planner
	local realGet = P.GetPlan
    P.GetPlan = function() return entries end
	local ok, err = pcall(fn)
	P.GetPlan = realGet
	if not ok then error(err, 0) end
end

local function withProfile(profile, fn)
	local TP = MM.Teleports
	if not TP then return fn() end
	local realOptions, realLandings, realRefresh = TP.Options, TP.Landings, TP.Refresh
	local live = realOptions and realOptions() or {}
	local allowed = {}
	for _, landing in ipairs(live) do
		if profile.allow(tostring(landing.key or "")) then allowed[#allowed + 1] = landing end
	end
	TP.Options = function() return allowed end
	TP.Landings = function(used)
		if not used then return allowed end
		local out = {}
		for _, l in ipairs(allowed) do if not used[l.key] then out[#out + 1] = l end end
		return out
	end
	TP.Refresh = function() return allowed end
	-- TravelMinutes is the SLOW path travelMinutes() falls back to when a step
	-- carries no precomputed costs. Left un-overridden it answers from the
	-- player's real teleports no matter which profile is running, so every
	-- profile would quietly agree -- and the invariant would pass by accident.
	local realTravel = TP.TravelMinutes
	if realTravel then
		TP.TravelMinutes = function(fc, fw, tc, tw, used)
			local blocked = {}
			for k, v in pairs(used or {}) do blocked[k] = v end
			for _, l in ipairs(realOptions and realOptions() or {}) do
				if not profile.allow(tostring(l.key or "")) then blocked[l.key] = true end
			end
			return realTravel(fc, fw, tc, tw, blocked)
		end
	end
	-- The journey planner caches a route per zone-pair and reads TP.Options only
	-- when it MISSES. So the first profile filled the cache and every later one
	-- replayed its answers verbatim -- which is why all four profiles reported
	-- identical times, and why the "no teleports at all" profile was routing via
	-- a Cloak of Coordination it does not own. Clear it on the way in AND on the
	-- way out, so no profile inherits another's cache and the player's real
	-- session is not left holding the last profile's answers.
	if MM.Journey and MM.Journey.Forget then MM.Journey.Forget() end

	-- AND the per-stop teleport costs, which are the fast path and therefore the
	-- one that actually decides the leg.
	--
	-- R.PrecomputeTravel caches a sorted landing list on every stop so the
	-- improvement pass does not re-walk the teleport list thousands of times.
	-- It runs inside Build, once, against the player's REAL teleports -- and
	-- travelMinutes reads that cache before it ever consults the overridden
	-- TP.TravelMinutes. So swapping the teleport layer changed only the slow
	-- fallback, every profile replayed the same cached costs, and "no teleports
	-- at all (fresh character)" routed via a Cloak of Coordination it does not
	-- own. All four profiles reported an identical 33 minutes, which is how the
	-- bug hid: the monotonicity invariant compared four copies of one answer and
	-- passed every time.
	--
	-- Recomputing it here costs one pass over the route and is the only way the
	-- profile reaches the decision. Recomputed again on the way out so the
	-- player's real session does not keep the last profile's impoverished list.
	local R = MM.Router
	if R and R.PrecomputeTravel and R.route then R.PrecomputeTravel(R.route) end

	local ok, err = pcall(fn)
	TP.Options, TP.Landings, TP.Refresh = realOptions, realLandings, realRefresh
	TP.TravelMinutes = realTravel

	if MM.Journey and MM.Journey.Forget then MM.Journey.Forget() end
	if R and R.PrecomputeTravel and R.route then R.PrecomputeTravel(R.route) end
	if not ok then error(err, 0) end
	return #allowed
end

-- Everything we want to say about one (sample, profile) pair.
local function observe(sample)
	local R = MM.Router
	local obs = { stops = {}, minutes = 0, travel = 0, teleports = 0, goals = 0 }
	local m = R.Measure and R.Measure() or nil
	obs.minutes = (m and m.minutes) or 0
	-- Travel is the number the invariant tests. Total minutes also includes
	-- grind time, which no teleport can shorten, so comparing totals would let
	-- a real regression hide behind a big constant.
	obs.travel = (m and m.travelMinutes) or 0

	for i, stop in ipairs(R.route or {}) do
		local rec = stop.rec
		local need, have = RM.Precision(rec)
		local members = stop.members or { stop }
		obs.goals = obs.goals + #members
		if stop.arriveBy then obs.teleports = obs.teleports + 1 end
		obs.stops[#obs.stops + 1] = {
			order = i,
			excuse = MM.Router.PositionlessExcuse(stop),
			approxFrom = stop.approxFrom,
			name = (rec and rec.name) or stop.label or "?",
			category = rec and rec.category or "?",
			-- WHERE, not what. stop.label is the mount's name, which reads as
			-- "travel to Cartel Master's Gearglider" -- a destination that does
			-- not exist. The zone only surfaced when stops happened to group.
			place = (rec and rec.zone and rec.zone.name)
				or (rec and rec.instance and rec.instance.name)
				or stop.unmappedZone or stop.label or "(unnamed)",
			mounts = #members,
			world = stop.world and true or false,
			coords = (have >= 2),
			need = need,
			arrive = stop.arriveBy and (stop.arriveBy.name or stop.arriveBy.key) or "fly",
			travel = stop.travelMinutes or 0,
			-- The OTHER half of the cost: what the goal itself takes once you
			-- are standing there. A dungeon clear times the expected number of
			-- attempts, a reputation grind, a currency total. Travel alone
			-- makes a 3-minute flight to a 40-hour rep look cheap.
			work = stop.workMinutes or 0,
			access = rec and rec.access or nil,
		}
	end
	obs.unrouted = #(R.unrouted or {})
	obs.deferred = #(R.deferred or {})
	obs.sampled  = #sample
	return obs
end

-- Invariants. These are the point: they hold for every correct route no matter
-- what the player owns, so a violation is a router bug rather than an opinion
-- about which order is nicer.
local function checkInvariants(results, sample)
	local fails = {}
	local function fail(s, ...) fails[#fails + 1] = s:format(...) end

	for _, r in ipairs(results) do
		local o = r.obs
		-- 1. Nothing may vanish. NOT plus unrouted: the unrouted list is
		--    already inside R.route, so adding it double-counts exactly the
		--    goals it exists to reconcile.
		local accounted = o.goals + o.deferred
		if accounted < o.sampled then
			fail("[%s] %d of %d goals vanished (routed %d + deferred %d + unrouted %d)",
				r.profile.key, o.sampled - accounted, o.sampled, o.goals, o.deferred, o.unrouted)
		end
		-- 2. A routed stop the player cannot be sent to is worse than no stop --
		--    UNLESS the router said so deliberately. Queued goals and zones
		--    this client cannot map yet are features, and reporting them as
		--    failures is how this check cried wolf 32 times on its first run.
		for _, st in ipairs(o.stops) do
			if not st.world and not st.excuse then
				fail("[%s] stop %d %s has no world position and no reason given",
					r.profile.key, st.order, st.name)
			end
		end
	end

	-- 3. Capability may not make things worse. A teleport can only ever remove
	--    travel time, never add it, so travel must not rise as the profile
	--    grows. If it does, the router is not using what it has been given --
	--    which is the single most valuable thing this harness can catch,
	--    because it is invisible from inside any one route.
	-- A PROFILE THAT OWNS NOTHING MUST USE NOTHING.
	--
	-- This is the assertion that should have existed first, because it needs no
	-- comparison between profiles and cannot be satisfied by accident: a
	-- character with zero landings has no teleport to take. When the per-stop
	-- cost cache survived the capability swap, "no teleports at all" happily
	-- reported two teleport legs and every other check still passed.
	for _, r in ipairs(results) do
		if r.landings == 0 and r.obs.teleports > 0 then
			fail("[%s] owns 0 teleports and still took %d teleport leg(s) -- "
				.. "the capability filter is not reaching the routing decision",
				r.profile.key, r.obs.teleports)
		end
	end

	-- "Exercised" means THE PROFILES DIFFERED, not that some teleport was used.
	--
	-- The old test asked whether any profile used a teleport, which was true
	-- even while the bug made all four identical -- so it printed the confident
	-- line about monotonicity holding, over four copies of a single answer.
	-- Four equal numbers are one measurement, and one measurement cannot
	-- demonstrate a trend.
	local usedAny, first = false, results[1]
	for i = 2, #results do
		local prev, cur = results[i - 1], results[i]
		if first and (cur.obs.travel ~= first.obs.travel
			or cur.obs.teleports ~= first.obs.teleports) then usedAny = true end
		if cur.obs.travel > prev.obs.travel + 0.5 then
			fail("[%s] travel got LONGER than [%s] despite more teleports: %.0f -> %.0f min",
				cur.profile.key, prev.profile.key, prev.obs.travel, cur.obs.travel)
		end
	end
	return fails, usedAny
end

function RM.Run(n)
	local sample, eligible = RM.Sample(n)
	local asked = n
	if #sample == 0 then
		MM:Print("Nothing to model — no uncollected high-risk goals found.")
		return nil
	end
	local entries = {}
	for _, c in ipairs(sample) do entries[#entries + 1] = c.entry end

	local results = {}
	withPlan(entries, function()
		for _, profile in ipairs(PROFILES) do
			local count = withProfile(profile, function()
				MM.Router:Build()
			end)
			results[#results + 1] = {
				profile = profile, landings = count or 0, obs = observe(sample),
			}
		end
	end)
	-- Leave the player looking at their own route, not the model's.
	MM.Router:Build()
	local fails, exercised = checkInvariants(results, sample)
	return { sample = sample, results = results, fails = fails, exercised = exercised,
		asked = asked, eligible = eligible }
end

------------------------------------------------------------
-- Reporting
------------------------------------------------------------
-- Built to be pasted at a human. The machine can prove the route is coherent;
-- only a player can say whether the coordinate is the right patch of ground,
-- so every destination is printed even when nothing failed.
local function riskWord(risk)
	if risk >= 3 then return "CRITICAL" elseif risk == 2 then return "HIGH"
	elseif risk == 1 then return "MED" end
	return "ok"
end

function RM.Format(run)
	local L = {}
	local function w(s, ...) L[#L + 1] = select("#", ...) > 0 and s:format(...) or s end

	w("# Master Mounts router model")
	w("")
	-- SAY WHAT WAS ASKED FOR AND WHAT WAS AVAILABLE.
	--
	-- `/mm routertest 300` returning 20 goals looks like a truncation bug. It is
	-- not: only goals with a ROUTING RISK are worth modelling, and once the data
	-- is good most goals have none. Asking for 300 cannot conjure 300 problems.
	--
	-- Silently ignoring the number is what made it look broken, so the number
	-- asked for, the number eligible and the number taken are all stated.
	if run.asked then
		w("## Goals chosen (highest routing risk first)")
		w("   %d of %d eligible%s. Only goals with a routing RISK are modelled --",
			#run.sample, run.eligible or #run.sample,
			run.asked > (run.eligible or 0)
				and (", asked for " .. run.asked) or "")
		w("   a goal the router places correctly has nothing to test.")
	else
		w("## Goals chosen (highest routing risk first)")
	end
	for i, c in ipairs(run.sample) do
		w("%2d. %-34s [%s] %s — %s", i, c.entry.name, c.rec.category or "?",
			riskWord(c.risk), c.why)
	end

	w("")
	w("## Per capability profile")
	for _, r in ipairs(run.results) do
		local o = r.obs
		w("")
		w("### %s (%s) — %d teleport(s) available", r.profile.key, r.profile.label, r.landings)
		w("    %d stops · %d goals · travel %.0f min · total %.0f min · %d leg(s) by teleport",
			#o.stops, o.goals, o.travel, o.minutes, o.teleports)
		if o.deferred > 0 or o.unrouted > 0 then
			w("    deferred %d · unrouted %d", o.deferred, o.unrouted)
		end
		for _, st in ipairs(o.stops) do
			local note = ""
			if not st.world then
				note = st.excuse and ("<< no position: " .. st.excuse)
					or "<< NO POSITION, and no reason given"
			elseif st.approxFrom then
				note = "<< via flight point " .. st.approxFrom
			elseif not st.coords then
				note = "<< zone centre only, no x/y"
			end
			w("    %2d. %-30s -> %-26s %s", st.order, st.name, st.place, note)
			-- travel + work = total, stated rather than implied. The two are
			-- different kinds of cost and the router weighs them differently;
			-- showing only travel hid the number that usually dominates.
			w("        arrive: %-22s travel %.0f + do %s = %s%s",
				st.arrive, st.travel,
				st.work > 0 and ("%.0f"):format(st.work) or "?",
				st.work > 0 and (MM.Util.FormatSeconds((st.travel + st.work) * 60))
					or ("%.0f min"):format(st.travel),
				st.mounts > 1 and (" · %d mounts here"):format(st.mounts) or "")
			if st.access then w("        access: %s", st.access) end
		end
	end

	w("")
	if #run.fails == 0 then
		w("## Invariants: all passed")
		w("   - every goal accounted for (routed, deferred or unrouted)")
		w("   - every routed stop has a world position, or a stated reason")
		if run.exercised then
			w("   - travel time never increased as teleports were added")
		else
			-- A pass that could not have failed is not evidence. Say so, or the
			-- report claims the router handles capability correctly when in
			-- fact nothing in this sample ever consulted a teleport.
			w("   - travel monotonicity: |cffff9a3cNOT EXERCISED|r — every profile")
			w("     returned the same travel and the same teleport count, so there")
			w("     is only one measurement here and it cannot show a trend. Either")
			w("     no leg on this sample can use a teleport, or capability is not")
			w("     reaching the routing decision. Re-run with a larger n, or from a")
			w("     continent your teleports actually land on.")
		end
	else
		w("## Invariants: %d FAILED", #run.fails)
		for _, f in ipairs(run.fails) do w("   !! %s", f) end
	end
	return table.concat(L, "\n")
end

-- Both commands open the copyable window. Printing this to chat was a
-- mistake: it is hundreds of lines, chat truncates and reflows it, and the
-- entire point of the report is that a human can paste it somewhere and read
-- the destinations. A report you cannot copy is a report nobody checks.
-- TRAVEL DATA INTEGRATION REPORT.
--
-- "Is it working" is three separate questions and they fail differently:
--   1. did the data load           -- a missing .toc line loads nothing, silently
--   2. is it reachable             -- a hop with no name mapping is inert
--   3. is it actually being USED   -- a dataset can be loaded, valid, and never
--                                     consulted, which looks identical to
--                                     working from the outside
--
-- The third is the one that matters and the one nobody checks, so this prices
-- real legs from the current route and reports which method won each. If the
-- network never wins anywhere, it is decorative.
function RM.TravelReport()
	local L = {}
	local function w(f, ...) L[#L + 1] = select("#", ...) > 0 and f:format(...) or f end

	w("----- TRAVEL DATA -----")

	-- 1. loaded?
	local fs = MM.FlightSeconds
	if not fs then
		w("  |cffff4444Measured flight times: NOT LOADED|r")
	else
		local nodes, hops = 0, 0
		for _, nb in pairs(fs) do
			nodes = nodes + 1
			for _ in pairs(nb) do hops = hops + 1 end
		end
		-- 2. reachable?
		local named, projected = MM.FlightNodeName, 0
		if named then
			for id, nb in pairs(fs) do
				if named[id] then
					for oid in pairs(nb) do if named[oid] then projected = projected + 1 end end
				end
			end
		end
		w("  Flight times   %d nodes, %d measured hops, %d projected (%.1f%%)",
			nodes, hops, projected, hops > 0 and (projected / hops * 100) or 0)
		-- Loaded is not the same as WIRED. This says how many of those hops the
		-- route planner actually took as edges -- the number that was silently
		-- zero while everything else read healthy.
		local wired = MM.Journey and MM.Journey.measuredEdges
		if wired then
			w("     %d fed into the route planner%s", wired,
				wired == 0 and " |cffff4444 -- loaded but NOT WIRED|r" or "")
		end
		if projected < hops then
			w("     |cffff4444%d hops have no name mapping and cannot be routed|r",
				hops - projected)
		end
	end

	local tn, te = MM.TravelNodes, MM.TravelEdges
	if not (tn and te) then
		w("  |cffff4444Travel network: NOT LOADED|r")
	else
		-- FORCE THE LAZY BUILD FIRST.
		--
		-- autoEdges is set at the END of Network.build(), and build() only runs
		-- when something routes. Reading the counter before that reported "0
		-- generated" for a graph that had simply not been built yet -- a
		-- diagnostic describing a state its own act of measuring had not
		-- reached. Coverage() triggers the build, so ask it before reporting.
		if MM.Network and MM.Network.Coverage then MM.Network.Coverage() end
		local n, byMethod, zero = 0, {}, 0
		for _ in pairs(tn) do n = n + 1 end
		for _, e in ipairs(te) do
			byMethod[e.method] = (byMethod[e.method] or 0) + 1
			local s = MM.Network and MM.Network.EdgeSeconds and MM.Network.EdgeSeconds(e)
			if not s or s <= 0 then zero = zero + 1 end
		end
		local parts = {}
		for m, c in pairs(byMethod) do parts[#parts + 1] = ("%s %d"):format(m, c) end
		table.sort(parts)
		w("  Travel network %d endpoints, %d recorded + %d generated connections",
			n, #te, (MM.Network and MM.Network.autoEdges) or 0)
		w("     %s", table.concat(parts, " · "))
		if zero > 0 then
			w("     |cffff4444%d edges priced at ZERO -- free teleportation|r", zero)
		end
	end

	-- 3. actually used? price real legs three ways and show the winner.
	local R = MM.Router
	if not (R and R.route and #R.route > 1) then
		w("  (no route built -- run /mm route to compare live legs)")
		return table.concat(L, "\n")
	end

	w("")
	w("  Live legs, priced every way. WON marks what the router will use:")
	local U, ypm = MM.Util, MM.YARDS_PER_MINUTE or 1500
	local wins = { flight = 0, network = 0, direct = 0 }
	local shown = 0
	for i = 1, math.min(#R.route - 1, 8) do
		local a, b = R.route[i], R.route[i + 1]
		if a and b and a.mapID and b.mapID then
			local direct
			if U and a.world and b.world then
				local d = U.WorldDistance(a.world, b.world)
				direct = d and (d / ypm)
			end
			-- An instanced goal is reached by its DOOR, so the instance name has
			-- to travel with the query or both datasets look at an interior map
			-- with no flight points and correctly find nothing.
			local aInst = a.rec and a.rec.instance and a.rec.instance.name
			local bInst = b.rec and b.rec.instance and b.rec.instance.name
			local taxi = MM.Taxi and MM.Taxi.TravelMinutes
				and MM.Taxi.TravelMinutes(a.mapID, a.x, a.y, b.mapID, b.x, b.y, true,
					bInst, aInst)
			local net, netWhy
			if MM.Network and MM.Network.TravelMinutes then
				net, netWhy = MM.Network.TravelMinutes(a.mapID, a.x, a.y,
					b.mapID, b.x, b.y, bInst, aInst)
			end
			local best, who = direct, "direct"
			if taxi and (not best or taxi < best) then best, who = taxi, "flight" end
			if net and (not best or net < best) then best, who = net, "network" end
			if best then
				wins[who] = (wins[who] or 0) + 1
				shown = shown + 1
				w("   %-24s map %-5s direct %s · taxi %s · network %s -> |cff40d860%s|r",
					((a.label or (a.entry and a.entry.name) or "?"):sub(1, 24)),
					tostring(a.mapID),
					direct and ("%.1fm"):format(direct) or "  -  ",
					taxi and ("%.1fm"):format(taxi) or "  -  ",
					net and ("%.1fm"):format(net) or "  -  ", who)
				-- Why the network declined, when it did. Four different causes
				-- need four different fixes and "-" distinguishes none of them.
				if not net and netWhy then w("      network: %s", netWhy) end
			end
		end
	end
	if shown == 0 then
		w("   (no comparable legs -- stops lack coordinates)")
	else
		w("")
		w("  Winner across %d legs: direct %d · taxi %d · network %d",
			shown, wins.direct or 0, wins.flight or 0, wins.network or 0)
		if (wins.network or 0) == 0 and (wins.flight or 0) == 0 then
			w("  |cffff9a3cNeither dataset won a leg here. That is possible on a")
			w("  short local route, and suspicious on a long one.|r")
		end
	end
	return table.concat(L, "\n")
end

local function show(n)
	local run = RM.Run(n)
	if not run then return end
	-- The travel report leads: it answers "is the data even reaching the
	-- router" before the invariants answer "does the router behave".
	local text = RM.TravelReport() .. "\n\n" .. RM.Format(run)
	if MM.Diagnostics and MM.Diagnostics.ShowExport then
		MM.Diagnostics.ShowExport(text, "Router model")
	else
		for _, line in ipairs({ strsplit("\n", text) }) do MM:Print(line) end
	end
	if #run.fails > 0 then
		MM:Print("|cffff5555Router model: %d invariant failure(s)|r — see the window.", #run.fails)
	else
		MM:Print("Router model: all invariants passed across %d profiles.", #run.results)
	end
end

MM:On("MM_ROUTERTEST", function(arg)
	MM:Print("Modelling the router...")
	show(tonumber(arg) or 12)
end)

MM:On("MM_ROUTERTEST_EXPORT", function(arg) show(tonumber(arg) or 12) end)
