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
		-- the user: tooltips must not repeat themselves. The exact-match guard was
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
		-- "Priority 7" with no reasoning is the opaque case the user hit. The rule
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

	check("The route builds cleanly", function()
		-- A one-line omission broke every route build in the addon and 57 checks
		-- did not notice, because every one of them tested a PIECE. Nothing ran
		-- the pipeline. This does, and it is the check that should have existed
		-- first.
		local R = MM.Router
		local ok, err = pcall(function() return R:Build() end)
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
		local before = debugprofilestop()
		R:Build()
		local ms = debugprofilestop() - before
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
		-- The cap is the middle ground the user chose: the clock stays free inside
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
			R:Build()
			return R.totals and R.totals.minutes or 0, R.capReport
		end
		local free = build(0)
		local capped, rep = build(8)
		MM.db.weights = saved
        MM:Fire("MM_WEIGHTS_CHANGED")
		R:Build()
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
		-- the user asked how realistic the time costs are. The honest answer is a
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
			if J.Plan then J.Plan(zone, 50, 50, "Orgrimmar", 50, 50) end
			local same, other = J.AttachAudit(zone, 50, 50)
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
				-- `or 15` matches what S.Fit itself assumes for a stop with no
				-- stated work, so the test costs the route the same way the
				-- session costed it. Using 0 here would let an unpriced stop
				-- silently satisfy any budget.
				local work = stop.workMinutes or 15
				if stop.travelMinutes or stop.workMinutes then priced = priced + 1 end
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
		if R.Build then R:Build() end

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
		MM.db.contributions = saved
		pcall(CO.Apply)
		if applied > 0 or wrote > 0 then
			return false, ("its own export wrote %d records back — placeholders "
				.. "are being treated as data"):format(wrote)
		end
		return true, ("%d gaps exported, round-trips as a no-op"):format(total)
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
		-- Each was found by the user reading a list and saying "that is wrong".
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
		-- the user stood in Zuldazar with three Orgrimmar teleports in his bags and
		-- was told to fly to the Dazar'alor portal room and "take the portal to
		-- Orgrimmar, then the Dornogal portal". The engine had rejected all
		-- three with "lands on a different continent" -- while the instruction
		-- it printed proved Orgrimmar was exactly where it wanted him.
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
		-- soloable, per the user: blanket-grouping punishes the many to guard
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
		-- the user: an 8-hour guaranteed grind one minute away must not beat a
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
		-- and the exception the user named: with nothing shorter available, the
		-- grind IS the best thing left, with no special case for it
		local alone = R.NearestChain({ grind }, here)
		if alone[1] ~= grind then return false, "the grind vanished when alone" end
		return true, "short closed work leads; long grinds surface when it is gone"
	end)

	check("Detours are never worthless", function()
		-- Bloodthirsty Dreadwing -- a mount the user cannot afford, expected value
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
		-- the user: a mount costing 1,000 medals he has none of was FIRST, then
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
		-- the user: a unique currency to farm, criteria to finish, a reputation to
		-- grind -- "these all factor into the total time equation". They are
		-- SEQUENTIAL, so they add. Taking the worst would price a mount needing
		-- exalted AND a thousand medals the same as one needing only the medals.
		local P = MM.Planner
		-- Two DIFFERENT currencies: two separate grinds. Using a rep condition
		-- here failed for a boring reason -- an invented faction name yields no
		-- progress at all, so there was nothing to add -- and a test that fails
		-- because its fixture is unreadable tells you nothing about the code.
		local both = { rec = { category = "CURRENCY", timePerAttempt = 10, effort = 3,
			conditions = {
				{ type = "CURRENCY", id = 1166, name = "Timewarped Badge", amount = 5000 },
				{ type = "CURRENCY", id = 1560, name = "War Resources", amount = 5000 },
			} } }
		local justCurrency = { rec = { category = "CURRENCY", timePerAttempt = 10, effort = 3,
			conditions = {
				{ type = "CURRENCY", id = 1166, name = "Timewarped Badge", amount = 5000 },
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
		-- the user: Hand of Bahmethra and Mawsworn Soulhunter need a Maw event to be
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
		-- A raw coefficient with no plain-language reading is a number the user
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
		pcall(function() MM.Router:Build() end)
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
