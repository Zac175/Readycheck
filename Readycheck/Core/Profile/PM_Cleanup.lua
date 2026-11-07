------------------------------------------------------------------------
-- Readycheck - Saved Profile Cleanup & Migrations
-- Strips dead/legacy fields from ReadycheckDB and runs versioned one-time
-- migrations, gated by profile.migrationVersion vs CURRENT_MIGRATION_VERSION.
-- Retiring a saved-variable field is not complete until its name is added
-- to DEAD_FIELDS (or ROOT_LEVEL_LEGACY_KEYS for root-level keys) here -
-- otherwise it lingers in every existing character's saved variables.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
RC._pms = RC._pms or {}
    local originalOnEvent = RC.OnEvent
    RC.OnEvent = function(self, event, ...)
        if event == "ZONE_CHANGED_NEW_AREA" then
            if self.OnZoneChanged then
                self:OnZoneChanged()
            else
                if self.SaveConfigurationToProfile then
                    self:SaveConfigurationToProfile()
                end
            end
        end

        if originalOnEvent then
            originalOnEvent(self, event, ...)
        end
    end

    local DEAD_FIELDS = {
        root = {
            "debugMode",
            "reminderCooldown",
            "statsBarWidth", "statsBarBuffs", "statsBarHit", "statsBarCrit",
            "statsBarAp", "statsBarDmg",
            -- the per-stat gauges: shipped for an afternoon, then removed
            "statsBarGauges",
            "abilitySettings", "bossSettings", "raidConfigs", "currentRaid",
            "absorbTracking", "buffPushoffAbsorbConsumed",
            "hotswapCombatMessage",
            "hotswapSettings",
            "ttsVisual", "ttsVisualX", "ttsVisualY",
            "showCooldowns",
            "profiler",
            "raidPlanner",
            -- the in-game raid map window, replaced by the route page
            "routeMap",
            -- Tank Marks (testing), scrapped
            "tankMarks",
            -- Raid consume reminders while in testing; carried into
            -- consumeRemind first (RC:MigrateConsumeRemind)
            "testConsumeRemind",
        },
        executeSettings = {
            "dpsProfiles",
            "adaptiveSampling",
            "debugMode",
            "combatLogThrottle", "combatLogDisabled",
        },
        consumablesChecker = {
            "onlyInRaid",
        },
        fontSettings = {
            "shadowEnabled",
        },
        consumablesHelper = {
            "debugMode",
            "bagWeaponBlacklist",
            -- Stored and defaulted but never read: the speak rate is fixed
            -- at TTS_RATE in TTSEngine.lua.
            "consumableTTSRate",
        },
        trinketSwap = {
            "debugMode",
            "bagCooldowns",
            "scanOnLogin",
        },
        fastWeaponReminder = {
            "speedThreshold",
        },
        boonReminder = {
            "animationType",
            "locked", "scale", "iconSize", "showLabel", "fontSize",
            "anchorPoint", "xOffset", "yOffset",
        },
        bossNotes = {
            "width",
        },
        polarityMode = {
            "reminderDuration",
            "lipBuffDuration",
            "reckTrinketDelay",
        },
        weaponsBar = {
            -- one Horde Mode flag for every faction; now per bar and per
            -- faction (hordeByFaction), so a synced Horde "on" cannot stick
            -- on Alliance characters
            "hordeMode", "hordeModeDefaulted",
        },
        worldBuffs = {
            -- one Reverse for the whole board; each sort key now carries
            -- its own direction inside boardSort (folded in below)
            "boardSortReverse",
        },
        nameplateAuras = {
            -- option to lift debuffs over one nameplate addon's names, removed
            "clearName",
        },
        previewPane = {
            -- the preview column's sample size and width: the preview is a
            -- strip in the page now, scaled to fit
            "size", "width",
        },
        customColors = {
            buttons = {"textNormal", "textHover", "textDisabled", "textConfigured"},
            sidebar = {"textNormal", "textSelected", "textDisabled", "categoryText"},
            consumablesBar = {"conflictBorder"},
            weaponBar = {"blacklisted", "notBlacklisted"},
        },
    }

    -- DEAD_FIELDS sub-tables that are plain field lists, cleaned/reported by
    -- the data-driven loops in AutoCleanupProfile, AnalyzeProfileForCleanup
    -- and CleanupProfile below (customColors is nested and handled separately).
    -- weaponsBar.hordeMode is folded into hordeByFaction before it goes.
    -- Only the character playing now has a faction to go by, so another
    -- character keeps its old fields until it logs in itself. Only an "off"
    -- carries over, and only for a Horde character: an old "on" is the
    -- synced value that stuck on Alliance characters.
    local function HoldOldHordeMode(profile, charKey)
        local wb = profile and profile.weaponsBar
        if type(wb) ~= "table" or (wb.hordeMode == nil and wb.hordeModeDefaulted == nil) then
            return false
        end
        local me = RC.GetCharacterKey and RC:GetCharacterKey()
        if charKey ~= me then return true end
        local faction = UnitFactionGroup and UnitFactionGroup("player")
        if faction == "Horde" and wb.hordeMode == false then
            for _, key in ipairs({ "weaponsBar", "consumablesHelper" }) do
                local bar = profile[key]
                if type(bar) == "table" then
                    if type(bar.hordeByFaction) ~= "table" then bar.hordeByFaction = {} end
                    if bar.hordeByFaction.Horde == nil then bar.hordeByFaction.Horde = false end
                end
            end
        end
        return false
    end

    local DEAD_FIELD_SECTIONS = {
        "executeSettings", "consumablesHelper", "trinketSwap",
        "fastWeaponReminder", "boonReminder", "bossNotes", "polarityMode",
        "worldBuffs", "weaponsBar", "nameplateAuras", "previewPane",
    }

    -- Legacy per-ability potion keys removed by the raidSettings cleanup
    -- (config-key and display-name variants from the pre-raidProfiles era).
    local OLD_POTION_KEYS_RAIDSETTINGS = {
        "mightyRagePotion", "stoneshieldPotion", "invulnerabilityPotion",
        "swiftnessPotion", "fireProtectionPotion", "frostProtectionPotion",
        "natureProtectionPotion", "shadowProtectionPotion", "arcaneProtectionPotion",
        "greatRagePotion", "ragePotion", "limitedInvulnerabilityPotion",
        "Mighty Rage Potion", "Stoneshield Potion", "Limited Invulnerability Potion",
        "Free Action Potion", "Swiftness Potion", "Fire Protection Potion",
        "Frost Protection Potion", "Nature Protection Potion", "Shadow Protection Potion",
        "Arcane Protection Potion", "Great Rage Potion", "Rage Potion"
    }

    -- Legacy per-ability potion keys removed by the v4 raidProfiles migration
    -- (bosses and trash share this exact list).
    local OLD_POTION_KEYS_V4 = {
        "mightyRagePotion", "stoneshieldPotion", "limitedInvulnerabilityPotion",
        "freeActionPotion", "greaterArcaneProtectionPotion", "greaterFireProtectionPotion",
        "greaterFrostProtectionPotion", "greaterNatureProtectionPotion", "greaterShadowProtectionPotion",
        "invulnerabilityPotion", "swiftnessPotion", "fireProtectionPotion",
        "frostProtectionPotion", "natureProtectionPotion", "shadowProtectionPotion",
        "arcaneProtectionPotion", "greatRagePotion", "ragePotion"
    }

    local INVALID_CONSUMABLE_ITEMS = {
        [954] = true,
        [2289] = true,
        [4426] = true,
        [10310] = true,
        [3012] = true,
        [1477] = true,
        [4425] = true,
        [10309] = true,
        [12218] = true,
        [17222] = true,
        [18045] = true,
        [18254] = true,
        [8411] = true,
        [20008] = true,
        [12450] = true,
        [21153] = true,
    }

    local ROOT_LEVEL_LEGACY_KEYS = {
        "currentRaid", "xOffset", "yOffset", "anchorPoint",
        "animationType", "clickThrough", "iconSpacing", "iconSize",
        "reminderDuration", "fadeInTime", "fadeTime",
        "showIconText", "iconGlow", "showTooltips", "showCooldowns",
        "showInCombatOnly", "showStatsBar", "dragEnabled",
        "showStatsButton",

        "statsBarWidth", "statsBarHeight", "statsBarSpacing",
        "statsBarFontSize", "statsBarLocked", "statsBarShowBg", "statsBarShowPushoffIcon",
        "statsBarDurability", "statsBarGold",
        "statsBarPosition", "statsBarColors",
        "statsBarAp", "statsBarCrit", "statsBarHit", "statsBarDmg", "statsBarBuffs",
        "buffPushoffAlert", "ttkDisplay",

        "remoteGearPush",
        "remoteEditLastSession",
        "remoteReminderPush",

        "customReminders",

        "customColors",

        "consumablesChecker", "consumablesHelper", "potionsBar",
        "trinketSwap", "executeSettings", "fontSettings",
        "gearManager", "gearSets", "gearButtons", "gearButtonPositions", "gearPinnedButtons",
        "fastWeaponReminder", "specDetection",

        "abilitySettings", "bossSettings", "raidSettings", "raidConfigs",
        "raidProfiles", "consumableSettings",

        "enabled", "ttsEnabled", "soundEnabled",
        "ttsVisual", "ttsVisualX", "ttsVisualY",
        "reminderCooldown", "abilityReadyGracePeriod", "debugMode",

        "sidebarState", "lastSidebarSelection",

        "configWindowWidth", "configWindowHeight",

        "hotswapEnabled", "hotswapT2Protect", "hotswapPartyAnnounce",
        "hotswapCombatMessage",

        "potionCleanupDone", "lastUsed", "migrationVersion",
    }

    function RC:CleanupRootLevelLegacyKeys()
        if not ReadycheckDB then return 0 end
        if RC._rootLevelCleanupDone then return 0 end
        RC._rootLevelCleanupDone = true

        local cleaned = 0

        for _, key in ipairs(ROOT_LEVEL_LEGACY_KEYS) do
            if ReadycheckDB[key] ~= nil then
                ReadycheckDB[key] = nil
                cleaned = cleaned + 1
            end
        end

        local pruned = 0
        local now = time()
        local RETAIN = 90 * 24 * 60 * 60 -- 90 days
        local function pruneAged(root, stampField)
            local t = ReadycheckDB[root]
            if type(t) ~= "table" then return end
            for charKey, entry in pairs(t) do
                if type(entry) ~= "table" then
                    t[charKey] = nil; pruned = pruned + 1
                elseif root == "remoteRaidConfigQueue" then
                    local ts = tonumber(entry[stampField])
                    if not ts then entry[stampField] = now
                    elseif (now - ts) > RETAIN then
                        t[charKey] = nil; pruned = pruned + 1
                    end
                else
                    for raidKey, slot in pairs(entry) do
                        if type(slot) ~= "table" then
                            entry[raidKey] = nil; pruned = pruned + 1
                        else
                            local ts = tonumber(slot[stampField])
                            if not ts then slot[stampField] = now
                            elseif (now - ts) > RETAIN then
                                entry[raidKey] = nil; pruned = pruned + 1
                            end
                        end
                    end
                    if next(entry) == nil then t[charKey] = nil end
                end
            end
        end
        pruneAged("remoteRaidConfigs", "savedAt")
        pruneAged("remoteRaidConfigQueue", "queuedAt")
        for _, root in ipairs({ "remoteTrinketPush", "remoteReminderPush" }) do
            local t = ReadycheckDB[root]
            if type(t) == "table" then
                for charKey, entry in pairs(t) do
                    if type(entry) ~= "table" or entry.pendingPush ~= true then
                        t[charKey] = nil
                        pruned = pruned + 1
                    end
                end
            end
        end
        if pruned > 0 then
            self:DebugPrint("Pruned " .. pruned .. " stale remote mirror entries", "profile")
        end

        if cleaned > 0 then
            self:DebugPrint("Cleaned " .. cleaned .. " root-level legacy keys", "profile")
        end

        return cleaned
    end

    -- The raid consume reminders came out of testing: their settings move
    -- from profile.testConsumeRemind to profile.consumeRemind, once, with
    -- every pick kept. A consumeRemind that already has its own items (set
    -- up live, or imported) wins and the old table just goes. Flask of the
    -- Titans comes off a table that never had its one-time "titans off"
    -- pass, as testing did on load.
    function RC:MigrateConsumeRemind(profile)
        if type(profile) ~= "table" or profile.testConsumeRemind == nil then return false end
        local old = profile.testConsumeRemind
        profile.testConsumeRemind = nil
        if type(old) ~= "table" then return true end
        local cur = profile.consumeRemind
        if type(cur) == "table" and type(cur.items) == "table" then return true end
        local new = (RC.DeepCopy and RC.DeepCopy(old)) or old
        if type(new.items) ~= "table" then new.items = {} end
        if not new.titansOff1 then new.items[13510] = nil end
        new.titansOff1 = nil
        local dflt = RC.defaults and RC.defaults.consumeRemind
        for k, v in pairs(type(dflt) == "table" and dflt or {}) do
            if new[k] == nil then new[k] = v end
        end
        profile.consumeRemind = new
        return true
    end

    function RC:AutoCleanupProfile(charKey)
    if self.db and self.db.raidRoute and self.db.raidRoute.reminderPos ~= nil then
        self.db.raidRoute.reminderPos = nil
    end
    if self.db and self.db.raidRoute and self.db.raidRoute.trackerCustomSize ~= nil then
        self.db.raidRoute.trackerCustomSize = nil
    end
    if self.db then
        self.db.hotswapDPSSet = nil
    end
    if self.db and self.db.gearManager and self.db.gearManager.settings then
        self.db.gearManager.settings._spacingResetV1 = nil
    end
    if self.db and self.db.raidRoute then
        local rr = self.db.raidRoute
        rr.trackerH = nil
        local sagaW = { [280]=true, [340]=true, [360]=true }
        if sagaW[rr.trackerW] then rr.trackerW = nil end
        rr.completeTTS = nil
    end
        local profile = ReadycheckDB.characters and ReadycheckDB.characters[charKey]
        if not profile then return 0 end
        if RC._autoCleanupDone and RC._autoCleanupDone[charKey] then return 0 end
        if not RC._autoCleanupDone then RC._autoCleanupDone = {} end
        RC._autoCleanupDone[charKey] = true

        local cleaned = 0
        -- before the dead-field pass below drops the old key
        if self:MigrateConsumeRemind(profile) then cleaned = cleaned + 1 end

        -- Bump this and add a new "if profileVersion < N then ... end" block
        -- below for each one-time migration; each block sets
        -- profile.migrationVersion = CURRENT_MIGRATION_VERSION when it runs.
        local CURRENT_MIGRATION_VERSION = 19
        local profileVersion = profile.migrationVersion or 0

        -- Readycheck's sounds, font and bar texture are now its own: the
        -- sounds were remade and renamed, the font is Red Hat Display and
        -- the soft bar texture is "Readycheck Smooth". Every saved choice
        -- that names an old file or an old name is pointed at what
        -- replaced it, so each still plays and looks the same way.
        if profileVersion < 19 then
            local SND = "interface\\addons\\readycheck\\media\\sounds\\"
            local NEW = "Interface\\AddOns\\Readycheck\\Media\\Sounds\\"
            local STEMS = {
                clear_announce_tones = "announce", airhorn = "horn", access_allowed_tone = "access",
                arabian_mystery_harp_notification = "harp", atm_cash_machine_key_press = "keypress",
                bell_notification = "bell", correct_answer_reward = "correct", digital_quick_tone = "quicktone",
                dry_pop_up_notification_alert = "popup", elevator_tone = "elevator", final_level_bonus = "levelbonus",
                guitar_notification_alert = "guitar", happy_bells_notification = "happybells",
                interface_option_select = "select", magic_marimba = "marimba", magic_notification_ring = "magicring",
                melodical_flute_music_notification = "flute", software_interface_remove = "remove",
                software_interface_start = "start", tile_game_reveal = "reveal", unlock_game_notification = "unlock",
                video_game_win = "win", wrong_answer_fail_notification = "wrong",
            }
            local NAMES = { ["Naowh"] = "Red Hat Display", ["Melli"] = "Readycheck Smooth" }
            local FONT_OLD = "interface\\addons\\readycheck\\media\\naowh.ttf"
            local FONT_NEW = "Interface\\AddOns\\Readycheck\\Media\\Fonts\\RedHatDisplay-SemiBold.ttf"
            local function New(v)
                if NAMES[v] then return NAMES[v] end
                local l = v:lower():gsub("/", "\\")
                if l == FONT_OLD then return FONT_NEW end
                if l:sub(1, #SND) == SND then
                    local stem = l:sub(#SND + 1):gsub("%.ogg$", "")
                    if STEMS[stem] then return NEW .. STEMS[stem] .. ".ogg" end
                end
                return nil
            end
            local seen = {}
            local function Walk(t, depth)
                if seen[t] or depth > 30 then return end
                seen[t] = true
                for k, v in pairs(t) do
                    if type(v) == "table" then Walk(v, depth + 1)
                    elseif type(v) == "string" and v ~= "" then
                        local n = New(v)
                        if n then t[k] = n end
                    end
                end
            end
            Walk(profile, 0)
            profile.migrationVersion = CURRENT_MIGRATION_VERSION
            cleaned = cleaned + 1
        end

        -- Until now the "WR: Warning" sound pointed at a file that was never
        -- shipped, so every sound left on that default played nothing.
        -- It now points at a real file. To keep the game sounding exactly
        -- as it did, each sound that is on but still uses that default is
        -- switched off once. A sound set to anything else was audible
        -- before, so it is left alone.
        if profileVersion < 18 then
            -- the old missing file, and the file it is now rewritten to
            local DEFAULT_FILES = {
                ["Interface\\AddOns\\Readycheck\\Sounds\\Warning.ogg"] = true,
                ["Interface\\AddOns\\Readycheck\\Media\\Sounds\\clear_announce_tones.ogg"] = true,
                ["Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg"] = true,
            }
            local function oldDefault(key, file)
                if key == "WR: Warning" then return true end
                if key ~= nil and key ~= "" then return false end
                return file == nil or file == "" or DEFAULT_FILES[file] == true
            end
            local function quiet(t)
                if type(t) == "table" and t.playSound and oldDefault(t.soundKey, t.soundFile) then
                    t.playSound = false
                end
            end
            quiet(profile.repairReminder)
            quiet(profile.fastWeaponReminder)
            quiet(profile.battleShoutReminder)
            quiet(profile.consumablesChecker)
            quiet(profile.boonReminder)
            -- ability reminders: per-ability sounds first, then the global
            -- switch, which per-ability sounds also need, so it stays on
            -- while any of them still plays a real sound
            local keepGlobal = false
            if type(profile.abilityOverrides) == "table" then
                for _, ao in pairs(profile.abilityOverrides) do
                    if type(ao) == "table" and ao.soundEnabled then
                        if oldDefault(ao.soundKey, ao.soundFile) then
                            ao.soundEnabled = false
                        else
                            keepGlobal = true
                        end
                    end
                end
            end
            if profile.soundEnabled and oldDefault(profile.soundKey, profile.soundFile) and not keepGlobal then
                profile.soundEnabled = false
            end
            profile.migrationVersion = CURRENT_MIGRATION_VERSION
            cleaned = cleaned + 1
        end

        -- The repair reminder and spec detection sounds are now off by
        -- default. Both used to be filled in as on, so a saved "on" here
        -- is the old default, not a choice: turn it off once.
        if profileVersion < 17 then
            if type(profile.repairReminder) == "table" then
                profile.repairReminder.playSound = false
            end
            if type(profile.specDetection) == "table" then
                profile.specDetection.playSound = false
            end
            profile.migrationVersion = CURRENT_MIGRATION_VERSION
            cleaned = cleaned + 1
        end

        if profileVersion < 16 then
            if profile.consumablesHelper then
                profile.consumablesHelper.preferVoiceFiles = nil
                profile.consumablesHelper.voiceChannel = nil
                profile.consumablesHelper.pingOnQuietVoice = nil
            end
            profile.migrationVersion = CURRENT_MIGRATION_VERSION
            cleaned = cleaned + 1
        end

        if profileVersion < 3 then
            local oldAnchor = profile.anchorPoint or "TOP"

            profile.anchorPoint = "CENTER"
            profile.xOffset = 0
            profile.yOffset = 200

            profile.migrationVersion = CURRENT_MIGRATION_VERSION
            cleaned = cleaned + 1
            RC:DebugPrint("Migration v3: Reset position to CENTER (X=0, Y=200)", "profile")
        end

        if profileVersion < 6 then
            if profile.absorbTracking ~= nil then
                profile.absorbTracking = nil
                cleaned = cleaned + 1
            end
            if profile.buffPushoffAbsorbConsumed ~= nil then
                profile.buffPushoffAbsorbConsumed = nil
                cleaned = cleaned + 1
            end

            if profile.frostBlastConfig then
                if profile.frostBlastConfig.history ~= nil then
                    profile.frostBlastConfig.history = nil
                    cleaned = cleaned + 1
                end
                if profile.frostBlastConfig.peakMaxHp ~= nil then
                    profile.frostBlastConfig.peakMaxHp = nil
                    cleaned = cleaned + 1
                end
            end

            -- v6: custom reminders moved from COMBAT_LOG_EVENT_UNFILTERED
            -- triggers to plain frame events; anything with no mapping here
            -- gets disabled rather than silently firing on the wrong event.
            local CLEU_MIGRATION_MAP = {
                SPELL_CAST_SUCCESS_player  = { frameEvent = "UNIT_SPELLCAST_SUCCEEDED", unitFilter = "player" },
                SPELL_CAST_START_player    = { frameEvent = "UNIT_SPELLCAST_START",     unitFilter = "player" },
                SPELL_CAST_FAILED_player   = { frameEvent = "UNIT_SPELLCAST_FAILED",    unitFilter = "player" },
                SPELL_AURA_APPLIED_player  = { frameEvent = "UNIT_AURA",                unitFilter = "player" },
                SPELL_AURA_REMOVED_player  = { frameEvent = "UNIT_AURA",                unitFilter = "player" },
                SPELL_AURA_REFRESH_player  = { frameEvent = "UNIT_AURA",                unitFilter = "player" },
            }
            if profile.customReminders and profile.customReminders.reminders then
                local migrated, disabled = 0, 0
                for _, r in ipairs(profile.customReminders.reminders) do
                    if r and r.mode == "event" and r.eventTrigger and r.eventTrigger.eventCategory == "cleu" then
                        local cfg = r.eventTrigger
                        local keySrc  = cfg.source == "player" and "player" or nil
                        local keyDest = cfg.dest   == "player" and "player" or nil
                        local who = keySrc or keyDest
                        local mapKey = cfg.event and who and (cfg.event .. "_" .. who) or nil
                        local target = mapKey and CLEU_MIGRATION_MAP[mapKey] or nil
                        if target then
                            cfg.eventCategory = "frame"
                            cfg.frameEvent    = target.frameEvent
                            cfg.unitFilter    = target.unitFilter
                            cfg.event, cfg.source, cfg.dest = nil, nil, nil
                            migrated = migrated + 1
                        else
                            r.enabled = false
                            cfg.eventCategory = "frame"
                            cfg.frameEvent    = cfg.frameEvent or "RAID_BOSS_EMOTE"
                            cfg.event, cfg.source, cfg.dest = nil, nil, nil
                            disabled = disabled + 1
                        end
                        cleaned = cleaned + 1
                    end
                end
                if migrated > 0 or disabled > 0 then
                    RC:DebugPrint(string.format(
                        RCL["Migration v6: Custom reminders - %d migrated, %d disabled"],
                        migrated, disabled), "profile")
                end
            end

            profile.migrationVersion = CURRENT_MIGRATION_VERSION
            RC:DebugPrint("Migration v6: Zero-CLEU cleanup applied", "profile")
        end

        if profileVersion < 8 then
            local cleared = 0
            if profile.executeSettings and profile.executeSettings.fightHistory then
                local data = profile.executeSettings.fightHistory
                for key in pairs(data) do
                    if type(key) == "string" and key:find("Kel'Thuzad", 1, true) then
                        data[key] = nil
                        cleared = cleared + 1
                    end
                end
            end
            if RC.executeCalculator and RC.executeCalculator.fightHistory
               and RC.executeCalculator.fightHistory.data then
                for key in pairs(RC.executeCalculator.fightHistory.data) do
                    if type(key) == "string" and key:find("Kel'Thuzad", 1, true) then
                        RC.executeCalculator.fightHistory.data[key] = nil
                    end
                end
            end
            profile.migrationVersion = CURRENT_MIGRATION_VERSION
            RC:DebugPrint(string.format(RCL["Migration v8: Cleared %d Kel'Thuzad fight history bucket(s) polluted by add-phase time"], cleared), "profile")
        end

        if profileVersion < 9 then
            local merged = 0
            if profile.executeSettings and profile.executeSettings.fightHistory then
                local data = profile.executeSettings.fightHistory
                local toMerge = {}
                for key in pairs(data) do
                    if type(key) == "string" then
                        local prefix, boss = key:match("^(.+)_([^_]+)$")
                        if prefix and boss then
                            local stripped = boss:gsub("^[Tt]he%s+", "")
                            if stripped ~= boss then
                                toMerge[key] = prefix .. "_" .. stripped
                            end
                        end
                    end
                end
                for fromKey, toKey in pairs(toMerge) do
                    if data[toKey] then
                        for _, fight in ipairs(data[fromKey]) do
                            table.insert(data[toKey], fight)
                        end
                        table.sort(data[toKey], function(a, b)
                            return (a.timestamp or 0) > (b.timestamp or 0)
                        end)
                    else
                        data[toKey] = data[fromKey]
                    end
                    data[fromKey] = nil
                    merged = merged + 1
                end
            end
            profile.migrationVersion = CURRENT_MIGRATION_VERSION
            RC:DebugPrint(string.format(RCL["Migration v9: Merged %d 'The X' duplicate fight history buckets"], merged), "profile")
        end

        if profileVersion < 10 then
            local cleared = 0
            local addPhaseBosses = {}
            if RC.encounterAddPhases then
                for bossName, info in pairs(RC.encounterAddPhases) do
                    if info.addPhasesBeforeBoss then
                        addPhaseBosses[bossName] = true
                    end
                end
            end
            if profile.executeSettings and profile.executeSettings.fightHistory then
                local data = profile.executeSettings.fightHistory
                for key in pairs(data) do
                    if type(key) == "string" then
                        for boss in pairs(addPhaseBosses) do
                            local needle = "_" .. boss
                            if #key >= #needle and key:sub(-#needle) == needle then
                                data[key] = nil
                                cleared = cleared + 1
                                break
                            end
                        end
                    end
                end
            end
            if RC.executeCalculator and RC.executeCalculator.fightHistory
               and RC.executeCalculator.fightHistory.data then
                for key in pairs(RC.executeCalculator.fightHistory.data) do
                    if type(key) == "string" then
                        for boss in pairs(addPhaseBosses) do
                            local needle = "_" .. boss
                            if #key >= #needle and key:sub(-#needle) == needle then
                                RC.executeCalculator.fightHistory.data[key] = nil
                                break
                            end
                        end
                    end
                end
            end
            profile.migrationVersion = CURRENT_MIGRATION_VERSION
            RC:DebugPrint(string.format(RCL["Migration v10: Cleared %d add-phase boss history bucket(s) polluted by full encounter timing"], cleared), "profile")
        end

        if profileVersion < 11 then
            if profile.hotswapCombatMessage ~= nil then
                local oldVal = profile.hotswapCombatMessage
                if type(oldVal) == "string" and oldVal ~= ""
                   and (profile.hotswapCombatBlockMessage == nil
                        or profile.hotswapCombatBlockMessage == ""
                        or profile.hotswapCombatBlockMessage == "Can't swap - party member in combat!") then
                    profile.hotswapCombatBlockMessage = oldVal
                    RC:DebugPrint("Migration v11: Forwarded hotswapCombatMessage to hotswapCombatBlockMessage", "profile")
                end
            end
            if type(profile.gearSets) == "table" then
                local stripped = 0
                for _, setData in pairs(profile.gearSets) do
                    if type(setData) == "table" and setData.previewImage ~= nil then
                        setData.previewImage = nil
                        stripped = stripped + 1
                    end
                end
                if stripped > 0 then
                    RC:DebugPrint(string.format(RCL["Migration v11: Stripped previewImage from %d gear set(s)"], stripped), "profile")
                end
            end
            profile.migrationVersion = CURRENT_MIGRATION_VERSION
        end

        if profileVersion < 12 then
            if type(profile.hotswapSettings) == "table" then
                local sub = profile.hotswapSettings
                local fields = {
                    "hotswapEnabled", "hotswapT2Protect", "hotswapPartyAnnounce",
                    "hotswapAnnounceChannel", "hotswapAnnounceMessage",
                    "hotswapCombatBlockMessage",
                }
                local forwarded = 0
                for _, f in ipairs(fields) do
                    if profile[f] == nil and sub[f] ~= nil then
                        profile[f] = sub[f]
                        forwarded = forwarded + 1
                    end
                end
                if forwarded > 0 then
                    RC:DebugPrint(string.format(RCL["Migration v12: Forwarded %d hotswap field(s) from sub-table to flat"], forwarded), "profile")
                end
            end
            profile.migrationVersion = CURRENT_MIGRATION_VERSION
        end

        if profileVersion < 13 then
            if profile.raidProfiles then
                for _, raidStruct in pairs(profile.raidProfiles) do
                    if raidStruct and raidStruct.profiles then
                        for _, rp in pairs(raidStruct.profiles) do
                            if rp and rp.bosses and rp.bosses["Maexxna"]
                               and rp.bosses["Maexxna"].abilities then
                                if rp.bosses["Maexxna"].abilities.snowball ~= nil then
                                    rp.bosses["Maexxna"].abilities.snowball = nil
                                    cleaned = cleaned + 1
                                end
                            end
                        end
                    end
                end
            end
            profile.migrationVersion = CURRENT_MIGRATION_VERSION
            RC:DebugPrint("Migration v13: Removed Maexxna snowball entries", "profile")
        end

        if profileVersion < 14 then
            local REN = {
                ["Death Knight"] = "Deathknight",
                ["Death Knight Captain"] = "Deathknight Captain",
                ["Death Knight Cavalier"] = "Deathknight Cavalier",
                ["Spectral Death Knight"] = "Spectral Deathknight",
            }
            local n = 0
            local function fixList(mobs)
                if type(mobs) ~= "table" then return end
                for _, e in ipairs(mobs) do
                    if type(e) == "table" and REN[e.mob] then
                        e.mob = REN[e.mob]
                        n = n + 1
                    end
                end
            end
            if profile.raidProfiles then
                for _, rd in pairs(profile.raidProfiles) do
                    if type(rd) == "table" and type(rd.profiles) == "table" then
                        for _, prof in pairs(rd.profiles) do
                            local route = type(prof) == "table" and prof.route
                            if route and type(route.steps) == "table" then
                                for _, st in ipairs(route.steps) do
                                    if REN[st.mob] then
                                        st.mob = REN[st.mob]
                                        n = n + 1
                                    end
                                    fixList(st.mobs)
                                end
                            end
                        end
                    end
                end
            end
            if profile.bossNotes and type(profile.bossNotes.trashNotesList) == "table" then
                for _, list in pairs(profile.bossNotes.trashNotesList) do
                    if type(list) == "table" then
                        for _, note in ipairs(list) do
                            if type(note) == "table" then fixList(note.mobs) end
                        end
                    end
                end
            end
            profile.migrationVersion = CURRENT_MIGRATION_VERSION
            if n > 0 then
                cleaned = cleaned + 1
                RC:DebugPrint("Migration v14: renamed " .. n .. " Deathknight mob entries", "profile")
            end
        end

        if profileVersion < 15 then
            local REN = {
                ["Naxxramas Acolyte"] = "Necropolis Acolyte",
                ["Naxxramas Shade"] = "Spirit of Naxxramas",
            }
            local n = 0
            local function fixList(mobs)
                if type(mobs) ~= "table" then return end
                for _, e in ipairs(mobs) do
                    if type(e) == "table" and REN[e.mob] then
                        e.mob = REN[e.mob]
                        n = n + 1
                    end
                end
            end
            if profile.raidProfiles then
                for _, rd in pairs(profile.raidProfiles) do
                    if type(rd) == "table" and type(rd.profiles) == "table" then
                        for _, prof in pairs(rd.profiles) do
                            local route = type(prof) == "table" and prof.route
                            if route and type(route.steps) == "table" then
                                for _, st in ipairs(route.steps) do
                                    if REN[st.mob] then
                                        st.mob = REN[st.mob]
                                        n = n + 1
                                    end
                                    fixList(st.mobs)
                                end
                            end
                        end
                    end
                end
            end
            if profile.bossNotes and type(profile.bossNotes.trashNotesList) == "table" then
                for _, list in pairs(profile.bossNotes.trashNotesList) do
                    if type(list) == "table" then
                        for _, note in ipairs(list) do
                            if type(note) == "table" then fixList(note.mobs) end
                        end
                    end
                end
            end
            profile.migrationVersion = CURRENT_MIGRATION_VERSION
            if n > 0 then
                cleaned = cleaned + 1
                RC:DebugPrint("Migration v15: renamed " .. n .. " Acolyte/Spirit mob entries", "profile")
            end
        end

        for _, field in ipairs(DEAD_FIELDS.root) do
            if profile[field] ~= nil then
                profile[field] = nil
                cleaned = cleaned + 1
            end
        end

        -- worldBuffs.boardSortReverse is about to be stripped as a dead
        -- field. A board that was saved reversed keeps its order: the
        -- flag becomes the "-" in front of its one sort key.
        do
            local wb = profile.worldBuffs
            if type(wb) == "table" and wb.boardSortReverse == true
               and type(wb.boardSort) == "string" and wb.boardSort:find("^%a+$") then
                wb.boardSort = "-" .. wb.boardSort
            end
        end

        local holdWeapons = HoldOldHordeMode(profile, charKey)
        for _, section in ipairs(DEAD_FIELD_SECTIONS) do
            local sub = profile[section]
            if sub and DEAD_FIELDS[section] and not (holdWeapons and section == "weaponsBar") then
                for _, field in ipairs(DEAD_FIELDS[section]) do
                    if sub[field] ~= nil then
                        sub[field] = nil
                        cleaned = cleaned + 1
                    end
                end
            end
        end

        if profile.customColors then
            for category, keys in pairs(DEAD_FIELDS.customColors) do
                if profile.customColors[category] then
                    for _, key in ipairs(keys) do
                        if profile.customColors[category][key] ~= nil then
                            profile.customColors[category][key] = nil
                            cleaned = cleaned + 1
                            self:DebugPrint("Removed obsolete color key: " .. category .. "." .. key, "profile")
                        end
                    end
                end
            end
        end

        if profile.executeSettings and profile.executeSettings.fightHistory then
            if type(profile.executeSettings.fightHistory) ~= "table" then
                profile.executeSettings.fightHistory = {}
                cleaned = cleaned + 1
            end
        end

        if profile.consumablesChecker and profile.consumablesChecker.disabledItems then
            for itemId in pairs(INVALID_CONSUMABLE_ITEMS) do
                if profile.consumablesChecker.disabledItems[itemId] then
                    profile.consumablesChecker.disabledItems[itemId] = nil
                    cleaned = cleaned + 1
                    self:DebugPrint("Removed invalid consumable item: " .. itemId, "profile")
                end
                local strId = tostring(itemId)
                if profile.consumablesChecker.disabledItems[strId] then
                    profile.consumablesChecker.disabledItems[strId] = nil
                    cleaned = cleaned + 1
                    self:DebugPrint("Removed invalid consumable item (string): " .. strId, "profile")
                end
            end

            if RC.raidConsumables then
                local validItemIds = {}
                for categoryKey, category in pairs(RC.raidConsumables) do
                    if category.items then
                        for itemId in pairs(category.items) do
                            validItemIds[itemId] = true
                            validItemIds[tostring(itemId)] = true
                        end
                    end
                end

                -- other classes' rows (DB_Consumables drops them at load)
                -- still count, for a profile shared between classes
                for itemId in pairs(RC.classItemIds or {}) do
                    validItemIds[itemId] = true
                    validItemIds[tostring(itemId)] = true
                end

                -- so do every game version's items: a pick for an item this
                -- version does not have comes back on the version that has it
                for itemId in pairs(RC:KnownConsumableItemIds()) do
                    validItemIds[itemId] = true
                    validItemIds[tostring(itemId)] = true
                end

                if profile.consumablesChecker.customItems then
                    for itemId in pairs(profile.consumablesChecker.customItems) do
                        validItemIds[itemId] = true
                        validItemIds[tostring(itemId)] = true
                    end
                end

                local toRemove = {}
                for itemId in pairs(profile.consumablesChecker.disabledItems) do
                    if not validItemIds[itemId] and not validItemIds[tonumber(itemId)] then
                        table.insert(toRemove, itemId)
                    end
                end

                for _, itemId in ipairs(toRemove) do
                    profile.consumablesChecker.disabledItems[itemId] = nil
                    cleaned = cleaned + 1
                    self:DebugPrint("Removed orphaned disabledItem: " .. tostring(itemId), "profile")
                end
            end
        end

        local function ValidateCustomItemTable(customItems, barLabel)
            if type(customItems) ~= "table" then return end
            for itemId, data in pairs(customItems) do
                if type(data) == "table" then
                    if data.buffId ~= nil and type(data.buffId) ~= "number" then
                        local n = tonumber(data.buffId)
                        if n and n > 0 then
                            data.buffId = n
                        else
                            data.buffId = nil
                        end
                        cleaned = cleaned + 1
                        self:DebugPrint("Scrubbed malformed buffId on " .. barLabel .. " item " .. tostring(itemId), "profile")
                    elseif type(data.buffId) == "number" and data.buffId <= 0 then
                        data.buffId = nil
                        cleaned = cleaned + 1
                    end
                    if data.materials ~= nil then
                        if type(data.materials) ~= "table" then
                            data.materials = nil
                            cleaned = cleaned + 1
                            self:DebugPrint("Scrubbed malformed materials on " .. barLabel .. " item " .. tostring(itemId), "profile")
                        else
                            local cleanList = {}
                            for _, mat in ipairs(data.materials) do
                                if type(mat) == "table" then
                                    local mid = tonumber(mat.itemId)
                                    local q   = tonumber(mat.qty) or 1
                                    if mid and mid > 0 and q > 0 then
                                        table.insert(cleanList, {
                                            itemId = mid, qty = q,
                                            name = mat.name, ahSearchName = mat.ahSearchName,
                                        })
                                    end
                                end
                            end
                            if #cleanList == 0 then
                                data.materials = nil
                            else
                                data.materials = cleanList
                            end
                        end
                    end
                end
            end
        end
        if profile.consumablesHelper then
            ValidateCustomItemTable(profile.consumablesHelper.customItems, "consumables")
        end
        if profile.potionsBar then
            ValidateCustomItemTable(profile.potionsBar.customItems, "potions")
        end
        if profile.consumablesChecker then
            ValidateCustomItemTable(profile.consumablesChecker.customItems, "checker")
        end

        if RC.db and RC.db.consumablesHelper then
            RC.db.consumablesHelper.alwaysShowWeaponStones = nil
        end

        if profile.showWarriorFeatures ~= nil then
            if profile.showWarriorFeatures == true then
                profile.nonWarriorEnabled = profile.nonWarriorEnabled or {}
                profile.nonWarriorEnabled.hotswap = true
                profile.nonWarriorEnabled.mc   = true
                profile.nonWarriorEnabled.bwl  = true
                profile.nonWarriorEnabled.aq40 = true
                profile.nonWarriorEnabled.naxx = true
            end
            profile.showWarriorFeatures = nil
            cleaned = cleaned + 1
            self:DebugPrint("Removed obsolete showWarriorFeatures key", "profile")
        end

        if profile.raidSettings then
            local oldPotionKeys = OLD_POTION_KEYS_RAIDSETTINGS

            for raidName, raidData in pairs(profile.raidSettings) do
                if raidData.bosses then
                    for bossName, bossData in pairs(raidData.bosses) do
                        if bossData.abilities then
                            for _, oldKey in ipairs(oldPotionKeys) do
                                if bossData.abilities[oldKey] then
                                    bossData.abilities[oldKey] = nil
                                    cleaned = cleaned + 1
                                    self:DebugPrint(string.format(RCL["Removed OLD potion key '%s' from raidSettings/%s/%s"],
                                        oldKey, raidName, bossName), "profile")
                                end
                            end
                        end
                    end
                end
                if raidData.trash then
                    for mobName, mobData in pairs(raidData.trash) do
                        if mobData.abilities then
                            for _, oldKey in ipairs(oldPotionKeys) do
                                if mobData.abilities[oldKey] then
                                    mobData.abilities[oldKey] = nil
                                    cleaned = cleaned + 1
                                    self:DebugPrint(string.format(RCL["Removed OLD potion key '%s' from raidSettings/%s/trash/%s"],
                                        oldKey, raidName, mobName), "profile")
                                end
                            end
                        end
                    end
                end
            end

            profile.raidSettings = nil
            cleaned = cleaned + 1
            self:DebugPrint("Removed legacy raidSettings key (system now uses raidProfiles)", "profile")
        end

        if profile.raidProfiles and profileVersion < 4 then
            for raidName, raidData in pairs(profile.raidProfiles) do
                if raidData.profiles then
                    for profileName, profileData in pairs(raidData.profiles) do
                        if profileData.bosses then
                            for bossName, bossData in pairs(profileData.bosses) do
                                if bossData.abilities then
                                    for abilityKey, abilitySettings in pairs(bossData.abilities) do
                                        if abilitySettings.combatTime and not abilitySettings.combatStartDelay then
                                            abilitySettings.combatStartDelay = abilitySettings.combatTime
                                            abilitySettings.combatTime = nil
                                            cleaned = cleaned + 1
                                            self:DebugPrint(string.format(RCL["Migrated combatTime->combatStartDelay for %s/%s/%s"],
                                                raidName, bossName, abilityKey), "profile")
                                        elseif abilitySettings.combatTime then
                                            abilitySettings.combatTime = nil
                                            cleaned = cleaned + 1
                                        end

                                        local isPotionKey = (type(abilityKey) == "string" and abilityKey:lower():find("potion") and abilityKey ~= "freeActionPotion")
                                        if isPotionKey and abilitySettings.enabled then
                                            if not abilitySettings.potionType then
                                                abilitySettings.potionType = "mightyRagePotion"
                                                cleaned = cleaned + 1
                                                self:DebugPrint(string.format(RCL["Added missing potionType for %s/%s/%s"],
                                                    raidName, bossName, abilityKey), "profile")
                                            end
                                            if not abilitySettings.hpValue or abilitySettings.hpValue == 85 then
                                                abilitySettings.hpValue = 20
                                                cleaned = cleaned + 1
                                                self:DebugPrint(string.format(RCL["Fixed hpValue for potion %s/%s/%s"],
                                                    raidName, bossName, abilityKey), "profile")
                                            end
                                        end
                                    end

                                    for _, oldKey in ipairs(OLD_POTION_KEYS_V4) do
                                        if bossData.abilities[oldKey] then
                                            bossData.abilities[oldKey] = nil
                                            cleaned = cleaned + 1
                                            self:DebugPrint(string.format(RCL["Removed OLD potion key %s from %s/%s (use 'potion' key with potionType)"],
                                                oldKey, raidName, bossName), "profile")
                                        end
                                    end
                                end
                            end
                        end
                        if profileData.trash then
                            for mobName, mobData in pairs(profileData.trash) do
                                if mobData.abilities then
                                    for abilityKey, abilitySettings in pairs(mobData.abilities) do
                                        if abilitySettings.combatTime and not abilitySettings.combatStartDelay then
                                            abilitySettings.combatStartDelay = abilitySettings.combatTime
                                            abilitySettings.combatTime = nil
                                            cleaned = cleaned + 1
                                            self:DebugPrint(string.format(RCL["Migrated combatTime->combatStartDelay for %s/trash/%s/%s"],
                                                raidName, mobName, abilityKey), "profile")
                                        elseif abilitySettings.combatTime then
                                            abilitySettings.combatTime = nil
                                            cleaned = cleaned + 1
                                        end

                                        local isPotionKey = (type(abilityKey) == "string" and abilityKey:lower():find("potion") and abilityKey ~= "freeActionPotion")
                                        if isPotionKey and abilitySettings.enabled then
                                            if not abilitySettings.potionType then
                                                abilitySettings.potionType = "mightyRagePotion"
                                                cleaned = cleaned + 1
                                                self:DebugPrint(string.format(RCL["Added missing potionType for %s/trash/%s/%s"],
                                                    raidName, mobName, abilityKey), "profile")
                                            end
                                            if not abilitySettings.hpValue or abilitySettings.hpValue == 85 then
                                                abilitySettings.hpValue = 20
                                                cleaned = cleaned + 1
                                                self:DebugPrint(string.format(RCL["Fixed hpValue for potion %s/trash/%s/%s"],
                                                    raidName, mobName, abilityKey), "profile")
                                            end
                                        end
                                    end

                                    for _, oldKey in ipairs(OLD_POTION_KEYS_V4) do
                                        if mobData.abilities[oldKey] then
                                            mobData.abilities[oldKey] = nil
                                            cleaned = cleaned + 1
                                            self:DebugPrint(string.format(RCL["Removed OLD potion key %s from %s/trash/%s (use 'potion' key with potionType)"],
                                                oldKey, raidName, mobName), "profile")
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if cleaned > 0 then
            self:DebugPrint("Auto-cleaned " .. cleaned .. " dead fields from profile: " .. charKey, "profile")
        end

        return cleaned
    end

    function RC:AnalyzeProfileForCleanup(charKey)
        local profile = ReadycheckDB.characters and ReadycheckDB.characters[charKey]
        if not profile then
            return nil, "Profile not found"
        end

        local issues = {
            deadFields = {},
            corruptedData = {},
            orphanedData = {},
            totalIssues = 0
        }

        for _, field in ipairs(DEAD_FIELDS.root) do
            if profile[field] ~= nil then
                table.insert(issues.deadFields, field)
                issues.totalIssues = issues.totalIssues + 1
            end
        end

        for _, section in ipairs(DEAD_FIELD_SECTIONS) do
            local sub = profile[section]
            if sub and DEAD_FIELDS[section] then
                for _, field in ipairs(DEAD_FIELDS[section]) do
                    if sub[field] ~= nil then
                        table.insert(issues.deadFields, section .. "." .. field)
                        issues.totalIssues = issues.totalIssues + 1
                    end
                end
            end
        end

        if profile.executeSettings and profile.executeSettings.fightHistory then
            local fh = profile.executeSettings.fightHistory
            if type(fh) ~= "table" then
                table.insert(issues.corruptedData, "executeSettings.fightHistory (not a table)")
                issues.totalIssues = issues.totalIssues + 1
            end
        end

        if profile.raidSettings then
            table.insert(issues.orphanedData, "raidSettings (deprecated, will be auto-removed)")
            issues.totalIssues = issues.totalIssues + 1
        end

        if profile.consumablesChecker and profile.consumablesChecker.disabledItems then
            for itemId in pairs(INVALID_CONSUMABLE_ITEMS) do
                if profile.consumablesChecker.disabledItems[itemId] or profile.consumablesChecker.disabledItems[tostring(itemId)] then
                    table.insert(issues.orphanedData, "consumablesChecker.disabledItems[" .. itemId .. "]")
                    issues.totalIssues = issues.totalIssues + 1
                end
            end
        end

        return issues
    end

    function RC:CleanupProfile(charKey, dryRun)
        local profile = ReadycheckDB.characters and ReadycheckDB.characters[charKey]
        if not profile then
            return 0, "Profile not found"
        end

        local cleaned = 0
        local details = {}

        if not dryRun then self:MigrateConsumeRemind(profile) end
        for _, field in ipairs(DEAD_FIELDS.root) do
            if profile[field] ~= nil then
                if not dryRun then
                    profile[field] = nil
                end
                cleaned = cleaned + 1
                table.insert(details, "Removed: " .. field)
            end
        end

        local holdWeapons = (not dryRun) and HoldOldHordeMode(profile, charKey)
        for _, section in ipairs(DEAD_FIELD_SECTIONS) do
            local sub = profile[section]
            if sub and DEAD_FIELDS[section] and not (holdWeapons and section == "weaponsBar") then
                for _, field in ipairs(DEAD_FIELDS[section]) do
                    if sub[field] ~= nil then
                        if not dryRun then
                            sub[field] = nil
                        end
                        cleaned = cleaned + 1
                        table.insert(details, "Removed: " .. section .. "." .. field)
                    end
                end
            end
        end

        if profile.executeSettings and profile.executeSettings.fightHistory then
            if type(profile.executeSettings.fightHistory) ~= "table" then
                if not dryRun then
                    profile.executeSettings.fightHistory = {}
                end
                cleaned = cleaned + 1
                table.insert(details, "Fixed: executeSettings.fightHistory (reset to empty table)")
            end
        end

        if profile.consumablesChecker and profile.consumablesChecker.disabledItems then
            for itemId in pairs(INVALID_CONSUMABLE_ITEMS) do
                if profile.consumablesChecker.disabledItems[itemId] then
                    if not dryRun then
                        profile.consumablesChecker.disabledItems[itemId] = nil
                    end
                    cleaned = cleaned + 1
                    table.insert(details, "Removed: consumablesChecker.disabledItems[" .. itemId .. "]")
                end
                local strId = tostring(itemId)
                if profile.consumablesChecker.disabledItems[strId] then
                    if not dryRun then
                        profile.consumablesChecker.disabledItems[strId] = nil
                    end
                    cleaned = cleaned + 1
                    table.insert(details, "Removed: consumablesChecker.disabledItems[" .. strId .. "]")
                end
            end
        end

        return cleaned, details
    end

    function RC:CleanupAllProfiles(dryRun)
        if not ReadycheckDB or not ReadycheckDB.characters then
            return 0, 0, "No saved data found"
        end

        local totalCleaned = 0
        local profilesCleaned = 0
        local allDetails = {}

        for charKey, _ in pairs(ReadycheckDB.characters) do
            local cleaned, details = self:CleanupProfile(charKey, dryRun)
            if cleaned > 0 then
                profilesCleaned = profilesCleaned + 1
                totalCleaned = totalCleaned + cleaned
                table.insert(allDetails, charKey .. ": " .. cleaned .. " items")
            end
        end

        return totalCleaned, profilesCleaned, allDetails
    end

    function RC:HandleCleanupCommand(args)
        local confirm = args and args:lower() == "confirm"

        self:Print(RCL["|cFFFFD700=== SavedVariables Cleanup Utility ===|r"])

        local charKey = self:GetCharacterKey()
        local issues = self:AnalyzeProfileForCleanup(charKey)

        if issues then
            self:Print(RCL["|cFF00FFFFCurrent character:|r "] .. charKey)

            if issues.totalIssues == 0 then
                self:Print(RCL["|cFF00FF00No issues found - profile is clean!|r"])
            else
                self:Print(RCL["|cFFFF6600Found "] .. issues.totalIssues .. RCL[" issues:|r"])

                if #issues.deadFields > 0 then
                    self:Print(RCL["  |cFFFFFF00Dead fields:|r "] .. table.concat(issues.deadFields, ", "))
                end
                if #issues.corruptedData > 0 then
                    self:Print(RCL["  |cFFFF0000Corrupted data:|r "] .. table.concat(issues.corruptedData, ", "))
                end
                if #issues.orphanedData > 0 then
                    self:Print(RCL["  |cFF888888Orphaned data:|r "] .. table.concat(issues.orphanedData, ", "))
                end
            end
        end

        local totalIssues = 0
        local profilesWithIssues = 0

        if ReadycheckDB and ReadycheckDB.characters then
            for key, _ in pairs(ReadycheckDB.characters) do
                local profIssues = self:AnalyzeProfileForCleanup(key)
                if profIssues and profIssues.totalIssues > 0 then
                    totalIssues = totalIssues + profIssues.totalIssues
                    profilesWithIssues = profilesWithIssues + 1
                end
            end
        end

        self:Print("")
        self:Print(RCL["|cFF00FFFFAll profiles:|r "] .. profilesWithIssues .. RCL[" profiles with "] .. totalIssues .. RCL[" total issues"])

        if totalIssues == 0 then
            self:Print(RCL["|cFF00FF00All profiles are clean! No cleanup needed.|r"])
            return
        end

        if confirm then
            local cleaned, profilesCleaned, details = self:CleanupAllProfiles(false)
            self:Print("")
            self:Print(RCL["|cFF00FF00Cleanup complete!|r"])
            self:Print(RCL["Cleaned "] .. cleaned .. RCL[" items from "] .. profilesCleaned .. RCL[" profiles"])
            if type(details) == "table" then
                for _, detail in ipairs(details) do
                    self:Print("  " .. detail)
                end
            end
            self:Print(RCL["|cFFFFFF00Note: Changes will be saved when you logout/reload|r"])
        else
            local cleaned, profilesCleaned, details = self:CleanupAllProfiles(true)
            self:Print("")
            self:Print(RCL["|cFFFFFF00DRY RUN - Would clean "] .. cleaned .. RCL[" items from "] .. profilesCleaned .. RCL[" profiles|r"])
            self:Print("")
            self:Print(RCL["To perform cleanup, type: |cFF00FFFF/rc cleanup confirm|r"])
        end
    end

    function RC:ResetCurrentProfile()
        local charKey = self:GetCharacterKey()
        if not charKey then
            self:Print(RCL["|cFFFF0000Error: Could not get character key|r"])
            return
        end

        if ReadycheckDB and ReadycheckDB.characters then
            ReadycheckDB.characters[charKey] = nil
        end

        self:Print(RCL["|cFFFFFF00Please /reload to reinitialize with defaults|r"])
    end

