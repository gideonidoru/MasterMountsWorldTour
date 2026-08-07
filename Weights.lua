-- Master Mounts: user weights and priorities.
--
-- Every ranking number in Planner.lua encodes an opinion -- that a rare spawn
-- beats an achievement, that another continent costs you something, that a
-- mount 0.2% of players own is worth more than a quick one. Those defaults are
-- good general advice and wrong for plenty of individual collectors. Someone
-- farming for prestige wants rarity to dominate; someone with two hours wants
-- travel to dominate; someone who hates dungeons wants them last regardless.
--
-- So the opinions become settings. This file owns them; Planner.lua reads them.
--
-- Two kinds of control, because they answer different questions:
--
--   ORDER   which KIND of goal comes first. A strict ordering of the tiers,
--           because "rares before achievements" is an absolute statement -- no
--           achievement should outrank a rare however cheap it looks. BLOCKED
--           is never reorderable; something you cannot do today cannot be a
--           priority.
--
--   WEIGHTS how much each cost matters WITHIN a tier, plus how hard deadlines
--           jump the queue. These are the addon's ACTUAL coefficients -- the
--           numbers Planner.lua multiplies by -- not multipliers layered over
--           them, so every default here is the constant that used to be
--           hard-coded and a fresh install ranks identically.
--
-- A setting that does not visibly change anything is indistinguishable from a
-- setting that is not connected, so a change also re-optimizes the plan (see
-- the bottom of this file). Scoring differently while the list the player is
-- staring at stays put is not "wired".
--
-- Stored account-wide in MM.db.weights: a collector's taste does not change
-- when they log onto an alt.
local _, MM = ...

MM.Weights = {}
local W = MM.Weights

------------------------------------------------------------
-- Definitions
------------------------------------------------------------
-- Order is expressed as tier KEYS, not numbers, so a saved order survives any
-- future renumbering of P.TIER.
W.DEFAULT_ORDER = {
	"PICKUP", "INSTANCE", "RARE", "FIELD", "REP", "GRIND", "ACHIEVE", "GROUP",
}

-- One-line rationale per tier, shown beside each row so reordering is an
-- informed choice rather than a guess.
W.TIER_HINT = {
	PICKUP   = "Already earned or already paid for — just go get it",
	INSTANCE = "Solo a legacy dungeon or raid boss",
	RARE     = "Kill a rare spawn out in the world",
	FIELD    = "Short objective you do outdoors",
	REP      = "Grind a faction to a standing",
	GRIND    = "Long haul: currency, tokens, repeat runs",
	ACHIEVE  = "Complete an achievement, however long it takes",
	GROUP    = "Needs other people or rated play",
}

-- These are the addon's REAL coefficients, not opaque 0-2 multipliers. A slider
-- reading "1.0" says nothing about what the addon is doing; a slider reading
-- "250 points per continent" says exactly what it is doing, next to the number
-- it is doing it with. Every default below is the constant that was hard-coded
-- in Planner.lua before this panel existed, so a fresh install ranks
-- identically -- and a player can see the reasoning rather than take it on
-- faith.
--
-- Scale to keep in your head: a goal's score is typically 300-3,000 points, and
-- LOWER IS BETTER. Anything worth 2,500 is close to a veto; 100 is a nudge.
W.SCALE_HINT = "Scores run roughly 300-3,000 points and lower is better, "
	.. "so 100 is a nudge and 2,500 is nearly a veto."

W.SLIDERS = {
	{ key = "travel", label = "Travel cost", default = 250, min = 0, max = 1500, step = 25,
		unit = "points", lowText = "Distance is free", highText = "Stay local",
		desc = "Charged when a goal is on another continent (half that when we can't tell).",
		reading = function(v)
			if v == 0 then return "Distance is ignored entirely." end
			if v < 150 then return "A far goal barely loses ground to a near one." end
			if v > 700 then return "You will be sent almost nowhere off your own continent." end
			return "A far goal has to be clearly better to beat a near one."
		end },

	{ key = "effort", label = "Effort cost", default = 100, min = 0, max = 500, step = 10,
		unit = "points per step",
		lowText = "Size doesn't matter", highText = "Short jobs only",
		desc = "Charged per point of a goal's effort rating, 1 (trivial) to 5 (a project).",
		reading = function(v)
			if v == 0 then return "A five-star project competes with a one-star errand." end
			if v >= 300 then return ("A project costs %d more than an errand — you'll be shown short work."):format(v * 4) end
			return ("A five-star project starts %d points behind a one-star errand."):format(v * 4)
		end },

	{ key = "odds", label = "Long-odds cost", default = 2500, min = 0, max = 5000, step = 100,
		unit = "points at worst",
		lowText = "Chase trophies", highText = "Sure things only",
		desc = "Charged in full when almost nobody owns the mount, tapering to nothing "
			.. "at common. Needs MountsRarity for real ownership figures.",
		reading = function(v)
			if v == 0 then return "Ownership rate is ignored — a 0.02% trophy ranks on speed alone." end
			if v >= 3500 then return "Near-unobtainable mounts are pushed to the very bottom." end
			return "Rarer mounts sink; a trophy has to be quick to stay near the top."
		end },

	{ key = "era", label = "Era nudge", default = 0, min = -1000, max = 1000, step = 50,
		unit = "points", lowText = "Prefer current", highText = "Prefer legacy",
		desc = "Tilts every goal toward one era. Legacy means two expansions back or older.",
		reading = function(v)
			if v == 0 then return "Neutral — era plays no part." end
			if v > 0 then return ("Old content gets %d points off; current content pays %d."):format(v, v) end
			return ("Current content gets %d points off; old content pays %d."):format(-v, -v)
		end },

	{ key = "priority", label = "Priority strength", default = 0.6, min = 0, max = 1.5, step = 0.05,
		unit = "x per place",
		lowText = "Order is ignored", highText = "Order rules",
		desc = "How much better a lower-priority goal has to be before it jumps "
			.. "ahead. This never changes a goal's real payoff — it changes what "
			.. "you're willing to accept in exchange for going out of order.",
		reading = function(v)
			if v == 0 then return "Priority is ignored — whatever pays best per minute goes first." end
			if v >= 1.45 then
				return "ABSOLUTE. The order above decides outright; payoff only sorts within a band."
			end
			local perPlace = 1 + v
			return ("Each place down the list needs %.2fx the payoff per minute to jump ahead — the bottom needs %.0fx the top.")
				:format(perPlace, perPlace ^ 7)
		end },

	-- The cap. the player, on the matrix reporting "Layer 1 works; layer 3 overrides
	-- it": routing is the final adjudicator by design, but two continent hops
	-- dwarf any preference multiplier, so geography won nearly every tie and
	-- reordering the tier list barely changed what you were told to do. There
	-- was "geography decides" and "order decides outright" and nothing between.
	-- This is the middle: the clock stays free INSIDE a band around where
	-- preference put each goal, and cannot drag anything further than that.
	{ key = "orderCap", label = "How far the clock may reorder", default = 12,
		min = 0, max = 60, step = 2, unit = "places",
		lowText = "Order rules", highText = "Speed rules",
		desc = "Routing is allowed to move a goal for speed, but not without "
			.. "limit. At 12, nothing lands more than twelve places from where "
			.. "your priorities put it — so the top of your list still looks "
			.. "like the list you asked for, and the route is still efficient "
			.. "inside that.",
		reading = function(v)
			if v == 0 then
				return "No limit. The clock decides the order outright, and your "
					.. "priorities only break ties."
			end
			if v <= 4 then
				return ("Very tight: nothing moves more than %d places, so the route "
					.. "follows your priorities almost exactly and pays for it in travel."):format(v)
			end
			return ("Goals may move up to %d places for a faster route, and no further.")
				:format(v)
		end },

	{ key = "session", label = "Session length", default = 0, min = 0, max = 240, step = 15,
		unit = "minutes", lowText = "No limit", highText = "4 hours",
		desc = "Roughly how long you play in one sitting. This is not just a line "
			.. "on the route — it decides how much a long grind is worth to you "
			.. "tonight, because something you cannot finish in a sitting is a "
			.. "project rather than a stop.",
		reading = function(v)
			if v == 0 then
				return "Assumed to be about 2 hours. Goals far longer than that sink."
			end
			return ("Goals needing much more than %d minutes sink; the route also marks where you pass it."):format(v)
		end },

	{ key = "urgency", label = "Deadline pressure", default = 1, min = 0, max = 2, step = 0.05,
		unit = "x", lowText = "Ignore deadlines", highText = "Deadlines rule",
		desc = "How far a closing window jumps the queue.",
		reading = function(v)
			if v == 0 then return "Deadlines are ignored — payoff alone decides the route." end
			if v < 0.5 then return "A closing event is a strong hint, not a rule." end
			return "Anything closing is done first, whatever else is on the list."
		end },
}

------------------------------------------------------------
-- Presets
------------------------------------------------------------
-- Requirement — maybe we add some presets ... and it adjusts the weights and
-- priorities to give the player what they expect.
--
-- Seven sliders and a reorderable list is a good tool and a poor starting
-- point. A preset is a sentence about how you play, and the numbers behind it
-- are the addon's problem, not the player's.
--
-- Balanced IS the defaults -- not an approximation of them -- so switching to
-- it is exactly a reset. Every other preset is stated as what it should FEEL
-- like, and the simulator checks it actually does.
W.PRESETS = {
	{
		key = "balanced",
		name = "Balanced",
		blurb = "What ships. A bit of everything, weighted toward quick wins.",
		expect = "No strong bias in any direction.",
		weights = {},   -- empty == defaults, by definition
	},
	{
		key = "legacy",
		name = "Legacy Dungeons & Raids",
		blurb = "Old instances first, always — DROPS only. Soloable, repeatable, "
			.. "and the single biggest pool of mounts left for most collectors. "
			.. "Achievements are pushed to the bottom: they belong to Balanced "
			.. "and Long Session, not to a farming run.",
		expect = "Legacy instance runs dominate; achievements do not appear.",
		weights = {
			-- Requirement — when I said Legacy Dungeons and Raids I meant exclusively
			-- drop mounts not achievement, achievement belong in balanced and
			-- long grind only. So drops lead -- instances, then outdoor rares --
			-- and ACHIEVE goes dead last, below even group content. With strict
			-- priority on, last means it does not appear until everything else
			-- is exhausted.
			order = { "INSTANCE", "RARE", "PICKUP", "FIELD", "GRIND", "REP", "GROUP", "ACHIEVE" },
			-- The design calls for ALWAYS. Strict priority already puts instances
			-- first; a tight cap stops the clock quietly undoing it further
			-- down, which is what the matrix caught it doing.
			orderCap = 6,
			-- absolute, because The design calls for ALWAYS: at 2.5x per place, nothing
			-- below instances gets past them without being extraordinary
			priority = 1.5,
			-- a legacy raid mount is a 1% drop by design. Punishing long odds
			-- here would rule out the very thing the preset is for.
			odds = 800,
			-- and repeat runs are the point, so size is not a deterrent
			effort = 40,
			era = 600,
		},
	},
	{
		key = "time",
		name = "Optimised for Time",
		blurb = "Most mounts per hour. Short, closed jobs near where you already "
			.. "are, and nothing you cannot finish tonight.",
		expect = "Short work only, and very little travel.",
		weights = {
			order = { "PICKUP", "FIELD", "RARE", "INSTANCE", "REP", "GRIND", "ACHIEVE", "GROUP" },
			-- My first attempt set orderCap = 0 here, reasoning that a preset
			-- about the clock should let the clock off its leash. The preset
			-- harness rejected it immediately: "Optimised for Time averages 54
			-- min, worse than Balanced's 10".
			--
			-- The reasoning was backwards. This preset's promise is SHORT WORK,
			-- and short work is a preference -- it lives in the tier order,
			-- which is exactly what the cap protects. Removing the cap let the
			-- clock drag long jobs into a list whose whole point is that
			-- everything on it is quick. A tight cap serves the promise better
			-- than no cap does.
			orderCap = 8,
			travel = 700,
			effort = 320,
			odds = 3500,
			priority = 0.4,
			session = 60,
			urgency = 1.2,
		},
	},
	{
		key = "grind",
		name = "Long Session / Grind",
		blurb = "You have the evening. Commit to the reputations, currencies and "
			.. "metas that never fit into an hour.",
		expect = "Long projects surface instead of being pushed aside.",
		weights = {
			order = { "GRIND", "REP", "ACHIEVE", "INSTANCE", "PICKUP", "RARE", "FIELD", "GROUP" },
			travel = 120,
			effort = 30,
			odds = 1200,
			-- Absolute, like the Legacy preset, and for the same reason. A long
			-- project can never beat a ten-minute errand on value density, and
			-- geography beats both -- the simulator showed this preset returning
			-- the identical top ten as Balanced and Optimised for Time, because
			-- continent clustering decided all three. If the player has said "I
			-- am here to grind", the order has to actually rule.
			priority = 1.5,
			session = 240,
			urgency = 0.8,
		},
	},
}

function W.ApplyPreset(key)
	for _, preset in ipairs(W.PRESETS) do
		if preset.key == key then
			local copy = { schema = 2 }
			for k, v in pairs(preset.weights) do
				if k == "order" then
					local order = {}
					for i, tier in ipairs(v) do order[i] = tier end
					copy[k] = order
				else
					copy[k] = v
				end
			end
			MM.db.weights = copy
			W.Changed()
			return preset
		end
	end
end

-- Which preset the current settings match, or nil for "something of your own".
function W.CurrentPreset()
	for _, preset in ipairs(W.PRESETS) do
		local match = true
		for _, def in ipairs(W.SLIDERS) do
			local want = preset.weights[def.key] or def.default
			if math.abs(W.Get(def.key) - want) > (def.step or 0.05) / 2 then match = false end
		end
		local order = W.Order()
		local wantOrder = preset.weights.order or W.DEFAULT_ORDER
		for i, tier in ipairs(wantOrder) do
			if order[i] ~= tier then match = false end
		end
		if match then return preset end
	end
	return nil
end

local SLIDER_BY_KEY = {}
for _, s in ipairs(W.SLIDERS) do SLIDER_BY_KEY[s.key] = s end

------------------------------------------------------------
-- Storage
------------------------------------------------------------
-- The first cut of this panel stored 0-2 multipliers. Reading those as the
-- point values they now are would silently set travel to 1 point and odds to 1
-- point -- a wildly different addon, with no symptom a player could attribute.
-- Stamp the schema and drop slider values from before it; the ORDER is still
-- meaningful and is kept.
local SCHEMA = 2

local function store()
	local db = MM.db.weights
	if not db then
		db = { schema = SCHEMA }
		MM.db.weights = db
	elseif db.schema ~= SCHEMA then
		local order = db.order
		wipe(db)
		db.order, db.schema = order, SCHEMA
	end
	return db
end

-- A saved order can be stale: a tier added in a later version would be missing
-- and would silently drop out of ranking. Validate against DEFAULT_ORDER every
-- read -- unknown keys dropped, missing keys appended in default position.
local function validOrder(saved)
	local known, seen, out = {}, {}, {}
	for _, key in ipairs(W.DEFAULT_ORDER) do known[key] = true end
	for _, key in ipairs(saved or {}) do
		if known[key] and not seen[key] then
			seen[key] = true
			out[#out + 1] = key
		end
	end
	for _, key in ipairs(W.DEFAULT_ORDER) do
		if not seen[key] then out[#out + 1] = key end
	end
	return out
end

function W.Order()
	return validOrder(store().order)
end

-- Slider steps are not all whole numbers, so "is this the default" needs a
-- tolerance finer than the smallest step rather than a fixed epsilon.
local function same(a, b, def)
	return math.abs(a - b) < ((def and def.step or 0.05) / 2)
end

function W.IsDefaultOrder()
	local order = W.Order()
	for i, key in ipairs(W.DEFAULT_ORDER) do
		if order[i] ~= key then return false end
	end
	return true
end

-- Move the tier at `index` up (-1) or down (1). Returns its new index, or nil
-- if the move would fall off the list.
function W.Move(index, delta)
	local order = W.Order()
	local target = index + delta
	if not order[index] or not order[target] then return nil end
	order[index], order[target] = order[target], order[index]
	store().order = order
	W.Changed()
	return target
end

function W.Get(key)
	local def = SLIDER_BY_KEY[key]
	local value = store()[key]
	if type(value) ~= "number" then return def and def.default or 1 end
	if def then
		if value < def.min then return def.min end
		if value > def.max then return def.max end
	end
	return value
end

function W.Set(key, value)
	local def = SLIDER_BY_KEY[key]
	if not def then return end
	value = math.max(def.min, math.min(def.max, value))
	-- Storing nil at the default keeps SavedVariables clean and means a future
	-- change of default reaches anyone who never touched the slider.
	-- Written long-hand on purpose: `cond and nil or value` collapses back to
	-- `value` in Lua, so the idiomatic one-liner would silently persist every
	-- default it was meant to clear.
	if same(value, def.default, def) then
		store()[key] = nil
	else
		store()[key] = value
	end
	W.Changed()
end

function W.IsDefault()
	if not W.IsDefaultOrder() then return false end
	for _, s in ipairs(W.SLIDERS) do
		if not same(W.Get(s.key), s.default, s) then return false end
	end
	return true
end

function W.Reset()
	MM.db.weights = nil
	W.Changed()
end

-- Ranking is memoized in several places; anything cached on the old weights is
-- now wrong, so invalidate before telling the UI to redraw.
-- Try several settings, tell the world once.
--
-- W.Changed fires MM_PLAN_CHANGED, which re-plans. Anything that applies more
-- than one setting in a row therefore re-plans more than once, for states
-- nobody will ever see -- the preset round-trip check applies four and threw
-- "script ran too long" on slower hardware doing it. The work was never
-- needed: what it was checking is that the weights table reads back as the
-- preset that wrote it, and no part of that asks the plan anything.
--
-- The caller announces the settled state itself, once, at the end.
local silent = false
function W.Silent(fn)
	local was = silent
	silent = true
	local ok, err = pcall(fn)
	silent = was
	if not ok then error(err, 0) end
end

function W.Changed()
	if silent then return end
	if MM.Availability and MM.Availability.InvalidateStatus then
		MM.Availability.InvalidateStatus()
	end
	MM:Fire("MM_WEIGHTS_CHANGED")
	MM:Fire("MM_PLAN_CHANGED")
end

------------------------------------------------------------
-- Making a change actually land
------------------------------------------------------------
-- Changing the weights re-scores everything, but the PLAN stores its own order
-- and only ever rewrites it when Optimize is pressed. So a player could
-- rearrange the priority list, watch nothing move, and reasonably conclude the
-- settings were not wired to anything. They were wired to the scoring and not
-- to the artefact the player was looking at, which is the same thing as not
-- being wired at all.
--
-- Re-optimize on a change, debounced: dragging a slider fires this on every
-- step and a full Router build over a few hundred goals is not free.
local pending
W.blockedByRoute = false   -- kept for compatibility; never set now

local function applyToPlan()
	pending = nil
	if not (MM.Planner and MM.cdb and MM.cdb.plan and #MM.cdb.plan > 0) then return end

	-- A SETTING ALWAYS TAKES EFFECT. Refusing to re-optimize while a route was
	-- running, and telling the player to stop the route, optimize, and start
	-- again, made the player do the addon's bookkeeping by hand. Changing a
	-- setting and watching nothing happen is indistinguishable from a bug.
	--
	-- Nothing is pinned, deliberately. Elsewhere it would be rude to re-point
	-- someone mid-journey, but adjusting weights and priorities is the one
	-- action whose entire purpose is "re-order my plan" -- so holding the
	-- current goal in place would be ignoring what was just asked for.
	MM.Planner:Optimize()
end

MM:On("MM_WEIGHTS_CHANGED", function()
	if pending then return end
	pending = true
	C_Timer.After(0.5, applyToPlan)
end)

------------------------------------------------------------
-- What Planner asks for
------------------------------------------------------------
-- Position of a tier in the player's order, 1-based. BLOCKED is pinned past the
-- end so it can never be promoted, whatever is saved.
local rankCache, rankCacheOrder
function W.TierRank(tier)
	local P = MM.Planner
	if not P then return tier end
	if tier == P.TIER.BLOCKED then return #W.DEFAULT_ORDER + 1 end
	local order = W.Order()
	if rankCacheOrder ~= table.concat(order, ",") then
		rankCache = {}
		rankCacheOrder = table.concat(order, ",")
		for i, key in ipairs(order) do rankCache[P.TIER[key]] = i end
	end
	return rankCache[tier] or (#W.DEFAULT_ORDER + 1)
end

MM:On("MM_WEIGHTS_CHANGED", function() rankCache, rankCacheOrder = nil, nil end)

-- Era preference as a signed subscore adjustment. A positive `era` slider makes
-- legacy content cheaper and current content dearer; negative does the reverse.
-- 600 is a little over half a tier's worth of subscore, so it reorders within a
-- tier without ever jumping one.
-- Signed points: positive `era` makes legacy content cheaper and current
-- content dearer, negative does the reverse.
function W.EraAdjust(rec)
	local pref = W.Get("era")
	if pref == 0 or not rec or not rec.expansion then return 0 end
	local current = (tonumber((GetBuildInfo():match("^(%d+)"))) or 12) - 1
	local isLegacy = rec.expansion < current - 1
	return isLegacy and -pref or pref
end

-- Display form. Points are whole numbers; factors are not.
function W.Format(def, value)
	if def.unit == "points" or def.unit == "points per step"
		or def.unit == "points at worst" or def.unit == "minutes" then
		-- floor of value+0.5, not "%d" on a float: Lua 5.3+ refuses to format a
		-- number with no integer representation, and the sliders deal in halves
		-- of a step
		return tostring(math.floor(value + (value < 0 and -0.5 or 0.5)))
	end
	return ("%.2f"):format(value)
end

------------------------------------------------------------
-- /mm weights — what is actually in force
------------------------------------------------------------
MM:On("MM_WEIGHTS_DEBUG", function()
	MM:Print("Weights & priorities: %s",
		W.IsDefault() and "all defaults" or "|cffffd200customised|r")
	local parts = {}
	for i, key in ipairs(W.Order()) do parts[i] = ("%d.%s"):format(i, key) end
	MM:Print("  order: %s%s", table.concat(parts, " "),
		W.IsDefaultOrder() and "" or "  |cffffd200(reordered)|r")
	for _, s in ipairs(W.SLIDERS) do
		local v = W.Get(s.key)
		MM:Print("  %-9s %s%s", s.key, W.Format(s, v),
			same(v, s.default, s) and "" or (" |cffffd200(default %s)|r"):format(W.Format(s, s.default)))
	end
end)
