------------------------------------------------------------------------
-- Readycheck - Aura Index
-- One shared read of the player's own buffs and debuffs.
--
-- About a dozen features used to walk all 40 buff slots themselves - the
-- consumables bar, the buff cap counter, the trigger engine, trinket
-- swaps, the gear manager, world buff sync, custom reminders and more -
-- most of them on every aura change. In combat each Flurry, Enrage or
-- weapon proc set off five or six full rescans of the same list.
--
-- Now UNIT_AURA (through the shared dispatcher in Core_Events) only marks
-- the list stale; the first reader after that reads it once, for
-- everyone, and every later reader gets the same answer until the next
-- aura change. Entries are rebuilt fresh on each read, so a reader may
-- keep the tables it was given, but must not change them.
--
--   RC.Auras:Buffs()             -> array of buff entries, slot order
--   RC.Auras:Debuffs()           -> array of debuff entries, slot order
--   RC.Auras:Buff(spellId)       -> the first buff with that id, or nil
--   RC.Auras:BuffNamed(name)     -> the first buff with that exact name
--   RC.Auras:Debuff(spellId)     -> the first debuff with that id
--   RC.Auras:DebuffNamed(name)   -> the first debuff with that exact name
--   RC.Auras:Version()           -> moves on every aura change
--   RC.Auras:Invalidate()        -> the dispatcher calls this on UNIT_AURA
-- Entry: { name, icon, count, dispelType, duration, expirationTime,
--          source, spellId, index, instance }   (instance: auraInstanceID,
--          when the client reports one)
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local C = C_UnitAuras
local GetBuffData   = C and C.GetBuffDataByIndex
local GetDebuffData = C and C.GetDebuffDataByIndex
local UnitBuff, UnitDebuff = UnitBuff, UnitDebuff

local A = {}
RC.Auras = A

local MAX_AURAS = 40
local dirty, version = true, 0
local buffs, debuffs = {}, {}
local buffById, buffByName, debuffById, debuffByName = {}, {}, {}, {}

-- WoW Forever: an aura read in combat can be "secret" (not to be compared
-- or used as a key); treated as the end of the list, like the shims do.
local issecret = issecretvalue
local function FromData(a, i)
    if issecret ~= nil and (issecret(a.name) or issecret(a.spellId)) then return nil end
    return {
        name = a.name, icon = a.icon, count = a.applications or a.charges or 0,
        dispelType = a.dispelName, duration = a.duration or 0,
        expirationTime = a.expirationTime or 0, source = a.sourceUnit,
        spellId = a.spellId, index = i, instance = a.auraInstanceID,
    }
end

local function FromUnitAura(i, name, icon, count, dispelType, duration, expirationTime, source, _, _, spellId)
    if not name then return nil end
    return {
        name = name, icon = icon, count = count or 0, dispelType = dispelType,
        duration = duration or 0, expirationTime = expirationTime or 0,
        source = source, spellId = spellId, index = i,
    }
end

local function Read(getData, unitAura)
    local list, byId, byName = {}, {}, {}
    for i = 1, MAX_AURAS do
        local e
        if getData then
            local a = getData("player", i)
            e = a and FromData(a, i)
        else
            e = FromUnitAura(i, unitAura("player", i))
        end
        if not e then break end
        list[i] = e
        if e.spellId and not byId[e.spellId] then byId[e.spellId] = e end
        if e.name and not byName[e.name] then byName[e.name] = e end
    end
    return list, byId, byName
end

local function Refresh()
    if not dirty then return end
    dirty = false
    version = version + 1
    buffs, buffById, buffByName = Read(GetBuffData, UnitBuff)
    debuffs, debuffById, debuffByName = Read(GetDebuffData, UnitDebuff)
end

function A:Invalidate() dirty = true end
function A:Version() Refresh() return version end

function A:Buffs() Refresh() return buffs end
function A:Debuffs() Refresh() return debuffs end

function A:Buff(spellId)
    if not spellId then return nil end
    Refresh()
    return buffById[spellId]
end

function A:BuffNamed(name)
    if not name then return nil end
    Refresh()
    return buffByName[name]
end

function A:Debuff(spellId)
    if not spellId then return nil end
    Refresh()
    return debuffById[spellId]
end

function A:DebuffNamed(name)
    if not name then return nil end
    Refresh()
    return debuffByName[name]
end

-- A loading screen can swap the whole aura list; read it afresh after.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function() dirty = true end)
