------------------------------------------------------------------------
-- Readycheck - Font System
-- Owns font/texture selection: built-in font/texture tables, optional
-- LibSharedMedia-3.0 registration, and RC:ApplyCustomFont/RC:SetTexture/
-- RC:SetFont used everywhere else instead of raw SetFont/SetTexture calls.
-- FontStrings styled before CompleteInitialization runs are queued in
-- pendingFontStrings and replayed once fontSystem.initialized flips true.
------------------------------------------------------------------------
local AddonName = "Readycheck"
local RC = _G[AddonName]

if not RC then
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("ADDON_LOADED")
    frame:SetScript("OnEvent", function(self, event, addon)
        if addon == AddonName then
            RC = _G[AddonName]
            self:UnregisterAllEvents()
        end
    end)
    return
end

-- Every ApplyCustomFont'd fontString and font-managed texture registers
-- itself here so UpdateAllFonts/UpdateAllTextures can restyle it later.
RC.trackedFonts = RC.trackedFonts or {}
RC.trackedTextures = RC.trackedTextures or {}

RC.fontSystem = {
    currentFont = "Friz Quadrata",
    currentTexture = "Readycheck Smooth",
    useSharedMedia = false,
    initialized = false,

    builtInFonts = {
        ["Friz Quadrata"] = {
            path = "Fonts\\FRIZQT__.TTF",
            description = RCL["WoW's default UI font"]
        },
        ["Arial Narrow"] = {
            path = "Fonts\\ARIALN.TTF",
            description = RCL["Clean sans-serif font"]
        },
        ["Morpheus"] = {
            path = "Fonts\\MORPHEUS.TTF",
            description = RCL["WoW's decorative font"]
        },
        ["Skurri"] = {
            path = "Fonts\\SKURRI.TTF",
            description = RCL["WoW's bold combat font"]
        }
    },

    builtInTextures = {
        ["Readycheck Smooth"] = {
            path = "Interface\\AddOns\\Readycheck\\Media\\normTex",
            description = RCL["Readycheck's soft bar texture"]
        },
        ["Blizzard"] = {
            path = "Interface\\TargetingFrame\\UI-StatusBar",
            description = RCL["Default WoW statusbar"]
        },
        ["Blizzard Raid Bar"] = {
            path = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill",
            description = RCL["Raid frame health bar texture"]
        },
        ["Solid"] = {
            path = "Interface\\Buttons\\WHITE8X8",
            description = RCL["Solid flat color"]
        }
        -- "Minimalist", "Smooth" and "Flat" used to be listed here with
        -- files Readycheck never shipped (Media\minimalist and friends).
        -- Newer LibSharedMedia builds - the one WeakAuras carries - check
        -- that a registered file exists and raise an error when it does
        -- not, so anyone running Readycheck next to WeakAuras saw three
        -- errors at login. A saved choice of one of them falls back to
        -- Readycheck Smooth (see CompleteInitialization).
    },

    pendingFontStrings = {}
}

-- SetFont on a file the client does not have: older clients return false
-- and leave the string as it was, newer ones (1.15.9) RAISE "Invalid font
-- asset ... file not found" - a LibSharedMedia entry for another language's
-- font is enough. Both come back from here as "did not load" (false), so
-- every caller's fallback runs and nothing is raised.
local function TrySetFont(fontString, path, size, flags)
    local called, set = pcall(fontString.SetFont, fontString, path, size, flags)
    if not called then return false end
    return set
end
RC.TrySetFont = TrySetFont

-- CJK/Cyrillic clients render some custom font files as boxes; swap the
-- known-bad paths back to STANDARD_TEXT_FONT for those locales only
-- (ruRU is exempt from the FRIZQT swap - its default font renders fine).
local function LocaleSafeFont(path)
    local loc = (Readycheck and Readycheck.LOCALE) or "enUS"
    if loc ~= "ruRU" and loc ~= "koKR" and loc ~= "zhCN" and loc ~= "zhTW" then
        return path
    end
    if path and path:find("RedHatDisplay", 1, true) then
        return STANDARD_TEXT_FONT or path
    end
    if loc ~= "ruRU" and path == "Fonts\\FRIZQT__.TTF" then
        return STANDARD_TEXT_FONT or path
    end
    return path
end

function RC:GetFontPath(fontName)
    if not fontName then
        if self.db and self.db.fontSettings and self.db.fontSettings.selectedFont then
            fontName = self.db.fontSettings.selectedFont
        else
            fontName = "Friz Quadrata"
        end
    end

    -- LSM is checked first: it already contains every builtInFonts entry
    -- (registered in CompleteInitialization) plus anything other addons added.
    if self.LSM then
        local path = self.LSM:Fetch("font", fontName)
        if path then
            return LocaleSafeFont(path)
        end
    end

    if self.fontSystem.builtInFonts[fontName] then
        return LocaleSafeFont(self.fontSystem.builtInFonts[fontName].path)
    end

    return LocaleSafeFont("Fonts\\FRIZQT__.TTF")
end

------------------------------------------------------------------------
-- BESIDE ZACUI: ONE LOOK (2026-11-14)
-- Zac, his two changelog windows side by side: "can the changelog be
-- styled to what style the user has picked in the ui so things match
-- more ... consistancy is a thing that i want all the time". He chose:
-- when ZacUI is installed every Readycheck WINDOW wears ZacUI's font and
-- colours; without ZacUI nothing changes.
--
-- THE FONT. Readycheck's windows (the /rc window, every popup, dialog and
-- small window in the shell, the lists their dropdowns open) wear the
-- face picked in ZacUI - while Readycheck's own font is left on Default.
-- A font picked in Readycheck is the player's word and stays on
-- everything. What sits on the screen (bars, trackers, reminders, a
-- window's preview of them) keeps Readycheck's font either way: a new
-- face changes how wide text is, and nothing a player placed may change
-- size because of an update. ZacUI on "Blizzard default" has no face of
-- its own: nothing to follow.
--   RC:ZacUIFace()            the font file, or nil when not following
--   RC:IsWindowText(region)   is this string part of a window?
--   RC:FollowZacUI()          looks whether ZacUI's font or colours changed
--                             since last time and re-dresses if so (asked
--                             when a window opens; never from an event)
-- (the colours: Core/Database DB_Raids, RC:GetColor)
------------------------------------------------------------------------
local function OwnFontPicked()
    local fs = RC.db and RC.db.fontSettings
    local name = fs and fs.selectedFont
    return type(name) == "string" and name ~= "" and name:lower() ~= "default"
end

local zfaceName, zfacePath, zfaceAt = nil, nil, 0
function RC:ZacUIFace()
    local Z = _G.ZacUI
    if type(Z) ~= "table" or type(Z.ResolveFontPath) ~= "function" then return nil end
    local zdb = _G.ZacUIDB
    local font = type(zdb) == "table" and zdb.font
    local name = type(font) == "table" and font.name
    if type(name) ~= "string" or name == "" then return nil end
    if OwnFontPicked() then return nil end
    -- (asked for every string that is dressed: the answer for a name is
    -- kept; a name that has no file yet is asked again after 5 seconds)
    local now = GetTime and GetTime() or 0
    if zfaceName == name and (zfacePath or now - zfaceAt < 5) then return zfacePath end
    local ok, path = pcall(Z.ResolveFontPath, name)
    zfaceName, zfaceAt = name, now
    zfacePath = (ok and type(path) == "string" and path ~= "") and path or nil
    return zfacePath
end

-- A string is window text when something above it is the /rc window, one
-- of its marked parts, a dropdown's list (_rcWindow / _rcSetRoot) or a
-- popup in the shell that is a window (not a piece placed on the screen).
-- A preview of an on-screen piece inside a window (_rcSetStop) is not.
function RC:IsWindowText(region)
    local f, n = region and region.GetParent and region:GetParent(), 0
    while type(f) == "table" and n < 20 do
        if f._rcSetStop then return false end
        if f._rcSetRoot or f._rcWindow then return true end
        if f._rcShell then
            return (RC.UI and RC.UI.IsWindowShell and RC.UI:IsWindowShell(f)) and true or false
        end
        if not f.GetParent then return false end
        f = f:GetParent()
        n = n + 1
    end
    return false
end

function RC:ApplyCustomFont(fontString, size, outline)
    if not fontString or not fontString.SetFont then
        return false
    end

    local fontSize = size
    local fontOutline = outline

    if not fontSize then
        if self.db and self.db.fontSettings and self.db.fontSettings.fontSize then
            fontSize = self.db.fontSettings.fontSize
        else
            fontSize = 12
        end
    end

    if not fontOutline then
        local fs = self.db and self.db.fontSettings
        if fs and fs.fontFlags then
            fontOutline = fs.fontFlags
        elseif fs and fs.fontOutline then
            fontOutline = fs.fontOutline
        else
            fontOutline = "OUTLINE"
        end
    end

    local fontPath = self:GetFontPath()
    -- (beside ZacUI: a window's text wears ZacUI's face - see above)
    local zface = self:ZacUIFace()
    if zface and self:IsWindowText(fontString) then fontPath = LocaleSafeFont(zface) end

    if type(fontOutline) ~= "string" or fontOutline:upper() == "NONE" then
        fontOutline = ""
    end

    -- SetFont can fail silently on a bad path; GetFont() returning nil
    -- after the call is the only way to detect it, hence the fallback.
    local ok = TrySetFont(fontString, fontPath, fontSize, fontOutline)
    local success = not (ok == false or not fontString:GetFont())
    if not success then
        fontString:SetFont("Fonts\\FRIZQT__.TTF", fontSize, fontOutline)
    end

    fontString.wrFontSize = fontSize
    fontString.wrFontOutline = fontOutline
    -- the size and outline asked for last are the ones a font change
    -- re-applies (UpdateAllFonts reads _wrFontSize): a string built at one
    -- size and restyled at another used to snap back to the first size,
    -- or to 12, whenever the font was changed
    if size then fontString._wrFontSize = fontSize end
    if outline then fontString._wrFontOutline = fontOutline end

    -- ONE FONT: every string dressed here follows the Appearance > Fonts
    -- choice from now on - it joins RC.trackedFonts (once), and a change of
    -- font re-dresses it (UpdateAllFonts). The face it wears now is noted:
    -- a string something later gives a face of its own is left alone.
    fontString._rcFontSpec = nil
    fontString._rcFace = (fontString:GetFont())
    if not fontString._rcFontTracked then
        fontString._rcFontTracked = true
        table.insert(self.trackedFonts, fontString)
    end

    -- Font system loads after ADDON_LOADED but before other systems create
    -- their fontStrings; queue those calls until CompleteInitialization drains them.
    if not self.fontSystem.initialized then
        table.insert(self.fontSystem.pendingFontStrings, fontString)
    end

    return success
end

------------------------------------------------------------------------
-- PER-FEATURE FONTS AND TEXTURES
-- A feature with its own font saves a font spec (the standard shape):
--   { face = LSM font name, size = n, outline = flags, shadow = bool }
-- Any field may be nil. face nil / "" / "default" is the global Readycheck
-- font; size/outline/shadow nil fall back to the feature's `defaults`
-- table, then to the global base size / style. A texture setting is a
-- LibSharedMedia statusbar name; nil or "" is the global texture.
-- Strings and textures styled through these remember their spec, so a
-- change of the global font or texture re-applies them (and leaves a
-- feature's own choice alone).
--   RC:ResolveFontSpec(spec, defaults) -> path, size, flags, shadow
--   RC:ApplyFontSpec(fs, spec, defaults)
--   RC:ResolveTexture(name) -> path
--   RC:ApplyTextureSpec(texture, name)   a Texture region
--   RC:ApplyBarTexture(statusBar, name)  a StatusBar
------------------------------------------------------------------------
RC.FONT_OUTLINES = {
    { id = "",                    label = RCL["None"] },
    { id = "OUTLINE",             label = RCL["Outline"] },
    { id = "THICKOUTLINE",        label = RCL["Thick Outline"] },
    { id = "MONOCHROME",          label = RCL["Monochrome"] },
    { id = "OUTLINE, MONOCHROME", label = RCL["Outline + Mono"] },
}

-- ONE FONT: every Readycheck text wears the Appearance > Fonts font (ZacUI's
-- when ZacUI is installed - it pushes its font there). A face saved in a
-- feature's spec (the per-feature pickers of old) stays in the settings and
-- is ignored; the per-feature pickers show this note where the face was.
RC.ONE_FONT_NOTE = RCL["Uses Readycheck's font (Appearance > Fonts)"]

function RC:ResolveFontSpec(spec, defaults)
    spec = type(spec) == "table" and spec or {}
    defaults = type(defaults) == "table" and defaults or {}
    local fs = self.db and self.db.fontSettings
    local path = self:GetFontPath(nil)
    local size = tonumber(spec.size) or tonumber(defaults.size)
        or (fs and tonumber(fs.fontSize)) or 12
    local flags = spec.outline
    if flags == nil then flags = defaults.outline end
    if flags == nil then flags = (fs and (fs.fontFlags or fs.fontOutline)) or "OUTLINE" end
    if type(flags) ~= "string" or flags:upper() == "NONE" then flags = "" end
    local shadow = spec.shadow
    if shadow == nil then shadow = defaults.shadow end
    return path, size, flags, shadow and true or false
end

function RC:ApplyFontSpec(fontString, spec, defaults)
    if not fontString or not fontString.SetFont then return false end
    local path, size, flags, shadow = self:ResolveFontSpec(spec, defaults)
    local ok = TrySetFont(fontString, path, size, flags)
    if ok == false or not fontString:GetFont() then
        fontString:SetFont("Fonts\\FRIZQT__.TTF", size, flags)
    end
    if fontString.SetShadowOffset then
        if shadow then
            fontString:SetShadowOffset(1, -1)
            fontString:SetShadowColor(0, 0, 0, 1)
        else
            fontString:SetShadowOffset(0, 0)
        end
    end
    fontString._rcFontSpec = type(spec) == "table" and spec or false
    fontString._rcFontDefaults = defaults
    if not fontString._rcFontTracked then
        fontString._rcFontTracked = true
        table.insert(self.trackedFonts, fontString)
    end
    return true
end

function RC:ResolveTexture(name)
    if name == nil or name == "" then return self:GetTexturePath() end
    return self:GetTexturePath(name)
end

function RC:ApplyTextureSpec(texture, name)
    if not texture or not texture.SetTexture then return end
    texture:SetTexture(self:ResolveTexture(name))
    texture._rcTexName = (name ~= "" and name) or nil
    if not texture._rcTexTracked then
        texture._rcTexTracked = true
        table.insert(self.trackedTextures, texture)
    end
end

function RC:ApplyBarTexture(bar, name)
    if not bar or not bar.SetStatusBarTexture then return end
    bar:SetStatusBarTexture(self:ResolveTexture(name))
    local tex = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    if type(tex) == "table" then
        tex._rcTexName = (name ~= "" and name) or nil
        if not tex._rcTexTracked then
            tex._rcTexTracked = true
            table.insert(self.trackedTextures, tex)
        end
    end
end

local function CompleteInitialization()
    if not RC.db then
        C_Timer.After(0.5, CompleteInitialization)
        return
    end

    if not RC.db.fontSettings then
        RC.db.fontSettings = {
            selectedFont = "Friz Quadrata",
            fontSize = 12,
            fontOutline = "OUTLINE",
            selectedTexture = "Readycheck Smooth"
        }
    end

    if not RC.db.fontSettings.selectedTexture then
        RC.db.fontSettings.selectedTexture = "Readycheck Smooth"
    end
    -- textures that were listed without a file behind them
    local st = RC.db.fontSettings.selectedTexture
    if st == "Minimalist" or st == "Smooth" or st == "Flat" then
        RC.db.fontSettings.selectedTexture = "Readycheck Smooth"
    end

    RC.fontSystem.currentFont = RC.db.fontSettings.selectedFont or "Friz Quadrata"
    RC.fontSystem.currentTexture = RC.db.fontSettings.selectedTexture or "Readycheck Smooth"

    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    RC.LSM = LSM
    RC.fontSystem.useSharedMedia = (LSM ~= nil)

    if LSM then
        -- A registration that LibSharedMedia refuses (a file it cannot
        -- find, in the builds that check) must not take the rest of the
        -- list, or the addon's startup, with it: one line in debug and on.
        local function Register(kind, name, path)
            local ok, err = pcall(LSM.Register, LSM, kind, name, path)
            if not ok and RC.DebugPrint then
                RC:DebugPrint("LibSharedMedia refused " .. kind .. " '" .. tostring(name) .. "': " .. tostring(err), "system")
            end
            return ok
        end
        for fontName, fontData in pairs(RC.fontSystem.builtInFonts) do
            Register("font", fontName, fontData.path)
        end

        Register("font", "Red Hat Display", "Interface\\AddOns\\Readycheck\\Media\\Fonts\\RedHatDisplay-SemiBold.ttf")

        for textureName, textureData in pairs(RC.fontSystem.builtInTextures) do
            Register("statusbar", textureName, textureData.path)
        end

        -- Every sound Readycheck ships, offered to every sound picker that
        -- uses LibSharedMedia (ours and other addons'). "WR: Warning" is the
        -- old default name, kept so saved choices still play; its own file
        -- (Sounds\Warning.ogg) is not shipped, so it plays Announce.
        local SND = "Interface\\AddOns\\Readycheck\\Media\\Sounds\\"
        local addonSounds = {
            { name = "WR: Warning",                   file = SND .. "announce.ogg" },
            { name = "Readycheck: Air Horn",       file = SND .. "horn.ogg" },
            { name = "Readycheck: Access Allowed", file = SND .. "access.ogg" },
            { name = "Readycheck: Harp",           file = SND .. "harp.ogg" },
            { name = "Readycheck: Key Press",      file = SND .. "keypress.ogg" },
            { name = "Readycheck: Bell",           file = SND .. "bell.ogg" },
            { name = "Readycheck: Announce",       file = SND .. "announce.ogg" },
            { name = "Readycheck: Correct",        file = SND .. "correct.ogg" },
            { name = "Readycheck: Quick Tone",     file = SND .. "quicktone.ogg" },
            { name = "Readycheck: Pop Up",         file = SND .. "popup.ogg" },
            { name = "Readycheck: Elevator",       file = SND .. "elevator.ogg" },
            { name = "Readycheck: Level Bonus",    file = SND .. "levelbonus.ogg" },
            { name = "Readycheck: Guitar",         file = SND .. "guitar.ogg" },
            { name = "Readycheck: Happy Bells",    file = SND .. "happybells.ogg" },
            { name = "Readycheck: Select",         file = SND .. "select.ogg" },
            { name = "Readycheck: Marimba",        file = SND .. "marimba.ogg" },
            { name = "Readycheck: Magic Ring",     file = SND .. "magicring.ogg" },
            { name = "Readycheck: Flute",          file = SND .. "flute.ogg" },
            { name = "Readycheck: Remove",         file = SND .. "remove.ogg" },
            { name = "Readycheck: Start",          file = SND .. "start.ogg" },
            { name = "Readycheck: Reveal",         file = SND .. "reveal.ogg" },
            { name = "Readycheck: Unlock",         file = SND .. "unlock.ogg" },
            { name = "Readycheck: Win",            file = SND .. "win.ogg" },
            { name = "Readycheck: Wrong Answer",   file = SND .. "wrong.ogg" },
        }
        for _, s in ipairs(addonSounds) do
            Register("sound", s.name, s.file)
        end

        if RC.DebugPrint then
            RC:DebugPrint("LibSharedMedia-3.0 found - registered fonts and sounds", "system")
        end
    end

    RC.fontSystem.initialized = true

    -- Drain anything ApplyCustomFont queued before init finished.
    for _, fontString in ipairs(RC.fontSystem.pendingFontStrings) do
        if fontString and fontString.SetFont and fontString:GetParent() then
            local size = fontString.wrFontSize or 12
            local outline = fontString.wrFontOutline or "OUTLINE"
            RC:ApplyCustomFont(fontString, size, outline)
        end
    end
    RC.fontSystem.pendingFontStrings = {}

    if RC.UpdateAllFonts then
        RC:UpdateAllFonts()
    end

    if RC.DebugPrint then
        local fontCount = 0
        if RC.GetAvailableFonts then
            fontCount = #RC:GetAvailableFonts()
        end
        RC:DebugPrint("Font system fully initialized with " .. fontCount .. " fonts", "system")
    end
end

function RC:GetAvailableFonts()
    local fonts = {}
    local fontSet = {}

    if self.LSM then
        local smFonts = self.LSM:HashTable("font")
        if smFonts then
            for fontName, _ in pairs(smFonts) do
                if not fontSet[fontName] then
                    table.insert(fonts, fontName)
                    fontSet[fontName] = true
                end
            end
        end
    else
        for fontName, _ in pairs(self.fontSystem.builtInFonts) do
            if not fontSet[fontName] then
                table.insert(fonts, fontName)
                fontSet[fontName] = true
            end
        end
    end

    table.sort(fonts)
    return fonts
end

function RC:GetTexturePath(textureName)
    if not textureName then
        if self.db and self.db.fontSettings and self.db.fontSettings.selectedTexture then
            textureName = self.db.fontSettings.selectedTexture
        else
            textureName = "Readycheck Smooth"
        end
    end

    if self.LSM then
        local path = self.LSM:Fetch("statusbar", textureName)
        if path then
            return path
        end
    end

    if self.fontSystem.builtInTextures[textureName] then
        return self.fontSystem.builtInTextures[textureName].path
    end

    return "Interface\\AddOns\\Readycheck\\Media\\normTex"
end

function RC:GetAvailableTextures()
    local textures = {}
    local textureSet = {}

    if self.LSM then
        local smTextures = self.LSM:HashTable("statusbar")
        if smTextures then
            for textureName, _ in pairs(smTextures) do
                if not textureSet[textureName] then
                    table.insert(textures, textureName)
                    textureSet[textureName] = true
                end
            end
        end
    else
        for textureName, _ in pairs(self.fontSystem.builtInTextures) do
            if not textureSet[textureName] then
                table.insert(textures, textureName)
                textureSet[textureName] = true
            end
        end
    end

    table.sort(textures)
    return textures
end

function RC:SetTexture(textureName)
    local texturePath = self:GetTexturePath(textureName)

    if texturePath then
        if self.db and self.db.fontSettings then
            self.db.fontSettings.selectedTexture = textureName
        end
        self.fontSystem.currentTexture = textureName

        if self.SaveConfigurationToProfile then
            self:SaveConfigurationToProfile()
        end

        self:UpdateAllTextures()

        return true
    else
        return false
    end
end

function RC:UpdateAllTextures()
    local texturePath = self:GetTexturePath()
    local updatedCount = 0

    local validTextures = {}
    for _, textureObj in ipairs(self.trackedTextures or {}) do
        if textureObj and textureObj.SetTexture and textureObj:GetParent() then
            -- a feature's own texture choice survives a global change
            textureObj:SetTexture(textureObj._rcTexName and self:ResolveTexture(textureObj._rcTexName) or texturePath)
            table.insert(validTextures, textureObj)
            updatedCount = updatedCount + 1
        end
    end
    self.trackedTextures = validTextures

    if self.sidebarConfigFrame then
        if self.sidebarConfigFrame.titleBg then
            self.sidebarConfigFrame.titleBg:SetTexture(texturePath)
            updatedCount = updatedCount + 1
        end
    end

    if self.CharacterStats and self.CharacterStats.panelFrame then
        local pf = self.CharacterStats.panelFrame
        if pf.headerBar and pf.headerBar.bg then
            pf.headerBar.bg:SetTexture(texturePath)
            updatedCount = updatedCount + 1
        end
    end
    -- (the on-screen stats bar is a flat panel and takes no bar texture)

    if self.consumablesChecker and self.consumablesChecker.frame then
        if self.consumablesChecker.frame.headerBar and self.consumablesChecker.frame.headerBar.bg then
            self.consumablesChecker.frame.headerBar.bg:SetTexture(texturePath)
            updatedCount = updatedCount + 1
        end
    end

    if self.trinketToggleButton and self.trinketToggleButton.buttonBg then
        self.trinketToggleButton.buttonBg:SetTexture(texturePath)
        updatedCount = updatedCount + 1
    end

    if self.IconPicker and self.IconPicker.frame and self.IconPicker.frame:IsShown() then
        if self.IconPicker.frame.headerBg then
            self.IconPicker.frame.headerBg:SetTexture(texturePath)
            updatedCount = updatedCount + 1
        end
    end

    if self.sidebarConfigFrame and self.sidebarConfigFrame.sidebar and self.sidebarConfigFrame.sidebar.buttons then
        local SIDEBAR = self.SIDEBAR or {
            BUTTON_NORMAL = {r = 0.08, g = 0.08, b = 0.08, a = 1},
            BUTTON_SELECTED = {r = 0.12, g = 0.22, b = 0.12, a = 1}
        }
        for _, button in ipairs(self.sidebarConfigFrame.sidebar.buttons) do
            if button and button.SetBackdrop then
                button:SetBackdrop({
                    bgFile = texturePath,
                    edgeFile = "Interface\\Buttons\\WHITE8X8",
                    edgeSize = 1,
                })
                if button.isSelected then
                    button:SetBackdropColor(SIDEBAR.BUTTON_SELECTED.r, SIDEBAR.BUTTON_SELECTED.g, SIDEBAR.BUTTON_SELECTED.b, 1)
                    button:SetBackdropBorderColor(0, 0, 0, 1)
                else
                    button:SetBackdropColor(SIDEBAR.BUTTON_NORMAL.r, SIDEBAR.BUTTON_NORMAL.g, SIDEBAR.BUTTON_NORMAL.b, SIDEBAR.BUTTON_NORMAL.a)
                    button:SetBackdropBorderColor(0, 0, 0, 1)
                end
                updatedCount = updatedCount + 1
            end
        end
    end

    if self.sidebarConfigFrame and self.sidebarConfigFrame:IsShown() and self.sidebarConfigFrame.currentPanel then
        local currentPanel = self.sidebarConfigFrame.currentPanel
        if currentPanel and self[currentPanel] then
            C_Timer.After(0.05, function()
                if self[currentPanel] then
                    self[currentPanel](self, self.sidebarConfigFrame, true)
                end
            end)
        end
    end

    if self.DebugPrint then
        self:DebugPrint("Updated " .. updatedCount .. " texture elements", "system")
    end
end

function RC:SetFont(fontName)
    local fontPath = self:GetFontPath(fontName)

    -- Bad paths fail silently (see ApplyCustomFont); probe with a
    -- throwaway frame so a broken font choice never gets committed.
    local testFrame = CreateFrame("Frame", nil, UIParent)
    local testText = testFrame:CreateFontString(nil, "OVERLAY")

    local ok = TrySetFont(testText, fontPath, 12, "OUTLINE")
    local success = (ok ~= false) and (testText:GetFont() ~= nil)

    testFrame:Hide()

    if success then
        if self.db and self.db.fontSettings then
            self.db.fontSettings.selectedFont = fontName
        end
        self.fontSystem.currentFont = fontName

        if self.SaveConfigurationToProfile then
            self:SaveConfigurationToProfile()
        end

        self:UpdateAllFonts()

        return true
    else
        self:Print(RCL["Font '"] .. tostring(fontName)
            .. RCL["' could not be loaded (file missing or unreadable) - keeping "]
            .. tostring(self.fontSystem.currentFont) .. ".")
        return false
    end
end

-- A settings page is thrown away on every rebuild (RC:ClearSidebarContent
-- marks what it drops with _rcDiscarded); the client keeps those frames,
-- but their font strings need no font refresh ever again. A string whose
-- topmost parent is such a thrown-away frame leaves RC.trackedFonts here.
-- Cheap enough to call on every page clear: it only walks the list once
-- it has grown by half since the last walk (force = walk now).
function RC:PruneTrackedFonts(force)
    local list = self.trackedFonts
    if type(list) ~= "table" then return 0 end
    local n = #list
    if not force and n < (self._rcFontsPrunedAt or 0) * 1.5 + 400 then return 0 end
    local topDead = {}       -- [frame] = true / false (memo per walk)
    local function Dead(fs)
        local p = fs.GetParent and fs:GetParent()
        if not p then return false end
        local chain, d, verdict = {}, 0, nil
        while p and d < 50 do
            local m = topDead[p]
            if m ~= nil then verdict = m break end
            chain[#chain + 1] = p
            local up = p.GetParent and p:GetParent()
            if not up then verdict = rawget(p, "_rcDiscarded") == true break end
            p = up
            d = d + 1
        end
        verdict = verdict and true or false
        for _, f in ipairs(chain) do topDead[f] = verdict end
        return verdict
    end
    local keep, seen, dropped = {}, {}, 0
    for i = 1, n do
        local fs = list[i]
        if fs and not seen[fs] then
            seen[fs] = true
            if Dead(fs) then dropped = dropped + 1 else keep[#keep + 1] = fs end
        end
    end
    self.trackedFonts = keep
    self._rcFontsPrunedAt = #keep
    return dropped
end

-- Re-dresses the tracked strings under one frame (a popup the first time
-- it shows: it was built before it was in the shell).
function RC:RedressWindowFonts(root)
    if not root or not self:ZacUIFace() then return 0 end
    local n = 0
    local function Walk(f, depth)
        if depth > 12 or f._rcSetStop then return end
        if f.GetRegions then
            for _, r in ipairs({ f:GetRegions() }) do
                if r._rcFontTracked and r._rcFontSpec == nil and r.GetFont
                    and (r._rcFace == nil or r:GetFont() == r._rcFace) then
                    self:ApplyCustomFont(r, r._wrFontSize or r.wrFontSize or 12, r._wrFontOutline or r.wrFontOutline or "OUTLINE")
                    n = n + 1
                end
            end
        end
        if f.GetChildren then
            for _, c in ipairs({ f:GetChildren() }) do Walk(c, depth + 1) end
        end
    end
    Walk(root, 0)
    return n
end

-- What of ZacUI's this follows, as one string: its font file and the
-- colours picked there that Readycheck's windows take (RC.ZACUI_COLORS).
local function ZacUISignature()
    local parts = { tostring(RC:ZacUIFace()) }
    if RC.ZacUIColor and RC.ZACUI_COLORS then
        for _, key in ipairs(RC.ZACUI_COLOR_ORDER or {}) do
            local c = RC:ZacUIColor("settings", key)
            parts[#parts + 1] = c and string.format("%s=%.3f,%.3f,%.3f", key, c.r, c.g, c.b) or (key .. "=-")
        end
    end
    -- (the finish, button depth and main button followed from ZacUI:
    -- UIF_Base RC.UI:Look)
    if RC.UI and RC.UI.LookSignature then parts[#parts + 1] = RC.UI:LookSignature() end
    return table.concat(parts, "|")
end

-- Asked when a window opens (the /rc window, a popup). Cheap when nothing
-- changed: one string compared.
function RC:FollowZacUI()
    if type(_G.ZacUI) ~= "table" then return false end
    local sig = ZacUISignature()
    if sig == self._zacuiSig then return false end
    local first = self._zacuiSig == nil
    local wasFace = self._zacuiFace
    self._zacuiSig = sig
    self._zacuiFace = self:ZacUIFace()
    -- (the first look only notes what is there: everything built so far
    -- was dressed with it already)
    if first then return false end
    if wasFace ~= self._zacuiFace and self.UpdateAllFonts then self:UpdateAllFonts() end
    if self.UI and self.UI.RepaintPlates then self.UI:RepaintPlates() end
    if self.RefreshUIColors then self:RefreshUIColors() end
    self:DebugPrint("ZacUI's look changed: windows re-dressed", "ui")
    return true
end

function RC:UpdateAllFonts()
    local updatedCount = 0
    if self.PruneTrackedFonts then self:PruneTrackedFonts(true) end

    local baseFontSize = (self.db and self.db.fontSettings and self.db.fontSettings.fontSize) or 12

    -- The client never destroys frames, so a GetParent()==nil prune can
    -- never fire; the real growth risk is the same FontString being
    -- registered into trackedFonts more than once. Rebuild the list
    -- deduplicated on every pass so repeat registrations collapse here.
    local validFonts, seen = {}, {}
    for _, fontString in ipairs(self.trackedFonts or {}) do
        if fontString and fontString.SetFont and not seen[fontString] then
            seen[fontString] = true
            if fontString._rcFontSpec ~= nil then
                self:ApplyFontSpec(fontString, fontString._rcFontSpec or nil, fontString._rcFontDefaults)
            elseif fontString._rcFace == nil or fontString:GetFont() == fontString._rcFace then
                -- (one given a face of its own since is not ours to redo)
                local size = fontString._wrFontSize or fontString.wrFontSize or 12
                local outline = fontString._wrFontOutline or fontString.wrFontOutline or "OUTLINE"
                self:ApplyCustomFont(fontString, size, outline)
            end
            table.insert(validFonts, fontString)
            updatedCount = updatedCount + 1
        end
    end
    self.trackedFonts = validFonts

    -- (reminder icon labels carry their own font spec and were restyled
    -- by the loop above)

    if self.ttsFrame then
        if self.ttsFrame.text then
            self:ApplyCustomFont(self.ttsFrame.text, baseFontSize + 2)
            updatedCount = updatedCount + 1
        end
        if self.ttsFrame.label then
            self:ApplyCustomFont(self.ttsFrame.label, baseFontSize - 2)
            updatedCount = updatedCount + 1
        end
    end

    if self.UpdateTrinketToggleButtonFont then
        self:UpdateTrinketToggleButtonFont()
        updatedCount = updatedCount + 1
    end

    if self.CharacterStats and self.CharacterStats.RefreshStatsBar then
        self.CharacterStats:RefreshStatsBar()
        updatedCount = updatedCount + 1
    end

    if self.UpdateEquipmentReminderFontSize then
        self:UpdateEquipmentReminderFontSize()
        updatedCount = updatedCount + 1
    end

    if self.GearManager and self.GearManager.RefreshAllButtonFonts then
        self.GearManager:RefreshAllButtonFonts()
        updatedCount = updatedCount + 1
    end

    if self.consumablesHelper and self.consumablesHelper.buttons then
        for itemId, button in pairs(self.consumablesHelper.buttons) do
            if button then
                if button.nameLabel then self:ApplyCustomFont(button.nameLabel, 7, "OUTLINE") end
                if button.count then self:ApplyCustomFont(button.count, 12, "OUTLINE") end
                if button.gcdText then self:ApplyCustomFont(button.gcdText, 22, "OUTLINE") end
                if button.expiryText then self:ApplyCustomFont(button.expiryText, 18, "OUTLINE") end
                if button.durationText then self:ApplyCustomFont(button.durationText, 22, "OUTLINE") end
                if button.cooldownText then self:ApplyCustomFont(button.cooldownText, 20, "OUTLINE") end
                if button.slotLabel then self:ApplyCustomFont(button.slotLabel, 9, "OUTLINE") end
                if button.absorbText then self:ApplyCustomFont(button.absorbText, 9, "OUTLINE") end
                updatedCount = updatedCount + 1
            end
        end
    end

    if self.potionsBar and self.potionsBar.buttons then
        for itemId, button in pairs(self.potionsBar.buttons) do
            if button then
                if button.nameLabel then self:ApplyCustomFont(button.nameLabel, 7, "OUTLINE") end
                if button.count then self:ApplyCustomFont(button.count, 12, "OUTLINE") end
                if button.gcdText then self:ApplyCustomFont(button.gcdText, 22, "OUTLINE") end
                if button.expiryText then self:ApplyCustomFont(button.expiryText, 18, "OUTLINE") end
                if button.durationText then self:ApplyCustomFont(button.durationText, 22, "OUTLINE") end
                if button.cooldownText then self:ApplyCustomFont(button.cooldownText, 20, "OUTLINE") end
                if button.slotLabel then self:ApplyCustomFont(button.slotLabel, 9, "OUTLINE") end
                updatedCount = updatedCount + 1
            end
        end
    end

    if self.consumablesChecker and self.consumablesChecker.frame then
        if self.consumablesChecker.frame.title then
            self:ApplyCustomFont(self.consumablesChecker.frame.title, 12)
            updatedCount = updatedCount + 1
        end
        if self.PopulateConsumablesChecker then
            self:PopulateConsumablesChecker()
            updatedCount = updatedCount + 1
        end
    end

    if self.sidebarConfigFrame and self.sidebarConfigFrame:IsShown() and self.sidebarConfigFrame.currentPanel then
        local currentPanel = self.sidebarConfigFrame.currentPanel
        if currentPanel and self[currentPanel] then
            C_Timer.After(0.05, function()
                if self[currentPanel] then
                    self[currentPanel](self, self.sidebarConfigFrame, true)
                end
            end)
        end
    end

    if self.DebugPrint then
        self:DebugPrint("Updated " .. updatedCount .. " font elements (base size: " .. baseFontSize .. ")", "system")
    end
end

C_Timer.After(0.1, CompleteInitialization)

if RC.DebugPrint then
    RC:DebugPrint("FontSystem core loaded (immediate)", "system")
end
