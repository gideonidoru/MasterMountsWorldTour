-- Load the real data layer (Schema included) outside WoW and dump every record.
-- Using the actual Schema means first-wins and override-merge semantics match
-- what the addon does in game, rather than an approximation.
tinsert = table.insert; tremove = table.remove; tsort = table.sort
strsplit = function(sep, s) return s end
wipe = function(t) for k in pairs(t) do t[k]=nil end return t end
strtrim = function(s) return (s:gsub("^%s+",""):gsub("%s+$","")) end
C_Map = { GetMapInfo = function() return nil end }
UnitFactionGroup = function() return "Horde" end

MM = { EXPANSIONS = {} }
local MM = MM
MM.Print = function() end
MM.On = function() end
MM.AddResolvedIDs = function() end

local files = { "Data/Schema.lua" }
for line in io.lines("MasterMountsWorldTour.toc") do
  local f = line:match("^(Data\\[%w_]+%.lua)%s*$")
  if f and not f:find("Schema") then files[#files+1] = f:gsub("\\", "/") end
end

local fails = 0
for _, f in ipairs(files) do
  local chunk, err = loadfile(f)
  if not chunk then fails = fails + 1; io.stderr:write("LOAD FAIL "..f.." "..tostring(err).."\n")
  else
    local ok, e = pcall(chunk, "MasterMounts", MM)
    if not ok then fails = fails + 1; io.stderr:write("RUN FAIL "..f.." "..tostring(e).."\n") end
  end
end

-- Only CANONICAL records: MM.AddMounts keeps the first record for a mount and
-- demotes later duplicates to altSources, so iterating DBList double-counts
-- (e.g. the Timewalking-cache entry for a raid drop that is already catalogued).
local list = {}
for _, r in ipairs(MM.DBList) do
  local canon = (r.spellID and MM.DBBySpell[r.spellID] == r)
    or (r.name and MM.DBByName[r.name:lower()] == r)
  if canon then list[#list+1] = r end
end
io.stderr:write(("files=%d fails=%d records=%s\n"):format(#files, fails, list and #list or "nil"))
if not list then os.exit(1) end
for _, r in ipairs(list) do
  print(table.concat({ r.name or "", tostring(r.spellID or ""),
    r.category or "", tostring(r.expansion or ""),
    (r.obtainable == false) and "NO" or "yes",
    (r.source or ""):gsub("%s+"," ") }, "\t"))
end
