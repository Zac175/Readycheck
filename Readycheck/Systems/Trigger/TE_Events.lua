------------------------------------------------------------------------
-- Readycheck - Trigger Engine Events
-- One event frame drives the whole trigger engine: target change, combat
-- enter/leave, equipment change, ENCOUNTER_START/END and zone change.
-- Owns the reset semantics - which caches and which trigger latches each
-- event clears - and every combat-lockdown deferral of gear work.
-- UNIT_AURA is consumed through the shared 0.15s throttled callback, never
-- as a raw handler; UNIT_HEALTH only drives the Frost Blast dismissal.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)
local UnitBuff = UnitBuff or (RCC and RCC.Compat and RCC.Compat.UnitBuff)
local UnitDebuff = UnitDebuff or (RCC and RCC.Compat and RCC.Compat.UnitDebuff)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local GetTime, UnitGUID, UnitHealth, UnitHealthMax = GetTime, UnitGUID, UnitHealth, UnitHealthMax
local UnitExists, UnitIsDead, UnitName = UnitExists, UnitIsDead, UnitName
local UnitAffectingCombat, InCombatLockdown = UnitAffectingCombat, InCombatLockdown
local GetSpellCooldown = GetSpellCooldown or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetSpellCooldown)
local C_Timer = C_Timer
local wipe = wipe
local string_format = string.format
local string_lower = string.lower
local string_find = string.find

local reuseAbilitiesToShow = {}
local reuseMacroCasts = {}
local reuseAbilitiesRemoved = {}
local RC = _G.Readycheck
if not RC then return end
RC._tes = RC._tes or {}
local _tes = RC._tes
local abilityReadyCache = _tes.abilityReadyCache

-- The 1s heartbeat that actually re-evaluates triggers. Created once and
-- left running; only showInCombatOnly cancels it, on combat end. Shared by
-- the PLAYER_TARGET_CHANGED and PLAYER_REGEN_DISABLED branches below.
local function EnsureTriggerCheckTimer()
    if RC.triggerCheckTimer then return end
    local fn = function()
        if RC.activeSimulation or (UnitExists("target") and not UnitIsDead("target") and UnitCanAttack("player", "target")) then
            RC:RunTriggerCheck()
        end
    end
    if RC.Profiler and RC.Profiler.TrackTicker then
        RC.triggerCheckTimer = RC.Profiler:TrackTicker("TriggerEngine:TargetTriggerCheck", 1, fn)
    else
        RC.triggerCheckTimer = C_Timer.NewTicker(1, fn)
    end
end
    if not RC.targetChangeFrame then
        RC:DebugPrint("Creating event frame and registering events", "system")
        RC.targetChangeFrame = CreateFrame("Frame")
        RC.targetChangeFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
        RC.targetChangeFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
        RC.targetChangeFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
        RC.targetChangeFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
        RC.targetChangeFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        RC.targetChangeFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        -- UNIT_AURA is high frequency, so it goes through the shared throttled
        -- callback
        RC:RegisterUnitAuraCallback("TriggerEngine", 0.15, function()
            RC:CheckAndDismissPotionBuffs()
            RC:CheckFrostBlastDebuff()
            RC:CheckFrostBlastBuffRemoval()
        end)
        RC.targetChangeFrame:RegisterUnitEvent("UNIT_HEALTH", "player")
        RC.targetChangeFrame:RegisterEvent("ENCOUNTER_START")
        RC.targetChangeFrame:RegisterEvent("ENCOUNTER_END")

        RC.lastEquippedTrinkets = {
            slot13 = nil,
            slot14 = nil
        }

        RC.targetChangeFrame:SetScript("OnEvent", function(self, event, ...)
    if not RC.db then return end

    if RC:IsDebugEnabled("trigger") then RC:DebugPrint("Event received: " .. event, "trigger") end

    if event == "UNIT_HEALTH" then
        local unit = ...
        if unit == "player" then
            RC:CheckAndDismissFrostBlastReminder()
        end

    elseif event == "PLAYER_TARGET_CHANGED" then
        if RC:IsDebugEnabled("trigger") then RC:DebugPrint("Target changed event triggered", "trigger") end

        if not RC.currentRaid then
            if RC.GetEffectiveRaidName then
                RC.currentRaid = RC:GetEffectiveRaidName()
            else
                local z = GetRealZoneText()
                RC.currentRaid = RC.raidZoneMap and RC.raidZoneMap[z] or nil
            end
        end

        -- A new target invalidates everything keyed to the old one: encounter
        -- resolve, the has-X encounter flags, both TTK caches, ability readiness
        -- and the raid name / potion bag location caches.
        if RC.encounterCache then
            RC.encounterCache.targetGUID = nil
        end
        RC._currentEncounterHasTTK           = nil
        RC._currentEncounterHasBuffRemaining = nil
        if RC.ttkPredictionCache then
            RC.ttkPredictionCache.value = nil
            RC.ttkPredictionCache.liveValue = nil
            RC.ttkPredictionCache.lastUpdate = 0
            RC.ttkPredictionCache.lastLiveUpdate = 0
        end
        wipe(abilityReadyCache)

        if RC.OnExecuteTargetChanged then
            RC:OnExecuteTargetChanged()
        end

        if not UnitExists("target") or UnitIsDead("target") then
            if RC.triggerCheckTimer then
                RC.triggerCheckTimer:Cancel()
                RC.triggerCheckTimer = nil
            end

            if RC.DismissReminderKeepingPersistent then
                RC:DismissReminderKeepingPersistent("Target lost or dead")
            elseif RC.SmartDismissReminder then
                RC:SmartDismissReminder("Target lost or dead")
            end

            local engaged = RC.gearSwapState and RC.gearSwapState.engagedInCombat

            -- Losing the target only fires the post-combat swap when the dead
            -- unit really is the engaged boss. Deselecting a live boss must not,
            -- and a real death is covered again by PLAYER_REGEN_ENABLED.
            if RC.gearSwapState.lastEquippedSet and RC.gearSwapState.postCombatSet and engaged then
                local targetSet = RC.gearSwapState.postCombatSet

                if not UnitAffectingCombat("player") then
                    local deadTargetIsBoss = false
                    if UnitExists("target") and UnitIsDead("target") then
                        if RC.gearSwapState.engagedBossGUID then
                            deadTargetIsBoss = (UnitGUID("target") == RC.gearSwapState.engagedBossGUID)
                        elseif RC.gearSwapState.lastBossTarget then
                            deadTargetIsBoss = (UnitName("target") == RC.gearSwapState.lastBossTarget)
                        end
                    end

                    if deadTargetIsBoss and not RC:IsEngagedBossAlive() then
                        if RC.FireDeathGearSwap then
                            RC:FireDeathGearSwap()
                        else
                            RC:AttemptPostCombatGearSwap(targetSet, 1)
                        end
                        RC.gearSwapState.engagedInCombat = nil
                        RC.gearSwapState.engagedBossGUID = nil
                    elseif RC:IsDebugEnabled("gear") then
                        RC:DebugPrint("Post-combat swap suppressed on target loss: dead unit is not the engaged boss (or boss still alive) - PLAYER_REGEN_ENABLED will handle the real boss death", "gear")
                    end
                end
            else
                RC.gearSwapState.lastEquippedSet = nil
                if not UnitIsDead("target") and not UnitAffectingCombat("player") then
                    RC.gearSwapState.postCombatSet = nil
                end
                RC.gearSwapState.lastBossTarget = nil
                RC.gearSwapState.engagedBossGUID = nil
                RC.gearSwapState.engagedInCombat = nil

                if RC.bossTrinketState
                   and RC.bossTrinketState.appliedBoss
                   and RC:IsDebugEnabled("trinket")
                then
                    RC:DebugPrint("Target cleared OOC - keeping boss trinket lock for "
                        .. tostring(RC.bossTrinketState.appliedBoss)
                        .. " (deselect is not death)", "trinket")
                end
            end

            RC.gearSwapState.engageHandledBoss = nil
            RC.gearSwapState.engageHandledTime = nil

            return
        end

        local targetName = UnitName("target")
        if targetName then

            if not InCombatLockdown()
               and RC.gearSwapState
               and RC.gearSwapState.engageHandledBoss then
                RC.gearSwapState.engageHandledBoss = nil
                RC.gearSwapState.engageHandledTime  = nil
            end

            local currentRaid = RC.GetEffectiveRaidName and RC:GetEffectiveRaidName() or nil
            if currentRaid then
                local triggerTarget = RC:GetCurrentTargetData()
                if triggerTarget then
                    local encounterName = nil
                    if triggerTarget.encounterType == "boss" then
                        encounterName = RC:GetEncounterNameForBoss(currentRaid, triggerTarget.name)
                    else
                        encounterName = triggerTarget.name
                    end
                    if encounterName then
                        RC.lastKnownEncounter = encounterName
                        if RC:IsDebugEnabled("trigger") then RC:DebugPrint("Set lastKnownEncounter: " .. encounterName, "trigger") end
                    end

                    if encounterName then
                        RC:RunEngageGearSwap(encounterName, currentRaid, triggerTarget)
                    end
                end
            end

            if RC:IsDebugEnabled("trigger") then RC:DebugPrint("Calling RunTriggerCheck for target: " .. targetName, "trigger") end
            -- Under lockdown, target swapping can burst; collapse it behind a
            -- 0.2s guarded timer so RunTriggerCheck runs once for the burst.
            if InCombatLockdown() then
                RC._targetTriggerDirty = true
                if not RC._targetTriggerPending then
                    RC._targetTriggerPending = true
                    C_Timer.After(0.2, function()
                        RC._targetTriggerPending = false
                        if not RC._targetTriggerDirty then return end
                        RC._targetTriggerDirty = false
                        RC:RunTriggerCheck()
                    end)
                end
            else
                RC:RunTriggerCheck()
            end

            if not InCombatLockdown() and currentRaid then
                local triggerTarget2 = RC:GetCurrentTargetData()
                if triggerTarget2 and triggerTarget2.encounterType == "boss" then
                    local eName2 = RC:GetEncounterNameForBoss(currentRaid, triggerTarget2.name)
                    if eName2 and RC.CheckBossTargetConsumableReminders then
                        RC:CheckBossTargetConsumableReminders(eName2, currentRaid)
                    end
                end
            end

            EnsureTriggerCheckTimer()
        end

    elseif event == "PLAYER_REGEN_DISABLED" then
        if RC.OnExecuteCombatStart then
            RC:OnExecuteCombatStart()
        end

        local now = GetTime()
        RC.combatState.lastStateChange = now
        RC.combatState.stableForDuration = 0
        wipe(abilityReadyCache); RC._encResolveCache = nil

        if RC.ScanEquippedTrinkets then
            RC:ScanEquippedTrinkets()
        end

        if RC.activeReminderData and RC.activeReminderData.abilities then
            local hasOil = false
            for _, abilityKey in ipairs(RC.activeReminderData.abilities) do
                local isOil = (abilityKey == "8956") or (abilityKey == 8956) or
                              (type(abilityKey) == "string" and abilityKey:lower() == "oil of immolation")
                if isOil then
                    hasOil = true
                    break
                end
            end

            if hasOil then
                if RC:IsDebugEnabled("trigger") then RC:DebugPrint("Combat started - instantly dismissing Oil of Immolation reminder", "trigger") end
                if RC.InstantDismissReminder then
                    RC:InstantDismissReminder("Combat started - Oil dismissed")
                elseif RC.reminderFrame then
                    RC.reminderFrame:Hide()
                end
            end

            if not hasOil then
                local hasPrePullOrEquip = false
                for _, abilityKey in ipairs(RC.activeReminderData.abilities) do
                    if abilityKey == "preTargetConsumable" or abilityKey == "equipReminder" then
                        hasPrePullOrEquip = true
                        break
                    end
                end
                if hasPrePullOrEquip then
                    if RC:IsDebugEnabled("trigger") then RC:DebugPrint("Combat started - dismissing pre-pull / post-death reminder", "trigger") end
                    if RC.abilityData then
                        RC.abilityData["preTargetConsumable"] = nil
                        RC.abilityData["equipReminder"] = nil
                    end
                    if RC.InstantDismissReminder then
                        RC:InstantDismissReminder("Combat started - pre-pull / equip reminder dismissed")
                    end
                end
            end
        end

        if RC.StartBuffRemainingMonitor then
            RC:StartBuffRemainingMonitor()
        end

        -- Combat just started, so the post-combat set cannot be equipped now.
        -- Queue it; ProcessGearSwapQueue drains it at the regen edge.
        if RC.gearSwapState.postCombatSet and RC.gearSwapState.lastEquippedSet
           and RC.activeEncounterName then
            local targetSet = RC.gearSwapState.postCombatSet
            if RC.QueueGearSwap then
                RC:QueueGearSwap(targetSet)
                if RC:IsDebugEnabled("gear") then RC:DebugPrint("Entered combat - queued post-combat gear swap: " .. targetSet, "gear") end
            end
        end

        if RC.UpdateFastWeaponReminder then
            C_Timer.After(0.5, function()
                RC:UpdateFastWeaponReminder()
            end)
        end

        RC:RunTriggerCheck()

        EnsureTriggerCheckTimer()

    elseif event == "PLAYER_REGEN_ENABLED" then
        if RC.OnExecuteCombatEnd then
            RC:OnExecuteCombatEnd()
        end

        local now = GetTime()
        RC.combatState.lastStateChange = now
        RC.combatState.stableForDuration = 0

        if RC.DismissReminderKeepingPersistent then
            RC:DismissReminderKeepingPersistent("Combat ended")
        elseif RC.SmartDismissReminder then
            RC:SmartDismissReminder("Combat ended")
        end

        if RC.StopBuffRemainingMonitor then
            RC:StopBuffRemainingMonitor()
        end

        RC.lastKnownEncounter = nil

        if RC.encounterCache then RC.encounterCache.targetGUID = nil end
        if RC.ttkPredictionCache then
            RC.ttkPredictionCache.value = nil
            RC.ttkPredictionCache.liveValue = nil
        end
        wipe(abilityReadyCache)

        -- Combat end is the rearm point. combat_start, buff_remaining and the
        -- once-per-boss Oil latch all reset here. usedAbilities is deliberately
        -- left alone: it is per-GUID and dies with the mob. encounterStartTriggers
        -- is also never cleared, so encounter_start is once per mob GUID for good.
        if RC.spellCastTriggers and RC.spellCastTriggers.combatStartTriggers then
            RC.spellCastTriggers.combatStartTriggers = {}
            if RC:IsDebugEnabled("trigger") then RC:DebugPrint("Combat ended - cleared combatStartTriggers", "trigger") end
        end

        if RC.spellCastTriggers and RC.spellCastTriggers.buffRemainingTriggers then
            RC.spellCastTriggers.buffRemainingTriggers = {}
            if RC:IsDebugEnabled("trigger") then RC:DebugPrint("Combat ended - cleared buffRemainingTriggers", "trigger") end
        end

        if RC.spellCastTriggers and RC.spellCastTriggers.oilOfImmolationShown
           and next(RC.spellCastTriggers.oilOfImmolationShown) then
            wipe(RC.spellCastTriggers.oilOfImmolationShown)
        end

        if RC.db.showInCombatOnly then
            if RC.triggerCheckTimer then
                RC.triggerCheckTimer:Cancel()
                RC.triggerCheckTimer = nil
            end
        end

        if RC.activeReminderData and RC.activeReminderData.abilities then
            local hadFB = false
            for i = #RC.activeReminderData.abilities, 1, -1 do
                local ab = RC.activeReminderData.abilities[i]
                if ab == "frostBlast" or (type(ab) == "string" and ab:find("^frostBlastBuff_")) then
                    table.remove(RC.activeReminderData.abilities, i)
                    hadFB = true
                end
            end
            if hadFB then
                if #RC.activeReminderData.abilities == 0 then
                    RC:SmartDismissReminder("Left KT combat  -  clearing frost blast reminder")
                else
                    RC:UpdateReminderWithRemainingAbilities()
                end
                RC:DebugPrint("Frost blast reminder cleared on combat end", "trigger")
            end
        end

        -- Combat dropped while the engaged boss is still alive: this was a
        -- self-buff or an add pull, not a kill. Re-equip the on-target set and
        -- flush the slot overrides lockdown blocked, instead of the death path.
        do
            local gs = RC.gearSwapState
            local bossName = gs and gs.lastBossTarget
            if bossName and RC:IsEngagedBossAlive() then
                if RC.gearSwapQueue then RC.gearSwapQueue = {} end
                gs.engagedInCombat = nil
                local capturedSet  = gs.lastEquippedSet
                local capturedBoss = bossName
                if capturedSet and capturedSet ~= "" then
                    C_Timer.After(1.0, function()
                        if InCombatLockdown() then return end
                        if not UnitExists("target") or UnitIsDead("target") then return end
                        if UnitName("target") ~= capturedBoss then return end
                        RC:EquipGearSetFast(capturedSet, RC:GetOnTargetOverrideSlots(capturedBoss))
                        RC:DebugPrint(
                            "Re-equipping on-target set after self-buff combat exit: " .. capturedSet,
                            "gear")
                    end)
                end
                -- Also apply any non-trinket override slots that were blocked by
                -- combat lockdown when the player first targeted the boss.
                if RC._pendingOnTargetSlots then
                    local pendingSlots  = RC._pendingOnTargetSlots
                    local pendingReason = RC._pendingOnTargetReason
                    local pendingEnch   = RC._pendingOnTargetEnchants
                    RC._pendingOnTargetSlots    = nil
                    RC._pendingOnTargetReason   = nil
                    RC._pendingOnTargetEnchants = nil
                    C_Timer.After(1.2, function()
                        if InCombatLockdown() then return end
                        if not UnitExists("target") or UnitIsDead("target") then return end
                        if UnitName("target") ~= capturedBoss then return end
                        RC:ApplyBossForceEquipSlots(pendingSlots,
                            "deferred on-target (self-buff exit): " .. (pendingReason or "?"),
                            pendingEnch)
                    end)
                end
            end
        end

        if RC.ProcessGearSwapQueue then
            RC:ProcessGearSwapQueue()
        end

        local _postSet = RC.gearSwapState.postCombatSet
        local _hasPost = _postSet and _postSet ~= ""
        local _hasDeathOverride =
            (RC.pendingDeathTrinketSwap ~= nil) or (RC.pendingDeathSlotSwap ~= nil)
        if _hasPost or _hasDeathOverride then
            if RC.FireDeathGearSwap then
                RC:FireDeathGearSwap()
            end
        end

        if not _hasPost then
            RC.gearSwapState.lastEquippedSet  = nil
            RC.gearSwapState.postCombatSet    = nil
            RC.gearSwapState.lastBossTarget   = nil
            RC.gearSwapState.engagedInCombat  = nil
            RC.gearSwapState.engagedBossGUID  = nil
            RC.gearSwapState._postSwapActiveSet   = nil
            RC.gearSwapState._postSwapActiveUntil = nil
            RC._pendingOnTargetSlots    = nil
            RC._pendingOnTargetReason   = nil
            RC._pendingOnTargetEnchants = nil
        end

        if RC.UpdateFastWeaponReminder then
            C_Timer.After(0.5, function()
                RC:UpdateFastWeaponReminder()
            end)
        end

    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local slotId = ...

        -- 13/14 are the trinket slots. A manual trinket change invalidates that
        -- trinket's readiness cache, its cached buff duration and its per-target
        -- trigger latches, otherwise the new trinket inherits the old state.
        if slotId == 13 or slotId == 14 then
            local itemLink = GetInventoryItemLink("player", slotId)
            local itemId = nil

            if itemLink then
                itemId = tonumber(itemLink:match("item:(%d+)"))
            end

            local slotKey = "slot" .. slotId
            local trinketKey = slotId == 13 and "trinket1" or "trinket2"

            if RC.lastEquippedTrinkets[slotKey] ~= itemId then
                if RC:IsDebugEnabled("trinket") then RC:DebugPrint("Trinket swap detected in " .. trinketKey .. " - clearing trigger tracking", "trinket") end

                abilityReadyCache[trinketKey] = nil

                if RC._trinketBuffDurationCache then
                    RC._trinketBuffDurationCache[slotId] = nil
                end

                -- RC.spellCastTriggers is built by Readycheck_Reminders
                -- (TE_Triggers.lua), which is LoadOnDemand - this file ships
                -- in the base addon and runs whether or not the reminder
                -- stack is loaded. Swapping a trinket before it loads (or
                -- with it disabled) used to error here. The other three
                -- touch points in this file already guard the same way;
                -- these two were the ones that were missed. With no trigger
                -- engine loaded there are no latches to clear, so skipping
                -- is the correct behaviour, not a degraded one.
                local sct = RC.spellCastTriggers
                if sct then
                    if UnitExists("target") then
                        local targetGUID = UnitGUID("target")
                        if targetGUID and sct.usedAbilities
                           and sct.usedAbilities[targetGUID] then
                            sct.usedAbilities[targetGUID][trinketKey] = nil
                            if RC:IsDebugEnabled("trinket") then RC:DebugPrint("Cleared " .. trinketKey .. " tracking for current target", "trinket") end
                        end
                    end
                    if sct.buffRemainingTriggers
                       and sct.buffRemainingTriggers["player"] then
                        sct.buffRemainingTriggers["player"][trinketKey] = nil
                        if RC:IsDebugEnabled("trinket") then RC:DebugPrint("Cleared " .. trinketKey .. " buff_remaining tracking", "trinket") end
                    end
                end

                RC.lastEquippedTrinkets[slotKey] = itemId

                if RC.RefreshTrinketScan then
                    RC:RefreshTrinketScan()
                end
            end
        end

        -- 16/17 are main hand / off hand; the 0.5s delay lets the swap settle
        -- before the weapon-speed reminder re-reads the slots.
        if slotId == 16 or slotId == 17 then
            if RC.UpdateFastWeaponReminder then
                C_Timer.After(0.5, function()
                    RC:UpdateFastWeaponReminder()
                end)
            end
        end

        -- Any equipment change while a boss set is active can be another addon
        -- or a manual swap undoing it; re-assert the on-target set 1.5s later,
        -- re-checking that the same set and same boss are still in play.
        do
            local gs = RC.gearSwapState
            local bossName = gs and gs.lastBossTarget
            if bossName
               and gs.lastEquippedSet
               and not InCombatLockdown()
               and UnitExists("target")
               and not UnitIsDead("target")
               and UnitName("target") == bossName then
                local capturedSet  = gs.lastEquippedSet
                local capturedBoss = bossName
                C_Timer.After(1.5, function()
                    if InCombatLockdown() then return end
                    if not UnitExists("target") or UnitIsDead("target") then return end
                    if UnitName("target") ~= capturedBoss then return end
                    local gs2 = RC.gearSwapState
                    if gs2 and gs2.lastEquippedSet == capturedSet
                       and gs2.lastBossTarget == capturedBoss then
                        RC:EquipGearSetFast(capturedSet, RC:GetOnTargetOverrideSlots(capturedBoss))
                        RC:DebugPrint(
                            "PLAYER_EQUIPMENT_CHANGED: re-equipping on-target set for live boss: "
                            .. capturedSet, "gear")
                    end
                end)
            end
        end

    elseif event == "ENCOUNTER_START" then
        local encounterID, encounterName = ...
        RC:DebugPrint("ENCOUNTER_START: " .. (encounterName or "?"), "trigger")

        -- the next boss is engaged: a gear set picker still up is stale
        if RC.HideGearSetPrompt then RC:HideGearSetPrompt() end

        -- Blizzard's encounter name does not always match the configured boss
        -- key, so match lowercased with a leading "the" stripped. On no match the
        -- raw encounter name is used and raidName stays nil.
        local bossName, raidName = nil, nil
        -- only a configured raid boss of this game version is matched (Core_Flavor)
        if encounterName and RC.raidMobConfigs and RC:FeatureOn("raid_configs") then
            local function strip(s) return s:lower():gsub("^the%s+", "") end
            local lookup = strip(encounterName)
            for raid, bosses in pairs(RC.raidMobConfigs) do
                for bn in pairs(bosses) do
                    if strip(bn) == lookup then
                        bossName = bn
                        raidName = raid
                        break
                    end
                end
                if bossName then break end
            end
            -- a version whose list carries encounter ids (TBC) also matches by id
            if not bossName and RC.RaidBossByEncounterId then
                local hit = RC:RaidBossByEncounterId(encounterID)
                if hit then bossName, raidName = hit.name, hit.raid end
            end
        end
        bossName = bossName or encounterName

        RC.activeEncounterName = bossName
        RC.activeEncounterRaid = raidName
        RC._encounterStartTime = GetTime()

        if RC.lastBossDeathReminder then
            RC.lastBossDeathReminder.bossName = nil
            RC.lastBossDeathReminder.timestamp = 0
        end

        if RC.executeCalculator then
            RC.executeCalculator._seenAnyEncounterStart = true
        end

        if bossName and raidName and RC.executeCalculator then
            local calc = RC.executeCalculator
            if not calc.currentFight or not calc.currentFight.started then
                calc.pendingBossTarget = {
                    name          = bossName,
                    guid          = nil,
                    maxHP         = nil,
                    raidName      = raidName,
                    encounterName = bossName,
                }
            elseif calc.currentFight.started and RC.HasSaygeBuff then
                calc.currentFight.hasSayge = RC:HasSaygeBuff()
                RC:DebugPrint("ENCOUNTER_START: refreshed hasSayge=" .. tostring(calc.currentFight.hasSayge), "execute")
            end
            if calc.currentFight then
                calc.currentFight.encounterStartTime = GetTime()
            end
        end
        if RC.OnExecuteCombatStart then
            RC:OnExecuteCombatStart()
        end

        if bossName and raidName then
            local raidProfile = RC.GetActiveRaidProfile and RC:GetActiveRaidProfile(raidName)
            local bossCfg = raidProfile and raidProfile.bosses and raidProfile.bosses[bossName]
            local gsCfg = bossCfg and bossCfg.abilities and bossCfg.abilities.gearswap
            local gearSet = gsCfg and (gsCfg.gearSet or gsCfg.itemRackSet)
            local postSet = gsCfg and gsCfg.postCombatSet
            -- Seed the swap state from config so a post-combat set still fires
            -- when the player never targeted the boss - ENCOUNTER_START can
            -- arrive before any targeting, and on Heigan or Gothik often does.
            if postSet and postSet ~= "" then
                RC.gearSwapState = RC.gearSwapState or {}
                if not RC.gearSwapState.postCombatSet or RC.gearSwapState.postCombatSet == "" then
                    if gearSet and gearSet ~= "" then
                        RC.gearSwapState.lastEquippedSet = gearSet
                    else
                        RC.gearSwapState.lastEquippedSet = postSet
                    end
                    RC.gearSwapState.postCombatSet = postSet
                    local gsLabel = (gearSet and gearSet ~= "") and gearSet or "(no combat set)"
                    RC:DebugPrint("ENCOUNTER_START: seeded gear swap state '" .. gsLabel .. "' -> '" .. postSet .. "' for " .. bossName, "gear")
                end
                if not RC.gearSwapState.engagedInCombat then
                    RC.gearSwapState.engagedInCombat = bossName
                end
            end
        end

        if RC.RaidRoute and RC.RaidRoute.OnEncounterStart then
            RC.RaidRoute:OnEncounterStart(bossName, raidName)
        end

        C_Timer.After(0.1, function()
            if RC.RunTriggerCheck then RC:RunTriggerCheck() end
        end)

    elseif event == "ENCOUNTER_END" then
        local _, encounterName, _, _, success = ...
        RC:DebugPrint("ENCOUNTER_END: " .. (encounterName or "?") .. " success=" .. tostring(success), "trigger")

        local wasEncounterName = RC.activeEncounterName
        local wasEncounterRaid = RC.activeEncounterRaid
        -- the encounter's start, kept for the kill handler below: a kill
        -- made after the player died has no live fight left to time it from
        RC._endedEncounter = { name = wasEncounterName, raid = wasEncounterRaid, startTime = RC._encounterStartTime }
        RC.activeEncounterName = nil
        RC.activeEncounterRaid = nil
        RC._encounterStartTime = nil

        if RC.executeCalculator and RC.OnExecuteBossKilledByEncounterEnd then
            if success == 1 then
                RC:OnExecuteBossKilledByEncounterEnd(wasEncounterName, wasEncounterRaid)
            else
                if RC.OnExecuteCombatEnd then RC:OnExecuteCombatEnd(true) end
            end
        elseif RC.OnExecuteCombatEnd then
            RC:OnExecuteCombatEnd(true)
        end

        if success == 1 and encounterName and RC.OnBossUnitDied then
            RC:OnBossUnitDied(nil, encounterName)
        end

        -- a boss set to ask which gear set to wear next (TE_GearSwap)
        if success == 1 and RC.CheckGearSetPrompt then
            RC:CheckGearSetPrompt(wasEncounterName or encounterName, wasEncounterRaid)
        end

        if RC.RaidRoute and RC.RaidRoute.OnEncounterEnd then
            RC.RaidRoute:OnEncounterEnd(wasEncounterName or encounterName, success)
        end

        -- PLAYER_REGEN_ENABLED can land before ENCOUNTER_END. If it did, the
        -- post-combat swap never ran because the state was still armed, so
        -- fire it here now that the kill is confirmed.
        if success == 1
           and RC.gearSwapState
           and RC.gearSwapState.postCombatSet
           and RC.gearSwapState.postCombatSet ~= ""
           and not InCombatLockdown()
           and RC.FireDeathGearSwap then
            RC:DebugPrint(
                "ENCOUNTER_END: firing deferred post-combat swap (regen fired before encounter end)",
                "gear")
            RC:FireDeathGearSwap()
        end

        if success == 1 and RC.gearSwapState
           and RC.gearSwapState.postCombatSet
           and RC.gearSwapState.postCombatSet ~= ""
           and not RC.gearSwapState.engagedInCombat then
            RC.gearSwapState.engagedInCombat = wasEncounterName
            RC:DebugPrint("ENCOUNTER_END kill: re-stamped engagedInCombat for " .. tostring(wasEncounterName), "gear")
        end

        -- 5s after the kill, confirm the post-combat gear actually landed.
        -- _verifyGen is stamped now and re-checked then, so a new encounter
        -- starting inside that window cancels this pass.
        if success == 1 and wasEncounterName then
            RC.gearSwapState = RC.gearSwapState or {}
            RC.gearSwapState._verifyGen = (RC.gearSwapState._verifyGen or 0) + 1
            local _vgen = RC.gearSwapState._verifyGen
            local _vboss = wasEncounterName
            C_Timer.After(5, function()
                if RC.VerifyPostCombatGear then RC:VerifyPostCombatGear(_vboss, _vgen) end
            end)
        end

        -- Wipe: release the boss trinket lock and clear the engage dedupe so the
        -- next pull re-runs the full engage instead of hitting the 30s guard.
        if success == 0 then
            if RC.bossTrinketState
               and RC.bossTrinketState.appliedBoss
               and RC.ReleaseBossTrinketLock
            then
                RC:ReleaseBossTrinketLock("ENCOUNTER_END wipe")
            end

            if RC.gearSwapState then
                RC.gearSwapState.engageHandledBoss = nil
                RC.gearSwapState.engageHandledTime = nil
                RC.gearSwapState.engagedInCombat = nil
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
        RC.activeEncounterName = nil
        RC.activeEncounterRaid = nil
        RC._encounterStartTime = nil
        if RC.executeCalculator then
            RC.executeCalculator._seenAnyEncounterStart = nil
        end
        if RC.GetEffectiveRaidName then
            RC.currentRaid = RC:GetEffectiveRaidName()
        else
            local z = GetRealZoneText()
            RC.currentRaid = RC.raidZoneMap and RC.raidZoneMap[z] or nil
        end
        if RC:IsDebugEnabled("trigger") then
            RC:DebugPrint("Zone update: currentRaid=" .. tostring(RC.currentRaid), "trigger")
        end

    end
        end)

        local trinket1Link = GetInventoryItemLink("player", 13)
        local trinket2Link = GetInventoryItemLink("player", 14)

        if trinket1Link then
            RC.lastEquippedTrinkets.slot13 = tonumber(trinket1Link:match("item:(%d+)"))
        end
        if trinket2Link then
            RC.lastEquippedTrinkets.slot14 = tonumber(trinket2Link:match("item:(%d+)"))
        end
    end

    RC.lastBossDeathReminder = {
        bossName = nil,
        timestamp = 0
    }
