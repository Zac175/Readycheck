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
        SIDEBAR = 295, HEADER = 138, TABS = 40, FOOTER = 0, PAD = 45, TOP_PAD = 10,
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
        CLOSE_BOX = 40, WHEEL = 80, LERP = 18,
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
        BTN_BG_HA = 0.65, BTN_BRD_A = 0.30, BTN_TXT_A = 0.55,
        -- (2026-11-16, Zac: "in both uis the buttons and sidebar stuff needs
        -- to be emphisized more") THE PLATES' STRENGTHS, in one place - the
        -- same as ZacUI's (UI.PL). A button: its lift and top line at rest
        -- and under the mouse, the shadow under its foot. A sidebar row: a
        -- quieter plate. CTA: how dark the accent (or the red) is on the
        -- face of the button a window wants pressed.
        -- (2026-11-16 12:39, Zac: "readycheck needs the same button redone
        -- stuff ... why did you only do zui and not both addons") THE SAME
        -- FACE AS ZACUI'S, worked out from its numbers instead of set by
        -- eye: over the button colour the lift is PL_LIFT at the top and
        -- PL_LIFT_LO at the foot (ZacUI's 0.250 down to 0.152 at rest),
        -- PL_LIFT_H / PL_LIFT_LO_H under the mouse with the lift's colour
        -- PL_WARM of the way to the accent (its 0.305 / 0.282 / 0.236 down
        -- to 0.186); the edge PL_EDGE, going to the accent at PL_EDGE_ACC
        -- under the mouse (PL_EDGE_H where it stays white: the corner
        -- boxes). CTA: the face is the accent (or the red) at CTA_BOT, lit
        -- with its own colour at CTA_LIFT at the top (ZacUI's 0.60 down to
        -- 0.38, and 0.74 down to 0.48 under the mouse).
        PL_LIFT = 0.107, PL_LIFT_LO = 0, PL_LIFT_H = 0.20, PL_LIFT_LO_H = 0.03, PL_WARM = 0.6,
        PL_SHEEN = 0.18, PL_SHEEN_H = 0.26, PL_DROP = 0.55,
        PL_EDGE = 0.26, PL_EDGE_H = 0.32, PL_EDGE_ACC = 0.80, PL_TXT = 0.86,
        NAV_PL_LIFT = 0.085, NAV_PL_SHEEN = 0.09, NAV_PL_EDGE = 0.16,
        NAV_PL_LIFT_H = 0.13, NAV_PL_SHEEN_H = 0.13, NAV_PL_EDGE_H = 0.62, NAV_PL_DROP = 0.40,
        CTA_BOT = 0.38, CTA_BOT_H = 0.48, CTA_LIFT = 0.355, CTA_LIFT_H = 0.50,
        -- (a plate painted with no foot value of its own - a sidebar row -
        -- has this share of its lift at its foot)
        PL_LO_SHARE = 0.35,
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

    -- THE SCROLL THUMB'S COLOUR, one for every scroll bar (2026-11-14, Zac:
    -- "some sliders in the addons were still brown by default they should
    -- all match the like greyish slider"). Outside the /rc window a thumb
    -- was the palette's brown and gold while it moved; the /rc window's is
    -- white at 0.27, a fifth brighter under the mouse. Now that grey is
    -- every bar's, as long as no thumb colour is picked on the Colours
    -- page. A picked one is painted as it always was: the pick at
    -- `pickAlpha` (what that bar used: 1, or 0.6 where it rests dim), gold
    -- while live. Returns r, g, b, a.
    function RC.UI:ScrollThumbColor(live, pickAlpha)
        local c = GetScrollThumb()
        local d = RC.defaultColors and RC.defaultColors.scrollbar and RC.defaultColors.scrollbar.thumb
        if d == nil or c == d then
            local a = S.SCROLL_THUMB_A
            local r, g, b = self:SCol("text", 1)
            return r, g, b, live and math.min(1, a + 0.2) or a
        end
        if live then
            local gold = GetAccentGold()
            return gold.r, gold.g, gold.b, 1
        end
        return c.r, c.g, c.b, pickAlpha or 1
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

    -- THE LOOK'S CHOICES (2026-11-18, Zac, of looks he had picked from
    -- mocks: "users should be able to pick just use my choice as
    -- default"). The window finish, the buttons' depth, the main button's
    -- face and the wheel are settings, the same ones ZacUI has on its Style
    -- page. Beside ZacUI Readycheck's windows wear ZacUI's (so the two
    -- match) unless "Use Readycheck's own" is ticked; on its own, or with
    -- that tick, they are read from the character's profile
    -- (db.fontSettings, the appearance table - nothing saved is what ships):
    --   lookOwn       true: Readycheck's own settings even beside ZacUI
    --   finishDepth   how much of the shading is drawn, 0 .. 1 (nil = 1)
    --   finishKind    nil / "depth", "bands", "plain" (UIF_Finish)
    --   finishRule    true: an accent line under a window's title bar
    --   finishGrain   how much of a ground texture, 0 .. 2 (nil = none)
    --   finishTex     which texture (nil = brushed metal)
    --   buttonDepth   0 .. 1.5 (nil = 1)
    --   mainButton    "plain" (nil: the main button's face is the accent)
    --   wheelSpeed    0.25 .. 4 (nil = 1)
    --   wheelSmooth   false: a notch jumps
    -- RC.UI:Look() -> the values in force (one table, refilled on every
    -- call: read it, do not keep it), and "zacui" or "own".
    RC.UI.LOOK_KEYS = { "finishDepth", "finishKind", "finishRule", "finishGrain", "finishTex",
                        "buttonDepth", "mainButton", "wheelSpeed", "wheelSmooth" }
    RC.UI.FINISH_KINDS = { depth = true, bands = true, plain = true }
    RC.UI.FINISH_TEXTURES = {
        { id = "brushed", label = RCL["Brushed metal"],  file = "brushed" },
        { id = "stone",   label = RCL["Stone grain"],    file = "ground_stone" },
        { id = "fine",    label = RCL["Fine grain"],     file = "ground_fine" },
        { id = "leather", label = RCL["Leather"],        file = "ground_leather" },
        { id = "iron",    label = RCL["Hammered iron"],  file = "ground_iron" },
        { id = "linen",   label = RCL["Linen"],          file = "ground_linen" },
        { id = "slate",   label = RCL["Slate"],          file = "ground_slate" },
        { id = "veined",  label = RCL["Veined stone"],   file = "ground_veined" },
        { id = "fibre",   label = RCL["Paper fibre"],    file = "ground_fibre" },
    }
    local TEX_KNOWN = {}
    for _, t in ipairs(RC.UI.FINISH_TEXTURES) do TEX_KNOWN[t.id] = t.file end
    RC.UI.FINISH_TEX_FILE = TEX_KNOWN
    local look = {}
    local function Num(v, default, lo, hi)
        v = tonumber(v)
        if not v or v ~= v then return default end
        if v < lo then return lo end
        if v > hi then return hi end
        return v
    end
    -- Whether ZacUI is there to follow, and whether it is being followed.
    function RC.UI:LookFollows()
        local Z = _G.ZacUI
        local F = type(Z) == "table" and Z.Finish or nil
        if type(F) ~= "table" then return false, false end
        local fs = RC.db and RC.db.fontSettings
        return true, not (fs and fs.lookOwn == true)
    end
    function RC.UI:Look()
        local there, following = self:LookFollows()
        if following then
            local F = _G.ZacUI.Finish
            if type(F.Look) == "function" then
                local ok, L = pcall(F.Look)
                if ok and type(L) == "table" then
                    look.depth = Num(L.depth, 1, 0, 2)
                    look.kind = RC.UI.FINISH_KINDS[L.kind] and L.kind or "depth"
                    look.rule = L.rule == true
                    look.grain = Num(L.grain, 0, 0, 2)
                    look.texture = TEX_KNOWN[L.texture] and L.texture or "brushed"
                    look.buttons = Num(L.buttons, 1, 0, 1.5)
                    look.mainPlain = L.mainPlain == true
                    look.wheel = Num(L.wheel, 1, 0.25, 4)
                    look.smooth = L.smooth ~= false
                    return look, "zacui"
                end
            end
            -- (a ZacUI from before the choices: its strength, the rest as shipped)
            local v = type(F.Strength) == "function" and tonumber(F.Strength()) or nil
            look.depth = Num(v, 1, 0, 2)
            look.kind, look.rule, look.grain, look.texture = "depth", false, 0, "brushed"
            look.buttons, look.mainPlain, look.wheel, look.smooth = 1, false, 1, true
            return look, "zacui"
        end
        local fs = (RC.db and RC.db.fontSettings) or look   -- (no profile yet: every read is nil)
        look.depth = Num(fs.finishDepth, 1, 0, 2)
        look.kind = RC.UI.FINISH_KINDS[fs.finishKind] and fs.finishKind or "depth"
        look.rule = fs.finishRule == true
        look.grain = Num(fs.finishGrain, 0, 0, 2)
        look.texture = TEX_KNOWN[fs.finishTex] and fs.finishTex or "brushed"
        look.buttons = Num(fs.buttonDepth, 1, 0, 1.5)
        look.mainPlain = fs.mainButton == "plain"
        look.wheel = Num(fs.wheelSpeed, 1, 0.25, 4)
        look.smooth = fs.wheelSmooth ~= false
        return look, "own"
    end
    -- everything of the look in one string (FontSystem's ZacUI signature:
    -- a change there re-dresses Readycheck's windows)
    function RC.UI:LookSignature()
        local L = self:Look()
        return string.format("%.2f|%s|%s|%.2f|%s|%.2f|%s", L.depth, L.kind, tostring(L.rule), L.grain, L.texture,
            L.buttons, tostring(L.mainPlain))
    end

    -- THE MOCKED FINISHES, AS PRESETS for Readycheck's own settings: values
    -- for the four finish keys; one a preset does not name is unset.
    RC.UI.FINISH_PRESET_KEYS = { "finishDepth", "finishKind", "finishRule", "finishGrain" }
    RC.UI.FINISH_PRESETS = {
        { id = "depth",     label = RCL["Soft depth"],                     set = {} },
        { id = "flat",      label = RCL["Flat"],                           set = { finishDepth = 0 } },
        { id = "bands",     label = RCL["Dark bands"],                     set = { finishKind = "bands" } },
        { id = "rule",      label = RCL["Flat with an accent line"],       set = { finishKind = "plain", finishRule = true } },
        { id = "bandsrule", label = RCL["Dark bands with an accent line"], set = { finishKind = "bands", finishRule = true } },
        { id = "textured",  label = RCL["Soft depth, textured"],           set = { finishGrain = 1 } },
    }
    -- the preset Readycheck's own saved values match: id, label - or
    -- "custom", RCL["Custom"]
    function RC.UI:FinishPresetNow()
        local fs = (RC.db and RC.db.fontSettings) or {}
        local k = math.min(1, Num(fs.finishDepth, 1, 0, 2))
        local kind = RC.UI.FINISH_KINDS[fs.finishKind] and fs.finishKind or "depth"
        local rule, g = fs.finishRule == true, Num(fs.finishGrain, 0, 0, 2)
        for _, p in ipairs(RC.UI.FINISH_PRESETS) do
            local set = p.set
            if math.abs((set.finishDepth or 1) - k) < 0.001 and (set.finishKind or "depth") == kind
                and (set.finishRule == true) == rule and math.abs((set.finishGrain or 0) - g) < 0.001 then
                return p.id, p.label
            end
        end
        return "custom", RCL["Custom"]
    end
    -- One of Readycheck's own look settings (nil = as shipped), applied at once.
    function RC.UI:SetLook(key, value)
        if not (RC.db and key) then return end
        if type(RC.db.fontSettings) ~= "table" then RC.db.fontSettings = {} end
        RC.db.fontSettings[key] = value
        self:LookChanged()
    end
    function RC.UI:SetFinishPreset(id)
        if not RC.db then return false end
        for _, p in ipairs(RC.UI.FINISH_PRESETS) do
            if p.id == id then
                if type(RC.db.fontSettings) ~= "table" then RC.db.fontSettings = {} end
                for _, key in ipairs(RC.UI.FINISH_PRESET_KEYS) do RC.db.fontSettings[key] = p.set[key] end
                self:LookChanged()
                return true
            end
        end
        return false
    end

    -- BUTTON DEPTH. The plate numbers in S above are what ships (100%).
    -- The depth moves each between the flat plate - one shade top to foot,
    -- a faint edge, no top line, no shadow - and the shipped one, and on
    -- past it (ZacUI's rule, UIF_Controls PlateSync: the same faces at
    -- every setting). S is rewritten in place; everything reads it when it
    -- paints.
    local S0 = {}
    for _, key in ipairs({ "PL_LIFT", "PL_LIFT_LO", "PL_LIFT_H", "PL_LIFT_LO_H", "PL_SHEEN", "PL_SHEEN_H", "PL_DROP", "PL_EDGE",
                           "NAV_PL_LIFT", "NAV_PL_SHEEN", "NAV_PL_EDGE", "NAV_PL_LIFT_H", "NAV_PL_SHEEN_H", "NAV_PL_DROP",
                           "CTA_BOT", "CTA_BOT_H", "CTA_LIFT", "CTA_LIFT_H", "PL_LO_SHARE" }) do
        S0[key] = S[key]
    end
    RC.UI.PLATE_SHIPPED = S0
    local EDGE_FLAT, NAV_EDGE_FLAT = 0.13, 0.085
    RC.UI._plated = setmetatable({}, { __mode = "k" })
    local plK
    function RC.UI:PlateSync()
        local k = self:Look().buttons
        if plK == k then return end
        plK = k
        if k == 1 then
            for key, v in pairs(S0) do S[key] = v end
            return
        end
        local function At(flat, shipped) return math.max(0, math.min(1, flat + (shipped - flat) * k)) end
        -- a face's lift at its top and at its foot: both move away from
        -- (or onto) their middle
        local function Pair(top, bot)
            local mid = (S0[top] + S0[bot]) / 2
            S[top], S[bot] = At(mid, S0[top]), At(mid, S0[bot])
        end
        Pair("PL_LIFT", "PL_LIFT_LO")
        Pair("PL_LIFT_H", "PL_LIFT_LO_H")
        S.PL_SHEEN, S.PL_SHEEN_H, S.PL_DROP = At(0, S0.PL_SHEEN), At(0, S0.PL_SHEEN_H), At(0, S0.PL_DROP)
        S.PL_EDGE = At(EDGE_FLAT, S0.PL_EDGE)
        -- a sidebar row's foot is a share of its lift
        local share0 = S0.PL_LO_SHARE
        local mid = (1 + share0) / 2
        local topK, footK = At(mid, 1), At(mid, share0)
        S.NAV_PL_LIFT, S.NAV_PL_LIFT_H = S0.NAV_PL_LIFT * topK, S0.NAV_PL_LIFT_H * topK
        S.PL_LO_SHARE = (topK > 0) and (footK / topK) or 1
        S.NAV_PL_SHEEN, S.NAV_PL_SHEEN_H, S.NAV_PL_DROP = At(0, S0.NAV_PL_SHEEN), At(0, S0.NAV_PL_SHEEN_H), At(0, S0.NAV_PL_DROP)
        S.NAV_PL_EDGE = At(NAV_EDGE_FLAT, S0.NAV_PL_EDGE)
        -- the main button: the accent at CTA_BOT, lit with itself at
        -- CTA_LIFT at the top (so its top is bot + (1 - bot) * lift)
        local function Cta(botKey, liftKey)
            local bot0 = S0[botKey]
            local top0 = bot0 + (1 - bot0) * S0[liftKey]
            local m = (top0 + bot0) / 2
            local top, bot = At(m, top0), At(m, bot0)
            S[botKey] = bot
            S[liftKey] = (bot < 1) and math.max(0, (top - bot) / (1 - bot)) or 0
        end
        Cta("CTA_BOT", "CTA_LIFT")
        Cta("CTA_BOT_H", "CTA_LIFT_H")
    end
    -- Every plate repaints from its frame's own painter (a look change).
    function RC.UI:RepaintPlates()
        self:PlateSync()
        for f in pairs(self._plated) do
            if type(f.Repaint) == "function" then pcall(f.Repaint, f) end
        end
    end
    -- After a look setting changed: buttons, window finishes, popups.
    function RC.UI:LookChanged()
        self:RepaintPlates()
        if self.FinishRefresh then self:FinishRefresh() end
        if RC.RefreshUIColors then RC:RefreshUIColors() end
    end

    -- THE PLATE (2026-11-09: buttons that look like buttons). A raised
    -- face on a settings control: a pale lift fading down from its top, a
    -- pale line along the inside of its top and, with edges = true, a
    -- one-pixel edge all round. Inset l / r / t / b from the frame (or laid
    -- on `over`, a texture). Made once per frame (frame._rcPlate).
    -- :Paint(liftA, sheenA, edgeColor, edgeA, dropA, liftLo, liftColor) colours
    -- it from the theme (liftLo: the lift at the foot, default a third of
    -- liftA; liftColor: default the window's text colour);
    -- :SetShown hides all of it. p.box is the area it covers.
    function RC.UI:Plate(f, l, r, t, b, edges, over)
        local p = f._rcPlate
        if p then return p end
        RC.UI:PlateSync()
        RC.UI._plated[f] = true
        p = { parts = {} }
        local function T(layer, sub)
            local x = f:CreateTexture(nil, layer, nil, sub)
            x:SetTexture(FLAT)
            p.parts[#p.parts + 1] = x
            return x
        end
        local box = over
        if not box then
            box = T("BACKGROUND", 0)
            box:SetPoint("TOPLEFT", f, "TOPLEFT", l or 0, -(t or 0))
            box:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -(r or 0), b or 0)
            box:SetVertexColor(0, 0, 0, 0)
        end
        p.box = box
        p.lift = T("BACKGROUND", 4)
        p.lift:SetAllPoints(box)
        p.sheen = T("BORDER", 2)
        p.sheen:SetHeight(1)
        p.sheen:SetPoint("TOPLEFT", box, "TOPLEFT", 1, -1)
        p.sheen:SetPoint("TOPRIGHT", box, "TOPRIGHT", -1, -1)
        if edges then
            p.edges = {}
            for _, side in ipairs({ "TOP", "BOTTOM" }) do
                local e = T("BORDER", 3)
                e:SetHeight(1)
                e:SetPoint(side .. "LEFT", box, side .. "LEFT", 0, 0)
                e:SetPoint(side .. "RIGHT", box, side .. "RIGHT", 0, 0)
                p.edges[#p.edges + 1] = e
            end
            for _, side in ipairs({ "LEFT", "RIGHT" }) do
                local e = T("BORDER", 3)
                e:SetWidth(1)
                e:SetPoint("TOP" .. side, box, "TOP" .. side, 0, 0)
                e:SetPoint("BOTTOM" .. side, box, "BOTTOM" .. side, 0, 0)
                p.edges[#p.edges + 1] = e
            end
        end
        -- (2026-11-16) the plate's shadow: one dark line under its foot,
        -- so it stands off the window (the window's shade colour)
        p.drop = T("BACKGROUND", -1)
        p.drop:SetHeight(1)
        p.drop:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 0, 0)
        p.drop:SetPoint("TOPRIGHT", box, "BOTTOMRIGHT", 0, 0)
        p.drop:SetVertexColor(0, 0, 0, 0)
        -- dropA: the shadow's strength (nil = none)
        function p:Paint(liftA, sheenA, edgeColor, edgeA, dropA, liftLo, liftColor)
            local c = RC:GetColor("settings", "text")
            local sh = RC:GetColor("settings", "shade")
            self.drop:SetVertexColor(sh.r, sh.g, sh.b, dropA or 0)
            local lc = liftColor or c
            local lo = liftLo or (liftA or 0) * S.PL_LO_SHARE
            if CreateColor and self.lift.SetGradient then
                self.lift:SetVertexColor(1, 1, 1, 1)
                self.lift:SetGradient("VERTICAL", CreateColor(lc.r, lc.g, lc.b, lo), CreateColor(lc.r, lc.g, lc.b, liftA or 0))
            elseif self.lift.SetGradientAlpha then
                self.lift:SetVertexColor(1, 1, 1, 1)
                self.lift:SetGradientAlpha("VERTICAL", lc.r, lc.g, lc.b, lo, lc.r, lc.g, lc.b, liftA or 0)
            else
                self.lift:SetVertexColor(lc.r, lc.g, lc.b, ((liftA or 0) + lo) / 2)
            end
            self.sheen:SetVertexColor(c.r, c.g, c.b, sheenA or 0)
            if self.edges and edgeColor then
                for _, e in ipairs(self.edges) do e:SetVertexColor(edgeColor.r, edgeColor.g, edgeColor.b, edgeA or 1) end
            end
        end
        function p:SetShown(on)
            for _, x in ipairs(self.parts) do x:SetShown(on and true or false) end
        end
        f._rcPlate = p
        return p
    end

    -- A BUTTON'S FACE at hover t (0 at rest .. 1 under the mouse), for
    -- p:Paint over the button colour: the lift at the top, the lift at the
    -- foot and the lift's colour (S.PL_*, ZacUI's face).
    function RC.UI:ButtonFace(t)
        t = t or 0
        RC.UI:PlateSync()
        local c = RC:GetColor("settings", "text")
        local A = RC.UI:SAccent()
        local w = S.PL_WARM * t
        return S.PL_LIFT + (S.PL_LIFT_H - S.PL_LIFT) * t, S.PL_LIFT_LO + (S.PL_LIFT_LO_H - S.PL_LIFT_LO) * t,
            { r = c.r + (A.r - c.r) * w, g = c.g + (A.g - c.g) * w, b = c.b + (A.b - c.b) * w }
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
