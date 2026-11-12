------------------------------------------------------------------------
-- Readycheck - World Buff Timers Comms
-- Wire-compatible with Nova World Buffs' guild timer network, so
-- Readycheck and NWB users in one guild share a single pool of timers.
-- Independent implementation of NWB's message format; the design is
-- Venomisto's and is credited in CREDITS.md.
--
-- TWO WIRES, both read; the newer one sent whenever the client can
-- (WBT.HasNewCodec - see WBT_Core for the history):
--   NEW (Nova World Buffs 3.43+ encoding, 3.48+ data; WBT.WIRE_VERSION)
--     payload: Encode(C_EncodingUtil.CompressString(SerializeCBOR(msg), 0, 2))
--       Encode = LibDeflate's addon-channel alphabet, or
--       C_EncodingUtil.EncodeBase64 on YELL/SAY.
--     data = SerializeCBOR(table) for the data cmds; flowers "1".."0",
--       layers[<world>][<layer id>] (the world is 1 on Classic Era),
--       layerMap values as short zone numbers.
--   OLD (3.39; what Readycheck 5.0.5 and earlier speak)
--     payload: Encode(LibDeflate:CompressDeflate(LibSerialize(msg), level 9))
--       Encode = addon-channel alphabet, or the chat-channel one on YELL/SAY.
--     data = LibSerialize(table); flowers "f1".."f10", layers[<layer id>],
--       layerMap values as map ids.
--   transport (both): AceComm framing on the network prefix - single part
--     <=255 bytes raw (\004-escaped if it starts with \001-\009), else
--     254-byte chunks prefixed \001/\002/\003.
--   msgString (both): "<cmd> <protoVer> <level>[-<layerNum>] <timeHash> <data>"
--     timeHash = epochToHash of truncated server time; receivers
--     recompute it and gate layer/flower merges on a match.
--     data = the serialized table (short keys) for data cmds, plain text
--     args for instant cmds (yell/drop/npcKilled/flower/handIn).
--
-- Command vocabulary (cmd, then plain-text args after the header):
--   data / settings   serialized store merge: drop timestamps, per-layer
--                     tables, layerMap, timerLog, per-user settings table
--   requestData       same payload and also asks the guild for a reply
--   requestSettings   reply with the settings table only
--   l <n>             "I am on layer n" ping, GUILD only, 10s throttle
--   yell <key> [layer] [arg]     NPC pull-timer yell heard: SECONDS until
--                     the buff lands. Never starts a cooldown.
--   drop <key> [layer]           a buff just landed: starts the multi-hour
--                     cooldown. Sent at most once per buff per 60s.
--   npcKilled <key> [layer]      herald NPC died, buff is delayed
--   flower <flowerN> [layer]     songflower picked
--   handIn <questID> [layer]     quest turn-in seen; accepted from YELL/SAY
--                     only, so the guild never re-announces it
-- Channels: GUILD carries every cmd; RAID/PARTY carry the instant cmds for
-- people in the group; YELL/SAY reach non-guild players in shouting range.
-- Cross-faction and out-of-range peers are the mesh's job (WBT_Mesh).
-- Inbound also accepts the legacy yell2/npcKilled2/flower2 spellings.
------------------------------------------------------------------------
-- CREDIT: the message vocabulary and framing above follow the design of
-- Nova World Buffs (Venomisto). No NWB code is bundled; Readycheck does
-- transmit on NWB's prefix (WBT.NETWORK_PREFIX) so both addons share one
-- pool of timers - see the note in WBT_Core and CREDITS.md.
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end
local RC = _G.Readycheck
if not RC or not RC.WorldBuffTimers then return end
local WBT = RC.WorldBuffTimers

WBT.Comms = WBT.Comms or {}
local Comms = WBT.Comms

local GetServerTime = GetServerTime
local strsplit = strsplit
local strmatch = string.match
local math_floor = math.floor

local LS, LD
local function GetCodecLibs()
    if LS and LD then return LS, LD end
    if LibStub then
        LS = LibStub("LibSerialize", true)
        LD = LibStub("LibDeflate", true)
    end
    return LS, LD
end

local function pairsByKeys(t, f)
    local a = {}
    for n in pairs(t) do a[#a + 1] = n end
    table.sort(a, f)
    local i = 0
    return function()
        i = i + 1
        if a[i] ~= nil then return a[i], t[a[i]] end
    end
end
WBT.pairsByKeys = pairsByKeys

-- Split with a cap: after `count` splits the remainder is one element
-- (the serialized data blob can contain spaces).
local function explode(div, str, count)
    if div == "" then return false end
    local pos, arr = 0, {}
    local index = 0
    for st, sp in function() return string.find(str, div, pos, true) end do
        index = index + 1
        table.insert(arr, string.sub(str, pos, st - 1))
        pos = sp + 1
        if count and index == count then
            table.insert(arr, string.sub(str, pos))
            return arr
        end
    end
    table.insert(arr, string.sub(str, pos))
    return arr
end

-- Network key-shortening map (exact copy - do not edit).
local shortKeys = {
    ["a"] = "disableAllGuildMsgs", ["b"] = "guildBuffDropped",
    ["c"] = "guildNpcDialogue", ["d"] = "guildZanDialogue",
    ["e"] = "guildNpcKilled", ["f"] = "guildSongflower",
    ["g"] = "guildCommand", ["h"] = "guild30", ["i"] = "guild15",
    ["j"] = "guild10", ["k"] = "guild5", ["l"] = "guild1", ["m"] = "guild0",
    ["n"] = "rendTimer", ["o"] = "rendYell", ["p"] = "rendYell2",
    ["q"] = "rendTimerWho", ["r"] = "rendSource",
    ["s"] = "onyTimer", ["t"] = "onyYell", ["u"] = "onyYell2",
    ["v"] = "onyTimerWho", ["w"] = "onySource", ["x"] = "onyNpcDied",
    ["y"] = "nefTimer", ["z"] = "nefYell", ["A"] = "nefYell2",
    ["B"] = "nefTimerWho", ["C"] = "nefSource", ["D"] = "nefNpcDied",
    ["E"] = "lastSeenNPC", ["F"] = "timerLog", ["G"] = "type",
    ["H"] = "timestamp", ["I"] = "layerID", ["J"] = "who",
    ["K"] = "guildNpcWalking", ["L"] = "terokTowers", ["M"] = "terokFaction",
    ["N"] = "hellfireRep", ["O"] = "tbcHD", ["P"] = "tbcHDT",
    ["Q"] = "tbcDD", ["R"] = "tbcDDT", ["S"] = "tbcPD", ["T"] = "tbcPDT",
    ["U"] = "terokTowersTime", ["V"] = "guildTerok10", ["W"] = "wintergrasp",
    ["X"] = "wintergraspFaction", ["Y"] = "wintergraspTime",
    ["aa"] = "ashenvale", ["ab"] = "ashenvaleTime",
    ["ac"] = "lastAshenvaleGuildMsg", ["ad"] = "stvData",
    ["ae"] = "npcID", ["af"] = "spawn",
    ["f1"] = "flower1", ["f2"] = "flower2", ["f3"] = "flower3",
    ["f4"] = "flower4", ["f5"] = "flower5", ["f6"] = "flower6",
    ["f7"] = "flower7", ["f8"] = "flower8", ["f9"] = "flower9",
    ["f10"] = "flower10",
    ["t1"] = "tuber1", ["t2"] = "tuber2", ["t3"] = "tuber3",
    ["t4"] = "tuber4", ["t5"] = "tuber5", ["t6"] = "tuber6",
    ["d1"] = "dragon1", ["d2"] = "dragon2", ["d3"] = "dragon3",
    ["d4"] = "dragon4",
}
local shortKeysReversed = {}
for k, v in pairs(shortKeys) do shortKeysReversed[v] = k end

-- WHAT NOVA WORLD BUFFS 3.48 CHANGED IN THE DATA (2026-11-11, read off a
-- 3.50 install; Zac: "i like never have songflower timers anymore").
-- The map above is the 3.39 one. From 3.48 a sender:
--   * writes the songflowers as "1" .. "9" and "0" (flower10), where they
--     were "f1" .. "f10". (The picked-a-flower message itself only prints
--     a chat line; the timer travels in the data.)
--   * swapped two keys: "N" is spawn and "af" is hellfireRep.
--   * nests the per-layer records by world: layers[<world>][<layer id>]
--     (flattened on arrival, WBT.FlatLayers; the world is 1 on Classic Era).
--   * sends each layer's zone map with short zone numbers (ZONE_SHORT).
--   * ignores timer data from anything older than 3.48.
-- Incoming data is read with the map of the version that sent it (the
-- songflower spellings never collide, so both are taken from anyone);
-- outgoing data is written the 3.48 way whenever the new wire is spoken.
local NEW_WIRE_FROM = 3.48
local ERA_WORLD = 1                    -- Nova World Buffs' storage id for Azeroth on Classic Era
local shortKeysOldRx, shortKeysNewRx = {}, {}
for k, v in pairs(shortKeys) do shortKeysOldRx[k] = v shortKeysNewRx[k] = v end
for i = 1, 10 do
    local short = tostring(i % 10)          -- "1" .. "9", then "0" for the tenth
    shortKeysOldRx[short] = "flower" .. i
    shortKeysNewRx[short] = "flower" .. i
end
shortKeysNewRx["N"], shortKeysNewRx["af"] = "spawn", "hellfireRep"
-- writing the 3.48 way: the reverse of the 3.48 map
local shortKeysNewTx = {}
for k, v in pairs(shortKeys) do shortKeysNewTx[v] = k end
for i = 1, 10 do shortKeysNewTx["flower" .. i] = tostring(i % 10) end
shortKeysNewTx["spawn"], shortKeysNewTx["hellfireRep"] = "N", "af"
local function isNewWire(remoteVersion)
    local v = tonumber(remoteVersion)
    return v ~= nil and v >= NEW_WIRE_FROM
end
Comms.IsNewWire = isNewWire

-- A layer's zone map is { [zone uid] = map id }. On the new wire the map
-- ids of the Classic zones travel as 1 .. 46 (Durotar 1411 = 1 ... The
-- Barrens 1413 = 3, then Alterac Mountains 1416 = 4 ... Undercity 1458 =
-- 46; 1414 and 1415 are the continents and are not zones). Anything else
-- travels as itself, and nothing real is below 100, so a small number is
-- always a short one.
local ZONE_SHORT, ZONE_LONG = {}, {}
for short = 1, 46 do
    local mapID = (short <= 3) and (1410 + short) or (1412 + short)
    ZONE_SHORT[mapID], ZONE_LONG[short] = short, mapID
end
local function encodeLayerMap(layerMap)
    local out = {}
    for zoneID, mapID in pairs(layerMap) do out[zoneID] = ZONE_SHORT[mapID] or mapID end
    return out
end
-- (returns nil for a map that does not decode: one bad entry means the
-- whole map is not to be trusted)
local function decodeLayerMap(layerMap)
    local out = {}
    for zoneID, mapID in pairs(layerMap) do
        if type(mapID) ~= "number" then return nil end
        if mapID < 100 then mapID = ZONE_LONG[mapID] end
        if not mapID then return nil end
        out[zoneID] = mapID
    end
    return out
end
Comms.EncodeLayerMap, Comms.DecodeLayerMap = encodeLayerMap, decodeLayerMap

-- Base-36 freshness token. timeToken drops the last 3 digits of
-- (serverTime + 1998), so the value only changes once every 1000s and the
-- 1998 offset moves where that boundary falls. validToken accepts the
-- current bucket or the one just rolled over, so a message stamped right
-- before a boundary and delivered right after (multipart sends take real
-- time) still lands; effective slack is 1000-2000s.
-- Timestamps travel as base 36 - digits then lowercase letters - to keep
-- the token short enough to ride in a message header.
--
-- The ENCODING is fixed by the shared protocol: a token produced here has
-- to read identically on any other client in the pool, and theirs here.
-- Base 36 is base 36, so that is a constraint on the output, not on how
-- it is reached. Digits resolve through a prebuilt lookup rather than a
-- string scan per character, the encoder assembles through a table rather
-- than rebuilding a string each pass, and the decoder runs Horner's method
-- so it never touches floating-point exponentiation.
local HASH_DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local HASH_BASE   = #HASH_DIGITS
local HASH_VALUE  = {}
for i = 1, HASH_BASE do
    HASH_VALUE[string.sub(HASH_DIGITS, i, i)] = i - 1
end

local function epochToHash(n)
    n = math_floor(tonumber(n) or 0)
    if n <= 0 then return "" end
    local digits, count = {}, 0
    repeat
        local d = n % HASH_BASE
        count = count + 1
        digits[count] = string.sub(HASH_DIGITS, d + 1, d + 1)
        n = math_floor(n / HASH_BASE)
    until n == 0
    -- Built least-significant first; flip in place rather than paying for
    -- a second table.
    for i = 1, math_floor(count / 2) do
        digits[i], digits[count - i + 1] = digits[count - i + 1], digits[i]
    end
    return table.concat(digits)
end

local function epochFromHash(s)
    if type(s) ~= "string" or s == "" then return nil end
    local epoch = 0
    for i = 1, #s do
        local v = HASH_VALUE[string.sub(s, i, i)]
        -- An unknown character means the token is not ours to read; the
        -- callers all treat nil as "reject", never as zero.
        if not v then return nil end
        epoch = epoch * HASH_BASE + v
    end
    return epoch
end

local function timeToken()
    return epochToHash(tonumber(string.sub(tostring(GetServerTime() + 1998), 1, -4)) or 0)
end

local function validToken(d)
    if type(d) ~= "string" or d == "" then return false end
    local got = epochFromHash(d)
    if not got then return false end
    local now = tonumber(string.sub(tostring(GetServerTime() + 1998), 1, -4))
    if not now then return false end
    -- Current bucket or the one just rolled over: a message stamped right
    -- before a 1000s boundary and delivered right after (chunked sends
    -- take real time) used to be silently discarded whole.
    return got == now or got == now - 1
end
Comms.ValidToken = validToken
Comms.TimeToken = timeToken

-- Network data sanitizer (runs on both send and receive): zeroes keys
-- sharing an identical timestamp and runs of flowerN picks exactly 1s
-- apart. Peers run the same pass; skipping it desyncs us.
local function sanitizeData(i)
    local e, f = {}, {}
    for k, v in pairs(i) do
        if tonumber(v) and v ~= 0 and v > 50 and type(k) == "string" and not string.match(k, "Yell") then
            local dup
            for _, w in pairs(e) do
                if v == w then dup = true end
            end
            if dup then f[v] = true else e[k] = v end
        end
    end
    for k, v in pairs(i) do
        if tonumber(v) and v ~= 0 and v ~= 1 and f[v] then
            i[k] = 0
        end
    end
    local m, ke = {}, {}
    for k, v in pairs(i) do
        if type(k) == "table" then
            WBT:Debug("data table error found in sanitizeData")
            return
        end
        -- "r%d" matches the long key names flowerN and tuberN. Short-form
        -- keys ("f1") never match, so the run detection below only bites on
        -- the receive pass, where keys have already been expanded.
        if tostring(k) and string.match(tostring(k), "r%d") then
            if tonumber(v) then m[v] = k end
        end
    end
    local l, lk, c = 0, "", 0
    if next(m) then
        for k, v in pairsByKeys(m) do
            if k == l + 1 then
                c = c + 1
                ke[v] = k
                ke[lk] = k
            end
            l = k
            lk = v
        end
        if c > 1 then
            for k in pairs(ke) do
                i[k] = 0
            end
        end
    end
    return i
end

-- The only whitelisted keys whose value is legitimately a string; every
-- other validKeys entry is a timestamp or count. Anything else that
-- arrives (tables, booleans, numeric strings) is dropped on merge.
local stringKeys = { faction = true, GUID = true }
local function acceptedValue(k, v)
    if type(k) ~= "string" then return false end
    if stringKeys[k] or k:match("TimerWho$") or k:match("Source$") then
        return type(v) == "string"
    end
    return type(v) == "number"
end

local hashKeys = {
    rendTimer=true, rendYell=true, rendYell2=true,
    onyTimer=true, onyYell=true, onyYell2=true, onyNpcDied=true,
    nefTimer=true, nefYell=true, nefYell2=true, nefNpcDied=true,
    zanYell=true, zanYell2=true, lastSeenNPC=true,
    flower1=true, flower2=true, flower3=true, flower4=true, flower5=true,
    flower6=true, flower7=true, flower8=true, flower9=true, flower10=true,
    tuber1=true, tuber2=true, tuber3=true, tuber4=true, tuber5=true, tuber6=true,
    dragon1=true, dragon2=true, dragon3=true, dragon4=true,
}

-- newWire: reading - the sender speaks 3.48 or later; writing - we do
local function convertKeys(tbl, shorten, distribution, newWire)
    if type(tbl) ~= "table" then
        WBT:Debug("no convertKeys table")
        return
    end
    local keys
    if shorten then
        keys = newWire and shortKeysNewTx or shortKeysReversed
    else
        keys = newWire and shortKeysNewRx or shortKeysOldRx
    end
    local data = {}
    for k, v in pairs(tbl) do
        if type(v) == "table" then
            v = convertKeys(v, shorten, distribution, newWire)
        end
        if distribution == "YELL" and not shorten and hashKeys[keys[k]] then
            -- Old clients hashed yell timestamps; accept both forms.
            if not tonumber(v) then
                v = epochFromHash(v)
            end
            if not tonumber(v) then return end
        end
        if keys[k] then
            data[keys[k]] = v
        else
            data[k] = v
        end
    end
    data = sanitizeData(data)
    return data
end
Comms.ConvertKeys = convertKeys

------------------------------------------------------------------------
-- Outbound transport (throttle: 4-message burst, then 1 per 0.35s -
-- under ChatThrottleLib's ~800 bytes/sec sustained target)
------------------------------------------------------------------------
local MSG_MULTI_FIRST = "\001"
local MSG_MULTI_NEXT  = "\002"
local MSG_MULTI_LAST  = "\003"
local MSG_ESCAPE      = "\004"

local sendQueue = {}
local sendTicker
local burstAllowance = 4
local lastBurstRefill = 0

local function pumpQueue()
    local now = GetTime()
    if now - lastBurstRefill > 5 then
        burstAllowance = 4
        lastBurstRefill = now
    end
    local entry = table.remove(sendQueue, 1)
    if entry then
        C_ChatInfo.SendAddonMessage(WBT.NETWORK_PREFIX, entry.text, entry.distribution, entry.target)
    end
    if #sendQueue == 0 and sendTicker then
        sendTicker:Cancel()
        sendTicker = nil
    end
end

local function startSendTicker()
    if RC.Profiler and RC.Profiler.TrackTicker then
        return RC.Profiler:TrackTicker("WorldBuffTimers:SendQueue", 0.35, pumpQueue)
    end
    return C_Timer.NewTicker(0.35, pumpQueue)
end

local function queueChunk(text, distribution, target, front)
    local entry = { text = text, distribution = distribution, target = target }
    if front then
        table.insert(sendQueue, 1, entry)
    else
        sendQueue[#sendQueue + 1] = entry
    end
    if burstAllowance > 0 and not sendTicker then
        burstAllowance = burstAllowance - 1
        pumpQueue()
        if #sendQueue > 0 and not sendTicker then
            sendTicker = startSendTicker()
        end
    elseif not sendTicker then
        sendTicker = startSendTicker()
    end
end

-- Addon messages cap at 255 bytes. A payload starting in \001-\009 would be
-- read as a chunk header, so it is escaped with \004 (or forced multipart
-- when the extra byte would overflow).
local function sendFramed(text, distribution, target, prio)
    local textlen = #text
    local maxtextlen = 255
    local front = (prio == "ALERT")
    local forceMultipart
    if strmatch(text, "^[\001-\009]") then
        if textlen + 1 > maxtextlen then
            forceMultipart = true
        else
            text = MSG_ESCAPE .. text
            textlen = textlen + 1
        end
    end
    if not forceMultipart and textlen <= maxtextlen then
        queueChunk(text, distribution, target, front)
    else
        maxtextlen = maxtextlen - 1
        local chunks = {}
        chunks[#chunks + 1] = MSG_MULTI_FIRST .. string.sub(text, 1, maxtextlen)
        local pos = 1 + maxtextlen
        while pos + maxtextlen <= textlen do
            chunks[#chunks + 1] = MSG_MULTI_NEXT .. string.sub(text, pos, pos + maxtextlen - 1)
            pos = pos + maxtextlen
        end
        chunks[#chunks + 1] = MSG_MULTI_LAST .. string.sub(text, pos)
        -- A multipart message never jumps the queue, whatever the prio:
        -- pushed in front of another in-flight multipart its chunks
        -- interleave with that one's and the receiver reassembles garbage
        -- for both. With the queue empty, appending is the same as front
        -- insertion anyway (and reverse front insertion let the burst pump
        -- send the LAST chunk first).
        for i = 1, #chunks do
            queueChunk(chunks[i], distribution, target, false)
        end
    end
end

local function isInArena()
    local _, instanceType = IsInInstance()
    return instanceType == "arena"
end

------------------------------------------------------------------------
-- The two encodings (see the header). Everything that leaves goes out in
-- the one Comms.NewWire() names; everything that arrives is tried as the
-- older one first and the newer one second - the order Nova World Buffs
-- itself uses - and the caller is told which it was.
------------------------------------------------------------------------
function Comms.NewWire()
    return WBT.HasNewCodec()
end
-- message string -> text ready for the addon channel (nil on failure)
local function packEnvelope(msgString, distribution)
    local ls, ld = GetCodecLibs()
    if not ld then return end
    if Comms.NewWire() then
        local E = C_EncodingUtil
        local ok, packed = pcall(function()
            return E.CompressString(E.SerializeCBOR(msgString), 0, 2)     -- deflate, smallest
        end)
        if not ok or type(packed) ~= "string" then return end
        if distribution == "YELL" or distribution == "SAY" then
            local ok2, text = pcall(E.EncodeBase64, packed, 0)
            return ok2 and text or nil
        end
        return ld:EncodeForWoWAddonChannel(packed)
    end
    if not ls then return end
    local compressed = ld:CompressDeflate(ls:Serialize(msgString), { level = 9 })
    if distribution == "YELL" or distribution == "SAY" then
        return ld:EncodeForWoWChatChannel(compressed)
    end
    return ld:EncodeForWoWAddonChannel(compressed)
end
-- text off the addon channel -> message string, and true when it was the
-- newer encoding (nil when neither opens it)
local function unpackEnvelope(msg, distribution)
    local ls, ld = GetCodecLibs()
    if not ld then return end
    local chat = distribution == "YELL" or distribution == "SAY"
    if ls then
        local decoded = chat and ld:DecodeForWoWChatChannel(msg) or (not chat and ld:DecodeForWoWAddonChannel(msg)) or nil
        local decompressed = decoded and ld:DecompressDeflate(decoded)
        if decompressed then
            local ok, text = ls:Deserialize(decompressed)
            if ok and type(text) == "string" then return text, false end
        end
    end
    if not WBT.HasNewCodec() then return end
    local E = C_EncodingUtil
    local decoded
    if chat then
        local ok, d = pcall(E.DecodeBase64, msg, 0)
        decoded = ok and d or nil
    else
        decoded = ld:DecodeForWoWAddonChannel(msg)
    end
    if type(decoded) ~= "string" then return end
    local ok, decompressed = pcall(E.DecompressString, decoded, 0)
    if not ok or type(decompressed) ~= "string" then return end
    local ok2, text = pcall(E.DeserializeCBOR, decompressed)
    if not ok2 or type(text) ~= "string" then return end
    return text, true
end
-- the table inside a data message -> its text, in the wire being spoken
local function packInner(tbl)
    if Comms.NewWire() then
        local ok, text = pcall(C_EncodingUtil.SerializeCBOR, tbl)
        return (ok and type(text) == "string") and text or nil
    end
    local ls = GetCodecLibs()
    return ls and ls:Serialize(tbl) or nil
end
-- ...and back. newFirst: the envelope was the newer encoding, so the
-- inside almost certainly is too; either way both are tried.
local function unpackInner(text, newFirst)
    if type(text) ~= "string" then return end
    local ls = GetCodecLibs()
    local function Old()
        if not ls then return end
        local ok, data = ls:Deserialize(text)
        if ok and type(data) == "table" then return data end
    end
    local function New()
        if not WBT.HasNewCodec() then return end
        local ok, data = pcall(C_EncodingUtil.DeserializeCBOR, text)
        if ok and type(data) == "table" then return data end
    end
    if newFirst then return New() or Old() end
    return Old() or New()
end
Comms.PackEnvelope, Comms.UnpackEnvelope = packEnvelope, unpackEnvelope
Comms.PackInner, Comms.UnpackInner = packInner, unpackInner

function Comms:SendComm(distribution, msgString, target, prio)
    if not WBT:CanSend() then return end
    local ls, ld = GetCodecLibs()
    if not ls or not ld then return end
    if target == UnitName("player") then return end
    if distribution == "GUILD" and not IsInGuild() then return end
    -- Battlegrounds, arenas and instance groups are cross-realm: everyone
    -- around us is on another realm's layers, so only GUILD leaves there.
    if (UnitInBattleground("player") or isInArena()) and distribution ~= "GUILD" then return end
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) and distribution ~= "GUILD" then
        return
    end
    if distribution ~= "WHISPER" and distribution ~= "CHANNEL" then
        target = nil
    end
    local data = packEnvelope(msgString, distribution)
    if not data then return end
    sendFramed(data, distribution, target, prio)
end

local function versionHeader()
    return WBT.PROTOCOL_VERSION .. " " .. (UnitLevel("player") or 1)
end

-- Our current layer number rides along in the header's level field as
-- "<level>-<layerNum>"; peers read it to know which layer we speak for.
local function statusL(distribution)
    if WBT:IsLayered() and distribution == "GUILD" then
        if WBT.currentLayerShared and WBT.currentLayerShared > 0 then
            return "-" .. WBT.currentLayerShared
        elseif (Comms._lastDataSent or 0) == 0 then
            return "-0"
        end
    end
    return ""
end

------------------------------------------------------------------------
-- Payload builders
------------------------------------------------------------------------
-- We advertise "no guild messages from me" so peers never designate us
-- as the guild-chat announcer (a real legacy-addon user keeps that role).
function Comms:CreateSettings(distribution)
    local data = {}
    if (UnitInBattleground("player") or isInArena()) and distribution ~= "GUILD" then
        return data
    end
    if distribution == "GUILD" then
        local me = UnitName("player") .. "-" .. (GetNormalizedRealmName() or "")
        data[me] = {
            disableAllGuildMsgs = true,
            guildBuffDropped = 0,
            guildNpcDialogue = 0,
            guildZanDialogue = 0,
            guildNpcKilled = 0,
            guildSongflower = 0,
            guildCommand = 0,
            guild10 = 0,
            guild1 = 0,
            guildNpcWalking = false,
        }
    end
    return convertKeys(data, true, distribution, Comms.NewWire()) or {}
end

-- Only rend drops ("r") and rend quest hand-ins ("q") are shared, capped at
-- 6 entries no older than 24h: the log exists solely so the network can
-- attribute a rend drop to a layer after the fact.
function Comms:CreateTimerLogData(distribution, entries)
    if not WBT:IsLayered() then return end
    local d = WBT:Data()
    if not d or not next(d.timerLog) then return end
    if (UnitInBattleground("player") or isInArena()) and distribution ~= "GUILD" then return end
    entries = entries or 6
    local count = 0
    local sorted = {}
    for _, v in ipairs(d.timerLog) do
        if v.type == "r" or v.type == "q" then
            count = count + 1
            if v.timestamp and v.timestamp > (GetServerTime() - 86400) then
                sorted[#sorted + 1] = v
            end
            v.layerNum = nil
            if count >= entries * 2 then break end
        end
    end
    if #sorted == 0 then return end
    table.sort(sorted, function(a, b) return a.timestamp > b.timestamp end)
    local data = {}
    count = 0
    for _, v in ipairs(sorted) do
        count = count + 1
        data[count] = v
        if count >= entries then break end
    end
    -- Pull in close-timestamp pairs from other layers the cap left out.
    local extra = {}
    for _, v in ipairs(data) do
        local c2 = 0
        for _, vv in ipairs(sorted) do
            c2 = c2 + 1
            if c2 > entries and v.timestamp < (vv.timestamp + 30) and v.timestamp > (vv.timestamp - 30)
                    and v.layerID ~= vv.layerID then
                extra[#extra + 1] = vv
            end
        end
    end
    for _, v in ipairs(extra) do data[#data + 1] = v end
    if next(data) then return data end
end

local lastSendLayerMap = {}
local lastSendLayerMapID = {}

function Comms:CreateDataLayered(distribution, noLayerMap, noLogs, forceLayerMap)
    local d = WBT:Data()
    local data = {}
    if not d then return data end
    if (UnitInBattleground("player") or isInArena()) and distribution ~= "GUILD" then
        return data
    end
    lastSendLayerMap[distribution] = lastSendLayerMap[distribution] or 0
    -- layerMaps are by far the largest thing on the wire, so one goes out at
    -- most every 1840s per channel and never to a party or raid.
    local sendLayerMap, foundTimer
    if not noLayerMap and (GetServerTime() - lastSendLayerMap[distribution]) > 1840
            and distribution ~= "PARTY" and distribution ~= "RAID" then
        sendLayerMap = true
    end
    local function ensureLayer(layer)
        data.layers = data.layers or {}
        data.layers[layer] = data.layers[layer] or {}
        return data.layers[layer]
    end
    -- Only timestamps still inside their own cooldown are sent; an older one
    -- carries no information and receivers discard it anyway.
    for layer, v in pairsByKeys(d.layers) do
        foundTimer = nil
        if WBT.rendCooldown > 0 and (v.rendTimer or 0) > (GetServerTime() - WBT.rendCooldown) then
            local out = ensureLayer(layer)
            out.rendTimer = v.rendTimer
            out.rendYell = v.rendYell
            foundTimer = true
        end
        if WBT.onyCooldown > 0 and (v.onyTimer or 0) > (GetServerTime() - WBT.onyCooldown) then
            local out = ensureLayer(layer)
            out.onyTimer = v.onyTimer
            out.onyYell = v.onyYell
            foundTimer = true
        end
        if WBT.nefCooldown > 0 and (v.nefTimer or 0) > (GetServerTime() - WBT.nefCooldown) then
            local out = ensureLayer(layer)
            out.nefTimer = v.nefTimer
            out.nefYell = v.nefYell
            foundTimer = true
        end
        if (v.onyNpcDied or 0) > (v.onyTimer or 0)
                and (v.onyNpcDied or 0) > (GetServerTime() - WBT.onyCooldown) then
            local out = ensureLayer(layer)
            out.onyNpcDied = v.onyNpcDied
            foundTimer = true
        end
        -- Faction asymmetry: only Alliance puts nefNpcDied on the wire, and
        -- the receive path drops the Horde form to match. Change one side
        -- and the two factions' stores diverge.
        if (v.nefNpcDied or 0) > (v.nefTimer or 0)
                and (v.nefNpcDied or 0) > (GetServerTime() - WBT.nefCooldown) then
            if WBT.faction == "Alliance" then
                ensureLayer(layer).nefNpcDied = v.nefNpcDied
            end
        end
        for i = 1, 10 do
            local fk = "flower" .. i
            if v[fk] and v[fk] > GetServerTime() - WBT.FLOWER_CD then
                ensureLayer(layer)[fk] = v[fk]
                foundTimer = true
            end
        end
        if forceLayerMap or ((sendLayerMap and foundTimer) or not lastSendLayerMapID[layer]
                or (lastSendLayerMapID[layer] and GetServerTime() - lastSendLayerMapID[layer] > 3600)) then
            if v.layerMap and next(v.layerMap) then
                lastSendLayerMap[distribution] = GetServerTime()
                lastSendLayerMapID[layer] = GetServerTime()
                local count = 0
                for _ in pairs(v.layerMap) do count = count + 1 end
                -- A map covering 70+ zones is merged garbage, not one layer.
                if count < 70 then
                    ensureLayer(layer).layerMap = v.layerMap
                end
            end
        end
        if v.lastSeenNPC and v.lastSeenNPC > GetServerTime() - WBT.layerExpire then
            ensureLayer(layer).lastSeenNPC = v.lastSeenNPC
        end
        if data.layers and data.layers[layer] and v.spawn and v.spawn > 0 then
            data.layers[layer].spawn = v.spawn
        end
    end
    -- The new wire: zone maps in short numbers, and the layers one level
    -- down, under the world they belong to (always Azeroth here).
    if Comms.NewWire() and data.layers then
        for _, out in pairs(data.layers) do
            if out.layerMap then out.layerMap = encodeLayerMap(out.layerMap) end
        end
        data.layers = { [ERA_WORLD] = data.layers }
    end
    if distribution == "GUILD" and not forceLayerMap then
        local settings = self:CreateSettings(distribution)
        local me = UnitName("player") .. "-" .. (GetNormalizedRealmName() or "")
        data[me] = settings[me]
    end
    if not noLogs then
        local timerLog = self:CreateTimerLogData(distribution)
        if timerLog then data.timerLog = timerLog end
    end
    return convertKeys(data, true, distribution, Comms.NewWire()) or {}
end

function Comms:CreateData(distribution, noLogs)
    local d = WBT:Data()
    local data = {}
    if not d then return data end
    if (UnitInBattleground("player") or isInArena()) and distribution ~= "GUILD" then
        return data
    end
    if WBT.rendCooldown > 0 and d.rendTimer > (GetServerTime() - WBT.rendCooldown) then
        data.rendTimer = d.rendTimer
        data.rendYell = d.rendYell or 0
    end
    if WBT.onyCooldown > 0 and d.onyTimer > (GetServerTime() - WBT.onyCooldown) then
        data.onyTimer = d.onyTimer
        data.onyYell = d.onyYell or 0
    end
    if WBT.nefCooldown > 0 and d.nefTimer > (GetServerTime() - WBT.nefCooldown) then
        data.nefTimer = d.nefTimer
        data.nefYell = d.nefYell or 0
    end
    if d.onyNpcDied > d.onyTimer and d.onyNpcDied > (GetServerTime() - WBT.onyCooldown) then
        data.onyNpcDied = d.onyNpcDied
    end
    if d.nefNpcDied > d.nefTimer and d.nefNpcDied > (GetServerTime() - WBT.nefCooldown) then
        if WBT.faction == "Alliance" then
            data.nefNpcDied = d.nefNpcDied
        end
    end
    for i = 1, 10 do
        local fk = "flower" .. i
        if d[fk] > GetServerTime() - WBT.FLOWER_CD then data[fk] = d[fk] end
    end
    for i = 1, 6 do
        local tk = "tuber" .. i
        if d[tk] > GetServerTime() - WBT.FLOWER_CD then data[tk] = d[tk] end
    end
    for i = 1, 4 do
        local dk = "dragon" .. i
        if d[dk] > GetServerTime() - WBT.FLOWER_CD then data[dk] = d[dk] end
    end
    if distribution == "GUILD" then
        local settings = self:CreateSettings(distribution)
        local me = UnitName("player") .. "-" .. (GetNormalizedRealmName() or "")
        data[me] = settings[me]
    end
    if not noLogs then
        local timerLog = self:CreateTimerLogData(distribution)
        if timerLog then data.timerLog = timerLog end
    end
    return convertKeys(data, true, distribution, Comms.NewWire()) or {}
end

------------------------------------------------------------------------
-- High level sends
------------------------------------------------------------------------
Comms._lastDataSent = 0

function Comms:SendData(distribution, target, prio, noLayerMap, noLogs, forceLayerMap)
    if not WBT:CanSend() then return end
    local ls = GetCodecLibs()
    if not ls then return end
    if distribution == "YELL" then
        if IsInInstance() then return end
        -- Floor between YELL data dumps. The 20m ticker is the intended
        -- cadence, but the event-driven callers - EVERY songflower pick,
        -- NPC deaths, drops, both taxi hooks - had no gap at all, and a
        -- yell payload is several chat-channel messages that all count
        -- against the same server throttle as /say. A flower run used to
        -- be one multi-chunk yell dump per node and could squelch the
        -- player ("You are sending too many messages"). The payload is
        -- full current state, so the next send carries everything anyway.
        if (GetServerTime() - (self._lastYellDataAt or 0)) < 60 then
            WBT:Debug("yell data suppressed (60s floor)")
            return
        end
    end
    prio = prio or "NORMAL"
    local data
    if WBT:IsLayered() then
        data = self:CreateDataLayered(distribution, noLayerMap, noLogs, forceLayerMap)
    else
        data = self:CreateData(distribution, noLogs)
    end
    if data and next(data) ~= nil then
        local serialized = packInner(data)
        if not serialized then return end
        local l = statusL(distribution)
        self._lastDataSent = GetServerTime()
        if distribution == "YELL" then self._lastYellDataAt = GetServerTime() end
        self:SendComm(distribution, "data " .. versionHeader() .. l .. " " .. timeToken() .. " " .. serialized, target, prio)
        WBT:Debug("sent data (" .. distribution .. ")")
    end
end

function Comms:SendSettings(distribution, target, prio)
    if not WBT:CanSend() then return end
    local ls = GetCodecLibs()
    if not ls then return end
    if (UnitInBattleground("player") or isInArena()) and distribution ~= "GUILD" then return end
    local data = self:CreateSettings(distribution)
    if data and next(data) ~= nil then
        local serialized = packInner(data)
        if not serialized then return end
        local l = statusL(distribution)
        self._lastDataSent = GetServerTime()
        self:SendComm(distribution, "settings " .. versionHeader() .. l .. " " .. timeToken() .. " " .. serialized, target, prio)
    end
end

function Comms:SendTimerLogData(distribution, entries)
    if not WBT:CanSend() or not WBT:IsLayered() then return end
    local ls = GetCodecLibs()
    if not ls then return end
    if distribution == "YELL" then
        if IsInInstance() then return end
        -- Shares SendData's 60s yell floor - same chat-throttle budget.
        if (GetServerTime() - (self._lastYellDataAt or 0)) < 60 then
            WBT:Debug("yell timer log suppressed (60s floor)")
            return
        end
        self._lastYellDataAt = GetServerTime()
    end
    local logData = self:CreateTimerLogData(distribution, entries)
    if not logData then return end
    local data = convertKeys({ timerLog = logData }, true, distribution, Comms.NewWire())
    if data and next(data) ~= nil then
        local serialized = packInner(data)
        if not serialized then return end
        self._lastDataSent = GetServerTime()
        self:SendComm(distribution, "data " .. versionHeader() .. " " .. timeToken() .. " " .. serialized)
    end
end

function Comms:RequestData(distribution, target, prio)
    if not WBT:CanSend() then return end
    local ls = GetCodecLibs()
    if not ls then return end
    prio = prio or "NORMAL"
    local data
    if WBT:IsLayered() then
        data = self:CreateDataLayered(distribution)
    else
        data = self:CreateData(distribution)
    end
    data = packInner(data or {})
    if not data then return end
    self._lastDataSent = GetServerTime()
    self:SendComm(distribution, "requestData " .. versionHeader() .. " " .. timeToken() .. " " .. data, target, prio)
end

-- Instant cmds carry plain text instead of a serialized table: each is one
-- small event that has to arrive now. A missing layer is written as "0" so
-- any following arg still lands in the right position.
local function sendInstant(cmd, distribution, msgType, target, layer, arg)
    if not WBT:CanSend() then return end
    local parts = cmd .. " " .. versionHeader() .. " " .. timeToken() .. " " .. msgType
    if tonumber(layer) then
        parts = parts .. " " .. layer
    elseif arg then
        parts = parts .. " 0"
    end
    if arg then
        parts = parts .. " " .. arg
    end
    Comms:SendComm(distribution, parts, target)
end

-- A yell means "this buff lands in seconds" - a pull warning that expires
-- almost immediately. It never starts a cooldown; only SendBuffDropped
-- does. Note the layer is stripped from every yell key here, not just rend.
function Comms:SendYell(distribution, msgType, target, layer, arg)
    if WBT.sharedLayerBuffs then layer = nil end
    sendInstant("yell", distribution, msgType, target, layer, arg)
end

-- A drop means the buff has landed and the multi-hour cooldown has started.
-- The Detect setters rate-limit this to one per buff per 60s.
function Comms:SendBuffDropped(distribution, msgType, target, layer)
    sendInstant("drop", distribution, msgType, target, layer)
end

function Comms:SendNpcKilled(distribution, msgType, target, layer)
    sendInstant("npcKilled", distribution, msgType, target, layer)
end

function Comms:SendFlower(distribution, msgType, target, layer)
    sendInstant("flower", distribution, msgType, target, layer)
end

function Comms:SendHandIn(distribution, questID, target, layer)
    sendInstant("handIn", distribution, tostring(questID), target, layer)
end

-- Layer ping. Layer detection re-fires on every target change in the
-- capital, hence the 10s floor between pings.
function Comms:SendL(layerNum)
    if not WBT:CanSend() then return end
    if GetServerTime() - (self._lastSendL or 0) < 10 then return end
    if UnitInBattleground("player") or isInArena() or not IsInGuild() then return end
    self._lastSendL = GetServerTime()
    self:SendComm("GUILD", "l " .. versionHeader() .. "-" .. layerNum .. " " .. timeToken())
end

-- Only the first 2 online network users (alphabetical) reply with full
-- data so one logon doesn't trigger a reply avalanche.
function Comms:GetGuildDataStatus()
    if not IsInGuild() then return end
    C_GuildInfo.GuildRoster()
    local numTotalMembers = GetNumGuildMembers()
    local onlineMembers = {}
    local myRealm = GetNormalizedRealmName() or ""
    local me = UnitName("player") .. "-" .. myRealm
    for i = 1, numTotalMembers do
        local name, _, _, _, _, _, _, _, online, _, _, _, _, isMobile = GetGuildRosterInfo(i)
        if name and online and not isMobile then
            -- networkUsers keys are always "Name-NormalizedRealm", but the
            -- roster returns bare names on non-connected realms - so this
            -- lookup never matched, onlineMembers stayed empty, and this
            -- client answered every requestData with settings instead of
            -- real timer data. Qualify bare names before the lookup, the
            -- same way IsPlayerInGuild reconciles the two.
            local qualified = name:find("-", 1, true) and name
                or (name .. "-" .. myRealm)
            if WBT.networkUsers[qualified] then
                onlineMembers[qualified] = true
            end
        end
    end
    local count = 0
    for k in pairsByKeys(onlineMembers) do
        count = count + 1
        if count > 2 then return end
        if k == me then return true end
    end
end

------------------------------------------------------------------------
-- DRIFT: noticing the day Nova World Buffs changes its wire again
-- (2026-11-12, Zac: "how can we prevent that from happening in the
-- future if nova updates?")
--
-- Twice now (3.43's encoding, 3.48's layout) the other addon changed
-- what it sends and Readycheck went quiet without a sound: every message
-- it could not open was dropped, which looks exactly like "nobody has a
-- timer". Nothing can make an old Readycheck read a format that does not
-- exist yet, but it can stop being silent about it. For the session:
--   newer    the highest sender version above the one this file was
--            checked against (WBT.WIRE_VERSION)
--   unread   messages on the timer prefix that neither encoding opened
--            (a new encoding hides the sender's version with everything
--            else, so these are counted on their own: a handful in one
--            session is the 3.43 kind of change), and data whose inside
--            neither reader could parse
--   unknown  short keys from a newer sender that this file has no name
--            for (a key added or moved - the 3.48 change was two moved
--            keys and ten renamed ones)
--   empty    data from a newer sender that held layers this file could
--            find no layer records in (a reshaped store - the other half
--            of the 3.48 change)
-- Comms.Drift:Status() turns that into the lines the Status card shows;
-- the first time a newer sender's data fails to read, one line is
-- printed as well. Nothing is stored: a count from last week says
-- nothing about today.
------------------------------------------------------------------------
Comms.Drift = Comms.Drift or {}
local Drift = Comms.Drift
Drift.unread, Drift.unknown, Drift.empty = 0, 0, 0
Drift.newer, Drift.unreadNewer, Drift.told = nil, 0, nil
Drift.MSG_WARN, Drift.MSG_TELL = 5, 12      -- unopened messages: say so on the card / in chat

local function testedVersion() return tonumber(WBT.WIRE_VERSION) or 0 end
local function isNewer(remoteVersion)
    local v = tonumber(remoteVersion)
    return v ~= nil and v > testedVersion()
end

function Drift:Reset()
    self.unread, self.unknown, self.empty = 0, 0, 0
    self.newer, self.unreadNewer, self.told = nil, 0, nil
end

-- a header was read: remember the newest version above ours
function Drift:Saw(remoteVersion)
    if isNewer(remoteVersion) and (not self.newer or tonumber(remoteVersion) > tonumber(self.newer)) then
        self.newer = tostring(remoteVersion)
        WBT:Debug("newer timer addon version seen: " .. self.newer .. " (this wire: " .. tostring(WBT.WIRE_VERSION) .. ")")
    end
end

local function tell(self)
    if self.told then return end
    self.told = true
    RC:Print("World Buff Timers: " .. (self.newer and ("Nova World Buffs " .. self.newer) or "another timer addon")
        .. " is sending timers in a form this Readycheck cannot fully read. Timers from those players may be missing "
        .. "until Readycheck is updated.")
end

-- something on the prefix could not be opened (what = "message" | "data")
function Drift:Unread(what, sender, remoteVersion)
    self.unread = self.unread + 1
    if what == "data" and isNewer(remoteVersion) then
        self.unreadNewer = self.unreadNewer + 1
        self:Saw(remoteVersion)
        tell(self)
    elseif what == "message" and self.unread >= self.MSG_TELL then
        tell(self)
    end
    WBT:Debug("unreadable " .. tostring(what) .. " from " .. tostring(sender)
        .. (remoteVersion and (" (v" .. tostring(remoteVersion) .. ")") or ""))
end

-- data was read: from a newer sender, does it look like what we know?
function Drift:Read(data, sender, remoteVersion)
    if not isNewer(remoteVersion) or type(data) ~= "table" then return end
    local odd = 0
    local function scan(t, depth)
        for k, v in pairs(t) do
            -- a short string key still short after conversion, holding a
            -- number, is a key this file has no long name for
            if type(k) == "string" and #k <= 2 and type(v) == "number" and not WBT.validKeys[k] then
                odd = odd + 1
            end
            if type(v) == "table" and depth < 3 and k ~= "layerMap" and k ~= "timerLog" then scan(v, depth + 1) end
        end
    end
    scan(data, 0)
    local empty = false
    if type(data.layers) == "table" and next(data.layers) ~= nil then
        local flat = WBT.FlatLayers(data.layers)
        local found = false
        for _, rec in pairs(flat) do
            if type(rec) == "table" then
                for k in pairs(rec) do
                    if type(k) == "string" and WBT.validKeys[k] then found = true break end
                end
            end
            if found then break end
        end
        empty = not found
    end
    if odd > 0 then self.unknown = self.unknown + odd end
    if empty then self.empty = self.empty + 1 end
    if odd > 0 or empty then
        WBT:Debug("data from " .. tostring(sender) .. " (v" .. tostring(remoteVersion) .. ") does not look like "
            .. tostring(WBT.WIRE_VERSION) .. ": " .. odd .. " unknown key(s)" .. (empty and ", no layer records found" or ""))
        tell(self)
    end
end

-- the Status card's lines: { text, level } with level "ok" | "warn"
function Drift:Status()
    local lines = {}
    if Comms.NewWire() then
        lines[#lines + 1] = { "Timer format: Nova World Buffs " .. tostring(WBT.WIRE_VERSION) .. " (older Readycheck is read too).", "ok" }
    else
        lines[#lines + 1] = { "Timer format: the older " .. tostring(WBT.LEGACY_VERSION)
            .. " (this client lacks the newer encoder); current Nova World Buffs users will not take timers from here.", "warn" }
    end
    local trouble = self.unreadNewer + self.unknown + self.empty
    if self.newer and trouble > 0 then
        lines[#lines + 1] = { "Nova World Buffs " .. self.newer .. " seen: " .. trouble
            .. " thing(s) it sent could not be read. Its format has changed - update Readycheck.", "warn" }
    elseif self.newer then
        lines[#lines + 1] = { "Nova World Buffs " .. self.newer .. " seen (newer than " .. tostring(WBT.WIRE_VERSION)
            .. "); everything it sent so far read fine.", "ok" }
    end
    if self.unread >= self.MSG_WARN and not (self.newer and trouble > 0) then
        lines[#lines + 1] = { self.unread .. " timer messages could not be opened this session: "
            .. "another addon's encoding may have changed. Check for a Readycheck update.", "warn" }
    elseif self.unread > 0 and not (self.newer and trouble > 0) then
        lines[#lines + 1] = { self.unread .. " message(s) this session could not be opened.", "ok" }
    end
    return lines
end

------------------------------------------------------------------------
-- Inbound merge
------------------------------------------------------------------------
-- newEnvelope: the message came in the newer encoding (so its data is
-- almost certainly CBOR; both readers are tried either way)
function Comms:ReceivedData(dataReceived, sender, distribution, elapsed, remoteVersion, newEnvelope)
    local d = WBT:Data()
    if not d then return end
    local data = unpackInner(dataReceived, newEnvelope)
    if not data then
        Comms.Drift:Unread("data", sender, remoteVersion)
        return
    end
    data = convertKeys(data, nil, distribution, isNewWire(remoteVersion))
    if not data then
        WBT:Debug("bad hash result from " .. tostring(sender))
        return
    end
    Comms.Drift:Read(data, sender, remoteVersion)
    -- layers[<world>][<layer id>] (3.48+) read as layers[<layer id>]
    if type(data.layers) == "table" then data.layers = WBT.FlatLayers(data.layers) end
    -- zone maps sent in short numbers (3.48+) read as map ids; one that
    -- does not decode is left out rather than guessed at
    if type(data.layers) == "table" then
        for _, vv in pairs(data.layers) do
            if type(vv) == "table" and vv.layerMap ~= nil then
                vv.layerMap = type(vv.layerMap) == "table" and decodeLayerMap(vv.layerMap) or nil
            end
        end
    end
    -- Settings rows come off this same decode; OnCommReceived used to
    -- deserialize and expand the whole payload a second time for them.
    if distribution == "GUILD" then
        self:ExtractSettings(nil, sender, distribution, data)
    end
    -- A timer without its yell timestamp is corrupt data.
    if tonumber(data.rendTimer) and not tonumber(data.rendYell) then return end
    if tonumber(data.onyTimer) and not tonumber(data.onyYell) then return end
    if tonumber(data.nefTimer) and not tonumber(data.nefYell) then return end

    -- The herald's yell precedes the buff by well under two minutes, so a
    -- drop whose yell timestamp sits further than 120s from it (or that is
    -- older than what we already hold) is fabricated; drop the whole set.
    -- The "no yell at all" case is already handled by the returns above.
    local function dropSet(prefix)
        data[prefix .. "Timer"] = nil
        data[prefix .. "TimerWho"] = nil
        data[prefix .. "Yell"] = nil
        data[prefix .. "Yell2"] = nil
        data[prefix .. "Source"] = nil
    end
    if data.rendTimer and tonumber(data.rendTimer) and (not data.rendYell or data.rendTimer < d.rendTimer
            or data.rendYell < (data.rendTimer - 120) or data.rendYell > (data.rendTimer + 120)) then
        dropSet("rend")
    end
    if data.onyTimer and tonumber(data.onyTimer) and (not data.onyYell or data.onyTimer < d.onyTimer
            or data.onyYell < (data.onyTimer - 120) or data.onyYell > (data.onyTimer + 120)) then
        dropSet("ony")
    end
    if data.nefTimer and tonumber(data.nefTimer) and (not data.nefYell or data.nefTimer < d.nefTimer
            or data.nefYell < (data.nefTimer - 120) or data.nefYell > (data.nefTimer + 120)) then
        dropSet("nef")
    end

    local hasNewData, newFlowerData

    -- Layer merges are gated on the sender's time token matching ours, so a
    -- client with a badly wrong clock cannot inject layers into the store.
    if WBT:IsLayered() and data.layers and validToken(elapsed) then
        for k in pairs(data.layers) do
            if type(k) ~= "number" then
                WBT:Debug("bad data, layer key is a string")
                return
            end
        end
        -- Never create a local layer from one that has no recent NPC
        -- sighting or carries nothing but zeroes; layerCap is small and a
        -- junk entry pushes a real layer out.
        for layer, vv in pairsByKeys(data.layers) do
            -- (2026-11-12) ...which is a rule about MAKING a layer. One we
            -- already hold takes what arrives for it: someone who has been
            -- picking songflowers in Felwood for three hours has seen no
            -- city NPC in that time, sends no sighting with the layer, and
            -- their songflower timers for a layer we both know were being
            -- thrown away with it.
            local skipLayer = type(vv) ~= "table" or d.layersDisabled[layer]
            if not skipLayer and not d.layers[layer] then
                skipLayer = not vv.lastSeenNPC
                    or GetServerTime() - vv.lastSeenNPC > WBT.layerExpire
                    or ((not vv.rendTimer or vv.rendTimer == 0) and (not vv.onyTimer or vv.onyTimer == 0)
                        and (not vv.nefTimer or vv.nefTimer == 0) and (not vv.onyNpcDied or vv.onyNpcDied == 0)
                        and (not vv.nefNpcDied or vv.nefNpcDied == 0) and (not vv.lastSeenNPC or vv.lastSeenNPC == 0))
            end
            if not skipLayer and type(vv) == "table" and next(vv) then
                -- Identical timestamps on two layers = corrupt; strip them.
                for localLayer, localV in pairs(d.layers) do
                    if vv.rendTimer and localV.rendTimer and vv.rendTimer == localV.rendTimer and layer ~= localLayer then
                        vv.rendTimer = nil; vv.rendTimerWho = nil; vv.rendYell = nil; vv.rendYell2 = nil; vv.rendSource = nil
                    end
                    if vv.onyTimer and localV.onyTimer and vv.onyTimer == localV.onyTimer and layer ~= localLayer then
                        vv.onyTimer = nil; vv.onyTimerWho = nil; vv.onyYell = nil; vv.onyYell2 = nil; vv.onySource = nil; vv.onyNpcDied = nil
                    end
                    if vv.nefTimer and localV.nefTimer and vv.nefTimer == localV.nefTimer and layer ~= localLayer then
                        vv.nefTimer = nil; vv.nefTimerWho = nil; vv.nefYell = nil; vv.nefYell2 = nil; vv.nefSource = nil; vv.nefNpcDied = nil
                    end
                end
                if not d.layers[layer] then
                    WBT:CreateNewLayer(layer, vv.GUID or "other")
                end
                if d.layers[layer] then
                    local dl = d.layers[layer]
                    if vv.rendTimer and tonumber(vv.rendTimer) and (not vv.rendYell
                            or vv.rendTimer < (GetServerTime() - WBT.rendCooldown)
                            or vv.rendYell < (vv.rendTimer - 120) or vv.rendYell > (vv.rendTimer + 120)) then
                        vv.rendTimer = nil; vv.rendTimerWho = nil; vv.rendYell = nil; vv.rendYell2 = nil; vv.rendSource = nil
                    end
                    if vv.onyTimer and tonumber(vv.onyTimer) and (not vv.onyYell
                            or vv.onyTimer < (GetServerTime() - WBT.onyCooldown)
                            or vv.onyYell < (vv.onyTimer - 120) or vv.onyYell > (vv.onyTimer + 120)) then
                        vv.onyTimer = nil; vv.onyTimerWho = nil; vv.onyYell = nil; vv.onyYell2 = nil; vv.onySource = nil
                    end
                    if vv.nefTimer and tonumber(vv.nefTimer) and (not vv.nefYell
                            or vv.nefTimer < (GetServerTime() - WBT.nefCooldown)
                            or vv.nefYell < (vv.nefTimer - 120) or vv.nefYell > (vv.nefTimer + 120)) then
                        vv.nefTimer = nil; vv.nefTimerWho = nil; vv.nefYell = nil; vv.nefYell2 = nil; vv.nefSource = nil
                    end
                    for k, v in pairs(vv) do
                        if WBT.validKeys[k] and type(v) == "number" and k ~= "npcID" then
                            if not tonumber(dl[k]) then dl[k] = 0 end
                            if dl[k] ~= nil and v ~= 0 and v > dl[k]
                                    and WBT:ValidateTimestamp(v) and k ~= "terokFaction" then
                                if WBT:IsLayered() and type(k) == "string" and k:match("flower")
                                        and dl[k] and (GetServerTime() - dl[k]) < WBT.FLOWER_CD then
                                    -- Never overwrite a live songflower timer.
                                else
                                    if type(k) == "string" and k:match("flower")
                                            and not (distribution == "GUILD" and (GetServerTime() - dl[k]) > 15) then
                                        newFlowerData = true
                                    end
                                    if k == "onyNpcDied" or (k == "nefNpcDied" and WBT.faction == "Alliance") then
                                        if WBT.Detect and WBT.Detect.OnReceivedNpcDied then
                                            WBT.Detect:OnReceivedNpcDied(k, v, distribution, layer, sender)
                                        end
                                    end
                                    if WBT:ValidateCloseTimestamps(layer, k, v) then
                                        -- Log only what actually passed the
                                        -- gate: a rejected merge used to
                                        -- land in timerLog anyway and get
                                        -- re-shared by CreateTimerLogData.
                                        WBT:TimerLog(k, v, layer)
                                        if k == "lastSeenNPC" then
                                            if not dl.lastSeenNPC or v > dl.lastSeenNPC then dl[k] = v end
                                        elseif k == "spawn" then
                                            if v ~= 0 then
                                                if dl.spawn and dl.spawn ~= 0 then
                                                    if v < dl.spawn then dl[k] = v end
                                                else
                                                    dl[k] = v
                                                end
                                            end
                                        elseif k == "created" then
                                            if not dl.created then dl[k] = v end
                                        elseif k == "terokTowers" or k == "terokTowersTime" or k == "hellfireRep" then
                                            -- Not era content; ignore.
                                        else
                                            dl[k] = v
                                        end
                                        if not k:match("lastSeenNPC") and not k:match("terokTowers")
                                                and not k:match("hellfireRep") and k ~= "spawn" then
                                            hasNewData = true
                                        end
                                    end
                                end
                            end
                        elseif k == "layerMap" then
                            dl.layerMap = dl.layerMap or {}
                            if type(v) == "table" then
                                for zoneID, mapID in pairs(v) do
                                    if not dl.layerMap[zoneID] and WBT.layerZoneWhitelist[mapID] then
                                        local skip
                                        for _, lv in pairs(d.layers) do
                                            if lv.layerMap and lv.layerMap[zoneID] then skip = true end
                                        end
                                        if WBT:ValidateZoneID(zoneID, layer, mapID) and not skip then
                                            dl.layerMap[zoneID] = mapID
                                        end
                                    end
                                end
                            end
                        elseif v ~= nil and k ~= "layers" and k ~= "npcID" and k ~= "spawn" then
                            -- validKeys ONLY, and only the value type that
                            -- key is defined to carry. The old "or any
                            -- table" escape let every sender persist
                            -- arbitrary tables into SavedVariables forever.
                            if WBT.validKeys[k] and acceptedValue(k, v) then
                                dl[k] = v
                            end
                        end
                    end
                end
            end
        end
    end

    for k, v in pairs(data) do
        if validToken(elapsed) and type(k) == "string" then
            if WBT.validKeys[k] and type(v) == "number" then
                if not tonumber(d[k]) then
                    if k ~= "tbcDD" and k ~= "tbcHD" and k ~= "tbcPD" and k ~= "ashenvale" then
                        d[k] = 0
                    end
                end
                if k == "wintergrasp" or k == "wintergraspTime" or k == "terokTowers"
                        or k == "terokTowersTime" or k == "ashenvale" or k == "ashenvaleTime" then
                    -- Not era content; ignore.
                elseif tonumber(d[k]) and v ~= 0 and v > d[k] and WBT:ValidateTimestamp(v)
                        and k ~= "terokFaction" and k ~= "wintergraspFaction"
                        and k ~= "tbcHD" and k ~= "tbcDD" and k ~= "tbcPD" then
                    -- A drop dated further ahead than one full cooldown (plus
                    -- 60s of clock slack) cannot be a real event.
                    if (k:match("flower") and v > (GetServerTime() + 1530))
                            or (k:match("tuber") and v > (GetServerTime() + 1530))
                            or (k:match("dragon") and v > (GetServerTime() + 1530))
                            or (k:match("onyTimer") and v > (GetServerTime() + 21660))
                            or (k:match("nefTimer") and v > (GetServerTime() + 28860))
                            or (k:match("rendTimer") and v > (GetServerTime() + 10860)) then
                        WBT:Debug("invalid long timer " .. k)
                    else
                        if k:match("flower") and not (distribution == "GUILD" and (GetServerTime() - d[k]) > 15) then
                            newFlowerData = true
                        end
                        if k == "onyNpcDied" or (k == "nefNpcDied" and WBT.faction == "Alliance") then
                            if WBT.Detect and WBT.Detect.OnReceivedNpcDied then
                                WBT.Detect:OnReceivedNpcDied(k, v, distribution, nil, sender)
                            end
                        end
                        if k ~= "nefNpcDied" or WBT.faction ~= "Horde" then
                            d[k] = v
                            if not k:match("terokTowers") and not k:match("wintergrasp")
                                    and not k:match("hellfireRep") and not k:match("tbcHDT") then
                                hasNewData = true
                            end
                            if not WBT:IsLayered() then
                                WBT:TimerLog(k, v, nil, nil, nil, distribution)
                            end
                        end
                    end
                end
            elseif k == "timerLog" then
                if type(v) == "table" then
                    local valid = true
                    for _, lv in pairs(v) do
                        if type(lv) ~= "table" or not tonumber(lv.timestamp) then valid = false break end
                    end
                    if valid then
                        local arr = {}
                        for _, lv in pairs(v) do arr[#arr + 1] = lv end
                        table.sort(arr, function(a, b) return a.timestamp < b.timestamp end)
                        for _, lv in ipairs(arr) do
                            WBT:TimerLog(lv.type, lv.timestamp, lv.layerID, lv.who, nil, distribution)
                        end
                    end
                end
            elseif k == "stvData" then
                -- Not era content; ignore.
            elseif v ~= nil and k ~= "layers" then
                -- Whitelisted keys (in the value type each is defined to
                -- carry), plus the one legitimate table case: the SENDER's
                -- own settings row. Rows for anyone else are ignored - a
                -- sender may only speak for itself, and the old "or any
                -- table" escape persisted arbitrary tables from any sender
                -- into SavedVariables with nothing ever pruning them.
                if WBT.validKeys[k] then
                    if acceptedValue(k, v) then d[k] = v end
                elseif type(v) == "table" and k == sender and next(v) ~= nil then
                    d[k] = v
                    d[k].updated = GetServerTime()
                end
            end
        end
    end

    if hasNewData then
        d.lastSyncBy = sender
        -- Fresh data from outside the guild gets relayed to the guild -
        -- at most once a minute. Unthrottled, a busy capital full of
        -- yelling strangers produced one guild data message per inbound
        -- yell; the data they carry still travels on the next scheduled
        -- send either way.
        -- Cheap time check first; the roster scan is a full loop over
        -- GetGuildRosterInfo and runs on every inbound yell otherwise.
        if distribution ~= "GUILD"
                and (GetServerTime() - (self._lastNonGuildRelay or 0)) >= 60
                and not self:IsPlayerInGuild(sender) then
            self._lastNonGuildRelay = GetServerTime()
            self:SendData("GUILD", nil, nil, true, true)
        end
    end
    if newFlowerData then
        WBT:Debug("new songflower data from " .. tostring(sender))
    end
end

function Comms:IsPlayerInGuild(who)
    if not IsInGuild() or not who then return end
    local name = strsplit("-", who, 2)
    for i = 1, GetNumGuildMembers() do
        local rosterName = GetGuildRosterInfo(i)
        if rosterName then
            local short = strsplit("-", rosterName, 2)
            if short == name then return true end
        end
    end
end

-- `converted`: a table ReceivedData has already deserialized and
-- key-expanded; passing it skips a second decode of the same payload.
-- Without it, dataReceived is the raw serialized blob.
function Comms:ExtractSettings(dataReceived, sender, distribution, converted)
    if distribution ~= "GUILD" then return end
    local d = WBT:Data()
    if not d then return end
    local data = converted
    if type(data) ~= "table" then
        if not dataReceived then return end
        data = unpackInner(dataReceived)
        if not data then return end
        data = convertKeys(data, nil, distribution)
        if not data then return end
    end
    local nameOnly = strsplit("-", sender, 2)
    for k, v in pairs(data) do
        -- Exact name match up to the realm separator. The old plain
        -- substring find let a sender named "Bo" claim the settings rows
        -- of "Bobby-Realm", "Boris-Realm", and anyone else containing it.
        if type(v) == "table" and type(k) == "string" and nameOnly
                and (k == sender or k:sub(1, #nameOnly + 1) == (nameOnly .. "-"))
                and next(v) then
            d[k] = v
            d[k].updated = GetServerTime()
        end
    end
end

function Comms:CleanupSettingsData()
    local d = WBT:Data()
    if not d then return end
    for k, v in pairs(d) do
        if type(k) == "string" and k:match("%-") and type(v) == "table" and v.guild1 ~= nil then
            if not tonumber(v.updated) or GetServerTime() - v.updated > 2592000 then
                d[k] = nil
            end
        end
    end
end

------------------------------------------------------------------------
-- Inbound transport + command routing
------------------------------------------------------------------------
local spool = {}
-- Parallel to spool, so a partial payload can be aged out. See purgeSpool.
local spoolAt = {}
local SPOOL_TTL = 60

-- A sender who logs out, zones, or drops group mid-payload leaves a FIRST
-- (and any NEXTs) on file with no LAST ever arriving, and nothing else in
-- here would ever clear it - the entry would sit in memory for the rest of
-- the session, once per abandoned message. Every multipart chunk sweeps
-- first: a real multipart message is reassembled in the same second or
-- two, so a minute old can only mean the rest is never coming.
local function purgeSpool(now)
    for key, at in pairs(spoolAt) do
        if (now - at) > SPOOL_TTL then
            spool[key] = nil
            spoolAt[key] = nil
        end
    end
end

-- Realms whose senders share our world: our own plus every connected
-- realm. Built once per Start; keys are lower-cased with spaces stripped,
-- which is how a realm suffix arrives on a sender name either way.
local function realmKey(name)
    return (string.lower(tostring(name or "")):gsub("%s+", ""))
end

local ourRealms
local function buildRealmSet()
    ourRealms = {}
    ourRealms[realmKey(GetRealmName())] = true
    ourRealms[realmKey(GetNormalizedRealmName and GetNormalizedRealmName() or "")] = true
    local connected = GetAutoCompleteRealms and GetAutoCompleteRealms()
    if type(connected) == "table" then
        for i = 1, #connected do
            ourRealms[realmKey(connected[i])] = true
        end
    end
    ourRealms[""] = nil
end

function Comms:IsOurRealm(realm)
    if not ourRealms then buildRealmSet() end
    return ourRealms[realmKey(realm)] == true
end

-- One answer per requester per 30s; a guild logging in at once used to
-- get a full reply from every client for every request.
local replyAt = {}
function Comms:ReplyAllowed(sender)
    local now = GetTime()
    if sender and replyAt[sender] and (now - replyAt[sender]) < 30 then return false end
    replyAt[sender or ""] = now
    return true
end

function Comms:OnCommReceived(commPrefix, msg, distribution, sender)
    if not WBT:IsActive() then return end
    local ls, ld = GetCodecLibs()
    if not ls or not ld then return end

    if distribution == "GUILD" then
        local tempSender = sender
        if not tempSender:match("-") then
            tempSender = tempSender .. "-" .. (GetNormalizedRealmName() or "")
        end
        if not WBT.networkUsers[tempSender] then
            WBT.networkUsers[tempSender] = "0"
        end
    end
    if (UnitInBattleground("player") or isInArena()) and distribution ~= "GUILD" then return end

    local me = UnitName("player") .. "-" .. GetRealmName()
    local meNormalized = UnitName("player") .. "-" .. (GetNormalizedRealmName() or "")
    if sender == UnitName("player") or sender == me or sender == meNormalized then
        WBT.networkUsers[meNormalized] = WBT.PROTOCOL_VERSION
        return
    end
    -- Timers are per realm and per layer. A cross-realm sender (BG, instance
    -- group, cross-realm zone) is describing a world we are not in. A
    -- connected realm shares our world, so its senders pass.
    local _, senderRealm = strsplit("-", sender, 2)
    if senderRealm and not self:IsOurRealm(senderRealm) then
        return
    end
    if not sender:match("-") then
        sender = sender .. "-" .. (GetNormalizedRealmName() or "")
    end

    local deserialized, newEnvelope = unpackEnvelope(msg, distribution)
    if not deserialized then
        Comms.Drift:Unread("message", sender)
        return
    end

    local args = explode(" ", deserialized, 4)
    local cmd = args[1]
    local remoteVersion = args[2]
    local data = args[5]
    if not args[3] then return end
    local _, senderLayer = strsplit("-", args[3], 2)
    local elapsed = args[4] or 0
    if senderLayer then
        WBT.userLayers[sender] = senderLayer
    end
    -- Below 1.83 the payload layout is incompatible; below 2.75 the client
    -- only understands a data reply, so answer that and stop there.
    if not remoteVersion or not tonumber(remoteVersion) or tonumber(remoteVersion) < 1.83 then
        return
    end
    WBT.networkUsers[sender] = remoteVersion or "0"
    if tonumber(remoteVersion) < 2.75 then
        -- ReceivedData never runs for these clients, so the settings row
        -- has to be pulled from the raw payload here. Newer clients get
        -- it inside ReceivedData off the single decode.
        if distribution == "GUILD" then
            self:ExtractSettings(data, sender, distribution)
        end
        if cmd == "requestData" and distribution == "GUILD" then
            if not self:GetGuildDataStatus() then
                self:SendSettings("GUILD")
            else
                self:SendData("GUILD")
            end
        end
        return
    end
    if not data then return end

    -- Instant events are only honoured from people we share a guild or group
    -- with. A stranger's /yell must not be able to start bars or alerts.
    if distribution == "GUILD" or distribution == "PARTY" or distribution == "RAID" then
        if cmd == "drop" then
            local msgType, layer = strsplit(" ", data, 2)
            if WBT.Detect then WBT.Detect:OnBuffDropMsg(msgType, layer, sender) end
        elseif cmd == "yell" or cmd == "yell2" then
            local msgType, layer, arg = strsplit(" ", data, 3)
            if WBT.Detect then WBT.Detect:OnRelayedYell(msgType, layer, distribution, arg, sender) end
        elseif cmd == "npcKilled" or cmd == "npcKilled2" then
            local msgType, layer = strsplit(" ", data, 2)
            if WBT.Detect then WBT.Detect:OnNpcKilledMsg(msgType, layer, sender) end
        elseif cmd == "flower" or cmd == "flower2" then
            local msgType, layer = strsplit(" ", data, 2)
            if WBT.Detect then WBT.Detect:OnFlowerMsg(msgType, layer, sender) end
        end
    end

    if cmd == "data" or cmd == "settings" then
        self:ReceivedData(data, sender, distribution, elapsed, remoteVersion, newEnvelope)
    elseif cmd == "requestData" and distribution == "GUILD" then
        self:ReceivedData(data, sender, distribution, elapsed, remoteVersion, newEnvelope)
        if self:ReplyAllowed(sender) then
            if not self:GetGuildDataStatus() then
                self:SendSettings("GUILD")
            else
                self:SendData("GUILD")
            end
        end
    elseif cmd == "requestSettings" and distribution == "GUILD" then
        self:ReceivedData(data, sender, distribution, elapsed, remoteVersion, newEnvelope)
        if self:ReplyAllowed(sender) then
            self:SendSettings("GUILD")
        end
    -- Hand-ins are a "someone next to you is turning in" notice, so they are
    -- only taken from the local channels (YELL/SAY), never from the guild.
    elseif cmd == "handIn" and distribution ~= "GUILD" and distribution ~= "PARTY" and distribution ~= "RAID" then
        local questID, layer = strsplit(" ", data, 2)
        if WBT.Detect then WBT.Detect:OnHandIn(questID, layer, sender) end
    end

    if tonumber(remoteVersion) and tonumber(remoteVersion) > tonumber(WBT.newestSeenVersion or 0) then
        WBT.newestSeenVersion = remoteVersion
    end
    Comms.Drift:Saw(remoteVersion, sender)
end

-- Reassembly is keyed by prefix+distribution+sender, so two senders can
-- interleave chunks. A NEXT or LAST with no FIRST on file is discarded:
-- half a payload deserializes into garbage.
local function onChatMsgAddon(prefix, message, distribution, sender)
    if prefix ~= WBT.NETWORK_PREFIX then return end
    sender = Ambiguate(sender, "none")
    local control, rest = strmatch(message, "^([\001-\009])(.*)")
    if control then
        local key = prefix .. "\t" .. distribution .. "\t" .. sender
        local now = GetServerTime()
        purgeSpool(now)
        if control == MSG_MULTI_FIRST then
            spool[key] = rest
            spoolAt[key] = now
        elseif control == MSG_MULTI_NEXT then
            local old = spool[key]
            if old then
                if type(old) ~= "table" then
                    spool[key] = { old, rest }
                else
                    old[#old + 1] = rest
                end
                spoolAt[key] = now
            end
        elseif control == MSG_MULTI_LAST then
            local old = spool[key]
            spoolAt[key] = nil
            if old then
                spool[key] = nil
                if type(old) == "table" then
                    old[#old + 1] = rest
                    Comms:OnCommReceived(prefix, table.concat(old, ""), distribution, sender)
                else
                    Comms:OnCommReceived(prefix, old .. rest, distribution, sender)
                end
            end
        elseif control == MSG_ESCAPE then
            Comms:OnCommReceived(prefix, rest, distribution, sender)
        end
    else
        Comms:OnCommReceived(prefix, message, distribution, sender)
    end
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------
-- YELL is a real /yell: it reaches non-guild players standing near us, and
-- it is the only guild-network path to someone outside our guild. That
-- makes it expensive and visible, hence 20m between sends (10m unlayered),
-- and never from an instance or battleground.
local yellTickerStarted
local function startYellTicker()
    if yellTickerStarted then return end
    yellTickerStarted = true
    local function loop()
        C_Timer.After(WBT:IsLayered() and 1200 or 600, function()
            -- Self-rescheduling, so this is the only place it can be
            -- stopped. Clearing the latch on the way out lets a later
            -- Comms:Start() spin a fresh loop instead of finding the
            -- latch set and never starting one.
            if not Comms._running then
                yellTickerStarted = nil
                return
            end
            WBT:RemoveOldLayers()
            if WBT:CanSend() and not UnitInBattleground("player")
                    and not isInArena() and not IsInInstance() then
                Comms:SendData("YELL")
            end
            loop()
        end)
    end
    loop()
end

local commFrame = CreateFrame("Frame")
commFrame:RegisterEvent("PLAYER_LOGIN")
commFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_LOGIN" then
        C_Timer.After(3, function()
            if WBT:IsMirroring() or not WBT:Settings().enabled then
                WBT:Debug("comms disabled (mirror mode or engine off)")
                return
            end
            Comms:Start()
        end)
    elseif event == "CHAT_MSG_ADDON" then
        onChatMsgAddon(...)
    elseif event == "GROUP_JOINED" then
        if GetServerTime() - WBT.loadTime > 60 then
            C_Timer.After(5, function()
                if UnitInBattleground("player") or isInArena() then return end
                if IsInRaid() then
                    Comms:SendData("RAID")
                elseif IsInGroup() then
                    Comms:SendData("PARTY")
                end
            end)
        end
    elseif event == "CHAT_MSG_SYSTEM" then
        local text = ...
        if text and ERR_GUILD_JOIN_S then
            local who = string.match(text, string.gsub(ERR_GUILD_JOIN_S, "%%s", "(.+)"))
            if who == UnitName("player") then
                Comms:RequestData("GUILD", nil, "ALERT")
            end
        end
    end
end)

-- Live on/off, driven by WBT:ApplyEnabledState. Stopping unregisters
-- CHAT_MSG_ADDON rather than dropping messages in the handler: while the
-- engine is off this addon should not be reading guild network traffic at
-- all, and every send path already gates on WBT:CanSend().
--
-- Both are idempotent, so ApplyEnabledState can call them on every
-- settings change without tracking what it did last time.
function Comms:Start()
    if Comms._running then return end
    Comms._running = true
    buildRealmSet()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix(WBT.NETWORK_PREFIX)
    end
    commFrame:RegisterEvent("CHAT_MSG_ADDON")
    commFrame:RegisterEvent("GROUP_JOINED")
    commFrame:RegisterEvent("CHAT_MSG_SYSTEM")
    Comms:CleanupSettingsData()
    Comms:RequestData("GUILD", nil, "ALERT")
    C_Timer.After(30, function()
        if WBT:CanSend() and not UnitIsGhost("player") then
            Comms:SendData("YELL")
        end
    end)
    startYellTicker()
    WBT:Debug("comms active")
end

function Comms:Stop()
    if not Comms._running then return end
    Comms._running = nil
    -- PLAYER_LOGIN stays registered: it has already fired, and the frame
    -- is reused for the three below.
    commFrame:UnregisterEvent("CHAT_MSG_ADDON")
    commFrame:UnregisterEvent("GROUP_JOINED")
    commFrame:UnregisterEvent("CHAT_MSG_SYSTEM")
    -- Anything already queued is dropped rather than sent after the switch
    -- was thrown; the queue is rebuilt from live data on the next Start.
    wipe(sendQueue)
    if sendTicker then
        sendTicker:Cancel()
        sendTicker = nil
    end
    WBT:Debug("comms stopped")
end

-- A flight path is a free way to seed two different crowds: yell once at
-- takeoff and once on landing, where a fresh set of players can hear it.
hooksecurefunc("TakeTaxiNode", function()
    if not WBT:CanSend() then return end
    Comms:SendData("YELL")
    local function checkLanded()
        if not UnitOnTaxi("player") then
            if WBT:CanSend() then Comms:SendData("YELL") end
        else
            C_Timer.After(2, checkLanded)
        end
    end
    C_Timer.After(5, checkLanded)
end)
