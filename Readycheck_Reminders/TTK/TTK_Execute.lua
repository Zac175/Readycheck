------------------------------------------------------------------------
-- Readycheck - TTK Fight Lifecycle
-- Boss detection, fight start/end, ENCOUNTER_END kill recording and the
-- simulation harness for RC.executeCalculator.
-- OnExecuteTargetChanged / CombatStart / CombatEnd /
-- BossKilledByEncounterEnd are all invoked from Systems/Trigger/
-- TE_Events.lua; the only events wired here are ZONE_CHANGED_NEW_AREA
-- and the PLAYER_REGEN pair that gates the 0.5s execute ticker.
------------------------------------------------------------------------
local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local GetTime, UnitGUID, UnitHealth, UnitHealthMax = GetTime, UnitGUID, UnitHealth, UnitHealthMax
local UnitName, UnitExists = UnitName, UnitExists
local string_format = string.format
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
RC._ttk = RC._ttk or {}
local _ttk = RC._ttk
    function RC:LoadExecuteSettings()
        local charKey = self:GetCharacterKey()

        if not ReadycheckDB or not ReadycheckDB.characters or not ReadycheckDB.characters[charKey] then
            return
        end

        local settings = ReadycheckDB.characters[charKey].executeSettings
        if not settings then return end

        if settings.executeThreshold then
            self.executeCalculator.executeThreshold = settings.executeThreshold
        end

        if settings.collectData ~= nil then
            self.executeCalculator.collectData = settings.collectData
        end

        if settings.dataCollection then
            self.executeCalculator.dataCollection = self.DeepCopy(settings.dataCollection)
            self.executeCalculator.collectData = not self.executeCalculator.dataCollection.disabled
        else
            if not self.executeCalculator.dataCollection then
                self.executeCalculator.dataCollection = { disabled = false, disabledBosses = {} }
            end
            self.executeCalculator.dataCollection.disabled = not self.executeCalculator.collectData
        end

        -- Migration order is load-bearing: fold aliases into canonical
        -- keys first, dedup second, and prune unparseable keys last so
        -- the alias merge still gets a chance at them. The trailing
        -- SaveExecuteSettings persists the migrated shape immediately.
        if settings.fightHistory then
            self.executeCalculator.fightHistory.data = self.DeepCopy(settings.fightHistory)

            self:MigrateFightHistoryAliases()
            self:MigrateFightHistoryPhaseKeys()

            self:DeduplicateFightHistory()

            self:PruneUnrecognizedFightKeys()

            local keyCount = 0
            local fightCount = 0
            for k, v in pairs(self.executeCalculator.fightHistory.data) do
                keyCount = keyCount + 1
                if type(v) == "table" then
                    fightCount = fightCount + #v
                end
            end
            self:DebugPrint("LoadExecuteSettings: Loaded " .. keyCount .. " bosses, " .. fightCount .. " fights", "execute")

            self:SaveExecuteSettings()
        end

        if settings.testModeEnabled ~= nil then
            self.executeCalculator.testMode.enabled = settings.testModeEnabled
        end

        if settings.classicGlobalMultiplier then
            self.executeCalculator.classicMultipliers.global = settings.classicGlobalMultiplier
        end

        if settings.classicBossMultipliers then
            self.executeCalculator.classicMultipliers.perBoss = self.DeepCopy(settings.classicBossMultipliers)
        end

        if settings.ewmaEnabled ~= nil then
            self.executeCalculator.ewma.enabled = settings.ewmaEnabled
        end

        if settings.ewmaAlpha then
            self.executeCalculator.ewma.alpha = settings.ewmaAlpha
        end

        if settings.mlConfig then
            self.executeCalculator.mlConfig = self.DeepCopy(settings.mlConfig)
        end

        if settings.uiSettings then
            self.executeCalculator.uiSettings = self.DeepCopy(settings.uiSettings)
        end

        if settings.mode then
            self.executeCalculator.mode = settings.mode
        end

        self:DebugPrint("Execute settings loaded for character", "execute")
    end

    function RC:OnExecuteTargetChanged()
        local calc = self.executeCalculator

        -- combatContinuous encounters and any server-active encounter
        -- legitimately drop combat between phases, so the out-of-combat
        -- teardown below must not apply to them.
        local inMultiCombatEncounter = calc.currentFight.started
            and (calc.currentFight.isMultiCombatEncounter or RC.activeEncounterName ~= nil)

        if calc.currentFight.started and not UnitAffectingCombat("player") and not inMultiCombatEncounter then
            local shouldResume = false

            if not UnitExists("target") then
                shouldResume = true
                self:DebugPrint("Target lost while out of combat - checking fight state", "trinket")
            elseif UnitIsDead("target") then
                shouldResume = true
                self:DebugPrint("Target dead while out of combat - checking fight state", "trinket")
            else
                local targetName = UnitName("target")
                local isTrackedBoss = (targetName == calc.currentFight.encounterName or
                                       targetName == calc.currentFight.primaryBoss.name)
                if not isTrackedBoss then
                    shouldResume = true
                    self:DebugPrint("Target changed to non-boss while out of combat - checking fight state", "trinket")
                end
            end

            if shouldResume then
                self:DebugPrint("Ending fight tracking - out of combat with no boss target", "execute")
                calc.currentFight.started = false
                calc.pendingBossTarget = nil

                if self.ResumeTrinketSwapAfterBoss then
                    self:ResumeTrinketSwapAfterBoss()
                end
                return
            end
        end

        if not UnitExists("target") or UnitIsDead("target") or
           not UnitCanAttack("player", "target") then
            calc.pendingBossTarget = nil
            return
        end

        local targetName = UnitName("target")

        local isRaidBoss = self:IsKnownRaidBoss(targetName)

        if calc.testMode.enabled then
            isRaidBoss = true
        end

        -- A boss looked at before the pull is only remembered while it is
        -- still the target: moving on to anything else out of combat drops
        -- it, so a trash pull afterwards cannot open a fight on the boss.
        if not isRaidBoss and calc.pendingBossTarget and not UnitAffectingCombat("player")
           and not RC.activeEncounterName then
            calc.pendingBossTarget = nil
        end

        if isRaidBoss then
            self:DebugPrint(string_format("Boss detected: %s (fight.started=%s, bossEngaged=%s)",
                targetName, tostring(calc.currentFight.started), tostring(calc.currentFight.bossEngaged)), "ttk")
        end

        if isRaidBoss and not calc.currentFight.started then
            local raidName = calc.testMode.enabled and calc.testMode.testRaidName or self:GetEffectiveRaidName()
            local encounterName = self:GetEncounterName(targetName, raidName)

            -- Pre-pull latch: record the boss now so OnExecuteCombatStart
            -- can open the fight with the right raid/encounter names the
            -- instant combat starts, even if the player has since
            -- retargeted or the raid pulled before the player did.
            if not UnitAffectingCombat("player") then
                calc.pendingBossTarget = {
                    name = targetName,
                    guid = UnitGUID("target"),
                    maxHP = UnitHealthMax("target"),
                    raidName = raidName,
                    encounterName = encounterName
                }
                self:DebugPrint(string_format("Pre-pull boss pending: %s in %s", encounterName or targetName, raidName or "Unknown"), "ttk")
            else
                local targetData = {
                    name = targetName,
                    guid = UnitGUID("target"),
                    maxHP = UnitHealthMax("target")
                }
                calc.pendingBossTarget = nil
                self:DebugPrint(string_format("Starting fight tracking (in combat): %s in %s", encounterName or targetName, raidName or "Unknown"), "ttk")
                self:StartFightTracking(targetData, raidName, encounterName)
            end
        end

        if calc.currentFight.started and calc.currentFight.addPhasesBeforeBoss and not calc.currentFight.bossEngaged then
            if targetName == calc.currentFight.encounterName or targetName == calc.currentFight.primaryBoss.name then
                local currentHP = UnitHealth("target")
                local maxHP = UnitHealthMax("target")
                if maxHP > 0 and currentHP < maxHP then
                    self:EngageBoss()
                end
            end
        end
    end

    -- Four probes, cheapest first: worldboss classification, canonical
    -- encounterAddPhases entry, an alias of one, then the active raid
    -- profile's boss list matched loosely (lowercased, spaces/hyphens/
    -- apostrophes stripped). Only positives are cached - a negative depends
    -- on the raid profile, which can change without a zone change, and the
    -- cache is only wiped on ZONE_CHANGED_NEW_AREA.
    function RC:IsKnownRaidBoss(targetName)
        if not targetName then return false end

        if not self.bossDetectionCache then
            self.bossDetectionCache = {}
        end

        if self.bossDetectionCache[targetName] ~= nil then
            return self.bossDetectionCache[targetName]
        end

        local result = false

        if UnitExists("target") and UnitName("target") == targetName then
            if UnitClassification("target") == "worldboss" then
                result = true
            end
        end

        if not result and self.encounterAddPhases and self.encounterAddPhases[targetName] then
            result = true
        end

        if not result and self.encounterAddPhases then
            for bossName, config in pairs(self.encounterAddPhases) do
                if config.aliases then
                    for _, alias in ipairs(config.aliases) do
                        if alias == targetName then
                            result = true
                            break
                        end
                    end
                end
                if result then break end
            end
        end

        if not result then
            local raidName = self:GetEffectiveRaidName()
            if raidName and self.GetActiveRaidProfile then
                local raidSettings = self:GetActiveRaidProfile(raidName)
                if raidSettings and raidSettings.bosses then
                    if raidSettings.bosses[targetName] then
                        result = true
                    else
                        local targetNormalized = string.lower(string.gsub(targetName, "[%s%-']+", ""))
                        for configBossName, _ in pairs(raidSettings.bosses) do
                            local configNormalized = string.lower(string.gsub(configBossName, "[%s%-']+", ""))
                            if configNormalized == targetNormalized then
                                result = true
                                break
                            end
                        end
                    end
                end
            end
        end

        if result then
            self.bossDetectionCache[targetName] = result
        end

        return result
    end

    function RC:ClearBossDetectionCache()
        self.bossDetectionCache = {}
    end

    function RC:OnExecuteCombatStart()
        local calc = self.executeCalculator

        -- combatContinuous fights never close on PLAYER_REGEN_ENABLED, so
        -- a wipe can leave one open indefinitely. If a fresh combat opens
        -- with none of that encounter's bosses visible anywhere, the old
        -- fight is stale - force it closed before starting a new one.
        if calc.currentFight and calc.currentFight.started then
            local fight = calc.currentFight
            local encounterConfig = self.encounterAddPhases and self.encounterAddPhases[fight.encounterName]
            if encounterConfig and encounterConfig.combatContinuous then
                local bossNames = {}
                if fight.encounterName then bossNames[fight.encounterName] = true end
                if fight.primaryBoss and fight.primaryBoss.name then bossNames[fight.primaryBoss.name] = true end
                if encounterConfig.aliases and encounterConfig.aliasesAreEncounter then
                    for _, alias in ipairs(encounterConfig.aliases) do
                        bossNames[alias] = true
                    end
                end

                local bossVisible = false
                local function checkUnit(unit)
                    if not UnitExists(unit) or UnitIsDead(unit) then return false end
                    local n = UnitName(unit)
                    return n and bossNames[n] or false
                end
                if checkUnit("target") then bossVisible = true end
                if not bossVisible then
                    for i = 1, 40 do
                        if checkUnit("raid" .. i .. "target") then
                            bossVisible = true
                            break
                        end
                    end
                end

                if not bossVisible then
                    self:DebugPrint("Stale combatContinuous fight detected at combat start (boss '" .. (fight.encounterName or "?") .. "' not visible) - force-ending old fight", "execute")
                    self:OnExecuteCombatEnd(true)
                end
            end
        end

        -- The remembered boss is only trusted if it is actually in this
        -- combat: when it can be seen standing out of combat, the raid has
        -- pulled something else. ENCOUNTER_START (the server saying the
        -- encounter began) always counts.
        if calc.pendingBossTarget and calc.pendingBossTarget.guid and not RC.activeEncounterName then
            local pg = calc.pendingBossTarget.guid
            local function idleBoss(unit)
                return UnitExists(unit) and UnitGUID(unit) == pg and not UnitAffectingCombat(unit)
            end
            local idle = idleBoss("target")
            if not idle then
                for i = 1, 40 do
                    if idleBoss("raid" .. i .. "target") then idle = true break end
                end
            end
            if idle then
                self:DebugPrint("Pre-pull boss " .. tostring(calc.pendingBossTarget.name) .. " is not in this combat - ignoring it", "ttk")
                calc.pendingBossTarget = nil
            end
        end

        if calc.pendingBossTarget then
            local pb = calc.pendingBossTarget
            calc.pendingBossTarget = nil
            local targetData = { name = pb.name, guid = pb.guid, maxHP = pb.maxHP }
            self:DebugPrint(string_format("Starting fight tracking from pre-pull target: %s in %s",
                pb.encounterName or pb.name, pb.raidName or "Unknown"), "ttk")
            self:StartFightTracking(targetData, pb.raidName, pb.encounterName)
            local fight = calc.currentFight
            if fight.started and fight.addPhasesBeforeBoss and not fight.bossEngaged then
                self:StartBossScanTimer()
            end
            return
        end

        if not UnitExists("target") then
            self:ScanForBossOnCombatStart()
        else
            self:OnExecuteTargetChanged()

            if not calc.currentFight.started then
                self:ScanForBossOnCombatStart()
            end
        end

        local fight = calc.currentFight
        if not fight.started or (fight.started and fight.addPhasesBeforeBoss and not fight.bossEngaged) then
            self:StartBossScanTimer()
        end
    end

    -- Backstop for pulls where neither the target nor the raid scan saw
    -- the boss at combat start. 24 scans at 5s gives up after 2 minutes;
    -- it also self-cancels on combat end or once the boss is engaged.
    -- The self.bossScanTimer handle is the single-instance guard.
    function RC:StartBossScanTimer()
        if self.bossScanTimer then return end

        local scanCount = 0
        local maxScans = 24

        local fn = function()
            scanCount = scanCount + 1
            local fight = self.executeCalculator.currentFight

            local shouldStop = false
            if scanCount >= maxScans then shouldStop = true end
            if not UnitAffectingCombat("player") then shouldStop = true end
            if fight.started and fight.bossEngaged then shouldStop = true end

            if shouldStop then
                if self.bossScanTimer then
                    self.bossScanTimer:Cancel()
                    self.bossScanTimer = nil
                end
                return
            end

            if fight.started and fight.addPhasesBeforeBoss and not fight.bossEngaged then
                local bossName = fight.encounterName or fight.primaryBoss.name

                if UnitExists("target") and not UnitIsDead("target") then
                    local targetName = UnitName("target")
                    if targetName == bossName and UnitCanAttack("player", "target") then
                        local currentHP = UnitHealth("target")
                        local maxHP = UnitHealthMax("target")
                        if maxHP > 0 and currentHP < maxHP then
                            self:DebugPrint("Boss now hostile (via target) - engaging: " .. bossName, "execute")
                            self:EngageBoss()
                            return
                        end
                    end
                end

                for i = 1, 40 do
                    local unit = "raid" .. i .. "target"
                    if UnitExists(unit) and not UnitIsDead(unit) then
                        local name = UnitName(unit)
                        if name == bossName and UnitCanAttack("player", unit) then
                            local currentHP = UnitHealth(unit)
                            local maxHP = UnitHealthMax(unit)
                            if maxHP > 0 and currentHP < maxHP then
                                self:DebugPrint("Boss now hostile (via raid scan) - engaging: " .. bossName, "execute")
                                self:EngageBoss()
                                return
                            end
                        end
                    end
                end
            end

            if not fight.started then
                if UnitExists("target") then
                    self:OnExecuteTargetChanged()
                end

                if not self.executeCalculator.currentFight.started then
                    self:ScanForBossOnCombatStart()
                end
            end
        end

        if RC.Profiler and RC.Profiler.TrackTicker then
            self.bossScanTimer = RC.Profiler:TrackTicker("ExecuteCalculator:BossScan", 5, fn)
        else
            self.bossScanTimer = C_Timer.NewTicker(5, fn)
        end
    end

    function RC:ScanForBossOnCombatStart()
        local calc = self.executeCalculator
        if calc.currentFight.started then return end

        -- Requires a resolvable raid name: outside a known raid zone there
        -- is no boss list to match against and no key to store under.
        local raidName = self:GetEffectiveRaidName()
        if not raidName then return end

        self:DebugPrint("Scanning for boss on combat start in " .. raidName, "ttk")

        for i = 1, 40 do
            local unit = "raid" .. i .. "target"
            if UnitExists(unit)
               and not UnitIsDead(unit)
               and UnitAffectingCombat(unit)
            then
                local targetName = UnitName(unit)
                if targetName and self:IsKnownRaidBoss(targetName) then
                    local targetData = {
                        name = targetName,
                        guid = UnitGUID(unit),
                        maxHP = UnitHealthMax(unit)
                    }
                    local encounterName = self:GetEncounterName(targetName, raidName)
                    self:DebugPrint(string_format("Found boss via raid scan: %s", targetName), "ttk")
                    self:StartFightTracking(targetData, raidName, encounterName)
                    return
                end
            end
        end
    end

    function RC:OnExecuteCombatEnd(forceEnd)
        local calc = self.executeCalculator

        if self.bossScanTimer then
            self.bossScanTimer:Cancel()
            self.bossScanTimer = nil
        end

        if not calc.currentFight.started then return end

        local fight = calc.currentFight
        local encounterConfig = self.encounterAddPhases and
                               self.encounterAddPhases[fight.encounterName]

        -- forceEnd is the wipe path (ENCOUNTER_END without success), the
        -- stale-fight close, and the tidy-up after an ENCOUNTER_END kill
        -- that was already recorded. Nothing is recorded here: noRecord
        -- stops EndFightTracking's corpse check, or one dead horseman in a
        -- wiped Four Horsemen would save the wipe as a kill.
        if forceEnd then
            self:DebugPrint("OnExecuteCombatEnd: forced end (ENCOUNTER_END)", "execute")
            calc.currentFight.noRecord = true
            self:EndFightTracking(nil, calc.currentFight.raidName, calc.currentFight.encounterName)
            return
        end

        local targetData = nil

        -- aliasesAreEncounter means every alias is a real boss of this
        -- encounter (Four Horsemen), so any of their corpses counts as
        -- the kill and any of them still alive keeps the fight open.
        local aliasesAreBosses = encounterConfig and encounterConfig.aliasesAreEncounter
        local bossNames = { [fight.encounterName] = true, [fight.primaryBoss.name] = true }
        local aliasList = encounterConfig and encounterConfig.aliases
        if aliasList and aliasesAreBosses then
            for _, alias in ipairs(aliasList) do bossNames[alias] = true end
        end

        local livingAliasFound = false

        if UnitExists("target") and UnitIsDead("target") then
            local name = UnitName("target")
            if bossNames[name] then
                targetData = { guid = UnitGUID("target"), name = name }
                self:DebugPrint("Combat end: Target is dead boss: " .. name, "execute")
            end
        end

        if not targetData then
            for i = 1, 40 do
                local unit = "raid" .. i .. "target"
                if UnitExists(unit) then
                    local name = UnitName(unit)
                    if bossNames[name] then
                        if UnitIsDead(unit) then
                            targetData = { guid = UnitGUID(unit), name = name }
                            self:DebugPrint("Combat end: Found dead boss via raid scan: " .. name, "execute")
                            if not aliasesAreBosses then break end
                        else
                            livingAliasFound = true
                        end
                    end
                end
            end
        end

        -- For continuous encounters, losing combat is not the end of the
        -- fight. With no dead boss, hand off to the 20s stale check; with
        -- one dead but other aliases alive, keep the encounter clock going.
        if encounterConfig and encounterConfig.combatContinuous then
            if not targetData then
                self:DebugPrint("Continuous encounter - tracking continues (no dead boss found)", "execute")
                self:ScheduleStaleFightCleanup(bossNames, calc.currentFight.raidName, calc.currentFight.encounterName)
                return
            end
            if aliasesAreBosses and livingAliasFound then
                self:DebugPrint("Multi-boss encounter - tracking continues (other bosses still alive)", "execute")
                return
            end
        end

        self:EndFightTracking(targetData, calc.currentFight.raidName, calc.currentFight.encounterName)
    end

    -- Last resort for combatContinuous encounters that reset without ever
    -- firing ENCOUNTER_END. After 20s, if the encounter is not
    -- server-active and none of its bosses are visible, close the fight
    -- with no sample recorded. Cancelled by StartFightTracking and
    -- EndFightTracking so it can never fire against a later pull.
    function RC:ScheduleStaleFightCleanup(bossNames, raidName, encounterName)
        local calc = self.executeCalculator
        if not calc then return end

        if calc.staleCleanupTimer then
            calc.staleCleanupTimer:Cancel()
            calc.staleCleanupTimer = nil
        end

        local STALE_CHECK_DELAY = 20

        calc.staleCleanupTimer = C_Timer.NewTimer(STALE_CHECK_DELAY, function()
            calc.staleCleanupTimer = nil

            if not calc.currentFight or not calc.currentFight.started then
                return
            end

            if calc.currentFight.encounterName ~= encounterName then
                return
            end

            if RC.activeEncounterName == encounterName then
                self:DebugPrint("Stale-fight check: encounter still active server-side, keeping tracking", "execute")
                return
            end

            local bossVisible = false
            local function checkUnit(unit)
                if not UnitExists(unit) then return false end
                local n = UnitName(unit)
                return n and bossNames[n] or false
            end
            if checkUnit("target") then bossVisible = true end
            if not bossVisible then
                for i = 1, 40 do
                    if checkUnit("raid" .. i .. "target") then
                        bossVisible = true
                        break
                    end
                end
            end
            if bossVisible then
                self:DebugPrint("Stale-fight check: boss still visible, keeping tracking", "execute")
                return
            end

            self:DebugPrint(string.format(
                RCL["Stale-fight check: encounter '%s' reset (no boss visible), force-ending tracking"],
                encounterName or "?"
            ), "execute")
            self:EndFightTracking(nil, raidName, encounterName)
        end)
    end

    -- ENCOUNTER_END with success == 1, the authoritative kill signal.
    -- Two paths: the fight is still live (normal), or it was already torn
    -- down because the player died and left combat, in which case a start
    -- time has to be reconstructed from whichever stamp survived.
    function RC:OnExecuteBossKilledByEncounterEnd(encounterName, raidName)
        local calc = self.executeCalculator
        if not calc or not calc.collectData then return end

        if encounterName and raidName and self.GetEncounterName then
            local resolved = self:GetEncounterName(encounterName, raidName)
            if resolved and resolved ~= encounterName then
                self:DebugPrint(string.format(
                    RCL["ENCOUNTER_END canonicalize: '%s' -> '%s'"], encounterName, resolved), "execute")
                encounterName = resolved
            end
        end
        -- the same name every other path files this boss under
        if encounterName and raidName then
            encounterName = self:TTKBossName(raidName, encounterName)
        end

        if calc.currentFight.started and calc.currentFight.bossEngaged then
            self:DebugPrint("ENCOUNTER_END kill: fight still active, using normal end path", "execute")
            local fight = calc.currentFight
            local now = GetTime()

            -- Multi-boss encounters time from encounterStartTime; single
            -- bosses time from bossEngageTime so an add phase is excluded.
            -- If engage was never stamped the duration silently includes
            -- the adds, so flag isNeverEngaged and let PredictTTK skip it.
            local encCfg = self.encounterAddPhases and self.encounterAddPhases[fight.encounterName]
            local useEncounterTimer = encCfg and encCfg.aliasesAreEncounter
            local totalFightTime
            local engagementMissing = false
            if useEncounterTimer and fight.encounterStartTime then
                totalFightTime = now - fight.encounterStartTime
                self:DebugPrint(string.format(
                    RCL["Multi-boss encounter - using encounterStartTime (%.1fs)"],
                    totalFightTime), "execute")
            else
                if fight.bossEngageTime and fight.bossEngageTime > 0 then
                    totalFightTime = now - fight.bossEngageTime
                else
                    totalFightTime = now - (fight.encounterStartTime or now)
                    engagementMissing = (encCfg and encCfg.addPhasesBeforeBoss) and true or false
                    if engagementMissing then
                        self:DebugPrint("ENCOUNTER_END kill: bossEngageTime never stamped on addPhasesBeforeBoss encounter - flagging isNeverEngaged so prediction skips it", "execute")
                    end
                end
            end

            local safeRaid = raidName or fight.raidName or "Unknown"
            local safeBoss = encounterName or fight.historyName or fight.encounterName or "Unknown"
            -- The exclusion list is keyed "<raid>_<boss>" with no profile
            -- segment, while storage uses the profile-scoped MakeBossKey:
            -- disabling a boss disables it across every raid profile.
            -- Filed under the config the fight started on.
            local safeProfile = fight.profileName or self:GetActiveProfileNameForRaid(safeRaid)
            local bossKey  = self:MakeBossKey(safeRaid, safeBoss, safeProfile)
            local _dc1 = calc.dataCollection
            if _dc1 and _dc1.disabledBosses and _dc1.disabledBosses[safeRaid .. "_" .. safeBoss] then
                self:DebugPrint("ENCOUNTER_END kill: " .. safeBoss .. " excluded from data collection — skipping save", "execute")
            else
                self:RecordFightKill(bossKey, {
                    timestamp     = time(),
                    encounterName = safeBoss,
                    raidName      = safeRaid,
                    profileName   = safeProfile,
                    totalFightTime = totalFightTime,
                    executeStartHP = fight.executeStartHP,
                    maxHP          = fight.maxHP,
                    isTestFight    = fight.isTestFight,
                    isNeverEngaged = engagementMissing or nil,
                    hasSayge       = fight.hasSayge or self:HasSaygeBuff(),
                }, "ENCOUNTER_END/active")
                self:DebugPrint(string.format(
                    RCL["ENCOUNTER_END kill recorded: %s %.1fs"], safeBoss, totalFightTime), "execute")
                self:SaveExecuteSettings()
            end
            if self.OnExecuteCombatEnd then self:OnExecuteCombatEnd(true) end
            return
        end

        if not raidName or not encounterName then
            self:DebugPrint("ENCOUNTER_END kill: missing encounter info, cannot record", "execute")
            return
        end

        -- Player-died path: currentFight has already been reset, so walk a
        -- preference chain of surviving stamps. Only stamps from THIS
        -- encounter count - a pull of the same boss, started within the
        -- last 15 minutes - or an old fight's (or a /rc sim's) times would
        -- be saved as a kill hours long.
        local nowT = GetTime()
        local function Same(t)
            return t and t.encounterName ~= nil and t.raidName == raidName
                and self:TTKBossName(raidName, t.historyName or t.encounterName) == encounterName
                and not t.isTestFight
        end
        -- the encounter's own start, which TE_Events hands over at the end
        local encStart = RC._encounterStartTime
        local ended = RC._endedEncounter
        if not encStart and ended and ended.name and ended.startTime
           and self:TTKBossName(raidName, ended.name) == encounterName and (nowT - ended.startTime) <= 900 then
            encStart = ended.startTime
        end
        local cf = calc.currentFight
        local sameFight = Same(cf)
        -- the fight already closed at the player's combat end: its clock
        -- was kept for exactly this - as long as it belongs to this pull
        -- (it started after this encounter did), not an earlier wipe
        local lc = calc.lastClosedFight
        if not sameFight and Same(lc) and lc.closedAt and (nowT - lc.closedAt) < 900 then
            local lcStart = lc.encounterStartTime or lc.startTime or lc.bossEngageTime
            if not encStart or (lcStart and lcStart >= encStart - 10) then
                cf, sameFight = lc, true
            end
        end
        local function Fresh(t)
            if not (sameFight and t and t > 0) then return nil end
            if nowT - t > 900 then return nil end
            return t
        end
        local cfg = self.encounterAddPhases and self.encounterAddPhases[encounterName]
        local useEncounterTimer = cfg and cfg.aliasesAreEncounter
        local startTime
        local engagementMissing = false
        if useEncounterTimer then
            startTime = Fresh(cf.encounterStartTime)
                     or encStart
                     or Fresh(cf.bossEngageTime)
                     or Fresh(cf.startTime)
        else
            local engageTime = Fresh(cf.bossEngageTime)
            if engageTime then
                startTime = engageTime
            else
                startTime = Fresh(cf.encounterStartTime)
                         or Fresh(cf.startTime)
                         or encStart
                engagementMissing = (cfg and cfg.addPhasesBeforeBoss) and true or false
                if engagementMissing then
                    self:DebugPrint("ENCOUNTER_END kill (player-died): bossEngageTime never stamped - flagging isNeverEngaged", "execute")
                end
            end
        end

        if not startTime then
            self:DebugPrint("ENCOUNTER_END kill: no start time available, skipping", "execute")
            return
        end

        local totalFightTime = GetTime() - startTime
        if totalFightTime <= 0 then return end

        local diedProfile = (sameFight and cf.profileName) or self:GetActiveProfileNameForRaid(raidName)
        local bossKey = self:MakeBossKey(raidName, encounterName, diedProfile)
        local _dc2 = calc.dataCollection
        if _dc2 and _dc2.disabledBosses and _dc2.disabledBosses[raidName .. "_" .. encounterName] then
            self:DebugPrint("ENCOUNTER_END kill (player-died): " .. encounterName .. " excluded from data collection — skipping save", "execute")
        else
            self:RecordFightKill(bossKey, {
                timestamp      = time(),
                encounterName  = encounterName,
                raidName       = raidName,
                profileName    = diedProfile,
                totalFightTime = totalFightTime,
                isNeverEngaged = engagementMissing or nil,
                isTestFight    = false,
                hasSayge       = (sameFight and cf.hasSayge) or self:HasSaygeBuff(),
            }, "ENCOUNTER_END/playerDied")
            self:DebugPrint(string.format(
                RCL["ENCOUNTER_END kill recorded (player-died path): %s %.1fs"],
                encounterName, totalFightTime), "execute")
            self:SaveExecuteSettings()
        end

        -- The fight was still open (an add-phase boss whose engage was never
        -- seen): close it the normal way so trinket swapping resumes. The
        -- kill is already saved above, so nothing is recorded there.
        if calc.currentFight.started then
            calc.currentFight.noRecord = true
            self:EndFightTracking(nil, calc.currentFight.raidName, calc.currentFight.encounterName)
            return
        end

        calc.currentFight = {
            started = false, bossEngaged = false,
            encounterName = nil, raidName = nil,
            primaryBoss = {name=nil, guid=nil, maxHP=0},
            startTime = nil, bossEngageTime = nil, encounterStartTime = nil,
            enterExecuteTime = 0, maxHP = 0, executeStartHP = 0,
            addPhasesBeforeBoss = false, isMultiCombatEncounter = false, isTestFight = false,
        }
    end

    -- kill-time tracking reads enemy health, which Forever hides in
    -- combat (Core_Flavor)
    if not RC.executeTTKFrame and RC:FeatureOn("ttk") then
        RC.executeTTKFrame = CreateFrame("Frame")

        RC.executeTTKFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

        RC.executeTTKFrame:SetScript("OnEvent", function(self, event, ...)
            if event == "ZONE_CHANGED_NEW_AREA" then
                RC:ClearBossDetectionCache()
            end
        end)

        -- The only polling loop in this subsystem. Both calls read unit
        -- health directly; neither may be moved onto UNIT_HEALTH or CLEU.
        local executeTickerFn = function()
            if RC.executeCalculator.currentFight.started then
                if RC.Profiler then RC.Profiler:StartTiming("ExecuteTicker") end
                RC:UpdateEncounterUnits()
                RC:CheckExecutePhase()
                RC:ScanRaidForBoss()
                if RC.Profiler then RC.Profiler:StopTiming("ExecuteTicker") end
            end
        end

        local function StartExecuteTicker()
            if RC.executeCheckTicker then return end
            if RC.Profiler and RC.Profiler.TrackTicker then
                RC.executeCheckTicker = RC.Profiler:TrackTicker("Execute:Check", 0.5, executeTickerFn)
            else
                RC.executeCheckTicker = C_Timer.NewTicker(0.5, executeTickerFn)
            end
        end

        local function StopExecuteTicker()
            if RC.executeCheckTicker then
                RC.executeCheckTicker:Cancel()
                RC.executeCheckTicker = nil
            end
        end

        -- Combat gate: the 40-unit raid sweep stays completely idle out of
        -- combat. InCombatLockdown below covers a /reload taken mid-fight.
        local combatGate = CreateFrame("Frame")
        combatGate:RegisterEvent("PLAYER_REGEN_DISABLED")
        combatGate:RegisterEvent("PLAYER_REGEN_ENABLED")
        combatGate:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_REGEN_DISABLED" then
                StartExecuteTicker()
            elseif event == "PLAYER_REGEN_ENABLED" then
                StopExecuteTicker()
            end
        end)

        if InCombatLockdown() then
            StartExecuteTicker()
        end
    end

    if RC:FeatureOn("ttk") then RC:InitializeBossUnitTracking() end

    -- Manual and bulk-import entry point. fightTime is bounded to 5-900s;
    -- executeStartHP and maxHP are synthetic filler so the record shape
    -- matches a real kill, but only totalFightTime and hasSayge reach the
    -- model. Inserts directly rather than through RecordFightKill, so the
    -- 5s dedup cannot collapse a bulk paste into one entry.
    -- classToken: the class the kills were played on; nil means this
    -- character's class, false means none recorded.
    -- stamp: the kill's timestamp (nil = now). A paste gives each kill its
    -- own second, or kills of the same length would read as one copy.
    function RC:AddManualKillTime(bossName, fightTime, raidName, silent, hasSayge, profileName, classToken, stamp)
        if not fightTime or type(fightTime) ~= "number" then
            if not silent then
                self:Print(RCL["|cffff0000Error:|r Invalid fight time - must be a number"])
            end
            return nil
        end

        if fightTime < 5 then
            if not silent then
                self:Print(RCL["|cffff0000Error:|r Fight time too short (minimum 5 seconds)"])
            end
            return nil
        end

        if fightTime > 900 then
            if not silent then
                self:Print(RCL["|cffff0000Error:|r Fight time too long (maximum 900 seconds / 15 minutes)"])
            end
            return nil
        end

        raidName = raidName or "Manual"
        bossName = self:TTKBossName(raidName, bossName)

        local calc = self.executeCalculator
        if profileName == "" then profileName = nil end
        local bossKey = self:MakeBossKey(raidName, bossName, profileName)

        local fightData = {
            timestamp = stamp or time(),
            encounterName = bossName,
            raidName = raidName,
            profileName = profileName or self:GetActiveProfileNameForRaid(raidName),
            totalFightTime = fightTime,
            executeStartHP = 20,
            maxHP = 1000000,
            isMultiCombat = false,
            isTestFight = false,
            isManualEntry = true,
            hasSayge = hasSayge and true or false
        }
        if classToken == nil then
            fightData.class = self.PlayerClassToken and self:PlayerClassToken() or nil
        elseif type(classToken) == "string" and classToken ~= "" then
            fightData.class = classToken
        end

        if not calc.fightHistory.data[bossKey] then
            calc.fightHistory.data[bossKey] = {}
        end

        self:InsertKillByTime(calc.fightHistory.data[bossKey], fightData)

        self:TrimFightHistory(bossKey)

        self:SaveExecuteSettings()

        local count = calc.fightHistory.data[bossKey] and #calc.fightHistory.data[bossKey] or 0

        if not silent then
            self:Print(string.format(RCL["|cff00ff00Added:|r %s - %.1fs (Total: %d kills)"], bossName, fightTime, count))

            local pred, conf = self:PredictTTK(raidName, bossName, hasSayge and true or false, fightData.profileName)
            if pred then
                self:Print(string.format(RCL["  |cff88aaffPrediction:|r %.1fs (%.0f%% confidence)"], pred, conf * 100))
            end
        end

        self:DebugPrint(string.format(RCL["Manual kill added: %s = %.1fs in %s"], bossName, fightTime, raidName), "execute")

        return count
    end

    -- A sim's fight is thrown away whole when it ends: left in place its
    -- start times could later be taken for a real kill's.
    function RC:ResetFightAfterSimulation()
        self.executeCalculator.currentFight = {
            started = false, bossEngaged = false,
            encounterName = nil, raidName = nil,
            primaryBoss = { name = nil, guid = nil, isActive = false, lastHP = 0, lastMaxHP = 0, lastUpdate = 0 },
            startTime = nil, bossEngageTime = nil, encounterStartTime = nil,
            enterExecuteTime = 0, maxHP = 0, executeStartHP = 0,
            addPhasesBeforeBoss = false, isMultiCombatEncounter = false, isTestFight = false,
        }
    end

    -- Manual abort. Unlike EndBossSimulation this does not restore
    -- combatState or clear the sim's spellCastTriggers entries.
    function RC:StopSimulation()
        if not self.activeSimulation then
            self:Print(RCL["No simulation running"])
            return
        end

        self.inCombat = self.activeSimulation.originalInCombat
        self:ResetFightAfterSimulation()
        self.activeSimulation = nil
        self:Print(RCL["Simulation stopped"])
    end

    function RC:StartBossSimulation(raidName, bossName)
        if self.activeSimulation then
            self:Print(RCL["|cffff0000A simulation is already running. Use /rc stopsim to stop it.|r"])
            return
        end

        local calc = self.executeCalculator

        -- the same kills a real pull reads: this config plus related ones
        local fights = self:GetLinkedFightHistoryForBoss(raidName, bossName)
        local predictedTTK, confidence = 60, 0.5

        if fights and #fights > 0 then
            predictedTTK, confidence = self:PredictTTK(raidName, bossName, self:HasSaygeBuff())
            predictedTTK = predictedTTK or 60
            confidence = confidence or 0
        end

        local bossConfig = nil
        local activeProfile = nil

        if self.db and self.db.raidProfiles and self.db.raidProfiles[raidName] then
            local structure = self.db.raidProfiles[raidName]
            local activeName = structure.activeProfile or "Default"
            if structure.profiles and structure.profiles[activeName] then
                activeProfile = structure.profiles[activeName]
                if activeProfile.bosses and activeProfile.bosses[bossName] then
                    bossConfig = activeProfile.bosses[bossName]
                end
            end
        end

        local enabledAbilities = {}
        if bossConfig and bossConfig.abilities then
            for abilityKey, settings in pairs(bossConfig.abilities) do
                if settings.enabled then
                    table.insert(enabledAbilities, {
                        key = abilityKey,
                        name = settings.customMessage or abilityKey,
                        triggerType = settings.triggerType or "unknown"
                    })
                end
            end
        end

        local originalInCombat = self.inCombat
        local originalCombatStartTime = self.combatState and self.combatState.combatStartTime or 0

        self.inCombat = true
        local fakeGUID = "Creature-0-0-0-0-" .. math.random(10000, 99999) .. "-0"

        if not self.combatState then
            self.combatState = {
                inCombat = false,
                combatStartTime = 0,
                lastCheck = 0,
                stableForDuration = 0,
                lastStateChange = 0
            }
        end
        self.combatState.inCombat = true
        self.combatState.combatStartTime = GetTime()
        self.combatState.lastStateChange = GetTime()

        calc.currentFight = {
            started = true,
            startTime = GetTime(),
            targetGUID = fakeGUID,
            targetName = bossName,
            encounterName = bossName,
            raidName = raidName,
            historyName = self:TTKBossName(raidName, bossName),
            profileName = self:GetActiveProfileNameForRaid(raidName),
            hasSayge = self:HasSaygeBuff(),
            bossEngaged = true,
            bossEngageTime = GetTime(),
            addPhasesBeforeBoss = false,
            enterExecuteTime = 0,
            executeStartHP = 0,
            maxHP = 1000000,
            isMultiCombatEncounter = false,
            isBossFight = true,
            isTestFight = true,
            primaryBoss = { name = bossName, isActive = true }
        }

        self.activeSimulation = {
            bossName = bossName,
            raidName = raidName,
            predictedTTK = predictedTTK,
            confidence = confidence,
            startTime = GetTime(),
            fakeGUID = fakeGUID,
            originalInCombat = originalInCombat,
            originalCombatStartTime = originalCombatStartTime,
            phase = "combat",
            currentHP = 100,
            enabledAbilities = enabledAbilities,
            realFight = true
        }

        if not self.reminderFrame then
            self:CreateReminderFrame()
        end

        self:Print("|cffFFAA00=== BOSS SIMULATION ===|r")
        self:Print(string.format(RCL["Boss: |cff00ff00%s|r (%s)"], bossName, raidName))
        self:Print(string.format(RCL["Predicted TTK: |cff88aaff%.1fs|r (%.0f%% conf)"], predictedTTK, confidence * 100))
        self:Print(string.format(RCL["Configured abilities: |cffffff00%d|r"], #enabledAbilities))

        local hasBuffRemainingTriggers = false
        if #enabledAbilities > 0 then
            for _, ability in ipairs(enabledAbilities) do
                self:Print(string.format("  - %s (%s)", ability.key, ability.triggerType))
                if ability.triggerType == "buff_remaining" then
                    hasBuffRemainingTriggers = true
                end
            end
        end

        if hasBuffRemainingTriggers then
            self:Print(" ")
            self:Print(RCL["|cff88ff88Tip:|r Pop your buffs (Death Wish, etc.) during sim"])
            self:Print(RCL["     to test buff_remaining triggers!"])
        end

        self:Print(" ")
        self:Print(RCL["Simulation starting... (real-time)"])
        self:Print(" ")

        if not self.triggerSystem then
            self:InitializeTriggerSystem()
        end

        if self.StartBuffRemainingMonitor then
            self:StartBuffRemainingMonitor()
        end

        if not self.spellCastTriggers then
            self.spellCastTriggers = {
                usedAbilities = {},
                buffRemainingTriggers = {},
                oilOfImmolationShown = {}
            }
        end
        if not self.spellCastTriggers.usedAbilities then
            self.spellCastTriggers.usedAbilities = {}
        end
        if not self.spellCastTriggers.buffRemainingTriggers then
            self.spellCastTriggers.buffRemainingTriggers = {}
        end

        self.spellCastTriggers.usedAbilities[fakeGUID] = {}
        self.spellCastTriggers.buffRemainingTriggers["player"] = {}

        self:RunRealtimeSimulation()
    end

    function RC:RunRealtimeSimulation()
        if not self.activeSimulation then return end

        local sim = self.activeSimulation
        local ttk = sim.predictedTTK
        local startTime = sim.startTime
        local calc = self.executeCalculator

        local bossConfig = nil
        if self.db and self.db.raidProfiles and self.db.raidProfiles[sim.raidName] then
            local structure = self.db.raidProfiles[sim.raidName]
            local activeName = structure.activeProfile or "Default"
            if structure.profiles and structure.profiles[activeName] then
                local activeProfile = structure.profiles[activeName]
                if activeProfile.bosses and activeProfile.bosses[sim.bossName] then
                    bossConfig = activeProfile.bosses[sim.bossName]
                end
            end
        end

        if not bossConfig or not bossConfig.abilities then
            self:DebugPrint("SIM: No boss config for " .. sim.bossName .. "  -  using default fallback abilities", "trigger")
            bossConfig = {
                enabled = true,
                abilities = {
                    deathwish  = { enabled = true, triggerType = "ttk", ttkValue = 35 },
                    recklessness = { enabled = true, triggerType = "ttk", ttkValue = 20 },
                    trinket1   = { enabled = true, triggerType = "ttk", ttkValue = 5  },
                    trinket2   = { enabled = true, triggerType = "ttk", ttkValue = 5  },
                }
            }
        end

        self:DebugPrint("=== SIMULATION ABILITIES FOR " .. sim.bossName .. " ===", "trigger")
        for abilityKey, abilitySettings in pairs(bossConfig.abilities) do
            local isPotionKey = (type(abilityKey) == "string" and abilityKey:lower():find("potion"))
            if isPotionKey then
                self:DebugPrint(string.format(RCL["  POTION: %s | enabled=%s | triggerType=%s | potionType=%s | hpValue=%s"],
                    abilityKey,
                    tostring(abilitySettings.enabled),
                    tostring(abilitySettings.triggerType),
                    tostring(abilitySettings.potionType),
                    tostring(abilitySettings.hpValue)), "trigger")
            else
                self:DebugPrint(string.format(RCL["  Ability: %s | enabled=%s | triggerType=%s"],
                    abilityKey,
                    tostring(abilitySettings.enabled),
                    tostring(abilitySettings.triggerType)), "trigger")
            end
        end
        self:DebugPrint("=== END SIMULATION ABILITIES ===", "trigger")

        -- Linear decay: the mock boss burns 100% of its bar over exactly
        -- the predicted TTK, so the sim always "dies" on the prediction.
        -- It is a trigger-firing rehearsal, not a model validation.
        local hpDecayPerSecond = 100 / ttk

        sim.mockTarget = {
            name = sim.bossName,
            guid = sim.fakeGUID,
            currentHP = 1000000,
            maxHP = 1000000,
            currentHPPercent = 100,
            encounterType = "boss",
            healthHistory = {},
            estimatedTimeToKill = ttk
        }

        local function UpdateSimulation()
            if not self.activeSimulation then return end

            local elapsed = GetTime() - startTime
            local simulatedHP = math.max(0, 100 - (elapsed * hpDecayPerSecond))
            local simulatedCurrentHP = math.floor((simulatedHP / 100) * 1000000)

            sim.currentHP = simulatedHP

            sim.mockTarget.currentHP = simulatedCurrentHP
            sim.mockTarget.currentHPPercent = simulatedHP

            table.insert(sim.mockTarget.healthHistory, {
                hp = simulatedCurrentHP,
                time = GetTime()
            })
            while #sim.mockTarget.healthHistory > 50 do
                table.remove(sim.mockTarget.healthHistory, 1)
            end

            if simulatedHP <= calc.executeThreshold and calc.currentFight.enterExecuteTime == 0 then
                calc.currentFight.enterExecuteTime = GetTime()
                calc.currentFight.executeStartHP = simulatedHP
                sim.phase = "execute"
                self:DebugPrint("SIM: Entered execute phase", "execute")
            end

            local predictedRemaining, confidence = self:GetCurrentTTKPrediction()
            if predictedRemaining and predictedRemaining > 0 and predictedRemaining < 999 then
                sim.mockTarget.estimatedTimeToKill = predictedRemaining
            else
                sim.mockTarget.estimatedTimeToKill = math.max(0, ttk - elapsed)
            end

            local hpInt = math.floor(simulatedHP)
            if hpInt == 75 or hpInt == 50 or hpInt == 35 or hpInt == 25 or hpInt == 20 or hpInt == 10 or hpInt == 5 then
                if not sim["printed_" .. hpInt] then
                    sim["printed_" .. hpInt] = true
                    local color = simulatedHP > 35 and "888888" or (simulatedHP > 20 and "FFAA00" or "ff4444")
                    self:Print(string.format(RCL["  |cff%s[%.1fs]|r Boss at |cff%s%d%%|r HP (TTK: %.1fs)"],
                        color, elapsed, color, hpInt, sim.mockTarget.estimatedTimeToKill))

                    if hpInt == 20 and sim.phase ~= "execute" then
                        sim.phase = "execute"
                    end
                end
            end

            self:RunTriggerCheck()

            -- Self-rescheduling 0.2s chain rather than a tracked ticker;
            -- it terminates by simply not rescheduling once HP hits 0 or
            -- activeSimulation is cleared.
            if simulatedHP > 0 then
                C_Timer.After(0.2, UpdateSimulation)
            else
                self:EndBossSimulation()
            end
        end

        UpdateSimulation()
    end

    function RC:EndBossSimulation()
        if not self.activeSimulation then return end

        local sim = self.activeSimulation
        local calc = self.executeCalculator
        local actualFightTime = GetTime() - sim.startTime

        self:Print(" ")
        self:Print(string.format("  |cff00ff00[%.1fs]|r |cff00ff00%s DIES!|r", actualFightTime, sim.bossName))
        self:Print(" ")

        self:ResetFightAfterSimulation()
        self.inCombat = sim.originalInCombat

        if self.StopBuffRemainingMonitor then
            self:StopBuffRemainingMonitor()
        end

        if self.combatState then
            self.combatState.inCombat = sim.originalInCombat
            self.combatState.combatStartTime = sim.originalCombatStartTime or 0
        end

        if self.spellCastTriggers then
            if self.spellCastTriggers.usedAbilities then
                self.spellCastTriggers.usedAbilities[sim.fakeGUID] = nil
            end
            -- StartBossSimulation seeds buffRemainingTriggers under the
            -- key "player" as well as any per-GUID buckets, so clear both.
            if self.spellCastTriggers.buffRemainingTriggers then
                self.spellCastTriggers.buffRemainingTriggers[sim.fakeGUID] = nil
                self.spellCastTriggers.buffRemainingTriggers["player"] = nil
            end
        end

        self:Print("|cffFFAA00=== SIMULATION COMPLETE ===|r")
        self:Print(string.format(RCL["Fight duration: %.1fs"], actualFightTime))
        self:Print(string.format(RCL["Predicted was: %.1fs (diff: %+.1fs)"],
            sim.predictedTTK, actualFightTime - sim.predictedTTK))

        self.activeSimulation = nil
    end

    RC:DebugPrint("Execute Calculator initialized", "execute")
    RC:DebugPrint("  Use /rc sim to test with reminders", "execute")

C_Timer.After(0.1, function()
    local WR2 = _G.Readycheck
    if WR2 and WR2.LoadExecuteSettings then
        WR2:LoadExecuteSettings()
    end
end)
