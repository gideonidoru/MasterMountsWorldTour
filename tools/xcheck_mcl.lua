-- Cross-check our spellIDs against MCL's, using MCL only as a VERIFICATION
-- oracle. Nothing is imported; we only look for disagreements.
-- Paths come from the environment so this file carries no one's home
-- directory. MM_DIR defaults to the repository this script sits in;
-- the others are only needed by the cross-checks that read them.
local function envdir(name, default)
	local v = os.getenv(name)
	if v and #v > 0 then return (v:gsub("/*$", "") .. "/") end
	return default
end

local function norm(s)
  return (s:lower():gsub("^reins of the ",""):gsub("^reins of ",""):gsub("'",""):gsub("[^%w]",""))
end

-- MCL: MCL_GUIDE_DATA.mounts is keyed by spellID with a name field
local mcl = {}
local cur
for line in io.lines(envdir("MCL_DIR", "../MCL/") .. "guide/GuideData.lua") do
  local sid = line:match("^%s*%[(%d+)%]%s*=%s*{")
  if sid then cur = tonumber(sid) end
  local nm = line:match('name%s*=%s*"([^"]+)"')
  if nm and cur then mcl[norm(nm)] = cur; cur = nil end
end

-- ours
local ours = {}
local files = {"00_Classic","01_TBC","02_WotLK","03_Cataclysm","04_MoP","05_WoD","06_Legion",
  "07_BfA","08_Shadowlands","09_Dragonflight","10_TWW","11_Timewalking","13_GapFill","14_Midnight"}
for _,f in ipairs(files) do
  local fh = io.open(envdir("MM_DIR", "./") .. "Data/Data_"..f..".lua")
  if fh then for line in fh:lines() do
    local nm = line:match('name%s*=%s*"([^"]+)"')
    local sid = line:match("spellID%s*=%s*(%d+)")
    if nm and sid then ours[norm(nm)] = { id=tonumber(sid), name=nm } end
  end fh:close() end
end

local agree, conflict, weLack, theyLack = 0,{},0,0
for k,v in pairs(ours) do
  local m = mcl[k]
  if m then
    if m == v.id then agree = agree + 1
    else conflict[#conflict+1] = { name=v.name, ours=v.id, mcl=m } end
  else theyLack = theyLack + 1 end
end
for k in pairs(mcl) do if not ours[k] then weLack = weLack + 1 end end

print(("our spellIDs: %d | MCL spellIDs: %d"):format((function() local n=0 for _ in pairs(ours) do n=n+1 end return n end)(),
  (function() local n=0 for _ in pairs(mcl) do n=n+1 end return n end)()))
print(("AGREE: %d   CONFLICT: %d   only-ours: %d   only-MCL: %d"):format(agree,#conflict,theyLack,weLack))
if #conflict > 0 then
  print("\nCONFLICTS (one of us is wrong - verify against the client/Wowhead):")
  table.sort(conflict, function(a,b) return a.name < b.name end)
  for _,c in ipairs(conflict) do print(("  %-38s ours=%-8d mcl=%d"):format(c.name, c.ours, c.mcl)) end
end
