------------------------------------------------------------------------
-- Readycheck - Appearance: the preview and the Motion tab
-- RC:DeclareAppearancePreview() puts a working miniature of the
-- Readycheck window in the preview pane, built from the window's own
-- parts: the mark and the name over the nav column, a group and two page
-- rows, the page's tab row and a section with a real checkbox, slider,
-- dropdown and buttons. Beside it, what sits on the screen: a piece's
-- header strip, a bar in the global texture, a reminder icon and text in
-- the global font. So every font, texture, colour and motion setting on
-- the Appearance page shows on the real widgets as it changes. "Text"
-- mode lists every text colour.
-- RC:ShowAppearanceMotionContent is the Motion tab: db.motion.enabled
-- (every Readycheck animation on/off) and db.motion.speed.
------------------------------------------------------------------------
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_max, math_min = math.floor, math.max, math.min
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end

    -- wide and short for the preview strip. (2026-11-25, seen in the game:
    -- the miniature still drew the gold title bar the window lost, its
    -- checkbox was stretched under the slider's label, the bar ran over
    -- the icon and the text was cut off at the strip's edge.) The window
    -- part is now the /rc window as it is drawn today; the pieces that sit
    -- on the screen have a column of their own to its right.
    local W, H = 870, 126
    local WIN_W, NAV_W = 740, 170
    local SIDE_X = WIN_W + 10
    local SIDE_W = W - SIDE_X
    local CARD_H = 70

    local function RepaintTree(root, depth)
        depth = depth or 0
        if not root or depth > 10 then return end
        if type(root.Repaint) == "function" then pcall(root.Repaint, root) end
        if root.GetChildren then
            for _, c in ipairs({ root:GetChildren() }) do RepaintTree(c, depth + 1) end
        end
    end

    local function Flat(parent, layer, sub)
        local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sub)
        t:SetTexture(RC.UI.FLAT)
        return t
    end

    local function Paint(tex, cat, key, alpha)
        local c = RC:GetColor(cat, key)
        tex:SetVertexColor(c.r, c.g, c.b, alpha or c.a or 1)
    end

    local function TextColor(fs, cat, key)
        local c = RC:GetColor(cat, key)
        fs:SetTextColor(c.r, c.g, c.b, 1)
    end

    -- the nav column: a group, a page and the open page
    local NAV = {
        { text = RCL["Settings"], kind = "category" },
        { text = RCL["General"],  kind = "normal" },
        { text = RCL["Appearance"], kind = "selected" },
    }

    -- every text colour, as the colours page names them
    local TEXT_LINES = {
        { "normal", RCL["Default text"] }, { "white", RCL["Important"] },
        { "gray", RCL["Description text"] }, { "gold", RCL["Title"] },
        { "green", RCL["Success"] }, { "orange", RCL["Warning"] },
        { "red", RCL["Error"] }, { "yellow", RCL["Low"] }, { "blue", RCL["Info: cooldown 30s"] },
        { "disabled", RCL["Disabled"] },
    }

    local function Build(canvas, P)
        local st = P.store
        local UI = RC.UI
        local S = UI.S

        -- THE WINDOW. Marked as part of the settings window (_rcSetRoot),
        -- so the framework's constructors give every piece the window's
        -- look and the window's font, exactly as on the real one.
        local win = CreateFrame("Frame", nil, canvas)
        win._rcSetRoot = true
        win:SetSize(WIN_W, H)
        win:SetPoint("LEFT", canvas, "LEFT", 0, 0)
        win.bg = Flat(win)
        win.bg:SetAllPoints()
        win.border = UI:CreateSimpleBorder(win)
        st.win = win

        -- the nav column: the mark and the name, then the rows
        local nav = CreateFrame("Frame", nil, win)
        nav:SetPoint("TOPLEFT", win, "TOPLEFT", 0, 0)
        nav:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 0, 0)
        nav:SetWidth(NAV_W)
        nav.bg = Flat(nav)
        nav.bg:SetAllPoints()
        nav.rule = Flat(nav, "OVERLAY")
        RC.Line(nav.rule, "V", 1)
        nav.rule:SetPoint("TOPRIGHT", nav, "TOPRIGHT", 0, 0)
        nav.rule:SetPoint("BOTTOMRIGHT", nav, "BOTTOMRIGHT", 0, 0)
        nav.mark = nav:CreateTexture(nil, "ARTWORK", nil, 3)
        nav.mark:SetSize(22, 22)
        nav.mark:SetPoint("TOPLEFT", nav, "TOPLEFT", 16, -9)
        nav.mark:SetTexture("Interface\\AddOns\\Readycheck\\Media\\Checkmark")
        nav.mark:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        nav.first = RC:CreateFontString(nav, "OVERLAY", nil, 18)
        nav.first:SetPoint("LEFT", nav.mark, "RIGHT", 7, 0)
        nav.first:SetText(RCL["Ready"])
        nav.second = RC:CreateFontString(nav, "OVERLAY", nil, 18)
        nav.second:SetPoint("LEFT", nav.first, "RIGHT", 0, 0)
        nav.second:SetText(RCL["check"])
        -- (the ring and the light behind the mark, as on the window)
        if UI.AnimateMark then pcall(UI.AnimateMark, UI, nav.mark, nav, { inset = 0 }) end
        nav.rows = {}
        local y = -40
        for i, r in ipairs(NAV) do
            local isGroup = (r.kind == "category")
            local row = RC:CreateSidebarButton(nav, { name = r.text, category = isGroup or nil }, y, not isGroup)
            row:SetWidth(NAV_W - 1)
            row.isSelected = (r.kind == "selected")
            row.isExpanded = true
            nav.rows[i] = row
            y = y - (row.buttonHeight or S.CHILD_ROW)
        end
        st.nav = nav

        -- the page: its tab row and one section
        local content = CreateFrame("Frame", nil, win)
        content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 0, -1)
        content:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -1, 1)
        content:SetClipsChildren(true)
        st.content = content

        local tabs
        tabs = UI:CreateTabGroup(content, {
            tabs = { { key = "fonts", label = RCL["Fonts"] }, { key = "colors", label = RCL["Colors"] },
                     { key = "motion", label = RCL["Motion"] } },
            selected = "fonts", y = 0, bar = true,
            onClick = function(key) if tabs then tabs:SetSelected(key) end end,
        })
        st.tabs = tabs

        -- the page's scroll bar down the content edge
        local rail = CreateFrame("Frame", nil, content)
        rail:SetWidth(S.SCROLL_W)
        rail:SetPoint("TOPRIGHT", content, "TOPRIGHT", -4, -(S.TABS + 6))
        rail:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -4, 6)
        rail.bg = Flat(rail)
        rail.bg:SetAllPoints()
        rail.thumb = Flat(rail, "OVERLAY")
        rail.thumb:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -6)
        rail.thumb:SetPoint("TOPRIGHT", rail, "TOPRIGHT", 0, -6)
        rail.thumb:SetHeight(26)
        st.rail = rail

        -- the section and real controls (the framework's own constructors),
        -- in one line under the section's title
        local card = RC:CreateSettingsCard(content, -(S.TABS + 6), RCL["Card title"])
        card:SetHeight(CARD_H)
        st.card = card

        local cb = UI:CreateCheckbox(card, RCL["Checkbox"], true)
        cb:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -37)
        local sl = UI:CreateSlider(card, 0, 100, 60, 1)
        sl:SetPoint("TOPLEFT", card, "TOPLEFT", 120, -30)
        sl:SetWidth(130)
        sl:SetLabel(RCL["Slider"])
        local dd = UI:CreateScrollableDropdown(card, 110, RCL["Dropdown"], 3)
        dd:SetPoint("TOPLEFT", card, "TOPLEFT", 264, -35)
        dd:SetItems({ { text = RCL["Option one"], value = 1 }, { text = RCL["Option two"], value = 2 } }, function() end)
        dd:SetSearchEnabled(false)
        local b1 = UI:CreateStyledButton(card, RCL["Button"], 56, 22)
        b1:SetPoint("TOPLEFT", card, "TOPLEFT", 388, -35)
        local b2 = UI:CreateStyledButton(card, RCL["On"], 38, 22)
        b2:SetPoint("LEFT", b1, "RIGHT", 4, 0)
        b2:SetActive(true)
        local b3 = UI:CreateStyledButton(card, RCL["Off"], 38, 22)
        b3:SetPoint("LEFT", b2, "RIGHT", 4, 0)
        b3:Disable()

        -- ON THE SCREEN: the pieces Readycheck places in the game wear the
        -- global font and texture, not the window's.
        local side = CreateFrame("Frame", nil, canvas)
        side:SetSize(SIDE_W, H)
        side:SetPoint("LEFT", canvas, "LEFT", SIDE_X, 0)
        st.side = side

        -- a piece's header strip (the trackers', the reminders')
        local strip = CreateFrame("Frame", nil, side)
        strip:SetPoint("TOPLEFT", side, "TOPLEFT", 0, -8)
        strip:SetPoint("TOPRIGHT", side, "TOPRIGHT", 0, -8)
        strip:SetHeight(18)
        UI:ApplyHeaderArt(strip, { compact = true })
        strip.title = RC:CreateFontString(strip, "OVERLAY", nil, 11)
        strip.title:SetPoint("LEFT", strip, "LEFT", 6, 0)
        strip.title:SetText(RCL["On screen"])
        st.strip = strip

        -- a bar in the global texture
        local barBox = CreateFrame("Frame", nil, side)
        barBox:SetPoint("TOPLEFT", strip, "BOTTOMLEFT", 0, -8)
        barBox:SetPoint("TOPRIGHT", strip, "BOTTOMRIGHT", 0, -8)
        barBox:SetHeight(10)
        barBox.track = Flat(barBox)
        barBox.track:SetAllPoints()
        barBox.fill = barBox:CreateTexture(nil, "ARTWORK")
        barBox.fill:SetPoint("TOPLEFT", barBox, "TOPLEFT", 0, 0)
        barBox.fill:SetPoint("BOTTOMLEFT", barBox, "BOTTOMLEFT", 0, 0)
        barBox.fill:SetWidth(math_floor(SIDE_W * 0.7))
        barBox.border = UI:CreateSimpleBorder(barBox)
        st.barBox = barBox

        -- a reminder icon: the ready dress and halo, as on the popup
        local ready = CreateFrame("Frame", nil, side)
        ready:SetSize(24, 24)
        ready:SetPoint("TOPLEFT", barBox, "BOTTOMLEFT", 2, -10)
        ready.texture = ready:CreateTexture(nil, "ARTWORK")
        ready.texture:SetAllPoints()
        ready.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ready.texture:SetTexture("Interface\\Icons\\Ability_CriticalStrike")
        UI:DressReadyIcon(ready, 24)
        st.ready = ready

        -- text in the global font, at the base size (it wraps in the column)
        local body = side:CreateFontString(nil, "OVERLAY")
        body:SetPoint("TOPLEFT", ready, "TOPRIGHT", 10, 2)
        body:SetPoint("RIGHT", side, "RIGHT", 0, 0)
        body:SetJustifyH("LEFT")
        body:SetJustifyV("TOP")
        body:SetWordWrap(true)
        RC:ApplyCustomFont(body)
        body:SetText(RCL["Body text in your font"])
        st.body = body

        -- TEXT mode: every text colour in the global font
        local textPanel = CreateFrame("Frame", nil, canvas)
        textPanel:SetSize(W, H)
        textPanel:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        textPanel.bg = Flat(textPanel)
        textPanel.bg:SetAllPoints()
        textPanel.border = UI:CreateSimpleBorder(textPanel)
        textPanel.lines = {}
        -- two lines of five columns
        local colW = math_floor((W - 24) / 5)
        for i, line in ipairs(TEXT_LINES) do
            local fs = textPanel:CreateFontString(nil, "OVERLAY")
            fs:SetPoint("TOPLEFT", textPanel, "TOPLEFT", 12 + ((i - 1) % 5) * colW, -30 - math_floor((i - 1) / 5) * 36)
            RC:ApplyCustomFont(fs)
            fs:SetText(line[2])
            fs.colorKey = line[1]
            textPanel.lines[i] = fs
        end
        st.textPanel = textPanel
    end

    local function Update(canvas, P)
        local st = P.store
        local UI = RC.UI
        local S = UI.S
        local textMode = (P.mode == "text")
        st.win:SetShown(not textMode)
        st.side:SetShown(not textMode)
        st.textPanel:SetShown(textMode)
        local fs = RC.db and RC.db.fontSettings or {}
        local alpha = fs.mainWindowBgOpacity or 1

        if textMode then
            Paint(st.textPanel.bg, "ui", "windowBackground", 1)
            st.textPanel.bg:SetAlpha(alpha)
            UI:UpdateBorderColor(st.textPanel.border, RC:GetColor("ui", "borderNormal"), 1)
            for _, line in ipairs(st.textPanel.lines) do
                RC:ApplyCustomFont(line)
                TextColor(line, "text", line.colorKey)
            end
            return
        end

        -- the window's ground, edge and nav band: what the /rc window's own
        -- repaint does (Sidebar_Window, frame:RepaintShell)
        st.win.bg:SetVertexColor(UI:SCol("windowBackground", 1))
        st.win.bg:SetAlpha(alpha)
        if UI.Finish then UI:Finish(st.win, st.win.bg, "window", alpha) end
        UI:UpdateBorderColor(st.win.border, RC:GetColor("settings", "text"), S.BORDER_A)
        st.nav.bg:SetVertexColor(UI:SCol("shade", S.SIDEBAR_A))
        st.nav.bg:SetAlpha(alpha * S.SIDEBAR_A)
        st.nav.rule:SetVertexColor(UI:SCol("text", S.BORDER_A))
        if UI.PaintMark then UI:PaintMark(st.nav.mark) end
        local A = UI:SAccent()
        st.nav.first:SetTextColor(UI:SCol("text", 1))
        st.nav.second:SetTextColor(A.r, A.g, A.b, 1)
        if st.tabs and st.tabs.container and st.tabs.container.band then
            st.tabs.container.band:SetVertexColor(UI:SCol("shade", S.TAB_BAND_A))
        end
        st.rail.bg:SetVertexColor(UI:SCol("text", S.SCROLL_TRACK_A))
        st.rail.thumb:SetVertexColor(UI:ScrollThumbColor(false, 1))

        -- the nav rows, the tabs, the section and its controls repaint
        -- themselves from the theme
        RepaintTree(st.win)
        st.card:SetHeight(CARD_H)
        if st.card.LayBands then st.card.LayBands() end

        -- on the screen
        if st.strip.RepaintArt then st.strip:RepaintArt() end
        TextColor(st.strip.title, "ui", "headerText")
        Paint(st.barBox.track, "ui", "elementBackground", 1)
        RC:ApplyTextureSpec(st.barBox.fill, nil)
        local g = RC:GetColor("text", "green")
        st.barBox.fill:SetVertexColor(g.r * 0.8, g.g * 0.8, g.b * 0.8, 1)
        UI:UpdateBorderColor(st.barBox.border, RC:GetColor("ui", "borderNormal"), 1)

        UI:RepaintReadyIcon(st.ready)
        UI:SetReadyIconGlow(st.ready, "pulse")

        -- base size and style exactly as a string with no size of its own gets
        RC:ApplyCustomFont(st.body)
        TextColor(st.body, "text", "normal")
    end

    -- The window's own opening (RC.UI:PopIn, which follows the Motion
    -- switches) and the halo restarted at the current speed.
    local function Replay(canvas, P)
        local st = P.store
        local target = (P.mode == "text") and st.textPanel or st.win
        RC.UI:PopIn(target, 0.18)
        if st.ready and st.ready.haloPulse then
            st.ready.haloPulse:Stop()
            RC.UI:SetReadyIconGlow(st.ready, "pulse")
        end
    end

    function RC:DeclareAppearancePreview()
        return self.UI:DeclarePreview({
            key = "appearance.ui", title = RCL["Readycheck window"],
            width = W, height = H,
            build = Build, update = Update, replay = Replay,
            modes = { { id = "window", label = RCL["Window"] }, { id = "text", label = RCL["Text"] } },
        })
    end

    ------------------------------------------------------------------
    -- Motion tab
    ------------------------------------------------------------------
    local function Motion()
        local db = RC.db
        if type(db.motion) ~= "table" then db.motion = { enabled = true, speed = 1 } end
        return db.motion
    end

    function RC:ShowAppearanceMotionContent(parent, yPos, frame, P)
        local txtNorm = self:GetColor("text", "normal")
        local txtGray = self:GetColor("text", "gray")
        local m = Motion()

        local card = self:CreateSettingsCard(parent, yPos, RCL["Animations"])
        local cy = -32

        local sp
        self.UI:CreateSettingCheckbox(card, cy, RCL["Play animations"], m.enabled ~= false, function(cb)
            local on = cb:GetChecked() and true or false
            Motion().enabled = on
            if sp then RC.UI:SetWidgetEnabled(sp, on) end
            self:SaveConfigurationToProfile()
            if P then P.Replay() end
        end)
        cy = cy - 22
        local onDesc = self:CreateFontString(card, "OVERLAY", nil, 10)
        onDesc:SetPoint("TOPLEFT", card, "TOPLEFT", 35, cy)
        onDesc:SetPoint("RIGHT", card, "RIGHT", -14, 0)
        onDesc:SetJustifyH("LEFT")
        onDesc:SetText(RCL["Windows opening, reminders appearing and going, fades and glows. Off, everything changes at once and glows hold still."])
        onDesc:SetTextColor(txtGray.r, txtGray.g, txtGray.b)
        cy = cy - (onDesc:GetStringHeight() or 12) - 12

        local spLbl = self:CreateFontString(card, "OVERLAY", nil, 11)
        spLbl:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        spLbl:SetText(RCL["Speed"])
        spLbl:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b)
        cy = cy - 22
        local pct = math_floor((tonumber(m.speed) or 1) * 100 + 0.5)
        sp = self.UI:CreateSlider(card, 25, 400, pct, 5)
        sp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        sp.Text:SetText(pct .. "%")
        sp:SetScript("OnValueChanged", function(s, v)
            v = math_floor(v / 5 + 0.5) * 5
            s.Text:SetText(v .. "%")
            Motion().speed = v / 100
            if s.saveTimer then s.saveTimer:Cancel() end
            s.saveTimer = C_Timer.NewTimer(0.5, function() RC:SaveConfigurationToProfile() end)
        end)
        sp:SetScript("OnMouseUp", function() if P then P.Replay() end end)
        cy = cy - 40
        local spDesc = self:CreateFontString(card, "OVERLAY", nil, 10)
        spDesc:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        spDesc:SetPoint("RIGHT", card, "RIGHT", -14, 0)
        spDesc:SetJustifyH("LEFT")
        spDesc:SetText(RCL["100% plays every animation at its own length; 200% is twice as fast, 50% half as fast."])
        spDesc:SetTextColor(txtGray.r, txtGray.g, txtGray.b)
        cy = cy - (spDesc:GetStringHeight() or 12) - 10

        -- the speed means nothing while animations are off
        RC.UI:SetWidgetEnabled(sp, m.enabled ~= false)

        card:SetContentHeight(math.abs(cy))
        return yPos - card:GetHeight() - 15
    end
