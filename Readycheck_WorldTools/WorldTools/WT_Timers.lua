------------------------------------------------------------------------
-- Readycheck - World Tools Timers
-- Local-only detection of world buff events: NPC yells and says, herald
-- deaths, and quest hand-ins. Everything detected here feeds the pull
-- timer bars in WT_Bars. Nothing in this file talks to the network.
--
-- TWO KINDS OF STATE, do not confuse them:
--   T.log      a plain ring buffer of human-readable debug lines. Runtime
--              only, never saved, never read by logic.
--   buff logs  the real record: one entry per confirmed buff POP, saved in
--              WT.Store().timerData. Used to suppress duplicate yells and
--              to refuse a hand-in pull timer while the buff is still on
--              its server cooldown.
--
-- CLEU IS REGISTERED, NOT FLAGGED. Herald deaths only happen in Orgrimmar
-- and Stormwind, so the combat log handler is registered on entering those
-- zones and unregistered on leaving. Outside them - every raid night, in
-- other words - there is no CLEU handler installed at all, which is the
-- only version of this that is free rather than merely cheap.
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end
local RC = _G.Readycheck
if not RC then return end
local WT = RC.WorldTools
if not WT then return end

WT.Timers = {}
local T = WT.Timers

local GetServerTime, GetTime = GetServerTime, GetTime
local floor, abs = math.floor, math.abs
local tinsert, tremove = table.insert, table.remove

-- Raw server cooldowns.
local CD_REND = 10800   -- 3h
local CD_ONY  = 21600   -- 6h

-- Hand-in suppression uses the raw cooldown plus a few seconds of slack,
-- because the pop we logged was timed off a yell we may have seen late.
-- The log's own duplicate gate deliberately does NOT get this slack.
local HANDIN_SLACK   = 5
local HANDIN_CD_REND = CD_REND + HANDIN_SLACK
local HANDIN_CD_ONY  = CD_ONY + HANDIN_SLACK

local LOG_KEEP    = 15      -- entries retained per buff log
local LOG_SAME    = 30      -- within this many seconds, it is the same event
local LOG_MAX_AGE = 172800  -- 48h

local DEBUG_KEEP = 200
T.log = {}

local function Note(text)
    tinsert(T.log, 1, { time = GetServerTime(), msg = text })
    if #T.log > DEBUG_KEEP then tremove(T.log) end
    RC:DebugPrint("WorldTools timer: " .. tostring(text), "worldbuffs")
end

-- ============================================================
-- BUFF LOGS
-- ============================================================
-- One implementation, three logs. The rend and per-faction Onyxia logs
-- differ only in where they are stored, what counts as a duplicate, and
-- whether a minimum gap between pops is enforced - so those three things
-- are parameters rather than three copies of the same insert-and-trim.

local function Bucket(key)
    local store = WT.Store()
    if not store or not store.timerData then return nil end
    local data = store.timerData
    if not data[key] then data[key] = {} end
    return data[key]
end

local function DropStale(entries)
    local oldest = GetServerTime() - LOG_MAX_AGE
    for i = #entries, 1, -1 do
        if (entries[i].epoch or 0) < oldest then tremove(entries, i) end
    end
end

-- Entries are kept newest-first so index 1 is always the latest pop.
local function InsertRanked(entries, record)
    local at = #entries + 1
    for i = 1, #entries do
        if record.epoch > (entries[i].epoch or 0) then at = i break end
    end
    tinsert(entries, at, record)
    for _ = #entries, LOG_KEEP + 1, -1 do tremove(entries) end
end

-- opts.sameKind(a, b) decides whether an existing entry describes the same
-- real-world event. opts.minGap, when set, rejects a pop that lands inside
-- another pop's cooldown - physically impossible, so it is bad data.
local function Record(key, epoch, who, extra, opts)
    local entries = Bucket(key)
    if not entries then return end
    epoch = tonumber(epoch) or 0
    if epoch <= 0 then return end
    opts = opts or {}

    for _, e in ipairs(entries) do
        local sameEvent = abs((e.epoch or 0) - epoch) < LOG_SAME
            and (not opts.sameKind or opts.sameKind(e, extra))
        local impossible = opts.minGap
            and abs((e.epoch or 0) - epoch) < opts.minGap
        if sameEvent or impossible then
            -- Keep the later timestamp and fill in a name we did not have.
            if sameEvent and epoch > (e.epoch or 0) then e.epoch = epoch end
            if who and who ~= "" and not e.who then e.who = who end
            return
        end
    end

    DropStale(entries)
    local record = { epoch = epoch }
    if who and who ~= "" then record.who = who end
    if extra and extra.killed then record.killed = true end
    InsertRanked(entries, record)
end

local function OnyKey(faction)
    return (faction == "H" or faction == "Horde") and "onyLogH" or "onyLogA"
end

-- A herald kill and a buff pop can land seconds apart and are different
-- events, so the kind has to match before they are treated as duplicates.
local function SameKillFlag(entry, extra)
    return (entry.killed or false) == ((extra and extra.killed) or false)
end

local function LogRend(epoch, who)
    Record("rendLog", epoch, who, nil, { minGap = CD_REND })
end

local function LogOny(epoch, who, faction, killed)
    Record(OnyKey(faction), epoch, who, { killed = killed },
        { sameKind = SameKillFlag })
end

function T:GetRendLog() return Bucket("rendLog") or {} end
function T:GetOnyLog(faction) return Bucket(OnyKey(faction)) or {} end
function T:AddRendLogPublic(epoch, who) LogRend(epoch, who) end
function T:AddOnyLogPublic(epoch, who, faction, killed)
    LogOny(epoch, who, faction, killed)
end

local function LatestRendPop()
    local entries = T:GetRendLog()
    return entries[1] and entries[1].epoch or 0
end

-- Kills reset the cooldown rather than starting one, so they are skipped.
local function LatestOnyPop(faction)
    for _, e in ipairs(T:GetOnyLog(faction)) do
        if not e.killed then return e.epoch or 0 end
    end
    return 0
end

-- ============================================================
-- FORMATTING
-- ============================================================
-- Drops the leading units once they are zero, so a countdown reads
-- "2h 04m 09s", then "4m 09s", then "9s".
local UNITS = { { 3600, "%dh %02dm %02ds" }, { 60, "%dm %02ds" }, { 0, "%ds" } }
local function FormatTime(seconds)
    seconds = tonumber(seconds) or 0
    if seconds <= 0 then return "expired" end
    local whole = floor(seconds)
    for _, unit in ipairs(UNITS) do
        local size = unit[1]
        if size == 0 then
            return unit[2]:format(whole % 60)
        elseif whole >= size then
            return unit[2]:format(floor(whole / size),
                floor(whole % size / (size == 3600 and 60 or 1)),
                whole % 60)
        end
    end
end
T.FormatTime = FormatTime

local function PlayingAlliance()
    return WT:GetPlayerFaction() ~= "Horde"
end

-- ============================================================
-- DETECTION TABLES
-- ============================================================
-- Every fragment in WT.YellText is an exact substring of the game's yell
-- text. One wrong character and detection silently stops - there is no
-- fallback path. WBT_Detect matches the very same lines for the timer
-- network, so the fragments live HERE once (this file loads before it in
-- the .toc) and both files consume this table. None of them contain Lua
-- pattern magic characters, so they are safe for plain and pattern find
-- alike.
WT.YellText = {
    rendFallen  = "Rend Blackhand, has fallen",
    rendPower   = "Be bathed in my power",
    onyHSlain   = "Onyxia, has been slain",
    onyHRally   = "Be lifted by the rallying cry",
    onyAHistory = "history has been made",
    onyAArches  = "hangs from the arches",
    nefHSlain   = "NEFARIAN IS SLAIN",
    nefHRally   = "Revel in his rallying cry",
    nefASlain   = "the Lord of Blackrock is slain",
    nefARally   = "Revel in the rallying cry",
    zanRitual   = "Begin the ritual",
    zanBloodGod = "The Blood God",
    zanSlayer   = "slayer of Hakkar",       -- WBT_Detect's zanYell2 line
    zanAvoid    = "Temple of Atal",         -- SoD reuses these NPCs for Sunken Temple
}
local YT = WT.YellText

-- Keyed by the NPC's name, so a yell costs one hash lookup and then walks
-- only that NPC's own lines - rather than scanning every pattern in the
-- game on every monster yell in earshot.
--
-- stage 1 is the announcement that starts a pull timer; stage 2 is the
-- follow-up flavour line, which confirms nothing new and never logs a pop.
-- `avoid` rejects a match: Season of Discovery reuses Molthor and the
-- Zandalarian Emissary for the Sunken Temple event.
local YELLS = {
    ["Thrall"] = {
        { find = YT.rendFallen, buff = "rend", stage = 1, via = "thrall" },
        { find = YT.rendPower,  buff = "rend", stage = 2, via = "thrall" },
    },
    ["Herald of Thrall"] = {
        { find = YT.rendFallen, buff = "rend", stage = 1, via = "herald" },
        { find = YT.rendPower,  buff = "rend", stage = 2, via = "herald" },
    },
    ["Overlord Runthak"] = {
        { find = YT.onyHSlain, buff = "onyH", stage = 1 },
        { find = YT.onyHRally, buff = "onyH", stage = 2 },
    },
    ["Major Mattingly"] = {
        { find = YT.onyAHistory, buff = "onyA", stage = 1 },
        { find = YT.onyAArches,  buff = "onyA", stage = 2 },
    },
    ["High Overlord Saurfang"] = {
        { find = YT.nefHSlain, buff = "nefH", stage = 1 },
        { find = YT.nefHRally, buff = "nefH", stage = 2 },
    },
    ["Field Marshal Afrasiabi"] = {
        { find = YT.nefASlain, buff = "nefA", stage = 1 },
        { find = YT.nefARally, buff = "nefA", stage = 2 },
    },
    ["Field Marshal Stonebridge"] = {
        { find = YT.nefASlain, buff = "nefA", stage = 1 },
        { find = YT.nefARally, buff = "nefA", stage = 2 },
    },
    ["Molthor"] = {
        { find = YT.zanRitual, buff = "zan", stage = 2, avoid = YT.zanAvoid },
    },
    ["Zandalarian Emissary"] = {
        { find = YT.zanBloodGod, buff = "zan", stage = 1, avoid = YT.zanAvoid },
    },
}

local SAYS = {
    ["Molthor"] = {
        { find = "Now, only one step", buff = "zan", stage = 1 },
    },
    ["Fallen Hero of the Horde"] = {
        { find = "My fury is released", buff = "battleshout", onlyIn = "Swamp of Sorrows" },
    },
}

-- Heralds whose death delays the buff. Keyed by creature id.
local HERALDS = {
    [14392] = { buff = "onyH", who = "Overlord Runthak" },
    [14394] = { buff = "onyA", who = "Major Mattingly" },
    [14720] = { buff = "nefH", who = "High Overlord Saurfang" },
    [14721] = { buff = "nefA", who = "Field Marshal Afrasiabi" },
}

-- Hand-ins that can start a pull timer. `cd` present means the buff has a
-- server cooldown worth checking before believing the hand-in.
local HANDINS = {
    [4974] = { buff = "rend", cd = HANDIN_CD_REND },
    [7491] = { buff = "onyA", cd = HANDIN_CD_ONY },
    [7496] = { buff = "onyH", cd = HANDIN_CD_ONY },
    [7782] = { buff = "nefA" },
    [7784] = { buff = "nefH" },
    [8183] = { buff = "zan" },
}

local HERALD_ZONES = {
    ["Orgrimmar"] = true,
    ["Stormwind City"] = true,
    ["Stormwind"] = true,
}

-- ============================================================
-- SHARED HELPERS
-- ============================================================
-- Alert categories collapse the per-faction buff keys; the bars keep them
-- apart, the alert profiles do not.
local function AlertKey(buff)
    if buff == "onyH" or buff == "onyA" then return "ony" end
    if buff == "nefH" or buff == "nefA" then return "nef" end
    return buff
end

local function FactionOf(buff)
    return (buff == "onyH" or buff == "nefH") and "H" or "A"
end

local ANNOUNCE = {
    rend   = "Rend is dropping - Orgrimmar shortly, Barrens a few seconds later",
    onyH   = "Onyxia's head is up - buff lands in a moment",
    onyA   = "Onyxia's head is up - buff lands in a moment",
    nefH   = "Nefarian's head is up - buff lands in a moment",
    nefA   = "Nefarian's head is up - buff lands in a moment",
    herald = "Herald is calling it - Barrens buff imminent",
    zan    = "Spirit of Zandalar is being raised",
    shout  = "Fallen Hero is shouting - Battle Shout buff incoming",
}

-- A hand-in a moment before the yell tells us WHO popped it; the yell
-- itself carries no name. Held briefly and consumed by the next rend yell.
local rendCredit = {}
local function TakeRendCredit(now)
    if rendCredit.at and (now - rendCredit.at) <= 20 then
        local who = rendCredit.who
        rendCredit.at, rendCredit.who = nil, nil
        return who
    end
end

-- Cross-faction yells arrive as scrambled text, so an Alliance player can
-- identify the NPC but never the line. Treated as a soft "something
-- happened" notice instead of a countdown that could be minutes wrong.
local lastVagueRend = 0
local function VagueRendNotice(epoch)
    LogRend(epoch, TakeRendCredit(epoch))
    if (GetTime() - lastVagueRend) < 60 then return end
    lastVagueRend = GetTime()
    if WT.Bars then
        WT.Bars:DispatchAlert("pullTimer", "rend",
            "A rend pop was announced, but the text is unreadable from this faction",
            { 0.6, 0.6, 0.4 })
    end
end

-- Starts whichever bar the buff calls for. Returns whether a bar appeared,
-- because the announcement should only follow a bar that actually showed.
local function RaiseBar(buff, stage, epoch, via)
    if not WT.Bars then return false end
    if buff == "rend" then
        return WT.Bars:OnRendYell(via or "thrall", stage, epoch, "local")
    elseif buff == "onyH" or buff == "onyA" then
        return WT.Bars:OnOnyYell(FactionOf(buff), stage, epoch, "local")
    elseif buff == "nefH" or buff == "nefA" then
        return WT.Bars:OnNefYell(FactionOf(buff), stage, epoch, "local")
    elseif buff == "zan" then
        return WT.Bars:OnZanYell(stage, epoch, "local")
    end
    return false
end

-- Only a stage-1 announcement is a new pop worth recording.
local function RecordPop(buff, stage, epoch)
    if stage ~= 1 then return end
    if buff == "rend" then
        LogRend(epoch, TakeRendCredit(epoch))
    elseif buff == "onyH" or buff == "onyA" then
        LogOny(epoch, nil, FactionOf(buff), false)
    end
end

local function FirstMatch(tbl, npc, msg)
    local lines = tbl[npc]
    if not lines then return nil end
    for _, line in ipairs(lines) do
        if msg:find(line.find, 1, true)
            and not (line.avoid and msg:find(line.avoid, 1, true)) then
            return line
        end
    end
    return nil
end

-- ============================================================
-- EVENT ENTRY POINTS
-- ============================================================
function T:OnMonsterYell(msg, npc)
    if not msg or not npc then return end

    if PlayingAlliance() and (npc == "Thrall" or npc == "Herald of Thrall") then
        VagueRendNotice(GetServerTime())
        return
    end

    local line = FirstMatch(YELLS, npc, msg)
    if not line then return end

    local epoch = GetServerTime()
    Note(string.format("yell from %s -> %s stage %d", npc, line.buff, line.stage))
    RecordPop(line.buff, line.stage, epoch)

    if RaiseBar(line.buff, line.stage, epoch, line.via) then
        local text = (line.via == "herald") and ANNOUNCE.herald or ANNOUNCE[line.buff]
        if text then
            WT.Bars:DispatchAlert("pullTimer", AlertKey(line.buff), text, { 1, 1, 0 })
        end
    end
end

function T:OnMonsterSay(msg, npc)
    if not msg or not npc then return end
    local line = FirstMatch(SAYS, npc, msg)
    if not line then return end
    if line.onlyIn and (GetRealZoneText() or "") ~= line.onlyIn then return end

    local epoch = GetServerTime()
    Note(string.format("say from %s -> %s", npc, line.buff))

    -- Battle Shout is an announcement only; there is no timed drop to bar.
    if line.buff == "battleshout" then
        if WT.Bars then
            WT.Bars:DispatchAlert("pullTimer", "battleshout",
                ANNOUNCE.shout, { 1, 0.8, 0 })
        end
        return
    end

    if RaiseBar(line.buff, line.stage, epoch) then
        WT.Bars:DispatchAlert("pullTimer", AlertKey(line.buff),
            ANNOUNCE[line.buff], { 1, 1, 0 })
    end
end

-- ============================================================
-- HERALD DEATHS (combat log, zone gated)
-- ============================================================
local cleuFrame = CreateFrame("Frame")
local cleuOn = false

cleuFrame:SetScript("OnEvent", function()
    local _, sub, _, _, _, _, _, destGUID = WT._CompatCLEUInfo()
    if sub ~= "UNIT_DIED" or not destGUID then return end
    local id = tonumber(destGUID:match("^Creature%-%d+%-%d+%-%d+%-%d+%-(%d+)"))
    local herald = id and HERALDS[id]
    if not herald then return end

    Note(string.format("herald down: %s (%d)", herald.who, id))
    if herald.buff == "onyH" or herald.buff == "onyA" then
        LogOny(GetServerTime(), nil, FactionOf(herald.buff), true)
    end
    if WT.Bars then WT.Bars:OnNpcDeath(herald.who, herald.buff) end
end)

function T:UpdateCLEUZoneGate()
    local want = HERALD_ZONES[GetRealZoneText() or ""] and not _G.READYCHECK_IS_FOREVER and true or false   -- (no combat log on WoW Forever)
    if want == cleuOn then return end
    cleuOn = want
    if want then
        cleuFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    else
        cleuFrame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    end
    Note("combat log " .. (want and "armed" or "released")
        .. " for " .. (GetRealZoneText() or "?"))
end

-- ============================================================
-- QUEST HAND-INS
-- ============================================================
-- True when the buff is still on cooldown, so the hand-in cannot really be
-- producing a drop. Buffs with no cooldown recorded (Zandalar, Nefarian)
-- are never suppressed.
function T:IsQuestHandinOnCooldown(info)
    if not info or not info.cd then return false end
    local last = 0
    if info.buff == "rend" then
        last = LatestRendPop()
    elseif info.buff == "onyH" or info.buff == "onyA" then
        last = LatestOnyPop(FactionOf(info.buff))
    end
    if last <= 0 then return false end
    local left = info.cd - (GetServerTime() - last)
    if left <= 0 then return false end
    Note(string.format("hand-in for %s ignored, %ds of cooldown left",
        info.buff, left))
    return true
end

function T:OnQuestTurnedIn(questID)
    local info = HANDINS[questID]
    if not info then return end
    if T:IsQuestHandinOnCooldown(info) then return end

    local epoch = GetServerTime()
    Note(string.format("hand-in seen: quest %d -> %s", questID, info.buff))

    -- Deliberately no log entry: the hand-in is a promise, the yell is the
    -- confirmation. All that is kept is who to credit when it arrives.
    if info.buff == "rend" then
        rendCredit.at, rendCredit.who = epoch, UnitName("player")
    end

    if not WT.Bars then return end
    WT.Bars:OnQuestHandin(info.buff, questID)
    -- Zandalar is the exception: the hand-in itself starts the long timer,
    -- because Molthor's line follows it rather than announcing it.
    if info.buff == "zan" then
        WT.Bars:OnZanYell(1, epoch, "local")
    end
end

function T:Init()
    T:UpdateCLEUZoneGate()
    Note("local detection ready")
end
