------------------------------------------------------------------------
-- Readycheck - Consumables Checker: Row/Category Rendering
-- Builds category sections and item rows from RC.raidConsumables plus
-- custom/overridden items, colors rows by stock status, and prints the
-- chat "/rc" consumables report. Bag counts are rescanned in full each
-- call, driven only by the 2s ticker in Checker_Window.lua.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format = string.format
local GetTime = GetTime
local GetItemCount = GetItemCount or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemCount)
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local WRF = _G.Readycheck
if not WRF then return end
WRF._cckInit = WRF._cckInit or {}
WRF._cck = WRF._cck or {}
WRF._cckInit[#WRF._cckInit + 1] = function()
    local RC = _G.Readycheck
    local _cck = WRF._cck
    local IsWeaponStone = _cck.IsWeaponStone

    -- One full 5-bag count scan, shared by the display refresh and the chat
    -- report. C_Container ships on Classic Era; no fallback path is needed.
    local function ScanBagCounts()
        local bagCounts = {}
        for bag = 0, 4 do
            local numSlots = C_Container.GetContainerNumSlots(bag) or 0
            for slot = 1, numSlots do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID then
                    bagCounts[info.itemID] = (bagCounts[info.itemID] or 0) + (info.stackCount or 1)
                end
            end
        end
        return bagCounts
    end

    -- Category-header pool, mirroring the row pool in Checker_Popup.lua:
    -- every populate rebuilds all headers, so they are reused by index
    -- instead of being detached and recreated per collapse click. Callers
    -- reset all dynamic state (text, colors, scripts) on every acquire.
    local headerPool = {}
    local headerPoolUsed = 0
    local function ResetHeaderPool()
        headerPoolUsed = 0
        for i = 1, #headerPool do
            headerPool[i]:Hide()
        end
    end
    -- One header's pieces, built once per pooled header (and by the
    -- settings preview's sample window, so it looks exactly like these).
    local function BuildHeaderParts(f)
        f:SetHeight(20)

        f.dropHighlight = f:CreateTexture(nil, "BACKGROUND")
        f.dropHighlight:SetAllPoints()

        f.dropHighlight:SetTexture(RC.UI.FLAT)

        -- Section header: 10px title, 1px rule running out to the
        -- right edge (gold under the built-in categories, per spec).
        f.title = RC:CreateFontString(f, "OVERLAY", nil, 10)
        f.title:SetPoint("LEFT", f, "LEFT", 6, 0)

        f.headerLine = f:CreateTexture(nil, "ARTWORK")
        f.headerLine:SetPoint("LEFT", f.title, "RIGHT", 6, 0)
        f.headerLine:SetPoint("RIGHT", f, "RIGHT", -6, 0)
        f.headerLine:SetHeight(1)
        f.headerLine:SetTexture(RC.UI.FLAT)
    end
    -- A built-in category's header text and colours ("[-] FLASKS (3)", gold).
    local function DressCategoryHeader(f, name, count, isCollapsed)
        local accentGold = RC:GetColor("ui", "accentGold")
        local collapseIndicator = isCollapsed and "[+] " or "[-] "
        local itemCount = count > 0 and (" (" .. count .. ")") or ""
        f.title:SetText(collapseIndicator .. string.upper(name) .. itemCount)
        f.title:SetTextColor(accentGold.r, accentGold.g, accentGold.b, 1)
        f.headerLine:SetVertexColor(accentGold.r, accentGold.g, accentGold.b, 0.3)
    end
    -- The settings preview's sample header: the same pieces, no scripts,
    -- never in the pool.
    function RC:NewCheckerHeaderSample(parent)
        local f = CreateFrame("Button", nil, parent)
        BuildHeaderParts(f)
        f:EnableMouse(false)
        f.dropHighlight:Hide()
        return f
    end
    function RC:FillCheckerHeaderSample(f, name, count, isCollapsed)
        DressCategoryHeader(f, name, count or 0, isCollapsed)
    end
    local function AcquireHeaderFrame(parent, yOffset)
        headerPoolUsed = headerPoolUsed + 1
        local f = headerPool[headerPoolUsed]
        if not f then
            f = CreateFrame("Button", nil, parent)
            BuildHeaderParts(f)

            headerPool[headerPoolUsed] = f
        end
        f:SetParent(parent)
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yOffset)
        f:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yOffset)
        f:Show()
        f.dropHighlight:Hide()
        f.items = {}
        return f
    end

    function RC:CreateCategorySection(parent, categoryKey, yOffset)
        local category = self.raidConsumables[categoryKey]
        if not category then return yOffset end

        local missingItems, lowItems, mediumItems, goodItems, disabledItems = {}, {}, {}, {}, {}

        -- Row status bucket, not the raid-entry alert's missing check
        -- (Checker_Base.RunRaidConsumablesCheck): here count==0 is "missing",
        -- below half of recommended is "low", below full recommended is
        -- "medium". The 0.5 threshold is duplicated in
        -- UpdateConsumablesCheckerDisplay and must stay in sync or the
        -- category badge count and the live per-row color diverge.
        local function AddItemToList(itemId, itemData)
            if self.db.consumablesChecker.disabledItems and self.db.consumablesChecker.disabledItems[itemId] then
                table.insert(disabledItems, {id = itemId, data = itemData})
            else
                local count = GetItemCount(itemData.baseItemId or itemId, false, false)
                -- a merged row (every poison rank, every dummy) counts all
                -- of its items, as the row itself shows
                if itemData.aggregateItemIds then
                    count = 0
                    for _, aid in ipairs(itemData.aggregateItemIds) do
                        count = count + (GetItemCount(aid, false, false) or 0)
                    end
                end
                local recommended = self:GetRecommendedCount(itemId, itemData)
                local lowThreshold = math.max(1, math.floor(recommended * 0.5))

                if count == 0 then
                    table.insert(missingItems, {id = itemId, data = itemData, count = count})
                elseif recommended > 0 and count < lowThreshold then
                    table.insert(lowItems, {id = itemId, data = itemData, count = count})
                elseif recommended > 0 and count < recommended then
                    table.insert(mediumItems, {id = itemId, data = itemData, count = count})
                else
                    table.insert(goodItems, {id = itemId, data = itemData, count = count})
                end
            end
        end

        -- Weapon stones/oils render in the weapons bar, not this window.
        for itemId, itemData in pairs(category.items) do
            if not IsWeaponStone(itemData) then
                if itemData.faction then
                    local playerFaction = UnitFactionGroup("player")
                    if playerFaction ~= itemData.faction then
                    else
                        local effectiveCategory = self:GetItemEffectiveCategory(itemId, categoryKey)
                        if effectiveCategory == categoryKey then
                            AddItemToList(itemId, itemData)
                        end
                    end
                else
                    local effectiveCategory = self:GetItemEffectiveCategory(itemId, categoryKey)
                    if effectiveCategory == categoryKey then
                        AddItemToList(itemId, itemData)
                    end
                end
            end
        end

        -- Custom checker items, added ONCE each: a category override
        -- (moving the item to another category) wins over the item's own
        -- stored category. The raw customData is used so its recommended
        -- count, icon and materials all carry through.
        local checkerCustoms = self:GetCustomConsumableItems("checker")
        for itemId, customData in pairs(checkerCustoms) do
            local effectiveCategory = self:GetItemEffectiveCategory(itemId, customData.category or "custom")
            if effectiveCategory == categoryKey then
                AddItemToList(itemId, customData)
            end
        end

        if self.GetOverriddenItemsForCategory then
            local movedItems = self:GetOverriddenItemsForCategory(categoryKey)
            for itemId, info in pairs(movedItems) do
                local itemData = info.data
                itemData.movedFrom = info.originalCategory
                AddItemToList(itemId, itemData)
            end
        end

        table.sort(missingItems, function(a, b) return a.data.name < b.data.name end)
        table.sort(lowItems, function(a, b) return a.data.name < b.data.name end)
        table.sort(mediumItems, function(a, b) return a.data.name < b.data.name end)
        table.sort(goodItems, function(a, b) return a.data.name < b.data.name end)
        table.sort(disabledItems, function(a, b) return a.data.name < b.data.name end)

        local enabledItems = {}
        for _, item in ipairs(missingItems) do table.insert(enabledItems, item) end
        for _, item in ipairs(lowItems) do table.insert(enabledItems, item) end
        for _, item in ipairs(mediumItems) do table.insert(enabledItems, item) end
        for _, item in ipairs(goodItems) do table.insert(enabledItems, item) end

        if self.GetSortedCheckerItems then
            enabledItems = self:GetSortedCheckerItems(categoryKey, enabledItems)
        end

        if #enabledItems > 0 or self.consumablesChecker.editMode then
            local isCollapsed = self.db.consumablesChecker.collapsedCategories and
                               self.db.consumablesChecker.collapsedCategories[categoryKey]

            local categoryFrame = AcquireHeaderFrame(parent, yOffset)
            categoryFrame.categoryKey = categoryKey

            local accentGold = RC:GetColor("ui", "accentGold")

            -- Drop target wash while dragging a row over the header.
            local dropCol = RC:GetColor("ui", "insertionLine")
            categoryFrame.dropHighlight:SetVertexColor(dropCol.r, dropCol.g, dropCol.b, 0.25)

            DressCategoryHeader(categoryFrame, category.name, #enabledItems, isCollapsed)

            categoryFrame.isCollapsed = isCollapsed

            categoryFrame.normalTitleColor = {accentGold.r, accentGold.g, accentGold.b}
            categoryFrame.normalLineColor = {accentGold.r, accentGold.g, accentGold.b, 0.3}

            categoryFrame:SetScript("OnEnter", function(self)
                if RC.consumablesChecker.dragData then
                    -- Drop target: the insertion-line colour, the same one
                    -- the drag indicator paints with.
                    self.dropHighlight:Show()
                    local hov = RC:GetColor("ui", "insertionLine")
                    self.title:SetTextColor(hov.r, hov.g, hov.b, 1)
                    self.headerLine:SetVertexColor(hov.r, hov.g, hov.b, 0.8)
                else
                    local hdrText = RC:GetColor("ui", "headerText")
                    self.title:SetTextColor(hdrText.r, hdrText.g, hdrText.b, 1)
                    self.headerLine:SetVertexColor(hdrText.r, hdrText.g, hdrText.b, 0.6)
                end
            end)

            categoryFrame:SetScript("OnLeave", function(self)
                self.dropHighlight:Hide()
                local accGold = RC:GetColor("ui", "accentGold")
                self.title:SetTextColor(accGold.r, accGold.g, accGold.b, 1)
                self.headerLine:SetVertexColor(accGold.r, accGold.g, accGold.b, 0.3)
            end)

            categoryFrame:SetScript("OnClick", function(self)
                local key = self.categoryKey

                if not RC.db.consumablesChecker.collapsedCategories then
                    RC.db.consumablesChecker.collapsedCategories = {}
                end
                RC.db.consumablesChecker.collapsedCategories[key] = not RC.db.consumablesChecker.collapsedCategories[key]
                RC:SaveConsumablesCheckerToProfile()
                RC.consumablesChecker._populated = false
                RC:PopulateConsumablesChecker()
            end)

            yOffset = yOffset - 22

            if not isCollapsed then
                for _, item in ipairs(enabledItems) do
                    item.data.categoryKey = categoryKey
                    local itemFrame = self:CreateItemRow(parent, item.id, item.data, yOffset)
                    itemFrame.categoryKey = categoryKey
                    table.insert(categoryFrame.items, itemFrame)
                    yOffset = yOffset - 28
                end
            end

            self.consumablesChecker.categoryFrames[categoryKey] = categoryFrame
            yOffset = yOffset - 6
        end

        if not self.consumablesChecker.disabledItemsList then
            self.consumablesChecker.disabledItemsList = {}
        end

        for _, item in ipairs(disabledItems) do
            table.insert(self.consumablesChecker.disabledItemsList, {
                categoryKey = categoryKey,
                categoryName = category.name,
                id = item.id,
                data = item.data
            })
        end

        return yOffset
    end

    function RC:CreateCustomItemsSection(parent, yOffset)
        local missingItems, lowItems, mediumItems, goodItems, disabledItems = {}, {}, {}, {}, {}
        local builtInCategories = {flasks=true, elixirs=true, food=true, drinks=true, potions=true,
                                   protectionPotions=true, buffs=true, utilities=true, chronoboon=true, special=true}

        local function AddItemToList(itemId, itemData)
            if self.db.consumablesChecker.disabledItems and self.db.consumablesChecker.disabledItems[itemId] then
                table.insert(disabledItems, {id = itemId, data = itemData})
            else
                local count = GetItemCount(itemData.baseItemId or itemId, false, false)
                -- a merged row (every poison rank, every dummy) counts all
                -- of its items, as the row itself shows
                if itemData.aggregateItemIds then
                    count = 0
                    for _, aid in ipairs(itemData.aggregateItemIds) do
                        count = count + (GetItemCount(aid, false, false) or 0)
                    end
                end
                local recommended = self:GetRecommendedCount(itemId, itemData)
                local lowThreshold = math.max(1, math.floor(recommended * 0.5))

                if count == 0 then
                    table.insert(missingItems, {id = itemId, data = itemData, count = count})
                elseif recommended > 0 and count < lowThreshold then
                    table.insert(lowItems, {id = itemId, data = itemData, count = count})
                elseif recommended > 0 and count < recommended then
                    table.insert(mediumItems, {id = itemId, data = itemData, count = count})
                else
                    table.insert(goodItems, {id = itemId, data = itemData, count = count})
                end
            end
        end

        local customItems = self.GetCustomConsumableItems and self:GetCustomConsumableItems("checker") or nil
        if customItems then
            for itemId, customData in pairs(customItems) do
                local effectiveCategory = self:GetItemEffectiveCategory(itemId, customData.category or "custom")
                if effectiveCategory == "CUSTOM_ITEMS" or effectiveCategory == "custom" or not builtInCategories[effectiveCategory] then
                    local itemData = {
                        name = customData.name or ("Item " .. itemId),
                        icon = customData.icon,
                        baseItemId = itemId,
                        recommended = 0,
                        isCustomItem = true
                    }
                    AddItemToList(itemId, itemData)
                end
            end
        end

        if self.GetOverriddenItemsForCategory then
            local movedItems = self:GetOverriddenItemsForCategory("CUSTOM_ITEMS")
            for itemId, info in pairs(movedItems) do
                local itemData = info.data
                itemData.movedFrom = info.originalCategory
                AddItemToList(itemId, itemData)
            end
        end

        table.sort(missingItems, function(a, b) return a.data.name < b.data.name end)
        table.sort(lowItems, function(a, b) return a.data.name < b.data.name end)
        table.sort(mediumItems, function(a, b) return a.data.name < b.data.name end)
        table.sort(goodItems, function(a, b) return a.data.name < b.data.name end)
        table.sort(disabledItems, function(a, b) return a.data.name < b.data.name end)

        local enabledItems = {}
        for _, item in ipairs(missingItems) do table.insert(enabledItems, item) end
        for _, item in ipairs(lowItems) do table.insert(enabledItems, item) end
        for _, item in ipairs(mediumItems) do table.insert(enabledItems, item) end
        for _, item in ipairs(goodItems) do table.insert(enabledItems, item) end

        if #enabledItems == 0 and #disabledItems == 0 then
            return yOffset
        end

        local categoryKey = "CUSTOM_ITEMS"

        if self.GetSortedCheckerItems then
            enabledItems = self:GetSortedCheckerItems(categoryKey, enabledItems)
        end

        local isCollapsed = self.db.consumablesChecker.collapsedCategories and
                           self.db.consumablesChecker.collapsedCategories[categoryKey]

        local categoryFrame = AcquireHeaderFrame(parent, yOffset)
        categoryFrame.categoryKey = categoryKey

        -- Custom section reads in text.blue so it stands apart from the
        -- gold built-in categories; hover brightens to white.
        local customCol = RC:GetColor("text", "blue")
        local dropCol = RC:GetColor("ui", "insertionLine")
        categoryFrame.dropHighlight:SetVertexColor(dropCol.r, dropCol.g, dropCol.b, 0.25)

        local collapseIndicator = isCollapsed and "[+] " or "[-] "
        local itemCount = #enabledItems > 0 and (" (" .. #enabledItems .. ")") or ""
        categoryFrame.title:SetText(collapseIndicator .. string.upper(RCL["Custom Items"]) .. itemCount)
        categoryFrame.title:SetTextColor(customCol.r, customCol.g, customCol.b, 1)

        categoryFrame.headerLine:SetVertexColor(customCol.r, customCol.g, customCol.b, 0.3)

        categoryFrame.isCollapsed = isCollapsed

        categoryFrame:SetScript("OnEnter", function(self)
            if RC.consumablesChecker.dragData then
                self.dropHighlight:Show()
                local hov = RC:GetColor("ui", "insertionLine")
                self.title:SetTextColor(hov.r, hov.g, hov.b, 1)
                self.headerLine:SetVertexColor(hov.r, hov.g, hov.b, 0.8)
            else
                local w = RC:GetColor("text", "white")
                self.title:SetTextColor(w.r, w.g, w.b, 1)
                self.headerLine:SetVertexColor(w.r, w.g, w.b, 0.6)
            end
        end)

        categoryFrame:SetScript("OnLeave", function(self)
            self.dropHighlight:Hide()
            local c = RC:GetColor("text", "blue")
            self.title:SetTextColor(c.r, c.g, c.b, 1)
            self.headerLine:SetVertexColor(c.r, c.g, c.b, 0.3)
        end)

        categoryFrame:SetScript("OnClick", function(self)
            local key = self.categoryKey
            if not RC.db.consumablesChecker.collapsedCategories then
                RC.db.consumablesChecker.collapsedCategories = {}
            end
            RC.db.consumablesChecker.collapsedCategories[key] = not RC.db.consumablesChecker.collapsedCategories[key]
            RC:SaveConsumablesCheckerToProfile()
            RC.consumablesChecker._populated = false
            RC:PopulateConsumablesChecker()
        end)

        yOffset = yOffset - 22

        if not isCollapsed then
            for _, item in ipairs(enabledItems) do
                item.data.categoryKey = categoryKey
                local itemFrame = self:CreateItemRow(parent, item.id, item.data, yOffset)
                itemFrame.categoryKey = categoryKey
                table.insert(categoryFrame.items, itemFrame)
                yOffset = yOffset - 28
            end
        end

        self.consumablesChecker.categoryFrames[categoryKey] = categoryFrame
        yOffset = yOffset - 6

        if not self.consumablesChecker.disabledItemsList then
            self.consumablesChecker.disabledItemsList = {}
        end

        for _, item in ipairs(disabledItems) do
            table.insert(self.consumablesChecker.disabledItemsList, {
                categoryKey = categoryKey,
                categoryName = "Custom Items",
                id = item.id,
                data = item.data
            })
        end

        return yOffset
    end

    function RC:UpdateConsumablesCheckerDisplay()
        if not self.consumablesChecker.frame or not self.consumablesChecker.frame:IsShown() then
            return
        end

        if RC.Profiler then RC.Profiler:StartTiming("ConsumChecker") end

        local statusColors = {
            bad     = RC:GetColor("consumables", "stockEmpty"),
            warning = RC:GetColor("consumables", "stockMedium"),
            medium  = RC:GetColor("consumables", "stockLow"),
            good    = RC:GetColor("consumables", "stockFull"),
        }
        local dimC = RC:GetColor("text", "gray")

        local bagCounts = ScanBagCounts()

        local showRecommended = self.db.consumablesChecker.showRecommended
        -- consumablesChecker.formats.count (nil = the plain path below)
        local ccFormats = self.db.consumablesChecker.formats
        local countFmt = type(ccFormats) == "table" and ccFormats.count or nil

        for _, categoryFrame in pairs(self.consumablesChecker.categoryFrames) do
            if categoryFrame.items then
                for _, itemFrame in ipairs(categoryFrame.items) do
                    local itemId = itemFrame.itemId
                    local itemData = itemFrame.itemData
                    local countItemId = itemData.baseItemId or itemId

                    local isDisabled = self.db.consumablesChecker.disabledItems and self.db.consumablesChecker.disabledItems[itemId]

                    if not isDisabled then
                        local count
                        if itemData.aggregateItemIds then
                            count = 0
                            for _, aggId in ipairs(itemData.aggregateItemIds) do
                                count = count + (bagCounts[aggId] or 0)
                            end
                        else
                            count = bagCounts[countItemId] or 0
                        end
                        local recommended = self:GetRecommendedCount(itemId, itemData)

                        -- Keep in sync with AddItemToList's lowThreshold above.
                        local lowThreshold = math.max(1, math.floor(recommended * 0.5))

                        local colorKey
                        if count == 0 then
                            colorKey = "bad"
                        elseif recommended > 0 and count < lowThreshold then
                            colorKey = "warning"
                        elseif recommended > 0 and count < recommended then
                            colorKey = "medium"
                        else
                            colorKey = "good"
                        end

                        if itemFrame.count then
                            local newText
                            if countFmt then
                                newText = self:CheckerCountText(count, recommended, showRecommended, countFmt)
                            elseif showRecommended and recommended > 0 then
                                newText = count .. "/" .. recommended
                            else
                                newText = tostring(count)
                            end
                            if itemFrame.count._cachedText ~= newText then
                                itemFrame.count:SetText(newText)
                                itemFrame.count._cachedText = newText
                            end
                        end

                        if itemFrame._cachedColorKey ~= colorKey then
                            itemFrame._cachedColorKey = colorKey
                            local c = statusColors[colorKey] or statusColors.good
                            itemFrame.name:SetTextColor(c.r, c.g, c.b, 1)
                            if itemFrame.count then
                                itemFrame.count:SetTextColor(c.r, c.g, c.b, 1)
                            end
                            local barAlpha = (colorKey == "bad" or colorKey == "warning") and 1 or 0.8
                            itemFrame.statusBar:SetColorTexture(c.r, c.g, c.b, barAlpha)
                        end
                    else
                        if itemFrame._cachedColorKey ~= "disabled" then
                            itemFrame._cachedColorKey = "disabled"
                            if itemFrame.count then
                                itemFrame.count:SetText("-")
                                itemFrame.count._cachedText = "-"
                                itemFrame.count:SetTextColor(dimC.r, dimC.g, dimC.b, 1)
                            end
                            itemFrame.name:SetTextColor(dimC.r, dimC.g, dimC.b, 1)
                            itemFrame.statusBar:SetColorTexture(0, 0, 0, 0)
                        end
                    end
                end
            end
        end

        if self.consumablesChecker.disabledItemsFrames then
            for _, itemFrame in ipairs(self.consumablesChecker.disabledItemsFrames) do
                if itemFrame.count and itemFrame.count._cachedText ~= "-" then
                    itemFrame.count:SetText("-")
                    itemFrame.count._cachedText = "-"
                    itemFrame.count:SetTextColor(dimC.r, dimC.g, dimC.b, 1)
                end
            end
        end

        if RC.Profiler then RC.Profiler:StopTiming("ConsumChecker") end
    end

    RC.consumablesChecker._populated = false
    function RC:PopulateConsumablesChecker()
        if not self.consumablesChecker.frame then
            self:CreateConsumablesCheckerFrame()
        end

        local scrollChild = self.consumablesChecker.frame.scrollChild

        -- All scrollChild children come from the two pools; reset them
        -- instead of detaching and recreating every frame (item rows are
        -- pooled in Checker_Popup.lua, headers above).
        ResetHeaderPool()
        if _cck.ResetCheckerRowPool then
            _cck.ResetCheckerRowPool()
        end

        self.consumablesChecker.categoryFrames = {}
        self.consumablesChecker.disabledItemsList = {}
        self.consumablesChecker.disabledItemsFrames = {}

        local yOffset = -4
        local categoryOrder = {"flasks", "elixirs", "food", "drinks", "potions", "protectionPotions", "buffs", "utilities", "classItems", "reagents", "chronoboon", "special"}

        for _, categoryKey in ipairs(categoryOrder) do
            yOffset = self:CreateCategorySection(scrollChild, categoryKey, yOffset)
        end

        yOffset = self:CreateCustomItemsSection(scrollChild, yOffset)

        if #self.consumablesChecker.disabledItemsList > 0 then
            yOffset = yOffset - 10

            local hiddenKey = "HIDDEN"
            local isHiddenCollapsed = self.db.consumablesChecker.collapsedCategories and
                                      self.db.consumablesChecker.collapsedCategories[hiddenKey]

            local disabledHeader = AcquireHeaderFrame(scrollChild, yOffset)
            disabledHeader.categoryKey = hiddenKey

            -- Hidden (untracked) section: dimmed, brightens a step on hover.
            local hidCol = RC:GetColor("text", "disabled")
            local collapseIndicator = isHiddenCollapsed and "[+] " or "[-] "
            disabledHeader.title:SetText(collapseIndicator .. string.upper(RCL["Hidden"]))
            disabledHeader.title:SetTextColor(hidCol.r, hidCol.g, hidCol.b, 1)

            disabledHeader.headerLine:SetVertexColor(hidCol.r, hidCol.g, hidCol.b, 0.3)

            disabledHeader:SetScript("OnEnter", function(self)
                local c = RC:GetColor("text", "gray")
                self.title:SetTextColor(c.r, c.g, c.b, 1)
                self.headerLine:SetVertexColor(c.r, c.g, c.b, 0.5)
            end)

            disabledHeader:SetScript("OnLeave", function(self)
                local c = RC:GetColor("text", "disabled")
                self.title:SetTextColor(c.r, c.g, c.b, 1)
                self.headerLine:SetVertexColor(c.r, c.g, c.b, 0.3)
            end)

            disabledHeader:SetScript("OnClick", function(self)
                local key = self.categoryKey
                if not RC.db.consumablesChecker.collapsedCategories then
                    RC.db.consumablesChecker.collapsedCategories = {}
                end
                RC.db.consumablesChecker.collapsedCategories[key] = not RC.db.consumablesChecker.collapsedCategories[key]
                RC:SaveConsumablesCheckerToProfile()
                RC.consumablesChecker._populated = false
                RC:PopulateConsumablesChecker()
            end)

            yOffset = yOffset - 22

            if not isHiddenCollapsed then
                for _, item in ipairs(self.consumablesChecker.disabledItemsList) do
                    local itemFrame = self:CreateItemRow(scrollChild, item.id, item.data, yOffset)
                    table.insert(self.consumablesChecker.disabledItemsFrames, itemFrame)
                    yOffset = yOffset - 28
                end
            end

            self.consumablesChecker.categoryFrames[hiddenKey] = disabledHeader

            yOffset = yOffset - 6
        end

        local totalHeight = math.abs(yOffset) + 16
        scrollChild:SetHeight(totalHeight)

        local sf = self.consumablesChecker.frame.scrollFrame
        local viewHeight = sf:GetHeight()
        if sf.scrollBar and sf.scrollBar.SyncRange then
            sf.scrollBar:SyncRange(totalHeight, viewHeight)
        else
            local scrollRange = math.max(0, totalHeight - viewHeight)
            sf.scrollBar:SetMinMaxValues(0, scrollRange)
            if scrollRange > 0 then sf.scrollBar:Show() else sf.scrollBar:Hide() end
        end

        self.consumablesChecker._populated = true
        self:InvalidateCheckerColorCache()
        self:UpdateConsumablesCheckerDisplay()
    end

    function RC:InvalidateCheckerColorCache()
        for _, categoryFrame in pairs(self.consumablesChecker.categoryFrames or {}) do
            if categoryFrame.items then
                for _, itemFrame in ipairs(categoryFrame.items) do
                    itemFrame._cachedColorKey = nil
                    if itemFrame.count then itemFrame.count._cachedText = nil end
                end
            end
        end
        if self.consumablesChecker.disabledItemsFrames then
            for _, itemFrame in ipairs(self.consumablesChecker.disabledItemsFrames) do
                if itemFrame.count then itemFrame.count._cachedText = nil end
            end
        end
    end

    local REPORT_CATEGORIES = {
        { key = "flasks",             label = RCL["Flasks"]            },
        { key = "elixirs",            label = RCL["Elixirs"]           },
        { key = "food",               label = RCL["Food"]              },
        { key = "drinks",             label = RCL["Drinks"]            },
        { key = "potions",            label = RCL["Potions"]           },
        { key = "protectionPotions",  label = RCL["Prot Potions"]      },
        { key = "buffs",              label = RCL["Jujus & Buffs"]     },
        { key = "utilities",          label = RCL["Utilities"]         },
        { key = "classItems",         label = RCL["Class Consumables"] },
        { key = "reagents",           label = RCL["Class Reagents"]    },
    }

    function RC:PrintConsumablesReport()
        if not self.raidConsumables then return end

        local bagCounts = ScanBagCounts()

        local disabledItems = (self.db.consumablesChecker and self.db.consumablesChecker.disabledItems) or {}
        local isWarrior = RC.isWarrior

        local GOLD   = "|cFFFFD700"
        local RED    = "|cFFFF4444"
        local ORANGE = "|cFFFF8800"
        local YELLOW = "|cFFFFFF00"
        local GREEN  = "|cFF44FF44"
        local GRAY   = "|cFF888888"
        local WHITE  = "|cFFFFFFFF"
        local RESET  = "|r"

        local ICON_LOW  = YELLOW .. "!" .. RESET
        local ICON_NONE = RED    .. "x" .. RESET

        DEFAULT_CHAT_FRAME:AddMessage(GOLD .. "=== Consumables Report ===" .. RESET)

        local anyPrinted = false

        for _, catDef in ipairs(REPORT_CATEGORIES) do
            local category = self.raidConsumables[catDef.key]
            if category and category.items then
                local missing, low = {}, {}

                for itemId, itemData in pairs(category.items) do
                    local skip = disabledItems[itemId] or (isWarrior and itemData.nonWarrior)
                    if not skip then
                        local countItemId = itemData.baseItemId or itemId
                        local count
                        if itemData.aggregateItemIds then
                            count = 0
                            for _, aggId in ipairs(itemData.aggregateItemIds) do
                                count = count + (bagCounts[aggId] or 0)
                            end
                        else
                            count = bagCounts[countItemId] or 0
                        end
                        local recommended = self:GetRecommendedCount(itemId, itemData)
                        local name        = itemData.name or (GetItemInfo(itemId)) or ("Item " .. itemId)
                        local icon        = GetItemIcon(countItemId)
                        local iconStr     = icon and ("|T" .. icon .. ":14:14:0:0|t") or ""

                        if count == 0 then
                            table.insert(missing, { name=name, count=count, recommended=recommended, icon=iconStr })
                        elseif recommended > 0 and count < math.max(1, math.floor(recommended * 0.5)) then
                            table.insert(low, { name=name, count=count, recommended=recommended, icon=iconStr })
                        end
                    end
                end

                if #missing > 0 or #low > 0 then
                    anyPrinted = true
                    local catStatus = #missing > 0 and (RED .. "x" .. RESET) or (YELLOW .. "!" .. RESET)
                    DEFAULT_CHAT_FRAME:AddMessage(GOLD .. catDef.label .. RESET .. "  " .. catStatus)

                    for _, item in ipairs(missing) do
                        local recStr = item.recommended > 0 and (GRAY .. "/" .. item.recommended .. RESET) or ""
                        DEFAULT_CHAT_FRAME:AddMessage(
                            "  " .. ICON_NONE .. " " .. item.icon .. " " ..
                            WHITE .. item.name .. RESET ..
                            "  " .. RED .. "0" .. RESET .. recStr
                        )
                    end

                    for _, item in ipairs(low) do
                        local recStr = item.recommended > 0 and (GRAY .. "/" .. item.recommended .. RESET) or ""
                        DEFAULT_CHAT_FRAME:AddMessage(
                            "  " .. ICON_LOW .. " " .. item.icon .. " " ..
                            WHITE .. item.name .. RESET ..
                            "  " .. ORANGE .. item.count .. RESET .. recStr
                        )
                    end
                end
            end
        end

        if not anyPrinted then
            DEFAULT_CHAT_FRAME:AddMessage(GREEN .. "All consumables fully stocked!" .. RESET)
        else
            DEFAULT_CHAT_FRAME:AddMessage(GRAY .. "x = missing   ! = low stock" .. RESET)
        end
    end
end
