------------------------------------------------------------------------
-- Readycheck - Raid Profile Storage
-- CRUD plus base64 export/import for per-raid profile sets (each raid has
-- named profiles of boss/trash ability overrides). Remote editing routes
-- reads/writes to RC._remoteEditData via GetEditableRaidProfileStructure/
-- GetEditableActiveProfile so editing another character's profile never
-- touches this character's own config. Runtime code (reminder engine,
-- encounter detection) must keep using GetActiveRaidProfile, which is
-- always local regardless of remote edit state.
------------------------------------------------------------------------
local function InitializeRaidProfiles()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeRaidProfiles)
        return
    end

    if not RC.db then
        C_Timer.After(0.5, InitializeRaidProfiles)
        return
    end

    if not RC.db.raidProfiles then
        RC.db.raidProfiles = {}
    end

    function RC:GetRaidProfileStructure(raidName)
        if not raidName then return nil end
        if not self.db.raidProfiles[raidName] then
            if self:IsDebugEnabled("config") then
                self:DebugPrint("GetRaidProfileStructure: Creating NEW structure for " .. raidName .. " (none existed)", "config")
            end
            self.db.raidProfiles[raidName] = {
                activeProfile = "Default",
                profiles = {
                    ["Default"] = {
                        enabled = false,
                        bosses = {},
                        trash = {}
                    }
                }
            }
        end
        return self.db.raidProfiles[raidName]
    end

    -- The structure that profile EDITS should act on. While remote editing,
    -- the profiles on screen belong to the other character and live in
    -- RC._remoteEditData - so create/delete/rename/merge must operate there,
    -- not on our own raid profiles. Deliberately separate from
    -- GetRaidProfileStructure: the reminder engine and encounter detection
    -- must keep reading THIS character's config while a remote edit is open.
    function RC:GetEditableRaidProfileStructure(raidName)
        local rem = RC.remoteEditMode
        if rem and RC._remoteEditData and raidName and rem.raidKey == raidName then
            local d = RC._remoteEditData
            d.profiles = d.profiles or {}
            return d, true
        end
        return self:GetRaidProfileStructure(raidName), false
    end

    -- The active profile that raid-config EDITORS must read and write. While
    -- remote editing it is the other character's active profile inside
    -- RC._remoteEditData, so their sliders, checkboxes and dropdowns actually
    -- change their config; otherwise it is ours. Returns profile, name, isRemote.
    -- Runtime code (reminder engine, encounter detection) must keep using
    -- GetActiveRaidProfile, which is always local.
    function RC:GetEditableActiveProfile(raidName)
        local rem = RC.remoteEditMode
        if rem and RC._remoteEditData and raidName and rem.raidKey == raidName then
            local d = RC._remoteEditData
            d.profiles = d.profiles or {}
            local activeName = d.activeProfile or "Default"
            local prof = d.profiles[activeName]
            if not prof then
                activeName, prof = next(d.profiles)
            end
            if prof then
                prof.bosses = prof.bosses or {}
                prof.trash  = prof.trash  or {}
                return prof, activeName, true
            end
        end
        local prof, activeName = self:GetActiveRaidProfile(raidName)
        return prof, activeName, false
    end

    function RC:GetActiveRaidProfile(raidName)
        local structure = self:GetRaidProfileStructure(raidName)
        if not structure then return nil end
        local activeName = structure.activeProfile or "Default"

        if not structure.profiles[activeName] then
            local bestName, bestScore
            for pName, pd in pairs(structure.profiles) do
                local score = 0
                if type(pd) == "table" and type(pd.bosses) == "table" then
                    for _ in pairs(pd.bosses) do score = score + 1 end
                end
                if pd and pd.enabled then score = score + 100 end
                if not bestScore or score > bestScore
                   or (score == bestScore and pName == "Default") then
                    bestName, bestScore = pName, score
                end
            end
            if bestName then
                self:Print(RCL["Raid profile '"] .. tostring(activeName) .. RCL["' no longer exists for "]
                    .. raidName .. RCL[" - switched to '"] .. bestName .. "'.")
                activeName = bestName
                structure.activeProfile = bestName
            else
                activeName = "Default"
                structure.activeProfile = "Default"
                structure.profiles["Default"] = {
                    enabled = true,
                    bosses = {},
                    trash = {}
                }
                self:DebugPrint("GetActiveRaidProfile: Created NEW Default profile for " .. raidName, "config")
            end
        end

        local profile = structure.profiles[activeName]

        if self:IsDebugEnabled("config") and profile.bosses then
            local bossCount = 0
            for bossName, bossConfig in pairs(profile.bosses) do
                bossCount = bossCount + 1
                if bossConfig.abilities then
                    for abilityKey, abilityConfig in pairs(bossConfig.abilities) do
                        if type(abilityKey) == "string" and abilityKey:lower():find("potion") then
                            self:DebugPrint(string.format(RCL["GetActiveRaidProfile: %s/%s/%s | enabled=%s | triggerType=%s | potionType=%s"],
                                raidName, bossName, abilityKey,
                                tostring(abilityConfig.enabled),
                                tostring(abilityConfig.triggerType),
                                tostring(abilityConfig.potionType)), "config")
                        end
                    end
                end
            end
            self:DebugPrint(string.format(RCL["GetActiveRaidProfile: %s has %d bosses configured"], raidName, bossCount), "config")
        end

        return profile, activeName
    end

    function RC:StampRaidProfileContributor(raidName)
        if not raidName then return end
        local profile = self:GetActiveRaidProfile(raidName)
        if type(profile) ~= "table" then return end

        local _, raceToken = UnitRace("player")
        local _, classToken = UnitClass("player")

        if raceToken then
            if type(profile.contributorRaces) ~= "table" then
                profile.contributorRaces = {}
            end
            profile.contributorRaces[raceToken] = true
        end
        if classToken then
            if type(profile.contributorClasses) ~= "table" then
                profile.contributorClasses = {}
            end
            profile.contributorClasses[classToken] = true
        end
    end

    -- Which races' racial abilities this profile's UI may suggest: your own
    -- race, plus any race that has contributed to the profile
    -- (contributorRaces, stamped by StampRaidProfileContributor) or whose
    -- racial ability (Blood Fury/Berserking) is already enabled in it.
    function RC:GetRaidConfigRacialRaces(raidName, profileOverride, includeLocalRace)
        local allowed = {}

        if includeLocalRace ~= false then
            local _, raceToken = UnitRace("player")
            if raceToken then allowed[raceToken] = true end
        end

        local profile = profileOverride
        if type(profile) ~= "table" and raidName then
            profile = self:GetActiveRaidProfile(raidName)
        end
        if type(profile) ~= "table" then return allowed end

        if type(profile.contributorRaces) == "table" then
            for raceToken in pairs(profile.contributorRaces) do
                allowed[raceToken] = true
            end
        end

        local racialRace = { bloodfury = "Orc", berserking = "Troll" }
        local function ScanAbilities(container)
            if type(container) ~= "table" then return end
            for _, entry in pairs(container) do
                if type(entry) == "table" and type(entry.abilities) == "table" then
                    for abilityKey, abilityCfg in pairs(entry.abilities) do
                        local race = racialRace[abilityKey]
                        if race and type(abilityCfg) == "table" and abilityCfg.enabled then
                            allowed[race] = true
                        end
                    end
                end
            end
        end
        ScanAbilities(profile.bosses)
        ScanAbilities(profile.trash)

        return allowed
    end

    -- forceLocal: callers that LIST this character's own profiles (the zone-in
    -- picker, the boss-notes switcher) must also WRITE locally, or the click
    -- silently retargets whoever is being remote edited.
    function RC:SetActiveRaidProfile(raidName, profileName, forceLocal)
        local structure, isRemote
        if forceLocal then
            structure, isRemote = self:GetRaidProfileStructure(raidName), false
        else
            structure, isRemote = self:GetEditableRaidProfileStructure(raidName)
        end

        if not structure.profiles[profileName] then
            self:Print(RCL["ERROR: Profile '"] .. profileName .. RCL["' does not exist for "] .. raidName)
            return false
        end

        structure.activeProfile = profileName
        self:SaveConfigurationToProfile()

        -- Everything below rebuilds THIS character's runtime state from its own
        -- active profile. None of it applies when the profile we just switched
        -- belongs to someone else.
        if isRemote then
            self:DebugPrint("Switched remote " .. raidName .. " to profile: " .. profileName, "config")
            return true
        end

        -- An open raid page for this raid still points at the old profile's
        -- tables, so its edits would land in a profile no longer in use.
        -- The sidebar's own profile dropdown rebuilds the page itself; any
        -- other switch (zone-in picker, notes, import) is caught here. The
        -- short wait lets that rebuild happen first, so it is never done twice.
        C_Timer.After(0.15, function()
            local f = RC._lastPageFrame
            if f and f:IsShown() and f._pageRaid == raidName and f._pageEncounter
               and f._pageRaidSettings ~= RC:GetEditableActiveProfile(raidName) then
                RC:ShowInlineAbilityConfig(f, raidName, f._pageEncounter, f._pageType, nil, true)
            end
        end)

        self:DebugPrint("Switched " .. raidName .. " to profile: " .. profileName, "config")

        if self.RebuildTrashKillWatch then self:RebuildTrashKillWatch() end

        if self.RaidRoute and self.RaidRoute.SyncBossStepsFromConfig then
            self.RaidRoute:SyncBossStepsFromConfig(raidName)
        end

        return true
    end

    function RC:CreateRaidProfile(raidName, profileName)
        if not profileName or profileName == "" then
            self:Print(RCL["ERROR: Profile name cannot be empty"])
            return false
        end

        local structure = self:GetEditableRaidProfileStructure(raidName)

        if structure.profiles[profileName] then
            self:Print(RCL["ERROR: Profile '"] .. profileName .. RCL["' already exists"])
            return false
        end

        structure.profiles[profileName] = {
            enabled = true,
            bosses = {},
            trash = {}
        }

        self:SaveConfigurationToProfile()

        return true
    end

    function RC:DeleteRaidProfile(raidName, profileName)
        local structure, isRemote = self:GetEditableRaidProfileStructure(raidName)

        if not structure.profiles[profileName] then
            self:Print(RCL["ERROR: Profile '"] .. profileName .. RCL["' does not exist"])
            return false
        end

        local profileCount = 0
        for _ in pairs(structure.profiles) do
            profileCount = profileCount + 1
        end

        if profileCount <= 1 then
            self:Print(RCL["ERROR: Cannot delete the last profile. Create a new profile first."])
            return false
        end

        if structure.activeProfile == profileName then
            for name, _ in pairs(structure.profiles) do
                if name ~= profileName then
                    structure.activeProfile = name
                    break
                end
            end
        end

        structure.profiles[profileName] = nil

        -- Kill history belongs to THIS character. Deleting someone else's
        -- profile while remote editing must not prune our own fights.
        local prefix = raidName .. "|" .. profileName .. "_"
        if not isRemote and self.executeCalculator and self.executeCalculator.fightHistory and
           self.executeCalculator.fightHistory.data then
            for key in pairs(self.executeCalculator.fightHistory.data) do
                if key:sub(1, #prefix) == prefix then
                    self.executeCalculator.fightHistory.data[key] = nil
                end
            end
        end

        self:SaveConfigurationToProfile()

        return true
    end

    function RC:MergeRaidProfiles(raidName, sourceName, destName)
        if not raidName or not sourceName or not destName then
            self:Print(RCL["ERROR: Merge requires raidName, sourceName, destName"])
            return false
        end
        if sourceName == destName then
            self:Print(RCL["ERROR: Cannot merge a profile into itself"])
            return false
        end

        local structure = self:GetEditableRaidProfileStructure(raidName)
        local source = structure.profiles[sourceName]
        local dest   = structure.profiles[destName]
        if not source then
            self:Print(RCL["ERROR: Source profile '"] .. sourceName .. RCL["' does not exist"])
            return false
        end
        if not dest then
            self:Print(RCL["ERROR: Destination profile '"] .. destName .. RCL["' does not exist"])
            return false
        end

        dest.bosses = dest.bosses or {}
        dest.trash  = dest.trash  or {}

        local bossesAdded, abilitiesAdded, trashAdded = 0, 0, 0

        if source.bosses then
            for bossName, sourceBoss in pairs(source.bosses) do
                if not dest.bosses[bossName] then
                    dest.bosses[bossName] = RC.DeepCopy(sourceBoss)
                    bossesAdded = bossesAdded + 1
                else
                    local destBoss = dest.bosses[bossName]
                    destBoss.abilities = destBoss.abilities or {}
                    if sourceBoss.abilities then
                        for abilityKey, sourceAbility in pairs(sourceBoss.abilities) do
                            if not destBoss.abilities[abilityKey] then
                                destBoss.abilities[abilityKey] = RC.DeepCopy(sourceAbility)
                                abilitiesAdded = abilitiesAdded + 1
                            end
                        end
                    end
                end
            end
        end

        if source.trash then
            for mobName, sourceMob in pairs(source.trash) do
                if not dest.trash[mobName] then
                    dest.trash[mobName] = RC.DeepCopy(sourceMob)
                    trashAdded = trashAdded + 1
                else
                    local destMob = dest.trash[mobName]
                    destMob.abilities = destMob.abilities or {}
                    if sourceMob.abilities then
                        for abilityKey, sourceAbility in pairs(sourceMob.abilities) do
                            if not destMob.abilities[abilityKey] then
                                destMob.abilities[abilityKey] = RC.DeepCopy(sourceAbility)
                                abilitiesAdded = abilitiesAdded + 1
                            end
                        end
                    end
                end
            end
        end

        self:SaveConfigurationToProfile()

        self:Print(string.format(RCL["Merged '%s' into '%s': +%d bosses, +%d abilities, +%d trash entries"],
            sourceName, destName, bossesAdded, abilitiesAdded, trashAdded))
        self:DebugPrint(string.format(RCL["MergeRaidProfiles: %s < %s = %d/%d/%d added"],
            destName, sourceName, bossesAdded, abilitiesAdded, trashAdded), "config")

        return true
    end

    function RC:RenameRaidProfile(raidName, oldName, newName)
        if not newName or newName == "" then
            self:Print(RCL["ERROR: New profile name cannot be empty"])
            return false
        end

        local structure, isRemote = self:GetEditableRaidProfileStructure(raidName)

        if not structure.profiles[oldName] then
            self:Print(RCL["ERROR: Profile '"] .. oldName .. RCL["' does not exist"])
            return false
        end

        if structure.profiles[newName] then
            self:Print(RCL["ERROR: Profile '"] .. newName .. RCL["' already exists"])
            return false
        end

        structure.profiles[newName] = RC.DeepCopy(structure.profiles[oldName])
        structure.profiles[oldName] = nil

        if structure.activeProfile == oldName then
            structure.activeProfile = newName
        end

        -- Boss notes are keyed by profile name but live in THIS character's
        -- saved variables. Renaming someone else's profile must not rekey our
        -- own notes (their notes cannot be reached from here at all).
        local bn = (not isRemote) and self.db and self.db.bossNotes or nil
        if bn then
            -- Mirrors RC.trashPacks' keys in RaidConfigs.lua; both must
            -- agree or trash notes fail to follow a renamed profile.
            local shortFromLong = {
                ["Molten Core"] = "mc", ["Blackwing Lair"] = "bwl",
                ["Temple of Ahn'Qiraj"] = "aq40", ["Naxxramas"] = "naxx",
                ["Zul'Gurub"] = "zg", ["Onyxia's Lair"] = "onyxia",
                ["Ruins of Ahn'Qiraj"] = "aq20",
            }
            local short = shortFromLong[raidName] or RC:RaidCode(raidName)
            local moved = 0
            local function rekeyMap(map, matchFn, buildFn)
                if type(map) ~= "table" then return end
                local moves = {}
                for k, v in pairs(map) do
                    if type(k) == "string" then
                        local nk = matchFn(k) and buildFn(k) or nil
                        if nk and map[nk] == nil then moves[k] = nk end
                    end
                end
                for k, nk in pairs(moves) do
                    map[nk] = map[k]
                    map[k] = nil
                    moved = moved + 1
                end
            end
            local oldSuf = "|" .. oldName
            rekeyMap(bn.notes,
                function(k)
                    local _, rl, prof = k:match("^(.-)|(.-)|(.-)$")
                    return rl == raidName and prof == oldName
                end,
                function(k) return k:sub(1, #k - #oldName) .. newName end)
            if short then
                local pref = short .. "|"
                local function shortMatch(k) return k == pref .. oldName end
                local function shortBuild(k) return pref .. newName end
                rekeyMap(bn.trashNotesByRaid, shortMatch, shortBuild)
                rekeyMap(bn.trashNotesList,   shortMatch, shortBuild)
                rekeyMap(bn.trashNotesListMig, shortMatch, shortBuild)
                if type(bn.trashNotesByPack) == "table" then
                    rekeyMap(bn.trashNotesByPack[short],
                        function(k) return k:sub(-#oldSuf) == oldSuf end,
                        function(k) return k:sub(1, #k - #oldName) .. newName end)
                end
                local function triMatch(k)
                    local s2, _, prof = k:match("^(.-)|(.-)|(.-)$")
                    return s2 == short and prof == oldName
                end
                local function triBuild(k) return k:sub(1, #k - #oldName) .. newName end
                rekeyMap(bn.trashNoteKills, triMatch, triBuild)
                rekeyMap(bn.trashNoteDur,   triMatch, triBuild)
                rekeyMap(bn.bossNoteAdded,  triMatch, triBuild)
            end
            if moved > 0 then
                self:Print(RCL["Renamed profile: moved "] .. moved
                    .. RCL[" note keys from '"] .. oldName .. RCL["' to '"] .. newName .. "'.")
            end
        end

        self:SaveConfigurationToProfile()

        return true
    end

    function RC:ExportRaidProfile(raidName, profileName)
        -- Export what is on screen: the remote character's profile while
        -- remote editing, ours otherwise.
        local structure = self:GetEditableRaidProfileStructure(raidName)

        if not structure.profiles[profileName] then
            self:Print(RCL["ERROR: Profile '"] .. profileName .. RCL["' does not exist"])
            return nil
        end

        local profile = structure.profiles[profileName]

        self:DebugPrint("=== EXPORT START ===", "profile")
        self:DebugPrint("Raid: " .. tostring(raidName), "profile")
        self:DebugPrint("Profile: " .. tostring(profileName), "profile")
        self:DebugPrint("Profile type: " .. type(profile), "profile")

        if type(profile) == "table" then
            local bossCount = 0
            local trashCount = 0
            if profile.bosses then
                for _ in pairs(profile.bosses) do bossCount = bossCount + 1 end
            end
            if profile.trash then
                for _ in pairs(profile.trash) do trashCount = trashCount + 1 end
            end
            self:DebugPrint("Bosses: " .. bossCount .. ", Trash: " .. trashCount, "profile")
        end

        local exportData = {
            version = 1,
            addon = "Readycheck",
            raidName = raidName,
            profileName = profileName,
            timestamp = time(),
            data = RC.DeepCopy(profile)
        }

        local serialized = self:SerializeTableForRaid(exportData)

        self:DebugPrint("Serialized length: " .. #serialized, "profile")
        self:DebugPrint("First 200 chars: " .. serialized:sub(1, math.min(200, #serialized)), "profile")

        local encoded = self:EncodeBase64ForRaid(serialized)

        self:DebugPrint("Encoded length: " .. #encoded, "profile")
        self:DebugPrint("=== EXPORT COMPLETE ===", "profile")

        return "WR1:" .. encoded
    end

    local B64_ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local B64_ENC, B64_DEC = {}, {}
    for i = 1, 64 do
        local c = B64_ALPHA:sub(i, i)
        B64_ENC[i - 1] = c
        B64_DEC[c:byte()] = i - 1
    end

    function RC:EncodeBase64ForRaid(str)
        local out, o = {}, 0
        local len = #str
        local i = 1
        local floor = math.floor
        while i <= len do
            local b1, b2, b3 = str:byte(i, i + 2)
            local n = b1 * 65536 + (b2 or 0) * 256 + (b3 or 0)
            o = o + 1
            out[o] = B64_ENC[floor(n / 262144)]
                .. B64_ENC[floor(n / 4096) % 64]
                .. (b2 and B64_ENC[floor(n / 64) % 64] or "=")
                .. (b3 and B64_ENC[n % 64] or "=")
            i = i + 3
        end
        return table.concat(out)
    end

    function RC:DecodeBase64ForRaid(str)
        str = str:gsub("%s+", "")
        local out, o = {}, 0
        local len = #str
        local i = 1
        local EQ = string.byte("=")
        local floor = math.floor
        local char = string.char
        while i <= len do
            local c1, c2, c3, c4 = str:byte(i, i + 3)
            local n1 = c1 and B64_DEC[c1]
            local n2 = c2 and B64_DEC[c2]
            if not n1 or not n2 then return nil end
            local n3 = (c3 and c3 ~= EQ) and B64_DEC[c3] or nil
            local n4 = (c4 and c4 ~= EQ) and B64_DEC[c4] or nil
            local n = n1 * 262144 + n2 * 4096 + (n3 or 0) * 64 + (n4 or 0)
            o = o + 1
            if n4 then
                out[o] = char(floor(n / 65536), floor(n / 256) % 256, n % 256)
            elseif n3 then
                out[o] = char(floor(n / 65536), floor(n / 256) % 256)
            else
                out[o] = char(floor(n / 65536))
            end
            i = i + 4
        end
        return table.concat(out)
    end

    function RC:DecodeFromExport(str)
        if not str or not str:match("^WR1:") then
            return nil
        end

        local encoded = str:sub(5)

        return self:DecodeBase64ForRaid(encoded)
    end

    function RC:ScrubUnknownGearSets(profileData)
        if type(profileData) ~= "table" then return 0 end
        local known = {}
        if self.GetAllGearSets then
            for _, e in ipairs(self:GetAllGearSets()) do known[e.name] = true end
        end
        local n = 0
        local function scrub(t, k)
            local v = t and t[k]
            if type(v) == "string" and v ~= "" and not known[v] then
                t[k] = ""
                n = n + 1
            end
        end
        if type(profileData.bosses) == "table" then
            for _, b in pairs(profileData.bosses) do
                local gs = type(b) == "table" and b.abilities and b.abilities.gearswap
                if gs then
                    scrub(gs, "gearSet")
                    scrub(gs, "postCombatSet")
                end
            end
        end
        local steps = profileData.route and profileData.route.steps
        if type(steps) == "table" then
            for _, st in ipairs(steps) do
                if type(st) == "table" and type(st.actions) == "table" then
                    scrub(st.actions, "gearSet")
                end
            end
        end
        return n
    end

    function RC:ImportRaidProfile(importString, newName)
        self:DebugPrint("=== IMPORT START ===", "profile")

        local decoded = self:DecodeFromExport(importString)

        if not decoded then
            self:Print(RCL["ERROR: Invalid import string format (not WR1: format)"])
            return false
        end

        self:DebugPrint("Decoded length: " .. #decoded, "profile")
        self:DebugPrint("First 100 chars: " .. decoded:sub(1, math.min(100, #decoded)), "profile")

        local data = self:DeserializeTableForRaid(decoded)

        if not data then
            self:Print(RCL["ERROR: Invalid import string - could not deserialize data"])
            self:DebugPrint("Deserialization failed - decoded string length: " .. #decoded, "profile")
            return false
        end

        self:DebugPrint("Deserialized data type: " .. type(data), "profile")
        if type(data) == "table" then
            if data.addon then
                self:DebugPrint("Addon: '" .. tostring(data.addon) .. "'", "profile")
            end
            if data.raidName then
                self:DebugPrint("Raid: '" .. tostring(data.raidName) .. "'", "profile")
            end
            if data.profileName then
                self:DebugPrint("Original profile name: '" .. tostring(data.profileName) .. "'", "profile")
            end
        end

        if not data.addon then
            self:Print(RCL["ERROR: Import data missing 'addon' field"])
            return false
        end

        if data.addon ~= "WarriorReminder" and data.addon ~= "Readycheck" then
            self:Print(RCL["ERROR: Import data is not from Readycheck"])
            self:Print(RCL["Found addon: '"] .. tostring(data.addon) .. "'")
            return false
        end

        if not data.raidName or not data.data then
            self:Print(RCL["ERROR: Import data is corrupted - missing raidName or data"])
            return false
        end

        local raidName = data.raidName
        local profileName = newName or data.profileName or "Imported"

        if profileName == "" then
            profileName = "Imported"
        end

        -- Import into whichever config is open - remote editing means the
        -- imported profile belongs to the character being edited.
        local structure = self:GetEditableRaidProfileStructure(raidName)

        if structure.profiles[profileName] then
            local baseName = profileName
            local counter = 2
            while structure.profiles[profileName] do
                profileName = baseName .. " (" .. counter .. ")"
                counter = counter + 1
            end
            self:DebugPrint("Name conflict - using '" .. profileName .. "'", "profile")
        end

        if type(data.data) ~= "table" then
            self:Print(RCL["ERROR: Invalid profile data"])
            return false
        end
        structure.profiles[profileName] = RC.DeepCopy(data.data)
        do
            local p = structure.profiles[profileName]
            if type(p.bosses) ~= "table" then p.bosses = {} end
            if type(p.trash) ~= "table" then p.trash = {} end
        end
        do
            local scrubbed = self:ScrubUnknownGearSets(structure.profiles[profileName])
            if scrubbed > 0 then
                self:Print(RCL["Import: "] .. scrubbed .. RCL[" gear set name(s) from the"]
                    .. RCL[" sender don't exist on this character - cleared to None."]
                    .. RCL[" Re-pick your own sets on those bosses/steps."])
            end
        end

        self:SaveConfigurationToProfile()

        self:DebugPrint("Successfully created profile '" .. profileName .. "'", "profile")
        self:DebugPrint("=== IMPORT COMPLETE ===", "profile")

        self:Print(RCL["Imported profile '"] .. profileName .. RCL["' for "] .. raidName)

        return true, raidName, profileName
    end

    function RC:SerializeTableForRaid(tbl, depth, seen)
        depth = depth or 0
        seen = seen or {}

        -- seen[] catches genuine circular references; the depth cap below
        -- is a backstop for extreme non-cyclic nesting (corrupted profile data).
        if seen[tbl] then
            return "nil"
        end
        seen[tbl] = true

        if depth > 50 then
            if depth == 51 then
                self:Print(RCL["WARNING: Export failed - data too deeply nested (depth="] .. depth .. ")")
                self:Print(RCL["This indicates a circular reference or corrupted profile data"])
            end
            return "nil"
        end

        local result = "{"
        local first = true

        for k, v in pairs(tbl) do
            local vtype = type(v)
            if vtype == "function" or vtype == "userdata" or vtype == "thread" then
            else
                if not first then
                    result = result .. ","
                end
                first = false

                if type(k) == "number" then
                    result = result .. "[" .. k .. "]="
                else
                    local escapedKey = tostring(k)
                    escapedKey = escapedKey:gsub("\\", "\\\\")
                    escapedKey = escapedKey:gsub("'", [[\']])
                    escapedKey = escapedKey:gsub("\n", "\\n")
                    escapedKey = escapedKey:gsub("\r", "\\r")
                    escapedKey = escapedKey:gsub("\t", "\\t")
                    result = result .. "['" .. escapedKey .. "']="
                end

                if vtype == "table" then
                    result = result .. self:SerializeTableForRaid(v, depth + 1, seen)
                elseif vtype == "string" then
                    local escapedValue = v
                    escapedValue = escapedValue:gsub("\\", "\\\\")
                    escapedValue = escapedValue:gsub("'", [[\']])
                    escapedValue = escapedValue:gsub("\n", "\\n")
                    escapedValue = escapedValue:gsub("\r", "\\r")
                    escapedValue = escapedValue:gsub("\t", "\\t")
                    result = result .. "'" .. escapedValue .. "'"
                elseif vtype == "boolean" then
                    result = result .. (v and "true" or "false")
                elseif vtype == "number" then
                    result = result .. tostring(v)
                else
                    result = result .. "nil"
                end
            end
        end

        result = result .. "}"
        return result
    end

    function RC:DeserializeTableForRaid(str)
        if not str or str == "" then
            return nil
        end

        local func, err = loadstring("return " .. str)
        -- Sandboxed to an empty environment: imported data can only build a
        -- literal table, never call globals or reach anything of ours.
        if func and setfenv then
            setfenv(func, {})
        end
        if not func then
            self:Print(RCL["ERROR: Deserialization failed - syntax error in data"])
            self:Print(RCL["Error: "] .. tostring(err))

            local errorLine = err:match(":(%d+):")
            if errorLine then
                errorLine = tonumber(errorLine)
                self:Print(RCL["Error at approximate position: "] .. tostring(errorLine))
            end

            local preview1 = str:sub(1, 300)
            local preview2 = str:sub(-300)
            self:Print(RCL["Data START: "] .. preview1)
            self:Print(RCL["Data END: "] .. preview2)
            self:Print(RCL["Total length: "] .. #str)

            return nil
        end

        local success, result = pcall(func)
        if not success then
            self:Print(RCL["ERROR: Deserialization failed - could not execute data"])
            self:Print(RCL["Error: "] .. tostring(result))
            return nil
        end

        return result
    end

    -- Runs once after login: if a raid's active profile is empty/disabled
    -- but a better-scored sibling profile exists, switch to it automatically.
    C_Timer.After(2.5, function()
        if not (RC.db and RC.db.raidProfiles) then return end
        local function Score(pd)
            if type(pd) ~= "table" then return -1 end
            local s = 0
            if type(pd.bosses) == "table" then
                for _ in pairs(pd.bosses) do s = s + 1 end
            end
            if pd.enabled then s = s + 100 end
            return s
        end
        local fixed = false
        for raidName, structure in pairs(RC.db.raidProfiles) do
            -- another game version's raids are left as saved
            if type(structure) == "table" and type(structure.profiles) == "table"
               and RC:RaidShownHere(raidName) then
                local curName = structure.activeProfile
                local cur = curName and structure.profiles[curName]
                if Score(cur) <= 0 then
                    local bestName, bestScore
                    for pName, pd in pairs(structure.profiles) do
                        local sc = Score(pd)
                        if not bestScore or sc > bestScore then
                            bestName, bestScore = pName, sc
                        end
                    end
                    if bestName and bestName ~= curName and bestScore and bestScore > 0 then
                        structure.activeProfile = bestName
                        RC:Print(raidName .. RCL[": active profile was empty - switched to '"] .. bestName .. "'")
                        fixed = true
                    end
                end
            end
        end
        if fixed then
            RC:SaveConfigurationToProfile()
        end
    end)

    RC._profilePicker = RC._profilePicker or { frame = nil }

    local function CountProfiles(raidName)
        local structure = RC.db and RC.db.raidProfiles and RC.db.raidProfiles[raidName]
        if not structure or not structure.profiles then return 0, {} end
        local names = {}
        for name in pairs(structure.profiles) do
            table.insert(names, name)
        end
        table.sort(names)
        return #names, names
    end

    -- Raid icon for the picker header and row cards; falls back to a
    -- generic skull for a raid without one.
    local PICKER_RAID_ICONS = {
        ["Molten Core"]          = "Interface\\Icons\\Spell_Fire_Incinerate",
        ["Blackwing Lair"]       = "Interface\\Icons\\INV_Misc_Head_Dragon_Black",
        ["Temple of Ahn'Qiraj"]  = "Interface\\Icons\\INV_Misc_QirajiCrystal_05",
        ["Naxxramas"]            = "Interface\\Icons\\Achievement_Boss_KelThuzad_01",
    }
    local PICKER_GENERIC_ICON = "Interface\\Icons\\Spell_Shadow_DeathsEmbrace"

    local function PickerRaidIcon(raidName)
        return PICKER_RAID_ICONS[raidName] or RC:RaidIcon(raidName) or PICKER_GENERIC_ICON
    end

    -- Picker geometry (ZacUI grid): 30px title bar, 18px page margin,
    -- header (icon 20 + title 15 + subtitle 11 + gold rule), 40px row
    -- cards 6px apart, 44px footer under a 1px black rule.
    local PICKER_ROW_H   = 40
    local PICKER_ROW_GAP = 6
    local PICKER_HEADER_H = 54
    local PICKER_FOOTER_H = 38
    local PICKER_MARGIN  = 18

    local function BuildPickerFrame()
        if RC._profilePicker.frame then return RC._profilePicker.frame end

        local windowBg   = RC:GetColor("ui", "windowBackground")
        local headerBg   = RC:GetColor("ui", "headerBackground")
        local accent     = RC:GetColor("ui", "accentGold")
        local headerText = RC:GetColor("ui", "headerText")
        local titleGold  = RC:GetColor("text", "gold")
        local noteText   = RC:GetColor("text", "gray")
        local borderNorm = RC:GetColor("ui", "borderNormal")
        local FLAT       = RC.UI.FLAT

        local frame = CreateFrame("Frame", "ReadycheckProfilePicker", UIParent)
        frame:SetSize(320, 200)
        frame:SetPoint("CENTER", 0, 80)
        frame:SetFrameStrata("DIALOG")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:SetClampedToScreen(true)
        frame:SetToplevel(true)
        frame:SetScript("OnMouseDown", function(self) self:Raise() end)
        RC.UI:RegisterEscapeClose(frame)

        -- Flat window: WHITE8X8 fill, 1px black ring, 30px flat title bar
        -- with a gold hairline under it and a chromeless X.
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(FLAT)
        bg:SetVertexColor(windowBg.r, windowBg.g, windowBg.b, windowBg.a or 0.95)

        if RC.UI and RC.UI.CreateSimpleBorder then
            RC.UI:CreateSimpleBorder(frame)
        end

        local titleBar = CreateFrame("Frame", nil, frame)
        titleBar:SetHeight(30)
        titleBar:SetPoint("TOPLEFT", 1, -1)
        titleBar:SetPoint("TOPRIGHT", -1, -1)
        titleBar:EnableMouse(true)
        titleBar:RegisterForDrag("LeftButton")
        titleBar:SetScript("OnDragStart", function() frame:StartMoving() end)
        titleBar:SetScript("OnDragStop", function() frame:StopMovingOrSizing() end)

        local titleBg = titleBar:CreateTexture(nil, "BACKGROUND")
        titleBg:SetAllPoints()
        titleBg:SetTexture(FLAT)
        titleBg:SetVertexColor(headerBg.r, headerBg.g, headerBg.b, headerBg.a or 1)

        local accentLine = titleBar:CreateTexture(nil, "ARTWORK")
        accentLine:SetPoint("BOTTOMLEFT", 0, 0)
        accentLine:SetPoint("BOTTOMRIGHT", 0, 0)
        accentLine:SetHeight(1)
        accentLine:SetTexture(FLAT)
        accentLine:SetVertexColor(accent.r, accent.g, accent.b, 0.6)
        if RC.UI.ApplyHeaderArt then
            accentLine:Hide()
            RC.UI:ApplyHeaderArt(titleBar, { fill = titleBg, stepX = 160 })
        end

        local titleIcon = RC.UI:AddTitleIcon(titleBar, 16, 8)

        local title = RC:CreateFontString(titleBar, "OVERLAY", nil, 15, "")
        title:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        title:SetTextColor(headerText.r, headerText.g, headerText.b, 1)
        title:SetText(RCL["Raid Profile Picker"])
        frame.title = title

        local function ClosePicker()
            if RC.UI.PopOut then RC.UI:PopOut(frame, 0.1) else frame:Hide() end
        end
        frame.ClosePicker = ClosePicker

        local closeBtn = RC.UI:CreateXCloseButton(titleBar, 22, ClosePicker)
        closeBtn:SetPoint("RIGHT", -5, 0)

        -- Header: 20px raid icon, raid name 15px gold, 11px gray
        -- subtitle, 1px gold rule across the bottom.
        local header = CreateFrame("Frame", nil, frame)
        header:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", PICKER_MARGIN - 1, -10)
        header:SetPoint("TOPRIGHT", titleBar, "BOTTOMRIGHT", -(PICKER_MARGIN - 1), -10)
        header:SetHeight(PICKER_HEADER_H)
        frame.header = header

        -- Icon and text sit on the same x as the rows below (10 / 42),
        -- so the header reads as the first item of the same list rather
        -- than a block indented by its own amount. Vertically centred on
        -- the two-line text block, not pinned to its top.
        local raidIcon = header:CreateTexture(nil, "ARTWORK")
        raidIcon:SetSize(24, 24)
        raidIcon:SetPoint("LEFT", header, "LEFT", 10, 6)
        raidIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        frame.raidIcon = raidIcon

        local subtitle = RC:CreateFontString(header, "OVERLAY", nil, 15, "")
        subtitle:SetPoint("TOPLEFT", header, "TOPLEFT", 42, -2)
        subtitle:SetPoint("RIGHT", header, "RIGHT", -14, 0)
        subtitle:SetJustifyH("LEFT")
        subtitle:SetTextColor(titleGold.r, titleGold.g, titleGold.b, 1)
        frame.subtitle = subtitle

        local hint = RC:CreateFontString(header, "OVERLAY", nil, 11, "")
        hint:SetPoint("TOPLEFT", subtitle, "BOTTOMLEFT", 0, -4)
        hint:SetPoint("RIGHT", header, "RIGHT", -14, 0)
        hint:SetJustifyH("LEFT")
        hint:SetTextColor(noteText.r, noteText.g, noteText.b, 1)
        hint:SetText(RCL["Click a profile to use it for this run"])
        frame.hint = hint

        local headerRule = header:CreateTexture(nil, "ARTWORK")
        headerRule:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
        headerRule:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
        headerRule:SetHeight(1)
        headerRule:SetTexture(FLAT)
        headerRule:SetVertexColor(accent.r, accent.g, accent.b, 0.6)

        -- Footer: 1px black rule and a single dismiss. Picking a profile
        -- is one click on its row - a confirm button on top of that is a
        -- second click to say what the first click already said.
        local footer = CreateFrame("Frame", nil, frame)
        footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
        footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
        footer:SetHeight(PICKER_FOOTER_H)
        frame.footer = footer

        local footerRule = footer:CreateTexture(nil, "ARTWORK")
        footerRule:SetPoint("TOPLEFT", footer, "TOPLEFT", 0, 0)
        footerRule:SetPoint("TOPRIGHT", footer, "TOPRIGHT", 0, 0)
        footerRule:SetHeight(1)
        footerRule:SetTexture(FLAT)
        footerRule:SetVertexColor(borderNorm.r, borderNorm.g, borderNorm.b, borderNorm.a or 1)

        local useBtn = RC.UI:CreateStyledButton(footer, RCL["Use profile"], 100, 22)
        useBtn:SetPoint("RIGHT", footer, "RIGHT", -(PICKER_MARGIN - 1), 0)
        useBtn:Hide()
        useBtn:SetActive(true)
        useBtn:SetScript("OnClick", function()
            if frame.onUse then frame.onUse() end
        end)
        frame.useBtn = useBtn

        local laterBtn = RC.UI:CreateStyledButton(footer, RCL["Not now"], 100, 22)
        laterBtn:SetPoint("RIGHT", footer, "RIGHT", -(PICKER_MARGIN - 1 + 10), 0)
        laterBtn:SetScript("OnClick", ClosePicker)
        frame.laterBtn = laterBtn

        -- Row list scrolls when the saved height is shorter than the
        -- profile count needs; the 16px framework scrollbar hides itself
        -- whenever everything fits.
        local bodyHost = CreateFrame("Frame", nil, frame)
        bodyHost:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -10)
        bodyHost:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -10)
        bodyHost:SetPoint("BOTTOM", footer, "TOP", 0, 6)
        frame.bodyHost = bodyHost

        local scrollFrame = CreateFrame("ScrollFrame", nil, bodyHost)
        scrollFrame:SetPoint("TOPLEFT", bodyHost, "TOPLEFT", 0, 0)
        scrollFrame:SetPoint("BOTTOMRIGHT", bodyHost, "BOTTOMRIGHT", -20, 0)
        local body = CreateFrame("Frame", nil, scrollFrame)
        body:SetSize(200, 10)
        scrollFrame:SetScrollChild(body)
        frame.scrollFrame = scrollFrame
        frame.body = body
        frame.buttons = {}

        local scrollBar = RC.UI:AttachScrollbar(scrollFrame, bodyHost, { width = 16 })
        scrollBar:ClearAllPoints()
        scrollBar:SetPoint("TOPRIGHT", bodyHost, "TOPRIGHT", 0, 0)
        scrollBar:SetPoint("BOTTOMRIGHT", bodyHost, "BOTTOMRIGHT", 0, 0)
        frame.scrollBar = scrollBar

        local function SyncBody()
            local w = scrollFrame:GetWidth() or 0
            if w > 0 then body:SetWidth(w) end
            scrollBar:SyncRange(body:GetHeight() or 0, scrollFrame:GetHeight() or 0)
        end
        frame.SyncBody = SyncBody
        scrollFrame:SetScript("OnSizeChanged", SyncBody)
        -- the 5.0 popup look (UIF_Dialogs); the profile rows keep their own
        RC.UI:SkinPopup(frame, { fill = bg, header = titleBar, title = title, close = closeBtn,
            buttons = { laterBtn }, primary = useBtn, scan = false })

        -- The same six-dot handle every other Readycheck window uses; only
        -- the "remember the size" half of the mouse-up is the picker's.
        local resizeGrip = RC.UI:AttachResizeGrip(frame, {
            minW = 260, minH = 150, maxW = 700, maxH = 700,
        })
        resizeGrip:SetScript("OnMouseUp", function()
            frame:StopMovingOrSizing()
            if RC.db then
                RC.db.profilePicker = RC.db.profilePicker or {}
                RC.db.profilePicker.width  = math.floor(frame:GetWidth() + 0.5)
                RC.db.profilePicker.height = math.floor(frame:GetHeight() + 0.5)
            end
            SyncBody()
        end)

        RC._profilePicker.frame = frame
        return frame
    end

    -- "<n> bosses configured" for a profile: the same count the sidebar
    -- shows (anything set up, gear included; phases and the horsemen
    -- count once with their boss).
    local function CountConfiguredBosses(profileData)
        local n, seen = 0, {}
        if type(profileData) == "table" and type(profileData.bosses) == "table" then
            for key, bossData in pairs(profileData.bosses) do
                if RC:EncounterHasConfig(bossData) then
                    local name = RC:EncounterMenuName(key)
                    if not seen[name] then
                        seen[name] = true
                        n = n + 1
                    end
                end
            end
        end
        return n
    end

    -- Row card paint: rest = ui.elementBackground + 1px black; hover =
    -- buttons.hoverBackground; the profile already in use = green fill,
    -- a 3px muted-green bar down the left edge and a matching ring.
    -- There is no separate "selected" state: a click applies the profile
    -- and closes the picker, so the only thing worth marking is which one
    -- is currently in use.
    local function PaintPickerRow(btn, hot)
        local fill, txt
        if btn.isActive then
            fill = hot and RC:GetColor("buttons", "configuredHover") or RC:GetColor("buttons", "configuredBackground")
            RC.UI:UpdateBorderColor(btn.border, RC:GetColor("ui", "borderSelected"), 1)
            btn.selBar:Show()
            txt = RC:GetColor("text", "buttonActive")
        else
            fill = hot and RC:GetColor("buttons", "hoverBackground") or RC:GetColor("ui", "elementBackground")
            RC.UI:UpdateBorderColor(btn.border, RC:GetColor("ui", "borderNormal"), 1)
            btn.selBar:Hide()
            txt = hot and RC:GetColor("ui", "accentGold") or RC:GetColor("text", "normal")
        end
        btn.bg:SetVertexColor(fill.r, fill.g, fill.b, 1)
        btn.txt:SetTextColor(txt.r, txt.g, txt.b, 1)
        local sc = btn.isActive and RC:GetColor("text", "buttonActive")
            or RC:GetColor("text", "gray")
        btn.sub:SetTextColor(sc.r, sc.g, sc.b, 1)
    end

    -- Picker rows are pooled by index on frame.buttonPool and re-skinned on
    -- every open instead of being recreated - each recreation also grew
    -- RC.trackedFonts via the label registration. They read per-open
    -- state (isActive/onClick) off the button.
    local function BuildProfileButton(frame, index, profileName, isActive, onClick, iconPath, subText)
        frame.buttonPool = frame.buttonPool or {}
        local btn = frame.buttonPool[index]
        if not btn then
            btn = CreateFrame("Button", nil, frame.body)
            btn:SetHeight(PICKER_ROW_H)

            btn.bg = btn:CreateTexture(nil, "BACKGROUND")
            btn.bg:SetAllPoints()
            btn.bg:SetTexture(RC.UI.FLAT)
            btn.border = RC.UI:CreateSimpleBorder(btn)

            btn.selBar = btn:CreateTexture(nil, "ARTWORK")
            btn.selBar:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
            btn.selBar:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
            btn.selBar:SetWidth(3)
            btn.selBar:SetTexture(RC.UI.FLAT)
            local ac = RC:GetColor("ui", "borderSelected")
            btn.selBar:SetVertexColor(ac.r, ac.g, ac.b, 1)

            btn.icon = btn:CreateTexture(nil, "ARTWORK")
            btn.icon:SetSize(24, 24)
            btn.icon:SetPoint("LEFT", btn, "LEFT", 10, 0)
            btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            -- Name + sub-line are one block centred in the 40px row: the
            -- name's own height is fixed so the pair cannot drift when a
            -- font size changes, and the icon centres against the same row.
            local txt = RC:CreateFontString(btn, "OVERLAY", nil, 12, "")
            txt:SetPoint("TOPLEFT", btn, "TOPLEFT", 42, -8)
            txt:SetPoint("RIGHT", btn, "RIGHT", -14, 0)
            txt:SetHeight(13)
            txt:SetJustifyH("LEFT")
            txt:SetWordWrap(false)
            btn.txt = txt

            local sub = RC:CreateFontString(btn, "OVERLAY", nil, 10, "")
            sub:SetPoint("TOPLEFT", txt, "BOTTOMLEFT", 0, -1)
            sub:SetPoint("RIGHT", btn, "RIGHT", -14, 0)
            sub:SetHeight(11)
            sub:SetJustifyH("LEFT")
            sub:SetWordWrap(false)
            btn.sub = sub

            btn:SetScript("OnEnter", function(self) PaintPickerRow(self, true) end)
            btn:SetScript("OnLeave", function(self) PaintPickerRow(self, false) end)
            btn:SetScript("OnClick", function(self)
                if self.onClick then self.onClick() end
            end)

            frame.buttonPool[index] = btn
        end

        btn.isActive = isActive
        btn.onClick = onClick
        btn.icon:SetTexture(iconPath)
        btn.txt:SetText(profileName)
        btn.sub:SetText(subText or "")

        btn:ClearAllPoints()
        btn:Show()
        return btn
    end

    function RC:ShowRaidProfilePicker(raidName)
        local count, names = CountProfiles(raidName)
        if count <= 1 then return end

        local frame = BuildPickerFrame()

        -- Hide the rows from the previous open; the pool keeps them for reuse.
        if frame.buttonPool then
            for _, b in ipairs(frame.buttonPool) do b:Hide() end
        end
        frame.buttons = {}

        local structure = RC.db.raidProfiles[raidName]
        local activeName = structure.activeProfile or "Default"
        local iconPath = PickerRaidIcon(raidName)

        frame.title:SetText(RCL["Raid Profile Picker"])
        frame.raidIcon:SetTexture(iconPath)
        frame.subtitle:SetText(raidName)

        -- One click on a row is the whole interaction: it switches the
        -- profile and closes the picker.
        frame.selectedProfile = activeName
        local function RepaintRows()
            for _, b in ipairs(frame.buttons) do
                PaintPickerRow(b, b:IsMouseOver())
            end
        end

        local y = 0
        for i, profileName in ipairs(names) do
            local isActive = (profileName == activeName)
            local nBosses = CountConfiguredBosses(structure.profiles[profileName])
            local subText
            if nBosses == 1 then
                subText = RCL["1 boss configured"]
            else
                subText = string.format(RCL["%d bosses configured"], nBosses)
            end
            if isActive then
                subText = subText .. RCL[" \194\183 current"]
            end
            local btn = BuildProfileButton(frame, i, profileName, isActive, function()
                frame.selectedProfile = profileName
                if frame.onUse then frame.onUse() end
            end, iconPath, subText)
            btn.profileName = profileName
            btn:SetPoint("TOPLEFT", frame.body, "TOPLEFT", 0, y)
            btn:SetPoint("TOPRIGHT", frame.body, "TOPRIGHT", 0, y)
            y = y - (PICKER_ROW_H + PICKER_ROW_GAP)
            table.insert(frame.buttons, btn)
        end
        RepaintRows()

        frame.onUse = function()
            local chosen = frame.selectedProfile
            if chosen and chosen ~= activeName then
                -- This picker lists our own profiles (and fires on zone-in),
                -- so it must always switch our own active profile.
                RC:SetActiveRaidProfile(raidName, chosen, true)
            end
            frame.ClosePicker()
        end

        local N = #names
        local bodyContentHeight = math.max(PICKER_ROW_H, N * (PICKER_ROW_H + PICKER_ROW_GAP) - PICKER_ROW_GAP)
        frame.body:SetHeight(bodyContentHeight)
        -- 30px title bar + 10 gap + header + 10 gap above the rows, 6 +
        -- footer below them.
        local minHeight = 30 + 10 + PICKER_HEADER_H + 10 + bodyContentHeight + 6 + PICKER_FOOTER_H + 2
        local maxHeight = UIParent:GetHeight() * 0.7
        if minHeight > maxHeight then minHeight = maxHeight end

        if frame.SetResizeBounds then
            frame:SetResizeBounds(260, minHeight, 700, 700)
        elseif frame.SetMinResize then
            frame:SetMinResize(260, minHeight)
        end

        local saved = (RC.db and RC.db.profilePicker) or {}
        local desiredHeight = minHeight
        if saved.height and saved.height > minHeight then
            desiredHeight = saved.height
        end
        frame:SetHeight(desiredHeight)

        if saved.width and saved.width >= 260 then
            frame:SetWidth(saved.width)
        end

        RC.UI:StopAnimations(frame)
        RC.UI:PopIn(frame, 0.12)
        frame:Raise()
        frame.SyncBody()

        if RC.db then
            RC.db.profilePicker = RC.db.profilePicker or {}
            RC.db.profilePicker.lastPromptedRaid = raidName
            RC.db.profilePicker.lastPromptedTime = time()
        end
    end

    -- Re-prompt for the same raid roughly once per lockout window, not on
    -- every zone-in/loading screen.
    local PICKER_EXPIRY_SECONDS = 12 * 3600

    local function OnZoneChanged()
        if not RC.db then return end
        if InCombatLockdown() then
            return
        end

        local currentRaid = (RC.GetEffectiveRaidName and RC:GetEffectiveRaidName()) or nil

        if not currentRaid then return end

        RC.db.profilePicker = RC.db.profilePicker or {}
        local lastPrompted = RC.db.profilePicker.lastPromptedRaid
        local lastTime = RC.db.profilePicker.lastPromptedTime or 0
        local now = time()

        if lastPrompted == currentRaid and (now - lastTime) < PICKER_EXPIRY_SECONDS then
            return
        end

        local count = CountProfiles(currentRaid)
        if count <= 1 then
            RC.db.profilePicker.lastPromptedRaid = currentRaid
            RC.db.profilePicker.lastPromptedTime = now
            return
        end

        C_Timer.After(1.5, function()
            if (RC.GetEffectiveRaidName and RC:GetEffectiveRaidName()) == currentRaid then
                RC:ShowRaidProfilePicker(currentRaid)
            end
        end)
    end

    local zoneFrame = CreateFrame("Frame")
    zoneFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    zoneFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    zoneFrame:SetScript("OnEvent", function()
        OnZoneChanged()
    end)

    RC:DebugPrint("Raid Profiles System initialized", "config")
end

InitializeRaidProfiles()

C_Timer.After(5, function()
    local RC = _G.Readycheck
    if RC and not RC.GetActiveRaidProfile then
        print("|cffff0000[Readycheck]|r RaidProfilesSystem did NOT finish initializing - " ..
            "raid profiles and boss/TTK name resolution are disabled this session. " ..
            "Enable 'Display Lua Errors' and check the FIRST error at login; " ..
            "that error is the real cause.")
    end
end)
