------------------------------------------------------------------------
-- Readycheck - World Buff Timers Detect
-- Local detection feeding the timer store + network: buff drops (CLEU),
-- NPC yells/deaths, quest hand-ins, songflower picks, DMF fortunes, and
-- capital-city layer identity from creature GUIDs.
-- Local ALERTS stay in WorldTools (no overlap); this module only alerts
-- for relayed network events WorldTools cannot see, routed through the
-- existing WT.Bars pipeline.
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end
local RC = _G.Readycheck
if not RC or not RC.WorldBuffTimers then return end
local WBT = RC.WorldBuffTimers

WBT.Detect = WBT.Detect or {}
local Detect = WBT.Detect

local GetServerTime = GetServerTime
local strsplit = strsplit

local ZONE_CAPITAL_H = 1454
local ZONE_CAPITAL_A = 1453
local ZONE_BARRENS   = 1413
local ZONE_FELWOOD   = 1448

local function currentZone()
    return (C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")) or 0
end
-- Zone as of the last registration pass; CLEU reads this instead of
-- calling C_Map per event (thousands per second on drop night).
local cleuZone = 0

local function capitalZone()
    return (WBT.faction == "Horde") and ZONE_CAPITAL_H or ZONE_CAPITAL_A
end

-- Remaining-at-application duration for a buff the player just gained.
-- Runs from the combat log, possibly before that frame's UNIT_AURA has
-- marked the shared aura read stale, so it asks for a fresh read (rare).
local function buffDuration(nameMatch)
    RC.Auras:Invalidate()
    local a = RC.Auras:BuffNamed(nameMatch)
    if not a then return 0 end
    if a.expirationTime > 0 then return a.expirationTime - GetTime() end
    return a.duration
end

local function bars()
    return RC.WorldTools and RC.WorldTools.Bars
end

-- Second transport for yells: guild/raid/party only reach people you
-- share a guild or group with, the mesh reaches your other accounts.
local function meshYell(msgType, age, layer, arg)
    if WBT.Mesh and WBT.Mesh.SendYell then
        WBT.Mesh:SendYell(msgType, age or 0, layer, arg)
    end
end

-- DispatchAlert takes an {r,g,b} array; the theme hands out r/g/b fields.
local function alertTint(name)
    local c = RC.GetColor and RC:GetColor("text", name)
    if c and c.r then return { c.r, c.g, c.b } end
    return nil
end

-- category selects which WorldTools alert profile (sound/flash/channels)
-- the message uses. Only genuine incoming drops may use "pullTimer" - a
-- cooldown notice must never sound like a buff is landing.
local function relayAlert(category, buffKey, text, color, dedupTag)
    if not WBT:Settings().relayAlerts then return end
    local b = bars()
    if b then
        b:DispatchAlert(category, buffKey, text, color or { 0.4, 0.75, 1 }, dedupTag)
    else
        RC:Print(text)
    end
end

------------------------------------------------------------------------
-- Timer setting (ports of the legacy set*Buff functions, minus chat)
------------------------------------------------------------------------
-- Guards common to all three setters:
--   source ~= "self" plus <10s since the stored timer: a relayed copy of a
--     drop we already recorded locally.
--   20s between the ony and nef setters: both buffs arrive as the same
--     Rallying Cry aura, so two sets that close are one event seen twice.
--   zone gate: only the capital (plus the Barrens for rend) can produce a
--     drop, so anything from elsewhere is a buff we merely received.
--   60s since our last drop message before another SendBuffDropped, which
--     keeps a raid full of Readycheck users from spamming the guild.
WBT.lastSets = { rend = 0, ony = 0, nef = 0 }

-- Everything the three buffs do NOT share, so SetBuffTimer below can stay
-- one function instead of three copies that drift apart. Store fields are
-- derived from the key ("rend" -> rendTimer, rendTimerWho, rendSource,
-- rendYell, rendYell2), which is why the key doubles as the field prefix.
--   cross           a sibling whose recent set blocks this one: ony and nef
--                   arrive as the same Rallying Cry aura, so two sets less
--                   than 20s apart are one event seen twice
--   hordeZones /
--   allianceZones   where a genuine drop can be witnessed; rend alone lets
--                   an Alliance player count the Horde capital, because the
--                   cross-faction yell is audible from there
--   npcDied         buffs whose herald death is tracked clear that stamp
--   singleLayer     rend alone honours the manually pinned Alliance layer
--   log             rend alone writes a TimerLog entry (layer + unlayered)
--   layerNeedsGUID  rend only spawns a layer when CLEU handed us a GUID;
--                   ony/nef create one from the zone alone
--   allianceLayer   rend's 5th argument, an Alliance-side layer fixup that
--                   can reject the set outright
--   sapped          ony's 5th argument: suppresses the guild drop message
--                   and pushes a YELL-channel sync instead
local CAPITAL_AND_BARRENS_H = { [ZONE_CAPITAL_H] = true, [ZONE_BARRENS] = true }
local BUFF_SPECS = {
    rend = {
        hordeZones     = CAPITAL_AND_BARRENS_H,
        allianceZones  = { [ZONE_CAPITAL_A] = true, [ZONE_BARRENS] = true, [ZONE_CAPITAL_H] = true },
        singleLayer    = true,
        log            = "rendTimer",
        layerNeedsGUID = true,
        allianceLayer  = true,
    },
    ony = {
        cross         = "nef",
        hordeZones    = CAPITAL_AND_BARRENS_H,
        allianceZones = { [ZONE_CAPITAL_A] = true, [ZONE_BARRENS] = true },
        npcDied       = true,
        sapped        = true,
    },
    nef = {
        cross         = "ony",
        hordeZones    = CAPITAL_AND_BARRENS_H,
        allianceZones = { [ZONE_CAPITAL_A] = true, [ZONE_BARRENS] = true },
        npcDied       = true,
    },
}

-- The shared body. `extra` is the per-buff 5th argument described above;
-- which one it is comes from the spec, never from a branch in here.
function Detect:SetBuffTimer(kind, source, sender, zoneID, GUID, extra)
    local spec = BUFF_SPECS[kind]
    if not spec then return end
    local d = WBT:Data()
    if not d then return end

    -- All four gates are side-effect free returns, so they read in one
    -- block regardless of the order the old per-buff copies used.
    if spec.cross and (GetServerTime() - WBT.lastSets[spec.cross]) < 20 then return end
    if source ~= "self" and (GetServerTime() - d[kind .. "Timer"]) < 10 then return end
    local zone = currentZone()
    -- Written as two positive faction tests rather than one lookup so an
    -- unknown faction still falls through, exactly as the old copies did.
    if WBT.faction == "Horde" and not spec.hordeZones[zone] then return end
    if WBT.faction == "Alliance" and not spec.allianceZones[zone] then return end
    -- The stamp about to be written (line below uses GetServerTime() too);
    -- calling with two args left the ony/nef separation guard vacuous.
    if not WBT:ValidateNewTimer(kind, source, GetServerTime()) then return end

    local useSingleLayer
    if spec.singleLayer then
        useSingleLayer = WBT:GetSingleLayer()
        if WBT:IsLayered() and WBT.faction == "Alliance" and useSingleLayer then
            zoneID = useSingleLayer
        end
    end

    zoneID = WBT:MapLayerToParent(zoneID)
    if WBT:IsLayered() and not zoneID then return end
    if WBT:IsLayered() and tonumber(zoneID) and WBT:GetLayerCount() <= WBT.layerCap then
        if spec.allianceLayer and extra then
            if not d.layers[WBT.lastKnownLayerMapID] and not d.layers[zoneID] then
                return
            elseif WBT.lastKnownLayerMapID > 0 or zoneID > 0 then
                zoneID = useSingleLayer or WBT.lastKnownLayerMapID
            else
                return
            end
        elseif GUID or not spec.layerNeedsGUID then
            if not d.layers[zoneID] then
                WBT:CreateNewLayer(zoneID, GUID)
            end
        end
        local dl = d.layers[zoneID]
        if dl then
            dl[kind .. "Timer"]    = GetServerTime()
            dl[kind .. "TimerWho"] = sender
            dl[kind .. "Source"]   = source
            dl[kind .. "Yell"]     = d[kind .. "Yell"]
            dl[kind .. "Yell2"]    = d[kind .. "Yell2"]
            if spec.npcDied then dl[kind .. "NpcDied"] = 0 end
            if spec.log then WBT:TimerLog(spec.log, GetServerTime(), zoneID) end
        end
    end

    d[kind .. "Timer"]    = GetServerTime()
    d[kind .. "TimerWho"] = sender
    d[kind .. "Source"]   = source
    if spec.npcDied then d[kind .. "NpcDied"] = 0 end
    if WBT.Comms then WBT.Comms:SendData("GUILD") end
    if spec.log and not WBT:IsLayered() then
        WBT:TimerLog(spec.log, GetServerTime())
    end
    local isSapped = spec.sapped and extra
    if (GetServerTime() - WBT.lastSets[kind]) > 60 and not isSapped and WBT.Comms then
        local count = zoneID and WBT:GetLayerNum(zoneID) or 0
        if WBT:IsLayered() and count > 0 then
            WBT.Comms:SendBuffDropped("GUILD", kind, nil, count)
        else
            WBT.Comms:SendBuffDropped("GUILD", kind)
        end
    end
    WBT.lastSets[kind] = GetServerTime()
    if WBT.Mesh then WBT.Mesh:Nudge() end
    if isSapped and WBT.Comms then WBT.Comms:SendData("YELL") end
    WBT:Debug("set " .. kind .. " timer (" .. tostring(source) .. ")")
end

function Detect:SetRendBuff(source, sender, zoneID, GUID, isAllianceAndLayered)
    return Detect:SetBuffTimer("rend", source, sender, zoneID, GUID, isAllianceAndLayered)
end

function Detect:SetOnyBuff(source, sender, zoneID, GUID, isSapped)
    return Detect:SetBuffTimer("ony", source, sender, zoneID, GUID, isSapped)
end

function Detect:SetNefBuff(source, sender, zoneID, GUID)
    return Detect:SetBuffTimer("nef", source, sender, zoneID, GUID)
end

------------------------------------------------------------------------
-- NPC yells (records + network sends; WorldTools handles local alerts)
-- Each buff has two yells: the announcement ("...has fallen"), then the
-- application yell seconds later as the aura goes out. Only the first is
-- relayed as a pull timer; both timestamps are kept because the CLEU drop
-- check will not trust an aura without a yell close behind it.
------------------------------------------------------------------------
local rendHandIn, rendHandInTime = nil, 0

local function currentLayerNum()
    if WBT:IsLayered() and WBT.lastKnownLayerMapID > 0 and WBT.lastKnownLayer > 0 then
        return WBT.lastKnownLayer
    end
end

local function pushRendHandInLog()
    if tonumber(rendHandIn) and rendHandInTime > (GetServerTime() - 20) then
        WBT:TimerLog("q", GetServerTime(), rendHandIn, UnitName("player"))
        if WBT.Comms then
            WBT.Comms:SendTimerLogData("YELL")
            C_Timer.After(120, function()
                if WBT.Comms then WBT.Comms:SendTimerLogData("YELL") end
            end)
        end
        rendHandIn = nil
        rendHandInTime = 0
    end
end

-- Every NPC name and message fragment below is an exact match against the
-- game's yell text. One wrong character and detection silently stops - there
-- is no fallback path, which is exactly why the fragments are NOT written
-- out here: they live once in WT_Timers (WT.YellText, loaded above this file
-- in the .toc) and the local alert path reads the same table, so the two
-- detectors cannot drift apart. Only the fragments are shared - the branch
-- structure below is this module's own, because the network path gates on
-- faction and sends where the local path does not.
--
-- Heralds differ per faction for rend/ony/nef; Zandalar (Molthor,
-- Zandalarian Emissary) is one shared world event both factions hear, which
-- is why it has no faction branch.
local YT = (RC.WorldTools and RC.WorldTools.YellText) or {}

-- Same test the literals used to do (msg:find on a fragment with no Lua
-- pattern magic in it), just sourced from the shared table. A missing key
-- can only mean WorldTools failed to load, and never matching is the right
-- answer there.
local function saw(msg, key)
    local fragment = YT[key]
    return fragment ~= nil and msg:find(fragment) ~= nil
end

-- The same herald npcIDs the CLEU drop check keys on (Thrall 4949, Onyxia
-- heralds 14392 H / 14394 A, Nefarian heralds 14720 H / 14721 A, and the
-- era heralds 173758 H / 173754 A that announce either buff), so a yell is
-- also recognised by GUID when the client's NPC name is not the English
-- one. The Crossroads herald, Stonebridge and the Zandalar NPCs have no
-- id on file and stay name-only.
local YELL_NPC_IDS = {
    thrall = { ["4949"] = true },
    onyH   = { ["14392"] = true, ["173758"] = true },
    onyA   = { ["14394"] = true, ["173754"] = true },
    nefH   = { ["14720"] = true, ["173758"] = true },
    nefA   = { ["14721"] = true, ["173754"] = true },
}

function Detect:OnMonsterYell(msg, name, guid)
    local d = WBT:Data()
    if not d then return end
    local layerNum = currentLayerNum()
    local npcID = type(guid) == "string" and select(6, strsplit("-", guid)) or nil
    -- Name match OR known npcID; either alone is enough.
    local function isNpc(wantName, idSet)
        return name == wantName or (npcID ~= nil and idSet[npcID] == true)
    end
    local isThrall = isNpc("Thrall", YELL_NPC_IDS.thrall)
    if (isThrall or name == "Herald of Thrall") and saw(msg, "rendFallen") then
        d.rendYell = GetServerTime()
        local zone = currentZone()
        if name == "Herald of Thrall" then
            if not WBT:IsLayered() then
                C_Timer.After(5, function()
                    Detect:SetRendBuff("self", UnitName("player"))
                end)
            end
            if WBT.Comms then WBT.Comms:SendYell("GUILD", "rendCrossroads", nil, layerNum) end
            meshYell("rendCrossroads", 0, layerNum)
        else
            if WBT.Comms then WBT.Comms:SendYell("GUILD", "rend", nil, layerNum) end
            meshYell("rend", 0, layerNum)
        end
        if WBT:IsLayered() and (zone == ZONE_CAPITAL_H or zone == ZONE_BARRENS) and WBT.faction == "Alliance" then
            if WBT.lastKnownLayerMapID > 0 then
                C_Timer.After(5, function()
                    Detect:SetRendBuff("self", UnitName("player"), WBT.lastKnownLayerMapID, nil, true)
                end)
            end
        end
        pushRendHandInLog()
    elseif (isThrall or (name == "Herald of Thrall" and (not WBT:IsLayered() or WBT.faction == "Alliance")))
            and saw(msg, "rendPower") then
        d.rendYell2 = GetServerTime()
        pushRendHandInLog()
    elseif (WBT.faction == "Horde" and isNpc("Overlord Runthak", YELL_NPC_IDS.onyH) and saw(msg, "onyHSlain"))
            or (WBT.faction == "Alliance" and isNpc("Major Mattingly", YELL_NPC_IDS.onyA) and saw(msg, "onyAHistory")) then
        d.onyYell = GetServerTime()
        if WBT.Comms then WBT.Comms:SendYell("GUILD", "ony", nil, layerNum) end
        meshYell("ony", 0, layerNum)
    elseif (WBT.faction == "Horde" and isNpc("Overlord Runthak", YELL_NPC_IDS.onyH) and saw(msg, "onyHRally"))
            or (WBT.faction == "Alliance" and isNpc("Major Mattingly", YELL_NPC_IDS.onyA) and saw(msg, "onyAArches")) then
        d.onyYell2 = GetServerTime()
    elseif (WBT.faction == "Horde" and isNpc("High Overlord Saurfang", YELL_NPC_IDS.nefH) and saw(msg, "nefHSlain"))
            or (WBT.faction == "Alliance" and (isNpc("Field Marshal Afrasiabi", YELL_NPC_IDS.nefA) or name == "Field Marshal Stonebridge")
            and saw(msg, "nefASlain")) then
        d.nefYell = GetServerTime()
        if WBT.Comms then WBT.Comms:SendYell("GUILD", "nef", nil, layerNum) end
        meshYell("nef", 0, layerNum)
    elseif (WBT.faction == "Horde" and isNpc("High Overlord Saurfang", YELL_NPC_IDS.nefH) and saw(msg, "nefHRally"))
            or (WBT.faction == "Alliance" and (isNpc("Field Marshal Afrasiabi", YELL_NPC_IDS.nefA) or name == "Field Marshal Stonebridge")
            and saw(msg, "nefARally")) then
        d.nefYell2 = GetServerTime()
    elseif (name == "Molthor" or name == "Zandalarian Emissary")
            and (saw(msg, "zanRitual") or saw(msg, "zanBloodGod")) then
        if saw(msg, "zanAvoid") then return end
        d.zanYell = GetServerTime()
        local delay = (name == "Zandalarian Emissary") and "50" or nil
        if WBT.Comms then
            WBT.Comms:SendYell("GUILD", "zan", nil, layerNum, delay)
            if IsInRaid() then
                WBT.Comms:SendYell("RAID", "zan", nil, layerNum, delay)
            elseif IsInGroup() then
                WBT.Comms:SendYell("PARTY", "zan", nil, layerNum, delay)
            end
        end
        meshYell("zan", 0, layerNum, delay)
    elseif (name == "Molthor" or name == "Zandalarian Emissary") and saw(msg, "zanSlayer") then
        if saw(msg, "zanAvoid") then return end
        d.zanYell2 = GetServerTime()
    end
end

function Detect:OnMonsterSay(msg, name)
    local d = WBT:Data()
    if not d then return end
    if name == "Molthor" then
        -- Same guard the yell handler has: the NPC name is reused by the
        -- SoD Sunken Temple event (its lines carry the "Temple of Atal"
        -- fragment). Without it any such say fired a false Zandalar pull
        -- broadcast to guild, raid/party AND the mesh.
        if saw(msg, "zanAvoid") then return end
        d.zanYell = GetServerTime()
        local layerNum = currentLayerNum()
        if WBT.Comms then
            WBT.Comms:SendYell("GUILD", "zan", nil, layerNum, "50")
            if IsInRaid() then
                WBT.Comms:SendYell("RAID", "zan", nil, layerNum, "50")
            elseif IsInGroup() then
                WBT.Comms:SendYell("PARTY", "zan", nil, layerNum, "50")
            end
        end
        meshYell("zan", 0, layerNum, "50")
    end
end

------------------------------------------------------------------------
-- CLEU: buff drops, NPC deaths, songflower picks, DMF fortunes
------------------------------------------------------------------------
local DMF_SPELLS = {
    [23768]=true,[23769]=true,[23767]=true,[23766]=true,
    [23738]=true,[23737]=true,[23735]=true,[23736]=true,
}
-- A drop only counts if the aura we just gained still has nearly its full
-- duration (1h Warchief's Blessing, 2h Rallying Cry) AND a herald yell
-- landed within 80s. Without both, what CLEU shows is someone else's older
-- buff being reapplied or a logon aura. buffLag absorbs CLEU/aura latency.
local yellOneOffset, yellTwoOffset, buffLag = 80, 80, 15

local detectedPlayers = {}
local playerHasSongflower = {}
local lastPicked = 0

local function nearestFlowerKey()
    if currentZone() ~= ZONE_FELWOOD then return end
    local pos = C_Map.GetPlayerMapPosition(ZONE_FELWOOD, "player")
    if not pos then return end
    local px, py = pos:GetXY()
    if not px then return end
    px, py = px * 100, py * 100
    local bestKey, bestD = nil, 3.0
    for key, n in pairs(WBT.songFlowers) do
        local dx, dy = px - n.x, py - n.y
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist < bestD then
            bestD = dist
            bestKey = key
        end
    end
    return bestKey
end

function Detect:FlowerPicked(flowerKey, otherPlayer)
    local d = WBT:Data()
    if not d or not flowerKey then return end
    if currentZone() ~= ZONE_FELWOOD then return end
    if otherPlayer then
        -- Heuristics against logon-buff false positives.
        if playerHasSongflower[otherPlayer] then return end
        if not detectedPlayers[otherPlayer] then return end
        local seen = GetServerTime() - detectedPlayers[otherPlayer]
        if seen > 600 or seen < 1 then return end
    end
    if (GetServerTime() - lastPicked) <= 5 then return end
    local timestamp = GetServerTime()
    local layer = (WBT:IsLayered() and WBT:GetLayerCount() >= 2 and WBT.lastKnownLayerMapID > 0 and WBT.lastKnownLayer > 0)
        and WBT.lastKnownLayerMapID or nil
    if not layer or layer == 0 then
        layer = WBT.lastKnownLayerMapIDBackup
    end
    if (not layer or layer == 0) and WBT:IsLayered() then
        layer = WBT:GetSingleLayer()
    end
    if WBT:IsLayered() and layer and layer > 0 and d.layers[layer] then
        local dl = d.layers[layer]
        dl[flowerKey] = dl[flowerKey] or 0
        -- 1440 sits just inside the 1500s node cooldown: a second player
        -- reporting a pick in that window is the same pick, seen again.
        if otherPlayer and dl[flowerKey] > (timestamp - 1440) then return end
        if WBT:ValidateTimestamp(timestamp) then
            dl[flowerKey] = timestamp
            if WBT.Comms then
                WBT.Comms:SendFlower("GUILD", flowerKey, nil, WBT:GetLayerNum(layer))
                WBT.Comms:SendData("GUILD")
                WBT.Comms:SendData("YELL")
            end
        end
        if not (otherPlayer and d[flowerKey] > (timestamp - 1440)) and WBT:ValidateTimestamp(timestamp) then
            d[flowerKey] = timestamp
        end
        lastPicked = timestamp
    else
        if otherPlayer and d[flowerKey] > (timestamp - 1440) then return end
        if WBT:ValidateTimestamp(timestamp) then
            d[flowerKey] = timestamp
            if WBT.Comms then
                WBT.Comms:SendFlower("GUILD", flowerKey)
                WBT.Comms:SendData("GUILD")
                WBT.Comms:SendData("YELL")
            end
        end
        lastPicked = timestamp
    end
    if WBT.Mesh then WBT.Mesh:Nudge() end
    WBT:Debug("songflower picked " .. flowerKey .. (otherPlayer and (" by " .. otherPlayer) or ""))
end

local function onCombatLog()
    local cleuInfo = RC.WorldTools and RC.WorldTools._CompatCLEUInfo or CombatLogGetCurrentEventInfo
    local _, subEvent, _, sourceGUID, sourceName, _, _, destGUID, destName, destFlags, _, spellID, spellName = cleuInfo()

    -- Every sub-event that is not a death or an aura gain only feeds the
    -- Felwood "player seen nearby" table, so the map lookup is skipped
    -- until a player source has been confirmed by a plain string test.
    if subEvent ~= "UNIT_DIED" and subEvent ~= "SPELL_AURA_APPLIED" and subEvent ~= "SPELL_AURA_REFRESH" then
        if cleuZone == ZONE_FELWOOD and sourceName and sourceGUID
                and sourceGUID:find("Player", 1, true) then
            if not detectedPlayers[sourceName] or (GetServerTime() - detectedPlayers[sourceName]) >= 180 then
                detectedPlayers[sourceName] = GetServerTime()
            end
        end
        return
    end

    local zone = cleuZone

    if subEvent == "UNIT_DIED" then
        local capital = capitalZone()
        if zone ~= capital then return end
        local _, _, _, _, zoneID = strsplit("-", destGUID)
        zoneID = tonumber(zoneID)
        local died
        if WBT.faction == "Horde" and destName == "Overlord Runthak" then
            died = "ony"
        elseif WBT.faction == "Horde" and destName == "High Overlord Saurfang" then
            died = "nef"
        elseif WBT.faction == "Alliance" and destName == "Major Mattingly" then
            died = "ony"
        elseif WBT.faction == "Alliance" and (destName == "Field Marshal Afrasiabi"
                or destName == "Field Marshal Stonebridge") then
            died = "nef"
        end
        if died then
            local d = WBT:Data()
            if not d then return end
            local layerNum = currentLayerNum()
            zoneID = WBT:MapLayerToParent(zoneID)
            if WBT:IsLayered() and not zoneID then return end
            if WBT:IsLayered() and zoneID and d.layers[zoneID] then
                d.layers[zoneID][died .. "NpcDied"] = GetServerTime()
            end
            d[died .. "NpcDied"] = GetServerTime()
            if WBT.Comms then
                WBT.Comms:SendNpcKilled("GUILD", died, nil, layerNum)
                C_Timer.After(1, function()
                    WBT.Comms:SendData("GUILD")
                    WBT.Comms:SendData("YELL")
                end)
            end
        end
        return
    end

    if zone == ZONE_FELWOOD then
        local trackName, trackGUID = sourceName, sourceGUID
        if not trackName then trackName, trackGUID = destName, destGUID end
        if trackName and trackGUID and trackGUID:match("Player") then
            if not detectedPlayers[trackName] or (GetServerTime() - detectedPlayers[trackName]) >= 180 then
                detectedPlayers[trackName] = GetServerTime()
            end
        end
        if spellName == "Songflower Serenade" then
            if destName == UnitName("player") then
                if buffDuration("Songflower Serenade") >= 3599 then
                    Detect:FlowerPicked(nearestFlowerKey())
                end
            else
                local hostile = bit.band(destFlags or 0, COMBATLOG_OBJECT_REACTION_HOSTILE) == COMBATLOG_OBJECT_REACTION_HOSTILE
                if not hostile then
                    Detect:FlowerPicked(nearestFlowerKey(), destName)
                end
                playerHasSongflower[destName] = GetServerTime()
            end
        end
        return
    end

    if destName ~= UnitName("player") then return end
    local d = WBT:Data()
    if not d then return end
    local unitType, _, _, _, zoneID, npcID = strsplit("-", sourceGUID or "")
    zoneID = tonumber(zoneID)

    if spellID == 16609 or spellName == "Warchief's Blessing" then
        local duration = buffDuration("Warchief's Blessing")
        if duration >= (3599.5 - buffLag) and unitType == "Creature"
                and ((GetServerTime() - d.rendYell2) < yellTwoOffset or (GetServerTime() - d.rendYell) < yellOneOffset) then
            if zone == ZONE_CAPITAL_H or (zone == ZONE_BARRENS and WBT.faction == "Alliance") or not WBT:IsLayered() then
                if zone == ZONE_BARRENS and WBT.faction ~= "Alliance" then return end
                if WBT:IsLayered() and zone ~= ZONE_CAPITAL_H then
                    if WBT.faction == "Alliance" and WBT.lastKnownLayerMapID > 0 then
                        Detect:SetRendBuff("self", UnitName("player"), WBT.lastKnownLayerMapID, sourceGUID, true)
                    end
                    return
                end
                if WBT:IsLayered() and WBT.faction ~= "Alliance"
                        and (not npcID or npcID ~= "4949" or zone ~= ZONE_CAPITAL_H) then
                    -- Only Thrall (4949) in Orgrimmar sets the horde layer timer.
                    return
                end
                if WBT:IsLayered() and WBT.faction == "Alliance" then
                    Detect:SetRendBuff("self", UnitName("player"), zoneID, sourceGUID, true)
                else
                    Detect:SetRendBuff("self", UnitName("player"), zoneID, sourceGUID)
                end
            end
        end
    -- Ony and nef share one aura, so the source creature is what tells them
    -- apart: 14392/14394 are the Onyxia heralds, 14720/14721 the Nefarian
    -- ones. 173754/173758 appear in both lists - that era herald announces
    -- either buff, so only the yell timestamps below separate those.
    elseif spellID == 22888 or spellName == "Rallying Cry of the Dragonslayer" then
        local isNefSource = (WBT.faction == "Horde" and (npcID == "14720" or npcID == "173758"))
            or (WBT.faction == "Alliance" and (npcID == "14721" or npcID == "173754"))
        local isOnySource = (WBT.faction == "Horde" and (npcID == "14392" or npcID == "173758"))
            or (WBT.faction == "Alliance" and (npcID == "14394" or npcID == "173754"))
        if isNefSource and unitType == "Creature"
                and ((GetServerTime() - d.nefYell2) < yellTwoOffset or (GetServerTime() - d.nefYell) < yellOneOffset) then
            if buffDuration("Rallying Cry of the Dragonslayer") >= (7199.5 - buffLag) then
                -- A group invite can move us to the leader's layer with no
                -- event, so for 180s afterwards the drop cannot be pinned to
                -- a layer and is not recorded at all.
                if zone == ZONE_CAPITAL_A or zone == ZONE_CAPITAL_H or not WBT:IsLayered() then
                    if (GetServerTime() - WBT.lastJoinedGroup) > 180 then
                        Detect:SetNefBuff("self", UnitName("player"), zoneID, sourceGUID)
                    end
                end
            end
        elseif isOnySource and unitType == "Creature"
                and ((GetServerTime() - d.onyYell2) < yellTwoOffset or (GetServerTime() - d.onyYell) < yellOneOffset)
                and (GetServerTime() - d.nefYell2) > 30 then
            if buffDuration("Rallying Cry of the Dragonslayer") >= (7199.5 - buffLag) then
                if zone == ZONE_CAPITAL_A or zone == ZONE_CAPITAL_H or not WBT:IsLayered() then
                    if (GetServerTime() - WBT.lastJoinedGroup) > 180 then
                        Detect:SetOnyBuff("self", UnitName("player"), zoneID, sourceGUID)
                    end
                end
            end
        end
    elseif DMF_SPELLS[spellID] then
        if buffDuration(spellName) >= 7199 then
            WBT:SetDmfCooldown(14400)
        end
    end
end

------------------------------------------------------------------------
-- Layer identity from capital city creature GUIDs
-- Field 5 of a Creature GUID is the instance/layer ID the unit was spawned
-- in. It is the only layer signal the client gets, and it is only reliable
-- for a stationary city NPC: pets and summons follow their owner across
-- layers, and the player's own layer can change on a group join or a zone
-- change without any event firing.
------------------------------------------------------------------------
local function onLayerUnit(unit)
    if not WBT:IsLayered() then return end
    local zone = currentZone()
    if zone ~= capitalZone() then return end
    local GUID = UnitGUID(unit)
    if not GUID then return end
    local unitType, _, _, _, zoneID, npcID = strsplit("-", GUID)
    zoneID = tonumber(zoneID)
    npcID = tonumber(npcID)
    if not zoneID or unitType ~= "Creature" or not npcID then return end
    if WBT.companionNpcs and WBT.companionNpcs[npcID] then return end
    local d = WBT:Data()
    if not d then return end

    local known = d.layers[zoneID] and zoneID or WBT:MapLayerToParent(zoneID)
    if known and d.layers[known] then
        local count = WBT:GetLayerNum(known)
        if count > 0 then
            if WBT.currentLayerShared ~= count and WBT.Comms then
                WBT.Comms:SendL(count)
                WBT.currentLayerShared = count
            end
            WBT.lastKnownLayer = count
            WBT.lastKnownLayerID = known
            if (GetServerTime() - WBT.lastJoinedGroup) > WBT.groupJoinCooldown then
                WBT.lastKnownLayerMapID = known
                WBT.lastKnownLayerMapIDBackup = known
            end
        end
    end

    -- Strict path: whitelisted NPC, long since group join and zone change.
    -- 600s and 30s respectively - both events can silently move us, and the
    -- unit on screen may still be one we saw on the layer we just left.
    -- Only this path is allowed to create a layer or claim a GUID for one.
    if WBT.cityNpcs and WBT.cityNpcs[npcID]
            and (GetServerTime() - WBT.lastJoinedGroup) > 600
            and (GetServerTime() - WBT.lastZoneChange) > 30 then
        WBT.currentZoneIDStrict = zoneID
        if d.layers[zoneID] then
            d.layers[zoneID].lastSeenNPC = GetServerTime()
            d.layers[zoneID].GUID = GUID
        elseif not WBT:MapLayerToParent(zoneID) then
            WBT:CreateNewLayer(zoneID, GUID, true)
        end
    end
end

-- The backup layer ID is what songflower picks fall back to, so it is not
-- cleared immediately: within the first 60s of logon the "group join" is
-- usually the addon noticing a group we were already in, not a real invite.
function Detect:JoinedGroupReset()
    WBT.lastKnownLayerMapID = 0
    WBT.currentZoneIDStrict = 0
    WBT.lastKnownLayerID = 0
    WBT.lastJoinedGroup = GetServerTime()
    local sinceLogon = GetServerTime() - WBT.loadTime
    if sinceLogon > 5 then
        local buffer = 60 - sinceLogon
        if buffer > 0 then
            C_Timer.After(buffer, function() WBT.lastKnownLayerMapIDBackup = 0 end)
        else
            WBT.lastKnownLayerMapIDBackup = 0
        end
    end
end

------------------------------------------------------------------------
-- Relayed network events (things local detection can't see)
------------------------------------------------------------------------
-- One pull is announced by every guildie in earshot and again over the mesh.
-- 40s is longer than any pull timer, so a single incoming buff produces one
-- bar and one alert no matter how many copies arrive.
local relayedYellAt = { rend = 0, ony = 0, nef = 0, zan = 0 }

function Detect:OnRelayedYell(msgType, layer, distribution, arg, sender, yellEpoch)
    local base = msgType
    if base == "rendCrossroads" then base = "rend" end
    if not relayedYellAt[base] then return end
    if (GetServerTime() - relayedYellAt[base]) < 40 then return end
    relayedYellAt[base] = GetServerTime()
    local s = WBT:Settings()
    -- Only mesh relays carry an age; game channels have no age field.
    local epoch = tonumber(yellEpoch) or GetServerTime()
    local viaMesh = (distribution == "MESH")
    -- Forward game-channel relays to the mesh, never mesh back to mesh.
    -- Real age, not 0: the mesh receiver subtracts it so its bar starts
    -- part-way through instead of restarting the full pull timer on every
    -- relay hop.
    if not viaMesh then
        local relayAge = math.max(0, GetServerTime() - epoch)
        meshYell(msgType, relayAge, layer, arg)
    end
    local b = bars()
    local barCreated = false
    if s.relayBars and b then
        if base == "rend" then
            barCreated = b:OnRendYell(msgType == "rendCrossroads" and "herald" or "thrall", 1, epoch, "network")
        elseif base == "ony" then
            barCreated = b:OnOnyYell(WBT.faction == "Horde" and "H" or "A", 1, epoch, "network")
        elseif base == "nef" then
            barCreated = b:OnNefYell(WBT.faction == "Horde" and "H" or "A", 1, epoch, "network")
        elseif base == "zan" then
            barCreated = b:OnZanYell(arg == "50" and 1 or 2, epoch, "network")
        end
    end
    if barCreated or not (s.relayBars and b) then
        local layerMsg = tonumber(layer) and tonumber(layer) > 0 and (" (layer " .. layer .. ")") or ""
        local via = viaMesh and " (mesh relay)" or " (guild relay)"
        local names = {
            rend = "Rend buff incoming" .. via .. layerMsg,
            ony  = "Onyxia buff incoming" .. via .. layerMsg,
            nef  = "Nefarian buff incoming" .. via .. layerMsg,
            zan  = "Zandalar buff incoming" .. via .. layerMsg,
        }
        relayAlert("pullTimer", base == "rend" and "rend" or base, names[base])
    end
    WBT:Debug("relayed yell " .. tostring(msgType) .. " from " .. tostring(sender))
end

-- 60s window, matching the sender-side throttle on SendBuffDropped. Nothing
-- is announced while standing in the capital: the drop happened in front of
-- us and WorldTools has already alerted for it.
local buffDropMsgAt = { rend = 0, ony = 0, nef = 0 }
function Detect:OnBuffDropMsg(msgType, layer, sender)
    if not buffDropMsgAt[msgType] then return end
    if (GetServerTime() - buffDropMsgAt[msgType]) < 60 then return end
    buffDropMsgAt[msgType] = GetServerTime()
    if currentZone() == capitalZone() then return end
    local layerMsg = tonumber(layer) and tonumber(layer) > 0 and (" (layer " .. layer .. ")") or ""
    local names = { rend = "Rend", ony = "Onyxia", nef = "Nefarian" }
    relayAlert("buffDropped", msgType,
        (names[msgType] or msgType) .. " buff dropped" .. layerMsg .. " - new timer started", alertTint("green"))
end

-- A killed herald stays dead for minutes and everyone in the city reports
-- it, so one notice per 10m per buff. Shared by both the live message and
-- the "killed N minutes ago" path below.
local npcKilledMsgAt = { ony = 0, nef = 0 }
function Detect:OnNpcKilledMsg(msgType, layer, sender)
    if not WBT:Settings().npcKilledAlerts then return end
    if not npcKilledMsgAt[msgType] then return end
    if (GetServerTime() - npcKilledMsgAt[msgType]) < 600 then return end
    npcKilledMsgAt[msgType] = GetServerTime()
    local layerMsg = tonumber(layer) and tonumber(layer) > 0 and (" (layer " .. layer .. ")") or ""
    local names = { ony = "Onyxia herald", nef = "Nefarian herald" }
    relayAlert("npcDied", msgType,
        (names[msgType] or msgType) .. " was killed" .. layerMsg .. " - buff delayed", alertTint("red"))
end

function Detect:OnReceivedNpcDied(key, timestamp, distribution, layer, sender)
    if not WBT:Settings().npcKilledAlerts then return end
    local msgType = (key == "onyNpcDied") and "ony" or "nef"
    local d = WBT:Data()
    if not d then return end
    local dataPrefix = (WBT:IsLayered() and layer and d.layers[layer]) or d
    if (GetServerTime() - (dataPrefix[msgType .. "Timer"] or 0)) < 600 then return end
    -- Only a death from the last 30 minutes still delays a buff; a future
    -- timestamp is a clock problem, not an event.
    local timeAgo = GetServerTime() - timestamp
    if timeAgo < -1 or timeAgo >= 1800 then return end
    if not npcKilledMsgAt[msgType] then return end
    if (GetServerTime() - npcKilledMsgAt[msgType]) < 600 then return end
    npcKilledMsgAt[msgType] = GetServerTime()
    local layerMsg = layer and (" (layer " .. WBT:GetLayerNum(layer) .. ")") or ""
    local names = { ony = "Onyxia herald", nef = "Nefarian herald" }
    relayAlert("npcDied", msgType,
        (names[msgType] or msgType) .. " killed " .. math.floor(timeAgo / 60) .. "m ago" .. layerMsg .. " - buff delayed", alertTint("red"))
end

local flowerMsgAt = 0
function Detect:OnFlowerMsg(msgType, layer, sender)
    if (GetServerTime() - flowerMsgAt) < 10 then return end
    flowerMsgAt = GetServerTime()
    local node = WBT.songFlowers[msgType]
    if not node then return end
    if WBT:Settings().relayAlerts and currentZone() == ZONE_FELWOOD then
        RC:Print("Songflower picked: node " .. node.idx .. " (guild relay)")
    end
end

-- Quest IDs are the era hand-ins for each buff; a buff with two IDs has one
-- per faction. Window is 60s for zan (its pull is under a minute) and 120s
-- for the rest, since a whole raid hands in together.
local handInAt = {}
function Detect:OnHandIn(questID, layer, sender)
    if not WBT:Settings().handInMsgs then return end
    local names = {
        ["4974"] = { "rend", "Rend" }, ["7491"] = { "ony", "Onyxia" },
        ["7496"] = { "ony", "Onyxia" }, ["7782"] = { "nef", "Nefarian" },
        ["7784"] = { "nef", "Nefarian" }, ["8183"] = { "zan", "Zandalar" },
    }
    local info = names[tostring(questID)]
    if not info then return end
    local window = (info[1] == "zan") and 60 or 120
    -- GetServerTime like every sibling dedup table in this file; mixing
    -- the two clocks here was a drift bug waiting to happen.
    if handInAt[info[1]] and (GetServerTime() - handInAt[info[1]]) < window then return end
    handInAt[info[1]] = GetServerTime()
    local who = sender and strsplit("-", sender, 2) or "someone"
    RC:Print(info[2] .. " quest handed in by " .. who .. ".")
end

------------------------------------------------------------------------
-- Cooldown-ready warnings (10m / 1m / ready)
------------------------------------------------------------------------
local warned = {}

local function warningPass()
    local s = WBT:Settings()
    if not (s.warn10 or s.warn1 or s.warn0) then return end
    local d = WBT:Data()
    if not d then return end
    -- No Nefarian entry: the Head of Nefarian turn-in has no cooldown on
    -- Era/Anniversary, so a "Nefarian is ready" alert derived from
    -- nefCooldown would be announcing the end of a lockout that never
    -- started. Nef yells are still detected and relayed - see the drop
    -- handlers above - they just do not drive a countdown warning.
    local checks = {
        { key = "rend", field = "rendTimer", cd = WBT.rendCooldown, label = "Rend" },
        { key = "ony",  field = "onyTimer",  cd = WBT.onyCooldown,  label = "Onyxia" },
    }
    for _, c in ipairs(checks) do
        -- Rend layer attribution is unreliable with 2+ layers; skip warnings.
        local skip = (c.key == "rend" and WBT:GetLayerCount() >= 2)
        if not skip then
            local newest, layerNum
            if WBT:IsLayered() then
                for k, v in pairs(d.layers) do
                    local t = tonumber(v[c.field])
                    if t and t > 0 and (not newest or t > newest) then
                        newest = t
                        layerNum = WBT:GetLayerNum(k)
                    end
                end
            end
            if not newest then
                local t = tonumber(d[c.field])
                if t and t > 0 then newest = t end
            end
            if newest then
                local rem = (newest + c.cd) - GetServerTime()
                local layerMsg = layerNum and (" (layer " .. layerNum .. ")") or ""
                local function fire(threshold, text)
                    local id = c.key .. threshold .. newest
                    if not warned[id] then
                        warned[id] = true
                        -- warned[] already guarantees one fire per threshold;
                        -- tag the dedup key so the 1-minute and ready notices
                        -- cannot suppress each other inside the 60s window.
                        relayAlert("buffCooldown", c.key, text .. layerMsg, alertTint("yellow"), threshold)
                    end
                end
                if s.warn0 and rem <= 0 and rem > -30 then
                    fire("w0", c.label .. " buff cooldown is READY")
                elseif s.warn1 and rem > 0 and rem <= 60 then
                    fire("w1", c.label .. " buff cooldown ready in 1 minute")
                elseif s.warn10 and rem > 540 and rem <= 600 then
                    fire("w10", c.label .. " buff cooldown ready in 10 minutes")
                end
            end
        end
    end
    -- Stop the warned table growing forever.
    local n = 0
    for _ in pairs(warned) do n = n + 1 end
    if n > 200 then warned = {} end
end

------------------------------------------------------------------------
-- Event wiring (active mode only; CLEU + unit events are zone-gated)
------------------------------------------------------------------------
-- CLEU fires thousands of times a second in a raid, so it is only ever
-- registered in the four zones onCombatLog has a branch for: the two
-- capitals, the Barrens (rend) and Felwood (songflowers).
local CLEU_ZONES = {
    [ZONE_CAPITAL_H] = true, [ZONE_CAPITAL_A] = true,
    [ZONE_BARRENS] = true, [ZONE_FELWOOD] = true,
}

local eventFrame = CreateFrame("Frame")
local cleuActive, unitActive = false, false

local function updateZoneRegistrations()
    local zone = currentZone()
    cleuZone = zone
    local wantCleu = (CLEU_ZONES[zone] and not _G.READYCHECK_IS_FOREVER) or false   -- (no combat log on WoW Forever)
    if wantCleu ~= cleuActive then
        cleuActive = wantCleu
        if wantCleu then
            eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        else
            eventFrame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        end
    end
    local wantUnit = (zone == capitalZone())
    if wantUnit ~= unitActive then
        unitActive = wantUnit
        if wantUnit then
            eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
            eventFrame:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
        else
            eventFrame:UnregisterEvent("PLAYER_TARGET_CHANGED")
            eventFrame:UnregisterEvent("UPDATE_MOUSEOVER_UNIT")
        end
    end
    if zone ~= ZONE_FELWOOD and next(detectedPlayers) then
        detectedPlayers = {}
        playerHasSongflower = {}
    end
end

-- The visible "[WorldBuffs] Zandalar will drop in 50 seconds." guild
-- line, for senders whose client only produces the text and not the
-- addon message. Same path as the addon message; the 40s dedup in
-- OnRelayedYell absorbs getting both.
local CHAT_BUFFS = { rend = "rend", onyxia = "ony", nefarian = "nef", zandalar = "zan" }
local function onGuildText(msg, sender)
    if type(msg) ~= "string" or not msg:find("^%[WorldBuffs%]") then return end
    -- Plain text is trivially typed by hand, so only a guildie whose
    -- client has spoken on the timer network this session may start bars
    -- with it. networkUsers is keyed "Name-NormalizedRealm".
    if type(sender) ~= "string" or sender == "" then return end
    local key = sender
    if not key:find("-", 1, true) then
        key = key .. "-" .. (GetNormalizedRealmName() or "")
    end
    if not WBT.networkUsers[key] then return end
    local who, secs = msg:match("%[WorldBuffs%]%s*(%a+)%s+[%a%s]-drop[%a]*%s+in%s+(%d+)%s+second")
    if not who then return end
    local msgType = CHAT_BUFFS[who:lower()]
    if not msgType then return end
    Detect:OnRelayedYell(msgType, nil, "GUILD", secs, sender)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        onCombatLog()
    elseif event == "CHAT_MSG_GUILD" then
        local msg, sender = ...
        onGuildText(msg, sender)
    elseif event == "PLAYER_TARGET_CHANGED" then
        onLayerUnit("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        onLayerUnit("mouseover")
    elseif event == "CHAT_MSG_MONSTER_YELL" then
        -- Arg 12 is the speaking creature's GUID; its npcID backs up the
        -- English-name match in OnMonsterYell.
        local msg, name = ...
        local guid = select(12, ...)
        Detect:OnMonsterYell(msg, name, guid)
    elseif event == "CHAT_MSG_MONSTER_SAY" then
        local msg, name = ...
        Detect:OnMonsterSay(msg, name)
    elseif event == "QUEST_TURNED_IN" then
        local questID = ...
        if questID == 4974 or questID == 7491 or questID == 7784
                or questID == 7496 or questID == 7782 or questID == 8183 then
            if WBT.Comms then WBT.Comms:SendHandIn("YELL", questID) end
            if questID == 4974 then
                rendHandIn = (WBT.currentZoneIDStrict > 0 and WBT.currentZoneIDStrict)
                    or (WBT.lastKnownLayerMapID > 0 and WBT.lastKnownLayerMapID) or nil
                rendHandInTime = GetServerTime()
            end
        end
    elseif event == "GROUP_JOINED" then
        if GetNumGroupMembers() > 1 then
            Detect:JoinedGroupReset()
        end
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if GetServerTime() - WBT.loadTime > 5 then
            WBT.lastZoneChange = GetServerTime()
        end
        WBT.currentZoneIDStrict = 0
        updateZoneRegistrations()
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isLogon, isReload = ...
        if (not isLogon and not isReload) or IsInGroup() then
            WBT.lastZoneChange = GetServerTime()
        end
        WBT.currentZoneIDStrict = 0
        updateZoneRegistrations()
    elseif event == "PLAYER_LEAVING_WORLD" then
        WBT.lastZoneChange = GetServerTime()
        WBT.currentZoneIDStrict = 0
    elseif event == "UNIT_PHASE" then
        local unit = ...
        if UnitIsGroupLeader and UnitIsGroupLeader(unit) then
            WBT.currentZoneIDStrict = 0
        end
    end
end)

-- Detection is switched on and off by registering and unregistering the
-- event set, never by early-returning inside the handlers. The expensive
-- one is COMBAT_LOG_EVENT_UNFILTERED, which updateZoneRegistrations hooks
-- while the player is in a drop zone; leaving that attached while the
-- engine is "off" is precisely the cost the switch exists to remove.
--
-- Both are idempotent, so WBT:ApplyEnabledState can call them on every
-- settings change without tracking what it did last time.
function Detect:Start()
    if Detect._running then return end
    Detect._running = true
    if IsInGroup() then
        WBT.lastKnownLayerMapID = 0
        WBT.currentZoneIDStrict = 0
    end
    eventFrame:RegisterEvent("CHAT_MSG_MONSTER_YELL")
    eventFrame:RegisterEvent("CHAT_MSG_MONSTER_SAY")
    eventFrame:RegisterEvent("CHAT_MSG_GUILD")
    eventFrame:RegisterEvent("QUEST_TURNED_IN")
    eventFrame:RegisterEvent("GROUP_JOINED")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_LEAVING_WORLD")
    eventFrame:RegisterEvent("UNIT_PHASE")
    updateZoneRegistrations()
    -- 30s is fine resolution for 10m/1m/ready thresholds, and keeps the
    -- cooldown scan off any game event.
    Detect._warnTicker = WBT.StartTicker("WorldBuffTimers:Warnings", 30, warningPass)
    WBT:Debug("detect active")
end

function Detect:Stop()
    if not Detect._running then return end
    Detect._running = nil
    eventFrame:UnregisterAllEvents()
    -- updateZoneRegistrations only acts on a CHANGE in these two, so they
    -- have to be cleared here. Leave them true and a later Start() would
    -- believe the combat log is still hooked and never re-register it.
    cleuActive, unitActive = false, false
    if Detect._warnTicker then
        Detect._warnTicker:Cancel()
        Detect._warnTicker = nil
    end
    WBT:Debug("detect stopped")
end

local startFrame = CreateFrame("Frame")
startFrame:RegisterEvent("PLAYER_LOGIN")
startFrame:SetScript("OnEvent", function()
    C_Timer.After(4, function()
        if not WBT:IsActive() then
            WBT:Debug("detect disabled (mirror mode or engine off)")
            return
        end
        Detect:Start()
    end)
end)
