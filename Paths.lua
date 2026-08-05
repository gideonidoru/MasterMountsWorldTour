-- Master Mounts: mounts with more than one way in.
--
-- Some mounts have several genuinely different routes. Reins of the Infinite
-- Timereaver drops from any Timewalking dungeon boss AND from the Timewalking
-- event's reward chests. Sharkbait drops from Harlan Sweete on Mythic AND from
-- the weekly Challenger's Cache. A single `source` string has to pick one and
-- lie about the rest, and whichever it picks becomes the only place the router
-- will ever send you.
--
-- WHAT A PATH CARRIES, AND WHAT IT DOES NOT. A path knows WHERE it happens and
-- WHETHER this character can take it. It deliberately does NOT carry its own
-- drop rate: odds already live in the rarity layer, verified, and a second
-- copy here would drift from it and start quietly outranking it. Selection is
-- therefore about reachability and availability -- questions a path can answer
-- honestly -- and never about numbers invented to make a path look good.
--
-- WHY THE OTHERS STAY. Taking the best path does not consume the alternatives.
-- If the Mythic run does not drop it, the weekly cache is still there this
-- week, and the plan should say so rather than silently repeating the same
-- attempt. Remaining() is what keeps the fallbacks in the player's plan.
local _, MM = ...

MM.Paths = {}
local P = MM.Paths

------------------------------------------------------------
-- Availability
------------------------------------------------------------
-- A path is available unless something concrete rules it out. Unknown is
-- treated as available on purpose: hiding a real route because we could not
-- verify a covenant is worse than offering one the player must judge.
function P.Available(path)
	if not path then return false, "no path" end
	if path.faction then
		local mine = UnitFactionGroup and UnitFactionGroup("player")
		if mine and path.faction ~= mine then
			return false, path.faction .. " only"
		end
	end
	-- Covenant and achievement are asked of the GAME, not of our own data.
	-- An earlier draft routed these through MM.Conditions helpers that do not
	-- exist, so the guard never fired and every covenant path silently read as
	-- available -- the failure mode being defended against in the first place.
	if path.covenant and C_Covenants and C_Covenants.GetActiveCovenantID then
		local mine = C_Covenants.GetActiveCovenantID()
		if mine and mine > 0 and mine ~= path.covenant then
			return false, "another covenant"
		end
	end
	if path.requiresAchievement and GetAchievementInfo then
		local _, _, _, done = GetAchievementInfo(path.requiresAchievement)
		if not done then return false, "achievement not earned" end
	end
	return true
end

------------------------------------------------------------
-- Which one to send them to
------------------------------------------------------------
-- Cheapest AVAILABLE path by travel time, which is the same currency the
-- router uses for everything else. Falls back to declaration order when travel
-- cannot be measured, so an unresolvable map never silently drops a route.
local function travelCost(path)
	local U = MM.Util
	if not (U and path.zone and path.zone.name) then return nil end
	local mapID = U.ResolveMapByName(path.zone.name)
	if not mapID then return nil end
	local continent, world = U.GetWorldPos(mapID, path.zone.x or 50, path.zone.y or 50)
	if not world then return nil end
	local pc, pw = U.PlayerWorldPos()
	if not pw then return nil end
	if MM.Teleports and MM.Teleports.TravelMinutes then
		local minutes = MM.Teleports.TravelMinutes(pc, pw, continent, world, nil)
		if minutes then return minutes end
	end
	local d = U.WorldDistance(pw, world)
	-- Same yards-per-minute the router flies at, so a path's cost is directly
	-- comparable with every other travel number in the addon.
	return d and (d / (MM.YARDS_PER_MINUTE or 1500)) or nil
end

function P.Best(rec)
	local paths = rec and rec.paths
	if not paths or #paths == 0 then return nil end
	local best, bestCost, bestIndex
	for i, path in ipairs(paths) do
		if P.Available(path) then
			local cost = travelCost(path)
			-- An unmeasurable path still beats no path, but loses to any
			-- measurable one, so a broken map cannot win by being unknown.
			local rank = cost or math.huge
			if not best or rank < bestCost then best, bestCost, bestIndex = path, rank, i end
		end
	end
	return best, bestIndex, bestCost ~= math.huge and bestCost or nil
end

-- Everything still open to this character that is not the one we recommended.
-- These are what the plan falls back to when the first attempt does not pay.
function P.Remaining(rec, chosen)
	local out = {}
	for _, path in ipairs((rec and rec.paths) or {}) do
		if path ~= chosen and P.Available(path) then out[#out + 1] = path end
	end
	return out
end

-- One line per path for a tooltip or the plan panel.
function P.Describe(rec)
	local paths = rec and rec.paths
	if not paths or #paths == 0 then return nil end
	local best = P.Best(rec)
	local lines = {}
	for _, path in ipairs(paths) do
		local ok, why = P.Available(path)
		local mark = (path == best) and "|cff40ff40>|r" or " "
		local text = ("%s %s"):format(mark, path.label or "?")
		if not ok then text = text .. (" |cff808080(%s)|r"):format(why or "unavailable") end
		lines[#lines + 1] = text
	end
	return lines, best
end

-- The router asks this: given a record with paths, where are we actually
-- going? Returns a zone table the caller can treat exactly like rec.zone.
function P.EffectiveZone(rec)
	local best = P.Best(rec)
	return best and best.zone or nil
end
