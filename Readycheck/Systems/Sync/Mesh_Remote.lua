------------------------------------------------------------------------
-- Readycheck - Mesh Remote Edit and Event Wiring
-- Remote-edit mode: fetching, editing and pushing another character's gear
-- sets, trinket config, reminders and raid configs, plus the same-account
-- snapshot handoff between the user's own alts (no wire traffic - shared
-- ReadycheckDB, written at logout and applied at the next login).
-- Also owns the mesh event frame: login bootstrap, CHAT_MSG_ADDON, both
-- cross-faction inbound legs, discovery channel joins/leaves, logout.
-- Every push queues when the target is offline. ReadycheckDB.remote* holds
-- the pending work and the login-sync path in Mesh_Inbound.lua flushes it
-- when that peer's HELLO arrives.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)

local pairs, ipairs, type, tostring, tonumber, select =
      pairs, ipairs, type, tostring, tonumber, select
local math_floor = math.floor
local string_format, string_find, string_sub, string_gsub =
      string.format, string.find, string.sub, string.gsub
local string_match, string_len, string_byte = string.match, string.len, string.byte
local table_insert, table_remove, table_concat = table.insert, table.remove, table.concat
local GetTime = GetTime
local CreateFrame, C_Timer = CreateFrame, C_Timer
local loadstring, pcall = loadstring, pcall
local RC = _G.Readycheck
if not RC then return end
RC.MeshSync = RC.MeshSync or {}
local MS = RC.MeshSync
RC._mss = RC._mss or {}
local _mss = RC._mss
local ADDON_PREFIX, BuildHelloData, CMD_BYE, CMD_HELLO, CMD_PUSH_DONE, ChunkData, EnqueueMessages, GetCharEnabled =
      _mss.ADDON_PREFIX, _mss.BuildHelloData, _mss.CMD_BYE, _mss.CMD_HELLO, _mss.CMD_PUSH_DONE, _mss.ChunkData, _mss.EnqueueMessages, _mss.GetCharEnabled
local ChunkForTarget = _mss.ChunkForTarget
local GetMyLabel, GetToken, GetToonKey, HideChannelFromChat, InitBroadcastHashes, JoinDiscoveryChannel, LogActivity, MAINT_INTERVAL =
      _mss.GetMyLabel, _mss.GetToken, _mss.GetToonKey, _mss.HideChannelFromChat, _mss.InitBroadcastHashes, _mss.JoinDiscoveryChannel, _mss.LogActivity, _mss.MAINT_INTERVAL
local Maintenance, NextMsgId, NormalizeName, PushRawPayload, QuickHash, RebuildSyncCategories, Serialize, SlimRaidData =
      _mss.Maintenance, _mss.NextMsgId, _mss.NormalizeName, _mss.PushRawPayload, _mss.QuickHash, _mss.RebuildSyncCategories, _mss.Serialize, _mss.SlimRaidData
local StripGearFromRaid, knownAccounts =
      _mss.StripGearFromRaid, _mss.knownAccounts

    local function EnsureRemoteWarriors()
        if not ReadycheckDB then return nil end
        ReadycheckDB.remoteWarriors = ReadycheckDB.remoteWarriors or {}
        return ReadycheckDB.remoteWarriors
    end

    function MS:GetRemoteWarriorData(charKey)
        local t = EnsureRemoteWarriors()
        return t and t[charKey]
    end

    -- One entry per remote character: gearSets is their last known state,
    -- localEdits is what we changed here, pendingPush names the sets not yet
    -- delivered. The three are only reconciled once a push actually goes out.
    function MS:EnsureRemoteWarriorEntry(charKey, label)
        local t = EnsureRemoteWarriors()
        if not t then return nil end
        if not t[charKey] then
            t[charKey] = {
                label = label or charKey,
                gearSets = {},
                availableItems = {},
                localEdits = {},
                pendingPush = {},
                lastReceived = 0,
            }
        elseif label and label ~= "" then
            t[charKey].label = label
        end
        return t[charKey]
    end

    function MS:SaveRemoteEdit(charKey, setName, setData)
        local entry = self:EnsureRemoteWarriorEntry(charKey)
        if not entry then return end
        entry.localEdits = entry.localEdits or {}
        entry.localEdits[setName] = RC.DeepCopy(setData)
        entry.pendingPush = entry.pendingPush or {}
        local found = false
        for _, n in ipairs(entry.pendingPush) do if n == setName then found = true; break end end
        if not found then table_insert(entry.pendingPush, setName) end

        if _mss.isEnabled then
            local peerName, peerLabel = nil, nil
            for lbl, info in pairs(knownAccounts) do
                if info.online and info.charName then
                    local ck = NormalizeName(info.charName)
                    if ck == charKey then
                        peerName  = info.charName
                        peerLabel = lbl
                        break
                    end
                end
            end

            if peerName then
                MS._remotePushDebounce = MS._remotePushDebounce or {}
                if MS._remotePushDebounce[charKey] then
                    MS._remotePushDebounce[charKey]:Cancel()
                    MS._remotePushDebounce[charKey] = nil
                end
                local capKey   = charKey
                local capPeer  = peerName
                local capLabel = peerLabel
                -- Coalesce a run of edits into one push, and re-check that
                -- the peer is still online when it fires - three seconds is
                -- long enough for them to log out.
                MS._remotePushDebounce[charKey] = C_Timer.After(3.0, function()
                    MS._remotePushDebounce[capKey] = nil
                    local stillOnline = false
                    for _, info2 in pairs(knownAccounts) do
                        if info2.online and info2.charName and NormalizeName(info2.charName) == capKey then
                            stillOnline = true; break
                        end
                    end
                    if stillOnline then
                        MS:PushQueuedGearSets(capKey, capPeer, capLabel, false)
                    end
                end)
            end
        end
    end

    function MS:_ApplyGearDataFromCache(charKey, cache)
        if not charKey or not cache then return end
        ReadycheckDB.remoteWarriors = ReadycheckDB.remoteWarriors or {}
        local rw = ReadycheckDB.remoteWarriors
        rw[charKey] = rw[charKey] or { localEdits = {}, pendingPush = {} }
        local entry = rw[charKey]
        entry.label          = cache.label or cache.charName or charKey
        entry.gearSets       = RC.DeepCopy and RC.DeepCopy(cache.gearSets or {}) or {}
        entry.availableItems = RC.DeepCopy and RC.DeepCopy(cache.availableItems or {}) or {}
        entry.lastReceived   = GetTime()
        entry.fromCache      = true
    end

    function MS:RequestRemoteTrinketData(member)
        if not member then return end
        local rawName = member.name or ""
        local charKey = NormalizeName(rawName)
        if not charKey then return end

        -- Cached data answers instantly so the panel is never blank; the
        -- live request still goes out afterwards to refresh it.
        local cache = ReadycheckDB
                   and ReadycheckDB.meshSyncGearCache
                   and ReadycheckDB.meshSyncGearCache[charKey]
        if cache then
            ReadycheckDB.remoteTrinketWarriors =
                ReadycheckDB.remoteTrinketWarriors or {}
            local rw    = ReadycheckDB.remoteTrinketWarriors
            rw[charKey] = rw[charKey] or { localEdits = {} }
            local entry = rw[charKey]
            entry.label = cache.label or cache.charName or charKey
            local charProfile = ReadycheckDB.characters
                             and ReadycheckDB.characters[charKey]
            if charProfile and charProfile.trinketSwap then
                entry.config = RC.DeepCopy and RC.DeepCopy(charProfile.trinketSwap) or {}
            end
            local trinkets = {}
            for _, item in ipairs(cache.availableItems or {}) do
                if item.equipLoc == "INVTYPE_TRINKET" then
                    trinkets[#trinkets+1] = item
                end
            end
            entry.availableTrinkets = trinkets
            entry.lastReceived      = GetTime()
            if RC.trinketSwapTab == "remote"
                    and RC.ShowSidebarTrinketSwapConfig
                    and RC.sidebarConfigFrame then
                local cf = RC.sidebarConfigFrame.compatFrame
                if cf then RC:ShowSidebarTrinketSwapConfig(cf) end
            end
            if _mss.isEnabled then
                for _, info in pairs(knownAccounts) do
                    if info.online and info.charName
                            and NormalizeName(info.charName) == charKey then
                        self:Broadcast("REQ_remoteTrinketData", "", charKey)
                        break
                    end
                end
            end
            return
        end

        if not _mss.isEnabled then
            RC:Print(RCL["Mesh: Mesh Network not enabled."]); return
        end
        self:Broadcast("REQ_remoteTrinketData", "", charKey)
        local lbl = member.label or rawName
        LogActivity("Requested trinket data from " .. lbl)
        RC:Print(RCL["Mesh: Requested trinket data from "] .. lbl
            .. RCL[". They must be online and have Mesh enabled."])
    end

    function MS:FetchRaidConfigForEdit(member, raidKey)
        if not member or not raidKey or raidKey == "" then return end
        if not _mss.isEnabled then
            RC:Print(RCL["Mesh: Mesh Network not enabled."]); return
        end
        local charKey = NormalizeName(member.name or "")
        if not charKey then return end
        local payload = Serialize({ raidKey = raidKey })
        self:Broadcast("REQ_raidCfgForEdit", payload, charKey)
        local lbl = member.label or member.name or charKey
        LogActivity("Fetching raid config '" .. raidKey .. "' from " .. lbl .. " (edit mode)")
        RC:DebugPrint("MeshSync: FetchRaidConfigForEdit '" .. raidKey .. "' from " .. charKey, "meshsync")
    end

    function MS:FlushRemoteEditNow(member, raidKey, data)
        if not member or not raidKey or not data then return end
        local charKey = NormalizeName(member.name or "")
        if not charKey then return end

        if ReadycheckDB then
            ReadycheckDB.remoteRaidConfigs = ReadycheckDB.remoteRaidConfigs or {}
            ReadycheckDB.remoteRaidConfigs[charKey] =
                ReadycheckDB.remoteRaidConfigs[charKey] or {}
            local slot = ReadycheckDB.remoteRaidConfigs[charKey][raidKey] or {}
            slot.memberLabel  = member.label or member.name or ""
            slot.data         = RC.DeepCopy(data)
            slot.savedAt      = time()
            slot.gearIncluded = true
            ReadycheckDB.remoteRaidConfigs[charKey][raidKey] = slot
        end

        -- Leaving edit mode: cancel the debounced push and send now, because
        -- the pending timer would fire after RC.remoteEditMode is gone and
        -- abort itself.
        if _mss.raidCfgPushDebounce then _mss.raidCfgPushDebounce:Cancel(); _mss.raidCfgPushDebounce = nil end

        local send = SlimRaidData(data)

        local isOnline = false
        for _, acct in pairs(knownAccounts) do
            if acct.online and acct.charName
                    and NormalizeName(acct.charName) == charKey then
                isOnline = true; break
            end
        end

        if _mss.isEnabled and isOnline then
            local targetMember = { name = charKey, label = member.label or member.name }
            PushRawPayload("raidCfgFor", { raidKey = raidKey, data = send }, targetMember, nil, raidKey)
            RC:DebugPrint("MeshSync: FlushRemoteEditNow pushed '" .. raidKey ..
                "' to " .. charKey, "meshsync")
        else
            if ReadycheckDB then
                ReadycheckDB.remoteRaidConfigQueue =
                    ReadycheckDB.remoteRaidConfigQueue or {}
                ReadycheckDB.remoteRaidConfigQueue[charKey] = {
                    raidKey  = raidKey,
                    data     = send,
                    label    = member.label or member.name or "",
                    queuedAt = time(),
                }
            end
            RC:DebugPrint("MeshSync: FlushRemoteEditNow queued '" .. raidKey ..
                "' for offline " .. charKey, "meshsync")
        end
    end

    function MS:PushOrQueueRaidConfig(member, raidKey, customData)
        if not member or not raidKey or raidKey == "" then return end
        local charKey = NormalizeName(member.name or "")
        if not charKey then return end

        local rd
        if customData then
            rd = customData
        else
            if not RC.db or not RC.db.raidProfiles or not RC.db.raidProfiles[raidKey] then return end
            local includeGear = (_mss.charCfg and _mss.charCfg.syncRaidGear) or (RC.remoteEditMode ~= nil)
            rd = includeGear
                 and RC.db.raidProfiles[raidKey]
                 or  StripGearFromRaid(RC.db.raidProfiles[raidKey])
        end

        if ReadycheckDB then
            ReadycheckDB.remoteRaidConfigs = ReadycheckDB.remoteRaidConfigs or {}
            ReadycheckDB.remoteRaidConfigs[charKey] =
                ReadycheckDB.remoteRaidConfigs[charKey] or {}
            local slot = ReadycheckDB.remoteRaidConfigs[charKey][raidKey] or {}
            slot.memberLabel  = member.label or member.name or ""
            slot.data         = RC.DeepCopy(rd)
            slot.savedAt      = time()
            slot.gearIncluded = true
            ReadycheckDB.remoteRaidConfigs[charKey][raidKey] = slot
        end

        local isOnline = false
        for _, acct in pairs(knownAccounts) do
            if acct.online and acct.charName
                    and NormalizeName(acct.charName) == charKey then
                isOnline = true; break
            end
        end

        if _mss.isEnabled and isOnline then
            if _mss.raidCfgPushDebounce then _mss.raidCfgPushDebounce:Cancel() end
            local capKey    = charKey
            local capMember = { name = charKey, label = member.label or member.name }
            local capRaid   = raidKey
            -- Re-reads the live edit buffer when it fires and aborts if the
            -- session moved to another raid or ended, so the 1.5s old
            -- snapshot captured above is never what gets delivered.
            _mss.raidCfgPushDebounce = C_Timer.After(1.5, function()
                _mss.raidCfgPushDebounce = nil
                local rem = RC.remoteEditMode
                if not rem or rem.raidKey ~= capRaid then return end
                local cur = RC._remoteEditData
                if not cur then return end
                local send = SlimRaidData(cur)
                PushRawPayload("raidCfgFor", { raidKey = capRaid, data = send }, capMember, nil, capRaid)
                RC:DebugPrint("MeshSync: pushed raidCfgFor '" .. capRaid ..
                    "' to " .. capKey, "meshsync")
            end)
        else
            if not ReadycheckDB then return end
            ReadycheckDB.remoteRaidConfigQueue = ReadycheckDB.remoteRaidConfigQueue or {}
            ReadycheckDB.remoteRaidConfigQueue[charKey] = {
                raidKey  = raidKey,
                data     = SlimRaidData(rd),
                label    = member.label or member.name or "",
                queuedAt = time(),
            }
            RC:DebugPrint("MeshSync: queued raidCfgFor '" .. raidKey ..
                "' for offline " .. charKey, "meshsync")
        end
    end

    function MS:PushQueuedGearSets(charKey, targetCharName, targetLabel, silent)
        if not _mss.isEnabled then return 0 end
        if not RC.DeepCopy then return 0 end

        local payload = { gearSets = {} }
        local found = 0

        local rwEntry = self:GetRemoteWarriorData(charKey)
        if rwEntry and rwEntry.localEdits and rwEntry.pendingPush and #rwEntry.pendingPush > 0 then
            for _, setName in ipairs(rwEntry.pendingPush) do
                local setData = rwEntry.localEdits[setName]
                if setData then
                    payload.gearSets[setName] = RC.DeepCopy(setData)
                    found = found + 1
                end
            end
        end

        if found == 0 then return 0 end

        local from  = GetMyLabel()
        local msgId = NextMsgId()
        local token = GetToken()
        local target = NormalizeName(targetCharName)
        if not target then return 0 end
        local msgs  = ChunkForTarget(payload, from, msgId, token, "PUSH_gearSets", target)
        if not msgs then return 0 end
        EnqueueMessages(msgs, target)

        -- The target applies what we sent and then broadcasts it back as its
        -- own gearSets. Ignore inbound gear sets from that character for a
        -- minute so our own push does not return and overwrite later edits.
        MS._suppressGearSetInbound = MS._suppressGearSetInbound or {}
        MS._suppressGearSetInbound[charKey] = GetTime() + 60

        if rwEntry and rwEntry.pendingPush then
            for _, setName in ipairs(rwEntry.pendingPush) do
                local edited = rwEntry.localEdits and rwEntry.localEdits[setName]
                if edited then
                    rwEntry.gearSets = rwEntry.gearSets or {}
                    rwEntry.gearSets[setName] = RC.DeepCopy(edited)
                end
            end
            rwEntry.pendingPush = {}
        end

        if not silent then
            local dest = targetLabel or targetCharName
            LogActivity("Pushed " .. found .. " gear set(s) to " .. dest)
            RC:Print(RCL["Mesh: Pushed "] .. found .. RCL[" gear set(s) to "] .. dest .. "")
            local ns = NormalizeName(targetCharName)
            if ns then self:Broadcast(CMD_PUSH_DONE, found .. " Gear Set(s)", ns) end
        end
        return #msgs
    end

    -- Deletions cannot ride the normal gearSets merge (ApplyInbound only
    -- ever adds), so they are queued per character and delivered as their
    -- own PUSH_gearSetDeletes, immediately if the target is online.
    function MS:QueueNetworkGearDelete(setName, targetCharKey)
        if not _mss.cfg then return end
        ReadycheckDB.remoteGearDeletes = ReadycheckDB.remoteGearDeletes or {}
        local queued = {}

        local function enqueueFor(charKey, displayName)
            if not charKey then return end
            ReadycheckDB.remoteGearDeletes[charKey] =
                ReadycheckDB.remoteGearDeletes[charKey] or {}
            local already = false
            for _, n in ipairs(ReadycheckDB.remoteGearDeletes[charKey]) do
                if n == setName then already = true; break end
            end
            if not already then
                table_insert(ReadycheckDB.remoteGearDeletes[charKey], setName)
                queued[#queued+1] = displayName or charKey
            end
        end

        if targetCharKey then
            local norm = NormalizeName(targetCharKey)
            local lbl = norm
            if _mss.cfg.members then
                for _, member in ipairs(_mss.cfg.members) do
                    if NormalizeName(member.name) == norm then
                        lbl = member.label or norm; break
                    end
                end
            end
            enqueueFor(norm, lbl)

            if _mss.isEnabled and norm then
                local onlineCharName = nil
                for _, info in pairs(knownAccounts) do
                    if info.online and info.charName
                            and NormalizeName(info.charName) == norm then
                        onlineCharName = info.charName; break
                    end
                end
                if onlineCharName then
                    MS:PushQueuedGearDeletes(norm, onlineCharName, lbl)
                    if #queued > 0 then
                        RC:Print(RCL["Mesh: Deleted '"] .. setName ..
                            RCL["' from "] .. lbl .. ".")
                    end
                    return
                end
            end
        else
            if not _mss.cfg.members then return end
            for _, member in ipairs(_mss.cfg.members) do
                enqueueFor(NormalizeName(member.name), member.label or member.name)
            end
        end

        if #queued > 0 then
            RC:Print(RCL["Mesh: Queued deletion of '"] .. setName ..
                RCL["' for "] .. table_concat(queued, ", ") ..
                RCL[" - will apply when they next log in."])
        end
    end

    function MS:PushQueuedGearDeletes(charKey, targetCharName, targetLabel)
        if not _mss.isEnabled then return end
        local pending = ReadycheckDB.remoteGearDeletes
                     and ReadycheckDB.remoteGearDeletes[charKey]
        if not pending or #pending == 0 then return end

        local payload    = { delete = pending }
        local from  = GetMyLabel()
        local msgId = NextMsgId()
        local token = GetToken()
        local target = NormalizeName(targetCharName)
        if not target then return end
        local msgs  = ChunkForTarget(payload, from, msgId, token, "PUSH_gearSetDeletes", target)
        if not msgs then return end
        EnqueueMessages(msgs, target)
        ReadycheckDB.remoteGearDeletes[charKey] = {}
        RC:DebugPrint("MeshSync: sent " .. #pending .. " gear delete(s) to " ..
            (targetLabel or targetCharName), "meshsync")
    end

    function MS:QueueNetworkTrinketPush(charKey, config, label)
        if not _mss.cfg then return end
        local norm = NormalizeName(charKey)
        if not norm then return end
        ReadycheckDB.remoteTrinketPush = ReadycheckDB.remoteTrinketPush or {}
        ReadycheckDB.remoteTrinketPush[norm] = {
            config      = RC.DeepCopy(config),
            pendingPush = true,
            label       = label or norm,
        }
        if _mss.isEnabled then
            for _, info in pairs(knownAccounts) do
                if info.online and info.charName
                        and NormalizeName(info.charName) == norm then
                    MS:PushQueuedTrinketConfig(norm, info.charName, info.label or label or norm)
                    return
                end
            end
        end
        RC:Print(RCL["Mesh: Trinket swap config queued for "]
            .. (label or norm) .. RCL[" - will send when they log in."])
    end

    function MS:PushQueuedTrinketConfig(charKey, targetCharName, targetLabel)
        if not _mss.isEnabled then return end
        local pending = ReadycheckDB.remoteTrinketPush
                     and ReadycheckDB.remoteTrinketPush[charKey]
        if not pending or not pending.pendingPush or not pending.config then return end

        local payload    = { trinketSwap = pending.config }
        local from  = GetMyLabel()
        local msgId = NextMsgId()
        local token = GetToken()
        local target = NormalizeName(targetCharName)
        if not target then return end
        local msgs  = ChunkForTarget(payload, from, msgId, token, "PUSH_trinketSwap", target)
        if not msgs then return end
        EnqueueMessages(msgs, target)
        ReadycheckDB.remoteTrinketPush[charKey].pendingPush = false
        local dest = targetLabel or targetCharName
        LogActivity("Pushed trinket swap config to " .. dest)
        RC:Print(RCL["Mesh: Pushed trinket swap config to "] .. dest .. "")
        local ns = NormalizeName(targetCharName)
        if ns then self:Broadcast(CMD_PUSH_DONE, "trinketSwap", ns) end
    end

    -- DEAD CHANNEL, kept only as a stub: nothing in the addon ever WRITES
    -- ReadycheckDB.remoteReminderPush, so this could never fire - the
    -- remote-reminder-editing feature it was built for never shipped its
    -- sender side. The queue drains in ApplySameAccountSync and the
    -- login-sync hook were removed with it; PM_Cleanup still prunes any
    -- stale table from old installs.
    function MS:PushQueuedReminders()
    end

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_LOGIN")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:RegisterEvent("BN_CHAT_MSG_ADDON")
    frame:RegisterEvent("CHAT_MSG_BN_WHISPER")
    frame:RegisterEvent("CHAT_MSG_CHANNEL_JOIN")
    frame:RegisterEvent("CHAT_MSG_CHANNEL_LEAVE")
    frame:RegisterEvent("CHANNEL_UI_UPDATE")
    frame:RegisterEvent("PLAYER_LOGOUT")

    frame:SetScript("OnEvent", function(self, event, ...)
        if event == "PLAYER_LOGIN" then
            if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
                local ok = C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
                if not ok then
                    C_Timer.After(2, function()
                        C_ChatInfo.RegisterAddonMessagePrefix(ADDON_PREFIX)
                    end)
                end
            end

            -- Hide the BNet bridge from chat. Without this filter every
            -- cross-faction message shows up as a visible whisper, in both
            -- directions.
            if ChatFrame_AddMessageEventFilter and not MS._whisperFilterAdded then
                MS._whisperFilterAdded = true
                local function RCWhisperFilter(_, _, m)
                    if m and m:sub(1, 7) == "RCMESH:" then return true end
                    return false
                end
                ChatFrame_AddMessageEventFilter("CHAT_MSG_BN_WHISPER", RCWhisperFilter)
                ChatFrame_AddMessageEventFilter("CHAT_MSG_BN_WHISPER_INFORM", RCWhisperFilter)
            end

            -- Login staging, all inside one callback so the ORDER is code,
            -- not wall-clock luck: config first, then the same-account
            -- snapshot apply, and only THEN broadcast hashes + HELLOs +
            -- poll ticker. The apply used to run on its own timer 5s after
            -- the HELLOs went out, which left a ~5s window where this
            -- character pushed pre-handoff (stale) data to the mesh, and
            -- then overwrote fresher wire data with the older snapshot.
            -- (Relative timers that remain: gear cache at +6s, remote-edit
            -- restore at +8s - both pure consumers.)
            C_Timer.After(3.5, function()
                -- Rebuild BEFORE InitConfig: InitConfig prunes every saved
                -- Send/Receive flag whose category id is not in
                -- SYNC_CATEGORIES, so pruning against a partial list would
                -- silently wipe the user's sync rules.
                if #MS.SYNC_CATEGORIES <= 2 then RebuildSyncCategories() end

                MS:InitConfig()

                if RC.db and RC.db.raidProfiles then
                    for _, raidData in pairs(RC.db.raidProfiles) do
                        if type(raidData) == "table" and raidData.profiles then
                            for _, pd in pairs(raidData.profiles) do
                                if type(pd) == "table" then
                                    if pd.bosses == nil then pd.bosses = {} end
                                    if pd.trash  == nil then pd.trash  = {} end
                                end
                            end
                        end
                    end
                end

                if _mss.cfg and GetCharEnabled() then
                    _mss.isEnabled  = true
                    _mss._enabledAt = GetTime()
                    -- Snapshots from other alts land BEFORE this session
                    -- hashes its state or answers a single HELLO, so what
                    -- the mesh sees from this character is post-handoff.
                    MS:ApplySameAccountSync()
                    JoinDiscoveryChannel()
                    InitBroadcastHashes()
                    -- One HELLO per second, one member at a time. A burst at
                    -- login is exactly when the client is most likely to
                    -- throttle, and a dropped HELLO costs a full sync cycle.
                    local members = _mss.cfg.members or {}
                    for i, member in ipairs(members) do
                        C_Timer.After(i - 1, function()
                            if not _mss.isEnabled then return end
                            local target = NormalizeName(member.name)
                            if target then
                                MS:Broadcast(CMD_HELLO, BuildHelloData(), target)
                                -- CAP RIDES WITH EVERY HELLO. Without it
                                -- the RC2 codec never negotiates: this
                                -- path only ever sent HELLO, and CAP was
                                -- emitted from the HELLO-*reply* path,
                                -- which is gated on freshAnnounce. Two
                                -- peers who still have each other marked
                                -- online - anything inside the 300s
                                -- ACCOUNT_TIMEOUT, so any brief relog -
                                -- therefore never learn each other's
                                -- PROTO_VERSION and fall back to the
                                -- uncompressed RC1 literal codec for the
                                -- whole session. On this machine's real
                                -- data that is 1,733 chunks instead of
                                -- 172, which in an instance is 29 minutes
                                -- instead of 3.
                                MS:Broadcast(_mss.CMD_CAP,
                                    tostring(_mss.PROTO_VERSION or 1), target)
                            end
                        end)
                    end
                    _mss.lastHelloTime = GetTime()
                    LogActivity("Mesh Network started - pinging " .. #members .. " member(s)")
                    _mss.StartPollTicker()
                end

                if RC.Profiler then
                    RC.Profiler:TrackTicker("MeshSync_Maint", MAINT_INTERVAL, Maintenance)
                else
                    C_Timer.NewTicker(MAINT_INTERVAL, Maintenance)
                end

                -- Mesh disabled on this character: still run the apply so
                -- per-character queues (gear deletes, trinket pushes) drain
                -- and the consumed-ledger logic stays in one place. The
                -- snapshot loop itself no-ops while not enabled, on purpose.
                if not _mss.isEnabled then
                    MS:ApplySameAccountSync()
                end

                C_Timer.After(8, function()
                    local session = ReadycheckDB and ReadycheckDB.remoteEditSession
                    if not session or session.memberName == "" then return end
                    local cached = ReadycheckDB.remoteRaidConfigs
                               and ReadycheckDB.remoteRaidConfigs[session.charKey]
                               and ReadycheckDB.remoteRaidConfigs[session.charKey][session.raidKey]
                    if not (cached and cached.data) then return end
                    if not RC.EnterRemoteEditMode then return end
                    local member = { name = session.memberName, label = session.memberLabel }
                    RC:EnterRemoteEditMode(member, session.raidKey, cached.data)
                    RC:DebugPrint("MeshSync: restored remote edit session for " ..
                        session.raidKey .. " / " .. session.memberLabel, "meshsync")
                end)

                C_Timer.After(6, function()
                    local myKey = GetToonKey()
                    if not myKey or not RC.db then return end
                    ReadycheckDB.meshSyncGearCache = ReadycheckDB.meshSyncGearCache or {}
                    local items = {}
                    for bag = 0, 4 do
                        local numS = C_Container and C_Container.GetContainerNumSlots(bag) or 0
                        for s = 1, numS do
                            local info = C_Container.GetContainerItemInfo(bag, s)
                            if info and info.itemID then
                                local _, _, _, _, _, _, _, _, eqLoc, icon = GetItemInfo(info.itemID)
                                if eqLoc and eqLoc ~= "" and eqLoc ~= "INVTYPE_NON_EQUIP" then
                                    local lnk = C_Container.GetContainerItemLink(bag, s)
                                    local nm  = GetItemInfo(info.itemID) or ("item:"..info.itemID)
                                    items[#items+1] = { id=info.itemID, link=lnk, name=nm,
                                                        icon=icon, equipLoc=eqLoc }
                                end
                            end
                        end
                    end
                    for slot = 1, 19 do
                        local itemId = GetInventoryItemID and GetInventoryItemID("player", slot)
                        if itemId then
                            local nm, _, _, _, _, _, _, _, eqLoc, icon = GetItemInfo(itemId)
                            if nm then
                                items[#items+1] = {
                                    id = itemId,
                                    link = GetInventoryItemLink and GetInventoryItemLink("player", slot),
                                    name = nm, icon = icon, equipLoc = eqLoc,
                                    equipped = true, slot = slot,
                                }
                            end
                        end
                    end
                    ReadycheckDB.meshSyncGearCache[myKey] = {
                        label          = GetMyLabel() or (UnitName("player") or myKey),
                        charName       = UnitName("player") or myKey,
                        level          = UnitLevel("player") or 0,
                        gearSets       = RC.DeepCopy and RC.DeepCopy(RC.db.gearSets or {}) or {},
                        availableItems = items,
                        cachedAt       = time(),
                    }
                    RC:DebugPrint("Gear cache written for " .. myKey ..
                        " (" .. #items .. " items)", "meshsync")
                end)
            end)

        elseif event == "CHAT_MSG_ADDON" then
            if not _mss.cfg then return end
            local prefix, msgText, distType, sender = ...
            if prefix ~= ADDON_PREFIX then return end
            -- Cross-faction leg one: a base64 addon YELL heard by nearby
            -- players of either faction. Flagged cross-faction on dispatch,
            -- which keeps that peer out of the chunked fanout.
            if distType == "YELL" or distType == "SAY" then
                if not _mss.cfg.crossFaction then return end
                local decoded = RC:DecodeBase64ForSettings(msgText)
                if not decoded or decoded == "" then return end
                RC:DebugPrint("CHAT_MSG_ADDON: YELL inbound from " .. tostring(sender), "meshsync")
                MS:OnChatMessage(decoded, sender, true)
            else
                MS:OnChatMessage(msgText, sender)
            end

        elseif event == "BN_CHAT_MSG_ADDON" then
            if not _mss.cfg or not _mss.cfg.crossFaction then return end
            local prefix, msgText, _, senderID = ...
            if prefix ~= ADDON_PREFIX then return end
            RC:DebugPrint("BN_CHAT_MSG_ADDON: RCMESH inbound senderID=" .. tostring(senderID), "meshsync")
            -- Resolve the game account to Name-Realm so this peer merges with
            -- its same-faction identity; the "bnet-<id>" fallback leaves a
            -- peer nothing can whisper or match to the roster.
            local name
            if C_BattleNet and C_BattleNet.GetGameAccountInfoByID and senderID then
                local ga = C_BattleNet.GetGameAccountInfoByID(senderID)
                if ga and ga.characterName and ga.characterName ~= "" then
                    name = ga.characterName
                    if ga.realmName and ga.realmName ~= "" then
                        name = name .. "-" .. (ga.realmName:gsub("%s+", ""))
                    end
                end
            end
            RC:DebugPrint("BN_CHAT_MSG_ADDON: dispatch as " .. tostring(name or ("bnet-" .. tostring(senderID))), "meshsync")
            -- Numeric viaBNet marks a real cross-faction leg downstream; a
            -- bare true is what same-faction YELL copies carry.
            MS:OnChatMessage(msgText, name or ("bnet-" .. tostring(senderID)), senderID or true)

        elseif event == "CHAT_MSG_BN_WHISPER" then
            if not _mss.cfg or not _mss.cfg.crossFaction then return end
            -- Cross-faction leg two: the whisper bridge. "RCMESH:" prefix,
            -- base64 body, always one message. Arg 13 is the sender's
            -- bnetAccountID, which the reply path needs.
            local wmsg, wauthor = ...
            if not wmsg or wmsg:sub(1, 7) ~= "RCMESH:" then return end
            local decoded = RC:DecodeBase64ForSettings(wmsg:sub(8))
            if not decoded or decoded == "" then return end
            local bnSenderID = select(13, ...)
            RC:DebugPrint("CHAT_MSG_BN_WHISPER: cross-faction inbound from " .. tostring(wauthor)
                .. " bnetId=" .. tostring(bnSenderID), "meshsync")
            MS:OnChatMessage(decoded, wauthor, bnSenderID or true)

        elseif event == "CHAT_MSG_CHANNEL_JOIN" then
            if not _mss.cfg or not _mss.isEnabled or _mss.cfg.discoveryChannel == "" then return end
            -- Discovery channel joins are the fast path to noticing a peer
            -- not yet on the roster. Arg 2 is the joiner, arg 9 the channel.
            -- The delay lets their addon load before the HELLO lands.
            local args = {...}
            local senderName = args[2] or ""
            local channelName = args[9]
            if type(channelName) ~= "string" then return end
            if channelName:lower() ~= _mss.cfg.discoveryChannel:lower() then return end
            local myName = UnitName("player")
            if senderName ~= "" and senderName ~= myName then
                local target = NormalizeName(senderName)
                -- Same 25s per-peer gate as the HELLO reply path, plus a
                -- spread, so a channel-wide reconnect does not fire one
                -- greeting per member in the same frame.
                local gate = _mss.lastHelloResponseTo
                if target and gate and not (gate[target] and (GetTime() - gate[target]) < 25) then
                    gate[target] = GetTime()
                    C_Timer.After(0.3 + math.random() * 3, function()
                        if _mss.isEnabled then
                            MS:Broadcast(CMD_HELLO, BuildHelloData(), target)
                            MS:Broadcast(_mss.CMD_CAP,
                                tostring(_mss.PROTO_VERSION or 1), target)
                        end
                    end)
                end
            end

        elseif event == "CHAT_MSG_CHANNEL_LEAVE" then
            if not _mss.cfg or not _mss.isEnabled or _mss.cfg.discoveryChannel == "" then return end
            local args = {...}
            local senderName = args[2] or ""
            local channelName = args[9]
            if type(channelName) ~= "string" then return end
            if channelName:lower() ~= _mss.cfg.discoveryChannel:lower() then return end
            local normLeaver = NormalizeName(senderName)
            if normLeaver then
                for label, info in pairs(knownAccounts) do
                    if info.charName and NormalizeName(info.charName) == normLeaver then
                        info.online = false
                        LogActivity(label .. " left the channel")
                        MS:RefreshMeshUI()
                        break
                    end
                end
            end

        elseif event == "CHANNEL_UI_UPDATE" then
            if _mss.cfg and _mss.cfg.discoveryChannel ~= "" then
                HideChannelFromChat(_mss.cfg.discoveryChannel)
            end

        elseif event == "PLAYER_LOGOUT" then
            -- Unwrap the remote-edit hooks FIRST. While installed,
            -- GetAllGearSets and SaveConfigurationToProfile answer for the
            -- character being edited, not for this one.
            if RC._remoteEditGearSetWrapped and RC._origGetAllGearSets then
                RC.GetAllGearSets            = RC._origGetAllGearSets
                RC._origGetAllGearSets       = nil
                RC._remoteEditGearSetWrapped = nil
            end
            if RC._remoteEditSaveWrapped and RC._origSaveConfig then
                RC.SaveConfigurationToProfile = RC._origSaveConfig
                RC._origSaveConfig            = nil
                RC._remoteEditSaveWrapped     = nil
            end

            if _mss.isEnabled then
                local kc = _mss.knownChars
                if kc and C_ChatInfo and C_ChatInfo.SendAddonMessage and not RC:AddonMessagesBlocked() then
                    local msgs = ChunkData("", GetMyLabel(), NextMsgId(), GetToken(), CMD_BYE)
                    local m = msgs and msgs[1]
                    if m then
                        -- Best effort: the client is already tearing down, so
                        -- BYE goes only to chars seen inside ACCOUNT_TIMEOUT
                        -- and stops at 8 (the throttle allowance). Peers that
                        -- miss it just time out.
                        local nowUp = GetTime()
                        local tmo = _mss.ACCOUNT_TIMEOUT or 300
                        local sent = 0
                        for charName, rec in pairs(kc) do
                            if rec.seenAt and (nowUp - rec.seenAt) <= tmo then
                                C_ChatInfo.SendAddonMessage(ADDON_PREFIX, m, "WHISPER", charName)
                                sent = sent + 1
                                if sent >= 8 then break end
                            end
                        end
                    end
                end
                MS:WriteSameAccountSync()
            end
            local rem = RC.remoteEditMode
            if rem then
                local cur = RC._remoteEditData
                if cur then
                    local ck = NormalizeName(rem.member.name or "")
                    if ck then
                        ReadycheckDB = ReadycheckDB or {}
                        ReadycheckDB.remoteRaidConfigQueue = ReadycheckDB.remoteRaidConfigQueue or {}
                        ReadycheckDB.remoteRaidConfigQueue[ck] = {
                            raidKey  = rem.raidKey,
                            data     = SlimRaidData(cur),
                            label    = rem.member.label or rem.member.name or "",
                            queuedAt = time(),
                        }
                    end
                end
                ReadycheckDB = ReadycheckDB or {}
                ReadycheckDB.remoteEditSession = {
                    memberName  = rem.member.name  or "",
                    memberLabel = rem.member.label or rem.member.name or "",
                    raidKey     = rem.raidKey,
                    charKey     = NormalizeName(rem.member.name or "") or "",
                }
            else
                if ReadycheckDB then
                    ReadycheckDB.remoteEditSession = nil
                end
            end
        end
    end)

    -- The snapshot payload comes from _mss.BuildCategoryPayload in
    -- Mesh_Proto - the SAME builder MS:Push ships over the wire. This file
    -- used to carry its own hand-copied builder and the two drifted: the
    -- snapshot's raidProfiles dragged raidRoute.runtime and unknown raid
    -- keys along, and its executeCalc ignored the history watermark.

    -- Same-account snapshot store shape: state[toonKey][categoryId] = entry.
    -- Older builds used one flat slot per category (state[categoryId]),
    -- which made every alt's logout overwrite every other alt's snapshot -
    -- with three or more characters, whoever logged out last won and the
    -- others' unconsumed changes were silently lost. Entries migrate in
    -- place; the shapes are distinguishable because old entries carry
    -- .fromChar/.data directly (and old keys are category ids, which never
    -- contain "-"), while new outer values are plain per-character tables.
    local function MigrateSameAccountState()
        ReadycheckDB.meshSameAccountState = ReadycheckDB.meshSameAccountState or {}
        local state = ReadycheckDB.meshSameAccountState
        local old = nil
        for k, v in pairs(state) do
            if type(v) == "table" and v.fromChar and v.data ~= nil then
                old = old or {}
                old[k] = v
            end
        end
        -- Collected first: Lua 5.1 forbids adding keys mid-traversal.
        if old then
            local moved = 0
            for k, v in pairs(old) do
                state[k] = nil
                local src = v.fromChar
                if type(state[src]) ~= "table" then state[src] = {} end
                state[src][k] = v
                moved = moved + 1
            end
            RC:DebugPrint("Same-account sync: migrated " .. moved
                .. " snapshot(s) to per-character storage", "mesh")
        end
        return state
    end

    local sameAcctAppliedOnce = false

    -- Characters not played in this long get their snapshots dropped, so
    -- the per-character store cannot grow without bound on alt-heavy
    -- accounts. Two months comfortably covers a parked alt.
    local SNAPSHOT_PRUNE_AFTER = 60 * 86400

    -- Writes this character's snapshots into the shared ReadycheckDB at
    -- logout.
    function MS:WriteSameAccountSync()
        if not _mss.cfg then return end
        if not sameAcctAppliedOnce then
            -- PLAYER_LOGOUT: C_Timer callbacks never run during client
            -- teardown, so the old "defer via a 6s timer" recovery was a
            -- no-op and a logout or /reload inside the first seconds of a
            -- session silently discarded the whole session's changes for
            -- every alt. Run the apply inline, then write.
            RC:DebugPrint("Same-account sync: login apply had not run - applying inline before write", "mesh")
            MS:ApplySameAccountSync()
        end
        local state   = MigrateSameAccountState()
        local toonKey = GetToonKey()
        local mine    = state[toonKey]
        if type(mine) ~= "table" then mine = {}; state[toonKey] = mine end

        local BuildPayload = _mss.BuildCategoryPayload
        local _wrote, _ruleOff, _noData, _unchanged = 0, 0, 0, 0
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            if cat.id == "gearSets" then
                -- Gear sets never snapshot between alts (same set names,
                -- different gear); also drops any slot an older build left.
                mine[cat.id] = nil
            elseif not (_mss.charCfg and _mss.charCfg.syncCategories and _mss.charCfg.syncCategories[cat.id]) then
                -- Unticking Send removes the snapshot this character left
                -- behind, or alts keep applying data it no longer shares.
                mine[cat.id] = nil
                _ruleOff = _ruleOff + 1
            else
                local raw = BuildPayload and BuildPayload(cat.id, { history = "full" })
                if not raw then
                    mine[cat.id] = nil
                    _noData = _noData + 1
                else
                    -- Only restamp savedAt when the content actually
                    -- changed - compared against THIS character's previous
                    -- snapshot. The old flat store deleted its own entries
                    -- before comparing, so the guard compared against
                    -- nothing, savedAt bumped on every logout, and every
                    -- alt re-applied identical data on every login.
                    local newHash  = QuickHash(raw)
                    local existing = mine[cat.id]
                    if existing and existing.hash == newHash then
                        existing.v = 2
                        _unchanged = _unchanged + 1
                    else
                        mine[cat.id] = {
                            data     = RC.DeepCopy(raw),
                            fromChar = toonKey,
                            savedAt  = time(),
                            hash     = newHash,
                            v        = 2,
                        }
                        _wrote = _wrote + 1
                    end
                end
            end
        end

        -- GC: drop snapshot sets from characters idle past the horizon,
        -- and ledger rows whose source character no longer has snapshots.
        -- Idleness is the last logout write, not savedAt: an active alt
        -- whose settings never change would otherwise look parked.
        local now = time()
        mine._lastWrite = now
        for charKey, cats in pairs(state) do
            if charKey ~= toonKey and type(cats) == "table" then
                local newest = tonumber(cats._lastWrite) or 0
                if newest == 0 then
                    for _, e in pairs(cats) do
                        if type(e) == "table" and (e.savedAt or 0) > newest then
                            newest = e.savedAt
                        end
                    end
                end
                if newest == 0 or (now - newest) > SNAPSHOT_PRUNE_AFTER then
                    state[charKey] = nil
                end
            end
        end
        local ledger = ReadycheckDB.meshSameAccountLastApplied
        if type(ledger) == "table" then
            for k in pairs(ledger) do
                local src = string_match(k, "^(.*):[^:]+$")
                if src and not state[src] then ledger[k] = nil end
            end
        end

        RC:DebugPrint(string_format(
            "[Readycheck] Same-account snapshot for %s: %d written, %d rule-off, %d no-data, %d unchanged",
            toonKey, _wrote, _ruleOff, _noData, _unchanged), "mesh")
        if _wrote > 0 and not MS._wroteAnnounced then
            MS._wroteAnnounced = true
            RC:DebugPrint("Same-account sync: first snapshot this session ("
                .. _wrote .. " written)", "mesh")
        end
    end

    -- Drops this character's own snapshot slot (MS:Disable calls this), so
    -- alts stop consuming data from a character that opted out of the mesh.
    function MS:ClearOwnSameAccountSnapshot()
        if not (ReadycheckDB and ReadycheckDB.meshSameAccountState) then return end
        local state = MigrateSameAccountState()
        state[GetToonKey()] = nil
    end

    -- Login half of the same-account handoff. Alts share ReadycheckDB, so
    -- this reads snapshots left by other characters and any per-character
    -- queues (deletes, trinket and reminder pushes) addressed to this toon.
    -- No wire traffic at all, but ApplyInbound is still the only gate on
    -- Receive rules.
    function MS:ApplySameAccountSync()
        if not _mss.cfg then return end
        sameAcctAppliedOnce = true
        local toonKey = GetToonKey()

        -- Same gate as the wire path: gear deletes stay queued (not
        -- consumed) while mesh is off or Receive for gear sets is off.
        local recvRules = _mss.charCfg and _mss.charCfg.recvCategories
        local gearRecvOk = _mss.isEnabled
            and not (recvRules and recvRules.gearSets == false)
        local myDeletes = gearRecvOk and ReadycheckDB.remoteGearDeletes
                       and ReadycheckDB.remoteGearDeletes[toonKey]
        if myDeletes and #myDeletes > 0 then
            local deleted = {}
            for _, setName in ipairs(myDeletes) do
                if type(setName) == "string" and setName ~= "" then
                    if RC.GearManager and RC.GearManager.sets then
                        RC.GearManager.sets[setName] = nil
                    end
                    if RC.db and RC.db.gearSets then
                        RC.db.gearSets[setName] = nil
                    end
                    deleted[#deleted+1] = setName
                end
            end
            ReadycheckDB.remoteGearDeletes[toonKey] = {}
            if #deleted > 0 then
                RC:SaveConfigurationToProfile()
                RC:Print(RCL["Mesh: Deleted "] .. #deleted ..
                    RCL[" gear set(s) from another warrior: "] .. table_concat(deleted, ", "))
            end
        end

        local myTrinket = ReadycheckDB.remoteTrinketPush
                       and ReadycheckDB.remoteTrinketPush[toonKey]
        if myTrinket and myTrinket.pendingPush and myTrinket.config then
            self:ApplyInbound("trinketSwap", { trinketSwap = myTrinket.config },
                myTrinket.label or "same-account", false)
            myTrinket.pendingPush = false
        end

        -- (remoteReminderPush drain removed: nothing ever wrote that
        -- queue - see the PushQueuedReminders stub.)

        if not ReadycheckDB.meshSameAccountState then return end
        local state   = MigrateSameAccountState()
        ReadycheckDB.meshSameAccountLastApplied =
            ReadycheckDB.meshSameAccountLastApplied or {}
        -- One-time repair. Earlier builds stamped this ledger for snapshots
        -- they never applied (the receive check read the Send table), so every
        -- affected category looks permanently consumed and would stay dead even
        -- with the logic fixed. Clear it once so those snapshots can land.
        if not ReadycheckDB.meshSameAcctLedgerReset then
            ReadycheckDB.meshSameAcctLedgerReset = true
            ReadycheckDB.meshSameAccountLastApplied = {}
            RC:DebugPrint("Same-account sync: cleared stale applied-ledger (one-time repair)", "mesh")
        end
        local lastApplied = ReadycheckDB.meshSameAccountLastApplied
        local applied = {}

        -- Receive is governed by recvCategories (recvRules above). This used
        -- to read syncCategories - the SEND table - so a category only landed
        -- if the RECEIVING character also had Send ticked for it, which is
        -- not what either checkbox means.
        local _applied, _recvOff, _fresh = 0, 0, 0
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            -- Every OTHER character's snapshot for this category, oldest
            -- first, so each one is consumed on its own ledger row. Taking
            -- only the newest left the others unstamped and re-eligible.
            local entries = {}
            for charKey, cats in pairs(state) do
                if charKey ~= toonKey and type(cats) == "table" and not cats.fromChar then
                    local e = cats[cat.id]
                    if type(e) == "table" and e.data then
                        entries[#entries+1] = { entry = e, char = charKey }
                    end
                end
            end
            table.sort(entries, function(a, b)
                local sa, sb = a.entry.savedAt or 0, b.entry.savedAt or 0
                if sa ~= sb then return sa < sb end
                return a.char < b.char
            end)
            local labelAdded = false
            for _, item in ipairs(entries) do
                local entry, entryChar = item.entry, item.char
                local trackKey   = entryChar .. ":" .. cat.id
                local savedAt    = entry.savedAt or 0
                local lastAt     = lastApplied[trackKey] or 0
                local recvOff    = (recvRules and recvRules[cat.id] == false)
                if not _mss.isEnabled or recvOff then
                    -- Deliberately do NOT stamp lastApplied. Marking a snapshot
                    -- we never applied as consumed is what left a category dead
                    -- forever: tick Receive on later and it still looked done.
                    -- Leaving the stamp alone means the pending snapshot lands
                    -- as soon as the rule allows it.
                    entry.v = 2
                    _recvOff = _recvOff + 1
                elseif entry.v == 2 and lastAt >= savedAt then
                    _fresh = _fresh + 1
                else
                    entry.v = 2
                    if cat.id == "gearSets" then
                        -- Gear sets never auto-merge between alts of one
                        -- account (same set names, different gear). Consume
                        -- silently; explicit wire pushes still work.
                        lastApplied[trackKey] = savedAt
                    else
                        -- ApplyInbound is the single authority on receive
                        -- rules; it returns false when Receive is off. Only
                        -- record the snapshot as consumed when it truly landed.
                        if self:ApplyInbound(cat.id, entry.data,
                                entryChar or "same-account", false) then
                            if not labelAdded then
                                labelAdded = true
                                applied[#applied+1] = cat.label or cat.id
                            end
                            _applied = _applied + 1
                            lastApplied[trackKey] = savedAt
                        end
                    end
                end
            end
        end

        RC:DebugPrint(string_format(
            "Same-account apply for %s: %d applied, %d receive-off, %d already current",
            toonKey, _applied, _recvOff, _fresh), "mesh")
        if #applied == 0 then
            local haveOther = false
            for charKey, cats in pairs(state) do
                if charKey ~= toonKey and type(cats) == "table" and not cats.fromChar then
                    -- _lastWrite alone is a stamp, not a snapshot.
                    for _, e in pairs(cats) do
                        if type(e) == "table" then haveOther = true; break end
                    end
                    if haveOther then break end
                end
            end
            RC:DebugPrint(haveOther
                and "Same-account sync: up to date (nothing new)"
                or  "Same-account sync: no snapshots from other characters yet",
                "mesh")
        end
        -- No summary print here: ApplyInbound's reporter announces every
        -- applied category in chat, grouped by source character.
    end
