------------------------------------------------------------------------
-- Readycheck - Sidebar Shell: Registry & Theme
-- Owns the SIDEBAR const table, color helpers, RC:RefreshUIColors, and
-- RC.MenuStructure - the single registry of every sidebar page.
-- MenuStructure entries define the page contract: `panel` is a method
-- name invoked as self[panel](self, compatFrame); `raidKey` routes to
-- OpenRaidBossPage instead. lodAddon lazy-loads a LoD module before
-- the panel lookup. See Sidebar_Window.lua for ShowSidebarPanel, the
-- dispatcher that reads these fields.
------------------------------------------------------------------------
-- Taint-safe API locals (fallbacks on RC.Compat, built in Core; never write _G)
local RCC = _G.Readycheck
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
RC._sbs = RC._sbs or {}
local _sbs = RC._sbs

    -- Fallback values only; RC:GetColor()-backed getters below are used whenever RC.GetColor exists.
    local SIDEBAR = {
        -- (5.0: the /zui sidebar - 295 wide, 28 px rows, no gap between
        -- rows, 10 between groups; RC.UI.S has the rest)
        WIDTH = 295,
        BUTTON_HEIGHT = 28,
        RAID_BUTTON_HEIGHT = 50,
        BUTTON_SPACING = 0,
        CATEGORY_SPACING = 10,
        HEADER_HEIGHT = 24,
        PADDING = 8,

        BG_COLOR = {r = 0.04, g = 0.04, b = 0.04, a = 1},
        BUTTON_NORMAL = {r = 0.08, g = 0.08, b = 0.08, a = 1},
        BUTTON_HOVER = {r = 0.15, g = 0.15, b = 0.15, a = 1},
        BUTTON_SELECTED = {r = 0.12, g = 0.22, b = 0.12, a = 1},
        CATEGORY_COLOR = {r = 1, g = 0.82, b = 0},
        TEXT_NORMAL = {r = 0.75, g = 0.75, b = 0.75},
        TEXT_SELECTED = {r = 0.5, g = 1, b = 0.5},
        TEXT_DISABLED = {r = 0.5, g = 0.5, b = 0.5},
        ACCENT_COLOR = {r = 0.5, g = 1, b = 0.5}
    }

    local TEXT = RC.UI and RC.UI.TEXT or {}

    function SIDEBAR:GetButtonNormal()
        if RC.GetColor then
            return RC:GetColor("sidebar", "buttonNormal")
        end
        return self.BUTTON_NORMAL
    end

    function SIDEBAR:GetButtonHover()
        if RC.GetColor then
            return RC:GetColor("sidebar", "buttonHover")
        end
        return self.BUTTON_HOVER
    end

    function SIDEBAR:GetButtonSelected()
        if RC.GetColor then
            return RC:GetColor("sidebar", "buttonSelected")
        end
        return self.BUTTON_SELECTED
    end

    function SIDEBAR:GetTextNormal()
        if RC.GetColor then
            return RC:GetColor("text", "menuNormal")
        end
        return self.TEXT_NORMAL
    end

    function SIDEBAR:GetTextSelected()
        if RC.GetColor then
            return RC:GetColor("text", "menuSelected")
        end
        return self.TEXT_SELECTED
    end

    function SIDEBAR:GetAccentColor()
        if RC.GetColor then
            return RC:GetColor("sidebar", "selectionIndicator")
        end
        return self.ACCENT_COLOR
    end

    RC.SIDEBAR = SIDEBAR

    -- Walks a frame tree and calls :Repaint() on anything that has one
    -- (buttons, tabs, checkboxes, sliders, cards, page headers). Bounded
    -- by depth so a runaway tree cannot stall the client.
    local function RepaintTree(root, depth)
        if not root or (depth or 0) > 10 then return end
        if type(root.Repaint) == "function" then pcall(root.Repaint, root) end
        if root.GetChildren then
            for _, child in ipairs({ root:GetChildren() }) do
                RepaintTree(child, (depth or 0) + 1)
            end
        end
    end

    function RC:RefreshUIColors()
        local frame = self.sidebarConfigFrame
        if not frame then return end

        local windowBgColor = self:GetColor("ui", "windowBackground")
        local headerBgColor = self:GetColor("ui", "headerBackground")
        local accentColor = self:GetColor("ui", "accentGold")
        local headerTextColor = self:GetColor("ui", "headerText")
        local sidebarBgColor = self:GetColor("sidebar", "background")
        local contentBgColor = self:GetColor("ui", "windowBackground")
        local scrollTrackColor = self:GetColor("scrollbar", "track")
        local scrollThumbColor = self:GetColor("scrollbar", "thumb")
        local borderColor = self:GetColor("ui", "borderNormal")
        local inputBgColor = self:GetColor("uiMover", "inputBackground")

        if frame.bg then
            frame.bg:SetColorTexture(windowBgColor.r, windowBgColor.g, windowBgColor.b, windowBgColor.a or 1)
        end

        local bgOpacity = (self.db and self.db.fontSettings and self.db.fontSettings.mainWindowBgOpacity) or 1.0
        if frame.bg then frame.bg:SetAlpha(bgOpacity) end
        if frame.sidebar and frame.sidebar.bg then frame.sidebar.bg:SetAlpha(bgOpacity) end
        if frame.contentBg then frame.contentBg:SetAlpha(bgOpacity) end

        if frame.border and self.UI and self.UI.UpdateBorderColor then
            self.UI:UpdateBorderColor(frame.border, borderColor)
        end

        -- Title bar: the hero header repaints itself from the theme.
        if frame.heroHeader and frame.heroHeader.Repaint then
            frame.heroHeader:Repaint()
        end
        if frame.titleFill then
            frame.titleFill:SetVertexColor(headerBgColor.r, headerBgColor.g, headerBgColor.b, headerBgColor.a or 1)
        end

        if frame.titleAccent then
            frame.titleAccent:SetVertexColor(accentColor.r, accentColor.g, accentColor.b, 0.6)
        end

        if frame.titleText then
            frame.titleText:SetTextColor(headerTextColor.r, headerTextColor.g, headerTextColor.b)
        end

        if frame.sidebar and frame.sidebar.bg then
            frame.sidebar.bg:SetVertexColor(sidebarBgColor.r, sidebarBgColor.g, sidebarBgColor.b, sidebarBgColor.a or 1)
        end

        if frame.sidebar and frame.sidebar.rule then
            frame.sidebar.rule:SetVertexColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
        end

        if frame.sidebar and frame.sidebar.searchContainer and frame.sidebar.searchContainer.SetBackdropColor then
            frame.sidebar.searchContainer:SetBackdropColor(inputBgColor.r, inputBgColor.g, inputBgColor.b, 1)
            frame.sidebar.searchContainer:SetBackdropBorderColor(borderColor.r, borderColor.g, borderColor.b, borderColor.a or 1)
        end

        local function RepaintScrollbar(scrollBar)
            if not scrollBar then return end
            -- (a bar wearing the framework's scroll look repaints itself)
            if scrollBar._rcScrollStyled and scrollBar.Repaint then scrollBar:Repaint() return end
            if scrollBar.bg then
                scrollBar.bg:SetVertexColor(scrollTrackColor.r, scrollTrackColor.g, scrollTrackColor.b, scrollTrackColor.a or 0.8)
            end
            if scrollBar.thumb then
                scrollBar.thumb:SetVertexColor(scrollThumbColor.r, scrollThumbColor.g, scrollThumbColor.b, 1)
            end
            if scrollBar.border and self.UI and self.UI.UpdateBorderColor then
                self.UI:UpdateBorderColor(scrollBar.border, borderColor)
            end
        end

        if frame.sidebar and frame.sidebar.scrollFrame then
            RepaintScrollbar(frame.sidebar.scrollFrame.scrollBar)
        end

        if frame.contentArea and frame.contentArea.bg then
            frame.contentArea.bg:SetVertexColor(contentBgColor.r, contentBgColor.g, contentBgColor.b, contentBgColor.a or 1)
        end

        if frame.contentFrame then
            RepaintScrollbar(frame.contentFrame.scrollBar)
        end

        -- the 5.0 window paints its own shell (RC.UI.S, settings colours)
        if frame.RepaintShell then frame:RepaintShell() end

        if frame.sidebar then
            self:BuildSidebar(frame, false)

            if self.SidebarState and self.SidebarState.selectedItem then
                for _, button in ipairs(frame.sidebar.buttons or {}) do
                    local isSelected = (button.menuItem.id == self.SidebarState.selectedItem)
                    self:SetSidebarButtonState(button, isSelected, self.SidebarState.expandedCategories[button.menuItem.id])
                end
            end
        end

        -- Everything on the current page that knows how to repaint itself
        -- (cards, headers, buttons, tabs, checkboxes, sliders) does so in
        -- place, so a colour change shows without rebuilding the page.
        if frame.contentScrollChild then
            RepaintTree(frame.contentScrollChild, 0)
        end

        if self.consumablesChecker and self.consumablesChecker.frame and self.consumablesChecker.frame:IsShown() then
            self:UpdateConsumablesCheckerDisplay()
        end

        self:DebugPrint("UI colors refreshed", "config")
    end

    -- Page registry: panel = method name dispatched as self[panel](self, compatFrame);
    -- raidKey routes to OpenRaidBossPage instead of a panel lookup. A group's
    -- panel is its overview page (RC:ShowSidebarGroupOverview), which lists
    -- the group's children in this order. A group's icon shows where the
    -- group is listed as a row (search results), so it lines up with pages.
    --
    -- ORDER: what a raiding warrior opens most comes first - reminders,
    -- consumables, gear - then the raid setup and its kill timing, then
    -- the world (world tools, the mesh), your character, the extras, and
    -- Settings (general, appearance, profiles, help) last. Group and page
    -- ids never change (saved selections, tests and the tour use them);
    -- a renamed page keeps its old name in its aliases so search finds it.
    -- World Tools registers itself just above Mesh Network (WT_UI.lua).
    -- A page whose id did change: old id -> new id, read wherever a saved
    -- or passed-in page id is looked up (RC:ResolvePageId).
    RC.PAGE_ID_RENAMES = {
        test_consumeremind = "consumeremind",   -- Raid Consume Reminders, out of testing
    }
    function RC:ResolvePageId(id)
        return (id and RC.PAGE_ID_RENAMES[id]) or id
    end
    RC.MenuStructure = {
        {
            id = "reminders",
            name = RCL["Reminders"],
            category = true,
            icon = "Interface\\Icons\\INV_Misc_Bell_01",
            panel = "ShowSidebarRemindersOverview",
            aliases = {"reminders", "reminder", "alerts", "alert", "popup", "custom", "trigger", "trackers", "buff tracker", "debuff tracker", "shout", "boon"},
            children = {
                {id = "reminder_settings",   name = RCL["Reminder Settings"],   icon = "Interface\\Icons\\INV_Misc_Bell_01",            panel = "ShowSidebarReminderSettings", lodAddon = "Readycheck_Reminders", aliases = {"reminder", "reminder settings", "sound", "audio", "animation", "tts", "text to speech", "position", "display", "flash", "pulse", "popup"}},
                {id = "battle_shout",        name = RCL["Battle Shout"],        icon = "Interface\\Icons\\Ability_Warrior_BattleShout", panel = "ShowSidebarBattleShoutConfig", lodAddon = "Readycheck_Reminders",  warriorOnly = true, aliases = {"shout", "battle shout", "buff", "party buff", "bshout", "battle shout reminder"},                          sidebarVisibleKey = "battle_shout"},
                {id = "boon_reminder",       name = RCL["Chronoboon"],          icon = "Interface\\Icons\\inv_misc_enggizmos_24",       panel = "ShowSidebarBoonReminderConfig", lodAddon = "Readycheck_Reminders", warriorOnly = true, aliases = {"boon", "chronoboon", "world buff", "worldbuff", "dire maul", "ony head", "zg", "chronoboon reminder"},   sidebarVisibleKey = "boon_reminder"},
                {id = "buff_pushoff",        name = RCL["Buff Pushoff"],        icon = "Interface\\Icons\\Spell_ChargePositive",        panel = "ShowSidebarBuffPushoffConfig", warriorOnly = true, aliases = {"pushoff", "push off", "buff cap", "32 buffs", "buff limit", "dropped buff", "pushed off", "buff pushoff"}},
                -- Both trackers are for every class (not warriorOnly).
                {id = "raid_buff_tracker",   name = RCL["Raid Buff Tracker"],   icon = "Interface\\Icons\\Spell_Holy_WordFortitude",    panel = "ShowSidebarRaidBuffTrackerConfig",   lodAddon = "Readycheck_Reminders", aliases = {"buff timers", "class buffs", "raid buffs", "fortitude", "fort", "intellect", "blessings", "blessing", "mark of the wild", "motw", "buff tracker", "buff duration", "buff expiring", "rebuff", "whisper"}},
                {id = "boss_debuff_tracker", name = RCL["Boss Debuff Tracker"], icon = "Interface\\Icons\\Spell_Nature_FaerieFire",     panel = "ShowSidebarBossDebuffTrackerConfig", lodAddon = "Readycheck_Reminders", aliases = {"debuff timers", "boss debuffs", "sunder", "curses", "curse of recklessness", "curse of elements", "scorch", "scorch stacks", "demo shout", "faerie fire", "debuff tracker", "winter's chill", "shadow weaving", "nightfall", "whisper"}},
                {id = "custom_reminders",    name = RCL["Custom Reminders"],    icon = "Interface\\Icons\\INV_Misc_Note_06",            panel = "ShowSidebarCustomReminders", lodAddon = "Readycheck_Reminders", aliases = {"reminder", "reminders", "custom", "trigger", "condition", "alert", "notification"}},
            }
        },
        {
            id = "consumables",
            name = RCL["Consumables"],
            category = true,
            icon = "Interface\\Icons\\INV_Potion_41",
            panel = "ShowSidebarBarsOverview", lodAddon = "Readycheck_Consumables",
            aliases = {"bars", "bar", "consumables", "potions", "weapons", "consumable bars"},
            children = {
                {id = "consumables_checker", name = RCL["Consumables Checker"], icon = "Interface\\Icons\\INV_Scroll_03",  panel = "ShowSidebarConsumablesCheckerConfig", lodAddon = "Readycheck_Consumables", aliases = {"check", "checker", "missing", "checklist", "consumable check", "before raid", "must have", "missing items"}},
                {id = "consumables_bar",     name = RCL["Consumables Bar"],     icon = "Interface\\Icons\\INV_Potion_41",  panel = "ShowSidebarConsumablesHelperConfig", lodAddon = "Readycheck_Consumables",  aliases = {"consumable", "bar", "elixir", "flask", "food", "scroll", "consumables", "glow", "expiry glow", "fade"}, enabledKey = {"consumablesHelper", "enabled"}},
                {id = "potions_bar",         name = RCL["Potions Bar"],         icon = "Interface\\Icons\\INV_Potion_54",  panel = "ShowSidebarPotionsBarConfig", lodAddon = "Readycheck_Consumables",         aliases = {"potion", "pot", "mana potion", "healing potion", "greater healing"},      enabledKey = {"potionsBar", "enabled"}},
                {id = "weapons_bar",         name = RCL["Weapons Bar"],         icon = "Interface\\Icons\\INV_Stone_02",   panel = "ShowSidebarWeaponsBarConfig", lodAddon = "Readycheck_Consumables",          aliases = {"weapon", "stone", "oil", "poison", "imbue", "temp enchant"},             enabledKey = {"weaponsBar", "enabled"}},
                {id = "consumeremind",       name = RCL["Raid Consume Reminders"], icon = "Interface\\Icons\\INV_Potion_62", panel = "ShowSidebarConsumeRemind", lodAddon = "Readycheck_Consumables",           aliases = {"missing consumables", "consume reminder", "consumes", "flask reminder", "raid consume reminders", "raid consumes"}},
            }
        },
        {
            id = "equipment",
            name = RCL["Gear"],
            category = true,
            icon = "Interface\\Icons\\INV_Chest_Plate16",
            panel = "ShowSidebarEquipmentOverview",
            aliases = {"equipment", "gear", "trinket", "hotswap", "weapon", "equipment & gear", "repair"},
            children = {
                {id = "gear_manager",       name = RCL["Gear Manager"],        icon = "Interface\\Icons\\INV_Chest_Plate16",          panel = "ShowSidebarGearManagerConfig",   aliases = {"gear", "set", "gear set", "equipment set", "sets", "swap set"},                              sidebarVisibleKey = "gear_manager"},
                {id = "trinkets",           name = RCL["Trinket Manager"],     icon = "Interface\\Icons\\INV_Trinket_Naxxramas04",    panel = "ShowSidebarTrinketSwapConfig",   aliases = {"trinket", "swap", "rotation", "trinkets", "on use"},                                          sidebarVisibleKey = "trinkets"},
                {id = "trinket_bar",        name = RCL["Trinket Menu"],        icon = "Interface\\Icons\\inv_trinket_naxxramas03",    panel = "ShowSidebarTrinketBarConfig", lodAddon = "Readycheck_Consumables",    aliases = {"trinket menu", "trinket bar", "trinket display", "trinket icons", "on use trinket"},          enabledKey = {"trinketBar", "enabled"}},
                {id = "speed_swaps",        name = RCL["On-Use Gear Swaps"],   icon = "Interface\\Icons\\INV_Boots_02",               panel = "ShowSidebarSpeedSwaps",          aliases = {"speed", "swapback", "swap back", "rocket boots", "boots", "skull", "use item", "revert", "on-use", "on use", "gear swap", "belt", "hauberk"},    sidebarVisibleKey = "speed_swaps"},
                {id = "hotswap",            name = RCL["Hotswap Macros"],      icon = "Interface\\Icons\\INV_Helmet_71",              panel = "ShowSidebarHotswapMacros",       aliases = {"hotswap", "macro", "t2", "battle shout gear", "diamond flask", "t2 protection"}, warriorOnly = true, sidebarVisibleKey = "hotswap"},
                {id = "equipment_reminder", name = RCL["Equipment Reminder"],  icon = "Interface\\Icons\\INV_Sword_04",               panel = "ShowSidebarFastWeaponConfig",    aliases = {"equipment", "weapon", "enchant", "oil", "sharpening stone", "wizard oil", "reminder", "wrong gear", "fast weapon", "shield"},       sidebarVisibleKey = "equipment_reminder"},
                {id = "repair_reminder",    name = RCL["Repair Reminder"],     icon = "Interface\\Icons\\Trade_BlackSmithing",        panel = "ShowSidebarRepairReminderConfig", aliases = {"repair", "durability", "broken gear", "gear durability", "vendor", "armor durability", "repair bot", "fix gear"}},
            }
        },
        {
            id = "raids",
            name = RCL["Raids"],
            category = true,
            icon = "Interface\\Icons\\Achievement_Boss_KelThuzad_01",
            panel = "ShowSidebarRaidsOverview",
            aliases = {"raids", "raid", "raid configuration", "raid config", "boss", "bosses"},
            children = {
                {id = "mc",   name = RCL["Molten Core"],           icon = "Interface\\Icons\\Spell_Fire_Incinerate",          raidKey = "Molten Core",           },
                {id = "bwl",  name = RCL["Blackwing Lair"],        icon = "Interface\\Icons\\INV_Misc_Head_Dragon_Black",      raidKey = "Blackwing Lair",        },
                {id = "aq40", name = RCL["Temple of Ahn'Qiraj"],   icon = "Interface\\Icons\\INV_Misc_QirajiCrystal_05",      raidKey = "Temple of Ahn'Qiraj",   },
                {id = "naxx", name = RCL["Naxxramas"],             icon = "Interface\\Icons\\Achievement_Boss_KelThuzad_01",  raidKey = "Naxxramas",             },
                {id = "boss_notes", name = RCL["Boss & Trash Notes"], icon = "Interface\\Icons\\INV_Misc_Note_01", panel = "ShowSidebarBossNotes",    aliases = {"notes", "boss notes", "pull notes", "note", "target note", "pull note", "strategy", "raid note", "trash notes"}},
            }
        },
        {
            id = "combat",
            name = RCL["Fight Analytics"],
            category = true,
            icon = "Interface\\Icons\\Ability_Warrior_Savageblow",
            panel = "ShowSidebarFightAnalyticsOverview",
            aliases = {"analytics", "fight", "ttk", "predictions", "history", "kill time"},
            children = {
                {id = "execute",     name = RCL["ML Predictions"], icon = "Interface\\Icons\\Ability_Warrior_Savageblow", panel = "ShowSidebarExecuteSettings", lodAddon = "Readycheck_Reminders", aliases = {"ml", "machine learning", "prediction", "execute", "kill time estimate", "learning", "history"}, sidebarVisibleKey = "execute"},
                {id = "ttk_display", name = RCL["TTK Display"],    icon = "Interface\\Icons\\INV_Misc_PocketWatch_02",    panel = "ShowSidebarTTKSettings", lodAddon = "Readycheck_Reminders",     aliases = {"ttk", "kill time", "overlay", "hud", "display", "on screen", "frame"},                         sidebarVisibleKey = "ttk_display"},
            }
        },
        {
            id = "mesh",
            name = RCL["Mesh Network"],
            category = true,
            icon = "Interface\\Icons\\spell_nature_web",
            panel = "ShowSidebarMeshOverview",
            aliases = {"mesh", "network", "sync", "world buff", "worldbuff", "buffs", "boon board", "remote", "cross account", "battlenet", "share", "who has buffs", "stuck", "unstuck", "fetching config", "cross faction", "crossfaction", "tombstone", "version check", "mesh password", "recover", "reset sync"},
            children = {
                {id = "mesh_sync",       name = RCL["Connection"],         icon = "Interface\\Icons\\spell_nature_web",        panel = "ShowSidebarMeshSync", aliases = {"mesh", "network", "sync", "channel", "transfer", "accounts", "battlenet", "multi", "cross account", "connection", "password", "discovery", "stuck", "cross faction", "crossfaction", "members", "peers", "broadcast", "request config", "priority source", "mesh log", "recent activity", "sync rules", "live sync"}},
                {id = "world_buffs",     name = RCL["World Buffs"],        icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01", panel = "ShowSidebarWorldBuffs", aliases = {"world buff", "worldbuff", "buffs", "boon board", "raid buffs", "ony", "rallying cry", "songflower", "zandalar", "chronoboon", "who has buffs", "buff board", "wb board", "buff grid", "online toons", "buff tracker"}},
                {id = "remote_raid_cfg", name = RCL["Remote Raid Config"], icon = "Interface\\Icons\\INV_Letter_16",           panel = "ShowSidebarRemoteRaidConfig", aliases = {"remote raid", "remote config", "mesh raid", "edit toon", "push raid", "pull raid", "stuck", "fetching config", "remote edit", "remote", "config sync", "select toon", "unstuck"}},
            }
        },
        {
            id = "character",
            name = RCL["Character"],
            category = true,
            icon = "Interface\\Icons\\Ability_Warrior_Rampage",
            panel = "ShowSidebarCharacterOverview",
            warriorOnly = true,
            aliases = {"character", "spec", "talents", "stats"},
            children = {
                {id = "spec_detection", name = RCL["Spec Detection"], icon = "Interface\\Icons\\Ability_Warrior_Rampage", panel = "ShowSidebarSpecDetection", warriorOnly = true, aliases = {"spec", "talent", "fury", "arms", "protection", "prot", "talents"},                  sidebarVisibleKey = "spec_detection"},
                {id = "stats_bar",      name = RCL["Stats Bar"],      icon = "Interface\\Icons\\INV_Misc_Spyglass_03",  panel = "ShowSidebarStatsBar",      warriorOnly = true, aliases = {"stats", "ap", "attack power", "crit", "hit", "strength", "character", "bar", "character stats bar"},     sidebarVisibleKey = "stats_bar"},
            }
        },
        {
            id = "extras",
            name = RCL["Extras"],
            category = true,
            icon = "Interface\\Icons\\INV_Misc_Bomb_04",
            panel = "ShowSidebarExtrasOverview",
            aliases = {"extras", "extra", "macros", "macro", "smart macro", "nameplate", "nameplates", "debuff", "debuffs"},
            children = {
                {id = "nameplate_auras", name = RCL["Nameplates"],   icon = "Interface\\Icons\\Ability_Warrior_Sunder", panel = "ShowSidebarNameplates", aliases = {"nameplate", "nameplates", "debuff", "debuffs", "sunder", "expose", "armor", "plates", "nameplate debuffs", "range", "target range"}},
                {id = "smart_macros",    name = RCL["Smart Macros"], icon = "Interface\\Icons\\INV_Misc_Bomb_04",       panel = "ShowSidebarSmartMacro", aliases = {"smart macro", "smart macros", "dynamic macro", "target macro", "macro rewrite", "dynamite", "sapper", "holy water"}},
            }
        },
        {
            id = "home",
            name = RCL["Settings"],
            category = true,
            icon = "Interface\\Icons\\INV_Misc_Gear_01",
            panel = "ShowSidebarSettingsOverview",
            aliases = {"settings", "home", "welcome", "start", "options", "general", "help"},
            children = {
                {id = "general_behavior", name = RCL["General"],         icon = "Interface\\Icons\\INV_Misc_Gear_01",       panel = "ShowSidebarGeneralBehavior", aliases = {"general", "behavior", "settings", "options", "general & behavior", "enable", "minimap"}},
                {id = "font_settings",    name = RCL["Appearance"],      icon = "Interface\\Icons\\INV_Scroll_08",          panel = "ShowSidebarFontSettings", aliases = {"font", "color", "colour", "theme", "appearance", "style", "skin", "ui", "texture", "motion", "animation", "animations", "speed", "preview"}},
                {id = "profile_export",   name = RCL["Import / Export"], icon = "Interface\\Icons\\INV_Misc_Note_01",       panel = "ShowSidebarProfileExport", aliases = {"import", "export", "profile", "backup", "share", "copy", "paste"}},
                {id = "profiler",         name = RCL["Profiler"],        icon = "Interface\\Icons\\INV_Misc_PocketWatch_01", panel = "ShowSidebarProfiler", aliases = {"performance", "fps", "lag", "debug", "profiler", "cpu", "memory", "performance profiler"}},
                {id = "commands",         name = RCL["Commands"],        icon = "Interface\\Icons\\INV_Misc_Book_09",       panel = "ShowSidebarCommands", aliases = {"commands", "help", "slash", "list"}},
                -- lodAddon: loaded via LoadAddOn before the panel lookup if self[panel] is not yet defined.
                {id = "changelog",        name = RCL["Changelog"],       icon = "Interface\\Icons\\INV_Misc_Note_05",       panel = "ShowSidebarChangelog", lodAddon = "Readycheck_Extras", aliases = {"changelog", "what's new", "whats new", "updates", "version", "patch notes", "news", "history"}},
            }
        },
    }

    RC.SidebarState = RC.SidebarState or {
        selectedCategory = nil,
        selectedItem = nil,
        expandedCategories = {},
        currentPanel = nil
    }

    -- Writes which groups are open into this character's saved record the
    -- moment a group is folded or unfolded, so the list comes back the way
    -- it was left even after a reload with the window still open (closing
    -- the window saves it too, through SaveConfigurationToProfile).
    function RC:RememberSidebarState()
        local st = self.SidebarState
        local key = self.GetCharacterKey and self:GetCharacterKey()
        local chars = ReadycheckDB and ReadycheckDB.characters
        local rec = key and chars and chars[key]
        if not (st and type(rec) == "table") then return end
        local open = {}
        for id, on in pairs(st.expandedCategories or {}) do
            if on then open[id] = true end
        end
        rec.sidebarState = { expandedCategories = open }
    end

    -- pendingNavigation is set by external callers (slash commands, deep links) before the
    -- window exists; consumed once here then cleared.
    function RC:HandlePendingNavigation(frame)
        if not self.pendingNavigation then return end

        local nav = self.pendingNavigation
        self.pendingNavigation = nil

        local targetItem = nil

        if nav.type == "general" then
            for _, category in ipairs(self.MenuStructure) do
                if category.id == "home" and category.children then
                    self.SidebarState.expandedCategories["home"] = true
                    for _, child in ipairs(category.children) do
                        if child.id == "general_behavior" then
                            targetItem = child
                            break
                        end
                    end
                    break
                end
            end
        elseif nav.type == "raid" and nav.raidName then
            for _, category in ipairs(self.MenuStructure) do
                if category.id == "raids" and category.children then
                    self.SidebarState.expandedCategories["raids"] = true
                    for _, child in ipairs(category.children) do
                        if child.raidKey == nav.raidName then
                            targetItem = child
                            break
                        end
                    end
                    break
                end
            end
        elseif nav.type == "panel" and nav.panelId then
            nav.panelId = self:ResolvePageId(nav.panelId)
            for _, category in ipairs(self.MenuStructure) do
                if category.children then
                    for _, child in ipairs(category.children) do
                        if child.id == nav.panelId then
                            self.SidebarState.expandedCategories[category.id] = true
                            targetItem = child
                            break
                        end
                    end
                end
                if targetItem then break end
            end
        end

        if targetItem then
            self.SidebarState.selectedItem = targetItem.id
            self:BuildSidebar(frame, true)
            self:ShowSidebarPanel(frame, targetItem)

            for _, button in ipairs(frame.sidebar.buttons or {}) do
                local isSelected = (button.menuItem.id == targetItem.id)
                self:SetSidebarButtonState(button, isSelected, self.SidebarState.expandedCategories[button.menuItem.id])
            end
        end
    end

    -- RC:EncounterHasConfig / EncounterHasGearConfig / EncounterMenuName
    -- live in Systems/RaidData/RaidLookup.lua: the runtime boss lookup
    -- uses them too, and that file loads whether or not the UI does.

    -- Three-tier fallback for reading raid profile data across old/new save formats:
    -- GetActiveRaidProfile API, then db.raidProfiles, then legacy db.raidSettings.
    -- Bosses count once each (phases and horsemen fold into their boss).
    function RC:GetRaidConfigCounts(raidKey)
        local profile
        if self.GetActiveRaidProfile then
            profile = self:GetActiveRaidProfile(raidKey)
        elseif self.db and self.db.raidProfiles and self.db.raidProfiles[raidKey] then
            local raidData = self.db.raidProfiles[raidKey]
            local activeProfileName = raidData.activeProfile or "Default"
            profile = raidData.profiles and raidData.profiles[activeProfileName]
        elseif self.db and self.db.raidSettings and self.db.raidSettings[raidKey] then
            profile = self.db.raidSettings[raidKey]
        end

        local bossCount, trashCount = 0, 0
        if type(profile) ~= "table" then return bossCount, trashCount end
        if type(profile.bosses) == "table" then
            local seen = {}
            for key, boss in pairs(profile.bosses) do
                if self:EncounterHasConfig(boss) then
                    local name = self:EncounterMenuName(key)
                    if not seen[name] then
                        seen[name] = true
                        bossCount = bossCount + 1
                    end
                end
            end
        end
        if type(profile.trash) == "table" then
            for _, trash in pairs(profile.trash) do
                if self:EncounterHasConfig(trash) then trashCount = trashCount + 1 end
            end
        end
        return bossCount, trashCount
    end

    _sbs.SIDEBAR = SIDEBAR
    _sbs.TEXT = TEXT
