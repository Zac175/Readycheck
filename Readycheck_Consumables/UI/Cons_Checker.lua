local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_sort = table.insert, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbc = RC._sbc or {}
local _sbc = RC._sbc
local GetTabHoverBg, GetTabNormalBg, GetTabNormalText, GetTabSelectedBg, GetTabSelectedText, TEXT = _sbc.GetTabHoverBg, _sbc.GetTabNormalBg, _sbc.GetTabNormalText, _sbc.GetTabSelectedBg, _sbc.GetTabSelectedText, _sbc.TEXT
------------------------------------------------------------------------
-- Readycheck - Bars Overview + Consumables Checker Settings
-- ShowSidebarBarsOverview is the shared group overview; this file gives
-- its bar tiles their on/off switch (each bar's own db.enabled).
-- ShowSidebarConsumablesCheckerConfig edits db.consumablesChecker
-- (Behavior/Auto-Open/Items/Look/Text/Animation/Position; the last four
-- style the must-have alert, previewed in the pane). The raid-entry warning reuses the Items
-- list: disabledItems, priorityItems, customRecommended are separate
-- sub-tables keyed by item id.
------------------------------------------------------------------------
    -- The Bars group overview is the shared tile page; this file adds the
    -- three bar switches (a bar that is off is hidden from the sidebar, so
    -- its tile is where it comes back on). Each set() is the switch this
    -- page has always had: write enabled, show/hide the bar, save.
    local OT = RC.OverviewTiles or {}
    RC.OverviewTiles = OT

    local function BarSwitch(dbKey, stateKey, createFn, updateFn)
        return {
            get = function() local t = RC.db[dbKey] return (t and t.enabled) and true or false end,
            set = function(on)
                if not RC.db[dbKey] then RC.db[dbKey] = {} end
                RC.db[dbKey].enabled = on
                local st = RC[stateKey]
                if on then
                    if st and not st.frame and RC[createFn] then RC[createFn](RC) end
                    if st and st.frame then st.frame:Show() end
                    if RC[updateFn] then RC[updateFn](RC) end
                elseif st and st.frame then
                    st.frame:Hide()
                end
                RC:SaveConfigurationToProfile()
            end,
        }
    end

    OT.consumables_bar = { desc = RCL["Quick-access icons for flasks, elixirs, food and buffs."],
        toggle = BarSwitch("consumablesHelper", "consumablesHelper", "CreateConsumablesHelperFrame", "UpdateConsumablesButtons") }
    OT.potions_bar     = { desc = RCL["Combat and protection potions at a glance."],
        toggle = BarSwitch("potionsBar", "potionsBar", "CreatePotionsBarFrame", "UpdatePotionsButtons") }
    OT.weapons_bar     = { desc = RCL["Weapon stones and oils timer display."],
        toggle = BarSwitch("weaponsBar", "weaponsBar", "CreateWeaponsBarFrame", "UpdateWeaponsButtons") }

    function RC:ShowSidebarBarsOverview(frame)
        self:ShowSidebarGroupOverview(frame, "consumables")
    end

    ------------------------------------------------------------------
    -- The must-have alert's look: preview and the Look / Text /
    -- Animation / Position cards. Settings: consumablesChecker.essentials
    -- (see Checker_Essentials.lua; every new field nil = today's look).
    ------------------------------------------------------------------
    local MH_W, MH_H = 246, 166   -- update sizes the canvas to the alert

    local function MHList(P)
        local ESS = RC.Essentials
        local e = ESS.Settings()
        local items = (e and #e.items > 0) and e.items or ESS.DEFAULT_ITEMS
        if P and P.mode == "one" then return { items[1] } end
        return items
    end

    -- fake rows for the checker window's sample (each stock colour)
    local CHECKER_ROW_SAMPLES = {
        { icon = "Interface\\Icons\\INV_Potion_62", name = "Flask of the Titans", count = 2, rec = 3, stock = "medium" },
        { icon = "Interface\\Icons\\INV_Potion_32", name = "Elixir of the Mongoose", count = 20, rec = 20, stock = "good" },
        { icon = "Interface\\Icons\\INV_Potion_54", name = "Major Healing Potion", count = 0, rec = 10, stock = "bad" },
    }

    -- the checker window's sample (mode "window"): one category as the
    -- window lists it, missing first
    local CHECKER_WINDOW_SAMPLE = {
        category = "Potions",
        rows = {
            { icon = "Interface\\Icons\\INV_Potion_54", name = "Major Healing Potion", count = 0, rec = 10, stock = "bad" },
            { icon = "Interface\\Icons\\INV_Potion_24", name = "Greater Fire Protection Potion", count = 2, rec = 10, stock = "warning" },
            { icon = "Interface\\Icons\\INV_Potion_04", name = "Free Action Potion", count = 6, rec = 4, stock = "good" },
        },
    }

    local function DeclareMustHavePreview(self)
        if not RC.Essentials then return nil end
        -- a click on a row's name / count opens the Text tab on its controls
        if RC.CustomPick then
            RC.CustomPick.SetHandler("consumables.mustHave", function(k)
                local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                if not cf or (k ~= "rowName" and k ~= "rowCount") then return end
                cf.consumablesCheckerTab = "text"
                RC:ShowSidebarConsumablesCheckerConfig(cf, true)
            end)
        end
        return self.UI:DeclarePreview({
            key = "consumables.mustHave", title = RCL["Missing must-have items"],
            width = MH_W, height = MH_H,
            build = function(canvas, P)
                local f = CreateFrame("Frame", nil, canvas)
                f:SetPoint("CENTER", canvas, "CENTER", 0, 0)
                RC.Essentials.BuildAlertFrame(f)
                P.store.alert, P.store.token = f, 0
                -- the checker window's rows (mode "rows"), drawn by its own row code
                if RC.NewCheckerRowSample then
                    local host = CreateFrame("Frame", nil, canvas)
                    host:SetPoint("CENTER", canvas, "CENTER", 0, 0)
                    host:Hide()
                    P.store.rowsHost, P.store.rows = host, {}
                    for i = 1, #CHECKER_ROW_SAMPLES do P.store.rows[i] = RC:NewCheckerRowSample(host) end
                    RC.UI:PickOnClick(host, "consumables.mustHave")
                end
                -- the whole checker window (mode "window"), built by its own
                -- code (title bar, tools, search box, scroll area, grip), inert
                if RC.NewCheckerWindowSample then
                    local win = RC:NewCheckerWindowSample(canvas)
                    win:SetPoint("CENTER", canvas, "CENTER", 0, 0)
                    win:Hide()
                    RC.UI:PickOnClick(win, "consumables.mustHave")
                    P.store.win = win
                end
            end,
            update = function(canvas, P)
                local st = P.store
                local f = st.alert
                if st.win then
                    if P.mode == "window" then
                        if not st.winOn then
                            RC.Motion.Stop(f) f:Hide()
                            if st.rowsHost then st.rowsHost:Hide() st.rowsOn = false end
                            st.win:Show() st.winOn = true
                        end
                        local w, h = RC:FillCheckerWindowSample(st.win, RCL[CHECKER_WINDOW_SAMPLE.category], CHECKER_WINDOW_SAMPLE.rows)
                        -- the canvas is the window's box; the strip shows it at real size
                        P.Resize(w + 6, h + 6)
                        return
                    elseif st.winOn then
                        st.win:Hide() f:Show() st.winOn = false st.sig = nil
                    end
                end
                if st.rowsHost then
                    if P.mode == "rows" then
                        if not st.rowsOn then RC.Motion.Stop(f) f:Hide() st.rowsHost:Show() st.rowsOn = true end
                        -- laid out as the window lays them out: its width less
                        -- the margins and scroll bar, a row every 28 px
                        local cc = RC.db.consumablesChecker or {}
                        local w = (tonumber(cc.width) or 320) - 30
                        local n = #CHECKER_ROW_SAMPLES
                        local h = n * 28 - 2
                        st.rowsHost:SetSize(w, h)
                        for i, row in ipairs(st.rows) do
                            row:ClearAllPoints()
                            row:SetPoint("TOPLEFT", st.rowsHost, "TOPLEFT", 0, -(i - 1) * 28)
                            row:SetWidth(w)
                            RC:FillCheckerRowSample(row, CHECKER_ROW_SAMPLES[i])
                        end
                        P.Resize(w + 6, h + 6)
                        return
                    elseif st.rowsOn then
                        st.rowsHost:Hide() f:Show() st.rowsOn = false st.sig = nil
                    end
                end
                local list = MHList(P)
                RC.Essentials.LayoutAlert(f, list)
                local w, h = f:GetWidth(), f:GetHeight()
                local sig = #list .. ":" .. w .. ":" .. h
                if st.sig ~= sig then
                    RC.Motion.Stop(f)
                    f:SetScale(1)
                    st.sig = sig
                end
                -- the canvas is the alert's box; the strip shows it at real size
                P.Resize(w + 6, h + 6)
            end,
            replay = function(canvas, P)
                local M = RC.Motion
                local st = P.store
                if P.mode == "rows" then return end
                if P.mode == "window" then
                    -- the window's opening: its title bar's sheen and mark
                    -- (on show) and its fade-in
                    local win = st.win
                    if win and win:IsShown() then
                        win:Hide() win:Show()
                        RC:PlayCheckerOpen(win)
                    end
                    return
                end
                local f = st.alert
                st.token = st.token + 1
                local t = st.token
                M.Stop(f)
                f:Hide()
                local inSpec = RC.Essentials.Anim("showAnim")
                M.Show(f, inSpec)
                C_Timer.After(M.Duration(inSpec.duration) + M.Duration(inSpec.delay) + 1.4, function()
                    if t ~= st.token or not f:IsVisible() then return end
                    local outSpec = RC.Essentials.Anim("hideAnim")
                    M.Hide(f, outSpec)
                    C_Timer.After(M.Duration(outSpec.duration) + M.Duration(outSpec.delay) + 0.4, function()
                        if t ~= st.token then return end
                        M.Stop(f)
                        if canvas:IsVisible() then f:Show() end
                    end)
                end)
            end,
            modes = { { id = "all", label = RCL["Whole list"] }, { id = "one", label = RCL["One item"] },
                { id = "rows", label = RCL["Checker rows"] }, { id = "window", label = RCL["Checker window"] } },
            modesLabel = RCL["Show"],
        })
    end

    local function MHChanged()
        RC:SaveConfigurationToProfile()
        if RC.Essentials then RC.Essentials.Refresh() end
    end

    local function MHColor(self, card, cy, key, label)
        local ESS = RC.Essentials
        local d = ESS.COLOR_DEFAULTS[key]
        local cp = self.UI:CreateColorPicker(card, {
            label = label, width = 420, alpha = true,
            get = function() return ESS.Settings()[key] end,
            set = function(r, g, b, a) ESS.Settings()[key] = { r = r, g = g, b = b, a = a or 1 } MHChanged() end,
            default = RC:GetColor(d[1], d[2]),
            isChanged = function() return type(ESS.Settings()[key]) == "table" end,
            reset = function() ESS.Settings()[key] = nil MHChanged() end,
        })
        cp:SetPoint("TOPLEFT", card, "TOPLEFT", 10, cy)
        return cy - 28
    end

    local function MHSlider(self, card, cy, label, minV, maxV, step, cur, fmt, onChange)
        local l = RC:CreateFontString(card, "OVERLAY", nil, 11)
        l:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        l:SetText(label)
        l:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
        cy = cy - 20
        local sl = self.UI:CreateSlider(card, minV, maxV, cur, step)
        sl:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        sl.Text:SetText(fmt(cur))
        sl:SetScript("OnValueChanged", function(s, v)
            v = math_floor(v / step + 0.5) * step
            s.Text:SetText(fmt(v))
            onChange(v)
        end)
        return cy - 46
    end

    local function BuildMustHaveLook(self, frame, parent, yPos)
        local ESS = RC.Essentials
        if not ESS then return yPos end
        local e = ESS.Settings()
        local CBS = _sbc.BarPages
        local card = self:CreateSettingsCard(parent, yPos, RCL["Missing must-have items"])
        local cy = -32
        cy = CBS.Desc(card, cy, RCL["The big icons that go up in the middle of the screen when a must-have item is missing."])
        cy = MHSlider(self, card, cy, RCL["Icon size"], 32, 128, 4, e.iconSize or 56,
            function(v) return v .. " px" end,
            function(v) ESS.Settings().iconSize = v MHChanged() end)
        cy = MHSlider(self, card, cy, RCL["Space between icons"], 20, 200, 5,
            math_floor((tonumber(e.gap) or ESS.GAP) * 100 + 0.5),
            function(v) return v .. "%" end,
            function(v) ESS.Settings().gap = v / 100 MHChanged() end)
        cy = CBS.Desc(card, cy, RCL["As a share of the icon size."])
        cy = MHColor(self, card, cy, "ringColor", RCL["Ring round each icon"])
        cy = cy - 4
        card:SetContentHeight(math.abs(cy))
        return yPos - card:GetHeight() - 15
    end

    local function BuildMustHaveText(self, frame, parent, yPos)
        local ESS = RC.Essentials
        if not ESS then return yPos end
        local CBS = _sbc.BarPages
        local rows = {
            { "titleFont", "titleColor", RCL["Title"], RCL["MISSING across the top."], ESS.FONT_DEFAULTS.title, RCL["MISSING"] },
            { "nameFont", "nameColor", RCL["Item names"], RCL["The name under each icon."], ESS.FONT_DEFAULTS.name, "Limited Invulnerability Potion" },
            { "hintFont", "hintColor", RCL["Hint"], RCL["The line at the bottom."], ESS.FONT_DEFAULTS.hint, RCL["click to dismiss"] },
        }
        for _, r in ipairs(rows) do
            local card = self:CreateSettingsCard(parent, yPos, r[3])
            local cy = -32
            cy = CBS.Desc(card, cy, r[4])
            local fkey = r[1]
            local fp = self.UI:CreateFontPicker(card, {
                label = RCL["Font"], width = 420,
                get = function() return ESS.Settings()[fkey] end,
                set = function(spec) ESS.Settings()[fkey] = spec MHChanged() end,
                defaults = r[5], minSize = 6, maxSize = 48, sample = r[6],
            })
            fp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
            cy = cy - fp:GetHeight() - 8
            cy = MHColor(self, card, cy, r[2], RCL["Colour"])
            cy = cy - 4
            card:SetContentHeight(math.abs(cy))
            yPos = yPos - card:GetHeight() - 15
        end
        return yPos
    end

    -- The checker window's rows: where each row's name and count sit, and
    -- how the count reads (consumablesChecker.anchors.rowName / .rowCount,
    -- consumablesChecker.formats.count; nothing set = today's rows).
    local function CheckerRowsChanged()
        RC:SaveConfigurationToProfile()
        local _cck = RC._cck
        if _cck and _cck.ApplyCheckerRowCustom then _cck.ApplyCheckerRowCustom() end
        if RC.InvalidateCheckerColorCache then RC:InvalidateCheckerColorCache() end
        if RC.UpdateConsumablesCheckerDisplay then RC:UpdateConsumablesCheckerDisplay() end
    end
    local function CheckerRoot() return RC.db.consumablesChecker end
    local ROW_TARGETS = {
        { value = "row", text = RCL["The row"] },
        { value = "icon", text = RCL["The icon"] },
    }
    local NAME_TARGETS = { ROW_TARGETS[1], ROW_TARGETS[2], { value = "count", text = RCL["The count"] } }
    local COUNT_TARGETS = { ROW_TARGETS[1], ROW_TARGETS[2], { value = "name", text = RCL["The name"] } }
    local COUNT_KINDS = { number = true }
    local function CountSample(spec)
        return RC:CheckerCountText(12, 20, RC.db.consumablesChecker.showRecommended, spec or {})
    end
    local function BuildCheckerRowsText(self, frame, parent, yPos)
        local CBS = _sbc.BarPages
        local card = self:CreateSettingsCard(parent, yPos, RCL["Checker window rows"])
        local cy = -32
        cy = CBS.Desc(card, cy, RCL["Where each item's name and count sit in its row, and how the count reads. The preview's Checker rows shows them."])
        local cw = card:GetWidth() or 0
        local W = (cw > 240) and math_min(460, cw - 28) or 420
        local ag, as = self.UI:CustomAccess(CheckerRoot, "anchors", "rowName", CheckerRowsChanged)
        local g = self.UI:CreateTextElement(card, { label = RCL["Item name position"], key = "rowName", width = W,
            anchorGet = ag, anchorSet = as, targets = NAME_TARGETS,
            defaultTargetLabel = RCL["After the icon, to the count"],
            anchorDefaults = function() return { point = "LEFT", relPoint = "RIGHT", x = 5, y = 0 } end })
        g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        cy = cy - g:GetHeight() - 10
        ag, as = self.UI:CustomAccess(CheckerRoot, "anchors", "rowCount", CheckerRowsChanged)
        local fg, fs = self.UI:CustomAccess(CheckerRoot, "formats", "count", CheckerRowsChanged)
        g = self.UI:CreateTextElement(card, { label = RCL["Count"], key = "rowCount", width = W,
            formatGet = fg, formatSet = fs, formatKinds = COUNT_KINDS, formatTokens = RC.CHECKER_COUNT_TOKENS,
            formatDefaults = RC.db.consumablesChecker.showRecommended and RC.CHECKER_COUNT_FORMAT or RC.CHECKER_COUNT_FORMAT_PLAIN,
            formatSample = CountSample,
            anchorGet = ag, anchorSet = as, targets = COUNT_TARGETS,
            defaultTargetLabel = RCL["Right end of the row"],
            anchorDefaults = function() return { point = "RIGHT", relPoint = "RIGHT", x = -6, y = 0 } end })
        g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        cy = cy - g:GetHeight() - 6
        card:SetContentHeight(math.abs(cy))
        return yPos - card:GetHeight() - 15
    end

    local function BuildMustHaveAnimation(self, frame, parent, yPos, P)
        local ESS = RC.Essentials
        if not ESS then return yPos end
        local CBS = _sbc.BarPages
        local card = self:CreateSettingsCard(parent, yPos, RCL["Missing must-have items"])
        local cy = -32
        cy = CBS.Desc(card, cy, RCL["How the alert comes up and goes away (click, buying the item, or combat)."])
        local function Set(which, spec)
            ESS.Settings()[which] = spec
            RC:SaveConfigurationToProfile()
            if P then P.Replay() end
        end
        local inP = self.UI:CreateAnimationPicker(card, {
            label = RCL["When it appears"], width = 460, how = "in", defaults = ESS.ANIM_DEFAULTS,
            get = function() return ESS.Settings().showAnim end,
            set = function(spec) Set("showAnim", spec) end,
        })
        inP:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        cy = cy - inP:GetHeight() - 14
        local outP = self.UI:CreateAnimationPicker(card, {
            label = RCL["When it goes"], width = 460, how = "out", defaults = ESS.ANIM_DEFAULTS,
            get = function() return ESS.Settings().hideAnim end,
            set = function(spec) Set("hideAnim", spec) end,
        })
        outP:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        cy = cy - outP:GetHeight() - 8
        cy = CBS.Desc(card, cy, RCL["Appearance > Motion can turn every animation off or speed them all up."])
        card:SetContentHeight(math.abs(cy))
        return yPos - card:GetHeight() - 15
    end

    local function BuildMustHavePosition(self, frame, parent, yPos)
        local ESS = RC.Essentials
        if not ESS then return yPos end
        local CBS = _sbc.BarPages
        local card = self:CreateSettingsCard(parent, yPos, RCL["Missing must-have items"])
        local cy = -32
        cy = CBS.Desc(card, cy, RCL["Move the alert with Edit Mode (/rc move). Test puts it up with every item on your list."])
        local test = self.UI:CreateStyledButton(card, RCL["Test"], 90, 22)
        test:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        test:SetScript("OnClick", function() ESS.Show(true) end)
        local hide = self.UI:CreateStyledButton(card, RCL["Hide"], 90, 22)
        hide:SetPoint("LEFT", test, "RIGHT", 8, 0)
        hide:SetScript("OnClick", function() ESS.Hide() end)
        cy = cy - 34
        card:SetContentHeight(math.abs(cy))
        return yPos - card:GetHeight() - 15
    end

    function RC:ShowSidebarConsumablesCheckerConfig(frame, preserveScroll)
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        -- the must-have alert, drawn by its own code (Checker_Essentials)
        local P = DeclareMustHavePreview(self)
        local parent = frame.scrollChild
        local yPos = -20

        local headerFrame, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Consumables Checker"],
            RCL["Check raid consumables before pulls"], "Interface\\Icons\\INV_Scroll_03")
        yPos = newY

        if self.InitializeConsumablesCheckerDefaults then
            self:InitializeConsumablesCheckerDefaults()
        elseif not self.db.consumablesChecker then
            self.db.consumablesChecker = {}
        end
        local cc = self.db.consumablesChecker

        -- old tab key (search aliases, saved state) lands on Behavior
        if not frame.consumablesCheckerTab or frame.consumablesCheckerTab == "general" then
            frame.consumablesCheckerTab = "behavior"
        end

        local _, newTabY = self.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = {
                { key = "behavior",  label = RCL["Behavior"] },
                { key = "autoopen",  label = RCL["Auto-Open"] },
                { key = "items",     label = RCL["Items"] },
                { key = "look",      label = RCL["Look"] },
                { key = "text",      label = RCL["Text"] },
                { key = "animation", label = RCL["Animation"] },
                { key = "position",  label = RCL["Position"] },
            },
            selected = frame.consumablesCheckerTab,
            onClick = function(tk)
                frame.consumablesCheckerTab = tk
                RC:ShowSidebarConsumablesCheckerConfig(frame, true)
            end,
            inset = 18,
            fontSize = 10,
            advance = 34,
        })
        yPos = newTabY

        local currentTab = frame.consumablesCheckerTab or "behavior"

        if currentTab == "behavior" then
            local basicCard = self:CreateSettingsCard(parent, yPos, RCL["General"])
            local cardY = -32

            local enableCheck = self.UI:CreateSettingCheckbox(basicCard, cardY, "Enable Consumables Checker", cc.enabled, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesChecker.enabled = newState
                RC:ForceCheckboxUpdate(cb, newState)
                if not newState and RC.consumablesChecker and RC.consumablesChecker.frame then
                    RC.consumablesChecker.frame:Hide()
                end
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 28
            local enableMark = self.UI:MarkCard(basicCard)

            if cc.raidEntryAlert == nil then cc.raidEntryAlert = true end
            local raidAlertCheck = self.UI:CreateSettingCheckbox(basicCard, cardY, "Warn on raid entry when missing consumables", cc.raidEntryAlert, function(cb)
                local newState = cb:GetChecked() and true or false
                RC.db.consumablesChecker.raidEntryAlert = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            local raTestBtn = self.UI:CreateStyledButton(basicCard, RCL["Test Warning"], 110, 22)
            raTestBtn:SetPoint("TOPRIGHT", basicCard, "TOPRIGHT", -14, cardY + 4)
            raTestBtn:SetScript("OnClick", function()
                if RC.RunRaidConsumablesCheck then
                    RC:RunRaidConsumablesCheck(true)
                end
            end)
            cardY = cardY - 24

            local prioOnlyCheck = self.UI:CreateSettingCheckbox(basicCard, cardY, "Raid-entry warning: only warn about priority items", cc.raidEntryAlertPrioOnly, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesChecker.raidEntryAlertPrioOnly = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26

            local soundCheck = self.UI:CreateSettingCheckbox(basicCard, cardY, "Play warning sound", cc.playSound, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesChecker.playSound = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26
            if self.UI.CreateSoundPicker then
                local warnSound = self.UI:CreateSoundPicker(basicCard, { width = 220,
                    selected = cc.soundKey or "WR: Warning",
                    onPick = function(key)
                        RC.db.consumablesChecker.soundKey = key
                        RC:SaveConfigurationToProfile()
                    end })
                warnSound:SetPoint("TOPLEFT", basicCard, "TOPLEFT", 14, cardY)
                cardY = cardY - 32
                self.UI:BindDependents(soundCheck, { warnSound })
            end
            cardY = cardY - 9
            self.UI:BindDependents(raidAlertCheck, { prioOnlyCheck })
            self.UI:BindDependents(enableCheck, self.UI:CardSince(basicCard, enableMark))

            basicCard:SetContentHeight(math.abs(cardY))

            yPos = yPos - basicCard:GetHeight() - 15

            -- Must-have items (Checker_Essentials.lua): big on-screen icons
            -- when one of them is missing from the bags.
            local ESS = RC.Essentials
            if ESS then
                local e = ESS.Settings()
                local mhCard = self:CreateSettingsCard(parent, yPos, RCL["Must-have items"])
                cardY = -32

                cardY = RC.UI:CreateHelpLine(mhCard, 14, cardY, RCL["Things you must never raid without. If you have none of one, big icons go up in the middle of your screen when you enter a raid (level 60 characters only). Buying it takes it off; a click dismisses the rest."],
                    { title = RCL["Must-have items"] })

                self.UI:CreateSettingCheckbox(mhCard, cardY, RCL["Show missing must-have items on screen"], e.enabled, function(cb)
                    local on = cb:GetChecked() and true or false
                    ESS.Settings().enabled = on
                    RC:ForceCheckboxUpdate(cb, on)
                    if not on then ESS.Hide() end
                    RC:SaveConfigurationToProfile()
                end)
                local mhTest = self.UI:CreateStyledButton(mhCard, RCL["Test"], 70, 22)
                mhTest:SetPoint("TOPRIGHT", mhCard, "TOPRIGHT", -14, cardY + 4)
                mhTest:SetScript("OnClick", function() ESS.Show(true) end)
                cardY = cardY - 26

                self.UI:CreateSettingCheckbox(mhCard, cardY, RCL["Play a sound when something is missing"], e.airhorn, function(cb)
                    local on = cb:GetChecked() and true or false
                    ESS.Settings().airhorn = on
                    RC:ForceCheckboxUpdate(cb, on)
                    if on then ESS.PlaySound() end
                    RC:SaveConfigurationToProfile()
                end)
                cardY = cardY - 26
                if self.UI.CreateSoundPicker then
                    local mhSound = self.UI:CreateSoundPicker(mhCard, { width = 220, selected = e.soundKey,
                        fallback = ESS.AIRHORN,
                        onPick = function(key)
                            ESS.Settings().soundKey = key
                            RC:SaveConfigurationToProfile()
                        end })
                    mhSound:SetPoint("TOPLEFT", mhCard, "TOPLEFT", 38, cardY)
                    cardY = cardY - 32
                end


                -- the list
                local shown = 0
                for _, id in ipairs(e.items) do
                    if ESS.Shown(id) then
                        shown = shown + 1
                        local row = CreateFrame("Frame", nil, mhCard)
                        row:SetHeight(24)
                        row:SetPoint("TOPLEFT", mhCard, "TOPLEFT", 14, cardY)
                        row:SetPoint("RIGHT", mhCard, "RIGHT", -14, 0)
                        local ic = row:CreateTexture(nil, "ARTWORK")
                        ic:SetSize(20, 20)
                        ic:SetPoint("LEFT", row, "LEFT", 0, 0)
                        ic:SetTexture(ESS.ItemIcon(id))
                        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        local have = ESS.Count(id)
                        local nm = self:CreateFontString(row, "OVERLAY", nil, 11)
                        nm:SetPoint("LEFT", ic, "RIGHT", 8, 0)
                        nm:SetText(ESS.ItemName(id) .. (ESS.IsDummy(id) and RCL["  (any kind)"] or ""))
                        nm:SetTextColor(TEXT.light and TEXT.light[1] or TEXT.normal[1], TEXT.light and TEXT.light[2] or TEXT.normal[2], TEXT.light and TEXT.light[3] or TEXT.normal[3])
                        local cnt = self:CreateFontString(row, "OVERLAY", nil, 11)
                        cnt:SetPoint("RIGHT", row, "RIGHT", -30, 0)
                        local cc2 = (have > 0) and RC:GetColor("text", "success") or RC:GetColor("text", "red")
                        cnt:SetText(have > 0 and (RCL["in bags: "] .. have) or RCL["none!"])
                        cnt:SetTextColor(cc2.r, cc2.g, cc2.b)
                        local itemId = id
                        local del = self.UI:CreateRemoveButton(row, 18, function()
                            ESS.Remove(itemId)
                            RC:ShowSidebarConsumablesCheckerConfig(frame)
                        end)
                        del:SetPoint("RIGHT", row, "RIGHT", 0, 0)
                        cardY = cardY - 26
                    end
                end
                if shown == 0 then
                    local none = self:CreateFontString(mhCard, "OVERLAY", nil, 10)
                    none:SetPoint("TOPLEFT", mhCard, "TOPLEFT", 14, cardY)
                    none:SetText(RCL["Nothing on the list."])
                    none:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                    cardY = cardY - 22
                end
                cardY = cardY - 6

                -- adding: shift-click an item, or type its name or id
                local addBox = self.UI:CreateStyledEditBox(mhCard, { height = 22, maxLetters = 250 })
                addBox:SetPoint("TOPLEFT", mhCard, "TOPLEFT", 14, cardY)
                addBox:SetPoint("RIGHT", mhCard, "RIGHT", -110, 0)
                local addMsg = self:CreateFontString(mhCard, "OVERLAY", nil, 10)
                local function DoAdd()
                    local eb = addBox.editBox
                    local id, why = ESS.Add(eb:GetText() or "")
                    if id then
                        RC:ShowSidebarConsumablesCheckerConfig(frame)
                    else
                        addMsg:SetText(why or "")
                    end
                end
                local addBtn = self.UI:CreateStyledButton(mhCard, RCL["Add"], 88, 22)
                addBtn:SetPoint("TOPRIGHT", mhCard, "TOPRIGHT", -14, cardY)
                addBtn:SetScript("OnClick", DoAdd)
                if addBox.editBox then
                    addBox.editBox:SetScript("OnEnterPressed", DoAdd)
                    RC._mustHaveAddBox = addBox.editBox
                end
                -- shift-clicking an item while the box has focus drops its link in
                if not RC._mustHaveLinkHook and hooksecurefunc then
                    RC._mustHaveLinkHook = true
                    hooksecurefunc("ChatEdit_InsertLink", function(link)
                        local eb = RC._mustHaveAddBox
                        if link and eb and eb:IsVisible() and eb:HasFocus() and link:find("item:", 1, true) then
                            eb:SetText(link)
                        end
                    end)
                end
                cardY = cardY - 26
                addMsg:SetPoint("TOPLEFT", mhCard, "TOPLEFT", 14, cardY)
                addMsg:SetPoint("RIGHT", mhCard, "RIGHT", -14, 0)
                addMsg:SetJustifyH("LEFT")
                addMsg:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                addMsg:SetText(RCL["Click the box, then shift-click an item in your bags (or type its name or item ID)."])
                cardY = cardY - 20

                local defBtn = self.UI:CreateStyledButton(mhCard, RCL["Put Back Defaults"], 130, 22)
                defBtn:SetPoint("TOPLEFT", mhCard, "TOPLEFT", 14, cardY)
                defBtn:SetScript("OnClick", function()
                    ESS.RestoreDefaults()
                    RC:ShowSidebarConsumablesCheckerConfig(frame)
                end)
                cardY = cardY - 34

                mhCard:SetContentHeight(math.abs(cardY))
                yPos = yPos - mhCard:GetHeight() - 15
            end

        end

        if currentTab == "position" then
            local posCard = self:CreateSettingsCard(parent, yPos, RCL["Checker window"])
            local cardY = -32
            local lockCheck = self.UI:CreateSettingCheckbox(posCard, cardY, "Lock window position", cc.locked, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesChecker.locked = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 28
            posCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - posCard:GetHeight() - 15

            local actionsCard = self:CreateSettingsCard(parent, yPos, RCL["Actions"])
            local cardY = -32

            local openBtn = self.UI:CreateStyledButton(actionsCard, RCL["Open Window"], 110, 22)
            openBtn:SetPoint("TOPLEFT", actionsCard, "TOPLEFT", 14, cardY)
            openBtn:SetScript("OnClick", function()
                if not RC.consumablesChecker.frame then
                    RC:CreateConsumablesCheckerFrame()
                    RC:PopulateConsumablesChecker()
                end
                if RC.consumablesChecker.frame then
                    RC.consumablesChecker.wasManuallyShown = true
                    RC.consumablesChecker.frame:Show()
                    RC:PopulateConsumablesChecker()
                end
            end)

            local resetPosBtn = self.UI:CreateStyledButton(actionsCard, RCL["Reset Position"], 110, 22)
            resetPosBtn:SetPoint("LEFT", openBtn, "RIGHT", 8, 0)
            resetPosBtn:SetScript("OnClick", function()
                RC.UI:CreateConfirmDialog(RCL["Reset Checker Position"],
                    RCL["Reset the checker window's size and its remembered Auction House and Mailbox positions?"],
                    function()
                        local cc = RC.db.consumablesChecker
                        cc.xOffset, cc.yOffset, cc.anchorPoint, cc.centred = nil, nil, nil, nil
                        cc.width = 320
                        cc.height = 480
                        cc.ahPosition = nil
                        cc.mailboxPosition = nil
                        if RC.consumablesChecker.frame then
                            RC.consumablesChecker.frame:SetSize(320, 480)
                            RC:ApplyConsumablesCheckerPosition()
                        end
                        RC:SaveConfigurationToProfile()
                    end, nil, RCL["Reset"], true)
            end)
            cardY = cardY - 40

            actionsCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - actionsCard:GetHeight() - 15

            yPos = BuildMustHavePosition(self, frame, parent, yPos)
        end

        if currentTab == "behavior" then
            local cardY
            local infoCard = self:CreateSettingsCard(parent, yPos, RCL["Items checked"])
            cardY = -32

            cardY = RC.UI:CreateHelpLine(infoCard, 14, cardY, RCL["Checks flasks, elixirs, food, drinks, potions, protection potions, buffs, utilities, reagents, chronoboon, and specials.\n\nThe raid-entry warning uses this SAME list: right-click items in the checker window to enable or disable them, and use Edit there to set the recommended amounts the warning compares against."],
                { short = RCL["The raid-entry warning uses this same list: right-click items in the checker to turn them on or off."],
                  title = RCL["Items checked"] })

            infoCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - infoCard:GetHeight() - 15

        end

        if currentTab == "autoopen" then
            local ahCard = self:CreateSettingsCard(parent, yPos, RCL["Auction House"])
            local cardY = -32

            local ahInfo = self:CreateFontString(ahCard, "OVERLAY", nil, 10)
            ahInfo:SetPoint("TOPLEFT", ahCard, "TOPLEFT", 14, cardY)
            ahInfo:SetWidth(ahCard:GetWidth() - 30)
            ahInfo:SetText(RCL["Automatically show the checker when visiting the AH to help with shopping."])
            ahInfo:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 27

            local ahOpenCheck = self.UI:CreateSettingCheckbox(ahCard, cardY, "Auto-open at Auction House", cc.autoOpenAtAH, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesChecker.autoOpenAtAH = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 28

            local ahCloseCheck = self.UI:CreateSettingCheckbox(ahCard, cardY, "Auto-close when leaving AH", cc.autoCloseAtAH, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesChecker.autoCloseAtAH = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 28

            local ahAnchorCheck = self.UI:CreateSettingCheckbox(ahCard, cardY, "Snap next to Auction House frame", cc.anchorToAH, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesChecker.anchorToAH = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 28

            if RC.db.consumablesChecker.reportOnAHOpen == nil then
                RC.db.consumablesChecker.reportOnAHOpen = false
            end
            local ahReportCheck = self.UI:CreateSettingCheckbox(ahCard, cardY, "Print report to chat when AH opens", cc.reportOnAHOpen, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesChecker.reportOnAHOpen = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 35

            ahCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - ahCard:GetHeight() - 15

            local mailCard = self:CreateSettingsCard(parent, yPos, RCL["Mailbox"])
            cardY = -32

            local mailInfo = self:CreateFontString(mailCard, "OVERLAY", nil, 10)
            mailInfo:SetPoint("TOPLEFT", mailCard, "TOPLEFT", 14, cardY)
            mailInfo:SetWidth(mailCard:GetWidth() - 30)
            mailInfo:SetText(RCL["Automatically show the checker when checking mail to track incoming supplies."])
            mailInfo:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 27

            local mailOpenCheck = self.UI:CreateSettingCheckbox(mailCard, cardY, "Auto-open at Mailbox", cc.autoOpenAtMailbox, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesChecker.autoOpenAtMailbox = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 28

            local mailCloseCheck = self.UI:CreateSettingCheckbox(mailCard, cardY, "Auto-close when leaving Mailbox", cc.autoCloseAtMailbox, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesChecker.autoCloseAtMailbox = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 28

            local mailAnchorCheck = self.UI:CreateSettingCheckbox(mailCard, cardY, "Snap next to Mailbox frame", cc.anchorToMailbox, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesChecker.anchorToMailbox = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
                if RC.consumablesChecker.currentContext == "mailbox" and RC.consumablesChecker.frame and RC.consumablesChecker.frame:IsShown() then
                    RC:ApplyConsumablesCheckerPosition()
                end
            end)
            cardY = cardY - 35

            mailCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - mailCard:GetHeight() - 15

            local posCard = self:CreateSettingsCard(parent, yPos, RCL["Position memory"])
            cardY = -32

            local posInfo = self:CreateFontString(posCard, "OVERLAY", nil, 10)
            posInfo:SetPoint("TOPLEFT", posCard, "TOPLEFT", 14, cardY)
            posInfo:SetWidth(posCard:GetWidth() - 30)
            posInfo:SetText(RCL["The checker remembers separate positions for AH and Mailbox. Drag the window while at each location to set its position."])
            posInfo:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 45

            posCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - posCard:GetHeight() - 15

        end

        if currentTab == "items" then

            if not self.db.consumablesChecker.disabledItems then
                self.db.consumablesChecker.disabledItems = {}
            end
            local disabledItems = self.db.consumablesChecker.disabledItems

            if not self.db.consumablesChecker.collapsedCategories then
                self.db.consumablesChecker.collapsedCategories = {}
            end

            local countCard = self:CreateSettingsCard(parent, yPos, RCL["Count display"])
            local cardY = -32

            local countInfo = self:CreateFontString(countCard, "OVERLAY", nil, 10)
            countInfo:SetPoint("TOPLEFT", countCard, "TOPLEFT", 14, cardY)
            countInfo:SetWidth(countCard:GetWidth() - 30)
            countInfo:SetText(RCL["Choose how item counts are displayed in the Consumables Checker window."])
            countInfo:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 27

            local showRecCheck = self.UI:CreateSettingCheckbox(countCard, cardY, "Show recommended amounts (X/Y)", cc.showRecommended ~= false, function(cb)
                local newState = cb:GetChecked()
                RC.db.consumablesChecker.showRecommended = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
                RC:UpdateConsumablesCheckerDisplay()
                if RC.consumablesChecker.frame and RC.consumablesChecker.frame.UpdateToggleButton then
                    RC.consumablesChecker.frame.UpdateToggleButton()
                end
            end)
            cardY = cardY - 35

            countCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - countCard:GetHeight() - 15

            local customCard = self:CreateSettingsCard(parent, yPos, RCL["Custom items"])
            cardY = -32

            local customInfo = self:CreateFontString(customCard, "OVERLAY", nil, 10)
            customInfo:SetPoint("TOPLEFT", customCard, "TOPLEFT", 14, cardY)
            customInfo:SetWidth(customCard:GetWidth() - 30)
            customInfo:SetText(RCL["Add items by ID. Use arrows to reorder, right-click to change category."])
            customInfo:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 25

            local inputRow = CreateFrame("Frame", nil, customCard)
            inputRow:SetHeight(26)
            inputRow:SetPoint("TOPLEFT", customCard, "TOPLEFT", 14, cardY)
            inputRow:SetPoint("RIGHT", customCard, "RIGHT", -14, 0)

            local idLabel = self:CreateFontString(inputRow, "OVERLAY", nil, 10)
            idLabel:SetPoint("LEFT", inputRow, "LEFT", 0, 0)
            idLabel:SetText(RCL["Item ID:"])
            idLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local idEdit = self.UI:CreateBackedEditBox(inputRow, {
                width = 80, height = 22, numeric = true, maxLetters = 8,
                fontSize = 10, fontFlags = "", insets = 6,
                textColor = TEXT.white,
            })
            idEdit:SetPoint("LEFT", idLabel, "RIGHT", 8, 0)
            do
                -- Rebuilding this page destroys the editbox; restash typed text
                -- (8s TTL) so Add doesn't lose keystrokes typed right before a redraw.
                local st = RC._customIdStash
                if st and st.key == "checker" and (GetTime() - (st.at or 0)) < 8 then
                    idEdit:SetText(st.text or "")
                    local cur = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
                    if not cur then
                        idEdit:SetFocus()
                        idEdit:SetCursorPosition(#(st.text or ""))
                    end
                end
            end
            idEdit:SetScript("OnTextChanged", function(selfEB, userInput)
                if userInput then
                    RC._customIdStash = { key = "checker", text = selfEB:GetText() or "", at = GetTime() }
                end
            end)
            idEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

            local addBtn = self.UI:CreateStyledButton(inputRow, RCL["Add Item"], 70, 22)
            addBtn:SetPoint("LEFT", idEdit, "RIGHT", 8, 0)
            addBtn:SetScript("OnClick", function()
                local itemId = tonumber(idEdit:GetText())
                if itemId and itemId > 0 then
                    local success, msg = RC:AddCustomConsumableItem(itemId, "checker", "custom")
                    if success then
                        if RC.PopulateConsumablesChecker then
                            RC:PopulateConsumablesChecker()
                        end
                        RC:ShowSidebarConsumablesCheckerConfig(frame)
                    else
                        RC:Print("|cffff6666" .. (msg or "Failed to add item") .. "|r")
                    end
                    idEdit:SetText("")
                    RC._customIdStash = nil
                else
                    RC:Print(RCL["|cffff6666Please enter a valid item ID|r"])
                end
            end)
            idEdit:SetScript("OnEnterPressed", function(self)
                addBtn:Click()
            end)
            cardY = cardY - 32

            local customItemsByCategory = RC:GetCustomItemsByCategory("checker")
            local hasCustomItems = false
            for _ in pairs(customItemsByCategory) do hasCustomItems = true break end

            if hasCustomItems then
                for _, catInfo in ipairs(RC.customItemCategories or {}) do
                    local catKey = catInfo.key
                    local catItems = customItemsByCategory[catKey]

                    if catItems and #catItems > 0 then
                        local catHeader = self:CreateFontString(customCard, "OVERLAY", nil, 10)
                        catHeader:SetPoint("TOPLEFT", customCard, "TOPLEFT", 14, cardY)
                        catHeader:SetText(catInfo.name .. " (" .. #catItems .. ")")
                        catHeader:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
                        cardY = cardY - 18

                        for idx, item in ipairs(catItems) do
                            local itemId = item.id
                            local itemData = item.data

                            local itemRow = CreateFrame("Frame", nil, customCard)
                            itemRow:SetHeight(24)
                            itemRow:SetPoint("TOPLEFT", customCard, "TOPLEFT", 20, cardY)
                            itemRow:SetPoint("RIGHT", customCard, "RIGHT", -14, 0)

                            -- Reorder arrows: framework buttons (flat fill,
                            -- 1px ring, hover/disabled paint) carrying the
                            -- addon's flat arrow glyph; the glyph follows the
                            -- label colour (gold on hover, dim when disabled).
                            local function MakeArrowButton(texPath)
                                local b = self.UI:CreateStyledButton(itemRow, "", 18, 18)
                                local glyph = b:CreateTexture(nil, "ARTWORK")
                                glyph:SetSize(10, 10)
                                glyph:SetPoint("CENTER", 0, 0)
                                glyph:SetTexture(texPath)
                                b.glyph = glyph
                                local function SyncGlyph()
                                    local r, g, bb = b.text:GetTextColor()
                                    glyph:SetVertexColor(r, g, bb, 1)
                                end
                                b:HookScript("OnEnter", SyncGlyph)
                                b:HookScript("OnLeave", SyncGlyph)
                                b:HookScript("OnDisable", SyncGlyph)
                                b:HookScript("OnEnable", SyncGlyph)
                                SyncGlyph()
                                return b
                            end

                            local upBtn = MakeArrowButton("Interface\\AddOns\\Readycheck\\Media\\arrowUp")
                            upBtn:SetPoint("LEFT", itemRow, "LEFT", 0, 0)
                            upBtn:SetScript("OnClick", function()
                                if RC:MoveCustomItem(itemId, "checker", "up") then
                                    if RC.PopulateConsumablesChecker then
                                        RC:PopulateConsumablesChecker()
                                    end
                                    RC:ShowSidebarConsumablesCheckerConfig(frame)
                                end
                            end)
                            if idx == 1 then
                                upBtn:Disable()
                            end

                            local downBtn = MakeArrowButton("Interface\\AddOns\\Readycheck\\Media\\arrow")
                            downBtn:SetPoint("LEFT", upBtn, "RIGHT", 2, 0)
                            downBtn:SetScript("OnClick", function()
                                if RC:MoveCustomItem(itemId, "checker", "down") then
                                    if RC.PopulateConsumablesChecker then
                                        RC:PopulateConsumablesChecker()
                                    end
                                    RC:ShowSidebarConsumablesCheckerConfig(frame)
                                end
                            end)
                            if idx == #catItems then
                                downBtn:Disable()
                            end

                            local icon = itemRow:CreateTexture(nil, "ARTWORK")
                            icon:SetSize(18, 18)
                            icon:SetPoint("LEFT", downBtn, "RIGHT", 6, 0)
                            icon:SetTexture(itemData.icon or 134400)
                            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                            local nameText = self:CreateFontString(itemRow, "OVERLAY", nil, 10)
                            nameText:SetPoint("LEFT", icon, "RIGHT", 4, 0)
                            nameText:SetText(itemData.name or ("Item " .. itemId))
                            if itemData.pending then
                                nameText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                            else
                                nameText:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                            end

                            local catLabel = self:CreateFontString(itemRow, "OVERLAY", nil, 10)
                            catLabel:SetPoint("RIGHT", itemRow, "RIGHT", -26, 0)
                            catLabel:SetText("[" .. (catInfo.name:sub(1, 8)) .. "]")
                            catLabel:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])

                            local removeBtn = self.UI:CreateRemoveButton(itemRow, 18, function()
                                RC:RemoveCustomConsumableItem(itemId, "checker")
                                if RC.PopulateConsumablesChecker then
                                    RC:PopulateConsumablesChecker()
                                end
                                RC:ShowSidebarConsumablesCheckerConfig(frame)
                            end)
                            removeBtn:SetPoint("RIGHT", itemRow, "RIGHT", 0, 0)

                            itemRow:EnableMouse(true)
                            itemRow:SetScript("OnMouseUp", function(self, button)
                                if button == "RightButton" then
                                    local menuFrame = _sbc.GetCustomItemCategoryMenu()
                                    UIDropDownMenu_Initialize(menuFrame, function(dropdown, level)
                                        for _, cat in ipairs(RC.customItemCategories or {}) do
                                            local info = UIDropDownMenu_CreateInfo()
                                            info.text = cat.name
                                            info.checked = (itemData.category == cat.key)
                                            info.func = function()
                                                RC:SetCustomItemCategory(itemId, "checker", cat.key)
                                                if RC.PopulateConsumablesChecker then
                                                    RC:PopulateConsumablesChecker()
                                                end
                                                RC:ShowSidebarConsumablesCheckerConfig(frame)
                                            end
                                            UIDropDownMenu_AddButton(info, level)
                                        end
                                    end, "MENU")
                                    ToggleDropDownMenu(1, nil, menuFrame, "cursor", 0, 0)
                                end
                            end)

                            cardY = cardY - 26
                        end
                        cardY = cardY - 4
                    end
                end
            else
                local noItemsText = self:CreateFontString(customCard, "OVERLAY", nil, 10)
                noItemsText:SetPoint("TOPLEFT", customCard, "TOPLEFT", 14, cardY)
                noItemsText:SetText(RCL["No custom items added"])
                noItemsText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY = cardY - 20
            end

            customCard:SetContentHeight(math.abs(cardY) + 5)
            yPos = yPos - customCard:GetHeight() - 15

            local categoryOrder = {"flasks", "elixirs", "potions", "protectionPotions", "food", "drinks", "buffs", "utilities", "chronoboon", "special"}
            local categoryNames = {
                flasks = "Flasks",
                elixirs = "Battle Elixirs",
                potions = "Combat Potions",
                protectionPotions = "Protection Potions",
                food = "Food",
                drinks = "Drinks & Desserts",
                buffs = "Jujus & Buffs",
                utilities = "Utilities & Tools",
                chronoboon = "Chronoboon Displacers",
                special = "Special Items"
            }

            for _, categoryKey in ipairs(categoryOrder) do
                local category = self.raidConsumables and self.raidConsumables[categoryKey]
                if category and category.items then
                    local items = {}
                    for itemId, itemData in pairs(category.items) do
                        local isSlotSpecific = itemData.slot ~= nil
                        if not isSlotSpecific then
                            local icon = GetItemIcon(itemData.baseItemId or itemId) or 134400
                            table.insert(items, {
                                id = itemId,
                                data = itemData,
                                icon = icon
                            })
                        end
                    end

                    if #items > 0 then
                        table.sort(items, function(a, b) return (a.data.name or "") < (b.data.name or "") end)

                        local isCollapsed = self.db.consumablesChecker.collapsedCategories[categoryKey]

                        local headerBtn = _sbc.CreateCollapsibleHeader(parent, yPos,
                            categoryNames[categoryKey] or categoryKey,
                            isCollapsed, function()
                                self.db.consumablesChecker.collapsedCategories[categoryKey] = not isCollapsed
                                RC:SaveConfigurationToProfile()
                                RC:ShowSidebarConsumablesCheckerConfig(frame)
                            end, {
                                textureArrow = true,
                                hoverDelta = 0.06,
                                textColor = TEXT.goldFull,
                            })

                        local countText = self:CreateFontString(headerBtn, "OVERLAY", nil, 10)
                        countText:SetPoint("RIGHT", headerBtn, "RIGHT", -10, 0)
                        local enabledCount = 0
                        for _, item in ipairs(items) do
                            if not disabledItems[item.id] then
                                enabledCount = enabledCount + 1
                            end
                        end
                        countText:SetText(enabledCount .. "/" .. #items .. RCL[" enabled"])
                        countText:SetTextColor(TEXT.grayFull[1], TEXT.grayFull[2], TEXT.grayFull[3], TEXT.grayFull[4])

                        yPos = yPos - 32

                        if not isCollapsed then
                            local itemContainer = CreateFrame("Frame", nil, parent, "BackdropTemplate")
                            itemContainer:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
                            itemContainer:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, yPos)
                            itemContainer:SetBackdrop({
                                bgFile = "Interface\\Buttons\\WHITE8X8",
                                edgeFile = "Interface\\Buttons\\WHITE8X8",
                                edgeSize = 1,
                            })
                            do local _cb=RC:GetColor("ui","cardBackground"); itemContainer:SetBackdropColor(_cb.r,_cb.g,_cb.b,1) end
                            do local _bn=RC:GetColor("ui","borderNormal"); itemContainer:SetBackdropBorderColor(_bn.r,_bn.g,_bn.b,_bn.a or 1) end

                            local containerY = -8
                            for _, item in ipairs(items) do
                                local itemId = item.id
                                local itemData = item.data

                                local itemRow = CreateFrame("Frame", nil, itemContainer)
                                itemRow:SetHeight(24)
                                itemRow:SetPoint("TOPLEFT", itemContainer, "TOPLEFT", 10, containerY)
                                itemRow:SetPoint("RIGHT", itemContainer, "RIGHT", -10, 0)

                                local icon = itemRow:CreateTexture(nil, "ARTWORK")
                                icon:SetSize(20, 20)
                                icon:SetPoint("LEFT", itemRow, "LEFT", 0, 0)
                                icon:SetTexture(item.icon)
                                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                                local isDisabled = disabledItems[itemId]
                                local checkbox = self.UI:CreateCheckbox(itemRow, itemData.name, not isDisabled)
                                checkbox:SetPoint("LEFT", icon, "RIGHT", 5, 0)
                                checkbox:SetScript("OnClick", function(cb)
                                    local newState = cb:GetChecked()
                                    if newState then
                                        RC.db.consumablesChecker.disabledItems[itemId] = nil
                                    else
                                        RC.db.consumablesChecker.disabledItems[itemId] = true
                                    end
                                    RC:ForceCheckboxUpdate(cb, newState)
                                    RC:SaveConfigurationToProfile()
                                    if RC.consumablesChecker then
                                        RC.consumablesChecker._populated = false
                                    end
                                    if RC.consumablesChecker and RC.consumablesChecker.frame
                                            and RC.consumablesChecker.frame:IsShown() then
                                        RC:PopulateConsumablesChecker()
                                    end
                                end)

                                local isPrio = (RC.db.consumablesChecker.priorityItems or {})[itemId] and true or false
                                local prioCb = self.UI:CreateCheckbox(itemRow, "", isPrio)
                                -- (off its holder first: pinned by LEFT to an unplaced
                                -- holder and RIGHT to the row it stretched across the page)
                                prioCb:ClearAllPoints()
                                prioCb:SetPoint("RIGHT", itemRow, "RIGHT", -110, 0)
                                prioCb:SetScript("OnClick", function(cb)
                                    local v = cb:GetChecked() and true or nil
                                    if not RC.db.consumablesChecker.priorityItems then
                                        RC.db.consumablesChecker.priorityItems = {}
                                    end
                                    RC.db.consumablesChecker.priorityItems[itemId] = v
                                    RC:ForceCheckboxUpdate(cb, v and true or false)
                                    RC:SaveConfigurationToProfile()
                                end)

                                local prioLabel = self:CreateFontString(itemRow, "OVERLAY", nil, 10)
                                prioLabel:SetPoint("RIGHT", prioCb, "LEFT", -6, 0)
                                prioLabel:SetText(RCL["Priority"])
                                prioLabel:SetTextColor(TEXT.grayFull[1], TEXT.grayFull[2], TEXT.grayFull[3], TEXT.grayFull[4])

                                local recLabel = self:CreateFontString(itemRow, "OVERLAY", nil, 10)
                                recLabel:SetPoint("RIGHT", itemRow, "RIGHT", -48, 0)
                                recLabel:SetText(RCL["Want:"])
                                recLabel:SetTextColor(TEXT.grayFull[1], TEXT.grayFull[2], TEXT.grayFull[3], TEXT.grayFull[4])

                                local recEdit = self.UI:CreateBackedEditBox(itemRow, {
                                    width = 40, height = 18, numeric = true, maxLetters = 4,
                                    fontSize = 10, fontFlags = "", insets = 4,
                                    justify = "CENTER", textColor = TEXT.white,
                                })
                                recEdit:SetPoint("RIGHT", itemRow, "RIGHT", 0, 0)

                                local currentRec = self:GetRecommendedCount(itemId, itemData)
                                recEdit:SetText(tostring(currentRec))

                                local isCustom = self.db.consumablesChecker.customRecommended and self.db.consumablesChecker.customRecommended[itemId]
                                if isCustom then
                                    recEdit:SetTextColor(TEXT.orange[1], TEXT.orange[2], TEXT.orange[3], TEXT.orange[4])
                                end

                                recEdit:SetScript("OnEscapePressed", function(self)
                                    self:ClearFocus()
                                    self:SetText(tostring(RC:GetRecommendedCount(itemId, itemData)))
                                end)
                                recEdit:SetScript("OnEnterPressed", function(self)
                                    local value = tonumber(self:GetText()) or 0
                                    RC:SetRecommendedCount(itemId, value)
                                    self:ClearFocus()
                                    local isNowCustom = RC.db.consumablesChecker.customRecommended and RC.db.consumablesChecker.customRecommended[itemId]
                                    if isNowCustom then
                                        self:SetTextColor(TEXT.orange[1], TEXT.orange[2], TEXT.orange[3], TEXT.orange[4])
                                    else
                                        self:SetTextColor(TEXT.white[1], TEXT.white[2], TEXT.white[3], TEXT.white[4])
                                    end
                                end)
                                recEdit:SetScript("OnEditFocusGained", function(self)
                                    self:HighlightText()
                                    local hoverCol = RC:GetColor("ui", "borderHover")
                                    if recEdit.bg then recEdit.bg:SetBackdropBorderColor(hoverCol.r, hoverCol.g, hoverCol.b, 1) end
                                end)
                                recEdit:SetScript("OnEditFocusLost", function(self)
                                    local bn = RC:GetColor("ui", "borderNormal")
                                    if recEdit.bg then recEdit.bg:SetBackdropBorderColor(bn.r, bn.g, bn.b, bn.a or 1) end
                                    self:SetText(tostring(RC:GetRecommendedCount(itemId, itemData)))
                                end)

                                containerY = containerY - 26
                            end

                            itemContainer:SetHeight(math.abs(containerY) + 8)
                            yPos = yPos - itemContainer:GetHeight() - 4
                        end
                    end
                end
            end
        end

        if currentTab == "look" then yPos = BuildMustHaveLook(self, frame, parent, yPos) end
        if currentTab == "text" then
            yPos = BuildCheckerRowsText(self, frame, parent, yPos)
            yPos = BuildMustHaveText(self, frame, parent, yPos)
        end
        if currentTab == "animation" then yPos = BuildMustHaveAnimation(self, frame, parent, yPos, P) end
        -- the checker window: fade (Behavior), shadow and glow (Look), layer (Position)
        yPos = self.UI:FrameCardsForTab(currentTab, parent, yPos, function() return RC.db.consumablesChecker end, function()
            local f = RC.consumablesChecker and RC.consumablesChecker.frame
            if f then RC:ApplyFrameCustom(f, function() return RC.db and RC.db.consumablesChecker end,
                { parts = { bg = f.bg, border = f.border } }) end
        end, { prefix = RCL["Checker window "], chromeFields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true },
            visibilityNote = RCL["On top of when it opens: a rule that is not met fades it out."] })

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
        if preserveScroll then
            self:RestoreScrollPosition(self.sidebarConfigFrame)
        end
    end
