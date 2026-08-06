-- Master Mounts: goals you reach by queueing, not by walking.
--
-- Requirement — recommending queueing for a dungeon should be represented and
-- respected in the nav (the arrow should change to the random dungeon queue,
-- etc).
--
-- Infinite Timereaver sat at the top of the route with an arrow
-- pointing at a location, because the router treats every goal as a place. It
-- is not a place. It drops from **any** Timewalking dungeon, and the way you
-- get to a Timewalking dungeon is the Dungeon Finder — there is nothing to fly
-- to and no door to stand outside.
--
-- Pointing an arrow at those is worse than pointing at nothing: it sends
-- someone across the world to a spot that will not help them.
--
-- So a goal can now say "this is queued for", and the nav answers with the
-- queue instead of a direction. Detection is deliberately conservative:
--
--   * an explicit `queue` field on the record always wins
--   * otherwise the source text has to SAY so, in the game's own words
--     ("any Timewalking dungeon", "Dungeon Finder", "random dungeon")
--
-- Anything ambiguous keeps the arrow, because a wrong arrow is recoverable and
-- a wrong "just queue for it" wastes an evening in the wrong queue.
local _, MM = ...

MM.Queue = {}
local Q = MM.Queue

------------------------------------------------------------
-- What kind of queue, if any
------------------------------------------------------------
-- Each kind knows how to describe itself and how to open the right window.
-- `dungeons` is the Dungeon Finder's own category id for Timewalking, which
-- changes between expansions -- so it is looked up rather than hardcoded, and
-- falls back to simply opening the finder if it cannot be found.
Q.KINDS = {
	timewalking = {
		label = "Queue for Timewalking",
		detail = "Any Timewalking dungeon — there is nowhere to fly to.",
		open = function()
			-- PVEFrame is the group finder; the Timewalking category lives
			-- inside the Dungeon Finder's list.
			if PVEFrame_ToggleFrame then
				pcall(PVEFrame_ToggleFrame, "GroupFinderFrame", nil)
			end
		end,
		live = function()
			return MM.Timewalking and MM.Timewalking.IsActive
				and MM.Timewalking.IsActive()
		end,
		blocked = "Timewalking is not running this week.",
	},
	dungeon = {
		label = "Queue for a random dungeon",
		detail = "Dungeon Finder — no travel needed.",
		open = function()
			if PVEFrame_ToggleFrame then
				pcall(PVEFrame_ToggleFrame, "GroupFinderFrame", nil)
			end
		end,
	},
	raid = {
		label = "Queue for Raid Finder",
		detail = "Raid Finder — no travel needed.",
		open = function()
			if PVEFrame_ToggleFrame then
				pcall(PVEFrame_ToggleFrame, "GroupFinderFrame", nil)
			end
		end,
	},
}

-- Phrases that mean "this is a queue, not a place". Matched against the
-- record's own source text, so the data does not have to be re-authored for
-- the feature to work -- but an explicit `queue` field overrides all of it.
local PHRASES = {
	{ kind = "timewalking", "any timewalking", "timewalking dungeon",
		"timewalking dungeons" },
	{ kind = "dungeon", "dungeon finder", "random dungeon", "random heroic" },
	{ kind = "raid", "raid finder", "looking for raid" },
}

function Q.KindFor(rec)
	if not rec then return nil end
	if rec.queue then return rec.queue, Q.KINDS[rec.queue] end

	local hay = ((rec.source or "") .. " " .. (rec.notes or "")):lower()
	if hay == " " then return nil end
	for _, group in ipairs(PHRASES) do
		for _, phrase in ipairs(group) do
			if hay:find(phrase, 1, true) then
				return group.kind, Q.KINDS[group.kind]
			end
		end
	end
	return nil
end

-- Everything the nav needs in one call: is this queued for, what should the
-- card say, and can it be queued right now?
function Q.Describe(rec)
	local kind, def = Q.KindFor(rec)
	if not (kind and def) then return nil end
	local ok = true
	if def.live then
		local fine, live = pcall(def.live)
		ok = (not fine) or live and true or false
	end
	return {
		kind = kind,
		label = def.label,
		detail = ok and def.detail or (def.blocked or def.detail),
		usable = ok,
		open = def.open,
	}
end

------------------------------------------------------------
-- /mm queue
------------------------------------------------------------
MM:On("MM_QUEUE_DEBUG", function()
	local counts, examples = {}, {}
	for _, rec in pairs(MM.DBByName) do
		if rec.obtainable then
			local kind = Q.KindFor(rec)
			if kind then
				counts[kind] = (counts[kind] or 0) + 1
				examples[kind] = examples[kind] or rec.name
			end
		end
	end
	local total = 0
	for kind, n in pairs(counts) do
		total = total + n
		local d = Q.Describe(MM.DBByName[examples[kind]])
		MM:Print("   %-12s %3d goals   e.g. %s   %s", kind, n, examples[kind],
			d and (d.usable and "|cff40d860queueable now|r"
				or ("|cffff9a3c" .. (d.detail or "not now") .. "|r")) or "")
	end
	if total == 0 then
		MM:Print("No goals are reached by queueing.")
	else
		MM:Print("%d goals are reached by QUEUEING, not by travelling. The arrow", total)
		MM:Print("   offers the queue for these instead of pointing at a location.")
	end
end)
