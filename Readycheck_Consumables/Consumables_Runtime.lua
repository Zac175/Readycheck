------------------------------------------------------------------------
-- Readycheck - Consumables Runtime
-- Creates the bar frames at init, owns the 0.2s cooldown ticker, and
-- handles the cooldown/cast events (through Consumables_Events).
-- Every high-frequency handler here obeys the performance law: it may
-- only throttle-and-start a ticker, never iterate buttons inline.
-- StartCooldownTicker is the guarded entry point - `if cooldownTicker
-- then return` makes repeat calls free, and the ticker stops itself once
-- no bar is visible and nothing is on cooldown.
------------------------------------------------------------------------
local WRF = _G.Readycheck
if not WRF then return end
WRF._chInit = WRF._chInit or {}
WRF._chs = WRF._chs or {}
WRF._chInit[#WRF._chInit + 1] = function()
    local RC = _G.Readycheck
    local GetTime = GetTime
    local InCombatLockdown = InCombatLockdown
    local UnitCastingInfo = UnitCastingInfo
    local UnitChannelInfo = UnitChannelInfo
    local pairs = pairs
    local type = type

    local _chs = WRF._chs

    -- Every bar whose buttons can show a cast swirl.
    local SWIRL_BARS = { "consumablesHelper", "potionsBar", "weaponsBar", "trinketBar" }
    local function AnyCastSwirl()
        for i = 1, #SWIRL_BARS do
            local bar = RC[SWIRL_BARS[i]]
            if bar and bar.frame and bar.frame:IsShown() and bar.buttons then
                for _, button in pairs(bar.buttons) do
                    if button.castFrame and button.castFrame:IsShown() then return true end
                end
            end
        end
        return false
    end

    function RC:FormatCooldownTime(seconds)
        if seconds >= 3600 then
            return string.format("%dh", math.floor(seconds / 3600))
        elseif seconds >= 60 then
            return string.format("%dm", math.floor(seconds / 60))
        else
            return string.format("%d", math.floor(seconds))
        end
    end

    function RC:UpdateTrinketBarButtonStates()
        if not self.trinketBar.buttons then return end
        if not self.trinketBar.frame or not self.trinketBar.frame:IsShown() then return end
        -- A swap is mid-flight (PredictTrinketBarEquip): the buttons already
        -- show where each trinket will be, but the slots still hold where
        -- they are, so cooldowns read now would land on the wrong button.
        -- Only for the hold itself - the record can outlive it (the bar is
        -- not rescanned in combat) and must not freeze the cooldowns then.
        local predicted = self.trinketBar.predicted
        if predicted and GetTime() < predicted.expires then return end

        local now = GetTime()
        local db = self.db.trinketBar


        for itemId, button in pairs(self.trinketBar.buttons) do
            if button:IsShown() and button.trinketData then
                local trinketData = button.trinketData
                local cooldownRemaining = 0
                local buffRemaining = 0

                local trinketBuffData = RC.trinketBuffs and RC.trinketBuffs[trinketData.itemId]
                local buffSpellId = trinketBuffData and trinketBuffData.buffId
                if not buffSpellId and RC.TrinketScanner and RC.TrinketScanner.autoDetectedTrinkets then
                    local scanned = RC.TrinketScanner.autoDetectedTrinkets[trinketData.itemId]
                    if scanned then buffSpellId = scanned.buffId or scanned.spellId end
                end
                if buffSpellId then
                    if RC.IsTrinketBuffActive and RC:IsTrinketBuffActive(trinketData.itemId) then
                        local expirationTime
                        for _, a in ipairs(RC.Auras:Buffs()) do
                            if a.spellId == buffSpellId and a.expirationTime > 0 then
                                expirationTime = a.expirationTime
                            end
                        end
                        if expirationTime and expirationTime > 0 then
                            buffRemaining = expirationTime - now
                            if buffRemaining < 0 then buffRemaining = 0 end
                        end
                    end
                end

                -- Classic Era: no GetItemCooldown(itemId). Equipped reads
                -- GetInventoryItemCooldown(unit, slot), carried reads
                -- C_Container.GetContainerItemCooldown(bag, slot).
                -- duration > 1.5 rejects the GCD.
                local start, duration
                if trinketData.equipped then
                    start, duration = GetInventoryItemCooldown("player", trinketData.slotIndex)
                    if start and start > 0 and duration > 1.5 then
                        cooldownRemaining = (start + duration) - now
                        if cooldownRemaining < 0 then cooldownRemaining = 0 end
                    end
                elseif trinketData.bag and trinketData.slot then
                    start, duration = C_Container.GetContainerItemCooldown(trinketData.bag, trinketData.slot)
                    if start and start > 0 and duration > 1.5 then
                        cooldownRemaining = (start + duration) - now
                        if cooldownRemaining < 0 then cooldownRemaining = 0 end
                    end
                end

                if db.showCooldownText then
                    if buffRemaining > 0 then
                        if button.buffDurationText then
                            button.buffDurationText:SetText(self:FormatCooldownTime(buffRemaining))
                            if self:ShouldShowOwnCooldownText() then button.buffDurationText:Show() else button.buffDurationText:Hide() end
                        end
                        if button.cooldownText then
                            button.cooldownText:SetText("")
                            button.cooldownText:Hide()
                        end

                        local buffDur = (trinketBuffData and trinketBuffData.duration)
                            or (RC.GetTrinketBuffDuration and RC:GetTrinketBuffDuration(trinketData.itemId))
                        if buffDur and buffDur > 0 then
                            local buffStart = now - (buffDur - buffRemaining)
                            button.cooldownFrame:SetCooldown(buffStart, buffDur)
                        end
                    elseif cooldownRemaining > 0 then
                        if button.cooldownText then
                            button.cooldownText:SetText(self:FormatCooldownTime(cooldownRemaining))
                            if self:ShouldShowOwnCooldownText() then button.cooldownText:Show() else button.cooldownText:Hide() end
                        end
                        if button.buffDurationText then
                            button.buffDurationText:SetText("")
                            button.buffDurationText:Hide()
                        end

                        if start and duration then
                            button.cooldownFrame:SetCooldown(start, duration)
                        end
                    else
                        if button.cooldownText then
                            button.cooldownText:SetText("")
                            button.cooldownText:Hide()
                        end
                        if button.buffDurationText then
                            button.buffDurationText:SetText("")
                            button.buffDurationText:Hide()
                        end
                        button.cooldownFrame:Clear()
                    end
                else
                    if button.cooldownText then
                        button.cooldownText:SetText("")
                        button.cooldownText:Hide()
                    end
                    if button.buffDurationText then
                        button.buffDurationText:SetText("")
                        button.buffDurationText:Hide()
                    end
                    button.cooldownFrame:Clear()
                end
            end
        end
    end

    RC:CreateConsumablesHelperFrame()

    -- Staggered so login does not build four bars in one frame; the
    -- consumables bar is the only one users see immediately.
    C_Timer.After(0.5, function()
        RC:CreatePotionsBarFrame()
        RC:CreateWeaponsBarFrame()
        RC:CreateTrinketBarFrame()
    end)

    RC:InitializeAbsorbSpells()

    C_Timer.After(2, function()
        RC:LoadCurrentAbsorbs()
    end)

    RC.consumablesHelper.cooldownTickerActive = false
    RC.consumablesHelper.lastRefresh = 0

    -- While only the eating countdown is live, update the one button the
    -- food was used from instead of sweeping the whole bar.
    function RC:RefreshEatingCountdown()
        local ch = self.consumablesHelper
        if not ch or not ch.buttons or not ch.frame or not ch.frame:IsShown() then return end
        local foodId = RC._lastUsedBarItemId
        if not foodId then return end
        local button = ch.buttons[foodId]
        if not button or not button:IsShown() or not button.fullyInitialized then return end
        local now = GetTime()
        local isEating, eatingTime = self:IsEating()
        local gcdRemaining, gcdDuration = self:GetGCDInfo()
        self:UpdateSingleButton(button, now, isEating, eatingTime, gcdRemaining, gcdDuration)
    end

    -- THE guarded entry point for every hot cooldown event. The early
    -- return on an existing ticker is what lets BAG_UPDATE_COOLDOWN and
    -- SPELL_UPDATE_COOLDOWN call this 20 times a second for free: at most
    -- one 0.2s ticker exists, and it cancels itself when idle.
    function RC:StartCooldownTicker()
        if self.consumablesHelper.cooldownTicker then return end

        self.consumablesHelper.cooldownTickerActive = true

        local tickerFn = function()
            local anyVisible = (self.consumablesHelper.frame and self.consumablesHelper.frame:IsShown()) or
                              (self.potionsBar and self.potionsBar.frame and self.potionsBar.frame:IsShown()) or
                              (self.weaponsBar and self.weaponsBar.frame and self.weaponsBar.frame:IsShown()) or
                              (self.trinketBar and self.trinketBar.frame and self.trinketBar.frame:IsShown())

            -- No bar on screen: nothing to animate, stop immediately.
            if not anyVisible then
                RC:StopCooldownTicker()
                return
            end

            local now = GetTime()
            local updateAll = false
            local castingNow = false
            local eating = false
            local updC, updP, updW, updT = false, false, false, false

            if UnitCastingInfo("player") or UnitChannelInfo("player") then
                castingNow = AnyCastSwirl()
                -- 1.7s covers the longest bar-item cast plus server latency,
                -- so the swirl animation is not cut off by the skip logic.
                local recentBarClick = (RC._lastBarItemUse ~= nil) and (now - RC._lastBarItemUse < 1.7)
                updateAll = castingNow or recentBarClick
            end

            if not updateAll and self.IsEating and self:IsEating() then
                eating = true
            end

            local function barHasCooldown(buttons)
                if not buttons then return false end
                for _, button in pairs(buttons) do
                    if button and button:IsShown() and button.itemId then
                        if button.expiryText and button.expiryText:IsShown() then
                            return true
                        end
                        if button.cooldownFrame and button.cooldownFrame:IsShown() then
                            return true
                        end
                        -- A cast swirl still up (a stone or oil being put on,
                        -- or one that just ended or was cancelled): the bar
                        -- keeps being refreshed until a pass clears it and
                        -- its countdown. Without this, a cancelled cast left
                        -- its first number on the button for as long as some
                        -- other bar (a potion cooldown) kept the ticker going.
                        if button.castFrame and button.castFrame:IsShown() then
                            return true
                        end
                        local countItemId = (button.itemData and button.itemData.baseItemId) or button.itemId
                        local cdStart, cdDuration = RC:GetItemCooldownByID(countItemId)
                        if cdStart and cdDuration and cdStart > 0 and cdDuration > 1.5 then
                            if (cdStart + cdDuration) - now > 0 then
                                return true
                            end
                        end
                    end
                end
                return false
            end

            -- Second throttle inside the ticker: the 0.2s cadence exists for
            -- smooth swirls, but the per-button cooldown reads and state
            -- sweeps are held to ~1s unless casting or just clicked.
            -- Between heavy ticks the cached _updC/_updP/_updW/_updT decide.
            local recentBarUse = (now - (RC._lastBarItemUse or 0)) < 1.0
            local heavyTick = castingNow or recentBarUse
                or (now - (self.consumablesHelper._lastBarHeavyRefresh or 0)) >= 0.95
            if heavyTick then
                self.consumablesHelper._lastBarHeavyRefresh = now
            end

            if updateAll then
                updC, updP, updW, updT = true, true, true, true
            else
                if heavyTick then
                    if self.consumablesHelper.frame and self.consumablesHelper.frame:IsShown() then
                        updC = barHasCooldown(self.consumablesHelper.buttons)
                    end
                    if self.potionsBar and self.potionsBar.frame and self.potionsBar.frame:IsShown() then
                        updP = barHasCooldown(self.potionsBar.buttons)
                    end
                    if self.weaponsBar and self.weaponsBar.frame and self.weaponsBar.frame:IsShown() then
                        updW = barHasCooldown(self.weaponsBar.buttons)
                    end
                    if self.trinketBar and self.trinketBar.frame and self.trinketBar.frame:IsShown() then
                        for _, button in pairs(self.trinketBar.buttons or {}) do
                            if button:IsShown() and button.trinketData then
                                local trinketData = button.trinketData
                                if trinketData.equipped then
                                    local start, duration = GetInventoryItemCooldown("player", trinketData.slotIndex)
                                    if start and start > 0 and duration > 1.5 and (start + duration) - now > 0 then
                                        updT = true; break
                                    end
                                elseif trinketData.bag and trinketData.slot then
                                    local start, duration = C_Container.GetContainerItemCooldown(trinketData.bag, trinketData.slot)
                                    if start and start > 0 and duration > 1.5 and (start + duration) - now > 0 then
                                        updT = true; break
                                    end
                                end
                                local trinketBuffData = self.trinketBuffs and self.trinketBuffs[trinketData.itemId]
                                if trinketBuffData and trinketBuffData.buffId then
                                    if RC.IsTrinketBuffActive and RC:IsTrinketBuffActive(trinketData.itemId) then
                                        updT = true
                                    end
                                    if updT then break end
                                end
                            end
                        end
                    end
                    self.consumablesHelper._updC = updC
                    self.consumablesHelper._updP = updP
                    self.consumablesHelper._updW = updW
                    self.consumablesHelper._updT = updT
                else
                    updC = self.consumablesHelper._updC or false
                    updP = self.consumablesHelper._updP or false
                    updW = self.consumablesHelper._updW or false
                    updT = self.consumablesHelper._updT or false
                end
            end

            local consumCooldownLive = updC

            if eating then updC = true end

            local hasActiveCooldown = updC or updP or updW or updT

            if hasActiveCooldown then
                if heavyTick then
                    if updC and self.consumablesHelper.frame and self.consumablesHelper.frame:IsShown() then
                        if consumCooldownLive then
                            self:UpdateButtonStates(true)
                            self.consumablesHelper._eatingOnlySettled = false
                        elseif self.consumablesHelper._eatingOnlySettled then
                            self:RefreshEatingCountdown()
                        else
                            self:UpdateButtonStates(true)
                            self.consumablesHelper._eatingOnlySettled = true
                        end
                    end
                    if updP and self.potionsBar and self.potionsBar.frame and self.potionsBar.frame:IsShown() then
                        self:UpdatePotionButtonStates(true)
                    end
                    if updW and self.weaponsBar and self.weaponsBar.frame and self.weaponsBar.frame:IsShown() then
                        self:UpdateWeaponsButtonStates()
                    end
                    if updT and self.trinketBar and self.trinketBar.frame and self.trinketBar.frame:IsShown() then
                        self:UpdateTrinketBarButtonStates()
                    end
                end
            else
                -- Nothing on cooldown anywhere: one final trinket pass to
                -- clear its text, then stop. Any later event restarts it.
                if self.trinketBar and self.trinketBar.frame and self.trinketBar.frame:IsShown() then
                    self:UpdateTrinketBarButtonStates()
                end
                self.consumablesHelper._eatingOnlySettled = false
                RC:StopCooldownTicker()
            end
        end

        if RC.Profiler and RC.Profiler.TrackTicker then
            self.consumablesHelper.cooldownTicker =
                RC.Profiler:TrackTicker("ConsumablesHelper:CooldownTicker", 0.2, tickerFn)
        else
            self.consumablesHelper.cooldownTicker = C_Timer.NewTicker(0.2, tickerFn)
        end
    end

    function RC:StopCooldownTicker()
        if self.consumablesHelper.cooldownTicker then
            self.consumablesHelper.cooldownTicker:Cancel()
            self.consumablesHelper.cooldownTicker = nil
        end
        self.consumablesHelper.cooldownTickerActive = false

        -- Stopping the ticker would otherwise freeze half-drawn swirls on
        -- screen. Text and Cooldown frames are not protected, so hiding
        -- them is legal in combat.
        local function clearStaleText(buttons)
            if not buttons then return end
            for _, button in pairs(buttons) do
                if button and button:IsShown() then
                    if button.gcdText and button.gcdText:IsShown() then
                        button.gcdText:Hide()
                        button.gcdText._cachedText = nil
                    end
                    if button.gcdFrame and button.gcdFrame:IsShown() then
                        button.gcdFrame:Hide()
                    end
                    button._gcdEndTime = nil
                    if button.cooldownText and button.cooldownText:IsShown() then
                        button.cooldownText:Hide()
                        button.cooldownText._cachedText = nil
                    end
                    if button.cooldownFrame and button.cooldownFrame:IsShown() then
                        button.cooldownFrame:Hide()
                    end
                    -- durationText doubles as the eating countdown, which
                    -- outlives the cooldown ticker; leave it alone if the
                    -- player is still eating.
                    if button.durationText and button.durationText:IsShown() then
                        if not RC:IsEating() then
                            button.durationText:Hide()
                            button.durationText._cachedText = nil
                        end
                    end
                    if button.castFrame and button.castFrame:IsShown() then
                        button.castFrame:Hide()
                        button.lastCastStart = 0
                    end
                end
            end
        end
        clearStaleText(self.consumablesHelper.buttons)
        if self.potionsBar  then clearStaleText(self.potionsBar.buttons)  end
        if self.weaponsBar  then clearStaleText(self.weaponsBar.buttons)  end

        if self.UpdateButtonStates and self.consumablesHelper.frame and self.consumablesHelper.frame:IsShown() then
            self:UpdateButtonStates()
        end
        if self.UpdatePotionButtonStates and self.potionsBar and self.potionsBar.frame and self.potionsBar.frame:IsShown() then
            self:UpdatePotionButtonStates()
        end
        if self.UpdateWeaponsButtonStates and self.weaponsBar and self.weaponsBar.frame and self.weaponsBar.frame:IsShown() then
            self:UpdateWeaponsButtonStates()
        end
    end

    -- Debounced full rebuild entry point for one-off triggers (login, zone
    -- settle, options changes). NOT for the hot events - 0.05s is far too
    -- permissive for something that rebuilds both bars.
    function RC:ThrottledConsumablesRefresh()
        local now = GetTime()
        if now - self.consumablesHelper.lastRefresh < 0.05 then
            return
        end
        self.consumablesHelper.lastRefresh = now

        -- Rebuilds create and move secure buttons: queue instead in combat.
        if not InCombatLockdown() then
            self:UpdateConsumablesButtons()
            if self.db.potionsBar.enabled and self.potionsBar and self.potionsBar.frame then
                self:UpdatePotionsButtons()
            end
        else
            self.consumablesHelper.pendingRebuildOnCombatEnd = true
        end
        if self.db.potionsBar.enabled and self.potionsBar and self.potionsBar.frame and self.potionsBar.frame:IsShown() then
            self:RefreshPotionsDisplay()
        end
    end

    -- A use that bypasses the bar buttons - a bag click, an action bar
    -- keybind, a /use macro, an equipped item - must still mark the item
    -- so the swirl and eating countdown appear on its bar button.
    -- hooksecurefunc is post-call and cannot taint; unrelated uses cost
    -- one table lookup.
    if not RC._bagUseHooked then
        RC._bagUseHooked = true
        local function MarkUse(iid, how)
            if type(iid) ~= "number" then return end
            local tracked = (RC._flatItemIdSet and RC._flatItemIdSet[iid])
                or (RC._buffIdLookup and RC._buffIdLookup[iid])
            if tracked then
                RC._lastBarItemUse = GetTime()
                RC._lastUsedBarItemId = iid
                RC:DebugPrint(how .. " use marked: item " .. iid, "consumables")
            end
        end
        local function OnBagUse(bag, slot)
            if type(bag) ~= "number" or type(slot) ~= "number" then return end
            local iid = C_Container and C_Container.GetContainerItemID
                and C_Container.GetContainerItemID(bag, slot)
            MarkUse(iid, "Bag")
        end
        if C_Container and C_Container.UseContainerItem then
            hooksecurefunc(C_Container, "UseContainerItem", OnBagUse)
        elseif UseContainerItem then
            hooksecurefunc("UseContainerItem", OnBagUse)
        end
        -- action bar slot (keybind or click): an item placed on it
        -- directly; a macro on it reaches the hooks below through /use
        if UseAction and GetActionInfo then
            hooksecurefunc("UseAction", function(slot)
                if type(slot) ~= "number" then return end
                local kind, id = GetActionInfo(slot)
                if kind == "item" then MarkUse(tonumber(id), "Action bar") end
            end)
        end
        -- /use <name> and /use item:<id> from macros
        if UseItemByName and GetItemInfoInstant then
            hooksecurefunc("UseItemByName", function(name)
                if type(name) ~= "string" then return end
                MarkUse((GetItemInfoInstant(name)), "Macro")
            end)
        end
        -- /use <slot> and equipped-item uses
        if UseInventoryItem and GetInventoryItemID then
            hooksecurefunc("UseInventoryItem", function(slot)
                if type(slot) ~= "number" then return end
                MarkUse(GetInventoryItemID("player", slot), "Equipped")
            end)
        end
    end

    -- Cooldown and cast events, heard through the bars' shared event
    -- frame (Consumables_Events).
    local function OnCooldownEvent(event, arg1, arg2, arg3)
        if event == "PLAYER_ENTERING_WORLD" then
            C_Timer.After(1.0, function()
                RC:ThrottledConsumablesRefresh()
                if RC.consumablesHelper.frame and RC.consumablesHelper.frame:IsShown() then
                    RC:UpdateButtonStates()
                end
                if RC.weaponsBar and RC.weaponsBar.frame and RC.weaponsBar.frame:IsShown() then
                    RC:UpdateWeaponsButtonStates()
                end
                if RC.potionsBar and RC.potionsBar.frame and RC.potionsBar.frame:IsShown() then
                    RC:UpdatePotionButtonStates()
                end
                if RC.trinketBar and RC.trinketBar.frame and RC.trinketBar.frame:IsShown() then
                    RC:UpdateTrinketBarButtonStates()
                end
                RC:StartCooldownTicker()
            end)
            C_Timer.After(3.0, function()
                if RC.trinketBar and RC.trinketBar.frame then
                    RC.trinketBar.lastScanTime = 0
                    RC:UpdateTrinketBarButtons()
                    RC:UpdateTrinketBarButtonStates()
                end
                RC:StartCooldownTicker()
            end)
        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            -- a potion or elixir drunk, however it was used, starts its
            -- shared cooldown on the bars
            if arg3 then RC:OnPotionUsed(arg3) end
            if arg1 == "player" and RC._lastBarItemUse and (GetTime() - RC._lastBarItemUse) < 1.7 then
                RC:StartCooldownTicker()
                -- The item that was just used (bar click, bag, keybind or
                -- macro - every path marks it) went off in combat: hide its
                -- button now, whatever buff or cooldown it has. Once per use.
                if InCombatLockdown() and RC._lastUsedBarItemId
                    and RC._spentHiddenForUse ~= RC._lastBarItemUse and RC.HideSpentConsumableInCombat then
                    RC._spentHiddenForUse = RC._lastBarItemUse
                    RC:HideSpentConsumableInCombat(RC._lastUsedBarItemId)
                end
            end
        -- HOT EVENT. Fires 10-20+ times per second in combat. Throttled to
        -- 0.3s, then only starts the guarded ticker, which already covers
        -- the trinket bar sweep on its own cadence.
        elseif event == "SPELL_UPDATE_COOLDOWN" then
            if RC.Profiler and RC.Profiler.CountHit then
                RC.Profiler:CountHit("Event:SPELL_UPDATE_COOLDOWN(consum)")
            end
            local now = GetTime()
            if (now - (RC._lastSpellCDUpdate or 0)) >= 0.3 then
                RC._lastSpellCDUpdate = now
                RC:StartCooldownTicker()
            end
        -- HOT EVENT, handled correctly: 0.3s throttle plus one call to the
        -- guarded ticker starter. No button iteration, no WoW API reads.
        elseif event == "BAG_UPDATE_COOLDOWN" then
            local now = GetTime()
            if (now - (RC._lastBagCDUpdate or 0)) >= 0.3 then
                RC._lastBagCDUpdate = now
                RC:StartCooldownTicker()
            end
        -- Cast-end is low frequency (player only, unit filtered at
        -- registration), so a 0.3s throttle plus an inline sweep is
        -- affordable; it exits on the first visible cast swirl.
        elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_FAILED"
            or event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
            if arg1 == "player" then
                local now = GetTime()
                if (now - (RC._lastCastEndUpdate or 0)) >= 0.3 then
                    RC._lastCastEndUpdate = now
                    -- the cast info can still read as live while this event
                    -- fires, so the ticker follows up and clears the swirl
                    -- on its next pass (see barHasCooldown)
                    RC:StartCooldownTicker()
                    if AnyCastSwirl() then
                        if RC.consumablesHelper and RC.consumablesHelper.frame and RC.consumablesHelper.frame:IsShown() then
                            RC:UpdateButtonStates()
                        end
                        if RC.potionsBar and RC.potionsBar.frame and RC.potionsBar.frame:IsShown() then
                            RC:UpdatePotionButtonStates()
                        end
                        if RC.weaponsBar and RC.weaponsBar.frame and RC.weaponsBar.frame:IsShown() then
                            RC:UpdateWeaponsButtonStates()
                        end
                    end
                end
            end
        end
    end
    RC:OnBarsEvent("PLAYER_ENTERING_WORLD", OnCooldownEvent)
    RC:OnBarsEvent("SPELL_UPDATE_COOLDOWN", OnCooldownEvent)
    RC:OnBarsEvent("BAG_UPDATE_COOLDOWN", OnCooldownEvent)
    RC:OnBarsEvent("UNIT_SPELLCAST_SUCCEEDED", OnCooldownEvent, "player")
    RC:OnBarsEvent("UNIT_SPELLCAST_STOP", OnCooldownEvent, "player")
    RC:OnBarsEvent("UNIT_SPELLCAST_FAILED", OnCooldownEvent, "player")
    RC:OnBarsEvent("UNIT_SPELLCAST_INTERRUPTED", OnCooldownEvent, "player")
    RC:OnBarsEvent("UNIT_SPELLCAST_CHANNEL_STOP", OnCooldownEvent, "player")
end
