local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_sort = table.insert, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbc = RC._sbc or {}
local _sbc = RC._sbc
local GetTabHoverBg, GetTabNormalBg, GetTabNormalText, GetTabSelectedBg, GetTabSelectedText, MakeSayBox, TEXT = _sbc.GetTabHoverBg, _sbc.GetTabNormalBg, _sbc.GetTabNormalText, _sbc.GetTabSelectedBg, _sbc.GetTabSelectedText, _sbc.MakeSayBox, _sbc.TEXT
------------------------------------------------------------------------
-- Readycheck - Consumables Bar Settings
-- Behavior/Items/Order/Quick use/Look/Text/Animation/Sound/Position tabs
-- edit db.consumablesHelper (Look/Text/Animation/Position and the pane
-- preview are the shared bar builders in Cons_BarStyle.lua). Item rows use consumablesHelper.consumableTTSSettings
-- (shared with the potions bar and weapons bar rows, keyed by item id)
-- and MakeSayBox (Cons_Base.lua) for the optional custom TTS text.
-- 999901/999902/999903 are pseudo item ids standing in for the Main
-- Hand/Off Hand enchant slots and Bag Weapons in hiddenItems/itemOrder -
-- not real WoW item ids.
------------------------------------------------------------------------

local function CachedIcon(id)
    return RC:GetCachedItemIcon(id)
end

-- Shared "Order"-tab drag-to-reorder handle, used by this page and the
-- potions bar page (Cons_PotionsCfg.lua) via RC._sbc.CreateOrderDragHandle.
-- Builds the up/down-arrow handle on itemRow and wires the whole drag:
-- dragState is the page's persistent state table (must carry .indicator),
-- itemRows the ordered row frames, availableItems the ordered item list
-- ({ baseId = ... } entries). onCommit(newOrder) persists the reordered
-- baseId list and refreshes the page.
local function CreateOrderDragHandle(itemRow, dragState, itemRows, availableItems, onCommit)
    local normBg = _sbc.GetTabNormalBg()
    local hoverBg = _sbc.GetTabHoverBg()

    local dragHandle = CreateFrame("Frame", nil, itemRow)
    dragHandle:SetSize(20, 24)
    dragHandle:SetPoint("LEFT", itemRow, "LEFT", 0, 0)
    dragHandle:EnableMouse(true)

    local handleBg = dragHandle:CreateTexture(nil, "BACKGROUND")
    handleBg:SetAllPoints()
    handleBg:SetColorTexture(normBg.r, normBg.g, normBg.b, 0.5)
    dragHandle.bg = handleBg

    local upArrow = dragHandle:CreateTexture(nil, "ARTWORK")
    upArrow:SetSize(8, 8)
    upArrow:SetPoint("CENTER", dragHandle, "CENTER", 0, 5)
    upArrow:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrowUp")
    local downArrow = dragHandle:CreateTexture(nil, "ARTWORK")
    downArrow:SetSize(8, 8)
    downArrow:SetPoint("CENTER", dragHandle, "CENTER", 0, -5)
    downArrow:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrow")
    do local _gc = RC:GetColor("buttons", "xNormal"); upArrow:SetVertexColor(_gc.r, _gc.g, _gc.b, 1); downArrow:SetVertexColor(_gc.r, _gc.g, _gc.b, 1) end
    dragHandle.upArrow = upArrow
    dragHandle.downArrow = downArrow

    dragHandle:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(hoverBg.r, hoverBg.g, hoverBg.b, 0.85)
        local _ag = RC:GetColor("ui", "accentGold")
        self.upArrow:SetVertexColor(_ag.r, _ag.g, _ag.b, 1)
        self.downArrow:SetVertexColor(_ag.r, _ag.g, _ag.b, 1)
    end)
    dragHandle:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(normBg.r, normBg.g, normBg.b, 0.5)
        local _gc = RC:GetColor("buttons", "xNormal")
        self.upArrow:SetVertexColor(_gc.r, _gc.g, _gc.b, 1)
        self.downArrow:SetVertexColor(_gc.r, _gc.g, _gc.b, 1)
    end)

    dragHandle:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            dragState.dragging = true
            dragState.sourceIndex = itemRow.index
            dragState.sourceItemId = itemRow.itemId
            dragState.rows = itemRows
            dragState.items = availableItems

            -- OnUpdate is scoped to the drag gesture only: set here,
            -- cleared on mouse-up and on hide below.
            self:SetScript("OnUpdate", function()
                if not dragState.dragging then return end
                local indicator = dragState.indicator
                local _, cy = GetCursorPosition()
                local scale = UIParent:GetEffectiveScale()
                cy = cy / scale
                local insertIndex = nil
                for idx, row in ipairs(dragState.rows) do
                    if row:IsVisible() then
                        local top = row:GetTop()
                        local bottom = row:GetBottom()
                        local mid = (top + bottom) / 2
                        if cy > mid then
                            insertIndex = idx
                            indicator:ClearAllPoints()
                            indicator:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 2)
                            indicator:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 2)
                            indicator:Show()
                            break
                        elseif idx == #dragState.rows then
                            insertIndex = idx + 1
                            indicator:ClearAllPoints()
                            indicator:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, -2)
                            indicator:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, -2)
                            indicator:Show()
                        end
                    end
                end
                dragState.insertIndex = insertIndex
            end)
        end
    end)

    dragHandle:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and dragState.dragging then
            dragState.dragging = false
            self:SetScript("OnUpdate", nil)
            local indicator = dragState.indicator
            if indicator then indicator:Hide() end
            local sourceIdx = dragState.sourceIndex
            local insertIdx = dragState.insertIndex
            local items = dragState.items
            if insertIdx and sourceIdx and insertIdx ~= sourceIdx and insertIdx ~= sourceIdx + 1 then
                local newOrder = {}
                local movedItem = items[sourceIdx]
                local targetIdx = 1
                for idx, itm in ipairs(items) do
                    if idx ~= sourceIdx then
                        if targetIdx == insertIdx then
                            table.insert(newOrder, movedItem.baseId)
                        end
                        table.insert(newOrder, itm.baseId)
                        targetIdx = targetIdx + 1
                    end
                end
                if insertIdx > #items then
                    table.insert(newOrder, movedItem.baseId)
                end
                onCommit(newOrder)
            end
        end
    end)

    dragHandle:HookScript("OnHide", function(self)
        self:SetScript("OnUpdate", nil)
        dragState.dragging = false
        if dragState.indicator then dragState.indicator:Hide() end
    end)

    return dragHandle
end
_sbc.CreateOrderDragHandle = CreateOrderDragHandle

-- Shared collapsible category header for the Items tabs, used by this page,
-- the potions bar page (Cons_PotionsCfg.lua) and the checker page
-- (Cons_Checker.lua) via RC._sbc.CreateCollapsibleHeader. Builds the full-
-- width header button with collapse arrow, label and hover, and wires
-- onToggle as the click handler. opts (all optional):
--   textureArrow: use the plus/minus button textures instead of "+"/"-" text
--   hoverDelta:   hover brighten amount (default 0.08)
--   textColor:    {r,g,b[,a]} array for the label (default TEXT.gold)
-- Returns the header button (label FontString on .headerText) so callers
-- can anchor extra widgets to it.
local function CreateCollapsibleHeader(parent, yPos, labelText, isCollapsed, onToggle, opts)
    opts = opts or {}
    local FLAT = RC.UI.FLAT
    -- Flat 28px row in the button palette: normal fill, 1px black ring,
    -- hover = buttons.hoverBackground with the label going gold. Sits on
    -- the card grid (18px page margin) like every card around it.
    local headerBtn = CreateFrame("Button", nil, parent)
    headerBtn:SetHeight(28)
    headerBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
    headerBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, yPos)
    headerBtn.bg = headerBtn:CreateTexture(nil, "BACKGROUND")
    headerBtn.bg:SetAllPoints()
    headerBtn.bg:SetTexture(FLAT)
    headerBtn.border = RC.UI:CreateSimpleBorder(headerBtn)

    -- Collapse glyph: the addon's own flat arrow, pointing down when the
    -- section is open and rotated to point right when collapsed. No
    -- Blizzard plus/minus art (opts.textureArrow is kept for callers but
    -- draws this same glyph).
    local arrow = headerBtn:CreateTexture(nil, "ARTWORK")
    arrow:SetSize(10, 10)
    arrow:SetPoint("LEFT", headerBtn, "LEFT", 10, 0)
    arrow:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrow")
    arrow:SetRotation(isCollapsed and math.rad(90) or 0)
    do local ac = RC:GetColor("dropdown", "arrow") or RC:GetColor("ui", "accentGold")
        arrow:SetVertexColor(ac.r, ac.g, ac.b, 1) end
    headerBtn.arrow = arrow

    local headerText = RC:CreateFontString(headerBtn, "OVERLAY", nil, 11)
    headerText:SetPoint("LEFT", arrow, "RIGHT", 8, 0)
    headerText:SetText(labelText)
    local tc = opts.textColor or TEXT.gold
    headerText:SetTextColor(tc[1], tc[2], tc[3], tc[4])
    headerBtn.headerText = headerText

    headerBtn:SetScript("OnClick", onToggle)
    do
        local normBg  = RC:GetColor("buttons", "normalBackground")
        local hoverBg = RC:GetColor("buttons", "hoverBackground")
        headerBtn.bg:SetVertexColor(normBg.r, normBg.g, normBg.b, normBg.a or 1)
        RC.UI:AttachHover(headerBtn, normBg, hoverBg, {
            text = headerText,
            normTextColor  = { r = tc[1], g = tc[2], b = tc[3] },
            hoverTextColor = RC:GetColor("ui", "accentGold"),
        })
    end
    return headerBtn
end
_sbc.CreateCollapsibleHeader = CreateCollapsibleHeader

-- Square icon tile that toggles one thing on/off (weapon shown/hidden on
-- a bar). The implementation moved to the framework as
-- RC.UI:CreateIconToggleTile so the aura tracker pages in
-- Readycheck_Reminders can use it without this addon loaded; the local
-- name and the RC._sbc alias stay for Cons_WeaponsCfg.lua and the
-- callers below. Returns the Button; call tile:SetOn(bool) to repaint,
-- wire OnClick / HookScript("OnEnter") yourself.
local function CreateIconToggleTile(parent, size, iconTexture) return RC.UI:CreateIconToggleTile(parent, size, iconTexture) end
_sbc.CreateIconToggleTile = CreateIconToggleTile
    function RC:ShowSidebarConsumablesHelperConfig(frame, preserveScroll)
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local CBS = _sbc.BarPages
        -- the bar itself, drawn by its own button code (Cons_BarStyle)
        local P = CBS.DeclarePreview(self, "consumablesHelper")
        local parent = frame.scrollChild
        local yPos = -20

        local headerFrame, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Consumables Bar"],
            RCL["Quick-access buttons for raid consumables"], "Interface\\Icons\\INV_Potion_41")
        yPos = newY

        if not self.db.consumablesHelper then
            self.db.consumablesHelper = {}
        end
        if not self.db.consumablesHelper.hiddenItems then
            self.db.consumablesHelper.hiddenItems = {}
        end
        if not self.db.consumablesHelper.itemOrder then
            self.db.consumablesHelper.itemOrder = {}
        end
        if not self.db.consumablesHelper.collapsedCategories then
            self.db.consumablesHelper.collapsedCategories = {}
        end

        if self.db.consumablesHelper.groupConflictButtons == nil then
            self.db.consumablesHelper.groupConflictButtons = false
        end

        if not self.db.consumablesHelper.conflictGroupPreferences then
            self.db.consumablesHelper.conflictGroupPreferences = {}
        end

        if not self.db.consumablesHelper.collapsedCategories then
            self.db.consumablesHelper.collapsedCategories = {}
        end

        if not self.db.consumablesHelper.itemOrder then
            self.db.consumablesHelper.itemOrder = {}
        end

        -- old tab keys (search aliases, saved state) land on the tab that has them now
        frame.consumablesBarTab = CBS.Tab(frame.consumablesBarTab, "behavior")

        local _, newTabY = self.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = {
                { key = "behavior", label = RCL["Behavior"] },
                { key = "items", label = RCL["Items"] },
                { key = "order", label = RCL["Order"] },
                { key = "actions", label = RCL["Quick use"] },
                { key = "look", label = RCL["Look"] },
                { key = "text", label = RCL["Text"] },
                { key = "animation", label = RCL["Animation"] },
                { key = "sound", label = RCL["Sound"] },
                { key = "position", label = RCL["Position"] },
            },
            selected = frame.consumablesBarTab,
            onClick = function(tk)
                frame.consumablesBarTab = tk
                RC:ShowSidebarConsumablesHelperConfig(frame, true)
            end,
            inset = 18,
            fontSize = 10,
            advance = 34,
        })
        yPos = newTabY

        local currentTab = frame.consumablesBarTab or "behavior"
        -- the card holding the on switch (Behavior tab): it stays live
        local liveCard

        if currentTab == "behavior" then
            local basicCard = self:CreateSettingsCard(parent, yPos, RCL["General"])
            liveCard = basicCard
            local cardY = -32

            local enableCheck = self.UI:CreateSettingCheckbox(basicCard, cardY, "Enable Consumables Bar", self.db.consumablesHelper.enabled, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesHelper.enabled = newState
                RC:ForceCheckboxUpdate(cb, newState)
                if newState then
                    if not RC.consumablesHelper.frame then RC:CreateConsumablesHelperFrame() end
                    if RC.consumablesHelper.frame then
                        RC:UpdateConsumablesButtons()
                    end
                end
                -- Show/hide through the visibility evaluator so the bar's
                -- "show in" mode is honoured instead of forcing it on.
                RC:UpdateConsumablesVisibility()
                RC:SaveConfigurationToProfile()
                C_Timer.After(0, function() RC:ShowSidebarConsumablesHelperConfig(frame, true) end)
            end)
            cardY = cardY - 28

            local hideCombatCheck = self.UI:CreateSettingCheckbox(basicCard, cardY, "Hide in combat", self.db.consumablesHelper.hideInCombat, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesHelper.hideInCombat = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 30
            cardY = cardY - 4
            basicCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - basicCard:GetHeight() - 15

        end

        if currentTab == "look" then
            local displayCard = self:CreateSettingsCard(parent, yPos, RCL["Display"])
            local cardY = -32

            local presetLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            presetLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            presetLabel:SetText(RCL["Presets:"])
            presetLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local compactBtn = self.UI:CreateStyledButton(displayCard, RCL["Compact"], 70, 22)
            compactBtn:SetPoint("LEFT", presetLabel, "RIGHT", 10, 0)
            compactBtn:SetScript("OnClick", function()
                RC.db.consumablesHelper.buttonSize = 28
                RC.db.consumablesHelper.iconSpacing = 2
                RC.db.consumablesHelper.showBackground = false
                RC:UpdateConsumablesHelperBackground()
                RC:UpdateConsumablesButtons()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarConsumablesHelperConfig(frame)
            end)

            local normalBtn = self.UI:CreateStyledButton(displayCard, RCL["Normal"], 70, 22)
            normalBtn:SetPoint("LEFT", compactBtn, "RIGHT", 6, 0)
            normalBtn:SetScript("OnClick", function()
                RC.db.consumablesHelper.buttonSize = 36
                RC.db.consumablesHelper.iconSpacing = 4
                RC.db.consumablesHelper.showBackground = true
                RC:UpdateConsumablesHelperBackground()
                RC:UpdateConsumablesButtons()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarConsumablesHelperConfig(frame)
            end)
            cardY = cardY - 27

            local sizeLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            sizeLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            sizeLabel:SetText(RCL["Button Size:"])
            sizeLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local sizeSlider = self.UI:CreateSettingSlider(displayCard, 24, 64, self.db.consumablesHelper.buttonSize or 36, 2, 100, cardY + 5, (self.db.consumablesHelper.buttonSize or 36) .. "px", function(slider, value)
                value = math.floor(value / 2) * 2
                RC.db.consumablesHelper.buttonSize = value
                slider.Text:SetText(value .. RCL["px"])
                RC:UpdateConsumablesButtons()
            end)
            sizeSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            local perRowLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            perRowLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            perRowLabel:SetText(RCL["Per Row:"])
            perRowLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local perRowSlider = self.UI:CreateSettingSlider(displayCard, 1, 40, self.db.consumablesHelper.buttonsPerRow or 10, 1, 100, cardY + 5, self.db.consumablesHelper.buttonsPerRow or 10, function(slider, value)
                value = math.floor(value)
                RC.db.consumablesHelper.buttonsPerRow = value
                slider.Text:SetText(value)
                RC:UpdateConsumablesButtons()
            end)
            perRowSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            local spacingLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            spacingLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            spacingLabel:SetText(RCL["Spacing:"])
            spacingLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local spacingSlider = self.UI:CreateSettingSlider(displayCard, 0, 20, self.db.consumablesHelper.iconSpacing or 4, 1, 100, cardY + 5, (self.db.consumablesHelper.iconSpacing or 4) .. "px", function(slider, value)
                value = math.floor(value)
                RC.db.consumablesHelper.iconSpacing = value
                slider.Text:SetText(value .. RCL["px"])
                RC:UpdateConsumablesButtons()
            end)
            spacingSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            if self.db.consumablesHelper.showBackground == nil then self.db.consumablesHelper.showBackground = true end
            local bgCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show background and borders", self.db.consumablesHelper.showBackground, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesHelper.showBackground = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:UpdateConsumablesHelperBackground()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26

            if self.db.consumablesHelper.showItemNames == nil then self.db.consumablesHelper.showItemNames = false end
            local nameCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show item names on icons", self.db.consumablesHelper.showItemNames, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesHelper.showItemNames = newState
                RC:ForceCheckboxUpdate(cb, newState)
                if RC.UpdateConsumablesHelperNameLabels then
                    RC:UpdateConsumablesHelperNameLabels()
                end
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 35

            local ttCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show item tooltips on hover", self.db.consumablesHelper.showTooltips == true, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesHelper.showTooltips = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 35

            displayCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - displayCard:GetHeight() - 15

            yPos = CBS.BuildLook(self, frame, "consumablesHelper", parent, yPos)

        end

        if currentTab == "behavior" then
            local behaviorCard = self:CreateSettingsCard(parent, yPos, RCL["Behavior"])
            local cardY = -32

            do
                local cur = self.db.consumablesHelper.hideUsedInCombat
                if cur == nil then cur = true end
                self.UI:CreateSettingCheckbox(behaviorCard, cardY,
                    "Hide consumes when used (in combat)", cur, function(cb)
                    self.db.consumablesHelper.hideUsedInCombat = cb:GetChecked() and true or false
                    RC:SaveConfigurationToProfile()
                end)
                cardY = cardY - 28
            end

            local hordeCheck = self.UI:CreateSettingCheckbox(behaviorCard, cardY, "Horde mode: hide main-hand stone and oil buttons", RC:IsHordeMode("consumablesHelper"), function(cb)
                local newState = cb:GetChecked()
                RC:SetHordeMode("consumablesHelper", newState)
                RC:ForceCheckboxUpdate(cb, newState)
                if RC.ForceRebuildWeaponButtons then RC:ForceRebuildWeaponButtons() end
                RC:UpdateConsumablesButtons()
                RC:SaveConfigurationToProfile()
            end)
            hordeCheck:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local gold, norm, gray = RC:GetColor("text", "gold"), RC:GetColor("text", "normal"), RC:GetColor("text", "gray")
                GameTooltip:SetText(RCL["Horde Mode"], gold.r, gold.g, gold.b)
                GameTooltip:AddLine(RCL["Hides the main-hand stone and oil buttons on this bar. The weapons bar has its own switch."], norm.r, norm.g, norm.b, true)
                GameTooltip:AddLine(RCL["Remembered for this character's faction only: on for Horde and off for Alliance until you change it."], norm.r, norm.g, norm.b, true)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(RCL["Horde warriors use Windfury Totem on their main-hand,"], gray.r, gray.g, gray.b, true)
                GameTooltip:AddLine(RCL["so only the off-hand needs a sharpening stone."], gray.r, gray.g, gray.b, true)
                GameTooltip:Show()
            end)
            hordeCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)
            cardY = cardY - 28


            local showAvailCheck = self.UI:CreateSettingCheckbox(behaviorCard, cardY, "Show only available items", self.db.consumablesHelper.showOnlyAvailable, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesHelper.showOnlyAvailable = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:UpdateConsumablesButtons()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26
            -- (2026-11-09) not offered on TBC
            if RC.Flavor and RC:Flavor() == "tbc" then hordeCheck:Hide() cardY = cardY + 26 end

            local hideActiveCheck = self.UI:CreateSettingCheckbox(behaviorCard, cardY, "Hide when buff active", self.db.consumablesHelper.hideWhenActive, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesHelper.hideWhenActive = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:RefreshConsumablesDisplay()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26

            local hideConflictCheck = self.UI:CreateSettingCheckbox(behaviorCard, cardY, "Hide conflicting buffs", self.db.consumablesHelper.hideConflictingBuffs, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesHelper.hideConflictingBuffs = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:RefreshConsumablesDisplay()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26

            local groupConflictCheck = self.UI:CreateSettingCheckbox(behaviorCard, cardY, "Group conflict items (one button)", self.db.consumablesHelper.groupConflictButtons or false, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesHelper.groupConflictButtons = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:UpdateConsumablesButtons()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarConsumablesHelperConfig(frame)
            end)
            cardY = cardY - 26

            local selfCastCheck = self.UI:CreateSettingCheckbox(behaviorCard, cardY, "Force Jujus to self-cast", self.db.consumablesHelper.selfCastJujus, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesHelper.selfCastJujus = newState
                RC:ForceCheckboxUpdate(cb, newState)
                -- Button rebuild touches secure attributes; skip in combat,
                -- setting still saves and applies on the next rebuild.
                if not InCombatLockdown() then
                    RC:UpdateConsumablesButtons()
                end
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26
            -- (2026-11-09) not offered on TBC
            if RC.Flavor and RC:Flavor() == "tbc" then selfCastCheck:Hide() cardY = cardY + 26 end

            if RC.db.consumablesHelper.petrificationCampMode == nil then
                RC.db.consumablesHelper.petrificationCampMode = false
            end
            local petrCampCheck = self.UI:CreateSettingCheckbox(behaviorCard, cardY, "Flask of Petrification: also /camp", self.db.consumablesHelper.petrificationCampMode, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesHelper.petrificationCampMode = newState
                RC:ForceCheckboxUpdate(cb, newState)
                if not InCombatLockdown() then
                    RC:UpdateConsumablesButtons()
                end
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26
            -- (2026-11-09) not offered on TBC
            if RC.Flavor and RC:Flavor() == "tbc" then petrCampCheck:Hide() cardY = cardY + 26 end

            if self.db.consumablesHelper.groupConflictButtons then
                local groupNames = RC.flavorGroupLabels or {
                    {key = "apStrength", name = "AP Buffs"},
                    {key = "zanza", name = "Zanza/ROIDS"},
                    {key = "wellFed", name = "Well Fed"},
                    {key = "hitFood", name = "Hit Food (Bun / Dark Desire)"},
                    {key = "sharpeningStone", name = "Sharpening Stones"},
                    {key = "wizardOil", name = "Wizard Oils"},
                    {key = "engineeringExplosives", name = "Explosives"},
                }

                local prefs = self.db.consumablesHelper.conflictGroupPreferences or {}

                for _, groupInfo in ipairs(groupNames) do
                    local groupKey = groupInfo.key
                    local groupLabel = groupInfo.name
                    local priority = RC.conflictGroupPriority and RC.conflictGroupPriority[groupKey]

                    if priority and #priority > 1 then
                        local options = {{value = nil, name = "Auto (first available)"}}
                        for _, itemId in ipairs(priority) do
                            local itemName = GetItemInfo(itemId) or RC:FlavorItemName(itemId)
                            table.insert(options, {
                                value = itemId,
                                name = itemName or ("Item #" .. itemId)
                            })
                        end

                        local currentPref = prefs[groupKey]
                        local currentName = "Auto (first available)"
                        if currentPref then
                            for _, opt in ipairs(options) do
                                if opt.value == currentPref then
                                    currentName = opt.name
                                    break
                                end
                            end
                        end

                        local label = self:CreateFontString(behaviorCard, "OVERLAY", nil, 10)
                        label:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 30, cardY)
                        label:SetText(groupLabel .. ":")
                        label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

                        -- the choice sits after the longest name, never on it
                        local ddX = math.max(140, 30 + math.ceil(label:GetStringWidth() or 0) + 10)
                        local dropdown = self.UI:CreateScrollableDropdown(behaviorCard, 140, currentName, 10)
                        dropdown:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", ddX, cardY + 5)

                        do
                            local AUTO = "__auto__"
                            local items = {}
                            for _, opt in ipairs(options) do
                                table.insert(items, { text = opt.name, value = (opt.value == nil) and AUTO or opt.value })
                            end
                            dropdown:SetItems(items, function(value)
                                if not RC.db.consumablesHelper.conflictGroupPreferences then
                                    RC.db.consumablesHelper.conflictGroupPreferences = {}
                                end
                                RC.db.consumablesHelper.conflictGroupPreferences[groupKey] = (value == AUTO) and nil or value
                                RC:UpdateConsumablesButtons()
                                RC:SaveConfigurationToProfile()
                            end)
                            dropdown:SetSelectedValue((currentPref == nil) and AUTO or currentPref, currentName)
                        end

                        cardY = cardY - 35
                    end
                end

                cardY = cardY - 5
            end

            local expiryLabel = self:CreateFontString(behaviorCard, "OVERLAY", nil, 11)
            expiryLabel:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 14, cardY)
            expiryLabel:SetText(RCL["Show before expiry:"])
            expiryLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local expirySlider = self.UI:CreateSettingSlider(behaviorCard, 10, 300, self.db.consumablesHelper.showBeforeExpiry or 60, 5, 140, cardY + 5, (self.db.consumablesHelper.showBeforeExpiry or 60) .. "s", function(slider, value)
                value = math.floor(value / 5) * 5
                RC.db.consumablesHelper.showBeforeExpiry = value
                slider.Text:SetText(value .. "s")
            end)
            expirySlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 40

            behaviorCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - behaviorCard:GetHeight() - 15

            -- the same card the weapons bar page shows: these two settings
            -- drive both bars' weapon buttons
            if self.BuildWeaponEnhancementCard then
                yPos = self:BuildWeaponEnhancementCard(parent, yPos)
            end
        end

        -- the spoken warnings
        if currentTab == "sound" then
            local behaviorCard = self:CreateSettingsCard(parent, yPos, RCL["Voice alerts"])
            local cardY = -32

            local ttsCheck = self.UI:CreateCheckbox(behaviorCard,
                RCL["Speak consumable name when expiring (TTS)"],
                self.db.consumablesHelper.consumableTTSEnabled)
            ttsCheck:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 14, cardY)
            ttsCheck:SetScript("OnClick", function()
                RC.db.consumablesHelper.consumableTTSEnabled = ttsCheck:GetChecked()
                self:ForceCheckboxUpdate(ttsCheck, RC.db.consumablesHelper.consumableTTSEnabled)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26
            local ttsDesc = self:CreateFontString(behaviorCard, "OVERLAY", nil, 10)
            ttsDesc:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 35, cardY)
            ttsDesc:SetWidth(behaviorCard:GetWidth() - 50)
            ttsDesc:SetText(RCL['Uses OS text-to-speech e.g. "Titans!" or "Mug!" - volume set in Reminder Settings > Sound.'])
            ttsDesc:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            ttsDesc:SetJustifyH("LEFT")
            cardY = cardY - ttsDesc:GetStringHeight() - 4
            local ttsItemNote = self:CreateFontString(behaviorCard, "OVERLAY", nil, 10)
            ttsItemNote:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 35, cardY)
            ttsItemNote:SetWidth(behaviorCard:GetWidth() - 50)
            ttsItemNote:SetText(RCL["Enable/disable TTS and repeat per item in the Items tab."])
            ttsItemNote:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
            ttsItemNote:SetJustifyH("LEFT")
            cardY = cardY - ttsItemNote:GetStringHeight() - 8

            local potReadyCb = self.UI:CreateCheckbox(behaviorCard,
                RCL["Announce when potion cooldown ends"],
                RC.db.consumablesHelper.potionReadyTTS or false)
            potReadyCb:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 14, cardY)
            potReadyCb:SetScript("OnClick", function()
                RC.db.consumablesHelper.potionReadyTTS = potReadyCb:GetChecked() and true or false
                self:ForceCheckboxUpdate(potReadyCb, RC.db.consumablesHelper.potionReadyTTS)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 28

            local repeatEnCb = self.UI:CreateCheckbox(behaviorCard,
                RCL["Repeat TTS after buff expires"],
                RC.db.consumablesHelper.consumableTTSRepeatEnabled or false)
            repeatEnCb:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 14, cardY)
            repeatEnCb:SetScript("OnClick", function()
                RC.db.consumablesHelper.consumableTTSRepeatEnabled = repeatEnCb:GetChecked()
                self:ForceCheckboxUpdate(repeatEnCb, RC.db.consumablesHelper.consumableTTSRepeatEnabled)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26

            local repeatEnDesc = self:CreateFontString(behaviorCard, "OVERLAY", nil, 10)
            repeatEnDesc:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 35, cardY)
            repeatEnDesc:SetWidth(behaviorCard:GetWidth() - 50)
            repeatEnDesc:SetText(RCL["After the buff expires the TTS fires again at the interval below."])
            repeatEnDesc:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            repeatEnDesc:SetJustifyH("LEFT")
            -- (the slider's value sits over its track: room for it)
            cardY = cardY - repeatEnDesc:GetStringHeight() - 12

            local repeatCntLbl = self:CreateFontString(behaviorCard, "OVERLAY", nil, 10)
            repeatCntLbl:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 14, cardY)
            repeatCntLbl:SetText(RCL["Repeat count"])
            local repeatCount = RC.db.consumablesHelper.consumableTTSRepeatCount or 1
            -- Max 10 to match the cap the voice watch applies; the
            -- slider used to stop at 5 and hide half the usable range.
            local repeatCntSlider = self.UI:CreateSlider(behaviorCard, 1, 10, repeatCount, 1)
            repeatCntSlider:SetPoint("LEFT", repeatCntLbl, "RIGHT", 8, 0)
            repeatCntSlider:SetWidth(100)
            repeatCntSlider.Text:SetText(tostring(repeatCount))
            repeatCntSlider:SetScript("OnValueChanged", function(slider, value)
                value = math.floor(value)
                RC.db.consumablesHelper.consumableTTSRepeatCount = value
                slider.Text:SetText(tostring(value))
            end)
            repeatCntSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 32

            local repeatLbl = self:CreateFontString(behaviorCard, "OVERLAY", nil, 10)
            repeatLbl:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 14, cardY)
            repeatLbl:SetText(RCL["Repeat reminder every"])
            local repeatInterval = RC.db.consumablesHelper.consumableTTSRepeatInterval or 60
            local repeatSlider = self.UI:CreateSlider(behaviorCard, 10, 300, repeatInterval, 5)
            repeatSlider:SetPoint("LEFT", repeatLbl, "RIGHT", 8, 0)
            repeatSlider:SetWidth(110)
            repeatSlider.Text:SetText(repeatInterval .. "s")
            repeatSlider:SetScript("OnValueChanged", function(slider, value)
                value = math.floor(value / 5) * 5
                RC.db.consumablesHelper.consumableTTSRepeatInterval = value
                slider.Text:SetText(value .. "s")
            end)
            repeatSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 32
            local repeatDesc = self:CreateFontString(behaviorCard, "OVERLAY", nil, 10)
            repeatDesc:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 35, cardY)
            repeatDesc:SetWidth(behaviorCard:GetWidth() - 50)
            repeatDesc:SetText(RCL["Seconds after the buff expires before each repeat fires."])
            repeatDesc:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            repeatDesc:SetJustifyH("LEFT")
            cardY = cardY - repeatDesc:GetStringHeight() - 6
            -- the count and the interval only matter with the repeat on
            self.UI:BindDependents(repeatEnCb, { repeatCntLbl, repeatCntSlider, repeatLbl, repeatSlider })
            self.UI:BindDependents(repeatEnCb, { repeatDesc }, { indent = 0 })

            if not (C_VoiceChat and C_VoiceChat.SpeakText) then
                local ttsWarn = self:CreateFontString(behaviorCard, "OVERLAY", nil, 10)
                ttsWarn:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 35, cardY)
                ttsWarn:SetWidth(behaviorCard:GetWidth() - 50)
                ttsWarn:SetText(RCL["Note: C_VoiceChat.SpeakText not available on this client version."])
                local _warnC = RC:GetColor("text", "warning")
                ttsWarn:SetTextColor(_warnC.r, _warnC.g, _warnC.b, 1)
                ttsWarn:SetJustifyH("LEFT")
                cardY = cardY - 14
            end
            cardY = cardY - 4

            behaviorCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - behaviorCard:GetHeight() - 15

        end

        if currentTab == "behavior" then
            local visCard = self:CreateSettingsCard(parent, yPos, RCL["Visibility mode"])
            local cardY = -32

            local visInfo = self:CreateFontString(visCard, "OVERLAY", nil, 10)
            visInfo:SetPoint("TOPLEFT", visCard, "TOPLEFT", 14, cardY)
            visInfo:SetWidth(visCard:GetWidth() - 30)
            visInfo:SetText(RCL["Control when the consumables bar is automatically shown."])
            visInfo:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 25

            -- Keys are the saved values; labels/tooltips come from
            -- BuildVisibilityModeGrid ("group" = any party/raid anywhere,
            -- "raids" = inside a raid instance, "city" = resting in an inn
            -- or capital). The raid modes get a per-raid filter block
            -- underneath, so onPick re-renders (scroll kept) to resize.
            local modes = {
                {key = "always", name = "Always"},
                {key = "group", name = "In a Group"},
                {key = "city", name = "In Cities"},
                {key = "raids", name = "In Raids"},
                {key = "raids_and_city", name = "Raids & Cities"}
            }

            cardY = _sbc.BuildVisibilityModeGrid(visCard, cardY, modes, RC.db.consumablesHelper, function()
                RC:UpdateConsumablesVisibility()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarConsumablesHelperConfig(frame, true)
            end)

            visCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - visCard:GetHeight() - 15
            -- fade rules on top of "Show in" (the customization standard)
            yPos = self.UI:FrameVisibilityCard(parent, yPos, function() return RC.db.consumablesHelper end,
                function() RC:RestyleBar("consumablesHelper") end, { fields = { show = true, alpha = true, combatAlpha = true, fadeIn = true, fadeOut = true },
                note = RCL["On top of 'Show in' and the mouseover fade: a rule that is not met fades the bar out."] })

        end

        if currentTab == "items" then

            if not self.db.consumablesHelper.hiddenItems then
                self.db.consumablesHelper.hiddenItems = {}
            end
            local hiddenItems = self.db.consumablesHelper.hiddenItems

            local bulkCard = self:CreateSettingsCard(parent, yPos, RCL["Bulk actions"])
            local cardY = -32

            local showAllBtn = self.UI:CreateStyledButton(bulkCard, RCL["Show All"], 110, 22)
            showAllBtn:SetPoint("TOPLEFT", bulkCard, "TOPLEFT", 14, cardY)
            showAllBtn:SetScript("OnClick", function()
                RC.db.consumablesHelper.hiddenItems = {}
                RC:UpdateConsumablesButtons()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarConsumablesHelperConfig(frame)
            end)

            local hideAllBtn = self.UI:CreateStyledButton(bulkCard, RCL["Hide All"], 110, 22)
            hideAllBtn:SetPoint("LEFT", showAllBtn, "RIGHT", 8, 0)
            hideAllBtn:SetScript("OnClick", function()
                for _, categoryKey in ipairs(RC.consumablesHelper.categories) do
                    local category = RC.raidConsumables[categoryKey]
                    if category then
                        for itemId, itemData in pairs(category.items) do
                            local isWepItem = itemData.slot ~= nil or itemData.enchantId
                                or RC.weaponStoneIds[itemId]
                            local isPotionOnly = RC.potionBarItems[itemId]
                                and not (RC.bothBarsItems and RC.bothBarsItems[itemId])
                            if not isPotionOnly and not isWepItem then
                                RC.db.consumablesHelper.hiddenItems[itemId] = true
                            end
                        end
                    end
                end
                RC:UpdateConsumablesButtons()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarConsumablesHelperConfig(frame)
            end)
            cardY = cardY - 40

            bulkCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - bulkCard:GetHeight() - 10

            local customCard = self:CreateSettingsCard(parent, yPos, RCL["Custom items"])
            cardY = -32

            local customInfo = self:CreateFontString(customCard, "OVERLAY", nil, 10)
            customInfo:SetPoint("TOPLEFT", customCard, "TOPLEFT", 14, cardY)
            customInfo:SetWidth(customCard:GetWidth() - 30)
            customInfo:SetText(RCL["Add items by ID. Right-click to change category."])
            customInfo:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 25

            local inputRow = CreateFrame("Frame", nil, customCard)
            inputRow:SetHeight(26)
            inputRow:SetPoint("TOPLEFT", customCard, "TOPLEFT", 14, cardY)
            inputRow:SetPoint("RIGHT", customCard, "RIGHT", -14, 0)

            local idLabel = self:CreateFontString(inputRow, "OVERLAY", nil, 10)
            idLabel:SetPoint("LEFT", inputRow, "LEFT", 0, 0)
            idLabel:SetText(RCL["Item ID:"])
            idLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local idEdit = self.UI:CreateBackedEditBox(inputRow, {
                width = 80, height = 22, numeric = true, maxLetters = 8,
                fontSize = 10, fontFlags = "", insets = 6,
                textColor = TEXT.white,
            })
            idEdit:SetPoint("LEFT", idLabel, "RIGHT", 8, 0)
            do
                -- Rebuilding this page destroys the editbox; restash typed text
                -- (8s TTL) so Add doesn't lose keystrokes typed right before a redraw.
                local st = RC._customIdStash
                if st and st.key == "consbar" and (GetTime() - (st.at or 0)) < 8 then
                    idEdit:SetText(st.text or "")
                    local cur = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
                    if not cur then
                        idEdit:SetFocus()
                        idEdit:SetCursorPosition(#(st.text or ""))
                    end
                end
            end
            idEdit:SetScript("OnTextChanged", function(selfEB, userInput)
                if userInput then
                    RC._customIdStash = { key = "consbar", text = selfEB:GetText() or "", at = GetTime() }
                end
            end)
            idEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

            local addBtn = self.UI:CreateStyledButton(inputRow, RCL["Add Item"], 70, 22)
            addBtn:SetPoint("LEFT", idEdit, "RIGHT", 8, 0)
            addBtn:SetScript("OnClick", function()
                local itemId = tonumber(idEdit:GetText())
                if itemId and itemId > 0 then
                    local success, msg = RC:AddCustomConsumableItem(itemId, "consumables", "custom")
                    if success then
                        RC:UpdateConsumablesButtons()
                        RC:ShowSidebarConsumablesHelperConfig(frame, true)
                    else
                        RC:Print("|cffff6666" .. (msg or "Failed to add item") .. "|r")
                    end
                    idEdit:SetText("")
                    RC._customIdStash = nil
                else
                    RC:Print(RCL["|cffff6666Please enter a valid item ID|r"])
                end
            end)
            idEdit:SetScript("OnEnterPressed", function(self)
                addBtn:Click()
            end)
            cardY = cardY - 32

            local customItemsByCategory = RC:GetCustomItemsByCategory("consumables")
            local hasCustomItems = false
            for _ in pairs(customItemsByCategory) do hasCustomItems = true break end

            if hasCustomItems then
                for _, catInfo in ipairs(RC.customItemCategories or {}) do
                    local catKey = catInfo.key
                    local catItems = customItemsByCategory[catKey]

                    if catItems and #catItems > 0 then
                        local catHeader = self:CreateFontString(customCard, "OVERLAY", nil, 10)
                        catHeader:SetPoint("TOPLEFT", customCard, "TOPLEFT", 14, cardY)
                        catHeader:SetText(catInfo.name .. " (" .. #catItems .. ")")
                        catHeader:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
                        cardY = cardY - 18

                        for _, item in ipairs(catItems) do
                            local itemId = item.id
                            local itemData = item.data

                            local itemRow = CreateFrame("Frame", nil, customCard)
                            itemRow:SetHeight(24)
                            itemRow:SetPoint("TOPLEFT", customCard, "TOPLEFT", 20, cardY)
                            itemRow:SetPoint("RIGHT", customCard, "RIGHT", -14, 0)

                            local icon = itemRow:CreateTexture(nil, "ARTWORK")
                            icon:SetSize(18, 18)
                            icon:SetPoint("LEFT", itemRow, "LEFT", 0, 0)
                            icon:SetTexture(itemData.icon or 134400)
                            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                            local nameText = self:CreateFontString(itemRow, "OVERLAY", nil, 10)
                            nameText:SetPoint("LEFT", icon, "RIGHT", 4, 0)
                            nameText:SetText(itemData.name or ("Item " .. itemId))
                            if itemData.pending then
                                nameText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                            else
                                nameText:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                            end

                            local catLabel = self:CreateFontString(itemRow, "OVERLAY", nil, 10)
                            catLabel:SetPoint("RIGHT", itemRow, "RIGHT", -26, 0)
                            catLabel:SetText("[" .. (catInfo.name:sub(1, 8)) .. "]")
                            catLabel:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])

                            local removeBtn = self.UI:CreateRemoveButton(itemRow, 18, function()
                                RC:RemoveCustomConsumableItem(itemId, "consumables")
                                RC:UpdateConsumablesButtons()
                                RC:ShowSidebarConsumablesHelperConfig(frame, true)
                            end)
                            removeBtn:SetPoint("RIGHT", itemRow, "RIGHT", 0, 0)

                            itemRow:EnableMouse(true)
                            itemRow:SetScript("OnMouseUp", function(self, button)
                                if button == "RightButton" then
                                    local menuFrame = _sbc.GetCustomItemCategoryMenu()
                                    UIDropDownMenu_Initialize(menuFrame, function(dropdown, level)
                                        for _, cat in ipairs(RC.customItemCategories or {}) do
                                            local info = UIDropDownMenu_CreateInfo()
                                            info.text = cat.name
                                            info.checked = (itemData.category == cat.key)
                                            info.func = function()
                                                RC:SetCustomItemCategory(itemId, "consumables", cat.key)
                                                RC:UpdateConsumablesButtons()
                                                RC:ShowSidebarConsumablesHelperConfig(frame, true)
                                            end
                                            UIDropDownMenu_AddButton(info, level)
                                        end
                                    end, "MENU")
                                    ToggleDropDownMenu(1, nil, menuFrame, "cursor", 0, 0)
                                end
                            end)

                            cardY = cardY - 26
                        end
                        cardY = cardY - 4
                    end
                end
            else
                local noItemsText = self:CreateFontString(customCard, "OVERLAY", nil, 10)
                noItemsText:SetPoint("TOPLEFT", customCard, "TOPLEFT", 14, cardY)
                noItemsText:SetText(RCL["No custom items added"])
                noItemsText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY = cardY - 20
            end

            customCard:SetContentHeight(math.abs(cardY) + 5)
            yPos = yPos - customCard:GetHeight() - 10

            local consSearchText = RC._consumablesBarSearch or ""
            local consSearchBox = self.UI:CreateSearchBox(parent, {
                placeholder = RCL["Search consumables..."],
                initialText = consSearchText,
                onChange = function(txt)
                    RC._consumablesBarSearch = txt
                    RC._consumablesBarSearchFocus = true
                    -- Debounce the filtered rebuild until typing pauses, and defer it
                    -- again if some other edit box has focus (avoid stealing it back).
                    if RC._consumablesBarSearchTimer then RC._consumablesBarSearchTimer:Cancel() end
                    RC._consumablesBarSearchTimer = C_Timer.NewTimer(0.6, function()
                        RC._consumablesBarSearchTimer = nil
                        if not (RC.sidebarConfigFrame and RC.sidebarConfigFrame:IsVisible()) then RC._consumablesBarSearchFocus = nil; return end
                        if RC.SidebarState and RC.SidebarState.currentPanel ~= "consumables_bar" then RC._consumablesBarSearchFocus = nil; return end
                        if not (RC._consumablesBarSearchBox and RC._consumablesBarSearchBox.editBox and RC._consumablesBarSearchBox.editBox:HasFocus()) then RC._consumablesBarSearchFocus = nil end
                        local function tryFilterRebuild()
                            RC._consumablesBarSearchTimer = nil
                            local cf = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
                            if cf and cf.IsObjectType and cf:IsObjectType("EditBox")
                               and not (RC._consumablesBarSearchBox and cf == RC._consumablesBarSearchBox.editBox) then
                                RC._consumablesBarSearchTimer = C_Timer.NewTimer(0.6, tryFilterRebuild)
                                return
                            end
                            RC:ShowSidebarConsumablesHelperConfig(frame, true)
                        end
                        tryFilterRebuild()
                    end)
                end,
            })
            consSearchBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
            consSearchBox:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, yPos)
            RC._consumablesBarSearchBox = consSearchBox
            yPos = yPos - 34
            if RC._consumablesBarSearchFocus then
                RC._consumablesBarSearchFocus = false
                local function _refocus()
                    local eb = consSearchBox and consSearchBox.editBox
                    if not (eb and eb:IsVisible()) then return end
                    local cur = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
                    if cur and cur ~= eb then return end
                    eb:SetFocus(); eb:SetCursorPosition(#(eb:GetText() or ""))
                end
                _refocus()
                C_Timer.After(0, _refocus)
            end
            local consSearchQ = consSearchText:lower()
            for _, categoryKey in ipairs(self.consumablesHelper.categories or {}) do
                local category = self.raidConsumables and self.raidConsumables[categoryKey]
                if category then
                    local items = {}
                    for itemId, itemData in pairs(category.items) do
                        local isWepItem = itemData.slot ~= nil
                            or RC.weaponStoneIds[itemId]
                            or (RC.IsWeaponOilItem and RC:IsWeaponOilItem(itemId))
                        local isPotionOnly = self.potionBarItems[itemId]
                            and not (self.bothBarsItems and self.bothBarsItems[itemId])
                        if not isPotionOnly and not isWepItem then
                            if consSearchQ == "" or (itemData.name and itemData.name:lower():find(consSearchQ, 1, true)) then
                                table.insert(items, {id = itemId, data = itemData})
                            end
                        end
                    end

                    if #items > 0 or (categoryKey == "utilities" and consSearchQ == "") then
                        table.sort(items, function(a, b) return a.data.name < b.data.name end)

                        local isCollapsed = self.db.consumablesHelper.collapsedCategories[categoryKey]
                        if consSearchQ ~= "" then isCollapsed = false end

                        _sbc.CreateCollapsibleHeader(parent, yPos,
                            category.name .. " (" .. (#items + (categoryKey == "utilities" and 3 or 0)) .. ")",
                            isCollapsed, function()
                                RC.db.consumablesHelper.collapsedCategories[categoryKey] = not isCollapsed
                                RC:SaveConfigurationToProfile()
                                RC:ShowSidebarConsumablesHelperConfig(frame, true)
                            end)

                        yPos = yPos - 32

                        if not isCollapsed then
                            local itemContainer = CreateFrame("Frame", nil, parent, "BackdropTemplate")
                            -- shaded with the cards when the bar is off (LockSettingsCards)
                            itemContainer._rcSettingsCard = true
                            itemContainer:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
                            itemContainer:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, yPos)
                            itemContainer:SetBackdrop({
                                bgFile = "Interface\\Buttons\\WHITE8X8",
                                edgeFile = "Interface\\Buttons\\WHITE8X8",
                                edgeSize = 1,
                            })
                            do local _cb=RC:GetColor("ui","cardBackground"); itemContainer:SetBackdropColor(_cb.r,_cb.g,_cb.b,1) end
                            do local _bn=RC:GetColor("ui","borderNormal"); itemContainer:SetBackdropBorderColor(_bn.r,_bn.g,_bn.b,_bn.a or 1) end

                            local containerY = -8
                            for _, item in ipairs(items) do
                                local itemId = item.id
                                local itemData = item.data
                                local tsKey = tostring(itemId)

                                local itemRow = CreateFrame("Frame", nil, itemContainer)
                                itemRow:SetHeight(46)
                                itemRow:SetPoint("TOPLEFT", itemContainer, "TOPLEFT", 10, containerY)
                                itemRow:SetPoint("RIGHT", itemContainer, "RIGHT", -10, 0)

                                local iconTex = CachedIcon(itemId) or 134400
                                local icon = itemRow:CreateTexture(nil, "ARTWORK")
                                icon:SetSize(20, 20)
                                icon:SetPoint("TOPLEFT", itemRow, "TOPLEFT", 0, -2)
                                icon:SetTexture(iconTex)
                                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                                local isHidden = hiddenItems[itemId]
                                local checkbox = self.UI:CreateCheckbox(itemRow, RC:ItemLabel(itemId, itemData), not isHidden)
                                checkbox:SetPoint("TOPLEFT", itemRow, "TOPLEFT", 25, 0)
                                checkbox:SetScript("OnClick", function(cb)
                                    local newState = cb:GetChecked()
                                    if newState then
                                        RC.db.consumablesHelper.hiddenItems[itemId] = nil
                                    else
                                        RC.db.consumablesHelper.hiddenItems[itemId] = true
                                    end
                                    RC:ForceCheckboxUpdate(cb, newState)
                                    RC:UpdateConsumablesButtons()
                                    RC:SaveConfigurationToProfile()
                                end)

                                if not RC.db.consumablesHelper.consumableTTSSettings then
                                    RC.db.consumablesHelper.consumableTTSSettings = {}
                                end
                                local tsSettings = RC.db.consumablesHelper.consumableTTSSettings
                                local tsItem     = tsSettings[tsKey] or {}

                                local ttsCb = self.UI:CreateCheckbox(itemRow, "TTS", tsItem.ttsEnabled ~= false)
                                ttsCb.parentFrame:ClearAllPoints()
                                ttsCb.parentFrame:SetPoint("TOPLEFT", itemRow, "TOPLEFT", 25, -24)
                                ttsCb.parentFrame:SetWidth(46)
                                ttsCb:SetScript("OnClick", function()
                                    if not tsSettings[tsKey] then tsSettings[tsKey] = {} end
                                    local v = ttsCb:GetChecked()
                                    tsSettings[tsKey].ttsEnabled = v
                                    RC:ForceCheckboxUpdate(ttsCb, v)
                                    RC:SaveConfigurationToProfile()
                                end)

                                local repCb = self.UI:CreateCheckbox(itemRow, RCL["Repeat"], tsItem.repeatEnabled ~= false)
                                repCb.parentFrame:ClearAllPoints()
                                repCb.parentFrame:SetPoint("LEFT", ttsCb.parentFrame, "RIGHT", 6, 0)
                                repCb.parentFrame:SetWidth(68)
                                MakeSayBox(itemRow, repCb.parentFrame, tsSettings, tsKey, itemData and itemData.name)
                                repCb:SetScript("OnClick", function()
                                    if not tsSettings[tsKey] then tsSettings[tsKey] = {} end
                                    local v = repCb:GetChecked()
                                    tsSettings[tsKey].repeatEnabled = v
                                    RC:ForceCheckboxUpdate(repCb, v)
                                    RC:SaveConfigurationToProfile()
                                end)

                                containerY = containerY - 50
                            end

                            if categoryKey == "utilities" then
                                local stoneIcon = CachedIcon(18262) or 134400
                                local oilIcon = CachedIcon(20749) or 134400
                                local wepIcon = CachedIcon(871) or 134400
                                -- 999901/999902 are not real item ids; they stand in for the
                                -- main-hand/off-hand enchant slots so they can reuse the
                                -- hiddenItems/order/TTS machinery built for real items.
                                local wepRows = {
                                    { label = RCL["Main Hand"],   key = 999901, isHiddenItem = true, icon = stoneIcon },
                                    { label = RCL["Off Hand"],    key = 999902, isHiddenItem = true, icon = stoneIcon },
                                    { label = RCL["Bag Weapons"], key = "bagWeapons", isHiddenItem = false, icon = wepIcon },
                                }
                                for _, row in ipairs(wepRows) do
                                    local itemRow = CreateFrame("Frame", nil, itemContainer)
                                    itemRow:SetHeight(46)
                                    itemRow:SetPoint("TOPLEFT", itemContainer, "TOPLEFT", 10, containerY)
                                    itemRow:SetPoint("RIGHT", itemContainer, "RIGHT", -10, 0)

                                    local icon = itemRow:CreateTexture(nil, "ARTWORK")
                                    icon:SetSize(20, 20)
                                    icon:SetPoint("TOPLEFT", itemRow, "TOPLEFT", 0, -2)
                                    icon:SetTexture(row.icon or stoneIcon)
                                    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                                    local checked
                                    if row.key == "bagWeapons" then
                                        checked = RC.db.consumablesHelper.showBagWeapons ~= false
                                    else
                                        checked = not hiddenItems[row.key]
                                    end
                                    local cb = self.UI:CreateCheckbox(itemRow, row.label, checked)
                                    cb:SetPoint("TOPLEFT", itemRow, "TOPLEFT", 25, 0)
                                    local rowKey = row.key
                                    cb:SetScript("OnClick", function(btn)
                                        local newState = btn:GetChecked()
                                        RC:ForceCheckboxUpdate(btn, newState)
                                        if rowKey == "bagWeapons" then
                                            RC.db.consumablesHelper.showBagWeapons = newState
                                            RC:RefreshWeaponButtons()
                                            if RC.ShowSidebarConsumablesHelperConfig then RC:ShowSidebarConsumablesHelperConfig(frame, true) end
                                        else
                                            if newState then
                                                RC.db.consumablesHelper.hiddenItems[rowKey] = nil
                                            else
                                                RC.db.consumablesHelper.hiddenItems[rowKey] = true
                                            end
                                            RC:RefreshWeaponButtons()
                                        end
                                        RC:SaveConfigurationToProfile()
                                    end)

                                    if not RC.db.consumablesHelper.consumableTTSSettings then
                                        RC.db.consumablesHelper.consumableTTSSettings = {}
                                    end
                                    local wTsSettings = RC.db.consumablesHelper.consumableTTSSettings
                                    local wTsKey  = tostring(rowKey)
                                    local wTsItem = wTsSettings[wTsKey] or {}

                                    local wTtsCb = self.UI:CreateCheckbox(itemRow, "TTS", wTsItem.ttsEnabled ~= false)
                                    wTtsCb.parentFrame:ClearAllPoints()
                                    wTtsCb.parentFrame:SetPoint("TOPLEFT", itemRow, "TOPLEFT", 25, -24)
                                    wTtsCb.parentFrame:SetWidth(46)
                                    wTtsCb:SetScript("OnClick", function()
                                        if not wTsSettings[wTsKey] then wTsSettings[wTsKey] = {} end
                                        local v = wTtsCb:GetChecked()
                                        wTsSettings[wTsKey].ttsEnabled = v
                                        RC:ForceCheckboxUpdate(wTtsCb, v)
                                        RC:SaveConfigurationToProfile()
                                    end)

                                    local wRepCb = self.UI:CreateCheckbox(itemRow, RCL["Repeat"], wTsItem.repeatEnabled ~= false)
                                    wRepCb.parentFrame:ClearAllPoints()
                                    wRepCb.parentFrame:SetPoint("LEFT", wTtsCb.parentFrame, "RIGHT", 6, 0)
                                    wRepCb.parentFrame:SetWidth(68)
                                    MakeSayBox(itemRow, wRepCb.parentFrame, wTsSettings, wTsKey, row and row.label)
                                    wRepCb:SetScript("OnClick", function()
                                        if not wTsSettings[wTsKey] then wTsSettings[wTsKey] = {} end
                                        local v = wRepCb:GetChecked()
                                        wTsSettings[wTsKey].repeatEnabled = v
                                        RC:ForceCheckboxUpdate(wRepCb, v)
                                        RC:SaveConfigurationToProfile()
                                    end)

                                    containerY = containerY - 50
                                end

                                if not RC.db.consumablesHelper.hiddenWeapons then
                                    RC.db.consumablesHelper.hiddenWeapons = {}
                                end
                                do
                                    local function _chSharpenable(slotId, allowPolearm)
                                        local link = GetInventoryItemLink("player", slotId)
                                        if not link then return false end
                                        local _, _, _, _, _, _, sub, _, eqLoc, _, _, classID = self:GetCachedItemInfo(link)
                                        if classID ~= 2 or eqLoc == "INVTYPE_SHIELD" then return false end
                                        local s = sub and sub:lower() or ""
                                        return (s:find("sword") or s:find("axe") or s:find("mace") or s:find("dagger") or s:find("fist") or (allowPolearm and s:find("polearm"))) and true or false
                                    end
                                    local chList = {}
                                    local chSeen = {}
                                    local mhId2 = GetInventoryItemID("player", 16)
                                    if mhId2 and _chSharpenable(16, true) then
                                        chSeen[mhId2] = true
                                        chList[#chList + 1] = { id = mhId2, texture = CachedIcon(mhId2) }
                                    end
                                    local ohId2 = GetInventoryItemID("player", 17)
                                    if ohId2 and not chSeen[ohId2] and _chSharpenable(17, false) then
                                        chSeen[ohId2] = true
                                        chList[#chList + 1] = { id = ohId2, texture = CachedIcon(ohId2) }
                                    end
                                    if RC.db.consumablesHelper.showBagWeapons ~= false then
                                        for _, weapon in ipairs(self:ScanBagWeapons()) do
                                            local iid = weapon.itemId
                                            if iid and not chSeen[iid] then
                                                chSeen[iid] = true
                                                chList[#chList + 1] = { id = iid, texture = weapon.texture or CachedIcon(iid) }
                                            end
                                        end
                                    end
                                    if #chList > 0 then
                                        local gLabel = self:CreateFontString(itemContainer, "OVERLAY", nil, 10)
                                        gLabel:SetPoint("TOPLEFT", itemContainer, "TOPLEFT", 10, containerY)
                                        gLabel:SetText(RCL["Show each weapon (click an icon to toggle):"])
                                        gLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                                        containerY = containerY - 22

                                        local isz, igap = 36, 8
                                        local availW = itemContainer:GetWidth()
                                        if not availW or availW < 60 then availW = 300 end
                                        local perRow = math.floor((availW - 20 + igap) / (isz + igap))
                                        if perRow < 1 then perRow = 1 end
                                        for gi, gw in ipairs(chList) do
                                            local gwid = gw.id
                                            local gcol = (gi - 1) % perRow
                                            local grow = math.floor((gi - 1) / perRow)
                                            local gbtn = CreateIconToggleTile(itemContainer, isz, gw.texture or CachedIcon(gwid) or 134400)
                                            gbtn:SetPoint("TOPLEFT", itemContainer, "TOPLEFT", 10 + gcol * (isz + igap), containerY - grow * (isz + igap))

                                            local function gApply()
                                                gbtn:SetOn(not RC.db.consumablesHelper.hiddenWeapons[gwid])
                                            end
                                            gApply()

                                            gbtn:SetScript("OnClick", function()
                                                if RC.db.consumablesHelper.hiddenWeapons[gwid] then
                                                    RC.db.consumablesHelper.hiddenWeapons[gwid] = nil
                                                else
                                                    RC.db.consumablesHelper.hiddenWeapons[gwid] = true
                                                end
                                                gApply()
                                                RC:RefreshWeaponButtons()
                                                RC:SaveConfigurationToProfile()
                                            end)
                                            gbtn:HookScript("OnEnter", function(sb)
                                                GameTooltip:SetOwner(sb, "ANCHOR_RIGHT")
                                                GameTooltip:SetHyperlink("item:" .. tostring(gwid))
                                                local hid = RC.db.consumablesHelper.hiddenWeapons[gwid]
                                                local sc = hid and RC:GetColor("text", "red") or RC:GetColor("text", "success")
                                                GameTooltip:AddLine(hid and RCL["Hidden - click to show"] or RCL["Shown - click to hide"], sc.r, sc.g, sc.b)
                                                GameTooltip:Show()
                                            end)
                                            gbtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
                                        end
                                        local gRows = math.ceil(#chList / perRow)
                                        containerY = containerY - gRows * (isz + igap) - 6
                                    end
                                end
                            end

                            itemContainer:SetHeight(math.abs(containerY) + 8)
                            yPos = yPos - itemContainer:GetHeight() - 4
                        end
                    end
                end
            end

        end

        if currentTab == "order" then

            if not self.db.consumablesHelper.hiddenItems then
                self.db.consumablesHelper.hiddenItems = {}
            end
            local hiddenItems = self.db.consumablesHelper.hiddenItems

            if not self.db.consumablesHelper.itemOrder then
                self.db.consumablesHelper.itemOrder = {}
            end

            local infoCard = self:CreateSettingsCard(parent, yPos, RCL["Item display order"])
            local cardY = -32

            local infoText = self:CreateFontString(infoCard, "OVERLAY", nil, 10)
            infoText:SetPoint("TOPLEFT", infoCard, "TOPLEFT", 14, cardY)
            infoText:SetWidth(infoCard:GetWidth() - 30)
            infoText:SetText(RCL["Drag items to reorder how they appear on the consumables bar. Items at the top appear first."])
            infoText:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 27

            infoCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - infoCard:GetHeight() - 10

            local availableItems = {}
            local seenBaseIds = {}

            if self.raidConsumables then
                local excludeCategories = {potions = true, protectionPotions = true}

                for categoryKey, category in pairs(self.raidConsumables) do
                    if not excludeCategories[categoryKey] and category.items then
                        for itemId, itemData in pairs(category.items) do
                            local isWeaponStone = itemData.slot ~= nil or itemData.enchantId
                                or RC.weaponStoneIds[itemId]
                            if not isWeaponStone and not self.db.consumablesHelper.hiddenItems[itemId] then
                                local baseId = itemData.baseItemId or itemId
                                if not seenBaseIds[baseId] then
                                    seenBaseIds[baseId] = true
                                    local iconTexture = CachedIcon(itemId) or 134400
                                    table.insert(availableItems, {
                                        itemId = itemId,
                                        baseId = baseId,
                                        name = RC:ItemLabel(itemId, itemData),
                                        icon = iconTexture,
                                        category = categoryKey
                                    })
                                end
                            end
                        end
                    end
                end
            end

            local customItems = self.db.consumablesHelper.customItems
            if customItems then
                for itemId, itemData in pairs(customItems) do
                    local baseId = itemData.baseItemId or itemId
                    if not seenBaseIds[baseId] and not self.db.consumablesHelper.hiddenItems[itemId] then
                        seenBaseIds[baseId] = true
                        local iconTexture = CachedIcon(itemId) or 134400
                        table.insert(availableItems, {
                            itemId = itemId,
                            baseId = baseId,
                            name = itemData.name or "Custom Item",
                            icon = iconTexture,
                            category = itemData.category or "custom"
                        })
                    end
                end
            end

            local stoneIconOrder = CachedIcon(18262) or 134400
            -- Same pseudo item ids as the Items tab's weapon rows (999901/999902/999903).
            if not hiddenItems[999901] then
                table.insert(availableItems, {
                    itemId = 999901,
                    baseId = 999901,
                    name = "Main Hand Enchant",
                    icon = stoneIconOrder,
                    category = "utilities"
                })
            end
            if not hiddenItems[999902] then
                table.insert(availableItems, {
                    itemId = 999902,
                    baseId = 999902,
                    name = "Off Hand Enchant",
                    icon = stoneIconOrder,
                    category = "utilities"
                })
            end
            if RC.db.consumablesHelper.showBagWeapons ~= false then
                table.insert(availableItems, {
                    itemId = 999903,
                    baseId = 999903,
                    name = "Bag Weapons",
                    icon = stoneIconOrder,
                    category = "utilities"
                })
            end

            local customOrder = self.db.consumablesHelper.itemOrder or {}
            local orderLookup = {}
            for i, itemId in ipairs(customOrder) do
                orderLookup[itemId] = i
            end

            table.sort(availableItems, function(a, b)
                local aOrder = orderLookup[a.baseId] or 9999
                local bOrder = orderLookup[b.baseId] or 9999
                if aOrder ~= bOrder then
                    return aOrder < bOrder
                end
                return (a.name or "") < (b.name or "")
            end)

            if #availableItems == 0 then
                local noItemsCard = self:CreateSettingsCard(parent, yPos, RCL["No items"])
                local cardY2 = -32
                local noItemsText = self:CreateFontString(noItemsCard, "OVERLAY", nil, 10)
                noItemsText:SetPoint("TOPLEFT", noItemsCard, "TOPLEFT", 14, cardY2)
                noItemsText:SetText(RCL["No consumable items found. Make sure consumables data is loaded."])
                noItemsText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY2 = cardY2 - 25
                noItemsCard:SetContentHeight(math.abs(cardY2))
                yPos = yPos - noItemsCard:GetHeight() - 10
            else
                local orderCard = self:CreateSettingsCard(parent, yPos, RCL["Drag to reorder ("] .. #availableItems .. RCL[" items)"])
                cardY = -32

                if not self.consumablesOrderDrag then
                    self.consumablesOrderDrag = {}
                end

                local insertIndicator = orderCard:CreateTexture(nil, "OVERLAY")
                insertIndicator:SetHeight(2)
                local ag = RC:GetColor("ui", "accentGold")
                insertIndicator:SetColorTexture(ag.r, ag.g, ag.b, 0.9)
                insertIndicator:Hide()
                self.consumablesOrderDrag.indicator = insertIndicator

                local itemRows = {}

                for i, item in ipairs(availableItems) do
                    local itemRow = CreateFrame("Frame", nil, orderCard)
                    itemRow:SetHeight(28)
                    itemRow:SetPoint("TOPLEFT", orderCard, "TOPLEFT", 14, cardY)
                    itemRow:SetPoint("RIGHT", orderCard, "RIGHT", -14, 0)
                    itemRow.itemId = item.baseId
                    itemRow.itemName = item.name
                    itemRow.index = i

                    local xOffset = 0

                    _sbc.CreateOrderDragHandle(itemRow, self.consumablesOrderDrag,
                        itemRows, availableItems, function(newOrder)
                            RC.db.consumablesHelper.itemOrder = newOrder
                            RC:SaveConfigurationToProfile()
                            RC:ShowSidebarConsumablesHelperConfig(frame, true)
                            RC:UpdateConsumablesButtons()
                        end)

                    xOffset = xOffset + 24

                    local icon = itemRow:CreateTexture(nil, "ARTWORK")
                    icon:SetSize(22, 22)
                    icon:SetPoint("LEFT", itemRow, "LEFT", xOffset, 0)
                    local iconTexture = item.icon
                    if iconTexture and type(iconTexture) == "number" then
                        icon:SetTexture(iconTexture)
                    elseif iconTexture and type(iconTexture) == "string" then
                        icon:SetTexture(iconTexture)
                    else
                        icon:SetTexture(134400)
                    end
                    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    xOffset = xOffset + 26

                    local nameText = self:CreateFontString(itemRow, "OVERLAY", nil, 10)
                    nameText:SetPoint("LEFT", itemRow, "LEFT", xOffset, 0)
                    nameText:SetText(item.name or RCL["Unknown"])
                    nameText:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

                    local orderNum = self:CreateFontString(itemRow, "OVERLAY", nil, 10)
                    orderNum:SetPoint("RIGHT", itemRow, "RIGHT", -5, 0)
                    orderNum:SetText("#" .. i)
                    orderNum:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])

                    table.insert(itemRows, itemRow)
                    cardY = cardY - 27
                end

                cardY = cardY - 5
                orderCard:SetContentHeight(math.abs(cardY))
                yPos = yPos - orderCard:GetHeight() - 10

                local resetCard = self:CreateSettingsCard(parent, yPos, RCL["Reset order"])
                cardY = -32

                local resetBtn = self.UI:CreateStyledButton(resetCard, RCL["Reset to Default"], 120, 22)
                resetBtn:SetPoint("TOPLEFT", resetCard, "TOPLEFT", 14, cardY)
                resetBtn:SetScript("OnClick", function()
                    RC.UI:CreateConfirmDialog(RCL["Reset Item Order"],
                        RCL["Throw away your custom consumables order and go back to alphabetical within each category?"],
                        function()
                            RC.db.consumablesHelper.itemOrder = {}
                            RC:SaveConfigurationToProfile()
                            RC:ShowSidebarConsumablesHelperConfig(frame)
                            RC:UpdateConsumablesButtons()
                        end, nil, RCL["Reset Order"], true)
                end)
                cardY = cardY - 35

                local resetHint = self:CreateFontString(resetCard, "OVERLAY", nil, 10)
                resetHint:SetPoint("TOPLEFT", resetCard, "TOPLEFT", 14, cardY)
                resetHint:SetText(RCL["Resets to alphabetical order within categories"])
                resetHint:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
                cardY = cardY - 20

                resetCard:SetContentHeight(math.abs(cardY))
                yPos = yPos - resetCard:GetHeight() - 10
            end

        end

        if currentTab == "actions" then

            if not self.db.consumablesHelper.conflictGroupQuickUse then
                self.db.consumablesHelper.conflictGroupQuickUse = {}
            end

            local infoCard = self:CreateSettingsCard(parent, yPos, RCL["Quick-use shortcuts"])
            local cardY = -32

            local infoText = self:CreateFontString(infoCard, "OVERLAY", nil, 10)
            infoText:SetPoint("TOPLEFT", infoCard, "TOPLEFT", 14, cardY)
            infoText:SetWidth(infoCard:GetWidth() - 30)
            infoText:SetText(RCL["Assign modifier shortcuts for each conflict group. Shift/Alt/Ctrl+Click on any item in a group uses the assigned item."])
            infoText:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 35

            infoCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - infoCard:GetHeight() - 10

            local function GetItemNameById(itemId)
                if not itemId then return "Click" end
                local name = GetItemInfo(itemId) or RC:FlavorItemName(itemId)
                return name or ("Item #" .. itemId)
            end

            local groupNames = {
                apStrength = "AP / Strength buffs",
                zanza = "Zanza / ROIDS",
                wellFed = "Well Fed buffs",
                hitFood = "Hit food (Bun / Dark Desire)",
                sharpeningStone = "Sharpening stones",
                wizardOil = "Wizard oils",
            }
            if RC.flavorGroupLabels then
                groupNames = {}
                for _, g in ipairs(RC.flavorGroupLabels) do groupNames[g.key] = g.name end
            end

            local modifiers = {
                {key = "click", label = RCL["Click"]},
                {key = "shiftClick", label = RCL["Shift"]},
                {key = "altClick", label = RCL["Alt"]},
                {key = "ctrlClick", label = RCL["Ctrl"]},
            }

            for groupKey, groupDisplayName in pairs(groupNames) do
                local priority = self.conflictGroupPriority and self.conflictGroupPriority[groupKey]
                if priority and #priority > 1 then
                    local groupConfig = self.db.consumablesHelper.conflictGroupQuickUse[groupKey] or {}

                    local groupCard = self:CreateSettingsCard(parent, yPos, groupDisplayName)
                    cardY = -32

                    local headerX = 14
                    for _, mod in ipairs(modifiers) do
                        local headerLabel = self:CreateFontString(groupCard, "OVERLAY", nil, 10)
                        headerLabel:SetPoint("TOPLEFT", groupCard, "TOPLEFT", headerX, cardY)
                        headerLabel:SetWidth(70)
                        headerLabel:SetJustifyH("LEFT")
                        headerLabel:SetText(mod.label)
                        headerLabel:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
                        headerX = headerX + 75
                    end
                    cardY = cardY - 20

                    local dropdownX = 14
                    for _, mod in ipairs(modifiers) do
                        local currentItemId = groupConfig[mod.key]
                        local currentName = GetItemNameById(currentItemId)
                        if #currentName > 10 then
                            currentName = currentName:sub(1, 10) .. "..."
                        end

                        local dropdown = self.UI:CreateScrollableDropdown(groupCard, 70, currentName, 10)
                        dropdown:SetPoint("TOPLEFT", groupCard, "TOPLEFT", dropdownX, cardY + 5)

                        local thisGroup = groupKey
                        local thisKey = mod.key

                        do
                            local DEFAULT = "__default__"
                            local items = {
                                { text = (mod.key == "click" and "Clicked Item" or "None"), value = DEFAULT },
                            }
                            for _, itemId in ipairs(priority) do
                                local itemName = GetItemInfo(itemId) or RC:FlavorItemName(itemId)
                                if itemName then
                                    local count = GetItemCount(itemId)
                                    table.insert(items, {
                                        text  = itemName .. (count > 0 and " (" .. count .. ")" or ""),
                                        value = itemId,
                                        icon  = CachedIcon(itemId),
                                    })
                                end
                            end
                            dropdown:SetItems(items, function(value)
                                RC:SetConflictGroupQuickUse(thisGroup, thisKey, (value == DEFAULT) and nil or value)
                            end)
                            dropdown:SetSelectedValue((currentItemId == nil) and DEFAULT or currentItemId, currentName)
                        end

                        dropdownX = dropdownX + 75
                    end
                    cardY = cardY - 35

                    local clearBtn = self.UI:CreateStyledButton(groupCard, RCL["Clear Shortcuts"], 110, 22)
                    clearBtn:SetPoint("TOPLEFT", groupCard, "TOPLEFT", 14, cardY)
                    clearBtn:SetScript("OnClick", function()
                        RC.UI:CreateConfirmDialog(RCL["Clear Shortcuts"],
                            string.format(RCL["Remove every click shortcut for %s?"], groupDisplayName),
                            function()
                                RC.db.consumablesHelper.conflictGroupQuickUse[groupKey] = {}
                                RC:SaveConfigurationToProfile()
                                RC:ShowSidebarConsumablesHelperConfig(frame)
                            end, nil, RCL["Clear"], true)
                    end)
                    cardY = cardY - 27

                    groupCard:SetContentHeight(math.abs(cardY))
                    yPos = yPos - groupCard:GetHeight() - 10
                end
            end

            local usageCard = self:CreateSettingsCard(parent, yPos, RCL["How it works"])
            cardY = -32

            -- Key column in its own font string (white for the plain click,
            -- gold for the modifiers) with the meaning in text.secondary.
            local usageLines = {
                { key = RCL["Click"],       desc = RCL["Uses the clicked item (or the assigned one)"], plain = true },
                { key = RCL["Shift+Click"], desc = RCL["Uses the Shift-assigned item"] },
                { key = RCL["Alt+Click"],   desc = RCL["Uses the Alt-assigned item"] },
                { key = RCL["Ctrl+Click"],  desc = RCL["Uses the Ctrl-assigned item"] },
            }

            for _, line in ipairs(usageLines) do
                local keyText = self:CreateFontString(usageCard, "OVERLAY", nil, 10)
                keyText:SetPoint("TOPLEFT", usageCard, "TOPLEFT", 14, cardY)
                keyText:SetWidth(80)
                keyText:SetJustifyH("LEFT")
                keyText:SetText(line.key)
                if line.plain then
                    keyText:SetTextColor(TEXT.white[1], TEXT.white[2], TEXT.white[3])
                else
                    keyText:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
                end
                local lineText = self:CreateFontString(usageCard, "OVERLAY", nil, 10)
                -- top-aligned with its key: a wrapped line grows down
                lineText:SetPoint("TOPLEFT", keyText, "TOPRIGHT", 6, 0)
                lineText:SetPoint("RIGHT", usageCard, "RIGHT", -14, 0)
                lineText:SetJustifyH("LEFT")
                lineText:SetText(line.desc)
                lineText:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
                cardY = cardY - math.max(16, (lineText:GetStringHeight() or 12) + 4)
            end
            cardY = cardY - 5

            usageCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - usageCard:GetHeight() - 15
        end

        if currentTab == "text" then yPos = CBS.BuildText(self, frame, "consumablesHelper", parent, yPos) end
        if currentTab == "animation" then yPos = CBS.BuildAnimation(self, frame, "consumablesHelper", parent, yPos, P) end
        if currentTab == "position" then yPos = CBS.BuildPosition(self, frame, "consumablesHelper", parent, yPos) end

        if not self.db.consumablesHelper.enabled then
            self:LockSettingsCards(parent, RCL["The consumables bar is off. Turn it on to change these."], liveCard, 58)
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
        if preserveScroll then
            self:RestoreScrollPosition(self.sidebarConfigFrame)
        end
    end
