-- Harvest gaps from MountCollector, gated on client validation.
-- Paths come from the environment so this file carries no one's home
-- directory. MM_DIR defaults to the repository this script sits in;
-- the others are only needed by the cross-checks that read them.
local function envdir(name, default)
	local v = os.getenv(name)
	if v and #v > 0 then return (v:gsub("/*$", "") .. "/") end
	return default
end

local MMDIR = envdir("MM_DIR", "./")
local p="/Applications/World of Warcraft/_retail_/WTF/Account/GIDEONALT/SavedVariables/MasterMountsWorldTour.lua"
assert(loadfile(p))()
local client = MasterMountsDB.ids.mounts        -- [lowername]={mountID,spellID}
local clientNPCs = MasterMountsDB.ids.npcs or {} -- [lowername]=creatureID

-- our current state
local opened=0
local files={"00_Classic","01_TBC","02_WotLK","03_Cataclysm","04_MoP","05_WoD","06_Legion",
 "07_BfA","08_Shadowlands","09_Dragonflight","10_TWW","11_Timewalking","13_GapFill","14_Midnight"}
local haveSpell,haveCoord,haveNpcID,allNames,npcNameOf = {},{},{},{},{}
for _,f in ipairs(files) do
  local fh=io.open(MMDIR.."Data/_source/Data_"..f..".lua")
  if fh then opened=opened+1 for line in fh:lines() do
    local nm=line:match('name%s*=%s*"([^"]+)"')
    if nm then
      local k=nm:lower(); allNames[k]=nm
      if line:match("spellID%s*=%s*%d+") then haveSpell[k]=true end
      if line:match("zone%s*=%s*{[^}]-x%s*=") then haveCoord[k]=true end
      local npcnm=line:match('npc = {[^}]-name = "([^"]+)"')
      if npcnm then npcNameOf[k]=npcnm; if line:match("npc = {%s*id = %d+") then haveNpcID[k]=true end end
    end
  end fh:close() end
end
assert(opened > 0, "read ZERO source files -- check the Data/_source path; a report built from nothing is worse than no report")

for _,f in ipairs({"86_GapValidated","90_LocationsA","91_LocationsB","92_LocationsC","93_LocationsD","94_LocationsE","95_LocationsF","96_Access","99_Overrides"}) do
  local fh=io.open(MMDIR.."Data/_source/Data_"..f..".lua")
  if fh then opened=opened+1 for line in fh:lines() do
    local nm=line:match('OverrideMount%("([^"]+)"')
    if nm then
      if line:match("spellID%s*=%s*%d+") then haveSpell[nm:lower()]=true end
      if line:match("x%s*=%s*[%d%.]+") then haveCoord[nm:lower()]=true end
    end
  end fh:close() end
end

-- parse MountCollector
local mc, cur = {}, nil
for line in io.lines(envdir("MOUNTCOLLECTOR_DIR", "../MountCollector/") .. "MountsDB.lua") do
  local nm = line:match("^%s*%[%d+%] = { %-%- (.+)%s*$")
  if nm then cur = { name = nm:gsub("%s+$","") }; mc[#mc+1] = cur end
  if cur then
    local s = line:match("spell_id = (%d+)"); if s then cur.spell = tonumber(s) end
    local n = line:match("npc_id = (%d+)"); if n and not cur.npc then cur.npc = tonumber(n) end
    local cz,cx,cy = line:match("coordzone = (%d+), coordx = ([%d%.]+), coordy = ([%d%.]+)")
    if cz and not cur.coord then cur.coord = {m=tonumber(cz),x=tonumber(cx),y=tonumber(cy)} end
  end
end

-- validated gap output
local oS,oN,oC,rej = {},{},{},0
for _,r in ipairs(mc) do
  -- MountCollector names are ITEM names ("Reins of the X"); normalise to mount name
  local cand = { r.name, (r.name:gsub("^Reins of the ",""):gsub("^Reins of ","")
                          :gsub("'s Reins$",""):gsub(" Reins$","")) }
  local key
  for _,c in ipairs(cand) do if allNames[c:lower()] then key=c:lower() break end end
  if key and r.spell then
    local c = client[key]
    if c and c.spellID == r.spell then                 -- CLIENT-VALIDATED
      if not haveSpell[key] then oS[#oS+1]={allNames[key],r.spell} end
      if r.coord and not haveCoord[key] then oC[#oC+1]={allNames[key],r.coord} end
      -- npc_id: only where our record names that npc and lacks an id
      if r.npc and npcNameOf[key] and not haveNpcID[key] then
        local resolved = clientNPCs[npcNameOf[key]:lower()]
        local agree = (not resolved) or (resolved == r.npc)
        if agree then oN[#oN+1]={allNames[key],npcNameOf[key],r.npc,resolved~=nil} end
      end
    else rej = rej + 1 end
  end
end
print(("MountCollector records: %d | matched to our names: %d | REJECTED by client: %d")
  :format(#mc, #oS+#oN+#oC+rej, rej))
print(("gap fills passing validation -> spellID:%d npc_id:%d coords:%d"):format(#oS,#oN,#oC))

local f=io.open("gapfill2.lua","w")
f:write("-- MasterMounts: gap fills from a third-party addon (MountCollector),\n")
f:write("-- each CROSS-CHECKED against the player's own client before being kept.\n")
f:write("-- Only values we were MISSING appear here; nothing is overwritten.\n")
f:write("local _, MM = ...\n\n")
table.sort(oS,function(a,b) return a[1]<b[1] end)
for _,v in ipairs(oS) do f:write(("MM.OverrideMount(%q, { spellID = %d })\n"):format(v[1],v[2])) end
f:write("\n")
table.sort(oC,function(a,b) return a[1]<b[1] end)
for _,v in ipairs(oC) do
  f:write(("MM.OverrideMount(%q, { zone = { mapID = %d, x = %.1f, y = %.1f } })\n")
    :format(v[1],v[2].m,v[2].x,v[2].y))
end
f:write("\n")
table.sort(oN,function(a,b) return a[1]<b[1] end)
for _,v in ipairs(oN) do
  f:write(("MM.OverrideMount(%q, { npc = { id = %d, name = %q } })%s\n")
    :format(v[1],v[3],v[2], v[4] and " -- client-confirmed" or ""))
end
f:close()
print("wrote gapfill2.lua")
