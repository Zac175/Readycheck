------------------------------------------------------------------------
-- Readycheck - Settings Core Data
-- Owns RC.triggerTypes: trigger-id -> display-label map consumed by the
-- reminder/trigger dropdown elsewhere in the settings UI. Loads via the
-- same C_Timer retry-until-RC-exists pattern used across UI/ files.
------------------------------------------------------------------------
local function InitializeConfigCore()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeConfigCore)
        return
    end

    RC.triggerTypes = {
        hp_percent = "Target HP %",
        ttk = "Time to Kill",
        player_hp = "Player HP %",
        player_hp_above = "Player HP Above (raw)",
        combat_start = "Combat Start Timer",
        encounter_start = "Encounter Start (boss engaged)",
        encounter_end = "Encounter End (boss died)",
        rage_threshold = "Rage Level",
        buff_remaining = "Buff Time Remaining",
        debuff_present = "When Debuffed",
        ability_ready = "When Ability Ready"
    }

    RC:DebugPrint("Configuration core loaded", "config")
end

InitializeConfigCore()
