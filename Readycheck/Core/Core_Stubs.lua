------------------------------------------------------------------------
-- Readycheck - Absent Companion Stubs
-- No-op fallbacks for everything the main addon calls on
-- Readycheck_Reminders, Readycheck_Consumables and Readycheck_Gear. All
-- three are companions the user can untick in the AddOns list, and each
-- owns functions that the trigger event pump, the scanner and the slash
-- commands call without a guard - in combat, dozens of times a second.
-- One missed nil check there is a Lua error mid-pull, so the contract is
-- inverted: the method always exists, and the real one simply replaces
-- the stub.
--
-- Load order is what makes this safe. Companions are force-loaded from
-- Core_Runtime's ADDON_LOADED handler, which runs after this whole file,
-- so a real definition always lands on top of its stub. Never add a stub
-- for something the main addon itself defines.
--
-- NOT stubbed on purpose: every ShowSidebar* page entry point. The
-- sidebar's lazy loader in Sidebar_Base/Sidebar_Window keys off
-- `not self[panel]` to decide whether to LoadAddOn the owning module, so
-- a stub there would make the page permanently blank instead of loading
-- it on first click.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

-- Return nothing. Callers that read a result all treat nil as "nothing to
-- do" already; the two that cannot are written out longhand below.
local NOOP = {
    -- Reminder frame (Core_Reminders.lua)
    "ShowReminder", "ShowReminderForced", "ShowTestReminder",
    "HideReminder", "HideAllReminders", "ForceResetReminderFrame",
    "UpdateReminderFrameMouseState", "SetupCooldownMonitoring",

    -- Trigger engine (Trigger\TE_Triggers, TE_Reminders, TE_Encounters)
    "RunTriggerCheck", "GetCurrentTargetData", "CalculateTimeToKill",
    "ResetSpellCastTriggers", "ProcessSpellCastForDismissal",
    "StartBuffRemainingMonitor", "StopBuffRemainingMonitor",
    "UpdateReminderWithRemainingAbilities", "CheckAndDismissPotionBuffs",
    "CheckAndDismissFrostBlastReminder", "CheckFrostBlastDebuff",
    "CheckFrostBlastBuffRemoval", "CheckBossTargetConsumableReminders",
    "HasSaygeBuff", "IsBossEngagedForEncounter",

    -- TTK / execute calculator (TTK\*)
    "OnExecuteCombatStart", "OnExecuteCombatEnd", "OnExecuteTargetChanged",
    "OnExecuteBossKilledByEncounterEnd", "SaveExecuteSettings",
    "LoadExecuteSettings", "StartBossSimulation", "EndBossSimulation",
    "StopSimulation", "ClearAllHistory", "ClearBossHistory",
    "GetFightHistoryForBoss", "MigrateFightHistoryAliases",
    "AddManualKillTime", "UpdateTTKDisplayActive", "ShowBulkKillDialog",
    "ShowFightEditDialog", "PredictTTK", "CheckExecutePhase",
    "StartFightTracking", "EndFightTracking", "RecordFightKill",

    -- Reminder features (Reminders\*)
    "UpdateFastWeaponReminder", "UpdateEquipmentReminderFontSize",
    "UpdateEquipmentReminderIconSize", "ShowFastWeaponReminderTest",
    "HideFastWeaponReminderTest", "AddCustomEquipmentItem",
    "RemoveCustomEquipmentItem", "ToggleBattleShoutReminder",
    "ApplyBattleShoutLockState", "UpdateBattleShoutReminder",
    "UpdateBoonReminder", "KickCustomReminderTicker",
    "ListCustomReminders", "TestFireCustomReminder",
    "RefreshCustomReminderEvents", "StartCustomReminderTicker",
    "StopCustomReminderTicker",

    -- Raid route (Route\*)
    "KillWatchRegister", "KillWatchUnregister", "RenderRaidRouteBody",

    -- Trinket locks (Readycheck_Gear). Silent on purpose: these fire
    -- automatically from the trigger pump on every boss target change, so a
    -- message here would spam. EquipTrinketSet is the one that bites
    -- hardest - the per-boss trinket override config lives in the MAIN addon
    -- (Raids_BossConfig), so it survives unticking Gear and TE_ForceEquip
    -- keeps calling this, plus once more per retry pass.
    -- The Hotswap* trio is deliberately NOT here: those are user-pressed
    -- macros and get talking stubs further down.
    "EquipTrinketSet", "ReleaseBossTrinketLock",

    -- Consumable bars and checker (Readycheck_Consumables)
    "CreateTrinketBarFrame", "UpdateTrinketBarButtons",
    "UpdateTrinketBarVisibility", "UpdateConsumablesButtons",
    "UpdateConsumablesCheckerDisplay", "UpdateConsumablesHelperBackground",
    "UpdatePotionsBarBackground", "UpdateConsumablesBarMouseoverFade",
    "UpdatePotionsBarMouseoverFade", "UpdateWeaponsBarMouseoverFade",
    "PopulateConsumablesChecker", "ToggleConsumablesChecker",
    "PrintConsumablesReport", "HasConsumableBuff", "ResolveConsumableBuff",
    "GetConflictGroup", "HasConflictGroupBuff", "RefreshConsumablesDisplay",
    "RefreshPotionsDisplay", "RefreshWeaponButtons",
}

local function Noop() end
for i = 1, #NOOP do
    local name = NOOP[i]
    if not RC[name] then
        RC[name] = Noop
    end
end

-- Core_Scan's "/rc ttk summary" takes the length of this immediately, so
-- nil would throw where every other stub can safely return nothing.
if not RC.GetAllFightDataSummary then
    function RC:GetAllFightDataSummary()
        return {}
    end
end

-- Compared with > 0 in Raids_Equipment's custom item list.
if not RC.GetCustomEquipmentItemCount then
    function RC:GetCustomEquipmentItemCount()
        return 0
    end
end

------------------------------------------------------------------------
-- Talking stubs for the macro surface (Readycheck_Gear)
--
-- These are reached from macro bodies the user pasted or generated from
-- the Hotswap page, and from ReadycheckGear:* calls in hand-written
-- macros. A silent no-op here is worse than an error: the key does
-- nothing and there is no way to tell why. So they explain themselves
-- once, then go quiet.
--
-- Throttled because these sit on action bars - a user mashing the button
-- mid-pull must not flood their chat frame.
------------------------------------------------------------------------
-- "absent" (the user unticked it) vs "loading" (it is enabled but its
-- deferred initializer has not installed the real methods yet - Gear's
-- hotswap init is C_Timer.After(1), its trinket init After(3), Features'
-- smart macros After(1), boss notes After(0.5)). Telling someone to enable
-- an addon they already have enabled is worse than saying nothing, so
-- every companion-missing message has to tell these two apart.
function RC:CompanionStatus(addonName)
    local IsLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if IsLoaded and IsLoaded(addonName) then return "loading" end
    return "absent"
end

local _lastGearNag = 0
local function GearMissing()
    local now = GetTime and GetTime() or 0
    if now - _lastGearNag <= 10 then return end
    _lastGearNag = now
    if not RC.Print then return end
    -- Literals inside RCL[] so the locale extractor can see the strings.
    if RC:CompanionStatus("Readycheck_Gear") == "loading" then
        RC:Print(RCL["|cFFFFAA00Readycheck:|r still starting up - try that macro again in a moment."])
    else
        RC:Print(RCL["|cFFFF4444Readycheck:|r this macro needs the Readycheck_Gear addon. Enable it in your AddOns list and /reload."])
    end
end

for _, name in ipairs({ "HotswapBattleShout", "HotswapDiamondFlask",
                        "HotswapBloodrage" }) do
    if not RC[name] then
        RC[name] = function() GearMissing() end
    end
end

-- ReadycheckGear is a GLOBAL created by Readycheck_Gear (GM_Runtime.lua)
-- purely as a macro-facing API. Older macros were rewritten to call it by
-- the WarriorReminder migration in Core_Runtime, so bodies referencing it
-- are out in the wild on characters whose Gear addon may be switched off -
-- where the call raised "attempt to index global 'ReadycheckGear'".
-- Shapes match the real table so a macro degrades to a message plus a
-- harmless return instead of an error. Gear assigns the real table
-- wholesale at load, which lands after this file and replaces the stub.
if not ReadycheckGear then
    ReadycheckGear = {
        EquipSet        = function() GearMissing() end,
        ToggleSet       = function() GearMissing() end,
        SaveCurrentGear = function() GearMissing() end,
        IsSetEquipped   = function() GearMissing() return false end,
        GetSets         = function() GearMissing() return {} end,
    }
end

-- Placeholder state tables. Same purpose as RC.activeReminderData in
-- Core_Boot and RC.weaponsBar in Core_Runtime: a handful of call sites
-- reach a field on these without checking the table first, so an empty
-- table turns a hard error into a nil read.
--
-- ONLY tables whose owner assigns them wholesale (`RC.x = { ... }`) may
-- go here, plus the two that build up from `or {}` with no defaults. A
-- table whose owner writes `if not RC.x then RC.x = {defaults} end` or
-- `RC.x = RC.x or {defaults}` must NOT be listed: the placeholder would
-- satisfy that check and the real defaults would never be installed.
-- RC.executeCalculator and RC.boonReminder are both in that category,
-- which is why they are absent - every core reader of executeCalculator
-- already does `local ec = RC.executeCalculator; if not ec then return`.
RC.consumablesHelper   = RC.consumablesHelper   or { buttons = {} }
RC.potionsBar          = RC.potionsBar          or { buttons = {} }
RC.trinketBar          = RC.trinketBar          or { buttons = {} }
RC.consumablesChecker  = RC.consumablesChecker  or {}
RC.TTKDisplay          = RC.TTKDisplay          or {}
RC.fastWeaponReminder  = RC.fastWeaponReminder  or {}
RC.battleShoutReminder = RC.battleShoutReminder or {}
RC.CustomReminders     = RC.CustomReminders     or {}

-- PROFILER (RC.Profiler)
-- The real profiler lives in Readycheck_Debug\AddonProfiler.lua - a
-- developer-only addon that is NOT shipped. Roughly a hundred call sites
-- across all nine folders bracket hot paths with StartTiming/StopTiming,
-- build their tickers through TrackTicker, and wrap event handlers with
-- WrapHandler. Every one of them is nil-guarded by hand today, which only
-- holds until someone forgets one - and a forgotten guard in a release
-- build is a Lua error for every user. Same inverted contract as the
-- companion stubs above: the API always exists, the real one replaces it.
--
-- Readycheck_Debug declares `## Dependencies: Readycheck`, so it always
-- loads AFTER this file. Its own bootstrap does
--   RC.Profiler = RC.Profiler or { initialized = false, modules = {}, tickers = {} }
-- which is why the table below carries exactly those three fields: the
-- merge keeps this table and its real methods land on top of these no-ops.
-- (This is the one placeholder table exempt from the `or {defaults}` rule
-- noted above, because the defaults are reproduced here verbatim.)
--
-- TrackTicker and WrapHandler are deliberately NOT no-ops. ~50 call sites
-- keep TrackTicker's return value to Cancel() the ticker later, and wrapped
-- handlers are invoked for real from OnEvent dispatchers. Only the
-- measurement is dropped: TrackTicker still builds a live C_Timer ticker,
-- WrapHandler is pass-through. Nothing here allocates per call.
--
-- `isStub` exists because a handful of call sites used plain
-- `if RC.Profiler then` as an "is Readycheck_Debug installed?" test rather
-- than as a nil-guard - Core_Debug's DebugPrint/IsDebugEnabled gate, the
-- Commands page's Profiler/Debug sections, and the Execute page's debug
-- card. Those must keep answering "no" in a shipped build, so they test
-- `RC.Profiler.isStub` instead; AddonProfiler.lua clears the flag when the
-- real subsystem loads. Pure nil-guards around StartTiming/TrackTicker are
-- unaffected - they now simply always take the profiler branch.
RC.Profiler = RC.Profiler or {
    isStub      = true,
    initialized = false,
    modules     = {},
    tickers     = {},
}
do
    local P = RC.Profiler

    -- Measurement only - genuinely empty.
    if not P.StartTiming   then function P:StartTiming(moduleName)  end end
    if not P.StopTiming    then function P:StopTiming(moduleName)   end end
    if not P.CountHit      then function P:CountHit(name)           end end
    if not P.ResetModules  then function P:ResetModules()           end end
    if not P.ResetTickers  then function P:ResetTickers()           end end
    if not P.SampleTickers then function P:SampleTickers()          end end

    -- Real functionality - must keep working with the profiler absent.
    if not P.TrackTicker then
        function P:TrackTicker(name, interval, callback)
            return C_Timer.NewTicker(interval, callback)
        end
    end
    if not P.WrapHandler then
        function P:WrapHandler(name, callback)
            return callback
        end
    end
end
