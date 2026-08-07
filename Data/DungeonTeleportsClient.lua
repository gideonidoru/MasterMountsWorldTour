-- MasterMounts: dungeon teleports read from the CLIENT, not from an export.
--
-- DungeonTeleports.lua is generated from a third-party ability file, and that
-- file drifts. Checked spell by spell against the client's own tables it was
-- eleven teleports behind live, and one id it did carry was not a teleport at
-- all: 393272, shipped as the Algeth'ar Academy teleport, is
-- "[DNT] Eclipse Lake - WQ 01 - Ping - 3" in the client's Spell table -- an
-- internal test entry. IsPlayerSpell was therefore false for every player
-- alive and that teleport had never once been offered to anyone.
--
-- A WRONG SPELL ID FAILS SILENTLY AND FOREVER. Nothing errors, nothing is
-- missing from any list, the route is simply longer than it needed to be. That
-- is why these are keyed by id and why the ids are now read from the source
-- that decides the answer.
--
-- Names come from SpellName; destinations from each spell's own description,
-- which states them outright ("Teleport to the entrance of X"). Coordinates
-- are NOT invented -- they are the ones the shipped travel network already
-- holds for that place, which is the same rule the generator follows.
local _, MM = ...

-- Corrections: the name is right, the id was not.
local FIX = {
	["Path of the Draconic Diploma"] = 393273,
}

local ADD = {
	{spell=373262,name="Path of the Fallen Guardian",place="Karazhan",mapID=42,x=47.30,y=75.30,cooldown=28800,cast=10},
	{spell=1254559,name="Path of Cavernous Depths",place="Maisara Caverns",mapID=2437,x=43.85,y=39.53,cooldown=28800,cast=10},
	{spell=1286807,name="Path of the Worthy Aspirant",place="Den of Nalorakk",mapID=2437,x=29.87,y=84.49,cooldown=28800,cast=10},
	{spell=1286809,name="Path of the Devious Smuggler",place="Murder Row",mapID=2393,x=57.02,y=61.08,cooldown=28800,cast=10},
	{spell=1286828,name="Path of the Sacred Temple",place="Temple of Sethraliss",mapID=864,x=52.00,y=25.00,cooldown=28800,cast=10},
	{spell=1286831,name="Path of the Slumbering Conqueror",place="Kings' Rest",mapID=862,x=38.00,y=39.00,cooldown=28800,cast=10},
}

-- LEFT OUT, deliberately. These are real teleports the client knows about,
-- and the shipped travel network has no node for where they land -- so there
-- is no coordinate to point at. A teleport aimed at a guess is worse than one
-- absent: it would win the route on a distance nobody measured.
--

--   1254563  Path of the Fractured Core         -> Nexus-Point Xenas
--   1286801  Path of the Blooming Verdure       -> The Blinding Vale
--   1286804  Path of the Brutal Combatant       -> Voidscar Arena
--   1286812  Path of Venomous Evolution         -> Altar of Fangs

-- Cooldown and cast match every one of the 76 already shipped -- 28800 and 10,
-- without exception -- rather than a figure guessed per row.
local by_name = {}
for _, t in ipairs(MM.DungeonTeleports or {}) do by_name[t.name] = t end

for name, spell in pairs(FIX) do
	local t = by_name[name]
	if t then t.spell = spell end
end

for _, t in ipairs(ADD) do
	-- Never a duplicate: if the generated file gains one of these later, the
	-- one that is already there wins and this stays inert.
	if not by_name[t.name] then
		MM.DungeonTeleports[#MM.DungeonTeleports + 1] = t
	end
end

