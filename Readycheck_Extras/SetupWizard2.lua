------------------------------------------------------------------------
-- Readycheck_Extras - The setup
-- Builds RC.SetupWizard: one window in the 5.0 popup shell (UIF_Dialogs
-- RC.UI:CreatePopupShell) with a step bar under the title, Back / Next,
-- Skip setup, and one Finish. Core_Scan lazy-loads this addon and opens it
-- on a fresh install, after /rc resetprofile, and on /rc setup.
--
--   1. You        class and detected spec, the game version in one line,
--                 the role you play (recorded), copy another character
--   2. Tracking   the feature groups on / off with a miniature each; the
--                 raid consume reminders and the alert tests live here
--   3. Layout     a named arrangement of the frames, chosen as a tile and
--                 applied on Finish (SetupLayouts)
--   4. Extras     raid profile presets, the active profile per raid, a
--                 settings string (left out when there is nothing to offer)
--   5. Finish     what Finish does, the tour as a tick, then one chat line
--
-- EVERYTHING IS OPTIONAL: Next on a step left alone changes nothing. A
-- switch writes the same key the settings pages write and saves at once;
-- only the layout waits for Finish (it moves frames). Closing keeps what
-- was chosen and the step it was on.
--
-- BOOKKEEPING: RC.db.setupWizard = { version = 3, completed, lastStep,
-- visited = {}, role = "auto" | "tank" | "melee" | "ranged" | "healer",
-- layout = the layout picked and not yet applied, tour = the Finish tick }
-- (per character, never exported or synced - PM_Registry). The role is
-- recorded only; nothing changes its defaults by it.
--
-- Combat: the wizard registers no events of its own but the two combat
-- ones (hide for a fight, back after), and runs no tickers.
------------------------------------------------------------------------
local function InitializeSetupWizard()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializeSetupWizard) return end
    if not (RC.UI and RC.db and RC.UI.CreatePopupShell) then C_Timer.After(0.3, InitializeSetupWizard) return end
    if RC.SetupWizard and RC.SetupWizard.VERSION == 3 then return end

    local Wizard = RC.SetupWizard or {}
    RC.SetupWizard = Wizard
    Wizard.VERSION = 3

    local S = RC.UI.S
    local W, H = 720, 560
    local HEADER_H, FOOTER_H, STEPS_H = 64, 60, 46
    local PAD = 24
    local PAGE_W = W - 2
    local INNER = PAGE_W - 2 * PAD

    local FLAT = RC.UI.FLAT or "Interface\\Buttons\\WHITE8X8"
    local function SC(key, a) return RC.UI:SCol(key, a) end

    local function Text(parent, text, size, alpha, outline)
        local fs = parent:CreateFontString(nil, "OVERLAY")
        RC:ApplyCustomFont(fs, size or S.F_HINT, outline or "")
        if RC.trackedFonts then table.insert(RC.trackedFonts, fs) end
        fs._wrFontSize, fs._wrFontOutline = size or S.F_HINT, outline or ""
        fs:SetText(text or "")
        fs:SetTextColor(SC("text", alpha or 1))
        fs:SetJustifyH("LEFT")
        return fs
    end

    local function Tip(frame, title, body)
        if RC.SetupTip then RC.SetupTip(frame, title, body) end
    end

    local function Button(parent, text, w, h) return RC.UI:CreateStyledButton(parent, text, w or 110, h or 26) end

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
    local S2, steps, index
    local frame, stepBar, pagesHost

    local function Note(key, text)
        if not S2.notes[key] then S2.noteOrder[#S2.noteOrder + 1] = key end
        S2.notes[key] = text
    end
    Wizard.Note = Note

    local function NeedsReload(key, label) S2.reloadExtra[key] = label end

    function Wizard:ReloadNeeded()
        local out = {}
        if not S2 then return out end
        local keys = {}
        for k in pairs(S2.reloadExtra) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do out[#out + 1] = S2.reloadExtra[k] end
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

    -- a section's label, the /rc page's way: small, upper case, dim
    local function Section(host, text, x, y)
        local fs = Text(host, string.upper(text), S.F_SECTION, S.SECTION_A, "OUTLINE")
        fs:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
        return fs
    end

    local function Desc(host, text, x, y, width)
        local fs = Text(host, text, S.F_HINT, S.DIM_A)
        fs:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
        fs:SetWidth(width)
        fs:SetWordWrap(true)
        return fs, math.max(12, fs:GetStringHeight() or 12)
    end

    -- a card: the row band of the /rc page with its hairline edge
    local function Box(parent, w, h)
        local f = CreateFrame("Frame", nil, parent)
        f:SetSize(w, h)
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints()
        f.bg:SetTexture(FLAT)
        f.bg:SetVertexColor(SC("shade", S.ROW_EVEN))
        f.border = RC.UI:CreateSimpleBorder(f)
        RC.UI:UpdateBorderColor(f.border, RC:GetColor("settings", "text"), S.BORDER_A)
        return f
    end

    local function Scroll(host, y, bottom)
        local sf = CreateFrame("ScrollFrame", nil, host)
        sf:SetPoint("TOPLEFT", host, "TOPLEFT", 0, y)
        sf:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -16, bottom or 8)
        local child = CreateFrame("Frame", nil, sf)
        child:SetWidth(PAGE_W - 16)
        child:SetHeight(1)
        sf:SetScrollChild(child)
        local bar = RC.UI:AttachScrollbar(sf, host, { width = 8 })
        bar:ClearAllPoints()
        bar:SetPoint("TOPRIGHT", host, "TOPRIGHT", -6, y)
        bar:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -6, bottom or 8)
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
        local box = CreateFrame("Frame", nil, parent)
        box:SetSize(w, h)
        box.bg = box:CreateTexture(nil, "BACKGROUND")
        box.bg:SetAllPoints()
        box.bg:SetTexture(FLAT)
        box.bg:SetVertexColor(SC("input", 1))
        box.border = RC.UI:CreateSimpleBorder(box)
        RC.UI:UpdateBorderColor(box.border, RC:GetColor("settings", "text"), S.INPUT_BRD_A)
        box.marks = {}
        function box:Rect(x, y, rw, rh, cat, key, alpha)
            local t = self:CreateTexture(nil, "ARTWORK")
            t:SetTexture(FLAT)
            t:SetSize(rw, rh)
            t:SetPoint("TOPLEFT", self, "TOPLEFT", x, -y)
            local c = RC:GetColor(cat or "settings", key or "accent")
            t:SetVertexColor(c.r, c.g, c.b, alpha or 1)
            self.marks[#self.marks + 1] = t
            return t
        end
        function box:Text(text, x, y, size, alpha)
            local fs = Text(self, text, size or 9, alpha or 0.86)
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
            local x = 8 + i * 22
            if glowAt == i + 1 then c:Rect(x - 3, 9, 24, 24, "ui", "readyGlow", 0.35) end
            c:Rect(x, 12, 18, 18, "settings", "buttonBackground")
            c:Rect(x + 2, 14, 14, 14, "settings", "accent", 0.25 + (i % 3) * 0.15)
        end
    end
    function Mini.consumables(c) Icons(c, 4, 2) c:Text(RCL["Flask  Food  Elixir"], 8, 34, 8, 0.53) end
    function Mini.reminders(c)
        c:Rect(32, 4, 34, 34, "ui", "readyGlow", 0.3)
        c:Rect(37, 9, 24, 24, "settings", "buttonBackground")
        c:Rect(39, 11, 20, 20, "text", "red", 0.6)
    end
    function Mini.trackers(c)
        for i = 1, 3 do
            c:Rect(8, 6 + (i - 1) * 13, 80, 10, "settings", "buttonBackground")
            c:Rect(8, 6 + (i - 1) * 13, 80 - (i - 1) * 26, 10, "settings", "accent", 0.55)
        end
    end
    function Mini.gear(c)
        for i = 0, 2 do
            c:Rect(10 + i * 27, 10, 24, 24, "settings", "buttonBackground")
            c:Rect(13 + i * 27, 13, 18, 18, "text", "blue", 0.3 + i * 0.15)
        end
    end
    function Mini.raids(c)
        c:Rect(8, 8, 80, 10, "settings", "buttonBackground")
        c:Rect(8, 8, 56, 10, "text", "red", 0.7)
        c:Rect(8, 26, 80, 10, "settings", "buttonBackground")
        c:Rect(8, 26, 30, 10, "text", "yellow", 0.7)
    end
    function Mini.extras(c)
        c:Rect(8, 10, 80, 8, "settings", "buttonBackground")
        c:Rect(8, 10, 46, 8, "text", "green", 0.8)
        c:Rect(8, 26, 80, 1, "settings", "accent", 0.6)
        c:Text(RCL["Hit 9%  AP 1680"], 8, 31, 8, 0.53)
    end
    local function DrawMini(canvas, kind)
        canvas:Reset()
        local fn = Mini[kind] or Mini.extras
        fn(canvas)
    end
    Wizard.DrawMini = DrawMini

    ------------------------------------------------------------------
    -- The feature groups: the switches, grouped (Tracking step)
    ------------------------------------------------------------------
    local function Flag(tbl, key)
        return function() local t = RC.db[tbl] return type(t) == "table" and t[key] and true or false end,
            function(on)
                if type(RC.db[tbl]) ~= "table" then RC.db[tbl] = {} end
                RC.db[tbl][key] = on and true or false
            end
    end

    -- the raid consume reminder's own store (Consumables_RaidReminders):
    -- read without making it, made from the defaults on the first write
    local function ConsumeStore(make)
        local d = RC.db.consumeRemind
        if type(d) ~= "table" then
            if not make then return (RC.defaults and RC.defaults.consumeRemind) or { enabled = true, onlyInBags = true } end
            d = (RC.DeepCopy and RC.defaults and RC.defaults.consumeRemind and RC.DeepCopy(RC.defaults.consumeRemind)) or { enabled = true, onlyInBags = true }
            RC.db.consumeRemind = d
        end
        return d
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
            RCL["Bars for your flasks, food, potions and weapon stones, and a nudge in raids for what you are not wearing."], {
            { label = RCL["Consumables bar"], get = cHelperGet, set = cHelperSet },
            { label = RCL["Potions bar"], get = potGet, set = potSet },
            { label = RCL["Weapon enchant bar"], get = weapGet, set = weapSet },
            { label = RCL["Missing consumes in raids"], key = "consume",
              get = function() return ConsumeStore(false).enabled == true end,
              set = function(on) ConsumeStore(true).enabled = on and true or false end },
            { label = RCL["Only what is in my bags"], key = "consumeBags",
              get = function() return ConsumeStore(false).onlyInBags ~= false end,
              set = function(on) ConsumeStore(true).onlyInBags = on and true or false end },
        })
        local remItems = {}
        if RC.isWarrior then
            remItems[#remItems + 1] = { label = RCL["Ability reminders"],
                get = function() return RC.db.enabled and true or false end,
                set = function(on) RC.db.enabled = on and true or false end }
            local bsGet, bsSet = Flag("battleShoutReminder", "enabled")
            remItems[#remItems + 1] = { label = RCL["Battle Shout reminder"], get = bsGet, set = bsSet }
        else
            remItems[#remItems + 1] = { label = RCL["Reminders and alerts"],
                get = function() return RC.db.enabled and true or false end,
                set = function(on) RC.db.enabled = on and true or false end }
        end
        local boonGet, boonSet = Flag("boonReminder", "enabled")
        remItems[#remItems + 1] = { label = RCL["Chronoboon reminder"], get = boonGet, set = boonSet }
        remItems[#remItems + 1] = { label = RCL["Sound alerts"], key = "sound",
            get = function() return RC.db.soundEnabled and true or false end,
            set = function(on) RC.db.soundEnabled = on and true or false end,
            test = function()
                if RC.PlaySoundKey then RC:PlaySoundKey(RC.db.soundKey or "WR: Warning", RC.db.soundFile) end
            end,
            testTip = RCL["Plays the reminder sound you have picked (Reminder Settings > Sound)."] }
        remItems[#remItems + 1] = { label = RCL["Voice alerts"], key = "voice",
            get = function() return RC.db.ttsEnabled and true or false end,
            set = function(on) RC.db.ttsEnabled = on and true or false end,
            test = function()
                if RC.SpeakTTSPreview then RC:SpeakTTSPreview(RCL["Elixir of the Mongoose missing"]) end
            end,
            testTip = RCL["Speaks a sample line with the voice Readycheck uses for its alerts."] }
        Group("reminders", RCL["Reminders"], "reminders", "Readycheck_Reminders",
            RCL["Icons when a key ability is ready, Battle Shout and Chronoboon reminders, with a sound and a spoken voice."], remItems)
        local rbGet, rbSet = Flag("raidBuffTracker", "enabled")
        local bdGet, bdSet = Flag("bossDebuffTracker", "enabled")
        Group("trackers", RCL["Trackers"], "trackers", "Readycheck_Reminders",
            RCL["Time left on the raid buffs on you and the debuffs on the boss."], {
            { label = RCL["Raid buff tracker"], get = rbGet, set = function(on) rbSet(on) if RC.RefreshRaidBuffTracker then RC:RefreshRaidBuffTracker() end end },
            { label = RCL["Boss debuff tracker"], get = bdGet, set = function(on) bdSet(on) if RC.RefreshBossDebuffTracker then RC:RefreshBossDebuffTracker() end end },
        })
        local gmGet, gmSet = Flag("gearManager", "enabled")
        local tsGet, tsSet = Flag("trinketSwap", "enabled")
        Group("gear", RCL["Gear"], "gear", "Readycheck_Gear",
            RCL["Gear sets on screen buttons, and on-use trinkets rotated for you in combat."], {
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
            RCL["Your own boss notes when you target the boss, and a kill timer."], {
            { label = RCL["Boss notes overlay"], addon = "Readycheck_Features", get = bnGet, set = function(on) bnSet(on) if RC.UpdateBossNotes then RC:UpdateBossNotes() end end },
            { label = RCL["Time-to-kill display"], addon = "Readycheck_Reminders", get = ttkGet, set = ttkSet },
        })
        local npGet, npSet = Flag("nameplateAuras", "enabled")
        Group("extras", RCL["Extras"], "extras", nil,
            RCL["Your debuffs on enemy nameplates, and the character stats button."], {
            { label = RCL["Debuffs on nameplates"], addon = "Readycheck_Features", get = npGet, set = npSet },
            { label = RCL["Stats bar button"], get = function() return RC.db.showStatsButton and true or false end,
              set = function(on) RC.db.showStatsButton = on and true or false if RC.UpdateStatsButton then RC:UpdateStatsButton() end end },
        })
        return groups
    end
    Wizard.FeatureGroups = FeatureGroups

    ------------------------------------------------------------------
    -- 1. YOU
    ------------------------------------------------------------------
    local ROLES = {
        { id = "auto", label = RCL["As detected"] },
        { id = "tank", label = RCL["Tank"] },
        { id = "melee", label = RCL["Melee"] },
        { id = "ranged", label = RCL["Ranged"] },
        { id = "healer", label = RCL["Healer"] },
    }

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

    local function PageYou(host)
        local x, y = PAD, -6
        local className = UnitClass("player")
        local specKey = RC.DetectWarriorSpec and RC:DetectWarriorSpec() or nil
        local specData = specKey and RC.specDetection and RC.specDetection.specs and RC.specDetection.specs[specKey] or nil
        local card = Box(host, INNER, 84)
        card:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
        local icon = card:CreateTexture(nil, "ARTWORK")
        icon:SetSize(52, 52)
        icon:SetPoint("LEFT", card, "LEFT", 16, 0)
        icon:SetTexture(specData and specData.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local who = Text(card, (UnitName("player") or "") .. "  -  " .. (className or ""), 16, 1, "OUTLINE")
        who:SetPoint("TOPLEFT", icon, "TOPRIGHT", 14, 0)
        local spec = Text(card, specData and (RCL["Spec: "] .. specData.name .. RCL[" (read from your talents)"]) or RCL["Spec: not detected yet"], S.F_HINT, 0.86)
        spec:SetPoint("TOPLEFT", who, "BOTTOMLEFT", 0, -6)
        -- the game version, one line (the old Game version step); the
        -- list of what is off here is in its tooltip
        local flavor = RC.Flavor and RC:Flavor() or "era"
        local fname = RC.FlavorName and RC:FlavorName(flavor) or flavor
        local off = RC.FeaturesOff and RC:FeaturesOff(flavor) or {}
        local game = Text(card, RCL["Game: "] .. fname .. "  -  " .. (#off == 0 and RCL["everything Readycheck has runs here"]
            or (#off .. RCL[" features are off on this client"])), S.F_HINT, S.DIM_A)
        game:SetPoint("TOPLEFT", spec, "BOTTOMLEFT", 0, -6)
        host.specText, host.gameText, host.offCount = spec, game, #off
        if #off > 0 then
            card:EnableMouse(true)
            local lines = {}
            for _, f in ipairs(off) do lines[#lines + 1] = f.name end
            Tip(card, RCL["Off on "] .. fname, table.concat(lines, ", ") .. RCL[". The full list is under /rc > Settings > Game version."])
        end
        y = y - 84 - 22

        Section(host, RCL["Your role"], x, y)
        y = y - 20
        local d = DB()
        host.roleButtons = {}
        local function Paint()
            for id, b in pairs(host.roleButtons) do b:SetActive(id == d.role) end
        end
        local bx = x
        for i, r in ipairs(ROLES) do
            local b = Button(host, r.label, i == 1 and 120 or 100, 28)
            b:SetPoint("TOPLEFT", host, "TOPLEFT", bx, y)
            b:SetScript("OnClick", function()
                d.role = r.id
                Save()
                Note("role", RCL["Role: "] .. r.label)
                Paint()
            end)
            host.roleButtons[r.id] = b
            bx = bx + b:GetWidth() + 8
        end
        Paint()
        y = y - 28 - 10
        local _, dh = Desc(host, RCL["Written down for the raid profiles and the consume lists. It never switches anything on or off."], x, y, INNER)
        y = y - dh - 22

        local others = OtherCharacters()
        host.copyDropdown, host.copyButton = nil, nil
        if #others > 0 then
            Section(host, RCL["Already use Readycheck on another character?"], x, y)
            y = y - 20
            local chosen
            local dd = RC.UI:CreateScrollableDropdown(host, 260, RCL["Pick a character"], 6)
            dd:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
            local items = {}
            for _, k in ipairs(others) do items[#items + 1] = { text = k, value = k } end
            dd:SetItems(items, function(value) chosen = value end)
            host.copyDropdown = dd
            local status
            local copy = Button(host, RCL["Copy"], 90, 26)
            copy:SetPoint("LEFT", dd, "RIGHT", 10, 0)
            copy:SetScript("OnClick", function()
                if not chosen then RC:Print(RCL["Pick a character first."]) return end
                local ok, n = Wizard:CopyFromCharacter(chosen)
                if ok then
                    Note("profile", RCL["Settings copied from "] .. chosen)
                    NeedsReload("profile", RCL["The copied settings"])
                    status:SetText(RCL["Copied "] .. tostring(n) .. RCL[" settings from "] .. chosen .. RCL[". Finish reloads to apply them."])
                else
                    status:SetText(RCL["Nothing to copy from "] .. tostring(chosen) .. ".")
                end
            end)
            Tip(copy, RCL["Copy"], RCL["Every setting an export string carries, copied from that character onto this one. Raid profiles too. Finish then reloads to apply it all."])
            host.copyButton = copy
            y = y - 26 - 10
            local fs, h2 = Desc(host, RCL["Copies every setting an export string carries. Finish then reloads to apply it."], x, y, INNER)
            status = fs
            host.copyStatus = fs
            y = y - h2
        end
    end

    ------------------------------------------------------------------
    -- 2. TRACKING
    ------------------------------------------------------------------
    local function PageTracking(host)
        local sf, child, bar = Scroll(host, -2)
        local cardW = INNER
        local colW = math.floor((cardW - 132 - 16) / 2)
        local cy = -2
        host.featureChecks, host.featureMinis, host.testButtons = {}, {}, {}
        for _, g in ipairs(FeatureGroups()) do
            local card = Box(child, cardW, 60)
            card:SetPoint("TOPLEFT", child, "TOPLEFT", PAD, cy)
            local mini = Canvas(card, 96, 44)
            mini:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -14)
            DrawMini(mini, g.mini)
            host.featureMinis[g.id] = mini
            local head = Text(card, g.title, 14, 1, "OUTLINE")
            head:SetPoint("TOPLEFT", card, "TOPLEFT", 126, -12)
            local desc = Text(card, g.desc, S.F_HINT - 1, S.DIM_A)
            desc:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -4)
            desc:SetWidth(cardW - 126 - 14)
            desc:SetWordWrap(true)
            local iy = -(12 + 16 + 4 + math.max(12, desc:GetStringHeight() or 12) + 10)
            local anyOn = false
            local col = 0
            for _, it in ipairs(g.items) do
                local addon = it.addon or g.addon
                local okG, v = pcall(it.get)
                v = okG and v and true or false
                if v then anyOn = true end
                local cx = 126 + col * (colW + 16)
                if AddonOn(addon) then
                    local cb = RC.UI:CreateCheckbox(card, it.label, v)
                    cb:ClearAllPoints()
                    cb:SetPoint("TOPLEFT", card, "TOPLEFT", cx, iy)
                    cb:SetScript("OnClick", function(self)
                        local on = self:GetChecked() and true or false
                        local ok, err = pcall(it.set, on)
                        if not ok then RC:DebugPrint("setup: " .. it.label .. ": " .. tostring(err), "wizard") end
                        Save()
                        Note("feat:" .. g.id .. ":" .. it.label, it.label .. (on and RCL[" on"] or RCL[" off"]))
                        RC:DebugPrint("SetupWizard: " .. it.label .. "=" .. tostring(on), "wizard")
                        local lit = false
                        for _, o in ipairs(g.items) do local okO, vv = pcall(o.get) if okO and vv then lit = true end end
                        Dim(mini, lit)
                    end)
                    host.featureChecks[g.id .. ":" .. it.label] = cb
                    if it.test then
                        local tb = Button(card, RCL["Test"], 52, 20)
                        local lw = (cb.Text and cb.Text:GetStringWidth()) or 100
                        tb:SetPoint("LEFT", cb, "RIGHT", 10 + lw + 10, 0)
                        tb:SetScript("OnClick", it.test)
                        Tip(tb, RCL["Test"], it.testTip)
                        host.testButtons[it.key] = tb
                    end
                else
                    local need = Text(card, it.label .. RCL[" - needs the "] .. tostring(addon) .. RCL[" addon"], S.F_HINT - 1, 1)
                    local red = RC:GetColor("text", "red")
                    need:SetTextColor(red.r, red.g, red.b, 1)
                    need:SetPoint("TOPLEFT", card, "TOPLEFT", cx, iy - 2)
                    need:SetWidth(colW)
                    Tip(card, it.label, RCL["Enable the "] .. tostring(addon) .. RCL[" addon in your AddOns list and /reload."])
                    card:EnableMouse(true)
                end
                col = col + 1
                if col == 2 then col = 0 iy = iy - 26 end
            end
            if col ~= 0 then iy = iy - 26 end
            Dim(mini, anyOn)
            local cardH = math.max(72, -iy + 8)
            card:SetHeight(cardH)
            cy = cy - cardH - 10
        end
        FinishScroll(sf, child, bar, -cy + 4)
    end

    ------------------------------------------------------------------
    -- 3. LAYOUT (SetupLayouts draws it when it is there)
    ------------------------------------------------------------------
    local function LayoutReady()
        local LP = RC.SetupLayouts
        return type(LP) == "table" and type(LP.BuildStep) == "function" and LP.Available and LP.Available()
    end
    local function LayoutName(id)
        local LP = RC.SetupLayouts
        local p = LP and LP.Preset and LP.Preset(id)
        return p and p.name or tostring(id)
    end
    local function PageLayout(host)
        local d = DB()
        RC.SetupLayouts.BuildStep(host, -6, {
            pageW = PAGE_W, pad = PAD, canvas = Canvas,
            chosen = d.layout or "keep",
            choose = function(id)
                d.layout = (id ~= "keep") and id or nil
                if id == "keep" then S2.notes.layout = nil
                else Note("layout", RCL["Layout: "] .. LayoutName(id) .. RCL[" (applied on Finish)"]) end
            end,
        })
    end

    ------------------------------------------------------------------
    -- 4. EXTRAS
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
    local function ExtrasAvailable()
        return #RaidsWithProfiles() > 0 or (#Presets() > 0 and RC.ImportRaidProfile ~= nil) or RC.ImportAny ~= nil
    end

    local function PageExtras(host)
        local sf, child, bar = Scroll(host, -2)
        local x = PAD
        local wide = INNER
        local cy = -6
        host.raidDropdowns = {}
        local raids = RaidsWithProfiles()
        if #raids > 0 then
            Section(child, RCL["Active profile per raid"], x, cy)
            cy = cy - 22
            for _, r in ipairs(raids) do
                local name = Text(child, r.raid, S.F_VALUE, 0.86)
                name:SetPoint("TOPLEFT", child, "TOPLEFT", x, cy - 5)
                name:SetWidth(170)
                local dd = RC.UI:CreateScrollableDropdown(child, 240, r.active, 6)
                dd:SetPoint("TOPLEFT", child, "TOPLEFT", x + 180, cy)
                local items = {}
                for _, n in ipairs(r.names) do items[#items + 1] = { text = n, value = n } end
                dd:SetItems(items, function(value)
                    if RC.SetActiveRaidProfile then RC:SetActiveRaidProfile(r.raid, value, true) end
                    Note("raid:" .. r.raid, r.raid .. RCL[": active profile "] .. value)
                end)
                dd:SetSelectedValue(r.active, r.active)
                host.raidDropdowns[r.raid] = dd
                cy = cy - 32
            end
            cy = cy - 12
        end
        local presets = Presets()
        host.presetButtons = {}
        if #presets > 0 and RC.ImportRaidProfile then
            Section(child, RCL["Raid profile presets"], x, cy)
            cy = cy - 22
            for _, raidEntry in ipairs(presets) do
                for _, profile in ipairs(raidEntry.profiles) do
                    local b = Button(child, raidEntry.name .. "  -  " .. profile.name, 420, 28)
                    b:SetPoint("TOPLEFT", child, "TOPLEFT", x, cy)
                    local pData, pName, rName = profile.data, profile.name, raidEntry.name
                    b:SetScript("OnClick", function()
                        if RC.remoteEditMode and RC.ExitRemoteEditMode then RC:ExitRemoteEditMode() end
                        local ok = RC:ImportRaidProfile(pData, pName)
                        if ok then
                            b:SetActive(true)
                            RC.UI:SetButtonText(b, rName .. RCL[" - Imported"])
                            Note("preset:" .. rName .. ":" .. pName, RCL["Imported preset: "] .. rName .. " - " .. pName)
                        end
                    end)
                    if profile.description then Tip(b, pName, profile.description) end
                    host.presetButtons[#host.presetButtons + 1] = b
                    cy = cy - 34
                end
            end
            local _, dh = Desc(child, RCL["Imports the bosses, gear swaps and notes for that raid. When you enter a raid with more than one profile, a picker asks which to load."], x, cy, wide)
            cy = cy - dh - 18
        end
        host.importBox, host.importButton = nil, nil
        if RC.ImportAny then
            Section(child, RCL["Paste a settings string"], x, cy)
            cy = cy - 22
            local box = RC.UI:CreateStyledEditBox(child, { width = wide - 110, multiLine = true, scrollable = true, scrollHeight = 52, height = 52 })
            box:SetPoint("TOPLEFT", child, "TOPLEFT", x, cy)
            host.importBox = box
            local imp = Button(child, RCL["Import"], 100, 28)
            imp:SetPoint("TOPLEFT", box, "TOPRIGHT", 10, 0)
            imp:SetScript("OnClick", function()
                local eb = box.editBox or box
                local text = eb.GetText and eb:GetText() or ""
                if text:match("^%s*$") then RC:Print(RCL["Paste a string first."]) return end
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
            cy = cy - 64 - 8
            local _, dh = Desc(child, RCL["A whole settings string replaces what you set in the steps before; Finish then reloads."], x, cy, wide)
            cy = cy - dh - 6
        end
        FinishScroll(sf, child, bar, -cy + 4)
    end

    ------------------------------------------------------------------
    -- 5. FINISH
    ------------------------------------------------------------------
    local function PageFinish(host)
        local x, y = PAD, -6
        local d = DB()
        Section(host, RCL["What you chose"], x, y)
        y = y - 22
        local lines = {}
        for _, key in ipairs(S2.noteOrder) do if S2.notes[key] then lines[#lines + 1] = S2.notes[key] end end
        if #lines == 0 then lines[1] = RCL["Nothing changed - Readycheck keeps its defaults."] end
        local sf, child, bar = Scroll(host, y, 150)
        local cy = -2
        local A = RC.UI:SAccent()
        for _, l in ipairs(lines) do
            local dot = child:CreateTexture(nil, "ARTWORK")
            RC.UI:DiscArt(dot, 6)
            dot:SetSize(6, 6)
            dot:SetVertexColor(A.r, A.g, A.b, 0.9)
            dot:SetPoint("TOPLEFT", child, "TOPLEFT", x + 2, cy - 5)
            local fs = Text(child, l, S.F_VALUE, 0.86)
            fs:SetPoint("TOPLEFT", child, "TOPLEFT", x + 16, cy)
            fs:SetWidth(INNER - 16)
            fs:SetWordWrap(true)
            cy = cy - math.max(15, fs:GetStringHeight() or 14) - 6
        end
        FinishScroll(sf, child, bar, -cy + 4)
        host.summaryCount = #lines

        local by = 140
        local reload = Wizard:ReloadNeeded()
        host.reloadText = nil
        if #reload > 0 then
            local fs = Text(host, RCL["Finish reloads the interface to apply: "] .. table.concat(reload, ", ") .. ".", S.F_HINT, 0.86)
            fs:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", x, by)
            fs:SetWidth(INNER)
            fs:SetWordWrap(true)
            host.reloadText = fs
        end
        by = by - 34
        local tour = RC.UI:CreateCheckbox(host, RCL["Show me around the settings window afterwards"], d.tour == true)
        tour:ClearAllPoints()
        tour:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", x, by)
        tour:SetScript("OnClick", function(self) d.tour = self:GetChecked() and true or nil end)
        Tip(tour, RCL["The tour"], RCL["A short walk around the settings window. /rc tutorial plays it any time."])
        host.tourCheck = tour
        by = by - 40
        local cmd = Text(host, RCL["/rc opens the settings.  /rc setup runs this again.  /rc tutorial plays the tour."], S.F_HINT, S.DIM_A)
        cmd:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", x, by)
        by = by - 22
        local disc = Text(host, RCL["Questions or feedback? Discord: "] .. tostring(RC.CONTACT_DISCORD or "Zac12"), S.F_HINT, S.DIM_A)
        disc:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", x, by)
    end

    ------------------------------------------------------------------
    -- The steps
    ------------------------------------------------------------------
    local ALL_STEPS = {
        { id = "you", label = RCL["You"], title = RCL["Welcome to Readycheck"],
          sub = RCL["A few short steps. Nothing changes until you pick it, and /rc changes it all later."], build = PageYou },
        { id = "tracking", label = RCL["Tracking"], title = RCL["What Readycheck tracks"],
          sub = RCL["Tick what you want. Each group shows a glimpse of what it puts on screen."], build = PageTracking },
        { id = "layout", label = RCL["Layout"], title = RCL["Where things sit"],
          sub = RCL["Pick an arrangement for the bars and reminders. It is applied when you press Finish."], build = PageLayout,
          available = LayoutReady },
        { id = "extras", label = RCL["Extras"], title = RCL["Optional extras"],
          sub = RCL["Ready-made raid profiles and settings strings. All of it can wait."], build = PageExtras,
          available = ExtrasAvailable },
        { id = "finish", label = RCL["Finish"], title = RCL["All set"],
          sub = RCL["Here is what Finish does. Everything can be changed later with /rc."], build = PageFinish },
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
    -- The step bar: a numbered disc and a name per step, joined by a
    -- line; the current one in the accent, the ones behind filled. Each
    -- is a button (any step can be visited in any order).
    ------------------------------------------------------------------
    local DOT = 20
    local function PaintStepBar()
        local A = RC.UI:SAccent()
        local bg = RC:GetColor("settings", "windowBackground")
        for i, b in ipairs(stepBar.items) do
            if not steps[i] then break end
            local cur, done = i == index, i < index
            if done then
                b.ring:SetVertexColor(A.r, A.g, A.b, 0.9)
                b.hole:Hide()
                b.num:SetTextColor(bg.r, bg.g, bg.b, 1)
            else
                if cur then b.ring:SetVertexColor(A.r, A.g, A.b, 1) else b.ring:SetVertexColor(SC("text", 0.25)) end
                b.hole:Show()
                if cur then b.num:SetTextColor(A.r, A.g, A.b, 1) else b.num:SetTextColor(SC("text", 0.5)) end
            end
            b.label:SetTextColor(SC("text", cur and 1 or (done and 0.75 or 0.45)))
            if b.line then
                if done then b.line:SetVertexColor(A.r, A.g, A.b, 0.7) else b.line:SetVertexColor(SC("text", 0.12)) end
            end
        end
    end

    local function FillStepBar()
        for _, b in ipairs(stepBar.items) do b:Hide() if b.line then b.line:Hide() end end
        local x = PAD
        for i, st in ipairs(steps) do
            local b = stepBar.items[i]
            if not b then
                b = CreateFrame("Button", nil, stepBar)
                b:SetHeight(DOT)
                b.ring = b:CreateTexture(nil, "ARTWORK", nil, 1)
                b.ring:SetSize(DOT, DOT)
                b.ring:SetPoint("LEFT", b, "LEFT", 0, 0)
                RC.UI:DiscArt(b.ring, DOT)
                b.hole = b:CreateTexture(nil, "ARTWORK", nil, 2)
                b.hole:SetSize(DOT - 3, DOT - 3)
                b.hole:SetPoint("CENTER", b.ring, "CENTER", 0, 0)
                RC.UI:DiscArt(b.hole, DOT - 3)
                b.num = Text(b, "", 11, 1, "OUTLINE")
                b.num:SetPoint("CENTER", b.ring, "CENTER", 0, 0)
                b.num:SetJustifyH("CENTER")
                b.num:SetDrawLayer("OVERLAY", 3)
                b.label = Text(b, "", S.F_VALUE, 1)
                b.label:SetPoint("LEFT", b.ring, "RIGHT", 7, 0)
                b.line = stepBar:CreateTexture(nil, "ARTWORK")
                b.line:SetTexture(FLAT)
                b.line:SetHeight(1)
                stepBar.items[i] = b
            end
            local wb = RC:GetColor("settings", "windowBackground")
            b.hole:SetVertexColor(wb.r, wb.g, wb.b, 1)
            b.num:SetText(tostring(i))
            b.label:SetText(st.label)
            local w = DOT + 7 + math.ceil(b.label:GetStringWidth() or 40)
            b:SetWidth(w)
            b:ClearAllPoints()
            b:SetPoint("LEFT", stepBar, "LEFT", x, 0)
            b:SetScript("OnClick", function() Wizard:ShowStep(i) end)
            b:Show()
            x = x + w
            if i < #steps then
                b.line:ClearAllPoints()
                b.line:SetPoint("LEFT", stepBar, "LEFT", x + 10, 0)
                b.line:SetWidth(26)
                b.line:Show()
                x = x + 46
            else
                b.line:Hide()
            end
        end
    end

    ------------------------------------------------------------------
    -- Paging
    ------------------------------------------------------------------
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
        if not ok then RC:DebugPrint("SetupWizard: " .. steps[index].id .. ": " .. tostring(err), "wizard") end
        frame.page, frame.pageId = host, steps[index].id
        frame.titleText:SetText(steps[index].title)
        if frame.subtitleText then frame.subtitleText:SetText(steps[index].sub or "") end
        frame.stepCountText:SetText(RCL["Step "] .. index .. RCL[" of "] .. #steps)
        frame.prevBtn:SetShown(index > 1)
        RC.UI:SetButtonText(frame.nextBtn, index == #steps and (#self:ReloadNeeded() > 0 and RCL["Finish & reload"] or RCL["Finish"]) or RCL["Next"])
        PaintStepBar()
        self.shownLog = self.shownLog or {}
        self.shownLog[#self.shownLog + 1] = steps[index].id
    end

    function Wizard:GoToNext()
        if index < #steps then self:ShowStep(index + 1) else self:Finish() end
    end
    function Wizard:GoToPrev() if index > 1 then self:ShowStep(index - 1) end end

    -- the one Finish: the layout picked is applied, the setup is done, and
    -- one line in chat says so (a reload instead when a copy or import
    -- needs one; the tour only when ticked)
    function Wizard:Finish()
        if InCombat() then RC:Print(RCL["The setup finishes after combat."]) return end
        local d = DB()
        local layoutId = d.layout
        if layoutId and layoutId ~= "keep" and LayoutReady() then
            local n = RC.SetupLayouts.Apply(layoutId, { quiet = true })
            RC:DebugPrint("SetupWizard: layout " .. tostring(layoutId) .. " placed " .. tostring(n), "wizard")
        end
        local tour = d.tour == true
        d.layout, d.tour = nil, nil
        d.completed = true
        d.lastStep = 1
        self.currentStep = nil
        Save()
        local reload = #self:ReloadNeeded() > 0
        self:Close(true)
        -- a changelog that waited for the setup is not shown on top of it
        -- now: it is counted as seen and the line says where it is
        local whatsNew = ""
        if RC.Changelog and RC.Changelog.ShouldShowPopup and RC.Changelog:ShouldShowPopup() then
            RC.Changelog:MarkAsSeen()
            whatsNew = RCL[" What's new: |cffffd700/rc changelog|r."]
        end
        RC:Print(RCL["Setup done. |cffffd700/rc|r opens the settings any time."] .. whatsNew)
        if reload then
            if type(ReloadUI) == "function" then ReloadUI() elseif C_UI and C_UI.Reload then C_UI.Reload() end
            return
        end
        if tour then self:FinishIntoSettings() end
    end

    -- Skip setup: Readycheck keeps its defaults and what was already ticked
    function Wizard:SkipAll()
        local d = DB()
        d.completed = true
        d.layout, d.tour = nil, nil
        d.lastStep = 1
        self.currentStep = nil
        Save()
        self:Close(true)
        RC:Print(RCL["Setup skipped - the defaults are on. |cffffd700/rc|r opens the settings; |cffffd700/rc setup|r brings this back."])
    end

    -- the tour, when the Finish tick asked for it
    function Wizard:FinishIntoSettings()
        if not (RC.sidebarConfigFrame and RC.sidebarConfigFrame:IsShown()) and RC.CreateSidebarConfigWindow then
            RC:CreateSidebarConfigWindow()
        end
        C_Timer.After(0.5, function()
            if RC.Tutorial and not RC.Tutorial.active then RC.Tutorial:Start("wizard") end
        end)
    end

    ------------------------------------------------------------------
    -- The window: the 5.0 popup shell
    ------------------------------------------------------------------
    local function Build()
        local f = RC.UI:CreatePopupShell("WRSetupWizardFrame", {
            width = W, height = H, title = RCL["Welcome to Readycheck"], subtitle = "",
            headerH = HEADER_H, footerH = FOOTER_H, level = 100,
            onClose = function() Wizard:Close() end,
        })
        f.header:SetScript("OnMouseDown", function() f:Raise() end)

        stepBar = CreateFrame("Frame", nil, f.body)
        stepBar:SetPoint("TOPLEFT", f.body, "TOPLEFT", 0, 0)
        stepBar:SetPoint("TOPRIGHT", f.body, "TOPRIGHT", 0, 0)
        stepBar:SetHeight(STEPS_H)
        stepBar.items = {}
        local rule = stepBar:CreateTexture(nil, "ARTWORK")
        rule:SetHeight(1)
        rule:SetPoint("BOTTOMLEFT", stepBar, "BOTTOMLEFT", PAD, 0)
        rule:SetPoint("BOTTOMRIGHT", stepBar, "BOTTOMRIGHT", -PAD, 0)
        RC.UI:SkinPopup(f, { rules = { rule } })
        f.stepBar = stepBar

        pagesHost = CreateFrame("Frame", nil, f.body)
        pagesHost:SetPoint("TOPLEFT", stepBar, "BOTTOMLEFT", 0, -10)
        pagesHost:SetPoint("BOTTOMRIGHT", f.body, "BOTTOMRIGHT", 0, 6)

        f.skipAllBtn = f:AddFooterButton(RCL["Skip setup"], 120, false, function() Wizard:SkipAll() end, "left")
        Tip(f.skipAllBtn, RCL["Skip setup"], RCL["Closes the setup and keeps Readycheck's defaults (and anything you already ticked). /rc setup brings it back any time."])
        f.nextBtn = f:AddFooterButton(RCL["Next"], 140, true, function() Wizard:GoToNext() end, "right")
        f.prevBtn = f:AddFooterButton(RCL["Back"], 100, false, function() Wizard:GoToPrev() end, "right")
        local count = Text(f.footer, "", S.F_HINT, S.DIM_A)
        count:SetPoint("CENTER", f.footer, "CENTER", -40, 0)
        count:SetJustifyH("CENTER")
        f.stepCountText = count

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
        -- a setup saved by an older version resumes from its first step
        if d.version ~= Wizard.VERSION then d.lastStep = 1 self.currentStep = nil end
        d.version = Wizard.VERSION
        S2 = { notes = {}, noteOrder = {}, reloadExtra = {} }
        self.shownLog = {}
        steps = BuildSteps()
        FillStepBar()
        if d.layout then Note("layout", RCL["Layout: "] .. LayoutName(d.layout) .. RCL[" (applied on Finish)"]) end
        local start = self.currentStep or tonumber(d.lastStep) or 1
        if start > #steps or start < 1 then start = 1 end
        self:ShowStep(start)
        Watch():RegisterEvent("PLAYER_REGEN_DISABLED")
        frame:Show()
        frame:Raise()
        if RC.UI.PopIn then RC.UI:PopIn(frame, 0.15) end
        return true
    end

    -- done: Finish or Skip setup (no hint); otherwise the X or Escape,
    -- which keeps the step and says once how to come back
    function Wizard:Close(done)
        if watch then watch:UnregisterEvent("PLAYER_REGEN_DISABLED") end
        pendingReopen = false
        if RC.SetupLayouts and RC.SetupLayouts.EndPreview then RC.SetupLayouts.EndPreview() end
        if frame and frame:IsShown() then
            frame:Hide()
            if not done and RC.Hints then
                RC.Hints.Say("setup_closed", RCL["Setup closed - |cffffd700/rc setup|r picks it up where you left off."])
            end
        end
    end

    function Wizard:IsShown() return frame ~= nil and frame:IsShown() end
    -- on screen, or waiting for a fight to end: the changelog holds back
    function Wizard:IsBusy() return self:IsShown() or pendingReopen end

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
                C_Timer.After(1, function()
                    if InCombat() or not pendingReopen then return end
                    pendingReopen = false
                    if frame and S2 then
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
    InitializeSetupWizard()
else
    initFrame:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_LOGIN" then
            self:UnregisterEvent("PLAYER_LOGIN")
            C_Timer.After(0.5, InitializeSetupWizard)
        end
    end)
end
