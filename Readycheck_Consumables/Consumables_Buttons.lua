------------------------------------------------------------------------
-- Readycheck - Consumables Button States
-- Per-button visual state for all three bars: cooldown swirls, GCD, cast
-- bar, eating countdown, expiry text and border colours. Also owns bar
-- visibility (ShouldShow*) and the combat buff-expiry check.
-- UpdateSingleButton is the innermost hot-path function - it runs for
-- every visible button on every heavy tick, so it opens with a liveness
-- test that returns before doing anything for an idle button.
-- Everything here is called from tickers, never from an event handler.
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
    local IsInInstance = IsInInstance
    local IsInRaid = IsInRaid
    local IsResting = IsResting
    local InCombatLockdown = InCombatLockdown
    local UnitCastingInfo = UnitCastingInfo
    local UnitChannelInfo = UnitChannelInfo
    local math_ceil = math.ceil
    local math_abs = math.abs
    local string_format = string.format
    local string_lower = string.lower
    local pairs = pairs
    local ipairs = ipairs
    local type = type

    local _chs = WRF._chs
    local C, GetStoneColor = _chs.C, _chs.GetStoneColor
    local SetBarButtonVisualHidden = _chs.SetBarButtonVisualHidden

    -- Zone visibility rules, cached 1.0s per bar; callers invalidate by
    -- zeroing bar.lastZoneCheck. _uiMoverActive forces every bar visible
    -- for repositioning. evalMode(mode, dbTable) maps this bar's
    -- visibilityMode string to a boolean (dbTable is passed so the raid
    -- filter can be read); each bar keeps its own mode names and defaults.
    local function EvalBarVisibility(bar, dbTable, evalMode)
        if RC._uiMoverActive then return true end
        if not dbTable or not dbTable.enabled then
            return false
        end

        local mode = dbTable.visibilityMode or "always"
        if mode == "always" then
            return true
        end

        local now = GetTime()
        if bar.lastZoneCheck and (now - bar.lastZoneCheck < 1.0)
                and bar.cachedShouldShow ~= nil then
            return bar.cachedShouldShow
        end

        local shouldShow = evalMode(mode, dbTable) and true or false
        bar.lastZoneCheck = now
        bar.cachedShouldShow = shouldShow
        return shouldShow
    end
    _chs.EvalBarVisibility = EvalBarVisibility

    -- Mode mapping shared by all four bars ("raids"/"raids_only", "group",
    -- "city", "raids_and_city"; unknown -> show). "Raids" means inside a
    -- raid instance (RC:IsInRaidInstance), never merely a raid group;
    -- "group" is any party or raid anywhere (RC:IsInGroup); "city" is the
    -- rested state (RC:IsInCity). cfg is the bar's db table: its optional
    -- visibilityRaids set ({ ["Molten Core"]=true, ... }) narrows the raid
    -- modes to the ticked raids; nil/empty means every raid. Same
    -- predicates as the shout reminder, so every bar flips on the same
    -- events.
    local function RaidsCityMode(mode, cfg)
        local raidFilter = cfg and cfg.visibilityRaids
        if mode == "raids" or mode == "raids_only" then
            return RC:IsInRaidInstance(raidFilter)
        elseif mode == "group" then
            return RC:IsInGroup()
        elseif mode == "city" then
            return RC:IsInCity()
        elseif mode == "raids_and_city" then
            return RC:IsInRaidInstance(raidFilter) or RC:IsInCity()
        end
        return true
    end
    _chs.RaidsCityMode = RaidsCityMode

    function RC:ShouldShowConsumablesBar()
        return EvalBarVisibility(self.consumablesHelper, self.db and self.db.consumablesHelper, RaidsCityMode)
    end

    function RC:ShouldShowPotionsBar()
        return EvalBarVisibility(self.potionsBar, self.db and self.db.potionsBar, RaidsCityMode)
    end

    -- One grid map + seam pass shared by the bar state sweeps here and the
    -- weapons rebuild in Consumables_Weapons.lua.
    local function BuildButtonGrid(buttons)
        local grid = {}
        for _, button in pairs(buttons) do
            if button:IsShown() and button.gridRow and button.gridCol then
                if not grid[button.gridRow] then
                    grid[button.gridRow] = {}
                end
                grid[button.gridRow][button.gridCol] = button
            end
        end
        return grid
    end
    _chs.BuildButtonGrid = BuildButtonGrid

    -- Adjacent enchanted buttons would draw two 1px lines against each
    -- other, reading as a thick seam. Each drops its right and bottom
    -- edge when that neighbour is also bordered: one line per boundary.
    local function ApplyGridSeamBorders(buttons, buttonGrid)
        for _, button in pairs(buttons) do
            if button:IsShown() and button.appliedBorder and button.borderShowing then
                local row, col = button.gridRow, button.gridCol
                if row and col then
                    local rightNeighbor = buttonGrid[row] and buttonGrid[row][col + 1]
                    if rightNeighbor and rightNeighbor.borderShowing then
                        button.appliedBorder.right:Hide()
                    else
                        button.appliedBorder.right:Show()
                    end

                    local bottomNeighbor = buttonGrid[row + 1] and buttonGrid[row + 1][col]
                    if bottomNeighbor and bottomNeighbor.borderShowing then
                        button.appliedBorder.bottom:Hide()
                    else
                        button.appliedBorder.bottom:Show()
                    end
                end
            end
        end
    end
    _chs.ApplyGridSeamBorders = ApplyGridSeamBorders

    -- With hideInCombat on, a buff dropping mid-fight must still surface.
    -- Showing the container is legal in combat since it is not secure.
    -- lastBuffCheck makes this edge triggered: only a true->false
    -- transition re-shows the bar. Reached from the UNIT_AURA drain only.
    function RC:CheckBuffExpiredInCombat()
        if not InCombatLockdown() then return end
        if not self.db.consumablesHelper.hideInCombat then return end
        -- A bar hidden by its zone mode stays hidden; this only undoes
        -- the hideInCombat hide.
        if not self:ShouldShowConsumablesBar() then return end

        local importantBuffsExpired = false

        -- (this used to read self.consumableDatabase, a table nothing ever
        -- built, and threw on the first consumable change in combat - which
        -- also skipped the rebuild-after-combat flag set after this call)
        local last = self.consumablesHelper.lastBuffCheck
        for categoryKey, category in pairs(self.raidConsumables or {}) do
            if categoryKey ~= "drinks" and categoryKey ~= "utilities"
                and type(category) == "table" and category.items then
                for itemId, itemData in pairs(category.items) do
                    if itemData.buffId then
                        local hasBuff = self:HasConsumableBuff(itemId) and true or false
                        if last[itemId] == true and not hasBuff then
                            importantBuffsExpired = true
                        end
                        last[itemId] = hasBuff
                    end
                end
            end
        end

        if importantBuffsExpired then
            self.consumablesHelper.buffExpiredInCombat = true
            if self.consumablesHelper.frame then
                self:ShowBarFrame("consumablesHelper")
            end
        end
    end

    function RC:UpdateConsumablesVisibility()
        if not self.consumablesHelper.frame then return end

        self.consumablesHelper.cachedShouldShow = nil
        self.consumablesHelper.lastZoneCheck = 0

        if InCombatLockdown() then return end

        if self:ShouldShowConsumablesBar() then
            self:ShowBarFrame("consumablesHelper")
            self:UpdateConsumablesButtons()
        else
            self:HideBarFrame("consumablesHelper")
        end
    end

    function RC:UpdatePotionsVisibility()
        if not self.potionsBar.frame then return end

        if not self.db.potionsBar.enabled then
            if not InCombatLockdown() then
                self:HideBarFrame("potionsBar")
            end
            return
        end

        self.potionsBar.cachedShouldShow = nil
        self.potionsBar.lastZoneCheck = 0

        if InCombatLockdown() then return end

        if self:ShouldShowPotionsBar() then
            self:ShowBarFrame("potionsBar")
            self:UpdatePotionsButtons()
        else
            self:HideBarFrame("potionsBar")
        end
    end

    -- IsEating and GetGCDInfo are hoisted out of the loop: per-player, not
    -- per-button. skipBorders lets the 0.2s ticker skip the three grid
    -- passes below, which only matter after a layout change.
    function RC:UpdateButtonStates(skipBorders)
        if not self.consumablesHelper or not self.consumablesHelper.buttons then return end

        if not self.consumablesHelper.frame or not self.consumablesHelper.frame:IsShown() then
            return
        end

        local now = GetTime()

        local isEating, eatingTime = self:IsEating()

        local gcdRemaining, gcdDuration = self:GetGCDInfo()

        -- A pending weaponUpdateTimer means an equipment swap is still
        -- settling; weapon buttons describe slots that are mid-change, so
        -- reading them now produces flicker.
        local skipWeaponButtons = self.consumablesHelper.weaponUpdateTimer ~= nil

        for itemId, button in pairs(self.consumablesHelper.buttons) do
            if button and button:IsShown() and button.fullyInitialized then
                if skipWeaponButtons then
                    local isWeaponButton = (itemId == 999901 or itemId == 999902 or (itemId >= 900000 and itemId < 999900))
                    if isWeaponButton then
                    else
                        self:UpdateSingleButton(button, now, isEating, eatingTime, gcdRemaining, gcdDuration)
                    end
                else
                    self:UpdateSingleButton(button, now, isEating, eatingTime, gcdRemaining, gcdDuration)
                end
            end
        end

        -- Border work is three more full passes over the button table and
        -- calls HasConflictGroupBuff per button. Skipped entirely in combat:
        -- the layout it depends on cannot change under lockdown anyway.
        if skipBorders or UnitAffectingCombat("player") then
            return
        end
        local cache = self.performanceCache
        if cache.buttonGridDirty then
            cache.buttonGrid = {}
            for itemId, button in pairs(self.consumablesHelper.buttons) do
                if button:IsShown() and button.gridRow and button.gridCol then
                    if not cache.buttonGrid[button.gridRow] then
                        cache.buttonGrid[button.gridRow] = {}
                    end
                    cache.buttonGrid[button.gridRow][button.gridCol] = button
                end
            end
            cache.buttonGridDirty = false
        end

        local buttonGrid = cache.buttonGrid
        if not buttonGrid then return end

        ApplyGridSeamBorders(self.consumablesHelper.buttons, buttonGrid)

        for itemId, button in pairs(self.consumablesHelper.buttons) do
            if button:IsShown() and button.border then
                local row, col = button.gridRow, button.gridCol
                if row and col then
                    local itemData = button.itemData
                    local countItemId = itemData and (itemData.baseItemId or button.itemId) or button.itemId
                    local conflictGroup = self:TimerConflictGroup(countItemId)
                    local hasConflictBuff, conflictTime, conflictItemId = false, 0, nil
                    if conflictGroup then
                        hasConflictBuff, conflictTime, conflictItemId = self:HasConflictGroupBuff(conflictGroup)
                    end
                    local isConflict = hasConflictBuff and conflictItemId ~= countItemId

                    local borderCol

                    local hasBuff = false
                    if itemData then
                        local buffId = itemData.buffId
                        if buffId then
                            hasBuff = self:HasConsumableBuff(countItemId)
                        end
                    end

                    if hasBuff then
                        local barType = button.isPotionBar and "potionsBar" or (button.isWeaponsBar and "weaponBar" or "consumablesBar")
                        borderCol = self:GetColor(barType, "activeBorder")
                    elseif isConflict then
                        borderCol = self:GetColor("consumablesBar", "conflictBorder")
                    else
                        local barType = button.isPotionBar and "potionsBar" or (button.isWeaponsBar and "weaponBar" or "consumablesBar")
                        borderCol = self:GetColor(barType, "buttonBorder")
                    end

                    if button.border and button.border.SetBackdropBorderColor then
                        button.border:SetBackdropBorderColor(borderCol.r, borderCol.g, borderCol.b, borderCol.a or 1)
                    end
                end
            end
        end
    end

    function RC:UpdatePotionButtonStates(skipBorders)
        if not self.potionsBar or not self.potionsBar.buttons then return end

        if not self.potionsBar.frame or not self.potionsBar.frame:IsShown() then
            return
        end

        local now = GetTime()
        local gcdRemaining, gcdDuration = self:GetGCDInfo()

        for itemId, button in pairs(self.potionsBar.buttons) do
            if button and button:IsShown() and button.fullyInitialized then
                self:UpdateSingleButton(button, now, false, 0, gcdRemaining, gcdDuration)
            end
        end

        if skipBorders or UnitAffectingCombat("player") then
            return
        end

        for itemId, button in pairs(self.potionsBar.buttons) do
            if button:IsShown() and button.border then
                local row, col = button.gridRow, button.gridCol
                if row and col then
                    local borderCol

                    local hasBuff = false
                    if button.itemData then
                        local buffId = button.itemData.buffId
                        if buffId then
                            hasBuff = self:HasConsumableBuff(button.itemId)
                        end
                    end

                    if hasBuff then
                        borderCol = RC:GetColor("potionsBar", "activeBorder")
                    else
                        borderCol = RC:GetColor("potionsBar", "buttonBorder")
                    end

                    if button.border and button.border.SetBackdropBorderColor then
                        button.border:SetBackdropBorderColor(borderCol.r, borderCol.g, borderCol.b, borderCol.a or 1)
                    end
                end
            end
        end
    end

    -- Weapons-bar equivalent of UpdateButtonStates. It builds its grid map
    -- locally every call instead of using performanceCache.buttonGrid,
    -- which belongs to the consumables bar.
    function RC:UpdateWeaponsButtonStates()
        if not self.weaponsBar or not self.weaponsBar.buttons then return end

        if not self.weaponsBar.frame or not self.weaponsBar.frame:IsShown() then
            return
        end

        if self.consumablesHelper.weaponUpdateTimer ~= nil then
            return
        end

        local now = GetTime()
        local gcdRemaining, gcdDuration = self:GetGCDInfo()

        for itemId, button in pairs(self.weaponsBar.buttons) do
            if button and button:IsShown() and button.fullyInitialized then
                self:UpdateSingleButton(button, now, false, 0, gcdRemaining, gcdDuration)
            end
        end

        if UnitAffectingCombat("player") then
            return
        end

        ApplyGridSeamBorders(self.weaponsBar.buttons, BuildButtonGrid(self.weaponsBar.buttons))

        for itemId, button in pairs(self.weaponsBar.buttons) do
            if button:IsShown() and button.border then
                local row, col = button.gridRow, button.gridCol
                if row and col then
                    local borderCol

                    local hasBuff = false
                    if button.itemData then
                        local isWeaponButton = button.itemData.slot == "mainhand" or button.itemData.slot == "offhand" or button.itemData.isBagWeapon or button.itemData.enchantId
                        if isWeaponButton then
                            local hasEnchant, timeRemaining
                            if button.itemData.isBagWeapon and button.itemData.bagSlot and button.itemData.bagPosition then
                                hasEnchant, timeRemaining = self:HasBagWeaponEnchant(button.itemData.bagSlot, button.itemData.bagPosition)
                            elseif button.itemData.slot then
                                hasEnchant, timeRemaining = self:HasWeaponEnchant(button.itemId, button.itemData.slot)
                            end
                            hasBuff = hasEnchant and timeRemaining and timeRemaining > 0
                        end
                    end

                    if hasBuff then
                        borderCol = RC:GetColor("weaponBar", "activeBorder")
                    else
                        borderCol = RC:GetColor("weaponBar", "buttonBorder")
                    end

                    if button.border and button.border.SetBackdropBorderColor then
                        button.border:SetBackdropBorderColor(borderCol.r, borderCol.g, borderCol.b, borderCol.a or 1)
                    end
                end
            end
        end
    end

    -- Innermost hot-path function: runs per visible button per heavy tick.
    -- Structured as a chain of exclusive display states, each returning
    -- once it owns the button's centre text:
    --   real cooldown > GCD > cast/eat swirl > eating countdown > expiry.
    function RC:UpdateSingleButton(button, now, isEating, eatingTime, gcdRemaining, gcdDuration)
        local itemId = button.itemId
        local itemData = button.itemData
        local config
        if button.isWeaponsBar then
            config = self.db.weaponsBar
        elseif button.isPotionBar then
            config = self.db.potionsBar
        else
            config = self.db.consumablesHelper
        end

        -- Liveness gate: most buttons are idle most of the time, and
        -- everything below reads cooldowns, auras, casts and enchants.
        -- Proceed only if something is live now, was live last pass (so the
        -- clean-up frame still runs), or the button is alpha-hidden and
        -- needs restoring. Every read in this block is cached.
        do
            local _cid = (itemData and itemData.baseItemId) or itemId
            local _cs, _cd = self:GetItemCooldownByID(_cid)
            local live = (_cs and _cd and _cs > 0 and _cd > 1.5 and (_cs + _cd) - now > 0)
                or (RC._lastBarItemUse and (now - RC._lastBarItemUse) < 1.7)
                or (button.gcdFrame and button.gcdFrame:IsShown())
                or (button.castFrame and button.castFrame:IsShown())
                or (isEating and itemId == RC._lastUsedBarItemId)
            if not live and itemData then
                if itemData.slot == "mainhand" or itemData.slot == "offhand" then
                    live = self:HasWeaponEnchant(nil, itemData.slot)
                elseif itemData.isBagWeapon and itemData.bagSlot and itemData.bagPosition then
                    live = self:HasBagWeaponEnchant(itemData.bagSlot, itemData.bagPosition)
                elseif itemData.enchantId then
                    live = self:HasWeaponEnchant(_cid, "mainhand")
                elseif itemData.buffId then
                    live = self:HasConsumableBuff(_cid)
                end
            end
            if not live and not button._wrLastActive
                and not button._iconHiddenByCd and not button._spentInCombat then
                return
            end
            button._wrLastActive = live and true or false
        end

        if button.isPotionBar and button.absorbContainer and button.absorbContainer:IsShown() then
            button.absorbContainer:Hide()
        end

        if button.appliedBorder then
            local hasEnchant = false
            local enchantId = nil
            local appliedStone = nil
            local r, g, b = 0, 1, 0.5

            -- Slot readers take the canonical key. Passing anything else
            -- misses the enchant cache and reports no enchant.
            if itemData.slot == "mainhand" then
                local hasMH, _, mhEnchantId = self:HasWeaponEnchant(nil, "mainhand")
                if hasMH then
                    hasEnchant = true
                    enchantId = mhEnchantId
                    appliedStone = enchantId and self:GetStoneFromEnchantId(enchantId)
                end
            elseif itemData.slot == "offhand" then
                local hasOH, _, ohEnchantId = self:HasWeaponEnchant(nil, "offhand")
                if hasOH then
                    hasEnchant = true
                    enchantId = ohEnchantId
                    appliedStone = enchantId and self:GetStoneFromEnchantId(enchantId)
                end
            elseif itemData.isBagWeapon and itemData.bagSlot and itemData.bagPosition then
                hasEnchant = self:HasBagWeaponEnchant(itemData.bagSlot, itemData.bagPosition)
            end

            if hasEnchant then
                local stoneType = appliedStone and RC.stoneColourType[appliedStone]
                if stoneType then
                    local stoneCol = GetStoneColor(stoneType)
                    r, g, b = stoneCol.r, stoneCol.g, stoneCol.b
                end

                local newBorderState = appliedStone or "enchanted"
                if button.lastBorderState ~= newBorderState then
                    button.lastBorderState = newBorderState
                    button.appliedBorder.top:SetColorTexture(r, g, b, 1)
                    button.appliedBorder.bottom:SetColorTexture(r, g, b, 1)
                    button.appliedBorder.left:SetColorTexture(r, g, b, 1)
                    button.appliedBorder.right:SetColorTexture(r, g, b, 1)
                end

                if not button.borderShowing then
                    button.borderShowing = true
                    button.appliedBorder.top:Show()
                    button.appliedBorder.bottom:Show()
                    button.appliedBorder.left:Show()
                    button.appliedBorder.right:Show()
                end
            else
                if button.borderShowing then
                    button.borderShowing = false
                    button.lastBorderState = nil
                    button.appliedBorder.top:Hide()
                    button.appliedBorder.bottom:Hide()
                    button.appliedBorder.left:Hide()
                    button.appliedBorder.right:Hide()
                end
            end
        end

        local countItemId = itemData.baseItemId or itemId
        local cdStart, cdDuration = self:GetItemCooldownByID(countItemId)

        local cooldownRemaining = 0
        local cooldownStart = 0
        local cooldownDuration = 0
        local itemGcdRemaining = 0
        local itemGcdDuration = 0

        -- Classic Era reports the GCD through the same bag-item cooldown as
        -- a real one, so they split by duration: over 15s is the item's own
        -- cooldown, shorter is GCD-class. A short cooldown only counts as
        -- this button's GCD if it began within 1.6s of a bar click, or
        -- every bag item would flash on every ability use.
        if cdStart and cdDuration and cdStart > 0 and cdDuration > 0 then
            -- A cooldown that began before this session's clock (the
            -- client reports its start on the previous clock, far past
            -- "now") would read as hours remaining: brought onto this
            -- clock the way every cooldown addon does (2026-10-31, "7x
            -- C_Timer.After duration is too large" on Maexxna).
            if cdStart > now + 1 then cdStart = cdStart - 4294967.296 end
            local remaining = (cdStart + cdDuration) - now
            if remaining > 0 then
                if cdDuration > 15 then
                    cooldownRemaining = remaining
                    cooldownStart = cdStart
                    cooldownDuration = cdDuration
                else
                    if button._gcdActiveStart == cdStart then
                        itemGcdRemaining = remaining
                        itemGcdDuration = cdDuration
                    else
                        local lastUse = RC._lastBarItemUse or 0
                        if math_abs(cdStart - lastUse) < 1.6 then
                            itemGcdRemaining = remaining
                            itemGcdDuration = cdDuration
                            button._gcdActiveStart = cdStart
                        end
                    end
                end
            else
                button._gcdActiveStart = nil
            end
        else
            button._gcdActiveStart = nil
        end

        local hideUsedOpt = RC.db and RC.db.consumablesHelper
            and RC.db.consumablesHelper.hideUsedInCombat
        if hideUsedOpt == nil then hideUsedOpt = true end
        -- Combat-only hide of an item on cooldown. :Hide() is illegal on a
        -- secure button in combat, hence the alpha-zero helper across the
        -- button and every child that keeps its own alpha.
        if hideUsedOpt and button.icon and not button.isWeaponsBar and not button.isPotionBar then
            if cooldownRemaining > 0 and InCombatLockdown() then
                button._iconHiddenByCd = true
                button.icon:SetAlpha(0)
                SetBarButtonVisualHidden(button, true)
                -- One restore timer per cooldown, keyed on its start stamp
                -- so a re-use replaces rather than stacks it. +0.15s guards
                -- against firing just before the cooldown clears.
                if button._iconCdTimerStart ~= cooldownStart then
                    button._iconCdTimerStart = cooldownStart
                    local startStamp = cooldownStart
                    -- never longer than the cooldown itself, and never more than
                    -- an hour (C_Timer refuses a huge wait outright)
                    local wait = math.min(cooldownRemaining, cooldownDuration > 0 and cooldownDuration or cooldownRemaining, 3600)
                    C_Timer.After(wait + 0.15, function()
                        if button._iconCdTimerStart == startStamp then
                            button._iconCdTimerStart = nil
                            button._iconHiddenByCd = false
                            local sk = button._cachedStateKey
                            local stillSpent = button._spentInCombat and InCombatLockdown()
                            button.icon:SetAlpha(stillSpent and 0 or ((sk == "unavailable" and 0.4) or (sk == "conflictBuff" and 0.7) or 1.0))
                            if not stillSpent then
                                SetBarButtonVisualHidden(button, false)
                            end
                        end
                    end)
                end
            elseif button._iconHiddenByCd then
                button._iconHiddenByCd = false
                button._iconCdTimerStart = nil
                local sk = button._cachedStateKey
                local stillSpent = button._spentInCombat and InCombatLockdown()
                button.icon:SetAlpha(stillSpent and 0 or ((sk == "unavailable" and 0.4) or (sk == "conflictBuff" and 0.7) or 1.0))
                if not stillSpent then
                    SetBarButtonVisualHidden(button, false)
                end
            end
        end

        if cooldownRemaining > 0 then
            if not button.cooldownFrame:IsShown() or button.lastCooldownStart ~= cooldownStart then
                button.cooldownFrame:SetCooldown(cooldownStart, cooldownDuration)
                button.cooldownFrame:Show()
                button.lastCooldownStart = cooldownStart
            end

            self:SetBarButtonCooldownText(button, cooldownRemaining)
            button.gcdText:Hide()
            button.gcdFrame:Hide()
            if button.durationText then button.durationText:Hide() end
            if button.expiryText then button.expiryText:Hide() end
            return
        else
            button.cooldownFrame:Hide()
            button.cooldownText:Hide()
        end

        -- No API links a cast to the item that started it, so the cast is
        -- attributed by matching the spell name. Channels count too:
        -- drinking is a channel, not a cast.
        local spellName, _, _, startTime, endTime = UnitCastingInfo("player")
        if not spellName then
            spellName, _, _, startTime, endTime = UnitChannelInfo("player")
        end

        if spellName and startTime and endTime then
            local showCastTime = false
            local spellLower = string_lower(spellName)

            if itemData.slot then
                if spellLower:find("sharpen weapon", 1, true) or spellLower:find("consecrated", 1, true) then
                    showCastTime = true
                end
            end

            if itemData.enchantId then
                local itemName = GetItemInfo(itemId)
                if itemName and spellLower:find(string_lower(itemName), 1, true) then
                    showCastTime = true
                end
                if spellLower:find("oil", 1, true) then
                    showCastTime = true
                end
            end

            if itemData.category == "chronoboon" then
                if spellLower:find("chronoboon", 1, true) then
                    showCastTime = true
                end
            end

            if itemData.category == "food" or itemData.category == "drinks" then
                if isEating then
                    showCastTime = true
                end
            end

            if showCastTime then
                -- Cast times come back in milliseconds.
                local castStart = startTime / 1000
                local castEnd = endTime / 1000
                local castDuration = castEnd - castStart
                local castingTime = castEnd - now

                if castingTime > 0 and castDuration > 0 then
                    if button.castFrame then
                        if not button.castFrame:IsShown() or button.lastCastStart ~= castStart then
                            button.castFrame:SetCooldown(castStart, castDuration)
                            button.castFrame:Show()
                            button.lastCastStart = castStart
                        end
                    end

                    local newText = string_format("%d", math_ceil(castingTime))
                    if button.durationText._cachedText ~= newText then
                        button.durationText:SetText(newText)
                        button.durationText._cachedText = newText
                    end
                    if self:ShouldShowOwnCooldownText() then button.durationText:Show() else button.durationText:Hide() end
                    button.gcdFrame:Hide()
                    button.gcdText:Hide()
                    if button.expiryText then button.expiryText:Hide() end
                    return
                end
            end
        end

        if button.castFrame and button.castFrame:IsShown() then
            button.castFrame:Hide()
            button.lastCastStart = 0
        end

        if itemGcdRemaining > 0 then
            if not button.gcdFrame:IsShown() then
                local gcdStart = now - (itemGcdDuration - itemGcdRemaining)
                button.gcdFrame:SetCooldown(gcdStart, itemGcdDuration)
                button.gcdFrame:Show()
            end

            local newText = string_format("%d", math_ceil(itemGcdRemaining))
            if button.gcdText._cachedText ~= newText then
                button.gcdText:SetText(newText)
                button.gcdText._cachedText = newText
            end
            if self:ShouldShowOwnCooldownText() then button.gcdText:Show() else button.gcdText:Hide() end

            if button.durationText then button.durationText:Hide() end
            if button.expiryText then button.expiryText:Hide() end

            -- The 0.2s ticker may stop before the GCD elapses, which would
            -- strand the swirl on screen. This schedules its own clean-up,
            -- keyed on the end time so a newer GCD invalidates the old timer.
            local gcdEndTime = now + itemGcdRemaining
            if button._gcdEndTime ~= gcdEndTime then
                button._gcdEndTime = gcdEndTime
                C_Timer.After(itemGcdRemaining + 0.01, function()
                    if not button or not button._gcdEndTime then return end
                    if math_abs(button._gcdEndTime - gcdEndTime) > 0.05 then return end
                    button._gcdEndTime = nil
                    if button.gcdText and button.gcdText:IsShown() then
                        button.gcdText:Hide()
                        button.gcdText._cachedText = nil
                    end
                    if button.gcdFrame and button.gcdFrame:IsShown() then
                        button.gcdFrame:Hide()
                    end
                end)
            end
            return
        else
            if button.gcdFrame and button.gcdFrame:IsShown() then
                button.gcdFrame:Hide()
            end
            if button.gcdText and button.gcdText:IsShown() then
                button.gcdText:Hide()
                button.gcdText._cachedText = nil
            end
            button._gcdEndTime = nil
        end

        local isFood = (itemData.category == "food")
		local isDrink = (itemData.category == "drinks")
        local isInstantItem = self.itemGCDTypes and self.itemGCDTypes[itemId] == "instant"

		-- The eating aura is generic, so only the button whose item was
		-- actually used shows the countdown - otherwise every food item on
		-- the bar would count down at once.
		if isFood and isEating and eatingTime > 0 and not isInstantItem and itemId == RC._lastUsedBarItemId then
			local newText = string_format("%.0f", math_ceil(eatingTime))
			if button.durationText._cachedText ~= newText then
				button.durationText:SetText(newText)
				button.durationText._cachedText = newText
			end
			button.durationText:Show()
			if button.expiryText then button.expiryText:Hide() end
			return
		else
			if button.durationText then button.durationText:Hide() end
		end

        if button.expiryText and config.showExpiryTimer then
            local countItemId = itemData.baseItemId or itemId
            local hasBuff, timeRemaining = self:HasConsumableBuff(countItemId)

            if itemData.slot then
                hasBuff, timeRemaining = self:HasWeaponEnchant(countItemId, itemData.slot)
            elseif itemData.enchantId then
                hasBuff, timeRemaining = self:HasOwnWeaponEnchant(countItemId, "mainhand", itemData.enchantId)
            end

            if itemData.isBagWeapon and itemData.bagSlot and itemData.bagPosition then
                hasBuff, timeRemaining = self:HasBagWeaponEnchant(itemData.bagSlot, itemData.bagPosition)
            end

            local conflictGroup = self:TimerConflictGroup(countItemId)
            local hasConflictBuff, conflictTime, conflictItemId = false, 0, nil
            if conflictGroup then
                hasConflictBuff, conflictTime, conflictItemId = self:HasConflictGroupBuff(conflictGroup)
            end

            -- Own buff wins; otherwise fall back to a conflicting buff's
            -- timer, so a button whose group rival is active still shows
            -- when that rival runs out and this item becomes usable.
            local displayTime = hasBuff and timeRemaining or (hasConflictBuff and conflictTime) or 0
            local threshold = config.showBeforeExpiry or 60
            -- a poison low on charges: the charges left, in red, where the
            -- seconds would be (it reads as running out - RC:HasWeaponEnchant)
            local chargeText
            if hasBuff and (itemData.slot == "mainhand" or itemData.slot == "offhand") and self.GetWeaponCharges then
                local ch, _, low = self:GetWeaponCharges(itemData.slot)
                if low then chargeText = string_format("%dc", ch) end
            end

            -- Two readouts: a corner minutes label while the enchant is
            -- healthy, swapping to the large centred seconds text inside
            -- the threshold. Each branch hides the other explicitly.
            if (button.isWeaponsBar or itemData.enchantId) and button.weaponTimeText then
                if displayTime > 0 then
                    if displayTime <= threshold then
                        button.weaponTimeText:Hide()
                        button.weaponTimeText._cachedText = nil
                        button.weaponTimeText._cachedColorKey = nil

                        local seconds = math_ceil(displayTime)
                        local newText = chargeText or string_format("%d", seconds)
                        if button.expiryText._cachedText ~= newText then
                            button.expiryText:SetText(newText)
                            button.expiryText._cachedText = newText
                        end

                        local redCutoff = threshold * 0.5
                        local colorKey = displayTime < redCutoff and "red" or "gold"
                        if button.expiryText._cachedColorKey ~= colorKey then
                            if displayTime < redCutoff then
                                RC.BarStyle.Paint(button.expiryText, button, "expiryUrgentColor")
                            else
                                RC.BarStyle.Paint(button.expiryText, button, "expirySoonColor")
                            end
                            button.expiryText._cachedColorKey = colorKey
                        end
                        button.expiryText:Show()
                    else
                        button.expiryText:Hide()
                        button.expiryText._cachedText = nil
                        button.expiryText._cachedColorKey = nil

                        local mins = math_ceil(displayTime / 60)
                        local newText = tostring(mins)
                        if button.weaponTimeText._cachedText ~= newText then
                            button.weaponTimeText:SetText(newText)
                            button.weaponTimeText._cachedText = newText
                        end

                        local colorKey
                        if displayTime < 60 then
                            colorKey = "red"
                        elseif displayTime < 300 then
                            colorKey = "gold"
                        else
                            colorKey = "green"
                        end

                        if button.weaponTimeText._cachedColorKey ~= colorKey then
                            if displayTime < 60 then
                                RC.BarStyle.Paint(button.weaponTimeText, button, "timerLowColor")
                            elseif displayTime < 300 then
                                RC.BarStyle.Paint(button.weaponTimeText, button, "timerMidColor")
                            else
                                RC.BarStyle.Paint(button.weaponTimeText, button, "timerGoodColor")
                            end
                            button.weaponTimeText._cachedColorKey = colorKey
                        end
                        button.weaponTimeText:Show()
                    end
                else
                    button.weaponTimeText:Hide()
                    button.weaponTimeText._cachedText = nil
                    button.weaponTimeText._cachedColorKey = nil
                    button.expiryText:Hide()
                    button.expiryText._cachedText = nil
                    button.expiryText._cachedColorKey = nil
                end
            else
                if displayTime > 0 and displayTime <= threshold then
                    local seconds = math_ceil(displayTime)
                    local newText = chargeText or string_format("%d", seconds)
                    if button.expiryText._cachedText ~= newText then
                        button.expiryText:SetText(newText)
                        button.expiryText._cachedText = newText
                    end

                    local redCutoff = threshold * 0.5
                    local colorKey = displayTime < redCutoff and "red" or "gold"
                    if button.expiryText._cachedColorKey ~= colorKey then
                        if displayTime < redCutoff then
                            RC.BarStyle.Paint(button.expiryText, button, "expiryUrgentColor")
                        else
                            RC.BarStyle.Paint(button.expiryText, button, "expirySoonColor")
                        end
                        button.expiryText._cachedColorKey = colorKey
                    end
                    button.expiryText:Show()
                else
                    button.expiryText:Hide()
                    button.expiryText._cachedText = nil
                    button.expiryText._cachedColorKey = nil
                end
            end
        end
    end
end
