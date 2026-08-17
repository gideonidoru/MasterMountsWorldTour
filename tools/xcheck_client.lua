-- Validate our static spellIDs against the CLIENT's own journal data
-- (Data_87_ResolvedIDs was generated from a live game client).
-- Paths come from the environment so this file carries no one's home
-- directory. MM_DIR defaults to the repository this script sits in;
-- the others are only needed by the cross-checks that read them.
local function envdir(name, default)
	local v = os.getenv(name)
	if v and #v > 0 then return (v:gsub("/*$", "") .. "/") end
	return default
end

local p="/Applications/World of Warcraft/_retail_/WTF/Account/GIDEONALT/SavedVariables/MasterMountsWorldTour.lua"
assert(loadfile(p))()
local client = MasterMountsDB.ids and MasterMountsDB.ids.mounts or {}

local opened=0
local files = {"00_Classic","01_TBC","02_WotLK","03_Cataclysm","04_MoP","05_WoD","06_Legion",
  "07_BfA","08_Shadowlands","09_Dragonflight","10_TWW","11_Timewalking","13_GapFill","14_Midnight"}
local agree, bad, unknown = 0, {}, 0
for _,f in ipairs(files) do
  local fh=io.open(envdir("MM_DIR", "./") .. "Data/_source/Data_"..f..".lua")
  if fh then opened=opened+1 for line in fh:lines() do
    local nm=line:match('name%s*=%s*"([^"]+)"')
    local sid=line:match("spellID%s*=%s*(%d+)")
    if nm and sid then
      local c = client[nm:lower()]
      if c and c.spellID then
        if c.spellID == tonumber(sid) then agree = agree + 1
        else bad[#bad+1] = {name=nm, ours=tonumber(sid), client=c.spellID} end
      else unknown = unknown + 1 end
    end
  end fh:close() end
end
assert(opened > 0, "read ZERO source files -- check the Data/_source path; a report built from nothing is worse than no report")

print(("vs CLIENT (authoritative): agree=%d  DISAGREE=%d  not-in-journal=%d"):format(agree,#bad,unknown))
for _,b in ipairs(bad) do print(("  MISMATCH %-36s ours=%-8d client=%d"):format(b.name,b.ours,b.client)) end
