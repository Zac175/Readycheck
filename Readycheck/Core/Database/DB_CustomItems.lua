local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)
local RC = _G.Readycheck
if not RC then
    print("ERROR: Readycheck not initialized before Database files")
    return
end
------------------------------------------------------------------------
-- Readycheck - Custom Consumable Items
-- User-added items for the three consumable bars ("consumables" helper,
-- "potions" bar, "checker"), each stored in its own db.*.customItems
-- table keyed by itemId. Legacy behavior mirrors an item added under
-- "consumables" or "checker" into the other's table too; _purgeMirrorTwins
-- (DB_Consumables.lua) removes exact-duplicate mirrors left by that.
------------------------------------------------------------------------
local _purgeMirrorTwins = RC._dbs and RC._dbs._purgeMirrorTwins
if _purgeMirrorTwins then _purgeMirrorTwins(RC) end
    function RC:AddCustomConsumableItem(itemId, barType, category, opts)
        if not itemId or itemId <= 0 then return false, "Invalid item ID" end

        barType = barType or "consumables"
        category = category or "custom"
        opts = opts or {}

        local customBuffId
        if opts.buffId ~= nil then
            customBuffId = tonumber(opts.buffId)
            if customBuffId and customBuffId <= 0 then customBuffId = nil end
        end

        local customMaterials
        if type(opts.materials) == "table" and #opts.materials > 0 then
            customMaterials = {}
            for _, mat in ipairs(opts.materials) do
                local matId = tonumber(mat.itemId)
                local matQty = tonumber(mat.qty) or 1
                if matId and matId > 0 and matQty > 0 then
                    table.insert(customMaterials, {
                        itemId = matId,
                        qty = matQty,
                        name = mat.name,
                        ahSearchName = mat.ahSearchName,
                    })
                end
            end
            if #customMaterials == 0 then customMaterials = nil end
        end

        local customItems
        if barType == "potions" then
            if not self.db.potionsBar then self.db.potionsBar = {} end
            if not self.db.potionsBar.customItems then self.db.potionsBar.customItems = {} end
            customItems = self.db.potionsBar.customItems
        elseif barType == "checker" then
            if not self.db.consumablesChecker then self.db.consumablesChecker = {} end
            if not self.db.consumablesChecker.customItems then self.db.consumablesChecker.customItems = {} end
            customItems = self.db.consumablesChecker.customItems
        else
            if not self.db.consumablesHelper then self.db.consumablesHelper = {} end
            if not self.db.consumablesHelper.customItems then self.db.consumablesHelper.customItems = {} end
            customItems = self.db.consumablesHelper.customItems
        end

        if customItems[itemId] then
            return false, "Item already added"
        end

        for _, cat in pairs(self.raidConsumables or {}) do
            if cat.items and cat.items[itemId] then
                return false, "Item already in default list"
            end
        end

        local maxOrder = 0
        for _, itemData in pairs(customItems) do
            if itemData.sortOrder and itemData.sortOrder > maxOrder then
                maxOrder = itemData.sortOrder
            end
        end

        if customBuffId then
            self._buffIdLookup[itemId] = customBuffId
            self._consumableSpellIdSet[customBuffId] = true
            if self._consumableBuffNameSet and GetSpellInfo then
                local bn = GetSpellInfo(customBuffId)
                if bn then
                    self._consumableBuffNameSet[bn:lower()] = true
                    if self._buffNameById then
                        self._buffNameById[customBuffId] = bn:lower()
                    end
                end
            end
        end

        local itemName, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(itemId)

        -- Item not yet in the client cache: store a placeholder and resolve
        -- it via GET_ITEM_INFO_RECEIVED plus a bounded poll fallback.
        if not itemName then
            customItems[itemId] = {
                name = "Loading... (ID: " .. itemId .. ")",
                icon = 134400,
                recommended = 5,
                buffId = customBuffId,
                materials = customMaterials,
                category = category,
                sortOrder = maxOrder + 1,
                pending = true,
                pendingItemId = itemId,
                pendingBarType = barType
            }

            if not self.pendingItemInfoFrame then
                self.pendingItemInfoFrame = CreateFrame("Frame")
                self.pendingItemInfoFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
                self.pendingItemInfoFrame:SetScript("OnEvent", function(frame, event, receivedItemId, success)
                    if event == "GET_ITEM_INFO_RECEIVED" and success then
                        self:OnItemInfoReceived(receivedItemId)
                    end
                end)
            end

            local attempts = 0
            local function TryLoadItem()
                attempts = attempts + 1
                local name, _, _, _, _, _, _, _, _, texture = GetItemInfo(itemId)
                if name then
                    self:OnItemInfoReceived(itemId)
                elseif attempts < 10 then
                    C_Timer.After(0.5, TryLoadItem)
                end
            end
            C_Timer.After(0.3, TryLoadItem)

            self:SaveConfigurationToProfile()
            return true, "Item added (loading info...)"
        end

        customItems[itemId] = {
            name = itemName,
            icon = itemTexture or 134400,
            recommended = 5,
            buffId = customBuffId,
            materials = customMaterials,
            category = category,
            sortOrder = maxOrder + 1
        }

        self:SaveConfigurationToProfile()
        self:DebugPrint("Custom item added: " .. itemName .. " (ID: " .. itemId .. ") to category: " .. category, "items")
        if barType ~= "potions" and barType ~= "checker" then
            self._flatConsumableItemsDirty = true
        end

        return true, "Item added: " .. itemName
    end

    -- A pending item could have been added under any of the three bar
    -- types, so all three are checked regardless of which one triggered
    -- the GET_ITEM_INFO_RECEIVED event.
    function RC:OnItemInfoReceived(itemId)
        local updated = false

        local tables = {
            {db = self.db.consumablesChecker, key = "customItems", barType = "checker"},
            {db = self.db.consumablesHelper, key = "customItems", barType = "consumables"},
            {db = self.db.potionsBar, key = "customItems", barType = "potions"}
        }

        for _, tbl in ipairs(tables) do
            if tbl.db and tbl.db[tbl.key] and tbl.db[tbl.key][itemId] and tbl.db[tbl.key][itemId].pending then
                local itemData = tbl.db[tbl.key][itemId]
                local name, _, _, _, _, _, _, _, _, texture = GetItemInfo(itemId)

                if name then
                    itemData.name = name
                    itemData.icon = texture or 134400
                    itemData.pending = nil
                    itemData.pendingItemId = nil
                    itemData.pendingBarType = nil
                    updated = true
                    self:DebugPrint("Custom item loaded: " .. name .. " (ID: " .. itemId .. ")", "items")
                end
            end
        end

        if updated then
            self:SaveConfigurationToProfile()

            if self.PopulateConsumablesChecker then
                C_Timer.After(0.1, function()
                    self:PopulateConsumablesChecker()
                end)
            end
            if self.UpdateConsumablesHelperDisplay then
                C_Timer.After(0.1, function()
                    self:UpdateConsumablesHelperDisplay()
                end)
            end
            if self.UpdatePotionsBar then
                C_Timer.After(0.1, function()
                    self:UpdatePotionsBar()
                end)
            end
        end
    end

    function RC:RemoveCustomConsumableItem(itemId, barType)
        if not itemId then return false end

        barType = barType or "consumables"

        local customItems
        if barType == "potions" then
            customItems = self.db.potionsBar and self.db.potionsBar.customItems
        elseif barType == "checker" then
            customItems = self.db.consumablesChecker and self.db.consumablesChecker.customItems
        else
            customItems = self.db.consumablesHelper and self.db.consumablesHelper.customItems
        end

        if customItems and customItems[itemId] then
            local itemName = customItems[itemId].name or "Unknown"
            customItems[itemId] = nil
            self:SaveConfigurationToProfile()
            self:DebugPrint("Custom item removed: " .. itemName .. " (ID: " .. itemId .. ")", "items")
            if barType ~= "potions" and barType ~= "checker" then
                self._flatConsumableItemsDirty = true
            end

            -- Remove the legacy mirrored copy too (see header note on
            -- consumables/checker mirroring), so it doesn't reappear later.
            if barType == "consumables" or barType == "checker" then
                local mirror
                if barType == "consumables" then
                    mirror = self.db.consumablesChecker and self.db.consumablesChecker.customItems
                else
                    mirror = self.db.consumablesHelper and self.db.consumablesHelper.customItems
                end
                if mirror and mirror[itemId] then
                    mirror[itemId] = nil
                    self._flatConsumableItemsDirty = true
                end
            end

            return true
        end

        return false
    end

    function RC:SetCustomItemCategory(itemId, barType, newCategory)
        if not itemId then return false end

        local customItems = self:GetCustomConsumableItems(barType)
        if customItems and customItems[itemId] then
            customItems[itemId].category = newCategory or "custom"
            if barType == "consumables" or barType == "checker" then
                local other = (barType == "consumables")
                    and (self.db.consumablesChecker and self.db.consumablesChecker.customItems)
                    or  (self.db.consumablesHelper and self.db.consumablesHelper.customItems)
                if other and other[itemId] then other[itemId].category = newCategory or "custom" end
                self._flatConsumableItemsDirty = true
            end
            self:SaveConfigurationToProfile()
            self:DebugPrint("Custom item " .. itemId .. " moved to category: " .. newCategory, "items")
            return true
        end
        return false
    end

    function RC:MoveCustomItem(itemId, barType, direction)
        if not itemId then return false end

        local customItems = self:GetCustomConsumableItems(barType)
        if not customItems or not customItems[itemId] then return false end

        local currentItem = customItems[itemId]
        local currentOrder = currentItem.sortOrder or 0
        local currentCategory = currentItem.category or "custom"

        local categoryItems = {}
        for id, data in pairs(customItems) do
            if (data.category or "custom") == currentCategory then
                table.insert(categoryItems, {id = id, data = data, sortOrder = data.sortOrder or 0})
            end
        end

        table.sort(categoryItems, function(a, b) return a.sortOrder < b.sortOrder end)

        local currentIndex = nil
        for i, item in ipairs(categoryItems) do
            if item.id == itemId then
                currentIndex = i
                break
            end
        end

        if not currentIndex then return false end

        local targetIndex
        if direction == "up" then
            targetIndex = currentIndex - 1
        else
            targetIndex = currentIndex + 1
        end

        if targetIndex < 1 or targetIndex > #categoryItems then
            return false
        end

        local targetItem = categoryItems[targetIndex]
        local tempOrder = currentItem.sortOrder
        currentItem.sortOrder = targetItem.data.sortOrder
        targetItem.data.sortOrder = tempOrder

        self:SaveConfigurationToProfile()
        return true
    end

    function RC:GetCustomConsumableItems(barType)
        barType = barType or "consumables"

        if barType == "potions" then
            return self.db.potionsBar and self.db.potionsBar.customItems or {}
        elseif barType == "checker" then
            return self.db.consumablesChecker and self.db.consumablesChecker.customItems or {}
        else
            return self.db.consumablesHelper and self.db.consumablesHelper.customItems or {}
        end
    end

    function RC:GetCustomItemsByCategory(barType)
        local customItems = self:GetCustomConsumableItems(barType)
        local byCategory = {}

        for itemId, itemData in pairs(customItems) do
            local cat = itemData.category or "custom"
            if not byCategory[cat] then
                byCategory[cat] = {}
            end
            table.insert(byCategory[cat], {id = itemId, data = itemData})
        end

        for cat, items in pairs(byCategory) do
            table.sort(items, function(a, b)
                return (a.data.sortOrder or 0) < (b.data.sortOrder or 0)
            end)
        end

        return byCategory
    end

    function RC:RefreshCustomItemInfo()
        local barTypes = {"consumables", "potions", "checker"}

        for _, barType in ipairs(barTypes) do
            local customItems = self:GetCustomConsumableItems(barType)
            for itemId, itemData in pairs(customItems) do
                if itemData.pending then
                    local name, _, _, _, _, _, _, _, _, texture = GetItemInfo(itemId)
                    if name then
                        itemData.name = name
                        itemData.icon = texture or 134400
                        itemData.pending = nil
                    end
                end
                if not itemData.category then
                    itemData.category = "custom"
                end
                if type(itemData.buffId) == "number" and itemData.buffId > 0 then
                    self._buffIdLookup[itemId] = itemData.buffId
                    self._consumableSpellIdSet[itemData.buffId] = true
                end
            end
        end
    end

