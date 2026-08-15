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
	-- for a later step will not talk to you yet, so that position is the wrong
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
	-- A QUEUE IS ONE ACT, HOWEVER MANY MOUNTS ROLL OFF IT.
	--
	-- Five Island Expedition mounts all drop from finishing one island: two
	-- minutes to the queue NPC, ten minutes to run it, five chances. But an
	-- island has no map to group by -- "Island Expedition" is not a zone this
	-- client resolves -- and no instance or npc name either, so every one of
	-- them fell through to `return nil` and became a stop of its own. The
	-- session then charged twelve minutes five times over for a single run,
	-- and a three-hour evening could not fit what a twelve-minute one does.
	--
	-- Checked AFTER instance and npc so a specific raid still keys on the raid
	-- rather than collapsing into "raid queue" with every other one.
	local kind = MM.Queue and MM.Queue.KindFor and MM.Queue.KindFor(rec)
	if kind then return prefix .. "Q:" .. kind end
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

-- IDENTITY OF A STOP, IN ONE PLACE.
--
-- A step carries its mount as `entry`, and `entry.spellID` is the only spellID
-- it has ever had -- makeStep never writes a `spellID` field onto the step
-- itself. Three separate places asked a step for `stop.spellID` anyway, so all
-- three silently read nil: the route anchor was never recorded, and the
-- resume-by-identity search that depends on it therefore never matched
-- anything. A rebuilt route always restarted at the top, which reads as the
-- router forgetting where you were.
local function stopSpellID(stop)
	if not stop then return nil end
	if stop.entry and stop.entry.spellID then return stop.entry.spellID end
	local first = stop.members and stop.members[1]
	return first and first.entry and first.entry.spellID or nil
end

-- Does this stop cover that goal -- as its own mount, or as one of the mounts
-- batched into it?
local function stopHolds(stop, spellID)
	if not (stop and spellID) then return false end
	if stop.entry and stop.entry.spellID == spellID then return true end
	for _, m in ipairs(stop.members or {}) do
		if m.entry and m.entry.spellID == spellID then return true end
	end
	return false
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
			-- MOUNTS ADD ONLY WHEN ONE VISIT CAN REALLY YIELD THEM ALL.
			--
			-- Five island mounts off one run genuinely add: the run rolls for
			-- each independently, so the chances are separate events.
			--
			-- Eight Vicious mounts at one vendor do NOT. They share a single
			-- underlying grind -- one Vicious Saddle buys one mount, and every
			-- saddle is another hundred wins. Summing them made a single vendor
			-- trip look like 0.8 expected mounts for fifteen minutes, the best
			-- density in the plan, which is why a 45-minute session filled with
			-- Vicious saddles.
			--
			-- A stated dropRate is a real, independent per-attempt chance and
			-- adds. Anything resting on an unread requirement is a shared
			-- grind wearing several hats, and takes the MAX instead.
			local indep = step.rec and step.rec.dropRate
			if indep then
				stop.mounts = (stop.mounts or 0) + (step.mounts or 0)
			elseif (step.mounts or 0) > (stop.mounts or 0) then
				stop.mounts = step.mounts
			end
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

-- `wantLegs` defaults to TRUE, because every caller that existed when this was
-- written needs the described route and a silent downgrade would replace real
-- directions with nothing. Only the greedy selection passes false: it compares
-- numbers and throws every candidate but one away, so building 5,400 leg
-- descriptions to discard 5,399 of them was the bulk of the freeze.
local function travelMinutes(state, step, wantLegs)
	if wantLegs == nil then wantLegs = true end
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
			-- REUSABLE BY CONSTRUCTION, on this branch.
			--
			-- MinutesFrom runs one search from the origin over the STATIC graph
			-- -- taxi and transit edges only. No teleport is ever wired into it,
			-- so an answer from it cannot have spent one, and saying so here is
			-- a fact about the search rather than a guess about the answer.
			if not wantLegs and MM.Journey.MinutesFrom then
				-- ONE SEARCH FOR THE WHOLE POOL, not one per candidate.
				--
				-- Journey.Plan runs a Dijkstra per (from, to) pair, and the
				-- greedy chain asks it for every remaining stop at every step
				-- -- O(n^2), about 5,400 searches on a 104-stop plan, all in
				-- one frame. MinutesFrom answers the question that loop is
				-- actually asking -- "from where I am now, how far is
				-- everything?" -- with a single search from the origin, cached
				-- until the origin moves.
				--
				-- EXACTLY the same numbers: it is the same Dijkstra, run once
				-- to every node instead of once per node. The route this
				-- chooses is unchanged; only the time to choose it is.
				local mins = MM.Journey.MinutesFrom(fi.name, state.x, state.y,
					state.mapID, ti.name, step.x, step.y, step.mapID)
				if mins and (not flyMinutes or mins < flyMinutes) then
					best = mins
					method = { key = "journey:" .. tostring(step.mapID), taxi = true,
						name = "multi-leg route", reusable = true }
				end
			else
				-- `state.used` GOES IN. Without it the planner re-offered the
				-- same hearthstone as the first leg of every journey in the
				-- route, and the whole plan was costed as though the player
				-- carried one charge per stop.
				local mins, legs, _, spends = MM.Journey.Plan(fi.name,
					state.x, state.y, ti.name, step.x, step.y, flyMinutes,
					state.mapID, step.mapID, state.used)
				if mins then
					best = mins
					-- `spends` COMES BACK FROM THE PLANNER, structured.
					--
					-- A journey is tagged `taxi = true` because most of one can
					-- be ridden again -- but a journey whose first leg is a
					-- hearthstone plainly spends a charge, and the only way to
					-- know that used to be to search the human-readable leg
					-- description for the word "teleport".
					method = { key = "journey:" .. tostring(step.mapID), taxi = true,
						name = MM.Journey.Describe(legs) or "multi-leg route",
						legs = legs, spends = spends, reusable = (spends == nil) }
				end
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
				if option.minutes < best then
					best = option.minutes
					-- WRAPPED, not handed out raw. `option.landing` is a row of
					-- the shared teleport snapshot; writing this leg's
					-- bookkeeping onto it would write it onto every other stop
					-- that priced the same option.
					local landing = option.landing
					method = { key = option.key, name = landing and landing.name,
						verb = landing and landing.verb,
						place = landing and landing.place,
						landing = landing, taxi = false,
						spends = { [option.key] = true }, reusable = false }
				end
				break
			end
		end
	elseif MM.Teleports and MM.Teleports.TravelMinutes then
		-- not precomputed (a caller outside Build): ask the slow way
		local mins, m = MM.Teleports.TravelMinutes(state.continent, state.world,
			step.continent, step.world, state.used)
		-- The same contract on the way out, so a caller cannot tell which path
		-- answered it. This one returns a bare landing, and a landing is a
		-- charge: it is exactly the case `not method.taxi` used to stand for.
		if m and not m.spends and m.key then
			m = { key = m.key, name = m.name, verb = m.verb, place = m.place,
				landing = m.landing or m, taxi = false,
				spends = { [m.key] = true }, reusable = false }
		end
		return mins, m
	end
	return best, method
end

-- THE ONE PLACE A LEG IS CHARGED TO THE ROUTE.
--
-- Four call sites decided this for themselves and three of them decided it
-- differently: the chart-restore path spent EVERY method including taxis and
-- journeys, the greedy path spent the placeholder from its numbers-only pass,
-- and the two measuring paths spent only bare landings. So the route was costed
-- under one rule, measured under a second and reported under a third.
--
-- `spends` is now filled in wherever a method is built, from structured data
-- rather than from the shape of a label, and this reads nothing else.
function R.SpendTravel(state, method)
	if not (state and method and method.spends) then return end
	state.used = state.used or {}
	for key in pairs(method.spends) do state.used[key] = true end
end

-- Cost ONE leg from a travel state, WITHOUT changing it.
--
-- Exposed so the session fitter prices a leg exactly the way the route does.
-- It had its own path into Teleports.TravelMinutes, which knows about teleports
-- and flying and nothing about taxis, boats or portals -- so a session and the
-- route it is a view of disagreed about the same chain, and the session was the
-- one the player was reading.
--
-- `wantLegs` false is the numbers-only form: no leg descriptions, one cached
-- search per origin instead of one Dijkstra per candidate. Anything comparing
-- candidates in a loop wants it.
function R.LegFrom(state, step, wantLegs)
	return travelMinutes(state, step, wantLegs)
end

-- Carry a travel state forward onto a step. The one owner of that transition;
-- three places used to write it out by hand and only one set every field.
function R.AdvanceTravelState(state, step)
	advanceState(state, step)
end

-- Does getting to this stop actually spend a teleport?
--
-- `stop.arriveBy` is NOT a teleport flag -- it is whatever method won, and for
-- most stops that is a multi-leg journey. Every journey is tagged `taxi = true`
-- (a taxi can be ridden again; a teleport cannot, which is the distinction the
-- router spends its charges on), so testing `arriveBy` for existence counted
-- every routed stop and reported the stop count back as a teleport count.
--
-- Two ways a stop genuinely opens with one, and BOTH have to be asked:
--   a bare landing  -- the teleport goes straight there, no journey needed
--   a journey whose first leg is a teleport -- "teleport:Hearthstone Valdrakken,
--   then portal to Orgrimmar, then fly" is the common shape, and it plainly
--   uses a charge even though the method that won is the journey
-- ASKED OF THE DATA, NOT OF THE PROSE.
--
-- This used to search the leg descriptions for a "teleport:" prefix, so the
-- answer depended on a string built for a player to read -- and the resource it
-- actually spent was not recoverable at all. Every method now carries `spends`,
-- filled in where the method is built, and this is one lookup.
function R.ArrivesByTeleport(stop)
	local m = stop and stop.arriveBy
	if not (m and m.spends) then return false end
	for _ in pairs(m.spends) do return true end
	return false
end

-- Which charges this stop's arrival costs, as a set. Empty when the trip is
-- rideable again -- a taxi, a boat, an ordinary flight.
function R.TravelSpends(stop)
	local m = stop and stop.arriveBy
	return (m and m.spends) or nil
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
		R.SpendTravel(state, method)
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
-- the player, twice: I changed a bunch of weights and priorities and nothing really
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
-- what the question was it to optimise, it front-loads the best hour for someone who
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
-- It was not, and the objection landed on exactly the wrong bit. The first version
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
-- The escape hatch matters and is the thing the player already said was reasonable:
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
-- HOW MUCH OF THE WINDOW IS LEFT, not merely that there is one.
--
-- DAILY and WEEKLY both returned URGENCY.LOCKOUT and both got the same flat
-- boost, so a weekly raid on THURSDAY -- with four days still to use it --
-- pushed as hard as one on Monday night with three hours left. And by the same
-- flatness a daily rare, whose window closes tonight, could never outrank it.
--
-- Pressure is the fraction of the window already spent: ~0 when it has just
-- reset and nothing is at stake, ~1 as it closes and the roll is about to be
-- lost. A daily six hours from reset is 75% spent; a weekly on Thursday is
-- about 43%. The daily leads, which is what "use it or lose it" actually means.
local SECONDS_DAY, SECONDS_WEEK = 86400, 604800

local function windowPressure(rec)
	if not rec then return nil end
	local cadence = rec.attempts or (rec.instance and rec.instance.lockout)
	local left, window
	if cadence == "DAILY" then
		window = SECONDS_DAY
		left = GetQuestResetTime and GetQuestResetTime() or nil
	elseif cadence == "WEEKLY" then
		window = SECONDS_WEEK
		left = C_DateAndTime and C_DateAndTime.GetSecondsUntilWeeklyReset
			and C_DateAndTime.GetSecondsUntilWeeklyReset() or nil
	else
		return nil
	end
	-- No clock from the client: fall back to treating the window as half
	-- spent. Guessing "about to close" would make every lockout scream.
	if not left or left <= 0 or left > window then return 0.5 end
	return 1 - (left / window)
end

-- Exposed so /mm can assert the scaling rather than trust it.
R.WindowPressure = windowPressure

local function urgencyBoost(s)
	local P = MM.Planner
	if not (P and s.urgency) then return 1 end
	if s.urgency == P.URGENCY.LOCKOUT then
		local W = MM.Weights
		local weight = (W and W.Get) and W.Get("urgency") or 1
		local pressure = windowPressure(s.rec)
		if pressure then return 1 + weight * pressure end
		return 1 + weight
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
-- They are lenses, not corrections to the measurement -- the rule the player set when
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
		-- A CHART WE ALREADY HAVE IS AN ORDER WE DO NOT HAVE TO RE-DERIVE.
		--
		-- This scan is the expensive part of the whole build: for every stop it
		-- prices travel to every remaining candidate -- O(n^2), roughly 5,400
		-- Journey searches on a 104-stop plan, and the reason a login froze.
		--
		-- Restoring the stored chart used to skip only the 2-opt, which for a
		-- strict-priority player does nothing at all, so the freeze survived
		-- every attempt to cache it. The decision that actually costs time is
		-- THIS one, so when a valid chart says where each stop goes, the choice
		-- is read instead of recomputed and only the winner is priced.
		local rank = R.chartRank
		if rank then
			local bi, br
			for i, s in ipairs(pool) do
				local id = s.entry and s.entry.spellID
				local r = id and rank[id]
				for _, m in ipairs(s.members or {}) do
					local mid = m.entry and m.entry.spellID
					local mr = mid and rank[mid]
					if mr and (not r or mr < r) then r = mr end
				end
				-- Anything the chart does not know keeps its place at the end.
				r = r or (1e9 + i)
				if not bi or r < br then bi, br = i, r end
			end
			local chosen = tremove(pool, bi)
			local minutes, method = travelMinutes(state, chosen)
			chosen.arriveMinutes, chosen.arriveBy = minutes, method
			tinsert(ordered, chosen)
			R.SpendTravel(state, method)
			advanceState(state, chosen)
		else

		-- Hand the frame back if we have held it too long. This is the only
		-- place that needs it: it is where the graph searches are.
		if R.ShouldYield and R.ShouldYield() then R.Yield() end

		local bestI, bestScore, bestTime, bestMethod
		for i, s in ipairs(pool) do
			-- AND INSIDE THE LOOP, WHICH IS WHERE THE TIME ACTUALLY GOES.
			--
			-- Reported from outside: "building a route fails with an error msg
			-- about the script running too long", and the client freezing until
			-- it did. The check above yields between STOPS; this loop runs one
			-- graph search per CANDIDATE, so a single pass through it is
			-- hundreds of searches with the frame held throughout. Yielding
			-- once per stop cannot help when one stop is the expensive thing.
			--
			-- It is much worse for a new player, which is exactly who was
			-- reporting it. Our own router model measures it: with no teleports
			-- a leg takes fifteen hops where a well-equipped character takes
			-- two. Same plan, an order of magnitude more search, and the
			-- yielding was tuned against the cheap case.
			--
			-- Safe to yield mid-loop: a coroutine resumes exactly here with the
			-- iterator, the accumulators and the pool all intact.
			if R.ShouldYield and R.ShouldYield() then R.Yield() end

			-- Numbers only: every candidate but one is discarded, and the
			-- winner's directions are built once, after the choice.
			local minutes, method = travelMinutes(state, s, false)
			local d = selectionScore(s, minutes * scale, s.workMinutes)
			if not bestI or d > bestScore + 1e-12
				or (d > bestScore - 1e-12 and minutes < bestTime) then
				bestI, bestScore, bestTime, bestMethod = i, d, minutes, method
			end
		end
		local nextStep = tremove(pool, bestI)
		-- NOW build the real directions -- once, for the one we chose.
		--
		-- The selection above deliberately skipped them, so bestMethod carries
		-- a placeholder name and no legs. Leaving that on the stop would trade
		-- the freeze for a route that cannot tell you how to get anywhere.
		-- One described leg per stop is 104 of them, not 5,400.
		local wMinutes, wMethod = travelMinutes(state, nextStep, true)
		nextStep.arriveMinutes = wMinutes or bestTime
		nextStep.arriveBy = wMethod or bestMethod
		tinsert(ordered, nextStep)
		-- Spending the teleport here is what makes the rest of the chain honest:
		-- a hearthstone used on leg two is not available on leg nine.
		--
		-- CHARGED FOR WHAT WAS RECORDED, not for what was shortlisted. The
		-- selection pass above runs without leg descriptions and cannot see a
		-- teleport inside a journey, so spending its placeholder charged the
		-- route for a key nothing else would ever match while the charge the
		-- stop actually carries went unspent.
		R.SpendTravel(state, nextStep.arriveBy)
		advanceState(state, nextStep)
		end
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
			-- -- a mount the player cannot afford, expected value ZERO -- was slotted
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

-- What this route was charted FOR. If none of it has moved, the route standing
-- in R.route is still the answer and re-deriving it is pure cost.
--
-- The plan is account-wide; the charted path is not. It depends on this
-- character's teleports, faction, lockouts and the anchor it was charted from,
-- so the signature carries all of those and the cache is per character.
--
-- Opening the main window re-ran the whole chart -- Journey.lua:1122 "script
-- ran too long" -- for a route that had not changed since it was built.
local function buildSignature()
	local plan = MM.cdb and MM.cdb.plan or {}
	-- SORTED, because the plan is a SET and its ORDER is an output.
	--
	-- P:Optimize rewrites cdb.plan into route order at the end of every chart.
	-- Hashing the plan in order therefore made every build change its own
	-- signature, so the stored chart could never match and every login
	-- re-charted from scratch. Sorting makes the signature depend on WHICH
	-- goals are planned, never on the order the last chart put them in.
	local ids = {}
	for i = 1, #plan do ids[i] = plan[i].spellID end
	table.sort(ids)
	local a = MM.Planner and MM.Planner.Anchor and MM.Planner.Anchor()
	local W = MM.Weights
	-- ANCHOR CELL, not anchor coordinate.
	--
	-- The anchor only moves when the plan is charted, never as the player walks,
	-- so including its position costs no churn -- but Advance re-anchors after
	-- every completed goal, often within the same zone, and the first leg is
	-- measured from it. A tenth of a zone is coarse enough that no realistic
	-- re-anchor inside one spot changes the cell, and fine enough that crossing
	-- a zone does.
	local cell = "?"
	if a and a.x and a.y then
		cell = ("%d,%d"):format(math.floor(a.x / 10), math.floor(a.y / 10))
	end
	return table.concat({
		UnitName and UnitName("player") or "?",
		GetRealmName and GetRealmName() or "?",
		-- Faction gates destinations and vendors, and the plan follows the
		-- account rather than the character, so two characters of opposite
		-- factions share a plan and must not share an order built for it.
		(UnitFactionGroup and UnitFactionGroup("player")) or "?",
		#plan, table.concat(ids, ","),
		-- The anchor's MAP, never its timestamp.
		--
		-- P:Optimize calls SetAnchor first, which stamps a fresh `at` every
		-- time -- so the signature was different on every single build and the
		-- cache could never hit. That is why logging out and back in still
		-- re-charted: the chart was being saved and then never matched.
		a and a.mapID or "?",
		cell,
		-- Session length is deliberately ABSENT. The chart is the optimal
		-- order; a session is a view applied over it by ApplySession. Folding
		-- the length in here would re-chart the whole route every time the
		-- dropdown moved, which is the churn that made a 45-minute list look
		-- like a different plan rather than a shorter one.
		--
		-- EVERY WEIGHT THAT MOVES THE CHART, not the four that were easiest to
		-- name. `era` shifts a goal by half a tier, `urgency` reorders the
		-- bands, and `orderCap` decides how far the clock may overrule layer 1
		-- -- all three changed the route and none of them changed the
		-- signature, so a saved chart built at one setting was restored at
		-- another and the slider read as doing nothing.
		--
		-- `priority` carries strict ordering with it: strictness is a pure
		-- function of that value (>= 1.45), so the threshold needs no field of
		-- its own and cannot drift away from the number it is derived from.
		W and W.Get and ("%s/%s/%s/%s/%s/%s/%s"):format(
			W.Get("travel"), W.Get("effort"), W.Get("odds"), W.Get("priority"),
			W.Get("era"), W.Get("urgency"), W.Get("orderCap")) or "w",
		-- WHICH KIND OF GOAL COMES FIRST. The tier order is a setting the player
		-- drags into place, and layer 1 is built from it.
		W and W.Order and table.concat(W.Order(), ">") or "o",
		-- What this character can travel with. See MM.TravelFingerprint: a
		-- stored chart cannot outlive the teleports it was ordered around.
		MM.TravelFingerprint and MM.TravelFingerprint() or "t?",
	}, "|")
end

-- The signature this plan and this character would chart under, without
-- charting anything.
--
-- Exposed because "does the route depend on X?" is otherwise only answerable by
-- changing X and running a full build to see whether the order moved -- which
-- is minutes of work per setting, and re-charts the player's plan to ask a
-- question about it. The cache diagnostics read it for the same reason.
function R.Signature() return buildSignature() end

-- Force the next Build to do real work: anything that changes the WORLD rather
-- than the plan (a new flight point, a teleport learned) calls this.
function R.InvalidateRouteOrder()
	-- CLEARS THE IN-MEMORY MARKER ONLY. It must NOT delete the stored chart.
	--
	-- It used to, and MM_SCANNED -- which fires on every login as the journal
	-- is read -- is wired to this. So the first thing that happened every
	-- session was the saved chart being thrown away, and it could never
	-- survive long enough to be matched. That is the whole login recalculation.
	--
	-- Deleting it was redundant anyway: the chart is only ever used when its
	-- signature matches, so a world that has genuinely changed is already
	-- rejected by the comparison. Forcing a rebuild and destroying the
	-- evidence are two different things, and only the first was wanted.
	R.builtSignature = nil
end

-- ONE BROAD INVALIDATION IS HOW THE WRONG THING GETS THROWN AWAY.
--
-- `Invalidate` was the only verb available, so every caller used it for every
-- reason and none of them could say what had actually changed. It stays as the
-- route-order name it always meant, because that is what its callers meant.
R.Invalidate = R.InvalidateRouteOrder

-- The ANSWERS about travel are stale, the MAP is not. A teleport gained, lost
-- or switched off changes which routes are legal without moving a single node,
-- so the graph -- 29,000 within-zone edges, 1,360 transit links and 4,068 taxi
-- hops -- is kept and only the cached journeys are dropped.
function R.InvalidateTravelPlans()
	local J = MM.Journey
	if J and J.ForgetPlans then J.ForgetPlans() end
	if J and J.ForgetTravelFrom then J.ForgetTravelFrom() end
	local TP = MM.Teleports
	if TP and TP.Refresh then TP.Refresh() end
	if TP and TP.ForgetArrivals then TP.ForgetArrivals() end
end

-- The MAP itself moved: a flight point learned, a node added. This is the
-- expensive one, and the only reason to keep it separate from the above.
function R.InvalidateTravelTopology()
	local J = MM.Journey
	if J and J.Forget then J.Forget() end
end

-- The finished order, as spellIDs, keyed by the signature it was charted for.
-- Only the SEQUENCE is stored: everything else about a stop is derived from the
-- database on load and would be stale the moment anything moved.
-- `S` is the state being charted: the stage during a build, the live router
-- otherwise. The result is STORED ON THE STATE rather than written straight to
-- saved variables, so a build that throws after this point cannot leave a chart
-- behind describing a route that was never published.
function R.SaveChart(sig, S)
	S = S or R
	if not (MM.cdb and sig and #S.route > 0) then return end
	local stops = {}
	for _, stop in ipairs(S.route) do
		local ids = {}
		for _, m in ipairs(stop.members or { stop }) do
			if m.entry and m.entry.spellID then ids[#ids + 1] = m.entry.spellID end
		end
		if #ids > 0 then stops[#stops + 1] = ids end
	end
	S.chart = { sig = sig, stops = stops }
	-- The live router has no publication step of its own, so a direct call
	-- still commits. Only a staged build defers.
	if S == R then MM.cdb.chart = S.chart end
end

-- Reorder the freshly built stops into the stored sequence. Returns false when
-- there is nothing valid to restore, and the caller then charts for real.
--
-- Anything the stored order does not mention keeps its relative place at the
-- END rather than being dropped -- a goal added since must still appear, and
-- silently losing one would be far worse than charting it in the wrong slot.
function R.RestoreChart(sig, S)
	S = S or R
	local chart = MM.cdb and MM.cdb.chart
	if not (chart and sig and chart.sig == sig and chart.stops) then return false end
	local rank = {}
	for i, ids in ipairs(chart.stops) do
		for _, spellID in ipairs(ids) do
			if rank[spellID] == nil then rank[spellID] = i end
		end
	end
	local order, seen = {}, 0
	for i, stop in ipairs(S.route) do
		local best
		for _, m in ipairs(stop.members or { stop }) do
			local r = m.entry and rank[m.entry.spellID]
			if r and (not best or r < best) then best = r end
		end
		if best then seen = seen + 1 end
		-- Unknown stops sort after everything known, in the order they arrived.
		order[stop] = best or (#chart.stops + i)
	end
	-- A chart that matches almost nothing is not worth trusting.
	if seen == 0 then return false end
	table.sort(S.route, function(a, b) return order[a] < order[b] end)
	S.restoredChart = seen
	return true
end

-- CHUNKED, IN ONE PLACE, FOR EVERY CALLER.
--
-- Charting a large plan is thousands of graph searches in a single frame, and
-- the client simply stops until it finishes. Rather than ask each of the seven
-- call sites to opt in -- which is how this gets missed the next time one is
-- added -- the yielding lives inside Build itself.
--
-- The body runs as a coroutine. nearestChain, where the searches actually are,
-- hands the frame back whenever it has held it for longer than the budget, and
-- a ticker resumes it. Every caller keeps calling R:Build() exactly as before.
--
-- A CALLER THAT NEEDS THE ANSWER NOW asks for it: Build takes `sync`, and the
-- session fitter, the router model and the checks all pass it. Everything else
-- is chunked, whatever the plan's size.
--
-- There was a CHUNK_FROM_STOPS threshold here, documented as "small plans stay
-- synchronous". It was declared and never read -- `chunked` is set true
-- unconditionally further down -- so for its whole life it described a rule the
-- code did not have. Removed rather than implemented: a stop count is the wrong
-- proxy anyway. What costs time is how hard each leg is to search, and a small
-- plan on a character with no teleports is far more work than a large one on a
-- character with eighteen.
local CHUNK_MS = 24            -- frame budget before handing control back
local building                 -- the coroutine, while one is in flight

-- TWO SIGNATURES, BECAUSE THERE ARE TWO QUESTIONS.
--
-- `R.builtSignature` answers "what is the route currently on screen?" and is
-- written in exactly one place: R.Publish. `activeBuildSignature` answers "what
-- is the build in flight producing?" and is private to this file.
--
-- They were one field, so starting a build immediately overwrote the published
-- answer with a promise -- and a build that then failed or was superseded had
-- to clear it, throwing away the description of a route that was still on
-- screen and perfectly valid. The route survived the failure; the record of
-- what it was did not.
local activeBuildSignature

-- Called from inside the chain: true when we have held the frame long enough.
function R.ShouldYield()
	if not (building and R.chunkStartedAt and debugprofilestop) then return false end
	return (debugprofilestop() - R.chunkStartedAt) > CHUNK_MS
end

function R.Yield()
	-- NOT coroutine.isyieldable(): that is Lua 5.2+, and WoW is 5.1. Calling it
	-- threw "attempt to call a nil value" on every build, which emptied the
	-- plan. `coroutine.running()` returns the current coroutine (or nil on the
	-- main thread) in 5.1, which is the same question asked in the dialect we
	-- actually run in.
	if building and coroutine.running() then
		-- Counted so the report can show the frame really was handed back.
		-- "The client did not freeze" is not evidence on a fast machine with a
		-- small plan; a yield count is.
		R.yieldsThisBuild = (R.yieldsThisBuild or 0) + 1
		coroutine.yield()
		R.chunkStartedAt = debugprofilestop and debugprofilestop() or 0
	end
end

-- True while a chunked build is still in flight.
--
-- Chunking made Build return before the route exists, so a caller that renders
-- immediately draws the PREVIOUS route -- and after Clear Plan the previous
-- route is empty. The planner showed "your farm plan is empty" over a plan of
-- 286 goals, and switching tabs fixed it because that re-rendered after the
-- build had finished. Anything that draws the route needs to be able to ask.
function R.IsBuilding()
	return building ~= nil and coroutine.status(building) == "suspended"
end

------------------------------------------------------------
-- The build contract
------------------------------------------------------------
-- BUILD RETURNS A STATUS, NEVER A COUNT.
--
-- It used to return nothing at all, and Start formatted that nothing with %d.
-- The count is not knowable at the moment an asynchronous build is requested,
-- so returning one is a promise the function cannot keep. Every caller that
-- needs the number now asks for it through BuildSync, and every caller that
-- can wait asks for it through AfterBuild.
R.BUILD_CURRENT   = "current"    -- cache hit: the route already is this plan's
R.BUILD_STARTED   = "started"    -- a fresh build is in flight
R.BUILD_QUEUED    = "queued"     -- one was running; a replacement is queued
R.BUILD_RUNNING   = "running"    -- one was already running and still stands
R.BUILD_COMPLETED = "completed"  -- driven to completion before returning

-- One-shot callbacks waiting on the CURRENT build. Held in slot tables so the
-- same function can wait twice without one removal cancelling both.
local pendingCompletion = {}

-- Everything that happens when a build lands, in one place.
--
-- `ok` is false when the coroutine threw. Waiters are released either way --
-- a caller blocked forever on a failed build is a hang, and the failure has
-- already been reported -- but the completion event is not fired, because
-- nothing new was built for anyone to redraw.
local function finishBuild(ok)
	R.buildFailed = not ok
	local waiting = pendingCompletion
	pendingCompletion = {}
	local stops = #R.route
	for i = 1, #waiting do
		local fine, err = pcall(waiting[i].fn, stops, ok)
		if not fine and MM.Print then
			MM:Print("|cffff5555route completion handler failed|r -- %s",
				tostring(err):sub(-140))
		end
	end
	if ok then MM:Fire("MM_ROUTE_BUILT", stops, R.builtSignature) end
end

-- Resume the in-flight build one slice. Recursive through R:Build, which is how
-- a queued replacement is picked up without duplicating the completion rules.
local pumpBuild
pumpBuild = function(sync)
	if not building then return end
	R.chunkStartedAt = debugprofilestop and debugprofilestop() or 0
	local ok, err = coroutine.resume(building)
	if not ok then
		building = nil
		R.rebuildWhenDone, R.rebuildForced = nil, nil
		-- ONLY THE IN-FLIGHT SIGNATURE GOES. `R.builtSignature` still describes
		-- the route on screen, which a failed build never replaced, and the
		-- cache guard compares the request against THAT -- so a plan that has
		-- moved still misses and charts for real, while a plan that has not
		-- still hits. Clearing it here threw away a true statement.
		--
		-- `builtRouteCount` is kept for the same reason. `chartRank` goes back
		-- to nil, which is exactly its value between builds, so a failure
		-- leaves no field holding something a completed build would not.
		activeBuildSignature = nil
		R.chartRank = nil
		if MM.Print then MM:Print("|cffff5555route build failed|r -- %s",
			tostring(err):sub(-140)) end
		finishBuild(false)
		return
	end
	if coroutine.status(building) == "dead" then
		building = nil
		-- AN OBSOLETE BUILD DOES NOT ANNOUNCE ITSELF.
		--
		-- Its inputs changed while it ran, so its route is already wrong. It
		-- hands straight over to the replacement, and the waiters stay queued
		-- for that one -- which is the build whose result they asked for.
		if R.rebuildWhenDone then
			local forced = R.rebuildForced
			R.rebuildWhenDone, R.rebuildForced = nil, nil
			-- Same rule as the failure path: only the in-flight signature goes.
			-- The published one still describes the route on screen, which a
			-- superseded build never replaced.
			activeBuildSignature = nil
			R.chartRank = nil
			R:Build(forced, sync)
			return
		end
		finishBuild(true)
		return
	end
	-- Only the chunked path schedules itself. A synchronous caller is already
	-- looping on this, and a timer as well would drive the same coroutine twice.
	if not sync then C_Timer.After(0, function() pumpBuild(false) end) end
end

-- Drive whatever is in flight to completion, including any replacement it
-- queues on the way out.
local function drain()
	local guard = 0
	while building and coroutine.status(building) == "suspended" do
		pumpBuild(true)
		-- A replacement re-enters Build, which drives itself to completion and
		-- clears `building`; the loop then ends. The guard is a backstop against
		-- a pathological chain of replacements, not an expected path.
		guard = guard + 1
		if guard > 10000 then break end
	end
	building = nil
end

-- Drive a build to completion before returning, and answer with the number of
-- stops it produced.
--
-- Chunking makes Build return with the work still in flight, which is right for
-- the game -- the previous route stays on screen and the frame is handed back --
-- and wrong for anything that asks a question about the result on the very next
-- line. The checks and the router model both do exactly that: build, then
-- measure what was built. Without this they would measure the PREVIOUS route and
-- quietly report on the wrong thing.
function R:BuildSync(force)
	self:Build(force, true)
	-- Belt and braces: Build(sync) only returns with `building` cleared, so this
	-- is an assertion that the contract held rather than a loop that runs.
	if R.IsBuilding() then drain() end
	return #R.route
end

-- Run `fn(stops, ok)` when the route is complete and current, without freezing
-- the frame to get there.
--
-- THE CALLBACK IS REGISTERED BEFORE THE BUILD IS ASKED FOR. A small plan can
-- finish inside its first slice, so a callback added afterwards would have
-- missed the very completion it was waiting for.
function R.AfterBuild(force, fn)
	if not fn then return R:Build(force) end
	local slot = { fn = fn }
	pendingCompletion[#pendingCompletion + 1] = slot
	local status = R:Build(force)
	if status ~= R.BUILD_CURRENT then return status end
	-- Nothing to wait for: the route already is this plan's route, so the slot
	-- comes back out and the answer is given now rather than at the next build.
	for i = #pendingCompletion, 1, -1 do
		if pendingCompletion[i] == slot then table.remove(pendingCompletion, i) break end
	end
	fn(#R.route, true)
	return status
end

-- ONE BUILD FOR A WHOLE REPORT.
--
-- Several report sections each need a completed route, and each asking for one
-- separately is several chances to chart the same plan twice -- and, before the
-- contract existed, several chances to describe a different route from the one
-- the section above described. Warming once up front means every section after
-- it takes a cache hit and they all describe the same route.
function R.Warm()
	return R:BuildSync()
end

function R:Build(force, sync)
	-- A build already in flight owns R.route; asking again just lets it finish.
	--
	-- BUT THE ASK IS NOT DISCARDED. Letting it finish is right when nothing has
	-- changed and wrong when something has: Clear Plan during a build was
	-- dropped entirely, so the in-flight build completed against the OLD plan,
	-- announced itself, and the planner drew a route for mounts that were no
	-- longer planned. The compact list was right because it reads the plan
	-- rather than the route.
	--
	-- So a request that arrives mid-build is remembered and re-issued when the
	-- current one lands.
	if building and coroutine.status(building) == "suspended" then
		local queued = R.rebuildWhenDone
		-- AGAINST THE BUILD IN FLIGHT, not against what is published. The
		-- question here is whether the running build will still produce the
		-- right answer, and only its own signature can say.
		if force or buildSignature() ~= activeBuildSignature then
			R.rebuildWhenDone = true
			-- A FORCED REQUEST STAYS FORCED ACROSS THE QUEUE.
			--
			-- The re-issue below always asked for an unforced build, so a
			-- forced rebuild that arrived mid-build was remembered and then
			-- quietly downgraded: if the signature had not changed, the
			-- replacement took a cache hit and the work never happened. The
			-- caller was told a rebuild was queued and got nothing.
			if force then R.rebuildForced = true end
			queued = true
		end
		-- A SYNCHRONOUS CALLER DRAINS WHAT IS ALREADY RUNNING.
		--
		-- Returning here left the coroutine suspended and handed the caller the
		-- PREVIOUS route -- the exact failure BuildSync exists to prevent, and
		-- invisible because it only happens when a build is already in flight.
		-- Draining also picks up the replacement queued just above, so a sync
		-- caller that arrives mid-build still measures the plan it asked about.
		if sync then
			drain()
			return R.BUILD_COMPLETED
		end
		return queued and R.BUILD_QUEUED or R.BUILD_RUNNING
	end
	local sig = buildSignature()
	-- THE SIGNATURE DESCRIBES THE PLAN. IT DOES NOT DESCRIBE THE ROUTE.
	--
	-- Matching signature was taken as proof that R.route was still the route
	-- this signature built, and nothing enforced that. Anything which replaced
	-- the route without touching the signature got a cache hit on a route that
	-- was no longer there:
	--
	--   the router model swapped in its six-goal sample, and its restoring
	--   Build returned early -- so the planner showed six mounts, not a hundred
	--   the speed check timed that same early return and reported 0 ms in a run
	--   where the route section said 1483 ms
	--
	-- Both were fixed by clearing the signature by hand at the call site, which
	-- is a fix that has to be repeated by every future caller and was already
	-- missed twice. So the guard now also checks that the route is the SIZE the
	-- build left it. A swapped route almost never has the same stop count, and
	-- when it does it is the same length of work anyway.
	--
	-- This does not make the signature honest, it makes the guard suspicious,
	-- which is the property that was actually missing.
	if not force and R.builtSignature == sig and #R.route > 0
		and R.builtRouteCount == #R.route then
		return R.BUILD_CURRENT
	end
	-- SAY WHY, when it did not hit.
	--
	-- Four rounds went on inferring why the cache missed. A cache that cannot
	-- explain itself is a cache nobody can fix, so it names the component that
	-- differed instead of leaving it to be guessed at.
	local stored = MM.cdb and MM.cdb.chart
	R.cacheWhy = nil
	if not stored then
		R.cacheWhy = "no chart stored for this character yet"
	elseif stored.sig ~= sig then
		local was, now = {}, {}
		for part in tostring(stored.sig):gmatch("[^|]*") do was[#was + 1] = part end
		for part in sig:gmatch("[^|]*") do now[#now + 1] = part end
		-- IN THE SAME ORDER AS buildSignature CONCATENATES THEM. A label list
		-- that has drifted from the fields names the wrong component, which is
		-- worse than naming none: the cache explains itself to whoever is
		-- trying to work out why it missed.
		local LABEL = { "character", "realm", "faction", "plan size",
			"plan contents", "anchor map", "anchor cell", "weights",
			"tier order", "travel options" }
		for i = 1, math.max(#was, #now) do
			if was[i] ~= now[i] then
				R.cacheWhy = ("%s changed (%s -> %s)"):format(
					LABEL[i] or ("field " .. i),
					tostring(was[i]):sub(1, 24), tostring(now[i]):sub(1, 24))
				break
			end
		end
		R.cacheWhy = R.cacheWhy or "signature differs"
	end

	activeBuildSignature = sig
	-- `R.builtSignature` IS NOT TOUCHED HERE. It describes the route on screen,
	-- which this build has not replaced yet; R.Publish is the only writer.
	-- `builtRouteCount` IS NOT TOUCHED HERE.
	--
	-- It describes the route currently on screen, which this build has not
	-- replaced yet and may never replace. Nulling it at the start was a write to
	-- published state before a single step of work had run -- so a build that
	-- failed left the last good route reporting a length it no longer had.
	--
	-- Nulling it was load-bearing for exactly one case: a failed build must not
	-- then take a cache hit under the signature it had already claimed. Clearing
	-- the SIGNATURE on failure and on supersession covers that case at its
	-- source, and leaves the count describing the thing it actually describes.
	-- The build's own count is published with the rest of its state.

	R.chunkStartedAt = debugprofilestop and debugprofilestop() or 0
	R.yieldsThisBuild = 0
	building = coroutine.create(function() R.RunBuild(sig) end)
	-- CHUNKING IS ON.
	--
	-- It was off because RunBuild cleared R.route before it refilled it, so any
	-- reader during a chunked build -- opening the window, a plan edit, a scan
	-- -- saw an empty or half-filled route and drew it. A plan that loses its
	-- goals is far worse than one that takes a moment to appear, so the whole
	-- build ran in a single frame instead, and froze the client for a second
	-- and a half.
	--
	-- The route is now assembled into a LOCAL list and swapped into R.route in
	-- one go, after every yield is behind it. During a build a reader sees the
	-- PREVIOUS complete route rather than a partial one: an answer that is one
	-- build stale, which is a far better thing to show than an empty list, and
	-- briefer than the freeze it replaces.
	--
	-- The frame budget is CHUNK_MS, checked in nearestChain, which is where the
	-- graph searches are and the only place that yields.
	if not sync then
		pumpBuild(false)
		-- STARTED even if that first slice happened to finish it: the caller
		-- asked for a build and got one. A caller that needs to know when it
		-- landed uses AfterBuild, which registers before this point precisely
		-- so a one-slice build cannot outrun it.
		return R.BUILD_STARTED
	end
	-- Drive it to completion before returning, so a caller that measures on the
	-- next line measures what it just asked for.
	drain()
	return R.BUILD_COMPLETED
end

------------------------------------------------------------
-- Staged builds: nothing is published until everything succeeded
------------------------------------------------------------
-- THE ROUTE WAS ATOMIC AND ITS COMPANIONS WERE NOT.
--
-- R.route was swapped in one go, which is why a chunked build never showed a
-- half-ordered list. But `unrouted` and `deferred` were wiped at the TOP of the
-- build and refilled a goal at a time, while the previous route was still on
-- screen -- so for the whole expensive middle of a build the planner could read
-- a complete route alongside empty companion lists, and report "0 with nowhere
-- to go" over a route that had 40.
--
-- Worse, publication happened before the failure-prone work. The route went
-- live and THEN the chart restore, the 2-opt, the preference cap, Measure and
-- the session view ran. Any of those throwing left the new order published with
-- no totals and a stale index -- and destroyed the last good route, even though
-- the build reported failure and fired no completion.
--
-- So a build now assembles into a STAGE and publishes once, at the end. The
-- field names match the ones on R deliberately: every helper below takes the
-- stage or the live router and cannot tell the difference.
local function newStage()
	return {
		route = {}, unrouted = {}, deferred = {}, stopBySpell = {},
		totals = nil, baseOrder = nil, builtRouteCount = nil,
		restoredChart = nil, capReport = nil, pinReport = nil,
		blocksSkipped = nil, timeSaved = nil, lastBuildMs = nil,
		travelPrecomputed = nil, hereDebug = nil,
		-- What this build charted for. Published as the description of the
		-- route it publishes, and never before.
		builtSignature = nil,
		-- The session view's own bookkeeping. `planned` is read by the monitor
		-- and the plan pane as "how many stops this session promises", so it
		-- cannot be written before the stops it counts exist.
		sessionState = nil, sessionPlanned = nil,
		-- Deferred side effects. Saved variables are published state too: a
		-- chart written by a build that then threw would outlive the route it
		-- describes and be restored on the next login.
		chart = nil, routeIndex = nil, dropRouteGoal = false,
		applySession = nil,
	}
end

-- Scalar derived state, published with the lists rather than as it is computed.
local STAGED_FIELDS = {
	"totals", "baseOrder", "builtRouteCount", "restoredChart", "capReport",
	"pinReport", "blocksSkipped", "timeSaved", "lastBuildMs", "travelPrecomputed",
	"hereDebug", "builtSignature",
}

-- The single moment a build becomes visible.
function R.Publish(stage)
	if not stage then return #R.route end
	-- CONTENTS, NOT THE TABLE. R.route, R.unrouted, R.deferred and
	-- R.stopBySpell are module tables other files hold direct references to;
	-- assigning a new table would leave every one of those references pointing
	-- at the previous build for the rest of the session.
	wipe(R.route)
	for i = 1, #stage.route do R.route[i] = stage.route[i] end
	wipe(R.unrouted)
	for i = 1, #stage.unrouted do R.unrouted[i] = stage.unrouted[i] end
	wipe(R.deferred)
	for i = 1, #stage.deferred do R.deferred[i] = stage.deferred[i] end
	wipe(R.stopBySpell)
	for k, v in pairs(stage.stopBySpell) do R.stopBySpell[k] = v end
	for _, key in ipairs(STAGED_FIELDS) do R[key] = stage[key] end
	R.ApplySession = stage.applySession

	-- The session view's promise, committed with the route it is a view OF.
	-- Applying a session to a stage used to write this straight onto the live
	-- session object, so the monitor could be told "7 stops this session"
	-- against a route that did not exist yet -- and keep that number if the
	-- build then failed.
	if stage.sessionState then
		stage.sessionState.planned = stage.sessionPlanned
	end

	-- Saved variables last, and only now: the chart describes the order being
	-- published on the line above, and the index points into it.
	if stage.chart and MM.cdb then MM.cdb.chart = stage.chart end
	if stage.dropRouteGoal and MM.db then MM.db.routeGoal = nil end
	if stage.routeIndex and MM.cdb then MM.cdb.routeIndex = stage.routeIndex end
	return #R.route
end

function R.RunBuild(sig)
	-- A stored chart for THIS signature means the order is already decided.
	-- nearestChain reads it instead of re-deriving it, which is where the
	-- login freeze actually lived -- the 2-opt skip never touched it.
	--
	-- DELIBERATELY NOT STAGED, and the one field in this function that is not.
	-- It is an INPUT read out of saved variables, not anything derived from the
	-- route being built, and nothing outside the router reads it for
	-- information -- the model and the checks only clear it to force real work.
	-- Threading it through nearestChain and routePool to stage a value nobody
	-- observes would put a parameter on the hot path for nothing.
	--
	-- Its invariant instead: NIL EXCEPT DURING A BUILD. Set here, cleared at
	-- publication, and cleared again on failure and on supersession -- so no
	-- path can leave it holding a value from a build that never published.
	R.chartRank = nil
	local stored = MM.cdb and MM.cdb.chart
	if stored and stored.sig == sig and stored.stops then
		local rank = {}
		for i, ids in ipairs(stored.stops) do
			for _, spellID in ipairs(ids) do
				if rank[spellID] == nil then rank[spellID] = i end
			end
		end
		R.chartRank = rank
	end
	local startedAt = debugprofilestop and debugprofilestop() or nil
	-- NOTHING PUBLISHED IS TOUCHED FROM HERE UNTIL R.Publish AT THE BOTTOM.
	--
	-- The route was already assembled into a local and swapped in one go, which
	-- is why a chunked build never showed a half-ordered list. Its companions
	-- were not: `unrouted` and `deferred` were wiped HERE and refilled a goal at
	-- a time across every yield, so a reader during a build saw the previous
	-- complete route beside empty companion lists.
	--
	-- The stage holds all of it. A reader during a build sees the PREVIOUS
	-- build, whole and self-consistent -- one build stale, which is a far better
	-- answer than a mixture of two, and briefer than the freeze it replaces.
	local stage = newStage()

	-- Refresh the travel snapshot ONCE for this whole build. Every travel-time
	-- question below then reads a plain table instead of the toybox.
	if MM.Teleports and MM.Teleports.Refresh then MM.Teleports.Refresh() end

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
			tinsert(stage.deferred, { entry = entry, status = status, detail = detail })
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
			tinsert(stage.deferred, { entry = entry, status = "PREREQ",
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
				tinsert(stage.unrouted, entry)
			end
		end
	end

	-- Every travel question from here down reads these, not the toybox.
	R.PrecomputeTravel(pending)
	stage.travelPrecomputed = #pending

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
		-- Cleared every build. The flag means "you are standing here NOW", and
		-- a stop object that survives into a build made somewhere else would
		-- otherwise stay pinned to the front of a route in another hemisphere.
		stop.hereNow = nil
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
			stop.hereNow = true
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
	-- STAGED. This is a diagnostic ABOUT the route being built, so publishing it
	-- while the previous route is still on screen described one route with the
	-- other's numbers -- and a failed build left the report explaining a route
	-- that was never published.
	stage.hereDebug = {
		playerMap = playerMap,
		promoted = #nearby,
		candidates = #grouped,
	}

	-- SPINE: only what genuinely disappears. Everything else has to earn its
	-- place on the score, which is what lets a preset change the answer.
	local cursor = playerWorld
	local chain
	chain, cursor = routePool(bands[1], playerContinent, cursor)
	-- ASSEMBLED INTO A LOCAL, swapped in at the end.
	--
	-- The two routePool calls below also run graph searches, and those YIELD.
	-- Filling R.route as we go would put a half-built plan on screen across
	-- every one of those yields, which is the failure that kept chunking off.
	local built = {}
	for _, s in ipairs(chain) do tinsert(built, s) end
	for _, s in ipairs(nearby) do
		tinsert(built, s)
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
	for _, s in ipairs(main) do tinsert(built, s) end

	-- WEAVE: rare spawns slotted in wherever they cost the least detour. This is
	-- genuine opportunism -- something you pass on the way -- and nothing else.
	--
	-- Stands down under strict ordering, for the same reason clustering and the
	-- block reorder do: insertion knows nothing about rank, so it is the fourth
	-- thing that would quietly overrule "order rules".
	local leftovers = opportunistic
	if not strictOrdering() then
		table.sort(opportunistic, function(a, b) return R.StopValue(a) > R.StopValue(b) end)
		leftovers = weaveOpportunistic(built, opportunistic, playerWorld, playerContinent)
	end

	-- Whatever could not ride along still belongs in the sequence.
	local tail = routePool(leftovers, playerContinent, cursor)
	for _, s in ipairs(tail) do tinsert(built, s) end

	-- Into the STAGE, not into the route. Every yield is behind us, but the
	-- failure-prone work is still ahead: the chart restore, the 2-opt, the
	-- preference cap, Measure, the session view. Publishing here meant any of
	-- those throwing left the new order live with no totals and a stale index,
	-- having already destroyed the last route that worked.
	for _, s in ipairs(built) do tinsert(stage.route, s) end

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
		while i <= #stage.route do
			local s = stage.route[i]
			local m = s and s.mapID
			local e = m and blockEnd[m]
			if e and e < i - 1 and s.urgency > MM.Planner.URGENCY.EXPIRING
				and shortWork(s) then
				tremove(stage.route, i)
				tinsert(stage.route, e + 1, s)
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
	-- `into` is the state being reordered: the STAGE while a build is running,
	-- and the live router afterwards, when MM_SESSION_CHANGED re-applies the
	-- view without re-charting. Defaulting to R keeps every existing caller --
	-- Session.Start and the session-changed handler -- working unchanged.
	stage.applySession = function(into)
		into = into or R
		local S = MM.Session
		-- THE BASE ORDER IS NEVER OVERWRITTEN.
		--
		-- This reordered the route in place, so the session's order became the
		-- only order there was: going back to "No limit" had nothing to return
		-- to. The un-sessioned order is kept aside and every application starts
		-- from it, so a session is a view that can always be closed.
		if into.baseOrder then
			wipe(into.route)
			for _, stop in ipairs(into.baseOrder) do into.route[#into.route + 1] = stop end
		end
		local st = S and S.Active and S.Active()
		if not (st and S.Fit and into.route and #into.route > 0) then return end
		-- THE ROUTE IT IS FITTING GOES IN.
		--
		-- Session.Fit read MM.Router.route directly, so applying a session to a
		-- staged build fitted against the PUBLISHED one -- the previous route --
		-- and then reordered the staged route by the answer.
		local chosen = S.Fit(st.minutes, into.route)
		if not chosen or #chosen == 0 then return end
		-- S.Fit RETURNS WRAPPERS, NOT STOPS.
		--
		-- Each entry is { stop = <the stop>, travel = n, at = n }. This treated
		-- them as stops, so two things broke at once: `inSession` was keyed on
		-- wrappers and never matched a real stop, and the wrappers themselves
		-- were pushed into R.route.
		--
		-- A wrapper has no `members`, so the UI's `step.members or { step }`
		-- fell back to a single row -- which is why five Island Expedition
		-- mounts sat at stop 1 with no session limit and split into stops 1, 2
		-- and 3 the moment one was set. Nothing was ungrouping them; the group
		-- was being replaced by a table that never had one.
		local inSession = {}
		for _, sel in ipairs(chosen) do inSession[sel.stop] = true end
		local rest = {}
		for _, stop in ipairs(into.route) do
			if not inSession[stop] then rest[#rest + 1] = stop end
		end
		wipe(into.route)
		for _, sel in ipairs(chosen) do into.route[#into.route + 1] = sel.stop end
		for _, stop in ipairs(rest) do into.route[#into.route + 1] = stop end
		-- THE PROMISE IS COMMITTED WITH THE ROUTE IT DESCRIBES.
		--
		-- `st.planned` is live session state: the monitor reads it as "goal N of
		-- PLANNED" and the plan pane hides everything past it. Writing it while
		-- a build was still staging announced a count for stops that did not
		-- exist yet, and left that count behind if the build then failed.
		--
		-- Applied to the LIVE router -- which is what MM_SESSION_CHANGED does,
		-- re-applying the view over a route that is already published -- there
		-- is nothing to wait for and it commits immediately, exactly as before.
		if into == R then
			st.planned = #chosen
		else
			into.sessionState, into.sessionPlanned = st, #chosen
		end
	end

	-- Goals with no map location still belong in the sequence — otherwise
	-- skipping through the route "finishes" while they sit unvisited.
	table.sort(stage.unrouted, function(a, b)
		return MM.Planner.SessionScore(a) < MM.Planner.SessionScore(b)
	end)
	for _, entry in ipairs(stage.unrouted) do
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
		tinsert(stage.route, stop)
	end

	table.sort(stage.deferred, function(a, b) return a.entry.name < b.entry.name end)

	------------------------------------------------------------
	-- LAYER 3: the clock
	------------------------------------------------------------
	-- The final adjudicator. It respects preference -- that is what
	-- selectionScore carries -- but it is not bound by it, and where the two
	-- disagree the clock wins. Total plan time is the objective.
	-- THE ORDER SURVIVES A LOGOUT.
	--
	-- R.builtSignature is a Lua local, so a reload wiped it and an unchanged
	-- plan on the same character re-charted from scratch at every login --
	-- "Journey.lua: script ran too long" for a decision that had already been
	-- made two minutes earlier.
	--
	-- Deciding the order is the expensive part; the order itself is a list of
	-- spellIDs. So it is written to the CHARACTER's saved variables (the plan
	-- is account-wide, the chart is not -- it depends on this character's
	-- teleports, faction and lockouts) and restored when the signature still
	-- matches. Restoring skips the 2-opt entirely, which is where the Dijkstras
	-- live.
	if not R.RestoreChart(sig, stage) then
		R.ImproveTotalTime(playerContinent, playerWorld, stage)
	end
	R.ApplyPreferenceCap(stage)
	R.PinHereNow(stage)
	for i, stop in ipairs(stage.route) do stop.layerRouted = i end
	-- The route is final here. Recording its length now is what lets the next
	-- Build tell "nothing changed" from "someone replaced my route".
	stage.builtRouteCount = #stage.route
	R.Measure(stage)

	-- Index the finished route so a goal can be asked what it was batched with.
	-- Built here rather than searched on demand: the tooltip asks per row, and
	-- rescanning the route for every hover is work we already did once.
	R.Reindex(stage)

	-- The session's promise, applied AFTER every other layer and after the
	-- stopBySpell index is built -- it only reorders, so the index stays valid.
	-- Persist BEFORE the session reorder, not after: the session is a view of
	-- the chart, not the chart. Storing the session's order would make the
	-- restored route depend on whatever length happened to be picked last.
	-- Charting is done: stop reading the old order, and record the new one.
	R.chartRank = nil
	-- STAGED, not written. MM.cdb.chart is saved-variable state: a chart
	-- written by a build that then threw would outlive the route it describes
	-- and be restored on the next login, under a signature that matches.
	R.SaveChart(sig, stage)
	-- Snapshot BEFORE ApplySession, so the view always has something to
	-- restore to without rebuilding anything.
	stage.baseOrder = {}
	for i, stop in ipairs(stage.route) do stage.baseOrder[i] = stop end

	if stage.applySession then stage.applySession(stage) end

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
	-- DECIDED HERE, WRITTEN AT PUBLICATION. The index points into the route
	-- being published; writing it before the route exists would leave it
	-- pointing into the previous one if anything below threw.
	local goal = MM.db and MM.db.routeGoal
	if goal then
		local found
		for i, stop in ipairs(stage.route) do
			if stopHolds(stop, goal) then found = i break end
		end
		if found then
			stage.routeIndex = found
		else
			-- The anchored goal is gone -- collected, unplanned, or blocked for
			-- whoever this is. Dropping the anchor was right and leaving the
			-- INDEX where it was, was not: it still pointed into the old route,
			-- so a rebuilt plan led with one goal and the arrow with another.
			stage.dropRouteGoal = true
			stage.routeIndex = 1
		end
	elseif MM.cdb and MM.cdb.routeIndex ~= 1 then
		-- Never anchored at all -- a fresh plan, or one just cleared. There is
		-- nothing to resume TO, so the route starts where it reads: the top.
		stage.routeIndex = 1
	end

	if (stage.routeIndex or (MM.cdb and MM.cdb.routeIndex) or 1) > #stage.route then
		stage.routeIndex = 1
	end
	-- Measured, not assumed. A route build froze the client for minutes and
	-- nothing in the addon could say so.
	if startedAt then stage.lastBuildMs = debugprofilestop() - startedAt end
	stage.builtSignature = sig

	-- SUPERSEDED BUILDS DO NOT PUBLISH.
	--
	-- Its inputs changed while it ran, so this order is already known to be
	-- wrong. Publishing it would put a route for the previous plan on screen
	-- for the length of one more build -- and the completion contract already
	-- says an obsolete build announces nothing, so it must not leave a visible
	-- result either. The replacement publishes; this stage is dropped.
	if R.rebuildWhenDone then return #R.route end

	-- THE PUBLICATION POINT. Everything above either succeeded or threw, and a
	-- throw never reaches this line: the stage is a local, so an error unwinds
	-- it and the last successful route is still standing, untouched.
	return R.Publish(stage)
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
-- That was the architecture working as specified. the player set routing as the final
-- adjudicator whose goal is total time, and two continent hops dwarf any
-- preference multiplier, so geography won essentially every tie. The layered
-- ordering table showed goals arriving 57 places ahead of where preference put
-- them while goals ranked 9th never appeared at all.
--
-- The system therefore spanned both extremes and had no middle: "geography
-- decides" at normal strength, "order decides outright" past 1.45, and very
-- little in between. the chosen middle ground is the cap.
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

-- A stop you are STANDING ON cannot be reordered away from the front.
--
-- Layer 2 promotes short work in the zone you are in, and layer 3 was free to
-- undo it. Standing at the Island Expedition NPC -- one minute away, five
-- mounts on the one stop -- the plan opened by flying to Tazavesh, because the
-- clock minimises TOTAL travel across a hundred stops and moving a zero-travel
-- stop later costs that total almost nothing.
--
-- It costs THIS SESSION everything. Anyone who does two stops and logs out
-- gets the worst answer in the plan, and a zero-travel stop is exactly the
-- case a total-distance objective undervalues -- there is no distance for it
-- to weigh.
--
-- So the promotion is made sticky rather than advisory. Relative order among
-- the pinned stops is left as the earlier layers arranged it, and everything
-- else keeps the clock's ordering; only the boundary moves.
function R.PinHereNow(S)
	S = S or R
	S.pinReport = nil
	local route = S.route
	if not route or #route < 2 then return 0 end
	local here, rest = {}, {}
	for _, stop in ipairs(route) do
		-- EXPIRING work still leads: a window closing forever outranks
		-- convenience, and layer 2 already placed those ahead of the promotion.
		if stop.hereNow and stop.urgency ~= MM.Planner.URGENCY.EXPIRING then
			here[#here + 1] = stop
		else
			rest[#rest + 1] = stop
		end
	end
	if #here == 0 or #rest == 0 then return 0 end
	local moved, worst = 0, 0
	local before = {}
	for i, stop in ipairs(route) do before[stop] = i end
	for i = 1, #here do
		if route[i] ~= here[i] then
			moved = moved + 1
			local from = before[here[i]] or i
			if from - i > worst then worst = from - i end
		end
	end
	-- Recorded so the cap can say it was OVERRULED rather than claim a
	-- guarantee it no longer keeps. Standing-here work is exempt on purpose;
	-- a report that hides the exemption is how a number stops being trusted.
	S.pinReport = { moved = moved, worst = worst, pinned = #here }
	wipe(route)
	for _, stop in ipairs(here) do route[#route + 1] = stop end
	for _, stop in ipairs(rest) do route[#route + 1] = stop end
	return moved
end

function R.ApplyPreferenceCap(S)
	S = S or R
	S.capReport = nil
	local cap = R.PreferenceCap()
	if not cap then return 0 end
	local route = S.route
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
	S.capReport = { cap = cap, worst = worst, shifted = shifted, stops = n }
	return shifted
end

function R.ImproveTotalTime(playerContinent, playerWorld, S)
	S = S or R
	local blocks = continentBlocks(S.route)
	S.blocksSkipped = nil
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
		S.blocksSkipped = #blocks - MAX_BLOCKS_TO_REORDER
	end

	local start = { continent = playerContinent, world = playerWorld }
	local best = R.RouteMinutes(S.route, start)
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
		wipe(S.route)
		for _, stop in ipairs(final) do S.route[#S.route + 1] = stop end
	end

	S.timeSaved = before - best
	return S.timeSaved
end

-- Rebuild the goal -> stop index. Called after anything reorders R.route,
-- including the session view, or a goal would report the stop it used to be in.
function R.Reindex(S)
	S = S or R
	wipe(S.stopBySpell)
	for _, stop in ipairs(S.route) do
		for _, member in ipairs(stop.members or { stop }) do
			local e = member.entry
			if e and e.spellID then S.stopBySpell[e.spellID] = stop end
		end
	end
end

-- Take everything no longer planned out of the VISIBLE route, immediately.
--
-- A plan edit while a route is running used to re-chart synchronously, so the
-- very next line could ask whether the route still existed -- about 1.6 seconds
-- of frozen client for every click of [+] or [-]. The question that could not
-- wait is narrow: the arrow must never point at a goal you have just unplanned.
-- That is answerable from plan membership alone, and this is the answer.
--
-- Returns how many GOALS it removed, and how many whole stops went with them.
-- Counting only the stops was wrong: unplanning one mount from a stop shared by
-- three leaves every stop standing, so the caller saw zero, skipped its repaint
-- and left the goal index still pointing the removed mount at that stop.
--
-- What it leaves is the previous chart minus what is gone -- not a re-optimised
-- one. The replacement chart follows asynchronously and lands atomically.
--
-- AGGREGATE NUMBERS ON A PARTIALLY-EMPTIED STOP ARE LEFT ALONE. `mounts`,
-- `workMinutes` and the rest are combined by groupStops under rules that are
-- genuinely subtle -- independent drop rates add, a shared grind takes the max,
-- handicap takes the min -- and re-deriving them here would be a second copy of
-- that rule, drifting from the first. They are briefly high for a stop that has
-- lost one of several mounts, and correct again when the chart lands.
-- A STOP *IS* ITS FIRST MEMBER, AND THAT MEMBER CAN BE THE ONE REMOVED.
--
-- groupStops builds a stop by taking the first step and hanging the rest off it
-- as `members`, so `stop.entry`, `stop.mapID` and `stop.label` all describe
-- members[1]. Filtering that member out of the list left the stop still
-- claiming it -- stopSpellID returned the removed mount, stopHolds matched it,
-- SetIndex wrote it to routeGoal, Current reported it and the waypoint pointed
-- at its coordinates. The goal you had just unplanned became the one the arrow
-- sent you to.
--
-- So a survivor is promoted into the container: identity, place and label,
-- which is everything that answers "which mount is this, and where". The
-- AGGREGATES are deliberately left alone -- groupStops owns how those combine
-- and the chart that follows recomputes them.
local PROMOTED_FIELDS = {
	"entry", "rec", "mapID", "x", "y", "continent", "world",
	"path", "approxFrom", "sweep", "sweepIndex", "unmappedZone",
}

local function promoteMember(stop, survivor)
	if not survivor or stop == survivor then return end
	for _, key in ipairs(PROMOTED_FIELDS) do stop[key] = survivor[key] end
	stop.desc = survivor.desc
	stop.label = (survivor.entry and survivor.entry.name) or stop.label
	-- Rebuilt rather than kept: the grouped label counts the mounts at the stop,
	-- and one of them has just left.
	if #(stop.members or {}) > 1 then
		stop.label = stopLabel(stop)
		stop.desc = ("%s — %d mounts drop here"):format(
			survivor.desc or "One visit", #stop.members)
	end
end

function R.DropUnplanned(planned)
	if not planned then return 0, 0 end
	local kept, removedStops, removedGoals = {}, 0, 0
	for _, stop in ipairs(R.route) do
		local members = stop.members or { stop }
		local live = {}
		for _, m in ipairs(members) do
			local id = m.entry and m.entry.spellID
			if id and planned[id] then live[#live + 1] = m end
		end
		removedGoals = removedGoals + (#members - #live)
		if #live == 0 then
			removedStops = removedStops + 1
		else
			-- Filtered so the pane stops listing a mount that is off the plan,
			-- even where the stop itself survives for the others.
			if #live ~= #members then
				stop.members = live
				local stillHere = false
				for _, m in ipairs(live) do
					if m == stop then stillHere = true break end
				end
				if not stillHere then promoteMember(stop, live[1]) end
			end
			kept[#kept + 1] = stop
		end
	end
	if removedStops > 0 then
		wipe(R.route)
		for i = 1, #kept do R.route[i] = kept[i] end
	end
	return removedGoals, removedStops
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

function R.Measure(S)
	S = S or R
	local playerContinent, playerWorld = U.PlayerWorldPos()
	-- Walk the route the way the player will, spending teleports as they go, so
	-- the time we report is the time a wormhole actually buys them.
	local state = R.TravelState({ continent = playerContinent, world = playerWorld })
	local minutes, mounts, travelTotal, visitTotal = 0, 0, 0, 0
	local sessionCap = MM.Weights and MM.Weights.Get("session") or 0
	local boundaryMarked = false

	for _, stop in ipairs(S.route) do
		local legMinutes, method = travelMinutes(state, stop)
		-- A teleport is a resource: spent on leg two, gone on leg nine. A taxi
		-- is not -- you can ride the same route all day -- so marking it used
		-- would silently forbid the second trip to a destination.
		R.SpendTravel(state, method)
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
		-- the player rather than truncate. Cutting the route at the session length
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

	S.totals = {
		stops = #S.route,
		minutes = minutes,                       -- everything, grinds included
		routeMinutes = travelTotal + visitTotal, -- travel plus one visit each
		travelMinutes = travelTotal,
		mounts = mounts,
	}
	return S.totals
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
	-- TWO DIFFERENT CLOCKS, and they have to say which is which. The first is
	-- travel plus a single visit to each stop; the second adds the grinding.
	-- Labelled "on the route" the first one read as the total, so a stop
	-- reporting "1d 3h in" -- which counts against the SECOND clock -- looked
	-- like it landed after the route had already ended.
	return ("%d stop%s · %s travelling and visiting · %s to finish everything · %s"):format(
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
	-- SYNCHRONOUS, because a diagnostic that reports the PREVIOUS route is
	-- worse than no diagnostic: it looks like an answer. R.Warm has usually
	-- run this already for the full report, so this is a cache hit.
	local built, err = pcall(function() return R:BuildSync() end)
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
	local pinRep = R.pinReport
	if capRep then
		MM:Print("  Layer 3 reorders for speed, but no goal lands more than |cffffd84d%d|r places", capRep.cap)
		MM:Print("  from where layer 1 put it. Worst actual displacement: %d.", capRep.worst)
		if pinRep and pinRep.moved > 0 then
			MM:Print("  The cap does NOT bind %d stop%s you are standing on: those are"
				.. " pinned to the front afterwards (largest jump %d places).",
				pinRep.pinned, pinRep.pinned == 1 and "" or "s", pinRep.worst)
		end
	else
		MM:Print("  Layer 3 overrides layers 1 and 2 whenever it is faster overall,")
		MM:Print("  without limit — Options > Weights sets a cap if you want one.")
	end
end)

MM:On("MM_ROUTE_DEBUG", function()
	-- Never let a broken build produce an EMPTY section. "(no output)" is
	-- the least useful thing a diagnostic can say, and it is exactly what
	-- this printed while the router was throwing on every build.
	-- SYNCHRONOUS, for the same reason as /mm layers: this section's whole job
	-- is to describe the route the request asked for, not the one before it.
	local built, err = pcall(function() return R:BuildSync() end)
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
	for _, stop in ipairs(R.route) do
		if R.ArrivesByTeleport(stop) then hops = hops + 1 end
	end
	MM:Print("  %d of %d stop%s on this route open with a teleport.",
		hops, #R.route, #R.route == 1 and "" or "s")
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
		-- Against "to finish everything", never against the travel figure.
		MM:Print("   %d. %s |cff9a9a9a(%s, ~%.0f%% mount, %s into the plan)|r", i,
			stop.label or "?",
			stop.opportunistic and "detour" or "planned",
			math.min(99, (stop.mounts or 0) * 100),
			U.FormatSeconds((stop.cumulativeMinutes or 0) * 60))
	end
end)

-- MOVING THE ROUTE GOES THROUGH HERE, and nowhere else.
--
-- The anchor used to be written inside R:Current, so that reading where you
-- are heading CHANGED where you were heading. Anything that rendered the arrow
-- or drew a panel re-stamped it, including /mm report -- and because the
-- anchor is account-wide while the index is per-character, a stale one dragged
-- the index somewhere the plan was not. That is how the arrow ended up on one
-- mount while the guide showed another.
--
-- A read is a read now. The anchor moves when the ROUTE moves, which is the
-- thing it was always meant to record, and every mover calls this so none of
-- them can forget.
function R.SetIndex(i)
	if not MM.cdb then return end
	MM.cdb.routeIndex = i
	local stop = R.route[i]
	if stop and MM.db then
		local id = stopSpellID(stop)
		-- A stop with no spellID leaves the anchor alone rather than clearing
		-- it: losing your place is worse than an anchor going briefly stale.
		if id then MM.db.routeGoal = id end
	end
end

function R:Current()
	if not (MM.cdb and MM.cdb.routeActive) then return nil end
	return R.route[MM.cdb.routeIndex]
end

-- True between the request and the route landing, so a second press does not
-- start a second build behind the first.
local startPending = false

function R:Start()
	if startPending then
		MM:Print("Still charting your route — one moment.")
		return false
	end
	-- AN EMPTY PLAN IS ANSWERABLE WITHOUT CHARTING ANYTHING.
	--
	-- Asking the router first meant a build ran to discover what the plan
	-- already knew, and Start read its return value as a count when Build
	-- returns no count at all -- so `n == 0` was never true and an empty plan
	-- activated a route with nothing in it.
	local planned = MM.cdb and MM.cdb.plan and #MM.cdb.plan or 0
	if planned == 0 then
		MM:Print("No routable goals in the plan. Add mounts with a farm location first.")
		return false
	end

	local activated = false
	startPending = true
	-- ASYNCHRONOUS, because charting a large plan is seconds of work and Start
	-- is a button. Nothing about the route is touched until it has landed.
	--
	-- WRAPPED, because `startPending` blocks every later press. If the request
	-- itself throws, the flag has to come back down or the button is dead for
	-- the rest of the session.
	local requested = pcall(R.AfterBuild, false, function(stops, ok)
		startPending = false
		-- A FAILED BUILD LEAVES THE PREVIOUS ROUTE STANDING, and that route was
		-- charted for a different plan. Starting on it would look like success.
		if not ok then
			MM:Print("The route could not be charted — nothing started. /mm route to retry.")
			return
		end
		if stops == 0 then
			MM:Print("No routable goals in the plan. Add mounts with a farm location first.")
			return
		end
		MM.cdb.routeActive = true
		-- Re-anchors to the new leader, so the next rebuild resumes to what the
		-- plan actually shows rather than to whatever was current before.
		R.SetIndex(1)
		MM.Nav.SetWaypoint(R:Current())
		MM:Fire("MM_ROUTE_STARTED")
		MM:Fire("MM_ROUTE_ADVANCED")
		MM:Print("Route started: %d goals. Good hunting.", stops)
		activated = true
	end)
	if not requested then
		startPending = false
		MM:Print("The route could not be charted — nothing started.")
		return false
	end
	-- A cached route completes inline, so the honest answer is whether it
	-- activated; a real build is still pending, and that is also a yes.
	return activated or startPending
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
	R.SetIndex(index)
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
	R.SetIndex(nextIndex)

	-- FINISHING A GOAL IS WHERE THE PLAN IS ALLOWED TO MOVE ON.
	--
	-- The rest of the route was charted from wherever you started. By the time
	-- a goal is done you are somewhere else -- and if you got there your own
	-- way, teleporting to Orgrimmar instead of taking the taxi we suggested,
	-- you may be somewhere else entirely. Re-anchoring here charts what is
	-- left from where you ACTUALLY stand.
	--
	-- This is the only automatic re-chart, and it is deliberately tied to
	-- completing a leg rather than to moving: moving changes the DIRECTIONS to
	-- the current goal, which are live anyway, and must never reshuffle the
	-- order underneath someone who is halfway to it.
	--
	-- Everything already visited keeps its place -- routeIndex is preserved
	-- across the rebuild, and stops behind it are not re-ordered.
	local goal = R:Current()
	if MM.Planner and MM.Planner.SetAnchor then
		-- Build reorders what is left, so hold onto the goal we advanced TO by
		-- identity rather than by index -- the same rule the resume path uses,
		-- for the same reason.
		local sid = goal and goal.entry and goal.entry.spellID
		MM.Planner.SetAnchor()
		R.Invalidate()
		-- REPOINT ONLY AFTER THE NEW ROUTE EXISTS.
		--
		-- This searched R.route on the line after an asynchronous Build, so it
		-- was searching the route the rebuild was about to replace: the arrow
		-- and MM_ROUTE_ADVANCED both landed on the previous ordering. If a plan
		-- edit arrives while this builds, the completion belongs to the newest
		-- build, and that is the route these stops come from.
		R.AfterBuild(false, function(_, ok)
			-- A FAILED BUILD LEAVES THE PREVIOUS ROUTE STANDING, and that route
			-- is the one this advance was moving away from. Repointing into it
			-- would put the arrow on a stop chosen by a chart that no longer
			-- describes the plan, and announce it as progress.
			if not ok then return end
			if not (MM.cdb and MM.cdb.routeActive) then return end
			if sid then
				for i, stop in ipairs(R.route) do
					if stopHolds(stop, sid) then R.SetIndex(i) break end
				end
			end
			MM.Nav.SetWaypoint(R:Current())
			MM:Fire("MM_ROUTE_ADVANCED")
		end)
		return
	end

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
		-- MEASURED THROUGH COMPLETION, NOT TO THE START OF THE COROUTINE.
		--
		-- Build returns with the work in flight, so timing around the call
		-- measured how long it took to CREATE the build -- microseconds -- and
		-- the receipt for a genuinely slow resume never printed. Finishing here
		-- also means FinishResume can trust that an empty route is an empty
		-- route rather than one that has not been charted yet.
		R.AfterBuild(false, function(stops, ok)
			-- Resuming onto the PREVIOUS route would restore a route charted for
			-- whatever the plan was last session, re-arm the arrow on it and
			-- open the monitor over it -- all of which reads as a successful
			-- resume. Say so instead, and leave the route alone.
			if not ok then
				MM:Print("Could not plan your route — it is not running. "
					.. "/mm route to try again.")
				R:Stop()
				return
			end
			if startedAt and debugprofilestop then
				local secs = (debugprofilestop() - startedAt) / 1000
				-- Only when it was slow enough to have looked broken. Below that
				-- the player never noticed a pause and does not need a receipt.
				if secs > 4 then
					MM:Print("Route planned in %.1fs — %d goals.", secs, stops)
				end
			end
			R.FinishResume()
		end)
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
	-- A BUILD IN FLIGHT IS NOT AN EMPTY ROUTE.
	--
	-- Stopping here on an empty in-memory route would throw away a perfectly
	-- valid saved route whenever the chart had not landed yet -- the route
	-- would simply be gone after a reload, with nothing said about why.
	if R.IsBuilding() then return end
	if #R.route == 0 then
		R:Stop()
		return
	end
	if MM.cdb.routeIndex > #R.route then R.SetIndex(1) end
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
	-- A SPENT PARAGON CACHE IS A LOCKOUT WITHOUT THE FIELD.
	--
	-- Paragon records carry no `attempts` value, so this rule never covered
	-- them -- and opening the cache is precisely "nothing more to do here": it
	-- is consumed, the bar has reset, and the next one is a rep grind away.
	-- Reported as "did it register and move on", and it did not.
	local spent = MM.Attempts.IsParagonGoal and MM.Attempts.IsParagonGoal(cur.rec)
	if lockout == "DAILY" or lockout == "WEEKLY" or spent then
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

-- The WORLD changed, not the plan: a lockout taken or lifted, a flight point
-- lifted, or the collection rescanned. The signature cannot see these, so they
-- say so outright rather than being inferred.
MM:On("MM_LOCKS", R.Invalidate)
MM:On("MM_SCANNED", R.Invalidate)

-- TRAVEL CHANGED, WHICH THE PLAN CANNOT SEE.
--
-- Switching a teleport off used to fire MM_PLAN_CHANGED. That rebuilt the
-- route, and the rebuild took a CACHE HIT -- the plan had not changed, and the
-- signature could not see teleports -- so the option moved and the route did
-- not. The signature now carries a travel fingerprint, and this is what tells
-- each layer to drop what it owns.
--
-- Scope decides how much is thrown away. Rebuilding a 29,000-edge graph because
-- a hearthstone came off cooldown is the waste this distinction exists to
-- prevent.
local lastTravelPrint
MM:On("MM_TRAVEL_CHANGED", function(scope)
	-- DID ANYTHING ACTUALLY MOVE?
	--
	-- SPELLS_CHANGED and TOYS_UPDATED fire for reasons that have nothing to do
	-- with travel -- a talent swap, a pet learned. Invalidating on the EVENT
	-- would re-chart the whole plan for each of them. The fingerprint answers
	-- the question the event only raises.
	local now = MM.TravelFingerprint and MM.TravelFingerprint() or "?"
	local moved = (now ~= lastTravelPrint)
	lastTravelPrint = now

	if scope == "topology" then
		-- The map moved. This is the expensive one, and the only reason the
		-- scopes exist: rebuilding 29,000 edges because a hearthstone came off
		-- cooldown is exactly the waste being avoided here.
		R.InvalidateTravelTopology()
	elseif scope == "cooldown" or moved then
		-- Prices or options moved: the cached ANSWERS are wrong, the map is not.
		R.InvalidateTravelPlans()
	end

	-- A cooldown changes what a route costs, not which routes are legal, and an
	-- order is a decision about legality and value. Re-charting for one would
	-- reshuffle the plan under the player every thirty seconds.
	if scope == "cooldown" or not moved then return end
	R.InvalidateRouteOrder()
	-- Asynchronously, and only when there is a route to keep current: a settings
	-- panel toggle must not freeze the frame, and the previous complete route
	-- stays on screen until the replacement lands.
	if MM.cdb and MM.cdb.routeActive then R:Build() end
end)

-- A SESSION IS A VIEW, AND A VIEW HAS TO BE ABLE TO CLOSE.
--
-- ApplySession reorders R.route IN PLACE, and nothing re-charted when the
-- session ended -- so picking a length and then going back to "No limit" left
-- the session's order standing for good. That is the exact symptom: the order
-- is right, wrong once a limit is set, and never comes back.
--
-- Only the in-memory signature is cleared, NOT the stored chart. The chart is
-- saved before ApplySession, so it holds the un-sessioned order: the rebuild
-- restores it and then applies whatever the session now is, or nothing at all.
-- Cheap either way -- no Dijkstra runs, because the ordering decision is not
-- being remade.
MM:On("MM_SESSION_CHANGED", function()
	-- Re-APPLY, do not re-chart. The base order is already in hand, so this
	-- costs nothing and cannot change which stops were chosen or in what
	-- order the chart put them.
	if R.baseOrder and #R.baseOrder > 0 then
		if R.ApplySession then R.ApplySession() end
		R.Reindex()
		MM:Fire("MM_ROUTE_ADVANCED")
	else
		R.builtSignature = nil
		R:Build()
	end
end)

-- Plan edits invalidate the route order.
--
-- AND THE THREE STEPS ARE TIMED SEPARATELY, because the total was misleading.
-- The per-handler profiler put 3,736 ms of a plan edit inside this handler,
-- which reads as "the rebuild is slow" -- except a self-test that clears the
-- signature and times BuildSync on its own measures 52 ms for the same 285
-- goals. The profiler attributes nested fires to whoever raised them, so
-- MM_ROUTE_ADVANCED and everything listening to it is counted here too.
--
-- One number for three steps cannot say which one to fix, so each is recorded.
R.lastPlanEditMs = nil

MM:On("MM_PLAN_CHANGED", function()
	if MM.cdb.routeActive then
		local clock = debugprofilestop
		local t0 = clock and clock() or nil

		-- ASKED OF THE PLAN, NOT OF A RE-CHART.
		--
		-- This called BuildSync purely so the next line could ask whether the
		-- route still existed -- a full re-chart on every click of [+] or [-]
		-- while a route was running, about 1.6 seconds of frozen client for a
		-- question about plan membership. The plan can simply be read.
		local planned, n = {}, 0
		for _, item in ipairs(MM.cdb.plan or {}) do
			if item.spellID then planned[item.spellID] = true n = n + 1 end
		end
		if n == 0 then R:Stop() return end

		-- The one thing that cannot wait for the chart: a goal you have just
		-- unplanned must stop being somewhere the arrow can send you.
		local dropped = R.DropUnplanned(planned)
		local t1 = clock and clock() or nil
		-- Any goal leaving is enough. A mount removed from a stop shared with
		-- two others changes what the pane lists and what the goal index maps,
		-- even though every stop is still standing.
		if dropped > 0 then
			if #R.route == 0 then R:Stop() return end
			-- The route on screen changed, so what describes it has to change
			-- with it. Both are O(n) over the stops -- the expensive part of a
			-- build is choosing the ORDER, and that is what moves off-frame.
			R.Measure()
			R.Reindex()
			-- The current goal may have been the thing removed. Land on
			-- something real before anything reads the index.
			local goal = MM.db and MM.db.routeGoal
			local found
			if goal then
				for i, stop in ipairs(R.route) do
					if stopHolds(stop, goal) then found = i break end
				end
			end
			R.SetIndex(found or math.min(MM.cdb.routeIndex or 1, #R.route))
			MM.Nav.SetWaypoint(R:Current())
			MM:Fire("MM_ROUTE_ADVANCED")
		end
		local t2 = clock and clock() or nil

		-- The OPTIMISED order is recomputed off-frame. Until it lands the
		-- previous chart stays on screen, minus whatever left the plan -- one
		-- build stale, which is a far better thing to show than a frozen client.
		R.AfterBuild(false, function(stops, ok)
			if not (MM.cdb and MM.cdb.routeActive) then return end
			-- The trim above already took the unplanned goals out of the visible
			-- route, so what is on screen is correct even without the chart. A
			-- failed build must not repoint or announce against it: `stops` then
			-- describes the PREVIOUS route, and zero would stop a route that is
			-- perfectly alive.
			if not ok then return end
			if stops == 0 then R:Stop() return end
			local goal = MM.db and MM.db.routeGoal
			if goal then
				for i, stop in ipairs(R.route) do
					if stopHolds(stop, goal) then R.SetIndex(i) break end
				end
			end
			MM.Nav.SetWaypoint(R:Current())
			MM:Fire("MM_ROUTE_ADVANCED")
		end)
		if t0 then
			R.lastPlanEditMs = {
				-- `build` is what the frame actually pays now: reading the plan
				-- and trimming it. The chart is off-frame and is not counted
				-- here, because nobody is waiting for it.
				build = t1 - t0, waypoint = t2 - t1, advanced = clock() - t2,
				dropped = dropped,
			}
		end
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
