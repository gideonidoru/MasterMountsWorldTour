-- Master Mounts: session mode.
--
-- "we have forty-five minutes. What should I do?"
--
-- That is the question a collector actually asks, and until now the addon could
-- only answer a different one: "here is everything, in a good order, and it
-- will take you twenty days." Session length existed as a WEIGHT -- a slider
-- that leaned the ranking toward shorter work -- which is not the same thing at
-- all. A lean is not a promise. Forty-five minutes is a promise.
--
-- So this is a mode, not a dial:
--
--   * you name a length
--   * the plan is CUT to what genuinely fits it, using the same whole-plan
--     clock the router already uses -- never a different estimate, or the
--     addon would be promising one thing and routing another
--   * it counts down while you play, and says where you actually are against
--     the plan rather than where it hoped you would be
--
-- Everything here is assembly. `sessionFit`, `RouteMinutes` and the Monitor HUD
-- all existed; what was missing was somebody drawing a line and saying "these
-- eight things, this hour".
local _, MM = ...

MM.Session = {}
local S = MM.Session
local U = MM.Util

-- Presets a person actually thinks in. "A dungeon" and "an evening" are how
-- players describe time to each other; 47 minutes is not.
S.LENGTHS = {
	{ minutes = 20,  label = "20 minutes",  blurb = "A queue's worth" },
	{ minutes = 45,  label = "45 minutes",  blurb = "A dungeon and a bit" },
	{ minutes = 90,  label = "90 minutes",  blurb = "A proper sitting" },
	{ minutes = 180, label = "3 hours",     blurb = "An evening" },
}

------------------------------------------------------------
-- State
------------------------------------------------------------
-- Lives on the CHARACTER, not the account: a session is a thing you are doing
-- right now, and it should not follow you to a different character mid-run.
local function state()
	MM.cdb.session = MM.cdb.session or {}
	return MM.cdb.session
end

function S.Active()
	local st = state()
	if not st.startedAt then return nil end
	return st
end

function S.Remaining()
	local st = S.Active()
	if not st then return nil end
	local elapsed = (GetTime() - st.startedAt) / 60
	return math.max(0, (st.minutes or 0) - elapsed), elapsed
end

------------------------------------------------------------
-- Cutting the plan to fit
------------------------------------------------------------
-- Picks the best set of stops that genuinely fit the budget, starting from
-- where the player is standing.
--
-- The first version walked the router's route in order and took whatever fitted.
-- That answers a different question, and the diagnostic said so plainly:
--
--     20  min ->  1 stops, ~0.05 mounts
--     45  min ->  1 stops, ~0.01 mounts     <- more time, FEWER mounts
--     90  min ->  2 stops, ~2.00 mounts
--     180 min ->  2 stops, ~0.03 mounts     <- three hours buys two stops
--
-- The route is ordered for a twenty-day campaign; its first stop alone costs
-- 2h08m. First-fitting down it means a session gets whatever happens to be
-- small, in an arbitrary order, and more time can genuinely buy less.
--
-- So this selects rather than truncates: repeatedly take the stop with the best
-- score FROM WHERE YOU NOW ARE, among those that still fit. Same scoring the
-- router uses, so weights and priorities still apply -- but the travel is
-- measured from the player, and nothing is chosen that cannot be finished.
--
-- Returns: stops, mounts expected, minutes used.
function S.Fit(minutes)
	local R = MM.Router
	if not (R and R.route and R.Density) then return {}, 0, 0 end
	minutes = minutes or (state().minutes or 60)

	local pool = {}
	for i, stop in ipairs(R.route) do pool[i] = stop end

	local chosen, mounts, used = {}, 0, 0
	local continent, world = U.PlayerWorldPos()

	while #pool > 0 do
		local bestIdx, bestScore, bestCost, bestTravel, bestPref
		for i, stop in ipairs(pool) do
			local travel = 0
			if MM.Teleports and MM.Teleports.TravelMinutes and stop.world then
				travel = MM.Teleports.TravelMinutes(continent, world,
					stop.continent, stop.world) or 0
			end
			-- WHAT IT TAKES TO DO IT, NOT WHAT IT TAKES TO GET IT.
			--
			-- stop.workMinutes is EffortMinutes -- visit x expected attempts,
			-- the whole grind. That is the right number for "should I spend my
			-- evening on this" and the wrong one for "what fits in three
			-- hours": an island run is fifteen minutes whether the mount lands
			-- on the first try or the two hundredth, but priced as the whole
			-- grind it costs twenty-five hours and nothing fits in an evening.
			-- Which is exactly what happened -- three hours admitted one goal.
			--
			-- Planner already draws this distinction and says so in as many
			-- words; the session was simply asking the wrong one of the two.
			--
			-- Taken as the MAX across everything at the stop, not the sum: one
			-- island run is one island run however many mounts can drop from it.
			local work
			local VM = MM.Planner and MM.Planner.VisitMinutes
			if VM then
				if stop.entry then work = VM(stop.entry) end
				for _, m in ipairs(stop.members or {}) do
					local v = m.entry and VM(m.entry)
					if v and (not work or v > work) then work = v end
				end
			end
			work = work or stop.workMinutes or 15
			local cost = travel + work
			-- Only things that actually fit in what is left. A session is a
			-- promise, and half a raid is not a mount.
			if used + cost <= minutes then
				-- MOUNTS PER MINUTE, not the router's selection score.
				--
				-- The selection score goes lexicographic above priority 1.45,
				-- so a rank-1 goal beats a rank-8 goal outright whatever it
				-- yields. In a session that inverted the whole point: at 20
				-- minutes the budget could only fit a 1.0-mount goal, at 45 it
				-- could fit a higher-PRIORITY goal worth 0.01, and more time
				-- bought fewer mounts.
				--
				-- Preference decides what is IN the plan. A session is the one
				-- place where the question really is "what collects the most in
				-- the time we have", so it is answered honestly and preference
				-- only breaks ties.
				local density = R.Density(stop, travel, work)
				if not bestIdx or density > bestScore + 1e-12
					or (density > bestScore - 1e-12
						and (stop.layerPreference or math.huge) < bestPref) then
					bestIdx, bestScore, bestCost, bestTravel = i, density, cost, travel
					bestPref = stop.layerPreference or math.huge
				end
			end
		end
		if not bestIdx then break end

		local stop = tremove(pool, bestIdx)
		chosen[#chosen + 1] = { stop = stop, travel = bestTravel, at = used }
		used = used + bestCost
		mounts = mounts + (stop.mounts or 0)
		continent = stop.continent or continent
		world = stop.world or world
	end
	return chosen, mounts, used
end

------------------------------------------------------------
-- Start / stop
------------------------------------------------------------
-- setOnly: choose a length WITHOUT launching the route.
--
-- The Planner's picker is a setting, not a go button. Starting a session from
-- it flipped routeActive and threw the goal window on screen before the player
-- had pressed Start Route -- a dropdown that hijacks the UI is not a dropdown.
-- /mm session 45 still means "go now", because there the verb is explicit.
function S.Start(minutes, setOnly)
	local st = state()
	st.minutes = minutes or 60
	st.startedAt = GetTime()
	st.collectedAtStart = MM.Scanner and MM.Scanner.collectedCount or 0

	local chosen, mounts, used = S.Fit(st.minutes)
	st.planned = #chosen
	st.plannedMounts = mounts
	st.plannedMinutes = used

	-- ACTUALLY REORDER THE ROUTE, do not just count.
	--
	-- Fit works out which stops fit in the time, and this used to keep only
	-- #chosen and throw the list away -- so the addon announced "45 minutes:
	-- 2 stops" and then walked you through all 106 in the ordinary order. The
	-- promise was printed, never kept.
	--
	-- Reordered, not truncated: the chosen stops move to the front in Fit's
	-- order, and everything else follows untouched. Nothing is lost, so ending
	-- the session or running over just continues into the rest of the plan,
	-- and the session boundary is a position rather than a deletion.
	-- The REORDER LIVES IN Build(), not here.
	--
	-- Doing it here reordered the route and then fired MM_SESSION_CHANGED, whose
	-- listener refreshes the Planner, which calls Router:Build(), which rebuilds
	-- the route from scratch and threw the ordering away microseconds later. The
	-- self-test caught it: "stop 1 of the session is not at route position 1".
	--
	-- Anything that only survives until the next rebuild is not a property of
	-- the route. Build() applies it as its final step, so every rebuild -- from
	-- a UI refresh, a plan change, a reload -- produces a route that already
	-- honours the session.
	if MM.Router and MM.Router.ApplySession then MM.Router.ApplySession() end

	-- Only take over the route if one is already running, or if the caller
	-- actually asked to start.
	if not setOnly then
		MM.cdb.routeActive = true
		MM.cdb.routeIndex = 1
	elseif MM.cdb.routeActive then
		MM.cdb.routeIndex = 1
	end
	MM:Fire("MM_SESSION_CHANGED")

	if #chosen == 0 then
		-- Worth saying even from the UI: an empty plan looks like a broken
		-- picker, and the reason is not visible anywhere on screen.
		MM:Print("|cffff9a3cNothing in your plan fits %d minutes.|r "
			.. "Everything reachable needs longer than that right now.", st.minutes)
		return false
	end
	-- SILENT WHEN SET FROM THE UI.
	--
	-- The dropdown already reads "45 minutes" and the plan list already shows
	-- only what fits. Printing two more lines into chat every time the picker
	-- moves narrates something the player is looking at, and a control people
	-- adjust a few times in a row turns that into a wall.
	--
	-- /mm session 45 still reports, because there chat IS the interface and
	-- silence would look like nothing happened.
	if not setOnly then
		MM:Print("|cff40d860Session started: %d minutes.|r %d stops, ~%.1f mounts "
			.. "expected, %s of work planned.", st.minutes, #chosen, mounts,
			U.FormatSeconds(used * 60))
		MM:Print("   %s", S.NextLine() or "")
	end
	-- Same reasoning as a route: a session is a mode where the next stop is
	-- the thing you want on screen.
	if not setOnly and MM.UI and MM.UI.ShowMonitor then pcall(MM.UI.ShowMonitor) end
	return true
end

function S.Stop(quiet)
	local st = state()
	if not st.startedAt then return end
	local gained = (MM.Scanner and MM.Scanner.collectedCount or 0)
		- (st.collectedAtStart or 0)
	local _, elapsed = S.Remaining()
	st.startedAt = nil
	MM:Fire("MM_SESSION_CHANGED")
	if quiet then return end
	MM:Print("Session ended after %s. |cffffd24d%d mount%s|r collected "
		.. "(expected about %.1f).", U.FormatSeconds((elapsed or 0) * 60),
		gained, gained == 1 and "" or "s", st.plannedMounts or 0)
end

------------------------------------------------------------
-- Where you actually are
------------------------------------------------------------
-- Pace, honestly. The comparison is against the plan's OWN estimate, so if the
-- estimate was optimistic this says so rather than blaming the player.
function S.Pace()
	local st = S.Active()
	if not st then return nil end
	local remaining, elapsed = S.Remaining()
	local done = math.max(0, (MM.cdb.routeIndex or 1) - 1)
	local planned = st.planned or 0
	if planned == 0 then return remaining, done, 0, "no plan" end

	-- Where the plan expected you to be by now.
	local expectedFraction = (st.minutes or 1) > 0 and (elapsed / st.minutes) or 0
	local expectedDone = expectedFraction * planned
	local delta = done - expectedDone

	local text
	if remaining <= 0 then
		text = ("Time is up — %d of %d stops done"):format(done, planned)
	elseif delta >= 1 then
		text = ("%s left — %d ahead of plan"):format(
			U.FormatSeconds(remaining * 60), math.floor(delta))
	elseif delta <= -1 then
		text = ("%s left — %d behind plan"):format(
			U.FormatSeconds(remaining * 60), math.floor(-delta))
	else
		text = ("%s left — on pace (%d of %d)"):format(
			U.FormatSeconds(remaining * 60), done, planned)
	end
	return remaining, done, planned, text
end

function S.NextLine()
	local R = MM.Router
	local cur = R and R.Current and R:Current()
	if not cur then return nil end
	local _, _, _, pace = S.Pace()
	return ("Next: %s%s"):format(cur.label or "?", pace and ("  ·  " .. pace) or "")
end

-- The session ends itself, once, rather than nagging.
local ticker
local function tick()
	local st = S.Active()
	if not st then return end
	local remaining = S.Remaining()
	if remaining and remaining <= 0 then
		MM:Print("|cffffd24dYour %d minutes are up.|r %s", st.minutes,
			select(4, S.Pace()) or "")
		S.Stop()
	end
end

MM:On("MM_SESSION_CHANGED", function()
	if ticker then ticker:Cancel(); ticker = nil end
	if S.Active() then ticker = C_Timer.NewTicker(20, tick) end
end)
MM:On("MM_LOGIN", function()
	-- A session cannot survive a logout: GetTime resets, so the clock would be
	-- meaningless and the player would be told they had hours left.
	local st = state()
	if st.startedAt then st.startedAt = nil end
end)

------------------------------------------------------------
-- Commands
------------------------------------------------------------
MM:On("MM_SESSION", function(arg)
	if arg == "stop" then return S.Stop() end
	local minutes = tonumber(arg)
	if minutes then return S.Start(minutes) end

	local st = S.Active()
	if st then
		local _, _, _, pace = S.Pace()
		MM:Print("Session: %s", pace or "running")
		MM:Print("   %s", S.NextLine() or "nothing next")
		MM:Print("   /mm session stop ends it.")
		return
	end
	MM:Print("No session running. Pick a length:")
	for _, len in ipairs(S.LENGTHS) do
		local chosen, mounts = S.Fit(len.minutes)
		MM:Print("   |cffffd24d/mm session %d|r — %s: %d stops, ~%.1f mounts",
			len.minutes, len.blurb, #chosen, mounts)
	end
end)

MM:On("MM_SESSION_DEBUG", function()
	local st = S.Active()
	if not st then
		MM:Print("No session running.")
	else
		local remaining, done, planned, pace = S.Pace()
		MM:Print("Session: %d min, started, %s", st.minutes, pace or "?")
		MM:Print("   %d of %d stops done, %.1f min left, ~%.1f mounts expected",
			done, planned, remaining or 0, st.plannedMounts or 0)
	end
	-- What each length would actually buy, which is the number that makes the
	-- feature worth having.
	for _, len in ipairs(S.LENGTHS) do
		local chosen, mounts, used = S.Fit(len.minutes)
		MM:Print("   %-4d min -> %2d stops, ~%.2f mounts, %.0f min of work",
			len.minutes, #chosen, mounts, used)
	end
end)
