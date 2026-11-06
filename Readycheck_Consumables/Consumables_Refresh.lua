------------------------------------------------------------------------
-- Readycheck - Consumables Rebuild and Refresh
-- The hot path. Owns the full bar rebuild (UpdateConsumablesButtons,
-- UpdatePotionsButtons), the cheap per-frame refresh (RefreshConsumables-
-- Display), the expiry/TTS threshold sweep (CheckConsumablesThreshold)
-- and the 1.0s shared maintenance ticker.
--
-- PERFORMANCE LAW. BAG_UPDATE, BAG_UPDATE_COOLDOWN, SPELL_UPDATE_COOLDOWN
-- and UNIT_AURA fire 10-20+ times per second in combat. NOTHING in this
-- file may be called inline from those handlers: every function here
-- iterates buttons or slots and hits WoW APIs. The handlers (in
-- Consumables_Events, Frames and Runtime, not here) may only set a
-- dirty flag, call a start-ticker function with an early-return guard, or
-- C_Timer.After. All work below runs from a 0.2s or 1.0s ticker.
--
-- Dirty flags this file drains, and who sets them:
--   RC.Bags:Version()    the shared bag index; moves when the bags change
--                        -> RefreshBagItemCountCache, ScanBagWeapons
--   buffCache/buffCacheTime  UNIT_AURA (0.2s aura dispatcher -> Frames)
--   _flatConsumableItemsDirty  item db or custom-item edits
--   buttonGridDirty      any rebuild -> UpdateButtonStates
--   pendingRebuildOnCombatEnd  anything blocked by combat lockdown
--                        -> the combat-end handler in Frames
--   _lastRefreshEpoch + _nextThresholdEventTime  let a refresh no-op when
--                        neither the buff nor the bag epoch moved.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local UnitAura = UnitAura or (RCC and RCC.Compat and RCC.Compat.UnitAura)
local WRF = _G.Readycheck
if not WRF then return end
WRF._chInit = WRF._chInit or {}
WRF._chs = WRF._chs or {}
WRF._chInit[#WRF._chInit + 1] = function()
    local RC = _G.Readycheck
    local GetTime = GetTime
    local GetItemCount = GetItemCount or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemCount)
    local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
    local UnitBuff = UnitBuff or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.UnitBuff)
    local GetWeaponEnchantInfo = GetWeaponEnchantInfo
    local IsInInstance = IsInInstance
    local IsInRaid = IsInRaid
    local IsResting = IsResting
    local InCombatLockdown = InCombatLockdown
    local UnitGetTotalAbsorbs = UnitGetTotalAbsorbs
    local UnitGUID = UnitGUID
    local UnitCastingInfo = UnitCastingInfo
    local UnitChannelInfo = UnitChannelInfo
    local GetSpellCooldown = GetSpellCooldown or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetSpellCooldown)
    local math_floor = math.floor
    local math_ceil = math.ceil
    local math_max = math.max
    local math_min = math.min
    local math_abs = math.abs
    local string_format = string.format
    local string_lower = string.lower
    local pairs = pairs
    local ipairs = ipairs
    local type = type

    local _chs = WRF._chs
    local C, SmoothSetSize, categoryOrder, conflictGroupSortKey = _chs.C, _chs.SmoothSetSize, _chs.categoryOrder, _chs.conflictGroupSortKey

    ------------------------------------------------------------------
    -- Shared per-button passes used by BOTH the full rebuild
    -- (UpdateConsumablesButtons) and the cheap refresh
    -- (RefreshConsumablesDisplay). Any change here changes both paths.
    ------------------------------------------------------------------

    -- Four visual states behind one cached string key: the whole colour
    -- block is skipped unless the key changed. _iconHiddenByCd /
    -- _spentInCombat force alpha 0 regardless of state.
    local function ApplyButtonStateColors(button, count, hasBuff, hasConflictBuff, conflictItemId, itemId)
        if not button.icon then return end
        local newStateKey
        if count == 0 and not hasBuff then
            newStateKey = "unavailable"
        elseif hasBuff then
            newStateKey = "hasBuff"
        elseif hasConflictBuff and conflictItemId ~= itemId then
            newStateKey = "conflictBuff"
        else
            newStateKey = "normal"
        end
        if button._cachedStateKey == newStateKey then return end
        button._cachedStateKey = newStateKey

        local hiddenAlpha = button._iconHiddenByCd or (button._spentInCombat and InCombatLockdown())
        local barType = button.isPotionBar and "potionsBar" or (button.isWeaponsBar and "weaponBar" or "consumablesBar")
        if newStateKey == "unavailable" then
            button.icon:SetDesaturated(true)
            button.icon:SetAlpha(hiddenAlpha and 0 or 0.4)
            button.bg:SetColorTexture(C.redDark[1], C.redDark[2], C.redDark[3], C.redDark[4])
            if button.border and button.border.SetBackdropBorderColor then
                local bc = RC:GetColor(barType, "buttonBorder")
                button.border:SetBackdropBorderColor(bc.r, bc.g, bc.b, bc.a or 1)
            end
        elseif newStateKey == "hasBuff" then
            button.icon:SetDesaturated(false)
            button.icon:SetAlpha(hiddenAlpha and 0 or 1.0)
            button.bg:SetColorTexture(C.greenDark[1], C.greenDark[2], C.greenDark[3], C.greenDark[4])
            if button.border and button.border.SetBackdropBorderColor then
                local ac = RC:GetColor(barType, "activeBorder")
                button.border:SetBackdropBorderColor(ac.r, ac.g, ac.b, ac.a or 1)
            end
        elseif newStateKey == "conflictBuff" then
            local conflictBg = RC:GetColor("consumablesBar", "conflictBackground")
            button.icon:SetDesaturated(false)
            button.icon:SetAlpha(hiddenAlpha and 0 or 0.7)
            button.bg:SetColorTexture(conflictBg.r, conflictBg.g, conflictBg.b, conflictBg.a or 1)
            if button.border and button.border.SetBackdropBorderColor then
                local cc = RC:GetColor("consumablesBar", "conflictBorder")
                button.border:SetBackdropBorderColor(cc.r, cc.g, cc.b, cc.a or 1)
            end
        else
            button.icon:SetDesaturated(false)
            button.icon:SetAlpha(hiddenAlpha and 0 or 1.0)
            button.bg:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
            if button.border and button.border.SetBackdropBorderColor then
                local bc = RC:GetColor(barType, "buttonBorder")
                button.border:SetBackdropBorderColor(bc.r, bc.g, bc.b, bc.a or 1)
            end
        end
    end

    -- the same state paint for the pane samples
    function RC:ApplyBarButtonState(button, count, hasBuff, hasConflictBuff, conflictItemId, itemId)
        ApplyButtonStateColors(button, count, hasBuff, hasConflictBuff, conflictItemId, itemId)
    end

    -- Corner minutes/hours readout, weapon buttons only. It yields to the
    -- centred expiryText once the buff is inside the warning threshold.
    local function UpdateWeaponTimeLabel(button, hasBuff, timeRemaining, threshold)
        if not button.timeLabel then return end
        local itemData = button.itemData
        local isWeaponButton = itemData and (itemData.slot == "mainhand" or itemData.slot == "offhand"
            or itemData.isBagWeapon or itemData.enchantId)
        local expiryWarningActive = hasBuff and timeRemaining and timeRemaining > 0 and timeRemaining <= threshold
        if isWeaponButton and hasBuff and timeRemaining and timeRemaining > 0 and not expiryWarningActive then
            RC:SetBarButtonTimeLabel(button, timeRemaining)
        else
            button.timeLabel:Hide()
            button.timeLabel._cachedText = nil
            button.timeLabel._cachedColorKey = nil
        end
    end

    function RC:UpdateBarButtonTimeLabel(button, hasBuff, timeRemaining, threshold)
        UpdateWeaponTimeLabel(button, hasBuff, timeRemaining, threshold)
    end

    -- Expiry glow. The spoken warning is the voice watch's (TTSEngine.lua).
    local function UpdateExpiryGlow(button, hasBuff, timeRemaining, threshold, now)
        local showGlow = hasBuff and timeRemaining and timeRemaining > 0 and timeRemaining <= threshold
        RC:SetBarButtonGlow(button, showGlow and true or false)
    end

    -- Grid-derived frame resize + re-anchor shared by the rebuild and
    -- refresh passes. No-op in combat (protected frame layout).
    local function ResizeBarFrame(frame, dbTable, visibleCount, size, spacing, perRow, growDir)
        if visibleCount <= 0 or InCombatLockdown() then return end
        local cols, rows
        if growDir == "DOWN" then
            cols = math_min(visibleCount, perRow)
            rows = math_ceil(visibleCount / perRow)
        else
            cols = math_ceil(visibleCount / perRow)
            rows = math_min(visibleCount, perRow)
        end
        local contentWidth  = cols * size + (cols - 1) * spacing
        local contentHeight = rows * size + (rows - 1) * spacing
        local width  = 5 + contentWidth + 5
        local height = 5 + contentHeight + 5
        SmoothSetSize(frame, width, height)
        RC.Position.RestoreFrame(frame)
    end

    -- One 1.0s ticker for all three bars' slow maintenance: expiry
    -- thresholds and timer text. The `if self._barsMaintTicker then return`
    -- guard is what makes this safe to call from any event or bar creation
    -- path - repeated calls are free and never stack a second ticker.
    -- It cancels itself when no bar is enabled, so a disabled bar costs zero.
    function RC:StartBarsMaintTicker()
        if self.StartConsumableVoiceWatch then self:StartConsumableVoiceWatch() end
        if self._barsMaintTicker then return end
        local tickerFn = function()
            local anyRan = false

            -- The 0.2s cooldown ticker already covers timer text when it is
            -- running; doing it here too would double the work per second.
            local tickerActive = RC.consumablesHelper and RC.consumablesHelper.cooldownTickerActive

            local chDb = RC.db and RC.db.consumablesHelper
            if chDb and chDb.enabled and RC.consumablesHelper and not RC.consumablesHelper.isRebuilding then
                anyRan = true
                if RC.CheckConsumablesThreshold then
                    RC:CheckConsumablesThreshold()
                end
                if not tickerActive and RC.consumablesHelper.buttons then
                    local hasActiveBuffs = false
                    for _, button in pairs(RC.consumablesHelper.buttons) do
                        if button and button:IsShown() and button.expiryText and button.expiryText:IsShown() then
                            hasActiveBuffs = true
                            break
                        end
                    end
                    if hasActiveBuffs and RC.UpdateConsumablesTimers then
                        RC:UpdateConsumablesTimers()
                    end
                end
            end

            local pbDb = RC.db and RC.db.potionsBar
            if pbDb and pbDb.enabled and RC.potionsBar and RC.potionsBar.frame
               and RC.potionsBar.frame:IsShown() and not RC.potionsBar.isRebuilding then
                anyRan = true
                if not tickerActive then
                    if RC.UpdatePotionButtonStates then
                        RC:UpdatePotionButtonStates()
                    end
                    local hasActiveBuffs = false
                    if RC.potionsBar.buttons then
                        for _, button in pairs(RC.potionsBar.buttons) do
                            if button and button:IsShown() and button.expiryText and button.expiryText:IsShown() then
                                hasActiveBuffs = true
                                break
                            end
                        end
                    end
                    if hasActiveBuffs and RC.RefreshPotionsDisplay then
                        RC:RefreshPotionsDisplay()
                    end
                end
            end

            -- (skipped while the cooldown ticker is already sweeping this
            -- bar for a cooldown on it - same pass, same second)
            local wbDb = RC.db and RC.db.weaponsBar
            if wbDb and wbDb.enabled and RC.weaponsBar and RC.weaponsBar.frame
               and RC.weaponsBar.frame:IsShown() then
                anyRan = true
                if RC.UpdateWeaponsButtonStates
                    and not (tickerActive and RC.consumablesHelper._updW) then
                    RC:UpdateWeaponsButtonStates()
                end
            end

            -- No bar did any work: stop. Enabling one restarts the ticker.
            if not anyRan and RC._barsMaintTicker then
                RC._barsMaintTicker:Cancel()
                RC._barsMaintTicker = nil
            end
        end
        if RC.Profiler and RC.Profiler.TrackTicker then
            self._barsMaintTicker = RC.Profiler:TrackTicker("ConsumablesHelper:SharedBarsMaint", 1.0, tickerFn)
        else
            self._barsMaintTicker = C_Timer.NewTicker(1.0, tickerFn)
        end
    end

    -- Item counts from the shared bag index, rebuilt only when the bags
    -- changed since the last build. Callers are rebuilds only.
    function RC:RefreshBagItemCountCache()
        local ch = self.consumablesHelper
        if not ch then return {} end
        local cache = ch.persistentItemCountCache
        local v = RC.Bags:Version()
        if cache and ch._countVersion == v then
            return cache
        end
        cache = {}
        RC.Bags:Each(function(_, _, id, count)
            cache[id] = (cache[id] or 0) + count
        end)
        ch.persistentItemCountCache = cache
        ch._countVersion = v
        return cache
    end

    -- Defined at init level, NOT inside UpdateConsumablesButtons: the checker
    -- window uses these too, and users who never build the consumables bar
    -- (bar disabled/hidden) crashed with a nil call because the definitions
    -- were previously nested inside the bar rebuild and never executed.
    RC.itemInfoCache = RC.itemInfoCache or {}

    local _iconById = {}
    function RC:GetCachedItemIcon(itemId)
        if not itemId then return nil end
        local v = _iconById[itemId]
        if v then return v end
        v = GetItemIcon(itemId)
        if v then _iconById[itemId] = v end
        return v
    end

    function RC:GetCachedItemInfo(itemLink)
        if not itemLink then return nil end

        local cached = self.itemInfoCache[itemLink]
        if cached then
            return unpack(cached)
        end

        local itemName, itemLink2, itemQuality, itemLevel, itemMinLevel, itemType,
              itemSubType, itemStackCount, itemEquipLoc, itemTexture, sellPrice, itemClassID = GetItemInfo(itemLink)

        if itemName then
            self.itemInfoCache[itemLink] = {itemName, itemLink2, itemQuality, itemLevel, itemMinLevel, itemType,
                                            itemSubType, itemStackCount, itemEquipLoc, itemTexture, sellPrice, itemClassID}
            return itemName, itemLink2, itemQuality, itemLevel, itemMinLevel, itemType,
                   itemSubType, itemStackCount, itemEquipLoc, itemTexture, sellPrice, itemClassID
        end

        return nil
    end

    -- Full rebuild, and the most expensive operation in the addon. Only
    -- reachable via a timer, a dirty-flag drain or an explicit user action.
    -- The MH/OH stone button's face: the weapon in that hand when weapon
    -- icons are on, else the stone. Only a texture, so safe in combat.
    function RC:RefreshUnifiedWeaponIcon(button)
        local data = button and button.itemData
        if not (data and data.isUnifiedWeaponButton and button.icon) then return end
        local tex
        if self.db.consumablesHelper.showWeaponIcons then
            tex = GetInventoryItemTexture("player", data.slot == "offhand" and 17 or 16)
        end
        tex = tex or GetItemIcon(data.baseItemId or 0) or 134400
        if button.icon:GetTexture() ~= tex then button.icon:SetTexture(tex) end
    end

    function RC:UpdateConsumablesButtons()
        if not self.raidConsumables then
            C_Timer.After(0.5, function()
                if self and self.UpdateConsumablesButtons then
                    self:UpdateConsumablesButtons()
                end
            end)
            return
        end

        -- Queue-until-combat-ends. A rebuild creates, reparents, repositions
        -- and re-attributes secure buttons, all of which are forbidden under
        -- lockdown. PLAYER_REGEN_ENABLED (Consumables_Frames) drains this.
        if not self.consumablesHelper.frame or InCombatLockdown() then
            if InCombatLockdown() then
                self.consumablesHelper.pendingRebuildOnCombatEnd = true
            end
            return
        end

        if not self:ShouldShowConsumablesBar() then
            self:HideBarFrame("consumablesHelper")
            return
        end

        local now = GetTime()
        if not self.consumablesHelper.lastRebuildTime then
            self.consumablesHelper.lastRebuildTime = 0
        end

        -- Trailing-edge 0.5s throttle: a burst of callers collapses into one
        -- deferred rebuild, so the last caller's state is still rendered.
        local timeSinceLastRebuild = now - self.consumablesHelper.lastRebuildTime
        if timeSinceLastRebuild < 0.5 then
            if not self.consumablesHelper.rebuildScheduled then
                self.consumablesHelper.rebuildScheduled = true
                local delay = 0.5 - timeSinceLastRebuild
                C_Timer.After(delay, function()
                    self.consumablesHelper.rebuildScheduled = false
                    if self and self.UpdateConsumablesButtons then
                        self:UpdateConsumablesButtons()
                    end
                end)
            end
            return
        end

        self.consumablesHelper.lastRebuildTime = now

        if RC.Profiler then RC.Profiler:StartTiming("ConsumRebuild") end

        -- The shared buff map (one read per aura change) for the whole
        -- rebuild; buffCacheTime is the epoch the refresh skip compares.
        local buffCache = self:SnapshotAllBuffs()
        self.consumablesHelper.buffCache = buffCache
        self.consumablesHelper.buffCacheTime = now

        local itemCountCache = self:RefreshBagItemCountCache()

        local function GetCachedItemCount(itemId)
            return itemCountCache[itemId] or 0
        end

        -- The raw stone ids are NOT stones for this purpose: they are what
        -- the 999901/999902 slot buttons apply, so excluding them here
        -- would delete the only way to see them.
        local function IsWeaponStoneItem(itemId, itemData)
            if RC.weaponStoneIds[itemId] then
                return false
            end
            if itemId == 182621 or itemId == 182622 or
               itemId == 231221 or itemId == 231222 or
               itemId == 124041 or itemId == 124042 or
               itemId == 38291 or itemId == 38292 then
                return true
            end
            if RC.IsWeaponOilItem and RC:IsWeaponOilItem(itemId) then
                return true
            end
            return false
        end

        self.consumablesHelper.isRebuilding = true

        local config = self.db.consumablesHelper
        local size = config.buttonSize or 36

        -- Buttons are pooled by itemId. Clearing _cachedStateKey and the
        -- last position forces the icon and SetPoint work to run again.
        for itemId, button in pairs(self.consumablesHelper.buttons) do
            button:Hide()
            button._cachedStateKey = nil
            button._lastXPos = nil
            button._lastYPos = nil

            -- Synthetic-id buttons are destroyed rather than pooled when
            -- their weapon is gone: itemData encodes a stale slot or bag
            -- position that no longer resolves.
            if itemId == 999901 then
                local mhTexture = GetInventoryItemTexture("player", 16)
                if not mhTexture or self:IsHordeMode("consumablesHelper") then
                    button:SetParent(nil)
                    self.consumablesHelper.buttons[itemId] = nil
                end
            elseif itemId == 999902 then
                local ohTexture = GetInventoryItemTexture("player", 17)
                local shouldRemove = not ohTexture

                if not shouldRemove and ohTexture then
                    local ohLink = GetInventoryItemLink("player", 17)
                    if ohLink then
                        local _, _, _, _, _, _, itemSubType, _, itemEquipLoc, _, _, itemClassID = self:GetCachedItemInfo(ohLink)
                        if itemClassID ~= 2 or itemEquipLoc == "INVTYPE_SHIELD" then
                            shouldRemove = true
                        else
                            local sub = itemSubType and itemSubType:lower() or ""
                            local isSharpenable = (sub:find("sword") or sub:find("axe") or
                                                   sub:find("mace") or sub:find("dagger") or
                                                   sub:find("fist"))
                            if not isSharpenable then
                                shouldRemove = true
                            end
                        end
                    end
                end

                if shouldRemove then
                    button:SetParent(nil)
                    self.consumablesHelper.buttons[itemId] = nil
                end
            elseif itemId >= 900000 and itemId < 999900 and button.itemData then
                local bagSlot = button.itemData.bagSlot
                local bagPos = button.itemData.bagPosition
                local storedWeaponId = button.itemData.weaponItemId

                if bagSlot and bagPos then
                    local currentLink = C_Container.GetContainerItemLink(bagSlot, bagPos)
                    local currentItemId = currentLink and GetItemInfoInstant(currentLink)
                    if not currentItemId or currentItemId ~= storedWeaponId then
                        button:SetParent(nil)
                        self.consumablesHelper.buttons[itemId] = nil
                    end
                end
            end

            if self.consumablesHelper.buttons[itemId] and not self.consumablesHelper.buttons[itemId].fullyInitialized then
                self:EnsureButtonTextElements(self.consumablesHelper.buttons[itemId], config, size)
            elseif self.consumablesHelper.buttons[itemId] then
                self:FitButtonSize(self.consumablesHelper.buttons[itemId], size)
            end
        end

        local consumables = {}
        local consumableCount = 0

        if not self.db.consumablesHelper.hiddenItems then
            self.db.consumablesHelper.hiddenItems = {}
        end

        local conflictGroupRepresentative = {}

        -- Priority when a conflict group collapses to one button: carried
        -- user preference, else first carried item of conflictGroupPriority,
        -- else the preference or list head so something is still shown.
        local function GetConflictGroupRepresentative(groupName)
            if not self.conflictGroupPriority or not self.conflictGroupPriority[groupName] then
                return nil
            end

            local priority = self.conflictGroupPriority[groupName]
            local prefs = self.db.consumablesHelper.conflictGroupPreferences or {}

            local preferredItem = prefs[groupName]
            if preferredItem then
                local count = GetCachedItemCount(preferredItem)
                if count > 0 then
                    return preferredItem, "userPreference"
                end
            end

            for _, itemId in ipairs(priority) do
                local count = GetCachedItemCount(itemId)
                if count > 0 then
                    return itemId, "firstAvailable"
                end
            end

            return preferredItem or priority[1], "noneAvailable"
        end

        -- 999901: the mainhand weapon-enchant slot button. Suppressed for
        -- Horde (no stone vendor path) and when the equipped mainhand takes
        -- no stone. No class gate applies.
        local hordeMode = self:IsHordeMode("consumablesHelper")
        local mhTexture = GetInventoryItemTexture("player", 16)
        local mhInvItemId = GetInventoryItemID("player", 16)
        if mhTexture and not hordeMode
            and not (self.db.consumablesHelper.hiddenItems and self.db.consumablesHelper.hiddenItems[999901])
            and not (config.hiddenWeapons and mhInvItemId and config.hiddenWeapons[mhInvItemId]) then
            local mhLink = GetInventoryItemLink("player", 16)
            local isMHSharpenable = false
            if mhLink then
                local _, _, _, _, _, _, itemSubType, _, itemEquipLoc, _, _, itemClassID = self:GetCachedItemInfo(mhLink)
                if itemClassID == 2 then
                    local sub = itemSubType and itemSubType:lower() or ""
                    -- Mainhand accepts staves and polearms; the offhand test
                -- below omits both, since neither equips there.
                    isMHSharpenable = (sub:find("sword") or sub:find("axe") or
                                       sub:find("mace") or sub:find("dagger") or
                                       sub:find("polearm") or sub:find("fist") or
                                       sub:find("staff"))
                end
            end

            if isMHSharpenable then
                local selectedStone = self:GetValidStoneType("mainhand")
                local displayStone = selectedStone
                local stoneCount = GetCachedItemCount(displayStone)
                local hasBuff, timeRemaining = self:HasWeaponEnchant(selectedStone, "mainhand")
                local shouldShow = not config.showOnlyAvailable or stoneCount > 0 or hasBuff

                if shouldShow then
                    consumableCount = consumableCount + 1
                    consumables[consumableCount] = {
                        itemId = 999901,
                        itemData = {
                            name = "Mainhand Stone",
                            slot = "mainhand",
                            baseItemId = displayStone,
                            isUnifiedWeaponButton = true
                        },
                        count = stoneCount,
                        category = "utilities",
                        hasBuff = hasBuff,
                        timeRemaining = timeRemaining
                    }
                end
            end
        end

        local ohTexture = GetInventoryItemTexture("player", 17)
        local ohInvItemId = GetInventoryItemID("player", 17)
        if ohTexture
            and not (self.db.consumablesHelper.hiddenItems and self.db.consumablesHelper.hiddenItems[999902])
            and not (config.hiddenWeapons and ohInvItemId and config.hiddenWeapons[ohInvItemId]) then
            local ohLink = GetInventoryItemLink("player", 17)
            local isOHSharpenable = false
            if ohLink then
                local _, _, _, _, _, _, itemSubType, _, itemEquipLoc, _, _, itemClassID = self:GetCachedItemInfo(ohLink)
                if itemClassID == 2 and itemEquipLoc ~= "INVTYPE_SHIELD" then
                    local sub = itemSubType and itemSubType:lower() or ""
                    isOHSharpenable = (sub:find("sword") or sub:find("axe") or
                                       sub:find("mace") or sub:find("dagger") or
                                       sub:find("fist"))
                end
            end

            if isOHSharpenable then
                local selectedStone = self:GetValidStoneType("offhand")
                local displayStone = selectedStone
                local stoneCount = GetCachedItemCount(displayStone)
                local hasBuff, timeRemaining = self:HasWeaponEnchant(selectedStone, "offhand")
                local shouldShow = not config.showOnlyAvailable or stoneCount > 0 or hasBuff

                if shouldShow then
                    consumableCount = consumableCount + 1
                    consumables[consumableCount] = {
                        itemId = 999902,
                        itemData = {
                            name = "Offhand Stone",
                            slot = "offhand",
                            baseItemId = displayStone,
                            isUnifiedWeaponButton = true
                        },
                        count = stoneCount,
                        category = "utilities",
                        hasBuff = hasBuff,
                        timeRemaining = timeRemaining
                    }
                end
            end
        end

        -- Flatten the nested category -> items walk once, until
        -- _flatConsumableItemsDirty. _flatItemIdSet built alongside is what
        -- the UseContainerItem hook in Runtime tests bag clicks against.
        if not self._flatConsumableItems or self._flatConsumableItemsDirty then
            self._flatConsumableItemsDirty = false
            local flat = {}
            local n = 0
            for _, categoryKey in ipairs(self.consumablesHelper.categories) do
                local category = self.raidConsumables[categoryKey]
                if category and category.items then
                    for itemId, itemData in pairs(category.items) do
                        -- Items the potions bar claims are skipped unless
                        -- bothBarsItems opts them into appearing on both.
                        if not IsWeaponStoneItem(itemId, itemData) and not itemData.noBar and not (self.potionBarItems[itemId] and not (self.bothBarsItems and self.bothBarsItems[itemId])) then
                            n = n + 1
                            flat[n] = {
                                itemId     = itemId,
                                itemData   = itemData,
                                categoryKey = categoryKey,
                                countItemId = itemData.baseItemId or itemId,
                            }
                        end
                    end
                end
            end
            local customItems = self.db and self.db.consumablesHelper and self.db.consumablesHelper.customItems
            if customItems then
                for itemId, itemData in pairs(customItems) do
                    if not IsWeaponStoneItem(itemId, itemData)
                        and not (RC.IsWeaponOilItem and RC:IsWeaponOilItem(itemId)) then
                    local catKey = itemData.category or "custom"
                    n = n + 1
                    flat[n] = {
                        itemId     = itemId,
                        itemData   = itemData,
                        categoryKey = catKey,
                        countItemId = itemData.baseItemId or itemId,
                        isCustom   = true,
                    }
                    end
                end
            end
            self._flatConsumableItems = flat
            local idset = {}
            for i = 1, n do idset[flat[i].itemId] = true end
            self._flatItemIdSet = idset
        end

        -- Per-rebuild memo so each conflict group is resolved at most once,
        -- no matter how many of its members are iterated.
        local conflictGroupExpiry = {}
        local hiddenItems = self.db.consumablesHelper.hiddenItems
        local showOnlyAvailable = config.showOnlyAvailable
        -- Seconds before expiry that count as "expiring": drives re-show,
        -- the glow and the TTS warning.
        local threshold = config.showBeforeExpiry or 60
        local now_t = GetTime()

        for _, entry in ipairs(self._flatConsumableItems) do
            local itemId     = entry.itemId
            local itemData   = entry.itemData
            local categoryKey = entry.categoryKey
            local countItemId = entry.countItemId

            if not hiddenItems[itemId] and not (itemData.enchantId and (hiddenItems[999901] or hordeMode)) then
                local count = GetCachedItemCount(countItemId)

                local buffId = self:GetConsumableBuffId(countItemId)
                local hasBuff, timeRemaining = false, 0
                local skipItem = false

                if buffId then
                    local buffData = self:ResolveConsumableBuff(self.consumablesHelper.buffCache, buffId)
                    if buffData then
                        local rem = buffData.expirationTime and buffData.expirationTime > 0
                            and (buffData.expirationTime - now_t) or 0
                        hasBuff = true
                        timeRemaining = rem
                    elseif showOnlyAvailable and count == 0 then
                        skipItem = true
                    end
                elseif showOnlyAvailable and count == 0 then
                    skipItem = true
                end

                if not skipItem then
                        local myBuffExpiring = hasBuff and timeRemaining > 0 and timeRemaining <= threshold

                        local conflictGroup = self:TimerConflictGroup(countItemId)

                        local shouldShow = false
                        local shouldSkipForGroup = false

                        -- Visibility precedence inside a conflict group:
                        --  1. my own buff is expiring -> always show
                        --  2. a rival's buff is up and not expiring -> show
                        --     only the group representative (or nothing at
                        --     all when hideWhenActive and it is my own buff)
                        --  3. nothing active -> normal availability rules
                        if conflictGroup then
                            if conflictGroupExpiry[conflictGroup] == nil then
                                local hasGroupBuff, groupTime, groupItemId = self:HasConflictGroupBuff(conflictGroup)
                                conflictGroupExpiry[conflictGroup] = {
                                    hasGroupBuff = hasGroupBuff,
                                    groupTime = groupTime,
                                    groupItemId = groupItemId,
                                    isExpiring = hasGroupBuff and groupTime > 0 and groupTime <= threshold
                                }
                            end

                            local groupState = conflictGroupExpiry[conflictGroup]

                            if myBuffExpiring then
                                shouldShow = true

                            elseif groupState.hasGroupBuff and not groupState.isExpiring then
                                if config.hideWhenActive and hasBuff then
                                    shouldShow = false
                                else
                                    shouldShow = not config.showOnlyAvailable or count > 0 or hasBuff

                                    if shouldShow and config.groupConflictButtons then
                                        if not conflictGroupRepresentative[conflictGroup] then
                                            conflictGroupRepresentative[conflictGroup] = GetConflictGroupRepresentative(conflictGroup)
                                        end
                                        local repItemId = conflictGroupRepresentative[conflictGroup]
                                        if countItemId ~= repItemId then
                                            shouldSkipForGroup = true
                                        end
                                    end
                                end

                            else
                                shouldShow = not config.showOnlyAvailable or count > 0 or hasBuff
                            end

                        else
                            if config.hideWhenActive and hasBuff and timeRemaining > (config.showBeforeExpiry or 60) then
                                shouldShow = false
                            else
                                shouldShow = not config.showOnlyAvailable or count > 0 or hasBuff
                            end
                        end

                        if shouldShow and not shouldSkipForGroup then
                            consumableCount = consumableCount + 1
                            local cge = conflictGroup and conflictGroupExpiry[conflictGroup]
                            consumables[consumableCount] = {
                                itemId = itemId,
                                itemData = itemData,
                                count = count,
                                category = categoryKey,
                                hasBuff = hasBuff,
                                timeRemaining = timeRemaining,
                                isGroupedConflictButton = (config.groupConflictButtons and conflictGroup ~= nil),
                                conflictGroup = conflictGroup,
                                hasConflictBuff = cge and cge.hasGroupBuff or false,
                                conflictTime = cge and cge.groupTime or 0,
                                conflictItemId = cge and cge.groupItemId or nil,
                            }
                        end
                end
            end
        end

        if config.showBagWeapons then
            local bagWeapons = self:ScanBagWeapons()
            local selectedStone = self:GetValidStoneType()
            local displayStone = selectedStone
            local stoneCount = GetCachedItemCount(displayStone)

            self:DebugPrint(string.format(RCL["BAG WEAPONS: selectedStone=%d, stoneCount=%d, found=%d"],
                selectedStone, stoneCount, #bagWeapons), "items")

            if #bagWeapons > 0 then
                for i, weapon in ipairs(bagWeapons) do
                    local hasEnchant, enchantTime = self:HasBagWeaponEnchant(weapon.bag, weapon.slot)

                    self:DebugPrint(string.format(RCL["  Bag weapon: %s (bag %d slot %d) enchant=%s time=%d"],
                        weapon.itemName or RCL["unknown"], weapon.bag, weapon.slot, tostring(hasEnchant), enchantTime or 0), "items")

                    -- bag 0-4 and slot 1-99 pack into a unique id below the
                    -- 999900 unified-button range and above any real itemId.
                    local bagWeaponId = 900000 + (weapon.bag * 100) + weapon.slot

                    if not (config.hiddenWeapons and weapon.itemId and config.hiddenWeapons[weapon.itemId]) then
                        consumableCount = consumableCount + 1
                        consumables[consumableCount] = {
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
        end

        local customOrder = self.db.consumablesHelper and self.db.consumablesHelper.itemOrder or {}
        local customOrderLookup = {}
        for i, itemId in ipairs(customOrder) do
            customOrderLookup[itemId] = i
        end
        local hasCustomOrder = #customOrder > 0

        -- Custom order is stored by base item id, so synthetic ids need a
        -- stand-in: every bag weapon collapses to one 999903 key so the
        -- whole bag group orders as a unit.
        local function getSortKey(item)
            local id = item.itemId
            if id == 999901 or id == 999902 then return id end
            if id >= 900000 and id < 999900 then return 999903 end
            return item.itemData.baseItemId or id
        end

        -- Precedence: user order, category order, conflict-group items
        -- ahead of loose ones, then name. Mainhand precedes offhand.
        table.sort(consumables, function(a, b)
            local aBaseId = getSortKey(a)
            local bBaseId = getSortKey(b)

            if hasCustomOrder then
                local aCustom = customOrderLookup[aBaseId]
                local bCustom = customOrderLookup[bBaseId]

                if aCustom and not bCustom then
                    return true
                elseif not aCustom and bCustom then
                    return false
                elseif aCustom and bCustom then
                    return aCustom < bCustom
                end
            end

            local aCatOrder = categoryOrder[a.category] or 99
            local bCatOrder = categoryOrder[b.category] or 99

            if aCatOrder ~= bCatOrder then
                return aCatOrder < bCatOrder
            end

            local aConflictGroup = a.conflictGroup
            local bConflictGroup = b.conflictGroup

            local aHasConflict = (aConflictGroup ~= nil)
            local bHasConflict = (bConflictGroup ~= nil)

            if aHasConflict and not bHasConflict then
                return true
            elseif not aHasConflict and bHasConflict then
                return false
            elseif aHasConflict and bHasConflict then
                local aGroupKey = conflictGroupSortKey[aConflictGroup] or 99
                local bGroupKey = conflictGroupSortKey[bConflictGroup] or 99

                if aGroupKey ~= bGroupKey then
                    return aGroupKey < bGroupKey
                end

                return a.itemData.name < b.itemData.name
            end

            if aBaseId ~= bBaseId then
                return a.itemData.name < b.itemData.name
            end

            local aSlot = a.itemData.slot or "none"
            local bSlot = b.itemData.slot or "none"

            if aSlot == "mainhand" and bSlot == "offhand" then
                return true
            elseif aSlot == "offhand" and bSlot == "mainhand" then
                return false
            end

            return a.itemData.name < b.itemData.name
        end)

        -- Drops raw stones and oils: they arrive via category data but are
        -- only applied through the weapon slot buttons, so a standalone
        -- button would duplicate one.
        self.consumablesHelper.sortedOrder = {}
        do
            local w = 0
            for i = 1, consumableCount do
                local e = consumables[i]
                local bid = e and e.itemId
                local isEnh = (bid and RC.weaponStoneIds[bid])
                    or (bid and RC.IsWeaponOilItem and RC:IsWeaponOilItem(bid))
                if e and not isEnh then
                    w = w + 1
                    consumables[w] = e
                end
            end
            for i = w + 1, consumableCount do consumables[i] = nil end
            consumableCount = w
        end

        for i, item in ipairs(consumables) do
            self.consumablesHelper.sortedOrder[item.itemId] = i

            local existingButton = self.consumablesHelper.buttons[item.itemId]
            if not existingButton or not existingButton.fullyInitialized then
                self.consumablesHelper.buttons[item.itemId] = self:CreateConsumableButton(item.itemId, item.itemData, i, item.category, false)
                existingButton = self.consumablesHelper.buttons[item.itemId]
            else
                existingButton.itemData = item.itemData
                existingButton.hasBuff = item.hasBuff
                existingButton.timeRemaining = item.timeRemaining
                existingButton.sortIndex = i

                if item.itemData.isBagWeapon and item.itemData.weaponTexture then
                    if existingButton.icon then
                        existingButton.icon:SetTexture(item.itemData.weaponTexture)
                    end
                    if existingButton.nameLabel then
                        existingButton.nameLabel:SetText(item.itemData.name or RCL["Weapon"])
                    end
                elseif item.itemData.isUnifiedWeaponButton then
                    -- A pooled MH/OH button kept the weapon it was built
                    -- with, so after a swap both could show the same one.
                    self:RefreshUnifiedWeaponIcon(existingButton)
                end

                existingButton:Show()
            end

            if item.conflictGroup and item.isGroupedConflictButton then
                existingButton.conflictGroup = item.conflictGroup
                existingButton.isGroupedConflictButton = true

                -- Hook once per button lifetime: HookScript stacks, so
                -- re-hooking every rebuild would open N pickers per click.
                if not existingButton.conflictGroupClickHooked then
                    existingButton.conflictGroupClickHooked = true
                    existingButton:HookScript("OnMouseUp", function(btn, mouseButton)
                        if mouseButton == "RightButton" and not InCombatLockdown() then
                            if btn.conflictGroup and btn.isGroupedConflictButton then
                                RC:ShowConflictGroupPicker(btn, btn.conflictGroup)
                            end
                        end
                    end)
                end
            end
        end

        local activeIds = {}
        for _, item in ipairs(consumables) do
            activeIds[item.itemId] = true
        end
        for itemId, button in pairs(self.consumablesHelper.buttons) do
            if button and button.fullyInitialized and not activeIds[itemId] then
                button:Hide()
            end
        end

        self.consumablesHelper.isRebuilding = false
        self:UpdateConsumablesHelperTitleVisibility()
        self.performanceCache.buttonGridDirty = true

        if self.consumablesHelper.persistentItemCountCache then
            self.consumablesHelper.itemCountCache = self.consumablesHelper.persistentItemCountCache
            self.consumablesHelper.itemCountCacheTime = now
        end

        local size    = config.buttonSize or 36
        local spacing = config.iconSpacing or 4
        local perRow  = config.buttonsPerRow or 2
        local growDir = config.growDirection or "DOWN"

        local showCount = config.showCount ~= false
        local topOffset = -5
        self:IsEating()  -- warms the eating cache for UpdateButtonStates below
        local visibleIndex = 0
        local nextThresholdEventTime = nil

        for i = 1, consumableCount do
            local item = consumables[i]
            local button = self.consumablesHelper.buttons[item.itemId]
            if button and button.fullyInitialized then
                local shouldBeVisible = true
                if config.hideWhenActive and item.hasBuff and item.timeRemaining > threshold then
                    shouldBeVisible = false
                elseif config.hideConflictingBuffs and item.hasConflictBuff and item.conflictItemId ~= item.itemId then
                    if item.conflictTime > threshold then shouldBeVisible = false end
                end

                if shouldBeVisible then
                    visibleIndex = visibleIndex + 1

                    -- PROTECTED: layout of a secure button (ClearAllPoints,
                    -- SetPoint, Show) is combat-forbidden. The text/icon
                    -- updates below are not, so they stay outside this guard
                    -- and the bar keeps counting down during a lockdown.
                    if not InCombatLockdown() then
                        local row, col
                        if growDir == "DOWN" then
                            row = math_floor((visibleIndex - 1) / perRow)
                            col = (visibleIndex - 1) % perRow
                        else
                            col = math_floor((visibleIndex - 1) / perRow)
                            row = (visibleIndex - 1) % perRow
                        end
                        local xPos = 5 + (col * (size + spacing))
                        local yPos = topOffset - (row * (size + spacing))
                        if button._lastXPos ~= xPos or button._lastYPos ~= yPos then
                            button:ClearAllPoints()
                            button:SetPoint("TOPLEFT", self.consumablesHelper.frame, "TOPLEFT", xPos, yPos)
                            button._lastXPos = xPos
                            button._lastYPos = yPos
                        end
                        button.gridRow = row
                        button.gridCol = col
                        if not button:IsShown() then button:Show() end
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
                        local newText = item.count > 0 and tostring(item.count) or "0"
                        local needsColorUpdate = false
                        if button.count._cachedText ~= newText then
                            button.count:SetText(newText)
                            button.count._cachedText = newText
                            needsColorUpdate = true
                        end
                        if needsColorUpdate or not button.count._cachedColorKey then
                            if item.count > 0 then
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

                    ApplyButtonStateColors(button, item.count, item.hasBuff,
                        item.hasConflictBuff, item.conflictItemId, item.itemId)

                    UpdateWeaponTimeLabel(button, item.hasBuff, item.timeRemaining, threshold)

                    UpdateExpiryGlow(button, item.hasBuff, item.timeRemaining, threshold, now_t)

                    -- Earliest moment any buff crosses the threshold; the
                    -- refresh path skips its whole body until then.
                    if item.hasBuff and item.timeRemaining > threshold then
                        local crossTime = now_t + item.timeRemaining - threshold
                        if not nextThresholdEventTime or crossTime < nextThresholdEventTime then
                            nextThresholdEventTime = crossTime
                        end
                    end

                else
                    if not InCombatLockdown() then button:Hide() end
                end
            end
        end

        local visibleCount = visibleIndex
        self.consumablesHelper.lastVisibleCount = visibleCount
        self.consumablesHelper.lastTotalCount = visibleCount
        ResizeBarFrame(self.consumablesHelper.frame, self.db.consumablesHelper,
            visibleCount, size, spacing, perRow, growDir)

        if not InCombatLockdown() and self:ShouldShowConsumablesBar() then
            self:ShowBarFrame("consumablesHelper")
        end

        -- Publish the epochs this rebuild rendered from; a following
        -- refresh returns immediately if neither snapshot has moved.
        self.consumablesHelper._nextThresholdEventTime = nextThresholdEventTime
        self.consumablesHelper._lastRefreshEpoch = {
            buffEpoch = self.consumablesHelper.buffCacheTime or 0,
            bagEpoch  = self.consumablesHelper.itemCountCacheTime or 0,
        }

        if self.UpdateButtonStates and self.consumablesHelper.frame and self.consumablesHelper.frame:IsShown() then
            self:UpdateButtonStates()
        end

        if RC.Profiler then RC.Profiler:StopTiming("ConsumRebuild") end
    end

    -- Unhides every potion-bar item by writing false, never by clearing the
    -- key or replacing the table. RC.defaults.potionsBar.hiddenItems ships
    -- a handful of items hidden (the food/drink additions), and Core_Init's
    -- FillMissing re-seeds any key that is *missing* from the saved profile
    -- on every login - so a nil'd key silently came back hidden next login
    -- while an explicit false survives.
    function RC:ShowAllPotionBarItems()
        if not self.db or not self.db.potionsBar then return end
        local hidden = self.db.potionsBar.hiddenItems or {}
        for itemId in pairs(hidden) do
            hidden[itemId] = false
        end
        local defaultHidden = RC.defaults and RC.defaults.potionsBar
            and RC.defaults.potionsBar.hiddenItems
        if defaultHidden then
            for itemId in pairs(defaultHidden) do
                hidden[itemId] = false
            end
        end
        self.db.potionsBar.hiddenItems = hidden
    end

    -- Potions-bar rebuild: no conflict groups, weapon buttons or synthetic
    -- ids. Retries up to 10 times with a rising delay, since the item data
    -- files may still be loading at first call.
    function RC:UpdatePotionsButtons()
        if not self.raidConsumables or not self.potionBarItems then
            if not self.potionsBar.retryCount then
                self.potionsBar.retryCount = 0
            end

            self.potionsBar.retryCount = self.potionsBar.retryCount + 1

            if self.debugCategories and self.debugCategories.items and self.debugCategories.items.enabled then
                self:DebugPrint(string.format(RCL[" UpdatePotionsButtons retry #%d - waiting for data (raidConsumables: %s, potionBarItems: %s)"],
                    self.potionsBar.retryCount,
                    tostring(self.raidConsumables ~= nil),
                    tostring(self.potionBarItems ~= nil)), "items")
            end

            if self.potionsBar.retryCount < 10 then
                local delay = math.min(0.5 * self.potionsBar.retryCount, 3)
                C_Timer.After(delay, function()
                    if self and self.UpdatePotionsButtons then
                        self:UpdatePotionsButtons()
                    end
                end)
            else
                self:Print(RCL["ERROR: Failed to load potion bar data. Please /reload"])
            end
            return
        end

        self.potionsBar.retryCount = 0

        -- Secure buttons: nothing moves in combat. The bar's combat-end
        -- handler re-decides visibility, which rebuilds it. (This used to
        -- start a 1s retry loop per call, so every potion drunk in a long
        -- fight added another loop and they all rebuilt at the end.)
        if not self.potionsBar or not self.potionsBar.frame or not self.db.potionsBar or InCombatLockdown() then
            return
        end

        if not self:ShouldShowPotionsBar() then
            self:HideBarFrame("potionsBar")
            return
        end

        self.potionsBar.isRebuilding = true

        local config = self.db.potionsBar
        local size = config.buttonSize or 36

        for itemId, button in pairs(self.potionsBar.buttons) do
            button:Hide()
            self:EnsureButtonTextElements(button, config, size)
        end

        local potions = {}
        local potionCount = 0

        if not self.db.potionsBar.hiddenItems then
            self.db.potionsBar.hiddenItems = {}
        end

        local itemCountCache = self:RefreshBagItemCountCache()
        self.potionsBar._bagVersion = RC.Bags:Version()

        for _, categoryKey in ipairs(self.consumablesHelper.categories) do
            local category = self.raidConsumables[categoryKey]
            if category then
                for itemId, itemData in pairs(category.items) do
                    if self.potionBarItems[itemId] and not self.db.potionsBar.hiddenItems[itemId] then
                        local countItemId = itemData.baseItemId or itemId
                        local count = itemCountCache[countItemId] or 0
                        local hasBuff, timeRemaining = self:HasConsumableBuff(countItemId)

                        local shouldShow = not self.db.potionsBar.showOnlyAvailable or count > 0 or hasBuff

                        if shouldShow then
                            potionCount = potionCount + 1
                            potions[potionCount] = {
                                itemId = itemId,
                                itemData = itemData,
                                count = count,
                                category = categoryKey,
                                hasBuff = hasBuff,
                                timeRemaining = timeRemaining
                            }
                        end
                    end
                end
            end
        end

        local potionCustom = self.db.potionsBar.customItems
        if potionCustom then
            for itemId, itemData in pairs(potionCustom) do
                if not self.db.potionsBar.hiddenItems[itemId] then
                    local countItemId = itemData.baseItemId or itemId
                    local count = itemCountCache[countItemId] or 0
                    local hasBuff, timeRemaining = self:HasConsumableBuff(countItemId)
                    local shouldShow = not self.db.potionsBar.showOnlyAvailable or count > 0 or hasBuff
                    if shouldShow then
                        potionCount = potionCount + 1
                        potions[potionCount] = {
                            itemId   = itemId,
                            itemData = itemData,
                            count    = count,
                            category = itemData.category or "custom",
                            hasBuff  = hasBuff,
                            timeRemaining = timeRemaining,
                        }
                    end
                end
            end
        end

        local potionOrder = (self.db.potionsBar and self.db.potionsBar.itemOrder) or {}
        local potionOrderLookup = {}
        for i, oid in ipairs(potionOrder) do
            potionOrderLookup[oid] = i
        end
        local hasPotionOrder = #potionOrder > 0
        table.sort(potions, function(a, b)
            if hasPotionOrder then
                local aId = a.itemData.baseItemId or a.itemId
                local bId = b.itemData.baseItemId or b.itemId
                local aO = potionOrderLookup[aId]
                local bO = potionOrderLookup[bId]
                if aO and not bO then return true end
                if bO and not aO then return false end
                if aO and bO then return aO < bO end
            end
            return a.itemData.name < b.itemData.name
        end)

        local _dbgItems = self.debugCategories and self.debugCategories.items and self.debugCategories.items.enabled

        self.potionsBar.sortedOrder = {}
        for i, item in ipairs(potions) do
            self.potionsBar.sortedOrder[item.itemId] = i

            local existingButton = self.potionsBar.buttons[item.itemId]
            if not existingButton or not existingButton.fullyInitialized then
                self.potionsBar.buttons[item.itemId] = self:CreateConsumableButton(item.itemId, item.itemData, i, item.category, true)

                if _dbgItems then
                    self:DebugPrint(string.format(RCL[" Created potion button for %s (ID: %d)"], item.itemData.name, item.itemId), "items")
                end
            else
                existingButton.itemData = item.itemData
                existingButton.hasBuff = item.hasBuff
                existingButton.timeRemaining = item.timeRemaining
                existingButton.sortIndex = i
                existingButton:Show()

                if _dbgItems then
                    self:DebugPrint(string.format(RCL[" Reusing existing button for %s (ID: %d)"], item.itemData.name, item.itemId), "items")
                end
            end
        end

        if _dbgItems then
            local btnCount = 0
            for _ in pairs(self.potionsBar.buttons) do btnCount = btnCount + 1 end
            self:DebugPrint(string.format(RCL[" UpdatePotionsButtons complete - found %d potions, %d buttons in table"],
                potionCount, btnCount), "items")
        end

        local config = self.db.potionsBar
        local size = config.buttonSize or 36
        local spacing = config.iconSpacing or 4
        local perRow = config.buttonsPerRow or 2
        local growDir = config.growDirection or "DOWN"

        local contentHeight
        if growDir == "DOWN" then
            local rows = math_ceil(potionCount / perRow)
            contentHeight = rows * size + (rows - 1) * spacing
        else
            contentHeight = math_min(potionCount, perRow) * size + (math_min(potionCount, perRow) - 1) * spacing
        end

        local sidePadding = 5
        local topPadding = 5
        local bottomPadding = 5

        local width, height
        if growDir == "DOWN" then
            local cols = math_min(potionCount, perRow)
            local contentWidth = cols * size + (cols - 1) * spacing
            width = sidePadding + contentWidth + sidePadding
            height = topPadding + contentHeight + bottomPadding
        else
            local cols = math_ceil(potionCount / perRow)
            local contentWidth = cols * size + (cols - 1) * spacing
            width = sidePadding + contentWidth + sidePadding
            height = topPadding + contentHeight + bottomPadding
        end

        if not InCombatLockdown() then
            SmoothSetSize(self.potionsBar.frame, width, height)
            RC.Position.RestoreFrame(self.potionsBar.frame)
        end
        self:UpdatePotionsBarTitleVisibility()

        self.potionsBar.isRebuilding = false

        self.performanceCache.buttonGridDirty = true

        self:RefreshPotionsDisplay()
    end

    -- 1.0s maintenance ticker only - this sweeps the entire item db, so it
    -- must never be reached inline from an event. Two jobs: re-show a buff
    -- that dropped below threshold while its button was hidden, and drive
    -- TTS for items with no visible button at all.
    function RC:CheckConsumablesThreshold()
        if self.consumablesHelper.isRebuilding or not self.consumablesHelper.frame then
            return
        end

        if not self.db.consumablesHelper.enabled or not self:ShouldShowConsumablesBar() then
            return
        end

        local threshold = self.db.consumablesHelper.showBeforeExpiry or 60

        if self.consumablesHelper.buttons and next(self.consumablesHelper.buttons) then
            local qualifying = {}

            -- consumableConflictGroups values are sets keyed by itemId
            -- (see GetConflictGroup / HasConflictGroupBuff, which use
            -- pairs the same way).
            if self.consumableConflictGroups then
                for _, groupItems in pairs(self.consumableConflictGroups) do
                    for itemId in pairs(groupItems) do
                        local hasBuff, timeRemaining = self:HasConsumableBuff(itemId)
                        if hasBuff and timeRemaining > 0 and timeRemaining <= threshold then
                            local button = self.consumablesHelper.buttons[itemId]
                            if not button or not button:IsShown() then
                                qualifying[itemId] = true
                            end
                        end
                    end
                end
            end

            if self.db.consumablesHelper.hideWhenActive then
                for _, category in pairs(self.raidConsumables or {}) do
                    if category.items then
                        for itemId, itemData in pairs(category.items) do
                            local buffId    = itemData.buffId
                            local enchantId = itemData.enchantId
                            if buffId or enchantId then
                                -- Oils carry enchantId and need the strict
                                -- reader; the loose one would report a
                                -- stone's enchant as this oil's own.
                                local hasBuff, timeRemaining
                                if enchantId then
                                    hasBuff, timeRemaining = self:HasOwnWeaponEnchant(itemId, "mainhand", enchantId)
                                else
                                    hasBuff, timeRemaining = self:HasConsumableBuff(itemId)
                                end
                                if hasBuff and timeRemaining > 0 and timeRemaining <= threshold then
                                    if not self.consumablesHelper.sortedOrder[itemId] then
                                        qualifying[itemId] = true
                                    end
                                end
                            end
                        end
                    end
                end
            end

            -- Edge-triggered. Without the latch every 1.0s tick would
            -- re-trigger a full rebuild for the whole minute a buff spends
            -- inside the threshold.
            local prevLatch = self.consumablesHelper._expiryShowLatch
            local triggerRebuild = false
            for itemId in pairs(qualifying) do
                if not (prevLatch and prevLatch[itemId]) then
                    triggerRebuild = true
                    break
                end
            end
            self.consumablesHelper._expiryShowLatch = qualifying

            if triggerRebuild and not InCombatLockdown() then
                self:UpdateConsumablesButtons()
            end
        end

    end

    -- Text-only pass: no layout, visibility or secure attribute changes, so
    -- it is safe under combat lockdown. Run from the 1.0s ticker only when
    -- some button is actually showing an expiry.
    function RC:UpdateConsumablesTimers()
        if not self.consumablesHelper or not self.consumablesHelper.buttons then
            return
        end

        local config = self.db.consumablesHelper
        local now = GetTime()

        for itemId, button in pairs(self.consumablesHelper.buttons) do
            if button and button:IsShown() and button.fullyInitialized then
                local itemData = button.itemData
                local countItemId = itemData.baseItemId or itemId

                -- Order matters: bag weapon, then slot buttons passing the
                -- canonical "mainhand"/"offhand" through untouched, then
                -- the strict per-oil reader, then plain auras.
                local hasBuff, timeRemaining
                if itemData.isBagWeapon then
                    hasBuff, timeRemaining = self:HasBagWeaponEnchant(itemData.bagSlot, itemData.bagPosition)
                elseif itemData.slot == "mainhand" or itemData.slot == "offhand" then
                    hasBuff, timeRemaining = self:HasWeaponEnchant(countItemId, itemData.slot)
                elseif itemData.enchantId then
                    hasBuff, timeRemaining = self:HasOwnWeaponEnchant(countItemId, "mainhand", itemData.enchantId)
                else
                    hasBuff, timeRemaining = self:HasConsumableBuff(countItemId)
                end

                local hasConflictBuff, conflictTime = false, 0
                local conflictGroup = self:TimerConflictGroup(countItemId)
                if conflictGroup then
                    local _cId
                    hasConflictBuff, conflictTime, _cId = self:HasConflictGroupBuff(conflictGroup)
                end
                local displayTime = (hasBuff and timeRemaining) or (hasConflictBuff and conflictTime) or 0

                if button.expiryText and displayTime > 0 and displayTime <= config.showBeforeExpiry then
                    local seconds = math_ceil(displayTime)
                    local newText = string_format("%d", seconds)
                    if button.expiryText._cachedText ~= newText then
                        button.expiryText:SetText(newText)
                        button.expiryText._cachedText = newText
                    end

                    local redCutoff = (config.showBeforeExpiry or 60) * 0.5
                    local colorKey = displayTime < redCutoff and "red" or "gold"
                    if button.expiryText._cachedColorKey ~= colorKey then
                        if displayTime < redCutoff then
                            RC.BarStyle.Paint(button.expiryText, button, "expiryUrgentColor")
                        else
                            RC.BarStyle.Paint(button.expiryText, button, "expirySoonColor")
                        end
                        button.expiryText._cachedColorKey = colorKey
                    end
                elseif button.expiryText and button.expiryText:IsShown() then
                    button.expiryText:Hide()
                    button.expiryText._cachedText = nil
                    button.expiryText._cachedColorKey = nil
                end

                if button.timeLabel and button.timeLabel:IsShown() and hasBuff and timeRemaining and timeRemaining > 0 then
                    local timeStr
                    if timeRemaining >= 3600 then
                        timeStr = tostring(math_floor(timeRemaining / 3600))
                    else
                        timeStr = tostring(math_ceil(timeRemaining / 60))
                    end

                    if button.timeLabel._cachedText ~= timeStr then
                        button.timeLabel:SetText(timeStr)
                        button.timeLabel._cachedText = timeStr
                    end
                end

                -- the glow animates itself (RC.Motion); this only picks a
                -- loop back up after its bar was hidden
                if button.expiryGlowFrame and button.expiryGlowFrame:IsShown() then
                    RC:SetBarButtonGlow(button, true)
                end
            end
        end
    end

    -- The cheap path: re-evaluates visibility, colours and timers over the
    -- buttons a rebuild already created, creating and sorting nothing.
    -- Three successive early-outs precede any real work: the in-combat
    -- throttle, the conflict-group re-show check, and the epoch skip.
    function RC:RefreshConsumablesDisplay()
        if self.consumablesHelper.isRebuilding or not self.consumablesHelper.frame then
            return
        end

        if not self.db.consumablesHelper.enabled then
            return
        end

        if not self:ShouldShowConsumablesBar() then
            if not InCombatLockdown() then
                self:HideBarFrame("consumablesHelper")
            end
            return
        end

        -- Hard 0.5s floor in combat regardless of caller frequency.
        if InCombatLockdown() then
            local now = GetTime()
            if now - (self.consumablesHelper.updateThrottle or 0) < 0.5 then
                return
            end
            self.consumablesHelper.updateThrottle = now
        end

        local threshold = self.db.consumablesHelper.showBeforeExpiry or 60
        -- A conflict-group buff that dropped inside the threshold with no
        -- visible button needs a full rebuild, not a refresh. groupItems is
        -- a set keyed by itemId, hence pairs (same as
        -- CheckConsumablesThreshold).
        if self.consumablesHelper.buttons and next(self.consumablesHelper.buttons) and self.consumableConflictGroups then
            for groupName, groupItems in pairs(self.consumableConflictGroups) do
                for itemId in pairs(groupItems) do
                    local hasBuff, timeRemaining = self:HasConsumableBuff(itemId)
                    if hasBuff and timeRemaining > 0 and timeRemaining <= threshold then
                        local button = self.consumablesHelper.buttons[itemId]
                        if not button or not button:IsShown() then
                            if not InCombatLockdown() then
                                self:UpdateConsumablesButtons()
                            end
                            return
                        end
                    end
                end
            end
        end

        if RC.Profiler then RC.Profiler:StartTiming("ConsumRefresh") end

        local now = GetTime()
        local useCache = false
        local itemCountCache = nil
        if self.consumablesHelper.itemCountCache and self.consumablesHelper.itemCountCacheTime then
            if (now - self.consumablesHelper.itemCountCacheTime) < 1.0 then
                useCache = true
                itemCountCache = self.consumablesHelper.itemCountCache
            end
        end

        -- Epoch skip. The aura and bag caches carry the timestamp of their
        -- last real refresh; if neither moved since the last render, and no
        -- buff has crossed the expiry threshold in between, nothing on
        -- screen can differ and the whole body is skipped.
        local buffEpoch = self.consumablesHelper.buffCacheTime or self.performanceCache.allBuffsCacheTime or 0
        local bagEpoch  = self.consumablesHelper.itemCountCacheTime or 0
        local lastRefresh = self.consumablesHelper._lastRefreshEpoch
        local canSkip = lastRefresh and
                        lastRefresh.buffEpoch == buffEpoch and
                        lastRefresh.bagEpoch  == bagEpoch

        if canSkip then
            local threshold = self.db.consumablesHelper.showBeforeExpiry or 60
            local nextThreshold = self.consumablesHelper._nextThresholdEventTime
            if nextThreshold and now >= nextThreshold then
                canSkip = false
            end
        end

        if canSkip then
            if RC.Profiler then RC.Profiler:StopTiming("ConsumRefresh") end
            return
        end
        self.consumablesHelper._lastRefreshEpoch = { buffEpoch = buffEpoch, bagEpoch = bagEpoch }

        local function GetItemCountCached(itemId)
            if useCache then
                return itemCountCache[itemId] or 0
            else
                return GetItemCount(itemId)
            end
        end

        self:IsEating()  -- warms the eating cache for the passes below
        local config = self.db.consumablesHelper

        local allBuffs = self:SnapshotAllBuffs()

        -- Primes both slots of the weapon-enchant cache with one API call so
        -- the per-button readers below all hit it. Result discarded.
        self:HasWeaponEnchant(nil, "mainhand")

        -- Per-refresh memo: resolve each conflict group once, then reuse.
        local conflictGroupStates = {}
        local checkedGroups = {}

        local visibleButtons = {}
        local visibleCount = 0

        -- sortedOrder is the rebuild's authoritative list. A pooled button
        -- missing from it is hidden, never destroyed, so it stays reusable.
        for itemId, button in pairs(self.consumablesHelper.buttons) do
            if button and button.fullyInitialized then
                if not self.consumablesHelper.sortedOrder[itemId] then
                    if not InCombatLockdown() then button:Hide() end
                else
                local itemData = button.itemData
                local countItemId = itemData.baseItemId or itemId
                local count = GetItemCountCached(countItemId)

                local buffId = self:GetConsumableBuffId(countItemId)
                local buffData = buffId and self:ResolveConsumableBuff(allBuffs, buffId)
                local hasBuff = buffData ~= nil
                local timeRemaining = buffData and buffData.expirationTime and buffData.expirationTime > 0
                    and (buffData.expirationTime - now) or 0

                if itemData.isBagWeapon then
                    hasBuff, timeRemaining = self:HasBagWeaponEnchant(itemData.bagSlot, itemData.bagPosition)
                elseif itemData.slot == "mainhand" or itemData.slot == "offhand" then
                    hasBuff, timeRemaining = self:HasWeaponEnchant(countItemId, itemData.slot)
                elseif itemData.enchantId then
                    hasBuff, timeRemaining = self:HasOwnWeaponEnchant(countItemId, "mainhand", itemData.enchantId)
                end

                local conflictGroup = self:TimerConflictGroup(countItemId)
                local hasConflictBuff, conflictTime, conflictItemId = false, 0, nil
                if conflictGroup then
                    if not checkedGroups[conflictGroup] then
                        hasConflictBuff, conflictTime, conflictItemId = self:HasConflictGroupBuff(conflictGroup)
                        conflictGroupStates[conflictGroup] = {
                            hasConflict = hasConflictBuff,
                            time = conflictTime,
                            itemId = conflictItemId
                        }
                        checkedGroups[conflictGroup] = true
                    else
                        local cached = conflictGroupStates[conflictGroup]
                        hasConflictBuff = cached.hasConflict
                        conflictTime = cached.time
                        conflictItemId = cached.itemId
                    end
                end

                local shouldBeVisible = false

                local hiddenByConflictGroup = false
                if config.groupConflictButtons and conflictGroup then
                    local prefs = config.conflictGroupPreferences or {}
                    local preferredItem = prefs[conflictGroup]
                    local repItemId = nil

                    if preferredItem and GetItemCountCached(preferredItem) > 0 then
                        repItemId = preferredItem
                    else
                        local priority = self.conflictGroupPriority and self.conflictGroupPriority[conflictGroup]
                        if priority then
                            for _, groupItemId in ipairs(priority) do
                                if GetItemCountCached(groupItemId) > 0 then
                                    repItemId = groupItemId
                                    break
                                end
                            end
                        end
                        if not repItemId then
                            repItemId = preferredItem or (priority and priority[1])
                        end
                    end

                    if repItemId and countItemId ~= repItemId then
                        hiddenByConflictGroup = true
                    end
                end

                -- Ladder, first match wins: user-hidden, collapsed into a
                -- group representative, bag weapon (always shown - a slot
                -- tracker, not stock), then availability and buff rules.
                if config.hiddenItems and config.hiddenItems[itemId] then
                    shouldBeVisible = false

                elseif hiddenByConflictGroup then
                    shouldBeVisible = false

                elseif itemData.isBagWeapon then
                    shouldBeVisible = true

                elseif count == 0 and not hasBuff then
                    shouldBeVisible = not config.showOnlyAvailable

                else
                    shouldBeVisible = true

                    if config.hideWhenActive and hasBuff and timeRemaining > config.showBeforeExpiry then
                        shouldBeVisible = false

                    elseif config.hideConflictingBuffs and hasConflictBuff and conflictItemId ~= itemId then
                        if conflictTime > config.showBeforeExpiry then
                            shouldBeVisible = false
                        end
                    end
                end

                if shouldBeVisible then
                    visibleCount = visibleCount + 1
                    visibleButtons[visibleCount] = {
                        button = button,
                        itemId = itemId,
                        count = count,
                        hasBuff = hasBuff,
                        timeRemaining = timeRemaining,
                        hasConflictBuff = hasConflictBuff,
                        conflictTime = conflictTime,
                        conflictItemId = conflictItemId,
                        sortIndex = self.consumablesHelper.sortedOrder[itemId] or 999
                    }
                else
                    -- PROTECTED: Only hide buttons outside of combat to prevent taint
                    if not InCombatLockdown() then
                        button:Hide()
                    end
                end
                end
            end
        end

        if visibleCount == 0 then
            if self.consumablesHelper.placeholder then
                self.consumablesHelper.placeholder:Show()
            end
        else
            self.consumablesHelper.initializing = false

            if self.consumablesHelper.placeholder then
                self.consumablesHelper.placeholder:Hide()
            end

            table.sort(visibleButtons, function(a, b)
                return a.sortIndex < b.sortIndex
            end)
        end

        if visibleCount > 0 then

        local size = config.buttonSize or 36
        local spacing = config.iconSpacing or 4
        local perRow = config.buttonsPerRow or 2
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
                if button._lastXPos ~= xPos or button._lastYPos ~= yPos then
                    button:ClearAllPoints()
                    button:SetPoint("TOPLEFT", self.consumablesHelper.frame, "TOPLEFT", xPos, yPos)
                    button._lastXPos = xPos
                    button._lastYPos = yPos
                end

                button.gridRow = row
                button.gridCol = col

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

            ApplyButtonStateColors(button, data.count, data.hasBuff,
                data.hasConflictBuff, data.conflictItemId, data.itemId)

            UpdateWeaponTimeLabel(button, data.hasBuff, data.timeRemaining,
                config.showBeforeExpiry or 60)

            UpdateExpiryGlow(button, data.hasBuff, data.timeRemaining,
                config.showBeforeExpiry or 60, now)
        end

		self.consumablesHelper.lastVisibleCount = visibleCount
		self.consumablesHelper.lastTotalCount = visibleCount

		ResizeBarFrame(self.consumablesHelper.frame, self.db.consumablesHelper,
			visibleCount, size, spacing, perRow, growDir)
        end

        if not InCombatLockdown() and self:ShouldShowConsumablesBar() then
            self:ShowBarFrame("consumablesHelper")
        end

        -- Recompute the next threshold crossing to give the epoch skip a
        -- wake-up time; without it a refresh sleeps past a buff's warning.
        do
            local threshold = self.db.consumablesHelper.showBeforeExpiry or 60
            local buffCache = self.consumablesHelper.buffCache or self.performanceCache.allBuffs
            local nextEvent = nil
            for itemId, button in pairs(self.consumablesHelper.buttons) do
                if button and button.fullyInitialized then
                    local countItemId = (button.itemData and button.itemData.baseItemId) or itemId
                    local buffId = self._buffIdLookup[countItemId]
                    if buffId then
                        local buffData = self:ResolveConsumableBuff(buffCache, buffId)
                        if buffData and buffData.expirationTime and buffData.expirationTime > 0 then
                            local timeLeft = buffData.expirationTime - now
                            if timeLeft > threshold then
                                local crossTime = buffData.expirationTime - threshold
                                if not nextEvent or crossTime < nextEvent then
                                    nextEvent = crossTime
                                end
                            end
                        end
                    end
                end
            end
            self.consumablesHelper._nextThresholdEventTime = nextEvent
        end

        if RC.Profiler then RC.Profiler:StopTiming("ConsumRefresh") end
    end

end
