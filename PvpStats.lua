-- Master Mounts: your real rated win rate.
--
-- A Vicious mount costs 2,400 points and ONLY WINS PAY. So the honest cost is
-- not "40 rated battlegrounds" -- it is 40 divided by however often you
-- actually win. At 50% that is 80 matches; at 35% it is 115. The win rate is
-- not a detail of the estimate, it is most of the estimate.
--
-- The old honor API (GetPVPLifetimeStats, UnitPVPRank, GetPVPSessionStats and
-- friends) cannot answer this. Those belong to the Vanilla/TBC honor-rank
-- system, they are largely gone from retail, and even where they still respond
-- they count HONORABLE KILLS -- not matches won. Kills say nothing about
-- whether the game ended in a win, which is the only thing the bar cares about.
--
-- GetPersonalRatedInfo reports seasonPlayed and seasonWon per bracket, which is
-- exactly the ratio needed. It is called defensively here and probed in /mm,
-- because an API this specific is worth confirming on a real client rather than
-- trusting from memory.
local _, MM = ...

MM.PvpStats = {}
local PS = MM.PvpStats

-- Below this, a ratio is noise. Ten games is already a thin sample; fewer than
-- that and one lucky night would tell the planner someone is a 100% winner and
-- price a 24-hour grind as an afternoon.
local MIN_GAMES = 10

-- Brackets are scanned rather than indexed by a hardcoded constant. The index
-- for each bracket has shifted across expansions (5v5 left, solo shuffle and
-- blitz arrived), and the bracket the player ACTUALLY queues is the one whose
-- win rate describes them -- so take whichever they have played most.
local MAX_BRACKET = 10

local function rated(i)
	if C_PvP and C_PvP.GetPersonalRatedInfo then
		return C_PvP.GetPersonalRatedInfo(i)
	elseif GetPersonalRatedInfo then
		return GetPersonalRatedInfo(i)
	end
	return nil
end

-- Returns winRate, gamesPlayed, bracketIndex -- or nil when nothing is known.
function PS.Best()
	local bestPlayed, bestWon, bestIdx = 0, 0, nil
	for i = 1, MAX_BRACKET do
		local ok, _, _, _, played, won = pcall(rated, i)
		if ok and type(played) == "number" and type(won) == "number" then
			if played > bestPlayed then
				bestPlayed, bestWon, bestIdx = played, won, i
			end
		end
	end
	if bestPlayed < MIN_GAMES then return nil end
	return bestWon / bestPlayed, bestPlayed, bestIdx
end

-- The figure the planner asks for. Falls back to even odds, deliberately: with
-- no games played, assuming someone wins more than half would make every
-- Vicious mount look cheaper than it is.
function PS.WinRate()
	local rate = PS.Best()
	return rate or 0.5
end

-- How much of the 2,400-point bar is already filled, as a fraction.
--
-- Returns 0 rather than guessing. Wowhead's guide offers achievement criteria
-- 13943 (Alliance) / 13944 (Horde) for this, but a commenter reports the value
-- reading stale against their real progress, so it is NOT used here. Charging
-- someone for a full bar they are halfway through is the safe error; telling
-- them they are nearly done when they are not is the one that wastes an evening.
function PS.BarProgress()
	return 0
end
