-- Master Mounts zone alert: on entering a zone, show what is farmable HERE
-- that you're still missing, rarest first.
--
-- This is a different question from the rare alert. RareAlert answers "a rare
-- is up right now, go"; this answers "you just arrived somewhere — here is
-- what this place owes you", which is what makes a detour worth taking.
local _, MM = ...
local U = MM.Util

MM.ZoneAlert = {}
local ZA = MM.ZoneAlert

local MAX_ROWS = 5
local lastMapID
local frame

------------------------------------------------------------
-- Rarity colouring: a 1-in-2000 drop should not look like a 1-in-5
------------------------------------------------------------
local function rarityColor(dropRate)
	if not dropRate then return 0.8, 0.8, 0.8 end
	if dropRate < 0.5 then return 1, 0.3, 0.4 end      -- brutal
	if dropRate < 2 then return 1, 0.55, 0.2 end       -- rare
	if dropRate < 10 then return 1, 0.85, 0.3 end      -- uncommon
	return 0.45, 0.9, 0.5                              -- likely
end

local function chanceText(rec)
	if not rec.dropRate then return "" end
	return ("1/%d (%.2f%%)"):format(math.max(1, math.floor(100 / rec.dropRate)), rec.dropRate)
end

------------------------------------------------------------
-- What's here that we still need
------------------------------------------------------------
function ZA.MountsInZone(mapID)
	local out = {}
	if not mapID then return out end
	for _, entry in ipairs(MM.Scanner.mounts) do
		local rec = entry.rec
		if not entry.collected and rec and not rec.stub and rec.obtainable ~= false
			and MM.Scanner:FactionOk(entry)
			and not (MM.db.ignored and MM.db.ignored[entry.spellID]) then
			if U.GetRecordMapID(rec) == mapID then
				tinsert(out, entry)
			end
		end
	end
	-- rarest first; anything without a rate sorts after those with one
	table.sort(out, function(a, b)
		local ra, rb = a.rec.dropRate, b.rec.dropRate
		if ra and rb then return ra < rb end
		if ra then return true end
		if rb then return false end
		return a.name < b.name
	end)
	return out
end

------------------------------------------------------------
-- Frame
------------------------------------------------------------
-- Where the header text starts, and therefore where the close button centres.
-- One header row, and every other measurement hangs off it.
local HEADER_H = 26
local ROW_H = 18
local BOTTOM_PAD = 6

local function build()
	if frame then return end
	frame = CreateFrame("Button", "MasterMountsZoneAlert", UIParent, "BackdropTemplate")
	frame:SetSize(300, 60)
	frame:SetPoint("TOP", UIParent, "TOP", 0, -260)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	frame:SetClampedToScreen(true)
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 14,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	frame:SetBackdropColor(0.03, 0.04, 0.07, 0.93)
	frame:SetBackdropBorderColor(0.35, 0.65, 1)
	MM.Theme.Register(frame, "panel")
	frame:SetScript("OnDragStart", function(s) s:StartMoving() end)
	frame:SetScript("OnDragStop", function(s)
		s:StopMovingOrSizing()
		local p, _, rp, x, y = s:GetPoint()
		MM.db.zoneAlertPos = { point = p, relPoint = rp, x = x, y = y }
	end)
	frame:SetScript("OnClick", function(s, button)
		if button == "RightButton" then s:Hide() else MM:Fire("MM_TOGGLE_MAIN", 1) end
	end)

	-- A real close button.
	--
	-- Hiding it was right-click only, which is undiscoverable: nothing on the
	-- window said so. That matters much more now the window can be pinned open
	-- -- a panel you cannot obviously dismiss is a panel people uninstall over.
	-- A real header row, and both things sit in the middle of it.
	--
	-- Twice wrong now. First the X was anchored to the frame corner while the
	-- title was anchored to the frame's top-left -- two different baselines.
	-- Then I "fixed" it by centring the button on the title's measured height…
	-- at BUILD time, when the title has no text and GetStringHeight() returns
	-- zero. The button ended up six pixels high, which is exactly what the
	-- screenshot showed. Measuring a thing before it exists is not measuring.
	--
	-- No measurement now, and nothing anchored to a corner. There is a header
	-- frame of known height; the title and the button are both anchored to its
	-- LEFT and RIGHT, which centres them vertically on the same line by
	-- construction. It cannot drift, and it does not care what the font is.
	local CLOSE_SIZE = 18
	frame.header = CreateFrame("Frame", nil, frame)
	frame.header:SetPoint("TOPLEFT", 0, 0)
	frame.header:SetPoint("TOPRIGHT", 0, 0)
	frame.header:SetHeight(HEADER_H)

	frame.close = MM.Theme.CreateCloseButton(frame, CLOSE_SIZE)
	frame.close:SetPoint("RIGHT", frame.header, "RIGHT", -2, 0)
	frame.close:SetScript("OnClick", function()
		frame:Hide()
		-- An explicit close beats the setting for this zone. Pinned means
		-- "keep showing it", not "refuse to go away".
		ZA.dismissedMap = C_Map.GetBestMapForUnit("player")
	end)

	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.title:SetPoint("LEFT", frame.header, "LEFT", 10, 0)
	frame.title:SetPoint("RIGHT", frame.close, "LEFT", -2, 0)
	frame.title:SetJustifyH("LEFT")
	frame.title:SetTextColor(0.45, 0.8, 1)
	MM.Theme.RegisterText(frame.title, "info")

	frame.rows = {}
	for i = 1, MAX_ROWS do
		-- A BUTTON, because the rows were the one thing here worth clicking and
		-- were the one thing that could not be. A plain Frame does not take
		-- clicks, so every click landed on the window behind and opened the
		-- whole collection -- the row under the cursor named the mount and the
		-- player still had to type its name.
		local row = CreateFrame("Button", nil, frame)
		row:SetSize(280, 18)
		row:SetPoint("TOPLEFT", 10, -HEADER_H - (i - 1) * ROW_H)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

		row.hl = row:CreateTexture(nil, "HIGHLIGHT")
		row.hl:SetAllPoints()
		MM.Theme.RegisterTint(row.hl, "accent", 0.10)

		row:SetScript("OnClick", function(s, button)
			if not s.entry then return end
			-- Right-click goes straight to Wowhead, matching every other list
			-- in the addon. Learning the gesture once should be enough.
			if button == "RightButton" then
				MM:ShowWowheadLink(s.entry)
			else
				MM:Fire("MM_SHOW_MOUNT", s.entry)
			end
		end)

		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetSize(15, 15)
		row.icon:SetPoint("LEFT")
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
		row.name:SetJustifyH("LEFT")
		row.name:SetWidth(165)
		row.name:SetWordWrap(false)

		row.chance = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.chance:SetPoint("RIGHT", 0, 0)
		row.chance:SetJustifyH("RIGHT")

		MM.Theme.Register(row, "row", false)
		frame.rows[i] = row
	end
	-- Read by the report. A row that takes clicks is the whole fix, and the
	-- only way to see it from outside is to ask what kind of frame it is.
	ZA.rowsClickable = true

	frame.more = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.more:SetPoint("BOTTOMLEFT", 10, 7)
	MM.Theme.RegisterText(frame.more, "muted")

	if MM.db.zoneAlertPos then
		frame:ClearAllPoints()
		frame:SetPoint(MM.db.zoneAlertPos.point, UIParent,
			MM.db.zoneAlertPos.relPoint, MM.db.zoneAlertPos.x, MM.db.zoneAlertPos.y)
	end
	MM.Theme.SkinTree(frame)
	frame:Hide()
end

function ZA.Show(list, zoneName)
	build()
	frame.title:SetText(#list == 0
		and ("%s — nothing to farm here"):format(zoneName or "This zone")
		or ("%s — %d mount%s to farm here"):format(
			zoneName or "This zone", #list, #list == 1 and "" or "s"))

	local shown = math.min(#list, MAX_ROWS)
	for i = 1, MAX_ROWS do
		local row, entry = frame.rows[i], list[i]
		if entry then
			row.entry = entry
			row.icon:SetTexture(entry.icon or 134400)
			row.name:SetText(entry.name)
			row.chance:SetText(chanceText(entry.rec))
			row.chance:SetTextColor(rarityColor(entry.rec.dropRate))
			row:Show()
		else
			-- Cleared as well as hidden: rows are reused between zones, and a
			-- stale entry on a hidden row is a click waiting to open the wrong
			-- mount the next time the list is shorter than this one.
			row.entry = nil
			row:Hide()
		end
	end

	local extra = #list - shown
	frame.more:SetText(extra > 0 and ("... and %d more (click to open)"):format(extra) or "")
	-- Derived from the same constants the layout uses, so an empty window is
	-- exactly a header tall rather than a header plus a guess.
	frame:SetHeight(HEADER_H + shown * ROW_H
		+ (extra > 0 and 16 or 0) + BOTTOM_PAD)
	frame:Show()

	-- Auto-hide, unless the player has pinned it open.
	--
	-- The token matters: every Show scheduled its own timer, so walking through
	-- three zones inside twelve seconds left three timers armed and the third
	-- window was closed by the first zone's countdown.
	ZA.showToken = (ZA.showToken or 0) + 1
	local token = ZA.showToken
	if MM.db.zoneAlertSticky then return end
	C_Timer.After(MM.db.zoneAlertSeconds or 12, function()
		if frame and frame:IsShown() and ZA.showToken == token then frame:Hide() end
	end)
end

------------------------------------------------------------
-- Trigger
------------------------------------------------------------
local function check()
	if MM.db.zoneAlert == false then return end
	-- Auto-open is separate from the feature being enabled: someone may want
	-- the window available on demand without it appearing by itself. Pinning it
	-- open and having it open itself are two different wishes.
	if MM.db.zoneAlertAutoOpen == false then return end
	if not MM.Scanner.ready then return end
	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID or mapID == lastMapID then return end
	lastMapID = mapID

	-- A fresh zone clears an explicit dismissal.
	if ZA.dismissedMap and ZA.dismissedMap ~= mapID then ZA.dismissedMap = nil end
	if ZA.dismissedMap == mapID then return end

	local list = ZA.MountsInZone(mapID)
	local info = C_Map.GetMapInfo(mapID)
	-- Pinned open means pinned open. Reporting "nothing here" is information;
	-- silently vanishing looks like the addon stopped working.
	if #list == 0 and not MM.db.zoneAlertSticky then return end
	ZA.Show(list, info and info.name)
end

-- Summon it for the current zone on demand. Without this the only way to see
-- the window was to walk somewhere new, which made it nearly untestable.
MM:On("MM_ZONE_SHOW", function()
	ZA.dismissedMap = nil
	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID then MM:Print("No map position here.") return end
	local info = C_Map.GetMapInfo(mapID)
	ZA.Show(ZA.MountsInZone(mapID), info and info.name)
end)

MM:RegisterGameEvent("ZONE_CHANGED_NEW_AREA", function()
	C_Timer.After(1.5, check)
end)

-- A /reload is not a zone change, so nothing above fires and a window the
-- player had PINNED OPEN simply never came back -- which reads as the setting
-- having been forgotten.
--
-- Only the sticky case is restored. A window that appeared because you walked
-- somewhere interesting is transient by nature and should not resurrect itself
-- on every login; one you pinned is a stated preference.
--
-- The delay is not politeness. Map data is genuinely absent for the first
-- moments after entering the world -- GetBestMapForUnit returns nil -- and
-- asking too early yields "No map position here" instead of the window.
MM:On("MM_LOGIN", function()
	if not MM.db.zoneAlertSticky then return end
	C_Timer.After(4, function()
		local mapID = C_Map.GetBestMapForUnit("player")
		if not mapID then return end
		lastMapID = mapID
		local info = C_Map.GetMapInfo(mapID)
		ZA.Show(ZA.MountsInZone(mapID), info and info.name)
	end)
end)

MM:On("MM_ZONE_DEBUG", function()
	lastMapID = nil
	local mapID = C_Map.GetBestMapForUnit("player")
	local list = ZA.MountsInZone(mapID)
	local info = mapID and C_Map.GetMapInfo(mapID)
	MM:Print("%s (map %s): %d farmable mounts you're missing.",
		info and info.name or "?", tostring(mapID), #list)
	for i = 1, math.min(10, #list) do
		MM:Print("  %s  %s", list[i].name, chanceText(list[i].rec))
	end
	if #list > 0 then ZA.Show(list, info and info.name) end
end)
