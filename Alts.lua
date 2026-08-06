-- Master Mounts alts: "which of my characters should I log into for this?"
--
-- We already evaluate typed requirements for the current character. This
-- stores a small snapshot of each character's progress toward the things
-- mounts actually gate on, so a mount needing Exalted can say "your Druid is
-- 90% there" instead of only ever describing whoever you're logged in as.
local _, MM = ...
local U = MM.Util

MM.Alts = {}
local A = MM.Alts

local function charKey()
	return ("%s-%s"):format(UnitName("player") or "?", GetRealmName() or "?")
end

local function ensure()
	MM.db.alts = MM.db.alts or {}
	local key = charKey()
	MM.db.alts[key] = MM.db.alts[key] or {}
	return MM.db.alts[key], key
end

------------------------------------------------------------
-- Snapshot the current character
------------------------------------------------------------
function A.Snapshot()
	if not MM.db then return end
	local me = ensure()
	me.class = select(2, UnitClass("player"))
	me.level = UnitLevel("player")
	me.faction = UnitFactionGroup("player")
	me.updated = GetServerTime()
	me.rep = me.rep or {}
	me.renown = me.renown or {}
	me.quests = me.quests or {}

	-- Which professions this character actually has.
	--
	-- Needed to answer "who should craft this". Without it the warband
	-- recommendation can only ever say "whoever harvested the recipe", which is
	-- one character rather than a real answer.
	me.skillLines = {}
	if C_TradeSkillUI and C_TradeSkillUI.GetAllProfessionTradeSkillLines then
		local ok, lines = pcall(C_TradeSkillUI.GetAllProfessionTradeSkillLines)
		if ok and type(lines) == "table" then
			for _, lineID in ipairs(lines) do
				-- The catalogue lists every profession in the GAME, so a line
				-- only counts when this character has levelled it.
				local okI, info = pcall(C_TradeSkillUI.GetProfessionInfoBySkillLineID, lineID)
				if okI and info and (info.skillLevel or 0) > 0 then
					me.skillLines[lineID] = info.skillLevel
				end
			end
		end
	end
	-- Fallback: GetProfessions reports the primaries even when skillLevel
	-- reads 0, which it does for every line on 12.0.
	-- NEVER CLEAR BEFORE READING.
	--
	-- This assigned an empty table and then refilled it, so any login where
	-- GetProfessions had nothing to say -- it is not always ready this early --
	-- saved the character as having no professions and threw away what was
	-- already known. Build aside, and only commit a result that found something.
	--
	-- GetProfessions returns SIX values with HOLES in them: two primaries, then
	-- archaeology, fishing, cooking, first aid, any of which may be nil. A table
	-- constructor keeps the holes and ipairs stops dead at the first one, so a
	-- character with no first primary but with cooking lost the lot. select()
	-- walks all six positions regardless of what is missing.
	if GetProfessions and GetProfessionInfo then
		local found = {}
		local any = false
		local n = select("#", GetProfessions())
		for i = 1, n do
			local index = select(i, GetProfessions())
			if index then
				local name = GetProfessionInfo(index)
				if name then found[name] = true; any = true end
			end
		end
		if any or not me.professions then me.professions = found end
	elseif not me.professions then
		me.professions = {}
	end

	-- Only snapshot what the database actually cares about; scanning every
	-- faction and currency in the game on every login is wasteful and most are
	-- irrelevant. The DB names 297 rep conditions and 216 currency ones, so
	-- this walks the records rather than the game.
	me.currency = me.currency or {}
	me.achievements = me.achievements or {}
	local wanted = {}
	for _, rec in ipairs(MM.DBList) do
		if rec.conditions then
			for _, cond in ipairs(rec.conditions) do
				if cond.type == "REP" and cond.factionID then wanted[cond.factionID] = true end
				if cond.type == "QUEST" and cond.id then
					me.quests[cond.id] = C_QuestLog.IsQuestFlaggedCompleted(cond.id) or nil
				end
				-- Currency is PER CHARACTER for most of what gates a mount, and
				-- it is the commonest reason one alt is nearly there while the
				-- character reading the list has nothing.
				if cond.type == "CURRENCY" and cond.id and C_CurrencyInfo
					and C_CurrencyInfo.GetCurrencyInfo then
					local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, cond.id)
					if ok and info and info.quantity then
						me.currency[cond.id] = info.quantity
					end
				end
				-- Achievements are usually account-wide, but not always, and
				-- knowing who has one is what makes a recommendation concrete.
				if cond.type == "ACHIEVEMENT" and cond.id and GetAchievementInfo then
					local ok, _, _, _, completed = pcall(GetAchievementInfo, cond.id)
					if ok and completed then me.achievements[cond.id] = true end
				end
			end
		end
	end

	for factionID in pairs(wanted) do
		if C_MajorFactions and C_MajorFactions.GetMajorFactionData then
			local ok, data = pcall(C_MajorFactions.GetMajorFactionData, factionID)
			if ok and data and data.renownLevel then me.renown[factionID] = data.renownLevel end
		end
		if C_Reputation and C_Reputation.GetFactionDataByID then
			local ok, data = pcall(C_Reputation.GetFactionDataByID, factionID)
			if ok and data and data.reaction then
				me.rep[factionID] = { reaction = data.reaction, standing = data.currentStanding }
			end
		end
	end
end

------------------------------------------------------------
-- Scoring a character against a record's requirements
------------------------------------------------------------
-- Partial progress counts proportionally; finishing a requirement is worth a
-- large cliff so "already qualifies" always beats "nearly qualifies".
local COMPLETION_BONUS = 500

local function scoreCondition(snapshot, cond)
	-- Currency is the commonest reason an alt is the right answer: it is held
	-- per character, so the one who has been running that content has it and
	-- the character reading the list has none.
	if cond.type == "CURRENCY" and cond.id and (cond.amount or 0) > 0 then
		local have = (snapshot.currency or {})[cond.id] or 0
		if have >= cond.amount then return COMPLETION_BONUS, have, cond.amount end
		return (have / cond.amount) * 100, have, cond.amount
	end
	if cond.type == "ACHIEVEMENT" and cond.id then
		return (snapshot.achievements or {})[cond.id] and COMPLETION_BONUS or 0
	end
	if cond.type == "PROFESSION" and cond.name then
		local profs = snapshot.professions or {}
		local lines = snapshot.skillLines or {}
		if profs[cond.name] then return COMPLETION_BONUS end
		for _, level in pairs(lines) do
			if level and level > 0 then return COMPLETION_BONUS * 0.5 end
		end
		return 0
	end
	if cond.type == "REP" and cond.factionID then
		local renownTarget = cond.standingName and cond.standingName:match("^Renown (%d+)$")
		if renownTarget then
			local level = snapshot.renown and snapshot.renown[cond.factionID] or 0
			local target = tonumber(renownTarget) or 1
			local score = math.min(level, target) / target * 120
			return level >= target and score + COMPLETION_BONUS or score, level, target
		end
		local data = snapshot.rep and snapshot.rep[cond.factionID]
		local reaction = data and data.reaction or 4
		local target = U.STANDING[cond.standingName] or 8
		local score = math.min(reaction, target) / target * 120
		return reaction >= target and score + COMPLETION_BONUS or score, reaction, target
	end
	if cond.type == "QUEST" and cond.id then
		local done = snapshot.quests and snapshot.quests[cond.id]
		return done and COMPLETION_BONUS or 0
	end
	return 0
end

------------------------------------------------------------
-- The recommendation
------------------------------------------------------------
-- Requirement — We should always recommend the best character to finish/get the mount
-- in the tooltip (rep/faction/materials/currency/etc) maybe even as an explicit
-- recommendation.
--
-- `BestCharacterFor` below answers a narrower question and answers it quietly:
-- it only speaks when an ALT beats you, and only looks at reputation and
-- quests. That is a hint. This is a recommendation, and the difference matters:
--
--   * HARD GATES FIRST. Faction and class are not preferences. An Alliance-only
--     mount cannot be got by any Horde character no matter how much rep they
--     have, and saying "you are the best choice" to someone who can never
--     complete it is worse than saying nothing.
--   * IT ALWAYS ANSWERS. Including "you" -- a collector wants to know they are
--     already on the right character, not to be met with silence and left
--     wondering whether the addon considered it.
--   * IT SAYS WHY. "Ellyria — 1,240/2,000 Timewarped Badge" is actionable.
--     "Best character: Ellyria" is trivia.
--
-- Returns: { key, colored, why, isYou, blocked } or nil when the record has no
-- per-character requirement at all (a world drop is the same for everyone).
local function classToken(rec)
	for _, cond in ipairs(rec.conditions or {}) do
		if cond.type == "CLASS" and cond.class then return cond.class end
	end
	-- Most class gates live in prose rather than a condition block.
	local hay = (rec.notes or "") .. " " .. (rec.source or "")
	local token = hay:match("(%a+) only")
	return token
end

function A.Recommend(rec)
	if not (rec and MM.db and MM.db.alts) then return nil end
	local alts = MM.db.alts
	local myKey = charKey()

	-- Does this record care who does it at all?
	local relevant = false
	for _, cond in ipairs(rec.conditions or {}) do
		if cond.type == "REP" or cond.type == "QUEST" or cond.type == "CURRENCY"
			or cond.type == "ACHIEVEMENT" or cond.type == "PROFESSION" then
			relevant = true
		end
	end
	if MM.Crafting and MM.Crafting.IsCraft(rec) then relevant = true end
	if rec.faction then relevant = true end
	if not relevant then return nil end

	local wantFaction = rec.faction
	local best, bestScore, bestDetail, eligible = nil, -1, nil, 0

	for key, snap in pairs(alts) do
		-- Hard gate: the wrong faction can never finish it.
		local blocked = wantFaction and snap.faction and snap.faction ~= wantFaction
		if not blocked then
			eligible = eligible + 1
			local total, detail = 0, nil
			for _, cond in ipairs(rec.conditions or {}) do
				local score, have, target = scoreCondition(snap, cond)
				total = total + (score or 0)
				if have and target and not detail then
					detail = ("%s/%s %s"):format(U.Comma(have), U.Comma(target),
						cond.name or cond.factionName or "")
				end
			end
			-- A craft belongs to whoever can actually make it.
			if MM.Crafting and MM.Crafting.IsCraft(rec) then
				local profs, lines = snap.professions or {}, snap.skillLines or {}
				if next(lines) or next(profs) then
					total = total + 250
					detail = detail or "has a profession"
				end
			end
			-- Ties go to the character you are on: no reason to log out.
			if key == myKey then total = total + 1 end
			if total > bestScore then
				best, bestScore, bestDetail = key, total, detail
			end
		end
	end

	if not best then
		-- Everyone is the wrong faction. That is the single most useful thing
		-- the tooltip could possibly say about this mount.
		return { blocked = true,
			why = ("No %s character on this account"):format(tostring(wantFaction)) }
	end

	local snap = alts[best]
	local colored = best
	local color = snap and snap.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[snap.class]
	if color and color.colorStr then colored = "|c" .. color.colorStr .. best .. "|r" end
	return {
		key = best, colored = colored, why = bestDetail,
		isYou = (best == myKey), eligible = eligible,
	}
end

-- Returns bestCharKey, bestScore, reason (or nil when it doesn't matter).
function A.BestCharacterFor(rec)
	if not (rec and rec.conditions and MM.db.alts) then return nil end
	local relevant = false
	for _, cond in ipairs(rec.conditions) do
		if (cond.type == "REP" and cond.factionID) or (cond.type == "QUEST" and cond.id) then
			relevant = true
		end
	end
	if not relevant then return nil end

	local bestKey, bestScore, bestDetail = nil, -1, nil
	for key, snapshot in pairs(MM.db.alts) do
		local total, detail = 0, nil
		for _, cond in ipairs(rec.conditions) do
			local score, have, target = scoreCondition(snapshot, cond)
			total = total + score
			if have and target and not detail then
				detail = ("%s %s/%s"):format(cond.factionName or "rep",
					tostring(have), tostring(target))
			end
		end
		if total > bestScore then bestKey, bestScore, bestDetail = key, total, detail end
	end

	if not bestKey or bestKey == charKey() then return nil end
	local snapshot = MM.db.alts[bestKey]
	local colored = bestKey
	local color = snapshot.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[snapshot.class]
	if color and color.colorStr then colored = "|c" .. color.colorStr .. bestKey .. "|r" end
	return bestKey, bestScore, ("%s is furthest along%s"):format(colored,
		bestDetail and (" (" .. bestDetail .. ")") or "")
end

------------------------------------------------------------
-- Wiring
------------------------------------------------------------
MM:On("MM_LOGIN", function()
	C_Timer.After(15, A.Snapshot)
end)
MM:RegisterGameEvent("PLAYER_LOGOUT", function() pcall(A.Snapshot) end)
MM:RegisterGameEvent("MAJOR_FACTION_RENOWN_LEVEL_CHANGED", function()
	C_Timer.After(2, A.Snapshot)
end)

------------------------------------------------------------
-- Who in the warband can actually DO this
------------------------------------------------------------
-- BestCharacterFor answers "who is furthest along", which is the right question
-- while nobody qualifies and the wrong one once somebody does. A goal you have
-- already earned the standing for on an alt is not blocked: it is a character
-- switch away, and a switch costs about a minute.
--
-- That distinction is the whole of it. The ranking treated "this character
-- cannot do it" as "nobody can", so a mount sitting behind exalted reputation
-- an alt already has ranked below things needing weeks of work.
--
-- Returns: key, isCurrentCharacter, needsCurrencyTransfer, reason
function A.WhoMeets(rec)
	if not (rec and rec.conditions and #rec.conditions > 0 and MM.db.alts) then
		return nil
	end
	local me = charKey()

	-- A currency the warband shares still has to be ON the character spending
	-- it -- the vendor checks the character's own balance, not the account's.
	-- So "an alt has the badges" is a real answer AND a real extra step.
	local function meets(snapshot)
		local transfer = false
		for _, cond in ipairs(rec.conditions) do
			local score = scoreCondition(snapshot, cond)
			if (score or 0) < COMPLETION_BONUS then return false end
			if cond.type == "CURRENCY" and cond.id and snapshot ~= MM.db.alts[me] then
				transfer = true
			end
		end
		return true, transfer
	end

	local mine = MM.db.alts[me]
	if mine then
		local ok = meets(mine)
		if ok then return me, true, false, "you can do this on this character" end
	end

	for key, snapshot in pairs(MM.db.alts) do
		if key ~= me then
			local ok, transfer = meets(snapshot)
			if ok then
				local colored = key
				local color = snapshot.class and RAID_CLASS_COLORS
					and RAID_CLASS_COLORS[snapshot.class]
				if color and color.colorStr then
					colored = "|c" .. color.colorStr .. key .. "|r"
				end
				return key, false, transfer, transfer
					and ("%s already qualifies — move the currency to them first")
						:format(colored)
					or ("%s already qualifies"):format(colored)
			end
		end
	end
	return nil
end
