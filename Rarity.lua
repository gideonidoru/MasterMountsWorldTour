-- Master Mounts rarity: empirical "how many players actually own this".
--
-- Our `effort` field is an editorial guess. Population rarity is a measured
-- fact, and it is a far better signal for "is this actually hard" — a mount
-- owned by 0.0001% of players is brutal no matter what our data claims.
--
-- Source: the MountsRarity-2.0 LibStub library, if the player has it
-- installed. We deliberately do NOT bundle or copy it: it is GPL-3.0, and
-- embedding would impose that licence on this addon. Detecting an optional
-- library at runtime is both the clean licensing answer and the way the
-- library is designed to be consumed. Everything degrades gracefully when
-- it is absent.
local _, MM = ...

MM.Rarity = {}
local R = MM.Rarity

local lib
local function get()
	if lib ~= nil then return lib or nil end
	lib = (LibStub and LibStub("MountsRarity-2.0", true)) or false
	-- ONCE, not every login. This is a capability notice: useful the first time
-- MountsRarity is seen, noise on the four hundredth. The flag lives in saved
-- variables so it survives reloads, which is where the repetition came from.
if lib then
	MM.db = MM.db or {}
	if not MM.db.rarityNoticed then
		MM.db.rarityNoticed = true
		MM:Print("Rarity data detected — difficulty now uses real ownership rates.")
	end
end
	return lib or nil
end

-- Percentage of the playerbase owning this mount, or nil.
function R.Get(mountID)
	if not mountID then return nil end
	local l = get()
	if not l or not l.GetRarityByID then return nil end
	local ok, pct = pcall(l.GetRarityByID, l, mountID)
	if ok and type(pct) == "number" then return pct end
	return nil
end

function R.Available()
	return get() ~= nil
end

-- Human label, coloured by how exclusive it is.
function R.Text(mountID)
	local pct = R.Get(mountID)
	if not pct then return nil end
	local color
	if pct < 0.5 then color = "ffff4444"        -- almost nobody has it
	elseif pct < 3 then color = "ffff9a3c"
	elseif pct < 15 then color = "ffffd84d"
	elseif pct < 40 then color = "ffb8e08a"
	else color = "ff8a8a8a" end                  -- common, most people have it
	if pct < 0.01 then
		return ("|c%sOwned by fewer than 1 in 10,000 players|r"):format(color)
	end
	return ("|c%sOwned by %.2f%% of players|r"):format(color, pct)
end

-- Difficulty contribution, on the same scale as the rest of EaseScore.
-- Rarer than the median (~17%) costs points; commonplace mounts get a small
-- discount. Returns 0 when we have no data, so nothing changes without the
-- library installed.
function R.Penalty(mountID)
	local pct = R.Get(mountID)
	if not pct then return 0 end
	if pct < 0.05 then return 2500 end
	if pct < 0.5 then return 1500 end
	if pct < 2 then return 800 end
	if pct < 8 then return 300 end
	if pct < 25 then return 0 end
	return -200
end

------------------------------------------------------------
-- Coverage cross-check: /mm rarity
------------------------------------------------------------
-- "Does MountsRarity know about mounts we don't catalogue?" cannot be answered
-- offline. Its table is keyed by JOURNAL mountID -- a client-side identifier
-- with no published mapping to a spell or a name. Wowhead does not index it,
-- and the other collector addons build the same mapping at runtime that we do.
--
-- So the check has to run in the game, where both sides are live: walk the
-- journal, take each mount's ID and spellID together, and ask whether the mount
-- MountsRarity has a rarity figure for is one we actually have a record for.
MM:On("MM_RARITY_DEBUG", function()
	local lib = get()
	if not lib then
		MM:Print("MountsRarity is not installed — nothing to compare against.")
		return
	end
	local data = lib.GetData and select(2, pcall(lib.GetData, lib))
	if type(data) ~= "table" then
		MM:Print("MountsRarity is present but exposed no data table.")
		return
	end

	local rarityCount = 0
	for _ in pairs(data) do rarityCount = rarityCount + 1 end

	local inJournal, catalogued, missing = 0, 0, {}
	for _, mountID in ipairs(C_MountJournal.GetMountIDs()) do
		if data[mountID] then
			inJournal = inJournal + 1
			local name, spellID = C_MountJournal.GetMountInfoByID(mountID)
			local rec = (spellID and MM.DBBySpell[spellID])
				or (name and MM.DBByName[name:lower()])
			if rec and not rec.stub then
				catalogued = catalogued + 1
			else
				tinsert(missing, { name = name or ("mount " .. mountID),
					mountID = mountID, spellID = spellID, pct = data[mountID] })
			end
		end
	end

	table.sort(missing, function(a, b) return (a.pct or 0) < (b.pct or 0) end)

	MM:Print("MountsRarity holds %d entries; %d match a journal mount.",
		rarityCount, inJournal)
	MM:Print("We catalogue %d of those. |cffffd84d%d not in our database:|r",
		catalogued, #missing)
	for i = 1, math.min(#missing, 40) do
		local m = missing[i]
		MM:Print("   %s  |cffbbbbbb(mountID %d, spell %s, owned by %.4f%%)|r",
			m.name, m.mountID, tostring(m.spellID or "?"), m.pct or 0)
	end
	if #missing > 40 then
		MM:Print("   ...and %d more.", #missing - 40)
	end
	if #missing == 0 then
		MM:Print("|cff40d860Nothing MountsRarity knows about is missing from our database.|r")
	end
end)

