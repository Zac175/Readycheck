------------------------------------------------------------------------
-- Readycheck - Version Check
-- Out-of-date notice on its own RCVER addon prefix. Nothing to do with the
-- mesh: no token, no chunking, no BNet leg - one plain version string on
-- GUILD/RAID/PARTY.
-- Broadcast is throttled and jittered; the notice latches so it prints at
-- most once per session.
------------------------------------------------------------------------
local function InitializeVersionCheck()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializeVersionCheck); return end

    RC.VersionCheck = RC.VersionCheck or {}
    local VC = RC.VersionCheck

    local PREFIX = "RCVER"

    local function ParseVersion(v)
        local t = {}
        if type(v) ~= "string" then v = tostring(v or "") end
        for n in v:gmatch("%d+") do t[#t + 1] = tonumber(n) end
        return t
    end

    local function CompareVersions(a, b)
        local pa, pb = ParseVersion(a), ParseVersion(b)
        local n = math.max(#pa, #pb)
        for i = 1, n do
            local x, y = pa[i] or 0, pb[i] or 0
            if x > y then return 1 end
            if x < y then return -1 end
        end
        return 0
    end

    -- Sole guard on the inbound string: anything that is not a short
    -- digits-and-dots version is dropped before it can reach a chat print.
    local function SanitizeVersion(v)
        if type(v) ~= "string" then return nil end
        v = v:match("^%s*(.-)%s*$")
        if v == "" or #v > 24 then return nil end
        if not v:find("^%d[%d%.]*$") then return nil end
        return v
    end

    local function MyVersion() return RC.version or "0" end

    local notified     = false
    local lastBroadcast = 0

    function VC:Notify(latest)
        if notified then return end
        notified = true
        if RC.Print then
            RC:Print(RCL["|cffff5555Out of date:|r your version ("] .. MyVersion()
                .. RCL[") is behind |cff00ff00v"] .. latest .. RCL["|r. Update Readycheck on CurseForge."])
        end
    end

    function VC:OnReceive(version)
        version = SanitizeVersion(version)
        if not version then return end
        if CompareVersions(version, MyVersion()) > 0 then
            self:Notify(version)
        end
    end

    local function GetChannels()
        local chans
        if IsInGuild and IsInGuild() then
            chans = chans or {}; chans[#chans + 1] = "GUILD"
        end
        if IsInRaid and IsInRaid() then
            chans = chans or {}; chans[#chans + 1] = "RAID"
        elseif IsInGroup and IsInGroup() then
            chans = chans or {}; chans[#chans + 1] = "PARTY"
        end
        return chans
    end

    function VC:Broadcast()
        if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
        -- not delivered inside an instance on Forever (Core_Flavor)
        if RC:AddonMessagesBlocked() then return end
        local now = GetTime()
        -- 10s floor between sends. GROUP_ROSTER_UPDATE fires in bursts, and
        -- every addon copy in the group reacts to the same burst.
        if now - lastBroadcast < 10 then return end
        local chans = GetChannels()
        if not chans then return end
        lastBroadcast = now
        local ver = MyVersion()
        for _, ch in ipairs(chans) do
            C_ChatInfo.SendAddonMessage(PREFIX, ver, ch)
        end
    end

    function VC:ScheduleBroadcast(baseDelay)
        if self._pending then return end
        self._pending = true
        -- Spread the reply so a raid full of Readycheck users does not send
        -- on the same frame after a roster change.
        local jitter = math.random() * 3
        C_Timer.After((baseDelay or 0) + jitter, function()
            VC._pending = nil
            VC:Broadcast()
        end)
    end

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("GROUP_ROSTER_UPDATE")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "CHAT_MSG_ADDON" then
            local prefix, message, distType = ...
            if prefix == PREFIX and (distType == "GUILD" or distType == "RAID" or distType == "PARTY") then
                VC:OnReceive(message)
            end
        elseif event == "GROUP_ROSTER_UPDATE" then
            VC:ScheduleBroadcast(2)
        elseif event == "PLAYER_ENTERING_WORLD" then
            VC:ScheduleBroadcast(5)
        end
    end)

    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        local ok = C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        if not ok then
            C_Timer.After(2, function() C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) end)
        end
    end

    VC:ScheduleBroadcast(5)
end

InitializeVersionCheck()
