------------------------------------------------------------------------
-- Readycheck - Naxxramas Duplicate Mob Handler
-- Some Naxxramas trash names appear in more than one wing's
-- trashSections; a toggle set on that name in one wing must propagate
-- to every other wing listing it, or those quarters stay on stale config.
-- GetQuartersForNaxxMob is what finds "every other wing".
------------------------------------------------------------------------
local function InitializeNaxxDuplicateHandler()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeNaxxDuplicateHandler)
        return
    end

    if not RC.raidData then
        C_Timer.After(0.1, InitializeNaxxDuplicateHandler)
        return
    end

    -- Exact names that occur in 2+ wings. Plagued Gargoyle spans the
    -- Spider and Military wings; Stoneskin Gargoyle is Plague-wing only
    -- and is a different mob, so it is deliberately not in this list.
    RC.naxxDuplicateMobs = {
        ["Infectious Ghoul"] = true,
        ["Plagued Gargoyle"] = true,
        ["Shade of Naxxramas"] = true,
        ["Naxxramas Acolyte"] = true
    }

    function RC:IsNaxxDuplicateMob(mobName)
        return self.naxxDuplicateMobs[mobName] == true
    end

    function RC:GetQuartersForNaxxMob(mobName)
        if not self.raidData["Naxxramas"] or not self.raidData["Naxxramas"].trashSections then
            return {}
        end

        local quarters = {}
        for quarterName, mobs in pairs(self.raidData["Naxxramas"].trashSections) do
            for _, mob in ipairs(mobs) do
                if mob == mobName then
                    table.insert(quarters, quarterName)
                    break
                end
            end
        end

        return quarters
    end
end

InitializeNaxxDuplicateHandler()
