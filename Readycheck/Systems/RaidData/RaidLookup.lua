------------------------------------------------------------------------
-- Readycheck - Raid Name Lookup
-- Resolves a mob name to its encounter, its parent boss, or its raw
-- config entry against the active raid profile. Lookup order per
-- function is documented above each one.
--
-- Lifted out of TE_Triggers.lua and TTK_Model.lua when the reminder
-- stack moved to Readycheck_Reminders: the gear side (TE_GearSwap,
-- TE_ForceEquip, Readycheck_Gear's TrinketSwap) calls these on every
-- boss death and target change, so they cannot live in an addon the
-- user is allowed to switch off.
--
-- Results memoise into RC._encResolveCache, which TE_Events wipes on
-- target change. Negative results are stored as false, never nil -
-- nil in the cache means "not looked up yet", so a miss stored as nil
-- would make every trash mob rescan forever.
------------------------------------------------------------------------
local pairs, ipairs, type = pairs, ipairs, type
local string_format = string.format
local GetRealZoneText, GetSubZoneText = GetRealZoneText, GetSubZoneText
local GetInstanceInfo, UnitName = GetInstanceInfo, UnitName
local RC = _G.Readycheck
if not RC then return end

    -- What counts as "set up" for one boss or trash entry. Wider than
    -- cfg.enabled, which only follows the reminder toggles (the reminder
    -- triggers and the trinket pause read it, so its meaning stays): a
    -- boss whose only setup is a gear set, a slot item, a death trinket
    -- config, the set picker or Fungal Bloom is still set up. The menus
    -- use this for their markers and counts; the lookup below uses it so
    -- an entry that only exists because its page was opened never wins.
    local function HasSet(v) return type(v) == "string" and v ~= "" end
    local function HasItems(t)
        if type(t) ~= "table" then return false end
        for _, v in pairs(t) do
            if v and v ~= 0 then return true end
        end
        return false
    end
    local function HasId(v) return v ~= nil and v ~= false and v ~= 0 end

    -- The gear swap page alone: full sets (what the swap reads, not
    -- gearswap.enabled), per-slot items incl. the old trinket-only keys,
    -- the death trinket config and the set picker.
    function RC:EncounterHasGearConfig(cfg)
        if type(cfg) ~= "table" then return false end
        local gs = type(cfg.abilities) == "table" and cfg.abilities.gearswap
        if type(gs) == "table" and (HasSet(gs.gearSet) or HasSet(gs.postCombatSet)
            or (gs.gearSet == nil and HasSet(gs.itemRackSet))) then
            return true
        end
        local fe = cfg.forceEquip
        if type(fe) == "table" then
            if HasItems(fe.onTarget) or HasItems(fe.onDeath) then return true end
            if HasId(fe.slot1) or HasId(fe.slot2) or HasId(fe.deathSlot1) or HasId(fe.deathSlot2) then
                return true
            end
            if HasSet(fe.deathConfig) then return true end
            if type(fe.deathPrompt) == "table" and fe.deathPrompt.enabled then return true end
        end
        return false
    end

    function RC:EncounterHasConfig(cfg)
        if type(cfg) ~= "table" then return false end
        if cfg.enabled then return true end
        if type(cfg.abilities) == "table" then
            for key, a in pairs(cfg.abilities) do
                if key ~= "gearswap" and type(a) == "table" and a.enabled then return true end
            end
        end
        if HasItems(cfg.postDeathConsumables) then return true end
        if type(cfg.fungalBloom) == "table" and cfg.fungalBloom.enabled then return true end
        return self:EncounterHasGearConfig(cfg)
    end

    -- Storage keys that belong to one boss in the menus: the four horsemen
    -- save under their own names, and profiles from before per-phase
    -- configs were retired can still hold "C'Thun_phase1"-style entries.
    local HORSEMEN_KEYS = {
        ["Highlord Mograine"] = true, ["Lady Blaumeux"] = true,
        ["Thane Korth'azz"]   = true, ["Sir Zeliek"]    = true,
    }
    function RC:EncounterMenuName(key)
        if type(key) ~= "string" then return key end
        if HORSEMEN_KEYS[key] then return "Four Horsemen" end
        return key:match("^(.-)_phase%d+$") or key
    end

    -- Name compare used by the lookups: a leading "The" is dropped and
    -- spaces, hyphens and apostrophes are stripped, so config keys,
    -- in-game names and Blizzard encounter names collapse to one string.
    local function norm(s)
        s = string.gsub(s, "^[Tt]he%s+", "")
        return string.lower(string.gsub(s, "[%s%-']+", ""))
    end

    -- Normalised names of every member of a multi-boss encounter in this
    -- raid (encounterAddPhases aliases). Static data, built once per raid.
    local membersByRaid, NO_MEMBERS = {}, {}
    function RC:_MultiBossMembers(raidName)
        if not raidName or not self.encounterAddPhases then return NO_MEMBERS end
        local m = membersByRaid[raidName]
        if m then return m end
        m = {}
        for _, info in pairs(self.encounterAddPhases) do
            if info.zone == raidName and type(info.aliases) == "table" then
                for _, alias in ipairs(info.aliases) do m[norm(alias)] = true end
            end
        end
        membersByRaid[raidName] = m
        return m
    end

    -- The one way to set a boss's full gear set ("gearSet" for the pull,
    -- "postCombatSet" for after the kill), shared by the boss page and the
    -- route page so both leave the same flags: gearswap.enabled is on
    -- exactly while either set is chosen (the boss page's old rule; the
    -- route page used to leave it on after clearing), postCombatSwap
    -- follows the after-kill set.
    function RC:SetBossGearSet(gs, field, value)
        if type(gs) ~= "table" then return end
        value = (type(value) == "string") and value or ""
        gs[field] = value
        if field == "gearSet" then gs.itemRackSet = nil end
        if field == "postCombatSet" then gs.postCombatSwap = (value ~= "") end
        -- (an old entry may still name its pull set only in itemRackSet)
        gs.enabled = HasSet(gs.gearSet) or HasSet(gs.postCombatSet)
            or (gs.gearSet == nil and HasSet(gs.itemRackSet))
    end

    -- cfg.enabled under its existing rule - any ability (gear swap
    -- included) switched on, or an after-death consumable - for editors
    -- other than the boss page, which keeps its own copy of this rule.
    function RC:RecomputeEncounterEnabled(cfg)
        if type(cfg) ~= "table" then return end
        local on = false
        if type(cfg.abilities) == "table" then
            for _, a in pairs(cfg.abilities) do
                if type(a) == "table" and a.enabled then on = true break end
            end
        end
        if not on and type(cfg.postDeathConsumables) == "table"
           and next(cfg.postDeathConsumables) then
            on = true
        end
        cfg.enabled = on
    end

    function RC:GetEncounterNameForBoss(raidName, bossName)
        if not raidName or not bossName then return bossName end
        local c = self._encResolveCache
        if not c then c = {}; self._encResolveCache = c end
        local k = "E\1" .. raidName .. "\1" .. bossName
        local v = c[k]
        if v ~= nil then return v end
        v = self:_ResolveEncounterNameForBoss(raidName, bossName)
        c[k] = v
        return v
    end

    -- Resolution order, first hit wins: exact/normalised boss key, that boss's
    -- own aliases, the add-to-boss map, then the multi-boss alias table.
    -- Result is memoised by GetEncounterNameForBoss; never call this directly.
    function RC:_ResolveEncounterNameForBoss(raidName, bossName)
        if not raidName or not bossName then
            return bossName
        end

        if not self.GetActiveRaidProfile then
            return bossName
        end

        local raidSettings = self:GetActiveRaidProfile(raidName)
        if not raidSettings then
            return bossName
        end

        -- Normalised compare: a leading "The" is dropped and spaces, hyphens and
        -- apostrophes are stripped, so config keys, in-game names and Blizzard
        -- encounter names all collapse to the same string.
        local function nameMatches(name1, name2)
            if not name1 or not name2 then return false end
            return norm(name1) == norm(name2)
        end

        -- Members of a multi-boss encounter (the four horsemen) have their
        -- own entries only for per-member setup. An entry with nothing set
        -- up - made just by opening that member's page - must not win over
        -- the shared encounter, so those fall through to the alias block.
        local members = self:_MultiBossMembers(raidName)

        for configBossName, bossSettings in pairs(raidSettings.bosses or {}) do
            local matches = nameMatches(configBossName, bossName)

            if matches and not (members[norm(configBossName)]
                                and not self:EncounterHasConfig(bossSettings)) then
                return configBossName
            end

            if bossSettings.aliases then
                for _, alias in ipairs(bossSettings.aliases) do
                    if nameMatches(alias, bossName) then
                        return configBossName
                    end
                end
            end
        end

        local parentBoss = self:GetBossFromAdd(raidName, bossName)
        if parentBoss then
            if self:IsDebugEnabled("trigger") then self:DebugPrint(string_format("[ADD DETECTED] '%s' belongs to boss '%s'", bossName, parentBoss), "trigger") end
            return parentBoss
        end

        if self.encounterAddPhases then
            for encounterName, encounterInfo in pairs(self.encounterAddPhases) do
                if encounterInfo.zone == raidName and encounterInfo.aliases then
                    -- Multi-boss encounters (Four Horsemen, Twin Emperors) list
                    -- every member in aliases. A member with its own enabled
                    -- abilities wins; otherwise the shared encounter config does.
                    for _, alias in ipairs(encounterInfo.aliases) do
                        if nameMatches(alias, bossName) then
                            -- Anything set up on the member's own page counts,
                            -- gear included (its page offers a gear swap), not
                            -- only enabled reminders - and a gear swap left
                            -- "on" with no set chosen no longer does.
                            local hasIndividualConfig = raidSettings.bosses
                                and self:EncounterHasConfig(raidSettings.bosses[alias]) or false
                            if hasIndividualConfig then
                                if self:IsDebugEnabled("trigger") then self:DebugPrint(string_format("[ALIAS] '%s' has individual config - using it directly", bossName), "trigger") end
                                return alias
                            end
                            if self:IsDebugEnabled("trigger") then self:DebugPrint(string_format("[ALIAS DETECTED] '%s' is alias for '%s'", bossName, encounterName), "trigger") end
                            return encounterName
                        end
                    end
                end
            end
        end

        return bossName
    end

    function RC:GetDirectBossMatch(raidName, name)
        if not raidName or not name then return nil end
        local resolved = self:GetEncounterNameForBoss(raidName, name)
        if not resolved then return nil end
        local raidSettings = self.GetActiveRaidProfile and self:GetActiveRaidProfile(raidName)
        if raidSettings and raidSettings.bosses and raidSettings.bosses[resolved] then
            return resolved
        end
        return nil
    end

    function RC:GetBossFromAdd(raidName, addName)
        if not raidName or not addName or not self.encounterAddPhases then
            return nil
        end
        local c = self._encResolveCache
        if not c then c = {}; self._encResolveCache = c end
        local k = "A\1" .. raidName .. "\1" .. addName
        local v = c[k]
        if v ~= nil then
            if v == false then return nil end
            return v
        end
        v = self:_ResolveBossFromAdd(raidName, addName)
        -- Negative results are stored as false: nil in the cache means
        -- "not looked up yet", so every trash mob would rescan forever.
        c[k] = (v == nil) and false or v
        return v
    end

    function RC:_ResolveBossFromAdd(raidName, addName)
        if not raidName or not addName or not self.encounterAddPhases then
            return nil
        end

        local function nameMatches(name1, name2)
            if not name1 or not name2 then return false end
            local n1 = string.lower(string.gsub(name1, "[%s%-']+", ""))
            local n2 = string.lower(string.gsub(name2, "[%s%-']+", ""))
            return n1 == n2
        end

        if self:IsDebugEnabled("trigger") then self:DebugPrint(string_format("[GetBossFromAdd] Searching for '%s' in '%s'", addName, raidName), "trigger") end

        for bossName, encounterInfo in pairs(self.encounterAddPhases) do
            if encounterInfo.zone == raidName and encounterInfo.adds then
                for _, add in ipairs(encounterInfo.adds) do
                    if nameMatches(add, addName) then
                        if self:IsDebugEnabled("trigger") then self:DebugPrint(string_format("[GetBossFromAdd] MATCH! '%s' belongs to '%s'", addName, bossName), "trigger") end
                        return bossName
                    end
                end
            end
        end

        if self:IsDebugEnabled("trigger") then self:DebugPrint(string_format("[GetBossFromAdd] No boss found for add '%s'", addName), "trigger") end

        return nil
    end


    -- Lookup order: exact boss key, multi-boss alias to its shared
    -- encounter key, then the trash table.
    -- Returns the raw config table, so callers must check .enabled themselves.
    function RC:GetMobConfig(raidName, mobName)
        if not raidName or not mobName then
            return nil
        end

        local raidSettings = self:GetActiveRaidProfile(raidName)
        if not raidSettings then
            return nil
        end

        if raidSettings.bosses and raidSettings.bosses[mobName]
           and not (self:_MultiBossMembers(raidName)[norm(mobName)]
                    and not self:EncounterHasConfig(raidSettings.bosses[mobName])) then
            return raidSettings.bosses[mobName]
        end

        if self.encounterAddPhases and raidSettings.bosses then
            for encounterName, encounterInfo in pairs(self.encounterAddPhases) do
                if encounterInfo.zone == raidName and encounterInfo.aliases then
                    for _, alias in ipairs(encounterInfo.aliases) do
                        if alias == mobName and raidSettings.bosses[encounterName] then
                            return raidSettings.bosses[encounterName]
                        end
                    end
                end
            end
        end

        if raidSettings.trash and raidSettings.trash[mobName] then
            return raidSettings.trash[mobName]
        end

        return nil
    end
    function RC:GetEffectiveRaidName()
        if self.activeSimulation and self.activeSimulation.raidName then
            return self.activeSimulation.raidName
        end

        -- executeCalculator and activeSimulation are both owned by
        -- Readycheck_Reminders, so neither exists when that addon is off.
        local calc = self.executeCalculator
        if calc and calc.testMode and calc.testMode.enabled then
            return calc.testMode.testRaidName
        end

        -- the configured raids are this game version's (RaidFlavor.lua):
        -- on a version with none listed no zone counts as one (Core_Flavor)
        if self.FeatureOn and not self:FeatureOn("raid_configs") then return nil end

        local zoneName = GetRealZoneText()
        local subZoneName = GetSubZoneText and GetSubZoneText() or nil
        local instanceName = GetInstanceInfo and select(1, GetInstanceInfo()) or nil

        local zoneMap = self.raidZoneMap or {}

        if zoneName and zoneMap[zoneName] then
            return zoneMap[zoneName]
        end

        if instanceName and zoneMap[instanceName] then
            return zoneMap[instanceName]
        end

        if subZoneName and zoneMap[subZoneName] then
            return zoneMap[subZoneName]
        end
        -- another game version's raids also match by instance id, whatever
        -- the zone text (RaidFlavor.lua)
        if self._raidFlavorApplied and GetInstanceInfo then
            local instanceID = select(8, GetInstanceInfo())
            if instanceID then
                for raidName, id in pairs(self.raidInstanceIDs or {}) do
                    if id == instanceID then return raidName end
                end
            end
        end

        local targetName = Readycheck.SafeName("target")
        if targetName and self.encounterAddPhases then
            for encounterName, config in pairs(self.encounterAddPhases) do
                if encounterName == targetName and config.zone then
                    return config.zone
                end
            end
        end

        return nil
    end
    function RC:GetActiveProfileNameForRaid(raidName)
        if not raidName then return nil end
        if not self.GetRaidProfileStructure then return nil end
        local structure = self:GetRaidProfileStructure(raidName)
        if structure and structure.activeProfile and structure.activeProfile ~= "" then
            return structure.activeProfile
        end
        return nil
    end
