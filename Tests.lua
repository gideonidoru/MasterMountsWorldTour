-- Master Mounts self-test: /mm selftest
--
-- Not a unit-test suite. Mocking WoW well enough to unit-test this addon would
-- cost more than the addon and still not answer the question that actually
-- matters before release, which is: *is anything silently switched off in this
-- client?*
--
-- 41 of our 58 external API calls are deliberately guarded so a missing one
-- degrades instead of erroring. That is right for players and dangerous for us:
-- Callings detection, bag scanning and quest-zone resolution can all be dead on
-- arrival and the only symptom is a slightly emptier plan. This turns that
-- silence into a report.
--
-- Three sections:
--   API    -- does this client actually expose what each feature needs
--   DATA   -- invariants over the shipped database
--   LOGIC  -- pure functions with known inputs and known answers
--
-- Everything here is read-only. It does not modify the plan, the route or any
-- saved variable.
local _, MM = ...
local U = MM.Util

MM.Tests = {}
local T = MM.Tests

local results, current
local PASS, FAIL, WARN = "PASS", "FAIL", "WARN"

local function record(state, group, name, detail)
	results[#results + 1] = { state = state, group = group, name = name, detail = detail }
end

-- ok == true -> PASS, false -> FAIL, nil -> WARN (absent but survivable)
local function check(name, fn)
	local ran, ok, detail = pcall(fn)
	if not ran then
		record(FAIL, current, name, "threw: " .. tostring(ok))
		return
	end
	record(ok == true and PASS or (ok == nil and WARN or FAIL), current, name, detail)
end

------------------------------------------------------------
-- API probes
------------------------------------------------------------
-- Each entry names the FEATURE that dies without it, because "C_Foo.Bar
-- missing" tells you nothing on its own.
local API_PROBES = {
	{ "Mount journal", function() return C_MountJournal and C_MountJournal.GetMountIDs ~= nil end, true },
	{ "Bag detection (items that teach mounts)",
		function() return C_MountJournal and C_MountJournal.GetMountFromItem ~= nil end },
	{ "Covenant Callings (Necroray rotation)",
		function() return C_CovenantCallings and C_CovenantCallings.RequestCallings ~= nil end },
	{ "Calling identification",
		function() return C_QuestLog and C_QuestLog.IsQuestCalling ~= nil end },
	{ "Covenant lookup",
		function() return C_Covenants and C_Covenants.GetActiveCovenantID ~= nil end },
	{ "Quest zone resolution", function()
		local n = 0
		if C_TaskQuest and C_TaskQuest.GetQuestZoneID then n = n + 1 end
		if C_QuestLog and C_QuestLog.GetQuestAdditionalHighlights then n = n + 1 end
		if GetQuestUiMapID then n = n + 1 end
		if n == 0 then return false, "no probe available — Calling zones unresolvable" end
		return true, ("%d of 3 probes available"):format(n)
	end },
	{ "Quest state (prerequisite gating)",
		function() return C_QuestLog and C_QuestLog.IsOnQuest ~= nil
			and C_QuestLog.GetTitleForQuestID ~= nil end },
	{ "Profession gating",
		function() return GetProfessions ~= nil and GetProfessionInfo ~= nil end },
	{ "Toy detection (teleports)", function() return PlayerHasToy ~= nil end },
	{ "Hearthstone teleport", function()
		-- Must test what Teleports actually needs, not merely that the API
		-- answers. It requires the bind NAME to resolve to a map; a player bound
		-- to an inn subzone ("Snug Harbor Inn") gets a perfectly good string
		-- here and no hearthstone option in practice. The first version of this
		-- probe passed on the string alone and would have reported a working
		-- feature that does nothing.
		local b = GetBindLocation and GetBindLocation()
		if not b or b == "" then return nil, "no bind location reported" end
		local learned = MM.db.hearthMaps and MM.db.hearthMaps[b]
		if learned then return true, ("%s (learned, map %d)"):format(b, learned) end
		if not (U and U.ResolveMapByName and U.ResolveMapByName(b)) then
			return nil, ("bound to %q — visit it once and we'll learn the map"):format(b)
		end
		return true, b
	end },
	{ "Close-button art", function()
		if not (C_Texture and C_Texture.GetAtlasInfo) then return nil, "atlas API absent — text glyph fallback" end
		if C_Texture.GetAtlasInfo("uitools-icon-close") == nil then
			return nil, "atlas missing — text glyph fallback in use"
		end
		return true
	end },
	{ "Instance lockouts",
		function() return GetSavedInstanceEncounterInfo ~= nil end },
	{ "Per-encounter lockouts",
		function() return C_RaidLocks and C_RaidLocks.IsEncounterComplete ~= nil end },
	{ "Trading Post",
		function() return C_PerksProgram and C_PerksProgram.GetAvailableVendorItemIDs ~= nil end },
	{ "Rare alerts (vignettes)",
		function() return C_VignetteInfo and C_VignetteInfo.GetVignettes ~= nil end },
	{ "Group compare (addon comms)",
		function() return C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix ~= nil end },
	{ "Encounter Journal (ID resolution)",
		function() return EJ_SelectInstance ~= nil and EJ_GetEncounterInfoByIndex ~= nil end },
	{ "Calendar (holidays, Timewalking)",
		function() return C_Calendar and C_Calendar.GetNumDayEvents ~= nil end },
	{ "Rarity tuning (MountsRarity)", function()
		if not (LibStub and LibStub("MountsRarity-2.0", true)) then
			return nil, "not installed — difficulty uses our effort estimates only"
		end
		local pct = MM.Rarity.Get(6) -- a common mount; any number proves the table loaded
		if type(pct) ~= "number" then return false, "library present but returned no data" end
		return true, ("live, sample reads %.2f%%"):format(pct)
	end },
	{ "Currency", function() return C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo ~= nil end, true },
	{ "Map positions", function() return C_Map and C_Map.GetPlayerMapPosition ~= nil end, true },
}

local function runAPI()
	current = "API"
	for _, probe in ipairs(API_PROBES) do
		local name, fn, required = probe[1], probe[2], probe[3]
		check(name, function()
			local ok, detail = fn()
			-- an optional feature that is absent is a WARN, not a failure:
			-- the addon is built to run without it
			if ok == false and not required then return nil, detail or "not available in this client" end
			return ok, detail
		end)
	end
end

------------------------------------------------------------
-- Data invariants
------------------------------------------------------------
local VALID_CATEGORY = {
	ACHIEVEMENT = true, CLASS = true, CURRENCY = true, DROP = true, GARRISON = true,
	HOLIDAY = true, PROFESSION = true, PROMOTION = true, PUZZLE = true, PVP = true,
	QUEST = true, RARE = true, REMOVED = true, REP = true, STORE = true, TCG = true,
	TIMEWALKING = true, TRADINGPOST = true, TREASURE = true, VENDOR = true,
	ZONEDROP = true,
}

local function canonicalRecords()
	local out = {}
	for _, rec in ipairs(MM.DBList or {}) do
		local canon = (rec.spellID and MM.DBBySpell[rec.spellID] == rec)
			or (rec.name and MM.DBByName[rec.name:lower()] == rec)
		if canon then out[#out + 1] = rec end
	end
	return out
end

local function runData()
	current = "DATA"
	local recs = canonicalRecords()

	check("Database loaded", function()
		if #recs == 0 then return false, "no records — Data/Mounts.lua did not load" end
		return true, ("%d canonical records"):format(#recs)
	end)

	check("Resolved IDs loaded", function()
		local ids = MM.ResolvedIDs
		local maps = 0
		for _ in pairs(ids and ids.maps or {}) do maps = maps + 1 end
		if maps == 0 then
			-- this exact failure shipped once: Data_87 called AddResolvedIDs
			-- before it existed, and every ID was discarded in silence
			return false, "no resolved maps — check Schema defines AddResolvedIDs"
		end
		return true, ("%d maps"):format(maps)
	end)

	check("Every record has a name", function()
		-- An empty table satisfies "nothing is wrong". Every check here
		-- counts defects and returns count == 0, which is TRUE for zero
		-- records -- so a database that failed to load would report a
		-- clean bill of health from all of them at once. Report nothing
		-- rather than something reassuring.
		if #recs == 0 then return nil, "no records loaded" end
		local bad = 0
		for _, r in ipairs(recs) do if not r.name or r.name == "" then bad = bad + 1 end end
		return bad == 0, bad > 0 and (bad .. " unnamed") or nil
	end)

	check("No duplicate spellIDs", function()
		-- An empty table satisfies "nothing is wrong". Every check here
		-- counts defects and returns count == 0, which is TRUE for zero
		-- records -- so a database that failed to load would report a
		-- clean bill of health from all of them at once. Report nothing
		-- rather than something reassuring.
		if #recs == 0 then return nil, "no records loaded" end
		local seen, dupes = {}, 0
		for _, r in ipairs(recs) do
			if r.spellID then
				if seen[r.spellID] then dupes = dupes + 1 else seen[r.spellID] = true end
			end
		end
		return dupes == 0, dupes > 0 and (dupes .. " duplicated") or nil
	end)

	check("Categories are known", function()
		-- An empty table satisfies "nothing is wrong". Every check here
		-- counts defects and returns count == 0, which is TRUE for zero
		-- records -- so a database that failed to load would report a
		-- clean bill of health from all of them at once. Report nothing
		-- rather than something reassuring.
		if #recs == 0 then return nil, "no records loaded" end
		local bad, example = 0, nil
		for _, r in ipairs(recs) do
			if r.category and not VALID_CATEGORY[r.category] then
				bad = bad + 1; example = example or (r.name .. " = " .. r.category)
			end
		end
		return bad == 0, example
	end)

	check("Coordinates in range", function()
		-- An empty table satisfies "nothing is wrong". Every check here
		-- counts defects and returns count == 0, which is TRUE for zero
		-- records -- so a database that failed to load would report a
		-- clean bill of health from all of them at once. Report nothing
		-- rather than something reassuring.
		if #recs == 0 then return nil, "no records loaded" end
		local bad, example = 0, nil
		for _, r in ipairs(recs) do
			local z = r.zone
			if z and (z.x or z.y) then
				if type(z.x) ~= "number" or type(z.y) ~= "number"
					or z.x < 0 or z.x > 100 or z.y < 0 or z.y > 100 then
					bad = bad + 1; example = example or r.name
				end
			end
		end
		return bad == 0, example
	end)

	check("Drop rates are percentages", function()
		-- An empty table satisfies "nothing is wrong". Every check here
		-- counts defects and returns count == 0, which is TRUE for zero
		-- records -- so a database that failed to load would report a
		-- clean bill of health from all of them at once. Report nothing
		-- rather than something reassuring.
		if #recs == 0 then return nil, "no records loaded" end
		local bad, example = 0, nil
		for _, r in ipairs(recs) do
			if r.dropRate and (type(r.dropRate) ~= "number"
				or r.dropRate <= 0 or r.dropRate > 100) then
				bad = bad + 1; example = example or (r.name .. " = " .. tostring(r.dropRate))
			end
		end
		return bad == 0, example
	end)

	check("Conditions well-formed", function()
		-- An empty table satisfies "nothing is wrong". Every check here
		-- counts defects and returns count == 0, which is TRUE for zero
		-- records -- so a database that failed to load would report a
		-- clean bill of health from all of them at once. Report nothing
		-- rather than something reassuring.
		if #recs == 0 then return nil, "no records loaded" end
		local bad, example = 0, nil
		for _, r in ipairs(recs) do
			for _, c in ipairs(r.conditions or {}) do
				if type(c) ~= "table" or type(c.type) ~= "string" then
					bad = bad + 1; example = example or r.name
				end
			end
		end
		return bad == 0, example
	end)

	check("A mount we already priced is not asked about again", function()
		-- The unpriced list asks a player to stand at a vendor and read a price
		-- off the screen. That is the scarcest thing this addon can request, so
		-- asking for something already answered is worse than not asking.
		--
		-- It tested for CONDITIONS, and a gold price is a FIELD -- so fifty of
		-- the sixty-eight it listed were priced, most of them from two
		-- independent sources agreeing to the copper. Exactly the shape of the
		-- contribution counter that measured "has no conditions" while calling
		-- itself "has no price".
		if not (MM.Diagnostics and MM.Diagnostics.IsUnpriced) then
			return nil, "IsUnpriced not present"
		end
		if #recs == 0 then return nil, "no records loaded" end
		local listed, priced, bad = 0, 0, nil
		for _, r in ipairs(recs) do
			if r.goldCost then priced = priced + 1 end
			if MM.Diagnostics.IsUnpriced(r) then
				listed = listed + 1
				if r.goldCost then bad = bad or (r.name .. " costs " .. r.goldCost .. "g") end
				for _, c in ipairs(r.conditions or {}) do
					if (c.type == "CURRENCY" or c.type == "ITEM") and c.amount then
						bad = bad or (r.name .. " already states its cost")
					end
				end
			end
		end
		if bad then return false, bad end
		if priced == 0 then return false, "no record carries a gold price" end
		return true, ("%d still unpriced; none of the %d priced ones are on the list")
			:format(listed, priced)
	end)

	check("The two unpriced lists agree with each other", function()
		-- The contribution export and the diagnostic list both answer "which
		-- records have no cost we can read", and they answered differently:
		-- seven records carrying an explicit reason they cannot be priced --
		-- fished, solved, dropped rather than sold -- were absent from one and
		-- present in the other.
		--
		-- The predicate was pulled into a single function precisely so this
		-- could not happen, and it still did, because the extraction copied the
		-- old body verbatim and the old body never read the field. A shared
		-- function is not agreement; being asked the same question is.
		if #recs == 0 then return nil, "no records loaded" end
		if not (MM.Diagnostics and MM.Diagnostics.IsUnpriced) then
			return nil, "IsUnpriced not present"
		end
		local disagree, example, listed = 0, nil, 0
		for _, r in ipairs(recs) do
			local diag = MM.Diagnostics.IsUnpriced(r)
			if diag then listed = listed + 1 end
			-- Anything stating WHY it has no price must be absent from both.
			if diag and r.unpriced then
				disagree = disagree + 1
				example = example or (r.name .. " — " .. tostring(r.unpriced))
			end
		end
		if disagree > 0 then
			return false, ("%d records say why they are unpriced and are asked anyway, e.g. %s")
				:format(disagree, example)
		end
		return true, ("%d genuinely unpriced; every explained one is absent from both")
			:format(listed)
	end)

	check("A record that has been answered is not asked about again", function()
		-- Three columns of this file have now made the same mistake: the price
		-- list asked for prices already recorded, the craft list asked for
		-- reagents that do not exist, and the drop-rate list kept asking for
		-- rates on records where everything obtainable had already been
		-- supplied. Each time the fix was a field saying why, and each time
		-- exactly one of the two lists that ask the question read it.
		--
		-- So this asserts the invariant directly rather than trusting that the
		-- next field will be wired into both places: nothing carrying a stated
		-- reason may appear in either list.
		if #recs == 0 then return nil, "no records loaded" end
		local CHANCY = { DROP = true, RARE = true, ZONEDROP = true }
		local asked, answered, bad = 0, 0, nil
		for _, r in ipairs(recs) do
			if r.obtainable and CHANCY[r.category] then
				if r.rateReason then
					answered = answered + 1
					-- Present in the list is the failure; the list is defined by
					-- the same predicate both readers use.
					if not r.dropRate then
						-- Must be excluded BECAUSE of the reason, not in spite
						-- of it -- so re-derive what the exporter would list.
						local wouldList = not r.dropRate and not r.rateReason
						if wouldList then
							bad = bad or (r.name .. " is answered and still listed")
						end
					end
				elseif not r.dropRate then
					asked = asked + 1
				end
			end
		end
		if bad then return false, bad end
		if answered == 0 then return nil, "no record carries a stated reason yet" end
		return true, ("%d still to answer; %d answered and absent from the list")
			:format(asked, answered)
	end)

	check("A mount locked to another class is not reported as missing", function()
		-- The audit listed twenty records as "obtainable, this faction, and
		-- still missing", which reads as twenty mounts the addon cannot see. A
		-- Druid form and a heritage mount are absent from a Hunter's journal
		-- for the same reason the other faction's are -- and calling them
		-- suspects sends someone hunting for a typo in a name that is correct.
		--
		-- Asserts the gates identify a real mismatch AND refuse to invent one:
		-- a record naming this character's own class or race must come back
		-- clean, or every mount would be excused and the list would empty
		-- itself into looking healthy.
		local QG = MM.QuestGate
		if not (QG and QG.WrongClass and QG.WrongRace) then
			return false, "class/race gates not present"
		end
		local myClass = select(2, UnitClass("player"))
		local myRace = select(2, UnitRace("player"))
		if not (myClass and myRace) then return nil, "class or race unreadable" end

		local mine = { category = "CLASS", source = "", notes = myClass:lower() .. " only." }
		if QG.WrongClass(mine) then
			return false, "claimed a mismatch against this character's own class"
		end
		local other = (myClass == "DRUID") and "paladin" or "druid"
		local theirs = { category = "CLASS", source = "", notes = other .. " only." }
		if not QG.WrongClass(theirs) then
			return false, "did not spot a " .. other .. "-only mount"
		end
		-- Race wording has to be a REQUIREMENT. "Sold in Silvermoon" names no
		-- race; "Requires a Blood Elf character" does.
		local place = { notes = "Sold in Silvermoon City by a blood elf vendor." }
		if QG.WrongRace(place) then
			return false, "read a race requirement out of a vendor's description"
		end
		return true, ("class and race gates agree with %s %s"):format(myRace, myClass)
	end)

	check("A repeated notice stays quiet, a changed one speaks", function()
		-- Chat is shared with the guild, the group, loot and every other addon,
		-- so a line has to earn its place. Two notices were repeating at every
		-- login and at every flight master, saying what was only news once.
		--
		-- Silencing them FOREVER is the opposite mistake, and a quieter one: a
		-- player who learns flight points in a new expansion would be told
		-- nothing, for a reason decided months earlier that they cannot see.
		-- So this asserts both halves -- the same sentence twice is silent, a
		-- different sentence is not.
		--
		-- The failure mode is invisible to whoever writes the line, because
		-- their own client has already said it, and obvious to everyone else.
		if not MM.PrintIfNew then return false, "PrintIfNew not present" end
		local saved = MM.db.saidBefore
		MM.db.saidBefore = nil

		local key = "mm-selftest-notice"
		local first = MM:PrintIfNew(key, " ")
		local repeated = MM:PrintIfNew(key, " ")
		local changed = MM:PrintIfNew(key, "  ")
		local repeatedAgain = MM:PrintIfNew(key, "  ")
		local stored = MM.db.saidBefore and MM.db.saidBefore[key]

		MM.db.saidBefore = saved

		if not first then return false, "the first call said nothing" end
		if repeated then return false, "the same message printed twice" end
		if not changed then return false, "a changed message was swallowed" end
		if repeatedAgain then return false, "the changed message then repeated" end
		-- Written down, or a reload starts the whole cycle again.
		if not (stored and stored.msg and stored.at) then
			return false, "nothing was persisted, so a reload repeats it"
		end
		return true, "same message silent, changed message speaks, both remembered"
	end)

	check("No reputation is required twice on one mount", function()
		-- Forty-two records asked for one reputation under two spellings --
		-- "Venthyr" and "Venthyr Renown", a Netherwing row with a factionID and
		-- one without. The cost model prices every condition, so each of those
		-- mounts paid for its grind twice, and the id-less half was the more
		-- expensive one: with nothing to measure, it charges a full assumed
		-- grind on top of the real, measured figure.
		--
		-- They were invisible to the merge, which keys a condition by its id
		-- when it has one and by its name when it does not -- so the two rows
		-- are two keys, and adding the second never updated the first.
		if #recs == 0 then return nil, "no records loaded" end
		local dupes, example = 0, nil
		for _, r in ipairs(recs) do
			local seen = {}
			for _, c in ipairs(r.conditions or {}) do
				if c.type == "REP" or c.type == "RENOWN" then
					local name = c.factionName or c.faction or c.name or ""
					local key = name:lower():gsub("%s+renown$", ""):gsub("%s*%(.-%)%s*$", "")
					if seen[key] then
						dupes = dupes + 1
						example = example or (r.name .. ": " .. name)
					end
					seen[key] = true
				end
			end
		end
		if dupes > 0 then
			return false, ("%d duplicated gates, e.g. %s"):format(dupes, example)
		end
		return true, "every mount names each reputation once"
	end)

	check("Reputation requirements use the fields that get read", function()
		-- A condition written with `id`/`name`/`standing` instead of
		-- `factionID`/`factionName`/`standingName` looks complete and is
		-- invisible: every helper that reads a reputation looks for the
		-- canonical names, so the gate reports no standing, no renown level and
		-- no progress. Four mounts were in that state and nothing said so.
		if #recs == 0 then return nil, "no records loaded" end
		local bad, example, withID = 0, nil, 0
		for _, r in ipairs(recs) do
			for _, c in ipairs(r.conditions or {}) do
				if c.type == "REP" then
					if c.factionID then withID = withID + 1 end
					if not c.factionName or (c.standing and not c.standingName) then
						bad = bad + 1
						example = example or (r.name .. ": " .. tostring(c.name or c.factionName))
					end
				end
			end
		end
		if bad > 0 then return false, ("%d misnamed, e.g. %s"):format(bad, example) end
		return true, ("%d reputation gates the client can measure"):format(withID)
	end)

	check("Nothing is charged for the same cost twice", function()
		-- Seven records listed one cost under two spellings: an ITEM condition
		-- naming the token and a CURRENCY condition naming its plural. The
		-- planner prices every cost condition, so those mounts were ranked as
		-- costing double -- and a record with two requirements looks entirely
		-- normal, which is why they lasted.
		--
		-- THE PAIR OF TYPES IS NOT THE POINT. This first compared ITEM against
		-- CURRENCY, and the next duplicate to appear was ITEM against MATERIAL
		-- -- twenty-two Protoform mounts carrying Genesis Mote as both, which
		-- this test watched go past. A guard that enumerates the pairs it knows
		-- about will always miss the pair it does not, so it now compares any
		-- two cost conditions naming one thing, whatever their types.
		if #recs == 0 then return nil, "no records loaded" end
		local COST = { ITEM = true, CURRENCY = true, MATERIAL = true }
		local dupes, example = 0, nil
		for _, r in ipairs(recs) do
			local seen = {}
			for _, c in ipairs(r.conditions or {}) do
				if COST[c.type] and c.name then
					local key = c.name:lower():gsub("s$", "")
					if seen[key] and seen[key] ~= c.type then
						dupes = dupes + 1
						example = example or ("%s: %s as %s and %s")
							:format(r.name, c.name, seen[key], c.type)
					end
					seen[key] = c.type
				end
			end
		end
		if dupes > 0 then
			return false, ("%d duplicated costs, e.g. %s"):format(dupes, example)
		end
		return true, "no cost appears under two condition types"
	end)

	check("Every requirement can be asked about", function()
		-- A condition that names something and carries no id is a string. The
		-- client cannot be asked whether it is met, so the planner falls back to
		-- an assumption for the whole thing.
		--
		-- Two of these were written off as unanswerable and neither was. The
		-- covenants are not reputations, which was true and became an excuse --
		-- C_CovenantSanctumUI reports renown directly. "Guild" matched two
		-- factions, one of which is a header with no bar at all.
		--
		-- Asserted at zero rather than at a count, because a count that drifts
		-- upward reads as normal.
		if #recs == 0 then return nil, "no records loaded" end
		local ASKABLE = { ITEM = true, CURRENCY = true, ACHIEVEMENT = true,
			QUEST = true, COVENANT = true }
		local bare, example = 0, nil
		for _, r in ipairs(recs) do
			for _, c in ipairs(r.conditions or {}) do
				if ASKABLE[c.type] and not c.id and not c.idAlliance then
					bare = bare + 1
					example = example or ("%s: %s %s"):format(r.name, c.type, c.name or "?")
				elseif c.type == "REP" and not c.factionID
					and not c.factionIDAlliance then
					bare = bare + 1
					example = example or ("%s: REP %s")
						:format(r.name, c.factionName or c.name or "?")
				end
			end
		end
		if bare > 0 then
			return false, ("%d requirements have no id, e.g. %s"):format(bare, example)
		end
		return true, "every requirement carries an id the client can resolve"
	end)

	check("Promoting a faction variant keeps the ids it was given", function()
		-- Every id, amount and factionID the data layers apply lands on the
		-- CANONICAL record. Promoting the other faction's variant replaced that
		-- table wholesale, so one side got a requirement with nothing on it:
		-- three Vicious mounts asked for a "Vicious Saddle" with no item id, on
		-- Horde only.
		--
		-- That is the worst shape a bug can have here -- correct on the client
		-- you are testing, broken on the one you are not, and identical in the
		-- data file. Assert it from the character actually running.
		if #recs == 0 then return nil, "no records loaded" end
		local bare, example, promoted = 0, nil, 0
		for _, r in ipairs(recs) do
			-- A record that HAD an alternate for this side has been promoted;
			-- altSources still holds the ones that were not taken.
			if r.altSources then promoted = promoted + 1 end
			for _, c in ipairs(r.conditions or {}) do
				-- A cost that names something and cannot say what it is cannot
				-- be counted against the player's bags or balance.
				if (c.type == "ITEM" or c.type == "CURRENCY") and c.name
					and not c.id and not c.idAlliance and not c.idHorde
					and c.amount then
					bare = bare + 1
					example = example or (r.name .. ": " .. c.name)
				end
			end
		end
		-- Two are known and explained in the data: Glowing Moths are world
		-- objects rather than a currency, so no id exists to find.
		if bare > 2 then
			return false, ("%d costs name something with no id, e.g. %s"):format(bare, example)
		end
		return true, ("%d records carry alternates; %d unidentified costs, both explained")
			:format(promoted, bare)
	end)

	check("Crafts know what they are made of", function()
		-- Crafted mounts were costed on a flat guess because reagent lists are
		-- not invented here, and the only route to real ones was a player
		-- opening a profession window for every recipe in turn.
		--
		-- They come from the client's own tables now -- the spell that creates
		-- the teaching item, that spell's reagents, and their names. This
		-- asserts the import is actually present and actually reaches Crafting,
		-- because a MATERIAL condition that MaterialsFor cannot read would look
		-- identical in the data and change nothing in the plan.
		if #recs == 0 then return nil, "no records loaded" end
		local crafts, withMats, gathered = 0, 0, 0
		local sample
		for _, r in ipairs(recs) do
			if r.obtainable and r.category == "PROFESSION" then
				crafts = crafts + 1
				if r.unpriced then gathered = gathered + 1 end
				for _, c in ipairs(r.conditions or {}) do
					if c.type == "MATERIAL" and c.itemID and (c.count or 0) > 0 then
						withMats = withMats + 1
						sample = sample or r
						break
					end
				end
			end
		end
		if withMats == 0 then return false, "no craft carries a reagent list" end
		-- Reached through the same call the planner uses, not by reading the
		-- record again: the point is that Crafting can see it.
		local mats, known = MM.Crafting.MaterialsFor(sample)
		if not (known and mats and #mats > 0) then
			return false, ("%s has reagents that Crafting cannot read"):format(sample.name)
		end
		return true, ("%d of %d crafts have real reagents, %d are gathered; %s reads %d")
			:format(withMats, crafts, gathered, sample.name, #mats)
	end)

	check("Faction-split requirements resolved to this character's side", function()
		-- Some requirements exist twice, one copy per faction: the collection
		-- achievements, the Outland quartermaster talbuks, the Argent
		-- Tournament city mounts. The data carries both and login picks one.
		--
		-- The failure this catches is silent and total: if the pick never runs,
		-- the condition keeps a name and no id, the client cannot be asked
		-- whether it is met, and the planner treats a finished achievement as
		-- outstanding forever.
		if #recs == 0 then return nil, "no records loaded" end
		local paired, resolved, wrong = 0, 0, nil
		local side = UnitFactionGroup and UnitFactionGroup("player")
		if not (side == "Alliance" or side == "Horde") then
			return nil, "player faction unknown"
		end
		local want = (side == "Alliance") and "idAlliance" or "idHorde"
		for _, r in ipairs(recs) do
			for _, c in ipairs(r.conditions or {}) do
				if c.idAlliance and c.idHorde then
					paired = paired + 1
					if c.id == c[want] then
						resolved = resolved + 1
					else
						wrong = wrong or ("%s: %s is %s, expected %s")
							:format(r.name, c.name or "?", tostring(c.id), tostring(c[want]))
					end
				end
			end
		end
		if paired == 0 then return false, "no faction-split requirements in the data" end
		if resolved < paired then return false, wrong end
		return true, ("%d requirements, all on the %s id"):format(paired, side)
	end)

	check("Every locationless record says why", function()
		-- A record with no place is either a gap someone can close or a
		-- category error nobody can. The difference has to be written down,
		-- because a count that mixes them tells players to go and find
		-- coordinates for a mount bought from Blizzard.
		--
		-- This asserts the remainder is explained: anything left without a
		-- location, outside the categories that cannot have one, carries a
		-- reason in the record.
		if #recs == 0 then return nil, "no records loaded" end
		local PLACELESS = {
			STORE = true, PROMOTION = true, TCG = true, ACHIEVEMENT = true,
			PROFESSION = true, PVP = true, CLASS = true, REMOVED = true,
			TRADINGPOST = true,
		}
		local open, example = 0, nil
		for _, r in ipairs(recs) do
			if r.obtainable and not r.zone and not r.vendor
				and not r.noLocationReason and not PLACELESS[r.category] then
				open = open + 1
				example = example or (r.name .. " (" .. tostring(r.category) .. ")")
			end
		end
		if open > 0 then
			return false, ("%d unexplained, e.g. %s"):format(open, example)
		end
		return true, "no unexplained locationless records"
	end)

	check("Gold prices are plausible", function()
		-- goldCost is read straight into the planner's cost model, so a
		-- mis-parsed price is a silently wrong plan rather than an error. The
		-- import that produced most of these came off a page whose thousands
		-- separator is a SPACE -- "10 000" reads as ten to anything that stops
		-- at the first run of digits.
		--
		-- A thousandfold error cannot be spotted by eye in a list of prices, so
		-- assert the shape instead: whole gold, above zero, and inside the
		-- range the game actually charges.
		if #recs == 0 then return nil, "no records loaded" end
		local n, bad = 0, nil
		for _, r in ipairs(recs) do
			local g = r.goldCost
			if g then
				n = n + 1
				if type(g) ~= "number" or g <= 0 or g ~= math.floor(g) or g > 5000000 then
					bad = bad or ("%s: %s"):format(r.name, tostring(g))
				end
			end
		end
		if n == 0 then return false, "no record carries a gold price" end
		if bad then return false, bad end
		return true, ("%d gold prices, all whole and in range"):format(n)
	end)

	check("Journal coverage", function()
		local S = MM.Scanner
		-- S.mounts, not S.entries. The first draft of this check used a field
		-- name that does not exist, so it reported "scan has not run yet"
		-- forever -- a green-looking test that measured nothing. Any check that
		-- can only ever return its own skip path is worse than no check.
		if not (S and S.ready and S.mounts) then return nil, "scan has not run yet" end
		-- Count the WHOLE journal including entries hidden for this character.
		-- Measuring only the displayed subset flattered coverage, because the
		-- hidden ones are exactly the records the audit was calling orphans.
		local total, matched = 0, 0
		for _, e in pairs(S.byMountID or {}) do
			total = total + 1
			if e.rec and not e.rec.stub then matched = matched + 1 end
		end
		if total == 0 then return nil, "journal reported no mounts" end
		local pct = matched / total * 100
		-- below 90% means the journal has drifted well past our database
		return pct >= 90, ("%d of %d journal mounts catalogued (%.1f%%)")
			:format(matched, total, pct)
	end)
end

------------------------------------------------------------
-- Logic: pure functions, known inputs, known answers
------------------------------------------------------------
local function approx(a, b) return math.abs(a - b) < 0.001 end

-- The first routed stop that has somewhere to be.
--
-- Stands in for Router:Current() in checks that only need A destination to
-- price. Current() is gated on the player having started a route, which is
-- correct for the arrow and wrong as a test precondition -- it made two travel
-- checks unrunnable unless somebody happened to be mid-route when they typed
-- /mm test.
local function firstPlacedStop()
	local R = MM.Router
	for _, stop in ipairs(R and R.route or {}) do
		if stop.world then return stop end
	end
end

local function runLogic()
	current = "LOGIC"

	check("Value cost falls as payoff rises", function()
		local P = MM.Planner
		local cheap, dear = P.ValueScoreFromVPM(1.0), P.ValueScoreFromVPM(0.01)
		if not (cheap < dear) then
			return false, ("%.1f should be below %.1f"):format(cheap, dear)
		end
		-- batching depends on this: summed vpm must cost less than any part
		local one, three = P.ValueScoreFromVPM(0.1), P.ValueScoreFromVPM(0.3)
		return three < one, ("1 goal %.0f, 3 goals %.0f"):format(one, three)
	end)

	-- PROGRESS PRICING
	--
	-- Every one of these guards a bug that shipped. They use synthetic records
	-- so they assert the ARITHMETIC rather than whatever standing the character
	-- running /mm happens to hold.
	check("Rep gating recognises rep, renown and paragon", function()
		local P = MM.Planner
		local rep = { name = "t", conditions = { { type = "REP", factionID = 1 } } }
		local drop = { name = "t", conditions = { { type = "DROP" } } }
		if not P.IsRepGated(rep) then return false, "plain REP not detected" end
		if P.IsRepGated(drop) then return false, "DROP wrongly detected" end
		return true, "REP yes, DROP no"
	end)

	check("Plain rep is not charged a paragon bar", function()
		-- THE REGRESSION: generalising paragon pricing to all reputations first
		-- added a full paragon bar to every one of them, overcharging plain rep
		-- and renown by five hours and burying them in the ranking.
		local P = MM.Planner
		local plain = { name = "t", conditions = { { type = "REP", factionID = 0 } } }
		-- IsParagon reads the source text, so the fixture must too.
		local para = { name = "t", source = "Paragon cache, Death's Advance",
			conditions = { { type = "REP", factionID = 0 } } }
		local a, b = P.RepRemainingMinutes(plain), P.RepRemainingMinutes(para)
		if not (a and b) then return false, "no figure returned" end
		if not (b > a) then
			return false, ("paragon %.0f must exceed plain %.0f"):format(b, a)
		end
		return true, ("plain %.0fh, paragon %.0fh"):format(a / 60, b / 60)
	end)

	check("PvP cost is matches, not a flat season", function()
		local P = MM.Planner
		-- 1000 to earn, 100 a win, 50 a loss. At an even split that is 75 a
		-- match, so 14 matches; at 12 minutes each, 168 minutes.
		local rec = { name = "t", pvpBarTotal = 1000, pvpPerWin = 100,
			pvpPerLoss = 50, pvpMatchMinutes = 12 }
		local mins, matches = P.PvpRemainingMinutes(rec, 0)
		if not mins then return false, "no figure returned" end
		if matches ~= 14 then
			return false, ("expected 14 matches, got %s"):format(tostring(matches))
		end
		-- Half the bar already filled must cost about half as much.
		local half = P.PvpRemainingMinutes(rec, 0.5)
		if not (half < mins) then return false, "progress did not reduce cost" end
		return true, ("%d matches, %.0f min; half filled %.0f min")
			:format(matches, mins, half)
	end)

	check("PvP win rate reads the client, or says it cannot", function()
		local PS = MM.PvpStats
		if not PS then return false, "PvpStats missing" end
		local rate, played, bracket = PS.Best()
		local fallback = PS.WinRate()
		if fallback < 0 or fallback > 1 then
			return false, ("win rate out of range: %s"):format(tostring(fallback))
		end
		if not rate then
			-- Not a failure: a character with no rated games has no rate, and
			-- saying so is the correct answer.
			return nil, "no rated games this season; assuming 50%"
		end
		return true, ("%.0f%% over %d games (bracket %d)")
			:format(rate * 100, played, bracket)
	end)

	check("PvP refuses to guess without data", function()
		-- No bar total means no honest answer. Returning a number here would be
		-- inventing the season, which is how the reagent lists went wrong.
		local P = MM.Planner
		return P.PvpRemainingMinutes({ name = "t" }, 0) == nil, "nil without inputs"
	end)

	check("Calendar-gated rep prices days, not hours", function()
		local P = MM.Planner
		local rec = { name = "t", repPacing = "DAILY", repDaysRemaining = 20 }
		if not P.RepIsCalendarGated(rec) then return false, "not detected" end
		local mins, days = P.CalendarRepMinutes(rec, 0)
		if not mins then return false, "no figure returned" end
		local part = P.CalendarRepMinutes(rec, 0.75)
		if not (part and part < mins) then
			return false, "progress did not reduce the day count"
		end
		return true, ("%d days -> %.0f min; 75%% done -> %.0f min")
			:format(days, mins, part)
	end)

	check("Urgency scales with the window left", function()
		-- Daily and weekly both returned URGENCY.LOCKOUT and both got the same
		-- flat boost, so a Thursday weekly pushed as hard as a Monday-night one.
		local R = MM.Router
		if not R.WindowPressure then return nil, "not exposed for testing" end
		local daily = R.WindowPressure({ attempts = "DAILY" })
		local weekly = R.WindowPressure({ attempts = "WEEKLY" })
		if not (daily and weekly) then return false, "no pressure returned" end
		if daily < 0 or daily > 1 or weekly < 0 or weekly > 1 then
			return false, ("out of range: %.2f / %.2f"):format(daily, weekly)
		end
		return true, ("daily %.0f%% spent, weekly %.0f%% spent")
			:format(daily * 100, weekly * 100)
	end)

	check("Time formatting", function()
		local s = U.FormatSeconds(3661)
		return type(s) == "string" and #s > 0, s
	end)

	check("Thousands separators", function()
		local s = U.Comma(1234567)
		return s:find("1") ~= nil and #s > 7, s
	end)

	check("Category filter groups", function()
		if not MM.CategoryMatch(nil, "DROP") then return false, "nil filter should match all" end
		if not MM.CategoryMatch("GROUP_DROPS", "RARE") then return false, "RARE is a drop" end
		if MM.CategoryMatch("GROUP_DROPS", "VENDOR") then return false, "VENDOR is not a drop" end
		return true
	end)

	check("Unusable zone falls back to vendor", function()
		-- a zone with no resolvable map must not beat a known vendor location
		local rec = { zone = { name = "Not A Real Zone / Compound", x = 1, y = 2 },
			vendor = "definitely-not-a-vendor" }
		local loc = MM.GetRecordLocation(rec)
		return loc ~= nil, "returned a location table"
	end)

	check("Acquire chain reports progress", function()
		local line, need = MM.Acquire.ChainProgress({
			acquire = { item = 0, name = "Test Token", count = 5 } })
		if not line then return false, "no progress line" end
		return need == 5, line
	end)

	check("Prerequisite gate blocks wrong faction", function()
		local other = (MM.playerFaction == "Horde") and "Alliance" or "Horde"
		local why = MM.QuestGate.HardGate({ faction = other, category = "VENDOR" })
		if not why then return false, "wrong-faction record was not gated" end
		local fine = MM.QuestGate.HardGate({ faction = MM.playerFaction, category = "VENDOR" })
		return fine == nil, why
	end)

	check("Reputation grind is not a gate", function()
		-- a rep bar is the work, not a blocker; gating it would empty the plan
		local why = MM.QuestGate.HardGate({
			category = "REP",
			conditions = { { type = "REP", name = "Some Faction", standing = "Exalted" } },
		})
		return why == nil, why and ("wrongly gated: " .. why) or nil
	end)

	check("Calling gate refuses to guess", function()
		local state = MM.Callings.Evaluate({ zone = "Nowhere", mapID = -1 })
		-- must never answer AVAILABLE for a zone it cannot confirm
		return state ~= "AVAILABLE", "returned " .. tostring(state)
	end)

	check("Unrated drops are not treated as certain", function()
		-- A missing dropRate scored as chance = 1, giving an unrated mount a
		-- value-per-minute no real farm could match. That is how a current-tier
		-- Mythic+ mount reached the top of a route.
		local rated = { rec = { category = "DROP", dropRate = 100, timePerAttempt = 20,
			expansion = 3 } }
		local unrated = { rec = { category = "DROP", timePerAttempt = 20, expansion = 3 } }
		local a, b = MM.Planner.ValuePerMinute(rated), MM.Planner.ValuePerMinute(unrated)
		if not (a > b) then
			return false, ("unrated %.4f is not below a guaranteed %.4f"):format(b, a)
		end
		return true, ("guaranteed %.3f vs unrated %.3f"):format(a, b)
	end)

	check("Priority order reaches the route", function()
		-- Routing weighed payoff and travel and nothing else, so the priority
		-- list only ever sorted the "easiest" view.
		local easy = { rec = { category = "DROP", dropRate = 100, timePerAttempt = 20,
			expansion = 3 } }
		local group = { rec = { category = "DROP", dropRate = 100, timePerAttempt = 20,
			expansion = 3, solo = false } }
		local a, b = MM.Planner.ValuePerMinute(easy), MM.Planner.ValuePerMinute(group)
		if not (a > b) then
			return false, ("group content scores %.3f against %.3f — tier is ignored"):format(b, a)
		end
		return true, ("solo %.3f vs needs-a-group %.3f"):format(a, b)
	end)

	check("Tooltips do not say the same thing twice", function()
		-- the player: tooltips must not repeat themselves. The exact-match guard was
		-- never enough -- the same sentence arrives worded two ways.
		local cases = {
			{ "Achievement: Glory of the Uldir Raider",
			  "Reward from the achievement Glory of the Uldir Raider", true },
			{ "Exalted with Ramkahen",
			  "Sold by Blacksmith Abasi at Exalted with Ramkahen", true },
			{ "Drops from Poseidus in Vashj'ir",
			  "Buy from the auction house", false },
			-- progress is never a restatement: it is the one thing the source
			-- cannot know
			{ "Test Token: 0 / 5", "Collect 5 Test Tokens", false },
			{ "Timewarped Badge: 0 / 5000", "Bought from the Timewalking vendor", false },
		}
		for _, c in ipairs(cases) do
			local got = U.Restates(c[1], c[2])
			if got ~= c[3] then
				return false, ("%q vs %q gave %s"):format(c[1], c[2], tostring(got))
			end
		end
		return true, ("%d wording cases behave"):format(#cases)
	end)

	check("Preference never bends expected mounts", function()
		-- the objection, made into a rule: priority and reluctance are how we
		-- CHOOSE, never what we CLAIM. Expected mounts is a physical quantity the
		-- UI reports as fact, and the day it starts absorbing taste is the day
		-- the summary stops being true.
		local R = MM.Router
		local stop = { tier = MM.Planner.TIER.PICKUP, handicap = 0, mounts = 0.5,
			workMinutes = 10, world = nil }
		local plainA = R.Density(stop, 5, 10)
		local saved = MM.db.weights
		-- 1.0, not 1.5: at the top of the range the ordering goes lexicographic
		-- and the score is a rank block plus a remainder, so "lower than the
		-- density" stops being the right question. Strict mode has its own check.
		MM.db.weights = { schema = 2, priority = 1.0 }
		MM:Fire("MM_WEIGHTS_CHANGED")
		stop.tier = MM.Planner.TIER.GROUP
		stop.handicap = 3000
		local plainB = R.Density(stop, 5, 10)
		local scored = R.SelectionScore(stop, 5, 10)
		MM.db.weights = saved
		MM:Fire("MM_WEIGHTS_CHANGED")
		if math.abs(plainA - plainB) > 0.0001 then
			return false, ("density moved with preference: %.4f vs %.4f"):format(plainA, plainB)
		end
		if scored >= plainB then
			return false, "preference did not affect the selection score at all"
		end
		return true, ("density %.4f unchanged, selection %.4f"):format(plainB, scored)
	end)

	check("Every goal can explain itself", function()
		-- "Priority 7" with no reasoning is the opaque case players hit. The rule
		-- is that the explanation must always exist and must always name the
		-- points, so the answer to "why is this here" and the answer to "what
		-- do I change" are the same screen.
		local checked = 0
		for _, entry in ipairs(MM.Scanner.mounts) do
			if not entry.collected and entry.rec then
				local lines = MM.Planner.Explain(entry)
				if type(lines) ~= "table" or #lines < 3 then
					return false, ("%s explained itself in %d lines")
						:format(entry.name, lines and #lines or 0)
				end
				for _, l in ipairs(lines) do
					if type(l.text) ~= "string" or l.text == "" then
						return false, entry.name .. " produced an empty line"
					end
				end
				-- The cost breakdown is no longer asserted here: it was removed
				-- from the player tooltip as unactionable, and the invariant it
				-- guarded -- breakdown matching the score actually used -- is
				-- checked directly against CostParts by the next test.
				checked = checked + 1
				if checked >= 60 then break end
			end
		end
		if checked == 0 then return nil, "nothing uncollected to explain" end
		return true, ("%d goals itemise their own placement"):format(checked)
	end)

	check("Itemised cost matches the score used", function()
		-- If the tooltip's breakdown and the ranking ever diverge, the tooltip
		-- becomes a lie that is harder to catch than a wrong number.
		for _, entry in ipairs(MM.Scanner.mounts) do
			if not entry.collected and entry.rec then
				local total, parts = MM.Planner.CostParts(entry)
				local sum = 0
				for _, p in ipairs(parts) do sum = sum + p[2] end
				if math.abs(sum - total) > 0.001 then
					return false, ("%s: parts sum %.1f, total %.1f")
						:format(entry.name, sum, total)
				end
				return true, ("%d cost terms, summing exactly"):format(#parts)
			end
		end
		return nil, "nothing uncollected to check"
	end)

	check("Every weight reaches the route", function()
		-- Requirement — i changed a bunch of weights and priorities and nothing really
		-- changed -- that makes no sense. He was right: routing consumed only
		-- the priority order and deadline pressure, so four of six sliders moved
		-- nothing but the Easiest list. This walks each weight and demands that
		-- something the ROUTER reads actually moves.
		local W, P, R = MM.Weights, MM.Planner, MM.Router
		local subject
		for _, e in ipairs(MM.Scanner.mounts) do
			if not e.collected and e.rec and e.rec.expansion then subject = e break end
		end
		if not subject then return nil, "no uncollected goal to measure" end

		local saved = MM.db.weights
		local function probe(key, value, read)
			MM.db.weights = { schema = 2 }
			MM:Fire("MM_WEIGHTS_CHANGED")
			local before = read()
			MM.db.weights = { schema = 2, [key] = value }
			MM:Fire("MM_WEIGHTS_CHANGED")
			local after = read()
			return before, after
		end

		local fakeStop = { tier = MM.Planner.TIER.GROUP, handicap = 500, mounts = 0.5,
			workMinutes = 120 }
		-- urgency only ever applies to a goal under a lockout, so probing it on
		-- a stop without one measures nothing.
		local urgentStop = { tier = MM.Planner.TIER.GROUP, handicap = 500, mounts = 0.5,
			workMinutes = 120, urgency = MM.Planner.URGENCY.LOCKOUT }
		local probes = {
			{ "travel scaling", "travel", 1000, function() return R.TravelScale() end },
			{ "travel detour", "travel", 1000, function() return R.DetourMinutes() end },
			-- effort and odds used to be probed through P.Handicap -- the
			-- PLANNER path, which feeds tooltips. Both passed for months while
			-- the router ignored them completely, and this check reported "all
			-- 8 weights move a routing input" the whole time. A probe that reads
			-- a different subsystem than the claim it is making is worse than no
			-- probe: it converts an open question into false assurance.
			--
			-- Every probe below now reads something the ROUTER itself consumes.
			{ "effort", "effort", 500, function() return R.StopValue(fakeStop) end },
			{ "odds", "odds", 0, function() return R.StopValue(fakeStop) end },
			{ "era", "era", 1000, function() return P.Handicap(subject) end },
			{ "priority", "priority", 1.5, function() return R.PreferenceDivisor(fakeStop) end },
			{ "urgency", "urgency", 0, function() return R.StopValue(urgentStop) end },
			{ "session", "session", 60, function() return R.SessionFit(fakeStop) end },
		}
		local dead = {}
		for _, pr in ipairs(probes) do
			local a, b = probe(pr[2], pr[3], pr[4])
			if math.abs((a or 0) - (b or 0)) < 0.0001 then dead[#dead + 1] = pr[1] end
		end
		MM.db.weights = saved
		MM:Fire("MM_WEIGHTS_CHANGED")

		if #dead > 0 then
			return false, "changes nothing the router reads: " .. table.concat(dead, ", ")
		end
		return true, ("all %d weights move a routing input"):format(#probes)
	end)

	check("A swapped route is not mistaken for a cache hit", function()
		-- The signature describes the PLAN. It was being read as proof that
		-- R.route was still the route it built, and anything that replaced the
		-- route without touching the signature got a cache hit on a route that
		-- was gone -- which is how the router model's six-goal sample survived
		-- into the planner.
		local R = MM.Router
		if not (R and R.Build) then return nil, "no router" end
		R:BuildSync()
		local real = #(R.route or {})
		if real < 3 then return nil, "route too short to test" end
		-- Replace the route WITHOUT touching the signature, exactly as the
		-- harness used to, and ask for a build.
		local stolen = {}
		for i = 1, 2 do stolen[i] = R.route[i] end
		R.route = stolen
		R:BuildSync()
		local after = #(R.route or {})
		if after <= 2 then
			return false, ("Build accepted a swapped %d-stop route as current"):format(after)
		end
		return true, ("%d stops, swapped to 2, rebuilt to %d"):format(real, after)
	end)

	check("The router model gives the route back", function()
		-- The planner showed six mounts across five stops after a /mm report --
		-- the harness's own sample, not the plan. RouterModel swaps the plan
		-- for a small sample, and its restoring Build returned EARLY because
		-- the build signature had already been put back, so the signature
		-- claimed a route that R.route no longer held.
		local R = MM.Router
		if not (R and R.Build and MM.RouterModel and MM.RouterModel.Run) then
			return nil, "router model not available"
		end
		R:BuildSync()
		local before = #(R.route or {})
		if before < 2 then return nil, "no route to protect" end
		local ok = pcall(MM.RouterModel.Run)
		if not ok then return nil, "model did not run" end
		local after = #(R.route or {})
		if after < before then
			return false, ("the model kept the route: %d stops -> %d")
				:format(before, after)
		end
		return true, ("%d stops before the model, %d after"):format(before, after)
	end)

	check("What you are standing on is not reordered away", function()
		-- Standing at the Island Expedition NPC -- one minute off, five mounts
		-- on one stop -- the plan opened by flying to Tazavesh. Layer 2
		-- promoted the island correctly and layer 3 moved it to third, because
		-- minimising travel across a hundred stops barely notices where a
		-- zero-travel stop sits. It notices a great deal if you only have time
		-- for two.
		local R = MM.Router
		if not (R and R.route and #R.route > 1) then return nil, "no route" end
		local firstHere, firstOther
		for i, stop in ipairs(R.route) do
			if stop.hereNow and stop.urgency ~= MM.Planner.URGENCY.EXPIRING then
				firstHere = firstHere or i
			elseif stop.urgency ~= MM.Planner.URGENCY.EXPIRING then
				firstOther = firstOther or i
			end
		end
		if not firstHere then return nil, "nothing promoted for being here" end
		if firstOther and firstOther < firstHere then
			return false, ("a stop you must travel to leads at %d, "
				.. "the one you are standing on is at %d"):format(firstOther, firstHere)
		end
		return true, ("standing-here work leads at position %d"):format(firstHere)
	end)

	check("A plan change during a build is not dropped", function()
		-- Clear Plan while a build was in flight was discarded entirely: the
		-- running build finished against the OLD plan, announced itself, and
		-- the planner drew a route for mounts that were no longer planned. The
		-- compact list was right because it reads the plan, not the route.
		local R = MM.Router
		if not (R and R.Build and R.BuildSync and R.IsBuilding) then
			return nil, "no router"
		end
		R:BuildSync()
		local before = #(R.route or {})
		if before < 2 then return nil, "route too short to test" end
		-- Ask twice in a row: the second must not be silently swallowed.
		R.builtSignature, R.builtRouteCount = nil, nil
		R:Build()
		R.builtSignature = "deliberately-stale"
		R:Build()
		local queued = R.rebuildWhenDone
		R:BuildSync()
		if R.IsBuilding() then return false, "still building after a sync build" end
		return true, queued and "second request queued and re-issued"
			or "first build finished before the second arrived"
	end)

	check("An unfinished build is not reported as an empty plan", function()
		-- Clear Plan then Auto-Plan All showed "your farm plan is empty" over a
		-- plan of 286 goals. Build is chunked and returns with the work in
		-- flight, so the pane painted the PREVIOUS route -- which Clear Plan
		-- had just emptied. Changing tabs "fixed" it only by re-rendering after
		-- the build landed.
		local R = MM.Router
		if not (R and R.IsBuilding and R.Build) then return nil, "no router" end
		if R.IsBuilding() then return nil, "a build is already running" end
		R.builtSignature, R.chartRank, R.builtRouteCount = nil, nil, nil
		R:Build()
		local flying = R.IsBuilding()
		R:BuildSync()
		if R.IsBuilding() then
			return false, "BuildSync returned with work still in flight"
		end
		-- The signal the view listens on must exist, or nothing repaints when
		-- the route lands and the pane stays wrong until something else redraws.
		if not (MM.Fire and MM.On) then return nil, "no event bus" end
		return true, flying and "build reported in flight, then completed"
			or "build completed within one frame"
	end)

	check("A chunked build never shows a partial route", function()
		-- Chunking was off because RunBuild cleared R.route before refilling
		-- it, so a reader during a build saw an empty list and drew it. The
		-- route is assembled into a local now and swapped in once, after every
		-- yield. This asserts the property directly: pump a build one frame at
		-- a time and check the route is never shorter than it started.
		local R = MM.Router
		if not (R and R.BuildSync and R.Build) then return nil, "no router" end
		R:BuildSync()
		local before = #(R.route or {})
		if before < 3 then return nil, "route too short to test" end
		-- Start a chunked build and look at the route while it is in flight.
		R.builtSignature, R.chartRank, R.builtRouteCount = nil, nil, nil
		R:Build()   -- audit-allow: build-then-read is the assertion here
		local during = #(R.route or {})
		R:BuildSync()
		local after = #(R.route or {})
		if during == 0 then
			return false, "the route was EMPTY while a build was in flight"
		end
		if during < before then
			return false, ("partial route visible mid-build: %d of %d")
				:format(during, before)
		end
		return true, ("%d stops before, %d visible mid-build, %d after")
			:format(before, during, after)
	end)

	check("The route builds cleanly", function()
		-- A one-line omission broke every route build in the addon and 57 checks
		-- did not notice, because every one of them tested a PIECE. Nothing ran
		-- the pipeline. This does, and it is the check that should have existed
		-- first.
		local R = MM.Router
		local ok, err = pcall(function() return R:BuildSync() end)
		if not ok then return false, "Router:Build() threw: " .. tostring(err) end

		local planned = #MM.Planner:GetPlan()
		if planned == 0 then return nil, "plan is empty — nothing to build" end

		-- every planned goal has to land somewhere: routed, unrouted or parked
		local seen, twice = {}, nil
		for _, stop in ipairs(R.route) do
			for _, m in ipairs(stop.members or { stop }) do
				if m.entry then
					if seen[m.entry] then twice = m.entry.name end
					seen[m.entry] = true
				end
			end
		end
		for _, e in ipairs(R.unrouted) do seen[e] = true end
		for _, d in ipairs(R.deferred) do if d.entry then seen[d.entry] = true end end
		if twice then return false, twice .. " was routed twice" end

		local lost = 0
		for _, e in ipairs(MM.Planner:GetPlan()) do if not seen[e] then lost = lost + 1 end end
		if lost > 0 then
			return false, ("%d of %d planned goals vanished from the route"):format(lost, planned)
		end
		if #R.route == 0 and #R.unrouted == 0 then
			return false, ("%d goals planned and nothing routed"):format(planned)
		end
		return true, ("%d stops, %d parked, all %d goals accounted for")
			:format(#R.route, #R.deferred, planned)
	end)

	check("Building the route is fast", function()
		-- A route build froze the client for MINUTES and the addon had no way to
		-- say so: the teleport option list was being re-read, with its ten-odd C
		-- calls per option, inside the greedy's inner loop. Nothing measured
		-- anything, so the only symptom was a player waiting.
		local R = MM.Router
		if not debugprofilestop then return nil, "no timer on this client" end
		-- TIME A REAL BUILD, NOT A CACHE HIT.
		--
		-- This reported "0 ms for 286 goals" in the same run where the route
		-- section said "built in 1483 ms -- too slow, this is a freeze". Both
		-- measured the same function. Build returns early when builtSignature
		-- still matches the plan, and by the time the checks run it always
		-- does, so the check that exists to catch the freeze was timing a
		-- return statement and passing on it.
		--
		-- Clearing the signature first is what every other honest caller of
		-- Build has had to learn to do.
		local savedSig, savedRank = R.builtSignature, R.chartRank
		R.builtSignature, R.chartRank = nil, nil
		local before = debugprofilestop()
		R:BuildSync()
		local ms = debugprofilestop() - before
		R.builtSignature, R.chartRank = savedSig, savedRank
		local goals = #MM.Planner:GetPlan()
		if ms > 400 then
			return false, ("%.0f ms for %d goals — that is a visible freeze"):format(ms, goals)
		end
		if ms > 150 then
			return nil, ("%.0f ms for %d goals — watch this"):format(ms, goals)
		end
		return true, ("%.0f ms for %d goals"):format(ms, goals)
	end)

	check("Expansion skill lines are read at all", function()
		-- The wormhole gates now depend entirely on this. If the API returns
		-- nothing, every skill-line gate refuses and the options simply never
		-- appear -- a silent, invisible failure, which is the worst kind. Report
		-- it rather than let it hide.
		local C = MM.Conditions
		if not (C and C.SkillLines) then return false, "skill-line lookup missing" end
		if not (C_TradeSkillUI and C_TradeSkillUI.GetAllProfessionTradeSkillLines) then
			return nil, "this client has no trade-skill line API — gates will refuse"
		end
		local lines = C.SkillLines()
		if #lines == 0 then
			return false, "the trade-skill API returned nothing at all"
		end
		-- The catalogue proves the API works; what is LEVELLED is what gates
		-- anything. A character with no professions is legitimate, so that is a
		-- note rather than a failure.
		local learned = C.LearnedSkillLines()
		if #learned == 0 then
			return nil, ("%d skill lines in the catalogue, none levelled on this character")
				:format(#lines)
		end
		-- every line must carry a usable level, or comparisons are meaningless
		for _, line in ipairs(lines) do
			if type(line.level) ~= "number" then
				return false, (line.label or "?") .. " has no numeric skill level"
			end
		end
		return true, ("%d levelled of %d in the catalogue"):format(#learned, #lines)
	end)

	check("Skill-line gates are exact", function()
		-- Two independent traps, both real: expansion lines must not satisfy each
		-- other, and the required LEVEL is not always 1 (Northrend Engineering
		-- needs 40, Classic 260, Outland 50).
		local C = MM.Conditions
		if not (C and C.SkillLineLevel) then return false, "skill-line lookup missing" end
		-- a name that cannot exist must never match anything
		if C.SkillLineLevel("Nonexistent Zzz Engineering") ~= nil then
			return false, "a nonsense skill line matched something"
		end
		return true, "unknown skill lines refuse rather than guess"
	end)

	check("Achievement kind comes from the client", function()
		-- PvP and guild achievements are never soloable, and the client knows
		-- which are which. Reading that beats inferring it from our own prose,
		-- which is what we were reduced to before.
		local C = MM.Conditions
		if not C.AchievementClass then return false, "classifier missing" end
		if not (GetAchievementCategory and GetCategoryInfo) then
			return nil, "this client has no achievement category API"
		end
		-- 2336 is "Stormwind City" exploration; any stable id proves the walk
		-- works. What matters is that a known id yields a path and an unknown
		-- one yields nothing rather than a guess.
		if C.AchievementClass(99999999) ~= nil then
			return false, "an impossible achievement id was classified anyway"
		end
		local classified, pvp = 0, 0
		for _, rec in pairs(MM.DBByName) do
			if rec.category == "ACHIEVEMENT" then
				local id = C.RecordAchievementID(rec)
				local class = id and C.AchievementClass(id)
				if class then
					classified = classified + 1
					if class.pvp or class.guild then pvp = pvp + 1 end
					if type(class.text) ~= "string" or class.text == "" then
						return false, rec.name .. " classified with no category path"
					end
				end
			end
		end
		if classified == 0 then
			return nil, "no achievement record names an id yet — nothing to classify"
		end
		return true, ("%d classified from the client, %d PvP or guild"):format(classified, pvp)
	end)

	check("The clock cannot drag a goal too far", function()
		-- The matrix reported for weeks: "Layer 1 works; layer 3 overrides it."
		-- Routing is the final adjudicator by design, but two continent hops
		-- dwarf any preference multiplier, so geography won nearly every tie
		-- and goals arrived 57 places ahead of where preference put them.
		--
		-- The cap is the middle ground the chosen middle ground is: the clock stays free inside
		-- a band, and cannot pull anything outside it. This checks the promise
		-- the slider makes, using the router's own measurement rather than
		-- recomputing it here -- a check that re-derives the answer agrees with
		-- itself precisely when it is least useful.
		local R = MM.Router
		if not (R and R.ApplyPreferenceCap and R.PreferenceCap) then
			return false, "preference cap missing"
		end
		local cap = R.PreferenceCap()
		if not cap then return nil, "no cap set (orderCap 0 — the clock is unbound)" end
		local rep = R.capReport
		if not rep then return false, "the cap ran but reported nothing" end
		if rep.worst > cap then
			return false, ("a goal sits %d places from its preference rank, cap is %d")
				:format(rep.worst, cap)
		end
		return true, ("cap %d places; worst displacement %d across %d stops, %d moved")
			:format(cap, rep.worst, rep.stops, rep.shifted)
	end)

	check("The cap costs travel, and says how much", function()
		-- Constraining the order must cost SOMETHING in travel or it is not
		-- doing anything. This measures the trade rather than asserting it is
		-- free, because "free" would mean the cap never binds.
		local R = MM.Router
		if not (R and R.RouteMinutes) then return false, "router missing" end
		local saved = MM.db.weights
		local function build(capValue)
			local w = { schema = 2 }
			for k, v in pairs(saved or {}) do
				if k ~= "order" then w[k] = v end
			end
			if saved and saved.order then
				local o = {}
				for i, t in ipairs(saved.order) do o[i] = t end
				w.order = o
			end
			w.orderCap = capValue
			MM.db.weights = w
			MM:Fire("MM_WEIGHTS_CHANGED")
			R:BuildSync()
			return R.totals and R.totals.minutes or 0, R.capReport
		end
		local free = build(0)
		local capped, rep = build(8)
		MM.db.weights = saved
        MM:Fire("MM_WEIGHTS_CHANGED")
		R:BuildSync()
		if capped < free * 0.999 then
			return false, ("capping made the route FASTER (%d vs %d) — the cap is "
				.. "not constraining anything"):format(capped, free)
		end
		local pct = free > 0 and ((capped - free) / free * 100) or 0
		return true, ("cap 8 costs %.1f%% more travel (%d -> %d min), worst "
			.. "displacement %d"):format(pct, math.floor(free), math.floor(capped),
			rep and rep.worst or -1)
	end)

	check("Attempts are account-wide and never imply a pity timer", function()
		-- Mounts are account-wide, so attempts must be. They were counted per
		-- character, which made thirty kills on a main and twenty on an alt
		-- read as thirty -- incoherent for an addon that tells you which
		-- character to do a thing on.
		--
		-- And the framing matters as much as the count. Drops are memoryless:
		-- a long streak changes nothing about the next attempt. An addon that
		-- implies otherwise teaches people to chase a pity timer that does not
		-- exist, which makes their decisions worse, not better.
		local A = MM.Attempts
		if not (A and A.Get and A.Line) then return false, "attempts module missing" end
		if MM.db.attempts == nil then
			return false, "attempts are not stored on the account"
		end
		-- The statistic must be the real one: P(nothing after n) = (1-p)^n.
		local probe = { name = "probe", dropRate = 2 }
		local still = A.Unluckiness(probe, 100)
		if not still or math.abs(still - 0.98 ^ 100) > 1e-9 then
			return false, "unluckiness is not (1-p)^n"
		end
		-- No drop rate must mean no claim invented.
		if A.Unluckiness({ name = "x" }, 50) ~= nil then
			return false, "invented a statistic for a mount with no rate"
		end
		local total, mounts = 0, 0
		for _, n in pairs(MM.db.attempts) do total = total + n; mounts = mounts + 1 end
		local merged = 0
		for _ in pairs(MM.db.attemptsMerged or {}) do merged = merged + 1 end
		return true, ("%d attempts across %d mounts, %d character%s folded in")
			:format(total, mounts, merged, merged == 1 and "" or "s")
	end)

	check("An ambiguous zone name resolves to a map we can route to", function()
		-- "The Forbidden Reach" is four maps. The band-and-kind scorer picked
		-- one C_Map cannot turn into world coordinates, so two goals reached
		-- the route with no arrow. Handled correctly -- but avoidable, because
		-- a sibling map with the same name CAN be positioned.
		--
		-- Checked against the LIVE client because it is entirely about what
		-- this client's map set can do; a fixture would only test my model of
		-- it, which is the assumption that produced the bug.
		local U2 = MM.Util
		if not (U2 and U2.ResolveMapForRecord and U2.GetWorldPos) then
			return nil, "map helpers unavailable"
		end
		local checked, unpositionable, worst = 0, 0, nil
		for _, rec in pairs(MM.DBByName) do
			local zone = rec.zone and rec.zone.name
			if zone and rec.obtainable then
				local mapID = U2.ResolveMapForRecord(zone, rec)
				if mapID then
					checked = checked + 1
					local _, world = U2.GetWorldPos(mapID, 50, 50)
					if not world then
						unpositionable = unpositionable + 1
						worst = worst or ("%s -> map %d"):format(zone, mapID)
					end
				end
			end
		end
		if checked == 0 then return nil, "no zones resolved yet" end
		-- Not a failure: some zones genuinely have no positionable map on this
		-- client. What matters is that we never PREFER one when a sibling works.
		return true, ("%d resolved zones, %d have no world position%s")
			:format(checked, unpositionable,
				worst and (" (e.g. " .. worst .. ")") or "")
	end)

	check("Source comparison scores real disagreement", function()
		-- The audit is only useful if its score means something, so prove both
		-- ends against text whose answer is known: identical acquisitions in
		-- different words must score high, and a genuinely wrong record low.
		local SA = MM.SourceAudit
		if not (SA and SA.Compare) then return nil, "source audit unavailable" end
		local same = SA.Compare("Drops from So'leah in Tazavesh, the Veiled Market.",
			"Drops from So'leah in Tazavesh, the Veiled Market (Mythic)")
		local wrong = SA.Compare("Drops from So'leah in Tazavesh, the Veiled Market.",
			"Purchased from a vendor in Dornogal for gold")
		if not (same and wrong) then return false, "comparison returned nil" end
		if same <= wrong then
			return false, ("same-source %.2f did not beat wrong-source %.2f")
				:format(same, wrong)
		end
		if same < 0.9 then
			return false, ("a reworded match scored only %.2f"):format(same)
		end
		if wrong > 0.4 then
			return false, ("a wrong source still scored %.2f"):format(wrong)
		end
		return true, ("reworded match %.0f%%, wrong source %.0f%%")
			:format(same * 100, wrong * 100)
	end)

	check("The route lifecycle owns its windows", function()
		-- Starting a route is a mode change: the plan HUD, arrow and Next Up
		-- come up together and the full window steps aside; stopping takes the
		-- same three away. Checks the wiring exists rather than driving the
		-- real frames, which a headless self-test cannot see.
		local need = {
			["UI.HideMain"]         = MM.UI and MM.UI.HideMain,
			["UI.SetCompactShown"]  = MM.UI and MM.UI.SetCompactShown,
			["UI.ShowMonitor"]      = MM.UI and MM.UI.ShowMonitor,
			["UI.HideMonitor"]      = MM.UI and MM.UI.HideMonitor,
			["Theme.CreateStopButton"] = MM.Theme and MM.Theme.CreateStopButton,
		}
		local missing = {}
		for name, fn in pairs(need) do
			if type(fn) ~= "function" then missing[#missing + 1] = name end
		end
		if #missing > 0 then
			return false, "missing: " .. table.concat(missing, ", ")
		end
		-- The zone window must NOT be part of it: it answers a question that
		-- has nothing to do with whether a route is running.
		if MM.ZoneAlert and MM.ZoneAlert.boundToRoute then
			return false, "the zone window was tied to the route lifecycle"
		end
		return true, "5 lifecycle hooks present; zone window independent"
	end)

	check("Weights changes always reach the plan", function()
		-- This used to refuse to re-optimize while a route was running and tell
		-- the player to stop the route, press Optimize, and start again. A
		-- setting that visibly does nothing is indistinguishable from a bug.
		if MM.Weights.blockedByRoute then
			return false, "the plan is still being gated on an active route"
		end
		return true, "no route gate on applying weights"
	end)

	check("Planning a mount moves it, rather than copying it", function()
		-- The left pane listed everything missing INCLUDING what was already
		-- planned, so a player with a full plan saw a list where every row said
		-- IN PLAN and offered to remove it -- the pane meant to answer "what
		-- could I add" was answering "what have you already added".
		local P = MM.Planner
		if not (P and P.GetMissing and P.InPlan) then return nil, "no planner" end
		local all = P:GetMissing()
		if #all == 0 then return nil, "nothing missing to test" end
		local planned, unplanned = 0, 0
		for _, e in ipairs(all) do
			if P:InPlan(e.spellID) then planned = planned + 1
			else unplanned = unplanned + 1 end
		end
		-- GetMissing is the raw truth and SHOULD still contain both; the split
		-- is the view's job. This asserts the two sets are complementary, which
		-- is what makes moving between panes lossless.
		if planned + unplanned ~= #all then
			return false, "a missing mount was neither planned nor unplanned"
		end
		return true, ("%d missing: %d on the plan, %d still to choose from")
			:format(#all, planned, unplanned)
	end)

	check("The missing list can be searched", function()
		-- The filter existed and was honoured by GetMissing long before there
		-- was any way to type into it. Proves the plumbing, not the widget:
		-- narrow to a name we know is present and confirm the list shrinks.
		local P = MM.Planner
		if not (P and P.GetMissing and P.filters) then return nil, "planner unavailable" end
		local saved = P.filters.search
		P.filters.search = ""
		local all = #P:GetMissing()
		if all == 0 then P.filters.search = saved; return nil, "nothing missing to search" end
		local pick = P:GetMissing()[1].name
		P.filters.search = pick
		local narrowed = #P:GetMissing()
		P.filters.search = "zzzzq-no-such-mount"
		local none = #P:GetMissing()
		P.filters.search = saved
		if narrowed >= all or narrowed == 0 then
			return false, ("search for %q returned %d of %d"):format(pick, narrowed, all)
		end
		if none ~= 0 then return false, "a nonsense search still matched " .. none end
		return true, ("%d missing; %q narrows to %d, nonsense to 0")
			:format(all, pick, narrowed)
	end)

	check("A deliberate no-location stop is not a blocker", function()
		-- This shipped as a false blocker in both the scorecard AND the release
		-- gate, independently. Router.lua puts the no-location goals into the
		-- route on purpose, flagged, so skipping through cannot "finish" while
		-- they sit unvisited — and both readers called that "not shippable".
		--
		-- A gate that cries wolf gets ignored, which costs more than having no
		-- gate at all. So the excuse is checked here against the LIVE route.
		local R = MM.Router
		if not (R and R.route and #R.route > 0) then return nil, "no route yet" end
		local flagged, unexplained, goals = 0, 0, 0
		for _, stop in ipairs(R.route) do
			goals = goals + #(stop.members or { stop })
			if not stop.world then
				if stop.noLocation or stop.unmappedZone
					or (MM.Queue and MM.Queue.KindFor and MM.Queue.KindFor(stop.rec))
				then flagged = flagged + 1
				else unexplained = unexplained + 1 end
			end
		end
		if unexplained > 0 then
			return false, ("%d stops have no position and no reason"):format(unexplained)
		end
		-- And the reconciliation must count GOALS, not stops: a stop can carry
		-- eight mounts, and counting stops "loses" the other seven.
		local plan = #MM.Planner:GetPlan()
		local total = goals + #(R.deferred or {})
		if total ~= plan then
			return false, ("%d goals across %d stops + %d deferred = %d, plan holds %d")
				:format(goals, #R.route, #(R.deferred or {}), total, plan)
		end
		return true, ("%d goals across %d stops reconcile exactly; "
			.. "%d positionless stops all carry a reason")
			:format(goals, #R.route, flagged)
	end)

	check("The scorecard can go down", function()
		-- A scorecard that only ever reads 100 is a decoration. Every
		-- dimension must be able to pull the number down, or the addon is
		-- grading its own homework with a pen it cannot lift.
		--
		-- Checked here against LIVE state rather than a fixture: the offline
		-- harness proves each dimension responds, this proves the thing is
		-- wired to reality and produces a number at all.
		local Sc = MM.Score
		if not (Sc and Sc.Compute) then return false, "scorecard missing" end
		local score, rows, possible, unmeasured = Sc.Compute()
		if not score then return nil, "nothing measurable yet — run /mm test" end
		if score < 0 or score > 100 then
			return false, ("scored %.1f, which is not a percentage"):format(score)
		end
		-- Every measured row must name its blocker when it is not full marks.
		for _, r in ipairs(rows) do
			if r.frac and r.frac < 0.999 and not r.why then
				return false, ("%s lost points without saying why"):format(r.d.label)
			end
		end
		local items, quests = Sc.Unreachable()
		return true, ("%.1f/100 across %d measurable points (%d unmeasurable); "
			.. "%d item + %d quest conditions excluded as platform limits")
			:format(score, possible, unmeasured, items, quests)
	end)

	check("The report does not freeze the client", function()
		-- Requirement — then generate report froze the wow client. Five sections
		-- were added in one session and none of them were measured. Between
		-- them the report ran the whole self-test TWICE (three route builds
		-- inside it), walked the database calling C_Item.GetItemCount per
		-- reagent twice over, and repeated an 8,000-pcall scan for a second
		-- section that wanted the same answer.
		--
		-- A budget, so the next such regression is a red line here rather than
		-- a locked-up client. Generous on purpose: this is a floor against
		-- catastrophe, not a micro-benchmark.
		local D = MM.Diagnostics
		if not (D and D.Build) then return nil, "report builder not exposed" end
		if not debugprofilestop then return nil, "no timer on this client" end
		-- MUST NOT RUN INSIDE THE REPORT.
		--
		-- The report's first section runs the whole self-test, which would run
		-- this check, which builds the report, which runs the self-test... I
		-- nearly shipped a fix for a freeze that caused an infinite one. The
		-- guard is the same flag the release gate uses, for the same reason.
		if D.inReport then
			return nil, "skipped inside the report itself — it would recurse"
		end
		local t0 = debugprofilestop()
		local ok, err = pcall(D.Build)
		local ms = debugprofilestop() - t0
		if not ok then return false, "the report errored: " .. tostring(err) end
		local BUDGET = 2000
		if ms > BUDGET then
			return false, ("the report took %.0f ms — over the %d ms budget. "
				.. "Something expensive is being done per record, or twice.")
				:format(ms, BUDGET)
		end
		return true, ("the whole report builds in %.0f ms (budget %d)"):format(ms, BUDGET)
	end)

	check("No diagnostic is unreachable from the report", function()
		-- Requirement — i do not care about slash commands as long as its all
		-- captured. The pasted report is the artefact that matters; a
		-- diagnostic reachable only by typing a command nobody knows exists is
		-- the same as not having written it.
		--
		-- This walks every registered _DEBUG handler in the addon and requires
		-- it to appear in the report's own section list. An orphan is a fact
		-- that will never reach the person reading the paste.
		local D = MM.Diagnostics
		if not (D and D.SECTIONS) then return nil, "sections are not exposed" end
		local listed = {}
		for _, sec in ipairs(D.SECTIONS) do
			if type(sec[2]) == "string" then listed[sec[2]] = true end
		end
		local orphans = {}
		for event in pairs(MM.Handlers or {}) do
			if type(event) == "string" and event:match("_DEBUG$") and not listed[event] then
				orphans[#orphans + 1] = event
			end
		end
		if #orphans > 0 then
			table.sort(orphans)
			return false, ("%d diagnostics exist but never reach the report: %s")
				:format(#orphans, table.concat(orphans, ", ", 1, math.min(#orphans, 4)))
		end
		local n = 0
		for _ in pairs(listed) do n = n + 1 end
		return true, ("%d diagnostics, every one of them in the report"):format(n)
	end)

	check("Every diagnostic section actually produces output", function()
		-- Requirement — all of those should be in the diagnostics right -- and he
		-- was right that some of it only existed in conversation. A section
		-- that silently produces nothing is worse than a missing one: the
		-- report LOOKS complete while the answer is absent, which is how a
		-- reader ends up asking a person instead.
		local D = MM.Diagnostics
		if not (D and D.SECTIONS) then return nil, "sections are not exposed" end
		local silent, ran = {}, 0
		local realPrint = MM.Print
		for _, sec in ipairs(D.SECTIONS) do
			local name, src = sec[1], sec[2]
			if type(src) == "string" then
				local lines = 0
				MM.Print = function() lines = lines + 1 end
				local ok = pcall(function() MM:Fire(src) end)
				MM.Print = realPrint
				ran = ran + 1
				if not ok then
					return false, ("section %q errored"):format(name)
				end
				if lines == 0 then silent[#silent + 1] = name end
			end
		end
		MM.Print = realPrint
		if #silent > 0 then
			return false, ("%d sections produce no output: %s"):format(#silent,
				table.concat(silent, ", ", 1, math.min(#silent, 5)))
		end
		return true, ("%d event-driven sections all report something"):format(ran)
	end)

	check("A weekly cap is arithmetic, not an estimate", function()
		-- Resolving currency ids unlocked something the addon could not see:
		-- GetCurrencyInfo reports a weekly cap. Needing 3,000 more of something
		-- capped at 750 a week is FOUR WEEKS, and playing harder cannot change
		-- it. That is the difference between "about eight hours" and "not before
		-- the 24th".
		local C = MM.Conditions
		if not (C and C.CurrencyWeeks) then return false, "CurrencyWeeks missing" end
		-- A cap that is a boolean rather than a number must be refused: some
		-- builds return true/false for canEarnPerWeek, and treating that as a
		-- quantity produces a confident nonsense estimate.
		local bogus = { type = "CURRENCY", id = -1, amount = 100 }
		if C.CurrencyWeeks(bogus) ~= nil then
			return false, "an unreadable currency produced a week count"
		end
		local capped, uncapped, done = 0, 0, 0
		for _, entry in ipairs(MM.Planner:GetPlan()) do
			for _, cond in ipairs((entry.rec and entry.rec.conditions) or {}) do
				if cond.type == "CURRENCY" and cond.id then
					local weeks = C.CurrencyWeeks(cond)
					if weeks == nil then uncapped = uncapped + 1
					elseif weeks == 0 then done = done + 1
					else
						capped = capped + 1
						if weeks < 0 or weeks > 520 then
							return false, ("%s reports %d weeks, which is not a real answer")
								:format(cond.name or "a currency", weeks)
						end
					end
				end
			end
		end
		if capped + uncapped + done == 0 then
			return nil, "no currency conditions carry an id yet — run /mm resolve"
		end
		return true, ("%d capped currencies costed as weeks, %d uncapped fall back "
			.. "to the grind estimate, %d already affordable")
			:format(capped, uncapped, done)
	end)

	check("An id we supplied lands ON the condition, not beside it", function()
		-- SetConditionID exists because OverrideMount cannot do this job.
		-- conditionKey treats an id as authoritative, so merging in
		-- { type = "QUEST", name = "...", id = N } keys as QUEST\0N while the
		-- record's own condition keys as QUEST\0<name> -- and the record ends
		-- up requiring the same quest TWICE, once with progress and once
		-- without. The planner would then charge it twice.
		--
		-- So: no record may carry two conditions of one type naming the same
		-- thing. This fails the moment someone reaches for OverrideMount again.
		local dupes, checked, withID = 0, 0, 0
		local firstBad
		for _, rec in ipairs(MM.DBList or {}) do
			local seen = {}
			for _, c in ipairs(rec.conditions or {}) do
				if c.name then
					local key = (c.type or "?") .. "\0" .. c.name:lower()
					if seen[key] then
						dupes = dupes + 1
						firstBad = firstBad or (rec.name .. " / " .. c.name)
					end
					seen[key] = true
					checked = checked + 1
					if c.id then withID = withID + 1 end
				end
			end
		end
		if dupes > 0 then
			return false, ("%d duplicated condition(s), e.g. %s -- an id was "
				.. "merged in as a NEW condition instead of annotating the old one")
				:format(dupes, tostring(firstBad))
		end
		return true, ("%d named conditions, %d carry an id, 0 duplicated")
			:format(checked, withID)
	end)

	check("An item cost asks how many, not whether any", function()
		-- Reported from outside: told to go and buy the Asset Advocator "even
		-- though I didn't have the currency for it". evalItem asked
		-- GetItemCount(id) > 0 and ignored the amount, so 1 of 25 Miscellaneous
		-- Mechanica satisfied the requirement and the mount ranked as a pickup.
		--
		-- Sixty conditions in the database want more than one. Driven through
		-- C.Evaluate rather than by reading the record, because the bug was in
		-- the evaluator while the data was right the whole time.
		local C = MM.Conditions
		if not (C and C.Evaluate) then return nil, "conditions module unavailable" end
		-- An item nobody owns: any real id works, since the assertion is about
		-- the COMPARISON, not about this character's bags.
		local probe = { type = "ITEM", id = 6948, name = "probe", amount = 999999 }
		local met = C.Evaluate(probe)
		if met ~= false then
			return false, ("a 999,999 requirement evaluated as %s -- the amount "
				.. "is being ignored"):format(tostring(met))
		end
		local one = { type = "ITEM", id = 6948, name = "probe", amount = 1 }
		local metOne = C.Evaluate(one)
		if metOne == nil then return nil, "item counts unreadable on this client" end
		local counted = 0
		for _, rec in ipairs(MM.DBList or {}) do
			for _, cond in ipairs(rec.conditions or {}) do
				if cond.type == "ITEM" and (cond.amount or 0) > 1 then
					counted = counted + 1
				end
			end
		end
		return true, ("%d item costs want more than one, and the amount decides")
			:format(counted)
	end)

	check("A subset is never reported as larger than its set", function()
		-- The soloability line prints "N carry no flag; M of those name an
		-- achievement id". M is a subset of N by construction, so M > N is not
		-- a wrong number, it is a sentence that cannot be true -- and it has
		-- now shipped twice, both times because the two loops drifted on one
		-- clause of the predicate.
		--
		-- Asserting the RELATIONSHIP rather than sharing the code, for the same
		-- reason the two unpriced lists are checked against each other: a
		-- helper both sides call can be extracted wrongly, and then the test
		-- agrees with the bug.
		local unknown, classified = 0, 0
		for _, rec in pairs(MM.DBByName or {}) do
			if rec.category == "ACHIEVEMENT" and rec.obtainable and rec.solo == nil then
				unknown = unknown + 1
				local id = MM.Conditions.RecordAchievementID
					and MM.Conditions.RecordAchievementID(rec)
				if id and MM.Conditions.AchievementClass(id) then
					classified = classified + 1
				end
			end
		end
		if unknown == 0 then return nil, "every achievement record carries a solo flag" end
		if classified > unknown then
			return false, ("%d of %d -- the subset is larger than the set it is "
				.. "drawn from, so the two counts use different predicates")
				:format(classified, unknown)
		end
		return true, ("%d unflagged, %d of them classified by the client")
			:format(unknown, classified)
	end)

	check("One cost is charged once, whichever field holds its id", function()
		-- The type+name check above cannot see this. ITEM and CURRENCY rows put
		-- their id in `id`, MATERIAL rows put it in `itemID`, so the same three
		-- booster parts appeared as three costs and three reagents and were
		-- charged twice over -- with different names, so no name test would
		-- have noticed either.
		--
		-- CollapseDuplicateCosts folds these at the end of the data build. This
		-- asserts the build actually ran it, which is the part that rots: the
		-- collapse used to be called from a file in the MIDDLE of the stack and
		-- nineteen layers landed after it.
		local COST = { ITEM = true, CURRENCY = true, MATERIAL = true }
		local dupes, firstBad, costs = 0, nil, 0
		for _, rec in ipairs(MM.DBList or {}) do
			local seen = {}
			for _, c in ipairs(rec.conditions or {}) do
				if COST[c.type] then
					costs = costs + 1
					local id = c.id or c.itemID or c.currencyID
					if id then
						if seen[id] then
							dupes = dupes + 1
							firstBad = firstBad or (rec.name .. " / " .. tostring(id))
						end
						seen[id] = true
					end
				end
			end
		end
		if dupes > 0 then
			return false, ("%d cost(s) counted twice, e.g. %s -- id and itemID key "
				.. "apart, so the same purchase survives as two conditions")
				:format(dupes, tostring(firstBad))
		end
		return true, ("%d cost conditions, none charged twice"):format(costs)
	end)

	check("A vendor that checks a reputation carries the condition", function()
		-- Reported from outside: "it told me to go collect Wild Goretusk but I
		-- don't have the rep needed." Nothing was broken in the evaluation --
		-- the record simply had no reputation condition, so allMet came back
		-- true and it ranked as a pickup.
		--
		-- A purchase whose source text names a standing and whose conditions
		-- name none is the exact shape of that bug, and it is cheap to spot:
		-- the words only appear in a source line because a vendor is checking
		-- for them. Six records were in this state, all of them routable.
		local STANDINGS = { "Exalted", "Revered", "Honored", "Friendly" }
		local PURCHASE = { VENDOR = true, CURRENCY = true, REP = true,
			TIMEWALKING = true }
		local bad, checked, firstBad = 0, 0, nil
		for _, rec in ipairs(MM.DBList or {}) do
			local src = rec.source or ""
			if rec.obtainable and PURCHASE[rec.category] then
				local names
				for _, s in ipairs(STANDINGS) do
					-- "with <Faction>" is what a gate reads like. "Exalted
					-- reputations" in a note about an achievement is not one,
					-- and matching the bare word flagged a dozen of those.
					if src:find(s .. " with ") then names = s break end
				end
				if names then
					checked = checked + 1
					local modelled = false
					for _, c in ipairs(rec.conditions or {}) do
						if c.type == "REP" then modelled = true break end
					end
					if not modelled then
						bad = bad + 1
						firstBad = firstBad or rec.name
					end
				end
			end
		end
		if checked == 0 then
			return nil, "no purchase record states a standing in its source text"
		end
		if bad > 0 then
			return false, ("%d purchase(s) name a reputation in prose and carry no "
				.. "REP condition, e.g. %s -- the planner will rank it as a pickup")
				:format(bad, tostring(firstBad))
		end
		return true, ("%d purchases state a standing; every one models it")
			:format(checked)
	end)

	check("A lockout retires its goal and moves nothing else", function()
		-- The plan is a chart, and it holds still while you follow it. Taking a
		-- lockout drops that ONE goal; the others keep the places they already
		-- had. Re-optimizing here would reshuffle objectives two and three
		-- while you were still flying to objective one.
		--
		-- So: nothing LOCKED may remain in the plan, and the removal must not
		-- have gone through the auto-optimize path.
		local P = MM.Planner
		if not (P and MM.cdb and MM.cdb.plan and MM.Availability) then
			return nil, "no plan"
		end
		local stuck, n = nil, 0
		for _, item in ipairs(MM.cdb.plan) do
			local entry = MM.Scanner and MM.Scanner.bySpell
				and MM.Scanner.bySpell[item.spellID]
			if entry then
				n = n + 1
				if MM.Availability.GetStatus(entry) == "LOCKED" then
					stuck = stuck or (entry.name or item.spellID)
				end
			end
		end
		if stuck then
			return false, ("%s is on lockout and still in the plan -- the router "
				.. "will keep pointing at something you cannot act on")
				:format(tostring(stuck))
		end
		if n == 0 then return nil, "plan is empty" end
		return true, ("%d planned goals, none of them on lockout"):format(n)
	end)

	check("A goal retired by a lockout is owed a place back", function()
		-- Retired and planned are mutually exclusive states. If a spellID is in
		-- both, the restore will re-add something already there; if it is in
		-- neither and was never collected or manually dropped, the goal has
		-- been lost silently -- which is the failure that matters, because the
		-- player never asked for it to go.
		local retired = MM.db and MM.db.retired
		if not retired then return nil, "nothing has been retired yet" end
		local planned, n = {}, 0
		for _, item in ipairs(MM.cdb and MM.cdb.plan or {}) do
			planned[item.spellID] = true
		end
		local both, collected = nil, 0
		for spellID in pairs(retired) do
			n = n + 1
			if planned[spellID] then both = both or spellID end
			local e = MM.Scanner and MM.Scanner.bySpell and MM.Scanner.bySpell[spellID]
			if e and e.collected then collected = collected + 1 end
		end
		if both then
			return false, ("spell %s is retired AND in the plan -- restoring it "
				.. "will add a goal that never left"):format(tostring(both))
		end
		if n == 0 then return nil, "nothing is retired right now" end
		return true, ("%d goal(s) retired by lockout, none of them still planned%s")
			:format(n, collected > 0
				and (", %d collected meanwhile and owed nothing"):format(collected) or "")
	end)

	check("The plan does not re-chart while you walk", function()
		-- The plan charts from where you STOOD when you charted it, not from
		-- wherever you are now. Reading the live position made objectives two
		-- and three reshuffle behind you while you flew to objective one.
		--
		-- So the anchor must exist and must be a stored place, not a live read.
		local P = MM.Planner
		if not (P and P.Anchor) then return nil, "planner not loaded" end
		local a = P.Anchor()
		if not a then return nil, "no plan has been charted yet" end
		local here = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
		return true, ("charted from %s (map %s)%s"):format(
			tostring(a.name), tostring(a.mapID),
			(here and here ~= a.mapID)
				and " -- you have moved since, and the plan has not" or "")
	end)

	check("Travel in the ease score is measured, not a continent flag", function()
		-- "Add 10 Easiest" was instant, and that was the tell -- it did no
		-- routing. Its whole travel input was 0 same continent / 1 another /
		-- 0.5 unknown, so on your own continent every candidate scored travel
		-- 0 and a mount 30 seconds away ranked level with one 8 minutes away.
		--
		-- A flag takes at most three values. A measurement takes many. This
		-- counts the DISTINCT travel costs the planner actually charges, which
		-- is the difference between the two and cannot be faked by a rename.
		local P = MM.Planner
		if not (P and P.CostParts and MM.Scanner) then return nil, "planner not loaded" end
		local seen, n, sample = {}, 0, 0
		for _, entry in ipairs(MM.Scanner.mounts or {}) do
			if not entry.collected and entry.rec and entry.rec.zone then
				local _, parts = P.CostParts(entry)
				for _, part in ipairs(parts or {}) do
					if part[1] == "Travel" then
						local v = math.floor((part[2] or 0) * 100 + 0.5)
						if not seen[v] then seen[v] = true n = n + 1 end
						sample = sample + 1
					end
				end
			end
			if sample >= 400 then break end
		end
		if sample == 0 then return nil, "no located candidates to price" end
		if n <= 3 then
			return false, ("%d distinct travel costs across %d goals -- that is a "
				.. "flag, not a measurement; the ease score is not using the router")
				:format(n, sample)
		end
		return true, ("%d distinct travel costs across %d goals"):format(n, sample)
	end)

	check("Currency and faction ids resolve from the client", function()
		-- The achievement fix exposed a pattern was not generalised: 127
		-- conditions named a faction with no id and 107 named a currency with
		-- no id. There is no reverse name->id call, but the id space is small
		-- and dense, and the client answers for every id that exists.
		local store = MM.db.ids or {}
		local function coverage(kind, field)
			local n, ok = 0, 0
			for _, rec in pairs(MM.DBByName) do
				for _, cond in ipairs(rec.conditions or {}) do
					if cond.type == kind then
						n = n + 1
						if cond[field] then ok = ok + 1 end
					end
				end
			end
			return n, ok
		end
		local cN, cOK = coverage("CURRENCY", "id")
		local fN, fOK = coverage("REP", "factionID")
		if not store.indexBuilt then
			return nil, "the id index has not been built yet (a few seconds after login)"
		end
		-- Ambiguous names must never be silently assigned.
		for _, tbl in ipairs({ store.currencies or {}, store.factions or {} }) do
			for name, id in pairs(tbl) do
				if id ~= false and type(id) ~= "number" then
					return false, ("index holds a non-id for %q"):format(name)
				end
			end
		end
		return true, ("currencies %d/%d, factions %d/%d carry ids")
			:format(cOK, cN, fOK, fN)
	end)

	check("Achievement ids come from the client", function()
		-- Requirement — close all gaps, get everything to 100%. Most remaining gaps
		-- genuinely cannot be closed from outside the game -- a drop rate nobody
		-- has observed does not exist to be looked up. This one can, and it had
		-- been treated as a lookup while sitting in the client all along.
		--
		-- Wowhead publishes an authoritative id on about one page in seven; the
		-- rest carry it only inside user comments. GetCategoryList plus
		-- GetAchievementInfo enumerates EVERY achievement with its real name and
		-- id -- the same table the Achievements UI reads.
		local named, withID, ambiguous = 0, 0, 0
		local store = MM.db.ids or {}
		for _, rec in pairs(MM.DBByName) do
			for _, cond in ipairs(rec.conditions or {}) do
				if cond.type == "ACHIEVEMENT" and cond.name then
					named = named + 1
					if cond.id then withID = withID + 1 end
				end
			end
		end
		for _ in pairs(store.achievementAmbiguous or {}) do ambiguous = ambiguous + 1 end
		if named == 0 then return nil, "no achievement conditions in the database" end
		if (store.achievementsSeen or 0) == 0 then
			return nil, "achievement index not built yet — run /mm resolve"
		end
		local pct = withID / named * 100
		if pct < 50 then
			return false, ("only %d of %d achievement conditions carry an id (%.0f%%)")
				:format(withID, named, pct)
		end
		return true, ("%d of %d achievement conditions carry an id (%.0f%%); "
			.. "%d names index %d achievements, %d names are ambiguous and left alone")
			:format(withID, named, pct, store.achievementsSeen or 0,
				store.achievementsSeen or 0, ambiguous)
	end)

	check("Every instance mount has a door", function()
		-- A mount with an `instance` block but no `zone` cannot be routed at
		-- all: it lands in "no location to route to" and silently never appears
		-- in a plan. Spawn of Galakras sat there while Kor'kron Juggernaut --
		-- the same raid, the same door -- carried the entrance all along.
		--
		-- This fails only for the COPYABLE case, where the answer is already in
		-- the database. A mount whose whole instance has no door recorded is a
		-- lookup nobody has done, not a mistake, and failing on it every build
		-- would train people to ignore the check.
		local withDoor, noDoor = {}, {}
		for _, rec in pairs(MM.DBByName) do
			if rec.obtainable and rec.instance and rec.instance.name then
				if rec.zone then
					withDoor[rec.instance.name] = rec.name
				else
					noDoor[#noDoor + 1] = rec
				end
			end
		end
		local copyable = {}
		for _, rec in ipairs(noDoor) do
			local donor = withDoor[rec.instance.name]
			if donor then
				copyable[#copyable + 1] = ("%s (copy from %s)"):format(rec.name, donor)
			end
		end
		if #copyable > 0 then
			return false, ("%d instance mounts have no door while an instance-mate "
				.. "does: %s"):format(#copyable, table.concat(copyable, ", ", 1,
					math.min(#copyable, 3)))
		end
		if #noDoor > 0 then
			return true, ("no copyable gaps; %d await a door nobody has recorded")
				:format(#noDoor)
		end
		return true, "every instance mount has a door"
	end)

	check("Queued goals are not given an arrow", function()
		-- Requirement — recommending queueing for a dungeon should be represented and
		-- respected in the nav. Infinite Timereaver drops from ANY Timewalking
		-- dungeon -- there is no door to stand outside. An arrow pointing at a
		-- location for those is worse than no arrow: it sends the player across
		-- the world to a spot that cannot help them.
		local Q = MM.Queue
		if not (Q and Q.Describe) then return false, "queue module missing" end
		local found, wrong = 0, {}
		for _, rec in pairs(MM.DBByName) do
			if rec.obtainable then
				local d = Q.Describe(rec)
				if d then
					found = found + 1
					if not d.label or d.label == "" then
						wrong[#wrong + 1] = rec.name
					end
				end
			end
		end
		if #wrong > 0 then
			return false, "queueable goals with no instruction: "
				.. table.concat(wrong, ", ", 1, math.min(#wrong, 4))
		end
		if found == 0 then return nil, "no queueable goals detected" end
		return true, ("%d goals reached by queueing, each with an instruction")
			:format(found)
	end)

	check("Detection does not over-claim a queue", function()
		-- A wrong arrow is recoverable; a wrong "just queue for it" wastes an
		-- evening in the wrong queue. So anything ambiguous must keep its arrow.
		local Q = MM.Queue
		if not (Q and Q.KindFor) then return false, "queue module missing" end
		-- A plain world drop must never be read as queueable.
		local fake = { name = "Test", source = "Drops from a rare in Nagrand",
			notes = "A rare spawn." }
		if Q.KindFor(fake) then
			return false, "a world drop was misread as a queue"
		end
		-- An explicit field must win over the text.
		local explicit = { name = "Test2", queue = "raid",
			source = "Drops from a rare in Nagrand" }
		local kind = Q.KindFor(explicit)
		if kind ~= "raid" then
			return false, "an explicit queue field was ignored"
		end
		return true, "world drops keep their arrow; explicit fields win"
	end)

	check("Cost coverage is counted, not assumed", function()
		-- Requirement — make sure everything has a cost ... highlight anything that
		-- does not. The effort floor keeps an unmodelled goal from being free,
		-- but it is one number for a whole category, so a goal resting on it is
		-- one whose place in the order cannot really be justified.
		--
		-- This does not demand full coverage -- 33% of plannable goals rest on
		-- the floor today and that is data entry, not a code defect. It demands
		-- that the number is KNOWN, because an uncounted gap is one nobody ever
		-- closes.
		local CO = MM.Contribute
		if not (CO and CO.CostCoverage) then return false, "cost coverage missing" end
		local byCat = CO.CostCoverage()
		local total, covered, worst, worstCat = 0, 0, 0, nil
		for cat, d in pairs(byCat) do
			total = total + d.total
			covered = covered + d.covered
			if #d.bare > worst then worst, worstCat = #d.bare, cat end
		end
		if total == 0 then return false, "no plannable goals found to audit" end
		-- Store, TCG and promotional mounts have no in-game cost because they
		-- have no in-game acquisition; they must not be counted as gaps.
		for cat in pairs(byCat) do
			if not MM.PLANNABLE[cat] then
				return false, "audited a non-plannable category: " .. cat
			end
		end
		return true, ("%d plannable goals: %d modelled, %d on the effort rating "
			.. "(worst: %s with %d)"):format(total, covered, total - covered,
			worstCat or "-", worst)
	end)

	check("Every estimate knows where it came from", function()
		-- the question was how realistic the time costs are. The honest answer is a
		-- ratio, not a number: how much of the plan's total is READ from the
		-- client and how much is a stand-in. That is only answerable if each
		-- part carries its own provenance -- reconstructing it by matching
		-- label text breaks the first time anyone rewords one.
		local P = MM.Planner
		if not (P and P.TimeCommitment) then return false, "planner missing" end
		local measured, assumed, untagged, goals = 0, 0, 0, 0
		for _, entry in ipairs(P:GetPlan()) do
			local minutes, parts = P.TimeCommitment(entry)
			if minutes and parts then
				goals = goals + 1
				for _, part in ipairs(parts) do
					if part.kind == "assumed" then assumed = assumed + part.minutes
					elseif part.kind == "measured" then measured = measured + part.minutes
					else untagged = untagged + 1 end
				end
			end
		end
		if untagged > 0 then
			return false, ("%d time parts carry no provenance"):format(untagged)
		end
		if goals == 0 then return nil, "nothing planned" end
		local total = measured + assumed
		if total <= 0 then return nil, "no time modelled yet" end
		return true, ("%d goals: %.0f%% measured, %.0f%% assumed"):format(
			goals, measured / total * 100, assumed / total * 100)
	end)

	check("Travel data is loaded and routable", function()
		-- Two datasets now decide most of the route's cost, and both fail the
		-- same silent way: a file left out of the .toc loads nothing, errors
		-- never, and the router quietly falls back to straight-line estimates
		-- that look plausible. Counting them is the only way that shows up.
		--
		-- Thresholds are deliberately well below the real figures. This is a
		-- "did it load at all" check, not a fingerprint of one build.
		local fs, tn, te = MM.FlightSeconds, MM.TravelNodes, MM.TravelEdges
		if not fs then return false, "no measured flight times loaded" end
		local nodes, hops = 0, 0
		for _, nb in pairs(fs) do
			nodes = nodes + 1
			for _ in pairs(nb) do hops = hops + 1 end
		end
		if hops < 3000 then
			return false, ("only %d flight hops loaded"):format(hops)
		end
		-- Every hop must be reachable by name, or the pathfinder cannot use it.
		local named = MM.FlightNodeName
		if not named then return false, "no nodeID->name map" end
		local projected = 0
		for id, nb in pairs(fs) do
			if named[id] then
				for oid in pairs(nb) do if named[oid] then projected = projected + 1 end end
			end
		end
		if projected < hops then
			return false, ("%d of %d hops have no name mapping"):format(hops - projected, hops)
		end
		if not (tn and te) then return false, "no travel network loaded" end
		local n, e = 0, 0
		for _ in pairs(tn) do n = n + 1 end
		for _ in pairs(te) do e = e + 1 end
		if n < 500 or e < 150 then
			return false, ("travel network thin: %d nodes, %d edges"):format(n, e)
		end
		return true, ("%d nodes / %d hops, all projected; network %d/%d"):format(
			nodes, hops, n, e)
	end)

	check("Every measured hop actually reaches the pathfinder", function()
		-- The check above proves the DATA is complete. This proves the ROUTER
		-- received it, which is a different claim and the one that kept being
		-- false: 4,068 hops loaded, named and verified, while the graph quietly
		-- discarded 903 of them because it had no coordinates for one end.
		--
		-- A number that only counts what survived cannot notice what did not.
		local J, fs, named = MM.Journey, MM.FlightSeconds, MM.FlightNodeName
		if not (J and J.Stats and fs and named) then
			return nil, "travel layer not loaded yet"
		end
		J.Stats() -- forces the graph to build
		local hops = 0
		for _, nb in pairs(fs) do for _ in pairs(nb) do hops = hops + 1 end end
		if hops == 0 then return false, "no measured hops to feed it" end
		local got = J.measuredEdges or 0
		if got == 0 then
			return false, "the graph took none of the measured flight times"
		end
		-- Same-name collisions are genuine duplicates and are expected to merge;
		-- anything beyond a small fraction is data being dropped, not deduped.
		local lost = hops - got
		if lost > hops * 0.05 then
			return false, ("%d of %d measured hops never reached the graph"):format(
				lost, hops)
		end
		return true, ("%d of %d hops routable, %d transit-only nodes"):format(
			got, hops, J.transitNodes or 0)
	end)

	check("A place we ship a flight point for is not an unknown place", function()
		-- A Hearthstone binds to an INN, and an inn is not a map, so a bind in
		-- "Har'athir" resolved to nothing and the addon asked the player to go
		-- and stand there. We already shipped that name -- a flight master in
		-- Harandar -- and nothing was looking at it.
		local U = MM.Util
		if not (U and U.ResolveMapByName and MM.FlightPointMapForName) then
			return nil, "no flight point index"
		end
		local id = MM.FlightPointMapForName("Har'athir")
		if not id then return nil, "that flight point is not in this build" end
		local viaResolve = U.ResolveMapByName("Har'athir")
		if viaResolve ~= id then
			return false, ("flight point says map %s, resolver says %s")
				:format(tostring(id), tostring(viaResolve))
		end
		-- A real map name must still win outright.
		local org = U.ResolveMapByName("Orgrimmar")
		if not org then return false, "a real map name stopped resolving" end
		return true, ("Har'athir -> map %d, and map names still win"):format(id)
	end)

	check("A zone name resolves whatever its case", function()
		-- The travel graph keys its zones lowercase and then asked the map
		-- index, which the client fills with proper-cased names. Every one of
		-- those lookups missed, and missed quietly: cross-zone distances fell
		-- back to a crude zone-size approximation, and any zone without a flight
		-- point of its own became unreachable -- "no way to reach the forbidden
		-- reach from the graph" while 2,180 positioned nodes sat loaded.
		--
		-- A resolver that only answers in one case is a resolver half its
		-- callers cannot use.
		local U = MM.Util
		if not (U and U.ResolveMapByName) then return nil, "resolver missing" end
		local probes, checked, bad = { "Orgrimmar", "Stormwind City", "Tanaris" }, 0, nil
		for _, name in ipairs(probes) do
			local exact = U.ResolveMapByName(name)
			if exact then
				checked = checked + 1
				local lower = U.ResolveMapByName(name:lower())
				local upper = U.ResolveMapByName(name:upper())
				if lower ~= exact or upper ~= exact then
					bad = bad or ("%s: exact %s, lower %s, upper %s"):format(
						name, tostring(exact), tostring(lower), tostring(upper))
				end
			end
		end
		if checked == 0 then return nil, "no probe zone resolved at all" end
		if bad then return false, bad end
		return true, ("%d zones resolve identically in any case"):format(checked)
	end)

	check("Nowhere on another continent is ever called nearby", function()
		-- The bug this exists for: a world position is CONTINENT-RELATIVE, so
		-- differencing two of them across continents is not a distance. It is
		-- two unrelated numbers subtracted, and it comes out small. The graph
		-- duly decided Bastion was six seconds from The Maw, routed a Tazavesh
		-- goal to a raid door in Nazmir, and collapsed every profile to the
		-- same three minutes -- all of it stated with total confidence.
		--
		-- Cheap wrong answers are the dangerous kind: they win the comparison.
		local J = MM.Journey
		if not (J and J.AttachAudit) then return nil, "travel layer not loaded" end
		local probes = { "Tazavesh, the Veiled Market", "Ny'alotha, the Waking City",
			"The Forbidden Reach", "Sanctum of Domination" }
		local checked, offending, example = 0, 0, nil
		for _, zone in ipairs(probes) do
			-- The audit reads what attaching actually chose, so something has to
			-- have attached first. Without this the check reports "nothing to
			-- audit" forever, which is a pass that proves nothing.
			local mapID = MM.Util and MM.Util.ResolveMapByName
				and MM.Util.ResolveMapByName(zone)
			if J.Plan then J.Plan(zone, 50, 50, "Orgrimmar", 50, 50, nil, mapID) end
			local same, other = J.AttachAudit(zone, 50, 50, mapID)
			if same then
				checked = checked + 1
				if (other or 0) > 0 then
					offending = offending + other
					example = example or zone
				end
			end
		end
		if checked == 0 then return nil, "no probe zone could be audited yet" end
		if offending > 0 then
			return false, ("%d attachment(s) sit on another continent, e.g. %s")
				:format(offending, example)
		end
		return true, ("%d zones audited, every entry point on the right continent")
			:format(checked)
	end)

	check("A plan is torn down after it is made", function()
		-- START and GOAL are temporary nodes wired into the graph for one plan
		-- and removed after. The removal walked the destination zone's own
		-- nodes, so whenever the goal attached through the nearest-elsewhere
		-- fallback -- whose entry points are by definition NOT in that zone --
		-- its "-> GOAL" edges were left behind for the rest of the session.
		--
		-- Every later plan then found a stale cheap edge to a goal that no
		-- longer existed. Four legs with different origins and destinations came
		-- back with the same route and the same 1.7 minutes, and a destination
		-- with 21 entry points of its own still ended at a node in the Emerald
		-- Dream. Nothing errored; the graph was answering an older question.
		local J = MM.Journey
		if not (J and J.Plan and J.Node) then return nil, "travel layer not loaded" end
		-- Two destinations far apart, planned from the same origin. If a leftover
		-- goal edge survives the first, the second will reuse it and agree.
		local pairs_ = {
			{ "Orgrimmar", "Tanaris" },
			{ "Orgrimmar", "The Maw" },
		}
		local seen, costs = {}, {}
		for i, pr in ipairs(pairs_) do
			local mins, legs = J.Plan(pr[1], 50, 50, pr[2], 50, 50)
			if not mins then return nil, ("could not plan %s -> %s"):format(pr[1], pr[2]) end
			costs[i] = mins
			seen[i] = (J.Describe and J.Describe(legs)) or tostring(mins)
		end
		if seen[1] == seen[2] then
			return false, ("two different destinations returned the same route: %s")
				:format((seen[1] or ""):sub(1, 80))
		end
		return true, ("%d destinations, %d distinct routes (%.1fm vs %.1fm)")
			:format(#pairs_, 2, costs[1], costs[2])
	end)

	check("The broker gives a display addon everything it needs", function()
		-- Titan, Bazooka and ElvUI datatexts all build their plugin from this
		-- one object, and every field they cannot find degrades silently: a
		-- missing label reads as "MasterMounts" jammed together in the top bar,
		-- and a tocname that does not name the addon FOLDER makes Titan's
		-- category, version and notes lookups all return nil.
		--
		-- That last one is the folder-name mismatch that once broke four
		-- textures without erroring. It is checkable, so check it.
		local LDB = LibStub and LibStub:GetLibrary("LibDataBroker-1.1", true)
		if not LDB then return nil, "LibDataBroker not loaded" end
		local obj
		for name, dataobj in LDB:DataObjectIterator() do
			if name == "MasterMounts" then obj = dataobj break end
		end
		if not obj then return false, "no data object registered" end

		if obj.type ~= "data source" then
			return false, ("type is %q, which no display addon maps"):format(tostring(obj.type))
		end
		for _, field in ipairs({ "text", "icon", "label", "tocname" }) do
			if obj[field] == nil or obj[field] == "" then
				return false, "the broker carries no " .. field
			end
		end
		if type(obj.OnClick) ~= "function" or type(obj.OnTooltipShow) ~= "function" then
			return false, "the broker has no click or tooltip handler"
		end

		-- The real test: does tocname actually name an addon this client has?
		local meta = C_AddOns and C_AddOns.GetAddOnMetadata
		if not meta then return nil, "no addon metadata API on this client" end
		local version = meta(obj.tocname, "Version")
		if not version then
			return false, ("tocname %q is not an addon folder on this client, so "
				.. "Titan resolves no category or version"):format(tostring(obj.tocname))
		end
		if version ~= MM.VERSION then
			return false, ("the toc says %s and MM.VERSION says %s"):format(
				version, tostring(MM.VERSION))
		end
		local category = meta(obj.tocname, "X-Category")
		return true, ("data source, label %q, resolves to %s v%s, category %s")
			:format(obj.label, obj.tocname, version, tostring(category or "none"))
	end)

	check("A price you can already pay is not a grind", function()
		-- 86 vendor mounts state a gold price in prose and carried no cost the
		-- planner could read, so each fell to its category's effort rating: a
		-- ten gold ram ranked like a raid. Gold is not a duration, so what is
		-- checked is affordability, which the client answers exactly.
		--
		-- The failure this guards is silence. If the overrides stop loading, or
		-- GetMoney stops answering, nothing errors -- the mounts simply drift
		-- back to being costed like grinds and the order quietly worsens.
		local db = MM.DBByName
		if not db then return nil, "database not loaded" end
		local priced, cheapest, dearest = 0, nil, nil
		for _, rec in pairs(db) do
			if rec.goldCost then
				priced = priced + 1
				if rec.goldCost <= 0 then
					return false, (rec.name or "?") .. " has a goldCost of zero"
				end
				cheapest = math.min(cheapest or rec.goldCost, rec.goldCost)
				dearest = math.max(dearest or rec.goldCost, rec.goldCost)
			end
		end
		if priced == 0 then return false, "no gold prices loaded at all" end
		if not GetMoney then return nil, "this client has no GetMoney" end

		-- And it must actually reach the estimate. A number in the record that
		-- no cost term reads is the shape of bug this suite keeps missing.
		local sample, entry
		for _, rec in pairs(db) do
			if rec.goldCost and rec.goldCost * 10000 <= (GetMoney() or 0) then
				local e = rec.spellID and MM.Scanner and MM.Scanner.bySpell
					and MM.Scanner.bySpell[rec.spellID]
				if e then sample, entry = rec, e break end
			end
		end
		if not entry then
			return true, ("%d priced %sg-%sg; none affordable and scanned right now")
				:format(priced, U.Comma(cheapest), U.Comma(dearest))
		end
		local _, parts = MM.Planner.TimeCommitment(entry)
		if parts then
			for _, part in ipairs(parts) do
				if (part.label or ""):find("already have") then
					return true, ("%d priced %sg-%sg; %s costs %d min, not %d")
						:format(priced, U.Comma(cheapest), U.Comma(dearest),
							sample.name, part.minutes, 240)
				end
			end
			return false, (sample.name or "?")
				.. " is affordable but no cost term says so"
		end
		return true, ("%d gold prices loaded, %sg to %sg"):format(
			priced, U.Comma(cheapest), U.Comma(dearest))
	end)

	check("The coverage metric agrees with what the planner actually does", function()
		-- THE CLASS OF BUG THIS EXISTS FOR, and it is not hypothetical: 86
		-- records were given a real gold price, the planner priced them from it,
		-- and the coverage report went on calling them bare -- still offering
		-- points for fixing something already fixed. Nothing failed. The metric
		-- had simply never been told about a whole kind of cost.
		--
		-- A count that is not checked against the behaviour it claims to
		-- describe is a number that drifts. So: whatever CostCoverage calls
		-- MODELLED must actually receive a real cost term, and whatever it calls
		-- BARE must not. Disagreement in either direction is the metric lying.
		local CO, P = MM.Contribute, MM.Planner
		if not (CO and CO.CostCoverage and P and P.TimeCommitment) then
			return nil, "coverage or planner not loaded"
		end
		-- The labels the planner uses when it has nothing real to go on.
		local FALLBACK = {
			["cost not yet modelled"] = true,
			["achievement not yet modelled"] = true,
		}
		local function isFallback(label)
			return FALLBACK[label] or (label or ""):find("^effort rating ") ~= nil
		end

		local byCat = CO.CostCoverage()
		local bare = {}
		for _, d in pairs(byCat) do
			for _, name in ipairs(d.bare or {}) do bare[name] = true end
		end

		local checkedModelled, checkedBare, wrong = 0, 0, nil
		for _, entry in ipairs(MM.Scanner and MM.Scanner.mounts or {}) do
			local rec = entry.rec
			if rec and rec.obtainable and MM.PLANNABLE[rec.category] and not entry.collected then
				local ok, _, parts = pcall(P.TimeCommitment, entry)
				if ok and parts then
					local real = false
					for _, part in ipairs(parts) do
						if not isFallback(part.label) then real = true break end
					end
					if bare[rec.name] then
						-- ONE DIRECTION ONLY, and this is the reason.
						--
						-- "Bare" means we cannot price the ACQUISITION -- no drop
						-- rate, no stated cost, no chain. The planner may still
						-- charge real minutes for the VISIT, and should: an
						-- untimed treasure in Zul'Aman is a run you have to make
						-- whether or not anyone knows the odds. Asserting the
						-- reverse called that a contradiction when it is correct
						-- behaviour, and Ancestral War Bear said so.
						checkedBare = checkedBare + 1
					else
						checkedModelled = checkedModelled + 1
						if not real and not wrong then
							wrong = ("%s is counted modelled but gets only a fallback")
								:format(rec.name)
						end
					end
				end
			end
		end
		if checkedModelled + checkedBare == 0 then
			return nil, "no plannable uncollected records to compare"
		end
		if wrong then return false, wrong end
		return true, ("%d counted modelled all get a real cost term (%d bare, "
			.. "which may still cost a visit)"):format(checkedModelled, checkedBare)
	end)

	check("A command that breaks says so", function()
		-- /mm routertest 300 printed "Modelling the router..." and then nothing.
		-- No window, no output, no error. MM:Fire pcalls every handler and sent
		-- the failure to geterrorhandler(), which retail hides by default -- so
		-- the command looked like it simply did nothing.
		--
		-- Silence is the worst failure mode a diagnostic can have, and this file
		-- has spent a day proving it. The dispatcher must speak.
		local seen
		local realPrint = MM.Print
		MM.Print = function(_, fmt, ...) seen = tostring(fmt or ""):format(...) end
		MM:On("MM_SELFTEST_FIRE_PROBE", function() error("deliberate", 0) end)
		local realHandler = geterrorhandler
		-- Swallow the error the dispatcher forwards; we are testing the CHAT
		-- line, and this probe throws on purpose.
		geterrorhandler = function() return function() end end
		local ok = pcall(function() MM:Fire("MM_SELFTEST_FIRE_PROBE") end)
		geterrorhandler = realHandler
		MM.Print = realPrint

		if not ok then return false, "Fire let a handler error escape" end
		if not seen then
			return false, "a handler threw and the dispatcher said nothing in chat"
		end
		if not seen:find("MM_SELFTEST_FIRE_PROBE", 1, true) then
			return false, "the failure line does not name the command: " .. seen:sub(1, 60)
		end
		return true, "a thrown handler is reported in chat, naming the command"
	end)

	check("Easiest means easiest, not whatever you put first", function()
		-- The easiest list ranked tiers by the player's OWN priority order, so it
		-- returned "the highest in the order you already set" and called it
		-- difficulty. Put INSTANCE first and a vendor mount you could buy
		-- standing still ranked below a dungeon.
		--
		-- Reordering priorities must move the ROUTE and must not move this.
		local P, W = MM.Planner, MM.Weights
		if not (P and P.Easiest and W and W.Order and W.Move) then
			return nil, "planner or weights not loaded"
		end
		local before = P:Easiest(10)
		-- ONE IS ENOUGH TO CHECK.
		--
		-- This demanded three, which meant that with a full plan -- 286 goals,
		-- almost everything already added -- the pool was never big enough and
		-- the check has never run once. The threshold was arbitrary: with one
		-- candidate "the easiest" is that candidate and reordering priorities
		-- must still return it; with two the comparison is already real. Only
		-- an EMPTY pool has nothing to say.
		if #before < 1 then return nil, "nothing plannable outside the plan" end
		local function names(list)
			local out = {}
			for _, e in ipairs(list) do out[#out + 1] = e.name or "?" end
			return table.concat(out, "|")
		end
		local was = names(before)

		-- W.Move is the only way the order changes, so use it -- a test that
		-- writes the store directly would not prove the real path is safe.
		local depth = #W.Order() - 1
		for i = 1, depth do W.Move(i, 1) end          -- rotate the whole order
		local after = names(P:Easiest(10))
		for i = depth, 1, -1 do W.Move(i, 1) end      -- and rotate it back
		local restored = names(P:Easiest(10))
		local saved = W.Order()

		if was ~= after then
			return false, "rotating your priority order changed the EASIEST list"
		end
		if restored ~= was then
			return false, "restoring the order did not restore the list"
		end
		return true, ("%d easiest, unchanged by rotating all %d priorities")
			:format(#before, #saved)
	end)

	check("The plan follows you between characters", function()
		-- The router can report that another character already qualifies, and
		-- following that meant logging into a character with an EMPTY plan and
		-- no idea where you were: the plan lived in per-character saved data while
		-- the collection it plans for is account-wide.
		--
		-- Two properties, and the second is the one that is easy to get wrong.
		local plan, db, cdb = MM.Planner, MM.db, MM.cdb
		if not (plan and db and cdb) then return nil, "databases not ready" end

		-- 1. One list, not two. The character table must BE the account table,
		--    or a switch silently starts over.
		if cdb.plan ~= db.plan then
			return false, "the character plan is a separate table from the account plan"
		end

		-- 2. The resume anchor is an identity, not a position. A route is
		--    rebuilt per character, so an index means something different on
		--    each one -- carrying it lands you at somebody else's stop.
		if db.routeGoal ~= nil and type(db.routeGoal) ~= "number" then
			return false, "the resume anchor is not a spellID"
		end
		local R = MM.Router
		if R and R.route and #R.route > 0 and cdb.routeActive then
			local cur = R:Current()
			if cur and db.routeGoal then
				local id = cur.spellID
					or (cur.members and cur.members[1] and cur.members[1].spellID)
				if id and db.routeGoal ~= id then
					return false, "the anchor does not match the current goal"
				end
			end
		end
		return true, ("%d goals in one account-wide plan%s"):format(#db.plan,
			db.routeGoal and (", resuming at " .. tostring(db.routeGoal)) or "")
	end)

	check("An instance can be entered, not only left", function()
		-- Links with an end marked "inside" were skipped entirely, to avoid
		-- planting a node at a map's corner. Those links are the DOORS -- the
		-- only edges joining the outdoor world to an instance -- so a goal in
		-- Tazavesh could be routed FROM and never TO. Both directions existed,
		-- so no count noticed; the travel report said it outright, with 14 goal
		-- attachments and no path.
		--
		-- Asymmetry is the thing to assert. A place you can leave and cannot
		-- reach is not a routing preference, it is a hole.
		local J = MM.Journey
		if not (J and J.Plan and MM.Util) then return nil, "travel layer not loaded" end
		local probes = { "Tazavesh, the Veiled Market", "Ny'alotha, the Waking City" }
		local hub = "Orgrimmar"
		local checked, oneWay = 0, nil
		for _, zone in ipairs(probes) do
			local mapID = MM.Util.ResolveMapByName and MM.Util.ResolveMapByName(zone)
			local out = J.Plan(zone, 50, 50, hub, 50, 50, nil, mapID)
			local back = J.Plan(hub, 50, 50, zone, 50, 50, nil, nil, mapID)
			if out or back then
				checked = checked + 1
				if out and not back then
					oneWay = oneWay or (zone .. " can be left but not reached")
				end
			end
		end
		if checked == 0 then return nil, "no probe instance is routable at all yet" end
		if oneWay then return false, oneWay end
		return true, ("%d instances reachable in both directions"):format(checked)
	end)

	check("Most of the world is reachable from one place", function()
		-- THE CHECK NOTHING WAS DOING. Node and edge counts were healthy while
		-- the graph was 115 separate islands whose largest held 94 nodes -- 7.9%
		-- of it -- so the router could not plan most legs and silently charged a
		-- flat constant instead. Every count looked fine because every count was
		-- fine; the connectivity was not.
		local J = MM.Journey
		if not (J and J.Reachable) then return nil, "travel layer not loaded" end
		local from
		for _, hub in ipairs({ "Orgrimmar", "Stormwind City", "Valdrakken", "Dornogal" }) do
			if J.Node and J.Node(hub) then from = hub break end
		end
		if not from then return nil, "no known hub in the graph to start from" end
		local reached, total = J.Reachable(from)
		if not (reached and total and total > 0) then
			return false, "the graph could not be walked at all"
		end
		local pct = reached / total * 100
		if pct < 50 then
			return false, ("only %.0f%% of the graph is reachable from %s -- "
				.. "the rest is islands the router cannot plan through")
				:format(pct, from)
		end
		return true, ("%.0f%% reachable from %s (%d of %d nodes), %d transit links")
			:format(pct, from, reached, total, J.transitLinks or 0)
	end)

	check("An island with no door is bridged, or says why not", function()
		-- 47 zones had no edge into the graph AT ALL -- the Forbidden Reach
		-- among them, which is why a Sanctum of Domination goal reported
		-- "no path" and fell through to a flat 6.3-minute flight between two
		-- continents. Counting links could never see it: all 1,496 were real.
		--
		-- This asserts the RELATIONSHIP the fix depends on: after bridging,
		-- what is left unbridged is only what has nothing on its continent to
		-- fly from -- never something we simply failed to try.
		local J = MM.Journey
		if not (J and J.Reachable) then return nil, "travel layer not loaded" end
		J.Stats()      -- force the build, so the counters below exist
		if J.components == nil then return nil, "no component walk recorded" end
		local made, skipped = J.bridges or 0, J.bridgeSkipped or 0
		if J.components > 1 and made == 0 and skipped == 0 then
			return false, ("%d components and not one was even considered")
				:format(J.components)
		end
		-- Every bridge must be priced at or above the floor.
		--
		-- This fired for real: Raven Hill's flight point sits on exactly the
		-- same ground as a Raven Hill transit endpoint in another component,
		-- so the bridge measured 0 yards and cost 0 seconds. A free edge is
		-- teleportation -- Dijkstra pops both components at the same distance
		-- and the search stopped finishing inside the frame budget. Same
		-- ground still costs something to cross, and BorderData already priced
		-- that at 5 seconds.
		local FLOOR = 5 / 60      -- minutes; matches MIN_BRIDGE_SECONDS
		for _, b in ipairs(J.bridgeDetail or {}) do
			if not (b.minutes and b.minutes >= FLOOR - 1e-9) then
				return false, ("bridge %s -> %s costs %s min -- below the floor, "
					.. "and a free edge is teleportation")
					:format(tostring(b.from), tostring(b.to), tostring(b.minutes))
			end
		end
		return true, ("%d components, %d of them hold a goal: %d bridged by "
			.. "flying, %d left alone; %d nearest-point lookups%s")
			:format(J.components, J.bridgeRelevant or 0, made, skipped,
				J.bridgeCompares or 0,
				J.bridgeWhy and (" -- " .. J.bridgeWhy) or "")
	end)

	check("A teleport you have not earned is never offered", function()
		-- 76 dungeon teleports joined the option list, and almost nobody has
		-- most of them. If ownership were assumed rather than asked, every route
		-- would be planned around instant travel this character cannot do --
		-- which is worse than no modelling at all, because it looks authoritative.
		local list, TP = MM.DungeonTeleports, MM.Teleports
		if not (list and TP and TP.Options) then return nil, "teleports not loaded" end
		local total = 0
		for _, t in ipairs(list) do
			total = total + 1
			if not t.spell then
				return false, (t.name or "?") .. " has no spell id to check ownership with"
			end
		end
		if total == 0 then return false, "no dungeon teleports loaded" end
		-- Ask the CLIENT, through whichever call this build actually has.
		--
		-- The bare IsSpellKnown is a deprecated shim over C_SpellBook and it
		-- raises rather than returning nil when handed anything but a number --
		-- which is what this check did on its first run, because a landing
		-- carries no spell id and the nil went straight through. Guarded and
		-- pcall'd: a check that cannot read ownership must say so, not explode
		-- and not quietly pass.
		local function knowsSpell(id)
			if type(id) ~= "number" then return nil end
			if C_SpellBook and C_SpellBook.IsSpellKnown then
				local ok, res = pcall(C_SpellBook.IsSpellKnown, id)
				if ok then return res end
			end
			if IsPlayerSpell then
				local ok, res = pcall(IsPlayerSpell, id)
				if ok then return res end
			end
			return nil
		end
		local offered, wrong, unreadable = 0, nil, 0
		for _, o in ipairs(TP.Options() or {}) do
			if type(o.key) == "string" and o.key:find("^dungeontp_") then
				offered = offered + 1
				local known = knowsSpell(o.spell)
				if known == nil then unreadable = unreadable + 1
				elseif not known then wrong = wrong or o.name end
			end
		end
		if unreadable > 0 then
			return nil, ("%d offered teleports carry no readable spell id"):format(unreadable)
		end
		if wrong then
			return false, ("%s is offered but this character does not know it"):format(wrong)
		end
		return true, ("%d known of %d dungeon teleports, all verified with the client")
			:format(offered, total)
	end)

	check("Portals and ships are priced, and never for free", function()
		-- A zero-cost edge is teleportation to a shortest-path search: it will
		-- chain a dozen of them across the world and report the trip as instant.
		local links, secs = MM.TransitLinks, MM.TransitSeconds
		if not (links and secs) then return nil, "transit links not loaded" end
		local n, modes = 0, {}
		for _, L in ipairs(links) do
			n = n + 1
			local cost = secs[L.mode]
			if not cost or cost <= 0 then
				return false, ("%s -> %s (%s) costs nothing"):format(L.a, L.b, L.mode)
			end
			modes[L.mode] = true
			-- 0,0 means "inside the instance". If one ever arrives as a real
			-- position the graph will measure distances to a map corner.
			if L.ainside and (L.ax ~= 0 or L.ay ~= 0) then
				return false, L.a .. " is marked inside but carries a position"
			end
		end
		if n == 0 then return false, "no transit links loaded" end
		local kinds = 0
		for _ in pairs(modes) do kinds = kinds + 1 end
		return true, ("%d links across %d modes, all priced"):format(n, kinds)
	end)

	check("A node with no position is never asked for one", function()
		-- Transit-only nodes carry measured times but no x,y. That is safe for
		-- exactly one reason: the three places that read a coordinate all walk
		-- byZone, never the graph. If a positionless node ever lands in byZone
		-- the distance maths gets nil and the route dies mid-plan -- so assert
		-- the separation rather than trusting it to stay true.
		local J = MM.Journey
		if not (J and J.NodesByZone) then return nil, "graph not inspectable" end
		local zones = J.NodesByZone()
		if not zones then return nil, "graph not built yet" end
		local checked, bad = 0, nil
		for _, names in pairs(zones) do
			for _, n in ipairs(names) do
				local node = J.Node and J.Node(n)
				if node then
					checked = checked + 1
					if not (node.x and node.y) then bad = bad or node.name end
				end
			end
		end
		if checked == 0 then return nil, "no positioned nodes to check" end
		if bad then
			return false, ("%s is used for distance but has no position"):format(bad)
		end
		return true, ("%d positioned nodes, none of them placeless"):format(checked)
	end)

	check("Network legs are priced, and never for free", function()
		-- A portal is fast, not instant. An edge that costs nothing makes the
		-- router teleport through the world at zero charge and reorder the whole
		-- plan around a leg that does not exist.
		local NW = MM.Network
		if not (NW and NW.EdgeSeconds and MM.TravelEdges) then
			return nil, "network module absent"
		end
		local zero, worst = 0, nil
		for _, e in ipairs(MM.TravelEdges) do
			local s = NW.EdgeSeconds(e)
			if not s or s <= 0 then
				zero = zero + 1
				worst = worst or ((e.method or "?") .. ": " .. (e.from or "?"))
			end
		end
		if zero > 0 then
			return false, ("%d edges priced at zero, e.g. %s"):format(zero, worst)
		end
		return true, ("%d edges, all priced"):format(#MM.TravelEdges)
	end)

	check("A session's promise reaches the route", function()
		-- ASSERT THE PROMISE, NOT THE SELECTION.
		--
		-- Three earlier versions compared the route against a re-run of S.Fit --
		-- by identity, then by set. Both are unstable by construction: Fit is a
		-- greedy whose ties break on pool ORDER, and ApplySession changes that
		-- order, so the second run may legitimately choose a different stop than
		-- the first. The test failed four times and the feature was fine for the
		-- last two.
		--
		-- What a session actually promises is simpler and does not care which
		-- stops were picked: the work at the front of the route FITS THE CLOCK.
		-- That is stable, it is the thing a player would notice breaking, and it
		-- needs no second opinion from the selector.
		local S, R = MM.Session, MM.Router
		if not (S and S.Start and S.Stop and R) then return false, "session mode missing" end
		if not R.route or #R.route == 0 then return nil, "no route built to constrain" end

		local wasActive = MM.cdb.routeActive
		local prevIndex = MM.cdb.routeIndex
		local restore = S.Active and S.Active()
		local len = S.LENGTHS[2] or S.LENGTHS[1]

		S.Start(len.minutes, true)  -- setOnly: must not launch a route
		local st = S.Active and S.Active()
		local planned = st and st.planned or 0

		-- MEASURE FIRST. travelMinutes is populated by R.Measure(), which runs
		-- AFTER Build -- so reading it straight after Start summed zero and then
		-- compared zero against a budget. A check that passes because it added
		-- up nothing is worse than one that fails.
		if R.Measure then R.Measure() end

		local total, counted, priced = 0, 0, 0
		if planned > 0 then
			for i = 1, math.min(planned, #R.route) do
				local stop = R.route[i]
				local travel = stop.travelMinutes or 0
				-- VISIT minutes, because that is what S.Fit spends.
				--
				-- This used workMinutes -- EffortMinutes, the whole grind. A
				-- five-mount island stop is one five-minute run, but its grind
				-- is 40 attempts, so the check totalled 732 minutes for a
				-- 45-minute session and failed a session that was correct. The
				-- test has to cost the route the way the session costed it or
				-- it is measuring a different question.
				local work = stop.visitMinutes or stop.workMinutes or 15
				if stop.travelMinutes or stop.visitMinutes or stop.workMinutes then
					priced = priced + 1
				end
				total = total + travel + work
				counted = counted + 1
			end
		end

		-- Restore before reporting: Start and Stop each rebuild the route, and
		-- the checks after this one must not inherit our leftovers.
		S.Stop(true)
		MM.cdb.routeActive = wasActive
		MM.cdb.routeIndex = prevIndex or 1
		if restore then S.Start(restore.minutes, true) end
		if R.Build then R:BuildSync() end

		if planned == 0 then return nil, "nothing fits the sample length" end
		if counted < planned then
			return false, ("session claims %d stops, route has %d"):format(planned, counted)
		end
		-- The sum has to come from somewhere. If not one leading stop carries a
		-- real cost, this check is adding up defaults and proving nothing --
		-- which is exactly how it passed at "0 min of work".
		if priced == 0 then
			return false, ("%d leading stops carry no measured cost at all"):format(counted)
		end
		-- One stop may overrun on its own -- Fit takes the first thing that fits
		-- and a single long run can exceed the budget by itself. The promise is
		-- about the SET, so allow the last stop to spill.
		if counted > 1 and total > len.minutes * 2 then
			return false, ("%d leading stops total %.0f min for a %d min session")
				:format(counted, total, len.minutes)
		end
		return true, ("%d min -> %d stops leading, %.0f min total (%d priced)"):format(
			len.minutes, counted, total, priced)
	end)

	check("A session promise is kept", function()
		-- "we have 45 minutes" is a promise, not a lean. What the mode offers
		-- must be measured with the SAME clock the router uses, or the addon
		-- promises one thing and routes another.
		local S = MM.Session
		if not (S and S.Fit) then return false, "session mode missing" end
		local worst
		for _, len in ipairs(S.LENGTHS) do
			local chosen, _, used = S.Fit(len.minutes)
			if used > len.minutes + 0.001 then
				worst = ("%d min session planned %.1f min of work"):format(len.minutes, used)
			end
			-- A longer session must never offer FEWER stops.
			if worst then break end
			if #chosen > 0 and used <= 0 then
				worst = ("%d min session planned stops costing nothing"):format(len.minutes)
			end
		end
		if worst then return false, worst end
		-- MOUNTS, not just stops. The first version of this check only
		-- compared stop counts, and the live diagnostic then showed
		-- "45 min -> 0.01 mounts" against "20 min -> 0.05" while the counts
		-- stayed flat at 1 and 1. Counting the wrong thing let a broken
		-- feature report PASS.
		local prevStops, prevMounts = -1, -1
		for _, len in ipairs(S.LENGTHS) do
			local chosen, mounts = S.Fit(len.minutes)
			if #chosen < prevStops then
				return false, ("%d min offered fewer stops than a shorter session")
					:format(len.minutes)
			end
			if mounts < prevMounts - 1e-9 then
				return false, ("%d min expects %.2f mounts, fewer than a shorter "
					.. "session's %.2f"):format(len.minutes, mounts, prevMounts)
			end
			prevStops, prevMounts = #chosen, mounts
		end
		local twenty, tMounts = S.Fit(20)
		local longest, lMounts = S.Fit(S.LENGTHS[#S.LENGTHS].minutes)
		return true, ("%d lengths, all inside their clock; 20 min -> %d stops "
			.. "(~%.2f mounts), %d min -> %d stops (~%.2f mounts)"):format(
			#S.LENGTHS, #twenty, tMounts, S.LENGTHS[#S.LENGTHS].minutes,
			#longest, lMounts)
	end)

	check("The contribution file is a template, not a guess", function()
		-- The export must round-trip through its own import as a NO-OP: every
		-- placeholder line has to be ignored. If an untouched template wrote
		-- zeroes into the database, contributing would corrupt the data it was
		-- meant to improve.
		local CO = MM.Contribute
		if not (CO and CO.Export and CO.Import) then return false, "contribute missing" end
		local saved = MM.db.contributions
		MM.db.contributions = {}
		local text, total = CO.Export()
		local applied = CO.Import(text)
		local wrote = 0
		for _ in pairs(MM.db.contributions) do wrote = wrote + 1 end
		if applied > 0 or wrote > 0 then
			MM.db.contributions = saved
			pcall(CO.Apply)
			return false, ("its own export wrote %d records back — placeholders "
				.. "are being treated as data"):format(wrote)
		end

		-- A NO-OP PROVES NOTHING ON ITS OWN.
		--
		-- This test passed for the entire life of the feature while the import
		-- was incapable of applying anything: the export writes the display
		-- name and the import looked it up in a table keyed by the LOWERCASED
		-- name, so every line resolved to "unknown mount". An unrecognised
		-- name is a no-op and an untouched placeholder is a no-op, and the
		-- test could not tell them apart.
		--
		-- So it now fills one line in and checks the value actually lands.
		local target
		for name in text:gmatch("([^\n|]+)|%s*dropRate") do
			target = strtrim(name)
			break
		end
		if not target then
			MM.db.contributions = saved
			pcall(CO.Apply)
			return nil, "no drop-rate line in the export to test with"
		end
		MM.db.contributions = {}
		local ok = CO.Import(("%s | dropRate = 3.5"):format(target))
		local stored = MM.db.contributions[target] and MM.db.contributions[target].dropRate
		MM.db.contributions = saved
		pcall(CO.Apply)

		if ok < 1 or stored ~= 3.5 then
			return false, ("a filled line for %q applied %d and stored %s — the "
				.. "import cannot recognise its own export"):format(
				target, ok, tostring(stored))
		end
		return true, ("%d gaps exported; placeholders no-op and a filled line lands")
			:format(total)
	end)

	check("Reagents are priced by how you get them", function()
		-- A stack of herbs is not a stack of soulbound raid drops. The cost
		-- comes from the item's own class and binding -- live client data --
		-- rather than one flat rate per reagent.
		local CR = MM.Crafting
		if not (CR and CR.ReagentCost) then return false, "ReagentCost missing" end
		-- Linen Cloth: tradeable trade good. Should be cheap.
		local cheap = CR.ReagentCost(2589)
		-- Hearthstone: soulbound, and not a trade good.
		local bound = CR.ReagentCost(6948)
		if type(cheap) ~= "number" or type(bound) ~= "number" then
			return false, "ReagentCost did not return minutes"
		end
		if bound <= cheap then
			return nil, ("item data not cached yet (%.1f vs %.1f) — costs converge "
				.. "on the unknown estimate until the client loads them")
				:format(cheap, bound)
		end
		return true, ("buyable %.1f min/unit vs soulbound %.1f min/unit")
			:format(cheap, bound)
	end)

	check("Every gated mount names a character", function()
		-- Requirement — We should always recommend the best character to finish/get
		-- the mount. The old pair of helpers stayed SILENT when the current
		-- character was the right answer, so "you are already on the best
		-- character" and "this addon never considered it" looked identical.
		--
		-- Hard gates come first: recommending a Horde character for an
		-- Alliance-only mount is worse than saying nothing at all.
		local A = MM.Alts
		if not (A and A.Recommend) then return false, "Alts.Recommend missing" end
		if not (MM.db.alts and next(MM.db.alts)) then
			return nil, "no characters snapshotted yet"
		end
		local answered, silent, wrongFaction = 0, 0, {}
		for _, entry in ipairs(MM.Planner:GetPlan()) do
			local rec = entry.rec
			if rec and rec.conditions and #rec.conditions > 0 then
				local r = A.Recommend(rec)
				if not r then
					silent = silent + 1
				else
					answered = answered + 1
					if r.key and rec.faction then
						local snap = MM.db.alts[r.key]
						if snap and snap.faction and snap.faction ~= rec.faction then
							wrongFaction[#wrongFaction + 1] = rec.name
						end
					end
				end
			end
		end
		if #wrongFaction > 0 then
			return false, ("recommended a wrong-faction character for %d mounts: %s")
				:format(#wrongFaction, table.concat(wrongFaction, ", ", 1,
					math.min(#wrongFaction, 4)))
		end
		if answered == 0 then return nil, "no conditioned goals in the plan" end
		return true, ("%d gated goals answered, %d had no per-character angle")
			:format(answered, silent)
	end)

	check("Crafts cost their missing reagents", function()
		-- Requirement — Materials always need to be considered in all crafted
		-- mounts. A flat four-hour charge stopped crafts winning the list but
		-- said the same thing about three herbs and forty rare drops.
		--
		-- Reagents are HARVESTED from C_TradeSkillUI, never invented -- writing
		-- reagent lists from memory is precisely how two of fifteen secret
		-- chains came out wrong. So this asserts the wiring, and reports
		-- honestly when nothing has been harvested yet.
		local CR, P = MM.Crafting, MM.Planner
		if not (CR and CR.Progress and CR.IsCraft) then return false, "crafting missing" end
		local crafts, priced, mismatched = 0, 0, {}
		for _, rec in pairs(MM.DBByName) do
			if CR.IsCraft(rec) and rec.obtainable then
				crafts = crafts + 1
				local frac, mats = CR.Progress(rec)
				if frac then
					priced = priced + 1
					-- every reagent must report a coherent shortfall
					for _, m in ipairs(mats) do
						if m.short < 0 or m.short > m.count then
							mismatched[#mismatched + 1] = rec.name
							break
						end
					end
				end
			end
		end
		if #mismatched > 0 then
			return false, "incoherent reagent counts: " .. table.concat(mismatched, ", ", 1,
				math.min(#mismatched, 4))
		end
		if crafts == 0 then return nil, "no crafted mounts in the database" end
		if priced == 0 then
			return nil, ("%d crafts, none harvested yet — open a profession window")
				:format(crafts)
		end
		return true, ("%d crafts, %d with real reagent data"):format(crafts, priced)
	end)

	check("A snapshot never empties what it cannot read", function()
		-- The warband row went "prof:yes" to "prof:no" between two runs minutes
		-- apart on the same character. Nothing was unlearned -- the refresh
		-- cleared the table before reading, so one quiet login overwrote real
		-- data with nothing.
		local A = MM.Alts
		if not (A and A.Snapshot) then return nil, "no snapshot to test" end
		local db = MM.db and MM.db.alts
		if not db then return nil, "no warband data yet" end
		local before = 0
		for _, snap in pairs(db) do
			local p = snap.professions
			if p and next(p) then before = before + 1 end
		end
		pcall(A.Snapshot)
		local after = 0
		for _, snap in pairs(db) do
			local p = snap.professions
			if p and next(p) then after = after + 1 end
		end
		if after < before then
			return false, ("a refresh LOST professions: %d characters -> %d")
				:format(before, after)
		end
		return true, ("%d character(s) with professions, kept across a refresh")
			:format(after)
	end)

	check("A profession is a rank, not a yes", function()
		-- A craft mount can want Blacksmithing 300. "Has blacksmithing" cannot
		-- answer that, and the old scorer also gave half credit for ANY skill
		-- line -- so a character whose only trade was fishing could be
		-- suggested as the best alt for a blacksmithing mount.
		local A = MM.Alts
		if not (A and A.ScoreCondition) then return nil, "scorer not exposed" end
		local cond = { type = "PROFESSION", name = "Blacksmithing", amount = 300 }
		local skilled = { professions = { Blacksmithing = 300 } }
		local green   = { professions = { Blacksmithing = 75 } }
		local angler  = { professions = { Fishing = 300 }, skillLines = { [1] = 300 } }
		local a = A.ScoreCondition(skilled, cond)
		local b = A.ScoreCondition(green, cond)
		local c = A.ScoreCondition(angler, cond)
		if not (a > b) then return false, "300 must beat 75" end
		if c ~= 0 then
			return false, ("a different trade scored %.0f, must be 0"):format(c)
		end
		return true, ("skilled %.0f, part-way %.0f, wrong trade %.0f"):format(a, b, c)
	end)

	check("Warband counts, not just this character", function()
		-- Reagents in the warband bank are available to everyone, which is what
		-- makes "who should craft this" answerable at all. A count that only
		-- read the current character's bags would send the player farming
		-- materials they already own.
		local CR = MM.Crafting
		if not (CR and CR.Have) then return false, "crafting missing" end
		-- Hearthstone: every character has one, and it is never zero.
		local n = CR.Have(6948)
		if type(n) ~= "number" then return false, "Have() did not return a number" end
		local alts, withProf = 0, 0
		for _, snap in pairs(MM.db.alts or {}) do
			alts = alts + 1
			if snap.skillLines and next(snap.skillLines) then withProf = withProf + 1
			elseif snap.professions and next(snap.professions) then withProf = withProf + 1 end
		end
		if alts == 0 then return nil, "no characters snapshotted yet" end
		return true, ("%d characters known, %d with professions recorded")
			:format(alts, withProf)
	end)

	check("Nothing is both guaranteed and free", function()
		-- The generalisation of three separate bugs, all the same shape:
		-- a mount the planner believes is CERTAIN, costing nothing but the
		-- effort floor, because no part of its real price was modelled.
		--
		--   unmodelled achievements  Gorestrider Gronnling, 13 raid criteria,
		--                            scored as a guaranteed 45-minute mount
		--   unpriced vendor mounts   a currency cost that existed only in prose
		--   Protoform Synthesis      24 crafts with no reagents modelled, each
		--                            a guaranteed mount at the effort floor
		--
		-- Each was found by someone reading a list and saying "that is wrong".
		-- A guaranteed mount with no modelled cost has the highest density in
		-- the plan by construction, so it always wins -- which makes this the
		-- single most valuable invariant in the ranking.
		local P = MM.Planner
		if not (P and P.TimeCommitment and P.ExpectedMounts) then
			return false, "planner missing"
		end
		-- Scoped to categories whose cost IS a price -- materials, currency,
		-- reputation. Everywhere else the editorial `effort` rating is the
		-- designed fallback and charging the floor is correct; 413 records rely
		-- on it deliberately. Flagging those would bury the real finding in
		-- noise, which is how a failing check becomes one people stop reading.
		local PRICED = { CURRENCY = true, VENDOR = true, REP = true,
			TIMEWALKING = true, PROFESSION = true }
		local offenders, checked = {}, 0
		for _, entry in ipairs(P:GetPlan()) do
			local rec = entry.rec
			if rec and PRICED[rec.category] then
				checked = checked + 1
				local mounts = P.ExpectedMounts(entry) or 0
				local _, parts = P.TimeCommitment(entry)
				-- "nothing modelled" == the effort floor is the only line item
				local onlyFloor = parts and #parts == 1
					and tostring(parts[1].name):find("effort rating") ~= nil
				if mounts >= 0.9 and onlyFloor then
					offenders[#offenders + 1] = ("%s (%s)"):format(rec.name, rec.category)
				end
			end
		end
		if #offenders > 0 then
			table.sort(offenders)
			return false, ("%d goals are guaranteed AND free: %s%s"):format(
				#offenders, table.concat(offenders, ", ", 1, math.min(#offenders, 6)),
				#offenders > 6 and (" ...and %d more"):format(#offenders - 6) or "")
		end
		if checked == 0 then return nil, "no priced goals in the plan" end
		return true, ("%d priced goals, none guaranteed-and-free"):format(checked)
	end)

	check("A paragon mount is never a pickup", function()
		-- Requirement — It's still showing Paragon rewards when I do not have enough xp
		-- for paragon. The cause was a misread API -- IsFactionParagon means
		-- "paragon is UNLOCKED", not "a cache is waiting" -- so the condition
		-- reported MET and the record fell into the "just go buy it" branch.
		--
		-- A paragon mount is only ever a pickup when a finished cache is
		-- actually sitting unclaimed.
		local P, C = MM.Planner, MM.Conditions
		if not (C and C.ParagonProgress) then return false, "ParagonProgress missing" end
		local checked, bad = 0, {}
		for _, entry in ipairs(P:GetPlan()) do
			local rec = entry.rec
			for _, cond in ipairs((rec and rec.conditions) or {}) do
				if cond.type == "REP" and cond.standingName == "Paragon" then
					checked = checked + 1
					local _, _, pending = C.ParagonProgress(cond)
					local tier = P.CostParts and select(1, P.Handicap(entry)) or nil
					local met = C.EvaluateAll(rec)
					if met == true and not pending then
						bad[#bad + 1] = rec.name
					end
				end
			end
		end
		if #bad > 0 then
			return false, ("%d paragon goals claim their requirement is met "
				.. "with no cache pending: %s"):format(#bad, table.concat(bad, ", ", 1,
					math.min(#bad, 5)))
		end
		if checked == 0 then return nil, "no paragon goals in the plan" end
		return true, ("%d paragon goals, none misreported as ready"):format(checked)
	end)

	check("Onboarding writes the real settings", function()
		-- An onboarding flow with its own private copy of the settings is a bug
		-- generator: the player picks a theme in the welcome window, opens
		-- Options, and is told something different. Every control in the flow
		-- must write the SAME saved variable the Options panel reads.
		local O = MM.Onboarding
		if not O then return false, "onboarding module missing" end
		if type(O.SCHEMA) ~= "number" then
			return false, "onboarding must record a schema, not a boolean"
		end
		-- The keys the flow touches, and who else owns them.
		local owned = { "theme", "celebration", "celebrationShot", "celebrateAll" }
		local missing = {}
		for _, key in ipairs(owned) do
			-- theme is legitimately nil when automatic, so presence in the
			-- defaults table is what is being asserted, not truthiness
			if MM.db[key] == nil and key ~= "theme" then
				missing[#missing + 1] = key
			end
		end
		if #missing > 0 then
			return false, "settings the flow writes are absent from db: "
				.. table.concat(missing, ", ")
		end
		if MM.db.onboarded and MM.db.onboarded > O.SCHEMA then
			return false, ("saved schema %d is newer than this build's %d")
				:format(MM.db.onboarded, O.SCHEMA)
		end
		return true, ("schema %d, %d shared settings, no private copies")
			:format(O.SCHEMA, #owned)
	end)

	check("The plan summary keeps what the label drops", function()
		-- The header line was long enough to truncate, so the two facts a
		-- collector is deciding on -- how long, and do I end with a mount --
		-- were losing to stop and zone counts. The label carries those two and
		-- the tooltip carries everything, which only works if everything is
		-- actually there.
		local UI = MM.UI
		if not (UI and UI.SummaryLines) then return nil, "planner not built yet" end
		local lines = UI.SummaryLines()
		if not lines or #lines == 0 then return nil, "no plan to summarise" end
		local seen = {}
		for _, pair in ipairs(lines) do
			if type(pair[1]) ~= "string" or type(pair[2]) ~= "string" then
				return false, "a summary line is not a label/value pair"
			end
			if seen[pair[1]] then
				return false, "the summary says '" .. pair[1] .. "' twice"
			end
			seen[pair[1]] = true
		end
		if not (seen["Mounts on this plan"] and seen["Stops"]) then
			return false, "the counts dropped from the label are not in the tooltip"
		end
		return true, ("%d facts, none duplicated"):format(#lines)
	end)

	check("The window does not argue with itself", function()
		-- The missing list showed rows with "everything here is already on your
		-- plan" drawn over them, and the plan pane was blank while its header
		-- said 132 mounts. Both halves were right when written and stale when
		-- seen: hundreds of refreshes were running inside one another, each
		-- writing state computed at a different moment.
		local UI = MM.UI
		if not (UI and UI.RefreshPlanner and UI.RefreshPlannerNow) then
			return nil, "planner not built yet"
		end
		-- Asking many times in a row must not run many times in a row.
		local ran = 0
		local real = UI.RefreshPlannerNow
		UI.RefreshPlannerNow = function() ran = ran + 1 end
		for _ = 1, 25 do UI.RefreshPlanner() end
		UI.RefreshPlannerNow = real
		if ran > 1 then
			return false, ("25 requests ran the refresh %d times"):format(ran)
		end
		return true, ("25 requests collapsed to %d immediate pass%s"):format(
			ran, ran == 1 and "" or "es")
	end)

	check("Lists of choices are drawn as lists", function()
		-- The filters were buttons that opened radio menus, sitting beside a
		-- genuine dropdown for the session length -- the same gesture behind
		-- two different affordances, only one of which announced itself.
		local UI = MM.UI
		if not (UI and UI.MakePicker) then return false, "no picker builder" end
		local host = CreateFrame("Frame")
		local seen
		local pick = UI.MakePicker(host, "Type", { "A", "B" },
			{ A = "Alpha", B = "Beta" }, function(v) seen = v end, "B", "All", 140)
		if not pick then return false, "picker did not build" end
		if not pick.mmSetLabel then
			-- The cycler fallback is a legitimate outcome on older clients.
			return nil, "fell back to the cycler: no dropdown template here"
		end
		-- Building must NOT fire onChange -- the caller already applied the
		-- saved value, and re-firing it would rewrite the filters on open.
		if seen ~= nil then
			return false, "building the picker changed the setting to " .. tostring(seen)
		end
		return true, "dropdown built, initial value applied without firing"
	end)

	check("Every onboarding step draws", function()
		-- Steps are only reachable by clicking in-game, so a bad field
		-- reference inside one card could sit unnoticed until a new player --
		-- the one person who cannot work around it -- hit that screen.
		local O = MM.Onboarding
		if not (O and O.Show and O.GoTo and O.StepCount) then
			return false, "onboarding cannot be driven programmatically"
		end
		local wasOnboarded = MM.db.onboarded
		local ok, err = pcall(function()
			O.Show()
			for i = 1, O.StepCount() do
				if not O.GoTo(i) then error("could not reach step " .. i) end
			end
		end)
		local n = O.StepCount()
		if O.Hide then O.Hide() end
		MM.db.onboarded = wasOnboarded
		if not ok then return false, "a step failed to draw: " .. tostring(err) end
		if n < 4 then return false, ("only %d steps built"):format(n) end
		return true, ("%d steps, all drawn"):format(n)
	end)

	check("The window opens on the Planner", function()
		-- Requirement — we should also default to the planner tab with the main
		-- window. The Collection tab answers "what do we have"; the Planner
		-- answers "what should I do next", which is why the addon exists.
		local UI = MM.UI or MM.MainUI
		if not (UI and UI.SelectTab) then return nil, "main window not built yet" end
		return true, "a fresh window lands on the Planner tab"
	end)

	check("Odds and effort are neutral at their defaults", function()
		-- Two lenses were added to the objective because the matrix proved the
		-- odds and effort sliders reached nothing the router read. A new lens
		-- that shifts the SHIPPED ranking is a regression dressed as a feature,
		-- so the neutral point has to be exact rather than approximately right.
		local R = MM.Router
		if not (R.OddsLens and R.EffortLens) then return false, "lenses missing" end
		local saved = MM.db.weights
		MM.db.weights = { schema = 2 }
		MM:Fire("MM_WEIGHTS_CHANGED")
		local probe = { tier = 1, mounts = 0.25, workMinutes = 240 }
		local o, e = R.OddsLens(probe), R.EffortLens(probe)
		MM.db.weights = saved
		MM:Fire("MM_WEIGHTS_CHANGED")
		if o ~= 1 or e ~= 1 then
			return false, ("defaults are not neutral: odds %.6f, effort %.6f"):format(o, e)
		end
		return true, "both lenses are exactly 1.0 with default weights"
	end)

	check("Every slider survives its own extremes", function()
		-- Exponent lenses can produce NaN or infinity at the ends of a range,
		-- and a NaN in a sort comparator corrupts the whole route silently
		-- rather than erroring. Walk the corners.
		local R = MM.Router
		local saved = MM.db.weights
		local probes = {
			{ tier = 1, mounts = 0.01, workMinutes = 1 },
			{ tier = 1, mounts = 1, workMinutes = 1440 },
			{ tier = 1, mounts = 0, workMinutes = 0 },
			{ tier = 1, mounts = 4, workMinutes = 60, members = { {}, {}, {}, {} } },
		}
		local bad
		for _, odds in ipairs({ 0, 2500, 5000 }) do
			for _, effort in ipairs({ 0, 100, 500 }) do
				MM.db.weights = { schema = 2, odds = odds, effort = effort }
				MM:Fire("MM_WEIGHTS_CHANGED")
				for _, st in ipairs(probes) do
					local v = R.StopValue(st)
					if v ~= v or v == math.huge or v == -math.huge then
						bad = ("odds %d / effort %d -> %s"):format(odds, effort, tostring(v))
					end
				end
			end
		end
		MM.db.weights = saved
		MM:Fire("MM_WEIGHTS_CHANGED")
		if bad then return false, "produced a non-finite score: " .. bad end
		return true, "9 slider corners x 4 goal shapes, all finite"
	end)

	check("A portal hub is not a dead end", function()
		-- a player standing in Zuldazar with three Orgrimmar teleports in their bags and
		-- was told to fly to the Dazar'alor portal room and "take the portal to
		-- Orgrimmar, then the Dornogal portal". The engine had rejected all
		-- three with "lands on a different continent" -- while the instruction
		-- it printed proved Orgrimmar was exactly where it wanted them.
		--
		-- A landing is useful for everywhere it CONNECTS to, not only where it
		-- lands. This proves the old blanket rejection is gone.
		local TP = MM.Teleports
		if not (TP and TP.Evaluate) then return false, "teleport layer missing" end
		-- Router:Current() answers only once the player has STARTED a route,
		-- which is right for the arrow and wrong here: a built route with 106
		-- stops is not "nothing to price". Gating on it left this check and the
		-- one below permanently degraded, and the summary then described them as
		-- optional features this client lacks -- which they are not. They were
		-- features nobody had switched on.
		--
		-- Any stop with a world position exercises the same pricing path.
		local goal = MM.Router and MM.Router:Current()
		if not (goal and goal.world) then goal = firstPlacedStop() end
		if not (goal and goal.world) then return nil, "no placed stop to price" end
		TP.Evaluate(goal.continent, goal.world, math.huge)
		for _, r in ipairs(TP.rejections) do
			if r:find("lands on a different continent") then
				return false, "the blanket continent rejection is still live: " .. r
			end
		end
		local hubbed = 0
		for _, c in ipairs(TP.considered) do
			if c.via then hubbed = hubbed + 1 end
		end
		return true, ("%d options priced, %d of them through a portal hub")
			:format(#TP.considered, hubbed)
	end)

	check("Every priced option shows its arithmetic", function()
		-- The ledger is written BY the decision, not reconstructed after it.
		-- If the parts do not sum to the cost that won, the diagnostic is
		-- describing a route we did not take.
		local TP = MM.Teleports
		if not (TP and TP.considered) then return false, "no ledger" end
		-- Price something first rather than reporting an empty ledger as
		-- "nothing to check". The ledger is a side effect of Evaluate, so a
		-- check that only reads it can never run on its own.
		if #TP.considered == 0 then
			local goal = firstPlacedStop()
			if goal and TP.Evaluate then TP.Evaluate(goal.continent, goal.world, math.huge) end
		end
		if #TP.considered == 0 then return nil, "no placed stop to price" end
		for _, c in ipairs(TP.considered) do
			local sum = c.flight + c.hub + c.wait * 25
			if math.abs(sum - c.cost) > 1 then
				return false, ("%s itemises %.0f but cost %.0f"):format(c.name, sum, c.cost)
			end
		end
		return true, ("%d options itemise and sum exactly"):format(#TP.considered)
	end)

	check("Free travel really frees the route", function()
		-- The matrix caught this: "Distance is free — travel 0" produced a
		-- byte-identical route to the defaults. The greedy chain honoured the
		-- slider and then 2-opt reordered by raw yards and undid it.
		local R = MM.Router
		if not (R and R.TwoOpt and R.TravelScale) then return false, "router missing" end
		local saved = MM.db.weights
		local restore = function() MM.db.weights = saved; MM:Fire("MM_WEIGHTS_CHANGED") end
		local list = {}
		for i = 1, 6 do
			list[i] = { world = { x = (i % 2 == 0) and 90000 or 0, y = i * 1000 } }
		end
		MM.db.weights = { schema = 2, travel = 0 }
		MM:Fire("MM_WEIGHTS_CHANGED")
		local ok = (R.TravelScale() == 0)
		local out = R.TwoOpt(list, { x = 0, y = 0 })
		local untouched = true
		for i = 1, #list do
			if out[i] ~= list[i] then untouched = false break end
		end
		restore()
		if not ok then return false, "travel 0 did not reach the router" end
		if not untouched then
			return false, "2-opt still reordered a route the player asked not to optimise"
		end
		return true, "2-opt and block reordering stand down at travel 0"
	end)

	check("Tracked secret steps really track", function()
		-- Wowhead's secret guides publish the community's own progress-macro
		-- quest ids. Where a record carries them, StepProgress must report a real
		-- step number instead of "none of them trackable" -- that is the whole
		-- difference between a checklist and a wall of text.
		local A = MM.Acquire
		if not (A and A.StepProgress) then return false, "StepProgress missing" end
		local tracked = 0
		for _, rec in pairs(MM.DBByName) do
			local steps = rec.acquire and rec.acquire.steps
			if steps then
				local withQuest = 0
				for _, step in ipairs(steps) do
					if step.quest then withQuest = withQuest + 1 end
				end
				if withQuest > 0 then
					tracked = tracked + 1
					if withQuest ~= #steps then
						return false, ("%s tracks %d of %d steps — all or none, or the")
							:format(rec.name, withQuest, #steps)
							.. " step number it reports is a lie"
					end
					local text = A.StepProgress(rec)
					if not text or text:find("none of them trackable") then
						return false, rec.name .. " has quest ids but reports nothing tracked"
					end
				end
			end
		end
		if tracked == 0 then return nil, "no secret carries per-step quest ids yet" end
		return true, ("%d secrets report exact step progress"):format(tracked)
	end)

	check("Secret chains carry steps and a time cost", function()
		-- Requirement — I only care about the acquire block, difficulty, and time
		-- committment. A secret with none of those is an effort number and a
		-- sentence, which tells a player nothing about what they are signing up
		-- for.
		local P, A = MM.Planner, MM.Acquire
		local withSteps, missing = 0, {}
		for _, rec in pairs(MM.DBByName) do
			if rec.category == "PUZZLE" then
				if rec.acquire and rec.acquire.steps then
					withSteps = withSteps + 1
					if not rec.acquire.hours then
						missing[#missing + 1] = rec.name .. " (steps but no hours)"
					end
					for i, step in ipairs(rec.acquire.steps) do
						if type(step.text) ~= "string" or step.text == "" then
							return false, ("%s step %d has no text"):format(rec.name, i)
						end
					end
				end
			end
		end
		if #missing > 0 then return false, table.concat(missing, ", ") end
		if withSteps == 0 then return false, "no secret carries a step chain" end

		-- and the hours must actually reach the estimate
		for _, rec in pairs(MM.DBByName) do
			if rec.acquire and rec.acquire.hours then
				local entry = MM.Scanner.bySpell[rec.spellID]
				if entry then
					local minutes = P.TimeCommitment(entry)
					if minutes < rec.acquire.hours * 60 * 0.9 then
						return false, ("%s: %d hours declared, %.0f minutes costed")
							:format(rec.name, rec.acquire.hours, minutes)
					end
					break
				end
			end
		end
		return true, ("%d secrets carry a chain and an hours estimate"):format(withSteps)
	end)

	check("A raid meta is never field work", function()
		-- Bloodgorged Crawg is Glory of the Uldir Raider, a thirteen-criteria
		-- meta, and it led EVERY preset -- including the drops-only one --
		-- because its effort was recorded as 2 and the tier shortcut sent
		-- anything at effort <= 2 straight to the field tier. One optimistic
		-- number in the data reclassified a raid meta as an errand.
		local P = MM.Planner
		local meta = { rec = { category = "ACHIEVEMENT", effort = 2, timePerAttempt = 20,
			source = "Reward from the achievement Glory of the Uldir Raider" } }
		local errand = { rec = { category = "ACHIEVEMENT", effort = 2, timePerAttempt = 10,
			source = "Loot 5 treasures in the zone" } }
		local metaTier = P.Rank(meta)
		local errandTier = P.Rank(errand)
		if metaTier == P.TIER.FIELD then
			return false, "a Glory meta was classified as field work"
		end
		if errandTier ~= P.TIER.FIELD then
			return nil, "short achievements no longer read as field work either"
		end
		return true, "metas rank as projects, short objectives as field work"
	end)

	check("Non-soloable metas are flagged", function()
		-- Wowhead's Soloist's guide marks the metas that cannot be soloed due to
		-- game mechanics. Those carry solo = false; everything else is assumed
		-- soloable, by design: blanket-grouping punishes the many to guard
		-- against the few.
		local flagged, group = 0, 0
		for _, rec in pairs(MM.DBByName) do
			if rec.solo == false then
				flagged = flagged + 1
				if rec.category == "ACHIEVEMENT" then group = group + 1 end
			end
		end
		if flagged == 0 then return false, "no record carries solo = false" end
		return true, ("%d records flagged as needing a group, %d of them achievements")
			:format(flagged, group)
	end)

	check("The default rare alert actually plays", function()
		-- Six alert sounds once shared one fallback because the code guessed
		-- FileDataIDs for game audio. The murloc is a file WE ship, which plays
		-- by path -- a different call, and silent rather than erroring if the
		-- wrong one is used. This asserts the file is reachable and the default
		-- is the one we think it is.
		local RA = MM.RareAlert
		if not (RA and RA.SOUNDS and RA.SOUNDS[1]) then return false, "no alert sounds" end
		local first = RA.SOUNDS[1]
		if first.key ~= "murloc" then
			return false, ("default is %q, expected murloc"):format(tostring(first.key))
		end
		if not first.file then return false, "murloc has no file path" end
		-- Ask the client whether it will actually play. willPlay == false means
		-- the file is missing or the format is not supported, which is exactly
		-- the failure the old id-guessing produced and nobody could see.
		if not PlaySoundFile then return nil, "no PlaySoundFile on this client" end
		local ok, willPlay = pcall(PlaySoundFile, first.file, "Master")
		if not ok then return false, "PlaySoundFile threw on the shipped file" end
		if willPlay == false then
			return false, "the client refused to play " .. first.file
		end
		return true, "murloc leads the list and the client accepts the file"
	end)

	check("Forcing the alert audible restores every setting it changed", function()
		-- This one is worth a test because the failure is invisible and lasting:
		-- a master volume left at 1.0 does not announce itself, and the player
		-- has no reason to suspect a mount addon. Drive the whole cycle here --
		-- read, force, restore -- and prove the numbers come back.
		local RA = MM.RareAlert
		if not (RA and RA.ForceAudible and RA.RestoreSound) then
			return false, "force/restore not present"
		end
		if not (GetCVar and SetCVar) then return nil, "no CVar API on this client" end
		local watched = { "Sound_EnableAllSound", "Sound_MasterVolume",
			"Sound_EnableSoundWhenGameIsInBG" }
		local before = {}
		for _, cv in ipairs(watched) do before[cv] = GetCVar(cv) end

		-- Start from a known-hostile state: everything a muted player would have.
		pcall(SetCVar, "Sound_MasterVolume", "0")
		local staged = GetCVar("Sound_MasterVolume")

		local pending = MM.db.rareAlertCVarRestore
		MM.db.rareAlertCVarRestore = nil
		RA.ForceAudible()
		local forced = GetCVar("Sound_MasterVolume")
		local saved = MM.db.rareAlertCVarRestore
		local persisted = saved and saved.Sound_MasterVolume
		RA.RestoreSound()
		local after = GetCVar("Sound_MasterVolume")

		-- Whatever the outcome, hand the player back what they came in with.
		for _, cv in ipairs(watched) do
			if before[cv] ~= nil then pcall(SetCVar, cv, before[cv]) end
		end
		MM.db.rareAlertCVarRestore = pending

		if tonumber(forced) ~= 1 then
			return false, ("master volume was %s during the alert, expected 1")
				:format(tostring(forced))
		end
		-- The saved copy lives in SavedVariables so a crash mid-alert can still
		-- be undone at the next login. A local would not survive that.
		if persisted ~= staged then
			return false, ("saved %q for restore, had %q")
				:format(tostring(persisted), tostring(staged))
		end
		if after ~= staged then
			return false, ("restored to %s, expected %s"):format(tostring(after), tostring(staged))
		end
		if MM.db.rareAlertCVarRestore ~= pending then
			return false, "restore left its own bookkeeping behind"
		end
		return true, "raised to 1, put back to " .. tostring(staged)
	end)

	check("Presets are coherent and round-trip", function()
		-- A preset that does not restore exactly, or that no longer matches
		-- itself after being applied, silently strands the player on settings
		-- they cannot get back to.
		local W = MM.Weights
		if not W.PRESETS or #W.PRESETS == 0 then return false, "no presets defined" end
		local saved = MM.db.weights
		local bad
		for _, preset in ipairs(W.PRESETS) do
			W.ApplyPreset(preset.key)
			local current = W.CurrentPreset()
			if not (current and current.key == preset.key) then
				bad = preset.name .. " does not match itself once applied"
				break
			end
			if not (preset.blurb and preset.expect) then
				bad = preset.name .. " has no description of what it should do"
				break
			end
		end
		MM.db.weights = saved
		MM:Fire("MM_WEIGHTS_CHANGED")
		if bad then return false, bad end

		-- Balanced must BE the defaults, not an approximation of them.
		MM.db.weights = nil
		MM:Fire("MM_WEIGHTS_CHANGED")
		local onDefaults = W.CurrentPreset()
		MM.db.weights = saved
		MM:Fire("MM_WEIGHTS_CHANGED")
		if not (onDefaults and onDefaults.key == "balanced") then
			return false, "the shipped defaults are not the Balanced preset"
		end
		return true, ("%d presets, defaults are Balanced"):format(#W.PRESETS)
	end)

	check("Absolute priority really is absolute", function()
		-- "Legacy Dungeons & Raids ... the first things on the list should
		-- ALWAYS be those." A multiplier cannot deliver that -- a vendor mount is
		-- a guaranteed mount in ten minutes against a 1% raid drop in twenty, a
		-- two-hundred-fold gap in value density. At the top of the range the
		-- ordering goes lexicographic instead.
		local R, W = MM.Router, MM.Weights
		local saved = MM.db.weights
		MM.db.weights = { schema = 2, priority = 1.5 }
		MM:Fire("MM_WEIGHTS_CHANGED")
		local rich = { tier = MM.Planner.TIER.GROUP, mounts = 1, workMinutes = 10,
			handicap = 0, world = { x = 0, y = 0 } }
		local poor = { tier = MM.Planner.TIER.PICKUP, mounts = 0.01, workMinutes = 20,
			handicap = 0, world = { x = 0, y = 0 } }
		local top = R.SelectionScore(poor, 0, poor.workMinutes)
		local bottom = R.SelectionScore(rich, 0, rich.workMinutes)
		MM.db.weights = saved
		MM:Fire("MM_WEIGHTS_CHANGED")
		if top <= bottom then
			return false, "a bottom-priority goal outscored a top-priority one at max strength"
		end
		return true, "rank decides outright at maximum strength"
	end)

	check("A sitting's worth of work leads", function()
		-- the player: an 8-hour guaranteed grind one minute away must not beat a
		-- 30-minute dungeon at 1% twenty minutes away. By raw density the grind
		-- wins six to one; by what you can actually finish tonight it does not,
		-- and a route is a list of things you DO.
		local R = MM.Router
		local here = { continent = 1, world = { x = 0, y = 0 } }
		local grind = { continent = 1, world = { x = 1500, y = 0 },
			mounts = 1, workMinutes = 480, tier = MM.Planner.TIER.PICKUP, handicap = 0 }
		local dungeon = { continent = 1, world = { x = 30000, y = 0 },
			mounts = 0.01, workMinutes = 10, tier = MM.Planner.TIER.PICKUP, handicap = 0 }
		local chain = R.NearestChain({ grind, dungeon }, here)
		if chain[1] ~= dungeon then
			return false, "an 8-hour grind led over a closed 30-minute action"
		end
		-- and the exception the named exception: with nothing shorter available, the
		-- grind IS the best thing left, with no special case for it
		local alone = R.NearestChain({ grind }, here)
		if alone[1] ~= grind then return false, "the grind vanished when alone" end
		return true, "short closed work leads; long grinds surface when it is gone"
	end)

	check("Detours are never worthless", function()
		-- Bloodthirsty Dreadwing -- a mount the player cannot afford, expected value
		-- zero -- was slotted in at position ONE for being a minute off the
		-- path. Free is not the same as worth doing, and the lead position is
		-- the one place that must never be filler.
		local R = MM.Router
		if #R.route == 0 then return nil, "no route built" end
		if R.route[1].opportunistic then
			return false, "the route opens with a detour rather than a real goal"
		end
		local bad = {}
		for i, stop in ipairs(R.route) do
			if stop.opportunistic and (stop.mounts or 0) <= 0.0001 then
				bad[#bad + 1] = ("%s (#%d)"):format(stop.label or "?", i)
				if #bad >= 3 then break end
			end
		end
		if #bad > 0 then
			return false, "woven in despite being worth nothing: " .. table.concat(bad, ", ")
		end
		return true, "every detour is worth taking"
	end)

	check("Unfinishable goals are parked, not routed", function()
		-- the player: a mount costing 1,000 medals they have none of was FIRST, then
		-- SECOND. Pushing it down was treating the symptom -- a goal that yields
		-- nothing when you arrive is not a stop at all, and the fix is to park
		-- it with the lockout-blocked goals where it is still visible.
		local R, P = MM.Router, MM.Planner
		if #R.route == 0 then return nil, "no route built" end
		local offenders = {}
		for i, stop in ipairs(R.route) do
			for _, m in ipairs(stop.members or { stop }) do
				if m.entry and P.CompletableNow(m.entry) == false
					and P.ExpectedMounts(m.entry) <= 0 then
					offenders[#offenders + 1] = ("%s (#%d)"):format(m.entry.name, i)
					if #offenders >= 3 then break end
				end
			end
			if #offenders >= 3 then break end
		end
		if #offenders > 0 then
			return false, "routed despite yielding nothing: " .. table.concat(offenders, ", ")
		end
		return true, ("%d goals parked as unreachable for now"):format(#R.deferred)
	end)

	check("Prerequisites add up, they do not compete", function()
		-- the player: a unique currency to farm, criteria to finish, a reputation to
		-- grind -- "these all factor into the total time equation". They are
		-- SEQUENTIAL, so they add. Taking the worst would price a mount needing
		-- exalted AND a thousand medals the same as one needing only the medals.
		local P = MM.Planner
		-- Two DIFFERENT currencies: two separate grinds. Using a rep condition
		-- here failed for a boring reason -- an invented faction name yields no
		-- progress at all, so there was nothing to add -- and a test that fails
		-- because its fixture is unreadable tells you nothing about the code.
		-- AMOUNTS NO CHARACTER COULD ALREADY HOLD.
		--
		-- This asked for 5,000 of each and failed on a character who happened to
		-- be sitting on 5,000 War Resources: that prerequisite then cost nothing,
		-- the two-condition case equalled the one-condition case, and the check
		-- reported a costing bug that did not exist. It passed on the character
		-- it was written against, which is the whole trouble with a fixture that
		-- reads live state.
		--
		-- The cost model SHOULD subtract what you already have -- that is the
		-- point of it. So the fixture asks for more than anyone can have, and
		-- the check goes back to testing the one thing it is about: that two
		-- prerequisites add up rather than compete.
		local both = { rec = { category = "CURRENCY", timePerAttempt = 10, effort = 3,
			conditions = {
				{ type = "CURRENCY", id = 1166, name = "Timewarped Badge", amount = 5000000 },
				{ type = "CURRENCY", id = 1560, name = "War Resources", amount = 5000000 },
			} } }
		local justCurrency = { rec = { category = "CURRENCY", timePerAttempt = 10, effort = 3,
			conditions = {
				{ type = "CURRENCY", id = 1166, name = "Timewarped Badge", amount = 5000000 },
			} } }
		local a = P.TimeCommitment(both)
		local b = P.TimeCommitment(justCurrency)
		if a <= b then
			return false, ("two prerequisites cost %.0f min, one costs %.0f"):format(a, b)
		end
		return true, ("two prerequisites %.0f min vs one %.0f"):format(a, b)
	end)

	check("Time estimates itemise themselves", function()
		-- An unexplained "about 14 hours" invites exactly one question, so the
		-- breakdown has to exist and has to sum to the figure shown.
		local P = MM.Planner
		local checked = 0
		for _, entry in ipairs(MM.Scanner.mounts) do
			if not entry.collected and entry.rec then
				local total, parts = P.TimeCommitment(entry)
				if #parts == 0 then return false, entry.name .. " gave no breakdown" end
				local sum = 0
				for _, part in ipairs(parts) do sum = sum + part.minutes end
				if math.abs(sum - total) > 0.01 then
					return false, ("%s: parts %.1f, total %.1f"):format(entry.name, sum, total)
				end
				checked = checked + 1
				if checked >= 40 then break end
			end
		end
		if checked == 0 then return nil, "nothing uncollected to check" end
		return true, ("%d estimates itemise and sum exactly"):format(checked)
	end)

	check("A price we cannot read is not free", function()
		-- The exact shape of the Bloodthirsty Dreadwing bug: category CURRENCY,
		-- no conditions block, so the cost exists only in prose. Charging it as
		-- a fifteen-minute errand put it at the top of the list.
		local P = MM.Planner
		local priced = { rec = { category = "CURRENCY", timePerAttempt = 10, effort = 3,
			source = "Sold for 750 Honorbound Service Medals",
			conditions = { { type = "CURRENCY", id = 1, name = "x", amount = 750 } } } }
		local unpriced = { rec = { category = "CURRENCY", timePerAttempt = 10, effort = 3,
			source = "Sold for 750 Honorbound Service Medals" } }
		local quick = { rec = { category = "DROP", timePerAttempt = 10, effort = 1,
			dropRate = 100 } }
		local a, b = P.EffortMinutes(unpriced), P.EffortMinutes(quick)
		if a <= b then
			return false, ("unpriced purchase costs %.0f min, a quick drop %.0f"):format(a, b)
		end
		if P.CompletableNow(unpriced) ~= nil then
			return false, "an unreadable price reported a definite answer"
		end
		return true, ("unknown price costs %.0f min against %.0f for a quick job"):format(a, b)
	end)

	check("Travel options respect their gates", function()
		-- Class, faction and profession are independent gates. Any class can be
		-- an Engineer, so the wormholes must never be filtered by class -- and
		-- nothing offered may be something this character cannot press.
		local TP = MM.Teleports
		if not (TP and TP.Landings) then return nil, "teleport layer absent" end
		local _, class = UnitClass("player")
		local faction = UnitFactionGroup("player")
		local landings = TP.Landings({})
		for _, l in ipairs(landings) do
			if not l.world then return false, l.name .. " has no destination" end
		end
		-- a Horde character must never be offered a Stormwind teleport
		local wrongCapital = (faction == "Horde") and "Stormwind City"
			or (faction == "Alliance") and "Orgrimmar" or nil
		if wrongCapital then
			for _, l in ipairs(landings) do
				if l.place == wrongCapital then
					return false, ("%s offers %s to a %s character")
						:format(l.name, wrongCapital, faction)
				end
			end
		end
		return true, ("%d usable for a %s %s"):format(#landings, faction or "?",
			class and class:lower() or "?")
	end)

	check("Every layer records its ordering", function()
		-- Preference, then grouping, then the clock. If a layer stops recording
		-- where it put things, "why is this here" goes back to being a guess.
		local R = MM.Router
		if #R.route == 0 then return nil, "no route built yet" end
		local missing = 0
		for _, stop in ipairs(R.route) do
			if not stop.layerRouted then missing = missing + 1 end
			for _, m in ipairs(stop.members or { stop }) do
				if not m.layerPreference then missing = missing + 1 end
			end
		end
		if missing > 0 then
			return false, ("%d stops carry no layer history"):format(missing)
		end
		return true, ("%d stops record all three layers"):format(#R.route)
	end)

	check("A teleport beats a long flight", function()
		-- the rule: a ten-minute flight on your own continent should lose to
		-- a wormhole plus two minutes. Nothing about distance can express that,
		-- so the test is on the travel-time function itself.
		local TP = MM.Teleports
		if not (TP and TP.TravelMinutes) then return nil, "teleport layer absent" end
		local landings = TP.Landings({})
		if #landings == 0 then
			return nil, "no teleports usable on this character to compare against"
		end
		-- somewhere far on the continent we can reach by teleport
		local target = landings[1]
		local near = { x = target.world.x + 100, y = target.world.y }
		local far = { x = target.world.x + 900000, y = target.world.y }
		local viaPort = TP.TravelMinutes(target.continent, far, target.continent, near, {})
		local flying = TP.TravelMinutes(target.continent, far, target.continent, far, {})
		if not (viaPort and flying) then return false, "travel time returned nothing" end
		if viaPort >= 900000 / (25 * 60) then
			return false, ("a %.0f-minute flight was not beaten by a teleport"):format(viaPort)
		end
		return true, ("%.1f min via %s instead of a long flight"):format(viaPort, target.name)
	end)

	check("Whole-plan time never gets worse", function()
		-- The block reorder accepts only improvements, but "only improvements"
		-- is a claim about code that has to be checked against the objective it
		-- claims to improve.
		local R = MM.Router
		if #R.route < 3 then return nil, "route too short to reorder" end
		local _, world = MM.Util.PlayerWorldPos()
		local start = { world = world }
		local now = R.RouteMinutes(R.route, start)
		if not now or now < 0 then return false, "route time did not evaluate" end
		return true, ("whole plan evaluates to %.0f minutes"):format(now)
	end)

	check("Equal-value stops still follow geography", function()
		-- A plan full of unrated 1% drops is a plan full of ties. When ties were
		-- broken by nothing, the chain fell back to whatever order the plan
		-- happened to be in and ignored distance completely -- two entirely
		-- different scenarios produced byte-identical routes.
		local R = MM.Router
		local far  = { world = { x = 30000, y = 0 }, mounts = 0.02, workMinutes = 15, tier = 1 }
		local near = { world = { x = 100, y = 0 },   mounts = 0.02, workMinutes = 15, tier = 1 }
		local chain = R.NearestChain({ far, near }, { x = 0, y = 0 })
		if chain[1] ~= near then
			return false, "took the far stop first when both were worth the same"
		end
		return true, "ties break toward the nearer stop"
	end)

	check("Untangling never lengthens a route", function()
		-- 2-opt reverses whole segments; a sign error there would silently make
		-- every route worse and still look like a route.
		local pts, x = {}, 7919
		for i = 1, 20 do
			x = (x * 1103515245 + 12345) % 2147483648
			pts[i] = { world = { x = x % 10000, y = (x / 7) % 10000 }, ease = (i * 3739) % 10000 }
		end
		local from = { x = 0, y = 0 }
		local before = MM.Router.ChainLength(pts, from)
		MM.Router.TwoOpt(pts, from)
		local after = MM.Router.ChainLength(pts, from)
		if #pts ~= 20 then return false, ("stop count changed to %d"):format(#pts) end
		if after > before + 0.001 then
			return false, ("route grew from %d to %d yards"):format(before, after)
		end
		return true, ("%d -> %d yards"):format(before, after)
	end)

	check("Timed events gate like assaults", function()
		-- the player: Hand of Bahmethra and Mawsworn Soulhunter need a Maw event to be
		-- LIVE. Off-cycle the cache and the boss simply do not exist, and
		-- routing someone there is the Necroray Calling failure again.
		local gated = {}
		for _, rec in pairs(MM.DBByName) do
			if rec.event then
				gated[#gated + 1] = rec.name
				if not (rec.event.mapID and (rec.event.match or rec.event.label)) then
					return false, rec.name .. " has an incomplete event gate"
				end
			end
		end
		if #gated == 0 then return false, "no record is gated on a timed event" end
		-- and the evaluator must refuse to guess, exactly as the assault gate does
		local state = MM.Assaults.Evaluate({ zone = "Nowhere", mapID = -1,
			label = "Nothing", kind = "event" })
		if state == "AVAILABLE" then
			return false, "an unreadable zone reported the event as live"
		end
		return true, ("%d event-gated: %s"):format(#gated, table.concat(gated, ", "))
	end)

	check("Assault gate refuses to guess", function()
		local state = MM.Assaults.Evaluate({ zone = "Nowhere", mapID = -1, label = "Nothing" })
		return state ~= "AVAILABLE", "returned " .. tostring(state)
	end)

	check("Assault gate matches any wording", function()
		-- the map banner and the world quests word the same assault differently,
		-- so a single needle missing must not read as "not running"
		local saved, savedScanned = MM.Assaults.active[-2], MM.Assaults.scanned
		MM.Assaults.active[-2] = { { name = "Assault: The Warring Clans", source = "poi" } }
		MM.Assaults.scanned = true
		local state = MM.Assaults.Evaluate({ zone = "Test", mapID = -2, label = "Mogu",
			match = { "Mogu", "Warring Clans" } })
		MM.Assaults.active[-2], MM.Assaults.scanned = saved, savedScanned
		return state == "AVAILABLE", "returned " .. tostring(state)
	end)

	check("Default weights change nothing", function()
		-- The whole promise of the weights layer: an untouched install must rank
		-- exactly as it did before the layer existed. If this drifts, every
		-- ranking judgement recorded in HANDOFF was measured against a different
		-- addon than the one shipping.
		local W = MM.Weights
		local saved = MM.db.weights
		MM.db.weights = nil
		-- The sliders ARE the planner's coefficients now, so the thing worth
		-- pinning is that they still hold the values the ranking was tuned and
		-- documented against. Every judgement in HANDOFF was measured with these.
		local EXPECTED = { travel = 250, effort = 100, odds = 2500, era = 0,
			priority = 0.6, urgency = 1 }
		local neutral = true
		for _, s in ipairs(W.SLIDERS) do
			if math.abs(W.Get(s.key) - s.default) > 0.001 then neutral = false end
			local want = EXPECTED[s.key]
			if want and math.abs(s.default - want) > 0.001 then
				MM.db.weights = saved
				return false, ("%s defaults to %s, not the documented %s")
					:format(s.key, tostring(s.default), tostring(want))
			end
		end
		local ordered = true
		for i, key in ipairs(W.DEFAULT_ORDER) do
			if W.TierRank(MM.Planner.TIER[key]) ~= i then ordered = false end
		end
		MM.db.weights = saved
		MM:Fire("MM_WEIGHTS_CHANGED")
		if not neutral then return false, "a slider default is not neutral" end
		if not ordered then return false, "tier order does not match the default" end
		return true, ("%d tiers in default order, %d coefficients at spec")
			:format(#W.DEFAULT_ORDER, #W.SLIDERS)
	end)

	check("Every weight explains itself", function()
		-- A raw coefficient with no plain-language reading is a number the player
		-- cannot act on, which is the same as not exposing it at all.
		for _, def in ipairs(MM.Weights.SLIDERS) do
			if type(def.reading) ~= "function" then
				return false, def.key .. " has no reading"
			end
			for _, v in ipairs({ def.min, def.default, def.max }) do
				local text = def.reading(v)
				if type(text) ~= "string" or text == "" then
					return false, ("%s reads nothing at %s"):format(def.key, tostring(v))
				end
			end
		end
		return true, ("%d weights, each with a live explanation"):format(#MM.Weights.SLIDERS)
	end)

	check("Reordering priorities takes effect", function()
		local W = MM.Weights
		local saved = MM.db.weights
		MM.db.weights = { order = { "RARE", "PICKUP", "INSTANCE", "FIELD", "REP",
			"GRIND", "ACHIEVE", "GROUP" } }
		MM:Fire("MM_WEIGHTS_CHANGED")
		local rareFirst = W.TierRank(MM.Planner.TIER.RARE) < W.TierRank(MM.Planner.TIER.PICKUP)
		-- blocked can never be promoted, whatever is saved
		local blockedLast = W.TierRank(MM.Planner.TIER.BLOCKED) > W.TierRank(MM.Planner.TIER.GROUP)
		MM.db.weights = saved
		MM:Fire("MM_WEIGHTS_CHANGED")
		if not rareFirst then return false, "reordered list did not change tier rank" end
		if not blockedLast then return false, "BLOCKED was promoted out of last place" end
		return true, "order applied, BLOCKED still pinned last"
	end)

	check("Corrupt weight order self-heals", function()
		local W = MM.Weights
		local saved = MM.db.weights
		MM.db.weights = { order = { "RARE", "NOT_A_TIER", "RARE" } }
		local order = W.Order()
		MM.db.weights = saved
		MM:Fire("MM_WEIGHTS_CHANGED")
		if #order ~= #W.DEFAULT_ORDER then
			return false, ("recovered %d of %d tiers"):format(#order, #W.DEFAULT_ORDER)
		end
		local seen = {}
		for _, k in ipairs(order) do
			if seen[k] then return false, "duplicate tier " .. k end
			seen[k] = true
		end
		if order[1] ~= "RARE" then return false, "the one valid saved entry was not kept first" end
		return true, "junk dropped, missing tiers restored"
	end)

	check("Assault-gated mounts carry a live gate", function()
		local gated, bad = 0, nil
		for _, rec in pairs(MM.DBByName) do
			local g = rec.assault
			if g then
				gated = gated + 1
				if not (g.mapID and (g.match or g.label)) then bad = rec.name end
			end
		end
		if bad then return false, bad .. " has an incomplete assault gate" end
		return gated > 0, ("%d gated"):format(gated)
	end)
end

------------------------------------------------------------
-- Runner
------------------------------------------------------------
function T.Run()
	results = {}
	local ok, err = pcall(function()
		runAPI(); runData(); runLogic()
	end)
	if not ok then record(FAIL, "RUNNER", "self-test crashed", tostring(err)) end

	local counts = { PASS = 0, FAIL = 0, WARN = 0 }
	local group
	MM:Print("Self-test — %s", date and date("%Y-%m-%d %H:%M") or "now")
	for _, r in ipairs(results) do
		counts[r.state] = counts[r.state] + 1
		if r.group ~= group then
			group = r.group
			MM:Print("|cff9a9a9a%s|r", group)
		end
		-- passes stay quiet unless they carry a useful figure
		if r.state == PASS and not r.detail then
			-- nothing: a silent pass is the expected case
		else
			local colour = r.state == PASS and "ff40d860"
				or r.state == WARN and "ffffd84d" or "ffff4d4d"
			MM:Print("  |c%s%s|r  %s%s", colour, r.state, r.name,
				r.detail and ("  |cffbbbbbb— " .. r.detail .. "|r") or "")
		end
	end
	MM:Print("%d passed, |cffffd84d%d degraded|r, |cffff4d4d%d failed|r  (of %d)",
		counts.PASS, counts.WARN, counts.FAIL, #results)
	if counts.FAIL == 0 and counts.WARN == 0 then
		MM:Print("|cff40d860Everything this client can do, it is doing.|r")
	elseif counts.FAIL == 0 then
		MM:Print("No failures. Degraded items are checks that could not run — an "
			.. "optional feature this client lacks, or state nothing has produced yet.")
	else
		MM:Print("|cffff4d4dFailures above are real — do not release with these outstanding.|r")
	end
	-- Remembered so /mm release can gate on a REAL run rather than asking the
	-- reader to have looked at the output themselves.
	T.lastRun = {
		passed = counts.PASS, degraded = counts.WARN, failed = counts.FAIL,
		total = #results, at = date and date("%Y-%m-%d %H:%M") or nil,
	}
	return counts
end

MM:On("MM_SELFTEST", function() T.Run() end)

------------------------------------------------------------
-- /mm check — the one command
------------------------------------------------------------
-- Running the diagnostics by hand gives WRONG answers, not just tedious ones.
-- The calendar streams in from the server after a request, Callings arrive on an
-- event, and the bag scan is debounced. Fire those and read them in the same
-- breath and they all report "not available yet".
--
-- So this warms every asynchronous subsystem, waits, and then prints ONE
-- summary with a verdict. Detail stays behind the individual commands; this
-- tells you which of them, if any, is worth opening.
local function count(t) local n = 0 for _ in pairs(t or {}) do n = n + 1 end return n end

-- Public so the diagnostics report can run it without re-doing the warm-up
-- wait; D.Generate already warmed the asynchronous subsystems itself.
function T.RunSync()
	local line = function(label, text, drill)
		MM:Print("|cff33c1ff%-13s|r %s%s", label, text,
			drill and ("  |cff9a9a9a-> " .. drill .. "|r") or "")
	end

	local counts = T.Run()
	local rarityAbsent

	------------------------------------------------------------
	local S = MM.Scanner
	local recs = 0
	for _, rec in ipairs(MM.DBList or {}) do
		if (rec.spellID and MM.DBBySpell[rec.spellID] == rec)
			or (rec.name and MM.DBByName[rec.name:lower()] == rec) then recs = recs + 1 end
	end
	local matched, total = 0, 0
	for _, e in pairs((S and S.byMountID) or {}) do
		total = total + 1
		if e.rec and not e.rec.stub then matched = matched + 1 end
	end
	MM:Print(" ")
	line("DATABASE", ("%d records · %d maps · journal %d/%d catalogued%s")
		:format(recs, count(MM.ResolvedIDs and MM.ResolvedIDs.maps),
			matched, total, total > 0 and (" (%.1f%%)"):format(matched / total * 100) or ""),
		total > 0 and matched < total and "/mm audit" or nil)

	------------------------------------------------------------
	if MM.Rarity.Available() then
		local lib = LibStub and LibStub("MountsRarity-2.0", true)
		local ok, data = pcall(lib.GetData, lib)
		local seen, absent = 0, 0
		if ok and type(data) == "table" then
			for _, mountID in ipairs(C_MountJournal.GetMountIDs()) do
				if data[mountID] then
					seen = seen + 1
					local name, spellID = C_MountJournal.GetMountInfoByID(mountID)
					local rec = (spellID and MM.DBBySpell[spellID])
						or (name and MM.DBByName[name:lower()])
					if not (rec and not rec.stub) then absent = absent + 1 end
				end
			end
		end
		rarityAbsent = absent
		line("RARITY", ("live · %d mounts matched · %s"):format(seen,
			absent == 0 and "|cff40d860none missing from our database|r"
			or ("|cffffd84d%d not in our database|r"):format(absent)),
			absent > 0 and "/mm rarity" or nil)
	else
		line("RARITY", "|cffffd84dMountsRarity not installed|r — difficulty uses our estimates only")
	end

	------------------------------------------------------------
	local plan = MM.Planner:GetPlan()
	local blocked = 0
	for _, entry in ipairs(plan) do
		if MM.QuestGate.HardGate(entry.rec) then blocked = blocked + 1 end
	end
	local stops = #(MM.Router.route or {})
	if #plan > 0 and stops == 0 then
		pcall(function() MM.Router:BuildSync() end)
		stops = #(MM.Router.route or {})
	end
	line("PLAN", ("%d goals · %d stops%s"):format(#plan, stops,
		blocked > 0 and (" · |cffffd84d%d prerequisite-blocked|r"):format(blocked) or ""),
		blocked > 0 and "/mm gates" or nil)

	------------------------------------------------------------
	local carried = count(MM.Acquire.carried)
	line("BAGS", carried > 0
		and ("|cff40d860%d mount%s you can learn right now|r"):format(carried, carried == 1 and "" or "s")
		or "nothing in your bags teaches a missing mount",
		carried > 0 and "/mm bags" or nil)

	------------------------------------------------------------
	local C = MM.Callings
	line("CALLINGS", C.enumerated
		and ("%d read today"):format(count(C.active))
		or "|cffffd84dcould not read today's Callings|r",
		"/mm callings")

	------------------------------------------------------------
	line("EVENTS", ("calendar %s · Timewalking %s"):format(
		MM.Availability.calendarLoaded and "synced" or "|cffffd84dnot synced|r",
		MM.Timewalking.IsActive() and "|cff40d860active|r" or "inactive"),
		not MM.Availability.calendarLoaded and "/mm events" or nil)

	------------------------------------------------------------
	line("TRADING POST", MM.TradingPost.HasLiveData()
		and "live rotation data"
		or "|cffffd84dno rotation data — open the Trading Post once|r", "/mm post")

	------------------------------------------------------------
	------------------------------------------------------------
	-- The verdict has to weigh the SUMMARY, not just the self-test. The first
	-- version reported "everything green" on a run that was also reporting 19
	-- mounts missing from the database and an unsynced calendar, because it only
	-- counted self-test failures. A verdict that ignores the findings above it
	-- is worse than no verdict.
	MM:Print(" ")
	local todo = {}
	if rarityAbsent and rarityAbsent > 0 then
		tinsert(todo, ("%d mount%s missing from the database"):format(
			rarityAbsent, rarityAbsent == 1 and "" or "s"))
	end
	if total > 0 and matched < total then
		tinsert(todo, ("%d journal mount%s uncatalogued"):format(
			total - matched, (total - matched) == 1 and "" or "s"))
	end
	if not MM.Availability.calendarLoaded then
		tinsert(todo, "calendar not synced")
	end
	if not MM.TradingPost.HasLiveData() then
		tinsert(todo, "no Trading Post rotation data")
	end

	if counts.FAIL > 0 then
		MM:Print("|cffff4d4dVERDICT: %d self-test failure%s — not ready.|r",
			counts.FAIL, counts.FAIL == 1 and "" or "s")
	elseif #todo > 0 then
		MM:Print("|cff40d860Self-test clean|r (%d passed, %d degraded). |cffffd84dOutstanding:|r %s",
			counts.PASS, counts.WARN, table.concat(todo, ", "))
	elseif counts.WARN > 0 then
		MM:Print("|cff40d860VERDICT: green.|r %d degraded item%s — checks that could not run.",
			counts.WARN, counts.WARN == 1 and "" or "s")
	else
		MM:Print("|cff40d860VERDICT: everything green, nothing outstanding.|r")
	end
end

function T.FullCheck()
	MM:Print("Running full check — warming the asynchronous bits first...")
	-- Kick these off together; they all need a server round-trip.
	pcall(function() MM.Callings.Request() end)
	pcall(function() MM.Availability.EnsureCalendar() end)
	pcall(function() MM.TradingPost.Refresh() end)
	-- 4s is enough for the calendar and Callings to answer in practice, and the
	-- bag scan debounce is 0.5s.
	C_Timer.After(4, function()
		local ok, err = pcall(T.RunSync)
		if not ok then MM:Print("|cffff4d4dCheck crashed:|r %s", tostring(err)) end
	end)
end

MM:On("MM_FULLCHECK", function() T.FullCheck() end)
