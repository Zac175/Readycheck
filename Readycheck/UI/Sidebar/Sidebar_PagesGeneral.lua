------------------------------------------------------------------------
-- Readycheck - General & Behavior + Overview Pages
-- General & Behavior page (db.enabled, db.minimapButton, db.nonWarriorEnabled)
-- plus the group overview pages (RC:ShowSidebarGroupOverview, one per
-- sidebar group) and Spec Detection. The per-reminder toggles
-- (db.showInCombatOnly, db.clickThrough, db.abilityReadyGracePeriod) are
-- edited on the Reminders page only. An overview tile's sidebar box flips
-- db.sidebarNav[key] and rebuilds the menu (RC:BuildSidebar) live.
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
local TEXT = _sbs.TEXT

    ------------------------------------------------------------------
    -- Display page kit (RC._disp): small helpers the display pages share
    -- (stats bar, buff pushoff, spec popup, polarity bar, nameplates,
    -- world buff board, sync transfer bar). Framework widgets only; these
    -- just remove the repetition. Candidates for the framework.
    ------------------------------------------------------------------
    local K = RC._disp or {}
    RC._disp = K

    -- A feature's "look" sub-table, created on first use (nil fields =
    -- today's look, so an old profile reads unchanged).
    function K.Look(root, field)
        field = field or "look"
        if type(root) ~= "table" then return {} end
        if type(root[field]) ~= "table" then root[field] = {} end
        return root[field]
    end

    -- A font spec with one field taken from a legacy key (size), so the
    -- picker can show and write the key a profile has always had.
    function K.CopySpec(t)
        local out = {}
        if type(t) == "table" then for k, v in pairs(t) do out[k] = v end end
        return out
    end

    -- Backgrounds that are flat today: nil = flat, "" = the global
    -- Readycheck texture, anything else an LSM statusbar name.
    function K.BgTexName(v)
        if v == nil then return "Solid" end
        if v == "" then return nil end
        return v
    end
    function K.PaintBg(tex, v, c, alpha)
        if v == nil then
            tex:SetTexture(RC.UI.FLAT)
        else
            RC:ApplyTextureSpec(tex, K.BgTexName(v))
        end
        if c then tex:SetVertexColor(c.r, c.g, c.b, alpha or c.a or 1) end
    end

    -- A gray 10px line under a control, one line at most (the rest in
    -- its tooltip: RC.UI:CreateHelpLine); returns the next y.
    function K.Desc(card, y, text, x)
        local ny, h = RC.UI:CreateHelpLine(card, x or 14, y, text)
        return ny, h.text
    end

    function K.Check(card, y, label, get, set, desc)
        local cb = RC.UI:CreateSettingCheckbox(card, y, label, get(), function(box)
            local on = box:GetChecked() and true or false
            set(on)
            RC:ForceCheckboxUpdate(box, on)
            RC:SaveConfigurationToProfile()
        end)
        if RC.RegisterCheckboxWithData then RC:RegisterCheckboxWithData(cb, get, set) end
        y = y - 26
        if desc then y = K.Desc(card, y + 4, desc, 35) end
        return y, cb
    end

    -- Slider with its label above and the unit in the value. scale > 1
    -- for fractions (100 = hundredths), fmt formats the shown value.
    function K.Slider(card, y, label, lo, hi, value, step, fmt, onChange, scale)
        scale = scale or 1
        local s = RC.UI:CreateSettingSlider(card, lo * scale, hi * scale, (value or lo) * scale, step * scale, 14, y,
            fmt(value or lo), function(sl, v)
                v = v / scale
                if scale == 1 then v = math_floor(v + 0.5) end
                sl.Text:SetText(fmt(v))
                onChange(v)
            end)
        s:SetLabel(label)
        return y - 45, s
    end

    -- A colour picker over a theme colour (the one Appearance > Colors edits).
    function K.ThemeColor(card, y, label, cat, key, apply, tooltip)
        local cp = RC.UI:CreateColorPicker(card, {
            label = label, width = 420, tooltip = tooltip,
            get = function() return RC:GetColor(cat, key) end,
            set = function(r, g, b, a)
                if a == nil then a = RC:GetColor(cat, key).a or 1 end
                RC:SetColor(cat, key, r, g, b, a)
                if apply then apply() end
            end,
            isChanged = function()
                local cc = RC.db and RC.db.customColors
                return cc ~= nil and cc[cat] ~= nil and cc[cat][key] ~= nil
            end,
            reset = function() RC:ResetColor(cat, key) if apply then apply() end end,
        })
        cp:SetPoint("TOPLEFT", card, "TOPLEFT", 10, y)
        return y - 28, cp
    end

    -- A colour kept in a feature table (nil = fallback()).
    function K.LookColor(card, y, label, tbl, field, fallback, apply, alpha, tooltip)
        local cp = RC.UI:CreateColorPicker(card, {
            label = label, width = 420, alpha = alpha, tooltip = tooltip,
            get = function() return tbl()[field] or fallback() end,
            set = function(r, g, b, a)
                tbl()[field] = { r = r, g = g, b = b, a = a or 1 }
                RC:SaveConfigurationToProfile()
                if apply then apply() end
            end,
            isChanged = function() return type(tbl()[field]) == "table" end,
            reset = function()
                tbl()[field] = nil
                RC:SaveConfigurationToProfile()
                if apply then apply() end
            end,
        })
        cp:SetPoint("TOPLEFT", card, "TOPLEFT", 10, y)
        return y - 28, cp
    end

    function K.Font(card, y, label, get, set, defaults, sample, minS, maxS)
        local fp = RC.UI:CreateFontPicker(card, {
            label = label, width = 420, get = get,
            set = function(spec) set(spec) RC:SaveConfigurationToProfile() end,
            defaults = defaults, minSize = minS or 6, maxSize = maxS or 32, sample = sample,
        })
        fp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
        return y - fp:GetHeight() - 12, fp
    end

    -- A background texture that is flat until one is picked.
    function K.BgTexture(card, y, label, get, set, tint)
        local tp = RC.UI:CreateTexturePicker(card, {
            label = label, width = 260, color = tint,
            get = function() return K.BgTexName(get()) end,
            set = function(name)
                if name == nil then set("") elseif name == "Solid" then set(nil) else set(name) end
                RC:SaveConfigurationToProfile()
            end,
        })
        tp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
        return y - tp:GetHeight() - 12, tp
    end

    function K.Anim(card, y, label, how, get, set, defaults, styles, P)
        local ap = RC.UI:CreateAnimationPicker(card, {
            label = label, width = 460, how = how, defaults = defaults, styles = styles,
            get = get,
            set = function(s)
                set(s)
                RC:SaveConfigurationToProfile()
                if P then P.Replay() end
            end,
        })
        ap:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
        return y - ap:GetHeight() - 14, ap
    end

    -- A card that closes itself: fill(card, y) -> y.
    function K.Card(parent, yPos, title, fill)
        local card = RC:CreateSettingsCard(parent, yPos, title)
        local y = fill(card, -32) or -32
        card:SetContentHeight(math.abs(y))
        return yPos - card:GetHeight() - 15, card
    end

    function K.Tabs(parent, yPos, tabs, selected, onClick)
        local defs = {}
        for i, t in ipairs(tabs) do defs[i] = { key = t[1], label = t[2] } end
        local tg, y = RC.UI:CreateTabGroup(parent, { y = yPos, tabs = defs, selected = selected,
            onClick = onClick, advance = 38 + 8 })
        return y, tg
    end

    -- X/Y offset sliders for a frame bound to RC.Position (or plain keys).
    function K.Offsets(card, y, getX, getY, setXY, range)
        range = range or 800
        local fmt = function(v) return math_floor(v + 0.5) .. RCL[" px"] end
        local y1 = K.Slider(card, y, RCL["Horizontal position"], -range, range, getX(), 1, fmt,
            function(v) setXY(v, nil) end)
        local y2 = K.Slider(card, y1, RCL["Vertical position"], -range, range, getY(), 1, fmt,
            function(v) setXY(nil, v) end)
        return y2
    end

    function RC:ShowSidebarGeneralBehavior(frame)
        local parent = frame.scrollChild
        local yPos = -20

        -- the minimap button as it sits on the minimap (its own face,
        -- MinimapButton.lua), dimmed while it is switched off
        self.UI:DeclarePreview({
            key = "general.minimapbutton", title = RCL["Minimap button"],
            width = 60, height = 60,
            build = function(canvas, P)
                local MB = RC.MinimapButton
                if not (MB and MB.NewSample) then return end
                P.store.b = MB.NewSample(canvas)
                P.store.b:SetPoint("CENTER", canvas, "CENTER", -8, 8)
            end,
            update = function(canvas, P)
                local b = P.store.b
                if not b then return end
                local hidden = RC.db.minimapButton and RC.db.minimapButton.hide
                b:SetAlpha(hidden and 0.35 or 1)
                if RC.UI.PaintMark and b.icon then RC.UI:PaintMark(b.icon) end
                -- under the mouse: the minimap's own highlight, held on
                if P.mode == "hover" then b:LockHighlight() else b:UnlockHighlight() end
                -- the round border hangs 20px past the button: the box holds it
                P.Resize(60, 60)
            end,
            -- the mark's flip, as the mouse crossing the button plays it
            replay = function(canvas, P)
                local b = P.store.b
                if b and b._rcFlip and b:IsVisible() then b._rcFlip:Play() end
            end,
            modes = { { id = "rest", label = RCL["On the minimap"] }, { id = "hover", label = RCL["Mouse over"] } },
            modesLabel = RCL["Show"],
        })

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["General & Behavior"],
            RCL["Core addon settings and behavior"], "Interface\\Icons\\INV_Misc_Gear_01")
        yPos = newY

        -- Three plain switches, one card each: the reminders master switch,
        -- the minimap button and the world map stand-down.
        yPos = K.Card(parent, yPos, RCL["Addon control"], function(card, y)
            y = K.Check(card, y, RCL["Enable Addon"],
                function() return self.db.enabled end,
                function(v) self.db.enabled = v end,
                RCL["Master switch for ability reminder popups. Other features (Stats Bar, Trinket Manager, Gear Manager, bars, etc.) have their own toggles inside each panel."])
            return y
        end)

        yPos = K.Card(parent, yPos, RCL["Minimap button"], function(card, y)
            -- The button owns its saved state (SetVisible writes it).
            local function Shown() return not (self.db.minimapButton and self.db.minimapButton.hide) end
            local function SetShown(v)
                if self.MinimapButton and self.MinimapButton.SetVisible then self.MinimapButton:SetVisible(v) end
            end
            y = K.Check(card, y, RCL["Show minimap button"], Shown, SetShown,
                RCL["Show or hide the Readycheck button on the minimap. Right-click it for the full menu; middle-click opens the World Buffs board."])
            return y
        end)

        yPos = K.Card(parent, yPos, RCL["World map"], function(card, y)
            y = K.Check(card, y, RCL["Hide frames under the world map"],
                function() return self.db.hideUnderMap == true end,
                function(v)
                    self.db.hideUnderMap = v
                    if self.ApplyMapStandDown then self:ApplyMapStandDown() end
                end,
                RCL["While the world map is open, any Readycheck bar or reminder sitting under it fades out and comes back when the map closes. Frames clear of the map are left alone."])
            return y
        end)
        local cardY

        if not self.isWarrior then
            if not self.db.nonWarriorEnabled then self.db.nonWarriorEnabled = {} end
            local nwe = self.db.nonWarriorEnabled

            local classCard = self:CreateSettingsCard(parent, yPos, RCL["Class features"])
            cardY = -32

            local hint = self:CreateFontString(classCard, "OVERLAY", nil, 10)
            hint:SetPoint("TOPLEFT", classCard, "TOPLEFT", 14, cardY)
            hint:SetWidth(classCard:GetWidth() - 30)
            hint:SetText(RCL["Enable individual sidebar sections. Most of these were designed around warrior abilities and gear but some (Stats Bar, Chronoboon Reminder, Battle Shout Reminder, Spec Detection) work for any class."])
            hint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            hint:SetJustifyH("LEFT")
            cardY = cardY - hint:GetStringHeight() - 10

            local warriorItems = {
                {id = "spec_detection", label = RCL["Spec Detection"]},
                {id = "stats_bar",      label = RCL["Character Stats Bar"]},
                {id = "speed_swaps",    label = RCL["On-Use Gear Swaps"]},
                {id = "battle_shout",   label = RCL["Battle Shout Reminder"]},
                {id = "boon_reminder",  label = RCL["Chronoboon Reminder"]},
                {id = "hotswap",        label = RCL["Hotswap Macros"]},
                {id = "mc",             label = RCL["Molten Core config"]},
                {id = "bwl",            label = RCL["Blackwing Lair config"]},
                {id = "aq40",           label = RCL["Temple of Ahn'Qiraj config"]},
                {id = "naxx",           label = RCL["Naxxramas config"]},
            }
            for _, wi in ipairs(warriorItems) do
                local cb = self.UI:CreateCheckbox(classCard, wi.label, nwe[wi.id] == true)
                cb:SetPoint("TOPLEFT", classCard, "TOPLEFT", 14, cardY)
                local itemId = wi.id
                cb:SetScript("OnClick", function()
                    nwe[itemId] = cb:GetChecked() and true or nil
                    self:ForceCheckboxUpdate(cb, nwe[itemId] == true)
                    self:SaveConfigurationToProfile()
                    if self.sidebarConfigFrame and self.BuildSidebar then
                        self:BuildSidebar(self.sidebarConfigFrame, false)
                    end
                end)
                self:RegisterCheckboxWithData(cb,
                    function() return nwe[itemId] == true end,
                    function(v) nwe[itemId] = v and true or nil end)
                cardY = cardY - 24
            end

            classCard:SetContentHeight(math.abs(cardY) + 5)
            yPos = yPos - classCard:GetHeight() - 15
        end

        -- Combat-only, click-through and early-warning live on the
        -- Reminders page (Reminder Settings > Behavior); this page keeps
        -- only the global switches.
        if self.isWarrior then
            local remHint = self:CreateFontString(parent, "OVERLAY", nil, 10)
            remHint:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
            remHint:SetWidth(parent:GetWidth() - 36)
            remHint:SetText(RCL["Reminder toggles live on the Reminders page."])
            local _hc = self:GetColor("text", "secondary")
            remHint:SetTextColor(_hc.r, _hc.g, _hc.b, _hc.a)
            remHint:SetJustifyH("LEFT")
            yPos = yPos - 20
        end

        if self.UpdateSidebarScrollbar then
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
        end
    end

    ------------------------------------------------------------------
    -- GROUP OVERVIEW PAGES. Clicking a group header in the sidebar opens
    -- its overview: a grid of tiles, one per page of the group the
    -- sidebar would show this character (class, loaded addons), built
    -- from RC.MenuStructure so a page registered later (World Tools,
    -- testing pages) gets a tile too.
    --
    -- A tile: icon, name, a one-line description, a status line read
    -- from the feature's own saved switch, and an Open button; the whole
    -- tile opens the page. Two optional controls:
    --   sidebar box  pages with a sidebarVisibleKey: db.sidebarNav[key]
    --                (false = hidden from the menu; the page still works)
    --   On/Off       spec.toggle {get, set}: only where set() does exactly
    --                what the page's own switch does
    --
    -- RC.OverviewTiles[pageId] = { desc = (or descFn = fn -> text),
    --   status = fn -> on, text,
    --   toggle = { get = fn, set = fn(on) } }. status returns on (true /
    -- false / nil) and an optional text (nil = "On"/"Off"). LoD addons
    -- add their own entries (Cons_Checker: the bars).
    ------------------------------------------------------------------
    local OT = RC.OverviewTiles or {}
    RC.OverviewTiles = OT

    local function Tbl(key) return RC.db and RC.db[key] end
    -- status for a plain "<root>.enabled" switch
    local function EnabledOf(key)
        return function()
            local t = Tbl(key)
            return (t and t.enabled) and true or false
        end
    end

    -- Settings
    OT.general_behavior = { desc = RCL["Master switch, minimap button and world map options."],
        status = function() return RC.db.enabled and true or false end,
        -- the page's "Enable Addon" box writes db.enabled and saves, nothing else
        toggle = {
            get = function() return RC.db.enabled and true or false end,
            set = function(on) RC.db.enabled = on; RC:SaveConfigurationToProfile() end,
        } }
    OT.reminder_settings = { desc = RCL["Sound, voice, animation and position for reminder popups."] }
    OT.font_settings     = { desc = RCL["Fonts, colors, textures and motion for the whole addon."] }
    OT.profile_export    = { desc = RCL["Back up, share or copy your settings as a text string."] }
    OT.profiler          = { desc = RCL["See which features use the most CPU and memory."] }
    OT.commands          = { desc = RCL["Every /rc slash command in one list."] }
    OT.changelog         = { desc = RCL["What changed in each version."] }

    -- Mesh Network
    OT.mesh_sync = { desc = RCL["Link your characters to share settings and world buffs."],
        status = function()
            local MS = RC.MeshSync
            if not (MS and MS.IsEnabled) then return nil end
            return MS:IsEnabled() and true or false
        end }
    OT.world_buffs     = { desc = RCL["See which of your characters have which world buffs."] }
    OT.remote_raid_cfg = { desc = RCL["Edit another character's raid setup over the mesh."] }

    -- World Tools
    OT.wt_pulltimers = { desc = RCL["Countdown bars and alerts before a world buff drops."],
        status = function()
            local WT = RC.WorldTools
            local s = WT and WT.Store and WT.Store()
            local ts = s and s.timerSettings
            if not ts then return nil end
            local bars, alerts = ts.pullTimerEnabled ~= false, ts.alertsEnabled ~= false
            return (bars or alerts), (bars and RCL["Bars on"] or RCL["Bars off"]) .. ", "
                .. (alerts and RCL["alerts on"] or RCL["alerts off"])
        end }
    OT.wt_automation  = { desc = RCL["Auto-accept summons, click through gossip, common turn-ins."] }
    OT.wt_buffnetwork = { desc = RCL["Share world buff timers with your guild."],
        -- off by default (WBT_Core SETTINGS_DEFAULTS.enabled = false)
        status = EnabledOf("worldBuffTimers") }

    -- Character
    OT.spec_detection = { desc = RCL["Auto-detect your spec from talents and show on raid entry."],
        status = function()
            local sd = Tbl("specDetection")
            return not (sd and sd.enabled == false)
        end,
        -- the page's "Enable spec detection" box writes this and saves
        toggle = {
            get = function() local sd = Tbl("specDetection") return not (sd and sd.enabled == false) end,
            set = function(on)
                if not RC.db.specDetection then RC.db.specDetection = {} end
                RC.db.specDetection.enabled = on
                RC:SaveConfigurationToProfile()
            end,
        } }
    OT.stats_bar      = { desc = RCL["In-game overlay showing AP, crit, hit and more."],
        status = function() return RC.db.showStatsBar and true or false end }
    OT.buff_pushoff   = { desc = RCL["Alerts when a buff is pushed off by the 32 buff limit."],
        status = EnabledOf("buffPushoffAlert") }
    OT.battle_shout   = { desc = RCL["Reminds you and tracks shout status for your party."],
        status = EnabledOf("battleShoutReminder") }
    OT.boon_reminder  = { desc = RCL["Alerts when world buffs are about to be lost."],
        status = EnabledOf("boonReminder") }

    -- Equipment & Gear
    OT.trinkets           = { desc = RCL["Automatic trinket rotation and swap logic."],
        status = EnabledOf("trinketSwap") }
    OT.gear_manager       = { desc = RCL["Gear sets and quick-swap macro generation."],
        -- the page reads and writes the live GearManager.enabled
        status = function()
            local GM = RC.GearManager
            if GM and GM.enabled ~= nil then return GM.enabled and true or false end
            local g = Tbl("gearManager")
            return (g and g.enabled) and true or false
        end }
    OT.speed_swaps        = { desc = RCL["On-use gear swaps back after its buff ends."],
        status = function() return RC.db.gearUseRevert ~= false end }
    OT.equipment_reminder = { desc = RCL["Reminders for weapon stones, oils and enchants."],
        status = EnabledOf("fastWeaponReminder") }
    OT.hotswap            = { desc = RCL["One-click macros to swap gear sets mid-fight."] }
    OT.trinket_bar        = { desc = RCL["On-use trinket cooldown and status display."],
        -- the overview's own switch since before the tiles: shows or hides
        -- the menu at once (the page hides from the sidebar while it is off)
        toggle = {
            get = function() local t = Tbl("trinketBar") return (t and t.enabled) and true or false end,
            set = function(on)
                if not RC.db.trinketBar then RC.db.trinketBar = {} end
                RC.db.trinketBar.enabled = on
                local TB = RC.trinketBar
                if on then
                    if TB and not TB.frame and RC.CreateTrinketBarFrame then RC:CreateTrinketBarFrame() end
                    if TB and TB.frame then
                        TB.stableStateReached = true
                        if RC.UpdateTrinketBarButtons then RC:UpdateTrinketBarButtons() end
                        -- respect the visibility mode (raids/city) instead of forcing Show()
                        if RC.UpdateTrinketBarVisibility then
                            RC:UpdateTrinketBarVisibility()
                        else
                            TB.frame:Show()
                        end
                    end
                elseif TB and TB.frame and not InCombatLockdown() then
                    TB.frame:Hide()
                end
                RC:SaveConfigurationToProfile()
            end,
        } }

    -- Bars (the three bar switches are added by Readycheck_Consumables)
    OT.consumables_checker = { desc = RCL["Pre-raid checklist for all your consumables."],
        status = EnabledOf("consumablesChecker") }

    -- Extras
    OT.nameplate_auras     = { desc = RCL["Sunder, Expose and other debuffs on enemy nameplates."],
        status = function()
            local NA = RC.nameplateAuras
            local c = (NA and NA.cfg and NA.cfg()) or Tbl("nameplateAuras")
            return (c and c.enabled) and true or false
        end }
    OT.custom_reminders    = { desc = RCL["Your own reminders with triggers and conditions."],
        status = function()
            local cr = Tbl("customReminders")
            local list = cr and cr.reminders
            if type(list) ~= "table" then return nil end
            local n = #list
            return n > 0, n == 1 and RCL["1 reminder"] or string_format(RCL["%d reminders"], n)
        end }
    OT.raid_buff_tracker   = { desc = RCL["Time left on your class buffs, on screen and spoken."],
        status = EnabledOf("raidBuffTracker") }
    OT.boss_debuff_tracker = { desc = RCL["Time left on the raid's debuffs on your target."],
        status = EnabledOf("bossDebuffTracker") }
    OT.smart_macros        = { desc = RCL["Macros that rewrite themselves for your target."],
        status = function()
            local list = Tbl("smartMacros")
            if type(list) ~= "table" then return nil end
            local on = 0
            for _, m in ipairs(list) do if type(m) == "table" and m.enabled then on = on + 1 end end
            if #list == 0 then return false, RCL["No macros yet"] end
            return on > 0, string_format(RCL["%d of %d on"], on, #list)
        end }
    OT.repair_reminder     = { desc = RCL["Reminds you to repair when durability is low."],
        status = EnabledOf("repairReminder") }

    -- Raid Configuration: the raid tiles read like the sidebar's raid rows
    -- (active profile as the description, boss/trash counts as the status)
    local function RaidTile(raidKey)
        return {
            descFn = function()
                local profileName = "Default"
                if RC.GetActiveRaidProfile then
                    local _, name = RC:GetActiveRaidProfile(raidKey)
                    profileName = name or "Default"
                end
                return RCL["Profile: "] .. profileName
            end,
            status = function()
                local bossCount, trashCount = RC:GetRaidConfigCounts(raidKey)
                if bossCount > 0 or trashCount > 0 then
                    return true, bossCount .. RCL[" Bosses  "] .. trashCount .. RCL[" Trash"]
                end
                return false, RCL["Not Configured"]
            end,
        }
    end
    OT.mc   = RaidTile("Molten Core")
    OT.bwl  = RaidTile("Blackwing Lair")
    OT.aq40 = RaidTile("Temple of Ahn'Qiraj")
    OT.naxx = RaidTile("Naxxramas")
    OT.boss_notes = { desc = RCL["Notes that show when you target a boss or trash pack."],
        status = EnabledOf("bossNotes") }

    -- Fight Analytics
    OT.execute     = { desc = RCL["Machine learning kill-time predictions from fight history."],
        status = function()
            local EC = RC.executeCalculator
            if not EC then return nil end
            local n = 0
            local data = EC.fightHistory and EC.fightHistory.data
            if type(data) == "table" then
                for _, list in pairs(data) do
                    if type(list) == "table" then n = n + #list end
                end
            end
            local collecting = not (EC.dataCollection and EC.dataCollection.disabled)
            local fights = n == 1 and RCL["1 fight recorded"] or string_format(RCL["%d fights recorded"], n)
            return collecting, (collecting and RCL["Recording"] or RCL["Paused"]) .. "  -  " .. fights
        end }
    OT.ttk_display = { desc = RCL["On-screen TTK overlay and timeline display."],
        status = EnabledOf("ttkDisplay") }

    -- Page header per group (title is the group's own name).
    local GROUP_HEADERS = {
        reminders   = { RCL["Popups, shout and boon, buff trackers and your own reminders"], "Interface\\Icons\\INV_Misc_Bell_01" },
        consumables = { RCL["Enable bars to show them in-game and in the sidebar"],      "Interface\\Icons\\INV_Potion_41" },
        equipment   = { RCL["Gear sets, trinkets, swaps and gear warnings"],             "Interface\\Icons\\INV_Chest_Plate16" },
        raids       = { RCL["Boss reminders and notes for each raid"],                   "Interface\\Icons\\Achievement_Boss_KelThuzad_01" },
        combat      = { RCL["Kill time predictions and display overlays"],               "Interface\\Icons\\Ability_Warrior_Savageblow" },
        world_tools = { RCL["Buff drop timers, automation and the timer network"],       "Interface\\Icons\\INV_Misc_PocketWatch_02" },
        mesh        = { RCL["Share settings and world buffs between your characters"],   "Interface\\Icons\\spell_nature_web" },
        character   = { RCL["Spec detection and the stats bar"],                         "Interface\\Icons\\Ability_Warrior_Rampage" },
        extras      = { RCL["Nameplate debuffs and smart macros"],                       "Interface\\Icons\\INV_Misc_Bomb_04" },
        home        = { RCL["Core options, appearance, profiles and help"],              "Interface\\Icons\\INV_Misc_Gear_01" },
    }

    local TILE_H, TILE_GAP, TILE_MIN_W = 92, 10, 230

    local function FindCategory(catId)
        for _, cat in ipairs(RC.MenuStructure or {}) do
            if cat.id == catId then return cat end
        end
    end

    -- The sidebar's own rule minus the two per-page switches: a page
    -- hidden from the menu (or a bar switched off) still gets its tile,
    -- because this is where it is switched back on.
    local function TileVisible(self, item)
        if not self.SidebarItemVisible then return true end
        local probe = {}
        for k, v in pairs(item) do probe[k] = v end
        probe.sidebarVisibleKey, probe.enabledKey = nil, nil
        return self:SidebarItemVisible(probe)
    end

    -- on, text for a tile; text nil = "On"/"Off" (nothing when on is nil)
    local function ReadStatus(spec)
        if not (spec and spec.status) then return nil, nil end
        local okS, on, text = pcall(spec.status)
        if not okS then
            RC:DebugPrint("Overview status failed: " .. tostring(on), "config")
            return nil, nil
        end
        if text == nil and on ~= nil then text = on and RCL["On"] or RCL["Off"] end
        return on, text
    end

    local function StatusColor(on)
        if on == true then return RC:GetColor("text", "green") end
        if on == false then return RC:GetColor("text", "gray") end
        return RC:GetColor("text", "secondary")
    end

    local function BuildTile(self, grid, item, cat, frame, catId)
        local outer = self.sidebarConfigFrame
        local spec = OT[item.id] or {}

        local tile = self:CreateSettingsCard(grid, 0, nil)
        tile:ClearAllPoints()
        tile.bg = tile.bgTexture   -- AttachHover paints .bg
        tile.menuItem = item
        tile._rcOverviewTile = item.id
        tile:EnableMouse(true)

        local iconBox = CreateFrame("Frame", nil, tile)
        iconBox:SetSize(34, 34)
        iconBox:SetPoint("TOPLEFT", tile, "TOPLEFT", 14, -12)
        local icon = iconBox:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", iconBox, "TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", iconBox, "BOTTOMRIGHT", -1, 1)
        icon:SetTexture(item.icon or 134400)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        iconBox.border = self.UI:CreateSimpleBorder(iconBox, 1)
        self.UI:UpdateBorderColor(iconBox.border, self:GetColor("ui", "borderNormal"), 1)
        function iconBox:Repaint()
            RC.UI:UpdateBorderColor(self.border, RC:GetColor("ui", "borderNormal"), 1)
        end
        tile.icon = icon

        -- sidebar box, top-right corner
        local navKey = item.sidebarVisibleKey
        local navBox
        if navKey then
            if not RC.db.sidebarNav then RC.db.sidebarNav = {} end
            navBox = self.UI:CreateCheckbox(tile, "", RC.db.sidebarNav[navKey] ~= false)
            navBox.parentFrame:SetSize(14, 14)
            navBox.parentFrame:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -12, -12)
            navBox:SetHitRectInsets(-4, -4, -4, -4)
            navBox:SetScript("OnClick", function(box)
                local on = box:GetChecked() and true or false
                if not RC.db.sidebarNav then RC.db.sidebarNav = {} end
                RC.db.sidebarNav[navKey] = on
                RC:ForceCheckboxUpdate(box, on)
                RC:SaveConfigurationToProfile()
                if outer and RC.BuildSidebar then RC:BuildSidebar(outer, false) end
            end)
            navBox:HookScript("OnEnter", function(box)
                GameTooltip:SetOwner(box, "ANCHOR_RIGHT")
                local w = RC:GetColor("text", "white")
                GameTooltip:SetText(RCL["Show in sidebar"], w.r, w.g, w.b)
                local g = RC:GetColor("text", "gray")
                GameTooltip:AddLine(RCL["Untick to hide this page from the sidebar menu. It keeps working and stays here."], g.r, g.g, g.b, true)
                GameTooltip:Show()
            end)
            navBox:HookScript("OnLeave", function() GameTooltip:Hide() end)
            tile.navBox = navBox
        end

        local name = self:CreateFontString(tile, "OVERLAY", nil, 13)
        name:SetPoint("TOPLEFT", iconBox, "TOPRIGHT", 10, -1)
        name:SetPoint("RIGHT", tile, "RIGHT", navBox and -34 or -12, 0)
        name:SetJustifyH("LEFT")
        name:SetWordWrap(false)
        name:SetText(item.name or "")
        tile.nameText = name

        local desc = self:CreateFontString(tile, "OVERLAY", nil, 10)
        desc:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -4)
        desc:SetPoint("RIGHT", tile, "RIGHT", -12, 0)
        desc:SetJustifyH("LEFT")
        desc:SetJustifyV("TOP")
        desc:SetWordWrap(true)
        desc:SetMaxLines(2)
        local descText = spec.desc
        if spec.descFn then
            local okD, d = pcall(spec.descFn)
            descText = okD and d or nil
        end
        desc:SetText(descText or "")
        tile.descText = desc

        local function Open() self:SelectSidebarItem(outer, item, cat) end

        local openBtn = self.UI:CreateStyledButton(tile, RCL["Open"], 54, 20)
        openBtn:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -10, 10)
        openBtn:SetScript("OnClick", Open)
        tile.openBtn = openBtn

        local function Rebuild()
            if RC.UI.NotifySettingChanged then RC.UI:NotifySettingChanged("toggle") end
            if outer and RC.BuildSidebar then RC:BuildSidebar(outer, false) end
            RC:ShowSidebarGroupOverview(frame, catId, true)
        end

        local on, text = ReadStatus(spec)
        local rightOf = openBtn
        if spec.toggle then
            local isOn = spec.toggle.get() and true or false
            local sw = self.UI:CreateStyledButton(tile, isOn and RCL["On"] or RCL["Off"], 40, 20)
            sw:SetPoint("RIGHT", openBtn, "LEFT", -6, 0)
            -- green configured look = on; plain = off
            sw:SetActive(isOn)
            sw:SetScript("OnClick", function()
                spec.toggle.set(not (spec.toggle.get() and true or false))
                Rebuild()
            end)
            tile.switch = sw
            tile.switchOn = isOn
            rightOf = sw
            -- the switch shows on/off; the line keeps only extra facts
            if spec.status and text == (on and RCL["On"] or RCL["Off"]) then text = nil end
            if on == nil then on = isOn end
        end

        local status = self:CreateFontString(tile, "OVERLAY", nil, 10)
        status:SetPoint("LEFT", tile, "BOTTOMLEFT", 14, 20)
        status:SetPoint("RIGHT", rightOf, "LEFT", -8, 0)
        status:SetJustifyH("LEFT")
        status:SetWordWrap(false)
        status:SetText(text or "")
        if not text then status:Hide() end
        tile.statusText = status
        tile.statusOn = on

        local function Paint(t)
            local tc = RC:GetColor("text", "gold")
            t.nameText:SetTextColor(tc.r, tc.g, tc.b)
            local gc = RC:GetColor("text", "gray")
            t.descText:SetTextColor(gc.r, gc.g, gc.b)
            local sc = StatusColor(t.statusOn)
            t.statusText:SetTextColor(sc.r, sc.g, sc.b)
        end
        Paint(tile)

        local function HoverRing(t, hot)
            if hot then
                RC.UI:UpdateBorderColor(t.border, RC:GetColor("ui", "borderHover"), 1)
            else
                RC.UI:UpdateBorderColor(t.border, RC:GetColor("ui", "borderNormal"), 0.55)
            end
        end
        self.UI:AttachHover(tile, self:GetColor("ui", "cardBackground"), self:GetColor("buttons", "hoverBackground"), {
            onEnter = function(t) HoverRing(t, true) end,
            onLeave = function(t)
                -- moving onto the tile's own buttons keeps the tile lit
                if t:IsMouseOver() then
                    local hc = t.hoverBg
                    t.bg:SetVertexColor(hc.r, hc.g, hc.b, hc.a or 1)
                    return
                end
                HoverRing(t, false)
            end,
        })
        -- a tile is a fixed size: a long name, description or status line
        -- is cut short in it and shows whole on hover
        self.UI:TruncTip(name, tile)
        self.UI:TruncTip(desc, tile)
        self.UI:TruncTip(status, tile)
        -- leaving one of the tile's own controls for outside the tile
        -- never reaches the tile's OnLeave, so they pass it on
        local function PassLeave()
            if not tile:IsMouseOver() then
                local fn = tile:GetScript("OnLeave")
                if fn then fn(tile) end
            end
        end
        openBtn:HookScript("OnLeave", PassLeave)
        if tile.switch then tile.switch:HookScript("OnLeave", PassLeave) end
        if navBox then navBox:HookScript("OnLeave", PassLeave) end
        tile:SetScript("OnMouseUp", function(_, button)
            if button == nil or button == "LeftButton" then Open() end
        end)

        local cardRepaint = tile.Repaint
        function tile:Repaint()
            cardRepaint(self)
            self.normBg = RC:GetColor("ui", "cardBackground")
            self.hoverBg = RC:GetColor("buttons", "hoverBackground")
            Paint(self)
        end

        return tile
    end

    -- The shared builder behind every group overview page. No preview:
    -- these pages draw no feature, so the window stays narrow.
    function RC:ShowSidebarGroupOverview(frame, catId, preserveScroll)
        local outer = self.sidebarConfigFrame
        self:ClearSidebarContent(outer, preserveScroll)
        local parent = frame.scrollChild
        local cat = FindCategory(catId)
        if not (parent and cat) then return end

        local head = GROUP_HEADERS[catId] or {}
        local yPos = -20
        local _, newY = self:CreateSettingsPageHeader(parent, yPos, cat.name, head[1], head[2] or cat.icon)
        yPos = newY

        local items, anyNav, anyGated = {}, false, false
        for _, child in ipairs(cat.children or {}) do
            if TileVisible(self, child) then
                items[#items + 1] = child
                if child.sidebarVisibleKey then anyNav = true end
                if child.enabledKey then anyGated = true end
            end
        end

        if anyNav or anyGated then
            local hint = self:CreateFontString(parent, "OVERLAY", nil, 10)
            hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos + 4)
            hint:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
            hint:SetJustifyH("LEFT")
            hint:SetText(anyNav and RCL["Hidden pages still work; turn them back on here."]
                or RCL["Switched-off bars are hidden from the sidebar; turn them on here."])
            local hc = self:GetColor("text", "gray")
            hint:SetTextColor(hc.r, hc.g, hc.b)
            function hint:Repaint()
                local c = RC:GetColor("text", "gray")
                self:SetTextColor(c.r, c.g, c.b)
            end
            yPos = yPos - 20
        end

        local grid = CreateFrame("Frame", nil, parent)
        grid:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
        grid:SetPoint("RIGHT", parent, "RIGHT", -18, 0)
        grid._rcOverviewGrid = catId
        grid.tiles = {}
        for i, child in ipairs(items) do
            grid.tiles[i] = BuildTile(self, grid, child, cat, frame, catId)
        end

        -- 2 columns, 1 when the page is narrow; re-run on resize
        function grid:Layout(w)
            if not w or w < 50 then w = self:GetWidth() end
            if not w or w < 50 then w = (parent:GetWidth() or 0) - 36 end
            if w < 50 then w = TILE_MIN_W end
            local cols = (w >= TILE_MIN_W * 2 + TILE_GAP) and 2 or 1
            local tileW = math_floor((w - (cols - 1) * TILE_GAP) / cols)
            for i, tile in ipairs(self.tiles) do
                local col = (i - 1) % cols
                local row = math_floor((i - 1) / cols)
                tile:ClearAllPoints()
                tile:SetPoint("TOPLEFT", self, "TOPLEFT", col * (tileW + TILE_GAP), -row * (TILE_H + TILE_GAP))
                tile:SetSize(tileW, TILE_H)
            end
            local rows = math_ceil(#self.tiles / cols)
            local h = math_max(1, rows * (TILE_H + TILE_GAP) - TILE_GAP)
            self.cols, self.tileW, self.laidW = cols, tileW, w
            self:SetHeight(h)
            return h
        end
        grid:SetScript("OnSizeChanged", function(g, w)
            if w and w >= 50 and math.abs(w - (g.laidW or 0)) > 1 then g:Layout(w) end
        end)
        local h = grid:Layout()

        self:UpdateSidebarScrollbar(outer, math.abs(yPos) + h + 10)
        if preserveScroll then self:RestoreScrollPosition(outer) end
    end

    function RC:ShowSidebarSettingsOverview(frame)       self:ShowSidebarGroupOverview(frame, "home") end
    function RC:ShowSidebarMeshOverview(frame)           self:ShowSidebarGroupOverview(frame, "mesh") end
    function RC:ShowSidebarWorldToolsOverview(frame)     self:ShowSidebarGroupOverview(frame, "world_tools") end
    function RC:ShowSidebarCharacterOverview(frame)      self:ShowSidebarGroupOverview(frame, "character") end
    function RC:ShowSidebarEquipmentOverview(frame)      self:ShowSidebarGroupOverview(frame, "equipment") end
    function RC:ShowSidebarRemindersOverview(frame)      self:ShowSidebarGroupOverview(frame, "reminders") end
    function RC:ShowSidebarExtrasOverview(frame)         self:ShowSidebarGroupOverview(frame, "extras") end
    function RC:ShowSidebarRaidsOverview(frame)          self:ShowSidebarGroupOverview(frame, "raids") end
    function RC:ShowSidebarFightAnalyticsOverview(frame) self:ShowSidebarGroupOverview(frame, "combat") end

    -- SPEC POPUP PREVIEW: the real popup (NewSpecDisplayFrame +
    -- StyleSpecDisplay + FillSpecDisplay) with sample talents per spec.
    local I = "Interface\\Icons\\"
    local SPEC_SAMPLE_TALENTS = {
        fury = {
            { icon = I .. "Spell_Nature_BloodLust", rank = 1, maxRank = 1 },
            { icon = I .. "Ability_GhoulFrenzy", rank = 5, maxRank = 5 },
            { icon = I .. "Spell_Shadow_DeathPact", rank = 1, maxRank = 1 },
            { icon = I .. "INV_Sword_48", rank = 2, maxRank = 2 },
            { icon = I .. "Ability_Warrior_BattleShout", rank = 5, maxRank = 5 },
            { icon = I .. "Ability_Warrior_Cleave", rank = 3, maxRank = 3 },
            { icon = I .. "Ability_DualWield", rank = 5, maxRank = 5 },
            { icon = I .. "Ability_Rogue_Eviscerate", rank = 5, maxRank = 5 },
            { icon = I .. "Spell_Shadow_UnholyFrenzy", rank = 5, maxRank = 5 },
        },
        arms = {
            { icon = I .. "Ability_Warrior_SavageBlow", rank = 1, maxRank = 1 },
            { icon = I .. "Ability_Rogue_SliceDice", rank = 1, maxRank = 1 },
            { icon = I .. "Ability_BackStab", rank = 3, maxRank = 3 },
            { icon = I .. "Ability_SearingArrow", rank = 2, maxRank = 2 },
            { icon = I .. "INV_Sword_27", rank = 5, maxRank = 5 },
            { icon = I .. "Spell_Nature_EnchantArmor", rank = 5, maxRank = 5 },
        },
        prot = {
            { icon = I .. "INV_Shield_05", rank = 1, maxRank = 1 },
            { icon = I .. "Spell_Holy_AshesToAshes", rank = 1, maxRank = 1 },
            { icon = I .. "Spell_Nature_Reincarnation", rank = 5, maxRank = 5 },
            { icon = I .. "Ability_Defend", rank = 3, maxRank = 3 },
            { icon = I .. "Ability_ThunderBolt", rank = 1, maxRank = 1 },
        },
    }
    -- the popup at its default look (320 x 122 with a row of talents);
    -- update sizes the canvas to the popup
    local SP_W, SP_H = 324, 126

    local function SpecLook() return K.Look(RC.db.specDetection, "look") end

    local function SpecPreviewBuild(canvas, P)
        if not RC.NewSpecDisplayFrame then return end
        P.store.frame = RC:NewSpecDisplayFrame(canvas)
        P.store.token = 0
    end
    local function SpecPreviewUpdate(canvas, P)
        local f = P.store.frame
        if not (f and RC.specDetection and RC.specDetection.specs) then return end
        local key = P.mode or "fury"
        local data = RC.specDetection.specs[key] or RC.specDetection.specs.fury
        local sd = RC.db.specDetection or {}
        local talents
        if sd.showTalents ~= false and (sd.maxTalentsShown or 8) > 0 then
            talents = {}
            for i, t in ipairs(SPEC_SAMPLE_TALENTS[key] or SPEC_SAMPLE_TALENTS.fury) do
                if i > (sd.maxTalentsShown or 8) then break end
                talents[i] = t
            end
        end
        RC.Motion.Stop(f)
        RC:StyleSpecDisplay(f)
        RC:FillSpecDisplay(f, data, key, talents)
        -- the canvas is the popup's box as drawn in game, its own scale
        -- included (the strip shows it at real size)
        local sc = f:GetScale() or 1
        local w, h = f:GetWidth() or 320, f:GetHeight() or 120
        P.Resize(w * sc + 4, h * sc + 4)
        f:ClearAllPoints()
        f:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        f:Show()
    end
    -- the popup's own sequence, with a short hold
    local function SpecPreviewReplay(canvas, P)
        local f = P.store.frame
        if not f then return end
        local M = RC.Motion
        P.store.token = P.store.token + 1
        local t = P.store.token
        M.Stop(f)
        f:Hide()
        local inSpec = M.Normalize(SpecLook().showAnim, RC.SPEC_POPUP_SHOW)
        M.Show(f, inSpec)
        local hold = M.Duration(inSpec.duration) + M.Duration(inSpec.delay or 0) + 1.2
        C_Timer.After(hold, function()
            if t ~= P.store.token or not f:IsVisible() then return end
            local outSpec = M.Normalize(SpecLook().hideAnim, RC.SPEC_POPUP_HIDE)
            M.Hide(f, outSpec)
            C_Timer.After(M.Duration(outSpec.duration) + M.Duration(outSpec.delay or 0) + 0.4, function()
                if t ~= P.store.token then return end
                M.Stop(f)
                if canvas:IsVisible() then f:Show() end
            end)
        end)
    end

    -- old tab keys (and the search aliases) land on the new tabs
    local SPEC_TAB_ALIAS = { overview = "behavior", settings = "behavior" }

    function RC:ShowSidebarSpecDetection(frame, preserveScroll)
        local cardY
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)

        local parent = frame.scrollChild
        local yPos = -20

        if not self.db.specDetection then
            self.db.specDetection = {}
        end
        local sd = self.db.specDetection
        if sd.enabled == nil then sd.enabled = true end
        if sd.showTalents == nil then sd.showTalents = true end
        if sd.displayDuration == nil then sd.displayDuration = 4 end
        if sd.playSound == nil then sd.playSound = false end
        if sd.showOnRaidEntry == nil then sd.showOnRaidEntry = true end
        if sd.maxTalentsShown == nil then sd.maxTalentsShown = 8 end

        local spec = self:DetectWarriorSpec()
        local P = self.UI:DeclarePreview({
            key = "spec.popup", title = RCL["Spec popup"],
            width = SP_W, height = SP_H,
            build = SpecPreviewBuild, update = SpecPreviewUpdate, replay = SpecPreviewReplay,
            modes = { { id = "fury", label = RCL["Fury"] }, { id = "arms", label = RCL["Arms"] },
                      { id = "prot", label = RCL["Protection"] } },
        })

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Spec Detection"],
            RCL["Configure spec detection display on raid entry"], "Interface\\Icons\\Ability_Warrior_Rampage")
        yPos = newY

        local tabKey = RC.specDetectionTab or "behavior"
        tabKey = SPEC_TAB_ALIAS[tabKey] or tabKey
        RC.specDetectionTab = tabKey
        yPos = K.Tabs(parent, yPos, {
            { "behavior", RCL["Behavior"] }, { "talents", RCL["Talents"] }, { "look", RCL["Look"] },
            { "text", RCL["Text"] }, { "animation", RCL["Animation"] }, { "sound", RCL["Sound"] },
            { "position", RCL["Position"] },
        }, tabKey, function(k)
            RC.specDetectionTab = k
            RC:ShowSidebarSpecDetection(frame, true)
        end)

        local specData = self.specDetection and self.specDetection.specs and self.specDetection.specs[spec]

        if RC.specDetectionTab == "behavior" then
        local currentCard = self:CreateSettingsCard(parent, yPos, RCL["Current spec"])
        local cardY = -32

        if specData then
            local specIcon = currentCard:CreateTexture(nil, "ARTWORK")
            specIcon:SetSize(48, 48)
            specIcon:SetPoint("TOPLEFT", currentCard, "TOPLEFT", 14, cardY)
            specIcon:SetTexture(specData.icon)
            specIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            local specName = self:CreateFontString(currentCard, "OVERLAY", nil, 16)
            specName:SetPoint("LEFT", specIcon, "RIGHT", 12, 8)
            specName:SetText(specData.name)
            local specColor = specData.colorKey and self:GetColor(specData.colorKey[1], specData.colorKey[2])
            if specColor then
                specName:SetTextColor(specColor.r, specColor.g, specColor.b)
            else
                local ac = self:GetColor("ui", "accentGold")
                specName:SetTextColor(ac.r, ac.g, ac.b)
            end

            local armsTalents, furyTalents, protTalents = 0, 0, 0
            for tab = 1, ((GetNumTalentTabs and GetNumTalents and GetTalentInfo) and GetNumTalentTabs() or 0) do
                for talent = 1, GetNumTalents(tab) do
                    local name, _, _, _, rank = GetTalentInfo(tab, talent)
                    if name and rank and rank > 0 then
                        if tab == 1 then armsTalents = armsTalents + rank
                        elseif tab == 2 then furyTalents = furyTalents + rank
                        elseif tab == 3 then protTalents = protTalents + rank
                        end
                    end
                end
            end

            local talentDist = self:CreateFontString(currentCard, "OVERLAY", nil, 11)
            talentDist:SetPoint("LEFT", specIcon, "RIGHT", 12, -10)
            talentDist:SetText(string.format(RCL["Arms %d / Fury %d / Prot %d"], armsTalents, furyTalents, protTalents))
            local _c = self:GetColor("text", "gray"); talentDist:SetTextColor(_c.r, _c.g, _c.b, _c.a)

            cardY = cardY - 60
        else
            local noSpec = self:CreateFontString(currentCard, "OVERLAY", nil, 12)
            noSpec:SetPoint("TOPLEFT", currentCard, "TOPLEFT", 14, cardY)
            noSpec:SetText(RCL["No spec detected"])
            local _c = self:GetColor("text", "gray"); noSpec:SetTextColor(_c.r, _c.g, _c.b, _c.a)
            cardY = cardY - 30
        end

        local testBtn = self.UI:CreateStyledButton(currentCard, RCL["Test Display"], 100, 26)
        testBtn:SetPoint("TOPLEFT", currentCard, "TOPLEFT", 14, cardY)
        testBtn:SetScript("OnClick", function()
            RC:ShowSpecDisplay(spec)
        end)
        cardY = cardY - 40

        currentCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - currentCard:GetHeight() - 15

        local specOnCb, talentsCb
        yPos = K.Card(parent, yPos, RCL["Display"], function(card, y)
            y, specOnCb = K.Check(card, y, RCL["Enable spec detection"], function() return sd.enabled ~= false end,
                function(v) sd.enabled = v end)
            local mark = self.UI:MarkCard(card)
            y = K.Check(card, y, RCL["Show on raid entry"], function() return sd.showOnRaidEntry ~= false end,
                function(v) sd.showOnRaidEntry = v end,
                RCL["Automatically show spec popup when entering a raid"])
            y, talentsCb = K.Check(card, y, RCL["Show talent summary"], function() return sd.showTalents ~= false end,
                function(v) sd.showTalents = v end,
                RCL["Show key talents below spec name in popup"])
            self.UI:BindDependents(specOnCb, self.UI:CardSince(card, mark))
            return y
        end)

        yPos = K.Card(parent, yPos, RCL["Timing & limits"], function(card, y)
            local mark = self.UI:MarkCard(card)
            y = K.Slider(card, y, RCL["Display Duration"], 1, 10, sd.displayDuration or 4, 0.5,
                function(v) return string.format(RCL["%.1f seconds"], v) end,
                function(v) sd.displayDuration = v RC:SaveConfigurationToProfile() end, 10)
            y = K.Desc(card, y + 6, RCL["How long the popup stays between its entrance and its exit."])
            local talentMark = self.UI:MarkCard(card)
            y = K.Slider(card, y, RCL["Max Talents Shown"], 0, 12, sd.maxTalentsShown or 8, 1,
                function(v) return v .. RCL[" talents"] end,
                function(v) sd.maxTalentsShown = v RC:SaveConfigurationToProfile() end)
            -- the talent count only matters with the summary shown; the
            -- whole card only with detection on (greyed, not set in: it is
            -- its own card)
            if talentsCb then self.UI:BindDependents(talentsCb, self.UI:CardSince(card, talentMark), { indent = 0 }) end
            if specOnCb then self.UI:BindDependents(specOnCb, self.UI:CardSince(card, mark), { indent = 0 }) end
            return y
        end)

        elseif RC.specDetectionTab == "talents" then
        if self.specDetection then
            self.specDetection.talentsDirty = true
        end
        spec = self:DetectWarriorSpec()
        if self.specDetection and self.specDetection.keyTalents and spec then
            if not sd.hiddenTalents then
                sd.hiddenTalents = {}
            end

            local talentCard = self:CreateSettingsCard(parent, yPos, RCL["Talent visibility & order"])
            cardY = -32

            if not sd.talentOrder then
                sd.talentOrder = {}
            end

            local editModeActive = self.specDetectionEditMode or false

            local editBtn = self.UI:CreateStyledButton(talentCard, editModeActive and RCL["Done Editing"] or RCL["Edit Order"], 90, 22)
            editBtn:SetPoint("TOPRIGHT", talentCard, "TOPRIGHT", -14, -8)
            editBtn:SetScript("OnClick", function()
                self.specDetectionEditMode = not self.specDetectionEditMode
                self:ShowSidebarSpecDetection(frame, true)
            end)

            local visDesc = self:CreateFontString(talentCard, "OVERLAY", nil, 10)
            visDesc:SetPoint("TOPLEFT", talentCard, "TOPLEFT", 14, cardY)
            visDesc:SetPoint("RIGHT", editBtn, "LEFT", -10, 0)
            visDesc:SetJustifyH("LEFT")
            if editModeActive then
                visDesc:SetText(RCL["Drag talents to reorder priority. Top = shown first."])
                local _c = self:GetColor("text", "blue"); visDesc:SetTextColor(_c.r, _c.g, _c.b, _c.a)
            else
                visDesc:SetText(RCL["Uncheck talents to hide. Grayed = not learned."])
                visDesc:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            end
            cardY = cardY - 28

            local specSearchText = RC._specDetectionSearch or ""
            local specSearchBox = self.UI:CreateSearchBox(talentCard, {
                placeholder = RCL["Search talents..."],
                initialText = specSearchText,
                onChange = function(txt)
                    RC._specDetectionSearch = txt
                    RC._specDetectionSearchFocus = true
                    if RC._specDetectionSearchTimer then RC._specDetectionSearchTimer:Cancel() end
                    RC._specDetectionSearchTimer = C_Timer.NewTimer(0.6, function()
                        RC._specDetectionSearchTimer = nil
                        if not (RC.sidebarConfigFrame and RC.sidebarConfigFrame:IsVisible()) then RC._specDetectionSearchFocus = nil; return end
                        if RC.SidebarState and RC.SidebarState.currentPanel ~= "spec_detection" then RC._specDetectionSearchFocus = nil; return end
                        if not (RC._specDetectionSearchBox and RC._specDetectionSearchBox.editBox and RC._specDetectionSearchBox.editBox:HasFocus()) then RC._specDetectionSearchFocus = nil end
                        RC:ShowSidebarSpecDetection(frame, true)
                    end)
                end,
            })
            specSearchBox:SetPoint("TOPLEFT", talentCard, "TOPLEFT", 14, cardY)
            specSearchBox:SetPoint("TOPRIGHT", talentCard, "TOPRIGHT", -14, cardY)
            RC._specDetectionSearchBox = specSearchBox
            cardY = cardY - 32
            if RC._specDetectionSearchFocus then
                RC._specDetectionSearchFocus = false
                local function _refocus()
                    local eb = specSearchBox and specSearchBox.editBox
                    if eb and eb:IsVisible() then eb:SetFocus(); eb:SetCursorPosition(#(eb:GetText() or "")) end
                end
                _refocus()
                C_Timer.After(0, _refocus)
            end
            local specSearchQ = specSearchText:lower()

            local defaultTalents = {}
            if spec == "fury" then
                defaultTalents = {
                    "Bloodthirst", "Flurry", "Death Wish", "Improved Execute",
                    "Improved Battle Shout", "Improved Cleave", "Dual Wield Specialization",
                    "Cruelty", "Enrage", "Improved Intercept", "Unbridled Wrath", "Improved Demoralizing Shout",
                    "Improved Berserker Rage", "Piercing Howl", "Improved Slam",
                    "Sweeping Strikes", "Deep Wounds", "Impale", "Tactical Mastery",
                    "Improved Heroic Strike", "Deflection", "Anger Management", "Improved Overpower",
                    "Defiance", "Improved Shield Block", "Last Stand", "Toughness",
                    "Improved Bloodrage", "Shield Specialization"
                }
            elseif spec == "furyProt" then
                defaultTalents = {
                    "Bloodthirst", "Flurry", "Death Wish", "Cruelty", "Enrage",
                    "Improved Heroic Strike", "Improved Cleave", "Unbridled Wrath",
                    "Defiance", "Improved Shield Block", "Last Stand", "Shield Slam",
                    "Improved Taunt", "Improved Demoralizing Shout", "One-Handed Weapon Specialization", "Improved Sunder Armor",
                    "Improved Bloodrage", "Shield Specialization", "Toughness",
                    "Concussion Blow", "Improved Revenge", "Iron Will",
                    "Tactical Mastery", "Anger Management", "Deep Wounds", "Impale", "Improved Overpower"
                }
            elseif spec == "arms" then
                defaultTalents = {
                    "Mortal Strike", "Sweeping Strikes", "Deep Wounds", "Impale",
                    "Sword Specialization", "Axe Specialization", "Mace Specialization",
                    "Two-Handed Weapon Specialization", "Tactical Mastery", "Improved Overpower",
                    "Anger Management", "Improved Heroic Strike", "Deflection", "Improved Charge",
                    "Improved Hamstring", "Polearm Specialization",
                    "Cruelty", "Improved Demoralizing Shout", "Unbridled Wrath", "Improved Battle Shout", "Enrage",
                    "Flurry", "Death Wish", "Improved Execute",
                    "Defiance", "Improved Shield Block", "Last Stand", "Toughness",
                    "Improved Bloodrage"
                }
            elseif spec == "prot" then
                defaultTalents = {
                    "Shield Slam", "Last Stand", "Defiance", "Improved Shield Block",
                    "Concussion Blow", "One-Handed Weapon Specialization", "Improved Taunt", "Improved Demoralizing Shout",
                    "Improved Revenge", "Improved Sunder Armor", "Toughness",
                    "Shield Specialization", "Improved Bloodrage", "Iron Will",
                    "Improved Shield Bash", "Improved Disarm",
                    "Tactical Mastery", "Anger Management", "Deflection", "Improved Heroic Strike",
                    "Deep Wounds", "Impale", "Improved Overpower",
                    "Cruelty", "Unbridled Wrath", "Improved Cleave", "Piercing Howl"
                }
            else
                local detected = self.specDetection and self.specDetection.detectedTalents or {}
                local collected = {}
                for tname, tdata in pairs(detected) do
                    table.insert(collected, { name = tname, tab = tdata.tab or 0, rank = tdata.rank or 0 })
                end
                table.sort(collected, function(a, b)
                    if a.tab ~= b.tab then return a.tab < b.tab end
                    if a.rank ~= b.rank then return a.rank > b.rank end
                    return a.name < b.name
                end)
                for _, entry in ipairs(collected) do
                    table.insert(defaultTalents, entry.name)
                end
            end

            local priorityTalents = sd.talentOrder[spec] or defaultTalents

            if #priorityTalents == 0 then
                priorityTalents = {}
                local detectedNow = self.specDetection and self.specDetection.detectedTalents or {}
                local tmp = {}
                for tname, tdata in pairs(detectedNow) do
                    table.insert(tmp, { name = tname, tab = tdata.tab or 0, rank = tdata.rank or 0 })
                end
                table.sort(tmp, function(a, b)
                    if a.tab ~= b.tab then return a.tab < b.tab end
                    if a.rank ~= b.rank then return a.rank > b.rank end
                    return a.name < b.name
                end)
                for _, entry in ipairs(tmp) do
                    table.insert(priorityTalents, entry.name)
                end
            end

            local talentSet = {}
            for _, t in ipairs(priorityTalents) do
                talentSet[t] = true
            end
            for _, t in ipairs(defaultTalents) do
                if not talentSet[t] then
                    table.insert(priorityTalents, t)
                end
            end

            local detected = self.specDetection.detectedTalents or {}
            local keyTalents = self.specDetection.keyTalents
            local talentRows = {}
            local talentCount = 0

            if not self.specDetectionDrag then
                self.specDetectionDrag = {}
            end

            local insertIndicator = talentCard:CreateTexture(nil, "OVERLAY")
            insertIndicator:SetHeight(2)
            do local _il=RC:GetColor("ui","insertionLine"); insertIndicator:SetColorTexture(_il.r,_il.g,_il.b,_il.a or 1) end
            insertIndicator:Hide()
            self.specDetectionDrag.indicator = insertIndicator

            for i, talentName in ipairs(priorityTalents) do
                local keyData = keyTalents[talentName]
                if not keyData then
                    local d = detected[talentName]
                    if d then
                        keyData = {
                            tab       = d.tab,
                            abbrev    = d.abbrev or talentName,
                            important = d.important,
                        }
                    end
                end
                if keyData and (specSearchQ == "" or (talentName and talentName:lower():find(specSearchQ, 1, true))) then
                    local isLearned = detected[talentName] ~= nil
                    local data = detected[talentName]
                    local isHidden = sd.hiddenTalents[talentName]

                    local talentRow = CreateFrame("Frame", nil, talentCard)
                    talentRow:SetHeight(24)
                    talentRow:SetPoint("TOPLEFT", talentCard, "TOPLEFT", 14, cardY)
                    talentRow:SetPoint("RIGHT", talentCard, "RIGHT", -14, 0)
                    talentRow.talentName = talentName
                    talentRow.index = i

                    local xOffset = 0

                    if editModeActive and specSearchQ == "" then
                        local dragHandle = CreateFrame("Frame", nil, talentRow)
                        dragHandle:SetSize(16, 20)
                        dragHandle:SetPoint("LEFT", talentRow, "LEFT", 0, 0)
                        dragHandle:EnableMouse(true)

                        local handleBg = dragHandle:CreateTexture(nil, "BACKGROUND")
                        handleBg:SetAllPoints()
                        local eb = RC:GetColor("ui", "elementBackground")
                        handleBg:SetColorTexture(eb.r, eb.g, eb.b, 0.6)
                        dragHandle.bg = handleBg

                        for j = 0, 2 do
                            local line = dragHandle:CreateTexture(nil, "ARTWORK")
                            line:SetSize(8, 2)
                            line:SetPoint("CENTER", 0, (j - 1) * 5)
                            local gtd = RC:GetColor("text", "disabled")
                            line:SetColorTexture(gtd.r, gtd.g, gtd.b, 0.9)
                        end

                        dragHandle:SetScript("OnEnter", function(self)
                            local ag = RC:GetColor("ui", "accentGold")
                            self.bg:SetColorTexture(ag.r, ag.g, ag.b, 0.35)
                        end)

                        dragHandle:SetScript("OnLeave", function(self)
                            local eb2 = RC:GetColor("ui", "elementBackground")
                            self.bg:SetColorTexture(eb2.r, eb2.g, eb2.b, 0.6)
                        end)

                        dragHandle:SetScript("OnMouseDown", function(self, button)
                            if button == "LeftButton" then
                                RC.specDetectionDrag.dragging = true
                                RC.specDetectionDrag.sourceIndex = talentRow.index
                                RC.specDetectionDrag.sourceName = talentRow.talentName
                                RC.specDetectionDrag.rows = talentRows
                                RC.specDetectionDrag.spec = spec

                                self:SetScript("OnUpdate", function()
                                    if not RC.specDetectionDrag.dragging then return end

                                    local indicator = RC.specDetectionDrag.indicator
                                    local _, cy = GetCursorPosition()
                                    local scale = UIParent:GetEffectiveScale()
                                    cy = cy / scale

                                    local insertIndex = nil
                                    for idx, row in ipairs(RC.specDetectionDrag.rows) do
                                        if row:IsVisible() then
                                            local top = row:GetTop()
                                            local bottom = row:GetBottom()
                                            local mid = (top + bottom) / 2

                                            if cy > mid then
                                                insertIndex = idx
                                                indicator:ClearAllPoints()
                                                indicator:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 2)
                                                indicator:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 2)
                                                indicator:Show()
                                                break
                                            elseif idx == #RC.specDetectionDrag.rows then
                                                insertIndex = idx + 1
                                                indicator:ClearAllPoints()
                                                indicator:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, -2)
                                                indicator:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, -2)
                                                indicator:Show()
                                            end
                                        end
                                    end

                                    RC.specDetectionDrag.insertIndex = insertIndex
                                end)
                            end
                        end)

                        dragHandle:SetScript("OnMouseUp", function(self, button)
                            if button == "LeftButton" and RC.specDetectionDrag.dragging then
                                RC.specDetectionDrag.dragging = false
                                self:SetScript("OnUpdate", nil)

                                local indicator = RC.specDetectionDrag.indicator
                                if indicator then indicator:Hide() end

                                local sourceIdx = RC.specDetectionDrag.sourceIndex
                                local insertIdx = RC.specDetectionDrag.insertIndex
                                local specKey = RC.specDetectionDrag.spec

                                -- insertIdx == sourceIdx or sourceIdx+1 means the row
                                -- was dropped back where it started - no-op.
                                if insertIdx and sourceIdx and insertIdx ~= sourceIdx and insertIdx ~= sourceIdx + 1 then
                                    local currentOrder = RC.db.specDetection.talentOrder[specKey] or defaultTalents
                                    local newOrder = {}
                                    local movedTalent = currentOrder[sourceIdx]

                                    -- Skip the source entry while copying, then splice
                                    -- movedTalent back in once targetIdx reaches insertIdx.
                                    local targetIdx = 1
                                    for idx, talent in ipairs(currentOrder) do
                                        if idx == sourceIdx then
                                        else
                                            if targetIdx == insertIdx then
                                                table.insert(newOrder, movedTalent)
                                            end
                                            table.insert(newOrder, talent)
                                            targetIdx = targetIdx + 1
                                        end
                                    end

                                    if insertIdx > #currentOrder then
                                        table.insert(newOrder, movedTalent)
                                    end

                                    RC.db.specDetection.talentOrder[specKey] = newOrder
                                    RC:SaveConfigurationToProfile()
                                    RC:ShowSidebarSpecDetection(frame, true)
                                end
                            end
                        end)

                        xOffset = 20
                    end

                    local icon = talentRow:CreateTexture(nil, "ARTWORK")
                    icon:SetSize(20, 20)
                    icon:SetPoint("LEFT", talentRow, "LEFT", xOffset, 0)
                    if data and data.icon then
                        icon:SetTexture(data.icon)
                    else
                        local spellIcon = GetSpellTexture(talentName)
                        if spellIcon then
                            icon:SetTexture(spellIcon)
                        else
                            icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
                        end
                    end
                    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                    if not isLearned then
                        icon:SetDesaturated(true)
                        icon:SetAlpha(0.5)
                    end

                    local displayName = keyData.abbrev or talentName
                    if isLearned and data and data.maxRank > 1 then
                        displayName = displayName .. " " .. data.rank .. "/" .. data.maxRank
                    elseif not isLearned then
                        displayName = displayName .. " " .. RCL["(not learned)"]
                    end

                    local checkbox = self.UI:CreateCheckbox(talentRow, displayName, not isHidden)
                    checkbox:SetPoint("LEFT", icon, "RIGHT", 5, 0)
                    if not isLearned then
                        -- Whole label dimmed (text.disabled) in place of an
                        -- inline colour code on the suffix; the icon is
                        -- already desaturated for the same state.
                        local _dim = self:GetColor("text", "disabled")
                        checkbox.Text:SetTextColor(_dim.r, _dim.g, _dim.b, 1)
                    end
                    checkbox.talentName = talentName
                    checkbox:SetScript("OnClick", function(cb)
                        local newState = cb:GetChecked()
                        if newState then
                            RC.db.specDetection.hiddenTalents[cb.talentName] = nil
                        else
                            RC.db.specDetection.hiddenTalents[cb.talentName] = true
                        end
                        RC:ForceCheckboxUpdate(cb, newState)
                        RC:SaveConfigurationToProfile()
                    end)

                    table.insert(talentRows, talentRow)
                    cardY = cardY - 26
                    talentCount = talentCount + 1
                end
            end

            if talentCount == 0 then
                local noTalents = self:CreateFontString(talentCard, "OVERLAY", nil, 10)
                noTalents:SetPoint("TOPLEFT", talentCard, "TOPLEFT", 14, cardY)
                noTalents:SetText(RCL["No key talents detected for this spec"])
                noTalents:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY = cardY - 25
            end

            cardY = cardY - 10
            talentCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - talentCard:GetHeight() - 15
        end
        elseif RC.specDetectionTab == "look" then
            local function Live()
                local f = RC.specDisplayFrame
                if f and f:IsShown() then RC:StyleSpecDisplay(f) end
            end
            yPos = K.Card(parent, yPos, RCL["Size"], function(card, y)
                local L = SpecLook()
                y = K.Slider(card, y, RCL["Width"], 220, 600, L.width or 320, 5,
                    function(v) return v .. RCL[" px"] end, function(v) SpecLook().width = v RC:SaveConfigurationToProfile() Live() end)
                y = K.Slider(card, y, RCL["Spec icon size"], 24, 96, L.iconSize or 48, 1,
                    function(v) return v .. RCL[" px"] end, function(v) SpecLook().iconSize = v RC:SaveConfigurationToProfile() Live() end)
                y = K.Slider(card, y, RCL["Talent icon size"], 16, 48, L.talentSize or 28, 1,
                    function(v) return v .. RCL[" px"] end, function(v) SpecLook().talentSize = v RC:SaveConfigurationToProfile() Live() end)
                y = K.Slider(card, y, RCL["Talents per row"], 3, 12, L.perRow or 8, 1,
                    function(v) return tostring(v) end, function(v) SpecLook().perRow = v RC:SaveConfigurationToProfile() Live() end)
                return K.Desc(card, y + 6, RCL["Talents past the end of a row wrap onto the next one."])
            end)
            yPos = K.Card(parent, yPos, RCL["Background"], function(card, y)
                y = K.BgTexture(card, y, RCL["Background texture"],
                    function() return SpecLook().bgTexture end,
                    function(v) SpecLook().bgTexture = v Live() end,
                    function() local c = SpecLook().bgColor or RC:GetColor("ui", "cardBackground") return c.r, c.g, c.b end)
                y = K.LookColor(card, y, RCL["Background colour"], SpecLook, "bgColor",
                    function() local c = RC:GetColor("ui", "cardBackground") return { r = c.r, g = c.g, b = c.b, a = 0.95 } end, Live, true)
                y = K.LookColor(card, y, RCL["Border colour"], SpecLook, "borderColor",
                    function() return RC:GetColor("ui", "borderNormal") end, Live, true)
                return y - 4
            end)
        elseif RC.specDetectionTab == "text" then
            local function Live()
                local f = RC.specDisplayFrame
                if f and f:IsShown() then RC:StyleSpecDisplay(f) end
            end
            local F = RC.SPEC_POPUP_FONTS
            yPos = K.Card(parent, yPos, RCL["Text"], function(card, y)
                y = K.Font(card, y, RCL["Spec name"], function() return SpecLook().titleFont end,
                    function(s) SpecLook().titleFont = s Live() end, F.title, "Fury", 10, 36)
                y = K.Desc(card, y + 4, RCL["The spec name keeps its spec colour (Appearance > Colors)."])
                y = K.Font(card, y, RCL["Entering Raid line"], function() return SpecLook().subFont end,
                    function(s) SpecLook().subFont = s Live() end, F.sub, RCL["Entering Raid"], 7, 24)
                y = K.LookColor(card, y, RCL["Colour"], SpecLook, "subColor",
                    function() return RC:GetColor("text", "gray") end, Live)
                y = K.Font(card, y - 6, RCL["Talent ranks"], function() return SpecLook().rankFont end,
                    function(s) SpecLook().rankFont = s Live() end, F.rank, "3/5  5/5", 6, 18)
                return y
            end)
            -- where each text sits (specDetection.anchors.title / .sub)
            yPos = K.Card(parent, yPos, RCL["Text positions"], function(card, y)
                local cw = card:GetWidth() or 0
                local W = (cw > 240) and math.min(460, cw - 28) or 420
                local function Root()
                    RC.db.specDetection = RC.db.specDetection or {}
                    return RC.db.specDetection
                end
                local function After() RC:SaveConfigurationToProfile() Live() end
                local TARGETS = { { value = "icon", text = RCL["The spec icon"] }, { value = "frame", text = RCL["The whole popup"] } }
                local ag, as = self.UI:CustomAccess(Root, "anchors", "title", After)
                local g = self.UI:CreateTextElement(card, { label = RCL["Spec name"], key = "title", width = W,
                    anchorGet = ag, anchorSet = as, targets = { TARGETS[1], { value = "sub", text = RCL["The Entering Raid line"] }, TARGETS[2] },
                    defaultTargetLabel = RCL["Right of the icon"],
                    anchorDefaults = function() return { point = "LEFT", relPoint = "RIGHT", x = 12, y = 8 } end })
                g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                y = y - g:GetHeight() - 14
                ag, as = self.UI:CustomAccess(Root, "anchors", "sub", After)
                g = self.UI:CreateTextElement(card, { label = RCL["Entering Raid line"], key = "sub", width = W,
                    anchorGet = ag, anchorSet = as, targets = { TARGETS[1], { value = "title", text = RCL["The spec name"] }, TARGETS[2] },
                    defaultTargetLabel = RCL["Right of the icon"],
                    anchorDefaults = function() return { point = "LEFT", relPoint = "RIGHT", x = 12, y = -10 } end })
                g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                y = y - g:GetHeight() - 10
                return K.Desc(card, y, RCL["Reset puts a text back where the popup always put it."])
            end)
        elseif RC.specDetectionTab == "animation" then
            yPos = K.Card(parent, yPos, RCL["Popup animation"], function(card, y)
                y = K.Anim(card, y, RCL["When it appears"], "in",
                    function() return SpecLook().showAnim end, function(s) SpecLook().showAnim = s end,
                    RC.SPEC_POPUP_SHOW, nil, P)
                y = K.Anim(card, y, RCL["When it goes"], "out",
                    function() return SpecLook().hideAnim end, function(s) SpecLook().hideAnim = s end,
                    RC.SPEC_POPUP_HIDE, nil, P)
                return K.Desc(card, y, RCL["The popup stays for the Display Duration (Behavior tab) between the two. Appearance > Motion can turn every animation off or speed them all up."])
            end)
        elseif RC.specDetectionTab == "sound" then
            yPos = K.Card(parent, yPos, RCL["Sound"], function(card, y)
                y = K.Check(card, y, RCL["Play sound on display"], function() return sd.playSound == true end,
                    function(v) sd.playSound = v end)
                local sp = self.UI:CreateSoundPicker(card, { selected = SpecLook().soundKey, width = 220,
                    onPick = function(key) SpecLook().soundKey = key RC:SaveConfigurationToProfile() end })
                sp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y - 2)
                y = y - 32
                y = K.Desc(card, y, RCL["Until you pick one it plays the quest-complete chime."])
                local reset = self.UI:CreateStyledButton(card, RCL["Use the chime"], 110, 22)
                reset:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                reset:SetScript("OnClick", function()
                    SpecLook().soundKey = nil
                    RC:SaveConfigurationToProfile()
                    RC.UI:NotifySettingChanged("reset")
                    RC:ShowSidebarSpecDetection(frame, true)
                end)
                return y - 32
            end)
        elseif RC.specDetectionTab == "position" then
            yPos = K.Card(parent, yPos, RCL["Position"], function(card, y)
                local function Live()
                    local f = RC.specDisplayFrame
                    if f then
                        local L = SpecLook()
                        f:ClearAllPoints()
                        f:SetPoint("TOP", UIParent, "TOP", L.x or 0, L.y or -150)
                        f:SetScale(L.scale or 1)
                    end
                end
                y = K.Desc(card, y, RCL["Measured from the top middle of the screen."])
                y = K.Slider(card, y, RCL["Horizontal position"], -800, 800, SpecLook().x or 0, 1,
                    function(v) return v .. RCL[" px"] end, function(v) SpecLook().x = v RC:SaveConfigurationToProfile() Live() end)
                y = K.Slider(card, y, RCL["Vertical position"], -900, 0, SpecLook().y or -150, 1,
                    function(v) return v .. RCL[" px"] end, function(v) SpecLook().y = v RC:SaveConfigurationToProfile() Live() end)
                y = K.Slider(card, y, RCL["Scale"], 0.5, 2, SpecLook().scale or 1, 0.05,
                    function(v) return math_floor(v * 100 + 0.5) .. "%" end,
                    function(v) SpecLook().scale = v RC:SaveConfigurationToProfile() Live() end, 100)
                local test = self.UI:CreateStyledButton(card, RCL["Test Display"], 100, 24)
                test:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                test:SetScript("OnClick", function() RC:ShowSpecDisplay(spec) end)
                local reset = self.UI:CreateStyledButton(card, RCL["Reset position"], 120, 24)
                reset:SetPoint("LEFT", test, "RIGHT", 6, 0)
                reset:SetScript("OnClick", function()
                    local L = SpecLook()
                    L.x, L.y, L.scale = nil, nil, nil
                    RC:SaveConfigurationToProfile()
                    Live()
                    RC.UI:NotifySettingChanged("reset")
                    RC:ShowSidebarSpecDetection(frame, true)
                end)
                return y - 32
            end)
        end
        -- the popup's layer / fade / shadow (the customization standard)
        yPos = self.UI:FrameCardsForTab(RC.specDetectionTab, parent, yPos, function() return RC.db.specDetection end, function()
            if RC.specDisplayFrame then RC:StyleSpecDisplay(RC.specDisplayFrame) end
        end, { scale = false, chromeFields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })

        if self.UpdateSidebarScrollbar then
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
        end
    end

