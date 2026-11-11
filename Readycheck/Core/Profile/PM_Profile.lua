------------------------------------------------------------------------
-- Readycheck - Profile Save/Load
-- All settings live in ReadycheckDB.characters[charKey] - per character,
-- not account-wide. self.db is the live working copy the rest of the
-- addon reads/writes; LoadConfigurationFromProfile only deep-copies from
-- the stored profile into self.db when they are different table objects
-- (needsDeepCopy). A shallow copy here would leave self.db and the stored
-- profile sharing the same nested tables, so editing settings in one
-- character's session would silently mutate another character's saved
-- profile the next time it loads.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
RC._pms = RC._pms or {}
    -- Cycle-safe (via seen) and skips functions/userdata and any table with
    -- a metatable (e.g. Frames), so UI objects accidentally nested in
    -- settings tables aren't recursed into or duplicated.
    local function DeepCopy(original, seen)
        if type(original) ~= "table" then
            return original
        end

        seen = seen or {}

        if seen[original] then
            return seen[original]
        end

        local mt = getmetatable(original)
        if mt and (mt.__type or mt.__index) then
            return nil
        end

        local copy = {}
        seen[original] = copy

        for key, value in pairs(original) do
            local valueType = type(value)

            if valueType == "function" or valueType == "userdata" then
            elseif valueType == "table" then
                local valueMt = getmetatable(value)
                if valueMt and (valueMt.__type or valueMt.__index) then
                else
                    copy[key] = DeepCopy(value, seen)
                end
            else
                copy[key] = value
            end
        end

        return copy
    end

    RC.DeepCopy = DeepCopy

    -- Single source of truth for a brand-new character profile's shape.
    -- Used by RC:Initialize (Core_Init.lua), SaveConfigurationToProfile and
    -- InitializeCharacterProfile below - previously three diverging copies.
    -- Sections with entries in RC.defaults are seeded from them; everything
    -- else starts as an empty table.
    function RC:BuildDefaultCharacterProfile()
        local function fromDefaults(key)
            if self.defaults and self.defaults[key] ~= nil then
                return DeepCopy(self.defaults[key])
            end
            return {}
        end
        return {
            enabled = true,
            -- a profile first made with the newer default layout (frames
            -- in their new default spots; see RC:NewDefaults)
            defaultsGen = 2,
            raidProfiles = {},
            fontSettings = fromDefaults("fontSettings"),
            executeSettings = fromDefaults("executeSettings"),
            trinketSwap = fromDefaults("trinketSwap"),
            consumablesHelper = fromDefaults("consumablesHelper"),
            potionsBar = fromDefaults("potionsBar"),
            weaponsBar = fromDefaults("weaponsBar"),
            trinketBar = {},
            consumablesChecker = fromDefaults("consumablesChecker"),
            consumableSettings = {},
            gearManager = {},
            gearButtons = {},
            gearButtonPositions = {},
            gearPinnedButtons = {},
            gearSets = {},
            hotswapSettings = {},
            sidebarState = {},
            battleShoutReminder = {},
            fastWeaponReminder = {},
            boonReminder = {},
            battleShoutPartyTracker = {},
            raidBuffTracker = {},
            bossDebuffTracker = {},
            bossNotes = {},
            polarityMode = {},
            specDetection = {},
            ttkDisplay = {},
            buffPushoffAlert = {},
            setupWizard = {},
            customReminders = { reminders = {}, nextId = 1 },
            smartMacros = {},
            smartMacrosNextId = 1,
            autoDetectedTrinkets = {},
            lastSidebarSelection = nil,
            lastUsed = GetServerTime(),
            showStatsButton = false,
            sidebarNav = {},
        }
    end

    function RC:SaveConfigurationToProfile()
        if RC.Profiler then RC.Profiler:StartTiming("ProfileSave") end
        RC._sidebarLastInteraction = GetTime()
        -- Boss-name lookups depend on which boss entries exist and what is
        -- set up on them; any config edit can change the answer, so the
        -- memo is dropped here as well as on target change (TE_Events).
        RC._encResolveCache = nil

        if RC._startupPhase then
            RC._startupDirty = true
            self:DebugPrint("Save suppressed during startup phase", "config")
            if RC.Profiler then RC.Profiler:StopTiming("ProfileSave") end
            return
        end

        if not self.db then
            if RC.Profiler then RC.Profiler:StopTiming("ProfileSave") end
            return
        end

        local charKey = self:GetCharacterKey()

        if not ReadycheckDB.characters then
            ReadycheckDB.characters = {}
        end
        if not ReadycheckDB.characters[charKey] then
            ReadycheckDB.characters[charKey] = self:BuildDefaultCharacterProfile()
        end

        if self.executeCalculator then
            local memoryFightHistory = self.executeCalculator.fightHistory and self.executeCalculator.fightHistory.data
            local memoryHasData = memoryFightHistory and next(memoryFightHistory) ~= nil

            local savedFightHistory = (ReadycheckDB.characters[charKey].executeSettings and
                ReadycheckDB.characters[charKey].executeSettings.fightHistory) or nil

            local fightHistoryToSave
            if RC._profileLoadDone and memoryHasData then
                fightHistoryToSave = memoryFightHistory
            elseif RC._profileLoadDone then
                fightHistoryToSave = memoryFightHistory or savedFightHistory
            else
                fightHistoryToSave = savedFightHistory
            end

            ReadycheckDB.characters[charKey].executeSettings = {
                executeThreshold = self.executeCalculator.executeThreshold,
                fightHistory = fightHistoryToSave,
                testModeEnabled = self.executeCalculator.testMode and self.executeCalculator.testMode.enabled,
                mode = self.executeCalculator.mode,
                collectData = self.executeCalculator.collectData,
                classicGlobalMultiplier = self.executeCalculator.classicMultipliers and self.executeCalculator.classicMultipliers.global,
                classicBossMultipliers = self.executeCalculator.classicMultipliers and self.executeCalculator.classicMultipliers.perBoss,
                mlConfig = self.executeCalculator.mlConfig,
                ewmaEnabled = self.executeCalculator.ewma and self.executeCalculator.ewma.enabled,
                ewmaAlpha = self.executeCalculator.ewma and self.executeCalculator.ewma.alpha,
                dataCollection = self.executeCalculator.dataCollection,
                uiSettings = self.executeCalculator.uiSettings
            }
        end

        if self.GearManager and self.GearManager.settings and self.GearManager.settingsLoaded then
            if not ReadycheckDB.characters[charKey].gearManager then
                ReadycheckDB.characters[charKey].gearManager = {}
            end
            -- Shallow copy: GearManager.settings is expected to hold only
            -- flat values. A nested table value here would still alias the
            -- live GearManager.settings table instead of being copied.
            local savedSettings = {}
            for key, value in pairs(self.GearManager.settings) do
                savedSettings[key] = value
            end
            ReadycheckDB.characters[charKey].gearManager.settings = savedSettings
            self:DebugPrint("Saved GearManager.settings to profile", "gear")
        elseif self.GearManager and not self.GearManager.settingsLoaded then
            self:DebugPrint("Skipped saving GearManager.settings - not yet loaded from profile", "gear")
        end

        if self.SidebarState then
            ReadycheckDB.characters[charKey].sidebarState = {
                expandedCategories = self.SidebarState.expandedCategories or {}
            }
        end

        if not ReadycheckDB.characters[charKey].gearSets then
            ReadycheckDB.characters[charKey].gearSets = {}
        end

        if not ReadycheckDB.characters[charKey].migrationVersion then
            ReadycheckDB.characters[charKey].migrationVersion = 3
        end

        ReadycheckDB.characters[charKey].lastUsed = GetServerTime()

        if RC.Profiler then RC.Profiler:StopTiming("ProfileSave") end
    end

    function RC:LoadConfigurationFromProfile()
        if RC.Profiler then RC.Profiler:StartTiming("ProfileLoad") end

        local charKey = self:GetCharacterKey()

        if not ReadycheckDB.characters or not ReadycheckDB.characters[charKey] then
            self:DebugPrint("No character profile found for " .. charKey, "config")
            if RC.Profiler then RC.Profiler:StopTiming("ProfileLoad") end
            return
        end

        if RC._profileLoadDone then
            if RC.Profiler then RC.Profiler:StopTiming("ProfileLoad") end
            return
        end
        RC._profileLoadDone = true

        if self.CleanupRootLevelLegacyKeys and not RC._rootLevelCleanupDone then
            RC._rootLevelCleanupDone = true
            self:CleanupRootLevelLegacyKeys()
        end

        if self.AutoCleanupProfile then
            self:AutoCleanupProfile(charKey)
        end

        local profile = ReadycheckDB.characters[charKey]
        self:DebugPrint("Loading configuration from profile: " .. charKey, "config")

        -- self.db can already BE the stored profile table (first load path);
        -- deep-copying in that case would be pointless and would break the
        -- identity the rest of the addon relies on.
        local needsDeepCopy = (self.db ~= profile)

        if needsDeepCopy then
            self:DebugPrint("LoadConfigurationFromProfile: Using DeepCopy (self.db is different object)", "config")
        else
            self:DebugPrint("LoadConfigurationFromProfile: Skipping DeepCopy (self.db IS the profile)", "config")
        end

        if profile.raidProfiles then
            if needsDeepCopy then
                local curN, inN = 0, 0
                if type(self.db.raidProfiles) == "table" then
                    for _ in pairs(self.db.raidProfiles) do curN = curN + 1 end
                end
                for _ in pairs(profile.raidProfiles) do inN = inN + 1 end
                if inN == 0 and curN > 0 then
                    self:Print(RCL["Profile load: kept your current raid configs (the loaded profile had none)."])
                else
                    if curN > 0 then
                        ReadycheckDB.lastRaidProfilesBackup =
                            ReadycheckDB.lastRaidProfilesBackup or {}
                        ReadycheckDB.lastRaidProfilesBackup[self:GetCharacterKey() or "?"] = {
                            t = time(),
                            raidProfiles = self.DeepCopy(self.db.raidProfiles),
                        }
                    end
                    self.db.raidProfiles = self.DeepCopy(profile.raidProfiles)
                end
            end

            if not RC._buffMigrationDone then
                RC._buffMigrationDone = true
                self:MigrateBuffRemainingFields()
            end
            if not RC._soundMigrationDone then
                RC._soundMigrationDone = true
                self:MigrateSoundFiles()
            end
            if not RC._animMigrationDone then
                RC._animMigrationDone = true
                self:MigrateAnimationStyles()
            end
        end

        if profile.fontSettings then
            if needsDeepCopy then
                self.db.fontSettings = self.DeepCopy(profile.fontSettings)
                if self.UpdateAllFonts then
                    self:UpdateAllFonts()
                end
            end
        end

        if profile.executeSettings and self.executeCalculator then
            if profile.executeSettings.executeThreshold then
                self.executeCalculator.executeThreshold = profile.executeSettings.executeThreshold
            end
            if profile.executeSettings.fightHistory then
                if not self.executeCalculator.fightHistory then
                    self.executeCalculator.fightHistory = { maxHistorySize = 500, data = {} }
                end
                self.executeCalculator.fightHistory.data = profile.executeSettings.fightHistory
                local keyCount = 0
                local fightCount = 0
                for k, v in pairs(self.executeCalculator.fightHistory.data) do
                    keyCount = keyCount + 1
                    if type(v) == "table" then
                        fightCount = fightCount + #v
                    end
                end
                self:DebugPrint("LoadConfigurationFromProfile: Loaded " .. keyCount .. " bosses, " .. fightCount .. " fights", "execute")
            end
            if profile.executeSettings.testModeEnabled ~= nil then
                if not self.executeCalculator.testMode then
                    self.executeCalculator.testMode = { enabled = false }
                end
                self.executeCalculator.testMode.enabled = profile.executeSettings.testModeEnabled
            end
            if profile.executeSettings.mode then
                self.executeCalculator.mode = profile.executeSettings.mode
            end
            if profile.executeSettings.collectData ~= nil then
                self.executeCalculator.collectData = profile.executeSettings.collectData
                if not self.executeCalculator.dataCollection then
                    self.executeCalculator.dataCollection = { disabled = false }
                end
                self.executeCalculator.dataCollection.disabled = not self.executeCalculator.collectData
            end
            if profile.executeSettings.classicGlobalMultiplier then
                if not self.executeCalculator.classicMultipliers then
                    self.executeCalculator.classicMultipliers = { global = 1.6, perBoss = {} }
                end
                self.executeCalculator.classicMultipliers.global = profile.executeSettings.classicGlobalMultiplier
            end
            if profile.executeSettings.classicBossMultipliers then
                if not self.executeCalculator.classicMultipliers then
                    self.executeCalculator.classicMultipliers = { global = 1.6, perBoss = {} }
                end
                self.executeCalculator.classicMultipliers.perBoss = profile.executeSettings.classicBossMultipliers
            end
            if profile.executeSettings.mlConfig then
                self.executeCalculator.mlConfig = profile.executeSettings.mlConfig
            end
            if profile.executeSettings.ewmaEnabled ~= nil then
                if not self.executeCalculator.ewma then
                    self.executeCalculator.ewma = { enabled = true, alpha = 0.3, minSamples = 3 }
                end
                self.executeCalculator.ewma.enabled = profile.executeSettings.ewmaEnabled
            end
            if profile.executeSettings.ewmaAlpha then
                if not self.executeCalculator.ewma then
                    self.executeCalculator.ewma = { enabled = true, alpha = 0.3, minSamples = 3 }
                end
                self.executeCalculator.ewma.alpha = profile.executeSettings.ewmaAlpha
            end
            if profile.executeSettings.dataCollection then
                self.executeCalculator.dataCollection = profile.executeSettings.dataCollection
                self.executeCalculator.collectData = not self.executeCalculator.dataCollection.disabled
            end
            if profile.executeSettings.uiSettings then
                self.executeCalculator.uiSettings = profile.executeSettings.uiSettings
            end
        end

        if profile.trinketSwap then
            if needsDeepCopy then
                self.db.trinketSwap = self.DeepCopy(profile.trinketSwap)
            end

            if self.defaults and self.defaults.trinketSwap then
                local function FillMissing(dst, src)
                    if type(src) ~= "table" then return end
                    for k, v in pairs(src) do
                        if dst[k] == nil then
                            if type(v) == "table" then
                                dst[k] = self.DeepCopy(v)
                            else
                                dst[k] = v
                            end
                        elseif type(v) == "table" and type(dst[k]) == "table" then
                            FillMissing(dst[k], v)
                        end
                    end
                end
                FillMissing(self.db.trinketSwap, self.defaults.trinketSwap)
            end

            self:DebugPrint("Loaded trinket swap settings: enabled=" .. tostring(self.db.trinketSwap.enabled), "config")

            if self.db.trinketSwap.showToggleButton then
                if self.ShowTrinketToggleButton then
                    self:ShowTrinketToggleButton()
                end
            else
                if self.HideTrinketToggleButton then
                    self:HideTrinketToggleButton()
                end
            end
        end

        if profile.consumablesHelper then
            if needsDeepCopy then
                self.db.consumablesHelper = self.DeepCopy(profile.consumablesHelper)
            end

            if self.UpdateConsumablesHelperBackground then
                self:UpdateConsumablesHelperBackground()
            end
        end

        if profile.potionsBar then
            if needsDeepCopy then
                self.db.potionsBar = self.DeepCopy(profile.potionsBar)
            end

            if self.UpdatePotionsBarBackground then
                self:UpdatePotionsBarBackground()
            end
        end

        if profile.consumablesChecker then
            if needsDeepCopy then
                self.db.consumablesChecker = self.DeepCopy(profile.consumablesChecker)
            end

            C_Timer.After(0.2, function()
                if self.consumablesChecker and self.consumablesChecker.frame and self.consumablesChecker.frame:IsShown() then
                    if self.PopulateConsumablesChecker then
                        self:PopulateConsumablesChecker()
                    end
                end
            end)
        end

        if profile.specDetection then
            if needsDeepCopy then
                self.db.specDetection = self.DeepCopy(profile.specDetection)
            end
        end

        if profile.consumableSettings then
            if needsDeepCopy then
                self.db.consumableSettings = self.DeepCopy(profile.consumableSettings)
            end
        end

        if profile.gearManager then
            if needsDeepCopy then
                self.db.gearManager = self.DeepCopy(profile.gearManager)
            end

            self:DebugPrint(string.format(RCL["Loaded gearManager.enabled = %s from profile"], tostring(profile.gearManager.enabled)), "gear")

            if self.GearManager then
                if profile.gearManager.enabled ~= nil then
                    self.GearManager.enabled = profile.gearManager.enabled
                    self:DebugPrint(string.format(RCL["Applied GM.enabled = %s"], tostring(self.GearManager.enabled)), "gear")
                end

                if profile.gearManager.settings then
                    if not self.GearManager.settings then
                        self.GearManager.settings = {}
                    end
                    for key, value in pairs(profile.gearManager.settings) do
                        self.GearManager.settings[key] = value
                    end

                    if profile.gearManager.settings.buttonsLocked ~= nil then
                        self.GearManager.locked = profile.gearManager.settings.buttonsLocked
                        self:DebugPrint(string.format(RCL["Synchronized GM.locked = %s from profile settings"], tostring(self.GearManager.locked)), "gear")
                    end
                end
            end
        end

        if profile.gearButtons then
            if needsDeepCopy then
                self.db.gearButtons = self.DeepCopy(profile.gearButtons)
            end
            local buttonCount = 0
            for slot, active in pairs(self.db.gearButtons) do
                if active then buttonCount = buttonCount + 1 end
            end
            self:DebugPrint(string.format(RCL["Loaded %d active gear button(s) from profile"], buttonCount), "gear")
        end

        if profile.gearButtonPositions then
            if needsDeepCopy then
                self.db.gearButtonPositions = self.DeepCopy(profile.gearButtonPositions)
            end
        end

        if profile.gearPinnedButtons then
            if needsDeepCopy then
                self.db.gearPinnedButtons = self.DeepCopy(profile.gearPinnedButtons)
            end
        end

        if not self.db.gearSets then
            self.db.gearSets = {}
        end

        if self.GearManager then
            self.GearManager.sets = self.db.gearSets
            if self:IsDebugEnabled("config") then
                self:DebugPrint("Loaded " .. self:TableCount(self.GearManager.sets) .. " gear sets from profile (DIRECT REFERENCE)", "config")
            end
        end

        if self.db.hotswapEnabled == nil then self.db.hotswapEnabled = true end
        if self.db.hotswapT2Protect == nil then self.db.hotswapT2Protect = true end
        if self.db.hotswapPartyAnnounce == nil then self.db.hotswapPartyAnnounce = false end
        if self.db.hotswapCombatBlockMessage == nil then
            self.db.hotswapCombatBlockMessage = "%player% in combat -- not equipping T2!"
        end
        if self.db.hotswapCombatQueue == nil then self.db.hotswapCombatQueue = false end
        if self.Hotswap then
            self.Hotswap.enabled = self.db.hotswapEnabled
        end

        if profile.anchorPoint ~= nil then
            self.db.anchorPoint = profile.anchorPoint
        end
        if profile.xOffset ~= nil then
            self.db.xOffset = profile.xOffset
        end
        if profile.yOffset ~= nil then
            self.db.yOffset = profile.yOffset
        end

        if profile.lastSidebarSelection then
            self.db.lastSidebarSelection = profile.lastSidebarSelection
        end
        if profile.sidebarState then
            if not self.SidebarState then
                self.SidebarState = {}
            end
            if profile.sidebarState.expandedCategories then
                self.SidebarState.expandedCategories = self.DeepCopy(profile.sidebarState.expandedCategories)
            end
        end

        if profile.buffPushoffAlert then
            if needsDeepCopy then
                self.db.buffPushoffAlert = self.DeepCopy(profile.buffPushoffAlert)
            end
            self:DebugPrint("Loaded buffPushoffAlert settings: enabled=" .. tostring(self.db.buffPushoffAlert.enabled), "config")
        end

        if profile.ttkDisplay then
            if needsDeepCopy then
                self.db.ttkDisplay = self.DeepCopy(profile.ttkDisplay)
            end
            if self:IsDebugEnabled("config") then
                self:DebugPrint("Loaded ttkDisplay settings: enabled=" .. tostring(self.db.ttkDisplay.enabled) ..
                    ", width=" .. tostring(self.db.ttkDisplay.width) ..
                    ", height=" .. tostring(self.db.ttkDisplay.height) ..
                    ", showBackground=" .. tostring(self.db.ttkDisplay.showBackground), "config")
            end

            C_Timer.After(0.3, function()
                if self.TTKDisplay and self.TTKDisplay.ttkFrame then
                    if self.TTKDisplay.UpdateTTKDisplayAppearance then
                        self.TTKDisplay:UpdateTTKDisplayAppearance()
                    end
                    if self.TTKDisplay.UpdateTTKDisplayBackground then
                        self.TTKDisplay:UpdateTTKDisplayBackground()
                    end
                end
            end)
        end

        if not self.db.sidebarNav then self.db.sidebarNav = {} end
        if profile.sidebarNav then
            for k, v in pairs(profile.sidebarNav) do
                self.db.sidebarNav[k] = v
            end
        end
        local navDefaults = RC.defaults and RC.defaults.sidebarNav or {}
        for k, v in pairs(navDefaults) do
            if self.db.sidebarNav[k] == nil then
                self.db.sidebarNav[k] = v
            end
        end

        if profile.customReminders then
            if needsDeepCopy then
                self.db.customReminders = self.DeepCopy(profile.customReminders)
            end
            if not self.db.customReminders.reminders then
                self.db.customReminders.reminders = {}
            end
            if not self.db.customReminders.nextId then
                self.db.customReminders.nextId = 1
            end
            for _, r in ipairs(self.db.customReminders.reminders) do
                if r.lua then
                    r.lua.compiledFn = nil
                end
                if r.sequence then
                    r.sequence.stepEnter = nil
                end
                r.lastFired = 0
            end
            self:DebugPrint("Loaded " .. #self.db.customReminders.reminders .. " custom reminders", "config")
            if RC.KickCustomReminderTicker then
                for _, r in ipairs(self.db.customReminders.reminders) do
                    if r.enabled then RC:KickCustomReminderTicker(); break end
                end
            end
        end

        profile.lastUsed = GetServerTime()

        self:DebugPrint("Configuration load complete from profile: " .. charKey, "config")

        if self.GearManager and self.GearManager.RestoreButtonsFromProfile then
            C_Timer.After(0.5, function()
                self.GearManager:RestoreButtonsFromProfile()
            end)
        end

        if self.ApplyBattleShoutLockState then
            C_Timer.After(0.1, function()
                self:ApplyBattleShoutLockState()
            end)
        end

        if self.MigrateGearSwapConfigs then
            self:MigrateGearSwapConfigs()
        end

        if RC.Profiler then RC.Profiler:StopTiming("ProfileLoad") end
    end

    -- Unlike PM_Cleanup.lua's profile.migrationVersion gates, this flag lives
    -- only in memory: it resets every session, so this rescans (cheaply,
    -- finding nothing left to do) on every login rather than running once ever.
    function RC:MigrateGearSwapConfigs()
        if RC._gearSwapMigrationDone then return end
        RC._gearSwapMigrationDone = true
        local migratedCount = 0

        if not self.db or not self.db.raidProfiles then
            return
        end

        for raidName, raidProfiles in pairs(self.db.raidProfiles) do
            if type(raidProfiles) == "table" then
                for profileName, profileData in pairs(raidProfiles) do
                    if type(profileData) == "table" and profileData.bosses then
                        for bossName, bossConfig in pairs(profileData.bosses) do
                            if type(bossConfig) == "table" and bossConfig.abilities then
                                local gearswapConfig = bossConfig.abilities.gearswap
                                if gearswapConfig then
                                    if gearswapConfig.itemRackSet and (not gearswapConfig.gearSet or gearswapConfig.gearSet == "") then
                                        gearswapConfig.gearSet = gearswapConfig.itemRackSet
                                        migratedCount = migratedCount + 1
                                        self:DebugPrint("Migrated gear swap for " .. bossName .. ": " .. gearswapConfig.itemRackSet, "config")
                                    end
                                end
                            end
                        end

                        if profileData.trash then
                            for trashName, trashConfig in pairs(profileData.trash) do
                                if type(trashConfig) == "table" and trashConfig.abilities then
                                    local gearswapConfig = trashConfig.abilities.gearswap
                                    if gearswapConfig then
                                        if gearswapConfig.itemRackSet and (not gearswapConfig.gearSet or gearswapConfig.gearSet == "") then
                                            gearswapConfig.gearSet = gearswapConfig.itemRackSet
                                            migratedCount = migratedCount + 1
                                            self:DebugPrint("Migrated gear swap for trash " .. trashName .. ": " .. gearswapConfig.itemRackSet, "config")
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if migratedCount > 0 then
            self:DebugPrint("Gear swap migration complete: " .. migratedCount .. " configs updated", "config")
            if self.SaveConfigurationToProfile then
                self:SaveConfigurationToProfile()
            end
        end
    end

    function RC:MigrateBuffRemainingFields()
        if RC._buffRemainingMigrationDone then return end
        RC._buffRemainingMigrationDone = true
        local migratedCount = 0

        if not self.db or not self.db.raidProfiles then
            return
        end

        local function CleanupAbility(abilityConfig, abilityKey, contextName)
            if not abilityConfig then return end

            if abilityConfig.buffRemainingValue ~= nil and abilityConfig.buffTimeRemaining ~= nil then
                self:DebugPrint(string.format(RCL["Migration: %s/%s - clearing buffTimeRemaining=%s (buffRemainingValue=%s)"],
                    contextName, abilityKey,
                    tostring(abilityConfig.buffTimeRemaining),
                    tostring(abilityConfig.buffRemainingValue)), "config")
                abilityConfig.buffTimeRemaining = nil
                migratedCount = migratedCount + 1
            elseif abilityConfig.buffTimeRemaining ~= nil and abilityConfig.buffRemainingValue == nil then
                abilityConfig.buffRemainingValue = abilityConfig.buffTimeRemaining
                abilityConfig.buffTimeRemaining = nil
                migratedCount = migratedCount + 1
                self:DebugPrint(string.format(RCL["Migration: %s/%s - converted buffTimeRemaining=%s to buffRemainingValue"],
                    contextName, abilityKey, tostring(abilityConfig.buffRemainingValue)), "config")
            end
        end

        for raidName, raidStructure in pairs(self.db.raidProfiles) do
            if type(raidStructure) == "table" and raidStructure.profiles then
                for profileName, profileData in pairs(raidStructure.profiles) do
                    if type(profileData) == "table" then
                        if profileData.bosses then
                            for bossName, bossConfig in pairs(profileData.bosses) do
                                if type(bossConfig) == "table" and bossConfig.abilities then
                                    for abilityKey, abilityConfig in pairs(bossConfig.abilities) do
                                        if type(abilityConfig) == "table" then
                                            CleanupAbility(abilityConfig, abilityKey, raidName .. "/" .. bossName)
                                        end
                                    end
                                end
                            end
                        end

                        if profileData.trash then
                            for trashName, trashConfig in pairs(profileData.trash) do
                                if type(trashConfig) == "table" and trashConfig.abilities then
                                    for abilityKey, abilityConfig in pairs(trashConfig.abilities) do
                                        if type(abilityConfig) == "table" then
                                            CleanupAbility(abilityConfig, abilityKey, raidName .. "/trash/" .. trashName)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if migratedCount > 0 then
            self:DebugPrint("Buff remaining migration complete: " .. migratedCount .. " configs updated", "config")
            if self.SaveConfigurationToProfile then
                self:SaveConfigurationToProfile()
            end
        end
    end

    function RC:MigrateSoundFiles()
        if not self.db then return end
        local fallback = "Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg"
        -- an .mp3 (the client cannot play them), or the old default
        -- Sounds\Warning.ogg, which is not shipped
        local function isBadPath(path)
            if not path or path == "" then return false end
            return path:find("%.mp3$") ~= nil
                or path:find("Readycheck\\Sounds\\Warning.ogg", 1, true) ~= nil
        end
        local changed = false
        for _, key in ipairs({ "repairReminder", "fastWeaponReminder" }) do
            local t = self.db[key]
            if type(t) == "table" and isBadPath(t.soundFile) then
                t.soundFile = fallback; changed = true
            end
        end
        if isBadPath(self.db.soundFile) then
            self.db.soundFile = fallback; changed = true
        end
        if self.db.battleShoutReminder and isBadPath(self.db.battleShoutReminder.soundFile) then
            self.db.battleShoutReminder.soundFile = fallback; changed = true
        end
        if self.db.abilityOverrides then
            for _, ao in pairs(self.db.abilityOverrides) do
                if isBadPath(ao.soundFile) then
                    ao.soundFile = fallback; changed = true
                end
            end
        end
        -- Custom reminders live in customReminders.reminders (customReminders
        -- itself only holds { reminders = {...}, nextId = n }).
        if self.db.customReminders and self.db.customReminders.reminders then
            for _, cr in ipairs(self.db.customReminders.reminders) do
                if type(cr) == "table" and isBadPath(cr.soundFile) then
                    cr.soundFile = fallback; changed = true
                end
            end
        end
        local bars = {"consumablesHelper", "potionsBar", "weaponsBar", "trinketBar"}
        for _, barKey in ipairs(bars) do
            local bar = self.db[barKey]
            if bar and isBadPath(bar.soundFile) then
                bar.soundFile = fallback; changed = true
            end
        end
        if changed then
            self:DebugPrint("MigrateSoundFiles: replaced stale sound paths with the Announce sound", "config")
            if self.SaveConfigurationToProfile then self:SaveConfigurationToProfile() end
        end
    end

    function RC:MigrateAnimationStyles()
        if not self.db then return end
        -- the styles RC.Motion plays are live values again
        local function keep(v)
            if v == nil or v == "" or v == "fade" or v == "none" then return true end
            return RC.Motion ~= nil and RC.Motion.StyleFromLegacy(v) == v
        end
        local changed = false
        if not keep(self.db.animationType) then
            self.db.animationType = "fade"; changed = true
        end
        if self.db.battleShoutReminder and not keep(self.db.battleShoutReminder.animationType) then
            self.db.battleShoutReminder.animationType = "none"; changed = true
        end
        if self.db.abilityOverrides then
            for _, ao in pairs(self.db.abilityOverrides) do
                if type(ao) == "table" and not keep(ao.animationType) then
                    ao.animationType = "fade"; changed = true
                end
            end
        end
        if self.db.customReminders and self.db.customReminders.reminders then
            for _, r in ipairs(self.db.customReminders.reminders) do
                if type(r) == "table" and not keep(r.animationType) then
                    r.animationType = "fade"; changed = true
                end
            end
        end
        if changed then
            self:DebugPrint("MigrateAnimationStyles: collapsed retired animation styles to fade", "config")
            if self.SaveConfigurationToProfile then self:SaveConfigurationToProfile() end
        end
    end

    function RC:InitializeCharacterProfile()
        local charKey = self:GetCharacterKey()

        if not ReadycheckDB.characters then
            ReadycheckDB.characters = {}
        end

        if not ReadycheckDB.characters[charKey] then
            ReadycheckDB.characters[charKey] = self:BuildDefaultCharacterProfile()

            self:SaveConfigurationToProfile()
        else
            if self.AutoCleanupProfile then
                self:AutoCleanupProfile(charKey)
            end
        end

        return true
    end

    RC:RegisterEvent("ZONE_CHANGED_NEW_AREA")

