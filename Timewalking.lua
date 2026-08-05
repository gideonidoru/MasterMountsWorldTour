-- Master Mounts timewalking: knows whether a Timewalking week is active and
-- turns Timewarped Badge costs into "dungeons you still need to run".
local _, MM = ...
local U = MM.Util

MM.Timewalking = {}
local TW = MM.Timewalking

TW.CURRENCY_ID = 1166        -- Timewarped Badge
TW.BADGES_PER_RUN = 55       -- ~10/boss plus end-of-run bonus, conservative
TW.WEEKLY_QUEST_BONUS = 500  -- the "complete 5 timewalking dungeons" turn-in

-- Calendar titles for TW weeks are NOT literally "Timewalking": Blizzard uses
-- the "A <adjective> Path Through Time" series, plus "Turbulent Timeways" for
-- the meta event. Match the whole family.
local function isTimewalkingTitle(lowerTitle)
	return lowerTitle:find("timewalking", 1, true)
		or lowerTitle:find("turbulent", 1, true)
		or lowerTitle:find("path through time", 1, true)
end

function TW.IsActive()
	-- primary: the past-week Begins-marker scan (TW entries only exist on
	-- Tuesdays); fallback: any TW-ish title on today's calendar
	if MM.Availability.twActive then return true end
	for title in pairs(MM.Availability.activeEvents) do
		if isTimewalkingTitle(title:lower()) then return true end
	end
	return false
end

-- Which era's Timewalking is running, best-effort from calendar titles.
-- Ordered, most specific first.
--
-- This used to be a keyed table walked with `pairs`, which has no defined
-- iteration order in Lua -- so a description matching two eras' needles could
-- return a different answer on different runs. An ordered list makes the result
-- deterministic and lets the specific needles win over the loose ones.
--
-- Dragonflight was missing entirely, which is why a Dragonflight Timewalking
-- week parsed as nil and the scan silently fell back to the PREVIOUS week's era.
local ERA_ORDER = {
	{ "Dragonflight",           { "dragonflight", "dragon isles" } },
	-- Shadowlands Timewalking is real: Collector Ta'steld sells it in the Ring
	-- of Fates, Oribos. Both the vendor and the city are unique to Shadowlands,
	-- so they identify the era as reliably as its name does.
	{ "Shadowlands",            { "shadowlands", "oribos", "ta'steld" } },
	{ "Battle for Azeroth",     { "battle for azeroth", "kul tiras", "zandalar" } },
	{ "Legion",                 { "broken isles", "legion", "fel " } },
	{ "Warlords of Draenor",    { "warlords", "draenor", "savage" } },
	{ "Mists of Pandaria",      { "pandaria", "shrouded", "mists" } },
	{ "Cataclysm",              { "cataclysm", "shattered" } },
	{ "Wrath of the Lich King", { "lich king", "northrend", "frozen", "wrath" } },
	{ "Burning Crusade",        { "burning crusade", "outland", "burning" } },
	-- "classic" on its own is far too loose -- it matched the 20th Anniversary
	-- Frayfeather Hippogryph, which is not Classic Timewalking stock at all.
	-- Harmless today because only badge purchases are era-gated, but a needle
	-- that is wrong for a reason other than the guard is a bug in waiting.
	{ "Classic",                { "classic timewalking", "classic era" } },
}


-- Parse an era name out of arbitrary event text; nil = couldn't tell.
function TW.ParseEra(text)
	if not text then return nil end
	for _, entry in ipairs(ERA_ORDER) do
		for _, needle in ipairs(entry[2]) do
			if text:find(needle, 1, true) then return entry[1] end
		end
	end
	return nil
end

-- The active era if known, else nil (unknown never era-gates anything).
function TW.ActiveEra()
	if MM.Availability.twEra then return MM.Availability.twEra end
	for title in pairs(MM.Availability.activeEvents) do
		local t = title:lower()
		if isTimewalkingTitle(t) then
			local era = TW.ParseEra(t)
			if era then return era end
		end
	end
	return nil
end

-- Era name for a record's expansion index (vendor stock is era-locked).
TW.ERA_BY_EXPANSION = {
	[0] = "Classic", [1] = "Burning Crusade", [2] = "Wrath of the Lich King",
	[3] = "Cataclysm", [4] = "Mists of Pandaria", [5] = "Warlords of Draenor",
	[6] = "Legion", [7] = "Battle for Azeroth", [8] = "Shadowlands",
	[9] = "Dragonflight",
}

-- Which Timewalking era does this record's vendor stock belong to?
--
-- `rec.expansion` is the patch the mount was ADDED in, which is NOT the era it
-- sells during -- and for everything added in 11.x the two are usually
-- different. Amani Hunting Bear is expansion 10 but sells during Burning
-- Crusade; Skypaw Glimmerfur Prowler is expansion 10 but sells during
-- Shadowlands. Using expansion alone gets those backwards.
--
-- The era IS stated in the record's own source text, so read it from there and
-- fall back to the expansion only when the text says nothing. Deriving it beats
-- hand-maintaining a second field on 49 records, and it stays right when a
-- record's prose is corrected.
function TW.EraForRecord(rec)
	if not rec then return nil end
	if rec.twEra then return rec.twEra end -- explicit override always wins
	local fromText = TW.ParseEra(((rec.source or "") .. " " .. (rec.notes or "")):lower())
	if fromText then return fromText end
	return TW.ERA_BY_EXPANSION[rec.expansion]
end

-- Where each era's Timewalking vendor stands (faction-aware where needed).
local VENDORS = {
	["Classic"] = { Horde = { mapID = 85, x = 52.8, y = 83.0 }, Alliance = { mapID = 84, x = 56.0, y = 19.0 }, vendor = "Bobadormu" },
	["Burning Crusade"] = { any = { mapID = 111, x = 54.6, y = 39.6 }, vendor = "Cupri (Shattrath)" },
	["Wrath of the Lich King"] = { any = { mapID = 125, x = 51.0, y = 47.6 }, vendor = "Auzin (Dalaran, Northrend)" },
	["Cataclysm"] = { Horde = { mapID = 85, x = 52.0, y = 41.6 }, Alliance = { mapID = 84, x = 76.6, y = 16.6 }, vendor = "Kiatke" },
	["Mists of Pandaria"] = { any = { mapID = 554, x = 43.0, y = 55.6 }, vendor = "Mistweaver Xia (Timeless Isle)" },
	["Warlords of Draenor"] = { Horde = { mapID = 624, x = 50, y = 50 }, Alliance = { mapID = 622, x = 50, y = 50 }, vendor = "the Ashran TW vendor" },
	["Legion"] = { any = { mapID = 627, x = 68.8, y = 49.6 }, vendor = "Aridormi (Dalaran, Broken Isles)" },
	["Battle for Azeroth"] = { Horde = { mapID = 1165, x = 51.3, y = 46.7 }, Alliance = { mapID = 1161, x = 70.5, y = 17.2 }, vendor = "the BfA TW vendor" },
	["Shadowlands"] = { any = { mapID = 1670, x = 56.1, y = 63.9 }, vendor = "the Oribos TW vendor" },
	["Dragonflight"] = { any = { mapID = 2112, x = 81.4, y = 47.3 }, vendor = "the Valdrakken TW vendor" },
}

-- Location + display name of the vendor for the CURRENTLY active TW era.
function TW.VendorLocation()
	local era = TW.ActiveEra()
	if not era then return nil end
	for name, v in pairs(VENDORS) do
		if era:find(name, 1, true) or name:find(era, 1, true) then
			local loc = v.any or v[MM.playerFaction or "Alliance"]
			return loc, v.vendor, name
		end
	end
	return nil
end

function TW.Badges()
	local info = C_CurrencyInfo.GetCurrencyInfo(TW.CURRENCY_ID)
	return info and info.quantity or 0
end

-- For a record with a Timewarped Badge cost: how many badges are missing and
-- roughly how many dungeon runs that is.
-- Returns badgesNeeded, runsEstimate, text.
function TW.Estimate(rec)
	if not (rec and rec.conditions) then return nil end
	local cost
	for _, cond in ipairs(rec.conditions) do
		if cond.type == "CURRENCY" and cond.id == TW.CURRENCY_ID then
			cost = cond.amount
			break
		end
	end
	if not cost then return nil end

	local have = TW.Badges()
	local needed = math.max(0, cost - have)
	if needed == 0 then
		return 0, 0, ("Badges ready: %s / %s — buy it during the right Timewalking week!")
			:format(U.Comma(have), U.Comma(cost))
	end

	local afterQuest = math.max(0, needed - TW.WEEKLY_QUEST_BONUS)
	local runs = math.ceil(afterQuest / TW.BADGES_PER_RUN)
	local text = ("Badges: %s / %s — ~%d dungeon runs (counting the %d-badge weekly quest)")
		:format(U.Comma(have), U.Comma(cost), runs, TW.WEEKLY_QUEST_BONUS)
	if not TW.IsActive() then
		text = text .. " — no Timewalking event this week"
	end
	return needed, runs, text
end
