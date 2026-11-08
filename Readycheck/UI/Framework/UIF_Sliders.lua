local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local math_floor, math_ceil, math_max, math_min, math_abs = math.floor, math.ceil, math.max, math.min, math.abs
local table_insert = table.insert
local CreateFrame = CreateFrame
local C_Timer = C_Timer

------------------------------------------------------------------------
-- Readycheck - UI Framework Sliders and Scrollable Dropdown
-- Owns CreateSlider (drag + click-to-type value) and the custom
-- scrollable dropdown used for long option lists (with optional
-- filter/search box). CreateDropdown, the plain native-menu-based
-- dropdown, lives in UIF_Dropdowns.lua instead - pick whichever fits.
------------------------------------------------------------------------

local RC = _G.Readycheck
if not RC then return end
RC._uif = RC._uif or {}
local _uif = RC._uif
local NotifySettingChanged, WrapNotify = _uif.NotifySettingChanged, _uif.WrapNotify
local S = _uif.S
local BASE, C, FLAT, CreateProfessionalFontString, GetAccentGold, GetBorderNormal, GetButtonHoverBG, GetButtonNormalBG, GetButtonTexture, GetCheckboxCheckmark, GetDropdownArrow, GetDropdownBG, GetDropdownItemHover, GetDropdownItemText, GetDropdownSelected, GetElementBG, GetScrollThumb, GetScrollTrack, GetTextGray, GetTextNormal, RegisterTexture =
      _uif.BASE, _uif.C, _uif.FLAT, _uif.CreateProfessionalFontString, _uif.GetAccentGold, _uif.GetBorderNormal, _uif.GetButtonHoverBG, _uif.GetButtonNormalBG, _uif.GetButtonTexture, _uif.GetCheckboxCheckmark, _uif.GetDropdownArrow, _uif.GetDropdownBG, _uif.GetDropdownItemHover, _uif.GetDropdownItemText, _uif.GetDropdownSelected, _uif.GetElementBG, _uif.GetScrollThumb, _uif.GetScrollTrack, _uif.GetTextGray, _uif.GetTextNormal, _uif.RegisterTexture
    -- Returns a Slider whose value display doubles as a click-to-type
    -- EditBox (editBoxFrame/editBox). editBoxFrame paints its background
    -- with a plain texture rather than SetBackdrop, since SetBackdrop on
    -- an EditBox (or its container) flickers a white cursor in Classic.
    -- .Text/.displayText is the value label, .parentFrame is the outer
    -- frame; SetPoint/Show/Hide are redirected to parentFrame.
    --
    -- Look: a 6px flat track (ui.elementBackground, 1px black ring) along
    -- the bottom of the 30px frame, an 8x10 flat block thumb
    -- (scrollbar.thumb) with its own 1px ring, and the value riding
    -- top-right ABOVE the track so the thumb never slides through text.
    -- No Blizzard slider art, no arrow buttons. The optional label
    -- (slider.label, 10px text.gray) sits top-left; callers that draw
    -- their own label above the slider keep doing so.
    function RC.UI:CreateSlider(parent, min, max, value, step)
        if value == nil then
            value = min
        end

        local sliderFrame = CreateFrame("Frame", nil, parent)
        sliderFrame:SetSize(BASE.SLIDER_WIDTH, 30)
        -- In the /rc window (5.0), the /zui slider in this one's place: a
        -- 4 px pill track (white 0.22), the part up to the thumb an accent
        -- pill (0.75), a round 14 px accent thumb on a disc of the window's
        -- colour, and the value in a small input box (white 0.53; 1.0 and
        -- an accent edge while typing).
        local set = RC.UI:InSettings(parent)
        sliderFrame._rcSet = set or nil

        -- THE LOOK: a thin flat track, the part up to the thumb filled in
        -- the thumb's colour, a square thumb that lights gold under the
        -- mouse and while dragged, and the value top-right (click it to
        -- type one). The mouse wheel moves it only while Shift is held, so
        -- scrolling the page over a slider never changes a setting; without
        -- Shift the wheel scrolls the page as if the slider were not there.
        local TRACK_H = 4
        local track = CreateFrame("Frame", nil, sliderFrame)
        track:SetHeight(TRACK_H)
        track:SetPoint("BOTTOMLEFT", sliderFrame, "BOTTOMLEFT", 0, 6)
        track:SetPoint("BOTTOMRIGHT", sliderFrame, "BOTTOMRIGHT", 0, 6)

        local trackBg = track:CreateTexture(nil, "BACKGROUND")
        trackBg:SetAllPoints()
        trackBg:SetTexture(FLAT)
        local elemBg = GetElementBG()
        trackBg:SetVertexColor(elemBg.r, elemBg.g, elemBg.b, 1)
        sliderFrame.trackBg = trackBg
        sliderFrame.trackBorder = self:CreateSimpleBorder(track)
        -- the filled part, left edge to the thumb
        local fill = track:CreateTexture(nil, "ARTWORK")
        fill:SetTexture(FLAT)
        fill:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT", 1, 1)
        fill:SetWidth(1)
        sliderFrame.fill = fill
        local trackPill, fillHost, fillPill
        if set then
            trackBg:SetAlpha(0)
            RC.UI:UpdateBorderColor(sliderFrame.trackBorder, GetBorderNormal(), 0)
            fill:SetAlpha(0)
            trackPill = RC.UI:Pill(track, "BACKGROUND", 1, S.TRACK_H)
            fillHost = CreateFrame("Frame", nil, track)
            fillHost:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
            fillHost:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT", 0, 0)
            fillHost:SetWidth(S.TRACK_H)
            fillPill = RC.UI:Pill(fillHost, "ARTWORK", 1, S.TRACK_H)
        end

        local slider = CreateFrame("Slider", nil, sliderFrame)
        slider:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 2)
        slider:SetPoint("BOTTOMRIGHT", track, "BOTTOMRIGHT", 0, -2)
        -- Above the track's frame level, or the track's OVERLAY ring
        -- strips draw straight through the thumb.
        slider:SetFrameLevel(track:GetFrameLevel() + 2)
        slider:SetOrientation("HORIZONTAL")
        slider:SetMinMaxValues(min, max)
        slider:SetValue(value)
        slider:SetValueStep(step)
        slider:SetObeyStepOnDrag(true)

        local thumb = slider:CreateTexture(nil, "OVERLAY")
        thumb:SetSize(10, TRACK_H + 6)
        thumb:SetTexture(FLAT)
        local thumbCol = GetScrollThumb()
        thumb:SetVertexColor(thumbCol.r, thumbCol.g, thumbCol.b, 1)
        slider:SetThumbTexture(thumb)
        slider.thumb = thumb
        local thumbBack
        if set then
            thumb:SetSize(S.THUMB, S.THUMB)
            RC.UI:DiscArt(thumb, S.THUMB)
            thumbBack = slider:CreateTexture(nil, "ARTWORK")
            thumbBack:SetSize(S.THUMB + 4, S.THUMB + 4)
            thumbBack:SetPoint("CENTER", thumb, "CENTER", 0, 0)
            RC.UI:DiscArt(thumbBack, S.THUMB + 4)
        else
            RC.UI:AddThumbBorder(slider)
        end

        -- the fill follows the value, and the track's width
        local function UpdateFill()
            local lo, hi = slider:GetMinMaxValues()
            local v = slider:GetValue() or lo
            local frac = (hi and lo and hi > lo) and math_max(0, math_min(1, (v - lo) / (hi - lo))) or 0
            local tw = (track:GetWidth() or 0) - 2
            local tb = thumb:GetWidth() or 10
            -- the thumb's centre travels from half a thumb in to half a thumb short
            local w = (tw > tb) and (tb / 2 + frac * (tw - tb)) or (frac * math_max(0, tw))
            fill:SetWidth(math_max(0.01, w))
            fill:SetShown(w >= 1)
            if fillHost then
                fillHost:SetWidth(math_max(S.TRACK_H, w + 1))
                fillPill:Show(w >= 1)
            end
        end
        track:SetScript("OnSizeChanged", UpdateFill)

        -- thumb: gold under the mouse and while dragged
        local hovered, dragging = false, false
        local function PaintThumb()
            if set then
                local A = RC.UI:SAccent()
                local k = (hovered or dragging) and 1.15 or 1
                thumb:SetVertexColor(math_min(1, A.r * k), math_min(1, A.g * k), math_min(1, A.b * k), 1)
                thumbBack:SetVertexColor(RC.UI:SCol("windowBackground", 1))
                trackPill:Color(RC.UI:SCol("text", S.SL_TRACK_A))
                fillPill:Color(A.r, A.g, A.b, S.SL_FILL_A)
                return
            end
            local c = (hovered or dragging) and GetAccentGold() or GetScrollThumb()
            thumb:SetVertexColor(c.r, c.g, c.b, 1)
            local f = GetScrollThumb()
            fill:SetVertexColor(f.r, f.g, f.b, (hovered or dragging) and 0.8 or 0.6)
        end
        -- Callers set their own OnValueChanged / OnMouseUp / OnEnter...;
        -- the look's part runs first whatever they install.
        do
            local rawSet = slider.SetScript
            local PRE = {
                OnValueChanged = function() UpdateFill() end,
                OnEnter = function() hovered = true PaintThumb() end,
                OnLeave = function() hovered = false PaintThumb() end,
                OnMouseDown = function() dragging = true PaintThumb() end,
                OnMouseUp = function() dragging = false PaintThumb() end,
            }
            slider.SetScript = function(self, name, fn)
                local pre = PRE[name]
                if not pre then return rawSet(self, name, fn) end
                return rawSet(self, name, function(...)
                    pre()
                    if fn then return fn(...) end
                end)
            end
            for name in pairs(PRE) do slider:SetScript(name, nil) end
        end


        local textContainer = CreateFrame("Frame", nil, sliderFrame)
        textContainer:SetSize(60, 14)
        textContainer:SetPoint("TOPRIGHT", sliderFrame, "TOPRIGHT", 0, 0)

        -- the value is drawn by its own click-to-type button (one piece)
        local clickButton = CreateFrame("Button", nil, textContainer)
        clickButton:SetAllPoints()
        clickButton:EnableMouse(true)

        local displayText = CreateProfessionalFontString(clickButton, "OVERLAY", 10, "OUTLINE")
        displayText:SetPoint("RIGHT", textContainer, "RIGHT", 0, 0)
        displayText:SetJustifyH("RIGHT")
        displayText:SetText(tostring(math.floor(value)))
        local txtNorm = GetTextNormal()
        displayText:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b, 1)

        -- the value's box (the /rc window): as wide as the value + 12, 40
        -- at least, the value in its middle
        local valueBox
        local function PaintValue(hot)
            if hot then
                displayText:SetTextColor(RC.UI:SCol("text", 1))
            else
                displayText:SetTextColor(RC.UI:SCol("text", S.DIM_A))
            end
            valueBox.bg:SetVertexColor(RC.UI:SCol("input", S.SL_INPUT_A))
            RC.UI:UpdateBorderColor(valueBox.border, RC:GetColor("settings", "text"), hot and S.BTN_BRD_A or S.SL_INPUT_BRD_A)
        end
        if set then
            valueBox = CreateFrame("Frame", nil, textContainer)
            valueBox:SetPoint("TOPRIGHT", textContainer, "TOPRIGHT", 0, 0)
            valueBox:SetPoint("BOTTOMRIGHT", textContainer, "BOTTOMRIGHT", 0, 0)
            valueBox:SetWidth(S.VALUE_W)
            valueBox:SetFrameLevel(clickButton:GetFrameLevel() - 1 > 0 and clickButton:GetFrameLevel() - 1 or 1)
            valueBox.bg = valueBox:CreateTexture(nil, "BACKGROUND")
            valueBox.bg:SetAllPoints()
            valueBox.bg:SetTexture(FLAT)
            valueBox.border = self:CreateSimpleBorder(valueBox)
            displayText:ClearAllPoints()
            displayText:SetPoint("CENTER", valueBox, "CENTER", 0, 0)
            displayText:SetJustifyH("CENTER")
            local function Fit()
                local need = math_ceil(displayText:GetStringWidth() or 0) + 12
                local room = textContainer:GetWidth() or S.VALUE_W
                valueBox:SetWidth(math_max(math_min(S.VALUE_W, room), math_min(need, room)))
            end
            hooksecurefunc(displayText, "SetText", Fit)
            Fit()
            PaintValue(false)
        end

        -- The value is a click-to-type affordance; gold on hover says so.
        clickButton:SetScript("OnEnter", function(self)
            if set then PaintValue(true) return end
            local gold = GetAccentGold()
            displayText:SetTextColor(gold.r, gold.g, gold.b, 1)
        end)

        clickButton:SetScript("OnLeave", function(self)
            if set then PaintValue(false) return end
            local rest = GetTextNormal()
            displayText:SetTextColor(rest.r, rest.g, rest.b, 1)
        end)

        local editBoxFrame = CreateFrame("Frame", nil, sliderFrame)
        editBoxFrame:SetSize(60, 18)
        editBoxFrame:SetPoint("TOPRIGHT", sliderFrame, "TOPRIGHT", 0, 2)
        editBoxFrame:Hide()

        local editBg = editBoxFrame:CreateTexture(nil, "BACKGROUND")
        editBg:SetAllPoints()
        editBg:SetTexture(FLAT)
        editBg:SetVertexColor(elemBg.r, elemBg.g, elemBg.b, 1)
        if set then editBg:SetVertexColor(RC.UI:SCol("input", S.SL_INPUT_A + 0.4)) end

        -- Gold ring while typing, the flat box's only focus affordance.
        local editBorder = self:CreateSimpleBorder(editBoxFrame)

        local editBox = CreateFrame("EditBox", nil, editBoxFrame)
        editBox:SetSize(54, 16)
        editBox:SetPoint("CENTER")
        editBox:SetAutoFocus(false)
        editBox:SetMaxLetters(6)
        editBox:SetNumeric(true)

        if RC.ApplyCustomFont then
            RC:ApplyCustomFont(editBox, 10, "OUTLINE")
        end

        editBox:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b, 1)
        editBox:SetJustifyH("CENTER")

        local function ShowEditBox()
            textContainer:Hide()
            editBoxFrame:Show()
            editBox:SetText(displayText:GetText())
            editBox:SetFocus()
            editBox:HighlightText()
            RC.UI:UpdateBorderColor(editBorder, set and RC.UI:SAccent() or GetAccentGold(), 1)
        end

        local function HideEditBox()
            editBox:ClearFocus()
            editBoxFrame:Hide()
            textContainer:Show()
            RC.UI:UpdateBorderColor(editBorder, GetBorderNormal(), 1)
        end

        clickButton:SetScript("OnClick", function(self)
            ShowEditBox()
        end)

        editBox:SetScript("OnEditFocusLost", function(self)
            HideEditBox()
        end)

        editBox:SetScript("OnEnterPressed", function(self)
            local inputValue = tonumber(self:GetText())
            if inputValue then
                inputValue = math.max(min, math.min(max, inputValue))
                inputValue = math.floor((inputValue / step) + 0.5) * step
                inputValue = math.floor(inputValue)

                slider:SetValue(inputValue)
                displayText:SetText(tostring(inputValue))
                -- a code SetValue reports userInput = false; this was typed
                NotifySettingChanged("slider")
            else
                displayText:SetText(tostring(math.floor(slider:GetValue())))
            end
            HideEditBox()
        end)

        editBox:SetScript("OnEscapePressed", function(self)
            HideEditBox()
        end)

        -- the wheel: Shift + wheel steps the value; a plain wheel goes on
        -- to the scroll area underneath (the page keeps scrolling)
        if slider.EnableMouseWheel then slider:EnableMouseWheel(true) end
        slider:SetScript("OnMouseWheel", function(self, delta)
            -- (a greyed slider - its switch is off - never steps)
            if IsShiftKeyDown and IsShiftKeyDown() and not sliderFrame._rcDisabled then
                local lo, hi = self:GetMinMaxValues()
                local st = self:GetValueStep() or step or 1
                if not st or st <= 0 then st = 1 end
                local nv = math_max(lo, math_min(hi, (self:GetValue() or lo) + delta * st))
                -- whole steps only (no 0.30000000004)
                nv = lo + math_floor((nv - lo) / st + 0.5) * st
                if nv ~= self:GetValue() then
                    self:SetValue(nv)
                    local fn = self:GetScript("OnValueChanged")
                    -- SetValue from code reports no user input; a wheel step is one
                    if fn then fn(self, nv, true) end
                end
                return
            end
            local p = self:GetParent()
            for _ = 1, 30 do
                if not p then break end
                local h = p.GetScript and p:GetScript("OnMouseWheel")
                if h and p ~= sliderFrame then h(p, delta) return end
                p = p.GetParent and p:GetParent()
            end
        end)

        local lastUpdateTime = 0
        local updateThrottle = 0.05
        local pendingUpdate = false
        local pendingValue = nil

        local function DoSliderUpdate(val)
            UpdateFill()
            val = math.floor(val)
            displayText:SetText(tostring(val))

            if editBoxFrame:IsShown() then
                editBox:SetText(tostring(val))
            end
        end

        slider:SetScript("OnValueChanged", function(self, val)
            local currentTime = GetTime()

            if not self:IsMouseOver() or not IsMouseButtonDown("LeftButton") then
                DoSliderUpdate(val)
                lastUpdateTime = currentTime
                pendingUpdate = false
                return
            end

            if currentTime - lastUpdateTime >= updateThrottle then
                DoSliderUpdate(val)
                lastUpdateTime = currentTime
                pendingUpdate = false
            else
                pendingUpdate = true
                pendingValue = val
            end
        end)

        -- Whatever OnValueChanged a caller installs is followed by the
        -- change signal; moves made by code (userInput false) stay quiet.
        WrapNotify(slider, "OnValueChanged", "slider", function(_, _, userInput) return userInput ~= false end)

        slider:SetScript("OnMouseUp", function(self)
            if pendingUpdate and pendingValue then
                DoSliderUpdate(pendingValue)
                pendingUpdate = false
                pendingValue = nil
            end
        end)

        PaintThumb()
        UpdateFill()
        slider.Text = displayText
        slider.displayText = displayText
        slider.fill = fill
        slider.editBox = editBox
        slider.parentFrame = sliderFrame
        sliderFrame.slider = slider

        -- Optional built-in label, top-left above the track opposite the
        -- value (10px text.gray). Built lazily so sliders whose caller
        -- already draws a label above them do not get a second one.
        function slider:SetLabel(labelText)
            if not self.label then
                self.label = CreateProfessionalFontString(sliderFrame, "OVERLAY", 10, "OUTLINE")
                self.label:SetPoint("TOPLEFT", sliderFrame, "TOPLEFT", 0, 0)
                self.label:SetPoint("RIGHT", textContainer, "LEFT", -4, 0)
                self.label:SetJustifyH("LEFT")
                self.label:SetWordWrap(false)
                local gray = GetTextGray()
                self.label:SetTextColor(gray.r, gray.g, gray.b, 1)
                if set then self.label:SetTextColor(RC.UI:SCol("text", 1)) end
            end
            self.label:SetText(labelText or "")
        end

        -- Repaints track/thumb/text from the theme (RefreshUIColors).
        function slider:Repaint()
            if set then
                PaintThumb()
                PaintValue(false)
                if self.label then self.label:SetTextColor(RC.UI:SCol("text", 1)) end
                return
            end
            local eb = GetElementBG()
            trackBg:SetVertexColor(eb.r, eb.g, eb.b, 1)
            editBg:SetVertexColor(eb.r, eb.g, eb.b, 1)
            RC.UI:UpdateBorderColor(sliderFrame.trackBorder, GetBorderNormal(), 1)
            PaintThumb()
            local tn = GetTextNormal()
            displayText:SetTextColor(tn.r, tn.g, tn.b, 1)
            if self.label then
                local gray = GetTextGray()
                self.label:SetTextColor(gray.r, gray.g, gray.b, 1)
            end
        end

        local originalSetPoint = slider.SetPoint
        slider.SetPoint = function(self, ...)
            sliderFrame:SetPoint(...)
        end

        -- Sizing is redirected to the outer frame too. The inner Slider
        -- is anchored to both ends of the track, so a SetWidth on it was
        -- silently ignored and every caller that asked for a narrower or
        -- wider slider got the default. Everything hangs off sliderFrame
        -- by anchors - the track spans it edge to edge, the Slider spans
        -- the track (so the thumb range follows), the value and its edit
        -- box ride the top-right corner and the label fills the rest - so
        -- resizing the frame re-lays the whole control in one go.
        slider.SetWidth = function(self, w)
            sliderFrame:SetWidth(w)
        end
        slider.SetHeight = function(self, h)
            sliderFrame:SetHeight(h)
        end
        slider.SetSize = function(self, w, h)
            sliderFrame:SetSize(w, h)
        end
        -- Narrow sliders would otherwise let the value label run under
        -- the built-in label; clamp the value box to the room available.
        sliderFrame:SetScript("OnSizeChanged", function(self, w)
            if not w or w <= 0 then return end
            UpdateFill()
            local valueW = math_min(60, math_max(28, math_floor(w * 0.4)))
            textContainer:SetWidth(valueW)
            editBoxFrame:SetWidth(valueW)
            editBox:SetWidth(math_max(20, valueW - 6))
        end)

        slider.realShow = slider.Show
        slider.Show = function(self)
            sliderFrame:Show()
            self:realShow()
        end

        slider.realHide = slider.Hide
        slider.Hide = function(self)
            sliderFrame:Hide()
            self:realHide()
        end

        return slider
    end

    -- CreateSlider pre-anchored to a settings card at (x, y), with an
    -- optional label and OnValueChanged callback.
    function RC.UI:CreateSettingSlider(card, min, max, value, step, x, y, text, onChange)
        local s = self:CreateSlider(card, min, max, value, step)
        s:SetPoint("TOPLEFT", card, "TOPLEFT", x, y)
        if text ~= nil then s.Text:SetText(text) end
        if onChange then s:SetScript("OnValueChanged", onChange) end
        return s
    end

    -- Closes whichever CreateScrollableDropdown menu is currently open,
    -- plus any native Blizzard dropdown menus (CloseDropDownMenus).
    function RC.UI:CloseAllDropdowns()
        local dd = self._openDropdown
        if dd and dd.menu then dd.menu:Hide() end
        self._openDropdown = nil
        if CloseDropDownMenus then CloseDropDownMenus() end
    end

    -- Walks up from startFrame to its topmost ancestor and hooks that
    -- ancestor's OnHide to close all dropdowns, so a scrollable dropdown
    -- menu does not stay open floating in UIParent after its owning
    -- window closes. Runs once per top-level frame (_wrDropdownAutoClose).
    function RC.UI:_HookDropdownAutoClose(startFrame)
        local top, f = nil, startFrame
        while f and f ~= UIParent do
            top = f
            f = f:GetParent()
        end
        if top and not top._wrDropdownAutoClose then
            top._wrDropdownAutoClose = true
            top:HookScript("OnHide", function()
                if RC.UI and RC.UI.CloseAllDropdowns then RC.UI:CloseAllDropdowns() end
            end)
        end
    end

    -- Custom dropdown with its own scrollable/searchable menu (does not
    -- use UIDropDownMenuTemplate). Returns container; container.menu is
    -- the popup frame, container:SetItems(items, onClick, options) fills
    -- it (items: {key/value, label/text, icon, subText, itemLink}),
    -- container:SetSelectedValue/GetSelectedValue manage selection, and
    -- container:SetSearchEnabled(bool) toggles the filter box (auto-on
    -- once there are >= 2 items). onClick(value, displayText) fires on
    -- pick. Caller anchors/sizes the container as usual.
    function RC.UI:CreateScrollableDropdown(parent, width, defaultText, maxVisible)
        width = width or BASE.DROPDOWN_WIDTH
        maxVisible = maxVisible or 5
        local itemHeight = 20
        local scrollBarWidth = 12

        -- Closed box: 24px flat dropdown.background fill, 1px black ring,
        -- text at x 8, small gold arrow at the right. Hover swaps the
        -- fill to buttons.hoverBackground and the ring to gold. The menu
        -- is a flat dropdown.background box with a 1px black ring, 20px
        -- rows, dropdown.itemHover under the cursor and the selected row's
        -- text in dropdown.selected gold.
        local btnNorm = GetDropdownBG()
        local btnHover = GetButtonHoverBG()
        local dropBg = GetDropdownBG()
        local dropItemHover = GetDropdownItemHover()
        local dropArrow = GetDropdownArrow()
        local txtNorm = GetDropdownItemText()
        local checkColor = GetCheckboxCheckmark()
        local scrollThumbColor = GetScrollThumb()
        local scrollTrackColor = GetScrollTrack()

        -- (no global name: a page builds its dropdowns again on every
        -- rebuild, and each name would stay in _G for the session)
        local container = CreateFrame("Frame", nil, parent)
        container:SetSize(width, BASE.DROPDOWN_HEIGHT)

        local bg = container:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(FLAT)
        bg:SetVertexColor(btnNorm.r, btnNorm.g, btnNorm.b, btnNorm.a or 1)
        container.bg = bg

        local border = self:CreateSimpleBorder(container)
        container.border = border

        local text = CreateProfessionalFontString(container, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
        text:SetPoint("LEFT", 8, 0)
        text:SetPoint("RIGHT", -22, 0)
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        text:SetText(defaultText or RCL["Select..."])
        text:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b, 1)
        container.text = text

        local selIcon = container:CreateTexture(nil, "ARTWORK")
        selIcon:SetSize(14, 14)
        selIcon:SetPoint("LEFT", container, "LEFT", 6, 0)
        selIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        selIcon:Hide()
        container.selIcon = selIcon

        function container:SetSelectedIcon(iconPath)
            if iconPath then
                self.selIcon:SetTexture(iconPath)
                self.selIcon:Show()
                self.text:ClearAllPoints()
                self.text:SetPoint("LEFT",  self, "LEFT",  24, 0)
                self.text:SetPoint("RIGHT", self, "RIGHT", -22, 0)
            else
                self.selIcon:Hide()
                self.text:ClearAllPoints()
                self.text:SetPoint("LEFT",  self, "LEFT",   8, 0)
                self.text:SetPoint("RIGHT", self, "RIGHT", -22, 0)
            end
        end

        local arrow = container:CreateTexture(nil, "ARTWORK")
        arrow:SetSize(9, 9)
        arrow:SetPoint("RIGHT", -7, 0)
        arrow:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrow")
        arrow:SetVertexColor(dropArrow.r, dropArrow.g, dropArrow.b, 1)
        container.arrow = arrow

        container.btnNorm = btnNorm
        container.btnHover = btnHover

        -- In the /rc window (5.0): the /zui dropdown's colours in this one's
        -- place - a warm dark box at 0.90 (0.98 under the mouse), a white
        -- 0.20 edge (0.30), the choice in white 0.50 (0.60), the arrow with
        -- it; the open list the same box at 0.98, a row under the mouse
        -- white 0.08 with a full-white label, the picked row white 0.04.
        local set = RC.UI:InSettings(parent)
        container._rcSet = set or nil
        local function PaintClosed(hot)
            bg:SetVertexColor(RC.UI:SCol("dropdownBackground", hot and S.DD_BG_HA or S.DD_BG_A))
            RC.UI:UpdateBorderColor(container.border, RC:GetColor("settings", "text"), hot and S.DD_BRD_HA or S.DD_BRD_A)
            text:SetTextColor(RC.UI:SCol("text", hot and S.DD_TXT_HA or S.DD_TXT_A))
            arrow:SetVertexColor(RC.UI:SCol("text", hot and S.DD_TXT_HA or S.DD_TXT_A))
        end
        container._rcPaintClosed = PaintClosed
        if set then PaintClosed(false) end

        container:EnableMouse(true)
        container:SetScript("OnEnter", function(self)
            if set then PaintClosed(true) return end
            local hb = GetButtonHoverBG()
            bg:SetVertexColor(hb.r, hb.g, hb.b, hb.a or 1)
            RC.UI:UpdateBorderColor(self.border, GetAccentGold(), 1)
        end)

        container:SetScript("OnLeave", function(self)
            if set then PaintClosed(false) return end
            local nb = GetDropdownBG()
            bg:SetVertexColor(nb.r, nb.g, nb.b, nb.a or 1)
            RC.UI:UpdateBorderColor(self.border, GetBorderNormal(), 1)
        end)
        -- a long choice is cut short in the box and shows whole on hover
        self:TruncTip(text, container)

        local menuHeight = (maxVisible * itemHeight) + 4
        local menu = CreateFrame("Frame", nil, UIParent)
        menu:SetSize(width, menuHeight)
        menu:SetPoint("TOPLEFT", container, "BOTTOMLEFT", 0, -2)
        local STRATA_RANK = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4,
                              DIALOG = 5, FULLSCREEN = 6,
                              FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
        local ownerStrata = container:GetFrameStrata()
        if (STRATA_RANK[ownerStrata] or 0) > STRATA_RANK.FULLSCREEN_DIALOG then
            menu:SetFrameStrata(ownerStrata)
            menu:SetFrameLevel((container:GetFrameLevel() or 0) + 20)
        else
            menu:SetFrameStrata("FULLSCREEN_DIALOG")
            menu:SetFrameLevel(100)
        end
        menu:Hide()

        local menuBg = menu:CreateTexture(nil, "BACKGROUND")
        menuBg:SetAllPoints()
        menuBg:SetTexture(FLAT)
        menuBg:SetVertexColor(dropBg.r, dropBg.g, dropBg.b, dropBg.a or 1)
        menu.bg = menuBg

        menu.border = self:CreateSimpleBorder(menu)
        if set then
            menuBg:SetVertexColor(RC.UI:SCol("dropdownBackground", S.DD_BG_HA))
            RC.UI:UpdateBorderColor(menu.border, RC:GetColor("settings", "text"), S.DD_BRD_A)
        end

        local scrollFrame = CreateFrame("ScrollFrame", nil, menu)
        scrollFrame:SetPoint("TOPLEFT", 2, -2)
        scrollFrame:SetPoint("BOTTOMRIGHT", -(scrollBarWidth + 2), 2)

        local scrollChild = CreateFrame("Frame", nil, scrollFrame)
        scrollChild:SetWidth(width - scrollBarWidth - 6)
        scrollFrame:SetScrollChild(scrollChild)

        local scrollBar = CreateFrame("Slider", nil, menu)
        scrollBar:SetWidth(scrollBarWidth - 2)
        scrollBar:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -2, -2)
        scrollBar:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", -2, 2)
        scrollBar:SetOrientation("VERTICAL")
        scrollBar:SetMinMaxValues(0, 1)
        scrollBar:SetValue(0)

        -- Flat rail: track fill with a 1px ring, flat block thumb with
        -- its own ring so it keeps an edge while dragging.
        local track = scrollBar:CreateTexture(nil, "BACKGROUND")
        track:SetAllPoints()
        track:SetTexture(FLAT)
        track:SetVertexColor(scrollTrackColor.r, scrollTrackColor.g, scrollTrackColor.b, scrollTrackColor.a or 1)
        scrollBar.bg = track
        scrollBar.border = self:CreateSimpleBorder(scrollBar)

        local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
        thumb:SetTexture(FLAT)
        thumb:SetVertexColor(scrollThumbColor.r, scrollThumbColor.g, scrollThumbColor.b, 1)
        thumb:SetWidth(scrollBarWidth - 2)
        thumb:SetHeight(30)
        scrollBar:SetThumbTexture(thumb)
        RC.UI:AddThumbBorder(scrollBar)

        scrollBar:SetScript("OnValueChanged", function(self, value)
            scrollFrame:SetVerticalScroll(value)
        end)
        scrollBar.bg, scrollBar.thumb = track, thumb
        RC.UI:StyleScrollBar(scrollBar, { inset = 4 })

        local SEARCH_H = 22
        container._searchEnabled = false
        container._searchAutoFocus = false
        container._searchAllowed = true
        container._filter = ""

        -- The filter is a flat edit box in its own frame (SetBackdrop on
        -- an EditBox flickers the cursor in Classic): ui.elementBackground
        -- fill, 1px ring that turns gold on focus, gray placeholder.
        local searchFrame = CreateFrame("Frame", nil, menu)
        searchFrame:SetHeight(SEARCH_H - 2)
        searchFrame:SetPoint("TOPLEFT",  menu, "TOPLEFT",   2, -2)
        searchFrame:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -2, -2)
        local searchBg = searchFrame:CreateTexture(nil, "BACKGROUND")
        searchBg:SetAllPoints()
        searchBg:SetTexture(FLAT)
        local searchElem = GetElementBG()
        searchBg:SetVertexColor(searchElem.r, searchElem.g, searchElem.b, 1)
        searchFrame.bg = searchBg
        searchFrame.border = self:CreateSimpleBorder(searchFrame)
        searchFrame:Hide()
        container.searchFrame = searchFrame

        local searchBox = CreateFrame("EditBox", nil, searchFrame)
        searchBox:SetAutoFocus(false)
        searchBox:SetFontObject("ChatFontNormal")
        if RC.ApplyCustomFont then RC:ApplyCustomFont(searchBox, BASE.FONT_SIZE_SMALL, "") end
        searchBox:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b, 1)
        searchBox:SetPoint("TOPLEFT",  searchFrame, "TOPLEFT",   4, -1)
        searchBox:SetPoint("BOTTOMRIGHT", searchFrame, "BOTTOMRIGHT", -4, 1)
        searchBox:SetTextInsets(2, 2, 0, 0)
        container.searchBox = searchBox

        local searchHint = CreateProfessionalFontString(searchBox, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
        searchHint:SetPoint("LEFT", searchBox, "LEFT", 3, 0)
        searchHint:SetText(RCL["Type to filter..."])
        local hintCol = GetTextGray()
        searchHint:SetTextColor(hintCol.r, hintCol.g, hintCol.b, 0.7)
        local function UpdateSearchHint()
            if (searchBox:GetText() or "") == "" then searchHint:Show() else searchHint:Hide() end
        end

        searchBox:SetScript("OnEditFocusGained", function()
            RC.UI:UpdateBorderColor(searchFrame.border, GetAccentGold(), 1)
        end)
        searchBox:SetScript("OnEditFocusLost", function()
            RC.UI:UpdateBorderColor(searchFrame.border, GetBorderNormal(), 1)
        end)

        searchBox:SetScript("OnTextChanged", function(self)
            container._filter = self:GetText() or ""
            UpdateSearchHint()
            if container._RelayoutVisible then container:_RelayoutVisible() end
        end)
        searchBox:SetScript("OnEscapePressed", function(self)
            self:SetText("")
            self:ClearFocus()
            menu:Hide()
            container.isOpen = false
        end)
        searchBox:SetScript("OnEnterPressed", function(self)
            for _, item in ipairs(container.items) do
                if item:IsShown() then
                    local oc = item:GetScript("OnClick")
                    if oc then oc(item) end
                    return
                end
            end
            self:ClearFocus()
        end)

        function container:_SetSearchLayout(enabled)
            container._searchEnabled = enabled
            local topY = enabled and -(SEARCH_H + 2) or -2
            scrollFrame:ClearAllPoints()
            scrollFrame:SetPoint("TOPLEFT", menu, "TOPLEFT", 2, topY)
            scrollFrame:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", -(scrollBarWidth + 2), 2)
            scrollBar:ClearAllPoints()
            scrollBar:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -2, topY)
            scrollBar:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", -2, 2)
            searchBox:SetText("")
            if enabled then
                searchFrame:Show()
            else
                searchFrame:Hide()
            end
            UpdateSearchHint()
        end

        -- Empty state. A menu with nothing in it used to open as a 20px
        -- sliver of background, which reads as a broken dropdown rather
        -- than "there is nothing to pick yet". Two centred lines inside
        -- the menu say which of the two it is: nothing configured at all,
        -- or a search that matched none of the rows.
        local function EnsureEmptyBlock()
            if menu._emptyBlock then return menu._emptyBlock end
            local block = CreateFrame("Frame", nil, menu)
            -- Anchored to the scroll frame, not the menu: when the search
            -- box is up, a menu-anchored block would sit underneath it.
            block:SetPoint("TOPLEFT",     scrollFrame, "TOPLEFT",     0,  0)
            block:SetPoint("BOTTOMRIGHT", menu,        "BOTTOMRIGHT", -2, 2)
            block:Hide()

            block.title = CreateProfessionalFontString(block, "OVERLAY", 11, "OUTLINE")
            block.title:SetPoint("TOP", block, "TOP", 0, -12)
            block.title:SetJustifyH("CENTER")

            block.hint = CreateProfessionalFontString(block, "OVERLAY", 9, "OUTLINE")
            block.hint:SetPoint("TOP", block.title, "BOTTOM", 0, -4)
            block.hint:SetPoint("LEFT",  block, "LEFT",   8, 0)
            block.hint:SetPoint("RIGHT", block, "RIGHT", -8, 0)
            block.hint:SetJustifyH("CENTER")
            block.hint:SetWordWrap(true)

            menu._emptyBlock = block
            return block
        end

        -- Callers override the wording for their own list, e.g.
        -- dd:SetEmptyText("No trinket configs yet", "Add one in Gear > Trinket queues").
        function container:SetEmptyText(title, hint)
            container._emptyTitle = title
            container._emptyHint  = hint
        end

        local function ShowEmptyBlock(filtered)
            local block = EnsureEmptyBlock()
            local title, hint
            if filtered then
                title = RCL["No matches"]
                hint  = RCL["Try a different search."]
            else
                title = container._emptyTitle or RCL["Nothing here yet"]
                hint  = container._emptyHint
            end
            block.title:SetText(title)
            local tc = RC.GetColor and RC:GetColor("text", "gray") or { r = 0.6, g = 0.6, b = 0.6 }
            block.title:SetTextColor(tc.r, tc.g, tc.b, 1)
            if hint and hint ~= "" then
                block.hint:SetText(hint)
                local hc = RC.GetColor and RC:GetColor("text", "disabled") or { r = 0.5, g = 0.5, b = 0.5 }
                block.hint:SetTextColor(hc.r, hc.g, hc.b, 1)
                block.hint:Show()
            else
                block.hint:SetText("")
                block.hint:Hide()
            end
            block:Show()
            return (hint and hint ~= "") and 52 or 36
        end

        function container:_RelayoutVisible()
            local q = (container._filter or ""):lower()
            local visibleCount = 0
            local y = 0
            for _, item in ipairs(container.items) do
                local show = (q == "")
                if not show then
                    show = tostring(item.displayText or ""):lower():find(q, 1, true) ~= nil
                end
                if show then
                    item:ClearAllPoints()
                    item:SetPoint("TOPLEFT", 0, -y)
                    item:Show()
                    y = y + itemHeight
                    visibleCount = visibleCount + 1
                else
                    item:Hide()
                end
            end

            local totalHeight = y
            scrollChild:SetHeight(math.max(totalHeight, 1))

            local extra = container._searchEnabled and SEARCH_H or 0
            local contentH
            if visibleCount == 0 then
                -- No rows: the menu is the empty block, and the scroll
                -- machinery below has nothing to measure.
                contentH = ShowEmptyBlock(q ~= "")
                scrollBar:Hide()
                menu:SetHeight(contentH + 4 + extra)
                scrollFrame:SetVerticalScroll(0)
                return
            end
            if menu._emptyBlock then menu._emptyBlock:Hide() end
            local visibleRows = math.min(visibleCount, maxVisible)
            contentH = visibleRows * itemHeight
            menu:SetHeight(contentH + 4 + extra)

            local visibleHeight = contentH
            local maxScroll = math.max(0, totalHeight - visibleHeight)
            if maxScroll > 0 then
                scrollBar:Show()
                scrollBar:SetMinMaxValues(0, maxScroll)
                scrollBar:SetValue(0)
                local thumbHeight = math.max(20, (visibleHeight / totalHeight) * visibleHeight)
                thumb:SetHeight(thumbHeight)
            else
                scrollBar:Hide()
            end
            scrollFrame:SetVerticalScroll(0)
        end

        local function HookParentHide(frame)
            if frame and not frame.wrDropdownHooked then
                frame:HookScript("OnHide", function()
                    menu:Hide()
                end)
                frame.wrDropdownHooked = true
            end
        end

        HookParentHide(parent)
        if parent:GetParent() then
            HookParentHide(parent:GetParent())
        end

        local function OnMouseWheel(self, delta)
            local current = scrollBar:GetValue()
            local min, max = scrollBar:GetMinMaxValues()
            local step = itemHeight * 2
            if delta > 0 then
                scrollBar:SetValue(math.max(min, current - step))
            else
                scrollBar:SetValue(math.min(max, current + step))
            end
        end

        menu:EnableMouseWheel(true)
        menu:SetScript("OnMouseWheel", OnMouseWheel)
        scrollFrame:EnableMouseWheel(true)
        scrollFrame:SetScript("OnMouseWheel", OnMouseWheel)

        container.menu = menu
        menu._rcOwner = container   -- (RC.UI:DiscardTree takes it along)
        container.scrollFrame = scrollFrame
        container.scrollChild = scrollChild
        container.scrollBar = scrollBar
        container.thumb = thumb
        container.items = {}
        container.selectedValue = nil
        container.isOpen = false
        container.onClick = nil
        container.dropItemHover = dropItemHover
        container.selGold = (RC.GetColor and RC:GetColor("dropdown", "selected"))
            or {r = 0.85, g = 0.65, b = 0.25, a = 1}
        container.checkColor = container.selGold
        container.txtNorm = txtNorm

        -- Selection is carried by the label colour (dropdown.selected
        -- gold) plus a small tick at the right - no ring around the row,
        -- a box inside a box reads as a second control.
        local function _SetRowSelected(item, selected)
            if not item then return end
            item.isSelectedRow = selected and true or false
            if set then
                if item.check then item.check:SetText("") end
                if item.bg then item.bg:SetVertexColor(RC.UI:SCol("text", selected and S.DD_SEL_A or 0)) end
                if item.label then item.label:SetTextColor(RC.UI:SCol("text", selected and 1 or S.DIM_A)) end
                return
            end
            if item.check then item.check:SetText(selected and "*" or "") end
            if item.label then
                local c = selected and GetDropdownSelected() or GetDropdownItemText()
                item.label:SetTextColor(c.r, c.g, c.b, 1)
            end
        end
        container._SetRowSelected = _SetRowSelected

        container:SetScript("OnMouseDown", function()
            if container.isOpen then
                menu:Hide()
                container.isOpen = false
            else
                if RC.UI._openDropdown and RC.UI._openDropdown ~= container then
                    local other = RC.UI._openDropdown
                    if other.menu then other.menu:Hide() end
                    other.isOpen = false
                end
                menu:Show()
                container.isOpen = true
                RC.UI._openDropdown = container
                if RC.UI._ddWatch then RC.UI._ddWatch:Cancel() end
                -- The popup menu is a UIParent-level frame anchored by
                -- absolute position at open time, so it does not follow
                -- container if the owning window moves/hides afterward.
                -- This ticker polls for that and force-closes the menu;
                -- wrapped in RC.Profiler:TrackTicker per the no-bare-
                -- ticker rule, with a plain fallback if Profiler is absent.
                local ax, ay = container:GetLeft(), container:GetTop()
                local watchFn = function()
                    local open = RC.UI._openDropdown
                    if not open or not open.isOpen then
                        if RC.UI._ddWatch then RC.UI._ddWatch:Cancel(); RC.UI._ddWatch = nil end
                        return
                    end
                    local nx, ny = open:GetLeft(), open:GetTop()
                    if not open:IsVisible() or nx ~= ax or ny ~= ay then
                        if open.menu then open.menu:Hide() end
                        open.isOpen = false
                        RC.UI._openDropdown = nil
                        if RC.UI._ddWatch then RC.UI._ddWatch:Cancel(); RC.UI._ddWatch = nil end
                    end
                end
                if RC.Profiler and RC.Profiler.TrackTicker then
                    RC.UI._ddWatch = RC.Profiler:TrackTicker("uiDropdownWatch", 0.15, watchFn)
                else
                    RC.UI._ddWatch = C_Timer.NewTicker(0.15, watchFn)
                end
            end
        end)

        menu:SetScript("OnShow", function()
            container.isOpen = true
            RC.UI:SetDropdownArrowOpen(container.arrow, true)
            RC.UI._openDropdown = container
            if RC.UI._HookDropdownAutoClose then RC.UI:_HookDropdownAutoClose(parent) end
            if container._searchEnabled and container.searchBox then
                container.searchBox:SetText("")
                container._filter = ""
                if container._RelayoutVisible then container:_RelayoutVisible() end
                if container._searchAutoFocus then container.searchBox:SetFocus() end
            end
        end)
        menu:SetScript("OnHide", function()
            container.isOpen = false
            RC.UI:SetDropdownArrowOpen(container.arrow, false)
            if container.searchBox then container.searchBox:ClearFocus() end
            if RC.UI._openDropdown == container then
                RC.UI._openDropdown = nil
            end
        end)
        menu:EnableMouse(true)

        function container:SetItems(items, onClick, options)
            container.onClick = onClick
            options = options or {}

            -- Rows are pooled by index in container._rowPool and reused
            -- across SetItems calls instead of being unparented and
            -- recreated - the client never GCs frames, and each recreated
            -- row also grew RC.trackedFonts via CreateProfessionalFontString.
            -- container.items only ever holds the currently active rows
            -- (search relayout and selection walk it).
            container._rowPool = container._rowPool or {}
            local pool = container._rowPool
            for i = #items + 1, #pool do
                pool[i]:Hide()
            end
            wipe(container.items)

            local totalHeight = 0
            for i, itemData in ipairs(items) do
                local itemFrame = pool[i]
                if not itemFrame then
                    itemFrame = CreateFrame("Button", nil, scrollChild)
                    pool[i] = itemFrame

                    local itemBg = itemFrame:CreateTexture(nil, "BACKGROUND")
                    itemBg:SetAllPoints()
                    itemBg:SetTexture(FLAT)
                    itemBg:SetVertexColor(1, 1, 1, 0)
                    itemFrame.bg = itemBg

                    local check = CreateProfessionalFontString(itemFrame, "OVERLAY", 10, "OUTLINE")
                    check:SetPoint("RIGHT", -4, 0)
                    itemFrame.check = check

                    itemFrame:SetScript("OnEnter", function(self)
                        local hv = GetDropdownItemHover()
                        self.bg:SetVertexColor(hv.r, hv.g, hv.b, hv.a or 1)
                        if set then
                            self.bg:SetVertexColor(RC.UI:SCol("text", S.DD_HL_A))
                            if self.label then self.label:SetTextColor(RC.UI:SCol("text", 1)) end
                        end
                        if self.itemLink then
                            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                            GameTooltip:SetHyperlink(self.itemLink)
                            GameTooltip:Show()
                        elseif self.tipText then
                            -- a choice's own tooltip, read in the open list
                            local gold = RC:GetColor("text", "gold")
                            local norm = RC:GetColor("text", "normal")
                            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                            GameTooltip:SetText(self.displayText or "", gold.r, gold.g, gold.b)
                            GameTooltip:AddLine(self.tipText, norm.r, norm.g, norm.b, true)
                            GameTooltip:Show()
                        end
                    end)
                    itemFrame:SetScript("OnLeave", function(self)
                        self.bg:SetVertexColor(1, 1, 1, 0)
                        if set then _SetRowSelected(self, self.isSelectedRow) end
                        if self.itemLink or self.tipText then GameTooltip:Hide() end
                    end)

                    itemFrame:SetScript("OnClick", function(self)
                        container.selectedValue = self.value
                        text:SetText(self.displayText)
                        if container.SetSelectedIcon then
                            container:SetSelectedIcon(self.iconPath)
                        end

                        for _, item in ipairs(container.items) do
                            _SetRowSelected(item, false)
                        end
                        _SetRowSelected(self, true)

                        menu:Hide()
                        container.isOpen = false

                        if container.onClick then
                            container.onClick(self.value, self.displayText)
                        end
                        NotifySettingChanged("dropdown")
                    end)
                end

                itemFrame:SetSize(width - scrollBarWidth - 6, itemHeight)
                itemFrame:ClearAllPoints()
                itemFrame:SetPoint("TOPLEFT", 0, -totalHeight)
                itemFrame:Show()
                itemFrame.bg:SetVertexColor(1, 1, 1, 0)

                local fontName = itemData.value or itemData.text or itemData

                local textLeftX = 6
                if itemData.icon then
                    local iconSz = itemData.iconSize or 14
                    local iconTex = itemFrame.icon
                    if not iconTex then
                        iconTex = itemFrame:CreateTexture(nil, "ARTWORK")
                        iconTex:SetPoint("LEFT", itemFrame, "LEFT", 4, 0)
                        itemFrame.icon = iconTex
                    end
                    iconTex:SetSize(iconSz, iconSz)
                    iconTex:SetTexture(itemData.icon)
                    if itemData.iconNoCrop then
                        iconTex:SetTexCoord(0, 1, 0, 1)
                    else
                        iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    end
                    if itemData.iconColor then
                        local ic = itemData.iconColor
                        iconTex:SetVertexColor(ic.r, ic.g, ic.b, ic.a or 1)
                    else
                        iconTex:SetVertexColor(1, 1, 1, 1)
                    end
                    if itemData.iconBorder and not itemFrame._iconBordered then
                        RC.UI:AddArrowBorder(iconTex)
                        itemFrame._iconBordered = true
                    end
                    iconTex:Show()
                    textLeftX = 22
                elseif itemFrame.icon then
                    itemFrame.icon:Hide()
                end

                -- fontPreview rows need a raw FontString carrying the
                -- previewed font; normal rows use the tracked professional
                -- string. Rebuild the label only when the mode flips.
                local wantPreview = (options.fontPreview and RC and RC.GetFontPath) and true or false
                local itemText = itemFrame.label
                if not itemText or itemFrame.isFontPreview ~= wantPreview then
                    if itemText then itemText:Hide() end
                    if wantPreview then
                        itemText = itemFrame:CreateFontString(nil, "OVERLAY")
                        -- (each font's name in that font: on purpose)
                        itemText._rcOwnFace = "font list: each name in its own face"
                    else
                        itemText = CreateProfessionalFontString(itemFrame, "OVERLAY", 11, "OUTLINE")
                    end
                    itemFrame.label = itemText
                    itemFrame.isFontPreview = wantPreview
                end
                if wantPreview then
                    -- a font file that does not load (a LibSharedMedia entry
                    -- whose file is missing) leaves the string with no font,
                    -- and SetText would then error: fall back to the default
                    local fontPath = RC:GetFontPath(fontName)
                    local set = itemText:SetFont(fontPath, 11, "OUTLINE")
                    if set == false or not itemText:GetFont() then
                        itemText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
                    end
                end

                itemText:Show()
                itemText:SetJustifyH("LEFT")
                itemText:SetWordWrap(false)
                itemText:SetText(itemData.label or itemData.text or itemData)
                itemText:SetTextColor(container.txtNorm.r, container.txtNorm.g, container.txtNorm.b, 1)
                if container._rcSet then itemText:SetTextColor(RC.UI:SCol("text", S.DIM_A)) end
                itemText:ClearAllPoints()
                if itemData.subText and itemData.subText ~= "" then
                    itemText:SetPoint("TOPLEFT", itemFrame, "TOPLEFT", textLeftX, -1)
                    itemText:SetPoint("RIGHT", -20, 0)
                    itemText:SetHeight(11)
                    local sub = itemFrame.subText
                    if not sub then
                        sub = CreateProfessionalFontString(itemFrame, "OVERLAY", 8, "OUTLINE")
                        sub:SetJustifyH("LEFT")
                        sub:SetWordWrap(false)
                        sub:SetHeight(9)
                        itemFrame.subText = sub
                    end
                    sub:ClearAllPoints()
                    sub:SetPoint("TOPLEFT", itemFrame, "TOPLEFT", textLeftX + 2, -11)
                    sub:SetPoint("RIGHT", -20, 0)
                    sub:SetText(itemData.subText)
                    local gg = (RC.UI and RC.UI.TEXT and RC.UI.TEXT.green)
                        or { 0.45, 1, 0.45 }
                    sub:SetTextColor(gg[1] or gg.r or 0.45,
                        gg[2] or gg.g or 1, gg[3] or gg.b or 0.45, 1)
                    sub:Show()
                else
                    if itemFrame.subText then itemFrame.subText:Hide() end
                    itemText:SetPoint("LEFT", textLeftX, 0)
                    itemText:SetPoint("RIGHT", -20, 0)
                    itemText:SetHeight(itemHeight)
                end

                itemFrame.check:SetText("")
                itemFrame.check:SetTextColor(container.checkColor.r, container.checkColor.g, container.checkColor.b, 1)
                itemFrame.isSelectedRow = false

                itemFrame.value = itemData.key or itemData.value or itemData
                itemFrame.displayText = itemData.label or itemData.text or itemData
                itemFrame.iconPath    = itemData.icon
                itemFrame.itemLink    = itemData.itemLink
                itemFrame.tipText     = itemData.tooltip
                itemFrame.dropItemHover = container.dropItemHover

                table.insert(container.items, itemFrame)
                totalHeight = totalHeight + itemHeight
            end

            local _searchOK = (container._searchAllowed ~= false)
            container:_SetSearchLayout(_searchOK and #items >= 2)
            container._searchAutoFocus = _searchOK and (#items >= 8)
            container._filter = ""
            container:_RelayoutVisible()
        end

        function container:SetSearchEnabled(enabled)
            container._searchAllowed = enabled and true or false
            if container.items and #container.items > 0 then
                local want = container._searchAllowed and (#container.items >= 2)
                container:_SetSearchLayout(want)
                container._searchAutoFocus = container._searchAllowed and (#container.items >= 8)
                container:_RelayoutVisible()
            end
        end

        function container:SetSelectedValue(value, displayText)
            container.selectedValue = value
            if displayText then
                text:SetText(displayText)
            end
            local matchedIcon = nil
            for _, item in ipairs(container.items) do
                local sel = (item.value == value)
                _SetRowSelected(item, sel)
                if sel then matchedIcon = item.iconPath end
            end
            if container.SetSelectedIcon then
                container:SetSelectedIcon(matchedIcon)
            end
        end

        function container:GetSelectedValue()
            return container.selectedValue
        end

        -- Re-size the box, its menu and the rows (a value picker sizes
        -- itself to its longest choice once the rows exist).
        function container:SetDropdownWidth(w)
            width = w
            container:SetWidth(w)
            menu:SetWidth(w)
            scrollChild:SetWidth(w - scrollBarWidth - 6)
            for _, row in ipairs(container._rowPool or {}) do
                row:SetWidth(w - scrollBarWidth - 6)
            end
        end

        return container
    end
