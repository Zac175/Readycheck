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
-- there. pages: sidebar ids that show the reason instead of the page.
-- addon: a companion that is not loaded at all. stubs: methods the rest
-- of the addon calls that go quiet; talk: ones a player types or clicks,
-- which say why instead.
------------------------------------------------------------------------
local ERA     = RCL["Classic Era content"]
local CLOG    = RCL["needs the combat log, which Forever does not give addons"]
local HEALTH  = RCL["Forever hides enemy health from addons in combat"]
local DEBUFFS = RCL["Forever hides enemy debuffs from addons in combat"]
local MSG     = RCL["Forever blocks addon messages inside instances; sync waits until you leave"]
local ERA_ONLY = { tbc = ERA, forever = ERA }
-- the buff counter knows Classic Era's 32 buff slots and the auras that
-- fill them unseen; TBC has 40, and Forever's limit is not known yet
local BUFF_SLOTS = { tbc = RCL["counts Classic Era's 32 buff slots; TBC has 40"],
                     forever = RCL["counts Classic Era's 32 buff slots; Forever's buff limit is not known yet"] }

RC.FEATURE_FLAVORS = {
    -- Era-only content
    { id = "world_tools", name = RCL["World Tools and world buffs (drop timers, timer network, buff board, summons, turn-ins)"],
      off = ERA_ONLY, addon = "Readycheck_WorldTools",
      pages = { "world_tools", "wt_pulltimers", "wt_buffnetwork", "wt_automation", "wt_wbdrops", "world_buffs" } },
    { id = "chronoboon", name = RCL["Chronoboon reminder"], off = ERA_ONLY, pages = { "boon_reminder" } },
    { id = "raid_configs", name = RCL["Raid boss and trash configs (Molten Core, Blackwing Lair, AQ40, Naxxramas) and their ability reminders"],
      off = ERA_ONLY, pages = { "raids", "mc", "bwl", "aq40", "naxx", "remote_raid_cfg" } },
    { id = "boss_notes", name = RCL["Boss and trash notes"], off = ERA_ONLY, pages = { "boss_notes" } },
    { id = "polarity", name = RCL["Polarity mode (Thaddius, Sapphiron)"], off = ERA_ONLY },
    { id = "raid_route", name = RCL["Raid route (per-pull steps, gear sets, trinkets, reminders)"], off = ERA_ONLY },
    { id = "boss_gear_target", name = RCL["Boss gear set when you target the boss"], off = ERA_ONLY },
    { id = "boss_gear_kill", name = RCL["Boss gear set after the kill"], off = ERA_ONLY },
    { id = "boss_gear_prompt", name = RCL["Ask which gear set to wear after a kill"], off = ERA_ONLY },
    { id = "buff_pushoff", name = RCL["Buff pushoff alert, 32-slot buff counter and Darkmoon fortune watch"], off = BUFF_SLOTS,
      pages = { "buff_pushoff" } },
    -- Built on the combat log, or on values Forever hides in combat
    { id = "kill_watch", name = RCL["Trash kill counting (route steps, trash notes, Thaddius)"], off = { forever = CLOG } },
    { id = "overpower_dodge", name = RCL["Overpower glow after a dodge (nameplates)"], off = { forever = CLOG } },
    { id = "ttk", name = RCL["TTK display and ML kill-time predictions"], off = { forever = HEALTH },
      pages = { "execute", "ttk_display" },
      stubs = { "OnExecuteCombatStart", "OnExecuteCombatEnd", "OnExecuteTargetChanged",
                "OnExecuteBossKilledByEncounterEnd", "PredictTTK", "CheckExecutePhase",
                "StartFightTracking", "EndFightTracking", "RecordFightKill",
                "ScanForBossOnCombatStart", "HandleBossUnitEvent", "UpdateEncounterUnits",
                "ScanRaidForBoss", "UpdateTTKDisplayActive", "CalculateTimeToKill" } },
    { id = "boss_debuff_tracker", name = RCL["Boss debuff tracker"], off = { forever = DEBUFFS },
      pages = { "boss_debuff_tracker" } },
    -- Addon messages
    { id = "mesh_in_instance", name = RCL["Mesh sync, version check and gold sync inside instances"], off = { forever = MSG } },

    -- On everywhere (listed so the table covers every module)
    { id = "reminder_popup", name = RCL["Reminder popup, sounds and text-to-speech"] },
    { id = "battle_shout", name = RCL["Battle Shout reminder and party tracker"] },
    { id = "custom_reminders", name = RCL["Custom reminders"] },
    { id = "equipment_reminder", name = RCL["Equipment reminder (weapons, shield, enchants)"] },
    { id = "raid_buff_tracker", name = RCL["Raid buff tracker"] },
    { id = "consumable_bars", name = RCL["Consumables, potions and weapons bars, trinket menu (each game version's own items)"] },
    { id = "consumables_checker", name = RCL["Consumables checker and must-have item alert (each game version's own items; the raid-entry check needs the Classic Era raids)"] },
    { id = "raid_consume_reminders", name = RCL["Raid consume reminders (testing)"] },
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

local BY_ID, BY_PAGE, BY_ADDON = {}, {}, {}
for _, f in ipairs(RC.FEATURE_FLAVORS) do
    BY_ID[f.id] = f
    for _, p in ipairs(f.pages or {}) do BY_PAGE[p] = f end
    if f.addon then BY_ADDON[f.addon] = f end
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

-- "Not on TBC: Classic Era content", plus "(simulated)" under the override.
function RC:FeatureOffNote(id)
    local why = self:FeatureOffReason(id)
    if not why then return nil end
    local note = string.format(RCL["Not on %s: %s"], self:FlavorName(), why)
    if self:IsSimulatedFlavor() then note = note .. " " .. RCL["(simulated)"] end
    return note
end

-- The switched-off feature behind a sidebar entry, or nil.
function RC:FeatureOffForPage(menuItem)
    if type(menuItem) ~= "table" then return nil end
    local f = menuItem.id and BY_PAGE[menuItem.id]
    if f and not self:FeatureOn(f.id) then return f.id end
    return nil
end

-- A companion addon that this flavor does not load at all.
function RC:AddonOffByFlavor(addonName)
    local f = BY_ADDON[addonName]
    return (f and not self:FeatureOn(f.id)) and true or false
end

-- Every switched-off feature on a flavor (this one by default), in table
-- order: { { id =, name =, reason = }, ... }.
function RC:FeaturesOff(flavor)
    flavor = flavor or self:Flavor()
    local out = {}
    for _, f in ipairs(self.FEATURE_FLAVORS) do
        local why = f.off and f.off[flavor]
        if why then out[#out + 1] = { id = f.id, name = f.name, reason = why } end
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

-- A companion that is not loaded leaves no sidebar group behind; put the
-- World Tools group back as an entry that shows why.
function RC:AddFlavorMenuStubs()
    local menu = self.MenuStructure
    if type(menu) ~= "table" or self:FeatureOn("world_tools") then return end
    for _, item in ipairs(menu) do
        if item.id == "world_tools" then return end
    end
    local entry = {
        id = "world_tools", name = RCL["World Tools"], category = true,
        icon = "Interface\\Icons\\INV_Misc_PocketWatch_02",
        panel = "ShowSidebarWorldToolsOverview",
        children = {
            { id = "wt_pulltimers", name = RCL["Buff Drops"], icon = "Interface\\Icons\\INV_Misc_PocketWatch_02", panel = "ShowSidebarWTTimers" },
            { id = "wt_buffnetwork", name = RCL["Buff Timer Network"], icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01", panel = "ShowSidebarWBTNetwork" },
            { id = "wt_automation", name = RCL["Automation"], icon = "Interface\\Icons\\INV_Misc_EngGizmos_20", panel = "ShowSidebarWTAutomation" },
        },
    }
    local at = #menu + 1
    for i, item in ipairs(menu) do
        if item.id == "mesh" then at = i break end
    end
    table.insert(menu, at, entry)
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
    local off = self:FeaturesOff(cur)
    if #off == 0 then
        self:Print(RCL["Every feature is on."])
    else
        self:Print(string.format(RCL["Switched off on %s:"], self:FlavorName(cur)))
        for _, f in ipairs(off) do
            self:Print("  " .. f.name .. ": " .. f.reason)
        end
    end
end
