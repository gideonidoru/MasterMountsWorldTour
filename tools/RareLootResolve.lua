-- DEV ONLY -- delete before release. Not in the .toc.
--
-- Two jobs, one pass over the client's own data:
--
--   /mm rareloot     which rares drop a mount, from RareScanner's loot tables
--   /mm mountaudit   which mounts exist that our database does not have
--
-- WHY THIS IS THE THIRD VERSION.
--
-- v1 asked C_MountJournal.GetMountFromItem about 12,140 item ids straight from
-- the table and got ZERO hits -- not because none are mounts, but because the
-- client answers nil for any item whose data it has not loaded, and none of
-- these had ever been seen. A confident zero.
--
-- v2 called C_Item.RequestLoadItemDataByID first and re-queried two seconds
-- later. That found ONE. Requesting is asynchronous and fire-and-forget: there
-- is no guarantee the data has arrived when the timer expires, so most lookups
-- were still asking too early.
--
-- v3 stops guessing at timing. Item:CreateFromItemID():ContinueOnItemLoad()
-- invokes its callback WHEN the item is actually loaded, so a lookup cannot run
-- before its data exists. Concurrency is capped because thousands of
-- simultaneous item requests get dropped by the client rather than queued.
local _, MM = ...

local IN_FLIGHT = 40   -- concurrent item loads; higher and the client drops them

local function resolveLoot()
	local H = MM.RareLootHarvest
	if not H then
		MM:Print("RareLootHarvest.lua is not loaded - add it to the .toc.")
		return
	end
	if not (Item and Item.CreateFromItemID) then
		MM:Print("The Item mixin is unavailable on this client.")
		return
	end

	local items = {}
	for itemID in pairs(H.item2npc) do items[#items + 1] = itemID end
	table.sort(items)

	local found, nextIdx, done, active = {}, 1, 0, 0
	local total = #items
	MM:Print("Rare loot: loading %d items - this waits for each one, so it is not fast.", total)

	local pump   -- forward declaration; launch() feeds it back

	local finished = false
	local function finish()
		-- Idempotent, and reachable even if some callbacks never fire. An item
		-- id the client does not recognise may never call back at all, which
		-- would leave `done` short of `total` forever and the window unopened --
		-- with the work already done and no way to see it.
		if finished then return end
		finished = true
		table.sort(found, function(a, b) return a.mount < b.mount end)
		local lines = { ("-- %d mount-dropping rares out of %d looted items"):format(#found, total) }
		for _, f in ipairs(found) do
			lines[#lines + 1] = ('MM.OverrideMount("%s", { npc = { name = "%s", id = %d } }) -- item %d')
				:format(f.mount:gsub('"', '\\"'), f.npc:gsub('"', '\\"'), f.npcID, f.item)
		end
		local text = table.concat(lines, "\n")
		-- Kept on the namespace so it survives a failed window: /mm rareloot show
		-- reopens it rather than making you run the whole pass again.
		MM.RareLootResult = text
		-- Persist it. The pass takes minutes and its output is the whole point;
		-- losing it to a failed frame or a reload means running it all again.
		if MM.db then MM.db.rareLootResult = text end
		MM:Print("Rare loot: done - %d mounts across %d items. /mm rareloot show reopens this.",
			#found, total)
		-- Deferred a frame: opening a large EditBox from inside an item-load
		-- callback has been unreliable, and the callback is not a safe place to
		-- be doing UI work anyway.
		C_Timer.After(0, function()
			local ok, err = false, nil
			if MM.Diagnostics and MM.Diagnostics.ShowExport then
				ok, err = pcall(MM.Diagnostics.ShowExport, text, "Rare loot resolution")
			end
			if not ok then
				MM:Print("Copy window failed (%s). Saved anyway - /mm rareloot show, or reload and try again.",
					tostring(err):sub(1, 80))
			end
		end)
	end

	-- A stalled slot must not be able to wedge the run.
	--
	-- ContinueOnItemLoad never fires for an item id the server will not resolve,
	-- so those callbacks simply never arrive. With a fixed concurrency window
	-- that is fatal rather than merely slow: forty dead ids fill every slot,
	-- pump() can no longer launch anything, and the whole pass halts partway --
	-- with results collected, `finish` unreached, and nothing to show for it.
	--
	-- So each slot is timed. A slot that has not answered in SLOT_TIMEOUT is
	-- written off and freed, which keeps the pipeline moving past bad ids.
	local SLOT_TIMEOUT, STALL_LIMIT = 10, 20
	local pending, lastProgress = {}, GetTime()

	local watchdog
	watchdog = C_Timer.NewTicker(2, function()
		if finished then watchdog:Cancel() return end
		local now = GetTime()
		local freed = 0
		for itemID, startedAt in pairs(pending) do
			if now - startedAt > SLOT_TIMEOUT then
				pending[itemID] = nil
				done, active = done + 1, active - 1
				freed = freed + 1
			end
		end
        if freed > 0 then
			lastProgress = now
			pump()
		end
		-- Nothing moving at all for a while means there is nothing left coming.
		if now - lastProgress > STALL_LIMIT then
			watchdog:Cancel()
			MM:Print("Rare loot: no further responses; finishing with %d/%d answered.", done, total)
			finish()
		end
		if done >= total then watchdog:Cancel() finish() end
	end)

	local function launch(itemID)
		active = active + 1
		pending[itemID] = GetTime()
		local item = Item:CreateFromItemID(itemID)
		item:ContinueOnItemLoad(function()
			if not pending[itemID] then return end   -- already timed out and counted
			pending[itemID] = nil
			lastProgress = GetTime()
			-- The data is genuinely present now, so a nil here means "not a
			-- mount" rather than "not loaded yet" -- which is the distinction
			-- the first two versions could not make.
			local mountID = C_MountJournal.GetMountFromItem(itemID)
			if mountID then
				local name = C_MountJournal.GetMountInfoByID(mountID)
				local npcID = H.item2npc[itemID]
				local npcName = npcID and H.npcNames[npcID]
				if name and npcName then
					found[#found + 1] = { mount = name, npc = npcName, item = itemID, npcID = npcID }
				end
			end
			done, active = done + 1, active - 1
			if done % 1000 == 0 then
				MM:Print("Rare loot: %d/%d, %d mounts so far...", done, total, #found)
			end
			pump()
		end)
	end

	pump = function()
		while active < IN_FLIGHT and nextIdx <= total do
			local id = items[nextIdx]
			nextIdx = nextIdx + 1
			launch(id)
		end
		if done >= total then finish() end
	end

	pump()
end

-- Every mount the client knows, against every mount we ship. The client is the
-- only authority on what exists; comparing against another addon's tables can
-- only ever tell us what THEY have.
local function mountAudit()
	if not (C_MountJournal and C_MountJournal.GetMountIDs) then
		MM:Print("C_MountJournal.GetMountIDs is unavailable.")
		return
	end
	-- MM.DBList, not MM.DB. The first version read a table that does not exist,
	-- so `ours` was empty and every mount in the journal reported as missing --
	-- a thousand-line answer that looked like a finding and was a typo.
	--
	-- Guarded rather than assumed: an empty index here can only produce a
	-- nonsense report, so say so instead of printing one.
	local ours, counted = {}, 0
	for _, rec in ipairs(MM.DBList or {}) do
		if rec.spellID then ours[rec.spellID] = true counted = counted + 1 end
		if rec.name then ours[rec.name:lower()] = true end
		for _, alt in ipairs(rec.altSpellIDs or {}) do ours[alt] = true end
	end
	if counted < 100 then
		MM:Print("Mount audit aborted: only %d records indexed - the database is not loaded.", counted)
		return
	end

	local missing = {}
	for _, mountID in ipairs(C_MountJournal.GetMountIDs()) do
		local name, spellID, _, _, _, _, _, _, _, hideOnChar, isCollected = C_MountJournal.GetMountInfoByID(mountID)
		if name and not hideOnChar then
			if not (ours[spellID] or ours[name:lower()]) then
				missing[#missing + 1] = ('%s  spellID=%s  mountID=%d%s')
					:format(name, tostring(spellID), mountID, isCollected and "  [you own it]" or "")
			end
		end
	end
	table.sort(missing)
	MM:Print("Mount audit: %d mounts the client knows are missing from our database.", #missing)
	local text = table.concat(missing, "\n")
	if MM.Diagnostics and MM.Diagnostics.ShowExport then
		MM.Diagnostics.ShowExport(text, "Mounts missing from the database")
	else
		print(text)
	end
end

MM.RareLootResolve = resolveLoot
MM.MountAudit = mountAudit
