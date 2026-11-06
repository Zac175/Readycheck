------------------------------------------------------------------------
-- Readycheck - TTK Model
-- Time-to-kill estimator: fight-history keying, outlier rejection,
-- EWMA smoothing, and the two prediction paths.
-- Both estimators return (totalFightSeconds, confidence 0..1):
--   PredictTTK - historical, median or EWMA over past kill durations
--     stored under the same boss key.
--   GetClassicTTKPrediction - live, extrapolates seconds-per-HP-percent
--     from the current fight with an execute-phase speedup multiplier.
-- GetCurrentTTKPrediction picks one and returns seconds REMAINING
-- (total minus elapsed since bossEngageTime).
------------------------------------------------------------------------
local RCC = _G.Readycheck
local UnitBuff = UnitBuff or (RCC and RCC.Compat and RCC.Compat.UnitBuff)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min, math_abs = math.floor, math.ceil, math.max, math.min, math.abs
local math_sqrt, math_pow = math.sqrt, math.pow
local GetTime, UnitGUID, UnitHealth, UnitHealthMax = GetTime, UnitGUID, UnitHealth, UnitHealthMax
local UnitName, UnitExists = UnitName, UnitExists
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format = string.format
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
RC._ttk = RC._ttk or {}
local _ttk = RC._ttk
    -- Persisted per character as executeSettings and shipped over the mesh.
    -- Counts are fights, times are seconds, *HP is percent of boss max HP.
    if not RC.executeCalculator then
        RC.executeCalculator = {
            -- Retention cap per boss key, not a model window: PredictTTK
            -- only ever reads maxSamplesForPrediction of these.
            fightHistory = {
                maxHistorySize = 500,
                data = {}
            },

            -- outlierThreshold is a z-score in standard deviations; below
            -- confidenceThreshold the ML path yields to the classic one.
            mlConfig = {
                minSamplesForPrediction = 2,
                maxSamplesForPrediction = 20,
                confidenceThreshold = 0.25,
                outlierThreshold = 2.0,
                -- prefer kills played on this character's class
                matchClass = false,
                -- predictions also use the kills of related raid configs
                -- (GetLinkedFightHistoryForBoss); nil counts as on
                shareRelated = true,
            },

            -- Execute-phase speedup: the last executeThreshold percent
            -- burns ~1.6x faster. A divisor on the execute time segment.
            classicMultipliers = {
                global = 1.6,
                perBoss = {}
            },

            -- alpha 0.3 gives the newest kill 30% weight. Under minSamples
            -- cleaned fights the estimator uses the plain median instead.
            ewma = {
                enabled = true,
                alpha = 0.3,
                minSamples = 3
            },

            currentFight = {
                started = false,
                startTime = 0,
                targetGUID = nil,
                targetName = nil,
                encounterName = nil,
                raidName = nil,

                bossEngaged = false,
                bossEngageTime = 0,
                encounterStartTime = 0,
                addPhasesBeforeBoss = false,

                enterExecuteTime = 0,
                executeStartHP = 0,

                maxHP = 0,
                isMultiCombatEncounter = false,
                isBossFight = false,
                isTestFight = false,

                primaryBoss = {
                    name = nil,
                    guid = nil,
                    isActive = false
                }
            },

            uiSettings = {
                filterRaid = "All",
                filterBoss = "All",
                sortBy = "recent",
                showOnlyBosses = false,
                showOnlyMultiCombat = false,
                minFights = 1,
                minConfidence = 0
            },

            -- Percent of boss max HP at which execute phase is declared.
            executeThreshold = 20,
            collectData = true,

            mode = "intelligent",

            dataCollection = {
                disabled = false,
                disabledBosses = {},
            },

            testMode = {
                enabled = false,
                treatAsRaidBoss = true,
                currentTestTarget = nil,
                testRaidName = "TEST"
            }
        }
    end

    -- GetEffectiveRaidName moved to Systems\RaidData\RaidLookup.lua in the
    -- main addon - 21 core call sites need it whether or not this addon
    -- is loaded. It nil-guards executeCalculator, which lives here.

    --------------------------------------------------------------------
    -- ONE TTK FOR EVERYTHING
    -- The ability reminders, the TTK HUD and custom reminders all read the
    -- same time-left number, RC:GetTTKRemaining(), so what the HUD shows is
    -- what fires the reminders. The pieces it is built from:
    --   TTKBossName        the one name a boss's kills are filed under
    --   GetFightExpectedTTK the usual kill time from history, fixed for the
    --                      fight at engage (re-read once if Sayge lands)
    --   GetEncounterHP     the boss's health; every boss of a multi-boss
    --                      encounter summed
    --   GetClassicTTKPrediction  the live kill speed this pull
    -- histVersion goes up on every change to the kill history, so cached
    -- predictions are rebuilt only when something actually changed.
    --------------------------------------------------------------------
    _ttk.histVersion = _ttk.histVersion or 0
    function RC:TTKHistoryChanged()
        _ttk.histVersion = (_ttk.histVersion or 0) + 1
    end

    -- What a TTK trigger with no number saved means: an offset on top of
    -- the trinket's buff for the two trinket slots, seconds left otherwise.
    RC.TTK_DEFAULT_SECONDS = 30
    RC.TTK_DEFAULT_TRINKET_OFFSET = 3
    function RC:TTKDefaultValue(abilityKey)
        if abilityKey == "trinket1" or abilityKey == "trinket2" then
            return RC.TTK_DEFAULT_TRINKET_OFFSET
        end
        return RC.TTK_DEFAULT_SECONDS
    end

    -- The buff length a TTK trinket reminder plans for, for the trinket in
    -- that slot now: known table, then the scanner, else 20s.
    -- Returns seconds, itemId, and true when it is the 20s guess.
    function RC:GetTTKTrinketBuffDuration(slotId)
        local itemId = GetInventoryItemID and GetInventoryItemID("player", slotId)
        if not itemId then return 20, nil, true end
        if self.trinketBuffDurations and self.trinketBuffDurations[itemId] then
            return self.trinketBuffDurations[itemId], itemId, false
        end
        local sc = self.TrinketScanner and self.TrinketScanner.autoDetectedTrinkets
        if sc and sc[itemId] and sc[itemId].buffDuration then
            return sc[itemId].buffDuration, itemId, false
        end
        return 20, itemId, true
    end

    -- The name a boss's kills are filed and looked up under. A member of a
    -- multi-boss encounter (Lady Blaumeux), an add listed as an alias
    -- (Stalagg) and a phase page ("C'Thun_phase1") all fold onto the
    -- encounter, and "The Four Horsemen" matches "Four Horsemen". Anything
    -- not in encounterAddPhases is returned as it is.
    local bossNameCache = {}
    local function NormBossName(s)
        s = s:gsub("^[Tt]he%s+", "")
        return (s:gsub("[%s%-']+", "")):lower()
    end
    function RC:TTKBossName(raidName, name)
        if type(name) ~= "string" or name == "" then return name end
        local ck = tostring(raidName) .. "\1" .. name
        local v = bossNameCache[ck]
        if v then return v end
        v = name
        local enc = self.encounterAddPhases
        if enc then
            local base = name:match("^(.+)_phase%d+$")
            if base and enc[base] then
                v = base
            elseif not enc[name] then
                local n = NormBossName(name)
                for canon, info in pairs(enc) do
                    if not raidName or not info.zone or info.zone == raidName then
                        local hit = (NormBossName(canon) == n)
                        if not hit and info.aliases then
                            for _, a in ipairs(info.aliases) do
                                if NormBossName(a) == n then hit = true break end
                            end
                        end
                        if hit then v = canon break end
                    end
                end
            end
        end
        bossNameCache[ck] = v
        return v
    end

    function RC:GetEncounterName(bossName, raidName)
        if self.GetEncounterNameForBoss then
            return self:GetEncounterNameForBoss(raidName, bossName)
        end

        return bossName
    end

    function RC:InitializeBossUnitTracking()
        if self.bossUnitTracker then return end

        self.bossUnitTracker = CreateFrame("Frame")
        self.bossUnitTracker.lastUpdate = 0

        self.bossUnitTracker:RegisterEvent("INSTANCE_ENCOUNTER_ENGAGE_UNIT")

        -- Scoped to "target" so this cannot fire once per raid member. The
        -- handler stays a cheap compare; heavy work goes in the ticker.
        self.bossUnitTracker:RegisterUnitEvent("UNIT_HEALTH", "target")

        self.bossUnitTracker:SetScript("OnEvent", function(self, event, ...)
            RC:HandleBossUnitEvent(event, ...)
        end)
    end

    function RC:HandleBossUnitEvent(event, ...)
        if event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
            self:ScanRaidForBoss()
        elseif event == "UNIT_HEALTH" then
            local unit = ...
            if unit ~= "target" then return end

            local fight = self.executeCalculator and self.executeCalculator.currentFight
            if not fight or not fight.started then return end
            if not fight.addPhasesBeforeBoss or fight.bossEngaged then return end
            if not UnitExists("target") or UnitIsDead("target") then return end

            local targetName = UnitName("target")
            if targetName ~= fight.encounterName
               and (not fight.primaryBoss or targetName ~= fight.primaryBoss.name)
            then
                return
            end

            local currentHP = UnitHealth("target")
            local maxHP     = UnitHealthMax("target")
            if maxHP > 0 and currentHP < maxHP then
                self:DebugPrint("Boss engagement detected via UNIT_HEALTH (target='" .. targetName .. "')", "execute")
                self:EngageBoss()
            end
        end
    end

    function RC:UpdateBossHPFromUnit(unit)
        if not unit or not UnitExists(unit) then return end

        local currentHP = UnitHealth(unit)
        local maxHP = UnitHealthMax(unit)
        local hpPercent = (currentHP / maxHP) * 100

        local fight = self.executeCalculator.currentFight
        if fight.started then
            local name = UnitName(unit)

            if fight.addPhasesBeforeBoss and not fight.bossEngaged then
                if name == fight.encounterName or name == fight.primaryBoss.name then
                    if maxHP > 0 and currentHP < maxHP then
                        self:EngageBoss()
                    end
                end
            end

            fight.primaryBoss.lastHP = currentHP
            fight.primaryBoss.lastMaxHP = maxHP
            fight.primaryBoss.lastUpdate = GetTime()
        end
    end

    function RC:ScanRaidForBoss()
        local fight = self.executeCalculator.currentFight
        if not fight.started then return end
        local nowScan = GetTime()
        if self._lastRaidBossScan and (nowScan - self._lastRaidBossScan) < 0.25 then
            return
        end
        self._lastRaidBossScan = nowScan

        for i = 1, 40 do
            local unit = "raid" .. i .. "target"
            if UnitExists(unit) and UnitCanAttack("player", unit) then
                local name = UnitName(unit)
                if name == fight.encounterName or name == fight.primaryBoss.name then
                    self:UpdateBossHPFromUnit(unit)

                    if fight.addPhasesBeforeBoss and not fight.bossEngaged then
                        local currentHP = UnitHealth(unit)
                        local maxHP = UnitHealthMax(unit)
                        if maxHP > 0 and currentHP < maxHP then
                            self:EngageBoss()
                        end
                    end
                    return
                end
            end
        end
    end

    -- Simulation mock, then live target, then the primaryBoss cache from
    -- the last raid scan - and that cache is only trusted for 2s, past
    -- which callers get nil and skip rather than use a stale percent.
    function RC:GetBossHealthData()
        local fight = self.executeCalculator.currentFight
        if not fight.started then return nil end

        if self.activeSimulation and self.activeSimulation.mockTarget then
            local mock = self.activeSimulation.mockTarget
            return {
                name = self.activeSimulation.bossName,
                currentHP = mock.currentHP,
                maxHP = mock.maxHP,
                hpPercent = mock.currentHPPercent,
                unit = "simulation"
            }
        end

        if UnitExists("target") and not UnitIsDead("target") then
            local name = UnitName("target")
            if name == fight.encounterName or name == fight.primaryBoss.name then
                local currentHP = UnitHealth("target")
                local maxHP = UnitHealthMax("target")
                return {
                    name = name,
                    currentHP = currentHP,
                    maxHP = maxHP,
                    hpPercent = (currentHP / maxHP) * 100,
                    unit = "target"
                }
            end
        end

        if fight.primaryBoss.lastUpdate and (GetTime() - fight.primaryBoss.lastUpdate) < 2 then
            return {
                name = fight.primaryBoss.name,
                currentHP = fight.primaryBoss.lastHP,
                maxHP = fight.primaryBoss.lastMaxHP,
                hpPercent = (fight.primaryBoss.lastHP / fight.primaryBoss.lastMaxHP) * 100,
                unit = "cached"
            }
        end

        return nil
    end

    -- The encounter config of a multi-boss fight (every alias a boss of
    -- it - Four Horsemen, Twin Emperors, Silithid Royalty), else nil.
    function RC:TTKMultiBossConfig(fight)
        fight = fight or (self.executeCalculator and self.executeCalculator.currentFight)
        if not (fight and fight.started) then return nil end
        local name = fight.historyName or fight.encounterName
        local cfg = name and self.encounterAddPhases and self.encounterAddPhases[name]
        if cfg and cfg.aliasesAreEncounter and cfg.aliases and #cfg.aliases > 1 then
            return cfg
        end
        return nil
    end

    -- Multi-boss fights: every boss of the encounter the raid can see,
    -- by GUID, so their health can be summed. Run from the 0.5s execute
    -- ticker; a dead boss counts as 0. A boss nobody has targeted yet is
    -- simply missing, and GetEncounterHP then reports the total as
    -- incomplete.
    function RC:UpdateEncounterUnits()
        local fight = self.executeCalculator and self.executeCalculator.currentFight
        local cfg = self:TTKMultiBossConfig(fight)
        if not cfg then return end
        local names = cfg._ttkNameSet
        if not names then
            names = {}
            for _, a in ipairs(cfg.aliases) do names[a] = true end
            cfg._ttkNameSet = names
        end
        local units = fight.encUnits
        if not units then units = {}; fight.encUnits = units end
        local now = GetTime()
        local function Take(unit)
            if not UnitExists(unit) then return end
            local n = UnitName(unit)
            if not (n and names[n]) then return end
            local guid = UnitGUID(unit)
            if not guid then return end
            local e = units[guid]
            if not e then e = {}; units[guid] = e end
            local mx = UnitHealthMax(unit) or 0
            if mx > 0 then e.max = mx end
            e.hp = UnitIsDead(unit) and 0 or (UnitHealth(unit) or 0)
            e.name = n
            e.t = now
        end
        Take("target")
        for i = 1, 40 do Take("raid" .. i .. "target") end
    end

    -- The boss's health as a percent, the encounter's for a multi-boss
    -- fight. Returns pct, complete (false while some boss of a multi-boss
    -- fight has not been seen yet) - nil when nothing is known. Also keeps
    -- fight.hpChangedAt, when the number last moved (the HUD's "paused").
    function RC:GetEncounterHP()
        local fight = self.executeCalculator and self.executeCalculator.currentFight
        if not (fight and fight.started) then return nil end
        local pct, complete
        local cfg = (not self.activeSimulation) and self:TTKMultiBossConfig(fight)
        if cfg then
            local units = fight.encUnits
            if not units then return nil end
            local hp, mx, seen, names = 0, 0, 0, {}
            for _, e in pairs(units) do
                if e.max and e.max > 0 then
                    hp = hp + math_min(e.hp or 0, e.max)
                    mx = mx + e.max
                    if not names[e.name] then names[e.name] = true; seen = seen + 1 end
                end
            end
            if mx <= 0 then return nil end
            pct = hp / mx * 100
            complete = seen >= #cfg.aliases
        else
            local d = self:GetBossHealthData()
            if not (d and d.hpPercent) or (d.maxHP and d.maxHP <= 0) or d.hpPercent ~= d.hpPercent then
                return nil
            end
            pct, complete = d.hpPercent, true
        end
        if fight.lastHPPct ~= pct then
            fight.lastHPPct = pct
            fight.hpChangedAt = GetTime()
        end
        return pct, complete
    end

    -- GetActiveProfileNameForRaid moved to Systems\RaidData\RaidLookup.lua.

    -- The fightHistory key: "<raid>|<profile>_<boss>" when the raid has an
    -- active profile, else the legacy "<raid>_<boss>". Boss names contain
    -- spaces and apostrophes but never "|", which is what keeps it parseable.
    function RC:MakeBossKey(raidName, bossName, profileNameOverride)
        if not raidName or not bossName then return nil end
        local profileName = profileNameOverride
        if not profileName and self.GetRaidProfileStructure then
            local structure = self:GetRaidProfileStructure(raidName)
            if structure and structure.activeProfile then
                profileName = structure.activeProfile
            end
        end
        if profileName and profileName ~= "" then
            return raidName .. "|" .. profileName .. "_" .. bossName
        end
        return raidName .. "_" .. bossName
    end

    -- Multi-boss encounters get recorded under whichever alias the player
    -- targeted; fold those buckets into the canonical key (both legacy and
    -- profile-scoped shapes) so PredictTTK sees one sample set. Only
    -- aliasesAreEncounter entries qualify - adds must stay separate.
    function RC:MigrateFightHistoryAliases()
        local calc = self.executeCalculator
        if not calc or not calc.fightHistory or not calc.fightHistory.data then return false end
        if not self.encounterAddPhases then return false end

        local data    = calc.fightHistory.data
        local maxSize = calc.fightHistory.maxHistorySize or 50
        local touched = false

        for canonName, info in pairs(self.encounterAddPhases) do
            if info.zone and info.aliases and #info.aliases > 0 and info.aliasesAreEncounter then
                local aliasLower = {}
                for _, alias in ipairs(info.aliases) do
                    aliasLower[alias:lower()] = alias
                end

                local zoneLower = info.zone:lower()

                local toMerge = {}
                for key in pairs(data) do
                    local keyLower = type(key) == "string" and key:lower() or nil
                    if keyLower then
                        for aliasLow, canonAlias in pairs(aliasLower) do
                            local suffix = "_" .. aliasLow
                            if #keyLower > #suffix and keyLower:sub(-#suffix) == suffix then
                                local prefixLower = keyLower:sub(1, #keyLower - #suffix)
                                local isLegacy        = (prefixLower == zoneLower)
                                local isProfileScoped = (prefixLower:sub(1, #zoneLower + 1) == zoneLower .. "|")
                                if isLegacy or isProfileScoped then
                                    local origPrefix = key:sub(1, #key - #suffix)
                                    toMerge[#toMerge + 1] = {
                                        aliasKey = key,
                                        canonKey = origPrefix .. "_" .. canonName,
                                        alias    = canonAlias,
                                    }
                                end
                                break
                            end
                        end
                    end
                end

                if #toMerge > 0 then touched = true end

                for _, m in ipairs(toMerge) do
                    local oldFights = data[m.aliasKey]
                    if oldFights and #oldFights > 0 then
                        if not data[m.canonKey] then data[m.canonKey] = {} end
                        for _, fight in ipairs(oldFights) do
                            fight.mergedFromAlias = fight.mergedFromAlias or m.alias
                            table.insert(data[m.canonKey], fight)
                        end
                        self:DebugPrint("MigrateFightHistoryAliases: Merged " .. #oldFights ..
                            " fight(s) from '" .. m.aliasKey .. "' -> '" .. m.canonKey .. "'", "execute")
                    end
                    data[m.aliasKey] = nil
                end

                local touchedCanon = {}
                for _, m in ipairs(toMerge) do touchedCanon[m.canonKey] = true end
                for canonKey in pairs(touchedCanon) do
                    local bucket = data[canonKey]
                    if bucket then
                        table.sort(bucket, function(a, b)
                            return (a.timestamp or 0) > (b.timestamp or 0)
                        end)
                        while #bucket > maxSize do
                            table.remove(bucket)
                        end
                    end
                end
            end
        end

        return touched
    end

    -- Kills typed in on a phased boss's page (C'Thun) used to be filed
    -- under the phase ("...C'Thun_phase1") where no prediction reads them;
    -- fold them onto the boss itself.
    function RC:MigrateFightHistoryPhaseKeys()
        local calc = self.executeCalculator
        local data = calc and calc.fightHistory and calc.fightHistory.data
        if not data or not self.encounterAddPhases then return false end
        local moves = {}
        for key in pairs(data) do
            if type(key) == "string" then
                local stripped, n = key:gsub("_phase%d+$", "")
                if n > 0 then
                    for name, info in pairs(self.encounterAddPhases) do
                        if info.phases and stripped:sub(-(#name + 1)) == "_" .. name then
                            moves[#moves + 1] = { from = key, to = stripped }
                            break
                        end
                    end
                end
            end
        end
        for _, m in ipairs(moves) do
            local src = data[m.from]
            data[m.from] = nil
            if type(src) == "table" then
                local dst = data[m.to]
                if type(dst) ~= "table" then dst = {}; data[m.to] = dst end
                for _, f in ipairs(src) do
                    if type(f) == "table" then
                        if f.encounterName then f.encounterName = f.encounterName:gsub("_phase%d+$", "") end
                        dst[#dst + 1] = f
                    end
                end
                table.sort(dst, function(a, b) return (a.timestamp or 0) > (b.timestamp or 0) end)
            end
        end
        return #moves > 0
    end

    function RC:PruneUnrecognizedFightKeys()
        local calc = self.executeCalculator
        if not calc or not calc.fightHistory or not calc.fightHistory.data then return 0 end
        local data = calc.fightHistory.data

        local doomed = {}
        for bossKey in pairs(data) do
            local raidName, bossName
            if type(bossKey) == "string" then
                if bossKey:find("|", 1, true) then
                    local rest
                    raidName, rest = bossKey:match("^([^|]+)|(.+)$")
                    if rest then
                        bossName = rest:match("^.-_(.+)$")
                    end
                else
                    raidName, bossName = bossKey:match("^(.-)_(.+)$")
                end
            end
            if not (raidName and bossName) then
                doomed[#doomed + 1] = bossKey
            end
        end

        for _, bossKey in ipairs(doomed) do
            local n = type(data[bossKey]) == "table" and #data[bossKey] or 0
            data[bossKey] = nil
            self:DebugPrint(string.format(
                RCL["PruneUnrecognizedFightKeys: deleted key '%s' (%d fight(s))"],
                tostring(bossKey), n), "execute")
        end

        return #doomed
    end

    function RC:GetFightHistoryForBoss(raidName, bossName)
        local calc = self.executeCalculator
        if not calc or not calc.fightHistory or not calc.fightHistory.data then return nil, nil end
        if not raidName or not bossName then return nil, nil end
        bossName = self:TTKBossName(raidName, bossName)
        local newKey = self:MakeBossKey(raidName, bossName)
        if newKey and calc.fightHistory.data[newKey] then
            return calc.fightHistory.data[newKey], newKey
        end
        local legacyKey = raidName .. "_" .. bossName
        if calc.fightHistory.data[legacyKey] then
            return calc.fightHistory.data[legacyKey], legacyKey
        end
        return nil, newKey
    end

    -- RELATED RAID CONFIGS SHARE KILL TIMES (mlConfig.shareRelated, on
    -- unless switched off). Configs whose names start with the same two
    -- words are one family - "Crit Crush DPS", "Crit Crush Spider Tank"
    -- and "Crit Crush" - and a prediction for any of them reads every
    -- kill the family has on that boss, newest first, whichever one is
    -- selected. A one-word name is a family of its own. Kills stay filed
    -- under the config they were recorded on. Cached for a second: the
    -- TTK display asks several times a second.
    function RC:TTKConfigFamily(profileName)
        if type(profileName) ~= "string" or profileName == "" then return nil end
        local w1, w2 = profileName:match("^%s*(%S+)%s+(%S+)")
        if w1 then return (w1 .. " " .. w2):lower() end
        return profileName:lower():match("^%s*(.-)%s*$")
    end

    -- Every kill a prediction reads for this boss, newest first: the
    -- config's own, its family's (when shared), and the pre-profile
    -- "Raid_Boss" kills while the config has none of its own. A kill
    -- copied into several configs counts once (same time and length, the
    -- test the Move / Copy dialog uses). profileName pins a config (the
    -- fight's own); nil means the raid's active one. The returned list is
    -- shared and cached until the history changes - read it, never edit it.
    local function KillMark(f)
        return tostring(f.timestamp or "X") .. "|" .. tostring(math_floor((f.totalFightTime or 0) + 0.5))
    end
    RC.TTKKillMark = KillMark
    local linkedCache = {}
    function RC:GetLinkedFightHistoryForBoss(raidName, bossName, profileName)
        local calc = self.executeCalculator
        local data = calc and calc.fightHistory and calc.fightHistory.data
        if not (data and raidName and bossName) then return nil, nil, 0 end
        bossName = self:TTKBossName(raidName, bossName)
        if not profileName and self.GetActiveProfileNameForRaid then
            profileName = self:GetActiveProfileNameForRaid(raidName)
        end
        local ownKey = self:MakeBossKey(raidName, bossName, profileName)
        local legacyKey = raidName .. "_" .. bossName
        local ml = calc.mlConfig
        local family = (not (ml and ml.shareRelated == false)) and profileName and self:TTKConfigFamily(profileName) or nil

        local ck = raidName .. "\1" .. bossName .. "\1" .. tostring(profileName) .. "\1" .. tostring(family)
        local c = linkedCache[ck]
        local now = GetTime()
        if c and c.ver == _ttk.histVersion and c.data == data and (now - c.at) < 30 then
            return c.list, ownKey, c.linked
        end

        local merged, seen, order, linked = {}, {}, {}, 0
        local function Add(list)
            for _, f in ipairs(list) do
                if type(f) == "table" then
                    local m = KillMark(f)
                    if not seen[m] then
                        seen[m] = true
                        merged[#merged + 1] = f
                        order[f] = #merged
                    end
                end
            end
        end
        local own = data[ownKey]
        if type(own) == "table" then Add(own) end
        if family then
            local prefix, suffix = raidName .. "|", "_" .. bossName
            for key, list in pairs(data) do
                if key ~= ownKey and type(key) == "string" and type(list) == "table"
                    and #key > #prefix + #suffix
                    and key:sub(1, #prefix) == prefix and key:sub(-#suffix) == suffix then
                    local prof = key:sub(#prefix + 1, #key - #suffix)
                    if self:TTKConfigFamily(prof) == family then
                        Add(list)
                        if #list > 0 then linked = linked + 1 end
                    end
                end
            end
        end
        if type(own) ~= "table" and ownKey ~= legacyKey and type(data[legacyKey]) == "table" then
            Add(data[legacyKey])
        end
        -- newest first by when the kill happened, not by where it sits in
        -- its bucket (an edit or a paste can leave a bucket out of order)
        table.sort(merged, function(a, b)
            local ta, tb = a.timestamp or 0, b.timestamp or 0
            if ta ~= tb then return ta > tb end
            return order[a] < order[b]
        end)
        linkedCache[ck] = { at = now, ver = _ttk.histVersion, data = data, list = merged, linked = linked }
        return merged, ownKey, linked
    end

    -- The usual kill time for this boss, from history. Returns
    -- (totalSeconds, confidence 0..1, killsUsed), or nil, 0, 0 when there
    -- are too few kills. profileName pins the config (nil = the raid's
    -- active one). Cached until the history or a setting changes.
    --   * kills that cannot be timed (never engaged, no length) are dropped
    --     before anything else, so they never count toward a minimum
    --   * matchClass and the Darkmoon (Sayge) match only narrow the kills
    --     once the narrower set still has enough of its own - the larger of
    --     minSamplesForPrediction and the smoothing minimum
    --   * the newest maxSamplesForPrediction kills, outliers removed, then
    --     recency-weighted (EWMA) or the plain median under that minimum
    local predictCache = {}
    function RC:PredictTTK(raidName, encounterName, hasSayge, profileName)
        if not raidName or not encounterName then
            return nil, 0, 0
        end
        local calc = self.executeCalculator
        local ml, ew = calc.mlConfig, calc.ewma
        -- the config is part of the answer: resolve the active one now, so
        -- switching config is never answered from the old one's cache
        if not profileName and self.GetActiveProfileNameForRaid then
            profileName = self:GetActiveProfileNameForRaid(raidName)
        end
        local mine = (ml.matchClass and self.PlayerClassToken) and self:PlayerClassToken() or nil
        local ck = raidName .. "\1" .. encounterName .. "\1" .. tostring(hasSayge) .. "\1" .. tostring(profileName)
            .. "\1" .. tostring(mine)
        local data = calc.fightHistory and calc.fightHistory.data
        local c = predictCache[ck]
        -- (30s at most, for the one writer that does not announce itself:
        -- kills merged in from the mesh)
        local now = GetTime()
        if c and c.ver == _ttk.histVersion and c.ml == ml and c.ew == ew and c.data == data
           and (now - c.at) < 30 then
            return c.p, c.conf, c.n
        end

        local function Done(p, conf, n)
            predictCache[ck] = { ver = _ttk.histVersion, at = now, ml = ml, ew = ew, data = data, p = p, conf = conf, n = n }
            return p, conf, n
        end

        local all = self:GetLinkedFightHistoryForBoss(raidName, encounterName, profileName)
        if not all then return Done(nil, 0, 0) end

        local fights = {}
        for _, f in ipairs(all) do
            if not f.isNeverEngaged and f.totalFightTime and f.totalFightTime > 0 then
                fights[#fights + 1] = f
            end
        end

        local minSamples = ml.minSamplesForPrediction or 2
        local need = math_max(minSamples, (ew and ew.enabled and ew.minSamples) or minSamples)
        if #fights < minSamples then return Done(nil, 0, 0) end

        -- mlConfig.matchClass: prefer kills played on this character's
        -- class. Kills with no class recorded never count as a match.
        if mine and self.FightClass then
            local same = {}
            for _, f in ipairs(fights) do
                if self:FightClass(f) == mine then same[#same + 1] = f end
            end
            if #same >= need then fights = same end
        end

        -- hasSayge nil means do not filter. When given, prefer kills with a
        -- matching Darkmoon Faire buff state.
        if hasSayge ~= nil then
            local match = {}
            for _, f in ipairs(fights) do
                if (f.hasSayge == true) == (hasSayge == true) then match[#match + 1] = f end
            end
            if #match >= need then fights = match end
        end

        local maxSamples = ml.maxSamplesForPrediction or 20
        local recent = {}
        for i = 1, math_min(maxSamples, #fights) do
            recent[#recent + 1] = fights[i].totalFightTime
        end

        local cleaned = self:RemoveOutliers(recent)
        if #cleaned < minSamples then return Done(nil, 0, 0) end

        local prediction
        if ew and ew.enabled and #cleaned >= (ew.minSamples or 3) then
            prediction = self:CalculateEWMA(cleaned)
        else
            prediction = self:TTKMedian(cleaned)
        end

        -- Confidence blends 70% sample coverage (survivors / maxSamples)
        -- with 30% consistency (1 - coefficient of variation, floored at
        -- 0), so an erratic boss stays low even with a full 20 samples.
        local confidence = math_min(#cleaned / maxSamples, 1.0)
        local variance = self:CalculateVariance(cleaned, prediction)
        local cv = math_sqrt(variance) / prediction
        confidence = (confidence * 0.7) + (math_max(0, 1 - cv) * 0.3)

        return Done(prediction, confidence, #cleaned)
    end

    -- the middle value; the mean of the two middle ones for an even count
    function RC:TTKMedian(data)
        local n = #data
        if n == 0 then return nil end
        local t = {}
        for i = 1, n do t[i] = data[i] end
        table_sort(t)
        if n % 2 == 1 then return t[(n + 1) / 2] end
        return (t[n / 2] + t[n / 2 + 1]) / 2
    end

    -- Drops kills far from the median: further than outlierThreshold x 1.5
    -- robust deviations (1.4826 x the median absolute deviation), with the
    -- deviation never taken as under 5% of the median. A mean and standard
    -- deviation cannot do this on a handful of kills - one wipe-length
    -- "kill" drags both toward itself and hides. Needs 3 kills; never
    -- removes half or more; keeps the input order (newest first).
    function RC:RemoveOutliers(data)
        if #data < 3 then return data end
        local med = self:TTKMedian(data)
        local dev = {}
        for i, v in ipairs(data) do dev[i] = math_abs(v - med) end
        local mad = self:TTKMedian(dev)
        local sigma = math_max(1.4826 * mad, 0.05 * med)
        if sigma <= 0 then return data end
        local k = (self.executeCalculator.mlConfig.outlierThreshold or 2.0) * 1.5
        local cleaned = {}
        for i, v in ipairs(data) do
            if dev[i] <= k * sigma then cleaned[#cleaned + 1] = v end
        end
        if #cleaned * 2 <= #data then return data end
        return cleaned
    end

    -- Only engages once a bucket exceeds maxHistorySize: outliers evicted
    -- first, then the oldest. mean/stdDev come from engaged fights only but
    -- every fight is scored, so inflated isNeverEngaged samples go first.
    function RC:TrimFightHistory(bossKey)
        local fights = self.executeCalculator.fightHistory.data[bossKey]
        if not fights then return end

        local maxSize = self.executeCalculator.fightHistory.maxHistorySize
        if #fights <= maxSize then return end

        local threshold = self.executeCalculator.mlConfig.outlierThreshold or 2.0
        local times = {}
        for _, fight in ipairs(fights) do
            if fight.totalFightTime and not fight.isNeverEngaged then
                table.insert(times, fight.totalFightTime)
            end
        end

        if #times >= 3 then
            local sum = 0
            for _, v in ipairs(times) do sum = sum + v end
            local mean = sum / #times

            local variance = 0
            for _, v in ipairs(times) do
                variance = variance + math.pow(v - mean, 2)
            end
            variance = variance / #times
            local stdDev = math.sqrt(variance)

            if stdDev > 0 then
                for i = #fights, 1, -1 do
                    if #fights <= maxSize then break end

                    local fight = fights[i]
                    if fight.totalFightTime then
                        local zScore = math.abs((fight.totalFightTime - mean) / stdDev)
                        if zScore > threshold then
                            table.remove(fights, i)
                            self:DebugPrint(string.format(RCL["Trimmed outlier fight: %.1fs (z=%.2f)"], fight.totalFightTime, zScore), "ttk")
                        end
                    end
                end
            end
        end

        while #fights > maxSize do
            table.remove(fights)
        end
    end

    function RC:CalculateVariance(data, mean)
        local sum = 0
        for _, v in ipairs(data) do
            sum = sum + math.pow(v - mean, 2)
        end
        return sum / #data
    end

    -- data arrives newest-first, so seed with the oldest and fold forward:
    -- the newest kill is applied last and carries weight alpha. A sorted
    -- array here would silently become value-weighted, not recency-weighted.
    function RC:CalculateEWMA(data)
        local alpha = self.executeCalculator.ewma.alpha
        local ewma = data[#data]

        for i = #data - 1, 1, -1 do
            ewma = (alpha * data[i]) + ((1 - alpha) * ewma)
        end

        return ewma
    end

    -- The fight's usual kill time from history: read once per fight, so
    -- the HUD's Expected and the pace stay put while the boss dies. Read
    -- again only if the Darkmoon buff state changes (Sayge is often
    -- released after the pull). Returns total, confidence, kills used.
    function RC:GetFightExpectedTTK(fight)
        fight = fight or (self.executeCalculator and self.executeCalculator.currentFight)
        if not (fight and fight.started and fight.raidName and fight.encounterName) then return nil, 0, 0 end
        local key = fight.hasSayge and "S" or "N"
        if fight._expKey ~= key then
            fight._expKey = key
            fight._expTotal, fight._expConf, fight._expN = self:PredictTTK(fight.raidName,
                fight.historyName or fight.encounterName, fight.hasSayge, fight.profileName)
        end
        return fight._expTotal, fight._expConf or 0, fight._expN or 0
    end

    -- THE time left on the boss, in seconds. Every TTK reader goes through
    -- here: ability reminders, the HUD, custom reminders.
    -- Returns remaining, total, confidence, source, liveTotal - or nil
    -- before the boss is engaged or when nothing can be estimated yet.
    --   source "history"       the usual kill time, counted down
    --          "history+pace"  the usual kill time pulled toward this
    --                          pull's own speed - more so the further down
    --                          the boss is (at half health, half and half)
    --          "pace"          this pull's speed only (no trusted history,
    --                          or Classic mode)
    -- liveTotal is the pure live estimate, for pace comparisons.
    -- Multi-boss fights wait for every boss's health before any live
    -- number, so one horseman dying never reads as the end of the fight.
    -- Cached a quarter of a second.
    function RC:GetTTKRemaining()
        local calc = self.executeCalculator
        local fight = calc and calc.currentFight
        if not (fight and fight.started and fight.bossEngaged and fight.bossEngageTime and fight.bossEngageTime > 0) then
            return nil
        end
        local now = GetTime()
        local c = fight._ttkc
        if c and (now - c.at) < 0.25 then
            return c.rem, c.total, c.conf, c.src, c.live
        end

        local elapsed = now - fight.bossEngageTime
        local hp, complete = self:GetEncounterHP()
        local live, liveConf = self:GetClassicTTKPrediction(fight.raidName, fight.encounterName)
        if hp and not complete then live = nil end

        local total, conf, src
        local exp, expConf = nil, 0
        if (calc.mode or "intelligent") ~= "classic" then
            exp, expConf = self:GetFightExpectedTTK(fight)
        end
        local thr = (calc.mlConfig and calc.mlConfig.confidenceThreshold) or 0.25
        if exp and expConf >= thr then
            total, conf, src = exp, expConf, "history"
            -- (not in /rc sim: its mock boss loses health in a straight
            -- line, with no faster execute, so the sim plays out the
            -- prediction as it stands)
            if live and hp and not self.activeSimulation then
                local p = math_max(0, math_min(1, (100 - hp) / 100))
                if p >= 0.1 then
                    total = exp * (1 - p) + live * p
                    src = "history+pace"
                end
            end
        elseif live then
            total, conf, src = live, liveConf, "pace"
        end

        local rem
        if total then
            rem = total - elapsed
            if rem <= 0 then
                -- past the usual time with the boss still up: this pull's
                -- own speed is the better guess; without it, the usual time
                -- scaled by the health it has left
                if live and (live - elapsed) > 0 then
                    rem = live - elapsed
                elseif hp and hp > 0 and src ~= "pace" then
                    rem = math_max(1, total * hp / 100)
                else
                    rem = 0
                end
            end
        end

        if not c then c = {}; fight._ttkc = c end
        c.at, c.rem, c.total, c.conf, c.src, c.live = now, rem, total, conf, src, live
        return rem, total, conf, src, live
    end

    -- Kept for older callers: seconds remaining and confidence, from the
    -- one shared estimate above.
    function RC:GetCurrentTTKPrediction()
        local rem, _, conf = self:GetTTKRemaining()
        if not rem then return nil, 0 end
        return rem, conf or 0
    end

    -- Live extrapolation, no history needed. Two tiers in order:
    -- execute-phase pace, then whole-fight pace. Both hinge on
    -- timePerPercent (seconds per 1% of boss max HP); values outside
    -- 0.1-30 s/% are noise and reject the tier, totals clamp to 30-600s,
    -- and confidence is a flat 0.3 rather than derived. Nothing at all
    -- until 2% of the boss is gone and 3s have passed: a guessed fight
    -- length would fire trinket reminders on the pull.
    -- Health is the encounter's (GetEncounterHP), so a multi-boss fight
    -- reads every boss summed - and nothing until all have been seen.
    function RC:GetClassicTTKPrediction(raidName, encounterName)
        local fight = self.executeCalculator.currentFight

        if not fight.started or not fight.bossEngaged then
            return nil, 0
        end

        local hpPct, complete = self:GetEncounterHP()
        if not hpPct or not complete then
            return nil, 0
        end
        local bossData = { hpPercent = hpPct }

        local multiplier = self:GetClassicMultiplier(raidName, encounterName)

        -- Tier 1: needs 0.5% burned since execute entry to divide by.
        if fight.enterExecuteTime > 0 then
            local executeElapsed = GetTime() - fight.enterExecuteTime
            local hpBurned = fight.executeStartHP - bossData.hpPercent

            if hpBurned >= 0.5 then
                local timePerPercent = executeElapsed / hpBurned
                if timePerPercent >= 0.1 and timePerPercent <= 30 then
                    local remainingHP = bossData.hpPercent
                    local estimatedRemainingExecute = timePerPercent * remainingHP

                    local totalElapsed = GetTime() - fight.bossEngageTime
                    local totalEstimate = totalElapsed + estimatedRemainingExecute

                    totalEstimate = math.min(600, math.max(30, totalEstimate))

                    return totalEstimate, 0.3
                end
            end
        end

        -- Tier 2: extrapolate a flat 100% at the observed pace, then rebate
        -- the execute segment, which runs `multiplier` times faster.
        local elapsed = GetTime() - fight.bossEngageTime
        local hpBurned = 100 - bossData.hpPercent

        if hpBurned > 2 and elapsed >= 3 then
            local timePerPercent = elapsed / hpBurned

            if timePerPercent < 0.1 or timePerPercent > 30 then
            else
                local totalEstimate = timePerPercent * 100

                totalEstimate = math.min(600, math.max(30, totalEstimate))

                local executePercent = self.executeCalculator.executeThreshold
                local normalPercent = 100 - executePercent

                local normalTime = (normalPercent / 100) * totalEstimate
                local executeTime = (executePercent / 100) * totalEstimate / multiplier

                return normalTime + executeTime, 0.3
            end
        end

        return nil, 0
    end

    -- Tries "<raid>_<boss>" then "<raid>|<boss>". SetClassicMultiplier
    -- gsubs "|" away and only ever writes the underscore form, so the
    -- second lookup can only hit keys imported from older saved data.
    function RC:GetClassicMultiplier(raidName, bossName)
        if not raidName or not bossName then
            return self.executeCalculator.classicMultipliers.global
        end

        local bossKey = raidName .. "_" .. bossName
        local multiplier = self.executeCalculator.classicMultipliers.perBoss[bossKey]

        if not multiplier then
            bossKey = raidName .. "|" .. bossName
            multiplier = self.executeCalculator.classicMultipliers.perBoss[bossKey]
        end

        return multiplier or self.executeCalculator.classicMultipliers.global
    end

    function RC:SetClassicMultiplier(raidName, bossName, multiplier)
        if not raidName or not bossName then
            self.executeCalculator.classicMultipliers.global = multiplier
            self:SaveExecuteSettings()
            return
        end

        local bossKey = raidName .. "_" .. bossName
        bossKey = bossKey:gsub("|", "_")

        self.executeCalculator.classicMultipliers.perBoss[bossKey] = multiplier
        self:SaveExecuteSettings()

        self:DebugPrint(string.format(RCL["Set %s multiplier to %.2fx"], bossName, multiplier), "execute")
    end

    function RC:ClearBossClassicMultiplier(raidName, bossName)
        if not raidName or not bossName then return end

        local bossKey = raidName .. "_" .. bossName
        bossKey = bossKey:gsub("|", "_")

        self.executeCalculator.classicMultipliers.perBoss[bossKey] = nil
        self:SaveExecuteSettings()
    end

    function RC:StartFightTracking(targetData, raidName, encounterName)
        local calc = self.executeCalculator
        local now = GetTime()

        -- Post-ENCOUNTER_END gate. Once any ENCOUNTER_START has been seen
        -- this session, refuse to open a fight with no encounter active, or
        -- corpses and stray adds spawn phantom fights. Test mode bypasses.
        if not (calc.testMode and calc.testMode.enabled) then
            local hadEncounter = self._seenAnyEncounterStart
            local activeEnc    = RC.activeEncounterName
            if hadEncounter and not activeEnc then
                self:DebugPrint("StartFightTracking gated: no active encounter (post-END stale, target='" .. tostring(targetData and targetData.name) .. "')", "execute")
                return
            end
        end

        if calc.staleCleanupTimer then
            calc.staleCleanupTimer:Cancel()
            calc.staleCleanupTimer = nil
        end

        local encounterConfig = self.encounterAddPhases and self.encounterAddPhases[encounterName]
        local addPhasesBeforeBoss = encounterConfig and encounterConfig.addPhasesBeforeBoss or false
        local isMultiCombat = encounterConfig and encounterConfig.combatContinuous or false

        calc.currentFight = {
            started = true,
            startTime = now,
            encounterStartTime = now,
            targetGUID = targetData.guid,
            targetName = targetData.name,
            encounterName = encounterName,
            raidName = raidName or "Unknown",
            -- The name the kill is filed under and the raid config the
            -- fight was started on, fixed for the whole fight: switching
            -- config mid-pull must not split the prediction from the kill.
            historyName = self:TTKBossName(raidName or "Unknown", encounterName),
            profileName = self.GetActiveProfileNameForRaid and self:GetActiveProfileNameForRaid(raidName or "Unknown") or nil,

            -- These encounters stay untimed until the boss takes damage.
            bossEngaged = not addPhasesBeforeBoss,
            bossEngageTime = addPhasesBeforeBoss and 0 or now,
            addPhasesBeforeBoss = addPhasesBeforeBoss,

            enterExecuteTime = 0,
            executeStartHP = 0,

            maxHP = targetData.maxHP or UnitHealthMax("target") or 1,
            isMultiCombatEncounter = isMultiCombat,
            isBossFight = true,
            isTestFight = calc.testMode.enabled,
            hasSayge = self:HasSaygeBuff(),

            primaryBoss = {
                name = encounterName,
                guid = addPhasesBeforeBoss and nil or targetData.guid,
                isActive = not addPhasesBeforeBoss,
                lastHP = 0,
                lastMaxHP = 0,
                lastUpdate = 0
            }
        }

        self:DebugPrint("=== FIGHT START ===", "execute")
        self:DebugPrint(string.format(RCL["Boss: %s"], encounterName or RCL["Unknown"]), "execute")
        self:DebugPrint(string.format(RCL["Raid: %s"], raidName or RCL["Unknown"]), "execute")

        -- Sayge's boon is often released after the pull, so re-stamp at +10s
        -- and +30s; the captured fight table stops an old timer hitting a
        -- later pull.
        local thisFight = calc.currentFight
        local function RecheckSayge()
            if calc.currentFight ~= thisFight or not thisFight.started then return end
            if not thisFight.hasSayge and self:HasSaygeBuff() then
                thisFight.hasSayge = true
                self:DebugPrint("Sayge buff detected after pull (boon release) - fight re-stamped DMF", "execute")
            end
        end
        C_Timer.After(10, RecheckSayge)
        C_Timer.After(30, RecheckSayge)

        if self.PauseTrinketSwapForBoss then
            self:PauseTrinketSwapForBoss()
        end

        if addPhasesBeforeBoss then
            self:DebugPrint(" Pre-Boss Add Phase - Waiting for boss", "execute")
        else
            self:DebugPrint(" Boss Engaged - Timer Started", "execute")
        end
    end

    -- Restamps the TTK clock at real engage and clears add-phase execute
    -- state, so add damage never counts toward fight time. Must stay
    -- idempotent: four detectors can reach here in the same second.
    function RC:EngageBoss()
        local fight = self.executeCalculator.currentFight

        if not fight.started or fight.bossEngaged then
            return
        end

        fight.bossEngaged = true
        fight.bossEngageTime = GetTime()
        fight.primaryBoss.isActive = true

        local bossGUID = nil

        if UnitExists("target") then
            local targetName = UnitName("target")
            if targetName == fight.encounterName or targetName == fight.primaryBoss.name then
                bossGUID = UnitGUID("target")
            end
        end

        if not bossGUID then
            for i = 1, 40 do
                local unit = "raid" .. i .. "target"
                if UnitExists(unit) then
                    local name = UnitName(unit)
                    if name == fight.encounterName or name == fight.primaryBoss.name then
                        bossGUID = UnitGUID(unit)
                        break
                    end
                end
            end
        end

        fight.primaryBoss.guid = bossGUID

        if not fight.hasSayge and self:HasSaygeBuff() then
            fight.hasSayge = true
            self:DebugPrint("Sayge buff detected at boss engage - fight re-stamped DMF", "execute")
        end

        fight.enterExecuteTime = 0
        fight.executeStartHP = 0
        fight.primaryBoss.lastHP = 0
        fight.primaryBoss.lastMaxHP = 0
        fight.primaryBoss.lastUpdate = 0

        self:DebugPrint(">>> BOSS ENGAGED - TRACKING RESET <<<", "execute")
        self:DebugPrint(string.format(RCL["Boss: %s"], fight.primaryBoss.name), "execute")
        self:DebugPrint(" TTK calculations starting fresh (add damage excluded)", "execute")
    end

