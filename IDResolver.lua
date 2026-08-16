-- Master Mounts ID resolver.
--
-- The database is authored with NAMES because names are what a human can
-- write correctly without a game client, and a wrong name fails visibly
-- while a wrong ID silently points at the wrong mount. But names are
-- ambiguous ("Dalaran" is two maps), locale-bound, and slow to match.
--
-- This module closes that gap using the ONLY trustworthy source of IDs: the
-- running client. It resolves names to IDs from Blizzard's own APIs, caches
-- them, and can export them as a Lua file to commit back into the data — so
-- the database becomes ID-indexed at rest without anyone ever guessing a
-- number.
--
--   /mm ids      show resolution coverage
--   /mm resolve  force a full re-resolve
--   /mm export   write the resolved IDs to SavedVariables for committing
local _, MM = ...
local U = MM.Util

MM.IDs = {}
local R = MM.IDs

-- The saved resolve store outlives the fix that stopped producing bad data.
--
-- 1,813 npc "ids" were harvested from EJ_GetCreatureInfo, whose first return is
-- a journal-internal index rather than a creature id. IDResolver no longer
-- writes them, and Data_87's copy was deleted -- but the player's
-- SavedVariables still holds the old ones and will keep reporting them as
-- resolved. A stored wrong answer outlives the code that produced it, so it has
-- to be purged explicitly.
local STORE_VERSION = 2

local function db()
	MM.db.ids = MM.db.ids or { mounts = {}, maps = {}, instances = {}, npcs = {}, vendors = {} }
	local store = MM.db.ids
	if store.version ~= STORE_VERSION then
		store.npcs = {}
		store.version = STORE_VERSION
	end
	return store
end



------------------------------------------------------------
-- Mounts: journal is authoritative
------------------------------------------------------------
local function resolveMounts(store)
	local n = 0
	for _, entry in ipairs(MM.Scanner.mounts) do
		if entry.rec and entry.name then
			local key = entry.name:lower()
			local prev = store.mounts[key]
			if not prev or prev.mountID ~= entry.mountID or prev.spellID ~= entry.spellID then
				store.mounts[key] = { mountID = entry.mountID, spellID = entry.spellID }
				n = n + 1
			end
			-- backfill the live record so this session benefits immediately
			entry.rec.mountID = entry.mountID
			if not entry.rec.spellID then entry.rec.spellID = entry.spellID end
		end
	end
	return n
end

------------------------------------------------------------
-- Maps: resolve every zone name our data actually uses, and record when a
-- name is AMBIGUOUS so the "Dalaran" class of bug becomes visible instead of
-- silently picking the lowest ID.
------------------------------------------------------------
local function resolveMaps(store)
	local wanted, n = {}, 0

	local function want(name)
		if type(name) == "string" and name ~= "" then wanted[name] = true end
	end
	for _, rec in ipairs(MM.DBList) do
		if rec.zone then want(rec.zone.name) end
		if rec.instance then want(rec.instance.name) end
		if rec.patrolWaypoints then
			for _, p in ipairs(rec.patrolWaypoints) do want(p.name or p.waypointZone) end
		end
	end
	for _, loc in pairs(MM.VendorLocations or {}) do want(loc.name) end

	for name in pairs(wanted) do
		local matches = U.ResolveMapsByName(name)
		local entry = { mapID = U.ResolveMapByName(name) }
		if #matches > 1 then
			entry.ambiguous = matches -- record every candidate, don't hide it
		end
		if not entry.mapID then entry.unresolved = true end
		store.maps[name] = entry
		n = n + 1
	end
	return n
end

------------------------------------------------------------
-- Instances and encounters: the Encounter Journal knows both, by name,
-- in the client's own locale.
------------------------------------------------------------
local function resolveInstances(store)
	if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex) then return 0 end
	local n = 0
	local savedTier = EJ_GetCurrentTier and EJ_GetCurrentTier()

	for tier = 1, EJ_GetNumTiers() do
		pcall(EJ_SelectTier, tier)
		for _, isRaid in ipairs({ false, true }) do
			local index = 1
			while true do
				local ok, instanceID, name = pcall(EJ_GetInstanceByIndex, index, isRaid)
				if not ok or not instanceID then break end
				if name then
					local rec = store.instances[name:lower()] or {}
					rec.journalInstanceID = instanceID
					rec.isRaid = isRaid
					rec.encounters = rec.encounters or {}
					-- EJ_GetEncounterInfoByIndex only returns data for the
					-- CURRENTLY SELECTED instance; without this select it
					-- silently yields nothing.
					pcall(EJ_SelectInstance, instanceID)
					local e = 1
					while true do
						local okE, eName, _, journalEncounterID, _, _, _, dungeonEncounterID =
							pcall(EJ_GetEncounterInfoByIndex, e, instanceID)
						if not okE or not eName then break end
						rec.encounters[eName:lower()] = {
							journalEncounterID = journalEncounterID,
							dungeonEncounterID = dungeonEncounterID,
						}
						-- Boss CREATURE ids come free from the journal: no
						-- targeting required, and it covers every raid and
						-- dungeon boss in the game.
						if journalEncounterID and EJ_SelectEncounter and EJ_GetCreatureInfo then
							pcall(EJ_SelectEncounter, journalEncounterID)
							local c = 1
							while c <= 12 do
								-- EJ_GetCreatureInfo returns (id, name, ...) and pcall
								-- prepends its own ok, so the creature id is the FIRST
								-- real return, not a later one. Getting this wrong
								-- silently stores displayInfo as the npc id.
								local okC, ejIndex, cName = pcall(EJ_GetCreatureInfo, c, journalEncounterID)
								if not okC or not cName then break end
								-- DO NOT store this as an npc id. EJ_GetCreatureInfo's
								-- first return is a JOURNAL-INTERNAL index, not a world
								-- creature id -- verified against Wowhead: Abyssal
								-- Commander Sivara came back as 5004 where the real
								-- creature is 155144, Aarux as 3398 where it is 74412.
								-- Every value harvested this way was wrong, and anything
								-- matching rares by id was matching on nonsense.
								--
								-- Real creature ids come from vignette objectGUIDs (see
								-- below) or from a verified offline lookup.
								if type(ejIndex) == "number" and ejIndex > 0 then
									store.ejCreatures = store.ejCreatures or {}
									store.ejCreatures[cName:lower()] = ejIndex
								end
								c = c + 1
							end
						end
						e = e + 1
					end
					store.instances[name:lower()] = rec
					n = n + 1
				end
				index = index + 1
			end
		end
	end
	if savedTier then pcall(EJ_SelectTier, savedTier) end
	return n
end

------------------------------------------------------------
-- NPC ids: these cannot be looked up, only observed. Harvest the creature id
-- out of a GUID whenever the player interacts with something we care about.
------------------------------------------------------------
-- Parsed in one place, because a GUID is a client string and 12.0 can
-- withhold it. See U.NpcIDFromGUID.
local function npcIDFromGUID(guid)
	return MM.Util.NpcIDFromGUID(guid)
end

-- WHAT THE BACKFILL CAN ACTUALLY REACH, indexed once instead of searched.
--
-- Both observers used to walk all 1,608 records looking for one whose npc is
-- named but unidentified. Thirty-five records are in that state. The other
-- 1,573 iterations could never match, and they ran on NAME_PLATE_UNIT_ADDED,
-- UPDATE_MOUSEOVER_UNIT and VIGNETTE_MINIMAP_UPDATED -- which is to say, on
-- every nameplate that appears, every mouseover, and every minimap tick with a
-- rare on screen. Flying through a busy zone did tens of thousands of failed
-- comparisons a second to fill in a field that has thirty-five slots.
--
-- The index is built on first use, holds only those thirty-five, and entries
-- are removed as they are filled: once a name is known, it never costs anything
-- again. Behaviour is identical -- same records filled from the same
-- observations -- so this is purely the cost coming down.
local pending
local function pendingByName()
	if pending then return pending end
	pending = {}
	for _, rec in ipairs(MM.DBList or {}) do
		if rec.npc and rec.npc.name and not rec.npc.id then
			local key = rec.npc.name:lower()
			pending[key] = pending[key] or {}
			tinsert(pending[key], rec)
		end
	end
	return pending
end

-- Records are dropped from the index as they are identified, so a name seen a
-- second time costs one hash lookup and nothing else.
local function backfillNpc(key, id)
	local list = pendingByName()[key]
	if not list then return end
	for _, rec in ipairs(list) do
		if rec.npc and not rec.npc.id then rec.npc.id = id end
	end
	pending[key] = nil
end

-- The database is rebuilt when the layered sources are reflattened in a dev
-- session, and a stale index would then point at records nobody is using.
MM:On("MM_SCANNED", function() pending = nil end)

function R.ObserveUnit(unit)
	if not unit or not UnitExists(unit) then return end
	-- UnitName IS SECRET INSIDE INSTANCES. Reported from a delve as three
	-- distinct throws -- NAME_PLATE_UNIT_ADDED, UPDATE_MOUSEOVER_UNIT and
	-- PLAYER_TARGET_CHANGED -- which are the three events that land here. The
	-- vignette path was fixed and this one, four lines away, was not.
	--
	-- Losing the name costs only the backfill: the id below comes from the
	-- GUID and is unaffected, so rare alerts still match on it.
	local name = MM.Util.ReadableString(UnitName(unit))
	local id = npcIDFromGUID(UnitGUID(unit))
	if not (name and id) then return end
	local store = db()
	local key = name:lower()
	if store.npcs[key] ~= id then
		store.npcs[key] = id
		backfillNpc(key, id)
	end
end

-- Vignettes carry the creature GUID of the rare they mark, so flying past a
-- rare harvests its id with no targeting and no interaction at all.
function R.ObserveVignettes()
	if not (C_VignetteInfo and C_VignetteInfo.GetVignettes) then return end
	local ok, guids = pcall(C_VignetteInfo.GetVignettes)
	if not ok or not guids then return end
	local store = db()
	for _, vguid in ipairs(guids) do
		local okI, info = pcall(C_VignetteInfo.GetVignetteInfo, vguid)
		-- The NAME may be a 12.0 secret value. Reading it through the shared
		-- helper turns "throws several times a second inside a delve" into
		-- "this vignette teaches us nothing", which is the correct outcome:
		-- the id below is what we actually wanted, and it still arrives.
		local vname = info and MM.Util.ReadableString(info.name)
		if okI and info and vname and info.objectGUID then
			local id = npcIDFromGUID(info.objectGUID)
			-- THE SAME "have we already seen this" GUARD ObserveUnit HAS.
			--
			-- This one did not have it, and that is the difference between the
			-- two handlers: a nameplate appears once, but the minimap reports
			-- the same vignette on every update for as long as it is on screen.
			-- So the record walk below ran repeatedly for rares already
			-- identified minutes ago.
			local key = vname:lower()
			if id and store.npcs[key] ~= id then
				store.npcs[key] = id
				backfillNpc(key, id)
			end
		end
	end
end

-- Talking to an NPC identifies it as surely as targeting does, and it is how
-- you reach most vendors anyway.
function R.ObserveGossip()
	pcall(R.ObserveUnit, "npc")
end

function R.ObserveVendor()
	-- Through the same guard as ObserveUnit above: a vendor is a unit, and its
	-- name is as secret as any other inside an instance.
	local name, id = MM.Util.ReadableString(UnitName("npc")),
		npcIDFromGUID(UnitGUID("npc"))
	if not (name and id) then return end
	local store = db()
	store.vendors[name:lower()] = {
		npcID = id,
		mapID = C_Map.GetBestMapForUnit("player"),
	}
	-- capture where the vendor actually stands, which beats any wiki coord
	local mapID = C_Map.GetBestMapForUnit("player")
	if mapID then
		local pos = C_Map.GetPlayerMapPosition(mapID, "player")
		if pos then
			local x, y = pos:GetXY()
			store.vendors[name:lower()].x = math.floor(x * 1000 + 0.5) / 10
			store.vendors[name:lower()].y = math.floor(y * 1000 + 0.5) / 10
		end
	end

	-- WHAT they sell, not just where they are.
	--
	-- Recording only the position left the useful half unanswered: 213 records
	-- still have no location, and 128 of them hold an itemID we could match if
	-- we knew who stocked it. No API answers "who sells this item" -- which is
	-- why AllTheThings resolves vendors on mouseover rather than shipping them,
	-- and why its tables have no coordinates to borrow.
	--
	-- But an OPEN vendor will happily list its own stock. So every merchant the
	-- player opens teaches us its inventory, and a mount sold there becomes
	-- locatable for good.
	--
	-- Only mount items are kept. Storing whole inventories would grow saved
	-- variables without bound to answer a question about a few hundred items.
	if not GetMerchantNumItems then return end
	local wanted = MM.ItemToMount
	if not wanted then return end

	local sells
	for slot = 1, (GetMerchantNumItems() or 0) do
		local itemID = GetMerchantItemID and GetMerchantItemID(slot)
		if itemID and wanted[itemID] then
			sells = sells or {}
			sells[#sells + 1] = itemID
		end
	end
	if sells then
		store.vendors[name:lower()].sells = sells
		MM:Fire("MM_VENDOR_OBSERVED", name, store.vendors[name:lower()])
	end
end

------------------------------------------------------------
-- Run
------------------------------------------------------------
-- Currencies and factions: walking a bounded id space, once.
--
-- The achievement fix exposed a PATTERN was not generalised. 127 conditions
-- name a faction with no factionID and 107 name a currency with no id -- and
-- like the achievements, it had been treating both as lookups.
--
-- There is no reverse name->id call for either. But the id space is small and
-- dense, and the client answers `GetCurrencyInfo(id)` / `GetFactionDataByID(id)`
-- for every id that exists. Walking it once and caching the result is not
-- guessing: it is reading the client's own tables exhaustively.
--
-- Why not `GetCurrencyListSize` or `GetNumFactions`? Because those enumerate
-- what THIS CHARACTER has encountered. A mount gated behind a faction the
-- player has never met would never resolve -- which is precisely the mount most
-- in need of an estimate.
--
-- CHUNKED ACROSS FRAMES, deliberately. Three thousand C calls in one pass is
-- how the router froze the client for minutes in Addendum 97; that lesson cost
-- an evening and is not being relearned. This runs 200 ids per frame, once per
-- install, and stores the result.
local SCAN_MAX = 3200
local SCAN_CHUNK = 200

local function scanSpace(getName, into, onDone)
	local id, found = 1, 0
	local function step()
		local stop = math.min(id + SCAN_CHUNK - 1, SCAN_MAX)
		while id <= stop do
			local ok, name = pcall(getName, id)
			if ok and name and name ~= "" then
				local key = name:lower()
				if into[key] == nil then
					into[key] = id
					found = found + 1
				elseif into[key] ~= id then
					into[key] = false          -- the name is not unique
				end
			end
			id = id + 1
		end
		if id <= SCAN_MAX then
			C_Timer.After(0, step)
		elseif onDone then
			onDone(found)
		end
	end
	step()
end

-- Fills every condition that named one of these without giving its id.
local function applyIndex(store)
	local filled = 0
	-- Record the MISSES, not just the hits.
	--
	-- The index is the client's ENTIRE currency and faction id space, so a name
	-- that is not in it is not "not looked up yet" -- it is absent from this
	-- client and no amount of re-running will find it. Without recording that,
	-- the scorecard counted 108 such names as "client-resolvable — /mm resolve"
	-- and sent the player to a command that correctly resolves 0 of them, over
	-- and over. The achievement stage already kept a missing-cache for exactly
	-- this reason; currency and faction simply never got one.
	--
	-- Only trustworthy once the index EXISTS -- before that, absence means we
	-- have not looked, which is a different thing and must not be recorded as
	-- proof.
	if store.indexBuilt then
		store.currencyMissing = store.currencyMissing or {}
		store.factionMissing = store.factionMissing or {}
	end
	for _, rec in pairs(MM.DBByName) do
		for _, cond in ipairs(rec.conditions or {}) do
			if cond.type == "CURRENCY" and cond.name and not cond.id then
				local key = cond.name:lower()
				local hit = (store.currencies or {})[key]
				if hit then
					cond.id = hit; filled = filled + 1
				elseif store.currencyMissing then
					store.currencyMissing[key] = true
				end
			elseif cond.type == "REP" and not cond.factionID then
				local nm = cond.factionName or cond.name
				local hit = nm and (store.factions or {})[nm:lower()]
				if hit then
					cond.factionID = hit; filled = filled + 1
				elseif nm and store.factionMissing then
					store.factionMissing[nm:lower()] = true
				end
			end
		end
	end
	store.idsApplied = filled
	if filled > 0 and MM.Planner and MM.Planner.InvalidateRanks then
		MM.Planner.InvalidateRanks()
	end
	return filled
end
R.ApplyIndex = applyIndex

-- Built once, then reused from saved variables. The id space does not change
-- between logins; only a patch changes it, and a patch changes the TOC too.
function R.BuildIndexes(force)
	local store = db()
	if store.indexBuilt and not force then return applyIndex(store) end
	store.currencies = {}
	store.factions = {}

	local pending = 2
	local function done()
		pending = pending - 1
		if pending > 0 then return end
		store.indexBuilt = true
		store.indexBuiltAt = GetServerTime and GetServerTime() or 0
		local n = applyIndex(store)
		MM:Print("Indexed the currency and faction tables — %d conditions resolved.", n)
		MM:Fire("MM_IDS_RESOLVED")
	end

	if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
		scanSpace(function(id)
			local info = C_CurrencyInfo.GetCurrencyInfo(id)
			return info and info.name
		end, store.currencies, done)
	else done() end

	if C_Reputation and C_Reputation.GetFactionDataByID then
		scanSpace(function(id)
			local data = C_Reputation.GetFactionDataByID(id)
			return data and data.name
		end, store.factions, done)
	else done() end
end

-- Achievement ids, straight from the client's own achievement database.
--
-- Requirement — close all gaps, get everything to 100%. Most of the remaining gaps
-- genuinely cannot be closed from outside the game -- a drop rate nobody has
-- observed does not exist to be looked up. This one can, and it had been
-- treating it as a lookup when it was sitting in the client all along.
--
-- 75 records name an achievement in a condition but carry no id, so they are
-- charged a flat six hours and show no progress. Wowhead only publishes an
-- authoritative id on about one page in seven, and the rest of its pages carry
-- the id only inside USER COMMENTS -- which is why Addendum 125 stopped at
-- eleven rather than harvesting seventy-five plausible-looking numbers.
--
-- But `GetCategoryList` plus `GetAchievementInfo(category, index)` enumerates
-- EVERY achievement in the game with its real name and id. That is not a
-- lookup, a guess, or a scrape: it is the same table the Achievements UI reads.
--
-- Names are matched exactly, case-folded. A name that matches two achievements
-- (Blizzard reuses a few between factions and guild variants) is recorded as
-- AMBIGUOUS and left alone -- picking one at random is how you end up telling
-- someone to earn the wrong thing.
local function resolveAchievements(store)
	if not (GetCategoryList and GetAchievementInfo and GetCategoryNumAchievements) then
		return 0
	end
	store.achievements = store.achievements or {}
	store.achievementAmbiguous = store.achievementAmbiguous or {}
	-- Names we have already looked for and NOT found. Without this the whole
	-- 5,400-achievement index was rebuilt on every single login purely to fail
	-- to find the same 45 names again.
	store.achievementMissing = store.achievementMissing or {}

	-- What is still open? Apply the cache first -- it is a table lookup per
	-- condition -- and only then decide whether the index is worth building.
	local wanted, filled = {}, 0
	local anyWanted = false
	for _, rec in pairs(MM.DBByName) do
		for _, cond in ipairs(rec.conditions or {}) do
			if cond.type == "ACHIEVEMENT" and cond.name and not cond.id then
				local key = cond.name:lower()
				local cached = store.achievements[cond.name]
				if cached then
					cond.id = cached
					filled = filled + 1
				elseif not store.achievementMissing[key]
					and not store.achievementAmbiguous[cond.name] then
					wanted[key] = cond.name
					anyWanted = true
				end
			end
		end
	end

	-- THE FIX. Measured at 3,000 ms -- 99% of everything this addon spent at
	-- login -- and all of it to re-learn what the last run already knew. The
	-- index is only built when a name is outstanding that we have never
	-- searched for. Steady state is now the loop above and nothing else.
	if not anyWanted then return filled end

	-- Timed under its OWN name so /mm loadtime distinguishes the one run that
	-- has to walk the client from every run afterwards that does not. Without
	-- this the report shows the same number either way and the only way to
	-- tell "still broken" from "populating" is to reload again and squint.
	local buildIndex = MM.TimeIt("IDResolver:achievementIndex(FIRST RUN)", function()
	local index, seen = {}, 0
	local okCats, cats = pcall(GetCategoryList)
	if not (okCats and type(cats) == "table") then return nil, 0 end
	for _, categoryID in ipairs(cats) do
		-- ONE pcall per category, not one per achievement. 5,438 pcalls around
		-- a C function is most of the remaining cost, and a category that
		-- throws still cannot take the rest of the walk down.
		pcall(function()
			local count = GetCategoryNumAchievements(categoryID)
			for i = 1, (count or 0) do
				local id, name = GetAchievementInfo(categoryID, i)
				if id and name and name ~= "" then
					seen = seen + 1
					local key = name:lower()
					if index[key] == nil then
						index[key] = id
					elseif index[key] ~= id then
						index[key] = false      -- the name is not unique
					end
				end
			end
		end)
	end
	return index, seen
	end)

	local index, seen = buildIndex()
	if not index or seen == 0 then return filled end

	for _, rec in pairs(MM.DBByName) do
		for _, cond in ipairs(rec.conditions or {}) do
			if cond.type == "ACHIEVEMENT" and cond.name and not cond.id then
				local hit = index[cond.name:lower()]
				if hit then
					cond.id = hit
					store.achievements[cond.name] = hit
					filled = filled + 1
				elseif hit == false then
					store.achievementAmbiguous[cond.name] = true
				end
			end
		end
	end
	-- Remember the failures too, or the next login pays the same 3 seconds.
	for key in pairs(wanted) do
		if index[key] == nil then store.achievementMissing[key] = true end
	end
	store.achievementsSeen = seen
	return filled
end

-- onDone(summary) fires when the LAST stage finishes, not when this returns.
--
-- Resolve is asynchronous -- one frame per stage -- so it returns almost
-- immediately and everything interesting is printed frames later. Wrapping the
-- CALL in a capture therefore records nothing at all, which is how /mm resolve
-- came to open a window saying "Nothing to report" while the work ran fine in
-- the background. A caller that wants the result has to be told when there is
-- one; it cannot watch the call.
function R.Resolve(verbose, onDone)
	local store = db()

	-- ONE FRAME PER STAGE, not all five in one.
	--
	-- Measured: 2,971 ms inside a single handler at login -- 99% of everything
	-- this addon spends. That is a three second stall of the whole client, and
	-- it is what "the addon is slow to load" actually was. Nothing here got
	-- faster; the work is simply spread so no single frame carries all of it.
	--
	-- Each stage is timed under its own name, so /mm loadtime says WHICH of the
	-- five is expensive instead of blaming the group. Guessing at that is how
	-- the last three performance theories went wrong.
	local STAGES = {
		{ "mounts",       resolveMounts },
		{ "maps",         resolveMaps },
		{ "instances",    resolveInstances },
		{ "achievements", resolveAchievements },
		{ "index",        applyIndex },
	}

	local counts, i = {}, 1
	local function finish()
		store.resolvedAt = GetServerTime()
		local summary = ("Resolved %d mounts, %d zone names, %d instances, "
			.. "%d achievement ids, %d currency/faction ids."):format(
			counts.mounts or 0, counts.maps or 0, counts.instances or 0,
			counts.achievements or 0, counts.index or 0)
		if onDone then
			onDone(summary)
		elseif verbose then
			MM:Print(summary)
		end
		if (counts.achievements or 0) > 0 and MM.Planner and MM.Planner.InvalidateRanks then
			MM.Planner.InvalidateRanks()
		end
		MM:Fire("MM_IDS_RESOLVED")
	end

	local function step()
		local stage = STAGES[i]
		if not stage then return finish() end
		counts[stage[1]] = MM.TimeIt("IDResolver:" .. stage[1], stage[2])(store) or 0
		i = i + 1
		if STAGES[i] then C_Timer.After(0, step) else finish() end
	end
	step()
end

function R.Coverage()
	local store = db()
	local total, withID = 0, 0
	local ambiguous, unresolved = {}, {}
	-- Re-resolve every name AGAINST THE CURRENT RESOLVER rather than trusting the
	-- flags /mm resolve wrote. Those are a snapshot: after the zone aliases were
	-- added, this still reported the same 13 unresolvable names because nobody
	-- had re-run the resolve. A diagnostic that reports stale state is worse than
	-- one that reports nothing.
	-- Which records use each zone name, so we can ask whether the record itself
	-- settles an ambiguous one.
	-- Index BOTH the zone name and the instance name. Raid and dungeon records
	-- carry their location in rec.instance.name, so indexing only rec.zone.name
	-- left every one of them looking context-free -- which is why Ulduar,
	-- Karazhan, Icecrown Citadel and friends reported as unsettled when the
	-- resolver settles them perfectly well.
	local usedBy = {}
	local function note(name, rec)
		if not name then return end
		usedBy[name] = usedBy[name] or {}
		tinsert(usedBy[name], rec)
	end
	for _, rec in ipairs(MM.DBList or {}) do
		note(rec.zone and rec.zone.name, rec)
		note(rec.instance and rec.instance.name, rec)
	end

	local settled, unused = 0, 0
	for name, m in pairs(store.maps) do
		total = total + 1
		local live = U.ResolveMapByName(name)
		if live then
			withID = withID + 1
			local list = U.ResolveMapsByName(name)
			if list and #list > 1 then
				-- Ambiguous by NAME is not the same as ambiguous in PRACTICE.
				-- If every record using this name resolves to a specific map
				-- from its own expansion, the ambiguity never bites anyone.
				local resolvedAll, any = true, false
				for _, rec in ipairs(usedBy[name] or {}) do
					any = true
					if not U.ResolveMapForRecord(name, rec) then resolvedAll = false end
				end
				if not any then
					-- Nothing in the database refers to this name. It is a
					-- leftover in the saved resolve store from an older data
					-- shape, not a live problem -- and reporting it as ambiguous
					-- sent us looking for a fault that does not exist.
					unused = unused + 1
					store.maps[name] = nil
				elseif resolvedAll then
					settled = settled + 1
				else
					tinsert(ambiguous, name)
				end
			end
		else
			tinsert(unresolved, name)
		end
		m.mapID, m.unresolved = live, (live == nil) or nil
	end
	local npcCount = 0
	for _ in pairs(store.npcs) do npcCount = npcCount + 1 end
	local vendorCount = 0
	for _ in pairs(store.vendors) do vendorCount = vendorCount + 1 end
	return {
		zones = total, zonesResolved = withID, settled = settled, unused = unused,
		ambiguous = ambiguous, unresolved = unresolved,
		npcs = npcCount, vendors = vendorCount,
	}
end

------------------------------------------------------------
-- Export: a committable Lua chunk, shown in a copy-paste window and also kept
-- in SavedVariables as a fallback. The saved copy only reaches
-- WTF/Account/<ACCOUNT>/SavedVariables/MasterMountsWorldTour.lua at /reload or
-- logout -- the file takes the ADDON FOLDER's name, not the variable's.
------------------------------------------------------------
function R.Export()
	local store = db()
	local out = {}
	tinsert(out, "-- MasterMounts: IDs resolved from a live client. Generated, do not hand-edit.")
	tinsert(out, "local _, MM = ...")
	tinsert(out, "")
	tinsert(out, "MM.AddResolvedIDs({")

	tinsert(out, "  maps = {")
	local names = {}
	for name in pairs(store.maps) do tinsert(names, name) end
	table.sort(names)
	for _, name in ipairs(names) do
		local m = store.maps[name]
		if m.mapID then
			local note = m.ambiguous and (" -- AMBIGUOUS: " .. #m.ambiguous .. " maps share this name") or ""
			tinsert(out, ('    [%q] = %d,%s'):format(name, m.mapID, note))
		end
	end
	tinsert(out, "  },")

	tinsert(out, "  npcs = {")
	local npcNames = {}
	for name in pairs(store.npcs) do tinsert(npcNames, name) end
	table.sort(npcNames)
	for _, name in ipairs(npcNames) do
		tinsert(out, ('    [%q] = %d,'):format(name, store.npcs[name]))
	end
	tinsert(out, "  },")

	-- instances + their encounters: dungeonEncounterID is what the lockout
	-- system needs, and it can only come from a live client
	tinsert(out, "  instances = {")
	local instNames = {}
	for name in pairs(store.instances) do tinsert(instNames, name) end
	table.sort(instNames)
	for _, name in ipairs(instNames) do
		local inst = store.instances[name]
		if inst.journalInstanceID then
			local encs = {}
			local eNames = {}
			for e in pairs(inst.encounters or {}) do tinsert(eNames, e) end
			table.sort(eNames)
			for _, e in ipairs(eNames) do
				local d = inst.encounters[e]
				if d.dungeonEncounterID then
					tinsert(encs, ('[%q]=%d'):format(e, d.dungeonEncounterID))
				end
			end
			tinsert(out, ('    [%q] = { id = %d, raid = %s, enc = { %s } },'):format(
				name, inst.journalInstanceID, tostring(inst.isRaid or false),
				table.concat(encs, ", ")))
		end
	end
	tinsert(out, "  },")

	tinsert(out, "  vendors = {")
	local vNames = {}
	for name in pairs(store.vendors) do tinsert(vNames, name) end
	table.sort(vNames)
	for _, name in ipairs(vNames) do
		local v = store.vendors[name]
		tinsert(out, ('    [%q] = { npcID = %d, mapID = %s, x = %s, y = %s },'):format(
			name, v.npcID, tostring(v.mapID), tostring(v.x), tostring(v.y)))
	end
	tinsert(out, "  },")
	tinsert(out, "})")

	local text = table.concat(out, "\n")

	-- ON SCREEN, NOW -- BECAUSE "EXPORTED" WAS NOT TRUE YET.
	--
	-- An addon cannot write a file. This only ever put the chunk in a saved
	-- variable, and the client writes those at /reload or logout and not before,
	-- so the .lua on disk was untouched at the moment this said "Exported" and
	-- stayed that way until the session ended. Reported from outside as exactly
	-- that: the message claimed success and the timestamp disagreed.
	--
	-- The report window already solves this and has since it was built: no
	-- length cap, and it selects its own contents so Ctrl+C is the only key
	-- anybody needs. Nothing about an id export made it a different problem, it
	-- simply never asked for the window.
	-- PERSISTED ONLY WHEN IT IS THE DELIVERY MECHANISM.
	--
	-- This used to write the whole chunk into saved variables every time,
	-- unconditionally -- about 53 KB, kept for the life of the account, on the
	-- machine of every player who ever ran the command. Nothing reads it back:
	-- it exists so a HUMAN can find it in the file, which only matters when the
	-- copy window is unavailable. When the window opens, the text is already on
	-- screen and selects itself, and the copy on disk buys nothing.
	if MM.Diagnostics and MM.Diagnostics.ShowExport then
		MM.db.idExport = nil
		MM.Diagnostics.ShowExport(text, ("Resolved IDs — %d lines"):format(#out))
		MM:Print("%d lines ready to copy. Paste into Data/_source/Data_87_ResolvedIDs.lua.", #out)
		return
	end
	-- The fallback path, and now the only one that writes to disk. Said
	-- accurately: the copy is not there yet. NAMED CORRECTLY TOO -- the
	-- saved-variables file takes the ADDON FOLDER's name, so it is
	-- MasterMountsWorldTour.lua. Every message here used to say
	-- MasterMounts.lua, which is a file that has never existed, so anyone
	-- following the instruction was checking the wrong path.
	MM.db.idExport = text
	MM:Print("%d lines kept in MasterMountsDB.idExport, which reaches "
		.. "WTF/Account/<ACCOUNT>/SavedVariables/MasterMountsWorldTour.lua "
		.. "on your next /reload or logout -- not before.", #out)
end

------------------------------------------------------------
-- Consuming a committed export
------------------------------------------------------------
-- MM.ResolvedIDs and MM.AddResolvedIDs now live in Data/Schema.lua. They HAVE to
-- be defined before the data files run: Data_87_ResolvedIDs.lua calls
-- AddResolvedIDs at file scope, and this module loads fifteen files later, so
-- defining them here meant the call hit a nil and every resolved ID was lost.

------------------------------------------------------------
-- Wiring
------------------------------------------------------------
-- Build once, apply always. Applying is cheap (a table lookup per condition);
-- building walks 6,400 ids and only ever needs doing once per install.
MM:On("MM_LOGIN", function()
	C_Timer.After(3, MM.TimeIt("IDResolver:BuildIndexes", function() pcall(R.BuildIndexes) end))
end)

MM:On("MM_SCANNED", function()
	C_Timer.After(3, function() R.Resolve(false) end)
end)

MM:RegisterGameEvent("MERCHANT_SHOW", function() pcall(R.ObserveVendor) end)
MM:RegisterGameEvent("GOSSIP_SHOW", function() pcall(R.ObserveGossip) end)
MM:RegisterGameEvent("QUEST_DETAIL", function() pcall(R.ObserveGossip) end)
MM:RegisterGameEvent("VIGNETTE_MINIMAP_UPDATED", function() pcall(R.ObserveVignettes) end)
MM:RegisterGameEvent("VIGNETTES_UPDATED", function() pcall(R.ObserveVignettes) end)
MM:RegisterGameEvent("PLAYER_TARGET_CHANGED", function() pcall(R.ObserveUnit, "target") end)
MM:RegisterGameEvent("UPDATE_MOUSEOVER_UNIT", function() pcall(R.ObserveUnit, "mouseover") end)
MM:RegisterGameEvent("NAME_PLATE_UNIT_ADDED", function(unit) pcall(R.ObserveUnit, unit) end)

MM:On("MM_IDS_DEBUG", function()
	local store = db()
	local named, withID = 0, 0
	for _, rec in pairs(MM.DBByName) do
		for _, cond in ipairs(rec.conditions or {}) do
			if cond.type == "ACHIEVEMENT" and cond.name then
				named = named + 1
				if cond.id then withID = withID + 1 end
			end
		end
	end
	-- Currency and faction coverage, the other two closable id gaps.
	local function coverage(kind, idField)
		local n, ok = 0, 0
		for _, rec in pairs(MM.DBByName) do
			for _, cond in ipairs(rec.conditions or {}) do
				if cond.type == kind then
					n = n + 1
					if cond[idField] then ok = ok + 1 end
				end
			end
		end
		return n, ok
	end
	local cN, cOK = coverage("CURRENCY", "id")
	local fN, fOK = coverage("REP", "factionID")
	local idx = 0
	for _ in pairs(store.currencies or {}) do idx = idx + 1 end
	local fidx = 0
	for _ in pairs(store.factions or {}) do fidx = fidx + 1 end
	MM:Print("Currencies: %d of %d conditions carry an id (index holds %d names).",
		cOK, cN, idx)
	MM:Print("Factions:   %d of %d conditions carry an id (index holds %d names).",
		fOK, fN, fidx)
	if not store.indexBuilt then
		MM:Print("   |cffff9a3cIndex not built yet|r — it walks the id space once, "
			.. "a few seconds after login. /mm resolve forces it.")
	end

	if named > 0 then
		MM:Print("Achievements: %d of %d conditions carry an id (%.0f%%), from an "
			.. "index of %d built from the client.", withID, named,
			withID / named * 100, store.achievementsSeen or 0)
		local amb = {}
		for name in pairs(store.achievementAmbiguous or {}) do amb[#amb + 1] = name end
		if #amb > 0 then
			table.sort(amb)
			MM:Print("   %d names match more than one achievement and are left alone:",
				#amb)
			for i = 1, math.min(#amb, 5) do MM:Print("      %s", amb[i]) end
			if #amb > 5 then MM:Print("      ...and %d more", #amb - 5) end
			MM:Print("   Picking one at random is how you tell someone to earn the wrong thing.")
		end
	end

	local c = R.Coverage()
	local committed = 0
	for _ in pairs((MM.ResolvedIDs and MM.ResolvedIDs.npcs) or {}) do committed = committed + 1 end
	MM:Print("Zone names: %d/%d resolved. NPC ids: %d committed + %d learned. Vendors: %d.",
		c.zonesResolved, c.zones, committed, c.npcs, c.vendors)
	-- how much of the database's own npc list is now covered
	local want, have = 0, 0
	for _, rec in ipairs(MM.DBList) do
		if rec.npc and rec.npc.name then
			want = want + 1
			-- Committed ids (Data_87b, verified against Wowhead) count just as
			-- much as ones this client resolved. Checking only the saved store
			-- reported 73/147 while 130 verified ids sat unused.
			local key = rec.npc.name:lower()
			if rec.npc.id
				or (MM.ResolvedIDs and MM.ResolvedIDs.npcs and MM.ResolvedIDs.npcs[key])
				or (MM.db.ids.npcs and MM.db.ids.npcs[key]) then
				have = have + 1
			end
		end
	end
	MM:Print("Database npcs with a resolved id: %d/%d", have, want)
	if (c.unused or 0) > 0 then
		MM:Print("%d stale names pruned — nothing in the database used them.", c.unused)
	end
	if (c.settled or 0) > 0 then
		MM:Print("|cff40d860%d ambiguous names settled by the mount's expansion.|r", c.settled)
	end
	if #c.ambiguous > 0 then
		MM:Print("|cffff9a3cStill ambiguous (%d) — no record context to settle them:|r %s",
			#c.ambiguous, table.concat(c.ambiguous, ", "))
	end
	if #c.unresolved > 0 then
		MM:Print("|cffff4444Unresolvable zone names (%d):|r %s", #c.unresolved,
			table.concat(c.unresolved, ", "))
	end
end)

-- The stored id export is a fallback for clients with no copy window, and it is
-- about 53 KB. Anyone who ran the command before this build is carrying one
-- that nothing reads. Dropped once, and only where the window that replaced it
-- actually exists -- on a client that still needs the fallback, it stays.
MM:On("MM_LOGIN", function()
	if MM.db and MM.db.idExport and MM.Diagnostics and MM.Diagnostics.ShowExport then
		MM.db.idExport = nil
	end
end)
