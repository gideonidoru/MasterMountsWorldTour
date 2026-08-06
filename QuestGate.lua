-- Master Mounts: prerequisite gating.
--
-- The planner's job is to hand you a list you can actually act on. A mount
-- whose quest chain has not been unlocked, whose profession you never took, or
-- that belongs to the other faction is not a goal -- it is noise that pushes a
-- real goal off the screen. Worse, routing one sends you somewhere nothing can
-- happen, which is the fastest way to lose a player's trust in the whole addon.
--
-- Two kinds of check live here:
--
--  1. QUEST CHAINS. A record can name the chain that leads to its mount. We
--     report where you are in it, and refuse to route a mount whose chain has
--     not been unlocked yet.
--  2. HARD GATES. Requirements that cannot be satisfied by going where the
--     route would send you -- wrong class, wrong faction, a profession you do
--     not have, an unfinished prerequisite quest.
--
-- The distinction that matters: a reputation bar or a currency total is NOT a
-- gate. That is the work itself, and routing you to it is the whole point. Only
-- things you cannot make progress on by being there are gates.
local _, MM = ...

MM.QuestGate = {}
local QG = MM.QuestGate

local function completed(id)
	return id and C_QuestLog.IsQuestFlaggedCompleted(id) or false
end

local function onQuest(id)
	return id and C_QuestLog.IsOnQuest and C_QuestLog.IsOnQuest(id) or false
end

local function title(id, fallback)
	local t = id and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(id)
	return t or fallback or (id and ("quest #" .. id)) or "a quest"
end

------------------------------------------------------------
-- Quest chains
------------------------------------------------------------
-- rec.questChain = {
--   prereq = { id, ... },   -- must be complete before the chain unlocks
--   start  = questID,       -- first quest of the chain
--   final  = questID,       -- the one that awards (or unlocks) the mount
--   steps  = n,             -- how many quests long, for the estimate line
--   timeGated = true,       -- released one step per week
--   name   = "…",           -- display fallback when titles aren't cached
-- }
--
-- Returns state, text. States:
--   DONE        chain finished
--   IN_PROGRESS you are on it right now
--   READY       unlocked and startable
--   BLOCKED     a prerequisite is missing -- do not route this
--   nil         no chain recorded
function QG.ChainState(rec)
	local ch = rec and rec.questChain
	if not ch then return nil end

	-- A missing prerequisite is the one genuinely blocking case: the quest
	-- giver will not talk to you, so travelling there achieves nothing.
	for _, id in ipairs(ch.prereq or {}) do
		if not completed(id) then
			return "BLOCKED", ("Locked until you finish %s"):format(title(id, ch.name))
		end
	end

	if ch.final and completed(ch.final) then
		return "DONE", "Quest chain complete"
	end

	-- Any step in your log means the chain is live for you right now.
	for _, id in ipairs({ ch.start, ch.final }) do
		if onQuest(id) then
			return "IN_PROGRESS", ("On the chain now — %s"):format(title(id, ch.name))
		end
	end

	if ch.start and completed(ch.start) then
		local extra = ch.timeGated and " (one step unlocks per week)" or ""
		return "IN_PROGRESS", ("Chain started — continue it%s"):format(extra)
	end

	local extra = ""
	if ch.steps then extra = (" — %d quests"):format(ch.steps) end
	if ch.timeGated then extra = extra .. ", one per week" end
	return "READY", ("Pick up %s%s"):format(title(ch.start, ch.name), extra)
end

-- The step of a chain this character is actually on.
--
-- A chain is not one destination, it is a sequence of them, and sending someone
-- to the final quest giver before they have earned the right to talk to them is
-- the same failure as sending them nowhere. So we walk the steps, ask the game
-- which are already done, and hand back the first one that is not.
--
-- Steps without a recorded location are skipped for ROUTING but still counted
-- for progress, so a gap in our data delays the arrow rather than stopping it.
-- Returns step, index, total.
function QG.CurrentStep(rec)
	local ch = rec and rec.questChain
	local path = ch and ch.path
	if not (path and #path > 0) then return nil end

	for i, stepEntry in ipairs(path) do
		if not (stepEntry.id and completed(stepEntry.id)) then
			-- the first unfinished step; fall forward to the next one that has
			-- somewhere to point, so a missing coordinate is not a dead end
			for j = i, #path do
				if path[j].zone then return path[j], j, #path end
			end
			return stepEntry, i, #path
		end
	end
	return nil, #path, #path  -- every step done
end

------------------------------------------------------------
-- Hard gates
------------------------------------------------------------
local CLASS_TOKENS = {
	["death knight"] = "DEATHKNIGHT", ["demon hunter"] = "DEMONHUNTER",
	warrior = "WARRIOR", paladin = "PALADIN", hunter = "HUNTER", rogue = "ROGUE",
	priest = "PRIEST", shaman = "SHAMAN", mage = "MAGE", warlock = "WARLOCK",
	monk = "MONK", druid = "DRUID", evoker = "EVOKER",
}

-- A CLASS-category record names its class in the source text rather than in a
-- field, so that is where we have to look for it.
local function wrongClass(rec)
	if rec.category ~= "CLASS" then return nil end
	local hay = ((rec.source or "") .. " " .. (rec.notes or "")):lower()
	local mine = select(2, UnitClass("player"))
	for word, token in pairs(CLASS_TOKENS) do
		if hay:find(word, 1, true) then
			-- only claim a mismatch when we positively identified a class
			if token ~= mine then
				return ("%s only"):format(word:gsub("^%l", string.upper))
			end
			return nil
		end
	end
	return nil
end
QG.WrongClass = wrongClass

-- Race, read the same way and for the same reason: a heritage mount names its
-- race in prose and nowhere else.
--
-- NOT a routing gate -- it is not in HardGate. A record is race-locked for the
-- CHARACTER, and the plan is account-wide, so a Blood Elf mount is real work
-- for someone in the warband. What it does explain is why a mount is missing
-- from THIS character's journal, which is a question the audit asks.
local RACE_TOKENS = {
	"blood elf", "night elf", "void elf", "lightforged draenei", "dark iron dwarf",
	"highmountain tauren", "mag'har orc", "zandalari troll", "kul tiran",
	"mechagnome", "vulpera", "nightborne", "earthen", "haranir", "dracthyr",
	"pandaren", "worgen", "goblin", "gnome", "dwarf", "orc", "tauren", "troll",
	"undead", "draenei", "human",
}

-- THE RACE HAS TO BE THE THING BEING REQUIRED.
--
-- A first cut looked for a requirement WORD anywhere in the text and a race
-- name anywhere else in it. "Only available during Brewfest" plus a dwarf
-- mentioned in the flavour text is then a race lock, and a mount quietly
-- stops being reported as missing for the wrong reason -- which is worse than
-- not checking, because it silences the very list that would have shown it.
--
-- So the race and the requirement must be the SAME phrase. These four
-- wordings are the ones the database actually uses.
local function requirementFor(hay, race)
	local r = race:gsub("%-", "%%-"):gsub("'", "'")
	return hay:find("requires? an? " .. r)
		or hay:find(r .. "%-only")
		or hay:find(r .. " heritage")
		or hay:find(r .. " characters? only")
		or hay:find(r .. " only")
end

function QG.WrongRace(rec)
	if not rec then return nil end
	local hay = ((rec.source or "") .. " " .. (rec.notes or "")):lower()
	local mine = select(2, UnitRace("player"))
	mine = mine and mine:lower():gsub("[^%a]", "") or ""
	-- Longest first, so "blood elf" is not shadowed by "elf" inside it.
	for _, word in ipairs(RACE_TOKENS) do
		if requirementFor(hay, word) then
			if mine ~= word:gsub("[^%a]", "") then
				return (word:gsub("(%a)([%w']*)", function(a, b)
					return a:upper() .. b end) .. " only")
			end
			return nil
		end
	end
	return nil
end

local function knownProfessions()
	local set = {}
	for _, index in ipairs({ GetProfessions() }) do
		local name = GetProfessionInfo(index)
		if name then set[name:lower()] = true end
	end
	return set
end

-- Returns a reason string when this mount must NOT be routed, else nil.
function QG.HardGate(rec)
	if not rec then return nil end

	if rec.faction and MM.playerFaction and rec.faction ~= MM.playerFaction then
		return ("%s only"):format(rec.faction)
	end

	local cls = wrongClass(rec)
	if cls then return cls end

	local chainState, chainText = QG.ChainState(rec)
	if chainState == "BLOCKED" then return chainText end

	for _, cond in ipairs(rec.conditions or {}) do
		-- An unfinished prerequisite quest is separate content; standing at the
		-- mount's location does nothing for it.
		if cond.type == "QUEST" and cond.id and not completed(cond.id) then
			-- ...unless you are actively on it, in which case going there IS
			-- how you finish it
			if not onQuest(cond.id) then
				return ("Requires %s"):format(title(cond.id, cond.name))
			end
		end
		if cond.type == "PROFESSION" and cond.name then
			local have = knownProfessions()
			if not have[cond.name:lower()] then
				return ("Requires %s"):format(cond.name)
			end
		end
	end

	return nil
end

-- Cheap wrapper so callers can ask without caring how it was decided.
function QG.IsBlocked(rec)
	return QG.HardGate(rec) ~= nil
end

-- /mm gates — everything in the plan that is being held back, and why
MM:On("MM_GATES_DEBUG", function()
	local n = 0
	for _, entry in ipairs(MM.Planner:GetPlan()) do
		local why = QG.HardGate(entry.rec)
		if why then
			n = n + 1
			MM:Print("  |cffff9a3c%s|r — %s", entry.name, why)
		end
	end
	if n == 0 then
		MM:Print("Nothing in the plan is prerequisite-blocked.")
	else
		MM:Print("%d goal%s held back — they'd send you somewhere nothing can happen.",
			n, n == 1 and "" or "s")
	end
end)
