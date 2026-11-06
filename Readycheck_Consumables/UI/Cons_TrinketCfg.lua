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
-- Readycheck - Trinket Bar Settings
-- Behavior/Trinkets/Look/Text/Animation/Position tabs edit db.trinketBar
-- (the last four and the preview: Cons_BarStyle.lua). One
-- exception: "Pin equipped trinkets to front" writes
-- db.consumablesHelper.trinketBarEquippedFirst (see below).
-- preserveScroll captures/restores contentFrame vertical scroll across a
-- rebuild; pass true from dropdown/toggle handlers, omit from tab clicks.
------------------------------------------------------------------------
    function RC:ShowSidebarTrinketBarConfig(frame, preserveScroll)
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local CBS = _sbc.BarPages
        -- the bar itself, drawn by its own button code (Cons_BarStyle)
        local P = CBS.DeclarePreview(self, "trinketBar")
        local parent = frame.scrollChild
        local yPos = -20

        local headerFrame, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Trinket Menu"],
            RCL["Grid display for all trinkets with cooldown tracking"], "Interface\\Icons\\inv_trinket_naxxramas03")
        yPos = newY

        if not self.db.trinketBar then
            self.db.trinketBar = {enabled = false, locked = false, buttonSize = 36, buttonsPerRow = 4, maxRows = 5, showBackground = true, iconSpacing = 4, visibilityMode = "always", growDirection = "RIGHT", hiddenTrinkets = {}}
        end

        local db = self.db.trinketBar

        -- old tab keys (search aliases, saved state) land on the tab that has them now
        frame.trinketBarTab = CBS.Tab(frame.trinketBarTab, "behavior")

        local _, newTabY = self.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = {
                { key = "behavior", label = RCL["Behavior"] },
                { key = "trinkets", label = RCL["Trinkets"] },
                { key = "look", label = RCL["Look"] },
                { key = "text", label = RCL["Text"] },
                { key = "animation", label = RCL["Animation"] },
                { key = "position", label = RCL["Position"] },
            },
            selected = frame.trinketBarTab,
            onClick = function(tk)
                frame.trinketBarTab = tk
                RC:ShowSidebarTrinketBarConfig(frame, true)
            end,
            inset = 18,
            fontSize = 10,
            advance = 34,
        })
        yPos = newTabY

        local currentTab = frame.trinketBarTab or "behavior"
        -- the card holding the on switch (Behavior tab): it stays live
        local liveCard

        if currentTab == "behavior" then
            local generalCard = self:CreateSettingsCard(parent, yPos, RCL["General"])
            liveCard = generalCard
            local cardY = -32

            local enableCheck = self.UI:CreateSettingCheckbox(generalCard, cardY, "Enable Trinket Menu", db.enabled, function(cb)
                local newState = cb:GetChecked()
                RC.db.trinketBar.enabled = newState
                RC:ForceCheckboxUpdate(cb, newState)
                if newState then
                    if not RC.trinketBar.frame then
                        RC:CreateTrinketBarFrame()
                    end
                    if RC.trinketBar.frame then
                        RC.trinketBar.stableStateReached = true
                        RC:UpdateTrinketBarButtons()
                    end
                end
                -- Show/hide through the visibility evaluator so the bar's
                -- "show in" mode is honoured instead of forcing it on.
                RC:UpdateTrinketBarVisibility()
                RC:SaveConfigurationToProfile()
                C_Timer.After(0, function() RC:ShowSidebarTrinketBarConfig(frame, true) end)
            end)
            cardY = cardY - 27

            local combatCheck = self.UI:CreateSettingCheckbox(generalCard, cardY, "Hide in combat", db.hideInCombat, function(cb)
                local newState = cb:GetChecked()
                RC.db.trinketBar.hideInCombat = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 35
            cardY = cardY - 4
            generalCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - generalCard:GetHeight() - 15

        end

        if currentTab == "look" then
            local displayCard = self:CreateSettingsCard(parent, yPos, RCL["Display"])
            local cardY = -32

            local sizeLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            sizeLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            sizeLabel:SetText(RCL["Button Size:"])
            sizeLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local sizeSlider = self.UI:CreateSettingSlider(displayCard, 24, 64, db.buttonSize or 36, 2, 120, cardY + 5, (db.buttonSize or 36) .. "px", function(slider, value)
                value = math.floor(value / 2) * 2
                RC.db.trinketBar.buttonSize = value
                slider.Text:SetText(value .. RCL["px"])
                RC:UpdateTrinketBarButtons()
            end)
            sizeSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            local perRowLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            perRowLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            perRowLabel:SetText(RCL["Columns:"])
            perRowLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local perRowSlider = self.UI:CreateSettingSlider(displayCard, 1, 12, db.buttonsPerRow or 4, 1, 120, cardY + 5, db.buttonsPerRow or 4, function(slider, value)
                value = math.floor(value)
                RC.db.trinketBar.buttonsPerRow = value
                slider.Text:SetText(value)
                RC:UpdateTrinketBarButtons()
            end)
            perRowSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            local maxRowsLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            maxRowsLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            maxRowsLabel:SetText(RCL["Max Rows:"])
            maxRowsLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local maxRowsSlider = self.UI:CreateSettingSlider(displayCard, 1, 10, db.maxRows or 5, 1, 120, cardY + 5, db.maxRows or 5, function(slider, value)
                value = math.floor(value)
                RC.db.trinketBar.maxRows = value
                slider.Text:SetText(value)
                RC:UpdateTrinketBarButtons()
            end)
            maxRowsSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            local spacingLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            spacingLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            spacingLabel:SetText(RCL["Spacing:"])
            spacingLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local spacingSlider = self.UI:CreateSettingSlider(displayCard, 0, 12, db.iconSpacing or 4, 1, 120, cardY + 5, db.iconSpacing or 4, function(slider, value)
                value = math.floor(value)
                RC.db.trinketBar.iconSpacing = value
                slider.Text:SetText(value)
                RC:UpdateTrinketBarButtons()
            end)
            spacingSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            local textScaleLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            textScaleLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            textScaleLabel:SetText(RCL["Text Scale:"])
            textScaleLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local textScaleSlider = self.UI:CreateSettingSlider(displayCard, 0.3, 1.5, db.cooldownTextScale or 1.0, 0.05, 120, cardY + 5, string.format("%.2f", db.cooldownTextScale or 1.0), function(slider, value)
                value = math.floor(value * 20) / 20
                RC.db.trinketBar.cooldownTextScale = value
                slider.Text:SetText(string.format("%.2f", value))
                if RC.trinketBar and RC.trinketBar.buttons then
                    for _, btn in pairs(RC.trinketBar.buttons) do btn:Hide() end
                    RC.trinketBar.buttons = {}
                end
                RC:UpdateTrinketBarButtons()
            end)
            textScaleSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            self.UI:CreateSegmentedControl(displayCard, {
                x = 14, y = cardY + 5, height = 22, label = RCL["Grow:"],
                items = {
                    { key = "RIGHT", label = RCL["Right"], tooltip = RCL["New rows are added to the right of the anchor."] },
                    { key = "DOWN",  label = RCL["Down"],  tooltip = RCL["New rows are added below the anchor."] },
                },
                selected = db.growDirection or "RIGHT",
                onSelect = function(key)
                    RC.db.trinketBar.growDirection = key
                    RC:UpdateTrinketBarButtons()
                    RC:SaveConfigurationToProfile()
                end,
            })
            cardY = cardY - 40

            local bgCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show background and borders", db.showBackground ~= false, function(cb)
                local newState = cb:GetChecked()
                RC.db.trinketBar.showBackground = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:UpdateTrinketBarBackground()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 27

            local cdTextCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show cooldown text", db.showCooldownText ~= false, function(cb)
                local newState = cb:GetChecked()
                RC.db.trinketBar.showCooldownText = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:UpdateTrinketBarButtons()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 27

            local ttCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show item tooltips on hover", db.showTooltips == true, function(cb)
                local newState = cb:GetChecked()
                RC.db.trinketBar.showTooltips = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 27

            local slotNumCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show slot numbers (1/2 on equipped)", db.showSlotNumbers ~= false, function(cb)
                local newState = cb:GetChecked()
                RC.db.trinketBar.showSlotNumbers = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:UpdateTrinketBarButtons()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 27


            displayCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - displayCard:GetHeight() - 15

            yPos = CBS.BuildLook(self, frame, "trinketBar", parent, yPos)

        end

        if currentTab == "trinkets" then
            -- which trinkets the menu shows (was on the General tab)
            do
                local whichCard = self:CreateSettingsCard(parent, yPos, RCL["Which trinkets"])
                local cardY = -32
                local equippedOnlyCheck = self.UI:CreateSettingCheckbox(whichCard, cardY, "Show equipped trinkets only (hide bag trinkets)", db.showEquippedOnly, function(cb)
                    local newState = cb:GetChecked()
                    RC.db.trinketBar.showEquippedOnly = newState
                    if newState then RC.db.trinketBar.showBagOnly = false end
                    RC:ForceCheckboxUpdate(cb, newState)
                    RC.trinketBar.lastScanTime = 0
                    RC:UpdateTrinketBarButtons()
                    RC:SaveConfigurationToProfile()
                    RC:ShowSidebarTrinketBarConfig(frame, true)
                end)
                cardY = cardY - 28

                local bagOnlyCheck = self.UI:CreateSettingCheckbox(whichCard, cardY, "Show bag trinkets only (hide equipped)", db.showBagOnly, function(cb)
                    local newState = cb:GetChecked()
                    RC.db.trinketBar.showBagOnly = newState
                    if newState then RC.db.trinketBar.showEquippedOnly = false end
                    RC:ForceCheckboxUpdate(cb, newState)
                    RC.trinketBar.lastScanTime = 0
                    RC:UpdateTrinketBarButtons()
                    RC:SaveConfigurationToProfile()
                    RC:ShowSidebarTrinketBarConfig(frame, true)
                end)
                cardY = cardY - 28
                -- Writes to consumablesHelper, not trinketBar: this flag is shared
                -- with the consumables bar's trinket handling.
                local eqFirstCheck = self.UI:CreateSettingCheckbox(whichCard, cardY,
                    "Pin equipped trinkets to the front (bar reshuffles on equip)",
                    RC.db.consumablesHelper.trinketBarEquippedFirst == true, function(cb)
                    RC.db.consumablesHelper.trinketBarEquippedFirst = cb:GetChecked() and true or false
                    RC:SaveConfigurationToProfile()
                    if RC.consumablesHelper and RC.consumablesHelper.UpdateTrinketBar then
                        RC.consumablesHelper:UpdateTrinketBar()
                    end
                end)

                cardY = cardY - 40
                whichCard:SetContentHeight(math.abs(cardY))
                yPos = yPos - whichCard:GetHeight() - 15
            end

            local trinketsCard = self:CreateSettingsCard(parent, yPos, RCL["Manage trinkets"])
            local cardY = -32

            local infoText = self:CreateFontString(trinketsCard, "OVERLAY", nil, 10)
            infoText:SetPoint("TOPLEFT", trinketsCard, "TOPLEFT", 14, cardY)
            infoText:SetWidth(trinketsCard:GetWidth() - 30)
            infoText:SetText(RCL["Check to show. Drag the grip to reorder."])
            infoText:SetJustifyH("LEFT")
            infoText:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 25

            local hiddenTrinkets = db.hiddenTrinkets or {}
            local trinketOrder   = db.trinketOrder  or {}

            local allTrinkets = {}
            local seenItems = {}

            for slotIndex = 13, 14 do
                local itemId = GetInventoryItemID("player", slotIndex)
                if itemId and not seenItems[itemId] then
                    local name, _, rarity, _, _, _, _, _, _, icon = GetItemInfo(itemId)
                    if name then
                        seenItems[itemId] = true
                        table.insert(allTrinkets, {itemId=itemId, name=name, icon=icon, rarity=rarity or 1, equipped=true, slotIndex=slotIndex})
                    end
                end
            end
            for bag = 0, 4 do
                local numSlots = C_Container.GetContainerNumSlots(bag)
                for slot = 1, numSlots do
                    local itemInfo = C_Container.GetContainerItemInfo(bag, slot)
                    if itemInfo and itemInfo.itemID and not seenItems[itemInfo.itemID] then
                        local _, _, _, itemEquipLoc = GetItemInfoInstant(itemInfo.itemID)
                        if itemEquipLoc == "INVTYPE_TRINKET" then
                            local name, _, rarity, _, _, _, _, _, _, icon = GetItemInfo(itemInfo.itemID)
                            if name then
                                seenItems[itemInfo.itemID] = true
                                table.insert(allTrinkets, {itemId=itemInfo.itemID, name=name, icon=icon, rarity=rarity or 1, equipped=false})
                            end
                        end
                    end
                end
            end

            local orderPos = {}
            for i, id in ipairs(trinketOrder) do orderPos[id] = i end
            table.sort(allTrinkets, function(a, b)
                local pa = orderPos[a.itemId] or 9999
                local pb = orderPos[b.itemId] or 9999
                if pa ~= pb then return pa < pb end
                if a.rarity ~= b.rarity then return a.rarity > b.rarity end
                return a.name < b.name
            end)

            local dragState = { active = false, sourceIdx = nil, insertIdx = nil }

            local dragOverlay = CreateFrame("Frame", nil, UIParent)
            dragOverlay:SetSize(180, 24)
            dragOverlay:SetFrameStrata("TOOLTIP")
            dragOverlay:Hide()
            local dragOverlayBg = dragOverlay:CreateTexture(nil, "BACKGROUND")
            dragOverlayBg:SetAllPoints()
            do local _cb=RC:GetColor("ui","cardBackground"); dragOverlayBg:SetColorTexture(_cb.r,_cb.g,_cb.b,0.85) end
            local dragOverlayIcon = dragOverlay:CreateTexture(nil, "ARTWORK")
            dragOverlayIcon:SetSize(18, 18)
            dragOverlayIcon:SetPoint("LEFT", 4, 0)
            dragOverlayIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            local dragOverlayText = self:CreateFontString(dragOverlay, "OVERLAY", nil, 10)
            dragOverlayText:SetPoint("LEFT", dragOverlayIcon, "RIGHT", 4, 0)
            dragOverlayText:SetPoint("RIGHT", dragOverlay, "RIGHT", -4, 0)
            dragOverlayText:SetJustifyH("LEFT")
            do local _wc = RC:GetColor("text", "white"); dragOverlayText:SetTextColor(_wc.r, _wc.g, _wc.b, 1) end

            local insertLine = CreateFrame("Frame", nil, UIParent)
            insertLine:SetHeight(2)
            insertLine:SetFrameStrata("TOOLTIP")
            insertLine:Hide()
            local insertLineTex = insertLine:CreateTexture(nil, "ARTWORK")
            insertLineTex:SetAllPoints()
            local accentCol = RC:GetColor("ui", "accentGold")
            insertLineTex:SetColorTexture(accentCol.r, accentCol.g, accentCol.b, 1)

            local rowFrames = {}

            local function CommitOrder(insertIdx)
                local src = dragState.sourceIdx
                if not src or not insertIdx or src == insertIdx then return end
                local item = table.remove(allTrinkets, src)
                local dest = insertIdx
                -- removing src shifted every later index down by one
                if src < dest then dest = dest - 1 end
                table.insert(allTrinkets, dest, item)
                local newOrder = {}
                for _, t in ipairs(allTrinkets) do table.insert(newOrder, t.itemId) end
                RC.db.trinketBar.trinketOrder = newOrder
                RC:SaveConfigurationToProfile()
                RC.trinketBar.lastScanTime = 0
                RC:UpdateTrinketBarButtons()
                RC:ShowSidebarTrinketBarConfig(frame, true)
            end

            if #allTrinkets == 0 then
                local noTrinketsText = self:CreateFontString(trinketsCard, "OVERLAY", nil, 10)
                noTrinketsText:SetPoint("TOPLEFT", trinketsCard, "TOPLEFT", 14, cardY)
                noTrinketsText:SetText(RCL["No trinkets found in inventory."])
                noTrinketsText:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
                cardY = cardY - 25
            else
                for idx, trinket in ipairs(allTrinkets) do
                    local isHidden = hiddenTrinkets[trinket.itemId] == true
                    local rowY = cardY
                    local itemIdCapture = trinket.itemId
                    local idxCapture = idx

                    local rowFrame = CreateFrame("Frame", nil, trinketsCard)
                    rowFrame:SetPoint("TOPLEFT", trinketsCard, "TOPLEFT", 14, rowY)
                    rowFrame:SetPoint("TOPRIGHT", trinketsCard, "TOPRIGHT", -14, rowY)
                    rowFrame:SetHeight(24)
                    rowFrame.rowIdx = idx
                    table.insert(rowFrames, rowFrame)

                    local dragHandle = CreateFrame("Frame", nil, trinketsCard)
                    dragHandle:SetSize(12, 20)
                    dragHandle:SetPoint("TOPLEFT", trinketsCard, "TOPLEFT", 4, rowY)
                    dragHandle:EnableMouse(true)
                    local handleBg = dragHandle:CreateTexture(nil, "BACKGROUND")
                    handleBg:SetAllPoints()
                    local eb = RC:GetColor("ui", "elementBackground")
                    handleBg:SetColorTexture(eb.r, eb.g, eb.b, 0.6)
                    for i = 0, 2 do
                        local line = dragHandle:CreateTexture(nil, "ARTWORK")
                        line:SetSize(8, 2)
                        line:SetPoint("CENTER", 0, (i-1)*5)
                        local gtd = RC:GetColor("text", "disabled")
                        line:SetColorTexture(gtd.r, gtd.g, gtd.b, 0.9)
                    end
                    dragHandle:SetScript("OnEnter", function(self)
                        local ag = RC:GetColor("ui", "accentGold")
                        handleBg:SetColorTexture(ag.r, ag.g, ag.b, 0.35)
                        GameTooltip:SetOwner(self, "ANCHOR_TOP")
                        local _tw = RC:GetColor("text", "white")
                        GameTooltip:SetText(RCL["Drag to reorder"], _tw.r, _tw.g, _tw.b)
                        GameTooltip:Show()
                    end)
                    dragHandle:SetScript("OnLeave", function(self)
                        local eb = RC:GetColor("ui", "elementBackground")
                        handleBg:SetColorTexture(eb.r, eb.g, eb.b, 0.6)
                        GameTooltip:Hide()
                    end)
                    dragHandle:SetScript("OnMouseDown", function(self, btn)
                        if btn ~= "LeftButton" then return end
                        dragState.active = true
                        dragState.sourceIdx = idxCapture
                        dragOverlayIcon:SetTexture(trinket.icon)
                        dragOverlayText:SetText(trinket.name)
                        dragOverlay:Show()
                        dragOverlay:SetScript("OnUpdate", function(ov)
                            local cx, cy = GetCursorPosition()
                            local scale = UIParent:GetEffectiveScale()
                            cx, cy = cx/scale, cy/scale
                            ov:ClearAllPoints()
                            ov:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)
                            local found = false
                            for i, rf in ipairs(rowFrames) do
                                if rf:IsShown() then
                                    local top, bot = rf:GetTop(), rf:GetBottom()
                                    local lft, rgt = rf:GetLeft(), rf:GetRight()
                                    if top and bot and lft and rgt and cx >= lft-20 and cx <= rgt+20 and cy >= bot-8 and cy <= top+8 then
                                        local midY = (top+bot)/2
                                        if cy >= midY then
                                            insertLine:ClearAllPoints()
                                            insertLine:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", lft, top+1)
                                            insertLine:SetWidth(rgt-lft)
                                            insertLine:Show()
                                            dragState.insertIdx = i
                                        else
                                            insertLine:ClearAllPoints()
                                            insertLine:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", lft, bot-1)
                                            insertLine:SetWidth(rgt-lft)
                                            insertLine:Show()
                                            dragState.insertIdx = i + 1
                                        end
                                        found = true
                                        break
                                    end
                                end
                            end
                            if not found then insertLine:Hide(); dragState.insertIdx = nil end
                        end)
                    end)
                    dragHandle:SetScript("OnMouseUp", function(self, btn)
                        if btn ~= "LeftButton" or not dragState.active then return end
                        dragOverlay:Hide()
                        dragOverlay:SetScript("OnUpdate", nil)
                        insertLine:Hide()
                        if dragState.insertIdx then
                            CommitOrder(dragState.insertIdx)
                        end
                        dragState.active = false
                        dragState.sourceIdx = nil
                        dragState.insertIdx = nil
                    end)

                    local checkbox = self.UI:CreateCheckbox(trinketsCard, "", not isHidden)
                    checkbox.parentFrame:SetPoint("TOPLEFT", trinketsCard, "TOPLEFT", 18, rowY)
                    checkbox.parentFrame:SetSize(20, 20)
                    checkbox:SetScript("OnClick", function(cb)
                        local nowHidden = not cb:GetChecked()
                        if nowHidden then
                            RC.db.trinketBar.hiddenTrinkets[itemIdCapture] = true
                        else
                            RC.db.trinketBar.hiddenTrinkets[itemIdCapture] = nil
                        end
                        RC:ForceCheckboxUpdate(cb, not nowHidden)
                        RC:SaveConfigurationToProfile()
                        RC.trinketBar.lastScanTime = 0
                        RC:UpdateTrinketBarButtons()
                    end)

                    if trinket.icon then
                        local iconTex = trinketsCard:CreateTexture(nil, "ARTWORK")
                        iconTex:SetSize(18, 18)
                        iconTex:SetPoint("TOPLEFT", trinketsCard, "TOPLEFT", 40, rowY + 1)
                        iconTex:SetTexture(trinket.icon)
                        iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    end

                    local nameText = self:CreateFontString(trinketsCard, "OVERLAY", nil, 10)
                    nameText:SetPoint("TOPLEFT", trinketsCard, "TOPLEFT", 62, rowY - 3)
                    nameText:SetWidth(trinketsCard:GetWidth() - 115)
                    nameText:SetJustifyH("LEFT")
                    local qc = ITEM_QUALITY_COLORS[trinket.rarity or 1]
                    local r, g, b = (qc and qc.r) or 1, (qc and qc.g) or 1, (qc and qc.b) or 1
                    nameText:SetText(trinket.name)
                    nameText:SetTextColor(r, g, b)

                    if trinket.equipped then
                        local equippedText = self:CreateFontString(trinketsCard, "OVERLAY", nil, 10)
                        equippedText:SetPoint("TOPRIGHT", trinketsCard, "TOPRIGHT", -10, rowY - 3)
                        equippedText:SetText(RCL["Slot "] .. (trinket.slotIndex == 13 and "1" or "2"))
                        local ag = RC:GetColor("ui", "accentGold")
                        equippedText:SetTextColor(ag.r, ag.g, ag.b)
                    end

                    cardY = cardY - 26
                end

                cardY = cardY - 10

                local showAllBtn = self.UI:CreateStyledButton(trinketsCard, RCL["Show All"], 110, 22)
                showAllBtn:SetPoint("TOPLEFT", trinketsCard, "TOPLEFT", 14, cardY)
                showAllBtn:SetScript("OnClick", function()
                    RC.db.trinketBar.hiddenTrinkets = {}
                    RC:SaveConfigurationToProfile()
                    RC.trinketBar.lastScanTime = 0
                    RC:UpdateTrinketBarButtons()
                    RC:ShowSidebarTrinketBarConfig(frame, true)
                end)

                local hideAllBtn = self.UI:CreateStyledButton(trinketsCard, RCL["Hide All"], 110, 22)
                hideAllBtn:SetPoint("LEFT", showAllBtn, "RIGHT", 10, 0)
                hideAllBtn:SetScript("OnClick", function()
                    for _, trinket in ipairs(allTrinkets) do
                        RC.db.trinketBar.hiddenTrinkets[trinket.itemId] = true
                    end
                    RC:SaveConfigurationToProfile()
                    RC.trinketBar.lastScanTime = 0
                    RC:UpdateTrinketBarButtons()
                    RC:ShowSidebarTrinketBarConfig(frame, true)
                end)

                cardY = cardY - 35
            end

            cardY = cardY - 10
            trinketsCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - trinketsCard:GetHeight() - 15

        end

        if currentTab == "behavior" then
            local visCard = self:CreateSettingsCard(parent, yPos, RCL["Visibility"])
            local cardY = -32

            local visLabel = self:CreateFontString(visCard, "OVERLAY", nil, 11)
            visLabel:SetPoint("TOPLEFT", visCard, "TOPLEFT", 14, cardY)
            visLabel:SetText(RCL["Show the trinket menu:"])
            visLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            -- Keys are the saved values; labels/tooltips come from
            -- BuildVisibilityModeGrid ("group" = any party/raid anywhere,
            -- "raids_only" = inside a raid instance, "city" = resting in
            -- an inn or capital). The raid modes get a per-raid filter
            -- block underneath, so onPick re-renders to resize.
            local modes = {
                {key = "always", name = "Always"},
                {key = "group", name = "In a Group"},
                {key = "city", name = "In Cities"},
                {key = "raids_only", name = "In Raids"},
                {key = "raids_and_city", name = "Raids & Cities"}
            }

            cardY = _sbc.BuildVisibilityModeGrid(visCard, cardY, modes, RC.db.trinketBar, function()
                RC.trinketBar.cachedShouldShow = nil
                RC.trinketBar.lastZoneCheck = 0
                RC:UpdateTrinketBarVisibility()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarTrinketBarConfig(frame, true)
            end)

            visCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - visCard:GetHeight() - 15
            -- fade rules on top of "Show in" (the customization standard)
            yPos = self.UI:FrameVisibilityCard(parent, yPos, function() return RC.db.trinketBar end,
                function() RC:RestyleBar("trinketBar") end, { fields = { show = true, alpha = true, combatAlpha = true, fadeIn = true, fadeOut = true },
                note = RCL["On top of 'Show in' and the mouseover fade: a rule that is not met fades the bar out."] })
        end

        if currentTab == "text" then yPos = CBS.BuildText(self, frame, "trinketBar", parent, yPos) end
        if currentTab == "animation" then yPos = CBS.BuildAnimation(self, frame, "trinketBar", parent, yPos, P) end
        if currentTab == "position" then yPos = CBS.BuildPosition(self, frame, "trinketBar", parent, yPos) end

        if not db.enabled then
            self:LockSettingsCards(parent, RCL["The trinket menu is off. Turn it on to change these."], liveCard, 58)
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
        if preserveScroll then
            self:RestoreScrollPosition(self.sidebarConfigFrame)
        end
    end
