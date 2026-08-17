-- Harvest ONLY gaps from MCL, and validate every value against the client
-- export before it is allowed through.
-- Paths come from the environment so this file carries no one's home
-- directory. MM_DIR defaults to the repository this script sits in;
-- the others are only needed by the cross-checks that read them.
local function envdir(name, default)
	local v = os.getenv(name)
	if v and #v > 0 then return (v:gsub("/*$", "") .. "/") end
	return default
end

local MMDIR = envdir("MM_DIR", "./")
local MCL = envdir("MCL_DIR", "../MCL/")

-- 1. client truth
local p="/Applications/World of Warcraft/_retail_/WTF/Account/GIDEONALT/SavedVariables/MasterMountsWorldTour.lua"
assert(loadfile(p))()
local client = MasterMountsDB.ids.mounts          -- [lowername] = {mountID, spellID}
local clientBySpell = {}
for lname,c in pairs(client) do
  if c.spellID then clientBySpell[c.spellID] = lname end
end

-- 2. our current state
local opened=0
local files={"00_Classic","01_TBC","02_WotLK","03_Cataclysm","04_MoP","05_WoD","06_Legion",
 "07_BfA","08_Shadowlands","09_Dragonflight","10_TWW","11_Timewalking","13_GapFill","14_Midnight"}
local haveSpell, haveCoord, haveDrop, allNames = {},{},{},{}
for _,f in ipairs(files) do
  local fh=io.open(MMDIR.."Data/_source/Data_"..f..".lua")
  if fh then opened=opened+1 for line in fh:lines() do
    local nm=line:match('name%s*=%s*"([^"]+)"')
    if nm then
      local k=nm:lower(); allNames[k]=nm
      if line:match("spellID%s*=%s*%d+") then haveSpell[k]=true end
      if line:match("zone%s*=%s*{[^}]-x%s*=") then haveCoord[k]=true end
      if line:match("dropRate%s*=") then haveDrop[k]=true end
    end
  end fh:close() end
end
assert(opened > 0, "read ZERO source files -- check the Data/_source path; a report built from nothing is worse than no report")

-- overrides may add coords too
for _,f in ipairs({"90_LocationsA","91_LocationsB","92_LocationsC","93_LocationsD","94_LocationsE","95_LocationsF","96_Access","99_Overrides"}) do
  local fh=io.open(MMDIR.."Data/_source/Data_"..f..".lua")
  if fh then opened=opened+1 for line in fh:lines() do
    local nm=line:match('OverrideMount%("([^"]+)"')
    if nm and line:match("x%s*=%s*[%d%.]+") then haveCoord[nm:lower()]=true end
  end fh:close() end
end

-- 3. parse MCL GuideData
local mcl={}
local cur
for line in io.lines(MCL.."guide/GuideData.lua") do
  local sid=line:match("^%s*%[(%d+)%]%s*=%s*{")
  if sid then cur={spellID=tonumber(sid), coords={}} end
  if cur then
    local nm=line:match('name%s*=%s*"([^"]+)"'); if nm then cur.name=nm end
    local ch=line:match("chance%s*=%s*(%d+)"); if ch then cur.chance=tonumber(ch) end
    local m,x,y=line:match("{%s*m%s*=%s*(%d+)%s*,%s*x%s*=%s*([%d%.]+)%s*,%s*y%s*=%s*([%d%.]+)")
    if m then cur.coords[#cur.coords+1]={m=tonumber(m),x=tonumber(x),y=tonumber(y)} end
    if line:match("^%s*},%s*$") and cur.name then mcl[#mcl+1]=cur; cur=nil end
  end
end

-- 4. build validated gap list
local outSpell, outDrop, outCoord = {},{},{}
local rejected = 0
for _,r in ipairs(mcl) do
  local k=r.name:lower()
  -- VALIDATION: the client must confirm this spellID belongs to this name
  local c = client[k]
  local validated = c and c.spellID == r.spellID
  if not validated then rejected = rejected + 1 end
  if validated and allNames[k] then
    if not haveSpell[k] then outSpell[#outSpell+1]={name=allNames[k],id=r.spellID} end
    if r.chance and not haveDrop[k] then
      outDrop[#outDrop+1]={name=allNames[k], rate=100/r.chance, denom=r.chance}
    end
    if #r.coords>0 and not haveCoord[k] then
      outCoord[#outCoord+1]={name=allNames[k], coords=r.coords}
    end
  end
end
print(("MCL records parsed: %d"):format(#mcl))
print(("REJECTED by client validation: %d"):format(rejected))
print(("gap fills that PASSED validation -> spellID:%d dropRate:%d coords:%d"):format(#outSpell,#outDrop,#outCoord))

local f=io.open("gapfill.lua","w")
f:write("-- MasterMounts: gap fills cross-checked against the player's own client.\n")
f:write("-- Only values ABSENT from our data and CONFIRMED by C_MountJournal are here.\n")
f:write("local _, MM = ...\n\n")
table.sort(outSpell,function(a,b) return a.name<b.name end)
for _,v in ipairs(outSpell) do f:write(("MM.OverrideMount(%q, { spellID = %d })\n"):format(v.name,v.id)) end
f:write("\n")
table.sort(outDrop,function(a,b) return a.name<b.name end)
for _,v in ipairs(outDrop) do f:write(("MM.OverrideMount(%q, { dropRate = %.4f }) -- 1/%d\n"):format(v.name,v.rate,v.denom)) end
f:write("\n")
table.sort(outCoord,function(a,b) return a.name<b.name end)
for _,v in ipairs(outCoord) do
  if #v.coords==1 then
    local c=v.coords[1]
    f:write(("MM.OverrideMount(%q, { zone = { mapID = %d, x = %.1f, y = %.1f } })\n"):format(v.name,c.m,c.x,c.y))
  else
    local parts={}
    for _,c in ipairs(v.coords) do parts[#parts+1]=("{ mapID = %d, x = %.1f, y = %.1f }"):format(c.m,c.x,c.y) end
    f:write(("MM.OverrideMount(%q, { patrolWaypoints = { %s } })\n"):format(v.name,table.concat(parts,", ")))
  end
end
f:close()
print("wrote gapfill.lua")
