------------------------------------------------------------------------
-- Readycheck - Trigger Engine Equip Reminders
-- Config-driven reminders that bypass the trigger loop entirely: what to
-- equip after a boss dies, and what to drink before pulling one.
-- Sources: abilities[key].equipAfterDeath, and bossConfig.postDeathConsumables
-- where the value is "death" (show on kill) or "target" (show on targeting).
-- Both render through synthetic ability keys equipReminder and
-- preTargetConsumable, which TE_Triggers carries across ticks.
-- Loads last of the TE_* files and wraps EndFightTracking from the TTK system.
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
    function RC:CheckBossDeathEquipReminders(bossName, raidName)
        if not raidName then
            raidName = self:GetEffectiveRaidName()
        end
        if not raidName or not bossName then return end

        -- 5s dedupe per boss: the EndFightTracking hook, ENCOUNTER_END and the
        -- unit-died path can all arrive for the same kill.
        local now = GetTime()
        if self.lastBossDeathReminder.bossName == bossName and
           (now - self.lastBossDeathReminder.timestamp) < 5 then
            return
        end

        local raidSettings = self:GetActiveRaidProfile(raidName)
        if not raidSettings or not raidSettings.bosses then return end

        local bossConfig = raidSettings.bosses[bossName]
        if not bossConfig then
            local encounterName = self:GetEncounterNameForBoss(raidName, bossName)
            if encounterName then
                bossConfig = raidSettings.bosses[encounterName]
            end
        end

        if not bossConfig or not bossConfig.abilities then return end

        local equipReminders = {}
        for abilityKey, abilityConfig in pairs(bossConfig.abilities) do
            if abilityConfig.equipAfterDeath then
                local abilityData = self.abilityData and self.abilityData[abilityKey]
                if abilityData then
                    table.insert(equipReminders, {
                        key = abilityKey,
                        name = abilityData.name,
                        icon = abilityData.icon,
                        itemId = abilityData.itemId
                    })
                end
            end
        end

        -- mode is "death", "target" or boolean true; true is death mode.
        -- Items the player is not carrying are dropped from the reminder.
        if bossConfig.postDeathConsumables then
            for itemId, mode in pairs(bossConfig.postDeathConsumables) do
                local isDeathMode = (mode == "death") or (mode == true)
                if isDeathMode then
                    -- a target dummy or a merged row counts whichever of
                    -- its items is in the bags, and names that one
                    local row = RC:ConsumableRow(itemId)
                    local carried = row and RC:CarriedVersion(itemId, row)
                    if carried then
                        local name, _, _, _, _, _, _, _, _, tex = GetItemInfo(carried)
                        table.insert(equipReminders, {
                            key = "postDeath_" .. tostring(itemId),
                            name = name or RC:ItemLabel(itemId, row),
                            icon = tex or RC:ItemLabelIcon(itemId, row),
                            itemId = carried
                        })
                    end
                end
            end
        end

        if #equipReminders > 0 then
            self.lastBossDeathReminder.bossName = bossName
            self.lastBossDeathReminder.timestamp = now
            self:ShowBossDeathEquipReminder(bossName, equipReminders)
        end
    end

    function RC:CheckBossTargetConsumableReminders(encounterName, raidName)
        if not raidName or not encounterName then return end
        local raidSettings = self:GetActiveRaidProfile(raidName)
        if not raidSettings or not raidSettings.bosses then return end
        local bossConfig = raidSettings.bosses[encounterName]
        if not bossConfig or not bossConfig.postDeathConsumables then return end

        local targetReminders = {}
        for itemId, mode in pairs(bossConfig.postDeathConsumables) do
            if mode == "target" then
                local row = RC:ConsumableRow(itemId)
                local carried = row and RC:CarriedVersion(itemId, row)
                if carried then
                    local name, _, _, _, _, _, _, _, _, tex = GetItemInfo(carried)
                    table.insert(targetReminders, {
                        name = name or RC:ItemLabel(itemId, row),
                        icon = tex or RC:ItemLabelIcon(itemId, row),
                    })
                end
            end
        end

        if #targetReminders == 0 then return end

        local itemNames, icons = {}, {}
        for _, r in ipairs(targetReminders) do
            table.insert(itemNames, r.name)
            table.insert(icons, r.icon)
        end

        -- Synthetic ability record so the reminder frame has a name and icon to
        -- draw. Listed in TE_Triggers' PERSISTENT_REMINDER_KEYS, so it survives
        -- trigger ticks and is torn down by PLAYER_REGEN_DISABLED.
        if not self.abilityData then self.abilityData = {} end
        self.abilityData["preTargetConsumable"] = {
            name = "Use before pull: " .. table.concat(itemNames, ", "),
            icon = icons[1],
        }
        local reminderText = "Use before pull: " .. table.concat(itemNames, ", ")
        self:DebugPrint("Boss target consumable reminder: " .. reminderText, "trigger")
        if self.ShowReminder then
            self:ShowReminder(reminderText, {"preTargetConsumable"})
        end
    end

    function RC:ShowBossDeathEquipReminder(bossName, equipReminders)
        if not equipReminders or #equipReminders == 0 then return end

        local itemNames = {}
        local icons = {}
        for _, reminder in ipairs(equipReminders) do
            table.insert(itemNames, reminder.name)
            table.insert(icons, reminder.icon)
        end

        local reminderText = "Equip: " .. table.concat(itemNames, ", ")
        self:DebugPrint("Boss death equip reminder: " .. reminderText, "trigger")

        if not self.ShowReminder then
            self:Print("|cFFFFD700" .. bossName .. RCL[" died!|r "] .. reminderText)
            return
        end

        if not self.abilityData then self.abilityData = {} end
        self.abilityData["equipReminder"] = {
            name = reminderText,
            icon = icons[1] or "Interface\\Icons\\Spell_Magic_PolymorphChicken",
        }

        self:ShowReminder(reminderText, {"equipReminder"})

        if self.db.ttsEnabled and self.SpeakTTS then
            local ttsText = "equip " .. table.concat(itemNames, " and ")
            self:SpeakTTS(ttsText, false)
        end

    end

    -- Wraps the TTK system's EndFightTracking, which is already defined because
    -- Systems\TTK loads before Systems\Trigger. The 0.5s delay lets the fight
    -- record settle before the death reminder reads the boss config.
    local originalEndFightTracking = RC.EndFightTracking
    if originalEndFightTracking then
        RC.EndFightTracking = function(self, targetData, raidName, encounterName)
            if originalEndFightTracking then
                originalEndFightTracking(self, targetData, raidName, encounterName)
            end

            local bossName = encounterName or (targetData and targetData.name)
            if bossName then
                C_Timer.After(0.5, function()
                    RC:CheckBossDeathEquipReminders(bossName, raidName)
                end)
            end
        end
    end

    RC:DebugPrint("Trigger Engine loaded - ADD PHASE CHECK + BUFF DISMISSAL + GEAR SWAP RETRY + EQUIP REMINDER", "system")
