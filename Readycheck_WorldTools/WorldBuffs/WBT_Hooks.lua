------------------------------------------------------------------------
-- Readycheck - World Buff Timers Hooks
-- Runtime-wraps WorldBuffSync's legacy-db readers so the existing world
-- buff board keeps its drop timers, songflowers, DMF and opposite-Ony
-- data from our own store once NovaWorldBuffs is disabled. Hooks only;
-- no other files are modified.
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end
local RC = _G.Readycheck
if not RC or not RC.WorldBuffTimers then return end
local WBT = RC.WorldBuffTimers

-- Larger remaining = newer underlying drop timestamp, so max() wins.
local function mergeRemaining(a, b)
    if a == nil then return b end
    if b == nil then return a end
    return (a > b) and a or b
end

local function installHooks(WB)
    if WB._wbtHooked then return end
    WB._wbtHooked = true

    local origTimers = WB.ReadNWB
    WB.ReadNWB = function(self, ...)
        local orig = origTimers and origTimers(self, ...) or nil
        local ours = WBT:GetTimers()
        if not ours then return orig end
        if not orig then return ours end
        local out = {}
        out.warchief = mergeRemaining(orig.warchief, ours.warchief)
        out.rally = mergeRemaining(orig.rally, ours.rally)
        if ours.songflower ~= nil then
            out.songflower = ours.songflower
        else
            out.songflower = orig.songflower
        end
        if next(out) == nil then return nil end
        return out
    end

    local origFlowers = WB.ReadNWBFlowers
    WB.ReadNWBFlowers = function(self, ...)
        local orig = origFlowers and origFlowers(self, ...) or nil
        local ours = WBT:GetFlowerTimes()
        if not ours then return orig end
        if not orig then return ours end
        local out = {}
        for i = 1, 10 do
            local a, b = orig[i], ours[i]
            if a and b then
                out[i] = (a > b) and a or b
            else
                out[i] = a or b
            end
        end
        return out
    end

    local origDMF = WB.ReadNWBSelfDMF
    WB.ReadNWBSelfDMF = function(self, ...)
        local ours = WBT:GetSelfDMFRemaining()
        if ours ~= nil then return ours end
        return origDMF and origDMF(self, ...) or nil
    end

    local origOpp = WB.GetOppositeOnyxia
    WB.GetOppositeOnyxia = function(self, ...)
        local orig = origOpp and origOpp(self, ...) or nil
        if orig ~= nil then return orig end
        return WBT:GetOppOnyRemaining()
    end

    -- Readycheck's own timers are authoritative; the base reader (NovaWorldBuffs
    -- if installed, else the legacy dropLog) is only a fallback for keys we have
    -- no data for.
    --
    -- Rally comes from GetTimers().rally, which is the Onyxia lockout alone.
    -- It used to also merge GetNefRemaining() here, on the reasoning that both
    -- heads drop Rallying Cry - but the Head of Nefarian has no turn-in
    -- cooldown on Era/Anniversary, so that merge could only ever report a
    -- lockout that does not exist and drag the row earlier than the truth.
    local origDrops = WB.GetDrops
    WB.GetDrops = function(self, ...)
        local out  = origDrops and origDrops(self, ...) or {}
        local ours = WBT:GetTimers()
        for _, entry in ipairs(out) do
            local mine = ours and ours[entry.key] or nil
            if mine ~= nil then
                entry.known       = true
                entry.cdRemaining = mine
            end
        end
        return out
    end

    WBT:Debug("WorldBuffSync reader hooks installed")
end

-- WorldBuffSync builds its reader table lazily, so poll once a second for up
-- to a minute rather than assume a load order between the two files.
local attempts = 0
local function tryInstall()
    local WB = RC.WorldBuffs
    if WB and WB.ReadNWB and WB.GetDrops then
        installHooks(WB)
        return
    end
    attempts = attempts + 1
    if attempts < 60 then
        C_Timer.After(1, tryInstall)
    else
        WBT:Debug("WorldBuffSync never initialized; hooks not installed")
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:SetScript("OnEvent", function()
    C_Timer.After(2, tryInstall)
end)
