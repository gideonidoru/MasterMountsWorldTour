-- Master Mounts: Covenant Callings (Shadowlands daily rotation).
--
-- Three mounts -- Bulbous, Infested and Pestilent Necroray -- hatch from a
-- Necroray Egg, which has a chance to appear inside the Tribute chests awarded
-- for completing a MALDRAXXUS Calling. Callings are dailies whose target zone
-- rotates, so these mounts are only farmable on days when a Maldraxxus Calling
-- is actually on offer. There is no boss and no instance involved.
--
-- That distinction matters: cataloguing them as an ordinary drop made the
-- planner rank them as soloable legacy-raid loot and route the player to
-- Maldraxxus on a day when nothing there could possibly award an egg.
--
-- Everything here is best-effort, and every uncertain path resolves to UNKNOWN
-- rather than AVAILABLE. Wrongly claiming a mount is farmable today is exactly
-- the failure being fixed; a hedged "couldn't read today's Callings" is honest
-- and keeps the entry out of the route.
local _, MM = ...

MM.Callings = {}
local C = MM.Callings

C.active = {}        -- [questID] = { mapID = number|nil, title = string|nil }
C.enumerated = false -- did we manage to list today's Callings at all?
C.offered = nil      -- last COVENANT_CALLINGS_UPDATED payload

-- Learned questID -> uiMapID, persisted. Zone resolution can fail for a quest
-- that is merely offered rather than accepted, so once we have seen a Calling's
-- zone we keep it: the same Calling quest always targets the same zone.
local function learned()
	MM.db.callingZones = MM.db.callingZones or {}
	return MM.db.callingZones
end

------------------------------------------------------------
-- Zone resolution
------------------------------------------------------------
-- Which API answers "what map is this quest on" depends on how the quest is
-- classified, and a Calling is neither a plain quest nor a world quest. Rather
-- than bet on one, probe each and take the first plausible answer.
-- The Calling's TITLE is the zone.
--
-- Established from a live client: all three map probes are useless here.
-- C_TaskQuest.GetQuestZoneID returns map 1698 "Seat of the Primus" -- the
-- player's own COVENANT SANCTUM -- for every calling regardless of target, and
-- GetQuestAdditionalHighlights and GetQuestUiMapID both return 0.
--
-- But the titles say it outright: "Challenges in Bastion", "A Call to Bastion",
-- "Training in Ardenweald". Once RequestLoadQuestByID makes them readable, the
-- zone is simply the map name appearing in the title.
--
-- Matched against the client-resolved map names rather than a hardcoded list of
-- Shadowlands zones, so it keeps working if Callings ever cover new zones. The
-- longest match wins, so "The Maw" cannot be beaten by a shorter substring.
local function zoneFromTitle(title)
	if not title or title == "" then return nil end
	local lower = title:lower()
	local bestName, bestLen
	for name in pairs((MM.ResolvedIDs and MM.ResolvedIDs.maps) or {}) do
		if #name >= 4 and lower:find(name:lower(), 1, true) then
			if not bestLen or #name > bestLen then bestName, bestLen = name, #name end
		end
	end
	if not bestName then return nil end
	return MM.Util.ResolveMapByName(bestName), bestName
end

local function resolveMapID(questID)
	local cache = learned()
	-- Return the source too. Without it `via` was nil on every run after the
	-- first, which is why the diagnostic could never say which probe answered.
	if cache[questID] then return cache[questID], "learned cache" end

	local probes = {
		function()
			return C_TaskQuest and C_TaskQuest.GetQuestZoneID
				and C_TaskQuest.GetQuestZoneID(questID)
		end,
		function()
			return C_QuestLog and C_QuestLog.GetQuestAdditionalHighlights
				and C_QuestLog.GetQuestAdditionalHighlights(questID)
		end,
		function()
			return GetQuestUiMapID and GetQuestUiMapID(questID)
		end,
	}
	local NAMES = { "C_TaskQuest.GetQuestZoneID",
		"C_QuestLog.GetQuestAdditionalHighlights", "GetQuestUiMapID" }
	for i, probe in ipairs(probes) do
		local ok, id = pcall(probe)
		-- 0 is these APIs' "no answer", not a map
		if ok and type(id) == "number" and id > 0 then
			cache[questID] = id
			return id, NAMES[i]
		end
	end
	return nil
end

------------------------------------------------------------
-- Enumeration
------------------------------------------------------------
-- What does this Calling actually reward?
--
-- The zone is a proxy; the REWARD is the fact. the point: the Necroray egg
-- comes from Tribute of the Ambitious / Tribute of the Duty-Bound, and it is
-- those chests that matter, not the zone name on the quest. Zone-matching is
-- wrong in both directions -- Necrolord members receive Maldraxxus tribute from
-- Callings that are not zone-specific at all, and a Maldraxxus Calling that
-- rewards something else would be a false positive.
--
-- Readable only once the quest data is cached, which RequestLoadQuestByID now
-- ensures. Guarded: if these globals are absent the gate simply falls back to
-- the zone check rather than erroring.
local function callingRewards(questID)
	-- GetNumQuestLogRewards is QUEST-LOG scoped: it answers for a quest that is
	-- in the log, and an offered-but-unaccepted Calling is not. That is why the
	-- rewards read once (when a Calling happened to be accepted) and "not
	-- readable" every time since.
	--
	-- C_QuestLog.GetQuestRewards is log-independent where it exists. Try it
	-- first, fall back to the log API, and record which answered so the next
	-- report says whether this path works at all instead of us guessing again.
	-- C_QuestLog.GetQuestRewards does not exist on 12.0.7, so the log API does
	-- the work. It DOES answer for offered Callings -- observed returning
	-- Tribute of the Paragon, Tribute of the Ascended and Bounty of the Grove
	-- Wardens for three unaccepted ones -- provided the quest data has been
	-- requested first. Kept for the build where it does exist.
	if C_QuestLog and C_QuestLog.GetQuestRewards then
		local ok, rewards = pcall(C_QuestLog.GetQuestRewards, questID)
		if ok and type(rewards) == "table" then
			local items = {}
			for _, r in ipairs(rewards) do
				local id = (type(r) == "table") and (r.itemID or r.id) or r
				if type(id) == "number" then items[#items + 1] = id end
			end
			if #items > 0 then return items, "C_QuestLog.GetQuestRewards" end
		end
	end

	if not (GetNumQuestLogRewards and GetQuestLogRewardInfo) then return nil end
	local okCount, count = pcall(GetNumQuestLogRewards, questID)
	if not okCount or not count or count == 0 then return nil end
	local items = {}
	for i = 1, count do
		-- returns name, texture, numItems, quality, isUsable, itemID
		local ok, _, _, _, _, _, itemID = pcall(GetQuestLogRewardInfo, i, questID)
		if ok and itemID then items[#items + 1] = itemID end
	end
	return (#items > 0) and items or nil, "GetQuestLogRewardInfo"
end

local function record(questID, title)
	if not questID then return end
	local mapID, via
	title = title or (C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID))
	local rewards, rewardsVia = callingRewards(questID)

	-- Request the quest data whenever ANYTHING is still missing.
	--
	-- This used to be gated on `not title`, which broke rewards completely once
	-- titles were cached: a cached title meant no request, no request meant no
	-- QUEST_DATA_LOAD_RESULT, and rewards stayed nil forever. Titles cache more
	-- readily than reward data, so the moment titles started working the reward
	-- read stopped -- which is exactly the sequence observed, and why
	-- "/mm callings clear" (forcing a fresh cycle) brought them back.
	--
	-- Rewards ARE readable for offered Callings; they simply need the data
	-- requested. Earlier notes here claiming they need the Calling accepted were
	-- wrong -- they were inferred from an absence this bug caused.
	if (not title or not rewards) and C_QuestLog and C_QuestLog.RequestLoadQuestByID then
		pcall(C_QuestLog.RequestLoadQuestByID, questID)
	end

	-- Title first: it is the only source that has ever been right.
	local fromTitle, zoneName = zoneFromTitle(title)
	if fromTitle then
		mapID, via = fromTitle, ("title \"%s\""):format(zoneName)
	else
		mapID, via = resolveMapID(questID)
	end

	C.active[questID] = {
		mapID = mapID, via = via, title = title, zoneName = zoneName,
		rewards = rewards, rewardsVia = rewardsVia,
	}
end

-- Callings are zone-specific by definition, so if every one of today's resolves
-- to the SAME map, whichever API answered is not telling us about zones -- it is
-- returning a continent or a covenant hub. Trusting it would produce a confident
-- "no Maldraxxus Calling today" on a day there is one. Discard the answer and
-- fall back to UNKNOWN, which is the honest state.
local function discardIfUniform()
	local seen, n = nil, 0
	for _, info in pairs(C.active) do
		-- A title-derived zone is trustworthy even when every calling shares it
		-- (two Bastion callings in one day is normal), so only probe-derived
		-- answers are subject to the uniformity check.
		if info.zoneName then return end
		if not info.mapID then return end
		if seen == nil then seen = info.mapID elseif info.mapID ~= seen then return end
		n = n + 1
	end
	if n > 1 then
		local cache = learned()
		for questID, info in pairs(C.active) do
			info.mapID, info.uniform = nil, seen
			-- Purge it from SavedVariables as well. A rejected value left in the
			-- learned cache is read back on every future session and re-rejected
			-- forever -- the cache poisons itself and survives reloads.
			cache[questID] = nil
		end
	end
end

function C.Refresh()
	wipe(C.active)
	local found = false

	-- Callings that are OFFERED but not yet accepted exist only in the
	-- covenant API's payload -- they are not in the quest log.
	if type(C.offered) == "table" then
		for _, calling in ipairs(C.offered) do
			if type(calling) == "table" and calling.questID then
				record(calling.questID, calling.title)
				found = true
			end
		end
	end

	-- Callings already accepted sit in the quest log instead.
	if C_QuestLog and C_QuestLog.IsQuestCalling and C_QuestLog.GetNumQuestLogEntries then
		local n = C_QuestLog.GetNumQuestLogEntries() or 0
		for i = 1, n do
			local ok, info = pcall(C_QuestLog.GetInfo, i)
			if ok and info and info.questID and not info.isHeader then
				local okC, isCalling = pcall(C_QuestLog.IsQuestCalling, info.questID)
				if okC and isCalling then
					record(info.questID, info.title)
					found = true
				end
			end
		end
	end

	discardIfUniform()
	C.enumerated = found
	if MM.Availability and MM.Availability.InvalidateStatus then
		MM.Availability.InvalidateStatus()
	end
	MM:Fire("MM_CALLINGS")
end

-- Ask the game to send us today's Callings; the answer arrives on the event.
function C.Request()
	if C_CovenantCallings and C_CovenantCallings.RequestCallings then
		pcall(C_CovenantCallings.RequestCallings)
	end
	C.Refresh()
	-- The first Refresh fires the quest-data requests; their answers arrive a
	-- moment later. Re-reading once afterwards means a single /mm callings shows
	-- loaded rewards instead of needing to be run twice.
	C_Timer.After(1.5, function()
		local missing = false
		for _, info in pairs(C.active) do
			if not info.rewards then missing = true break end
		end
		if missing then C.Refresh() end
	end)
end

MM:RegisterGameEvent("COVENANT_CALLINGS_UPDATED", function(callings)
	C.offered = type(callings) == "table" and callings or nil
	C.Refresh()
end)

-- Accepting or handing in a Calling changes what is on offer.
-- The requested quest data has arrived; titles are readable now.
MM:RegisterGameEvent("QUEST_DATA_LOAD_RESULT", function(questID, success)
	if not success then return end
	local info = C.active[questID]
	if not info then return end
	local changed = false

	if not info.title and C_QuestLog.GetTitleForQuestID then
		info.title = C_QuestLog.GetTitleForQuestID(questID)
		changed = changed or (info.title ~= nil)
	end

	-- Rewards are read at record time, which is BEFORE the server has answered
	-- the load request -- so they were readable only when the quest happened to
	-- be cached already. That is why they appeared in one report and read "not
	-- readable" in the next. This event is the point at which they exist.
	if not info.rewards then
		info.rewards, info.rewardsVia = callingRewards(questID)
		changed = changed or (info.rewards ~= nil)
	end

	if changed then MM:Fire("MM_CALLINGS") end
end)

MM:RegisterGameEvent("QUEST_TURNED_IN", function() C.Request() end)
MM:RegisterGameEvent("QUEST_ACCEPTED", function() C.Request() end)

MM:On("MM_SCANNED", function()
	-- Callings are not available to a character who never picked a covenant,
	-- and the API answers nothing for them -- which is correctly indistinct
	-- from "couldn't read it", since either way we must not claim availability.
	C_Timer.After(3, C.Request)
end)

------------------------------------------------------------
-- Gate evaluation
------------------------------------------------------------
-- Returns a status key and detail text for a record's `calling` block.
-- Statuses: AVAILABLE (the right Calling is up today), ROTATION (it is not),
-- UNKNOWN (we could not determine it, so make no claim).
function C.Evaluate(gate)
	local zone = gate.zone or "the right zone"
	local target = gate.mapID

	-- Callings need a Shadowlands covenant. Saying so beats a vague
	-- "couldn't read today's Callings" when the real answer is knowable.
	if C_Covenants and C_Covenants.GetActiveCovenantID then
		local ok, id = pcall(C_Covenants.GetActiveCovenantID)
		if ok and id == 0 then
			return "ROTATION",
				("Needs a Shadowlands covenant — the egg comes from a %s Calling's chest")
					:format(zone)
		end
	end

	if not C.enumerated then
		return "UNKNOWN",
			("Only from a %s Calling's reward chest — today's Callings aren't readable yet")
				:format(zone)
	end

	-- A reward match is decisive: this Calling hands over the very chest the
	-- mount comes out of. No zone reasoning required, and it catches the
	-- Necrolord case where a non-Maldraxxus Calling still awards the tribute.
	if gate.rewardItems then
		for _, info in pairs(C.active) do
			for _, itemID in ipairs(info.rewards or {}) do
				for _, wanted in ipairs(gate.rewardItems) do
					if itemID == wanted then
						return "AVAILABLE",
							("A Calling today rewards %s — it can contain the egg"):format(
								(C_Item and C_Item.GetItemNameByID
									and C_Item.GetItemNameByID(itemID)) or ("item " .. itemID))
					end
				end
			end
		end
	end

	local unresolved = 0
	for _, info in pairs(C.active) do
		local hit = (target and info.mapID == target)
			or (info.zoneName and zone and info.zoneName:lower() == zone:lower())
			-- last resort: the zone named anywhere in the title
			or (info.title and zone and info.title:find(zone, 1, true) ~= nil)
		if hit then
			return "AVAILABLE",
				("Today's Calling is in %s — its Tribute chest can contain a Necroray Egg")
					:format(zone)
		end
		if not info.mapID then unresolved = unresolved + 1 end
	end

	-- A Calling we failed to place could be the one we are looking for, so an
	-- unresolved entry means we genuinely do not know -- not that it is absent.
	if unresolved > 0 then
		return "UNKNOWN",
			("Couldn't place %d of today's Callings — can't confirm a %s Calling")
				:format(unresolved, zone)
	end

	return "ROTATION",
		("No %s Calling today — check back when the daily rotation comes round")
			:format(zone)
end

-- /mm callings — what we can see of today's rotation
MM:On("MM_CALLINGS_DEBUG", function()
	local function mapName(id)
		if not id then return "nil" end
		local info = C_Map.GetMapInfo(id)
		return info and ("%d (%s, type %s)"):format(id, info.name or "?",
			tostring(info.mapType)) or tostring(id)
	end

	MM:Print("Callings enumerated: %s", tostring(C.enumerated))
	if C_Covenants and C_Covenants.GetActiveCovenantID then
		local ok, id = pcall(C_Covenants.GetActiveCovenantID)
		MM:Print("Active covenant: %s", ok and tostring(id) or "unreadable")
	end

	-- Dump the RAW payload. Every attempt at deriving a Calling's zone so far has
	-- been guesswork about which API to ask; the payload itself may simply carry
	-- the answer, and this is the only way to find out.
	if type(C.offered) == "table" then
		MM:Print("C_CovenantCallings payload: %d entries", #C.offered)
		for i, calling in ipairs(C.offered) do
			local keys = {}
			for k, v in pairs(calling) do
				tinsert(keys, ("%s=%s"):format(tostring(k), tostring(v)))
			end
			table.sort(keys)
			MM:Print("  [%d] %s", i, table.concat(keys, ", "))
		end
	else
		MM:Print("C_CovenantCallings payload: none received")
	end

	local n = 0
	for questID, info in pairs(C.active) do
		n = n + 1
		local rewardText = ""
		if info.rewards then
			local names = {}
			for _, id in ipairs(info.rewards) do
				tinsert(names, ((C_Item and C_Item.GetItemNameByID
					and C_Item.GetItemNameByID(id)) or "?") .. " (" .. id .. ")")
			end
			rewardText = " | rewards (" .. tostring(info.rewardsVia or "?") .. "): " .. table.concat(names, ", ")
		else
			rewardText = " | rewards: not loaded yet — retry in a moment"
		end
		MM:Print("  quest %d — %s — title: %s", questID,
			info.mapID and ("map " .. mapName(info.mapID) .. " via " .. tostring(info.via))
				or (info.uniform and ("all returned " .. mapName(info.uniform) .. " — discarded")
					or "unresolved"),
			tostring(info.title or "not cached") .. rewardText)

		-- Run every probe FRESH, bypassing the cache, and name what each returns.
		-- Which API is lying has never been established; this establishes it.
		local probes = {
			{ "C_TaskQuest.GetQuestZoneID", function()
				return C_TaskQuest and C_TaskQuest.GetQuestZoneID
					and C_TaskQuest.GetQuestZoneID(questID) end },
			{ "C_QuestLog.GetQuestAdditionalHighlights", function()
				return C_QuestLog and C_QuestLog.GetQuestAdditionalHighlights
					and C_QuestLog.GetQuestAdditionalHighlights(questID) end },
			{ "GetQuestUiMapID", function()
				return GetQuestUiMapID and GetQuestUiMapID(questID) end },
		}
		for _, probe in ipairs(probes) do
			local ok, result = pcall(probe[2])
			MM:Print("      %-42s -> %s", probe[1],
				(ok and type(result) == "number" and result > 0) and mapName(result)
					or (ok and tostring(result) or "error"))
		end
	end
	if n == 0 then
		MM:Print("  (none seen — no covenant, or the API hasn't answered yet)")
	end

	local cached = 0
	for _ in pairs(MM.db.callingZones or {}) do cached = cached + 1 end
	MM:Print("Learned zone cache: %d entries. |cff9a9a9a/mm callings clear|r wipes it.", cached)
end)

-- The learned cache persists to SavedVariables, so a bad value outlives reloads.
MM:On("MM_CALLINGS_CLEAR", function()
	MM.db.callingZones = {}
	wipe(C.active)
	C.offered = nil
	MM:Print("Calling state cleared. Re-resolving...")
	C.Request()
end)
