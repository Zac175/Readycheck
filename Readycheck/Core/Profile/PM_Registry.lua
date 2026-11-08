------------------------------------------------------------------------
-- Readycheck - Settings Registry
-- Single source of truth for settings: RC.SETTING_CATEGORIES and
-- RC.SETTINGS below. RC.EXPORT_CATEGORIES and RC.EXPORTABLE_KEYS (used by
-- PM_Export.lua and mesh sync) are derived from these, not hand-declared,
-- so a setting listed once here is automatically exportable and syncable.
-- RC:AuditSettingsRegistry() reports any setting with an unknown category
-- or missing default, and any RC.defaults key not covered by a setting.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

RC.SETTING_CATEGORIES = {
    { id = "general", group = "Display & UI", label = RCL["General Settings"], },
    { id = "colors", group = "Display & UI", label = RCL["Colors"], },
    { id = "fonts", group = "Display & UI", label = RCL["Fonts"], },
    { id = "sidebar", group = "Display & UI", label = RCL["Sidebar"], },
    { id = "minimap", group = "Display & UI", label = RCL["Minimap Button"], },
    { id = "statsBar", group = "Display & UI", label = RCL["Stats Bar"], },
    { id = "ttkDisplay", group = "Display & UI", label = RCL["TTK Display Bar"], },
    { id = "buffAlert", group = "Display & UI", label = RCL["Buff Pushoff Alert"], },
    { id = "abilityReminders", group = "Reminders", label = RCL["Ability Reminders"], },
    { id = "customReminders", group = "Reminders", label = RCL["Custom Reminders"], },
    { id = "smartMacros", group = "Reminders", label = RCL["Smart Macros"], },
    { id = "battleShout", group = "Reminders", label = RCL["Battle Shout"], },
    -- `feature`: a Core_Flavor row; the lists hide it where that is off
    -- (not on WoW Forever), as they do for `addon` below
    { id = "battleShoutTracker", group = "Reminders", label = RCL["Battle Shout Party Tracker"], feature = "battle_shout_party", },
    { id = "boonReminder", group = "Reminders", label = RCL["Chronoboon Reminder"], },
    { id = "repairReminder", group = "Reminders", label = RCL["Repair Reminder"], },
    { id = "fastWeapon", group = "Reminders", label = RCL["Fast Weapon Reminder"], },
    { id = "specDetection", group = "Combat", label = RCL["Spec Detection"], },
    { id = "executeCalc", group = "Combat", label = RCL["ML Predictions & TTK"], },
    { id = "bars", group = "Equipment", label = RCL["All Bars"], },
    { id = "trinketSwap", group = "Equipment", label = RCL["Trinket Swap"], },
    { id = "gearManager", group = "Equipment", label = RCL["Gear Manager Settings"], },
    { id = "gearSets", group = "Equipment", label = RCL["Gear Sets"], },
    { id = "hotswap", group = "Equipment", label = RCL["Hotswap Macros"], },
    { id = "consumablesHelper", group = "Consumables", label = RCL["Consumables Helper"], },
    { id = "consumablesChecker", group = "Consumables", label = RCL["Consumables Checker"], },
    { id = "raidProfiles", group = "Raids", label = RCL["Raid Profiles"], },
    { id = "bossNotes", group = "Raids", label = RCL["Boss Notes"], },
    { id = "nameplateAuras", group = "Display & UI", label = RCL["Nameplates"], },
    { id = "worldBuffs", group = "Display & UI", label = RCL["World Buff Board"], },
    { id = "raidPlanner", group = "Raids", label = RCL["Raid Planner"], retired = true, },
    { id = "meshBar", group = "Display & UI", label = RCL["Sync Transfer Bar"], },
    -- Appended (not next to their Reminders siblings) so the mesh digest's
    -- positional category layout stays stable for existing peers.
    -- `addon`: the feature lives in a companion addon. The category stays
    -- in the registry, the profile, the export key map and the mesh digest
    -- (every peer must keep the same positional layout), but user-facing
    -- lists (Sync Rules, Import/Export, the request picker) hide it while
    -- that addon is not loaded - see RC:IsSettingCategoryAvailable.
    { id = "raidBuffTracker", group = "Reminders", label = RCL["Raid Buff Tracker"], addon = "Readycheck_Reminders", },
    { id = "bossDebuffTracker", group = "Reminders", label = RCL["Boss Debuff Tracker"], addon = "Readycheck_Reminders", },
    { id = "motion", group = "Display & UI", label = RCL["Animations"], },
}

-- True unless the category is tied to an addon (cat.addon) that is not
-- loaded. Only for UI lists: never use it to skip a category in the mesh
-- digest, the sync flags or the export key map, or peers with and without
-- that addon stop agreeing on the category layout.
function RC:IsSettingCategoryAvailable(cat)
    -- (a feature this game version does not run: Core_Flavor)
    if type(cat) == "table" and cat.feature and self.FeatureOn and not self:FeatureOn(cat.feature) then return false end
    if type(cat) ~= "table" or not cat.addon then return true end
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if not isLoaded then return true end
    return isLoaded(cat.addon) and true or false
end

-- key: the RC.db field. cat: which category carries it.
-- label: shown in the per-setting sync picker and import/export UI.
RC.SETTINGS = {
    -- General Settings
    { key = "enabled", cat = "general", label = RCL["Addon enabled"] },
    { key = "showInCombatOnly", cat = "general", label = RCL["Show in combat only"] },
    { key = "abilityReadyGracePeriod", cat = "general", label = RCL["Ability ready grace period"] },
    { key = "fadeInTime", cat = "general", label = RCL["Fade in time"] },
    { key = "fadeTime", cat = "general", label = RCL["Fade out time"] },
    { key = "soundEnabled", cat = "general", label = RCL["Sound alerts"] },
    { key = "ttsEnabled", cat = "general", label = RCL["Text-to-speech alerts"] },
    { key = "ttsRepeatCount", cat = "general", label = RCL["Text-to-speech repeat count"] },
    { key = "ttsRepeatInterval", cat = "general", label = RCL["Text-to-speech repeat interval"] },
    { key = "anchorPoint", cat = "general", label = RCL["Screen anchor point"] },
    { key = "xOffset", cat = "general", label = RCL["Horizontal offset"] },
    { key = "yOffset", cat = "general", label = RCL["Vertical offset"] },
    { key = "iconSize", cat = "general", label = RCL["Icon size"] },
    { key = "iconSpacing", cat = "general", label = RCL["Icon spacing"] },
    { key = "showIconText", cat = "general", label = RCL["Show text on icons"] },
    { key = "iconGlow", cat = "general", label = RCL["Reminder icon glow"] },
    { key = "showTooltips", cat = "general", label = RCL["Show tooltips"] },
    { key = "dragEnabled", cat = "general", label = RCL["Frame dragging"] },
    { key = "clickThrough", cat = "general", label = RCL["Click-through frame"] },
    { key = "hideUnderMap", cat = "general", label = RCL["Hide frames under the world map"] },
    { key = "animationType", cat = "general", label = RCL["Animation style"] },
    { key = "nonWarriorEnabled", cat = "general", label = RCL["Non-warrior features"] },
    -- Colors
    { key = "customColors", cat = "colors", label = RCL["Custom colors"] },
    -- Fonts
    { key = "fontSettings", cat = "fonts", label = RCL["Font settings"] },
    -- Sidebar
    { key = "sidebarPosition", cat = "sidebar", label = RCL["Sidebar position"] },
    { key = "sidebarState", cat = "sidebar", label = RCL["Sidebar open/closed state"] },
    { key = "lastSidebarSelection", cat = "sidebar", label = RCL["Last selected page"] },
    { key = "sidebarNav", cat = "sidebar", label = RCL["Navigation tree state"] },
    { key = "configWindowWidth", cat = "sidebar", label = RCL["Config window width"] },
    { key = "configWindowHeight", cat = "sidebar", label = RCL["Config window height"] },
    { key = "profilePicker", cat = "sidebar", label = RCL["Profile picker state"] },
    -- Minimap Button
    { key = "minimapButton", cat = "minimap", label = RCL["Minimap button"] },
    -- Stats Bar
    { key = "showStatsBar", cat = "statsBar", label = RCL["Show stats bar"] },
    { key = "showStatsButton", cat = "statsBar", label = RCL["Show stats button"] },
    { key = "statsBarLocked", cat = "statsBar", label = RCL["Lock stats bar"] },
    { key = "statsBarShowBg", cat = "statsBar", label = RCL["Show background"] },
    { key = "statsBarShowPushoffIcon", cat = "statsBar", label = RCL["Show pushoff icon"] },
    { key = "statsBarDurability", cat = "statsBar", label = RCL["Show durability"] },
    { key = "statsBarGold", cat = "statsBar", label = RCL["Show gold"] },
    { key = "statsBarPosition", cat = "statsBar", label = RCL["Stats bar position"] },
    { key = "statsBarColors", cat = "statsBar", label = RCL["Stats bar colors"] },
    { key = "statsBarFontSize", cat = "statsBar", label = RCL["Font size"] },
    { key = "statsBarHeight", cat = "statsBar", label = RCL["Bar height"] },
    { key = "statsBarSpacing", cat = "statsBar", label = RCL["Bar spacing"] },
    { key = "statsBarStats", cat = "statsBar", label = RCL["Which stats are shown"] },
    -- TTK Display Bar
    { key = "ttkDisplay", cat = "ttkDisplay", label = RCL["TTK display bar"] },
    -- Buff Pushoff Alert
    { key = "buffPushoffAlert", cat = "buffAlert", label = RCL["Buff pushoff alert"] },
    { key = "buffCap", cat = "buffAlert", label = RCL["Buff cap counter"] },
    -- Ability Reminders
    { key = "abilityOverrides", cat = "abilityReminders", label = RCL["Per-ability overrides"] },
    { key = "soundKey", cat = "abilityReminders", label = RCL["Alert sound"] },
    { key = "soundFile", cat = "abilityReminders", label = RCL["Custom sound file"] },
    -- Custom Reminders
    { key = "customReminders", cat = "customReminders", label = RCL["Custom reminders"] },
    -- Smart Macros
    { key = "smartMacros", cat = "smartMacros", label = RCL["Smart macros"] },
    { key = "smartMacrosNextId", cat = "smartMacros", label = RCL["Smart macro id counter"] },
    -- Battle Shout
    { key = "battleShoutReminder", cat = "battleShout", label = RCL["Battle Shout reminder"] },
    -- Battle Shout Party Tracker
    { key = "battleShoutPartyTracker", cat = "battleShoutTracker", label = RCL["Battle Shout party tracker"] },
    -- Chronoboon Reminder
    { key = "boonReminder", cat = "boonReminder", label = RCL["Chronoboon reminder"] },
    -- Repair Reminder
    { key = "repairReminder", cat = "repairReminder", label = RCL["Repair reminder"] },
    -- Fast Weapon Reminder
    { key = "fastWeaponReminder", cat = "fastWeapon", label = RCL["Fast weapon reminder"] },
    -- Spec Detection
    { key = "specDetection", cat = "specDetection", label = RCL["Spec detection"] },
    -- ML Predictions & TTK
    { key = "executeCalculator", cat = "executeCalc", label = RCL["Execute calculator"] },
    { key = "executeSettings", cat = "executeCalc", label = RCL["Prediction & TTK settings"] },
    -- All Bars
    { key = "trinketBar", cat = "bars", label = RCL["Trinket bar"] },
    { key = "weaponsBar", cat = "bars", label = RCL["Weapons bar"] },
    { key = "potionsBar", cat = "bars", label = RCL["Potions bar"] },
    -- Trinket Swap
    { key = "trinketSwap", cat = "trinketSwap", label = RCL["Trinket auto-swap"] },
    -- Gear Manager Settings
    { key = "gearManager", cat = "gearManager", label = RCL["Gear manager layout"] },
    { key = "gearButtons", cat = "gearManager", label = RCL["Dockable gear buttons"] },
    { key = "gearButtonPositions", cat = "gearManager", label = RCL["Gear button positions"] },
    { key = "gearPinnedButtons", cat = "gearManager", label = RCL["Pinned gear buttons"] },
    { key = "gearUseRevert", cat = "gearManager", label = RCL["Revert after use"] },
    { key = "itemEnchantPreference", cat = "gearManager", label = RCL["Enchant preference"] },
    { key = "speedSwapTargets", cat = "gearManager", label = RCL["Speed swap targets"] },
    { key = "gearSwapRetry", cat = "gearManager", label = RCL["Boss gear swap retries"] },
    -- Gear Sets
    { key = "gearSets", cat = "gearSets", label = RCL["Gear sets"] },
    -- Hotswap Macros
    { key = "hotswapEnabled", cat = "hotswap", label = RCL["Hotswap enabled"] },
    { key = "hotswapT2Protect", cat = "hotswap", label = RCL["Tier 2 protection"] },
    { key = "hotswapPartyAnnounce", cat = "hotswap", label = RCL["Announce to party"] },
    { key = "hotswapAnnounceChannel", cat = "hotswap", label = RCL["Announce channel"] },
    { key = "hotswapAnnounceMessage", cat = "hotswap", label = RCL["Announce message"] },
    { key = "hotswapCombatBlockMessage", cat = "hotswap", label = RCL["Combat blocked message"] },
    { key = "hotswapCombatQueue", cat = "hotswap", label = RCL["Queue in combat"] },
    -- Consumables Helper
    { key = "consumablesHelper", cat = "consumablesHelper", label = RCL["Consumables helper"] },
    { key = "consumableSettings", cat = "consumablesHelper", label = RCL["Consumable preferences"] },
    -- Consumables Checker
    { key = "consumablesChecker", cat = "consumablesChecker", label = RCL["Consumables checker"] },
    -- Raid Profiles
    { key = "raidProfiles", cat = "raidProfiles", label = RCL["Raid & boss configs"] },
    { key = "polarityMode", cat = "raidProfiles", label = RCL["Polarity mode"] },
    { key = "frostBlastConfig", cat = "raidProfiles", label = RCL["Frost Blast config"] },
    { key = "raidRoute", cat = "raidProfiles", label = RCL["Route tracker"] },
    -- Boss Notes
    { key = "bossNotes", cat = "bossNotes", label = RCL["Boss & trash notes"] },
    -- Nameplates
    { key = "nameplateAuras", cat = "nameplateAuras", label = RCL["Nameplate auras"] },
    -- World Buff Board
    { key = "worldBuffs", cat = "worldBuffs", label = RCL["World buff board"] },
    -- Appended at the end (not next to their category siblings) so existing
    -- category key positions in the mesh digest stay stable.
    { key = "meshProgressBar", cat = "meshBar", label = RCL["Sync transfer bar position"] },
    { key = "worldBuffTimers", cat = "worldBuffs", label = RCL["Buff timer network settings"] },
    { key = "raidBuffTracker", cat = "raidBuffTracker", label = RCL["Raid buff tracker"] },
    { key = "bossDebuffTracker", cat = "bossDebuffTracker", label = RCL["Boss debuff tracker"] },
    { key = "gearSetPrompt", cat = "gearManager", label = RCL["Gear set picker position"] },
    { key = "swapToast", cat = "gearManager", label = RCL["Gear swap notices"] },
    { key = "iconBorder", cat = "general", label = RCL["Reminder icon border"] },
    { key = "iconGlowScale", cat = "general", label = RCL["Reminder icon glow size"] },
    { key = "reminderMotion", cat = "general", label = RCL["Reminder animation details"] },
    { key = "reminderText", cat = "general", label = RCL["Reminder icon text"] },
    { key = "motion", cat = "motion", label = RCL["Animations"] },
    { key = "statsBarLook", cat = "statsBar", label = RCL["Stats bar look"] },
    { key = "reminderPopup", cat = "general", label = RCL["Reminder popup layout"] },
    { key = "consumeRemindGlow", cat = "consumablesHelper", label = RCL["Raid consume reminder glow"] },
    { key = "consumeRemind", cat = "consumablesHelper", label = RCL["Raid consume reminders"] },
}

-- Settings that deliberately never export or sync, with the reason. Listed
-- explicitly so the audit can tell "intentionally excluded" from "forgotten".
RC.NONSYNCED_SETTINGS = {
    setupWizard = "Setup progress, visited steps, the recorded role and a pending layout - per install, never shared",
    -- (account-level, outside the character profile, so never exported either:
    -- ReadycheckDB.account.cvarRecord - the game settings Readycheck changed and
    -- their values from before (Core_CVar); ReadycheckDB.account.setupHints - the
    -- one-time hints shown (Core_Hints); ReadycheckDB.account.setupPending -
    -- characters whose profile /rc resetprofile reset, so the setup opens once
    -- after the reload (PM_Cleanup, Core_Scan))
    spikeLogger = "Profiler capture buffer - debug data, not a setting",
    debugMode   = "Removed setting, cleaned up by ProfileManager",
    autoDetectedTrinkets = "Per-character detection cache - rebuilt from bags, not a setting",
    speedSwapPending = "Runtime swap-back state - meaningless on another character",
    ttsMissLog = "Diagnostic log - debug data, not a setting",
    wbWatchWrites = "World buff write tracing toggle - debug only",
    buffCapLearned = "Hidden buff slots measured on this character - wrong on any other",
    consumablesMigrated_nonWarriorItems = "One-time migration flag",
    consumablesMigrated_potionBarFoodBandage = "One-time migration flag",
    previewPane = "Preview fold, background, height and mode - window state, never shared",
    flavor = "Developer game version override (Classic Era / TBC / Forever) - this character only, never shared",
}

-- Optional friendly names for individual fields INSIDE a settings table,
-- used by the mesh per-setting picker. Anything absent falls back to a
-- humanised form of the field name, so this only needs entries where that
-- guess reads badly.
RC.SETTING_FIELD_LABELS = RC.SETTING_FIELD_LABELS or {
    -- Animations (Appearance > Motion) and the reminder popup's looks
    ["motion.enabled"]      = RCL["Play animations"],
    ["motion.speed"]        = RCL["Animation speed"],
    ["reminderMotion.show"] = RCL["Reminder entrance details"],
    ["reminderMotion.hide"] = RCL["Reminder exit animation"],
    ["reminderText.font"]   = RCL["Reminder icon text font"],
    ["reminderText.color"]  = RCL["Reminder icon text colour"],
    -- Battle Shout party tracker
    ["battleShoutPartyTracker.enabled"]         = RCL["Tracker enabled"],
    ["battleShoutPartyTracker.locked"]          = RCL["Lock frame"],
    ["battleShoutPartyTracker.xOffset"]         = RCL["Horizontal position"],
    ["battleShoutPartyTracker.yOffset"]         = RCL["Vertical position"],
    ["battleShoutPartyTracker.scale"]           = RCL["Scale"],
    ["battleShoutPartyTracker.opacity"]         = RCL["Opacity"],
    ["battleShoutPartyTracker.fontSize"]        = RCL["Font size"],
    ["battleShoutPartyTracker.visibilityMode"]  = RCL["Where to show it"],
    ["battleShoutPartyTracker.visibilityRaids"] = RCL["Which raids count"],
    ["battleShoutPartyTracker.showOnlyMissing"] = RCL["Only show players missing the buff"],
    ["battleShoutPartyTracker.width"]           = RCL["Frame width"],
    ["battleShoutPartyTracker.rowHeight"]       = RCL["Row height"],
    ["battleShoutPartyTracker.showBackground"]  = RCL["Show background"],
    ["battleShoutPartyTracker.showHeader"]      = RCL["Show header"],
    ["battleShoutPartyTracker.durationStyle"]   = RCL["Duration display style"],
    ["battleShoutPartyTracker.barMaxDuration"]  = RCL["Bar max duration"],
    ["battleShoutPartyTracker.rangeCheck"]      = RCL["Range check"],
    ["battleShoutPartyTracker.showBloodrage"]   = RCL["Show Bloodrage"],
    ["battleShoutPartyTracker.bloodrageStyle"]  = RCL["Bloodrage display style"],
    -- Repair reminder
    ["repairReminder.enabled"]   = RCL["Reminder enabled"],
    ["repairReminder.threshold"] = RCL["Durability threshold"],
    ["repairReminder.playSound"] = RCL["Play sound"],
    ["repairReminder.weaponSkill"] = RCL["Warn about weapons below full weapon skill"],
    ["repairReminder.soundKey"]  = RCL["Alert sound"],
    ["repairReminder.soundFile"] = RCL["Custom sound file"],
    ["repairReminder.tts"]       = RCL["Text-to-speech"],
    -- World buff board
    ["worldBuffs.enabled"]      = RCL["Board enabled"],
    ["worldBuffs.hideBelowMax"] = RCL["Hide below max level"],
    ["worldBuffs.boardSort"]         = RCL["Board sort order"],
    ["worldBuffs.boardSortTopClass"] = RCL["Board class listed first"],
    -- Buff timer network
    ["worldBuffTimers.enabled"]         = RCL["Network enabled"],
    ["worldBuffTimers.send"]            = RCL["Send timers to the network"],
    ["worldBuffTimers.relayBars"]       = RCL["Start pull bars from relayed yells"],
    ["worldBuffTimers.relayAlerts"]     = RCL["Relay alerts"],
    ["worldBuffTimers.npcKilledAlerts"] = RCL["NPC killed alerts"],
    ["worldBuffTimers.handInMsgs"]      = RCL["Hand-in messages"],
    ["worldBuffTimers.warn10"]          = RCL["10 minute warning"],
    ["worldBuffTimers.warn1"]           = RCL["1 minute warning"],
    ["worldBuffTimers.warn0"]           = RCL["Ready warning"],
    ["worldBuffTimers.mapPins"]         = RCL["World map pins"],
    ["worldBuffTimers.minimapPins"]     = RCL["Minimap songflower pins"],
    ["worldBuffTimers.meshSync"]        = RCL["Carry timers over mesh"],
    -- Sync transfer bar
    ["meshProgressBar.x"] = RCL["Horizontal position"],
    ["meshProgressBar.y"] = RCL["Vertical position"],
    -- After-boss gear set picker
    ["gearSetPrompt.x"] = RCL["Horizontal position"],
    ["gearSetPrompt.y"] = RCL["Vertical position"],
    ["gearSetPrompt.buttonWidth"] = RCL["Button width"],
    ["gearSetPrompt.rowHeight"]   = RCL["Row height"],
    -- Raid buff tracker
    ["raidBuffTracker.enabled"]         = RCL["Tracker enabled"],
    ["raidBuffTracker.alertMode"]       = RCL["Voice / on-screen alerts"],
    ["raidBuffTracker.visibilityMode"]  = RCL["Where to show it"],
    ["raidBuffTracker.visibilityRaids"] = RCL["Which raids count"],
    ["raidBuffTracker.showMissing"]     = RCL["Show missing auras"],
    ["raidBuffTracker.warnAt"]          = RCL["First warning (seconds)"],
    ["raidBuffTracker.warnAt2"]         = RCL["Urgent warning (seconds)"],
    ["raidBuffTracker.ttsMissing"]      = RCL["Say when missing"],
    ["raidBuffTracker.ttsCooldown"]     = RCL["Repeat voice warnings every"],
    ["raidBuffTracker.onlyInCombat"]    = RCL["Only in combat"],
    ["raidBuffTracker.tracked"]         = RCL["Which auras are tracked"],
    ["raidBuffTracker.custom"]          = RCL["Custom auras"],
    ["raidBuffTracker.locked"]          = RCL["Lock frame"],
    ["raidBuffTracker.anchorPoint"]     = RCL["Anchor point"],
    ["raidBuffTracker.xOffset"]         = RCL["Horizontal position"],
    ["raidBuffTracker.yOffset"]         = RCL["Vertical position"],
    ["raidBuffTracker.scale"]           = RCL["Scale"],
    ["raidBuffTracker.opacity"]         = RCL["Opacity"],
    ["raidBuffTracker.fontSize"]        = RCL["Font size"],
    ["raidBuffTracker.iconSize"]        = RCL["Icon size"],
    ["raidBuffTracker.rowWidth"]        = RCL["Row width"],
    ["raidBuffTracker.growDown"]        = RCL["Grow downward"],
    ["raidBuffTracker.layout"]          = RCL["Layout (list / compact)"],
    ["raidBuffTracker.compactPerRow"]   = RCL["Compact icons per row"],
    ["raidBuffTracker.compactIconSize"] = RCL["Compact icon size"],
    ["raidBuffTracker.showBackground"]  = RCL["Show background"],
    ["raidBuffTracker.spacing"]         = RCL["Row spacing"],
    ["raidBuffTracker.compactSpacing"]  = RCL["Compact icon spacing"],
    ["raidBuffTracker.hidePresent"]     = RCL["Show missing auras only"],
    ["raidBuffTracker.showExpiring"]    = RCL["Still show when about to expire"],
    ["raidBuffTracker.growLeft"]        = RCL["Compact columns wrap leftward"],
    ["raidBuffTracker.compactDirection"] = RCL["Compact grow direction"],
    ["raidBuffTracker.whisperCaster"]   = RCL["Whisper the caster when it runs out"],
    ["raidBuffTracker.whisperCooldown"] = RCL["Whisper at most once per"],
    ["raidBuffTracker.whisperFor"]      = RCL["Which auras are whispered about"],
    -- Boss debuff tracker
    ["bossDebuffTracker.enabled"]         = RCL["Tracker enabled"],
    ["bossDebuffTracker.alertMode"]       = RCL["Voice / on-screen alerts"],
    ["bossDebuffTracker.visibilityMode"]  = RCL["Where to show it"],
    ["bossDebuffTracker.visibilityRaids"] = RCL["Which raids count"],
    ["bossDebuffTracker.showMissing"]     = RCL["Show missing auras"],
    ["bossDebuffTracker.warnAt"]          = RCL["First warning (seconds)"],
    ["bossDebuffTracker.warnAt2"]         = RCL["Urgent warning (seconds)"],
    ["bossDebuffTracker.ttsMissing"]      = RCL["Say when missing"],
    ["bossDebuffTracker.ttsCooldown"]     = RCL["Repeat voice warnings every"],
    ["bossDebuffTracker.onlyInCombat"]    = RCL["Only in combat"],
    ["bossDebuffTracker.tracked"]         = RCL["Which auras are tracked"],
    ["bossDebuffTracker.custom"]          = RCL["Custom auras"],
    ["bossDebuffTracker.locked"]          = RCL["Lock frame"],
    ["bossDebuffTracker.anchorPoint"]     = RCL["Anchor point"],
    ["bossDebuffTracker.xOffset"]         = RCL["Horizontal position"],
    ["bossDebuffTracker.yOffset"]         = RCL["Vertical position"],
    ["bossDebuffTracker.scale"]           = RCL["Scale"],
    ["bossDebuffTracker.opacity"]         = RCL["Opacity"],
    ["bossDebuffTracker.fontSize"]        = RCL["Font size"],
    ["bossDebuffTracker.iconSize"]        = RCL["Icon size"],
    ["bossDebuffTracker.rowWidth"]        = RCL["Row width"],
    ["bossDebuffTracker.growDown"]        = RCL["Grow downward"],
    ["bossDebuffTracker.layout"]          = RCL["Layout (list / compact)"],
    ["bossDebuffTracker.compactPerRow"]   = RCL["Compact icons per row"],
    ["bossDebuffTracker.compactIconSize"] = RCL["Compact icon size"],
    ["bossDebuffTracker.showBackground"]  = RCL["Show background"],
    ["bossDebuffTracker.spacing"]         = RCL["Row spacing"],
    ["bossDebuffTracker.compactSpacing"]  = RCL["Compact icon spacing"],
    ["bossDebuffTracker.hidePresent"]     = RCL["Show missing auras only"],
    ["bossDebuffTracker.showExpiring"]    = RCL["Still show when about to expire"],
    ["bossDebuffTracker.growLeft"]        = RCL["Compact columns wrap leftward"],
    ["bossDebuffTracker.compactDirection"] = RCL["Compact grow direction"],
    ["bossDebuffTracker.bossesOnly"] = RCL["Bosses only"],
    ["bossDebuffTracker.whisperCaster"]   = RCL["Whisper the caster when it runs out"],
    ["bossDebuffTracker.whisperCooldown"] = RCL["Whisper at most once per"],
    ["bossDebuffTracker.whisperFor"]      = RCL["Which auras are whispered about"],
    -- Mesh-only virtual rows (no db field behind them; see MS.VIRTUAL_SETTINGS)
    ["raidProfiles.gear"]              = RCL["Gear swap sets & slot overrides inside boss configs"],
    -- Predictions & TTK (executeSettings mirrors the wire payload shape)
    ["executeSettings.executeThreshold"]        = RCL["Execute threshold (%)"],
    ["executeSettings.testModeEnabled"]         = RCL["Test mode"],
    ["executeSettings.mode"]                    = RCL["Prediction mode"],
    ["executeSettings.collectData"]             = RCL["Collect fight data"],
    ["executeSettings.classicGlobalMultiplier"] = RCL["Classic execute multiplier"],
    ["executeSettings.classicBossMultipliers"]  = RCL["Per-boss execute multipliers"],
    ["executeSettings.mlConfig"]                = RCL["ML model config"],
    ["executeSettings.mlConfig.minSamplesForPrediction"] = RCL["ML: minimum fights for a prediction"],
    ["executeSettings.mlConfig.maxSamplesForPrediction"] = RCL["ML: fights used per prediction"],
    ["executeSettings.mlConfig.confidenceThreshold"]     = RCL["ML: confidence threshold"],
    ["executeSettings.mlConfig.outlierThreshold"]        = RCL["ML: outlier threshold"],
    ["executeSettings.ewmaEnabled"]             = RCL["EWMA smoothing"],
    ["executeSettings.ewmaAlpha"]               = RCL["EWMA alpha"],
    ["executeSettings.dataCollection"]          = RCL["Data collection"],
    ["executeSettings.dataCollection.disabled"]       = RCL["Data collection paused"],
    ["executeSettings.dataCollection.disabledBosses"] = RCL["Bosses excluded from data collection"],
    ["executeSettings.uiSettings"]              = RCL["Predictions page view"],
    ["executeSettings.uiSettings.filterRaid"]          = RCL["Predictions page: raid filter"],
    ["executeSettings.uiSettings.filterBoss"]          = RCL["Predictions page: boss filter"],
    ["executeSettings.uiSettings.sortBy"]              = RCL["Predictions page: sort order"],
    ["executeSettings.uiSettings.showOnlyBosses"]      = RCL["Predictions page: bosses only"],
    ["executeSettings.uiSettings.showOnlyMultiCombat"] = RCL["Predictions page: multi-combat only"],
    ["executeSettings.uiSettings.minFights"]           = RCL["Predictions page: minimum fights"],
    ["executeSettings.uiSettings.minConfidence"]       = RCL["Predictions page: minimum confidence"],
    ["executeSettings.fightHistory"]            = RCL["Kill history & TTK data"],
    ["executeSettings.raidMultiplier"]          = RCL["Raid multiplier"],
    -- Route tracker
    ["raidRoute.enabled"]            = RCL["Route reminders enabled"],
    ["raidRoute.trackerEnabled"]     = RCL["Route tracker window"],
    ["raidRoute.trackerShowContext"] = RCL["Tracker shows surrounding steps"],
    ["raidRoute.trackerCustomSize"]  = RCL["Tracker window size"],
    ["raidRoute.reminderPos"]        = RCL["Route reminder position"],
    ["raidRoute.uiTab"]              = RCL["Last route tab"],
    ["raidRoute.offByDefaultDone"]   = RCL["Off-by-default migration flag"],
    -- Frost Blast
    ["frostBlastConfig.alsoShowWhenDebuffed"] = RCL["Also show while debuffed"],
    ["frostBlastConfig.cancelAuraBuffs"]      = RCL["Buffs to cancel"],
    ["frostBlastConfig.showMacroButton"]      = RCL["Show macro button"],
    ["frostBlastConfig.history"]              = RCL["Frost Blast history"],
    ["frostBlastConfig.maxHpSamples"]         = RCL["Max HP samples"],
    ["frostBlastConfig.peakMaxHp"]            = RCL["Peak max HP"],
    -- Polarity mode
    ["polarityMode.enabled"]            = RCL["Polarity mode enabled"],
    ["polarityMode.barEnabled"]         = RCL["Countdown bar"],
    ["polarityMode.acceptDBM"]          = RCL["Accept DBM pull timers"],
    ["polarityMode.acceptBigWigs"]      = RCL["Accept BigWigs pull timers"],
    ["polarityMode.acceptCountdown"]    = RCL["Accept /countdown"],
    ["polarityMode.acceptChatFallback"] = RCL["Accept chat pull calls"],
    ["polarityMode.deathWishLead"]      = RCL["Death Wish lead (seconds)"],
    ["polarityMode.lipTime"]            = RCL["LIP timing"],
    ["polarityMode.trinketSlot"]        = RCL["Trinket slot"],
    ["polarityMode.thadTimer"]          = RCL["Timer after Thaddius dies"],
    ["polarityMode.thadTimerSec"]       = RCL["Thaddius timer length"],
    ["polarityMode.pendingPullEndAt"]   = RCL["Pending pull end"],
    ["polarityMode.pendingPullSource"]  = RCL["Pending pull source"],
    -- Consumables checker
    ["consumablesChecker.warningThreshold"] = RCL["Low stock warning threshold"],
    ["consumablesChecker.showOnlyMissing"]  = RCL["Only show missing consumables"],
    ["consumablesChecker.disabledItems"]    = RCL["Unchecked items"],
    ["consumablesChecker.openWithAH"]       = RCL["Open with the auction house"],
    ["consumablesChecker.openWithMail"]     = RCL["Open with the mailbox"],
    ["consumablesChecker.essentials.enabled"]  = RCL["Show missing must-have items on screen"],
    ["consumablesChecker.essentials.airhorn"]  = RCL["Sound when a must-have item is missing"],
    ["consumablesChecker.essentials.soundKey"] = RCL["Must-have alert sound"],
    ["consumablesChecker.soundKey"]            = RCL["Missing consumables warning sound"],
    ["consumablesChecker.essentials.iconSize"] = RCL["Must-have icon size"],
    ["consumablesChecker.essentials.items"]    = RCL["Must-have items"],
    ["consumablesChecker.essentials.xOffset"]  = RCL["Must-have alert position"],
    ["consumablesChecker.essentials.yOffset"]  = RCL["Must-have alert position"],
    -- Consumables helper
    ["consumablesHelper.alwaysShowStones"]     = RCL["Always show weapon stones"],
    ["consumablesHelper.hideWhenActive"]       = RCL["Hide while the buff is active"],
    ["consumablesHelper.hideConflictingBuffs"] = RCL["Hide conflicting buffs"],
    ["consumablesHelper.showBeforeExpiry"]     = RCL["Show before expiry (seconds)"],
    ["consumablesHelper.petrificationCampMode"] = RCL["Petrification camp mode"],
    ["consumablesHelper.consumableTTSEnabled"]  = RCL["Consumable voice alerts"],
    ["consumablesHelper.consumableTTSVolume"]   = RCL["Consumable voice volume"],
    ["consumablesHelper.potionReadyTTS"]        = RCL["Say when potion is ready"],
    ["consumablesHelper.consumableTTSRepeatEnabled"]  = RCL["Repeat voice alerts"],
    ["consumablesHelper.consumableTTSRepeatInterval"] = RCL["Voice repeat interval"],
    ["consumablesHelper.consumableTTSRepeatCount"]    = RCL["Voice repeat count"],
    ["consumablesHelper.consumableTTSSettings"]       = RCL["Per-consumable voice settings"],
    ["consumablesHelper.ttsVoiceId"]                  = RCL["Voice"],
    ["consumablesHelper.hiddenWeapons"]               = RCL["Hidden weapons"],
    -- Bars
    ["potionsBar.petrificationCampMode"] = RCL["Petrification camp mode"],
    ["potionsBar.hideWhenActive"]        = RCL["Hide while the buff is active"],
    ["potionsBar.showBeforeExpiry"]      = RCL["Show before expiry (seconds)"],
    ["weaponsBar.showItemNames"]         = RCL["Show item names"],
    ["weaponsBar.hordeByFaction"]        = RCL["Horde mode (per faction)"],
    ["consumablesHelper.hordeByFaction"] = RCL["Horde mode (per faction)"],
    ["weaponsBar.showEquippedWeapons"]   = RCL["Show equipped weapons"],
    ["weaponsBar.showBagWeapons"]        = RCL["Show bag weapons"],
    ["weaponsBar.hiddenWeapons"]         = RCL["Hidden weapons"],
    ["weaponsBar.showBeforeExpiry"]      = RCL["Show before expiry (seconds)"],
    ["trinketBar.maxRows"]               = RCL["Max rows"],
    ["trinketBar.hiddenTrinkets"]        = RCL["Hidden trinkets"],
    ["trinketBar.trinketOrder"]          = RCL["Trinket order"],
    ["trinketBar.showBagOnly"]           = RCL["Bag trinkets only"],
    ["trinketBar.showEquippedOnly"]      = RCL["Equipped trinkets only"],
    ["trinketBar.showSlotNumbers"]       = RCL["Show slot numbers"],
    ["trinketBar.showCooldownText"]      = RCL["Show cooldown text"],
    ["trinketBar.cooldownTextScale"]     = RCL["Cooldown text scale"],
    -- Trinket auto-swap
    ["trinketSwap.enabled"]              = RCL["Auto-swap enabled"],
    ["trinketSwap.autoSwapActive"]       = RCL["Auto-swap active"],
    ["trinketSwap.showToggleButton"]     = RCL["Show toggle button"],
    ["trinketSwap.toggleButtonLocked"]   = RCL["Lock toggle button"],
    ["trinketSwap.toggleButtonPosition"] = RCL["Toggle button position"],
    ["trinketSwap.compactButton"]        = RCL["Compact button"],
    ["trinketSwap.showQueueIcons"]       = RCL["Show queue icons"],
    ["trinketSwap.pauseDuringBossFight"] = RCL["Pause during boss fights"],
    ["trinketSwap.currentQueue"]         = RCL["Active queue"],
    ["trinketSwap.configNames"]          = RCL["Queue names"],
    ["trinketSwap.queues"]               = RCL["Swap queues (trinket lists)"],
    -- Nameplates
    ["nameplateAuras.enabled"]  = RCL["Nameplate auras enabled"],
    ["nameplateAuras.groups"]   = RCL["Debuff groups & layout"],
    -- Boss notes
    ["bossNotes.enabled"]          = RCL["Notes enabled"],
    ["bossNotes.showForTrash"]     = RCL["Show trash notes"],
    ["bossNotes.lingerDuration"]   = RCL["Linger after combat (seconds)"],
    ["bossNotes.trashNote"]        = RCL["Legacy trash note"],
    ["bossNotes.notes"]            = RCL["Boss notes (per boss)"],
    ["bossNotes.trashNotesByRaid"] = RCL["Trash notes (per raid)"],
    ["bossNotes.trashNotesByPack"] = RCL["Trash notes (per pack)"],
    ["bossNotes.trashNotesList"]   = RCL["Trash note lists"],
    ["bossNotes.trashNotesListMig"] = RCL["Trash note list migration flags"],
    ["bossNotes.bossNoteAdded"]    = RCL["Boss note added flags"],
    ["bossNotes.trashNoteKills"]   = RCL["Trash note kill counters"],
    ["bossNotes.trashNoteDur"]     = RCL["Trash note durations"],
    ["bossNotes.ttsTrigger"]       = RCL["Read aloud on"],
    -- Chronoboon
    ["boonReminder.enabled"]        = RCL["Reminder enabled"],
    ["boonReminder.mode"]           = RCL["Remind on"],
    ["boonReminder.showLabel"]      = RCL["Show label"],
    ["boonReminder.disabledBosses"] = RCL["Bosses with the reminder off"],
    -- Fast weapon reminder
    ["fastWeaponReminder.enabled"]           = RCL["Reminder enabled"],
    ["fastWeaponReminder.showIcon"]          = RCL["Show icon"],
    ["fastWeaponReminder.ttsRepeatEnabled"]  = RCL["Repeat voice alerts"],
    ["fastWeaponReminder.ttsRepeatInterval"] = RCL["Voice repeat interval"],
    ["fastWeaponReminder.ttsRepeatCount"]    = RCL["Voice repeat count"],
    ["fastWeaponReminder.ttsFastWeapons"]    = RCL["Say fast weapons"],
    ["fastWeaponReminder.ttsShields"]        = RCL["Say shields"],
    ["fastWeaponReminder.ttsHealingWeapons"] = RCL["Say healing weapons"],
    ["fastWeaponReminder.ttsWrathGear"]      = RCL["Say Wrath gear"],
    ["fastWeaponReminder.ttsUtilityItems"]   = RCL["Say utility items"],
    -- Spec detection
    ["specDetection.enabled"]         = RCL["Spec detection enabled"],
    ["specDetection.displayDuration"] = RCL["Display duration (seconds)"],
    ["specDetection.showOnRaidEntry"] = RCL["Show on raid entry"],
    ["specDetection.showTalents"]     = RCL["Show talents"],
    ["specDetection.playSound"]       = RCL["Play sound on display"],
    ["specDetection.maxTalentsShown"] = RCL["Max talents shown"],
    ["specDetection.hiddenTalents"]   = RCL["Hidden talents"],
    ["specDetection.talentOrder"]     = RCL["Talent order"],
    -- Battle Shout reminder
    ["battleShoutReminder.enabled"]           = RCL["Reminder enabled"],
    ["battleShoutReminder.hideWhenAllBuffed"] = RCL["Hide when everyone is buffed"],
    ["battleShoutReminder.buffThreshold"]     = RCL["Remaining-time threshold"],
    ["battleShoutReminder.showMissingNames"]  = RCL["Show missing player names"],
    ["battleShoutReminder.namesFontSize"]     = RCL["Names font size"],
    ["battleShoutReminder.namesPosition"]     = RCL["Names position"],
    ["battleShoutReminder.shortenNames"]      = RCL["Shorten names"],
    ["battleShoutReminder.showAPValue"]       = RCL["Show attack power value"],
    ["battleShoutReminder.visibilityRaids"]   = RCL["Which raids count"],
    ["battleShoutReminder.trackScope"]        = RCL["Track my group or just me"],
    ["battleShoutReminder.greedMode"]         = RCL["Greed mode"],
    ["battleShoutReminder.greedSkipIfImpCleave"] = RCL["Greed: skip with Improved Cleave"],
    ["battleShoutReminder.rangeCheck"]        = RCL["Range check"],
    -- TTK display
    ["ttkDisplay.enabled"]           = RCL["TTK display enabled"],
    ["ttkDisplay.headerFontSize"]    = RCL["Header font size"],
    ["ttkDisplay.showConfidence"]    = RCL["Show confidence"],
    ["ttkDisplay.showHealthPercent"] = RCL["Show health percent"],
    ["ttkDisplay.showOutOfCombat"]   = RCL["Show out of combat"],
    ["ttkDisplay.showLabels"]        = RCL["Show labels"],
    ["ttkDisplay.shortLabels"]       = RCL["Short labels"],
    ["ttkDisplay.centerText"]        = RCL["Center text"],
    ["ttkDisplay.showPace"]          = RCL["Show pace"],
    ["ttkDisplay.showHeader"]        = RCL["Show title bar"],
    -- Buff pushoff alert
    ["buffPushoffAlert.enabled"]    = RCL["Alert enabled"],
    ["buffPushoffAlert.showIcon"]   = RCL["Show icon"],
    ["buffPushoffAlert.showText"]   = RCL["Show text"],
    ["buffPushoffAlert.textFormat"] = RCL["Text format"],
    ["buffPushoffAlert.duration"]   = RCL["Alert duration (seconds)"],
    ["buffPushoffAlert.dmfDebuff"]  = RCL["Darkmoon Faire debuff warning"],
    ["buffPushoffAlert.showPusher"] = RCL["Name what pushed the buff off"],
    ["buffPushoffAlert.ttsPusher"]  = RCL["Say what pushed the buff off"],
    -- Gear swap notices
    ["swapToast.enabled"]           = RCL["Swap notices enabled"],
    ["swapToast.duration"]          = RCL["Notice duration (seconds)"],
    ["swapToast.scale"]             = RCL["Notice scale"],
    ["swapToast.showNames"]         = RCL["Name each piece"],
    ["swapToast.showBackground"]    = RCL["Notice background box"],
    ["swapToast.soundKey"]          = RCL["Notice sound"],
    ["swapToast.locked"]            = RCL["Lock notice position"],
    ["swapToast.width"]             = RCL["Notice width"],
    ["buffCap.countHidden"]         = RCL["Count hidden buff slots"],
    ["buffCap.learn"]               = RCL["Learn unseen hidden slots"],
    ["buffCap.chatWarn"]            = RCL["Chat line when a buff is pushed off"],
    ["buffCap.barText"]             = RCL["What the Buffs cell shows"],
    -- Fonts
    ["fontSettings.selectedFont"]        = RCL["Font"],
    ["fontSettings.fontSize"]            = RCL["Base font size"],
    ["fontSettings.fontOutline"]         = RCL["Font outline"],
    ["fontSettings.mainWindowBgOpacity"] = RCL["Main window opacity"],
    -- Minimap button
    ["minimapButton.hide"]       = RCL["Hide minimap button"],
    ["minimapButton.position"]   = RCL["Button angle"],
    ["minimapButton.minimapPos"] = RCL["Button angle (library)"],
    ["minimapButton.lock"]       = RCL["Lock minimap button"],
    -- Gear swap retries
    ["gearSwapRetry.attempts"] = RCL["Retry attempts"],
    ["gearSwapRetry.interval"] = RCL["Retry interval (seconds)"],
    ["gearSwapRetry.warn"]     = RCL["Warn when a swap fails"],
    -- Gear manager (settings live one level down)
    ["gearManager.settings"]                            = RCL["Gear manager settings"],
    ["gearManager.settings.characterSheetMenus"]        = RCL["Character sheet menus"],
    ["gearManager.settings.showTooltips"]               = RCL["Show tooltips"],
    ["gearManager.settings.tooltipsOutOfCombatOnly"]    = RCL["Tooltips out of combat only"],
    ["gearManager.settings.buttonSize"]                 = RCL["Button size"],
    ["gearManager.settings.buttonSpacing"]              = RCL["Button spacing"],
    ["gearManager.settings.shiftCancelQueue"]           = RCL["Shift-click cancels queue"],
    ["gearManager.settings.buttonsLocked"]              = RCL["Lock buttons"],
    ["gearManager.settings.equipToggle"]                = RCL["Click again to unequip"],
    ["gearManager.settings.showButtonNames"]            = RCL["Show button names"],
    ["gearManager.settings.showGearSetName"]            = RCL["Show gear set name"],
    ["gearManager.settings.showGearSetStatusBorder"]    = RCL["Gear set status border"],
    ["gearManager.settings.showMenuNames"]              = RCL["Show menu names"],
    ["gearManager.settings.showCharSlotNames"]          = RCL["Character sheet slot names"],
    ["gearManager.settings.showCharPaneNames"]          = RCL["Character pane names"],
    ["gearManager.settings.showCooldownTextButtons"]    = RCL["Cooldown text on buttons"],
    ["gearManager.settings.showCooldownTextMenus"]      = RCL["Cooldown text in menus"],
    ["gearManager.settings.trinketDockSplitClick"]      = RCL["Trinket dock split click"],
    ["gearManager.settings.hiddenMenuItems"]            = RCL["Items hidden from hover menus"],
    ["gearManager.settings.hiddenMenuSets"]             = RCL["Sets hidden from hover menus"],
    ["gearManager.settings.menuRevealKey"]              = RCL["Key that shows hidden menu entries"],
    ["gearManager.settings.fungalBloomEnabled"]         = RCL["Fungal Bloom swap"],
    ["gearManager.settings.fungalBloomActiveSet"]       = RCL["Fungal Bloom active set"],
    ["gearManager.settings.fungalBloomSet"]             = RCL["Fungal Bloom set"],
    ["gearManager.settings.lastEquippedSetName"]        = RCL["Last equipped set"],
    ["gearManager.settings.fungalBloomWasActive"]       = RCL["Fungal Bloom was active"],
    ["gearManager.settings.slotInfo"]                   = RCL["Slot info"],
    -- Custom reminders
    ["customReminders.reminders"] = RCL["Reminder list"],
    ["customReminders.nextId"]    = RCL["Reminder id counter"],
    -- Stats bar colours: one row per stat (each holds a low/high pair)
    ["statsBarColors.ap"]         = RCL["Attack power color"],
    ["statsBarColors.hit"]        = RCL["Hit color"],
    ["statsBarColors.crit"]       = RCL["Crit color"],
    ["statsBarColors.buffs"]      = RCL["Buff count color"],
    ["statsBarColors.dmg"]        = RCL["Damage color"],
    ["statsBarColors.sp"]         = RCL["Spell power color"],
    ["statsBarColors.spellcrit"]  = RCL["Spell crit color"],
    ["statsBarColors.mp5"]        = RCL["MP5 color"],
    ["statsBarColors.rap"]        = RCL["Ranged attack power color"],
    ["statsBarColors.rcrit"]      = RCL["Ranged crit color"],
    ["statsBarColors.durability"] = RCL["Durability color"],
    ["statsBarColors.gold"]       = RCL["Gold color"],
    ["statsBarColors.fps"]        = RCL["FPS color"],
    ["statsBarColors.ms"]         = RCL["Latency color"],
    -- Custom colours: one row per colour group
    ["customColors.ui"]         = RCL["Windows & panels colors"],
    ["customColors.buttons"]    = RCL["Button colors"],
    ["customColors.sidebar"]    = RCL["Sidebar colors"],
    ["customColors.settings"]   = RCL["Settings window colors"],
    ["fontSettings.mainWindowScale"] = RCL["Settings window scale"],
    ["fontSettings.windowLayout"]    = RCL["Settings window layout version"],
    ["customColors.checkbox"]   = RCL["Checkbox colors"],
    ["customColors.dropdown"]   = RCL["Dropdown colors"],
    ["customColors.nameplate"]  = RCL["Nameplate aura colors"],
    ["customColors.scrollbar"]  = RCL["Scrollbar colors"],
    ["customColors.text"]       = RCL["Text colors"],
    ["customColors.tooltip"]    = RCL["Tooltip colors"],
    ["customColors.raids"]      = RCL["Raid config colors"],
    ["customColors.consumables"] = RCL["Consumables checker colors"],
    ["customColors.actionBars"] = RCL["Shared bar colors"],
    ["customColors.weaponBar"]  = RCL["Weapon bar colors"],
    ["customColors.consumablesBar"] = RCL["Consumables bar colors"],
    ["customColors.potionsBar"] = RCL["Potions bar colors"],
    ["customColors.gearManager"] = RCL["Gear manager colors"],
    ["customColors.trinketSwap"] = RCL["Trinket swap colors"],
    ["customColors.statsBar"]   = RCL["Stats bar frame colors"],
    ["customColors.ttkDisplay"] = RCL["TTK display colors"],
    ["customColors.buffPushoffAlert"] = RCL["Buff pushoff alert colors"],
    ["customColors.battleShoutReminder"] = RCL["Battle Shout reminder colors"],
    ["customColors.battleShoutPartyTracker"] = RCL["Battle Shout party tracker colors"],
    ["customColors.auraTracker"] = RCL["Buff & debuff tracker colors"],
    ["customColors.uiMover"]    = RCL["Frame mover colors"],
    -- reminder pages: fonts, sizes and animations
    ["battleShoutReminder.countFont"]          = RCL["Count text font"],
    ["battleShoutReminder.namesFont"]          = RCL["Names font"],
    ["battleShoutReminder.borderSize"]         = RCL["Border thickness"],
    ["battleShoutReminder.namesOffset"]        = RCL["Gap between icon and names"],
    ["battleShoutReminder.showAnim"]           = RCL["Entrance animation"],
    ["battleShoutReminder.hideAnim"]           = RCL["Exit animation"],
    ["battleShoutReminder.alertAnim"]          = RCL["Warning animation"],
    ["battleShoutPartyTracker.rowFont"]        = RCL["Names and status font"],
    ["battleShoutPartyTracker.titleFont"]      = RCL["Title font"],
    ["battleShoutPartyTracker.borderSize"]     = RCL["Border thickness"],
    ["battleShoutPartyTracker.barAlpha"]       = RCL["Duration bar opacity"],
    ["battleShoutPartyTracker.showAnim"]       = RCL["Entrance animation"],
    ["battleShoutPartyTracker.hideAnim"]       = RCL["Exit animation"],
    ["raidBuffTracker.font"]                   = RCL["Names and time font"],
    ["raidBuffTracker.stackFont"]              = RCL["Stack count font"],
    ["raidBuffTracker.colors"]                 = RCL["Time colours"],
    ["raidBuffTracker.showAnim"]               = RCL["Entrance animation"],
    ["raidBuffTracker.hideAnim"]               = RCL["Exit animation"],
    ["raidBuffTracker.urgentAnim"]             = RCL["Urgent animation"],
    ["bossDebuffTracker.font"]                 = RCL["Names and time font"],
    ["bossDebuffTracker.stackFont"]            = RCL["Stack count font"],
    ["bossDebuffTracker.colors"]               = RCL["Time colours"],
    ["bossDebuffTracker.showAnim"]             = RCL["Entrance animation"],
    ["bossDebuffTracker.hideAnim"]             = RCL["Exit animation"],
    ["bossDebuffTracker.urgentAnim"]           = RCL["Urgent animation"],
    ["ttkDisplay.valueFont"]                   = RCL["Times font"],
    ["ttkDisplay.labelFont"]                   = RCL["Labels font"],
    ["ttkDisplay.headerFont"]                  = RCL["Title font"],
    ["ttkDisplay.borderSize"]                  = RCL["Border thickness"],
    ["ttkDisplay.showAnim"]                    = RCL["Entrance animation"],
    ["ttkDisplay.hideAnim"]                    = RCL["Exit animation"],
    ["boonReminder.label"]                     = RCL["Icon text"],
    ["boonReminder.animationType"]             = RCL["Popup animation style"],
    ["raidRoute.trackerSwapAnim"]              = RCL["Swap line animation"],
}

-- Friendly names for field names that recur across many settings tables
-- (every on-screen frame has xOffset/locked/scale/...). GetSettingLabel
-- consults these by the LAST path segment after SETTING_FIELD_LABELS misses,
-- so a common field reads the same everywhere without one entry per table.
RC.SETTING_LEAF_LABELS = RC.SETTING_LEAF_LABELS or {
    enabled            = RCL["Enabled"],
    locked             = RCL["Lock frame"],
    anchorPoint        = RCL["Anchor point"],
    xOffset            = RCL["Horizontal position"],
    yOffset            = RCL["Vertical position"],
    x                  = RCL["Horizontal position"],
    y                  = RCL["Vertical position"],
    scale              = RCL["Scale"],
    opacity            = RCL["Opacity"],
    fontSize           = RCL["Font size"],
    iconSize           = RCL["Icon size"],
    iconSpacing        = RCL["Icon spacing"],
    buttonSize         = RCL["Button size"],
    buttonsPerRow      = RCL["Buttons per row"],
    growDirection      = RCL["Grow direction"],
    showBackground     = RCL["Show background"],
    showCount          = RCL["Show item count"],
    hideInCombat       = RCL["Hide in combat"],
    visibilityMode     = RCL["Where to show it"],
    visibilityRaids    = RCL["Which raids count"],
    mouseoverFade      = RCL["Fade until mouseover"],
    mouseoverFadeAlpha = RCL["Faded opacity"],
    hiddenItems        = RCL["Hidden items"],
    itemOrder          = RCL["Item order"],
    playSound          = RCL["Play sound"],
    soundKey           = RCL["Alert sound"],
    soundFile          = RCL["Custom sound file"],
    ttsEnabled         = RCL["Text-to-speech"],
    tts                = RCL["Text-to-speech"],
    animationType      = RCL["Animation style"],
    width              = RCL["Width"],
    height             = RCL["Height"],
    showTooltips       = RCL["Show tooltips"],
    showLabel          = RCL["Show label"],
    showIcon           = RCL["Show icon"],
}

-- Paths the sync picker treats as ONE unit: lists, per-entry configs,
-- tracked sets, timers, history - user data rather than settings. They get
-- a single row (labelled by the container) and are never split into
-- per-field rows. "<parent>.*" marks every direct child of <parent> as
-- opaque (each child still gets its own row). Declared here rather than
-- guessed at runtime so the list a player sees is stable and reviewable.
RC.SETTING_OPAQUE_PATHS = RC.SETTING_OPAQUE_PATHS or {
    -- whole db keys
    abilityOverrides     = true,   -- per-ability overrides
    customColors         = "children", -- one row per colour group, never per colour
    reminderMotion       = "children", -- entrance / exit: one row each
    reminderText         = "children", -- font / colour: one row each
    nonWarriorEnabled    = true,   -- feature set for non-warriors
    gearSets             = true,
    gearButtons          = true,
    gearButtonPositions  = true,
    gearPinnedButtons    = true,
    speedSwapTargets     = true,
    smartMacros          = true,
    raidProfiles         = true,   -- raid & boss configs
    statsBarPosition     = true,   -- one saved position
    statsBarStats        = true,   -- ordered list of shown stats
    statsBarColors       = "children", -- one row per stat colour pair
    sidebarPosition      = true,
    consumableSettings   = true,   -- per-item preferences
    -- fields inside settings tables
    ["customReminders.reminders"]        = true,
    ["executeSettings.fightHistory"]     = true,
    ["executeSettings.classicBossMultipliers"] = true,
    ["executeSettings.dataCollection.disabledBosses"] = true,
    ["nameplateAuras.groups"]            = true,
    ["consumablesHelper.hiddenItems"]    = true,
    -- { Horde = bool, Alliance = bool }: one unit, each faction's choice
    ["consumablesHelper.hordeByFaction"] = true,
    ["weaponsBar.hordeByFaction"]        = true,
    ["consumablesHelper.hiddenWeapons"]  = true,
    ["consumablesHelper.itemOrder"]      = true,
    ["consumablesHelper.consumableTTSSettings"] = true,
    ["potionsBar.hiddenItems"]           = true,
    ["potionsBar.itemOrder"]             = true,
    ["potionsBar.visibilityRaids"]       = true,
    ["weaponsBar.hiddenWeapons"]         = true,
    ["weaponsBar.visibilityRaids"]       = true,
    ["trinketBar.hiddenTrinkets"]        = true,
    ["trinketBar.trinketOrder"]          = true,
    ["trinketBar.visibilityRaids"]       = true,
    ["battleShoutReminder.visibilityRaids"]    = true,
    ["battleShoutPartyTracker.visibilityRaids"] = true,
    ["raidBuffTracker.visibilityRaids"]  = true,
    ["raidBuffTracker.tracked"]          = true,
    ["raidBuffTracker.custom"]           = true,
    ["raidBuffTracker.whisperFor"]       = true,
    ["bossDebuffTracker.visibilityRaids"] = true,
    ["bossDebuffTracker.tracked"]        = true,
    ["bossDebuffTracker.custom"]         = true,
    ["bossDebuffTracker.whisperFor"]     = true,
    ["bossNotes.notes"]                  = true,
    ["bossNotes.trashNotesByRaid"]       = true,
    ["bossNotes.trashNotesByPack"]       = true,
    ["bossNotes.trashNotesList"]         = true,
    ["bossNotes.trashNotesListMig"]      = true,
    ["bossNotes.bossNoteAdded"]          = true,
    ["bossNotes.trashNoteKills"]         = true,
    ["bossNotes.trashNoteDur"]           = true,
    ["boonReminder.disabledBosses"]      = true,
    ["consumablesChecker.disabledItems"] = true,
    ["consumablesChecker.essentials.items"] = true,
    ["frostBlastConfig.cancelAuraBuffs"] = true,
    ["frostBlastConfig.history"]         = true,
    ["frostBlastConfig.maxHpSamples"]    = true,
    ["trinketSwap.toggleButtonPosition"] = true,
    ["trinketSwap.configNames"]          = true,
    ["trinketSwap.queues"]               = true,
    ["raidRoute.reminderPos"]            = true,
    ["raidRoute.trackerCustomSize"]      = true,
    ["specDetection.hiddenTalents"]      = true,
    ["specDetection.talentOrder"]        = true,
    ["gearManager.settings.slotInfo"]    = true,
    -- reminder pages: font and animation specs are one unit
    ["battleShoutReminder.countFont"]          = true,
    ["battleShoutReminder.namesFont"]          = true,
    ["battleShoutReminder.showAnim"]           = true,
    ["battleShoutReminder.hideAnim"]           = true,
    ["battleShoutReminder.alertAnim"]          = true,
    ["battleShoutPartyTracker.rowFont"]        = true,
    ["battleShoutPartyTracker.titleFont"]      = true,
    ["battleShoutPartyTracker.showAnim"]       = true,
    ["battleShoutPartyTracker.hideAnim"]       = true,
    ["raidBuffTracker.font"]                   = true,
    ["raidBuffTracker.stackFont"]              = true,
    ["raidBuffTracker.colors"]                 = true,
    ["raidBuffTracker.showAnim"]               = true,
    ["raidBuffTracker.hideAnim"]               = true,
    ["raidBuffTracker.urgentAnim"]             = true,
    ["bossDebuffTracker.font"]                 = true,
    ["bossDebuffTracker.stackFont"]            = true,
    ["bossDebuffTracker.colors"]               = true,
    ["bossDebuffTracker.showAnim"]             = true,
    ["bossDebuffTracker.hideAnim"]             = true,
    ["bossDebuffTracker.urgentAnim"]           = true,
    ["ttkDisplay.valueFont"]                   = true,
    ["ttkDisplay.labelFont"]                   = true,
    ["ttkDisplay.headerFont"]                  = true,
    ["ttkDisplay.showAnim"]                    = true,
    ["ttkDisplay.hideAnim"]                    = true,
    ["raidRoute.trackerSwapAnim"]              = true,
}

-- Paths that are registered (so they export) but never travel over the
-- mesh, with the reason. The sync picker skips them so a row can never
-- promise something the payload builder does not ship.
RC.SETTING_UNSYNCED_PATHS = RC.SETTING_UNSYNCED_PATHS or {
    sidebarState         = "Per-click UI churn - omitted by the sidebar payload",
    lastSidebarSelection = "Per-click UI churn - omitted by the sidebar payload",
    sidebarNav           = "Per-click UI churn - omitted by the sidebar payload",
    profilePicker        = "Per-click UI churn - omitted by the sidebar payload",
    ["raidRoute.runtime"] = "Live route progress - stripped by SlimRouteCfg",
    executeCalculator    = "Never a db field - the executeCalc payload is built from executeSettings",
}

-- Where the sync picker learns a settings table's FIELD NAMES when the live
-- db copy is sparse. customColors only holds overrides, so its group list
-- comes from the colour defaults instead.
RC.SETTING_FIELD_SOURCES = RC.SETTING_FIELD_SOURCES or {
    customColors = function() return RC.defaultColors end,
    -- the colour override is unset until picked
    reminderText = function() return { font = {}, color = {} } end,
    -- reminder pages: font and animation specs unset until picked
    battleShoutReminder     = function() return { countFont = {}, namesFont = {}, showAnim = {}, hideAnim = {}, alertAnim = {} } end,
    battleShoutPartyTracker = function() return { rowFont = {}, titleFont = {}, showAnim = {}, hideAnim = {} } end,
    raidBuffTracker         = function() return { font = {}, stackFont = {}, colors = {}, showAnim = {}, hideAnim = {}, urgentAnim = {} } end,
    bossDebuffTracker       = function() return { font = {}, stackFont = {}, colors = {}, showAnim = {}, hideAnim = {}, urgentAnim = {} } end,
    ttkDisplay              = function() return { valueFont = {}, labelFont = {}, headerFont = {}, showAnim = {}, hideAnim = {} } end,
    raidRoute               = function() return { trackerSwapAnim = {} } end,
}

-- ============================================================
-- Field groups for the Sync Rules page
-- ============================================================
-- Every feature (category) is shown as a header plus at most one row per
-- group below: its plain settings, its position & lock, its appearance,
-- and its saved data. GetSettingGroup classifies a path by the LAST
-- segment of its name; SETTING_GROUP_OVERRIDES corrects the cases the
-- pattern gets wrong. Opaque (user-data) paths are "data" unless
-- overridden.
RC.SETTING_GROUP_ORDER = { "settings", "position", "appearance", "data" }
RC.SETTING_GROUP_LABELS = {
    settings   = RCL["Settings"],
    position   = RCL["Position & Lock"],
    appearance = RCL["Appearance"],
    data       = RCL["Saved data"],
}

-- Exact (lower-cased) leaf names.
local POSITION_LEAVES = {
    anchorpoint = true, point = true, relativepoint = true, relpoint = true,
    xoffset = true, yoffset = true, x = true, y = true, xofs = true, yofs = true,
    offsetx = true, offsety = true, centred = true, centered = true,
    locked = true, growdown = true, growdirection = true, growup = true,
    lock = true,
}
local APPEARANCE_LEAVES = {
    scale = true, opacity = true, alpha = true, fontsize = true,
    iconsize = true, compacticonsize = true, compactperrow = true,
    rowwidth = true, width = true, height = true, spacing = true,
    padding = true, layout = true, layoutmode = true, iconspacing = true,
    showicontext = true, animationtype = true, fadeintime = true,
    fadetime = true, colors = true, texture = true, bartexture = true,
    orientation = true, direction = true, columns = true, rows = true,
    perrow = true, showtitle = true, showlabels = true, showicon = true,
    showtimer = true, compact = true, showbackground = true,
    showheader = true, showlabel = true, buttonsize = true,
    buttonsperrow = true, buttonspacing = true, maxrows = true,
    rowheight = true, headerfontsize = true, namesfontsize = true,
    mouseoverfade = true, mouseoverfadealpha = true, durationstyle = true,
    bloodragestyle = true, compactbutton = true, centertext = true,
    shortlabels = true, showcount = true, showitemnames = true,
    showslotnumbers = true, showcooldowntext = true, cooldowntextscale = true,
    showbuttonnames = true, showgearsetname = true, showmenunames = true,
    showcharslotnames = true, showcharpanenames = true,
    showcooldowntextbuttons = true, showcooldowntextmenus = true,
    showgearsetstatusborder = true, showqueueicons = true,
    fontoutline = true, selectedfont = true, mainwindowbgopacity = true,
    textformat = true, showbg = true,
}
-- Leaf prefixes / suffixes (lower-cased).
local POSITION_SUFFIXES   = { "position", "pos", "locked" }
local APPEARANCE_PREFIXES = { "font", "border", "background" }
local APPEARANCE_SUFFIXES = { "color", "colors", "size", "spacing", "height",
                              "width", "opacity", "scale", "background" }

-- Hand corrections. Exact path, or "<parent>.*" for every direct child.
RC.SETTING_GROUP_OVERRIDES = RC.SETTING_GROUP_OVERRIDES or {
    -- one saved anchor each: position, even though the picker holds them opaque
    statsBarPosition                     = "position",
    sidebarPosition                      = "position",
    ["trinketSwap.toggleButtonPosition"] = "position",
    ["raidRoute.reminderPos"]            = "position",
    ["raidRoute.trackerCustomSize"]      = "appearance",
    -- colour groups and stat colour pairs are looks, not data
    ["customColors.*"]                   = "appearance",
    ["motion.*"]                         = "appearance",
    ["reminderMotion.*"]                 = "appearance",
    ["reminderText.*"]                   = "appearance",
    ["statsBarColors.*"]                 = "appearance",
    -- names shown to the right/below: a look choice, not an anchor
    ["battleShoutReminder.namesPosition"] = "appearance",
    -- stats bar top-level keys that the leaf pattern cannot see through
    statsBarShowBg                       = "appearance",
    statsBarShowPushoffIcon              = "appearance",
    statsBarDurability                   = "settings",
    statsBarGold                         = "settings",
    configWindowWidth                    = "appearance",
    configWindowHeight                   = "appearance",
    -- minimap button angle is a position
    ["minimapButton.position"]           = "position",
    ["minimapButton.minimapPos"]         = "position",
    -- TTK display content toggles are what it shows, not how it looks
    ["ttkDisplay.showConfidence"]        = "settings",
    ["ttkDisplay.showHealthPercent"]     = "settings",
    ["ttkDisplay.showOutOfCombat"]       = "settings",
    ["ttkDisplay.showPace"]              = "settings",
    -- thresholds/timers that happen to end in "size"/"height"
    ["consumablesHelper.showBeforeExpiry"] = "settings",
    ["executeSettings.fightHistory"]     = "data",
    ["gearManager.settings.slotInfo"]    = "data",
    -- the retry block is behaviour
    ["gearSwapRetry.*"]                  = "settings",
    -- directions of growth for list frames read as layout to players
    ["raidBuffTracker.growDown"]         = "appearance",
    ["bossDebuffTracker.growDown"]       = "appearance",
    ["raidBuffTracker.growLeft"]         = "appearance",
    ["bossDebuffTracker.growLeft"]       = "appearance",
    ["raidBuffTracker.compactDirection"]   = "appearance",
    ["bossDebuffTracker.compactDirection"] = "appearance",
    -- "which raids count" / "which stats are shown" are choices the player
    -- made, not accumulated data, even though the picker holds them opaque
    ["potionsBar.visibilityRaids"]              = "settings",
    ["weaponsBar.visibilityRaids"]              = "settings",
    ["trinketBar.visibilityRaids"]              = "settings",
    ["battleShoutReminder.visibilityRaids"]     = "settings",
    ["battleShoutPartyTracker.visibilityRaids"] = "settings",
    ["raidBuffTracker.visibilityRaids"]         = "settings",
    ["bossDebuffTracker.visibilityRaids"]       = "settings",
    ["raidBuffTracker.whisperFor"]              = "settings",
    ["bossDebuffTracker.whisperFor"]            = "settings",
    ["weaponsBar.hordeByFaction"]               = "settings",
    ["consumablesChecker.essentials.items"]     = "settings",
    ["consumablesHelper.hordeByFaction"]        = "settings",
    statsBarStats                        = "settings",
    -- gear swap sets inside boss configs are data, like the configs
    ["raidProfiles.gear"]                = "data",
    -- counters, runtime state and migration flags are data, not options
    ["customReminders.nextId"]           = "data",
    smartMacrosNextId                    = "data",
    ["gearManager.settings.fungalBloomActiveSet"] = "data",
    ["gearManager.settings.fungalBloomWasActive"] = "data",
    ["gearManager.settings.lastEquippedSetName"]  = "data",
    ["frostBlastConfig.peakMaxHp"]       = "data",
    ["raidRoute.offByDefaultDone"]       = "data",
    -- reminder pages
    ["battleShoutReminder.countFont"]          = "appearance",
    ["battleShoutReminder.namesFont"]          = "appearance",
    ["battleShoutReminder.borderSize"]         = "appearance",
    ["battleShoutReminder.namesOffset"]        = "appearance",
    ["battleShoutReminder.showAnim"]           = "appearance",
    ["battleShoutReminder.hideAnim"]           = "appearance",
    ["battleShoutReminder.alertAnim"]          = "appearance",
    ["battleShoutPartyTracker.rowFont"]        = "appearance",
    ["battleShoutPartyTracker.titleFont"]      = "appearance",
    ["battleShoutPartyTracker.borderSize"]     = "appearance",
    ["battleShoutPartyTracker.barAlpha"]       = "appearance",
    ["battleShoutPartyTracker.showAnim"]       = "appearance",
    ["battleShoutPartyTracker.hideAnim"]       = "appearance",
    ["raidBuffTracker.font"]                   = "appearance",
    ["raidBuffTracker.stackFont"]              = "appearance",
    ["raidBuffTracker.colors"]                 = "appearance",
    ["raidBuffTracker.showAnim"]               = "appearance",
    ["raidBuffTracker.hideAnim"]               = "appearance",
    ["raidBuffTracker.urgentAnim"]             = "appearance",
    ["bossDebuffTracker.font"]                 = "appearance",
    ["bossDebuffTracker.stackFont"]            = "appearance",
    ["bossDebuffTracker.colors"]               = "appearance",
    ["bossDebuffTracker.showAnim"]             = "appearance",
    ["bossDebuffTracker.hideAnim"]             = "appearance",
    ["bossDebuffTracker.urgentAnim"]           = "appearance",
    ["ttkDisplay.valueFont"]                   = "appearance",
    ["ttkDisplay.labelFont"]                   = "appearance",
    ["ttkDisplay.headerFont"]                  = "appearance",
    ["ttkDisplay.borderSize"]                  = "appearance",
    ["ttkDisplay.showAnim"]                    = "appearance",
    ["ttkDisplay.hideAnim"]                    = "appearance",
    ["boonReminder.label"]                     = "settings",
    ["boonReminder.animationType"]             = "appearance",
    ["raidRoute.trackerSwapAnim"]              = "appearance",
}

local function LeafOf(path)
    return string.lower(path:match("([^%.]+)$") or path)
end

local function EndsWith(s, suffix)
    return #s >= #suffix and string.sub(s, -#suffix) == suffix
end
local function StartsWith(s, prefix)
    return string.sub(s, 1, #prefix) == prefix
end

function RC:GetSettingGroup(path)
    if not path then return "settings" end
    local ov = RC.SETTING_GROUP_OVERRIDES
    if ov[path] then return ov[path] end
    local parent = path:match("^(.+)%.[^%.]+$")
    if parent and ov[parent .. ".*"] then return ov[parent .. ".*"] end
    if RC:IsOpaqueSettingPath(path) then return "data" end
    local leaf = LeafOf(path)
    if POSITION_LEAVES[leaf] then return "position" end
    if APPEARANCE_LEAVES[leaf] then return "appearance" end
    for _, s in ipairs(POSITION_SUFFIXES) do
        if EndsWith(leaf, s) then return "position" end
    end
    for _, p in ipairs(APPEARANCE_PREFIXES) do
        if StartsWith(leaf, p) then return "appearance" end
    end
    for _, s in ipairs(APPEARANCE_SUFFIXES) do
        if EndsWith(leaf, s) then return "appearance" end
    end
    return "settings"
end

function RC:GetSettingGroupLabel(group)
    return RC.SETTING_GROUP_LABELS[group] or RC.HumanizeSettingName(group)
end

-- true when the picker must not descend into `path`. A "children" entry on
-- the parent makes every direct child opaque; "<parent>.*" does the same.
function RC:IsOpaqueSettingPath(path)
    if not path then return false end
    local t = RC.SETTING_OPAQUE_PATHS
    local own = t[path]
    if own == true then return true end
    local parent = path:match("^(.+)%.[^%.]+$")
    if parent then
        if t[parent] == "children" then return true end
        if t[parent .. ".*"] == true then return true end
    end
    return false
end

-- ============================================================
-- Derivation
-- ============================================================

-- Builds the category list the export UI and mesh sync consume. Category
-- order and key order are preserved exactly as declared above: the mesh HELLO
-- digest is a positional array, so reordering changes every peer's layout
-- fingerprint and forces a full resync.
function RC:BuildExportCategories()
    local byCat, out = {}, {}
    for _, cat in ipairs(RC.SETTING_CATEGORIES) do
        local entry = {
            id      = cat.id,
            group   = cat.group,
            label   = cat.label,
            keys    = {},
            retired = cat.retired,
            addon   = cat.addon,
            feature = cat.feature,
        }
        byCat[cat.id] = entry
        out[#out + 1] = entry
    end
    for _, s in ipairs(RC.SETTINGS) do
        local entry = byCat[s.cat]
        if entry then
            entry.keys[#entry.keys + 1] = s.key
        else
            RC:DebugPrint("Settings registry: '" .. tostring(s.key)
                .. "' names unknown category '" .. tostring(s.cat) .. "'", "profile")
        end
    end
    return out
end

-- Every db key that may be exported, in declaration order.
function RC:BuildExportableKeys()
    local out = {}
    for _, s in ipairs(RC.SETTINGS) do out[#out + 1] = s.key end
    return out
end

RC.EXPORT_CATEGORIES = RC:BuildExportCategories()
RC.EXPORTABLE_KEYS   = RC:BuildExportableKeys()

do
    local byKey = {}
    for _, s in ipairs(RC.SETTINGS) do byKey[s.key] = s end
    RC.SETTINGS_BY_KEY = byKey
end

-- "battleShoutPartyTracker.showOnlyMissing" -> "Show only missing"
local function Humanize(name)
    local s = tostring(name)
    s = s:gsub("(%l)(%u)", "%1 %2"):gsub("(%u)(%u%l)", "%1 %2")
    return s:sub(1, 1):upper() .. s:sub(2)
end
RC.HumanizeSettingName = Humanize

-- Label for a top-level key or a dotted sub-path. Lookup order: exact
-- path in SETTING_FIELD_LABELS, registry label for a bare key, the last
-- segment in SETTING_LEAF_LABELS, then a humanised last segment.
function RC:GetSettingLabel(path)
    if not path then return "" end
    local override = RC.SETTING_FIELD_LABELS[path]
    if override then return override end
    local head, rest = path:match("^([^%.]+)%.(.+)$")
    if not head then
        local s = RC.SETTINGS_BY_KEY[path]
        return (s and s.label) or Humanize(path)
    end
    local leaf = rest:match("([^%.]+)$") or rest
    local common = RC.SETTING_LEAF_LABELS and RC.SETTING_LEAF_LABELS[leaf]
    if common then return common end
    return Humanize(leaf)
end

-- true when GetSettingLabel would have to guess (humanise) for this path.
-- The audit uses it to list sync-picker rows that still need a real name.
function RC:SettingPathHasLabel(path)
    if not path then return false end
    if RC.SETTING_FIELD_LABELS[path] then return true end
    local head, rest = path:match("^([^%.]+)%.(.+)$")
    if not head then return RC.SETTINGS_BY_KEY[path] ~= nil end
    local leaf = rest:match("([^%.]+)$") or rest
    return (RC.SETTING_LEAF_LABELS and RC.SETTING_LEAF_LABELS[leaf]) ~= nil
end

-- ============================================================
-- Drift audit
-- ============================================================

-- Reports settings that exist in RC.defaults but no category carries (so they
-- can never be exported or synced), and registry entries with no default.
-- This is the check that would have caught speedSwapTargets being unsyncable.
function RC:AuditSettingsRegistry(verbose)
    local issues = { orphanDefaults = {}, noDefault = {}, unknownCat = {}, noLabel = {}, noGroup = {} }

    local covered = {}
    for _, s in ipairs(RC.SETTINGS) do covered[s.key] = true end

    if RC.defaults then
        for k in pairs(RC.defaults) do
            if not covered[k] and not RC.NONSYNCED_SETTINGS[k] then
                issues.orphanDefaults[#issues.orphanDefaults + 1] = k
            end
        end
    end

    local catIds = {}
    for _, c in ipairs(RC.SETTING_CATEGORIES) do catIds[c.id] = true end
    for _, s in ipairs(RC.SETTINGS) do
        if not catIds[s.cat] then
            issues.unknownCat[#issues.unknownCat + 1] = s.key .. " -> " .. tostring(s.cat)
        end
        if RC.defaults and RC.defaults[s.key] == nil then
            issues.noDefault[#issues.noDefault + 1] = s.key
        end
    end

    -- Every row the Sync Rules picker would show for every category: any
    -- path without a real label falls back to a humanised field name.
    local MS = RC.MeshSync
    if MS and MS.SYNC_CATEGORIES and MS.GetCategorySettings then
        for _, cat in ipairs(MS.SYNC_CATEGORIES) do
            for _, s in ipairs(MS:GetCategorySettings(cat.id)) do
                if not RC:SettingPathHasLabel(s.path) then
                    issues.noLabel[#issues.noLabel + 1] = s.path
                end
                -- The classifier always answers, so this only trips on an
                -- override naming a group that is not in the order list.
                if not RC.SETTING_GROUP_LABELS[RC:GetSettingGroup(s.path)] then
                    issues.noGroup[#issues.noGroup + 1] = s.path
                end
            end
        end
    end

    table.sort(issues.orphanDefaults)
    table.sort(issues.noDefault)
    table.sort(issues.unknownCat)
    table.sort(issues.noLabel)
    table.sort(issues.noGroup)

    local total = #issues.orphanDefaults + #issues.unknownCat + #issues.noGroup
    if verbose then
        RC:Print(RCL["|cFFFFD700=== Settings registry audit ===|r"])
        RC:Print(RCL["  Categories: "] .. #RC.SETTING_CATEGORIES
            .. RCL["  Settings: "] .. #RC.SETTINGS)
        if #issues.orphanDefaults > 0 then
            RC:Print(RCL["  |cFFFF6600No sync category (cannot be synced):|r "]
                .. table.concat(issues.orphanDefaults, ", "))
        end
        if #issues.unknownCat > 0 then
            RC:Print(RCL["  |cFFFF0000Unknown category:|r "]
                .. table.concat(issues.unknownCat, ", "))
        end
        if #issues.noDefault > 0 then
            RC:Print(RCL["  |cFF888888No entry in defaults (runtime-created):|r "]
                .. #issues.noDefault .. RCL[" setting(s)"])
        end
        if #issues.noLabel > 0 then
            RC:Print(RCL["  |cFFFFAA00Sync rows with no label (humanised guess):|r "]
                .. table.concat(issues.noLabel, ", "))
        end
        if #issues.noGroup > 0 then
            RC:Print(RCL["  |cFFFF0000Sync rows with no field group:|r "]
                .. table.concat(issues.noGroup, ", "))
        end
        if total == 0 then
            RC:Print(RCL["  |cFF00FF00Registry is consistent.|r"])
        end
    elseif total > 0 then
        RC:DebugPrint("Settings registry: " .. total
            .. " consistency issue(s) - run /rc settingsaudit", "profile")
    end
    return issues
end

-- Gear pages: new look options (all nil = the shipped look)
local GEAR_LOOK_FIELDS = {
    ["gearManager.look"]                   = RCL["Gear button look"],
    ["gearManager.look.borderSize"]        = RCL["Gear button border thickness"],
    ["gearManager.look.borderColor"]       = RCL["Gear button border colour"],
    ["gearManager.look.nameFont"]          = RCL["Gear button name font"],
    ["gearManager.look.nameColor"]         = RCL["Gear button name colour"],
    ["gearManager.look.namePos"]           = RCL["Gear button name position"],
    ["gearManager.look.timerFont"]         = RCL["Gear button timer font"],
    ["gearManager.look.timerColor"]        = RCL["Gear button cooldown timer colour"],
    ["gearManager.look.buffColor"]         = RCL["Gear button buff timer colour"],
    ["gearManager.look.swapAnim"]          = RCL["Item change animation"],
    ["gearManager.look.menuAnim"]          = RCL["Hover menu animation"],
    ["swapToast.showAnim"]                 = RCL["Notice appear animation"],
    ["swapToast.hideAnim"]                 = RCL["Notice hide animation"],
    ["swapToast.titleFont"]                = RCL["Notice title font"],
    ["swapToast.namesFont"]                = RCL["Notice piece names font"],
    ["swapToast.contextFont"]              = RCL["Notice reason line font"],
    ["swapToast.titleColor"]               = RCL["Notice title colour"],
    ["swapToast.namesColor"]               = RCL["Notice piece names colour"],
    ["swapToast.contextColor"]             = RCL["Notice reason line colour"],
    ["swapToast.bgColor"]                  = RCL["Notice background colour"],
    ["swapToast.borderColor"]              = RCL["Notice border colour"],
    ["swapToast.iconSize"]                 = RCL["Notice icon size"],
    ["swapToast.iconGap"]                  = RCL["Notice icon spacing"],
    ["repairReminder.iconSize"]            = RCL["Anvil size"],
    ["repairReminder.icon"]                = RCL["Anvil icon"],
    ["repairReminder.showBorder"]          = RCL["Anvil border"],
    ["repairReminder.borderSize"]          = RCL["Anvil border thickness"],
    ["repairReminder.borderColor"]         = RCL["Anvil border colour"],
    ["repairReminder.showLabel"]           = RCL["Anvil caption"],
    ["repairReminder.labelText"]           = RCL["Anvil caption text"],
    ["repairReminder.showPercent"]         = RCL["Durability in the caption"],
    ["repairReminder.labelFont"]           = RCL["Anvil caption font"],
    ["repairReminder.labelColor"]          = RCL["Anvil caption colour"],
    ["repairReminder.labelGap"]            = RCL["Anvil caption gap"],
    ["repairReminder.showAnim"]            = RCL["Anvil appear animation"],
    ["repairReminder.alertAnim"]           = RCL["Anvil attention animation"],
    ["repairReminder.hideAnim"]            = RCL["Anvil hide animation"],
    ["repairReminder.xOffset"]             = RCL["Anvil left / right nudge"],
    ["repairReminder.yOffset"]             = RCL["Anvil up / down nudge"],
    ["trinketSwap.buttonWidth"]            = RCL["Toggle button width"],
    ["trinketSwap.buttonHeight"]           = RCL["Toggle button height"],
    ["trinketSwap.compactSize"]            = RCL["Compact button size"],
    ["trinketSwap.queueIconSize"]          = RCL["Toggle button trinket icon size"],
    ["trinketSwap.stripeWidth"]            = RCL["Toggle button status stripe"],
    ["trinketSwap.buttonBgColor"]          = RCL["Toggle button background"],
    ["trinketSwap.buttonBorderColor"]      = RCL["Toggle button border"],
    ["trinketSwap.buttonFont"]             = RCL["Toggle button font"],
    ["trinketSwap.buttonShowAnim"]         = RCL["Toggle button appear animation"],
    ["trinketSwap.buttonStateAnim"]        = RCL["Toggle button state animation"],
    ["fastWeaponReminder.textFont"]        = RCL["Reminder font"],
    ["fastWeaponReminder.textColor"]       = RCL["Reminder text colour"],
    ["fastWeaponReminder.showText"]        = RCL["Reminder labels"],
    ["fastWeaponReminder.cellColor"]       = RCL["Reminder icon background"],
    ["fastWeaponReminder.showBorder"]      = RCL["Reminder icon border"],
    ["fastWeaponReminder.borderColor"]     = RCL["Reminder border colour"],
    ["fastWeaponReminder.showAnim"]        = RCL["Reminder appear animation"],
    ["fastWeaponReminder.flashAnim"]       = RCL["Reminder flash animation"],
    ["fastWeaponReminder.hideAnim"]        = RCL["Reminder hide animation"],
}
for k, v in pairs(GEAR_LOOK_FIELDS) do RC.SETTING_FIELD_LABELS[k] = v end
-- spec tables (font / colour / animation) are one row each, in Appearance
-- the button look is one unit (one Sync Rules row, Appearance)
RC.SETTING_OPAQUE_PATHS["gearManager.look"] = true
RC.SETTING_GROUP_OVERRIDES["gearManager.look"] = "appearance"
for _, path in ipairs({
    "swapToast.showAnim", "swapToast.hideAnim", "swapToast.titleFont", "swapToast.namesFont",
    "swapToast.contextFont", "swapToast.titleColor", "swapToast.namesColor", "swapToast.contextColor",
    "swapToast.bgColor", "swapToast.borderColor",
    "repairReminder.borderColor", "repairReminder.labelFont", "repairReminder.labelColor",
    "repairReminder.showAnim", "repairReminder.alertAnim", "repairReminder.hideAnim",
    "trinketSwap.buttonBgColor", "trinketSwap.buttonBorderColor", "trinketSwap.buttonFont",
    "trinketSwap.buttonShowAnim", "trinketSwap.buttonStateAnim",
    "fastWeaponReminder.textFont", "fastWeaponReminder.textColor", "fastWeaponReminder.cellColor",
    "fastWeaponReminder.borderColor", "fastWeaponReminder.showAnim", "fastWeaponReminder.flashAnim",
    "fastWeaponReminder.hideAnim",
}) do
    RC.SETTING_OPAQUE_PATHS[path] = true
    RC.SETTING_GROUP_OVERRIDES[path] = "appearance"
end
for _, path in ipairs({ "repairReminder.icon", "repairReminder.showBorder", "repairReminder.showLabel",
    "repairReminder.labelText", "repairReminder.showPercent", "repairReminder.labelGap",
    "repairReminder.xOffset", "repairReminder.yOffset", "fastWeaponReminder.showText",
    "fastWeaponReminder.showBorder", "trinketSwap.stripeWidth" }) do
    RC.SETTING_GROUP_OVERRIDES[path] = (path:find("Offset") and "position") or "appearance"
end
-- nil until picked: the Sync Rules page still lists them
local function Fields(list) return function() local t = {} for _, k in ipairs(list) do t[k] = true end return t end end
RC.SETTING_FIELD_SOURCES["swapToast"] = Fields({ "showAnim", "hideAnim", "titleFont", "namesFont", "contextFont",
    "titleColor", "namesColor", "contextColor", "bgColor", "borderColor", "iconSize", "iconGap" })
RC.SETTING_FIELD_SOURCES["repairReminder"] = Fields({ "iconSize", "icon", "showBorder", "borderSize", "borderColor",
    "showLabel", "labelText", "showPercent", "labelFont", "labelColor", "labelGap", "showAnim", "alertAnim",
    "hideAnim", "xOffset", "yOffset" })
RC.SETTING_FIELD_SOURCES["trinketSwap"] = Fields({ "buttonWidth", "buttonHeight", "compactSize", "queueIconSize",
    "stripeWidth", "buttonBgColor", "buttonBorderColor", "buttonFont", "buttonShowAnim", "buttonStateAnim" })
RC.SETTING_FIELD_SOURCES["fastWeaponReminder"] = Fields({ "textFont", "textColor", "showText", "cellColor",
    "showBorder", "borderColor", "showAnim", "flashAnim", "hideAnim" })

-- Consumables pages: bar looks, must-have alert and boss note (all nil = the shipped look)
-- SETTING_OPAQUE_PATHS: a style table is a set of specs, one row per field
RC.SETTING_OPAQUE_PATHS["consumablesHelper.style"] = "children"
RC.SETTING_OPAQUE_PATHS["potionsBar.style"]        = "children"
RC.SETTING_OPAQUE_PATHS["weaponsBar.style"]        = "children"
RC.SETTING_OPAQUE_PATHS["trinketBar.style"]        = "children"
-- SETTING_GROUP_OVERRIDES: looks, not behaviour
RC.SETTING_GROUP_OVERRIDES["consumablesHelper.style.*"] = "appearance"
RC.SETTING_GROUP_OVERRIDES["potionsBar.style.*"]        = "appearance"
RC.SETTING_GROUP_OVERRIDES["weaponsBar.style.*"]        = "appearance"
RC.SETTING_GROUP_OVERRIDES["trinketBar.style.*"]        = "appearance"
RC.SETTING_GROUP_OVERRIDES["consumablesChecker.essentials.titleFont"] = "appearance"
RC.SETTING_GROUP_OVERRIDES["consumablesChecker.essentials.nameFont"]  = "appearance"
RC.SETTING_GROUP_OVERRIDES["consumablesChecker.essentials.hintFont"]  = "appearance"
RC.SETTING_GROUP_OVERRIDES["consumablesChecker.essentials.gap"]       = "appearance"
RC.SETTING_GROUP_OVERRIDES["consumablesChecker.essentials.showAnim"]  = "appearance"
RC.SETTING_GROUP_OVERRIDES["consumablesChecker.essentials.hideAnim"]  = "appearance"
RC.SETTING_GROUP_OVERRIDES["bossNotes.showAnim"] = "appearance"
RC.SETTING_GROUP_OVERRIDES["bossNotes.hideAnim"] = "appearance"
-- SETTING_FIELD_SOURCES: sparse tables still list their rows on Sync Rules
do
    local function StyleFields()
        local t = {}
        for _, k in ipairs({ "countFont", "cooldownFont", "gcdFont", "durationFont", "expiryFont", "timerFont",
            "slotFont", "nameFont", "absorbFont", "buffFont", "countColor", "emptyColor", "cooldownColor",
            "gcdColor", "durationColor", "expirySoonColor", "expiryUrgentColor", "timerGoodColor",
            "timerMidColor", "timerLowColor", "nameColor", "slotColor", "glowColor", "tcooldownColor",
            "tbuffColor", "tslotColor", "glowAnim", "showAnim", "hideAnim" }) do t[k] = {} end
        t.glowEnabled, t.glowScale, t.fadeIn, t.fadeOut = false, 1.5, 0.18, 0.3
        return t
    end
    RC.SETTING_FIELD_SOURCES["consumablesHelper.style"] = StyleFields
    RC.SETTING_FIELD_SOURCES["potionsBar.style"]        = StyleFields
    RC.SETTING_FIELD_SOURCES["weaponsBar.style"]        = StyleFields
    RC.SETTING_FIELD_SOURCES["trinketBar.style"]        = StyleFields
end
-- SETTING_FIELD_LABELS
RC.SETTING_FIELD_LABELS["consumablesHelper.style"] = RCL["Consumables bar looks"]
RC.SETTING_FIELD_LABELS["potionsBar.style"]        = RCL["Potions bar looks"]
RC.SETTING_FIELD_LABELS["weaponsBar.style"]        = RCL["Weapons bar looks"]
RC.SETTING_FIELD_LABELS["trinketBar.style"]        = RCL["Trinket menu looks"]
RC.SETTING_FIELD_LABELS["consumablesHelper.style.glowAnim"]    = RCL["Expiry glow animation"]
RC.SETTING_FIELD_LABELS["consumablesHelper.style.glowEnabled"] = RCL["Expiry glow"]
RC.SETTING_FIELD_LABELS["consumablesHelper.style.glowScale"]   = RCL["Expiry glow size"]
RC.SETTING_FIELD_LABELS["consumablesHelper.style.glowColor"]   = RCL["Expiry glow colour"]
RC.SETTING_FIELD_LABELS["consumablesChecker.essentials.titleFont"] = RCL["Must-have alert title font"]
RC.SETTING_FIELD_LABELS["consumablesChecker.essentials.nameFont"]  = RCL["Must-have alert name font"]
RC.SETTING_FIELD_LABELS["consumablesChecker.essentials.hintFont"]  = RCL["Must-have alert hint font"]
RC.SETTING_FIELD_LABELS["consumablesChecker.essentials.gap"]       = RCL["Must-have icon spacing"]
RC.SETTING_FIELD_LABELS["consumablesChecker.essentials.showAnim"]  = RCL["Must-have alert entrance"]
RC.SETTING_FIELD_LABELS["consumablesChecker.essentials.hideAnim"]  = RCL["Must-have alert exit"]
RC.SETTING_FIELD_LABELS["bossNotes.font"]        = RCL["Note font"]
RC.SETTING_FIELD_LABELS["bossNotes.textColor"]   = RCL["Note text colour"]
RC.SETTING_FIELD_LABELS["bossNotes.bgColor"]     = RCL["Note background colour"]
RC.SETTING_FIELD_LABELS["bossNotes.borderColor"] = RCL["Note edge colour"]
RC.SETTING_FIELD_LABELS["bossNotes.showAnim"]    = RCL["Note entrance"]
RC.SETTING_FIELD_LABELS["bossNotes.hideAnim"]    = RCL["Note exit"]

-- Display pages: stats bar, pushoff alert, spec popup, nameplates, world buffs,
-- transfer bar and polarity bar looks (all nil = the shipped look)
RC.SETTING_OPAQUE_PATHS["statsBarLook"] = "children" -- one row per font / colour / texture
RC.SETTING_GROUP_OVERRIDES["statsBarLook.*"] = "appearance"
RC.SETTING_GROUP_OVERRIDES["buffPushoffAlert.look.*"] = "appearance"
RC.SETTING_GROUP_OVERRIDES["specDetection.look.*"] = "appearance"
RC.SETTING_GROUP_OVERRIDES["nameplateAuras.look.*"] = "appearance"
RC.SETTING_GROUP_OVERRIDES["worldBuffs.look.*"] = "appearance"
RC.SETTING_GROUP_OVERRIDES["meshProgressBar.look"] = "appearance"
RC.SETTING_GROUP_OVERRIDES["meshProgressBar.look.*"] = "appearance"
RC.SETTING_GROUP_OVERRIDES["polarityMode.look"] = "appearance"
RC.SETTING_GROUP_OVERRIDES["polarityMode.look.*"] = "appearance"
RC.SETTING_FIELD_LABELS["statsBarLook.labelFont"] = RCL["Label font"]
RC.SETTING_FIELD_LABELS["statsBarLook.valueFont"] = RCL["Value font"]
RC.SETTING_FIELD_LABELS["statsBarLook.bgTexture"] = RCL["Background texture"]
RC.SETTING_FIELD_LABELS["statsBarLook.borderColor"] = RCL["Border colour"]
RC.SETTING_FIELD_LABELS["statsBarLook.showBorder"] = RCL["Show border"]
RC.SETTING_FIELD_LABELS["buffPushoffAlert.look"] = RCL["Alert look"]
RC.SETTING_FIELD_LABELS["buffPushoffAlert.look.font"] = RCL["Alert font"]
RC.SETTING_FIELD_LABELS["buffPushoffAlert.look.subFont"] = RCL["Pusher line font"]
RC.SETTING_FIELD_LABELS["buffPushoffAlert.look.subColor"] = RCL["Pusher line colour"]
RC.SETTING_FIELD_LABELS["buffPushoffAlert.look.bgTexture"] = RCL["Background texture"]
RC.SETTING_FIELD_LABELS["buffPushoffAlert.look.showAnim"] = RCL["Alert entrance"]
RC.SETTING_FIELD_LABELS["buffPushoffAlert.look.hideAnim"] = RCL["Alert exit"]
RC.SETTING_FIELD_LABELS["buffPushoffAlert.look.width"] = RCL["Alert width"]
RC.SETTING_FIELD_LABELS["buffPushoffAlert.look.padding"] = RCL["Alert padding"]
RC.SETTING_FIELD_LABELS["specDetection.look"] = RCL["Spec popup look"]
RC.SETTING_FIELD_LABELS["specDetection.look.titleFont"] = RCL["Spec name font"]
RC.SETTING_FIELD_LABELS["specDetection.look.subFont"] = RCL["Subtitle font"]
RC.SETTING_FIELD_LABELS["specDetection.look.rankFont"] = RCL["Talent rank font"]
RC.SETTING_FIELD_LABELS["specDetection.look.width"] = RCL["Popup width"]
RC.SETTING_FIELD_LABELS["specDetection.look.iconSize"] = RCL["Spec icon size"]
RC.SETTING_FIELD_LABELS["specDetection.look.talentSize"] = RCL["Talent icon size"]
RC.SETTING_FIELD_LABELS["specDetection.look.perRow"] = RCL["Talents per row"]
RC.SETTING_FIELD_LABELS["specDetection.look.bgTexture"] = RCL["Background texture"]
RC.SETTING_FIELD_LABELS["specDetection.look.bgColor"] = RCL["Background colour"]
RC.SETTING_FIELD_LABELS["specDetection.look.borderColor"] = RCL["Border colour"]
RC.SETTING_FIELD_LABELS["specDetection.look.subColor"] = RCL["Subtitle colour"]
RC.SETTING_FIELD_LABELS["specDetection.look.showAnim"] = RCL["Popup entrance"]
RC.SETTING_FIELD_LABELS["specDetection.look.hideAnim"] = RCL["Popup exit"]
RC.SETTING_FIELD_LABELS["specDetection.look.x"] = RCL["Horizontal position"]
RC.SETTING_FIELD_LABELS["specDetection.look.y"] = RCL["Vertical position"]
RC.SETTING_FIELD_LABELS["specDetection.look.scale"] = RCL["Popup scale"]
RC.SETTING_FIELD_LABELS["specDetection.look.soundKey"] = RCL["Popup sound"]
RC.SETTING_FIELD_LABELS["nameplateAuras.look"] = RCL["Nameplate look"]
RC.SETTING_FIELD_LABELS["nameplateAuras.look.font"] = RCL["Count font"]
RC.SETTING_FIELD_LABELS["nameplateAuras.look.timerFont"] = RCL["Timer font"]
RC.SETTING_FIELD_LABELS["nameplateAuras.look.borderColor"] = RCL["Icon border colour"]
RC.SETTING_FIELD_LABELS["nameplateAuras.look.borderSize"] = RCL["Icon border size"]
RC.SETTING_FIELD_LABELS["nameplateAuras.look.zoom"] = RCL["Icon crop"]
RC.SETTING_FIELD_LABELS["nameplateAuras.look.showAnim"] = RCL["Debuff entrance"]
RC.SETTING_FIELD_LABELS["nameplateAuras.look.expireAnim"] = RCL["Expiring highlight"]
RC.SETTING_FIELD_LABELS["nameplateAuras.look.expireAt"] = RCL["Expiring at"]
RC.SETTING_FIELD_LABELS["worldBuffs.look"] = RCL["Board look"]
RC.SETTING_FIELD_LABELS["worldBuffs.look.iconSize"] = RCL["Cell size"]
RC.SETTING_FIELD_LABELS["worldBuffs.look.rowHeight"] = RCL["Row height"]
RC.SETTING_FIELD_LABELS["worldBuffs.look.nameFont"] = RCL["Name font"]
RC.SETTING_FIELD_LABELS["worldBuffs.look.subFont"] = RCL["Location font"]
RC.SETTING_FIELD_LABELS["worldBuffs.look.timeFont"] = RCL["Timer font"]
RC.SETTING_FIELD_LABELS["worldBuffs.look.activeColor"] = RCL["Active colour"]
RC.SETTING_FIELD_LABELS["worldBuffs.look.boonedColor"] = RCL["Booned colour"]
RC.SETTING_FIELD_LABELS["worldBuffs.look.missingColor"] = RCL["Missing colour"]
RC.SETTING_FIELD_LABELS["worldBuffs.look.stripes"] = RCL["Row stripes"]
RC.SETTING_FIELD_LABELS["meshProgressBar.look"] = RCL["Transfer bar look"]
RC.SETTING_FIELD_LABELS["polarityMode.look"] = RCL["Countdown bar look"]

-- ============================================================
-- The customization standard (UI/Framework/UIF_Custom.lua)
-- ============================================================
-- A feature keeps its customization specs under its own registered root,
-- one family table each: <root>.anchors, .layout, .visibility, .chrome,
-- .states, .formats, .sounds. Each family table is ONE unit - one Sync
-- Rules row, the whole table travels - and is nil until something is set.
-- One call per feature registers the rows (append; never reorder):
--   RC:RegisterCustomization("myRoot", { anchors = RCL["Text and part positions"], layout = ... })
-- Visibility rules are behaviour (Settings); everything else is a look
-- (Appearance).
RC.CUSTOM_FAMILY_GROUP = {
    anchors = "appearance", layout = "appearance", chrome = "appearance", states = "appearance",
    formats = "appearance", sounds = "appearance", visibility = "settings", framePos = "appearance",
}
function RC:RegisterCustomization(root, families)
    if type(root) ~= "string" or type(families) ~= "table" then return end
    local names = {}
    for fam, label in pairs(families) do
        local path = root .. "." .. fam
        RC.SETTING_OPAQUE_PATHS[path] = true
        RC.SETTING_GROUP_OVERRIDES[path] = RC.CUSTOM_FAMILY_GROUP[fam] or "appearance"
        RC.SETTING_FIELD_LABELS[path] = label
        names[#names + 1] = fam
    end
    -- listed on Sync Rules while still unset
    local prev = RC.SETTING_FIELD_SOURCES[root]
    RC.SETTING_FIELD_SOURCES[root] = function()
        local t = prev and prev() or {}
        for _, fam in ipairs(names) do if t[fam] == nil then t[fam] = {} end end
        return t
    end
end

-- Battle Shout: every text and part placeable, the tracker's rows laid
-- out and its name / time texts formatted
RC:RegisterCustomization("battleShoutReminder", { anchors = RCL["Text and part positions"],
    visibility = RCL["Icon fade and opacity"], chrome = RCL["Icon shadow and glow"], framePos = RCL["Icon layer and scale"] })
RC:RegisterCustomization("battleShoutPartyTracker", {
    anchors = RCL["Text and part positions"],
    layout  = RCL["Row layout"],
    formats = RCL["Name and time formats"],
    visibility = RCL["Tracker fade and opacity"], chrome = RCL["Tracker shadow and glow"], framePos = RCL["Tracker layer"],
})
-- The consumables, potions and weapons bars and the trinket menu: every
-- button text placeable (and the expiry glow), the timers worded
RC:RegisterCustomization("consumablesHelper", { anchors = RCL["Button text positions"], formats = RCL["Timer formats"],
    visibility = RCL["Fade and opacity"], chrome = RCL["Shadow and glow"], framePos = RCL["Frame layer"] })
RC:RegisterCustomization("potionsBar", { anchors = RCL["Button text positions"], formats = RCL["Timer formats"],
    visibility = RCL["Fade and opacity"], chrome = RCL["Shadow and glow"], framePos = RCL["Frame layer"] })
RC:RegisterCustomization("weaponsBar", { anchors = RCL["Button text positions"], formats = RCL["Timer formats"],
    visibility = RCL["Fade and opacity"], chrome = RCL["Shadow and glow"], framePos = RCL["Frame layer"] })
RC:RegisterCustomization("trinketBar", { anchors = RCL["Button text positions"],
    visibility = RCL["Fade and opacity"], chrome = RCL["Shadow and glow"], framePos = RCL["Frame layer"] })
-- Every on-screen frame's layer / fade / edge (RC:ApplyFrameCustom)
local FRAME_FAMILIES = { visibility = RCL["Fade and opacity"], chrome = RCL["Frame edge and shadow"], framePos = RCL["Frame layer"] }
RC:RegisterCustomization("fastWeaponReminder", FRAME_FAMILIES)
RC:RegisterCustomization("specDetection", FRAME_FAMILIES)
RC:RegisterCustomization("swapToast", FRAME_FAMILIES)
RC:RegisterCustomization("polarityMode", FRAME_FAMILIES)
RC:RegisterCustomization("buffPushoffAlert", FRAME_FAMILIES)
RC:RegisterCustomization("bossNotes", FRAME_FAMILIES)
RC:RegisterCustomization("consumablesChecker", FRAME_FAMILIES)
RC:RegisterCustomization("worldBuffs", FRAME_FAMILIES)
RC:RegisterCustomization("meshProgressBar", FRAME_FAMILIES)
RC:RegisterCustomization("trinketSwap", FRAME_FAMILIES)
RC:RegisterCustomization("gearManager", FRAME_FAMILIES)
-- a look per state: the aura trackers' time states, the repair anvil's
RC:RegisterCustomization("raidBuffTracker", { states = RCL["Look per state"] })
RC:RegisterCustomization("bossDebuffTracker", { states = RCL["Look per state"] })
RC:RegisterCustomization("repairReminder", { states = RCL["Look per state"] })
-- text positions on the smaller frames
RC:RegisterCustomization("buffPushoffAlert", { anchors = RCL["Text positions"] })
RC:RegisterCustomization("specDetection", { anchors = RCL["Text positions"] })
RC:RegisterCustomization("swapToast", { anchors = RCL["Text positions"] })
RC:RegisterCustomization("polarityMode", { anchors = RCL["Text positions"] })
RC:RegisterCustomization("fastWeaponReminder", { anchors = RCL["Label positions"] })
-- Nameplate auras: the count and timer placeable on the icon, the timer worded
RC:RegisterCustomization("nameplateAuras", { anchors = RCL["Count and timer positions"], formats = RCL["Timer format"] })
-- Repair reminder: the caption and the icon art placeable, the caption worded
RC:RegisterCustomization("repairReminder", { anchors = RCL["Caption and icon positions"], formats = RCL["Caption format"],
    visibility = RCL["Fade and opacity"], chrome = RCL["Shadow and glow"], framePos = RCL["Frame layer"] })
-- Route tracker: the title, count, body line and when-label placeable
RC:RegisterCustomization("raidRoute", { anchors = RCL["Tracker text positions"], visibility = RCL["Tracker fade and opacity"],
    chrome = RCL["Tracker shadow and glow"], framePos = RCL["Tracker layer"], sounds = RCL["Reminder ping sound"] })
-- Stats bar: each cell's label, value and the push-off icon placeable,
-- the values worded
RC:RegisterCustomization("statsBarLook", { anchors = RCL["Text positions"], formats = RCL["Value format"],
    visibility = RCL["Fade and opacity"], chrome = RCL["Shadow and glow"], framePos = RCL["Frame layer"] })
-- TTK display: every text placeable
RC:RegisterCustomization("ttkDisplay", { anchors = RCL["Text positions"], formats = RCL["Time format"],
    visibility = RCL["Fade and opacity"], chrome = RCL["Shadow and glow"], framePos = RCL["Frame layer"] })
-- Raid buff / boss debuff trackers: every text and the icon placeable,
-- the time and names worded, a sound when an aura turns urgent
RC:RegisterCustomization("raidBuffTracker", { anchors = RCL["Text and part positions"],
    formats = RCL["Time and name formats"], sounds = RCL["Urgent sound"], layout = RCL["Row order"],
    visibility = RCL["Fade and opacity"], chrome = RCL["Frame edge and shadow"], framePos = RCL["Frame layer"] })
RC:RegisterCustomization("bossDebuffTracker", { anchors = RCL["Text and part positions"],
    formats = RCL["Time and name formats"], sounds = RCL["Urgent sound"], layout = RCL["Row order"],
    visibility = RCL["Fade and opacity"], chrome = RCL["Frame edge and shadow"], framePos = RCL["Frame layer"] })
-- Reminder popup: the icon text and glow placeable, the icons laid out,
-- a look per label state, the text's wording
RC:RegisterCustomization("reminderPopup", {
    anchors = RCL["Icon text and glow positions"],
    layout  = RCL["Icon layout"],
    states  = RCL["Look per state"],
    formats = RCL["Icon text format"],
    visibility = RCL["Popup fade and opacity"],
    chrome  = RCL["Backdrop behind the icons"],
    framePos = RCL["Popup layer and scale"],
})
-- Consumables checker window: each row's name and count placeable, the count worded
RC:RegisterCustomization("consumablesChecker", { anchors = RCL["Row text positions"], formats = RCL["Count format"] })
-- Gear buttons (and their hover menu tiles): the name and timer placeable, the timer worded
RC:RegisterCustomization("gearManager", { anchors = RCL["Button text positions"], formats = RCL["Timer format"] })
-- World buffs board: every row text placeable, the buff and cooldown timers worded
RC:RegisterCustomization("worldBuffs", { anchors = RCL["Board text positions"], formats = RCL["Timer formats"] })
-- Boss notes: the box is sized around its text, so padding and the lines' alignment instead of a position
RC:RegisterCustomization("bossNotes", { layout = RCL["Note padding"], anchors = RCL["Note text alignment"] })

-- Raid consume reminders: the glow on the icons (one row per field, all looks)
RC.SETTING_OPAQUE_PATHS["consumeRemindGlow"] = "children"
RC.SETTING_GROUP_OVERRIDES["consumeRemindGlow.*"] = "appearance"
RC.SETTING_FIELD_SOURCES["consumeRemindGlow"] = function()
    local t = {}
    for k, v in pairs(RC.UI and RC.UI.EDGE_GLOW_DEFAULTS or {}) do t[k] = v end
    t.color = {}
    return t
end
RC.SETTING_FIELD_LABELS["consumeRemindGlow.style"]     = RCL["Consume reminder glow style"]
RC.SETTING_FIELD_LABELS["consumeRemindGlow.color"]     = RCL["Consume reminder glow colour"]
RC.SETTING_FIELD_LABELS["consumeRemindGlow.alpha"]     = RCL["Consume reminder glow strength"]
RC.SETTING_FIELD_LABELS["consumeRemindGlow.size"]      = RCL["Consume reminder glow size"]
RC.SETTING_FIELD_LABELS["consumeRemindGlow.halo"]      = RCL["Consume reminder soft halo"]
RC.SETTING_FIELD_LABELS["consumeRemindGlow.pulse"]     = RCL["Consume reminder glow pulse"]
RC.SETTING_FIELD_LABELS["consumeRemindGlow.speed"]     = RCL["Consume reminder pulse length"]
RC.SETTING_FIELD_LABELS["consumeRemindGlow.depth"]     = RCL["Consume reminder pulse depth"]
RC.SETTING_FIELD_LABELS["consumeRemindGlow.lines"]     = RCL["Consume reminder glow lines"]
RC.SETTING_FIELD_LABELS["consumeRemindGlow.length"]    = RCL["Consume reminder glow line length"]
RC.SETTING_FIELD_LABELS["consumeRemindGlow.lineSpeed"] = RCL["Consume reminder glow line speed"]

-- Raid consume reminders: on/off, bags only, and the ticked items (one unit)
RC.SETTING_OPAQUE_PATHS["consumeRemind.items"] = true
RC.SETTING_FIELD_LABELS["consumeRemind.enabled"]    = RCL["Raid consume reminders on"]
RC.SETTING_FIELD_LABELS["consumeRemind.onlyInBags"] = RCL["Raid consume reminders: only what is in my bags"]
RC.SETTING_FIELD_LABELS["consumeRemind.items"]      = RCL["Raid consume reminder items"]
