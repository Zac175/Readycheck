------------------------------------------------------------------------
-- Readycheck - CVar record
-- The game settings Readycheck changes that outlive it, and what puts them
-- back. Every console variable Readycheck writes goes through RC.CVar: the
-- first write records the value the player had, every write records the
-- value Readycheck left and which feature wrote it, and the value goes back
-- when that feature is off, or when Readycheck is uninstalled.
--
--   RC.CVar.Set(name, value, owner)      SetCVar, recorded
--   RC.CVar.Get(name)                    GetCVar, nil when unknown
--   RC.CVar.Hold(name, value, owner)     a value borrowed for a while
--   RC.CVar.Release(name, owner)         ...and handed back
--   RC.CVar.RestoreOwner(owner)          a feature turned off: its CVars go back
--   RC.CVar.RestoreAll()                 everything Readycheck changed goes back
--   RC.CVar.Uninstall()                  RestoreAll, every Readycheck addon off
--                                        for every character; the caller reloads
--   RC.CVar.OwnerCheck(owner, fn)        fn() -> true while that feature is off
--   RC.CVar.LoginPass()                  the CVars of owners that are off go back
--                                        (RC:OnEnable calls RC.CVar.AtLogin, which
--                                        runs it a moment later, only when the
--                                        record holds something)
--   RC.CVar.Record()                     the record (tests, diagnostics)
--
-- OWNERS are short strings naming the feature ("targetrange", "profiler",
-- the setup's "setup"). A feature that writes CVars registers OwnerCheck so
-- the login pass knows when it is off; an owner with no check is never off.
--
-- THE RULES: a CVar goes back only while it still holds Readycheck's value
-- (one the player changed since is theirs and stays); the value from before
-- is trusted only on an account that started with this system (a fresh
-- install, or since an Uninstall), otherwise the game's default is used;
-- per-character CVars are recorded per character (by GUID), the rest for
-- the account. A HOLD keeps what the record held before it, so the value
-- handed back on Release is never mistaken for one of Readycheck's.
--
-- Record (account-wide, never exported or synced):
--   ReadycheckDB.account.cvarRecord = { fresh, cvar = { [lowername] =
--     { b = before, a = ours, o = owner } }, held = { [lowername] = { e, v, o } },
--     chars = { [GUID] = { cvar, held } } }
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local pairs, type, tostring, pcall = pairs, type, tostring, pcall

local CVar = {}
local uninstalled = false
local checks = {}

local function GetFn() return (C_CVar and C_CVar.GetCVar) or _G.GetCVar end
local function SetFn() return (C_CVar and C_CVar.SetCVar) or _G.SetCVar end

local function Read(name)
    local f = GetFn()
    if not f then return nil end
    local ok, v = pcall(f, name)
    if ok and v ~= nil then return tostring(v) end
    return nil
end
CVar.Get = Read

local function Write(name, value)
    local f = SetFn()
    if not f then return false end
    local ok, res = pcall(f, name, value)
    if not ok then return false end
    return res ~= false
end

local function Str(value)
    if type(value) == "boolean" then return value and "1" or "0" end
    if value == nil then return nil end
    return tostring(value)
end

local function Default(name)
    if C_CVar and C_CVar.GetCVarDefault then
        local ok, v = pcall(C_CVar.GetCVarDefault, name)
        if ok and v ~= nil then return tostring(v) end
    end
    return nil
end

local function PerCharacter(name)
    if C_CVar and C_CVar.GetCVarInfo then
        local ok, _, _, _, perChar = pcall(C_CVar.GetCVarInfo, name)
        if ok then return perChar and true or false end
    end
    return false
end

------------------------------------------------------------------------
-- The record
------------------------------------------------------------------------
local function Account()
    if type(ReadycheckDB) ~= "table" then return nil end
    if type(ReadycheckDB.account) ~= "table" then ReadycheckDB.account = {} end
    return ReadycheckDB.account
end

local function Record(peek)
    local acct = Account()
    if not acct then return nil end
    local r = acct.cvarRecord
    if type(r) ~= "table" then
        if peek then return nil end
        -- a fresh install (Core_Runtime stamps the tour's "fresh") can
        -- trust what it writes down; an older account cannot
        local t = ReadycheckDB.tutorial
        r = { fresh = type(t) == "table" and t.fresh == true }
        acct.cvarRecord = r
    end
    return r
end
CVar.Record = Record

local function Sub(t, k)
    local s = t[k]
    if type(s) ~= "table" then s = {} t[k] = s end
    return s
end

local function Guid() return UnitGUID and UnitGUID("player") or nil end

local function Root(name)
    local r = Record()
    if not r then return nil end
    if PerCharacter(name) then
        local guid = Guid()
        if not guid then return nil end
        return Sub(Sub(r, "chars"), guid), r
    end
    return r, r
end

local function Note(root, r, key, before, owner)
    local t = Sub(root, "cvar")
    local e = t[key]
    if not e then
        e = {}
        t[key] = e
        if r.fresh and before ~= nil then e.b = before end
    end
    e.a = Read(key)
    e.o = owner
    return e
end

------------------------------------------------------------------------
-- Writing
------------------------------------------------------------------------
function CVar.Set(name, value, owner)
    if uninstalled or type(name) ~= "string" then return false end
    local key = name:lower()
    local before = Read(name)
    if not Write(name, Str(value)) then return false end
    local root, r = Root(name)
    if root then Note(root, r, key, before, owner) end
    if RC.DebugPrint then RC:DebugPrint("CVar " .. name .. " = " .. tostring(Str(value)) .. " (" .. tostring(owner) .. ")", "cvar") end
    return true
end

function CVar.Hold(name, value, owner)
    if uninstalled or type(name) ~= "string" then return false end
    local key = name:lower()
    local cur = Read(name)
    local root = Root(name)
    local snap
    if root and cur ~= nil and not (root.held and root.held[key]) then
        local e = root.cvar and root.cvar[key]
        snap = { e = e and { b = e.b, a = e.a, o = e.o } or false, v = cur, o = owner }
    end
    local ok = CVar.Set(name, value, owner)
    if ok and snap then Sub(root, "held")[key] = snap end
    return ok
end

local function EndHold(root, key, h, write)
    local e = root.cvar and root.cvar[key]
    local cur = Read(key)
    if write and h.v ~= nil and (not e or cur == e.a) then Write(key, h.v) end
    if h.e then
        Sub(root, "cvar")[key] = h.e
    elseif root.cvar then
        root.cvar[key] = nil
    end
    root.held[key] = nil
end

function CVar.Release(name, owner)
    if type(name) ~= "string" then return false end
    local key = name:lower()
    local root = Root(name)
    local h = root and root.held and root.held[key]
    if not h then return false end
    if owner ~= nil and h.o ~= nil and h.o ~= owner then return false end
    EndHold(root, key, h, not uninstalled)
    return true
end

------------------------------------------------------------------------
-- Putting back
------------------------------------------------------------------------
local function RestoreEntry(root, r, key, e)
    local cur = Read(key)
    if cur == nil or cur ~= e.a then return false end
    local want = r.fresh and e.b or nil
    if want == nil then want = Default(key) end
    if want == nil or want == cur then return false end
    return Write(key, want)
end

local function RestoreRoot(root, r, pick)
    local n = 0
    if not root then return 0 end
    if root.held then
        for key, h in pairs(root.held) do
            if pick(h.o) then EndHold(root, key, h, true) n = n + 1 end
        end
        if next(root.held) == nil then root.held = nil end
    end
    if root.cvar then
        for key, e in pairs(root.cvar) do
            if pick(e.o) then
                if RestoreEntry(root, r, key, e) then n = n + 1 end
                root.cvar[key] = nil
            end
        end
        if next(root.cvar) == nil then root.cvar = nil end
    end
    return n
end

local function Everywhere(pick)
    local r = Record(true)
    if not r then return 0 end
    local n = RestoreRoot(r, r, pick)
    local guid = Guid()
    local c = r.chars and guid and r.chars[guid]
    if c then
        n = n + RestoreRoot(c, r, pick)
        if next(c) == nil then r.chars[guid] = nil end
    end
    return n
end

function CVar.RestoreOwner(owner)
    if owner == nil then return 0 end
    return Everywhere(function(o) return o == owner end)
end

function CVar.RestoreAll()
    local n = Everywhere(function() return true end)
    local r = Record(true)
    if r then r.fresh = true end
    return n
end

------------------------------------------------------------------------
-- Which owners are off
------------------------------------------------------------------------
function CVar.OwnerCheck(owner, fn) checks[owner] = fn end

function CVar.OwnerOff(owner)
    local fn = checks[owner]
    if not fn then return false end
    local ok, off = pcall(fn)
    return ok and off and true or false
end

function CVar.LoginPass()
    if uninstalled then return 0 end
    return Everywhere(function(o) return CVar.OwnerOff(o) end)
end

------------------------------------------------------------------------
-- Uninstall
------------------------------------------------------------------------
-- Puts back everything Readycheck changed and turns every Readycheck addon
-- off for every character. The caller reloads. Refused in combat. Saved
-- variables are left alone (the player may come back).
function CVar.Uninstall()
    if uninstalled then return false end
    if InCombatLockdown and InCombatLockdown() then return false end
    CVar.RestoreAll()
    uninstalled = true
    local disable = C_AddOns and C_AddOns.DisableAddOn or _G.DisableAddOn
    local count = (C_AddOns and C_AddOns.GetNumAddOns) or _G.GetNumAddOns
    local info = (C_AddOns and C_AddOns.GetAddOnInfo) or _G.GetAddOnInfo
    if disable and count and info then
        local okN, n = pcall(count)
        for i = 1, (okN and tonumber(n)) or 0 do
            local okI, name = pcall(info, i)
            if okI and type(name) == "string" and name:find("^Readycheck") then pcall(disable, name) end
        end
    end
    local save = C_AddOns and C_AddOns.SaveAddOns or _G.SaveAddOns
    if save then pcall(save) end
    return true
end

function CVar.Uninstalled() return uninstalled end

------------------------------------------------------------------------
-- Login
------------------------------------------------------------------------
-- RC:OnEnable calls AtLogin once. Nothing is made or registered unless the
-- record holds something to put back: an account that never had a CVar
-- written by Readycheck costs nothing at all. A pass due in combat waits
-- for the fight to end (the only frame this file ever makes, made then).
local waiter
local function Pass()
    if InCombatLockdown and InCombatLockdown() then
        if not waiter then
            waiter = CreateFrame("Frame")
            waiter:SetScript("OnEvent", function(self)
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                pcall(CVar.LoginPass)
            end)
        end
        waiter:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    pcall(CVar.LoginPass)
end

function CVar.AtLogin()
    local r = Record(true)
    if not r then return false end
    if not (r.cvar or r.held or r.chars) then return false end
    C_Timer.After(2, Pass)
    return true
end

RC.CVar = CVar
