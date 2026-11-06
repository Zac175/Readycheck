------------------------------------------------------------------------
-- Readycheck - World Tools Core
--
-- Owns the account-wide store ReadycheckDB.worldTools, the tracked world
-- buff catalogue, coordinate pins, and the auto-accept summon engine.
-- WT_Bars / WT_Timers / WT_Turnins / WT_UI reach settings only through
-- WT.Store() and WT:GetFactionSettings().
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end
local RC = _G.Readycheck
if not RC then return end

RC.WorldTools = RC.WorldTools or {}
local WT = RC.WorldTools

local RCC = RC.Compat or {}
local GetSpellInfo = GetSpellInfo or RCC.GetSpellInfo

WT._CompatCLEUInfo = (C_CombatLog and C_CombatLog.GetCurrentEventInfo) or CombatLogGetCurrentEventInfo

------------------------------------------------------------------------
-- Table helpers
------------------------------------------------------------------------
local function Clone(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, inner in pairs(value) do out[key] = Clone(inner) end
    return out
end

-- Depth-limited merge into saved vars. A key that is already present is
-- never overwritten; `depth` caps how far we descend before a missing key
-- simply takes a whole copy of its default subtree. The cap matters: it
-- stops us "repairing" rows the user deliberately edited.
local function Backfill(target, defaults, depth)
    if type(target) ~= "table" or type(defaults) ~= "table" then return end
    for key, value in pairs(defaults) do
        local have = target[key]
        if have == nil then
            target[key] = Clone(value)
        elseif depth > 0 and type(have) == "table" and type(value) == "table" then
            Backfill(have, value, depth - 1)
        end
    end
end

------------------------------------------------------------------------
-- Tracked world buff catalogue
------------------------------------------------------------------------
-- Slot order is a saved-variable contract: autoSummon.buffTriggers is keyed
-- by these positions, so append only, never reorder or remove.
local AURA_SLOTS = {
    "DMF", "Ony", "DMT AP", "DMT SP", "DMT STAM", "SF", "ZG", "Rend", "BS", "FFF",
}

local MELEE_CLASSES = { WARRIOR = true, ROGUE = true, HUNTER = true }
local CASTER_CLASSES = {
    MAGE = true, WARLOCK = true, PRIEST = true,
    DRUID = true, PALADIN = true, SHAMAN = true,
}

-- Slot attributes; an absent entry means "any class, chronoboonable".
local AURA_SLOT_ATTRS = {
    ["DMT AP"] = { requiredClasses = MELEE_CLASSES },
    ["DMT SP"] = { requiredClasses = CASTER_CLASSES },
    ["BS"] = { boonable = false, requiredClasses = { WARRIOR = true, ROGUE = true } },
    ["FFF"] = { boonable = false, optional = true },
}

local SAYGE = "Sayge's Dark Fortune"
local SAYGE_ICON = 134334

-- One row per castable spell id: { slot, spellId, icon, label, sharedName }.
-- sharedName is the generic tooltip text several variants collapse onto.
local AURA_ROWS = {
    { "DMF", 23768, SAYGE_ICON, SAYGE .. " of Damage", SAYGE },
    { "DMF", 23769, SAYGE_ICON, SAYGE .. " of Resistance", SAYGE },
    { "DMF", 23767, SAYGE_ICON, SAYGE .. " of Armor", SAYGE },
    { "DMF", 23766, SAYGE_ICON, SAYGE .. " of Intelligence", SAYGE },
    { "DMF", 23738, SAYGE_ICON, SAYGE .. " of Spirit", SAYGE },
    { "DMF", 23737, SAYGE_ICON, SAYGE .. " of Stamina", SAYGE },
    { "DMF", 23735, SAYGE_ICON, SAYGE .. " of Strength", SAYGE },
    { "DMF", 23736, SAYGE_ICON, SAYGE .. " of Agility", SAYGE },
    { "Ony", 22888, 134153, "Rallying Cry of the Dragonslayer" },
    { "Ony", 355363, 134153, "Rallying Cry of the Dragonslayer" },
    { "DMT AP", 22817, 136109, "Fengus' Ferocity" },
    { "DMT SP", 22820, 135930, "Slip'kik's Savvy" },
    { "DMT STAM", 22818, 136054, "Mol'dar's Moxie" },
    { "SF", 15366, 135934, "Songflower Serenade" },
    { "ZG", 24425, 132107, "Spirit of Zandalar" },
    { "ZG", 355365, 132107, "Spirit of Zandalar" },
    { "Rend", 16609, 135759, "Warchief's Blessing" },
    { "Rend", 355366, 135759, "Warchief's Blessing" },
    { "BS", 25101, 132333, "Battle Shout" },
    { "FFF", 29338, 134468, "Fire Festival Fury" },
    { "FFF", 29846, 134468, "Fire Festival Fury" },
}

-- Lookup keys are punctuation-stripped so an apostrophe variant or a
-- differently-typeset client name still resolves back to its slot.
local function NormalizeName(name)
    local text = tostring(name or ""):lower()
    text = text:gsub("['`\226\128\153]", ""):gsub("[^%a%d%s]", " "):gsub("%s+", " ")
    return (text:gsub("^ +", ""):gsub(" +$", ""))
end

local TRACKED_AURAS = {}
local SLOT_INDEX = {}
local auraById, auraByName, auraByNormalName = {}, {}, {}

do
    local function IndexName(name, slot, option)
        if type(name) ~= "string" or name == "" then return end
        local ref = { slot = slot, option = option }
        auraByName[name:lower()] = ref
        local key = NormalizeName(name)
        if key ~= "" then auraByNormalName[key] = ref end
    end

    for position, short in ipairs(AURA_SLOTS) do
        local attrs = AURA_SLOT_ATTRS[short] or {}
        SLOT_INDEX[short] = position
        TRACKED_AURAS[position] = {
            short = short,
            options = {},
            boonable = attrs.boonable,
            optional = attrs.optional,
            requiredClasses = attrs.requiredClasses,
        }
    end

    local sharedSeen = {}
    for _, row in ipairs(AURA_ROWS) do
        local slot = SLOT_INDEX[row[1]]
        local entry = TRACKED_AURAS[slot]
        local option = { id = row[2], icon = row[3], label = row[4], fallbackName = row[5] }
        local optionIndex = #entry.options + 1
        entry.options[optionIndex] = option

        auraById[option.id] = { slot = slot, option = optionIndex }
        IndexName(option.label, slot, optionIndex)
        IndexName(GetSpellInfo and GetSpellInfo(option.id), slot, optionIndex)

        -- The shared name cannot tell the variants apart, so it points at
        -- option 1 and is registered once per slot rather than per variant.
        local shared = option.fallbackName
        if shared and not sharedSeen[slot .. shared] then
            sharedSeen[slot .. shared] = true
            IndexName(shared, slot, 1)
        end
    end
end

-- UI row order; storage order above keeps ZG at 7, the UI wants it beside Ony.
do
    local sequence = {
        "DMF", "Ony", "ZG", "DMT AP", "DMT SP", "DMT STAM", "SF", "Rend", "BS", "FFF",
    }
    local order = {}
    for position, short in ipairs(sequence) do order[position] = SLOT_INDEX[short] end
    WT.AURA_DISPLAY_ORDER = order
end

function WT:GetTrackedAuraList()
    return TRACKED_AURAS
end

function WT:IsAuraBoonable(index)
    local entry = TRACKED_AURAS[index]
    return (entry ~= nil) and entry.boonable ~= false
end

------------------------------------------------------------------------
-- Coordinate pins (pull timer bars use these for Rend zone sizing)
------------------------------------------------------------------------
local COORDINATE_SLOT_COUNT = 15
local PIN_TOLERANCE, BLANK_TOLERANCE = 0.02, 0.08

local SEEDED_PINS = {
    { "Rend South", 0.491113, 0.683181 },
    { "Mulgore DMF", 0.447506, 0.592198 },
    { "Rend North", 0.509452, 0.475196 },
}

local function BlankPin()
    return { name = "", x = 0, y = 0, tolerance = BLANK_TOLERANCE }
end

-- Always exactly COORDINATE_SLOT_COUNT rows: the options UI indexes them
-- positionally and will not create missing ones.
local function BuildPinSlots()
    local slots = {}
    for position = 1, COORDINATE_SLOT_COUNT do
        local seed = SEEDED_PINS[position]
        if seed then
            slots[position] = { name = seed[1], x = seed[2], y = seed[3], tolerance = PIN_TOLERANCE }
        else
            slots[position] = BlankPin()
        end
    end
    return slots
end

------------------------------------------------------------------------
-- Per-faction defaults (summon accept, gossip, turn-ins)
------------------------------------------------------------------------
local DEFAULT_SUMMON_WINDOW = 19

local FACTION_SETTINGS_DEFAULTS
do
    -- Everything arms the accept except the three Dire Maul Tribute stat
    -- buffs, which are usually collected deliberately, not off a summon.
    local triggerOff = { ["DMT AP"] = true, ["DMT SP"] = true, ["DMT STAM"] = true }
    local buffTriggers = {}
    for position, short in ipairs(AURA_SLOTS) do
        buffTriggers[position] = not triggerOff[short]
    end

    -- Sayge shows every class the same menu; damage is the default pick.
    local dmfBuffTypes = {}
    for _, group in ipairs({ MELEE_CLASSES, CASTER_CLASSES }) do
        for class in pairs(group) do dmfBuffTypes[class] = "Damage" end
    end

    FACTION_SETTINGS_DEFAULTS = {
        autoSummon = {
            enabled = true, alwaysAccept = false, taxiPvpDrop = false,
            summonWindow = DEFAULT_SUMMON_WINDOW,
            buffTriggers = buffTriggers,
        },
        autoGossip = {
            -- dmt: Tribute guards. bwl: portal via Orb of Command.
            dmtEnabled = true, bwlEnabled = true,
            -- Sayge stays off by default, one misclick burns the buff;
            -- skipCookie closes the gossip once the fortune lands.
            dmfEnabled = false, dmfSkipCookie = true,
            dmfBuffTypes = dmfBuffTypes,
        },
        autoQuest = {
            -- eko: Witch Doctor Mau'ari (Winterspring).
            -- coins: ZG coin sets at Vinchaxa (Yojamba Isle).
            ekoEnabled = true, coinsEnabled = true,
            -- zanza: Honor Tokens at Rin'wosho, then repair at the same NPC.
            zanzaEnabled = true, autoRepairEnabled = true,
            roidsEnabled = true,  -- "Rage of Ages" (Blasted Lands)
            -- Per-zanza opt in. Priority order: swiftness > spirit > sheen.
            zanzaPicks = { swiftness = true, sheen = true, spirit = true },
        },
    }
end
WT.FACTION_SETTINGS_DEFAULTS = FACTION_SETTINGS_DEFAULTS

-- autoSummon backfill is deliberately narrower than the defaults: enabled
-- and alwaysAccept are left alone once the block exists, and buffTriggers
-- is atomic so a user who cleared every trigger keeps it cleared.
local SUMMON_BACKFILL = {}
for _, key in ipairs({ "taxiPvpDrop", "summonWindow", "buffTriggers" }) do
    SUMMON_BACKFILL[key] = FACTION_SETTINGS_DEFAULTS.autoSummon[key]
end

------------------------------------------------------------------------
-- Timer / alert defaults
------------------------------------------------------------------------
-- One alert row. `flags` is a subset of notify/chat/flash, or the shorthand
-- "all" (every channel) / "off" (category disabled).
local function Alert(flags, sound)
    local on = {}
    for word in flags:gmatch("%a+") do on[word] = true end
    local every = on.all and true or false
    return {
        enabled = every or not on.off,
        notify = every or (on.notify or false),
        chat = every or (on.chat or false),
        flash = every or (on.flash or false),
        sound = sound,
    }
end

-- Relay-only categories: dispatched solely by the WorldBuffs network module
-- ("guild timer network" in the UI). Local detection never fires them, so
-- they stay chat-only and silent, as they always shipped: a cooldown
-- notice or a "dropped elsewhere" relay is a line to read, not a tone.
-- A sound can still be picked per row on the alerts page.
local SOUND_DROPPED  = "none"
local SOUND_COOLDOWN = "none"
local SOUND_ZAN_HANDIN = "atm_press"

local function RelayCategory(sound)
    return {
        rend = Alert("chat", sound),
        ony = Alert("chat", sound),
        nef = Alert("chat", sound),
    }
end

local timerSettingsDefaults = {}
do
    -- Flat by contract (these land directly in timerSettings) but grouped
    -- here so related knobs stay readable together.
    local groups = {
        -- Master gates. alertsEnabled gates every category (screen, chat,
        -- flash and sound) and is on by default; the page has its switch.
        { pullTimerEnabled = false, alertsEnabled = true, pullTimerLocked = true },
        { pullTimerMainBarWidth = 224, pullTimerMainBarHeight = 18 },
        { pullTimerSmallBarWidth = 150, pullTimerSmallBarHeight = 14, pullTimerExpandThreshold = 10 },
        { pullTimerMainOffsetX = 8, pullTimerMainOffsetY = 188 },
        { pullTimerIdleOffsetX = -527, pullTimerIdleOffsetY = -323 },
        -- Screen alert anchor is measured down from the TOP of the screen.
        { alertOffsetX = 0, alertOffsetY = -180, soundChannel = "Master" },
        { pullTimerBarColor = { 0.2, 0.8, 0.2 }, pullTimerBarColorWarn = { 1.0, 0.8, 0.0 } },
        { pullTimerBarColorCrit = { 1.0, 0.2, 0.2 } },
    }
    for _, group in ipairs(groups) do
        for key, value in pairs(group) do timerSettingsDefaults[key] = value end
    end

    timerSettingsDefaults.alerts = {
        questHandin = {
            rend = Alert("notify chat", "atm_press"),
            ony = Alert("notify chat", "atm_press"),
            nef = Alert("all", "atm_press"),
            zan = Alert("notify chat", SOUND_ZAN_HANDIN),
        },
        pullTimer = {
            rend = Alert("all", "happy_bells"),
            ony = Alert("all", "clear_announce"),
            nef = Alert("all", "clear_announce"),
            zan = Alert("all", "bell"),
            battleshout = Alert("all", "interface_select"),
        },
        npcDied = {
            ony = Alert("chat", "atm_press"),
            nef = Alert("chat", "atm_press"),
        },
        buffCooldown = RelayCategory(SOUND_COOLDOWN),
        buffDropped = RelayCategory(SOUND_DROPPED),
        -- Flat booleans, not alert rows: per-channel raid suppression plus
        -- the independent pull-timer-bars suppression toggle.
        raidDisable = { flash = true, sound = true, chat = true, notify = true, pullTimerBars = true },
    }
end

------------------------------------------------------------------------
-- Store (account-wide: ReadycheckDB.worldTools)
------------------------------------------------------------------------
-- Cached after the first successful init. Store() sits on hot paths (bar
-- OnUpdate, DispatchAlert), so the backfill walk must run only once.
local storeCache = nil

local function Store()
    if storeCache then return storeCache end
    if not ReadycheckDB then return nil end

    if type(ReadycheckDB.worldTools) ~= "table" then ReadycheckDB.worldTools = {} end
    local s = ReadycheckDB.worldTools

    if type(s.timerSettings) ~= "table" then s.timerSettings = {} end
    local ts = s.timerSettings

    -- alertsEnabled arrived after pullTimerEnabled and defaults to off, so a
    -- pre-existing install would go silent on upgrade. pullTimerEnabled is
    -- the oldest key here: if it is set at all this table has been written
    -- before, which means the install was already running with alerts on.
    if ts.alertsEnabled == nil then
        ts.alertsEnabled = (ts.pullTimerEnabled ~= nil) and true or false
    end

    -- Top level takes new keys only. Alert rows merge two levels down so a
    -- new category or a new buff appears, while an existing row is untouched.
    Backfill(ts, timerSettingsDefaults, 0)
    Backfill(ts.alerts, timerSettingsDefaults.alerts, 1)

    -- One-time fix-up (alertDefaultsV2). Before it:
    --  * alertsEnabled had no switch on any page, so a false there was
    --    never a choice - it could only be the old default;
    --  * the relay rows (buff dropped / cooldown ready) shipped silent and
    --    the Zandalar hand-in row shipped switched off.
    -- Only rows still exactly as they shipped are touched; a sound the
    -- user picked, or any channel they changed, is left alone.
    if not ts.alertDefaultsV2 then
        ts.alertDefaultsV2 = true
        ts.alertsEnabled = true
        local function Untouched(row, enabled, notify, chat, flash)
            return type(row) == "table" and (row.sound == nil or row.sound == "none")
                and (row.enabled ~= false) == enabled
                and (row.notify == true) == notify and (row.chat == true) == chat
                and (row.flash == true) == flash
        end
        local A = ts.alerts
        for _, cat in ipairs({ "buffDropped", "buffCooldown" }) do
            local group = A[cat]
            local want = timerSettingsDefaults.alerts[cat]
            if type(group) == "table" then
                for key, row in pairs(group) do
                    if want[key] and Untouched(row, true, false, true, false) then
                        row.sound = want[key].sound
                    end
                end
            end
        end
        local zan = A.questHandin and A.questHandin.zan
        if Untouched(zan, false, false, false, false) then
            A.questHandin.zan = Clone(timerSettingsDefaults.alerts.questHandin.zan)
        end
    end

    -- One-time (alertDefaultsV3): V2 above gave the relay rows a tone
    -- (Digital Tone on "cooldown ready", Magic Ring on "dropped"). They are
    -- silent again; a row still on exactly the tone V2 gave it goes back
    -- to none. Any other sound is a choice and stays.
    if not ts.alertDefaultsV3 then
        ts.alertDefaultsV3 = true
        local V2_TONE = { buffCooldown = "digital_tone", buffDropped = "magic_ring" }
        for cat, tone in pairs(V2_TONE) do
            local group = ts.alerts and ts.alerts[cat]
            if type(group) == "table" then
                for _, row in pairs(group) do
                    if type(row) == "table" and row.sound == tone then
                        row.sound = "none"
                    end
                end
            end
        end
    end

    if type(s.factionSettings) ~= "table" then s.factionSettings = {} end
    if type(s.timerData) ~= "table" then s.timerData = {} end

    if type(s.coordinateOverrides) ~= "table" then
        s.coordinateOverrides = BuildPinSlots()
    else
        for position = #s.coordinateOverrides + 1, COORDINATE_SLOT_COUNT do
            s.coordinateOverrides[position] = BlankPin()
        end
    end

    storeCache = s
    return s
end
WT.Store = Store

------------------------------------------------------------------------
-- Faction settings
------------------------------------------------------------------------
local function IsRealFaction(faction)
    return faction == "Alliance" or faction == "Horde"
end

function WT:GetPlayerFaction()
    return (UnitFactionGroup and UnitFactionGroup("player")) or "Unknown"
end

function WT:GetActiveFaction()
    local s = Store()
    local saved = s and s.activeFaction
    if IsRealFaction(saved) then return saved end
    return WT:GetPlayerFaction()
end

function WT:SetActiveFaction(faction)
    local s = IsRealFaction(faction) and Store()
    if s then s.activeFaction = faction end
end

function WT:EnsureFactionSettings(faction)
    local s = Store()
    if not s then return nil end

    local fs = s.factionSettings[faction]
    if type(fs) ~= "table" then
        fs = {}
        s.factionSettings[faction] = fs
    end

    -- Depth 0 creates any missing top block wholesale; each block then gets
    -- the merge depth its own semantics need.
    Backfill(fs, FACTION_SETTINGS_DEFAULTS, 0)
    Backfill(fs.autoSummon, SUMMON_BACKFILL, 0)
    Backfill(fs.autoGossip, FACTION_SETTINGS_DEFAULTS.autoGossip, 1)
    Backfill(fs.autoQuest, FACTION_SETTINGS_DEFAULTS.autoQuest, 1)

    return fs
end

function WT:GetFactionSettings(faction)
    faction = faction or WT:GetActiveFaction()
    if not IsRealFaction(faction) then faction = WT:GetPlayerFaction() end
    if not IsRealFaction(faction) then return nil end
    return WT:EnsureFactionSettings(faction)
end

function WT:GetPlayerFactionSettings()
    return WT:GetFactionSettings(WT:GetPlayerFaction())
end

------------------------------------------------------------------------
-- Coordinate lookup
------------------------------------------------------------------------
function WT:GetCoordinateOverrides()
    local s = Store()
    if s then return s.coordinateOverrides end
    return BuildPinSlots()
end

function WT:GetCoordinateLocation()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end

    local pos = C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
    local px, py = nil, nil
    if pos then px, py = pos:GetXY() end
    if not px or not py then return nil end

    for _, pin in ipairs(WT:GetCoordinateOverrides()) do
        local label = pin.name or ""
        local ax, ay = tonumber(pin.x) or 0, tonumber(pin.y) or 0
        local tol = tonumber(pin.tolerance) or BLANK_TOLERANCE
        local usable = label ~= "" and ax ~= 0 and ay ~= 0 and tol > 0
        if usable and math.abs(px - ax) <= tol and math.abs(py - ay) <= tol then
            return label
        end
    end

    return nil
end

------------------------------------------------------------------------
-- Auto-summon engine
------------------------------------------------------------------------
local CHRONOBOON_UNBOON_ID = 349863  -- cast when releasing the Chronoboon
local UNBOON_WINDOW = 3
local FRESH_DURATION_JUMP = 75   -- a refresh only counts as new past this jump
local BS_MIN_DURATION = 240      -- reject ordinary 2min warrior Battle Shout
local BS_SLOT_INDEX = SLOT_INDEX["BS"]

-- Runtime only, never persisted.
WT.hasFreshBuffForAutoSummon = false
WT.freshBuffDetectedAt = 0
WT.freshBuffSlots = nil
WT.pendingSummonAccept = false
WT.wasPvpFlagged = false
WT.isOnTaxi = false
WT.summonPending = false
WT.taxiPvpDropAt = 0

-- Only the unboon window matters here: buffs handed back by releasing a
-- Chronoboon must not register as fresh world buff gains.
WT.boonLifecycle = { inUnboonWindow = false }

-- Every summon path needs the same three-level guard, so resolve it once.
local function SummonSettings()
    local fs = WT:GetPlayerFactionSettings()
    local as = fs and fs.autoSummon
    if as and as.enabled then return as end
    return nil
end

local function ForgetFreshBuffs()
    WT.hasFreshBuffForAutoSummon = false
    WT.freshBuffSlots = nil
end

local function MarkFreshBuff(slot, now)
    WT.hasFreshBuffForAutoSummon = true
    WT.freshBuffDetectedAt = now
    WT.freshBuffSlots = WT.freshBuffSlots or {}
    WT.freshBuffSlots[slot] = true
end

local function IsFreshTransition(t)
    if t.to ~= "live" then return false end
    if t.from == "absent" then return true end
    return t.from == "live" and (t.durationJump or 0) > FRESH_DURATION_JUMP
end

function WT:DetectFreshBuffGains(transitions, now)
    local as = SummonSettings()
    if not as then return end

    local triggers = as.buffTriggers or {}
    local anyArmed = false

    for slot = 1, #TRACKED_AURAS do
        if triggers[slot] then
            anyArmed = true
            local t = transitions and transitions[slot]
            -- A Chronoboon release restores boonable buffs in bulk; those are
            -- not pickups and must not arm the accept.
            local restored = WT.boonLifecycle.inUnboonWindow and WT:IsAuraBoonable(slot)
            if t and not restored and IsFreshTransition(t) then
                MarkFreshBuff(slot, now)
            end
        end
    end

    if not anyArmed then return end

    local window = as.summonWindow or DEFAULT_SUMMON_WINDOW
    if WT.hasFreshBuffForAutoSummon and (now - WT.freshBuffDetectedAt) > window then
        ForgetFreshBuffs()
    end

    if WT.hasFreshBuffForAutoSummon and WT.summonPending then
        WT:TryAutoAcceptSummon()
    end
end

-- Ordinary warrior Battle Shout is short lived; only the Fallen Hero of the
-- Horde version (2h) is a world buff worth arming a summon.
local function IsShortBattleShout(slot, sample)
    if slot ~= BS_SLOT_INDEX then return false end
    local seconds = sample.duration or 0
    return seconds > 0 and seconds < BS_MIN_DURATION
end

-- From the shared aura read (RC.Auras).
local function ReadTrackedBuffs()
    local snapshot, now = {}, GetTime()
    for _, a in ipairs(RC.Auras:Buffs()) do
        local name, duration, expires, spellId = a.name, a.duration, a.expirationTime, a.spellId

        local ref = (spellId and auraById[spellId])
            or auraByName[name:lower()]
            or auraByNormalName[NormalizeName(name)]
        if ref then
            local remaining = 0
            if expires and expires > 0 then remaining = expires - now end
            local best = snapshot[ref.slot]
            if not best or remaining > best.remaining then
                snapshot[ref.slot] = { remaining = remaining, duration = duration or 0 }
            end
        end
    end
    return snapshot
end

local function DiffTrackedBuffs(before, after)
    local transitions = {}
    for slot = 1, #TRACKED_AURAS do
        local was, is = before[slot], after[slot]
        if is and was then
            transitions[slot] = {
                from = "live", to = "live",
                durationJump = (is.remaining or 0) - (was.remaining or 0),
            }
        elseif is and not IsShortBattleShout(slot, is) then
            transitions[slot] = { from = "absent", to = "live" }
        end
    end
    return transitions
end

-- Driven by the shared aura dispatcher below (coalesced), never inline
-- from the event itself.
local previousSnapshot = nil

function WT:ScanFreshBuffsForSummon()
    if not SummonSettings() then
        previousSnapshot = nil
        return
    end

    local snapshot = ReadTrackedBuffs()
    if previousSnapshot then
        WT:DetectFreshBuffGains(DiffTrackedBuffs(previousSnapshot, snapshot), GetTime())
    end
    previousSnapshot = snapshot
end

-- Gate for a non-forced accept. Expires a stale window as a side effect so
-- the flags do not leak into the next summon.
local function AutoAcceptAllowed(as)
    local always = as.alwaysAccept and true or false
    if not always and not WT.hasFreshBuffForAutoSummon then return false end

    if WT.hasFreshBuffForAutoSummon then
        local window = as.summonWindow or DEFAULT_SUMMON_WINDOW
        if (GetTime() - WT.freshBuffDetectedAt) > window then
            ForgetFreshBuffs()
            WT.pendingSummonAccept = false
            if not always then return false end
        end
    end
    return true
end

local function FreshBuffLabel()
    local names = {}
    for slot in pairs(WT.freshBuffSlots or {}) do
        local entry = TRACKED_AURAS[slot]
        if entry then names[#names + 1] = entry.short end
    end
    if #names == 0 then return "" end
    return " \226\128\148 " .. table.concat(names, ", ")
end

function WT:TryAutoAcceptSummon(force, reason)
    local as = SummonSettings()
    if not as then return end
    if not force and not AutoAcceptAllowed(as) then return end
    if not WT.summonPending then return end

    -- Defer out of combat lockdown, but say so exactly once.
    if InCombatLockdown() then
        if not WT.pendingSummonAccept then
            WT.pendingSummonAccept = true
            RC:Print("|cFFFFBB44Summon pending but in combat \226\128\148 will accept when combat ends.|r")
        end
        return
    end

    if not (StaticPopup_FindVisible and StaticPopup_OnClick) then return end
    if not StaticPopup_FindVisible("CONFIRM_SUMMON") then
        -- Popup already resolved manually or timed out; drop the stale flags
        -- so this path stops re-entering.
        WT.summonPending = false
        WT.pendingSummonAccept = false
        ForgetFreshBuffs()
        return
    end

    -- Print and clear BEFORE clicking: StaticPopup_OnClick teleports
    -- instantly and anything after it runs mid zone transition, where
    -- UnitAura is unreliable.
    RC:Print(string.format("|cFF00FF00Auto-accepted summon (%s)%s.|r",
        reason or "auto", FreshBuffLabel()))

    ForgetFreshBuffs()
    WT.pendingSummonAccept = false
    WT.summonPending = false

    local popup = StaticPopup_FindVisible("CONFIRM_SUMMON")
    if popup then StaticPopup_OnClick(popup, 1) end
end

------------------------------------------------------------------------
-- Player auras
------------------------------------------------------------------------
-- Through the addon-wide aura dispatcher (one UNIT_AURA reader for the
-- whole addon, coalesced to one call per 0.3s here) rather than a raw
-- UNIT_AURA registration and a ticker of its own.
RC:RegisterUnitAuraCallback("WorldToolsSummon", 0.3, function()
    if Store() then WT:ScanFreshBuffsForSummon() end
end)

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------
local eventFrame = CreateFrame("Frame")

local function RefreshZoneGate()
    local timers = WT.Timers
    if timers and timers.UpdateCLEUZoneGate then
        timers:UpdateCLEUZoneGate()
    end
end

function WT:PLAYER_LOGIN()
    Store()

    WT:SetActiveFaction(WT:GetPlayerFaction())
    WT:EnsureFactionSettings("Alliance")
    WT:EnsureFactionSettings("Horde")

    -- Seed PVP tracking for the taxi PVP-drop summon trigger.
    WT.wasPvpFlagged = UnitIsPVP("player") and true or false

    if WT.Timers and WT.Timers.Init then
        WT.Timers:Init()
    end

    RC:DebugPrint("WorldTools (testing) initialized", "worldbuffs")
end

function WT:PLAYER_ENTERING_WORLD()
    -- WT survives /reload, so clear the unboon window explicitly.
    WT.boonLifecycle.inUnboonWindow = false
    RefreshZoneGate()
end

function WT:ZONE_CHANGED_NEW_AREA()
    RefreshZoneGate()
end

function WT:UNIT_SPELLCAST_SUCCEEDED(unit, _, spellId)
    if unit ~= "player" then return end
    if tonumber(spellId) ~= CHRONOBOON_UNBOON_ID then return end

    WT.boonLifecycle.inUnboonWindow = true
    C_Timer.After(UNBOON_WINDOW, function()
        WT.boonLifecycle.inUnboonWindow = false
    end)
end

function WT:CONFIRM_SUMMON()
    if not Store() then return end
    WT.summonPending = true

    local as = SummonSettings()
    if as and as.taxiPvpDrop and WT.taxiPvpDropAt > 0 then
        local window = as.summonWindow or DEFAULT_SUMMON_WINDOW
        if (GetTime() - WT.taxiPvpDropAt) <= window then
            WT:TryAutoAcceptSummon(true, "taxi PVP drop")
            return
        end
    end

    WT:TryAutoAcceptSummon()
end

function WT:CANCEL_SUMMON()
    WT.summonPending = false
end

function WT:PLAYER_REGEN_ENABLED()
    if not WT.pendingSummonAccept then return end
    WT.pendingSummonAccept = false
    WT:TryAutoAcceptSummon()
end

function WT:PLAYER_CONTROL_LOST()
    if not Store() then return end
    -- UnitOnTaxi is not yet true on the event itself.
    C_Timer.After(0.2, function()
        if UnitOnTaxi("player") then WT.isOnTaxi = true end
    end)
end

function WT:PLAYER_CONTROL_GAINED()
    WT.isOnTaxi = false
end

function WT:PLAYER_FLAGS_CHANGED(unitTarget)
    if unitTarget and unitTarget ~= "player" then return end
    if not Store() then return end

    local wasFlagged = WT.wasPvpFlagged
    local isFlagged = UnitIsPVP("player") and true or false
    WT.wasPvpFlagged = isFlagged

    -- Losing the PVP flag mid-flight is the taxi drop summon cue.
    if not wasFlagged or isFlagged or not WT.isOnTaxi then return end

    WT.taxiPvpDropAt = GetTime()
    local as = SummonSettings()
    if as and as.taxiPvpDrop then
        WT:TryAutoAcceptSummon(true, "taxi PVP drop")
    end
end

-- Thin forwarders into the Timers module. CLEU is not here: Timers owns it
-- on its own zone-gated frame.
local TIMER_FORWARDS = {
    CHAT_MSG_MONSTER_YELL = "OnMonsterYell",
    CHAT_MSG_MONSTER_SAY = "OnMonsterSay",
    QUEST_TURNED_IN = "OnQuestTurnedIn",
}

for event, method in pairs(TIMER_FORWARDS) do
    WT[event] = function(_, ...)
        local timers = WT.Timers
        local handler = timers and timers[method]
        if handler then handler(timers, ...) end
    end
end

local BROADCAST_EVENTS = {
    "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
    "CONFIRM_SUMMON", "CANCEL_SUMMON", "PLAYER_REGEN_ENABLED",
    "PLAYER_FLAGS_CHANGED", "PLAYER_CONTROL_LOST", "PLAYER_CONTROL_GAINED",
    "CHAT_MSG_MONSTER_YELL", "CHAT_MSG_MONSTER_SAY", "QUEST_TURNED_IN",
}
for _, event in ipairs(BROADCAST_EVENTS) do
    eventFrame:RegisterEvent(event)
end

-- Unit scoped so it never fires for anyone but the player.
eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local handler = WT[event]
    if handler then handler(WT, ...) end
end)
