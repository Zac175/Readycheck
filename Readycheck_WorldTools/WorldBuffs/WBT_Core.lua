------------------------------------------------------------------------
-- Readycheck - World Buff Timers Core
-- Native world buff timer database + layer tracking, guild-synced over
-- the same wire protocol the rest of the guild's timer addons speak.
-- Store shape mirrors the legacy addon's db so import is a straight
-- merge and WorldBuffSync's reader hooks traverse it identically.
--
-- CREDIT: the guild timer network this speaks is Nova World Buffs' wire
-- format, by Venomisto. NETWORK_PREFIX below is NWB's own addon-message
-- prefix, used deliberately so NWB and Readycheck users in one guild share
-- a single pool of timers. No NWB code is bundled. See CREDITS.md.
--
-- Mirror mode: while NovaWorldBuffs is loaded we only mirror its saved
-- data on a slow ticker (no comms, no detection - zero double traffic).
-- Once it's disabled, this module runs the full receive/send/detect path.
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end
local RC = _G.Readycheck
if not RC then return end

RC.WorldBuffTimers = RC.WorldBuffTimers or {}
local WBT = RC.WorldBuffTimers

local GetServerTime = GetServerTime
local math_floor = math.floor

-- Must match the protocol Nova World Buffs is speaking. This travels in
-- every message header and both sides gate on it, so bumping it locally
-- silently drops Readycheck out of the shared pool.
--
-- TWO WIRES (2026-11-12, Zac: "both addons need to work together
-- seemlessly"). Nova World Buffs 3.43 moved its messages to the game's
-- own encoder (C_EncodingUtil: CBOR, the client's deflate, base64 on
-- yell/say) and 3.48 reshaped the data inside them; from 3.48 it takes
-- timer data only from 3.48 and up. Readycheck spoke 3.39 in the older
-- encoding, so a current Nova World Buffs user could neither read what
-- Readycheck sent nor be read by it. WBT_Comms now SENDS what the version
-- named in WIRE_VERSION sends, byte layout and all, and READS both.
--   WIRE_VERSION    the Nova World Buffs release this file's wire was
--                   checked against, line by line. Advertised in every
--                   header while the client has the encoder.
--   LEGACY_VERSION  what is advertised (and sent) on a client without
--                   C_EncodingUtil: the 3.39 wire, as before.
-- Do not raise WIRE_VERSION to "keep up" without reading that release:
-- a higher number over an older layout puts malformed data into other
-- people's saved timers. WBT_Comms watches for newer senders and
-- unreadable messages instead (Comms.Drift) and says so in the Status
-- card - that is how the next change gets noticed the day it ships.
WBT.WIRE_VERSION     = "3.50"
WBT.LEGACY_VERSION   = "3.39"
function WBT.HasNewCodec()
    local E = C_EncodingUtil
    return (E and E.SerializeCBOR and E.DeserializeCBOR and E.CompressString and E.DecompressString
        and E.EncodeBase64 and E.DecodeBase64) and true or false
end
WBT.PROTOCOL_VERSION = WBT.HasNewCodec() and WBT.WIRE_VERSION or WBT.LEGACY_VERSION
-- Nova World Buffs' addon-message prefix, used deliberately. This is
-- INTEROP, not appropriation: world buff timers are only useful if every
-- addon in a guild pools them, and speaking NWB's protocol is what lets
-- Readycheck and NWB users see each other's drops instead of sitting in
-- two silos that each think they know the truth.
--
-- The protocol is Venomisto's design and is credited in CREDITS.md. No
-- NWB code is bundled - this is an independent implementation of the
-- message format, the same way two mail clients both speak IMAP.
-- Changing this string does not "make it ours", it just breaks everyone.
WBT.NETWORK_PREFIX   = "NWB"
-- Buff cooldowns in seconds, per layer, from the era server rules: the
-- quest that drops each buff can only be turned in again this long after
-- the last drop. Rend 3h, Onyxia 6h, Nefarian 8h. Every remaining time in
-- the addon is (drop timestamp + cooldown) - now, so these must be exact.
WBT.rendCooldown     = 10800
WBT.onyCooldown      = 21600
-- DO NOT use nefCooldown for anything the player sees. The Head of
-- Nefarian turn-in has no cooldown on Era/Anniversary - anyone holding a
-- head can hand it in at any time - so there is no lockout to count down,
-- and Nefarian is absent from the timers card, the map pin columns, the
-- Rally estimate and the cooldown-ready warnings because of it.
--
-- The value survives purely as a wire-protocol staleness window: WBT_Comms
-- uses it to decide whether a received or outgoing nefTimer is recent
-- enough to be worth carrying. NWB clients in the shared pool still send
-- the field, and dropping it would desync us from them. See NETWORK_PREFIX.
WBT.nefCooldown      = 28800
WBT.layerCap         = 10    -- must match the rest of the network or layer sync breaks
-- A layer nobody has seen a whitelisted city NPC on for 3h is treated as
-- gone; layer IDs are recycled by the server, so stale ones mislead.
WBT.layerExpire      = 10800
WBT.sharedLayerBuffs = true  -- era: rend hits all layers

WBT.faction = UnitFactionGroup("player")
WBT.realm   = GetRealmName()

-- Era zones accepted in layerMap data from other players.
WBT.layerZoneWhitelist = {
    [1411]=true,[1412]=true,[1413]=true,[1416]=true,[1417]=true,[1418]=true,
    [1419]=true,[1420]=true,[1421]=true,[1422]=true,[1423]=true,[1424]=true,
    [1425]=true,[1426]=true,[1427]=true,[1428]=true,[1429]=true,[1430]=true,
    [1431]=true,[1432]=true,[1433]=true,[1434]=true,[1435]=true,[1436]=true,
    [1437]=true,[1438]=true,[1439]=true,[1440]=true,[1441]=true,[1442]=true,
    [1443]=true,[1444]=true,[1445]=true,[1446]=true,[1447]=true,[1448]=true,
    [1449]=true,[1450]=true,[1451]=true,[1452]=true,[1453]=true,[1454]=true,
    [1455]=true,[1456]=true,[1457]=true,[1458]=true,
}

-- Songflower respawn, the SINGLE source for the 1500s (25m) literal that
-- used to be re-hardcoded across the pin, mesh, comms and UI code.
WBT.FLOWER_CD = 1500

-- Songflower nodes; the SINGLE source of node data. WorldBuffSync builds
-- its index-keyed FLOWER_NODES 1..10 straight from this table (idx/name).
-- x/y are Felwood map percentages. A picked node respawns WBT.FLOWER_CD
-- seconds later.
-- Nodes are shared world spawns, so both factions see the same timers.
WBT.songFlowers = {
    flower1  = { x = 63.9, y = 6.1,  idx = 1,  name = "North Felpaw Village" },
    flower2  = { x = 55.8, y = 10.4, idx = 2,  name = "West Felpaw Village" },
    flower3  = { x = 50.6, y = 13.9, idx = 3,  name = "North of Irontree Woods" },
    flower4  = { x = 63.3, y = 22.6, idx = 4,  name = "Talonbranch Glade" },
    flower5  = { x = 40.1, y = 44.4, idx = 5,  name = "Shatter Scar Vale" },
    flower6  = { x = 34.3, y = 52.2, idx = 6,  name = "Bloodvenom Post" },
    flower7  = { x = 40.1, y = 56.5, idx = 7,  name = "East of Jaedenar" },
    flower8  = { x = 48.3, y = 75.7, idx = 8,  name = "North of Emerald Sanctuary" },
    flower9  = { x = 45.9, y = 85.2, idx = 9,  name = "West of Emerald Sanctuary" },
    flower10 = { x = 52.9, y = 87.8, idx = 10, name = "South of Emerald Sanctuary" },
}

-- Keys accepted from received data (superset kept for relay parity).
WBT.validKeys = {
    rendTimer=true, rendTimerWho=true, rendYell=true, rendYell2=true, rendSource=true,
    onyTimer=true, onyTimerWho=true, onyYell=true, onyYell2=true, onySource=true, onyNpcDied=true,
    nefTimer=true, nefTimerWho=true, nefYell=true, nefYell2=true, nefSource=true, nefNpcDied=true,
    zanTimer=true, zanTimerWho=true, zanYell=true, zanYell2=true, zanSource=true,
    flower1=true, flower2=true, flower3=true, flower4=true, flower5=true,
    flower6=true, flower7=true, flower8=true, flower9=true, flower10=true,
    tuber1=true, tuber2=true, tuber3=true, tuber4=true, tuber5=true, tuber6=true,
    dragon1=true, dragon2=true, dragon3=true, dragon4=true,
    terokTowers=true, terokTowersTime=true, terokFaction=true,
    wintergrasp=true, wintergraspTime=true, wintergraspFaction=true,
    hellfireRep=true, stvData=true,
    tbcHD=true, tbcHDT=true, tbcDD=true, tbcDDT=true, tbcPD=true, tbcPDT=true,
    faction=true, GUID=true, lastSeenNPC=true, spawn=true, timerLog=true,
    ashenvale=true, ashenvaleTime=true, lastAshenvaleGuildMsg=true,
}

-- Live layer-detection state (written by the Detect module).
-- Layer identity is inferred from the zoneID field of capital-city creature
-- GUIDs; the server never tells us the layer. Joining a group or changing
-- zone can silently move the player to another layer with no event, so the
-- strict values below are zeroed on those and only re-adopted once the
-- group-join / zone-change cooldowns have elapsed.
--   lastKnownLayer        display number (sort position, not an identity)
--   lastKnownLayerID      zoneID last seen, updated even during cooldown
--   lastKnownLayerMapID   zoneID trusted for writing timers
--   ...Backup             survives a group join so flower picks still land
--   currentZoneIDStrict   zoneID from a whitelisted NPC, long after joining
WBT.lastKnownLayer          = 0
WBT.lastKnownLayerID        = 0
WBT.lastKnownLayerMapID     = 0
WBT.lastKnownLayerMapIDBackup = 0
WBT.currentZoneIDStrict     = 0
WBT.currentLayerShared      = 0
WBT.lastJoinedGroup         = 0
-- A group invite can pull the player onto the leader's layer, so no GUID
-- sighting is trusted as our own layer within 180s of joining a group.
WBT.groupJoinCooldown       = 180
WBT.lastZoneChange          = 0
WBT.loadTime                = 0
WBT.networkUsers            = {} -- "Name-NormalizedRealm" -> version string
WBT.userLayers              = {} -- "Name-Realm" -> layer number string
WBT.newestSeenVersion       = WBT.PROTOCOL_VERSION

function WBT:Debug(msg)
    RC:DebugPrint("WorldBuffTimers: " .. tostring(msg), "worldbuffs")
end

local isAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
function WBT:IsMirroring()
    if self._mirroring == nil then
        self._mirroring = (isAddOnLoaded and isAddOnLoaded("NovaWorldBuffs")) and true or false
    end
    return self._mirroring
end

------------------------------------------------------------------------
-- Settings (per character)
------------------------------------------------------------------------
-- OFF BY DEFAULT, all of it. This system puts icons on the world map and
-- minimap, prints relayed alerts, and broadcasts to other players - none
-- of which anyone asked for by installing a raid addon. `enabled` is the
-- master switch and every sub-feature is off behind it, so turning the
-- system on does not immediately produce pins and chat spam either.
--
-- Anything that TRANSMITS (send, meshSync) stays off until deliberately
-- turned on: an addon that starts talking to other people's clients on
-- first login is the kind of thing that gets an addon a bad name.
local SETTINGS_DEFAULTS = {
    enabled         = false,
    send            = false, -- transmit to the guild timer network
    relayBars       = false, -- start WorldTools pull bars from relayed yells
    relayAlerts     = false,
    npcKilledAlerts = false,
    handInMsgs      = false,
    warn10          = false, -- cooldown-ready warnings
    warn1           = false,
    warn0           = false,
    mapPins         = false, -- world map icons (Felwood flowers + capital CDs)
    minimapPins     = false, -- songflower nodes on the minimap while in Felwood
    meshSync        = false, -- also carry timers over the mesh network
}

function WBT:Settings()
    if not RC.db then
        -- A copy, never the shared table: a write before RC.db exists
        -- would otherwise change the defaults for every later character.
        if RC.DeepCopy then return RC.DeepCopy(SETTINGS_DEFAULTS) end
        local copy = {}
        for k, v in pairs(SETTINGS_DEFAULTS) do copy[k] = v end
        return copy
    end
    local s = RC.db.worldBuffTimers
    if not s then
        s = {}
        RC.db.worldBuffTimers = s
    end
    -- Defaults apply to keys that are ABSENT, which means a fresh install
    -- only. Anyone who already had this running keeps every setting they
    -- had: the defaults below changed to off, and that is deliberately
    -- not retroactive. Turning off a feature someone chose to run is not
    -- a migration, it is a decision made on their behalf.
    for k, v in pairs(SETTINGS_DEFAULTS) do
        if s[k] == nil then s[k] = v end
    end
    -- Repair: the settings page used to hand its checkbox callback the
    -- CheckButton frame instead of a boolean, so every box on that page
    -- could store a frame table here. A table is truthy, which is why
    -- unticking "Enable timer network engine" left it running and the
    -- status card still read ACTIVE.
    --
    -- Anything that is not a boolean is corrupt by definition - these are
    -- all on/off keys - and there is no way to recover what was intended,
    -- so it falls back to the default. Every default is false, which means
    -- a corrupted install lands switched off rather than silently talking
    -- to the guild network.
    for k, v in pairs(SETTINGS_DEFAULTS) do
        if type(s[k]) ~= type(v) then s[k] = v end
    end
    return s
end

function WBT:IsActive()
    return self:Settings().enabled and not self:IsMirroring()
end

-- Live on/off switch for the whole engine. Every submodule registers its
-- own events and tickers, so turning the engine off has to reach into all
-- of them - it used to be read once at PLAYER_LOGIN and nowhere else,
-- which meant unticking the box left CHAT_MSG_ADDON and the combat log
-- hooked until the next /reload.
--
-- Submodules are looked up rather than captured: this file loads before
-- all of them, and any one of them may be absent in mirror mode.
-- Start/Stop are both idempotent, so this is safe to call repeatedly.
--
-- Nothing here touches the stored timer data. Switching off stops the
-- addon listening and talking; it does not throw away what it already
-- knows, so switching back on resumes with the timers intact.
function WBT:ApplyEnabledState()
    local active = self:IsActive()

    local mods = { self.Comms, self.Detect, self.MapPins }
    for i = 1, #mods do
        local m = mods[i]
        if m then
            local fn = active and m.Start or m.Stop
            if fn then pcall(fn, m) end
        end
    end

    -- Mesh deliberately follows only the enabled switch, NOT IsActive():
    -- it is documented to run in mirror mode (timers mirrored from
    -- NovaWorldBuffs still reach mesh peers). Lumping it in with the
    -- IsActive() modules meant the mesh broadcast worked after login but
    -- died permanently the first time any setting was touched.
    -- meshSync is the mesh's own sub-switch: Mesh:Start refuses while it is
    -- off, but only an explicit Stop cancels a heartbeat already running.
    if self.Mesh then
        local ms = self:Settings()
        local fn = (ms.enabled and ms.meshSync ~= false) and self.Mesh.Start or self.Mesh.Stop
        if fn then pcall(fn, self.Mesh) end
    end

    -- Layer records expire on wall-clock time, so the cleanup pass is only
    -- meaningful while records are still arriving.
    if active and not self._layerTicker then
        self._layerTicker = self.StartTicker("WorldBuffTimers:LayerCleanup", 300, function()
            WBT:RemoveOldLayers()
            -- The log grows unbounded within a session otherwise; trimming
            -- used to happen only once at login.
            WBT:TrimTimerLog()
        end)
    elseif not active and self._layerTicker then
        self._layerTicker:Cancel()
        self._layerTicker = nil
    end
end

-- Single entry point for the settings UI and /wbtnet. Returns the state it
-- settled on, which is not always what was asked for: with NovaWorldBuffs
-- loaded the engine stays in mirror mode either way.
function WBT:SetEnabled(on)
    self:Settings().enabled = on and true or false
    self:ApplyEnabledState()
    return self:IsActive()
end

function WBT:CanSend()
    local s = self:Settings()
    return s.enabled and s.send and not self:IsMirroring()
end

------------------------------------------------------------------------
-- Account-wide store (ReadycheckDB.worldBuffTimers)
------------------------------------------------------------------------
local DATA_DEFAULTS = {
    rendTimer=0, rendTimerWho="", rendYell=0, rendYell2=0, rendSource="",
    onyTimer=0, onyTimerWho="", onyYell=0, onyYell2=0, onySource="", onyNpcDied=0,
    nefTimer=0, nefTimerWho="", nefYell=0, nefYell2=0, nefSource="", nefNpcDied=0,
    zanYell=0, zanYell2=0,
    flower1=0, flower2=0, flower3=0, flower4=0, flower5=0,
    flower6=0, flower7=0, flower8=0, flower9=0, flower10=0,
    tuber1=0, tuber2=0, tuber3=0, tuber4=0, tuber5=0, tuber6=0,
    dragon1=0, dragon2=0, dragon3=0, dragon4=0,
    lastZone=0,
}

-- Both caches hold a direct reference into the saved variables, so anything
-- that replaces the realm/faction table (import, wipe) must clear them.
local storeCache
function WBT:Store()
    if storeCache then return storeCache end
    if not ReadycheckDB then return nil end
    ReadycheckDB.worldBuffTimers = ReadycheckDB.worldBuffTimers or {}
    local s = ReadycheckDB.worldBuffTimers
    s.global = s.global or {}
    s.chars = s.chars or {}
    s.imported = s.imported or {}
    storeCache = s
    return s
end

local dataCache

-- Anything that replaces or wipes ReadycheckDB.worldBuffTimers must call
-- this, or the detached table keeps being read AND transmitted (the reset
-- button used to wipe the store yet keep broadcasting the old timers to
-- the guild and the mesh until the next /reload). Declared after both
-- cache locals so these assignments bind the upvalues, not globals.
function WBT:InvalidateCaches()
    storeCache = nil
    dataCache  = nil
end

-- LAYERS, IN EITHER SHAPE (2026-11-11, Zac: "i like never have songflower
-- timers anymore" - Nova World Buffs showing them, Readycheck showing "?").
-- From its version 3.48 Nova World Buffs keeps, and sends, its per-layer
-- records one level deeper: layers[<world>][<layer id>] = record, where it
-- used to be layers[<layer id>] = record. Everything here walked one
-- level, found tables of tables where it expected timestamps, and read
-- nothing - songflowers above all, which live only in the layer records.
-- FlatLayers hands back layers[<layer id>] = record whichever shape came
-- in (the same table when it is already flat): a record is a table with
-- at least one named field, a world is a table of records.
local function isLayerRecord(t)
    for k in pairs(t) do
        if type(k) == "string" then return true end
    end
    return false
end
function WBT.FlatLayers(layers)
    if type(layers) ~= "table" then return nil end
    local nested = false
    for _, v in pairs(layers) do
        if type(v) == "table" and next(v) ~= nil and not isLayerRecord(v) then
            nested = true
            break
        end
    end
    if not nested then return layers end
    local out = {}
    for id, v in pairs(layers) do
        if type(v) == "table" then
            if isLayerRecord(v) then
                out[id] = v
            else
                for layer, rec in pairs(v) do
                    if type(layer) == "number" and type(rec) == "table" then out[layer] = rec end
                end
            end
        end
    end
    return out
end

-- An import made while Nova World Buffs 3.48+ was loaded wrote each of its
-- worlds into our store as if it were one layer: a "layer" holding nothing
-- but other layers' records. They carry no timer anything can read and
-- take a place under the layer cap, so they go (once per login).
local function dropWorldsStoredAsLayers(d)
    if type(d.layers) ~= "table" then return end
    for layer, rec in pairs(d.layers) do
        if type(rec) == "table" and next(rec) ~= nil and not isLayerRecord(rec) then
            d.layers[layer] = nil
        end
    end
end

function WBT:Data()
    if dataCache then return dataCache end
    local s = self:Store()
    if not s then return nil end
    s.global[WBT.realm] = s.global[WBT.realm] or {}
    local rd = s.global[WBT.realm]
    rd[WBT.faction] = rd[WBT.faction] or {}
    local d = rd[WBT.faction]
    for k, v in pairs(DATA_DEFAULTS) do
        if d[k] == nil then d[k] = v end
    end
    d.layers = d.layers or {}
    d.layersDisabled = d.layersDisabled or {}
    d.layerMapBackups = d.layerMapBackups or {}
    d.timerLog = d.timerLog or {}
    dropWorldsStoredAsLayers(d)
    dataCache = d
    return d
end

function WBT:OppFactionData()
    local s = self:Store()
    if not s then return nil end
    local opp = (WBT.faction == "Horde") and "Alliance" or "Horde"
    local rd = s.global[WBT.realm]
    return rd and rd[opp] or nil
end

function WBT:CharKey()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or WBT.realm or ""
    return (UnitName("player") or "?") .. "-" .. tostring(realm):gsub("%s+", "")
end

function WBT:CharData()
    local s = self:Store()
    if not s then return nil end
    local key = self:CharKey()
    s.chars[key] = s.chars[key] or {}
    return s.chars[key]
end

-- Era realms are layered; layeredOverride is a manual escape hatch only.
function WBT:IsLayered()
    local s = self:Settings()
    if s.layeredOverride ~= nil then return s.layeredOverride end
    return true
end

------------------------------------------------------------------------
-- Timestamp / timer validation
------------------------------------------------------------------------
-- Gate for every epoch that arrives from another client. 2585912598 is the
-- network's agreed upper bound (year 2051); the 30000s of future slack
-- absorbs clock skew between clients, since timers are shared as absolute
-- server epochs on the guild network rather than ages.
function WBT:ValidateTimestamp(timestamp)
    if not tonumber(timestamp) then return end
    if timestamp > 2585912598 then return end
    if timestamp > (GetServerTime() + 30000) then return end
    return true
end

-- timestamp: the stamp the caller is about to write (SetBuffTimer passes
-- GetServerTime()). It used to arrive nil - the only caller passed two
-- arguments - which made both comparisons vacuous and the documented
-- guard dead; the 20s spec.cross gate in SetBuffTimer was the only thing
-- actually separating ony from nef.
function WBT:ValidateNewTimer(buffType, source, timestamp)
    local d = self:Data()
    if not d then return end
    timestamp = tonumber(timestamp) or GetServerTime()
    if buffType == "rend" then
        return true
    elseif buffType == "ony" then
        -- Ony must never adopt nef's timestamp (and vice versa); both drop
        -- Rallying Cry so a shared timestamp means one of them is wrong.
        if d.nefTimer == timestamp or d.nefTimer == GetServerTime() then return end
    elseif buffType == "nef" then
        if d.onyTimer == timestamp or d.onyTimer == GetServerTime() then return end
    end
    return true
end

-- Reject timestamps that match another layer's too closely (cross-layer
-- sync corruption seen in the wild).
function WBT:ValidateCloseTimestamps(layer, key, timestamp)
    local d = self:Data()
    if not d then return end
    if WBT.sharedLayerBuffs and (key == "rendTimer" or key == "terokTowers" or key == "terokFaction") then
        return true
    end
    if key == "spawn" then return true end
    -- NPC sightings are not buff drops: two layers legitimately have city
    -- NPCs seen within seconds of each other, so the cross-layer-bleed
    -- heuristic has no business here. Rejecting these merges left received
    -- layers stuck at lastSeenNPC = 0, so RemoveOldLayers deleted them
    -- 300s later and the next data message recreated them - permanent
    -- create/destroy churn on every received layer.
    if key == "lastSeenNPC" then return true end
    -- Two layers claiming the same drop within 30s (10s for flowers, which
    -- are picked far more often) is cross-layer bleed, not two real events.
    local offset = 30
    if type(key) == "string" and (key:match("flower") or key == "hellfireRep") then
        offset = 10
    end
    if not timestamp then
        timestamp = d.layers[layer] and d.layers[layer][key]
        if not tonumber(timestamp) then return end
        for k, v in pairs(d.layers) do
            if k ~= layer then
                local other = v[key]
                if tonumber(other) then
                    local diff = other - timestamp
                    if diff < offset and diff > -offset then return end
                end
            end
        end
    else
        for k, v in pairs(d.layers) do
            -- The layer being merged INTO must not veto its own update: its
            -- existing value is what the incoming timestamp replaces, so
            -- comparing against it rejected every small correction.
            if k ~= layer then
                local other = v[key]
                if tonumber(other) and timestamp then
                    local diff = other - timestamp
                    if diff < offset and diff > -offset then return end
                end
            end
        end
    end
    return true
end

------------------------------------------------------------------------
-- Layer helpers
------------------------------------------------------------------------
function WBT:GetLayerCount()
    if not self:IsLayered() then return 1 end
    local d = self:Data()
    if not d then return 0 end
    local count = 0
    for _ in pairs(d.layers) do count = count + 1 end
    return count
end

-- A layer NUMBER is only the sort position of its zoneID in our own layer
-- table. Two clients agree on "layer 2" only while they hold the same set
-- of layers, so numbers are for display and messages, never for storage.
function WBT:GetLayerNum(zoneID)
    local d = self:Data()
    if not d then return 0 end
    local keys = {}
    for k in pairs(d.layers) do keys[#keys + 1] = k end
    table.sort(keys)
    for i, k in ipairs(keys) do
        if k == zoneID then return i end
    end
    return 0
end

function WBT:GetLayerZoneID(layerNum)
    local d = self:Data()
    if not d then return end
    local keys = {}
    for k in pairs(d.layers) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys[tonumber(layerNum)]
end

function WBT:GetSingleLayer()
    if not self:IsLayered() then return end
    local d = self:Data()
    if not d then return end
    local count, layer = 0, nil
    for k in pairs(d.layers) do
        count = count + 1
        layer = k
    end
    if count == 1 then return layer end
end

function WBT:MapLayerToParent(layer)
    local d = self:Data()
    if not d then return end
    if d.layers[layer] then return layer end
    for k, v in pairs(d.layers) do
        if v.layerMap then
            for kk in pairs(v.layerMap) do
                if kk == layer then return k end
            end
        end
    end
    return nil
end

function WBT:ValidateZoneID(zoneID, layerID, mapID)
    local d = self:Data()
    if not d then return end
    if layerID and d.layers[layerID] and d.layers[layerID].layerMap then
        for _, v in pairs(d.layers[layerID].layerMap) do
            if mapID and mapID == v then return end
        end
    end
    if d.layers[zoneID] then return end
    return true
end

-- When a creature spawned, read off the last field of its GUID. That
-- field is ten hex digits; the low 23 bits of the last six count seconds
-- inside an 8388608-second (2^23) window of server time (the layout the
-- client documents for creature GUIDs). Every city NPC of a layer came up
-- when the layer did, so the earliest one seen is the layer's own age -
-- and Nova World Buffs 3.48+ throws away any layer shared without it.
-- The arithmetic matches theirs to the second on purpose: the earliest
-- value wins on both sides, so two clients must compute the same number
-- from the same NPC.
function WBT:GuidSpawnTime(GUID)
    if type(GUID) ~= "string" then return end
    local _, _, _, _, _, _, spawnUID = strsplit("-", GUID)
    if type(spawnUID) ~= "string" or #spawnUID < 6 then return end
    local low = tonumber(string.sub(spawnUID, 5), 16)
    if not low then return end
    local now = GetServerTime()
    local t = (now - now % 8388608) + (low % 8388608)
    if t > now then t = t - 8388607 end        -- the window has rolled over since it spawned
    if t <= 0 then return end
    return t
end

function WBT:CreateNewLayer(zoneID, GUID, isFromNpc)
    local d = self:Data()
    if not d then return end
    if self:GetLayerCount() >= WBT.layerCap then return end
    zoneID = tonumber(zoneID)
    if not zoneID or zoneID == 0 then return end
    if GUID and GUID ~= "other" and GUID ~= "none" then
        -- Locally-sourced layers require a whitelisted city NPC GUID.
        local unitType, _, _, _, _, npcID = strsplit("-", GUID)
        if unitType ~= "Creature" or not (WBT.cityNpcs and WBT.cityNpcs[tonumber(npcID)]) then
            self:Debug("bad layer rejected " .. tostring(zoneID) .. " " .. tostring(npcID))
            return
        end
    end
    d.layers[zoneID] = {
        rendTimer = 0, rendYell = 0, rendYell2 = 0,
        onyTimer = 0, onyYell = 0, onyYell2 = 0, onyNpcDied = 0,
        nefTimer = 0, nefYell = 0, nefYell2 = 0, nefNpcDied = 0,
        created = GetServerTime(),
        GUID = GUID or "none",
        lastSeenNPC = 0,
        flower1 = 0, flower2 = 0, flower3 = 0, flower4 = 0, flower5 = 0,
        flower6 = 0, flower7 = 0, flower8 = 0, flower9 = 0, flower10 = 0,
    }
    -- A layerMap takes days of sightings to rebuild, so an expired layer's
    -- map is kept for 518400s (6 days) and restored if that zoneID returns.
    local backups = d.layerMapBackups
    if backups and backups[zoneID] and backups[zoneID].created
            and (GetServerTime() - backups[zoneID].created) < 518400 then
        d.layers[zoneID].layerMap = d.layers[zoneID].layerMap or {}
        for k, v in pairs(backups[zoneID]) do
            if k ~= "created" and v ~= 1952 then
                d.layers[zoneID].layerMap[k] = v
            end
        end
    end
    if isFromNpc then
        d.layers[zoneID].lastSeenNPC = GetServerTime()
        if d.layersDisabled[zoneID] then d.layersDisabled[zoneID] = nil end
    end
    self:Debug("created new layer " .. zoneID)
end

function WBT:RemoveOldLayers()
    local d = self:Data()
    if not d then return end
    for k, v in pairs(d.layers) do
        if v.lastSeenNPC and GetServerTime() - v.lastSeenNPC > WBT.layerExpire then
            -- A layer still inside a 25m songflower cooldown is carrying
            -- live data even if no city NPC has been seen on it.
            local liveFlower
            for i = 1, 10 do
                local t = v["flower" .. i]
                if t and GetServerTime() - t < WBT.FLOWER_CD then
                    liveFlower = true
                    break
                end
            end
            if not liveFlower then
                if v.layerMap and next(v.layerMap) then
                    d.layerMapBackups[k] = {}
                    for zk, zv in pairs(v.layerMap) do d.layerMapBackups[k][zk] = zv end
                    d.layerMapBackups[k].created = v.created or GetServerTime()
                end
                d.layers[k] = nil
                self:Debug("removed old layer " .. tostring(k))
            end
        end
    end
    for k, v in pairs(d.layerMapBackups) do
        if not v.created or GetServerTime() - v.created > 518400 then
            d.layerMapBackups[k] = nil
        end
    end
end

------------------------------------------------------------------------
-- Timer log (rend layer attribution shared around the network)
------------------------------------------------------------------------
function WBT:ValidateCloseLogEntries(shortKey, timestamp, layer, cooldown)
    local d = self:Data()
    if not d then return end
    local count = 0
    for _, v in ipairs(d.timerLog) do
        if v.type == shortKey and (v.layerID == layer or not layer) then
            count = count + 1
            if not (timestamp > (v.timestamp + cooldown) or timestamp < (v.timestamp - cooldown)) then
                return false
            end
            if count >= 20 then break end
        end
    end
    return true
end

function WBT:TimerLog(logType, timestamp, layer, who, forceSend, distribution)
    if not self:IsLayered() then return end
    local d = self:Data()
    if not d then return end
    if logType == "r" then logType = "rendTimer"
    elseif logType == "o" then logType = "onyTimer"
    elseif logType == "n" then logType = "nefTimer" end
    if not ((logType == "rendTimer" or logType == "q") and tonumber(timestamp)) then
        return -- rend-only logging, matching current network behaviour
    end
    local shortKey = (logType == "rendTimer") and "r" or logType
    local newQuestHandIn
    if ((d.layers[layer] and (d.layers[layer][logType] or logType == "q"))
            or (not self:IsLayered() and d[logType]))
            and self:ValidateCloseLogEntries(shortKey, timestamp, layer, 60)
            and self:ValidateTimestamp(timestamp) then
        local t = { type = shortKey, timestamp = timestamp }
        if who then t.who = who end
        if layer then t.layerID = layer end
        table.insert(d.timerLog, 1, t)
        if logType == "q" then newQuestHandIn = true end
    end
    if ((distribution ~= "GUILD" and newQuestHandIn) or forceSend) and self:CanSend() then
        if not self._logPushQueued then
            self._logPushQueued = true
            C_Timer.After(2, function()
                self._logPushQueued = nil
                if WBT.Comms and WBT.Comms.SendTimerLogData then
                    WBT.Comms:SendTimerLogData("GUILD")
                end
            end)
        end
    end
end

-- Caps the log at 50 entries and drops anything without a layerID, so an
-- entry logged while no layer was known does not survive the next trim.
function WBT:TrimTimerLog()
    local d = self:Data()
    if not d then return end
    if type(d.timerLog) ~= "table" then d.timerLog = {} end
    for i = #d.timerLog, 1, -1 do
        local v = d.timerLog[i]
        if i > 50 or not v or not v.type or not v.timestamp or not v.layerID then
            table.remove(d.timerLog, i)
        end
    end
end

------------------------------------------------------------------------
-- DMF fortune cooldown (per character, absolute epoch)
------------------------------------------------------------------------
-- 14400 = the 4h Sayge's fortune lockout. Per character, not per account,
-- and stored as an absolute epoch so it survives relog.
function WBT:SetDmfCooldown(seconds)
    local c = self:CharData()
    if not c then return end
    c.dmfCooldownUntil = GetServerTime() + (seconds or 14400)
    self:Debug("DMF cooldown set: " .. tostring(seconds or 14400) .. "s")
end

function WBT:GetSelfDMFRemaining()
    local c = self:CharData()
    if not c or not c.dmfCooldownUntil then return nil end
    local rem = c.dmfCooldownUntil - GetServerTime()
    if rem <= 0 then return nil end
    return rem
end

------------------------------------------------------------------------
-- Import / mirror from the legacy addon's saved data
------------------------------------------------------------------------
local function mergeNumericNewest(dst, src, key)
    local sv = tonumber(src[key])
    if sv and sv > 0 and (not tonumber(dst[key]) or sv > dst[key]) then
        dst[key] = sv
        return true
    end
end

-- MIRROR HEALTH (2026-11-12, Zac: "how can we prevent that from happening
-- in the future if nova updates?"). While Nova World Buffs is loaded this
-- addon shows what Nova has saved, and Nova 3.48 moved where it saves it:
-- the copy found nothing, said nothing, and every songflower read "?".
-- Each copy now notes what it found - was the realm's store where it is
-- looked for, did it hold layer data, how many layers could be read - and
-- WBT:MirrorStatus() turns that into the Status card's lines, so a store
-- that has moved again shows as a warning instead of as empty timers.
local function holdsNumber(t, depth)
    for _, v in pairs(t) do
        if type(v) == "number" and v ~= 0 then return true end
        if type(v) == "table" and depth > 1 and holdsNumber(v, depth - 1) then return true end
    end
    return false
end
function WBT:MirrorStatus()
    local h = self.mirrorHealth
    local lines = {}
    if not h then return lines end
    local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local theirs = getMeta and getMeta("NovaWorldBuffs", "Version") or nil
    local newer = tonumber(theirs) and tonumber(theirs) > (tonumber(WBT.WIRE_VERSION) or 0)
    if not h.store then
        lines[#lines + 1] = { "Nova World Buffs' saved timers were not where Readycheck looks for them"
            .. (theirs and (" (Nova " .. tostring(theirs) .. ")") or "") .. ". Update Readycheck.", "warn" }
    elseif h.layerData and h.layers == 0 then
        lines[#lines + 1] = { "Nova World Buffs" .. (theirs and (" " .. tostring(theirs)) or "")
            .. " holds layer timers Readycheck could not read: its saved format has changed. Update Readycheck.", "warn" }
    elseif newer then
        lines[#lines + 1] = { "Nova World Buffs " .. tostring(theirs) .. " is newer than the " .. tostring(WBT.WIRE_VERSION)
            .. " Readycheck was checked against; its saved timers still read fine (" .. h.layers .. " layer(s)).", "ok" }
    else
        lines[#lines + 1] = { "Reading Nova World Buffs" .. (theirs and (" " .. tostring(theirs)) or "")
            .. "'s saved timers: " .. h.layers .. " layer(s).", "ok" }
    end
    return lines
end

function WBT:ImportLegacyData(verbose)
    local legacyDb = _G.NWBdatabase
    if type(legacyDb) ~= "table" or type(legacyDb.global) ~= "table" then
        if verbose then RC:Print("World Buff Timers: no legacy data found (NovaWorldBuffs not loaded this session).") end
        return false
    end
    local d = self:Data()
    local s = self:Store()
    if not d or not s then return false end
    local imported = 0
    local health = { store = false, layerData = false, layers = 0 }
    for _, factionName in ipairs({ "Horde", "Alliance" }) do
        local fd = legacyDb.global[WBT.realm] and legacyDb.global[WBT.realm][factionName]
        if type(fd) == "table" then
            health.store = true
            if type(fd.layers) == "table" and holdsNumber(fd.layers, 5) then health.layerData = true end
            s.global[WBT.realm][factionName] = s.global[WBT.realm][factionName] or {}
            local dst = s.global[WBT.realm][factionName]
            for k in pairs(WBT.validKeys) do
                if type(fd[k]) == "number" then
                    dst[k] = dst[k] or 0
                    if mergeNumericNewest(dst, fd, k) then imported = imported + 1 end
                end
            end
            if type(fd.layers) == "table" then
                dst.layers = dst.layers or {}
                for layer, lv in pairs(WBT.FlatLayers(fd.layers)) do
                    if type(layer) == "number" and type(lv) == "table" then
                        health.layers = health.layers + 1
                        dst.layers[layer] = dst.layers[layer] or {}
                        local dl = dst.layers[layer]
                        for k, v in pairs(lv) do
                            if k == "layerMap" and type(v) == "table" then
                                dl.layerMap = dl.layerMap or {}
                                for zk, zv in pairs(v) do dl.layerMap[zk] = zv end
                            elseif type(v) == "number" then
                                if k == "created" or k == "spawn" then
                                    -- Keep the earliest for these two.
                                    if not tonumber(dl[k]) or (v > 0 and (dl[k] == 0 or v < dl[k])) then
                                        dl[k] = v
                                    end
                                else
                                    dl[k] = dl[k] or 0
                                    if mergeNumericNewest(dl, lv, k) then imported = imported + 1 end
                                end
                            elseif dl[k] == nil then
                                dl[k] = v
                            end
                        end
                    end
                end
            end
            if type(fd.timerLog) == "table" and factionName == WBT.faction then
                for i = #fd.timerLog, 1, -1 do
                    local v = fd.timerLog[i]
                    if type(v) == "table" and v.type and tonumber(v.timestamp) then
                        self:TimerLog(v.type, v.timestamp, v.layerID, v.who, nil, "GUILD")
                    end
                end
            end
            -- Legacy DMF cooldowns are stored as remaining seconds.
            local chars = fd.myChars
            if type(chars) == "table" then
                for charName, cv in pairs(chars) do
                    if type(cv) == "table" then
                        for k, v in pairs(cv) do
                            if type(k) == "string" and type(v) == "number"
                                    and k:lower():find("dmf", 1, true)
                                    and (k:lower():find("cool", 1, true) or k:lower():find("cd", 1, true)) then
                                local untilEpoch
                                if v > 1000000000 then
                                    untilEpoch = v
                                elseif v > 0 and v < 1209600 then
                                    untilEpoch = GetServerTime() + v
                                end
                                if untilEpoch and untilEpoch > GetServerTime() then
                                    local key = charName .. "-" .. tostring((GetNormalizedRealmName and GetNormalizedRealmName()) or WBT.realm):gsub("%s+", "")
                                    s.chars[key] = s.chars[key] or {}
                                    local cur = s.chars[key].dmfCooldownUntil
                                    if not cur or untilEpoch > cur then
                                        s.chars[key].dmfCooldownUntil = untilEpoch
                                        imported = imported + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    s.imported[WBT.realm .. "-" .. WBT.faction] = GetServerTime()
    dataCache = nil
    -- (said once a session, the first time a copy comes back wrong)
    self.mirrorHealth = health
    if (not health.store or (health.layerData and health.layers == 0)) and not self._mirrorTold then
        self._mirrorTold = true
        RC:Print("World Buff Timers: Nova World Buffs' saved timers could not be read - its format has changed. "
            .. "Timers may be missing until Readycheck is updated.")
    end
    if verbose then
        RC:Print("World Buff Timers: imported/refreshed " .. imported .. " value(s) from legacy data.")
    end
    self:Debug("import merged " .. imported .. " values")
    return true
end

------------------------------------------------------------------------
-- Reads used by the WorldBuffSync hooks
------------------------------------------------------------------------
-- A timestamp stays meaningful for one cooldown past the point it comes up:
-- inside that window the buff really is due, so "Ready" is honest. Beyond it
-- the record is just old and tells us nothing, so it is dropped rather than
-- clamped to 0 - otherwise one stale layer entry wins the minimum forever and
-- pins the display to "Ready" no matter what the live timers say.
local function isStale(t, cd)
    return (GetServerTime() - t) > (cd * 2)
end
WBT.IsTimestampStale = isStale

-- Rend reaches every layer at once (sharedLayerBuffs), so one drop resets
-- its cooldown everywhere and the only stamp that means anything is the
-- NEWEST one. Taking the soonest across layers (right for Onyxia, whose
-- cooldown is per layer) let an older rend entry that had already come up
-- clamp to 0 and win, so the board read "Ready" - or an earlier drop's
-- time - while a fresh drop was still counting down; the map, which shows
-- each layer's own stamp, stayed right.
local function newestRemaining(d, field, cd)
    local newest
    local function take(t)
        t = tonumber(t)
        if t and t > 0 and (not newest or t > newest) then newest = t end
    end
    if type(d.layers) == "table" then
        for _, lyr in pairs(WBT.FlatLayers(d.layers)) do
            if type(lyr) == "table" then take(lyr[field]) end
        end
    end
    take(d[field])
    if not newest or isStale(newest, cd) then return nil end
    local rem = (newest + cd) - GetServerTime()
    if rem < 0 then rem = 0 end
    return rem
end

local function soonestRemaining(d, field, cd)
    if not d then return nil end
    if WBT.sharedLayerBuffs and field == "rendTimer" then
        return newestRemaining(d, field, cd)
    end
    local soonest
    local function consider(t)
        t = tonumber(t)
        if t and t > 0 and not isStale(t, cd) then
            local rem = (t + cd) - GetServerTime()
            if rem < 0 then rem = 0 end
            if soonest == nil or rem < soonest then soonest = rem end
        end
    end
    local newestLayer = 0
    if type(d.layers) == "table" then
        for _, lyr in pairs(WBT.FlatLayers(d.layers)) do
            local t = type(lyr) == "table" and tonumber(lyr[field]) or nil
            if t and t > newestLayer then newestLayer = t end
            if t and t > 0 and not isStale(t, cd) then
                consider(t)
            end
        end
    end
    -- The aggregate field is a candidate, not just a fallback: mesh-received
    -- timers land only top-level (the receiver cannot know which layer a
    -- remote drop happened on), and a layers-first rule hid them on layered
    -- realms. But only when it is NEWER than every layer entry - that is
    -- the one case where it describes a drop the layers do not know about.
    -- An older aggregate is just a previous drop the layers have already
    -- moved past, and letting it in made it clamp to 0 and win: the board
    -- said Onyxia was "Ready" while the map showed hours left.
    local agg = tonumber(d[field])
    if agg and agg > newestLayer then consider(agg) end
    return soonest
end
-- Shared with WorldBuffSync's NWB reader: `d` is any table with the
-- NWB-shaped fields (aggregate field + optional .layers), so both the
-- native store and a mirrored NWBdatabase faction table work.
WBT.SoonestRemaining = soonestRemaining

-- Same shape as WorldBuffSync's legacy timer reader.
--
-- Rally is the Onyxia lockout alone. It used to be min(ony, nef) because
-- both heads drop Rallying Cry, but the Head of Nefarian turn-in has no
-- cooldown on Era/Anniversary - anyone holding a head can hand it in at
-- any time. There is nothing to count down, and feeding a synthetic 8h
-- nef figure in here only ever pulled the Rally estimate earlier than the
-- one lockout that is real.
--
-- nefTimer is still received, stored and relayed for the shared NWB pool
-- (see WBT.NETWORK_PREFIX): guildies on other clients and on other
-- realm types still use it. It is simply not shown or derived from here.
function WBT:GetTimers()
    local d = self:Data()
    if not d then return nil end
    local out = {}
    local r = soonestRemaining(d, "rendTimer", WBT.rendCooldown)
    if r ~= nil then out.warchief = r end
    local o = soonestRemaining(d, "onyTimer", WBT.onyCooldown)
    if o ~= nil then out.rally = o end
    -- Soonest songflower still ON cooldown. A node whose 25 minutes have
    -- already run out is deliberately NOT reported as 0/ready: it has
    -- certainly respawned, but nothing tells us whether it is still there,
    -- and an expired pick from hours ago would otherwise read as a
    -- confident "READY" forever. No live countdown means no answer.
    local sfNext
    local function scanFlowers(tbl)
        for i = 1, 10 do
            local pick = tonumber(tbl["flower" .. i])
            if pick and pick > 0 then
                local rem = (pick + WBT.FLOWER_CD) - GetServerTime()
                if rem > 0 and (sfNext == nil or rem < sfNext) then sfNext = rem end
            end
        end
    end
    scanFlowers(d)
    if type(d.layers) == "table" then
        for _, lyr in pairs(WBT.FlatLayers(d.layers)) do
            if type(lyr) == "table" then scanFlowers(lyr) end
        end
    end
    if sfNext then out.songflower = sfNext end
    if next(out) == nil then return nil end
    return out
end

function WBT:GetFlowerTimes()
    local d = self:Data()
    if not d then return nil end
    local out, any = {}, false
    local function scan(tbl)
        for i = 1, 10 do
            local t = tonumber(tbl["flower" .. i])
            if t and t > 0 and (out[i] == nil or t > out[i]) then
                out[i] = t
                any = true
            end
        end
    end
    scan(d)
    if type(d.layers) == "table" then
        for _, lyr in pairs(WBT.FlatLayers(d.layers)) do
            if type(lyr) == "table" then scan(lyr) end
        end
    end
    if not any then return nil end
    return out
end

function WBT:GetOppOnyRemaining()
    local fd = self:OppFactionData()
    if not fd then return nil end
    return soonestRemaining(fd, "onyTimer", WBT.onyCooldown)
end

-- Kept for the network layer and for anyone reading raw nefTimer data off
-- the shared pool. NOT used for any Era/Anniversary display or estimate:
-- the Nefarian head turn-in has no cooldown there, so a remaining time
-- computed from nefCooldown describes a lockout that does not exist.
function WBT:GetNefRemaining()
    local d = self:Data()
    if not d then return nil end
    return soonestRemaining(d, "nefTimer", WBT.nefCooldown)
end

------------------------------------------------------------------------
-- Init
------------------------------------------------------------------------
local function StartTicker(name, interval, fn)
    if RC.Profiler and RC.Profiler.TrackTicker then
        return RC.Profiler:TrackTicker(name, interval, fn)
    end
    return C_Timer.NewTicker(interval, fn)
end
WBT.StartTicker = StartTicker

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function()
    WBT.loadTime = GetServerTime()
    WBT._mirroring = nil
    C_Timer.After(2, function()
        if not WBT:Store() then return end
        WBT:Settings()
        WBT:Data()
        WBT:TrimTimerLog()
        WBT:RemoveOldLayers()
        if WBT:IsMirroring() then
            WBT:ImportLegacyData(false)
            WBT._mirrorTicker = StartTicker("WorldBuffTimers:Mirror", 600, function()
                WBT:ImportLegacyData(false)
            end)
            WBT:Debug("mirror mode (NovaWorldBuffs loaded)")
        elseif WBT:Settings().enabled then
            -- Only the layer ticker starts here. Comms and Detect bring
            -- themselves up from their own PLAYER_LOGIN handlers on a
            -- longer delay (3s and 4s) that lets the client settle before
            -- the addon prefix is registered, and calling ApplyEnabledState
            -- here would pull both of those forward to 2s.
            WBT._layerTicker = StartTicker("WorldBuffTimers:LayerCleanup", 300, function()
                WBT:RemoveOldLayers()
                WBT:TrimTimerLog()
            end)
            WBT:Debug("active mode")
        else
            WBT:Debug("engine off")
        end
    end)
end)

local logoutFrame = CreateFrame("Frame")
logoutFrame:RegisterEvent("PLAYER_LOGOUT")
logoutFrame:SetScript("OnEvent", function()
    if WBT:IsMirroring() then
        pcall(function() WBT:ImportLegacyData(false) end)
    end
end)
