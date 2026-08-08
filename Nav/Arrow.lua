-- Master Mounts navigation HUD: a crisp custom-art arrow with a clean
-- instruction card, used when TomTom isn't handling the leg (and always for
-- cross-continent guidance).
local _, MM = ...
local U = MM.Util

MM.Arrow = {}
local Arrow = MM.Arrow

local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

local ARROW_TEXTURE = MM.MEDIA .. "arrow.tga"

local frame, tex, label, dist, pill, pillPrimary, pillSecondary, action

-- SHOWING AND HIDING A SECURE BUTTON IS A PROTECTED ACT TOO.
--
-- Reported from a delve: MasterMountsArrowAction:Hide() blocked, over and over
-- until it filled the chat frame. The attribute writes on this button were
-- guarded against combat from the beginning and its VISIBILITY was not, which
-- reads as an oversight because it was one. Blizzard protects the frame, not
-- merely its attributes, so Show and Hide are refused in combat exactly as
-- SetAttribute is.
--
-- It surfaced in a delve for a reason worth keeping in mind: a delve is
-- wall-to-wall combat, and the arrow re-evaluates on every step of the route.
-- Anywhere else there is a lull for the deferred state to drain in, so a single
-- missing guard looked like nothing at all.
--
-- Forward-declared because the frame is built above and the helper reads best
-- beside the deferral it belongs to, further down.
local setActionShown

-- Card metrics. Declared HERE, above every use.
--
-- These are read inside build(), which runs far earlier in the file than the
-- card code that also uses them. A `local` declared below its first use is not
-- an error in Lua -- it silently becomes a global nil -- and this file would
-- have thrown on the first SetPoint. That is the fourth time this exact shape
-- has bitten in this addon, and luac -p passes every single time.
local CARD_MAX_TEXT = 340   -- wrap beyond this
local CARD_MIN_TEXT = 150   -- below this the box looks pinched rather than neat
local CARD_PAD_X, CARD_PAD_Y, CARD_GAP = 14, 10, 4
local target -- { mapID, x, y, label, continent, world, rec }

local function build()
	if frame then return end
	frame = CreateFrame("Button", "MasterMountsArrow", UIParent)
	frame:SetSize(360, 170)
	frame:SetPoint("CENTER", UIParent, "CENTER", 0, 230)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint()
		MM.db.arrowPos = { point = point, relPoint = relPoint, x = x, y = y }
	end)

	-- slow-spinning soft glow behind the arrow
	local glow = frame:CreateTexture(nil, "BACKGROUND")
	glow:SetPoint("TOP", 0, 6)
	glow:SetSize(110, 110)
	glow:SetTexture("Interface\\Cooldown\\star4")
	glow:SetBlendMode("ADD")
	glow:SetVertexColor(1, 0.75, 0.25, 0.22)
	local spinGroup = glow:CreateAnimationGroup()
	spinGroup:SetLooping("REPEAT")
	local spin = spinGroup:CreateAnimation("Rotation")
	spin:SetDegrees(360)
	spin:SetDuration(30)
	spinGroup:Play()

	-- our own high-res arrow art (Media/arrow.tga)
	tex = frame:CreateTexture(nil, "ARTWORK")
	tex:SetPoint("TOP")
	tex:SetSize(76, 76)
	tex:SetTexture(ARROW_TEXTURE)

	-- Action button: when the instruction is "use this", pointing a direction is
	-- useless. It takes the arrow's place at the same size so the HUD does not
	-- jump, and reverts the moment the thing has been used.
	--
	-- MUST be a SecureActionButtonTemplate -- Blizzard only permits item and toy
	-- use from a secure button, and its attributes may not be changed in combat.
	-- Everything that writes an attribute below is guarded by InCombatLockdown
	-- and re-applied on PLAYER_REGEN_ENABLED.
	action = CreateFrame("Button", "MasterMountsArrowAction", frame,
		"SecureActionButtonTemplate")
	action:SetSize(76, 76)
	action:SetPoint("TOP", 0, 0)
	action:RegisterForClicks("AnyUp", "AnyDown")

	action.icon = action:CreateTexture(nil, "ARTWORK")
	action.icon:SetPoint("TOPLEFT", 4, -4)
	action.icon:SetPoint("BOTTOMRIGHT", -4, 4)
	action.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	-- A hairline border, matching the instruction card below it.
	--
	-- This used to be Interface\Buttons\UI-ActionButton-Border, stretched with
	-- SetAllPoints and blended ADD. That texture is Blizzard's PROC GLOW: it is
	-- authored to be drawn well OUTSIDE the button it belongs to, with a wide
	-- transparent margin and a bright ring some way in from its edge. Forced
	-- down to the button's own bounds, that ring landed on top of the artwork --
	-- the odd inner outline and halo over the hearthstone.
	--
	-- The addon already has a border idiom, used by the card directly below this
	-- button: a one-pixel edge in the accent colour. Using it here makes the two
	-- read as one control instead of two unrelated widgets.
	action.backdrop = CreateFrame("Frame", nil, action, "BackdropTemplate")
	action.backdrop:SetAllPoints()
	action.backdrop:SetFrameLevel(math.max(0, action:GetFrameLevel() - 1))
	action.backdrop:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
	action.backdrop:SetBackdropColor(0.04, 0.04, 0.07, 0.9)

	action.border = CreateFrame("Frame", nil, action, "BackdropTemplate")
	action.border:SetAllPoints()
	action.border:SetBackdrop({
		edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1,
	})
	action.border:SetBackdropBorderColor(0.85, 0.68, 0.25, 0.9)

	action.cooldown = CreateFrame("Cooldown", nil, action, "CooldownFrameTemplate")
	action.cooldown:SetAllPoints(action.icon)

	action:SetScript("OnEnter", function(self)
		-- Whichever kind of thing the button is offering. Asking SetItemByID
		-- about a spell id draws some unrelated item, which is a quieter
		-- failure than the error log but a worse one to read.
		if self.mmItemID then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetItemByID(self.mmItemID)
		elseif self.mmSpellID then
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetSpellByID(self.mmSpellID)
		else
			return
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Click to use — Master Mounts", 0.4, 0.8, 1)
		GameTooltip:Show()
	end)
	action:SetScript("OnLeave", function() GameTooltip:Hide() end)
	-- Through the same guard: the HUD is built the first time it is needed, and
	-- that can perfectly well be mid-fight.
	setActionShown(false)

	label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	label:SetPoint("TOP", tex, "BOTTOM", 0, -2)
	label:SetWidth(340)
	label:SetWordWrap(false)
	label:SetTextColor(1, 0.86, 0.35)

	dist = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	dist:SetPoint("TOP", label, "BOTTOM", 0, -2)

	-- instruction card: dark pill so guidance is readable over any scenery
	pill = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	pill:SetPoint("TOP", dist, "BOTTOM", 0, -6)
	pill:SetWidth(CARD_MIN_TEXT + CARD_PAD_X * 2)
	pill:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	pill:SetBackdropColor(0.04, 0.04, 0.07, 0.85)
	pill:SetBackdropBorderColor(0.85, 0.68, 0.25, 0.9)

	pillPrimary = pill:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	pillPrimary:SetPoint("TOP", 0, -CARD_PAD_Y)
	pillPrimary:SetJustifyH("CENTER")
	pillPrimary:SetTextColor(1, 0.86, 0.35)

	pillSecondary = pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	pillSecondary:SetPoint("TOP", pillPrimary, "BOTTOM", 0, -CARD_GAP)
	pillSecondary:SetJustifyH("CENTER")
	pillSecondary:SetTextColor(0.82, 0.82, 0.82)
	pill:Hide()

	if MM.db.arrowPos then
		frame:ClearAllPoints()
		frame:SetPoint(MM.db.arrowPos.point, UIParent, MM.db.arrowPos.relPoint,
			MM.db.arrowPos.x, MM.db.arrowPos.y)
	end
	frame:SetScale(MM.db.arrowScale or 1)

	local throttle = 0
	frame:SetScript("OnUpdate", function(_, dt)
		throttle = throttle + dt
		if throttle < 0.05 then return end
		throttle = 0
		Arrow:Update()
	end)
	MM.Theme.Register(pill, "panel")
	MM.Theme.SkinTree(frame)
	-- Protected as well: it PARENTS the secure button, and Blizzard refuses
	-- an ancestor of one just as firmly as the button itself.
	MM.Util.SetShownWhenCombatAllows(frame, false)
end

-- Swap the arrow for a clickable "use this" button, or back again.
--
-- Secure attributes cannot be written in combat, so a change requested mid-fight
-- is remembered and applied on PLAYER_REGEN_ENABLED. The visible state still
-- updates immediately -- the player sees the right thing, they simply cannot
-- click it until combat ends, which is Blizzard's rule, not ours.
-- NOT EVERY TELEPORT IS AN ITEM. Death Gate, Zen Pilgrimage, Astral Recall,
-- every mage portal and all 76 dungeon teleports are SPELLS -- Teleports.lua
-- has stored them as `spell` rather than `item` from the beginning, and its own
-- cooldown helper branches on exactly that. This button only ever read `item`,
-- so for a spell hop it was handed nil and offered nothing to click.
-- Deferred visibility, alongside the deferred attributes.
--
-- The waiting is done by Util now, because the rare alert turned out to need
-- exactly the same thing for exactly the same reason -- it parents a secure
-- macro button, this parents a secure action button, and Blizzard refuses to
-- show or hide either in combat. Two copies of a rule is how the last one got
-- missed.
function setActionShown(want)
	if not action then return end
	MM.Util.SetShownWhenCombatAllows(action, want)
end

local pendingAction
local function applyAction(itemID, isToy, spellID)
	if not action then return end
	if InCombatLockdown() then
		pendingAction = { itemID = itemID, isToy = isToy, spellID = spellID }
		return
	end
	pendingAction = nil
	if itemID then
		action:SetAttribute("type", isToy and "toy" or "item")
		action:SetAttribute("spell", nil)
		if isToy then
			action:SetAttribute("toy", itemID)
			action:SetAttribute("item", nil)
		else
			-- item NAME is the reliable form for a bag item; fall back to the id
			action:SetAttribute("item", (C_Item and C_Item.GetItemNameByID
				and C_Item.GetItemNameByID(itemID)) or ("item:" .. itemID))
			action:SetAttribute("toy", nil)
		end
	elseif spellID then
		-- Spell NAME for the same reason the item uses its name: the secure
		-- handler resolves a name reliably across ranks and overrides.
		action:SetAttribute("type", "spell")
		action:SetAttribute("spell",
			(C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID))
			or spellID)
		action:SetAttribute("item", nil)
		action:SetAttribute("toy", nil)
	else
		action:SetAttribute("type", nil)
		action:SetAttribute("item", nil)
		action:SetAttribute("toy", nil)
		action:SetAttribute("spell", nil)
	end
end

local actionRequested = false

function Arrow:ShowAction(itemID, isToy, spellID)
	if not action then return end

	-- NOTHING TO OFFER IS NOT AN ERROR, IT IS THE ARROW.
	--
	-- Reported from outside as "1124x bad argument #1 to '?'". Update runs 20
	-- times a second and this ran unguarded on every tick, so one spell-only
	-- teleport produced a thousand identical errors a minute and buried the
	-- addon's own output in the process -- the report called it "completely
	-- unusable", and for that player it was.
	--
	-- The nil never reached the idempotence check below either: that returns
	-- early only when the button is ALREADY SHOWN, and a button that has never
	-- been shown fails it forever. So the error repeated rather than happening
	-- once.
	--
	-- Fall back to the arrow. A hop with neither an item nor a spell is a
	-- portal you walk to, and pointing at it is exactly right.
	if not (itemID or spellID) then
		Arrow:HideAction()
		return
	end

	actionRequested = true
	-- Idempotent: Update runs 20x a second and must not rewrite a secure
	-- attribute, reset a cooldown swipe or restart the icon on every tick.
	local key = itemID and ("i" .. itemID) or ("s" .. spellID)
	if action.mmKey == key and action:IsShown() then return end
	action.mmKey = key
	action.mmItemID = itemID
	action.mmSpellID = spellID

	local icon
	if itemID then
		icon = C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(itemID)
	else
		icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)
	end
	action.icon:SetTexture(icon or 134400)

	-- Same branch Teleports.cooldownRemaining takes, for the same reason.
	local start, duration
	if itemID then
		start, duration = C_Container.GetItemCooldown(itemID)
	elseif C_Spell and C_Spell.GetSpellCooldown then
		local info = C_Spell.GetSpellCooldown(spellID)
		if info then start, duration = info.startTime, info.duration end
	end
	if start and duration and duration > 1.5 then
		action.cooldown:SetCooldown(start, duration)
	else
		-- Clear() is not on every Cooldown implementation; setting a zero
		-- duration blanks the swipe on all of them.
		action.cooldown:SetCooldown(0, 0)
	end

	applyAction(itemID, isToy, spellID)
	tex:Hide()
	setActionShown(true)
end

function Arrow:HideAction()
	-- A SHOW THAT COMBAT DEFERRED STILL HAS TO BE CANCELLABLE.
	--
	-- Reading IsShown alone, this returned early whenever a Show was sitting in
	-- the queue rather than on screen -- and combat then ended and put up an
	-- action button for a hop that had already been cancelled.
	if not (action and (action:IsShown() or MM.Util.ShownPending(action))) then return end
	action.mmItemID = nil
	setActionShown(false)
	tex:Show()
	applyAction(nil)
end

-- Apply anything deferred by combat.
-- Visibility drains in Util's own PLAYER_REGEN_ENABLED handler; this one only
-- has the attributes left to apply.
MM:RegisterGameEvent("PLAYER_REGEN_ENABLED", function()
	if pendingAction then
		applyAction(pendingAction.itemID, pendingAction.isToy, pendingAction.spellID)
	end
end)

-- The card sizes to its content, in both directions.
--
-- It used to be a fixed 350px box whose height was guessed from the string
-- heights of text that had just been given a FIXED width -- so a short
-- instruction sat in a wide empty box, and a long one wrapped to a second line
-- the height never accounted for and ran into the border. the screenshot
-- caught both: "some border and text issues with the navigation".
--
-- GetStringWidth() reports the unwrapped width, so it can be asked how wide the
-- text WOULD like to be before deciding how wide to let it get.
local function showCard(primary, secondary)
	primary = primary or ""
	secondary = secondary or ""
	local hasSecondary = secondary ~= ""

	pillPrimary:SetText(primary)
	pillSecondary:SetText(secondary)
	pillSecondary:SetShown(hasSecondary)

	-- Widest line the text would like, clamped into a sane band.
	local natural = pillPrimary:GetStringWidth() or 0
	if hasSecondary then
		natural = math.max(natural, pillSecondary:GetStringWidth() or 0)
	end
	local textW = math.max(CARD_MIN_TEXT, math.min(CARD_MAX_TEXT, math.ceil(natural)))
	pillPrimary:SetWidth(textW)
	pillSecondary:SetWidth(textW)

	-- Heights are read AFTER the width is applied, so wrapped lines count.
	local h = CARD_PAD_Y * 2 + (pillPrimary:GetStringHeight() or 12)
	if hasSecondary then
		h = h + CARD_GAP + (pillSecondary:GetStringHeight() or 10)
	end
	pill:SetWidth(textW + CARD_PAD_X * 2)
	pill:SetHeight(math.ceil(h))
	pill:Show()
end

function Arrow:SetTarget(step)
	build()
	target = step
	label:SetText(step.label or "")
	MM.Util.SetShownWhenCombatAllows(frame, true)
end

function Arrow:Clear()
	target = nil
	if frame then
		Arrow:HideAction()
		MM.Util.SetShownWhenCombatAllows(frame, false)
	end
end

-- Bearing (radians, same convention as GetPlayerFacing: 0 = north, CCW
-- positive) from the player to a world point. The map-east / map-south basis
-- is measured at runtime from two tiny probe offsets, so no assumption about
-- WoW's world-coordinate axis convention is ever needed — this is what makes
-- the arrow track exactly like TomTom's.
local function worldBearing(targetWorld, playerMapID, playerMapPos, playerWorld)
	local px, py = playerMapPos:GetXY()
	local EPS = 0.01
	local _, wE = U.GetWorldPos(playerMapID, (px + EPS) * 100, py * 100)
	local _, wS = U.GetWorldPos(playerMapID, px * 100, (py + EPS) * 100)
	if not (wE and wS) then return nil end
	local ex, ey = wE.x - playerWorld.x, wE.y - playerWorld.y -- world delta of map-east
	local sx, sy = wS.x - playerWorld.x, wS.y - playerWorld.y -- world delta of map-south
	local dx, dy = targetWorld.x - playerWorld.x, targetWorld.y - playerWorld.y
	local det = ex * sy - ey * sx
	if det == 0 then return nil end
	local east = (dx * sy - dy * sx) / det
	local south = (ex * dy - ey * dx) / det
	return atan2(-east, -south) -- atan2(west component, north component)
end

local function aimAtWorld(world, playerMapID, playerMapPos, playerWorld)
	local bearing = worldBearing(world, playerMapID, playerMapPos, playerWorld)
	if bearing then
		tex:SetRotation(bearing - (GetPlayerFacing() or 0))
		return true
	end
	tex:SetRotation(0)
	return false
end

-- The body has several early returns; rather than clear the action button at
-- the top (which would rewrite secure attributes 20x a second and flicker the
-- icon), run it and then hide only if no path asked for the button.
--
-- Once the hearthstone goes on cooldown its cost exceeds flying, Teleports stops
-- recommending it, nothing calls ShowAction, and the arrow comes back on its own.
local function updateBody()
	if not target then return end

	local playerContinent, playerWorld, playerMapID, playerMapPos = U.PlayerWorldPos()
	if not playerWorld then
		tex:SetRotation(0)
		dist:SetText("")
		showCard("Position unavailable here", "Instanced areas hide map positions")
		return
	end

	local goalKey = target.entry and target.entry.spellID or target.label

	-- Some goals are not places at all.
	--
	-- Infinite Timereaver drops from ANY Timewalking dungeon: there is nothing
	-- to fly to and no door to stand outside. Pointing an arrow at one is worse
	-- than pointing at nothing, because it sends the player across the world to
	-- a spot that cannot help them. Offer the queue instead.
	local queued = MM.Queue and MM.Queue.Describe(target.rec)
	if queued then
		tex:SetRotation(0)
		tex:Hide()
		dist:SetText("")
		Arrow:HideAction()
		showCard(queued.label, queued.detail)
		pill:Show()
		return
	end

	if target.continent and playerContinent ~= target.continent then
		-- A hearthstone bound on the GOAL's continent beats any portal room, so
		-- ask before sending the player across the world to a portal. Flying
		-- cost is effectively infinite here — you cannot fly between continents.
		local hop = MM.Teleports.Best(target.continent, target.world, math.huge, goalKey)
		if hop then
			aimAtWorld(hop.world, playerMapID, playerMapPos, playerWorld)
			dist:SetText("")
			showCard(MM.Teleports.Describe(hop))
			Arrow:ShowAction(hop.option.item, hop.option.toy, hop.option.spell)
			return
		end

		-- cross-continent: steer at the concrete next travel step
		local zoneName = target.rec and target.rec.zone and target.rec.zone.name
			or (C_Map.GetMapInfo(target.mapID) and C_Map.GetMapInfo(target.mapID).name)
		local subWorld, primary, secondary =
			MM.Travel.Guide(target.continent, zoneName, playerContinent, playerWorld)
		if subWorld then
			aimAtWorld(subWorld, playerMapID, playerMapPos, playerWorld)
			local yards = U.WorldDistance(playerWorld, subWorld)
			dist:SetText(yards and ("%d yds"):format(yards) or "")
		else
			tex:SetRotation(0)
			dist:SetText("")
		end
		showCard(primary, secondary)
		return
	end

	-- same continent: point straight at the goal
	pill:Hide()
	local aimed = false
	if target.world then
		aimed = aimAtWorld(target.world, playerMapID, playerMapPos, playerWorld)
	end
	if not aimed and target.mapID == playerMapID then
		-- same map: pure map-space bearing needs no world data at all
		local px, py = playerMapPos:GetXY()
		local east, south = target.x / 100 - px, target.y / 100 - py
		tex:SetRotation(atan2(-east, -south) - (GetPlayerFacing() or 0))
		aimed = true
	end
	if not aimed then
		dist:SetText("")
		showCard("Recalculating...", nil)
		return
	end

	local yards = target.world and U.WorldDistance(playerWorld, target.world)

	-- Long haul on your own continent: a teleport can still beat the flight.
	-- Only worth asking once the trip is long enough to matter — suggesting a
	-- hearthstone for a 400-yard hop is the kind of noise that makes navigation
	-- advice feel unreliable.
	if yards and yards > 3000 then
		local hop = MM.Teleports.Best(target.continent, target.world, yards, goalKey)
		if hop then
			aimAtWorld(hop.world, playerMapID, playerMapPos, playerWorld)
			dist:SetText(("%d yds"):format(yards))
			showCard(MM.Teleports.Describe(hop))
			Arrow:ShowAction(hop.option.item, hop.option.toy, hop.option.spell)
			return
		end
	end

	if yards then
		if yards < 20 then
			dist:SetText("|cff40d860Arrived!|r")
			tex:SetRotation(0)
			-- Reaching one of several spawn points starts the sweep's dwell: if
			-- nothing turns up here shortly, the router moves to the next point.
			if MM.Router and MM.Router.NoteArrival then
				MM.Router.NoteArrival(MM.Router:Current())
			end
		else
			dist:SetText(("%d yds"):format(yards))
			if MM.Router and MM.Router.CancelSweepDwell then
				MM.Router.CancelSweepDwell()
			end
		end
	else
		dist:SetText("")
	end
end

-- Live rescale, so the slider shows its effect while you drag it.
--
-- Scaling the FRAME scales everything inside it -- arrow texture, name, distance
-- and the step pill -- in one go, which is what "make the arrow bigger" means to
-- someone reading it. Scaling the texture alone would leave the text behind.
function Arrow:SetScale(v)
	v = tonumber(v) or 1
	if v < 0.5 then v = 0.5 elseif v > 2.5 then v = 2.5 end
	MM.db.arrowScale = v
	if frame then frame:SetScale(v) end
end

function Arrow:Update()
	actionRequested = false
	updateBody()
	if not actionRequested then Arrow:HideAction() end
end

