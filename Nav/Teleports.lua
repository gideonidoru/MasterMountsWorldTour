-- Master Mounts: teleport-aware travel.
--
-- Walking guidance that ignores your hearthstone is guidance that wastes your
-- time. This layer asks a different question before every long leg: "is there
-- something on your bars, in your bags or in your toybox that puts you closer
-- than flying will?"
--
-- Design notes, and where this deliberately differs from other route addons
-- (MIT, the one genuinely reusable piece of that addon -- its guide data is
-- commercial and is not used here):
--
--  * Cost blends into travel distance instead of living on its own scale, so a
--    teleport competes with flying on equal terms.
--  * REMAINING COOLDOWN IS PART OF THE COST, not a hard rejection. A hearthstone
--    coming off cooldown in 20 seconds is nearly free; one with 25 minutes left
--    prices itself out without any special case.
--  * Recommendations are STICKY. the complaint about other route addons is that they
--    recalculates constantly and never sounds sure of itself. A new option has
--    to beat the standing one by a clear margin (BETTER_BY) before we change our
--    mind, so the advice stays put while you act on it.
--  * Every rejection carries a REASON, visible via /mm travel. Silent absence is
--    indistinguishable from a bug.
local _, MM = ...
local U = MM.Util

MM.Teleports = {}
local TP = MM.Teleports

-- Rough flying speed, used to price waiting-for-cooldown in the same unit as
-- distance. Waiting 60s is about as costly as flying 1,500 yards.
local YARDS_PER_SECOND = 25
-- A teleport has to beat flying by this much before it is worth suggesting.
local WORTH_IT = 0.8
-- ...and beat the STANDING recommendation by this much before we switch.
local BETTER_BY = 0.75

------------------------------------------------------------
-- Options
------------------------------------------------------------
-- dest is a function returning mapID, x, y -- resolved live, because a
-- hearthstone's destination is wherever the player last bound it.
--
-- Only options whose destination can be resolved on THIS client are offered.
-- A hardcoded map ID that has drifted is worse than no suggestion at all, so
-- nothing here trusts an ID it has not just looked up by name.
local OPTIONS = {
	{
		key = "hearth", item = 6948, name = "Hearthstone",
		verb = "Use your Hearthstone",
		dest = function()
			local bind = MM.Util.ReadableString(GetBindLocation and GetBindLocation())
			if not bind or bind == "" then return nil end
			-- Most players are bound to an INN, and an inn's name is a subzone,
			-- not a map -- "Wayfarer's Rest" resolves to nothing. Falling back to
			-- "no hearthstone routing" for the common case was useless, so we
			-- learn it instead: whenever you stand in a subzone whose name
			-- matches your bind point, we record which map that is.
			local learned = MM.db.hearthMaps and MM.db.hearthMaps[bind]
			if learned then return learned, 50, 50, bind end
			local mapID = U.ResolveMapByName(bind)
			if mapID then return mapID, 50, 50, bind end
			return nil, ("bound to %q — stand there once and we'll learn the map"):format(bind)
		end,
	},
	{
		key = "ghearth", item = 110560, name = "Garrison Hearthstone",
		verb = "Use your Garrison Hearthstone",
		dest = function()
			-- Lunarfall / Frostwall. Both IDs are name-checked below before use.
			local want = (UnitFactionGroup("player") == "Horde")
				and { 590, "Frostwall" } or { 582, "Lunarfall" }
			local info = C_Map.GetMapInfo(want[1])
			if not (info and info.name == want[2]) then
				return nil, ("map %d is no longer %s"):format(want[1], want[2])
			end
			return want[1], 50, 50, want[2]
		end,
	},
}

------------------------------------------------------------
-- Continent hops
------------------------------------------------------------
-- Requirement — geography should not really matter at all, its all about time to travel
-- to destination, if something is a 10 minute flight but on the same continent
-- it should lose to something that is a Wormhole toy + 2 minute flight.
--
-- Exactly the point, and it is why two options were never enough. A hearthstone
-- and a garrison hearthstone can only ever make two places cheap; the things
-- that actually collapse the map are the wormhole toys, and without them the
-- router had no way to know that Northrend is two minutes away.
--
-- Every id below was resolved through Wowhead's tooltip API and confirmed to
-- name the item we meant. The DESTINATION is declared as a continent NAME and
-- resolved on this client at runtime, never as a hardcoded map id -- same rule
-- as the hearthstone above, for the same reason.
--
-- A wormhole drops you somewhere random on its continent, so the continent
-- centre is not an approximation we are apologising for: it is the honest
-- expected landing point.
-- Everything else the player might be able to travel with.
--
-- Requirement — the routing logic should take into consideration EVERY form of travel
-- available to the player (e.g. teleport items [cloaks etc], wormhole toys and
-- other toys if they can use them [right profession], airships, boats, teleport
-- NPCs, mage spells if they are a mage or faction spells like DKs order hall
-- teleport).
--
-- Schema, so adding one is a data change and never a code change:
--
--   item / spell  what you press. Ownership is checked against the bags, the
--                 toybox or the spellbook -- never assumed.
--   requires      class, faction or profession, any combination, each checked
--                 on its own. The wormhole generators require Engineering --
--                 which any class can have -- and were previously offered to
--                 everyone. Every requirement below was read off the live
--                 tooltip, not assumed from the item's flavour.
--   place         destination as a NAME, resolved on this client. A hardcoded
--                 map id that has drifted is worse than no suggestion.
--   bind          destination is wherever the player is bound.
--
-- Every id here was resolved through Wowhead's tooltip API and confirmed to
-- name the thing meant, including which faction's version is which -- Cloak of
-- Coordination is two different items and getting them backwards would send
-- Horde players to Stormwind.
-- Requirement — The engineering requirements are sometimes per faction, for instance
-- the Zandalar wormhole requires Kul Tiran engineering if youre alliance but
-- not if youre horde.
--
-- Right: Battle for Azeroth's engineering skill line is named for whichever
-- continent your faction levelled it on -- Kul Tiran for Alliance, Zandalari
-- for Horde -- and it is ONE tier, so either name satisfies either wormhole.
-- Wowhead only ever shows one of the two, so reading the tooltip alone would
-- have locked out half the players.
--
-- `skillLine` therefore accepts a list of acceptable names, which also leaves
-- room for the next expansion that does this.
-- ONE SKILL LINE, TWO NAMES, and the client picks by faction.
--
-- SkillLine 2499 is DisplayName "Kul Tiran Engineering" and HordeDisplayName
-- "Zandalari Engineering" -- the same profession, labelled differently
-- depending on who is reading. Both generators require that one line, so both
-- names have to be accepted: a Horde engineer never sees the Alliance string
-- and would be refused a wormhole they can plainly use.
--
-- IT IS THE ONLY ENGINEERING LINE THAT DOES THIS. Every other one -- Draenor,
-- Legion, Shadowlands, Dragon Isles, Khaz Algar, Midnight -- carries the same
-- name for both factions, which is why the single-name entries below are safe
-- and why this one is not.
local BFA_ENGINEERING = { "Kul Tiran Engineering", "Zandalari Engineering" }

local MORE = {
	-- Engineering wormholes: a random spot on their continent, which is exactly
	-- what continent-level routing wants.
	--
	-- Each needs a SPECIFIC EXPANSION's Engineering at a specific level, and the
	-- levels are not all 1. Every line and number below is read off the live
	-- tooltip -- including the one nobody would guess, that the ZANDALAR
	-- wormhole requires KUL TIRAN Engineering.
	{ key = "wh_northrend", item = 48933, place = "Northrend",
		name = "Wormhole Generator: Northrend", requires = { skillLine = "Northrend Engineering", level = 40 } },
	{ key = "wh_pandaria", item = 87215, place = "Pandaria",
		name = "Wormhole Generator: Pandaria", requires = { skillLine = "Pandaria Engineering", level = 1 } },
	{ key = "wh_argus", item = 151652, place = "Argus",
		name = "Wormhole Generator: Argus", requires = { skillLine = "Legion Engineering", level = 1 } },
	{ key = "wh_kultiras", item = 168807, place = "Kul Tiras",
		name = "Wormhole Generator: Kul Tiras", requires = { skillLine = BFA_ENGINEERING, level = 1 } },
	{ key = "wh_zandalar", item = 168808, place = "Zandalar",
		name = "Wormhole Generator: Zandalar", requires = { skillLine = BFA_ENGINEERING, level = 1 } },
	{ key = "wh_shadowlands", item = 172924, place = "Shadowlands",
		name = "Wormhole Generator: Shadowlands", requires = { skillLine = "Shadowlands Engineering", level = 1 } },
	{ key = "wh_dragonisles", item = 198156, place = "Dragon Isles",
		name = "Wyrmhole Generator: Dragon Isles", requires = { skillLine = "Dragon Isles Engineering", level = 1 } },
	{ key = "wh_khazalgar", item = 221966, place = "Khaz Algar",
		name = "Wormhole Generator: Khaz Algar", requires = { skillLine = "Khaz Algar Engineering", level = 1 } },
	-- TWO GAPS, AND THE REQUIREMENTS ARE READ RATHER THAN REMEMBERED.
	--
	-- The comment above says every line was taken off a live tooltip, and that
	-- standard is kept: these come from the client's own item table, which
	-- carries the required skill line and rank directly. The method was checked
	-- against the three already here before being trusted -- it reproduces
	-- Northrend at rank 40 and, more to the point, the Zandalar generator
	-- needing KUL TIRAN Engineering, which is the one nobody would guess.
	--
	-- Destinations come from each spell's own description, not from the item's
	-- name: the Centrifuge says "travel around Draenor" and the Quel'Thalas
	-- generator says "a random Midnight location", which is Quel'Thalas.
	{ key = "wh_draenor", item = 112059, place = "Draenor",
		name = "Wormhole Centrifuge", requires = { skillLine = "Draenor Engineering", level = 1 } },
	{ key = "wh_quelthalas", item = 248485, place = "Quel'Thalas",
		name = "Wormhole Generator: Quel'Thalas", requires = { skillLine = "Midnight Engineering", level = 1 } },

	-- Engineering transporters: fixed destinations, and the only fast way into
	-- a couple of otherwise awkward corners. These are the expensive ones --
	-- Classic Engineering 260 and Outland 50, not the level 1 the wormholes led
	-- me to assume.
	{ key = "tp_gadgetzan", item = 18986, place = "Tanaris",
		name = "Ultrasafe Transporter: Gadgetzan",
		requires = { skillLine = "Classic Engineering", level = 260 } },
	{ key = "tp_everlook", item = 18984, place = "Winterspring",
		name = "Dimensional Ripper - Everlook",
		requires = { skillLine = "Classic Engineering", level = 260 } },
	{ key = "tp_toshley", item = 30544, place = "Blade's Edge Mountains",
		name = "Ultrasafe Transporter: Toshley's Station",
		requires = { skillLine = "Outland Engineering", level = 50 } },
	{ key = "tp_area52", item = 30542, place = "Netherstorm",
		name = "Dimensional Ripper - Area 52",
		requires = { skillLine = "Outland Engineering", level = 50 } },

	-- Capital cloaks. Three separate items with three separate cooldowns, so a
	-- player holding all of them has three shots at the capital, not one.
	{ key = "cloak_coord", item = 65360, place = "Stormwind City",
		name = "Cloak of Coordination", requires = { faction = "Alliance" } },
	{ key = "cloak_coord", item = 65274, place = "Orgrimmar",
		name = "Cloak of Coordination", requires = { faction = "Horde" } },
	{ key = "wrap_unity", item = 63206, place = "Stormwind City",
		name = "Wrap of Unity", requires = { faction = "Alliance" } },
	{ key = "wrap_unity", item = 63207, place = "Orgrimmar",
		name = "Wrap of Unity", requires = { faction = "Horde" } },
	{ key = "shroud_coop", item = 63352, place = "Stormwind City",
		name = "Shroud of Cooperation", requires = { faction = "Alliance" } },
	{ key = "shroud_coop", item = 63353, place = "Orgrimmar",
		name = "Shroud of Cooperation", requires = { faction = "Horde" } },

	-- A second hearthstone in all but name: same destination, own cooldown.
	{ key = "naaru", item = 206195, bind = true, name = "Path of the Naaru" },
	-- Dalaran Hearthstone: its own cooldown, not the hearthstone's, so it is a
	-- SECOND free trip rather than a different flavour of the same one. Widely
	-- held and it lands somewhere the route genuinely uses.
	--
	-- Found by walking every toy in the client through ItemXItemEffect to its
	-- spell and reading that spell's description -- a toy's teleport is in the
	-- spell, not in the item's flavour text, which is why looking at item text
	-- alone found almost nothing.
	{ key = "dalaran_hearth", item = 140192, place = "Dalaran",
		name = "Dalaran Hearthstone" },
	-- No profession, no faction: the client's item table gives it no required
	-- skill at all, and its spell says plainly where it goes.
	{ key = "arcantina_key", item = 253629, place = "Arcantina",
		name = "Personal Key to the Arcantina" },

	-- Class travel.
	{ key = "deathgate", spell = 50977, place = "Acherus: The Ebon Hold",
		name = "Death Gate", requires = { class = "DEATHKNIGHT" } },
	{ key = "moonglade", spell = 18960, place = "Moonglade",
		name = "Teleport: Moonglade", requires = { class = "DRUID" } },
	{ key = "dreamwalk", spell = 193753, place = "The Emerald Dreamway",
		name = "Dreamwalk", requires = { class = "DRUID" } },
	{ key = "zenpilgrimage", spell = 126892, place = "The Peak of Serenity",
		name = "Zen Pilgrimage", requires = { class = "MONK" } },
	{ key = "astralrecall", spell = 556, bind = true,
		name = "Astral Recall", requires = { class = "SHAMAN" } },

	-- Mage city teleports. One spell per destination and each on its own short
	-- cooldown, which makes a mage's route a fundamentally different shape.
	{ key = "mage_sw", spell = 3561, place = "Stormwind City", name = "Teleport: Stormwind",
		requires = { class = "MAGE", faction = "Alliance" } },
	{ key = "mage_if", spell = 3562, place = "Ironforge", name = "Teleport: Ironforge",
		requires = { class = "MAGE", faction = "Alliance" } },
	{ key = "mage_darn", spell = 3565, place = "Darnassus", name = "Teleport: Darnassus",
		requires = { class = "MAGE", faction = "Alliance" } },
	{ key = "mage_exo", spell = 32271, place = "The Exodar", name = "Teleport: Exodar",
		requires = { class = "MAGE", faction = "Alliance" } },
	{ key = "mage_org", spell = 3567, place = "Orgrimmar", name = "Teleport: Orgrimmar",
		requires = { class = "MAGE", faction = "Horde" } },
	{ key = "mage_uc", spell = 3563, place = "Undercity", name = "Teleport: Undercity",
		requires = { class = "MAGE", faction = "Horde" } },
	{ key = "mage_tb", spell = 3566, place = "Thunder Bluff", name = "Teleport: Thunder Bluff",
		requires = { class = "MAGE", faction = "Horde" } },
	{ key = "mage_smc", spell = 32272, place = "Silvermoon City", name = "Teleport: Silvermoon",
		requires = { class = "MAGE", faction = "Horde" } },
	{ key = "mage_dal_nr", spell = 53140, place = "Dalaran", name = "Teleport: Dalaran - Northrend",
		requires = { class = "MAGE" } },
	{ key = "mage_dal_bi", spell = 224869, place = "Broken Isles",
		name = "Teleport: Dalaran - Broken Isles", requires = { class = "MAGE" } },
	{ key = "mage_boralus", spell = 281403, place = "Boralus", name = "Teleport: Boralus",
		requires = { class = "MAGE", faction = "Alliance" } },
	{ key = "mage_dazar", spell = 281404, place = "Dazar'alor", name = "Teleport: Dazar'alor",
		requires = { class = "MAGE", faction = "Horde" } },
	{ key = "mage_oribos", spell = 344587, place = "Oribos", name = "Teleport: Oribos",
		requires = { class = "MAGE" } },
	{ key = "mage_valdrakken", spell = 395277, place = "Valdrakken", name = "Teleport: Valdrakken",
		requires = { class = "MAGE" } },
	-- THE LIST STOPPED AT DRAGONFLIGHT. A mage's city teleports are the biggest
	-- single travel advantage any class has, and the catalogue ended one
	-- expansion back -- so a mage was routed the long way to everything in Khaz
	-- Algar while holding a thirty-second answer.
	--
	-- Spell id read from the client's own SpellName table, not from memory.
	{ key = "mage_dornogal", spell = 446540, place = "Dornogal", name = "Teleport: Dornogal",
		requires = { class = "MAGE" } },
	-- MIDNIGHT'S SILVERMOON IS NOT THE OLD ONE, and both are live at once.
	--
	-- Five spells in the client are called some variant of "Teleport:
	-- Silvermoon". Four of them are not a mage's: SkillLineAbility puts only
	-- 1259190 and its portal on skill line 904, which is how this was settled
	-- rather than by picking the newest id and hoping.
	--
	-- The destination is the Midnight city -- map 2393, the node the transit
	-- links already call "Silvermoon City M" -- and NOT the Burning Crusade
	-- Silvermoon above, which keeps its own teleport because it is still a
	-- different place you can still need to reach.
	{ key = "mage_smc_midnight", spell = 1259190, place = "Silvermoon City M",
		name = "Teleport: Silvermoon City", requires = { class = "MAGE" } },
}

for _, o in ipairs(MORE) do
	OPTIONS[#OPTIONS + 1] = {
		key = o.key, item = o.item, spell = o.spell, name = o.name,
		requires = o.requires,
		verb = o.spell and ("Cast " .. o.name) or ("Use your " .. o.name),
		dest = function()
			if o.bind then
				local bind = MM.Util.ReadableString(GetBindLocation and GetBindLocation())
				if not bind or bind == "" then return nil, "no bind location" end
				local learned = MM.db.hearthMaps and MM.db.hearthMaps[bind]
				if learned then return learned, 50, 50, bind end
				local mapID = U.ResolveMapByName(bind)
				if mapID then return mapID, 50, 50, bind end
				return nil, ("bound to %q — stand there once and we'll learn the map"):format(bind)
			end
			local mapID = U.ResolveMapByName(o.place)
			if not mapID then
				return nil, ("this client has no map called %q"):format(o.place)
			end
			return mapID, 50, 50, o.place
		end,
	}
end

-- DUNGEON AND RAID TELEPORTS.
--
-- The route is led by INSTANCE goals and these land you at the door, from
-- anywhere, so for a player who has earned them they matter more to a route
-- than any flight path. We modelled 19 teleport spells in total; this is 76
-- more, and none of the ones that count.
--
-- OWNERSHIP IS ALWAYS ASKED, NEVER ASSUMED. Each carries a spell id and goes
-- through the same IsPlayerSpell check as every other spell option below, so a
-- teleport this character has not earned can never shorten its route. That is
-- the whole reason to key them by spell id rather than by name.
--
-- Unlike the list above these know exactly where they land, so they hand back
-- their real coordinate instead of the centre of the zone.
for _, t in ipairs(MM.DungeonTeleports or {}) do
	OPTIONS[#OPTIONS + 1] = {
		key = "dungeontp_" .. t.spell .. (t.faction or ""),
		spell = t.spell,
		name = t.name,
		requires = t.faction and { faction = t.faction } or nil,
		verb = "Cast " .. t.name,
		dest = function()
			-- The map id is carried, but a client that has never heard of it is
			-- the authority, not us: a stale id points somewhere that no longer
			-- exists and every distance measured to it is fiction.
			if not (C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(t.mapID)) then
				return nil, ("this client has no map %d for %q"):format(t.mapID, t.place)
			end
			return t.mapID, t.x, t.y, t.place
		end,
	}
end

------------------------------------------------------------
-- Availability
------------------------------------------------------------
TP.rejections = {} -- populated on every Evaluate, for /mm travel
-- Every option Evaluate priced, with the arithmetic that priced it.
--
-- Written BY the decision rather than reconstructed after it. A diagnostic that
-- recomputes the answer separately is checking our homework against our
-- homework -- it agrees precisely when it is least useful. This is the real
-- ledger: if it says the cloak cost 2.3 minutes, that is the number that won.
TP.considered = {}

-- GCD leaks into item/spell cooldown queries: a 1.5s global would otherwise
-- read as "this hearthstone is on cooldown".
local function cooldownRemaining(option)
	local start, duration
	if option.item then
		start, duration = C_Container.GetItemCooldown(option.item)
	elseif option.spell and C_Spell and C_Spell.GetSpellCooldown then
		local info = C_Spell.GetSpellCooldown(option.spell)
		if info then start, duration = info.startTime, info.duration end
	end
	if not (start and duration) or duration <= 1.5 then return 0 end
	return math.max(0, start + duration - GetTime())
end

-- Class, faction and profession gates.
--
-- Three independent gates, and they really are independent: profession is not a
-- proxy for class and class is not a proxy for profession. Any class can be an
-- Engineer, so the wormhole gate asks whether you have Engineering and nothing
-- else; the mage teleports ask about class and nothing else.
--
-- Checked BEFORE ownership, because "you don't have Engineering" is a more
-- useful rejection than "you don't have it" for something you could never use
-- anyway.
local function meetsRequirements(option)
	local req = option.requires
	if not req then return true end
	if req.class then
		local _, class = UnitClass("player")
		if class ~= req.class then return false, "not a " .. req.class:lower() end
	end
	if req.faction and UnitFactionGroup("player") ~= req.faction then
		return false, req.faction .. " only"
	end
	if req.profession then
		local skill = MM.Conditions and MM.Conditions.ProfessionSkill
			and MM.Conditions.ProfessionSkill(req.profession)
		if not skill then return false, "requires " .. req.profession end
	end
	if req.skillLine then
		local C = MM.Conditions
		if not (C and C.SkillLineLevel) then
			return false, "cannot read profession skill lines on this client"
		end
		-- one name or several: several because a tier can be named per faction
		local wanted = type(req.skillLine) == "table" and req.skillLine or { req.skillLine }
		local best, bestName
		for _, name in ipairs(wanted) do
			local level = C.SkillLineLevel(name)
			if level and level > (best or -1) then best, bestName = level, name end
		end
		if not best or best == 0 then
			-- The struct reads 0 for every line on this client, including
			-- professions the player demonstrably has -- a test character has
			-- Alchemy and Inscription and every expansion line came back
			-- skillLevel=0, maxSkillLevel=0. The data is not populated until
			-- something opens that skill line.
			--
			-- So fall back to the API that does work. `GetProfessions` cannot
			-- say WHICH expansion line you have or how far, which is why it
			-- cannot replace the reader -- but "do you have Engineering at all"
			-- is enough to settle a level-1 requirement, and most of them are
			-- level 1. Anything wanting a real number still refuses, and says
			-- why, rather than silently guessing.
			local base = wanted[1]:match("(%a+)%s*$")
			local C2 = MM.Conditions
			if base and C2 and C2.HasProfession and C2.HasProfession(base) then
				if (req.level or 1) <= 1 then
					return true
				end
				return false, ("%s %d needed; your skill level is not readable on this client")
					:format(bestName or wanted[1], req.level)
			end
			return false, "requires " .. table.concat(wanted, " or ")
		end
		if req.level and best < req.level then
			return false, ("%s %d, you have %d"):format(bestName, req.level, best)
		end
	end
	return true
end

-- Returns true, or false plus the reason -- the reason is the whole point.
-- TURNED OFF BY HAND.
--
-- Asked for directly: "I don't want it to suggest my M+ dungeon teleports."
-- They are a real saving and the router is right to price them, but a player
-- who is saving those charges for a key would rather walk, and no amount of
-- modelling can know that.
--
-- Checked HERE, in the one gate every caller already goes through, so a switched
-- off option disappears from the route, the landing list and the evaluator at
-- once -- and TP.Gates reports the reason, so it reads as a decision rather than
-- as a teleport that mysteriously stopped being offered.
function TP.IsOff(key)
	local off = MM.db and MM.db.teleportsOff
	return (key and off and off[key]) and true or false
end

function TP.SetOff(key, off)
	if not (key and MM.db) then return end
	MM.db.teleportsOff = MM.db.teleportsOff or {}
	MM.db.teleportsOff[key] = off or nil
	snapshot = nil
	if MM.Fire then MM:Fire("MM_PLAN_CHANGED") end
end

-- The dungeon and raid teleports as one group, because that is how the request
-- arrived and how anybody would think of them.
function TP.DungeonKeys()
	local out = {}
	for _, option in ipairs(OPTIONS) do
		if option.key and option.key:find("^dungeontp_") then out[#out + 1] = option.key end
	end
	return out
end

local function usable(option, ignoreOff)
	if not ignoreOff and TP.IsOff(option.key) then
		return false, "you turned this one off"
	end
	local allowed, why = meetsRequirements(option)
	if not allowed then return false, why end

	if option.item then
		local have = (C_Item.GetItemCount(option.item) or 0) > 0
		if not have and PlayerHasToy then have = PlayerHasToy(option.item) end
		if not have then return false, "you don't have it" end
	end
	if option.spell then
		local known = IsPlayerSpell and IsPlayerSpell(option.spell)
		if known == nil and IsSpellKnown then known = IsSpellKnown(option.spell) end
		if not known then return false, "spell not known" end
	end
	if UnitOnTaxi("player") then return false, "you're on a taxi" end
	if InCombatLockdown() then return false, "in combat" end
	return true
end

------------------------------------------------------------
-- Travel time
------------------------------------------------------------
-- The router's cost model, and the answer to "geography shouldn't matter, time
-- should". Everything here is MINUTES.
--
-- Flying speed is a rough average and that is fine: what changes a route is the
-- difference between two minutes and twenty, not between nine and eleven.
local YARDS_PER_MINUTE = YARDS_PER_SECOND * 60

-- Getting to another continent with no teleport at all: portal hub, boat, the
-- usual shuffle. Deliberately expensive, because it genuinely is.
local CROSS_CONTINENT_MINUTES = 8
-- Casting, loading and getting your bearings after any teleport.
local TELEPORT_OVERHEAD_MINUTES = 0.5

------------------------------------------------------------
-- Portal hubs
------------------------------------------------------------
-- the player, standing in Zuldazar with three Orgrimmar teleports in their bags, was
-- told to fly to the Dazar'alor portal room and "take the portal to Orgrimmar,
-- then the Dornogal portal". The engine had rejected all three of those items
-- with "lands on a different continent".
--
-- The instruction refutes the rejection. The route WANTED the player in Orgrimmar --
-- Orgrimmar is not a different continent to be avoided, it is the portal room
-- he was being sent to reach the long way round. A landing is not only useful
-- where it lands; it is useful for everywhere it CONNECTS to.
--
-- So a landing now has a second leg. Teleport into a hub, take the portal out,
-- fly the remainder. Nothing here is free: the hop is priced, crossing the
-- portal room is priced, and the flight at the far end is measured like any
-- other. It simply stops pretending the portal room does not exist.

-- Crossing a portal room and taking the portal: find it, run to it, load.
local HUB_TRANSIT_MINUTES = 1.5

-- Where a portal drops you on each continent. Keyed by continent id, which is
-- what GetWorldPos returns, so these resolve at runtime and a mapID we have
-- wrong simply yields no arrival rather than a wrong one.
local ARRIVALS = {
	[0]    = { mapID = 84,   x = 49.5, y = 86.5, name = "Stormwind" },
	[1]    = { mapID = 85,   x = 57.0, y = 89.0, name = "Orgrimmar" },
	[530]  = { mapID = 111,  x = 57.0, y = 48.0, name = "Shattrath" },
	[571]  = { mapID = 125,  x = 55.0, y = 47.0, name = "Dalaran" },
	[870]  = { mapID = 371,  x = 45.0, y = 45.0, name = "the Jade Forest" },
	[1116] = { mapID = 588,  x = 50.0, y = 50.0, name = "Ashran" },
	[1220] = { mapID = 627,  x = 55.0, y = 45.0, name = "Dalaran" },
	[1642] = { mapID = 1165, x = 51.3, y = 46.7, name = "Dazar'alor" },
	[1643] = { mapID = 1161, x = 70.5, y = 17.2, name = "Boralus" },
	[2222] = { mapID = 1670, x = 50.0, y = 50.0, name = "Oribos" },
	[2444] = { mapID = 2112, x = 59.5, y = 41.5, name = "Valdrakken" },
	[2552] = { mapID = 2339, x = 57.0, y = 50.0, name = "Dornogal" },
}

-- Which landings open the portal network, and how far it reaches.
--
-- The faction capitals reach effectively everywhere -- that is the entire point
-- of their portal rooms -- so they are `true`. The expansion hubs carry a
-- portal home and little else, so they are listed explicitly rather than
-- credited with connections they do not have. Being wrong in the generous
-- direction here would send someone through a portal that is not there.
local HUB_BY_ZONE = {
	["Orgrimmar"] = true,
	["Stormwind City"] = true,
	["Valdrakken"] = { [0] = true, [1] = true, [2552] = true },
	["Dornogal"] = { [0] = true, [1] = true, [2444] = true },
	["Oribos"] = { [0] = true, [1] = true },
	["Shattrath City"] = { [0] = true, [1] = true },
	["Dalaran"] = { [0] = true, [1] = true },
	["Dazar'alor"] = { [1] = true },
	["Boralus"] = { [0] = true },
}

-- Resolved lazily: continent -> arrival world position.
--
-- Only SUCCESS is cached. Map data is not available for a few seconds after
-- login, and caching an early failure would silently disable hub routing for
-- the rest of the session -- a bug that would look exactly like the one this
-- whole section exists to fix.
local arrivalWorld = {}
function TP.ForgetArrivals() wipe(arrivalWorld) end

local function arrivalFor(continent)
	local cached = arrivalWorld[continent]
	if cached then return cached end
	local spec = ARRIVALS[continent]
	if not spec then return nil end
	local c, world = U.GetWorldPos(spec.mapID, spec.x, spec.y)
	-- The arrival must actually BE on the continent it claims, or the mapID is
	-- wrong and every route built on it would be wrong too.
	if not world or c ~= continent then return nil end
	arrivalWorld[continent] = { world = world, name = spec.name }
	return arrivalWorld[continent]
end

-- Does a landing in `place` reach `continent` through a portal, and at what
-- cost? Returns extra minutes and the arrival, or nil when there is no such
-- portal. Takes the place name rather than a landing so callers that only have
-- a name need not build a table to ask.
local function hubReach(place, continent)
	local reach = place and HUB_BY_ZONE[place]
	if not reach then return nil end
	if reach ~= true and not reach[continent] then return nil end
	-- A hub does not portal to itself.
	if ARRIVALS[continent] and ARRIVALS[continent].name == place then return nil end
	local arrival = arrivalFor(continent)
	if not arrival then return nil end
	return HUB_TRANSIT_MINUTES, arrival
end

-- Where each usable option would put you, priced in minutes of waiting.
-- `used` is a set of option keys already spent on this route.
--
-- Each teleport is offered ONCE per route. Modelling real cooldown recovery
-- would mean inventing base cooldowns we have not verified, and one use per
-- route is both conservative and true of almost every real session.
-- One pass over every option: ownership, gates, destination resolution and
-- cooldown. This is EXPENSIVE -- roughly ten C API calls per option across
-- forty-odd options -- so it must happen once per route build and never inside
-- a loop.
--
-- It was inside a loop. `TravelMinutes` called it for every candidate stop on
-- every greedy iteration, so a 150-stop plan re-read the entire toybox,
-- spellbook and profession list about eleven thousand times -- several million
-- C calls, and a client frozen for minutes. Snapshot once, reuse.
function TP.Snapshot()
	local list = {}
	for _, option in ipairs(OPTIONS) do
		if usable(option) then
			local mapID, x, y, placeName = option.dest()
			if mapID then
				local continent, world = U.GetWorldPos(mapID, x or 50, y or 50)
				if world then
					list[#list + 1] = {
						key = option.key, name = option.name, verb = option.verb,
						continent = continent, world = world, place = placeName,
						waitMinutes = cooldownRemaining(option) / 60,
						-- What it actually IS, carried through. A landing named
						-- only by its key cannot be audited: a check asking
						-- "does this character really have this" had nothing to
						-- ask the client about, and re-deriving the id from the
						-- key string is guessing at our own data.
						spell = option.spell, item = option.item,
					}
				end
			end
		end
	end
	return list
end

-- The live snapshot. Rebuilt on demand, dropped when the world changes.
local snapshot, snapshotAt

-- Cooldowns tick down continuously and fire no event, so an event-driven
-- snapshot alone goes quietly stale: a hearthstone with twenty minutes left
-- would still read twenty minutes an hour later. Events catch what CHANGED,
-- this catches what merely got older.
local SNAPSHOT_TTL = 30

function TP.Refresh()
	snapshot = TP.Snapshot()
	snapshotAt = GetTime and GetTime() or 0
	return snapshot
end

function TP.Options()
	local now = GetTime and GetTime() or 0
	if not snapshot or (now - (snapshotAt or 0)) > SNAPSHOT_TTL then TP.Refresh() end
	return snapshot
end

-- Anything that could change what you can press drops the snapshot. Event
-- driven rather than time based: a stale answer here sends someone flying when
-- they had a portal.
for _, event in ipairs({ "BAG_UPDATE_DELAYED", "SPELLS_CHANGED", "TOYS_UPDATED",
	"PLAYER_ENTERING_WORLD", "HEARTHSTONE_BOUND", "SKILL_LINES_CHANGED",
	"UPDATE_INSTANCE_INFO" }) do
	MM:RegisterGameEvent(event, function() snapshot = nil end)
end
-- Arrivals resolve against map data, which is absent for a moment after a
-- world change. Drop them with it so a miss is retried rather than remembered.
MM:RegisterGameEvent("PLAYER_ENTERING_WORLD", function() wipe(arrivalWorld) end)

-- Every option with its verdict, for diagnostics. Deliberately reports the
-- REASON: an option that silently never appears is indistinguishable from one
-- we forgot to add.
-- Every option this character could actually press, with its switch state.
-- Deliberately not the whole catalogue: a list of eighty teleports nobody has
-- earned is not a setting, it is a wall.
function TP.Switchable()
	local out = {}
	for _, option in ipairs(OPTIONS) do
		local ok = usable(option, true)
		if ok then
			local _, _, _, placeName = option.dest()
			out[#out + 1] = {
				key = option.key,
				name = option.name,
				place = placeName or option.place,
				dungeon = option.key and option.key:find("^dungeontp_") ~= nil,
				off = TP.IsOff(option.key),
			}
		end
	end
	table.sort(out, function(a, b)
		if a.dungeon ~= b.dungeon then return not a.dungeon end
		return (a.name or "") < (b.name or "")
	end)
	return out
end

function TP.Gates()
	local out = {}
	for _, option in ipairs(OPTIONS) do
		local ok, why = usable(option)
		if ok then
			local mapID, _, _, placeName = option.dest()
			if not mapID then ok, why = false, "destination unresolved" end
			out[#out + 1] = { name = option.name, usable = ok, why = why,
				place = placeName }
		else
			out[#out + 1] = { name = option.name, usable = false, why = why }
		end
	end
	return out
end

function TP.Landings(used)
	if not used then return TP.Options() end
	local out = {}
	for _, landing in ipairs(TP.Options()) do
		if not used[landing.key] then out[#out + 1] = landing end
	end
	return out
end

local function flightMinutes(fromWorld, toWorld)
	local d = U.WorldDistance(fromWorld, toWorld)
	if not d then return nil end
	return d / YARDS_PER_MINUTE
end

-- Minutes to reach (toContinent, toWorld), and how. Returns minutes, method
-- (nil when flying is the answer).
--
-- This is the whole model in one function: flying is one option among several
-- rather than the baseline everything else has to beat. A ten-minute flight on
-- your own continent losing to a wormhole plus two minutes is not a special
-- case here -- it is just arithmetic.
function TP.TravelMinutes(fromContinent, fromWorld, toContinent, toWorld, used)
	local best, method, best_via

	-- Same continent -- including "both unknown" -- means you can fly it.
	--
	-- The earlier version required both continents to be non-nil, so two stops
	-- whose continent we had failed to resolve were priced at the flat
	-- cross-continent cost and became indistinguishable: known positions were
	-- thrown away because a less important field was missing. Distance is worse
	-- information than travel time, and far better than none.
	if fromContinent == toContinent then
		best = flightMinutes(fromWorld, toWorld)
	end
	-- Genuinely different continents, or nothing to measure: the slow way.
	best = best or CROSS_CONTINENT_MINUTES

	-- Iterate the snapshot directly and skip spent keys in place. Building a
	-- filtered copy per call allocated a table for every candidate stop on every
	-- greedy iteration, which is the same mistake one layer down.
	for _, landing in ipairs(TP.Options()) do
		if not (used and used[landing.key]) then
			local leg, extra, via
			if landing.continent == toContinent then
				-- lands where we are going: fly the remainder
				leg, extra = flightMinutes(landing.world, toWorld), 0
			else
				-- lands somewhere else -- but if that somewhere is a portal hub
				-- that reaches the target continent, the trip is still on
				extra, via = hubReach(landing.place, toContinent)
				if extra then leg = flightMinutes(via.world, toWorld) end
			end
			if leg then
				local cost = landing.waitMinutes + TELEPORT_OVERHEAD_MINUTES + extra + leg
				if cost < best then best, method, best_via = cost, landing, via end
			end
		end
	end

	return best, method, best_via
end

------------------------------------------------------------
-- Evaluation
------------------------------------------------------------

-- Best teleport toward a goal, or nil. `goalWorld` is a world position and
-- `flyCost` the distance you would otherwise cover under your own power.
function TP.Evaluate(goalContinent, goalWorld, flyCost)
	wipe(TP.rejections)
	wipe(TP.considered)
	if not (goalWorld and flyCost) then return nil end

	local best, bestCost
	for _, option in ipairs(OPTIONS) do
		local ok, why = usable(option)
		local mapID, x, y, placeName
		if ok then
			-- dest() returns either (mapID, x, y, name) or (nil, reason)
			local a, b, c, d = option.dest()
			if a then
				mapID, x, y, placeName = a, b, c, d
			else
				ok, why = false, b or "destination unknown"
			end
		end

		if ok then
			local continent, world = U.GetWorldPos(mapID, x or 50, y or 50)
			local from, via = world, nil
			if not world then
				ok, why = false, "destination has no world position"
			elseif continent ~= goalContinent then
				-- Not where we are going -- but a portal hub is not a dead end.
				-- This is the rejection that sent the player flying to a portal room
				-- he had three items to skip.
				local extra, arrival = hubReach(placeName, goalContinent)
				if extra then
					from, via = arrival.world, arrival
				else
					ok, why = false, ("lands in %s, which has no portal onward")
						:format(placeName or "another continent")
				end
			end
			if ok then
				-- what the trip actually costs: the hop, the portal room if we
				-- go through one, then the flight in
				local remaining = cooldownRemaining(option)
				local flight = U.WorldDistance(from, goalWorld) or math.huge
				local hop = via and HUB_TRANSIT_MINUTES * YARDS_PER_MINUTE or 0
				local cost = flight + remaining * YARDS_PER_SECOND + hop
				tinsert(TP.considered, {
					name = option.name, place = placeName, cost = cost,
					flight = flight, wait = remaining, hub = hop, via = via,
					minutes = cost / YARDS_PER_MINUTE,
				})
				if cost < (bestCost or math.huge) then
					best, bestCost = {
						option = option, cost = cost, mapID = mapID,
						world = world, place = placeName,
						cooldown = remaining, via = via,
					}, cost
				end
			end
		end

		if not ok then
			tinsert(TP.rejections, ("%s — %s"):format(option.name, why or "?"))
		end
	end

	if not best then return nil end
	-- Flying is the incumbent; a teleport must clearly beat it.
	if bestCost >= flyCost * WORTH_IT then
		tinsert(TP.rejections, ("%s — flying is about as fast"):format(best.option.name))
		return nil
	end
	return best
end

------------------------------------------------------------
-- Sticky recommendation
------------------------------------------------------------
-- Other route addons are strong but flicker: they re-solve constantly and the
-- advice changes under you mid-action. Once we have said "use your hearthstone"
-- we keep saying it until that stops being true or something is clearly better.
local standing -- { key, goalKey, cost }

function TP.Best(goalContinent, goalWorld, flyCost, goalKey)
	local fresh = TP.Evaluate(goalContinent, goalWorld, flyCost)

	if standing and standing.goalKey ~= goalKey then
		standing = nil -- different goal entirely; no loyalty owed
	end

	if not fresh then
		standing = nil
		return nil
	end

	if standing and standing.key ~= fresh.option.key then
		-- hold the current advice unless the newcomer is decisively better
		if fresh.cost > standing.cost * BETTER_BY then
			return standing.result
		end
	end

	standing = { key = fresh.option.key, goalKey = goalKey,
		cost = fresh.cost, result = fresh }
	return fresh
end

function TP.Clear() standing = nil end

-- Instruction text for the arrow's guidance card.
function TP.Describe(best)
	if not best then return nil end
	local o = best.option
	local where = best.place and (" » " .. best.place) or ""
	-- A hub hop has a second leg, and leaving it out would be the same failure
	-- in a friendlier voice: "Use your Cloak of Coordination" with no mention of
	-- the portal afterwards drops the player in Orgrimmar wondering why.
	if best.via then
		local detail = ("Then the %s portal — %s"):format(best.via.name,
			(best.cooldown and best.cooldown > 0)
				and ("ready in " .. U.FormatSeconds(best.cooldown))
				or "still beats flying the whole way")
		return ("%s%s"):format(o.verb, where), detail
	end
	if best.cooldown and best.cooldown > 0 then
		return ("%s%s"):format(o.verb, where),
			("Ready in %s — still quicker than flying"):format(U.FormatSeconds(best.cooldown))
	end
	return ("%s%s"):format(o.verb, where), "Ready now — faster than flying there"
end

-- /mm travel — what the travel layer considered, and why it said no
MM:On("MM_TRAVEL_DEBUG", function()
	-- Say what the travel data actually covers, before pricing anything.
	--
	-- Two datasets feed routing now and both can be silently absent -- a file
	-- missing from the .toc loads nothing and errors never. Printing the counts
	-- means "the route looks wrong" can be answered without guessing which
	-- half is missing.
	if MM.FlightSeconds then
		local nodes, edges = 0, 0
		for _, nb in pairs(MM.FlightSeconds) do
			nodes = nodes + 1
			for _ in pairs(nb) do edges = edges + 1 end
		end
		MM:Print("  Flight times: %d nodes, %d measured hops.", nodes, edges)
	else
		MM:Print("  |cffff4444No measured flight times loaded.|r")
	end
	if MM.Network and MM.Network.Coverage then
		local n, e, maps = MM.Network.Coverage()
		MM:Print("  Travel network: %d endpoints, %d connections, %d maps.", n, e, maps)
	else
		MM:Print("  |cffff4444No travel network loaded.|r")
	end

	local cur = MM.Router and MM.Router:Current()
	if not (cur and cur.world) then
		MM:Print("No active route goal to evaluate travel for.")
		return
	end
	local _, playerWorld = U.PlayerWorldPos()
	local fly = playerWorld and U.WorldDistance(playerWorld, cur.world)
	local best = TP.Evaluate(cur.continent, cur.world, fly)
	MM:Print("Travel options toward %s (flying: %s yds):", cur.label,
		fly and ("%d"):format(fly) or "?")
	if best then
		MM:Print("  |cff40d860chosen:|r %s » %s%s", best.option.name,
			best.place or "?",
			best.via and (" then the " .. best.via.name .. " portal") or "")
	else
		MM:Print("  |cffff9a3cnothing beats flying|r")
	end

	-- Everything that was priced, cheapest first, WITH the arithmetic.
	--
	-- The runners-up are the point. A choice shown alone cannot be argued with;
	-- a choice shown beside what it beat, and by how much, can be checked --
	-- and a wrong constant announces itself as a number that is obviously off
	-- rather than as a route that merely feels wrong.
	table.sort(TP.considered, function(a, b) return a.cost < b.cost end)
	if #TP.considered > 0 then
		MM:Print("  |cffffd84dpriced (cheapest first):|r")
		for i, c in ipairs(TP.considered) do
			if i > 8 then
				MM:Print("     ...and %d more", #TP.considered - 8)
				break
			end
			local parts = { ("%.1f min flight"):format(c.flight / YARDS_PER_MINUTE) }
			if c.hub > 0 then
				tinsert(parts, ("%.1f portal room"):format(c.hub / YARDS_PER_MINUTE))
			end
			if c.wait > 0 then
				tinsert(parts, ("%.1f cooldown"):format(c.wait / 60))
			end
			MM:Print("     %-38s %5.1f min  = %s", c.name .. " » " .. (c.place or "?"),
				c.minutes, table.concat(parts, " + "))
		end
	end

	-- Rejections, grouped. Forty separate lines saying "not a mage" buried the
	-- one line that mattered; the reason is the information, not the repetition.
	local byReason, order = {}, {}
	for _, r in ipairs(TP.rejections) do
		local name, why = r:match("^(.-) — (.*)$")
		why = why or r
		if not byReason[why] then byReason[why] = {}; order[#order + 1] = why end
		tinsert(byReason[why], name or r)
	end
	table.sort(order, function(a, b) return #byReason[a] > #byReason[b] end)
	if #order > 0 then MM:Print("  |cff9a9a9anot considered:|r") end
	for _, why in ipairs(order) do
		local names = byReason[why]
		if #names > 3 then
			MM:Print("     %-46s ×%d", why, #names)
		else
			MM:Print("     %-46s %s", why, table.concat(names, ", "))
		end
	end

	-- The profession picture, because the wormhole gates now depend on it and a
	-- wrong answer here is invisible otherwise: the option simply never appears.
	local C = MM.Conditions
	local all = (C and C.SkillLines) and C.SkillLines() or {}
	local learned = (C and C.LearnedSkillLines) and C.LearnedSkillLines() or {}
	-- Report both. The catalogue count proves the API answered; the learned
	-- count is the one that decides whether a wormhole appears.
	MM:Print("|cffffd84dProfessions:|r %d skill lines levelled (of %d in the game)",
		#learned, #all)
	local primary = {}
	if GetProfessions then
		for _, index in ipairs({ GetProfessions() }) do
			if index and GetProfessionInfo then
				local name = GetProfessionInfo(index)
				if name then primary[#primary + 1] = name end
			end
		end
	end
	MM:Print("   GetProfessions says: %s",
		#primary > 0 and table.concat(primary, ", ") or "|cff9a9a9anone|r")
	if #learned == 0 then
		MM:Print("   |cff9a9a9aNothing levelled, so every skill-line gate refuses --|r")
		MM:Print("   |cff9a9a9awhich is correct on a character with no professions.|r")
	end
	for _, line in ipairs(learned) do
		MM:Print("   %s — %d/%d", line.label, line.level, line.max)
	end
	-- Raw struct fields for a couple of lines. When GetProfessions and the
	-- skill-line reader disagree -- and on a live client they did, Alchemy and
	-- Inscription against 0/0 everywhere -- the field names are the suspect and
	-- guessing at them is how this stays broken.
	if #learned == 0 and #all > 0 then
		MM:Print("   |cffffd84dRaw fields, so the reader can be corrected:|r")
		for i = 1, math.min(3, #all) do
			MM:Print("     %s: %s", all[i].label, all[i].raw or "(no numeric fields)")
		end
	end
	MM:Print("|cffffd84dTravel options and their gates:|r")
	for _, o in ipairs(TP.Gates()) do
		MM:Print("   %-38s %s", o.name,
			o.usable and "|cff40d860usable|r"
				or ("|cff9a9a9a" .. (o.why or "?") .. "|r"))
	end
end)

------------------------------------------------------------
-- Learning where the hearthstone goes
------------------------------------------------------------
-- No API reports the MAP a hearthstone returns you to -- only the subzone name.
-- But the player visits that inn, and when they do, the current subzone matches
-- GetBindLocation() and the current map is the answer. Record it once and the
-- hearthstone becomes routable from then on, for that bind point, forever.
local function learnBind()
	local bind = MM.Util.ReadableString(GetBindLocation and GetBindLocation())
	if not bind or bind == "" then return end
	MM.db.hearthMaps = MM.db.hearthMaps or {}
	if MM.db.hearthMaps[bind] then return end

	local here = GetSubZoneText and GetSubZoneText()
	if not here or here == "" or here ~= bind then return end

	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID then return end
	MM.db.hearthMaps[bind] = mapID
	TP.Clear() -- the standing recommendation was made without this
	MM:Print("Learned your hearthstone: %s is on map %d. Travel routing will use it now.",
		bind, mapID)
end

MM:RegisterGameEvent("ZONE_CHANGED", learnBind)
MM:RegisterGameEvent("ZONE_CHANGED_INDOORS", learnBind)
MM:RegisterGameEvent("PLAYER_ENTERING_WORLD", learnBind)
-- Rebinding invalidates nothing we stored (the old inn is still on that map),
-- but the new bind point needs learning in turn.
MM:RegisterGameEvent("HEARTHSTONE_BOUND", learnBind)

