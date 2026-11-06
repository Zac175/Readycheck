------------------------------------------------------------------------
-- Readycheck - Appearance: the preview and the Motion tab
-- RC:DeclareAppearancePreview() puts a working miniature of the
-- Readycheck window in the preview pane - its title bar, nav rows, a
-- settings card with a real checkbox, slider, dropdown and buttons from
-- the framework, a bar in the global texture, a reminder icon and text in
-- the global font - so every font, texture, colour and motion setting on
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

    -- wide and short for the preview strip: the title bar on top, then the
    -- nav, a card with its controls in one line, and the bar / icon / text
    -- side by side (reads at 0.75 at Normal)
    local W, H = 740, 80
    local NAV_W = 74

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

    -- the nav rows in the window's own colours (sidebar.* / text.menu*)
    local NAV = {
        { text = RCL["SETTINGS"], kind = "category" },
        { text = RCL["General"],  kind = "normal" },
        { text = RCL["Reminders"], kind = "selected" },
        { text = RCL["Testing"],  kind = "disabled" },
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

        -- WINDOW
        local win = CreateFrame("Frame", nil, canvas)
        win:SetSize(W, H)
        win:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        win.bg = Flat(win)
        win.bg:SetAllPoints()
        win.border = UI:CreateSimpleBorder(win)
        st.win = win

        local bar = CreateFrame("Frame", nil, win)
        bar:SetPoint("TOPLEFT", win, "TOPLEFT", 1, -1)
        bar:SetPoint("TOPRIGHT", win, "TOPRIGHT", -1, -1)
        bar:SetHeight(18)
        UI:ApplyHeaderArt(bar, { stepX = NAV_W, leftColor = function() return RC:GetColor("sidebar", "background") end })
        local icon = UI:AddTitleIcon(bar, 14, 6)
        bar.title = RC:CreateFontString(bar, "OVERLAY", nil, 12)
        bar.title:SetPoint("LEFT", icon, "RIGHT", 6, 1)
        bar.title:SetText("Readycheck")
        st.bar = bar

        local nav = CreateFrame("Frame", nil, win)
        nav:SetPoint("TOPLEFT", bar, "BOTTOMLEFT", 0, 0)
        nav:SetPoint("BOTTOMLEFT", win, "BOTTOMLEFT", 1, 1)
        nav:SetWidth(NAV_W)
        nav.bg = Flat(nav)
        nav.bg:SetAllPoints()
        nav.rule = Flat(nav, "OVERLAY")
        nav.rule:SetWidth(1)
        nav.rule:SetPoint("TOPRIGHT", nav, "TOPRIGHT", 0, 0)
        nav.rule:SetPoint("BOTTOMRIGHT", nav, "BOTTOMRIGHT", 0, 0)
        nav.rows = {}
        local y = -3
        for i, r in ipairs(NAV) do
            local row = CreateFrame("Frame", nil, nav)
            row:SetPoint("TOPLEFT", nav, "TOPLEFT", 3, y)
            row:SetPoint("RIGHT", nav, "RIGHT", -3, 0)
            row:SetHeight(r.kind == "category" and 12 or 14)
            row.bg = Flat(row)
            row.bg:SetAllPoints()
            row.text = RC:CreateFontString(row, "OVERLAY", nil, r.kind == "category" and 8 or 10)
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.text:SetText(r.text)
            row.kind = r.kind
            nav.rows[i] = row
            y = y - (r.kind == "category" and 13 or 15)
        end
        st.nav = nav

        local content = CreateFrame("Frame", nil, win)
        content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 1, 0)
        content:SetPoint("BOTTOMRIGHT", win, "BOTTOMRIGHT", -1, 1)
        st.content = content

        -- a scrollbar rail down the content edge
        local rail = CreateFrame("Frame", nil, content)
        rail:SetWidth(8)
        rail:SetPoint("TOPRIGHT", content, "TOPRIGHT", -2, -4)
        rail:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -2, 4)
        rail.bg = Flat(rail)
        rail.bg:SetAllPoints()
        rail.border = UI:CreateSimpleBorder(rail)
        rail.thumb = Flat(rail, "OVERLAY")
        rail.thumb:SetPoint("TOPLEFT", rail, "TOPLEFT", 0, -10)
        rail.thumb:SetPoint("TOPRIGHT", rail, "TOPRIGHT", 0, -10)
        rail.thumb:SetHeight(22)
        st.rail = rail

        -- the card and real controls (the framework's own constructors)
        local card = RC:CreateSettingsCard(content, -8, RCL["Card title"])
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -4)
        card:SetSize(512, 52)
        st.card = card

        -- the controls in one line under the card's title
        local cb = UI:CreateCheckbox(card, RCL["Checkbox"], true)
        cb:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -28)
        cb:SetWidth(84)
        local sl = UI:CreateSlider(card, 0, 100, 60, 1)
        sl:SetPoint("TOPLEFT", card, "TOPLEFT", 100, -18)
        sl:SetWidth(110)
        sl:SetLabel(RCL["Slider"])
        local dd = UI:CreateScrollableDropdown(card, 110, RCL["Dropdown"], 3)
        dd:SetPoint("TOPLEFT", card, "TOPLEFT", 226, -24)
        dd:SetItems({ { text = RCL["Option one"], value = 1 }, { text = RCL["Option two"], value = 2 } }, function() end)
        dd:SetSearchEnabled(false)
        local b1 = UI:CreateStyledButton(card, RCL["Button"], 60, 20)
        b1:SetPoint("TOPLEFT", card, "TOPLEFT", 352, -26)
        local b2 = UI:CreateStyledButton(card, RCL["On"], 40, 20)
        b2:SetPoint("LEFT", b1, "RIGHT", 4, 0)
        b2:SetActive(true)
        local b3 = UI:CreateStyledButton(card, RCL["Off"], 40, 20)
        b3:SetPoint("LEFT", b2, "RIGHT", 4, 0)
        b3:Disable()

        -- a bar in the global texture
        local barBox = CreateFrame("Frame", nil, content)
        barBox:SetPoint("TOPLEFT", card, "TOPRIGHT", 10, -10)
        barBox:SetSize(90, 10)
        barBox.track = Flat(barBox)
        barBox.track:SetAllPoints()
        barBox.fill = barBox:CreateTexture(nil, "ARTWORK")
        barBox.fill:SetPoint("TOPLEFT", barBox, "TOPLEFT", 0, 0)
        barBox.fill:SetPoint("BOTTOMLEFT", barBox, "BOTTOMLEFT", 0, 0)
        barBox.fill:SetWidth(98)
        barBox.border = UI:CreateSimpleBorder(barBox)
        st.barBox = barBox

        -- a reminder icon: the ready dress and halo, as on the popup
        local ready = CreateFrame("Frame", nil, content)
        ready:SetSize(22, 22)
        ready:SetPoint("LEFT", barBox, "RIGHT", 10, 0)
        ready.texture = ready:CreateTexture(nil, "ARTWORK")
        ready.texture:SetAllPoints()
        ready.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ready.texture:SetTexture("Interface\\Icons\\Ability_CriticalStrike")
        UI:DressReadyIcon(ready, 22)
        st.ready = ready

        local body = content:CreateFontString(nil, "OVERLAY")
        body:SetPoint("TOPLEFT", barBox, "BOTTOMLEFT", 0, -14)
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
            fs:SetPoint("TOPLEFT", textPanel, "TOPLEFT", 12 + ((i - 1) % 5) * colW, -16 - math_floor((i - 1) / 5) * 28)
            RC:ApplyCustomFont(fs)
            fs:SetText(line[2])
            fs.colorKey = line[1]
            textPanel.lines[i] = fs
        end
        st.textPanel = textPanel
    end

    local function Update(canvas, P)
        local st = P.store
        local textMode = (P.mode == "text")
        if textMode then st.win:Hide() st.textPanel:Show() else st.textPanel:Hide() st.win:Show() end
        local fs = RC.db and RC.db.fontSettings or {}
        local alpha = fs.mainWindowBgOpacity or 1

        if textMode then
            Paint(st.textPanel.bg, "ui", "windowBackground", 1)
            st.textPanel.bg:SetAlpha(alpha)
            RC.UI:UpdateBorderColor(st.textPanel.border, RC:GetColor("ui", "borderNormal"), 1)
            for _, line in ipairs(st.textPanel.lines) do
                RC:ApplyCustomFont(line)
                TextColor(line, "text", line.colorKey)
            end
            return
        end

        Paint(st.win.bg, "ui", "windowBackground", 1)
        st.win.bg:SetAlpha(alpha)
        RC.UI:UpdateBorderColor(st.win.border, RC:GetColor("ui", "borderNormal"), 1)
        if st.bar.RepaintArt then st.bar:RepaintArt() end
        if RC.UI.PaintMark and st.bar.titleIcon then RC.UI:PaintMark(st.bar.titleIcon) end
        TextColor(st.bar.title, "ui", "headerText")

        Paint(st.nav.bg, "sidebar", "background")
        st.nav.bg:SetAlpha(alpha)
        Paint(st.nav.rule, "ui", "borderNormal")
        for _, row in ipairs(st.nav.rows) do
            if row.kind == "category" then
                row.bg:SetVertexColor(0, 0, 0, 0)
                TextColor(row.text, "text", "menuCategory")
            elseif row.kind == "selected" then
                Paint(row.bg, "sidebar", "buttonSelected")
                TextColor(row.text, "text", "menuSelected")
            elseif row.kind == "disabled" then
                Paint(row.bg, "sidebar", "buttonNormal", 0.5)
                TextColor(row.text, "text", "menuDisabled")
            else
                Paint(row.bg, "sidebar", "buttonNormal")
                TextColor(row.text, "text", "menuNormal")
            end
        end

        Paint(st.rail.bg, "scrollbar", "track")
        Paint(st.rail.thumb, "scrollbar", "thumb", 1)
        RC.UI:UpdateBorderColor(st.rail.border, RC:GetColor("ui", "borderNormal"), 1)

        -- the framework widgets repaint themselves from the theme
        RepaintTree(st.content)

        Paint(st.barBox.track, "ui", "elementBackground", 1)
        RC:ApplyTextureSpec(st.barBox.fill, nil)
        local g = RC:GetColor("text", "green")
        st.barBox.fill:SetVertexColor(g.r * 0.8, g.g * 0.8, g.b * 0.8, 1)
        RC.UI:UpdateBorderColor(st.barBox.border, RC:GetColor("ui", "borderNormal"), 1)

        RC.UI:RepaintReadyIcon(st.ready)
        RC.UI:SetReadyIconGlow(st.ready, "pulse")

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
