------------------------------------------------------------------------
-- Readycheck - hidden values (WoW Forever)
-- Forever hands back many reads as "secret" values - in a fight even
-- your own power, attack power, attack speed, stats, cooldowns and casts
-- - which may not be used in maths, compared or used as a table key, and
-- a secret boolean may not even be tested. These two let a caller check
-- before it does any of that. issecretvalue does not exist on Classic Era
-- or TBC, so there both are plain pass-throughs and nothing changes.
--   RC.Hidden(...)                     any of the values secret
--   RC.PlainCD(start, duration, enable, ...)
--                                      a cooldown read as it is, or
--                                      0, 0, 1 (ready) when any of it is
--                                      hidden: Readycheck.PlainCD(
--                                      GetInventoryItemCooldown("player", slot))
--   RC.SafeGUID(unit) / RC.SafeName(unit)  nil while hidden
-- Loaded right after Core_Boot (which makes the Readycheck table) and
-- before every file that calls them.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local issecret = issecretvalue

function RC.Hidden(...)
    if issecret == nil then return false end
    for i = 1, select("#", ...) do
        if issecret((select(i, ...))) then return true end
    end
    return false
end

-- An enemy's GUID and name come back hidden in a fight on Forever: these
-- answer nil then (no keying, comparing or splitting a hidden one). On the
-- other clients exactly UnitGUID / UnitName, read at call time.
function RC.SafeGUID(unit)
    local g = UnitGUID(unit)
    if issecret ~= nil and issecret(g) then return nil end
    return g
end

function RC.SafeName(unit)
    local n, realm = UnitName(unit)
    if issecret ~= nil and (issecret(n) or issecret(realm)) then return nil end
    return n, realm
end

-- The spell whose cooldown is the global cooldown: Blizzard's dummy 61304;
-- on WoW Forever 29515 when that client does not know 61304. Always 61304
-- on the other clients.
local gcdSpell
function RC.GCDSpell()
    if gcdSpell then return gcdSpell end
    local id = 61304
    if _G.READYCHECK_IS_FOREVER and C_Spell and C_Spell.GetSpellInfo then
        local ok, info = pcall(C_Spell.GetSpellInfo, 61304)
        if ok and not info then id = 29515 end
        if not ok then return id end
    end
    gcdSpell = id
    return id
end

function RC.PlainCD(start, duration, enable, ...)
    if issecret ~= nil and (issecret(start) or issecret(duration) or issecret(enable)) then return 0, 0, 1 end
    return start, duration, enable, ...
end
