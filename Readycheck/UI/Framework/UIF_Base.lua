local type = type

------------------------------------------------------------------------
-- Readycheck - UI Framework Base
-- Owns the shared color/metric tables, font string creation, and the
-- default button texture that every widget file below builds on.
-- Exposes locals to the rest of the framework via RC._uif; only RC.UI:*
-- functions are the public surface other addon files may call.
-- Every other UI file must use RC.UI:* helpers instead of hand-rolling
-- frames, buttons, or hover logic - this file is the reference for them.
------------------------------------------------------------------------

local RC = _G.Readycheck
if not RC then return end
RC._uif = RC._uif or {}
local _uif = RC._uif
    RC.UI = {}

    RC.trackedFonts = RC.trackedFonts or {}
    RC.trackedTextures = RC.trackedTextures or {}

    -- Each Get*() below reads one theme key from RC:GetColor and falls
    -- back to a literal color if the theme system is not ready yet
    -- (e.g. very early load). Keep the fallback in sync with the theme
    -- default by hand - nothing checks the two against each other.
    local function GetWindowBG()
        if RC.GetColor then
            return RC:GetColor("ui", "windowBackground")
        end
        return {r = 0.08, g = 0.08, b = 0.08, a = 0.90}
    end

    local function GetElementBG()
        if RC.GetColor then
            return RC:GetColor("ui", "elementBackground")
        end
        return {r = 0.12, g = 0.12, b = 0.12, a = 0.9}
    end

    local function GetAccentGold()
        if RC.GetColor then
            return RC:GetColor("ui", "accentGold")
        end
        return {r = 0.85, g = 0.65, b = 0.25, a = 1}
    end

    local function GetHeaderBG()
        if RC.GetColor then
            return RC:GetColor("ui", "headerBackground")
        end
        return {r = 0.1, g = 0.1, b = 0.1, a = 1}
    end

    local function GetHeaderText()
        if RC.GetColor then
            return RC:GetColor("ui", "headerText")
        end
        return {r = 1, g = 0.82, b = 0, a = 1}
    end

    local function GetButtonNormalBG()
        if RC.GetColor then
            return RC:GetColor("buttons", "normalBackground")
        end
        return {r = 0.15, g = 0.15, b = 0.15, a = 1}
    end

    local function GetButtonHoverBG()
        if RC.GetColor then
            return RC:GetColor("buttons", "hoverBackground")
        end
        return {r = 0.22, g = 0.22, b = 0.22, a = 1}
    end

    local function GetButtonPressedBG()
        if RC.GetColor then
            return RC:GetColor("buttons", "pressedBackground")
        end
        return {r = 0.06, g = 0.06, b = 0.06, a = 1}
    end

    local function GetButtonDisabledBG()
        if RC.GetColor then
            return RC:GetColor("buttons", "disabledBackground")
        end
        return {r = 0.06, g = 0.06, b = 0.06, a = 0.5}
    end

    local function GetButtonConfiguredBG()
        if RC.GetColor then
            return RC:GetColor("buttons", "configuredBackground")
        end
        return {r = 0.1, g = 0.2, b = 0.1, a = 1}
    end

    local function GetButtonConfiguredHover()
        if RC.GetColor then
            return RC:GetColor("buttons", "configuredHover")
        end
        return {r = 0.15, g = 0.28, b = 0.15, a = 1}
    end

    local function GetButtonTextNormal()
        if RC.GetColor then
            return RC:GetColor("text", "buttonNormal")
        end
        return {r = 0.9, g = 0.9, b = 0.9, a = 1}
    end

    local function GetButtonTextDisabled()
        if RC.GetColor then
            return RC:GetColor("text", "buttonDisabled")
        end
        return {r = 0.5, g = 0.5, b = 0.5, a = 1}
    end

    local function GetButtonTextConfigured()
        if RC.GetColor then
            return RC:GetColor("text", "buttonActive")
        end
        return {r = 0.6, g = 1, b = 0.6, a = 1}
    end

    local function GetCloseNormal()
        if RC.GetColor then
            return RC:GetColor("buttons", "closeNormal")
        end
        return {r = 0.9, g = 0.2, b = 0.2, a = 1}
    end

    local function GetCloseHover()
        if RC.GetColor then
            return RC:GetColor("buttons", "closeHover")
        end
        return {r = 1, g = 0.3, b = 0.3, a = 1}
    end

    local function GetXNormal()
        if RC.GetColor then
            return RC:GetColor("buttons", "xNormal")
        end
        return {r = 0.6, g = 0.6, b = 0.6, a = 1}
    end

    local function GetXHover()
        if RC.GetColor then
            return RC:GetColor("buttons", "xHover")
        end
        return {r = 0.9, g = 0.3, b = 0.3, a = 1}
    end

    local function GetBorderNormal()
        if RC.GetColor then
            return RC:GetColor("ui", "borderNormal")
        end
        return {r = 0, g = 0, b = 0, a = 1}
    end

    -- The ring that outlines an ACTIVE (green-filled) control. Muted green
    -- on purpose: gold is reserved for "selected / open" on a neutral fill,
    -- so a gold ring never lands on top of a green one.
    local function GetBorderSelected()
        if RC.GetColor then
            return RC:GetColor("ui", "borderSelected")
        end
        return {r = 0.32, g = 0.62, b = 0.38, a = 1}
    end

    local function GetTextGold()
        if RC.GetColor then
            return RC:GetColor("text", "gold")
        end
        return {r = 1, g = 0.82, b = 0, a = 1}
    end

    local function GetScrollTrack()
        if RC.GetColor then
            return RC:GetColor("scrollbar", "track")
        end
        return {r = 0.08, g = 0.08, b = 0.08, a = 0.8}
    end

    local function GetScrollThumb()
        if RC.GetColor then
            return RC:GetColor("scrollbar", "thumb")
        end
        return {r = 0.6, g = 0.46, b = 0.18, a = 0.9}
    end

    local function GetCheckboxBG()
        if RC.GetColor then
            return RC:GetColor("checkbox", "background")
        end
        return {r = 0.1, g = 0.1, b = 0.1, a = 1}
    end

    local function GetCheckboxBorder()
        if RC.GetColor then
            return RC:GetColor("checkbox", "border")
        end
        return {r = 0, g = 0, b = 0, a = 1}
    end

    local function GetCheckboxHoverBorder()
        if RC.GetColor then
            return RC:GetColor("checkbox", "hoverBorder")
        end
        return {r = 0.85, g = 0.65, b = 0.25, a = 1}
    end

    local function GetCheckboxCheckmark()
        if RC.GetColor then
            return RC:GetColor("checkbox", "checkmark")
        end
        return {r = 0.3, g = 1, b = 0.3, a = 1}
    end

    local function GetDropdownBG()
        if RC.GetColor then
            return RC:GetColor("dropdown", "background")
        end
        return {r = 0.12, g = 0.12, b = 0.12, a = 0.98}
    end

    local function GetDropdownItemHover()
        if RC.GetColor then
            return RC:GetColor("dropdown", "itemHover")
        end
        return {r = 0.18, g = 0.18, b = 0.18, a = 1}
    end

    local function GetDropdownArrow()
        if RC.GetColor then
            return RC:GetColor("dropdown", "arrow")
        end
        return {r = 0.6, g = 0.6, b = 0.6, a = 1}
    end

    local function GetDropdownItemText()
        if RC.GetColor then
            return RC:GetColor("dropdown", "itemText")
        end
        return {r = 0.9, g = 0.9, b = 0.9, a = 1}
    end

    local function GetDropdownSelected()
        if RC.GetColor then
            return RC:GetColor("dropdown", "selected")
        end
        return {r = 0.85, g = 0.65, b = 0.25, a = 1}
    end

    local function GetTextNormal()
        if RC.GetColor then
            return RC:GetColor("text", "normal")
        end
        return {r = 0.9, g = 0.9, b = 0.9, a = 1}
    end

    local function GetTextGray()
        if RC.GetColor then
            return RC:GetColor("text", "gray")
        end
        return {r = 0.6, g = 0.6, b = 0.6, a = 1}
    end

    local function GetSidebarSelected()
        if RC.GetColor then
            return RC:GetColor("sidebar", "buttonSelected")
        end
        return {r = 0.12, g = 0.22, b = 0.12, a = 1}
    end

    local function GetSidebarTextNormal()
        if RC.GetColor then
            return RC:GetColor("text", "menuNormal")
        end
        return {r = 0.75, g = 0.75, b = 0.75, a = 1}
    end

    local function GetSidebarTextSelected()
        if RC.GetColor then
            return RC:GetColor("text", "menuSelected")
        end
        return {r = 0.5, g = 1, b = 0.5, a = 1}
    end

    -- FLAT is the one texture every piece of furniture (buttons, tabs, nav
    -- rows, dropdowns, checkboxes, thumbs, cards, title bars) paints with
    -- SetVertexColor. A plain white pixel takes any theme colour exactly,
    -- which is what lets the colour editor recolour the UI without
    -- swapping art, and it never carries a gradient.
    local FLAT = "Interface\\Buttons\\WHITE8X8"

    -- The addon's mark. It rides at the left of every title bar the addon
    -- draws, the way a window in any other app carries its own icon, so a
    -- Readycheck popup is recognisable as one before you read the title.
    local ICON_PATH = "Interface\\AddOns\\Readycheck\\Media\\Checkmark"

    -- normTex.tga / the user's LibSharedMedia statusbar texture is a BAR
    -- texture with a slight vertical lift. It is reserved for real
    -- status/progress/duration bars; furniture must use FLAT. The lookup
    -- stays public because the HUD bars still read it.
    local DEFAULT_TEXTURE = "Interface\\AddOns\\Readycheck\\Media\\normTex"

    local function GetButtonTexture()
        if RC.GetTexturePath then
            return RC:GetTexturePath()
        end
        return DEFAULT_TEXTURE
    end

    RC.UI.FLAT = FLAT
    RC.UI.ICON = ICON_PATH

    -- Same texture lookup exposed two ways (RC.UI.GetButtonTexture and
    -- RC:GetButtonTexture) for callers that only hold one or the other.
    function RC.UI.GetButtonTexture()
        return GetButtonTexture()
    end

    function RC:GetButtonTexture()
        return GetButtonTexture()
    end

    -- Blizzard's DropDownList1/2 are shared global frames with their own
    -- hardcoded art; they do not belong to any RC.UI container, so this
    -- reskins them in place the first time each one shows rather than
    -- creating a themed replacement. Runs once per list via the
    -- _wrChromeApplied guard.
    --
    -- This is the ONLY live reskin path. UIF_Dropdowns.lua carries an
    -- overlapping UIDropDownMenu_CreateFrames hook, but that file is not
    -- listed in Readycheck.toc and never loads, so it must not be relied on.
    local function ApplyDropdownChrome(listFrame)
        if not listFrame or listFrame._wrChromeApplied then return end

        local canBackdrop = listFrame.SetBackdrop ~= nil
        if not canBackdrop and BackdropTemplateMixin then
            Mixin(listFrame, BackdropTemplateMixin)
            if listFrame.OnBackdropLoaded then
                pcall(listFrame.OnBackdropLoaded, listFrame)
            end
            canBackdrop = listFrame.SetBackdrop ~= nil
        end

        -- Flat menu box: dropdown background fill, 1px black edge, square
        -- corners. No gold rule here - gold is reserved for title bars,
        -- page headers, card accents and the selected nav row.
        if canBackdrop then
            listFrame:SetBackdrop({
                bgFile   = FLAT,
                edgeFile = FLAT,
                edgeSize = 1,
                insets   = { left = 1, right = 1, top = 1, bottom = 1 },
            })
            local bg     = GetDropdownBG()
            local border = GetBorderNormal()
            listFrame:SetBackdropColor(bg.r, bg.g, bg.b, bg.a or 1)
            listFrame:SetBackdropBorderColor(border.r, border.g, border.b, border.a or 1)
        end

        listFrame._wrChromeApplied = true
    end

    if not RC._dropdownChromeHooked then
        RC._dropdownChromeHooked = true
        if DropDownList1 and DropDownList1.HookScript then
            DropDownList1:HookScript("OnShow", function(self) ApplyDropdownChrome(self) end)
        end
        if DropDownList2 and DropDownList2.HookScript then
            DropDownList2:HookScript("OnShow", function(self) ApplyDropdownChrome(self) end)
        end
    end

    local function RegisterTexture(textureObj)
        if textureObj and RC.trackedTextures then
            table.insert(RC.trackedTextures, textureObj)
        end
    end

    -- Shared layout/metric constants for every screen built on this
    -- framework. Change a value here rather than at each call site to
    -- keep spacing and sizing consistent across panels.
    local BASE = {
        BUTTON_WIDTH = 200,
        BUTTON_HEIGHT = 32,
        SMALL_BUTTON_WIDTH = 140,
        SMALL_BUTTON_HEIGHT = 28,

        SLIDER_WIDTH = 280,
        SLIDER_HEIGHT = 18,
        DROPDOWN_WIDTH = 220,
        DROPDOWN_HEIGHT = 24,

        EDITBOX_WIDTH = 120,
        EDITBOX_HEIGHT = 22,
        CHECKBOX_SIZE = 14,

        FONT_SIZE_TINY = 9,
        FONT_SIZE_SMALL = 11,
        FONT_SIZE_NORMAL = 12,
        FONT_SIZE_MEDIUM = 14,
        FONT_SIZE_LARGE = 16,
        FONT_SIZE_HEADER = 18,
        FONT_SIZE_TITLE = 20,

        SPACING_MICRO = 3,
        SPACING_TINY = 6,
        SPACING_SMALL = 12,
        SPACING_NORMAL = 18,
        SPACING_LARGE = 28,
        SPACING_SECTION = 40,
        SPACING_MAJOR = 55,

        MARGIN = 20,
        CONTENT_PADDING = 15,
        SCROLLBAR_WIDTH = 20,
        BORDER_WIDTH = 1,

        WINDOW_WIDTH = 950,
        WINDOW_HEIGHT = 700,

        ELEMENT_HEIGHTS = {
            button = 32,
            checkbox = 24,
            slider = 45,
            dropdown = 35,
            text = 16,
            section_header = 30
        }
    }

    -- Structural constants (pure black borders, additive highlight,
    -- transparent fill) rather than themeable UI colors - these are not
    -- routed through RC:GetColor because they are not meant to vary
    -- with the color theme.
    local C = {
        black = {0, 0, 0, 1},
        transparent = {0.1, 0.1, 0.1, 0},
        whiteHint = {1, 1, 1, 0.05},
        green = {0.2, 1, 0.2, 1},
        darkGray = {0.2, 0.2, 0.2, 0.8},
        buttonBg = {0.18, 0.18, 0.18, 0.9},
        black4 = {0, 0, 0, 1},
        white = {1, 1, 1, 1},
        blackDim = {0, 0, 0, 0.8},
        lightGray = {0.85, 0.85, 0.85, 1},
        elementBg = {0.12, 0.12, 0.12, 0.5},
        red = {1, 0.3, 0.3, 1},
        yellowHint = {1, 1, 0, 0.3},
        brownHint = {0.3, 0.3, 0, 0.5},
    }

    -- TEXT used to be a table of literal RGB triples, so the ~40 pages
    -- that paint through TEXT.gray / TEXT.light ignored the colour editor
    -- entirely. Each name now maps onto a key in the text palette and is
    -- resolved at the moment it is read, so those pages recolour like
    -- everything else. Callers keep indexing it exactly as before
    -- (TEXT.gray[1..3], unpack(TEXT.light)); the fourth slot is alpha.
    local TEXT_MAP = {
        light       = "normal",
        bright      = "normal",
        normal      = "secondary",
        gray        = "disabled",
        dimGray     = "disabled",
        medGray     = "gray",
        white       = "white",
        gold        = "gold",
        goldFull    = "gold",
        orange      = "orange",
        yellow      = "yellow",
        yellowLight = "yellow",
        green       = "green",
        greenBright = "green",
        red         = "red",
        redLight    = "red",
        lightGray   = "gray",
        grayFull    = "gray",
    }
    local TEXT_FALLBACK = {
        normal = {0.9, 0.9, 0.9}, secondary = {0.6, 0.6, 0.6}, disabled = {0.5, 0.5, 0.5},
        gray = {0.6, 0.6, 0.6}, white = {1, 1, 1}, gold = {1, 0.82, 0}, orange = {1, 0.6, 0.2},
        yellow = {1, 1, 0.3}, green = {0.5, 0.8, 0.5}, red = {1, 0.3, 0.3},
    }
    local TEXT_SHARED = setmetatable({}, {
        __index = function(_, name)
            local key = TEXT_MAP[name]
            if not key then return nil end
            if RC.GetColor and RC.defaultColors then
                local c = RC:GetColor("text", key)
                if c then return { c.r, c.g, c.b, c.a or 1 } end
            end
            local f = TEXT_FALLBACK[key]
            return { f[1], f[2], f[3], 1 }
        end,
        -- Writes are ignored: legacy callers do `TEXT.gray = TEXT.gray or {...}`,
        -- which would otherwise freeze a snapshot and break live recolouring.
        __newindex = function() end,
    })

    RC.UI.C    = C
    RC.UI.TEXT = TEXT_SHARED

    -- Creates a FontString via RC:ApplyCustomFont (never raw SetFont) and
    -- registers it in RC.trackedFonts so a global font change can walk
    -- every tracked string and reapply. Returns the FontString; caller
    -- still owns SetPoint/SetText/SetTextColor.
    local function CreateProfessionalFontString(parent, layer, size, outline)
        local fontString = parent:CreateFontString(nil, layer or "OVERLAY")
        local fontSize = size or BASE.FONT_SIZE_NORMAL
        local fontOutline = outline or "OUTLINE"

        RC:ApplyCustomFont(fontString, fontSize, fontOutline)

        fontString._wrFontSize = fontSize
        fontString._wrFontOutline = fontOutline

        if RC.trackedFonts then
            table.insert(RC.trackedFonts, fontString)
        end

        return fontString
    end

    -- Appends entry to RC.SUBPANEL_ALIASES for the settings sidebar's
    -- search-by-keyword feature; entry is caller-defined and not
    -- validated beyond being a table.
    function RC.UI:RegisterSidebarSearch(entry)
        if type(entry) ~= "table" then return end
        RC.SUBPANEL_ALIASES = RC.SUBPANEL_ALIASES or {}
        table.insert(RC.SUBPANEL_ALIASES, entry)
    end

    ------------------------------------------------------------------
    -- THE /rc WINDOW'S LOOK (5.0)
    ------------------------------------------------------------------
    -- The settings window is built to the same numbers as ZacUI's /zui
    -- window (zui_tests/MATCH_OPTIONS_1107.md has each value and where it
    -- was read). One table, so a spacing change is one edit. Colours come
    -- from RC:GetColor("settings", ...); the numbers here are sizes and
    -- the alpha each state paints that colour at.
    local S = {
        -- the window
        W = 1300, H = 946, MIN_W = 1000, MIN_H = 640, MAX_W = 1600, MAX_H = 1100,
        SIDEBAR = 295, HEADER = 138, TABS = 40, FOOTER = 82, PAD = 45, TOP_PAD = 10,
        -- the page's own left edge (cards and headers sit 18 in from it):
        -- the scroll area is set in by the rest, so PAD lands at 45
        PAGE_X = 27,
        -- the sidebar
        NAV_TOP = 114, NAV_ROW = 40, NAV_ICON_W = 45, NAV_ICON_H = 32, NAV_LEFT = 20, NAV_GAP = 10,
        GROUP_ROW = 28, CHILD_ROW = 28, GROUP_GAP = 10, CHILD_X = 36,
        SB_TOP = 13, SB_H = 28, SB_BOT = 6, SB_INSET = 20,
        -- sections and rows
        SECTION_RULE_Y = 26, SIDE = 20, CARD_GAP = 10,
        -- controls
        CHECK = 18, TOGGLE_W = 40, TOGGLE_H = 20, KNOB_PAD = 2,
        TRACK_H = 4, THUMB = 14, VALUE_W = 40, VALUE_H = 26, TRACK_GAP = 12,
        FOOT_BTN_W = 180, FOOT_BTN_H = 36, FOOT_CLOSE_W = 160, FOOT_PAD = 24, FADE = 0.10,
        CLOSE_BOX = 40, WHEEL = 60, LERP = 12,
        -- type
        F_TITLE = 36, F_DESC = 14, F_TAB = 16, F_NAV = 14, F_GROUP = 15, F_SECTION = 12,
        F_VALUE = 13, F_HINT = 12, F_BRAND = 28,
        -- alphas
        BORDER_A = 0.05, DIM_A = 0.53, SECTION_A = 0.41, OFF_A = 0.3,
        ROW_ODD = 0.10, ROW_EVEN = 0.20, SIDEBAR_A = 0.20, TAB_BAND_A = 0.20,
        SECTION_RULE_A = 0.02,
        NAV_EN = 0.60, NAV_HOVER = 0.86, NAV_OFF = 0.11, NAV_HL = 0.06,
        NAV_GLOW = 0.15, NAV_HOVER_GLOW = 0.03, NAV_HOVER_IND = 0.25, NAV_EDGE = 0.5,
        INPUT_A = 0.35, INPUT_BRD_A = 0.10, INPUT_FOCUS_A = 0.8,
        SL_TRACK_A = 0.22, SL_FILL_A = 0.75, SL_INPUT_A = 0.40, SL_INPUT_BRD_A = 0.12,
        TG_OFF_A = 0.65, TG_ON_A = 0.75, KNOB_OFF_A = 0.5,
        CB_BRD_A = 0.05, CB_ACT_BRD_A = 0.15, CB_REST = 0.8,
        BTN_BG_A = 0.6, BTN_BG_HA = 0.65, BTN_BRD_A = 0.30, BTN_BRD_HA = 0.45, BTN_TXT_A = 0.55, BTN_TXT_HA = 0.70,
        FOOT_BG_A = 0.92, FOOT_BRD_A = 0.4, FOOT_BRD_HA = 0.6, FOOT_TXT_A = 0.5, FOOT_TXT_HA = 0.7, CLOSE_A = 0.7,
        DD_BG_A = 0.9, DD_BG_HA = 0.98, DD_BRD_A = 0.20, DD_BRD_HA = 0.30, DD_TXT_A = 0.50, DD_TXT_HA = 0.60,
        DD_HL_A = 0.08, DD_SEL_A = 0.04,
        SCROLL_TRACK_A = 0.02, SCROLL_THUMB_A = 0.27, SCROLL_W = 4,
    }
    RC.UI.S = S

    -- One colour of the window (RC:GetColor "settings"), at an alpha.
    function RC.UI:SCol(key, alpha)
        local c = (RC.GetColor and RC:GetColor("settings", key)) or { r = 1, g = 1, b = 1, a = 1 }
        return c.r or 1, c.g or 1, c.b or 1, (alpha or 1) * (c.a or 1)
    end
    function RC.UI:SAccent()
        local c = (RC.GetColor and RC:GetColor("settings", "accent")) or GetAccentGold()
        return c
    end

    -- Is this frame part of the /rc window's page or sidebar? The window
    -- marks its scroll child, sidebar and footer (_rcSetRoot); a widget
    -- built anywhere under them wears the window's look, one built
    -- anywhere else (a dialog, a preview sample, a HUD) keeps its own.
    function RC.UI:InSettings(frame)
        local f, n = frame, 0
        while type(f) == "table" and n < 16 do
            if f._rcSetRoot then return true end
            if f._rcSetStop or not f.GetParent then return false end
            f = f:GetParent()
            n = n + 1
        end
        return false
    end

    -- ROUND ART: plain white anti-aliased discs (Media/Icons/disc<n>, the
    -- same files ZacUI ships - our own art), each in a power-of-two
    -- canvas. A pill is a disc's two halves for its ends with a flat
    -- middle. Tinted by vertex colour.
    local DISC_SIZES = { 4, 6, 8, 10, 12, 14, 16, 20, 24, 32 }
    local DISC_PATH = "Interface\\AddOns\\Readycheck\\Media\\Icons\\disc"
    RC.UI.ICONS = "Interface\\AddOns\\Readycheck\\Media\\Icons\\"
    local function DiscOf(n)
        n = math.floor((n or 16) + 0.5)
        for _, s in ipairs(DISC_SIZES) do if s >= n then return s end end
        return 32
    end
    local function Canvas(s) local c = 1 while c < s do c = c * 2 end return c end
    -- part: nil (the whole disc), "left" or "right" (its half)
    function RC.UI:DiscArt(tex, n, part)
        local s = DiscOf(n)
        local c = Canvas(s)
        local o = (c - s) / 2
        local l, r, t, b = o / c, (o + s) / c, o / c, (o + s) / c
        if part == "left" then r = (o + s / 2) / c elseif part == "right" then l = (o + s / 2) / c end
        tex:SetTexture(DISC_PATH .. s)
        tex:SetTexCoord(l, r, t, b)
    end
    -- A pill filling `host` (h = its height): pill:Color(r, g, b, a),
    -- pill:Show(on), pill:Size(h).
    function RC.UI:Pill(host, layer, sub, h)
        local p = {}
        local function T()
            return host:CreateTexture(nil, layer or "ARTWORK", nil, sub or 0)
        end
        p.l, p.m, p.r = T(), T(), T()
        p.m:SetTexture(FLAT)
        function p:Size(hh)
            hh = math.max(2, hh or host:GetHeight() or 4)
            local half = hh / 2
            RC.UI:DiscArt(self.l, hh, "left")
            RC.UI:DiscArt(self.r, hh, "right")
            self.l:ClearAllPoints()
            self.l:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
            self.l:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", 0, 0)
            self.l:SetWidth(half)
            self.r:ClearAllPoints()
            self.r:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, 0)
            self.r:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
            self.r:SetWidth(half)
            self.m:ClearAllPoints()
            self.m:SetPoint("TOPLEFT", self.l, "TOPRIGHT", 0, 0)
            self.m:SetPoint("BOTTOMRIGHT", self.r, "BOTTOMLEFT", 0, 0)
        end
        function p:Color(r, g, b, a)
            self.l:SetVertexColor(r, g, b, a) self.m:SetVertexColor(r, g, b, a) self.r:SetVertexColor(r, g, b, a)
        end
        function p:Show(on)
            self.l:SetShown(on) self.m:SetShown(on) self.r:SetShown(on)
        end
        p:Size(h)
        return p
    end

    -- A left-to-right fade of colour c from alpha a0 to nothing.
    function RC.UI:Grad(tex, c, a0)
        tex._rcGrad = { c.r, c.g, c.b, a0 }
        if CreateColor and tex.SetGradient then
            tex:SetVertexColor(1, 1, 1, 1)
            tex:SetGradient("HORIZONTAL", CreateColor(c.r, c.g, c.b, a0), CreateColor(c.r, c.g, c.b, 0))
        elseif tex.SetGradientAlpha then
            tex:SetVertexColor(1, 1, 1, 1)
            tex:SetGradientAlpha("HORIZONTAL", c.r, c.g, c.b, a0, c.r, c.g, c.b, 0)
        else
            tex:SetVertexColor(c.r, c.g, c.b, a0 / 2)
        end
    end

    _uif.S = S
    _uif.BASE = BASE
    _uif.C = C
    _uif.FLAT = FLAT
    _uif.CreateProfessionalFontString = CreateProfessionalFontString
    _uif.GetAccentGold = GetAccentGold
    _uif.GetBorderNormal = GetBorderNormal
    _uif.GetBorderSelected = GetBorderSelected
    _uif.GetCheckboxBorder = GetCheckboxBorder
    _uif.GetCheckboxHoverBorder = GetCheckboxHoverBorder
    _uif.GetDropdownItemText = GetDropdownItemText
    _uif.GetDropdownSelected = GetDropdownSelected
    _uif.GetScrollThumb = GetScrollThumb
    _uif.GetScrollTrack = GetScrollTrack
    _uif.GetTextGold = GetTextGold
    _uif.GetXHover = GetXHover
    _uif.GetButtonConfiguredBG = GetButtonConfiguredBG
    _uif.GetButtonConfiguredHover = GetButtonConfiguredHover
    _uif.GetButtonDisabledBG = GetButtonDisabledBG
    _uif.GetButtonHoverBG = GetButtonHoverBG
    _uif.GetButtonNormalBG = GetButtonNormalBG
    _uif.GetButtonPressedBG = GetButtonPressedBG
    _uif.GetButtonTextConfigured = GetButtonTextConfigured
    _uif.GetButtonTextDisabled = GetButtonTextDisabled
    _uif.GetButtonTextNormal = GetButtonTextNormal
    _uif.GetButtonTexture = GetButtonTexture
    _uif.GetCheckboxBG = GetCheckboxBG
    _uif.GetCheckboxCheckmark = GetCheckboxCheckmark
    _uif.GetCloseHover = GetCloseHover
    _uif.GetCloseNormal = GetCloseNormal
    _uif.GetDropdownArrow = GetDropdownArrow
    _uif.GetDropdownBG = GetDropdownBG
    _uif.GetDropdownItemHover = GetDropdownItemHover
    _uif.GetElementBG = GetElementBG
    _uif.GetHeaderBG = GetHeaderBG
    _uif.GetHeaderText = GetHeaderText
    _uif.GetSidebarSelected = GetSidebarSelected
    _uif.GetSidebarTextNormal = GetSidebarTextNormal
    _uif.GetSidebarTextSelected = GetSidebarTextSelected
    _uif.GetTextGray = GetTextGray
    _uif.GetTextNormal = GetTextNormal
    _uif.GetWindowBG = GetWindowBG
    _uif.GetXNormal = GetXNormal
    _uif.RegisterTexture = RegisterTexture
