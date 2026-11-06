------------------------------------------------------------------------
-- Readycheck - Boon of Blackfathom Reminder
-- Surfaces the shared reminder popup while the player holds the Boon
-- buff, gated to raid instances and out of combat lockdown.
-- shownForThisBoon rearms only when the buff itself is lost and
-- reacquired, not on every target/zone change while still buffed.
------------------------------------------------------------------------
local function InitializeBoonReminder()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializeBoonReminder) return end
    if not RC.db then C_Timer.After(0.2, InitializeBoonReminder) return end
    -- Chronoboon is Classic Era only (Core_Flavor)
    if RC.FeatureOn and not RC:FeatureOn("chronoboon") then return end

    -- Matched by spellId, not buff name, so locale/rank text differences
    -- between the two known Boon variants can't cause a missed match.
    local BOON_STORED_SPELL_IDS = {
        [349981] = true,
        [349977] = true,
    }

    local IsInInstance  = IsInInstance
    local IsInRaid      = IsInRaid
    local UnitExists    = UnitExists
    local UnitIsDead    = UnitIsDead
    local UnitCanAttack = UnitCanAttack

    RC.boonReminder = RC.boonReminder or {
        hasBoon  = false,
        testMode = false,
        frame    = nil,
        shownForThisBoon = false,
    }

    local function EnsureDB()
        if not RC.db.boonReminder then RC.db.boonReminder = {} end
        local db = RC.db.boonReminder

        if db.enabled == nil then
            db.enabled = false
        end
        if not db.defaultsMigratedV2 then
            db.enabled = false
            db.defaultsMigratedV2 = true
        end

        if db.mode      == nil then db.mode      = "boss"  end
        if db.playSound == nil then db.playSound = false   end
        if db.soundKey  == nil then db.soundKey  = "WR: Warning" end
        if not db.disabledBosses then
            db.disabledBosses = {
                ["Instructor Razuvious"] = true,
                ["Gothik the Harvester"] = true,
            }
        end
    end

    local function PlayerHasBoon()
        for _, a in ipairs(RC.Auras:Buffs()) do
            if a.spellId and BOON_STORED_SPELL_IDS[a.spellId] then return true end
        end
        return false
    end

    local function IsInRaidZone()
        local inInstance, instanceType = IsInInstance()
        return (inInstance and instanceType == "raid") or IsInRaid()
    end

    local function ShouldShowBoon()
        if not RC.db or not RC.db.boonReminder then return false end
        local db = RC.db.boonReminder
        if not db.enabled then return false end
        if not IsInRaidZone() then return false end
        if not RC.boonReminder.hasBoon then return false end

        -- Pre-pull reminder only: PLAYER_REGEN_DISABLED below force-clears
        -- it, so it never needs to persist once combat actually starts.
        if InCombatLockdown() then return false end

        if RC.boonReminder.shownForThisBoon then return false end

        local mode = db.mode or "boss"
        if mode == "always_raid" then return true end

        if not UnitExists("target") or UnitIsDead("target") or not UnitCanAttack("player", "target") then
            return false
        end

        local triggerTarget = RC.GetCurrentTargetData and RC:GetCurrentTargetData() or nil
        local isBoss = (triggerTarget and triggerTarget.encounterType == "boss")
                    or (UnitClassification("target") == "worldboss")
                    or (UnitLevel("target") == -1)

        if isBoss then
            local disabledBosses = db.disabledBosses
            if disabledBosses then
                local targetName = UnitName("target")
                local encounterName = targetName
                if RC.GetEncounterNameForBoss and RC.GetEffectiveRaidName then
                    local raidName = RC:GetEffectiveRaidName()
                    if raidName then
                        encounterName = RC:GetEncounterNameForBoss(raidName, targetName) or targetName
                    end
                end
                if disabledBosses[encounterName] or disabledBosses[targetName] then
                    return false
                end
            end
        end

        if mode == "boss"  then return isBoss == true  end
        if mode == "trash" then return isBoss == false  end
        if mode == "both"  then return true             end
        return false
    end

    local function IsBoonActiveInReminder()
        if not RC.activeReminderData or not RC.activeReminderData.abilities then return false end
        for _, k in ipairs(RC.activeReminderData.abilities) do
            if k == "boon" then return true end
        end
        return false
    end

    local function ShowBoonInReminder()
        if RC.Profiler then RC.Profiler:StartTiming("BoonReminder") end

        if RC.activeReminderData and RC.activeReminderData.abilities
           and #RC.activeReminderData.abilities > 0 then
            local already = false
            for _, k in ipairs(RC.activeReminderData.abilities) do
                if k == "boon" then already = true; break end
            end
            if not already then
                if RC.ShowReminder then
                    local combined = {}
                    for _, k in ipairs(RC.activeReminderData.abilities) do
                        combined[#combined + 1] = k
                    end
                    combined[#combined + 1] = "boon"
                    RC:ShowReminder(
                        RC.activeReminderData.message or "unboon",
                        combined, 0, true)
                end
            end
        else
            if RC.ShowReminder then
                RC:ShowReminder("unboon", {"boon"}, 0, true)
            end
        end

        if IsBoonActiveInReminder() then
            RC.boonReminder.shownForThisBoon = true
        end

        if RC.Profiler then RC.Profiler:StopTiming("BoonReminder") end
    end

    local function RemoveBoonFromReminder()
        if not RC.activeReminderData or not RC.activeReminderData.abilities then return end
        local changed = false
        for i = #RC.activeReminderData.abilities, 1, -1 do
            if RC.activeReminderData.abilities[i] == "boon" then
                table.remove(RC.activeReminderData.abilities, i)
                changed = true
            end
        end
        if changed then
            RC.boonReminder.shownForThisBoon = false
            if #RC.activeReminderData.abilities == 0 then
                if RC.SmartDismissReminder then
                    RC:SmartDismissReminder("Boon conditions no longer met")
                end
            elseif RC.UpdateReminderWithRemainingAbilities then
                RC:UpdateReminderWithRemainingAbilities()
            end
            RC:DebugPrint("Boon removed from reminder", "trigger")
        end
    end

    function RC:UpdateBoonReminder()
        if not self.db or not self.db.boonReminder then return end

        if self.boonReminder.testMode then
            ShowBoonInReminder()
            return
        end

        if not self.db.boonReminder.enabled then
            RemoveBoonFromReminder()
            return
        end

        if ShouldShowBoon() then
            if not IsBoonActiveInReminder() then
                ShowBoonInReminder()
            end
        else
            RemoveBoonFromReminder()
        end
    end

    function RC:UpdateBoonReminderAppearance()
        self:UpdateBoonReminder()
    end

    -- Auras come through the shared throttled callback, woken only by the
    -- stored-boon auras themselves.
    local boonWatch = {}
    for id in pairs(BOON_STORED_SPELL_IDS) do boonWatch[#boonWatch + 1] = id end
    RC:RegisterUnitAuraCallback("BoonReminder", 0.25, function()
        if not RC.db or not RC.db.boonReminder then return end
        if not RC.db.boonReminder.enabled then
            RemoveBoonFromReminder()
            return
        end
        local had = RC.boonReminder.hasBoon
        RC.boonReminder.hasBoon = PlayerHasBoon()
        if had and not RC.boonReminder.hasBoon then
            RC.boonReminder.shownForThisBoon = false
            RemoveBoonFromReminder()
            return
        end
        if RC.boonReminder.hasBoon ~= had then
            RC:UpdateBoonReminder()
        end
    end, boonWatch)

    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

    eventFrame:SetScript("OnEvent", function(self, event, ...)
        if not RC.db or not RC.db.boonReminder then return end
        if not RC.db.boonReminder.enabled then
            RemoveBoonFromReminder()
            return
        end

        if event == "PLAYER_TARGET_CHANGED" then
            if not RC.boonReminder.hasBoon and not IsBoonActiveInReminder() then return end
            local mode = RC.db.boonReminder.mode or "boss"
            if mode ~= "always_raid" then
                RC:UpdateBoonReminder()
            end

        elseif event == "PLAYER_REGEN_DISABLED" then
            RemoveBoonFromReminder()

        elseif event == "PLAYER_REGEN_ENABLED" then
            RC:UpdateBoonReminder()

        elseif event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
            C_Timer.After(2, function()
                if not RC.db or not RC.db.boonReminder then return end
                local had = RC.boonReminder.hasBoon
                RC.boonReminder.hasBoon = PlayerHasBoon()
                if had and not RC.boonReminder.hasBoon then
                    RC.boonReminder.shownForThisBoon = false
                end
                RC:UpdateBoonReminder()
            end)
        end
    end)

    EnsureDB()

    C_Timer.After(2, function()
        if RC.db and RC.db.boonReminder then
            RC.boonReminder.hasBoon = PlayerHasBoon()
            RC:UpdateBoonReminder()
        end
    end)

    RC:DebugPrint("BoonReminder module loaded (normal reminder popup)", "system")
end

C_Timer.After(0.5, InitializeBoonReminder)
