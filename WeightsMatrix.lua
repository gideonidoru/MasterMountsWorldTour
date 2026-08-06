-- Master Mounts: the weights & priorities matrix.
--
-- Requirement — I need you to add a full weights & priorities test suite in the
-- Diagnostics section, it needs to work through multiple combinations and
-- permutations of the weights & priorities and show the differences in ordering
-- 25 mounts. So we can put them in here and you can tweak the implementation so
-- its logical and user friendly.
--
-- The point is not to pass or fail. It is to make the ranking ARGUABLE. Twice
-- now a settings change produced no visible effect and the only way to find out
-- was to play the game and squint at a list; both times the cause was a scale
-- problem invisible from the code. This runs the real router under a spread of
-- settings and prints what a player would actually be sent to do, so the
-- question "is this sensible?" can be answered by reading rather than guessing.
--
-- Two rules it must never break:
--   * the player's own settings are saved and restored, whatever happens
--   * it reports what the router really produced -- no separate model of the
--     ranking, or we would be checking our homework against our homework
local _, MM = ...

MM.WeightsMatrix = {}
local WX = MM.WeightsMatrix

local TOP_N = 25

-- Each scenario is a full weights table, so a scenario says exactly what it is
-- rather than inheriting whatever the player happened to have set.
local function base(overrides)
	local t = { schema = 2 }
	for k, v in pairs(overrides or {}) do t[k] = v end
	return t
end

local ORDER_DEFAULT = { "PICKUP", "INSTANCE", "RARE", "FIELD", "REP", "GRIND", "ACHIEVE", "GROUP" }
local ORDER_RARES   = { "RARE", "FIELD", "PICKUP", "INSTANCE", "REP", "GRIND", "ACHIEVE", "GROUP" }
local ORDER_SOLO    = { "INSTANCE", "PICKUP", "RARE", "FIELD", "GRIND", "REP", "ACHIEVE", "GROUP" }
local ORDER_REP     = { "REP", "GRIND", "PICKUP", "FIELD", "RARE", "INSTANCE", "ACHIEVE", "GROUP" }

-- Presets first: those are what a player actually picks, so those are what most
-- needs to be right. The single-lever scenarios after them exist to diagnose
-- WHY a preset behaves as it does.
WX.SCENARIOS = {}
for _, preset in ipairs(MM.Weights.PRESETS) do
	local weights = { schema = 2 }
	for k, v in pairs(preset.weights) do weights[k] = v end
	WX.SCENARIOS[#WX.SCENARIOS + 1] = {
		name = "PRESET: " .. preset.name,
		why = preset.expect,
		weights = weights,
	}
end

local LEVERS = {
	{ name = "Rares & field work first", why = "priority order changed, nothing else",
		weights = base({ order = ORDER_RARES }) },

	{ name = "Legacy dungeons over rep", why = "a worked example",
		weights = base({ order = ORDER_SOLO }) },

	{ name = "Reputation first", why = "the opposite end of the same lever",
		weights = base({ order = ORDER_REP }) },

	{ name = "Priority ignored", why = "strength 0 — pure value per minute",
		weights = base({ order = ORDER_RARES, priority = 0 }) },

	{ name = "Priority absolute", why = "strength 1.5 — order rules",
		weights = base({ order = ORDER_RARES, priority = 1.5 }) },

	{ name = "Distance is free", why = "travel 0 — best goals wherever they are",
		weights = base({ travel = 0 }) },

	{ name = "Stay local", why = "travel 1500 — refuse to leave",
		weights = base({ travel = 1500 }) },

	{ name = "Chase trophies", why = "odds 0 — rarity stops counting against a mount",
		weights = base({ odds = 0 }) },

	{ name = "Sure things only", why = "odds 5000, effort 500",
		weights = base({ odds = 5000, effort = 500 }) },

	{ name = "Deadlines ignored", why = "urgency 0 — payoff alone decides",
		weights = base({ urgency = 0 }) },

	{ name = "Prefer legacy content", why = "era +1000",
		weights = base({ era = 1000 }) },

	-- The cap is the answer to this tool's most persistent complaint, so it
	-- gets scenarios at both ends rather than one in the middle.
	{ name = "Clock unleashed", why = "orderCap 0 — routing may reorder without limit",
		weights = base({ order = ORDER_SOLO, orderCap = 0 }) },

	{ name = "Order held tight", why = "orderCap 4 — nothing moves far from your list",
		weights = base({ order = ORDER_SOLO, orderCap = 4 }) },
}

for _, lever in ipairs(LEVERS) do WX.SCENARIOS[#WX.SCENARIOS + 1] = lever end

------------------------------------------------------------
-- Running one scenario
------------------------------------------------------------
-- The goals a player would actually be sent to, in order, flattened out of the
-- route so batched mounts are listed individually -- a stop that drops four is
-- four mounts to the person collecting them.
local function topGoals(n)
	local out, seen = {}, {}
	for _, stop in ipairs(MM.Router.route) do
		for _, member in ipairs(stop.members or { stop }) do
			local entry = member.entry
			if entry and not seen[entry] then
				seen[entry] = true
				out[#out + 1] = {
					name = entry.name,
					tier = member.tier or stop.tier,
					detour = stop.opportunistic and true or false,
					batched = #(stop.members or { stop }),
					mounts = member.mounts or 0,
					pref = member.layerPreference or stop.layerPreference,
				}
				if #out >= n then return out end
			end
		end
	end
	return out
end

-- The same goals in the order LAYER ONE wanted them.
--
-- When a scenario produces an identical route the cause is one of two very
-- different things: the setting never reached the ranking at all, or it did and
-- the clock layer then erased it. Those need opposite fixes, and the report
-- could not tell them apart -- it only ever showed the final answer.
local function prefOrder(list)
	local copy = {}
	for i, g in ipairs(list) do copy[i] = g end
	table.sort(copy, function(a, b)
		local pa, pb = a.pref or math.huge, b.pref or math.huge
		if pa ~= pb then return pa < pb end
		return (a.name or "") < (b.name or "")
	end)
	return copy
end

function WX.Run(scenario, n)
	-- A COPY, always. `store()` writes bookkeeping into whatever table it is
	-- handed, and handing it a module constant would let one scenario mutate the
	-- definition every later run reads.
	local weights = { }
	for k, v in pairs(scenario.weights) do
		if k == "order" then
			local order = {}
			for i, key in ipairs(v) do order[i] = key end
			weights[k] = order
		else
			weights[k] = v
		end
	end
	MM.db.weights = weights
	MM:Fire("MM_WEIGHTS_CHANGED")
	-- SYNCHRONOUS: the very next line reads the route this produced. A chunked
	-- build returns with the work in flight, so this would score the PREVIOUS
	-- weights and attribute the result to the new ones.
	MM.Router:BuildSync()
	return topGoals(n or TOP_N), MM.Router.totals
end

------------------------------------------------------------
-- Reporting
------------------------------------------------------------
local function positions(list)
	local at = {}
	for i, g in ipairs(list) do at[g.name] = i end
	return at
end

-- How different two orderings are, in the terms a player would notice: what
-- appeared, what vanished, and how far things shifted.
local function compare(baseline, other)
	local a, b = positions(baseline), positions(other)
	local entered, left, moved, same = {}, {}, 0, 0
	for name, pos in pairs(b) do
		if not a[name] then
			entered[#entered + 1] = ("%s (#%d)"):format(name, pos)
		elseif a[name] ~= pos then
			moved = moved + 1
		else
			same = same + 1
		end
	end
	for name, pos in pairs(a) do
		if not b[name] then left[#left + 1] = ("%s (was #%d)"):format(name, pos) end
	end
	table.sort(entered); table.sort(left)
	return entered, left, moved, same
end

------------------------------------------------------------
-- The run
------------------------------------------------------------
-- Asynchronous, one scenario per frame.
--
-- Twelve route builds plus twelve full re-rankings is real work however fast
-- each one is, and doing it inside a single call means the client stops dead
-- for the duration. the player watched exactly that happen. A diagnostic tool that
-- freezes the game to tell you about performance is its own punchline.
--
-- Each scenario yields to the frame loop, so the client stays responsive and
-- the player can watch progress instead of wondering whether it crashed.
local running

local function emit(state, fmt, ...)
	local text
	if select("#", ...) > 0 then
		local ok, res = pcall(string.format, tostring(fmt), ...)
		text = ok and res or tostring(fmt)
	else
		text = tostring(fmt)
	end
	state.lines[#state.lines + 1] = text
	if state.echo then MM:Print(text) end
end

local function finish(state)
	-- Restore FIRST, and unconditionally. Whatever happened above, the player
	-- must get their own settings back.
	MM.db.weights = state.savedWeights
	if MM.cdb then MM.cdb.routeActive = state.savedRouteActive end
	MM:Fire("MM_WEIGHTS_CHANGED")
	-- Restoring the player's real route after the matrix has been swapping
	-- weights underneath it. Must complete before we hand control back, or the
	-- next thing to draw shows the matrix's last experiment.
	pcall(function() MM.Router:BuildSync() end)
	running = nil

	emit(state, " ")
	emit(state, "Your settings are restored.")
	if state.onDone then state.onDone(table.concat(state.lines, "\n")) end
end

local function step(state)
	local index = state.index
	if index > #WX.SCENARIOS then return finish(state) end
	state.index = index + 1

	local scenario = WX.SCENARIOS[index]
	emit(state, " ")
	emit(state, "[%d/%d] %s — %s", index, #WX.SCENARIOS, scenario.name, scenario.why)

	-- Per-scenario pcall. One bad scenario must not take the other eleven with
	-- it, and a failure has to name itself: a run that silently produces nothing
	-- is the exact bug this tool exists to catch, so it must never BE that bug.
	local ran, list, totals = pcall(WX.Run, scenario, TOP_N)
	if not ran then
		emit(state, "    failed: %s", tostring(list))
		list, totals = {}, nil
	end
	list = list or {}

	if totals then
		emit(state, "    route: %d stops · %s · ~%.2f mounts expected · built in %s",
			totals.stops, MM.Util.FormatSeconds(totals.minutes * 60), totals.mounts,
			MM.Router.lastBuildMs and ("%.0f ms"):format(MM.Router.lastBuildMs) or "?")
	end
	if #list == 0 and ran then
		emit(state, "    router returned no goals for this scenario")
	end

	for i, g in ipairs(list) do
		local rank = MM.Weights.TierRank(g.tier or 1)
		local tags = {}
		if g.detour then tags[#tags + 1] = "detour" end
		if g.batched > 1 then tags[#tags + 1] = ("%d at this stop"):format(g.batched) end
		if g.mounts >= 0.999 then tags[#tags + 1] = "guaranteed"
		elseif g.mounts > 0 then tags[#tags + 1] = ("%.2g%%"):format(g.mounts * 100) end
		emit(state, "    %2d. #%d %-34s %s", i, rank, g.name,
			#tags > 0 and ("(" .. table.concat(tags, ", ") .. ")") or "")
	end

	if index == 1 then
		state.baseline = list
	elseif state.baseline then
		local entered, left, moved, same = compare(state.baseline, list)
		emit(state, "    vs defaults: %d unchanged, %d moved, %d new, %d dropped",
			same, moved, #entered, #left)
		if #entered > 0 then emit(state, "      in:  %s", table.concat(entered, ", ")) end
		if #left > 0 then emit(state, "      out: %s", table.concat(left, ", ")) end
		-- The whole reason this exists: a scenario that changes NOTHING is either
		-- a setting with no effect or a scale bug, and both have shipped before.
		if same == #state.baseline and #entered == 0 then
			-- Attribute the silence. This is the whole diagnostic value:
			-- "the weight never landed" and "the weight landed and routing
			-- overruled it" look identical here and are fixed in completely
			-- different places.
			local _, _, prefMoved = compare(prefOrder(state.baseline), prefOrder(list))
			local cap = MM.Router.capReport
			if prefMoved > 0 then
				emit(state, "      IDENTICAL route — but preference DID reorder "
					.. "(%d moved). Layer 1 works; layer 3 overrides it.", prefMoved)
			elseif cap then
				-- A TRAVEL weight does not touch layer one -- layer one has no
				-- travel in it at all -- so "preference did not move" says
				-- nothing about whether the weight is wired. With a cap active
				-- the likelier story is that the order is pinned: near the top
				-- of the list the windows are tight (position 1 can only take a
				-- goal preferred within `cap` places), so the clock has almost
				-- no room to express anything.
				emit(state, "      IDENTICAL — but the preference cap (%d places) is "
					.. "holding the order. Raise it, or set it to 0, to give this "
					.. "setting room to show.", cap.cap)
			else
				emit(state, "      IDENTICAL, and preference did not move either "
					.. "— this setting never reaches the ranking.")
			end
		end
	end

	C_Timer.After(0, function() step(state) end)
end

-- onDone receives the whole report as text.
function WX.Start(onDone, echo)
	if running then
		MM:Print("The weights matrix is already running — %d of %d scenarios done.",
			running.index - 1, #WX.SCENARIOS)
		return false
	end

	local planSize = (MM.Planner and MM.Planner.GetPlan) and #MM.Planner:GetPlan() or -1
	local state = {
		index = 1, lines = {}, echo = echo, onDone = onDone,
		savedWeights = MM.db.weights,
		savedRouteActive = MM.cdb and MM.cdb.routeActive,
	}
	running = state
	if MM.cdb then MM.cdb.routeActive = false end

	emit(state, "Weights & priorities matrix — %d scenarios, top %d goals each",
		#WX.SCENARIOS, TOP_N)
	emit(state, "Every scenario runs the real router. Your own settings are restored at the end.")
	emit(state, "Plan holds %d uncollected goals.", planSize)
	if planSize <= 0 then
		emit(state, "Nothing to order — add mounts to your plan first.")
		finish(state)
		return true
	end

	MM:Print("Running the weights matrix — %d scenarios, one per frame. "
		.. "This stays responsive; the report opens when it finishes.", #WX.SCENARIOS)
	C_Timer.After(0, function() step(state) end)
	return true
end

MM:On("MM_WEIGHTS_MATRIX", function()
	WX.Start(function(text)
		if MM.Diagnostics and MM.Diagnostics.ShowExport then
			MM.Diagnostics.ShowExport(text, "Weights & priorities matrix")
		else
			for line in text:gmatch("[^\n]+") do MM:Print(line) end
		end
	end)
end)
