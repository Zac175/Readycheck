------------------------------------------------------------------------
-- Readycheck - World Buff Sync
-- Broadcasts this character's world buffs over the mesh, caches what it
-- hears in ReadycheckDB.worldBuffCache, and relays cached peers onward.
-- Peer record WB.peers[<lowercase name-realm>]: buffs = key -> seconds
-- left AS OF t; frozen = the keys chronoboon-stored, which do not tick;
-- booned, class, cd, hs, chrono, gold, pvp, location, dmfRem, level,
-- race; t = the server time every remaining value in the record is
-- measured from; own = true when this record is our own write.
-- Staleness windows and send gating are the constants near the top.
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end

-- Taint-safe API locals (fallbacks on RC.Compat, built in Core;
-- never write _G - a written Blizzard global taints its readers)
local RCC = _G.Readycheck
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)

local function InitializeWorldBuffSync()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializeWorldBuffSync) return end
    if not RC.db then C_Timer.After(0.2, InitializeWorldBuffSync) return end

    local RCC = _G.Readycheck
    local UnitBuff     = UnitBuff or (RCC and RCC.Compat and RCC.Compat.UnitBuff)
    local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)
    -- Buff slot i from the shared aura read (RC.Auras).
    local function ReadBuff(i)
        local a = RC.Auras:Buffs()[i]
        if not a then return nil end
        return a.name, a.duration, a.expirationTime, a.spellId
    end

    -- Full duration of each buff in seconds, used only as a sanity ceiling
    -- on inbound claims - a peer running a broken build can otherwise pin a
    -- roster row to a buff that never expires.
    local BUFF_MAX_SECS = {
        warchief = 3600, songflower = 3600,
        rally = 7200, zandalar = 7200,
        fengus = 7200, moldar = 7200, slipkik = 7200,
        sayges = 7200, dmf = 7200, ony = 3600,
    }
    -- 300s of slack absorbs clock skew and transit delay between peers.
    local function DurOk(key, secs)
        if type(secs) ~= "number" or secs <= 0 then return false end
        return secs <= ((BUFF_MAX_SECS[key] or 7200) + 300)
    end

    local GetTime    = GetTime
    local time       = time
    local GetSpellInfo = GetSpellInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetSpellInfo)
    local math_floor = math.floor
    local math_max   = math.max

    RC.WorldBuffs = RC.WorldBuffs or {}
    local WB = RC.WorldBuffs

    if ReadycheckDB then
        ReadycheckDB.worldBuffCache = ReadycheckDB.worldBuffCache or {}
        WB.peers = ReadycheckDB.worldBuffCache
        WB._loadedCounts = {}
        for k, p in pairs(WB.peers) do
            local n = 0
            if p.buffs then for _ in pairs(p.buffs) do n = n + 1 end end
            WB._loadedCounts[k] = n
        end
    else
        WB.peers = WB.peers or {}
    end

    -- Peers that came back but could not be whispered a catch-up at that
    -- moment (key -> how far back it has to reach). Session only.
    WB._returnSince = {}

    if ReadycheckDB then
        ReadycheckDB.worldBuffDrops = ReadycheckDB.worldBuffDrops or {}
        WB.dropLog = ReadycheckDB.worldBuffDrops
    else
        WB.dropLog = WB.dropLog or {}
    end
    WB.dropLog.flowers = WB.dropLog.flowers or {}

    if ReadycheckDB then
        ReadycheckDB.worldBuffRemovals = ReadycheckDB.worldBuffRemovals or {}
        WB.removals = ReadycheckDB.worldBuffRemovals
    else
        WB.removals = WB.removals or {}
    end

    -- Supercharged Chronoboon Displacer aura ids (both client variants).
    local STORED_IDS = {
        [349981] = true,
        [349977] = true,
    }
    -- 184937 = Chronoboon Displacer (empty), 184938 = Supercharged.
    local CHRONO_ITEM_IDS = {
        [184937] = true,
        [184938] = true,
    }

    -- HEARTBEAT: seconds between heartbeat passes; a pass only sends when
    -- the signature moved or the last full send is over 300s old.
    -- ONLINE_WINDOW: seconds since record.t within which a peer counts as
    -- online. GC_MAX: 14 days, after which a cached peer is dropped.
    -- RELAY_MIN_INTERVAL: floor between unforced roster relays.
    -- RELAY_NEW_PEER_DELAY: base delay before relaying to a new peer, plus
    -- random jitter, so a raid loading in does not relay in unison.
    -- RELAY_PRESENCE_TTL: how long a relayed online flag stays trusted.
    local HEARTBEAT     = 30
    local ONLINE_WINDOW = 90
    local GC_MAX        = 1209600
    local RELAY_MIN_INTERVAL   = 600
    local RELAY_MAX_PER_PASS   = 8     -- peers relayed per pass, oldest first
    local WB_MIN_SEND_GAP      = 8     -- floor between own state broadcasts
    local RELAY_NEW_PEER_DELAY = 8
    local RELAY_PRESENCE_TTL   = 300
    -- RETURN_GAP: silence after which a peer heard again counts as having
    -- been away. Same length as the mesh's own ACCOUNT_TIMEOUT: a peer
    -- draining a long transfer to someone else skips its 60s HELLOs, and
    -- must not look like a relog to everybody it is not sending to.
    -- CATCHUP_DELAY: wait before whispering a returning peer what it
    -- missed, plus jitter. CATCHUP_MAX: records sent in one catch-up.
    -- RELAY_QUEUE_MAX: the longest a relay is believed to have sat in the
    -- sender's queue; an exact age further out than that is not trusted.
    -- LONG_SHOUT_SECS: a Battle Shout this long is the one worth showing.
    local RETURN_GAP           = 300
    local CATCHUP_DELAY        = 6
    local CATCHUP_MAX          = 16
    local RELAY_QUEUE_MAX      = 900
    local LONG_SHOUT_SECS      = 300

    -- Presence epoch: p.seenAt is stamped by HELLO/BYE and every direct
    -- write, p.t only by a data write. Online/stale/GC decisions read this;
    -- buff, cooldown and DMF ageing must keep subtracting from p.t.
    local function LastSeen(p)
        return math_max(p.seenAt or 0, p.t or 0)
    end

    -- A peer that said BYE is offline at once; anyone else is offline
    -- once the online window has passed without a word from them.
    local function PeerOffline(p, now)
        local last = LastSeen(p)
        if p.byeAt and p.byeAt >= last then return true end
        return (now - last) > ONLINE_WINDOW
    end

    -- True while we can hear a peer for ourselves: a direct sighting
    -- inside the online window and no BYE since. Unlike PeerOffline this
    -- reads seenAt alone - a relayed record's data time is not a sighting.
    local function HeardDirectly(p, now)
        local seen = p.seenAt
        if not seen or (now - seen) > ONLINE_WINDOW then return false end
        return not (p.byeAt and p.byeAt >= seen)
    end

    local DROP_TRACK = {
        { key = "warchief",   code = "W", label = RCL["Rend"],       cd = 3 * 3600, dur = 3600, id = 16609 },
        { key = "rally",      code = "R", label = RCL["Onyxia"],     cd = 6 * 3600, dur = 7200, id = 22888 },
        { key = "songflower", code = "S", label = RCL["Songflower"], cd = 25 * 60,  dur = 3600, id = 15366 },
    }
    local DROP_DUR, DROP_CD = {}, {}
    for _, d in ipairs(DROP_TRACK) do DROP_DUR[d.key] = d.dur; DROP_CD[d.key] = d.cd end

    -- Turn-in tracking. The head/heart quests are one-time per character,
    -- so "dropped" is the completion flag of the step that lands the buff
    -- (the herald hand-in), and "can still drop" is that flag being clear.
    -- A head or heart in the bags means the toon is ready to do it now.
    -- Codes live only inside the "t"/"u" wire tokens (own namespace).
    local TURNINS = {
        { key = "ony",  code = "O", label = RCL["Onyxia"],   items = { 18422, 18423 }, quests = { 7491, 7496 } },
        { key = "nef",  code = "N", label = RCL["Nefarian"], items = { 19003, 19002 }, quests = { 7782, 7784 } },
        { key = "zan",  code = "Z", label = RCL["Zandalar"], items = { 19802 },        quests = { 8183 } },
        { key = "rend", code = "R", label = RCL["Rend"],     items = { 18646 },        quests = { 4974 }, horde = true },
    }
    local TURNIN_BY_CODE, TURNIN_BY_QUEST = {}, {}
    for _, d in ipairs(TURNINS) do
        TURNIN_BY_CODE[d.code] = d
        for _, q in ipairs(d.quests) do TURNIN_BY_QUEST[q] = d end
    end
    WB.TURNINS = TURNINS

    local QuestDone = (C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted) or IsQuestFlaggedCompleted
    -- Set of turn-in keys this character has already completed.
    local function ReadDropped()
        if not QuestDone then return nil end
        local done
        for _, d in ipairs(TURNINS) do
            for _, q in ipairs(d.quests) do
                if QuestDone(q) then
                    done = done or {}
                    done[d.key] = true
                    break
                end
            end
        end
        return done
    end

    local function ReadHeads()
        if not GetItemCount then return nil end
        local heads
        for _, d in ipairs(TURNINS) do
            for _, id in ipairs(d.items) do
                if (GetItemCount(id) or 0) > 0 then
                    heads = heads or {}
                    heads[d.key] = true
                    break
                end
            end
        end
        return heads
    end

    -- Codes in TURNINS order for a key set (heads held or drops done).
    local function HeadsCodes(set)
        if not set then return "" end
        local out = {}
        for _, d in ipairs(TURNINS) do
            if set[d.key] then out[#out + 1] = d.code end
        end
        return table.concat(out)
    end

    -- uiMapID for Felwood; the node coordinates are that map's 0-100
    -- space, and NearestFlowerNode only matches within 3.0 map units.
    -- Node data is owned by WBT_Core (WBT.songFlowers, loaded earlier in
    -- this addon's .toc): build the index-keyed 1..10 list this file's
    -- callers expect straight from it instead of keeping a second copy.
    local FELWOOD_MAP  = 1448
    local FLOWER_NODES = {}
    for _, node in pairs(RC.WorldBuffTimers.songFlowers) do
        FLOWER_NODES[node.idx] = { x = node.x, y = node.y, name = node.name }
    end
    local function NearestFlowerNode()
        if not C_Map or not C_Map.GetBestMapForUnit then return nil end
        if C_Map.GetBestMapForUnit("player") ~= FELWOOD_MAP then return nil end
        local pos = C_Map.GetPlayerMapPosition(FELWOOD_MAP, "player")
        if not pos then return nil end
        local px, py
        if pos.GetXY then px, py = pos:GetXY() else px, py = pos.x, pos.y end
        if not px then return nil end
        px, py = px * 100, py * 100
        local bestIdx, bestD = nil, 3.0
        for i, n in ipairs(FLOWER_NODES) do
            local dx, dy = px - n.x, py - n.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d < bestD then bestD = d; bestIdx = i end
        end
        return bestIdx
    end

    local function NormKey(s)
        if type(s) ~= "string" then return s end
        return string.lower(s)
    end

    -- Every cache key is lowercased "name-realm" with realm whitespace
    -- stripped. Keys arrive from three sources (self, direct broadcast,
    -- relay) and must normalize identically or the same character shows
    -- up as two roster rows.
    local function LocalKey()
        local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
            or (GetRealmName and GetRealmName()) or ""
        realm = tostring(realm):gsub("%s+", "")
        return NormKey((UnitName("player") or "?") .. "-" .. realm)
    end

    -- code is the single wire character for this buff and must stay stable
    -- across versions - it is the whole encoding. slot is the aura return
    -- position the chronoboon stores this buff's remaining time in, and its
    -- presence also marks a buff as chronoboonable; name is replaced at
    -- load by the client's localized name for exact-name aura matching,
    -- while tipName keeps the English string the boon TOOLTIP prints.
    local BUFFS = {
        { key = "rally",      code = "R", slot = 20, ids = { 22888 }, name = "Rallying Cry of the Dragonslayer", short = "Rally" },
        { key = "warchief",   code = "W", slot = 21, ids = { 16609 }, name = "Warchief's Blessing",             short = "WCB" },
        { key = "zandalar",   code = "Z", slot = 22, ids = { 24425 }, name = "Spirit of Zandalar",              short = "ZG" },
        { key = "songflower", code = "S", slot = 23, ids = { 15366 }, name = "Songflower Serenade",             short = "Song" },
        { key = "fengus",     code = "F", slot = 17, ids = { 22817 }, name = "Fengus' Ferocity",                short = "Fengus" },
        { key = "moldar",     code = "M", slot = 18, ids = { 22818 }, name = "Mol'dar's Moxie",                 short = "Mol'dar" },
        { key = "slipkik",    code = "K", slot = 19, ids = { 22820 }, name = "Slip'kik's Savvy",                short = "Slip'kik" },
        { key = "sayges",     code = "Y", slot = 24, ids = { 23735, 23736, 23737, 23738, 23766, 23767, 23768, 23769 }, name = "Sayge's Dark Fortune", short = "DMF" },
        { key = "firefort", code = "T", ids = { 29235 }, name = "Fire Festival Fortitude", short = "FF Stam", festival = true },
        { key = "firefury", code = "U", ids = { 29338 }, name = "Fire Festival Fury",      short = "FF Crit", festival = true },
        { key = "battleshout", code = "B", ids = { 6673 }, name = "Battle Shout", short = "BS" },
    }

    local ID_TO_KEY  = {}
    local CODE_TO_KEY = {}
    local NAME_TO_KEY = {}
    local DEF_BY_KEY = {}
    for _, def in ipairs(BUFFS) do
        DEF_BY_KEY[def.key]  = def
        CODE_TO_KEY[def.code] = def.key
        for _, id in ipairs(def.ids) do ID_TO_KEY[id] = def.key end
        def.icon = select(3, GetSpellInfo(def.ids[1]))
        local resolvedName = GetSpellInfo(def.ids[1])
        def.tipName = def.tipName or def.name
        if resolvedName then def.name = resolvedName end
        NAME_TO_KEY[def.name] = def.key
    end

    local MAJOR_CITIES = {
        ["Orgrimmar"] = true, ["Thunder Bluff"] = true, ["Undercity"] = true,
        ["Stormwind City"] = true, ["Stormwind"] = true, ["Ironforge"] = true,
        ["Darnassus"] = true,
    }
    -- Sayge's fortune re-roll lockout is 4h from taking the fortune.
    -- A peer parked in a capital for 8h has certainly used theirs, so the
    -- stale lockout is dropped rather than shown as still counting.
    local DMF_LOCK_DUR  = 4 * 3600
    local DMF_CITY_FALL = 8 * 3600

    -- Fire Festival auras carry no usable spellId on some clients, so they
    -- are matched on the exact English aura name as well.
    NAME_TO_KEY["Fire Festival Fortitude"] = "firefort"
    NAME_TO_KEY["Fire Festival Fury"]      = "firefury"

    WB.BUFFS = BUFFS

    local function EnsureDB()
        if not RC.db.worldBuffs then RC.db.worldBuffs = {} end
        local db = RC.db.worldBuffs
        if not db._defaultsV2 then
            db._defaultsV2 = true
            db.enabled = true
        end
        if db.enabled == nil then db.enabled = true end
        db.sortMode  = nil
        db.showStale = nil
        db.miniScale = nil
    end

    function WB:BuildAuraSnapshot()
        local booned, boonIndex, boonSig = false, nil, 0
        for i = 1, 40 do
            local name, _, exp, sid = ReadBuff(i)
            if not name then break end
            if (sid and STORED_IDS[sid])
               or name == "Supercharged Chronoboon Displacer" then
                booned = true
                boonIndex = i
                boonSig = math_floor(exp or 0)
                break
            end
        end

        local buffs = {}
        local frozen = {}

        if not booned and GetItemCount and (GetItemCount(184938) or 0) > 0 then
            booned = true
        end

        -- Chronoboon-stored buffs are readable only from the tooltip text of
        -- the aura or the bag item; the remaining time is parsed out of the
        -- 48 characters that follow the exact buff name. The curly
        -- apostrophe is folded to a plain one first so "Fengus' Ferocity"
        -- and "Mol'dar's Moxie" match the names in BUFFS.
        local function ParseTipInto(lines)
            if type(lines) ~= "table" then return end
            for li = 1, #lines do
                local text = lines[li].text
                if text and text ~= "" then
                    text = text:gsub("\226\128\153", "'")
                    local matchedKey
                    for _, def in ipairs(BUFFS) do
                        if def.slot and not buffs[def.key]
                           and string.find(text, def.tipName or def.name, 1, true) then
                            matchedKey = def.key
                            local _, nameEnd = string.find(text, def.tipName or def.name, 1, true)
                            local tail = text:sub((nameEnd or 0) + 1, (nameEnd or 0) + 48)
                            local secs = 0
                            -- Case-folded once so "Hr", "hours", "Min", "sec"
                            -- and bare h/m/s all read; each unit takes its
                            -- first "<digits> <unit-letter>" occurrence.
                            local lt = tail:lower()
                            local h = string.match(lt, "(%d+)%s*h")
                            local m = string.match(lt, "(%d+)%s*m")
                            local s = string.match(lt, "(%d+)%s*s")
                            if h then secs = secs + tonumber(h) * 3600 end
                            if m then secs = secs + tonumber(m) * 60 end
                            if s then secs = secs + tonumber(s) end
                            if secs > 0 and DurOk(def.key, secs) then
                                buffs[def.key] = secs
                                frozen[def.key] = true
                            end
                        end
                    end
                    if RC:IsDebugEnabled("worldbuffs") then
                        RC:DebugPrint("BoonTip: '" .. text .. "' -> "
                            .. (matchedKey or "no match"), "worldbuffs", 0)
                    end
                end
            end
        end

        if booned then
            if not next(buffs) then
                local nowG = GetTime()
                -- Tooltip scans are expensive, so results are cached against
                -- the boon aura's expiration (boonSig): 30s while the parse
                -- produced something, 3s while it came back empty so a
                -- tooltip that has not finished loading is retried soon.
                -- The key also records which source was read (aura vs bag)
                -- and the supercharged count, so a boon that moved between
                -- the aura and the bag is re-read rather than served stale.
                local scanSig = boonSig .. ":" .. (boonIndex and "a" or "b") .. ":"
                    .. tostring((GetItemCount and GetItemCount(184938)) or 0)
                local cacheT = self._boonScanCache
                if cacheT and cacheT.sig == scanSig
                        and (nowG - cacheT.at) < (cacheT.empty and 3 or 30) then
                    for k, v in pairs(cacheT.buffs) do
                        buffs[k] = v
                        frozen[k] = true
                    end
                else
                    if boonIndex then
                        ParseTipInto(RC.Compat.TooltipLines(
                            "unitbuff", "player", boonIndex))
                        if not next(buffs) and RC.Compat.TooltipLinesFrame then
                            ParseTipInto(RC.Compat.TooltipLinesFrame(
                                "unitbuff", "player", boonIndex))
                        end
                    end
                    if not next(buffs) and C_Container
                       and C_Container.GetContainerNumSlots then
                        for bag = 0, 4 do
                            local n = C_Container.GetContainerNumSlots(bag) or 0
                            for s = 1, n do
                                if C_Container.GetContainerItemID(bag, s) == 184938 then
                                    ParseTipInto(RC.Compat.TooltipLines(
                                        "bagitem", bag, s))
                                    if not next(buffs) and RC.Compat.TooltipLinesFrame then
                                        ParseTipInto(RC.Compat.TooltipLinesFrame(
                                            "bagitem", bag, s))
                                    end
                                    break
                                end
                            end
                            if next(buffs) then break end
                        end
                    end
                    local cached = {}
                    for k, v in pairs(buffs) do cached[k] = v end
                    self._boonScanCache = {
                    sig = scanSig, at = nowG, buffs = cached,
                                            empty = (next(cached) == nil) }
                end
            end
        end

        for i = 1, 40 do
            local name, dur, expiration, sid = ReadBuff(i)
            if not name then break end
            local key = (sid and ID_TO_KEY[sid]) or NAME_TO_KEY[name]
            if key and not buffs[key] then
                -- Only a Warchief-length Battle Shout is worth syncing; a
                -- normal in-raid shout is noise on the roster.
                local skip = (key == "battleshout") and (not dur or dur < LONG_SHOUT_SECS)
                if not skip then
                    local rem = (expiration and expiration > 0) and (expiration - GetTime()) or 0
                    buffs[key] = math_max(0, math_floor(rem))
                end
            end
        end
        return booned, buffs, frozen
    end

    -- Seconds left on the Chronoboon cooldown (the longest of the kinds
    -- carried; every stack of one kind shares it), or nil.
    function WB:ReadReboonCD()
        local best = nil
        for id in pairs(CHRONO_ITEM_IDS) do
            local bag, s = RC.Bags:Find(id)
            if bag then
                local start, dur = C_Container.GetContainerItemCooldown(bag, s)
                if start and start > 0 and dur and dur > 10 then
                    local rem = start + dur - GetTime()
                    if rem > 1 and (not best or rem > best) then best = math_floor(rem) end
                end
            end
        end
        return best
    end

    function WB:ReadHearthstoneCD()
        local bag, s = RC.Bags:Find(6948)
        if not bag then return nil end
        local start, dur, enable = C_Container.GetContainerItemCooldown(bag, s)
        if start and dur and dur > 0 and enable == 1 then
            local rem = start + dur - GetTime()
            if rem > 1 then return math_floor(rem) end
        end
        return nil
    end
    -- Change detector for the send gate: which buffs are held, whether we
    -- are booned, and our Onyxia timer. Deliberately excludes remaining
    -- SECONDS, so a state that is only ticking down does not re-broadcast.
    function WB:Signature(booned, buffs)
        local keys = {}
        for k in pairs(buffs) do keys[#keys + 1] = k end
        table.sort(keys)
        local sig = (booned and "1" or "0") .. ":" .. table.concat(keys, ",")
        local ony = self:OurOnyxiaNextAt()
        if ony then sig = sig .. ":y" .. ony end
        -- Held turn-in items and which turn-ins are on record (not their
        -- ages) so picking up or handing in a head re-broadcasts.
        local own = self.peers[LocalKey()]
        if own then
            sig = sig .. ":t" .. HeadsCodes(own.heads) .. ":u" .. HeadsCodes(own.dropped)
        end
        return sig
    end

    function WB:CurrentLocation()
        local zone = GetRealZoneText()
        if not zone or zone == "" then zone = GetZoneText() or "" end
        local sub = GetSubZoneText() or ""
        local loc
        if sub ~= "" and sub ~= zone then
            loc = (zone ~= "" and (zone .. " - " .. sub)) or sub
        else
            loc = zone
        end
        loc = (loc or ""):gsub(";", " ")
        return loc
    end

    -- Wire format, ";" between tokens: token 1 is a comma list of tagged
    -- meta fields (b booned, c reboon cd, h hearthstone, q chrono count,
    -- k class, p pvp, d dmf lockout, v level, g gold, r race); then one
    -- <code><seconds> token per held buff; then optional "z" + the codes
    -- that are chronoboon-frozen, "x"/"f" drop ages, "l" location,
    -- "n" our key, "y" our Onyxia timestamp. Location has ";" stripped
    -- upstream because it would otherwise split the payload.
    -- Shared body of WB:Encode and EncodePeerBuffs: the meta token, the
    -- per-buff <code><seconds> tokens and the frozen "z" token are built
    -- identically for a self broadcast and a relayed peer. `p` is a peer
    -- record (or a record-shaped table of self state). includeSelfMeta adds
    -- the self-broadcast-only "p" (pvp) and "g" (gold) meta fields - relays
    -- deliberately omit both (we do not forward someone's gold to third
    -- parties). The one exception is a record this account wrote itself
    -- (p.own: one of our own logged-off characters) - its gold IS ours to
    -- announce, and nobody else can. Without it a toon that traded gold and
    -- logged out before its send went out kept its old balance on every
    -- other account until it next logged in. forceFrozen marks every held
    -- buff frozen regardless of the record's own frozen set. Returns the
    -- open parts list so each caller can append its own trailing tokens
    -- before joining with ";".
    local function EncodeRecord(p, includeSelfMeta, forceFrozen)
        local meta = { "b" .. (p.booned and "1" or "0") }
        if p.cd and p.cd > 1 then meta[#meta + 1] = "c" .. math_floor(p.cd) end
        if p.hs and p.hs > 1 then meta[#meta + 1] = "h" .. math_floor(p.hs) end
        if p.chrono ~= nil then meta[#meta + 1] = "q" .. math_floor(p.chrono) end
        if p.class and p.class ~= "" then meta[#meta + 1] = "k" .. p.class end
        if includeSelfMeta then meta[#meta + 1] = "p" .. (p.pvp and "1" or "0") end
        if p.dmfRem and p.dmfRem > 0 then meta[#meta + 1] = "d" .. math_floor(p.dmfRem) end
        if p.level then meta[#meta + 1] = "v" .. p.level end
        if (includeSelfMeta or p.own) and p.gold then meta[#meta + 1] = "g" .. math_floor(p.gold) end
        if p.race then meta[#meta + 1] = "r" .. p.race end
        local parts = { table.concat(meta, ",") }
        local frozenCodes = {}
        for _, def in ipairs(BUFFS) do
            local secs = p.buffs and p.buffs[def.key]
            if secs and secs > 0 then
                parts[#parts + 1] = def.code .. math_floor(secs)
                if forceFrozen or (p.frozen and p.frozen[def.key]) then
                    frozenCodes[#frozenCodes + 1] = def.code
                end
            end
        end
        -- Always emitted for a booned record, even empty: a bare "z" tells
        -- the decoder "nothing frozen" so it does not assume every slot buff.
        if forceFrozen or p.booned then
            parts[#parts + 1] = "z" .. table.concat(frozenCodes, "")
        end
        local hc = HeadsCodes(p.heads)
        if hc ~= "" then parts[#parts + 1] = "t" .. hc end
        -- Always emitted when known, even empty: a bare "u" means "nothing
        -- dropped yet", distinct from an older sender that never reports.
        if p.dropped then parts[#parts + 1] = "u" .. HeadsCodes(p.dropped) end
        return parts
    end

    function WB:Encode(booned, buffs, cd, hs, class, frozen, pvp, location, chrono, dmfRem, level, gold, race)
        local own = self.peers[LocalKey()]
        local parts = EncodeRecord({
            booned = booned, buffs = buffs, cd = cd, hs = hs, class = class,
            frozen = frozen, pvp = pvp, chrono = chrono, dmfRem = dmfRem,
            level = level, gold = gold, race = race,
            heads = own and own.heads, dropped = own and own.dropped,
        }, true, false)
        local now = time()
        local dropPairs = {}
        for _, d in ipairs(DROP_TRACK) do
            local t = self.dropLog[d.key]
            if t then
                local age = now - t
                if age >= 0 and age < d.cd then
                    dropPairs[#dropPairs + 1] = d.code .. math_floor(age)
                end
            end
        end
        if #dropPairs > 0 then
            parts[#parts + 1] = "x" .. table.concat(dropPairs, ",")
        end
        local flowerPairs = {}
        for idx = 1, 10 do
            local t = self.dropLog.flowers[idx]
            if t then
                local age = now - t
                if age >= 0 and age < DROP_CD.songflower then
                    flowerPairs[#flowerPairs + 1] = idx .. ":" .. math_floor(age)
                end
            end
        end
        if #flowerPairs > 0 then
            parts[#parts + 1] = "f" .. table.concat(flowerPairs, ",")
        end
        if location and location ~= "" then
            parts[#parts + 1] = "l" .. location
        end
        local myKey = LocalKey()
        if myKey and myKey ~= "" then
            parts[#parts + 1] = "n" .. myKey
        end
        local ony = self:OurOnyxiaNextAt()
        if ony then
            parts[#parts + 1] = "y" .. ony
        end
        return table.concat(parts, ";")
    end

    local function EncodePeerBuffs(p, forceFrozen)
        local parts = EncodeRecord(p, false, forceFrozen)
        if p.location and p.location ~= "" then
            parts[#parts + 1] = "l" .. p.location
        end
        return table.concat(parts, ";")
    end

    -- Fits an encoded payload (";"-separated tokens, token 1 fixed) under
    -- `limit` bytes by shedding the least important tokens in order:
    -- flower ages, drop ages, location cut to its zone, a relay's
    -- exact-age stamp, location, then our key.
    -- Buff tokens (upper-case codes) and the "z" token are never dropped.
    local function TrimPayload(payload, limit)
        if type(payload) ~= "string" or #payload <= limit then return payload end
        local parts = {}
        for tok in string.gmatch(payload, "[^;]+") do parts[#parts + 1] = tok end
        local function Drop(head)
            for i = #parts, 2, -1 do
                if string.sub(parts[i], 1, 1) == head then table.remove(parts, i) end
            end
            return table.concat(parts, ";")
        end
        local out = Drop("f")
        if #out <= limit then return out end
        out = Drop("x")
        if #out <= limit then return out end
        out = Drop("u")
        if #out <= limit then return out end
        for i = 2, #parts do
            if string.sub(parts[i], 1, 1) == "l" then
                local cut = string.find(parts[i], " - ", 2, true)
                if cut then parts[i] = string.sub(parts[i], 1, cut - 1) end
            end
        end
        out = table.concat(parts, ";")
        if #out <= limit then return out end
        out = Drop("e")
        if #out <= limit then return out end
        out = Drop("l")
        if #out <= limit then return out end
        return Drop("n")
    end

    function WB:Decode(data)
        local gold
        if type(data) ~= "string" or data == "" then return nil end
        local tokens = {}
        for tok in string.gmatch(data, "[^;]+") do tokens[#tokens + 1] = tok end
        if #tokens == 0 then return nil end

        local booned, cd, hs, class = false, nil, nil, nil
        local chrono = nil
        local dmfRem = nil
        local level = nil
        local pvp, location = nil, nil
        local race = nil
        local name = nil
        local onyAt = nil
        for item in string.gmatch(tokens[1], "[^,]+") do
            local k = string.sub(item, 1, 1)
            local v = string.sub(item, 2)
            if k == "b" then booned = (v == "1")
            elseif k == "c" then cd = tonumber(v)
            elseif k == "h" then hs = tonumber(v)
            elseif k == "q" then chrono = tonumber(v)
            elseif k == "k" then class = v
            elseif k == "p" then pvp = (v == "1")
            elseif k == "d" then dmfRem = tonumber(v)
            elseif k == "v" then level = tonumber(v)
            elseif k == "g" then gold = tonumber(v)
            elseif k == "r" then race = v end
        end

        local buffs = {}
        local dropAges = nil
        local flowerAges = nil
        local frozen = nil
        local heads, dropped = nil, nil
        for i = 2, #tokens do
            local tok = tokens[i]
            local head = string.sub(tok, 1, 1)
            if head == "x" then
                dropAges = dropAges or {}
                for pair in string.gmatch(string.sub(tok, 2), "[^,]+") do
                    local key = CODE_TO_KEY[string.sub(pair, 1, 1)]
                    local age = tonumber(string.sub(pair, 2))
                    if key and age then dropAges[key] = age end
                end
            elseif head == "f" then
                flowerAges = flowerAges or {}
                for pair in string.gmatch(string.sub(tok, 2), "[^,]+") do
                    local fi, fa = string.match(pair, "^(%d+):(%d+)$")
                    fi, fa = tonumber(fi), tonumber(fa)
                    if fi and fa and fi >= 1 and fi <= 10 then flowerAges[fi] = fa end
                end
            elseif head == "z" then
                frozen = frozen or {}
                local codes = string.sub(tok, 2)
                for ci = 1, #codes do
                    local key = CODE_TO_KEY[string.sub(codes, ci, ci)]
                    if key then frozen[key] = true end
                end
            elseif head == "l" then
                location = string.sub(tok, 2)
            elseif head == "n" then
                name = string.sub(tok, 2)
            elseif head == "y" then
                onyAt = tonumber(string.sub(tok, 2))
            elseif head == "t" then
                local codes = string.sub(tok, 2)
                for ci = 1, #codes do
                    local d = TURNIN_BY_CODE[string.sub(codes, ci, ci)]
                    if d then heads = heads or {}; heads[d.key] = true end
                end
            elseif head == "u" then
                dropped = {}
                local codes = string.sub(tok, 2)
                for ci = 1, #codes do
                    local d = TURNIN_BY_CODE[string.sub(codes, ci, ci)]
                    if d then dropped[d.key] = true end
                end
            else
                local key  = CODE_TO_KEY[head]
                local secs = tonumber(string.sub(tok, 2))
                if key and secs and secs > 0 then buffs[key] = math_floor(secs) end
            end
        end
        -- Older senders omit the "z" token: for a booned peer, assume every
        -- chronoboonable buff (the ones with a slot) is frozen.
        if booned and not frozen then
            frozen = {}
            for key in pairs(buffs) do
                local def = DEF_BY_KEY[key]
                if def and def.slot then frozen[key] = true end
            end
        end
        return booned, buffs, cd, hs, class, dropAges, flowerAges, frozen, pvp, location, name, onyAt, chrono, dmfRem, level, gold, race, heads, dropped
    end

    local function MeshOn()
        return RC.MeshSync and RC.MeshSync.IsEnabled and RC.MeshSync:IsEnabled()
    end
    -- Same test; the heartbeat reads it under this name.
    local FeatureEnabled = MeshOn

    function WB:RecordSelf()
        local booned, buffs, frozen = self:BuildAuraSnapshot()

        -- A booned character whose tooltip has not loaded reads as zero
        -- buffs. Writing that would wipe a good stored record, so the
        -- previous one is carried forward instead.
        -- buffs already holds any live auras, so the empty test is on the
        -- frozen set, and only the previously frozen keys are carried.
        if booned and not next(frozen) then
            local prevRec = self.peers[LocalKey()]
            if prevRec and prevRec.buffs and prevRec.frozen and next(prevRec.frozen) then
                local carried = false
                for k in pairs(prevRec.frozen) do
                    if prevRec.buffs[k] and not buffs[k] then
                        buffs[k]  = prevRec.buffs[k]
                        frozen[k] = true
                        carried   = true
                    end
                end
                if carried then
                    RC:DebugPrint("WorldBuffSync: booned but read empty - carried forward "
                        .. "previous stored buffs", "meshsync")
                end
            end
        end

        local now = time()
        local activeRem = {}
        for i = 1, 40 do
            local name, _, expiration, sid = ReadBuff(i)
            if not name then break end
            local key = (sid and ID_TO_KEY[sid]) or NAME_TO_KEY[name]
            if key and DROP_DUR[key] then
                local rem = (expiration and expiration > 0) and (expiration - GetTime()) or 0
                if rem > 0 then activeRem[key] = math_floor(rem) end
            end
        end

        self._dropPresent = self._dropPresent or {}
        for _, d in ipairs(DROP_TRACK) do
            local present = (buffs[d.key] and buffs[d.key] > 0) and true or false
            if d.key == "songflower" then
                if self._dropInit and present and not self._dropPresent[d.key] then
                    local idx = NearestFlowerNode()
                    if idx then self.dropLog.flowers[idx] = now end
                end
            else
                if self._dropInit and present and not self._dropPresent[d.key] then
                    if now > (self.dropLog[d.key] or 0) then self.dropLog[d.key] = now end
                end
                -- A buff already running when we logged in still dates its
                -- drop: elapsed = full duration minus what is left.
                local rem = activeRem[d.key]
                if rem and rem > 0 and rem <= d.dur then
                    local implied = now - (d.dur - rem)
                    if implied > (self.dropLog[d.key] or 0) then self.dropLog[d.key] = implied end
                end
            end
            self._dropPresent[d.key] = present
        end
        self._dropInit = true

        local cd = self:ReadReboonCD()
        local hs = self:ReadHearthstoneCD()
        -- Both item variants count: a booned toon holds the supercharged
        -- 184938, not an empty 184937, and still owns a displacer.
        local chrono = ((GetItemCount and GetItemCount(184937)) or 0)
            + ((GetItemCount and GetItemCount(184938)) or 0)
        if not booned then self._boonScanCache = nil end
        local gold = (GetMoney and GetMoney()) or nil
        local _, class = UnitClass("player")
        local pvp = UnitIsPVP("player") and true or false
        local location = self:CurrentLocation()
        local key = LocalKey()

        local old = self.peers[key]
        local dmfRem = old and old.dmfRem
        local heads = ReadHeads()
        local dropped = ReadDropped() or {}
        if dmfRem then
            if self._dmfStamp then
                dmfRem = dmfRem - (now - self._dmfStamp)
            elseif old and old.t then
                if MAJOR_CITIES[old.location or ""] and (now - old.t) >= DMF_CITY_FALL then
                    dmfRem = nil
                end
            end
        end
        local sayFrozen = (frozen and frozen.sayges) and true or false
        local sayActive = (buffs.sayges and buffs.sayges > 0 and not sayFrozen) and true or false
        local unboonEvent = (self._prevBooned == true) and (not booned)
        if self._saygesInit and sayActive and not self._saygesPrev and not unboonEvent then
            dmfRem = DMF_LOCK_DUR
        elseif sayActive and not dmfRem then
            dmfRem = 7200 + (buffs.sayges or 0)
        end
        do
            local nwbRem = self:ReadNWBSelfDMF()
            if nwbRem ~= nil then dmfRem = nwbRem > 0 and nwbRem or nil end
        end
        -- 16 is the client's debuff cap: at a full bar the fortune aura can
        -- be pushed off, which also clears the re-roll lockout.
        if dmfRem then
            if #RC.Auras:Debuffs() >= 16 then
                dmfRem = nil
                RC:DebugPrint("WorldBuffSync: DMF lockout pushed off by a full debuff bar", "meshsync")
            end
        end
        if dmfRem and dmfRem <= 0 then dmfRem = nil end
        self._saygesPrev = sayActive
        self._prevBooned = booned
        self._saygesInit = true
        self._dmfStamp = now

        if WB._watchWrites then
            local bn = 0
            if buffs then for _ in pairs(buffs) do bn = bn + 1 end end
            RC:Print(RCL["WBwrite[self] "] .. key .. RCL[" buffs="] .. bn)
        end
        self.peers[key] = {
            gold     = gold,
            goldT    = time(),
            label    = nil,
            name     = key,
            class    = class,
            booned   = booned,
            buffs    = buffs,
            frozen   = frozen,
            cd       = cd,
            hs       = hs,
            chrono   = chrono,
            pvp      = pvp,
            location = location,
            dmfRem   = dmfRem,
            level    = UnitLevel("player"),
            race     = select(2, UnitRace("player")),
            heads    = heads,
            dropped  = dropped,
            own      = true,
            t        = time(),
        }
        return gold, booned, buffs, cd, hs, class, frozen, pvp, location, chrono, dmfRem,
            UnitLevel("player")
    end

    function WB:Broadcast()
        local gold, booned, buffs, cd, hs, class, frozen, pvp, location, chrono, dmfRem, level = self:RecordSelf()
        local sig = self:Signature(booned, buffs)
        self._lastChrono = chrono
        if not MeshOn() or not RC.MeshSync.Broadcast then
            self._lastSig = sig
            self._lastFullSend = time()
            return
        end
        if RC.MeshSync.SetNextSendPriority then RC.MeshSync:SetNextSendPriority() end
        self._lastGoldSent = gold
        local payload = self:Encode(booned, buffs, cd, hs, class, frozen, pvp, location, chrono, dmfRem, level, gold,
            select(2, UnitRace("player")))
        -- One unchunked mesh message is 255 bytes with a ~43 byte header;
        -- the yell and BNet legs base64-inflate, so they get a smaller cut.
        payload = TrimPayload(payload, 200)
        if #payload > 200 then
            RC:DebugPrint("WB: payload still " .. #payload .. " bytes after trim - not sent", "worldbuffs")
            return
        end
        self._lastSig = sig
        self._lastFullSend = time()
        local yellPayload = TrimPayload(payload, 140)
        RC.MeshSync:Broadcast("WBUFF", payload, nil, nil,
            (yellPayload ~= payload) and yellPayload or nil)
        RC:DebugPrint("WB: state broadcast (sig " .. tostring(sig) .. ")", "worldbuffs")
        if RC.MeshSync.CrossFactionWhisper then
            -- Own dedup slot: omitting the key shared the "_self" slot with
            -- WBTIME/WBYELL, so each command clobbered the others' stored
            -- signature and this whisper's change suppression never held.
            -- The buff signature alone let a gold-only change sit unsent
            -- for the whole 10-minute resend window; fold gold in.
            RC.MeshSync:CrossFactionWhisper("WBUFF", yellPayload,
                sig .. "|g" .. math_floor((gold or 0) / 10000), "wbuff")
        end
        self:SyncXfRoster()
        RC:DebugPrint("WorldBuffSync: broadcast " .. payload, "meshsync")
    end

    function WB:OnInbound(from, sender, data, viaBNet)
        if not sender then return end
        RC:DebugPrint("WB: inbound state from " .. tostring(sender)
            .. ((type(viaBNet) == "number") and " (bnet)" or (viaBNet and " (yell)" or "")), "worldbuffs")
        local booned, buffs, cd, hs, class, dropAges, flowerAges, frozen, pvp, location, name, onyAt, chrono, dmfRem, level, gold, race, heads, dropped = self:Decode(data)
        if type(buffs) == "table" then
            for k, secs in pairs(buffs) do
                if not DurOk(k, secs) then
                    buffs[k] = nil
                end
            end
        end
        if booned == nil then return end
        -- Only a real BNet whisper (numeric sender id) is cross-faction; the
        -- mesh passes viaBNet=true for any addon YELL, same-faction included.
        local crossFaction = (type(viaBNet) == "number")
        local bnetId       = crossFaction and viaBNet or nil
        local key = NormKey((crossFaction and name and name ~= "") and name or sender)
        local keyValid = key ~= nil
            and not key:find("@", 1, true)
            and not key:find("#", 1, true)
            and not (crossFaction and (not name or name == ""))
        if not keyValid and WB._watchWrites then
            RC:Print(RCL["WBwrite[REJECTED] key="] .. tostring(key) .. RCL[" from="] .. tostring(from))
        end
        local prev  = keyValid and self.peers[key] or nil
        local isNew = keyValid and (prev == nil)
        if keyValid then
        if self.removals[key] then self.removals[key] = nil end
        if self.removals[sender] then self.removals[sender] = nil end
        -- Someone else claiming a record we wrote ourselves (an alt sharing
        -- a base name, a mismatched realm suffix) may only overwrite it if
        -- it carries at least as many buffs - never trade down.
        if prev and prev.own and NormKey(sender or "") ~= key then
            local exN = 0
            if prev.buffs then for _ in pairs(prev.buffs) do exN = exN + 1 end end
            local inN = 0
            if buffs then for _ in pairs(buffs) do inN = inN + 1 end end
            if inN <= exN then return end
        end
        if WB._watchWrites then
            local bn = 0
            if buffs then for _ in pairs(buffs) do bn = bn + 1 end end
            RC:Print(RCL["WBwrite[direct] "] .. key .. RCL[" buffs="] .. bn .. RCL[" from="] .. tostring(from))
        end
        local wt = time()
        self.peers[key] = {
            label    = from,
            name     = key,
            class    = class,
            booned   = booned,
            buffs    = buffs,
            frozen   = frozen,
            cd       = cd,
            hs       = hs,
            gold     = gold,
            goldT    = gold and wt or nil,
            chrono   = chrono,
            pvp      = pvp,
            location = location,
            dmfRem   = dmfRem,
            level    = level,
            race     = race,
            heads    = heads,
            dropped  = dropped,
            t        = wt,
            seenAt   = wt,
            viaBNet    = crossFaction or nil,
            bnetId     = bnetId or (prev and prev.bnetId) or nil,
            bnetOnline = crossFaction and true or nil,
            offlineAt  = nil,
        }
        end
        if dropAges then
            local now = time()
            for key, age in pairs(dropAges) do
                local dt = now - age
                if dt > (self.dropLog[key] or 0) then self.dropLog[key] = dt end
            end
        end
        if flowerAges then
            local now = time()
            for idx, age in pairs(flowerAges) do
                local dt = now - age
                if dt > (self.dropLog.flowers[idx] or 0) then self.dropLog.flowers[idx] = dt end
            end
        end
        if bnetId and onyAt and onyAt > GetServerTime() then
            if onyAt > (self.oppOnyAt or 0) then
                self.oppOnyAt = onyAt
                if MeshOn() and RC.MeshSync.Broadcast then
                    RC.MeshSync:Broadcast("WBONY", tostring(onyAt), nil, true)
                end
            end
        end
        RC:DebugPrint("WorldBuffSync: inbound from " .. tostring(sender), "meshsync")
        -- Only a genuinely new or long-absent peer earns a roster relay, and
        -- only one is ever in flight. The random jitter plus the "somebody
        -- else relayed in the last 20s" bail keeps a raid zoning in together
        -- from all dumping their caches on the channel at once.
        local returning = (not isNew) and prev and (time() - LastSeen(prev)) > 120
        if (isNew or returning or crossFaction) and not self._relayScheduled then
            self._relayScheduled = true
            C_Timer.After(RELAY_NEW_PEER_DELAY + math.random(0, 7), function()
                self._relayScheduled = false
                if time() - (self._lastRelayHeard or 0) < 20 then return end
                self._lastRelay = nil
                self:RelayRoster()
            end)
        end
        -- A character never heard before has nothing of ours at all: it
        -- gets the same whispered catch-up as a returning one, reaching
        -- all the way back. Only a whisper can be answered with one; when
        -- the yelled copy got here first it is owed until the whisper does
        -- (see OnPeerSeen).
        if isNew and not crossFaction then
            if viaBNet then
                self._returnSince[key] = 0
            else
                self:QueueCatchUp(sender, 0)
            end
        end
        if not crossFaction then self:SyncXfRoster() end
    end

    local RELAY_SEP = "~"

    -- forceOffline: send the frozen snapshot even for a peer still inside
    -- the online window. Claiming "online" for someone else is only safe
    -- when everybody can hear them for themselves.
    function WB:BuildRelayPayload(p, now, forceOffline)
        -- age is the DATA age (what the relay reports); presence is judged
        -- on the last time the peer was heard at all.
        local age = now - (p.t or 0)
        local isOnline
        if p.bnetId then
            isOnline = p.bnetOnline and true or false
        elseif p.relayOnline ~= nil then
            local presAge = now - (p.presenceT or LastSeen(p))
            isOnline = (p.relayOnline and presAge <= RELAY_PRESENCE_TTL) and true or false
        else
            isOnline = not PeerOffline(p, now)
        end
        if forceOffline then isOnline = false end
        -- Online peers relay live: age since t, values untouched. Offline
        -- ones relay a snapshot frozen at the moment they went offline -
        -- unfrozen buffs are wound forward to that point and the reported
        -- age restarts there, so listeners do not keep ticking a logged-out
        -- character's buffs down toward zero.
        local relAge, buffBlock
        if isOnline then
            relAge    = math_floor(age)
            buffBlock = EncodePeerBuffs(p, false)
        else
            local fpoint = (p.bnetId and p.offlineAt) or (p.t or now)
            local fage   = fpoint - (p.t or 0)
            if fage < 0 then fage = 0 end
            local snapBuffs = {}
            for k, secs in pairs(p.buffs or {}) do
                if p.frozen and p.frozen[k] then
                    snapBuffs[k] = secs
                else
                    local rem = secs - fage
                    if rem > 0 then snapBuffs[k] = math_floor(rem) end
                end
            end
            local snap = {
                booned = p.booned,
                class  = p.class,
                buffs  = snapBuffs,
                frozen = p.frozen,
                cd     = p.cd and math_max(0, p.cd - fage) or nil,
                hs     = p.hs and math_max(0, p.hs - fage) or nil,
                chrono = p.chrono,
                dmfRem = p.dmfRem and math_max(0, p.dmfRem - fage) or nil,
                location = p.location,
                level  = p.level,
                race   = p.race,
                own    = p.own,
                gold   = p.gold,
            }
            relAge    = math_floor(now - fpoint)
            if relAge < 0 then relAge = 0 end
            buffBlock = EncodePeerBuffs(snap, false)
        end
        -- relAge is right when this is built and wrong by however long the
        -- message then waits in the send queue - long enough, in a burst,
        -- for old news to land looking newer than what the listener heard
        -- for itself. The "e" token pins the data to the server clock, which
        -- every client shares; listeners that know it use it, older ones
        -- skip it like any token they do not recognise.
        local payload = (p.name or "?") .. RELAY_SEP .. relAge .. RELAY_SEP
            .. (isOnline and "1" or "0") .. RELAY_SEP .. buffBlock
            .. ";e" .. (GetServerTime() - relAge)
        return payload, isOnline
    end

    function WB:RelayRoster(force)
        if not MeshOn() or not RC.MeshSync.Broadcast then return end
        if RC.MeshSync.SetNextSendPriority then RC.MeshSync:SetNextSendPriority() end
        local now = time()
        local selfKey = LocalKey()
        -- Our own logged-off characters whose gold changed since they were
        -- last relayed go out on the next pass regardless of the relay
        -- interval. The toon that traded is offline, so this account is the
        -- only thing on the network that knows its new balance.
        local goldDue = {}
        for key, p in pairs(self.peers) do
            if key ~= selfKey and p.own and p.gold
               and (now - LastSeen(p)) <= GC_MAX
               and (p.goldT or 0) > (p.goldRelayedAt or 0) then
                goldDue[#goldDue + 1] = p
            end
        end
        local due = {}
        local regularPass = false
        if force or not self._lastRelay or (now - self._lastRelay) >= RELAY_MIN_INTERVAL then
            regularPass = true
            -- Only relay what the listeners cannot hear for themselves:
            -- cross-faction peers, and same-faction ones already past the
            -- online window. Anything currently broadcasting is skipped.
            for key, p in pairs(self.peers) do
                local age = now - LastSeen(p)
                local relayCF   = (p.bnetId or p.xfRoster) and true or false
                local relaySame = (not p.viaBNet) and (p.relayOnline == nil) and PeerOffline(p, now)
                if key ~= selfKey and age <= GC_MAX and (relayCF or relaySame) then
                    due[#due + 1] = p
                end
            end
        elseif #goldDue == 0 then
            return
        end
        local goldFirst = {}
        for _, p in ipairs(goldDue) do
            goldFirst[p] = true
            local already = false
            for _, d in ipairs(due) do
                if d == p then already = true break end
            end
            if not already then due[#due + 1] = p end
        end
        -- One message per peer, so a big cache is spread over several
        -- passes: pending gold changes first, then least recently relayed.
        table.sort(due, function(a, b)
            local ga, gb = goldFirst[a] or false, goldFirst[b] or false
            if ga ~= gb then return ga end
            return (a.relayedAt or 0) < (b.relayedAt or 0)
        end)
        local sent = 0
        for i = 1, math.min(#due, RELAY_MAX_PER_PASS) do
            local p = due[i]
            -- Relays also go out on the yell leg, which needs the tighter cut.
            local rel = TrimPayload((self:BuildRelayPayload(p, now)), 200)
            local relYell = TrimPayload(rel, 140)
            RC.MeshSync:Broadcast("WBREL", rel, nil, nil,
                (relYell ~= rel) and relYell or nil)
            p.relayedAt = now
            if goldFirst[p] then p.goldRelayedAt = now end
            sent = sent + 1
        end
        if self.oppOnyAt and self.oppOnyAt > GetServerTime() then
            RC.MeshSync:Broadcast("WBONY", tostring(self.oppOnyAt), nil, true)
        end
        if sent > 0 then
            -- A gold-only pass must not push the regular relay interval out.
            if regularPass then self._lastRelay = now end
            RC:DebugPrint("WorldBuffSync: relayed " .. sent .. " cached peer(s)", "meshsync")
        end
    end

    -- Cross-faction whispers go over BNet and are rate-limited hard by the
    -- client: at most 4 peers per pass, no pass inside 6 seconds.
    local XF_ROSTER_PER_PASS = 4
    local XF_ROSTER_INTERVAL = 6
    function WB:SyncXfRoster()
        if not MeshOn() or not RC.MeshSync.CrossFactionWhisper then return end
        local now = time()
        if self._lastXfRoster and (now - self._lastXfRoster) < XF_ROSTER_INTERVAL then return end
        local selfKey = LocalKey()
        -- Least recently whispered first, so every eligible peer gets a
        -- turn instead of the same four in pairs() order every pass.
        local eligible = {}
        for key, p in pairs(self.peers) do
            local age = now - LastSeen(p)
            if key ~= selfKey and age <= GC_MAX and not p.bnetId and not p.viaBNet
               and not p.xfRoster and p.relayOnline == nil then
                eligible[#eligible + 1] = { key = key, p = p }
            end
        end
        table.sort(eligible, function(a, b)
            local ta, tb = a.p.xfSentAt or 0, b.p.xfSentAt or 0
            if ta ~= tb then return ta < tb end
            return a.key < b.key
        end)
        local sent = 0
        for i = 1, math.min(#eligible, XF_ROSTER_PER_PASS) do
            local key, p = eligible[i].key, eligible[i].p
            local payload, isOnline = self:BuildRelayPayload(p, now)
            local keys = {}
            for k in pairs(p.buffs or {}) do keys[#keys + 1] = k end
            table.sort(keys)
            local sig = (isOnline and "1" or "0") .. (p.booned and "B" or "b")
                .. table.concat(keys, ",")
            if p.own and p.gold then sig = sig .. "|g" .. math_floor(p.gold / 10000) end
            RC.MeshSync:CrossFactionWhisper("WBREL", TrimPayload(payload, 140), sig, key)
            p.xfSentAt = now
            sent = sent + 1
        end
        if sent > 0 then self._lastXfRoster = now end
    end

    function WB:ResolvePeer(sender)
        local key = NormKey(sender or "")
        if key == "" then return nil end
        local p = self.peers[key]
        if not p then
            self._seenKeyMap = self._seenKeyMap or {}
            local cached = self._seenKeyMap[key]
            if cached and self.peers[cached] then
                p = self.peers[cached]
            else
                -- Only a bare name pairs with its realm-qualified form;
                -- two realm-qualified keys are always distinct characters.
                local keyHasRealm = key:find("-", 1, true) ~= nil
                local pref = key .. "-"
                for k, v in pairs(self.peers) do
                    local kHasRealm = k:find("-", 1, true) ~= nil
                    if (not keyHasRealm and kHasRealm and k:sub(1, #pref) == pref)
                       or (keyHasRealm and not kHasRealm and key:sub(1, #k + 1) == k .. "-") then
                        p = v
                        self._seenKeyMap[key] = k
                        break
                    end
                end
            end
        end
        return p
    end

    -- What one returning peer is whispered: our own live state, then the
    -- characters we know first-hand whose data changed while that peer was
    -- away - the ones we know are offline first (nobody else can speak
    -- for them), newest first. Sent to that peer alone; everyone else heard
    -- these when they happened. First-hand only, like RelayRoster: passing
    -- on hearsay lets two accounts hand one record back and forth. Always
    -- as the frozen snapshot - a peer that really is online says so itself
    -- a moment later, and one that left without a BYE is not shown online
    -- with its buffs ticking away.
    function WB:SendCatchUp(target, since)
        if not MeshOn() or not RC.MeshSync.Broadcast then return end
        local now = time()
        local selfKey, targetKey = LocalKey(), NormKey(target)
        local list, offline = {}, {}
        for key, p in pairs(self.peers) do
            if key ~= selfKey and key ~= targetKey
               and not p.viaBNet and not p.bnetId and p.relayOnline == nil
               and (p.t or 0) >= since and (now - LastSeen(p)) <= GC_MAX then
                list[#list + 1] = p
                offline[p] = PeerOffline(p, now)
            end
        end
        table.sort(list, function(a, b)
            if offline[a] ~= offline[b] then return offline[a] end
            local ta, tb = a.t or 0, b.t or 0
            if ta ~= tb then return ta > tb end
            return tostring(a.name or "") < tostring(b.name or "")
        end)
        -- The mesh puts a single message at the FRONT of its target's
        -- queue, so the last one handed over is the first one sent. Handed
        -- over backwards, they go out own state first, then in list order.
        local sent = math.min(#list, CATCHUP_MAX)
        for i = sent, 1, -1 do
            RC.MeshSync:Broadcast("WBREL",
                TrimPayload((self:BuildRelayPayload(list[i], now, true)), 200), target)
        end
        local gold, booned, buffs, cd, hs, class, frozen, pvp, location, chrono, dmfRem, level = self:RecordSelf()
        local own = TrimPayload(self:Encode(booned, buffs, cd, hs, class, frozen, pvp, location,
            chrono, dmfRem, level, gold, select(2, UnitRace("player"))), 200)
        if #own <= 200 then
            RC.MeshSync:Broadcast("WBUFF", own, target)
        end
        RC:DebugPrint("WorldBuffSync: caught " .. tostring(target) .. " up with own state + "
            .. sent .. " record(s)", "meshsync")
    end

    -- One catch-up per peer is ever waiting; a second sighting inside the
    -- delay only widens how far back it reaches.
    function WB:QueueCatchUp(sender, since)
        if not MeshOn() or type(sender) ~= "string" or sender == "" then return end
        local key = NormKey(sender)
        -- Whispered back, so the target needs its realm like every other
        -- mesh target.
        if not sender:find("-", 1, true) then
            local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or ""
            if realm ~= "" then sender = sender .. "-" .. realm end
        end
        self._catchUp = self._catchUp or {}
        local job = self._catchUp[key]
        if job then
            if since < job.since then job.since = since end
            return
        end
        self._catchUp[key] = { target = sender, since = since }
        C_Timer.After(CATCHUP_DELAY + math.random(0, 4), function()
            local due = self._catchUp[key]
            self._catchUp[key] = nil
            if not due then return end
            -- Gone again before its turn came: still owed, next time.
            local p = self:ResolvePeer(due.target)
            if not MeshOn() or (p and PeerOffline(p, time())) then
                local owed = self._returnSince[key]
                if not owed or due.since < owed then self._returnSince[key] = due.since end
                return
            end
            self:SendCatchUp(due.target, due.since)
        end)
    end

    -- viaBNet is the mesh's own flag for how this message arrived: nil for
    -- a whisper, true for a yell, a number for a BNet whisper.
    function WB:OnPeerSeen(sender, viaBNet)
        local p = self:ResolvePeer(sender)
        if p then
            -- Back after a BYE or a long silence: it was not listening
            -- while it was gone, so it is told what changed. Noticed here
            -- because this stamps seenAt before any other handler runs -
            -- by the time OnInbound looks, the gap is already closed.
            -- The catch-up is whispered, so it waits for a whisper from
            -- them: a broadcast is yelled as well, and the yelled copy is
            -- often the first to arrive.
            if not p.viaBNet and not p.bnetId and not p.xfRoster then
                local key = NormKey(sender)
                local owed = self._returnSince
                -- Our last direct sighting, not LastSeen: a record that only
                -- a relay has refreshed since is no sign they could hear us.
                local last = p.seenAt or 0
                if (p.byeAt and p.byeAt >= last) or (time() - last) > RETURN_GAP then
                    if not owed[key] or last < owed[key] then owed[key] = last end
                end
                if owed[key] and not viaBNet and MeshOn() then
                    self:QueueCatchUp(sender, owed[key])
                    owed[key] = nil
                end
            end
            -- Presence only: p.t is the epoch every remaining value is
            -- measured from, so a HELLO must not move it.
            p.seenAt = time()
            p.offlineAt = nil
            p.byeAt     = nil
            p.relayOnline = nil
            p.presenceT   = nil
        end
    end

    function WB:OnPeerBye(sender)
        local p = self:ResolvePeer(sender)
        if p then
            p.seenAt = time()
            p.byeAt  = p.seenAt
            p.relayOnline = nil
            p.presenceT   = nil
        end
    end

    local function LogKill(reason, key, detail)
        local L = WB._killLog
        L[#L + 1] = { t = time(), reason = reason, key = tostring(key), detail = detail or "" }
        if #L > 30 then table.remove(L, 1) end
    end

    local function BaseName(k)
        local b = tostring(k):match("^([^%-]+)")
        return b and b:lower() or tostring(k):lower()
    end

    function WB:DedupePeers()
        local best = {}
        for k, p in pairs(self.peers) do
            local b = BaseName(k)
            local cur = best[b]
            if not cur then
                best[b] = k
            else
                local kHasRealm  = k:find("-", 1, true) ~= nil
                local cHasRealm  = cur:find("-", 1, true) ~= nil
                local pc = self.peers[cur]
                local tk = math_max(p.seenAt or 0, p.goldT or 0, p.t or 0)
                local tc = pc and math_max(pc.seenAt or 0, pc.goldT or 0, pc.t or 0) or 0
                local keepK
                if math.abs(tk - tc) > 60 then
                    keepK = tk > tc
                else
                    keepK = kHasRealm
                end
                -- Two realm-qualified keys are different characters that
                -- happen to share a name; only a bare key merges into one.
                if kHasRealm and cHasRealm then
                    best[b] = cur
                elseif keepK then
                    LogKill("dedupe", cur, "kept=" .. k)
                    if WB._watchWrites then
                        RC:Print(RCL["WBkill[dedupe] dropped "] .. cur .. RCL[" (t-age="]
                            .. (time() - tc) .. RCL["s) kept "] .. k .. RCL[" (t-age="]
                            .. (time() - tk) .. "s)")
                    end
                    self.peers[cur] = nil
                    best[b] = k
                else
                    LogKill("dedupe", k, "kept=" .. cur)
                    if WB._watchWrites then
                        RC:Print(RCL["WBkill[dedupe] dropped "] .. k .. RCL[" (t-age="]
                            .. (time() - tk) .. RCL["s) kept "] .. cur .. RCL[" (t-age="]
                            .. (time() - tc) .. "s)")
                    end
                    self.peers[k] = nil
                end
            end
        end
    end

    -- True when a decoded relay says nothing our own record of that peer
    -- does not: same booned flag, the same buffs (a couple of seconds of
    -- slack, same stored/running split), and no different displacer count,
    -- zone or hand-in list. A relay's zone may have been cut down to fit,
    -- so one being the start of the other counts as the same place.
    local function SameBoardState(p, booned, buffs, frozen, chrono, location, dropped)
        if (p.booned and true or false) ~= (booned and true or false) then return false end
        local mine = p.buffs or {}
        buffs = buffs or {}
        for k, secs in pairs(buffs) do
            local have = mine[k]
            if not have or math.abs(have - secs) > 2 then return false end
            if ((p.frozen and p.frozen[k]) and true or false)
               ~= ((frozen and frozen[k]) and true or false) then
                return false
            end
        end
        for k, have in pairs(mine) do
            if have > 0 and not buffs[k] then return false end
        end
        if chrono ~= nil and p.chrono ~= nil and chrono ~= p.chrono then return false end
        local a, b = location or "", p.location or ""
        if a ~= "" and b ~= "" and a ~= b
           and a:sub(1, #b) ~= b and b:sub(1, #a) ~= a then
            return false
        end
        if dropped and HeadsCodes(dropped) ~= HeadsCodes(p.dropped) then return false end
        return true
    end

    function WB:OnRelay(from, sender, data, viaBNet)
        if type(data) ~= "string" then return end
        self._lastRelayHeard = time()
        local name, ageStr, onlineStr, buffData = string.match(data, "^(.-)~(%d+)~([01])~(.*)$")
        if not name then
            name, ageStr, buffData = string.match(data, "^(.-)~(%d+)~(.*)$")
            onlineStr = nil
        end
        local age = tonumber(ageStr)
        if not name or name == "" or not age or not buffData then return end
        -- The sender's "e" token is the data's time on the server clock.
        -- The age above was right when the relay was built; this is right
        -- now, however long it queued. A stamp that says the data is
        -- younger than its own built age cannot be true and is ignored. One
        -- that says the relay took longer than RELAY_QUEUE_MAX to get here
        -- is dropped whole: re-dating it from the built age would pass off
        -- data that old as recent.
        local stamped = false
        do
            local epoch = tonumber(string.match(";" .. buffData .. ";", ";e(%d+);"))
            if epoch then
                local exact = GetServerTime() - epoch
                if exact > age + RELAY_QUEUE_MAX then return end
                if exact >= age - 5 then
                    age = math_max(0, exact)
                    stamped = true
                end
            end
        end
        name = NormKey(name)
        if not name
           or name:find("@", 1, true)
           or name:find("#", 1, true) then
            return
        end
        if name == LocalKey() then return end
        -- WB:Decode returns 17 values and the tail order is
        -- ... chrono, dmfRem, level, gold, race. This list used to stop one
        -- short, so the 16th (gold) landed in the variable named `race` and
        -- the real race was dropped - relayed peers came out with no race at
        -- all. Relays never carry a "g" token (EncodePeerBuffs omits it on
        -- purpose: we do not forward someone's gold to third parties), so
        -- relayGold is normally nil and is read only to keep the positions
        -- honest.
        local booned, buffs, cd, hs, class, _, _, frozen, pvp, location, _, _, chrono, dmfRem, level, relayGold, race, heads, dropped = self:Decode(buffData)
        if booned == nil then return end
        if type(buffs) == "table" then
            for k, secs in pairs(buffs) do
                if not DurOk(k, secs) then
                    buffs[k] = nil
                end
            end
        end
        local now = time()
        local t = now - age
        if t > now then t = now end
        name = NormKey(name)
        -- A relay that names a peer without a realm suffix is dropped when
        -- the fuller "name-realm" key is already cached, so a lossy hop
        -- cannot fork one character into two roster rows.
        do
            local b = BaseName(name)
            if not name:find("-", 1, true) then
                for k in pairs(self.peers) do
                    if k ~= name and BaseName(k) == b
                       and k:find("-", 1, true) then
                        return
                    end
                end
            end
        end
        local rem = self.removals[name]
        if rem then
            if t <= rem then return end
            self.removals[name] = nil
        end
        local existing = self.peers[name]
        -- Gold rides a relay only when the sender is the account that owns
        -- the character (EncodeRecord adds it for p.own records alone), so
        -- it is authoritative: take it even when the rest of the relay is
        -- rejected below as stale, or for a BNet-tracked peer.
        if relayGold and existing and not existing.own then
            existing.gold  = relayGold
            existing.goldT = now
        end
        if existing and existing.bnetId then return end
        if existing and existing.own then
            local exN = 0
            if existing.buffs then for _ in pairs(existing.buffs) do exN = exN + 1 end end
            local inN = 0
            if buffs then for _ in pairs(buffs) do inN = inN + 1 end end
            if inN <= exN then return end
        end
        if WB._watchWrites then
            local bn = 0
            if buffs then for _ in pairs(buffs) do bn = bn + 1 end end
            RC:Print(RCL["WBwrite[relay] "] .. name .. RCL[" buffs="] .. bn .. RCL[" via="] .. tostring(from))
        end
        -- A relay repeating what we heard for ourselves is not news. Taking
        -- it anyway traded a first-hand record for hearsay - which we then
        -- stop passing on - every time someone's copy of the same broadcast
        -- arrived a second "newer" than ours. The record stays ours; if the
        -- relay's copy is clearly the later one, its details (cooldowns,
        -- level, zone) are folded in. The one thing such a relay can still
        -- tell us is that a peer we no longer hear is online - that goes on
        -- to the ordinary path below.
        -- Folding in moves t, and three things must not ride along with it:
        -- an unstamped relay's t includes its queue wait; a second or two
        -- of rounding would otherwise walk t forward relay after relay;
        -- and for a record of our own t counts as a sighting, so a data
        -- time inside the online window would put a toon we cannot hear -
        -- one that may just have said BYE - back online.
        local heard = existing and HeardDirectly(existing, now)
        if existing and existing.relayOnline == nil
           and not (onlineStr == "1" and not heard)
           and SameBoardState(existing, booned, buffs, frozen, chrono, location, dropped) then
            if stamped and t > (existing.t or 0) + 2
               and (heard or (now - t) > ONLINE_WINDOW) then
                existing.buffs, existing.frozen = buffs, frozen
                existing.cd, existing.hs, existing.dmfRem = cd, hs, dmfRem
                existing.t = t
                if chrono ~= nil then existing.chrono = chrono end
                if level then existing.level = level end
                if race then existing.race = race end
                if dropped then existing.dropped = dropped end
                -- never trade a full zone for one that was cut to fit
                if location and #location >= #(existing.location or "") then
                    existing.location = location
                end
            end
            return
        end
        -- Older-than-cached data never overwrites; only the presence flag is
        -- allowed to refresh from a stale relay.
        if existing and (existing.t or 0) >= t then
            if onlineStr ~= nil and existing.relayOnline ~= nil then
                existing.relayOnline = (onlineStr == "1")
                existing.presenceT   = now
                if type(viaBNet) == "number" then existing.srcBnetId = viaBNet end
            end
            return
        end
        local relayOnline = nil
        if onlineStr ~= nil then relayOnline = (onlineStr == "1") end
        -- Our own ears beat a relayed "offline": a catch-up always sends the
        -- frozen snapshot, and a peer we heard seconds ago with no BYE since
        -- is not offline because somebody else's copy says so. Presence then
        -- runs off our own sightings, as for any record we wrote ourselves.
        if relayOnline == false and heard then relayOnline = nil end
        -- A numeric viaBNet is a real BNet whisper; true is just a yell.
        local xfRoster = (type(viaBNet) == "number") or (existing and existing.xfRoster) or nil
        self.peers[name] = {
            label  = name,
            name   = name,
            class  = class,
            booned = booned,
            buffs  = buffs,
            frozen = frozen,
            cd     = cd,
            hs     = hs,
            chrono = chrono,
            t      = t,
            -- A relay is hearsay; the direct presence stamp is kept.
            seenAt = existing and existing.seenAt or nil,
            location = location or (existing and existing.location) or nil,
            dmfRem   = dmfRem or nil,
            level    = level or (existing and existing.level) or nil,
            pvp      = pvp or (existing and existing.pvp) or nil,
            race     = race or (existing and existing.race) or nil,
            heads    = heads,
            dropped  = dropped or (existing and existing.dropped) or nil,
            -- This is a whole-record replacement, and a relay payload has no
            -- gold in it. Without carrying the cached value forward, a relay
            -- arriving for a character we already knew directly over the mesh
            -- erased their gold - which is why a toon's gold would show up in
            -- the GOLD roster and then quietly vanish once a guildmate
            -- relayed them. Every other optional field above already had this
            -- fallback; gold was the one that was missed.
            gold     = relayGold or (existing and existing.gold) or nil,
            goldT    = (relayGold and now) or (existing and existing.goldT) or nil,
            relayOnline = relayOnline,
            presenceT   = (relayOnline ~= nil) and now or nil,
            srcBnetId   = (type(viaBNet) == "number") and viaBNet
                          or (existing and existing.srcBnetId) or nil,
            xfRoster    = xfRoster,
        }
        RC:DebugPrint("WorldBuffSync: relay-learned " .. tostring(name)
            .. " (age " .. age .. "s)", "meshsync")
    end

    WB._killLog = WB._killLog or {}
    C_Timer.After(3, function()
        if RC.db and RC.db.wbWatchWrites then WB._watchWrites = true end
    end)
    function WB:RemovePeer(name)
        if not name or name == "" then return false end
        name = NormKey(name)
        if name == LocalKey() then return false end
        LogKill("manual-remove", name, "")
        self.removals[name] = time()
        self.peers[name] = nil
        if MeshOn() and RC.MeshSync.Broadcast then
            RC.MeshSync:Broadcast("WBDEL", name .. "~0")
            RC:DebugPrint("WorldBuffSync: removed " .. tostring(name) .. " + broadcast", "meshsync")
        else
            RC:DebugPrint("WorldBuffSync: removed " .. tostring(name) .. " (mesh off, local only)", "meshsync")
        end
        return true
    end

    function WB:RelayRemovals()
        if not MeshOn() or not RC.MeshSync.Broadcast then return end
        if RC.MeshSync.SetNextSendPriority then RC.MeshSync:SetNextSendPriority() end
        local now = time()
        if self._lastRemovalRelay and (now - self._lastRemovalRelay) < RELAY_MIN_INTERVAL then return end
        local sent, names = 0, ""
        for name, rt in pairs(self.removals) do
            local age = now - (rt or 0)
            -- Removals are re-broadcast for 6 hours, then forgotten. Past
            -- that a peer who is genuinely back must be able to reappear.
            if age >= 0 and age <= 6 * 3600 then
                RC.MeshSync:Broadcast("WBDEL", name .. "~" .. math_floor(age))
                sent = sent + 1
                names = (names == "") and tostring(name) or (names .. ", " .. tostring(name))
            else
                self.removals[name] = nil
            end
        end
        if sent > 0 then
            self._lastRemovalRelay = now
            RC:DebugPrint("WorldBuffSync: re-broadcast " .. sent .. " removal(s): " .. names, "meshsync")
        end
    end

    function WB:OnRemoval(from, sender, data)
        if type(data) ~= "string" then return end
        local name, ageStr = string.match(data, "^(.-)~(%d+)$")
        local age = tonumber(ageStr)
        if not name or name == "" or not age then return end
        name = NormKey(name)
        if name == LocalKey() then return end
        if age > 6 * 3600 then
            RC:DebugPrint("WorldBuffSync: ignored stale removal for "
                .. tostring(name) .. " (age " .. age .. "s)", "meshsync")
            return
        end
        local now = time()
        local removedAt = now - age
        if removedAt > now then removedAt = now end
        if removedAt > (self.removals[name] or 0) + 60 then
            self.removals[name] = removedAt
        end
        -- A peer heard from in the last 120s outranks any removal: someone
        -- else's stale delete must not evict a character we can see live.
        local p = self.peers[name]
        if p and (now - LastSeen(p)) <= 120 then
            if WB._watchWrites then
                RC:Print(RCL["WBkill[removal-SPARED] "] .. name .. RCL[" t-age="]
                    .. (now - LastSeen(p)) .. RCL["s vs removedAt-age="] .. age .. "s")
            end
        elseif p and LastSeen(p) <= removedAt then
            LogKill("removal", name, "t-age=" .. (now - LastSeen(p)) .. "s removal-age=" .. age .. "s from=" .. tostring(from))
            if WB._watchWrites then
                RC:Print(RCL["WBkill[removal] "] .. name .. RCL[" t-age="]
                    .. (now - LastSeen(p)) .. RCL["s removal-age="] .. age
                    .. RCL["s from="] .. tostring(from))
            end
            self.peers[name] = nil
        end
        RC:DebugPrint("WorldBuffSync: inbound removal for " .. tostring(name)
            .. " (age " .. age .. "s)", "meshsync")
    end

    -- Ages a stored record forward to "now". Frozen (chronoboon-stored)
    -- entries pass through untouched - they are a stored duration, not a
    -- running one - and anything that has aged out is dropped entirely.
    local function LiveBuffs(buffs, frozenSet, t, now)
        local out = {}
        local age = now - (t or now)
        for key, secs in pairs(buffs) do
            if frozenSet and frozenSet[key] then
                out[key] = secs
            else
                local rem = secs - age
                if rem > 0 then out[key] = math_floor(rem) end
            end
        end
        return out
    end

    local function BuffCount(buffs)
        local n = 0
        for _ in pairs(buffs) do n = n + 1 end
        return n
    end

    function WB:GetRoster()
        local now = time()
        local selfKey = LocalKey()
        local list = {}

        for name, rt in pairs(self.removals) do
            if (now - (rt or 0)) > GC_MAX then self.removals[name] = nil end
        end

        local localDMF
        do
            local rec = self.peers[selfKey]
            local d = rec and rec.dmfRem
            if d and self._dmfStamp then d = d - (now - self._dmfStamp) end
            if d and d <= 0 then d = nil end
            localDMF = d
        end
        local lb, lbuffs, lfrozen = self:BuildAuraSnapshot()
        local _, classFile = UnitClass("player")
        list[#list + 1] = {
            name    = UnitName("player") or "You",
            label   = RCL["(you)"],
            isLocal = true,
            online  = true,
            booned  = lb,
            frozen  = lfrozen,
            cd      = self:ReadReboonCD(),
            hs      = self:ReadHearthstoneCD(),
            buffs   = LiveBuffs(lbuffs, lfrozen, now, now),
            class   = classFile,
            count   = BuffCount(lbuffs),
            chrono  = ((GetItemCount and GetItemCount(184937)) or 0)
                + ((GetItemCount and GetItemCount(184938)) or 0),
            pvp      = UnitIsPVP("player") and true or false,
            location = self:CurrentLocation(),
            dmfRem   = localDMF,
            level    = UnitLevel("player"),
            race     = select(2, UnitRace("player")),
            heads    = ReadHeads(),
            dropped  = ReadDropped() or {},
        }

        for key, p in pairs(self.peers) do
            -- Presence age; buff/cd ageing below still subtracts from p.t.
            local age = now - LastSeen(p)
            -- Roster read doubles as the garbage collector: anything older
            -- than GC_MAX leaves the cache here.
            if age > GC_MAX then
                LogKill("gc", key, "t-age=" .. age .. "s")
                if WB._watchWrites then
                    RC:Print(RCL["WBkill[gc] "] .. tostring(key) .. RCL[" t-age="] .. age .. "s")
                end
                self.peers[key] = nil
            elseif key ~= selfKey then
                local pfrozen = p.frozen
                if p.booned and not pfrozen then
                    pfrozen = {}
                    for k in pairs(p.buffs or {}) do
                        local d = DEF_BY_KEY[k]
                        if d and d.slot then pfrozen[k] = true end
                    end
                end
                local live = LiveBuffs(p.buffs or {}, pfrozen, p.t, now)
                -- fnow is the instant the record is aged to: "now" while the
                -- peer is online, otherwise the moment they dropped, which
                -- parks their buffs at their last known values instead of
                -- ticking them down while they are logged out.
                local isOnline, fnow
                if p.bnetId then
                    isOnline = p.bnetOnline and true or false
                    fnow     = isOnline and now or (p.offlineAt or now)
                elseif p.relayOnline ~= nil then
                    local presAge = now - (p.presenceT or LastSeen(p))
                    isOnline = (p.relayOnline and presAge <= RELAY_PRESENCE_TTL) and true or false
                    fnow     = isOnline and now or (p.t or now)
                else
                    isOnline = age <= ONLINE_WINDOW
                        and not (p.byeAt and p.byeAt >= LastSeen(p))
                    fnow     = isOnline and now or (p.t or now)
                end
                local fage = fnow - (p.t or 0)
                local cdAge = now - (p.t or 0)
                if fnow ~= now then live = LiveBuffs(p.buffs or {}, pfrozen, p.t, fnow) end
                local pd = p.dmfRem
                if pd then
                    if isOnline then
                        pd = pd - (now - (p.t or now))
                    elseif MAJOR_CITIES[p.location or ""]
                       and (now - (p.t or now)) >= DMF_CITY_FALL then
                        pd = nil
                    end
                    if pd and pd <= 0 then pd = nil end
                end
                list[#list + 1] = {
                    name    = p.name,
                    label   = p.label,
                    isLocal = false,
                    online  = isOnline,
                    booned  = p.booned,
                    frozen  = pfrozen,
                    cd      = p.cd and math_max(0, p.cd - cdAge) or nil,
                    hs      = p.hs and math_max(0, p.hs - cdAge) or nil,
                    chrono  = p.chrono,
                    buffs   = live,
                    class   = p.class,
                    count   = BuffCount(live),
                    pvp      = p.pvp,
                    location = p.location,
                    dmfRem   = pd,
                    level    = p.level,
                    race     = p.race,
                    heads    = p.heads,
                    dropped  = p.dropped,
                }
            end
        end

        table.sort(list, function(a, b)
            if a.isLocal ~= b.isLocal then return a.isLocal end
            if a.count ~= b.count then return a.count < b.count end
            return (a.name or "") < (b.name or "")
        end)
        return list
    end

    function WB:Counts()
        local now, online, tracked = time(), 0, 0
        local selfKey = LocalKey()
        for key, p in pairs(self.peers) do
            local age = now - LastSeen(p)
            if key ~= selfKey and age <= GC_MAX then
                tracked = tracked + 1
                if p.bnetId then
                    if p.bnetOnline then online = online + 1 end
                elseif p.relayOnline ~= nil then
                    local presAge = now - (p.presenceT or LastSeen(p))
                    if p.relayOnline and presAge <= RELAY_PRESENCE_TTL then online = online + 1 end
                elseif not PeerOffline(p, now) then
                    online = online + 1
                end
            end
        end
        return online, tracked
    end

    function WB:ReadNWBSelfDMF()
        local db = _G.NWBdatabase
        if type(db) ~= "table" or type(db.global) ~= "table" then return nil end
        local rd = db.global[GetRealmName()]
        local fd = rd and rd[UnitFactionGroup("player") or ""]
        local chars = fd and fd.myChars
        local me = chars and chars[UnitName("player")]
        if type(me) ~= "table" then return nil end
        local now = GetServerTime()
        for k, v in pairs(me) do
            if type(k) == "string" and type(v) == "number"
               and k:lower():find("dmf", 1, true)
               and (k:lower():find("cool", 1, true) or k:lower():find("cd", 1, true)) then
                if v > 1000000000 then
                    local rem = v - now
                    return rem > 0 and rem or 0
                elseif v >= 0 and v < 1209600 then
                    return v
                end
            end
        end
        return nil
    end

    function WB:ReadNWB()
        local db = _G.NWBdatabase
        if type(db) ~= "table" or type(db.global) ~= "table" then return nil end
        local rd = db.global[GetRealmName()]
        local fd = rd and rd[UnitFactionGroup("player") or ""]
        if type(fd) ~= "table" then return nil end
        local now = GetServerTime()
        local out = {}

        -- Staleness rule and layer-aware minimum are WBT_Core's
        -- (WBT.SoonestRemaining): a timestamp is good for one cooldown past
        -- coming up, after which it is stale rather than "Ready", so a
        -- long-dead layer entry cannot clamp to 0, win the minimum forever
        -- and pin the footer to "Ready". fd is NWB-shaped (aggregate field
        -- plus optional .layers), which is exactly what the helper traverses.
        local soonestRemaining = RC.WorldBuffTimers.SoonestRemaining
        local function cityNext(field, cd)
            return soonestRemaining(fd, field, cd)
        end
        local r = cityNext("rendTimer", DROP_CD.warchief); if r ~= nil then out.warchief = r end
        local o = cityNext("onyTimer",  DROP_CD.rally);     if o ~= nil then out.rally    = o end

        local sfNext, sfData = nil, false
        local function scanFlowers(tbl)
            for i = 1, 10 do
                local pick = tonumber(tbl["flower" .. i])
                if pick and pick > 0 then
                    sfData = true
                    local rem = (pick + DROP_CD.songflower) - now
                    if rem > 0 and (sfNext == nil or rem < sfNext) then sfNext = rem end
                end
            end
        end
        scanFlowers(fd)
        if type(fd.layers) == "table" then
            -- (either shape: Nova World Buffs 3.48+ nests its layers by world)
            for _, lyr in pairs(RC.WorldBuffTimers.FlatLayers(fd.layers)) do
                if type(lyr) == "table" then scanFlowers(lyr) end
            end
        end
        if sfData then out.songflower = sfNext or 0 end

        if next(out) == nil then return nil end
        return out
    end

    function WB:OurOnyxiaNextAt()
        local nwb = self:ReadNWB()
        local rem = nwb and nwb.rally
        -- A timer that is up clamps to 0 and would drift the signature by
        -- one second per read; nothing pending means no token at all.
        if not rem or rem <= 0 then return nil end
        return GetServerTime() + math_floor(rem)
    end

    function WB:OnOppOny(data)
        local at = tonumber(data)
        if not at or at <= GetServerTime() then return end
        if at > (self.oppOnyAt or 0) then self.oppOnyAt = at end
    end

    function WB:GetOppositeOnyxia()
        if self.oppOnyAt then
            local rem = self.oppOnyAt - GetServerTime()
            if rem and rem > 0 then return rem end
            if rem and rem <= 0 then return 0 end
        end
        local db = _G.NWBdatabase
        if type(db) ~= "table" or type(db.global) ~= "table" then return nil end
        local rd = db.global[GetRealmName()]
        if type(rd) ~= "table" then return nil end
        local mine = UnitFactionGroup("player") or ""
        local opp  = (mine == "Horde") and "Alliance" or "Horde"
        local fd = rd[opp]
        if type(fd) ~= "table" then return nil end
        local now, cd = GetServerTime(), DROP_CD.rally
        local soonest
        local function consider(t)
            t = tonumber(t)
            if t and t > 0 then
                local rem = (t + cd) - now
                if rem < 0 then rem = 0 end
                if soonest == nil or rem < soonest then soonest = rem end
            end
        end
        local usedLayer = false
        if type(fd.layers) == "table" then
            -- (either shape: Nova World Buffs 3.48+ nests its layers by world)
            for _, lyr in pairs(RC.WorldBuffTimers.FlatLayers(fd.layers)) do
                if type(lyr) == "table" and tonumber(lyr.onyTimer) then
                    consider(lyr.onyTimer); usedLayer = true
                end
            end
        end
        if not usedLayer then consider(fd.onyTimer) end
        return soonest
    end

    function WB:GetDrops()
        local nwb = self:ReadNWB()
        local now = time()
        local out = {}
        for _, d in ipairs(DROP_TRACK) do
            local rem, known
            if nwb and nwb[d.key] ~= nil then
                rem, known = nwb[d.key], true
            elseif d.key == "songflower" then
                local sfNext, sfData = nil, false
                for _, t in pairs(self.dropLog.flowers or {}) do
                    sfData = true
                    local r = (t + d.cd) - now
                    if r > 0 and (sfNext == nil or r < sfNext) then sfNext = r end
                end
                if sfData then rem, known = (sfNext or 0), true end
            else
                local t = self.dropLog[d.key]
                known = (t ~= nil)
                if t then
                    rem = d.cd - (now - t)
                    if rem < 0 then rem = 0 end
                end
            end
            local entry = { key = d.key, label = d.label, id = d.id, known = known, cdRemaining = rem }
            if d.key == "rally" then
                entry.oppRemaining = self:GetOppositeOnyxia()
            end
            out[#out + 1] = entry
        end
        return out
    end

    function WB:ReadNWBFlowers()
        local db = _G.NWBdatabase
        if type(db) ~= "table" or type(db.global) ~= "table" then return nil end
        local rd = db.global[GetRealmName()]
        local fd = rd and rd[UnitFactionGroup("player") or ""]
        if type(fd) ~= "table" then return nil end
        local out, any = {}, false
        local function scan(tbl)
            for i = 1, 10 do
                local t = tonumber(tbl["flower" .. i])
                if t and t > 0 and (out[i] == nil or t > out[i]) then out[i] = t; any = true end
            end
        end
        scan(fd)
        if type(fd.layers) == "table" then
            -- (either shape: Nova World Buffs 3.48+ nests its layers by world)
            for _, lyr in pairs(RC.WorldBuffTimers.FlatLayers(fd.layers)) do
                if type(lyr) == "table" then scan(lyr) end
            end
        end
        if not any then return nil end
        return out
    end

    function WB:GetSongflowerNodes()
        local now = time()
        local best = {}
        for idx, t in pairs(self.dropLog.flowers or {}) do
            if t and (best[idx] == nil or t > best[idx]) then best[idx] = t end
        end
        local nd = self:ReadNWBFlowers()
        if nd then
            for idx, t in pairs(nd) do
                if t and (best[idx] == nil or t > best[idx]) then best[idx] = t end
            end
        end
        local out = {}
        for idx, t in pairs(best) do
            local rem = (t + DROP_CD.songflower) - now
            if rem > 0 then
                local node = FLOWER_NODES[idx]
                out[#out + 1] = {
                    idx = idx,
                    rem = rem,
                    x = node and node.x,
                    y = node and node.y,
                    name = node and node.name,
                }
            end
        end
        table.sort(out, function(a, b) return a.rem < b.rem end)
        return out
    end

    do
        local wbWatch = {}
        for _, def in ipairs(BUFFS) do
            if def.ids then
                for _, id in ipairs(def.ids) do wbWatch[#wbWatch + 1] = id end
            end
        end
        for id in pairs(STORED_IDS) do wbWatch[#wbWatch + 1] = id end
        -- UNIT_AURA is funnelled through the shared 0.2s throttled callback,
        -- and only the watched spell ids wake it at all.
        -- A changed snapshot is sent at most once per WB_MIN_SEND_GAP;
        -- anything that changes inside the gap is picked up by one
        -- deferred send, so a buff drop landing six auras in a row costs
        -- one message, not six.
        local function BroadcastIfChanged()
            local booned, buffs = WB:BuildAuraSnapshot()
            if booned == nil or WB:Signature(booned, buffs) == WB._lastSig then return end
            local wait = WB_MIN_SEND_GAP - (time() - (WB._lastFullSend or 0))
            if wait <= 0 then
                WB:Broadcast()
            elseif not WB._auraSendPending then
                WB._auraSendPending = true
                C_Timer.After(wait, function()
                    WB._auraSendPending = nil
                    BroadcastIfChanged()
                end)
            end
        end
        -- The same buffs by name. BUFFS lists Battle Shout by its rank 1
        -- id alone; every other rank, and the long 400 AP one this board
        -- exists to show, carries the same name under a different id. The
        -- id list above never woke for those, so the news waited for the
        -- next 30s heartbeat - too late for anyone who logs out first.
        -- Battle Shout is watched only at the length the snapshot keeps:
        -- the two-minute raid shout must not wake this all fight long.
        local wbWatchNames = {}
        for name, key in pairs(NAME_TO_KEY) do
            wbWatchNames[name] = (key == "battleshout") and LONG_SHOUT_SECS or 0
        end
        RC:RegisterUnitAuraCallback("WorldBuffSync", 0.2, function()
            BroadcastIfChanged()
            -- Second look 2s later: unbooning lands the stored buffs one
            -- at a time, so the first snapshot catches only part of it.
            C_Timer.After(2, BroadcastIfChanged)
        end, wbWatch, wbWatchNames)
    end

    -- The re-broadcast gate: an unchanged signature sends nothing until the
    -- last full send is 300s old, so a stable raid costs one message every
    -- five minutes per player instead of one every heartbeat.
    local function Heartbeat()
        if FeatureEnabled() then
            local lb, lbuffs = WB:BuildAuraSnapshot()
            if lb ~= nil and WB:Signature(lb, lbuffs) == WB._lastSig
               and (time() - (WB._lastFullSend or 0)) < 300 then
            else
                WB:Broadcast()
            end
            WB:RelayRoster()
            WB:RelayRemovals()
        end
    end
    if RC.Profiler and RC.Profiler.TrackTicker then
        WB._heartbeat = RC.Profiler:TrackTicker("WorldBuffSync:Heartbeat", HEARTBEAT, Heartbeat)
    else
        WB._heartbeat = C_Timer.NewTicker(HEARTBEAT, Heartbeat)
    end

    local function RefreshXfPresence()
        if not (RC.MeshSync and RC.MeshSync.IsBnetFriendInWoW) then return end
        local now = time()
        local changed = false
        local bridgeLive = {}
        local function BridgeInWoW(id)
            local v = bridgeLive[id]
            if v == nil then
                v = RC.MeshSync:IsBnetFriendInWoW(id) and true or false
                bridgeLive[id] = v
            end
            return v
        end
        for _, p in pairs(WB.peers) do
            if p.viaBNet and p.bnetId then
                if BridgeInWoW(p.bnetId) then
                    if p.bnetOnline ~= true then changed = true end
                    p.bnetOnline = true
                    p.offlineAt  = nil
                elseif p.bnetOnline ~= false then
                    p.bnetOnline = false
                    p.offlineAt  = now
                    changed = true
                end
            elseif p.xfRoster and p.srcBnetId and p.relayOnline then
                if BridgeInWoW(p.srcBnetId) then
                    p.presenceT = now
                end
            end
        end
        if changed then
            WB._lastRelay = nil
            WB:RelayRoster()
        end
    end
    if RC.Profiler and RC.Profiler.TrackTicker then
        WB._xfPresence = RC.Profiler:TrackTicker("WorldBuffSync:XfPresence", 10, RefreshXfPresence)
    else
        WB._xfPresence = C_Timer.NewTicker(10, RefreshXfPresence)
    end

    local evt = CreateFrame("Frame")
    evt:RegisterEvent("PLAYER_ENTERING_WORLD")
    evt:RegisterEvent("PLAYER_LOGOUT")
    evt:RegisterEvent("PLAYER_MONEY")
    evt:RegisterEvent("QUEST_TURNED_IN")
    local goldPending = false
    local bagCheckPending = false
    local function BagChronoCheck()
        bagCheckPending = false
        local n = ((GetItemCount and GetItemCount(184937)) or 0)
            + ((GetItemCount and GetItemCount(184938)) or 0)
        -- First bag settle after login has no baseline yet; the login
        -- broadcast already covers it, so only a real change sends.
        local hc = HeadsCodes(ReadHeads())
        local headsChanged = (WB._lastHeads ~= nil and hc ~= WB._lastHeads)
        WB._lastHeads = hc
        if (WB._lastChrono ~= nil and n ~= WB._lastChrono) or headsChanged then WB:Broadcast() end
        WB._lastChrono = n
    end

    -- A matching hand-in flips this toon's completion flag; the bags and
    -- the flag settle a moment later, so the broadcast waits for them.
    function WB:OnQuestTurnedIn(questID)
        local d = TURNIN_BY_QUEST[tonumber(questID) or 0]
        if not d then return end
        RC:DebugPrint("WorldBuffSync: handed in " .. d.key, "worldbuffs")
        C_Timer.After(2, function() if MeshOn() then WB:Broadcast() end end)
    end
    -- Chronoboon and head counts: one guarded 1s check after the bags
    -- really changed (shared bag index).
    RC.Bags:OnChange("WorldBuffSync", function()
        if bagCheckPending then return end
        bagCheckPending = true
        C_Timer.After(1.0, BagChronoCheck)
    end)
    evt:SetScript("OnEvent", function(_, event, arg1)
        if event == "QUEST_TURNED_IN" then
            WB:OnQuestTurnedIn(arg1)
            return
        end
        if event == "PLAYER_MONEY" then
            if goldPending then return end
            -- 10000 copper = 1 gold: vendor trash and repairs must not
            -- trigger a broadcast. Real changes coalesce over 5s - long
            -- enough to fold a looting burst into one send, short enough
            -- that a trade followed by a quick logout still gets out.
            local cur = (GetMoney and GetMoney()) or 0
            if math.abs(cur - (WB._lastGoldSent or 0)) < 10000 then return end
            goldPending = true
            C_Timer.After(5, function()
                goldPending = false
                if WB.Broadcast then WB:Broadcast() end
            end)
            return
        end
        -- Last write before the cache is serialized to disk. If the final
        -- RecordSelf errors or comes back with fewer buffs than the record
        -- already held, the old record is put back: a bad read at logout
        -- would otherwise be the state loaded next session.
        if event == "PLAYER_LOGOUT" then
            local key = LocalKey()
            local before = WB.peers[key]
            local beforeN = 0
            if before and before.buffs then
                for _ in pairs(before.buffs) do beforeN = beforeN + 1 end
            end
            local beforeCopy = before
            local ok = pcall(function() WB:RecordSelf() end)
            local rec = WB.peers[key]
            local afterN = 0
            if rec and rec.buffs then
                for _ in pairs(rec.buffs) do afterN = afterN + 1 end
            end
            if (not ok or afterN < beforeN) and beforeCopy then
                WB.peers[key] = beforeCopy
                rec = beforeCopy
                if rec.dmfRem and WB._dmfStamp then
                    rec.dmfRem = rec.dmfRem - (time() - WB._dmfStamp)
                    if rec.dmfRem <= 0 then rec.dmfRem = nil end
                end
                -- The restored record keeps its buffs but must not keep a
                -- pre-trade balance: this is the value every other account
                -- will relay for this toon until it logs in again.
                local money = GetMoney and GetMoney()
                if money and money > 0 then
                    rec.gold  = money
                    rec.goldT = time()
                end
                rec.t = time()
            end
            local n = 0
            if rec and rec.buffs then for _ in pairs(rec.buffs) do n = n + 1 end end
            ReadycheckDB._wbLogoutDiagKey = LocalKey()
            ReadycheckDB._wbLogoutDiagN   = n
            ReadycheckDB._wbLogoutDiagT   = time()
            return
        end
        if not WB._dedupedOnce then
            WB._dedupedOnce = true
            WB:DedupePeers()
        end
        WB:RecordSelf()
        C_Timer.After(3, function()
            WB:Broadcast()
        end)
        C_Timer.After(10, function()
            WB:RecordSelf()
        end)
    end)

    function WB:HandleDiagCommand(msg)
        return WB._diagHandler(msg)
    end
    SLASH_READYCHECKWBDUMP1 = "/wbdump"
    WB._diagHandler = function(msg)
        if msg and string.match(msg, "^%s*load") then
            RC:Print(RCL["Previous logout stored: "]
                .. tostring(ReadycheckDB._wbLogoutDiagKey) .. " = "
                .. tostring(ReadycheckDB._wbLogoutDiagN) .. RCL[" buff(s), "]
                .. (ReadycheckDB._wbLogoutDiagT
                    and (math_floor((time() - ReadycheckDB._wbLogoutDiagT) / 60) .. "m ago")
                    or "never"))
            RC:Print(RCL["This session loaded from disk:"])
            local any = false
            for k, n in pairs(WB._loadedCounts or {}) do
                any = true
                RC:Print("  " .. k .. " = " .. n .. RCL[" buff(s)"])
            end
            if not any then RC:Print(RCL["  (nothing)"]) end
            return
        end
        do
            local mins = msg and string.match(msg, "^%s*dmf%s+(%d+)")
            if mins then
                local rec = WB.peers[LocalKey()]
                if rec then
                    rec.dmfRem = tonumber(mins) * 60
                    WB._dmfStamp = time()
                    RC:Print(RCL["DMF lockout set to "] .. mins .. RCL["m for this character."])
                else
                    RC:Print(RCL["No record for this character yet - wait a few seconds after login and retry."])
                end
                return
            end
        end
        if msg and string.match(msg, "^%s*dmfreset") then
            local rec = WB.peers[LocalKey()]
            if rec then rec.dmfRem = nil end
            RC:Print(RCL["DMF lockout tracking cleared for this character - it re-learns "]
                .. RCL["exactly from the next fortune taken (or backfills from a live buff)."])
            return
        end
        if msg and string.match(msg, "^%s*write") then
            local ok, err = pcall(function() WB:RecordSelf() end)
            if not ok then
                RC:Print(RCL["RecordSelf ERROR: "] .. tostring(err))
                return
            end
            local rec = WB.peers[LocalKey()]
            local n = 0
            if rec and rec.buffs then for _ in pairs(rec.buffs) do n = n + 1 end end
            RC:Print(RCL["RecordSelf stored: "] .. n .. RCL[" buff(s)"]
                .. ((rec and rec.booned) and " (booned)" or "")
                .. ((rec and rec.own) and " (own)" or ""))
            return
        end
        if msg and string.match(msg, "^%s*purge") then
            local selfKey = LocalKey()
            local now = time()
            local purged = 0
            for key, p in pairs(WB.peers) do
                if key ~= selfKey then
                    local isOnline = ((now - LastSeen(p)) <= 90)
                        and not (p.byeAt and p.byeAt >= LastSeen(p))
                    if not isOnline and (not p.level or p.level < 60) then
                        LogKill("purge", key, "level=" .. tostring(p.level or "UNKNOWN"))
                        WB.peers[key] = nil
                        purged = purged + 1
                    end
                end
            end
            RC:Print(RCL["WB purge: removed "] .. purged .. RCL[" offline row(s) with unknown"]
                .. RCL[" or sub-60 level. Live toons re-appear with correct levels on"]
                .. RCL[" their next broadcast."])
            return
        end
        if msg and string.match(msg, "^%s*watch") then
            WB._watchWrites = not WB._watchWrites
            if RC.db then RC.db.wbWatchWrites = WB._watchWrites end
            RC:Print(RCL["WB write tracing "] .. (WB._watchWrites and "ON - every cache write will print (path, key, buff count, source). Watch for 30s, paste what appears." or "OFF"))
            return
        end
        if msg and string.match(msg, "^%s*self") then
            RC:Print(RCL["WB self-check on "] .. LocalKey() .. ":")
            RC:Print(RCL["  supercharged item count: "] .. tostring(GetItemCount and GetItemCount(184938) or "n/a"))
            local idx, sidFound
            for i = 1, 40 do
                local nm, _, _, sid = ReadBuff(i)
                if not nm then break end
                if (sid and STORED_IDS[sid]) or nm == "Supercharged Chronoboon Displacer" then
                    idx, sidFound = i, sid
                    break
                end
            end
            RC:Print(RCL["  boon aura: "] .. (idx and ("index " .. idx .. " spellId " .. tostring(sidFound)) or "NOT FOUND"))
            if idx then
                local r = { UnitBuff("player", idx) }
                RC:Print(RCL["  aura returns: "] .. #r .. RCL[" values"])
                local slotHits = 0
                for _, def in ipairs(BUFFS) do
                    if def.slot and type(r[def.slot]) == "number" and r[def.slot] > 0 then
                        slotHits = slotHits + 1
                    end
                end
                RC:Print(RCL["  slot-read stored buffs: "] .. slotHits)
            end
            do
                local function CountLinesAndHits(lines)
                    local hits = 0
                    for li = 1, #lines do
                        local text = lines[li].text
                        if text then
                            for _, def in ipairs(BUFFS) do
                                if def.slot and string.find(text, def.tipName or def.name, 1, true) then
                                    hits = hits + 1
                                    break
                                end
                            end
                        end
                    end
                    return #lines, hits
                end
                if idx then
                    local l, h = CountLinesAndHits(
                        RC.Compat.TooltipLines("unitbuff", "player", idx))
                    RC:Print(RCL["  aura tooltip: "] .. l .. RCL[" lines, "] .. h .. RCL[" buff-name hits"])
                end
                local fb, fsL
                for bag = 0, 4 do
                    local n = C_Container.GetContainerNumSlots(bag) or 0
                    for s = 1, n do
                        if C_Container.GetContainerItemID(bag, s) == 184938 then fb, fsL = bag, s break end
                    end
                    if fb then break end
                end
                RC:Print(RCL["  item in bags: "] .. (fb and (fb .. "/" .. fsL) or "not found"))
                if fb then
                    local l, h = CountLinesAndHits(
                        RC.Compat.TooltipLines("bagitem", fb, fsL))
                    RC:Print(RCL["  item tooltip: "] .. l .. RCL[" lines, "] .. h .. RCL[" buff-name hits"])
                end
            end
            WB._boonScanCache = nil
            local booned2, buffs2, frozen2 = WB:BuildAuraSnapshot()
            local names = {}
            for k in pairs(buffs2) do names[#names + 1] = k .. (frozen2[k] and "*" or "") end
            table.sort(names)
            RC:Print(RCL["  final snapshot: booned="] .. tostring(booned2) .. RCL[", buffs: "]
                .. (#names > 0 and table.concat(names, ", ") or "NONE") .. RCL[" (* = frozen)"])
            return
        end
        if msg and string.match(msg, "^%s*tip") then
            local lines
            for i = 1, 40 do
                local name, _, _, sid = ReadBuff(i)
                if not name then break end
                if (sid and STORED_IDS[sid]) or name == "Supercharged Chronoboon Displacer" then
                    lines = RC.Compat.TooltipLines("unitbuff", "player", i)
                    RC:Print(RCL["boon AURA tooltip:"])
                    break
                end
            end
            if not lines and C_Container and C_Container.GetContainerNumSlots then
                for bag = 0, 4 do
                    local n = C_Container.GetContainerNumSlots(bag) or 0
                    for s = 1, n do
                        if C_Container.GetContainerItemID(bag, s) == 184938 then
                            lines = RC.Compat.TooltipLines("bagitem", bag, s)
                            RC:Print(RCL["boon ITEM tooltip:"])
                            break
                        end
                    end
                    if lines then break end
                end
            end
            if not lines then RC:Print(RCL["no boon aura or supercharged item found"]) return end
            for li = 1, #lines do
                local text = lines[li].text
                if text and text ~= "" then RC:Print("  [" .. li .. "] " .. text) end
            end
            return
        end
        local nowT = time()
        RC:Print(RCL["WB cache - this toon: "] .. LocalKey())
        local n = 0
        for key, p in pairs(WB.peers) do
            n = n + 1
            local buffN = 0
            if p.buffs then for _ in pairs(p.buffs) do buffN = buffN + 1 end end
            RC:Print("  " .. key .. " - " .. buffN .. RCL[" buff(s)"]
                .. (p.booned and " (booned)" or "")
                .. (p.own and " (own)" or "") .. ", "
                .. math_floor((nowT - LastSeen(p)) / 60) .. RCL["m old"]
                .. (p.location and (", " .. p.location) or ""))
        end
        if n == 0 then RC:Print(RCL["  (cache is empty)"]) end
    end
    SlashCmdList["READYCHECKWBDUMP"] = WB._diagHandler

    EnsureDB()
    RC:DebugPrint("WorldBuffSync module loaded", "system")
end

C_Timer.After(0.5, InitializeWorldBuffSync)

local _WRm = _G.Readycheck
if _WRm then
    _WRm._buildMarks = _WRm._buildMarks or {}
    _WRm._buildMarks["worldbuffs"] = "boon-double-tap"
end
