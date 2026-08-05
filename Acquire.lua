-- Master Mounts: indirect acquisition.
--
-- Plenty of mounts never drop as a mount. They arrive as an egg that has to
-- incubate, a harness or set of reins, a war chest, or a pile of tokens you
-- hand to a vendor. Two failure modes follow from that, and this module exists
-- to kill both:
--
--  1. The addon says "go farm X" while the item that teaches X is already
--     sitting in your bags. Embarrassing, and easy to fix.
--  2. The plan treats a multi-step chain as a single drop, so the effort
--     estimate is wrong and the instructions are useless.
--
-- For (1) we ask the CLIENT rather than keep a table. C_MountJournal can map an
-- item to the mount it teaches, so any teaching item -- egg, harness, reins,
-- chest -- is recognised without a single hand-written row, including mounts
-- added after this addon shipped. A hardcoded item list would have needed 72
-- entries harvested from a competitor and would still have gone stale.
--
-- For (2) records carry an `acquire` block, since no API can tell you that a
-- mount costs 5 tokens from a vendor or that an egg incubates for three days.
local _, MM = ...
local U = MM.Util

MM.Acquire = {}
local A = MM.Acquire

A.carried = {} -- [mountID] = { itemID, link, count } for uncollected mounts

------------------------------------------------------------
-- Bag scan
------------------------------------------------------------
-- Not every client build exposes this; without it we simply skip the feature
-- rather than guess from item names.
local function mountFromItem(itemID)
	if not (C_MountJournal and C_MountJournal.GetMountFromItem) then return nil end
	local ok, mountID = pcall(C_MountJournal.GetMountFromItem, itemID)
	return ok and mountID or nil
end
A.Supported = function()
	return (C_MountJournal and C_MountJournal.GetMountFromItem) ~= nil
end

local function scan()
	wipe(A.carried)
	if not A.Supported() then return end

	for bag = 0, NUM_BAG_SLOTS do
		local slots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, slots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local itemID = info and info.itemID
			if itemID then
				local mountID = mountFromItem(itemID)
				if mountID then
					local _, spellID, _, _, _, _, _, _, _, _, collected =
						C_MountJournal.GetMountInfoByID(mountID)
					if not collected then
						A.carried[mountID] = {
							itemID = itemID, spellID = spellID,
							link = info.hyperlink,
							count = info.stackCount or 1,
						}
					end
				end
			end
		end
	end
	MM:Fire("MM_CARRIED")
end

-- Bag events fire in bursts; one scan after the dust settles is enough.
local pending
local function scanSoon()
	if pending then return end
	pending = true
	C_Timer.After(0.5, function() pending = false scan() end)
end

MM:RegisterGameEvent("BAG_UPDATE_DELAYED", scanSoon)
MM:On("MM_SCANNED", scanSoon)

-- Is this plan entry's mount already teachable from something we're carrying?
function A.Carried(entry)
    if not entry then return nil end
    -- match on mountID when we have it, else fall back to the spell the item
    -- teaches, since a plan entry always knows its spellID
    if entry.mountID and A.carried[entry.mountID] then
        return A.carried[entry.mountID]
    end
    for _, info in pairs(A.carried) do
        if entry.spellID and info.spellID == entry.spellID then return info end
    end
    return nil
end

------------------------------------------------------------
-- Authored chains
------------------------------------------------------------
-- `rec.acquire` describes what an API cannot infer:
--   { item = itemID, name = "Necroray Egg", count = 5,
--     incubate = 3, note = "hand to <vendor>" }
-- `count` means "collect this many", `incubate` is a wait in days.
--
-- Returns a progress line, plus how many you still need.
-- Multi-step chains, for secrets.
--
-- The design calls for the acquire block, the difficulty and the time commitment on
-- the twenty PUZZLE records, and none of them had any of it -- a secret was an
-- effort number and one sentence. A secret is a SEQUENCE: find four lanterns,
-- then solve a maze, then wait for a spawn. One item field cannot express that.
--
-- Steps carry an optional `quest` or `item` so progress can be read where the
-- client knows it, and nothing where it does not. A step we cannot verify says
-- so rather than pretending -- the same rule as everywhere else here.
--
-- Returns: text, remaining, done, total
function A.StepProgress(rec)
	local steps = rec and rec.acquire and rec.acquire.steps
	if not (steps and #steps > 0) then return nil end

	local done, unknown, firstOpen = 0, 0, nil
	for i, step in ipairs(steps) do
		local complete
		if step.quest and C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
			complete = C_QuestLog.IsQuestFlaggedCompleted(step.quest)
		elseif step.item and C_Item and C_Item.GetItemCount then
			complete = (C_Item.GetItemCount(step.item) or 0) > 0
		end
		if complete == true then
			done = done + 1
		else
			if complete == nil then unknown = unknown + 1 end
			if not firstOpen then firstOpen = i end
		end
	end

	local total = #steps
	local text
	if unknown == total then
		-- Nothing here is machine-checkable, which is normal for a secret: the
		-- steps are things you DO, not flags the client sets.
		text = ("%d steps, none of them trackable — next: %s")
			:format(total, steps[firstOpen or 1].text or "?")
	elseif done >= total then
		text = "Every step done — the mount should be yours"
	else
		text = ("Step %d of %d: %s"):format(
			(firstOpen or total), total, steps[firstOpen or total].text or "?")
	end
	return text, total - done, done, total
end

function A.ChainProgress(rec)
	local acq = rec and rec.acquire
	if not acq then return nil end

	-- a stepped chain answers first; it is the richer statement
	if acq.steps then
		local text, remaining = A.StepProgress(rec)
		if text then return text, remaining end
	end

	local have = acq.item and (C_Item.GetItemCount(acq.item) or 0) or 0
	local need = acq.count or 1

	if acq.count and acq.count > 1 then
		local line = ("%s: %d / %d"):format(acq.name or "Required item", have, need)
		if acq.note then line = line .. " — " .. acq.note end
		return line, math.max(0, need - have)
	end

	if have > 0 then
		if acq.incubate then
			return ("You have %s — it becomes usable %d days after it drops")
				:format(acq.name or "the item", acq.incubate), 0
		end
		return ("You have %s — use it to learn this mount"):format(acq.name or "the item"), 0
	end

	local line = acq.name and ("Comes from " .. acq.name) or nil
	if line and acq.incubate then
		line = line .. (", which incubates for %d days"):format(acq.incubate)
	end
	if line and acq.note then line = line .. " — " .. acq.note end
	return line, need
end

-- /mm bags — what you're carrying that would teach a missing mount
MM:On("MM_CARRIED_DEBUG", function()
	if not A.Supported() then
		MM:Print("This client build can't map items to mounts — bag detection is off.")
		return
	end
	local n = 0
	for mountID, info in pairs(A.carried) do
		n = n + 1
		local name = C_MountJournal.GetMountInfoByID(mountID)
		MM:Print("  |cff40d860%s|r — %s", name or ("mount " .. mountID),
			info.link or ("item " .. info.itemID))
	end
	if n == 0 then
		MM:Print("Nothing in your bags teaches a mount you're missing.")
	else
		MM:Print("%d mount%s ready to learn from your bags.", n, n == 1 and "" or "s")
	end
end)
