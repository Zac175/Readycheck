------------------------------------------------------------------------
-- Readycheck - Appearance: Colors
-- Colors sub-tab (Core UI / Bars / Raid Tools) of the Appearance page.
-- One card per color category; inside a card every colour is a full
-- width row ([swatch] [label] ... [#hex] [gold dot = changed] [Reset]),
-- and clicking a row opens ONE inline editor panel under it (R/G/B/Alpha
-- sliders, hex box, Colour wheel..., Reset to default, Done). A search
-- box at the top filters rows by label or key across the whole sub-tab.
--
-- RC:GetColor(cat,key): db.customColors[cat][key] if set, else the
-- default. Edits go through RC:SetColor (writes + saves the profile) and
-- must end in RC:RefreshUIColors() so already-built frames repaint; card
-- previews only update via their own rebuildPreview() closure. Live
-- slider edits are coalesced (see QueueFlush) so neither the profile
-- save nor the repaint runs per tick.
--
-- The page is rebuilt on every structural change (editor open/close,
-- search, sub-tab) exactly like the sub-tab switch always did. Frames are
-- never garbage-collected in WoW, so the row frames and the editor panel
-- are POOLED on RC._colorEditor and re-targeted per rebuild instead of
-- being created again (~150 rows a time otherwise).
-- Custom cards (text groups, input controls, stats bar gradients, buff
-- pushoff, TTK, UI mover) in Sidebar_AppearanceCards.lua build their
-- rows through the same RC:CreateColorRowCard / RC:MakeColorEntry.
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

    ------------------------------------------------------------------
    -- Editor state (survives page rebuilds)
    ------------------------------------------------------------------
    RC._colorEditor = RC._colorEditor or {
        rowPool = {},          -- every row frame ever created, reused in order
        rowsUsed = 0,          -- rows handed out during the current build
        panel = nil,           -- the single inline editor panel
        open = nil,            -- entry id whose editor is open (nil = closed)
        openBeforeId = nil,    -- entry id `before` was captured for
        before = nil,          -- colour when the open editor was opened
        search = "",           -- current filter text
        pending = nil,         -- row -> {r,g,b,a} live edits awaiting a write
        flushQueued = false,
        dirtyCards = {},       -- cards whose preview/changed-count need a rebuild
        frame = nil,           -- config frame handed to ShowAppearanceColorsContent
    }
    local ED = RC._colorEditor
    local ROW_H, ROW_X, EDITOR_H = 24, 14, 146

    local function CopyColor(c)
        return { r = c.r or 1, g = c.g or 1, b = c.b or 1, a = c.a or 1 }
    end

    local function ToHex(c)
        if not c then return "FFFFFF" end
        local function q(v) return math_max(0, math_min(255, math_floor((v or 0) * 255 + 0.5))) end
        return string_format("%02X%02X%02X", q(c.r), q(c.g), q(c.b))
    end

    -- "#RRGGBB" / "RRGGBB" / "#RRGGBBAA" -> r, g, b, a (a nil when 6 digits);
    -- anything else -> nil.
    local function ParseHex(s)
        if type(s) ~= "string" then return nil end
        s = s:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^#", "")
        local n = #s
        if (n ~= 6 and n ~= 8) or not s:match("^%x+$") then return nil end
        local r = tonumber(s:sub(1, 2), 16) / 255
        local g = tonumber(s:sub(3, 4), 16) / 255
        local b = tonumber(s:sub(5, 6), 16) / 255
        local a
        if n == 8 then a = tonumber(s:sub(7, 8), 16) / 255 end
        return r, g, b, a
    end

    -- Two colours count as different when they land on different 0-255
    -- steps (or different whole alpha percents) - the same resolution
    -- the editor exposes, so a colour typed back to its default hex
    -- reads as unchanged.
    local function ColorsDiffer(a, b)
        if not a or not b then return false end
        local function q(v) return math_floor((v or 0) * 255 + 0.5) end
        if q(a.r) ~= q(b.r) or q(a.g) ~= q(b.g) or q(a.b) ~= q(b.b) then return true end
        return math_floor((a.a or 1) * 100 + 0.5) ~= math_floor((b.a or 1) * 100 + 0.5)
    end

    _sbs.ColorToHex = ToHex
    _sbs.ParseHexColor = ParseHex
    _sbs.CopyColor = CopyColor
    _sbs.ColorsDiffer = ColorsDiffer

    ------------------------------------------------------------------
    -- Entries: what one row edits
    ------------------------------------------------------------------
    -- An entry describes one editable colour:
    --   id         unique string ("cat:key")
    --   label,key  shown / searched
    --   hasAlpha   editor shows the Alpha slider
    --   default    {r,g,b,a}
    --   get()      -> current {r,g,b,a} from the store
    --   set(r,g,b,a)  persist
    --   reset()    clear the override
    --   after()    optional extra side effect after a write or reset
    --   wheel(row) open the Blizzard colour wheel for this row
    -- Generic customColors entries come from MakeColorEntry; the stats bar
    -- card builds its own of the same shape over db.statsBarColors.
    function RC:MakeColorEntry(cat, key, label, after)
        local def = self.defaultColors and self.defaultColors[cat] and self.defaultColors[cat][key]
        if not def then return nil end
        return {
            id = cat .. ":" .. key,
            cat = cat,
            key = key,
            label = label or def.label or key,
            hasAlpha = true,
            default = CopyColor(def),
            get = function() return CopyColor(RC:GetColor(cat, key)) end,
            set = function(r, g, b, a) RC:SetColor(cat, key, r, g, b, a) end,
            reset = function() RC:ResetColor(cat, key) end,
            after = after,
            wheel = function(row) RC:OpenAppearanceColorPickerLive(row) end,
        }
    end

    local function EntryMatches(e, q)
        if not q or q == "" then return true end
        local lbl = tostring(e.label or ""):lower()
        if lbl:find(q, 1, true) then return true end
        local key = tostring(e.key or ""):lower()
        return key:find(q, 1, true) ~= nil
    end

    local function RowChanged(row)
        return ColorsDiffer(row.currentColor, row.entry.default)
    end

    local function SyncRow(row)
        local e = row.entry
        row:SetData(e.label, "#" .. ToHex(row.currentColor), row.currentColor, RowChanged(row))
    end

    ------------------------------------------------------------------
    -- Coalesced writes
    ------------------------------------------------------------------
    -- Slider ticks land here many times a second. The swatch/hex/After
    -- box follow instantly (cheap), while SetColor (which saves the whole
    -- profile), the card preview rebuild and RefreshUIColors run once per
    -- 0.15s for whatever is pending. Writes are keyed by row so two
    -- colours edited back to back both land.
    local function FlushPending()
        local pend = ED.pending
        ED.pending = nil
        local touched = false
        if pend then
            for row, c in pairs(pend) do
                local e = row.entry
                e.set(c.r, c.g, c.b, c.a)
                if e.after then e.after() end
                if row.card then ED.dirtyCards[row.card] = true end
                touched = true
            end
        end
        for card in pairs(ED.dirtyCards) do
            ED.dirtyCards[card] = nil
            if card.rebuildPreview then card.rebuildPreview() end
            if card.RefreshChangedState then card.RefreshChangedState() end
            touched = true
        end
        if touched then
            RC:RefreshUIColors()
        end
    end

    local function QueueFlush()
        if ED.flushQueued then return end
        ED.flushQueued = true
        C_Timer.After(0.15, function()
            ED.flushQueued = false
            FlushPending()
        end)
    end

    local function ApplyLive(row, r, g, b, a)
        row.currentColor = { r = r, g = g, b = b, a = a or 1 }
        SyncRow(row)
        local panel = ED.panel
        if panel and panel.row == row then panel:SyncAfter() end
        ED.pending = ED.pending or {}
        ED.pending[row] = row.currentColor
        QueueFlush()
    end

    -- Discrete actions (reset, picker OK) repaint at once.
    local function ResetRow(row)
        local e = row.entry
        if ED.pending then ED.pending[row] = nil end
        e.reset()
        if e.after then e.after() end
        row.currentColor = CopyColor(e.default)
        SyncRow(row)
        local panel = ED.panel
        if panel and panel.row == row then panel:SyncAll() end
        if row.card then
            if row.card.rebuildPreview then row.card.rebuildPreview() end
            if row.card.RefreshChangedState then row.card.RefreshChangedState() end
        end
        RC:RefreshUIColors()
    end

    -- Called by the Blizzard-picker bridges (OpenAppearanceColorPickerLive
    -- / OpenStatsBarColorPicker) after they painted row.colorTex, updated
    -- row.currentColor and written the store themselves.
    local function PickerChanged(row)
        if ED.pending then ED.pending[row] = nil end
        SyncRow(row)
        local panel = ED.panel
        if panel and panel.row == row then panel:SyncAll() end
        if row.card then ED.dirtyCards[row.card] = true end
        QueueFlush()
    end

    local function RowTooltip(row, tt)
        local e = row.entry
        local tn = RC:GetColor("text", "normal")
        local gray = RC:GetColor("text", "gray")
        local gold = RC:GetColor("ui", "accentGold")
        tt:AddLine(e.label or e.key or "", tn.r, tn.g, tn.b)
        tt:AddLine(string_format(RCL["Default: #%s"], ToHex(e.default)), gray.r, gray.g, gray.b)
        if RowChanged(row) then
            tt:AddLine(string_format(RCL["Current: #%s"], ToHex(row.currentColor)), gray.r, gray.g, gray.b)
        end
        tt:AddLine(RCL["Click to edit"], gold.r, gold.g, gold.b)
    end

    ------------------------------------------------------------------
    -- Page rebuild
    ------------------------------------------------------------------
    -- Same recipe as the sub-tab switch: clear, rebuild the Appearance
    -- page on the same tab, restore the scroll position a frame later.
    -- Pending live edits are written first so nothing is lost.
    function RC:_ColorEditorRebuild()
        FlushPending()
        local frame = ED.frame
        if not frame or not RC.sidebarConfigFrame then return end
        RC:ClearSidebarContent(RC.sidebarConfigFrame, true)
        RC:ShowSidebarFontSettings(frame, true)
        C_Timer.After(0.05, function()
            RC:RestoreScrollPosition(RC.sidebarConfigFrame)
        end)
    end

    local function ToggleEditor(row)
        local id = row.entry.id
        if ED.open == id then
            ED.open = nil
            -- Closing forgets "Before"; reopening captures it afresh.
            ED.openBeforeId = nil
            ED.before = nil
        else
            ED.open = id
        end
        RC:_ColorEditorRebuild()
    end

    ------------------------------------------------------------------
    -- Row pool
    ------------------------------------------------------------------
    local function ResetRowPool()
        ED.rowsUsed = 0
        for i = 1, #ED.rowPool do
            ED.rowPool[i]:Hide()
        end
    end

    local function AcquireRow(card)
        ED.rowsUsed = ED.rowsUsed + 1
        local row = ED.rowPool[ED.rowsUsed]
        if not row then
            row = RC.UI:CreateColorRow(card)
            row.onClick = ToggleEditor
            row.onReset = ResetRow
            row.tooltipFn = RowTooltip
            row.OnPickerChanged = PickerChanged
            ED.rowPool[ED.rowsUsed] = row
        end
        row:SetParent(card)
        row:ClearAllPoints()
        row:Show()
        return row
    end

    local function BindRow(card, entry, index)
        local row = AcquireRow(card)
        row.entry = entry
        row.card = card
        row.currentColor = entry.get()
        -- Blizzard-picker bridge fields: OpenAppearanceColorPickerLive and
        -- OpenStatsBarColorPicker read these off the swatch they are given.
        row.categoryKey = entry.cat
        row.colorKey = entry.key
        row.defaultColor = entry.default
        row.statKey = entry.statKey
        row.isHigh = entry.isHigh
        row:SetStripe(index % 2 == 0)
        row:SetSelected(ED.open == entry.id)
        SyncRow(row)
        return row
    end

    ------------------------------------------------------------------
    -- Inline editor panel (one instance, reparented under the open row)
    ------------------------------------------------------------------
    local function GetEditorPanel()
        if ED.panel then return ED.panel end

        local p = CreateFrame("Frame", nil, UIParent)
        p:SetHeight(EDITOR_H)
        p:Hide()

        p.bg = p:CreateTexture(nil, "BACKGROUND")
        p.bg:SetAllPoints()
        p.bg:SetTexture(RC.UI.FLAT)
        p.border = RC.UI:CreateSimpleBorder(p)

        -- Before / After: the value when the editor opened over the live one.
        local function MakeSwatch(labelText, y)
            local lbl = RC:CreateFontString(p, "OVERLAY", nil, 10)
            lbl:SetPoint("TOPLEFT", p, "TOPLEFT", 12, y)
            lbl:SetText(labelText)
            local box = CreateFrame("Frame", nil, p)
            box:SetSize(40, 20)
            box:SetPoint("TOPLEFT", p, "TOPLEFT", 12, y - 13)
            box.ring = box:CreateTexture(nil, "BACKGROUND")
            box.ring:SetAllPoints()
            box.ring:SetTexture(RC.UI.FLAT)
            box.tex = box:CreateTexture(nil, "ARTWORK")
            box.tex:SetPoint("TOPLEFT", box, "TOPLEFT", 1, -1)
            box.tex:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -1, 1)
            box.tex:SetColorTexture(1, 1, 1, 1)
            return lbl, box
        end
        p.beforeLbl, p.beforeBox = MakeSwatch(RCL["Before"], -10)
        p.afterLbl,  p.afterBox  = MakeSwatch(RCL["After"],  -50)

        -- R / G / B (0-255) and Alpha (0-100 %) in a column.
        local SL_X, SL_W = 72, 220
        local function MakeSlider(labelText, y, maxV)
            local s = RC.UI:CreateSlider(p, 0, maxV, 0, 1)
            s:SetPoint("TOPLEFT", p, "TOPLEFT", SL_X, y)
            s.parentFrame:SetWidth(SL_W)
            s:SetLabel(labelText)
            return s
        end
        p.sR = MakeSlider(RCL["R"],     -8,   255)
        p.sG = MakeSlider(RCL["G"],     -40,  255)
        p.sB = MakeSlider(RCL["B"],     -72,  255)
        p.sA = MakeSlider(RCL["Alpha"], -104, 100)

        local function PctText()
            p.sA.Text:SetText(math_floor(p.sA:GetValue() + 0.5) .. "%")
        end

        local function FromSliders()
            if p.syncing or not p.row then return end
            local r = math_floor(p.sR:GetValue() + 0.5) / 255
            local g = math_floor(p.sG:GetValue() + 0.5) / 255
            local b = math_floor(p.sB:GetValue() + 0.5) / 255
            local a
            if p.row.entry.hasAlpha then
                a = math_floor(p.sA:GetValue() + 0.5) / 100
            else
                a = p.row.currentColor.a or 1
            end
            ApplyLive(p.row, r, g, b, a)
        end
        p.sR:HookScript("OnValueChanged", FromSliders)
        p.sG:HookScript("OnValueChanged", FromSliders)
        p.sB:HookScript("OnValueChanged", FromSliders)
        p.sA:HookScript("OnValueChanged", FromSliders)
        -- The framework paints the raw number; alpha reads as a percent.
        p.sA:HookScript("OnValueChanged", PctText)
        p.sA:HookScript("OnMouseUp", PctText)

        -- Hex box + buttons column.
        local HX = SL_X + SL_W + 24
        p.hexLbl = RC:CreateFontString(p, "OVERLAY", nil, 10)
        p.hexLbl:SetPoint("TOPLEFT", p, "TOPLEFT", HX, -8)
        p.hexLbl:SetText(RCL["Hex"])

        p.hexBox = RC.UI:CreateStyledEditBox(p, { width = 80, height = 22, maxLetters = 9, font = 11 })
        p.hexBox:SetPoint("TOPLEFT", p, "TOPLEFT", HX, -20)
        local eb = p.hexBox.editBox

        function p:SyncHex()
            if not self.row then return end
            eb:SetText("#" .. ToHex(self.row.currentColor))
            eb:SetCursorPosition(0)
        end

        -- Bad input: red ring for a moment, old value back in the box.
        function p:FlashHexInvalid()
            local red = RC:GetColor("text", "red")
            self.hexBox:SetBackdropBorderColor(red.r, red.g, red.b, 1)
            self.hexFlashToken = (self.hexFlashToken or 0) + 1
            local token = self.hexFlashToken
            C_Timer.After(0.4, function()
                if token ~= p.hexFlashToken then return end
                if eb:HasFocus() then
                    local gold = RC:GetColor("ui", "accentGold")
                    p.hexBox:SetBackdropBorderColor(gold.r, gold.g, gold.b, 1)
                else
                    local bn = RC:GetColor("ui", "borderNormal")
                    p.hexBox:SetBackdropBorderColor(bn.r, bn.g, bn.b, bn.a or 1)
                end
            end)
            self:SyncHex()
            eb:HighlightText()
        end

        eb:SetScript("OnEnterPressed", function(s)
            if not p.row then s:ClearFocus() return end
            local r, g, b, a = ParseHex(s:GetText())
            if not r then
                p:FlashHexInvalid()
                return
            end
            if not p.row.entry.hasAlpha or a == nil then
                a = p.row.currentColor.a or 1
            end
            ApplyLive(p.row, r, g, b, a)
            p:SyncAll()
            s:ClearFocus()
        end)
        eb:HookScript("OnEditFocusLost", function() p:SyncHex() end)

        p.wheelBtn = RC.UI:CreateStyledButton(p, RCL["Colour wheel..."], 110, 22)
        p.wheelBtn:SetPoint("TOPLEFT", p, "TOPLEFT", HX, -52)
        p.wheelBtn:SetScript("OnClick", function()
            if not p.row then return end
            FlushPending()
            p.row.entry.wheel(p.row)
        end)

        p.resetBtn = RC.UI:CreateStyledButton(p, RCL["Reset to default"], 110, 22)
        p.resetBtn:SetPoint("TOPLEFT", p, "TOPLEFT", HX, -78)
        p.resetBtn:SetScript("OnClick", function()
            if p.row then ResetRow(p.row) end
        end)

        p.doneBtn = RC.UI:CreateStyledButton(p, RCL["Done"], 110, 22)
        p.doneBtn:SetPoint("TOPLEFT", p, "TOPLEFT", HX, -104)
        p.doneBtn:SetScript("OnClick", function()
            ED.open = nil
            ED.openBeforeId = nil
            ED.before = nil
            RC:_ColorEditorRebuild()
        end)

        -- After box, Reset enable and (unless being typed in) the hex.
        function p:SyncAfter()
            if not self.row then return end
            local c = self.row.currentColor
            self.afterBox.tex:SetColorTexture(c.r, c.g, c.b, c.a or 1)
            if RowChanged(self.row) then self.resetBtn:Enable() else self.resetBtn:Disable() end
            if not eb:HasFocus() then self:SyncHex() end
        end

        -- Sliders too (guarded so their OnValueChanged does not re-apply).
        function p:SyncAll()
            if not self.row then return end
            self.syncing = true
            local c = self.row.currentColor
            self.sR:SetValue(math_floor((c.r or 1) * 255 + 0.5))
            self.sG:SetValue(math_floor((c.g or 1) * 255 + 0.5))
            self.sB:SetValue(math_floor((c.b or 1) * 255 + 0.5))
            if self.row.entry.hasAlpha then
                self.sA:Show()
                self.sA:SetValue(math_floor((c.a or 1) * 100 + 0.5))
                PctText()
            else
                self.sA:Hide()
            end
            self.syncing = false
            self:SyncAfter()
        end

        function p:Bind(row)
            self.row = row
            -- "Before" is captured once per opened colour and kept across
            -- the page rebuilds that search / sub-tab switches cause.
            if ED.openBeforeId ~= row.entry.id or not ED.before then
                ED.openBeforeId = row.entry.id
                ED.before = CopyColor(row.currentColor)
            end
            local b = ED.before
            self.beforeBox.tex:SetColorTexture(b.r, b.g, b.b, b.a or 1)
            self:Repaint()
            self:SyncAll()
        end

        function p:Repaint()
            local wb = RC:GetColor("ui", "windowBackground")
            self.bg:SetVertexColor(wb.r, wb.g, wb.b, 0.95)
            local bn = RC:GetColor("ui", "borderNormal")
            RC.UI:UpdateBorderColor(self.border, bn, 1)
            self.beforeBox.ring:SetVertexColor(bn.r, bn.g, bn.b, 1)
            self.afterBox.ring:SetVertexColor(bn.r, bn.g, bn.b, 1)
            local gray = RC:GetColor("text", "gray")
            self.beforeLbl:SetTextColor(gray.r, gray.g, gray.b)
            self.afterLbl:SetTextColor(gray.r, gray.g, gray.b)
            self.hexLbl:SetTextColor(gray.r, gray.g, gray.b)
        end

        p:Repaint()
        ED.panel = p
        return p
    end

    ------------------------------------------------------------------
    -- Card pieces shared by the generic and the custom cards
    ------------------------------------------------------------------
    -- True when at least one of the entries survives the current search.
    function RC:ColorEntriesMatchSearch(entries)
        local q = (ED.search or ""):lower()
        if q == "" then return true end
        for _, e in ipairs(entries or {}) do
            if EntryMatches(e, q) then return true end
        end
        return false
    end

    -- Lays out card.entries as rows from cardY down (only those matching
    -- the search), slotting the editor panel under the open one. Returns
    -- the y below the last row.
    function RC:LayoutColorRows(card, cardY)
        card.rows = {}
        local q = (ED.search or ""):lower()
        local idx = 0
        for _, e in ipairs(card.entries or {}) do
            if EntryMatches(e, q) then
                idx = idx + 1
                local row = BindRow(card, e, idx)
                row:SetPoint("TOPLEFT",  card, "TOPLEFT",  ROW_X, cardY)
                row:SetPoint("TOPRIGHT", card, "TOPRIGHT", -ROW_X, cardY)
                cardY = cardY - ROW_H
                table_insert(card.rows, row)
                if ED.open == e.id then
                    local panel = GetEditorPanel()
                    panel:SetParent(card)
                    panel:ClearAllPoints()
                    panel:SetPoint("TOPLEFT",  card, "TOPLEFT",  ROW_X, cardY - 2)
                    panel:SetPoint("TOPRIGHT", card, "TOPRIGHT", -ROW_X, cardY - 2)
                    panel:Show()
                    panel:Bind(row)
                    cardY = cardY - EDITOR_H - 6
                end
            end
        end
        return cardY
    end

    -- Category-level Reset in the card's title row, shown only while
    -- something in the card differs from default, with an "N changed"
    -- note beside it. resetAll() clears the whole card's overrides.
    function RC:AttachColorCardHeader(card, resetAll)
        local btn = RC.UI:CreateStyledButton(card, RCL["Reset"], 60, 18)
        btn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -6)
        local note = self:CreateFontString(card, "OVERLAY", nil, 10)
        note:SetPoint("RIGHT", btn, "LEFT", -8, 0)
        local gray = self:GetColor("text", "gray")
        note:SetTextColor(gray.r, gray.g, gray.b)
        card.headerResetBtn = btn
        card.headerNote = note

        function card:RefreshChangedState()
            local n = 0
            for _, e in ipairs(self.entries or {}) do
                if ColorsDiffer(e.get(), e.default) then n = n + 1 end
            end
            if n > 0 then
                note:SetText(string_format(RCL["%d changed"], n))
                note:Show()
                btn:Show()
            else
                note:Hide()
                btn:Hide()
            end
        end

        btn:SetScript("OnClick", function()
            if ED.pending then
                for _, row in ipairs(card.rows or {}) do ED.pending[row] = nil end
            end
            resetAll()
            for _, row in ipairs(card.rows or {}) do
                row.currentColor = row.entry.get()
                SyncRow(row)
                if ED.panel and ED.panel.row == row then ED.panel:SyncAll() end
            end
            if card.rebuildPreview then card.rebuildPreview() end
            card:RefreshChangedState()
            RC:RefreshUIColors()
        end)

        card:RefreshChangedState()
    end

    -- The one card shape every colour card uses:
    --   title (+ Reset / "N changed" at the right)
    --   opts.desc          10px gray description
    --   opts.previewBuilder(previewFrame, card)  the category preview box,
    --                      opts.previewHeight tall (default 55); it must
    --                      set card.rebuildPreview
    --   opts.above(card, cardY) -> cardY   any extra controls above the rows
    --   rows for `entries` (filtered by the search), editor under the open one
    -- With a search active and no entry matching, the card collapses to
    -- its title line. opts.resetAll() resets the whole card (default: every
    -- entry's reset()). Returns card, nextY.
    function RC:CreateColorRowCard(parent, yPos, title, entries, opts)
        opts = opts or {}
        local card = self:CreateSettingsCard(parent, yPos, title)
        card.entries = entries or {}
        local cardY = -32

        if not self:ColorEntriesMatchSearch(card.entries) then
            card:SetContentHeight(8)
            return card, yPos - card:GetHeight() - 14
        end

        if opts.desc and opts.desc ~= "" then
            local dfs = self:CreateFontString(card, "OVERLAY", nil, 10)
            dfs:SetPoint("TOPLEFT",  card, "TOPLEFT",  ROW_X, cardY + 2)
            dfs:SetPoint("TOPRIGHT", card, "TOPRIGHT", -ROW_X, cardY + 2)
            dfs:SetJustifyH("LEFT")
            dfs:SetWordWrap(true)
            local gc = self:GetColor("text", "gray")
            dfs:SetTextColor(gc.r, gc.g, gc.b)
            dfs:SetText(opts.desc)
            cardY = cardY - (dfs:GetStringHeight() or 12) - 6
        end

        if opts.previewBuilder then
            local ph = opts.previewHeight or 55
            local previewContainer = CreateFrame("Frame", nil, card, "BackdropTemplate")
            previewContainer:SetPoint("TOPLEFT", card, "TOPLEFT", ROW_X, cardY)
            previewContainer:SetPoint("RIGHT", card, "RIGHT", -ROW_X, 0)
            previewContainer:SetHeight(ph)
            previewContainer:SetBackdrop({
                bgFile = RC.UI.FLAT,
                edgeFile = RC.UI.FLAT,
                edgeSize = 1,
            })
            do local _wb = RC:GetColor("ui", "windowBackground"); previewContainer:SetBackdropColor(_wb.r, _wb.g, _wb.b, 0.95) end
            do local _bn = RC:GetColor("ui", "borderNormal"); previewContainer:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
            card.previewContainer = previewContainer
            opts.previewBuilder(previewContainer, card)
            cardY = cardY - ph - 8
        end

        if opts.above then
            cardY = opts.above(card, cardY)
        end

        self:AttachColorCardHeader(card, opts.resetAll or function()
            for _, e in ipairs(card.entries) do
                e.reset()
                if e.after then e.after() end
            end
        end)

        cardY = self:LayoutColorRows(card, cardY)

        card:SetContentHeight(math_max(0, -cardY))
        return card, yPos - card:GetHeight() - 14
    end

    ------------------------------------------------------------------
    -- Page
    ------------------------------------------------------------------
    function RC:ShowAppearanceColorsContent(parent, yPos, frame)
        if not self.db.customColors then
            self.db.customColors = {}
        end

        ED.frame = frame
        -- A rebuild from outside (sub-tab, Reset All, texture change)
        -- orphans whatever rows were mid-edit; drop those few ticks
        -- rather than write them over a store that may just have been
        -- reset. _ColorEditorRebuild flushes before it gets here.
        ED.pending = nil
        for k in pairs(ED.dirtyCards) do ED.dirtyCards[k] = nil end
        ResetRowPool()
        if ED.panel then ED.panel:Hide() end

        local txtGray = self:GetColor("text", "gray")

        -- Search + Reload UI on one line.
        local reloadBtn = RC.UI:CreateStyledButton(parent, RCL["Reload UI"], 110, 22)
        reloadBtn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, yPos)
        reloadBtn:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(RCL["Reload UI"], 1, 1, 1)
            GameTooltip:AddLine(RCL["Some color changes require a UI reload"], 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine(RCL["to apply fully across all windows."], 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        reloadBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
        reloadBtn:SetScript("OnClick", function()
            ReloadUI()
        end)

        local searchBox = RC.UI:CreateSearchBox(parent, {
            placeholder = RCL["Find a colour..."],
            initialText = ED.search,
            onChange = function(txt)
                ED.search = txt or ""
                ED.searchFocus = true
                if ED.searchTimer then ED.searchTimer:Cancel() end
                ED.searchTimer = C_Timer.NewTimer(0.4, function()
                    ED.searchTimer = nil
                    if not (RC.sidebarConfigFrame and RC.sidebarConfigFrame:IsVisible()) then ED.searchFocus = nil; return end
                    if RC.SidebarState and RC.SidebarState.currentPanel ~= "font_settings" then ED.searchFocus = nil; return end
                    if RC.appearanceTab ~= "colors" then ED.searchFocus = nil; return end
                    if not (ED.searchBox and ED.searchBox.editBox and ED.searchBox.editBox:HasFocus()) then ED.searchFocus = nil end
                    RC:_ColorEditorRebuild()
                end)
            end,
        })
        searchBox:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
        searchBox:SetPoint("TOPRIGHT", reloadBtn, "TOPLEFT", -10, 0)
        ED.searchBox = searchBox
        if ED.searchFocus then
            ED.searchFocus = false
            local function _refocus()
                local eb = searchBox.editBox
                if eb and eb:IsVisible() then eb:SetFocus(); eb:SetCursorPosition(#(eb:GetText() or "")) end
            end
            _refocus()
            C_Timer.After(0, _refocus)
        end
        yPos = yPos - 27

        local hint = self:CreateFontString(parent, "OVERLAY", nil, 10)
        hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos)
        hint:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, yPos)
        hint:SetJustifyH("LEFT")
        hint:SetText(RCL["Click a colour to edit it. Changed colours show a gold dot."])
        hint:SetTextColor(txtGray.r, txtGray.g, txtGray.b)
        yPos = yPos - 18

        -- Framework tab row: equal-width flat tabs, the selected one in
        -- the active (green fill, gold ring) look.
        -- preserveScroll=true: this is a sub-tab switch on the same page,
        -- not navigation away, so scroll position must survive the rebuild.
        RC.UI:CreateTabGroup(parent, {
            y = yPos, inset = 18, spacing = 4, fontSize = 10,
            tabs = {
                { key = "core", label = RCL["Core UI"] },
                { key = "bars", label = RCL["Bars"] },
                { key = "raid", label = RCL["Raid Tools"] },
            },
            selected = RC.colorSubTab,
            onClick = function(tabKey)
                RC.colorSubTab = tabKey
                RC:ClearSidebarContent(RC.sidebarConfigFrame, true)
                RC:ShowSidebarFontSettings(frame, true)
                C_Timer.After(0.05, function()
                    RC:RestoreScrollPosition(RC.sidebarConfigFrame)
                end)
            end,
        })

        yPos = yPos - 32

        yPos = self:RenderColorTab(parent, yPos, frame, RC.colorSubTab)

        return yPos
    end

    -- Generic category card: every key of self.defaultColors[categoryKey]
    -- as a row, alphabetical by label, under the category preview.
    function RC:CreateColorCategoryCard(parent, yPos, categoryKey, categoryLabel, previewBuilder, desc)
        local entries = {}
        local colors = self.defaultColors and self.defaultColors[categoryKey]
        if colors then
            for k in pairs(colors) do
                local e = self:MakeColorEntry(categoryKey, k)
                if e then table_insert(entries, e) end
            end
            -- Alphabetical by label keeps positions stable when a future
            -- update adds keys to the category.
            table_sort(entries, function(a, b)
                local la, lb = tostring(a.label or ""):lower(), tostring(b.label or ""):lower()
                if la == lb then return a.key < b.key end
                return la < lb
            end)
        end
        return self:CreateColorRowCard(parent, yPos, categoryLabel, entries, {
            desc = desc,
            previewBuilder = previewBuilder,
            previewHeight = 55,
            resetAll = function() RC:ResetColorCategory(categoryKey) end,
        })
    end

    -- The Bars and Raid Tools previews draw through this pool: each
    -- rebuild hands back the frames, strings and textures the last one made
    -- (in call order) instead of making new ones, so a repaint after every
    -- colour change creates nothing. They are drawn in the preview pane
    -- (RenderColorTab) and repaint there on each change.
    local function PreviewPool(preview)
        local p = preview._rcPool
        if not p then
            p = { f = {}, s = {}, t = {} }
            preview._rcPool = p
            function p:Frame(kind, name, parent, tmpl)
                self.fi = self.fi + 1
                local o = self.f[self.fi]
                if not o then o = CreateFrame(kind, name, parent, tmpl) self.f[self.fi] = o end
                o:Show()
                return o
            end
            function p:FS(parent, layer, tmpl, size, outline)
                self.si = self.si + 1
                local o = self.s[self.si]
                if not o then o = RC:CreateFontString(parent, layer, tmpl, size, outline) self.s[self.si] = o end
                o:Show()
                return o
            end
            function p:Tex(owner, name, layer, tmpl, sub)
                self.ti = self.ti + 1
                local o = self.t[self.ti]
                if not o then o = owner:CreateTexture(name, layer, tmpl, sub) self.t[self.ti] = o end
                o:Show()
                return o
            end
        end
        p.fi, p.si, p.ti = 0, 0, 0
        return p
    end

    local ColorPreviews = {}
    -- Windows, buttons, the sidebar and scrollbars have no card preview:
    -- the preview pane shows them on a miniature of the window itself.
    ColorPreviews["raids"] = function(preview, cardRef)
            local function buildPreview()
                local pool = PreviewPool(preview)

                local enCol = RC:GetColor("raids", "enabled")
                local disCol = RC:GetColor("raids", "disabled")
                local bossEnBg = RC:GetColor("raids", "bossEnabled")
                local bossDisBg = RC:GetColor("raids", "bossDisabled")
                local abilAct = RC:GetColor("raids", "abilityActive")
                local abilInact = RC:GetColor("raids", "abilityInactive")
                local txtGray = RC:GetColor("text", "gray")

                local row1 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                row1:SetSize(95, 20)
                row1:SetPoint("TOPLEFT", preview, "TOPLEFT", 5, -5)
                row1:SetBackdrop({bgFile = RC.UI.FLAT, edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                row1:SetBackdropColor(bossEnBg.r, bossEnBg.g, bossEnBg.b, 1)
                row1:SetBackdropBorderColor(0, 0, 0, 1)

                local ind1 = pool:Tex(row1, nil, "ARTWORK")
                ind1:SetSize(8, 8)
                ind1:SetPoint("LEFT", row1, "LEFT", 4, 0)
                ind1:SetColorTexture(enCol.r, enCol.g, enCol.b, 1)

                local txt1 = pool:FS(row1, "OVERLAY", nil, 8)
                txt1:SetPoint("LEFT", ind1, "RIGHT", 4, 0)
                txt1:SetText(RCL["Enabled Boss"])
                txt1:SetTextColor(txtGray.r + 0.2, txtGray.g + 0.2, txtGray.b + 0.2)

                local row2 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                row2:SetSize(95, 20)
                row2:SetPoint("LEFT", row1, "RIGHT", 5, 0)
                row2:SetBackdrop({bgFile = RC.UI.FLAT, edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                row2:SetBackdropColor(bossDisBg.r, bossDisBg.g, bossDisBg.b, 1)
                row2:SetBackdropBorderColor(0, 0, 0, 1)

                local ind2 = pool:Tex(row2, nil, "ARTWORK")
                ind2:SetSize(8, 8)
                ind2:SetPoint("LEFT", row2, "LEFT", 4, 0)
                ind2:SetColorTexture(disCol.r, disCol.g, disCol.b, 1)

                local txt2 = pool:FS(row2, "OVERLAY", nil, 8)
                txt2:SetPoint("LEFT", ind2, "RIGHT", 4, 0)
                txt2:SetText(RCL["Disabled Boss"])
                txt2:SetTextColor(txtGray.r, txtGray.g, txtGray.b)

                local ab1 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                ab1:SetSize(40, 16)
                ab1:SetPoint("BOTTOMLEFT", preview, "BOTTOMLEFT", 5, 5)
                ab1:SetBackdrop({bgFile = RC.UI.FLAT, edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                ab1:SetBackdropColor(abilAct.r, abilAct.g, abilAct.b, 1)
                ab1:SetBackdropBorderColor(0, 0, 0, 1)
                local ab1Txt = pool:FS(ab1, "OVERLAY", nil, 7)
                ab1Txt:SetPoint("CENTER")
                ab1Txt:SetText(RCL["Active"])
                ab1Txt:SetTextColor(txtGray.r + 0.2, txtGray.g + 0.2, txtGray.b + 0.2)

                local ab2 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                ab2:SetSize(45, 16)
                ab2:SetPoint("LEFT", ab1, "RIGHT", 4, 0)
                ab2:SetBackdrop({bgFile = RC.UI.FLAT, edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                ab2:SetBackdropColor(abilInact.r, abilInact.g, abilInact.b, 1)
                ab2:SetBackdropBorderColor(0, 0, 0, 1)
                local ab2Txt = pool:FS(ab2, "OVERLAY", nil, 7)
                ab2Txt:SetPoint("CENTER")
                ab2Txt:SetText(RCL["Inactive"])
                ab2Txt:SetTextColor(txtGray.r, txtGray.g, txtGray.b)
            end

            cardRef.rebuildPreview = buildPreview
            buildPreview()
        end

    ColorPreviews["consumables"] = function(preview, cardRef)
            local function buildPreview()
                local pool = PreviewPool(preview)

                local fullCol = RC:GetColor("consumables", "stockFull")
                local medCol = RC:GetColor("consumables", "stockMedium")
                local lowCol = RC:GetColor("consumables", "stockLow")
                local emptyCol = RC:GetColor("consumables", "stockEmpty")
                local headerCol = RC:GetColor("consumables", "categoryHeader")
                local hoverCol = RC:GetColor("consumables", "hoverBorder")
                local btnBg = RC:GetColor("buttons", "normalBackground")

                local headerTxt = pool:FS(preview, "OVERLAY", nil, 9)
                headerTxt:SetPoint("TOPLEFT", preview, "TOPLEFT", 8, -5)
                headerTxt:SetText(RCL["Flasks"])
                headerTxt:SetTextColor(headerCol.r, headerCol.g, headerCol.b)

                local items = {
                    {count = "20", col = fullCol, hover = false},
                    {count = "8", col = medCol, hover = true},
                    {count = "3", col = lowCol, hover = false},
                    {count = "0", col = emptyCol, hover = false},
                }
                local xOff = 8
                for _, item in ipairs(items) do
                    local slot = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                    slot:SetSize(28, 28)
                    slot:SetPoint("BOTTOMLEFT", preview, "BOTTOMLEFT", xOff, 5)
                    slot:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                    slot:SetBackdropColor(btnBg.r, btnBg.g, btnBg.b, 0.8)

                    if item.hover then
                        slot:SetBackdropBorderColor(hoverCol.r, hoverCol.g, hoverCol.b, 1)
                    else
                        slot:SetBackdropBorderColor(0, 0, 0, 1)
                    end

                    local countTxt = pool:FS(slot, "OVERLAY", nil, 10)
                    countTxt:SetPoint("CENTER")
                    countTxt:SetText(item.count)
                    countTxt:SetTextColor(item.col.r, item.col.g, item.col.b)

                    xOff = xOff + 35
                end

                local desc = pool:FS(preview, "OVERLAY", nil, 7)
                desc:SetPoint("BOTTOMRIGHT", preview, "BOTTOMRIGHT", -5, 5)
                desc:SetText(RCL["Full | Med | Low | Empty"])
                local txtGray = RC:GetColor("text", "gray")
                desc:SetTextColor(txtGray.r * 0.7, txtGray.g * 0.7, txtGray.b * 0.7)
            end

            cardRef.rebuildPreview = buildPreview
            buildPreview()
        end

    ColorPreviews["tooltip"] = function(preview, cardRef)
            local function buildPreview()
                for _, child in ipairs({preview:GetChildren()}) do
                    if child ~= preview.resetBtn then
                        child:Hide()
                        child:SetParent(nil)
                    end
                end
                for _, region in ipairs({preview:GetRegions()}) do
                    if region:GetObjectType() == "FontString" then
                        region:Hide()
                    end
                end

                local ttBg = RC:GetColor("tooltip", "background")
                local ttBorder = RC:GetColor("tooltip", "border")
                local ttTitle = RC:GetColor("tooltip", "titleText")
                local ttBody = RC:GetColor("tooltip", "bodyText")

                local tt = CreateFrame("Frame", nil, preview, "BackdropTemplate")
                tt:SetSize(180, 45)
                tt:SetPoint("CENTER", preview, "CENTER", 0, 0)
                tt:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                tt:SetBackdropColor(ttBg.r, ttBg.g, ttBg.b, ttBg.a or 1)
                tt:SetBackdropBorderColor(ttBorder.r, ttBorder.g, ttBorder.b, 1)

                local title = RC:CreateFontString(tt, "OVERLAY", nil, 10)
                title:SetPoint("TOPLEFT", tt, "TOPLEFT", 8, -6)
                title:SetText(RCL["Item Name"])
                title:SetTextColor(ttTitle.r, ttTitle.g, ttTitle.b)

                local body = RC:CreateFontString(tt, "OVERLAY", nil, 9)
                body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
                body:SetPoint("RIGHT", tt, "RIGHT", -8, 0)
                body:SetText(RCL["Description of the item\nor ability goes here."])
                body:SetTextColor(ttBody.r, ttBody.g, ttBody.b)
                body:SetJustifyH("LEFT")
            end

            cardRef.rebuildPreview = buildPreview
            buildPreview()
        end

    ColorPreviews["actionBars"] = function(preview, cardRef)
            local function buildPreview()
                local pool = PreviewPool(preview)

                local itemBg = RC:GetColor("actionBars", "itemNormalBg")
                local itemActive = RC:GetColor("actionBars", "itemActiveBg")
                local timeGood = RC:GetColor("actionBars", "timeGood")
                local timeWarn = RC:GetColor("actionBars", "timeWarning")
                local timeCrit = RC:GetColor("actionBars", "timeCritical")
                local countNorm = RC:GetColor("actionBars", "countNormal")
                local countLow = RC:GetColor("actionBars", "countLow")

                local slot1 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                slot1:SetSize(28, 28)
                slot1:SetPoint("LEFT", preview, "LEFT", 8, 0)
                slot1:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                slot1:SetBackdropColor(itemBg.r, itemBg.g, itemBg.b, itemBg.a or 1)
                slot1:SetBackdropBorderColor(0, 0, 0, 1)

                local count1 = pool:FS(slot1, "OVERLAY", nil, 9)
                count1:SetPoint("CENTER")
                count1:SetText("10")
                count1:SetTextColor(countNorm.r, countNorm.g, countNorm.b)

                local slot2 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                slot2:SetSize(28, 28)
                slot2:SetPoint("LEFT", slot1, "RIGHT", 4, 0)
                slot2:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                slot2:SetBackdropColor(itemActive.r, itemActive.g, itemActive.b, itemActive.a or 1)
                slot2:SetBackdropBorderColor(0, 0, 0, 1)

                local count2 = pool:FS(slot2, "OVERLAY", nil, 9)
                count2:SetPoint("CENTER")
                count2:SetText("2")
                count2:SetTextColor(countLow.r, countLow.g, countLow.b)

                local time1 = pool:FS(preview, "OVERLAY", nil, 8)
                time1:SetPoint("BOTTOMLEFT", preview, "BOTTOMLEFT", 8, 8)
                time1:SetText("15m")
                time1:SetTextColor(timeGood.r, timeGood.g, timeGood.b)

                local time2 = pool:FS(preview, "OVERLAY", nil, 8)
                time2:SetPoint("LEFT", time1, "RIGHT", 12, 0)
                time2:SetText("5m")
                time2:SetTextColor(timeWarn.r, timeWarn.g, timeWarn.b)

                local time3 = pool:FS(preview, "OVERLAY", nil, 8)
                time3:SetPoint("LEFT", time2, "RIGHT", 12, 0)
                time3:SetText("1m")
                time3:SetTextColor(timeCrit.r, timeCrit.g, timeCrit.b)
            end

            cardRef.rebuildPreview = buildPreview
            buildPreview()
        end

    ColorPreviews["weaponBar"] = function(preview, cardRef)
            local function buildPreview()
                local pool = PreviewPool(preview)

                local btnBg = RC:GetColor("weaponBar", "buttonNormal")
                local elemCol = RC:GetColor("weaponBar", "elementalStone")
                local consCol = RC:GetColor("weaponBar", "consecratedStone")
                local denseCol = RC:GetColor("weaponBar", "denseStone")
                local frostCol = RC:GetColor("weaponBar", "frostOil")
                local timeGood = RC:GetColor("weaponBar", "timeGood")
                local timeWarn = RC:GetColor("weaponBar", "timeWarning")
                local txtGray = RC:GetColor("text", "gray")

                local stones = {
                    {col = elemCol, name = "Elem", time = "28m", timeCol = timeGood},
                    {col = consCol, name = "Cons", time = "5m", timeCol = timeWarn},
                    {col = denseCol, name = "Dense", time = "15m", timeCol = timeGood},
                    {col = frostCol, name = "Frost", time = "10m", timeCol = timeGood},
                }
                local xOff = 8
                for _, stone in ipairs(stones) do
                    local slot = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                    slot:SetSize(32, 32)
                    slot:SetPoint("TOPLEFT", preview, "TOPLEFT", xOff, -5)
                    slot:SetBackdrop({bgFile = RC.UI.FLAT, edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                    slot:SetBackdropColor(btnBg.r, btnBg.g, btnBg.b, 1)
                    slot:SetBackdropBorderColor(stone.col.r, stone.col.g, stone.col.b, 1)

                    local nameTxt = pool:FS(slot, "OVERLAY", nil, 7)
                    nameTxt:SetPoint("TOP", slot, "BOTTOM", 0, -1)
                    nameTxt:SetText(stone.name)
                    nameTxt:SetTextColor(stone.col.r, stone.col.g, stone.col.b)

                    local timeTxt = pool:FS(slot, "OVERLAY", nil, 8)
                    timeTxt:SetPoint("CENTER")
                    timeTxt:SetText(stone.time)
                    timeTxt:SetTextColor(stone.timeCol.r, stone.timeCol.g, stone.timeCol.b)

                    xOff = xOff + 42
                end
            end

            cardRef.rebuildPreview = buildPreview
            buildPreview()
        end

    ColorPreviews["consumablesBar"] = function(preview, cardRef)
            local function buildPreview()
                local pool = PreviewPool(preview)

                local btnBg = RC:GetColor("consumablesBar", "buttonNormal")
                local btnHov = RC:GetColor("consumablesBar", "buttonHover")
                local btnAct = RC:GetColor("consumablesBar", "buttonActive")
                local txtGray = RC:GetColor("text", "gray")

                local btn1 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                btn1:SetSize(32, 32)
                btn1:SetPoint("LEFT", preview, "LEFT", 8, 0)
                btn1:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                btn1:SetBackdropColor(btnBg.r, btnBg.g, btnBg.b, 1)
                btn1:SetBackdropBorderColor(0, 0, 0, 1)
                local lbl1 = pool:FS(preview, "OVERLAY", nil, 7)
                lbl1:SetPoint("TOP", btn1, "BOTTOM", 0, -1)
                lbl1:SetText(RCL["Normal"])
                lbl1:SetTextColor(txtGray.r, txtGray.g, txtGray.b)

                local btn2 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                btn2:SetSize(32, 32)
                btn2:SetPoint("LEFT", btn1, "RIGHT", 18, 0)
                btn2:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                btn2:SetBackdropColor(btnHov.r, btnHov.g, btnHov.b, 1)
                btn2:SetBackdropBorderColor(0, 0, 0, 1)
                local lbl2 = pool:FS(preview, "OVERLAY", nil, 7)
                lbl2:SetPoint("TOP", btn2, "BOTTOM", 0, -1)
                lbl2:SetText(RCL["Hover"])
                lbl2:SetTextColor(txtGray.r, txtGray.g, txtGray.b)

                local btn3 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                btn3:SetSize(32, 32)
                btn3:SetPoint("LEFT", btn2, "RIGHT", 18, 0)
                btn3:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                btn3:SetBackdropColor(btnAct.r, btnAct.g, btnAct.b, 1)
                btn3:SetBackdropBorderColor(0, 0, 0, 1)
                local lbl3 = pool:FS(preview, "OVERLAY", nil, 7)
                lbl3:SetPoint("TOP", btn3, "BOTTOM", 0, -1)
                lbl3:SetText(RCL["Active"])
                lbl3:SetTextColor(txtGray.r, txtGray.g, txtGray.b)
            end

            cardRef.rebuildPreview = buildPreview
            buildPreview()
        end

    ColorPreviews["potionsBar"] = function(preview, cardRef)
            local function buildPreview()
                local pool = PreviewPool(preview)

                local btnBg = RC:GetColor("potionsBar", "buttonNormal")
                local btnHov = RC:GetColor("potionsBar", "buttonHover")
                local btnAct = RC:GetColor("potionsBar", "buttonActive")
                local txtGray = RC:GetColor("text", "gray")

                local btn1 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                btn1:SetSize(32, 32)
                btn1:SetPoint("LEFT", preview, "LEFT", 8, 0)
                btn1:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                btn1:SetBackdropColor(btnBg.r, btnBg.g, btnBg.b, 1)
                btn1:SetBackdropBorderColor(0, 0, 0, 1)
                local lbl1 = pool:FS(preview, "OVERLAY", nil, 7)
                lbl1:SetPoint("TOP", btn1, "BOTTOM", 0, -1)
                lbl1:SetText(RCL["Normal"])
                lbl1:SetTextColor(txtGray.r, txtGray.g, txtGray.b)

                local btn2 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                btn2:SetSize(32, 32)
                btn2:SetPoint("LEFT", btn1, "RIGHT", 18, 0)
                btn2:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                btn2:SetBackdropColor(btnHov.r, btnHov.g, btnHov.b, 1)
                btn2:SetBackdropBorderColor(0, 0, 0, 1)
                local lbl2 = pool:FS(preview, "OVERLAY", nil, 7)
                lbl2:SetPoint("TOP", btn2, "BOTTOM", 0, -1)
                lbl2:SetText(RCL["Hover"])
                lbl2:SetTextColor(txtGray.r, txtGray.g, txtGray.b)

                local btn3 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                btn3:SetSize(32, 32)
                btn3:SetPoint("LEFT", btn2, "RIGHT", 18, 0)
                btn3:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                btn3:SetBackdropColor(btnAct.r, btnAct.g, btnAct.b, 1)
                btn3:SetBackdropBorderColor(0, 0, 0, 1)
                local lbl3 = pool:FS(preview, "OVERLAY", nil, 7)
                lbl3:SetPoint("TOP", btn3, "BOTTOM", 0, -1)
                lbl3:SetText(RCL["Active"])
                lbl3:SetTextColor(txtGray.r, txtGray.g, txtGray.b)
            end

            cardRef.rebuildPreview = buildPreview
            buildPreview()
        end

    ColorPreviews["gearManager"] = function(preview, cardRef)
            local function buildPreview()
                local pool = PreviewPool(preview)

                local slotEmpty = RC:GetColor("gearManager", "slotEmpty")
                local slotFilled = RC:GetColor("gearManager", "slotFilled")
                local slotHover = RC:GetColor("gearManager", "slotHoverBorder")
                local txtGray = RC:GetColor("text", "gray")

                local slot1 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                slot1:SetSize(28, 28)
                slot1:SetPoint("LEFT", preview, "LEFT", 8, 0)
                slot1:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                slot1:SetBackdropColor(slotEmpty.r, slotEmpty.g, slotEmpty.b, 1)
                do local _bn = RC:GetColor("ui", "borderNormal"); slot1:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
                local lbl1 = pool:FS(preview, "OVERLAY", nil, 7)
                lbl1:SetPoint("TOP", slot1, "BOTTOM", 0, -1)
                lbl1:SetText(RCL["Empty"])
                lbl1:SetTextColor(txtGray.r, txtGray.g, txtGray.b)

                local slot2 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                slot2:SetSize(28, 28)
                slot2:SetPoint("LEFT", slot1, "RIGHT", 20, 0)
                slot2:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                slot2:SetBackdropColor(slotFilled.r, slotFilled.g, slotFilled.b, 1)
                do local _bn = RC:GetColor("ui", "borderNormal"); slot2:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
                local lbl2 = pool:FS(preview, "OVERLAY", nil, 7)
                lbl2:SetPoint("TOP", slot2, "BOTTOM", 0, -1)
                lbl2:SetText(RCL["Filled"])
                lbl2:SetTextColor(txtGray.r, txtGray.g, txtGray.b)

                local slot3 = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                slot3:SetSize(28, 28)
                slot3:SetPoint("LEFT", slot2, "RIGHT", 20, 0)
                slot3:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                slot3:SetBackdropColor(slotFilled.r, slotFilled.g, slotFilled.b, 1)
                slot3:SetBackdropBorderColor(slotHover.r, slotHover.g, slotHover.b, 1)
                local lbl3 = pool:FS(preview, "OVERLAY", nil, 7)
                lbl3:SetPoint("TOP", slot3, "BOTTOM", 0, -1)
                lbl3:SetText(RCL["Hover"])
                lbl3:SetTextColor(txtGray.r, txtGray.g, txtGray.b)
            end

            cardRef.rebuildPreview = buildPreview
            buildPreview()
        end

    ColorPreviews["battleShoutReminder"] = function(preview, cardRef)
            local function buildPreview()
                local pool = PreviewPool(preview)

                local normBorder = RC:GetColor("battleShoutReminder", "normalBorder")
                local missBorder = RC:GetColor("battleShoutReminder", "missingBorder")
                local missText = RC:GetColor("battleShoutReminder", "missingText")
                local allBuffed = RC:GetColor("battleShoutReminder", "allBuffedText")
                local bg = RC:GetColor("battleShoutReminder", "background")

                local normal = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                normal:SetSize(80, 24)
                normal:SetPoint("LEFT", preview, "LEFT", 8, 8)
                normal:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                normal:SetBackdropColor(bg.r, bg.g, bg.b, bg.a or 1)
                normal:SetBackdropBorderColor(normBorder.r, normBorder.g, normBorder.b, 1)

                local normTxt = pool:FS(normal, "OVERLAY", nil, 9)
                normTxt:SetPoint("CENTER")
                normTxt:SetText(RCL["All Buffed"])
                normTxt:SetTextColor(allBuffed.r, allBuffed.g, allBuffed.b)

                local missing = pool:Frame("Frame", nil, preview, "BackdropTemplate")
                missing:SetSize(80, 24)
                missing:SetPoint("BOTTOM", preview, "BOTTOM", 0, 8)
                missing:SetBackdrop({bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                missing:SetBackdropColor(bg.r, bg.g, bg.b, bg.a or 1)
                missing:SetBackdropBorderColor(missBorder.r, missBorder.g, missBorder.b, 1)

                local missTxt = pool:FS(missing, "OVERLAY", nil, 9)
                missTxt:SetPoint("CENTER")
                missTxt:SetText(RCL["5 Missing"])
                missTxt:SetTextColor(missText.r, missText.g, missText.b)
            end

            cardRef.rebuildPreview = buildPreview
            buildPreview()
        end

    _sbs.ColorPreviews = ColorPreviews
