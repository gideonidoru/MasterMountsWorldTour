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

local function readRGB(value, fallback)
	if type(value) ~= "table" then return fallback end
	local r, g, b = value.r or value[1], value.g or value[2], value.b or value[3]
	if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
		return fallback
	end
	return { r, g, b }
end

function T.Colors()
	local active = T.Active()
	local base = PALETTE[active] or PALETTE.blizzard
	if active ~= "elvui" then return base end

	-- Match the player's profile, not a screenshot of ElvUI's default profile.
	-- ElvUI has moved these tables over time, so every lookup is optional and the
	-- self-contained fallback palette remains complete when an internal moves.
	local _, E = elvSkins()
	if not E then return base end
	local general = E.db and E.db.general or {}
	local media = E.media or {}
	local accent = readRGB(general.valuecolor or media.rgbvaluecolor, base.accent)
	local border = readRGB(general.bordercolor or media.bordercolor, base.border)
	local bg = readRGB(general.backdropcolor or media.backdropcolor, base.bg)
	return {
		bg = { bg[1], bg[2], bg[3], base.bg[4] },
		border = { border[1], border[2], border[3], base.border[4] },
		accent = accent,
		header = { accent[1], accent[2], accent[3], base.header[4] },
		row = base.row,
		text = base.text,
		muted = base.muted,
		info = accent,
		danger = base.danger,
	}
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
	if not frame then return nil end
	local fs = frame.GetFontString and frame:GetFontString()
	if fs then return fs end
	for _, key in ipairs({ "Text", "Label", "DefaultText" }) do
		local candidate = frame[key]
		if type(candidate) == "table" and candidate.SetTextColor then return candidate end
	end
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
-- `hideArt` belongs here too. It is defined far below but the Blizzard button
-- branch calls it, and without the forward declaration that name resolved to a
-- global -- nil at runtime, so skinning a button under the Blizzard theme threw
-- rather than skinned. Every other call site sits after the definition, which
-- is why only one branch was affected and why the modern theme never showed it.
local restoreArt, hideModern, restoreStatusTexture, restoreModernControls, hideArt -- forward declarations
local flatBackground, flatBorder -- used by the Blizzard normalization path
local function skinBlizzard(frame, kind)
	-- undo anything the flat skin added, so switching back is complete
	if hideModern then hideModern(frame) end
	if kind == "statusbar" and restoreStatusTexture then restoreStatusTexture(frame) end
	if restoreModernControls then restoreModernControls(frame, kind) end
	if frame.mmFlatTabIndicator then frame.mmFlatTabIndicator:SetAlpha(0) end
	if frame.mmFlatCheckboxBox then frame.mmFlatCheckboxBox:SetAlpha(0) end
	if frame.mmBackground then frame.mmBackground:SetAlpha(0) end
	if frame.mmBorder then
		for _, t in pairs(frame.mmBorder) do t:SetAlpha(0) end
	end
	if frame.mmCloseX then frame.mmCloseX:SetAlpha(0) end
	if restoreArt then restoreArt(frame) end
	restoreControlFont(frame)
	-- restore native close geometry (its art needs the padded anchor)
	local g = frame.mmCloseGeom
	if g and g.p then
		frame:SetSize(g.w, g.h)
		frame:ClearAllPoints()
		frame:SetPoint(g.p, g.rel, g.relP, g.x, g.y)
	end

	-- The columns, wells and cards are frames the addon creates itself. They
	-- carry no template art, so a theme that does not name them leaves them
	-- drawing nothing at all -- which is what the Blizzard look did for nine
	-- of the thirteen kinds the interface registers. Native controls (tabs,
	-- checkboxes, edit boxes, scroll bars, status bars) are a different case
	-- and are deliberately left to their own art: keeping it IS this theme.
	--
	-- Depth is carried the way the stock UI carries it, by how much light a
	-- surface holds against the same tooltip backdrop, so the ladder stays
	-- recognisably Blizzard rather than becoming a second flat skin.
	local SHADE = {
		frame = 1.00, panel = 1.00,
		content = 0.95,   -- the centre column, the reference surface
		sidebar = 0.82,   -- flanking columns sit back from it
		utility = 1.22,   -- an action rail sits forward
		card    = 1.35,   -- and a card forward of that
		inset   = 0.62,   -- a well reads as cut INTO whatever holds it
	}
	if SHADE[kind or ""] then
		local c = PALETTE.blizzard
		local shade = SHADE[kind]
		local bg = { math.min(1, c.bg[1] * shade), math.min(1, c.bg[2] * shade),
			math.min(1, c.bg[3] * shade), c.bg[4] }
		if frame.SetBackdrop and frame.mmBackdropOwned then
			frame:SetBackdrop({
				bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
				tile = true, tileSize = 16, edgeSize = 14,
				insets = { left = 4, right = 4, top = 4, bottom = 4 },
			})
			frame:SetBackdropColor(unpack(bg))
			-- Gold at full strength belongs to the window. Interior edges take
			-- a quieter share of it, or every pane competes with the frame.
			local edge = (kind == "frame" or kind == "panel") and c.border[4]
				or (kind == "card" and 0.42 or 0.30)
			frame:SetBackdropBorderColor(c.border[1], c.border[2], c.border[3], edge)
		else
			flatBackground(frame, bg)
			flatBorder(frame, c.border[1], c.border[2], c.border[3], 0.30)
		end
	elseif kind == "row" then
		-- Rows are read as a column of text, not as a stack of containers. The
		-- palette states the banding strength in its own alpha; a border here
		-- would draw a grid over the one thing that must stay scannable.
		local c = PALETTE.blizzard
		flatBackground(frame, c.row)
	elseif kind == "button" then
		-- Retail's current generic button template is saturated red. That is a
		-- useful danger colour, but it made every harmless planner command read
		-- like a destructive action. Blizzard keeps its gold/black vocabulary
		-- while neutral actions receive a quiet, native-feeling chassis.
		hideArt(frame)
		local c = PALETTE.blizzard
		local danger = frame.mmIntent == "danger"
		local fill = danger and { 0.28, 0.035, 0.025, 0.96 }
			or { 0.075, 0.060, 0.045, 0.96 }
		flatBackground(frame, fill)
		flatBorder(frame, c.border[1], c.border[2], c.border[3], danger and 0.92 or 0.58)
		local fs = controlFont(frame)
		if fs then
			local tc = danger and c.danger or c.text
			fs:SetTextColor(tc[1], tc[2], tc[3])
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
	arrowUp = MODERN .. "arrow_up_small.tga",
	arrowDown = MODERN .. "arrow_down_small.tga",
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
	if frame.mmModernCheckboxBox then frame.mmModernCheckboxBox:SetAlpha(0) end
	if frame.mmModernSliderTrack then frame.mmModernSliderTrack:SetAlpha(0) end
	if frame.mmModernSliderFill then frame.mmModernSliderFill:SetAlpha(0) end
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

local function rememberStatusTexture(frame)
	if frame.GetStatusBarTexture and not frame.mmOriginalStatusTexture then
		local texture = frame:GetStatusBarTexture()
		if texture and texture.GetTexture then
			local ok, path = pcall(texture.GetTexture, texture)
			if ok then frame.mmOriginalStatusTexture = path end
		end
	end
end

local function skinModernBar(frame, c)
	rememberStatusTexture(frame)
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
		-- The sheen belongs to the completed portion, not the entire track.
		-- ARTWORK keeps it below the OVERLAY-layer label and edge spark.
		local overlay = frame:CreateTexture(nil, "ARTWORK")
		frame.mmModernBarOverlay = overlay
	end
	local fill = frame.GetStatusBarTexture and frame:GetStatusBarTexture()
	frame.mmModernBarOverlay:ClearAllPoints()
	if fill then
		frame.mmModernBarOverlay:SetPoint("TOPLEFT", fill, "TOPLEFT")
		frame.mmModernBarOverlay:SetPoint("BOTTOMRIGHT", fill, "BOTTOMRIGHT")
	else
		frame.mmModernBarOverlay:SetAllPoints(frame)
	end
	if frame.mmModernBarOverlay.SetDrawLayer then
		frame.mmModernBarOverlay:SetDrawLayer("ARTWORK", 0)
	end
	frame.mmModernBarOverlay:SetTexture(MODERN_ASSET.barOverlay)
	-- The source image is almost opaque, so normal blending turns it into a white
	-- slab. Add only a trace of light; the status colour remains the information.
	frame.mmModernBarOverlay:SetBlendMode("ADD")
	frame.mmModernBarOverlay:SetVertexColor(1, 1, 1, 1)
	frame.mmModernBarOverlay:SetAlpha(0.035)
	frame.mmModernBarOverlay:Show()
	if frame.mmSpark then
		if not frame.mmOriginalSpark then
			local r, g, b, a = frame.mmSpark:GetVertexColor()
			frame.mmOriginalSpark = {
				texture = frame.mmSpark.GetTexture and frame.mmSpark:GetTexture(),
				width = frame.mmSpark:GetWidth(), height = frame.mmSpark:GetHeight(),
				alpha = frame.mmSpark:GetAlpha(),
				shown = frame.mmSpark:IsShown(),
				blend = frame.mmSpark.GetBlendMode and frame.mmSpark:GetBlendMode(),
				vertex = { r, g, b, a or 1 },
			}
		end
		frame.mmSpark:SetTexture(MODERN_ASSET.barSpark)
		frame.mmSpark:SetSize(6, math.max(12, frame:GetHeight()))
		frame.mmSpark:SetBlendMode("ADD")
		frame.mmSpark:SetVertexColor(1, 0.83, 0.38, 1)
		frame.mmSpark:SetAlpha(0.16)
	end
end

restoreStatusTexture = function(frame)
	if frame.mmOriginalStatusTexture and frame.SetStatusBarTexture then
		pcall(frame.SetStatusBarTexture, frame, frame.mmOriginalStatusTexture)
	end
	if frame.mmModernBarOverlay then frame.mmModernBarOverlay:SetAlpha(0) end
	local spark = frame.mmSpark and frame.mmOriginalSpark
	if spark then
		if spark.texture then pcall(frame.mmSpark.SetTexture, frame.mmSpark, spark.texture) end
		frame.mmSpark:SetSize(spark.width or 8, spark.height or 16)
		frame.mmSpark:SetAlpha(spark.alpha or 1)
		frame.mmSpark:SetShown(spark.shown ~= false)
		local vertex = spark.vertex or { 1, 1, 1, 1 }
		frame.mmSpark:SetVertexColor(vertex[1], vertex[2], vertex[3], vertex[4])
		if spark.blend then frame.mmSpark:SetBlendMode(spark.blend) end
	end
end

-- Draw a 1px border out of four thin textures (cheap, no edge file, and it
-- stays exactly 1px at any frame size unlike a scaled edgeFile).
flatBorder = function(frame, r, g, b, a)
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

flatBackground = function(frame, c)
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
	--
	-- A container may hold its border in a NESTED frame rather than in its own
	-- regions. BasicFrameTemplateWithInset builds its sunken inset that way:
	-- the corner and edge pieces belong to frame.Inset's own nine-slice, so a
	-- walk that stopped at the outer level took the inset's backing texture and
	-- left its border standing — a grey metal rectangle up both sides and
	-- across the bottom of the window, behind the panes, surviving every theme
	-- change because nothing had ever collected it.
	--
	-- Descend one level into each container's child frames instead of naming
	-- the nested key, so this holds for whichever template a window inherits.
	-- Frames of ours are skipped; the containers themselves are never hidden,
	-- only the textures within them, which is what keeps the title readable.
	--
	-- Append one at a time. A table constructor holding absent keys is a list
	-- with holes, and ipairs halts at the first one -- so listing these inline
	-- meant a window without a PortraitContainer stopped being walked at the
	-- second slot, and its TitleContainer and Inset were never examined.
	local containers = {}
	local function consider(container)
		if type(container) ~= "table" then return end
		containers[#containers + 1] = container
		if container.GetChildren and not ours(container) then
			local ok, kids = pcall(function() return { container:GetChildren() } end)
			if ok then
				for _, kid in ipairs(kids) do
					-- Descend into plain Frames ONLY. A Button's textures are
					-- its control surface, not window chrome: hiding them
					-- leaves a live but invisible control. The close button is
					-- reachable this way, and blanking it cost ElvUI its X --
					-- invisible there alone, because Blizzard restores template
					-- art rather than hiding it and Modern draws its own close.
					local kind = type(kid) == "table" and kid.GetObjectType
						and select(2, pcall(kid.GetObjectType, kid))
					if kind == "Frame" and not ours(kid) then
						containers[#containers + 1] = kid
					end
				end
			end
		end
	end
	consider(frame.NineSlice)
	consider(frame.PortraitContainer)
	consider(frame.TitleContainer)
	consider(frame.Inset)
	for _, container in ipairs(containers) do
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

function hideArt(frame)
	local keep = frame.GetCheckedTexture and select(2, pcall(frame.GetCheckedTexture, frame))
	for _, t in ipairs(templateRegions(frame)) do
		if t ~= keep then
			frame.mmOriginalArt = frame.mmOriginalArt or setmetatable({}, { __mode = "k" })
			if not frame.mmOriginalArt[t] then
				local ok, alpha = pcall(t.GetAlpha, t)
				frame.mmOriginalArt[t] = ok and alpha or 1
			end
			pcall(t.SetAlpha, t, 0)
		end
	end
end

function restoreArt(frame)
	for _, t in ipairs(templateRegions(frame)) do
		local original = frame.mmOriginalArt and frame.mmOriginalArt[t]
		pcall(t.SetAlpha, t, original ~= nil and original or 1)
	end
end

-- Test seams. Whether a window's native chrome is fully collected is a runtime
-- property of whatever template it inherits, so the release gate exercises
-- these directly rather than trusting a reading of the template.
T.HideTemplateArt = hideArt
T.RestoreTemplateArt = restoreArt

-- Any Modern control that borrows a native texture records it first. Theme
-- switching then restores the exact path and geometry instead of relying on a
-- reload to repair a slider thumb or scrollbar arrow.
-- Record a texture's original appearance and CHANGE NOTHING.
--
-- Callers that only mean to recolour art must use this. modernTexture ends by
-- applying `path`, and handing it a texture's own GetTexture() reads like a
-- no-op -- it is one for a file-backed texture. It is not one for an
-- atlas-backed texture: GetTexture on an atlas returns the whole SHEET, and
-- setting that discards the atlas coordinates, so every icon in the file draws
-- at once. Blizzard's close button is atlas-backed and the sweep classifies it
-- as a glyph, so it came out as a grid of X glyphs -- under ElvUI alone, that
-- being the only theme which shows the native button rather than hiding it.
local function rememberTexture(frame, texture)
	if not (frame and texture and texture.GetTexture and texture.SetTexture) then return end
	frame.mmModernTextureRestore = frame.mmModernTextureRestore or {}
	if not frame.mmModernTextureRestore[texture] then
		local r, g, b, a = texture:GetVertexColor()
		local texcoord = texture.GetTexCoord and { texture:GetTexCoord() } or nil
		frame.mmModernTextureRestore[texture] = {
			atlas = texture.GetAtlas and texture:GetAtlas() or nil,
			path = texture:GetTexture(), texcoord = texcoord,
			width = texture:GetWidth(), height = texture:GetHeight(),
			vertex = { r, g, b, a or 1 }, alpha = texture:GetAlpha(),
			blend = texture.GetBlendMode and texture:GetBlendMode() or nil,
			desaturated = texture.IsDesaturated and texture:IsDesaturated() or false,
		}
	end
end

local function modernTexture(frame, texture, path)
	rememberTexture(frame, texture)
	if texture and texture.SetTexture then texture:SetTexture(path) end
end

restoreModernControls = function(frame)
	for texture, original in pairs(frame.mmModernTextureRestore or {}) do
		if texture and texture.SetTexture then
			if original.atlas and texture.SetAtlas then
				texture:SetAtlas(original.atlas, false)
			else
				texture:SetTexture(original.path)
			end
			if original.texcoord and texture.SetTexCoord then
				texture:SetTexCoord(unpack(original.texcoord))
			end
			if original.width and original.height then
				texture:SetSize(original.width, original.height)
			end
			local vertex = original.vertex or { 1, 1, 1, 1 }
			texture:SetVertexColor(vertex[1], vertex[2], vertex[3], vertex[4])
			texture:SetAlpha(original.alpha or 1)
			if original.blend and texture.SetBlendMode then
				texture:SetBlendMode(original.blend)
			end
			if texture.SetDesaturated then
				texture:SetDesaturated(original.desaturated and true or false)
			end
		end
	end
end

function flatSkin(frame, kind, c)
	hideModern(frame)
	if kind == "frame" or kind == "panel" or kind == "content"
		or kind == "sidebar" or kind == "utility" or kind == "card"
		or kind == "inset" then
		-- A Blizzard template frame keeps drawing its gold chrome over
		-- anything we add underneath, so it has to be hidden first.
		hideArt(frame)
		local fill = c.bg
		local shade = kind == "sidebar" and 0.82
			or kind == "utility" and 1.22
			or kind == "card" and 1.35
			or kind == "content" and 0.95
			-- Recessed: an inset well reads as cut INTO the panel holding it,
			-- so it goes darker than anything it can sit inside.
			or kind == "inset" and 0.68
		if shade then
			fill = { math.min(1, c.bg[1] * shade), math.min(1, c.bg[2] * shade),
				math.min(1, c.bg[3] * shade), kind == "card" and 0.90 or 0.96 }
		end
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
		flatBorder(frame, c.border[1], c.border[2], c.border[3], 0.24)
		return
	end

	if kind == "button" or kind == "tab" then
		hideArt(frame)
		local danger = kind == "button" and frame.mmIntent == "danger"
		flatBackground(frame, danger and { 0.24, 0.035, 0.030, 0.94 }
			or { 0.105, 0.105, 0.105, 0.96 })
		flatBorder(frame, 0, 0, 0, 0.72)
		if kind == "tab" then
			if not frame.mmFlatTabIndicator then
				local indicator = frame:CreateTexture(nil, "OVERLAY")
				indicator:SetPoint("BOTTOMLEFT", 4, 1)
				indicator:SetPoint("BOTTOMRIGHT", -4, 1)
				indicator:SetHeight(2)
				frame.mmFlatTabIndicator = indicator
			end
			local active = frame.IsEnabled and not frame:IsEnabled()
			frame.mmFlatTabIndicator:SetColorTexture(c.accent[1], c.accent[2], c.accent[3], 0.92)
			frame.mmFlatTabIndicator:SetAlpha(1)
			frame.mmFlatTabIndicator:SetShown(active and true or false)
			if active and frame.mmBackground then
				frame.mmBackground:SetColorTexture(c.accent[1] * 0.20,
					c.accent[2] * 0.20, c.accent[3] * 0.20, 0.96)
			end
			if not frame.mmFlatTabHooks then
				frame.mmFlatTabHooks = true
				frame:HookScript("OnEnable", function(self)
					if T.Active() == "elvui" then flatSkin(self, "tab", T.Colors()) end
				end)
				frame:HookScript("OnDisable", function(self)
					if T.Active() == "elvui" then flatSkin(self, "tab", T.Colors()) end
				end)
			end
		end
		-- Tint the EXISTING highlight; never swap its texture. Replacing the
		-- texture path is unrecoverable, which is what left a solid white
		-- block behind after switching back to the Blizzard theme.
		local hl = frame.GetHighlightTexture and frame:GetHighlightTexture()
		if hl and hl.SetVertexColor then
			rememberTexture(frame, hl)
			pcall(hl.SetVertexColor, hl, c.accent[1], c.accent[2], c.accent[3], 0.45)
			pcall(hl.SetAlpha, hl, 1)
		end
		local fs = controlFont(frame)
		if fs then fs:SetTextColor(c.text[1], c.text[2], c.text[3]) end
		return
	end

	if kind == "checkbox" then
		hideArt(frame)
		if frame.mmBackground then frame.mmBackground:SetAlpha(0) end
		if not frame.mmFlatCheckboxBox then
			local box = CreateFrame("Frame", nil, frame)
			box:SetSize(18, 18)
			box:SetPoint("CENTER")
			box.mmNoSkin = true
			frame.mmFlatCheckboxBox = box
			local tick = box:CreateTexture(nil, "OVERLAY")
			tick:SetSize(14, 14)
			tick:SetPoint("CENTER")
			tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
			frame.mmFlatCheck = tick
		end
		flatBackground(frame.mmFlatCheckboxBox, { 0.10, 0.10, 0.10, 0.98 })
		flatBorder(frame.mmFlatCheckboxBox, 0, 0, 0, 0.82)
		frame.mmFlatCheckboxBox:SetAlpha(1)
		-- A dedicated 14px tick keeps the mark proportional to the 18px chassis;
		-- native checkbox ticks vary by client and can fill the whole 24px target.
		local checked = frame.GetCheckedTexture and frame:GetCheckedTexture()
		if checked then
			rememberTexture(frame, checked)
			checked:SetAlpha(0)
		end
		frame.mmFlatCheck:SetVertexColor(c.accent[1], c.accent[2], c.accent[3], 1)
		frame.mmFlatCheck:SetShown(frame:GetChecked() and true or false)
		if not frame.mmFlatCheckboxHooks then
			frame.mmFlatCheckboxHooks = true
			local function update(self)
				if T.Active() == "elvui" and self.mmFlatCheck then
					self.mmFlatCheck:SetShown(self:GetChecked() and true or false)
				end
			end
			frame:HookScript("OnClick", update)
			frame:HookScript("OnShow", update)
			if hooksecurefunc then hooksecurefunc(frame, "SetChecked", update) end
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
					rememberTexture(frame, t)
					pcall(t.SetVertexColor, t, dimmed[1], dimmed[2], dimmed[3])
					pcall(t.SetDesaturated, t, true)
				end
			end
		end
		local hl = frame.GetHighlightTexture and frame:GetHighlightTexture()
		if hl and hl.SetVertexColor then
			rememberTexture(frame, hl)
			pcall(hl.SetVertexColor, hl, c.accent[1], c.accent[2], c.accent[3])
		end
		return
	end

	if kind == "statusbar" then
		-- Fill colour communicates data (collection progress), not chrome. The
		-- owner controls it; the fallback supplies only a clean flat material.
		if frame.SetStatusBarTexture then frame:SetStatusBarTexture(SOLID) end
		flatBackground(frame, { c.bg[1] * 0.70, c.bg[2] * 0.70,
			c.bg[3] * 0.70, 0.96 })
		flatBorder(frame, c.border[1], c.border[2], c.border[3], 1)
		return
	end

	if kind == "slider" then
		hideArt(frame)
		flatBackground(frame, { c.bg[1] * 1.18, c.bg[2] * 1.18,
			c.bg[3] * 1.18, 0.92 })
		flatBorder(frame, c.border[1], c.border[2], c.border[3], 1)
		local thumb = frame.GetThumbTexture and frame:GetThumbTexture()
		if thumb and thumb.SetVertexColor then
			rememberTexture(frame, thumb)
			thumb:SetVertexColor(c.accent[1], c.accent[2], c.accent[3], 1)
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
	local danger = kind == "button" and frame.mmIntent == "danger" and not disabled
	local path
	if kind == "row" then
		path = MODERN_ASSET.row
	elseif kind == "tab" then
		path = activeTab and MODERN_ASSET.tabActive
			or (state == "hover" and MODERN_ASSET.tabHover or MODERN_ASSET.tab)
	else
		modernButtonParts(frame, disabled and "disabled" or state)
		if danger and frame.mmModernButtonParts then
			for _, part in pairs(frame.mmModernButtonParts) do
				part:SetVertexColor(0.76, 0.42, 0.38, 0.88)
			end
		elseif frame.mmModernButtonParts then
			for _, part in pairs(frame.mmModernButtonParts) do
				part:SetVertexColor(1, 1, 1, 1)
			end
		end
	end
	if path then
		modernBackground(frame, path)
		frame.mmModernBackground:SetAlpha(disabled and not activeTab and 0.55 or 1)
		if kind == "row" then
			local warm = state == "pressed" and { 0.78, 0.66, 0.46 }
				or state == "hover" and { 1.00, 0.91, 0.72 }
				or { 1, 1, 1 }
			frame.mmModernBackground:SetVertexColor(warm[1], warm[2], warm[3], 1)
		elseif activeTab then
			-- The source texture carries a theatrical yellow bloom. A restrained
			-- warm tint keeps the selected state clear without turning the tab into
			-- the brightest object in the entire window.
			frame.mmModernBackground:SetVertexColor(0.62, 0.58, 0.50, 0.72)
			frame.mmModernBackground:SetAlpha(0.88)
		else
			frame.mmModernBackground:SetVertexColor(1, 1, 1, 1)
		end
	end

	local c = PALETTE.modern
	local fs = controlFont(frame)
	if fs then
		local tc = activeTab and c.accent or danger and c.danger
			or (disabled and c.muted or c.text)
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

-- The hit target stays generous, but the visible checkbox is an 18px control.
-- Shrinking the CheckButton itself would make Options harder to use; shrinking
-- only its authored chassis gives the calmer rhythm without losing usability.
local function modernCheckboxState(frame)
	local box = frame.mmModernCheckboxBox
	if not box then return end
	local active = T.Active() == "modern"
	box:SetAlpha(active and (frame:IsEnabled() and 1 or 0.45) or 0)
	if frame.mmModernCheck then
		frame.mmModernCheck:SetShown(active and frame:GetChecked() and true or false)
	end
	local c = PALETTE.modern
	local hover = frame.IsMouseOver and frame:IsMouseOver()
	flatBorder(box, c.border[1], c.border[2], c.border[3], hover and 0.78 or 0.42)
end

local function skinModernCheckbox(frame, c)
	hideArt(frame)
	local native = frame.GetCheckedTexture and frame:GetCheckedTexture()
	if native then native:SetAlpha(0) end
	if not frame.mmModernCheckboxBox then
		local box = CreateFrame("Frame", nil, frame)
		box:SetSize(18, 18)
		box:SetPoint("CENTER", frame, "CENTER", 0, 0)
		box:SetFrameLevel(frame:GetFrameLevel())
		box.mmNoSkin = true
		modernBackground(box, MODERN_ASSET.inset)
		box.mmModernBackground:SetVertexColor(0.58, 0.54, 0.47, 0.96)
		flatBorder(box, c.border[1], c.border[2], c.border[3], 0.42)

		local check = box:CreateTexture(nil, "OVERLAY")
		check:SetSize(14, 14)
		check:SetPoint("CENTER", 0, 0)
		check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
		check:SetVertexColor(c.accent[1], c.accent[2], c.accent[3], 1)
		frame.mmModernCheckboxBox = box
		frame.mmModernCheck = check
	end
	frame.mmModernCheckboxBox:SetAlpha(1)
	if not frame.mmModernCheckboxHooks then
		frame.mmModernCheckboxHooks = true
		for _, event in ipairs({ "OnShow", "OnClick", "OnEnter", "OnLeave",
			"OnEnable", "OnDisable" }) do
			frame:HookScript(event, modernCheckboxState)
		end
		-- Programmatic refreshes use SetChecked without firing OnClick. A secure
		-- post-hook keeps the authored tick in sync without replacing the native
		-- method, so Blizzard and ElvUI receive the exact control on round-trip.
		if hooksecurefunc then
			hooksecurefunc(frame, "SetChecked", modernCheckboxState)
		end
	end
	modernCheckboxState(frame)
end

local function updateModernSlider(frame)
	if T.Active() ~= "modern" or not frame.mmModernSliderFill then return end
	local lo, hi = frame:GetMinMaxValues()
	local value = frame:GetValue() or lo
	local span = (hi or 0) - (lo or 0)
	local pct = span > 0 and math.max(0, math.min(1, (value - lo) / span)) or 0
	local width = math.max(0, (frame:GetWidth() or 0) - 12) * pct
	frame.mmModernSliderFill:SetShown(width > 0)
	if width > 0 then frame.mmModernSliderFill:SetWidth(math.max(1, width)) end
end

local function skinModernSlider(frame, c)
	hideArt(frame)
	if not frame.mmModernSliderTrack then
		local track = frame:CreateTexture(nil, "BACKGROUND", nil, 2)
		track:SetPoint("LEFT", 6, 0)
		track:SetPoint("RIGHT", -6, 0)
		track:SetHeight(5)
		track:SetColorTexture(0.035, 0.026, 0.020, 0.96)
		frame.mmModernSliderTrack = track

		local fill = frame:CreateTexture(nil, "ARTWORK", nil, 2)
		fill:SetPoint("LEFT", track, "LEFT", 1, 0)
		fill:SetHeight(3)
		frame.mmModernSliderFill = fill
	end
	frame.mmModernSliderTrack:SetAlpha(1)
	frame.mmModernSliderFill:SetColorTexture(c.accent[1], c.accent[2], c.accent[3], 0.62)
	frame.mmModernSliderFill:SetAlpha(1)
	local thumb = frame.GetThumbTexture and frame:GetThumbTexture()
	if thumb then
		modernTexture(frame, thumb, MODERN_ASSET.scrollThumb)
		thumb:SetSize(10, 16)
		thumb:SetVertexColor(0.92, 0.78, 0.48, 0.92)
		thumb:SetAlpha(1)
	end
	if not frame.mmModernSliderHooks then
		frame.mmModernSliderHooks = true
		frame:HookScript("OnValueChanged", updateModernSlider)
		frame:HookScript("OnShow", updateModernSlider)
		frame:HookScript("OnSizeChanged", updateModernSlider)
	end
	updateModernSlider(frame)
end

local function skinModernScrollbar(frame, c)
	modernBackground(frame, MODERN_ASSET.scrollTrack)
	frame.mmModernBackground:SetVertexColor(0.58, 0.55, 0.49, 0.62)
	flatBorder(frame, c.border[1], c.border[2], c.border[3], 0.16)
	borderAlpha(frame, 0.16)
	local thumb = frame.GetThumbTexture and frame:GetThumbTexture()
	if thumb then
		modernTexture(frame, thumb, MODERN_ASSET.scrollThumb)
		thumb:SetVertexColor(0.76, 0.66, 0.46, 0.70)
		thumb:SetAlpha(0.74)
	end

	local function arrow(button, path)
		if not button then return end
		local states = {
			{ "GetNormalTexture",   { 0.72, 0.65, 0.50, 0.72 }, 0.70 },
			{ "GetPushedTexture",   { 1.00, 0.82, 0.34, 1.00 }, 1.00 },
			{ "GetDisabledTexture", { 0.46, 0.43, 0.38, 0.46 }, 0.42 },
		}
		for _, state in ipairs(states) do
			local getter, tint, alpha = state[1], state[2], state[3]
			local ok, texture = button[getter] and pcall(button[getter], button)
			if not ok then texture = nil end
			if texture then
				modernTexture(frame, texture, path)
				texture:SetVertexColor(tint[1], tint[2], tint[3], tint[4])
				texture:SetAlpha(alpha)
			end
		end
	end
	arrow(frame.ScrollUpButton or frame.UpButton or frame.Back or frame.DecrementButton,
		MODERN_ASSET.arrowUp)
	arrow(frame.ScrollDownButton or frame.DownButton or frame.Forward or frame.IncrementButton,
		MODERN_ASSET.arrowDown)
end

local function skinModern(frame, kind)
	local c = PALETTE.modern
	-- A prior ElvUI fallback may have created its own solid fill. It is ours,
	-- not native art, so hide it explicitly or it sits above the textured
	-- Modern surface when switching themes live.
	if frame.mmBackground then frame.mmBackground:SetAlpha(0) end
	if frame.mmFlatTabIndicator then frame.mmFlatTabIndicator:SetAlpha(0) end
	if frame.mmFlatCheckboxBox then frame.mmFlatCheckboxBox:SetAlpha(0) end
	if kind == "slider" then
		skinModernSlider(frame, c)
		return
	end
	hideArt(frame)

	-- "inset" IS A REAL KIND NOW, AND IT WAS THE MISSING LEVEL.
	--
	-- surface_inset_v2.tga has shipped in every build, sits in the asset table
	-- above, and could never be drawn: the fallback that names it was
	-- unreachable because this condition never admitted the kind. 192 KB of art
	-- with no way in.
	--
	-- It matters because it is the level the reference interface uses for every
	-- list. There the nesting is window -> column panel -> INSET WELL -> rows,
	-- and the well is what makes a list read as recessed into its column rather
	-- than painted onto it. We had window -> column -> rows and no well, which
	-- is why our columns look like flat areas with text on them.
	if kind == "frame" or kind == "panel" or kind == "content"
		or kind == "sidebar" or kind == "utility" or kind == "card"
		or kind == "inset" then
		local path = kind == "frame" and MODERN_ASSET.window
			or kind == "content" and MODERN_ASSET.content
			or kind == "sidebar" and MODERN_ASSET.sidebar
			or kind == "utility" and MODERN_ASSET.utility
			or kind == "card" and MODERN_ASSET.cardInset
			or kind == "panel" and MODERN_ASSET.panel
			or MODERN_ASSET.inset
		modernBackground(frame, path)
		-- THE PLATES CARRY THE HIERARCHY. LET THEM.
		--
		-- Six distinct plates are selected above -- window, content, sidebar,
		-- utility, card inset, panel -- each authored to sit at a different
		-- depth. Four of them were then tinted to the SAME 0.70, which
		-- collapsed exactly the difference they exist to express. Picking the
		-- right material and then averaging them together is how a window with
		-- six surfaces renders as one flat field.
		--
		-- The interface these came from draws every plate at full brightness
		-- and tints only the border. The one concession kept here is a small
		-- knock-back on the window plate, which is the largest stretched area
		-- and the only one where the detail reads as noise rather than grain.
		if kind == "frame" then
			frame.mmModernBackground:SetVertexColor(0.92, 0.90, 0.87, 0.98)
		else
			frame.mmModernBackground:SetVertexColor(1, 1, 1, 1)
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
			flatBorder(frame, c.border[1], c.border[2], c.border[3], 0.22)
			borderAlpha(frame, 0.22)
		else
			-- The shaped control artwork already contains its own frame.
			-- A second rectangular edge is what made every control shout gold.
			borderAlpha(frame, 0)
		end
		hookModernControl(frame, kind)
		modernControlState(frame, kind, "normal")
		return
	end

	if kind == "checkbox" then
		skinModernCheckbox(frame, c)
		return
	end

	if kind == "editbox" then
		modernBackground(frame, MODERN_ASSET.inset)
		frame.mmModernBackground:SetVertexColor(0.64, 0.61, 0.56, 0.92)
		flatBorder(frame, c.border[1], c.border[2], c.border[3], 0.34)
		borderAlpha(frame, 0.34)
		return
	end

	if kind == "scrollbar" then
		skinModernScrollbar(frame, c)
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
	if restoreModernControls then restoreModernControls(frame, kind) end
	if frame.mmBackground then frame.mmBackground:SetAlpha(0) end
	if frame.mmBorder then
		for _, edge in pairs(frame.mmBorder) do edge:SetAlpha(0) end
	end
	if restoreArt then restoreArt(frame) end
	local c = T.Colors()
	-- Tabs and checkboxes are stateful compound controls. ElvUI's public
	-- handlers are intentionally one-way and may preserve a prior selected
	-- texture or resize the checkbox hit frame. Our small flat primitives use
	-- the profile palette and remain exactly reversible.
	if kind == "tab" or kind == "checkbox" then
		flatSkin(frame, kind, c)
		return
	end

	-- ElvUI's handler API is intentionally one-way: handlers strip and replace
	-- template art and do not expose an undo operation. Live theme switching is
	-- a first-class feature here, so the addon uses ElvUI's active profile
	-- colours (T.Colors above) with its own reversible flat primitives instead
	-- of allowing a handler to permanently mutate Blizzard controls.
	flatSkin(frame, kind, c)
end

-- Apply the active theme to one frame.
function T.Skin(frame, kind)
	if not frame then return end
	rememberControlFont(frame)
	if kind == "statusbar" then rememberStatusTexture(frame) end
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

-- Meaning is not colour. Callers mark the rare destructive control and each
-- theme decides how strongly to express it; unmarked actions stay neutral.
function T.SetIntent(frame, intent)
	if not frame then return frame end
	frame.mmIntent = intent
	local kind = registry[frame] or "button"
	T.Skin(frame, kind)
	return frame
end

-- Keep the visible 18px checkbox while making its full label a click target.
-- SetHitRectInsets expands the existing button without stretching Blizzard's
-- template textures or moving the Modern/ElvUI chassis.
function T.ExtendCheckboxHitTarget(check, label, padding)
	if not (check and check.SetHitRectInsets and label) then return check end
	local function refresh()
		local width = label.GetStringWidth and label:GetStringWidth() or 0
		check:SetHitRectInsets(0, -math.ceil(width + (padding or 8)), 0, 0)
	end
	check.mmRefreshHitTarget = refresh
	refresh()
	return check
end

-- ButtonFrameTemplate may expose the same title through two aliases, or two
-- genuinely distinct FontStrings depending on client build. Exactly one title
-- is allowed to own the rail: Modern's authored label, otherwise one native
-- label. This removes the doubled ElvUI title without relying on API aliases.
function T.SyncWindowIdentity(frame)
	if not frame then return end
	local modern = frame.mmModernTitleText
	local nativeA = frame.TitleContainer and frame.TitleContainer.TitleText
	local nativeB = frame.TitleText
	local active = T.Active()
	if modern and modern.SetAlpha then modern:SetAlpha(active == "modern" and 1 or 0) end
	local chosen = nativeA or nativeB
	local titles = {}
	if nativeA then titles[#titles + 1] = nativeA end
	if nativeB and nativeB ~= nativeA then titles[#titles + 1] = nativeB end
	for _, title in ipairs(titles) do
		if title and title.SetAlpha then
			title:SetAlpha(active ~= "modern" and title == chosen and 1 or 0)
		end
	end
	if chosen and active ~= "modern" and chosen.SetTextColor then
		local c = T.Colors()
		local color = active == "elvui" and c.accent or c.text
		chosen:SetTextColor(color[1], color[2], color[3])
	end
end

-- Typography is part of the hierarchy too. `GameFontNormal` is bright yellow,
-- which is useful for one Blizzard heading but overwhelming when every mount
-- name inherits it. Register the semantic role once and let each theme choose
-- the colour without changing the font, size, copy, or layout.
local function skinText(fontString, spec)
	if not (fontString and fontString.SetTextColor and spec) then return end
	local active = T.Active()
	local c = active == "elvui" and T.Colors()
		or PALETTE[active] or PALETTE.blizzard
	local color
	-- "onbar" is text drawn over a COLOURED DATA SURFACE, not over the window.
	-- It cannot take the window's text colour, because the thing behind it is
	-- the fill: the collection bar runs amber to green, and ElvUI's 0.90 grey
	-- over a 0.30/0.85/0.40 green is about 1.4:1 -- and ElvUI reads the
	-- player's own profile, so it can be dimmer again. White plus a hard shadow
	-- is the only pairing that holds over both the filled and unfilled halves,
	-- since a centred label sits across the boundary between them.
	if spec.role == "onbar" then
		fontString:SetTextColor(1, 1, 1, 1)
		if fontString.SetShadowColor then
			fontString:SetShadowColor(0, 0, 0, 1)
			fontString:SetShadowOffset(1, -1)
		end
		return
	end
	if active == "modern" then
		color = spec.role == "accent" and c.accent
			or c[spec.role]
			or c.text
	elseif active == "elvui" then
		color = spec.role == "accent" and c.accent
			or c[spec.role]
			or c.text
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
		-- A LADDER, NOT A WOBBLE.
		--
		-- These were 0.72 and 0.70. Two percent apart is not a boundary the eye
		-- can find, so the planner's two columns -- correctly separated,
		-- correctly bordered, each carrying its own surface art -- rendered as
		-- one flat brown field, and every band and rule drawn on top of them
		-- had nothing to sit against.
		--
		-- Four steps far enough apart to read as depth: the toolbar strip and
		-- the side column sit BACK, the main reading surface comes forward, and
		-- a card lifts off it. That is the arrangement the source art was cut
		-- for -- side panels recessed, centre raised -- and it was being
		-- flattened by the tints rather than by the textures.
		-- Same reasoning as the frame path above, and this is where the tonal
		-- ladder I added a few commits ago was working against the art rather
		-- than with it: the plates already differ, so spreading vertex colours
		-- across them was correcting a flatness that came from tinting in the
		-- first place. Drawn as authored.
		texture:SetVertexColor(1, 1, 1, 1)
	elseif active == "elvui" then
		local c = T.Colors()
		local scale = role == "sidebar" and 0.82
			or role == "utility" and 1.22
			or role == "card" and 1.35 or 0.95
		texture:SetColorTexture(math.min(1, c.bg[1] * scale),
			math.min(1, c.bg[2] * scale), math.min(1, c.bg[3] * scale),
			role == "card" and 0.88 or 0.96)
	else
		-- Blizzard keeps its ornate outer frame, but a quiet pane tint still
		-- distinguishes navigation/list/detail regions instead of one black void.
		local warm = role == "sidebar" and { 0.055, 0.045, 0.035, 0.90 }
			or role == "utility" and { 0.085, 0.065, 0.025, 0.78 }
			or role == "card" and { 0.055, 0.050, 0.055, 0.86 }
			or { 0.035, 0.035, 0.050, 0.90 }
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
	local c = active == "elvui" and T.Colors()
		or PALETTE[active] or PALETTE.blizzard
	local alpha = strength == "strong" and 0.72 or 0.26
	-- ElvUI's actual frame border is black, which is correct around a light
	-- panel and completely invisible as an internal divider on our dark panes.
	-- Semantic rules use the profile accent there; the outer chrome remains the
	-- native black hairline.
	local color = active == "elvui" and c.accent or c.border
	texture:SetColorTexture(color[1], color[2], color[3], alpha)
	texture:SetAlpha(1)
end

function T.RegisterRule(texture, strength)
	if not texture then return texture end
	ruleRegistry[texture] = strength or "subtle"
	skinRule(texture, strength or "subtle")
	return texture
end

-- Tint authored effects (row hover, glow, active markers) through the same
-- semantic palette. A gold hover left inside an ElvUI-blue window is one of
-- those tiny inconsistencies that makes the entire skin feel unfinished.
local function skinTint(texture, spec)
	if not (texture and spec) then return end
	local color = T.Color(spec.role)
	-- NO ALPHA MEANS THE COLOUR'S OWN, and that matters because several palette
	-- entries carry their intensity in the fourth component rather than in the
	-- hue. `row` is the clearest case: modern states a brown at 0.20, Blizzard
	-- and ElvUI state WHITE at 0.03 and 0.02, because on those themes a row
	-- band is a barely-there lightening rather than a tint.
	--
	-- Passing a fixed alpha throws that away and cannot be right for all three
	-- at once. A caller that asked for 0.55 turned Blizzard's white-at-3% into
	-- white at 55% -- opaque grey slabs across the plan, reported from play.
	-- An explicit alpha still wins; omitting one now means "as the theme
	-- intends", which is the only thing that travels between palettes.
	local alpha = spec.alpha or color[4] or 1
	if spec.vertex and texture.SetVertexColor then
		texture:SetVertexColor(color[1], color[2], color[3], alpha)
	else
		texture:SetColorTexture(color[1], color[2], color[3], alpha)
	end
	texture:SetAlpha(1)
end

function T.RegisterTint(texture, role, alpha)
	if not texture then return texture end
	local spec = { role = role or "accent", alpha = alpha or 1 }
	tintRegistry[texture] = spec
	skinTint(texture, spec)
	return texture
end

function T.RegisterVertexTint(texture, role, alpha)
	if not texture then return texture end
	local spec = { role = role or "accent", alpha = alpha or 1, vertex = true }
	tintRegistry[texture] = spec
	skinTint(texture, spec)
	return texture
end

local function skinBackdropBorder(frame, strength)
	if not (frame and frame.SetBackdropBorderColor) then return end
	local active, c = T.Active(), T.Colors()
	local color = active == "elvui" and c.accent or c.border
	-- Modern's progress texture already contains its own fine gold rim. Drawing
	-- the generic frame border around it created the doubled, overlapping track
	-- visible in the first pass.
	local alpha = active == "modern" and frame.mmStatusFrame and 0
		or strength == "strong" and 0.86 or 0.40
	frame:SetBackdropBorderColor(color[1], color[2], color[3], alpha)
end

function T.RegisterBackdropBorder(frame, strength)
	if not frame then return frame end
	backdropBorderRegistry[frame] = strength or "subtle"
	skinBackdropBorder(frame, strength or "subtle")
	return frame
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

local function iconRest(button)
	return button.mmRestRole and T.Color(button.mmRestRole) or button.mmRest or REST
end

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
	b.mmRest = REST
	b.mmRestRole = "muted"

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
		local rest = iconRest(self)
		self:mmTint(rest[1], rest[2], rest[3])
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
	local rest = iconRest(b)
	b:mmTint(rest[1], rest[2], rest[3])
	return b
end

-- The main Modern window has a purpose-built title control in the authorized
-- art set. Keep the generic compact X for HUD panels, where a 64px ornamental
-- title button would be visually too loud even when scaled down.
function T.CreateTitleCloseButton(parent, size)
	local b = iconButton(parent, size, { 1.00, 0.88, 0.42 })
	b.mmRest = { 1, 1, 1 }
	b.mmRestRole = nil
	b.art:SetTexture(MODERN_ASSET.titleClose)
	b:mmTint(1, 1, 1)
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
	local rest = iconRest(b)
	b:mmTint(rest[1], rest[2], rest[3])
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
	local rest = iconRest(b)
	b:mmTint(rest[1], rest[2], rest[3])
	return b
end

local function retintIconButtons()
	for b in pairs(iconButtons) do
		if not b:IsMouseOver() then
			local rest = iconRest(b)
			b:mmTint(rest[1], rest[2], rest[3])
		end
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
	if objType == "EditBox" then return "editbox" end
	if objType == "DropdownButton" then return "button" end
	if objType == "Slider" then
		local orientation = child.GetOrientation and child:GetOrientation()
		return orientation == "HORIZONTAL" and "slider" or "scrollbar"
	end
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
	for texture, spec in pairs(tintRegistry) do skinTint(texture, spec) end
	for frame, strength in pairs(backdropBorderRegistry) do
		skinBackdropBorder(frame, strength)
	end
	-- re-sweep top-level windows: scroll rows are recycled and new ones may
	-- have appeared since the last pass
	local c = T.Colors()
	for _, name in ipairs({ "MasterMountsFrame", "MasterMountsMonitor",
		"MasterMountsCompact", "MasterMountsZoneAlert", "MasterMountsRareAlert",
		"MasterMountsArrow", "MasterMountsOnboarding" }) do
		local f = _G[name]
		if f then
			T.SkinTree(f)
			if f.mmIsWindow then T.SyncWindowIdentity(f) end
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
