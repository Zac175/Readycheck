------------------------------------------------------------------------
-- Readycheck - Trinket Swap Event Wiring
-- Registers the WoW events that drive scans, combat-state transitions
-- and boss-fight auto-pause. Bag changes (from the shared bag index) and
-- PLAYER_EQUIPMENT_CHANGED are debounced with a pending flag + C_Timer
-- before doing any work; BAG_UPDATE_COOLDOWN only raises a dirty flag.
------------------------------------------------------------------------
local pairs, tostring = pairs, tostring
local GetTime = GetTime
local GetInventoryItemID = GetInventoryItemID
local GetInventoryItemCooldown = GetInventoryItemCooldown
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local WRF = _G.Readycheck
if not WRF then return end
WRF._tssInit = WRF._tssInit or {}
WRF._tss = WRF._tss or {}
WRF._tssInit[#WRF._tssInit + 1] = function()
    local RC = _G.Readycheck
    local _tss = WRF._tss
    local SLOT_KEYS, INVENTORY_SLOTS = _tss.SLOT_KEYS, _tss.INVENTORY_SLOTS

    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
    eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_ALIVE")

    -- One rescan 0.5s after the bags really changed (shared bag index),
    -- however many changes land in between.
    RC.Bags:OnChange("TrinketSwap", function()
        if RC.trinketSwapSystem.pendingBagUpdate then return end
        RC.trinketSwapSystem.pendingBagUpdate = true
        C_Timer.After(0.5, function()
            RC.trinketSwapSystem.pendingBagUpdate = false
            if RC.db then RC:RefreshTrinketScan() end
        end)
    end)

    eventFrame:SetScript("OnEvent", function(self, event, ...)
        if not RC.db then return end

        if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_ALIVE" then
            -- A boss-fight pause that a reload interrupted: put auto-swap
            -- back the way it was, unless the fight is picked up again
            -- below by ReengageBossStateAfterReload.
            if RC.db.trinketSwap and RC.db.trinketSwap.bossPausedAutoSwap
               and not (RC.trinketBossPauseState and RC.trinketBossPauseState.pausedByBossFight) then
                RC.db.trinketSwap.bossPausedAutoSwap = nil
                RC.db.trinketSwap.autoSwapActive = true
            end
            if RC.db.trinketSwap and RC.db.trinketSwap.enabled then
                C_Timer.After(2.0, function()
                    if not RC.db or not RC.db.trinketSwap or not RC.db.trinketSwap.enabled then return end
                    RC:ScanAvailableTrinkets()
                    if RC.ReengageBossStateAfterReload then
                        RC:ReengageBossStateAfterReload()
                    end
                    -- 8s grace: an on-use trinket already equipped at
                    -- login may still have its buff running from before
                    -- reload/relog.
                    RC.trinketSwapSystem.loginProtectionExpiry = GetTime() + 8
                    RC:PerformInitialTrinketEquip()
                    if not RC.trinketSwapSystem.pollingActive then
                        RC:StartTrinketPolling()
                    end
                end)
            else
                C_Timer.After(2.0, function()
                    if RC.ReengageBossStateAfterReload then
                        RC:ReengageBossStateAfterReload()
                    end
                end)
            end
            return
        end

        if event == "BAG_UPDATE_COOLDOWN" then
            -- Fires 10-20x/sec in combat, so this handler does no work of
            -- its own: it only raises a dirty flag that the 1 Hz trinket
            -- poll consumes (RC:CheckDeathSwapLockCooldowns, TSS_Combat).
            RC.trinketSwapSystem._deathSwapCDDirty = true
        elseif event == "PLAYER_EQUIPMENT_CHANGED" then
            local slot = ...
            if slot == 13 or slot == 14 then
                if not RC.trinketSwapSystem.pendingEquipUpdate then
                    RC.trinketSwapSystem.pendingEquipUpdate = true
                    C_Timer.After(0.2, function()
                        RC.trinketSwapSystem.pendingEquipUpdate = false
                        local slotNumber = (slot == 13) and 1 or 2
                        RC:UpdateTrinketState(slotNumber)
                    end)
                end
            end
        elseif event == "PLAYER_REGEN_DISABLED" then
            RC.trinketSwapSystem.combatStartTime = GetTime()
            RC:OnCombatStateChange(true)

            local applied = RC.bossTrinketState and RC.bossTrinketState.appliedBoss
            if applied and UnitExists("target") and not UnitIsDead("target") then
                local tName = UnitName("target")
                local raid  = RC.GetEffectiveRaidName and RC:GetEffectiveRaidName() or nil
                local enc   = (raid and tName and RC.GetEncounterNameForBoss) and RC:GetEncounterNameForBoss(raid, tName) or tName
                if enc == applied then
                    RC.gearSwapState = RC.gearSwapState or {}
                    RC.gearSwapState.engagedInCombat = applied
                    RC:DebugPrint("Combat engaged with applied boss: " .. applied, "trinket")
                end
            end

            if RC.db.trinketSwap and RC.db.trinketSwap.pauseDuringBossFight then
                if RC:IsTargetingKnownBoss() then
                    RC:PauseTrinketSwapForBoss()
                end
            end
        elseif event == "PLAYER_REGEN_ENABLED" then
            RC:OnCombatStateChange(false)
            if RC.db.trinketSwap and RC.db.trinketSwap.pauseDuringBossFight then
                RC:ResumeTrinketSwapAfterBoss()
            end
        elseif event == "PLAYER_TARGET_CHANGED" then
            if RC.db.trinketSwap and RC.db.trinketSwap.pauseDuringBossFight then
                if not InCombatLockdown() then
                    if RC:IsTargetingKnownBoss() then
                        RC:PauseTrinketSwapForBoss()
                    else
                        RC:ResumeTrinketSwapAfterBoss()
                    end
                end
            end
        end
    end)

    C_Timer.After(1, function()
        if not RC.db or not RC.db.trinketSwap then return end

        if RC.db.trinketSwap.configNames then
            for key, name in pairs(RC.db.trinketSwap.configNames) do
                RC.trinketSwapSystem.queueNames[key] = name
            end
        end

        if RC.db.trinketSwap.currentQueue then
            RC.trinketSwapSystem.currentQueue = RC.db.trinketSwap.currentQueue
        end

        if RC.db.trinketSwap.showToggleButton then
            RC:ShowTrinketToggleButton()
        end

        C_Timer.After(2.0, function()
            if not RC.trinketSwapSystem or not RC.trinketSwapSystem.trinketStates then return end

            for slotNumber = 1, 2 do
                local inventorySlot = INVENTORY_SLOTS[slotNumber]
                local itemId = GetInventoryItemID("player", inventorySlot)

                if itemId then
                    local slotKey = SLOT_KEYS[slotNumber]
                    local state = RC.trinketSwapSystem.trinketStates[slotKey]

                    state.itemId = itemId
                    state.isOnUse = RC:IsTrinketOnUse(itemId)

                    if state.isOnUse then
                        local start, duration = GetInventoryItemCooldown("player", inventorySlot)

                        if start and start > 0 and duration > 1.5 then
                            local expectedCD = RC.trinketCooldowns[itemId]
                            local isCategoryCD = (duration <= 20)
                                or (expectedCD and math.abs(duration - expectedCD) >= 5)
                                or (not expectedCD and duration >= 25 and duration <= 35)

                            if isCategoryCD then
                                state.wasOnCooldown    = false
                                state.cooldownStart    = start
                                state.cooldownDuration = duration
                                state.buffExpireTime   = 0
                                state.cooldownDetectedAt = 0
                                state.readySinceTime   = 0
                            else
                                local elapsed   = GetTime() - start
                                local fullCD    = RC.trinketCooldowns[itemId] or duration

                                state.wasOnCooldown    = true
                                state.cooldownStart    = start
                                state.cooldownDuration = duration
                                state.fullCooldown     = fullCD
                                state.readySinceTime   = 0
                                state.cooldownDetectedAt = start
                                state.inheritedCD = true

                                local spellId = (RC.trinketBuffs and RC.trinketBuffs[itemId] and RC.trinketBuffs[itemId].buffId)
                                if not spellId and RC.TrinketScanner and RC.TrinketScanner.autoDetectedTrinkets then
                                    local scanned = RC.TrinketScanner.autoDetectedTrinkets[itemId]
                                    if scanned then spellId = scanned.buffId end
                                end
                                state.buffExpireTime = 0
                                if spellId then
                                    for _, a in ipairs(RC.Auras:Buffs()) do
                                        if a.spellId == spellId and a.expirationTime > GetTime() then
                                            state.buffExpireTime = a.expirationTime
                                            break
                                        end
                                    end
                                end

                                local timeIntoCD = fullCD - (duration - elapsed)
                                state.lastEquipTime = timeIntoCD > 30 and (start - 60) or (start - timeIntoCD)
                            end
                        else
                            state.wasOnCooldown    = false
                            state.cooldownStart    = 0
                            state.cooldownDuration = 0
                            state.fullCooldown     = 0
                            state.buffExpireTime   = 0
                            state.cooldownDetectedAt = 0
                            state.lastEquipTime    = GetTime()
                            state.readySinceTime   = GetTime()
                        end
                    else
                        state.wasOnCooldown = false
                        state.cooldownStart = 0
                        state.cooldownDuration = 0
                        state.fullCooldown = 0
                        state.buffExpireTime = 0
                    end
                end
            end
        end)

        C_Timer.After(6.0, function()
            if RC.db.trinketSwap.enabled then
                RC:PerformInitialTrinketEquip()
            end
            C_Timer.After(1.0, function()
                -- Polling is the trinket rotation engine; leaving it
                -- running with the system disabled burns a 1 Hz tick
                -- forever. The settings checkbox and the toggle button
                -- both start it when the system is switched on later.
                if RC.db and RC.db.trinketSwap and RC.db.trinketSwap.enabled then
                    RC:StartTrinketPolling()
                end
                C_Timer.After(0.2, function()
                    if RC.db.trinketSwap.enabled and RC.db.trinketSwap.autoSwapActive then
                        for sn = 1, 2 do RC:ProcessTrinketRotation(sn) end
                    end
                end)
            end)
        end)
    end)

    RC.trinketBossPauseState = {
        pausedByBossFight = false,
        originalAutoSwapState = nil
    }

    function RC:IsTargetingKnownBoss()
        if not UnitExists("target") then return false end
        local targetName = UnitName("target")
        if not targetName then return false end
        if not RC.GetEffectiveRaidName then return false end
        local raidName = self:GetEffectiveRaidName()
        if not raidName then return false end
        if not RC.GetEncounterNameForBoss then return false end
        local encounterName = self:GetEncounterNameForBoss(raidName, targetName)
        if not encounterName then return false end
        if not RC.GetMobConfig then return false end
        local bossConfig = self:GetMobConfig(raidName, encounterName)
        return bossConfig ~= nil and bossConfig.enabled == true
    end

    function RC:PauseTrinketSwapForBoss()
        if not self.db or not self.db.trinketSwap or not self.db.trinketSwap.pauseDuringBossFight then
            return
        end

        if not self.trinketBossPauseState then
            self.trinketBossPauseState = { pausedByBossFight = false, originalAutoSwapState = nil }
        end

        if self.trinketBossPauseState.pausedByBossFight then
            return
        end

        self.trinketBossPauseState.originalAutoSwapState = self.db.trinketSwap.autoSwapActive
        self.trinketBossPauseState.pausedByBossFight = true

        if self.db.trinketSwap.autoSwapActive then
            -- Remembered in the profile too: a reload mid-fight used to
            -- leave auto-swap off for good with nothing to restore it.
            self.db.trinketSwap.bossPausedAutoSwap = true
            self.db.trinketSwap.autoSwapActive = false
            self:DebugPrint("Trinket auto-swap PAUSED for boss fight", "trinket")
        end

        self:UpdateTrinketToggleButtonState()
    end

    function RC:ResumeTrinketSwapAfterBoss()
        if not self.trinketBossPauseState then
            self.trinketBossPauseState = { pausedByBossFight = false, originalAutoSwapState = nil }
            return
        end

        if not self.trinketBossPauseState.pausedByBossFight then
            return
        end

        local originalState = self.trinketBossPauseState.originalAutoSwapState
        self.trinketBossPauseState.pausedByBossFight = false
        self.trinketBossPauseState.originalAutoSwapState = nil
        if self.db and self.db.trinketSwap then self.db.trinketSwap.bossPausedAutoSwap = nil end

        if self.db and self.db.trinketSwap and self.db.trinketSwap.enabled then
            if originalState == nil then
                self.db.trinketSwap.autoSwapActive = true
            else
                self.db.trinketSwap.autoSwapActive = originalState
            end
            self:DebugPrint("Trinket auto-swap RESUMED after boss fight (state=" .. tostring(self.db.trinketSwap.autoSwapActive) .. ")", "trinket")
        end

        self:UpdateTrinketToggleButtonState()
    end

    function RC:UpdateTrinketToggleButtonState()
        if not self.trinketToggleButton then return end
        if not self.db or not self.db.trinketSwap then return end

        local button = self.trinketToggleButton

        local now = GetTime()
        if not button.lastCleanupTime or (now - button.lastCleanupTime) > 5 then
            self:CleanupTrinketButtonFontStrings()
            button.lastCleanupTime = now
        end

        -- The button paints itself (stripe, dot, text, icons) through
        -- RC:StyleTrinketToggle (TSS_UI.lua).
        if button.UpdateButtonState then
            button.UpdateButtonState()
            return
        end
        local statusC, textC = self:GetTrinketToggleStateColors()

        if button.statusDot then
            button.statusDot:SetVertexColor(statusC.r, statusC.g, statusC.b, statusC.a or 1)
        end

        if button.text and self.trinketSwapSystem then
            button.text:SetText("")

            local configName = self.trinketSwapSystem.queueNames[self.trinketSwapSystem.currentQueue] or "Default"
            button.text:SetText(configName)

            button.text:SetTextColor(textC.r, textC.g, textC.b, textC.a or 1)
        end
    end

    function RC:GetTrinketSwapHistory()
        return self.trinketSwapSystem.swapHistory or {}
    end

    function RC:PrintTrinketSwapHistory()
        local history = self:GetTrinketSwapHistory()
        if #history == 0 then
            self:Print(RCL["No trinket swaps recorded this session."])
            return
        end
        self:Print(RCL["|cFFFFD700Trinket Swap History ("] .. #history .. RCL[" swaps):|r"])
        for i = #history, math.max(1, #history - 19), -1 do
            local entry = history[i]
            self:Print(string.format(RCL["  [%s] Slot %d: %s -> %s"], entry.time, entry.slot, entry.out, entry.inn))
        end
    end

    RC:DebugPrint("Trinket Swap System loaded", "trinket")
end
