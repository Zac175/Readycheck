------------------------------------------------------------------------
-- Readycheck - Game flavor: Classic Era, TBC Anniversary, WoW Forever
-- RC:Flavor() says which client this is: "era", "tbc" or "forever".
-- RC.FEATURE_FLAVORS lists every feature that does not run on all three,
-- with the plain reason; a feature asks RC:FeatureOn(id) before it
-- registers its events, tickers or frames. Anything not listed runs
-- everywhere, and on Classic Era every feature is on.
--
-- DEVELOPER OVERRIDE. db.flavor.override (nil = this client, or a flavor), set from
-- Readycheck_Testing or /rc flavor, is read once per session, so a change
-- lands after /reload. It only decides which features Readycheck switches
-- off; it never pretends an API is there or missing (Core_Forever does
-- that, on the real client only).
--
-- The flavor is fixed the first time it is read after the saved
-- variables exist (the companions load from Core_Runtime's ADDON_LOADED,
-- so they all see the same answer). Read before that, it is the real
-- client's flavor and nothing is fixed yet.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local pairs, ipairs, type, tostring, select = pairs, ipairs, type, tostring, select

local VALID = { era = true, tbc = true, forever = true }
local ORDER = { "era", "tbc", "forever" }
RC.FLAVORS = ORDER
RC.FLAVOR_NAMES = { era = RCL["Classic Era"], tbc = RCL["TBC"], forever = RCL["Forever"] }

-- WOW_PROJECT_ID first (2 Classic Era, 5 TBC Anniversary, 18 WoW Forever),
-- then the interface number for a client that reports something else.
function RC:DetectFlavor()
    local pid = WOW_PROJECT_ID
    if pid == 2 then return "era" end
    if pid == 5 then return "tbc" end
    if pid == 18 then return "forever" end
    local build = (GetBuildInfo and select(4, GetBuildInfo())) or 0
    if build >= 16000 and build < 20000 then return "forever" end
    if build >= 20000 and build < 30000 then return "tbc" end
    return "era"
end

-- The saved override for this character, and whether the saved
-- variables were there to read it from.
local function ReadOverride()
    local db = RC.db
    if type(db) ~= "table" then
        local chars = type(ReadycheckDB) == "table" and ReadycheckDB.characters
        if type(chars) ~= "table" then
            return nil, type(ReadycheckDB) == "table"
        end
        if not RC.GetCharacterKey then return nil, false end
        local ok, key = pcall(RC.GetCharacterKey, RC)
        if not ok or not key then return nil, false end
        db = chars[key]
    end
    local v = type(db) == "table" and type(db.flavor) == "table" and db.flavor.override or nil
    if VALID[v] then return v, true end
    return nil, true
end

local latched, simulated, realFlavor

function RC:Flavor()
    if latched then return latched end
    local real = self:DetectFlavor()
    local ov, ready = ReadOverride()
    if not ready then return real end
    realFlavor = real
    if ov and ov ~= real then
        latched, simulated = ov, true
    else
        latched, simulated = real, false
    end
    return latched
end

function RC:RealFlavor()
    return realFlavor or self:DetectFlavor()
end

function RC:IsSimulatedFlavor()
    self:Flavor()
    return simulated and true or false
end

function RC:FlavorName(flavor)
    flavor = flavor or self:Flavor()
    return self.FLAVOR_NAMES[flavor] or tostring(flavor)
end

-- What /reload will bring: the saved choice, or the real client on auto.
function RC:PendingFlavor()
    local ov = ReadOverride()
    return ov or self:RealFlavor()
end

-- value: "auto", "era", "tbc" or "forever". Returns true when it changes
-- what the next /reload runs as.
function RC:SetFlavorOverride(value)
    if value ~= "auto" and not VALID[value] then return false end
    if type(self.db) ~= "table" then return false end
    if type(self.db.flavor) ~= "table" then self.db.flavor = {} end
    self.db.flavor.override = (value ~= "auto") and value or nil
    if self.SaveConfigurationToProfile then pcall(self.SaveConfigurationToProfile, self) end
    return self:PendingFlavor() ~= self:Flavor()
end

------------------------------------------------------------------------
-- The feature table. off[flavor] = the plain reason it does not run
-- there, and kind[flavor] = which kind of "off" that is:
--   not_needed  the game version does not have the problem it solves
--               (Forever and TBC have no buff limit to push buffs off)
--   not_there   the content it is for is not on that version (Naxxramas
--               on TBC, raids Forever has not opened yet)
--   cant        the game keeps from addons what it needs there (Forever's
--               hidden values, no combat log, blocked addon messages)
-- Whatever the kind, a switched-off feature does not load there: no
-- frames, events, tickers, settings pages, options, search hits, stats
-- bar cells or slash commands. Only /rc flavor and the Game version page
-- list it, with its kind and reason. Saved settings are never touched.
-- pages: sidebar ids hidden there. addon: a companion that is not loaded
-- at all. stubs: methods the rest of the addon calls that go quiet.
-- cmds: /rc sub-commands that are not there; slash: standalone slash
-- commands (SlashCmdList keys) taken away there.
------------------------------------------------------------------------
-- world buffs. TBC: patch 2.1 stops the Classic Era ones above level 63
-- (warcraft.wiki.gg). Forever: "world buffs are removed inside dungeons
-- and raids" (warcraft.wiki.gg, World of Warcraft: Forever).
local WB_TBC  = RCL["Classic Era world buffs stop working above level 63 on TBC"]
local WB_FOREVER = RCL["Forever removes world buffs inside dungeons and raids, so there is nothing to time or keep for a raid"]
-- Forever's raids (Barrow Deeps, Hyjal Summit, Onyxia's Lair) open on
-- 9 December 2026 (warcraft.wiki.gg); RC:ApplyRaidFlavor drops these once
-- Forever's list is filled in
local RAIDS_LATER = { forever = RCL["Forever's raids open on 9 December and aren't in Readycheck yet"] }
local RAIDS_LATER_KIND = { forever = "not_there" }
local HEALTH  = RCL["Forever hides enemy health from addons in combat"]
local DEBUFFS = RCL["Forever hides enemy debuffs from addons in combat"]
local MSG     = RCL["Forever blocks addon messages inside instances; sync waits until you leave"]
local CANT    = { forever = "cant" }

RC.FEATURE_FLAVORS = {
    -- World buffs. The World Tools companion loads wherever either row
    -- runs; its world buff parts stand down where world_tools is off.
    { id = "world_tools", name = RCL["World buffs: drop timers, timer network, buff board, summons on a fresh world buff, gossip and turn-ins"],
      off = { tbc = WB_TBC, forever = WB_FOREVER },
      kind = { tbc = "not_there", forever = "not_needed" },
      addon = "Readycheck_WorldTools",
      pages = { "wt_pulltimers", "wt_buffnetwork", "wt_wbdrops", "world_buffs" },
      cmds = { "wb", "worldbuffs", "worldbuff", "crossfaction", "xfaction", "xfpeer", "xfpeerclear",
               "wbclearremovals", "wbclear", "wbself" },
      slash = { "READYCHECKWB" } },
    { id = "world_summons", name = RCL["Auto-accept summons (always, or after a taxi PvP drop)"],
      off = { forever = RCL["whether Forever lets an addon accept a summon is unconfirmed"] }, kind = CANT,
      addon = "Readycheck_WorldTools", pages = { "world_tools", "wt_automation" } },
    { id = "chronoboon", name = RCL["Chronoboon reminder"],
      off = { tbc = RCL["Classic Era world buffs stop working above level 63 on TBC, so there are none to store"],
              forever = RCL["Forever removes world buffs inside dungeons and raids, so there is nothing to keep for a raid"] },
      kind = { tbc = "not_there", forever = "not_needed" },
      pages = { "boon_reminder" } },
    { id = "raid_configs", name = RCL["Raid boss and trash configs (each game version's raids) and their ability reminders"],
      off = RAIDS_LATER, kind = RAIDS_LATER_KIND, raidList = true,
      pages = { "raids", "mc", "bwl", "aq40", "naxx", "remote_raid_cfg" },
      cmds = { "sim", "simulate", "stopsim", "gearsim", "encounter", "raidprofdump" } },
    { id = "boss_notes", name = RCL["Boss and trash notes"], off = RAIDS_LATER, kind = RAIDS_LATER_KIND, raidList = true,
      pages = { "boss_notes" }, cmds = { "notesdump", "notesadopt" } },
    { id = "polarity", name = RCL["Polarity mode (Thaddius, Sapphiron)"],
      off = { tbc = RCL["Thaddius and Sapphiron are in Classic Era's Naxxramas, which TBC does not have"],
              forever = RCL["Thaddius and Sapphiron are in Classic Era's Naxxramas, which isn't on Forever"] },
      kind = { tbc = "not_there", forever = "not_there" }, cmds = { "polarity" } },
    -- counts trash kills from the combat log: off on Forever for good
    { id = "raid_route", name = RCL["Raid route (per-pull steps, gear sets, trinkets, reminders)"],
      off = { forever = RCL["the kill steps need the combat log, which Forever does not give addons (and Forever's raids open on 9 December)"] },
      kind = CANT, cmds = { "routever", "routedebug" } },
    { id = "boss_gear_target", name = RCL["Boss gear set when you target the boss"], off = RAIDS_LATER, kind = RAIDS_LATER_KIND, raidList = true },
    { id = "boss_gear_kill", name = RCL["Boss gear set after the kill"], off = RAIDS_LATER, kind = RAIDS_LATER_KIND, raidList = true },
    { id = "boss_gear_prompt", name = RCL["Ask which gear set to wear after a kill"], off = RAIDS_LATER, kind = RAIDS_LATER_KIND, raidList = true },
    -- Classic Era's limit is 32. Zac: TBC and Forever have no buff limit
    -- you reach, so nothing is pushed off there and there is nothing to
    -- count, measure or warn about (saved measurements stay as they are).
    { id = "buff_pushoff", name = RCL["Buff pushoff alert, Buffs cell (buff slot counter), buff limit measuring and Darkmoon fortune watch"],
      off = { tbc = RCL["TBC has no buff limit you'll hit, so nothing is ever pushed off"],
              forever = RCL["Forever has no buff limit, so nothing is ever pushed off"] },
      kind = { tbc = "not_needed", forever = "not_needed" },
      pages = { "buff_pushoff" } },
    -- Built on the combat log, or on values Forever hides in combat
    { id = "kill_watch", name = RCL["Trash kill counting (route steps, trash notes, Thaddius)"],
      off = { forever = RCL["needs the combat log; Forever's death event (UNIT_DIED) hides which mob died"] }, kind = CANT },
    -- the glow in Battle Stance comes from Overpower being usable and runs
    -- everywhere; only the dodge seen while out of Battle Stance is off
    { id = "overpower_dodge", name = RCL["Overpower glow after a dodge while out of Battle Stance (nameplates)"],
      off = { forever = RCL["needs the combat log to see your own attack dodged; UNIT_COMBAT does not say whose attack it was"] }, kind = CANT },
    { id = "ttk", name = RCL["TTK display and ML kill-time predictions"], off = { forever = HEALTH }, kind = CANT,
      pages = { "combat", "execute", "ttk_display" },
      cmds = { "ttk", "fixttk", "fixhistory", "dmfdump" },
      stubs = { "OnExecuteCombatStart", "OnExecuteCombatEnd", "OnExecuteTargetChanged",
                "OnExecuteBossKilledByEncounterEnd", "PredictTTK", "CheckExecutePhase",
                "StartFightTracking", "EndFightTracking", "RecordFightKill",
                "ScanForBossOnCombatStart", "HandleBossUnitEvent", "UpdateEncounterUnits",
                "ScanRaidForBoss", "UpdateTTKDisplayActive", "CalculateTimeToKill" } },
    { id = "boss_debuff_tracker", name = RCL["Boss debuff tracker"], off = { forever = DEBUFFS }, kind = CANT,
      pages = { "boss_debuff_tracker" } },
    -- Addon messages
    { id = "mesh_in_instance", name = RCL["Mesh sync, version check and gold sync inside instances"], off = { forever = MSG }, kind = CANT },
    -- Forever's Battle Shout reaches every raid member within 20 yards
    -- (and gives less attack power), so a list of who in your party has
    -- your shout, with its AP and shout-gear maths, has nothing to do
    -- there. The reminder itself runs everywhere (battle_shout below).
    { id = "battle_shout_party", name = RCL["Battle Shout party tracker"],
      off = { forever = RCL["Battle Shout reaches the whole raid within 20 yards on Forever; the raid buff tracker shows who has it"] },
      kind = { forever = "not_needed" } },

    -- On everywhere (listed so the table covers every module)
    { id = "reminder_popup", name = RCL["Reminder popup, sounds and text-to-speech"] },
    { id = "battle_shout", name = RCL["Battle Shout reminder"] },
    { id = "custom_reminders", name = RCL["Custom reminders"] },
    { id = "equipment_reminder", name = RCL["Equipment reminder (weapons, shield, enchants)"] },
    { id = "raid_buff_tracker", name = RCL["Raid buff tracker"] },
    { id = "consumable_bars", name = RCL["Consumables, potions and weapons bars, trinket menu (each game version's own items)"] },
    { id = "consumables_checker", name = RCL["Consumables checker and must-have item alert (each game version's own items; the raid-entry check needs the Classic Era raids)"] },
    { id = "raid_consume_reminders", name = RCL["Raid consume reminders (each game version's own items)"],
      pages = { "consumeremind" } },
    { id = "gear_manager", name = RCL["Gear Manager sets, buttons and /rc gearset"] },
    { id = "trinket_swap", name = RCL["Trinket Manager (trinket rotation)"] },
    { id = "speed_swaps", name = RCL["On-use gear swaps and swap back"] },
    { id = "hotswap", name = RCL["Hotswap macros and /rc equip"] },
    { id = "repair_reminder", name = RCL["Repair reminder"] },
    { id = "trinket_scanner", name = RCL["Trinket scanner"] },
    { id = "smart_macros", name = RCL["Smart macros"] },
    { id = "nameplates", name = RCL["Nameplate debuffs, execute glow and view distance (on Forever, enemy debuffs and health do not show in combat)"] },
    { id = "stats_bar", name = RCL["Stats bar and character stats"] },
    { id = "spec_detection", name = RCL["Spec detection"] },
    { id = "mesh", name = RCL["Mesh network, remote settings, version check and gold ledger (outside instances on Forever)"] },
    { id = "settings", name = RCL["Settings window, appearance, profiles, import / export, minimap button, frame mover"] },
    { id = "debug", name = RCL["Profiler and debug tools (Readycheck_Debug)"] },
    { id = "extras", name = RCL["Setup wizard, tour and changelog (Readycheck_Extras)"] },
    { id = "testing", name = RCL["Testing tools: decision log, game version (Readycheck_Testing)"] },
}

local BY_ID, BY_PAGE, BY_ADDON, BY_CMD = {}, {}, {}, {}
for _, f in ipairs(RC.FEATURE_FLAVORS) do
    BY_ID[f.id] = f
    for _, p in ipairs(f.pages or {}) do BY_PAGE[p] = f end
    for _, c in ipairs(f.cmds or {}) do BY_CMD[c] = f end
    if f.addon then
        BY_ADDON[f.addon] = BY_ADDON[f.addon] or {}
        table.insert(BY_ADDON[f.addon], f)
    end
end

-- True when the feature runs on this flavor (and for any id not listed).
function RC:FeatureOn(id)
    local f = BY_ID[id]
    if not (f and f.off) then return true end
    return f.off[self:Flavor()] == nil
end

function RC:FeatureOffReason(id)
    local f = BY_ID[id]
    return f and f.off and f.off[self:Flavor()] or nil
end

-- The three kinds of "off" (see the table above), as /rc flavor and the
-- Game version page name them.
RC.FLAVOR_KINDS = { "not_needed", "not_there", "cant" }
RC.FLAVOR_KIND_NAMES = { not_needed = RCL["not needed"], not_there = RCL["not there"], cant = RCL["can't"] }

-- "not_needed" | "not_there" | "cant" for a feature off on a flavor (this
-- one by default), nil where it runs. A row with no kind reads as "cant".
function RC:FeatureOffKind(id, flavor)
    local f = BY_ID[id]
    flavor = flavor or self:Flavor()
    if not (f and f.off and f.off[flavor]) then return nil end
    return (f.kind and f.kind[flavor]) or "cant"
end

function RC:FlavorKindName(kind)
    return self.FLAVOR_KIND_NAMES[kind] or tostring(kind)
end

-- "Not needed on Forever: ...", "Not on TBC: ..." or "Can't run on
-- Forever: ...", plus "(simulated)" under the override.
local NOTE_FORMAT = { not_needed = RCL["Not needed on %s: %s"], not_there = RCL["Not on %s: %s"],
                      cant = RCL["Can't run on %s: %s"] }
function RC:FeatureOffNote(id)
    local why = self:FeatureOffReason(id)
    if not why then return nil end
    local fmt = NOTE_FORMAT[self:FeatureOffKind(id)] or NOTE_FORMAT.cant
    local note = string.format(fmt, self:FlavorName(), why)
    if self:IsSimulatedFlavor() then note = note .. " " .. RCL["(simulated)"] end
    return note
end

-- A /rc sub-command of a feature this version does not run: the switched
-- off feature's id, or nil. The dispatcher treats it as unknown.
function RC:CommandOffByFlavor(cmd)
    local f = cmd and BY_CMD[cmd]
    if f and not self:FeatureOn(f.id) then return f.id end
    return nil
end

-- The switched-off feature behind a sidebar entry, or nil.
function RC:FeatureOffForPage(menuItem)
    if type(menuItem) ~= "table" then return nil end
    local f = menuItem.id and BY_PAGE[menuItem.id]
    if f and not self:FeatureOn(f.id) then return f.id end
    return nil
end

-- A search alias's keywords on this flavor (RC.SUBPANEL_ALIASES): the
-- words a row names in featureWords[featureId] are left out where that
-- feature is off, so a tab is not found by a part this version does not
-- run. Where nothing is off it is the alias's own list, unchanged.
function RC:AliasKeywords(sub)
    local words = type(sub) == "table" and sub.keywords or {}
    local fw = type(sub) == "table" and sub.featureWords
    if type(fw) ~= "table" then return words end
    local drop
    for id, list in pairs(fw) do
        if not self:FeatureOn(id) then
            drop = drop or {}
            for _, w in ipairs(list) do drop[w] = true end
        end
    end
    if not drop then return words end
    local out = {}
    for _, w in ipairs(words) do
        if not drop[w] then out[#out + 1] = w end
    end
    return out
end

-- A companion addon that this flavor does not load at all: every row
-- that runs in it is off.
function RC:AddonOffByFlavor(addonName)
    local rows = BY_ADDON[addonName]
    if not rows then return false end
    for _, f in ipairs(rows) do
        if self:FeatureOn(f.id) then return false end
    end
    return true
end

-- Every switched-off feature on a flavor (this one by default), in table
-- order: { { id =, name =, reason =, kind = }, ... }.
function RC:FeaturesOff(flavor)
    flavor = flavor or self:Flavor()
    local out = {}
    for _, f in ipairs(self.FEATURE_FLAVORS) do
        local why = f.off and f.off[flavor]
        if why then
            out[#out + 1] = { id = f.id, name = f.name, reason = why,
                              kind = (f.kind and f.kind[flavor]) or "cant" }
        end
    end
    return out
end

-- Run once the companions are in (Core_Runtime): the methods of a
-- switched-off feature that the rest of the addon calls go quiet, and the
-- ones a player reaches say why.
function RC:ApplyFlavorStubs()
    local function Noop() end
    for _, f in ipairs(self.FEATURE_FLAVORS) do
        if not self:FeatureOn(f.id) then
            for _, name in ipairs(f.stubs or {}) do self[name] = Noop end
            for _, key in ipairs(f.slash or {}) do
                if SlashCmdList then SlashCmdList[key] = nil end
                for i = 1, 3 do _G["SLASH_" .. key .. i] = nil end
            end
            local id = f.id
            for _, name in ipairs(f.talk or {}) do
                self[name] = function(me)
                    local note = me:FeatureOffNote(id)
                    if note then me:Print(note) end
                end
            end
        end
    end
end

-- A companion that is not loaded leaves no sidebar group behind, and
-- that is how it stays: a feature this version does not run has no page
-- (only /rc flavor and the Game version page list it). Kept as a no-op
-- for its caller (Core_Runtime).
function RC:AddFlavorMenuStubs() end

-- A stand-in for a frame a switched-off feature would make at load: every
-- method is there and does nothing, so its file runs unchanged and no
-- frame exists on that version. (Only for code that runs after the game
-- version is fixed: the companions, never the main addon's own files.)
do
    local function Noop() end
    RC.FlavorNullFrame = setmetatable({}, { __index = function() return Noop end })
end

-- Addon messages: Forever does not deliver them inside an instance, so
-- the senders hold or skip them there.
function RC:AddonMessagesBlocked()
    if self:FeatureOn("mesh_in_instance") then return false end
    local inInstance = IsInInstance and IsInInstance()
    return inInstance and true or false
end

------------------------------------------------------------------------
-- Secret values (WoW Forever, in combat). They may not be compared, used
-- in arithmetic or used as a table key; on the other clients the test is
-- always false.
------------------------------------------------------------------------
local issecret = issecretvalue
function RC.IsSecret(v)
    if issecret == nil then return false end
    return issecret(v) and true or false
end

-- UnitHealth / UnitHealthMax, or nil, nil when either is hidden.
function RC:SafeHealth(unit)
    local hp, mx = UnitHealth(unit), UnitHealthMax(unit)
    if issecret ~= nil and (issecret(hp) or issecret(mx)) then return nil, nil end
    return hp, mx
end

------------------------------------------------------------------------
-- /rc flavor [era|tbc|forever|auto]
------------------------------------------------------------------------
function RC:FlavorCommand(arg)
    arg = arg and arg:lower() or ""
    if arg == "era" or arg == "tbc" or arg == "forever" or arg == "auto" then
        if type(self.db) ~= "table" then
            self:Print(RCL["Settings are not loaded yet - try again in a moment."])
            return
        end
        local changes = self:SetFlavorOverride(arg)
        local target = self:FlavorName(self:PendingFlavor())
        if changes then
            self:Print(string.format(RCL["Flavor set to %s. Type /reload to apply it."], target))
        else
            self:Print(string.format(RCL["Flavor set to %s - already running as that."], target))
        end
        return
    elseif arg ~= "" then
        self:Print(RCL["Usage: /rc flavor [era|tbc|forever|auto]"])
        return
    end

    local cur = self:Flavor()
    local line = string.format(RCL["Flavor: %s"], self:FlavorName(cur))
    if self:IsSimulatedFlavor() then
        line = line .. " " .. string.format(RCL["(simulated - this client is %s)"], self:FlavorName(self:RealFlavor()))
    end
    self:Print(line)
    local pending = self:PendingFlavor()
    if pending ~= cur then
        self:Print(string.format(RCL["After /reload: %s"], self:FlavorName(pending)))
    end
    if self._consumableFlavorApplied then
        self:Print(string.format(RCL["Consumables: the %s list (bars, checker, must-have alert, previews)"], self:FlavorName(cur)))
    end
    if self._raidFlavorApplied then
        self:Print(string.format(RCL["Raids: the %s raids (%d) in the raid configs, boss notes, gear swaps and route"],
            self:FlavorName(cur), #self:FlavorRaids()))
    end
    local off = self:FeaturesOff(cur)
    if #off == 0 then
        self:Print(RCL["Every feature is on."])
    else
        self:Print(string.format(RCL["Switched off on %s (not loaded at all):"], self:FlavorName(cur)))
        for _, f in ipairs(off) do
            self:Print("  " .. f.name .. " [" .. self:FlavorKindName(f.kind) .. "]: " .. f.reason)
        end
    end
end
