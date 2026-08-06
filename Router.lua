-- Master Mounts router: turns the plan into an ordered travel route
-- (current continent first, nearest-neighbor within each continent), keeps a
-- current goal, and auto-advances when goals complete.
local _, MM = ...
local U = MM.Util

MM.Router = {}
local R = MM.Router

R.route = {}      -- ordered steps: { entry, rec, mapID, x, y, label, continent, world, ease }
R.stopBySpell = {}   -- spellID -> the stop it was batched into, for "why is this here"
R.unrouted = {}   -- actionable plan entries with no physical location
R.deferred = {}   -- plan entries you can't work on right now: { entry, status, detail }

------------------------------------------------------------
-- Build
------------------------------------------------------------
-- Order a rare's spawn points into the shortest sweep we can cheaply compute.
--
-- A rare that patrols or spawns in several places is not "at" a coordinate --
-- it is at ONE of them, and which one is unknowable until you look. So the goal
-- is not to pick the right point, it is to walk every point in an order that
-- costs the least, and stop as soon as the rare turns up.
--
-- Nearest-neighbour from the player, not the true optimum: these lists run to a
-- handful of points, the ordering is recomputed whenever the player moves on,
-- and an exact solve would spend more time than it could ever save.
local function sweepOrder(points, fromWorld)
	local remaining, ordered = {}, {}
	for i, p in ipairs(points) do remaining[i] = p end

	local cursor = fromWorld
	while #remaining > 0 do
		local bestIdx, bestDist = 1, nil
		if cursor then
			for i, p in ipairs(remaining) do
				local _, w = U.GetWorldPos(p.mapID, p.x, p.y)
				local d = w and U.WorldDistance(cursor, w)
				if d and (not bestDist or d < bestDist) then bestIdx, bestDist = i, d end
			end
		end
		local pick = table.remove(remaining, bestIdx)
		ordered[#ordered + 1] = pick
		local _, w = U.GetWorldPos(pick.mapID, pick.x, pick.y)
		cursor = w or cursor
	end
	return ordered
end

local function makeStep(entry)
	local rec = entry.rec

	-- Timewalking purchases route to the LIVE event's vendor: any-era stock
	-- always, era-locked stock when its week is the active one.
	if rec.category == "TIMEWALKING" and MM.Timewalking.IsActive() then
		local loc, vendorName = MM.Timewalking.VendorLocation()
		if loc then
			-- ONE resolver, not a second copy of the rule.
			--
			-- This checked for "every era" and missed "any era", so Infinite
			-- Timereaver -- which drops from any TW boss in any era -- fell
			-- through to ERA_BY_EXPANSION[5] and was labelled Warlords of
			-- Draenor: one era named for a mount that ignores all of them.
			-- Availability.lua had its own near-identical copy. Two copies of a
			-- rule are two chances for it to be subtly different, and it was.
			local TWk = MM.Timewalking
			local eraOk = TWk.IsAnyEra and TWk.IsAnyEra(rec)
			if not eraOk then
				local needed = TWk.EraForRecord and TWk.EraForRecord(rec)
				local active = TWk.ActiveEra()
				eraOk = needed and active
					and (active:find(needed, 1, true) or needed:find(active, 1, true))
			end
			if eraOk then
				local continent, world = U.GetWorldPos(loc.mapID, loc.x, loc.y)
				return {
					entry = entry, rec = rec, mapID = loc.mapID, x = loc.x, y = loc.y,
					label = entry.name, desc = "Buy from " .. (vendorName or "the TW vendor"),
					continent = continent, world = world,
				}
			end
		end
	end

	-- A mount with several ways in routes to the one this character can
	-- actually take, cheapest first. Without this the record's single zone
	-- wins even when it belongs to a covenant the player did not join, which
	-- is how all four covenant-feature mounts pointed at one sanctum.
	local pathZone, chosenPath
	if rec.paths and MM.Paths then
		chosenPath = MM.Paths.Best(rec)
		pathZone = chosenPath and chosenPath.zone or nil
	end

	-- Several known spawn points: sweep them cheapest-first rather than commit
	-- to one. The first becomes this stop's target; the rest ride along so the
	-- player can advance to the next without losing their place in the route.
	-- Player position is resolved here rather than passed in: this runs before
	-- Build establishes its own copy, and ordering from a nil origin would
	-- silently degrade the sweep to database order.
	local sweep
	if rec.spawns and #rec.spawns > 1 then
		local _, fromWorld = U.PlayerWorldPos()
		sweep = sweepOrder(rec.spawns, fromWorld)
	end

	-- A quest chain routes to the step you are ON, not to the mount. The giver
	-- for a later step will not talk to you yet, so his position is the wrong
	-- answer until the steps before it are done.
	local chainStep, chainIndex, chainTotal
	if rec.questChain and MM.QuestGate and MM.QuestGate.CurrentStep then
		chainStep, chainIndex, chainTotal = MM.QuestGate.CurrentStep(rec)
		if chainStep and chainStep.zone then pathZone = chainStep.zone end
	end

	local zone = pathZone or rec.zone
	-- Trust the path's own mapID before re-deriving one from its name. We store
	-- the id precisely so it does not have to be guessed, and resolving by name
	-- can fail -- at which point a path-only record fell through to the record's
	-- zone, which does not exist, and the stop lost its coordinates entirely.
	local mapID = (pathZone and pathZone.mapID)
		or (pathZone and U.ResolveMapByName(pathZone.name))
		or U.GetRecordMapID(rec)
	if sweep and sweep[1] and sweep[1].mapID then mapID = sweep[1].mapID end
	-- dungeon/raid drops without zone data: the instance name is usually also
	-- a map name, which is good enough to route to the entrance area
	if not mapID and rec.instance and rec.instance.name then
		mapID = U.ResolveMapForRecord(rec.instance.name, rec)
	end
	if not mapID then return nil end
	local x = zone and zone.x
	local y = zone and zone.y
	if sweep and sweep[1] then x, y = sweep[1].x, sweep[1].y end

	-- No coordinate recorded? Aim at the zone's flight point, not its centre.
	--
	-- The centre of a zone is an arithmetic result, not a place -- it lands in
	-- mountains, oceans and unreachable geometry, and it made every travel
	-- estimate for a zone-only goal a guess about a spot nobody can stand on.
	-- A flight point is somewhere the player provably arrives, and its
	-- coordinates come from the client rather than from anyone's memory.
	--
	-- `approxFrom` is set so nothing downstream can mistake this for the
	-- mount's actual location. It is where the journey ENDS, not where the
	-- mount is, and the UI has to be able to tell the difference.
	local approxFrom
	if not (x and y) and MM.Taxi then
		local node = MM.Taxi.Nearest(mapID)
		if node then
			x, y = node.x, node.y
			approxFrom = MM.Taxi.Describe(node)
		end
	end
	x = x or 50
	y = y or 50
	local continent, world = U.GetWorldPos(mapID, x, y)
	local label = entry.name
	local desc
	if chainStep then
		desc = ("Quest %d of %d: %s"):format(chainIndex or 1, chainTotal or 1,
			chainStep.name or chainStep.npc or "continue the chain")
		if chainStep.npc then desc = desc .. " (" .. chainStep.npc .. ")" end
	elseif rec.npc and rec.npc.name then
		desc = "Kill " .. rec.npc.name
	elseif rec.instance and rec.instance.name then
		desc = rec.instance.name .. (rec.instance.difficulty and (" (" .. rec.instance.difficulty .. ")") or "")
	elseif chosenPath and chosenPath.label then
		desc = chosenPath.label
	elseif rec.category == "VENDOR" or rec.category == "REP" then
		desc = "Vendor in " .. ((zone and zone.name) or "?")
	else
		desc = rec.source
	end
	return {
		entry = entry, rec = rec, mapID = mapID, x = x, y = y,
		label = label, desc = desc, continent = continent, world = world,
		-- Which of several ways in this stop represents, so the UI can name it
		-- and say what is still open if this attempt does not pay.
		path = chosenPath,
		-- Set only when the coordinate is the zone's flight point standing in
		-- for a location we do not have. Never claims to be the mount's spot.
		approxFrom = approxFrom,
		-- Every known spawn point, cheapest-first. Index 1 is this stop's
		-- target; `sweepIndex` tracks how far through the player has checked.
		sweep = sweep,
		sweepIndex = sweep and 1 or nil,
		-- A zone this client cannot map yet -- Midnight 12.1 zones like the
		-- Coiled Isle are named by records but carry no map id until that
		-- content goes live. The goal is still real and still routed: travel
		-- falls back to the flat cross-continent cost (pessimistic, never
		-- free) and the player gets a zone NAME even though the arrow has
		-- nothing to point at.
		--
		-- It is recorded rather than left as a bare nil because the release
		-- gate reads "no position" as "would send someone nowhere", and an
		-- unexplained nil is indistinguishable from a bug. Say why, or the
		-- check has to assume the worst -- correctly.
		-- Named from whatever we actually know. A stop only exists at all once a
		-- mapID resolved, so we always know WHERE -- what failed is turning that
		-- map into world coordinates. Falling back through zone -> instance ->
		-- label keeps the reason truthful and specific instead of nil, which
		-- would read as "unexplained" and put the release gate back where it
		-- started.
		unmappedZone = (not world) and (
			(rec.zone and rec.zone.name)
			or (rec.instance and rec.instance.name)
			or label or "unmapped") or nil,
	}
end

------------------------------------------------------------
-- Visit batching
--
-- One route step per plan entry means a raid that can drop four mounts appears
-- as four separate journeys, and a 281-goal plan reads as 281 trips when it is
-- really about sixty stops. Goals collected in the SAME PLACE by the SAME ACT --
-- one raid clear, one vendor, one rare kill -- become a single stop carrying all
-- of them.
------------------------------------------------------------
local BUY = { VENDOR = true, REP = true, CURRENCY = true,
	TIMEWALKING = true, TRADINGPOST = true }

-- Forward declaration. This is the THIRD time in one session that a `local`
-- referenced above its definition silently became a global nil -- after
-- YARDS_PER_MINUTE (Addendum 98) and timeCache (Addendum 103). `luac -p` passes
-- every time, because the result is valid Lua that happens to call nil.
local strictOrdering

local function stopKey(step)
	local rec = step.rec
	if not rec then return nil end
	-- Under strict ordering a stop may not span a rank boundary.
	--
	-- Batching takes a stop's tier from its best member, so a raid that drops
	-- mounts AND awards a meta ranked as a drop and carried the achievement in
	-- with it -- which is how achievements kept appearing in a preset that says
	-- "drops only". Splitting by rank means the raid appears twice: once for the
	-- drops, once, much later, for the meta. That is the honest reading of
	-- "order rules".
	local prefix = ""
	if strictOrdering() and MM.Weights and MM.Weights.TierRank then
		prefix = "R" .. MM.Weights.TierRank(step.tier or 1) .. ":"
	end
	-- An instance is one run however many mounts it can drop. Difficulty
	-- deliberately does not split the key: you choose difficulty on arrival,
	-- and splitting would send you to the same door twice.
	if rec.instance and rec.instance.name then
		return prefix .. "I:" .. rec.instance.name:lower()
	end
	if rec.npc and rec.npc.name then
		return prefix .. "N:" .. rec.npc.name:lower()
	end
	if not step.mapID then return nil end
	-- Otherwise: same map, same spot, same kind of errand. The family guard
	-- stops a vendor and a world drop merging just because they share a corner
	-- of the map -- they are not one act even though they are one place.
	local family = BUY[rec.category] and "buy" or "field"
	return prefix .. ("Z:%d:%d:%d:%s"):format(step.mapID,
		math.floor((step.x or 50) / 5), math.floor((step.y or 50) / 5), family)
end

local function stopLabel(stop)
	local n = #stop.members
	if n == 1 then return stop.entry.name end
	local rec = stop.rec
	local place = (rec.instance and rec.instance.name)
		or (rec.npc and rec.npc.name)
		or (rec.zone and rec.zone.name)
		or stop.entry.name
	return ("%s  |cffffd84d(%d mounts)|r"):format(place, n)
end

-- Merge steps into stops, preserving the order they were produced in.
local function groupStops(steps)
	local stops, byKey = {}, {}
	for _, step in ipairs(steps) do
		local key = stopKey(step)
		local stop = key and byKey[key]
		if stop then
			tinsert(stop.members, step)
			-- You make this trip once, so it should be scheduled for the best
			-- reason any goal at it can offer.
			if step.urgency < stop.urgency then
				stop.urgency, stop.urgencyReason = step.urgency, step.urgencyReason
			end
			if step.tier < stop.tier then stop.tier = step.tier end
			-- Value per minute ADDS: one trip's travel now buys every roll at
			-- this stop, which is exactly why batching is worth doing.
			stop.vpm = (stop.vpm or 0) + (step.vpm or 0)
			stop.ease = MM.Planner.ValueScoreFromVPM(stop.vpm)
			-- Expected mounts ADD -- one trip now rolls for all of them, which
			-- is the whole point of batching. Time does NOT add: four mounts off
			-- one raid clear is still one raid clear, so take the longest.
			stop.mounts = (stop.mounts or 0) + (step.mounts or 0)
			if (step.visitMinutes or 0) > (stop.visitMinutes or 0) then
				stop.visitMinutes = step.visitMinutes
			end
			if (step.workMinutes or 0) > (stop.workMinutes or 0) then
				stop.workMinutes = step.workMinutes
			end
			if (step.visitMinutes or 0) > (stop.visitMinutes or 0) then
				stop.visitMinutes = step.visitMinutes
			end
			-- The handicap of a shared stop is the EASIEST thing you could do
			-- there, not the sum: you are not paying a hard mount's effort twice
			-- because an easy one drops at the same door.
			if (step.handicap or 0) < (stop.handicap or math.huge) then
				stop.handicap = step.handicap
			end
		else
			step.members = { step }
			tinsert(stops, step)
			if key then byKey[key] = step end
		end
	end
	for _, stop in ipairs(stops) do
		if #stop.members > 1 then
			stop.label = stopLabel(stop)
			stop.desc = ("%s — %d mounts drop here"):format(
				stop.desc or "One visit", #stop.members)
		end
	end
	return stops
end

-- How fast you cover ground, for turning yards into minutes and back.
local YARDS_PER_SECOND = 25
-- Declared HERE, not beside its first conceptual use further down: a `local`
-- referenced above its declaration silently resolves to a global, so the
-- fallback flight path was dividing by nil on any client without the teleport
-- layer. Nothing in the syntax check catches that.
local YARDS_PER_MINUTE = YARDS_PER_SECOND * 60

-- A stop we cannot place is not a stop that is free to visit. Treating an
-- unknown position as distance 0 let locationless steps win every comparison
-- and open the route from nowhere.
local UNKNOWN_DISTANCE = 4000

local function hop(fromWorld, step)
	if not fromWorld or not step.world then return UNKNOWN_DISTANCE end
	return U.WorldDistance(fromWorld, step.world) or UNKNOWN_DISTANCE
end

------------------------------------------------------------
-- Travel time, not geography
------------------------------------------------------------
-- Requirement — geography should not really matter at all, its all about time to travel
-- to destination, if something is a 10 minute flight but on the same continent
-- it should lose to something that is a Wormhole toy + 2 minute flight.
--
-- Correct, and it invalidates the model this router was built on. Continent
-- clustering, nearest-neighbour on world yards, "your continent first" -- all of
-- it encodes the assumption that distance is the cost. It is not. **Arrival
-- time is the cost**, and a wormhole toy makes another continent nearer than
-- the far side of the one you are standing on.
--
-- MM.Teleports.TravelMinutes answers the real question, weighing flying against
-- every teleport the player actually owns and the wait left on its cooldown.
-- `used` is the set already spent on this route, because a hearthstone is a
-- resource: spending it on leg two means it is gone on leg nine.
-- Per-step teleport costs, computed ONCE.
--
-- Even with the option list snapshotted, asking "which teleport is best for this
-- stop" inside the greedy meant walking every landing for every candidate on
-- every iteration, and again for every stop on every whole-plan evaluation. But
-- a teleport's cost to a FIXED destination never changes during a build: the
-- landing point and the cooldown are both already known. So compute it once per
-- stop and keep the short sorted list.
--
-- This is what turns the improvement pass from seconds into milliseconds: a
-- whole-plan walk goes from (stops x landings) to (stops x about two).
function R.PrecomputeTravel(steps)
	local TP = MM.Teleports
	local landings = (TP and TP.Options) and TP.Options() or {}
	for _, step in ipairs(steps) do
		local costs = {}
		if step.world then
			for _, landing in ipairs(landings) do
				if landing.continent == step.continent then
					local d = U.WorldDistance(landing.world, step.world)
					if d then
						costs[#costs + 1] = {
							key = landing.key, landing = landing,
							minutes = landing.waitMinutes + 0.5 + d / YARDS_PER_MINUTE,
						}
					end
				end
			end
			table.sort(costs, function(a, b) return a.minutes < b.minutes end)
		end
		step.tpCosts = costs
	end
end

-- Getting to another continent with nothing to teleport with: portals, boats,
-- the usual shuffle. Matches the constant in the teleport layer.
local CROSS_CONTINENT_MINUTES = 8

-- Build the travel state every costing walk starts from.
--
-- This exists because it was previously written out by hand in three places and
-- only one of them set `mapID`. The two that did not were the chain builder and
-- the objective function -- so during BUILDING and OPTIMISING, the map was
-- always unknown, the journey planner was never consulted, and every leg came
-- back as the flat cross-continent constant. The optimiser was choosing between
-- identical numbers and could not have found a better route if one existed.
--
-- `x`/`y` matter as much as `mapID`: the planner takes them as the origin, and
-- nothing ever set them at all.
function R.TravelState(start)
	local mapID = start and start.mapID
	local x, y = start and start.x, start and start.y
	if not mapID and C_Map and C_Map.GetBestMapForUnit then
		mapID = C_Map.GetBestMapForUnit("player")
		if mapID and not (x and y) and C_Map.GetPlayerMapPosition then
			local pos = C_Map.GetPlayerMapPosition(mapID, "player")
			if pos then x, y = pos.x * 100, pos.y * 100 end
		end
	end
	local continent, world = start and start.continent, start and start.world
	if not (continent and world) then
		local pc, pw = U.PlayerWorldPos()
		continent = continent or pc
		world = world or pw
	end
	return { continent = continent, world = world, mapID = mapID, x = x, y = y, used = {} }
end

-- Carry the position forward after a step, so leg three is costed from where
-- leg two ended rather than from where the player was standing at the start.
local function advanceState(state, step)
	state.continent = step.continent or state.continent
	state.world = step.world or state.world
	state.mapID = step.mapID or state.mapID
	state.x = step.x or state.x
	state.y = step.y or state.y
end

local function travelMinutes(state, step)
	-- Flying, if we can measure it. Same continent includes "both unknown":
	-- a missing continent must not throw away two known positions.
	-- Mounting up is not free. Two seconds, and it
	-- exists to stop the router recommending a dismount-walk-remount to save
	-- ten yards -- a saving that is imaginary once you have paid to get back on.
	local MOUNT_UP_MINUTES = 2 / 60

	-- A real flight time, ONLY when we can actually measure one.
	local flyMinutes
	if state.continent == step.continent and state.world and step.world then
		local d = U.WorldDistance(state.world, step.world)
		if d then flyMinutes = d / YARDS_PER_MINUTE + MOUNT_UP_MINUTES end
	end

	-- The whole journey, chained: one graph, every mode, Dijkstra across it.
	--
	-- Asked BEFORE the cross-continent fallback is applied, and that ordering is
	-- the whole point. Previously the flat 8-minute constant was handed in as
	-- the flying baseline, and since almost every genuine cross-continent route
	-- costs MORE than eight minutes, the fallback beat every real answer. Every
	-- stop reported exactly 8 minutes -- a number that looked like a measurement
	-- and was really just the constant, hiding the routing entirely.
	local best, method
	if MM.Journey and MM.Journey.Plan and C_Map and C_Map.GetMapInfo then
		local fi = state.mapID and C_Map.GetMapInfo(state.mapID)
		local ti = step.mapID and C_Map.GetMapInfo(step.mapID)
		if fi and ti and fi.name and ti.name then
			local mins, legs = MM.Journey.Plan(fi.name, state.x, state.y,
				ti.name, step.x, step.y, flyMinutes, state.mapID, step.mapID)
			if mins then
				best = mins
				method = { key = "journey:" .. tostring(step.mapID), taxi = true,
					name = MM.Journey.Describe(legs) or "multi-leg route", legs = legs }
			end
		end
	end

	-- Only now the fallbacks: a measured flight, else the flat cross-continent
	-- cost, which is a last resort and never a competitor.
	if not best then best = flyMinutes end
	if not best then best, method = CROSS_CONTINENT_MINUTES, nil end

	local costs = step.tpCosts
	if costs then
		for _, option in ipairs(costs) do
			if not (state.used and state.used[option.key]) then
				-- sorted ascending, so the first unspent one is the best one
				if option.minutes < best then best, method = option.minutes, option.landing end
				break
			end
		end
	elseif MM.Teleports and MM.Teleports.TravelMinutes then
		-- not precomputed (a caller outside Build): ask the slow way
		return MM.Teleports.TravelMinutes(state.continent, state.world,
			step.continent, step.world, state.used)
	end
	return best, method
end

-- Walk a chain and total it up, spending teleports as it goes. This is THE
-- objective function: one number for a whole plan, in minutes.
function R.RouteMinutes(chain, start)
	local state = R.TravelState(start)
	-- Same rule as the chain builder: a bare world position passed in must not
	-- be overwritten by the player's own.
	if start and start.x and not (start.world or start.continent) then
		state.world = start
		-- Clear the continent too. TravelState fills it from the player when the
		-- caller supplied none, and travelMinutes only measures a distance when
		-- state.continent == step.continent -- so a stale player continent
		-- against continent-less steps meant NO distance was ever computed, and
		-- the tie fell back to plan order. Fixing `world` alone left that intact.
		state.continent = start.continent
	end
	local total = 0
	for _, step in ipairs(chain) do
		local minutes, method = travelMinutes(state, step)
		total = total + (minutes or 0) + (step.workMinutes or 15)
		-- A teleport is a resource: spent on leg two, gone on leg nine. A taxi
		-- is not -- you can ride the same route all day -- so marking it used
		-- would silently forbid the second trip to a destination.
		if method and not method.taxi then state.used[method.key] = true end
		advanceState(state, step)
	end
	return total
end

-- Greedy chain blending travel distance (yards) with payoff-per-minute, so
-- the route clusters geographically while still front-loading the best value.
local nearestChain
-- How much a yard costs, relative to the shipped default of 250 points per
-- continent. This is the ONLY place the router weighs distance, so the Travel
-- slider now does in the route exactly what its label promises: at 0 the router
-- ignores geography and takes the best goals first, at the top of the range it
-- refuses to leave the neighbourhood.
local function travelScale()
	local w = MM.Weights and MM.Weights.Get("travel") or 250
	return w / 250
end
-- exposed so a self-test can prove the Travel slider reaches the router
function R.TravelScale() return travelScale() end

------------------------------------------------------------
-- The objective
------------------------------------------------------------
-- the user, twice: I changed a bunch of weights and priorities and nothing really
-- changed and It did not seem like the prioritization stack did anything to
-- reorder the list either. Both true, and neither was a wiring fault. It was
-- a UNITS fault.
--
-- The old ordering cost was `yards + points * 0.5`. A zone hop in WoW is
-- 15,000-40,000 world yards. The entire priority stack -- top of the list to
-- bottom -- moved the points term by about 1,900. Distance outweighed every
-- preference a player could express by roughly twenty to one, so of course the
-- list did not move. Adding more weights to that sum would have changed
-- nothing: the sum itself was the bug.
--
-- Everything is now in two units a player can actually reason about:
--
--     MINUTES           travel time plus time on site
--     EXPECTED MOUNTS   the sum of the chances you roll at a stop
--
-- and the router maximises **expected mounts per minute**. That is literally
-- what the user asked it to optimise, it front-loads the best hour for someone who
-- only has an hour, and every weight now shifts the answer by an amount
-- proportional to what its label claims.
-- How big a divisor a goal's own handicap (effort, time, long odds, era)
-- applies to its value. Chosen so the realistic handicap range -- roughly 0 to
-- 4,000 points -- spans about 1x to 3.7x, comparable to the priority divisor's
-- 1x to 5.2x, so neither silently swamps the other.
local HANDICAP_SCALE = 1500

-- Never divide by zero minutes, and never let a "free" stop score infinitely
-- better than a one-minute one.
local MIN_MINUTES = 1

-- Expected mounts per minute if you went to this stop next. HONEST: no
-- preference of any kind is folded in here. This is a physical quantity the UI
-- reports to the player, and anything that bends it makes the addon lie.
-- `travel` is MINUTES of travel, already weighted. Taking minutes rather than a
-- map position is precisely what lets a wormhole hop and a long flight be
-- compared at all -- there is no distance between them to compare.
local function density(s, travel, work)
	local minutes = math.max((travel or 0) + (work or s.workMinutes or 15), MIN_MINUTES)
	return (s.mounts or 0) / minutes
end
R.Density = density

------------------------------------------------------------
-- Preference: a selection rule, not a thumb on the scale
------------------------------------------------------------
-- Requirement — Is that the correct way to implement prioritization stacking? That
-- feels like gaming currency not considering it as part of the selection
-- criteria.
--
-- It was not, and he put his finger on exactly the wrong bit. The first version
-- divided EXPECTED MOUNTS by the priority rank -- pretending a rare literally
-- yields more mounts than it does. Expected mounts is a real quantity that the
-- planner summary and the tooltips report to the player as fact. Corrupting it
-- to express a taste means the number shown and the number used disagree, and
-- the honest summary stops being honest.
--
-- Preference applies to the SELECTION SCORE instead. Density stays a
-- measurement; this is the lens the player looks at it through.
--
-- The rule, in words the panel can print: *each place further down the priority
-- list, a goal must be this many times better value-per-minute to jump ahead.*
-- Geometric rather than linear, because "rares before achievements" is meant as
-- an ordering, not a nudge -- at the default 1.6x per place, the bottom of the
-- list must be 27x better before it outranks the top, which is a real ordering
-- with a real escape hatch for the genuinely exceptional case.
--
--   strength 0    -> 1.0x per place: priority ignored, pure value density
--   strength 0.6  -> 1.6x per place (default)
--   strength 1.5  -> 2.5x per place: effectively strict, top-of-list first
--
-- The escape hatch matters and is the thing the user already said was reasonable:
-- a #7 that is right next to you and rolls four chances SHOULD beat a #1 across
-- the world. A hard lexicographic sort could never express that.
-- Can you FINISH it in one sitting?
--
-- Requirement — the dreadwing says it takes 8 hours to complete, that is the factor
-- that matters. 1 min detour + 8 hours of activity guarantee should not [beat]
-- 20 min of travel + 10 minute dungeon run for a 1% drop UNLESS we are locked
-- out of all of those instances.
--
-- By raw value density the grind wins comfortably -- one guaranteed mount for
-- eight hours is 0.0021 mounts a minute against the dungeon's 0.0003, six times
-- better. The arithmetic is right and the answer is still wrong, because a
-- route is a list of things you DO and an eight-hour grind is not a stop. It is
-- a project you chip at; the dungeon is a closed action that either hands you a
-- mount tonight or does not.
--
-- The missing term is how much of the goal fits in a sitting. Squared, because
-- the intuition is not linear: something twice as long as your evening is much
-- worse than half as good, it is something you will not finish at all.
--
-- And the own exception falls out for free. When the short work is locked
-- out it is deferred and never reaches the route, so the grind rises to the top
-- on its own -- no special case, it simply becomes the best thing left.
local DEFAULT_SESSION_MINUTES = 120

local function sessionFit(s)
	local session = (MM.Weights and MM.Weights.Get("session")) or 0
	if session <= 0 then session = DEFAULT_SESSION_MINUTES end
	local work = s.workMinutes or 15
	if work <= session then return 1 end
	local ratio = session / work
	return ratio * ratio
end
R.SessionFit = sessionFit

-- At the very top of the Priority strength range the order stops being a strong
-- bias and becomes ABSOLUTE.
--
-- The design calls for "Legacy Dungeons & Raids ... the first things on the list
-- should ALWAYS be those", and a multiplier cannot deliver that. A vendor mount
-- you can simply buy is a guaranteed mount in ten minutes; a legacy raid drop is
-- 1% in twenty. That is a two-hundred-fold difference in value density, and no
-- per-place factor in a sane range closes it.
--
-- So the top of the slider switches to a lexicographic order: rank decides,
-- full stop, and value only sorts within a rank. The label already said "Order
-- rules" -- this makes it true.
local STRICT_AT = 1.45
-- comfortably larger than any achievable density (one mount a minute would be
-- 1.0), so a rank can never be crossed by value alone
local LEX_STEP = 1000

function strictOrdering()
	local W = MM.Weights
	return W and W.Get and W.Get("priority") >= STRICT_AT
end

local function preferenceDivisor(s)
	local div = 1
	-- Guard the FUNCTION, not the module. `if MM.Weights then` assumed the whole
	-- API existed the moment the table did, which is true today only because of
	-- TOC order -- a load-order change would have turned this into a hard error
	-- inside route building, the worst possible place for one.
	local W = MM.Weights
	if W and W.TierRank and W.Get then
		local rank = W.TierRank(s.tier or 1)
		local advantage = 1 + W.Get("priority")
		div = advantage ^ (rank - 1)
	end
	-- Reluctance about the goal itself -- effort, long odds, era -- is the same
	-- kind of thing as priority and belongs in the same place, never in mounts.
	return div * (1 + math.max(s.handicap or 0, 0) / HANDICAP_SCALE)
end
R.PreferenceDivisor = preferenceDivisor

-- What the router actually sorts on: measured value seen through the player's
-- stated preferences.
-- A reset you skip is a roll gone forever, so lockout work deserves a push --
-- but a PUSH, not a veto.
--
-- It used to be a hard band, and the preset simulator showed what that costs:
-- every preset produced the SAME top ten for anyone with a decent number of
-- weekly lockouts, because the band filled it before preference was consulted.
-- "Optimised for Time" was serving three-hour raid lockouts ahead of ten-minute
-- vendor pickups, which is the opposite of what it says on the tin.
--
-- EXPIRING stays absolute -- a holiday window genuinely disappears and no
-- amount of convenience is worth losing it. LOCKOUT becomes a multiplier the
-- Deadline pressure slider controls, so it can be traded off like everything
-- else.
local function urgencyBoost(s)
	local P = MM.Planner
	if not (P and s.urgency) then return 1 end
	if s.urgency == P.URGENCY.LOCKOUT then
		local W = MM.Weights
		return 1 + ((W and W.Get) and W.Get("urgency") or 1)
	end
	return 1
end

-- How certain this stop is, per goal. A batched stop that yields four mounts is
-- not "400% certain"; it is four goals with their own odds.
local function certaintyOf(s)
	local n = (s.members and #s.members) or 1
	if n < 1 then n = 1 end
	local c = (s.mounts or 0) / n
	if c <= 0 then return 0.01 end
	return math.min(1, c)
end

-- Odds and effort, as lenses.
--
-- The matrix said outright what four rounds of squinting had not: "Sure things
-- only — odds 5000, effort 500 ... IDENTICAL, and preference did not move
-- either — this setting never reaches the ranking." It was exactly true. Both
-- weights existed only in `Planner.CostParts`, which feeds tooltips. Neither
-- had ever touched a routing decision, while the self-test cheerfully reported
-- "all 8 weights move a routing input".
--
-- They are lenses, not corrections to the measurement -- the rule the user set when
-- he caught the first version dividing expected mounts by priority rank
-- ("that feels like gaming currency"). Density stays an honest quantity; these
-- change how hard the player wants to look at part of it.
--
-- Both take the same shape: an EXPONENT on a term density already contains.
-- That makes the neutral point exact rather than approximate, and gives the
-- extremes a precise meaning instead of a vibe:
--
--   exponent 1  the shipped default, changes nothing at all
--   exponent 0  that term cancels out of the density entirely
--   exponent 2  that term is counted twice
--
-- So "odds 0" does not merely soften rarity, it removes it from the sum -- a
-- 1% drop and a guaranteed one are then judged purely on time. That is what
-- "rarity stops counting against a mount" has to mean to be worth a slider.
local ODDS_BASELINE, EFFORT_BASELINE = 2500, 100
local EFFORT_REFERENCE = 60      -- an hour's work is the neutral yardstick
local LENS_CLAMP = 1e6

local function clampLens(v)
	if not (v == v) or v == math.huge then return LENS_CLAMP end   -- NaN or inf
	if v > LENS_CLAMP then return LENS_CLAMP end
	if v < 1 / LENS_CLAMP then return 1 / LENS_CLAMP end
	return v
end

local function oddsLens(s)
	local W = MM.Weights
	local w = (W and W.Get) and W.Get("odds") or ODDS_BASELINE
	local k = w / ODDS_BASELINE
	if math.abs(k - 1) < 1e-9 then return 1 end
	return clampLens(certaintyOf(s) ^ (k - 1))
end

local function effortLens(s)
	local W = MM.Weights
	local w = (W and W.Get) and W.Get("effort") or EFFORT_BASELINE
	local k = w / EFFORT_BASELINE
	if math.abs(k - 1) < 1e-9 then return 1 end
	local work = math.max(s.workMinutes or 15, MIN_MINUTES)
	return clampLens((EFFORT_REFERENCE / work) ^ (k - 1))
end
R.OddsLens, R.EffortLens = oddsLens, effortLens

-- Measured value, seen through the player's preferences AND through what they
-- can realistically finish tonight. Both are lenses on the density; neither
-- touches the density itself.
local function selectionScore(s, travel, work)
	local score = density(s, travel, work) * sessionFit(s) * urgencyBoost(s)
		* oddsLens(s) * effortLens(s)
		/ preferenceDivisor(s)
	if strictOrdering() then
		local W = MM.Weights
		local rank = (W and W.TierRank) and W.TierRank(s.tier or 1) or 1
		local places = #(W and W.DEFAULT_ORDER or {}) + 1
		-- rank 1 gets the largest block; value still sorts inside it
		score = (places - rank) * LEX_STEP + math.min(score, LEX_STEP - 1)
	end
	return score
end
R.SelectionScore = selectionScore

-- Preference-adjusted value ignoring travel, for "which of these is worth most"
-- questions where distance is not part of the comparison. This is LAYER ONE:
-- what the player asked for, before the world gets a vote.
--
-- It used to be a second, hand-written copy of the objective -- and it had
-- quietly drifted from the real one, carrying only mounts, session fit and
-- preference. No urgency, no work time, and so no effort or odds either. That
-- is precisely why the matrix reported settings "doing nothing": layer 1 could
-- not see three of the levers that were supposed to move it.
--
-- So it is no longer a copy. It is the objective with travel set to zero, which
-- is what "ignoring travel" always meant. One formula, one place to be wrong.
local function stopValue(s)
	return selectionScore(s, 0, s.workMinutes)
end
R.StopValue = stopValue

-- exposed so the offline geometry checks can measure the real starting point
-- rather than a shuffled one: the honest question is how much 2-opt improves on
-- nearest-neighbour, not on chaos.
function R.NearestChain(steps, fromWorld) return nearestChain(steps, fromWorld) end

function nearestChain(steps, start)
	local ordered = {}
	local pool = { unpack(steps) }
	local scale = travelScale()
	-- `start` is either a bare world position or a full travel state.
	-- `start` may be a bare world position rather than a full travel state, and
	-- that form has to WIN over the player-position fallback inside TravelState.
	-- Letting the fallback fill it in substituted the real player location for
	-- the caller's, which silently ignored the requested origin -- ties then
	-- broke on nothing and the nearer stop stopped being nearer.
	local state = R.TravelState(start)
	if start and start.x and not (start.world or start.continent) then
		state.world = start
		-- Clear the continent too. TravelState fills it from the player when the
		-- caller supplied none, and travelMinutes only measures a distance when
		-- state.continent == step.continent -- so a stale player continent
		-- against continent-less steps meant NO distance was ever computed, and
		-- the tie fell back to plan order. Fixing `world` alone left that intact.
		state.continent = start.continent
	end
	while #pool > 0 do
		-- Rank on value density, break ties on ARRIVAL TIME.
		--
		-- The tie-break is not a nicety. Any two stops with the same expected
		-- payoff -- and a plan full of unrated 1% drops is FULL of those -- were
		-- being separated by nothing at all, so the chain fell back to whatever
		-- order the plan happened to be in and ignored travel completely.
		-- An offline run made it obvious: two very different scenarios produced
		-- byte-identical routes.
		local bestI, bestScore, bestTime, bestMethod
		for i, s in ipairs(pool) do
			local minutes, method = travelMinutes(state, s)
			local d = selectionScore(s, minutes * scale, s.workMinutes)
			if not bestI or d > bestScore + 1e-12
				or (d > bestScore - 1e-12 and minutes < bestTime) then
				bestI, bestScore, bestTime, bestMethod = i, d, minutes, method
			end
		end
		local nextStep = tremove(pool, bestI)
		nextStep.arriveMinutes, nextStep.arriveBy = bestTime, bestMethod
		tinsert(ordered, nextStep)
		-- Spending the teleport here is what makes the rest of the chain honest:
		-- a hearthstone used on leg two is not available on leg nine.
		if bestMethod then state.used[bestMethod.key] = true end
		advanceState(state, nextStep)
	end
	return ordered
end

-- Nearest-neighbour is fast and leaves crossings: it commits to a cheap first
-- hop and pays for it later, so the chain doubles back over ground it already
-- covered. 2-opt reverses any run that untangles a crossing.
--
-- Two deliberate restraints, because pure shortest-path is NOT the goal:
--
--   * the first two stops are pinned. nearestChain front-loads the best payoff
--     on purpose, and a player who logs in for twenty minutes should get the
--     best twenty minutes, not the tidiest loop.
--   * a swap must save MIN_GAIN yards. Below that it is shuffling for a
--     rounding error and only costs you the value ordering.
local MIN_GAIN = 500
local MAX_PASSES = 4

function R.TwoOpt(list, fromWorld)
	local n = #list
	if n < 4 then return list end
	-- Untangling optimises DISTANCE and nothing else, so it has to answer to
	-- the Travel slider like every other distance decision.
	--
	-- It did not, and the matrix caught it: "Distance is free — travel 0"
	-- produced a byte-identical route to the defaults. The greedy chain duly
	-- ignored geography, and then 2-opt reordered the result by raw yards and
	-- put it all back. The slider's own label promises the router "ignores
	-- geography and takes the best goals first" at 0; this is what makes that
	-- true.
	if travelScale() <= 0 then return list end
	local passes = 0
	repeat
		local improved = false
		passes = passes + 1
		for i = 3, n - 1 do
			for j = i + 1, n do
				local a = (i == 1) and fromWorld or list[i - 1].world
				local b, c = list[i].world, list[j].world
				local dNext = list[j + 1] and list[j + 1].world
				if a and b and c then
					local before = (U.WorldDistance(a, b) or 0)
						+ (dNext and (U.WorldDistance(c, dNext) or 0) or 0)
					local after = (U.WorldDistance(a, c) or 0)
						+ (dNext and (U.WorldDistance(b, dNext) or 0) or 0)
					if after < before - MIN_GAIN then
						local lo, hi = i, j
						while lo < hi do
							list[lo], list[hi] = list[hi], list[lo]
							lo, hi = lo + 1, hi - 1
						end
						improved = true
					end
				end
			end
		end
	until not improved or passes >= MAX_PASSES
	return list
end

-- Total travel of a chain, in yards. Used by the estimate and by the tests.
function R.ChainLength(list, fromWorld)
	local total, cursor = 0, fromWorld
	for _, s in ipairs(list) do
		if cursor and s.world then total = total + (U.WorldDistance(cursor, s.world) or 0) end
		cursor = s.world or cursor
	end
	return total
end


-- How far out of your way a goal is still worth grabbing, in MINUTES of ADDED
-- travel. Minutes, not yards, for the reason the whole objective changed: 900
-- world yards -- the old limit -- is thirty-six seconds of flying, so almost
-- nothing ever qualified as "on the way" and the weave barely ran. Five minutes
-- is a detour a real player takes without thinking about it.
--
-- Scaled by the Travel slider like everything else: someone who says distance
-- is cheap means detours are cheap, and someone who says stay local means the
-- opposite.
local DETOUR_MINUTES = 5
local function detourMinutes()
	local scale = travelScale()
	if scale <= 0 then return math.huge end
	return DETOUR_MINUTES / scale
end
function R.DetourMinutes() return detourMinutes() end

-- Cheapest-insertion: weave opportunistic goals into an existing route
-- wherever they add the least travel, so you sweep past rare spawns on the
-- way to a dungeon or vendor instead of making a special trip.
-- Reported by /mm routeinfo, because "0 stops picked up as detours" is a number
-- with two completely different meanings -- nothing was near enough, or the
-- weave is inert -- and no way to tell them apart.
R.weaveReport = { considered = 0, taken = 0, cheapestRejected = nil, noSlot = 0 }

local function weaveOpportunistic(route, extras, startWorld, startContinent)
	local leftovers = {}
	R.weaveReport = { considered = #extras, taken = 0, cheapestRejected = nil, noSlot = 0 }
	for _, s in ipairs(extras) do
		if not s.world then
			-- No position, so it cannot be woven anywhere: hand it back to be
			-- routed with the rest rather than dropped at the insertion point.
			tinsert(leftovers, s)
		else
			local bestPos, bestCost = nil, math.huge
			-- Seed the continent, do not leave it nil. An unseeded first slot was
			-- treated as "same side as anything" and priced at zero, so a detour
			-- on the far side of the world could win the opening position.
			local prevWorld, prevContinent = startWorld, startContinent
			for i = 1, #route + 1 do
				local nextStep = route[i]
				local a, b = prevWorld, nextStep and nextStep.world
				-- A slot works if EITHER neighbour is on the detour's continent.
				--
				-- Requiring both was far too strict: once the route is ordered by
				-- rank rather than geography the continents interleave, so almost
				-- no slot has matching neighbours on both sides. a live report
				-- said it outright -- 111 candidates, 110 with no slot at all,
				-- which is a filter rejecting everything rather than a plan with
				-- nothing worth detouring to.
				--
				-- Passing through is the real case: you land on the continent,
				-- grab the rare, carry on. One matching side is what that looks
				-- like.
				local prevOk = (prevContinent == nil) or s.continent == prevContinent
				local nextOk = (not nextStep) or s.continent == nextStep.continent
				local sameSide = prevOk or nextOk
				if sameSide then
					-- Measure only against the side that is actually on this
					-- continent; distances across a boundary are arithmetic on
					-- unrelated numbers (Addendum 95).
					local cost
					if prevOk and nextOk and a and b then
						cost = (U.WorldDistance(a, s.world) or 0)
							+ (U.WorldDistance(s.world, b) or 0)
							- (U.WorldDistance(a, b) or 0)
					elseif prevOk and a then
						cost = U.WorldDistance(a, s.world) or UNKNOWN_DISTANCE
					elseif nextOk and b then
						cost = U.WorldDistance(s.world, b) or UNKNOWN_DISTANCE
					else
						cost = UNKNOWN_DISTANCE
					end
					if cost and cost < bestCost then bestCost, bestPos = cost, i end
				end
				if nextStep then
					prevWorld = nextStep.world or prevWorld
					prevContinent = nextStep.continent or prevContinent
				end
			end
			local extraMinutes = bestCost / YARDS_PER_MINUTE

			-- A detour has to be worth taking, not merely short.
			--
			-- This weighed distance and nothing else, so Bloodthirsty Dreadwing
			-- -- a mount the user cannot afford, expected value ZERO -- was slotted
			-- in at position ONE because it happened to be a minute off the
			-- path. Free is not the same as worth doing, and the first thing in
			-- a route is the one place that must never be filler.
			local worthless = (s.mounts or 0) <= 0.0001
			if worthless then bestPos = nil end
			-- Never take the lead. The spine's opening stop is the best thing to
			-- do right now; a pickup on the way cannot displace it.
			--
			-- Clamped, because the spine can now be EMPTY -- with only expiring
			-- work in it, a player with no live events has nothing there, and
			-- "second of nothing" is out of bounds.
			if bestPos == 1 then bestPos = math.min(2, #route + 1) end

			if bestPos and extraMinutes <= detourMinutes() then
				s.opportunistic = true
				s.detourMinutes = extraMinutes
				R.weaveReport.taken = R.weaveReport.taken + 1
				tinsert(route, bestPos, s)
			else
				if not bestPos then
					R.weaveReport.noSlot = R.weaveReport.noSlot + 1
				elseif extraMinutes < (R.weaveReport.cheapestRejected or math.huge) then
					R.weaveReport.cheapestRejected = extraMinutes
				end
				tinsert(leftovers, s)
			end
		end
	end
	return leftovers
end

-- Where you actually ARRIVE on a continent you are not standing on.
--
-- World coordinates are per-continent, so the distance between a position in
-- Kalimdor and one in the Dragon Isles is arithmetic on unrelated numbers. The
-- old code carried the cursor straight across the boundary, which meant the
-- first stop chosen on every new continent was chosen by a meaningless figure.
--
-- What a player really does is take a portal and travel out from where it drops
-- them, so ask the teleport layer where that is. When nothing lands there we
-- return nil and the chain opens on payoff instead -- the honest answer to
-- "you have to fly there anyway, so start with the best thing".
local function arrivalWorld(steps, continentKey)
	local n, sx, sy = 0, 0, 0
	for _, step in ipairs(steps) do
		if step.world then
			n, sx, sy = n + 1, sx + step.world.x, sy + step.world.y
		end
	end
	if n == 0 then return nil end
	local centroid = { x = sx / n, y = sy / n }
	if not (MM.Teleports and MM.Teleports.Landings) then return nil end
	local ok, landings = pcall(MM.Teleports.Landings, {})
	if not (ok and landings) then return nil end
	local best, bestDist
	for _, landing in ipairs(landings) do
		if landing.continent == continentKey and landing.world then
			local d = U.WorldDistance(landing.world, centroid) or math.huge
			if not best or d < bestDist then best, bestDist = landing.world, d end
		end
	end
	return best
end

-- Continent-clustered chain over one pool of steps.
--
-- Clustering survives the move to travel time, but as a STARTING SHAPE rather
-- than a rule: stops on one continent are usually cheap to chain, so it is a
-- good first guess, and ImproveTotalTime is then free to break the grouping up
-- when the whole-plan clock disagrees. A cheap heuristic proposes, the real
-- objective disposes.
local function routePool(steps, playerContinent, startWorld)
	local byContinent, order = {}, {}
	for _, s in ipairs(steps) do
		local key = s.continent or -1
		if not byContinent[key] then
			byContinent[key] = {}
			tinsert(order, key)
		end
		tinsert(byContinent[key], s)
	end
	table.sort(order, function(a, b)
		if (a == playerContinent) ~= (b == playerContinent) then return a == playerContinent end
		return #byContinent[a] > #byContinent[b]
	end)
	-- "Order rules" has to mean it. Continent clustering sits ABOVE the
	-- selection score, so with strict priority on it was quietly overruling the
	-- very thing the player had just declared absolute: the simulator showed the
	-- Legacy preset putting ZERO instance runs in its own top ten, because the
	-- continent it started on happened to have none.
	--
	-- Under strict ordering the pool is routed whole, and travel decides only
	-- within a rank.
	if strictOrdering() then
		local chain = nearestChain(steps, { world = startWorld })
		return chain, chain[#chain] and chain[#chain].world or startWorld
	end

	local out, cursor = {}, startWorld
	for _, key in ipairs(order) do
		local pool = byContinent[key]
		-- Only the player's own continent inherits the running cursor. Anywhere
		-- else, start from where you would land.
		local from = (key == playerContinent) and cursor or arrivalWorld(pool, key)
		-- a STATE, not a bare position: without the continent the greedy cannot
		-- price a teleport at all
		local chain = R.TwoOpt(nearestChain(pool, { continent = key, world = from }), from)
		for _, s in ipairs(chain) do tinsert(out, s) end
		cursor = chain[#chain] and chain[#chain].world or cursor
	end
	return out, cursor
end

function R:Build()
	local startedAt = debugprofilestop and debugprofilestop() or nil
	wipe(R.route); wipe(R.unrouted); wipe(R.deferred)

	-- Refresh the travel snapshot ONCE for this whole build. Every travel-time
	-- question below then reads a plain table instead of the toybox.
	if MM.Teleports and MM.Teleports.Refresh then MM.Teleports.Refresh() end
	R.travelPrecomputed = nil

	-- Urgency bands lead: expiring events, then lockout attempts (skipping
	-- those wastes a roll forever), then everything that waits for you.
	-- Outdoor rares are held back and woven in as cheap detours.
	local bands, opportunistic, pending = { {}, {} }, {}, {}
	for _, entry in ipairs(MM.Planner:GetPlan()) do
		local status, detail = MM.Availability.GetStatus(entry)
		-- A goal you cannot complete, that yields nothing if you go, is not a
		-- stop -- it is a project. Bloodthirsty Dreadwing kept surfacing near the
		-- top because it was being ROUTED at all: zero expected mounts still
		-- occupies a position, and the position it occupied was second.
		--
		-- Parked, with the reason, alongside the lockout-blocked goals. It is
		-- still in the plan and still visible; it just cannot be somewhere the
		-- route sends you, because going there achieves nothing.
		local yields = MM.Planner.ExpectedMounts(entry)
		local finishable = MM.Planner.CompletableNow(entry)
		if status == "LOCKED" or status == "HOLIDAY" or status == "ROTATION"
			or status == "PREREQ" or status == "UNOBTAINABLE" then
			tinsert(R.deferred, { entry = entry, status = status, detail = detail })
		elseif yields <= 0 and finishable == false then
			-- Name the specific unmet requirement when we can. Guarded because
			-- Conditions is not guaranteed present in every context that builds
			-- a route (the offline harness proved it), and a diagnostic detail
			-- is never worth taking the route down for.
			local why
			if MM.Conditions and MM.Conditions.EvaluateAll then
				local _, condLines = MM.Conditions.EvaluateAll(entry.rec)
				for _, line in ipairs(condLines or {}) do
					if line.met == false then why = line.text break end
				end
			end
			tinsert(R.deferred, { entry = entry, status = "PREREQ",
				detail = why or "Requirements not met yet" })
		else
			local step = makeStep(entry)
			if step then
				local tier = MM.Planner.Rank(entry)
				local urgency, urgencyReason = MM.Planner.Urgency(entry)
				step.tier = tier
				step.urgency, step.urgencyReason = urgency, urgencyReason
				-- value-only: urgency is already handled by the band, and this
				-- must stay on the same scale as travel distance (yards)
				step.vpm = MM.Planner.ValuePerMinute(entry)
				step.ease = MM.Planner.ValueScoreFromVPM(step.vpm)
				step.handicap = MM.Planner.Handicap(entry)
				-- The two figures the objective is expressed in. Computed here
				-- rather than after routing, because they ARE the ordering.
				step.mounts = MM.Planner.ExpectedMounts(entry)
				-- the REAL time to finish, not the length of one visit
				step.workMinutes = MM.Planner.EffortMinutes(entry)
				step.visitMinutes = MM.Planner.VisitMinutes(entry)
				-- One visit, as distinct from finishing the thing. A route of
				-- 156 stops reading "33 days" is honest about the commitment and
				-- useless as an answer to "what am I doing tonight" -- both
				-- numbers are wanted, so both are kept.
				step.visitMinutes = (entry.rec and entry.rec.timePerAttempt) or 15
				step.completableNow = MM.Planner.CompletableNow(entry)
				tinsert(pending, step)
			else
				tinsert(R.unrouted, entry)
			end
		end
	end

	-- Every travel question from here down reads these, not the toybox.
	R.PrecomputeTravel(pending)
	R.travelPrecomputed = #pending

	------------------------------------------------------------
	-- LAYER 1: preference
	------------------------------------------------------------
	-- the description of how this is meant to work, and it is right:
	--
	--   the weights and priorities define the initial order of the mounts,
	--   then grouping nearby objectives push things up or down based on
	--   effectiveness, then finally the routing logic comes in as the final
	--   adjudicator, it respects weights and priorities but is not bound to them
	--   and its ultimate goal is SPEED and most efficient TOTAL TIME.
	--
	-- The three layers existed but were tangled together, so when the order came
	-- out wrong there was no way to say WHICH layer had done it. They are now
	-- recorded as they happen: every goal carries where it stood after each
	-- stage, and `/mm layers` prints the movement. A disagreement between two
	-- layers is now a thing you can read instead of a thing you have to guess.
	--
	-- Layer 1 is preference alone: what you asked for, before the world gets a
	-- vote. No travel, no batching.
	table.sort(pending, function(a, b)
		local va, vb = R.StopValue(a), R.StopValue(b)
		if va ~= vb then return va > vb end
		return (a.entry and a.entry.name or "") < (b.entry and b.entry.name or "")
	end)
	for i, step in ipairs(pending) do step.layerPreference = i end

	-- Batch first, then band: a stop's urgency is its most urgent member, so a
	-- rare that happens to share a doorway with an expiring goal gets swept up
	-- rather than deferred to its own trip.
	-- Work you can do WITHOUT TRAVELLING beats work you have to fly to, and the
	-- bands alone could not express that: they are consumed in strict order, so
	-- a lockout goal in Shadowlands was placed ahead of an available goal in the
	-- zone the player is standing in. Distance was only ever compared WITHIN a
	-- band, never across them.
	--
	-- The zone-alert module already knew this ("Valdrakken: 7 farmable mounts
	-- you're missing") while the router was routing to another continent. Two
	-- parts of the addon disagreeing about the same question is the tell.
	local playerContinent, playerWorld = U.PlayerWorldPos()
	local playerMap = C_Map.GetBestMapForUnit("player")
	-- Roughly a zone hop. Beyond this you are making a journey, not a detour.
	local NEARBY_YARDS = 5000

	-- "Am I standing here" cannot be map-id equality. Capitals are their own
	-- maps nested inside a zone: stand in Dazar'alor (1165) and the player map
	-- is Zuldazar (862), so an exact test says you are not where you are. The
	-- route then flew to Tazavesh and back to Dazar'alor for three mounts that
	-- were underfoot the whole time. Same family as Dalaran 41-vs-125, coming
	-- from the parent side instead of the name side.
	--
	-- One step each way covers city-in-zone and zone-with-city; it deliberately
	-- does not walk to the continent, or every stop on Kalimdor would be "here".
	-- Is the player standing inside this stop's map, or vice versa?
	--
	-- Depth is the wrong bound and I got this wrong twice. One level missed the
	-- portal-room-inside-a-city case. Three levels then matched 95 of 103 stops,
	-- because three hops from any zone reaches the CONTINENT, and every chain
	-- meets there -- so the whole route counted as underfoot and travel stopped
	-- mattering at all.
	--
	-- The real bound is the map's TYPE. Zone (3) and below -- dungeons, micro
	-- maps, the room you are standing in -- are places you can be inside of.
	-- Continent (2), World (1) and Cosmic (0) are not: sharing a continent is
	-- not standing somewhere. So the climb stops the moment the parent stops
	-- being a Zone, however many levels that takes.
	local ZONE = (Enum and Enum.UIMapType and Enum.UIMapType.Zone) or 3
	local function ancestry(id)
		local seen, cur = { [id] = true }, id
		for _ = 1, 8 do -- generous; the type test is what actually stops it
			local info = C_Map.GetMapInfo(cur)
			local parent = info and info.parentMapID
			if not parent or parent == 0 then break end
			local pinfo = C_Map.GetMapInfo(parent)
			-- Refuse to climb out of Zone level. This is the whole guard.
			if not pinfo or not pinfo.mapType or pinfo.mapType < ZONE then break end
			seen[parent] = true
			cur = parent
		end
		return seen
	end
	local function nestedMap(a, b)
		if not (a and b) then return false end
		if a == b then return true end
		if not (C_Map and C_Map.GetMapInfo) then return false end
		local up = ancestry(a)
		if up[b] then return true end
		for id in pairs(ancestry(b)) do
			if up[id] then return true end
		end
		return false
	end

	-- What "already here" is allowed to promote. This used to be a tier test,
	-- and tier is the wrong axis: it was standing in for "is this short?" and
	-- got it wrong in both directions.
	--
	-- The rule it encodes is still right -- Taivan is hundreds of hours and sits
	-- in Valdrakken, and promoting it to save three minutes of flying is absurd.
	-- But Island Expeditions are GRIND tier too, and a run is fifteen minutes
	-- you can start from where you stand. Blocking those made the router send
	-- the player across the world and back.
	--
	-- So measure the thing the rule was actually about: minutes of work per
	-- visit -- NOT the whole grind. Taivan fails on hours. An island run passes
	-- on fifteen no matter how many runs the odds imply. Tier no
	-- longer has to mean two different things at once.
	local function shortWork(stop)
		if stop.tier <= MM.Planner.TIER.FIELD then return true end
		return (stop.visitMinutes or 15) <= 30
	end

	------------------------------------------------------------
	-- LAYER 2: grouping
	------------------------------------------------------------
	-- Goals that share a stop now count as one visit with the payoff of all of
	-- them, which moves things: four mounts behind one raid door beats a single
	-- better mount somewhere else. This is where "effectiveness" enters.
	local grouped = groupStops(pending)
	table.sort(grouped, function(a, b)
		local va, vb = R.StopValue(a), R.StopValue(b)
		if va ~= vb then return va > vb end
		return (a.layerPreference or 0) < (b.layerPreference or 0)
	end)
	for i, stop in ipairs(grouped) do stop.layerGrouped = i end

	local nearby = {}
	for _, stop in ipairs(grouped) do
		local allRare = true
		for _, m in ipairs(stop.members) do
			if m.tier ~= MM.Planner.TIER.RARE then allRare = false break end
		end
		local hereNow = nestedMap(stop.mapID, playerMap)
			or (playerWorld and stop.world and stop.continent == playerContinent
				and (U.WorldDistance(playerWorld, stop.world) or math.huge) <= NEARBY_YARDS)

		if allRare and not hereNow then
			tinsert(opportunistic, stop)
		elseif hereNow and stop.urgency > MM.Planner.URGENCY.EXPIRING
			and shortWork(stop) then
			-- EXPIRING still leads: a window that closes forever outranks
			-- convenience. Everything else yields to "you are already here" --
			-- but ONLY for short work.
			--
			-- The value of being here is the travel you save. Taivan is the
			-- Dragonflight meta-achievement, hundreds of hours, and it sits in
			-- Valdrakken -- so promoting it for proximity put a months-long
			-- project in the top seven to save three minutes of flying. Saving
			-- travel is meaningless next to that.
			--
			-- PICKUP/INSTANCE/RARE/FIELD are "go do a thing now". REP, GRIND,
			-- ACHIEVE and GROUP are projects and stay in their proper band,
			-- where difficulty decides their place.
			tinsert(nearby, stop)
		else
			-- Two bands now, not three: what genuinely disappears, and
			-- everything else. Lockout urgency rides on the score instead.
			tinsert(bands[stop.urgency == MM.Planner.URGENCY.EXPIRING and 1 or 2], stop)
		end
	end
	-- best payoff first among the free ones: you are already standing here, so
	-- the only question left is which is worth most
	table.sort(nearby, function(a, b) return R.StopValue(a) > R.StopValue(b) end)

	-- Record what the "already here" test actually decided.
	--
	-- This took three reloads to diagnose because the answer lived inside one
	-- boolean nobody could see: a nil player map and a genuinely-distant stop
	-- produce the same empty band and the same wrong-looking route. The report
	-- now says which, so the next person reads it instead of guessing.
	R.hereDebug = {
		playerMap = playerMap,
		promoted = #nearby,
		candidates = #grouped,
	}

	-- SPINE: only what genuinely disappears. Everything else has to earn its
	-- place on the score, which is what lets a preset change the answer.
	local cursor = playerWorld
	local chain
	chain, cursor = routePool(bands[1], playerContinent, cursor)
	for _, s in ipairs(chain) do tinsert(R.route, s) end
	for _, s in ipairs(nearby) do
		tinsert(R.route, s)
		cursor = s.world or cursor
	end

	-- MAIN JOURNEY: everything without a hard deadline, ordered by the score --
	-- which is where preference, session fit and lockout urgency all land.
	--
	-- This has to be ROUTED, not woven. When the expiring band is empty (the
	-- normal case -- most players have no live event), weaving the whole plan
	-- means cheapest-insertion decides the order, and it places by travel alone:
	-- it will happily put stop nine ahead of stop one, and drop an achievement
	-- into the middle of a drops-only route.
	local main
	main, cursor = routePool(bands[2], playerContinent, cursor)
	for _, s in ipairs(main) do tinsert(R.route, s) end

	-- WEAVE: rare spawns slotted in wherever they cost the least detour. This is
	-- genuine opportunism -- something you pass on the way -- and nothing else.
	--
	-- Stands down under strict ordering, for the same reason clustering and the
	-- block reorder do: insertion knows nothing about rank, so it is the fourth
	-- thing that would quietly overrule "order rules".
	local leftovers = opportunistic
	if not strictOrdering() then
		table.sort(opportunistic, function(a, b) return R.StopValue(a) > R.StopValue(b) end)
		leftovers = weaveOpportunistic(R.route, opportunistic, playerWorld, playerContinent)
	end

	-- Whatever could not ride along still belongs in the sequence.
	local tail = routePool(leftovers, playerContinent, cursor)
	for _, s in ipairs(tail) do tinsert(R.route, s) end

	-- DON'T LEAVE AND COME BACK.
	--
	-- Every pool above is ordered by score with travel as a tiebreak, and none
	-- of them can see the others. So a map can be visited, left, and visited
	-- again -- fly to Dazar'alor, cross the world, fly back to Dazar'alor --
	-- because the two stops were ranked in different pools and neither knew.
	--
	-- Merging the revisit into the first visit is free: same stops, same order
	-- otherwise, one less round trip. That is the whole change.
	--
	-- Three guards, each for a rule that already exists above:
	--   * EXPIRING is never moved. A closing window outranks tidy travel.
	--   * shortWork only. Same test the "already here" promotion uses -- a
	--     hundred-hour project should not jump forward to save a flight.
	--   * stands down under strict ordering, exactly like clustering and the
	--     weave, because this reorders and "order rules" means it must not.
	if not strictOrdering() then
		local blockEnd = {} -- mapID -> index where its first run of stops ends
		local i = 1
		while i <= #R.route do
			local s = R.route[i]
			local m = s and s.mapID
			local e = m and blockEnd[m]
			if e and e < i - 1 and s.urgency > MM.Planner.URGENCY.EXPIRING
				and shortWork(s) then
				tremove(R.route, i)
				tinsert(R.route, e + 1, s)
				-- everything between the block and here shifted right by one
				for k, v in pairs(blockEnd) do
					if v > e then blockEnd[k] = v + 1 end
				end
				blockEnd[m] = e + 1
			elseif m then
				blockEnd[m] = i
			end
			i = i + 1
		end
	end

	-- A SESSION REORDERS THE FINISHED ROUTE.
	--
	-- Last, after every other layer, because it is a promise about what the next
	-- N minutes contain and it must not be undone by anything downstream. It
	-- used to live in Session.Start, where the very next rebuild discarded it.
	--
	-- Reordered, not truncated: the rest of the plan follows, so running over or
	-- ending early simply continues.
	R.ApplySession = function()
		local S = MM.Session
		local st = S and S.Active and S.Active()
		if not (st and S.Fit and R.route and #R.route > 0) then return end
		local chosen = S.Fit(st.minutes)
		if not chosen or #chosen == 0 then return end
		local inSession = {}
		for _, stop in ipairs(chosen) do inSession[stop] = true end
		local rest = {}
		for _, stop in ipairs(R.route) do
			if not inSession[stop] then rest[#rest + 1] = stop end
		end
		wipe(R.route)
		for _, stop in ipairs(chosen) do R.route[#R.route + 1] = stop end
		for _, stop in ipairs(rest) do R.route[#R.route + 1] = stop end
		st.planned = #chosen
	end

	-- Goals with no map location still belong in the sequence — otherwise
	-- skipping through the route "finishes" while they sit unvisited.
	table.sort(R.unrouted, function(a, b)
		return MM.Planner.SessionScore(a) < MM.Planner.SessionScore(b)
	end)
	for _, entry in ipairs(R.unrouted) do
		-- A real stop, not a placeholder. These were bare tables with no
		-- `mounts`, no `workMinutes` and no `members`, and everything downstream
		-- assumed a stop has those -- Measure crashed on the first one, taking
		-- every route build in the addon with it. A thing that lives in a list
		-- has to satisfy that list's contract.
		local stop = {
			entry = entry, rec = entry.rec, label = entry.name,
			desc = entry.rec and entry.rec.source or "No map location recorded",
			noLocation = true,
			tier = MM.Planner.Rank(entry),
			mounts = MM.Planner.ExpectedMounts(entry),
			workMinutes = MM.Planner.EffortMinutes(entry),
			visitMinutes = MM.Planner.VisitMinutes(entry),
			handicap = MM.Planner.Handicap(entry),
			completableNow = MM.Planner.CompletableNow(entry),
			layerPreference = 0, layerGrouped = 0,
			tpCosts = {},
		}
		stop.members = { stop }
		tinsert(R.route, stop)
	end

	table.sort(R.deferred, function(a, b) return a.entry.name < b.entry.name end)

	------------------------------------------------------------
	-- LAYER 3: the clock
	------------------------------------------------------------
	-- The final adjudicator. It respects preference -- that is what
	-- selectionScore carries -- but it is not bound by it, and where the two
	-- disagree the clock wins. Total plan time is the objective.
	R.ImproveTotalTime(playerContinent, playerWorld)
	R.ApplyPreferenceCap()
	for i, stop in ipairs(R.route) do stop.layerRouted = i end
	R.Measure()

	-- Index the finished route so a goal can be asked what it was batched with.
	-- Built here rather than searched on demand: the tooltip asks per row, and
	-- rescanning the route for every hover is work we already did once.
	wipe(R.stopBySpell)
	for _, stop in ipairs(R.route) do
		for _, member in ipairs(stop.members or { stop }) do
			local e = member.entry
			if e and e.spellID then R.stopBySpell[e.spellID] = stop end
		end
	end

	-- The session's promise, applied AFTER every other layer and after the
	-- stopBySpell index is built -- it only reorders, so the index stays valid.
	if R.ApplySession then R.ApplySession() end

	-- RESUME BY IDENTITY, NOT BY POSITION.
	--
	-- The route is rebuilt per character, from a different place with different
	-- teleports and different things reachable, so index 7 here is not index 7
	-- there. Carrying the number across a switch lands you at somebody else's
	-- stop; carrying the GOAL finds the same mount wherever it now sits.
	--
	-- If it is gone -- collected in the meantime, or blocked for whoever you
	-- are now -- the anchor is dropped rather than approximated, and the route
	-- starts from the top.
	local goal = MM.db and MM.db.routeGoal
	if goal then
		local found
		for i, stop in ipairs(R.route) do
			if stop.spellID == goal then found = i break end
			for _, member in ipairs(stop.members or {}) do
				if member.spellID == goal then found = i break end
			end
			if found then break end
		end
		if found then
			MM.cdb.routeIndex = found
		else
			MM.db.routeGoal = nil
		end
	end

	if MM.cdb.routeIndex > #R.route then MM.cdb.routeIndex = 1 end
	-- Measured, not assumed. A route build froze the client for minutes and
	-- nothing in the addon could say so.
	if startedAt then R.lastBuildMs = debugprofilestop() - startedAt end
	return #R.route
end

------------------------------------------------------------
-- Total time, not per-leg time
------------------------------------------------------------
-- Requirement — it should be TOTAL time for the entire plan -- if it makes more sense
-- to fly 10 minutes now because we cannot work in a more efficient travel leg
-- later on then it makes sense to have it now, but if we can do the wormhole
-- teleport, then go do a dungeon, then hearth and its faster total time then
-- that makes the most sense.
--
-- A greedy chain answers "what is cheapest NEXT", which is a different question
-- and sometimes the wrong one: taking the wormhole early to save four minutes
-- can cost twenty later when the continent it served comes round again.
--
-- Optimising the true total is a scheduling problem, and brute force is out --
-- a hundred and fifty stops with a teleport budget is not something to solve
-- inside a UI callback. But almost all of the available saving lives in ONE
-- decision: the order you visit continents in, because that is what decides
-- which teleport is spent when. So the route is cut into continent blocks and
-- the blocks are reordered while the WHOLE-PLAN time keeps falling.
--
-- Within a block the greedy chain and the 2-opt pass have already done the
-- work, and no teleport choice is involved -- you are flying either way.
local function continentBlocks(route)
	local blocks, current = {}, nil
	for _, stop in ipairs(route) do
		if current and stop.continent == current.continent then
			current[#current + 1] = stop
		else
			current = { continent = stop.continent, stop }
			blocks[#blocks + 1] = current
		end
	end
	return blocks
end

local function flatten(blocks)
	local out = {}
	for _, block in ipairs(blocks) do
		for _, stop in ipairs(block) do out[#out + 1] = stop end
	end
	return out
end

-- Reordering is O(blocks^2) evaluations of an O(stops) walk, so its cost grows
-- as blocks^2 * stops. That is fine for the shape this normally has -- a handful
-- of continents -- and ruinous when a plan fragments into dozens of one-stop
-- blocks, which is exactly what happens when the player has goals scattered
-- everywhere. Cap it, and say what was skipped rather than silently doing less.
local MAX_BLOCKS_TO_REORDER = 30
local MAX_IMPROVE_PASSES = 3

------------------------------------------------------------
-- The preference cap
------------------------------------------------------------
-- The matrix kept reporting the same thing: IDENTICAL route -- but preference
-- DID reorder (15 moved). Layer 1 works; layer 3 overrides it.
--
-- That was the architecture working as specified. the user set routing as the final
-- adjudicator whose goal is total time, and two continent hops dwarf any
-- preference multiplier, so geography won essentially every tie. The layered
-- ordering table showed goals arriving 57 places ahead of where preference put
-- them while goals ranked 9th never appeared at all.
--
-- The system therefore spanned both extremes and had no middle: "geography
-- decides" at normal strength, "order decides outright" past 1.45, and very
-- little in between. the user chose the cap.
--
-- THE RULE: a stop may not sit more than `cap` places from where preference
-- wanted it. Inside that band the clock is still completely free -- which is
-- the point. This does not overrule routing, it bounds how far routing may
-- drag something before the player stops recognising their own list.
--
-- A stop's preference rank is its BEST member's, matching how urgency already
-- batches: a stop is as wanted as the most-wanted thing at it.
--
-- Implementation is a deadline-driven greedy, not a sort.
--
-- The first version clamped each stop's position into its band and stable-sorted
-- by the result. That is O(n log n) and reads well, and the offline harness
-- rejected it immediately: cap 4 produced a worst displacement of 5, cap 30
-- produced 35. Clamping the SORT KEY does not bound the resulting POSITION,
-- because every other stop is moving at the same time. The slider promises
-- "nothing lands more than twelve places from where your priorities put it",
-- and approximately-twelve is not that promise.
--
-- So positions are filled one at a time, and a stop is only ever placed inside
-- its own window [pref - cap, pref + cap]:
--
--   * if a stop has reached the END of its window it MUST be placed now,
--     otherwise it can never be legal again
--   * otherwise take the stop the CLOCK wanted soonest among those whose
--     window has opened -- which is what keeps the routing inside the band
--
-- At most one stop can hit its deadline at any position (preference ranks are
-- distinct), so a backlog cannot build up, and the identity assignment is
-- always legal, so a feasible answer always exists.

R.capReport = nil

local function stopPreference(stop)
	local best
	for _, m in ipairs(stop.members or { stop }) do
		local p = m.layerPreference or stop.layerPreference
		-- ZERO IS NOT A RANK. Goals that never reached layer one -- the ones
		-- with no location to route to -- are appended with layerPreference = 0
		-- as a placeholder. Treating that as "rank 0" made them the most
		-- preferred things in the plan, and the cap then dutifully dragged them
		-- to the very top: the route opened with nine goals it cannot route
		-- to at all, led by a mount with no location and a 0.1% drop.
		--
		-- No preference means LAST, not first.
		if p and p > 0 and (not best or p < best) then best = p end
	end
	return best or math.huge
end

function R.PreferenceCap()
	local W = MM.Weights
	local v = (W and W.Get) and W.Get("orderCap") or 0
	if not v or v <= 0 then return nil end   -- 0 means no cap at all
	return v
end

function R.ApplyPreferenceCap()
	R.capReport = nil
	local cap = R.PreferenceCap()
	if not cap then return 0 end
	local route = R.route
	local n = #route
	if n < 3 then return 0 end

	-- Preference RANK among the routed stops, densely numbered. The raw
	-- layerPreference is an index into the pending list, which includes stops
	-- that never made the route, so using it directly would compare a rank of
	-- 70 against a position of 12 on different scales.
	local order = {}
	for i = 1, n do order[i] = route[i] end
	table.sort(order, function(a, b)
		local pa, pb = stopPreference(a), stopPreference(b)
		if pa ~= pb then return pa < pb end
		return (a.layerRouted or 0) < (b.layerRouted or 0)
	end)
	local prefRank = {}
	for i, stop in ipairs(order) do prefRank[stop] = i end

	local before = {}
	for i, stop in ipairs(route) do before[stop] = i end

	-- Candidates in the order the CLOCK chose them. That order is what we are
	-- trying to preserve; the window is what we are trying to respect.
	local pending = {}
	for i, stop in ipairs(route) do
		pending[i] = { stop = stop, pref = prefRank[stop] or i }
	end

	local placed = {}
	for i = 1, n do
		local pickIdx
		-- 1. Anything at the end of its window has to go now.
		for idx, e in ipairs(pending) do
			if e.pref + cap <= i then
				if not pickIdx or e.pref < pending[pickIdx].pref then pickIdx = idx end
			end
		end
		-- 2. Otherwise the clock's favourite among those allowed here.
		if not pickIdx then
			for idx, e in ipairs(pending) do
				if e.pref - cap <= i then pickIdx = idx break end
			end
		end
		-- 3. Cannot happen -- the identity assignment is always legal -- but a
		--    router that silently drops a goal is far worse than one that
		--    ignores preference, so it falls back rather than failing.
		if not pickIdx then pickIdx = 1 end
		placed[i] = pending[pickIdx].stop
		tremove(pending, pickIdx)
	end
	for i = 1, n do route[i] = placed[i] end

	-- Measure what actually happened. A guarantee nobody checks is a comment.
	local worst, shifted = 0, 0
	for i, stop in ipairs(route) do
		local d = math.abs(i - (prefRank[stop] or i))
		if d > worst then worst = d end
		if before[stop] ~= i then shifted = shifted + 1 end
	end
	R.capReport = { cap = cap, worst = worst, shifted = shifted, stops = n }
	return shifted
end

function R.ImproveTotalTime(playerContinent, playerWorld)
	local blocks = continentBlocks(R.route)
	R.blocksSkipped = nil
	-- "Order rules" has to survive this too. Block reordering optimises travel
	-- and nothing else, so with strict priority on it was quietly undoing the
	-- ordering the player had just declared absolute -- the simulator showed the
	-- Legacy preset managing two instance runs before drifting into grinds.
	if strictOrdering() then return 0 end
	-- Same reasoning as 2-opt: reordering continent blocks is a pure travel
	-- optimisation, and a player who has set travel to zero has said that is
	-- not what they want optimised.
	if travelScale() <= 0 then return 0 end
	if #blocks < 3 then return 0 end   -- nothing to reorder
	if #blocks > MAX_BLOCKS_TO_REORDER then
		-- Reorder the biggest blocks, which is where the travel actually is, and
		-- leave the long tail of single stops where the greedy put them.
		R.blocksSkipped = #blocks - MAX_BLOCKS_TO_REORDER
	end

	local start = { continent = playerContinent, world = playerWorld }
	local best = R.RouteMinutes(R.route, start)
	local before = best

	-- Pairwise block swaps until nothing improves. Blocks are few -- one per
	-- continent run, typically a handful -- so this is cheap where a general
	-- reordering of every stop would not be.
	--
	-- Block 1 is left alone: it is where the player is standing, and moving it
	-- means opening the evening with a journey.
	-- Swap AND relocate.
	--
	-- Swapping alone cannot cluster an interleaved route: turning
	-- [Kalimdor, Northrend, Kalimdor, Northrend] into two blocks needs a
	-- sequence of moves, and every single swap along the way looks like no
	-- improvement. An offline run made that concrete -- twelve alternating
	-- stops, and swap-only found nothing at all to save. Relocation moves one
	-- block next to its own kind in a single step, which is exactly the move
	-- that pays.
	-- Only the first N blocks are candidates for moving; everything after stays
	-- put. Blocks are already in a sensible order, so the head is where the
	-- expensive decisions live.
	local limit = math.min(#blocks, MAX_BLOCKS_TO_REORDER)

	local improved, guard = true, 0
	while improved and guard < MAX_IMPROVE_PASSES do
		improved, guard = false, guard + 1

		for i = 2, limit - 1 do
			for j = i + 1, limit do
				blocks[i], blocks[j] = blocks[j], blocks[i]
				local minutes = R.RouteMinutes(flatten(blocks), start)
				if minutes < best - 0.5 then
					best, improved = minutes, true
				else
					blocks[i], blocks[j] = blocks[j], blocks[i]   -- put it back
				end
			end
		end

		for i = 2, limit do
			local block = tremove(blocks, i)
			local bestPos, bestMinutes = i, best
			for pos = 2, limit do
				tinsert(blocks, pos, block)
				local minutes = R.RouteMinutes(flatten(blocks), start)
				if minutes < bestMinutes - 0.5 then
					bestPos, bestMinutes = pos, minutes
				end
				tremove(blocks, pos)
			end
			tinsert(blocks, bestPos, block)
			if bestMinutes < best - 0.5 then
				best, improved = bestMinutes, true
			end
		end
	end

	-- Rewrite IN PLACE. R.route is a module table that the UI, the compact list
	-- and the stop index all hold a reference to; reassigning it would leave
	-- every one of them pointing at the old route.
	if best < before - 0.5 then
		local final = flatten(blocks)
		wipe(R.route)
		for _, stop in ipairs(final) do R.route[#R.route + 1] = stop end
	end

	R.timeSaved = before - best
	return R.timeSaved
end

-- The stop a goal currently sits in, or nil if the route has not been built.
function R.StopFor(spellID)
	return spellID and R.stopBySpell[spellID] or nil
end

------------------------------------------------------------
-- What this route is actually worth
------------------------------------------------------------
-- The plan could say "286 goals" and the route "153 stops" and neither number
-- answered the only question a collector has on a Tuesday evening: *if I do
-- this, do I get a mount?* Two goals with the same stop count are not the same
-- session when one is four guaranteed drops and the other is four 1% rolls.
--
-- Expected mounts is the honest figure and it adds cleanly: the expected value
-- of independent rolls is the sum of their chances, whatever their odds. 0.85
-- expected mounts over two hours is a real answer, and a much better one than
-- a number of pins on a map.
-- Fills in per-stop figures and returns the route totals.
-- Why a stop is allowed to have no world position.
--
-- Three separate diagnostics have now grown their own copy of this rule.
-- The first two disagreed until they were made textually identical, which is
-- only another way of saying they will drift again; the third simply forgot
-- it and reported 32 deliberate cases as router failures. One owner.
--
-- Returns the REASON, not a boolean, because every caller wants to print it.
function R.PositionlessExcuse(stop)
	if not stop then return nil end
	if stop.noLocation then return "no location by design" end
	if stop.unmappedZone then
		return ("zone not mapped by this client (%s)"):format(tostring(stop.unmappedZone))
	end
	if MM.Queue and MM.Queue.KindFor and MM.Queue.KindFor(stop.rec) then
		return "reached by queueing, not travelling"
	end
	return nil
end

function R.Measure()
	local playerContinent, playerWorld = U.PlayerWorldPos()
	-- Walk the route the way the player will, spending teleports as they go, so
	-- the time we report is the time a wormhole actually buys them.
	local state = R.TravelState({ continent = playerContinent, world = playerWorld })
	local minutes, mounts, travelTotal, visitTotal = 0, 0, 0, 0
	local sessionCap = MM.Weights and MM.Weights.Get("session") or 0
	local boundaryMarked = false

	for _, stop in ipairs(R.route) do
		local legMinutes, method = travelMinutes(state, stop)
		-- A teleport is a resource: spent on leg two, gone on leg nine. A taxi
		-- is not -- you can ride the same route all day -- so marking it used
		-- would silently forbid the second trip to a destination.
		if method and not method.taxi then state.used[method.key] = true end
		stop.arriveBy = method
		travelTotal = travelTotal + legMinutes
		stop.travelMinutes = legMinutes
		-- Build already computed these; Measure must not recompute them from a
		-- second copy of the rules or the two will drift.
		stop.minutes = stop.workMinutes or 15
		visitTotal = visitTotal + (stop.visitMinutes or 15)
		minutes = minutes + stop.travelMinutes + stop.minutes
		mounts = mounts + (stop.mounts or 0)
		stop.cumulativeMinutes = minutes
		stop.cumulativeMounts = mounts
		-- the user rather than truncate. Cutting the route at the session length
		-- would hide work from someone who turns out to have longer; a line
		-- across it tells them where they stand without deciding for them.
		stop.pastSession = false
		if sessionCap > 0 and minutes > sessionCap then
			stop.pastSession = true
			if not boundaryMarked then
				stop.sessionBoundary = true
				boundaryMarked = true
			end
		else
			stop.sessionBoundary = false
		end
		advanceState(state, stop)
		state.x, state.y = stop.x, stop.y
	end

	R.totals = {
		stops = #R.route,
		minutes = minutes,                       -- everything, grinds included
		routeMinutes = travelTotal + visitTotal, -- travel plus one visit each
		travelMinutes = travelTotal,
		mounts = mounts,
	}
	return R.totals
end

-- One line for the UI: "12 stops · about 2h 10m · ~0.8 mounts expected".
function R.SummaryText()
	local t = R.totals
	if not t or t.stops == 0 then return nil end
	local mountText
	if t.mounts >= 1 then
		mountText = ("~%.1f mounts expected"):format(t.mounts)
	elseif t.mounts > 0 then
		mountText = ("~%d%% chance of a mount"):format(math.min(99, t.mounts * 100))
	else
		mountText = "no drops to roll"
	end
	return ("%d stop%s · %s on the route · %s to finish everything · %s"):format(
		t.stops, t.stops == 1 and "" or "s",
		U.FormatSeconds((t.routeMinutes or t.minutes) * 60),
		U.FormatSeconds(t.minutes * 60), mountText)
end

------------------------------------------------------------
-- Control
------------------------------------------------------------
-- /mm layers — where each layer put things, and where they disagreed.
--
-- The whole point of naming the layers is being able to answer "why is this
-- here" with "layer 2 moved it up because three mounts share that door" rather
-- than with a shrug.
MM:On("MM_LAYERS_DEBUG", function()
	-- Never let a broken build produce an EMPTY section. "(no output)" is
	-- the least useful thing a diagnostic can say, and it is exactly what
	-- this printed while the router was throwing on every build.
	local built, err = pcall(function() return R:Build() end)
	if not built then
		MM:Print("|cffff4444Layered ordering: the router failed to build: %s|r", tostring(err))
		return
	end
	MM:Print("|cff33c1ffLayered ordering|r — preference, then grouping, then the clock")
	MM:Print("  1. weights & priorities   2. shared stops   3. total travel time")
	if #R.route == 0 then
		MM:Print("  |cffff4444Nothing routed — is your plan empty?|r")
		return
	end
	MM:Print("  %-32s %5s %5s %5s  %s", "goal", "pref", "group", "route", "why it moved")
	local shown = 0
	for _, stop in ipairs(R.route) do
		for _, m in ipairs(stop.members or { stop }) do
			if shown < 25 then
				shown = shown + 1
				local why = {}
				local batched = #(stop.members or { stop })
				if batched > 1 then why[#why + 1] = batched .. " share this stop" end
				if stop.opportunistic then
					why[#why + 1] = ("on the way, +%.0f min"):format(stop.detourMinutes or 0)
				end
				if stop.arriveBy then why[#why + 1] = stop.arriveBy.name end
				local band = ({ "expiring", "lockout", "anytime" })[stop.urgency or 3] or "?"
				why[#why + 1] = band
				local pref = m.layerPreference or 0
				local routed = stop.layerRouted or 0
				local drift = pref - routed
				if math.abs(drift) >= 5 then
					why[#why + 1] = ("|cffffd84dmoved %d %s|r"):format(math.abs(drift),
						drift > 0 and "up" or "down")
				end
				MM:Print("  %-32s %5s %5s %5s  |cff9a9a9a%s|r",
					(m.entry and m.entry.name or "?"):sub(1, 32),
					tostring(pref), tostring(stop.layerGrouped or "-"), tostring(routed),
					table.concat(why, ", "))
			end
		end
	end
	local capRep = R.capReport
	if capRep then
		MM:Print("  Layer 3 reorders for speed, but no goal lands more than |cffffd84d%d|r places", capRep.cap)
		MM:Print("  from where layer 1 put it. Worst actual displacement: %d.", capRep.worst)
	else
		MM:Print("  Layer 3 overrides layers 1 and 2 whenever it is faster overall,")
		MM:Print("  without limit — Options > Weights sets a cap if you want one.")
	end
end)

MM:On("MM_ROUTE_DEBUG", function()
	-- Never let a broken build produce an EMPTY section. "(no output)" is
	-- the least useful thing a diagnostic can say, and it is exactly what
	-- this printed while the router was throwing on every build.
	local built, err = pcall(function() return R:Build() end)
	if not built then
		MM:Print("|cffff4444Route: the router failed to build: %s|r", tostring(err))
		return
	end
	MM:Print("Route: %s", R.SummaryText() or "nothing routable")
	local cap = MM.Weights and MM.Weights.Get("session") or 0
	if cap > 0 then
		local reached = 0
		for _, stop in ipairs(R.route) do
			if not stop.pastSession then reached = reached + 1 end
		end
		local mounts = R.route[reached] and R.route[reached].cumulativeMounts or 0
		MM:Print("  In a %d-minute session: %d of %d stops, ~%.2f mounts expected",
			cap, reached, #R.route, mounts)
	else
		MM:Print("  No session length set — Options > Weights & Priorities draws the line.")
	end
	MM:Print("  Built in %s%s",
		R.lastBuildMs and ("%.0f ms"):format(R.lastBuildMs) or "unmeasured",
		(R.lastBuildMs or 0) > 250 and " |cffff4444— too slow, this is a freeze|r" or "")
	MM:Print("  Travel weight %.2fx, detours accepted up to %.1f minutes off the path",
		R.TravelScale(), R.DetourMinutes())
	-- Why "you are already here" did or did not fire. Without this the two
	-- failure modes -- the client not knowing where you are, and nothing
	-- actually being near you -- look identical in the route.
	local hd = R.hereDebug
	if hd then
		if not hd.playerMap then
			MM:Print("  |cffff4444Your position was unknown when this route was built|r "
				.. "— nothing could be promoted for being nearby. /mm route to replan.")
		else
			local zone = C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(hd.playerMap)
			MM:Print("  Standing in %s (map %d) — %d of %d stops promoted for being here.",
				(zone and zone.name) or "?", hd.playerMap, hd.promoted, hd.candidates)
		end
	end
	if R.blocksSkipped then
		MM:Print("  %d small blocks left where they were (reorder is capped at %d).",
			R.blocksSkipped, 30)
	end
	if (R.timeSaved or 0) > 0.5 then
		MM:Print("  Reordering continents saved %.0f minutes of the total plan time.",
			R.timeSaved)
	end
	local landings = MM.Teleports and MM.Teleports.Landings and MM.Teleports.Landings({}) or {}
	MM:Print("  %d teleport%s usable right now:", #landings, #landings == 1 and "" or "s")
	for _, l in ipairs(landings) do
		MM:Print("     %s -> %s%s", l.name, l.place or "?",
			l.waitMinutes > 0.1 and (" (%.0f min cooldown)"):format(l.waitMinutes) or "")
	end
	local hops = 0
	for _, stop in ipairs(R.route) do if stop.arriveBy then hops = hops + 1 end end
	MM:Print("  %d leg%s of this route use a teleport rather than flying.",
		hops, hops == 1 and "" or "s")
	local woven, batched = 0, 0
	for _, stop in ipairs(R.route) do
		if stop.opportunistic then woven = woven + 1 end
		if #(stop.members or {}) > 1 then batched = batched + 1 end
	end
	MM:Print("  %d stops picked up as detours, %d stops carry more than one mount",
		woven, batched)
	local wr = R.weaveReport or {}
	if (wr.considered or 0) > 0 and (wr.taken or 0) == 0 then
		MM:Print("     |cffffd84dnone qualified:|r %d candidates, %d had no slot on their",
			wr.considered, wr.noSlot or 0)
		MM:Print("     own continent, cheapest rejected detour was %s (limit %.1f min)",
			wr.cheapestRejected and ("%.1f min"):format(wr.cheapestRejected) or "n/a",
			R.DetourMinutes())
	elseif (wr.considered or 0) > 0 then
		MM:Print("     %d of %d rare-only stops rode along; cheapest rejected %s",
			wr.taken or 0, wr.considered,
			wr.cheapestRejected and ("%.1f min"):format(wr.cheapestRejected) or "n/a")
	end
	for i = 1, math.min(8, #R.route) do
		local stop = R.route[i]
		MM:Print("   %d. %s |cff9a9a9a(%s, ~%.0f%% mount, %s in)|r", i,
			stop.label or "?",
			stop.opportunistic and "detour" or "planned",
			math.min(99, (stop.mounts or 0) * 100),
			U.FormatSeconds((stop.cumulativeMinutes or 0) * 60))
	end
end)

function R:Current()
	if not (MM.cdb and MM.cdb.routeActive) then return nil end
	local stop = R.route[MM.cdb.routeIndex]
	-- Remember WHICH GOAL, account-wide, every time the current one is read.
	--
	-- This is the anchor the rebuild resumes from, and putting it here rather
	-- than in each of the four places that move the index means no future one
	-- can forget to. A goal with no spellID leaves the anchor alone rather than
	-- clearing it -- losing your place is worse than an anchor going briefly
	-- stale.
	if stop and MM.db then
		local id = stop.spellID
			or (stop.members and stop.members[1] and stop.members[1].spellID)
		if id then MM.db.routeGoal = id end
	end
	return stop
end

function R:Start()
	local n = R:Build()
	if n == 0 then
		MM:Print("No routable goals in the plan. Add mounts with a farm location first.")
		return false
	end
	MM.cdb.routeActive = true
	MM.cdb.routeIndex = 1
	MM.Nav.SetWaypoint(R:Current())
	MM:Fire("MM_ROUTE_STARTED")
	MM:Fire("MM_ROUTE_ADVANCED")
	MM:Print("Route started: %d goals. Good hunting.", n)
	return true
end

function R:Stop()
	MM.cdb.routeActive = false
	MM.Nav.ClearWaypoint()
	MM:Fire("MM_ROUTE_STOPPED")
end

-- Where a record sits in the live route, or nil if it is not in the plan at all.
-- The rare alert needs this to decide between steering the player and merely
-- pointing: a rare they are already hunting deserves the main arrow, a rare
-- that is nobody's goal must not be allowed to take it.
function R:IndexOfRec(rec)
	if not (rec and MM.cdb and MM.cdb.routeActive) then return nil end
	for i, s in ipairs(R.route) do
		if s.rec == rec then return i end
	end
	return nil
end

-- Jump the route to a stop the player is standing next to. Used when a rare
-- they already planned to kill turns up early -- taking it now is strictly
-- better than walking past it to honour an order that assumed it was elsewhere.
function R:JumpTo(index)
	if not (MM.cdb and MM.cdb.routeActive) then return false end
	if not (index and R.route[index]) then return false end
	MM.cdb.routeIndex = index
	MM.Nav.SetWaypoint(R:Current())
	MM:Fire("MM_ROUTE_ADVANCED")
	return true
end

-- Move to this stop's next known spawn point. Returns false when every point
-- has been checked, which is the caller's cue that the rare is genuinely not up
-- rather than merely not here.
function R:NextSpawn()
	local step = R:Current()
	if not (step and step.sweep) then return false end
	local nextIdx = (step.sweepIndex or 1) + 1
	local p = step.sweep[nextIdx]
	if not p then return false end

	step.sweepIndex = nextIdx
	step.mapID, step.x, step.y = p.mapID, p.x, p.y
	step.continent, step.world = U.GetWorldPos(p.mapID, p.x, p.y)
	MM.Nav.SetWaypoint(step)
	MM:Fire("MM_ROUTE_ADVANCED")
	MM:Print("Spawn point %d of %d for %s.", nextIdx, #step.sweep, step.label or "this rare")
	return true
end

-- Arriving at a spawn point and finding nothing is information: the rare is not
-- HERE, which is not the same as it not being up. So we wait a moment -- the
-- vignette appears on a delay after a zone streams in, and advancing instantly
-- would skip past a rare that was about to announce itself -- and only then move
-- on. Otherwise the player stands on an empty spawn waiting for a thing that was
-- never going to appear at that particular one.
local SWEEP_DWELL_SECONDS = 8
local sweepDwell

function R.CancelSweepDwell()
	if sweepDwell then sweepDwell:Cancel() end
	sweepDwell = nil
end

function R.NoteArrival(step)
	if not (step and step.sweep and step.sweepIndex) then return end
	if step.sweepIndex >= #step.sweep then return end  -- every point checked
	if sweepDwell then return end                      -- already counting down

	sweepDwell = C_Timer.NewTimer(SWEEP_DWELL_SECONDS, function()
		sweepDwell = nil
		-- the player may have moved on, or the route rebuilt, in the meantime
		if R:Current() ~= step then return end
		-- an alert for this record means the rare IS here: stay put
		if MM.RareAlert and MM.RareAlert.RecentlyAlerted
			and MM.RareAlert.RecentlyAlerted(step.rec) then return end
		R:NextSpawn()
	end)
end

function R:Advance(step)
	if not MM.cdb.routeActive then return end
	step = step or 1
	local nextIndex = MM.cdb.routeIndex + step
	if nextIndex > #R.route then
		-- be explicit about what's left rather than implying "all done"
		local waiting = #R.deferred
		if waiting > 0 then
			MM:Print("End of the route — %d goal%s still waiting on lockouts or events. "
				.. "They unlock on their own; re-Optimize after the next reset.",
				waiting, waiting == 1 and "" or "s")
		else
			MM:Print("Route complete! Rebuild it after resets for another lap.")
		end
		R:Stop()
		return
	end
	if nextIndex < 1 then nextIndex = 1 end
	MM.cdb.routeIndex = nextIndex
	MM.Nav.SetWaypoint(R:Current())
	MM:Fire("MM_ROUTE_ADVANCED")
end

MM:On("MM_ROUTE_TOGGLE", function()
	if MM.cdb.routeActive then R:Stop() else R:Start() end
end)

-- A route that was active at logout resumes automatically after the first
-- journal scan: rebuild it, re-arm the waypoint/arrow, reopen the monitor.
local resumed = false
MM:On("MM_SCANNED", function()
	if resumed or not (MM.cdb and MM.cdb.routeActive) then return end
	resumed = true

	-- Say what is happening BEFORE the work starts.
	--
	-- Resuming a route plans every leg through the travel graph, and that is
	-- seconds of real computation. It is not wasted time -- it is the routing --
	-- but silence during it is indistinguishable from a hang, and a player who
	-- thinks the addon froze reloads and pays the cost twice. The message is
	-- printed first, and the build deferred one frame so the client can actually
	-- draw it rather than queueing it behind the very work it describes.
	-- ONE line for a resume, not three.
	--
	-- This printed "planning travel...", then "Route planned in 4.3s", then
	-- "Route resumed — goal 1 of 143" -- three messages at every single login
	-- describing one thing the player did not ask for. The monitor window opens
	-- and shows the goal, so chat was narrating a window that is already on
	-- screen. The wait notice stays, because seconds of silence during a freeze
	-- genuinely does look broken; the other two go.
	MM:Print("Resuming your route — planning travel, this takes a moment...")

	-- WAIT FOR THE MAP BEFORE PLANNING.
	--
	-- Build() asks where the player is standing, and everything about "you are
	-- already here" depends on the answer. Straight after a reload the client
	-- has not finished bringing the world map up, so GetBestMapForUnit returns
	-- nil for the first few frames.
	--
	-- Planning in that window is not a small error, it is a different plan: nil
	-- means nothing is nearby, so every free stop underfoot loses its promotion
	-- and the route orders on value alone. That is exactly the symptom -- stand
	-- in Dazar'alor with three mounts under your feet and get sent to Tazavesh
	-- first, every time, because at plan time the router did not know where you
	-- were. Deferring one frame was never enough; it needed the map, not a frame.
	--
	-- Bounded at ~5s. If the position never arrives we still plan, because a
	-- value-ordered route beats no route -- but we say so, rather than silently
	-- producing the bad ordering and letting it look like a routing bug.
	local waited = 0
	local function planNow(positionKnown)
		if not positionKnown then
			MM:Print("Could not read your position — routing without it, so "
				.. "nearby goals may not be ordered first. /mm route to replan.")
		end
		local startedAt = debugprofilestop and debugprofilestop() or nil
		R:Build()
		if startedAt and debugprofilestop then
			local secs = (debugprofilestop() - startedAt) / 1000
			-- Only when it was slow enough to have looked broken. Below that
			-- the player never noticed a pause and does not need a receipt.
			if secs > 4 then
				MM:Print("Route planned in %.1fs — %d goals.", secs, #R.route)
			end
		end
		R.FinishResume()
	end
	local function whenReady()
		if C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player") then
			planNow(true)
			return
		end
		waited = waited + 1
		if waited > 50 then planNow(false) return end
		C_Timer.After(0.1, whenReady)
	end
	C_Timer.After(0, whenReady)
end)

-- The second half of the resume, split out so the build above can be deferred.
function R.FinishResume()
	if #R.route == 0 then
		R:Stop()
		return
	end
	if MM.cdb.routeIndex > #R.route then MM.cdb.routeIndex = 1 end
	MM.Nav.SetWaypoint(R:Current())
	MM:Fire("MM_ROUTE_STARTED")
	MM:Fire("MM_ROUTE_ADVANCED")
	-- Silent: MM_ROUTE_STARTED above opens the monitor, which states the goal
	-- and the count in the window the player is now looking at.
end

------------------------------------------------------------
-- Auto-advance triggers
------------------------------------------------------------
-- Goal mount learned → next goal.
MM:On("MM_MOUNT_LEARNED", function(_, spellID)
	local cur = R:Current()
	if not (cur and spellID) then return end
	local hit, remaining = nil, 0
	for _, m in ipairs(cur.members or { cur }) do
		if m.entry.spellID == spellID then
			hit = m
		elseif not m.entry.collected then
			remaining = remaining + 1
		end
	end
	if not hit then return end
	-- A batched stop is not finished just because one of its mounts dropped;
	-- moving on would send you away from rolls you already travelled for.
	if remaining > 0 then
		MM:Print("%s collected! %d more can still drop here — staying put.",
			hit.entry.name, remaining)
		MM:Fire("MM_ROUTE_ADVANCED")
		return
	end
	MM:Print("Goal complete — %s! Moving to the next target.", hit.entry.name)
	R:Advance()
end)

-- Attempt used on a daily/weekly goal → nothing more to do here today, advance.
MM:On("MM_ATTEMPT", function(spellID)
	local cur = R:Current()
	if not cur then return end
	local match
	for _, m in ipairs(cur.members or { cur }) do
		if m.entry.spellID == spellID then match = m break end
	end
	if not match then return end
	-- The lockout covers the whole stop: every mount here shares the one run.
	local lockout = cur.rec.attempts or (cur.rec.instance and cur.rec.instance.lockout)
	if lockout == "DAILY" or lockout == "WEEKLY" then
		MM:Print("Attempt recorded for %s — advancing the route.", cur.label)
		C_Timer.After(3, function() R:Advance() end)
	end
end)

-- Tracking-quest completion poll (rares whose "attempted" flag flips).
-- A ticker that only exists while a route is running: an always-on OnUpdate
-- frame costs every player every frame forever, for a check that is
-- meaningless outside an active route.
local poller

local function startPoller()
	if poller then return end
	poller = C_Timer.NewTicker(10, function()
		local cur = R:Current()
		if not cur then return end
		if cur.rec.trackingQuest
			and C_QuestLog.IsQuestFlaggedCompleted(cur.rec.trackingQuest) then
			MM:Print("Attempt flagged for %s — advancing the route.", cur.label)
			R:Advance()
		end
	end)
end

local function stopPoller()
	if poller then poller:Cancel() poller = nil end
end

MM:On("MM_ROUTE_STARTED", startPoller)
MM:On("MM_ROUTE_STOPPED", stopPoller)

-- Plan edits invalidate the route order.
MM:On("MM_PLAN_CHANGED", function()
	if MM.cdb.routeActive then
		R:Build()
		if #R.route == 0 then R:Stop() return end
		MM.Nav.SetWaypoint(R:Current())
		MM:Fire("MM_ROUTE_ADVANCED")
	end
end)

------------------------------------------------------------
-- /mm whynot — the goals that did NOT make the route, and why
------------------------------------------------------------
-- Requirement — we should enhance our diagnostics log to help you understand why an
-- item was not considered/path was chosen so we can optimize it as well.
--
-- Every other section reports what the addon DID. The most expensive bugs so
-- far have all been the opposite: a mount silently absent, a teleport silently
-- rejected, a weight silently ignored. Absence leaves no trace to read, so it
-- has to be reported deliberately.
--
-- Three populations, and every planned goal is in exactly one:
--   routed     it is on the route
--   deferred   we know why it cannot be worked on right now
--   unrouted   it survived planning but no stop could be built for it, which
--              is usually a missing location and always worth knowing about
MM:On("MM_WHYNOT_DEBUG", function()
	local plan = MM.Planner and MM.Planner:GetPlan() or {}
	local onRoute = {}
	for _, stop in ipairs(R.route) do
		for _, m in ipairs(stop.members or { stop }) do
			if m.entry then onRoute[m.entry] = true end
		end
	end

	MM:Print("Of %d planned goals: %d routed, %d held back, %d with nowhere to go.",
		#plan, R.totals and R.totals.stops or 0, #R.deferred, #R.unrouted)

	-- Held back, grouped by reason. The detail line is what a player reads, so
	-- one worked example per reason is worth more than a bare count.
	local byStatus, order = {}, {}
	for _, d in ipairs(R.deferred) do
		local status = d.status or "UNKNOWN"
		if not byStatus[status] then byStatus[status] = {}; order[#order + 1] = status end
		tinsert(byStatus[status], d)
	end
	table.sort(order, function(a, b) return #byStatus[a] > #byStatus[b] end)
	if #order > 0 then MM:Print("|cffffd84dHeld back:|r") end
	for _, status in ipairs(order) do
		local list = byStatus[status]
		MM:Print("  %-12s %3d   e.g. %s — %s", status, #list,
			list[1].entry.name, list[1].detail or "no detail recorded")
	end

	-- Nowhere to go. This one is nearly always a data gap rather than a
	-- decision, so it names the records: each is a fixable line in a data file.
	if #R.unrouted > 0 then
		MM:Print("|cffff9a3cNo location to route to (%d):|r", #R.unrouted)
		local shown = 0
		for _, u in ipairs(R.unrouted) do
			local entry = u.entry or u
			if entry.name then
				shown = shown + 1
				if shown <= 12 then MM:Print("     %s", entry.name) end
			end
		end
		if shown > 12 then MM:Print("     ...and %d more", shown - 12) end
		MM:Print("     Each needs a zone or vendor location in its record.")
	end

	-- Routed, but this client cannot map the zone. Different from the above:
	-- these DO have a location, the client just has no map id for it yet --
	-- Midnight 12.1 zones like the Coiled Isle are named by records months
	-- before that content goes live.
	--
	-- They stay routed because they are real, actionable goals and the player
	-- gets a zone NAME; only the arrow has nothing to point at. Travel falls
	-- back to the flat cross-continent cost, so they are never priced as free.
	--
	-- Reported because an excuse nobody can see is a silent swallow. The
	-- release gate stops calling these blockers, so this line is the only
	-- place anyone would learn they exist.
	local unmapped = {}
	for _, stop in ipairs(R.route) do
		if stop.unmappedZone then
			unmapped[#unmapped + 1] = ("%s (%s)"):format(
				stop.label or "?", stop.unmappedZone)
		end
	end
	if #unmapped > 0 then
		MM:Print("|cffffd84dRouted, but this client cannot map the zone (%d):|r",
			#unmapped)
		for i = 1, math.min(#unmapped, 8) do MM:Print("     %s", unmapped[i]) end
		if #unmapped > 8 then MM:Print("     ...and %d more", #unmapped - 8) end
		MM:Print("     Not a defect: the zone is named but has no map id on this")
		MM:Print("     client yet. You get the zone name; the arrow has nothing to")
		MM:Print("     point at, and travel is priced at the flat cross-continent")
		MM:Print("     cost rather than free.")
	end

	-- And the silent one: planned, not routed, not deferred, not unrouted.
	-- If this is ever non-zero something is losing goals, and until now it
	-- would have lost them without a word.
	local lost = {}
	for _, entry in ipairs(plan) do
		if not onRoute[entry] then
			local accounted = false
			for _, d in ipairs(R.deferred) do
				if d.entry == entry then accounted = true break end
			end
			for _, u in ipairs(R.unrouted) do
				if (u.entry or u) == entry then accounted = true break end
			end
			if not accounted then tinsert(lost, entry.name or "?") end
		end
	end
	if #lost > 0 then
		MM:Print("|cffff4444Unaccounted for (%d) — this is a bug:|r %s", #lost,
			table.concat(lost, ", ", 1, math.min(#lost, 8)))
	else
		MM:Print("Every planned goal is accounted for.")
	end
end)

------------------------------------------------------------
-- /mm timemodel — how much of the estimate is measured, and how much is a guess
------------------------------------------------------------
-- Requirement — check the optimization and realistic time/material costs to complete
-- the ordering.
--
-- The honest answer is not a number, it is a ratio. The plan says twenty days;
-- what matters is how much of that is READ from the client or from verified
-- data, and how much is a stand-in for data nobody has filled in yet. A total
-- built mostly from assumptions is not wrong, but it is not a measurement
-- either, and the difference decides whether the ordering can be trusted or
-- merely believed.
--
-- Every part carries its own provenance (`kind`), so this counts rather than
-- infers -- no string-matching labels that break the moment one is reworded.
MM:On("MM_TIMEMODEL_DEBUG", function()
	local P = MM.Planner
	if not (P and P.TimeCommitment) then return end

	local measured, assumed, total = 0, 0, 0
	local byLabel, goals = {}, 0

	for _, entry in ipairs(P:GetPlan()) do
		local minutes, parts = P.TimeCommitment(entry)
		if minutes then
			goals = goals + 1
			total = total + minutes
			for _, part in ipairs(parts or {}) do
				if part.kind == "assumed" then
					assumed = assumed + part.minutes
					-- group the standing assumptions so the biggest is obvious
					local key = tostring(part.label):gsub("%d+", "N")
					byLabel[key] = (byLabel[key] or 0) + part.minutes
				else
					measured = measured + part.minutes
				end
			end
		end
	end

	if total <= 0 then MM:Print("Nothing planned to measure.") return end
	local pct = assumed / total * 100
	MM:Print("Plan estimate: %s across %d goals.",
		MM.Util.FormatSeconds(total * 60), goals)
	MM:Print("   |cff40d860measured %s (%.0f%%)|r  ·  |cffff9a3cassumed %s (%.0f%%)|r",
		MM.Util.FormatSeconds(measured * 60), 100 - pct,
		MM.Util.FormatSeconds(assumed * 60), pct)

	local rows = {}
	for label, minutes in pairs(byLabel) do
		rows[#rows + 1] = { label = label, minutes = minutes }
	end
	table.sort(rows, function(a, b) return a.minutes > b.minutes end)
	if #rows > 0 then
		MM:Print("   Where the assumptions are:")
		for i = 1, math.min(#rows, 6) do
			MM:Print("      %-34s %s (%.0f%% of the plan)", rows[i].label,
				MM.Util.FormatSeconds(rows[i].minutes * 60),
				rows[i].minutes / total * 100)
		end
	end

	-- How much of the estimate is now COMPUTED rather than estimated.
	--
	-- Two things stopped being guesses this pass, and both deserve a number
	-- rather than a claim in a changelog: a weekly-capped currency is
	-- arithmetic, and an achievement three criteria from done is not the same
	-- job as one not started.
	local capped, uncapped, criteria, flat = 0, 0, 0, 0
	local C = MM.Conditions
	for _, entry in ipairs(P:GetPlan()) do
		for _, cond in ipairs((entry.rec and entry.rec.conditions) or {}) do
			if cond.type == "CURRENCY" and cond.id then
				if C.CurrencyWeeks and C.CurrencyWeeks(cond) then capped = capped + 1
				else uncapped = uncapped + 1 end
			elseif cond.type == "ACHIEVEMENT" and cond.id then
				local left = C.AchievementCriteriaLeft and C.AchievementCriteriaLeft(cond)
				if left then criteria = criteria + 1 else flat = flat + 1 end
			end
		end
	end
	if capped + uncapped + criteria + flat > 0 then
		MM:Print("   Computed rather than estimated:")
		MM:Print("      %d currencies have a weekly cap, so their time is arithmetic "
			.. "(%d have none)", capped, uncapped)
		MM:Print("      %d achievements are costed by criteria remaining (%d fall back "
			.. "to a flat meta)", criteria, flat)
	end

	if pct > 50 then
		MM:Print("   |cffff9a3cMore than half this estimate is a stand-in.|r The")
		MM:Print("   ORDER is still sound -- assumptions are deliberately")
		MM:Print("   pessimistic, so nothing unpriced can outrank real work --")
		MM:Print("   but the TOTAL should be read as an upper bound, not a")
		MM:Print("   forecast. /mm contribute is what shrinks it.")
	end
end)
