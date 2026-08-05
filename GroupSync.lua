-- Master Mounts group sync: know who around you has a mount, and what they
-- have that you don't.
--
-- The competing implementation delta-encodes collected mount IDs as decimal
-- text (~5 KB, ~23 chunks, ~9 seconds for a large collection), which is slow
-- enough that it can only support a manual "pick one player and request their
-- data" flow. Mount journal IDs top out around 2,600, so a BITFIELD packs the
-- same information into ~440 characters — two chunks, sub-second. That is
-- what makes a passive, cached, whole-group model possible instead.
--
-- Privacy: sharing is opt-in and OFF by default, the payload is WHISPERED to
-- the requester rather than broadcast to the channel, and the protocol
-- carries a version integer from the first message.
local _, MM = ...
local U = MM.Util

MM.GroupSync = {}
local GS = MM.GroupSync

local PREFIX = "MMountsGS"
local PROTOCOL = 1
local CHUNK = 200
local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+-"
local MAX_MOUNT_ID = 4000  -- generous headroom over the live journal range

-- [fullName] = { set = {[mountID]=true}, at = time, count = n, class = "MAGE" }
GS.collections = {}

local incoming = {}   -- [sender] = { parts = {}, total = n, at = time }

------------------------------------------------------------
-- Bitfield codec (6 bits per character)
------------------------------------------------------------
local charToVal = {}
for i = 1, #ALPHABET do charToVal[ALPHABET:sub(i, i)] = i - 1 end

local function encodeSet(set)
	local out, highest = {}, 0
	for id in pairs(set) do if id > highest then highest = id end end
	highest = math.min(highest, MAX_MOUNT_ID)
	for base = 0, highest, 6 do
		local v = 0
		for b = 0, 5 do
			if set[base + b] then v = v + bit.lshift(1, b) end
		end
		out[#out + 1] = ALPHABET:sub(v + 1, v + 1)
	end
	return table.concat(out)
end

local function decodeSet(str)
	local set, n = {}, 0
	for i = 1, #str do
		local v = charToVal[str:sub(i, i)]
		if v then
			local base = (i - 1) * 6
			for b = 0, 5 do
				if bit.band(v, bit.lshift(1, b)) ~= 0 then
					set[base + b] = true
					n = n + 1
				end
			end
		end
	end
	return set, n
end

------------------------------------------------------------
-- Identity / channel
------------------------------------------------------------
local function fullName()
	return ("%s-%s"):format(UnitName("player") or "?",
		(GetRealmName() or "?"):gsub("%s", ""))
end

local function groupChannel()
	if IsInRaid() then
		return IsInRaid(LE_PARTY_CATEGORY_INSTANCE) and "INSTANCE_CHAT" or "RAID"
	elseif IsInGroup() then
		return IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and "INSTANCE_CHAT" or "PARTY"
	end
	return nil
end

local function sharingAllowed()
	local cfg = MM.db and MM.db.groupSync
	return cfg and cfg.share and cfg.share ~= "none"
end

------------------------------------------------------------
-- Send
------------------------------------------------------------
local function mySet()
	local set = {}
	for _, entry in ipairs(MM.Scanner.mounts) do
		if entry.collected and entry.mountID then set[entry.mountID] = true end
	end
	return set
end

local function send(msg, channel, target)
	if not C_ChatInfo then return end
	pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, channel, target)
end

-- Whisper our collection to one player, chunked and paced.
function GS.SendCollection(target)
	if not sharingAllowed() then return end
	local payload = encodeSet(mySet())
	local chunks = {}
	for i = 1, #payload, CHUNK do
		chunks[#chunks + 1] = payload:sub(i, i + CHUNK - 1)
	end
	local class = select(2, UnitClass("player")) or ""
	for i, part in ipairs(chunks) do
		-- version is in every chunk so a mismatched peer bails immediately
		local msg = ("D|%d|%d|%d|%s|%s"):format(PROTOCOL, i, #chunks, class, part)
		C_Timer.After(0.25 * (i - 1), function() send(msg, "WHISPER", target) end)
	end
end

-- Ask everyone in the group to share (they decide whether to answer).
function GS.Request()
	local channel = groupChannel()
	if not channel then
		MM:Print("You are not in a group.")
		return
	end
	send(("Q|%d"):format(PROTOCOL), channel)
	MM:Print("Asked your group for collections. Answers arrive as they come in.")
end

------------------------------------------------------------
-- Receive
------------------------------------------------------------
local function store(sender, payload, class)
	local set, count = decodeSet(payload)
	GS.collections[sender] = { set = set, count = count, at = GetTime(), class = class }
	MM:Fire("MM_GROUPSYNC", sender, count)
end

local function onMessage(prefix, message, _, sender)
	if prefix ~= PREFIX or not message then return end
	if sender == fullName() then return end

	local kind, rest = message:match("^(%a)|(.*)$")
	if not kind then return end

	if kind == "Q" then
		-- a request: answer only if we've opted in, and only by whisper
		local ver = tonumber(rest)
		if ver ~= PROTOCOL then return end
		if sharingAllowed() then GS.SendCollection(sender) end
		return
	end

	if kind == "D" then
		local ver, seq, total, class, part =
			rest:match("^(%d+)|(%d+)|(%d+)|([^|]*)|(.*)$")
		ver, seq, total = tonumber(ver), tonumber(seq), tonumber(total)
		if ver ~= PROTOCOL or not seq or not total then return end

		local buf = incoming[sender]
		if not buf or buf.total ~= total or (GetTime() - buf.at) > 20 then
			buf = { parts = {}, total = total, at = GetTime() }
			incoming[sender] = buf
		end
		buf.parts[seq] = part
		buf.at = GetTime() -- sliding timeout: reset on every chunk

		local complete = true
		for i = 1, total do if not buf.parts[i] then complete = false break end end
		if complete then
			store(sender, table.concat(buf.parts), class)
			incoming[sender] = nil
		end
	end
end

------------------------------------------------------------
-- Queries
------------------------------------------------------------
-- Who in the cached group has this mount? Returns have, missing (name lists).
function GS.WhoHas(mountID)
	local have, missing = {}, {}
	if not mountID then return have, missing end
	for name, data in pairs(GS.collections) do
		local short = name:match("^([^-]+)") or name
		local color = data.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[data.class]
		if color and color.colorStr then short = "|c" .. color.colorStr .. short .. "|r" end
		tinsert(data.set[mountID] and have or missing, short)
	end
	return have, missing
end

-- Mounts someone in the group has that you do not.
function GS.TheyHaveYouDont()
	local out = {}
	for _, entry in ipairs(MM.Scanner.mounts) do
		if not entry.collected and entry.mountID then
			local have = GS.WhoHas(entry.mountID)
			if #have > 0 then tinsert(out, { entry = entry, have = have }) end
		end
	end
	return out
end

function GS.Forget()
	wipe(GS.collections)
	wipe(incoming)
	MM:Print("Cleared cached group collections.")
end

------------------------------------------------------------
-- Wiring
------------------------------------------------------------
MM:On("MM_LOGIN", function()
	MM.db.groupSync = MM.db.groupSync or { share = "none" }
	if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
		pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
	end
end)

MM:RegisterGameEvent("CHAT_MSG_ADDON", onMessage)

-- Leaving a group makes cached collections meaningless.
MM:RegisterGameEvent("GROUP_ROSTER_UPDATE", function()
	if not groupChannel() then wipe(GS.collections) end
end)

MM:On("MM_GROUPSYNC_DEBUG", function()
	local n = 0
	for name, d in pairs(GS.collections) do
		n = n + 1
		MM:Print("  %s — %d mounts (%ds ago)", name, d.count, math.floor(GetTime() - d.at))
	end
	if n == 0 then MM:Print("No group collections cached. Try /mm compare.") end
	local diff = GS.TheyHaveYouDont()
	MM:Print("Mounts someone here has that you don't: %d", #diff)
	for i = 1, math.min(10, #diff) do
		MM:Print("  %s — %s", diff[i].entry.name, table.concat(diff[i].have, ", "))
	end
end)
