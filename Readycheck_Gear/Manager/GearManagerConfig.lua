------------------------------------------------------------------------
-- Readycheck - Gear Manager Config Defaults
-- Ensures the gear manager's saved-variable tables exist before anything
-- else touches RC.db.gear*. Runs once, 2s after load; GM_Runtime.lua's
-- own Initialize() performs the same ensures again for its own timing.
------------------------------------------------------------------------
C_Timer.After(2, function()
    local RC = _G.Readycheck
    if not RC or not RC.db then return end

    if not RC.db.gearButtons then
        RC.db.gearButtons = {}
    end
    if not RC.db.gearButtonPositions then
        RC.db.gearButtonPositions = {}
    end
    if not RC.db.gearPinnedButtons then
        RC.db.gearPinnedButtons = {}
    end
    if not RC.db.gearManager then
        RC.db.gearManager = {}
    end
    if not RC.db.gearSets then
        RC.db.gearSets = {}
    end
end)
