------------------------------------------------------------------------
-- Readycheck - Gold Ledger
-- One account-wide table of every known character's gold, fed by this
-- install's own characters and by your other accounts over the gold link.
--
-- WHAT "RIGHT" MEANS HERE. The total is every copper your characters
-- own: what each one carries, what is sitting in each one's mailbox, and
-- what one of them has mailed to another that has not been opened yet.
-- Every piece has exactly one owner - the install that plays the
-- character - and everyone else only ever copies the owner's word.
--
-- ORDERING. Each owner stamps its entries with its own clock (t) plus a
-- counter (r) that goes up on every change, and peers keep whichever
-- (t, r) is higher. Two stamps from the same owner can therefore never
-- be put in the wrong order, however late or out of order the messages
-- arrive. (The old ledger ordered by "receive time minus age", which a
-- message stuck in the send queue could get backwards - and then the
-- stale number stuck until that character's gold changed again.)
--
-- MAIL. Money in the post belongs to nobody's bags, so it used to drop
-- out of the total until it was collected. Now:
--   * the sender records each money mail to one of your characters
--     ("s" list) the moment the send succeeds;
--   * the recipient, whenever its mailbox is open, records which of those
--     mails it can see ("m" list) and how much money its mailbox holds
--     ("b" list, by expiry hour, so mail that expires drops out);
--   * a send is "in the post" until the recipient has seen a matching
--     mail (same sender and amount, seen after it was sent). Unmatched
--     sends older than 30 days are dropped: unopened mail goes back to
--     its sender then, and shows up in the sender's own mailbox.
-- The sender forgets a send once it has been matched; the recipient
-- keeps publishing the matching mail for two days after that, so no
-- third install can see the send without its match.
--
-- WIRE (WBGOLD, one message each, ";" between records, "~" between
-- fields). Every record names its character first:
--   Name-Realm~copper~age~class~t~r~flags~lastPlayed    an entry
--   Name-Realm~x~age~~t~r                               a forgotten character
--   Name-Realm~b|s|m~t~r~part~parts~items               one list, in parts
-- flags lists which of b / s / m are non-empty for that version, so an
-- emptied list clears without a record of its own. Readycheck builds
-- from before this change read field 2 as the copper and skip anything
-- that is not a number, so they ignore the new record kinds, and they
-- still get the age field they order by.
--
-- Not tracked: C.O.D. payments and auction house proceeds before the
-- mail carrying them has been seen.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
local CS = RC.CharacterStats
if not CS then return end

local time, pairs, ipairs, next, type, tonumber, tostring =
      time, pairs, ipairs, next, type, tonumber, tostring
local math_floor, math_max = math.floor, math.max
local table_concat, table_sort = table.concat, table.sort
local strsplit = strsplit

local L = {}
RC.GoldLedger = L

local CMD            = "WBGOLD"
local LEDGER_VERSION = 3
local CHANGE_GAP     = 2          -- coalesce bursts of changes into one send
local PEER_GAP       = 30         -- per-peer floor for full sends
local FULL_GAP       = 300        -- periodic full broadcast
local MAIL_LIFE      = 30 * 86400 -- unopened mail returns after 30 days
local MATCH_KEEP     = 2 * 86400  -- keep publishing a matching mail this long
local TOMB_KEEP      = 60 * 86400
local SKEW           = 600        -- clock difference allowed between machines
local PART_TTL       = 120        -- incomplete multi-part lists are dropped after this
local MAX_COPPER     = 2147483647
local MAX_ITEMS      = 400
local LIST_KINDS     = { "b", "s", "m" }

-- Keys -----------------------------------------------------------------

local function StripRealm(r)
    return (tostring(r or ""):gsub("[%s%-']", ""))
end

local function Realm()
    return StripRealm((GetNormalizedRealmName and GetNormalizedRealmName())
        or (GetRealmName and GetRealmName()) or "")
end

local function Key(name, realm)
    return (tostring(name or "?") .. "-" .. tostring(realm or "")):lower()
end

local function MyKey()
    return Key(UnitName("player"), Realm())
end

-- A mail's sender or recipient as a ledger key: "Name" is this realm.
local function NameKey(who)
    if type(who) ~= "string" then return nil end
    who = who:match("^%s*(.-)%s*$")
    if who == "" then return nil end
    local name, realm = strsplit("-", who, 2)
    if not name or name == "" then return nil end
    realm = (realm and realm ~= "") and StripRealm(realm) or Realm()
    return Key(name, realm)
end

local function MyAccount()
    local cfg = RC._mss and RC._mss.cfg
    local label = cfg and cfg.accountLabel
    if label and label ~= "" then return label end
    return "local"
end

local function Store()
    if not ReadycheckDB then return nil end
    ReadycheckDB.goldLedger = ReadycheckDB.goldLedger or {}
    return ReadycheckDB.goldLedger
end

local function Live(e)
    return type(e) == "table" and not e.dead
end

-- Versions -------------------------------------------------------------

local function Newer(t1, r1, t2, r2)
    t1, r1, t2, r2 = t1 or 0, r1 or 0, t2 or 0, r2 or 0
    if t1 ~= t2 then return t1 > t2 end
    return r1 > r2
end

-- Every change an owner makes gets a strictly higher (t, r) than the one
-- before, even within one second or if the clock steps backwards.
local function Bump(e)
    local now = time()
    if now > (e.t or 0) then
        e.t, e.r = now, 0
    else
        e.r = (e.r or 0) + 1
    end
    e.o = true
end

local function SetList(e, kind, items)
    e[kind] = items
    e[kind .. "T"], e[kind .. "R"] = e.t, e.r
end

-- Publishing -----------------------------------------------------------

local dirty = {}
local publishTimer
local Publish      -- defined below

local function MarkDirty(key)
    dirty[key] = true
    if publishTimer then return end
    publishTimer = C_Timer.NewTimer(CHANGE_GAP, function()
        publishTimer = nil
        Publish()
    end)
end

local barPending
local function RefreshBar()
    if barPending then return end
    barPending = true
    C_Timer.After(1.0, function()
        barPending = nil
        if RC.db and RC.db.statsBarGold == true and CS.ForceUpdateBarStats then
            CS:ForceUpdateBarStats()
        end
    end)
end

-- Mailbox and transit --------------------------------------------------

-- Money in a mailbox as of its last scan, minus mail that has expired
-- since (it went back to its sender, or was lost with an AH invoice).
local function MailOf(e, now)
    local sum = 0
    if type(e.b) == "table" then
        for _, it in ipairs(e.b) do
            if ((it.h or 0) + 1) * 3600 > now then sum = sum + (it.c or 0) end
        end
    end
    return sum
end

local function ByTime(a, b)
    if (a.st or 0) ~= (b.st or 0) then return (a.st or 0) < (b.st or 0) end
    return (a.n or 0) < (b.n or 0)
end

-- Pairs S's sends to R with the mails R has seen from S, oldest first:
-- each send takes the earliest unused mail of the same amount that R saw
-- no earlier than the send (less the clock allowance).
local function MatchPair(sends, seen, fromKey)
    local a, b = {}, {}
    for _, it in ipairs(sends) do a[#a + 1] = it end
    for _, it in ipairs(seen or {}) do
        if it.from == fromKey then b[#b + 1] = it end
    end
    table_sort(a, ByTime)
    table_sort(b, ByTime)
    local used, sendHit, seenHit = {}, {}, {}
    for _, s in ipairs(a) do
        for j, m in ipairs(b) do
            if not used[j] and m.c == s.c and (m.st or 0) >= (s.st or 0) - SKEW then
                used[j] = true
                sendHit[s], seenHit[m] = true, true
                break
            end
        end
    end
    return sendHit, seenHit
end

-- Every unmatched, unexpired send between two tracked characters.
local function Transit(store, now)
    local total, legs = 0, {}
    for sKey, S in pairs(store) do
        if Live(S) and type(S.s) == "table" and #S.s > 0 then
            local byTo = {}
            for _, it in ipairs(S.s) do
                if it.to and now - (it.st or 0) <= MAIL_LIFE then
                    byTo[it.to] = byTo[it.to] or {}
                    local list = byTo[it.to]
                    list[#list + 1] = it
                end
            end
            for rKey, list in pairs(byTo) do
                local R = store[rKey]
                if Live(R) then
                    local hit = MatchPair(list, R.m, sKey)
                    for _, it in ipairs(list) do
                        if not hit[it] then
                            total = total + (it.c or 0)
                            legs[#legs + 1] = { from = S.name, to = R.name, c = it.c, st = it.st }
                        end
                    end
                end
            end
        end
    end
    return total, legs
end

local function ListSig(list, kind)
    local parts = {}
    for _, it in ipairs(list or {}) do
        if kind == "b" then
            parts[#parts + 1] = tostring(it.c) .. ":" .. tostring(it.h)
        else
            parts[#parts + 1] = tostring(it.to or it.from) .. ":" .. tostring(it.c)
                .. ":" .. tostring(it.st) .. ":" .. tostring(it.n)
        end
    end
    return table_concat(parts, ",")
end

-- The owner's side of the mail bookkeeping, run after anything that can
-- change it: drop sends that have been matched or have expired, and
-- republish which seen mails matter.
local function Reconcile()
    local store = Store()
    if not store then return end
    local now = time()
    for _ = 1, 3 do
        local changed = false

        -- Recipients: what they publish is every mail that matches a
        -- known send, plus anything seen in the last two days (a send can
        -- arrive after its mail was seen).
        for rKey, R in pairs(store) do
            if Live(R) and R.own and type(R.seenAll) == "table" then
                local keep = {}
                for _, it in ipairs(R.seenAll) do
                    if now - (it.st or 0) <= MAIL_LIFE + SKEW then keep[#keep + 1] = it end
                end
                R.seenAll = keep
                local hitAll = {}
                for sKey, S in pairs(store) do
                    if Live(S) and type(S.s) == "table" and #S.s > 0 then
                        local list = {}
                        for _, it in ipairs(S.s) do
                            if it.to == rKey then list[#list + 1] = it end
                        end
                        if #list > 0 then
                            local _, seenHit = MatchPair(list, R.seenAll, sKey)
                            for m in pairs(seenHit) do hitAll[m] = true end
                        end
                    end
                end
                local pub = {}
                for _, it in ipairs(R.seenAll) do
                    if hitAll[it] or now - (it.st or 0) <= MATCH_KEEP then pub[#pub + 1] = it end
                end
                table_sort(pub, ByTime)
                if ListSig(pub, "m") ~= ListSig(R.m, "m") then
                    Bump(R)
                    SetList(R, "m", pub)
                    MarkDirty(rKey)
                    changed = true
                end
            end
        end

        -- Senders: forget sends that are matched, expired, or addressed
        -- to a character nobody tracks any more.
        for sKey, S in pairs(store) do
            if Live(S) and S.own and type(S.s) == "table" and #S.s > 0 then
                local byTo = {}
                for _, it in ipairs(S.s) do
                    byTo[it.to or "?"] = byTo[it.to or "?"] or {}
                    local list = byTo[it.to or "?"]
                    list[#list + 1] = it
                end
                local keep = {}
                for rKey, list in pairs(byTo) do
                    local R = store[rKey]
                    local hit = Live(R) and MatchPair(list, R.m, sKey) or {}
                    for _, it in ipairs(list) do
                        if Live(R) and not hit[it] and now - (it.st or 0) <= MAIL_LIFE then
                            keep[#keep + 1] = it
                        end
                    end
                end
                if #keep ~= #S.s then
                    table_sort(keep, ByTime)
                    Bump(S)
                    SetList(S, "s", keep)
                    MarkDirty(sKey)
                    changed = true
                end
            end
        end

        if not changed then break end
    end
end

-- Own entry ------------------------------------------------------------

local sessionStart = time()
local recordedThisSession = false
local leaving, zeroCheck = false, false

-- confirmed: a second reading of 0, taken a moment after the first.
function L:RecordSelf(confirmed)
    if leaving then return end
    local store = Store()
    if not store then return end
    local key = MyKey()
    local copper = GetMoney() or 0
    local e = store[key]
    -- GetMoney reads 0 for a moment after login and while a character is
    -- leaving the world (logging out, switching character). Recording that
    -- told every other account the character was broke. A real balance is
    -- only replaced by 0 once a reading two seconds later agrees - and
    -- never in the first 15 seconds of a session.
    if copper == 0 and Live(e) and (e.copper or 0) > 0 and not confirmed then
        if not zeroCheck then
            zeroCheck = true
            C_Timer.After(2, function()
                zeroCheck = false
                L:RecordSelf(time() - sessionStart >= 15)
            end)
        end
        return
    end
    if not Live(e) then
        e = {}
        store[key] = e
    end
    local _, class = UnitClass("player")
    e.name, e.realm = UnitName("player"), Realm()
    e.class, e.faction = class, UnitFactionGroup("player")
    e.account, e.own = MyAccount(), true
    e.lt = time()
    if e.copper ~= copper or not e.o or not recordedThisSession then
        e.copper = copper
        Bump(e)
        MarkDirty(key)
        RefreshBar()
    end
    recordedThisSession = true
end
RC.SaveToonGold = function() L:RecordSelf() end

-- Mail: sending --------------------------------------------------------

local pendingSend

-- SendMail is hooked, not replaced: whatever sends the mail (Blizzard's
-- window, ZacUI, Postal) goes through it. The send only counts once the
-- server confirms it (MAIL_SEND_SUCCESS).
local function OnSendMail(recipient)
    local amount = GetSendMailMoney and tonumber(GetSendMailMoney()) or 0
    local to = NameKey(recipient)
    if amount and amount > 0 and to then
        pendingSend = { to = to, c = math_floor(amount) }
    else
        pendingSend = nil
    end
end

local function CommitSend()
    local p = pendingSend
    pendingSend = nil
    if not p then return end
    local store = Store()
    local key = MyKey()
    if not store or p.to == key or not Live(store[p.to]) then return end
    L:RecordSelf()
    local e = store[key]
    if not Live(e) then return end
    e.seq = (e.seq or 0) + 1
    local list = {}
    for _, it in ipairs(e.s or {}) do list[#list + 1] = it end
    list[#list + 1] = { to = p.to, c = p.c, st = time(), n = e.seq }
    Bump(e)
    SetList(e, "s", list)
    MarkDirty(key)
    Reconcile()
    RefreshBar()
end

-- Mail: receiving ------------------------------------------------------

-- Run whenever the inbox data changes while the mailbox is open. A mail
-- is recorded as "seen" the first time it shows up; a second identical
-- mail (same sender, amount and subject) counts only when the inbox
-- holds more copies of it than were already counted.
function L:ScanInbox()
    if not (GetInboxNumItems and GetInboxHeaderInfo) then return end
    local store = Store()
    if not store then return end
    self:RecordSelf()
    local key = MyKey()
    local e = store[key]
    if not Live(e) then return end
    local now = time()
    local n = GetInboxNumItems() or 0
    local buckets, copies = {}, {}
    for i = 1, n do
        local _, _, sender, subject, money, _, daysLeft = GetInboxHeaderInfo(i)
        money = tonumber(money) or 0
        if money > 0 then
            local left = tonumber(daysLeft) or 30
            local h = math_floor((now + math_floor(left * 86400)) / 3600)
            buckets[h] = (buckets[h] or 0) + money
            local from = NameKey(sender)
            if from and from ~= key and Live(store[from]) then
                local fp = from .. "\1" .. money .. "\1" .. tostring(subject or "")
                local c = copies[fp]
                if not c then
                    c = { n = 0, from = from, c = money }
                    copies[fp] = c
                end
                c.n = c.n + 1
            end
        end
    end

    local changed = false
    e.counted = e.counted or {}
    e.seenAll = e.seenAll or {}
    for fp, c in pairs(copies) do
        local had = e.counted[fp] or 0
        for _ = had + 1, c.n do
            e.seq = (e.seq or 0) + 1
            e.seenAll[#e.seenAll + 1] = { from = c.from, c = c.c, st = now, n = e.seq }
            changed = true
        end
        e.counted[fp] = c.n
    end
    for fp in pairs(e.counted) do
        if not copies[fp] then e.counted[fp] = nil end
    end

    local b = {}
    for h, c in pairs(buckets) do b[#b + 1] = { h = h, c = c } end
    table_sort(b, function(x, y) return x.h < y.h end)
    if ListSig(b, "b") ~= ListSig(e.b, "b") then
        Bump(e)
        SetList(e, "b", b)
        MarkDirty(key)
        changed = true
    end
    if changed then
        Reconcile()
        RefreshBar()
    end
end

-- Forgetting -----------------------------------------------------------

-- A character that no longer exists (deleted, transferred, renamed).
-- The forget is a stamped record like any other, so it reaches every
-- peer and beats the stale entry; if the character is ever played
-- again, its owner's next entry is newer and brings it back.
function L:Forget(key)
    local store = Store()
    if not store or key == MyKey() then return end
    local e = store[key]
    if not Live(e) then return end
    local tomb = { dead = true, name = e.name, realm = e.realm, t = e.t, r = e.r, own = true }
    Bump(tomb)
    store[key] = tomb
    MarkDirty(key)
    Reconcile()
    RefreshBar()
end

-- Encoding -------------------------------------------------------------

local function ItemText(kind, it)
    if kind == "b" then
        return tostring(it.c) .. ":" .. tostring(it.h)
    end
    return tostring(it.to or it.from) .. ":" .. tostring(it.c) .. ":" .. tostring(it.st) .. ":" .. tostring(it.n)
end

local function FlagsOf(e)
    local f = ""
    for _, kind in ipairs(LIST_KINDS) do
        if type(e[kind]) == "table" and #e[kind] > 0 then f = f .. kind end
    end
    return f
end

-- Every record for one owned character. Lists are cut into parts that
-- fit the smaller (cross-faction) budget on their own, so every record
-- fits in one message on either leg.
local function RecordsFor(e, now, partMax)
    local who = tostring(e.name) .. "-" .. tostring(e.realm)
    local out = {}
    local age = tostring(math_max(0, now - (e.t or now)))
    if e.dead then
        out[1] = who .. "~x~" .. age .. "~~" .. tostring(e.t) .. "~" .. tostring(e.r or 0)
        return out
    end
    out[1] = who .. "~" .. tostring(e.copper or 0) .. "~" .. age .. "~" .. tostring(e.class or "")
        .. "~" .. tostring(e.t) .. "~" .. tostring(e.r or 0) .. "~" .. FlagsOf(e)
        .. "~" .. tostring(e.lt or e.t or 0)
    for _, kind in ipairs(LIST_KINDS) do
        local list = e[kind]
        if type(list) == "table" and #list > 0 then
            local head = who .. "~" .. kind .. "~" .. tostring(e[kind .. "T"] or e.t) .. "~"
                .. tostring(e[kind .. "R"] or e.r or 0) .. "~"
            -- part and parts are at most 3 digits each, plus two "~".
            local room = partMax - #head - 8
            local parts, cur, len = {}, {}, 0
            for _, it in ipairs(list) do
                local s = ItemText(kind, it)
                if len + #s + 1 > room and #cur > 0 then
                    parts[#parts + 1] = table_concat(cur, ",")
                    cur, len = {}, 0
                end
                cur[#cur + 1] = s
                len = len + #s + 1
            end
            if #cur > 0 then parts[#parts + 1] = table_concat(cur, ",") end
            for i, p in ipairs(parts) do
                out[#out + 1] = head .. i .. "~" .. #parts .. "~" .. p
            end
        end
    end
    return out
end

local function Pack(records, budget)
    local msgs, cur, len = {}, {}, 0
    for _, r in ipairs(records) do
        if len + #r + 1 > budget and #cur > 0 then
            msgs[#msgs + 1] = table_concat(cur, ";")
            cur, len = {}, 0
        end
        cur[#cur + 1] = r
        len = len + #r + 1
    end
    if #cur > 0 then msgs[#msgs + 1] = table_concat(cur, ";") end
    return msgs
end

-- Transport ------------------------------------------------------------
--
-- GOLD HAS ITS OWN LINK, independent of Mesh sync, and it only ever talks
-- to your own Battle.net account.
--   * Who counts: every WoW account on one Battle.net account shares one
--     BattleTag. Every message carries a hash of it and anything with a
--     different one is ignored. The mesh can include friends' characters
--     (they share its password), and their gold is not yours - so gold no
--     longer travels over the mesh at all, in either direction.
--   * Who is online: every character joins a hidden channel whose name and
--     password are made from that hash, so its member list is exactly your
--     characters online right now. The list (asked for every minute), its
--     join and leave notices, the mesh noticing a peer, and a periodic
--     knock on characters the ledger already knows all feed that.
--   * The data: whispered addon messages straight to each of those
--     characters - the route the mesh itself proves works between your
--     accounts. Nothing is sent over the channel itself.
-- A character that shows up gets a hello (H); an install answers a hello
-- with an acknowledgement (A), and each side then sends the other its
-- whole roster. Changes go to every character online as they happen, and
-- the whole roster again every 5 minutes as a safety net.

local PREFIX      = "RCGOLD"
local LINK_VER    = "G2"
local SEND_GAP    = 0.5      -- between our own link messages
local RETRY_GAP   = 2        -- after the client reports a throttle
local QUEUE_MAX   = 300
local HELLO_GAP   = 55       -- per character
local ONLINE_TTL  = 15 * 60  -- a peer not heard from this long is dropped
local PROBE_GAP   = 300
local PROBE_MAX   = 25
local GONE_GRACE  = 15       -- "no player named" within this of our whisper

local linkQueue, lowQueue, pumping = {}, {}, false
local online      = {}   -- lower "name-realm" -> { name, id, label, seen, verified }
local helloAt     = {}   -- lower "name-realm" -> time of our last hello
local rosterAt    = {}   -- lower "name-realm" -> time we last sent it our roster
local whisperedAt = {}   -- lower base name -> time of our last whisper to it
local lastFull, lastProbe = 0, 0
local stats = { sent = 0, refused = 0, throttled = 0, heard = 0, lastHeard = 0 }
L.linkStats = stats

local function Cfg() return RC._mss and RC._mss.cfg end

local function InstallId()
    if not ReadycheckDB then return "?" end
    if not ReadycheckDB.goldInstallId then
        ReadycheckDB.goldInstallId = string.format("%x%04x", time(), math.random(0, 65535))
    end
    return ReadycheckDB.goldInstallId
end

local function Hash(s, seed)
    local h = seed
    for i = 1, #s do h = (h * 33 + s:byte(i)) % 4294967296 end
    return h
end

local function Letters(s, seed, n)
    local h, out = Hash(s, seed), {}
    for i = 1, n do
        out[i] = string.char(97 + h % 26)
        h = math_floor(h / 26)
    end
    return table_concat(out)
end

-- The Battle.net identity: a hash for the header plus the hidden
-- channel's name and password. Remembered, so a Battle.net hiccup at
-- login does not stop the link.
local bnet
local function Bnet()
    if bnet then return bnet end
    local tag
    if BNGetInfo then
        local _, bt = BNGetInfo()
        if type(bt) == "string" and bt ~= "" then tag = bt:lower() end
    end
    if tag then
        bnet = {
            h = string.format("%08x", Hash(tag, 7)),
            c = "Rcg" .. Letters(tag, 11, 6) .. Letters(tag, 13, 6),
            p = Letters(tag, 17, 6) .. Letters(tag, 19, 6),
        }
        if ReadycheckDB then ReadycheckDB.goldBnet = bnet end
        return bnet
    end
    local saved = ReadycheckDB and ReadycheckDB.goldBnet
    if type(saved) == "table" and saved.h and saved.c and saved.p then return saved end
end

local function Label()
    local l = MyAccount()
    if l == "local" then l = UnitName("player") or "?" end
    return (tostring(l):gsub("[#|~;]", "")):sub(1, 20)
end

local function Header(kind)
    local b = Bnet()
    if not b then return nil end
    return LINK_VER .. "#" .. Label() .. "#" .. b.h .. "#" .. InstallId() .. "#" .. kind
end

local function LinkBudget()
    local head = Header("D")
    if head then return 255 - #head end
end

local function FullName(n)
    if type(n) ~= "string" then return nil end
    n = n:gsub("^[%*@%+]+", ""):match("^%s*(.-)%s*$")
    if n == "" then return nil end
    if not n:find("-", 1, true) then n = n .. "-" .. Realm() end
    return n
end

local function BaseLower(n)
    return (tostring(n or ""):match("^([^%-]+)") or ""):lower()
end

local function MyFull()
    return (FullName(UnitName("player")) or ""):lower()
end

-- Sending --------------------------------------------------------------

local THROTTLED = {}
do
    local E = Enum and Enum.SendAddonMessageResult
    THROTTLED[(E and E.AddonMessageThrottle) or 3] = true
    THROTTLED[(E and E.ChannelThrottle) or 8] = true
end

-- SendAddonMessage returns nothing on old builds, a boolean on some and a
-- result code on current ones; the last value is the one that counts.
local function Result(...)
    local n = select("#", ...)
    if n == 0 then return true end
    local r = select(n, ...)
    if r == nil or r == true or r == 0 then return true end
    if type(r) == "number" and THROTTLED[r] then return "throttle" end
    return false
end

local function Pump()
    if pumping then return end
    local q = (#linkQueue > 0) and linkQueue or lowQueue
    local job = q[1]
    if not job then return end
    pumping = true
    local gap = SEND_GAP
    local ok, res = pcall(job)
    if ok and res == "throttle" then
        stats.throttled = stats.throttled + 1
        gap = RETRY_GAP
    else
        table.remove(q, 1)
        if ok and res then stats.sent = stats.sent + 1 else stats.refused = stats.refused + 1 end
    end
    C_Timer.After(gap, function()
        pumping = false
        Pump()
    end)
end

-- low: hellos, which wait behind data.
local function Whisper(target, text, low)
    -- not delivered inside an instance on Forever; the next change or
    -- hello outside sends it again (Core_Flavor)
    if RC:AddonMessagesBlocked() then return end
    local q = low and lowQueue or linkQueue
    if #q >= QUEUE_MAX then return end
    q[#q + 1] = function()
        whisperedAt[BaseLower(target)] = time()
        return Result(C_ChatInfo.SendAddonMessage(PREFIX, text, "WHISPER", target))
    end
    Pump()
end

-- Verified characters online right now.
local function Peers()
    local out, now = {}, time()
    for k, p in pairs(online) do
        if p.verified and now - (p.seen or 0) <= ONLINE_TTL then
            out[#out + 1] = p.name
        elseif now - (p.seen or 0) > ONLINE_TTL then
            online[k] = nil
        end
    end
    table_sort(out)
    return out
end

local function Hello(name, kind)
    local full = FullName(name)
    if not full then return end
    local k = full:lower()
    if k == MyFull() then return end
    local now = time()
    if kind ~= "A" then
        if helloAt[k] and now - helloAt[k] < HELLO_GAP then return end
        helloAt[k] = now
    end
    local head = Header(kind or "H")
    if head then Whisper(full, head, kind ~= "A") end
end

local function Send(keys, target)
    local store = Store()
    if not store then return end
    local budget = LinkBudget()
    if not budget then return end
    local targets = target and { target } or Peers()
    if #targets == 0 then return end
    local now = time()
    local records = {}
    for _, key in ipairs(keys) do
        local e = store[key]
        if type(e) == "table" and e.own and e.t then
            for _, r in ipairs(RecordsFor(e, now, budget)) do records[#records + 1] = r end
        end
    end
    if #records == 0 then return end
    local head = Header("D")
    for _, m in ipairs(Pack(records, budget)) do
        for _, t in ipairs(targets) do Whisper(t, head .. m) end
    end
end

function L:OwnKeys()
    local store = Store()
    local out = {}
    if not store then return out end
    for key, e in pairs(store) do
        if type(e) == "table" and e.own then out[#out + 1] = key end
    end
    table_sort(out, function(a, b) return (store[a].t or 0) > (store[b].t or 0) end)
    return out
end

Publish = function()
    local keys = {}
    for key in pairs(dirty) do keys[#keys + 1] = key end
    dirty = {}
    if #keys > 0 then Send(keys) end
end

function L:SendAll(target)
    self:RecordSelf()
    Reconcile()
    Send(self:OwnKeys(), target)
    if not target then
        lastFull = time()
        dirty = {}
    end
end

-- Our whole roster to one character, at most once per PEER_GAP.
local function RosterTo(full)
    local k = full:lower()
    local now = time()
    if rosterAt[k] and now - rosterAt[k] < PEER_GAP then return end
    rosterAt[k] = now
    C_Timer.After(0.5 + math.random() * 1.5, function() L:SendAll(full) end)
end

-- The mesh noticed one of its peers come online: worth a hello. Whatever
-- the mesh itself carries about gold is ignored (see above).
function L:OnPeerOnline(peer)
    if peer then Hello(peer) end
end

function L:OnInbound() end

-- Presence -------------------------------------------------------------

local function Chan()
    local b = Bnet()
    if b then return b.c, b.p end
end

local function ChannelId()
    local name = Chan()
    if not name then return nil end
    local id = GetChannelName(name)
    if id and id > 0 then return id end
end

local function IsOurs(chanString, baseName)
    local name = Chan()
    if not name then return false end
    name = name:lower()
    if type(baseName) == "string" and baseName ~= "" then return baseName:lower() == name end
    if type(chanString) == "string" then
        return ((chanString:match("^%d+%.%s*(.+)$") or chanString):lower()) == name
    end
    return false
end

local function HideChannel(name)
    for i = 1, NUM_CHAT_WINDOWS or 10 do
        local cf = _G["ChatFrame" .. i]
        if cf and ChatFrame_RemoveChannel then ChatFrame_RemoveChannel(cf, name) end
    end
end

local function JoinedCount()
    local n = 0
    for i = 1, 10 do
        local _, name = GetChannelName(i)
        if name and name ~= "" then n = n + 1 end
    end
    return n
end

local function ListOnline()
    local name = Chan()
    if name and ChannelId() and ListChannelByName then pcall(ListChannelByName, name) end
end

local function EnsureChannel()
    local name, pw = Chan()
    if not name then return end
    if ChannelId() then
        stats.chanFull = nil
        return
    end
    if JoinedCount() >= 10 then
        stats.chanFull = true
        return
    end
    JoinChannelByName(name, pw)
    C_Timer.After(0.5, function() HideChannel(name) end)
    C_Timer.After(2, function()
        if ChannelId() then
            HideChannel(name)
            ListOnline()
        end
    end)
end

local function OnChannelList(list)
    if type(list) ~= "string" then return end
    for n in list:gmatch("[^,]+") do
        local full = FullName(n)
        local p = full and online[full:lower()]
        if full and not (p and p.verified) then Hello(full) end
    end
end

local function Gone(name)
    local b = BaseLower(name)
    for k in pairs(online) do
        if BaseLower(k) == b then online[k] = nil end
    end
end

-- Characters the ledger already knows are yours (it only holds what your
-- own accounts sent it), and the last character heard from each of your
-- other accounts. At login, the mesh roster too, to find them the first
-- time. Anyone not online just answers "no player named", which is hidden.
local function Probe(withMembers)
    lastProbe = time()
    local store = Store()
    if not store then return end
    local now, me, realm = time(), MyKey(), Realm()
    local seen, list = {}, {}
    local function Add(full, when)
        full = FullName(full)
        if not full then return end
        local k = full:lower()
        local p = online[k]
        if seen[k] or k == MyFull() or (p and p.verified) then return end
        seen[k] = true
        list[#list + 1] = { full = full, when = when or 0 }
    end
    for key, e in pairs(store) do
        if Live(e) and not e.own and not e.placeholder and key ~= me and e.name
                and e.realm == realm and now - (e.lt or e.t or 0) < 60 * 86400 then
            Add(e.name .. "-" .. e.realm, e.lt or e.t)
        end
    end
    local gp = ReadycheckDB and ReadycheckDB.goldPeers
    if type(gp) == "table" then
        for _, v in pairs(gp) do
            if type(v) == "table" and v.char then Add(v.char, (v.seen or 0) + 86400 * 90) end
        end
    end
    table_sort(list, function(a, b) return a.when > b.when end)
    local cfg = Cfg()
    if withMembers and cfg and type(cfg.members) == "table" then
        for _, m in ipairs(cfg.members) do
            if type(m) == "table" and type(m.name) == "string" then Add(m.name, 0) end
        end
    end
    for i = 1, math.min(#list, PROBE_MAX) do Hello(list[i].full) end
end

-- Inbound --------------------------------------------------------------

local Decode   -- defined with the decoder below

local function OnLinkMessage(text, sender)
    if type(text) ~= "string" or text == "" then return end
    local ver, label, bh, id, rest = strsplit("#", text, 5)
    if ver ~= LINK_VER or not rest or rest == "" then return end
    local b = Bnet()
    if not b or bh ~= b.h then return end      -- not your Battle.net account
    local full = FullName(sender)
    if not full then return end
    local k = full:lower()
    if k == MyFull() then return end
    if id == InstallId() then
        -- Another account with our id: a copied WTF folder. Take a new
        -- one; its next message gets through.
        ReadycheckDB.goldInstallId = nil
        InstallId()
        return
    end
    local now = time()
    stats.heard, stats.lastHeard = stats.heard + 1, now
    local p = online[k]
    local isNew = not (p and p.verified)
    if not p then
        p = {}
        online[k] = p
    end
    p.name, p.id, p.label, p.seen, p.verified = full, id, label, now, true
    if ReadycheckDB then
        local gp = ReadycheckDB.goldPeers
        if type(gp) ~= "table" then
            gp = {}
            ReadycheckDB.goldPeers = gp
        end
        gp[id] = { label = label, char = full, seen = now }
    end
    local kind, data = rest:sub(1, 1), rest:sub(2)
    if kind == "H" then Hello(full, "A") end
    if kind == "H" or kind == "A" or isNew then RosterTo(full) end
    if kind == "D" and data ~= "" then Decode(label, full, data) end
end

-- For the Gold card.
function L:LinkStatus()
    local peers = Peers()
    local accounts = {}
    for _, p in pairs(online) do
        if p.verified then accounts[p.id or "?"] = true end
    end
    local na = 0
    for _ in pairs(accounts) do na = na + 1 end
    return {
        bnet = Bnet() ~= nil,
        channel = ChannelId() ~= nil,
        chanFull = stats.chanFull,
        chars = #peers,
        accounts = na,
        online = accounts,
        sent = stats.sent,
        refused = stats.refused,
        throttled = stats.throttled,
        heard = stats.heard,
        lastHeard = stats.lastHeard,
        queued = #linkQueue + #lowQueue,
    }
end

-- Last chance before the character goes away: whatever is waiting on
-- the coalesce timer goes now.
local function Flush()
    if publishTimer then
        publishTimer:Cancel()
        publishTimer = nil
    end
    Publish()
end

-- Decoding -------------------------------------------------------------

local partsCache = {}   -- key|kind|t|r -> { n, got, parts = {}, at }

local function ParseItems(kind, text)
    local items = {}
    if not text or text == "" then return items end
    for s in text:gmatch("[^,]+") do
        if #items >= MAX_ITEMS then break end
        if kind == "b" then
            local c, h = strsplit(":", s)
            c, h = tonumber(c), tonumber(h)
            if c and h and c > 0 and c <= MAX_COPPER then
                items[#items + 1] = { c = math_floor(c), h = math_floor(h) }
            end
        else
            local who, c, st, n = strsplit(":", s)
            c, st, n = tonumber(c), tonumber(st), tonumber(n)
            if who and who ~= "" and c and st and n and c > 0 and c <= MAX_COPPER then
                local it = { c = math_floor(c), st = math_floor(st), n = math_floor(n) }
                if kind == "s" then it.to = who:lower() else it.from = who:lower() end
                items[#items + 1] = it
            end
        end
    end
    return items
end

-- A complete list for one owner's version. Lists carry their own
-- version, so they apply in any order relative to the entry record.
local function ApplyList(store, key, kind, t, r, items)
    local e = store[key]
    if not Live(e) then
        -- The entry record has not landed yet: keep the list on a
        -- placeholder so it applies the moment it does.
        e = e or { name = key, realm = "", t = 0, r = 0, placeholder = true }
        if e.dead then return false end
        store[key] = e
    end
    if e[kind .. "T"] and not Newer(t, r, e[kind .. "T"], e[kind .. "R"]) then return false end
    e[kind] = items
    e[kind .. "T"], e[kind .. "R"] = t, r
    return true
end

local function ApplyEntry(store, key, rec)
    local cur = store[key]
    if type(cur) == "table" and not cur.placeholder then
        if rec.o then
            if cur.o and not Newer(rec.t, rec.r, cur.t, cur.r) then return false end
        else
            -- A build from before stamps: only its relative age to go on.
            if cur.o or (cur.t or 0) >= rec.t then return false end
        end
    end
    local e = (type(cur) == "table" and not cur.dead) and cur or {}
    e.placeholder, e.dead = nil, nil
    e.name, e.realm, e.class = rec.name, rec.realm, rec.class
    e.copper, e.t, e.r, e.o = rec.copper, rec.t, rec.r, rec.o
    e.lt = rec.lt or rec.t
    e.account = rec.account
    -- The sender is the authority for this character now.
    e.own = nil
    if rec.o and rec.flags then
        for _, kind in ipairs(LIST_KINDS) do
            if not rec.flags:find(kind, 1, true)
                    and (not e[kind .. "T"] or Newer(rec.t, rec.r, e[kind .. "T"], e[kind .. "R"])) then
                e[kind] = {}
                e[kind .. "T"], e[kind .. "R"] = rec.t, rec.r
            end
        end
    end
    store[key] = e
    return true
end

local function ApplyTomb(store, key, name, realm, t, r)
    local cur = store[key]
    if type(cur) == "table" and not cur.placeholder and cur.o and not Newer(t, r, cur.t, cur.r) then
        return false
    end
    store[key] = { dead = true, name = name, realm = realm, t = t, r = r, o = true }
    return true
end

Decode = function(from, sender, data)
    local store = Store()
    if not store or type(data) ~= "string" or data == "" then return end
    local now = time()
    local me = MyKey()
    local changed = false

    for cacheKey, p in pairs(partsCache) do
        if now - p.at > PART_TTL then partsCache[cacheKey] = nil end
    end

    for rec in data:gmatch("[^;]+") do
        local f1, f2, f3, f4, f5, f6, f7, f8 = strsplit("~", rec)
        local name, realm = strsplit("-", f1 or "", 2)
        realm = StripRealm(realm)
        if name and name ~= "" and realm ~= "" then
            local key = Key(name, realm)
            if key ~= me then
                local t, r = tonumber(f5), tonumber(f6)
                if f2 == "x" then
                    if t and r then
                        changed = ApplyTomb(store, key, name, realm, math_floor(t), math_floor(r)) or changed
                    end
                elseif f2 == "b" or f2 == "s" or f2 == "m" then
                    -- Name-Realm~kind~t~r~part~parts~items
                    local lt, lr, k, n = tonumber(f3), tonumber(f4), tonumber(f5), tonumber(f6)
                    if lt and lr and k and n and k >= 1 and n >= 1 and k <= n and n <= 50 then
                        local ck = key .. "|" .. f2 .. "|" .. lt .. "|" .. lr
                        local p = partsCache[ck]
                        if not p then
                            p = { n = n, got = 0, parts = {}, at = now }
                            partsCache[ck] = p
                        end
                        if p.n == n and not p.parts[k] then
                            p.parts[k] = f7 or ""
                            p.got = p.got + 1
                        end
                        if p.got == p.n then
                            partsCache[ck] = nil
                            local items = {}
                            for i = 1, p.n do
                                for _, it in ipairs(ParseItems(f2, p.parts[i])) do
                                    if #items < MAX_ITEMS then items[#items + 1] = it end
                                end
                            end
                            changed = ApplyList(store, key, f2, math_floor(lt), math_floor(lr), items) or changed
                        end
                    end
                else
                    local copper, age = tonumber(f2), tonumber(f3)
                    if copper and copper >= 0 and copper <= MAX_COPPER and age and age >= 0 then
                        local e = {
                            name = name, realm = realm, copper = math_floor(copper),
                            class = (f4 and f4 ~= "") and f4 or nil,
                            account = from or "?",
                        }
                        if t and r then
                            e.t, e.r, e.o = math_floor(t), math_floor(r), true
                            e.flags = f7 or ""
                            e.lt = tonumber(f8)
                        else
                            e.t = now - math_floor(age)
                        end
                        changed = ApplyEntry(store, key, e) or changed
                    end
                end
            end
        end
    end

    if changed then
        Reconcile()
        RefreshBar()
    end
end

-- Rows -----------------------------------------------------------------

function L:Rows()
    local store = Store()
    local rows, total = {}, 0
    if not store then return rows, total, 0, {} end
    local me = MyKey()
    local now = time()
    for key, e in pairs(store) do
        if Live(e) and not e.placeholder then
            local copper = (key == me) and (GetMoney() or e.copper or 0) or (e.copper or 0)
            local mail = MailOf(e, now)
            if copper + mail > 0 then
                rows[#rows + 1] = {
                    key = key, name = e.name, realm = e.realm, class = e.class,
                    copper = copper, mail = mail,
                    t = (key == me) and now or (e.lt or e.t), me = (key == me),
                    account = e.account,
                }
                total = total + copper + mail
            end
        end
    end
    local transit, legs = Transit(store, now)
    total = total + transit
    table_sort(rows, function(a, b) return (a.copper + a.mail) > (b.copper + b.mail) end)
    return rows, total, transit, legs
end

function RC:GetGoldGrandTotal()
    local _, total = L:Rows()
    return math_floor(total / 10000)
end

-- Migration ------------------------------------------------------------

-- The first ledger ordered by relative age, re-imported the buff board's
-- cache (other players' gold, realm-less duplicates of your own) on
-- every login, and keyed some realms un-normalised. Once: normalise
-- keys, drop the buff-board imports, mark which entries this install
-- owns, and stop reading the old stores for good.
local function MigrateV2()
    local store = Store()
    local mine = MyAccount()
    local fresh = {}
    local function Take(e, own)
        local realm = StripRealm(e.realm)
        if not e.name or e.name == "" or realm == "" then return end
        local k = Key(e.name, realm)
        local copy = {
            name = e.name, realm = realm, class = e.class, faction = e.faction,
            copper = tonumber(e.copper) or 0, t = tonumber(e.t) or 0, r = 0,
            lt = tonumber(e.t) or 0, account = e.account,
        }
        if own then
            -- Stamped by this machine's clock, so already in owner order.
            copy.own, copy.o = true, true
        end
        local cur = fresh[k]
        if not cur or copy.t > (cur.t or 0) then fresh[k] = copy end
    end
    for _, e in pairs(store) do
        if type(e) == "table" and e.account ~= "mesh" then
            Take(e, e.account == mine or e.account == "local")
        end
    end
    local old = ReadycheckDB.goldByToon
    if type(old) == "table" then
        for _, d in pairs(old) do
            if type(d) == "table" and d.name then
                Take({ name = d.name, realm = d.realm, class = d.class, faction = d.faction,
                    copper = d.copper, t = d.t, account = mine }, true)
            end
        end
    end
    ReadycheckDB.goldLedger = fresh
    ReadycheckDB.goldByToon = nil
    ReadycheckDB.goldUI = nil
    ReadycheckDB.goldChipOn = nil
    ReadycheckDB.goldLedgerV = 2
end

-- Until now any mesh peer's gold was believed, and the mesh can include
-- friends' characters. Nothing this install did not record itself can be
-- told apart from theirs, so all of it goes; your other accounts send
-- theirs again over the link the next time each one is online.
local function MigrateV3()
    local store = Store()
    for key, e in pairs(store) do
        if type(e) ~= "table" or not e.own then store[key] = nil end
    end
    ReadycheckDB.goldPeers = nil
    ReadycheckDB.goldLedgerV = 3
end

local function Migrate()
    local store = Store()
    if not store or ReadycheckDB.goldLedgerV == LEDGER_VERSION then return end
    if (ReadycheckDB.goldLedgerV or 0) < 2 then MigrateV2() end
    if ReadycheckDB.goldLedgerV == 2 then MigrateV3() end
end

local function Prune()
    local store = Store()
    if not store then return end
    local now = time()
    for key, e in pairs(store) do
        if type(e) ~= "table" then
            store[key] = nil
        elseif e.dead and now - (e.t or 0) > TOMB_KEEP then
            store[key] = nil
        elseif e.placeholder and now - math_max(e.sT or 0, e.mT or 0, e.bT or 0) > MAIL_LIFE then
            store[key] = nil
        end
    end
end

-- Events ---------------------------------------------------------------

local function MailboxOpen()
    return (InboxFrame and InboxFrame:IsVisible())
        or (MailFrame and MailFrame:IsVisible())
end

if hooksecurefunc and SendMail then
    hooksecurefunc("SendMail", OnSendMail)
end

-- The hidden channel's notices and member list, and "no player named"
-- for a character we just knocked on, stay out of the chat window.
if ChatFrame_AddMessageEventFilter then
    local function ChanFilter(_, _, _, _, _, chanString, _, _, _, _, baseName)
        return IsOurs(chanString, baseName)
    end
    for _, ev in ipairs({ "CHAT_MSG_CHANNEL_JOIN", "CHAT_MSG_CHANNEL_LEAVE", "CHAT_MSG_CHANNEL_NOTICE",
            "CHAT_MSG_CHANNEL_NOTICE_USER", "CHAT_MSG_CHANNEL_LIST" }) do
        ChatFrame_AddMessageEventFilter(ev, ChanFilter)
    end
end

local notFound
do
    local pat = ERR_CHAT_PLAYER_NOT_FOUND_S or "No player named '%s' is currently playing."
    pat = pat:gsub("[%^%$%(%)%.%[%]%*%+%-%?]", "%%%0")
    notFound = "^" .. pat:gsub("%%s", "(.-)") .. "$"
end

local function OursNotFound(msg)
    local name = type(msg) == "string" and msg:match(notFound)
    if not name then return nil end
    local at = whisperedAt[BaseLower(name)]
    if at and time() - at <= GONE_GRACE then return name end
end

if ChatFrame_AddMessageEventFilter then
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", function(_, _, msg)
        return OursNotFound(msg) ~= nil
    end)
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_MONEY")
f:RegisterEvent("PLAYER_LOGOUT")
f:RegisterEvent("PLAYER_CAMPING")
f:RegisterEvent("PLAYER_QUITING")
f:RegisterEvent("MAIL_INBOX_UPDATE")
f:RegisterEvent("MAIL_SEND_SUCCESS")
f:RegisterEvent("MAIL_FAILED")
f:RegisterEvent("CHAT_MSG_ADDON")
f:RegisterEvent("CHAT_MSG_CHANNEL_JOIN")
f:RegisterEvent("CHAT_MSG_CHANNEL_LEAVE")
f:RegisterEvent("CHAT_MSG_CHANNEL_LIST")
f:RegisterEvent("CHAT_MSG_SYSTEM")
f:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        local prefix, text, dist, sender = ...
        if prefix == PREFIX and dist == "WHISPER" then OnLinkMessage(text, sender) end
        return
    elseif event == "CHAT_MSG_CHANNEL_LIST" then
        local list, _, _, chanString = ...
        if IsOurs(chanString, (select(9, ...))) then OnChannelList(list) end
        return
    elseif event == "CHAT_MSG_CHANNEL_JOIN" then
        local _, who, _, chanString = ...
        if IsOurs(chanString, (select(9, ...))) and who and who ~= "" then
            -- A moment for its addons to finish loading.
            C_Timer.After(2 + math.random() * 2, function() Hello(who) end)
        end
        return
    elseif event == "CHAT_MSG_CHANNEL_LEAVE" then
        local _, who, _, chanString = ...
        if IsOurs(chanString, (select(9, ...))) and who then Gone(who) end
        return
    elseif event == "CHAT_MSG_SYSTEM" then
        local name = OursNotFound((...))
        if name then Gone(name) end
        return
    end
    if event == "PLAYER_LOGIN" then
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        end
        Migrate()
        Prune()
        L:RecordSelf()
        Reconcile()
        -- Channels (and Battle.net) are not ready right at login.
        C_Timer.After(4, EnsureChannel)
        C_Timer.After(7, function()
            EnsureChannel()
            ListOnline()
            Probe(true)
        end)
        C_Timer.After(20, function()
            EnsureChannel()
            ListOnline()
        end)
        local function Periodic()
            EnsureChannel()
            ListOnline()
            local now = time()
            if now - lastFull >= FULL_GAP then L:SendAll() end
            if now - lastProbe >= PROBE_GAP then Probe(false) end
        end
        if RC.Profiler and RC.Profiler.TrackTicker then
            RC.Profiler:TrackTicker("GoldLedger", 60, Periodic)
        else
            C_Timer.NewTicker(60, Periodic)
        end
    elseif event == "PLAYER_MONEY" then
        L:RecordSelf()
    elseif event == "MAIL_INBOX_UPDATE" then
        -- Synchronously, on purpose: an auto-looting addon answering the
        -- same event takes the money a moment later, and the mail has to
        -- be counted before it goes.
        if MailboxOpen() then L:ScanInbox() end
    elseif event == "MAIL_SEND_SUCCESS" then
        CommitSend()
    elseif event == "MAIL_FAILED" then
        pendingSend = nil
    elseif event == "PLAYER_CAMPING" or event == "PLAYER_QUITING" then
        L:RecordSelf()
        Flush()
    elseif event == "PLAYER_LOGOUT" then
        -- Too late to trust GetMoney: the balance was recorded as it
        -- changed, and again when the logout started.
        leaving = true
    end
end)

-- UI -------------------------------------------------------------------

local function AgeText(r)
    local age = time() - (r.t or 0)
    if r.me or age < 60 then return RCL["now"] end
    if age < 3600 then return math_floor(age / 60) .. RCL["m ago"] end
    if age < 86400 then return math_floor(age / 3600) .. RCL["h ago"] end
    return math_floor(age / 86400) .. RCL["d ago"]
end

function CS:ShowGoldTooltip(anchorFrame)
    GameTooltip:SetOwner(anchorFrame, "ANCHOR_BOTTOM")
    local title = RC:GetColor("text", "gold") or { r = 1, g = 0.82, b = 0 }
    GameTooltip:SetText(RCL["Gold"], title.r, title.g, title.b)
    local rows, total, transit = L:Rows()
    if #rows == 0 and transit == 0 then
        GameTooltip:AddLine(GetCoinTextureString(GetMoney() or 0))
        GameTooltip:Show()
        return
    end
    local gray = RC:GetColor("text", "gray") or { r = 0.6, g = 0.6, b = 0.6 }
    for _, r in ipairs(rows) do
        local cc = r.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[r.class]
        local nr, ng, nb = 0.9, 0.9, 0.9
        if cc then nr, ng, nb = cc.r, cc.g, cc.b end
        GameTooltip:AddDoubleLine((r.name or "?") .. (r.me and " *" or ""),
            GetCoinTextureString(r.copper + r.mail), nr, ng, nb, 1, 1, 1)
        if r.mail > 0 then
            GameTooltip:AddDoubleLine("   " .. RCL["in the mailbox"], GetCoinTextureString(r.mail),
                gray.r, gray.g, gray.b, gray.r, gray.g, gray.b)
        end
    end
    if transit > 0 then
        GameTooltip:AddDoubleLine(RCL["In the post"], GetCoinTextureString(transit),
            gray.r, gray.g, gray.b, 1, 1, 1)
    end
    if #rows + (transit > 0 and 1 or 0) > 1 then
        GameTooltip:AddLine(" ", 1, 1, 1)
        GameTooltip:AddDoubleLine(RCL["Total"], GetCoinTextureString(total),
            title.r, title.g, title.b, title.r, title.g, title.b)
    end
    GameTooltip:Show()
end

function RC:BuildGoldCard(parent, yPos, pageFrame)
    local gray = RC:GetColor("text", "gray") or { r = 0.5, g = 0.5, b = 0.5 }
    local norm = RC:GetColor("text", "normal") or { r = 0.8, g = 0.8, b = 0.8 }
    local card = self:CreateSettingsCard(parent, yPos, RCL["Cross-account gold"])
    local cy = -30

    local function Refresh()
        if pageFrame and RC.ShowSidebarStatsBar then RC:ShowSidebarStatsBar(pageFrame, "gold") end
    end

    local rows, total, transit, legs = L:Rows()
    if #rows == 0 and transit == 0 then
        local fs = RC:CreateFontString(card, "OVERLAY", nil, 10)
        fs:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
        fs:SetText(RCL["Nothing tracked yet - this fills in as your characters log in."])
        fs:SetTextColor(gray.r, gray.g, gray.b)
        cy = cy - 24
    else
        for _, r in ipairs(rows) do
            local cc = r.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[r.class]
            local nf = self:CreateFontString(card, "OVERLAY", nil, 11)
            nf:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
            nf:SetWidth(150)
            nf:SetJustifyH("LEFT")
            nf:SetWordWrap(false)
            nf:SetText((r.name or "?") .. (r.me and RCL[" (you)"] or ""))
            if cc then nf:SetTextColor(cc.r, cc.g, cc.b) else nf:SetTextColor(norm.r, norm.g, norm.b) end
            local gf = self:CreateFontString(card, "OVERLAY", nil, 11)
            gf:SetPoint("TOPLEFT", card, "TOPLEFT", 170, cy)
            gf:SetText(GetCoinTextureString(r.copper + r.mail))
            local af = self:CreateFontString(card, "OVERLAY", nil, 9)
            af:SetPoint("TOPRIGHT", card, "TOPRIGHT", r.me and -15 or -34, cy - 1)
            af:SetText(AgeText(r) .. ((r.account and r.account ~= MyAccount() and r.account ~= "local")
                and ("  " .. r.account) or ""))
            af:SetTextColor(gray.r, gray.g, gray.b)
            if not r.me then
                local key, name = r.key, r.name or "?"
                local x = self.UI:CreateXCloseButton(card, 14, function()
                    self.UI:CreateConfirmDialog(RCL["Forget character"],
                        string.format(RCL["Remove %s from the gold ledger on all your accounts? Use this for a character that was deleted, renamed or transferred. If it is played again it comes back on its own."], name),
                        function()
                            L:Forget(key)
                            Refresh()
                        end, nil, RCL["Forget"], true)
                end)
                x:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, cy + 2)
            end
            cy = cy - 18
            if r.mail > 0 then
                local mf = self:CreateFontString(card, "OVERLAY", nil, 9)
                mf:SetPoint("TOPLEFT", card, "TOPLEFT", 27, cy + 2)
                mf:SetText(RCL["of which in the mailbox:"] .. " " .. GetCoinTextureString(r.mail))
                mf:SetTextColor(gray.r, gray.g, gray.b)
                cy = cy - 14
            end
        end
        for _, leg in ipairs(legs or {}) do
            local lf = self:CreateFontString(card, "OVERLAY", nil, 10)
            lf:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
            lf:SetWidth(150)
            lf:SetJustifyH("LEFT")
            lf:SetWordWrap(false)
            lf:SetText(string.format(RCL["In the post: %s to %s"], leg.from or "?", leg.to or "?"))
            lf:SetTextColor(gray.r, gray.g, gray.b)
            local lv = self:CreateFontString(card, "OVERLAY", nil, 10)
            lv:SetPoint("TOPLEFT", card, "TOPLEFT", 170, cy)
            lv:SetText(GetCoinTextureString(leg.c or 0))
            cy = cy - 16
        end
        if #rows + #(legs or {}) > 1 then
            cy = cy - 4
            local tf = self:CreateFontString(card, "OVERLAY", nil, 11)
            tf:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
            tf:SetText(RCL["Total"])
            tf:SetTextColor(norm.r, norm.g, norm.b)
            local tv = self:CreateFontString(card, "OVERLAY", nil, 11)
            tv:SetPoint("TOPLEFT", card, "TOPLEFT", 170, cy)
            tv:SetText(GetCoinTextureString(total))
            cy = cy - 18
        end
        cy = cy - 8
    end

    -- Freshness, account by account. Another account's numbers are exact
    -- as of the last time it was online together with this one; this is
    -- where that time is shown rather than implied.
    local st = L:LinkStatus()
    local green = RC:GetColor("text", "green") or norm
    local heard = ReadycheckDB and ReadycheckDB.goldPeers
    local ids = {}
    if type(heard) == "table" then
        for id, v in pairs(heard) do
            if type(v) == "table" then ids[#ids + 1] = id end
        end
    end
    if #ids > 0 then
        table_sort(ids, function(x, y) return (heard[x].seen or 0) > (heard[y].seen or 0) end)
        local hf = RC:CreateFontString(card, "OVERLAY", nil, 10)
        hf:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
        hf:SetText(RCL["Other accounts"])
        hf:SetTextColor(norm.r, norm.g, norm.b)
        cy = cy - 16
        for _, id in ipairs(ids) do
            local v = heard[id]
            local lf = RC:CreateFontString(card, "OVERLAY", nil, 10)
            lf:SetPoint("TOPLEFT", card, "TOPLEFT", 27, cy)
            lf:SetWidth(140)
            lf:SetJustifyH("LEFT")
            lf:SetWordWrap(false)
            local who = type(v.char) == "string" and v.char:match("^([^%-]+)") or nil
            lf:SetText(tostring(v.label or "?") .. ((who and who ~= v.label) and (" (" .. who .. ")") or ""))
            lf:SetTextColor(gray.r, gray.g, gray.b)
            local vf = RC:CreateFontString(card, "OVERLAY", nil, 10)
            vf:SetPoint("TOPLEFT", card, "TOPLEFT", 170, cy)
            if st.online[id] then
                vf:SetText(RCL["online - live"])
                vf:SetTextColor(green.r, green.g, green.b)
            else
                vf:SetText(string.format(RCL["last synced %s"], AgeText({ t = v.seen })))
                vf:SetTextColor(gray.r, gray.g, gray.b)
            end
            cy = cy - 14
        end
        cy = cy - 8
    end

    -- What the link is doing right now.
    local line
    if not st.bnet then
        line = RCL["Gold link: waiting for Battle.net - it tells your own accounts apart from everyone else's."]
    elseif st.chanFull then
        line = RCL["Gold link: can't join its hidden channel - you are in 10 chat channels already. Leave one and /reload."]
    else
        line = string.format(RCL["Gold link: %d of your characters online on %d other account(s)%s. Sent %d, refused %d, received %d."],
            st.chars, st.accounts, st.channel and "" or RCL[" (hidden channel not joined yet)"],
            st.sent, st.refused, st.heard)
    end
    local sf = RC:CreateFontString(card, "OVERLAY", nil, 9)
    sf:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
    sf:SetPoint("RIGHT", card, "RIGHT", -15, 0)
    sf:SetJustifyH("LEFT")
    sf:SetText(line)
    sf:SetTextColor(gray.r, gray.g, gray.b)
    cy = cy - 32

    cy = RC.UI:CreateHelpLine(card, 15, cy, RCL["Every character holding money on this account and your other accounts on the same Battle.net account, including money in their mailboxes and money mailed between them that has not been opened yet. Works on every character, with or without Mesh sync - friends on your mesh are never counted. An account that is not online shows its numbers as of the last time it was. Tick GOLD on the Stats tab to put the chip on the bar."],
        { short = RCL["Gold on every character of your Battle.net account, mail included."], title = RCL["Account gold"] })

    card:SetContentHeight(math.abs(cy))
    return yPos - card:GetHeight() - 15
end
