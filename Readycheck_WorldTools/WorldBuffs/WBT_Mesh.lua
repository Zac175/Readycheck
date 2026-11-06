------------------------------------------------------------------------
-- Readycheck - World Buff Timers over Mesh
-- Second transport for the timer store, independent of the guild timer
-- network: reaches non-guild peers, the opposite faction (BNet bridge),
-- and any account on your mesh. Runs even in mirror mode, so timers you
-- get from NovaWorldBuffs still reach your mesh peers.
--
-- Payload is one addon message (mesh sends this cmd unchunked), so the
-- encoding is compact and uses AGES in seconds rather than epochs -
-- immune to clock differences between clients.
--   kH            sender faction (H/A)
--   r<age> o<age> n<age>   rend / ony / nef drop age
--   f<idx>:<age>,...       songflower picks
--   e<realm>      sender realm (normalized, lower-case); a peer on another
--                 realm drops the message. Omitted on the yell leg, which
--                 is same-realm by nature and tight on space.
--
-- WBYELL is a separate cmd for pull-timer yells, which the timer store
-- cannot express (seconds-long warnings, not cooldowns).
--   b<key>  rend/rendCrossroads/ony/nef/zan   a<age>  since the yell
--   l<num>  layer      x<arg>  zan "50" variant      kH  faction
--   e<realm>  as above
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end
local RC = _G.Readycheck
if not RC or not RC.WorldBuffTimers then return end
local WBT = RC.WorldBuffTimers

WBT.Mesh = WBT.Mesh or {}
local Mesh = WBT.Mesh

local GetServerTime = GetServerTime
local math_floor = math.floor

local CMD = "WBTIME"
local YELL_CMD = "WBYELL"
-- FLOWER_CD: songflower node respawn. HEARTBEAT: resend interval when the
-- payload has not changed, so a peer that just logged in still gets timers.
-- MIN_SEND_GAP: floor between any two broadcasts, however many local events
-- fire. FRESH_DROP: an inbound timer older than this merges silently -
-- only a genuinely new drop is worth an alert.
local FLOWER_CD = WBT.FLOWER_CD or 1500
local HEARTBEAT = 300
local MIN_SEND_GAP = 8
local FRESH_DROP = 120

-- Longest pull timer is Zandalar's ~50s; past that a relay is only noise.
local MAX_YELL_AGE = 60
-- Stops a yell arriving on both GUILD and RAID going out to mesh twice.
local YELL_SEND_GAP = 30

local YELL_KEYS = {
    rend = true, rendCrossroads = true, ony = true, nef = true, zan = true,
}

-- cd reads WBT.rendCooldown / onyCooldown / nefCooldown (3h / 6h / 8h)
-- rather than re-hardcoding them. An age at or past the cooldown is
-- dropped on both encode and decode, so an expired timer never travels.
local TIMER_FIELDS = {
    { code = "r", field = "rendTimer", cd = WBT.rendCooldown or 10800, alert = "rend" },
    { code = "o", field = "onyTimer",  cd = WBT.onyCooldown  or 21600, alert = "ony"  },
    { code = "n", field = "nefTimer",  cd = WBT.nefCooldown  or 28800, alert = "nef"  },
}
local CODE_TO_FIELD = {}
for _, t in ipairs(TIMER_FIELDS) do CODE_TO_FIELD[t.code] = t end

local function meshOn()
    return RC.MeshSync and RC.MeshSync.IsEnabled and RC.MeshSync:IsEnabled()
end

-- Realm as it travels on the wire: normalized (no spaces), lower-cased.
-- Timers are per realm, and BNet peers can sit on any realm.
local function myRealmToken()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or WBT.realm or ""
    return (string.lower(tostring(realm)):gsub("%s+", ""))
end

local function sameRealm(token)
    if not token or token == "" then return true end
    if string.lower(token) == myRealmToken() then return true end
    -- Connected realms share the world and its timers (Comms keeps the set).
    local C = WBT.Comms
    return (C and C.IsOurRealm and C:IsOurRealm(token)) and true or false
end

local function enabled()
    local s = WBT:Settings()
    return s.enabled and s.meshSync ~= false
end

-- Newest value for a field across layers, falling back to the top level.
local function newestTimer(d, field)
    local best
    if type(d.layers) == "table" then
        for _, lyr in pairs(d.layers) do
            local t = tonumber(lyr[field])
            if t and t > 0 and (not best or t > best) then best = t end
        end
    end
    local top = tonumber(d[field])
    if top and top > 0 and (not best or top > best) then best = top end
    return best
end

-- Returns the wire payload AND a change signature. The payload carries
-- AGES, which tick every second - two payloads built a second apart never
-- compare equal, so the old "unchanged payload" heartbeat suppression
-- never fired. The signature is built from the underlying STAMPS, which
-- only move when something actually happened.
function Mesh:Encode()
    local d = WBT:Data()
    if not d then return nil end
    local now = GetServerTime()
    local parts = { "k" .. ((WBT.faction == "Horde") and "H" or "A") }
    local sig = {}

    for _, t in ipairs(TIMER_FIELDS) do
        local stamp = newestTimer(d, t.field)
        if stamp then
            local age = now - stamp
            if age >= 0 and age < t.cd then
                parts[#parts + 1] = t.code .. math_floor(age)
                sig[#sig + 1] = t.code .. stamp
            end
        end
    end

    local flowers = WBT:GetFlowerTimes()
    if flowers then
        local fp = {}
        for idx = 1, 10 do
            local stamp = flowers[idx]
            if stamp then
                local age = now - stamp
                if age >= 0 and age < FLOWER_CD then
                    fp[#fp + 1] = idx .. ":" .. math_floor(age)
                    sig[#sig + 1] = "f" .. idx .. ":" .. stamp
                end
            end
        end
        if #fp > 0 then
            parts[#parts + 1] = "f" .. table.concat(fp, ",")
        end
    end

    if #parts <= 1 then return nil end
    -- Realm goes last so an older decoder simply stops at a token it does
    -- not know. Third value is the realm-less copy for the yell leg.
    local yellPayload = table.concat(parts, ";")
    return yellPayload .. ";e" .. myRealmToken(), table.concat(sig, ";"), yellPayload
end

function Mesh:Decode(data)
    if type(data) ~= "string" or data == "" then return nil end
    local out = { timers = {}, flowers = {} }
    for tok in string.gmatch(data, "[^;]+") do
        local head = string.sub(tok, 1, 1)
        local body = string.sub(tok, 2)
        if head == "k" then
            out.faction = (body == "H") and "Horde" or "Alliance"
        elseif head == "e" then
            out.realm = body
        elseif head == "f" then
            for pair in string.gmatch(body, "[^,]+") do
                local idx, age = string.match(pair, "^(%d+):(%d+)$")
                idx, age = tonumber(idx), tonumber(age)
                if idx and age and idx >= 1 and idx <= 10 and age < FLOWER_CD then
                    out.flowers[idx] = age
                end
            end
        else
            local def = CODE_TO_FIELD[head]
            local age = tonumber(body)
            if def and age and age >= 0 and age < def.cd then
                out.timers[def.field] = age
            end
        end
    end
    if not out.faction then return nil end
    return out
end

-- Faction table for merging; creates the opposite-faction side on demand
-- so a cross-faction peer's Ony time has somewhere to land.
local function factionData(faction)
    if faction == WBT.faction then return WBT:Data() end
    local s = WBT:Store()
    if not s then return nil end
    s.global[WBT.realm] = s.global[WBT.realm] or {}
    local rd = s.global[WBT.realm]
    rd[faction] = rd[faction] or {}
    local fd = rd[faction]
    fd.layers = fd.layers or {}
    for _, t in ipairs(TIMER_FIELDS) do
        if fd[t.field] == nil then fd[t.field] = 0 end
    end
    for i = 1, 10 do
        local fk = "flower" .. i
        if fd[fk] == nil then fd[fk] = 0 end
    end
    return fd
end

function Mesh:OnInbound(from, sender, data, viaBNet)
    if not enabled() then return end
    local parsed = self:Decode(data)
    if not parsed then return end
    if not sameRealm(parsed.realm) then
        WBT:Debug("mesh timers from " .. tostring(sender) .. " ignored (realm "
            .. tostring(parsed.realm) .. ")")
        return
    end
    local d = factionData(parsed.faction)
    if not d then return end
    local now = GetServerTime()
    local sameFaction = (parsed.faction == WBT.faction)
    local newDrops = {}

    for _, t in ipairs(TIMER_FIELDS) do
        local age = parsed.timers[t.field]
        if age then
            local stamp = now - age
            if WBT:ValidateTimestamp(stamp) then
                local mine = newestTimer(d, t.field) or 0
                -- Only accept a strictly newer drop, and ignore anything
                -- inside the 25s window where two clients saw the same drop.
                if stamp > mine + 25 then
                    d[t.field] = stamp
                    if age < FRESH_DROP and sameFaction then
                        newDrops[#newDrops + 1] = t.alert
                    end
                    WBT:Debug("mesh timer " .. t.field .. " from "
                        .. tostring(sender) .. " (" .. math_floor(age) .. "s ago)")
                end
            end
        end
    end

    -- Songflower nodes are shared ground spawns: merge from either faction.
    local own = WBT:Data()
    if own then
        for idx, age in pairs(parsed.flowers) do
            local stamp = now - age
            local fk = "flower" .. idx
            local mine = tonumber(own[fk]) or 0
            -- 10s: two clients reporting the same pick differ only by relay
            -- delay, so anything closer than that is not a newer pick.
            if stamp > mine + 10 and WBT:ValidateTimestamp(stamp) then
                own[fk] = stamp
            end
        end
    end

    if WBT.Detect and WBT.Detect.OnBuffDropMsg then
        for _, key in ipairs(newDrops) do
            WBT.Detect:OnBuffDropMsg(key, nil, sender)
        end
    end
end

------------------------------------------------------------------------
-- Incoming-buff yells (pull timers)
------------------------------------------------------------------------
local lastYellSent = {}

function Mesh:EncodeYell(msgType, age, layer, arg)
    if not YELL_KEYS[msgType] then return nil end
    age = tonumber(age) or 0
    if age < 0 then age = 0 end
    if age > MAX_YELL_AGE then return nil end
    local parts = {
        "b" .. msgType,
        "a" .. math_floor(age),
        "k" .. ((WBT.faction == "Horde") and "H" or "A"),
    }
    -- No layer field. A layer NUMBER is only the sort position in the
    -- SENDER's layer table (see WBT:GetLayerNum); a mesh peer, often on
    -- another account or faction, holds a different table, so the number
    -- rendered on their side was confidently wrong. DecodeYell still
    -- parses "l" from older peers, but OnInboundYell discards it.
    if arg and arg ~= "" and not string.find(tostring(arg), ";", 1, true) then
        parts[#parts + 1] = "x" .. tostring(arg)
    end
    -- Realm last: older decoders skip tokens they do not know.
    parts[#parts + 1] = "e" .. myRealmToken()
    return table.concat(parts, ";")
end

function Mesh:DecodeYell(data)
    if type(data) ~= "string" or data == "" then return nil end
    local out = {}
    for tok in string.gmatch(data, "[^;]+") do
        local head = string.sub(tok, 1, 1)
        local body = string.sub(tok, 2)
        if head == "b" then
            if YELL_KEYS[body] then out.key = body end
        elseif head == "a" then
            out.age = tonumber(body)
        elseif head == "k" then
            out.faction = (body == "H") and "Horde" or "Alliance"
        elseif head == "l" then
            out.layer = tonumber(body)
        elseif head == "x" then
            out.arg = body
        elseif head == "e" then
            out.realm = body
        end
    end
    if not out.key or not out.faction then return nil end
    if not out.age or out.age < 0 or out.age > MAX_YELL_AGE then return nil end
    return out
end

-- Data observed inside a battleground or arena describes the cross-realm
-- instance world, not the realm the peers are on - the guild path
-- (Comms:SendComm) already refuses to send from there.
local function inPvPInstance()
    if UnitInBattleground and UnitInBattleground("player") then return true end
    if IsActiveBattlefieldArena and IsActiveBattlefieldArena() then return true end
    return false
end

-- Callers must never forward a mesh-sourced yell back in; that is the
-- only thing stopping an echo loop.
function Mesh:SendYell(msgType, age, layer, arg)
    if not enabled() or not meshOn() then return end
    if inPvPInstance() then return end
    local MS = RC.MeshSync
    if not MS or not MS.Broadcast then return end
    if not YELL_KEYS[msgType] then return end
    local now = GetServerTime()
    if lastYellSent[msgType] and (now - lastYellSent[msgType]) < YELL_SEND_GAP then
        return
    end
    local payload = self:EncodeYell(msgType, age, layer, arg)
    if not payload then return end
    lastYellSent[msgType] = now
    if MS.SetNextSendPriority then MS:SetNextSendPriority() end
    MS:Broadcast(YELL_CMD, payload)
    if MS.CrossFactionWhisper then
        -- Own dedup slot: every caller that omits the key shares "_self",
        -- so WBYELL and WBTIME used to clobber each other's stored
        -- signature (and WorldBuffSync's WBUFF too), breaking all three
        -- commands' change suppression.
        MS:CrossFactionWhisper(YELL_CMD, payload, payload, "wbyell")
    end
    WBT:Debug("mesh yell sent: " .. payload)
end

function Mesh:OnInboundYell(from, sender, data, viaBNet)
    if not enabled() then return end
    local p = self:DecodeYell(data)
    if not p then return end
    if not sameRealm(p.realm) then
        WBT:Debug("mesh yell from " .. tostring(sender) .. " ignored (realm "
            .. tostring(p.realm) .. ")")
        return
    end
    -- Rend/Ony/Nef bars are keyed off the RECEIVER's faction, so a
    -- cross-faction yell would start a bar for a buff that isn't coming.
    -- Zandalar is one shared world event.
    if p.faction ~= WBT.faction and p.key ~= "zan" then return end
    local epoch = GetServerTime() - p.age
    if not WBT:ValidateTimestamp(epoch) then return end
    if WBT.Detect and WBT.Detect.OnRelayedYell then
        -- p.layer deliberately dropped: a layer index from another client's
        -- table means nothing here (see EncodeYell).
        WBT.Detect:OnRelayedYell(p.key, nil, "MESH", p.arg, sender, epoch)
    end
    WBT:Debug("mesh yell " .. p.key .. " from " .. tostring(sender)
        .. " (" .. p.age .. "s ago)")
end

-- Returns true when a payload actually went out, false when the send was
-- suppressed by the MIN_SEND_GAP / unchanged-signature gates - Nudge uses
-- the distinction to reschedule instead of dropping the event.
function Mesh:Broadcast(force)
    if not enabled() or not meshOn() then return false end
    if inPvPInstance() then return false end
    local MS = RC.MeshSync
    if not MS.Broadcast then return false end
    local now = GetServerTime()
    if not force and self._lastSend and (now - self._lastSend) < MIN_SEND_GAP then
        return false
    end
    local payload, sig, yellPayload = self:Encode()
    if not payload then return true end -- nothing to say is not "suppressed"
    -- Signature, not payload: the payload carries ages that tick every
    -- second, so payload equality never held and this gate was dead code.
    if not force and sig == self._lastSig
            and self._lastSend and (now - self._lastSend) < HEARTBEAT then
        return true
    end
    self._lastSend = now
    self._lastSig  = sig
    if MS.SetNextSendPriority then MS:SetNextSendPriority() end
    -- The yell leg base64-inflates header+payload 4/3 against the 255 byte
    -- cap; a full flower set plus a long realm name would not fit, so the
    -- realm-less copy rides there (a /yell never leaves the realm anyway).
    MS:Broadcast(CMD, payload, nil, nil, yellPayload)
    if MS.CrossFactionWhisper then
        MS:CrossFactionWhisper(CMD, payload, payload, "wbtime")
    end
    WBT:Debug("mesh broadcast: " .. payload)
    return true
end

-- Called by the timer setters and songflower picks so a local event
-- propagates immediately instead of waiting for the heartbeat. When the
-- broadcast lands inside MIN_SEND_GAP it re-arms rather than dropping the
-- event on the floor - a songflower picked 3s after a rend drop used to
-- wait for the 300s heartbeat.
function Mesh:Nudge()
    if not enabled() then return end
    if self._nudgeQueued then return end
    self._nudgeQueued = true
    C_Timer.After(2, function()
        self._nudgeQueued = nil
        if not Mesh:Broadcast() then
            local wait = MIN_SEND_GAP
            if Mesh._lastSend then
                local elapsed = GetServerTime() - Mesh._lastSend
                wait = math.max(1, MIN_SEND_GAP - elapsed + 1)
            end
            if not Mesh._nudgeQueued then
                Mesh._nudgeQueued = true
                C_Timer.After(wait, function()
                    Mesh._nudgeQueued = nil
                    Mesh:Broadcast()
                end)
            end
        end
    end)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
-- 12s after login: the mesh needs its peers connected and the store loaded
-- before the first broadcast, otherwise we advertise an empty payload.
f:SetScript("OnEvent", function()
    C_Timer.After(12, function()
        if not enabled() then
            WBT:Debug("mesh timer sync disabled")
            return
        end
        Mesh:Start()
    end)
end)

-- Live on/off, driven by WBT:ApplyEnabledState. Broadcast already refuses
-- to send while disabled, so this exists to stop the heartbeat idling
-- rather than to prevent traffic. Both are idempotent.
function Mesh:Start()
    if Mesh._ticker or not enabled() then return end
    Mesh:Broadcast(true)
    Mesh._ticker = WBT.StartTicker("WorldBuffTimers:MeshSync", HEARTBEAT, function()
        Mesh:Broadcast()
    end)
    WBT:Debug("mesh timer sync active")
end

function Mesh:Stop()
    if not Mesh._ticker then return end
    Mesh._ticker:Cancel()
    Mesh._ticker = nil
    WBT:Debug("mesh timer sync stopped")
end
