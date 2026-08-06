-- Master Mounts data schema: registry the per-expansion files feed into.
local _, MM = ...

MM.DBList = {}    -- every record, in load order
MM.DBBySpell = {} -- [spellID] = record
MM.DBByName = {}  -- [lowercased mount name] = record
-- [itemID] = record. Every external source keys on item rather than spell, so
-- this is what lets a vendor's open stock, a loot table or a tooltip be matched
-- back to a mount. Built here because it must cover overrides too -- most of
-- our itemIDs arrive from a late override file, not the base records.
MM.ItemToMount = {}

function MM.AddMounts(list)
	for _, rec in ipairs(list) do
		tinsert(MM.DBList, rec)
		-- First record for a mount is canonical; later duplicates (e.g. the
		-- Timewalking-cache route for a raid drop) become alternate sources.
		local existing = (rec.spellID and MM.DBBySpell[rec.spellID])
			or (rec.name and MM.DBByName[rec.name:lower()])
		if existing then
			existing.altSources = existing.altSources or {}
			tinsert(existing.altSources, rec)
		else
			if rec.spellID then MM.DBBySpell[rec.spellID] = rec end
			-- Some mounts occupy SEVERAL journal rows under one name: Magic
			-- Rooster has four (65917 plus three race-variant summons). Without
			-- this the extra rows match nothing and are reported as
			-- uncatalogued mounts forever, while the record looks id-less.
			for _, alt in ipairs(rec.altSpellIDs or {}) do
				MM.DBBySpell[alt] = rec
			end
			if rec.name then MM.DBByName[rec.name:lower()] = rec end
			if rec.itemID then MM.ItemToMount[rec.itemID] = rec end
		end
	end
end

-- Client-resolved IDs (maps, npcs, vendors), committed from /mm export.
--
-- Defined here rather than in IDResolver.lua because Data_87_ResolvedIDs.lua
-- calls AddResolvedIDs at FILE SCOPE, and the data files all load before any
-- module does. Anything the data layer calls at load time must be defined in
-- this file.
MM.ResolvedIDs = { maps = {}, npcs = {}, vendors = {} }

function MM.AddResolvedIDs(tbl)
	for kind, set in pairs(tbl) do
		MM.ResolvedIDs[kind] = MM.ResolvedIDs[kind] or {}
		for k, v in pairs(set) do MM.ResolvedIDs[kind][k] = v end
	end
end

-- Vendor-keyed locations. Many mounts share one quartermaster, so storing the
-- coordinates once per NPC and letting records inherit them by `vendor` name
-- avoids duplicating the same point across a dozen records (and means fixing
-- a vendor's coords fixes every mount they sell).
MM.VendorLocations = {}

function MM.AddVendorLocations(list)
	for name, loc in pairs(list) do
		MM.VendorLocations[name:lower()] = loc
	end
end

-- Location for a record, preferring its own zone block, then its vendor's.
--
-- A zone only wins if its name actually resolves to a map. Several records
-- ship compound names like "Ashran (Warspear / Stormshield)" or
-- "Boralus / Dazar'alor" that are not real maps and resolve to nil; without
-- this check those silently beat a perfectly good vendor location. Note that
-- `zone = nil` in an override is a no-op (Lua drops nil keys), so unusable
-- zones have to be detected rather than cleared.
function MM.GetRecordLocation(rec)
	if not rec then return nil end

	local zone = rec.zone
	local zoneUsable = zone and zone.x and zone.y and zone.name
		and MM.Util and MM.Util.ResolveMapByName
		and MM.Util.ResolveMapByName(zone.name) ~= nil

	if zoneUsable then return zone end

	if rec.vendor then
		local loc = MM.VendorLocations[rec.vendor:lower()]
		if loc then return loc end
	end
	return zone
end

-- Identity of a requirement, so two override files describing the SAME
-- requirement update each other instead of stacking duplicates.
local function conditionKey(cond)
	if type(cond) ~= "table" then return tostring(cond) end
	local kind = cond.type or "?"
	-- an id is authoritative; otherwise the name distinguishes (a mount can
	-- legitimately need two different currencies, or rep with two factions)
	local ident = cond.id or cond.factionID
		or (cond.factionName and cond.factionName:lower())
		or (cond.name and cond.name:lower())
		or ""
	return kind .. "\0" .. tostring(ident)
end

-- Merge a replacement condition list into an existing one: same-identity
-- requirements are updated field-by-field (so a costs file can add `amount`
-- without discarding an access file's `how`/unlock quest), genuinely new
-- requirements are appended, and nothing already known is silently dropped.
local function mergeConditions(existing, incoming)
	if type(existing) ~= "table" or #existing == 0 then return incoming end
	if type(incoming) ~= "table" then return existing end

	-- AN ID AND A NAME FOR ONE REQUIREMENT ARE ONE REQUIREMENT.
	--
	-- conditionKey prefers the id, so { type = "ACHIEVEMENT", name = "Mount
	-- Parade" } and { type = "ACHIEVEMENT", id = 8302, name = "Mount Parade" }
	-- keyed differently and BOTH survived -- 25 records ended up requiring the
	-- same thing twice, once with readable progress and once without, and the
	-- planner charged both. A second index on type+name collapses them.
	--
	-- Two conditions of one type with DIFFERENT names stay separate, which is
	-- the case the id-first key was protecting: a mount really can need two
	-- currencies.
	local byKey, byName, order = {}, {}, {}
	local function nameKey(cond)
		if not cond.name then return nil end
		return (cond.type or "?") .. "\0" .. cond.name:lower()
	end
	local function absorb(cond)
		local nk = nameKey(cond)
		local prev = byKey[conditionKey(cond)] or (nk and byName[nk])
		if prev then
			for k, v in pairs(cond) do prev[k] = v end -- later file wins per-field
			-- It may only NOW have an id, so re-index under both identities.
			byKey[conditionKey(prev)] = prev
			if nk then byName[nk] = prev end
		else
			local copy = {}
			for k, v in pairs(cond) do copy[k] = v end
			byKey[conditionKey(copy)] = copy
			if nk then byName[nk] = copy end
			-- Store the TABLE, not its key: absorbing an id changes the key,
			-- and a list of stale keys would rebuild the wrong conditions.
			tinsert(order, copy)
		end
	end
	for _, cond in ipairs(existing) do absorb(cond) end
	for _, cond in ipairs(incoming) do absorb(cond) end

	return order
end

-- Later files (overrides) may correct earlier records by name. Most fields
-- are replaced outright; `conditions` MERGES, because separate override files
-- each know a different part of the same requirement (costs vs access vs rep)
-- and wholesale replacement made whichever loaded last silently win.
function MM.OverrideMount(name, fields)
	local rec = MM.DBByName[name:lower()]
	if not rec then return end
	for k, v in pairs(fields) do
		if k == "conditions" then
			rec.conditions = mergeConditions(rec.conditions, v)
		else
			rec[k] = v
		end
	end
	-- Most itemIDs arrive here rather than in the base records -- 911 of the 957
	-- came from a late override file -- so the index has to be maintained on
	-- override too, or it would hold the 43 we started with.
	if rec.itemID then MM.ItemToMount[rec.itemID] = rec end
end

-- Put an id on a condition that already exists, found by type and NAME.
--
-- OverrideMount cannot do this. conditionKey treats an id as authoritative, so
-- passing { type = "QUEST", name = "...", id = 11012 } keys as QUEST\011012
-- while the record's own condition keys as QUEST\0<name> -- the merge sees two
-- different conditions and the record ends up requiring the same quest twice.
--
-- Returns true only when a condition was actually found and changed, so a
-- generated file cannot quietly annotate nothing after a record is renamed.
--
-- `properName` is optional and corrects the wording at the same time. Some
-- conditions were written the way a person says the requirement rather than
-- the way the game titles it -- "Keystone Myth" for "Midnight Keystone Myth:
-- Season 1". The id is what makes the requirement checkable; the title is what
-- the player reads in the tooltip, and the two should agree.
function MM.SetConditionID(mountName, kind, condName, id, properName)
	local rec = MM.DBByName[mountName:lower()]
	if not (rec and rec.conditions and id) then return false end
	local want = condName and condName:lower()
	for _, cond in ipairs(rec.conditions) do
		if cond.type == kind and not cond.id
			and cond.name and cond.name:lower() == want then
			cond.id = id
			if properName then cond.name = properName end
			return true
		end
	end
	return false
end

-- The same requirement under two ids, one per side.
--
-- Some things exist twice: the collection achievements, the Argent Tournament
-- and Outland quartermaster mounts, anything a faction sells through its own
-- vendor. Both copies carry the same name, so "the name is not unique" is the
-- wrong conclusion -- there are two answers and which one applies depends on
-- who is asking.
--
-- Recorded rather than resolved here because the data layer runs before the
-- player's faction is known. ResolveFactionVariants picks one at login, which
-- is the same moment it promotes faction-specific sources.
function MM.SetConditionIDByFaction(mountName, kind, condName, allianceID, hordeID)
	local rec = MM.DBByName[mountName:lower()]
	if not (rec and rec.conditions and allianceID and hordeID) then return false end
	local want = condName and condName:lower()
	for _, cond in ipairs(rec.conditions) do
		if cond.type == kind and not cond.id
			and cond.name and cond.name:lower() == want then
			cond.idAlliance, cond.idHorde = allianceID, hordeID
			return true
		end
	end
	return false
end

-- Put an AMOUNT on a condition that already names what it costs.
--
-- Same reasoning as SetConditionID, and the same reason OverrideMount cannot do
-- it: a record carrying { type = "CURRENCY", name = "Timewarped Badge" } with no
-- amount keys as CURRENCY\0<name>, so merging in an id-bearing copy produces a
-- SECOND condition and the mount reads as costing both. Matching on the name and
-- filling the amount in place is the only way to price these without duplicating.
--
-- Sets the id too when one is supplied and the condition lacks it, since a
-- condition matched by name can safely gain the id it was missing.
--
-- Returns true only when a condition was actually found and changed, so a
-- generated file cannot quietly price nothing after a record is renamed.
function MM.SetConditionAmount(mountName, kind, condName, amount, id)
	local rec = MM.DBByName[mountName:lower()]
	if not (rec and rec.conditions and amount) then return false end
	local want = condName and condName:lower()
	for _, cond in ipairs(rec.conditions) do
		if cond.type == kind and cond.name and cond.name:lower() == want then
			if cond.amount then return false end   -- never overwrite a real price
			cond.amount = amount
			if id and not cond.id then cond.id = id end
			return true
		end
	end
	return false
end

-- Put an id on every record whose npc is named but unidentified.
--
-- Keyed by the NPC rather than the mount: one drop source usually feeds
-- several mounts, and a per-mount override would replace the whole npc table
-- and lose whatever else it held. Returns how many records were changed, so a
-- generated file cannot silently annotate nothing.
function MM.SetNpcID(npcName, id)
	if not (npcName and id) then return 0 end
	local want, n = npcName:lower(), 0
	for _, rec in ipairs(MM.DBList or {}) do
		local npc = rec.npc
		if type(npc) == "table" and not npc.id
			and npc.name and npc.name:lower() == want then
			npc.id = id
			n = n + 1
		end
	end
	return n
end

-- Remove one requirement by type and NAME.
--
-- For the case where a record carries the SAME cost twice under two spellings
-- -- an ITEM condition naming the token and a CURRENCY condition naming its
-- plural. Both charge, so the mount reads as costing double, and neither
-- OverrideMount nor SetConditionID can help: merging keys them apart, and
-- filling in the second one's id only makes the duplicate look deliberate.
--
-- Returns true only when something was actually removed, so a generated file
-- cannot quietly drop nothing after a record is renamed.
function MM.DropCondition(mountName, kind, condName)
	local rec = MM.DBByName[mountName:lower()]
	if not (rec and rec.conditions) then return false end
	local want = condName and condName:lower()
	for i, cond in ipairs(rec.conditions) do
		if cond.type == kind and cond.name and cond.name:lower() == want then
			tremove(rec.conditions, i)
			return true
		end
	end
	return false
end

-- Correct a requirement filed under the wrong kind, in place.
--
-- Written for costs recorded as CURRENCY that are really items. The client
-- resolves a nameless currency against the player's own currency list, so a
-- CURRENCY condition naming something that is not a currency can never resolve
-- -- it reads as "you have none" forever, whatever is in the bags. Retyped to
-- ITEM with its item id, the same requirement becomes answerable.
--
-- Amount and how-text are left alone: only the kind was wrong.
function MM.RetypeCondition(mountName, fromKind, condName, toKind, id)
	local rec = MM.DBByName[mountName:lower()]
	if not (rec and rec.conditions) then return false end
	local want = condName and condName:lower()
	for _, cond in ipairs(rec.conditions) do
		if cond.type == fromKind and cond.name and cond.name:lower() == want then
			cond.type = toKind
			if id then cond.id = id end
			return true
		end
	end
	return false
end

-- Escape hatch for a record whose old requirements are genuinely wrong
-- (e.g. it was never a vendor mount at all) rather than merely incomplete.
function MM.ReplaceConditions(name, conditions)
	local rec = MM.DBByName[name:lower()]
	if rec then rec.conditions = conditions end
end

------------------------------------------------------------
-- Faction-split records
--
-- Alliance and Horde versions of a mount often share one NAME (Vicious War
-- Basilisk, the Battle of Dazar'alor drops, Island Expedition loot). Because
-- AddMounts is first-wins, the second faction's record ends up in altSources
-- and nothing could ever address it — so per-faction coordinates were
-- impossible to write. These two functions fix that.
------------------------------------------------------------

-- Target a specific faction's variant explicitly.
function MM.OverrideMountFaction(name, faction, fields)
	local rec = MM.DBByName[name:lower()]
	if not rec then return end

	local target
	if rec.faction == faction then
		target = rec
	elseif rec.altSources then
		for _, alt in ipairs(rec.altSources) do
			if alt.faction == faction then target = alt break end
		end
	end
	-- no variant carries this faction yet: store it as a faction-specific
	-- overlay on the canonical record so ResolveFactionVariants can apply it
	if not target then
		rec.factionOverlay = rec.factionOverlay or {}
		rec.factionOverlay[faction] = rec.factionOverlay[faction] or {}
		for k, v in pairs(fields) do rec.factionOverlay[faction][k] = v end
		return
	end

	for k, v in pairs(fields) do
		if k == "conditions" then
			target.conditions = mergeConditions(target.conditions, v)
		else
			target[k] = v
		end
	end
end

-- Once we know the player's faction, make THEIR variant the canonical record
-- so every lookup, route and pin uses the right vendor and coordinates.
-- Called after login; safe to call more than once.
function MM.ResolveFactionVariants(playerFaction)
	if not playerFaction then return end
	for _, rec in ipairs(MM.DBList) do
		-- promote a matching alternate over a mismatched canonical
		if rec.altSources and rec.faction and rec.faction ~= playerFaction then
			for i, alt in ipairs(rec.altSources) do
				if alt.faction == playerFaction then
					for k, v in pairs(alt) do
						if k ~= "altSources" then rec[k] = v end
					end
					tremove(rec.altSources, i)
					break
				end
			end
		end
		-- apply any faction-specific overlay written before we knew the faction
		local overlay = rec.factionOverlay and rec.factionOverlay[playerFaction]
		if overlay then
			for k, v in pairs(overlay) do
				if k == "conditions" then
					rec.conditions = mergeConditions(rec.conditions, v)
				else
					rec[k] = v
				end
			end
		end
		-- Requirements that exist twice, once per side. Only one of the pair
		-- belongs to this player, and until it is chosen the condition carries
		-- no id at all -- which is the state where the client cannot be asked
		-- whether the requirement has been met.
		for _, cond in ipairs(rec.conditions or {}) do
			if not cond.id then
				local pick = (playerFaction == "Alliance") and cond.idAlliance
					or (playerFaction == "Horde") and cond.idHorde
				if pick then cond.id = pick end
			end
		end
	end
end

MM.CATEGORIES = {
	{ key = "DROP",        label = "Boss Drop" },
	{ key = "RARE",        label = "Rare Kill" },
	{ key = "ZONEDROP",    label = "Zone Drop" },
	{ key = "REP",         label = "Reputation" },
	{ key = "VENDOR",      label = "Vendor" },
	{ key = "QUEST",       label = "Quest" },
	{ key = "ACHIEVEMENT", label = "Achievement" },
	{ key = "PROFESSION",  label = "Profession" },
	{ key = "PUZZLE",      label = "Secret / Puzzle" },
	{ key = "TREASURE",    label = "Treasure" },
	{ key = "CURRENCY",    label = "Currency" },
	{ key = "PVP",         label = "PvP" },
	{ key = "HOLIDAY",     label = "Holiday" },
	{ key = "TIMEWALKING", label = "Timewalking" },
	{ key = "GARRISON",    label = "Garrison" },
	{ key = "CLASS",       label = "Class" },
	{ key = "PROMOTION",   label = "Promotion" },
	{ key = "STORE",       label = "Store" },
	{ key = "TCG",         label = "TCG" },
	{ key = "TRADINGPOST", label = "Trading Post" },
	{ key = "REMOVED",     label = "Removed" },
	{ key = "UNKNOWN",     label = "Uncatalogued" },
}

MM.CATEGORY_LABEL = {}
for _, c in ipairs(MM.CATEGORIES) do MM.CATEGORY_LABEL[c.key] = c.label end

-- Categories that represent something you can actively farm/work toward.
MM.PLANNABLE = {
	DROP = true, RARE = true, ZONEDROP = true, REP = true, VENDOR = true,
	QUEST = true, ACHIEVEMENT = true, PROFESSION = true, PUZZLE = true,
	TREASURE = true, CURRENCY = true, PVP = true, HOLIDAY = true,
	TIMEWALKING = true, GARRISON = true, CLASS = true,
}

-- Categories where attempts are kill-based (used for attempt counting).
MM.KILL_BASED = { DROP = true, RARE = true, ZONEDROP = true, HOLIDAY = true, TIMEWALKING = true }

-- Facet groups usable anywhere a category filter is accepted.
local CATEGORY_GROUPS = {
	GROUP_DROPS = { DROP = true, RARE = true, ZONEDROP = true },
	GROUP_BUY = { VENDOR = true, REP = true, CURRENCY = true, TRADINGPOST = true, TIMEWALKING = true },
	GROUP_ACH = { ACHIEVEMENT = true },
}
MM.CATEGORY_GROUP_LABEL = {
	GROUP_DROPS = "Any Drop", GROUP_BUY = "Purchasable", GROUP_ACH = "Achievement / Meta",
}

function MM.CategoryMatch(filterKey, category)
	if not filterKey then return true end
	local group = CATEGORY_GROUPS[filterKey]
	if group then return group[category] or false end
	return filterKey == category
end

MM.EXPANSIONS = {
	[0] = "Classic",
	[1] = "The Burning Crusade",
	[2] = "Wrath of the Lich King",
	[3] = "Cataclysm",
	[4] = "Mists of Pandaria",
	[5] = "Warlords of Draenor",
	[6] = "Legion",
	[7] = "Battle for Azeroth",
	[8] = "Shadowlands",
	[9] = "Dragonflight",
	[10] = "The War Within",
	[11] = "Midnight",
}
MM.MAX_EXPANSION = 11
