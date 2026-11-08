------------------------------------------------------------------------
-- Readycheck - Trigger Engine Core
-- Evaluates a boss's ability config every tick and raises reminders.
-- Config path: raid profile -> bosses[encounter] or trash[mob] -> abilities[key].
-- Ability key is a spell shorthand ("deathwish", "trinket1", "potion",
--   "frostBlast") or an item ID as string or number.
-- Required per ability: enabled, triggerType. Exactly one threshold field
--   applies per triggerType: hp_percent->hpValue, player_hp->playerHpValue,
--   player_hp_above->playerHpAboveValue, ttk->ttkValue, rage_threshold->rageValue,
--   buff_remaining->buffRemainingValue (or buffTimeRemaining) plus optional
--   buffName, debuff_present->debuffName, combat_start->combatStartDelay,
--   encounter_start->encounterStartDelay. ability_ready takes none.
-- Optional anywhere: textOverride, customMessage, equipAfterDeath, utilityType,
--   and potionType which is mandatory for potion keys.
-- Latches live in RC.spellCastTriggers, keyed per target GUID.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local GetTime, UnitGUID, UnitHealth, UnitHealthMax = GetTime, UnitGUID, UnitHealth, UnitHealthMax
-- WoW Forever hides health in combat ("secret" values that may not be
-- compared or used in arithmetic): read as 0 there. issecretvalue does not
-- exist on the other clients, so nothing changes on them.
if issecretvalue then
    local rawHP, rawMax = UnitHealth, UnitHealthMax
    UnitHealth = function(u) local v = rawHP(u) if issecretvalue(v) then return 0 end return v end
    UnitHealthMax = function(u) local v = rawMax(u) if issecretvalue(v) then return 0 end return v end
end
local UnitExists, UnitIsDead, UnitName = UnitExists, UnitIsDead, UnitName
local UnitAffectingCombat = UnitAffectingCombat
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
-- Live aliases of the tables created in TE_GearSwap, which loads first.
local reuseVisibleIcons, abilityMetaCache, abilityReadyCache, ABILITY_READY_TTL =
      _tes.reuseVisibleIcons, _tes.abilityMetaCache, _tes.abilityReadyCache, _tes.ABILITY_READY_TTL
local debugTriggerEnabled, debugDismissalEnabled, debugGearEnabled = false, false, false
do
    local prevSync = RC.SyncTriggerDebugFlags
    local function MySync()
        if prevSync then prevSync() end
        if RC.debugCategories then
            debugTriggerEnabled   = RC.debugCategories.trigger   and RC.debugCategories.trigger.enabled   or false
            debugDismissalEnabled = RC.debugCategories.dismissal and RC.debugCategories.dismissal.enabled or false
            debugGearEnabled      = RC.debugCategories.gear      and RC.debugCategories.gear.enabled      or false
        end
    end
    RC.SyncTriggerDebugFlags = MySync
    MySync()
end

-- Death Wish and Blood Fury apply as debuffs, not buffs, so those are
-- searched in the debuff list first. An explicit buffName in the
-- config overrides this map; unmapped keys fall back to the key text.
local BUFF_NAME_MAP = {
    ["deathwish"] = {name = "Death Wish", isDebuff = true},
    ["recklessness"] = {name = "Recklessness", isDebuff = false},
    ["bloodfury"] = {name = "Blood Fury", isDebuff = true},
    ["berserking"] = {name = "Berserking", isDebuff = false},
    ["mightyrage"] = {name = "Mighty Rage", isDebuff = false},
    ["enrage"] = {name = "Enrage", isDebuff = false},
    ["flurry"] = {name = "Flurry", isDebuff = false},
    -- Trinkets have no generic buff name, so they inherit Death Wish;
    -- set buffName on the ability to track the real trinket proc.
    ["trinket1"] = {name = "Death Wish", isDebuff = true},
    ["trinket2"] = {name = "Death Wish", isDebuff = true},
}

-- Tri-state result: true = inside the window, false = present but
-- still too long, nil = not found. Callers must distinguish false
-- from nil or a debuff miss would silently fall through to buffs.
-- list is RC.Auras:Buffs() or RC.Auras:Debuffs() (the shared aura read).
local function CheckBuffRemainingAura(self, list, auraType, searchBuff, remainingThreshold)
    local buffCount = #list
    local searchLower = searchBuff:lower()
    for _, a in ipairs(list) do
        local name, duration, expirationTime = a.name, a.duration, a.expirationTime

        local nameLower = name:lower()

        if nameLower:find(searchLower, 1, true) then
            if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining: FOUND %s '%s' (duration=%s, expTime=%s)",
                auraType, name, tostring(duration), tostring(expirationTime)), "trigger") end

            if expirationTime and expirationTime > 0 then
                local remaining = expirationTime - GetTime()

                local willTrigger = (remaining > 0 and remaining <= remainingThreshold)
                if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining COMPARE: '%s' remaining=%.2fs, threshold=%d, result=%s (%.2f <= %d = %s)",
                    name, remaining, remainingThreshold,
                    tostring(willTrigger),
                    remaining, remainingThreshold,
                    tostring(remaining <= remainingThreshold)), "trigger") end

                if willTrigger then
                    if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining TRIGGERED: '%s' has %.2fs remaining (<= %ds)",
                        name, remaining, remainingThreshold), "trigger") end
                    return true, remaining
                elseif remaining > 0 then
                    return false, remaining
                else
                    if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining EXPIRED: '%s' remaining=%.2fs (expired)",
                        name, remaining), "trigger") end
                end
            else
                if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining: '%s' has no expiration time (permanent buff?)",
                    name), "trigger") end
            end
        end
    end
    if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining: checked %d %ss, '%s' not found",
        buffCount, auraType, searchBuff), "trigger") end
    return nil, 0
end

-- Synthetic keys raised by TE_Reminders. They are not in any mobConfig,
-- so a normal tick would drop them; carry them forward instead. Combat
-- start (PLAYER_REGEN_DISABLED) is what actually clears them.
local PERSISTENT_REMINDER_KEYS = { equipReminder = true, preTargetConsumable = true }

-- Shared Oil of Immolation fire path for RunTriggerCheck: computes
-- conditionsMet once and, when met, marks the ability used and queues
-- it. latchTable is the once-per-GUID table for bosses (nil for trash,
-- which may repeat).
local function FireOilOfImmolation(self, abilitySettings, triggerTarget, currentTime,
                                   abilityKey, targetGUID, abilitiesToShow, latchTable, debugLabel)
    local conditionsMet = false

    if abilitySettings.triggerType == "ability_ready" then
        conditionsMet = true
    elseif abilitySettings.triggerType == "buff_remaining" then
        conditionsMet = self:ShouldTriggerAbility(abilitySettings, triggerTarget, currentTime, abilityKey)
        local playerKey = "player"
        if not self.spellCastTriggers.buffRemainingTriggers[playerKey] then
            self.spellCastTriggers.buffRemainingTriggers[playerKey] = {}
        end
        if conditionsMet and self.spellCastTriggers.buffRemainingTriggers[playerKey][abilityKey] then
            conditionsMet = false
        elseif conditionsMet then
            self.spellCastTriggers.buffRemainingTriggers[playerKey][abilityKey] = true
        else
            self.spellCastTriggers.buffRemainingTriggers[playerKey][abilityKey] = nil
        end
    else
        conditionsMet = self:ShouldTriggerAbility(abilitySettings, triggerTarget, currentTime, abilityKey)
    end

    if conditionsMet then
        if latchTable then latchTable[targetGUID] = true end
        self.spellCastTriggers.usedAbilities[targetGUID][abilityKey] = currentTime
        table.insert(abilitiesToShow, abilityKey)

        if debugTriggerEnabled then self:DebugPrint(debugLabel, "trigger") end
    end
end
    -- buff_remaining needs a countdown, which UNIT_AURA cannot provide (it only
    -- fires on aura add/remove). A 1s ticker does the work instead, and only
    -- while in combat or running a simulation.
    function RC:StartBuffRemainingMonitor()
        if self.buffRemainingMonitor then return end

        local fn = function()
            local inCombat = UnitAffectingCombat("player") or (RC.activeSimulation ~= nil)
            if not inCombat then return end

            self:CheckBuffRemainingTriggers()
        end

        if RC.Profiler and RC.Profiler.TrackTicker then
            self.buffRemainingMonitor = RC.Profiler:TrackTicker("TriggerEngine:BuffRemainingCheck", 1.0, fn)
        else
            self.buffRemainingMonitor = C_Timer.NewTicker(1.0, fn)
        end

        if debugTriggerEnabled then self:DebugPrint("Started buff remaining monitor (1s interval)", "trigger") end
    end

    function RC:StopBuffRemainingMonitor()
        if self.buffRemainingMonitor then
            self.buffRemainingMonitor:Cancel()
            self.buffRemainingMonitor = nil
            if debugTriggerEnabled then self:DebugPrint("Stopped buff remaining monitor", "trigger") end
        end
    end

    function RC:CheckBuffRemainingTriggers()
        if not self.db or not self.db.enabled then return end

        -- Stamped by RunTriggerCheck off the ability meta cache. An explicit
        -- false means this encounter has no buff_remaining ability at all;
        -- nil means not yet resolved, so the pass still runs.
        if RC._currentEncounterHasBuffRemaining == false then return end

        local currentRaid = RC.currentRaid
        if not currentRaid then
            currentRaid = self.GetEffectiveRaidName and self:GetEffectiveRaidName() or nil
        end
        if not currentRaid then return end

        local triggerTarget = self:GetCurrentTargetData()
        local encounterName = nil
        local targetGUID = nil

        if triggerTarget then
            targetGUID = triggerTarget.guid
            if triggerTarget.encounterType == "boss" then
                encounterName = self:GetEncounterNameForBoss(currentRaid, triggerTarget.name)
            else
                encounterName = triggerTarget.name
            end
        end

        local mobConfig = nil
        if encounterName then
            mobConfig = self:GetMobConfig(currentRaid, encounterName)
        end

        -- Buff timers keep running when the boss is untargeted, so fall back to
        -- the last resolved encounter and then to the ENCOUNTER_START name.
        -- Both use the synthetic "player_buff_check" key for latch tracking.
        if not mobConfig and self.lastKnownEncounter then
            mobConfig = self:GetMobConfig(currentRaid, self.lastKnownEncounter)
            targetGUID = targetGUID or "player_buff_check"
        end

        if not mobConfig and RC.activeEncounterName then
            local activeRaid = RC.activeEncounterRaid or currentRaid
            if activeRaid then
                mobConfig = self:GetMobConfig(activeRaid, RC.activeEncounterName)
                currentRaid = activeRaid
                targetGUID = targetGUID or "player_buff_check"
            end
        end

        if not mobConfig or not mobConfig.enabled or not mobConfig.abilities then return end

        local trackingKey = targetGUID or "player_buff_check"

        if not self.spellCastTriggers.usedAbilities[trackingKey] then
            self.spellCastTriggers.usedAbilities[trackingKey] = {}
        end
        local playerKey = "player"
        if not self.spellCastTriggers.buffRemainingTriggers[playerKey] then
            self.spellCastTriggers.buffRemainingTriggers[playerKey] = {}
        end

        local currentTime = GetTime()
        local abilitiesToShow = {}

        for abilityKey, abilitySettings in pairs(mobConfig.abilities) do
            if abilitySettings.enabled and abilitySettings.triggerType == "buff_remaining" then
                if not self.spellCastTriggers.buffRemainingTriggers[playerKey][abilityKey] then
                    local conditionsMet = self:ShouldTriggerAbility(abilitySettings, triggerTarget, currentTime, abilityKey)

                    if conditionsMet then
                        self.spellCastTriggers.buffRemainingTriggers[playerKey][abilityKey] = true
                        self.spellCastTriggers.usedAbilities[trackingKey][abilityKey] = currentTime
                        table.insert(abilitiesToShow, abilityKey)
                        if debugTriggerEnabled then self:DebugPrint("BuffMonitor: " .. abilityKey .. " triggered!", "trigger") end
                    end
                else
                    local stillMet = self:ShouldTriggerAbility(abilitySettings, triggerTarget, currentTime, abilityKey)
                    if not stillMet then
                        self.spellCastTriggers.buffRemainingTriggers[playerKey][abilityKey] = nil
                        if debugTriggerEnabled then self:DebugPrint("BuffMonitor: " .. abilityKey .. " tracking reset (buff expired/refreshed)", "trigger") end
                    end
                end
            end
        end

        if #abilitiesToShow > 0 then
            RC.pendingTextOverrides = {}
            if mobConfig and mobConfig.abilities then
                for _, ab in ipairs(abilitiesToShow) do
                    local abCfg = mobConfig.abilities[ab]
                    if abCfg and abCfg.textOverride and abCfg.textOverride ~= "" then
                        RC.pendingTextOverrides[ab] = abCfg.textOverride
                    end
                end
            end
            local message = "USE NOW!"
            self:ShowReminder(message, abilitiesToShow)
        end
    end

    -- usedAbilities[guid][key]      = last fire time; per-GUID, so a fresh mob re-arms.
    -- buffRemainingTriggers.player  = latch cleared when the buff leaves the window.
    -- combatStartTriggers[guid]     = once-per-combat latch, wiped on regen-enabled.
    -- oilOfImmolationShown[guid]    = once-per-boss latch, wiped on regen-enabled.
    RC.spellCastTriggers = {
        usedAbilities = {},
        recentCasts = {},
        -- One macro fires several spells across a frame or two; casts inside this
        -- window are replayed together so each icon they satisfy is dismissed.
        macroWindow = 1.5,

        buffRemainingTriggers = {},

        combatStartTriggers = {},

        oilOfImmolationShown = {},

        lastAbilityUse = {}

    }

    RC.targetUpdateCache = {
        lastUpdate = 0,
        cachedData = nil,
        cacheValidFor = 0.25
    }

    RC.encounterCache = {
        targetGUID = nil,
        encounterName = nil,
        mobConfig = nil,
        encounterType = nil,
        isAddOfBoss = nil
    }

    RC.ttkPredictionCache = {
        value = nil,
        confidence = nil,
        lastUpdate = 0,
        cacheValidFor = 2.0
    }

    if not RC.combatState then
        RC.combatState = {
            inCombat = false,
            combatStartTime = 0,
            lastCheck = 0,
            stableForDuration = 0,
            lastStateChange = 0
        }
    end

    function RC:InitializeTriggerSystem()
        if not self.triggerSystem then
            self.triggerSystem = {
                currentTarget = nil,
                updateInterval = 0.1,
                lastUpdate = 0,
                healthCheckInterval = 0.5,
                lastHealthCheck = 0
            }
        end
    end

    function RC:GetCurrentTargetData()
        if self.activeSimulation and self.activeSimulation.mockTarget then
            return self.activeSimulation.mockTarget
        end

        if not UnitExists("target") or UnitIsDead("target") then
            return nil
        end

        local currentTime = GetTime()

        local targetGUID = Readycheck.SafeGUID("target")
        local existingHistory = nil

        if self.targetUpdateCache.cachedData and
           self.targetUpdateCache.cachedData.guid == targetGUID and
           self.targetUpdateCache.cachedData.healthHistory then
            existingHistory = self.targetUpdateCache.cachedData.healthHistory
        end

        if self.targetUpdateCache.lastUpdate > 0 and
           (currentTime - self.targetUpdateCache.lastUpdate) < self.targetUpdateCache.cacheValidFor and
           self.targetUpdateCache.cachedData and
           self.targetUpdateCache.cachedData.guid == targetGUID then
            local cachedData = self.targetUpdateCache.cachedData

            cachedData.currentHP = UnitHealth("target")
            cachedData.currentHPPercent = (cachedData.currentHP / cachedData.maxHP) * 100

            if (currentTime - (cachedData.lastTTKCalc or 0)) >= 0.5 then
                self:CalculateTimeToKill(cachedData)
                cachedData.lastTTKCalc = currentTime
            end

            return cachedData
        end

        if not self.triggerSystem then
            self:InitializeTriggerSystem()
        end

        local targetName = Readycheck.SafeName("target")

        local currentHP = UnitHealth("target")
        local maxHP = UnitHealthMax("target")
        local currentHPPercent = (currentHP / maxHP) * 100

        local healthHistory = existingHistory or {}

        table.insert(healthHistory, {
            hp = currentHP,
            time = currentTime
        })

        -- Amortised trim: let the sample list reach 2x the cap before compacting
        -- back to the newest 50, so the shift costs O(n) once per 50 ticks
        -- instead of a table.remove(1) on every tick.
        local HISTORY_CAP = 50
        if #healthHistory > HISTORY_CAP * 2 then
            local drop = #healthHistory - HISTORY_CAP
            for i = 1, HISTORY_CAP do
                healthHistory[i] = healthHistory[i + drop]
            end
            for i = #healthHistory, HISTORY_CAP + 1, -1 do
                healthHistory[i] = nil
            end
        end

        local targetData = {
            name = targetName,
            guid = targetGUID,
            currentHP = currentHP,
            maxHP = maxHP,
            currentHPPercent = currentHPPercent,
            encounterType = self:DetermineEncounterType(targetName),
            healthHistory = healthHistory,
            estimatedTimeToKill = 999
        }

        self.targetUpdateCache.cachedData = targetData
        self.targetUpdateCache.lastUpdate = currentTime

        self.triggerSystem.currentTarget = targetData

        self:CalculateTimeToKill(targetData)

        return targetData
    end

    -- Returns "boss" or "add" only - anything unrecognised is treated as an add.
    -- The distinction matters: ttk triggers refuse to fire on an "add" target,
    -- and adds of an addPhasesBeforeBoss encounter are gated until boss engage.
    function RC:DetermineEncounterType(targetName)
        if UnitClassification("target") == "worldboss" then
            return "boss"
        end

        if self.IsKnownRaidBoss and self:IsKnownRaidBoss(targetName) then
            return "boss"
        end

        if self.encounterAddPhases then
            for _, info in pairs(self.encounterAddPhases) do
                if info.aliases then
                    for _, alias in ipairs(info.aliases) do
                        if alias == targetName then
                            return "boss"
                        end
                    end
                end
            end
        end

        local raidName = self.GetEffectiveRaidName and self:GetEffectiveRaidName() or nil
        if raidName and self.GetBossFromAdd then
            local parentBoss = self:GetBossFromAdd(raidName, targetName)
            if parentBoss then
                return "add"
            end
        end

        return "add"
    end

    -- GetEncounterNameForBoss, GetDirectBossMatch, GetBossFromAdd and
    -- their resolvers now live in Systems\RaidData\RaidLookup.lua: the
    -- gear stack calls them and must keep working with the reminder
    -- addon switched off.

    -- Thaddius, Garr, Majordomo): reminders on the adds stay suppressed until
    -- the fight record says bossEngaged. Absent fight data counts as not engaged,
    -- unless the player is directly targeting the boss or one of its aliases.
    function RC:IsBossEngagedForEncounter(encounterName)
        if not encounterName then return true end

        local encounterInfo = self.encounterAddPhases and self.encounterAddPhases[encounterName]
        if not encounterInfo or not encounterInfo.addPhasesBeforeBoss then
            return true
        end

        if self.executeCalculator and self.executeCalculator.currentFight then
            local fight = self.executeCalculator.currentFight

            if fight.started and (fight.encounterName == encounterName or fight.targetName == encounterName) then
                if fight.bossEngaged then
                    if debugTriggerEnabled then self:DebugPrint("[ADD PHASE CHECK] Boss IS engaged for " .. encounterName, "trigger") end
                    return true
                else
                    if debugTriggerEnabled then self:DebugPrint("[ADD PHASE CHECK] Boss NOT engaged for " .. encounterName .. " - blocking reminders", "trigger") end
                    return false
                end
            end
        end

        if UnitExists("target") then
            local targetName = Readycheck.SafeName("target")

            if targetName == encounterName then
                return true
            end

            if encounterInfo.aliases then
                for _, alias in ipairs(encounterInfo.aliases) do
                    if targetName == alias then
                        return true
                    end
                end
            end
        end

        if debugTriggerEnabled then self:DebugPrint("[ADD PHASE CHECK] No fight data for " .. encounterName .. " - blocking reminders on adds", "trigger") end
        return false
    end

    local function IsInKTFight()
        local f = _tes.IsInKTFight
        return f and f()
    end

    -- Main pass, run on a 1s ticker plus on target change and combat start.
    -- Order: target data -> raid -> encounter resolve (cached by target GUID)
    -- -> add-phase gate -> per-ability check. There is no first-match short
    -- circuit: every ability whose conditions hold this tick is collected and
    -- shown together, so a boss can raise several icons in one reminder.
    function RC:RunTriggerCheck()
        if debugTriggerEnabled then self:DebugPrint("RunTriggerCheck called", "trigger") end

        if not self.db or not self.db.enabled then
            if debugTriggerEnabled then self:DebugPrint("BLOCKED: Addon disabled", "trigger") end
            return
        end

        local currentTime = GetTime()
        local triggerTarget = self:GetCurrentTargetData()

        if not triggerTarget then
            if debugTriggerEnabled then self:DebugPrint("BLOCKED: No trigger target data", "trigger") end
            return
        end

        if debugTriggerEnabled then self:DebugPrint("Target: " .. tostring(triggerTarget.name) .. " | Type: " .. tostring(triggerTarget.encounterType), "trigger") end

        local targetGUID = triggerTarget.guid
        if not targetGUID then
            if debugTriggerEnabled then self:DebugPrint("BLOCKED: No target GUID", "trigger") end
            return
        end

        if RC.Profiler then RC.Profiler:StartTiming("TriggerEngine") end

        if not self.spellCastTriggers.usedAbilities[targetGUID] then
            self.spellCastTriggers.usedAbilities[targetGUID] = {}
        end

        local playerKey = "player"
        if not self.spellCastTriggers.buffRemainingTriggers[playerKey] then
            self.spellCastTriggers.buffRemainingTriggers[playerKey] = {}
        end

        if not self.spellCastTriggers.combatStartTriggers[targetGUID] then
            self.spellCastTriggers.combatStartTriggers[targetGUID] = {}
        end

        local currentRaid = RC.currentRaid
        if not currentRaid then
            if self.GetEffectiveRaidName then
                currentRaid = self:GetEffectiveRaidName()
            else
                local z = GetRealZoneText()
                currentRaid = self.raidZoneMap and self.raidZoneMap[z] or nil
            end
            if currentRaid then
                RC.currentRaid = currentRaid
            end
        end

        if not currentRaid and self.executeCalculator and self.executeCalculator.testMode.enabled then
            currentRaid = "TEST"
        end
        if not currentRaid and self.activeSimulation then
            currentRaid = self.activeSimulation.raidName or "TEST"
        end

        if not currentRaid then
            if debugTriggerEnabled then self:DebugPrint("BLOCKED: No raid detected", "trigger") end
            if RC.Profiler then RC.Profiler:StopTiming("TriggerEngine") end
            return
        end

        if debugTriggerEnabled then self:DebugPrint("Raid: " .. tostring(currentRaid), "trigger") end

        local encounterName = nil
        local mobConfig = nil
        local isAddOfBoss = false

        -- Encounter resolve is keyed on target GUID alone. TE_Events clears
        -- targetGUID on PLAYER_TARGET_CHANGED and on combat end, which is the
        -- only invalidation - editing a boss config mid-fight will not be seen.
        local cache = self.encounterCache
        if cache.targetGUID == targetGUID then
            encounterName = cache.encounterName
            mobConfig = cache.mobConfig
            isAddOfBoss = cache.isAddOfBoss or false
        else
            if triggerTarget.encounterType == "boss" then
                encounterName = self:GetEncounterNameForBoss(currentRaid, triggerTarget.name)
                mobConfig = self:GetMobConfig(currentRaid, encounterName)
                isAddOfBoss = false
                if self.CheckBossGearSwapWithRetry then
                    self:CheckBossGearSwapWithRetry(triggerTarget.name)
                end
                if debugTriggerEnabled then self:DebugPrint("Boss detected - Encounter name: " .. tostring(encounterName), "trigger") end
            else
                local parentBoss = self:GetBossFromAdd(currentRaid, triggerTarget.name)
                if parentBoss then
                    encounterName = parentBoss
                    mobConfig = self:GetMobConfig(currentRaid, parentBoss)
                    isAddOfBoss = true
                    if self.CheckBossGearSwapWithRetry then
                        self:CheckBossGearSwapWithRetry(triggerTarget.name)
                    end
                    if debugTriggerEnabled then self:DebugPrint("Add detected: " .. triggerTarget.name .. " (Parent: " .. parentBoss .. ")", "trigger") end
                else
                    encounterName = triggerTarget.name
                    mobConfig = self:GetMobConfig(currentRaid, encounterName)
                    if self.CheckTrashGearSwapWithRetry then
                        self:CheckTrashGearSwapWithRetry(triggerTarget.name)
                    end
                    if debugTriggerEnabled and mobConfig then self:DebugPrint("Trash mob detected: " .. triggerTarget.name, "trigger") end
                end
            end
            cache.targetGUID = targetGUID
            cache.encounterName = encounterName
            cache.mobConfig = mobConfig
            cache.encounterType = triggerTarget.encounterType
            cache.isAddOfBoss = isAddOfBoss
        end

        if isAddOfBoss and encounterName then
            if not self:IsBossEngagedForEncounter(encounterName) then
                if debugTriggerEnabled then self:DebugPrint("BLOCKED: Boss not engaged yet for " .. tostring(encounterName) .. " - skipping add reminders", "trigger") end
                if RC.Profiler then RC.Profiler:StopTiming("TriggerEngine") end
                return
            end
        end

        if (not mobConfig or not mobConfig.enabled) and self.executeCalculator and
           self.executeCalculator.testMode.enabled then
            if debugTriggerEnabled then self:DebugPrint("TEST MODE: Using built-in test config for " .. tostring(triggerTarget.name), "trigger") end
            encounterName = triggerTarget.name
            mobConfig = {
                enabled = true,
                abilities = {
                    deathwish = {
                        enabled = true,
                        triggerType = "ttk",
                        ttkValue = 35,
                    },
                    recklessness = {
                        enabled = true,
                        triggerType = "ttk",
                        ttkValue = 20,
                    },
                    trinket1 = {
                        enabled = true,
                        triggerType = "ttk",
                        ttkValue = 5,
                    },
                    trinket2 = {
                        enabled = true,
                        triggerType = "ttk",
                        ttkValue = 5,
                    },
                }
            }
        end

        if not mobConfig or not mobConfig.enabled then
            if debugTriggerEnabled then self:DebugPrint("BLOCKED: No mob config or not enabled for " .. tostring(encounterName), "trigger") end
            if RC.Profiler then RC.Profiler:StopTiming("TriggerEngine") end
            return
        end

        if debugTriggerEnabled then self:DebugPrint("Mob config found for " .. tostring(encounterName) .. " (enabled=" .. tostring(mobConfig.enabled) .. ")", "trigger") end

        if not mobConfig.abilities then
            if debugTriggerEnabled then self:DebugPrint("BLOCKED: No abilities in config for " .. tostring(encounterName), "trigger") end
            if RC.Profiler then RC.Profiler:StopTiming("TriggerEngine") end
            return
        end

        -- Keyed by the config table itself, so a profile reload that rebuilds
        -- the table drops the entry naturally. _keys gives a stable iteration
        -- order and lets the hot loop use ipairs instead of pairs.
        local abilityMeta = abilityMetaCache[mobConfig]
        if not abilityMeta then
            abilityMeta = {
                _keys                   = {},
                hasTTKTrigger           = false,
                hasBuffRemainingAbility = false,
            }
            local n = 0
            for k, cfg in pairs(mobConfig.abilities) do
                local kLower = type(k) == "string" and string_lower(k) or nil
                abilityMeta[k] = {
                    keyLower = kLower,
                    isPotionKey = k == "potion" or (kLower and string_find(kLower, "potion", 1, true)) or false,
                }
                n = n + 1
                abilityMeta._keys[n] = k

                if cfg and cfg.enabled then
                    if cfg.triggerType == "ttk" then
                        abilityMeta.hasTTKTrigger = true
                    elseif cfg.triggerType == "buff_remaining" then
                        abilityMeta.hasBuffRemainingAbility = true
                    end
                end
            end
            abilityMetaCache[mobConfig] = abilityMeta
        end

        RC._currentEncounterHasTTK           = abilityMeta.hasTTKTrigger
        RC._currentEncounterHasBuffRemaining = abilityMeta.hasBuffRemainingAbility

        -- IsAbilityReady walks cooldowns and bags; the 1s TTL keeps a whole
        -- ability sweep from doing that once per ability per tick.
        local now_ar = currentTime
        local function getCachedAbilityReady(key, allowGrace, trigType)
            local entry = abilityReadyCache[key]
            if entry and now_ar < entry.expires then
                return entry.result, entry.grace
            end
            local result, grace = RC:IsAbilityReady(key, allowGrace, trigType)
            abilityReadyCache[key] = { result = result, grace = grace, expires = now_ar + ABILITY_READY_TTL }
            return result, grace
        end

        if debugTriggerEnabled then
            local abilityCount = 0
            local potionCount = 0
            local trinket1Enabled = false
            local trinket2Enabled = false
            for _, abilityKey in ipairs(abilityMeta._keys) do
                local abilitySettings = mobConfig.abilities[abilityKey]
                abilityCount = abilityCount + 1
                local meta = abilityMeta[abilityKey]
                if meta and meta.isPotionKey then
                    potionCount = potionCount + 1
                end
                if abilityKey == "trinket1" then
                    trinket1Enabled = abilitySettings and abilitySettings.enabled == true
                elseif abilityKey == "trinket2" then
                    trinket2Enabled = abilitySettings and abilitySettings.enabled == true
                end
            end
            self:DebugPrint("Found " .. abilityCount .. " abilities for " .. tostring(encounterName) .. " | t1=" .. tostring(trinket1Enabled) .. " t2=" .. tostring(trinket2Enabled), "trigger")
        end

        wipe(reuseAbilitiesToShow)
        local abilitiesToShow = reuseAbilitiesToShow

        for _, abilityKey in ipairs(abilityMeta._keys) do
            local abilitySettings = mobConfig.abilities[abilityKey]
            local meta = abilityMeta[abilityKey]
            local abilityKeyLower = meta and meta.keyLower or (type(abilityKey) == "string" and string_lower(abilityKey) or nil)
            local isPotionKey = meta and meta.isPotionKey or (abilityKey == "potion" or (abilityKeyLower and string_find(abilityKeyLower, "potion", 1, true)))

            if isPotionKey and debugTriggerEnabled then
                self:DebugPrint(string_format("Checking potion: %s | enabled=%s | triggerType=%s | potionType=%s",
                    tostring(abilityKey),
                    tostring(abilitySettings.enabled),
                    tostring(abilitySettings.triggerType),
                    tostring(abilitySettings.potionType)), "trigger")
            end

            local shouldSkipThisAbility = false

            -- Potion keys are indirect: the config key names the slot, potionType
            -- names the actual item. Without a potionType there is nothing to
            -- check readiness against, so the entry is skipped entirely.
            if isPotionKey then
                if abilitySettings.enabled ~= true then
                    shouldSkipThisAbility = true

                    if debugTriggerEnabled then
                    self:DebugPrint(string_format("SKIPPING %s: Potion not enabled (enabled=%s)",
                        tostring(abilityKey), tostring(abilitySettings.enabled)), "trigger")
                    end
                elseif not abilitySettings.triggerType or abilitySettings.triggerType == "" then
                    shouldSkipThisAbility = true

                    if debugTriggerEnabled then
                    self:DebugPrint(string_format("SKIPPING %s: Potion enabled but no triggerType (triggerType=%s)",
                        tostring(abilityKey), tostring(abilitySettings.triggerType)), "trigger")
                    end
                elseif not abilitySettings.potionType or abilitySettings.potionType == "" then
                    shouldSkipThisAbility = true

                    if debugTriggerEnabled then
                    self:DebugPrint(string_format("SKIPPING %s: Potion enabled but no potionType configured (potionType=%s)",
                        tostring(abilityKey), tostring(abilitySettings.potionType)), "trigger")
                    end
                else

                    if debugTriggerEnabled then
                    self:DebugPrint(string_format("PROCESSING %s: Potion valid (enabled=%s, triggerType=%s, potionType=%s)",
                        tostring(abilityKey),
                        tostring(abilitySettings.enabled),
                        tostring(abilitySettings.triggerType),
                        tostring(abilitySettings.potionType)), "trigger")
                    end
                end
            end

            -- Polarity Mode (Readycheck_Features) owns damage cooldowns on
            -- Sapphiron; it takes precedence over any per-boss config here.
            if not shouldSkipThisAbility and RC.PolaritySuppressesAbility
               and RC:PolaritySuppressesAbility(abilityKey, encounterName) then
                shouldSkipThisAbility = true
                if debugTriggerEnabled then
                    self:DebugPrint(string_format("SKIPPING %s: Polarity Mode owns this on Sapphiron",
                        tostring(abilityKey)), "trigger")
                end
            end

            if not shouldSkipThisAbility and abilitySettings.enabled then
                local shouldProcess = true

                if abilityKey == "utility" and not abilitySettings.utilityType then
                    shouldProcess = false
                end

                local numericItemId = tonumber(abilityKey)
                if numericItemId and self.utilityItems and self.utilityItems[numericItemId] then
                    shouldProcess = true
                end

                if shouldProcess then
                    local displayAbilityKey = abilityKey
                    if isPotionKey and abilitySettings.potionType then
                        displayAbilityKey = abilitySettings.potionType
                    end
                    if numericItemId and RC.TARGET_DUMMY_IDS
                       and RC.TARGET_DUMMY_IDS[numericItemId]
                       and GetItemCount and (GetItemCount(numericItemId) or 0) == 0 then
                        local carried = RC.ResolveTargetDummy and RC:ResolveTargetDummy()
                        if carried and carried ~= numericItemId
                           and (GetItemCount(carried) or 0) > 0 then
                            displayAbilityKey = tostring(carried)
                        end
                    end

                    if debugTriggerEnabled then
                    self:DebugPrint(string_format("Checking ability: %s (enabled=%s, triggerType=%s)",
                        tostring(abilityKey),
                        tostring(abilitySettings.enabled),
                        tostring(abilitySettings.triggerType)), "trigger")
                    end

                    -- No per-ability rearm cooldown here: re-fire is prevented
                    -- downstream by the duplicate check on abilitiesToShow and
                    -- by the reminder frame itself.
                    local shouldTrigger = true
                    if debugTriggerEnabled then self:DebugPrint(string_format("  %s: Checking conditions", tostring(abilityKey)), "trigger") end

                    if shouldTrigger then
                        local checkAbilityKey = abilityKey
                        if isPotionKey and abilitySettings.potionType then
                            checkAbilityKey = abilitySettings.potionType

                            if debugTriggerEnabled then self:DebugPrint(string_format("  %s: Potion detected, checking readiness of type: %s",
                                tostring(abilityKey), tostring(checkAbilityKey)), "trigger") end
                        end

                        local triggerType = abilitySettings.triggerType

                        -- Default threshold splits by intent: 20% for potions
                        -- (emergency use), 85% for everything else. Under 1% the
                        -- mob is already dying, so a cooldown there is wasted.
                        if triggerType == "hp_percent" then
                            local defaultThreshold = isPotionKey and 20 or 85
                            local threshold = abilitySettings.hpValue or defaultThreshold

                            if triggerTarget.currentHPPercent < 1 then
                                shouldTrigger = false
                                if debugTriggerEnabled then self:DebugPrint(string_format("  %s: BLOCKED - target is dead/dying (HP: %.1f%%)",
                                    tostring(abilityKey), triggerTarget.currentHPPercent), "trigger") end
                            else
                                local hpConditionMet = triggerTarget.currentHPPercent <= threshold

                                if debugTriggerEnabled then self:DebugPrint(string_format("  %s: HP%% trigger - current HP: %.1f%%, threshold: %d%%, met: %s",
                                    tostring(abilityKey), triggerTarget.currentHPPercent, threshold, tostring(hpConditionMet)), "trigger") end

                                if not hpConditionMet then
                                    shouldTrigger = false
                                    if debugTriggerEnabled then self:DebugPrint(string_format("  %s: BLOCKED - HP not at threshold (%.1f%% > %d%%)",
                                        tostring(abilityKey), triggerTarget.currentHPPercent, threshold), "trigger") end
                                else
                                    local isReady = getCachedAbilityReady(checkAbilityKey, true, triggerType)
                                    if debugTriggerEnabled then self:DebugPrint(string_format("  %s: HP at threshold, ability ready: %s",
                                        tostring(abilityKey), tostring(isReady)), "trigger") end
                                    if not isReady then
                                        shouldTrigger = false
                                        if debugTriggerEnabled then self:DebugPrint(string_format("  %s: BLOCKED - not ready at HP threshold (%.1f%%)",
                                            tostring(abilityKey), triggerTarget.currentHPPercent), "trigger") end
                                    end
                                end
                            end

                        elseif triggerType == "buff_remaining" then
                            if debugTriggerEnabled then self:DebugPrint(string_format("  %s: buff_remaining trigger - will check buff duration",
                                tostring(abilityKey)), "trigger") end

                        elseif triggerType == "ability_ready" then
                            local isReady = getCachedAbilityReady(checkAbilityKey, true, triggerType)
                            if debugTriggerEnabled then self:DebugPrint(string_format("  %s: ability_ready trigger, ready: %s",
                                tostring(abilityKey), tostring(isReady)), "trigger") end
                            if not isReady then
                                shouldTrigger = false
                            end

                        -- frostBlast is the only player_hp_above user that is
                        -- fight-scoped; IsInKTFight lives in TE_Encounters and is
                        -- reached lazily through RC._tes because that file loads later.
                        elseif triggerType == "player_hp_above" then
                            if abilityKey == "frostBlast" and not IsInKTFight() then
                                shouldTrigger = false
                            else
                                local playerHP = UnitHealth("player")
                                local hpThreshold = abilitySettings.playerHpAboveValue or 8500
                                local conditionMet = playerHP > hpThreshold
                                if debugTriggerEnabled then self:DebugPrint(string_format("  %s: player_hp_above - HP=%d, threshold=%d, met=%s",
                                    tostring(abilityKey), playerHP, hpThreshold, tostring(conditionMet)), "trigger") end
                                if not conditionMet then
                                    shouldTrigger = false
                                end
                            end

                        elseif triggerType == "ttk" then
                            local isReady = getCachedAbilityReady(checkAbilityKey, true, triggerType)

                            if (checkAbilityKey == "trinket1" or checkAbilityKey == "trinket2") and debugTriggerEnabled then
                                local slotNum = checkAbilityKey == "trinket1" and 1 or 2
                                local slotId = checkAbilityKey == "trinket1" and 13 or 14
                                local hasOnUseCached = slotNum == 1 and self.trinketData.slot1.hasOnUse or self.trinketData.slot2.hasOnUse
                                local itemId = GetInventoryItemID("player", slotId)
                                self:DebugPrint(string_format("  %s: TTK trinket check - itemId=%s, hasOnUse(cached)=%s, ready=%s",
                                    tostring(checkAbilityKey), tostring(itemId), tostring(hasOnUseCached), tostring(isReady)), "trigger")
                            else
                                if debugTriggerEnabled then self:DebugPrint(string_format("  %s: ttk trigger, ability ready: %s",
                                    tostring(abilityKey), tostring(isReady)), "trigger") end
                            end

                            if not isReady then
                                shouldTrigger = false
                            end

                        -- Once per combat per target GUID. The latch is set the
                        -- moment the delay elapses, ready or not, so a cooldown
                        -- that was down at that instant is skipped for the fight.
                        -- Anchor preference: bossEngageTime, fight startTime,
                        -- then raw combatStartTime - so a trash pull that rolls
                        -- into the boss still measures from the boss engage.
                        elseif triggerType == "combat_start" then

                            if not self.spellCastTriggers.combatStartTriggers[targetGUID] then
                                self.spellCastTriggers.combatStartTriggers[targetGUID] = {}
                            end

                            if self.spellCastTriggers.combatStartTriggers[targetGUID][abilityKey] then
                                shouldTrigger = false
                                if debugTriggerEnabled then self:DebugPrint(string_format("  %s: combat_start already processed for this combat",
                                    tostring(abilityKey)), "trigger") end
                            else
                                local delay = abilitySettings.combatStartDelay or abilitySettings.combatTime or 0
                                local timeSinceCombatStart = 0
                                local _fightCS = self.executeCalculator and self.executeCalculator.currentFight
                                local _inCombatNow = self.combatState and self.combatState.inCombat
                                local _csAnchor = (_inCombatNow and self.combatState.combatStartTime) or 0
                                local _anchor   = _csAnchor
                                if _inCombatNow and _fightCS and _fightCS.started then
                                    local be = _fightCS.bossEngageTime
                                    local st = _fightCS.startTime
                                    if be and be > 0 and be >= _csAnchor then
                                        _anchor = be
                                    elseif st and st > 0 and st >= _csAnchor then
                                        _anchor = st
                                    end
                                end
                                if _anchor > 0 then
                                    timeSinceCombatStart = currentTime - _anchor
                                end

                                if _anchor > 0 and timeSinceCombatStart >= delay then
                                    self.spellCastTriggers.combatStartTriggers[targetGUID][abilityKey] = true

                                    local isReady = getCachedAbilityReady(checkAbilityKey, true, triggerType)
                                    if debugTriggerEnabled then self:DebugPrint(string_format("  %s: combat_start time reached (%.1fs), ability ready: %s",
                                        tostring(abilityKey), timeSinceCombatStart, tostring(isReady)), "trigger") end

                                    if not isReady then
                                        shouldTrigger = false
                                    end
                                else
                                    shouldTrigger = false
                                end
                            end

                        -- Same latch shape as combat_start but boss-only: it
                        -- needs a direct boss config match, and it always anchors
                        -- on raw combatStartTime rather than the boss engage.
                        elseif triggerType == "encounter_start" then
                            if not self.spellCastTriggers.encounterStartTriggers then
                                self.spellCastTriggers.encounterStartTriggers = {}
                            end
                            if not self.spellCastTriggers.encounterStartTriggers[targetGUID] then
                                self.spellCastTriggers.encounterStartTriggers[targetGUID] = {}
                            end

                            if self.spellCastTriggers.encounterStartTriggers[targetGUID][abilityKey] then
                                shouldTrigger = false
                            else
                                local raidName = self:GetEffectiveRaidName()
                                local targetName = triggerTarget.name
                                local bossMatch = (raidName and targetName and self.GetDirectBossMatch)
                                    and self:GetDirectBossMatch(raidName, targetName) or nil
                                if not bossMatch then
                                    shouldTrigger = false
                                else
                                    local delay = abilitySettings.encounterStartDelay or abilitySettings.combatTime or 0
                                    local timeSinceCombatStart = 0
                                    if self.combatState and self.combatState.combatStartTime and self.combatState.combatStartTime > 0 then
                                        timeSinceCombatStart = currentTime - self.combatState.combatStartTime
                                    end
                                    if timeSinceCombatStart >= delay then
                                        self.spellCastTriggers.encounterStartTriggers[targetGUID][abilityKey] = true
                                        local isReady = getCachedAbilityReady(checkAbilityKey, true, triggerType)
                                        if not isReady then shouldTrigger = false end
                                    else
                                        shouldTrigger = false
                                    end
                                end
                            end

                        -- Selectable in the settings UI but never fired: nothing
                        -- in the addon raises a reminder for encounter_end.
                        elseif triggerType == "encounter_end" then
                            shouldTrigger = false

                        else
                            local isReady = getCachedAbilityReady(checkAbilityKey, true, triggerType)
                            if debugTriggerEnabled then self:DebugPrint(string_format("  %s: trigger type '%s', ability ready: %s",
                                tostring(abilityKey), tostring(triggerType), tostring(isReady)), "trigger") end
                            if not isReady then
                                shouldTrigger = false
                            end
                        end
                    end

                    -- Oil of Immolation is a pre-pull item, so it has its own
                    -- path: skipped when the item is not carried or the player is
                    -- already in combat, and on a boss it is once per target GUID
                    -- via oilOfImmolationShown. On trash it may repeat.
                    if shouldTrigger then
                        local isOilOfImmolation = (type(abilityKey) == "number" and abilityKey == 8956) or
                                                  (type(abilityKey) == "string" and abilityKey == "8956")

                        if isOilOfImmolation then
                            if GetItemCount and GetItemCount(8956) == 0 then
                                if debugTriggerEnabled then self:DebugPrint("Skipping Oil of Immolation - not in bags", "trigger") end
                                shouldTrigger = false
                            else
                            local isInCombat = UnitAffectingCombat("player")
                            if isInCombat then
                                if debugTriggerEnabled then self:DebugPrint("Skipping Oil of Immolation - in combat", "trigger") end
                            else
                                local raidSettings = self:GetActiveRaidProfile(currentRaid)
                                local isBossConfig = raidSettings and raidSettings.bosses and raidSettings.bosses[encounterName]

                                if isBossConfig then
                                    if not self.spellCastTriggers.oilOfImmolationShown then
                                        self.spellCastTriggers.oilOfImmolationShown = {}
                                    end

                                    if not self.spellCastTriggers.oilOfImmolationShown[targetGUID] then
                                        FireOilOfImmolation(self, abilitySettings, triggerTarget, currentTime,
                                            abilityKey, targetGUID, abilitiesToShow,
                                            self.spellCastTriggers.oilOfImmolationShown,
                                            "Oil of Immolation shown for BOSS (once per boss)")
                                    else
                                        if debugTriggerEnabled then self:DebugPrint("Skipping Oil of Immolation - already shown for this boss", "trigger") end
                                    end
                                else
                                    FireOilOfImmolation(self, abilitySettings, triggerTarget, currentTime,
                                        abilityKey, targetGUID, abilitiesToShow, nil,
                                        "Oil of Immolation shown for TRASH")
                                end
                            end
                            end
                        else
                            local conditionsMet = false

                            if abilitySettings.triggerType == "ability_ready" then
                                conditionsMet = true
                            elseif abilitySettings.triggerType == "buff_remaining" then
                                conditionsMet = self:ShouldTriggerAbility(abilitySettings, triggerTarget, currentTime, abilityKey)

                                local playerKey = "player"
                                if not self.spellCastTriggers.buffRemainingTriggers[playerKey] then
                                    self.spellCastTriggers.buffRemainingTriggers[playerKey] = {}
                                end

                                if conditionsMet then
                                    if self.spellCastTriggers.buffRemainingTriggers[playerKey][abilityKey] then
                                        conditionsMet = false
                                        if debugTriggerEnabled then self:DebugPrint(string_format("  %s: buff_remaining already triggered, blocking duplicate",
                                            tostring(abilityKey)), "trigger") end
                                    else
                                        self.spellCastTriggers.buffRemainingTriggers[playerKey][abilityKey] = true
                                        if debugTriggerEnabled then self:DebugPrint(string_format("  %s: buff_remaining triggered, marking as fired",
                                            tostring(abilityKey)), "trigger") end
                                    end
                                else
                                    self.spellCastTriggers.buffRemainingTriggers[playerKey][abilityKey] = nil
                                end
                            elseif abilitySettings.triggerType == "combat_start" then
                                conditionsMet = true
                                if debugTriggerEnabled then self:DebugPrint(string_format("  %s: combat_start - proceeding with trigger",
                                    tostring(abilityKey)), "trigger") end
                            else
                                conditionsMet = self:ShouldTriggerAbility(abilitySettings, triggerTarget, currentTime, abilityKey)
                            end

                            if conditionsMet and self:IsConsumableBuffActive(displayAbilityKey) then
                                conditionsMet = false
                                if debugTriggerEnabled then self:DebugPrint("SKIPPED: " .. tostring(displayAbilityKey) .. " - its buff is already active", "trigger") end
                            end

                            if conditionsMet then
                                self.spellCastTriggers.usedAbilities[targetGUID][abilityKey] = currentTime
                                local alreadyAdded = false
                                for _, existingAbility in ipairs(abilitiesToShow) do
                                    if existingAbility == displayAbilityKey then
                                        alreadyAdded = true
                                        break
                                    end
                                end
                                if not alreadyAdded then
                                    table.insert(abilitiesToShow, displayAbilityKey)
                                    if debugTriggerEnabled then self:DebugPrint("TRIGGERED: " .. displayAbilityKey .. " - Conditions met", "trigger") end

                                    if self.activeSimulation then
                                        if not self.activeSimulation.buffActivationTimes then
                                            self.activeSimulation.buffActivationTimes = {}
                                        end
                                        local buffKey = abilityKey:lower():gsub(" ", "")
                                        self.activeSimulation.buffActivationTimes[buffKey] = currentTime
                                        if debugTriggerEnabled then self:DebugPrint("SIM: Recorded buff activation for " .. buffKey, "trigger") end
                                    end
                                else
                                    if debugTriggerEnabled then self:DebugPrint("SKIPPED DUPLICATE: " .. displayAbilityKey .. " (already in list)", "trigger") end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Persistent keys are the synthetic reminders raised by TE_Reminders
        -- (PERSISTENT_REMINDER_KEYS at module scope). They are not in any
        -- mobConfig, so a normal tick would drop them; carry them forward
        -- instead. Combat start (PLAYER_REGEN_DISABLED) actually clears them.
        if self.activeReminderData and self.activeReminderData.abilities then
            for _, activeKey in ipairs(self.activeReminderData.abilities) do
                if PERSISTENT_REMINDER_KEYS[activeKey] then
                    local alreadyPresent = false
                    for _, k in ipairs(abilitiesToShow) do
                        if k == activeKey then alreadyPresent = true; break end
                    end
                    if not alreadyPresent then
                        table.insert(abilitiesToShow, activeKey)
                    end
                end
            end
        end

        if self.activeReminderData and self.activeReminderData.abilities
            and #self.activeReminderData.abilities > 0
            and self.abilityData then
            local removedAny = false
            for i = #self.activeReminderData.abilities, 1, -1 do
                local activeKey = self.activeReminderData.abilities[i]
                local aData = self.abilityData[activeKey]
                -- Item reminders self-dismiss the moment the item goes on
                -- cooldown. allowGrace is false here on purpose: with grace on,
                -- a just-used item still reads ready and the icon would linger.
                if aData and aData.isItem then
                    local ready = self:IsAbilityReady(activeKey, false)
                    if not ready then
                        table.remove(self.activeReminderData.abilities, i)
                        removedAny = true
                        if debugTriggerEnabled then
                            self:DebugPrint("Item monitor: auto-dismissed " .. tostring(activeKey), "dismissal")
                        end
                    end
                end
            end
            if removedAny then
                if #self.activeReminderData.abilities == 0 then
                    self:SmartDismissReminder("Item used (auto-monitor)")
                else
                    self:UpdateReminderWithRemainingAbilities()
                end
            end
        end

        if #abilitiesToShow > 0 then
            if debugTriggerEnabled then self:DebugPrint("Showing reminder for abilities: " .. table.concat(abilitiesToShow, ", "), "trigger") end
            RC.pendingTextOverrides = {}
            if mobConfig and mobConfig.abilities then
                for _, ab in ipairs(abilitiesToShow) do
                    local abCfg = mobConfig.abilities[ab]
                    if abCfg and abCfg.textOverride and abCfg.textOverride ~= "" then
                        RC.pendingTextOverrides[ab] = abCfg.textOverride
                    end
                end
            end
            local message = RCL["Use Abilities Now!"]
            self:ShowReminder(message, abilitiesToShow)
        end

        if RC.Profiler then RC.Profiler:StopTiming("TriggerEngine") end
    end

    -- Second stage of the check. RunTriggerCheck has already vetted the ability
    -- is off cooldown; this answers only whether the trigger's own condition
    -- holds right now. Unknown trigger types return false.
    function RC:ShouldTriggerAbility(abilitySettings, triggerTarget, currentTime, abilityKey)
        local triggerType = abilitySettings.triggerType

        if triggerType == "hp_percent" then
            local threshold = abilitySettings.hpValue or 85
            local result = triggerTarget.currentHPPercent <= threshold
            if debugTriggerEnabled then self:DebugPrint("HP check: " .. triggerTarget.currentHPPercent .. " <= " .. threshold .. " = " .. tostring(result), "trigger") end
            return result

        elseif triggerType == "combat_start" then
            local delay = abilitySettings.combatStartDelay or abilitySettings.combatTime or 0

            if not self.combatState or not self.combatState.inCombat
               or self.combatState.combatStartTime == 0 then
                if debugTriggerEnabled then self:DebugPrint("combat_start: Combat not started yet", "trigger") end
                return false
            end

            local fight = self.executeCalculator and self.executeCalculator.currentFight
            local anchorTime = self.combatState.combatStartTime
            if fight and fight.started then
                if fight.addPhasesBeforeBoss then
                    if not fight.bossEngaged then
                        if debugTriggerEnabled then self:DebugPrint(string_format("combat_start [%s]: BLOCKED - pre-boss add phase, waiting for boss engage", tostring(abilityKey)), "trigger") end
                        return false
                    end
                end
                local csStamp = self.combatState.combatStartTime
                if fight.bossEngageTime and fight.bossEngageTime > 0 and fight.bossEngageTime >= csStamp then
                    anchorTime = fight.bossEngageTime
                elseif fight.startTime and fight.startTime > 0 and fight.startTime >= csStamp then
                    anchorTime = fight.startTime
                end
            end

            local timeSinceCombatStart = currentTime - anchorTime
            local result = timeSinceCombatStart >= delay
            if debugTriggerEnabled then self:DebugPrint(string_format("combat_start: timeSinceAnchor=%.1f, delay=%d, result=%s",
                timeSinceCombatStart, delay, tostring(result)), "trigger") end
            return result

        -- ttk is boss-only: blocked on adds and during a pre-boss add phase,
        -- since burning cooldowns to kill trash early is never the intent.
        elseif triggerType == "ttk" then
            local fight = self.executeCalculator and self.executeCalculator.currentFight
            if fight and fight.started and fight.addPhasesBeforeBoss and not fight.bossEngaged then
                if debugTriggerEnabled then self:DebugPrint(string_format("TTK trigger [%s]: BLOCKED - pre-boss add phase, boss not yet engaged", tostring(abilityKey)), "trigger") end
                return false
            end
            if triggerTarget.encounterType == "add" then
                if debugTriggerEnabled then self:DebugPrint(string_format("TTK trigger [%s]: BLOCKED - target is add/trash, not the boss", tostring(abilityKey)), "trigger") end
                return false
            end

            -- No number saved means the same default the ability page shows
            -- (an offset of 3 on a trinket, 30 seconds otherwise).
            local ttkOffset = abilitySettings.ttkValue
                or (RC.TTKDefaultValue and RC:TTKDefaultValue(abilityKey)) or 30
            local currentTTK = triggerTarget.estimatedTimeToKill
            local ttkThreshold = ttkOffset

            -- Trinkets must be popped early enough for the whole buff to land,
            -- so their threshold is buff duration plus the configured offset.
            -- 20s is the fallback when the trinket is in neither the static table
            -- nor the scanner's auto-detected results. The cache remembers
            -- which trinket it was worked out for, so a swap is never planned
            -- with the old trinket's buff length.
            local buffDuration = 0
            if abilityKey == "trinket1" or abilityKey == "trinket2" then
                local slotId = (abilityKey == "trinket1") and 13 or 14

                if not RC._trinketBuffDurationCache then
                    RC._trinketBuffDurationCache = {}
                end
                local itemNow = GetInventoryItemID("player", slotId)
                local cached = RC._trinketBuffDurationCache[slotId]
                if type(cached) == "table" and cached.id == itemNow then
                    buffDuration = cached.dur
                else
                    if RC.GetTTKTrinketBuffDuration then
                        buffDuration = RC:GetTTKTrinketBuffDuration(slotId)
                    else
                        buffDuration = 20
                    end
                    RC._trinketBuffDurationCache[slotId] = { id = itemNow, dur = buffDuration }
                end

                ttkThreshold = buffDuration + ttkOffset
                if debugTriggerEnabled then self:DebugPrint(string_format("TTK trinket: %s slot=%d buffDur=%d offset=%d threshold=%d",
                    abilityKey, slotId, buffDuration, ttkOffset, ttkThreshold), "trigger") end
            end

            if not RC.inCombat and not UnitAffectingCombat("player") then
                if debugTriggerEnabled then self:DebugPrint(string_format("TTK trigger [%s]: BLOCKED - not in combat", tostring(abilityKey)), "trigger") end
                return false
            end

            local hasTTK = currentTTK ~= nil
            local belowThreshold = hasTTK and (currentTTK <= ttkThreshold)
            local aboveZero = hasTTK and (currentTTK > 0)
            local validTTK = hasTTK and (currentTTK < 999)

            local hasReliableTTK = true
            local calc = self.executeCalculator
            if not currentTTK or currentTTK >= 999 then
                hasReliableTTK = false
                if debugTriggerEnabled then self:DebugPrint(string_format("TTK trigger [%s]: WAIT - no valid TTK computed yet", tostring(abilityKey)), "trigger") end
            -- The DPS estimate is noise for the first few seconds of a fight;
            -- 5s is the minimum sample before a TTK number is trusted. 999 is
            -- the sentinel for "no prediction yet".
            elseif calc and calc.currentFight and calc.currentFight.bossEngaged then
                local fightDuration = GetTime() - (calc.currentFight.bossEngageTime or GetTime())
                if fightDuration < 5 then
                    hasReliableTTK = false
                    if debugTriggerEnabled then self:DebugPrint(string_format("TTK trigger [%s]: WAIT - fight too short (%.1fs), need 5s+ for stable DPS", tostring(abilityKey), fightDuration), "trigger") end
                end
            end

            local result = hasTTK and belowThreshold and aboveZero and validTTK and hasReliableTTK

            if debugTriggerEnabled then
                if not hasTTK then
                    self:DebugPrint(string_format("TTK trigger [%s]: FAIL - currentTTK is nil", tostring(abilityKey)), "trigger")
                elseif not validTTK then
                    self:DebugPrint(string_format("TTK trigger [%s]: FAIL - currentTTK=%d is 999 (no valid prediction)", tostring(abilityKey), currentTTK), "trigger")
                elseif not hasReliableTTK then
                elseif not belowThreshold then
                    self:DebugPrint(string_format("TTK trigger [%s]: WAIT - currentTTK=%.1fs > threshold=%ds", tostring(abilityKey), currentTTK, ttkThreshold), "trigger")
                elseif result then
                    self:DebugPrint(string_format("TTK trigger [%s]: FIRE - currentTTK=%.1fs <= threshold=%ds (buffDur=%d)", tostring(abilityKey), currentTTK, ttkThreshold, buffDuration), "trigger")
                end
            end
            return result

        elseif triggerType == "rage_threshold" then
            local playerRage = UnitPower("player", 1)
            if Readycheck.IsSecret(playerRage) then return false end   -- (hidden on WoW Forever)
            local rageThreshold = abilitySettings.rageValue or 20
            return playerRage <= rageThreshold

        elseif triggerType == "player_hp" then
            local playerHP = (UnitHealth("player") / UnitHealthMax("player")) * 100
            local hpThreshold = abilitySettings.playerHpValue or 40
            return playerHP <= hpThreshold

        elseif triggerType == "player_hp_above" then
            local playerHP = UnitHealth("player")
            local hpThreshold = abilitySettings.playerHpAboveValue or 8500
            return playerHP > hpThreshold

        elseif triggerType == "ability_ready" then
            return true

        elseif triggerType == "buff_remaining" then
            local remainingThreshold = abilitySettings.buffRemainingValue or abilitySettings.buffTimeRemaining or 5

            if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining CHECK: abilityKey=%s, threshold=%ds (from buffRemainingValue=%s, buffTimeRemaining=%s)",
                tostring(abilityKey), remainingThreshold,
                tostring(abilitySettings.buffRemainingValue),
                tostring(abilitySettings.buffTimeRemaining)), "trigger") end

            if self.activeSimulation and self.activeSimulation.buffActivationTimes then
                local sim = self.activeSimulation

                local trackedBuff = "deathwish"
                local buffDuration = 30

                if abilityKey == "trinket1" or abilityKey == "trinket2" then
                    trackedBuff = "deathwish"
                    buffDuration = 30
                elseif abilityKey == "deathwish" then
                    trackedBuff = "deathwish"
                    buffDuration = 30
                elseif abilityKey == "recklessness" then
                    trackedBuff = "recklessness"
                    buffDuration = 15
                elseif abilityKey == "bloodfury" then
                    trackedBuff = "bloodfury"
                    buffDuration = 25
                elseif abilityKey == "berserking" then
                    trackedBuff = "berserking"
                    buffDuration = 10
                end

                local buffStartTime = sim.buffActivationTimes[trackedBuff]
                if buffStartTime then
                    local buffElapsed = GetTime() - buffStartTime
                    local buffRemaining = buffDuration - buffElapsed

                    if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining SIM: %s tracking %s, elapsed=%.1f, remaining=%.1f, threshold=%d",
                        abilityKey, trackedBuff, buffElapsed, buffRemaining, remainingThreshold), "trigger") end

                    if buffRemaining > 0 and buffRemaining <= remainingThreshold then
                        return true
                    end
                else
                    if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining SIM: %s waiting for %s to be cast",
                        abilityKey, trackedBuff), "trigger") end
                end
                return false
            end

            local searchBuff
            local checkDebuff = false

            if abilitySettings.buffName and abilitySettings.buffName ~= "" then
                searchBuff = abilitySettings.buffName
                for _, data in pairs(BUFF_NAME_MAP) do
                    if data.name == searchBuff then
                        checkDebuff = data.isDebuff
                        break
                    end
                end
                if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining: using configured buffName='%s'", searchBuff), "trigger") end
            else
                local mapped = BUFF_NAME_MAP[abilityKey]
                if mapped then
                    searchBuff = mapped.name
                    checkDebuff = mapped.isDebuff
                    if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining: mapped abilityKey '%s' to buff '%s'",
                        tostring(abilityKey), searchBuff), "trigger") end
                else
                    searchBuff = abilitySettings.customMessage or abilityKey or "Unknown"
                    if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining: no mapping for '%s', using fallback '%s'",
                        tostring(abilityKey), searchBuff), "trigger") end
                end
            end

            if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining: searching for '%s' (isDebuff=%s), threshold=%ds",
                searchBuff, tostring(checkDebuff), remainingThreshold), "trigger") end

            -- CheckBuffRemainingAura (module scope) is tri-state: true =
            -- inside the window, false = present but still too long, nil =
            -- not found. False must not fall through to the next list.
            if checkDebuff then
                if debugTriggerEnabled then self:DebugPrint("buff_remaining: checking debuffs first (Death Wish is a debuff)", "trigger") end
                local found = CheckBuffRemainingAura(self, RC.Auras:Debuffs(), "debuff", searchBuff, remainingThreshold)
                if found == true then return true end
                if found == false then return false end
            end

            if debugTriggerEnabled then self:DebugPrint("buff_remaining: checking buffs", "trigger") end
            local found = CheckBuffRemainingAura(self, RC.Auras:Buffs(), "buff", searchBuff, remainingThreshold)
            if found == true then return true end
            if found == false then return false end

            if not checkDebuff then
                if debugTriggerEnabled then self:DebugPrint("buff_remaining: also checking debuffs as fallback", "trigger") end
                found = CheckBuffRemainingAura(self, RC.Auras:Debuffs(), "debuff", searchBuff, remainingThreshold)
                if found == true then return true end
                if found == false then return false end
            end

            if debugTriggerEnabled then self:DebugPrint(string_format("buff_remaining: '%s' not found on player - not triggering", searchBuff), "trigger") end
            return false

        elseif triggerType == "debuff_present" then
            local debuffName = abilitySettings.debuffName
            if not debuffName or debuffName == "" then
                if debugTriggerEnabled then self:DebugPrint("debuff_present trigger missing debuffName", "trigger") end
                return false
            end

            local want = debuffName:lower()
            for _, d in ipairs(RC.Auras:Debuffs()) do
                if d.name:lower():find(want, 1, true) then
                    if debugTriggerEnabled then self:DebugPrint("Debuff found: " .. d.name .. " (looking for: " .. debuffName .. ")", "trigger") end
                    return true
                end
            end

            return false

        else
            return false
        end
    end

    -- Rearm for one target: clears its used-ability and combat_start latches
    -- plus the shared player buff_remaining latch. TE_Events replaces the
    -- combat_start and buff_remaining tables outright on combat end.
    function RC:ResetSpellCastTriggers(targetGUID)
        if targetGUID and self.spellCastTriggers.usedAbilities[targetGUID] then
            self.spellCastTriggers.usedAbilities[targetGUID] = {}
        end
        if self.spellCastTriggers.buffRemainingTriggers["player"] then
            self.spellCastTriggers.buffRemainingTriggers["player"] = {}
        end
        if targetGUID and self.spellCastTriggers.buffRemainingTriggers[targetGUID] then
            self.spellCastTriggers.buffRemainingTriggers[targetGUID] = {}
        end
        if targetGUID and self.spellCastTriggers.combatStartTriggers[targetGUID] then
            self.spellCastTriggers.combatStartTriggers[targetGUID] = {}
        end
    end

    -- Dismissal side. Every cast inside macroWindow is replayed, so a macro that
    -- fires trinket + Death Wish clears both icons. Removing an icon also clears
    -- its usedAbilities latch, letting the ability re-trigger when it comes back.
    function RC:ProcessSpellCastForDismissal(spellID)
        local currentTime = GetTime()

        if not self.reminderFrame or not self.reminderFrame:IsShown() then
            return
        end

        if not self.activeReminderData or not self.activeReminderData.abilities then
            return
        end

        self.spellCastTriggers.recentCasts[spellID] = currentTime

        wipe(reuseMacroCasts)
        local macroCasts = reuseMacroCasts
        for recentSpellID, castTime in pairs(self.spellCastTriggers.recentCasts) do
            if (currentTime - castTime) <= self.spellCastTriggers.macroWindow then
                table.insert(macroCasts, recentSpellID)
            else
                self.spellCastTriggers.recentCasts[recentSpellID] = nil
            end
        end

        wipe(reuseAbilitiesRemoved)
        local abilitiesRemoved = reuseAbilitiesRemoved

        for _, macroSpellID in ipairs(macroCasts) do
            local castAbilityKey = RC.spellIdMap[macroSpellID]
            local skipNormalProcessing = false

            if not castAbilityKey and RC.utilitySpellIds then
                if debugDismissalEnabled then self:DebugPrint("Checking utility spell ID: " .. macroSpellID, "dismissal") end

                if RC.utilitySpellIds[macroSpellID] then
                local castItemId = RC.utilitySpellIds[macroSpellID]
                if debugDismissalEnabled then self:DebugPrint("Found utility item for spell " .. macroSpellID .. " -> item " .. castItemId, "dismissal") end

                local conflictGroup = nil
                if self.GetConflictGroup then
                    conflictGroup = self:GetConflictGroup(castItemId)
                end

                if debugDismissalEnabled then self:DebugPrint("Current reminder abilities: " .. table.concat(self.activeReminderData.abilities, ", "), "dismissal") end

                for i = #self.activeReminderData.abilities, 1, -1 do
                    local reminderAbilityKey = self.activeReminderData.abilities[i]
                    local reminderItemId = tonumber(reminderAbilityKey)

                    if debugDismissalEnabled then self:DebugPrint("Checking reminder ability: " .. tostring(reminderAbilityKey) .. " (as number: " .. tostring(reminderItemId) .. ") vs castItemId: " .. tostring(castItemId), "dismissal") end

                    local shouldRemove = false

                    if reminderItemId and reminderItemId == castItemId then
                        shouldRemove = true
                        if debugDismissalEnabled then self:DebugPrint("Match found! reminderItemId == castItemId", "dismissal") end
                    end

                    -- Conflict groups cover consumables that overwrite each other
                    -- (one flask, one battle elixir; on TBC a flask fills both
                    -- elixir slots): using any member dismisses the reminders
                    -- for all of them.
                    if not shouldRemove and conflictGroup and reminderItemId then
                        local members = self.ConflictMembers and self:ConflictMembers(conflictGroup)
                        if members then
                            if members[reminderItemId] then
                                shouldRemove = true
                                if debugDismissalEnabled then self:DebugPrint("Removing " .. (self.utilityItems[reminderItemId] and self.utilityItems[reminderItemId].name or reminderItemId) .. " due to conflict group: " .. conflictGroup, "dismissal") end
                            end
                        end
                    end

                    if shouldRemove then
                        table.remove(self.activeReminderData.abilities, i)
                        table.insert(abilitiesRemoved, reminderAbilityKey)
                        if debugDismissalEnabled then self:DebugPrint("Removed utility item: " .. (self.utilityItems[reminderItemId] and self.utilityItems[reminderItemId].name or reminderItemId) .. " (spell ID: " .. macroSpellID .. ")", "dismissal") end

                        local targetGUID = Readycheck.SafeGUID("target")
                        if targetGUID and self.spellCastTriggers.usedAbilities[targetGUID] then
                            self.spellCastTriggers.usedAbilities[targetGUID][tostring(reminderItemId)] = nil
                        end
                        if self.spellCastTriggers.buffRemainingTriggers["player"] then
                            self.spellCastTriggers.buffRemainingTriggers["player"][tostring(reminderItemId)] = nil
                        end
                    end
                end
                skipNormalProcessing = true
                end
            end

            if not castAbilityKey and RC.trinketSpellIds[macroSpellID] then
                for i = #self.activeReminderData.abilities, 1, -1 do
                    local reminderAbilityKey = self.activeReminderData.abilities[i]

                    if reminderAbilityKey == "trinket1" or reminderAbilityKey == "trinket2" then
                        table.remove(self.activeReminderData.abilities, i)
                        table.insert(abilitiesRemoved, reminderAbilityKey)
                        if debugDismissalEnabled then self:DebugPrint("Removed trinket: " .. reminderAbilityKey, "dismissal") end

                        local targetGUID = Readycheck.SafeGUID("target")
                        if targetGUID then
                            if self.spellCastTriggers.usedAbilities[targetGUID] then
                                self.spellCastTriggers.usedAbilities[targetGUID][reminderAbilityKey] = nil
                                if debugDismissalEnabled then self:DebugPrint("Cleared usedAbilities for " .. reminderAbilityKey, "dismissal") end
                            end
                        end
                        if self.spellCastTriggers.buffRemainingTriggers["player"] then
                            self.spellCastTriggers.buffRemainingTriggers["player"][reminderAbilityKey] = nil
                            if debugDismissalEnabled then self:DebugPrint("Cleared buffRemainingTriggers for " .. reminderAbilityKey, "dismissal") end
                        end
                        break
                    end
                end
                skipNormalProcessing = true
            end

            if not skipNormalProcessing and castAbilityKey then
                for i = #self.activeReminderData.abilities, 1, -1 do
                    local reminderAbilityKey = self.activeReminderData.abilities[i]

                    if reminderAbilityKey == castAbilityKey then
                        table.remove(self.activeReminderData.abilities, i)
                        table.insert(abilitiesRemoved, castAbilityKey)
                        if debugDismissalEnabled then self:DebugPrint("Removed ability: " .. castAbilityKey, "dismissal") end

                        local targetGUID = Readycheck.SafeGUID("target")
                        if targetGUID and self.spellCastTriggers.usedAbilities[targetGUID] then
                            self.spellCastTriggers.usedAbilities[targetGUID][castAbilityKey] = nil
                            if debugDismissalEnabled then self:DebugPrint("Cleared tracking for " .. castAbilityKey .. " - can retrigger when CD up", "dismissal") end
                        end
                        if self.spellCastTriggers.buffRemainingTriggers["player"] then
                            self.spellCastTriggers.buffRemainingTriggers["player"][castAbilityKey] = nil
                        end

                        break
                    end

                    if reminderAbilityKey == "potion" and RC.potionSpellIds[macroSpellID] then
                        table.remove(self.activeReminderData.abilities, i)
                        table.insert(abilitiesRemoved, "potion")
                        if debugDismissalEnabled then self:DebugPrint("Removed potion (generic)", "dismissal") end
                        break
                    end

                    if RC.potionSpellIds[macroSpellID] and RC.potionSpellToItem and RC.potionSpellToItem[macroSpellID] then
                        local reminderItemId = tonumber(reminderAbilityKey)
                        local expectedItemId = RC.potionSpellToItem[macroSpellID]

                        if reminderItemId == expectedItemId then
                            table.remove(self.activeReminderData.abilities, i)
                            table.insert(abilitiesRemoved, reminderAbilityKey)
                            if debugDismissalEnabled then self:DebugPrint("Removed potion item " .. reminderItemId .. " (spell " .. macroSpellID .. ")", "dismissal") end
                            break
                        end
                    end
                end
            end
        end

        if #abilitiesRemoved > 0 then
            if debugDismissalEnabled then self:DebugPrint("Removed " .. #abilitiesRemoved .. " abilities", "dismissal") end
            if #self.activeReminderData.abilities == 0 then
                self:SmartDismissReminder("All abilities used")
            else
                self:UpdateReminderWithRemainingAbilities()
            end
        end
    end

    function RC:UpdateReminderWithRemainingAbilities()
        if not self.reminderFrame or not self.reminderFrame:IsShown() then
            return
        end

        if not self.activeReminderData or not self.activeReminderData.abilities or #self.activeReminderData.abilities == 0 then
            self:SmartDismissReminder("No abilities remaining")
            return
        end

        if self.reminderFrame.abilityIcons then
            for i, icon in ipairs(self.reminderFrame.abilityIcons) do
                if icon and icon.abilityKey then
                    local stillActive = false
                    for _, activeAbility in ipairs(self.activeReminderData.abilities) do
                        if icon.abilityKey == activeAbility then
                            stillActive = true
                            break
                        end
                    end

                    if not stillActive and icon:IsShown() then
                        if icon.fadeTimer then
                            icon.fadeTimer:Cancel()
                            icon.fadeTimer = nil
                        end

                        icon:SetAlpha(0)
                        icon:Hide()
                    end
                end
            end

            self.reminderFrame.currentAbilities = {}
            for _, ability in ipairs(self.activeReminderData.abilities) do
                table.insert(self.reminderFrame.currentAbilities, ability)
            end

            local iconSize = self.db.iconSize or 80
            local actualSpacing = self.db.iconSpacing or 5

            wipe(reuseVisibleIcons)
            local visibleIcons = reuseVisibleIcons

            for i, icon in ipairs(self.reminderFrame.abilityIcons) do
                if icon and icon:IsShown() then
                    table.insert(visibleIcons, icon)
                end
            end

            if #visibleIcons > 0 then
                local totalWidth = (#visibleIcons * iconSize) + ((#visibleIcons - 1) * actualSpacing)
                local startX = -(totalWidth / 2) + (iconSize / 2)

                for i, icon in ipairs(visibleIcons) do
                    icon:ClearAllPoints()
                    icon:SetPoint("CENTER", self.reminderFrame, "CENTER", startX + ((i-1) * (iconSize + actualSpacing)), 0)
                end

                self.reminderFrame:SetSize(totalWidth + 40, iconSize + 40)
            end
        end

        if self.activeReminderData.dismissalTimer then
            self.activeReminderData.dismissalTimer:Cancel()
            self.activeReminderData.dismissalTimer = nil
        end
    end

    -- GetMobConfig moved to Systems\RaidData\RaidLookup.lua alongside the
    -- other raid-profile lookups; TrinketSwap reads it on every boss death.

    -- The time-to-kill a TTK trigger compares against.
    -- Once the boss fight is tracked and engaged this is the one shared
    -- estimate (RC:GetTTKRemaining) - the same number the TTK HUD shows and
    -- custom reminders read - worked out fresh on every check from the
    -- fight's own clock, never from whichever unit happens to be targeted.
    -- 999 means "no estimate yet" and holds every TTK trigger.
    -- With no tracked fight (a boss in combat before tracking opens) it
    -- falls back to the old guesses: health% x the usual kill time x 1.1,
    -- then the target's own damage over the last few seconds.
    function RC:CalculateTimeToKill(target)
        if not target then
            return
        end

        local calc = self.executeCalculator
        local fight = calc and calc.currentFight
        if fight and fight.started and fight.bossEngaged and self.GetTTKRemaining then
            local remaining, _, confidence, source = self:GetTTKRemaining()
            if remaining and remaining < 999 then
                target.estimatedTimeToKill = remaining
                if self:IsDebugEnabled("ttk") then
                    self:DebugPrint(string_format("TTK (%s): %.1fs (confidence: %.2f)",
                        tostring(source), remaining, confidence or 0), "ttk")
                end
            else
                target.estimatedTimeToKill = 999
            end
            return
        end

        -- No ttk ability configured here, so skip the history and hand back
        -- a linear estimate off a 120s nominal fight length.
        if RC._currentEncounterHasTTK == false then
            if target.currentHPPercent and target.currentHPPercent > 0 then
                target.estimatedTimeToKill = (target.currentHPPercent / 100) * 120
            end
            return
        end

        if target.currentHPPercent and target.currentHPPercent > 0 then
            local hpRemaining = target.currentHPPercent
            local estimatedTotal = 120

            if calc then
                local raidName = (fight and fight.raidName) or self:GetEffectiveRaidName()
                local encounterName = (fight and fight.encounterName) or target.name
                if raidName and encounterName then
                    local saygeState
                    if fight and fight.started then
                        saygeState = fight.hasSayge and true or false
                    elseif self.HasSaygeBuff then
                        saygeState = self:HasSaygeBuff()
                    end
                    -- cached until the kill history changes
                    local pred = self:PredictTTK(raidName, encounterName, saygeState)
                    if pred and pred > 0 and pred < 600 then
                        estimatedTotal = pred
                    end
                end
            end

            -- 10% pad so the historical estimate errs late rather than early.
            target.estimatedTimeToKill = ((hpRemaining / 100) * estimatedTotal) * 1.1
        end

        if target.healthHistory and #target.healthHistory >= 5 then
            local oldest = target.healthHistory[1]
            local newest = target.healthHistory[#target.healthHistory]
            local timeDiff = newest.time - oldest.time

            if timeDiff > 5 then
                local hpLost = oldest.hp - newest.hp
                if hpLost > 0 then
                    local dps = hpLost / timeDiff
                    local dpsBasedTTK = newest.hp / dps

                    if dpsBasedTTK > 0 and dpsBasedTTK < 600 then
                        target.estimatedTimeToKill = dpsBasedTTK
                        if self:IsDebugEnabled("ttk") then
                            self:DebugPrint(string_format("TTK (DPS): %.1fs (%.0f DPS over %.1fs)",
                                dpsBasedTTK, dps, timeDiff), "ttk")
                        end
                        return
                    end
                end
            end
        end

        if target.estimatedTimeToKill and self:IsDebugEnabled("ttk") then
            self:DebugPrint(string_format("TTK (HP-Based Conservative): %.1fs (%.1f%% HP)",
                target.estimatedTimeToKill, target.currentHPPercent or 0), "ttk")
        end
    end

    -- Suppression check: a consumable whose buff is already up is not worth
    -- reminding about. Potion keys resolve through spellIdMap, item IDs through
    -- GetConsumableBuffId; anything with no known buff ID returns false.
    function RC:IsConsumableBuffActive(abilityKey)
        local checkBuffId = nil
        local isPotionKey = (type(abilityKey) == "string") and abilityKey:lower():find("potion")
        if isPotionKey then
            for spellId, potionName in pairs(RC.spellIdMap or {}) do
                if potionName == abilityKey then
                    if RC.potionBuffIds and RC.potionBuffIds[spellId] then
                        checkBuffId = spellId
                        break
                    end
                end
            end
        else
            local itemId = tonumber(abilityKey)
            if itemId and self.GetConsumableBuffId then
                checkBuffId = self:GetConsumableBuffId(itemId)
            end
        end
        if not checkBuffId then return false end
        local buffName = GetSpellInfo(checkBuffId)
        return buffName ~= nil and RC.Auras:BuffNamed(buffName) ~= nil
    end

