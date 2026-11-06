------------------------------------------------------------------------
-- Readycheck - Aura Tracker
-- One engine, two instances:
--   raidBuffTracker   the class buffs on YOU (Fortitude, Intellect, the
--                     Blessings, Battle Shout ...) with time remaining,
--   bossDebuffTracker the raid debuffs on your TARGET (Sunder, curses,
--                     Scorch stacks, Demo Shout ...) with time remaining.
-- Each instance is a movable row list plus voice warnings through
-- RC:SpeakTTS, gated by the same visibility modes as the bars, and an
-- opt-in whisper to whoever cast an aura once it has run out (see
-- WHISPER REMINDERS below).
--
-- Everything this file needs lives in the main addon (Readycheck):
-- RC.Position, RC.UI, RC:QueueVisibilityCheck / IsInRaidInstance /
-- IsInCity / IsInGroup (Core_Boot), RC:SpeakTTS (TTSEngine), the raid
-- data tables and RC.Profiler. The db tables (raidBuffTracker,
-- bossDebuffTracker) are registered in the main addon's PM_Registry so
-- profiles, export and mesh sync carry them whether or not this addon
-- is switched on; the UIMover bindings and mesh refresh hooks there are
-- nil-guarded for the same reason.
--
-- Performance contract (the project's high-frequency rule):
--   UNIT_AURA                    -> sets a dirty flag, nothing else
--   PLAYER_TARGET_CHANGED        -> dirty flag + one UnitGUID call + the
--                                   per-target CLEU cache is cleared
--   COMBAT_LOG_EVENT_UNFILTERED  -> one CombatLogGetCurrentEventInfo,
--                                   two table lookups, at most a
--                                   timestamp and a name written; registered ONLY
--                                   while the debuff tracker has a live
--                                   attackable (boss) target
--   zone / rest / roster events  -> RC:QueueVisibilityCheck (0.3s debounce)
-- Every aura walk, every string and every colour change happens in one
-- 0.25s ticker per instance (RC.Profiler:TrackTicker), which only runs
-- while the instance is enabled and its "show in" mode passes. The
-- aura walk itself runs at most twice a second; the other ticks only
-- re-print the countdown text of rows already laid out.
--
-- Era caveat: UnitDebuff only reports duration/expirationTime for auras
-- the player applied. For everyone else's debuffs the tracker keeps a
-- per-target "applied at" timestamp from the combat log and estimates
-- remaining = applied + catalog baseDuration - now.
------------------------------------------------------------------------

-- Catalogs. Matching is by aura NAME, so every rank and every caster of
-- a spell in `spells` lands on the same row. `icon` is a spell id for
-- GetSpellInfo; once the aura has been seen its live icon is used.
-- `speak` is the short spoken form when the label reads badly aloud.
-- `remind` is the whisper-reminder default (see WHISPER REMINDERS):
--   true  = whispered about unless the user turns it off,
--   false = offered, off until the user turns it on,
--   nil   = never offered. That is every aura with nobody to remind:
--           range auras with no duration, procs, and debuffs the whole
--           raid stacks or refreshes in its rotation (Sunder, Scorch...).
local RAID_BUFF_CATALOG = {
    { id = "fortitude",   label = "Fortitude",             spells = {"Power Word: Fortitude", "Prayer of Fortitude"},           icon = 1243, remind = true },
    { id = "spirit",      label = "Divine Spirit",         spells = {"Divine Spirit", "Prayer of Spirit"},                      icon = 14752, speak = "Spirit", remind = true },
    { id = "shadowprot",  label = "Shadow Protection",     spells = {"Shadow Protection", "Prayer of Shadow Protection"},       icon = 976, remind = true },
    { id = "intellect",   label = "Arcane Intellect",      spells = {"Arcane Intellect", "Arcane Brilliance"},                  icon = 1459, speak = "Intellect", remind = true },
    { id = "motw",        label = "Mark of the Wild",      spells = {"Mark of the Wild", "Gift of the Wild"},                   icon = 1126, remind = true },
    { id = "thorns",      label = "Thorns",                spells = {"Thorns"},                                                 icon = 467, remind = true },
    { id = "might",       label = "Blessing of Might",     spells = {"Blessing of Might", "Greater Blessing of Might"},         icon = 19740, speak = "Might", remind = true },
    { id = "kings",       label = "Blessing of Kings",     spells = {"Blessing of Kings", "Greater Blessing of Kings"},         icon = 20217, speak = "Kings", remind = true },
    { id = "wisdom",      label = "Blessing of Wisdom",    spells = {"Blessing of Wisdom", "Greater Blessing of Wisdom"},       icon = 19742, speak = "Wisdom", remind = true },
    { id = "salvation",   label = "Blessing of Salvation", spells = {"Blessing of Salvation", "Greater Blessing of Salvation"}, icon = 1038,  speak = "Salvation", remind = true },
    { id = "light",       label = "Blessing of Light",     spells = {"Blessing of Light", "Greater Blessing of Light"},         icon = 19977, speak = "Blessing of Light", remind = true },
    { id = "sanctuary",   label = "Blessing of Sanctuary", spells = {"Blessing of Sanctuary", "Greater Blessing of Sanctuary"}, icon = 20911, speak = "Sanctuary", remind = true },
    { id = "battleshout", label = "Battle Shout",          spells = {"Battle Shout"},                                           icon = 6673, remind = false },
    { id = "trueshot",    label = "Trueshot Aura",         spells = {"Trueshot Aura"},                                          icon = 19506 },
    { id = "lotp",        label = "Leader of the Pack",    spells = {"Leader of the Pack"},                                     icon = 17007 },
    { id = "moonkin",     label = "Moonkin Aura",          spells = {"Moonkin Aura"},                                           icon = 24907 },
    { id = "bloodpact",   label = "Blood Pact",            spells = {"Blood Pact"},                                             icon = 6307 },
}
local RAID_BUFF_DEFAULT_TRACKED = {
    fortitude = true, spirit = true, shadowprot = true, intellect = true, motw = true,
    might = true, kings = true, wisdom = true, salvation = true, light = true, sanctuary = true,
    battleshout = true,
}

-- baseDuration is the Era duration used for the combat-log estimate when
-- the debuff belongs to someone else; stacks = show the application
-- count on the icon. Improved Shadow Bolt's debuff is literally named
-- "Shadow Vulnerability"; Nightfall's proc is "Spell Vulnerability".
local BOSS_DEBUFF_CATALOG = {
    { id = "sunder",       label = "Sunder Armor",            spells = {"Sunder Armor"},                          icon = 7386,  baseDuration = 30,  stacks = true,  speak = "Sunder" },
    { id = "expose",       label = "Expose Armor",            spells = {"Expose Armor"},                          icon = 8647,  baseDuration = 30, remind = false },
    { id = "cor",          label = "Curse of Recklessness",   spells = {"Curse of Recklessness"},                 icon = 704,   baseDuration = 120, remind = true },
    { id = "coe",          label = "Curse of the Elements",   spells = {"Curse of the Elements"},                 icon = 1490,  baseDuration = 300, remind = true },
    { id = "cos",          label = "Curse of Shadow",         spells = {"Curse of Shadow"},                       icon = 17862, baseDuration = 300, remind = true },
    { id = "cow",          label = "Curse of Weakness",       spells = {"Curse of Weakness"},                     icon = 702,   baseDuration = 120, remind = true },
    { id = "faeriefire",   label = "Faerie Fire",             spells = {"Faerie Fire", "Faerie Fire (Feral)"},    icon = 770,   baseDuration = 40, remind = true },
    { id = "demoshout",    label = "Demoralizing Shout",      spells = {"Demoralizing Shout", "Demoralizing Roar"}, icon = 1160, baseDuration = 30, speak = "Demo Shout", remind = false },
    { id = "thunderclap",  label = "Thunder Clap",            spells = {"Thunder Clap"},                          icon = 6343,  baseDuration = 30, remind = false },
    { id = "scorch",       label = "Scorch stacks",           spells = {"Fire Vulnerability"},                    icon = 22959, baseDuration = 30,  stacks = true,  speak = "Scorch" },
    { id = "winterschill", label = "Winter's Chill",          spells = {"Winter's Chill"},                        icon = 12579, baseDuration = 15,  stacks = true },
    { id = "shadowweave",  label = "Shadow Weaving",          spells = {"Shadow Weaving"},                        icon = 15258, baseDuration = 15,  stacks = true },
    { id = "isb",          label = "Improved Shadow Bolt",    spells = {"Shadow Vulnerability"},                  icon = 17800, baseDuration = 12,  stacks = true,  speak = "Shadow Bolt debuff" },
    { id = "nightfall",    label = "Nightfall",               spells = {"Spell Vulnerability"},                   icon = 23605, baseDuration = 5 },
    { id = "huntersmark",  label = "Hunter's Mark",           spells = {"Hunter's Mark"},                         icon = 1130,  baseDuration = 120, remind = true },
    { id = "jow",          label = "Judgement of Wisdom",     spells = {"Judgement of Wisdom"},                   icon = 20186, baseDuration = 10,  speak = "Wisdom judgement", remind = false },
    { id = "jol",          label = "Judgement of Light",      spells = {"Judgement of Light"},                    icon = 20185, baseDuration = 10,  speak = "Light judgement", remind = false },
    { id = "joc",          label = "Judgement of the Crusader", spells = {"Judgement of the Crusader"},           icon = 20303, baseDuration = 10,  speak = "Crusader judgement", remind = false },
    { id = "gift",         label = "Gift of Arthas",          spells = {"Gift of Arthas"},                        icon = 11374, baseDuration = 180 },
    { id = "annihilator",  label = "Annihilator",             spells = {"Annihilator"},                           icon = 16928, baseDuration = 45,  stacks = true },
    { id = "ignite",       label = "Ignite",                  spells = {"Ignite"},                                icon = 12654, baseDuration = 4,   stacks = true },
}
local BOSS_DEBUFF_DEFAULT_TRACKED = {
    sunder = true, cor = true, coe = true, cos = true, faeriefire = true, demoshout = true,
    thunderclap = true, scorch = true, winterschill = true, shadowweave = true, nightfall = true,
    jow = true,
}

local function InitializeAuraTracker()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeAuraTracker)
        return
    end
    if not RC.db or not RC.UI or not RC.Position then
        C_Timer.After(0.2, InitializeAuraTracker)
        return
    end
    if RC.AuraTracker and RC.AuraTracker.initialized then return end

    local CP = RC.Compat or {}
    local UnitBuff   = UnitBuff   or CP.UnitBuff
    local UnitDebuff = UnitDebuff or CP.UnitDebuff
    local GetSpellInfo = GetSpellInfo or CP.GetSpellInfo
    local GetTime, UnitExists, UnitGUID, UnitName = GetTime, UnitExists, UnitGUID, UnitName
    local UnitCanAttack, UnitIsDeadOrGhost = UnitCanAttack, UnitIsDeadOrGhost
    local UnitClassification, UnitLevel = UnitClassification, UnitLevel
    local UnitAffectingCombat = UnitAffectingCombat
    local UnitIsUnit, UnitIsPlayer, UnitIsConnected = UnitIsUnit, UnitIsPlayer, UnitIsConnected
    local UnitInParty, UnitInRaid, GetUnitName = UnitInParty, UnitInRaid, GetUnitName
    local SendChatMessage = SendChatMessage
    local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo
    local CreateFrame, UIParent = CreateFrame, UIParent
    local math_floor, math_max, math_min = math.floor, math.max, math.min
    local string_format, table_sort, table_concat = string.format, table.sort, table.concat
    local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
    local wipe = wipe

    local FLAT = RC.UI.FLAT or "Interface\\Buttons\\WHITE8X8"
    local COLOR_GROUP = "auraTracker"
    local MAX_ROWS = 40
    local FALLBACK_ICON = 134400
    local TICK = 0.25
    local SCAN_EVERY = 0.5
    local TITLE_H = 16
    local PAD = 2
    local NO_MOTION = { style = "none" }

    -- WHISPER REMINDERS (db.whisperCaster, off by default). When a
    -- tracked aura runs out, the player who cast it gets one whisper:
    -- "Fortitude has run out on me" / "Faerie Fire has dropped off
    -- Patchwerk". It is a nudge, so every rule here errs towards
    -- staying quiet:
    --   * only auras with `remind` in the catalog, and of those only the
    --     ones switched on (db.whisperFor) - never a rotation or stacking
    --     debuff, never a range aura;
    --   * only a caster who is in the group, online, alive, and not you;
    --   * a buff must have run its full time. One that vanished early was
    --     dispelled, clicked off, or lost when you died - nobody forgot it;
    --   * nothing is sent for WHISPER_GRACE seconds, and nothing at all
    --     if the aura is back by then (most are simply being recast);
    --   * everything owed to one person goes in one whisper;
    --   * the same person hears about the same aura at most once per
    --     db.whisperCooldown, from anything at most once per
    --     WHISPER_PERSON_GAP, and whispers are WHISPER_GAP apart.
    -- A reminder still waiting WHISPER_STALE seconds after it was due
    -- (held back by those limits) is dropped rather than sent late.
    local WHISPER_GRACE = { player = 10, target = 4 }
    local WHISPER_PERSON_GAP = 20
    local WHISPER_GAP = 2
    local WHISPER_STALE = 30
    local EXPIRY_SLACK = 3      -- "ran its full time" = gone within 3s of its end
    local EXPIRY_LATE = 30      -- ...and noticed within 30s of it

    -- "A", "A and B", "A, B and C"
    local function JoinLabels(list)
        local n = #list
        if n == 1 then return list[1] end
        return table_concat(list, ", ", 1, n - 1) .. RCL[" and "] .. list[n]
    end

    local AT = RC.AuraTracker or {}
    RC.AuraTracker = AT
    AT.initialized = true
    AT.trackers = AT.trackers or {}

    local function SpellIcon(spellId)
        if not spellId or not GetSpellInfo then return FALLBACK_ICON end
        local _, _, icon = GetSpellInfo(spellId)
        return icon or FALLBACK_ICON
    end

    -- "4:32" past a minute, "45s" under it.
    local function FormatShort(secs)
        secs = math_floor((secs or 0) + 0.5)
        if secs >= 60 then
            return string_format("%d:%02d", math_floor(secs / 60), secs % 60)
        end
        return secs .. "s"
    end

    ------------------------------------------------------------------
    -- The customization standard on both trackers (db.anchors.<part>,
    -- db.formats.time / .name, db.sounds.urgent): every text and the icon
    -- placeable, the time and names worded, a sound when an aura turns
    -- urgent or goes missing. Nothing is touched until a spec is set.
    ------------------------------------------------------------------
    local function AD(p, to, rp, x, y, j) return { point = p, to = to, relPoint = rp, x = x, y = y, justify = j } end
    local LIST_DEF = {
        icon = AD("LEFT", "row", "LEFT", 2, 0),
        count = AD("BOTTOMRIGHT", "icon", "BOTTOMRIGHT", 1, -1, "RIGHT"),
        time = AD("RIGHT", "row", "RIGHT", -4, 0, "RIGHT"),
        name = { point = "LEFT", to = "icon", relPoint = "RIGHT", x = 4, y = 0, justify = "LEFT",
                 point2 = "RIGHT", to2 = "time", relPoint2 = "LEFT", x2 = -4, y2 = 0 },
    }
    local COMPACT_DEF = {
        icon = AD("TOP", "row", "TOP", 0, 0),
        count = AD("TOPRIGHT", "icon", "TOPRIGHT", 1, 1),
        time = AD("TOP", "icon", "BOTTOM", 0, 5, "CENTER"),
        name = AD("BOTTOM", "icon", "TOP", 0, 2, "CENTER"),
    }
    local TITLE_DEF = { point = "LEFT", to = "bar", relPoint = "LEFT", x = 4, y = 0, justify = "LEFT",
                        point2 = "RIGHT", to2 = "bar", relPoint2 = "RIGHT", x2 = -4, y2 = 0 }
    RC.AURA_TRACKER_TARGETS = {
        { value = "row", text = RCL["The row"] }, { value = "icon", text = RCL["Icon"] },
        { value = "name", text = RCL["Name"] }, { value = "time", text = RCL["Time left"] },
        { value = "count", text = RCL["Stack count"] },
    }
    RC.AURA_TRACKER_TIME_FORMAT = { time = "mmss" }
    RC.AURA_TRACKER_NAME_FORMAT = {}
    -- an element's default place for a layout (the compact time's lift
    -- follows the font size, as the layout has always done)
    local function AuraAnchorDefault(elem, compact, fs)
        if elem == "title" then return TITLE_DEF end
        if compact then
            if elem == "time" then COMPACT_DEF.time.y = math_floor((fs or 11) * 0.45 + 0.5) end
            return COMPACT_DEF[elem]
        end
        return LIST_DEF[elem]
    end
    RC.AuraTrackerAnchorDefault = function(_, elem, compact, fs) return AuraAnchorDefault(elem, compact, fs) end
    local function RowTo(row)
        if not row._atTo then
            row._atTo = function(k)
                if k == "row" then return row elseif k == "icon" then return row.icon
                elseif k == "name" then return row.label elseif k == "time" then return row.time
                elseif k == "count" then return row.count end
            end
        end
        return row._atTo
    end
    local ROW_PARTS = { icon = "icon", count = "count", time = "time", name = "label" }
    local function PlaceRowParts(db, row, compact)
        local a = type(db.anchors) == "table" and db.anchors or nil
        if not a then return end
        for elem, field in pairs(ROW_PARTS) do
            local spec = a[elem]
            if spec then
                local _, two = RC.UI:ApplyAnchor(row[field], spec, AuraAnchorDefault(elem, compact, db.fontSize), RowTo(row))
                if elem == "name" and not two and compact then row.label:Show() end
            end
        end
    end
    local timeValues, timeKinds = {}, { value = "time" }
    -- the time bucket of a row -> its state name (per-state looks)
    local AT_STATE_OF = { "normal", "warning", "urgent" }
    RC.AURA_TRACKER_STATES = {
        { id = "normal", label = RCL["Plenty of time"] },
        { id = "warning", label = RCL["Running out"] },
        { id = "urgent", label = RCL["Urgent or missing"] },
    }

    local function TimeText(db, rem, fallback)
        local f = type(db.formats) == "table" and db.formats.time
        if not f then return fallback(rem) end
        timeValues.value = rem
        return RC.UI:FormatText(f, RC.AURA_TRACKER_TIME_FORMAT, timeValues, timeKinds, "value")
    end
    local nameValues, nameKinds = {}, { value = "name" }
    local function NameText(db, name)
        local f = type(db.formats) == "table" and db.formats.name
        if not f then return name end
        nameValues.value = name
        return RC.UI:FormatText(f, RC.AURA_TRACKER_NAME_FORMAT, nameValues, nameKinds, "value")
    end

    -- Spoken form: whole minutes from 90s up, else seconds.
    local function FriendlyTime(secs)
        secs = math_floor((secs or 0) + 0.5)
        if secs >= 90 then
            local m = math_floor(secs / 60 + 0.5)
            return m .. (m == 1 and RCL[" minute"] or RCL[" minutes"])
        end
        return secs .. (secs == 1 and RCL[" second"] or RCL[" seconds"])
    end

    -- Boss/add name set, built once from the static raid data, for the
    -- "bosses only" gate on mobs the server marks as plain elites.
    local bossNames
    local function IsBossUnit(unit)
        if UnitClassification(unit) == "worldboss" or UnitLevel(unit) == -1 then
            return true
        end
        if not bossNames then
            bossNames = {}
            if RC.raidData then
                for _, raid in pairs(RC.raidData) do
                    for _, b in ipairs(raid.bosses or {}) do bossNames[b] = true end
                end
            end
            if RC.encounterAddPhases then
                for bossName, info in pairs(RC.encounterAddPhases) do
                    bossNames[bossName] = true
                    for _, a in ipairs(info.adds or {}) do bossNames[a] = true end
                    for _, a in ipairs(info.aliases or {}) do bossNames[a] = true end
                end
            end
        end
        local n = UnitName(unit)
        return (n and bossNames[n]) and true or false
    end

    -- Sort for the buff list: missing first, then soonest to expire,
    -- unknown-duration last, catalog order breaking ties.
    local function SortRows(a, b)
        local ra = a.isPresent and (a.timed and a.sortKey or 1e8) or -1
        local rb = b.isPresent and (b.timed and b.sortKey or 1e8) or -1
        if ra ~= rb then return ra < rb end
        return a.order < b.order
    end

    -- The layout family on top of the tracker's own grow / compact / per-row
    -- settings (db.layout: sort, reverse, max). Unset: its own order.
    RC.AURA_TRACKER_SORTS = {
        { value = "name", text = RCL["Name"] }, { value = "time", text = RCL["Time left"] },
        { value = "missing", text = RCL["Missing first"] },
    }
    local function Remaining(rt) return rt.isPresent and (rt.timed and (rt.expEff or 0) or 1e9) or -1 end
    local AURA_SORTS = {
        name = function(a, b)
            if a.entry.label ~= b.entry.label then return (a.entry.label or "") < (b.entry.label or "") end
            return a.order < b.order
        end,
        time = function(a, b)
            local ra, rb = Remaining(a), Remaining(b)
            if ra ~= rb then return ra < rb end
            return a.order < b.order
        end,
        missing = function(a, b)
            local ma, mb = a.isPresent and 1 or 0, b.isPresent and 1 or 0
            if ma ~= mb then return ma < mb end
            return SortRows(a, b)
        end,
    }
    local function ArrangeRows(db, rows)
        local L = type(db.layout) == "table" and db.layout or nil
        if not L then return end
        RC.UI:SortItems(rows, L, nil, AURA_SORTS)
        if L.reverse then
            local n = #rows
            for i = 1, math_floor(n / 2) do rows[i], rows[n - i + 1] = rows[n - i + 1], rows[i] end
        end
        local mx = tonumber(L.max)
        if mx and mx >= 1 then for i = #rows, mx + 1, -1 do rows[i] = nil end end
    end

    ------------------------------------------------------------------
    -- Tracker factory
    ------------------------------------------------------------------
    local function NewTracker(spec)
        local T = {
            spec        = spec,
            key         = spec.key,
            entries     = {},   -- ordered resolved entries {id,label,speak,spells,icon,baseDuration,stacks,order}
            nameToEntry = {},   -- aura name -> entry
            rt          = {},   -- id -> runtime state (kept across rebuilds)
            rows        = {},   -- current render order (rt refs)
            previewPool = {},
            dirty       = true,
            lastScan    = 0,
            gen         = 0,
            layoutSig   = nil,
            targetGUID  = nil,
            cleuArmed   = false,
            whisperPending = {},  -- entry id -> { due, who, label, on }
            whisperSent    = {},  -- "who|id" -> time, who -> time
            whisperHold    = 0,
        }
        T.auraFn = (spec.filter == "HELPFUL") and UnitBuff or UnitDebuff

        -- Runtime table shared with UIMover (RC.<key>.frame) and used as
        -- the state object for RC:QueueVisibilityCheck.
        RC[spec.key] = RC[spec.key] or {}
        T.state = RC[spec.key]

        function T:Cfg()
            return RC.db[self.key]
        end

        function T:InitDB()
            if not RC.db[self.key] then RC.db[self.key] = {} end
            local db = RC.db[self.key]
            if db.compactDirection == nil and db.growLeft then
                db.compactDirection, db.growLeft = "LEFT", false
            end
            for k, v in pairs(spec.defaults) do
                if db[k] == nil then
                    if type(v) == "table" then
                        db[k] = RC.DeepCopy and RC.DeepCopy(v) or v
                    else
                        db[k] = v
                    end
                end
            end
            if type(db.tracked) ~= "table" then db.tracked = {} end
            if type(db.custom) ~= "table" then db.custom = {} end
        end

        -- Is the whisper reminder on for this aura? remind is the catalog
        -- default; db.whisperFor holds only what the user changed.
        function T:WhisperWanted(id, remind)
            local db = self:Cfg()
            if not db or not db.whisperCaster or remind == nil then return false end
            local choice = type(db.whisperFor) == "table" and db.whisperFor[id]
            if choice == nil then return remind end
            return choice and true or false
        end

        local function AddEntry(self, id, label, spells, icon, baseDuration, stacks, speak, remind)
            local e = {
                id = id, label = label, speak = speak or label,
                spells = spells, icon = icon or FALLBACK_ICON,
                baseDuration = baseDuration or 0, stacks = stacks and true or false,
                order = #self.entries + 1,
                whisper = self:WhisperWanted(id, remind),
            }
            self.entries[#self.entries + 1] = e
            for _, n in ipairs(spells) do
                if n and n ~= "" and not self.nameToEntry[n] then
                    self.nameToEntry[n] = e
                end
            end
            local rt = self.rt[id]
            if not rt then
                rt = { applied = {}, warnLevel = 0, lastSpoke = 0, present = false, everPresent = false }
                self.rt[id] = rt
            end
            rt.entry = e
            rt.order = e.order
        end

        -- Resolves catalog toggles + custom entries into the live list.
        function T:RebuildEntries()
            local db = self:Cfg()
            wipe(self.entries)
            wipe(self.nameToEntry)
            for _, c in ipairs(spec.catalog) do
                if db.tracked[c.id] then
                    AddEntry(self, c.id, c.label, c.spells, SpellIcon(c.icon), c.baseDuration, c.stacks, c.speak, c.remind)
                end
            end
            for _, cu in ipairs(db.custom) do
                if type(cu) == "table" and cu.label and cu.label ~= "" then
                    local spells = cu.spells
                    if type(spells) ~= "table" or #spells == 0 then spells = { cu.label } end
                    local icon = FALLBACK_ICON
                    if GetSpellInfo then
                        local _, _, ic = GetSpellInfo(spells[1])
                        if ic then icon = ic end
                    end
                    -- Custom auras are offered for reminders, off until asked for.
                    AddEntry(self, "custom:" .. cu.label, cu.label, spells, icon, cu.baseDuration, cu.stacks, cu.speak, false)
                end
            end
            -- Drop runtime state for ids that no longer exist.
            for id, rt in pairs(self.rt) do
                if not rt.entry or rt.entry ~= self:FindEntry(id) then
                    self.rt[id] = nil
                end
            end
            self.layoutSig = nil
            self.dirty = true
        end

        function T:FindEntry(id)
            for _, e in ipairs(self.entries) do
                if e.id == id then return e end
            end
            return nil
        end

        --------------------------------------------------------------
        -- Gates
        --------------------------------------------------------------
        function T:ZoneOK()
            if RC._uiMoverActive then return true end
            local db = self:Cfg()
            local mode = db.visibilityMode or spec.defaults.visibilityMode or "always"
            local rf = db.visibilityRaids
            if mode == "always" then return true end
            if mode == "group" then return RC:IsInGroup() end
            if mode == "city" then return RC:IsInCity() end
            if mode == "raids" or mode == "raids_only" then return RC:IsInRaidInstance(rf) end
            if mode == "raids_and_city" then return RC:IsInRaidInstance(rf) or RC:IsInCity() end
            return true
        end

        -- Ticker alive: enabled, something to track, zone mode passes.
        function T:ShouldRun()
            if RC._uiMoverActive then return true end
            local db = self:Cfg()
            if not db or not db.enabled then return false end
            if #self.entries == 0 then return false end
            return self:ZoneOK()
        end

        -- Per-tick gate: combat and (debuffs) a live attackable target.
        function T:GateOK()
            if RC._uiMoverActive then return true end
            local db = self:Cfg()
            if db.onlyInCombat and not UnitAffectingCombat("player") then return false end
            if spec.unit == "target" then
                if not UnitExists("target") then return false end
                if not UnitCanAttack("player", "target") then return false end
                if UnitIsDeadOrGhost("target") then return false end
                if db.bossesOnly and not IsBossUnit("target") then return false end
            end
            return true
        end

        --------------------------------------------------------------
        -- Combat-log fallback (debuff instance only)
        --------------------------------------------------------------
        function T:SetTargetGUID(guid)
            if guid == self.targetGUID then return end
            self.targetGUID = guid
            for _, rt in pairs(self.rt) do
                rt.applied.t = nil
                rt.applied.by = nil
                rt.by, rt.src, rt.srcSeen, rt.srcExp = nil, nil, nil, nil
                rt.present = false
                rt.everPresent = false
                rt.warnLevel = 0
                rt.lastRemaining = nil
                rt.lastExp = nil
            end
            wipe(self.whisperPending)
            self.dirty = true
        end

        function T:ArmCLEU(on)
            on = on and true or false
            if on == self.cleuArmed then return end
            self.cleuArmed = on
            if not self.eventFrame then return end
            if _G.READYCHECK_IS_FOREVER then return end   -- (no combat log for addons on WoW Forever)
            if on then
                self.eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            else
                self.eventFrame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            end
        end

        -- The whole CLEU handler. No allocation, no API besides the one
        -- combat-log read; everything else waits for the ticker.
        function T:OnCLEU()
            local _, sub, _, _, sourceName, _, _, destGUID, _, _, _, _, spellName = CombatLogGetCurrentEventInfo()
            if destGUID ~= self.targetGUID then return end
            local e = self.nameToEntry[spellName]
            if not e then return end
            local rt = self.rt[e.id]
            if not rt then return end
            if sub == "SPELL_AURA_APPLIED" or sub == "SPELL_AURA_REFRESH" or sub == "SPELL_AURA_APPLIED_DOSE" then
                rt.applied.t = GetTime()
                rt.applied.dur = e.baseDuration
                rt.applied.by = sourceName      -- who to remind if it drops
                self.dirty = true
            elseif sub == "SPELL_AURA_REMOVED" then
                rt.applied.t = nil
                self.dirty = true
            end
        end

        --------------------------------------------------------------
        -- Scan + evaluate (ticker only)
        --------------------------------------------------------------
        function T:Scan()
            local gen = self.gen + 1
            self.gen = gen
            local fn, unit, map, rts = self.auraFn, spec.unit, self.nameToEntry, self.rt
            if not fn then return end
            for i = 1, MAX_ROWS do
                local name, icon, count, _, duration, expirationTime, source = fn(unit, i)
                if not name then break end
                local e = map[name]
                if e then
                    local rt = rts[e.id]
                    if rt and (rt.gen ~= gen or (expirationTime or 0) > (rt.exp or 0)) then
                        rt.gen = gen
                        rt.icon = icon
                        rt.count = count or 0
                        rt.duration = duration or 0
                        rt.exp = expirationTime or 0
                        rt.src = source     -- caster's unit token; read in NoteCaster
                    end
                end
            end
        end

        function T:Speak(rt, text, now, escalate)
            local db = self:Cfg()
            local cd = db.ttsCooldown or 30
            if not escalate and (now - (rt.lastSpoke or 0)) < cd then return end
            if RC.SpeakTTS then RC:SpeakTTS(text) end
            rt.lastSpoke = now
            RC:DebugPrint(spec.debugName .. " TTS: " .. text, "buff")
        end

        --------------------------------------------------------------
        -- Whisper reminders (rules at WHISPER REMINDERS above)
        --------------------------------------------------------------
        -- Who cast the aura that is up now. Looked up only when the
        -- caster token or the expiry moved - a new application - and not
        -- on every scan. A name is kept only for a player in the group;
        -- your own casts and strangers' leave it empty.
        function T:NoteCaster(rt)
            local src = rt.src
            if src == rt.srcSeen and rt.exp == rt.srcExp then return end
            rt.srcSeen, rt.srcExp = src, rt.exp
            rt.by = nil
            if not src or UnitIsUnit(src, "player") or not UnitIsPlayer(src) then return end
            if not (UnitInParty(src) or UnitInRaid(src)) then return end
            rt.by = GetUnitName(src, true)
        end

        -- A tracked aura has just gone. Decides whether anyone is owed a
        -- reminder and, if so, parks it for WHISPER_GRACE.
        function T:QueueWhisper(rt, e, now)
            if RC._uiMoverActive then return end
            -- The combat log names whoever applied a debuff last; the
            -- aura scan is the fallback (and the only source for buffs).
            local who = rt.applied.by or rt.by
            if not who or who == "" then return end
            local on
            if spec.unit == "player" then
                local ended = rt.lastExp
                if not ended or now < ended - EXPIRY_SLACK or now - ended > EXPIRY_LATE then return end
                if UnitIsDeadOrGhost("player") then return end
            else
                on = UnitName("target")
            end
            self.whisperPending[e.id] = {
                due = now + (WHISPER_GRACE[spec.unit] or 10), who = who, label = e.label, on = on,
            }
        end

        -- Sends at most one whisper per call. Runs in the ticker, only
        -- while something is parked.
        function T:FlushWhispers(now)
            local pend, sent = self.whisperPending, self.whisperSent
            -- Pick someone who is due and has not just been whispered; a
            -- person still inside WHISPER_PERSON_GAP stays parked and
            -- does not hold up anyone else.
            local who
            for id, p in pairs(pend) do
                local rt = self.rt[id]
                if not rt or rt.isPresent or not (rt.entry and rt.entry.whisper)
                   or now - p.due > WHISPER_STALE then
                    pend[id] = nil      -- back up, no longer wanted, or too late
                elseif not who and now >= p.due
                       and now - (sent[p.who] or -1e9) >= WHISPER_PERSON_GAP then
                    who = p.who
                end
            end
            if not who or now < self.whisperHold then return end

            -- A name works as a unit token only for someone in the group,
            -- so UnitExists doubles as the "still in the raid" check.
            local reachable = UnitExists(who) and not UnitIsUnit(who, "player")
                and UnitIsConnected(who) and not UnitIsDeadOrGhost(who)
                and (spec.unit ~= "player" or not UnitIsDeadOrGhost("player"))

            local cooldown = self:Cfg().whisperCooldown or 120
            local labels, on = {}, nil
            for id, p in pairs(pend) do
                if p.who == who then
                    pend[id] = nil
                    if reachable and now - (sent[who .. "|" .. id] or -1e9) >= cooldown then
                        sent[who .. "|" .. id] = now
                        labels[#labels + 1] = p.label
                        on = on or p.on
                    end
                end
            end
            if #labels == 0 then return end
            table_sort(labels)

            local msg
            if spec.unit == "player" then
                msg = string_format(#labels == 1 and RCL["Readycheck reminder: %s has run out on me."]
                    or RCL["Readycheck reminder: %s have run out on me."], JoinLabels(labels))
            else
                msg = string_format(#labels == 1 and RCL["Readycheck reminder: %s has dropped off %s."]
                    or RCL["Readycheck reminder: %s have dropped off %s."], JoinLabels(labels), on or RCL["the boss"])
            end
            sent[who] = now
            self.whisperHold = now + WHISPER_GAP
            SendChatMessage(msg, "WHISPER", nil, who)
            RC:DebugPrint(spec.debugName .. " whisper to " .. who .. ": " .. msg, "buff")
        end

        function T:Evaluate(now)
            local db = self:Cfg()
            local gen = self.gen
            local warnAt, warnAt2 = db.warnAt or 0, db.warnAt2 or 0
            local canSpeak = (db.alertMode ~= "ui") and not RC._uiMoverActive
            local inCombat = UnitAffectingCombat("player")
            -- Debuff "missing" lines only matter mid-fight.
            local missingOK = canSpeak and db.ttsMissing and (spec.unit ~= "target" or inCombat)
            local cooldown = db.ttsCooldown or 30

            for _, e in ipairs(self.entries) do
                local rt = self.rt[e.id]
                local present = (rt.gen == gen)
                local remaining, timed, expEff = nil, false, 0
                if present then
                    if rt.exp and rt.exp > 0 then
                        expEff = rt.exp
                    elseif rt.applied.t and (rt.applied.dur or 0) > 0 then
                        expEff = rt.applied.t + rt.applied.dur
                    end
                    if expEff > 0 then
                        remaining = expEff - now
                        if remaining > 0 then
                            timed = true
                        else
                            -- Stale estimate: the aura is still up past the
                            -- catalog duration, so stop pretending to know.
                            remaining, expEff = nil, 0
                        end
                    end
                end

                if present then
                    if not rt.present then
                        rt.present = true
                        rt.everPresent = true
                        rt.warnLevel = 0
                        rt.lastExp = nil
                    end
                    if e.whisper then
                        self:NoteCaster(rt)
                        -- Kept while the aura is up, and NOT cleared when
                        -- its time passes: the server takes a moment to
                        -- remove an expired aura, and a scan landing in
                        -- that moment sees it up with no time left.
                        if timed then rt.lastExp = expEff end
                    end
                    if timed then
                        -- A refresh pushes remaining back up: re-arm warnings.
                        if rt.lastRemaining and remaining > rt.lastRemaining + 1 then
                            rt.warnLevel = 0
                        end
                        if warnAt2 > 0 and remaining <= warnAt2 then
                            if rt.warnLevel < 2 then
                                rt.warnLevel = 2
                                if canSpeak then
                                    self:Speak(rt, e.speak .. RCL[" expiring"], now, true)
                                end
                            end
                        elseif warnAt > 0 and remaining <= warnAt then
                            if rt.warnLevel < 1 then
                                rt.warnLevel = 1
                                if canSpeak then
                                    self:Speak(rt, e.speak .. ", " .. FriendlyTime(remaining), now, true)
                                end
                            end
                        end
                        rt.lastRemaining = remaining
                    else
                        rt.lastRemaining = nil
                    end
                else
                    if rt.present then
                        rt.present = false
                        rt.lastRemaining = nil
                        rt.warnLevel = 0
                        if e.whisper then self:QueueWhisper(rt, e, now) end
                        if missingOK then
                            self:Speak(rt, e.speak .. RCL[" missing"], now, true)
                        end
                    elseif missingOK and rt.everPresent and cooldown > 0 then
                        self:Speak(rt, e.speak .. RCL[" missing"], now, false)
                    end
                end

                rt.isPresent = present
                rt.timed = timed
                rt.expEff = expEff
                rt.sortKey = timed and remaining or 0
            end
        end

        --------------------------------------------------------------
        -- Frame + rows
        --------------------------------------------------------------
        -- Compact flow: icons run along compactDirection and wrap into a
        -- new line after compactPerRow. The wrap goes down/up (growDown)
        -- for a horizontal run and right/left (growLeft) for a vertical one.
        local function CompactFlow(db)
            local dir = db.compactDirection or "RIGHT"
            if dir == "DOWN" or dir == "UP" then
                return true, dir == "UP", db.growLeft and true or false
            end
            return false, not db.growDown, dir == "LEFT"
        end

        -- The pinned corner is the one new rows/icons grow away from.
        local function PinPoint(db)
            if db.layout ~= "compact" then
                return (db.growDown and "TOP" or "BOTTOM") .. "LEFT"
            end
            local _, goesUp, goesLeft = CompactFlow(db)
            return (goesUp and "BOTTOM" or "TOP") .. (goesLeft and "RIGHT" or "LEFT")
        end

        local function BindPosition(self, frame)
            local db = self:Cfg()
            local point = PinPoint(db)
            self.pinPoint = point
            RC.Position.Bind(frame, function() return RC.db[self.key] end, {
                point     = point,
                pointKey  = "anchorPoint",
                legacyRel = "CENTER",
                default   = { x = spec.defaultPos.x, y = spec.defaultPos.y },
            })
        end

        -- The frame's visual parts (fill, border, title, row pool) with no
        -- position, mouse or name: the live frame and the settings
        -- preview's sample are both built here.
        function T:BuildFrame(parent, name)
            local db = self:Cfg()
            local frame = CreateFrame("Frame", name, parent)
            frame:SetWidth(db.rowWidth or 180)
            frame:SetHeight(20)

            local bg = frame:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetTexture(FLAT)
            frame.bg = bg
            frame.border = RC.UI:CreateSimpleBorder(frame, 1)

            -- Small title, only while the mover is open: the list is
            -- self-explanatory in play and the label would eat a row.
            local titleBar = CreateFrame("Frame", nil, frame)
            titleBar:SetHeight(TITLE_H)
            titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
            titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
            local titleText = RC:CreateFontString(titleBar, "OVERLAY", nil, 10)
            titleText:SetPoint("LEFT", titleBar, "LEFT", 4, 0)
            titleText:SetPoint("RIGHT", titleBar, "RIGHT", -4, 0)
            titleText:SetJustifyH("LEFT")
            titleText:SetText(spec.title)
            titleBar.text = titleText
            RC.UI:TagElement(titleText, "title")
            local rule = titleBar:CreateTexture(nil, "ARTWORK")
            rule:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
            rule:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
            rule:SetHeight(1)
            rule:SetTexture(FLAT)
            titleBar.rule = rule
            titleBar:Hide()
            frame.titleBar = titleBar

            frame.rows = {}
            return frame
        end

        function T:CreateFrame()
            if self.frame then return self.frame end
            local db = self:Cfg()
            local frame = self:BuildFrame(UIParent, spec.frameName)
            BindPosition(self, frame)
            RC.Position.RestoreFrame(frame)

            frame:SetFrameStrata("MEDIUM")
            frame:SetFrameLevel(50)
            frame:SetClampedToScreen(true)
            frame:SetMovable(true)
            frame:EnableMouse(not db.locked)
            frame:RegisterForDrag("LeftButton")

            RC.Position.MakeMovable(frame, function() return not RC.db[self.key].locked end)

            frame:Hide()
            self.frame = frame
            self.state.frame = frame
            self:ApplyAppearance()
            RC:DebugPrint(spec.debugName .. " frame created", "buff")
            return frame
        end

        -- A sample of this tracker on another parent (the settings
        -- preview): the same methods over its own frame, rows and pool,
        -- fed sample rows, never registered anywhere.
        function T:NewSample(parent)
            local S = setmetatable({ isSample = true, rows = {}, previewPool = {}, layoutSig = false }, { __index = self })
            S.frame = self.BuildFrame(S, parent, nil)
            S.sampleEntries = {}
            for i = 1, math_min(5, #spec.catalog) do
                local c = spec.catalog[i]
                S.sampleEntries[i] = { id = c.id, label = c.label, spells = c.spells,
                    icon = SpellIcon(c.icon) or FALLBACK_ICON, baseDuration = c.baseDuration, stacks = c.stacks }
            end
            S:ApplyAppearance()
            return S
        end

        local function AcquireRow(self, i)
            local frame = self.frame
            local row = frame.rows[i]
            if row then return row end
            row = CreateFrame("Frame", nil, frame)
            row:SetHeight(16)

            local rowBg = row:CreateTexture(nil, "BACKGROUND")
            rowBg:SetAllPoints()
            rowBg:SetTexture(FLAT)
            row.bg = rowBg

            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetPoint("LEFT", row, "LEFT", 2, 0)
            icon:SetSize(16, 16)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.icon = icon

            local count = RC:CreateFontString(row, "OVERLAY", nil, 10, "THICKOUTLINE")
            count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
            count:SetJustifyH("RIGHT")
            count:Hide()
            row.count = count

            local time = RC:CreateFontString(row, "OVERLAY", nil, 11)
            time:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            time:SetJustifyH("RIGHT")
            time:SetWordWrap(false)
            row.time = time

            local label = RC:CreateFontString(row, "OVERLAY", nil, 11)
            label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
            label:SetPoint("RIGHT", time, "LEFT", -4, 0)
            label:SetJustifyH("LEFT")
            label:SetWordWrap(false)
            row.label = label

            -- Compact cells can carry a name tooltip while the frame is
            -- unlocked or the mover is open; Layout flips row.tipEnabled
            -- and EnableMouse, the scripts are wired once here. Drags
            -- over a mouse-enabled cell are forwarded to the frame so an
            -- unlocked grid still moves by its body.
            row:EnableMouse(false)
            row:RegisterForDrag("LeftButton")
            row:SetScript("OnDragStart", function(r)
                local h = frame:GetScript("OnDragStart")
                if h then h(frame) end
            end)
            row:SetScript("OnDragStop", function(r)
                local h = frame:GetScript("OnDragStop")
                if h then h(frame) end
            end)
            row:SetScript("OnEnter", function(r)
                if not r.tipEnabled or not r.rtRef or not r.rtRef.entry then return end
                local e = r.rtRef.entry
                GameTooltip:SetOwner(r, "ANCHOR_RIGHT")
                local gold, norm = RC:GetColor("text", "gold"), RC:GetColor("text", "normal")
                GameTooltip:SetText(e.label, gold.r, gold.g, gold.b)
                GameTooltip:AddLine(table_concat(e.spells, ", "), norm.r, norm.g, norm.b, true)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)

            -- a click on a part of the preview's sample picks its controls
            RC.UI:TagElement(icon, "icon") RC.UI:TagElement(count, "count")
            RC.UI:TagElement(time, "time") RC.UI:TagElement(label, "name")

            row:Hide()
            frame.rows[i] = row
            self:PaintRow(row)
            return row
        end

        -- Re-anchors a pooled row's children for list or compact use.
        -- List: [icon] label ........ time. Compact: icon at the top of
        -- the cell, time/X centred on its bottom edge (the Reminders icon
        -- style), stacks in the top-right corner, label hidden.
        local function ShapeRow(row, compact, cw, showBg, fs)
            row.icon:ClearAllPoints()
            row.time:ClearAllPoints()
            row.label:ClearAllPoints()
            row.count:ClearAllPoints()
            if compact then
                row.icon:SetPoint("TOP", row, "TOP", 0, 0)
                row.time:SetPoint("TOP", row.icon, "BOTTOM", 0, math_floor((fs or 11) * 0.45 + 0.5))
                row.count:SetPoint("TOPRIGHT", row.icon, "TOPRIGHT", 1, 1)
                row.time:SetWidth(cw)
                row.time:SetJustifyH("CENTER")
                row.label:Hide()
                row.bg:Hide()
            else
                row.icon:SetPoint("LEFT", row, "LEFT", 2, 0)
                row.count:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 1, -1)
                row.time:SetPoint("RIGHT", row, "RIGHT", -4, 0)
                row.time:SetJustifyH("RIGHT")
                row.label:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
                row.label:SetPoint("RIGHT", row.time, "LEFT", -4, 0)
                row.label:Show()
                if showBg then row.bg:Show() else row.bg:Hide() end
            end
        end

        function T:IsCompact()
            local db = self:Cfg()
            return db.layout == "compact"
        end

        -- Icon edge for the active layout (list and compact keep their
        -- own value; the Appearance slider edits whichever is live).
        function T:IconSize()
            local db = self:Cfg()
            if db.layout == "compact" then return db.compactIconSize or 32 end
            return db.iconSize or 16
        end

        -- Compact cell: icon on top, countdown centred on its bottom
        -- edge, so only the lower half of the text hangs below. The cell
        -- is as wide as the icon or ~3.4 characters of the time font,
        -- whichever is larger, so "4:32" never spills sideways.
        function T:CellSize()
            local db = self:Cfg()
            local fs = db.fontSize or 11
            local isz = self:IconSize()
            local cw = math_max(isz, math_floor(fs * 3.4))
            local ch = isz + math_floor(fs * 0.6 + 0.5) + 2
            return cw, ch
        end

        -- Static per-row sizes/fonts; called for every pooled row on an
        -- appearance change and once for a fresh row.
        -- Fonts: db.font (name and time; its size stays on fontSize) and
        -- db.stackFont (the stack count; its own size, else 55% of the icon).
        local ROW_FONT = { outline = "OUTLINE", shadow = false }
        local STACK_FONT = { outline = "THICKOUTLINE", shadow = false }
        function T:PaintRow(row)
            local db = self:Cfg()
            local fs = db.fontSize or 11
            local isz = self:IconSize()
            row.icon:SetSize(isz, isz)
            local f = type(db.font) == "table" and db.font or {}
            local rowSpec = { face = f.face, outline = f.outline, shadow = f.shadow, size = fs }
            RC:ApplyFontSpec(row.label, rowSpec, ROW_FONT)
            RC:ApplyFontSpec(row.time, rowSpec, ROW_FONT)
            local sf = type(db.stackFont) == "table" and db.stackFont or {}
            RC:ApplyFontSpec(row.count, { face = sf.face, outline = sf.outline, shadow = sf.shadow,
                size = sf.size or math_max(8, math_floor(isz * 0.55)) }, STACK_FONT)
            row.time:SetWidth(math_max(34, fs * 4))
            local rowC = RC:GetColor(COLOR_GROUP, "rowBackground")
            row.bg:SetVertexColor(rowC.r, rowC.g, rowC.b, rowC.a or 0.03)
            local sc = RC:GetColor(COLOR_GROUP, "stackText")
            row.count:SetTextColor(sc.r, sc.g, sc.b, sc.a or 1)
            row.bucket = nil
            row.presentFlag = nil
        end

        function T:RowHeight()
            local db = self:Cfg()
            return math_max(self:IconSize(), (db.fontSize or 11) + 4) + 2
        end

        -- Whole-frame chrome from db + theme: scale, opacity, width,
        -- lock state, fonts on every pooled row.
        function T:ApplyAppearance()
            local frame = self.frame
            if not frame then return end
            local db = self:Cfg()
            frame:SetScale(db.scale or 1)
            frame:EnableMouse(not db.locked)
            local bgC = RC:GetColor(COLOR_GROUP, "background")
            frame.bg:SetVertexColor(bgC.r, bgC.g, bgC.b, (bgC.a or 1) * (db.opacity or 0.85))
            RC.UI:UpdateBorderColor(frame.border, RC:GetColor(COLOR_GROUP, "border"), 1)
            -- Background off hides the fill, border and list stripes;
            -- RC.Position then clamps to the visible rows instead.
            local showBg = db.showBackground ~= false
            if showBg then frame.bg:Show() else frame.bg:Hide() end
            for _, edge in pairs(frame.border) do
                if showBg then edge:Show() else edge:Hide() end
            end
            local tc = RC:GetColor(COLOR_GROUP, "titleText")
            frame.titleBar.text:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)
            local ta = type(db.anchors) == "table" and db.anchors.title or nil
            if ta or frame.titleBar._atMoved then
                local bar = frame.titleBar
                RC.UI:ApplyAnchor(bar.text, ta, TITLE_DEF, function(k) if k == "bar" then return bar elseif k == "frame" then return frame end end)
                bar._atMoved = ta ~= nil
            end
            RC:ApplyCustomFont(frame.titleBar.text, 10, "OUTLINE")
            local accent = RC:GetColor("ui", "accentGold")
            frame.titleBar.rule:SetVertexColor(accent.r, accent.g, accent.b, 0.6)
            for _, row in ipairs(frame.rows) do self:PaintRow(row) end
            -- layer / clamp, fade rules and edge from the customization standard
            if RC.ApplyFrameCustom then
                RC:ApplyFrameCustom(frame, function() return self:Cfg() end, { scale = false, parts = { bg = frame.bg, border = frame.border }, sample = self.isSample })
            end
            if self.isSample then self.layoutSig = false return end
            self:SyncAnchor()
            self.layoutSig = nil
            if RC.Position.ScheduleClamp then RC.Position.ScheduleClamp(frame) end
        end

        -- Flip the pinned point with the grow direction so the anchored
        -- edge stays put; RC.Position converts the stored spot in place.
        -- Re-pin when the grow directions or the layout change the
        -- corner; RC.Position converts the stored spot in place so the
        -- new pinned corner starts where it is on screen now.
        function T:SyncAnchor()
            local frame = self.frame
            if not frame or self.pinPoint == PinPoint(self:Cfg()) then return end
            BindPosition(self, frame)
            RC.Position.RestoreFrame(frame)
            self.layoutSig = nil
        end

        function T:SetGrowDown(on)
            self:Cfg().growDown = on and true or false
            self:SyncAnchor()
        end

        -- Compact vertical runs: new columns start to the left.
        function T:SetGrowLeft(on)
            self:Cfg().growLeft = on and true or false
            self:SyncAnchor()
        end

        function T:SetCompactDirection(dir)
            self:Cfg().compactDirection = dir
            self:SyncAnchor()
        end

        function T:ResetPosition()
            if self.frame then
                RC.Position.ResetFrame(self.frame, true)
            end
        end

        -- SetPoint offsets are in the frame's own units, so a bare
        -- SetScale slides the frame; rescale the stored spot so the
        -- pinned edge stays where it is on screen.
        function T:SetScale(v)
            local db = self:Cfg()
            local old = db.scale or 1
            db.scale = v
            local frame = self.frame
            if not frame or old == v then return end
            frame:SetScale(v)
            if db.centred and type(db.xOffset) == "number" and type(db.yOffset) == "number" then
                local k = old / v
                RC.Position.SetFrame(frame, db.xOffset * k, db.yOffset * k, true)
            end
        end

        -- Live repaint while an Appearance slider drags. Only redraws a
        -- frame that is already on screen, so no gate is bypassed.
        function T:LiveAppearance()
            if not self.frame then return end
            self:ApplyAppearance()
            if self.frame:IsShown() then self:Render(GetTime()) end
        end

        -- Re-anchors the pooled rows for the current order. Only runs
        -- when the visible set changes (layoutSig) or after an
        -- appearance edit; the per-tick pass never touches anchors.
        function T:Layout(rows)
            local frame = self.frame
            local db = self:Cfg()
            local n = #rows
            local showTitle = (RC._uiMoverActive and not self.isSample) and true or false
            local titleH = showTitle and TITLE_H or 0
            local growDown = db.growDown
            local compact = self:IsCompact()
            local showBg = db.showBackground ~= false
            -- Name tooltips only while the frame can be interacted with.
            local tips = compact and not self.isSample and (showTitle or not db.locked) or false

            if showTitle then frame.titleBar:Show() else frame.titleBar:Hide() end

            if compact then
                local cw, ch = self:CellSize()
                local gap = db.compactSpacing or 2
                local perLine = math_max(1, math_min(20, db.compactPerRow or 8))
                local vertical, goesUp, goesLeft = CompactFlow(db)
                local along = math_min(n, perLine)
                local lines = math_max(1, math.ceil(n / perLine))
                local cols = vertical and lines or along
                local rowsN = vertical and along or lines
                local p = (goesUp and "BOTTOM" or "TOP") .. (goesLeft and "RIGHT" or "LEFT")
                for i = 1, n do
                    local row = AcquireRow(self, i)
                    RC.Motion.Stop(row)
                    local a, b = (i - 1) % perLine, math_floor((i - 1) / perLine)
                    local col, line = a, b
                    if vertical then col, line = b, a end
                    local x = 1 + PAD + col * (cw + gap)
                    if goesLeft then x = -x end
                    local y
                    if goesUp then
                        y = 1 + PAD + line * (ch + gap)
                    else
                        y = -(1 + titleH + PAD + line * (ch + gap))
                    end
                    row:ClearAllPoints()
                    row:SetSize(cw, ch)
                    row:SetPoint(p, frame, p, x, y)
                    ShapeRow(row, true, cw, showBg, db.fontSize or 11)
                    PlaceRowParts(db, row, true)
                    -- a name placed on a compact cell shows
                    if row.label:IsShown() then row.label:SetText(NameText(db, rows[i].entry.label)) end
                    row.rtRef = rows[i]
                    row.tipEnabled = tips
                    row:EnableMouse(tips)
                    row.bucket = nil
                    row.presentFlag = nil
                    row:Show()
                end
                frame:SetWidth(2 + PAD * 2 + cols * cw + (cols - 1) * gap)
                frame:SetHeight(2 + titleH + PAD * 2 + rowsN * ch + (rowsN - 1) * gap)
            else
                local rh = self:RowHeight()
                local gap = db.spacing or 0
                local step = rh + gap
                for i = 1, n do
                    local row = AcquireRow(self, i)
                    RC.Motion.Stop(row)
                    row:ClearAllPoints()
                    row:SetHeight(rh)
                    if growDown then
                        local y = -(1 + titleH + PAD + (i - 1) * step)
                        row:SetPoint("TOPLEFT",  frame, "TOPLEFT",   1, y)
                        row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, y)
                    else
                        local y = 1 + PAD + (i - 1) * step
                        row:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",   1, y)
                        row:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, y)
                    end
                    ShapeRow(row, false, nil, showBg)
                    PlaceRowParts(db, row, false)
                    row.time:SetWidth(math_max(34, (db.fontSize or 11) * 4))
                    row.label:SetText(NameText(db, rows[i].entry.label))
                    row.rtRef = rows[i]
                    row.tipEnabled = false
                    row:EnableMouse(false)
                    row.bucket = nil
                    row.presentFlag = nil
                    row:Show()
                end
                frame:SetWidth(db.rowWidth or 180)
                frame:SetHeight(2 + titleH + PAD * 2 + n * rh + math_max(0, n - 1) * gap)
            end
            for i = n + 1, #frame.rows do frame.rows[i]:Hide() end
        end

        -- Sample rows while the mover is open, so the frame is placed
        -- at its real populated size with every colour state visible.
        function T:BuildPreviewRows(now)
            local rows = self.rows
            local pool = self.previewPool
            local list = self.entries
            -- the settings sample is never empty: nothing tracked shows the
            -- first catalog auras
            if #list == 0 and self.isSample then list = self.sampleEntries or {} end
            if #list == 0 then return end
            local n = math_min(5, #list)
            local allUp = self.isSample and self.sampleMode == "allup"
            for i = 1, n do
                local e = list[i] or list[1]
                local p = pool[i]
                if not p then p = { applied = {} }; pool[i] = p end
                p.entry = e
                p.order = i
                p.count = e.stacks and (6 - i) or 0
                p.icon = nil
                if allUp then
                    p.isPresent, p.timed, p.expEff = true, true, now + (self:Cfg().warnAt or 30) * (1 + i)
                elseif i == n and n > 1 then
                    p.isPresent, p.timed, p.expEff = false, false, 0
                elseif i == n - 1 and n > 2 then
                    p.isPresent, p.timed, p.expEff = true, false, 0
                else
                    local db = self:Cfg()
                    local base = (db.warnAt or 30) * (i == 1 and 4 or (i == 2 and 0.8 or 0.2))
                    p.isPresent, p.timed, p.expEff = true, true, now + math_max(2, base)
                end
                rows[i] = p
            end
            for i = n + 1, #rows do rows[i] = nil end
        end

        function T:BuildRows(now)
            local rows = self.rows
            wipe(rows)
            if RC._uiMoverActive or self.isSample then
                self:BuildPreviewRows(now)
                return
            end
            local db = self:Cfg()
            -- "Missing only" hides auras that are up; with showExpiring one
            -- comes back once it is inside the first warning time.
            local hidePresent = db.hidePresent
            local showMissing = db.showMissing or hidePresent
            local expiringAt = (hidePresent and db.showExpiring ~= false) and (db.warnAt or 0) or 0
            for _, e in ipairs(self.entries) do
                local rt = self.rt[e.id]
                if rt then
                    local show
                    if rt.isPresent then
                        show = (not hidePresent)
                            or (expiringAt > 0 and rt.timed and (rt.expEff - now) <= expiringAt)
                    else
                        show = showMissing
                    end
                    if show then rows[#rows + 1] = rt end
                end
            end
            if spec.sortByRemaining then
                table_sort(rows, SortRows)
            end
        end

        local sigParts = {}
        function T:Render(now)
            local frame = self.frame
            if not frame then return end
            local db = self:Cfg()
            if db.alertMode == "tts" and not RC._uiMoverActive and not self.isSample then
                self:HideNow()
                return
            end
            self:BuildRows(now)
            local rows = self.rows
            ArrangeRows(db, rows)
            if #rows == 0 then
                if self.isSample then frame:Hide() else self:HideAnimated() end
                return
            end

            for i = 1, #rows do sigParts[i] = rows[i].entry.id end
            for i = #rows + 1, #sigParts do sigParts[i] = nil end
            local compact = self:IsCompact()
            local sig = table_concat(sigParts, "|") .. (RC._uiMoverActive and "#p" or "")
                .. (compact and "#c" or "#l")
            if sig ~= self.layoutSig then
                self.layoutSig = sig
                self:Layout(rows)
            end

            local missingTxt = compact and "X" or RCL["MISSING"]
            local warnAt, warnAt2 = db.warnAt or 0, db.warnAt2 or 0
            local cc = type(db.colors) == "table" and db.colors or {}
            local urgentAnim = (not self.isSample) and db.urgentAnim or nil
            -- a look per state (db.states.normal / .warning / .urgent: text
            -- colour, icon tint, grey, opacity); unset = the colours above
            local states = type(db.states) == "table" and db.states or nil
            for i = 1, #rows do
                local rt, row = rows[i], frame.rows[i]
                local bucket, txt
                if not rt.isPresent then
                    bucket, txt = 3, missingTxt
                elseif rt.timed then
                    local rem = math_max(0, rt.expEff - now)
                    txt = TimeText(db, rem, FormatShort)
                    if warnAt2 > 0 and rem <= warnAt2 then bucket = 3
                    elseif warnAt > 0 and rem <= warnAt then bucket = 2
                    else bucket = 1 end
                else
                    bucket, txt = 1, "\226\128\148"
                end
                row.time:SetText(txt)
                local restate = false
                if row._stOf ~= states then
                    -- the state looks changed (or went): paint everything again
                    row._stOf, row.bucket, row.presentFlag, restate = states, nil, nil, true
                end
                if row.bucket ~= bucket then
                    row.bucket = bucket
                    restate = true
                    local c
                    if bucket == 3 then c = cc.urgent or RC:GetColor("text", "red")
                    elseif bucket == 2 then c = cc.warning or RC:GetColor("text", "warning")
                    else c = cc.normal or RC:GetColor("text", "normal") end
                    local tc = states and RC.UI:StateValue(states, AT_STATE_OF[bucket], "textColor")
                    if type(tc) == "table" then c = tc end
                    row.time:SetTextColor(c.r, c.g, c.b, c.a or 1)
                    row.label:SetTextColor(c.r, c.g, c.b, c.a or 1)
                end
                -- once per aura each time it turns urgent or goes missing
                if bucket == 3 then
                    if not rt.urgentSeen then
                        rt.urgentSeen = true
                        local snd = (not self.isSample) and type(db.sounds) == "table" and db.sounds.urgent or nil
                        if snd then RC.UI:PlaySoundSpec(snd, nil, self.key .. ":urgent") end
                        if urgentAnim and frame:IsShown() then RC.Motion.Play(row, urgentAnim, "update") end
                    end
                else
                    rt.urgentSeen = nil
                end
                local pres = rt.isPresent and true or false
                if row.presentFlag ~= pres then
                    row.presentFlag = pres
                    row.icon:SetDesaturated(not pres)
                    row.icon:SetAlpha(pres and 1 or 0.5)
                    restate = true
                end
                if restate and (states or row._stOn) then
                    row._stOn = states ~= nil
                    local name = AT_STATE_OF[bucket]
                    local ds = states and RC.UI:StateValue(states, name, "desat")
                    if ds ~= nil then row.icon:SetDesaturated(ds and true or false) else row.icon:SetDesaturated(not pres) end
                    local ic = states and RC.UI:StateValue(states, name, "color")
                    if type(ic) == "table" then row.icon:SetVertexColor(RC.UI:ColorOf(ic))
                    else row.icon:SetVertexColor(1, 1, 1, 1) end
                    local al = states and tonumber(RC.UI:StateValue(states, name, "alpha")) or 1
                    if row._stAlpha ~= al then
                        row._stAlpha = al
                        if not (RC.Motion and RC.Motion.IsPlaying and RC.Motion.IsPlaying(row)) then row:SetAlpha(al) end
                    end
                end
                local icon = rt.icon or rt.entry.icon
                if row.iconPath ~= icon then
                    row.iconPath = icon
                    row.icon:SetTexture(icon)
                end
                if rt.entry.stacks and rt.isPresent and (rt.count or 0) > 1 then
                    if row.countVal ~= rt.count then
                        row.countVal = rt.count
                        row.count:SetText(rt.count)
                    end
                    row.count:Show()
                else
                    row.countVal = nil
                    row.count:Hide()
                end
            end
            if self.isSample then frame:Show() return end
            if not frame:IsShown() or self.leaving then
                self.leaving = nil
                if not RC.Motion.Show(frame, db.showAnim or NO_MOTION) then frame:Show() end
            end
        end

        -- Animated exit when the list empties (hideAnim); every other way
        -- off (stopped, gate closed, voice only) is instant.
        function T:HideAnimated()
            local frame = self.frame
            if not frame or not frame:IsShown() or self.leaving then return end
            self.leaving = true
            local me = self
            RC.Motion.Hide(frame, self:Cfg().hideAnim or NO_MOTION, function() me.leaving = nil end)
            if not frame:IsShown() then self.leaving = nil end
        end
        function T:HideNow()
            local frame = self.frame
            if not frame then return end
            self.leaving = nil
            RC.Motion.Stop(frame)
            frame:Hide()
        end

        --------------------------------------------------------------
        -- Ticker
        --------------------------------------------------------------
        function T:Tick()
            if not self:ShouldRun() then
                self:Stop()
                return
            end
            local now = GetTime()
            local gate = self:GateOK()
            if spec.unit == "target" then
                local g = gate and UnitGUID("target") or nil
                if g ~= self.targetGUID then self:SetTargetGUID(g) end
                self:ArmCLEU(gate)
            end
            if not gate then
                self:HideNow()
                self.gateWasOff = true
                -- Whatever was owed belonged to a fight or a target that
                -- is over.
                if next(self.whisperPending) then wipe(self.whisperPending) end
                return
            end
            if self.dirty or self.gateWasOff or (now - self.lastScan) >= SCAN_EVERY then
                self.dirty = false
                self.gateWasOff = nil
                self.lastScan = now
                if RC.Profiler then RC.Profiler:StartTiming(spec.profKey) end
                self:Scan()
                self:Evaluate(now)
                if RC.Profiler then RC.Profiler:StopTiming(spec.profKey) end
            end
            if next(self.whisperPending) then self:FlushWhispers(now) end
            self:Render(now)
        end

        function T:Start()
            if self.ticker then return end
            if not self:ShouldRun() then return end
            if not self.frame then self:CreateFrame() end
            local me = self
            self.ticker = RC.Profiler:TrackTicker(spec.tickerName, TICK, function() me:Tick() end)
            self.dirty = true
            self.layoutSig = nil
            self:Tick()
            RC:DebugPrint(spec.debugName .. " started", "buff")
        end

        function T:Stop()
            if self.ticker then
                self.ticker:Cancel()
                self.ticker = nil
                RC:DebugPrint(spec.debugName .. " stopped", "buff")
            end
            self:ArmCLEU(false)
            self:HideNow()
        end

        -- Recompute shown/hidden from scratch (QueueVisibilityCheck target).
        function T:Reevaluate()
            if self:ShouldRun() then
                self:Start()
            else
                self:Stop()
            end
        end

        -- Settings-page entry point after any change.
        function T:Refresh()
            self:InitDB()
            self:RebuildEntries()
            self:ApplyAppearance()
            self:Reevaluate()
            if self.ticker then
                self.dirty = true
                self:Tick()
            end
        end

        --------------------------------------------------------------
        -- Events
        --------------------------------------------------------------
        local ev = CreateFrame("Frame")
        T.eventFrame = ev
        if ev.RegisterUnitEvent then
            ev:RegisterUnitEvent("UNIT_AURA", spec.unit)
        else
            ev:RegisterEvent("UNIT_AURA")
        end
        ev:RegisterEvent("PLAYER_ENTERING_WORLD")
        ev:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        ev:RegisterEvent("PLAYER_UPDATE_RESTING")
        ev:RegisterEvent("GROUP_ROSTER_UPDATE")
        ev:RegisterEvent("PLAYER_REGEN_ENABLED")
        ev:RegisterEvent("PLAYER_REGEN_DISABLED")
        if spec.unit == "target" then
            ev:RegisterEvent("PLAYER_TARGET_CHANGED")
        end
        ev:SetScript("OnEvent", function(_, event, arg1)
            if event == "UNIT_AURA" then
                if arg1 == spec.unit then T.dirty = true end
                return
            end
            if event == "COMBAT_LOG_EVENT_UNFILTERED" then
                T:OnCLEU()
                return
            end
            if event == "PLAYER_TARGET_CHANGED" then
                T.dirty = true
                T:SetTargetGUID(UnitExists("target") and UnitGUID("target") or nil)
                return
            end
            if event == "PLAYER_REGEN_ENABLED" or event == "PLAYER_REGEN_DISABLED" then
                T.dirty = true
                return
            end
            if not RC.db or not RC.db[spec.key] then return end
            RC:QueueVisibilityCheck(T.state, spec.visMethod, event == "PLAYER_ENTERING_WORLD")
        end)

        T:InitDB()
        T:RebuildEntries()
        T:CreateFrame()
        AT.trackers[spec.key] = T
        return T
    end

    ------------------------------------------------------------------
    -- Instances
    ------------------------------------------------------------------
    local COMMON_APPEARANCE = {
        locked = true, scale = 1.0, opacity = 0.85, fontSize = 11, rowWidth = 180,
        iconSize = 16, growDown = true, alertMode = "both",
        -- Whisper reminders: off, 2 minutes between repeats of one aura
        -- to one person, and no per-aura choices made yet.
        whisperCaster = false, whisperCooldown = 120, whisperFor = {},
        -- "list" = icon + name + time rows; "compact" = icon cells with the
        -- time under each, compactPerRow to a line. The compact grid has
        -- its own icon size so switching layouts does not shrink the list.
        layout = "list", compactPerRow = 8, compactIconSize = 32,
        showBackground = true, spacing = 0, compactSpacing = 2, growLeft = false,
        compactDirection = "RIGHT",
    }
    local function WithCommon(t)
        for k, v in pairs(COMMON_APPEARANCE) do
            if t[k] == nil then t[k] = v end
        end
        return t
    end

    local buffTracker = NewTracker({
        key         = "raidBuffTracker",
        unit        = "player",
        filter      = "HELPFUL",
        frameName   = "WRRaidBuffTrackerFrame",
        title       = RCL["Raid Buffs"],
        debugName   = "RaidBuffTracker",
        tickerName  = "AuraTracker:RaidBuffs",
        profKey     = "RaidBuffTracker",
        visMethod   = "UpdateRaidBuffTrackerVisibility",
        sortByRemaining = true,
        defaultPos  = { x = 260, y = 140 },
        catalog     = RAID_BUFF_CATALOG,
        defaults    = WithCommon({
            enabled        = false,
            visibilityMode = "raids",
            showMissing    = false,
            hidePresent    = false,
            showExpiring   = true,
            warnAt         = 300,
            warnAt2        = 60,
            ttsMissing     = false,
            ttsCooldown    = 30,
            onlyInCombat   = false,
            tracked        = RAID_BUFF_DEFAULT_TRACKED,
            custom         = {},
        }),
    })

    -- your target's debuffs: Forever hides them from addons in combat, so
    -- the tracker is not built there (Core_Flavor)
    local debuffTracker = RC:FeatureOn("boss_debuff_tracker") and NewTracker({
        key         = "bossDebuffTracker",
        unit        = "target",
        filter      = "HARMFUL",
        frameName   = "WRBossDebuffTrackerFrame",
        title       = RCL["Boss Debuffs"],
        debugName   = "BossDebuffTracker",
        tickerName  = "AuraTracker:BossDebuffs",
        profKey     = "BossDebuffTracker",
        visMethod   = "UpdateBossDebuffTrackerVisibility",
        sortByRemaining = false,
        defaultPos  = { x = 260, y = 20 },
        catalog     = BOSS_DEBUFF_CATALOG,
        defaults    = WithCommon({
            enabled        = false,
            visibilityMode = "raids",
            showMissing    = true,
            hidePresent    = false,
            showExpiring   = true,
            warnAt         = 10,
            warnAt2        = 3,
            ttsMissing     = true,
            ttsCooldown    = 20,
            onlyInCombat   = true,
            bossesOnly     = true,
            tracked        = BOSS_DEBUFF_DEFAULT_TRACKED,
            custom         = {},
        }),
    }) or nil

    AT.RAID_BUFF_CATALOG   = RAID_BUFF_CATALOG
    AT.BOSS_DEBUFF_CATALOG = BOSS_DEBUFF_CATALOG

    function RC:GetAuraTracker(key)
        return AT.trackers[key]
    end

    -- QueueVisibilityCheck targets (must recompute from scratch).
    function RC:UpdateRaidBuffTrackerVisibility()
        buffTracker:Reevaluate()
    end
    function RC:UpdateBossDebuffTrackerVisibility()
        if debuffTracker then debuffTracker:Reevaluate() end
    end

    -- Settings pages call these after any change.
    function RC:RefreshRaidBuffTracker()
        buffTracker:Refresh()
    end
    function RC:RefreshBossDebuffTracker()
        if debuffTracker then debuffTracker:Refresh() end
    end

    C_Timer.After(1.2, function()
        buffTracker:Reevaluate()
        if debuffTracker then debuffTracker:Reevaluate() end
    end)

    RC:DebugPrint("AuraTracker module loaded", "system")
end

C_Timer.After(0.5, InitializeAuraTracker)
