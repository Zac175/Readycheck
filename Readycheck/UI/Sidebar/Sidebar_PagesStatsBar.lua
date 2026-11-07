------------------------------------------------------------------------
-- Readycheck - Character Stats Bar, Buff Pushoff
-- Character Stats Bar (db.showStatsBar, statsBar*) and Buff Pushoff
-- Alert (db.buffPushoffAlert.*) sidebar pages.
-- Split out of Sidebar_PagesReminders.lua when the reminder stack moved
-- to Readycheck_Reminders: neither page is a reminder page, and both
-- have to stay reachable with that addon switched off.
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

    local K = RC._disp

    -- STATS BAR PREVIEW: the real bar (CS:NewBarPreview / FillBarPreview,
    -- the same BuildBarStats as the live one) with representative values.
    -- Strong / weak show both ends of each stat's colour range.
    local STATS_FAKE = {
        strong = { buffs = 24, hit = 6.0, crit = 31.5, ap = 2650, dmg = 112, sp = 640, hp = 980, sdmg = 640,
                   spellcrit = 12.5, mp5 = 64, rap = 1700, rcrit = 27.0, fps = 144, ms = 38, durability = 100, gold = 2350 },
        weak   = { buffs = 31, hit = 1.0, crit = 12.0, ap = 900, dmg = 60, sp = 120, hp = 200, sdmg = 120,
                   spellcrit = 4.0, mp5 = 8, rap = 600, rcrit = 9.0, fps = 28, ms = 310, durability = 22, gold = 40 },
    }
    local SB_W, SB_H = 440, 70

    local function LiveValues()
        local CS = RC.CharacterStats
        local defs = RC._css and RC._css.STAT_DEFS
        local out = {}
        if not (CS and defs) then return out end
        for _, s in ipairs(CS:GetStatList()) do
            local def = defs[s.key]
            if def and def.get then
                local ok, v = pcall(def.get, CS)
                if ok and type(v) == "number" then out[s.key] = math_floor(v * 10 + 0.5) / 10 end
            end
        end
        return out
    end

    -- The buff list a click on the Buffs cell opens (CS_BuffList.lua's own
    -- frame and fill): a buff of each badge (Keep / Remove / can't remove /
    -- its kind), a hidden slot, one slot free.
    local I = "Interface\\Icons\\"
    local function BuffListFake(now)
        return {
            items = {
                { a = { name = "Flask of the Titans", icon = I .. "INV_Potion_62", exp = now + 5400, e = { cat = "cons" } }, state = "k" },
                { a = { name = "Battle Shout", icon = I .. "Ability_Warrior_BattleShout", exp = now + 95, e = { cat = "self" } }, state = "s" },
                { a = { name = "Blessing of Wisdom", icon = I .. "Spell_Holy_SealOfWisdom", exp = now + 240, e = { cat = "raid" } }, state = "r" },
                { a = { name = "Inner Fire", icon = I .. "Spell_Holy_InnerFire", exp = now + 420, e = { cat = "fun" } } },
            },
            hidden = {
                { label = RCL["Battle Stance"], src = "stance", icon = I .. "Ability_Warrior_OffensiveStance" },
            },
            free = 1, cap = 32, realCap = 32, now = now,
            hint = RCL["Click a buff to keep or remove it. Shift-click Buffs to pause."],
        }
    end

    local function StatsPreviewBuild(canvas, P)
        local CS = RC.CharacterStats
        if not (CS and CS.NewBarPreview) then return end
        P.store.pv = CS:NewBarPreview(canvas)
        if CS.NewBuffListSample then
            P.store.list = CS.NewBuffListSample(canvas)
            P.store.list:Hide()
        end
    end

    local function StatsPreviewUpdate(canvas, P)
        local CS, pv = RC.CharacterStats, P.store.pv
        if not (CS and pv) then return end
        local list = P.store.list
        if P.mode == "buffs" and list then
            pv.barFrame:Hide()
            local w, h = CS.FillBuffListSample(list, BuffListFake(GetTime()))
            P.Resize((w or 260) + 8, (h or 120) + 8)
            list:ClearAllPoints()
            list:SetPoint("CENTER", canvas, "CENTER", 0, 0)
            list:Show()
            return
        end
        if list then list:Hide() end
        local values = (P.mode == "live") and LiveValues() or STATS_FAKE[P.mode or "strong"] or STATS_FAKE.strong
        local w, h = CS:FillBarPreview(pv, values)
        local f = pv.barFrame
        -- the bar at its real size; the canvas is its box, the strip scales it
        f:SetScale(1)
        P.Resize((w or SB_W) + 8, (h or SB_H) + 8)
        f:ClearAllPoints()
        f:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        f:Show()
    end

    -- Coalesced: a slider drag rebuilds the live bar once per frame.
    local ApplyStatsBar = RC.UI:Coalesce(function()
        local CS = RC.CharacterStats
        if CS and CS.barFrame and CS.RefreshStatsBar then CS:RefreshStatsBar() end
    end)

    local function StatsLook() return K.Look(RC.db, "statsBarLook") end

    -- old tab keys (and the search aliases) land on the new tabs
    local STATS_TAB_ALIAS = { general = "behavior", display = "look", alert = "behavior" }

    function RC:ShowSidebarStatsBar(frame, selectedTab)
        self:ClearSidebarContent(self.sidebarConfigFrame, selectedTab ~= nil)
        if RC.statsBarTab then
            selectedTab = RC.statsBarTab
            RC.statsBarTab = nil
        end
        selectedTab = selectedTab or frame.statsBarTab or "behavior"
        selectedTab = STATS_TAB_ALIAS[selectedTab] or selectedTab
        frame.statsBarTab = selectedTab
        local parent = frame.scrollChild
        local yPos = -20
        local cardY = -32

        self.UI:DeclarePreview({
            key = "statsbar.bar", title = RCL["Character Stats Bar"],
            width = SB_W, height = SB_H,
            build = StatsPreviewBuild, update = StatsPreviewUpdate,
            modes = { { id = "strong", label = RCL["Strong"] }, { id = "weak", label = RCL["Weak"] },
                      { id = "live", label = RCL["Your stats"] }, { id = "buffs", label = RCL["Buff list"] } },
        })

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Character Stats Bar"],
            RCL["Displays your character's stats at the top of screen"], "Interface\\Icons\\INV_Misc_Spyglass_03")
        yPos = newY

        yPos = K.Tabs(parent, yPos, {
            { "behavior", RCL["Behavior"] }, { "stats", RCL["Stats"] }, { "gold", RCL["Gold"] },
            { "look", RCL["Look"] }, { "text", RCL["Text"] }, { "position", RCL["Position"] },
        }, selectedTab, function(tk)
            frame.statsBarTab = tk
            RC:ShowSidebarStatsBar(frame, tk)
        end)

        local CS0 = self.CharacterStats
        if selectedTab == "gold" then
            if self.BuildGoldCard then
                yPos = self:BuildGoldCard(parent, yPos, frame)
            end
        elseif selectedTab == "behavior" then
            yPos = K.Card(parent, yPos, RCL["Display"], function(card, y)
                y = K.Check(card, y, RCL["Enable stats bar"],
                    function() return self.db.showStatsBar end,
                    function(newState)
                        self.db.showStatsBar = newState
                        local CS = self.CharacterStats
                        if CS then
                            if newState then
                                CS:CreateStatsBar()
                                if CS.barFrame then CS.barFrame:Show() end
                            elseif CS.barFrame then
                                CS.barFrame:Hide()
                            end
                            if CS.UpdateBuffCapWant then CS:UpdateBuffCapWant() end
                        end
                    end,
                    RCL["A thin bar of your attack power, crit, hit and the rest, with buff slots and durability. Pick the stats on the Stats tab."])
                y = K.Check(card, y, RCL["Show stats button in character pane"],
                    function() return self.db.showStatsButton or false end,
                    function(newState)
                        self.db.showStatsButton = newState
                        local CS = self.CharacterStats
                        if CS then
                            if newState then CS:ShowStatsButton() else CS:HideStatsButton() end
                        end
                    end,
                    RCL["A small button on the character window that opens the full stats panel."])
                return y
            end)
            yPos = self.UI:FrameVisibilityCard(parent, yPos, function() return StatsLook() end, ApplyStatsBar)
        elseif selectedTab == "look" then
            yPos = K.Card(parent, yPos, RCL["Size"], function(card, y)
                y = K.Slider(card, y, RCL["Bar height"], 14, 40, self.db.statsBarHeight or 20, 1,
                    function(v) return v .. RCL[" px"] end,
                    function(v) self.db.statsBarHeight = v ApplyStatsBar() end)
                y = K.Slider(card, y, RCL["Space between stats"], 2, 24, self.db.statsBarSpacing or 10, 1,
                    function(v) return v .. RCL[" px"] end,
                    function(v) self.db.statsBarSpacing = v ApplyStatsBar() end)
                return K.Desc(card, y + 6, RCL["Height of the bar, and the padding either side of each stat."])
            end)
            yPos = K.Card(parent, yPos, RCL["Background"], function(card, y)
                local bgCb, borderCb, bgTex, bgCol, borderCol
                y, bgCb = K.Check(card, y, RCL["Show background"],
                    function() return self.db.statsBarShowBg ~= false end,
                    function(v) self.db.statsBarShowBg = v ApplyStatsBar() end)
                y, borderCb = K.Check(card, y, RCL["Show border"],
                    function()
                        local b = StatsLook().showBorder
                        if b == nil then return self.db.statsBarShowBg ~= false end
                        return b and true or false
                    end,
                    function(v) StatsLook().showBorder = v ApplyStatsBar() end,
                    RCL["The thin edge around the bar. Until you set it, it comes and goes with the background."])
                y, bgTex = K.BgTexture(card, y, RCL["Background texture"],
                    function() return StatsLook().bgTexture end,
                    function(v) StatsLook().bgTexture = v ApplyStatsBar() end,
                    function() local c = RC:GetColor("statsBar", "background") return c.r, c.g, c.b end)
                y, bgCol = K.ThemeColor(card, y, RCL["Background colour"], "statsBar", "background", ApplyStatsBar)
                y, borderCol = K.LookColor(card, y, RCL["Border colour"], StatsLook, "borderColor",
                    function() return RC:GetColor("ui", "borderNormal") end, ApplyStatsBar, true)
                y = K.ThemeColor(card, y, RCL["Separators"], "statsBar", "separator", ApplyStatsBar)
                -- the fill's look only matters with the fill shown, the
                -- border's colour with the border shown
                self.UI:BindDependents(bgCb, { bgTex, bgCol })
                self.UI:BindDependents(borderCb, { borderCol })
                return y - 4
            end)
            yPos = K.Card(parent, yPos, RCL["Value colours"], function(card, y)
                y = K.Desc(card, y, RCL["Each value is coloured along its own range, from its low colour to its high one. Edit the ranges under Appearance > Colors > Stats Bar; the preview shows them on Strong and Weak."])
                local btn = self.UI:CreateStyledButton(card, RCL["Open stat colours"], 150, 22)
                btn:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                btn:SetScript("OnClick", function()
                    if self.SelectSidebarItem then
                        self:SelectSidebarItem(self.sidebarConfigFrame, { id = "font_settings", panel = "ShowSidebarFontSettings" }, nil)
                    end
                end)
                return y - 32
            end)
            yPos = self.UI:FrameChromeCard(parent, yPos, function() return StatsLook() end, ApplyStatsBar,
                { title = RCL["Shadow and glow"], fields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })
        elseif selectedTab == "text" then
            yPos = K.Card(parent, yPos, RCL["Text"], function(card, y)
                y = K.Font(card, y, RCL["Values"],
                    function()
                        local s = K.CopySpec(StatsLook().valueFont)
                        s.size = self.db.statsBarFontSize or 12
                        return s
                    end,
                    function(spec)
                        -- size stays on the key the bar has always read
                        self.db.statsBarFontSize = spec.size or self.db.statsBarFontSize
                        spec.size = nil
                        StatsLook().valueFont = spec
                        ApplyStatsBar()
                    end,
                    { size = 12 }, "AP 2650   CRIT 31.5%", 8, 20)
                y = K.Font(card, y, RCL["Labels"],
                    function() return StatsLook().labelFont end,
                    function(spec) StatsLook().labelFont = spec ApplyStatsBar() end,
                    { size = (self.db.statsBarFontSize or 12) - 1 }, "BUFFS  HIT  CRIT  AP", 6, 20)
                y = K.Desc(card, y + 4, RCL["Labels are one point smaller than the values until you give them a size of their own."])
                y = K.ThemeColor(card, y, RCL["Label colour"], "statsBar", "labelText", ApplyStatsBar)
                return y - 4
            end)
            -- where each cell's label, value and the push-off icon sit, and
            -- how the values read (the customization standard)
            yPos = K.Card(parent, yPos, RCL["Text positions"], function(card, y)
                local CSx = self.CharacterStats
                local cw = card:GetWidth() or 0
                local W = (cw > 240) and math.min(460, cw - 28) or 420
                local function Root() if type(self.db.statsBarLook) ~= "table" then self.db.statsBarLook = {} end return self.db.statsBarLook end
                local function After() self:SaveConfigurationToProfile() ApplyStatsBar() end
                local function Others(ex)
                    local out = {}
                    for _, t in ipairs(CSx and CSx.ANCHOR_TARGETS or {}) do if t.value ~= ex then out[#out + 1] = t end end
                    return out
                end
                local function Place(g) g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y) y = y - g:GetHeight() - 14 end
                local ag, as = self.UI:CustomAccess(Root, "anchors", "label", After)
                Place(self.UI:CreateTextElement(card, { label = RCL["Labels"], key = "label", width = W,
                    anchorGet = ag, anchorSet = as, targets = Others("label"),
                    anchorDefaults = function() return CSx:CellAnchorDefault("label") end }))
                ag, as = self.UI:CustomAccess(Root, "anchors", "value", After)
                local fg, fs = self.UI:CustomAccess(Root, "formats", "value", After)
                Place(self.UI:CreateTextElement(card, { label = RCL["Values"], key = "value", width = W,
                    formatGet = fg, formatSet = fs, formatKinds = { number = true, percent = true },
                    formatDefaults = CSx and CSx.VALUE_FORMAT_DEFAULTS,
                    formatSample = function(spec)
                        local look = Root()
                        local old = look.formats
                        look.formats = { value = spec }
                        local a, b = CSx:FormatBarValue(31.5, "31.5%"), CSx:FormatBarValue(2650, "2650")
                        look.formats = old
                        return a .. "   " .. b
                    end,
                    anchorGet = ag, anchorSet = as, targets = Others("value"),
                    anchorDefaults = function() return CSx:CellAnchorDefault("value") end }))
                ag, as = self.UI:CustomAccess(Root, "anchors", "pushoff", After)
                Place(self.UI:CreateFrameElement(card, { label = RCL["Push-off icon (Buffs cell)"], key = "pushoff", width = W,
                    anchorGet = ag, anchorSet = as, targets = Others(nil),
                    anchorDefaults = function() return CSx:CellAnchorDefault("pushoff") end }))
                return K.Desc(card, y + 4, RCL["One place for every cell. Reset puts a text back where it always sat."])
            end)
        elseif selectedTab == "position" then
            yPos = K.Card(parent, yPos, RCL["Position"], function(card, y)
                y = K.Check(card, y, RCL["Lock position (or right-click bar)"],
                    function() return self.db.statsBarLocked end,
                    function(v)
                        self.db.statsBarLocked = v
                        local CS = self.CharacterStats
                        if CS and CS.barFrame then CS.barFrame:SetMovable(not v) end
                    end,
                    RCL["Unlocked, drag the bar anywhere. Right-click it to lock or unlock."])
                local bar = CS0 and CS0.barFrame
                if bar and RC.Position.IsBound(bar) then
                    local x0, y0 = RC.Position.Capture(bar, "TOP")
                    local P = RC.Position
                    y = K.Offsets(card, y, function() return x0 or 0 end, function() return y0 or 0 end,
                        function(x, yy)
                            local cx, cy = P.Capture(bar, "TOP")
                            P.SetFrame(bar, x or cx or 0, yy or cy or 0)
                        end, 1200)
                    local reset = self.UI:CreateStyledButton(card, RCL["Reset position"], 120, 22)
                    reset:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                    reset:SetScript("OnClick", function()
                        P.ResetFrame(bar)
                        RC:ShowSidebarStatsBar(frame, "position")
                    end)
                    local em = self.UI:CreateStyledButton(card, RCL["Edit Mode"], 100, 22)
                    em:SetPoint("LEFT", reset, "RIGHT", 6, 0)
                    em:SetScript("OnClick", function()
                        if RC.UIMover and RC.UIMover.EnterMoveMode then RC.UIMover:EnterMoveMode() end
                    end)
                    y = y - 32
                else
                    y = K.Desc(card, y, RCL["Turn the bar on (Behavior tab) to place it here, or drag it on screen."])
                end
                return y
            end)
            yPos = self.UI:FrameLayerCard(parent, yPos, function() return StatsLook() end, ApplyStatsBar)
        else
        local CS = self.CharacterStats
        if CS and CS.GetAllStatOptions then
            local statsCard = self:CreateSettingsCard(parent, yPos, RCL["Stats"])
            cardY = -32

            local defs = RC._css and RC._css.STAT_DEFS
            local options = CS:GetAllStatOptions()
            local nAll = #options

            local oInfo = self:CreateFontString(statsCard, "OVERLAY", nil, 10)
            oInfo:SetPoint("TOPLEFT", statsCard, "TOPLEFT", 14, cardY)
            oInfo:SetWidth(300); oInfo:SetJustifyH("LEFT")
            oInfo:SetText(RCL["Tick a stat to show it. Drag a row (or use the arrows) - top = left end of the bar."])
            oInfo:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
            cardY = cardY - 24

            local SD = self._statDrag
            if not SD then
                SD = { active = false, from = nil, to = nil, rows = {} }
                self._statDrag = SD
                local poll = CreateFrame("Frame", "WRStatDragPoll", UIParent)
                poll:Hide()
                local ind = CreateFrame("Frame", "WRStatDragIndicator", UIParent)
                ind:SetHeight(2)
                ind:SetFrameStrata("TOOLTIP")
                local it = ind:CreateTexture(nil, "OVERLAY")
                it:SetAllPoints()
                local agi = RC:GetColor("ui", "accentGold")
                it:SetColorTexture(agi.r, agi.g, agi.b, 0.9)
                ind:Hide()
                SD.poll = poll
                SD.indicator = ind
                poll:SetScript("OnUpdate", function(pf)
                    if not SD.active then
                        SD.indicator:Hide()
                        pf:Hide()
                        return
                    end
                    local rows = SD.rows
                    local n = #rows
                    local _, cy = GetCursorPosition()
                    local scale = UIParent:GetEffectiveScale()
                    if n > 0 and scale and scale > 0 then
                        local cursorY = cy / scale
                        -- slot = index of the first row whose top edge is below the
                        -- cursor; stays n+1 (append) if the cursor is past the last row.
                        local slot = n + 1
                        for i = 1, n do
                            local top = rows[i] and rows[i]:GetTop()
                            if top and cursorY >= top - 12 then
                                slot = i
                                break
                            end
                        end
                        SD.to = slot
                        local anchor = rows[math.min(slot, n)]
                        local top = anchor and anchor:GetTop()
                        local left = rows[1] and rows[1]:GetLeft()
                        local right = rows[1] and rows[1]:GetRight()
                        if top and left and right then
                            local y = (slot > n) and (top - 24) or top
                            SD.indicator:ClearAllPoints()
                            SD.indicator:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, y)
                            SD.indicator:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", right, y)
                            SD.indicator:Show()
                        end
                    end
                    if not IsMouseButtonDown("LeftButton") then
                        SD.indicator:Hide()
                        local from, to = SD.from, SD.to
                        SD.active = false
                        pf:Hide()
                        if from and to and to ~= from and to ~= from + 1 then
                            CS:MoveStatTo(from, to)
                        end
                        if SD.refresh then SD.refresh() end
                    end
                end)
            end
            SD.rows = {}
            SD.frame = frame
            SD.active = false

            local gtd = RC:GetColor("text", "disabled")
            local ag = RC:GetColor("ui", "accentGold")
            local da = RC:GetColor("dropdown", "arrow")

            local rows = {}
            local Refresh

            -- the pane's sample is the real bar; a change of order or of the
            -- ticked stats redraws it (the checkboxes signal by themselves)
            local function RefreshPreview()
                self.UI:NotifySettingChanged("stats")
            end

            local function MakeArrow(row, texName, yOff)
                local b = CreateFrame("Button", nil, row)
                b:SetSize(12, 10)
                b:SetPoint("RIGHT", row, "RIGHT", -6, yOff)
                local a = b:CreateTexture(nil, "ARTWORK")
                a:SetSize(8, 8)
                a:SetPoint("CENTER", 0, 0)
                a:SetTexture("Interface\\AddOns\\Readycheck\\Media\\" .. texName)
                a:SetVertexColor(da.r, da.g, da.b, 1)
                RC.UI:AddArrowBorder(a)
                b:SetScript("OnEnter", function() a:SetVertexColor(ag.r, ag.g, ag.b, 1) end)
                b:SetScript("OnLeave", function() a:SetVertexColor(da.r, da.g, da.b, 1) end)
                return b
            end

            for i = 1, nAll do
                local row = CreateFrame("Button", nil, statsCard)
                row:SetHeight(22)
                row:SetPoint("TOPLEFT", statsCard, "TOPLEFT", 10, cardY + 4)
                row:SetPoint("TOPRIGHT", statsCard, "TOPRIGHT", -10, cardY + 4)
                rows[i] = row
                local rbg = row:CreateTexture(nil, "BACKGROUND")
                rbg:SetAllPoints()
                rbg:SetTexture(RC.UI.FLAT)
                rbg:SetVertexColor(gtd.r, gtd.g, gtd.b, 0)
                row.bg = rbg

                row:SetScript("OnEnter", function(r)
                    if r.shownIdx then
                        local _hb = RC:GetColor("buttons", "hoverBackground")
                        rbg:SetVertexColor(_hb.r, _hb.g, _hb.b, 1)
                    end
                end)
                row:SetScript("OnLeave", function()
                    rbg:SetVertexColor(gtd.r, gtd.g, gtd.b, 0)
                end)

                local cb = self.UI:CreateCheckbox(row, "", false)
                cb:SetPoint("LEFT", row, "LEFT", 2, 0)
                row.cb = cb
                cb:SetScript("OnClick", function(box)
                    local on = box:GetChecked()
                    RC:ForceCheckboxUpdate(box, on)
                    SD.active = false
                    if row.key then CS:SetStatEnabled(row.key, on) end
                    if Refresh then Refresh() end
                end)

                local lbl = self:CreateFontString(row, "OVERLAY", nil, 11)
                lbl:SetPoint("LEFT", row, "LEFT", 26, 0)
                row.lbl = lbl

                row:SetScript("OnMouseDown", function(r)
                    if not r.shownIdx then return end
                    SD.active = true
                    SD.from = r.shownIdx
                    SD.to = r.shownIdx
                    SD.poll:Show()
                end)

                row.up = MakeArrow(row, "arrowUp", 5)
                row.dn = MakeArrow(row, "arrow", -5)
                local idx = i
                row.up:SetScript("OnClick", function()
                    SD.active = false
                    CS:MoveStatTo(idx, idx - 1)
                    if Refresh then Refresh() end
                end)
                row.dn:SetScript("OnClick", function()
                    SD.active = false
                    CS:MoveStatTo(idx, idx + 2)
                    if Refresh then Refresh() end
                end)

                cardY = cardY - 24
            end

            Refresh = function(quiet)
                local shown = CS:GetStatList()
                local nShown = #shown
                local shownKeys = {}
                for _, s in ipairs(shown) do shownKeys[s.key] = true end
                local view = {}
                for _, s in ipairs(shown) do view[#view + 1] = s end
                for _, opt in ipairs(options) do
                    if not shownKeys[opt.key] then view[#view + 1] = opt end
                end
                SD.rows = {}
                for i = 1, nAll do
                    local row = rows[i]
                    local v = view[i]
                    if v then
                        local isShown = i <= nShown
                        row.key = v.key
                        row.shownIdx = isShown and i or nil
                        row.lbl:SetText(v.label)
                        if isShown then
                            row.lbl:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])
                            SD.rows[i] = row
                        else
                            row.lbl:SetTextColor(gtd.r, gtd.g, gtd.b)
                        end
                        RC:ForceCheckboxUpdate(row.cb, isShown)
                        if isShown and i > 1 then row.up:Show() else row.up:Hide() end
                        if isShown and i < nShown then row.dn:Show() else row.dn:Hide() end
                        row.bg:SetVertexColor(gtd.r, gtd.g, gtd.b, 0)
                        row:Show()
                    else
                        row.key = nil
                        row.shownIdx = nil
                        row:Hide()
                    end
                end
                if not quiet then RefreshPreview() end
            end
            SD.refresh = Refresh
            Refresh(true)

            statsCard:SetContentHeight(math.abs(cardY) + 6)
            yPos = yPos - statsCard:GetHeight() - 15
        end
        end

        if self.UpdateSidebarScrollbar then
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
        end
    end

    -- PUSHOFF ALERT PREVIEW: the real alert (CS:NewPushoffAlertFrame +
    -- LayoutPushoffAlert, the same drawing as the live one) with sample
    -- buffs; Replay plays its entrance, a beat, then its exit.
    local PUSH_SAMPLES = {
        one = { { name = "Flask of the Titans", icon = "Interface\\Icons\\INV_Potion_62", by = { "Battle Shout" } } },
        several = {
            { name = "Rallying Cry of the Dragonslayer", icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01", by = { "Blessing of Kings" } },
            { name = "Spirit of Zandalar", icon = "Interface\\Icons\\Ability_Creature_Poison_05" },
        },
    }
    -- the alert at its real size; update sizes the canvas to it (one buff
    -- is about 290 x 56, several stack as the real alert does)
    local PO_W, PO_H = 300, 62

    local function PushSettings()
        local a = RC.db.buffPushoffAlert
        return type(a) == "table" and a or {}
    end
    local function PushLook() return K.Look(PushSettings(), "look") end

    local function PushPreviewBuild(canvas, P)
        local CS = RC.CharacterStats
        if not (CS and CS.NewPushoffAlertFrame) then return end
        P.store.frame = CS:NewPushoffAlertFrame(canvas)
        P.store.token = 0
    end
    local function PushPreviewUpdate(canvas, P)
        local CS, f = RC.CharacterStats, P.store.frame
        if not (CS and f) then return end
        -- re-laying out mid-animation would fight the replay's rest
        RC.Motion.Stop(f)
        CS:LayoutPushoffAlert(f, PUSH_SAMPLES[P.mode or "one"] or PUSH_SAMPLES.one, PushSettings())
        f:SetScale(1)
        P.Resize(f:GetWidth() + 6, f:GetHeight() + 6)
        f:ClearAllPoints()
        f:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        f:Show()
    end
    local function PushPreviewReplay(canvas, P)
        local CS, f = RC.CharacterStats, P.store.frame
        if not (CS and f) then return end
        local M = RC.Motion
        P.store.token = P.store.token + 1
        local t = P.store.token
        M.Stop(f)
        f:Hide()
        local inSpec = M.Normalize(PushLook().showAnim, CS.PUSHOFF_SHOW_ANIM)
        M.Show(f, inSpec)
        local hold = M.Duration(inSpec.duration) + M.Duration(inSpec.delay or 0) + 1.2
        C_Timer.After(hold, function()
            if t ~= P.store.token or not f:IsVisible() then return end
            local outSpec = M.Normalize(PushLook().hideAnim, CS.PUSHOFF_HIDE_ANIM)
            M.Hide(f, outSpec)
            C_Timer.After(M.Duration(outSpec.duration) + M.Duration(outSpec.delay or 0) + 0.4, function()
                if t ~= P.store.token then return end
                M.Stop(f)
                if canvas:IsVisible() then f:Show() end
            end)
        end)
    end

    local function ApplyPushLive()
        local CS = RC.CharacterStats
        if CS and CS.alertFrame and CS.alertFrame:IsShown() and CS.LayoutPushoffAlert then
            CS:LayoutPushoffAlert(CS.alertFrame, PUSH_SAMPLES.one, PushSettings())
        end
    end

    function RC:ShowSidebarBuffPushoffConfig(frame, selectedTab)
        self:ClearSidebarContent(self.sidebarConfigFrame, selectedTab ~= nil)
        local parent = frame.scrollChild
        local yPos = -20
        local cardY = -32
        local tab = selectedTab or frame.pushoffTab or "behavior"
        frame.pushoffTab = tab

        -- the alert card used to fill these when missing; keep doing it
        -- before anything reads the table
        if not self.db.buffPushoffAlert then
            self.db.buffPushoffAlert = {
                enabled = false, locked = false, showBackground = true, showIcon = true, showText = true,
                textFormat = "%s pushed off!", duration = 3, fontSize = 18,
                anchorPoint = "CENTER", xOffset = 0, yOffset = 150,
            }
        end
        local A = self.db.buffPushoffAlert

        local P = self.UI:DeclarePreview({
            key = "buffpushoff.alert", title = RCL["Buff Pushoff Alert"],
            width = PO_W, height = PO_H,
            build = PushPreviewBuild, update = PushPreviewUpdate, replay = PushPreviewReplay,
            modes = { { id = "one", label = RCL["One buff"] }, { id = "several", label = RCL["Several"] } },
        })

        -- Classic Era's limit is 32; another version's is measured (CS_BuffCap)
        local eraCap = self:Flavor() == "era"
        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Buff Pushoff"],
            eraCap and RCL["Track buffs about to fall off the 32-buff limit and warn before they drop"]
                or RCL["Track buffs about to fall off the buff limit and warn before they drop"],
            "Interface\\Icons\\Spell_ChargePositive")
        yPos = newY

        yPos = K.Tabs(parent, yPos, {
            { "behavior", RCL["Behavior"] }, { "history", RCL["History"] }, { "look", RCL["Look"] },
            { "text", RCL["Text"] }, { "animation", RCL["Animation"] }, { "sound", RCL["Sound"] },
            { "position", RCL["Position"] },
        }, tab, function(k)
            frame.pushoffTab = k
            RC:ShowSidebarBuffPushoffConfig(frame, k)
        end)
        -- THE COUNTER (RC.BuffCap): hidden slots, learning, the chat line,
        -- and what the Buffs cell shows.
        local BC = self.BuffCap
        if BC then
            local function Cap()
                if type(self.db.buffCap) ~= "table" then
                    self.db.buffCap = { countHidden = true, learn = true, chatWarn = true, barText = "used" }
                end
                return self.db.buffCap
            end
            local function Changed()
                BC:SettingsChanged()
                local CS = self.CharacterStats
                if CS then
                    if CS.UpdateBuffCapWant then CS:UpdateBuffCapWant() end
                    if CS.statCache then CS.statCache.buffs = nil end
                    if CS.barFrame and CS.barFrame:IsShown() and CS.PaintBuffCapCell then
                        if CS:PaintBuffCapCell(BC:Current()) then CS:LayoutBarStats() end
                    end
                end
                self:SaveConfigurationToProfile()
            end
            local function Bound(key)
                return function() return BC:Setting(key) and true or false end,
                       function(v) Cap()[key] = v and true or false end
            end

            if tab == "behavior" then
            local capCard = self:CreateSettingsCard(parent, yPos, RCL["Buff cap counter"])
            cardY = -32
            if eraCap then
            cardY = RC.UI:CreateHelpLine(capCard, 14, cardY, RCL["The Buffs cell counts every one of the 32 buff slots, including the ones that never show an icon: a warrior's stance, the Defensive State after a dodge, parry or block, tracking, druid form passives, the second effect of some trinkets and a few worn items. Click the cell for the full list."],
                { short = RCL["The Buffs cell counts all 32 buff slots, hidden ones too. Click it for the list."], title = RCL["Buff cap"] })
            else
            cardY = RC.UI:CreateHelpLine(capCard, 14, cardY, RCL["The Buffs cell counts every buff slot in use, including the ones that never show an icon: a warrior's stance, the Defensive State after a dodge, parry or block, tracking and druid form passives. This version's buff limit is measured on this character the first time a buff gets pushed off; until then the cell shows the slots used. Click the cell for the full list."],
                { short = RCL["The Buffs cell counts every buff slot, hidden ones too; the limit is measured at the first push-off."], title = RCL["Buff cap"] })
            end

            local function Check(key, label)
                local getter, setter = Bound(key)
                local cb = self.UI:CreateSettingCheckbox(capCard, cardY, label, getter(), function(box)
                    local newState = box:GetChecked()
                    setter(newState)
                    self:ForceCheckboxUpdate(box, newState)
                    Changed()
                end)
                self:RegisterCheckboxWithData(cb, getter, setter)
                cardY = cardY - 28
                return cb
            end
            Check("countHidden", "Count hidden buff slots")
            Check("learn", "Learn hidden slots it cannot see when a buff is pushed off")
            Check("chatWarn", "Say in chat when a buff is pushed off")

            self.UI:CreateSegmentedControl(capCard, {
                x = 14, y = cardY, inset = 14, height = 22, label = RCL["The Buffs cell shows"],
                items = {
                    { key = "used",  label = RCL["Slots used"],  tooltip = eraCap and RCL["Buffs on you plus hidden slots, out of 32."]
                        or RCL["Buffs on you plus hidden slots."] },
                    { key = "ratio", label = RCL["On you / cap"], tooltip = eraCap and RCL["Buffs on you, then the real cap once hidden slots are taken off 32."]
                        or RCL["Buffs on you, then the real cap once hidden slots are taken off the measured limit."] },
                    { key = "free",  label = RCL["Slots free"],  tooltip = RCL["How many more buffs fit before one gets pushed off."] },
                },
                selected = BC:Setting("barText") or "used",
                onSelect = function(key)
                    Cap().barText = key
                    Changed()
                end,
            })
            cardY = cardY - 22 - 10

            local learnedText = self:CreateFontString(capCard, "OVERLAY", nil, 10)
            learnedText:SetPoint("TOPLEFT", capCard, "TOPLEFT", 14, cardY - 5)
            local function ShowLearned()
                local m = self.db.buffCapLearned
                local n = (type(m) == "table" and tonumber(m.learned)) or 0
                if not eraCap then
                    local lim = BC:Limit()
                    if lim then
                        learnedText:SetText(string.format(RCL["Buff limit measured on this character: %d slots."], lim))
                    else
                        learnedText:SetText(RCL["Buff limit not measured yet: it is learned the first time a buff gets pushed off."])
                    end
                elseif n == 0 then
                    learnedText:SetText(RCL["No unseen hidden slots learned."])
                elseif n > 0 then
                    learnedText:SetText(string.format(RCL["Learned: %d hidden slot(s) it cannot identify."], n))
                else
                    learnedText:SetText(string.format(RCL["Learned: %d fewer hidden slot(s) than expected."], -n))
                end
            end
            ShowLearned()
            learnedText:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
            local resetBtn = self.UI:CreateStyledButton(capCard, RCL["Reset"], 70, 22)
            resetBtn:SetPoint("TOPRIGHT", capCard, "TOPRIGHT", -14, cardY)
            resetBtn:SetScript("OnClick", function()
                BC:ResetLearned()
                ShowLearned()
                Changed()
            end)
            cardY = cardY - 30

            capCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - capCard:GetHeight() - 15
            end

            -- What got pushed off, what took its slot, where and when.
            -- Kept per character (the newest 40).
            if tab == "history" then
            local histCard = self:CreateSettingsCard(parent, yPos, RCL["Push-off history"])
            cardY = -32
            local pushes = BC:Pushes()
            local function AgoText(sec)
                if sec < 60 then return RCL["just now"] end
                if sec < 3600 then return string.format(RCL["%dm ago"], math.floor(sec / 60)) end
                if sec < 86400 then return string.format(RCL["%dh ago"], math.floor(sec / 3600)) end
                return string.format(RCL["%dd ago"], math.floor(sec / 86400))
            end
            if #pushes == 0 then
                local none = self:CreateFontString(histCard, "OVERLAY", nil, 10)
                none:SetPoint("TOPLEFT", histCard, "TOPLEFT", 14, cardY)
                none:SetText(RCL["Nothing pushed off yet."])
                none:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
                cardY = cardY - 22
            end
            local red = self:GetColor("text", "red")
            local norm = self:GetColor("text", "normal")
            local now = time()
            for _, p in ipairs(pushes) do
                local nameFs = self:CreateFontString(histCard, "OVERLAY", nil, 11)
                nameFs:SetPoint("TOPLEFT", histCard, "TOPLEFT", 14, cardY)
                nameFs:SetText(p.n or "?")
                nameFs:SetTextColor(red.r, red.g, red.b)
                local detail = {}
                if p.by and #p.by > 0 then
                    detail[#detail + 1] = RCL["pushed off by "] .. table.concat(p.by, ", ")
                else
                    detail[#detail + 1] = RCL["pushed off"]
                end
                if p.z then detail[#detail + 1] = p.z end
                if p.t then detail[#detail + 1] = AgoText(now - p.t) end
                local dFs = self:CreateFontString(histCard, "OVERLAY", nil, 10)
                dFs:SetPoint("LEFT", nameFs, "RIGHT", 8, 0)
                dFs:SetPoint("RIGHT", histCard, "RIGHT", -14, 0)
                dFs:SetJustifyH("LEFT")
                dFs:SetWordWrap(false)
                dFs:SetText(table.concat(detail, "  -  "))
                dFs:SetTextColor(norm.r, norm.g, norm.b)
                cardY = cardY - 20
            end
            if #pushes > 0 then
                local clearBtn = self.UI:CreateStyledButton(histCard, RCL["Clear"], 70, 22)
                clearBtn:SetPoint("TOPLEFT", histCard, "TOPLEFT", 14, cardY - 6)
                clearBtn:SetScript("OnClick", function()
                    BC:ClearPushes()
                    self:SaveConfigurationToProfile()
                    C_Timer.After(0, function() RC:ShowSidebarBuffPushoffConfig(frame, "history") end)
                end)
                cardY = cardY - 36
            end
            histCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - histCard:GetHeight() - 15
            end
        end

        local function TestAlert()
            local CS = self.CharacterStats
            if CS and CS.ShowMultiBuffPushoffAlert then
                local was = A.enabled
                A.enabled = true
                CS:ShowMultiBuffPushoffAlert({ { name = "Flask of the Titans", icon = "Interface\\Icons\\INV_Potion_62", by = { "Battle Shout" } } })
                A.enabled = was
            end
        end
        local function TestButton(card, y, x)
            local b = self.UI:CreateStyledButton(card, RCL["Test Alert"], 90, 24)
            b:SetPoint("TOPLEFT", card, "TOPLEFT", x or 14, y)
            b:SetScript("OnClick", TestAlert)
            return y - 32
        end

        if tab == "behavior" then
            yPos = K.Card(parent, yPos, RCL["Stats bar icon"], function(card, y)
                return K.Check(card, y, RCL["Show next buff pushoff icon"],
                    function() return self.db.statsBarShowPushoffIcon ~= false end,
                    function(v)
                        self.db.statsBarShowPushoffIcon = v
                        local CS = self.CharacterStats
                        if CS and CS.barFrame then
                            CS:UpdateBarStats()
                            CS:LayoutBarStats()
                        end
                    end,
                    RCL["The buff a new one would push off next, as a small icon in the stats bar's Buffs cell."])
            end)

            -- The debuff side of the same problem: a Darkmoon Faire fortune
            -- carried as a debuff sits under the 16-debuff cap.
            yPos = K.Card(parent, yPos, RCL["Darkmoon Faire debuff"], function(card, y)
                y = K.Desc(card, y, eraCap and RCL["If you carry Sayge's fortune as a debuff, a boss stacking debuffs on you can push it off at the 16-debuff cap. This prints a chat line, shows a warning on screen and plays the raid warning sound when that happens."]
                    or RCL["If you carry Sayge's fortune as a debuff and it goes early, this prints a chat line, shows a warning on screen and plays the raid warning sound."])
                y = K.Check(card, y, RCL["Warn when my Darkmoon Faire debuff is pushed off"],
                    function() return A.dmfDebuff ~= false end,
                    function(v) A.dmfDebuff = v and true or false end)
                local b = self.UI:CreateStyledButton(card, RCL["Test Warning"], 100, 24)
                b:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y - 4)
                b:SetScript("OnClick", function()
                    if self.CharacterStats and self.CharacterStats.TestDmfDebuffAlert then
                        self.CharacterStats:TestDmfDebuffAlert()
                    end
                end)
                return y - 36
            end)

            yPos = K.Card(parent, yPos, RCL["Buff pushoff alert"], function(card, y)
                y = K.Desc(card, y, eraCap and RCL["Shows an alert when a buff is pushed off by the 32 buff limit."]
                    or RCL["Shows an alert when a buff is pushed off by the buff limit."])
                local enableCb
                y, enableCb = K.Check(card, y, RCL["Enable buff pushoff alerts"],
                    function() return A.enabled end,
                    function(v)
                        A.enabled = v
                        local CS = self.CharacterStats
                        if CS and CS.UpdateBuffCapWant then CS:UpdateBuffCapWant() end
                    end)
                local enableMark = self.UI:MarkCard(card)
                y = K.Check(card, y, RCL["Show buff icon"], function() return A.showIcon ~= false end,
                    function(v) A.showIcon = v ApplyPushLive() end)
                y = K.Check(card, y, RCL["Show alert text"], function() return A.showText ~= false end,
                    function(v) A.showText = v ApplyPushLive() end)
                y = K.Check(card, y, RCL["Show what pushed it off under the alert"], function() return A.showPusher ~= false end,
                    function(v) A.showPusher = v ApplyPushLive() end)
                y = K.Slider(card, y - 4, RCL["Duration"], 1, 10, A.duration or 3, 0.5,
                    function(v) return string_format("%.1fs", v) end,
                    function(v) A.duration = v self:SaveConfigurationToProfile() end, 10)
                y = K.Desc(card, y + 6, RCL["How long the alert stays before its exit animation starts."])
                -- (the test button stays live)
                self.UI:BindDependents(enableCb, self.UI:CardSince(card, enableMark))
                return TestButton(card, y)
            end)
        elseif tab == "look" then
            yPos = K.Card(parent, yPos, RCL["Background"], function(card, y)
                local bgCb
                y, bgCb = K.Check(card, y, RCL["Show background"], function() return A.showBackground ~= false end,
                    function(v) A.showBackground = v ApplyPushLive() end,
                    RCL["The fill and the border around the alert. Off, only the icons and text show."])
                local bgMark = self.UI:MarkCard(card)
                y = K.BgTexture(card, y, RCL["Background texture"],
                    function() return PushLook().bgTexture end,
                    function(v) PushLook().bgTexture = v ApplyPushLive() end,
                    function() local c = RC:GetColor("buffPushoffAlert", "background") return c.r, c.g, c.b end)
                y = K.ThemeColor(card, y, RCL["Background colour"], "buffPushoffAlert", "background", ApplyPushLive)
                y = K.ThemeColor(card, y, RCL["Border colour"], "buffPushoffAlert", "border", ApplyPushLive)
                self.UI:BindDependents(bgCb, self.UI:CardSince(card, bgMark))
                return y - 4

            end)
            yPos = K.Card(parent, yPos, RCL["Size"], function(card, y)
                y = K.Slider(card, y, RCL["Icon size"], 16, 64, A.iconSize or 32, 2,
                    function(v) return v .. RCL[" px"] end,
                    function(v)
                        A.iconSize = v
                        self:SaveConfigurationToProfile()
                        local CS = self.CharacterStats
                        if CS and CS.UpdateBuffPushoffAlertAppearance then CS:UpdateBuffPushoffAlertAppearance() end
                        ApplyPushLive()
                    end)
                y = K.Slider(card, y, RCL["Widest it gets"], 200, 700, PushLook().width or 420, 10,
                    function(v) return v .. RCL[" px"] end,
                    function(v) PushLook().width = v self:SaveConfigurationToProfile() ApplyPushLive() end)
                y = K.Slider(card, y, RCL["Padding"], 2, 30, PushLook().padding or 10, 1,
                    function(v) return v .. RCL[" px"] end,
                    function(v) PushLook().padding = v self:SaveConfigurationToProfile() ApplyPushLive() end)
                return K.Desc(card, y + 6, RCL["Long buff names are cut off at the widest size."])
            end)
        elseif tab == "text" then
            yPos = K.Card(parent, yPos, RCL["Text"], function(card, y)
                y = K.Font(card, y, RCL["Alert text"],
                    function()
                        local s = K.CopySpec(PushLook().font)
                        s.size = A.fontSize or 18
                        return s
                    end,
                    function(spec)
                        -- size stays on the key the alert has always read
                        A.fontSize = spec.size or A.fontSize
                        spec.size = nil
                        PushLook().font = spec
                        local CS = self.CharacterStats
                        if CS and CS.UpdateBuffPushoffAlertAppearance then CS:UpdateBuffPushoffAlertAppearance() end
                        ApplyPushLive()
                    end,
                    { size = 18, shadow = true }, "Flask of the Titans pushed off!", 10, 32)
                y = K.ThemeColor(card, y, RCL["Text colour"], "buffPushoffAlert", "text", ApplyPushLive)
                y = K.Font(card, y - 6, RCL["What pushed it off"],
                    function() return PushLook().subFont end,
                    function(spec) PushLook().subFont = spec ApplyPushLive() end,
                    { size = math_max(9, math_floor((A.fontSize or 18) * 0.6 + 0.5)), shadow = true }, "by Battle Shout", 6, 24)
                y = K.LookColor(card, y, RCL["Colour"], PushLook, "subColor",
                    function() return RC:GetColor("text", "gray") end, ApplyPushLive)
                return y - 4
            end)
            -- where each text sits (buffPushoffAlert.anchors.title / .sub)
            yPos = K.Card(parent, yPos, RCL["Text positions"], function(card, y)
                local cw = card:GetWidth() or 0
                local W = (cw > 240) and math_min(460, cw - 28) or 420
                local function Root()
                    RC.db.buffPushoffAlert = RC.db.buffPushoffAlert or {}
                    return RC.db.buffPushoffAlert
                end
                local function After() RC:SaveConfigurationToProfile() ApplyPushLive() end
                local TARGETS = { { value = "row", text = RCL["The alert row"] }, { value = "icon", text = RCL["The buff icon"] },
                    { value = "frame", text = RCL["The whole alert"] } }
                local ag, as = self.UI:CustomAccess(Root, "anchors", "title", After)
                local g = self.UI:CreateTextElement(card, { label = RCL["Alert text"], key = "title", width = W,
                    anchorGet = ag, anchorSet = as, targets = TARGETS, defaultTargetLabel = RCL["Beside the icon"],
                    anchorDefaults = function() return { point = "LEFT", relPoint = "LEFT", x = 26 + 8, y = 0 } end })
                g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                y = y - g:GetHeight() - 14
                ag, as = self.UI:CustomAccess(Root, "anchors", "sub", After)
                g = self.UI:CreateTextElement(card, { label = RCL["What pushed it off"], key = "sub", width = W,
                    anchorGet = ag, anchorSet = as, defaultTargetLabel = RCL["Under the alert text"],
                    targets = { { value = "title", text = RCL["The alert text"] }, TARGETS[1], TARGETS[2], TARGETS[3] },
                    anchorDefaults = function() return { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = 1, y = -3 } end })
                g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                y = y - g:GetHeight() - 10
                return K.Desc(card, y, RCL["Reset puts a text back where the alert always put it."])
            end)
            yPos = K.Card(parent, yPos, RCL["Wording"], function(card, y)
                y = K.Desc(card, y, RCL["What the alert says. %s is the buff's name."])
                local eb = self.UI:CreateStyledEditBox(card, { width = 260, height = 22, font = 11, maxLetters = 60,
                    initialText = A.textFormat or "%s pushed off!" })
                eb:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                eb.editBox:SetScript("OnEnterPressed", function(box)
                    local t = box:GetText() or ""
                    if not t:find("%%s") then t = "%s " .. t end
                    -- one name only: a second %s would break the format
                    local first = t:find("%%s")
                    t = t:sub(1, first + 1) .. (t:sub(first + 2):gsub("%%", ""))
                    A.textFormat = t
                    box:SetText(t)
                    box:ClearFocus()
                    self:SaveConfigurationToProfile()
                    ApplyPushLive()
                end)
                return y - 34
            end)
        elseif tab == "animation" then
            yPos = K.Card(parent, yPos, RCL["Alert animation"], function(card, y)
                local CS = self.CharacterStats
                y = K.Anim(card, y, RCL["When it appears"], "in",
                    function() return PushLook().showAnim end,
                    function(s) PushLook().showAnim = s end,
                    CS and CS.PUSHOFF_SHOW_ANIM, nil, P)
                y = K.Anim(card, y, RCL["When it goes"], "out",
                    function() return PushLook().hideAnim end,
                    function(s) PushLook().hideAnim = s end,
                    CS and CS.PUSHOFF_HIDE_ANIM, nil, P)
                return K.Desc(card, y, RCL["Appearance > Motion can turn every animation off or speed them all up."])
            end)
        elseif tab == "sound" then
            yPos = K.Card(parent, yPos, RCL["Voice"], function(card, y)
                y = K.Check(card, y, RCL["Voice alert (TTS)"], function() return A.ttsEnabled == true end,
                    function(v) A.ttsEnabled = v end,
                    RCL["Says the buff's name out loud when it is pushed off."])
                y = K.Check(card, y, RCL["Voice alert also says what pushed it off"], function() return A.ttsPusher == true end,
                    function(v) A.ttsPusher = v end)
                return y
            end)
        elseif tab == "position" then
            yPos = K.Card(parent, yPos, RCL["Position"], function(card, y)
                y = K.Check(card, y, RCL["Lock position (drag to move when unlocked)"], function() return A.locked end,
                    function(v) A.locked = v end)
                local CS = self.CharacterStats
                local f = CS and CS.CreateBuffPushoffAlertFrame and CS:CreateBuffPushoffAlertFrame()
                local Pos = RC.Position
                if f and Pos.IsBound(f) then
                    Pos.RestoreFrame(f)
                    local x0, y0 = Pos.Capture(f, "CENTER")
                    y = K.Offsets(card, y, function() return x0 or 0 end, function() return y0 or 150 end,
                        function(x, yy)
                            local cx, cy = Pos.Capture(f, "CENTER")
                            Pos.SetFrame(f, x or cx or 0, yy or cy or 0)
                        end, 1000)
                    local reset = self.UI:CreateStyledButton(card, RCL["Reset position"], 120, 22)
                    reset:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                    reset:SetScript("OnClick", function()
                        Pos.ResetFrame(f)
                        RC:ShowSidebarBuffPushoffConfig(frame, "position")
                    end)
                    local em = self.UI:CreateStyledButton(card, RCL["Edit Mode"], 100, 22)
                    em:SetPoint("LEFT", reset, "RIGHT", 6, 0)
                    em:SetScript("OnClick", function()
                        if RC.UIMover and RC.UIMover.EnterMoveMode then RC.UIMover:EnterMoveMode() end
                    end)
                    y = y - 32
                end
                return TestButton(card, y)
            end)
        end
        -- the alert's layer / fade / edge (the customization standard)
        yPos = self.UI:FrameCardsForTab(tab, parent, yPos, function()
            RC.db.buffPushoffAlert = RC.db.buffPushoffAlert or {}
            return RC.db.buffPushoffAlert
        end, function()
            local CSx = RC.CharacterStats
            if CSx and CSx.alertFrame then
                RC:ApplyFrameCustom(CSx.alertFrame, function() return RC.db.buffPushoffAlert end)
            end
        end, { chromeFields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })

        if self.UpdateSidebarScrollbar then
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
        end
    end

