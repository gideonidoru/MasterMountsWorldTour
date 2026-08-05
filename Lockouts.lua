-- Master Mounts lockouts: per-ENCOUNTER save state (not just per-instance),
-- tracked across every character on the account.
--
-- Why this exists: "you are saved to Ulduar" is not the question a mount
-- farmer asks. The question is "is Yogg-Saron dead this week, and on which of
-- my alts is he still alive?" C_RaidLocks.IsEncounterComplete answers the
-- first; an account-wide roster answers the second.
local _, MM = ...
local U = MM.Util

MM.Lockouts = {}
local L = MM.Lockouts

-- Legacy raid difficulties share a single lockout: killing a boss on any one
-- of these consumes the attempt on all of them.
local LINKED_DIFFICULTIES = { [3] = true, [4] = true, [5] = true, [6] = true }

local function charKey()
	return ("%s-%s"):format(UnitName("player") or "?", GetRealmName() or "?")
end

local function ensureDB()
	MM.db.lockouts = MM.db.lockouts or {}
	local key = charKey()
	MM.db.lockouts[key] = MM.db.lockouts[key] or {}
	MM.db.lockouts[key].class = select(2, UnitClass("player"))
	MM.db.lockouts[key].instances = MM.db.lockouts[key].instances or {}
	return MM.db.lockouts[key].instances
end

------------------------------------------------------------
-- Reading the current character's saves
------------------------------------------------------------
-- Snapshot GetSavedInstanceInfo into the account-wide roster.
function L.Scan()
	if not MM.db then return end
	local store = ensureDB()
	wipe(store)

	for i = 1, GetNumSavedInstances() do
		-- NOTE: instanceID (the value that matches Encounter Journal / raid
		-- lock lookups) is the 14th return, NOT the lockout id.
		local name, _, reset, difficultyID, locked, _, _, _, _, _, numEncounters, _, _, instanceID =
			GetSavedInstanceInfo(i)
		if locked and reset and reset > 0 then
			local expiry = GetServerTime() + reset
			local key = instanceID or (name and name:lower())
			if key then
				store[key] = store[key] or {}
				store[key].name = name
				store[key].diffs = store[key].diffs or {}
				store[key].diffs[difficultyID] = expiry
				-- legacy raid difficulties share the lock
				if LINKED_DIFFICULTIES[difficultyID] then
					for d in pairs(LINKED_DIFFICULTIES) do
						store[key].diffs[d] = expiry
					end
				end

				-- Per-boss kill state, BY NAME, straight from the client.
				-- This is what removes the need for hand-entered encounter
				-- IDs: the game already tells us which bosses are dead.
				store[key].bosses = store[key].bosses or {}
				for e = 1, (numEncounters or 0) do
					local bossName, _, isKilled = GetSavedInstanceEncounterInfo(i, e)
					if bossName then
						store[key].bosses[bossName:lower()] = isKilled and expiry or false
					end
				end
			end
		end
	end
	MM:Fire("MM_LOCKS")
end

-- Is this specific boss dead on the current character's lockout?
-- Returns true/false/nil, plus seconds until reset when known.
function L.BossState(bossName, instanceName)
	if not bossName then return nil end
	local store = MM.db.lockouts and MM.db.lockouts[charKey()]
	if not (store and store.instances) then return nil end
	local needle = bossName:lower()
	local now = GetServerTime()

	for key, inst in pairs(store.instances) do
		local matchesInstance = true
		if instanceName and inst.name then
			matchesInstance = inst.name:lower() == instanceName:lower()
		end
		if matchesInstance and inst.bosses then
			local state = inst.bosses[needle]
			if state ~= nil then
				if state == false then return false, nil end
				if state > now then return true, state - now end
				return false, nil -- lock expired
			end
		end
	end
	return nil
end

-- Prune roster entries whose locks have all expired (theirs never do this
-- and the saved variables grow forever).
function L.Prune()
	if not (MM.db and MM.db.lockouts) then return end
	local now = GetServerTime()
	for char, data in pairs(MM.db.lockouts) do
		local anyLive = false
		for instanceID, inst in pairs(data.instances or {}) do
			for diff, expiry in pairs(inst.diffs or {}) do
				if expiry <= now then inst.diffs[diff] = nil else anyLive = true end
			end
			if not next(inst.diffs or {}) then data.instances[instanceID] = nil end
		end
		if not anyLive and char ~= charKey() then MM.db.lockouts[char] = nil end
	end
end

------------------------------------------------------------
-- Per-encounter state for the CURRENT character
------------------------------------------------------------
-- Returns true (killed), false (alive), or nil (can't tell).
function L.IsEncounterDone(instanceID, encounterID, difficultyID)
	if not (instanceID and encounterID) then return nil end
	if C_RaidLocks and C_RaidLocks.IsEncounterComplete then
		local ok, done = pcall(C_RaidLocks.IsEncounterComplete,
			instanceID, encounterID, difficultyID)
		if ok and done ~= nil then return done end
	end
	return nil
end

-- Lock info for a record, using its optional `lock` block:
--   rec.lock = { instanceID = 603, encounterID = 1649, diffs = { 14 } }
-- Returns done (bool/nil), secondsUntilReset (number/nil).
-- Look a record's boss up in the client-resolved Encounter Journal data
-- (Data_87_ResolvedIDs.lua) to get the numeric IDs C_RaidLocks wants.
local function resolvedLock(rec)
	local resolved = MM.ResolvedIDs and MM.ResolvedIDs.instances
	local bossName = rec.npc and rec.npc.name
	if not (resolved and bossName) then return nil end
	local boss = bossName:lower()

	-- prefer the record's own instance when it names one
	local instName = rec.instance and rec.instance.name
	if instName then
		local inst = resolved[instName:lower()]
		local encID = inst and inst.enc and inst.enc[boss]
		if encID then return inst.id, encID end
	end
	-- otherwise find whichever instance contains this boss
	for _, inst in pairs(resolved) do
		local encID = inst.enc and inst.enc[boss]
		if encID then return inst.id, encID end
	end
	return nil
end

function L.RecordState(rec)
	if not rec then return nil, nil end

	-- Authoritative path: real encounter IDs from the client, via C_RaidLocks.
	local instanceID, encounterID = resolvedLock(rec)
	if instanceID and encounterID then
		local diffs = (rec.lock and rec.lock.diffs)
			or { rec.instance and rec.instance.difficultyID or 14, 15, 16, 17, 23, 2 }
		for _, diff in ipairs(diffs) do
			local done = L.IsEncounterDone(instanceID, encounterID, diff)
			if done == true then return true, nil end
		end
	end

	-- Preferred path: the client's own per-boss kill flags, matched by name.
	-- Needs no data entry at all, so it works for every raid/dungeon record
	-- that names its boss.
	local bossName = rec.npc and rec.npc.name
	if bossName then
		local done, remaining = L.BossState(bossName, rec.instance and rec.instance.name)
		if done ~= nil then return done, remaining end
	end

	local lock = rec.lock
	if not lock then return nil, nil end
	local diffs = lock.diffs or { lock.difficultyID }
	local anyAlive, expiry = false, nil

	for _, diff in ipairs(diffs) do
		local done = L.IsEncounterDone(lock.instanceID, lock.encounterID, diff)
		if done == false then anyAlive = true end
		local store = MM.db.lockouts and MM.db.lockouts[charKey()]
		local inst = store and store.instances and store.instances[lock.instanceID]
		local e = inst and inst.diffs and inst.diffs[diff]
		if e and (not expiry or e < expiry) then expiry = e end
	end

	if anyAlive then return false, nil end
	if expiry then return true, math.max(0, expiry - GetServerTime()) end
	return nil, nil
end

------------------------------------------------------------
-- The alt roster: who else can still kill this?
------------------------------------------------------------
-- Returns two arrays of "Name-Realm" strings: available, locked.
function L.AltsFor(rec)
	local available, locked = {}, {}
	if not (rec and MM.db.lockouts) then return available, locked end

	local bossName = rec.npc and rec.npc.name
	local instanceName = rec.instance and rec.instance.name
	local lock = rec.lock
	-- nothing to compare against: neither a named boss nor numeric IDs
	if not (bossName or instanceName or lock) then return available, locked end

	local now, me = GetServerTime(), charKey()
	local diffs = lock and (lock.diffs or { lock.difficultyID }) or nil

	for char, data in pairs(MM.db.lockouts) do
		if char ~= me then
			local isLocked = false

			-- name-based per-boss state (no data entry required)
			if bossName and data.instances then
				local needle = bossName:lower()
				for _, inst in pairs(data.instances) do
					local okInstance = not instanceName or not inst.name
						or inst.name:lower() == instanceName:lower()
					local state = okInstance and inst.bosses and inst.bosses[needle]
					if state and state > now then isLocked = true end
				end
			end

			-- numeric fallback when the record carries explicit IDs
			local inst = lock and data.instances and data.instances[lock.instanceID]
			if inst and diffs then
				for _, diff in ipairs(diffs) do
					local expiry = inst.diffs and inst.diffs[diff]
					if expiry and expiry > now then isLocked = true end
				end
			end
			local colored = char
			local classColor = data.class and RAID_CLASS_COLORS
				and RAID_CLASS_COLORS[data.class]
			if classColor and classColor.colorStr then
				colored = "|c" .. classColor.colorStr .. char .. "|r"
			end
			tinsert(isLocked and locked or available, colored)
		end
	end
	return available, locked
end

------------------------------------------------------------
-- One-click difficulty switching for the current goal
------------------------------------------------------------
local DUNGEON_DIFFICULTIES = { [1] = true, [2] = true, [23] = true }

MM.DIFFICULTY_LABEL = {
	[1] = "Normal Dungeon", [2] = "Heroic Dungeon", [23] = "Mythic Dungeon",
	[3] = "10 Normal", [4] = "25 Normal", [5] = "10 Heroic", [6] = "25 Heroic",
	[14] = "Normal Raid", [15] = "Heroic Raid", [16] = "Mythic Raid",
	[17] = "Looking For Raid",
}

function L.SetDifficulty(difficultyID)
	if not difficultyID or InCombatLockdown() then return false end
	local setter
	if DUNGEON_DIFFICULTIES[difficultyID] then
		setter = SetDungeonDifficultyID
	elseif IsLegacyDifficulty and IsLegacyDifficulty(difficultyID) then
		setter = SetLegacyRaidDifficultyID
	else
		setter = SetRaidDifficultyID
	end
	if type(setter) ~= "function" then return false end
	local ok = pcall(setter, difficultyID)
	if ok then
		MM:Print("Difficulty set to %s.", MM.DIFFICULTY_LABEL[difficultyID] or difficultyID)
	end
	return ok
end

-- The difficulty a record wants you in, if it names one.
function L.WantedDifficulty(rec)
	local lock = rec and rec.lock
	if lock then
		if lock.difficultyID then return lock.difficultyID end
		if lock.diffs and lock.diffs[1] then return lock.diffs[1] end
	end
	return nil
end

------------------------------------------------------------
-- Wiring
------------------------------------------------------------
MM:RegisterGameEvent("UPDATE_INSTANCE_INFO", function()
	L.Scan()
end)

MM:RegisterGameEvent("BOSS_KILL", function()
	C_Timer.After(2, function() pcall(RequestRaidInfo) end)
end)

MM:On("MM_LOGIN", function()
	C_Timer.After(10, function()
		L.Prune()
		pcall(RequestRaidInfo)
	end)
end)

-- ENCOUNTER_END also invalidates our snapshot; ask the server to refresh.
MM:RegisterGameEvent("ENCOUNTER_END", function(_, _, _, _, success)
	if success == 1 then
		C_Timer.After(3, function() pcall(RequestRaidInfo) end)
	end
end)

MM:RegisterGameEvent("PLAYER_LOGOUT", function()
	pcall(L.Scan)
end)
