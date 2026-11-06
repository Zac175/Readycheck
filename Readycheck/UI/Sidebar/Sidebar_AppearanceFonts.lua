------------------------------------------------------------------------
-- Readycheck - Appearance: Fonts / Textures
-- Fonts, Textures, Colors (ShowAppearanceColorsContent) and Motion
-- (ShowAppearanceMotionContent) sub-tabs of the Appearance settings page.
-- Edits db.fontSettings (selectedFont, fontSize, fontFlags,
-- selectedTexture, mainWindowBgOpacity). The preview pane shows the
-- result on a miniature of the window (Sidebar_AppearanceMotion.lua).
--
-- RC:ApplyCustomFont(fs,size) resolves the font file: LSM:Fetch("font",
-- selectedFont) first, then a built-in font table, then FRIZQT__.TTF as a
-- last resort. For ruRU/koKR/zhCN/zhTW clients it silently swaps to
-- STANDARD_TEXT_FONT when the resolved file can't render CJK/Cyrillic
-- glyphs (custom TTFs render as boxes there).
-- Font/size/style changes call RC:UpdateAllFonts(), which restyles every
-- fontstring in RC.trackedFonts plus a fixed list of module refresh hooks -
-- new fontstrings must be added to RC.trackedFonts to stay in sync.
------------------------------------------------------------------------
-- Taint-safe API locals (fallbacks on RC.Compat, built in Core; never write _G)
local RCC = _G.Readycheck
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
RC._sbs = RC._sbs or {}
local _sbs = RC._sbs

    function RC:ShowSidebarFontSettings(frame, preserveScroll)
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local parent = frame.scrollChild
        local yPos = -20
        local P = self.DeclareAppearancePreview and self:DeclareAppearancePreview()

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Appearance"],
            RCL["Customize fonts, textures, colors and motion"], "Interface\\Icons\\INV_Scroll_08")
        yPos = newY

        local _, newTabY = self.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = {
                { key = "fonts",    label = RCL["Fonts"]    },
                { key = "textures", label = RCL["Textures"] },
                { key = "colors",   label = RCL["Colors"]   },
                { key = "motion",   label = RCL["Motion"]   },
            },
            selected = RC.appearanceTab,
            onClick = function(tk)
                RC.appearanceTab = tk
                RC:ShowSidebarFontSettings(frame, true)
            end,
            advance = 38,
            -- the framework's tab look (no palette override: the old green
            -- open-tab palette here was the one place left with it)
        })
        yPos = newTabY

        if RC.appearanceTab == "fonts" then
            yPos = self:ShowAppearanceFontsContent(parent, yPos, frame)
        elseif RC.appearanceTab == "textures" then
            yPos = self:ShowAppearanceTexturesContent(parent, yPos, frame)
        elseif RC.appearanceTab == "colors" then
            yPos = self:ShowAppearanceColorsContent(parent, yPos, frame)
        elseif RC.appearanceTab == "motion" then
            yPos = self:ShowAppearanceMotionContent(parent, yPos, frame, P)
        end

        if self.UpdateSidebarScrollbar then
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
        end
    end

    function RC:ShowAppearanceFontsContent(parent, yPos, frame)
        local cardY

        local txtNorm = self:GetColor("text", "normal")
        local txtGray = self:GetColor("text", "gray")
        local txtGreen = self:GetColor("text", "green")

        if self.LSM then
            local smCard = self:CreateSettingsCard(parent, yPos, RCL["SharedMedia integration"])
            cardY = -32

            -- Status word in text.green, detail in text.gray: two font
            -- strings instead of an inline colour code so both follow the theme.
            local smState = self:CreateFontString(smCard, "OVERLAY", nil, 11)
            smState:SetPoint("TOPLEFT", smCard, "TOPLEFT", 14, cardY)
            smState:SetText(RCL["Active"])
            smState:SetTextColor(txtGreen.r, txtGreen.g, txtGreen.b)

            local smStatus = self:CreateFontString(smCard, "OVERLAY", nil, 11)
            smStatus:SetPoint("LEFT", smState, "RIGHT", 4, 0)
            smStatus:SetText(RCL["- Fonts from ElvUI and other addons are available"])
            smStatus:SetTextColor(txtGray.r, txtGray.g, txtGray.b)
            cardY = cardY - 15

            smCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - smCard:GetHeight() - 15
        end

        -- The selected font is shown by the Font Family dropdown itself,
        -- so there is no separate "Current Font" card.
        local currentFontName = self.db.fontSettings and self.db.fontSettings.selectedFont or "Friz Quadrata"

        local selectCard = self:CreateSettingsCard(parent, yPos, RCL["Font"])
        cardY = -32

        local fontLabel = self:CreateFontString(selectCard, "OVERLAY", nil, 11)
        fontLabel:SetPoint("TOPLEFT", selectCard, "TOPLEFT", 14, cardY)
        fontLabel:SetText(RCL["Font Family"])
        fontLabel:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b)
        cardY = cardY - 25

        local availableFonts = self.GetAvailableFonts and self:GetAvailableFonts() or {"Friz Quadrata", "Arial Narrow", "Morpheus", "Skurri"}

        local fontDropdown = self.UI:CreateScrollableDropdown(selectCard, 280, currentFontName, 5)
        fontDropdown:SetPoint("TOPLEFT", selectCard, "TOPLEFT", 14, cardY)

        local fontItems = {}
        for _, fontName in ipairs(availableFonts) do
            table.insert(fontItems, {text = fontName, value = fontName})
        end

        -- self.SetFont (when present) already writes db.fontSettings and
        -- calls UpdateAllFonts; the else branch is only a fallback path.
        fontDropdown:SetItems(fontItems, function(value, displayText)
            if self.SetFont then
                self:SetFont(value)
            else
                if not self.db.fontSettings then self.db.fontSettings = {} end
                self.db.fontSettings.selectedFont = value
                if self.UpdateAllFonts then self:UpdateAllFonts() end
            end
            self:SaveConfigurationToProfile()
        end, { fontPreview = true })
        cardY = cardY - 45

        local fontCountLabel = self:CreateFontString(selectCard, "OVERLAY", nil, 10)
        fontCountLabel:SetPoint("TOPLEFT", selectCard, "TOPLEFT", 310, cardY + 35)
        fontCountLabel:SetText(#availableFonts .. RCL[" fonts available"])
        fontCountLabel:SetTextColor(txtGray.r, txtGray.g, txtGray.b)

        local sizeLabel = self:CreateFontString(selectCard, "OVERLAY", nil, 11)
        sizeLabel:SetPoint("TOPLEFT", selectCard, "TOPLEFT", 14, cardY)
        sizeLabel:SetText(RCL["Base Size"])
        sizeLabel:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b)
        cardY = cardY - 22

        local fontSize = (self.db.fontSettings and self.db.fontSettings.fontSize) or 12
        local fontSizeSlider = self.UI:CreateSlider(selectCard, 8, 24, fontSize, 1)
        fontSizeSlider:SetPoint("TOPLEFT", selectCard, "TOPLEFT", 14, cardY)
        fontSizeSlider.Text:SetText(fontSize .. RCL[" pt"])

        fontSizeSlider:SetScript("OnValueChanged", function(slider, value)
            value = math.floor(value)
            if not self.db.fontSettings then self.db.fontSettings = {} end
            self.db.fontSettings.fontSize = value
            slider.Text:SetText(value .. RCL[" pt"])
            if self.UpdateAllFonts then self:UpdateAllFonts() end
            if slider.saveTimer then slider.saveTimer:Cancel() end
            slider.saveTimer = C_Timer.NewTimer(0.5, function() self:SaveConfigurationToProfile() end)
        end)
        cardY = cardY - 45

        local styleLabel = self:CreateFontString(selectCard, "OVERLAY", nil, 11)
        styleLabel:SetPoint("TOPLEFT", selectCard, "TOPLEFT", 14, cardY)
        styleLabel:SetText(RCL["Style"])
        styleLabel:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b)
        cardY = cardY - 25

        local styleDropdown = self.UI:CreateScrollableDropdown(selectCard, 200, RCL["Select Style..."], 8)
        styleDropdown:SetPoint("TOPLEFT", selectCard, "TOPLEFT", 14, cardY)

        local currentStyle = (self.db.fontSettings and self.db.fontSettings.fontFlags) or "OUTLINE"
        local styleNames = {[""] = "None", ["OUTLINE"] = "Outline", ["THICKOUTLINE"] = "Thick Outline", ["MONOCHROME"] = "Monochrome", ["OUTLINE, MONOCHROME"] = "Outline + Mono"}
        do
            local styles = {
                {value = "", name = "None"},
                {value = "OUTLINE", name = "Outline"},
                {value = "THICKOUTLINE", name = "Thick Outline"},
                {value = "MONOCHROME", name = "Monochrome"},
                {value = "OUTLINE, MONOCHROME", name = "Outline + Mono"},
            }
            local styleItems = {}
            for _, style in ipairs(styles) do
                table.insert(styleItems, { text = style.name, value = style.value })
            end
            styleDropdown:SetItems(styleItems, function(value)
                if not self.db.fontSettings then self.db.fontSettings = {} end
                self.db.fontSettings.fontFlags = value
                if self.UpdateAllFonts then self:UpdateAllFonts() end
                self:SaveConfigurationToProfile()
            end)
            styleDropdown:SetSelectedValue(currentStyle, styleNames[currentStyle] or "Outline")
        end
        cardY = cardY - 45

        selectCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - selectCard:GetHeight() - 15

        local actionsCard = self:CreateSettingsCard(parent, yPos, RCL["Actions"])
        cardY = -32

        local resetFontButton = self.UI:CreateDynamicButton(actionsCard, "Reset Fonts to Default", 26, 12, 80)
        resetFontButton:SetPoint("TOPLEFT", actionsCard, "TOPLEFT", 14, cardY)
        -- Writes the sentinel "default" here; the no-fontSettings fallback
        -- above reads "Friz Quadrata" instead - two different default
        -- strings for the same reset state.
        resetFontButton:SetScript("OnClick", function()
            RC.UI:CreateConfirmDialog(RCL["Reset Fonts"],
                RCL["Reset the font, size and style back to the defaults?"],
                function()
                    if not self.db.fontSettings then self.db.fontSettings = {} end
                    self.db.fontSettings.selectedFont = "default"
                    self.db.fontSettings.fontSize = 12
                    self.db.fontSettings.fontFlags = "OUTLINE"
                    if self.UpdateAllFonts then self:UpdateAllFonts() end
                    self:ClearSidebarContent(self.sidebarConfigFrame, true)
                    self:ShowSidebarFontSettings(frame, true)
                    self:SaveConfigurationToProfile()
                end,
                nil, RCL["Reset"], true)
        end)
        cardY = cardY - 20

        actionsCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - actionsCard:GetHeight() - 20

        return yPos
    end

    function RC:ShowAppearanceTexturesContent(parent, yPos, frame)
        local cardY

        local txtNorm = self:GetColor("text", "normal")
        local txtGray = self:GetColor("text", "gray")

        local textureCard = self:CreateSettingsCard(parent, yPos, RCL["Texture"])
        cardY = -32

        local textureLabel = self:CreateFontString(textureCard, "OVERLAY", nil, 11)
        textureLabel:SetPoint("TOPLEFT", textureCard, "TOPLEFT", 14, cardY)
        textureLabel:SetText(RCL["Status Bar Texture"])
        textureLabel:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b)
        cardY = cardY - 25

        local availableTextures = self.GetAvailableTextures and self:GetAvailableTextures() or {"Readycheck Smooth", "Blizzard", "Solid"}
        local currentTextureName = self.db.fontSettings and self.db.fontSettings.selectedTexture or "Readycheck Smooth"

        local textureDropdown = self.UI:CreateScrollableDropdown(textureCard, 280, currentTextureName, 5)
        textureDropdown:SetPoint("TOPLEFT", textureCard, "TOPLEFT", 14, cardY)

        local textureItems = {}
        for _, textureName in ipairs(availableTextures) do
            table.insert(textureItems, {text = textureName, value = textureName})
        end

        textureDropdown:SetItems(textureItems, function(value, displayText)
            if self.SetTexture then
                self:SetTexture(value)
            else
                if not self.db.fontSettings then self.db.fontSettings = {} end
                self.db.fontSettings.selectedTexture = value
            end
            self:SaveConfigurationToProfile()
            self:ClearSidebarContent(self.sidebarConfigFrame, true)
            self:ShowSidebarFontSettings(frame, true)
        end)
        cardY = cardY - 45

        local textureCountLabel = self:CreateFontString(textureCard, "OVERLAY", nil, 10)
        textureCountLabel:SetPoint("TOPLEFT", textureCard, "TOPLEFT", 310, cardY + 35)
        textureCountLabel:SetText(#availableTextures .. RCL[" textures available"])
        textureCountLabel:SetTextColor(txtGray.r, txtGray.g, txtGray.b)

        -- (the texture is shown on the window's bar in the preview pane)

        textureCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - textureCard:GetHeight() - 15

        local actionsCard = self:CreateSettingsCard(parent, yPos, RCL["Actions"])
        cardY = -32

        local resetTextureButton = self.UI:CreateDynamicButton(actionsCard, "Reset Texture to Default", 26, 12, 80)
        resetTextureButton:SetPoint("TOPLEFT", actionsCard, "TOPLEFT", 14, cardY)
        resetTextureButton:SetScript("OnClick", function()
            RC.UI:CreateConfirmDialog(RCL["Reset Texture"],
                RCL["Reset the status bar texture back to the default?"],
                function()
                    if not self.db.fontSettings then self.db.fontSettings = {} end
                    self.db.fontSettings.selectedTexture = "Readycheck Smooth"
                    self:SaveConfigurationToProfile()
                    self:ClearSidebarContent(self.sidebarConfigFrame, true)
                    self:ShowSidebarFontSettings(frame, true)
                end,
                nil, RCL["Reset"], true)
        end)
        cardY = cardY - 20

        actionsCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - actionsCard:GetHeight() - 20

        return yPos
    end

    -- Migrates pre-rename sub-tab keys (persisted in RC.colorSubTab from
    -- older sessions) to the current core/bars/raid set.
    do
        local map = { interface = "core", content = "core",
                      actionbars = "bars", features = "raid" }
        RC.colorSubTab = map[RC.colorSubTab] or RC.colorSubTab or "core"
        if RC.colorSubTab ~= "core" and RC.colorSubTab ~= "bars"
           and RC.colorSubTab ~= "raid" then
            RC.colorSubTab = "core"
        end
    end
