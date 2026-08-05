-- Master Mounts Trading Post: reads the CURRENT month's rotation live from
-- the Perks Program API, so nothing has to be maintained by hand. The static
-- Data_12 file remains a fallback for when the client hasn't loaded perks
-- data yet (it populates after the Trading Post UI has been opened once).
local _, MM = ...
local U = MM.Util

MM.TradingPost = {}
local TP = MM.TradingPost

TP.byMountID = {}   -- [mountID]  = { price, vendorItemID, name, frozen }
TP.byName = {}      -- [lowername] = same entry
TP.loaded = false
TP.open = false     -- Trading Post UI currently open

------------------------------------------------------------
-- Currency + deadline
------------------------------------------------------------
function TP.Tender()
	if C_PerksProgram and C_PerksProgram.GetCurrencyAmount then
		local ok, amount = pcall(C_PerksProgram.GetCurrencyAmount)
		if ok and amount then return amount end
	end
	local info = C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo(2032)
	return (info and info.quantity) or 0
end

-- Seconds until the monthly rotation turns over (nil if unavailable).
function TP.TimeRemaining()
	if C_PerksProgram and C_PerksProgram.GetTimeRemaining then
		local ok, secs = pcall(C_PerksProgram.GetTimeRemaining)
		if ok and type(secs) == "number" and secs > 0 then return secs end
	end
	return nil
end

------------------------------------------------------------
-- Rotation
------------------------------------------------------------
-- Ask the server for the rotation.
--
-- GetAvailableVendorItemIDs reads a client-side cache that is empty until
-- something requests it, which is why the rotation only appeared after opening
-- the Trading Post by hand. The UI lives in Blizzard_PerksProgram and triggers
-- that request on open.
--
-- The exact request function is not something to guess at, so this DISCOVERS it:
-- load the module, then call every zero-argument Request* on C_PerksProgram.
-- Whatever the API is actually called on this build, it gets called. The names
-- found are recorded for /mm post so the answer stops being a mystery.
TP.requestFunctions = {}

function TP.RequestData()
	if not C_PerksProgram then return false end

	local load = C_AddOns and C_AddOns.LoadAddOn or LoadAddOn
	local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_PerksProgram")
	if not isLoaded and load then pcall(load, "Blizzard_PerksProgram") end

	wipe(TP.requestFunctions)
	local called = 0
	for name, fn in pairs(C_PerksProgram) do
		if type(name) == "string" and type(fn) == "function" and name:find("^Request") then
			tinsert(TP.requestFunctions, name)
			if pcall(fn) then called = called + 1 end
		end
	end
	table.sort(TP.requestFunctions)
	return called > 0
end

function TP.Refresh()
	if not (C_PerksProgram and C_PerksProgram.GetAvailableVendorItemIDs) then return end
	local ok, ids = pcall(C_PerksProgram.GetAvailableVendorItemIDs)
	-- Nothing cached yet: ask, and let PERKS_PROGRAM_DATA_REFRESH bring us back.
	if not ok or type(ids) ~= "table" or #ids == 0 then
		if not TP.requested then
			TP.requested = true
			TP.RequestData()
		end
		return
	end

	-- How we decide a vendor offer is a mount.
	--
	-- We used to trust `info.mountID` alone. If GetVendorItemInfo does not carry
	-- that field on this build, every offer is silently skipped, `count` stays 0,
	-- TP.loaded never flips, and we report "no rotation data" WITH the data fully
	-- loaded -- a second, independent cause of the same symptom.
	--
	-- So resolve it two ways and take whichever answers: the field if it exists,
	-- otherwise the item it sells, through the same C_MountJournal.GetMountFromItem
	-- that powers bag detection (self-test confirms that API is present).
	local function mountIDFor(info)
		if info.mountID then return info.mountID, "mountID field" end
		local itemID = info.itemID
		if itemID and C_MountJournal and C_MountJournal.GetMountFromItem then
			local ok, id = pcall(C_MountJournal.GetMountFromItem, itemID)
			if ok and id then return id, "itemID -> GetMountFromItem" end
		end
		return nil
	end

	local fresh, freshByName, count = {}, {}, 0
	TP.resolvedVia, TP.sampleFields = nil, nil
	for _, vendorItemID in ipairs(ids) do
		local okInfo, info = pcall(C_PerksProgram.GetVendorItemInfo, vendorItemID)
		-- Record the shape of the first offer we see. If nothing resolves, the
		-- next report names the actual fields instead of us guessing again.
		if okInfo and type(info) == "table" and not TP.sampleFields then
			local keys = {}
			for k in pairs(info) do tinsert(keys, tostring(k)) end
			table.sort(keys)
			TP.sampleFields = table.concat(keys, ", ")
		end
		local mountID, via = okInfo and type(info) == "table" and mountIDFor(info) or nil
		if mountID then
			TP.resolvedVia = TP.resolvedVia or via
			info.mountID = mountID
			local frozen = false
			if C_PerksProgram.IsFrozenPerksVendorItem then
				local okFrozen, isFrozen = pcall(C_PerksProgram.IsFrozenPerksVendorItem, vendorItemID)
				frozen = (okFrozen and isFrozen) or false
			end
			local item = {
				mountID = info.mountID, vendorItemID = vendorItemID,
				price = info.price, name = info.name,
				purchased = info.purchased, frozen = frozen,
			}
			fresh[info.mountID] = item
			if info.name then freshByName[info.name:lower()] = item end
			count = count + 1
		end
	end

	if count > 0 then
		TP.byMountID, TP.byName, TP.loaded = fresh, freshByName, true
		TP.cached = false
		TP.Save()
		MM:Fire("MM_TRADINGPOST")
	end
end

------------------------------------------------------------
-- Traveler's Log (monthly reward)
------------------------------------------------------------
-- The mount for filling the monthly bar is NOT a vendor purchase and never
-- appears in GetAvailableVendorItemIDs, which is why it went unmodelled. A live
-- dump settled the shape:
--
--   GetPerksActivitiesInfo() -> { activePerksMonth, activities, displayMonthName,
--                                 secondsRemaining, thresholds }
--   GetPendingChestRewards() -> { { activityMonthID, perksVendorItemID,
--                                   rewardAmount, rewardTypeID,
--                                   thresholdOrderIndex } }
--
-- A threshold's reward is a vendor item when perksVendorItemID is non-zero, and
-- that id resolves through GetVendorItemInfo exactly like a shop item -- so the
-- same mount detection works. rewardTypeID 2 with perksVendorItemID 0 is a
-- currency payout (100 Tender in the observed month), not a mount.
--
-- Written defensively: the threshold field names are not documented, so any
-- table carrying a perksVendorItemID is inspected whatever it is called.
TP.travelersLog = nil

local function vendorItemMount(vendorItemID)
	if not (vendorItemID and vendorItemID ~= 0 and C_PerksProgram.GetVendorItemInfo) then
		return nil
	end
	local ok, info = pcall(C_PerksProgram.GetVendorItemInfo, vendorItemID)
	if not (ok and type(info) == "table") then return nil end
	if info.mountID then return info.mountID, info.name end
	if info.itemID and C_MountJournal and C_MountJournal.GetMountFromItem then
		local okM, mountID = pcall(C_MountJournal.GetMountFromItem, info.itemID)
		if okM and mountID then return mountID, info.name end
	end
	return nil
end

function TP.ScanTravelersLog()
	if not (C_PerksActivities and C_PerksActivities.GetPerksActivitiesInfo) then return end
	local ok, info = pcall(C_PerksActivities.GetPerksActivitiesInfo)
	if not (ok and type(info) == "table") then return end

	local found = { month = info.displayMonthName, endsIn = info.secondsRemaining, mounts = {} }
	local function inspect(node, depth)
		if type(node) ~= "table" or depth > 3 then return end
		local id = node.perksVendorItemID or node.vendorItemID
		if id then
			local mountID, name = vendorItemMount(id)
			if mountID then
				found.mounts[#found.mounts + 1] = {
					mountID = mountID, name = name,
					threshold = node.thresholdOrderIndex or node.orderIndex,
				}
			end
		end
		for _, child in pairs(node) do inspect(child, depth + 1) end
	end
	inspect(info.thresholds, 0)
	-- the pending chest can also carry one
	if C_PerksProgram.GetPendingChestRewards then
		local okC, chest = pcall(C_PerksProgram.GetPendingChestRewards)
		if okC then inspect(chest, 0) end
	end

	TP.travelersLog = found
	if #found.mounts > 0 then MM:Fire("MM_TRADINGPOST") end
end

MM:RegisterGameEvent("PERKS_PROGRAM_DATA_REFRESH", function() TP.ScanTravelersLog() end)
MM:On("MM_SCANNED", function() C_Timer.After(7, TP.ScanTravelersLog) end)

------------------------------------------------------------
-- Remembering the rotation
------------------------------------------------------------
-- The API surface on 12.0.7 has exactly four Request* functions --
-- RequestCartCheckout, RequestPendingChestRewards, RequestPurchase, RequestRefund
-- -- and NONE of them fetches the vendor manifest. There is no client-side way
-- to ask for it: the server sends it when the player interacts with the Trading
-- Post, and not before. Loading Blizzard_PerksProgram does not help.
--
-- So instead of pretending otherwise, remember it. Open the Trading Post once
-- per rotation and the data survives reloads and relogs for the rest of that
-- month. GetTimeRemaining tells us when the rotation ends, so the cache expires
-- itself rather than going quietly stale.
--
-- Stored in MM.db (MasterMountsDB, the ACCOUNT-wide file), so one character
-- opening the vendor captures the rotation for all of them.
--
-- The one limit we cannot engineer around: WoW only writes SavedVariables on
-- logout or /reload. A character logged in RIGHT NOW will not see a rotation
-- another character captured until that character logs out and this one
-- reloads. Sharing works across sessions, not simultaneously.
function TP.Save()
	local ends = TP.TimeRemaining()
	if not ends or ends <= 0 then return end
	local items = {}
	for mountID, item in pairs(TP.byMountID or {}) do
		items[#items + 1] = {
			mountID = mountID, vendorItemID = item.vendorItemID,
			price = item.price, name = item.name, purchased = item.purchased,
		}
	end
	if #items == 0 then return end
	MM.db.tradingPost = {
		expires = time() + ends,
		capturedBy = (UnitName("player") or "?") .. "-" .. (GetRealmName() or "?"),
		capturedAt = time(),
		items = items,
	}
end

function TP.Restore()
	local saved = MM.db.tradingPost
	if not (saved and saved.items and saved.expires) then return false end
	if time() >= saved.expires then
		MM.db.tradingPost = nil -- rotation is over; the list is meaningless now
		return false
	end
	local byMountID, byName = {}, {}
	for _, item in ipairs(saved.items) do
		byMountID[item.mountID] = item
		if item.name then byName[item.name:lower()] = item end
	end
	TP.byMountID, TP.byName, TP.loaded, TP.cached = byMountID, byName, true, true
	TP.cachedExpiry = saved.expires
	TP.cachedBy, TP.cachedAt = saved.capturedBy, saved.capturedAt
	MM:Fire("MM_TRADINGPOST")
	return true
end

-- The live rotation entry for a scanner entry, or nil.
-- Is this mount this month's Traveler's Log reward?
function TP.TravelersLogFind(entry)
	local tl = TP.travelersLog
	if not (tl and entry) then return nil end
	for _, m in ipairs(tl.mounts or {}) do
		if (entry.mountID and m.mountID == entry.mountID)
			or (m.name and entry.name and m.name:lower() == entry.name:lower()) then
			return m, tl
		end
	end
	return nil
end

function TP.Find(entry)
	if not entry then return nil end
	if TP.loaded then
		if entry.mountID and TP.byMountID[entry.mountID] then return TP.byMountID[entry.mountID] end
		if entry.name and TP.byName[entry.name:lower()] then return TP.byName[entry.name:lower()] end
		return nil
	end
	-- fallback: hand-maintained monthly file
	local rot = MM.TradingPostRotation
	if rot and rot.month == date("%Y-%m") and entry.name and rot.items[entry.name] then
		return { price = rot.items[entry.name], name = entry.name, static = true }
	end
	return nil
end

-- True when we have live data (so "not in rotation" is trustworthy).
function TP.HasLiveData()
	return TP.loaded
end

------------------------------------------------------------
-- Wiring
------------------------------------------------------------
-- Opening the post is when stock data becomes readable — the reliable moment
-- to sync, and it makes the cold-start "rotation unknown" state self-healing.
MM:RegisterGameEvent("PERKS_PROGRAM_OPEN", function()
	TP.open = true
	C_Timer.After(0.5, TP.Refresh)
end)

MM:RegisterGameEvent("PERKS_PROGRAM_CLOSE", function()
	TP.open = false
	TP.Refresh() -- catch anything bought or frozen while it was open
end)

MM:RegisterGameEvent("PERKS_PROGRAM_DATA_REFRESH", function() TP.Refresh() end)

-- Ask once shortly after login so the rotation is known without the player ever
-- opening the Trading Post.
MM:On("MM_SCANNED", function()
	if TP.loaded then return end
	-- A remembered rotation beats no rotation; live data replaces it the moment
	-- the player opens the vendor.
	if TP.Restore() then return end
	C_Timer.After(6, function()
		if not TP.loaded then TP.requested = true TP.RequestData() end
	end)
end)

-- Tender total changed (spent, earned, or claimed from the chest).
MM:RegisterGameEvent("PERKS_PROGRAM_CURRENCY_REFRESH", function()
	MM:Fire("MM_TRADINGPOST")
end)

-- Monthly task progress / pending tender collected from the traveler's chest.
MM:RegisterGameEvent("CHEST_REWARDS_UPDATED_FROM_SERVER", function()
	MM:Fire("MM_TRADINGPOST")
end)

-- A purchase went through: mark it and re-sync (the mount itself arrives via
-- NEW_MOUNT_ADDED, which drives the celebration).
MM:RegisterGameEvent("PERKS_PROGRAM_PURCHASE_SUCCESS", function(vendorItemID)
	if vendorItemID then
		for _, item in pairs(TP.byMountID) do
			if item.vendorItemID == vendorItemID then
				item.purchased = true
				MM:Print("Trading Post purchase: |cff40d860%s|r", item.name or "mount")
				break
			end
		end
	end
	C_Timer.After(0.5, TP.Refresh)
	MM:Fire("MM_TRADINGPOST")
end)

MM:On("MM_LOGIN", function()
	C_Timer.After(6, function()
		-- perks data usually needs a request before it is readable
		if C_PerksProgram and C_PerksProgram.RequestPurchasableItems then
			pcall(C_PerksProgram.RequestPurchasableItems)
		end
		C_Timer.After(2, TP.Refresh)
	end)
end)

-- /mm post — what the live rotation looks like
MM:On("MM_TRADINGPOST_DEBUG", function()
	TP.Refresh()
	local remaining = TP.TimeRemaining()
	MM:Print("Trader's Tender: %s%s", U.Comma(TP.Tender()),
		remaining and (" — rotation ends in " .. U.FormatSeconds(remaining)) or "")

	local function surfaceOf(namespace)
		local names = {}
		for k, v in pairs(namespace or {}) do
			if type(k) == "string" and type(v) == "function" then tinsert(names, k) end
		end
		table.sort(names)
		return names
	end

	if not TP.loaded then
		-- Everything needed to work out WHY, so the next report settles it
		-- rather than prompting another round of guessing.
		MM:Print("No rotation data.")
		MM:Print("  There is NO API to request it: C_PerksProgram exposes only")
		MM:Print("  RequestCartCheckout / RequestPendingChestRewards / RequestPurchase /")
		MM:Print("  RequestRefund. The server sends the manifest on vendor interaction only.")
		MM:Print("  |cffffd84dOpen the Trading Post once and we will remember it all month,|r")
		MM:Print("  |cffffd84don every character on this account.|r")
		if MM.db.tradingPost then
			MM:Print("  (A stored rotation exists but has expired — it was captured by %s.)",
				MM.db.tradingPost.capturedBy or "?")
		end
		MM:Print("  Blizzard_PerksProgram loaded: %s",
			tostring(C_AddOns and C_AddOns.IsAddOnLoaded
				and C_AddOns.IsAddOnLoaded("Blizzard_PerksProgram")))
		MM:Print("  Request functions called: %s",
			#TP.requestFunctions > 0 and table.concat(TP.requestFunctions, ", ") or "none found")
		local surface = surfaceOf(C_PerksProgram)
		MM:Print("  C_PerksProgram surface (%d): %s", #surface, table.concat(surface, ", "))
		if TP.sampleFields then
			MM:Print("  A vendor offer's actual fields: %s", TP.sampleFields)
		end
		-- The monthly Traveler's Log reward mount is not a vendor purchase and
		-- never appears in GetAvailableVendorItemIDs -- it lives in a different
		-- namespace. We do not model it yet; dumping the surface shows what we
		-- would have to work with.
		local act = surfaceOf(C_PerksActivities)
		MM:Print("  C_PerksActivities surface (%d): %s", #act,
			#act > 0 and table.concat(act, ", ") or "namespace absent")

		-- Structure now known and modelled; the dump stays because the field
		-- names are undocumented and could change.
		if C_PerksProgram and C_PerksProgram.GetPendingChestRewards then
			local ok, rewards = pcall(C_PerksProgram.GetPendingChestRewards)
			if ok and type(rewards) == "table" then
				MM:Print("  Pending chest rewards: %d", #rewards)
				for i, r in ipairs(rewards) do
					local keys = {}
					for k, v in pairs(type(r) == "table" and r or {}) do
						tinsert(keys, ("%s=%s"):format(tostring(k), tostring(v)))
					end
					table.sort(keys)
					MM:Print("    [%d] %s", i, table.concat(keys, ", "))
				end
			else
				MM:Print("  Pending chest rewards: unreadable")
			end
		end
		if C_PerksActivities and C_PerksActivities.GetPerksActivitiesInfo then
			local ok, info = pcall(C_PerksActivities.GetPerksActivitiesInfo)
			if ok and type(info) == "table" then
				local keys = {}
				for k in pairs(info) do tinsert(keys, tostring(k)) end
				table.sort(keys)
				MM:Print("  Traveler's Log fields: %s", table.concat(keys, ", "))
			end
		end
		return
	end

	TP.ScanTravelersLog()
	if TP.travelersLog then
		local tl = TP.travelersLog
		if #tl.mounts > 0 then
			for _, m in ipairs(tl.mounts) do
				MM:Print("  |cff40d860Traveler's Log mount:|r %s (threshold %s)",
					m.name or ("mount " .. m.mountID), tostring(m.threshold or "?"))
			end
		else
			MM:Print("  Traveler's Log (%s): no mount among this month's rewards.",
				tl.month or "current month")
		end
	end
	if TP.cached then
		MM:Print("  |cffffd84dRemembered rotation|r — captured by %s %s, expires %s.",
			TP.cachedBy or "?",
			TP.cachedAt and (U.FormatSeconds(time() - TP.cachedAt) .. " ago") or "at some point",
			TP.cachedExpiry and date("%%d %%b %%H:%%M", TP.cachedExpiry) or "?")
		MM:Print("  Shared with every character on this account.")
	elseif TP.resolvedVia then
		MM:Print("  Mounts identified via: %s", TP.resolvedVia)
	end
	local n = 0
	for _, item in pairs(TP.byMountID) do
		n = n + 1
		MM:Print("  %s — %s Tender%s%s", item.name or "?", U.Comma(item.price or 0),
			item.frozen and " |cff5cb8ff(frozen)|r" or "",
			item.purchased and " |cff40d860(owned)|r" or "")
	end
	MM:Print("%d mount%s in this month's rotation.", n, n == 1 and "" or "s")
end)
