-- Proves the flattened database is identical to the layered one.
--
-- Run after tools/flatten_data.lua. Loads both stacks into separate namespaces
-- and deep-compares every canonical record field by field, in both directions,
-- so neither a dropped field nor an invented one can slip through.
--
--   lua tools/verify_flatten.lua Data/Mounts.lua
--
-- Exits non-zero on any difference. Never ship a regenerated Mounts.lua that
-- has not passed this.

local flatFile = ... or "Data/Mounts.lua"

local function stubs()
	tinsert = table.insert; tremove = table.remove; tsort = table.sort
	wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
	strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
	strsplit = function(_, s) return s end
	C_Map = { GetMapInfo = function() return nil end }
	UnitFactionGroup = function() return nil end
end

local function fresh()
	local MM = { EXPANSIONS = {} }
	MM.Print = function() end
	MM.On = function() end
	return MM
end

local function run(MM, files)
	for _, f in ipairs(files) do
		local chunk, err = loadfile(f)
		if not chunk then error(("load %s: %s"):format(f, tostring(err))) end
		local ok, e = pcall(chunk, "MasterMounts", MM)
		if not ok then error(("run %s: %s"):format(f, tostring(e))) end
	end
end

stubs()

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

local layered, flat = sourceFiles(), { "Data/Schema.lua", flatFile }

local A, B = fresh(), fresh()
run(A, layered)
run(B, flat)

------------------------------------------------------------
-- Deep compare
------------------------------------------------------------
local diffs = 0
local function report(path, msg)
	diffs = diffs + 1
	if diffs <= 40 then print(("  %s: %s"):format(path, msg)) end
end

local function deepEqual(a, b, path)
	if type(a) ~= type(b) then
		report(path, ("type %s vs %s"):format(type(a), type(b)))
		return
	end
	if type(a) ~= "table" then
		-- floats are re-serialised at %.14g; treat a tiny delta as equal
		if type(a) == "number" and a ~= b then
			if math.abs(a - b) > math.max(1e-9, math.abs(a) * 1e-12) then
				report(path, ("%s vs %s"):format(tostring(a), tostring(b)))
			end
			return
		end
		if a ~= b then report(path, ("%q vs %q"):format(tostring(a), tostring(b))) end
		return
	end
	for k, v in pairs(a) do
		if b[k] == nil then report(path .. "." .. tostring(k), "missing in flat")
		else deepEqual(v, b[k], path .. "." .. tostring(k)) end
	end
	for k in pairs(b) do
		if a[k] == nil then report(path .. "." .. tostring(k), "extra in flat") end
	end
end

local function canonical(MM)
	local out = {}
	for _, rec in ipairs(MM.DBList) do
		local isCanon = (rec.spellID and MM.DBBySpell[rec.spellID] == rec)
			or (rec.name and MM.DBByName[rec.name:lower()] == rec)
		if isCanon then out[#out + 1] = rec end
	end
	return out
end

local ca, cb = canonical(A), canonical(B)
print(("records: layered %d, flat %d"):format(#ca, #cb))
if #ca ~= #cb then diffs = diffs + 1 end

-- compare by identity key, not by position, so ordering never masks a swap
local function index(list)
	local by = {}
	for _, r in ipairs(list) do
		by[(r.spellID and ("s" .. r.spellID)) or ("n" .. (r.name or "?"):lower())] = r
	end
	return by
end
local ia, ib = index(ca), index(cb)
for key, rec in pairs(ia) do
	local other = ib[key]
	if not other then report(key, "record missing from flat")
	else deepEqual(rec, other, key) end
end
for key in pairs(ib) do
	if not ia[key] then report(key, "record only in flat") end
end

deepEqual(A.VendorLocations or {}, B.VendorLocations or {}, "VendorLocations")
deepEqual(A.ResolvedIDs or {}, B.ResolvedIDs or {}, "ResolvedIDs")

if diffs == 0 then
	print("IDENTICAL — flat file is a faithful build of the layered sources")
	os.exit(0)
end
print(("%d DIFFERENCE(S) — do not ship"):format(diffs))
os.exit(1)
