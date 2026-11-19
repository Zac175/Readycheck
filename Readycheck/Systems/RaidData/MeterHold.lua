-- Readycheck - the damage meter with a raid config
-- (2026-11-18, Zac: "for certain ready check raid configs i want to be able
-- to disable the damage meter in zui automatically so if i pick like my
-- okay booner config ... i want my zui damage meters gone"; 2026-11-19:
-- "it needs to work for other damage meters as well not just zui recount
-- and details for example".)
--
-- A raid config can ask for the damage meter's windows to be out of sight
-- while it is the config in force: you are standing in that raid and it
-- is the raid's picked config. On the config itself (RaidProfilesSystem):
--   profile.meterHide = "meter"   every meter window but threat
--                       "all"     threat windows too
--                       nil       nothing asked (what ships)
-- The meter keeps counting; its windows are back the moment the config
-- is not in force. Asked on what changes the answer - the zone, the
-- picked config, the setting - never on a timer.
--
-- THE METERS (HOLDERS below), each through its own calls - the ones its
-- own show / hide commands use - never by reaching into its frames:
--   ZacUI     ZacUI.Meter.Hold("Readycheck", mode): a flag for the
--             session on ZacUI's side, nothing to remember here.
--   Details   a window is closed with instance:ShutDown(true) and opened
--             with instance:EnableInstance(nil, true) (what /details hide
--             and /details show do; the "true" keeps window groups). A
--             window showing its Tiny Threat plugin is a threat window.
--   Recount   Recount.MainWindow:Hide() / :Show() (/recount hide, show).
--   Skada     a window's own "hidden" setting, then Skada:ApplySettings()
--             (its Hide window option).
-- Details, Recount and Skada SAVE that a window is closed. So what
-- Readycheck closed is written down, per character, and only that is put
-- back - a window you keep closed yourself stays closed, and a /reload or
-- a logout in the raid does not lose track of the ones to reopen:
--   ReadycheckDB.account.meterHeld = { [GUID] = { details = { [id] = true },
--     recount = true, skada = { [window name] = true } } }
-- Account bookkeeping like Core_CVar's record of what it changed: never
-- exported, never synced, emptied as the windows come back.
local RC = _G.Readycheck
if not RC then return end

local pairs, ipairs, type, pcall, next, tostring = pairs, ipairs, type, pcall, next, tostring
local table_sort = table.sort

RC.METER_HIDE_MODES = { "meter", "all" }
local METER_HIDE = { meter = true, all = true }

------------------------------------------------------------------------
-- THE METERS
--   Present()        the addon is loaded and has the calls used here
--   Ready()          (optional) it has finished starting up
--   Hide(mode, mem)  hides what the mode covers; mem is what Readycheck
--                    hid before (or nil); returns what it has hidden now
--   Show(mem)        puts back what mem lists
--   remembers        the meter saves "closed": mem is written down
------------------------------------------------------------------------
local HOLDERS = {}
RC.MeterHolders = HOLDERS

-- one call into a meter: an error there is noted and goes no further, so
-- what was already closed is still written down
local function Try(fn, ...)
    local ok, a = pcall(fn, ...)
    if not ok and RC.DebugPrint then RC:DebugPrint("MeterHold: " .. tostring(a), "config") end
    return ok, a
end

-- ZacUI ---------------------------------------------------------------
local function ZacMeter()
    local Z = _G.ZacUI
    local M = type(Z) == "table" and Z.Meter or nil
    if type(M) == "table" and type(M.Hold) == "function" then return M end
    return nil
end
HOLDERS[#HOLDERS + 1] = {
    id = "zacui", name = "ZacUI",
    Present = function() return ZacMeter() ~= nil end,
    Hide = function(mode) ZacMeter().Hold("Readycheck", mode) return nil end,
    Show = function() ZacMeter().Hold("Readycheck", nil) end,
}

-- Details -------------------------------------------------------------
local function DetailsAddon()
    local D = _G.Details
    if type(D) == "table" and type(D.ListInstances) == "function" and type(D.GetInstance) == "function" then return D end
    return nil
end
-- a window on its Tiny Threat plugin
local function DetailsThreat(inst)
    if type(inst.GetRaidPluginName) ~= "function" then return false end
    if _G.DETAILS_MODE_RAID == nil or inst.modo ~= _G.DETAILS_MODE_RAID then return false end
    return inst:GetRaidPluginName() == "DETAILS_PLUGIN_TINY_THREAT"
end
HOLDERS[#HOLDERS + 1] = {
    id = "details", name = "Details", remembers = true,
    Present = function() return DetailsAddon() ~= nil end,
    Ready = function() return not DetailsAddon().initializing end,
    Hide = function(mode, mem)
        local D = DetailsAddon()
        mem = type(mem) == "table" and mem or {}
        local back = {}
        for id, inst in D:ListInstances() do
            if type(inst) == "table" and type(inst.IsEnabled) == "function" then
                local covered = mode == "all" or not DetailsThreat(inst)
                if inst:IsEnabled() then
                    if not covered then
                        mem[id] = nil
                    elseif inst.baseframe and not inst.ignore_mass_showhide and type(inst.ShutDown) == "function" then
                        if Try(inst.ShutDown, inst, true) then mem[id] = true end
                    end
                elseif mem[id] and not covered then
                    -- (closed here under a wider ask, and this one leaves it be)
                    back[#back + 1] = id
                end
            end
        end
        table_sort(back, function(a, b) return a > b end)
        for _, id in ipairs(back) do
            local inst = D:GetInstance(id)
            if type(inst) == "table" and type(inst.EnableInstance) == "function" then Try(inst.EnableInstance, inst, nil, true) end
            mem[id] = nil
        end
        return next(mem) and mem or nil
    end,
    Show = function(mem)
        if type(mem) ~= "table" then return end
        local D = DetailsAddon()
        local ids = {}
        for id in pairs(mem) do if type(id) == "number" then ids[#ids + 1] = id end end
        -- (highest first, as Details reopens them itself)
        table_sort(ids, function(a, b) return a > b end)
        for _, id in ipairs(ids) do
            local inst = D:GetInstance(id)
            if type(inst) == "table" and type(inst.IsEnabled) == "function" and not inst:IsEnabled()
               and type(inst.EnableInstance) == "function" then
                Try(inst.EnableInstance, inst, nil, true)
            end
        end
    end,
}

-- Recount -------------------------------------------------------------
local function RecountWindow()
    local R = _G.Recount
    local W = type(R) == "table" and R.MainWindow or nil
    if type(W) == "table" and type(W.IsShown) == "function" and type(W.Hide) == "function"
       and type(W.Show) == "function" then
        return W, R
    end
    return nil, (type(R) == "table") and R or nil
end
HOLDERS[#HOLDERS + 1] = {
    id = "recount", name = "Recount", remembers = true,
    Present = function() return type(_G.Recount) == "table" end,
    Ready = function() return RecountWindow() ~= nil end,
    Hide = function(_, mem)
        local W = RecountWindow()
        if W:IsShown() then
            Try(W.Hide, W)
            if not W:IsShown() then return true end
        end
        return mem and true or nil
    end,
    Show = function(mem)
        if not mem then return end
        local W, R = RecountWindow()
        if W:IsShown() then return end
        -- (Recount's own "hide when not collecting data" wants it hidden)
        local prof = type(R.db) == "table" and R.db.profile or nil
        if type(prof) == "table" and prof.HideCollect and not R.CurrentDataCollect then return end
        Try(W.Show, W)
        if type(R.RefreshMainWindow) == "function" then Try(R.RefreshMainWindow, R) end
    end,
}

-- Skada ---------------------------------------------------------------
local function SkadaAddon()
    local K = _G.Skada
    if type(K) == "table" and type(K.GetWindows) == "function" and type(K.ApplySettings) == "function" then return K end
    return nil
end
HOLDERS[#HOLDERS + 1] = {
    id = "skada", name = "Skada", remembers = true,
    Present = function() return SkadaAddon() ~= nil end,
    Ready = function()
        local K = SkadaAddon()
        return type(K.db) == "table" and type(K.db.profile) == "table" and type(K:GetWindows()) == "table"
    end,
    Hide = function(_, mem)
        local K = SkadaAddon()
        mem = type(mem) == "table" and mem or {}
        local changed = false
        for _, win in ipairs(K:GetWindows()) do
            local db = type(win) == "table" and win.db or nil
            if type(db) == "table" and db.name ~= nil and not db.hidden then
                db.hidden = true
                mem[tostring(db.name)] = true
                changed = true
            end
        end
        if changed then Try(K.ApplySettings, K) end
        return next(mem) and mem or nil
    end,
    Show = function(mem)
        if type(mem) ~= "table" then return end
        local K = SkadaAddon()
        local changed = false
        for _, win in ipairs(K:GetWindows()) do
            local db = type(win) == "table" and win.db or nil
            if type(db) == "table" and db.name ~= nil and mem[tostring(db.name)] and db.hidden then
                db.hidden = false
                changed = true
            end
        end
        if changed then Try(K.ApplySettings, K) end
    end,
}

------------------------------------------------------------------------
-- WHAT READYCHECK HID (per character, account bookkeeping)
------------------------------------------------------------------------
local function Held(create)
    if type(ReadycheckDB) ~= "table" then return nil end
    local guid = UnitGUID and UnitGUID("player") or nil
    if not guid then return nil end
    local acct = ReadycheckDB.account
    if type(acct) ~= "table" then
        if not create then return nil end
        acct = {}
        ReadycheckDB.account = acct
    end
    local all = acct.meterHeld
    if type(all) ~= "table" then
        if not create then return nil end
        all = {}
        acct.meterHeld = all
    end
    local mine = all[guid]
    if type(mine) ~= "table" then
        if not create then return nil end
        mine = {}
        all[guid] = mine
    end
    return mine
end
local function Remember(id, mem)
    if mem == nil then
        local mine = Held(false)
        if not mine then return end
        mine[id] = nil
        -- (nothing left: the record goes too)
        if next(mine) == nil then
            local all = ReadycheckDB.account.meterHeld
            all[UnitGUID("player")] = nil
            if next(all) == nil then ReadycheckDB.account.meterHeld = nil end
        end
        return
    end
    local mine = Held(true)
    if mine then mine[id] = mem end
end
-- (for the tests and /rc's own checks: what is written down for this character)
function RC:MeterHeldRecord() return Held(false) end

------------------------------------------------------------------------
-- THE SETTING (on a raid config) AND THE CONFIG IN FORCE
------------------------------------------------------------------------
local Call = Try

-- is there a meter to ask at all
function RC:MeterHoldOffered()
    for _, h in ipairs(HOLDERS) do
        local ok, present = Call(h.Present)
        if ok and present then return true end
    end
    return false
end

-- what a config asks. The editors' side: the config on screen (the other
-- character's while remote editing).
function RC:GetRaidProfileMeterHide(raidName, profileName)
    if not (raidName and self.GetEditableRaidProfileStructure) then return nil end
    local structure = self:GetEditableRaidProfileStructure(raidName)
    local p = structure and structure.profiles and structure.profiles[profileName]
    local mode = type(p) == "table" and p.meterHide or nil
    return METER_HIDE[mode] and mode or nil
end

function RC:SetRaidProfileMeterHide(raidName, profileName, mode)
    if not (raidName and self.GetEditableRaidProfileStructure) then return false end
    local structure = self:GetEditableRaidProfileStructure(raidName)
    local p = structure and structure.profiles and structure.profiles[profileName]
    if type(p) ~= "table" then return false end
    p.meterHide = METER_HIDE[mode] and mode or nil
    self:SaveConfigurationToProfile()
    self:SyncMeterHold()
    return true
end

-- the config in force, always this character's own: mode, raid, config
function RC:RaidConfigMeterHide()
    local raid = self.GetZoneRaidName and self:GetZoneRaidName() or nil
    if not raid then return nil end
    local rd = self.db and self.db.raidProfiles and self.db.raidProfiles[raid]
    if type(rd) ~= "table" or type(rd.profiles) ~= "table" then return nil end
    local name = rd.activeProfile or "Default"
    local p = rd.profiles[name]
    local mode = type(p) == "table" and p.meterHide or nil
    if not METER_HIDE[mode] then return nil end
    return mode, raid, name
end

------------------------------------------------------------------------
-- ASKING THE METERS
------------------------------------------------------------------------
local RETRY_SECONDS, RETRY_MAX = 3, 10
local meterSaid = {}       -- [raid|config|mode] = said this session
local retries = 0

function RC:SyncMeterHold()
    if not self.db then return end
    local mode, raid, name = self:RaidConfigMeterHide()
    local asked, waiting = false, false
    for _, h in ipairs(HOLDERS) do
        local okP, present = Call(h.Present)
        if okP and present then
            local ready = true
            if h.Ready then
                local okR, r = Call(h.Ready)
                ready = okR and r and true or false
            end
            if not ready then
                waiting = true
            elseif mode then
                local mine = h.remembers and Held(false) or nil
                local ok, mem = Call(h.Hide, mode, mine and mine[h.id] or nil)
                if ok then
                    asked = true
                    if h.remembers then Remember(h.id, mem) end
                end
            else
                local mine = h.remembers and Held(false) or nil
                local mem = mine and mine[h.id] or nil
                if not h.remembers then
                    Call(h.Show)
                elseif mem ~= nil then
                    Call(h.Show, mem)
                    Remember(h.id, nil)
                end
            end
        end
    end
    if asked and mode then
        local key = raid .. "|" .. name .. "|" .. mode
        if not meterSaid[key] then
            meterSaid[key] = true
            self:Print(string.format(RCL["Damage meter hidden: the raid config \"%s\" asks for it (Manage > Damage meter)."], name))
        end
    end
    -- a meter that is still starting up is asked again shortly, a few times
    if waiting and retries < RETRY_MAX then
        retries = retries + 1
        self:SyncMeterHoldSoon(RETRY_SECONDS)
    elseif not waiting then
        retries = 0
    end
end

-- one ask a moment later, however many events came in
local meterAsked = false
function RC:SyncMeterHoldSoon(delay)
    if meterAsked then return end
    meterAsked = true
    C_Timer.After(delay or 1, function()
        meterAsked = false
        RC:SyncMeterHold()
    end)
end
