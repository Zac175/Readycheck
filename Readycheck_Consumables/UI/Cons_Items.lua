------------------------------------------------------------------------
-- Readycheck - Consumables/Potions Item Manager
-- Bulk show/hide list for bar items. barType "main" edits
-- db.consumablesHelper.hiddenItems, barType "potions" edits
-- db.potionsBar.hiddenItems. Excludes weapon-slot/stone items (slot or
-- enchantId set, plus the hardcoded stone/oil ids below) since those
-- live on the weapons bar instead.
------------------------------------------------------------------------
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
local TEXT = _sbc.TEXT
    function RC:ShowSidebarConsumablesItemManager(frame)
        self:ClearSidebarContent(self.sidebarConfigFrame)
        local parent = frame.scrollChild
        local yPos = -20
        local barType = frame.consumablesBarType or "main"

        local backButton = self.UI:CreateBackButton(parent, RCL["Back"], 80, 22)
        backButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
        backButton:SetScript("OnClick", function()
            if barType == "main" then
                RC:ShowSidebarConsumablesHelperConfig(frame)
            else
                RC:ShowSidebarPotionsBarConfig(frame)
            end
        end)

        local title = barType == "main" and "Consumables Bar" or "Potions Bar"
        -- Page-header title size (15px gold) beside the back button.
        local header = self:CreateFontString(parent, "OVERLAY", nil, 15)
        header:SetPoint("LEFT", backButton, "RIGHT", 14, 0)
        header:SetText(RCL["Manage "] .. title .. RCL[" Items"])
        header:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
        yPos = yPos - 50

        local hiddenItems
        if barType == "main" then
            if not self.db.consumablesHelper.hiddenItems then
                self.db.consumablesHelper.hiddenItems = {}
            end
            hiddenItems = self.db.consumablesHelper.hiddenItems
        else
            if not self.db.potionsBar.hiddenItems then
                self.db.potionsBar.hiddenItems = {}
            end
            hiddenItems = self.db.potionsBar.hiddenItems
        end

        local bulkCard = self:CreateSettingsCard(parent, yPos, RCL["Bulk actions"])
        local cardY = -32

        local showAllBtn = self.UI:CreateStyledButton(bulkCard, RCL["Show All"], 110, 22)
        showAllBtn:SetPoint("TOPLEFT", bulkCard, "TOPLEFT", 14, cardY)
        showAllBtn:SetScript("OnClick", function()
            if barType == "main" then
                RC.db.consumablesHelper.hiddenItems = {}
                RC:UpdateConsumablesButtons()
            else
                RC:ShowAllPotionBarItems()
                RC:UpdatePotionsButtons()
            end
            RC:SaveConfigurationToProfile()
            RC:ShowSidebarConsumablesItemManager(frame)
        end)

        local hideAllBtn = self.UI:CreateStyledButton(bulkCard, RCL["Hide All"], 110, 22)
        hideAllBtn:SetPoint("LEFT", showAllBtn, "RIGHT", 10, 0)
        hideAllBtn:SetScript("OnClick", function()
            if barType == "main" then
                for _, categoryKey in ipairs(RC.consumablesHelper.categories) do
                    local category = RC.raidConsumables[categoryKey]
                    if category then
                        for itemId, itemData in pairs(category.items) do
                            if not RC.potionBarItems[itemId] then
                                RC.db.consumablesHelper.hiddenItems[itemId] = true
                            end
                        end
                    end
                end
                RC:UpdateConsumablesButtons()
            else
                for itemId in pairs(RC.potionBarItems) do
                    RC.db.potionsBar.hiddenItems[itemId] = true
                end
                RC:UpdatePotionsButtons()
            end
            RC:SaveConfigurationToProfile()
            RC:ShowSidebarConsumablesItemManager(frame)
        end)
        cardY = cardY - 40

        bulkCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - bulkCard:GetHeight() - 15

        if barType == "main" then
            for _, categoryKey in ipairs(self.consumablesHelper.categories or {}) do
                local category = self.raidConsumables and self.raidConsumables[categoryKey]
                if category then
                    local items = {}
                    for itemId, itemData in pairs(category.items) do
                        if not self.potionBarItems[itemId] and not (itemData.slot ~= nil or itemData.enchantId
                            or RC.weaponStoneIds[itemId]) then
                            table.insert(items, {id = itemId, data = itemData})
                        end
                    end

                    if #items > 0 then
                        table.sort(items, function(a, b) return a.data.name < b.data.name end)

                        local catCard = self:CreateSettingsCard(parent, yPos, category.name)
                        cardY = -32

                        for _, item in ipairs(items) do
                            local itemId = item.id
                            local itemData = item.data

                            local itemRow = CreateFrame("Frame", nil, catCard)
                            itemRow:SetHeight(24)
                            itemRow:SetPoint("TOPLEFT", catCard, "TOPLEFT", 14, cardY)
                            itemRow:SetPoint("RIGHT", catCard, "RIGHT", -14, 0)

                            local icon = itemRow:CreateTexture(nil, "ARTWORK")
                            icon:SetSize(22, 22)
                            icon:SetPoint("LEFT", itemRow, "LEFT", 0, 0)
                            icon:SetTexture(itemData.icon)
                            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                            local isHidden = hiddenItems[itemId]
                            local checkbox = self.UI:CreateCheckbox(itemRow, itemData.name, not isHidden)
                            checkbox:SetPoint("LEFT", icon, "RIGHT", 5, 0)
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

                            cardY = cardY - 27
                        end

                        catCard:SetContentHeight(math.abs(cardY))
                        yPos = yPos - catCard:GetHeight() - 10
                    end
                end
            end
        else
            local potionsCard = self:CreateSettingsCard(parent, yPos, RCL["Combat potions"])
            cardY = -32

            local items = {}
            for _, categoryKey in ipairs(self.consumablesHelper.categories or {}) do
                local category = self.raidConsumables and self.raidConsumables[categoryKey]
                if category then
                    for itemId, itemData in pairs(category.items) do
                        if self.potionBarItems and self.potionBarItems[itemId] then
                            table.insert(items, {id = itemId, data = itemData})
                        end
                    end
                end
            end

            table.sort(items, function(a, b) return a.data.name < b.data.name end)

            for _, item in ipairs(items) do
                local itemId = item.id
                local itemData = item.data

                local itemRow = CreateFrame("Frame", nil, potionsCard)
                itemRow:SetSize(potionsCard:GetWidth() - 28, 24)
                itemRow:SetPoint("TOPLEFT", potionsCard, "TOPLEFT", 14, cardY)

                local icon = itemRow:CreateTexture(nil, "ARTWORK")
                icon:SetSize(22, 22)
                icon:SetPoint("LEFT", itemRow, "LEFT", 0, 0)
                icon:SetTexture(itemData.icon)
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                local isHidden = hiddenItems[itemId]
                local checkbox = self.UI:CreateCheckbox(itemRow, itemData.name, not isHidden)
                checkbox:SetPoint("LEFT", icon, "RIGHT", 5, 0)
                checkbox:SetScript("OnClick", function(cb)
                    local newState = cb:GetChecked()
                    if newState then
                        -- false, not nil - see RC:ShowAllPotionBarItems.
                        RC.db.potionsBar.hiddenItems[itemId] = false
                    else
                        RC.db.potionsBar.hiddenItems[itemId] = true
                    end
                    RC:ForceCheckboxUpdate(cb, newState)
                    RC:UpdatePotionsButtons()
                    RC:SaveConfigurationToProfile()
                end)

                cardY = cardY - 27
            end

            if #items == 0 then
                local noItems = self:CreateFontString(potionsCard, "OVERLAY", nil, 10)
                noItems:SetPoint("TOPLEFT", potionsCard, "TOPLEFT", 14, cardY)
                noItems:SetText(RCL["No potion items configured"])
                noItems:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
                cardY = cardY - 25
            end

            potionsCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - potionsCard:GetHeight() - 15
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end
