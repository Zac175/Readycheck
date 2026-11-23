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

-- A COOLDOWN THAT BEGAN BEFORE THIS PC STARTED (2026-11-22). The game
-- keeps a cooldown's start in milliseconds since the PC started, in a 32
-- bit number. One that began before that - used, then the PC restarted; or
-- started on another computer - comes back from every cooldown read one
-- turn of that number too late: 2^32 ms (49.7 days) in the future
-- (WoWUIBugs #47). Counted with, that is weeks left (and "C_Timer.After
-- duration is too large", 2026-10-31); on a Cooldown it is a greyed full
-- swipe. With the turn taken off the start is before zero, which every
-- "start > 0" test reads as no cooldown - so the corrected reading starts
-- just after zero and ENDS WHEN THE COOLDOWN REALLY ENDS: the time left
-- and "is it running" are right everywhere.
--   RC.CooldownFix(start, duration, ...) -> start, duration, ...
-- Ordinary readings and hidden values come back exactly as given.
local CLOCK_TURN = 2 ^ 32 / 1000
local CLOCK_ZERO = 0.001
function RC.CooldownFix(start, duration, ...)
    if issecret ~= nil and (issecret(start) or issecret(duration)) then return start, duration, ... end
    if type(start) ~= "number" or type(duration) ~= "number" then return start, duration, ... end
    local now = GetTime()
    if start <= now + 1 or duration <= 0 then return start, duration, ... end
    local began = start - CLOCK_TURN
    if began > now then return start, duration, ... end       -- (not this fault: left alone)
    local ends = began + duration
    if ends <= now then return 0, 0, ... end                   -- (over already)
    if began > 0 then return began, duration, ... end
    return CLOCK_ZERO, ends - CLOCK_ZERO, ...
end

function RC.PlainCD(start, duration, enable, ...)
    if issecret ~= nil and (issecret(start) or issecret(duration) or issecret(enable)) then return 0, 0, 1 end
    return RC.CooldownFix(start, duration, enable, ...)
end

-- The spell cooldown read every file takes in place of the game's own
-- (`local GetSpellCooldown = Readycheck.SpellCooldown or ...`): the same
-- answers, with a start from before this PC started put right.
do
    local raw = GetSpellCooldown or (RC.Compat and RC.Compat.GetSpellCooldown)
    if raw then
        function RC.SpellCooldown(a, b) return RC.CooldownFix(raw(a, b)) end
    end
end
