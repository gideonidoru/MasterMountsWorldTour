-- Master Mounts: the scorecard.
--
-- Requirement — implement a full 100/100 diagnostic to push us to the end.
--
-- Every other diagnostic answers one question. This one answers "how good is
-- this, really" — and it has to answer honestly or it is worse than useless,
-- because a scorecard that always reads 100 is a decoration.
--
-- Three rules it holds to:
--
--   MEASURED, NEVER ASSERTED. Every point is computed from live state. Nothing
--     is hardcoded, so the number moves when the addon does. A dimension that
--     cannot be measured on this client scores nil and says so, rather than
--     quietly awarding itself full marks.
--
--   THE DENOMINATOR IS WHAT IS ACHIEVABLE. 185 conditions name an item or a
--     quest with no id, and WoW exposes no reverse name→id lookup for either.
--     Scoring those as failures would peg the addon below 100 forever for a
--     platform limitation, which trains everyone to ignore the number. They
--     are excluded from the denominator and reported separately, by name.
--
--   EVERY LOST POINT NAMES ITS BLOCKER. "Data 14/20" is a grade. "Data 14/20 —
--     327 locations missing, /mm contribute exports them" is a next action.
--     Only one of those is worth printing.
local _, MM = ...

MM.Score = {}
local S = MM.Score
local U = MM.Util

------------------------------------------------------------
-- Dimensions
------------------------------------------------------------
-- Weights reflect what would actually make this addon worse if it regressed.
-- Correctness dominates: a fast, well-documented addon that routes you
-- somewhere useless is worthless, and no amount of polish redeems it.
local DIMENSIONS = {
	{
		key = "correctness", label = "Correctness", weight = 30,
		-- Self-tests are the contract. A single failure is not a rounding
		-- error, it is a promise the addon is currently breaking.
		measure = function()
			local t = MM.Tests and MM.Tests.lastRun
			if not t then return nil, "self-test has not run yet" end
			local total = (t.passed or 0) + (t.failed or 0)
			if total == 0 then return nil, "no checks ran" end
			local frac = (t.passed or 0) / total
			local why
			if (t.failed or 0) > 0 then
				why = ("%d self-test failure%s — these are promises being broken")
					:format(t.failed, t.failed == 1 and "" or "s")
			elseif (t.degraded or 0) > 0 then
				why = ("%d degraded — optional features this client lacks, not defects")
					:format(t.degraded)
			end
			return frac, why
		end,
	},
	{
		key = "integrity", label = "Build integrity", weight = 10,
		-- Every planned goal must be accounted for, and the route must not
		-- contain a stop it cannot send anyone to.
		--
		-- BOTH HALVES OF THIS WERE WRONG ON THE FIRST LIVE RUN, and the way they
		-- were wrong is worth keeping written down, because a scorecard that
		-- invents a blocker is worse than no scorecard.
		--
		--   A STOP IS NOT A GOAL. 23 stops on the route carry more than one
		--     mount; one carries eight. Reconciling #route against the plan
		--     "found" 23 missing goals that were sitting in `members` the whole
		--     time. The router's own check uses members and passes. This is the
		--     same stops-vs-mounts error that once made a test pass on broken
		--     code, made twice.
		--
		--   NO POSITION CAN BE CORRECT. Router.lua deliberately appends the
		--     no-location goals into the route flagged `noLocation`, so that
		--     skipping through the route cannot "finish" while they sit
		--     unvisited. Those have no world position ON PURPOSE. Only an
		--     unflagged one is a defect.
		measure = function()
			local R = MM.Router
			if not (R and R.route) then return nil, "no route built yet" end
			local bad, goals = 0, 0
			for _, stop in ipairs(R.route) do
				goals = goals + #(stop.members or { stop })
				-- `noLocation` is the router saying so deliberately. A queued
				-- goal likewise has nowhere to point — that IS the feature.
				local excused = MM.Router.PositionlessExcuse(stop)
				if not stop.world and not excused then bad = bad + 1 end
			end
			local plan = MM.Planner and #MM.Planner:GetPlan() or 0
			-- The unrouted list is ALREADY inside R.route; adding it again would
			-- double-count exactly the goals it is meant to reconcile.
			local lost = math.max(0, plan - (goals + #(R.deferred or {})))
			if bad > 0 or lost > 0 then
				return 0, ("%d routed stops have no position and no reason, "
					.. "%d goals unaccounted for"):format(bad, lost)
			end
			return 1
		end,
	},
	{
		key = "performance", label = "Performance", weight = 10,
		-- a live client froze on /mm diag. A number here is the difference
		-- between noticing that in a test and noticing it in the game.
		measure = function()
			local ms = MM.Router and MM.Router.lastBuildMs
			if not ms then return nil, "no route build timed yet" end
			-- 150ms is comfortable, 600ms is the edge of noticeable.
			if ms <= 150 then return 1 end
			if ms >= 600 then
				return 0, ("route takes %.0f ms to build — long enough to feel"):format(ms)
			end
			return 1 - (ms - 150) / 450,
				("route takes %.0f ms; under 150 is imperceptible"):format(ms)
		end,
	},
	{
		key = "catalogue", label = "Catalogue coverage", weight = 10,
		-- Every mount the journal knows should have a record. A missing record
		-- is a mount the addon cannot help with at all.
		measure = function()
			local S2 = MM.Scanner
			if not (S2 and S2.byMountID) then return nil, "collection not scanned yet" end
			local total, matched = 0, 0
			for _, e in pairs(S2.byMountID) do
				total = total + 1
				if e.rec and not e.rec.stub then matched = matched + 1 end
			end
			if total == 0 then return nil, "journal empty" end
			local frac = matched / total
			return frac, matched < total
				and ("%d journal mounts have no record"):format(total - matched) or nil
		end,
	},
	{
		key = "resolution", label = "Id resolution", weight = 10,
		-- Ids that the CLIENT can supply. Items and quests are excluded from
		-- the denominator entirely: WoW has no reverse name->id lookup for
		-- either, so counting them would peg this below 100 forever.
		measure = function()
			-- A name the resolver has ALREADY searched for and not found is not
			-- "still unfilled", it is absent from this client. Counting it here
			-- told the player to run /mm resolve for points that command cannot
			-- award: it walks the 5,438-achievement index once, caches every
			-- miss so it never rebuilds, and then correctly resolves 0 forever.
			-- The scorecard was promising work that was already done.
			--
			-- Same treatment as item and quest names above -- excluded as a
			-- platform limit, and SAID so, rather than scored as a failure
			-- nobody can fix.
			local store = MM.db and MM.db.ids or {}
			local missing = store.achievementMissing or {}
			local ambiguous = store.achievementAmbiguous or {}
			local curMissing = store.currencyMissing or {}
			local facMissing = store.factionMissing or {}
			local closable, resolved, absent = 0, 0, 0
			for _, rec in pairs(MM.DBByName) do
				for _, cond in ipairs(rec.conditions or {}) do
					local t = cond.type
					if t == "ACHIEVEMENT" or t == "CURRENCY" or t == "REP" then
						local proven
						if t == "ACHIEVEMENT" and cond.name then
							proven = missing[cond.name:lower()] or ambiguous[cond.name]
						elseif t == "CURRENCY" and cond.name then
							proven = curMissing[cond.name:lower()]
						elseif t == "REP" then
							local nm = cond.factionName or cond.name
							proven = nm and facMissing[nm:lower()]
						end
						if proven and not (cond.id or cond.factionID) then
							absent = absent + 1
						else
							closable = closable + 1
							if cond.id or cond.factionID then resolved = resolved + 1 end
						end
					end
				end
			end
			if closable == 0 then return nil, "no resolvable conditions" end
			local frac = resolved / closable
			local note
			if resolved < closable then
				note = ("%d of %d client-resolvable ids still unfilled — /mm resolve")
					:format(closable - resolved, closable)
			end
			if absent > 0 then
				-- NOT a clean bill of health, and the wording must not imply one.
				--
				-- "Not in the client's index" has two causes and this cannot tell
				-- them apart: the client genuinely lacks the id, or OUR name is
				-- wrong -- a misspelling, or prose where the real achievement
				-- name was meant. The first is a platform limit. The second is a
				-- data defect a person could fix in a minute.
				--
				-- Excluding them is right, because /mm resolve provably cannot
				-- close them and telling the player otherwise wasted their time.
				-- Calling the result perfect would be wrong. So the count stays
				-- visible and says what it actually is.
				note = (note and (note .. "; ") or "")
					.. ("%d name%s matched nothing in this client — either a "
						.. "platform limit or a typo in our data; /mm contribute "
						.. "exports them"):format(absent, absent == 1 and "" or "s")
			end
			return frac, note
		end,
	},
	{
		key = "costs", label = "Cost modelling", weight = 15,
		-- What fraction of plannable goals have a cost derived from something
		-- real, rather than resting on the editorial effort rating.
		measure = function()
			local CO = MM.Contribute
			if not (CO and CO.CostCoverage) then return nil, "cost coverage unavailable" end
			local total, covered, worst, worstN = 0, 0, nil, 0
			for cat, d in pairs(CO.CostCoverage()) do
				total = total + d.total
				covered = covered + d.covered
				if #d.bare > worstN then worst, worstN = cat, #d.bare end
			end
			if total == 0 then return nil, "no plannable goals" end
			local frac = covered / total
			return frac, covered < total
				and ("%d of %d goals rest on the effort rating (worst: %s, %d)")
					:format(total - covered, total, worst or "?", worstN) or nil
		end,
	},
	{
		key = "evidence", label = "Estimate evidence", weight = 15,
		-- How much of the plan's own time estimate is MEASURED rather than a
		-- pessimistic stand-in. This is the number that most honestly says how
		-- much the addon actually knows.
		measure = function()
			local P = MM.Planner
			if not (P and P.TimeCommitment) then return nil, "planner unavailable" end
			local measured, assumed = 0, 0
			for _, entry in ipairs(P:GetPlan()) do
				local _, parts = P.TimeCommitment(entry)
				for _, part in ipairs(parts or {}) do
					if part.kind == "assumed" then assumed = assumed + part.minutes
					else measured = measured + part.minutes end
				end
			end
			local total = measured + assumed
			if total <= 0 then return nil, "nothing planned" end
			local frac = measured / total
			return frac, assumed > 0
				and ("%.0f%% of the estimate is a pessimistic stand-in — "
					.. "the ORDER is still sound, the TOTAL is an upper bound")
					:format(assumed / total * 100) or nil
		end,
	},
}

------------------------------------------------------------
-- Scoring
------------------------------------------------------------
function S.Compute()
	local rows, earned, possible, unmeasured = {}, 0, 0, 0
	for _, d in ipairs(DIMENSIONS) do
		local ok, frac, why = pcall(d.measure)
		if not ok then frac, why = nil, "measurement errored" end
		if frac == nil then
			unmeasured = unmeasured + d.weight
			rows[#rows + 1] = { d = d, frac = nil, why = why }
		else
			frac = math.max(0, math.min(1, frac))
			earned = earned + frac * d.weight
			possible = possible + d.weight
			rows[#rows + 1] = { d = d, frac = frac, why = why }
		end
	end
	local score = possible > 0 and (earned / possible * 100) or nil
	return score, rows, possible, unmeasured
end

-- Things that cannot be scored because the platform does not expose them.
-- Reported by name so nobody mistakes them for work nobody got round to.
function S.Unreachable()
	local items, quests = 0, 0
	for _, rec in pairs(MM.DBByName) do
		for _, cond in ipairs(rec.conditions or {}) do
			if cond.type == "ITEM" and not cond.itemID then items = items + 1
			elseif cond.type == "QUEST" and not cond.id then quests = quests + 1 end
		end
	end
	return items, quests
end

------------------------------------------------------------
-- Report
------------------------------------------------------------
local function bar(frac, width)
	width = width or 20
	local filled = math.floor(frac * width + 0.5)
	local colour = frac >= 0.95 and "ff40d860" or frac >= 0.75 and "ffffd84d" or "ffff9a3c"
	return ("|c%s%s|r%s"):format(colour, string.rep("=", filled),
		string.rep("-", width - filled))
end

MM:On("MM_SCORE_DEBUG", function()
	local score, rows, possible, unmeasured = S.Compute()
	if not score then
		MM:Print("Nothing measurable yet — run /mm test first.")
		return
	end

	MM:Print("|cffffd84dSCORECARD|r  every point computed from live state, none asserted")
	for _, r in ipairs(rows) do
		if r.frac == nil then
			MM:Print("   %-20s   |cff9a9a9anot measurable|r  %s",
				r.d.label, r.why or "")
		else
			MM:Print("   %-20s %s %4.1f/%d", r.d.label, bar(r.frac),
				r.frac * r.d.weight, r.d.weight)
			if r.why then MM:Print("        %s", r.why) end
		end
	end

	MM:Print(" ")
	MM:Print("   |c%s%.1f / 100|r%s",
		score >= 95 and "ff40d860" or score >= 80 and "ffffd84d" or "ffff9a3c",
		score,
		unmeasured > 0 and ("   (%d points not measurable on this client)")
			:format(unmeasured) or "")

	local items, quests = S.Unreachable()
	if items + quests > 0 then
		MM:Print(" ")
		MM:Print("   |cff9a9a9aOutside the denominator, deliberately:|r")
		MM:Print("      %d item and %d quest conditions carry no id.", items, quests)
		MM:Print("      WoW exposes NO reverse name-to-id lookup for either, from")
		MM:Print("      the client or from anywhere else. Scoring them as failures")
		MM:Print("      would peg this below 100 forever for a platform limit, and")
		MM:Print("      a number that can never be green is a number people ignore.")
	end

	-- What to do next, in the order that moves the score most.
	local todo = {}
	for _, r in ipairs(rows) do
		if r.frac and r.frac < 1 and r.why then
			todo[#todo + 1] = { gain = (1 - r.frac) * r.d.weight, why = r.why,
				label = r.d.label }
		end
	end
	table.sort(todo, function(a, b) return a.gain > b.gain end)
	if #todo > 0 then
		MM:Print(" ")
		MM:Print("   |cffffd84dBiggest gains available:|r")
		for i = 1, math.min(#todo, 3) do
			MM:Print("      +%.1f  %s", todo[i].gain, todo[i].why)
		end
	end
end)
