------------------------------------------------------------------------
-- Readycheck - Mesh Transport
-- Wire format, codecs, hashing, send queue and the outbound API for the
-- mesh. Mesh_Inbound.lua dispatches whatever this file puts on the wire.
--
-- Wire: <marker>#<from>#<msgId>#<seq>#<tot>#<token>#<cmd>#<data>
--   marker  RC1 = literal Serialize(); RC2 = LibSerialize + LibDeflate,
--           used only when the peer announced CAP >= 2
--   from    account label, 15 chars max, "#" stripped
--   msgId   4 hex digits, per-session counter from a random start
--   seq/tot 3 digits each, 999 chunks max; chunks fill 255 - #header
--   token   djb2 of the mesh password, 8 hex; "00000000" means unset
--   cmd     command word - vocabulary is listed in Mesh_Inbound.lua
--
-- Two send paths. MS:Broadcast builds exactly ONE message and never
-- chunks, so every control command must fit a single addon message;
-- ChunkData/ChunkForTarget + EnqueueMessages carry PUSH_/REQ_ payloads.
-- Both cross-faction legs (base64 YELL fanout, BNet "RCMESH:" whisper)
-- are single-message only.
--
-- SYNC_CATEGORIES is built from RC.EXPORT_CATEGORIES: new persistable db
-- keys must be registered there or they never sync. Its ORDER is part of
-- the protocol - the HELLO digest is positional.
------------------------------------------------------------------------
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

    local ADDON_PREFIX   = "RCMESH"
    local PROTO_MARKER   = "RC1"
    local PROTO_SEP      = "#"

    -- SEND_INTERVAL is the send-queue TICK, and also the send rate out in
    -- the world, where whispers are exempt from the addon-message
    -- throttle. It is NOT "what the throttle tolerates indefinitely" -
    -- that claim was wrong and cost every in-instance bulk sync. The
    -- documented allowance is 10 messages refilling at 1/second, so
    -- inside an instance the rate drops to SEND_INTERVAL_INSTANCE; see
    -- CurrentSendInterval. BUFFER_TIMEOUT and ACCOUNT_TIMEOUT at 300
    -- outlast a long transfer at the world rate. ChunkData derives the
    -- chunk size from the real header length.
    local MAX_LABEL_LEN  = 15
    local MAX_MESH_MEMBERS = 100
    local BUFFER_TIMEOUT = 300
    local ACCOUNT_TIMEOUT    = 300
    local HELLO_INTERVAL     = 60
    local MAINT_INTERVAL     = 30
    local SEND_INTERVAL      = 0.12
    local POLL_SAFETY_RESCAN = 30

    -- Control commands. All of these travel via MS:Broadcast, so each one
    -- has to fit one 255 byte addon message including its header.
    -- PROTO_VERSION is announced with CAP and gates the RC2 codec.
    local CMD_HELLO     = "HELLO"
    local CMD_BYE       = "BYE"
    local CMD_ACK       = "ACK"
    local CMD_PUSH_DONE = "PUSH_DONE"
    local CMD_PUSH_ACK  = "PUSH_ACK"
    local CMD_BATCH_SIZE = "SYNC_TOTAL"
    local PROTO_VERSION = 3
    local CMD_CAP       = "CAP"

    -- HELLO carries a digest of every sync category so peers can skip pushing
    -- data the other side already has. It must fit in ONE addon message
    -- (Broadcast never chunks), which is why the digest is a positional array
    -- rather than an id->hash map: 5 bytes per category instead of ~20.
    local HELLO_V3_MARK  = "H3"
    local HELLO_HASH_LEN = 5
    -- Addon messages cap at 255 bytes total. The HELLO header runs to ~48 with
    -- a max-length account label; 64 leaves margin.
    local HELLO_MAX_DATA = 255 - 64
    -- The cross-faction YELL path base64-encodes header+data before sending,
    -- inflating it 4/3, so its raw budget is far smaller.
    local HELLO_MAX_YELL_DATA = math_floor(255 / 4) * 3 - 64

    MS.SYNC_CATEGORIES = {}
    local function RebuildSyncCategories()
    MS.SYNC_CATEGORIES = {}
    if RC.EXPORT_CATEGORIES then
        for _, cat in ipairs(RC.EXPORT_CATEGORIES) do
            -- Retired categories keep their registry row (old exports may
            -- still reference them) but must not occupy a positional HELLO
            -- digest slot, a config entry, or a Sync Rules count. The
            -- layout fingerprint forces one full sync against peers still
            -- running the old layout, which is the intended recovery.
            if not cat.retired then
            local keys = {}
            for _, k in ipairs(cat.keys) do
                if cat.id ~= "gearManager"
                        or (k ~= "gearButtons" and k ~= "gearButtonPositions"
                            and k ~= "gearPinnedButtons") then
                    keys[#keys+1] = k
                end
            end
            -- `addon` (owner-only feature) is carried for the UI lists
            -- only; the category keeps its digest slot on every client so
            -- the layout fingerprint matches with or without that addon.
            MS.SYNC_CATEGORIES[#MS.SYNC_CATEGORIES + 1] = {
                id    = cat.id,
                label = cat.label,
                group = cat.group,
                keys  = keys,
                addon = cat.addon,
            }
            end
        end
    end
    -- Button layout is lifted out of gearManager into its own category so
    -- it can be shared (or withheld) independently of the manager settings.
    MS.SYNC_CATEGORIES[#MS.SYNC_CATEGORIES + 1] = {
        id    = "gearButtons",
        label = RCL["Dockable Gear Buttons"],
        group = "Equipment",
        keys  = {"gearButtons","gearButtonPositions","gearPinnedButtons"},
    }
    end
    RebuildSyncCategories()
    MS.RebuildSyncCategories = RebuildSyncCategories

    -- Category ids are persisted per character. When settings pages are
    -- reorganised, ids can disappear while their saved entries stay behind -
    -- leaving a category flagged for Send that no longer maps to anything, and
    -- making the Sync Rules page disagree with what actually broadcasts.
    local function PruneUnknownCategoryFlags(t)
        if type(t) ~= "table" then return 0 end
        local valid = {}
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do valid[cat.id] = true end
        local removed = 0
        for id in pairs(t) do
            if not valid[id] then
                t[id] = nil
                removed = removed + 1
            end
        end
        return removed
    end
    MS.PruneUnknownCategoryFlags = PruneUnknownCategoryFlags

    local function EachSendTarget(fn)
        local cc = _mss.charCfg
        if not cc or type(cc.syncCategories) ~= "table" then return end
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do fn(cc.syncCategories, cat.id) end
    end


    -- Bulk edits to the Send set are destructive in a non-obvious way: at
    -- logout WriteSameAccountSync deletes this character's stored snapshots for
    -- every category that is no longer ticked. Keep one level of undo so a
    -- mis-click is recoverable.
    local function SnapshotSendSet()
        local cc = _mss.charCfg
        if not cc or type(cc.syncCategories) ~= "table" then return end
        local prev = {}
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            prev[cat.id] = cc.syncCategories[cat.id] and true or false
        end
        MS._prevSendSet = prev
    end
    MS.SnapshotSendSet = SnapshotSendSet

    function MS:UndoSendChange()
        local cc = _mss.charCfg
        if not cc or not MS._prevSendSet then return nil end
        cc.syncCategories = cc.syncCategories or {}
        for id, v in pairs(MS._prevSendSet) do cc.syncCategories[id] = v end
        MS._prevSendSet = nil
        return self:CountSendCategories()
    end

    function MS:HasSendUndo() return MS._prevSendSet ~= nil end

    -- Bulk Send helpers. The UI drives these so the "which categories am I
    -- actually broadcasting" answer lives in one place.
    -- Both presets reset EVERY per-setting state as well as the category
    -- flags: "Send Everything" means every row on, "Send Nothing" every row
    -- off, with no per-key leftovers waiting to surprise the next tick.
    function MS:SetAllSendCategories(value)
        SnapshotSendSet()
        local v = value and true or false
        EachSendTarget(function(t, id) t[id] = v end)
        local cc = _mss.charCfg
        if cc then
            cc.excludedKeys = {}
            -- Aliased rows (kill history, boss-config gear) follow the preset.
            cc.syncFightHistory = v
            cc.syncRaidGear     = v
        end
        return self:CountSendCategories()
    end

    function MS:SetAllRecvCategories(value)
        local cc = _mss.charCfg
        if not cc then return 0 end
        cc.recvCategories = cc.recvCategories or {}
        local v = value and true or false
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do cc.recvCategories[cat.id] = v end
        cc.recvExcludedKeys = {}
        return self:CountRecvCategories()
    end

    -- Send this one category and nothing else - the "just the Battle Shout
    -- party tracker" case. This unticks everything else, which at next logout
    -- also clears this character's stored same-account snapshots for those
    -- categories; snapshot first so it can be undone.
    function MS:SoloSendCategory(categoryId)
        SnapshotSendSet()
        EachSendTarget(function(t, id) t[id] = (id == categoryId) end)
        return self:CountSendCategories()
    end

    -- Categories the user should see listed. A category tied to an
    -- owner-only addon (cat.addon, PM_Registry) is hidden while that addon
    -- is absent; it still occupies its digest slot and still syncs.
    local function IsCategoryVisible(cat)
        if RC.IsSettingCategoryAvailable then
            return RC:IsSettingCategoryAvailable(cat)
        end
        return true
    end
    MS.IsCategoryVisible = IsCategoryVisible

    -- Counts and labels are user readouts, so they cover the visible
    -- categories only; the flag loops above still walk every category.
    function MS:CountSendCategories()
        local cc = _mss.charCfg
        local on, total = 0, 0
        local flags = cc and type(cc.syncCategories) == "table" and cc.syncCategories
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            if IsCategoryVisible(cat) then
                total = total + 1
                if flags and flags[cat.id] then on = on + 1 end
            end
        end
        return on, total
    end

    function MS:CountRecvCategories()
        local cc = _mss.charCfg
        local on, total = 0, 0
        local rc = cc and cc.recvCategories
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            if IsCategoryVisible(cat) then
                total = total + 1
                if cc and (not rc or rc[cat.id] ~= false) then on = on + 1 end
            end
        end
        return on, total
    end

    -- Labels of every category currently flagged for Send, for UI readouts.
    function MS:GetSendCategoryLabels()
        local cc = _mss.charCfg
        local out = {}
        if cc and type(cc.syncCategories) == "table" then
            for _, cat in ipairs(MS.SYNC_CATEGORIES) do
                if cc.syncCategories[cat.id] and IsCategoryVisible(cat) then
                    out[#out + 1] = cat.label or cat.id
                end
            end
        end
        return out
    end

    -- RETIRED bundle flags ("Include screen anchor position", "Include
    -- trinket bar", ...). Each used to be one charCfg boolean that stripped
    -- a group of keys both ways. Every one of those keys is now an ordinary
    -- per-setting row with its own Send and Receive state, so this table is
    -- read exactly once: by the InitConfig migration that turns a flag left
    -- at false into per-key exclusions, then clears the flag. Nothing else
    -- may read these flag names.
    local LEGACY_BUNDLE_RULES = {
        { cat="raidProfiles", flag="syncRaidRoute",        dflt=true,  keys={"raidRoute"} },
        { cat="general",  flag="syncGeneralPosition",   dflt=false, keys={"anchorPoint","xOffset","yOffset"} },
        { cat="general",  flag="syncGeneralAppearance", dflt=true,
          keys={"iconSize","iconSpacing","showIconText","iconGlow","animationType","fadeInTime","fadeTime"} },
        { cat="general",  flag="syncGeneralSounds",     dflt=true,  keys={"soundEnabled","ttsEnabled"} },
        { cat="statsBar", flag="syncStatsBarPosition",  dflt=true,  keys={"statsBarPosition"} },
        { cat="statsBar", flag="syncStatsBarColors",    dflt=true,  keys={"statsBarColors"} },
        { cat="statsBar", flag="syncStatsBarStats",     dflt=true,  keys={"statsBarStats"} },
        { cat="sidebar",  flag="syncSidebarLayout",     dflt=true,
          keys={"sidebarPosition","configWindowWidth","configWindowHeight"} },
        { cat="abilityReminders", flag="syncAbilitySound", dflt=true, keys={"soundKey","soundFile"} },
        { cat="gearManager", flag="syncEnchantPreference", dflt=true, keys={"itemEnchantPreference"} },
        { cat="hotswap", flag="syncHotswapMessages", dflt=true,
          keys={"hotswapAnnounceChannel","hotswapAnnounceMessage","hotswapCombatBlockMessage"} },
        { cat="bars", flag="syncTrinketBar", dflt=true, keys={"trinketBar"} },
        { cat="bars", flag="syncWeaponsBar", dflt=true, keys={"weaponsBar"} },
        { cat="bars", flag="syncPotionsBar", dflt=true, keys={"potionsBar"} },
    }

    -- Per-setting rows that exist only for the mesh: they name a content
    -- filter rather than a db field. "raidProfiles.gear" is the gear swap
    -- data nested inside every boss config - its Send side is the existing
    -- syncRaidGear switch (read by the push/hash/remote paths), its Receive
    -- side is an ordinary receive exclusion honoured in ApplyInbound.
    MS.VIRTUAL_SETTINGS = {
        raidProfiles = { "raidProfiles.gear" },
    }
    local VIRTUAL_PATHS = { ["raidProfiles.gear"] = true }

    -- Paths whose SEND state is an existing charCfg flag that other code
    -- reads directly (delta logic, hashing, remote raid config). The picker
    -- shows them as ordinary rows; IsKeyIncluded/SetKeyIncluded route to
    -- the flag instead of the exclusion table.
    local SEND_FLAG_ALIAS = {
        ["executeSettings.fightHistory"] = "syncFightHistory",
        ["raidProfiles.gear"]            = "syncRaidGear",
    }

    -- Exclusion entries are paths, not just keys: "statsBarColors.hit" or
    -- "battleShoutPartyTracker.showOnlyMissing". 18 of the 31 categories are a
    -- single db key holding one table, so top-level keys alone give no real
    -- granularity - the individual settings live inside those tables.
    local function SplitPath(path)
        local head, rest = string_match(path, "^([^%.]+)%.(.+)$")
        if head then return head, rest end
        return path, nil
    end
    _mss.SplitPath = SplitPath

    local function HasNestedSkips(skip)
        if not skip then return false end
        for k in pairs(skip) do
            if string_find(k, ".", 1, true) then return true end
        end
        return false
    end

    -- Copy of `value` with excluded sub-paths removed. Never mutates the
    -- source: outbound payloads alias RC.db directly, so stripping in place
    -- would delete the player's real settings.
    local function StripNestedCopy(value, key, skip)
        if type(value) ~= "table" or not skip then return value end
        local out, copied = value, false
        for path in pairs(skip) do
            local head, rest = SplitPath(path)
            if head == key and rest then
                if not copied then
                    out = RC.DeepCopy and RC.DeepCopy(value) or value
                    copied = true
                end
                local t, cur = out, rest
                while t do
                    local h, r = SplitPath(cur)
                    if not r then t[h] = nil; break end
                    t = t[h]
                    if type(t) ~= "table" then break end
                    cur = r
                end
            end
        end
        return out
    end
    _mss.StripNestedCopy = StripNestedCopy
    _mss.HasNestedSkips  = HasNestedSkips

    -- Per-setting, per-direction state. Two tables of the same shape on
    -- charCfg, keyed [categoryId][path] = true for EXCLUDED:
    --   excludedKeys      what this character withholds when it sends
    --   recvExcludedKeys  what this character refuses when it receives
    -- A path with no entry is included. An entry on a PARENT path
    -- ("trinketBar") also covers everything under it ("trinketBar.locked"),
    -- which is how the retired bundle flags migrate without needing the
    -- child list at login; re-including one child expands the parent entry
    -- into explicit sibling entries (see SetExcluded).
    local function ExclusionTable(cc, recvSide)
        return recvSide and cc.recvExcludedKeys or cc.excludedKeys
    end

    -- The set of paths to strip for one direction, or nil when nothing is
    -- excluded. Virtual rows never enter it: they are not payload fields.
    local function StripKeySet(categoryId, recvSide)
        local cc = _mss.charCfg
        if not cc then return nil end
        local skip
        local t = ExclusionTable(cc, recvSide)
        local ex = t and t[categoryId]
        if ex then
            for k, v in pairs(ex) do
                if v and not VIRTUAL_PATHS[k] then
                    skip = skip or {}
                    skip[k] = true
                end
            end
        end
        return skip
    end
    _mss.StripKeySet = StripKeySet

    -- Every db key a category can carry, in declaration order.
    function MS:GetCategoryKeys(categoryId)
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            if cat.id == categoryId then return cat.keys or {} end
        end
        return {}
    end

    -- true when `path` or any of its ancestors is excluded in `ex`.
    local function PathExcluded(ex, path)
        if not ex then return false end
        if ex[path] then return true end
        local cur = path
        while true do
            local parent = string_match(cur, "^(.+)%.[^%.]+$")
            if not parent then return false end
            if ex[parent] then return true end
            cur = parent
        end
    end

    local function IsUnder(path, prefix)
        return string_sub(path, 1, #prefix + 1) == prefix .. "."
    end

    -- Writes one path's excluded state. Re-including a path whose ANCESTOR
    -- carries the exclusion replaces that ancestor entry with explicit
    -- entries for every other row under it, so the rest stays excluded.
    local function SetExcluded(cc, categoryId, path, excluded, recvSide)
        local field = recvSide and "recvExcludedKeys" or "excludedKeys"
        cc[field] = cc[field] or {}
        local t = cc[field]
        if excluded then
            t[categoryId] = t[categoryId] or {}
            t[categoryId][path] = true
            return
        end
        local ex = t[categoryId]
        if not ex then return end
        local cur = path
        while true do
            local parent = string_match(cur, "^(.+)%.[^%.]+$")
            if not parent then break end
            if ex[parent] then
                ex[parent] = nil
                for _, s in ipairs(MS:GetCategorySettings(categoryId)) do
                    if IsUnder(s.path, parent) and s.path ~= path
                            and not IsUnder(s.path, path)
                            and not VIRTUAL_PATHS[s.path] then
                        ex[s.path] = true
                    end
                end
            end
            cur = parent
        end
        ex[path] = nil
        if next(ex) == nil then t[categoryId] = nil end
    end

    -- ---- Send side --------------------------------------------------
    function MS:IsKeyIncluded(categoryId, key)
        local cc = _mss.charCfg
        if not cc then return true end
        local flag = SEND_FLAG_ALIAS[key]
        if flag then return cc[flag] == true end
        return not PathExcluded(cc.excludedKeys and cc.excludedKeys[categoryId], key)
    end

    function MS:SetKeyIncluded(categoryId, key, included)
        local cc = _mss.charCfg
        if not cc then return end
        local flag = SEND_FLAG_ALIAS[key]
        if flag then cc[flag] = included and true or false; return end
        SetExcluded(cc, categoryId, key, not included, false)
    end

    function MS:SetAllKeysIncluded(categoryId, included)
        local cc = _mss.charCfg
        if not cc then return end
        cc.excludedKeys = cc.excludedKeys or {}
        local t = nil
        if not included then t = {} end
        for _, s in ipairs(MS:GetCategorySettings(categoryId)) do
            local flag = SEND_FLAG_ALIAS[s.path]
            if flag then
                cc[flag] = included and true or false
            elseif t then
                t[s.path] = true
            end
        end
        cc.excludedKeys[categoryId] = t
    end

    -- ---- Receive side -----------------------------------------------
    function MS:IsKeyReceived(categoryId, key)
        local cc = _mss.charCfg
        if not cc then return true end
        return not PathExcluded(cc.recvExcludedKeys and cc.recvExcludedKeys[categoryId], key)
    end

    function MS:SetKeyReceived(categoryId, key, received)
        local cc = _mss.charCfg
        if not cc then return end
        SetExcluded(cc, categoryId, key, not received, true)
    end

    function MS:SetAllKeysReceived(categoryId, received)
        local cc = _mss.charCfg
        if not cc then return end
        cc.recvExcludedKeys = cc.recvExcludedKeys or {}
        if received then
            cc.recvExcludedKeys[categoryId] = nil
        else
            local t = {}
            for _, s in ipairs(MS:GetCategorySettings(categoryId)) do t[s.path] = true end
            cc.recvExcludedKeys[categoryId] = t
        end
    end

    -- Send this one setting and nothing else, anywhere.
    function MS:SoloSendKey(categoryId, key)
        MS:SoloSendCategory(categoryId)
        MS:SetAllKeysIncluded(categoryId, false)
        MS:SetKeyIncluded(categoryId, key, true)
    end

    -- ---- Effective per-row state (category gate AND per-key state) ---
    -- What the Sync Rules list shows and edits. A category whose flag is off
    -- sends nothing, so every row under it reads as off; ticking one row of
    -- an off category turns the category on with ONLY that row included, so
    -- what the player saw (everything else off) is what now happens.
    function MS:GetKeySendState(categoryId, path)
        local cc = _mss.charCfg
        if not cc or not cc.syncCategories or cc.syncCategories[categoryId] ~= true then
            return false
        end
        return MS:IsKeyIncluded(categoryId, path)
    end

    function MS:SetKeySendState(categoryId, path, on)
        local cc = _mss.charCfg
        if not cc then return end
        cc.syncCategories = cc.syncCategories or {}
        if on then
            if cc.syncCategories[categoryId] ~= true then
                cc.syncCategories[categoryId] = true
                MS:SetAllKeysIncluded(categoryId, false)
            end
            MS:SetKeyIncluded(categoryId, path, true)
        else
            MS:SetKeyIncluded(categoryId, path, false)
            local n = MS:CountIncludedKeys(categoryId)
            if n == 0 then
                -- Last row off: the category itself goes off and its
                -- exclusion list is cleared, so re-ticking the header
                -- brings everything back rather than an empty category.
                -- Aliased flags are left alone: the category gate already
                -- reads them as off, and flipping them on here would leak
                -- into the flag readers that run outside category pushes.
                cc.syncCategories[categoryId] = false
                if cc.excludedKeys then cc.excludedKeys[categoryId] = nil end
            end
        end
    end

    function MS:GetKeyRecvState(categoryId, path)
        local cc = _mss.charCfg
        if not cc then return true end
        local rc = cc.recvCategories
        if rc and rc[categoryId] == false then return false end
        return MS:IsKeyReceived(categoryId, path)
    end

    function MS:SetKeyRecvState(categoryId, path, on)
        local cc = _mss.charCfg
        if not cc then return end
        cc.recvCategories = cc.recvCategories or {}
        if on then
            if cc.recvCategories[categoryId] == false then
                cc.recvCategories[categoryId] = true
                MS:SetAllKeysReceived(categoryId, false)
            end
            MS:SetKeyReceived(categoryId, path, true)
        else
            MS:SetKeyReceived(categoryId, path, false)
            local n = MS:CountReceivedKeys(categoryId)
            if n == 0 then
                cc.recvCategories[categoryId] = false
                MS:SetAllKeysReceived(categoryId, true)
            end
        end
    end

    -- Several paths at once, same rules as the single-path form: this is
    -- what a group row ("Position & Lock") drives.
    function MS:SetKeysSendState(categoryId, paths, on)
        local cc = _mss.charCfg
        if not cc then return end
        cc.syncCategories = cc.syncCategories or {}
        if on then
            if cc.syncCategories[categoryId] ~= true then
                cc.syncCategories[categoryId] = true
                MS:SetAllKeysIncluded(categoryId, false)
            end
            for _, p in ipairs(paths) do MS:SetKeyIncluded(categoryId, p, true) end
        else
            for _, p in ipairs(paths) do MS:SetKeyIncluded(categoryId, p, false) end
            local n = MS:CountIncludedKeys(categoryId)
            if n == 0 then
                cc.syncCategories[categoryId] = false
                if cc.excludedKeys then cc.excludedKeys[categoryId] = nil end
            end
        end
    end

    function MS:SetKeysRecvState(categoryId, paths, on)
        local cc = _mss.charCfg
        if not cc then return end
        cc.recvCategories = cc.recvCategories or {}
        if on then
            if cc.recvCategories[categoryId] == false then
                cc.recvCategories[categoryId] = true
                MS:SetAllKeysReceived(categoryId, false)
            end
            for _, p in ipairs(paths) do MS:SetKeyReceived(categoryId, p, true) end
        else
            for _, p in ipairs(paths) do MS:SetKeyReceived(categoryId, p, false) end
            local n = MS:CountReceivedKeys(categoryId)
            if n == 0 then
                cc.recvCategories[categoryId] = false
                if cc.recvExcludedKeys then cc.recvExcludedKeys[categoryId] = nil end
            end
        end
    end

    -- Send these paths and nothing else, anywhere.
    function MS:SoloSendKeys(categoryId, paths)
        MS:SoloSendCategory(categoryId)
        MS:SetAllKeysIncluded(categoryId, false)
        for _, p in ipairs(paths) do MS:SetKeyIncluded(categoryId, p, true) end
    end

    -- on/total across an explicit path list (a group row).
    function MS:CountSendStateFor(categoryId, paths)
        local on = 0
        for _, p in ipairs(paths) do
            if MS:GetKeySendState(categoryId, p) then on = on + 1 end
        end
        return on, #paths
    end

    function MS:CountRecvStateFor(categoryId, paths)
        local on = 0
        for _, p in ipairs(paths) do
            if MS:GetKeyRecvState(categoryId, p) then on = on + 1 end
        end
        return on, #paths
    end

    -- The category's settings bucketed by field group, in
    -- RC.SETTING_GROUP_ORDER, empty groups skipped:
    --   { { group = "position", label = "Position & Lock", paths = {...} }, ... }
    -- When a category carries SEVERAL table keys that each hold their own
    -- settings ("All Bars" = trinket + weapons + potions bars), the rows
    -- are bucketed per key as well and labelled "Trinket bar: Position &
    -- Lock", so each real feature keeps its own switches. Scalar and
    -- opaque keys of such a category stay in the plain buckets.
    function MS:GetCategoryGroups(categoryId)
        local settings = MS:GetCategorySettings(categoryId)
        local descends, nDesc = {}, 0
        for _, s in ipairs(settings) do
            if s.depth >= 1 and not s.virtual then
                local head = SplitPath(s.path)
                if not descends[head] then descends[head] = true; nDesc = nDesc + 1 end
            end
        end
        local perKey = nDesc >= 2
        local buckets, order = {}, {}
        local function bucket(sub, g)
            local id = (sub or "") .. "|" .. g
            if not buckets[id] then
                local label = RC:GetSettingGroupLabel(g)
                if sub then label = RC:GetSettingLabel(sub) .. ": " .. label end
                buckets[id] = { group = g, key = sub, label = label, paths = {} }
                order[#order + 1] = id
            end
            return buckets[id]
        end
        for _, s in ipairs(settings) do
            local g = RC:GetSettingGroup(s.path)
            local sub = nil
            if perKey then
                local head = SplitPath(s.path)
                if descends[head] and s.path ~= head then sub = head end
            end
            local b = bucket(sub, g)
            b.paths[#b.paths + 1] = s.path
        end
        -- Order: plain buckets first, then per-key buckets in category key
        -- order; within each, RC.SETTING_GROUP_ORDER, unknown groups last
        -- (an override typo still shows its settings; the audit names it).
        local groupRank = {}
        for i, g in ipairs(RC.SETTING_GROUP_ORDER or {}) do groupRank[g] = i end
        local keyRank = {}
        for i, k in ipairs(MS:GetCategoryKeys(categoryId)) do keyRank[k] = i end
        table.sort(order, function(a, b)
            local A, B = buckets[a], buckets[b]
            local ka = A.key and (keyRank[A.key] or 999) or 0
            local kb = B.key and (keyRank[B.key] or 999) or 0
            if ka ~= kb then return ka < kb end
            local ga = groupRank[A.group] or 999
            local gb = groupRank[B.group] or 999
            if ga ~= gb then return ga < gb end
            return A.group < B.group
        end)
        local out = {}
        for _, id in ipairs(order) do out[#out + 1] = buckets[id] end
        return out
    end

    -- Whole-category switches for the header rows: on = flag on with every
    -- row included, off = flag off with the exclusion list cleared.
    function MS:SetCategorySendAll(categoryId, on)
        local cc = _mss.charCfg
        if not cc then return end
        cc.syncCategories = cc.syncCategories or {}
        cc.syncCategories[categoryId] = on and true or false
        MS:SetAllKeysIncluded(categoryId, true)
        if not on then
            -- Aliased flags are per-row options too; "category off" must
            -- read as every row off, and SetAllKeysIncluded(true) just
            -- turned the aliases on.
            for _, s in ipairs(MS:GetCategorySettings(categoryId)) do
                local flag = SEND_FLAG_ALIAS[s.path]
                if flag then cc[flag] = false end
            end
        end
    end

    function MS:SetCategoryRecvAll(categoryId, on)
        local cc = _mss.charCfg
        if not cc then return end
        cc.recvCategories = cc.recvCategories or {}
        cc.recvCategories[categoryId] = on and true or false
        MS:SetAllKeysReceived(categoryId, true)
    end

    -- Send this category, whole, and nothing else.
    function MS:SoloSendCategoryAll(categoryId)
        MS:SoloSendCategory(categoryId)
        MS:SetAllKeysIncluded(categoryId, true)
    end

    -- Effective counts for a category header: rows on / rows total.
    function MS:CountSendState(categoryId)
        local list = MS:GetCategorySettings(categoryId)
        local on = 0
        for _, s in ipairs(list) do
            if MS:GetKeySendState(categoryId, s.path) then on = on + 1 end
        end
        return on, #list
    end

    function MS:CountRecvState(categoryId)
        local list = MS:GetCategorySettings(categoryId)
        local on = 0
        for _, s in ipairs(list) do
            if MS:GetKeyRecvState(categoryId, s.path) then on = on + 1 end
        end
        return on, #list
    end

    -- ---- Enumeration --------------------------------------------------
    -- Every individually selectable setting a category carries, as
    -- { path, depth } rows, ONE LEVEL DEEP by default:
    --   * a db key holding a scalar               -> one row (depth 0)
    --   * a db key holding a table of settings    -> one row per field (1)
    --   * a field that is itself a settings table -> one row per sub-field (2)
    --   * anything RC.SETTING_OPAQUE_PATHS marks as user data (lists, per-
    --     boss config, tracked sets, history) -> ONE row for the container
    -- Field names come from the live db copy AND RC.defaults (and
    -- RC.SETTING_FIELD_SOURCES for sparse tables such as customColors), so a
    -- setting the player has never touched still gets its row. A table key
    -- with no discoverable fields falls back to a single row for the key.
    -- Registry paths in RC.SETTING_UNSYNCED_PATHS are skipped: the payload
    -- builder never ships them. Rows are sorted by label within each key.
    -- Table keys that DO descend get no row of their own: the category
    -- header covers "all of it", and a checkbox on the parent would silently
    -- override every child underneath.
    local MAX_SETTING_ROWS = 200

    local function IsSettingsTable(v)
        if type(v) ~= "table" then return false end
        local anyString = false
        for k in pairs(v) do
            if type(k) == "string" then anyString = true
            else return false end
        end
        return anyString
    end

    local function CollectFieldNames(path, live, dflt)
        local seen, names = {}, {}
        local function add(t)
            if type(t) ~= "table" then return end
            for k in pairs(t) do
                if type(k) == "string" and not seen[k] then
                    seen[k] = true
                    names[#names + 1] = k
                end
            end
        end
        add(live); add(dflt)
        local src = RC.SETTING_FIELD_SOURCES and RC.SETTING_FIELD_SOURCES[path]
        if src then add(src()) end
        return names
    end

    local function SortByLabel(rows)
        table.sort(rows, function(a, b)
            local la = string.lower(RC:GetSettingLabel(a.path))
            local lb = string.lower(RC:GetSettingLabel(b.path))
            if la ~= lb then return la < lb end
            return a.path < b.path
        end)
    end

    local function ValueAt(root, rest)
        local t = root
        for seg in string.gmatch(rest, "[^%.]+") do
            if type(t) ~= "table" then return nil end
            t = t[seg]
        end
        return t
    end

    -- Appends the rows for the table at `path` (depth d) into out.
    -- Returns true when at least one row was added.
    local function AppendChildRows(out, path, depth, live, dflt)
        local unsynced = RC.SETTING_UNSYNCED_PATHS or {}
        local names = CollectFieldNames(path, live, dflt)
        local rows = {}
        for _, name in ipairs(names) do
            local sub = path .. "." .. name
            if not unsynced[sub] then
                local lv = type(live) == "table" and live[name] or nil
                local dv = type(dflt) == "table" and dflt[name] or nil
                local shape = lv
                if shape == nil then shape = dv end
                if depth < 2 and not RC:IsOpaqueSettingPath(sub)
                        and (IsSettingsTable(lv) or IsSettingsTable(dv)) then
                    local kids = {}
                    AppendChildRows(kids, sub, depth + 1, lv, dv)
                    if #kids > 0 then
                        rows[#rows + 1] = { path = sub, depth = depth, header = true, kids = kids }
                    else
                        rows[#rows + 1] = { path = sub, depth = depth }
                    end
                else
                    rows[#rows + 1] = { path = sub, depth = depth }
                end
            end
        end
        SortByLabel(rows)
        for _, r in ipairs(rows) do
            if #out >= MAX_SETTING_ROWS then break end
            if r.kids then
                -- Sub-header (label only) followed by its rows.
                out[#out + 1] = { path = r.path, depth = r.depth, header = true }
                for _, k in ipairs(r.kids) do
                    if #out >= MAX_SETTING_ROWS then break end
                    out[#out + 1] = k
                end
            else
                out[#out + 1] = r
            end
        end
        return #rows > 0
    end

    function MS:GetCategorySettings(categoryId)
        local out = {}
        local unsynced = RC.SETTING_UNSYNCED_PATHS or {}
        local keys = MS:GetCategoryKeys(categoryId)
        local nKeys = 0
        for _, key in ipairs(keys) do
            if not unsynced[key] then nKeys = nKeys + 1 end
        end
        local multiKey = nKeys > 1
        -- Virtual rows sit directly under the key they belong to.
        local virtByKey = nil
        for _, vp in ipairs(MS.VIRTUAL_SETTINGS[categoryId] or {}) do
            local head = SplitPath(vp)
            virtByKey = virtByKey or {}
            virtByKey[head] = virtByKey[head] or {}
            table.insert(virtByKey[head], vp)
        end
        for _, key in ipairs(keys) do
            if not unsynced[key] then
                local live = RC.db and RC.db[key]
                local dflt = RC.defaults and RC.defaults[key]
                local isTbl = type(live) == "table" or type(dflt) == "table"
                    or (RC.SETTING_FIELD_SOURCES and RC.SETTING_FIELD_SOURCES[key] ~= nil)
                if isTbl and not RC:IsOpaqueSettingPath(key) then
                    local kids = {}
                    AppendChildRows(kids, key, 1, live, dflt)
                    if #kids > 0 then
                        if multiKey then
                            out[#out + 1] = { path = key, depth = 0, header = true }
                        end
                        for _, k in ipairs(kids) do
                            if #out >= MAX_SETTING_ROWS then break end
                            out[#out + 1] = k
                        end
                    else
                        out[#out + 1] = { path = key, depth = 0 }
                    end
                else
                    out[#out + 1] = { path = key, depth = 0 }
                end
            end
            if virtByKey and virtByKey[key] then
                for _, vp in ipairs(virtByKey[key]) do
                    out[#out + 1] = { path = vp, depth = 1, virtual = true }
                end
            end
            if #out >= MAX_SETTING_ROWS then break end
        end
        -- Header rows are layout only; strip them from the state list so
        -- counts and bulk edits see selectable rows alone.
        local rows = {}
        for _, r in ipairs(out) do
            if not r.header then rows[#rows + 1] = r end
        end
        rows.layout = out
        return rows
    end

    -- Same list with the sub-header rows kept, for the Sync Rules page.
    function MS:GetCategorySettingsLayout(categoryId)
        return MS:GetCategorySettings(categoryId).layout
    end

    function MS:CountIncludedKeys(categoryId)
        local list = MS:GetCategorySettings(categoryId)
        local on = 0
        for _, s in ipairs(list) do
            if MS:IsKeyIncluded(categoryId, s.path) then on = on + 1 end
        end
        return on, #list
    end

    function MS:CountReceivedKeys(categoryId)
        local list = MS:GetCategorySettings(categoryId)
        local on = 0
        for _, s in ipairs(list) do
            if MS:IsKeyReceived(categoryId, s.path) then on = on + 1 end
        end
        return on, #list
    end

    -- Drop exclusions naming categories or keys that no longer exist, so a
    -- renamed setting cannot keep silently suppressing itself. Both
    -- directions.
    local function PruneOneExclusionTable(cc, field)
        if not cc or type(cc[field]) ~= "table" then return 0 end
        local tbl = cc[field]
        local removed = 0
        for catId, ex in pairs(tbl) do
            local valid = {}
            for _, k in ipairs(MS:GetCategoryKeys(catId)) do valid[k] = true end
            if next(valid) == nil then
                tbl[catId] = nil
                removed = removed + 1
            elseif type(ex) == "table" then
                for k in pairs(ex) do
                    -- Validate the HEAD of the path: "worldBuffs.showTimers"
                    -- is valid whenever "worldBuffs" is a key of the category.
                    local head = SplitPath(k)
                    if not valid[head] then ex[k] = nil; removed = removed + 1 end
                end
                if next(ex) == nil then tbl[catId] = nil end
            end
        end
        return removed
    end
    local function PruneExcludedKeys(cc)
        return PruneOneExclusionTable(cc, "excludedKeys")
             + PruneOneExclusionTable(cc, "recvExcludedKeys")
    end
    MS.PruneExcludedKeys = PruneExcludedKeys

    local function KeyIncluded(catId, key)
        local skip = StripKeySet(catId)
        return not (skip and skip[key])
    end
    _mss.KeyIncluded = KeyIncluded

    local function ApplyPayloadStrips(categoryIdOrSuffix, payload)
        if type(payload) ~= "table" then return payload end
        local catId = string.match(categoryIdOrSuffix or "", "^[^~]+")
            or categoryIdOrSuffix
        local skip = StripKeySet(catId)
        if not skip then return payload end
        for k in pairs(skip) do
            local head, rest = SplitPath(k)
            if not rest then payload[head] = nil end
        end
        if HasNestedSkips(skip) then
            -- Replaces values with stripped copies; assigning to existing keys
            -- during pairs() is safe (no new keys are introduced).
            for key, v in pairs(payload) do
                payload[key] = StripNestedCopy(v, key, skip)
            end
        end
        if next(payload) == nil then return nil end
        return payload
    end
    _mss.ApplyPayloadStrips = ApplyPayloadStrips

    -- One queue per target plus a round-robin cursor, so a 400 chunk
    -- transfer to one peer cannot starve traffic to every other peer.
    local sendQueues  = {}
    local sendOrder   = {}
    local sendRR      = 0
    _mss.sendPending = 0

    local function TargetKey(t) return tostring(t or "ALL") end

    local function SendQueueFor(tk)
        local q = sendQueues[tk]
        if not q then
            q = {}
            sendQueues[tk] = q
            sendOrder[#sendOrder + 1] = tk
        end
        return q
    end

    local function RebuildSendOrder()
        sendOrder = {}
        for tk, q in pairs(sendQueues) do
            if q[1] then sendOrder[#sendOrder + 1] = tk end
        end
        if sendRR > #sendOrder then sendRR = 0 end
    end

    local function SendPush(entry, front)
        local q = SendQueueFor(TargetKey(entry.target))
        if front then table.insert(q, 1, entry) else q[#q + 1] = entry end
        _mss.sendPending = _mss.sendPending + 1
    end

    -- Hard ceiling on queued chunks. A bulk push that would blow past it
    -- is dropped whole (partial chunk sets are useless to the receiver);
    -- single control messages always get through.
    local MAX_SEND_QUEUE = 2000
    local function QueueHasRoom(count)
        if count <= 1 or _mss.sendPending + count <= MAX_SEND_QUEUE then return true end
        RC:DebugPrint("MeshSync: send queue full (" .. _mss.sendPending .. " pending) - dropped "
            .. count .. " chunks", "meshsync")
        return false
    end
    local sendTicker         = nil

    -- ============================================================
    -- BACKPRESSURE
    -- ============================================================
    -- The client's addon-message throttle is an allowance of 10 that
    -- refills at 1 PER SECOND, per prefix. Whispers sent OUTSIDE
    -- instanced content are exempt, which is the only reason a 0.12s
    -- tick (~8.3/sec) ever worked: the bulk path is whisper-only and
    -- most of it happens in the world.
    --
    -- Inside an instance the exemption does not apply - and that is
    -- precisely when a 40-man syncs raid profiles. At 8.3/sec the bucket
    -- empties in about 1.4 seconds and roughly seven of every eight
    -- chunks are refused from then on. So the tick rate is decided per
    -- send, not baked in at load: full speed in the world, refill rate
    -- in an instance.
    --
    -- sendNextAt is the gate. The ticker still fires at the fast rate;
    -- it just does nothing until the clock says the next send is due.
    -- That way an instance transition takes effect immediately without
    -- tearing down and rebuilding the ticker.
    local SEND_INTERVAL_INSTANCE = 1.0
    local THROTTLE_BACKOFF       = { 1.0, 2.0, 4.0 }
    local sendNextAt   = 0
    local sendThrottled = 0        -- consecutive throttle refusals

    local function CurrentSendInterval()
        if IsInInstance and IsInInstance() then return SEND_INTERVAL_INSTANCE end
        return SEND_INTERVAL
    end
    _mss.CurrentSendInterval = CurrentSendInterval

    local msgIdCounter       = math.random(0, 65535)
    local inboundBuffers     = {}
    local knownAccounts      = {}
    local knownChars         = {}
    local lastHelloResponseTo = {}
    local _badTokenWarnedAt  = {}
    _mss.isEnabled = false
    _mss.isChannelJoined = false
    _mss.lastHelloTime = 0
    _mss.cfg = nil
    _mss.charCfg = nil
    local _lastBroadcastHash = {}
    _mss.pollTicker = nil
    _mss._enabledAt = 0
    local _refreshDebounce   = nil
    local _receivedRaidConfirmPrinted = {}
    _mss._addMemberSaveTimer = nil
    _mss._pollBroadcast = false
    _mss.raidCfgPushDebounce = nil

    MS.activityLog = {}

    -- The token is the only authentication on the wire. A peer whose
    -- password hashes differently is rejected in OnChatMessage, and
    -- "00000000" (no password set) is dropped there as well.
    local function HashPassword(pw)
        if not pw or pw == "" then return "00000000" end
        local hash = 5381
        for i = 1, string_len(pw) do
            hash = ((hash * 33) + string_byte(pw, i)) % 4294967296
        end
        return string_format("%08x", hash)
    end

    local function GetToken()
        return _mss.cfg and HashPassword(_mss.cfg.meshPassword) or "00000000"
    end

    -- Character key for every per-character table. Built from the
    -- NORMALIZED realm - the exact same expression NormalizeName uses -
    -- because the two used to disagree on realms with spaces ("Bob-Wild
    -- Growth" vs "Bob-WildGrowth"). That mismatch broke the self-echo drop,
    -- made same-account gear deletes and trinket pushes never land (written
    -- under normalized keys, read under raw ones), and left the gear cache
    -- written under a key nothing ever read. InitConfig migrates old keys.
    local function GetToonKey()
        local name  = UnitName("player") or "Unknown"
        -- Fallback strips the same set Blizzard normalization does
        -- (spaces, apostrophes, hyphens), matching normKey in InitConfig.
        local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
            or (GetRealmName() or "Unknown"):gsub("[%s'%-]", "")
        return name .. "-" .. realm
    end

    local function GetCharEnabled()
        local t = ReadycheckDB and ReadycheckDB.meshSyncEnabledPerChar
        if not t then return false end
        local key = GetToonKey()
        return t[key] == true
    end

    local function SetCharEnabled(val)
        if not ReadycheckDB then return end
        if not ReadycheckDB.meshSyncEnabledPerChar then
            ReadycheckDB.meshSyncEnabledPerChar = {}
        end
        ReadycheckDB.meshSyncEnabledPerChar[GetToonKey()] = val == true or nil
    end

    function MS:InitConfig()
        if not ReadycheckDB then return end

        -- One-time key migration. Per-character tables used to be keyed by
        -- the RAW realm name while everything from the wire used the
        -- normalized form; on realms with spaces (or hyphens/apostrophes)
        -- the two never matched - sync rules looked reset, same-account
        -- queues never drained, the gear cache was write-only. Old keys are
        -- rewritten to the normalized form GetToonKey now produces.
        if not ReadycheckDB.meshToonKeysNormalized then
            ReadycheckDB.meshToonKeysNormalized = true
            local rawKey = (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "Unknown")
            local newKey = GetToonKey()
            local function normKey(k)
                if type(k) ~= "string" then return k end
                if k == rawKey then return newKey end
                local n, r = k:match("^([^%-]+)%-(.+)$")
                if n and r then
                    -- Mirrors Blizzard's realm normalization: spaces,
                    -- hyphens and apostrophes dropped.
                    return n .. "-" .. r:gsub("[%s'%-]", "")
                end
                return k
            end
            local function migrateKeys(t)
                if type(t) ~= "table" then return end
                local moves = nil
                for k in pairs(t) do
                    local nk = normKey(k)
                    if nk ~= k then moves = moves or {}; moves[k] = nk end
                end
                if moves then
                    for k, nk in pairs(moves) do
                        if t[nk] == nil then t[nk] = t[k] end
                        t[k] = nil
                    end
                end
            end
            migrateKeys(ReadycheckDB.meshSyncPerChar)
            migrateKeys(ReadycheckDB.meshSyncEnabledPerChar)
            migrateKeys(ReadycheckDB.meshSyncGearCache)
            migrateKeys(ReadycheckDB.remoteGearDeletes)
            migrateKeys(ReadycheckDB.remoteTrinketPush)
            migrateKeys(ReadycheckDB.remoteReminderPush)
            local st = ReadycheckDB.meshSameAccountState
            if type(st) == "table" then
                migrateKeys(st)
                for _, v in pairs(st) do
                    if type(v) == "table" then
                        if v.fromChar then
                            v.fromChar = normKey(v.fromChar)
                        else
                            for _, e in pairs(v) do
                                if type(e) == "table" and e.fromChar then
                                    e.fromChar = normKey(e.fromChar)
                                end
                            end
                        end
                    end
                end
            end
            local lg = ReadycheckDB.meshSameAccountLastApplied
            if type(lg) == "table" then
                local moves = nil
                for k in pairs(lg) do
                    if type(k) == "string" then
                        local src, cat = k:match("^(.*):([^:]+)$")
                        if src then
                            local ns = normKey(src)
                            if ns ~= src then
                                moves = moves or {}
                                moves[k] = ns .. ":" .. cat
                            end
                        end
                    end
                end
                if moves then
                    for k, nk in pairs(moves) do
                        if lg[nk] == nil then lg[nk] = lg[k] end
                        lg[k] = nil
                    end
                end
            end
        end

        if not ReadycheckDB.meshSync then
            ReadycheckDB.meshSync = {
                accountLabel    = "",
                meshPassword    = "",
                autoBroadcast   = false,
                priorityAccount = "",
                members         = {},
                syncCategories  = {},
            }
        end
        local mc = ReadycheckDB.meshSync
        if mc.autoBroadcast    == nil then mc.autoBroadcast    = false end
        if mc.priorityAccount  == nil then mc.priorityAccount  = ""   end
        if mc.discoveryChannel == nil then mc.discoveryChannel = ""   end
        if mc.syncRaidGear        == nil then mc.syncRaidGear        = false end
        if mc.syncFightHistory    == nil then mc.syncFightHistory    = false end
        -- Account-level copy of a retired bundle flag; nothing reads it.
        mc.syncGeneralPosition = nil
        if mc.crossFaction       == nil then mc.crossFaction       = true end
        if mc.crossFactionPeers  == nil then mc.crossFactionPeers  = {} end
        if not mc.members        then mc.members        = {} end
        -- Send decisions read _mss.charCfg.syncCategories exclusively. An
        -- account-level syncCategories copy used to be initialised and
        -- pruned here every login while nothing anywhere read it - dead
        -- config with live maintenance code. Dropped for good.
        mc.syncCategories  = nil
        mc._syncCatCleaned = nil
        mc.enabled = nil
        _mss.cfg = mc

        ReadycheckDB.meshSyncPerChar = ReadycheckDB.meshSyncPerChar or {}
        local toonK = GetToonKey()
        if not ReadycheckDB.meshSyncPerChar[toonK] then
            ReadycheckDB.meshSyncPerChar[toonK] = {
                autoBroadcast       = false,
                priorityAccount     = "",
                syncRaidGear        = false,
                syncFightHistory    = false,
                syncCategories      = {},
            }
        end
        _mss.charCfg = ReadycheckDB.meshSyncPerChar[toonK]
        if _mss.charCfg.autoBroadcast       == nil then _mss.charCfg.autoBroadcast       = false end
        if _mss.charCfg.priorityAccount     == nil then _mss.charCfg.priorityAccount     = ""    end
        if _mss.charCfg.syncRaidGear        == nil then _mss.charCfg.syncRaidGear        = false end
        if _mss.charCfg.syncFightHistory    == nil then _mss.charCfg.syncFightHistory    = false end
        _mss.charCfg.syncPolarityMode = nil
        _mss.charCfg.syncFrostBlast   = nil
        if type(_mss.charCfg.excludedKeys)     ~= "table" then _mss.charCfg.excludedKeys     = {} end
        if type(_mss.charCfg.recvExcludedKeys) ~= "table" then _mss.charCfg.recvExcludedKeys = {} end

        -- One-time move from bundle flags to per-setting, per-direction
        -- state. Runs once per character (perKeyRulesV2), on fresh
        -- characters too, so the old defaults keep holding: anchor position
        -- stayed home by default (syncGeneralPosition=false) and boss-config
        -- gear was never accepted (syncRaidGear=false).
        --   * every bundle flag at false (or defaulting to false) -> its
        --     keys excluded on BOTH sides; the flag is then cleared
        --   * the old single exclusion list applied both ways -> copied
        --     into the receive list so nothing starts arriving unasked
        --   * receive side of boss-config gear seeded from syncRaidGear
        if not _mss.charCfg.perKeyRulesV2 then
            local cc = _mss.charCfg
            local function exclude(field, cat, path)
                cc[field][cat] = cc[field][cat] or {}
                cc[field][cat][path] = true
            end
            for cat, ex in pairs(cc.excludedKeys) do
                if type(ex) == "table" then
                    for path, v in pairs(ex) do
                        if v then exclude("recvExcludedKeys", cat, path) end
                    end
                end
            end
            for _, rule in ipairs(LEGACY_BUNDLE_RULES) do
                local eff = cc[rule.flag]
                if eff == nil then eff = rule.dflt end
                if eff == false then
                    for _, k in ipairs(rule.keys) do
                        exclude("excludedKeys", rule.cat, k)
                        exclude("recvExcludedKeys", rule.cat, k)
                    end
                end
                cc[rule.flag] = nil
            end
            if not cc.syncRaidGear then
                exclude("recvExcludedKeys", "raidProfiles", "raidProfiles.gear")
            end
            cc.perKeyRulesV2 = true
            RC:DebugPrint("MeshSync: migrated sync rules to per-setting send/receive state", "meshsync")
        end
        if not _mss.charCfg.syncCategories then _mss.charCfg.syncCategories = {} end
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            if _mss.charCfg.syncCategories[cat.id] == nil then
                _mss.charCfg.syncCategories[cat.id] = false
            end
        end
        -- Receive defaults ON, Send defaults OFF: a fresh character accepts
        -- what the mesh offers but never broadcasts until the user opts in.
        if not _mss.charCfg.recvCategories then _mss.charCfg.recvCategories = {} end
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            if _mss.charCfg.recvCategories[cat.id] == nil then
                _mss.charCfg.recvCategories[cat.id] = true
            end
        end

        local stale = PruneUnknownCategoryFlags(_mss.charCfg.syncCategories)
                    + PruneUnknownCategoryFlags(_mss.charCfg.recvCategories)
                    + PruneExcludedKeys(_mss.charCfg)
        if stale > 0 then
            RC:DebugPrint("MeshSync: pruned " .. stale
                .. " sync rule(s) for categories that no longer exist", "meshsync")
        end
        if _mss.charCfg.recvFromMode == nil then _mss.charCfg.recvFromMode = "all" end
        if type(_mss.charCfg.recvFromAccounts) ~= "table" then _mss.charCfg.recvFromAccounts = {} end
    end

    local function LogActivity(msg)
        local ts = string_format("[%s] ", date("%H:%M"))
        table_insert(MS.activityLog, 1, ts .. msg)
        if #MS.activityLog > 20 then table_remove(MS.activityLog) end
        MS:RefreshMeshUI()
    end

    -- Random start, wraps at 65536. The receiver keys its chunk buffers on
    -- sender + msgId, so a wrap that lands on a still-open transfer is
    -- detected there by the total-count mismatch and restarts the buffer.
    local function NextMsgId()
        msgIdCounter = (msgIdCounter + 1) % 65536
        return string_format("%04X", msgIdCounter)
    end

    local function GetMyLabel()
        return ((_mss.cfg and _mss.cfg.accountLabel) or "?"):sub(1, MAX_LABEL_LEN):gsub("#", "")
    end

    -- Peer identity is always "Name-Realm". Every roster lookup, queue key
    -- and dedupe table compares normalised names, so anything arriving from
    -- an event or the wire has to pass through here first.
    local function NormalizeName(name)
        if not name or name == "" then return nil end
        name = name:match("^%s*(.-)%s*$") or name
        if not name:find("-", 1, true) then
            -- Fallback matches GetToonKey exactly - the two producing
            -- different keys for the same character is the bug class that
            -- broke self-echo drops and same-account queues.
            local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
                or (GetRealmName() or ""):gsub("[%s'%-]", "")
            if realm and realm ~= "" then
                name = name .. "-" .. realm
            end
        end
        return name
    end

    local function HideChannelFromChat(channelName)
        if not channelName or channelName == "" then return end
        for i = 1, NUM_CHAT_WINDOWS or 10 do
            local chatFrame = _G["ChatFrame" .. i]
            if chatFrame and ChatFrame_RemoveChannel then
                ChatFrame_RemoveChannel(chatFrame, channelName)
            end
        end
    end

    local function MeshChatFilter(_, _, msg, sender, _, channelString)
        if not _mss.cfg or _mss.cfg.discoveryChannel == "" then return false end
        if channelString and type(channelString) == "string" then
            local chName = channelString:match("^%d+%.%s*(.+)$")
            if chName and chName:lower() == _mss.cfg.discoveryChannel:lower() then
                return true
            end
        end
        if msg and type(msg) == "string"
                and _mss.cfg.discoveryChannel ~= ""
                and msg:find(_mss.cfg.discoveryChannel, 1, true) then
            return true
        end
        return false
    end
    if ChatFrame_AddMessageEventFilter then
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_JOIN",         MeshChatFilter)
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_LEAVE",        MeshChatFilter)
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE",       MeshChatFilter)
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_NOTICE_USER",  MeshChatFilter)
        ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL_LIST",         MeshChatFilter)
    end

    local function GetJoinedChannelCount()
        local count = 0
        for i = 1, 10 do
            local _, n = GetChannelName(i)
            if n and n ~= "" then count = count + 1 end
        end
        return count
    end

    local function JoinDiscoveryChannel()
        if not _mss.cfg or _mss.cfg.discoveryChannel == "" then return end
        local chanName = _mss.cfg.discoveryChannel
        local existingId = GetChannelName(chanName)
        if existingId and existingId > 0 then
            HideChannelFromChat(chanName)
            _mss.isChannelJoined = true
            return
        end
        if GetJoinedChannelCount() >= 10 then
            RC:Print(RCL["Mesh: No channel slots free (10/10 used). Discovery channel not joined."])
            return
        end
        JoinChannelByName(chanName, _mss.cfg.meshPassword or "")
        C_Timer.After(0.5, function()
            HideChannelFromChat(chanName)
            _mss.isChannelJoined = true
            RC:DebugPrint("MeshSync: joined discovery channel " .. chanName, "meshsync")
            LogActivity("Joined discovery channel " .. chanName)
        end)
    end

    local function LeaveDiscoveryChannel()
        if not _mss.cfg or _mss.cfg.discoveryChannel == "" then return end
        if LeaveChannelByName then LeaveChannelByName(_mss.cfg.discoveryChannel) end
        _mss.isChannelJoined = false
        RC:DebugPrint("MeshSync: left discovery channel", "meshsync")
    end

    -- Reserved words cannot be emitted as bare table keys; they must take
    -- the ["..."] form or the receiver's loadstring rejects the payload.
    local LUA_KEYWORDS = {
        ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true,
        ["elseif"] = true, ["end"] = true, ["false"] = true, ["for"] = true,
        ["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true,
        ["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true,
        ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
        ["while"] = true,
    }

    local function Serialize(val)
        local buf = {}
        local function ser(v, depth)
            if depth > 30 then buf[#buf+1] = "nil"; return end
            local t = type(v)
            if t == "nil" then
                buf[#buf+1] = "nil"
            elseif t == "boolean" then
                buf[#buf+1] = v and "true" or "false"
            elseif t == "number" then
                buf[#buf+1] = tostring(v)
            elseif t == "string" then
                -- "#" is the header separator and "|" opens a chat escape
                -- sequence; both are escaped numerically so payload text can
                -- never split a header or be eaten by the chat system.
                local s = string_gsub(v,   "\\",   "\\\\")
                s        = string_gsub(s,   '"',    '\\"')
                s        = string_gsub(s,   "\n",   "\\n")
                s        = string_gsub(s,   "\r",   "\\r")
                s        = string_gsub(s,   "|",    "\\124")
                s        = string_gsub(s,   "#",    "\\035")
                buf[#buf+1] = '"'; buf[#buf+1] = s; buf[#buf+1] = '"'
            elseif t == "table" then
                local n = 0
                for i = 1, 1e9 do if v[i] == nil then break end; n = i end
                buf[#buf+1] = "{"
                local first = true
                for i = 1, n do
                    if not first then buf[#buf+1] = "," end; first = false
                    ser(v[i], depth+1)
                end
                for k, v2 in pairs(v) do
                    local isArr = type(k) == "number" and k == math_floor(k) and k >= 1 and k <= n
                    if not isArr then
                        if not first then buf[#buf+1] = "," end; first = false
                        if type(k) == "string" and not LUA_KEYWORDS[k]
                                and string_match(k, "^[%a_][%w_]*$") then
                            buf[#buf+1] = k
                        elseif type(k) == "string" then
                            local ks = string_gsub(k,  "\\",  "\\\\")
                            ks       = string_gsub(ks, '"',   '\\"')
                            ks       = string_gsub(ks, "\n",  "\\n")
                            ks       = string_gsub(ks, "\r",  "\\r")
                            ks       = string_gsub(ks, "|",   "\\124")
                            ks       = string_gsub(ks, "#",   "\\035")
                            buf[#buf+1] = '["'; buf[#buf+1] = ks; buf[#buf+1] = '"]'
                        else
                            buf[#buf+1] = "["; buf[#buf+1] = tostring(k); buf[#buf+1] = "]"
                        end
                        buf[#buf+1] = "="
                        ser(v2, depth+1)
                    end
                end
                buf[#buf+1] = "}"
            else
                buf[#buf+1] = "nil"
            end
        end
        ser(val, 0)
        return table_concat(buf)
    end

    -- Untrusted input from the wire. Three guards, none optional: a size
    -- cap, loadstring run in an EMPTY environment via setfenv, and a
    -- rejection of function results.
    local function Deserialize(str)
        if not str or str == "" then return nil, "empty" end
        if string_len(str) > 2000000 then return nil, "too large" end
        local f, err = loadstring("return " .. str)
        if not f then return nil, err end
        setfenv(f, {})
        local ok, result = pcall(f)
        if not ok then return nil, tostring(result) end
        if type(result) == "function" then return nil, "function payload rejected" end
        return result
    end

    -- ====================================================================
    -- ====================================================================
    local _LibSerialize, _LibDeflate, _codecResolved
    local function GetCodecLibs()
        if not _codecResolved then
            _codecResolved = true
            _LibSerialize = (LibStub and LibStub("LibSerialize", true)) or nil
            _LibDeflate   = (LibStub and LibStub("LibDeflate", true)) or nil
            if not (_LibSerialize and _LibDeflate) then
                RC:DebugPrint("MeshSync: LibSerialize/LibDeflate not found - "
                    .. "compressed sync (rc2) disabled, using rc1 literal codec", "meshsync")
            end
        end
        return _LibSerialize, _LibDeflate
    end

    -- Returns the encoded body and the marker to stamp in the header. Every
    -- failure path falls back to RC1, so a missing library or a codec error
    -- degrades to the literal format instead of dropping the payload.
    local function EncodeWire(payload, useCompress)
        if useCompress then
            local LS, LD = GetCodecLibs()
            if LS and LD then
                local ok, ser = pcall(LS.Serialize, LS, payload)
                if ok and ser then
                    local comp = LD:CompressDeflate(ser)
                    if comp then
                        local enc = LD:EncodeForWoWAddonChannel(comp)
                        if enc and enc ~= "" then return enc, "RC2" end
                    end
                end
            end
        end
        return Serialize(payload), "RC1"
    end

    local function DecodeWire(str, marker)
        if marker == "RC2" then
            local LS, LD = GetCodecLibs()
            if not (LS and LD) then return nil, "rc2 payload but codec libs missing" end
            local dec = LD:DecodeForWoWAddonChannel(str)
            if not dec then return nil, "rc2 channel-decode failed" end
            local ok, comp = pcall(LD.DecompressDeflate, LD, dec)
            if not ok or not comp then return nil, "rc2 inflate failed" end
            local dok, result = LS:Deserialize(comp)
            if not dok then return nil, tostring(result) end
            return result
        end
        return Deserialize(str)
    end

    local function PeerSupportsRC2(charName)
        if PROTO_VERSION < 2 then return false end
        local pp = _mss.peerProto
        if not pp or not charName then return false end
        local ns = NormalizeName(charName)
        return (ns and (pp[ns] or 0) >= 2) or false
    end

    local function BuildHeader(from, msgId, seq, tot, token, cmd, marker)
        return (marker or PROTO_MARKER) .. PROTO_SEP
            .. from  .. PROTO_SEP
            .. msgId .. PROTO_SEP
            .. string_format("%03d", seq) .. PROTO_SEP
            .. string_format("%03d", tot) .. PROTO_SEP
            .. token .. PROTO_SEP
            .. cmd   .. PROTO_SEP
    end

    local function ChunkData(serialized, from, msgId, token, cmd, marker)
        local msgs  = {}
        -- seq and tot are zero padded to 3, so the header measured for 1/1
        -- is the exact length of every header in the message.
        local headerLen = string_len(BuildHeader(from, msgId, 1, 1, token, cmd, marker))
        local chunkMax  = 255 - headerLen
        if chunkMax < 32 then chunkMax = 32 end
        local total = math_floor((string_len(serialized) + chunkMax - 1) / chunkMax)
        if total == 0 then total = 1 end
        if total > 999 then
            RC:DebugPrint("MeshSync: payload too large (" .. total .. " chunks)", "meshsync")
            return nil
        end
        local pos = 1
        for seq = 1, total do
            msgs[seq] = BuildHeader(from, msgId, seq, total, token, cmd, marker)
                .. string_sub(serialized, pos, pos + chunkMax - 1)
            pos = pos + chunkMax
        end
        return msgs
    end

    local function ChunkForTarget(payload, from, msgId, token, cmd, targetCharName)
        local ser, marker = EncodeWire(payload, targetCharName ~= nil and PeerSupportsRC2(targetCharName))
        return ChunkData(ser, from, msgId, token, cmd, marker)
    end

    local MAX_SEND_RETRIES = 3

    -- THIS CHECK WAS DEAD FOR ITS ENTIRE LIFE, and it is why bulk sync
    -- failed in raid while working fine in the world.
    --
    -- The old test was `if ok == false`. Patch 4.4.0 changed
    -- SendAddonMessage to return Enum.SendAddonMessageResult - a NUMBER,
    -- 0 for Success and 3 for AddonMessageThrottle - and that change
    -- reached Classic Era too. In Lua `0 == false` is false and
    -- `3 == false` is false, so the branch could never be entered under
    -- any condition. MAX_SEND_RETRIES, the front-requeue and the
    -- "dropped chunk" warning were all unreachable.
    --
    -- The visible symptom: inside an instance the throttle refused most
    -- chunks, nothing retried, nothing backed off, sendPending
    -- decremented as though every one had gone out, and the progress bar
    -- reported 100% sent. The receiver sat on a partial buffer for the
    -- full 300s BUFFER_TIMEOUT and then reported a failed transfer.
    --
    -- Read with select(-1, ...): the compatibility shim Blizzard shipped
    -- in 10.2.7 moved the code to the second return slot and 11.0.0
    -- removed the shim again, so the last return value is the only
    -- position that is correct on every build.
    local THROTTLED = (Enum and Enum.SendAddonMessageResult
        and Enum.SendAddonMessageResult.AddonMessageThrottle) or 3
    local ERR_OFFLINE = (Enum and Enum.SendAddonMessageResult
        and Enum.SendAddonMessageResult.NotInGroup) or nil

    -- OFFLINE DETECTION. SendAddonMessage's return value never reports an
    -- offline whisper target - the server answers asynchronously with the
    -- system message ERR_CHAT_PLAYER_NOT_FOUND_S ("No player named 'X' is
    -- currently playing."). Before this, every member in cfg.members was
    -- whispered on every HELLO heartbeat, CAP, and poll broadcast whether
    -- they were online or not, so a roster of logged-off alts produced a
    -- never-ending stream of that error in chat.
    --
    -- Every outgoing whisper is stamped in recentWhisperAt. When the
    -- not-found reply for one of those names arrives, the character is
    -- put in offlineUntil for OFFLINE_BACKOFF seconds: BroadcastToAllMembers
    -- skips them, their queue is dropped, and the chat line is hidden. One
    -- probe per backoff window still goes out so they are rediscovered when
    -- they log back in (their own login HELLO also clears the backoff).
    local OFFLINE_BACKOFF   = 300
    local WHISPER_ERR_GRACE = 15
    local recentWhisperAt   = {}   -- base name (lower) -> GetTime() of last whisper
    local baseToTarget      = {}   -- base name (lower) -> normalized "Name-Realm"
    local offlineUntil      = {}   -- normalized target -> GetTime() until which it is skipped
    _mss.offlineUntil = offlineUntil

    local function BaseLower(name)
        return ((tostring(name or "")):match("^([^%-]+)") or tostring(name or "")):lower()
    end

    local function NoteWhisper(targetCharName)
        local b = BaseLower(targetCharName)
        recentWhisperAt[b] = GetTime()
        baseToTarget[b]    = targetCharName
    end

    -- A peer that talks to us is online: clear any backoff. Called from the
    -- inbound path via _mss.MarkTargetOnline.
    _mss.MarkTargetOnline = function(charName)
        if not charName then return end
        offlineUntil[charName] = nil
        local b = BaseLower(charName)
        if baseToTarget[b] then offlineUntil[baseToTarget[b]] = nil end
    end

    _mss.IsTargetBackedOff = function(target, now)
        local t = target and offlineUntil[target]
        return t and t > (now or GetTime()) or false
    end

    do
        local pat = ERR_CHAT_PLAYER_NOT_FOUND_S or "No player named '%s' is currently playing."
        pat = pat:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
        pat = "^" .. pat:gsub("%%s", "(.-)") .. "$"

        local function OnNotFound(name)
            local b = BaseLower(name)
            local at = recentWhisperAt[b]
            if not at or (GetTime() - at) > WHISPER_ERR_GRACE then return false end
            local target = baseToTarget[b]
            if target then
                offlineUntil[target] = GetTime() + OFFLINE_BACKOFF
                if _mss.AbortQueuedFor then pcall(_mss.AbortQueuedFor, target, nil, true) end
            end
            -- Not cleared here: the filter runs once per chat frame, and the
            -- grace window already bounds how long the stamp is honored.
            return true
        end

        if ChatFrame_AddMessageEventFilter then
            ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, msg)
                local name = msg and msg:match(pat)
                if not name then return false end
                return OnNotFound(name)
            end)
        else
            local f = CreateFrame("Frame")
            f:RegisterEvent("CHAT_MSG_SYSTEM")
            f:SetScript("OnEvent", function(_, _, msg)
                local name = msg and msg:match(pat)
                if name then OnNotFound(name) end
            end)
        end
    end

    -- Returns true if the chunk went out, false if the caller should
    -- stop pumping for a moment.
    local function SendOne(msg, targetCharName, retries)
        retries = retries or 0
        if type(targetCharName) ~= "string" or targetCharName == "" then
            RC:DebugPrint("MeshSync: dropped chunk with bad target " .. tostring(targetCharName), "meshsync")
            return true
        end
        -- Forever does not deliver addon messages inside an instance: the
        -- chunk keeps its place and the pump waits until you leave
        -- (Core_Flavor)
        if RC:AddonMessagesBlocked() then
            SendPush({ msg = msg, target = targetCharName, retries = retries }, true)
            return false
        end
        NoteWhisper(targetCharName)
        local result = select(-1, C_ChatInfo.SendAddonMessage(
            ADDON_PREFIX, msg, "WHISPER", targetCharName))

        if result == THROTTLED then
            if retries < MAX_SEND_RETRIES then
                -- Front of the queue so the chunk keeps its place in the
                -- stream; the PUMP decides when to try again. Retrying on
                -- the next 0.12s tick - which is what the original code
                -- would have done had it ever run - burns all three
                -- retries in 0.36s against a bucket that refills once a
                -- second, so every retry throttles too and the chunk is
                -- discarded anyway. The backoff has to be the pump's.
                SendPush({ msg = msg, target = targetCharName,
                           retries = retries + 1 }, true)
            else
                RC:DebugPrint("MeshSync: dropped chunk to " .. tostring(targetCharName)
                    .. " after " .. MAX_SEND_RETRIES .. " retries", "meshsync")
            end
            return false
        end

        if ERR_OFFLINE and result == ERR_OFFLINE then
            -- No point draining hundreds of chunks at someone who is not
            -- there. Their queue is reaped rather than retried.
            if _mss.AbortQueuedFor then pcall(_mss.AbortQueuedFor, targetCharName, nil, true) end
            return true
        end
        return true
    end

    local progressBar
    local recvSessions = {}

    local function SessionTotal(s)
        return math.max(s.declared or 0, s.discovered or 0)
    end

    local function BarColor(group, key, fr, fg, fb, fa)
        local c = RC:GetColor(group, key)
        if c then return c.r, c.g, c.b, c.a or 1 end
        return fr, fg, fb, fa or 1
    end

    local function EnsureProgressBar()
        if progressBar then return progressBar end
        -- Flat window chrome: WHITE8X8 fill, 1px black ring and a gold
        -- hairline along the top edge. The rows below stay StatusBars.
        local f = CreateFrame("Frame", "WRMeshProgressBar", UIParent)
        f:SetSize(240, 44)
        f:SetFrameStrata("MEDIUM")
        local fill = f:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints()
        fill:SetTexture("Interface\\Buttons\\WHITE8X8")
        fill:SetVertexColor(BarColor("ui", "windowBackground", 0.08, 0.08, 0.08, 0.95))
        f.bg = fill
        if RC.UI and RC.UI.CreateSimpleBorder then
            f.border = RC.UI:CreateSimpleBorder(f)
        end
        local rule = f:CreateTexture(nil, "ARTWORK")
        rule:SetTexture("Interface\\Buttons\\WHITE8X8")
        rule:SetHeight(1)
        rule:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
        local gr, gg, gb = BarColor("ui", "accentGold", 0.85, 0.65, 0.25, 0.6)
        rule:SetVertexColor(gr, gg, gb, 0.6)

        local function MakeRow()
            local bar = CreateFrame("StatusBar", nil, f)
            bar:SetSize(228, 15)
            -- the bar texture picked on the Appearance page, like every other bar
            bar:SetStatusBarTexture((RC.GetTexturePath and RC:GetTexturePath()) or "Interface\\Buttons\\WHITE8x8")
            bar:SetStatusBarColor(BarColor("ui", "accentGreen", 0.35, 0.6, 0.35, 1))
            local bg = bar:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetTexture("Interface\\Buttons\\WHITE8x8")
            bg:SetVertexColor(BarColor("ui", "cardBackground", 0.08, 0.08, 0.08, 1))
            local label = bar:CreateFontString(nil, "OVERLAY")
            RC:ApplyCustomFont(label, 9)
            label:SetPoint("LEFT", bar, "LEFT", 4, 0)
            label:SetPoint("RIGHT", bar, "RIGHT", -52, 0)
            label:SetJustifyH("LEFT")
            label:SetWordWrap(false)
            label:SetTextColor(BarColor("ui", "headerText", 1, 0.82, 0, 1))
            local value = bar:CreateFontString(nil, "OVERLAY")
            RC:ApplyCustomFont(value, 9)
            value:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
            value:SetJustifyH("RIGHT")
            value:SetTextColor(BarColor("ui", "headerText", 1, 0.82, 0, 1))
            bar.label, bar.value = label, value
            bar:Hide()
            return bar
        end
        f.sendRow = MakeRow()
        f.recvRow = MakeRow()

        -- Position lives in the character profile (RC.db.meshProgressBar)
        -- so it exports and mesh-syncs like any other setting. The old
        -- mesh-config slot is read as a fallback and cleared on next save.
        RC.Position.Bind(f, function()
            if not RC.db then return nil end
            if not RC.db.meshProgressBar then
                local old = _mss.cfg and _mss.cfg.progressBarPos
                RC.db.meshProgressBar = { x = old and old.x, y = old and old.y }
                if _mss.cfg then _mss.cfg.progressBarPos = nil end
            end
            return RC.db.meshProgressBar
        end, { point = "CENTER", xKey = "x", yKey = "y", default = { x = 0, y = 220 } })
        RC.Position.RestoreFrame(f)
        f.ApplySavedPos = function(self) RC.Position.RestoreFrame(self) end
        if RC.UIMover and RC.UIMover.RegisterFrame then
            RC.UIMover:RegisterFrame("meshProgress", f, "Mesh Transfer Progress",
                { point = "CENTER", relPoint = "CENTER", x = 0, y = 220 })
        end
        f:Hide()
        progressBar = f
        return f
    end
    RC.EnsureMeshProgressBar = EnsureProgressBar

    local function BarRelayout()
        if not progressBar then return end
        local f = progressBar
        local rows = {}
        if f.sendRow:IsShown() then rows[#rows + 1] = f.sendRow end
        if f.recvRow:IsShown() then rows[#rows + 1] = f.recvRow end
        if #rows == 0 then f:Hide() return end
        for i, row in ipairs(rows) do
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -6 - (i - 1) * 19)
        end
        f:SetHeight(12 + #rows * 19 - 4)
        -- Re-read the saved position each time the bar appears, so a
        -- position that arrived via sync or import applies without a
        -- reload. Never while shown - that would fight the mover.
        if not f:IsShown() and f.ApplySavedPos then f:ApplySavedPos() end
        f:Show()
    end

    local function HideRowSoon(row)
        local gen = (row._gen or 0) + 1
        row._gen = gen
        C_Timer.After(1.2, function()
            if row._gen == gen then
                row:Hide()
                BarRelayout()
            end
        end)
    end

    local function UpdateSendRow(remaining, high)
        local f = EnsureProgressBar()
        local row = f.sendRow
        row._gen = (row._gen or 0) + 1
        row:SetMinMaxValues(0, high)
        row:SetValue(high - remaining)
        row.label:SetText(RCL["Sending sync data"])
        row.value:SetText((high - remaining) .. "/" .. high)
        if not row:IsShown() then row:Show() end
        BarRelayout()
        if remaining == 0 then HideRowSoon(row) end
    end

    local function UpdateRecvRow()
        local f = EnsureProgressBar()
        local row = f.recvRow
        local shown, extra, latest = nil, 0, 0
        for _, s in pairs(recvSessions) do
            extra = extra + 1
            if (s.lastAt or 0) >= latest then latest = s.lastAt or 0; shown = s end
        end
        if not shown then
            if row:IsShown() then
                row:SetValue(select(2, row:GetMinMaxValues()))
                HideRowSoon(row)
            end
            return
        end
        row._gen = (row._gen or 0) + 1
        local total = SessionTotal(shown)
        row:SetMinMaxValues(0, math.max(total, 1))
        row:SetValue(shown.received)
        local name = "Sync data"
        if extra > 1 then name = name .. " +" .. (extra - 1) end
        row.label:SetText(name .. " < " .. tostring(shown.label))
        row.value:SetText(shown.received .. "/" .. total)
        if not row:IsShown() then row:Show() end
        BarRelayout()
    end

    local function CheckRecvSessionDone(ns)
        local s = recvSessions[ns]
        if not s or s.received < SessionTotal(s) then return end
        local doneAt = GetTime()
        s.doneAt = doneAt
        C_Timer.After(6, function()
            local cur = recvSessions[ns]
            if cur and cur.doneAt == doneAt and cur.received >= SessionTotal(cur) then
                RC:Print(RCL["Mesh: finished receiving from "] .. tostring(cur.label)
                    .. " (" .. SessionTotal(cur) .. RCL[" parts)."])
                recvSessions[ns] = nil
                UpdateRecvRow()
            end
        end)
    end

    -- Against the LIVE interval, not the constant. With the instance rate
    -- at 1.0s an ETA computed from 0.12 would under-report by 8x, which
    -- is how a twelve-minute transfer announces itself as ninety seconds.
    local function FmtEta(parts)
        local s = math.ceil(parts * CurrentSendInterval())
        if s >= 60 then return math.floor(s / 60) .. "m " .. (s % 60) .. "s" end
        return s .. "s"
    end

    -- ONE holder so MS:OnChatMessage stays under Lua 5.1's hard 60-upvalue
    -- cap - one capture for the whole receive-progress API, not seven.
    local RP = {
        sessions = recvSessions,
        Total    = SessionTotal,
        Done     = CheckRecvSessionDone,
        Row      = UpdateRecvRow,
        Eta      = FmtEta,
        BATCH    = CMD_BATCH_SIZE,
        ACK      = CMD_PUSH_ACK,
    }

    -- The transfer bar is for genuinely long sends only - routine syncs
    -- announce themselves in chat instead (see the apply reporter in
    -- ApplyInbound).
    local PROGRESS_SEND_MIN = 250
    local function PumpSendQueue()
        if _mss.sendPending <= 0 then
            if sendTicker then sendTicker:Cancel(); sendTicker = nil end
            sendNextAt, sendThrottled = 0, 0
            return
        end
        -- The ticker keeps its fast granularity; this is the real rate
        -- limit. Idle ticks cost a clock read and a compare.
        local now = GetTime()
        if now < sendNextAt then return end
        if _mss.sendPending > (MS._drainHigh or 0) then MS._drainHigh = _mss.sendPending end
        local item
        local n = #sendOrder
        for _ = 1, math.max(n, 1) do
            sendRR = (n > 0) and ((sendRR % n) + 1) or 0
            local tk = sendOrder[sendRR]
            local q = tk and sendQueues[tk]
            if q and q[1] then
                item = table_remove(q, 1)
                _mss.sendPending = _mss.sendPending - 1
                if not q[1] then
                    sendQueues[tk] = nil
                    RebuildSendOrder()
                end
                break
            end
        end
        if not item then
            RebuildSendOrder()
            local total = 0
            for _, q in pairs(sendQueues) do total = total + #q end
            _mss.sendPending = total
            return
        end
        if SendOne(item.msg, item.target, item.retries) then
            sendThrottled = 0
            sendNextAt = now + CurrentSendInterval()
        else
            -- Refused. Escalate 1s / 2s / 4s and hold the WHOLE pump, not
            -- just this chunk - the allowance is per prefix, so every
            -- other target is equally blocked and hammering them only
            -- keeps the bucket at zero.
            sendThrottled = math.min(sendThrottled + 1, #THROTTLE_BACKOFF)
            sendNextAt = now + THROTTLE_BACKOFF[sendThrottled]
            RC:DebugPrint("MeshSync: throttled, backing off "
                .. THROTTLE_BACKOFF[sendThrottled] .. "s", "meshsync")
        end
        local high = MS._drainHigh or 0
        local remaining = _mss.sendPending
        if high >= PROGRESS_SEND_MIN then
            UpdateSendRow(remaining, high)
            if remaining == 0 then
                RC:Print(RCL["Mesh: all queued sync data sent ("] .. high .. RCL[" parts)."])
            end
        end
        if remaining == 0 then
            MS._drainHigh = 0
        end
    end

    local prioNext = false
    function MS:SetNextSendPriority() prioNext = true end

    -- Single-message sends jump the queue so control traffic is not stuck
    -- behind a bulk transfer. keepOrder defeats that on purpose: PUSH_DONE
    -- names the categories it just sent and must land after them.
    local function EnqueueMessages(msgs, targetCharName, keepOrder)
        if not QueueHasRoom(#msgs) then return end
        if not keepOrder and (prioNext or #msgs == 1) then
            prioNext = false
            for i = #msgs, 1, -1 do
                SendPush({ msg = msgs[i], target = targetCharName }, true)
            end
        else
            for _, m in ipairs(msgs) do
                SendPush({ msg = m, target = targetCharName })
            end
        end
        if not sendTicker then
            if RC.Profiler and RC.Profiler.TrackTicker then
                sendTicker = RC.Profiler:TrackTicker("MeshSync:SendQueue", SEND_INTERVAL, PumpSendQueue)
            else
                sendTicker = C_Timer.NewTicker(SEND_INTERVAL, PumpSendQueue)
            end
        end
    end

    local function BroadcastToAllMembers(msgs, keepOrder)
        if not _mss.cfg then return 0 end
        local sent    = {}
        local targets = {}
        local now     = _mss._pollBroadcast and GetTime() or nil

        -- BNet-only peers are skipped: the whisper bridge is single-message,
        -- so bulk chunked data cannot reach them at all.
        for label, info in pairs(knownAccounts) do
            if info.online and info.charName and not info.viaBNet then
                -- On a poll-driven broadcast, hold off peers that came online
                -- in the last 4 seconds - their login sync is still deciding
                -- what to exchange, and this would duplicate it.
                if now and info.cameOnlineAt and (now - info.cameOnlineAt) < 4 then
                else
                    local target = NormalizeName(info.charName)
                    if target and not sent[target] then
                        sent[target] = true
                        targets[#targets+1] = target
                    end
                end
            end
        end

        -- Members the server recently told us are offline are skipped until
        -- their backoff lapses (see OFFLINE_BACKOFF); knownAccounts online
        -- peers above are never affected.
        local tnow = GetTime()
        for _, member in ipairs(_mss.cfg.members or {}) do
            local target = NormalizeName(member.name)
            if target and not sent[target] then
                local ou = offlineUntil[target]
                if not (ou and ou > tnow) then
                    sent[target] = true
                    targets[#targets+1] = target
                end
            end
        end

        local count = #targets
        if count == 0 then return 0 end
        if #msgs > 1 and not QueueHasRoom(#msgs * count) then return 0 end

        if count == 1 then
            EnqueueMessages(msgs, targets[1], keepOrder)
        else
            for i = 1, #msgs do
                for _, target in ipairs(targets) do
                    SendPush({ msg = msgs[i], target = target })
                end
            end
            if not sendTicker then
                if RC.Profiler and RC.Profiler.TrackTicker then
                    sendTicker = RC.Profiler:TrackTicker("MeshSync:SendQueue", SEND_INTERVAL, PumpSendQueue)
                else
                    sendTicker = C_Timer.NewTicker(SEND_INTERVAL, PumpSendQueue)
                end
            end
        end

        return count
    end

    local function WalkHash(val, h, depth)
        if depth > 25 then return h end
        local t = type(val)
        if t == "number" then
            local i = math_floor(val)
            local f = math_floor((val - i) * 1000)
            h = ((h * 33) + i)     % 4294967296
            h = ((h * 33) + f + 1) % 4294967296
        elseif t == "boolean" then
            h = ((h * 33) + (val and 3 or 7)) % 4294967296
        elseif t == "string" then
            -- Long strings are sampled at two interleaved strides rather
            -- than hashed whole - this runs over every synced category once
            -- a second. Cost: two long strings that differ only at unsampled
            -- offsets hash equal and never re-push.
            local n = #val
            local stride = math_floor(n / 100) + 1
            for i = 1, n, stride do h = ((h * 33) + val:byte(i)) % 4294967296 end
            if stride > 1 then
                local half = math_floor(stride / 2) + 1
                for i = half, n, stride do h = ((h * 33) + val:byte(i)) % 4294967296 end
            end
            h = ((h * 33) + n + 1) % 4294967296
        elseif t == "table" then
            local count    = 0
            local pairSum  = 0
            for k, v in pairs(val) do
                count = count + 1
                local kh = WalkHash(k, 5381, depth + 1)
                pairSum = (pairSum + WalkHash(v, kh, depth + 1)) % 4294967296
            end
            h = ((h * 33) + pairSum + count * 17) % 4294967296
        end
        return h
    end

    -- Per-boss fight lists are summed, not walked in order: two clients
    -- holding the same fights in a different order must agree, otherwise
    -- executeCalc would re-push on every HELLO forever.
    local function HashFightHistory(data)
        if type(data) ~= "table" then return 5381 end
        local total = 0
        for bossKey, fights in pairs(data) do
            local bossSum = 0
            if type(fights) == "table" then
                for _, f in ipairs(fights) do
                    bossSum = (bossSum + WalkHash(f, 5381, 0)) % 4294967296
                end
            end
            local keyed = WalkHash(bossKey, 5381, 0)
            total = (total + ((keyed * 33 + bossSum) % 4294967296)) % 4294967296
        end
        return total
    end

    local function SlimRouteCfg()
        local rr = RC.db and RC.db.raidRoute
        if type(rr) ~= "table" then return nil end
        local slim = {}
        for k, v in pairs(rr) do
            if k ~= "runtime" then slim[k] = v end
        end
        return slim
    end

    -- Comparator for sorting mixed-type table keys before an order-sensitive hash.
    local function SortKeyLess(a, b)
        return tostring(a) < tostring(b)
    end

    -- 8 hex chars; only the first HELLO_HASH_LEN of them ride in the HELLO
    -- digest. executeCalc, raidProfiles and sidebar are hand-rolled because
    -- their live state is not simply RC.db[key] - hashing them generically
    -- would report a change on every login and re-push endlessly.
    --
    -- LAW: hash exactly what ships. Anything folded into the hash that the
    -- payload omits (or vice versa) makes sender and receiver hashes
    -- permanently unequal, and the login digest then re-pushes that
    -- category in full on every login, forever. That is precisely what
    -- happened with fight history under syncFightHistory=false and raid
    -- gear under syncRaidGear=false.
    local HashBossesStripped -- defined after StripGearFromBoss below
    local function GetCategoryHash(categoryId)
        if not RC.db then return "" end

        if categoryId == "executeCalc" then
            local ec = RC.executeCalculator
            if not ec then return string_format("%08x", 5381) end
            -- Hash exactly what ships: a field excluded in Sync Rules must
            -- not shape the hash either, or the digest never matches the
            -- peer's and the category re-pushes on every login.
            local skip = StripKeySet("executeCalc")
            local function on(field)
                return not (skip and (skip.executeSettings
                    or skip["executeSettings." .. field]))
            end
            -- Sub-tables (mlConfig, uiSettings, ...) may have depth-2
            -- exclusions; strip those the same way the payload does.
            local function sub(field, value)
                if type(value) ~= "table" or not skip then return value end
                local wrapped = StripNestedCopy({ [field] = value }, "executeSettings", skip)
                return wrapped[field]
            end
            local h = 5381
            if on("executeThreshold") then h = WalkHash(ec.executeThreshold, h, 0) end
            if on("mode")             then h = WalkHash(ec.mode, h, 0) end
            if on("collectData")      then h = WalkHash(ec.collectData, h, 0) end
            if on("mlConfig")         then h = WalkHash(sub("mlConfig", ec.mlConfig), h, 0) end
            if on("dataCollection")   then h = WalkHash(sub("dataCollection", ec.dataCollection), h, 0) end
            if ec.classicMultipliers then
                if on("classicGlobalMultiplier") then h = WalkHash(ec.classicMultipliers.global,  h, 0) end
                if on("classicBossMultipliers")  then h = WalkHash(ec.classicMultipliers.perBoss, h, 0) end
            end
            if ec.ewma then
                if on("ewmaEnabled") then h = WalkHash(ec.ewma.enabled, h, 0) end
                if on("ewmaAlpha")   then h = WalkHash(ec.ewma.alpha,   h, 0) end
            end
            if ec.testMode and on("testModeEnabled") then
                h = WalkHash(ec.testMode.enabled, h, 0)
            end
            if on("uiSettings") then h = WalkHash(sub("uiSettings", ec.uiSettings), h, 0) end
            -- History rides in the hash only when it rides in the payload.
            if _mss.charCfg and _mss.charCfg.syncFightHistory
                    and ec.fightHistory and ec.fightHistory.data then
                h = ((h * 33) + HashFightHistory(ec.fightHistory.data)) % 4294967296
            end
            return string_format("%08x", h)
        end

        if categoryId == "raidProfiles" then
            local h = 5381
            local stripGear = not (_mss.charCfg and _mss.charCfg.syncRaidGear)
            -- The chained hash below is order-sensitive, so every pairs()
            -- level is walked in sorted key order; otherwise two clients
            -- holding identical data can disagree and re-push forever.
            if RC.db.raidProfiles then
                local raidKeys = {}
                for raidKey in pairs(RC.db.raidProfiles) do raidKeys[#raidKeys+1] = raidKey end
                table.sort(raidKeys, SortKeyLess)
                for _, raidKey in ipairs(raidKeys) do
                    local rd = RC.db.raidProfiles[raidKey]
                    if type(rd) == "table" and rd.profiles then
                        h = WalkHash(raidKey, h, 0)
                        local profNames = {}
                        for pn in pairs(rd.profiles) do profNames[#profNames+1] = pn end
                        table.sort(profNames, SortKeyLess)
                        for _, pn in ipairs(profNames) do
                            local pd = rd.profiles[pn]
                            if type(pd) == "table" then
                                h = WalkHash(pn, h, 0)
                                h = WalkHash(pd.enabled, h, 0)
                                if stripGear and HashBossesStripped then
                                    -- Gear never ships with the rule off, so
                                    -- it must not shape the hash either
                                    -- (memoized - this runs in the poll).
                                    h = ((h * 33) + HashBossesStripped(
                                        raidKey, pn, pd.bosses)) % 4294967296
                                else
                                    h = WalkHash(pd.bosses, h, 0)
                                end
                                h = WalkHash(pd.trash, h, 0)
                                h = WalkHash(pd.route, h, 0)
                            end
                        end
                    end
                end
            end
            local skip = StripKeySet("raidProfiles")
            for _, k in ipairs({"polarityMode","frostBlastConfig"}) do
                if RC.db[k] ~= nil and not (skip and skip[k]) then
                    h = WalkHash(RC.db[k], h, 0)
                end
            end
            local rrCfg = (not (skip and skip.raidRoute)) and SlimRouteCfg() or nil
            if rrCfg then
                local rrKeys = {}
                for k in pairs(rrCfg) do rrKeys[#rrKeys+1] = k end
                table.sort(rrKeys, SortKeyLess)
                for _, k in ipairs(rrKeys) do
                    h = WalkHash(k, h, 0)
                    h = WalkHash(rrCfg[k], h, 0)
                end
            end
            return string_format("%08x", h)
        end

        if categoryId == "sidebar" then
            -- Only the stable keys; sidebarState/lastSidebarSelection churn
            -- with every click and would re-push constantly. Width/height
            -- ARE shipped (unless excluded per setting), so they must be
            -- hashed too - resizing was previously invisible to the poll
            -- ticker.
            local skip = StripKeySet("sidebar")
            local h = 5381
            for _, k in ipairs({"sidebarPosition","configWindowWidth","configWindowHeight"}) do
                if RC.db[k] ~= nil and not (skip and skip[k]) then
                    h = WalkHash(RC.db[k], h, 0)
                end
            end
            return string_format("%08x", h)
        end

        local catDef = nil
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            if cat.id == categoryId then catDef = cat; break end
        end
        if not catDef then return "" end
        local skip = StripKeySet(categoryId)
        -- Fast path when no per-setting exclusions exist for this category:
        -- this runs once per category per second in the poll ticker.
        local nested = HasNestedSkips(skip)
        local h = 5381
        for _, key in ipairs(catDef.keys) do
            if RC.db[key] ~= nil and not (skip and skip[key]) then
                local v = RC.db[key]
                if nested then v = StripNestedCopy(v, key, skip) end
                h = WalkHash(v, h, 0)
            end
        end
        return string_format("%08x", h)
    end

    -- Raid configs are only ever pushed per raid key from this list. A raid
    -- saved under any other name is stored locally but never syncs.
    local KNOWN_RAID_KEYS = {
        "Molten Core", "Blackwing Lair", "Temple of Ahn'Qiraj",
        "Naxxramas", "Onyxia's Lair", "Zul'Gurub", "Ruins of Ahn'Qiraj",
    }

    local function QuickHash(val)
        return string_format("%08x", WalkHash(val, 5381, 0))
    end

    local function StripGearFromBoss(bossData)
        if not bossData then return bossData end
        local copy = RC.DeepCopy(bossData)
        if copy.abilities then
            copy.abilities.gearswap = nil
            for _, aCfg in pairs(copy.abilities) do
                if type(aCfg) == "table" then
                    aCfg.gearSet        = nil
                    aCfg.postCombatSet  = nil
                    aCfg.postCombatSwap = nil
                    aCfg.itemRackSet    = nil
                end
            end
        end
        copy.fungalBloom  = nil
        copy.forceEquip   = nil
        return copy
    end

    local function StripGearFromRaid(rd)
        if not rd then return rd end
        local copy = RC.DeepCopy(rd)
        if copy.profiles then
            for _, pd in pairs(copy.profiles) do
                if pd.bosses then
                    for bossName, bossData in pairs(pd.bosses) do
                        pd.bosses[bossName] = StripGearFromBoss(bossData)
                    end
                end
            end
        end
        return copy
    end

    -- Hash of a profile's bosses with gear stripped, memoized on the raw
    -- hash so the deep copy only happens when a boss actually changed.
    -- GetCategoryHash runs in the poll ticker; stripping every raid on
    -- every pass would be a per-second DeepCopy of the whole raid config.
    -- WalkHash's table sum is insertion-order independent, so the hash of
    -- the rebuilt table equals the receiver hashing its stored copy.
    local _strippedBossHashCache = {}
    HashBossesStripped = function(raidKey, profileName, bosses)
        if type(bosses) ~= "table" then return WalkHash(bosses, 5381, 0) end
        local rawH = WalkHash(bosses, 5381, 0)
        local ck = raidKey .. ":" .. profileName
        local c = _strippedBossHashCache[ck]
        if c and c.raw == rawH then return c.stripped end
        local copy = {}
        for bn, bd in pairs(bosses) do copy[bn] = StripGearFromBoss(bd) end
        local sH = WalkHash(copy, 5381, 0)
        _strippedBossHashCache[ck] = { raw = rawH, stripped = sH }
        return sH
    end

    -- Only the active profile's contents travel (the whole raid config is far
    -- too big for the chat protocol), but the full NAME list rides along.
    -- Without it a delete, rename or merge done while remote editing never
    -- reached the other character: they only ever heard about the profile that
    -- happened to be active, so removed ones lived on forever on their side.
    local function SlimRaidData(rd)
        if type(rd) ~= "table" or not rd.profiles then return rd end
        local names = {}
        for pn in pairs(rd.profiles) do names[#names + 1] = pn end
        table.sort(names)
        local activeName = rd.activeProfile or "Default"
        local activeProf = rd.profiles[activeName]
        if not activeProf then
            return { activeProfile = rd.activeProfile, profiles = rd.profiles,
                     profileList = names }
        end
        return {
            activeProfile = activeName,
            profiles      = { [activeName] = activeProf },
            profileList   = names,
        }
    end

    local function HistoryMaxTimestamp(data)
        local maxTs = 0
        if type(data) == "table" then
            for _, fights in pairs(data) do
                if type(fights) == "table" then
                    for _, f in ipairs(fights) do
                        if (f.timestamp or 0) > maxTs then maxTs = f.timestamp end
                    end
                end
            end
        end
        return maxTs
    end

    -- ONE payload builder for both transports. MS:Push ships what this
    -- returns over the wire; WriteSameAccountSync (Mesh_Remote) deep-copies
    -- it into the shared same-account snapshot. Before this existed each
    -- path hand-built its own payload and they drifted: the snapshot's
    -- raidProfiles carried raidRoute.runtime and unknown raid keys the wire
    -- never ships, and its executeCalc left the history watermark stale.
    --
    -- opts.history = "full" includes fight history (still subject to the
    -- syncFightHistory rule); nil leaves it out - the wire path owns its
    -- own delta logic and watermark stamping inside MS:Push.
    --
    -- Returns payload, err (err = "nodata" | "stripped"). The payload holds
    -- live references into RC.db except where stripping substituted copies;
    -- callers that persist it must deep-copy.
    -- Per-click UI churn the sidebar hash deliberately leaves out; the
    -- payload must omit the same keys or hash and shipment disagree.
    local SIDEBAR_VOLATILE_KEYS = {
        sidebarState = true, lastSidebarSelection = true,
        sidebarNav = true, profilePicker = true,
    }

    local function BuildCategoryPayload(categoryId, opts)
        if not RC.db then return nil, "nodata" end
        opts = opts or {}

        if categoryId == "executeCalc" then
            local ec = RC.executeCalculator
            if not ec then return nil, "nodata" end
            local es = {
                executeThreshold        = ec.executeThreshold,
                testModeEnabled         = ec.testMode and ec.testMode.enabled,
                mode                    = ec.mode,
                collectData             = ec.collectData,
                classicGlobalMultiplier = ec.classicMultipliers and ec.classicMultipliers.global,
                classicBossMultipliers  = ec.classicMultipliers and ec.classicMultipliers.perBoss,
                mlConfig                = ec.mlConfig,
                ewmaEnabled             = ec.ewma and ec.ewma.enabled,
                ewmaAlpha               = ec.ewma and ec.ewma.alpha,
                dataCollection          = ec.dataCollection,
                uiSettings              = ec.uiSettings,
            }
            if opts.history == "full" and _mss.charCfg
                    and _mss.charCfg.syncFightHistory
                    and ec.fightHistory and ec.fightHistory.data
                    and next(ec.fightHistory.data) then
                es.fightHistory = {
                    data           = ec.fightHistory.data,
                    maxHistorySize = ec.fightHistory.maxHistorySize or 500,
                }
            end
            return { executeSettings = es }
        end

        if categoryId == "raidProfiles" then
            -- Exactly the shape the wire ships: known raid keys only, gear
            -- stripped when the rule says so, and the slimmed route config
            -- instead of raw raidRoute (which drags runtime state along).
            if not RC.db.raidProfiles then return nil, "nodata" end
            local rps, any = {}, false
            local stripGear = not (_mss.charCfg and _mss.charCfg.syncRaidGear)
            for _, raidKey in ipairs(KNOWN_RAID_KEYS) do
                local rd = RC.db.raidProfiles[raidKey]
                if rd then
                    rps[raidKey] = stripGear and StripGearFromRaid(rd) or rd
                    any = true
                end
            end
            if not any then return nil, "nodata" end
            local payload = { raidProfiles = rps }
            for _, k in ipairs({"polarityMode","frostBlastConfig"}) do
                if RC.db[k] ~= nil then payload[k] = RC.db[k] end
            end
            payload.raidRoute = SlimRouteCfg()
            payload = ApplyPayloadStrips(categoryId, payload)
            if not payload then return nil, "stripped" end
            return payload
        end

        local catDef = nil
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            if cat.id == categoryId then catDef = cat; break end
        end
        if not catDef then return nil, "nodata" end

        local payload = {}
        local hasData = false
        for _, key in ipairs(catDef.keys) do
            if RC.db[key] ~= nil
                    and not (categoryId == "sidebar" and SIDEBAR_VOLATILE_KEYS[key]) then
                payload[key] = RC.db[key]
                hasData = true
            end
        end
        if not hasData then return nil, "nodata" end
        payload = ApplyPayloadStrips(categoryId, payload)
        if not payload then return nil, "stripped" end
        return payload
    end
    MS.BuildCategoryPayload   = BuildCategoryPayload
    _mss.BuildCategoryPayload = BuildCategoryPayload

    function MS:DebugHashBreakdown()
        local ec = RC.executeCalculator
        if not ec then RC:Print(RCL["meshhash: no executeCalculator"]) return end
        local function one(label, ...)
            local h = 5381
            local n = select("#", ...)
            for i = 1, n do h = WalkHash((select(i, ...)), h, 0) end
            RC:Print(string_format("  %-16s %08x", label, h))
        end
        RC:Print(RCL["executeCalc component hashes (compare across toons):"])
        one("threshold",   ec.executeThreshold)
        one("mode",        ec.mode)
        one("collectData", ec.collectData)
        one("mlConfig",    ec.mlConfig)
        one("dataColl",    ec.dataCollection)
        one("multipliers", ec.classicMultipliers and ec.classicMultipliers.global,
                           ec.classicMultipliers and ec.classicMultipliers.perBoss)
        one("ewma",        ec.ewma and ec.ewma.enabled, ec.ewma and ec.ewma.alpha)
        one("testMode",    ec.testMode and ec.testMode.enabled)
        one("uiSettings",  ec.uiSettings)
        if ec.fightHistory and ec.fightHistory.data then
            RC:Print(string_format("  %-16s %08x", "history",
                HashFightHistory(ec.fightHistory.data)))
            RC:Print(RCL["  history newest: "] .. tostring(HistoryMaxTimestamp(ec.fightHistory.data)))
        end
        RC:Print(string_format("  %-16s %s", "category", GetCategoryHash("executeCalc")))
        RC:Print(RCL["  my watermark: "] .. tostring(MS._histWatermark or 0))
        local nowP = GetTime()
        for ns2, rec in pairs(knownChars) do
            RC:Print(string_format("  peer %s: wm=%s ec=%s age=%ds",
                tostring(ns2), tostring(rec.histWm or "?"),
                tostring(rec.hashes and rec.hashes["executeCalc"] or "?"),
                math_floor(nowP - (rec.seenAt or nowP))))
        end
        for label, rec in pairs(knownAccounts) do
            RC:Print(string_format("  acct %s: wm=%s ec=%s age=%ds",
                tostring(label), tostring(rec.histWm or "?"),
                tostring(rec.hashes and rec.hashes["executeCalc"] or "?"),
                math_floor(nowP - (rec.seenAt or nowP))))
        end
    end

    -- Seed the "already broadcast" hashes from current state at enable time,
    -- so switching the mesh on does not immediately push every category the
    -- peer already has. Includes the per-boss, per-route and per-raid meta
    -- sub-hashes the poll ticker compares against.
    local function InitBroadcastHashes()
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            _lastBroadcastHash[cat.id] = GetCategoryHash(cat.id)
        end
        if RC.executeCalculator and RC.executeCalculator.fightHistory then
            MS._histWatermark = HistoryMaxTimestamp(RC.executeCalculator.fightHistory.data)
            if RC.executeCalculator.fightHistory.data then
                _lastBroadcastHash["executeCalc_history"] =
                    HashFightHistory(RC.executeCalculator.fightHistory.data)
            end
        end
        if RC.db and RC.db.raidProfiles then
            for _, raidKey in ipairs(KNOWN_RAID_KEYS) do
                local raidData = RC.db.raidProfiles[raidKey]
                if raidData then
                    if raidData.profiles then
                        for pn, pd in pairs(raidData.profiles) do
                            if pd.bosses then
                                for bossName, bossData in pairs(pd.bosses) do
                                    _lastBroadcastHash["_boss_"..raidKey..":"..pn..":"..bossName] = QuickHash(bossData)
                                end
                            end
                            if type(pd.route) == "table" then
                                _lastBroadcastHash["_route_"..raidKey..":"..pn] = QuickHash(pd.route)
                            end
                        end
                    end
                    local metaInit = {}
                    if raidData.profiles then
                        for pn, pd in pairs(raidData.profiles) do
                            metaInit[pn] = { enabled = pd.enabled, trash = pd.trash }
                        end
                    end
                    _lastBroadcastHash["_meta_"..raidKey] = QuickHash(metaInit)
                    _lastBroadcastHash["_routeCfg"] = QuickHash(SlimRouteCfg() or {})
                end
            end
        end
    end

    -- Fingerprint of this client's category layout - the id list AND its
    -- order. The digest is positional, so it is only meaningful when both ends
    -- agree on both; otherwise slot N on the sender names a different category
    -- than slot N here, and every comparison is silently against the wrong data.
    local function CategoryLayoutFingerprint()
        local h = 5381
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            local id = tostring(cat.id)
            for i = 1, string_len(id) do
                h = ((h * 33) + string_byte(id, i)) % 4294967296
            end
            h = ((h * 33) + 31) % 4294967296
        end
        h = ((h * 33) + #MS.SYNC_CATEGORIES) % 4294967296
        return string_format("%08x", h):sub(1, HELLO_HASH_LEN)
    end
    MS.CategoryLayoutFingerprint = CategoryLayoutFingerprint

    -- compact: omit the per-category digest entirely. Used for the
    -- cross-faction YELL copy, whose base64 budget cannot fit the full array.
    -- Peers receiving it simply treat everything as mismatched and full-sync.
    local function BuildHelloData(compact)
        if not RC.db then return "" end
        local uptime = math_floor(GetTime() - _mss._enabledAt)
        if uptime > 999 then uptime = 999 end
        if uptime < 0   then uptime = 0   end

        local wm = 0
        if RC.executeCalculator and RC.executeCalculator.fightHistory then
            wm = HistoryMaxTimestamp(RC.executeCalculator.fightHistory.data) or 0
        end

        local head = HELLO_V3_MARK
            .. string_format("%03d", uptime)
            .. CategoryLayoutFingerprint()
        local tail = string_format("%010d", math_floor(wm))

        local budget  = compact and HELLO_MAX_YELL_DATA or HELLO_MAX_DATA
        local room    = budget - string_len(head) - string_len(tail)
        local maxCats = math_floor(room / HELLO_HASH_LEN)
        if maxCats < 0 then maxCats = 0 end

        local parts, nCats = {}, 0
        if not compact then
            for _, cat in ipairs(MS.SYNC_CATEGORIES) do
                if nCats >= maxCats then break end
                local h8 = _lastBroadcastHash[cat.id] or GetCategoryHash(cat.id)
                parts[#parts+1] = tostring(h8):sub(1, HELLO_HASH_LEN)
                nCats = nCats + 1
            end
            if nCats < #MS.SYNC_CATEGORIES then
                RC:DebugPrint(string_format(
                    "MeshSync: HELLO digest truncated - only %d of %d categories fit in one "
                    .. "addon message. Peers will re-push the remainder instead of skipping it. "
                    .. "Shrink HELLO or move the digest to a chunked message.",
                    nCats, #MS.SYNC_CATEGORIES), "meshsync")
            end
        end

        local out = head .. table_concat(parts) .. tail
        if RC.IsDebugEnabled and RC:IsDebugEnabled("meshsync") then
            RC:DebugPrint(string_format(
                "Mesh HELLO out: len=%d cats=%d/%d fp=%s wm=%d%s",
                string_len(out), nCats, #MS.SYNC_CATEGORIES,
                CategoryLayoutFingerprint(), math_floor(wm),
                compact and " (compact/yell)" or ""), "meshsync", 0)
        end
        return out
    end

    local function ParsePeerHashes(data)
        local hashes, peerUptime, histWm = {}, 0, 0
        if not data or string_len(data) < 3 then return hashes, 0, 0 end

        local dlen  = string_len(data)
        local isV3  = (string_sub(data, 1, 2) == HELLO_V3_MARK)
        local base, hashEnd, layoutOk

        if isV3 then
            if dlen < 20 then return hashes, 0, 0 end
            peerUptime   = tonumber(string_sub(data, 3, 5)) or 0
            local peerFp = string_sub(data, 6, 10)
            local myFp   = CategoryLayoutFingerprint()
            layoutOk     = (peerFp == myFp)
            base         = 10
            histWm       = tonumber(string_sub(data, -10)) or 0
            hashEnd      = dlen - 10
            if not layoutOk then
                -- Addon versions differ. Positional slots no longer line up, so
                -- every hash would name the wrong category. Discard the digest:
                -- an empty table reads as "everything mismatched", which
                -- re-pushes rather than wrongly skipping a real change.
                RC:DebugPrint("MeshSync: peer HELLO layout " .. tostring(peerFp)
                    .. " != ours " .. myFp
                    .. " - addon versions differ. Ignoring its digest, syncing in full.",
                    "meshsync")
            end
        else
            -- Pre-v3 peer: no fingerprint, so we cannot verify alignment.
            -- Decode positionally exactly as before - unchanged behaviour.
            peerUptime = tonumber(string_sub(data, 1, 3)) or 0
            base       = 3
            layoutOk   = true
            hashEnd    = dlen
            local tail = string_sub(data, -10)
            if dlen >= 18 and ((dlen - 13) % 5 == 0)
                    and tail:match("^%d%d%d%d%d%d%d%d%d%d$") then
                histWm  = tonumber(tail) or 0
                hashEnd = dlen - 10
            end
        end

        if layoutOk then
            for i, cat in ipairs(MS.SYNC_CATEGORIES) do
                local off = base + (i - 1) * HELLO_HASH_LEN + 1
                if off + HELLO_HASH_LEN - 1 <= hashEnd then
                    hashes[cat.id] = string_sub(data, off, off + HELLO_HASH_LEN - 1)
                end
            end
        end

        if RC.IsDebugEnabled and RC:IsDebugEnabled("meshsync") then
            RC:DebugPrint(string_format(
                "Mesh HELLO in: len=%d v%d layout=%s wm=%d",
                dlen, isV3 and 3 or 1, layoutOk and "ok" or "MISMATCH", histWm),
                "meshsync", 0)
        end
        return hashes, peerUptime, histWm
    end

    -- The yell leg rides the CHAT pipeline: every addon message on YELL
    -- counts against the same server throttle as /say and /yell. It used
    -- to send instantly and unthrottled, so a burst - WBUFF re-broadcasts
    -- while buffs land during a world buff drop, stacked on WBT_Comms'
    -- own yell chunks - earned the player a "You are sending too many
    -- messages" squelch. All yells now drain through one queue: at least
    -- YELL_GAP apart, and state-carrying commands coalesce so only the
    -- NEWEST payload of each is ever waiting (they encode full current
    -- state, so replacing a stale queued copy loses nothing).
    local YELL_GAP        = 2.0
    local YELL_QUEUE_MAX  = 10
    local YELL_COALESCE   = {
        [CMD_HELLO] = true, [CMD_CAP] = true,
        WBTIME = true, WBUFF = true,
    }
    local yellQueue  = {}
    local yellLastAt = 0
    local yellTimer  = nil

    local function DrainYellQueue()
        yellTimer = nil
        if not yellQueue[1] then return end
        -- held inside an instance on Forever (Core_Flavor)
        if RC:AddonMessagesBlocked() then
            yellTimer = C_Timer.NewTimer(YELL_GAP, DrainYellQueue)
            return
        end
        local entry = table.remove(yellQueue, 1)
        C_ChatInfo.SendAddonMessage(ADDON_PREFIX, entry.enc, "YELL")
        yellLastAt = GetTime()
        RC:DebugPrint("YellFanout: yelled " .. tostring(entry.cmd or "?")
            .. " (" .. #yellQueue .. " queued)", "meshsync")
        if #yellQueue > 0 then
            yellTimer = C_Timer.NewTimer(YELL_GAP, DrainYellQueue)
        end
    end

    local function PumpYellQueue()
        if yellTimer or #yellQueue == 0 then return end
        local wait = YELL_GAP - (GetTime() - yellLastAt)
        if wait <= 0 then
            DrainYellQueue()
        else
            yellTimer = C_Timer.NewTimer(wait, DrainYellQueue)
        end
    end

    local function YellFanout(msgs, cmd)
        if not _mss.cfg or not _mss.cfg.crossFaction then return end
        if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
        local oversize = 0
        for _, m in ipairs(msgs) do
            local enc = RC:EncodeBase64ForSettings(m)
            if enc and enc ~= "" then
                -- Base64 inflates header+data by 4/3. Anything past the 255
                -- byte addon-message cap is rejected by the client and vanishes
                -- with no error, so catch it here rather than lose the message.
                if string_len(enc) > 255 then
                    oversize = oversize + 1
                else
                    local queued = false
                    if cmd and YELL_COALESCE[cmd] then
                        for _, e in ipairs(yellQueue) do
                            if e.cmd == cmd then
                                e.enc = enc
                                queued = true
                                break
                            end
                        end
                    end
                    if not queued then
                        if #yellQueue >= YELL_QUEUE_MAX then
                            RC:DebugPrint("YellFanout: queue full - dropped a "
                                .. tostring(cmd or "?") .. " yell", "meshsync")
                        else
                            yellQueue[#yellQueue + 1] = { enc = enc, cmd = cmd }
                        end
                    end
                end
            end
        end
        if oversize > 0 then
            RC:DebugPrint("YellFanout: dropped " .. oversize
                .. " oversized msg(s) - exceeded 255 bytes after base64. "
                .. "Cross-faction peers will not have seen these.", "meshsync")
        end
        PumpYellQueue()
    end

    -- clientProgram "App"/"BSAp" is the desktop or mobile Battle.net client;
    -- a wowProjectID is the only proof the friend is actually in game and
    -- can receive an addon whisper.
    local function FriendInWoW(acc)
        local g = acc and acc.gameAccountInfo
        if not g or not g.isOnline then return false, nil end
        local cp = g.clientProgram or ""
        if cp == "App" or cp == "BSAp" or cp == "" then
            if g.wowProjectID and g.wowProjectID ~= 0 then return true, cp end
            return false, cp
        end
        return true, cp
    end

    -- Cross-faction leg for single-message commands: one BNet whisper of
    -- "RCMESH:" + base64(header .. data) to each battleTag listed in
    -- cfg.crossFactionPeers. Never chunks - callers must keep the payload
    -- inside one message after base64 inflation.
    -- Deduped per (account, dedupKey) against the caller's signature, so
    -- unchanged state is whispered once. Clearing _xfSent when a friend
    -- drops out of WoW forces a resend on their next login.
    function MS:CrossFactionWhisper(cmd, data, sig, dedupKey)
        if not _mss.cfg or not _mss.cfg.crossFaction then return end
        local peers = _mss.cfg.crossFactionPeers
        if not peers or not next(peers) then return end
        if not (BNSendWhisper and BNGetNumFriends and C_BattleNet
                and C_BattleNet.GetFriendAccountInfo) then return end
        local from   = GetMyLabel()
        local msgId  = NextMsgId()
        local token  = GetToken()
        local header = BuildHeader(from, msgId, 1, 1, token, cmd)
        local enc    = RC:EncodeBase64ForSettings(header .. (data or ""))
        if not enc or enc == "" then return end
        local wmsg = "RCMESH:" .. enc
        if string_len(wmsg) > 255 then
            RC:DebugPrint("CrossFactionWhisper: " .. tostring(cmd) .. " is " .. string_len(wmsg)
                .. " bytes after base64 (max 255) - not sent", "meshsync")
            return
        end
        sig = sig or ""
        dedupKey = dedupKey or "_self"
        self._xfSent = self._xfSent or {}
        local n = BNGetNumFriends() or 0
        for i = 1, n do
            local acc = C_BattleNet.GetFriendAccountInfo(i)
            if acc and acc.bnetAccountID and acc.battleTag and peers[acc.battleTag] then
                local id = acc.bnetAccountID
                local inWoW, cp = FriendInWoW(acc)
                if not inWoW then
                    if self._xfSent[id] ~= nil then
                        RC:DebugPrint("CrossFactionWhisper: " .. tostring(acc.battleTag)
                            .. " not in WoW (clientProgram=" .. tostring(cp) .. ") - not whispering", "meshsync")
                    end
                    self._xfSent[id] = nil
                else
                    local sent = self._xfSent[id]
                    if not sent then sent = {}; self._xfSent[id] = sent end
                    -- Signature match suppresses the resend only for 10
                    -- minutes. BNet whispers are fire-and-forget; a lost
                    -- one used to stay lost for the whole session as long
                    -- as the state (and so the signature) never changed.
                    self._xfSentAt = self._xfSentAt or {}
                    local atKey  = id .. ":" .. dedupKey
                    local sentAt = self._xfSentAt[atKey] or 0
                    if sent[dedupKey] ~= sig or (GetTime() - sentAt) > 600 then
                        BNSendWhisper(id, wmsg)
                        sent[dedupKey] = sig
                        self._xfSentAt[atKey] = GetTime()
                        RC:DebugPrint("CrossFactionWhisper: whispered " .. tostring(acc.battleTag)
                            .. " (" .. tostring(dedupKey) .. " changed, sig=" .. sig .. ")", "meshsync")
                    end
                end
            end
        end
    end

    function MS:IsBnetFriendInWoW(bnetId)
        if not bnetId then return false end
        if BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo then
            local n = BNGetNumFriends() or 0
            for i = 1, n do
                local acc = C_BattleNet.GetFriendAccountInfo(i)
                if acc and acc.bnetAccountID == bnetId then
                    return FriendInWoW(acc) and true or false
                end
            end
        end
        if C_BattleNet and C_BattleNet.GetAccountInfoByID then
            local acc = C_BattleNet.GetAccountInfoByID(bnetId)
            if acc then return FriendInWoW(acc) and true or false end
        end
        return false
    end

    -- The unchunked path: builds ONE message stamped seq 1 of 1. Anything
    -- longer than 255 bytes including the header is silently rejected by the
    -- client, so every command sent this way must be small.
    -- With a target it is whispered to that character; without one it fans
    -- out to all roster members and, unless sameFactionOnly, is also yelled.
    -- altYellData: a smaller payload substituted on the YELL leg only. The
    -- yell path base64-inflates the message 4/3, so a payload that whispers
    -- fine can still blow the 255 byte cap when yelled.
    function MS:Broadcast(cmd, data, targetCharName, sameFactionOnly, altYellData)
        if not _mss.cfg then return end
        local from  = GetMyLabel()
        local msgId = NextMsgId()
        local token = GetToken()
        local header = BuildHeader(from, msgId, 1, 1, token, cmd)
        local msgs   = { header .. (data or "") }
        if string_len(msgs[1]) > 255 then
            RC:DebugPrint("MeshSync: " .. tostring(cmd) .. " payload is " .. string_len(msgs[1])
                .. " bytes (max 255) - not sent", "meshsync")
            return
        end
        local keepOrder = (cmd == CMD_PUSH_DONE)
        if targetCharName then
            EnqueueMessages(msgs, targetCharName, keepOrder)
        else
            BroadcastToAllMembers(msgs, keepOrder)
            if not sameFactionOnly then
                YellFanout(altYellData and { header .. altYellData } or msgs, cmd)
            end
        end
    end

    -- The most data one unchunked message of `cmd` can carry, measured
    -- from the real header: the whisper leg (header + data <= 255) and
    -- the cross-faction BNet leg ("RCMESH:" + base64(header + data) <=
    -- 255, and base64 turns every 3 bytes into 4). Callers that pack
    -- their own single-message payloads size them from this instead of
    -- guessing, because an oversize message is dropped without a word.
    -- What another feature needs to sign its own traffic with the mesh's
    -- credentials without riding the mesh (the gold ledger runs on every
    -- character, mesh switched on or not): the password token and this
    -- account's label. nil when no mesh password is set - nothing may
    -- then be trusted, so nothing is sent.
    function MS:LinkAuth()
        if not _mss.cfg or (_mss.cfg.meshPassword or "") == "" then return nil end
        return GetToken(), GetMyLabel()
    end

    function MS:PayloadBudget(cmd)
        local headerLen = string_len(BuildHeader(GetMyLabel(), "0000", 1, 1, GetToken(), cmd or ""))
        local whisper = 255 - headerLen
        local xf = math_floor((255 - 7) / 4) * 3 - headerLen
        return whisper, xf
    end

    function MS:Enable()
        if not _mss.cfg then return end
        _mss.isEnabled  = true
        -- Keeps its first value: resetting it on every toggle read as a
        -- relog to every peer and triggered a full re-sync.
        _mss._enabledAt = _mss._enabledAt or GetTime()
        SetCharEnabled(true)
        -- Pending same-account snapshots first: enabling mid-session used
        -- to skip them entirely, and this character's next logout then
        -- overwrote its own slot without ever consuming the others'.
        if MS.ApplySameAccountSync then MS:ApplySameAccountSync() end
        InitBroadcastHashes()
        JoinDiscoveryChannel()
        local members = _mss.cfg.members or {}
        for i, member in ipairs(members) do
            C_Timer.After(i - 1, function()
                if not _mss.isEnabled then return end
                local target = NormalizeName(member.name)
                if target then
                    MS:Broadcast(CMD_HELLO, BuildHelloData(), target)
                    MS:Broadcast(CMD_CAP, tostring(PROTO_VERSION), target)
                end
            end)
        end
        _mss.lastHelloTime = GetTime()
        _mss.StartPollTicker()
        LogActivity("Mesh Network enabled - pinging " .. #members .. " member(s)")
        self:RefreshMeshUI()
    end

    function MS:Disable()
        if not _mss.cfg then return end
        SetCharEnabled(false)
        self:Broadcast(CMD_BYE)
        LeaveDiscoveryChannel()
        _mss.StopPollTicker()
        -- Defined in Mesh_Remote; a disabled character leaves no snapshot
        -- behind for its alts to consume.
        if self.ClearOwnSameAccountSnapshot then self:ClearOwnSameAccountSnapshot() end
        -- Let the BYE actually drain before the queue is thrown away.
        C_Timer.After(1.0, function()
            _mss.isEnabled = false
            sendQueues, sendOrder, sendRR, _mss.sendPending = {}, {}, 0, 0
            if sendTicker then sendTicker:Cancel(); sendTicker = nil end
            LogActivity("Mesh Network disabled")
            self:RefreshMeshUI()
        end)
    end

    local PushRawPayload

    -- Chunked send of one category. Returns a packet/target count, or nil
    -- when nothing went out - callers use that to decide whether to announce
    -- the category in PUSH_DONE. executeCalc and raidProfiles take their own
    -- routes; everything else is a plain key copy out of RC.db.
    -- targetFilter appends "~CLASS:x" or "~CHAR:x" to the command, which the
    -- receiver checks against itself before buffering anything.
    function MS:Push(categoryId, targetFilter, targetMember, silent, historyDelta)
        if not _mss.cfg or not RC.db then return nil end
        if not _mss.isEnabled then
            RC:Print(RCL["Mesh: Not enabled."]); return nil
        end

        if categoryId == "executeCalc" then
            local ec = RC.executeCalculator
            if not ec then
                RC:Print(RCL["Mesh: No ML Predictions data available."])
                return nil
            end
            local esPayload = {
                executeThreshold        = ec.executeThreshold,
                testModeEnabled         = ec.testMode and ec.testMode.enabled,
                mode                    = ec.mode,
                collectData             = ec.collectData,
                classicGlobalMultiplier = ec.classicMultipliers and ec.classicMultipliers.global,
                classicBossMultipliers  = ec.classicMultipliers and ec.classicMultipliers.perBoss,
                mlConfig                = ec.mlConfig,
                ewmaEnabled             = ec.ewma and ec.ewma.enabled,
                ewmaAlpha               = ec.ewma and ec.ewma.alpha,
                dataCollection          = ec.dataCollection,
                uiSettings              = ec.uiSettings,
            }
            -- Fight history has three shipping modes: a delta from the
            -- watermark the peer advertised in its HELLO (historyDelta),
            -- a full copy when no watermark is known, or a self-driven delta
            -- from our own last-sent watermark. All three restamp
            -- MS._histWatermark so the next send is a delta.
            if _mss.charCfg.syncFightHistory and ec.fightHistory
                    and ec.fightHistory.data and next(ec.fightHistory.data) then
                local histHash = HashFightHistory(ec.fightHistory.data)
                local histKey  = "executeCalc_history"
                if type(historyDelta) == "table" and historyDelta.fromWm then
                    local fromWm = historyDelta.fromWm
                    local delta, count = {}, 0
                    for bossKey, fights in pairs(ec.fightHistory.data) do
                        for _, f in ipairs(fights) do
                            if (f.timestamp or 0) > fromWm then
                                if not delta[bossKey] then delta[bossKey] = {} end
                                delta[bossKey][#delta[bossKey] + 1] = f
                                count = count + 1
                            end
                        end
                    end
                    if count > 0 then
                        esPayload.fightHistory = {
                            data           = delta,
                            maxHistorySize = ec.fightHistory.maxHistorySize or 500,
                        }
                    end
                    _lastBroadcastHash[histKey] = histHash
                    MS._histWatermark = HistoryMaxTimestamp(ec.fightHistory.data)
                elseif not historyDelta then
                    esPayload.fightHistory = {
                        data           = ec.fightHistory.data,
                        maxHistorySize = ec.fightHistory.maxHistorySize or 500,
                    }
                    _lastBroadcastHash[histKey] = histHash
                    MS._histWatermark = HistoryMaxTimestamp(ec.fightHistory.data)
                elseif histHash ~= (_lastBroadcastHash[histKey] or "") then
                    local histData = nil
                    local wm = MS._histWatermark or 0
                    if wm > 0 then
                        local delta, count = {}, 0
                        for bossKey, fights in pairs(ec.fightHistory.data) do
                            for _, f in ipairs(fights) do
                                if (f.timestamp or 0) > wm then
                                    if not delta[bossKey] then delta[bossKey] = {} end
                                    delta[bossKey][#delta[bossKey] + 1] = f
                                    count = count + 1
                                end
                            end
                        end
                        if count > 0 then histData = delta end
                    else
                        histData = ec.fightHistory.data
                    end
                    if histData then
                        esPayload.fightHistory = {
                            data           = histData,
                            maxHistorySize = ec.fightHistory.maxHistorySize or 500,
                        }
                    end
                    _lastBroadcastHash[histKey] = histHash
                    MS._histWatermark = HistoryMaxTimestamp(ec.fightHistory.data)
                end
            end
            -- Per-setting exclusions apply here exactly as in
            -- BuildCategoryPayload (substituted copies, never in place:
            -- mlConfig/uiSettings alias the live calculator tables).
            local ecPayload = ApplyPayloadStrips("executeCalc", { executeSettings = esPayload })
            if not ecPayload then
                if not silent then
                    RC:Print(RCL["Mesh: Everything in ML Predictions & TTK is excluded in Sync Rules."])
                end
                return nil
            end
            local from         = GetMyLabel()
            local msgId        = NextMsgId()
            local token        = GetToken()
            local cmd          = "PUSH_executeCalc"
            if targetFilter and targetFilter.type and targetFilter.value and targetFilter.value ~= "" then
                cmd = cmd .. "~" .. targetFilter.type .. ":" .. targetFilter.value
            end
            local count = 0
            if targetMember then
                local target = NormalizeName(targetMember.name)
                if target then
                    local msgs = ChunkForTarget(ecPayload, from, msgId, token, cmd, target)
                    if not msgs then RC:Print(RCL["Mesh: ML Predictions data too large to send."]); return nil end
                    EnqueueMessages(msgs, target); count = 1
                end
            else
                local msgs = ChunkData(Serialize(ecPayload), from, msgId, token, cmd)
                if not msgs then RC:Print(RCL["Mesh: ML Predictions data too large to send."]); return nil end
                count = BroadcastToAllMembers(msgs)
            end
            if not silent and count and count > 0 then
                RC:DebugPrint("MeshSync: sent executeCalc to " .. count .. " account(s)", "meshsync")
                -- Wire form is the category ID, never the label: labels are
                -- localized and renameable, and a receiver on another locale
                -- read every one as "did NOT fully arrive". The receiver
                -- still accepts labels from older peers.
                if targetMember then
                    local t = NormalizeName(targetMember.name)
                    if t then MS:Broadcast(CMD_PUSH_DONE, "executeCalc", t) end
                else
                    -- sameFactionOnly: chunked pushes only travel by
                    -- whisper, so cross-faction yell listeners can never
                    -- receive the data this verifies - yelling PUSH_DONE
                    -- and BATCH_SIZE at them only burns chat throttle.
                    MS:Broadcast(CMD_PUSH_DONE, "executeCalc", nil, true)
                end
            end
            _lastBroadcastHash["executeCalc"] = GetCategoryHash("executeCalc")
            return count > 0 and count or nil
        end

        -- One message set per raid key, each marked ~PARTIAL so the receiver
        -- merges instead of replacing. The whole raidProfiles table would
        -- blow the 999 chunk ceiling, and one lost chunk would then cost
        -- every raid rather than one.
        if categoryId == "raidProfiles" and RC.db.raidProfiles and not targetFilter then
            local sent = 0
            local totalChunks = 0
            for _, raidKey in ipairs(KNOWN_RAID_KEYS) do
                if RC.db.raidProfiles[raidKey] then
                    local rd = _mss.charCfg.syncRaidGear and RC.db.raidProfiles[raidKey]
                               or StripGearFromRaid(RC.db.raidProfiles[raidKey])
                    local partial = { raidProfiles = { [raidKey] = rd } }
                    for _, k in ipairs({"polarityMode","frostBlastConfig"}) do
                        if RC.db[k] ~= nil then partial[k] = RC.db[k] end
                    end
                    partial.raidRoute = SlimRouteCfg()
                    local nChunks = PushRawPayload("raidProfiles~PARTIAL", partial, targetMember, nil, raidKey)
                    totalChunks = totalChunks + (nChunks or 0)
                    local raidData   = RC.db.raidProfiles[raidKey]
                    if raidData.profiles then
                        for pn, pd in pairs(raidData.profiles) do
                            if pd.bosses then
                                for bossName, bossData in pairs(pd.bosses) do
                                    _lastBroadcastHash["_boss_"..raidKey..":"..pn..":"..bossName] = QuickHash(bossData)
                                end
                            end
                            if type(pd.route) == "table" then
                                _lastBroadcastHash["_route_"..raidKey..":"..pn] = QuickHash(pd.route)
                            end
                        end
                    end
                    local metaData = {}
                    if raidData.profiles then
                        for pn, pd in pairs(raidData.profiles) do
                            metaData[pn] = { enabled = pd.enabled, trash = pd.trash }
                        end
                    end
                    _lastBroadcastHash["_meta_"..raidKey] = QuickHash(metaData)
                    _lastBroadcastHash["_routeCfg"] = QuickHash(SlimRouteCfg() or {})
                    sent = sent + 1
                end
            end
            _lastBroadcastHash[categoryId] = GetCategoryHash(categoryId)
            if not silent and sent > 0 then
                if totalChunks >= 120 then
                    if targetMember then
                        local t = NormalizeName(targetMember.name)
                        if t then MS:Broadcast(CMD_BATCH_SIZE, tostring(totalChunks), t) end
                    else
                        MS:Broadcast(CMD_BATCH_SIZE, tostring(totalChunks), nil, true)
                    end
                end
                if targetMember then
                    local t = NormalizeName(targetMember.name)
                    if t then MS:Broadcast(CMD_PUSH_DONE, "raidProfiles", t) end
                else
                    MS:Broadcast(CMD_PUSH_DONE, "raidProfiles", nil, true)
                end
            end
            return sent > 0 and sent or nil
        end

        local catDef = nil
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            if cat.id == categoryId then catDef = cat; break end
        end
        if not catDef then return nil end

        -- payload holds live references into RC.db, not copies. Only the
        -- payload table itself may be mutated: ApplyPayloadStrips clears
        -- top-level keys and substitutes stripped COPIES for nested ones,
        -- because editing in place would delete the player's real settings.
        local payload, perr = BuildCategoryPayload(categoryId)
        if not payload then
            if perr == "stripped" then
                if not silent then
                    RC:Print(RCL["Mesh: Everything in "] .. catDef.label
                        .. RCL[" is excluded by its include options in Sync Rules."])
                end
            else
                -- silent-gated like the branch above: the login sync calls
                -- Push for every ticked category, and a ticked-but-empty
                -- one would otherwise print on every peer HELLO.
                if not silent then
                    RC:Print(RCL["Mesh: No saved data for: "] .. catDef.label)
                end
            end
            return nil
        end

        local from  = GetMyLabel()
        local msgId = NextMsgId()
        local token = GetToken()
        local cmd   = "PUSH_" .. categoryId
        if targetFilter and targetFilter.type and targetFilter.value and targetFilter.value ~= "" then
            cmd = cmd .. "~" .. targetFilter.type .. ":" .. targetFilter.value
        end

        local filterNote = (targetFilter and targetFilter.value and targetFilter.value ~= "")
            and (" \226\134\146 " .. targetFilter.value) or ""

        local nSent = 0
        if targetMember then
            local target = NormalizeName(targetMember.name)
            if target then
                local msgs = ChunkForTarget(payload, from, msgId, token, cmd, target)
                if not msgs then RC:Print(RCL["Mesh: Data too large to send for "] .. catDef.label); return nil end
                EnqueueMessages(msgs, target)
                nSent = #msgs
                if not silent then
                    local label = targetMember.label or targetMember.name
                    RC:DebugPrint("MeshSync: sent " .. catDef.label .. " to " .. label .. " (" .. #msgs .. " pkts)", "meshsync")
                    LogActivity("Sending " .. catDef.label .. filterNote .. " to " .. label .. " (" .. #msgs .. " pkts)")
                    MS:Broadcast(CMD_PUSH_DONE, categoryId, target)
                end
            end
        else
            local msgs = ChunkData(Serialize(payload), from, msgId, token, cmd)
            if not msgs then
                RC:Print(RCL["Mesh: Data too large to send for "] .. catDef.label)
                return nil
            end
            nSent = #msgs
            local targetCount = BroadcastToAllMembers(msgs)
            if targetCount == 0 then
                if not silent then
                    RC:Print(RCL["Mesh: No known accounts to send to. Make sure the other account is online and has the mesh enabled with the same password."])
                end
                return nil
            end
            if not silent then
                RC:Print(RCL["Mesh: Sent "] .. catDef.label .. filterNote .. RCL[" to "] .. targetCount .. RCL[" account(s)"])
                LogActivity("Sending " .. catDef.label .. filterNote .. " to " .. targetCount .. " account(s)")
                MS:Broadcast(CMD_PUSH_DONE, categoryId, nil, true)
            end
        end
        _lastBroadcastHash[categoryId] = GetCategoryHash(categoryId)
        return nSent
    end

    function MS:Request(targetMember, categoryId)
        if not _mss.isEnabled then
            RC:Print(RCL["Mesh: Not enabled."]); return
        end
        local catLabel = categoryId
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            if cat.id == categoryId then catLabel = cat.label; break end
        end
        if targetMember then
            local target = NormalizeName(targetMember.name)
            if target then
                self:Broadcast("REQ_" .. categoryId, "", target)
                LogActivity("Requested " .. catLabel .. " from " .. (targetMember.label or targetMember.name))
            end
        else
            -- sameFactionOnly: a REQ reply is a chunked whisper, which a
            -- cross-faction yell listener can never send back.
            self:Broadcast("REQ_" .. categoryId, "", nil, true)
            LogActivity("Requested " .. catLabel .. " from all members")
        end
    end

    local CATEGORY_TO_PANEL = {
        general           = "general_behavior",
        colors            = "font_settings",
        fonts             = "font_settings",
        motion            = "font_settings",
        sidebar           = "general_behavior",
        minimap           = "general_behavior",
        statsBar          = "stats_bar",
        ttkDisplay        = "ttk_display",
        buffAlert         = "general_behavior",
        nameplateAuras    = "nameplate_auras",
        customReminders   = "custom_reminders",
        battleShout       = "battle_shout",
        battleShoutTracker= "battle_shout",
        boonReminder      = "boon_reminder",
        fastWeapon        = "equipment_reminder",
        specDetection     = "spec_detection",
        executeCalc       = "execute",
        bars              = "consumables_bar",
        trinketSwap       = "trinkets",
        gearManager       = "gear_manager",
        gearButtons       = "gear_manager",
        gearSets          = "gear_manager",
        hotswap           = "hotswap",
        consumablesHelper = "consumables_bar",
        consumablesChecker= "consumables_checker",
        raidProfiles      = "raids",
        bossNotes         = "boss_notes",
        -- These five were missing, so inbound data for them never
        -- refreshed the open panel (NavigateAndRefresh bailed on nil).
        abilityReminders  = "reminder_settings",
        smartMacros       = "smart_macros",
        repairReminder    = "repair_reminder",
        worldBuffs        = "world_buffs",
        raidBuffTracker   = "raid_buff_tracker",
        bossDebuffTracker = "boss_debuff_tracker",
    }

    function MS:RefreshCurrentPanel()
        if not RC.SidebarState then return end
        local panelId = RC.SidebarState.currentPanel
        if not panelId or not RC.MenuStructure then return end
        local function FindItem(items)
            for _, item in ipairs(items) do
                if item.id == panelId then return item end
                if item.children then
                    local found = FindItem(item.children)
                    if found then return found end
                end
            end
        end
        local menuItem = FindItem(RC.MenuStructure)
        if not menuItem then return end
        local frame = RC.sidebarConfigFrame
        if not frame or not frame.compatFrame then return end

        if menuItem.raidKey then
            local savedState = frame.compatFrame and frame.compatFrame.configState
            RC:ClearSidebarContent(frame)
            frame.compatFrame.configState = savedState or {}
            frame.compatFrame.configState.selectedRaid = menuItem.raidKey
            RC:OpenRaidBossPage(frame.compatFrame, menuItem.raidKey)
            RC:UpdateSidebarScrollbar(frame)
        elseif menuItem.panel and RC[menuItem.panel] then
            RC:ClearSidebarContent(frame)
            RC[menuItem.panel](RC, frame.compatFrame)
            RC.SidebarState.currentPanel = panelId
            RC:UpdateSidebarScrollbar(frame)
        end
    end

    local PANEL_TO_RAID_KEY = {
        mc   = "Molten Core",
        bwl  = "Blackwing Lair",
        aq40 = "Temple of Ahn'Qiraj",
        naxx = "Naxxramas",
    }

    function MS:NavigateAndRefresh(categoryId)
        if categoryId == "raidProfiles" then
            if _refreshDebounce then _refreshDebounce:Cancel(); _refreshDebounce = nil end
            _refreshDebounce = C_Timer.After(0.5, function()
                _refreshDebounce = nil
                if not RC.SidebarState then return end
                local frame = RC.sidebarConfigFrame
                if not frame or not frame.compatFrame then return end
                local cs = frame.compatFrame.configState
                if not cs then return end
                local raidKey = PANEL_TO_RAID_KEY[RC.SidebarState.currentPanel or ""]
                if not raidKey then return end

                local lastInteract = RC._sidebarLastInteraction or 0
                if (GetTime() - lastInteract) < 3 then return end

                local rd = RC.db and RC.db.raidProfiles and RC.db.raidProfiles[raidKey]
                local an = rd and (rd.activeProfile or "Default")
                local pd = rd and rd.profiles and rd.profiles[an]
                if not (pd and pd.bosses) then return end

                if cs.selectedEncounter and cs.selectedEncounterType == "boss"
                        and pd.bosses[cs.selectedEncounter] then
                    if RC.ShowInlineAbilityConfig then
                        RC:ShowInlineAbilityConfig(frame.compatFrame, raidKey,
                            cs.selectedEncounter, "boss", nil, true)
                    end
                else
                    local savedState = frame.compatFrame.configState
                    RC:ClearSidebarContent(frame)
                    frame.compatFrame.configState = savedState or {}
                    frame.compatFrame.configState.selectedRaid = raidKey
                    RC:OpenRaidBossPage(frame.compatFrame, raidKey)
                    RC:UpdateSidebarScrollbar(frame)
                end
            end)
            return
        end

        local targetPanel = CATEGORY_TO_PANEL[categoryId]
        C_Timer.After(0, function()
            if not RC.SidebarState then return end

            if categoryId == "fonts" and RC.UpdateAllFonts then
                RC:UpdateAllFonts()
            end

            if categoryId == "consumablesHelper" or categoryId == "bars" then
                local chDb = RC.db and RC.db.consumablesHelper
                local ch   = RC.consumablesHelper
                if ch and ch.frame and chDb then
                    ch.frame:ClearAllPoints()
                    ch.frame:SetPoint(chDb.anchorPoint or "TOPRIGHT", UIParent,
                        chDb.anchorPoint or "TOPRIGHT", chDb.xOffset or -10, chDb.yOffset or -200)
                end
                local wbDb = RC.db and RC.db.weaponsBar
                local wb   = RC.weaponsBar
                if wb and wb.frame and wbDb then
                    wb.frame:ClearAllPoints()
                    wb.frame:SetPoint(wbDb.anchorPoint or "TOPLEFT", UIParent,
                        wbDb.anchorPoint or "TOPLEFT", wbDb.xOffset or 0, wbDb.yOffset or 0)
                end
                local pbDb = RC.db and RC.db.potionsBar
                local pb   = RC.potionsBar
                if pb and pb.frame and pbDb then
                    pb.frame:ClearAllPoints()
                    pb.frame:SetPoint(pbDb.anchorPoint or "TOPLEFT", UIParent,
                        pbDb.anchorPoint or "TOPLEFT", pbDb.xOffset or 0, pbDb.yOffset or 0)
                end
                local tbDb = RC.db and RC.db.trinketBar
                local tb   = RC.trinketBar
                if tb and tb.frame and tbDb then
                    tb.frame:ClearAllPoints()
                    tb.frame:SetPoint(tbDb.anchorPoint or "TOPRIGHT", UIParent,
                        tbDb.anchorPoint or "TOPRIGHT", tbDb.xOffset or -10, tbDb.yOffset or -400)
                end
                if RC.UpdateConsumablesButtons then RC:UpdateConsumablesButtons() end
            end

            if categoryId == "bossNotes" then
                if targetPanel then RC.SidebarState.currentPanel = targetPanel end
                MS:RefreshCurrentPanel()
                return
            end

            -- Refresh only when the receiving panel is the one on screen.
            -- (An activeEditPanels table used to sit here with two branches
            -- that did the identical thing - collapsed.)
            if not targetPanel then return end
            if RC.SidebarState.currentPanel ~= targetPanel then return end

            local frame = RC.sidebarConfigFrame
            if not frame or not frame.compatFrame then return end
            local cf = frame.compatFrame

            if (categoryId == "gearSets" or categoryId == "gearManager" or categoryId == "gearButtons")
                    and RC.ShowSidebarGearManagerConfig then
                if categoryId == "gearButtons" and RC.GearManager then
                    RC.GearManager:RestoreButtonsFromProfile()
                end
                if categoryId == "gearManager" and RC.GearManager then
                    local GM2 = RC.GearManager
                    local gdb = RC.db and RC.db.gearManager
                    if GM2.settings and gdb then
                        if gdb.enabled ~= nil then GM2.enabled = gdb.enabled end
                        if gdb.settings then
                            for key, value in pairs(gdb.settings) do
                                if GM2.settings[key] ~= nil then
                                    GM2.settings[key] = value
                                end
                            end
                        end
                        local wantLocked = GM2.settings.buttonsLocked and true or false
                        if GM2.locked ~= wantLocked then
                            if wantLocked and GM2.Lock then
                                GM2:Lock()
                            elseif not wantLocked and GM2.Unlock then
                                GM2:Unlock()
                            end
                        end
                        if GM2.buttons and GM2.UpdateButtonIcon then
                            for slot, btn in pairs(GM2.buttons) do
                                if btn and btn:IsShown() then
                                    GM2:UpdateButtonIcon(slot)
                                end
                            end
                        end
                    end
                end
                if cf.gearEditState and cf.gearEditState.setName
                        and RC.GearManager
                        and RC.GearManager.sets
                        and RC.GearManager.sets[cf.gearEditState.setName]
                        and RC.ShowSidebarGearSetEditor then
                    RC:ShowSidebarGearSetEditor(cf)
                else
                    RC:ShowSidebarGearManagerConfig(cf, true)
                end
            elseif categoryId == "customReminders"
                    and RC.ShowSidebarCustomReminders then
                RC:ShowSidebarCustomReminders(cf)
            elseif categoryId == "abilityReminders"
                    and RC.ShowSidebarReminderSettings then
                RC:ShowSidebarReminderSettings(cf)
            elseif (categoryId == "consumablesHelper" or categoryId == "bars")
                    and RC.ShowSidebarConsumablesHelperConfig then
                RC:ShowSidebarConsumablesHelperConfig(cf)
            elseif categoryId == "trinketSwap"
                    and RC.ShowSidebarTrinketSwapConfig then
                RC:ShowSidebarTrinketSwapConfig(cf)
            elseif categoryId == "hotswap"
                    and RC.ShowSidebarHotswapMacros then
                RC:ShowSidebarHotswapMacros(cf)
            else
                MS:RefreshCurrentPanel()
            end
        end)
    end

    local function DeepMerge(target, source)
        if type(source) ~= "table" or type(target) ~= "table" then return end
        if #source > 0 then
            for k, v in pairs(source) do target[k] = RC.DeepCopy(v) end
            return
        end
        for k, v in pairs(source) do
            if type(v) == "table" and type(target[k]) == "table" then
                DeepMerge(target[k], v)
            else
                target[k] = RC.DeepCopy(v)
            end
        end
    end

    -- Field-wise merge of an inbound settings table into the live one,
    -- mirroring the picker's enumeration depth: a field that is itself a
    -- (non-opaque) settings table merges one level further, everything else
    -- - scalars, lists, opaque containers - is replaced at that field. So an
    -- excluded "trinketBar.locked" leaves the receiver's own value standing
    -- while "trinketBar.hiddenTrinkets" (opaque) still replaces whole.
    local function IsStringKeyedTable(v)
        if type(v) ~= "table" then return false end
        local any = false
        for k in pairs(v) do
            if type(k) ~= "string" then return false end
            any = true
        end
        return any
    end
    local function MergeSettingsTable(dst, src, path, depth)
        depth = depth or 1
        for k, v in pairs(src) do
            local sub = path .. "." .. tostring(k)
            if depth < 2 and type(v) == "table" and type(dst[k]) == "table"
                    and IsStringKeyedTable(v) and IsStringKeyedTable(dst[k])
                    and not RC:IsOpaqueSettingPath(sub) then
                MergeSettingsTable(dst[k], v, sub, depth + 1)
            else
                dst[k] = RC.DeepCopy(v)
            end
        end
    end

    -- Single authority on Receive rules, for the wire path and the
    -- same-account snapshot path alike. Returns true only when data was
    -- actually written; ApplySameAccountSync keys "snapshot consumed" off
    -- that return, so the false-on-blocked case must stay.
    -- Per key: merge where a merge is meaningful (gear sets, reminders,
    -- fight history, raid profiles), overwrite otherwise. Nothing here ever
    -- deletes - removals travel as their own commands.
    function MS:ApplyInbound(categoryId, payload, from, isPartial)
        if not RC.db then return end
        if type(payload) ~= "table" then return end

        local catDef = nil
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            if cat.id == categoryId then catDef = cat; break end
        end
        if not catDef then
            RC:DebugPrint("MeshSync: unknown category " .. categoryId, "meshsync"); return
        end

        local rcv = _mss.charCfg and _mss.charCfg.recvCategories
        if rcv and rcv[categoryId] == false then
            LogActivity("Ignored " .. (catDef.label or categoryId) .. " from "
                .. tostring(from) .. " (Receive is off on this character)")
            RC:DebugPrint("MeshSync: Receive off for " .. categoryId
                .. " - ignored inbound from " .. tostring(from), "meshsync")
            return false
        end

        if not RC.DeepCopy then return end

        local recvSkip = StripKeySet(categoryId, true)
        -- Nested exclusions ("trinketSwap.enabled") hold on receive too.
        -- Shallow-copied: same-account passes its stored snapshot here.
        if HasNestedSkips(recvSkip) then
            local stripped = {}
            for k, v in pairs(payload) do
                stripped[k] = StripNestedCopy(v, k, recvSkip)
            end
            payload = stripped
        end

        for _, key in ipairs(catDef.keys) do
            if payload[key] ~= nil and not (recvSkip and recvSkip[key]) then
                if key == "executeSettings" and type(payload[key]) == "table" then
                    local src = payload[key]
                    local ec  = RC.executeCalculator
                    if ec then
                        if src.executeThreshold        ~= nil then ec.executeThreshold = src.executeThreshold end
                        if src.collectData             ~= nil then ec.collectData = src.collectData end
                        if src.testModeEnabled         ~= nil then
                            if not ec.testMode then ec.testMode = { enabled = false } end
                            ec.testMode.enabled = src.testModeEnabled
                        end
                        if src.mlConfig ~= nil then ec.mlConfig = RC.DeepCopy(src.mlConfig) end
                        if src.ewmaEnabled ~= nil then
                            if not ec.ewma then ec.ewma = {} end
                            ec.ewma.enabled = src.ewmaEnabled
                        end
                        if src.ewmaAlpha ~= nil then
                            if not ec.ewma then ec.ewma = {} end
                            ec.ewma.alpha = src.ewmaAlpha
                        end
                        if src.classicGlobalMultiplier ~= nil then
                            if not ec.classicMultipliers then ec.classicMultipliers = { global = 1, perBoss = {} } end
                            ec.classicMultipliers.global = src.classicGlobalMultiplier
                        end
                        if src.classicBossMultipliers ~= nil then
                            if not ec.classicMultipliers then ec.classicMultipliers = { global = 1, perBoss = {} } end
                            ec.classicMultipliers.perBoss = RC.DeepCopy(src.classicBossMultipliers)
                        end
                        if src.dataCollection ~= nil then ec.dataCollection = RC.DeepCopy(src.dataCollection) end
                        if src.uiSettings     ~= nil then ec.uiSettings     = RC.DeepCopy(src.uiSettings)     end
                    end
                    local dst = RC.db[key]
                    if type(dst) == "table" then
                        for k, v in pairs(src) do
                            if k ~= "fightHistory" and k ~= "mode" then dst[k] = RC.DeepCopy(v) end
                        end
                    end
                    local srcHist = src.fightHistory
                    if srcHist and srcHist.data and next(srcHist.data) then
                        if ec then
                            if not ec.fightHistory then
                                ec.fightHistory = { maxHistorySize = srcHist.maxHistorySize or 500, data = {} }
                            end
                            local fhData  = ec.fightHistory.data
                            local maxSize = ec.fightHistory.maxHistorySize or 500
                            for bossKey, fights in pairs(srcHist.data) do
                                if not fhData[bossKey] then fhData[bossKey] = {} end
                                local existing = fhData[bossKey]
                                -- Fights are deduped on timestamp plus fight
                                -- length bucketed to 5s: the same pull timed
                                -- on two clients rarely agrees to the second.
                                local seen = {}
                                for _, f in ipairs(existing) do
                                    local fp = tostring(f.timestamp or "X") .. "|"
                                        .. tostring(math_floor(((f.totalFightTime or 0) / 5) + 0.5) * 5)
                                    seen[fp] = f
                                end
                                for _, f in ipairs(fights) do
                                    local fp = tostring(f.timestamp or "X") .. "|"
                                        .. tostring(math_floor(((f.totalFightTime or 0) / 5) + 0.5) * 5)
                                    local have = seen[fp]
                                    if not have then
                                        local copy = RC.DeepCopy(f)
                                        table.insert(existing, 1, copy)
                                        seen[fp] = copy
                                    elseif type(have) == "table" and have.class == nil
                                            and type(f.class) == "string" and f.class ~= "" then
                                        -- the same kill, and the sender knows the
                                        -- class it was played on
                                        have.class = f.class
                                    end
                                end
                                table.sort(existing, function(a, b)
                                    local ta, tb = a.timestamp or 0, b.timestamp or 0
                                    if ta ~= tb then return ta > tb end
                                    return (a.totalFightTime or 0) > (b.totalFightTime or 0)
                                end)
                                while #existing > maxSize do table.remove(existing) end
                            end
                            _lastBroadcastHash["executeCalc_history"] = HashFightHistory(ec.fightHistory.data)
                            MS._histWatermark = HistoryMaxTimestamp(ec.fightHistory.data)
                        end
                    end
                elseif key == "raidProfiles"
                        and type(payload[key]) == "table" then
                    local incomingRaidProfiles = RC.DeepCopy(payload[key])
                    -- Receive side of the boss-config gear row: with it
                    -- off, a sender that ships gear must not overwrite
                    -- this character's own. Independent of syncRaidGear,
                    -- which is the Send side of the same row.
                    if not MS:IsKeyReceived("raidProfiles", "raidProfiles.gear") then
                        for rk, rd in pairs(incomingRaidProfiles) do
                            if type(rd) == "table" and rd.profiles then
                                incomingRaidProfiles[rk] = StripGearFromRaid(rd)
                            end
                        end
                    end
                    for _, rd in pairs(incomingRaidProfiles) do
                        if type(rd) == "table" and rd.profiles then
                            for _, pd in pairs(rd.profiles) do
                                if pd.bosses then
                                    for _, bd in pairs(pd.bosses) do
                                        if type(bd) == "table" and bd.abilities then
                                            local gs = bd.abilities.gearswap
                                            if type(gs) == "table" then
                                                if gs.gearSet       == "" then gs.gearSet       = nil end
                                                if gs.postCombatSet == "" then gs.postCombatSet = nil end
                                                if gs.itemRackSet   == "" then gs.itemRackSet   = nil end
                                            end
                                            for _, ac in pairs(bd.abilities) do
                                                if type(ac) == "table" then
                                                    if ac.gearSet       == "" then ac.gearSet       = nil end
                                                    if ac.postCombatSet == "" then ac.postCombatSet = nil end
                                                    if ac.itemRackSet   == "" then ac.itemRackSet   = nil end
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if RC.db[key] == nil then RC.db[key] = {} end
                    local function RaidProfileScore(pd)
                        if type(pd) ~= "table" then return -1 end
                        local s = 0
                        if type(pd.bosses) == "table" then
                            for _ in pairs(pd.bosses) do s = s + 1 end
                        end
                        if pd.enabled then s = s + 100 end
                        return s
                    end
                    -- Raid deletions are deliberately not honoured over the
                    -- wire: a peer that lost or reset its own data would
                    -- otherwise wipe yours on the next sync.
                    for rk, raidVal in pairs(incomingRaidProfiles) do
                        if type(raidVal) == "table" and raidVal.__deleted then
                            RC:DebugPrint("Mesh: ignored a raid-deletion sync for '"
                                .. tostring(rk) .. "'", "meshsync")
                        else
                            if RC.db[key][rk] == nil then RC.db[key][rk] = {} end
                            local target = RC.db[key][rk]
                            for k, v in pairs(raidVal) do
                                if k == "activeProfile" then
                                elseif k == "profiles" and type(v) == "table"
                                        and type(target.profiles) == "table" then
                                    for profileName, profileData in pairs(v) do
                                        if not target.profiles[profileName] then
                                            target.profiles[profileName] = RC.DeepCopy(profileData)
                                        else
                                            local tProf = target.profiles[profileName]
                                            for pk, pv in pairs(profileData) do
                                                if pk == "route" then
                                                    tProf.route = RC.DeepCopy(pv)
                                                elseif pk == "bosses" and type(pv) == "table" then
                                                    if not tProf.bosses then tProf.bosses = {} end
                                                    for bossName, srcBoss in pairs(pv) do
                                                        if not tProf.bosses[bossName] then
                                                            tProf.bosses[bossName] = RC.DeepCopy(srcBoss)
                                                        else
                                                            local tBoss = tProf.bosses[bossName]
                                                            for bk, bv in pairs(srcBoss) do
                                                                if bk == "forceEquip" then
                                                                    tBoss.forceEquip = RC.DeepCopy(bv)
                                                                elseif bk == "abilities"
                                                                        and type(bv) == "table" then
                                                                    if not tBoss.abilities then
                                                                        tBoss.abilities = {}
                                                                    end
                                                                    for ak, av in pairs(bv) do
                                                                        if ak == "gearswap" then
                                                                            tBoss.abilities.gearswap
                                                                                = RC.DeepCopy(av)
                                                                        elseif type(av) == "table"
                                                                                and type(tBoss.abilities[ak]) == "table" then
                                                                            DeepMerge(tBoss.abilities[ak], av)
                                                                        else
                                                                            tBoss.abilities[ak] = RC.DeepCopy(av)
                                                                        end
                                                                    end
                                                                elseif type(bv) == "table"
                                                                        and type(tBoss[bk]) == "table" then
                                                                    DeepMerge(tBoss[bk], bv)
                                                                else
                                                                    tBoss[bk] = RC.DeepCopy(bv)
                                                                end
                                                            end
                                                        end
                                                    end
                                                elseif type(pv) == "table"
                                                        and type(tProf[pk]) == "table" then
                                                    DeepMerge(tProf[pk], pv)
                                                else
                                                    tProf[pk] = RC.DeepCopy(pv)
                                                end
                                            end
                                        end
                                    end
                                elseif type(v) == "table" and type(target[k]) == "table" then
                                    DeepMerge(target[k], v)
                                else
                                    target[k] = RC.DeepCopy(v)
                                end
                            end

                            -- A merge can leave activeProfile pointing at an
                            -- empty profile. Score by boss count and repoint
                            -- rather than leave the raid looking unconfigured.
                            if type(target.profiles) == "table" then
                                local curName = target.activeProfile
                                local cur = curName and target.profiles[curName]
                                if RaidProfileScore(cur) <= 0 then
                                    local bestName, bestScore
                                    for pName, pd in pairs(target.profiles) do
                                        local sc = RaidProfileScore(pd)
                                        if not bestScore or sc > bestScore then
                                            bestName, bestScore = pName, sc
                                        end
                                    end
                                    local senderActive = raidVal.activeProfile
                                    if senderActive and RaidProfileScore(target.profiles[senderActive]) > 0 then
                                        bestName = senderActive
                                    end
                                    if bestName and bestName ~= curName
                                            and RaidProfileScore(target.profiles[bestName]) > 0 then
                                        target.activeProfile = bestName
                                        RC:DebugPrint("Mesh: repointed " .. tostring(rk)
                                            .. " active profile to '" .. bestName .. "' after merge", "meshsync")
                                    end
                                end
                            end
                        end
                    end
                -- Gear sets merge by name and only ever add or update fields.
                -- A set the sender no longer has is left alone; deletions
                -- travel separately as PUSH_gearSetDeletes.
                elseif key == "gearSets" and type(payload[key]) == "table" then
                    if not RC.db[key] then RC.db[key] = {} end
                    for setName, setData in pairs(payload[key]) do
                        if RC.db[key][setName] == nil then
                            RC.db[key][setName] = RC.DeepCopy(setData)
                        else
                            local existing = RC.db[key][setName]
                            if setData.icon ~= nil then existing.icon = setData.icon end
                            if type(setData.equip) == "table" then
                                existing.equip = RC.DeepCopy(setData.equip)
                            end
                            if type(setData.textures) == "table" then
                                existing.textures = RC.DeepCopy(setData.textures)
                            end
                        end
                    end
                    if RC.GearManager then RC.GearManager.sets = RC.db[key] end

                elseif key == "trinketSwap" and type(payload[key]) == "table" then
                    if type(RC.db[key]) ~= "table" then RC.db[key] = {} end
                    local src, dst = payload[key], RC.db[key]
                    for k2, v2 in pairs(src) do
                        if k2 == "queues" and type(v2) == "table" then
                            if type(dst.queues) ~= "table" then dst.queues = {} end
                            for qk, qv in pairs(v2) do
                                dst.queues[qk] = RC.DeepCopy(qv)
                            end
                        elseif k2 == "configNames" and type(v2) == "table" then
                            if type(dst.configNames) ~= "table" then dst.configNames = {} end
                            for nk, nv in pairs(v2) do
                                dst.configNames[nk] = nv
                            end
                        else
                            dst[k2] = RC.DeepCopy(v2)
                        end
                    end

                elseif key == "gearButtons" and type(payload[key]) == "table" then
                    if not RC.db[key] then RC.db[key] = {} end
                    for slot, btnData in pairs(payload[key]) do
                        RC.db[key][slot] = RC.DeepCopy(btnData)
                    end

                elseif key == "gearButtonPositions" and type(payload[key]) == "table" then
                    if not RC.db[key] then RC.db[key] = {} end
                    for slot, posData in pairs(payload[key]) do
                        RC.db[key][slot] = RC.DeepCopy(posData)
                    end

                elseif key == "gearPinnedButtons" and type(payload[key]) == "table" then
                    if not RC.db[key] then RC.db[key] = {} end
                    for id, def in pairs(payload[key]) do
                        RC.db[key][id] = RC.DeepCopy(def)
                        if RC.GearManager and RC.GearManager.buttons
                                and RC.GearManager.buttons[id] then
                            RC.GearManager:UpdateButtonIcon(id)
                        end
                    end

                elseif key == "abilityOverrides" and type(payload[key]) == "table" then
                    if not RC.db[key] then RC.db[key] = {} end
                    for spellId, override in pairs(payload[key]) do
                        RC.db[key][spellId] = RC.DeepCopy(override)
                    end

                -- Reminders and smart macros are keyed by id and only added
                -- when the id is new, so an inbound copy cannot overwrite an
                -- edit made locally to the same entry.
                elseif key == "customReminders" and type(payload[key]) == "table" then
                    local src = payload[key]
                    if not RC.db[key] then
                        RC.db[key] = { reminders = {}, nextId = 1 }
                    end
                    local dst = RC.db[key]
                    local srcList = (type(src.reminders) == "table") and src.reminders or {}
                    local dstList = (type(dst.reminders) == "table") and dst.reminders or {}
                    local existingIds = {}
                    for _, r in ipairs(dstList) do existingIds[r.id or ""] = true end
                    for _, r in ipairs(srcList) do
                        if r.id and not existingIds[r.id] then
                            dstList[#dstList+1] = RC.DeepCopy(r)
                            existingIds[r.id] = true
                        end
                    end
                    dst.reminders = dstList
                    if src.nextId and (not dst.nextId or src.nextId > dst.nextId) then
                        dst.nextId = src.nextId
                    end

                elseif key == "smartMacros" and type(payload[key]) == "table" then
                    if type(RC.db.smartMacros) ~= "table" then RC.db.smartMacros = {} end
                    local dst = RC.db.smartMacros
                    local existingIds = {}
                    for _, m in ipairs(dst) do existingIds[m.id or ""] = true end
                    for _, m in ipairs(payload[key]) do
                        if m.id and not existingIds[m.id] then
                            dst[#dst+1] = RC.DeepCopy(m)
                            existingIds[m.id] = true
                        end
                    end

                elseif key == "bossNotes" and type(payload[key]) == "table" then
                    local src = payload[key]
                    if not RC.db.bossNotes then RC.db.bossNotes = {} end
                    local dst = RC.db.bossNotes
                    local function fillMap(name)
                        if type(src[name]) ~= "table" then return end
                        if type(dst[name]) ~= "table" then dst[name] = {} end
                        for k2, v2 in pairs(src[name]) do
                            local cur = dst[name][k2]
                            if (cur == nil or cur == "") and v2 ~= nil and v2 ~= "" then
                                dst[name][k2] = RC.DeepCopy(v2)
                            end
                        end
                    end
                    fillMap("notes")
                    fillMap("trashNotesByRaid")
                    fillMap("bossNoteAdded")
                    fillMap("trashNoteKills")
                    fillMap("trashNoteDur")
                    if type(src.trashNotesByPack) == "table" then
                        if type(dst.trashNotesByPack) ~= "table" then dst.trashNotesByPack = {} end
                        for rk2, packs in pairs(src.trashNotesByPack) do
                            if type(packs) == "table" then
                                if type(dst.trashNotesByPack[rk2]) ~= "table" then
                                    dst.trashNotesByPack[rk2] = {}
                                end
                                local dp = dst.trashNotesByPack[rk2]
                                for pk2, v2 in pairs(packs) do
                                    if (dp[pk2] == nil or dp[pk2] == "") and v2 ~= "" then
                                        dp[pk2] = v2
                                    end
                                end
                            end
                        end
                    end
                    if type(src.trashNotesList) == "table" then
                        if type(dst.trashNotesList) ~= "table" then dst.trashNotesList = {} end
                        if type(dst.trashNotesListMig) ~= "table" then dst.trashNotesListMig = {} end
                        for lk2, lst in pairs(src.trashNotesList) do
                            local cur = dst.trashNotesList[lk2]
                            if type(lst) == "table" and #lst > 0
                               and (type(cur) ~= "table" or #cur == 0) then
                                dst.trashNotesList[lk2] = RC.DeepCopy(lst)
                                dst.trashNotesListMig[lk2] = true
                            end
                        end
                    end
                    for k2, v2 in pairs(src) do
                        if type(v2) ~= "table" and dst[k2] ~= v2
                           and k2 ~= "profileIsolationMigrated"
                           and k2 ~= "profileIsolationRepaired"
                           and k2 ~= "profileIsolationRepaired2"
                           and k2 ~= "bossNotesSprayUndone" then
                            dst[k2] = v2
                        end
                    end

                elseif key == "smartMacrosNextId" then
                    local incoming = payload[key]
                    if type(incoming) == "number" then
                        if type(RC.db.smartMacrosNextId) ~= "number"
                                or incoming > RC.db.smartMacrosNextId then
                            RC.db.smartMacrosNextId = incoming
                        end
                    end

                elseif key == "raidRoute" and type(payload[key]) == "table"
                        and type(RC.db[key]) == "table" then
                    -- Senders ship a slimmed route config without .runtime;
                    -- a whole-table replace would drop this character's own.
                    -- Whether routes are ON, and where the tracker sits, are
                    -- this character's business: a raid member whose routes
                    -- are off must never switch yours off by syncing.
                    local PERSONAL = { runtime = true, enabled = true, offByDefaultDone = true,
                        trackerPos = true, trackerUnlocked = true, trackerW = true, trackerBand = true, trackerBandSwaps = true, uiTab = true }
                    local dst = RC.db[key]
                    for k2, v2 in pairs(payload[key]) do
                        if not PERSONAL[k2] then dst[k2] = RC.DeepCopy(v2) end
                    end

                else
                    -- Type guard on the generic overwrite: a peer running a
                    -- different addon version can send a key whose shape has
                    -- changed, and blindly storing it corrupts the profile.
                    local cur = RC.db[key]
                    if cur ~= nil and type(payload[key]) ~= type(cur) then
                        RC:DebugPrint("MeshSync: dropped '" .. tostring(key)
                            .. "' from " .. tostring(from) .. " (type "
                            .. type(payload[key]) .. ", expected "
                            .. type(cur) .. ")", "meshsync")
                    elseif type(cur) == "table" and type(payload[key]) == "table"
                            and not RC:IsOpaqueSettingPath(key) then
                        -- Settings tables merge field by field, to the same
                        -- depth the Sync Rules picker splits them: a field
                        -- the SENDER withheld (or this side refused) is
                        -- simply absent, and a whole-table replace would
                        -- turn "not synced" into "erased". Opaque keys
                        -- (lists, per-entry data) still replace whole so
                        -- removals travel.
                        MergeSettingsTable(cur, payload[key], key)
                    else
                        RC.db[key] = RC.DeepCopy(payload[key])
                    end
                end
            end
        end

        -- Flags the save as machine-driven: MarkCategoryDirty reads it and
        -- suppresses the "you changed X but are not sending it" hint, which
        -- is not true of an inbound apply. The echo back to the sender is
        -- stopped separately, by restamping _lastBroadcastHash below so the
        -- poll ticker sees no change.
        MS._applyingInbound = true
        if MS.MarkCategoryDirty then MS:MarkCategoryDirty(categoryId) end
        RC:SaveConfigurationToProfile()
        MS._applyingInbound = nil

        -- Push the received values into the live UI. Without this the data
        -- lands in the profile but nothing on screen moves until a reload,
        -- which is indistinguishable from "sync is not working". Each call
        -- is optional - a feature whose module is not loaded just skips.
        local REFRESH = {
            fastWeapon         = { RC, "UpdateFastWeaponReminder" },
            battleShout        = { RC, "UpdateBattleShoutReminder" },
            battleShoutTracker = { RC, "UpdateBattleShoutPartyTracker" },
            raidBuffTracker    = { RC, "RefreshRaidBuffTracker" },
            bossDebuffTracker  = { RC, "RefreshBossDebuffTracker" },
            boonReminder       = { RC, "UpdateBoonReminder" },
            repairReminder     = { RC, "CheckRepairDurability" },
            consumablesHelper  = { RC, "UpdateConsumablesHelperBackground",
                                       "UpdateConsumablesHelperLock",
                                       "UpdateConsumablesHelperNameLabels",
                                       "UpdateConsumablesHelperTitleVisibility" },
            consumablesChecker = { RC, "UpdateConsumablesCheckerDisplay" },
            bars               = { RC, "UpdatePotionsBarBackground",
                                       "UpdateWeaponsBarBackground",
                                       "UpdatePotionsBarTitleVisibility",
                                       "UpdatePotionsBarMouseoverFade",
                                       "UpdateWeaponsBarMouseoverFade",
                                       "UpdateTrinketBarButtonStates" },
            statsBar           = { RC.CharacterStats, "UpdateBarStats", "UpdatePanelStats" },
            buffAlert          = { RC.CharacterStats, "UpdateBuffPushoffAlertAppearance",
                                                       "RefreshAlertFrameColors" },
            ttkDisplay         = { RC, "UpdateTTKDisplayActive" },
            bossNotes          = { RC, "UpdateBossNotes" },
            colors             = { RC, "RefreshUIColors" },
            fonts              = { RC, "UpdateAllFonts", "RefreshUIColors" },
            nameplateAuras     = nil,  -- handled by its own block below
        }
        local spec = REFRESH[categoryId]
        if spec then
            local owner = spec[1]
            if owner then
                for i = 2, #spec do
                    local fn = owner[spec[i]]
                    if type(fn) == "function" then pcall(fn, owner) end
                end
            end
        end

        if categoryId == "gearButtons" and RC.GearManager and RC.GearManager.RestoreButtonsFromProfile then
            RC.GearManager:RestoreButtonsFromProfile()
        end
        if categoryId == "nameplateAuras" and RC.nameplateAuras then
            local na = RC.nameplateAuras
            if na.cfg and na.cfg() and na.cfg().enabled then
                if na.Start then na:Start() end
                if na.ApplyVisualSettings then na:ApplyVisualSettings() end
            elseif na.Stop then
                na:Stop()
            end
        end
        _lastBroadcastHash[categoryId] = GetCategoryHash(categoryId)
        if categoryId == "raidProfiles" and RC.db.raidProfiles then
            for _, raidKey in ipairs(KNOWN_RAID_KEYS) do
                local raidData = RC.db.raidProfiles[raidKey]
                if raidData then
                    if raidData.profiles then
                        for _, pd in pairs(raidData.profiles) do
                            if type(pd) == "table" then
                                if pd.bosses == nil then pd.bosses = {} end
                                if pd.trash  == nil then pd.trash  = {} end
                            end
                        end
                    end
                    if raidData.profiles then
                        for pn, pd in pairs(raidData.profiles) do
                            if pd.bosses then
                                for bossName, bossData in pairs(pd.bosses) do
                                    _lastBroadcastHash["_boss_"..raidKey..":"..pn..":"..bossName] = QuickHash(bossData)
                                end
                            end
                            if type(pd.route) == "table" then
                                _lastBroadcastHash["_route_"..raidKey..":"..pn] = QuickHash(pd.route)
                            end
                        end
                    end
                    local metaData = {}
                    if raidData.profiles then
                        for pn, pd in pairs(raidData.profiles) do
                            metaData[pn] = { enabled = pd.enabled, trash = pd.trash }
                        end
                    end
                    _lastBroadcastHash["_meta_"..raidKey] = QuickHash(metaData)
                    _lastBroadcastHash["_routeCfg"] = QuickHash(SlimRouteCfg() or {})
                end
            end
        end

        if categoryId == "raidProfiles" and RC.RaidRoute then
            local RRm = RC.RaidRoute
            if RRm.raidName then
                if RRm.NormalizeActive then RRm:NormalizeActive() end
                if RRm.UpdateArming    then RRm:UpdateArming()    end
                if RRm.RefreshTracker  then RRm:RefreshTracker()  end
                if RRm.RefreshUI       then RRm:RefreshUI()       end
                RC:DebugPrint("MeshSync: live route data applied for "
                    .. tostring(RRm.raidName), "route")
            end
        end
        if categoryId == "bossNotes" then
            if RC.RebuildTrashKillWatch then RC:RebuildTrashKillWatch() end
            if RC.UpdateBossNotes then RC:UpdateBossNotes() end
        end

        MS._recentApplies = MS._recentApplies or {}
        MS._recentApplies[from] = MS._recentApplies[from] or {}
        MS._recentApplies[from][categoryId] = GetTime()

        LogActivity("Received " .. catDef.label .. " from " .. from .. (isPartial and " (partial)" or ""))

        -- Chat report of what actually landed, driven by the apply itself
        -- so it can never fall out of step with bookkeeping. Coalesced for
        -- a couple of seconds so a burst of categories prints one line per
        -- sender. Partials are skipped - the raid-config flow announces
        -- itself once and would spam here.
        if not isPartial then
            MS._applyReport = MS._applyReport or {}
            local rep = MS._applyReport[from]
            if not rep then rep = {}; MS._applyReport[from] = rep end
            rep[catDef.label or categoryId] = true
            if not MS._applyReportPending then
                MS._applyReportPending = true
                C_Timer.After(2, function()
                    MS._applyReportPending = nil
                    local report = MS._applyReport or {}
                    MS._applyReport = {}
                    for src, cats in pairs(report) do
                        local list = {}
                        for label in pairs(cats) do list[#list + 1] = label end
                        table.sort(list)
                        RC:Print(RCL["Mesh: Received "] .. table.concat(list, ", ")
                            .. RCL[" from "] .. src)
                    end
                end)
            end
        end

        if categoryId == "raidProfiles" and isPartial then
            if not _receivedRaidConfirmPrinted[from] then
                _receivedRaidConfirmPrinted[from] = true
                RC:Print(RCL["Mesh: Receiving Raid Configs from "] .. from .. "...")
            end
        end

        self:NavigateAndRefresh(categoryId)
        return true
    end

    local pushInflight = {}

    -- Called when a peer goes offline or says BYE. Dropping their queued
    -- chunks must also clear their in-flight reservations, or the next push
    -- to them is refused as a duplicate.
    _mss.AbortQueuedFor = function(tk, label, silent)
        local q = tk and sendQueues[tk]
        if not q or not q[1] then return end
        local dropped = #q
        sendQueues[tk] = nil
        _mss.sendPending = _mss.sendPending - dropped
        if _mss.sendPending < 0 then _mss.sendPending = 0 end
        RebuildSendOrder()
        for k in pairs(pushInflight) do
            if k:sub(1, #tk + 1) == (tk .. "|") then pushInflight[k] = nil end
        end
        if silent then
            RC:DebugPrint("MeshSync: " .. tostring(label or tk) .. " is offline - dropped "
                .. dropped .. " queued parts", "meshsync")
        else
            RC:Print(RCL["Mesh: "] .. tostring(label or tk) .. RCL[" went offline - dropped "]
                .. dropped .. RCL[" queued sync parts."])
        end
        if _mss.sendPending == 0 then MS._drainHigh = 0 end
    end
    -- Pre-send reservation, held only until the real drain time is known
    -- (PushRawPayload rewrites it once the packet count exists). Content
    -- signatures do the actual duplicate suppression, so this no longer
    -- needs to be minutes long.
    local PUSH_INFLIGHT_WINDOW = 45

-- Export table. Mesh_Inbound and Mesh_Remote re-localise these at load, so
-- a name missing here becomes a nil local in the consumer and only fails
-- when that code path first runs. Load order: this file, then the others.
_mss.ACCOUNT_TIMEOUT = ACCOUNT_TIMEOUT
_mss.ADDON_PREFIX = ADDON_PREFIX
_mss.BUFFER_TIMEOUT = BUFFER_TIMEOUT
_mss.BroadcastToAllMembers = BroadcastToAllMembers
_mss.BuildHelloData = BuildHelloData
_mss.CMD_ACK = CMD_ACK
_mss.CMD_BYE = CMD_BYE
_mss.CMD_HELLO = CMD_HELLO
_mss.CMD_PUSH_DONE = CMD_PUSH_DONE
_mss.CheckRecvSessionDone = CheckRecvSessionDone
_mss.ChunkData = ChunkData
_mss.ChunkForTarget = ChunkForTarget
_mss.EncodeWire = EncodeWire
_mss.DecodeWire = DecodeWire
_mss.PeerSupportsRC2 = PeerSupportsRC2
_mss.PROTO_VERSION = PROTO_VERSION
_mss.CMD_CAP = CMD_CAP
_mss.peerProto = _mss.peerProto or {}
_mss.Deserialize = Deserialize
_mss.EnqueueMessages = EnqueueMessages
_mss.GetCategoryHash = GetCategoryHash
_mss.GetCharEnabled = GetCharEnabled
_mss.GetMyLabel = GetMyLabel
_mss.GetToken = GetToken
_mss.GetToonKey = GetToonKey
_mss.HELLO_INTERVAL = HELLO_INTERVAL
_mss.HideChannelFromChat = HideChannelFromChat
_mss.InitBroadcastHashes = InitBroadcastHashes
_mss.JoinDiscoveryChannel = JoinDiscoveryChannel
_mss.KNOWN_RAID_KEYS = KNOWN_RAID_KEYS
_mss.LeaveDiscoveryChannel = LeaveDiscoveryChannel
_mss.LogActivity = LogActivity
_mss.MAINT_INTERVAL = MAINT_INTERVAL
_mss.MAX_MESH_MEMBERS = MAX_MESH_MEMBERS
_mss.NextMsgId = NextMsgId
_mss.NormalizeName = NormalizeName
_mss.POLL_SAFETY_RESCAN = POLL_SAFETY_RESCAN
_mss.PUSH_INFLIGHT_WINDOW = PUSH_INFLIGHT_WINDOW
_mss.ParsePeerHashes = ParsePeerHashes
_mss.QuickHash = QuickHash
_mss.RP = RP
_mss.RebuildSyncCategories = RebuildSyncCategories
_mss.SEND_INTERVAL = SEND_INTERVAL
_mss.Serialize = Serialize
_mss.SessionTotal = SessionTotal
_mss.SlimRaidData = SlimRaidData
_mss.SlimRouteCfg = SlimRouteCfg
_mss.StripGearFromBoss = StripGearFromBoss
_mss.StripGearFromRaid = StripGearFromRaid
_mss.UpdateRecvRow = UpdateRecvRow
_mss._badTokenWarnedAt = _badTokenWarnedAt
_mss._lastBroadcastHash = _lastBroadcastHash
_mss._receivedRaidConfirmPrinted = _receivedRaidConfirmPrinted
_mss.inboundBuffers = inboundBuffers
_mss.knownAccounts = knownAccounts
_mss.knownChars = knownChars
_mss.lastHelloResponseTo = lastHelloResponseTo
_mss.pushInflight = pushInflight
_mss.recvSessions = recvSessions
