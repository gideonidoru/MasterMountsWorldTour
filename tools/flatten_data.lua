-- Build step: collapse the layered data files into one flat file.
--
-- In development the database is 30-odd files: fourteen per-expansion sources
-- plus override layers (Data_83..Data_99) that patch them. That layering is good
-- for editing and terrible for loading -- roughly 1,970 OverrideMount calls run
-- on every login, each walking a table and merging conditions by identity, to
-- arrive at a result that is completely deterministic.
--
-- This script runs the whole layer stack once, offline, and emits the finished
-- records as a single MM.AddMounts call. The shipped addon loads that instead.
--
-- SAFETY: this is only sound because nothing in the data layer depends on the
-- player. It was checked before writing this:
--   * MM.ResolveFactionVariants is called from Core.lua at RUNTIME with the
--     player's faction, not during data load, so `altSources` and
--     `factionOverlay` must survive into the flat file untouched. They do.
--   * MM.GetRecordLocation resolves map names at runtime, not load.
-- If either ever moves to load time, this script starts baking one character's
-- answers into everyone's copy. Re-check before trusting it again.
--
-- Usage, from the addon root:
--   lua tools/flatten_data.lua > Data/Mounts.lua
--   lua tools/verify_flatten.lua      # proves the flat file matches the layers

tinsert = table.insert; tremove = table.remove; tsort = table.sort
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
strsplit = function(_, s) return s end
C_Map = { GetMapInfo = function() return nil end }
UnitFactionGroup = function() return nil end

-- Deliberately NOT a global. A global MM would mask a data file that forgot its
-- `local _, MM = ...` binding -- exactly the bug that silently killed
-- Data_85/Data_86 for months. Let those files fail loudly here instead.
local MM = { EXPANSIONS = {} }
MM.Print = function() end
MM.On = function() end

local function sourceFiles()
	local files = {}
	for line in io.lines("Data/_source/ORDER.txt") do
		local name = line:match("^%s*([%w_]+%.lua)%s*$")
		if name then
			files[#files + 1] = (name == "Schema.lua") and "Data/Schema.lua"
				or ("Data/_source/" .. name)
		end
	end
	return files
end

-- Order comes from ORDER.txt, not the TOC (the TOC now ships only the flat
-- file) and not the filesystem (alphabetical would put Data_13 before Data_15
-- and flip which record is canonical).
local files = sourceFiles()
for _, f in ipairs(files) do
	local chunk, err = assert(loadfile(f), tostring(err) .. " " .. f)
	assert(pcall(chunk, "MasterMounts", MM))
end

------------------------------------------------------------
-- Serialisation
------------------------------------------------------------
-- Keys are emitted in a stable order so regenerating the file produces a
-- readable diff instead of a reshuffle.
local KEY_ORDER = {
	"name", "spellID", "altSpellIDs", "mountID", "itemID", "expansion", "category", "obtainable",
	"faction", "source", "vendor", "npc", "zone", "instance", "calling",
	"questChain", "acquire", "conditions", "altSources", "factionOverlay",
	"dropRate", "attempts", "timePerAttempt", "effort", "trackingQuest",
	"holidayGate", "anyEra", "blackmarket", "access", "notes",
}
local ORDER_INDEX = {}
for i, k in ipairs(KEY_ORDER) do ORDER_INDEX[k] = i end

local function sortedKeys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, function(a, b)
		local ia, ib = ORDER_INDEX[a], ORDER_INDEX[b]
		if ia and ib then return ia < ib end
		if ia then return true end
		if ib then return false end
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function isArray(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n > 0 and #t == n
end

local function fmtNumber(v)
	if v == math.floor(v) and math.abs(v) < 1e15 then
		return string.format("%d", v)
	end
	-- %.14g round-trips a double without printing 33.333300000000001
	return string.format("%.14g", v)
end

local ser
function ser(v, indent)
	local t = type(v)
	if t == "string" then return string.format("%q", v) end
	if t == "number" then return fmtNumber(v) end
	if t == "boolean" then return tostring(v) end
	if t ~= "table" then error("cannot serialise " .. t) end

	local pad = string.rep("\t", indent)
	local inner = string.rep("\t", indent + 1)
	local parts = {}
	if isArray(v) then
		for _, item in ipairs(v) do
			parts[#parts + 1] = inner .. ser(item, indent + 1)
		end
	else
		for _, k in ipairs(sortedKeys(v)) do
			local key = (type(k) == "string" and k:match("^[%a_][%w_]*$"))
				and (k .. " = ")
				or ("[" .. ser(k, indent + 1) .. "] = ")
			parts[#parts + 1] = inner .. key .. ser(v[k], indent + 1)
		end
	end
	if #parts == 0 then return "{}" end
	return "{\n" .. table.concat(parts, ",\n") .. ",\n" .. pad .. "}"
end

------------------------------------------------------------
-- Emit
------------------------------------------------------------
local out = io.write

out("-- Master Mounts: flattened mount database. GENERATED -- DO NOT EDIT.\n")
out("--\n")
out("-- Produced by tools/flatten_data.lua from the layered sources in\n")
out("-- Data/_source/. Edit those and regenerate; edits here are lost.\n")
out("--\n")
out("-- Every override in Data_83..Data_99 is already applied. `altSources` and\n")
out("-- `factionOverlay` are preserved verbatim because MM.ResolveFactionVariants\n")
out("-- consumes them at runtime, once the player's faction is known.\n")
out("local _, MM = ...\n\n")

-- Only canonical records: duplicates already live inside altSources, and
-- re-emitting them would make AddMounts rebuild the same nesting a second time.
local canonical = {}
for _, rec in ipairs(MM.DBList) do
	local isCanon = (rec.spellID and MM.DBBySpell[rec.spellID] == rec)
		or (rec.name and MM.DBByName[rec.name:lower()] == rec)
	if isCanon then canonical[#canonical + 1] = rec end
end

-- Emitted in chunks rather than one 870KB table constructor.
--
-- We test-compile with Lua 5.5; WoW runs 5.1, whose parser has tighter limits on
-- constants and instructions per function. A single constructor this size is
-- probably fine there and would be a miserable thing to discover otherwise, so
-- it is split. AddMounts is additive, so N calls and one call are equivalent.
local CHUNK = 300
out(("-- %d mounts, in chunks of %d\n"):format(#canonical, CHUNK))
for first = 1, #canonical, CHUNK do
	local part = {}
	for i = first, math.min(first + CHUNK - 1, #canonical) do
		part[#part + 1] = canonical[i]
	end
	out("MM.AddMounts(" .. ser(part, 0) .. ")\n\n")
end

local vendorCount = 0
for _ in pairs(MM.VendorLocations or {}) do vendorCount = vendorCount + 1 end
if vendorCount > 0 then
	out(("-- %d vendor locations\n"):format(vendorCount))
	out("MM.AddVendorLocations(" .. ser(MM.VendorLocations, 0) .. ")\n\n")
end

if MM.ResolvedIDs then
	out("-- client-resolved IDs\n")
	out("MM.AddResolvedIDs(" .. ser(MM.ResolvedIDs, 0) .. ")\n")
end

-- WHAT WAS REMOVED, AND WHAT THE REMOVAL WAS FOR.
--
-- Both of these are built by code that runs HERE and never in the client: the
-- phantom removals happen at build time, and the Quantum Courser's source is
-- appended to sixteen records at build time. The shipped addon sees only the
-- result, so two self-test checks written against these tables could never run
-- there -- they reported "not declared" and were counted as degraded, which is
-- the same as not having written them.
--
-- Emitting the declarations turns both into checks the client CAN run, and the
-- questions change with the setting. At build time they ask whether the removal
-- and the append landed. Shipped, they ask whether the result survived: that no
-- phantom name has come back, that no real counterpart was taken down with its
-- duplicate, and that all sixteen pool members still carry the source.
if MM.removedPhantoms and #MM.removedPhantoms > 0 then
	out(("\n-- %d records removed as phantoms, with the mount each was a copy of\n")
		:format(#MM.removedPhantoms))
	out("MM.removedPhantoms = " .. ser(MM.removedPhantoms, 0) .. "\n")
end

if MM.quantumCourserPool and #MM.quantumCourserPool > 0 then
	out(("\n-- the %d mounts Reins of the Quantum Courser can grant\n")
		:format(#MM.quantumCourserPool))
	out("MM.quantumCourserPool = " .. ser(MM.quantumCourserPool, 0) .. "\n")
end

if MM.timewalkingGated and #MM.timewalkingGated > 0 then
	out(("\n-- the %d Timewalking mounts catalogued under another category\n")
		:format(#MM.timewalkingGated))
	out("MM.timewalkingGated = " .. ser(MM.timewalkingGated, 0) .. "\n")
end

if MM.timeRiftMounts and #MM.timeRiftMounts > 0 then
	out(("\n-- the %d Time Rift mounts, with the rift and vendor that sells each\n")
		:format(#MM.timeRiftMounts))
	out("MM.timeRiftMounts = " .. ser(MM.timeRiftMounts, 0) .. "\n")
end

io.stderr:write(("flattened %d source files -> %d canonical records, %d vendor locations\n")
	:format(#files, #canonical, vendorCount))

-- A PRICE THAT LANDS ON NOTHING IS A PRICE THAT DID NOT HAPPEN.
--
-- SetConditionAmount finds its condition BY NAME and returns false when it
-- finds none. Every caller ignored that, so renaming a condition priced
-- nothing and said nothing -- two covenant mounts lost their cost, and it
-- surfaced two reports later as a contribution gap. This is the only place
-- the calls actually run: the flat file resolves them at build time, so the
-- shipped addon never executes one and no in-client check can see this.
local function refuse(list, headline)
	if #list == 0 then return false end
	io.stderr:write(("\n%d %s -- refusing to install:\n"):format(#list, headline))
	for _, why in ipairs(list) do io.stderr:write("   " .. why .. "\n") end
	return true
end

local bad = false
bad = refuse(MM.conditionAmountMisses or {}, "PRICE(S) LANDED ON NOTHING") or bad

-- A NAME THAT MATCHES NOTHING REMOVES NOTHING, AND SAYS NOTHING.
--
-- Both of these resolve records by name and both fail by doing exactly what
-- success looks like from the outside. A mistyped phantom leaves the record in
-- place and the audit goes on calling it a missing mount; a pool member that no
-- longer resolves quietly shrinks the pool from sixteen. Same shape as the
-- price misses above, and the same answer.
bad = refuse(MM.phantomMisses or {}, "PHANTOM NAME(S) MATCHED NO RECORD") or bad
bad = refuse(MM.quantumCourserMisses or {},
	"QUANTUM COURSER POOL MEMBER(S) NO LONGER RESOLVE") or bad
bad = refuse(MM.timewalkingGateMisses or {},
	"TIMEWALKING GATE NAME(S) MATCHED NO RECORD") or bad
bad = refuse(MM.timeRiftMisses or {},
	"TIME RIFT MOUNT NAME(S) MATCHED NO RECORD") or bad

-- AND THE REMOVAL MUST NOT TAKE ANYTHING WITH IT. Every override layer naming
-- the duplicate spelling applied to the record about to be deleted, so its work
-- vanished when the record did -- an instance block, a "no reagent list" flag.
-- Anything the copy held and the record kept does not is reported here; the
-- deliberate ones are waived in Data_99zzZp_Phantoms.
bad = refuse(MM.phantomLostFields or {}, "FIELD(S) LOST TO A PHANTOM REMOVAL") or bad

if bad then os.exit(1) end
