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
