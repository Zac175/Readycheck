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
local GetTabHoverBg, GetTabNormalBg, GetTabNormalText, GetTabSelectedBg, GetTabSelectedText, TEXT = _sbc.GetTabHoverBg, _sbc.GetTabNormalBg, _sbc.GetTabNormalText, _sbc.GetTabSelectedBg, _sbc.GetTabSelectedText, _sbc.TEXT
------------------------------------------------------------------------
-- Readycheck - Potions Bar Settings
-- Behavior/Items/Order/Look/Text/Animation/Position tabs edit db.potionsBar
-- (the last four and the preview: Cons_BarStyle.lua).
-- Per-item TTS/Repeat checkboxes write into the shared
-- db.consumablesHelper.consumableTTSSettings table (keyed by item id) -
-- the same store the consumables bar and weapons bar item rows use.
------------------------------------------------------------------------
    function RC:ShowSidebarPotionsBarConfig(frame, preserveScroll)
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local CBS = _sbc.BarPages
        -- the bar itself, drawn by its own button code (Cons_BarStyle)
        local P = CBS.DeclarePreview(self, "potionsBar")
        local parent = frame.scrollChild
        local yPos = -20

        local headerFrame, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Potions Bar"],
            RCL["Quick-access buttons for combat potions"], "Interface\\Icons\\INV_Potion_54")
        yPos = newY

        if not self.db.potionsBar then
            self.db.potionsBar = {enabled = false, locked = false, buttonSize = 36, buttonsPerRow = 10, showBackground = true, iconSpacing = 4, showOnlyAvailable = false, hideWhenActive = false, showBeforeExpiry = 60, hideInCombat = false, visibilityMode = "always"}
        end

        if not self.db.potionsBar.collapsedCategories then
            self.db.potionsBar.collapsedCategories = {}
        end

        -- old tab keys (search aliases, saved state) land on the tab that has them now
        frame.potionsBarTab = CBS.Tab(frame.potionsBarTab, "behavior")

        local _, newTabY = self.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = {
                { key = "behavior", label = RCL["Behavior"] },
                { key = "items", label = RCL["Items"] },
                { key = "order", label = RCL["Order"] },
                { key = "look", label = RCL["Look"] },
                { key = "text", label = RCL["Text"] },
                { key = "animation", label = RCL["Animation"] },
                { key = "position", label = RCL["Position"] },
            },
            selected = frame.potionsBarTab,
            onClick = function(tk)
                frame.potionsBarTab = tk
                RC:ShowSidebarPotionsBarConfig(frame, true)
            end,
            inset = 18,
            fontSize = 10,
            advance = 34,
        })
        yPos = newTabY

        local currentTab = frame.potionsBarTab or "behavior"
        -- the card holding the on switch (Behavior tab): it stays live
        local liveCard

        if currentTab == "behavior" then
            local basicCard = self:CreateSettingsCard(parent, yPos, RCL["General"])
            liveCard = basicCard
            local cardY = -32

            local enableCheck = self.UI:CreateSettingCheckbox(basicCard, cardY, "Enable Potions Bar", self.db.potionsBar.enabled, function(cb)
                local newState = cb:GetChecked()
                RC.db.potionsBar.enabled = newState
                RC:ForceCheckboxUpdate(cb, newState)
                if newState then
                    if not RC.potionsBar.frame then RC:CreatePotionsBarFrame() end
                    if RC.potionsBar.frame then
                        RC.potionsBar.stableStateReached = true
                        RC:UpdatePotionsButtons()
                    end
                end
                -- Show/hide through the visibility evaluator so the bar's
                -- "show in" mode is honoured instead of forcing it on.
                RC:UpdatePotionsVisibility()
                RC:SaveConfigurationToProfile()
                C_Timer.After(0, function() RC:ShowSidebarPotionsBarConfig(frame, true) end)
            end)
            cardY = cardY - 28

            local hideCombatCheck = self.UI:CreateSettingCheckbox(basicCard, cardY, "Hide in combat", self.db.potionsBar.hideInCombat, function(cb)
                local newState = cb:GetChecked()
                RC.db.potionsBar.hideInCombat = newState
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
                RC.db.potionsBar.buttonSize = 28
                RC.db.potionsBar.iconSpacing = 2
                RC.db.potionsBar.showBackground = false
                RC:UpdatePotionsBarBackground()
                RC:UpdatePotionsButtons()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarPotionsBarConfig(frame)
            end)

            local normalBtn = self.UI:CreateStyledButton(displayCard, RCL["Normal"], 70, 22)
            normalBtn:SetPoint("LEFT", compactBtn, "RIGHT", 6, 0)
            normalBtn:SetScript("OnClick", function()
                RC.db.potionsBar.buttonSize = 36
                RC.db.potionsBar.iconSpacing = 4
                RC.db.potionsBar.showBackground = true
                RC:UpdatePotionsBarBackground()
                RC:UpdatePotionsButtons()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarPotionsBarConfig(frame)
            end)
            cardY = cardY - 27

            local sizeLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            sizeLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            sizeLabel:SetText(RCL["Button Size:"])
            sizeLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local sizeSlider = self.UI:CreateSettingSlider(displayCard, 24, 64, self.db.potionsBar.buttonSize or 36, 2, 100, cardY + 5, (self.db.potionsBar.buttonSize or 36) .. "px", function(slider, value)
                value = math.floor(value / 2) * 2
                RC.db.potionsBar.buttonSize = value
                slider.Text:SetText(value .. RCL["px"])
                RC:UpdatePotionsButtons()
            end)
            sizeSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            local perRowLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            perRowLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            perRowLabel:SetText(RCL["Per Row:"])
            perRowLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local perRowSlider = self.UI:CreateSettingSlider(displayCard, 1, 40, self.db.potionsBar.buttonsPerRow or 10, 1, 100, cardY + 5, self.db.potionsBar.buttonsPerRow or 10, function(slider, value)
                value = math.floor(value)
                RC.db.potionsBar.buttonsPerRow = value
                slider.Text:SetText(value)
                RC:UpdatePotionsButtons()
            end)
            perRowSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            local spacingLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            spacingLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            spacingLabel:SetText(RCL["Spacing:"])
            spacingLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local spacingSlider = self.UI:CreateSettingSlider(displayCard, 0, 20, self.db.potionsBar.iconSpacing or 4, 1, 100, cardY + 5, (self.db.potionsBar.iconSpacing or 4) .. "px", function(slider, value)
                value = math.floor(value)
                RC.db.potionsBar.iconSpacing = value
                slider.Text:SetText(value .. RCL["px"])
                RC:UpdatePotionsButtons()
            end)
            spacingSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            if self.db.potionsBar.showBackground == nil then self.db.potionsBar.showBackground = true end
            local bgCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show background and borders", self.db.potionsBar.showBackground, function(cb)
                local newState = cb:GetChecked()
                RC.db.potionsBar.showBackground = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:UpdatePotionsBarBackground()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26

            if self.db.potionsBar.showItemNames == nil then self.db.potionsBar.showItemNames = false end
            local nameCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show item names on icons", self.db.potionsBar.showItemNames, function(cb)
                local newState = cb:GetChecked()
                RC.db.potionsBar.showItemNames = newState
                RC:ForceCheckboxUpdate(cb, newState)
                if RC.UpdatePotionsBarNameLabels then
                    RC:UpdatePotionsBarNameLabels()
                end
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 35

            local ttCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show item tooltips on hover", self.db.potionsBar.showTooltips == true, function(cb)
                local newState = cb:GetChecked()
                RC.db.potionsBar.showTooltips = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 35

            displayCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - displayCard:GetHeight() - 15

            yPos = CBS.BuildLook(self, frame, "potionsBar", parent, yPos)

        end

        if currentTab == "behavior" then
            local behaviorCard = self:CreateSettingsCard(parent, yPos, RCL["Behavior"])
            local cardY = -32

            local showAvailCheck = self.UI:CreateSettingCheckbox(behaviorCard, cardY, "Show only available items", self.db.potionsBar.showOnlyAvailable, function(cb)
                local newState = cb:GetChecked()
                RC.db.potionsBar.showOnlyAvailable = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:UpdatePotionsButtons()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26

            local hideActiveCheck = self.UI:CreateSettingCheckbox(behaviorCard, cardY, "Hide when buff active", self.db.potionsBar.hideWhenActive, function(cb)
                local newState = cb:GetChecked()
                RC.db.potionsBar.hideWhenActive = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:RefreshPotionsDisplay()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26

            local expiryLabel = self:CreateFontString(behaviorCard, "OVERLAY", nil, 11)
            expiryLabel:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 14, cardY)
            expiryLabel:SetText(RCL["Show before expiry:"])
            expiryLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local expirySlider = self.UI:CreateSettingSlider(behaviorCard, 10, 300, self.db.potionsBar.showBeforeExpiry or 60, 5, 140, cardY + 5, (self.db.potionsBar.showBeforeExpiry or 60) .. "s", function(slider, value)
                value = math.floor(value / 5) * 5
                RC.db.potionsBar.showBeforeExpiry = value
                slider.Text:SetText(value .. "s")
            end)
            expirySlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 40

            local pttsCheck = self.UI:CreateCheckbox(behaviorCard,
                RCL["Speak name when expiring (TTS)"],
                self.db.potionsBar.ttsEnabled)
            pttsCheck:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 14, cardY)
            pttsCheck:SetScript("OnClick", function()
                RC.db.potionsBar.ttsEnabled = pttsCheck:GetChecked()
                self:ForceCheckboxUpdate(pttsCheck, RC.db.potionsBar.ttsEnabled)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 22
            local pttsHint = self:CreateFontString(behaviorCard, "OVERLAY", nil, 10)
            pttsHint:SetPoint("TOPLEFT", behaviorCard, "TOPLEFT", 35, cardY)
            pttsHint:SetText(RCL["Volume set in Reminder Settings > Sound"])
            pttsHint:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 18

            if RC.db.potionsBar.petrificationCampMode == nil then
                RC.db.potionsBar.petrificationCampMode = false
            end
            local petrCampCheck = self.UI:CreateSettingCheckbox(behaviorCard, cardY, "Flask of Petrification: also /camp", self.db.potionsBar.petrificationCampMode, function(cb)
                local newState = cb:GetChecked()
                RC.db.potionsBar.petrificationCampMode = newState
                RC:ForceCheckboxUpdate(cb, newState)
                -- Button rebuild touches secure button attributes; skip in combat,
                -- setting still saves and applies on the next rebuild.
                if not InCombatLockdown() then
                    RC:UpdatePotionsButtons()
                end
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26
            -- (2026-11-09) not offered on TBC
            if RC.Flavor and RC:Flavor() == "tbc" then petrCampCheck:Hide() cardY = cardY + 26 end

            behaviorCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - behaviorCard:GetHeight() - 15

        end

        if currentTab == "behavior" then
            local visCard = self:CreateSettingsCard(parent, yPos, RCL["Visibility mode"])
            local cardY = -32

            local visInfo = self:CreateFontString(visCard, "OVERLAY", nil, 10)
            visInfo:SetPoint("TOPLEFT", visCard, "TOPLEFT", 14, cardY)
            visInfo:SetWidth(visCard:GetWidth() - 30)
            visInfo:SetText(RCL["Control when the potions bar is automatically shown."])
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

            cardY = _sbc.BuildVisibilityModeGrid(visCard, cardY, modes, RC.db.potionsBar, function()
                RC:UpdatePotionsVisibility()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarPotionsBarConfig(frame, true)
            end)

            visCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - visCard:GetHeight() - 15
            -- fade rules on top of "Show in" (the customization standard)
            yPos = self.UI:FrameVisibilityCard(parent, yPos, function() return RC.db.potionsBar end,
                function() RC:RestyleBar("potionsBar") end, { fields = { show = true, alpha = true, combatAlpha = true, fadeIn = true, fadeOut = true },
                note = RCL["On top of 'Show in' and the mouseover fade: a rule that is not met fades the bar out."] })

        end

        if currentTab == "items" then

            if not self.db.potionsBar.hiddenItems then
                self.db.potionsBar.hiddenItems = {}
            end
            local hiddenItems = self.db.potionsBar.hiddenItems

            local bulkCard = self:CreateSettingsCard(parent, yPos, RCL["Bulk actions"])
            local cardY = -32

            local showAllBtn = self.UI:CreateStyledButton(bulkCard, RCL["Show All"], 110, 22)
            showAllBtn:SetPoint("TOPLEFT", bulkCard, "TOPLEFT", 14, cardY)
            showAllBtn:SetScript("OnClick", function()
                RC:ShowAllPotionBarItems()
                RC:UpdatePotionsButtons()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarPotionsBarConfig(frame)
            end)

            local hideAllBtn = self.UI:CreateStyledButton(bulkCard, RCL["Hide All"], 110, 22)
            hideAllBtn:SetPoint("LEFT", showAllBtn, "RIGHT", 8, 0)
            hideAllBtn:SetScript("OnClick", function()
                for itemId in pairs(RC.potionBarItems or {}) do
                    RC.db.potionsBar.hiddenItems[itemId] = true
                end
                RC:UpdatePotionsButtons()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarPotionsBarConfig(frame)
            end)
            cardY = cardY - 40

            bulkCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - bulkCard:GetHeight() - 10

            local customCard = self:CreateSettingsCard(parent, yPos, RCL["Custom items"])
            cardY = -32

            local customInfo = self:CreateFontString(customCard, "OVERLAY", nil, 10)
            customInfo:SetPoint("TOPLEFT", customCard, "TOPLEFT", 14, cardY)
            customInfo:SetWidth(customCard:GetWidth() - 30)
            customInfo:SetText(RCL["Add potions/items by ID. Right-click to change category."])
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
                if st and st.key == "potions" and (GetTime() - (st.at or 0)) < 8 then
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
                    RC._customIdStash = { key = "potions", text = selfEB:GetText() or "", at = GetTime() }
                end
            end)
            idEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

            local addBtn = self.UI:CreateStyledButton(inputRow, RCL["Add Item"], 70, 22)
            addBtn:SetPoint("LEFT", idEdit, "RIGHT", 8, 0)
            addBtn:SetScript("OnClick", function()
                local itemId = tonumber(idEdit:GetText())
                if itemId and itemId > 0 then
                    local success, msg = RC:AddCustomConsumableItem(itemId, "potions", "potions")
                    if success then
                        RC:UpdatePotionsButtons()
                        RC:ShowSidebarPotionsBarConfig(frame, true)
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

            local customItemsByCategory = RC:GetCustomItemsByCategory("potions")
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
                                RC:RemoveCustomConsumableItem(itemId, "potions")
                                RC:UpdatePotionsButtons()
                                RC:ShowSidebarPotionsBarConfig(frame, true)
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
                                                RC:SetCustomItemCategory(itemId, "potions", cat.key)
                                                RC:UpdatePotionsButtons()
                                                RC:ShowSidebarPotionsBarConfig(frame, true)
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

            local potSearchText = RC._potionsBarSearch or ""
            local potSearchBox = self.UI:CreateSearchBox(parent, {
                placeholder = RCL["Search potions..."],
                initialText = potSearchText,
                onChange = function(txt)
                    RC._potionsBarSearch = txt
                    RC._potionsBarSearchFocus = true
                    -- Debounce the filtered rebuild until typing pauses, and defer it
                    -- again if some other edit box has focus (avoid stealing it back).
                    if RC._potionsBarSearchTimer then RC._potionsBarSearchTimer:Cancel() end
                    RC._potionsBarSearchTimer = C_Timer.NewTimer(0.6, function()
                        RC._potionsBarSearchTimer = nil
                        if not (RC.sidebarConfigFrame and RC.sidebarConfigFrame:IsVisible()) then RC._potionsBarSearchFocus = nil; return end
                        if RC.SidebarState and RC.SidebarState.currentPanel ~= "potions_bar" then RC._potionsBarSearchFocus = nil; return end
                        if not (RC._potionsBarSearchBox and RC._potionsBarSearchBox.editBox and RC._potionsBarSearchBox.editBox:HasFocus()) then RC._potionsBarSearchFocus = nil end
                        local function tryFilterRebuild()
                            RC._potionsBarSearchTimer = nil
                            local cf = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
                            if cf and cf.IsObjectType and cf:IsObjectType("EditBox")
                               and not (RC._potionsBarSearchBox and cf == RC._potionsBarSearchBox.editBox) then
                                RC._potionsBarSearchTimer = C_Timer.NewTimer(0.6, tryFilterRebuild)
                                return
                            end
                            RC:ShowSidebarPotionsBarConfig(frame, true)
                        end
                        tryFilterRebuild()
                    end)
                end,
            })
            potSearchBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
            potSearchBox:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, yPos)
            RC._potionsBarSearchBox = potSearchBox
            yPos = yPos - 34
            if RC._potionsBarSearchFocus then
                RC._potionsBarSearchFocus = false
                local function _refocus()
                    local eb = potSearchBox and potSearchBox.editBox
                    if not (eb and eb:IsVisible()) then return end
                    local cur = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
                    if cur and cur ~= eb then return end
                    eb:SetFocus(); eb:SetCursorPosition(#(eb:GetText() or ""))
                end
                _refocus()
                C_Timer.After(0, _refocus)
            end
            local potSearchQ = potSearchText:lower()
            local items = {}
            for _, categoryKey in ipairs(self.consumablesHelper.categories or {}) do
                local category = self.raidConsumables and self.raidConsumables[categoryKey]
                if category then
                    for itemId, itemData in pairs(category.items) do
                        if self.potionBarItems and self.potionBarItems[itemId]
                           and (potSearchQ == "" or (itemData.name and itemData.name:lower():find(potSearchQ, 1, true))) then
                            table.insert(items, {id = itemId, data = itemData})
                        end
                    end
                end
            end

            if #items > 0 then
                table.sort(items, function(a, b) return a.data.name < b.data.name end)

                local isCollapsed = self.db.potionsBar.collapsedCategories["combat_potions"]
                if potSearchQ ~= "" then isCollapsed = false end

                _sbc.CreateCollapsibleHeader(parent, yPos,
                    RCL["Combat Potions ("] .. #items .. ")",
                    isCollapsed, function()
                        RC.db.potionsBar.collapsedCategories["combat_potions"] = not isCollapsed
                        RC:SaveConfigurationToProfile()
                        RC:ShowSidebarPotionsBarConfig(frame, true)
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

                        local itemRow = CreateFrame("Frame", nil, itemContainer)
                        itemRow:SetHeight(48)
                        itemRow:SetPoint("TOPLEFT", itemContainer, "TOPLEFT", 10, containerY)
                        itemRow:SetPoint("RIGHT", itemContainer, "RIGHT", -10, 0)

                        local icon = itemRow:CreateTexture(nil, "ARTWORK")
                        icon:SetSize(20, 20)
                        icon:SetPoint("TOPLEFT", itemRow, "TOPLEFT", 0, -1)
                        icon:SetTexture(itemData.icon or GetItemIcon(itemId) or 134400)
                        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                        local isHidden = hiddenItems[itemId]
                        local checkbox = self.UI:CreateCheckbox(itemRow, itemData.name, not isHidden)
                        checkbox:SetPoint("LEFT", icon, "RIGHT", 5, 0)
                        checkbox:SetScript("OnClick", function(cb)
                            local newState = cb:GetChecked()
                            if newState then
                                -- false, not nil: RC.defaults.potionsBar
                                -- .hiddenItems ships some items hidden, and
                                -- Core_Init's FillMissing re-adds any key
                                -- that is missing on the next login.
                                RC.db.potionsBar.hiddenItems[itemId] = false
                            else
                                RC.db.potionsBar.hiddenItems[itemId] = true
                            end
                            RC:ForceCheckboxUpdate(cb, newState)
                            RC:UpdatePotionsButtons()
                            RC:SaveConfigurationToProfile()
                        end)

                        -- Shared TTS-settings store keyed by item id; also read/written
                        -- by the consumables bar and weapons bar item rows.
                        if not RC.db.consumablesHelper.consumableTTSSettings then
                            RC.db.consumablesHelper.consumableTTSSettings = {}
                        end
                        local pTsSettings = RC.db.consumablesHelper.consumableTTSSettings
                        local pTsKey      = tostring(itemId)
                        local pTsItem     = pTsSettings[pTsKey] or {}

                        local pTtsCb = self.UI:CreateCheckbox(itemRow, "TTS", pTsItem.ttsEnabled ~= false)
                        pTtsCb.parentFrame:ClearAllPoints()
                        pTtsCb.parentFrame:SetPoint("TOPLEFT", itemRow, "TOPLEFT", 25, -24)
                        pTtsCb.parentFrame:SetWidth(46)
                        pTtsCb:SetScript("OnClick", function()
                            if not pTsSettings[pTsKey] then pTsSettings[pTsKey] = {} end
                            local v = pTtsCb:GetChecked()
                            pTsSettings[pTsKey].ttsEnabled = v
                            RC:ForceCheckboxUpdate(pTtsCb, v)
                            if v then
                                local btn = RC.potionsBar and RC.potionsBar.buttons and RC.potionsBar.buttons[itemId]
                                if btn then
                                    btn._ttsPlayCount = nil
                                    btn._repeatSessionID = (btn._repeatSessionID or 0) + 1
                                end
                            end
                            RC:SaveConfigurationToProfile()
                        end)

                        local pRepCb = self.UI:CreateCheckbox(itemRow, RCL["Repeat"], pTsItem.repeatEnabled ~= false)
                        pRepCb.parentFrame:ClearAllPoints()
                        pRepCb.parentFrame:SetPoint("LEFT", pTtsCb.parentFrame, "RIGHT", 6, 0)
                        pRepCb.parentFrame:SetWidth(68)
                        pRepCb:SetScript("OnClick", function()
                            if not pTsSettings[pTsKey] then pTsSettings[pTsKey] = {} end
                            local v = pRepCb:GetChecked()
                            pTsSettings[pTsKey].repeatEnabled = v
                            RC:ForceCheckboxUpdate(pRepCb, v)
                            RC:SaveConfigurationToProfile()
                        end)

                        containerY = containerY - 50
                    end

                    itemContainer:SetHeight(math.abs(containerY) + 8)
                    yPos = yPos - itemContainer:GetHeight() - 4
                end
            else
                local noItemsText = self:CreateFontString(parent, "OVERLAY", nil, 10)
                noItemsText:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
                noItemsText:SetText(RCL["No potion items configured"])
                noItemsText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                yPos = yPos - 25
            end

        end

        if currentTab == "order" then
            if not self.db.potionsBar.hiddenItems then
                self.db.potionsBar.hiddenItems = {}
            end
            if not self.db.potionsBar.itemOrder then
                self.db.potionsBar.itemOrder = {}
            end

            local infoCard = self:CreateSettingsCard(parent, yPos, RCL["Item display order"])
            local cardY = -32
            local infoText = self:CreateFontString(infoCard, "OVERLAY", nil, 10)
            infoText:SetPoint("TOPLEFT", infoCard, "TOPLEFT", 14, cardY)
            infoText:SetWidth(infoCard:GetWidth() - 30)
            infoText:SetText(RCL["Drag items to reorder how they appear on the potions bar. Items at the top appear first."])
            infoText:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 27
            infoCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - infoCard:GetHeight() - 10

            local availableItems = {}
            local seenBaseIds = {}
            if self.raidConsumables and self.potionBarItems then
                for categoryKey, category in pairs(self.raidConsumables) do
                    if category.items then
                        for itemId, itemData in pairs(category.items) do
                            if self.potionBarItems[itemId] and not self.db.potionsBar.hiddenItems[itemId] then
                                local baseId = itemData.baseItemId or itemId
                                if not seenBaseIds[baseId] then
                                    seenBaseIds[baseId] = true
                                    table.insert(availableItems, {
                                        itemId = itemId,
                                        baseId = baseId,
                                        name = itemData.name,
                                        icon = GetItemIcon(itemId) or 134400,
                                    })
                                end
                            end
                        end
                    end
                end
            end
            local potionCustom = self.db.potionsBar.customItems
            if potionCustom then
                for itemId, itemData in pairs(potionCustom) do
                    local baseId = itemData.baseItemId or itemId
                    if not seenBaseIds[baseId] and not self.db.potionsBar.hiddenItems[itemId] then
                        seenBaseIds[baseId] = true
                        table.insert(availableItems, {
                            itemId = itemId,
                            baseId = baseId,
                            name = itemData.name or "Custom Item",
                            icon = GetItemIcon(itemId) or 134400,
                        })
                    end
                end
            end

            local customOrder = self.db.potionsBar.itemOrder or {}
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
                noItemsText:SetText(RCL["No potion items found. Enable some in the Items tab first."])
                noItemsText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY2 = cardY2 - 25
                noItemsCard:SetContentHeight(math.abs(cardY2))
                yPos = yPos - noItemsCard:GetHeight() - 10
            else
                local orderCard = self:CreateSettingsCard(parent, yPos, RCL["Drag to reorder ("] .. #availableItems .. RCL[" items)"])
                cardY = -32

                if not self.potionsOrderDrag then
                    self.potionsOrderDrag = {}
                end

                local insertIndicator = orderCard:CreateTexture(nil, "OVERLAY")
                insertIndicator:SetHeight(2)
                local ag = RC:GetColor("ui", "accentGold")
                insertIndicator:SetColorTexture(ag.r, ag.g, ag.b, 0.9)
                insertIndicator:Hide()
                self.potionsOrderDrag.indicator = insertIndicator

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

                    _sbc.CreateOrderDragHandle(itemRow, self.potionsOrderDrag,
                        itemRows, availableItems, function(newOrder)
                            RC.db.potionsBar.itemOrder = newOrder
                            RC:SaveConfigurationToProfile()
                            RC:ShowSidebarPotionsBarConfig(frame, true)
                            RC:UpdatePotionsButtons()
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
                    RC.UI:CreateConfirmDialog(RCL["Reset Potion Order"],
                        RCL["Throw away your custom potion order and go back to alphabetical?"],
                        function()
                            RC.db.potionsBar.itemOrder = {}
                            RC:SaveConfigurationToProfile()
                            RC:ShowSidebarPotionsBarConfig(frame)
                            RC:UpdatePotionsButtons()
                        end, nil, RCL["Reset Order"], true)
                end)
                cardY = cardY - 35
                local resetHint = self:CreateFontString(resetCard, "OVERLAY", nil, 10)
                resetHint:SetPoint("TOPLEFT", resetCard, "TOPLEFT", 14, cardY)
                resetHint:SetText(RCL["Resets to alphabetical order"])
                resetHint:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
                cardY = cardY - 20
                resetCard:SetContentHeight(math.abs(cardY))
                yPos = yPos - resetCard:GetHeight() - 10
            end
        end

        if currentTab == "text" then yPos = CBS.BuildText(self, frame, "potionsBar", parent, yPos) end
        if currentTab == "animation" then yPos = CBS.BuildAnimation(self, frame, "potionsBar", parent, yPos, P) end
        if currentTab == "position" then yPos = CBS.BuildPosition(self, frame, "potionsBar", parent, yPos) end

        if not self.db.potionsBar.enabled then
            self:LockSettingsCards(parent, RCL["The potions bar is off. Turn it on to change these."], liveCard, 58)
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
        if preserveScroll then
            self:RestoreScrollPosition(self.sidebarConfigFrame)
        end
    end
