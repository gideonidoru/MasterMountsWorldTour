-- Master Mounts: crafted mounts, their materials, and who should make them.
--
-- Requirement — Materials always need to be considered in all crafted mounts
-- (profession, protoform synthesis, etc, check across the warband for the best
-- character to complete them [always should be a norm, mouse over should always
-- recommend the best character to complete based on completion] then consider
-- the missing materials and their farm time/chance/lockouts to complete the
-- craft).
--
-- Three problems, and only two of them are logic.
--
-- 1. WHAT DOES IT COST. A craft needs reagents. Addendum 115 charged every
--    unmodelled craft a flat four hours, which stopped them winning the list
--    but is not an answer -- it is the same number for a mount needing three
--    common herbs and one needing forty rare drops.
--
-- 2. WHO SHOULD MAKE IT. A craft is not a property of the character reading the
--    list. It belongs to whoever has the profession, and the reagents may be
--    sitting in the warband bank where everyone can reach them.
--
-- 3. WHERE DO THE REAGENT LISTS COME FROM. Not invented. there is no verified
--    reagent lists for twenty-four Protoform schematics, and inventing them
--    would be exactly the mistake Addendum 111 records -- two of fifteen secret
--    chains written from recollection turned out to be wrong.
--
-- So they are HARVESTED. `C_TradeSkillUI` knows the real reagents for every
-- recipe the player has, and reports them exactly. Open a profession window
-- once and the truth is recorded, account-wide, for every mount that profession
-- can make. Until then the record is honestly marked as unpriced rather than
-- given an invented number.
local _, MM = ...

MM.Crafting = {}
local CR = MM.Crafting
local U = MM.Util

------------------------------------------------------------
-- Counting what you have
------------------------------------------------------------
-- Bags, bank, reagent bank AND the warband bank.
--
-- The warband bank is the whole reason "which character" is answerable: a stack
-- of Genesis Motes in there is available to every character on the account, so
-- a craft can be finished by whoever has the profession rather than by whoever
-- happens to be holding the materials.
function CR.Have(itemID)
	if not itemID then return 0 end
	local get = C_Item and C_Item.GetItemCount
	if not get then return 0 end
	-- (itemID, includeBank, includeUses, includeReagentBank, includeAccountBank)
	local ok, n = pcall(get, itemID, true, false, true, true)
	if ok and type(n) == "number" then return n end
	-- Older signatures take fewer arguments; never report "you have none"
	-- because a trailing parameter was rejected.
	local ok2, n2 = pcall(get, itemID, true)
	return (ok2 and type(n2) == "number") and n2 or 0
end

------------------------------------------------------------
-- Harvesting real recipes
------------------------------------------------------------
-- MM.db.recipes[outputItemID] = {
--     name, recipeID, skillLine, learnedBy = charKey,
--     reagents = { { itemID, count, name }, ... }, harvested = timestamp }
local function store()
	MM.db.recipes = MM.db.recipes or {}
	return MM.db.recipes
end

CR.lastHarvest = nil

-- Reads every recipe the open profession window exposes and records the ones
-- whose output is an item. Cheap, and only ever runs when the player has
-- deliberately opened a trade skill.
function CR.Harvest()
	local API = C_TradeSkillUI
	if not (API and API.GetAllRecipeIDs and API.GetRecipeSchematic) then return 0, 0 end

	local okIDs, ids = pcall(API.GetAllRecipeIDs)
	if not (okIDs and type(ids) == "table") then return 0, 0 end

	local db = store()
	local charKey = ("%s-%s"):format(UnitName("player") or "?", GetRealmName() or "?")
	local seen, learned = 0, 0

	for _, recipeID in ipairs(ids) do
		local okS, schematic = pcall(API.GetRecipeSchematic, recipeID, false)
		if okS and schematic and schematic.outputItemID then
			seen = seen + 1
			local reagents = {}
			for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
				-- Optional slots (quality mats, finishing reagents) are not
				-- required to make the thing, so they are not part of its cost.
				local required = slot.required
				if required == nil then required = true end
				local first = slot.reagents and slot.reagents[1]
				if required and first and first.itemID then
					reagents[#reagents + 1] = {
						itemID = first.itemID,
						count = slot.quantityRequired or 1,
					}
				end
			end
			if #reagents > 0 then
				db[schematic.outputItemID] = {
					name = schematic.name,
					recipeID = recipeID,
					skillLine = schematic.skillLineAbility,
					learnedBy = charKey,
					reagents = reagents,
					harvested = GetServerTime and GetServerTime() or 0,
				}
				learned = learned + 1
			end
		end
	end

	CR.lastHarvest = { seen = seen, learned = learned, by = charKey }
	if learned > 0 then
		MM.Planner.InvalidateRanks()
		MM:Fire("MM_CRAFTING")
	end
	return seen, learned
end

MM:RegisterGameEvent("TRADE_SKILL_SHOW", function()
	-- The list is not populated on the very first frame.
	C_Timer.After(0.5, function() pcall(CR.Harvest) end)
end)

------------------------------------------------------------
-- What a record needs
------------------------------------------------------------
-- Returns a list of { itemID, count, have, short } and whether it is known at
-- all. `known == false` means nobody has opened the profession that makes it,
-- so the cost is still a guess and must be reported as such.
function CR.MaterialsFor(rec)
	if not rec then return nil, false end

	-- Explicit data in the record always wins over anything harvested.
	local list, known = {}, false
	for _, cond in ipairs(rec.conditions or {}) do
		if cond.type == "MATERIAL" and cond.itemID then
			known = true
			local have = CR.Have(cond.itemID)
			list[#list + 1] = {
				itemID = cond.itemID, name = cond.name,
				count = cond.count or 1, have = have,
				short = math.max(0, (cond.count or 1) - have),
			}
		end
	end
	if known then return list, true end

	local entry = rec.itemID and store()[rec.itemID]
	if not entry then return nil, false end
	for _, r in ipairs(entry.reagents or {}) do
		local have = CR.Have(r.itemID)
		list[#list + 1] = {
			itemID = r.itemID, name = r.name,
			count = r.count, have = have,
			short = math.max(0, r.count - have),
		}
	end
	return list, #list > 0
end

-- How complete a craft is, 0..1, counting each reagent by how much is held.
function CR.Progress(rec)
	local mats, known = CR.MaterialsFor(rec)
	if not (known and mats and #mats > 0) then return nil end
	local need, got = 0, 0
	for _, m in ipairs(mats) do
		need = need + m.count
		got = got + math.min(m.have, m.count)
	end
	if need <= 0 then return nil end
	return got / need, mats
end

-- Is this a craft at all? Category is the reliable signal; the Protoform
-- schematics are all PROFESSION and so is everything else that needs reagents.
function CR.IsCraft(rec)
	return rec and rec.category == "PROFESSION"
end

-- Do we KNOW this craft's reagents? A cheap table lookup.
--
-- `CR.Progress` was being used to answer this, over the whole database, twice
-- per diagnostic report -- and it calls `C_Item.GetItemCount` for every reagent
-- of every craft. Counting how many crafts are priced does not need to know how
-- many of each reagent you are carrying.
--
-- That was a large part of what froze the client on /mm diag. Asking a cheap
-- question expensively is the oldest performance bug there is.
function CR.IsPriced(rec)
	if not rec then return false end
	for _, cond in ipairs(rec.conditions or {}) do
		if cond.type == "MATERIAL" and cond.itemID then return true end
	end
	return rec.itemID ~= nil and store()[rec.itemID] ~= nil
end

------------------------------------------------------------
-- What a reagent costs to get
------------------------------------------------------------
-- Requirement — then consider the missing materials and their farm time/chance/
-- lockouts to complete the craft.
--
-- A flat two minutes an item scaled with HOW MUCH was missing but not with how
-- hard each item is, which makes a stack of common herbs look like a stack of
-- raid drops. The schematic does not say where a reagent comes from.
--
-- But the ITEM does. `C_Item.GetItemInfo` reports its class, subclass and
-- binding, and those three answer the question well enough to be useful:
--
--   BoE + a gathering class  -> the auction house. Minutes, not hours.
--   BoP                      -> nobody can sell it to you. You farm it.
--   Quest / "Reagent" class  -> usually a token from gated content
--
-- This is derived from live item data rather than invented per reagent, which
-- is the same discipline the recipe harvest follows: read what the client
-- knows, never write down what seems familiar.
local LE_ITEM_CLASS_TRADEGOODS = 7
local LE_ITEM_CLASS_QUEST = 12
local LE_ITEM_CLASS_REAGENT = 5

-- Minutes per unit, by how the item is actually obtained.
local BUYABLE_MINUTES = 0.5      -- one auction house trip covers a whole stack
local GATHER_MINUTES = 3         -- herbs, ore, cloth: farmable at a steady rate
local FARM_MINUTES = 12          -- soulbound drops: killing things until it drops
local GATED_MINUTES = 45         -- quest items and tokens: usually lockout-bound
local UNKNOWN_MINUTES = 6        -- item not cached yet; between the two

-- Returns minutes per unit and a short human reason.
function CR.ReagentCost(itemID)
	if not (itemID and C_Item and C_Item.GetItemInfo) then
		return UNKNOWN_MINUTES, "source unknown"
	end
	local ok, _, _, _, _, _, _, _, _, _, _, _, classID, subClassID, bindType =
		pcall(GetItemInfo, itemID)
	if not ok or not classID then
		-- Not in the client's cache yet. Asking for it warms the cache so the
		-- next call is real; charging the middle estimate meanwhile is honest.
		if C_Item.RequestLoadItemDataByID then
			pcall(C_Item.RequestLoadItemDataByID, itemID)
		end
		return UNKNOWN_MINUTES, "not cached yet"
	end

	-- Bind-on-pickup means no auction house, whatever it is.
	local soulbound = (bindType == 1)

	if classID == LE_ITEM_CLASS_QUEST then
		return GATED_MINUTES, "quest item — usually lockout-gated"
	end
	if classID == LE_ITEM_CLASS_REAGENT then
		return soulbound and FARM_MINUTES or BUYABLE_MINUTES,
			soulbound and "soulbound reagent" or "buyable reagent"
	end
	if classID == LE_ITEM_CLASS_TRADEGOODS then
		if soulbound then return FARM_MINUTES, "soulbound trade good" end
		return GATHER_MINUTES, "gatherable or buyable"
	end
	return soulbound and FARM_MINUTES or BUYABLE_MINUTES,
		soulbound and "soulbound" or "tradeable"
end

-- Total minutes to close the gap on a craft, itemised.
-- Returns minutes, parts[] -- or nil when the reagents are not known at all.
function CR.ShortfallMinutes(rec)
	local mats, known = CR.MaterialsFor(rec)
	if not (known and mats) then return nil end
	local total, parts = 0, {}
	for _, m in ipairs(mats) do
		if m.short > 0 then
			local per, why = CR.ReagentCost(m.itemID)
			local minutes = m.short * per
			total = total + minutes
			parts[#parts + 1] = {
				itemID = m.itemID, short = m.short,
				minutes = minutes, why = why,
			}
		end
	end
	return total, parts
end

------------------------------------------------------------
-- Who should make it
------------------------------------------------------------
-- Warband-wide. Returns charKey, detail -- or nil when we genuinely cannot say,
-- which is not the same as "you".
--
-- Reagents in the warband bank belong to everyone, so the answer is almost
-- always "whoever has the profession", and that is a fact about the account
-- rather than about the character reading the tooltip.
function CR.BestCharacterFor(rec)
	if not CR.IsCraft(rec) then return nil end
	local alts = MM.db and MM.db.alts
	if not alts then return nil end

	local entry = rec.itemID and store()[rec.itemID]
	local wantLine = entry and entry.skillLine

	local bestKey, bestScore, bestWhy
	for key, snap in pairs(alts) do
		local score, why = 0, nil
		-- Whoever the recipe was harvested from demonstrably knows it.
		if entry and entry.learnedBy == key then
			score = score + 100
			why = "knows the recipe"
		end
		-- Otherwise, anyone with the profession at all is a candidate.
		local lines = snap.skillLines
		if lines and wantLine and lines[wantLine] then
			score = score + 50
			why = why or "has the profession"
		end
		if score > (bestScore or 0) then bestKey, bestScore, bestWhy = key, score, why end
	end

	if not bestKey then return nil end
	local snap = alts[bestKey]
	local colored = bestKey
	local color = snap and snap.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[snap.class]
	if color and color.colorStr then colored = "|c" .. color.colorStr .. bestKey .. "|r" end
	return bestKey, colored, bestWhy
end

------------------------------------------------------------
-- /mm crafting
------------------------------------------------------------
MM:On("MM_CRAFTING_DEBUG", function()
	local db = store()
	local n = 0
	for _ in pairs(db) do n = n + 1 end
	MM:Print("Recipes harvested: %d (open a profession window to record more)", n)
	if CR.lastHarvest then
		MM:Print("   last scan: %d recipes seen, %d with reagents, on %s",
			CR.lastHarvest.seen, CR.lastHarvest.learned, CR.lastHarvest.by)
	end

	-- Crafted mounts, and whether their cost is real or still a guess.
	local priced, guessed = {}, {}
	for _, rec in pairs(MM.DBByName) do
		-- GATHERED IS NOT UNPRICED. Four of these are fished up and three are
		-- archaeology solves; none has a reagent list anywhere, so they sat in
		-- a list headed "open a profession window" that could never shorten by
		-- doing so. They carry a reason now and this reads it.
		if CR.IsCraft(rec) and rec.obtainable and not rec.unpriced then
			local frac, mats = CR.Progress(rec)
			if frac then
				local short = 0
				for _, m in ipairs(mats) do short = short + m.short end
				priced[#priced + 1] = ("%s — %d%% of reagents, %d still needed")
					:format(rec.name, math.floor(frac * 100), short)
			else
				guessed[#guessed + 1] = rec.name
			end
		end
	end
	table.sort(priced); table.sort(guessed)

	MM:Print("|cff40d860Crafts with real reagent data: %d|r", #priced)
	for i = 1, math.min(#priced, 10) do MM:Print("   %s", priced[i]) end
	if #priced > 10 then MM:Print("   ...and %d more", #priced - 10) end

	MM:Print("|cffff9a3cCrafts still costed on a guess: %d|r", #guessed)
	for i = 1, math.min(#guessed, 10) do MM:Print("   %s", guessed[i]) end
	if #guessed > 10 then MM:Print("   ...and %d more", #guessed - 10) end
	if #guessed > 0 then
		MM:Print("   These need the profession window opened once on a character")
		MM:Print("   who knows the recipe. No API can request it otherwise, and")
		MM:Print("   inventing reagent lists is how the secret chains went wrong.")
	end

	-- The raw API surface, so a wrong reader can be corrected rather than guessed at.
	local API = C_TradeSkillUI
	if API then
		local names = {}
		for k, v in pairs(API) do if type(v) == "function" then names[#names + 1] = k end end
		table.sort(names)
		MM:Print("   C_TradeSkillUI (%d): %s", #names,
			table.concat(names, ", ", 1, math.min(#names, 14)))
	end
end)
