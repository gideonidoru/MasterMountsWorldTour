-- Master Mounts: the contribution pipeline.
--
-- The ranking is sound. It is being fed guesses.
--
--   317 of 1,359 obtainable records have no location at all, so they can never
--       be routed -- roughly a quarter of the collection silently absent from
--       every plan
--    53 of 223 drop records have no observed rate and are ranked on an assumed 1%
--   124 purchases have a price that exists only in prose
--   113 achievements have no soloability judgement, which no API can supply
--
-- None of that is a logic problem, and no amount of cleverness fixes it. It is
-- data, and it is the ceiling on everything else the addon does.
--
-- It is also the one thing that gets cheaper the more people use the addon.
-- Every player is standing in front of some of these answers: they know the
-- vendor's coordinates because they just walked to them, they know the price
-- because they just paid it, they know the raid soloed fine because they just
-- soloed it. The cost of collecting that is a paste box; the cost of NOT
-- collecting it is that all of us guess separately, forever.
--
-- Two directions, and they use the same format:
--
--   EXPORT  /mm contribute -- the gaps this client can see, as ready-to-paste
--           Lua. Not a bug report: a patch.
--   IMPORT  paste someone else's block back in. It is applied as OVERRIDES on
--           top of the shipped database, never merged into it, so a bad paste
--           is undone by clearing overrides rather than by reinstalling.
--
-- Safety, because this accepts text from strangers:
--   * parsed with a strict pattern reader, never loadstring. An addon that
--     executes pasted Lua is a malware delivery mechanism.
--   * every field is validated for type and range before it is stored
--   * only known record names are accepted, so a paste cannot invent mounts
local _, MM = ...

MM.Contribute = {}
local CO = MM.Contribute
local U = MM.Util

local function store()
	MM.db.contributions = MM.db.contributions or {}
	return MM.db.contributions
end

------------------------------------------------------------
-- What is missing
------------------------------------------------------------
-- Each gap knows how to describe itself and what a filled-in line looks like,
-- so the export is a template rather than a complaint.
-- Categories where a location is not missing data, it is a category error.
-- The mount is bought, granted, crafted, coded or awarded -- there is no place
-- a player could stand and tell us about.
local PLACELESS = {
	STORE = true, PROMOTION = true, TCG = true, ACHIEVEMENT = true,
	PROFESSION = true, PVP = true, CLASS = true, REMOVED = true,
	TRADINGPOST = true,
}

local GAPS = {
	{
		key = "location",
		title = "Locations",
		blurb = "Where the mount actually comes from. Without this the mount "
			.. "can never be routed at all, which makes it the most valuable "
			.. "line in this file.",
		want = 'zone = "Zone Name", x = 00.0, y = 00.0',
		-- NOT EVERY MOUNT HAS A PLACE.
		--
		-- This counted any obtainable record without a zone, and reported 182
		-- "missing locations" as though someone could go and find them. Most of
		-- them cannot exist: 68 Store mounts are bought from Blizzard, 22
		-- Promotion mounts are granted, 3 came from trading cards, 35 arrive
		-- with an achievement, 18 are crafted wherever you stand, and 13 are
		-- honor-level rewards. There is nowhere to go for any of them.
		--
		-- Asking players to supply a coordinate for a Celestial Steed is asking
		-- for something that does not exist, and burying the thirty that ARE
		-- findable under a hundred and fifty that are not.
		test = function(rec)
			if not rec.obtainable or rec.zone or rec.vendor then return false end
			return not PLACELESS[rec.category]
		end,
	},
	{
		key = "dropRate",
		title = "Drop rates",
		blurb = "The observed rate, as a percentage. Wowhead's item page "
			.. "carries it under the drop source. Unrated drops are ranked on "
			.. "an assumed 1%, which flatters the rare ones and punishes the "
			.. "common ones.",
		want = "dropRate = 0.0",
		test = function(rec)
			return rec.obtainable and (rec.category == "DROP" or rec.category == "RARE")
				and not rec.dropRate
		end,
	},
	{
		key = "price",
		title = "Prices",
		blurb = "What it costs, as a currency condition. These are charged a "
			.. "flat four-hour guess today.",
		want = 'currency = 0, currencyName = "Name", currencyID = 0',
		-- A CONDITION IS NOT A PRICE.
		--
		-- This treated ANY condition as evidence the record was priced, so a
		-- mount carrying a reputation requirement and no cost was not counted,
		-- and a currency condition that named its cost without an AMOUNT was
		-- not counted either. It measured "has no conditions" while reporting
		-- itself as "has no price".
		--
		-- That mattered when a few hundred prices were imported: the real
		-- coverage more than doubled while this number moved by three, which
		-- reads as data that did not land. It had landed; the counter was
		-- looking at the wrong thing.
		test = function(rec)
			if not rec.obtainable then return false end
			local priced = rec.category == "VENDOR" or rec.category == "CURRENCY"
				or rec.category == "TIMEWALKING" or rec.category == "PROFESSION"
			if not priced then return false end
			if (rec.source or ""):lower():find("gold") then return false end
			-- Gold is a field rather than a condition.
			if rec.goldCost then return false end
			for _, cond in ipairs(rec.conditions or {}) do
				if (cond.type == "CURRENCY" or cond.type == "ITEM") and cond.amount then
					return false
				end
			end
			return true
		end,
	},
	{
		key = "solo",
		title = "Soloability",
		blurb = "Can one player finish this today? NO API EXPOSES THIS -- legacy "
			.. "raids were built for groups and are often soloable anyway, "
			.. "depending on class, gear and patch. It is a judgement, and it "
			.. "is the kind of judgement a collector makes every week.",
		want = "solo = true   -- or false",
		test = function(rec)
			return rec.obtainable and rec.category == "ACHIEVEMENT" and rec.solo == nil
		end,
	},
	{
		key = "chain",
		title = "Puzzle chains",
		blurb = "The steps, in order, and roughly how long the whole thing "
			.. "takes. Include quest ids where a tracking macro exists -- that "
			.. "turns a wall of text into real progress.",
		want = 'hours = 0, steps = { "first step", "second step" }',
		test = function(rec)
			return rec.obtainable and rec.category == "PUZZLE" and not rec.acquire
		end,
	},
}

-- Memoised for the life of a report.
--
-- Scan walks 1,608 records against five predicates -- 8,000 pcalls -- and the
-- report asked for it TWICE: once for CONTRIBUTIONS and once for KNOWN &
-- UNKNOWABLE. Neither needed a fresh answer; the database does not change
-- between two sections of the same printout.
local scanCache
function CO.InvalidateScan() scanCache = nil end
MM:On("MM_SCANNED", CO.InvalidateScan)
MM:On("MM_CONTRIBUTIONS", CO.InvalidateScan)

function CO.Scan()
	if scanCache then return scanCache[1], scanCache[2] end
	local out, counts = {}, {}
	for _, gap in ipairs(GAPS) do
		local list = {}
		for _, rec in pairs(MM.DBByName) do
			local ok, hit = pcall(gap.test, rec)
			if ok and hit then list[#list + 1] = rec.name end
		end
		table.sort(list)
		out[gap.key] = list
		counts[gap.key] = #list
	end
	scanCache = { out, counts }
	return out, counts
end

------------------------------------------------------------
-- Export
------------------------------------------------------------
local MAX_PER_SECTION = 40

function CO.Export()
	local found = CO.Scan()
	local L = {}
	local function add(s) L[#L + 1] = s or "" end

	add("-- Master Mounts contribution file")
	add("-- Generated " .. (date and date("%Y-%m-%d %H:%M") or "?")
		.. " on " .. (GetRealmName and GetRealmName() or "?"))
	add("--")
	add("-- Fill in what you KNOW. Delete the rest -- a blank line is far more")
	add("-- useful than a guess, because a guess is indistinguishable from data")
	add("-- once it is in the file.")
	add("--")
	add("-- Paste the finished block back with /mm contribute import.")
	add("")

	for _, gap in ipairs(GAPS) do
		local list = found[gap.key]
		if #list > 0 then
			add(("## %s (%d)"):format(gap.title, #list))
			for line in gap.blurb:gmatch("[^\n]+") do add("-- " .. line) end
			add(("-- Format:  <Mount Name> | %s"):format(gap.want))
			add("")
			local shown = math.min(#list, MAX_PER_SECTION)
			for i = 1, shown do
				add(("%s | %s"):format(list[i], gap.want))
			end
			if #list > shown then
				add(("-- ...and %d more; re-run after submitting these."):format(#list - shown))
			end
			add("")
		end
	end

	local total = 0
	for _, gap in ipairs(GAPS) do total = total + #found[gap.key] end
	if total == 0 then
		add("Nothing is missing that this client can see. That is remarkable.")
	end
	return table.concat(L, "\n"), total
end

------------------------------------------------------------
-- Import
------------------------------------------------------------
-- A strict line reader. NEVER loadstring: an addon that executes pasted Lua is
-- a malware delivery mechanism wearing a helpful hat, and "it's just a data
-- file" is exactly what the first malicious paste would also look like.
local function parseValue(key, raw)
	raw = strtrim(raw or "")
	if key == "zone" or key == "currencyName" then
		local str = raw:match('^"(.-)"$')
		if str and #str > 0 and #str <= 60 then return str end
		return nil, "expected a quoted name"
	end
	if key == "solo" then
		if raw == "true" then return true end
		if raw == "false" then return false end
		return nil, "expected true or false"
	end
	local n = tonumber(raw)
	if not n then return nil, "expected a number" end
	if key == "x" or key == "y" then
		if n < 0 or n > 100 then return nil, "coordinates run 0-100" end
	elseif key == "dropRate" then
		if n <= 0 or n > 100 then return nil, "a drop rate is a percentage" end
	elseif key == "hours" then
		if n <= 0 or n > 500 then return nil, "hours out of range" end
	elseif n < 0 or n > 100000000 then
		return nil, "out of range"
	end
	return n
end

local ACCEPTED = {
	zone = true, x = true, y = true, dropRate = true, solo = true,
	currency = true, currencyName = true, currencyID = true, hours = true,
}

-- Returns applied, skipped, problems[]
function CO.Import(text)
	if type(text) ~= "string" or #text == 0 then return 0, 0, { "nothing pasted" } end
	local applied, skipped, problems = 0, 0, {}
	local db = store()

	for rawLine in text:gmatch("[^\r\n]+") do
		-- a separate local: the generic-for variable is const under 5.4, and
		-- `luac -p` is the syntax gate for this project even though WoW is 5.1
		local line = strtrim(rawLine)
		if line ~= "" and not line:match("^%-%-") and not line:match("^##") then
			local name, rest = line:match("^(.-)%s*|%s*(.+)$")
			if not name then
				skipped = skipped + 1
			elseif not MM.DBByName[name] then
				-- A paste cannot invent mounts.
				skipped = skipped + 1
				if #problems < 8 then
					problems[#problems + 1] = ("unknown mount %q"):format(name)
				end
			else
				local fields, bad = {}, nil
				for pair in rest:gmatch("[^,]+") do
					local k, v = pair:match("^%s*([%w_]+)%s*=%s*(.+)$")
					if k and ACCEPTED[k] then
						-- Placeholder values from the template are ignored, not
						-- stored: an untouched line must be a no-op.
						local vt = strtrim(v)
						if vt ~= "0" and vt ~= "0.0" and vt ~= "00.0"
							and vt ~= '"Zone Name"' and vt ~= '"Name"' then
							local parsed, err = parseValue(k, v)
							if parsed ~= nil then fields[k] = parsed
							elseif err then bad = ("%s: %s"):format(k, err) end
						end
					end
				end
				if bad then
					skipped = skipped + 1
					if #problems < 8 then
						problems[#problems + 1] = ("%s — %s"):format(name, bad)
					end
				elseif next(fields) then
					db[name] = db[name] or {}
					for k, v in pairs(fields) do db[name][k] = v end
					applied = applied + 1
				else
					skipped = skipped + 1
				end
			end
		end
	end

	if applied > 0 then
		CO.Apply()
		MM.Planner.InvalidateRanks()
		MM:Fire("MM_CONTRIBUTIONS")
	end
	return applied, skipped, problems
end

-- Overrides are applied ON TOP of the shipped database, never merged into it,
-- so a bad paste is undone by clearing them rather than by reinstalling.
function CO.Apply()
	local db = MM.db and MM.db.contributions
	if not db then return 0 end
	local n = 0
	for name, fields in pairs(db) do
		local rec = MM.DBByName[name]
		if rec then
			n = n + 1
			if fields.zone then
				rec.zone = rec.zone or {}
				rec.zone.name = fields.zone
				if fields.x then rec.zone.x = fields.x end
				if fields.y then rec.zone.y = fields.y end
				rec.zone.contributed = true
			end
			if fields.dropRate then rec.dropRate = fields.dropRate end
			if fields.solo ~= nil then rec.solo = fields.solo end
			if fields.hours then
				rec.acquire = rec.acquire or {}
				rec.acquire.hours = fields.hours
			end
			if fields.currency and fields.currency > 0 then
				rec.conditions = rec.conditions or {}
				rec.conditions[#rec.conditions + 1] = {
					type = "CURRENCY", id = fields.currencyID,
					name = fields.currencyName or "currency",
					amount = fields.currency,
				}
			end
			rec.contributed = true
		end
	end
	return n
end

function CO.Clear()
	MM.db.contributions = {}
	MM:Print("Contributions cleared. Reload to restore the shipped data exactly.")
end

MM:On("MM_SCANNED", function() pcall(CO.Apply) end)

------------------------------------------------------------
-- Commands
------------------------------------------------------------
MM:On("MM_CONTRIBUTE", function()
	local text, total = CO.Export()
	if MM.Diagnostics and MM.Diagnostics.ShowExport then
		MM.Diagnostics.ShowExport(text,
			("Contribution file — %d gaps this client can see"):format(total))
	else
		MM:Print(text)
	end
end)

MM:On("MM_CONTRIBUTE_IMPORT", function()
	if MM.Diagnostics and MM.Diagnostics.ShowImport then
		MM.Diagnostics.ShowImport("Paste a contribution file", function(text)
			local applied, skipped, problems = CO.Import(text)
			MM:Print("Contributions: |cff40d860%d applied|r, %d skipped.",
				applied, skipped)
			for _, p in ipairs(problems) do MM:Print("   %s", p) end
			if applied > 0 then
				MM:Print("   /mm contribute clear undoes all of it.")
			end
		end)
	else
		MM:Print("Import needs the export window; /mm diag first.")
	end
end)

MM:On("MM_CONTRIBUTE_DEBUG", function()
	local _, counts = CO.Scan()
	local total = 0
	for _, gap in ipairs(GAPS) do
		MM:Print("   %-14s %4d missing", gap.title, counts[gap.key])
		total = total + counts[gap.key]
	end
	local db = MM.db.contributions or {}
	local n = 0
	for _ in pairs(db) do n = n + 1 end
	MM:Print("Gaps this client can see: %d. Contributions applied: %d.", total, n)
	MM:Print("   /mm contribute exports them; import merges someone else's back.")
end)

------------------------------------------------------------
-- /mm costs — does everything actually have a cost?
------------------------------------------------------------
-- Requirement — make sure everything has a cost (time/materials/rep/effort) highlight
-- anything that does not.
--
-- The five gap types above are the things a PLAYER can fill in. This is the
-- wider question: for every goal that can reach a plan, is its cost derived
-- from something real, or is it resting on the editorial `effort` rating alone?
--
-- The effort floor is a legitimate fallback -- it is what stops an unmodelled
-- goal being free -- but it is one number for a whole category, so a record
-- resting on it is a record the ordering cannot really justify. There is no way
-- to know how many of those there are without counting them, and until now
-- nothing counted them.
--
-- Deliberately restricted to PLANNABLE categories. Store, TCG and promotional
-- mounts have no in-game cost because they have no in-game acquisition, and
-- they are already excluded from planning -- listing them here would be 94
-- lines of noise implying 94 lines of work.
local COST_SIGNALS = {
	{ key = "rate",     label = "a drop rate",
		test = function(rec) return rec.dropRate ~= nil end },
	{ key = "cond",     label = "requirements (rep, currency, achievement, item)",
		test = function(rec)
			for _, c in ipairs(rec.conditions or {}) do
				if c.type then return true end
			end
			return false
		end },
	{ key = "chain",    label = "a step chain with hours",
		test = function(rec) return rec.acquire ~= nil end },
	{ key = "reagents", label = "harvested reagents",
		test = function(rec)
			return MM.Crafting and MM.Crafting.IsPriced
				and MM.Crafting.IsPriced(rec)
		end },
	-- A STATED GOLD PRICE IS A MODELLED COST.
	--
	-- 86 records carry one and the planner prices them from it, checked against
	-- what the character actually has. This list did not know, so the coverage
	-- report went on calling them bare and the scorecard went on offering the
	-- same points for fixing something already fixed.
	--
	-- A metric that cannot see a whole class of cost is not measuring coverage,
	-- it is measuring the signals it happens to enumerate.
	{ key = "gold",     label = "a stated gold price",
		test = function(rec) return rec.goldCost ~= nil end },
}

function CO.CostCoverage()
	local byCat = {}
	for _, rec in pairs(MM.DBByName) do
		if rec.obtainable and MM.PLANNABLE[rec.category] then
			local cat = byCat[rec.category]
			if not cat then
				cat = { total = 0, covered = 0, bare = {} }
				byCat[rec.category] = cat
			end
			cat.total = cat.total + 1
			local ok = false
			for _, sig in ipairs(COST_SIGNALS) do
				local fine, hit = pcall(sig.test, rec)
				if fine and hit then ok = true break end
			end
			if ok then
				cat.covered = cat.covered + 1
			else
				cat.bare[#cat.bare + 1] = rec.name
			end
		end
	end
	return byCat
end

MM:On("MM_COSTS_DEBUG", function()
	local byCat = CO.CostCoverage()
	local rows, total, covered = {}, 0, 0
	for cat, d in pairs(byCat) do
		rows[#rows + 1] = { cat = cat, d = d }
		total = total + d.total
		covered = covered + d.covered
	end
	table.sort(rows, function(a, b) return #a.d.bare > #b.d.bare end)

	MM:Print("Cost coverage across %d plannable goals: |cff40d860%d modelled|r, "
		.. "|cffff9a3c%d on the effort rating alone|r (%.0f%%).",
		total, covered, total - covered,
		total > 0 and (total - covered) / total * 100 or 0)
	MM:Print("   A goal resting on the effort rating is not free -- the floor")
	MM:Print("   still charges it -- but that is one number for a whole")
	MM:Print("   category, so its place in the order cannot really be justified.")

	for _, row in ipairs(rows) do
		local d = row.d
		if #d.bare > 0 then
			MM:Print("   |cffffd84d%-12s|r %3d of %3d unmodelled   e.g. %s",
				row.cat, #d.bare, d.total,
				table.concat(d.bare, ", ", 1, math.min(#d.bare, 3)))
		end
	end
	-- Instance mounts with no door.
	--
	-- A mount with an `instance` block but no `zone` cannot be routed at all --
	-- it lands in "no location to route to" and silently never appears in a
	-- plan. When another mount from the SAME instance records the entrance, the
	-- fix is a copy rather than a lookup, and there is no reason for anyone to
	-- go and find it again.
	local withDoor, noDoor = {}, {}
	for _, rec in pairs(MM.DBByName) do
		if rec.obtainable and rec.instance and rec.instance.name then
			local key = rec.instance.name
			if rec.zone then
				withDoor[key] = withDoor[key] or rec.name
			else
				noDoor[key] = noDoor[key] or {}
				tinsert(noDoor[key], rec.name)
			end
		end
	end
	local copyable, orphaned = {}, {}
	for inst, list in pairs(noDoor) do
		for _, name in ipairs(list) do
			if withDoor[inst] then
				copyable[#copyable + 1] = ("%s — copy the door from %s (%s)")
					:format(name, withDoor[inst], inst)
			else
				orphaned[#orphaned + 1] = ("%s (%s)"):format(name, inst)
			end
		end
	end
	table.sort(copyable); table.sort(orphaned)
	if #copyable > 0 then
		MM:Print("   |cffff9a3cInstance mounts with no door, fixable by copying:|r")
		for _, line in ipairs(copyable) do MM:Print("      %s", line) end
	end
	if #orphaned > 0 then
		MM:Print("   |cff9a9a9aInstance mounts with no door, and no instance-mate has one:|r")
		for i = 1, math.min(#orphaned, 6) do MM:Print("      %s", orphaned[i]) end
		if #orphaned > 6 then MM:Print("      ...and %d more", #orphaned - 6) end
	end
	if #copyable == 0 and #orphaned == 0 then
		MM:Print("   |cff40d860Every instance mount has a door to walk to.|r")
	end

	MM:Print("   /mm contribute exports the ones a player can answer.")
end)

------------------------------------------------------------
-- /mm known — what we don't know, and whether it can ever be known
------------------------------------------------------------
-- Requirement — all of those
-- should be in the diagnostics right. Yes. If the reader has to ask a person
-- which gaps are closable, the report is not doing its job.
--
-- Every other section reports a COUNT. This one reports the EPISTEMICS: for
-- each thing the addon does not know, who could know it, and whether anyone
-- can. That distinction is the difference between a to-do list and an excuse
-- list, and only one of those is worth shipping.
--
-- Three verdicts, and they mean genuinely different things:
--
--   SELF-CLOSING   the client knows; the addon reads it at runtime and no
--                  human ever needs to be involved
--   NEEDS A PLAYER someone standing in the right place can answer it in
--                  seconds -- /mm contribute exports exactly these
--   NOBODY CAN     no API and no public source exposes it. Not a to-do.
local VERDICT = {
	selfclosing = { tag = "|cff40d860self-closing|r", order = 1 },
	player      = { tag = "|cffffd84dneeds a player|r", order = 2 },
	nobody      = { tag = "|cffff9a3cnobody can|r", order = 3 },
}

local function conditionCoverage()
	local out = {}
	for _, rec in pairs(MM.DBByName) do
		if rec.obtainable then
			for _, cond in ipairs(rec.conditions or {}) do
				local t = cond.type
				if t then
					out[t] = out[t] or { total = 0, withID = 0 }
					out[t].total = out[t].total + 1
					local id = cond.id or cond.factionID or cond.itemID
					if id then out[t].withID = out[t].withID + 1 end
				end
			end
		end
	end
	return out
end

MM:On("MM_KNOWN_DEBUG", function()
	MM:Print("What is missing, and whether anyone could supply it.")

	------------------------------------------------------------
	-- Condition ids
	------------------------------------------------------------
	local HOW = {
		ACHIEVEMENT = { "selfclosing", "GetCategoryList enumerates every achievement" },
		CURRENCY    = { "selfclosing", "the currency id space is walked once and cached" },
		REP         = { "selfclosing", "the faction id space is walked once and cached" },
		PROFESSION  = { "selfclosing", "matched by name; no id is needed" },
		ITEM        = { "nobody", "WoW exposes NO reverse item-name to id lookup" },
		QUEST       = { "nobody", "WoW exposes NO reverse quest-name to id lookup" },
	}
	local cov = conditionCoverage()
	local rows = {}
	for t, d in pairs(cov) do
		local how = HOW[t] or { "player", "unclassified" }
		rows[#rows + 1] = { t = t, d = d, verdict = how[1], why = how[2] }
	end
	table.sort(rows, function(a, b)
		local va, vb = VERDICT[a.verdict].order, VERDICT[b.verdict].order
		if va ~= vb then return va < vb end
		return (a.d.total - a.d.withID) > (b.d.total - b.d.withID)
	end)
	MM:Print("|cffffd84dRequirement ids|r")
	for _, r in ipairs(rows) do
		local missing = r.d.total - r.d.withID
		MM:Print("   %-12s %4d total, %4d without an id   %s", r.t, r.d.total,
			missing, VERDICT[r.verdict].tag)
		if missing > 0 then MM:Print("                %s", r.why) end
	end

	------------------------------------------------------------
	-- Everything else
	------------------------------------------------------------
	local _, counts = CO.Scan()
	local crafts, harvested = 0, 0
	for _, rec in pairs(MM.DBByName) do
		if MM.Crafting and MM.Crafting.IsCraft(rec) and rec.obtainable then
			crafts = crafts + 1
			if MM.Crafting.IsPriced(rec) then harvested = harvested + 1 end
		end
	end

	local other = {
		{ "Locations", counts.location or 0, "player",
			"a player standing there, or a Wowhead page we cannot map a name to" },
		{ "Prices", counts.price or 0, "player",
			"only readable AT the vendor; no API lists a vendor's stock remotely" },
		{ "Soloability", counts.solo or 0, "player",
			"NO API exposes it -- depends on class, gear and patch. A judgement" },
		{ "Drop rates", counts.dropRate or 0, "nobody",
			"an unobserved rate does not exist to look up; new content has none" },
		{ "Puzzle chains", counts.chain or 0, "nobody",
			"all Midnight-era. No guide exists yet, for anyone" },
		{ "Craft reagents", crafts - harvested, "selfclosing",
			"harvests from C_TradeSkillUI -- open a profession window once" },
		{ "Trading Post", (MM.db.tradingPost and 0 or 1), "selfclosing",
			"captured on your first vendor visit, then remembered all month" },
	}
	table.sort(other, function(a, b)
		local va, vb = VERDICT[a[3]].order, VERDICT[b[3]].order
		if va ~= vb then return va < vb end
		return a[2] > b[2]
	end)
	MM:Print("|cffffd84dEverything else|r")
	for _, o in ipairs(other) do
		if o[2] > 0 then
			MM:Print("   %-15s %4d   %s", o[1], o[2], VERDICT[o[3]].tag)
			MM:Print("                   %s", o[4])
		end
	end

	------------------------------------------------------------
	local selfC, playerC, nobodyC = 0, 0, 0
	for _, r in ipairs(rows) do
		local m = r.d.total - r.d.withID
		if r.verdict == "selfclosing" then selfC = selfC + m
		elseif r.verdict == "player" then playerC = playerC + m
		else nobodyC = nobodyC + m end
	end
	for _, o in ipairs(other) do
		if o[3] == "selfclosing" then selfC = selfC + o[2]
		elseif o[3] == "player" then playerC = playerC + o[2]
		else nobodyC = nobodyC + o[2] end
	end
	MM:Print("|cffffd84dIn total|r")
	MM:Print("   %5d close themselves in-game, with nobody's help", selfC)
	MM:Print("   %5d want a player who is already standing there  -> /mm contribute", playerC)
	MM:Print("   %5d cannot be known by anyone today", nobodyC)
	MM:Print("   Every one of them is costed PESSIMISTICALLY, so an unknown can")
	MM:Print("   never outrank real work. The ORDER is sound even where the")
	MM:Print("   TOTAL is an upper bound -- see /mm timemodel for the split.")
end)
