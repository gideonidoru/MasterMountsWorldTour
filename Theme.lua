-- Master Mounts theming.
--
-- Three looks: "modern" (textured charcoal and warm gold), "blizzard" (the
-- stock gold-trimmed frames), and "elvui" (flat, thin-bordered, matching an
-- ElvUI setup). Auto prefers ElvUI when it is installed and Modern otherwise.
-- Explicit choices always win, so a user who selected Blizzard stays on it.
--
-- Frames register themselves; the registry lets a theme change re-skin
-- everything live instead of demanding a reload. Where ElvUI exposes its own
-- Skins module we use it (best possible match), and otherwise we approximate
-- it ourselves — so this still works if their internals move.
local _, MM = ...

MM.Theme = {}
local T = MM.Theme

local registry = setmetatable({}, { __mode = "k" }) -- [frame] = kind
local textRegistry = setmetatable({}, { __mode = "k" }) -- [fontString] = role/original
local surfaceRegistry = setmetatable({}, { __mode = "k" }) -- [texture] = semantic surface
local ruleRegistry = setmetatable({}, { __mode = "k" }) -- [texture] = visual strength
local tintRegistry = setmetatable({}, { __mode = "k" }) -- [texture] = role/alpha
local backdropBorderRegistry = setmetatable({}, { __mode = "k" }) -- [frame] = strength

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
	if set == "modern" or set == "elvui" or set == "blizzard" then return set end
	return T.Auto()
end

function T.Auto()
	if T.HasElvUI() then return "elvui" end
	return "modern"
end

------------------------------------------------------------
-- Palettes
------------------------------------------------------------
local PALETTE = {
	modern = {
		bg = { 0.025, 0.022, 0.020, 0.98 },
		border = { 0.40, 0.31, 0.10, 0.72 },
		accent = { 0.92, 0.76, 0.24 },
		-- Vaultloom's header is warm stone, not a translucent yellow wash.
		header = { 0.12, 0.085, 0.060, 0.78 },
		row = { 0.235, 0.160, 0.060, 0.20 },
		text = { 0.93, 0.89, 0.77 },
		muted = { 0.60, 0.57, 0.52 },
		info = { 0.39, 0.84, 1.00 },
		danger = { 1.00, 0.36, 0.32 },
	},
	blizzard = {
		bg = { 0.05, 0.05, 0.08, 0.92 },
		border = { 0.85, 0.65, 0.2, 1 },
		accent = { 1, 0.82, 0.2 },
		header = { 0.85, 0.65, 0.2, 0.15 },
		row = { 1, 1, 1, 0.03 },
		text = { 1.00, 1.00, 1.00 },
		muted = { 0.62, 0.62, 0.66 },
		info = { 0.36, 0.76, 1.00 },
		danger = { 1.00, 0.32, 0.28 },
	},
	elvui = {
		-- flat near-black with a hairline border is the ElvUI signature
		bg = { 0.06, 0.06, 0.06, 0.92 },
		border = { 0, 0, 0, 1 },
		accent = { 0.09, 0.51, 0.82 },   -- ElvUI's default blue
		header = { 0.09, 0.51, 0.82, 0.12 },
		row = { 1, 1, 1, 0.02 },
		text = { 0.90, 0.90, 0.90 },
		muted = { 0.62, 0.62, 0.62 },
		info = { 0.25, 0.67, 0.96 },
		danger = { 1.00, 0.30, 0.30 },
	},
}

function T.Colors()
	return PALETTE[T.Active()] or PALETTE.blizzard
end

function T.Accent()
	local c = T.Colors().accent
	return c[1], c[2], c[3]
end

function T.Color(role)
	local c = T.Colors()
	return c[role] or c.text or { 1, 1, 1 }
end

-- Theme changes must round-trip, including the part most skinning libraries
-- forget: a button's label. Modern deliberately warms button text and ElvUI
-- may recolour it again; without remembering the original, returning to
-- Blizzard leaves beige or blue labels inside otherwise stock controls.
local function controlFont(frame)
	return frame and frame.GetFontString and frame:GetFontString()
end

local function rememberControlFont(frame)
	if frame.mmOriginalFontColor then return end
	local fs = controlFont(frame)
	if not (fs and fs.GetTextColor) then return end
	local ok, r, g, b, a = pcall(fs.GetTextColor, fs)
	if ok then frame.mmOriginalFontColor = { r, g, b, a or 1 } end
end

local function restoreControlFont(frame)
	local fs, color = controlFont(frame), frame.mmOriginalFontColor
	if fs and color and fs.SetTextColor then
		pcall(fs.SetTextColor, fs, color[1], color[2], color[3], color[4])
	end
end

------------------------------------------------------------
-- Skinning
------------------------------------------------------------
local restoreArt, hideModern, restoreStatusTexture -- forward declarations
local function skinBlizzard(frame, kind)
	-- undo anything the flat skin added, so switching back is complete
	if hideModern then hideModern(frame) end
	if kind == "statusbar" and restoreStatusTexture then restoreStatusTexture(frame) end
	if frame.mmBackground then frame.mmBackground:SetAlpha(0) end
	if frame.mmBorder then
		for _, t in pairs(frame.mmBorder) do t:SetAlpha(0) end
	end
	if frame.mmCloseX then frame.mmCloseX:SetAlpha(0) end
	if restoreArt then restoreArt(frame) end
	restoreControlFont(frame)
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
local MODERN = MM.MEDIA .. "Modern\\"
local MODERN_ASSET = {
	window = MODERN .. "surface_window_v2.tga",
	panel = MODERN .. "surface_panel_v2.tga",
	inset = MODERN .. "surface_inset_v2.tga",
	content = MODERN .. "surface_content_v2.tga",
	sidebar = MODERN .. "surface_sidebar_v2.tga",
	utility = MODERN .. "surface_utility_v2.tga",
	card = MODERN .. "surface_card_v2.tga",
	cardInset = MODERN .. "surface_card_inset_v2.tga",
	row = MODERN .. "surface_row_v2.tga",
	title = MODERN .. "title_bar_stone.tga",
	titleClose = MODERN .. "title_close_button.tga",
	roundedBorder = MODERN .. "rounded_color_border.tga",
	roundedMask = MODERN .. "rounded_icon_mask.tga",
	button = MODERN .. "button_reskin_normal.tga",
	buttonHover = MODERN .. "button_reskin_hover.tga",
	buttonPressed = MODERN .. "button_reskin_pressed.tga",
	tab = MODERN .. "tab_reskin_normal.tga",
	tabHover = MODERN .. "tab_reskin_hover.tga",
	tabActive = MODERN .. "tab_reskin_active.tga",
	scrollTrack = MODERN .. "scroll_track_reskin.tga",
	scrollThumb = MODERN .. "scroll_thumb_reskin.tga",
	barBackground = MODERN .. "bar_bg_reskin.tga",
	barFill = MODERN .. "bar_fill_reskin.tga",
	barOverlay = MODERN .. "bar_overlay_reskin.tga",
	barSpark = MODERN .. "bar_spark_reskin.tga",
}

for _, state in ipairs({ "normal", "hover", "pressed", "disabled" }) do
	MODERN_ASSET["button_" .. state] = {
		left = MODERN .. "button_warm_frame_" .. state .. "_left.tga",
		middle = MODERN .. "button_warm_frame_" .. state .. "_middle.tga",
		middleLong = MODERN .. "button_warm_frame_" .. state .. "_middle_long.tga",
		right = MODERN .. "button_warm_frame_" .. state .. "_right.tga",
	}
end
local flatSkin  -- forward declaration; skinElv falls through to it

hideModern = function(frame)
	if frame.mmModernBackground then frame.mmModernBackground:SetAlpha(0) end
	if frame.mmModernTitle then frame.mmModernTitle:SetAlpha(0) end
	if frame.mmModernTitleShade then frame.mmModernTitleShade:SetAlpha(0) end
	if frame.mmModernTitleRules then
		for _, rule in pairs(frame.mmModernTitleRules) do rule:SetAlpha(0) end
	end
	if frame.mmModernLogo then frame.mmModernLogo:SetAlpha(0) end
	if frame.mmModernLogoRing then frame.mmModernLogoRing:SetAlpha(0) end
	if frame.mmModernTitleText then frame.mmModernTitleText:SetAlpha(0) end
	if frame.mmModernClose then frame.mmModernClose:Hide() end
	if frame.mmNativeClose then
		frame.mmNativeClose:SetAlpha(1)
		frame.mmNativeClose:Show()
	end
	if frame.mmModernButtonParts then
		for _, part in pairs(frame.mmModernButtonParts) do part:SetAlpha(0) end
	end
	if frame.mmModernBarBackground then frame.mmModernBarBackground:SetAlpha(0) end
	if frame.mmModernBarOverlay then frame.mmModernBarOverlay:SetAlpha(0) end
	-- Modern substitutes a smaller title label. Restore the template title when
	-- leaving it; texture restoration alone cannot revive a FontString alpha.
	local title = frame.TitleText
		or (frame.TitleContainer and frame.TitleContainer.TitleText)
	if title and title.SetAlpha then title:SetAlpha(1) end
end

local function modernBackground(frame, path)
	if not frame.mmModernBackground then
		local t = frame:CreateTexture(nil, "BACKGROUND")
		t:SetAllPoints()
		frame.mmModernBackground = t
	end
	frame.mmModernBackground:SetTexture(path)
	frame.mmModernBackground:SetVertexColor(1, 1, 1, 1)
	frame.mmModernBackground:SetAlpha(1)
end

local function modernTitle(frame)
	if not frame.mmModernTitle then
		local t = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
		t:SetPoint("TOPLEFT", 1, -1)
		t:SetPoint("TOPRIGHT", -1, -1)
		t:SetHeight(22)
		frame.mmModernTitle = t

		local shade = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
		shade:SetAllPoints(t)
		shade:SetColorTexture(0.015, 0.010, 0.008, 0.34)
		frame.mmModernTitleShade = shade

		local top = frame:CreateTexture(nil, "BORDER", nil, 5)
		top:SetPoint("TOPLEFT", t, "TOPLEFT", 0, -1)
		top:SetPoint("TOPRIGHT", t, "TOPRIGHT", 0, -1)
		top:SetHeight(1)
		top:SetColorTexture(0.72, 0.58, 0.30, 0.52)
		local bottom = frame:CreateTexture(nil, "BORDER", nil, 5)
		bottom:SetPoint("BOTTOMLEFT", t, "BOTTOMLEFT", 0, 1)
		bottom:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", 0, 1)
		bottom:SetHeight(1)
		bottom:SetColorTexture(0.045, 0.030, 0.020, 0.90)
		frame.mmModernTitleRules = { top = top, bottom = bottom }
	end
	frame.mmModernTitle:SetTexture(MODERN_ASSET.title)
	frame.mmModernTitle:SetVertexColor(0.82, 0.79, 0.73, 0.84)
	frame.mmModernTitle:SetAlpha(1)
	frame.mmModernTitleShade:SetAlpha(1)
	for _, rule in pairs(frame.mmModernTitleRules) do rule:SetAlpha(1) end
end

-- Current Vaultloom buttons are three-piece warm frames. Stretching the old
-- one-piece texture across a 200px control flattened its end caps and made our
-- buttons look like bordered rectangles; preserve the caps and stretch only
-- the middle, exactly as the source addon does.
local function modernButtonParts(frame, state)
	local set = MODERN_ASSET["button_" .. state] or MODERN_ASSET.button_normal
	if not frame.mmModernButtonParts then
		local left = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
		local middle = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
		local right = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
		left:SetWidth(10)
		right:SetWidth(10)
		left:SetPoint("TOPLEFT", -1, 4)
		left:SetPoint("BOTTOMLEFT", -1, -4)
		right:SetPoint("TOPRIGHT", 1, 4)
		right:SetPoint("BOTTOMRIGHT", 1, -4)
		middle:SetPoint("TOPLEFT", left, "TOPRIGHT")
		middle:SetPoint("BOTTOMRIGHT", right, "BOTTOMLEFT")
		frame.mmModernButtonParts = { left = left, middle = middle, right = right }
	end
	local p = frame.mmModernButtonParts
	p.left:SetTexture(set.left)
	p.middle:SetTexture((frame.GetWidth and frame:GetWidth() or 0) >= 96
		and set.middleLong or set.middle)
	p.right:SetTexture(set.right)
	for _, part in pairs(p) do part:SetAlpha(1) end
	if frame.mmModernBackground then frame.mmModernBackground:SetAlpha(0) end
end

local function borderAlpha(frame, alpha)
	if not frame.mmBorder then return end
	for _, edge in pairs(frame.mmBorder) do edge:SetAlpha(alpha) end
end

local function skinModernBar(frame, c)
	if frame.GetStatusBarTexture and not frame.mmOriginalStatusTexture then
		local texture = frame:GetStatusBarTexture()
		if texture and texture.GetTexture then
			local ok, path = pcall(texture.GetTexture, texture)
			if ok then frame.mmOriginalStatusTexture = path end
		end
	end
	if frame.SetStatusBarTexture then
		pcall(frame.SetStatusBarTexture, frame, MODERN_ASSET.barFill)
	end
	if not frame.mmModernBarBackground then
		local bg = frame:CreateTexture(nil, "BACKGROUND")
		bg:SetAllPoints()
		frame.mmModernBarBackground = bg
	end
	frame.mmModernBarBackground:SetTexture(MODERN_ASSET.barBackground)
	frame.mmModernBarBackground:SetVertexColor(1, 1, 1, 0.96)
	frame.mmModernBarBackground:SetAlpha(1)
	if not frame.mmModernBarOverlay then
		local overlay = frame:CreateTexture(nil, "OVERLAY", nil, 1)
		overlay:SetAllPoints()
		frame.mmModernBarOverlay = overlay
	end
	frame.mmModernBarOverlay:SetTexture(MODERN_ASSET.barOverlay)
	frame.mmModernBarOverlay:SetVertexColor(1, 1, 1, 0.88)
	frame.mmModernBarOverlay:SetAlpha(1)
	if frame.mmSpark then
		if not frame.mmOriginalSparkTexture and frame.mmSpark.GetTexture then
			local ok, path = pcall(frame.mmSpark.GetTexture, frame.mmSpark)
			if ok then frame.mmOriginalSparkTexture = path end
		end
		frame.mmSpark:SetTexture(MODERN_ASSET.barSpark)
	end
end

restoreStatusTexture = function(frame)
	if frame.mmOriginalStatusTexture and frame.SetStatusBarTexture then
		pcall(frame.SetStatusBarTexture, frame, frame.mmOriginalStatusTexture)
	end
	if frame.mmModernBarOverlay then frame.mmModernBarOverlay:SetAlpha(0) end
	if frame.mmSpark and frame.mmOriginalSparkTexture then
		pcall(frame.mmSpark.SetTexture, frame.mmSpark, frame.mmOriginalSparkTexture)
	end
end

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
	hideModern(frame)
	if kind == "frame" or kind == "panel" or kind == "content"
		or kind == "sidebar" or kind == "utility" or kind == "card" then
		-- A Blizzard template frame keeps drawing its gold chrome over
		-- anything we add underneath, so it has to be hidden first.
		hideArt(frame)
		local fill = c.bg
		if kind == "sidebar" then fill = { 0.045, 0.045, 0.045, 0.96 }
		elseif kind == "utility" then fill = { 0.075, 0.075, 0.075, 0.96 }
		elseif kind == "card" then fill = { 0.085, 0.085, 0.085, 0.90 }
		elseif kind == "content" then fill = { 0.055, 0.055, 0.055, 0.96 } end
		if frame.SetBackdrop and frame.mmBackdropOwned then
			pcall(frame.SetBackdrop, frame, {
				bgFile = SOLID, edgeFile = SOLID, edgeSize = 1,
			})
			pcall(frame.SetBackdropColor, frame, unpack(fill))
			pcall(frame.SetBackdropBorderColor, frame, unpack(c.border))
		else
			flatBackground(frame, { fill[1], fill[2], fill[3], fill[4] or 0.96 })
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

	if kind == "row" then
		hideArt(frame)
		flatBackground(frame, c.row)
		flatBorder(frame, c.border[1], c.border[2], c.border[3], 0.58)
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
		if fs then fs:SetTextColor(c.text[1], c.text[2], c.text[3]) end
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
		local dimmed = c.muted or { 0.55, 0.55, 0.58 }
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
		-- Fill colour communicates data (collection progress), not chrome. The
		-- owner controls it; a theme only changes the bar's material.
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
				local danger = T.Color("danger")
				if self.mmCloseX then self.mmCloseX:SetTextColor(danger[1], danger[2], danger[3]) end
			end)
			frame:HookScript("OnLeave", function(self)
				local muted = T.Color("muted")
				if self.mmCloseX then self.mmCloseX:SetTextColor(muted[1], muted[2], muted[3]) end
			end)
		end
		local muted = c.muted or { 0.65, 0.65, 0.65 }
		frame.mmCloseX:SetTextColor(muted[1], muted[2], muted[3])
		frame.mmCloseX:SetAlpha(1)
		return
	end
end

------------------------------------------------------------
-- Modern skin.
--
-- The textures are an intentionally small, reusable subset of the authorized
-- Vaultloom artwork: neutral surfaces and control states only. All state lives
-- in textures created by us, so changing theme can hide it and restore the
-- original Blizzard/ElvUI art without requiring a reload.
------------------------------------------------------------
local function modernControlState(frame, kind, state)
	if T.Active() ~= "modern" then
		hideModern(frame)
		return
	end

	local disabled = frame.IsEnabled and not frame:IsEnabled()
	local activeTab = kind == "tab" and disabled
	local path
	if kind == "row" then
		path = MODERN_ASSET.row
	elseif kind == "tab" then
		path = activeTab and MODERN_ASSET.tabActive
			or (state == "hover" and MODERN_ASSET.tabHover or MODERN_ASSET.tab)
	else
		modernButtonParts(frame, disabled and "disabled" or state)
	end
	if path then
		modernBackground(frame, path)
		frame.mmModernBackground:SetAlpha(disabled and not activeTab and 0.55 or 1)
		if kind == "row" then
			local warm = state == "pressed" and { 0.78, 0.66, 0.46 }
				or state == "hover" and { 1.00, 0.91, 0.72 }
				or { 1, 1, 1 }
			frame.mmModernBackground:SetVertexColor(warm[1], warm[2], warm[3], 1)
		end
	end

	local c = PALETTE.modern
	local fs = frame.GetFontString and frame:GetFontString()
	if fs then
		local tc = activeTab and c.accent or (disabled and c.muted or c.text)
		fs:SetTextColor(tc[1], tc[2], tc[3])
	end
end

local function hookModernControl(frame, kind)
	if frame.mmModernHooks or not frame.HookScript then return end
	frame.mmModernHooks = true
	frame:HookScript("OnEnter", function(self)
		modernControlState(self, kind, "hover")
	end)
	frame:HookScript("OnLeave", function(self)
		modernControlState(self, kind, "normal")
	end)
	frame:HookScript("OnMouseDown", function(self)
		modernControlState(self, kind, "pressed")
	end)
	frame:HookScript("OnMouseUp", function(self)
		modernControlState(self, kind, self:IsMouseOver() and "hover" or "normal")
	end)
	frame:HookScript("OnEnable", function(self)
		modernControlState(self, kind, "normal")
	end)
	frame:HookScript("OnDisable", function(self)
		modernControlState(self, kind, "normal")
	end)
end

local function skinModern(frame, kind)
	local c = PALETTE.modern
	-- A prior ElvUI fallback may have created its own solid fill. It is ours,
	-- not native art, so hide it explicitly or it sits above the textured
	-- Modern surface when switching themes live.
	if frame.mmBackground then frame.mmBackground:SetAlpha(0) end
	hideArt(frame)

	if kind == "frame" or kind == "panel" or kind == "content"
		or kind == "sidebar" or kind == "utility" or kind == "card" then
		local path = kind == "frame" and MODERN_ASSET.window
			or kind == "content" and MODERN_ASSET.content
			or kind == "sidebar" and MODERN_ASSET.sidebar
			or kind == "utility" and MODERN_ASSET.utility
			or kind == "card" and MODERN_ASSET.cardInset
			or kind == "panel" and MODERN_ASSET.panel
			or MODERN_ASSET.inset
		modernBackground(frame, path)
		-- The source plates are intentionally detailed, but the content must sit
		-- above them. A restrained material tint prevents large stretched areas
		-- from turning into visible noise while leaving controls crisp.
		if kind == "frame" then
			frame.mmModernBackground:SetVertexColor(0.76, 0.73, 0.68, 0.98)
		elseif kind == "content" or kind == "sidebar" or kind == "utility"
			or kind == "card" then
			frame.mmModernBackground:SetVertexColor(0.70, 0.68, 0.64, 0.96)
		end
		if frame.SetBackdrop and frame.mmBackdropOwned then
			pcall(frame.SetBackdrop, frame, {
				edgeFile = MODERN_ASSET.roundedBorder,
				edgeSize = (kind == "frame" or kind == "panel") and 4 or 2,
				insets = { left = 1, right = 1, top = 1, bottom = 1 },
			})
			pcall(frame.SetBackdropColor, frame, 1, 1, 1, 0)
			pcall(frame.SetBackdropBorderColor, frame,
				c.border[1], c.border[2], c.border[3], c.border[4])
			borderAlpha(frame, 0)
		else
			flatBorder(frame, c.border[1], c.border[2], c.border[3], c.border[4])
			borderAlpha(frame, kind == "card" and 0.38 or c.border[4])
		end
		if kind == "frame" then
			modernTitle(frame)
			if frame.mmModernLogo then frame.mmModernLogo:SetAlpha(1) end
			if frame.mmModernLogoRing then frame.mmModernLogoRing:SetAlpha(1) end
			if frame.mmModernTitleText then frame.mmModernTitleText:SetAlpha(1) end
			if frame.mmModernClose then frame.mmModernClose:Show() end
			if frame.mmNativeClose then frame.mmNativeClose:Hide() end
		end
		local title = frame.TitleText
			or (frame.TitleContainer and frame.TitleContainer.TitleText)
		if title and title.SetTextColor then
			-- The custom Modern label is deliberately small and centered in the
			-- thin rail; displaying the large template title as well recreates the
			-- journal silhouette we are replacing.
			title:SetAlpha(kind == "frame" and frame.mmModernTitleText and 0 or 1)
			title:SetTextColor(c.text[1], c.text[2], c.text[3])
		end
		return
	end

	if kind == "button" or kind == "tab" or kind == "row" then
		if kind == "row" then
			flatBorder(frame, c.border[1], c.border[2], c.border[3], 0.32)
			borderAlpha(frame, 0.32)
		else
			-- The shaped control artwork already contains its own frame.
			-- A second rectangular edge is what made every control shout gold.
			borderAlpha(frame, 0)
		end
		hookModernControl(frame, kind)
		modernControlState(frame, kind, "normal")
		return
	end

	if kind == "checkbox" or kind == "editbox" then
		modernBackground(frame, MODERN_ASSET.inset)
		flatBorder(frame, c.border[1], c.border[2], c.border[3], 1)
		local checked = frame.GetCheckedTexture and frame:GetCheckedTexture()
		if checked then
			checked:SetAlpha(1)
			checked:SetVertexColor(c.accent[1], c.accent[2], c.accent[3], 1)
		end
		return
	end

	if kind == "scrollbar" then
		modernBackground(frame, MODERN_ASSET.scrollTrack)
		flatBorder(frame, c.border[1], c.border[2], c.border[3], 0.35)
		borderAlpha(frame, 0.35)
		local thumb = frame.GetThumbTexture and frame:GetThumbTexture()
		if thumb and thumb.SetTexture then thumb:SetTexture(MODERN_ASSET.scrollThumb) end
		return
	end

	if kind == "statusbar" then
		skinModernBar(frame, c)
		return
	end

	-- Glyph, close and status-bar handling is already reversible and only needs
	-- the Modern palette. Reuse it instead of duplicating those careful paths.
	flatSkin(frame, kind, c)
	if kind == "close" and frame.mmBorder then
		flatBorder(frame, c.border[1], c.border[2], c.border[3], 1)
	end
end

local function skinElv(frame, kind)
	hideModern(frame)
	if kind == "statusbar" and restoreStatusTexture then restoreStatusTexture(frame) end
	if frame.mmBackground then frame.mmBackground:SetAlpha(0) end
	if frame.mmBorder then
		for _, edge in pairs(frame.mmBorder) do edge:SetAlpha(0) end
	end
	if restoreArt then restoreArt(frame) end
	local S = elvSkins()
	local c = PALETTE.elvui

	-- Prefer ElvUI's own handlers: they match the player's exact settings.
	if S then
		local handler =
			(kind == "button" and S.HandleButton)
			or (kind == "row" and S.HandleButton)
			or (kind == "tab" and S.HandleTab)
			or (kind == "close" and S.HandleCloseButton)
			or (kind == "checkbox" and S.HandleCheckBox)
			or (kind == "editbox" and S.HandleEditBox)
			or (kind == "scrollbar" and S.HandleScrollBar)
			or ((kind == "frame" or kind == "panel" or kind == "content"
				or kind == "sidebar" or kind == "utility" or kind == "card")
				and S.HandleFrame)
		if handler then
			local ok = pcall(handler, S, frame)
			if ok then return end
		end
	end

	local fallback = (kind == "tab" or kind == "row") and "button" or kind
	if kind == "content" or kind == "sidebar" or kind == "utility" or kind == "card" then
		fallback = "panel"
	end
	flatSkin(frame, fallback, c)
end

-- Apply the active theme to one frame.
function T.Skin(frame, kind)
	if not frame then return end
	local active = T.Active()
	if active == "modern" then
		skinModern(frame, kind)
	elseif active == "elvui" then
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

-- Typography is part of the hierarchy too. `GameFontNormal` is bright yellow,
-- which is useful for one Blizzard heading but overwhelming when every mount
-- name inherits it. Register the semantic role once and let each theme choose
-- the colour without changing the font, size, copy, or layout.
local function skinText(fontString, spec)
	if not (fontString and fontString.SetTextColor and spec) then return end
	local active = T.Active()
	local c = PALETTE[active] or PALETTE.blizzard
	local color
	if active == "modern" then
		color = spec.role == "accent" and c.accent
			or spec.role == "muted" and c.muted
			or spec.role == "info" and { 0.39, 0.84, 1.00 }
			or c.text
	elseif active == "elvui" then
		color = spec.role == "accent" and c.accent
			or spec.role == "muted" and { 0.62, 0.62, 0.62 }
			or spec.role == "info" and c.accent
			or { 0.90, 0.90, 0.90 }
	else
		color = spec.original
	end
	if color then fontString:SetTextColor(color[1], color[2], color[3], color[4] or 1) end
end

function T.RegisterText(fontString, role)
	if not fontString then return fontString end
	local spec = textRegistry[fontString]
	if not spec then
		local original = { 1, 1, 1, 1 }
		if fontString.GetTextColor then
			local ok, r, g, b, a = pcall(fontString.GetTextColor, fontString)
			if ok then original = { r, g, b, a or 1 } end
		end
		spec = { original = original }
		textRegistry[fontString] = spec
	end
	spec.role = role or "primary"
	skinText(fontString, spec)
	return fontString
end

local function skinSurface(texture, role)
	if not texture then return end
	local active = T.Active()
	if active == "modern" then
		local path = role == "sidebar" and MODERN_ASSET.sidebar
			or role == "utility" and MODERN_ASSET.utility
			or role == "card" and MODERN_ASSET.cardInset
			or MODERN_ASSET.content
		texture:SetTexture(path)
		if role == "utility" then
			texture:SetVertexColor(0.78, 0.74, 0.68, 0.96)
		elseif role == "card" then
			texture:SetVertexColor(0.74, 0.71, 0.66, 0.96)
		else
			texture:SetVertexColor(0.70, 0.68, 0.64, 0.96)
		end
	elseif active == "elvui" then
		texture:SetColorTexture(0.055, 0.055, 0.055, role == "card" and 0.82 or 0.94)
	else
		-- Blizzard keeps its ornate outer frame, but a quiet pane tint still
		-- distinguishes navigation/list/detail regions instead of one black void.
		local warm = role == "sidebar" and { 0.055, 0.045, 0.035, 0.62 }
			or { 0.035, 0.035, 0.050, 0.52 }
		texture:SetColorTexture(warm[1], warm[2], warm[3], warm[4])
	end
	texture:SetAlpha(1)
end

function T.RegisterSurface(texture, role)
	if not texture then return texture end
	surfaceRegistry[texture] = role or "content"
	skinSurface(texture, role or "content")
	return texture
end

-- Hairline rules carry hierarchy without turning every region into a heavy
-- box. They are semantic so the shared layout can use warm gold in Modern,
-- Blizzard gold in the stock look, and the configured ElvUI accent.
local function skinRule(texture, strength)
	if not texture then return end
	local active = T.Active()
	local c = PALETTE[active] or PALETTE.blizzard
	local alpha = strength == "strong" and 0.78 or 0.38
	texture:SetColorTexture(c.border[1], c.border[2], c.border[3], alpha)
	texture:SetAlpha(1)
end

function T.RegisterRule(texture, strength)
	if not texture then return texture end
	ruleRegistry[texture] = strength or "subtle"
	skinRule(texture, strength or "subtle")
	return texture
end

-- Frame any semantic surface with the same four hairlines. Keeping the
-- geometry here makes pane hierarchy a theme primitive instead of copied
-- coordinates in every screen.
function T.BorderSurface(parent, surface, strength)
	if not (parent and surface) then return {} end
	local edges = {}
	local definitions = {
		{ "TOPLEFT", "TOPRIGHT", "height" },
		{ "BOTTOMLEFT", "BOTTOMRIGHT", "height" },
		{ "TOPLEFT", "BOTTOMLEFT", "width" },
		{ "TOPRIGHT", "BOTTOMRIGHT", "width" },
	}
	for _, definition in ipairs(definitions) do
		local edge = parent:CreateTexture(nil, "ARTWORK")
		edge:SetPoint(definition[1], surface, definition[1])
		edge:SetPoint(definition[2], surface, definition[2])
		if definition[3] == "height" then edge:SetHeight(1) else edge:SetWidth(1) end
		T.RegisterRule(edge, strength or "subtle")
		edges[#edges + 1] = edge
	end
	return edges
end

-- Vaultloom's compact rounded icon silhouette is one of the details that
-- makes its rows feel designed rather than assembled from stock widgets.
-- Masks are content geometry, so keeping them across themes improves all
-- three looks without interfering with Blizzard or ElvUI chrome.
function T.RoundIcon(owner, texture)
	if not (owner and texture and owner.CreateMaskTexture and texture.AddMaskTexture) then
		return texture
	end
	if texture.mmRoundedMask then return texture end
	local mask = owner:CreateMaskTexture(nil, "ARTWORK")
	mask:SetTexture(MODERN_ASSET.roundedMask,
		"CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	mask:SetAllPoints(texture)
	texture:AddMaskTexture(mask)
	texture.mmRoundedMask = mask
	return texture
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
	-- Scroll-box element buttons do not expose a single GetFontString; their
	-- labels are regions. Treating those wide, shallow rows as ACTION buttons
	-- stretched button chrome across the entire list and produced the repeated
	-- heavy gold boxes seen in the Modern screenshot.
	if (not text or text == "") and h and h > 24 and h <= 60 and child.GetRegions then
		local okRegions, regions = pcall(function() return { child:GetRegions() } end)
		if okRegions then
			for _, region in ipairs(regions) do
				if region and region.GetObjectType and region:GetObjectType() == "FontString" then
					return "row"
				end
			end
		end
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
	for fontString, spec in pairs(textRegistry) do skinText(fontString, spec) end
	for texture, role in pairs(surfaceRegistry) do skinSurface(texture, role) end
	for texture, strength in pairs(ruleRegistry) do skinRule(texture, strength) end
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
	if name == "auto" then name = nil end
	if name ~= nil and name ~= "modern" and name ~= "blizzard" and name ~= "elvui" then
		MM:Print("Unknown theme '%s'. Use auto, modern, blizzard, or elvui.", tostring(name))
		return false
	end
	MM.db.theme = name
	T.ReskinAll()
	local label = name or ("auto (" .. T.Auto() .. ")")
	MM:Print("Theme set to %s.", label)
	return true
end

------------------------------------------------------------
-- Wiring
------------------------------------------------------------
MM:On("MM_LOGIN", function()
	-- Not once per login. The theme is visible the moment a window opens; the
	-- only thing chat adds is where to change it. This text never varies, so
	-- PrintIfNew's time window is what governs it -- said once, and again only
	-- if a month of not seeing it has gone by.
	if MM.db.theme == nil and T.HasElvUI() then
		MM:PrintIfNew("elvui", "ElvUI detected — using the ElvUI theme. Change it in Options.")
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
