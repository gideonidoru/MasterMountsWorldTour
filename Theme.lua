-- Master Mounts theming.
--
-- Two looks: "blizzard" (the stock gold-trimmed frames) and "elvui" (flat,
-- thin-bordered, matching an ElvUI setup). If ElvUI is installed we default to
-- its look, because a Blizzard-styled window inside an ElvUI interface is the
-- thing that looks broken.
--
-- Frames register themselves; the registry lets a theme change re-skin
-- everything live instead of demanding a reload. Where ElvUI exposes its own
-- Skins module we use it (best possible match), and otherwise we approximate
-- it ourselves — so this still works if their internals move.
local _, MM = ...

MM.Theme = {}
local T = MM.Theme

local registry = setmetatable({}, { __mode = "k" }) -- [frame] = kind

------------------------------------------------------------
-- Detection
------------------------------------------------------------
local elvCache
function T.HasElvUI()
	if elvCache ~= nil then return elvCache end
	elvCache = (_G.ElvUI ~= nil)
	return elvCache
end

-- ElvUI's own skinning module, when its internals are where we expect.
local function elvSkins()
	if not T.HasElvUI() then return nil end
	local ok, E = pcall(function() return unpack(_G.ElvUI) end)
	if not ok or type(E) ~= "table" or not E.GetModule then return nil end
	local ok2, S = pcall(E.GetModule, E, "Skins")
	if ok2 and type(S) == "table" then return S, E end
	return nil, E
end

function T.Active()
	local set = MM.db and MM.db.theme
	if set == "elvui" or set == "blizzard" then return set end
	return T.HasElvUI() and "elvui" or "blizzard"
end

------------------------------------------------------------
-- Palettes
------------------------------------------------------------
local PALETTE = {
	blizzard = {
		bg = { 0.05, 0.05, 0.08, 0.92 },
		border = { 0.85, 0.65, 0.2, 1 },
		accent = { 1, 0.82, 0.2 },
		header = { 0.85, 0.65, 0.2, 0.15 },
		row = { 1, 1, 1, 0.03 },
	},
	elvui = {
		-- flat near-black with a hairline border is the ElvUI signature
		bg = { 0.06, 0.06, 0.06, 0.92 },
		border = { 0, 0, 0, 1 },
		accent = { 0.09, 0.51, 0.82 },   -- ElvUI's default blue
		header = { 0.09, 0.51, 0.82, 0.12 },
		row = { 1, 1, 1, 0.02 },
	},
}

function T.Colors()
	return PALETTE[T.Active()] or PALETTE.blizzard
end

function T.Accent()
	local c = T.Colors().accent
	return c[1], c[2], c[3]
end

------------------------------------------------------------
-- Skinning
------------------------------------------------------------
local restoreArt  -- forward declaration (defined with the flat skin below)
local function skinBlizzard(frame, kind)
	-- undo anything the flat skin added, so switching back is complete
	if frame.mmBackground then frame.mmBackground:SetAlpha(0) end
	if frame.mmBorder then
		for _, t in pairs(frame.mmBorder) do t:SetAlpha(0) end
	end
	if frame.mmCloseX then frame.mmCloseX:SetAlpha(0) end
	if restoreArt then restoreArt(frame) end
	-- undo glyph tinting
	for _, get in ipairs({ "GetNormalTexture", "GetPushedTexture",
		"GetDisabledTexture", "GetHighlightTexture" }) do
		if frame[get] then
			local okT, t = pcall(frame[get], frame)
			if okT and t and t.SetVertexColor then
				pcall(t.SetVertexColor, t, 1, 1, 1)
				pcall(t.SetDesaturated, t, false)
			end
		end
	end
	if kind == "statusbar" and frame.SetStatusBarColor then
		pcall(frame.SetStatusBarColor, frame, 0.25, 0.85, 0.4)
	end
	-- restore native close geometry (its art needs the padded anchor)
	local g = frame.mmCloseGeom
	if g and g.p then
		frame:SetSize(g.w, g.h)
		frame:ClearAllPoints()
		frame:SetPoint(g.p, g.rel, g.relP, g.x, g.y)
	end

	if kind == "panel" or kind == "frame" then
		local c = PALETTE.blizzard
		if frame.SetBackdrop and frame.mmBackdropOwned then
			frame:SetBackdrop({
				bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
				tile = true, tileSize = 16, edgeSize = 14,
				insets = { left = 4, right = 4, top = 4, bottom = 4 },
			})
			frame:SetBackdropColor(unpack(c.bg))
			frame:SetBackdropBorderColor(unpack(c.border))
		end
	end
end

------------------------------------------------------------
-- Self-contained flat skin.
--
-- The ElvUI look is flat fills and hairline borders — it needs no artwork at
-- all, only a solid-colour texture the game already ships. So this theme
-- works fully WITHOUT ElvUI installed, and we never redistribute anyone
-- else's art.
------------------------------------------------------------
local SOLID = "Interface\\Buttons\\WHITE8X8"
local flatSkin  -- forward declaration; skinElv falls through to it

-- Draw a 1px border out of four thin textures (cheap, no edge file, and it
-- stays exactly 1px at any frame size unlike a scaled edgeFile).
local function flatBorder(frame, r, g, b, a)
	if frame.mmBorder then
		for _, t in pairs(frame.mmBorder) do
			t:SetColorTexture(r, g, b, a or 1)
			t:SetAlpha(1)
		end
		return
	end
	local edges = {}
	local defs = {
		top    = { "TOPLEFT", 0, 0, "TOPRIGHT", 0, 0, nil, 1 },
		bottom = { "BOTTOMLEFT", 0, 0, "BOTTOMRIGHT", 0, 0, nil, 1 },
		left   = { "TOPLEFT", 0, 0, "BOTTOMLEFT", 0, 0, 1, nil },
		right  = { "TOPRIGHT", 0, 0, "BOTTOMRIGHT", 0, 0, 1, nil },
	}
	for name, d in pairs(defs) do
		local t = frame:CreateTexture(nil, "BORDER")
		t:SetColorTexture(r, g, b, a or 1)
		t:SetPoint(d[1], frame, d[1], d[2], d[3])
		t:SetPoint(d[4], frame, d[4], d[5], d[6])
		if d[7] then t:SetWidth(d[7]) end
		if d[8] then t:SetHeight(d[8]) end
		edges[name] = t
	end
	frame.mmBorder = edges
end

local function flatBackground(frame, c)
	if not frame.mmBackground then
		local t = frame:CreateTexture(nil, "BACKGROUND")
		t:SetAllPoints()
		frame.mmBackground = t
	end
	frame.mmBackground:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
	frame.mmBackground:SetAlpha(1)
end

-- Blizzard button/checkbox templates carry their own art; strip it so the
-- flat styling is actually visible.
-- Hide template art by ALPHA, never by SetTexture(nil): the texture path
-- cannot be recovered afterwards, so a destructive strip would make switching
-- back to the Blizzard theme impossible without a reload.
-- Modern Blizzard templates keep most of their art in named sub-objects and a
-- NineSlice frame, NOT in the texture returned by GetNormalTexture. Missing
-- those is why a "flat" skin still looks like a gold Blizzard window.
local CHROME_KEYS = {
	"Left", "Middle", "Right", "TopLeft", "TopRight", "BottomLeft",
	"BottomRight", "Center", "Background", "Border", "Bg", "TitleBg",
	"TopTileStreaks", "portrait", "PortraitFrame", "TopBorder",
	"BottomBorder", "LeftBorder", "RightBorder",
}

-- Art WE put there is content, not chrome.
--
-- The strip hides `portrait` and everything inside PortraitContainer, which is
-- right for Blizzard's gold frame but wrong for our own icon sitting in that
-- exact slot: switching to the flat theme blanked the main window's icon while
-- the Blizzard theme showed it fine. A texture tagged mmKeep is ours and
-- survives every skin.
local function ours(r)
	return type(r) == "table" and r.mmKeep == true
end

local function templateRegions(frame)
	local out = {}
	for _, get in ipairs({ "GetNormalTexture", "GetPushedTexture",
		"GetDisabledTexture", "GetHighlightTexture", "GetCheckedTexture" }) do
		if frame[get] then
			local ok, t = pcall(frame[get], frame)
			if ok and t then out[#out + 1] = t end
		end
	end
	for _, key in ipairs(CHROME_KEYS) do
		local r = frame[key]
		if type(r) == "table" and r.GetObjectType and not ours(r) then
			local ok, kind = pcall(r.GetObjectType, r)
			if ok and kind == "Texture" then out[#out + 1] = r end
		end
	end
	-- NineSlice and friends are frames of textures. Collect the TEXTURES
	-- inside them, never the container itself — hiding the container would
	-- also hide its FontStrings, i.e. the window title.
	for _, container in ipairs({ frame.NineSlice, frame.PortraitContainer,
		frame.TitleContainer, frame.Inset }) do
		if type(container) == "table" and container.GetRegions then
			local ok, regions = pcall(function() return { container:GetRegions() } end)
			if ok then
				for _, r in ipairs(regions) do
					-- GetObjectType lets us keep text and drop art
					if r and r.GetObjectType and r:GetObjectType() == "Texture"
						and not ours(r) then
						out[#out + 1] = r
					end
				end
			end
		end
	end
	return out
end

local function hideArt(frame)
	local keep = frame.GetCheckedTexture and select(2, pcall(frame.GetCheckedTexture, frame))
	for _, t in ipairs(templateRegions(frame)) do
		if t ~= keep then pcall(t.SetAlpha, t, 0) end
	end
end

function restoreArt(frame)
	for _, t in ipairs(templateRegions(frame)) do t:SetAlpha(1) end
end

function flatSkin(frame, kind, c)
	if kind == "frame" or kind == "panel" then
		-- A Blizzard template frame keeps drawing its gold chrome over
		-- anything we add underneath, so it has to be hidden first.
		hideArt(frame)
		if frame.SetBackdrop and frame.mmBackdropOwned then
			pcall(frame.SetBackdrop, frame, {
				bgFile = SOLID, edgeFile = SOLID, edgeSize = 1,
			})
			pcall(frame.SetBackdropColor, frame, unpack(c.bg))
			pcall(frame.SetBackdropBorderColor, frame, unpack(c.border))
		else
			flatBackground(frame, { c.bg[1], c.bg[2], c.bg[3], 0.96 })
			flatBorder(frame, 0, 0, 0, 1)
		end
		-- title text is part of the look; recolour rather than hide it
		local title = frame.TitleText
			or (frame.TitleContainer and frame.TitleContainer.TitleText)
		if title and title.SetTextColor then
			title:SetAlpha(1)
			title:SetTextColor(1, 1, 1)
		end
		return
	end

	if kind == "button" then
		hideArt(frame)
		flatBackground(frame, { 0.12, 0.12, 0.12, 1 })
		flatBorder(frame, 0, 0, 0, 1)
		-- Tint the EXISTING highlight; never swap its texture. Replacing the
		-- texture path is unrecoverable, which is what left a solid white
		-- block behind after switching back to the Blizzard theme.
		local hl = frame.GetHighlightTexture and frame:GetHighlightTexture()
		if hl and hl.SetVertexColor then
			pcall(hl.SetVertexColor, hl, c.accent[1], c.accent[2], c.accent[3], 0.45)
			pcall(hl.SetAlpha, hl, 1)
		end
		local fs = frame.GetFontString and frame:GetFontString()
		if fs then fs:SetTextColor(1, 1, 1) end
		return
	end

	if kind == "checkbox" then
		hideArt(frame)
		flatBackground(frame, { 0.12, 0.12, 0.12, 1 })
		flatBorder(frame, 0, 0, 0, 1)
		-- keep the tick, tint it to the accent so state is still obvious
		local checked = frame.GetCheckedTexture and frame:GetCheckedTexture()
		if checked then
			checked:SetVertexColor(c.accent[1], c.accent[2], c.accent[3], 1)
		end
		return
	end

	-- Small glyph buttons (close, scroll arrows, +/- row buttons): tint the
	-- existing art rather than hiding it, so the glyph survives.
	if kind == "glyph" then
		local dimmed = { 0.55, 0.55, 0.58 }
		for _, get in ipairs({ "GetNormalTexture", "GetPushedTexture", "GetDisabledTexture" }) do
			if frame[get] then
				local okT, t = pcall(frame[get], frame)
				if okT and t and t.SetVertexColor then
					pcall(t.SetVertexColor, t, dimmed[1], dimmed[2], dimmed[3])
					pcall(t.SetDesaturated, t, true)
				end
			end
		end
		local hl = frame.GetHighlightTexture and frame:GetHighlightTexture()
		if hl and hl.SetVertexColor then
			pcall(hl.SetVertexColor, hl, c.accent[1], c.accent[2], c.accent[3])
		end
		return
	end

	if kind == "statusbar" then
		if frame.SetStatusBarColor then
			pcall(frame.SetStatusBarColor, frame, c.accent[1], c.accent[2], c.accent[3])
		end
		return
	end

	if kind == "scrollbar" then
		hideArt(frame)
		flatBackground(frame, { 0.10, 0.10, 0.10, 0.8 })
		return
	end

	if kind == "close" then
		-- Blizzard's close art is 32px with ~10px of transparent padding, so
		-- its native anchor sits OUTSIDE the frame. Flat art has no padding,
		-- so it needs its own smaller, inset geometry.
		if not frame.mmCloseGeom then
			local p, rel, relP, x, y = frame:GetPoint()
			frame.mmCloseGeom = { p = p, rel = rel, relP = relP, x = x, y = y,
				w = frame:GetWidth(), h = frame:GetHeight() }
		end
		local g = frame.mmCloseGeom
		if g.p then
			frame:SetSize(16, 16)
			frame:ClearAllPoints()
			frame:SetPoint(g.p, g.rel, g.relP, -5, -5)
		end
		hideArt(frame)
		flatBackground(frame, { 0.10, 0.10, 0.10, 0.9 })
		flatBorder(frame, 0, 0, 0, 1)
		if not frame.mmCloseX then
			local x = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
			x:SetPoint("CENTER", 0, 0)
			x:SetText("x")
			frame.mmCloseX = x
			-- brighten on hover so it reads as interactive without shouting
			frame:HookScript("OnEnter", function(self)
				if self.mmCloseX then self.mmCloseX:SetTextColor(1, 0.4, 0.4) end
			end)
			frame:HookScript("OnLeave", function(self)
				if self.mmCloseX then self.mmCloseX:SetTextColor(0.65, 0.65, 0.65) end
			end)
		end
		frame.mmCloseX:SetTextColor(0.65, 0.65, 0.65)
		frame.mmCloseX:SetAlpha(1)
		return
	end
end

local function skinElv(frame, kind)
	local S = elvSkins()
	local c = PALETTE.elvui

	-- Prefer ElvUI's own handlers: they match the player's exact settings.
	if S then
		local handler =
			(kind == "button" and S.HandleButton)
			or (kind == "close" and S.HandleCloseButton)
			or (kind == "checkbox" and S.HandleCheckBox)
			or (kind == "editbox" and S.HandleEditBox)
			or (kind == "scrollbar" and S.HandleScrollBar)
			or ((kind == "frame" or kind == "panel") and S.HandleFrame)
		if handler then
			local ok = pcall(handler, S, frame)
			if ok then return end
		end
	end

	flatSkin(frame, kind, c)
end

-- Apply the active theme to one frame.
function T.Skin(frame, kind)
	if not frame then return end
	if T.Active() == "elvui" then
		skinElv(frame, kind)
	else
		skinBlizzard(frame, kind)
	end
end

-- Register a frame so it is skinned now and re-skinned on theme change.
-- `owned` means WE created its backdrop, so we may safely restyle it.
function T.Register(frame, kind, owned)
	if not frame then return frame end
	frame.mmBackdropOwned = owned ~= false
	registry[frame] = kind or "frame"
	T.Skin(frame, kind or "frame")
	return frame
end

------------------------------------------------------------
-- Compact close button.
--
-- Blizzard's UIPanelCloseButton is built for large ornate frames: 32px of art
-- with ~10px of transparent padding, anchored OUTSIDE the frame so the padding
-- lands on the border. On a small HUD panel it always overhangs the corner and
-- reads as floating, in either theme. Our panels use this instead — a plain
-- button with a text glyph, so it is exactly the size it looks and sits where
-- it is anchored.
------------------------------------------------------------
local iconButtons = setmetatable({}, { __mode = "k" })

local REST = { 0.62, 0.62, 0.62 }

-- Shared chassis for our own small icon buttons.
--
-- Blizzard's UIPanelCloseButton / UIPanelButtonTemplate both carry art sized
-- for large ornate frames, which is why they never sat right on these HUD
-- panels. These are exactly the size they are given, sit where they are
-- anchored, and self-tint in both themes.
local function iconButton(parent, size, hover)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(size or 16, size or 16)
	b.mmNoSkin = true  -- fully self-styled; the sweep must not touch it
	b.mmHover = hover or { 1, 0.35, 0.35 }

	b.art = b:CreateTexture(nil, "ARTWORK")
	b.art:SetAllPoints()

	function b:mmTint(r, g, bl)
		if self.art:IsShown() then self.art:SetVertexColor(r, g, bl)
		elseif self.glyph then self.glyph:SetTextColor(r, g, bl) end
	end

	b:SetScript("OnEnter", function(self)
		self:mmTint(self.mmHover[1], self.mmHover[2], self.mmHover[3])
		if self.mmTooltip then
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(self.mmTooltip, 1, 1, 1, 1, true)
			GameTooltip:Show()
		end
	end)
	b:SetScript("OnLeave", function(self)
		self:mmTint(REST[1], REST[2], REST[3])
		GameTooltip:Hide()
	end)

	iconButtons[b] = true
	return b
end

-- SetAtlas silently draws nothing for an unknown atlas rather than erroring, so
-- an atlas must be confirmed to exist BEFORE relying on it; a pcall around
-- SetAtlas always reports success and leaves an invisible button behind.
local function hasAtlas(name)
	return C_Texture and C_Texture.GetAtlasInfo
		and C_Texture.GetAtlasInfo(name) ~= nil
end

-- Fall back to a text glyph when the client lacks the atlas.
local function glyphFallback(b, char)
	b.art:Hide()
	local g = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	g:SetPoint("CENTER", 0, 0)
	g:SetText(char)
	b.glyph = g
end

-- A control that looks like what it is.
--
-- Every "dropdown" in the addon was a UIPanelButtonTemplate that happened to
-- open a context menu, so a control offering a CHOICE was indistinguishable
-- from one performing an ACTION -- the player had no way to tell that clicking
-- it opens a list rather than doing something. Retail ships a proper dropdown
-- template; use it where it exists and keep the button as the fallback so older
-- clients still work.
--
-- `setup(root)` populates the menu. `text()` returns the current label.
function T.CreateDropdown(parent, width, text, setup)
	local d
	if C_XMLUtil and C_XMLUtil.GetTemplateInfo
		and C_XMLUtil.GetTemplateInfo("WowStyle1DropdownTemplate") then
		d = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
		d:SetWidth(width)
		d:SetHeight(24)
		if d.SetupMenu then
			d:SetupMenu(function(_, root) setup(root) end)
		end
		d.mmRefresh = function()
			if d.SetText then d:SetText(text()) end
			if d.GenerateMenu then d:GenerateMenu() end
		end
	else
		d = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
		d:SetSize(width, 24)
		d:SetScript("OnClick", function(self)
			if MenuUtil and MenuUtil.CreateContextMenu then
				MenuUtil.CreateContextMenu(self, function(_, root) setup(root) end)
			end
		end)
		d.mmRefresh = function() d:SetText(text()) end
	end
	d.mmRefresh()
	d:HookScript("OnShow", function() d.mmRefresh() end)
	T.Register(d, "button")
	return d
end

function T.CreateCloseButton(parent, size)
	local b = iconButton(parent, size, { 1, 0.35, 0.35 })
	if hasAtlas("uitools-icon-close") then
		b.art:SetAtlas("uitools-icon-close", false)
	else
		glyphFallback(b, "x")
	end
	b:mmTint(REST[1], REST[2], REST[3])
	return b
end

-- Expand: a thin double-headed arrow running bottom-left to top-right -- the
-- universal enlarge/maximise glyph.
--
-- Media/expand.tga is our own art (tools/make_expand_tga.py) rather than a
-- rotated Media/arrow.tga. Rotating the nav arrow produced a solid triangular
-- pointer that read as navigation, not expansion; this is deliberately a thin
-- shaft with open arrowheads, and being double-headed it cannot be mistaken for
-- a direction indicator. The art is white with the shape carried in alpha, so
-- vertex tinting recolours it cleanly.
--
-- It carries its own margin (tips stop at 12% from each edge), so it wants
-- SetAllPoints -- no inset, and no rotation to clip its corners.
function T.CreateExpandButton(parent, size)
	local b = iconButton(parent, size, { 1, 0.86, 0.35 })
	b.art:SetTexture(MM.MEDIA .. "expand.tga")
	b:mmTint(REST[1], REST[2], REST[3])
	return b
end

-- A square stop glyph, drawn rather than shipped: a solid inset block needs no
-- art file and tints through the same hover path as the others.
function T.CreateStopButton(parent, size)
	size = size or 16
	local b = iconButton(parent, size, { 1, 0.45, 0.45 })
	b.art:SetColorTexture(1, 1, 1, 1)
	b.art:ClearAllPoints()
	local inset = math.max(3, math.floor(size * 0.28))
	b.art:SetPoint("TOPLEFT", inset, -inset)
	b.art:SetPoint("BOTTOMRIGHT", -inset, inset)
	b:mmTint(REST[1], REST[2], REST[3])
	return b
end

local function retintIconButtons()
	for b in pairs(iconButtons) do
		if not b:IsMouseOver() then b:mmTint(REST[1], REST[2], REST[3]) end
	end
end

------------------------------------------------------------
-- Recursive sweep.
--
-- Hand-registering every widget means every new button is a chance to forget
-- one — and that is exactly how the first pass shipped with red Options and
-- Compact buttons. Instead we walk a window's descendants and skin whatever
-- is actually there, so future widgets are covered for free.
------------------------------------------------------------
local function inferKind(child)
	local ok, objType = pcall(child.GetObjectType, child)
	if not ok then return nil end

	if objType == "CheckButton" then return "checkbox" end
	if objType == "StatusBar" then return "statusbar" end
	if objType == "Slider" then return "scrollbar" end
	if objType ~= "Button" then return nil end

	-- A small square button with no label is a close/arrow glyph; giving it
	-- the full button treatment would erase the glyph and leave a blank box.
	local fs = child.GetFontString and child:GetFontString()
	local text = fs and fs:GetText()
	local w, h = child:GetWidth(), child:GetHeight()
	if (not text or text == "") and w and h and w <= 34 and h <= 34 then
		-- distinguish a close button from a scroll arrow by its art: the
		-- former should be redrawn flat, the latter only tinted
		local nt = child.GetNormalTexture and select(2, pcall(child.GetNormalTexture, child))
		if nt then
			local okA, atlas = pcall(nt.GetAtlas, nt)
			local okT, path = pcall(nt.GetTexture, nt)
			local art = ((okA and atlas) or (okT and type(path) == "string" and path) or ""):lower()
			if art:find("close") or art:find("minimize") then return "close" end
		end
		return "glyph"
	end
	return "button"
end

function T.SkinTree(frame, depth)
	if not frame or (depth or 0) > 6 then return end
	local ok, children = pcall(function() return { frame:GetChildren() } end)
	if not ok then return end
	for _, child in ipairs(children) do
		if child and child.GetObjectType and not child.mmNoSkin then
			-- an explicit Register() is authoritative; the sweep only guesses
			-- for widgets nobody classified, and guessing "glyph" for a close
			-- button desaturates its art into a pale blob
			local kind = registry[child] or inferKind(child)
			if kind then
				registry[child] = kind
				T.Skin(child, kind)
			end
			T.SkinTree(child, (depth or 0) + 1)
		end
	end
end

function T.ReskinAll()
	for frame, kind in pairs(registry) do
		if frame.IsObjectType then T.Skin(frame, kind) end
	end
	-- re-sweep top-level windows: scroll rows are recycled and new ones may
	-- have appeared since the last pass
	local c = T.Colors()
	for _, name in ipairs({ "MasterMountsFrame", "MasterMountsMonitor",
		"MasterMountsCompact", "MasterMountsZoneAlert", "MasterMountsRareAlert",
		"MasterMountsArrow" }) do
		local f = _G[name]
		if f then
			T.SkinTree(f)
			if f.mmBand then
				f.mmBand:SetColorTexture(c.header[1], c.header[2], c.header[3], c.header[4] or 0.15)
			end
		end
	end
	MM:Fire("MM_THEME_CHANGED")
	retintIconButtons()
end

function T.Set(name)
	MM.db.theme = name
	T.ReskinAll()
	MM:Print("Theme set to %s.%s", name,
		name == "elvui" and "" or " (ElvUI detected — /mm theme elvui to switch back)")
end

------------------------------------------------------------
-- Wiring
------------------------------------------------------------
MM:On("MM_LOGIN", function()
	if MM.db.theme == nil and T.HasElvUI() then
		MM:Print("ElvUI detected — using the ElvUI theme. Change it in Options.")
	end
	C_Timer.After(1, T.ReskinAll)
end)

MM:On("MM_THEME_DEBUG", function()
	-- "Theme: elvui (ElvUI absent)" reads as a contradiction and is not one.
	-- The PALETTE is ours and applies on any client; what needs ElvUI present
	-- is its own skinning module, which restyles Blizzard's widgets. Choosing
	-- the ElvUI look without ElvUI installed is a legitimate cosmetic choice,
	-- and the line now says which half is running rather than leaving the
	-- reader to reconcile two facts that look opposed.
	local palette = T.Active()
	if palette == "elvui" and not T.HasElvUI() then
		MM:Print("Theme: elvui palette (ElvUI is not installed, so its skinning"
			.. " is not applied -- the colours are ours and work regardless)")
		return
	end
	MM:Print("Theme: %s (ElvUI %s, skins module %s)", palette,
		T.HasElvUI() and "detected" or "absent",
		elvSkins() and "available" or "unavailable")
end)
