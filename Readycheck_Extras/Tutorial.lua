------------------------------------------------------------------------
-- Readycheck_Extras - First-Run Tour
-- Builds RC.Tutorial: a short guided walk around the settings window. One
-- part of the window at a time is lit (everything else is dimmed and a
-- gold ring pulses around it) with a callout beside it that says what
-- it is for, plus Back / Next / Skip.
--
-- WHO SEES IT. Whoever asks: the setup's Finish when its "Show me
-- around" tick is on (SetupWizard2.lua), and /rc tutorial. It never
-- opens by itself.
--
-- Each group on the left gets a stop (the group is opened and its pages
-- listed), then each main feature gets a closer look with its page open.
-- Only what this install has: the nav is read once at the start with every
-- group open, so a warrior-only page, a companion addon that is off or a
-- hidden page is neither shown nor counted. The nav list is scrolled so
-- the lit buttons are in view.
--
-- The dim layer does not take the mouse, so the window stays usable
-- while the tour is up; closing the window ends the tour. Positions are
-- re-fitted from a 0.25s ticker while the tour runs (the window can be
-- dragged or resized under it) and the ring pulse is an animation group,
-- so nothing here runs per frame.
------------------------------------------------------------------------
local function InitializeTutorial()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializeTutorial) return end
    if not (RC.UI and RC.db) then C_Timer.After(0.3, InitializeTutorial) return end

    RC.Tutorial = RC.Tutorial or {}
    local T = RC.Tutorial
    if T.initialized then return end
    T.initialized = true

    local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
    local CALLOUT_W   = 340
    local CALLOUT_PAD = 12
    local GAP         = 12      -- callout to spotlight
    local DIM_ALPHA   = 0.55
    local FIT_EVERY   = 0.25

    local function C(cat, key)
        if RC.GetColor then return RC:GetColor(cat, key) end
        return { r = 0.9, g = 0.9, b = 0.9, a = 1 }
    end

    local function Store()
        if type(ReadycheckDB) ~= "table" then return nil end
        if type(ReadycheckDB.tutorial) ~= "table" then ReadycheckDB.tutorial = {} end
        return ReadycheckDB.tutorial
    end

    local function Win()
        local w = RC.sidebarConfigFrame
        if w and w.IsVisible and w:IsVisible() then return w end
        return nil
    end

    local function NavButton(win, id)
        local sb = win and win.sidebar
        for _, b in ipairs((sb and sb.buttons) or {}) do
            if b.menuItem and b.menuItem.id == id and b:IsVisible() then return b end
        end
        return nil
    end

    -- A group (or page) entry from the nav menu, by id.
    local function MenuItem(id)
        for _, cat in ipairs(RC.MenuStructure or {}) do
            if cat.id == id then return cat end
            for _, child in ipairs(cat.children or {}) do
                if child.id == id then return child, cat end
            end
        end
        return nil
    end

    -- The search box filters the nav list; a step that points at a nav
    -- button needs the full list back.
    local function ClearSearch(win)
        local sb = win and win.sidebar
        if sb and sb.searchBox and sb.searchBox:GetText() ~= "" then
            sb.searchBox:SetText("")
            sb.searchBox:ClearFocus()
        end
    end

    -- The nav list scrolls. A button scrolled out of its viewport is still
    -- "visible" to the API and GetRect still reports where it would be,
    -- which can be anywhere on screen, so a nav step first scrolls its
    -- button (and, for a group, its pages below it) into view, and Fit
    -- clips to the viewport. The button lands 8px under the top edge so
    -- as many of its pages as fit show under it.
    local function ScrollNavTo(win, btn, last)
        local sb = win and win.sidebar
        local sf = sb and sb.scrollFrame
        local child, bar = sb and sb.scrollChild, sf and sf.scrollBar
        if not (sf and child and bar and btn) then return end
        local cTop, bTop, bBot = child:GetTop(), btn:GetTop(), (last or btn):GetBottom()
        local sTop, sBot = sf:GetTop(), sf:GetBottom()
        if not (cTop and bTop and bBot and sTop and sBot) then return end
        if bTop <= sTop and bBot >= sBot then return end
        local mn, mx = bar:GetMinMaxValues()
        local want = cTop - bTop - 8
        bar:SetValue(math.max(mn or 0, math.min(mx or 0, want)))
    end

    -- Nearest scroll frame above a region: the viewport it is clipped to.
    local function ScrollParent(f)
        local p = f and f.GetParent and f:GetParent()
        while p and p ~= UIParent do
            if p.GetObjectType and p:GetObjectType() == "ScrollFrame" then return p end
            p = p.GetParent and p:GetParent()
        end
        return nil
    end

    -- The pages a group has, as the nav shows them: children with a
    -- button right now (class and companion-addon filtering included).
    local function GroupPages(win, item)
        local out = {}
        for _, child in ipairs((item and item.children) or {}) do
            local b = NavButton(win, child.id)
            if b then out[#out + 1] = { item = child, button = b } end
        end
        return out
    end

    -- Opens a group the way a click on it does: expanded in the nav, its
    -- landing page in the content area (not when a page of it is about
    -- to be opened instead). The group toured before it is folded back
    -- so the list stays short. Nothing happens for a group this install
    -- has no button for.
    local function OpenGroup(win, id, forPage)
        local item = MenuItem(id)
        local st = RC.SidebarState
        if not (item and st and RC.BuildSidebar and NavButton(win, id)) then return nil end
        st.expandedCategories = st.expandedCategories or {}
        local rebuild = not st.expandedCategories[id]
        if T.lastGroup and T.lastGroup ~= id and st.expandedCategories[T.lastGroup] then
            st.expandedCategories[T.lastGroup] = nil
            rebuild = true
        end
        T.lastGroup = id
        st.expandedCategories[id] = true
        if rebuild then
            if not forPage then st.selectedItem = id end
            RC:BuildSidebar(win, false)
        end
        if not forPage and st.currentPanel ~= id and RC.SelectSidebarItem then
            RC:SelectSidebarItem(win, item, nil)
        end
        return item
    end

    -- Opens one page of a group (the group expanded first). Returns the
    -- page's nav button, nil when this install does not have it.
    local function OpenPage(win, groupId, pageId)
        local group = OpenGroup(win, groupId, true)
        local page = MenuItem(pageId)
        local st = RC.SidebarState
        local btn = group and page and NavButton(win, pageId)
        if not btn then return nil end
        if st.selectedItem ~= pageId and RC.SelectSidebarItem then
            RC:SelectSidebarItem(win, page, group)
        end
        return btn
    end

    -- One line per page, shown under the group's own description.
    local PAGE_TEXT = {
        general_behavior    = RCL["the minimap button, startup behaviour and the general switches"],
        reminder_settings   = RCL["how reminders look and sound: position, animation, sound and the spoken voice"],
        font_settings       = RCL["font, colours and the look of every Readycheck frame"],
        profile_export      = RCL["back your settings up as a string, or paste one in from another character"],
        profiler            = RCL["CPU and memory per system, for when something feels slow"],
        commands            = RCL["every /rc command on one page"],
        changelog           = RCL["what changed in each version"],
        mesh_sync           = RCL["join a mesh with a shared password; see who is connected and what syncs"],
        world_buffs         = RCL["the world buff board: who has which buffs, across your toons and friends"],
        remote_raid_cfg     = RCL["edit another character's raid configuration from here"],
        wt_pulltimers       = RCL["drop timers and alerts for world buffs"],
        wt_automation       = RCL["the chores around them: summons, gossip, turn-ins"],
        spec_detection      = RCL["reads Arms, Fury or Protection from your talents so reminders match"],
        stats_bar           = RCL["a small live bar of your attack power, crit, hit and more"],
        buff_pushoff        = RCL["warns when you are at the buff cap and something is about to be pushed off"],
        -- (Forever: the shout reaches the whole raid, no party tracker - Core_Flavor)
        battle_shout        = (not RC.FeatureOn or RC:FeatureOn("battle_shout_party"))
                                and RCL["reminds you to shout and tracks who in the party has it"]
                                or RCL["reminds you to shout when anyone your shout reaches is missing it"],
        boon_reminder       = RCL["reminds you to release your Chronoboon before a pull"],
        trinkets            = RCL["auto-swap trinkets around cooldowns and fights"],
        gear_manager        = RCL["gear sets and the on-screen buttons that equip them"],
        speed_swaps         = RCL["swap an item in, use it, swap back - rocket boots and the like"],
        equipment_reminder  = RCL["warns when a piece of gear you flagged is still equipped"],
        hotswap             = RCL["macros that swap gear around an ability - T2 for Battle Shout and so on"],
        trinket_bar         = RCL["an on-screen menu of your on-use trinkets"],
        consumables_checker = RCL["before a raid: what you are missing against a checklist"],
        consumables_bar     = RCL["your flasks, elixirs, food and scrolls on screen, with timers"],
        potions_bar         = RCL["healing and mana potions with their cooldowns"],
        weapons_bar         = RCL["weapon oils, stones and poisons with their time left"],
        nameplate_auras     = RCL["Sunder, Expose and other debuffs on enemy nameplates, plus range"],
        custom_reminders    = RCL["build your own reminders from triggers and conditions"],
        raid_buff_tracker   = RCL["tracks class buffs on you; can whisper the caster when one drops"],
        boss_debuff_tracker = RCL["tracks debuffs on the boss; can whisper whoever keeps them up"],
        smart_macros        = RCL["macros that rewrite themselves for the target - dynamite, sappers, holy water"],
        repair_reminder     = RCL["nags you to repair before durability becomes a problem"],
        boss_notes          = RCL["short notes that pop up when you target a boss or trash pack"],
        execute             = RCL["kill-time predictions learned from your own logged kills"],
        ttk_display         = RCL["the on-screen frame that shows time to kill during a fight"],
    }

    local function GroupBody(win, item, intro)
        local lines = { intro }
        local raids = {}
        for _, p in ipairs(GroupPages(win, item)) do
            local id = p.item.id
            if p.item.raidKey then
                raids[#raids + 1] = p.item.name
            elseif PAGE_TEXT[id] then
                lines[#lines + 1] = "|cffffd700" .. tostring(p.item.name) .. "|r - " .. PAGE_TEXT[id]
            end
        end
        if #raids > 0 then
            table.insert(lines, 2, "|cffffd700" .. table.concat(raids, ", ") .. "|r - " .. RCL["one page per boss in each"])
        end
        if #lines > 1 then lines[1] = lines[1] .. "\n" end
        return table.concat(lines, "\n")
    end

    -- One step per group in the nav column: the group is opened, its
    -- pages listed, and the ring covers the group and its pages. A group
    -- this install does not have (a warrior-only one on another class, a
    -- companion addon switched off) has no button, so its step is skipped.
    local function Group(id, title, intro)
        return {
            id = "group:" .. id, navId = id, place = "right", nav = true,
            title = title,
            prepare = function(win)
                ClearSearch(win)
                local item = OpenGroup(win, id)
                local pages = GroupPages(win, item)
                local last = pages[#pages] and pages[#pages].button
                ScrollNavTo(win, NavButton(win, id), last)
            end,
            target = function(win) return NavButton(win, id) end,
            also = function(win)
                local out = {}
                for _, p in ipairs(GroupPages(win, MenuItem(id))) do out[#out + 1] = p.button end
                return out
            end,
            body = function(win) return GroupBody(win, MenuItem(id), intro) end,
        }
    end

    -- A closer look at one page: the page is opened and the content area
    -- is lit. Skipped when this install does not have the page.
    local function Page(groupId, pageId, title, body)
        return {
            id = "page:" .. pageId, navId = pageId, place = "corner", nav = true,
            title = title, body = body,
            prepare = function(win)
                ClearSearch(win)
                local btn = OpenPage(win, groupId, pageId)
                if btn then ScrollNavTo(win, btn) end
            end,
            target = function(win)
                if not NavButton(win, pageId) then return nil end
                return win.contentArea
            end,
        }
    end

    ------------------------------------------------------------------
    -- Steps. target(win) returns the region to light; nil skips the step
    -- (a part of the window this install does not have). also(win) adds
    -- regions the ring grows to cover. place is where the callout goes
    -- relative to the lit region; "center" sits on it, "corner" inside
    -- its bottom-right so a page stays readable. body may be a
    -- function of the window, built when the step shows.
    ------------------------------------------------------------------
    T.steps = {
        {
            id = "welcome", place = "center", pad = 0,
            title = RCL["Welcome to Readycheck"],
            body  = RCL["This is the settings window. Open it any time with |cffffd700/rc|r or the minimap button.\n\nThis tour goes through every group on the left and takes a closer look at each of the main features - only the ones your character and your installed Readycheck addons have. Use Next and Back, or the X to skip it."],
            target = function(win) return win end,
        },
        {
            id = "search", place = "right",
            title = RCL["Search for any setting"],
            body  = RCL["Type what you are looking for - a page, a single option, a boss name. Each result jumps straight to the card it lives on."],
            prepare = ClearSearch,
            target = function(win) return win.sidebar and win.sidebar.searchContainer end,
        },
        {
            id = "content", place = "corner",
            title = RCL["Pages are made of cards"],
            body  = RCL["Click a group on the left to open it, then a page. Each page is a set of cards. Changes apply the moment you make them - there is no Save button - and settings are kept per character, so each of your toons has its own."],
            target = function(win) return win.contentArea end,
        },

        -- Reminders ---------------------------------------------------
        Group("reminders", RCL["Reminders"],
            RCL["Every reminder in one place: the popup they all share, the warrior ones, the buff and debuff trackers, and your own."]),
        Page("reminders", "reminder_settings", RCL["Reminder Settings"],
            RCL["Every reminder popup shares these: where it sits on screen, how it animates, the sound it plays and the spoken voice if you want one. The Test Reminder card at the bottom fires a sample so you can see and hear a change right away."]),
        Page("reminders", "battle_shout", RCL["Battle Shout"],
            (not RC.FeatureOn or RC:FeatureOn("battle_shout_party"))
                and RCL["Warns when your shout is about to fall off, and the party tracker shows who has it and the attack power it gives - it knows about T2 and other shout gear. Every reminder page looks like this: the switch at the top, then cards for timing, sound and display."]
                or RCL["Warns when your shout is about to fall off or anyone it reaches is missing it - on Forever it reaches the whole raid within 20 yards. Every reminder page looks like this: the switch at the top, then cards for timing, sound and display."]),
        Page("reminders", "buff_pushoff", RCL["Buff Pushoff"],
            RCL["Classic drops the oldest buff once you pass 32. This watches the count and warns when a consumable buff is about to be, or just was, pushed off, with an icon on the stats bar."]),
        Page("reminders", "raid_buff_tracker", RCL["Raid Buff Tracker"],
            RCL["Watches the class buffs on you - Fortitude, Intellect, Mark of the Wild, blessings - with time left, and calls out one about to expire or missing. Turn on whispers and it can ask the caster for a rebuff: once, with a cooldown, so it never spams."]),
        Page("reminders", "boss_debuff_tracker", RCL["Boss Debuff Tracker"],
            RCL["The same for debuffs on your target: Sunder, the curses, Scorch stacks, Demo Shout, Faerie Fire. Timers for other people's debuffs are estimated from when they were applied. Whispers can nudge whoever keeps a debuff up - never for things like Sunder that everyone stacks."]),
        Page("reminders", "custom_reminders", RCL["Custom Reminders"],
            RCL["Your own reminders: pick a trigger and conditions, and Readycheck fires a popup with the sound and voice from Reminder Settings. Everything the built-in reminders can do, for anything you want to be told."]),

        -- Consumables -------------------------------------------------
        Group("consumables", RCL["Consumables"],
            RCL["The pre-raid check and the bars that sit on screen."]),
        Page("consumables", "consumables_checker", RCL["Consumables Checker"],
            RCL["Before the first pull, the checker compares your bags against a list - flasks, elixirs, food, potions, protection potions, reagents, Chronoboon - and shows what is short. Right-click an item in the checker window to drop it from the list, or edit the amounts it expects. It can also count what you have on the Auction House and in the mailbox."]),
        Page("consumables", "consumables_bar", RCL["Consumables Bar"],
            RCL["Quick-use buttons for your raid consumables with the buff timer on each, so you can see what is about to run out and click to reapply. Move and lock it like any bar."]),
        Page("consumables", "potions_bar", RCL["Potions Bar"],
            RCL["Healing and mana potions, protection potions and the like, with cooldowns on the buttons. Visibility Mode can keep it hidden until you are in combat."]),
        Page("consumables", "weapons_bar", RCL["Weapons Bar"],
            RCL["Sharpening stones, oils and poisons for each weapon with the time left on the current one; click to reapply."]),

        -- Gear --------------------------------------------------------
        Group("equipment", RCL["Gear"],
            RCL["Everything that puts gear on and takes it off for you."]),
        Page("equipment", "gear_manager", RCL["Gear Manager"],
            RCL["Gear sets and the dockable buttons that equip them, with each swap shown on the button. Boss pages use these sets for engage and after-death swaps. This page sets how the buttons behave, their text and tooltips, and how a swap retries if an item was busy."]),
        Page("equipment", "trinkets", RCL["Trinket Manager"],
            RCL["Automatic trinket rotation. Build a queue per slot from the trinkets you own; when an on-use buff ends and its cooldown still has time left, the next ready one is swapped in, and passive trinkets give way to ready on-use ones. Keep several configs for different situations, and a boss page can lock a slot while the boss is alive."]),
        Page("equipment", "speed_swaps", RCL["On-Use Gear Swaps"],
            RCL["For items you only want on while you use them - rocket boots, a skull, a belt: swap it in, use it, and the original piece goes back when its buff ends. Add the items here."]),
        Page("equipment", "hotswap", RCL["Hotswap Macros"],
            RCL["Swaps a buff set in, fires the ability, and swaps your normal set back - T2 for Battle Shout, Diamond Flask and so on. Out of combat only; a press in combat can queue the swap for the moment combat ends. The page has the set naming rules and the macros to copy."]),

        -- Raids -------------------------------------------------------
        Group("raids", RCL["Raids"],
            RCL["Where you set up a raid before you go in."]),
        Page("raids", "mc", RCL["A raid page"],
            RCL["Pick a boss or a trash section. Each boss has tiles for what to remind you of on the pull - Death Wish, Recklessness, potion, trinkets, utility items, defensives, racial - plus a gear swap for engage and after a death, and the kill history that Fight Analytics learns from. Apply to all bosses copies a setting across the raid. Profiles keep a Farm and a Prog setup side by side, and the setup wizard can import a built-in preset to start from."]),
        Page("raids", "boss_notes", RCL["Boss & Trash Notes"],
            RCL["Short notes that appear when you target a boss or a specific trash mob - the thing you always forget on this pull. Notes can be kept per profile so Farm and Prog say different things."]),

        -- Fight Analytics ---------------------------------------------
        Group("combat", RCL["Fight Analytics"],
            RCL["Kill timing."]),
        Page("combat", "execute", RCL["ML Predictions"],
            RCL["Readycheck records your kill times per boss and learns from them to predict how long the next kill will take, which is what drives the timing reminders. Add kills by hand, tune the learning, and override a boss if your raid is faster or slower than usual."]),
        Page("combat", "ttk_display", RCL["TTK Display"],
            RCL["The on-screen frame that shows the predicted time to kill, counting down during a boss fight. Size, font and position are here; Edit Mode moves it too."]),

        -- World Tools -------------------------------------------------
        -- (where this game version has no world buffs worth timing, only
        -- the summon accept is left: Core_Flavor)
        Group("world_tools", RCL["World Tools"],
            (not RC.FeatureOn or RC:FeatureOn("world_tools")) and RCL["Everything around world buffs outside the raid."]
                or RCL["Accepting summons on your own terms."]),
        Page("world_tools", "wt_pulltimers", RCL["Buff Drops"],
            RCL["Timers for upcoming world buff drops, with alerts before each one lands so you are in position when the head goes in."]),
        Page("world_tools", "wt_automation", RCL["Automation"],
            (not RC.FeatureOn or RC:FeatureOn("world_tools"))
                and RCL["The chores around world buffs: accepting summons, skipping gossip, turning in heads and quests. Each one is a switch."]
                or RCL["Accept a summon on its own: every time, or after your PvP flag drops on a taxi."]),

        -- Mesh --------------------------------------------------------
        Group("mesh", RCL["Mesh Network"],
            RCL["Optional. Links your own accounts and trusted friends so settings, raid configs and world buff timers travel between them. Everything else works without it."]),
        Page("mesh", "mesh_sync", RCL["Connection"],
            RCL["A mesh is a private group of characters - your alts and trusted friends - that keep their Readycheck settings in sync through in-game whispers. Set a shared password here, see who is connected, and choose what syncs. Nothing leaves the game."]),
        Page("mesh", "world_buffs", RCL["World Buffs"],
            RCL["The world buff board: every character on your mesh, which world buffs each one is holding and how long is left - who is ready to raid, and who still needs Ony or Songflower."]),

        -- Character (warriors) ----------------------------------------
        Group("character", RCL["Character"],
            RCL["Warrior pages: your spec and your live stats."]),
        Page("character", "spec_detection", RCL["Spec Detection"],
            RCL["Reads Arms, Fury or Protection from your talents so reminders match what you are playing, and can announce your spec when you enter a raid. The cards set what it shows, when, and which talents it lists."]),
        Page("character", "stats_bar", RCL["Stats Bar"],
            RCL["A slim bar at the top of the screen with your live attack power, crit, hit and whatever else you tick in the Stats card. Handy for checking that a buff or a gear swap actually landed."]),

        -- Extras ------------------------------------------------------
        Group("extras", RCL["Extras"],
            RCL["Two helpers: your debuffs on enemy nameplates, and macros that rewrite themselves."]),
        Page("extras", "nameplate_auras", RCL["Nameplates"],
            RCL["Shows your debuffs - Sunder stacks, Expose Armor and the rest - on enemy nameplates with their time left, and can show range to the target."]),
        Page("extras", "smart_macros", RCL["Smart Macros"],
            RCL["Make an empty macro in the Blizzard macro window, name it here, and add rules. On every target change the rules are checked top to bottom and the first match whose item is in your bags and off cooldown is written into the macro: dynamite on one target, holy water on undead, a sapper on a pack."]),

        -- Settings ----------------------------------------------------
        Group("home", RCL["Settings"],
            RCL["The basics: the master switch, the look of everything, profiles and help."]),
        Page("home", "font_settings", RCL["Appearance"],
            RCL["One font, one set of textures and one colour set for every Readycheck frame, from the bars to this window. Change the font here and it applies everywhere at once."]),
        Page("home", "profile_export", RCL["Import / Export"],
            RCL["Settings are per character. Export turns this character's settings into a string you can paste on another character, or send to a friend; Import reads one back in. The Mesh Network does this automatically between your own characters."]),

        {
            id = "editmode", place = "below",
            title = RCL["Move things where you want them"],
            body  = RCL["Edit Mode shows every Readycheck bar and frame over a grid so you can drag them into place. Save & lock when you are done. Most bars can also be unlocked on their own with a right-click."],
            target = function(win) return win.editModeToolButton end,
        },
        {
            id = "done", place = "center", pad = 0,
            title = RCL["That is the tour"],
            body  = RCL["Replay it any time with |cffffd700/rc tutorial|r, or run the setup wizard again with |cffffd700/rc setup|r. Questions or feedback: Discord |cffffd700zac12|r. Have a good raid."],
            target = function(win) return win end,
        },
    }

    -- Which groups and pages this install actually has, read off the
    -- nav itself with every group opened for a moment (class, companion
    -- addons and hidden pages all filtered the way the nav does it), so
    -- a page that is not there for this character is never prepared,
    -- shown or counted. Taken once per tour.
    local function SnapshotNav(win)
        local present = {}
        local st = RC.SidebarState
        local sb = win and win.sidebar
        if not (st and sb and RC.BuildSidebar and RC.MenuStructure) then
            for _, b in ipairs((sb and sb.buttons) or {}) do
                if b.menuItem and b.menuItem.id then present[b.menuItem.id] = true end
            end
            return present
        end
        ClearSearch(win)
        st.expandedCategories = st.expandedCategories or {}
        local saved = {}
        for k, v in pairs(st.expandedCategories) do saved[k] = v end
        for _, cat in ipairs(RC.MenuStructure) do st.expandedCategories[cat.id] = true end
        RC:BuildSidebar(win, true)
        for _, b in ipairs(sb.buttons or {}) do
            if b.menuItem and b.menuItem.id then present[b.menuItem.id] = true end
        end
        st.expandedCategories = saved
        RC:BuildSidebar(win, true)
        return present
    end

    -- Does this step apply to this install? Steps with no nav id always do.
    local function Applies(step)
        if not step.navId then return true end
        return T.present == nil or T.present[step.navId] == true
    end

    -- Position of a step among the ones that apply, and how many there are.
    local function Numbering(idx)
        local pos, total = 0, 0
        for i, step in ipairs(T.steps) do
            if Applies(step) then
                total = total + 1
                if i == idx then pos = total end
            end
        end
        return pos, total
    end

    ------------------------------------------------------------------
    -- Frames, built once on first use
    ------------------------------------------------------------------
    local function Build()
        if T.dim then return end

        local dim = CreateFrame("Frame", "ReadycheckTourDim", UIParent)
        dim:SetAllPoints(UIParent)
        dim:SetFrameStrata("FULLSCREEN_DIALOG")
        dim:SetFrameLevel(100)
        dim:EnableMouse(false)
        dim.strips = {}
        for _, side in ipairs({ "top", "bottom", "left", "right" }) do
            local t = dim:CreateTexture(nil, "BACKGROUND")
            t:SetTexture(FLAT)
            t:SetVertexColor(0, 0, 0, DIM_ALPHA)
            dim.strips[side] = t
        end
        dim:Hide()
        T.dim = dim

        -- The pulsing ring. A frame of its own so one alpha animation
        -- drives all four edges.
        local ring = CreateFrame("Frame", nil, dim)
        ring:SetFrameLevel(101)
        ring:EnableMouse(false)
        ring.border = RC.UI:CreateSimpleBorder(ring, 2)
        RC.UI:UpdateBorderColor(ring.border, C("ui", "accentGold"), 1)
        local ag = ring:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local pulse = ag:CreateAnimation("Alpha")
        pulse:SetFromAlpha(1)
        pulse:SetToAlpha(0.35)
        pulse:SetDuration(0.7)
        ring.pulse = ag
        T.ring = ring

        -- The callout: flat window fill, 1px ring, title, body, step
        -- counter and the two buttons. Takes the mouse so a click on it
        -- does not land on whatever is underneath.
        local co = CreateFrame("Frame", "ReadycheckTourCallout", UIParent)
        co:SetWidth(CALLOUT_W)
        co:SetPoint("CENTER")      -- a rect from birth, so text lays out before the first Fit
        co:SetFrameStrata("FULLSCREEN_DIALOG")
        co:SetFrameLevel(120)
        co:EnableMouse(true)
        co:SetClampedToScreen(true)
        co.bg = co:CreateTexture(nil, "BACKGROUND")
        co.bg:SetAllPoints()
        co.bg:SetTexture(FLAT)
        local wb = C("ui", "windowBackground")
        co.bg:SetVertexColor(wb.r, wb.g, wb.b, 1)
        co.border = RC.UI:CreateSimpleBorder(co)
        RC.UI:UpdateBorderColor(co.border, C("ui", "accentGold"), 0.9)

        co.title = RC:CreateFontString(co, "OVERLAY", nil, 13)
        co.title:SetPoint("TOPLEFT", co, "TOPLEFT", CALLOUT_PAD, -CALLOUT_PAD)
        co.title:SetWidth(CALLOUT_W - 2 * CALLOUT_PAD - 22)
        co.title:SetJustifyH("LEFT")
        co.title:SetWordWrap(true)
        local gold = C("ui", "headerText")
        co.title:SetTextColor(gold.r, gold.g, gold.b, 1)

        co.body = RC:CreateFontString(co, "OVERLAY", nil, 11)
        co.body:SetPoint("TOPLEFT", co.title, "BOTTOMLEFT", 0, -6)
        co.body:SetWidth(CALLOUT_W - 2 * CALLOUT_PAD)
        co.body:SetJustifyH("LEFT")
        co.body:SetWordWrap(true)
        co.body:SetNonSpaceWrap(true)
        co.body:SetSpacing(2)
        local norm = C("text", "normal")
        co.body:SetTextColor(norm.r, norm.g, norm.b, 1)

        co.skip = RC.UI:CreateXCloseButton(co, 18, function() T:Skip() end)
        co.skip:SetPoint("TOPRIGHT", co, "TOPRIGHT", -5, -5)
        co.skip:HookScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
            GameTooltip:SetText(RCL["Skip the tour"], 1, 1, 1)
            GameTooltip:AddLine(RCL["It will not come back by itself. /rc tutorial replays it."], 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        co.skip:HookScript("OnLeave", function() GameTooltip:Hide() end)

        co.counter = RC:CreateFontString(co, "OVERLAY", nil, 10)
        co.counter:SetPoint("BOTTOMLEFT", co, "BOTTOMLEFT", CALLOUT_PAD, CALLOUT_PAD + 4)
        local gray = C("text", "gray")
        co.counter:SetTextColor(gray.r, gray.g, gray.b, 1)

        co.next = RC.UI:CreateStyledButton(co, RCL["Next"], 84, 22)
        co.next:SetPoint("BOTTOMRIGHT", co, "BOTTOMRIGHT", -CALLOUT_PAD, CALLOUT_PAD)
        co.next:SetScript("OnClick", function() T:Next() end)

        co.back = RC.UI:CreateStyledButton(co, RCL["Back"], 64, 22)
        co.back:SetPoint("RIGHT", co.next, "LEFT", -6, 0)
        co.back:SetScript("OnClick", function() T:Back() end)
        -- the 5.0 popup type, close glyph and buttons (UIF_Dialogs); the
        -- callout keeps its gold edge so it stands out from the window
        RC.UI:SkinPopup(co, { title = co.title, titleSize = 14, close = co.skip, texts = { co.body },
            dims = { co.counter }, buttons = { co.back }, primary = co.next, chrome = false })

        co:Hide()
        T.callout = co
    end

    ------------------------------------------------------------------
    -- Geometry. Everything is placed in UIParent's space; the target's
    -- own scale is folded in so a window at 0.95 still gets a tight ring.
    ------------------------------------------------------------------
    local function TargetRect(tgt, pad)
        if not (tgt and tgt.GetRect) then return nil end
        local l, b, w, h = tgt:GetRect()
        if not l or not w or w <= 0 or h <= 0 then return nil end
        -- inside a scroll frame: only the part in the viewport is real
        local sf = ScrollParent(tgt)
        if sf then
            local sl, sb, sw, sh = sf:GetRect()
            if sl then
                local r, t = math.min(l + w, sl + sw), math.min(b + h, sb + sh)
                l, b = math.max(l, sl), math.max(b, sb)
                w, h = r - l, t - b
                if w <= 4 or h <= 4 then return nil end
            end
        end
        local s = (tgt:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
        l, b, w, h = l * s, b * s, w * s, h * s
        pad = pad or 6
        return l - pad, b - pad, w + 2 * pad, h + 2 * pad
    end

    -- The step's whole lit area: its target plus whatever also() adds
    -- (a group's pages), each clipped to its viewport first.
    local function StepRect(step, win, tgt)
        local l, b, w, h = TargetRect(tgt, step.pad)
        if not l then return nil end
        local r, t = l + w, b + h
        if step.also then
            for _, f in ipairs(step.also(win) or {}) do
                local fl, fb, fw, fh = TargetRect(f, step.pad)
                if fl then
                    l, b = math.min(l, fl), math.min(b, fb)
                    r, t = math.max(r, fl + fw), math.max(t, fb + fh)
                end
            end
        end
        return l, b, r - l, t - b
    end

    local function Strip(t, x, y, w, h)
        if w <= 1 or h <= 1 then t:Hide() return end
        t:ClearAllPoints()
        t:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
        t:SetSize(w, h)
        t:Show()
    end

    local function PlaceCallout(co, place, l, b, w, h)
        local W, H = UIParent:GetWidth(), UIParent:GetHeight()
        local cw, ch = co:GetWidth(), co:GetHeight()
        co:ClearAllPoints()
        if place == "center" then
            co:SetPoint("CENTER", UIParent, "BOTTOMLEFT", l + w / 2, b + h / 2)
            return
        elseif place == "corner" then
            -- inside the lit area, bottom-right, so the page stays readable
            co:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", l + w - 16, b + 16)
            return
        end
        local fitsRight = (l + w + GAP + cw) <= W - 4
        local fitsLeft  = (l - GAP - cw) >= 4
        local fitsBelow = (b - GAP - ch) >= 4
        local order
        if place == "right" then order = { "right", "left", "below", "above" }
        elseif place == "left" then order = { "left", "right", "below", "above" }
        elseif place == "below" then order = { "below", "above", "right", "left" }
        else order = { "above", "below", "right", "left" } end
        for _, p in ipairs(order) do
            if p == "right" and fitsRight then
                co:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l + w + GAP, b + h)
                return
            elseif p == "left" and fitsLeft then
                co:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", l - GAP, b + h)
                return
            elseif p == "below" and fitsBelow then
                co:SetPoint("TOP", UIParent, "BOTTOMLEFT", l + w / 2, b - GAP)
                return
            elseif p == "above" and (b + h + GAP + ch) <= H - 4 then
                co:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", l + w / 2, b + h + GAP)
                return
            end
        end
        -- nowhere fits: on top of it, clamped to the screen
        co:SetPoint("CENTER", UIParent, "BOTTOMLEFT", l + w / 2, b + h / 2)
    end

    -- Lays the dim strips, the ring and the callout around the current
    -- step's target. Returns false when the target is gone.
    function T:Fit()
        local step = self.steps[self.index]
        local win = Win()
        if not (step and win) then return false end
        local tgt = step.target(win)
        if not (tgt and tgt.IsVisible and tgt:IsVisible()) then return false end
        local l, b, w, h = StepRect(step, win, tgt)
        if not l then return false end
        local W, H = UIParent:GetWidth(), UIParent:GetHeight()

        local s = self.dim.strips
        Strip(s.top,    0,     b + h, W,           H - (b + h))
        Strip(s.bottom, 0,     0,     W,           b)
        Strip(s.left,   0,     b,     l,           h)
        Strip(s.right,  l + w, b,     W - (l + w), h)

        self.ring:ClearAllPoints()
        self.ring:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", l, b)
        self.ring:SetSize(w, h)

        PlaceCallout(self.callout, step.place, l, b, w, h)
        self.lastRect = { l, b, w, h }
        self.fitted = true
        return true
    end

    -- A nav step's scroll may not have moved the button yet when the
    -- step is shown; the ring and callout stay hidden until the ticker
    -- gets a fit, and the step is given up after FIT_PATIENCE seconds.
    local FIT_PATIENCE = 1.5
    function T:Unfit()
        self.fitted = false
        self.lastRect = nil
        if self.ring then self.ring:Hide() end
        if self.callout then self.callout:Hide() end
    end

    local function RectMoved(a, l, b, w, h)
        if not a then return true end
        return math.abs(a[1] - l) > 0.5 or math.abs(a[2] - b) > 0.5
            or math.abs(a[3] - w) > 0.5 or math.abs(a[4] - h) > 0.5
    end

    ------------------------------------------------------------------
    -- Showing a step
    ------------------------------------------------------------------
    function T:ShowStep(idx, dir)
        local win = Win()
        if not win then self:Stop("closed") return end
        dir = dir or 1
        self.dir = dir
        local n = #self.steps
        -- walk past steps this install does not have
        while idx >= 1 and idx <= n do
            local step = self.steps[idx]
            if Applies(step) then
                if step.prepare then step.prepare(win) end
                local tgt = step.target(win)
                if tgt and tgt.IsVisible and tgt:IsVisible() then break end
            end
            idx = idx + dir
        end
        if idx < 1 then idx = 1 end
        if idx > n then self:Stop("finished", true) return end
        self.index = idx

        local step = self.steps[idx]
        local co = self.callout
        co.title:SetText(step.title or "")
        local body = step.body
        if type(body) == "function" then body = body(win) end
        co.body:SetText(body or "")
        local pos, total = Numbering(idx)
        co.counter:SetText(string.format(RCL["%d of %d"], pos, total))
        local bodyH = co.body:GetStringHeight() or 40
        local titleH = co.title:GetStringHeight() or 14
        co:SetHeight(CALLOUT_PAD + titleH + 6 + bodyH + 14 + 22 + CALLOUT_PAD)

        if idx == 1 then co.back:Hide() else co.back:Show() end
        if pos == total then
            co.next.text:SetText(RCL["Done"])
            co.next:SetActive(true)
        else
            co.next.text:SetText(RCL["Next"])
            co.next:SetActive(false)
        end

        self.shownAt = GetTime()
        if self:Fit() then
            self:Reveal()
        elseif step.nav then
            self:Unfit()        -- the ticker shows it once the scroll lands
            self.dim:Show()
        else
            self:Stop("lost")
        end
    end

    function T:Reveal()
        self.dim:Show()
        self.ring:Show()
        if self.ring.pulse and not self.ring.pulse:IsPlaying() then self.ring.pulse:Play() end
        self.callout:Show()
        self.callout:Raise()
    end

    function T:Next()
        if not self.active then return end
        if self.index >= #self.steps then self:Stop("finished", true) return end
        self:ShowStep(self.index + 1, 1)
    end

    function T:Back()
        if not self.active then return end
        self:ShowStep(self.index - 1, -1)
    end

    function T:Skip()
        self:Stop("skipped", true)
    end

    -- mode: "wizard" (the setup's Finish) or "manual" (/rc tutorial,
    -- the debug page).
    function T:Start(mode)
        if self.active then return true end
        if not Win() then return false end
        Build()
        self.active = true
        self.mode = mode or "manual"
        self.index = 0
        self.lastRect = nil
        self.fitted = false
        self.lastGroup = nil
        self.present = SnapshotNav(Win())
        local me = self
        self.ticker = RC.Profiler:TrackTicker("Tutorial:Fit", FIT_EVERY, function()
            if not me.active then return end
            local win = Win()
            if not win then me:Stop("closed") return end
            local step = me.steps[me.index]
            local tgt = step and step.target(win)
            if not (tgt and tgt:IsVisible()) then me:Stop("lost") return end
            local l, b, w, h = StepRect(step, win, tgt)
            if not l then
                -- scrolled out of its viewport (or not scrolled in yet)
                if me.fitted then me:Unfit() end
                if step.nav and step.prepare then step.prepare(win) end
                if GetTime() - (me.shownAt or 0) > FIT_PATIENCE then
                    -- a nav button that will not scroll into view: skip
                    -- its step rather than end the tour
                    if step.nav then me:ShowStep(me.index + (me.dir or 1), me.dir) else me:Stop("lost") end
                end
                return
            end
            if not me.fitted then
                if me:Fit() then me:Reveal() end
            elseif RectMoved(me.lastRect, l, b, w, h) then
                me:Fit()
            end
        end)
        self:ShowStep(1, 1)
        RC:DebugPrint("Tutorial started (" .. self.mode .. ")", "config")
        return true
    end

    -- markDone: the player finished or skipped it (written down for the
    -- status line). A window closed under the tour leaves that alone.
    function T:Stop(reason, markDone)
        if self.ticker then self.ticker:Cancel() self.ticker = nil end
        if self.dim then self.dim:Hide() end
        if self.ring then
            if self.ring.pulse then self.ring.pulse:Stop() end
            self.ring:Hide()
        end
        if self.callout then self.callout:Hide() end
        local wasActive = self.active
        self.active = false
        if markDone then
            local st = Store()
            if st then st.done = true end
        end
        if wasActive then
            RC:DebugPrint("Tutorial stopped (" .. tostring(reason) .. ")", "config")
        end
    end

    -- Debug / testing helpers (the Debug page and /rc tutorial use these).
    function T:Reset()
        self:Stop("reset")
        if type(ReadycheckDB) ~= "table" then return end
        ReadycheckDB.tutorial = { fresh = true }
    end

    function T:MarkDone()
        self:Stop("marked done")
        local st = Store()
        if st then st.done = true end
    end

    function T:Status()
        local st = (type(ReadycheckDB) == "table") and ReadycheckDB.tutorial or nil
        if not st then
            return RCL["Tour: not a fresh install. /rc tutorial plays it."]
        end
        return string.format(RCL["Tour: fresh=%s done=%s active=%s"],
            tostring(st.fresh and true or false),
            tostring(st.done and true or false), tostring(self.active and true or false))
    end
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
if IsLoggedIn() then
    initFrame:UnregisterEvent("PLAYER_LOGIN")
    InitializeTutorial()
else
    initFrame:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_LOGIN" then
            self:UnregisterEvent("PLAYER_LOGIN")
            C_Timer.After(0.5, InitializeTutorial)
        end
    end)
end
