------------------------------------------------------------------------
-- Readycheck - Weapons Bar & Potions/Consumables Bar Refresh
-- Owns the weapons bar (unified MH/OH sharpening-stone buttons plus bag
-- weapons) and the shared background/lock/name-label helpers and potions
-- bar refresh used by the other consumables bars.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local WRF = _G.Readycheck
if not WRF then return end
WRF._chInit = WRF._chInit or {}
WRF._chs = WRF._chs or {}
WRF._chInit[#WRF._chInit + 1] = function()
    local RC = _G.Readycheck
    local GetTime = GetTime
    local GetItemCount = GetItemCount or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemCount)
    local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
    local IsInInstance = IsInInstance
    local IsResting = IsResting
    local InCombatLockdown = InCombatLockdown
    local math_floor = math.floor
    local math_ceil = math.ceil
    local math_min = math.min
    local pairs = pairs
    local ipairs = ipairs

    local _chs = WRF._chs
    local C, GetConsBarBg, GetConsBarBorder, GetPotBarBg, GetPotBarBorder, GetWeapBarBg, GetWeapBarBorder, GetWeapBarTitle, SmoothSetSize = _chs.C, _chs.GetConsBarBg, _chs.GetConsBarBorder, _chs.GetPotBarBg, _chs.GetPotBarBorder, _chs.GetWeapBarBg, _chs.GetWeapBarBorder, _chs.GetWeapBarTitle, _chs.SmoothSetSize
    local EvalBarVisibility, BuildButtonGrid, ApplyGridSeamBorders = _chs.EvalBarVisibility, _chs.BuildButtonGrid, _chs.ApplyGridSeamBorders

    -- Same mode mapping as the other three bars (Consumables_Buttons.lua).
    -- The old private mapping here had no "city" branch, so that mode
    -- hid the bar everywhere.
    function RC:ShouldShowWeaponsBar()
        return EvalBarVisibility(self.weaponsBar, self.db and self.db.weaponsBar, _chs.RaidsCityMode)
    end

    function RC:UpdateWeaponsVisibility()
        if not self.weaponsBar.frame then return end

        if not self.db.weaponsBar.enabled then
            if not InCombatLockdown() then
                self:HideBarFrame("weaponsBar")
            end
            return
        end

        self.weaponsBar.cachedShouldShow = nil
        self.weaponsBar.lastZoneCheck = 0

        -- Secure buttons: nothing moves in combat. PLAYER_REGEN_ENABLED
        -- re-runs this, so a decision made mid-fight is not lost.
        if InCombatLockdown() then return end

        if self:ShouldShowWeaponsBar() then
            self:ShowBarFrame("weaponsBar")
            self:UpdateWeaponsButtons()
        else
            self:HideBarFrame("weaponsBar")
        end
    end

    function RC:CreateWeaponsBarFrame()
        if not self.db.weaponsBar then return nil end
        if self.weaponsBar.frame then return self.weaponsBar.frame end

        local db = self.db.weaponsBar

        local frame = CreateFrame("Frame", "ReadycheckWeaponsBar", UIParent)
        frame:SetSize(200, 50)
        RC.Position.Bind(frame, function() return self.db.weaponsBar end, {
            point = "TOPLEFT", pointKey = "anchorPoint",
            default = { point = "TOPLEFT", x = 450, y = -721 },
        })
        RC.Position.ApplyStored(frame) -- real layout restores at true size
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:SetClampedToScreen(true)
        frame:RegisterForDrag("LeftButton")

        frame.bg = frame:CreateTexture(nil, "BACKGROUND")
        frame.bg:SetAllPoints()
        local shouldShowBg = db.showBackground ~= false
        local frameBgCol = GetWeapBarBg()
        if shouldShowBg then
            frame.bg:SetColorTexture(frameBgCol.r, frameBgCol.g, frameBgCol.b, frameBgCol.a or 0.90)
        else
            frame.bg:SetColorTexture(C.transparent[1], C.transparent[2], C.transparent[3], C.transparent[4])
        end

        local borderCol = GetWeapBarBorder()
        self:ApplyBarChrome(frame, borderCol, shouldShowBg)
        local titleCol = GetWeapBarTitle()
        frame.titleText = self:CreateFontString(frame, "OVERLAY", nil, 10)
        frame.titleText:SetPoint("BOTTOM", frame, "TOP", 0, 20)
        frame.titleText:SetText(RCL["Weapons  (drag to move)"])
        frame.titleText:SetTextColor(titleCol.r, titleCol.g, titleCol.b, 1)
        if db.locked then
            frame.titleText:Hide()
        end

        frame.unlockHint = self:CreateFontString(frame, "OVERLAY", nil, 10)
        frame.unlockHint:SetPoint("BOTTOM", frame, "TOP", 0, 8)
        frame.unlockHint:SetText(RCL["Right-click to lock"])
        frame.unlockHint:SetTextColor(C.whiteDim[1], C.whiteDim[2], C.whiteDim[3], C.whiteDim[4])
        frame.unlockHint:Hide()

        frame:SetScript("OnEnter", function()
            local currentDb = self.db.weaponsBar
            if not currentDb.locked then
                frame.unlockHint:SetText(RCL["Right-click to lock"])
            else
                frame.unlockHint:SetText(RCL["Right-click to unlock"])
            end
            frame.unlockHint:Show()
        end)

        frame:SetScript("OnLeave", function()
            frame.unlockHint:Hide()
        end)

        RC.Position.MakeMovable(frame, function() return not self.db.weaponsBar.locked end)

        frame:SetScript("OnMouseUp", function(f, button)
            if button == "RightButton" and not InCombatLockdown() then
                self:ToggleWeaponsBarLock()
            end
        end)

        self:StartBarsMaintTicker()

        -- Shared bar events (Consumables_Events). Combat end re-decides
        -- visibility, which rebuilds the buttons when the bar shows. On a
        -- bag change the consumables bar's handler runs first and usually
        -- rebuilds this bar already (its stone buttons share the stock);
        -- the version check keeps that from happening twice.
        RC:RegisterBarEvents("weaponsBar", {
            visibility = "UpdateWeaponsVisibility",
            settle = true,
            combatEnd = function()
                self:UpdateWeaponsVisibility()
            end,
            bags = function()
                if self.weaponsBar.stableStateReached
                    and self.weaponsBar._bagVersion ~= RC.Bags:Version() then
                    self:UpdateWeaponsButtons()
                end
            end,
        })

        self.weaponsBar.frame = frame

        if RC.AttachContainerMouseoverFade then
            RC:AttachContainerMouseoverFade(frame, function()
                local d = RC.db and RC.db.weaponsBar
                if not d then return nil end
                local fi, fo = RC.BarStyle.FadeTimes("weaponsBar")
                return { enabled = d.mouseoverFade, alpha = d.mouseoverFadeAlpha or 0.15, fadeIn = fi, fadeOut = fo }
            end)
            if RC.UpdateWeaponsBarMouseoverFade then
                RC:UpdateWeaponsBarMouseoverFade()
            end
        end

        if db.enabled then
            self.weaponsBar.stableStateReached = true
            self:UpdateWeaponsVisibility()
        else
            frame:Hide()
        end

        -- the customization standard's layer / fade / shadow (unset = as always)
        if self.ApplyFrameCustom then self:ApplyFrameCustom(frame, function() return RC.db and RC.db.weaponsBar end, { scale = false }) end

        return frame
    end

    function RC:ToggleWeaponsBarLock()
        if not self.db.weaponsBar or not self.weaponsBar.frame then return end

        local db = self.db.weaponsBar
        db.locked = not db.locked

        local frame = self.weaponsBar.frame

        if db.locked then
            frame.titleText:Hide()
            if frame.unlockHint then
                frame.unlockHint:SetText(RCL["Right-click to unlock"])
            end
        else
            frame.titleText:Show()
            if frame.unlockHint then
                frame.unlockHint:SetText(RCL["Right-click to lock"])
            end
        end

        self:UpdateWeaponsBarBackground()
        self:UpdateWeaponsButtons()
        self:SaveConfigurationToProfile()
    end

    function RC:UpdateWeaponsBarBackground()
        if not self.weaponsBar.frame or not self.db.weaponsBar then return end

        local db = self.db.weaponsBar
        local frame = self.weaponsBar.frame
        local shouldShowBg = db.showBackground ~= false
        self:PaintBarChrome(frame, "weaponBar", shouldShowBg, db.locked == false)
    end

    function RC:UpdateWeaponsButtons()
        if not self.db.weaponsBar or not self.db.weaponsBar.enabled then return end
        if not self.weaponsBar.frame or InCombatLockdown() then return end

        if not self:ShouldShowWeaponsBar() then
            self:HideBarFrame("weaponsBar")
            return
        end

        local config = self.db.weaponsBar
        local size = config.buttonSize or 36
        local spacing = config.iconSpacing or 4
        local perRow = config.buttonsPerRow or 4
        local growDir = config.growDirection or "RIGHT"
        local topOffset = -5

        local visibleButtonIds = {}

        local weapons = {}
        local weaponCount = 0

        local itemCountCache = self:RefreshBagItemCountCache()
        self.weaponsBar._bagVersion = RC.Bags:Version()
        local displayStone   = self:GetValidStoneType()
        local stoneCount     = itemCountCache[displayStone] or 0

        local hordeMode = self:IsHordeMode("weaponsBar")
        local mhTexture = GetInventoryItemTexture("player", 16)
        local mhItemId = GetInventoryItemID("player", 16)
        if config.showEquippedWeapons and mhTexture and not hordeMode and not (config.hiddenWeapons and mhItemId and config.hiddenWeapons[mhItemId]) then
            local mhLink = GetInventoryItemLink("player", 16)
            -- itemClassID 2 = Weapon (GetItemInfo numeric class). Subtype
            -- string match, not itemId, so this works for every sword/axe/
            -- mace/dagger/polearm/fist/staff regardless of which one is
            -- equipped; these are exactly the types Sharpening/Weightstone
            -- can be applied to.
            local isMHSharpenable = false
            if mhLink then
                local _, _, _, _, _, _, itemSubType, _, itemEquipLoc, _, _, itemClassID = GetItemInfo(mhLink)
                if itemClassID == 2 then
                    local sub = itemSubType and itemSubType:lower() or ""
                    isMHSharpenable = (sub:find("sword") or sub:find("axe") or
                                       sub:find("mace") or sub:find("dagger") or
                                       sub:find("polearm") or sub:find("fist") or
                                       sub:find("staff"))
                end
            end

            if isMHSharpenable then
                local selectedStone = self:GetValidStoneType("mainhand")
                local hasBuff, timeRemaining = self:HasWeaponEnchant(selectedStone, "mainhand")

                weaponCount = weaponCount + 1
                -- 999901/999902 are virtual itemIds for the unified MH/OH
                -- stone buttons (no real item represents "whatever stone is
                -- on your weapon").
                weapons[weaponCount] = {
                    itemId = 999901,
                    itemData = {
                        name = "Mainhand Stone",
                        slot = "mainhand",
                        baseItemId = selectedStone,
                        isUnifiedWeaponButton = true
                    },
                    count = itemCountCache[selectedStone] or 0,
                    category = "utilities",
                    hasBuff = hasBuff,
                    timeRemaining = timeRemaining
                }
            end
        end

        local ohTexture = GetInventoryItemTexture("player", 17)
        local ohItemId = GetInventoryItemID("player", 17)
        if config.showEquippedWeapons and ohTexture and not (config.hiddenWeapons and ohItemId and config.hiddenWeapons[ohItemId]) then
            local ohLink = GetInventoryItemLink("player", 17)
            -- Offhand list omits polearm/staff (two-handers can't go here);
            -- the INVTYPE_SHIELD check is belt-and-suspenders since shields
            -- are itemClassID 4 (Armor), not 2, so class 2 alone already
            -- excludes them.
            local isOHSharpenable = false
            if ohLink then
                local _, _, _, _, _, _, itemSubType, _, itemEquipLoc, _, _, itemClassID = GetItemInfo(ohLink)
                if itemClassID == 2 and itemEquipLoc ~= "INVTYPE_SHIELD" then
                    local sub = itemSubType and itemSubType:lower() or ""
                    isOHSharpenable = (sub:find("sword") or sub:find("axe") or
                                       sub:find("mace") or sub:find("dagger") or
                                       sub:find("fist"))
                end
            end

            if isOHSharpenable then
                local selectedStone = self:GetValidStoneType("offhand")
                local hasBuff, timeRemaining = self:HasWeaponEnchant(selectedStone, "offhand")

                weaponCount = weaponCount + 1
                weapons[weaponCount] = {
                    itemId = 999902,
                    itemData = {
                        name = "Offhand Stone",
                        slot = "offhand",
                        baseItemId = selectedStone,
                        isUnifiedWeaponButton = true
                    },
                    count = itemCountCache[selectedStone] or 0,
                    category = "utilities",
                    hasBuff = hasBuff,
                    timeRemaining = timeRemaining
                }
            end
        end

        if config.showBagWeapons then
            local bagWeapons = self:ScanBagWeapons()

            if self.debugCategories and self.debugCategories.items and self.debugCategories.items.enabled then
                self:DebugPrint(string.format(RCL["WEAPONS BAR: Scanning %d bag weapons"], #bagWeapons), "items")
            end
            local _dbgItems = self.debugCategories and self.debugCategories.items and self.debugCategories.items.enabled

            for i, weapon in ipairs(bagWeapons) do
                local hasEnchant, enchantTime = self:HasBagWeaponEnchant(weapon.bag, weapon.slot)
                local bagWeaponId = 900000 + (weapon.bag * 100) + weapon.slot

                if _dbgItems then
                    self:DebugPrint(string.format(RCL["  Weapons bar bag weapon: %s (bag %d slot %d) enchant=%s time=%d"],
                        weapon.itemName or RCL["unknown"], weapon.bag, weapon.slot, tostring(hasEnchant), enchantTime or 0), "items")
                end

                if not (config.hiddenWeapons and config.hiddenWeapons[weapon.itemId]) then
                    weaponCount = weaponCount + 1
                    weapons[weaponCount] = {
                        itemId = bagWeaponId,
                        itemData = {
                            name = weapon.itemName,
                            slot = "bag",
                            bagSlot = weapon.bag,
                            bagPosition = weapon.slot,
                            weaponItemId = weapon.itemId,
                            weaponLink = weapon.itemLink,
                            weaponTexture = weapon.texture,
                            baseItemId = displayStone,
                            isBagWeapon = true
                        },
                        count = stoneCount,
                        category = "utilities",
                        hasBuff = hasEnchant,
                        timeRemaining = enchantTime or 0
                    }
                end
            end
        end

        local visibleCount = 0
        for i, data in ipairs(weapons) do
            local itemId = data.itemId
            local button = self.weaponsBar.buttons[itemId]

            if not button then
                button = self:CreateConsumableButton(itemId, data.itemData, i, data.category, false, config, self.weaponsBar.frame)
                self.weaponsBar.buttons[itemId] = button
            else
                local showWeaponIcons = self.db.consumablesHelper.showWeaponIcons
                local displayItemId = data.itemData.baseItemId or itemId
                local iconTexture = GetItemIcon(displayItemId) or 134400

                if data.itemData.isBagWeapon and data.itemData.weaponTexture then
                    iconTexture = data.itemData.weaponTexture
                elseif data.itemData.isUnifiedWeaponButton and showWeaponIcons then
                    if data.itemData.slot == "mainhand" then
                        local weaponTexture = GetInventoryItemTexture("player", 16)
                        if weaponTexture then iconTexture = weaponTexture end
                    elseif data.itemData.slot == "offhand" then
                        local weaponTexture = GetInventoryItemTexture("player", 17)
                        if weaponTexture then iconTexture = weaponTexture end
                    end
                end

                if button.icon and button.lastIconTexture ~= iconTexture then
                    button.lastIconTexture = iconTexture
                    button.icon:SetTexture(iconTexture)
                end
            end

            button.itemData = data.itemData
            button.hasBuff = data.hasBuff
            button.timeRemaining = data.timeRemaining

            visibleCount = visibleCount + 1
            local row, col
            if growDir == "DOWN" then
                row = math_floor((visibleCount - 1) / perRow)
                col = (visibleCount - 1) % perRow
            else
                col = math_floor((visibleCount - 1) / perRow)
                row = (visibleCount - 1) % perRow
            end

            local xPos = 5 + (col * (size + spacing))
            local yPos = topOffset - (row * (size + spacing))

            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", self.weaponsBar.frame, "TOPLEFT", xPos, yPos)
            self:FitButtonSize(button, size)

            if config.showCount ~= false then
                if not button.count then
                    local countFontSize = math.max(10, math.floor(size * 0.33))
                    button.count = self:CreateFontString(button, "OVERLAY", nil, countFontSize)
                    RC.BarStyle.ApplyFont(button.count, RC.BarStyle.KeyOf(button), "count", size)
                    button.count:SetShadowOffset(1, -1)
                    button.count:SetShadowColor(0, 0, 0, 1)
                    button.count:SetDrawLayer("OVERLAY", 6)
                    button.count:SetAlpha(1)
                end

                -- the corner it always had, or where the settings moved it
                RC.BarStyle.PlaceCount(button)

                local newText = data.count > 0 and tostring(data.count) or "0"
                local needsColorUpdate = false
                if button.count._cachedText ~= newText then
                    button.count:SetText(newText)
                    button.count._cachedText = newText
                    needsColorUpdate = true
                end

                if needsColorUpdate or not button.count._cachedColorKey then
                    if data.count > 0 then
                        RC.BarStyle.Paint(button.count, button, "countColor")
                        button.count._cachedColorKey = "white"
                    else
                        RC.BarStyle.Paint(button.count, button, "emptyColor")
                        button.count._cachedColorKey = "red"
                    end
                end
                button.count:Show()
            elseif button.count then
                button.count:Hide()
            end

            visibleButtonIds[itemId] = true
            button:Show()

            button.gridRow = row
            button.gridCol = col
        end

        ApplyGridSeamBorders(self.weaponsBar.buttons, BuildButtonGrid(self.weaponsBar.buttons))

        for itemId, button in pairs(self.weaponsBar.buttons) do
            if not visibleButtonIds[itemId] then
                button:Hide()
            end
        end

        if visibleCount > 0 then
            local cols, rows
            if growDir == "DOWN" then
                cols = math_min(visibleCount, perRow)
                rows = math_ceil(visibleCount / perRow)
            else
                cols = math_ceil(visibleCount / perRow)
                rows = math_min(visibleCount, perRow)
            end

            local contentWidth = cols * size + (cols - 1) * spacing
            local contentHeight = rows * size + (rows - 1) * spacing

            local sidePadding = 5
            local topPadding = 5
            local bottomPadding = 5

            local width = sidePadding + contentWidth + sidePadding
            local height = topPadding + contentHeight + bottomPadding

            SmoothSetSize(self.weaponsBar.frame, width, height)
            if not InCombatLockdown() then
                RC.Position.RestoreFrame(self.weaponsBar.frame)
            end

            self.performanceCache.buttonGridDirty = true

            self:ShowBarFrame("weaponsBar")
        else
            self:HideBarFrame("weaponsBar")
        end

        if self.UpdateWeaponsButtonStates and self.weaponsBar and self.weaponsBar.frame and self.weaponsBar.frame:IsShown() then
            self:UpdateWeaponsButtonStates()
        end
    end

    function RC:RefreshPotionsDisplay()
        if not self.potionsBar or not self.potionsBar.frame or not self.db.potionsBar then
            return
        end

        if not self.db.potionsBar.enabled then
            return
        end

        if not self:ShouldShowPotionsBar() then
            if not InCombatLockdown() then
                self:HideBarFrame("potionsBar")
            end
            return
        end

        if self.potionsBar.isRebuilding then
            return
        end

        if InCombatLockdown() then
            local now = GetTime()
            if now - (self.potionsBar.updateThrottle or 0) < 0.5 then
                return
            end
            self.potionsBar.updateThrottle = now
        end
        local visibleButtons = {}
        local visibleCount = 0

        for itemId, button in pairs(self.potionsBar.buttons) do
            if button and button.fullyInitialized then
                local itemData = button.itemData
                local countItemId = itemData.baseItemId or itemId
                local count = GetItemCount(countItemId)
                local hasBuff = self:HasConsumableBuff(countItemId)

                local shouldBeVisible = false

                if not (self.db.potionsBar.hiddenItems and self.db.potionsBar.hiddenItems[itemId]) then
				if self.db.potionsBar.showOnlyAvailable then
					shouldBeVisible = count > 0 or hasBuff
				else
					shouldBeVisible = true
				end
			end

                if shouldBeVisible then
                    visibleCount = visibleCount + 1
                    visibleButtons[visibleCount] = {
                        button = button,
                        itemId = itemId,
                        count = count,
                        hasBuff = hasBuff,
                        sortIndex = self.potionsBar.sortedOrder[itemId] or 999
                    }
                else
                    if not InCombatLockdown() then
                        button:Hide()
                    end
                end
            end
        end

        if visibleCount == 0 then
            if self.potionsBar.placeholder then
                self.potionsBar.placeholder:Show()
            end
        else
            self.potionsBar.initializing = false

            if self.potionsBar.placeholder then
                self.potionsBar.placeholder:Hide()
            end

            table.sort(visibleButtons, function(a, b)
                return a.sortIndex < b.sortIndex
            end)
        end

        if visibleCount > 0 then

        local config = self.db.potionsBar
        local size = config.buttonSize or 32
        local spacing = config.iconSpacing or 4
        local perRow = config.buttonsPerRow or 10
        local growDir = config.growDirection or "DOWN"
        local showCount = config.showCount ~= false
        local topOffset = -5

        for i = 1, visibleCount do
            local data = visibleButtons[i]
            local button = data.button

            local row, col
            if growDir == "DOWN" then
                row = math_floor((i - 1) / perRow)
                col = (i - 1) % perRow
            else
                col = math_floor((i - 1) / perRow)
                row = (i - 1) % perRow
            end

            local xPos = 5 + (col * (size + spacing))
            local yPos = topOffset - (row * (size + spacing))

            -- PROTECTED: Only reposition buttons outside of combat
            if not InCombatLockdown() then
                button:ClearAllPoints()
                button:SetPoint("TOPLEFT", self.potionsBar.frame, "TOPLEFT", xPos, yPos)

                if not button:IsShown() then
                    button:Show()
                end
            end

            if showCount then
                if not button.count then
                    local countFontSize = math.max(10, math.floor(size * 0.33))
                    button.count = self:CreateFontString(button, "OVERLAY", nil, countFontSize)
                    RC.BarStyle.ApplyFont(button.count, RC.BarStyle.KeyOf(button), "count", size)
                    button.count:SetShadowOffset(1, -1)
                    button.count:SetShadowColor(0, 0, 0, 1)
                    button.count:SetDrawLayer("OVERLAY", 6)
                    button.count:SetAlpha(1)
                end

                -- the corner it always had, or where the settings moved it
                RC.BarStyle.PlaceCount(button)

                local newText = data.count > 0 and tostring(data.count) or "0"
                local needsColorUpdate = false
                if button.count._cachedText ~= newText then
                    button.count:SetText(newText)
                    button.count._cachedText = newText
                    needsColorUpdate = true
                end

                if needsColorUpdate or not button.count._cachedColorKey then
                    if data.count > 0 then
                        RC.BarStyle.Paint(button.count, button, "countColor")
                        button.count._cachedColorKey = "white"
                    else
                        RC.BarStyle.Paint(button.count, button, "emptyColor")
                        button.count._cachedColorKey = "red"
                    end
                end
                button.count:Show()
            elseif button.count then
                button.count:Hide()
            end

            if button.icon then
                if data.count == 0 and not data.hasBuff then
                    button.icon:SetDesaturated(true)
                    button.icon:SetAlpha((button._iconHiddenByCd or (button._spentInCombat and InCombatLockdown())) and 0 or 0.4)
                    button.bg:SetColorTexture(C.redDark[1], C.redDark[2], C.redDark[3], C.redDark[4])
                elseif data.hasBuff then
                    button.icon:SetDesaturated(false)
                    button.icon:SetAlpha((button._iconHiddenByCd or (button._spentInCombat and InCombatLockdown())) and 0 or 1.0)
                    button.bg:SetColorTexture(C.greenDark[1], C.greenDark[2], C.greenDark[3], C.greenDark[4])
                else
                    button.icon:SetDesaturated(false)
                    button.icon:SetAlpha((button._iconHiddenByCd or (button._spentInCombat and InCombatLockdown())) and 0 or 1.0)
                    button.bg:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
                end
            end

        end

        if self.potionsBar.lastVisibleCount ~= visibleCount then
            self.potionsBar.lastVisibleCount = visibleCount

            local cols, rows
            if growDir == "DOWN" then
                cols = math_min(visibleCount, perRow)
                rows = math_ceil(visibleCount / perRow)
            else
                cols = math_ceil(visibleCount / perRow)
                rows = math_min(visibleCount, perRow)
            end

            local contentWidth = cols * size + (cols - 1) * spacing
            local contentHeight = rows * size + (rows - 1) * spacing

            local sidePadding = 5
            local topPadding = 5
            local bottomPadding = 5

            local width = sidePadding + contentWidth + sidePadding
            local height = topPadding + contentHeight + bottomPadding

            -- PROTECTED: Only resize frame outside of combat
            if not InCombatLockdown() then
                SmoothSetSize(self.potionsBar.frame, width, height)
                RC.Position.RestoreFrame(self.potionsBar.frame)
            end
        end
        end

        if not InCombatLockdown() and self:ShouldShowPotionsBar() then
            self:ShowBarFrame("potionsBar")
        end
    end

    function RC:UpdateConsumablesHelperLock()
        if not self.consumablesHelper.frame then return end

        local frame = self.consumablesHelper.frame
        local db = self.db.consumablesHelper

        frame:RegisterForDrag("LeftButton")

        self:UpdateConsumablesHelperTitleVisibility()
    end

    function RC:ToggleConsumablesHelperLock()
        self.db.consumablesHelper.locked = not self.db.consumablesHelper.locked

        self:UpdateConsumablesHelperLock()

        self:UpdateConsumablesHelperBackground()
        if not InCombatLockdown() then
            self:UpdateConsumablesButtons()
        end

        self:SaveConfigurationToProfile()
    end

    function RC:UpdatePotionsBarLock()
        if not self.potionsBar.frame then return end

        local frame = self.potionsBar.frame
        local db = self.db.potionsBar

        frame:RegisterForDrag("LeftButton")

        self:UpdatePotionsBarTitleVisibility()
    end

    function RC:TogglePotionsBarLock()
        self.db.potionsBar.locked = not self.db.potionsBar.locked

        self:UpdatePotionsBarLock()

        self:UpdatePotionsBarBackground()
        if not InCombatLockdown() then
            self:UpdatePotionsButtons()
        end

        self:SaveConfigurationToProfile()
    end

    function RC:UpdateConsumablesHelperBackground()
        if not self.consumablesHelper.frame then return end

        local frame = self.consumablesHelper.frame
        local db = self.db.consumablesHelper

        local shouldShow = (db.showBackground)
        self:PaintBarChrome(frame, "consumablesBar", shouldShow, db.locked == false)
        self:UpdateConsumablesHelperTitleVisibility()
    end

    function RC:UpdatePotionsBarBackground()
        if not self.potionsBar.frame then return end

        local frame = self.potionsBar.frame
        local db = self.db.potionsBar

        local shouldShow = (db.showBackground)
        self:PaintBarChrome(frame, "potionsBar", shouldShow, db.locked == false)
        self:UpdatePotionsBarTitleVisibility()
    end

    -- Shared name-label pass for the three bars. hideWeaponLabels is the
    -- consumables bar's rule: its unified/bag weapon buttons never show a
    -- name label regardless of the setting.
    local function UpdateBarNameLabels(buttons, showNames, hideWeaponLabels)
        if not buttons then return end
        for _, button in pairs(buttons) do
            if button and button.nameLabel then
                local itemData = button.itemData
                if hideWeaponLabels and itemData
                        and (itemData.isUnifiedWeaponButton or itemData.isBagWeapon) then
                    button.nameLabel:Hide()
                elseif showNames then
                    button.nameLabel:Show()
                else
                    button.nameLabel:Hide()
                end
            end
        end
    end

    function RC:UpdateConsumablesHelperNameLabels()
        UpdateBarNameLabels(self.consumablesHelper.buttons, self.db.consumablesHelper.showItemNames, true)
    end

    function RC:UpdatePotionsBarNameLabels()
        UpdateBarNameLabels(self.potionsBar.buttons, self.db.potionsBar.showItemNames)
    end

    function RC:UpdateWeaponsBarNameLabels()
        UpdateBarNameLabels(self.weaponsBar.buttons, self.db.weaponsBar.showItemNames)
    end

end
