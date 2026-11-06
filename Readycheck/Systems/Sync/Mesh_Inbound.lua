------------------------------------------------------------------------
-- Readycheck - Mesh Inbound Dispatch
-- Every mesh message lands in MS:OnChatMessage here: token check, peer
-- bookkeeping, chunk reassembly, command dispatch. Also owns the 1s poll
-- ticker (hash change -> push) and PushRawPayload.
--
-- Command vocabulary. "1msg" = single addon message via MS:Broadcast and
-- must fit 255 bytes; only PUSH_ commands are chunked.
--   HELLO      1msg  heartbeat: uptime, category digest, history watermark
--   BYE        1msg  leaving; peer marked offline, its send queue dropped
--   CAP        1msg  peer PROTO_VERSION, gates the compressed RC2 codec
--   ACK        1msg  per-msgId receipt; accepted and discarded
--   SYNC_TOTAL 1msg  declared packet count for a large transfer
--   PUSH_DONE  1msg  comma list of category labels just sent
--   PUSH_ACK   1msg  "<claimed labels>||<ids that landed>", answers PUSH_DONE
--   GOLDR      1msg  discarded; nothing in the addon sends it
--   WBUFF/WBREL/WBDEL/WBONY  1msg  world buff state, relay, removal, enemy Onyxia
--   WBTIME/WBYELL            1msg  world buff timer digest, pull-timer yell
--   REQ_<cat>  1msg  ask a peer to push that category back
--   PUSH_<cat> CHUNKED payload. "~PARTIAL" merges instead of replacing;
--             "~CLASS:x"/"~CHAR:x" make the receiver drop it unless it matches
--
-- Order in OnChatMessage is load bearing: parse, token, self-echo, CAP,
-- the isEnabled gate (only HELLO and BYE pass while the mesh is off), peer
-- bookkeeping, then commands. Roster and Accept-From checks are NOT here -
-- they run at the apply site, after reassembly.
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
local ACCOUNT_TIMEOUT, BUFFER_TIMEOUT, BroadcastToAllMembers, BuildHelloData, CMD_ACK, CMD_BYE, CMD_HELLO, CMD_PUSH_DONE =
      _mss.ACCOUNT_TIMEOUT, _mss.BUFFER_TIMEOUT, _mss.BroadcastToAllMembers, _mss.BuildHelloData, _mss.CMD_ACK, _mss.CMD_BYE, _mss.CMD_HELLO, _mss.CMD_PUSH_DONE
local CheckRecvSessionDone, ChunkData, Deserialize, EnqueueMessages, GetCategoryHash, GetCharEnabled, GetMyLabel, GetToken =
      _mss.CheckRecvSessionDone, _mss.ChunkData, _mss.Deserialize, _mss.EnqueueMessages, _mss.GetCategoryHash, _mss.GetCharEnabled, _mss.GetMyLabel, _mss.GetToken
local ChunkForTarget, DecodeWire, CMD_CAP, PROTO_VERSION, peerProto =
      _mss.ChunkForTarget, _mss.DecodeWire, _mss.CMD_CAP, _mss.PROTO_VERSION, _mss.peerProto
local GetToonKey, HELLO_INTERVAL, JoinDiscoveryChannel, KNOWN_RAID_KEYS, LeaveDiscoveryChannel, LogActivity, MAX_MESH_MEMBERS, NextMsgId =
      _mss.GetToonKey, _mss.HELLO_INTERVAL, _mss.JoinDiscoveryChannel, _mss.KNOWN_RAID_KEYS, _mss.LeaveDiscoveryChannel, _mss.LogActivity, _mss.MAX_MESH_MEMBERS, _mss.NextMsgId
local NormalizeName, POLL_SAFETY_RESCAN, PUSH_INFLIGHT_WINDOW, ParsePeerHashes, QuickHash, RP, SEND_INTERVAL, Serialize =
      _mss.NormalizeName, _mss.POLL_SAFETY_RESCAN, _mss.PUSH_INFLIGHT_WINDOW, _mss.ParsePeerHashes, _mss.QuickHash, _mss.RP, _mss.SEND_INTERVAL, _mss.Serialize
local SessionTotal, SlimRouteCfg, StripGearFromBoss, StripGearFromRaid, UpdateRecvRow, _badTokenWarnedAt, _lastBroadcastHash, _receivedRaidConfirmPrinted =
      _mss.SessionTotal, _mss.SlimRouteCfg, _mss.StripGearFromBoss, _mss.StripGearFromRaid, _mss.UpdateRecvRow, _mss._badTokenWarnedAt, _mss._lastBroadcastHash, _mss._receivedRaidConfirmPrinted
local inboundBuffers, knownAccounts, knownChars, lastHelloResponseTo, pushInflight, recvSessions =
      _mss.inboundBuffers, _mss.knownAccounts, _mss.knownChars, _mss.lastHelloResponseTo, _mss.pushInflight, _mss.recvSessions
local reqLastAt = {}
local ApplyPayloadStrips, KeyIncluded =
      _mss.ApplyPayloadStrips, _mss.KeyIncluded
    -- Chunked send of an arbitrary table as PUSH_<cmdSuffix>, for the flows
    -- that are not plain SYNC_CATEGORIES: raid config transfers, route
    -- share, and the per-boss "raidProfiles~PARTIAL" pushes. ifTag names the
    -- specific thing being sent so two different edits are not confused for
    -- one another by the in-flight guard.
    local function PushRawPayload(cmdSuffix, payload, targetMember, silent, ifTag)
        if not _mss.cfg or not _mss.isEnabled then return nil end
        local ifKey = ((targetMember and targetMember.name) or "ALL")
            .. "|" .. cmdSuffix .. "|" .. (ifTag or "")
        local nowIF = GetTime()
        -- The in-flight guard exists to stop the SAME payload being queued
        -- twice while it is still draining. It used to key on destination
        -- alone and hold for minutes, so the first edit of a remote raid
        -- config went out and every later one was dropped as a "duplicate"
        -- until the hold expired - live editing appeared to just stop.
        -- Keying on the content means a genuinely new edit always sends,
        -- while an unchanged repeat is still suppressed.
        local sig = QuickHash(payload)
        local held = pushInflight[ifKey]
        if held and held.until_ > nowIF and held.sig == sig then
            RC:DebugPrint("MeshSync: skip duplicate push " .. cmdSuffix
                .. " (identical payload in flight)", "meshsync")
            return nil
        end
        pushInflight[ifKey] = { until_ = nowIF + PUSH_INFLIGHT_WINDOW, sig = sig }
        if ApplyPayloadStrips then
            payload = ApplyPayloadStrips(cmdSuffix, payload)
            if not payload then pushInflight[ifKey] = nil; return nil end
        end
        local from  = GetMyLabel()
        local msgId = NextMsgId()
        local token = GetToken()
        local cmd   = "PUSH_" .. cmdSuffix
        local count, nPkts
        if targetMember then
            local target = NormalizeName(targetMember.name)
            if target then
                local msgs = ChunkForTarget(payload, from, msgId, token, cmd, target)
                if not msgs then return nil end
                EnqueueMessages(msgs, target); count = 1; nPkts = #msgs
            end
        else
            local msgs = ChunkData(Serialize(payload), from, msgId, token, cmd)
            if not msgs then return nil end
            count = BroadcastToAllMembers(msgs); nPkts = #msgs
        end
        if count and count > 0 then
            -- Hold only for as long as the send actually takes to drain,
            -- plus a small margin. Anything longer blocks the next edit.
            -- CurrentSendInterval, not the constant: inside an instance the
            -- real drain is ~8x slower, and a guard computed from the fast
            -- rate expired mid-transfer and let the same payload re-queue.
            local drainRate = (_mss.CurrentSendInterval and _mss.CurrentSendInterval())
                or SEND_INTERVAL
            pushInflight[ifKey] = {
                until_ = GetTime() + ((nPkts or 1) * drainRate * count) + 15,
                sig    = sig,
            }
        else
            pushInflight[ifKey] = nil
        end
        if not silent and count and count > 0 then
            local display = cmdSuffix:gsub("~PARTIAL", " (partial)"):gsub("~[^~]+", "")
            RC:DebugPrint("MeshSync: sending " .. display .. " to " .. count .. " account(s)", "meshsync")
        end
        return nPkts or 0
    end

    -- Poll ticker body, once a second while enabled. Sends nothing unless a
    -- category was marked dirty, a peer just came online, or
    -- POLL_SAFETY_RESCAN seconds have passed since the last full scan - the
    -- rescan is the backstop for edits that never went through a hook.
    local function PollAndBroadcast()
        if not _mss.isEnabled or not _mss.cfg then return end
        if not _mss.charCfg.autoBroadcast then return end

        local now = GetTime()
        local hasOnlineTarget = false
        for _, info in pairs(knownAccounts) do
            if info.online and (now - (info.cameOnlineAt or 0)) >= 4 then
                hasOnlineTarget = true; break
            end
        end
        if not hasOnlineTarget then
            MS._hadOnlineTarget = false
            return
        end

        local justOnline = false
        if not MS._hadOnlineTarget then
            MS._hadOnlineTarget = true
            justOnline = true
        end
        local full = justOnline
            or MS._dirtyAll
            or (now - (MS._lastFullScan or 0)) >= POLL_SAFETY_RESCAN
        if not full and not MS._syncDirty then
            return
        end
        local only = nil
        if not full then
            only = MS._dirtyCats
            if not (only and next(only)) then only = nil end
        end
        MS._syncDirty = false
        MS._dirtyAll  = false
        MS._dirtyCats = nil
        MS._lastPollScan = now
        if not only then MS._lastFullScan = now end

        _mss._pollBroadcast = true
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            if _mss.charCfg.syncCategories[cat.id]
               and (not only or only[cat.id]) then
                -- Raid data is diffed per boss, per route and per profile
                -- meta block, and each changed piece goes out as its own
                -- ~PARTIAL push. Diffing the whole category would resend
                -- every raid for a single boss edit.
                if cat.id == "raidProfiles" and RC.db and RC.db.raidProfiles then
                    -- Empty branch on purpose: no raid broadcast at all while
                    -- remote edit mode is active. The edits in flight belong
                    -- to another character; the login-sync path skips
                    -- raidProfiles for the same reason.
                    if RC.remoteEditMode then
                    else
                    local _rpCatHash = GetCategoryHash(cat.id)
                    if _rpCatHash ~= (_lastBroadcastHash[cat.id] or "") then
                    for _, raidKey in ipairs(KNOWN_RAID_KEYS) do
                        local raidData = RC.db.raidProfiles[raidKey]
                        local metaKey  = "_meta_"..raidKey

                        if raidData == nil then
                            if (_lastBroadcastHash[metaKey] or "") ~= "" then
                                _lastBroadcastHash[metaKey] = ""
                                local prefix = "_boss_"..raidKey..":"
                                for k in pairs(_lastBroadcastHash) do
                                    if k:sub(1, #prefix) == prefix then _lastBroadcastHash[k] = nil end
                                end
                                local rprefix = "_route_"..raidKey..":"
                                for k in pairs(_lastBroadcastHash) do
                                    if k:sub(1, #rprefix) == rprefix then _lastBroadcastHash[k] = nil end
                                end
                            end
                        else
                            if raidData.profiles then
                                for profileName, profileData in pairs(raidData.profiles) do
                                    if profileData and type(profileData.route) == "table" then
                                        local routeKey  = "_route_"..raidKey..":"..profileName
                                        local routeHash = QuickHash(profileData.route)
                                        if routeHash ~= (_lastBroadcastHash[routeKey] or "") then
                                            local partial = {
                                                raidProfiles = {
                                                    [raidKey] = {
                                                        profiles = {
                                                            [profileName] = { route = profileData.route }
                                                        }
                                                    }
                                                }
                                            }
                                            for _, k in ipairs({"polarityMode","frostBlastConfig"}) do
                                                if RC.db[k] ~= nil then partial[k] = RC.db[k] end
                                            end
                                            partial.raidRoute = SlimRouteCfg()
                                            local nSent = PushRawPayload("raidProfiles~PARTIAL", partial, nil, nil, routeKey)
                                            if (nSent or 0) > 0 then _lastBroadcastHash[routeKey] = routeHash end
                                        end
                                    end
                                    if profileData and profileData.bosses then
                                        for bossName, bossData in pairs(profileData.bosses) do
                                            local hk   = "_boss_"..raidKey..":"..profileName..":"..bossName
                                            local hash = QuickHash(bossData)
                                            if hash ~= (_lastBroadcastHash[hk] or "") then
                                                local bdToSend = _mss.charCfg.syncRaidGear and bossData
                                                                 or StripGearFromBoss(bossData)
                                                local partial = {
                                                    raidProfiles = {
                                                        [raidKey] = {
                                                            profiles = {
                                                                [profileName] = {
                                                                    bosses = { [bossName] = bdToSend }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                                for _, k in ipairs({"polarityMode","frostBlastConfig"}) do
                                                    if RC.db[k] ~= nil then partial[k] = RC.db[k] end
                                                end
                                                partial.raidRoute = SlimRouteCfg()
                                                local nSent = PushRawPayload("raidProfiles~PARTIAL", partial, nil, nil, hk)
                                                if (nSent or 0) > 0 then _lastBroadcastHash[hk] = hash end
                                            end
                                        end
                                    end
                                end
                            end

                            local metaContent = {}
                            if raidData.profiles then
                                for pn, pd in pairs(raidData.profiles) do
                                    metaContent[pn] = { enabled = pd.enabled, trash = pd.trash }
                                end
                            end
                            local metaHash = QuickHash(metaContent)
                            if metaHash ~= (_lastBroadcastHash[metaKey] or "") then
                                local partial = { raidProfiles = { [raidKey] = { profiles = metaContent } } }
                                for _, k in ipairs({"polarityMode","frostBlastConfig"}) do
                                    if RC.db[k] ~= nil then partial[k] = RC.db[k] end
                                end
                                partial.raidRoute = SlimRouteCfg()
                                local nSent = PushRawPayload("raidProfiles~PARTIAL", partial, nil, nil, metaKey)
                                if (nSent or 0) > 0 then _lastBroadcastHash[metaKey] = metaHash end
                            end
                        end
                    end
                    local rrSlim = (not KeyIncluded
                        or KeyIncluded("raidProfiles", "raidRoute"))
                        and SlimRouteCfg() or nil
                    if rrSlim then
                        local rrHash = QuickHash(rrSlim)
                        if rrHash ~= (_lastBroadcastHash["_routeCfg"] or "") then
                            local nSent = PushRawPayload("raidProfiles~PARTIAL",
                                { raidRoute = rrSlim }, nil, nil, "_routeCfg")
                            if (nSent or 0) > 0 then
                                _lastBroadcastHash["_routeCfg"] = rrHash
                            end
                        end
                    end
                    _lastBroadcastHash[cat.id] = _rpCatHash
                    end
                    end
                else
                    local hash = GetCategoryHash(cat.id)
                    if hash ~= (_lastBroadcastHash[cat.id] or "") then
                        RC:DebugPrint("MeshSync: hash change detected for " .. cat.id, "meshsync")
                        MS:Push(cat.id, nil, nil, true, true)
                    end
                end
            end
        end
        _mss._pollBroadcast = false
    end

    -- Which categories a save from a given settings page can have touched,
    -- so a save narrows the dirty set instead of flagging every category.
    -- "colors": the page edits Appearance theme colours in place (its
    -- Look / Text tabs), which live in the colors category.
    local SIDEBAR_PAGE_CATS = {
        general_behavior    = {"general"},
        reminder_settings   = {"abilityReminders", "general", "colors"},
        font_settings       = {"fonts", "colors", "motion"},
        spec_detection      = {"specDetection"},
        stats_bar           = {"statsBar", "colors"},
        buff_pushoff        = {"buffAlert", "colors"},
        battle_shout        = {"battleShout", "battleShoutTracker", "colors"},
        raid_buff_tracker   = {"raidBuffTracker", "colors"},
        boss_debuff_tracker = {"bossDebuffTracker", "colors"},
        boon_reminder       = {"boonReminder"},
        trinkets            = {"trinketSwap", "colors"},
        gear_manager        = {"gearManager", "gearButtons", "gearSets", "colors"},
        equipment_reminder  = {"fastWeapon"},
        hotswap             = {"hotswap"},
        trinket_bar         = {"bars", "colors"},
        consumables_checker = {"consumablesChecker"},
        consumables_bar     = {"consumablesHelper", "colors"},
        potions_bar         = {"bars", "colors"},
        weapons_bar         = {"bars", "colors"},
        nameplate_auras     = {"nameplateAuras", "colors"},
        custom_reminders    = {"customReminders"},
        smart_macros        = {"smartMacros"},
        repair_reminder     = {"repairReminder"},
        mc                  = {"raidProfiles"},
        bwl                 = {"raidProfiles"},
        aq40                = {"raidProfiles"},
        naxx                = {"raidProfiles"},
        boss_notes          = {"bossNotes"},
        execute             = {"executeCalc"},
        ttk_display         = {"ttkDisplay", "colors"},
        world_buffs         = {"worldBuffs"},
        test_consumeremind  = {"consumablesHelper"},
    }
    local function InferSaveCategories()
        local f = RC.sidebarConfigFrame
        if not f or not f.IsShown or not f:IsShown() then return nil end
        local sel = RC.SidebarState and RC.SidebarState.selectedItem
        return sel and SIDEBAR_PAGE_CATS[sel] or nil
    end

    function MS:MarkCategoryDirty(catId)
        local known = false
        if catId then
            for _, cat in ipairs(MS.SYNC_CATEGORIES) do
                if cat.id == catId then known = true; break end
            end
        end
        if known then
            MS._dirtyCats = MS._dirtyCats or {}
            MS._dirtyCats[catId] = true
        else
            MS._dirtyAll = true
        end
        MS._syncDirty = true
        MS._hintArmed = GetTime()

        -- Changing a setting this character does not broadcast used to be
        -- completely silent: no push, no chat, nothing to tell you the Send
        -- box was the reason. Say so once per category per session. Skipped
        -- while applying inbound data - that is not the user editing, and
        -- the receiving character has no reason to send it back.
        if known and _mss.isEnabled and _mss.charCfg and not MS._applyingInbound then
            local sc = _mss.charCfg.syncCategories
            if sc and not sc[catId] then
                MS._sendOffHinted = MS._sendOffHinted or {}
                if not MS._sendOffHinted[catId] then
                    MS._sendOffHinted[catId] = true
                    local label = catId
                    for _, cat in ipairs(MS.SYNC_CATEGORIES) do
                        if cat.id == catId then label = cat.label or catId; break end
                    end
                    RC:Print(RCL["Mesh: you changed "] .. label
                        .. RCL[" but this character is not sending it, so it stays local. Tick Send for it on the Connection page to share it."])
                end
            end
        end
    end

    -- Accept From list, matched on the sender's ACCOUNT LABEL, not its
    -- character name. Default mode "all" accepts every roster member.
    local function RecvFromAllowed(from)
        local cc = _mss.charCfg
        if not cc or cc.recvFromMode ~= "selected" then return true end
        local allow = cc.recvFromAccounts
        return type(allow) == "table" and allow[from] == true
    end

    -- Hooks SaveConfigurationToProfile once (identity guarded, so wrappers
    -- cannot stack) and starts the 1s poll ticker. _hintArmed inside 0.5s
    -- means MarkCategoryDirty already named the category.
    _mss.StartPollTicker = function()
        if RC.SaveConfigurationToProfile
                and RC.SaveConfigurationToProfile ~= MS._saveHookFn then
            local _origSaveConfig = RC.SaveConfigurationToProfile
            MS._saveHookFn = function(selfRef, ...)
                MS._syncDirty = true
                if not (MS._hintArmed and (GetTime() - MS._hintArmed) < 0.5) then
                    local cats = InferSaveCategories()
                    if cats then
                        MS._dirtyCats = MS._dirtyCats or {}
                        for i = 1, #cats do MS._dirtyCats[cats[i]] = true end
                    else
                        MS._dirtyAll = true
                    end
                end
                MS._hintArmed = nil
                return _origSaveConfig(selfRef, ...)
            end
            RC.SaveConfigurationToProfile = MS._saveHookFn
            MS._saveHooked = true
        end
        if _mss.pollTicker then _mss.pollTicker:Cancel(); _mss.pollTicker = nil end
        if RC.Profiler then
            _mss.pollTicker = RC.Profiler:TrackTicker("MeshSync:Poll", 1.0, PollAndBroadcast)
        else
            _mss.pollTicker = C_Timer.NewTicker(1.0, PollAndBroadcast)
        end
    end

    _mss.StopPollTicker = function()
        if _mss.pollTicker then _mss.pollTicker:Cancel(); _mss.pollTicker = nil end
    end

    -- Header parse. Exactly 6 separators are consumed and everything after
    -- them is payload, so a "#" inside the data cannot shift the fields
    -- (Serialize escapes them anyway). The seq/tot bounds and the label
    -- scrub here are the only sanity checks the rest of the file relies on.
    local function ParseMessage(text)
        local marker = string_sub(text, 1, 3)
        if (marker ~= "RC1" and marker ~= "RC2") or string_sub(text, 4, 4) ~= "#" then
            return nil
        end
        local remaining = string_sub(text, 5)
        local parts = {}
        for i = 1, 6 do
            local sep = string_find(remaining, "#", 1, true)
            if not sep then return nil end
            parts[i]  = string_sub(remaining, 1, sep - 1)
            remaining = string_sub(remaining, sep + 1)
        end
        local from  = parts[1]
        local msgId = parts[2]
        local seq   = tonumber(parts[3])
        local tot   = tonumber(parts[4])
        local token = parts[5]
        local cmd   = parts[6]
        if not from or from == "" or not msgId or not seq or not tot or not token or not cmd then
            return nil
        end
        if tot < 1 or tot > 999 or seq < 1 or seq > tot then return nil end
        from = from:gsub("|", ""):gsub("%c", ""):sub(1, 15)
        if from == "" then return nil end
        return from, msgId, seq, tot, token, cmd, remaining, marker
    end

    -- Auto-discovery: a matching token is enough to join the roster, up to
    -- MAX_MESH_MEMBERS. Save is debounced - a login burst discovers several.
    local function AddToMembersIfNew(charName, label)
        if not _mss.cfg or not _mss.cfg.members or not charName or charName == "" then return false end
        local normNew = NormalizeName(charName)
        if not normNew then return false end
        for _, member in ipairs(_mss.cfg.members) do
            if NormalizeName(member.name) == normNew then
                return false
            end
        end
        if #_mss.cfg.members >= MAX_MESH_MEMBERS then
            RC:DebugPrint("MeshSync: roster at cap (" .. MAX_MESH_MEMBERS
                .. "), not auto-adding " .. tostring(charName), "meshsync")
            return false
        end
        _mss.cfg.members[#_mss.cfg.members + 1] = { name = normNew, label = label or normNew }
        if _mss._addMemberSaveTimer then _mss._addMemberSaveTimer:Cancel() end
        _mss._addMemberSaveTimer = C_Timer.After(1.0, function()
            _mss._addMemberSaveTimer = nil
            RC:SaveConfigurationToProfile()
        end)
        return true
    end

    local function IsKnownSender(sender, from)
        if from and from ~= "" and from == GetMyLabel() then return true end
        local norm = sender and NormalizeName(sender)
        if norm and _mss.cfg and _mss.cfg.members then
            for _, m in ipairs(_mss.cfg.members) do
                if m.name == norm then return true end
            end
        end
        return false
    end

    -- Roster membership gates anything that WRITES to the profile. Checked
    -- at the apply site, so an unknown sender's chunks are still buffered
    -- and reassembled before being discarded.
    local function IsRosterMemberNs(ns)
        if not ns then return false end
        if _mss.cfg and _mss.cfg.members then
            for _, m in ipairs(_mss.cfg.members) do
                if m.name == ns then return true end
            end
        end
        return false
    end

    -- =========================================================================  (called from CHAT_MSG_ADDON with prefix RCMESH)
    function MS:OnChatMessage(text, sender, viaBNet)
        local from, msgId, seq, tot, token, cmd, data, marker = ParseMessage(text)
        if not from then return end

        -- Sender has no mesh password configured. An unprotected token is
        -- not trusted from either side, so this drops before any bookkeeping.
        if token == "00000000" then return end

        -- Wrong password. Warn at most once a minute per sender, and only
        -- for someone already on the roster - a discovery channel is shared
        -- ground and strangers with other passwords are expected there.
        if token ~= GetToken() then
            if _mss.isEnabled and _mss.cfg and _mss.cfg.discoveryChannel ~= "" and IsKnownSender(sender, from) then
                local sk  = (sender and NormalizeName(sender)) or "?"
                local now = GetTime()
                if not _badTokenWarnedAt[sk] or (now - _badTokenWarnedAt[sk]) > 60 then
                    _badTokenWarnedAt[sk] = now
                    RC:Print(RCL["Mesh: Message from "] .. tostring(sender)
                        .. RCL[" rejected - Mesh Passwords don't match. All accounts must use the same password in Mesh Network Setup."])
                end
            end
            if _mss.isEnabled then
                RC:DebugPrint("MeshSync: bad token from " .. tostring(sender), "meshsync")
            end
            return
        end

        -- Self-echo. Our own YELL comes back to us, and a whisper to an alt
        -- on the same account can too. Drop by toon key before anything
        -- treats us as a peer.
        if sender then
            local myToonKey = GetToonKey()
            if myToonKey and NormalizeName(sender) == myToonKey then return end
        end

        local senderNs = sender and NormalizeName(sender)
        if marker == "RC2" and senderNs and peerProto then
            peerProto[senderNs] = 2
        end

        -- Capability exchange runs BEFORE the enabled gate: peer codec
        -- support has to be known even on a character with the mesh off, or
        -- the first push after enabling picks the wrong codec.
        if cmd == CMD_CAP then
            if senderNs and peerProto then
                peerProto[senderNs] = tonumber(data) or 1
            end
            return
        end

        -- Enabled gate. Only HELLO and BYE pass while the mesh is off here -
        -- enough to keep the peer list live and print the "sync is disabled
        -- on this character" notice, but nothing may touch the profile.
        if not _mss.isEnabled and cmd ~= CMD_HELLO and cmd ~= CMD_BYE then
            return
        end

        if RC.WorldBuffs then
            if cmd == CMD_BYE then
                if RC.WorldBuffs.OnPeerBye then RC.WorldBuffs:OnPeerBye(sender) end
            elseif RC.WorldBuffs.OnPeerSeen then
                RC.WorldBuffs:OnPeerSeen(sender, viaBNet)
            end
        end

        local nsChar   = NormalizeName(sender)
        -- Anyone we hear from is online: lift the offline-whisper backoff.
        if nsChar and _mss.MarkTargetOnline then _mss.MarkTargetOnline(nsChar) end
        local prevChar = nsChar and knownChars[nsChar]
        local wasOffline = not (prevChar
            and (GetTime() - (prevChar.seenAt or 0)) < ACCOUNT_TIMEOUT)
        if wasOffline and nsChar and not viaBNet and RC.GoldLedger then
            RC.GoldLedger:OnPeerOnline(nsChar)
        end
        -- Rebuilt from scratch on every message: any field not explicitly
        -- carried over from prevEntry is lost, which is why the digest,
        -- watermark and timestamps are copied across here.
        local prevEntry  = knownAccounts[from]
        knownAccounts[from] = {
            lastSeen     = GetTime(),
            online       = true,
            charName     = sender,
            cameOnlineAt = wasOffline and GetTime() or (prevEntry and prevEntry.cameOnlineAt),
            viaBNet      = viaBNet or (prevEntry and prevEntry.viaBNet) or nil,
            peerUptime   = prevEntry and prevEntry.peerUptime,
            hashes       = prevEntry and prevEntry.hashes,
            histWm       = prevEntry and prevEntry.histWm,
            seenAt       = prevEntry and prevEntry.seenAt,
        }

        if cmd == CMD_HELLO then
            if sender then
                local isNew = AddToMembersIfNew(sender, from)
                if isNew then
                    LogActivity("Auto-discovered " .. from .. " (" .. sender .. ") - saved to roster")
                end
            end

            local peerHashes, peerUptime, peerHistWm = ParsePeerHashes(data)
            local prevPeerUptime = prevChar and prevChar.uptime
            local prevAcctWm = knownAccounts[from].histWm
            if not (peerHistWm and peerHistWm > 0) and prevAcctWm and prevAcctWm > 0 then
                knownAccounts[from].histWm = prevAcctWm
            else
                knownAccounts[from].histWm = peerHistWm
            end
            knownAccounts[from].hashes     = peerHashes
            knownAccounts[from].seenAt     = GetTime()
            knownAccounts[from].peerUptime = peerUptime
            if nsChar then
                local keepWm = peerHistWm
                if not (keepWm and keepWm > 0) and prevChar
                        and prevChar.histWm and prevChar.histWm > 0 then
                    keepWm = prevChar.histWm
                end
                knownChars[nsChar] = {
                    uptime = peerUptime,
                    hashes = peerHashes,
                    histWm = keepWm,
                    seenAt = GetTime(),
                }
            end
            -- A peer whose uptime went backwards has relogged. That is the
            -- only signal available: their character never left the roster,
            -- so nothing else distinguishes it from a routine heartbeat.
            local relogged = (prevPeerUptime ~= nil and peerUptime < prevPeerUptime)
            local freshAnnounce = wasOffline or relogged

            if freshAnnounce then
                MS._syncDirty = true
                MS._dirtyAll  = true
            end
            if relogged then
                local nsClr = NormalizeName(sender)
                if nsClr then lastHelloResponseTo[nsClr] = nil end
            end

            if sender and freshAnnounce and not _mss.isEnabled
               and not MS._disabledNoticeShown then
                MS._disabledNoticeShown = true
                RC:Print(RCL["Mesh: "] .. tostring(from) .. RCL[" came online, but mesh"]
                    .. RCL[" sync is disabled on this character - enable it in"]
                    .. RCL[" Mesh Network settings to sync with them."])
            end

            if sender and freshAnnounce and _mss.isEnabled then
                local ns = NormalizeName(sender)
                local now = GetTime()
                -- Answer a given peer's HELLO at most once per 25s. Both
                -- sides HELLO on login and each reply is itself a HELLO, so
                -- without this the pair ping-pongs indefinitely.
                if ns and (not lastHelloResponseTo[ns] or (now - lastHelloResponseTo[ns]) > 25) then
                    lastHelloResponseTo[ns] = now

                    C_Timer.After(0.5 + math.random() * 0.5, function()
                        if _mss.isEnabled then
                            self:Broadcast(CMD_HELLO, BuildHelloData(), ns)
                            self:Broadcast(CMD_CAP, tostring(PROTO_VERSION or 1), ns)
                        end
                    end)

                    local myUptime = math.min(math.floor(GetTime() - _mss._enabledAt), 999)
                    local myLabel  = (_mss.cfg and _mss.cfg.accountLabel) or ""
                    -- Whoever has been enabled longer sends first; equal
                    -- uptimes tie-break on label so both ends agree. The
                    -- other side waits for a quiet inbound stream, so two
                    -- bulk transfers never interleave.
                    local isEstablished = myUptime > peerUptime
                        or (myUptime == peerUptime and myLabel > from)
                    local syncDelay = isEstablished and 0.6 or 4.0
                    if _mss.isEnabled then
                        local RunLoginSync = function()
                            if not _mss.isEnabled then return end
                            if not _mss.charCfg then return end
                            local ph           = (nsChar and knownChars[nsChar] and knownChars[nsChar].hashes)
                                or (knownAccounts[from] and knownAccounts[from].hashes) or {}
                            local mismatchedCats = {}
                            local targetMember = { name = ns, label = from }
                            local totalPkts    = 0
                            local sentCats     = 0
                            local sentLabels   = {}
                            -- Labels are for the local chat line; ids are
                            -- what PUSH_DONE puts on the wire.
                            local sentIds      = {}

                            if RC.WorldBuffs and RC.WorldBuffs.RelayRoster then
                                RC.WorldBuffs:RelayRoster(true)
                            end

                            if _mss.charCfg.syncCategories["bossNotes"] then
                                local notes = RC.db and RC.db.bossNotes and RC.db.bossNotes.notes
                                if notes and next(notes) ~= nil then
                                    local myHash = GetCategoryHash("bossNotes")
                                    if myHash:sub(1, 5) ~= ph["bossNotes"] then
                                        local n = MS:Push("bossNotes", nil, targetMember, true)
                                        if n then
                                            totalPkts = totalPkts + n
                                            sentCats  = sentCats + 1
                                            sentLabels[#sentLabels+1] = "Boss Notes"
                                            sentIds[#sentIds+1]       = "bossNotes"
                                        end
                                    end
                                end
                            end

                            -- Push only what differs: our 8-char category
                            -- hash against the 5 the peer advertised. An
                            -- empty digest (truncated or layout mismatch)
                            -- reads as "everything differs".
                            for _, cat in ipairs(MS.SYNC_CATEGORIES) do
                                if _mss.charCfg.syncCategories[cat.id] then

                                    if cat.id == "raidProfiles" then
                                        if RC.remoteEditMode then
                                            RC:DebugPrint("login-sync: raidProfiles NOT pushed to " .. tostring(from)
                                                .. " - remote edit mode active", "meshsync")
                                        else
                                        local myHash = GetCategoryHash("raidProfiles")
                                        if myHash:sub(1, 5) == ph["raidProfiles"] then
                                            RC:DebugPrint("login-sync: raidProfiles hash matches " .. tostring(from)
                                                .. " - nothing pushed (peer already has identical data incl. TTK history)", "meshsync")
                                        end
                                        if myHash:sub(1, 5) ~= ph["raidProfiles"] and RC.db and RC.db.raidProfiles then
                                            local sentAny = false
                                            for _, raidKey in ipairs(KNOWN_RAID_KEYS) do
                                                local rd = RC.db.raidProfiles[raidKey]
                                                if rd and rd.profiles and next(rd.profiles) ~= nil then
                                                    local rdToSend = _mss.charCfg.syncRaidGear and rd
                                                                     or StripGearFromRaid(rd)
                                                    local partial = { raidProfiles = { [raidKey] = rdToSend } }
                                                    for _, k in ipairs({"polarityMode","frostBlastConfig"}) do
                                                        if RC.db[k] ~= nil then partial[k] = RC.db[k] end
                                                    end
                                                    partial.raidRoute = SlimRouteCfg()
                                                    local n = PushRawPayload("raidProfiles~PARTIAL", partial, targetMember, true, raidKey)
                                                    totalPkts = totalPkts + (n or 0)
                                                    sentAny = true
                                                end
                                            end
                                            if sentAny then
                                                sentCats = sentCats + 1
                                                sentLabels[#sentLabels+1] = cat.label or cat.id
                                                sentIds[#sentIds+1]       = cat.id
                                            end
                                        end
                                        end

                                    elseif cat.id == "bossNotes" then

                                    else
                                        local myHash = GetCategoryHash(cat.id)
                                        if myHash:sub(1, 5) ~= ph[cat.id] then
                                            mismatchedCats[#mismatchedCats + 1] = cat.id
                                            local hd, skipCat = nil, false
                                            -- Delta from the peer's advertised
                                            -- watermark, once per peer. Stale
                                            -- digest means that delta is still
                                            -- in flight; a fresh digest that
                                            -- still mismatches forces a full.
                                            if cat.id == "executeCalc" then
                                                local peerRec = (nsChar and knownChars[nsChar])
                                                    or knownAccounts[from]
                                                local pw = peerRec and peerRec.histWm
                                                if pw ~= nil and pw <= 0 then pw = nil end
                                                MS._histDeltaTried = MS._histDeltaTried or {}
                                                local tried = MS._histDeltaTried[ns]
                                                local decision
                                                if tried and peerRec
                                                        and (peerRec.seenAt or 0) <= (tried.sentAt or 0) then
                                                    skipCat = true
                                                    decision = "skip (delta sent, peer digest stale)"
                                                elseif pw and not tried then
                                                    MS._histDeltaTried[ns] = { sentAt = GetTime() }
                                                    hd = { fromWm = pw }
                                                    decision = "delta (fights newer than " .. pw .. ")"
                                                else
                                                    MS._histDeltaTried[ns] = nil
                                                    decision = pw and "FULL (fresh digest still mismatched)"
                                                        or "FULL (no peer watermark)"
                                                end
                                                if RC:IsDebugEnabled("meshsync") then
                                                    RC:DebugPrint("Mesh: executeCalc -> " .. from
                                                        .. ": " .. decision, "meshsync", 0)
                                                end
                                            end
                                            local n = (not skipCat)
                                                and MS:Push(cat.id, nil, targetMember, true, hd)
                                            if n then
                                                totalPkts = totalPkts + n
                                                sentCats  = sentCats + 1
                                                sentLabels[#sentLabels+1] = cat.label or cat.id
                                                sentIds[#sentIds+1]       = cat.id
                                            end
                                        end
                                    end

                                end
                            end

                            if sentCats > 0 then
                                local sentStr = table.concat(sentLabels, ", ")
                                RC:Print(RCL["Mesh: Sent "] .. sentStr .. RCL[" to "] .. from .. "")
                                if RC:IsDebugEnabled("meshsync") and #mismatchedCats > 0 then
                                    RC:DebugPrint("Mesh: mismatched categories vs " .. from
                                        .. ": " .. table.concat(mismatchedCats, ", "), "meshsync", 0)
                                end
                                -- Declare the packet count up front so the
                                -- receiver can show a total. Below 120 the
                                -- progress UI is noise, so it is not sent.
                                if totalPkts >= 120 then
                                    MS:Broadcast(RP.BATCH, tostring(totalPkts), ns)
                                end
                                -- Batched: MS:Broadcast never chunks, and
                                -- the receiver's ACK echoes the list back
                                -- roughly doubled - so each PUSH_DONE
                                -- carries at most ~90 bytes of ids, keeping
                                -- both directions inside one message. A
                                -- full-category list in one message used
                                -- to overflow and silently kill delivery
                                -- verification exactly on full syncs.
                                do
                                    local batch = {}
                                    local blen = 0
                                    for _, id in ipairs(sentIds) do
                                        if blen > 0 and blen + #id + 1 > 90 then
                                            MS:Broadcast(CMD_PUSH_DONE, table.concat(batch, ","), ns)
                                            batch, blen = {}, 0
                                        end
                                        batch[#batch + 1] = id
                                        blen = blen + #id + 1
                                    end
                                    if #batch > 0 then
                                        MS:Broadcast(CMD_PUSH_DONE, table.concat(batch, ","), ns)
                                    end
                                end
                            end

                            local charKey = NormalizeName(sender)
                            if charKey then
                                local gCache = ReadycheckDB
                                            and ReadycheckDB.meshSyncGearCache
                                            and ReadycheckDB.meshSyncGearCache[charKey]
                                if gCache then
                                    MS:_ApplyGearDataFromCache(charKey, gCache)
                                end

                                local rwEntry = ReadycheckDB
                                    and ReadycheckDB.remoteWarriors
                                    and ReadycheckDB.remoteWarriors[charKey]
                                local hasRemote = rwEntry and rwEntry.pendingPush
                                               and #rwEntry.pendingPush > 0
                                if hasRemote then
                                    MS:PushQueuedGearSets(charKey, sender, from, false)
                                end
                                MS:PushQueuedGearDeletes(charKey, sender, from)
                                local hasTrinket = ReadycheckDB.remoteTrinketPush
                                    and ReadycheckDB.remoteTrinketPush[charKey]
                                    and ReadycheckDB.remoteTrinketPush[charKey].pendingPush
                                if hasTrinket then
                                    MS:PushQueuedTrinketConfig(charKey, sender, from)
                                end
                                local hasRaidCfg = ReadycheckDB.remoteRaidConfigQueue
                                    and ReadycheckDB.remoteRaidConfigQueue[charKey]
                                if hasRaidCfg then
                                    local qEntry = ReadycheckDB.remoteRaidConfigQueue[charKey]
                                    if qEntry and qEntry.raidKey and qEntry.data then
                                        local targetMember = { name = sender, label = from }
                                        local payload = { raidKey = qEntry.raidKey, data = qEntry.data }
                                        PushRawPayload("raidCfgFor", payload, targetMember, nil, qEntry.raidKey)
                                        ReadycheckDB.remoteRaidConfigQueue[charKey] = nil
                                        RC:DebugPrint("MeshSync: flushed queued raidCfgFor '"
                                            .. qEntry.raidKey .. "' to " .. from .. " on login", "meshsync")
                                    end
                                end
                            end
                        end
                        local syncAttempts = 0
                        local function WaitQuietThenSync()
                            if not isEstablished and MS._lastInboundAt then
                                local lastIn = MS._lastInboundAt[ns]
                                if lastIn and (GetTime() - lastIn) < 6 then
                                    syncAttempts = syncAttempts + 1
                                    if syncAttempts < 180 then
                                        C_Timer.After(5, WaitQuietThenSync)
                                        return
                                    end
                                end
                            end
                            RunLoginSync()
                        end
                        C_Timer.After(syncDelay, WaitQuietThenSync)
                    end
                end
            end

            LogActivity(from .. " is on the mesh (" .. (sender or "") .. ")")
            self:RefreshMeshUI()
            return
        end

        if cmd == CMD_BYE then
            if knownAccounts[from] then knownAccounts[from].online = false end
            _mss.AbortQueuedFor(NormalizeName(sender), from)
            _receivedRaidConfirmPrinted[from] = nil
            LogActivity(from .. " left the mesh")
            self:RefreshMeshUI()
            return
        end

        -- Per-msgId receipt. Senders do not track outstanding msgIds, so
        -- this is only useful as proof of life; the real delivery check is
        -- the PUSH_DONE / PUSH_ACK label exchange below.
        if cmd == CMD_ACK then
            return
        end

        if cmd == RP.BATCH then
            local declared = tonumber(data) or 0
            if declared >= 120 then
                local sNs = NormalizeName(sender or from)
                if sNs then
                    local s = RP.sessions[sNs]
                    if not (s and (GetTime() - (s.lastAt or 0)) < 15) then
                        s = { received = 0, discovered = 0, label = from }
                        RP.sessions[sNs] = s
                    end
                    s.declared = (s.declared or 0) + declared
                    s.lastAt = GetTime()
                    s.doneAt = nil
                    if not s.announced then
                        s.announced = true
                        RC:Print(RCL["Mesh: receiving sync data from "] .. from .. " - "
                            .. RP.Total(s) .. RCL[" parts (~"] .. RP.Eta(RP.Total(s)) .. ").")
                    end
                    RP.Row()
                end
            end
            return
        end

        -- Sender lists the category IDS it just sent (labels from older
        -- peers are still accepted). Compared against what actually applied
        -- (_recentApplies) and answered with PUSH_ACK carrying the ids that
        -- landed. Ids are the wire form now: labels are localized and
        -- renameable, and a receiver on another locale used to read every
        -- category as "did NOT fully arrive" and trigger a full re-push.
        if cmd == CMD_PUSH_DONE then
            if data and data ~= "" then
                local applies = MS._recentApplies and MS._recentApplies[from]
                local toId, idToLabel = {}, {}
                for _, c in ipairs(MS.SYNC_CATEGORIES) do
                    toId[c.label or c.id] = c.id
                    toId[c.id]            = c.id
                    idToLabel[c.id]       = c.label or c.id
                end
                local got, missing, ackIds = {}, {}, {}
                for token in string.gmatch(data, "[^,]+") do
                    token = token:match("^%s*(.-)%s*$")
                    local id = toId[token]
                    local label = id and idToLabel[id] or token
                    if not id then
                        got[#got + 1] = label
                    elseif applies and applies[id] then
                        got[#got + 1] = label
                        ackIds[#ackIds + 1] = id
                    else
                        missing[#missing + 1] = label
                    end
                end
                -- The "Received X from Y" chat line comes from ApplyInbound's
                -- own reporter now - it fires when data actually lands, so it
                -- can't go quiet when this label bookkeeping drifts. This
                -- handler only checks for categories that did NOT arrive.
                if #missing > 0 then
                    RC:Print(RCL["Mesh: "] .. table.concat(missing, ", ") .. RCL[" from "] .. from
                        .. RCL[" did NOT fully arrive. The sender will retry once automatically; you can also use Request in the Actions tab."])
                    LogActivity("FAILED to receive " .. table.concat(missing, ", ") .. " from " .. from)
                end
                local ackTgt = NormalizeName(sender) or from
                MS:Broadcast(RP.ACK, data .. "||" .. table.concat(ackIds, ","), ackTgt)
                -- Consume only the ids THIS message covered. PUSH_DONE now
                -- arrives in batches, and wiping the whole applies table on
                -- the first batch made every later batch read as "did NOT
                -- arrive".
                if applies then
                    for _, id in ipairs(ackIds) do applies[id] = nil end
                end
            end
            return
        end

        -- Delivery verification. Exactly one automatic re-push per
        -- peer+category, then it gives up and tells the user - a category
        -- that keeps failing would otherwise loop forever.
        if cmd == RP.ACK then
            local claimed, ackedStr = string.match(data or "", "^(.-)||(.*)$")
            if claimed then
                local acked = {}
                for id in string.gmatch(ackedStr or "", "[^,]+") do acked[id] = true end
                local toId, idToLabel = {}, {}
                for _, c in ipairs(MS.SYNC_CATEGORIES) do
                    toId[c.label or c.id] = c.id
                    toId[c.id]            = c.id
                    idToLabel[c.id]       = c.label or c.id
                end
                MS._verifyRetried = MS._verifyRetried or {}
                for token in string.gmatch(claimed, "[^,]+") do
                    token = token:match("^%s*(.-)%s*$")
                    local id = toId[token]
                    local label = id and idToLabel[id] or token
                    if id and acked[id] then
                        -- Verified OK: clear any earlier retry mark, so a
                        -- genuine failure LATER in the session still gets
                        -- its one automatic re-push. This used to stick for
                        -- the whole session after the first failure.
                        MS._verifyRetried[from .. ":" .. id] = nil
                    elseif id and not acked[id] then
                        local rk = from .. ":" .. id
                        if not MS._verifyRetried[rk] then
                            MS._verifyRetried[rk] = true
                            RC:Print(RCL["Mesh: "] .. label .. RCL[" did not reach "] .. from .. RCL[" - re-sending in full."])
                            LogActivity("Verify failed for " .. label .. " to " .. from .. " - re-pushing")
                            MS:Push(id, nil, { name = NormalizeName(sender) or sender, label = from }, true)
                        else
                            RC:Print(RCL["Mesh: "] .. label .. RCL[" failed to reach "] .. from
                                .. RCL[" again - not retrying automatically. Push or Request it manually."])
                            LogActivity("Verify failed twice for " .. label .. " to " .. from)
                        end
                    end
                end
            end
            return
        end

        -- Nothing in the addon sends GOLDR. Swallowed explicitly so a peer
        -- that does emit it cannot fall through to the REQ_/PUSH_ branches.
        if cmd == "GOLDR" then return end

        -- World buff traffic: thin forwards into the feature modules, which
        -- own their encodings. All single-message, so each module must keep
        -- its payload inside one addon message.
        if cmd == "WBUFF" then
            if RC.WorldBuffs and RC.WorldBuffs.OnInbound then
                RC.WorldBuffs:OnInbound(from, sender, data, viaBNet)
            end
            return
        end

        if cmd == "WBREL" then
            if RC.WorldBuffs and RC.WorldBuffs.OnRelay then
                RC.WorldBuffs:OnRelay(from, sender, data, viaBNet)
            end
            return
        end

        if cmd == "WBGOLD" then
            if RC.GoldLedger then RC.GoldLedger:OnInbound(from, sender, data) end
            return
        end

        if cmd == "WBDEL" then
            if RC.WorldBuffs and RC.WorldBuffs.OnRemoval then
                RC.WorldBuffs:OnRemoval(from, sender, data)
            end
            return
        end

        if cmd == "WBONY" then
            if RC.WorldBuffs and RC.WorldBuffs.OnOppOny then
                RC.WorldBuffs:OnOppOny(data)
            end
            return
        end

        if cmd == "WBTIME" then
            if RC.WorldBuffTimers and RC.WorldBuffTimers.Mesh then
                RC.WorldBuffTimers.Mesh:OnInbound(from, sender, data, viaBNet)
            end
            return
        end

        if cmd == "WBYELL" then
            if RC.WorldBuffTimers and RC.WorldBuffTimers.Mesh
                    and RC.WorldBuffTimers.Mesh.OnInboundYell then
                RC.WorldBuffTimers.Mesh:OnInboundYell(from, sender, data, viaBNet)
            end
            return
        end

        -- Every REQ_ answer is a push of this character's data; the same
        -- request from the same sender is answered once per 30s.
        if string_sub(cmd, 1, 4) == "REQ_" then
            local reqKey = tostring(from) .. "|" .. cmd .. "|" .. tostring(data or "")
            local last = reqLastAt[reqKey]
            if last and (GetTime() - last) < 30 then
                RC:DebugPrint("MeshSync: ignored repeat " .. cmd .. " from " .. from, "meshsync")
                return
            end
            reqLastAt[reqKey] = GetTime()
        end

        if cmd == "REQ_remoteGearData" then
            if not sender then return end
            local tgt = NormalizeName(sender)
            if not tgt then return end
            -- This dumps full bags + equipped items; a valid token alone
            -- must not be enough to pull it. Roster + Accept From, same as
            -- every write path.
            if not IsRosterMemberNs(tgt) or not RecvFromAllowed(from) then
                RC:DebugPrint("MeshSync: denied REQ_remoteGearData from "
                    .. tostring(from), "meshsync")
                return
            end
            local items = {}
            for bag = 0, 4 do
                local numSlots = C_Container and C_Container.GetContainerNumSlots(bag) or 0
                for s = 1, numSlots do
                    local info = C_Container.GetContainerItemInfo(bag, s)
                    if info and info.itemID then
                        local _, _, _, _, _, _, _, _, equipLoc, icon, _, _, _, _ = GetItemInfo(info.itemID)
                        if equipLoc and equipLoc ~= "" and equipLoc ~= "INVTYPE_NON_EQUIP" then
                            local link = C_Container.GetContainerItemLink(bag, s)
                            local nm   = GetItemInfo(info.itemID) or ("item:" .. info.itemID)
                            items[#items+1] = {
                                id       = info.itemID,
                                link     = link,
                                name     = nm,
                                icon     = icon,
                                equipLoc = equipLoc,
                            }
                        end
                    end
                end
            end
            for slot = 1, 19 do
                local itemId = GetInventoryItemID and GetInventoryItemID("player", slot)
                if itemId then
                    local nm, _, _, _, _, _, _, _, equipLoc, icon = GetItemInfo(itemId)
                    if nm then
                        items[#items+1] = {
                            id       = itemId,
                            link     = GetInventoryItemLink and GetInventoryItemLink("player", slot),
                            name     = nm,
                            icon     = icon,
                            equipLoc = equipLoc,
                            equipped = true,
                            slot     = slot,
                        }
                    end
                end
            end
            local payload = {
                gearSets       = RC.db and RC.db.gearSets or {},
                availableItems = items,
            }
            local respFrom = GetMyLabel()
            local respId   = NextMsgId()
            local respTok  = GetToken()
            local respMsgs = ChunkForTarget(payload, respFrom, respId, respTok, "PUSH_remoteGearData", tgt)
            if respMsgs then EnqueueMessages(respMsgs, tgt) end
            LogActivity("Sent gear data to " .. from)
            return
        end

        if cmd == "REQ_remoteTrinketData" then
            if not sender then return end
            local tgt = NormalizeName(sender)
            if not tgt then return end
            if not IsRosterMemberNs(tgt) or not RecvFromAllowed(from) then
                RC:DebugPrint("MeshSync: denied REQ_remoteTrinketData from "
                    .. tostring(from), "meshsync")
                return
            end
            local trinkets = {}
            for bag = 0, 4 do
                local numS = C_Container and C_Container.GetContainerNumSlots(bag) or 0
                for s = 1, numS do
                    local info = C_Container.GetContainerItemInfo(bag, s)
                    if info and info.itemID then
                        local _, _, _, _, _, _, _, _, eqLoc, icon = GetItemInfo(info.itemID)
                        if eqLoc == "INVTYPE_TRINKET" then
                            local lnk = C_Container.GetContainerItemLink(bag, s)
                            local nm  = GetItemInfo(info.itemID) or ("item:" .. info.itemID)
                            trinkets[#trinkets+1] = { id=info.itemID, link=lnk, name=nm, icon=icon }
                        end
                    end
                end
            end
            for _, slot in ipairs({13, 14}) do
                local itemId = GetInventoryItemID and GetInventoryItemID("player", slot)
                if itemId then
                    local nm, _, _, _, _, _, _, _, eqLoc, icon = GetItemInfo(itemId)
                    if nm then
                        trinkets[#trinkets+1] = {
                            id = itemId,
                            link = GetInventoryItemLink and GetInventoryItemLink("player", slot),
                            name = nm, icon = icon, equipped = true, slot = slot,
                        }
                    end
                end
            end
            local payload    = {
                trinketSwap      = RC.db and RC.db.trinketSwap or {},
                availableTrinkets = trinkets,
            }
            local respFrom = GetMyLabel()
            local respId   = NextMsgId()
            local respTok  = GetToken()
            local respMsgs = ChunkForTarget(payload, respFrom, respId, respTok, "PUSH_remoteTrinketData", tgt)
            if respMsgs then EnqueueMessages(respMsgs, tgt) end
            LogActivity("Sent trinket data to " .. from)
            return
        end

        if cmd == "REQ_raidCfgForEdit" then
            if not sender then return end
            local tgt = NormalizeName(sender)
            if not tgt then return end
            if not IsRosterMemberNs(tgt) or not RecvFromAllowed(from) then
                RC:DebugPrint("MeshSync: denied REQ_raidCfgForEdit from "
                    .. tostring(from), "meshsync")
                return
            end
            local req = Deserialize(data or "{}")
            if type(req) ~= "table" or not req.raidKey then
                RC:DebugPrint("MeshSync: REQ_raidCfgForEdit missing raidKey from " .. from, "meshsync")
                return
            end
            local rk = req.raidKey
            if not RC.db or not RC.db.raidProfiles or not RC.db.raidProfiles[rk] then
                local errSer  = Serialize({ raidKey = rk, error = "nodata" })
                local errMsgs = ChunkData(errSer, GetMyLabel(), NextMsgId(), GetToken(), "PUSH_raidCfgForEdit")
                if errMsgs then EnqueueMessages(errMsgs, tgt) end
                RC:DebugPrint("MeshSync: REQ_raidCfgForEdit for '" .. rk .. "' - no data, sent error response", "meshsync")
                return
            end
            local rd = RC.db.raidProfiles[rk]
            local gearSetNames = {}
            if RC.db.gearSets then
                for name in pairs(RC.db.gearSets) do
                    gearSetNames[#gearSetNames + 1] = name
                end
            end
            if RC.GearManager and RC.GearManager.sets then
                local seen = {}
                for _, n in ipairs(gearSetNames) do seen[n] = true end
                for name in pairs(RC.GearManager.sets) do
                    if not seen[name] then gearSetNames[#gearSetNames + 1] = name end
                end
            end
            local payload  = { raidKey = rk, data = rd, gearSetNames = gearSetNames }
            local respFrom = GetMyLabel()
            local respId   = NextMsgId()
            local respTok  = GetToken()
            local respMsgs = ChunkForTarget(payload, respFrom, respId, respTok, "PUSH_raidCfgForEdit", tgt)
            local numChunks = respMsgs and #respMsgs or 0
            RC:DebugPrint(string_format(
                "MeshSync: raidCfgForEdit '%s' -> %d chunks to %s",
                rk, numChunks, tgt), "meshsync")
            if respMsgs then
                EnqueueMessages(respMsgs, tgt)
            else
                local eMsgs = ChunkData(Serialize({ raidKey = rk, error = "toolarge" }),
                    respFrom, NextMsgId(), respTok, "PUSH_raidCfgForEdit")
                if eMsgs then EnqueueMessages(eMsgs, tgt) end
                RC:Print(string_format(
                    "Mesh: raid config '%s' is too large to send (%d KB). " ..
                    "Reduce the number of profiles for that raid.",
                    rk, math_floor(string_len(Serialize(rd)) / 1024)))
            end
            LogActivity("Sent raid config '" .. rk .. "' (for editing) to " .. from)
            RC:DebugPrint("MeshSync: sent raidCfgForEdit '" .. rk .. "' to " .. tgt, "meshsync")
            return
        end

        -- Generic category request. Must stay AFTER the specific REQ_
        -- handlers above, which have their own payloads and responses.
        if string_sub(cmd, 1, 4) == "REQ_" then
            local categoryId = string_sub(cmd, 5)
            RC:DebugPrint("MeshSync: REQ for " .. categoryId .. " from " .. from, "meshsync")
            if sender then
                local normalizedSender = NormalizeName(sender)
                if normalizedSender then
                    -- A request is a pull of this character's data; it obeys
                    -- the same gates as everything else. In particular the
                    -- SEND rule: a category the user unticked must not be
                    -- extractable just by asking for it.
                    if not IsRosterMemberNs(normalizedSender)
                            or not RecvFromAllowed(from) then
                        RC:DebugPrint("MeshSync: denied REQ_" .. categoryId
                            .. " from " .. tostring(from), "meshsync")
                        return
                    end
                    if not (_mss.charCfg and _mss.charCfg.syncCategories
                            and _mss.charCfg.syncCategories[categoryId]) then
                        RC:DebugPrint("MeshSync: denied REQ_" .. categoryId
                            .. " from " .. tostring(from)
                            .. " (Send off for this category)", "meshsync")
                        LogActivity("Denied request for " .. categoryId
                            .. " from " .. from .. " (Send is off)")
                        return
                    end
                    local catLabel = categoryId
                    for _, cat in ipairs(MS.SYNC_CATEGORIES) do
                        if cat.id == categoryId then catLabel = cat.label; break end
                    end
                    local targetMember = { name = normalizedSender, label = from }
                    MS:Push(categoryId, nil, targetMember, true)
                    MS:Broadcast(CMD_PUSH_DONE, categoryId, normalizedSender)
                    LogActivity("Replied " .. catLabel .. " to " .. from)
                end
            end
            return
        end

        -- The only chunked path. Command tail is <category>[~modifier]:
        -- "~PARTIAL" means merge rather than replace, "~CLASS:x"/"~CHAR:x"
        -- are receiver-side filters.
        if string_sub(cmd, 1, 5) == "PUSH_" then
            local fullCat    = string_sub(cmd, 6)
            local categoryId = fullCat
            local filterType, filterVal
            local isPartial  = false

            local tilde = string_find(fullCat, "~", 1, true)
            if tilde then
                categoryId      = string_sub(fullCat, 1, tilde - 1)
                local afterTilde = string_sub(fullCat, tilde + 1)
                if afterTilde == "PARTIAL" then
                    isPartial = true
                else
                    local colon = string_find(afterTilde, ":", 1, true)
                    if colon then
                        filterType = string_sub(afterTilde, 1, colon - 1)
                        filterVal  = string_sub(afterTilde, colon + 1)
                    end
                end
            end

            -- Filters are evaluated before any buffering, so a transfer aimed
            -- at another class or character costs nothing but the parse.
            if filterType == "CLASS" then
                local _, playerClass = UnitClass("player")
                if playerClass ~= filterVal then return end
            elseif filterType == "CHAR" then
                if UnitName("player") ~= filterVal then return end
            end

            -- Reassembly buffers are keyed on sender + msgId + command, so
            -- one peer can have several transfers in flight at once. The
            -- command is in the key because two concurrent transfers from
            -- one sender that happened to collide on msgId AND chunk count
            -- would otherwise merge into one corrupt payload - the
            -- total-mismatch restart below only catches differing lengths.
            local bufKey = (sender or from) .. ":" .. msgId .. ":" .. (categoryId or cmd or "")
            if not inboundBuffers[bufKey] then
                local catLabel = categoryId
                for _, cat in ipairs(MS.SYNC_CATEGORIES) do
                    if cat.id == categoryId then catLabel = cat.label; break end
                end
                if isPartial then catLabel = catLabel .. " (partial)" end
                do
                    local sNs = NormalizeName(sender or from)
                    if sNs then
                        local s = RP.sessions[sNs]
                        local sessionActive = s and (GetTime() - (s.lastAt or 0)) < 15
                        if tot >= 120 or sessionActive then
                            if not sessionActive then
                                s = { received = 0, discovered = 0, label = from }
                                RP.sessions[sNs] = s
                            end
                            s.discovered = (s.discovered or 0) + tot
                            s.lastAt = GetTime()
                            s.doneAt = nil
                            if not s.announced then
                                s.announced = true
                                RC:Print(RCL["Mesh: receiving sync data from "] .. from .. "...")
                            end
                            RP.Row()
                        elseif not isPartial then
                            RC:DebugPrint("MeshSync: receiving " .. catLabel .. " from " .. from
                                .. " (" .. tot .. " packet(s))")
                        end
                    end
                end
                inboundBuffers[bufKey] = {
                    chunks     = {},
                    total      = tot,
                    received   = 0,
                    from       = from,
                    sessNs     = NormalizeName(sender or from),
                    catLabel   = catLabel,
                    categoryId = categoryId,
                    isPartial  = isPartial,
                    marker     = marker,
                    timeout    = GetTime() + BUFFER_TIMEOUT,
                }
            end
            local buf = inboundBuffers[bufKey]
            if buf.total ~= tot then
                RC:DebugPrint("MeshSync: msgId reuse from " .. from
                    .. " (total " .. tostring(buf.total) .. " -> " .. tostring(tot)
                    .. ") - restarted chunk buffer", "meshsync")
                inboundBuffers[bufKey] = {
                    chunks     = {},
                    total      = tot,
                    received   = 0,
                    from       = from,
                    sessNs     = NormalizeName(sender or from),
                    categoryId = categoryId,
                    isPartial  = isPartial,
                    marker     = marker,
                    timeout    = GetTime() + BUFFER_TIMEOUT,
                }
                buf = inboundBuffers[bufKey]
            end
            -- Duplicate chunks (a send retry, or the same message heard on
            -- two paths) are counted once. buf.received is a count of
            -- distinct seqs, which is what makes the completion test valid.
            if not buf.chunks[seq] then
                buf.chunks[seq] = data
                buf.received    = buf.received + 1
                local inNs = NormalizeName(sender or from)
                if inNs then
                    MS._lastInboundAt = MS._lastInboundAt or {}
                    MS._lastInboundAt[inNs] = GetTime()
                    local s = RP.sessions[inNs]
                    if s then
                        s.received = s.received + 1
                        s.lastAt   = GetTime()
                        RP.Row()
                        if s.received >= RP.Total(s) then RP.Done(inNs) end
                    end
                end
            end
            -- Each chunk pushes the deadline out. There is no retransmit
            -- request in the protocol: a chunk lost for good stalls the
            -- buffer until Maintenance drops the whole transfer, and recovery
            -- is the sender's PUSH_ACK retry or a manual Request.
            buf.timeout = GetTime() + BUFFER_TIMEOUT
            if buf.total >= 400 and buf.received % 200 == 0 then
                RC:DebugPrint(string_format(
                    "MeshSync: receiving %s from %s - %d/%d chunks",
                    tostring(buf.categoryId), tostring(buf.from),
                    buf.received, buf.total), "meshsync")
            end

            -- Complete: concatenate by seq and decode with the marker that
            -- came in the header. Everything below this point is per-category
            -- handling; the generic categories fall through to ApplyInbound
            -- at the bottom.
            if buf.received >= buf.total then
                local parts = {}
                for s = 1, buf.total do parts[s] = buf.chunks[s] or "" end
                local fullData = table_concat(parts, "")
                inboundBuffers[bufKey] = nil
                RC:DebugPrint(string_format(
                    "MeshSync: assembled %d bytes (%d chunks, %s) from %s category=%s",
                    string_len(fullData), buf.total, buf.marker or "RC1", buf.from, buf.categoryId), "meshsync")
                local result, err = DecodeWire(fullData, buf.marker)
                if result then
                    if buf.categoryId == "remoteGearData" then
                        local charKey = NormalizeName(sender)
                        if charKey and type(result) == "table" then
                            ReadycheckDB = ReadycheckDB or {}
                            ReadycheckDB.remoteWarriors = ReadycheckDB.remoteWarriors or {}
                            local rw = ReadycheckDB.remoteWarriors
                            rw[charKey] = rw[charKey] or {
                                localEdits = {}, pendingPush = {},
                            }
                            local entry = rw[charKey]
                            entry.label          = buf.from
                            entry.gearSets       = RC.DeepCopy(result.gearSets or {})
                            entry.availableItems = RC.DeepCopy(result.availableItems or {})
                            entry.lastReceived   = GetTime()
                            local setCount  = 0
                            for _ in pairs(entry.gearSets) do setCount = setCount + 1 end
                            local itemCount = #entry.availableItems
                            RC:Print(string_format("Mesh: Received gear data from |cFFFFD700%s|r: |cFFFFD700%d|r set(s), |cFFFFD700%d|r equippable item(s).", buf.from, setCount, itemCount))
                            LogActivity("Received gear data from " .. buf.from)
                            if RC.gearManagerTab == "remote" and RC.ShowSidebarGearManagerConfig and RC.sidebarConfigFrame then
                                local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                                if cf then RC:ShowSidebarGearManagerConfig(cf) end
                            end
                            if sender then
                                local ns2 = NormalizeName(sender)
                                if ns2 then self:Broadcast(CMD_ACK, msgId, ns2) end
                            end
                        end
                        return
                    end

                    if buf.categoryId == "remoteTrinketData" then
                        local charKey = NormalizeName(sender)
                        if charKey and type(result) == "table" then
                            ReadycheckDB = ReadycheckDB or {}
                            ReadycheckDB.remoteTrinketWarriors =
                                ReadycheckDB.remoteTrinketWarriors or {}
                            local rw = ReadycheckDB.remoteTrinketWarriors
                            rw[charKey] = rw[charKey] or { localEdits = {} }
                            local entry = rw[charKey]
                            entry.label             = buf.from
                            entry.config            = RC.DeepCopy(result.trinketSwap or {})
                            entry.availableTrinkets = RC.DeepCopy(result.availableTrinkets or {})
                            entry.lastReceived      = GetTime()
                            RC:Print(string_format(
                                "Mesh: Received trinket data from |cFFFFD700%s|r: |cFFFFD700%d|r trinket(s) available.",
                                buf.from, #entry.availableTrinkets))
                            LogActivity("Received trinket data from " .. buf.from)
                            if RC.trinketSwapTab == "remote"
                                    and RC.ShowSidebarTrinketSwapConfig
                                    and RC.sidebarConfigFrame then
                                local cf = RC.sidebarConfigFrame.compatFrame
                                if cf then RC:ShowSidebarTrinketSwapConfig(cf) end
                            end
                            if sender then
                                local ns2 = NormalizeName(sender)
                                if ns2 then self:Broadcast(CMD_ACK, msgId, ns2) end
                            end
                        end
                        return
                    end

                    if buf.categoryId == "gearSetDeletes" then
                        -- Deleting is at least as destructive as writing, so
                        -- it obeys the same Receive rules as a gearSets push:
                        -- roster, Accept From, and the category checkbox.
                        local rcOff = _mss.charCfg and _mss.charCfg.recvCategories
                            and _mss.charCfg.recvCategories["gearSets"] == false
                        if not IsRosterMemberNs(buf.sessNs) then
                            RC:DebugPrint("MeshSync: ignored gearSetDeletes from non-roster " .. tostring(buf.from), "meshsync")
                        elseif not RecvFromAllowed(from) then
                            LogActivity("Ignored gear set deletes from " .. from .. " (not in your Accept From list)")
                        elseif rcOff then
                            RC:DebugPrint("MeshSync: ignored gearSetDeletes from " .. tostring(buf.from)
                                .. " (Receive off for Gear Sets)", "meshsync")
                        elseif type(result) == "table" and type(result.delete) == "table" then
                            local deleted = {}
                            for _, setName in ipairs(result.delete) do
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
                            if #deleted > 0 then
                                RC:SaveConfigurationToProfile()
                                RC:Print(RCL["Mesh: "] .. buf.from .. RCL[" deleted "] ..
                                    #deleted .. RCL[" gear set(s): "] .. table_concat(deleted, ", "))
                                LogActivity(buf.from .. " deleted " .. #deleted .. " gear set(s)")
                                local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                                if cf and RC.ShowSidebarGearManagerConfig then
                                    RC:ShowSidebarGearManagerConfig(cf, true)
                                end
                            end
                            if sender then
                                local ns3 = NormalizeName(sender)
                                if ns3 then self:Broadcast(CMD_ACK, msgId, ns3) end
                            end
                        end
                        return
                    end

                    -- Echo guard: sets we just pushed to a remote toon come
                    -- back as their own broadcast. Restamping
                    -- _lastBroadcastHash here stops a third round trip.
                    local suppressInbound = false
                    if buf.categoryId == "gearSets" then
                        local senderKey = sender and NormalizeName(sender)
                        if RC.remoteEditMode then
                            local editedKey = NormalizeName(RC.remoteEditMode.member.name or "")
                            if senderKey and editedKey and senderKey == editedKey then
                                suppressInbound = true
                                _lastBroadcastHash["gearSets"] = GetCategoryHash("gearSets")
                                RC:DebugPrint("MeshSync: suppressed gearSets from edited toon " .. from, "meshsync")
                            end
                        end
                        if not suppressInbound
                                and senderKey and MS._suppressGearSetInbound
                                and MS._suppressGearSetInbound[senderKey]
                                and GetTime() < MS._suppressGearSetInbound[senderKey] then
                            suppressInbound = true
                            _lastBroadcastHash["gearSets"] = GetCategoryHash("gearSets")
                            RC:DebugPrint("MeshSync: suppressed gearSets echo from " .. from, "meshsync")
                        end
                    end

                    if buf.categoryId == "routeShare" then
                        -- Writes the active profile's route, so it obeys the
                        -- raidProfiles Receive rules like any other write.
                        local rsOff = _mss.charCfg and _mss.charCfg.recvCategories
                            and _mss.charCfg.recvCategories["raidProfiles"] == false
                        if not IsRosterMemberNs(buf.sessNs) then
                            RC:DebugPrint("MeshSync: ignored routeShare from non-roster " .. tostring(buf.from), "meshsync")
                        elseif not RecvFromAllowed(from) then
                            LogActivity("Ignored shared route from " .. from .. " (not in your Accept From list)")
                        elseif rsOff then
                            RC:DebugPrint("MeshSync: ignored routeShare from " .. tostring(buf.from)
                                .. " (Receive off for Raid Profiles)", "meshsync")
                        elseif type(result) == "table"
                                and type(result.raidKey) == "string"
                                and type(result.route) == "table"
                                and type(result.route.steps) == "table" then
                            local rk = result.raidKey
                            if RC.db and RC.GetActiveRaidProfile then
                                local profile = RC:GetActiveRaidProfile(rk)
                                if type(profile) == "table" then
                                    profile.route = RC.DeepCopy(result.route)
                                    if RC.SaveConfigurationToProfile then
                                        RC:SaveConfigurationToProfile()
                                    end
                                    if RC.RaidRoute then
                                        local RRm = RC.RaidRoute
                                        if RRm.NormalizeActive then RRm:NormalizeActive() end
                                        if RRm.UpdateArming    then RRm:UpdateArming()    end
                                        if RRm.RefreshTracker  then RRm:RefreshTracker()  end
                                        if RRm.RefreshUI       then RRm:RefreshUI()       end
                                    end
                                    RC:Print(RCL["Route for "] .. rk .. RCL[" received from "]
                                        .. buf.from .. RCL[" - applied to your active profile."])
                                    LogActivity("Applied shared route '" .. rk .. "' from " .. buf.from)
                                end
                            end
                        end
                        return
                    end

                    if buf.categoryId == "raidCfgFor" then
                        if not IsRosterMemberNs(buf.sessNs) then
                            RC:DebugPrint("MeshSync: ignored raidCfgFor from non-roster " .. tostring(buf.from), "meshsync")
                            return
                        end
                        if not RecvFromAllowed(from) then
                            LogActivity("Ignored remote raid config from " .. from .. " (not in your Accept From list)")
                            RC:DebugPrint("MeshSync: ignored raidCfgFor from " .. tostring(buf.from)
                                .. " (Accept From: selected accounts only)", "meshsync")
                            return
                        end
                        -- "Receive off for Raid Profiles" must protect raid
                        -- profiles on EVERY inbound path, not only the
                        -- payloads that route through ApplyInbound.
                        if _mss.charCfg and _mss.charCfg.recvCategories
                                and _mss.charCfg.recvCategories["raidProfiles"] == false then
                            RC:DebugPrint("MeshSync: ignored raidCfgFor from " .. tostring(buf.from)
                                .. " (Receive off for Raid Profiles)", "meshsync")
                            return
                        end
                        if type(result) == "table"
                                and type(result.raidKey) == "string"
                                and type(result.data)    == "table" then
                            local rk       = result.raidKey
                            local incoming = RC.DeepCopy(result.data)
                            if not RC.db then return end
                            if not RC.db.raidProfiles then RC.db.raidProfiles = {} end

                            -- Transport-only field: keep it out of whatever we
                            -- store, it is not part of a raid config.
                            local incomingList = incoming.profileList
                            incoming.profileList = nil

                            if incoming.profiles then
                                for _, pd in pairs(incoming.profiles) do
                                    if type(pd) == "table" and pd.bosses then
                                        for _, bd in pairs(pd.bosses) do
                                            if type(bd) == "table" and bd.abilities then
                                                local gs = bd.abilities.gearswap
                                                if type(gs) == "table" then
                                                    if gs.gearSet       == "" then gs.gearSet       = nil end
                                                    if gs.postCombatSet == "" then gs.postCombatSet = nil end
                                                    if gs.itemRackSet   == "" then gs.itemRackSet   = nil end
                                                end
                                            end
                                        end
                                    end
                                end
                            end

                            local activeName = incoming.activeProfile
                            if activeName and incoming.profiles
                                    and incoming.profiles[activeName] then
                                local rd = RC.db.raidProfiles[rk] or {}
                                RC.db.raidProfiles[rk] = rd
                                rd.activeProfile        = activeName
                                rd.profiles             = rd.profiles or {}
                                local existing   = rd.profiles[activeName]
                                local incomingPd = RC.DeepCopy(incoming.profiles[activeName])

                                if existing and existing.bosses and incomingPd.bosses then
                                    for bossName, incomingBoss in pairs(incomingPd.bosses) do
                                        if type(incomingBoss) == "table"
                                                and incomingBoss.abilities then
                                            local gs = incomingBoss.abilities.gearswap
                                            local hasGear = gs and type(gs) == "table"
                                                and (gs.gearSet or gs.postCombatSet
                                                     or gs.itemRackSet)
                                            if not hasGear then
                                                local eb = existing.bosses[bossName]
                                                if eb and eb.abilities
                                                        and eb.abilities.gearswap then
                                                    incomingBoss.abilities.gearswap =
                                                        RC.DeepCopy(eb.abilities.gearswap)
                                                end
                                            end
                                        end
                                    end
                                end

                                rd.profiles[activeName] = incomingPd
                            else
                                RC.db.raidProfiles[rk] = incoming
                            end

                            -- Apply profile removals. The sender ships the full
                            -- name list, so anything of ours that is absent was
                            -- deleted, renamed or merged away on their end. Only
                            -- ever prunes - a name we have no contents for is
                            -- never invented here.
                            if type(incomingList) == "table" and #incomingList > 0 then
                                local keep = {}
                                for _, pn in ipairs(incomingList) do keep[pn] = true end
                                local rd = RC.db.raidProfiles[rk]
                                if rd and type(rd.profiles) == "table" then
                                    local removed = {}
                                    for pn in pairs(rd.profiles) do
                                        if not keep[pn] then removed[#removed + 1] = pn end
                                    end
                                    -- Never strip the last profile: an empty raid
                                    -- config is worse than a stale extra one.
                                    local remaining = 0
                                    for _ in pairs(rd.profiles) do remaining = remaining + 1 end
                                    for _, pn in ipairs(removed) do
                                        if remaining > 1 then
                                            rd.profiles[pn] = nil
                                            remaining = remaining - 1
                                        end
                                    end
                                    if #removed > 0 then
                                        if rd.profiles[rd.activeProfile or ""] == nil then
                                            rd.activeProfile = incoming.activeProfile
                                                or next(rd.profiles)
                                        end
                                        RC:DebugPrint("raidCfgFor: removed " .. #removed
                                            .. " profile(s) for " .. rk .. " per "
                                            .. tostring(buf.from), "meshsync")
                                    end
                                end
                            end
                            RC:DebugPrint(string_format("raidCfgFor applied: %s from %s", rk, buf.from), "meshsync")
                            if RC.RaidRoute and RC.RaidRoute.raidName then
                                local RRm = RC.RaidRoute
                                if RRm.NormalizeActive then RRm:NormalizeActive() end
                                if RRm.UpdateArming    then RRm:UpdateArming()    end
                                if RRm.RefreshTracker  then RRm:RefreshTracker()  end
                                if RRm.RefreshUI       then RRm:RefreshUI()       end
                            end
                            LogActivity("Applied raid config '" .. rk .. "' from " .. buf.from)
                            C_Timer.After(0.15, function()
                                local cf = RC.sidebarConfigFrame
                                       and RC.sidebarConfigFrame.compatFrame
                                if not cf then return end
                                if not (RC.sidebarConfigFrame:IsShown()) then return end
                                local cs = cf.configState
                                if not (cs and cs.selectedRaid == rk) then return end

                                if cs.selectedEncounter and RC.ShowInlineAbilityConfig then
                                    local bossKey = cs.selectedEncounter
                                    cf._expandedAbility = cf._expandedAbility or {}
                                    if not cf._expandedAbility[bossKey] then
                                        local rd2   = RC.db and RC.db.raidProfiles
                                                      and RC.db.raidProfiles[rk]
                                        local an2   = rd2 and (rd2.activeProfile or "Default")
                                        local pd2   = rd2 and rd2.profiles and rd2.profiles[an2]
                                        local bc2   = pd2 and pd2.bosses and pd2.bosses[bossKey]
                                        if bc2 and bc2.abilities then
                                            for ak, ac in pairs(bc2.abilities) do
                                                if ac and ac.enabled then
                                                    cf._expandedAbility[bossKey] = ak
                                                    break
                                                end
                                            end
                                        end
                                    end
                                    local raidSettings = RC.GetActiveRaidProfile
                                        and RC:GetActiveRaidProfile(rk)
                                    RC:ShowInlineAbilityConfig(cf, rk,
                                        cs.selectedEncounter,
                                        cs.selectedEncounterType or "boss",
                                        raidSettings, true)
                                elseif rk then
                                    RC:OpenRaidBossPage(cf, rk)
                                end
                            end)
                            if sender then
                                local ns = NormalizeName(sender)
                                if ns then self:Broadcast(CMD_ACK, msgId, ns) end
                            end
                        end
                        return
                    end

                    if buf.categoryId == "raidCfgForEdit" then
                        if type(result) == "table"
                                and type(result.raidKey) == "string" then
                            if result.error == "nodata" or result.error == "toolarge" then
                                RC.remoteStagedRaidConfig = nil
                                RC:Print(string_format(
                                    result.error == "toolarge"
                                        and "Mesh: |cFFFFD700%s|r's config for |cFFFFD700%s|r is too large to fetch (they can trim profiles for that raid)."
                                        or  "Mesh: |cFFFFD700%s|r has no config for |cFFFFD700%s|r.",
                                    buf.from, result.raidKey))
                                local cf = RC.sidebarConfigFrame
                                       and RC.sidebarConfigFrame.compatFrame
                                if cf and RC.sidebarConfigFrame:IsShown()
                                        and RC.SidebarState
                                        and RC.SidebarState.currentPanel == "remote_raid_cfg" then
                                    C_Timer.After(0.05, function()
                                        RC:ShowSidebarRemoteRaidConfig(cf)
                                    end)
                                end
                                return
                            end

                            if type(result.data) == "table" then
                                local rk  = result.raidKey
                                local mbr = { name = sender, label = buf.from }
                                local gsn = type(result.gearSetNames) == "table" and result.gearSetNames or nil
                                C_Timer.After(0.05, function()
                                    if RC.EnterRemoteEditMode then
                                        RC:EnterRemoteEditMode(mbr, rk, result.data, gsn)
                                    end
                                end)
                                LogActivity("Received '" .. rk .. "' from " .. buf.from .. " (edit mode)")
                                RC:DebugPrint("MeshSync: entering edit mode for '" .. rk ..
                                    "' from " .. buf.from, "meshsync")
                                if sender then
                                    local ns = NormalizeName(sender)
                                    if ns then self:Broadcast(CMD_ACK, msgId, ns) end
                                end
                            else
                                RC.remoteStagedRaidConfig = nil
                                RC:Print(string_format(
                                    "Mesh: Received malformed config response from |cFFFFD700%s|r. Try fetching again.",
                                    buf.from))
                                RC:DebugPrint("MeshSync: raidCfgForEdit bad data field from " .. buf.from
                                    .. " type=" .. type(result.data), "meshsync")
                                local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                                if cf and RC.sidebarConfigFrame:IsShown()
                                        and RC.SidebarState
                                        and RC.SidebarState.currentPanel == "remote_raid_cfg" then
                                    C_Timer.After(0.05, function() RC:ShowSidebarRemoteRaidConfig(cf) end)
                                end
                            end
                        else
                            RC.remoteStagedRaidConfig = nil
                            RC:Print(RCL["Mesh: Config response had unexpected format. Try fetching again."])
                            RC:DebugPrint("MeshSync: raidCfgForEdit unexpected result type=" .. type(result), "meshsync")
                            local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                            if cf and RC.sidebarConfigFrame:IsShown()
                                    and RC.SidebarState
                                    and RC.SidebarState.currentPanel == "remote_raid_cfg" then
                                C_Timer.After(0.05, function() RC:ShowSidebarRemoteRaidConfig(cf) end)
                            end
                        end
                        return
                    end

                    -- Three gates before anything reaches the profile: on the
                    -- roster, allowed by Accept From, and the priority
                    -- account if one is set. ApplyInbound is pcall'd - it
                    -- writes deep into RC.db and a malformed payload must not
                    -- kill the handler. ACK only follows an apply attempt.
                    local prio = _mss.charCfg and _mss.charCfg.priorityAccount or ""
                    if not suppressInbound and not IsRosterMemberNs(buf.sessNs) then
                        RC:DebugPrint("MeshSync: ignored " .. tostring(buf.categoryId)
                            .. " apply from non-roster " .. tostring(buf.from), "meshsync")
                    elseif not suppressInbound and not RecvFromAllowed(from) then
                        LogActivity("Ignored push from " .. from .. " (not in your Accept From list)")
                        RC:DebugPrint("MeshSync: ignored data from " .. from
                            .. " (Accept From: selected accounts only)", "meshsync")
                    elseif not suppressInbound and (prio == "" or from == prio) then
                        local okApply, applyErr = pcall(self.ApplyInbound, self, buf.categoryId, result, buf.from, buf.isPartial)
                        if not okApply then
                            RC:DebugPrint("MeshSync: ApplyInbound failed for '"
                                .. tostring(buf.categoryId) .. "' from " .. tostring(buf.from)
                                .. ": " .. tostring(applyErr), "meshsync")
                        end
                        if sender then
                            local ns = NormalizeName(sender)
                            if ns then self:Broadcast(CMD_ACK, msgId, ns) end
                        end
                    elseif not suppressInbound then
                        LogActivity("Ignored push from " .. from .. " (not priority source)")
                        RC:DebugPrint("MeshSync: ignored data from " .. from .. " (not priority source)", "meshsync")
                    end
                else
                    -- Decode failed, so the reassembly is corrupt. Drop every
                    -- buffer from that sender: whatever went wrong is likely
                    -- to affect their other in-flight transfers too.
                    local es = tostring(err)
                    if #es > 70 then es = "..." .. es:sub(-70) end
                    RC:Print(RCL["Mesh: Failed to read data from "] .. from .. " - " .. es)
                    local pfx = tostring(sender or from) .. ":"
                    for k2 in pairs(inboundBuffers) do
                        if k2:sub(1, #pfx) == pfx then inboundBuffers[k2] = nil end
                    end
                    LogActivity("Error from " .. from .. ": " .. tostring(err):sub(1, 40))
                    if buf.categoryId == "raidCfgForEdit" then
                        RC.remoteStagedRaidConfig = nil
                        local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                        if cf and RC.sidebarConfigFrame:IsShown()
                                and RC.SidebarState
                                and RC.SidebarState.currentPanel == "remote_raid_cfg" then
                            C_Timer.After(0.05, function() RC:ShowSidebarRemoteRaidConfig(cf) end)
                        end
                    end
                end
            end
            return
        end
    end

    -- MAINT_INTERVAL housekeeping: re-read the per-character switch, rejoin
    -- a discovery channel the client dropped, expire stalled buffers and
    -- silent peers, and emit the HELLO heartbeat.
    local function Maintenance()
        local now = GetTime()
        _mss.isEnabled = GetCharEnabled()
        if _mss.isEnabled and _mss.isChannelJoined
                and _mss.cfg and _mss.cfg.discoveryChannel
                and _mss.cfg.discoveryChannel ~= "" then
            local chanId = GetChannelName(_mss.cfg.discoveryChannel)
            if not chanId or chanId == 0 then
                _mss.isChannelJoined = false
                RC:Print(RCL["Mesh: discovery channel was dropped by the client - rejoining."])
                JoinDiscoveryChannel()
            end
        end
        for k, buf in pairs(inboundBuffers) do
            if buf.timeout < now then
                RC:DebugPrint(string_format(
                    "MeshSync: dropped stalled transfer %s (%s from %s, %d/%d chunks)",
                    k, tostring(buf.categoryId), tostring(buf.from),
                    buf.received or 0, buf.total or 0), "meshsync")
                RC:Print(RCL["Mesh: transfer of "] .. tostring(buf.categoryId) .. RCL[" from "]
                    .. tostring(buf.from) .. RCL[" failed ("] .. (buf.received or 0) .. "/"
                    .. (buf.total or 0) .. RCL[" parts) and was dropped. Use Request in the Actions tab."])
                inboundBuffers[k] = nil
                local sNs = buf.sessNs or NormalizeName(buf.from)
                local s = sNs and recvSessions[sNs]
                if s then
                    local lost = (buf.total or 0) - (buf.received or 0)
                    s.discovered = math.max(s.received, (s.discovered or 0) - lost)
                    if s.declared then
                        s.declared = math.max(s.received, s.declared - lost)
                    end
                    UpdateRecvRow()
                    if s.received >= SessionTotal(s) then CheckRecvSessionDone(sNs) end
                end
            end
        end
        for ns, s in pairs(recvSessions) do
            if (now - (s.lastAt or 0)) > 60 and s.received < SessionTotal(s) then
                recvSessions[ns] = nil
                UpdateRecvRow()
            end
        end
        -- Silence past ACCOUNT_TIMEOUT means offline (their queued chunks are
        -- dropped); past twice that the peer is forgotten entirely, which
        -- also discards its cached digest so the next HELLO full-syncs.
        for label, acct in pairs(knownAccounts) do
            if acct.online and (now - acct.lastSeen) > ACCOUNT_TIMEOUT then
                acct.online = false
                LogActivity(label .. " timed out")
                if acct.charName then
                    _mss.AbortQueuedFor(NormalizeName(acct.charName), label)
                end
            elseif not acct.online and (now - acct.lastSeen) > (ACCOUNT_TIMEOUT * 2) then
                knownAccounts[label] = nil
            end
        end
        -- Skipped while a transfer is draining: every chunk already
        -- refreshes presence on the far side, and in an instance the
        -- heartbeat alone can outrun the 1/s send rate.
        if _mss.isEnabled and _mss.sendPending == 0
                and (now - _mss.lastHelloTime) >= HELLO_INTERVAL then
            -- Whispered members get the full digest; the cross-faction yell
            -- copy gets the compact one so it survives base64 inflation.
            MS:Broadcast(CMD_HELLO, BuildHelloData(), nil, nil, BuildHelloData(true))
            -- CAP rides every fifth heartbeat as a safety net for a peer
            -- that missed the bootstrap exchange.
            _mss.helloCount = (_mss.helloCount or 0) + 1
            if _mss.helloCount % 5 == 0 then
                MS:Broadcast(_mss.CMD_CAP, tostring(_mss.PROTO_VERSION or 1))
            end
            _mss.lastHelloTime = now
        end
    end

    function MS:PrintStatus()
        local W = RC
        W:Print(RCL["Mesh status for "] .. GetToonKey() .. ":")
        W:Print(RCL["  Mesh switch: "] .. (GetCharEnabled() and "ON" or "OFF (nothing sends while off)"))
        W:Print(RCL["  Auto sync: "] .. ((_mss.charCfg and _mss.charCfg.autoBroadcast) and "ON" or "OFF"))
        local rules, total = 0, 0
        for _, c in ipairs(MS.SYNC_CATEGORIES) do
            total = total + 1
            if _mss.charCfg and _mss.charCfg.syncCategories and _mss.charCfg.syncCategories[c.id] then
                rules = rules + 1
            end
        end
        -- Name the categories rather than just counting them. "1/31 enabled"
        -- looks the same whether that one is the category you wanted or a
        -- leftover, which is exactly how the TTK-only state hid for so long.
        local sendNames, recvOff = {}, {}
        for _, c in ipairs(MS.SYNC_CATEGORIES) do
            local cc = _mss.charCfg
            if cc and cc.syncCategories and cc.syncCategories[c.id] then
                sendNames[#sendNames+1] = c.label or c.id
            end
            if cc and cc.recvCategories and cc.recvCategories[c.id] == false then
                recvOff[#recvOff+1] = c.label or c.id
            end
        end
        W:Print(RCL["  Send: "] .. rules .. "/" .. total .. " -> "
            .. (#sendNames > 0 and table_concat(sendNames, ", ")
                or "|cFFFF6644NOTHING - this character broadcasts no settings|r"))
        W:Print(RCL["  Receive blocked: "] .. (#recvOff > 0
            and table_concat(recvOff, ", ") or "none (all categories accepted)"))

        -- Per-setting rules, one line per direction. Only categories that
        -- are partially on are named; a whole category on or off is
        -- already covered by the two lines above.
        local cc = _mss.charCfg
        local function PartialLines(counter)
            local out = {}
            for _, c in ipairs(MS.SYNC_CATEGORIES) do
                local on, tot = counter(MS, c.id)
                if tot > 0 and on > 0 and on < tot then
                    out[#out+1] = (c.label or c.id) .. " (" .. on .. "/" .. tot .. ")"
                end
            end
            return out
        end
        local sendPartial = cc and PartialLines(MS.CountSendState) or {}
        local recvPartial = cc and PartialLines(MS.CountRecvState) or {}
        W:Print(RCL["  Send, per setting: "] .. (#sendPartial > 0
            and table_concat(sendPartial, ", ") or "none (whole categories)"))
        W:Print(RCL["  Receive, per setting: "] .. (#recvPartial > 0
            and table_concat(recvPartial, ", ") or "none (whole categories)"))
        W:Print(RCL["  Send queue: "] .. _mss.sendPending .. RCL[" message(s) waiting"])
        local ago = _mss.lastHelloTime > 0 and math.floor(GetTime() - _mss.lastHelloTime) or -1
        W:Print(RCL["  Last heartbeat sent: "] .. (ago >= 0 and (ago .. RCL["s ago"]) or "never this session"))
        local n = 0
        for label, acct in pairs(knownAccounts) do
            n = n + 1
            local seen = math.floor(GetTime() - (acct.lastSeen or 0))
            W:Print(RCL["  Peer "] .. tostring(label) .. ": "
                .. (acct.online and "online" or "offline")
                .. RCL[", last seen "] .. seen .. RCL["s ago"])
        end
        if n == 0 then W:Print(RCL["  Peers: none heard from this session"]) end
        -- Same-account handoff is what alts on one Battle.net actually use, so
        -- list the snapshots by name and source rather than just counting them.
        -- Store shape: state[toonKey][categoryId] = entry (per-character since
        -- the flat-slot store was retired); un-migrated flat entries still
        -- show, labeled by their own fromChar.
        local st = ReadycheckDB and ReadycheckDB.meshSameAccountState
        local sn = 0
        local rows = {}
        if st then
            local now = time()
            local myKey = GetToonKey()
            local function AddRow(catId, e)
                sn = sn + 1
                local catLabel = catId
                for _, c in ipairs(MS.SYNC_CATEGORIES) do
                    if c.id == catId then catLabel = c.label or c.id; break end
                end
                local age = math.floor((now - (e.savedAt or now)) / 60)
                rows[#rows+1] = "    " .. catLabel
                    .. " |cFF999999from|r " .. tostring(e.fromChar)
                    .. " |cFF999999(" .. age .. "m ago)|r"
                    .. ((e.fromChar == myKey) and " |cFF999999<- this toon, not applied here|r" or "")
            end
            for k, v in pairs(st) do
                if type(v) == "table" and v.fromChar and v.data ~= nil then
                    AddRow(k, v)              -- old flat shape, pre-migration
                elseif type(v) == "table" then
                    for catId, e in pairs(v) do
                        if type(e) == "table" and e.data ~= nil then AddRow(catId, e) end
                    end
                end
            end
        end
        W:Print(RCL["  Same-account snapshots on file: "] .. sn)
        if sn > 0 then
            for _, line in ipairs(rows) do W:Print(line) end
        else
            W:Print("    |cFFFF6644No snapshots stored.|r Log out on the source character "
                .. "with Send ticked to create them.")
        end
    end

    function MS:SerializeTable(t)   return Serialize(t)   end
    function MS:DeserializeTable(s) return Deserialize(s) end
    function MS:ShareRoute(raidKey, route, targetMember)
        if not _mss.isEnabled then RC:Print(RCL["Mesh: Not enabled."]); return false end
        if not raidKey or type(route) ~= "table" or type(route.steps) ~= "table"
           or #route.steps == 0 then
            RC:Print(RCL["Nothing to share - this raid's route has no steps."])
            return false
        end
        local n = PushRawPayload("routeShare",
            { raidKey = raidKey, route = RC.DeepCopy(route) }, targetMember, true, raidKey)
        if n then
            LogActivity("Shared route '" .. raidKey .. "'"
                .. (targetMember and (" to " .. (targetMember.label or targetMember.name)) or " to all members"))
            RC:Print(RCL["Route for "] .. raidKey .. RCL[" shared to "]
                .. (targetMember and (targetMember.label or targetMember.name) or "all mesh members") .. ".")
            return true
        end
        return false
    end

    function MS:IsEnabled()          return _mss.isEnabled end
    function MS:IsChannelJoined()    return _mss.isChannelJoined end
    function MS:JoinDiscoveryChannel()  JoinDiscoveryChannel() end
    function MS:LeaveDiscoveryChannel() LeaveDiscoveryChannel() end
    function MS:GetKnownAccounts()   return knownAccounts end
    function MS:IsCharOnline(charName)
        local ns = NormalizeName(charName)
        if not ns then return false end
        local rec = knownChars[ns]
        return (rec and rec.seenAt and (GetTime() - rec.seenAt) < ACCOUNT_TIMEOUT) or false
    end
    function MS:GetConfig()          return _mss.cfg end
    function MS:GetCharConfig()      return _mss.charCfg end
    function MS:GetMembers()         return (_mss.cfg and _mss.cfg.members) or {} end

    function MS:RefreshMeshUI()
        if RC.meshSyncUIRefresh then RC.meshSyncUIRefresh() end
    end

_mss.Maintenance = Maintenance
_mss.PushRawPayload = PushRawPayload
