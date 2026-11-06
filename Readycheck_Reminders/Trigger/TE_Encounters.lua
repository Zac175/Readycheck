------------------------------------------------------------------------
-- Readycheck - Trigger Engine Encounter Specials
-- Consumable-buff auto-dismissal plus the Kel'Thuzad Frost Blast reminder:
-- detect the KT fight, project max HP under the player's stamina buffs and
-- name which buffs to cancel to drop under the Frost Blast threshold.
-- Publishes IsInKTFight on RC._tes for the frostBlast gate in TE_Triggers.
-- Everything aura-driven here runs from the shared throttled UNIT_AURA
-- callback registered in TE_Events, never from a raw UNIT_AURA handler.
------------------------------------------------------------------------
local RCC = _G.Readycheck

local ipairs, type, tostring = ipairs, type, tostring
local UnitGUID, UnitHealth, UnitHealthMax = UnitGUID, UnitHealth, UnitHealthMax
-- WoW Forever hides health in combat ("secret" values that may not be
-- compared or used in arithmetic): read as 0 there. issecretvalue does not
-- exist on the other clients, so nothing changes on them.
if issecretvalue then
    local rawHP, rawMax = UnitHealth, UnitHealthMax
    UnitHealth = function(u) local v = rawHP(u) if issecretvalue(v) then return 0 end return v end
    UnitHealthMax = function(u) local v = rawMax(u) if issecretvalue(v) then return 0 end return v end
end
local UnitName = UnitName
local UnitAffectingCombat = UnitAffectingCombat
local wipe = wipe

local reuseAbilitiesRemoved = {}
local RC = _G.Readycheck
if not RC then return end
RC._tes = RC._tes or {}
local _tes = RC._tes
local IsInKTFight
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
    function RC:CheckAndDismissPotionBuffs()
        if not self.reminderFrame or not self.reminderFrame:IsShown() then
            return
        end

        if not self.activeReminderData or not self.activeReminderData.abilities or #self.activeReminderData.abilities == 0 then
            return
        end

        wipe(reuseAbilitiesRemoved)
        local abilitiesRemoved = reuseAbilitiesRemoved

        for i = #self.activeReminderData.abilities, 1, -1 do
            local abilityKey = self.activeReminderData.abilities[i]
            local shouldRemove = self:IsConsumableBuffActive(abilityKey)
            if shouldRemove and debugDismissalEnabled then
                self:DebugPrint("Dismissing " .. tostring(abilityKey) .. " - its buff is active", "dismissal")
            end

            if shouldRemove then
                table.remove(self.activeReminderData.abilities, i)
                table.insert(abilitiesRemoved, abilityKey)

                local targetGUID = UnitGUID("target")
                if targetGUID and self.spellCastTriggers.usedAbilities[targetGUID] then
                    self.spellCastTriggers.usedAbilities[targetGUID][abilityKey] = nil
                end
                if self.spellCastTriggers.buffRemainingTriggers["player"] then
                    self.spellCastTriggers.buffRemainingTriggers["player"][abilityKey] = nil
                end
            end
        end

        if #abilitiesRemoved > 0 then
            if debugDismissalEnabled then self:DebugPrint("Buff check removed " .. #abilitiesRemoved .. " abilities", "dismissal") end
            if #self.activeReminderData.abilities == 0 then
                self:SmartDismissReminder("All buffs now active")
            else
                self:UpdateReminderWithRemainingAbilities()
            end
        end
    end

    -- Latched once any KT-fight unit is seen, so the reminder survives losing
    -- the target mid-fight. Cleared by ktCleanupFrame on regen, zone and login.
    local ktConfirmed = false

    -- Rolling 30 max-HP samples, newest first, kept only while ktConfirmed so
    -- the settings UI can show what the player's HP actually did during KT.
    local ktMaxHpFrame = CreateFrame("Frame")
    ktMaxHpFrame:RegisterUnitEvent("UNIT_MAXHEALTH", "player")
    ktMaxHpFrame:SetScript("OnEvent", function()
        if not ktConfirmed then return end
        local cfg = RC.db and RC.db.frostBlastConfig
        if not cfg then return end
        if not cfg.maxHpSamples then cfg.maxHpSamples = {} end
        local maxHp = UnitHealthMax("player")
        if not maxHp or maxHp <= 0 then return end
        if not cfg.peakMaxHp or maxHp > cfg.peakMaxHp then
            cfg.peakMaxHp = maxHp
        end
        table.insert(cfg.maxHpSamples, 1, { t = time(), hp = maxHp })
        while #cfg.maxHpSamples > 30 do table.remove(cfg.maxHpSamples) end
    end)

    IsInKTFight = function()
        local raidName = RC.GetEffectiveRaidName and RC:GetEffectiveRaidName() or nil
        if raidName ~= "Naxxramas" then
            ktConfirmed = false
            return false
        end

        local targetName = UnitName("target")
        if targetName then
            if RC.GetEncounterNameForBoss then
                local enc = RC:GetEncounterNameForBoss(raidName, targetName)
                if enc == "Kel'Thuzad" then
                    ktConfirmed = true
                    return true
                end
            end
            if RC.encounterAddPhases and RC.encounterAddPhases["Kel'Thuzad"] then
                local ktInfo = RC.encounterAddPhases["Kel'Thuzad"]
                if ktInfo.adds then
                    for _, addName in ipairs(ktInfo.adds) do
                        if addName == targetName then
                            ktConfirmed = true
                                    return true
                        end
                    end
                end
                if ktInfo.aliases then
                    for _, alias in ipairs(ktInfo.aliases) do
                        if alias == targetName then
                            ktConfirmed = true
                                    return true
                        end
                    end
                end
            end
            return ktConfirmed and (RC.inCombat or UnitAffectingCombat("player"))
        end

        return ktConfirmed and (RC.inCombat or UnitAffectingCombat("player"))
    end

    local ktCleanupFrame = CreateFrame("Frame")
    ktCleanupFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    ktCleanupFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    ktCleanupFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    ktCleanupFrame:SetScript("OnEvent", function()
        ktConfirmed = false
    end)

    function RC:CheckAndDismissFrostBlastReminder()
        if not self.reminderFrame or not self.reminderFrame:IsShown() then return end
        if not self.activeReminderData or not self.activeReminderData.abilities or #self.activeReminderData.abilities == 0 then return end
        if RC.Profiler then RC.Profiler:StartTiming("FrostBlast") end

        local hasFrostBlast = false
        for _, k in ipairs(self.activeReminderData.abilities) do
            if k == "frostBlast" then hasFrostBlast = true; break end
        end
        if not hasFrostBlast then
            if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
            return
        end

        if not IsInKTFight() then
            if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
            return
        end

        -- 8500 is the Frost Blast survival line: above it the shatter kills you.
        -- Per-boss config overrides it via frostBlast.playerHpAboveValue; the
        -- same literal is repeated as a fallback in every function in this file.
        local threshold = 8500
        local currentRaid = self.GetEffectiveRaidName and self:GetEffectiveRaidName() or nil
        if currentRaid then
            local raidSettings = self:GetActiveRaidProfile(currentRaid)
            if raidSettings and raidSettings.bosses then
                local targetName = UnitName("target")
                if targetName then
                    local encounterName = self:GetEncounterNameForBoss(currentRaid, targetName)
                    if encounterName then
                        local bossConfig = raidSettings.bosses[encounterName]
                        if bossConfig and bossConfig.abilities and bossConfig.abilities.frostBlast then
                            threshold = bossConfig.abilities.frostBlast.playerHpAboveValue or 8500
                        end
                    end
                end
            end
        end

        local playerHP = UnitHealth("player")
        if playerHP <= threshold then
            for i = #self.activeReminderData.abilities, 1, -1 do
                local k = self.activeReminderData.abilities[i]
                if k == "frostBlast" or (type(k) == "string" and k:find("^frostBlastBuff_")) then
                    table.remove(self.activeReminderData.abilities, i)
                end
            end
            local targetGUID = UnitGUID("target")
            if targetGUID and self.spellCastTriggers.usedAbilities[targetGUID] then
                self.spellCastTriggers.usedAbilities[targetGUID]["frostBlast"] = nil
            end
            if #self.activeReminderData.abilities == 0 then
                self:SmartDismissReminder("Frost Blast HP threshold reached")
            else
                self:UpdateReminderWithRemainingAbilities()
            end
            self:DebugPrint("Frost Blast dismissed  -  HP " .. playerHP .. " <= " .. threshold, "trigger")
        end
        if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
    end

    function RC:CheckFrostBlastBuffRemoval()
        if not self.reminderFrame or not self.reminderFrame:IsShown() then return end
        if not self.activeReminderData or not self.activeReminderData.abilities then return end
        if RC.Profiler then RC.Profiler:StartTiming("FrostBlast") end

        if not IsInKTFight() then
            if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
            return
        end

        local hasFB = false
        for _, k in ipairs(self.activeReminderData.abilities) do
            if k == "frostBlast" or (type(k) == "string" and k:find("^frostBlastBuff_")) then
                hasFB = true; break
            end
        end
        if not hasFB then
            if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
            return
        end

        local changed = false
        for i = #self.activeReminderData.abilities, 1, -1 do
            local ab = self.activeReminderData.abilities[i]
            if type(ab) == "string" and ab:find("^frostBlastBuff_") then
                local data = self.abilityData and self.abilityData[ab]
                if data and data.spellId then
                    if not RC.Auras:Buff(data.spellId) then
                        table.remove(self.activeReminderData.abilities, i)
                        changed = true
                        self:DebugPrint("FrostBlast buff removed: " .. (data.name or ab), "trigger")
                    end
                end
            end
        end

        if not changed then
            if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
            return
        end

        local fbRemaining = 0
        for _, ab in ipairs(self.activeReminderData.abilities) do
            if ab == "frostBlast" or (type(ab) == "string" and ab:find("^frostBlastBuff_")) then
                fbRemaining = fbRemaining + 1
            end
        end

        if fbRemaining <= 1 then
            local allAbilities = self.activeReminderData.abilities
            local onlyFB = (#allAbilities == 1 and allAbilities[1] == "frostBlast") or #allAbilities == 0
            if onlyFB then
                local threshold = 8500
                local raidS = self.GetActiveRaidProfile and self:GetActiveRaidProfile("Naxxramas") or nil
                if raidS and raidS.bosses and raidS.bosses["Kel'Thuzad"] and
                   raidS.bosses["Kel'Thuzad"].abilities and raidS.bosses["Kel'Thuzad"].abilities.frostBlast then
                    threshold = raidS.bosses["Kel'Thuzad"].abilities.frostBlast.playerHpAboveValue or 8500
                end
                if UnitHealth("player") <= threshold then
                    self.activeReminderData.abilities = {}
                    if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
                    self:SmartDismissReminder("All frost blast buffs removed and HP ok")
                    return
                end
            end
        end

        if #self.activeReminderData.abilities == 0 then
            if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
            self:SmartDismissReminder("All frost blast buffs removed")
        else
            if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
            self:UpdateReminderWithRemainingAbilities()
        end
    end

    -- The cancellable stamina sources and the flat max HP each one adds at 60.
    -- Only these three are offered; anything else contributing HP has to be
    -- handled by the player.
    local FB_BUFF_META = {
        { key="Flask of the Titans",   spellId=17626, hp=1200, icon="Interface\\Icons\\INV_Alchemy_ElunaPotion_A",    name="Flask of the Titans"   },
        { key="Spirit of Zanza",       spellId=24381, hp=500,  icon="Interface\\Icons\\Spell_Nature_StrengthOfEarth", name="Spirit of Zanza"       },
        { key="Power Word: Fortitude", spellId=21562, hp=540,  icon="Interface\\Icons\\Spell_Holy_WordFortitude",     name="Power Word: Fortitude" },
    }

    function RC:BuildFrostBlastReminderAbilities()
        local abilities = {"frostBlast"}

        local raidS  = self.GetActiveRaidProfile and self:GetActiveRaidProfile("Naxxramas") or nil
        local thresh = 8500
        if raidS and raidS.bosses and raidS.bosses["Kel'Thuzad"] and
           raidS.bosses["Kel'Thuzad"].abilities and raidS.bosses["Kel'Thuzad"].abilities.frostBlast then
            thresh = raidS.bosses["Kel'Thuzad"].abilities.frostBlast.playerHpAboveValue or 8500
        end

        local maxHP = UnitHealthMax("player")
        local bestProj = maxHP

        if maxHP > 0 then
            local present = {}
            for _, meta in ipairs(FB_BUFF_META) do
                if RC.Auras:Buff(meta.spellId) then table.insert(present, meta) end
            end

            -- 500 HP of slack over the threshold still counts as safe, so a
            -- cancel that would only buy that much is not worth suggesting.
            local ACCEPTABLE_OVER = 500
            local ceiling = thresh + ACCEPTABLE_OVER
            local n = #present
            local bestMetas = {}

            local bestInZone, bestInZoneMetas = nil, nil
            local bestOver,  bestOverMetas  = nil, nil

            -- Brute force every subset of the buffs actually present (2^n, n <= 3)
            -- and keep the highest projection still under the ceiling, so the
            -- player cancels as little as possible. If nothing fits, take the
            -- lowest projection above it and say so in the message.
            for mask = 0, (2^n - 1) do
                local proj = maxHP
                local metas = {}
                for i = 1, n do
                    if math.floor(mask / (2^(i-1))) % 2 == 1 then
                        proj = proj - present[i].hp
                        table.insert(metas, present[i])
                    end
                end
                if proj <= ceiling then
                    if not bestInZone or proj > bestInZone then
                        bestInZone       = proj
                        bestInZoneMetas  = metas
                    end
                else
                    if not bestOver or proj < bestOver then
                        bestOver      = proj
                        bestOverMetas = metas
                    end
                end
            end

            if bestInZone then
                bestMetas = bestInZoneMetas
                bestProj  = bestInZone
            else
                bestMetas = bestOverMetas or {}
                bestProj  = bestOver or maxHP
            end

            for i, meta in ipairs(bestMetas) do
                if not self.abilityData then self.abilityData = {} end
                -- Synthetic ability keys, index-based so they are reused between
                -- rebuilds. CheckFrostBlastBuffRemoval matches on this prefix.
                local abilityKey = "frostBlastBuff_" .. i
                self.abilityData[abilityKey] = {
                    name             = meta.name,
                    icon             = meta.icon,
                    description      = RCL["Cancel this buff"],
                    spellId          = meta.spellId,
                    cooldown         = 0,
                    duration         = 0,
                    isFrostBlastBuff = true,
                }
                table.insert(abilities, abilityKey)
            end
        end

        local msg
        if bestProj <= thresh + 500 then
            msg = string.format(RCL["Max HP %d (target < %d)"], bestProj, thresh)
        else
            msg = string.format(RCL["Drop stam consumes - max HP %d, need < %d"], bestProj, thresh)
        end

        return abilities, msg, thresh
    end

    local FROST_BLAST_DEBUFF_ID = 27808

    function RC:CheckFrostBlastDebuff()
        if not self.db or not self.db.frostBlastConfig then return end
        if not self.db.frostBlastConfig.alsoShowWhenDebuffed then return end
        if RC.Profiler then RC.Profiler:StartTiming("FrostBlast") end

        if not IsInKTFight() then
            if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
            return
        end

        local hasDebuff = RC.Auras:Debuff(FROST_BLAST_DEBUFF_ID) ~= nil

        if hasDebuff then
            if self.activeReminderData and self.activeReminderData.abilities then
                for _, k in ipairs(self.activeReminderData.abilities) do
                    if k == "frostBlast" then
                        if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
                        return
                    end
                end
            end

            self:DebugPrint("Frost Blast debuff detected  -  showing reminder", "trigger")
            local fbAbilities, fbMsg = self:BuildFrostBlastReminderAbilities()
            if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
            -- 3600s duration = effectively no auto-dismiss; this reminder is
            -- cleared only by HP dropping below the threshold, the buffs coming
            -- off, or leaving KT combat.
            self:ShowReminder(fbMsg, fbAbilities, 3600)
        else
            if self.activeReminderData and self.activeReminderData.abilities then
                for i = #self.activeReminderData.abilities, 1, -1 do
                    if self.activeReminderData.abilities[i] == "frostBlast" then
                        local cfg2 = nil
                        local raidSettings = self.GetActiveRaidProfile and self:GetActiveRaidProfile("Naxxramas") or nil
                        if raidSettings and raidSettings.bosses and raidSettings.bosses["Kel'Thuzad"] then
                            cfg2 = raidSettings.bosses["Kel'Thuzad"].abilities and raidSettings.bosses["Kel'Thuzad"].abilities.frostBlast
                        end
                        local threshold = cfg2 and cfg2.playerHpAboveValue or 8500
                        if UnitHealth("player") <= threshold then
                            for j = #self.activeReminderData.abilities, 1, -1 do
                                local ak = self.activeReminderData.abilities[j]
                                if ak == "frostBlast" or (type(ak) == "string" and ak:find("^frostBlastBuff_")) then
                                    table.remove(self.activeReminderData.abilities, j)
                                end
                            end
                            if #self.activeReminderData.abilities == 0 then
                                self:SmartDismissReminder("Frost Blast debuff dropped and HP ok")
                            else
                                self:UpdateReminderWithRemainingAbilities()
                            end
                        end
                        break
                    end
                end
            end
        end
        if RC.Profiler then RC.Profiler:StopTiming("FrostBlast") end
    end

_tes.IsInKTFight = IsInKTFight
