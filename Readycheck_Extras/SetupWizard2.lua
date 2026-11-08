------------------------------------------------------------------------
-- Readycheck_Extras - The setup (step by step)
-- Builds RC.SetupWizard: one window of short steps with a rail of steps
-- down the left and a preview on every step, that sets Readycheck up the
-- way a new player wants it. Replaces SetupWizard.lua (kept on disk, not
-- loaded). Core_Scan lazy-loads this addon and calls Wizard:Open() once
-- per account (see there); /rc setup and the General page open it again.
--
--   1. Welcome          what is about to happen; skip everything
--   2. Game version     what this client runs, what is off here (Core_Flavor)
--   3. Character        class, detected spec, and the role you play (recorded)
--   4. Features         the feature groups on / off, a miniature each
--   5. Consume reminders the raid consume reminders and the alert sounds
--   6. Raid profiles    the active profile per raid, the ready-made presets
--   7. Layout           a named arrangement of the frames (SetupLayouts)
--   8. Profile          start fresh, copy another character, paste a string
--   9. All set          the summary, the commands, Finish & tour
--
-- EVERYTHING IS OPTIONAL and nothing is written until a control is used:
-- Next without touching anything changes nothing. Each control writes the
-- same keys the settings pages write, and saves to the profile at once
-- (RC:SaveConfigurationToProfile), as the pages do. Closing mid-way keeps
-- what was already chosen; lastStep is saved every view so it resumes.
--
-- BOOKKEEPING: RC.db.setupWizard = { version = 2, completed, lastStep,
-- visited = {}, role = "auto" | "tank" | "melee" | "ranged" | "healer" }
-- (per character, never exported or synced - see PM_Registry). The role is
-- RECORDED only; nothing changes its defaults by it.
--
-- Combat: the wizard registers no events of its own but the two combat
-- ones (hide for a fight, back after), and runs no tickers.
------------------------------------------------------------------------
local function InitializeSetupWizard2()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializeSetupWizard2) return end
    if not (RC.UI and RC.db) then C_Timer.After(0.3, InitializeSetupWizard2) return end
    if RC.SetupWizard and RC.SetupWizard.VERSION == 2 then return end

    local Wizard = RC.SetupWizard or {}
    RC.SetupWizard = Wizard
    Wizard.VERSION = 2

    local W, H = 720, 560
    local HEADER_H = 30
    local RAIL_W = 160
    local NAV_H = 48
    local PAD = 14
    local PAGE_W = W - RAIL_W - 2

    local FLAT = RC.UI.FLAT or "Interface\\Buttons\\WHITE8X8"
    local function C(cat, key) return RC:GetColor(cat, key) end

    local function Font(parent, size, outline)
        local fs = parent:CreateFontString(nil, "OVERLAY")
        RC:ApplyCustomFont(fs, size or 11, outline or "")
        if RC.trackedFonts then table.insert(RC.trackedFonts, fs) end
        fs._wrFontSize, fs._wrFontOutline = size or 11, outline or ""
        return fs
    end

    local function Text(parent, text, size, cat, key, outline)
        local fs = Font(parent, size, outline)
        local c = C(cat or "text", key or "normal")
        fs:SetText(text)
        fs:SetTextColor(c.r, c.g, c.b, c.a or 1)
        return fs
    end

    local function Tip(frame, title, body)
        if RC.SetupTip then RC.SetupTip(frame, title, body) end
    end

    local function Button(parent, text, w, h) return RC.UI:CreateStyledButton(parent, text, w or 110, h or 24) end

    local function AddonOn(name)
        if not name then return true end
        local IsLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
        return (IsLoaded and IsLoaded(name)) and true or false
    end

    local function InCombat()
        return (InCombatLockdown and InCombatLockdown()) or (UnitAffectingCombat and UnitAffectingCombat("player")) or false
    end

    local function Save() RC:SaveConfigurationToProfile() end

    local function DB()
        if not RC.db then return {} end
        if type(RC.db.setupWizard) ~= "table" then RC.db.setupWizard = { completed = false, lastStep = 1 } end
        local d = RC.db.setupWizard
        if type(d.visited) ~= "table" then d.visited = {} end
        if d.role == nil then d.role = "auto" end
        return d
    end
    Wizard.DB = DB

    ------------------------------------------------------------------
    -- Session: what changed this opening, the step list
    ------------------------------------------------------------------
    local S, steps, index
    local frame, rail, pagesHost

    local function Note(key, text)
        if not S.notes[key] then S.noteOrder[#S.noteOrder + 1] = key end
        S.notes[key] = text
    end
    Wizard.Note = Note

    local function NeedsReload(key, label) S.reloadExtra[key] = label end

    function Wizard:ReloadNeeded()
        local out = {}
        if not S then return out end
        local keys = {}
        for k in pairs(S.reloadExtra) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do out[#out + 1] = S.reloadExtra[k] end
        return out
    end

    local function Clear(f)
        for _, c in ipairs({ f:GetChildren() }) do
            c:Hide()
            c:ClearAllPoints()
            c:SetParent(nil)
        end
        for _, r in ipairs({ f:GetRegions() }) do
            r:Hide()
            r:ClearAllPoints()
        end
    end

    -- the page's title, one line of help under it, the gold rule; returns
    -- the y the content starts at
    local function Title(host, title, sub)
        local t = Text(host, title, 15, "ui", "headerText", "OUTLINE")
        t:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -12)
        local s = Text(host, sub, 10, "text", "gray")
        s:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -5)
        s:SetWidth(PAGE_W - 2 * PAD)
        s:SetJustifyH("LEFT")
        s:SetWordWrap(true)
        local rule = host:CreateTexture(nil, "ARTWORK")
        rule:SetTexture(FLAT)
        rule:SetHeight(1)
        rule:SetPoint("TOPLEFT", s, "BOTTOMLEFT", 0, -8)
        rule:SetWidth(PAGE_W - 2 * PAD)
        local a = C("ui", "accentGold")
        rule:SetVertexColor(a.r, a.g, a.b, 0.6)
        return -12 - 16 - 5 - math.max(12, s:GetStringHeight() or 12) - 8 - 12
    end

    local function Label(host, text, x, y)
        local fs = Text(host, text, 12, "ui", "headerText", "OUTLINE")
        fs:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
        return fs
    end

    local function Desc(host, text, x, y, width)
        local fs = Text(host, text, 10, "text", "gray")
        fs:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
        fs:SetWidth(width)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        return fs, math.max(12, fs:GetStringHeight() or 12)
    end

    -- a bordered box: the card shell the pages use (flat fill, 1px ring)
    local function Box(parent, w, h, key)
        local f = CreateFrame("Frame", nil, parent)
        f:SetSize(w, h)
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints()
        f.bg:SetTexture(FLAT)
        local c = C("ui", key or "cardBackground")
        f.bg:SetVertexColor(c.r, c.g, c.b, c.a or 1)
        f.border = RC.UI:CreateSimpleBorder(f)
        RC.UI:UpdateBorderColor(f.border, C("ui", "borderNormal"), 0.55)
        return f
    end

    local function Scroll(host, y, bottom)
        local sf = CreateFrame("ScrollFrame", nil, host)
        sf:SetPoint("TOPLEFT", host, "TOPLEFT", 0, y)
        sf:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -18, bottom or 8)
        local child = CreateFrame("Frame", nil, sf)
        child:SetWidth(PAGE_W - 18)
        child:SetHeight(1)
        sf:SetScrollChild(child)
        local bar = RC.UI:AttachScrollbar(sf, host, { width = 12 })
        bar:ClearAllPoints()
        bar:SetPoint("TOPRIGHT", host, "TOPRIGHT", -4, y)
        bar:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -4, bottom or 8)
        return sf, child, bar
    end

    local function FinishScroll(sf, child, bar, h)
        child:SetHeight(h)
        if bar and bar.SyncRange then bar:SyncRange(h, sf:GetHeight() or 1) end
    end

    ------------------------------------------------------------------
    -- Miniatures: small inert drawings of what a feature puts on screen,
    -- in Readycheck's own colours. Dim(canvas, on) fades one when off.
    ------------------------------------------------------------------
    local Mini = {}
    local function Canvas(parent, w, h)
        local box = Box(parent, w, h, "elementBackground")
        box.marks = {}
        function box:Rect(x, y, rw, rh, cat, key, alpha)
            local t = self:CreateTexture(nil, "ARTWORK")
            t:SetTexture(FLAT)
            t:SetSize(rw, rh)
            t:SetPoint("TOPLEFT", self, "TOPLEFT", x, -y)
            local c = C(cat or "ui", key or "accentGold")
            t:SetVertexColor(c.r, c.g, c.b, alpha or 1)
            self.marks[#self.marks + 1] = t
            return t
        end
        function box:Text(text, x, y, size, cat, key)
            local fs = Text(self, text, size or 9, cat or "text", key or "normal")
            fs:SetPoint("TOPLEFT", self, "TOPLEFT", x, -y)
            self.marks[#self.marks + 1] = fs
            return fs
        end
        function box:Reset()
            for _, m in ipairs(self.marks) do m:Hide() m:ClearAllPoints() end
            self.marks = {}
        end
        return box
    end
    Wizard.Canvas = Canvas
    local function Dim(canvas, on) canvas:SetAlpha(on and 1 or 0.35) end

    local function Icons(c, n, glowAt)
        for i = 0, n - 1 do
            local x = 10 + i * 24
            if glowAt == i + 1 then c:Rect(x - 3, 15, 26, 26, "ui", "readyGlow", 0.35) end
            c:Rect(x, 18, 20, 20, "ui", "elementBackground")
            c:Rect(x, 18, 20, 20, "ui", "borderNormal", 0.9)
            c:Rect(x + 2, 20, 16, 16, "text", "gold", 0.25 + (i % 3) * 0.15)
        end
    end
    function Mini.consumables(c) Icons(c, 4, 2) c:Text("Flask  Food  Elixir", 12, 44, 9, "text", "gray") end
    function Mini.reminders(c)
        c:Rect(40, 8, 40, 40, "ui", "readyGlow", 0.3)
        c:Rect(46, 14, 28, 28, "ui", "elementBackground")
        c:Rect(46, 14, 28, 28, "ui", "readyBorder", 1)
        c:Rect(49, 17, 22, 22, "text", "red", 0.6)
        c:Text("Death Wish", 32, 46, 9, "text", "gold")
    end
    function Mini.trackers(c)
        local rows = { "Fortitude  28m", "Motw  12m", "Sunder x5  21s" }
        for i = 1, 3 do
            c:Rect(8, 6 + (i - 1) * 17, 104, 13, "ui", "cardBackground")
            c:Rect(8, 6 + (i - 1) * 17, 104 - (i - 1) * 35, 13, "ui", "accentGreen", 0.55)
            c:Text(rows[i], 11, 7 + (i - 1) * 17, 9)
        end
    end
    function Mini.gear(c)
        for i = 0, 2 do
            c:Rect(14 + i * 32, 16, 28, 28, "ui", "elementBackground")
            c:Rect(14 + i * 32, 16, 28, 28, "ui", (i == 0) and "borderSelected" or "borderNormal", 1)
            c:Rect(18 + i * 32, 20, 20, 20, "text", "blue", 0.3 + i * 0.15)
        end
    end
    function Mini.raids(c)
        c:Rect(8, 12, 104, 12, "ui", "cardBackground")
        c:Rect(8, 12, 72, 12, "text", "red", 0.7)
        c:Text("Patchwerk  2:14", 12, 12, 9)
        c:Rect(8, 34, 104, 12, "ui", "cardBackground")
        c:Rect(8, 34, 40, 12, "text", "yellow", 0.7)
        c:Text("Hateful  3", 12, 34, 9)
    end
    function Mini.extras(c)
        c:Rect(8, 14, 104, 10, "ui", "cardBackground")
        c:Rect(8, 14, 60, 10, "text", "green", 0.8)
        c:Text("TTK 0:42", 12, 13, 9)
        c:Rect(8, 32, 104, 1, "ui", "accentGold", 0.6)
        c:Text("Hit 9%  Crit 31%  AP 1680", 10, 38, 9, "text", "gray")
    end
    function Mini.character(c)
        c:Rect(10, 10, 40, 40, "ui", "elementBackground")
        c:Rect(10, 10, 40, 40, "ui", "borderNormal", 1)
        c:Rect(14, 14, 32, 32, "text", "orange", 0.5)
        c:Text("Fury", 58, 14, 11, "ui", "headerText")
        c:Text("Melee DPS", 58, 32, 9, "text", "gray")
    end
    function Mini.profile(c)
        for i = 0, 3 do
            c:Rect(10, 8 + i * 12, 100, 9, "ui", "cardBackground")
            c:Rect(12, 10 + i * 12, 40 + (i % 2) * 24, 5, "ui", "borderHover", 0.6)
        end
    end
    local function DrawMini(canvas, kind)
        canvas:Reset()
        local fn = Mini[kind] or Mini.extras
        fn(canvas)
    end
    Wizard.DrawMini = DrawMini

    ------------------------------------------------------------------
    -- The feature groups: the switches the old wizard set, grouped
    ------------------------------------------------------------------
    local function Flag(tbl, key)
        return function() local t = RC.db[tbl] return type(t) == "table" and t[key] and true or false end,
            function(on)
                if type(RC.db[tbl]) ~= "table" then RC.db[tbl] = {} end
                RC.db[tbl][key] = on and true or false
            end
    end

    local function FeatureGroups()
        local groups = {}
        local function Group(id, title, mini, addon, desc, items)
            groups[#groups + 1] = { id = id, title = title, mini = mini, addon = addon, desc = desc, items = items }
        end
        local cHelperGet, cHelperSet = Flag("consumablesHelper", "enabled")
        local potGet, potSet = Flag("potionsBar", "enabled")
        local weapGet, weapSet = Flag("weaponsBar", "enabled")
        Group("consumables", RCL["Consumables"], "consumables", "Readycheck_Consumables",
            RCL["Icons for every tracked buff that glow when one is missing or about to run out: flask and food, potions, weapon stones."], {
            { label = RCL["Consumables bar"], get = cHelperGet, set = cHelperSet },
            { label = RCL["Potions bar"], get = potGet, set = potSet },
            { label = RCL["Weapon enchant bar"], get = weapGet, set = weapSet },
        })
        local remItems = {}
        if RC.isWarrior then
            remItems[#remItems + 1] = { label = RCL["Ability reminders"],
                get = function() return RC.db.enabled and true or false end,
                set = function(on) RC.db.enabled = on and true or false end }
            local bsGet, bsSet = Flag("battleShoutReminder", "enabled")
            remItems[#remItems + 1] = { label = RCL["Battle Shout reminder"], get = bsGet, set = bsSet }
        else
            remItems[#remItems + 1] = { label = RCL["Reminders and alerts (master switch)"],
                get = function() return RC.db.enabled and true or false end,
                set = function(on) RC.db.enabled = on and true or false end }
        end
        local boonGet, boonSet = Flag("boonReminder", "enabled")
        remItems[#remItems + 1] = { label = RCL["Chronoboon reminder"], get = boonGet, set = boonSet }
        remItems[#remItems + 1] = { label = RCL["Sound alerts"],
            get = function() return RC.db.soundEnabled and true or false end,
            set = function(on) RC.db.soundEnabled = on and true or false end }
        remItems[#remItems + 1] = { label = RCL["Voice alerts (TTS)"],
            get = function() return RC.db.ttsEnabled and true or false end,
            set = function(on) RC.db.ttsEnabled = on and true or false end }
        Group("reminders", RCL["Reminders"], "reminders", "Readycheck_Reminders",
            RCL["Animated icons when a key ability is ready, Battle Shout and Chronoboon reminders, with sound and a spoken voice."], remItems)
        local rbGet, rbSet = Flag("raidBuffTracker", "enabled")
        local bdGet, bdSet = Flag("bossDebuffTracker", "enabled")
        Group("trackers", RCL["Trackers"], "trackers", "Readycheck_Reminders",
            RCL["Two small lists with time left: the raid buffs on you, and the debuffs on the boss. Both can warn before something drops."], {
            { label = RCL["Raid buff tracker"], get = rbGet, set = function(on) rbSet(on) if RC.RefreshRaidBuffTracker then RC:RefreshRaidBuffTracker() end end },
            { label = RCL["Boss debuff tracker"], get = bdGet, set = function(on) bdSet(on) if RC.RefreshBossDebuffTracker then RC:RefreshBossDebuffTracker() end end },
        })
        local gmGet, gmSet = Flag("gearManager", "enabled")
        local tsGet, tsSet = Flag("trinketSwap", "enabled")
        Group("gear", RCL["Gear"], "gear", "Readycheck_Gear",
            RCL["Named gear sets on screen buttons, and on-use trinkets rotated for you in combat."], {
            { label = RCL["Gear manager"], get = gmGet, set = function(on)
                gmSet(on)
                if RC.GearManager then
                    if on and RC.GearManager.Enable then RC.GearManager:Enable()
                    elseif not on and RC.GearManager.Disable then RC.GearManager:Disable() end
                end
            end },
            { label = RCL["Trinket auto-swap"], get = tsGet, set = tsSet },
        })
        local bnGet, bnSet = Flag("bossNotes", "enabled")
        local ttkGet, ttkSet = Flag("ttkDisplay", "enabled")
        Group("raids", RCL["Raids"], "raids", nil,
            RCL["A page per boss with gear swaps, trinkets and notes, kill timers, and your own boss notes shown when you target the boss."], {
            { label = RCL["Boss notes overlay"], addon = "Readycheck_Features", get = bnGet, set = function(on) bnSet(on) if RC.UpdateBossNotes then RC:UpdateBossNotes() end end },
            { label = RCL["Time-to-kill display"], addon = "Readycheck_Reminders", get = ttkGet, set = ttkSet },
        })
        local npGet, npSet = Flag("nameplateAuras", "enabled")
        Group("extras", RCL["Extras"], "extras", nil,
            RCL["The character stats bar, debuff timers on nameplates, smart macros and the other small tools."], {
            { label = RCL["Debuffs on nameplates"], addon = "Readycheck_Features", get = npGet, set = npSet },
            { label = RCL["Stats bar button"], get = function() return RC.db.showStatsButton and true or false end,
              set = function(on) RC.db.showStatsButton = on and true or false if RC.UpdateStatsButton then RC:UpdateStatsButton() end end },
        })
        return groups
    end
    Wizard.FeatureGroups = FeatureGroups

    ------------------------------------------------------------------
    -- 1. WELCOME
    ------------------------------------------------------------------
    local function PageWelcome(host)
        local y = Title(host, RCL["Welcome to Readycheck"],
            RCL["A few short steps set up the basics. Nothing changes until you choose it, every step can be skipped, and everything here can be changed again later with /rc."])
        local x = PAD
        Label(host, RCL["What is about to happen"], x, y)
        y = y - 18
        for _, st in ipairs(steps) do
            if st.id ~= "welcome" and st.id ~= "done" then
                local dash = Text(host, "-", 11, "text", "gray")
                dash:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
                local fs = Text(host, st.title .. " - " .. st.blurb, 11)
                fs:SetPoint("TOPLEFT", host, "TOPLEFT", x + 12, y)
                fs:SetWidth(PAGE_W - 2 * PAD - 14)
                fs:SetJustifyH("LEFT")
                fs:SetWordWrap(true)
                y = y - math.max(13, fs:GetStringHeight() or 12) - 5
            end
        end
        y = y - 12
        local _, dh = Desc(host, RCL["In a hurry? Skip everything keeps the defaults and closes this. The tour shows you around the settings window instead."], x, y, PAGE_W - 2 * PAD)
        y = y - dh - 10
        local skip = Button(host, RCL["Skip everything, use the defaults"], 230)
        skip:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
        skip:SetScript("OnClick", function()
            DB().completed = true
            Save()
            Wizard:Close()
            RC:Print(RCL["Setup skipped - the defaults are on. |cffffd700/rc|r opens the settings; |cffffd700/rc setup|r brings this back."])
        end)
        Tip(skip, RCL["Skip everything"], RCL["Closes the setup. Readycheck keeps every default; /rc setup brings this back any time."])
        local tour = Button(host, RCL["Take the tour instead"], 150)
        tour:SetPoint("LEFT", skip, "RIGHT", 8, 0)
        tour:SetScript("OnClick", function()
            Wizard:Close()
            Wizard:FinishIntoSettings()
        end)
        host.skipButton, host.tourButton = skip, tour
    end

    ------------------------------------------------------------------
    -- 2. GAME VERSION
    ------------------------------------------------------------------
    local function PageVersion(host)
        local flavor = RC.Flavor and RC:Flavor() or "era"
        local name = RC.FlavorName and RC:FlavorName(flavor) or flavor
        local y = Title(host, RCL["This game: "] .. name,
            RCL["Readycheck runs on Classic Era, TBC and WoW Forever and switches off what a client does not have. Nothing to set here - this is what "] .. name .. RCL[" gets."])
        local x, bx = PAD, PAD
        host.badges = {}
        for _, f in ipairs(RC.FLAVORS or { "era", "tbc", "forever" }) do
            local b = Button(host, RC.FlavorName and RC:FlavorName(f) or f, 100)
            b:SetPoint("TOPLEFT", host, "TOPLEFT", bx, y)
            b:SetActive(f == flavor)
            b:SetScript("OnClick", nil)
            host.badges[f] = b
            bx = bx + 106
        end
        y = y - 24 - 10
        if RC.IsSimulatedFlavor and RC:IsSimulatedFlavor() then
            local _, dh = Desc(host, RCL["(Running as this version by the developer override.)"], x, y, PAGE_W - 2 * PAD)
            y = y - dh - 8
        end
        local off = RC.FeaturesOff and RC:FeaturesOff(flavor) or {}
        host.offCount = #off
        local sf, child, bar = Scroll(host, y)
        local cy = -2
        local wide = PAGE_W - 2 * PAD - 18
        if #off == 0 then
            local _, dh = Desc(child, RCL["Everything Readycheck has runs on "] .. name .. ".", x, cy, wide)
            cy = cy - dh - 6
        else
            Label(child, RCL["Off on "] .. name .. " (" .. #off .. ")", x, cy)
            cy = cy - 18
            for _, f in ipairs(off) do
                local kind = RC.FlavorKindName and RC:FlavorKindName(f.kind) or f.kind or ""
                local fs = Text(child, f.name .. (kind ~= "" and (" - " .. kind) or ""), 11)
                fs:SetPoint("TOPLEFT", child, "TOPLEFT", x, cy)
                fs:SetWidth(wide)
                fs:SetJustifyH("LEFT")
                fs:SetWordWrap(true)
                cy = cy - math.max(13, fs:GetStringHeight() or 12) - 2
                local _, dh = Desc(child, f.reason, x + 12, cy, wide - 12)
                cy = cy - dh - 8
            end
        end
        local _, dh2 = Desc(child, RCL["The full list is under /rc > Settings > Game version."], x, cy, wide)
        cy = cy - dh2 - 6
        FinishScroll(sf, child, bar, -cy + 4)
    end

    ------------------------------------------------------------------
    -- 3. CHARACTER
    ------------------------------------------------------------------
    local ROLES = {
        { id = "auto", label = RCL["As detected"] },
        { id = "tank", label = RCL["Tank"] },
        { id = "melee", label = RCL["Melee"] },
        { id = "ranged", label = RCL["Ranged"] },
        { id = "healer", label = RCL["Healer"] },
    }
    local function PageCharacter(host)
        local y = Title(host, RCL["Your character"],
            RCL["Readycheck reads your talents to know your spec. Tell it the role you play too; it is written down for the features that ask (the raid profiles, the consume reminders), and never changes a default by itself."])
        local x = PAD
        local className, class = UnitClass("player")
        local specKey = RC.DetectWarriorSpec and RC:DetectWarriorSpec() or nil
        local specData = specKey and RC.specDetection and RC.specDetection.specs and RC.specDetection.specs[specKey] or nil
        local card = Box(host, 240, 96)
        card:SetPoint("TOPRIGHT", host, "TOPRIGHT", -PAD, y)
        local icon = card:CreateTexture(nil, "ARTWORK")
        icon:SetSize(48, 48)
        icon:SetPoint("LEFT", card, "LEFT", 12, 0)
        icon:SetTexture(specData and specData.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local who = Text(card, (UnitName("player") or "") .. "  -  " .. (className or ""), 12, "ui", "headerText", "OUTLINE")
        who:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -8)
        local spec = Text(card, specData and (RCL["Spec: "] .. specData.name) or RCL["Spec: not detected yet"], 11)
        spec:SetPoint("TOPLEFT", who, "BOTTOMLEFT", 0, -6)
        local roleLine = Text(card, "", 10, "text", "gray")
        roleLine:SetPoint("TOPLEFT", spec, "BOTTOMLEFT", 0, -6)
        host.specText, host.roleText = spec, roleLine

        Label(host, RCL["Role"], x, y)
        y = y - 20
        local d = DB()
        host.roleButtons = {}
        local function Paint()
            for id, b in pairs(host.roleButtons) do b:SetActive(id == d.role) end
            local lbl
            for _, r in ipairs(ROLES) do if r.id == d.role then lbl = r.label end end
            roleLine:SetText(RCL["Role: "] .. (lbl or d.role))
        end
        local bx = x
        for _, r in ipairs(ROLES) do
            local b = Button(host, r.label, 86)
            b:SetPoint("TOPLEFT", host, "TOPLEFT", bx, y)
            b:SetScript("OnClick", function()
                d.role = r.id
                Save()
                Note("role", RCL["Role: "] .. r.label)
                Paint()
            end)
            host.roleButtons[r.id] = b
            bx = bx + 92
            if bx + 86 > PAGE_W - PAD - 250 then bx = x y = y - 30 end
        end
        Paint()
        y = y - 24 - 14
        Desc(host, RCL["Recorded only. Which reminders and bars are on is the next step; the role never switches anything on or off."], x, y, PAGE_W - 2 * PAD - 256)
    end

    ------------------------------------------------------------------
    -- 4. FEATURES
    ------------------------------------------------------------------
    local function PageFeatures(host)
        local y = Title(host, RCL["Features"],
            RCL["Each group of Readycheck's features can be on or off, with a glimpse of what it puts on screen. A feature whose companion addon is off says so."])
        local x = PAD
        local sf, child, bar = Scroll(host, y)
        local wide = PAGE_W - 18
        local cy = -2
        host.featureChecks, host.featureMinis = {}, {}
        for _, g in ipairs(FeatureGroups()) do
            local rows = 0
            for _, it in ipairs(g.items) do rows = rows + 1 end
            local cardH = math.max(84, 36 + rows * 24 + 8)
            local card = Box(child, wide - 2 * PAD, cardH)
            card:SetPoint("TOPLEFT", child, "TOPLEFT", x, cy)
            local mini = Canvas(card, 120, 60)
            mini:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -12)
            DrawMini(mini, g.mini)
            host.featureMinis[g.id] = mini
            local head = Text(card, g.title, 12, "ui", "headerText", "OUTLINE")
            head:SetPoint("TOPLEFT", card, "TOPLEFT", 140, -10)
            local desc = Text(card, g.desc, 10, "text", "gray")
            desc:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -3)
            desc:SetPoint("RIGHT", card, "RIGHT", -10, 0)
            desc:SetJustifyH("LEFT")
            desc:SetWordWrap(true)
            local iy = -(10 + 14 + 3 + math.max(12, desc:GetStringHeight() or 12) + 6)
            local anyOn = false
            for _, it in ipairs(g.items) do
                local addon = it.addon or g.addon
                local okG, v = pcall(it.get)
                v = okG and v and true or false
                if v then anyOn = true end
                if AddonOn(addon) then
                    local cb = RC.UI:CreateCheckbox(card, it.label, v)
                    cb:ClearAllPoints()
                    cb:SetPoint("TOPLEFT", card, "TOPLEFT", 140, iy)
                    cb:SetScript("OnClick", function(self)
                        local on = self:GetChecked() and true or false
                        local ok, err = pcall(it.set, on)
                        if not ok then RC:DebugPrint("setup: " .. it.label .. ": " .. tostring(err), "wizard") end
                        Save()
                        Note("feat:" .. g.id .. ":" .. it.label, it.label .. (on and RCL[" on"] or RCL[" off"]))
                        RC:DebugPrint("SetupWizard2: " .. it.label .. "=" .. tostring(on), "wizard")
                        local lit = false
                        for _, o in ipairs(g.items) do local okO, vv = pcall(o.get) if okO and vv then lit = true end end
                        Dim(mini, lit)
                    end)
                    host.featureChecks[g.id .. ":" .. it.label] = cb
                else
                    local need = Text(card, it.label .. RCL[" - needs the "] .. tostring(addon) .. RCL[" addon (enable it in your AddOns list and /reload)"], 10, "text", "red")
                    need:SetPoint("TOPLEFT", card, "TOPLEFT", 140, iy - 2)
                    need:SetPoint("RIGHT", card, "RIGHT", -10, 0)
                    need:SetJustifyH("LEFT")
                end
                iy = iy - 24
            end
            Dim(mini, anyOn)
            local want = -iy + 8
            if want > cardH then card:SetHeight(want) cardH = want end
            cy = cy - cardH - 8
        end
        FinishScroll(sf, child, bar, -cy + 4)
    end

    ------------------------------------------------------------------
    -- 5. CONSUME REMINDERS
    ------------------------------------------------------------------
    local function PageConsume(host)
        local y = Title(host, RCL["Raid consume reminders"],
            RCL["In a raid, the consumables you have ticked but are not wearing show in the reminders bar. Try the alert sound and the voice here."])
        local x = PAD
        local d = RC.db.consumeRemind
        if type(d) ~= "table" then d = { enabled = true, onlyInBags = true } RC.db.consumeRemind = d end
        local mini = Canvas(host, 240, 70)
        mini:SetPoint("TOPRIGHT", host, "TOPRIGHT", -PAD, y)
        local function Draw()
            mini:Reset()
            Icons(mini, 5, d.enabled and 3 or nil)
            mini:Text(d.enabled and RCL["Missing: Elixir of the Mongoose"] or RCL["Reminders off"], 12, 48, 9, "text", d.enabled and "red" or "gray")
        end
        Draw()
        host.consumeMini = mini
        local cb1 = RC.UI:CreateCheckbox(host, RCL["Show missing consumables in raids"], d.enabled == true)
        cb1:ClearAllPoints()
        cb1:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
        cb1:SetScript("OnClick", function(self)
            d.enabled = self:GetChecked() and true or false
            Save()
            Note("consume", RCL["Raid consume reminders: "] .. (d.enabled and RCL["on"] or RCL["off"]))
            Draw()
        end)
        host.consumeOn = cb1
        y = y - 26
        local cb2 = RC.UI:CreateCheckbox(host, RCL["Only what is in my bags"], d.onlyInBags ~= false)
        cb2:ClearAllPoints()
        cb2:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
        cb2:SetScript("OnClick", function(self)
            d.onlyInBags = self:GetChecked() and true or false
            Save()
            Note("consumeBags", RCL["Only what is in my bags: "] .. (d.onlyInBags and RCL["on"] or RCL["off"]))
        end)
        host.consumeBags = cb2
        y = y - 26 - 10
        Label(host, RCL["Alerts"], x, y)
        y = y - 20
        local snd = Button(host, RCL["Test sound"], 110)
        snd:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
        snd:SetScript("OnClick", function()
            local key = RC.db.soundKey or "WR: Warning"
            if RC.PlaySoundKey then RC:PlaySoundKey(key, RC.db.soundFile) end
        end)
        Tip(snd, RCL["Test sound"], RCL["Plays the reminder sound you have picked (Reminder Settings > Sound)."])
        local voice = Button(host, RCL["Test voice"], 110)
        voice:SetPoint("LEFT", snd, "RIGHT", 8, 0)
        voice:SetScript("OnClick", function()
            if RC.SpeakTTSPreview then RC:SpeakTTSPreview(RCL["Elixir of the Mongoose missing"]) end
        end)
        Tip(voice, RCL["Test voice"], RCL["Speaks a sample line with the voice Readycheck uses for its alerts."])
        host.soundButton, host.voiceButton = snd, voice
        y = y - 24 - 12
        Desc(host, RCL["Which consumables count, per class and game version, is under /rc > Consumables > Raid consume reminders."], x, y, PAGE_W - 2 * PAD - 256)
    end

    ------------------------------------------------------------------
    -- 6. RAID PROFILES
    ------------------------------------------------------------------
    local function RaidsWithProfiles()
        local out = {}
        local rp = RC.db and RC.db.raidProfiles
        if type(rp) ~= "table" then return out end
        for raidName, st in pairs(rp) do
            if type(st) == "table" and type(st.profiles) == "table" then
                local names = {}
                for n in pairs(st.profiles) do names[#names + 1] = n end
                table.sort(names)
                if #names > 1 then out[#out + 1] = { raid = raidName, names = names, active = st.activeProfile or "Default" } end
            end
        end
        table.sort(out, function(a, b) return a.raid < b.raid end)
        return out
    end
    local function Presets()
        local list = {}
        for raidName, profiles in pairs(RC.builtInProfiles or {}) do
            if type(profiles) == "table" and #profiles > 0 then list[#list + 1] = { name = raidName, profiles = profiles } end
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        return list
    end
    local function RaidStepAvailable()
        return #RaidsWithProfiles() > 0 or (#Presets() > 0 and RC.ImportRaidProfile ~= nil)
    end

    local function PageRaids(host)
        local y = Title(host, RCL["Raid profiles"],
            RCL["Each raid can have more than one profile - Farm, Progression, per spec. Pick which one is active, or import one of the ready-made presets."])
        local x = PAD
        local sf, child, bar = Scroll(host, y)
        local wide = PAGE_W - 18 - 2 * PAD
        local cy = -2
        host.raidDropdowns = {}
        local raids = RaidsWithProfiles()
        if #raids > 0 then
            Label(child, RCL["Active profile per raid"], x, cy)
            cy = cy - 20
            for _, r in ipairs(raids) do
                local name = Text(child, r.raid, 11)
                name:SetPoint("TOPLEFT", child, "TOPLEFT", x, cy - 5)
                name:SetWidth(150)
                name:SetJustifyH("LEFT")
                local dd = RC.UI:CreateScrollableDropdown(child, 220, r.active, 6)
                dd:SetPoint("TOPLEFT", child, "TOPLEFT", x + 156, cy)
                local items = {}
                for _, n in ipairs(r.names) do items[#items + 1] = { text = n, value = n } end
                dd:SetItems(items, function(value)
                    if RC.SetActiveRaidProfile then RC:SetActiveRaidProfile(r.raid, value, true) end
                    Note("raid:" .. r.raid, r.raid .. RCL[": active profile "] .. value)
                end)
                dd:SetSelectedValue(r.active, r.active)
                host.raidDropdowns[r.raid] = dd
                cy = cy - 30
            end
            cy = cy - 8
        end
        local presets = Presets()
        if #presets > 0 and RC.ImportRaidProfile then
            Label(child, RCL["Import a ready-made preset"], x, cy)
            cy = cy - 20
            host.presetButtons = {}
            for _, raidEntry in ipairs(presets) do
                for _, profile in ipairs(raidEntry.profiles) do
                    local b = Button(child, raidEntry.name .. "  -  " .. profile.name, wide)
                    b:SetPoint("TOPLEFT", child, "TOPLEFT", x, cy)
                    local pData, pName, rName = profile.data, profile.name, raidEntry.name
                    b:SetScript("OnClick", function()
                        if RC.remoteEditMode and RC.ExitRemoteEditMode then RC:ExitRemoteEditMode() end
                        local ok = RC:ImportRaidProfile(pData, pName)
                        if ok then
                            b:SetActive(true)
                            RC.UI:SetButtonText(b, "|cff66ff66" .. rName .. RCL[" - Imported!|r"])
                            Note("preset:" .. rName .. ":" .. pName, RCL["Imported preset: "] .. rName .. " - " .. pName)
                        end
                    end)
                    if profile.description then Tip(b, pName, profile.description) end
                    host.presetButtons[#host.presetButtons + 1] = b
                    cy = cy - 30
                end
            end
        end
        local _, dh = Desc(child, RCL["Bosses, gear swaps and notes per profile are under /rc > Raids. When you enter a raid with more than one profile, a picker asks which to load."], x, cy, wide)
        cy = cy - dh - 6
        FinishScroll(sf, child, bar, -cy + 4)
    end

    ------------------------------------------------------------------
    -- 7. LAYOUT (SetupLayouts draws it when it is there)
    ------------------------------------------------------------------
    local function LayoutReady()
        local LP = RC.SetupLayouts
        return type(LP) == "table" and type(LP.BuildStep) == "function" and LP.Available and LP.Available()
    end
    local function PageLayout(host)
        local y = Title(host, RCL["Layout"],
            RCL["A named arrangement of Readycheck's bars and reminders for this screen. Preview it on screen first; nothing moves until you apply it."])
        RC.SetupLayouts.BuildStep(host, y, { note = Note, needsReload = NeedsReload, pageW = PAGE_W, pad = PAD, canvas = Canvas })
    end

    ------------------------------------------------------------------
    -- 8. PROFILE
    ------------------------------------------------------------------
    local function OtherCharacters()
        local out = {}
        local me = RC.GetCharacterKey and RC:GetCharacterKey() or nil
        for key, prof in pairs((ReadycheckDB and ReadycheckDB.characters) or {}) do
            if key ~= me and type(prof) == "table" then out[#out + 1] = key end
        end
        table.sort(out)
        return out
    end

    -- Every exportable setting of another character copied onto this one
    -- (the same keys an export string carries), saved; a reload applies it.
    function Wizard:CopyFromCharacter(key)
        local src = ReadycheckDB and ReadycheckDB.characters and ReadycheckDB.characters[key]
        if type(src) ~= "table" or not RC.db then return false end
        local keys = RC.EXPORTABLE_KEYS or {}
        local n = 0
        for _, k in ipairs(keys) do
            if src[k] ~= nil then
                RC.db[k] = RC.DeepCopy and RC.DeepCopy(src[k]) or src[k]
                n = n + 1
            end
        end
        Save()
        return n > 0, n
    end

    local function PageProfile(host)
        local y = Title(host, RCL["Profile"],
            RCL["Readycheck's settings are per character. Keep going with this character's own, copy another character's, or paste a settings string."])
        local x = PAD
        local wide = PAGE_W - 2 * PAD - 256
        local card = Box(host, 240, 110)
        card:SetPoint("TOPRIGHT", host, "TOPRIGHT", -PAD, y)
        local mini = Canvas(card, 120, 60)
        mini:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -8)
        DrawMini(mini, "profile")
        local who = Text(card, RC.GetCharacterKey and RC:GetCharacterKey() or "", 10, "ui", "headerText")
        who:SetPoint("TOPLEFT", mini, "TOPRIGHT", 8, -2)
        who:SetWidth(100)
        who:SetJustifyH("LEFT")
        who:SetWordWrap(true)
        local others = OtherCharacters()
        local line = Text(card, #others .. RCL[" other character(s) on this account"], 9, "text", "gray")
        line:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -76)
        line:SetWidth(224)
        line:SetJustifyH("LEFT")

        Label(host, RCL["Keep going"], x, y)
        y = y - 16
        local _, dh = Desc(host, RCL["Nothing to do: this character keeps its own settings."], x, y, wide)
        y = y - dh - 12

        Label(host, RCL["Copy another character's settings"], x, y)
        y = y - 20
        local chosen
        local dd = RC.UI:CreateScrollableDropdown(host, 220, RCL["Pick a character"], 6)
        dd:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
        local items = {}
        for _, k in ipairs(others) do items[#items + 1] = { text = k, value = k } end
        dd:SetItems(items, function(value) chosen = value end)
        host.copyDropdown = dd
        local copy = Button(host, RCL["Copy"], 80)
        copy:SetPoint("LEFT", dd, "RIGHT", 8, 0)
        copy:SetScript("OnClick", function()
            if not chosen then RC:Print(RCL["Pick a character first."]) return end
            local ok, n = Wizard:CopyFromCharacter(chosen)
            if ok then
                Note("profile", RCL["Settings copied from "] .. chosen)
                NeedsReload("profile", RCL["The copied settings"])
                RC:Print(RCL["Copied "] .. tostring(n) .. RCL[" settings from "] .. chosen .. RCL[". A reload applies them everywhere."])
            else
                RC:Print(RCL["Nothing to copy from "] .. tostring(chosen) .. ".")
            end
        end)
        Tip(copy, RCL["Copy"], RCL["Every setting an export string carries, copied from that character onto this one. Raid profiles too. A reload applies it all."])
        host.copyButton = copy
        y = y - 24 - 14

        Label(host, RCL["Paste a settings string"], x, y)
        y = y - 20
        local box = RC.UI:CreateStyledEditBox(host, { width = wide, multiLine = true, scrollable = true, scrollHeight = 56, height = 56 })
        box:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
        host.importBox = box
        y = y - 60 - 6
        local imp = Button(host, RCL["Import"], 90)
        imp:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
        imp:SetScript("OnClick", function()
            local eb = box.editBox or box
            local text = eb.GetText and eb:GetText() or ""
            if text:match("^%s*$") then RC:Print(RCL["Paste a string first."]) return end
            if not RC.ImportAny then RC:Print(RCL["The importer did not load."]) return end
            local ok, msg = RC:ImportAny(text, {})
            if ok then
                Note("import", RCL["Imported: "] .. tostring(msg or RCL["a settings string"]))
                NeedsReload("import", RCL["The imported settings"])
                if msg then RC:Print(msg) end
            elseif msg then
                RC:Print(RCL["Import: "] .. tostring(msg))
            end
        end)
        Tip(imp, RCL["Import"], RCL["Reads the string (settings, a raid profile, boss notes, a custom reminder or a route) and applies it."])
        host.importButton = imp
    end

    ------------------------------------------------------------------
    -- 9. DONE
    ------------------------------------------------------------------
    local function PageDone(host)
        local y = Title(host, RCL["You're all set!"],
            RCL["Everything here can be changed again with /rc. Finish opens the settings window and shows you around it."])
        local x = PAD
        local lines = {}
        for _, key in ipairs(S.noteOrder) do if S.notes[key] then lines[#lines + 1] = S.notes[key] end end
        if #lines == 0 then lines[1] = RCL["Nothing was changed - Readycheck keeps its defaults."] end
        local sf, child, bar = Scroll(host, y, 8)
        local wide = PAGE_W - 18 - 2 * PAD
        local cy = -2
        Label(child, RCL["What you set"], x, cy)
        cy = cy - 18
        for _, l in ipairs(lines) do
            local dash = Text(child, "-", 11, "text", "gray")
            dash:SetPoint("TOPLEFT", child, "TOPLEFT", x, cy)
            local fs = Text(child, l, 11)
            fs:SetPoint("TOPLEFT", child, "TOPLEFT", x + 12, cy)
            fs:SetWidth(wide - 14)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(true)
            cy = cy - math.max(13, fs:GetStringHeight() or 12) - 4
        end
        cy = cy - 10
        local reload = Wizard:ReloadNeeded()
        host.reloadButton = nil
        if #reload > 0 then
            local _, dh = Desc(child, RCL["These take a reload to finish: "] .. table.concat(reload, ", ") .. ".", x, cy, wide)
            cy = cy - dh - 8
            local rb = Button(child, RCL["Reload now"], 110)
            rb:SetPoint("TOPLEFT", child, "TOPLEFT", x, cy)
            rb:SetActive(true)
            rb:SetScript("OnClick", function()
                if type(ReloadUI) == "function" then ReloadUI()
                elseif C_UI and C_UI.Reload then C_UI.Reload() end
            end)
            host.reloadButton = rb
            cy = cy - 24 - 14
        end
        Label(child, RCL["Commands"], x, cy)
        cy = cy - 16
        local _, ch = Desc(child, RCL["/rc opens the settings. /rc setup runs this again. /rc tutorial shows you around the settings window. /rc hints reset brings every one-time tip back. The UI Mover (Settings > Interface) moves any frame."], x, cy, wide)
        cy = cy - ch - 12
        Label(child, RCL["Where next"], x, cy)
        cy = cy - 20
        local open = Button(child, RCL["Open settings"], 120)
        open:SetPoint("TOPLEFT", child, "TOPLEFT", x, cy)
        open:SetScript("OnClick", function()
            Wizard:Close()
            if not (RC.sidebarConfigFrame and RC.sidebarConfigFrame:IsShown()) and RC.CreateSidebarConfigWindow then
                RC:CreateSidebarConfigWindow()
            end
        end)
        local mover = Button(child, RCL["Move the frames"], 130)
        mover:SetPoint("LEFT", open, "RIGHT", 8, 0)
        mover:SetScript("OnClick", function()
            Wizard:Close()
            local UM = RC.UIMover
            if UM and UM.EnterMoveMode then UM:EnterMoveMode() end
        end)
        host.openButton, host.moverButton = open, mover
        cy = cy - 24 - 12
        local _, dh3 = Desc(child, RCL["Questions or feedback? Find me on Discord: |cffffd700zac12|r"], x, cy, wide)
        cy = cy - dh3 - 6
        FinishScroll(sf, child, bar, -cy + 4)
    end

    ------------------------------------------------------------------
    -- The steps
    ------------------------------------------------------------------
    local ALL_STEPS = {
        { id = "welcome", title = RCL["Welcome"], blurb = RCL["what this does"], build = PageWelcome },
        { id = "version", title = RCL["Game version"], blurb = RCL["what this client runs and what is off here"], build = PageVersion,
          available = function() return RC.Flavor ~= nil end },
        { id = "character", title = RCL["Character"], blurb = RCL["your spec, and the role you play"], build = PageCharacter },
        { id = "features", title = RCL["Features"], blurb = RCL["which groups of features are on"], build = PageFeatures },
        { id = "consume", title = RCL["Consume reminders"], blurb = RCL["missing consumables in raids, the alert sounds"], build = PageConsume,
          available = function() return AddonOn("Readycheck_Consumables") end },
        { id = "raids", title = RCL["Raid profiles"], blurb = RCL["the active profile per raid, the presets"], build = PageRaids,
          available = RaidStepAvailable },
        { id = "layout", title = RCL["Layout"], blurb = RCL["a named arrangement of the frames"], build = PageLayout, available = LayoutReady },
        { id = "profile", title = RCL["Profile"], blurb = RCL["keep going, copy a character, or paste a string"], build = PageProfile },
        { id = "done", title = RCL["All set"], blurb = "", build = PageDone },
    }

    local function BuildSteps()
        local out = {}
        for _, st in ipairs(ALL_STEPS) do
            local ok, avail = pcall(function() return (not st.available) or st.available() end)
            if ok and avail then out[#out + 1] = st end
        end
        return out
    end

    ------------------------------------------------------------------
    -- Paging
    ------------------------------------------------------------------
    local function PaintRail()
        local d = DB()
        for i, row in ipairs(rail.rows) do
            local st = steps[i]
            if not st then break end
            local c
            if i == index then c = C("ui", "headerText") row.mark:Show()
            elseif d.visited[st.id] then c = C("text", "normal") row.mark:Hide()
            else c = C("text", "gray") row.mark:Hide() end
            row.title:SetTextColor(c.r, c.g, c.b, 1)
            row.num:SetText(d.visited[st.id] and i < index and "+" or tostring(i))
        end
    end

    function Wizard:ShowStep(i)
        if not frame then return end
        index = math.max(1, math.min(#steps, i))
        self.currentStep = index
        -- (RC.db IS the saved profile table, so lastStep persists without a
        -- save; a save here would let other systems write on a plain view)
        local d = DB()
        d.visited[steps[index].id] = true
        d.lastStep = index
        Clear(pagesHost)
        local host = CreateFrame("Frame", nil, pagesHost)
        host:SetAllPoints(pagesHost)
        local ok, err = pcall(steps[index].build, host)
        if not ok then RC:DebugPrint("SetupWizard2: " .. steps[index].id .. ": " .. tostring(err), "wizard") end
        frame.page, frame.pageId = host, steps[index].id
        frame.titleText:SetText(RCL["Setup  -  "] .. (steps[index].title or ""))
        frame.stepCountText:SetText(RCL["Step "] .. index .. RCL[" of "] .. #steps)
        frame.prevBtn:SetShown(index > 1)
        frame.skipBtn:SetShown(index > 1 and index < #steps)
        RC.UI:SetButtonText(frame.nextBtn, index == #steps and RCL["Finish & tour"] or RCL["Next >"])
        frame.nextBtn:SetActive(index == #steps)
        PaintRail()
    end

    function Wizard:GoToNext()
        if index < #steps then
            self:ShowStep(index + 1)
        else
            DB().completed = true
            Save()
            self:Close()
            self:FinishIntoSettings()
        end
    end
    function Wizard:GoToPrev() if index > 1 then self:ShowStep(index - 1) end end
    function Wizard:SkipStep() if index < #steps then self:ShowStep(index + 1) end end

    -- The second half of the first run: the settings window opens and the
    -- tour starts in it.
    function Wizard:FinishIntoSettings()
        if not (RC.sidebarConfigFrame and RC.sidebarConfigFrame:IsShown()) and RC.CreateSidebarConfigWindow then
            RC:CreateSidebarConfigWindow()
        end
        C_Timer.After(0.5, function()
            if RC.Tutorial and not RC.Tutorial.active then RC.Tutorial:Start("wizard") end
        end)
    end

    local function FillRail()
        for _, row in ipairs(rail.rows) do row:Hide() end
        for i, st in ipairs(steps) do
            local row = rail.rows[i]
            if not row then
                row = CreateFrame("Button", nil, rail)
                row:SetHeight(28)
                row:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -8 - (i - 1) * 28)
                row:SetPoint("RIGHT", rail, "RIGHT", -1, 0)
                row.bg = row:CreateTexture(nil, "BACKGROUND")
                row.bg:SetAllPoints()
                row.bg:SetTexture(FLAT)
                local sbg = C("sidebar", "background")
                row.bg:SetVertexColor(sbg.r, sbg.g, sbg.b, sbg.a or 1)
                row.mark = row:CreateTexture(nil, "ARTWORK")
                row.mark:SetTexture(FLAT)
                row.mark:SetWidth(3)
                row.mark:SetPoint("TOPLEFT")
                row.mark:SetPoint("BOTTOMLEFT")
                local a = C("ui", "accentGold")
                row.mark:SetVertexColor(a.r, a.g, a.b, 1)
                row.num = Text(row, "", 10, "text", "gray")
                row.num:SetPoint("LEFT", row, "LEFT", 8, 0)
                row.num:SetWidth(16)
                row.num:SetJustifyH("RIGHT")
                row.title = Text(row, "", 12, "text", "gray")
                row.title:SetPoint("LEFT", row.num, "RIGHT", 8, 0)
                RC.UI:AttachHover(row, C("sidebar", "background"), C("sidebar", "buttonHover"))
                rail.rows[i] = row
            end
            row.title:SetText(st.title)
            row:SetScript("OnClick", function() Wizard:ShowStep(i) end)
            row:Show()
        end
    end

    ------------------------------------------------------------------
    -- The window
    ------------------------------------------------------------------
    local function Build()
        local f = CreateFrame("Frame", "WRSetupWizardFrame", UIParent)
        f:SetSize(W, H)
        f:SetPoint("CENTER", 0, 20)
        f:SetMovable(true)
        f:EnableMouse(true)
        f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetFrameStrata("DIALOG")
        f:SetFrameLevel(100)
        f:SetToplevel(true)
        f:SetClampedToScreen(true)
        f:SetScript("OnMouseDown", function(self) self:Raise() end)
        RC.UI:RegisterEscapeClose("WRSetupWizardFrame")
        f:Hide()

        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints()
        f.bg:SetTexture(FLAT)
        local winBg = C("ui", "windowBackground")
        f.bg:SetVertexColor(winBg.r, winBg.g, winBg.b, winBg.a or 0.95)
        RC.UI:CreateSimpleBorder(f)

        local header = CreateFrame("Frame", nil, f)
        header:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        header:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
        header:SetHeight(HEADER_H)
        header.bg = header:CreateTexture(nil, "BACKGROUND")
        header.bg:SetAllPoints()
        header.bg:SetTexture(FLAT)
        local hdrBg = C("ui", "headerBackground")
        header.bg:SetVertexColor(hdrBg.r, hdrBg.g, hdrBg.b, hdrBg.a or 1)
        if RC.UI.ApplyHeaderArt then RC.UI:ApplyHeaderArt(header, { stepX = 160 }) end
        local titleIcon = RC.UI:AddTitleIcon(header, 16, 8)
        local titleText = Text(header, RCL["Setup"], 15, "ui", "headerText", "OUTLINE")
        titleText:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        f.titleText = titleText
        local closeBtn = RC.UI:CreateXCloseButton(header, 22, function() Wizard:Close() end)
        closeBtn:SetPoint("RIGHT", header, "RIGHT", -5, 0)

        rail = CreateFrame("Frame", nil, f)
        rail:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
        rail:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, NAV_H)
        rail:SetWidth(RAIL_W)
        rail.bg = rail:CreateTexture(nil, "BACKGROUND")
        rail.bg:SetAllPoints()
        rail.bg:SetTexture(FLAT)
        local sb = C("sidebar", "background")
        rail.bg:SetVertexColor(sb.r, sb.g, sb.b, sb.a or 1)
        local edge = rail:CreateTexture(nil, "ARTWORK")
        edge:SetTexture(FLAT)
        edge:SetWidth(1)
        edge:SetPoint("TOPRIGHT")
        edge:SetPoint("BOTTOMRIGHT")
        local bord = C("ui", "borderNormal")
        edge:SetVertexColor(bord.r, bord.g, bord.b, bord.a or 1)
        rail.rows = {}

        pagesHost = CreateFrame("Frame", nil, f)
        pagesHost:SetPoint("TOPLEFT", rail, "TOPRIGHT", 0, 0)
        pagesHost:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, NAV_H)
        pagesHost:SetSize(PAGE_W, H - HEADER_H - NAV_H - 2)

        local nav = CreateFrame("Frame", nil, f)
        nav:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 1, 1)
        nav:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
        nav:SetHeight(NAV_H - 1)
        nav.bg = nav:CreateTexture(nil, "BACKGROUND")
        nav.bg:SetAllPoints()
        nav.bg:SetTexture(FLAT)
        nav.bg:SetVertexColor(hdrBg.r, hdrBg.g, hdrBg.b, 0.8)
        local navDiv = nav:CreateTexture(nil, "ARTWORK")
        navDiv:SetPoint("TOPLEFT", nav, "TOPLEFT")
        navDiv:SetPoint("TOPRIGHT", nav, "TOPRIGHT")
        navDiv:SetHeight(1)
        navDiv:SetTexture(FLAT)
        navDiv:SetVertexColor(bord.r, bord.g, bord.b, bord.a or 1)
        f.nav = nav

        local prevBtn = Button(nav, RCL["< Previous"], 100, 26)
        prevBtn:SetPoint("LEFT", nav, "LEFT", 14, 0)
        prevBtn:SetScript("OnClick", function() Wizard:GoToPrev() end)
        f.prevBtn = prevBtn
        local skipBtn = Button(nav, RCL["Skip this step"], 110, 26)
        skipBtn:SetPoint("LEFT", prevBtn, "RIGHT", 8, 0)
        skipBtn:SetScript("OnClick", function() Wizard:SkipStep() end)
        Tip(skipBtn, RCL["Skip this step"], RCL["Leaves this step as it is and moves on."])
        f.skipBtn = skipBtn
        local stepCount = Text(nav, "", 11, "text", "gray")
        stepCount:SetPoint("CENTER", nav, "CENTER", 60, 0)
        f.stepCountText = stepCount
        local nextBtn = Button(nav, RCL["Next >"], 110, 26)
        nextBtn:SetPoint("RIGHT", nav, "RIGHT", -14, 0)
        nextBtn:SetScript("OnClick", function() Wizard:GoToNext() end)
        f.nextBtn = nextBtn

        frame = f
        Wizard.frame = f
        return f
    end

    ------------------------------------------------------------------
    -- Open / close, combat
    ------------------------------------------------------------------
    -- the combat watch is made on first use (an open, or an open refused in
    -- combat): a closed wizard has no frame and no event at all
    local watch, OnWatch
    local function Watch()
        if not watch then
            watch = CreateFrame("Frame")
            watch:SetScript("OnEvent", OnWatch)
        end
        return watch
    end
    local pendingReopen = false

    function Wizard:Open()
        if not RC.db then return false end
        if InCombat() then
            RC:Print(RCL["The setup opens after combat."])
            pendingReopen = true
            Watch():RegisterEvent("PLAYER_REGEN_ENABLED")
            return false
        end
        if not frame then Build() end
        if frame:IsShown() then frame:Raise() return true end
        local d = DB()
        d.version = Wizard.VERSION
        S = { notes = {}, noteOrder = {}, reloadExtra = {} }
        steps = BuildSteps()
        FillRail()
        -- resume where it was left (Core_Scan resets a finished one to 1)
        local start = self.currentStep or tonumber(d.lastStep) or 1
        if start > #steps or start < 1 then start = 1 end
        self:ShowStep(start)
        Watch():RegisterEvent("PLAYER_REGEN_DISABLED")
        frame:Show()
        frame:Raise()
        return true
    end

    function Wizard:Close()
        if watch then watch:UnregisterEvent("PLAYER_REGEN_DISABLED") end
        if frame and frame:IsShown() then frame:Hide() end
    end

    function Wizard:IsShown() return frame ~= nil and frame:IsShown() end

    OnWatch = function(self, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if frame and frame:IsShown() then
                frame:Hide()
                pendingReopen = true
                self:RegisterEvent("PLAYER_REGEN_ENABLED")
            end
        elseif event == "PLAYER_REGEN_ENABLED" then
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
            if pendingReopen then
                pendingReopen = false
                C_Timer.After(1, function()
                    if InCombat() then return end
                    if frame and S then
                        frame:Show()
                        frame:Raise()
                        self:RegisterEvent("PLAYER_REGEN_DISABLED")
                    else
                        Wizard:Open()
                    end
                end)
            end
        end
    end

    -- for the tests
    function Wizard:Page() return frame and frame.page, frame and frame.pageId end
    function Wizard:Go(i) if frame and steps then self:ShowStep(i) end end
    function Wizard:PageIds()
        local out = {}
        for _, p in ipairs(steps or {}) do out[#out + 1] = p.id end
        return out
    end
    function Wizard:Index() return index end
end

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
if IsLoggedIn() then
    initFrame:UnregisterEvent("PLAYER_LOGIN")
    InitializeSetupWizard2()
else
    initFrame:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_LOGIN" then
            self:UnregisterEvent("PLAYER_LOGIN")
            C_Timer.After(0.5, InitializeSetupWizard2)
        end
    end)
end
