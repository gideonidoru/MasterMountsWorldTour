-- Dump every canonical mount record as JSON, for offline gap analysis.
--
-- Loads the real layer stack (Schema included) so first-wins and
-- override-merge behave exactly as they do in game. dump_db.lua emits a few
-- tab-separated columns; this emits the whole record, which is what a gap
-- report needs -- "does it have a price" cannot be answered from a name and a
-- category.
tinsert = table.insert; tremove = table.remove; tsort = table.sort
wipe = function(t) for k in pairs(t) do t[k]=nil end return t end
strtrim = function(s) return (s:gsub("^%s+",""):gsub("%s+$","")) end
strsplit = function(sep, s) return s end
C_Map = { GetMapInfo = function() return nil end }
UnitFactionGroup = function() return nil end

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

-- Resolve to a side before dumping, because in game every lookup runs AFTER
-- login has done this. A record whose location arrives with the player's
-- faction reads as having no location at all until then, and counting gaps
-- against the unresolved state invents work that does not exist.
--   lua tools/dump_json.lua Alliance
local faction = arg and arg[1]
if faction then MM.ResolveFactionVariants(faction) end

local esc = { ['"']='\\"', ['\\']='\\\\', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
local function q(s) return '"'..tostring(s):gsub('[%c"\\]', function(c)
  return esc[c] or ("\\u%04x"):format(c:byte()) end)..'"' end

local enc
local function isArray(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end
enc = function(v)
  local tv = type(v)
  if tv == "string" then return q(v) end
  if tv == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then return ("%d"):format(v) end
    return ("%.6g"):format(v)
  end
  if tv == "boolean" then return v and "true" or "false" end
  if tv == "table" then
    if isArray(v) then
      local out = {}
      for i = 1, #v do out[i] = enc(v[i]) end
      return "["..table.concat(out, ",").."]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys+1] = tostring(k) end
    table.sort(keys)
    local out = {}
    for _, k in ipairs(keys) do
      -- NOT `v[k] ~= nil and v[k] or v[tonumber(k)]`. When v[k] is FALSE the
      -- and/or idiom falls through to the right-hand side and emits null, so
      -- every `obtainable = false` in the database came out of this tool as
      -- "absent". Both read as falsy in the gap tests, which is why it went
      -- unnoticed -- and why "I marked it false and nothing changed" was
      -- impossible to diagnose from the JSON.
      local val = v[k]
      if val == nil then val = v[tonumber(k)] end
      out[#out+1] = q(k)..":"..enc(val)
    end
    return "{"..table.concat(out, ",").."}"
  end
  return "null"
end

local list = {}
for _, r in ipairs(MM.DBList) do
  local canon = (r.spellID and MM.DBBySpell[r.spellID] == r)
    or (r.name and MM.DBByName[r.name:lower()] == r)
  if canon then list[#list+1] = r end
end
io.stderr:write(("files=%d fails=%d records=%d\n"):format(#files, fails, #list))
if fails > 0 then os.exit(1) end
print(enc(list))
