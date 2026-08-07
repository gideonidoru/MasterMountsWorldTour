-- Master Mounts conditions: evaluates a record's requirement list against the
-- character (rep, quests, achievements, items, currency, professions).
local _, MM = ...
local U = MM.Util

MM.Conditions = {}
local C = MM.Conditions

-- Dead-simple "where does this currency even come from" guide, keyed by
-- lowercased currency name. Records can also carry their own `how` on any
-- condition, which wins over this table.
local CURRENCY_HELP = {
	["timewarped badge"] = "Run Timewalking dungeons during any TW event week (~55/run) and grab the 500-badge weekly quest.",
	["trader's tender"] = "Earned monthly from the Trading Post traveler's log activities + the monthly login gift.",
	["darkmoon prize ticket"] = "Play Darkmoon Faire games and turn in profession/artifact quests during the monthly Faire (first week of each month).",
	["curious coin"] = "Random reward from Legion world quests, emissary caches, and Broken Isles activities.",
	["champion's seal"] = "Argent Tournament dailies at the tournament grounds in northeast Icecrown.",
	["bloody coin"] = "Use the Censer of Eternal Agony on Timeless Isle and kill other flagged players.",
	["grateful offering"] = "Shadowlands covenant callings and anima conductor world quests award these.",
	["paracausal flake"] = "Time Rift events in Thaldraszus (Dragonflight 10.1.5), every hour.",
	["mark of honor"] = "Win battlegrounds, arenas, and PvP brawls.",
	["timeless coin"] = "Kill rares, open chests, and do events on the Timeless Isle.",
	["dubloon"] = "Complete BfA Island Expeditions; bonus for the weekly quest.",
	["seafarer's dubloon"] = "Complete BfA Island Expeditions; bonus for the weekly quest.",
}

function C.HowFor(cond)
	if cond.how then return cond.how end
	if cond.type == "CURRENCY" and cond.name then
		return CURRENCY_HELP[cond.name:lower()]
	end
	return nil
end

-- Paragon, as numbers rather than a verdict.
--
-- Returns: fraction into the CURRENT cache bar, rep remaining to fill it, and
-- whether a finished cache is already sitting unclaimed. nil when the faction
-- has no paragon unlocked or the API cannot answer.
function C.ParagonProgress(cond)
	if not (cond and cond.factionID and C_Reputation) then return nil end
	if not (C_Reputation.IsFactionParagon and C_Reputation.IsFactionParagon(cond.factionID)) then
		return nil
	end
	local ok, value, threshold, _, hasRewardPending =
		pcall(C_Reputation.GetFactionParagonInfo, cond.factionID)
	if not ok or not (value and threshold and threshold > 0) then return nil end
	local into = (value % threshold) / threshold
	return into, threshold - (value % threshold), hasRewardPending and true or false
end

local function evalRep(cond)
	local label = cond.factionName or "reputation"
	local renownTarget = cond.standingName and cond.standingName:match("^Renown (%d+)$")

	if renownTarget and cond.factionID and C_MajorFactions and C_MajorFactions.GetMajorFactionData then
		local data = C_MajorFactions.GetMajorFactionData(cond.factionID)
		if data and data.renownLevel then
			local target = tonumber(renownTarget)
			local met = data.renownLevel >= target
			return met, ("%s: Renown %d/%d"):format(label, data.renownLevel, target)
		end
		return nil, ("%s: Renown %s required"):format(label, renownTarget)
	end

	-- Paragon.
	--
	-- Requirement — It's still showing Paragon rewards when I do not have enough xp for
	-- paragon (fierce razorwing, beryl shardhide, soulbound gloomcharger).
	--
	-- The bug was a misread API. `IsFactionParagon` answers "does this faction
	-- HAVE paragon unlocked" -- true the moment you hit Exalted -- and this
	-- treated it as "you have a cache waiting". So the condition reported MET,
	-- which sent the record down the "Requirements met -- just go buy it"
	-- branch and ranked a repeated rep grind as a PICKUP: the same tier as
	-- walking to a vendor with the currency already in your bag.
	--
	-- `GetFactionParagonInfo` is the function that actually knows. It returns
	-- five values and only the first two were being read; `hasRewardPending` is
	-- the fourth, and it is the one that means what this code was claiming.
	if cond.standingName == "Paragon" and cond.factionID and C_Reputation then
		if not (C_Reputation.IsFactionParagon and C_Reputation.IsFactionParagon(cond.factionID)) then
			return false, label .. ": Paragon (reach Exalted first, then fill the paragon bar)"
		end
		local ok, value, threshold, _, hasRewardPending =
			pcall(C_Reputation.GetFactionParagonInfo, cond.factionID)
		if ok and hasRewardPending then
			-- a cache is sitting there unclaimed: this genuinely IS a pickup
			return true, label .. ": paragon cache ready to open"
		end
		if ok and value and threshold and threshold > 0 then
			local remaining = threshold - (value % threshold)
			return false, ("%s: %s rep to the next paragon cache")
				:format(label, U.Comma(math.floor(remaining)))
		end
		return false, label .. ": Paragon unlocked, but the bar is not full"
	end

	if cond.factionID and C_Reputation and C_Reputation.GetFactionDataByID then
		local data = C_Reputation.GetFactionDataByID(cond.factionID)
		if data then
			local target = U.STANDING[cond.standingName] or 8
			local met = (data.reaction or 0) >= target
			if met then
				return true, ("%s: %s reached"):format(label, cond.standingName or "Exalted")
			end
			local remaining = U.RepRemainingToTarget(data.reaction, data.currentStanding,
				data.nextReactionThreshold, target)
			local text = ("%s: %s rep to %s"):format(label,
				U.Comma(remaining or 0), cond.standingName or "Exalted")
			if remaining and remaining > 0 then
				-- rough planning figure: a world quest / daily turn-in averages ~150-250 rep
				local perAction = (cond.perAction and cond.perAction.amount) or 200
				local actionLabel = (cond.perAction and cond.perAction.label) or "quests/turn-ins"
				text = text .. (" (~%d %s)"):format(math.ceil(remaining / perAction), actionLabel)
			end
			return false, text
		end
	end
	return nil, ("%s: %s required"):format(label, cond.standingName or "Exalted")
end

-- How far along the required reputation you are: fraction 0..1 (1 = met),
-- plus a short label. Paragon requires Exalted FIRST, so with no Exalted the
-- fraction is capped well below 1 — a paragon cache with zero rep is a full
-- rep grind plus a paragon bar, not a "cache you can go open".
function C.RepProgress(cond)
	if not cond or cond.type ~= "REP" then return nil end
	local label = cond.factionName or "reputation"

	local renownTarget = cond.standingName and cond.standingName:match("^Renown (%d+)$")
	if renownTarget and cond.factionID and C_MajorFactions and C_MajorFactions.GetMajorFactionData then
		local data = C_MajorFactions.GetMajorFactionData(cond.factionID)
		if data and data.renownLevel then
			local target = tonumber(renownTarget)
			return math.min(1, data.renownLevel / math.max(target, 1)),
				("%s: Renown %d/%d"):format(label, data.renownLevel, target)
		end
		return nil, label
	end

	if not (cond.factionID and C_Reputation and C_Reputation.GetFactionDataByID) then
		return nil, label
	end
	local data = C_Reputation.GetFactionDataByID(cond.factionID)
	if not data then return nil, label end

	local reaction = data.reaction or 4
	local isParagon = cond.standingName == "Paragon"
	-- rough cumulative rep from Neutral to Exalted
	local CUMULATIVE = { [4] = 0, [5] = 3000, [6] = 9000, [7] = 21000, [8] = 42000 }
	local earned = (CUMULATIVE[reaction] or 0) + (data.currentStanding or 0)
	local toExalted = math.min(1, earned / 42000)

	if isParagon then
		if reaction >= 8 and C_Reputation.IsFactionParagon
			and C_Reputation.IsFactionParagon(cond.factionID) then
			local ok, value, threshold, _, hasRewardPending =
				pcall(C_Reputation.GetFactionParagonInfo, cond.factionID)
			if ok and hasRewardPending then
				return 1, label .. ": paragon cache ready to open"
			end
			if ok and value and threshold and threshold > 0 then
				local into = (value % threshold) / threshold
				-- Never reaches 1: a full bar is one cache, and the mount is a
				-- CHANCE from that cache, not the cache itself.
				return 0.8 + 0.19 * into,
					("%s: Paragon %d%% to next cache"):format(label, math.floor(into * 100))
			end
			return 0.8, label .. ": Paragon unlocked, bar not full"
		end
		-- not Exalted yet: paragon is Exalted + a full paragon bar beyond it
		return toExalted * 0.75,
			("%s: %d%% to Exalted, THEN a paragon bar"):format(label, math.floor(toExalted * 100))
	end

	local target = U.STANDING[cond.standingName] or 8
	if reaction >= target then return 1, label .. ": " .. (cond.standingName or "Exalted") .. " reached" end
	local targetRep = CUMULATIVE[target] or 42000
	return math.min(0.99, earned / math.max(targetRep, 1)),
		("%s: %d%% to %s"):format(label, math.floor(earned / targetRep * 100),
			cond.standingName or "Exalted")
end

-- Best rep progress across a record's conditions (nil if it has none).
function C.RecordRepProgress(rec)
	if not (rec and rec.conditions) then return nil end
	local worst, worstLabel
	for _, cond in ipairs(rec.conditions) do
		if cond.type == "REP" then
			local frac, label = C.RepProgress(cond)
			if frac and (not worst or frac < worst) then worst, worstLabel = frac, label end
		end
	end
	return worst, worstLabel
end

-- How far through an achievement you are, 0..1, or nil when we cannot tell.
--
-- "Complete or not" is a wildly coarse answer for a meta that wants twelve
-- raids: someone eleven-twelfths of the way through is nearly finished and
-- someone at zero has a project. The criteria carry that and nothing was
-- reading them.
function C.AchievementProgress(rec)
	if not (rec and rec.conditions and GetAchievementNumCriteria) then return nil end
	local worst
	for _, cond in ipairs(rec.conditions) do
		if cond.type == "ACHIEVEMENT" and cond.id then
			local _, _, _, completed = GetAchievementInfo(cond.id)
			local frac
			if completed then
				frac = 1
			else
				local ok, total = pcall(GetAchievementNumCriteria, cond.id)
				if ok and total and total > 0 then
					local done = 0
					for i = 1, total do
						local got, _, _, met, quantity, required = pcall(
							GetAchievementCriteriaInfo, cond.id, i)
						if got then
							if met then
								done = done + 1
							elseif quantity and required and required > 0 then
								-- a progress-bar criterion counts fractionally
								done = done + math.min(quantity / required, 1)
							end
						end
					end
					frac = done / total
				else
					frac = 0
				end
			end
			if frac and (not worst or frac < worst) then worst = frac end
		end
	end
	return worst
end

local function evalQuest(cond)
	if not cond.id then return nil, "Quest: " .. (cond.name or "unknown") end
	local done = C_QuestLog.IsQuestFlaggedCompleted(cond.id)
	return done, ("Quest: %s%s"):format(cond.name or ("#" .. cond.id), done and " (done)" or "")
end

local function evalAchievement(cond)
	if not cond.id then return nil, "Achievement: " .. (cond.name or "unknown") end
	local _, achName, _, completed = GetAchievementInfo(cond.id)
	return completed or false,
		("Achievement: %s%s"):format(cond.name or achName or ("#" .. cond.id),
			completed and " (done)" or "")
end

-- HOW MANY, NOT WHETHER ANY.
--
-- Reported from outside: told to go and buy the Asset Advocator "even though I
-- didn't have the currency for it". The record is fully modelled -- 25
-- Miscellaneous Mechanica, plus two quests -- and this function threw the
-- amount away and asked `> 0`. One of twenty-five read as satisfied, so
-- EvaluateAll returned true and the mount ranked as "Requirements met -- just
-- go buy it".
--
-- Sixty ITEM conditions in the database carry an amount above one. Every Alterac
-- Valley mount wants 15 Marks of Honor; a single Mark answered for all fifteen.
-- evalCurrency has compared against `amount` from the start -- this is the same
-- question about a different kind of token, and it never got the same answer.
--
-- MATERIAL rows come here too now. They had no evaluator at all, so 105 reagent
-- requirements returned "Unknown requirement" and printed that in the tooltip.
-- They are items with a count, which is exactly what this function is for.
local function evalItem(cond)
	local label = cond.name or (cond.id and ("item #" .. cond.id)) or "item"
	if cond.cost then label = label .. " (" .. cond.cost .. ")" end
	if not cond.id and not cond.itemID then return nil, "Item: " .. label end

	local id = cond.id or cond.itemID
	local need = cond.amount or cond.count or 1
	-- Bank, reagent bank and the warband bank all count: the vendor cares that
	-- you own them, and a stack sitting in the bank is a walk, not a grind.
	local have = C_Item.GetItemCount(id, true, false, true, true) or 0

	-- One is the "do you have the thing" case -- a key, a mask, a saddle -- and
	-- it reads better as owned/not owned than as 1 / 1.
	if need <= 1 then
		return have > 0, ("Item: %s%s"):format(label, have > 0 and " (owned)" or "")
	end
	return have >= need, ("%s: %s / %s"):format(cond.name or "Item",
		U.Comma(have), U.Comma(need))
end

-- Currencies referenced by name only (records omit IDs they weren't sure of)
-- resolve against the character's own currency list. Undiscovered = you have 0.
local currencyByName
local function currencyQuantityByName(name)
	if not name then return nil end
	if not currencyByName then
		currencyByName = {}
		local size = C_CurrencyInfo.GetCurrencyListSize and C_CurrencyInfo.GetCurrencyListSize() or 0
		for i = 1, size do
			local ok, info = pcall(C_CurrencyInfo.GetCurrencyListInfo, i)
			if ok and info and info.name and not info.isHeader then
				currencyByName[info.name:lower()] = info.quantity or 0
			end
		end
	end
	return currencyByName[name:lower()]
end

MM:RegisterGameEvent("CURRENCY_DISPLAY_UPDATE", function()
	currencyByName = nil -- quantities changed; rebuild lazily
end)

local function evalCurrency(cond)
	local need = cond.amount or 0
	local have
	if cond.id then
		local info = C_CurrencyInfo.GetCurrencyInfo(cond.id)
		have = info and info.quantity or 0
	else
		have = currencyQuantityByName(cond.name) or 0
	end
	if need <= 0 then
		-- record doesn't know the cost — that is NOT the same as "affordable"
		return nil, ("%s: cost unknown (%s held)"):format(cond.name or "Currency", U.Comma(have))
	end
	return have >= need, ("%s: %s / %s"):format(cond.name or "Currency",
		U.Comma(have), U.Comma(need))
end

-- The client knows perfectly well which professions you have, and this asked it
-- nothing -- it returned "unverified" for every profession requirement in the
-- database, so Fossilized Raptor sat in the gates list as an open question on a
-- character who plainly had no Archaeology. The API probe passed the whole time
-- because it only checked that GetProfessions EXISTS.
--
------------------------------------------------------------
-- Per-expansion profession skill lines
------------------------------------------------------------
-- Requirement — each wormhole toy has a specific expansion + engineering level for
-- that expansion to use (usually its just 1 but sometimes it is not).
--
-- Right, and "usually 1" is exactly the trap. Read off the live tooltips:
--
--   Northrend Engineering   40    Wormhole Generator: Northrend
--   Classic Engineering    260    Gadgetzan, Everlook transporters
--   Outland Engineering     50    Toshley's Station, Area 52
--   everything else          1
--
-- And the detail nobody would guess: the **Zandalar** wormhole requires **Kul
-- Tiran** Engineering, not a Zandalari line. Reading each tooltip instead of
-- pattern-matching the name is the only reason that is right.
--
-- `GetProfessionInfo` answers about the profession as a whole and cannot see
-- these at all, so the check has to go through the trade-skill lines. Field
-- names on that struct have moved between expansions, so rather than trust one,
-- every string in it is folded into a haystack and matched loosely. `/mm travel`
-- dumps the raw lines, which is how to correct this if a client disagrees.
local skillLineCache

local function collectSkillLines()
	local out = {}
	local api = C_TradeSkillUI
	if not (api and api.GetAllProfessionTradeSkillLines) then return out end
	local ok, lines = pcall(api.GetAllProfessionTradeSkillLines)
	if not (ok and type(lines) == "table") then return out end
	for _, skillLineID in ipairs(lines) do
		local got, info = pcall(api.GetProfessionInfoBySkillLineID, skillLineID)
		if got and type(info) == "table" then
			local words = {}
			for _, value in pairs(info) do
				if type(value) == "string" and #value > 0 then
					words[#words + 1] = value:lower()
				end
			end
			-- Field names on this struct have moved between expansions, and on
			-- 12.0 `skillLevel` reads 0 even for professions the player plainly
			-- has -- a test character has Alchemy and Inscription and every line
			-- came back 0/0. So take the largest plausible number the struct
			-- offers rather than trusting one name, and keep the raw pairs for
			-- the diagnostic to print.
			local level, max = 0, 0
			local raw = {}
			for key, value in pairs(info) do
				if type(value) == "number" then
					raw[#raw + 1] = ("%s=%s"):format(key, tostring(value))
					local k = key:lower()
					if k:find("skilllevel") or k == "level" or k == "rank" then
						if value > level then level = value end
					elseif k:find("maxskill") or k == "maxlevel" or k == "maxrank" then
						if value > max then max = value end
					end
				end
			end
			out[#out + 1] = {
				id = skillLineID,
				text = table.concat(words, " "),
				raw = table.concat(raw, " "),
				level = level,
				max = max,
				label = info.professionName or info.parentProfessionName
					or info.expansionName or ("skill line " .. tostring(skillLineID)),
			}
		end
	end
	return out
end

-- ALL skill lines the client knows about -- which is every one in the game, not
-- the ones you have. a live report listed 156 "known" lines including Junkyard
-- Tinkering and Soul Cyphering, every one at 0/0, which is what
-- GetAllProfessionTradeSkillLines actually returns: the catalogue.
function C.SkillLines()
	if not skillLineCache then skillLineCache = collectSkillLines() end
	return skillLineCache
end

-- The ones you have actually levelled. This is the honest answer to "what are
-- my professions", and the difference between the two numbers is the difference
-- between a catalogue and a character.
function C.LearnedSkillLines()
	local out = {}
	for _, line in ipairs(C.SkillLines()) do
		if (line.level or 0) > 0 or (line.max or 0) > 0 then out[#out + 1] = line end
	end
	return out
end

-- The professions the player has, from the API that demonstrably works.
--
-- Cross-check, not replacement. `GetProfessions` cannot tell you which
-- EXPANSION's line you have levelled or how far, so it can never satisfy
-- "Northrend Engineering 40" on its own. What it can do is prove the skill-line
-- reader is wrong when the two disagree, which is exactly what happened.
function C.KnownProfessions()
	local out = {}
	if not (GetProfessions and GetProfessionInfo) then return out end
	for _, index in ipairs({ GetProfessions() }) do
		if index then
			local name, _, skillLevel, maxSkill = GetProfessionInfo(index)
			if name then
				out[#out + 1] = { name = name, level = skillLevel or 0, max = maxSkill or 0 }
			end
		end
	end
	return out
end

-- Does the player have this profession at all, by either reading?
function C.HasProfession(name)
	if not name then return false end
	local want = name:lower()
	for _, p in ipairs(C.KnownProfessions()) do
		if p.name:lower() == want then return true end
	end
	for _, line in ipairs(C.LearnedSkillLines()) do
		if line.text:find(want, 1, true) then return true end
	end
	return false
end

MM:RegisterGameEvent("SKILL_LINES_CHANGED", function() skillLineCache = nil end)
MM:RegisterGameEvent("TRADE_SKILL_LIST_UPDATE", function() skillLineCache = nil end)
MM:RegisterGameEvent("PLAYER_ENTERING_WORLD", function() skillLineCache = nil end)

-- Your level in a named expansion skill line ("Northrend Engineering"), or nil.
-- Every word of the name must appear, so "Kul Tiran Engineering" cannot be
-- satisfied by "Khaz Algar Engineering".
function C.SkillLineLevel(name)
	if not name then return nil end
	local needles = {}
	for word in name:lower():gmatch("[%a']+") do needles[#needles + 1] = word end
	if #needles == 0 then return nil end
	for _, line in ipairs(C.SkillLines()) do
		local all = true
		for _, needle in ipairs(needles) do
			if not line.text:find(needle, 1, true) then all = false break end
		end
		if all then return line.level, line.max end
	end
	return nil
end

-- Returns your skill level in the named profession, or nil if you lack it.
function C.ProfessionSkill(name)
	if not (GetProfessions and GetProfessionInfo and name) then return nil end
	local want = name:lower()
	for _, index in ipairs({ GetProfessions() }) do
		if index then
			local profName, _, skillLevel = GetProfessionInfo(index)
			if profName and profName:lower() == want then return skillLevel or 0 end
		end
	end
	return nil
end

local function evalProfession(cond)
	local label = ("Profession: %s%s"):format(cond.name or "?",
		cond.skill and (" (" .. cond.skill .. ")") or "")
	if not (GetProfessions and GetProfessionInfo) then return nil, label end
	local skill = C.ProfessionSkill(cond.name)
	if not skill then
		return false, label .. " — you don't have it"
	end
	if cond.skill and skill < cond.skill then
		return false, ("%s — you have %d"):format(label, skill)
	end
	return true, label
end

-- A COVENANT IS NOT A QUEST, AND THE CLIENT CAN BE ASKED WHICH ONE YOU ARE.
--
-- 53 conditions read { type = "QUEST", name = "Covenant: Night Fae" } and had
-- no id, which is how they came to be counted among the quest ids "nobody can
-- supply". They were never quests. There is no quest called Covenant: Night
-- Fae, so no lookup anywhere was ever going to find one -- the report was
-- promising a dead end and calling it a platform limit.
--
-- C_Covenants.GetActiveCovenantID answers it outright, and Callings.lua has
-- been using it for other purposes the whole time.
--
-- Deliberately soft. Covenants can be switched freely now, so this is "you are
-- not in the one that drops it" rather than a wall -- which is exactly what a
-- collector wants to be told, since the fix is a visit to Oribos.
local COVENANTS = { [1] = "Kyrian", [2] = "Venthyr", [3] = "Night Fae", [4] = "Necrolord" }

-- Renown too, when the condition asks for a level.
--
-- Covenant renown is NOT reputation and has no factionID, which is why 16
-- conditions asking for "Venthyr, Renown 23" carried no id and were written
-- off as unresolvable. C_CovenantSanctumUI.GetRenownLevel reports it directly.
--
-- It answers for the ACTIVE covenant only, so a level can be judged only while
-- the player is in that covenant -- which is honest: renown in a covenant you
-- have left is not progress toward this mount tonight.
local function covenantRenown()
	if not (C_CovenantSanctumUI and C_CovenantSanctumUI.GetRenownLevel) then return nil end
	local ok, level = pcall(C_CovenantSanctumUI.GetRenownLevel)
	if ok and type(level) == "number" then return level end
	return nil
end

local function evalCovenant(cond)
	local label = ("Covenant: %s"):format(cond.name or COVENANTS[cond.id] or "?")
	if cond.renown then label = ("%s, Renown %d"):format(label, cond.renown) end
	if not (cond.id and C_Covenants and C_Covenants.GetActiveCovenantID) then
		return nil, label
	end
	local ok, active = pcall(C_Covenants.GetActiveCovenantID)
	if not ok or not active or active == 0 then return nil, label end
	if active ~= cond.id then
		return false, ("%s — you are %s"):format(label, COVENANTS[active] or "another covenant")
	end
	if not cond.renown then return true, label .. " (active)" end
	local have = covenantRenown()
	if not have then return nil, label end
	if have >= cond.renown then return true, ("%s (you are %d)"):format(label, have) end
	return false, ("%s — you are Renown %d"):format(label, have)
end

-- How far through a covenant renown requirement, 0..1, or nil when it cannot
-- be judged. Same shape as RepProgress so the planner can price it the same
-- way rather than charging a flat unknown.
function C.CovenantProgress(cond)
	if not (cond and cond.type == "COVENANT" and cond.renown and cond.renown > 0) then
		return nil
	end
	if not (C_Covenants and C_Covenants.GetActiveCovenantID) then return nil end
	local ok, active = pcall(C_Covenants.GetActiveCovenantID)
	if not (ok and active == cond.id) then return nil end
	local have = covenantRenown()
	if not have then return nil end
	return math.min(have / cond.renown, 1)
end

local EVAL = {
	REP = evalRep, QUEST = evalQuest, ACHIEVEMENT = evalAchievement,
	ITEM = evalItem, CURRENCY = evalCurrency, PROFESSION = evalProfession,
	COVENANT = evalCovenant,
}

-- How far through a record's CURRENCY requirements are you? 0 = none of it,
-- 1 = fully affordable, nil = no currency requirement.
--
-- Ranking needs this for the same reason it needs reputation progress: a mount
-- costing 5,000 Timewarped Badges is a trivial pickup at 5,000 badges and a
-- multi-week grind at 0, and nothing distinguished those two states.
-- Progress on ONE currency requirement, 0..1, or nil if it is not one.
--
-- Split out from CurrencyProgress because that returns the WORST fraction
-- across a record -- fine for "how close am I", useless for costing, since two
-- separate currencies are two separate grinds and must be priced as two.
function C.CurrencyProgressFor(cond)
	if not (cond and cond.type == "CURRENCY" and (cond.amount or 0) > 0) then return nil end
	local have
	if cond.id and C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
		local info = C_CurrencyInfo.GetCurrencyInfo(cond.id)
		have = info and info.quantity or 0
	end
	if not have then return nil end
	return math.min(have / cond.amount, 1)
end

-- How long a currency actually takes, when the client can tell us.
--
-- Resolving currency ids unlocked something the addon could not previously see:
-- `GetCurrencyInfo` reports `canEarnPerWeek` and `quantityEarnedThisWeek`. A
-- currency with a weekly cap is not a grind whose length you estimate -- it is
-- ARITHMETIC. Needing 3,000 more of something capped at 750 a week is four
-- weeks, and no amount of playing harder changes that.
--
-- That is the difference between "this costs about eight hours" and "you cannot
-- have this before the 24th", and it is the single most useful thing the
-- planner can say about a capped currency.
--
-- Returns: weeksNeeded, perWeek, remaining -- or nil when there is no cap, in
-- which case the generic grind estimate is still the best available answer.
function C.CurrencyWeeks(cond)
	if not (cond and cond.type == "CURRENCY" and cond.id and (cond.amount or 0) > 0) then
		return nil
	end
	if not (C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo) then return nil end
	local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, cond.id)
	if not (ok and info) then return nil end

	local perWeek = info.maxQuantityPerWeek or info.canEarnPerWeek
	-- `canEarnPerWeek` is a BOOLEAN on some builds and a number on others, which
	-- is exactly the kind of thing that turns into a nonsense estimate if
	-- assumed. Only a positive number is a cap.
	if type(perWeek) ~= "number" or perWeek <= 0 then return nil end

	local remaining = math.max(0, cond.amount - (info.quantity or 0))
	if remaining <= 0 then return 0, perWeek, 0 end
	-- What is left of THIS week's allowance counts toward the first week.
	local thisWeek = math.max(0, perWeek - (info.quantityEarnedThisWeek or 0))
	if remaining <= thisWeek then return 1, perWeek, remaining end
	return 1 + math.ceil((remaining - thisWeek) / perWeek), perWeek, remaining
end

------------------------------------------------------------
-- What KIND of achievement is this?
------------------------------------------------------------
-- Users sometimes add Overachiever and InstanceAchievementTracker hoping they could say
-- which achievements are soloable. Neither can:
--
--   * InstanceAchievementTracker is "All Rights Reserved", so its data is off
--     limits regardless -- and it is a LIVE encounter tracker anyway, counting
--     criteria during a pull. Its `groupSize` is the size of your group right
--     now, not a requirement.
--   * Overachiever is a search and tooltip layer over the achievement API. Its
--     only "solo" strings are Spanish localisation.
--
-- The game answers it directly, and better than either would have. An
-- achievement's CATEGORY ancestry is authoritative: anything under Player vs.
-- Player needs opponents, anything under Guild needs a guild group. That is a
-- fact from the client rather than a guess from our own source text, which is
-- what we were reduced to.
--
-- Returns a table, or nil when the id is unknown to this client.
function C.AchievementClass(achievementID)
	if not (achievementID and GetAchievementCategory and GetCategoryInfo) then return nil end
	local ok, categoryID = pcall(GetAchievementCategory, achievementID)
	if not (ok and categoryID) then return nil end

	local path, guard = {}, 0
	local cursor = categoryID
	while cursor and cursor > 0 and guard < 12 do
		guard = guard + 1
		local got, name, parent = pcall(GetCategoryInfo, cursor)
		if not (got and name) then break end
		tinsert(path, 1, name)
		cursor = parent
	end
	if #path == 0 then return nil end

	local root = path[1]:lower()
	local joined = table.concat(path, " / "):lower()
	local criteria = 0
	if GetAchievementNumCriteria then
		local gotCount, n = pcall(GetAchievementNumCriteria, achievementID)
		if gotCount then criteria = n or 0 end
	end

	return {
		path = path,
		text = table.concat(path, " / "),
		pvp = root:find("player vs") ~= nil or joined:find("arena") ~= nil
			or joined:find("battleground") ~= nil,
		guild = root:find("guild") ~= nil,
		instanced = joined:find("dungeon") ~= nil or joined:find("raid") ~= nil,
		criteria = criteria,
	}
end

-- The achievement id a record depends on, if it names one.
function C.RecordAchievementID(rec)
	for _, cond in ipairs((rec and rec.conditions) or {}) do
		if cond.type == "ACHIEVEMENT" and cond.id then return cond.id end
	end
	return nil
end

-- Progress on ONE achievement requirement, 0..1, or nil if it is not one.
function C.AchievementProgressFor(cond)
	if not (cond and cond.type == "ACHIEVEMENT" and cond.id and GetAchievementInfo) then
		return nil
	end
	local _, _, _, completed = GetAchievementInfo(cond.id)
	if completed then return 1 end
	if not GetAchievementNumCriteria then return 0 end
	local ok, total = pcall(GetAchievementNumCriteria, cond.id)
	if not (ok and total and total > 0) then return 0 end
	local done = 0
	for i = 1, total do
		local got, _, _, met, quantity, required = pcall(GetAchievementCriteriaInfo, cond.id, i)
		if got then
			if met then
				done = done + 1
			elseif quantity and required and required > 0 then
				done = done + math.min(quantity / required, 1)
			end
		end
	end
	return done / total
end

-- How many criteria are actually left, and how many there are in total.
--
-- A meta with three criteria outstanding and one with thirty are not the same
-- job, and until the ids resolved there was no way to tell them apart -- every
-- unfinished achievement was charged the same flat six hours scaled by its
-- editorial effort rating.
--
-- Returns remaining, total. nil when the client cannot say.
function C.AchievementCriteriaLeft(cond)
	if not (cond and cond.type == "ACHIEVEMENT" and cond.id and GetAchievementNumCriteria) then
		return nil
	end
	local done, completed = pcall(GetAchievementInfo, cond.id)
	if done and select(4, GetAchievementInfo(cond.id)) then return 0, 0 end
	local ok, total = pcall(GetAchievementNumCriteria, cond.id)
	if not (ok and total and total > 0) then return nil end
	local left = 0
	for i = 1, total do
		local got, _, _, met = pcall(GetAchievementCriteriaInfo, cond.id, i)
		if got and not met then left = left + 1 end
	end
	return left, total
end

function C.CurrencyProgress(rec)
	if not (rec and rec.conditions) then return nil end
	local worst
	for _, cond in ipairs(rec.conditions) do
		if cond.type == "CURRENCY" and (cond.amount or 0) > 0 then
			local have
			if cond.id then
				local info = C_CurrencyInfo.GetCurrencyInfo(cond.id)
				have = info and info.quantity or 0
			else
				have = currencyQuantityByName(cond.name) or 0
			end
			local frac = math.min(have / cond.amount, 1)
			if not worst or frac < worst then worst = frac end
		end
	end
	return worst
end

-- Returns met (true/false/nil-unknown), text.
function C.Evaluate(cond)
	local fn = cond and cond.type and EVAL[cond.type]
	if not fn then return nil, "Unknown requirement" end
	local ok, met, text = pcall(fn, cond)
	if not ok then return nil, "Requirement (couldn't evaluate)" end
	return met, text
end

-- Returns allMet (true/false/nil if any unknown), lines = { {met=, text=} }.
function C.EvaluateAll(rec)
	if not rec or not rec.conditions or #rec.conditions == 0 then return true, {} end
	local allMet, anyUnknown = true, false
	local lines = {}
	for _, cond in ipairs(rec.conditions) do
		local met, text = C.Evaluate(cond)
		if met == false then allMet = false end
		if met == nil then anyUnknown = true end
		-- only unmet requirements need the "how" coaching
		tinsert(lines, { met = met, text = text, how = (met ~= true) and C.HowFor(cond) or nil })
	end
	if allMet and anyUnknown then return nil, lines end
	return allMet, lines
end
