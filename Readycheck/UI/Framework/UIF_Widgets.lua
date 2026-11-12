local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local math_floor, math_ceil, math_max, math_min, math_abs = math.floor, math.ceil, math.max, math.min, math.abs
local table_insert = table.insert
local CreateFrame = CreateFrame
local C_Timer = C_Timer

------------------------------------------------------------------------
-- Readycheck - UI Framework Widgets
-- Owns the general-purpose widget helpers: borders, buttons, checkboxes,
-- tabs, scrollbars, the resize grip, and hover-color wiring.
-- Every visible button in the addon must go through CreateStyledButton
-- (or a helper built on it) instead of UIPanelButtonTemplate or a raw
-- CreateFrame("Button") - see the contract comments above each function.
------------------------------------------------------------------------

local RC = _G.Readycheck
if not RC then return end
RC._uif = RC._uif or {}
local _uif = RC._uif
local NotifySettingChanged, WrapNotify = _uif.NotifySettingChanged, _uif.WrapNotify
local BASE, C, FLAT, CreateProfessionalFontString, GetAccentGold, GetBorderNormal, GetBorderSelected, GetButtonConfiguredBG, GetButtonConfiguredHover, GetButtonDisabledBG, GetButtonHoverBG, GetButtonNormalBG, GetButtonPressedBG, GetButtonTextConfigured, GetButtonTextDisabled, GetButtonTextNormal, GetButtonTexture, GetCheckboxBG, GetCheckboxBorder, GetCheckboxCheckmark, GetCheckboxHoverBorder, GetCloseHover, GetScrollThumb, GetScrollTrack, GetSidebarSelected, GetSidebarTextNormal, GetSidebarTextSelected, GetTextGray, GetXHover, GetXNormal, RegisterTexture =
      _uif.BASE, _uif.C, _uif.FLAT, _uif.CreateProfessionalFontString, _uif.GetAccentGold, _uif.GetBorderNormal, _uif.GetBorderSelected, _uif.GetButtonConfiguredBG, _uif.GetButtonConfiguredHover, _uif.GetButtonDisabledBG, _uif.GetButtonHoverBG, _uif.GetButtonNormalBG, _uif.GetButtonPressedBG, _uif.GetButtonTextConfigured, _uif.GetButtonTextDisabled, _uif.GetButtonTextNormal, _uif.GetButtonTexture, _uif.GetCheckboxBG, _uif.GetCheckboxBorder, _uif.GetCheckboxCheckmark, _uif.GetCheckboxHoverBorder, _uif.GetCloseHover, _uif.GetScrollThumb, _uif.GetScrollTrack, _uif.GetSidebarSelected, _uif.GetSidebarTextNormal, _uif.GetSidebarTextSelected, _uif.GetTextGray, _uif.GetXHover, _uif.GetXNormal, _uif.RegisterTexture
local GetTextNormal = _uif.GetTextNormal
local S = _uif.S
    -- Returns a table of 4 edge textures (top/bottom/left/right) drawn
    -- OVERLAY on frame, colored from theme "borderNormal". Caller must
    -- keep the returned table if it wants to recolor via UpdateBorderColor.
    -- subLevel is optional. Frames that already own a border in OVERLAY
    -- sublevel 0 need a second ring drawn above it, and relying on
    -- creation order for that is a coin flip - pass an explicit sublevel
    -- so the stack is deterministic.
    function RC.UI:CreateSimpleBorder(frame, borderWidth, subLevel)
        local borders = {}
        borderWidth = borderWidth or BASE.BORDER_WIDTH

        -- Callers have historically passed extra colour arguments here that
        -- this function never accepted, so anything that is not a whole
        -- number is discarded rather than handed to CreateTexture.
        if type(subLevel) ~= "number" or subLevel ~= math_floor(subLevel) then
            subLevel = nil
        end

        if not frame or not frame.CreateTexture then
            return borders
        end
        -- the frame's own (first) edge, for RC.UI:SkinPopup to repaint
        if frame._rcBorder == nil then frame._rcBorder = borders end

        local borderColor = {0, 0, 0, 1}
        if RC.GetColor then
            local col = RC:GetColor("ui", "borderNormal")
            if col then
                borderColor = {col.r, col.g, col.b, col.a or 1}
            end
        end

        borders.top = frame:CreateTexture(nil, "OVERLAY", nil, subLevel)
        borders.top:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], borderColor[4])
        borders.top:SetPoint("TOPLEFT", 0, 0)
        borders.top:SetPoint("TOPRIGHT", 0, 0)
        borders.top:SetHeight(borderWidth)

        borders.bottom = frame:CreateTexture(nil, "OVERLAY", nil, subLevel)
        borders.bottom:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], borderColor[4])
        borders.bottom:SetPoint("BOTTOMLEFT", 0, 0)
        borders.bottom:SetPoint("BOTTOMRIGHT", 0, 0)
        borders.bottom:SetHeight(borderWidth)

        borders.left = frame:CreateTexture(nil, "OVERLAY", nil, subLevel)
        borders.left:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], borderColor[4])
        borders.left:SetPoint("TOPLEFT", 0, 0)
        borders.left:SetPoint("BOTTOMLEFT", 0, 0)
        borders.left:SetWidth(borderWidth)

        borders.right = frame:CreateTexture(nil, "OVERLAY", nil, subLevel)
        borders.right:SetColorTexture(borderColor[1], borderColor[2], borderColor[3], borderColor[4])
        borders.right:SetPoint("TOPRIGHT", 0, 0)
        borders.right:SetPoint("BOTTOMRIGHT", 0, 0)
        borders.right:SetWidth(borderWidth)

        return borders
    end

    -- Recolors a border table returned by CreateSimpleBorder in place.
    -- alpha (optional) overrides color.a - the card border sits at 0.55
    -- and an active button's gold ring at 0.7, both from the same table.
    function RC.UI:UpdateBorderColor(borders, color, alpha)
        if not borders or not color then return end

        local r, g, b, a = color.r or 0, color.g or 0, color.b or 0, alpha or color.a or 1

        if borders.top then
            borders.top:SetColorTexture(r, g, b, a)
        end
        if borders.bottom then
            borders.bottom:SetColorTexture(r, g, b, a)
        end
        if borders.left then
            borders.left:SetColorTexture(r, g, b, a)
        end
        if borders.right then
            borders.right:SetColorTexture(r, g, b, a)
        end
    end

    -- Builds a themed vertical Slider scrollbar anchored to anchorFrame's
    -- right edge and wires it to scrollFrame:SetVerticalScroll. Returns
    -- the slider; call slider:SyncRange(contentHeight, viewportHeight)
    -- whenever content size changes to update the thumb range and
    -- auto-hide when nothing needs scrolling. Starts hidden.
    function RC.UI:AttachScrollbar(scrollFrame, anchorFrame, opts)
        opts = opts or {}
        local width = opts.width or 16
        local trackColor = GetScrollTrack()
        local thumbColor = GetScrollThumb()

        local scrollBar = CreateFrame("Slider", nil, anchorFrame)
        scrollBar:SetWidth(width)
        scrollBar:SetPoint("TOPRIGHT",    anchorFrame, "TOPRIGHT",    -3, -6)
        scrollBar:SetPoint("BOTTOMRIGHT", anchorFrame, "BOTTOMRIGHT", -3,  6)
        scrollBar:SetOrientation("VERTICAL")
        scrollBar:SetMinMaxValues(0, 1)
        scrollBar:SetValue(0)

        -- Flat track with its own 1px edge; the thumb is a plain block
        -- ringed by AddThumbBorder so it keeps an outline while dragging.
        local track = scrollBar:CreateTexture(nil, "BACKGROUND")
        track:SetAllPoints()
        track:SetTexture(FLAT)
        track:SetVertexColor(trackColor.r, trackColor.g, trackColor.b, trackColor.a or 1)
        scrollBar.bg = track
        scrollBar.border = self:CreateSimpleBorder(scrollBar)

        local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
        thumb:SetTexture(FLAT)
        thumb:SetVertexColor(thumbColor.r, thumbColor.g, thumbColor.b, 1)
        thumb:SetWidth(width)
        thumb:SetHeight(24)
        scrollBar:SetThumbTexture(thumb)
        scrollBar.thumb = thumb
        RC.UI:AddThumbBorder(scrollBar)

        scrollBar:SetScript("OnValueChanged", function(s, value)
            scrollFrame:SetVerticalScroll(value)
        end)
        scrollBar:Hide()

        scrollFrame:EnableMouseWheel(true)
        scrollFrame:SetScript("OnMouseWheel", function(_, delta)
            local cur = scrollBar:GetValue()
            local mn, mx = scrollBar:GetMinMaxValues()
            scrollBar:SetValue(math.min(mx, math.max(mn, cur - delta * 20)))
        end)

        function scrollBar:SyncRange(contentH, viewportH)
            local range = math.max(0, (contentH or 0) - (viewportH or 0))
            self:SetMinMaxValues(0, range)
            if self.SizeThumb then self:SizeThumb(contentH, viewportH) end
            if range > 0 then self:Show() else self:Hide() end
        end
        self:StyleScrollBar(scrollBar)

        return scrollBar
    end

    -- THE SCROLL BAR LOOK, the same in every scroll area (the page, the
    -- sidebar, dropdown lists, text boxes, windows): a faint rail, a slim
    -- thumb that sits quiet until the mouse is over the bar, the area
    -- scrolls, or it is dragged - then it lights gold, and settles back a
    -- moment after. bar:SizeThumb(contentH, viewH) makes the thumb as long
    -- as the share of the content in view (24 px at least). No OnUpdate:
    -- the settle is one C_Timer per burst.
    local THUMB_MIN = 24
    function RC.UI:StyleScrollBar(bar, opts)
        if not bar or bar._rcScrollStyled then return bar end
        bar._rcScrollStyled = true
        opts = opts or {}
        -- (a bar inside a page of the /rc window wears the window's bar)
        if opts.settings == nil and bar.GetParent and RC.UI:InSettings(bar:GetParent()) then
            opts = { settings = true, inset = opts.inset }
        end
        local thumb = bar.thumb or (bar.GetThumbTexture and bar:GetThumbTexture())
        if not thumb then return bar end
        bar.thumb = thumb
        -- THE /rc WINDOW'S BAR (opts.settings): a thin rail (white 0.02)
        -- and thumb (white 0.27, 30 at least) in the middle of a wider hit
        -- area; brighter while the mouse is on it or it is dragged
        if opts.settings then
            local w = opts.width or S.SCROLL_W
            local trackA, thumbA = opts.track or S.SCROLL_TRACK_A, opts.thumb or S.SCROLL_THUMB_A
            thumb:SetWidth(w)
            if bar.bg then
                bar.bg:ClearAllPoints()
                bar.bg:SetPoint("TOP", bar, "TOP", 0, 0)
                bar.bg:SetPoint("BOTTOM", bar, "BOTTOM", 0, 0)
                bar.bg:SetWidth(w)
            end
            if bar.border then RC.UI:UpdateBorderColor(bar.border, GetBorderNormal(), 0) end
            local hot, drag = false, false
            local function SPaint()
                if bar.bg then bar.bg:SetVertexColor(RC.UI:SCol("text", trackA)) end
                thumb:SetVertexColor(RC.UI:SCol("text", (hot or drag) and math_min(1, thumbA + 0.2) or thumbA))
            end
            bar._rcPaintThumb = SPaint
            if bar.HookScript then
                bar:HookScript("OnEnter", function() hot = true SPaint() end)
                bar:HookScript("OnLeave", function() hot = false SPaint() end)
                bar:HookScript("OnMouseDown", function() drag = true SPaint() end)
                bar:HookScript("OnMouseUp", function() drag = false SPaint() end)
            end
            function bar:SizeThumb(contentH, viewH)
                local bh = self:GetHeight() or 0
                if not (contentH and viewH and contentH > 0 and bh > 0) then return end
                local h = math_max(30, math_min(bh, bh * viewH / contentH))
                thumb:SetHeight(math_floor(h + 0.5))
            end
            local oldRepaint = bar.Repaint
            function bar:Repaint()
                if oldRepaint then oldRepaint(self) end
                SPaint()
            end
            SPaint()
            return bar
        end
        local w = bar:GetWidth() or 16
        local slim = math_max(4, math_floor(w - (opts.inset or 6)))
        thumb:SetWidth(slim)
        -- the rail: faint, no ring
        if bar.bg then
            local tc = GetScrollTrack()
            bar.bg:SetVertexColor(tc.r, tc.g, tc.b, (tc.a or 1) * 0.45)
        end
        if bar.border then RC.UI:UpdateBorderColor(bar.border, GetBorderNormal(), 0) end
        local hot, drag, busy = false, false, false
        local token = 0
        local function Paint()
            local live = hot or drag or busy
            local c = live and GetAccentGold() or GetScrollThumb()
            thumb:SetVertexColor(c.r, c.g, c.b, live and 1 or 0.6)
        end
        bar._rcPaintThumb = Paint
        local function Settle()
            token = token + 1
            local t = token
            busy = true
            Paint()
            C_Timer.After(1.0, function()
                if t ~= token then return end
                busy = false
                Paint()
            end)
        end
        if bar.HookScript then
            bar:HookScript("OnEnter", function() hot = true Paint() end)
            bar:HookScript("OnLeave", function() hot = false Paint() end)
            bar:HookScript("OnMouseDown", function() drag = true Paint() end)
            bar:HookScript("OnMouseUp", function() drag = false Paint() end)
            bar:HookScript("OnValueChanged", function() if not drag then Settle() end end)
        end
        function bar:SizeThumb(contentH, viewH)
            local bh = self:GetHeight() or 0
            if not (contentH and viewH and contentH > 0 and bh > 0) then return end
            local h = math_max(THUMB_MIN, math_min(bh, bh * viewH / contentH))
            thumb:SetHeight(math_floor(h + 0.5))
        end
        -- re-read on a theme change (RefreshUIColors calls Repaint)
        local oldRepaint = bar.Repaint
        function bar:Repaint()
            if oldRepaint then oldRepaint(self) end
            if self.bg then
                local tc = GetScrollTrack()
                self.bg:SetVertexColor(tc.r, tc.g, tc.b, (tc.a or 1) * 0.45)
            end
            Paint()
        end
        Paint()
        return bar
    end

    -- The /rc window's wheel: `step` a notch, eased (each frame a share of
    -- what is left, 12 a second, done under 0.3 px). The easing runs only
    -- while it is moving; a value set from elsewhere (a page change, a
    -- jump) stops it where that put the bar.
    function RC.UI:SmoothWheel(area, bar, step)
        step = step or S.WHEEL
        local target, last
        local runner = CreateFrame("Frame", nil, area)
        runner:Hide()
        runner:SetScript("OnUpdate", function(self, dt)
            local cur = bar:GetValue()
            if last and math_abs(cur - last) > 0.01 then self:Hide() return end
            local diff = target - cur
            if math_abs(diff) < 0.3 then
                bar:SetValue(target)
                self:Hide()
                return
            end
            -- (2026-11-09: it crawled near the top and bottom, where the
            -- target stops running ahead) never slower than 1400 a second
            local stepv = diff * math_min(1, S.LERP * (dt or 0.016))
            local floor = 1400 * (dt or 0.016)
            if math_abs(stepv) < floor then
                stepv = ((diff > 0) and 1 or -1) * math_min(math_abs(diff), floor)
            end
            last = cur + stepv
            bar:SetValue(last)
        end)
        runner:SetScript("OnHide", function() last = nil end)
        -- (2026-11-08, Zac: "scrolling ... is really slow when im just
        -- slamming my scroll wheel") notches that come fast travel further:
        -- each one inside a fifth of a second of the last goes 1.5x the
        -- one before, up to 4x a notch
        local lastWheel, boost = 0, 1
        area:SetScript("OnMouseWheel", function(_, delta)
            local mn, mx = bar:GetMinMaxValues()
            if (mx or 0) <= 0 then return end
            local now = GetTime and GetTime() or 0
            if now - lastWheel < 0.2 then boost = math_min(4, boost * 1.5) else boost = 1 end
            lastWheel = now
            local base = (runner:IsShown() and target) or bar:GetValue()
            target = math_max(mn, math_min(mx, base - delta * step * boost))
            last = nil
            runner:Show()
        end)
        area._rcWheel = runner
        return runner
    end

    -- Chromeless X: two rotated 2px bars (.x1/.x2) and nothing else - no
    -- box, no Blizzard close art. Drawn rather than textured so it
    -- recolors with the theme (buttons.xNormal -> buttons.xHover).
    -- onClick receives the standard (self) button click args.
    -- Title-bar icon. Every window/dialog/popup the addon draws gets one
    -- at the left of its title bar; the title text anchors to the RIGHT of
    -- the returned texture rather than to the bar, so callers do not have
    -- to know the icon's size.
    --   local icon = RC.UI:AddTitleIcon(titleBar)
    --   titleText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    function RC.UI:AddTitleIcon(titleBar, size, xOffset)
        if not titleBar then return nil end
        local icon = titleBar:CreateTexture(nil, "ARTWORK")
        icon:SetSize(size or 16, size or 16)
        icon:SetPoint("LEFT", titleBar, "LEFT", xOffset or 8, 0)
        icon:SetTexture((RC.UI and RC.UI.ICON)
            or "Interface\\AddOns\\Readycheck\\Media\\Checkmark")
        if self.PaintMark then self:PaintMark(icon) end
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        titleBar.titleIcon = icon
        -- a header that wears the header art has a living mark (drop, turn,
        -- ring, flare on opening and under the mouse). Whichever of the
        -- two is added second does the wiring: the art here, or the icon
        -- in ApplyHeaderArt. Plain bars (stats bar, trackers) are left be.
        if titleBar._art and self.AnimateMark then
            self:AnimateMark(icon, titleBar, { idle = false, lead = 0.12 })
        end
        return icon
    end

    function RC.UI:CreateXCloseButton(parent, size, onClick)
        size = size or 22
        local btn = CreateFrame("Button", nil, parent)
        btn:SetSize(size, size)
        btn:EnableMouse(true)

        local xSize = math.floor(size * 0.5)
        local xThickness = 2

        local xNormColor = GetXNormal()

        local x1 = btn:CreateTexture(nil, "ARTWORK")
        x1:SetSize(xSize, xThickness)
        x1:SetPoint("CENTER")
        x1:SetColorTexture(xNormColor.r, xNormColor.g, xNormColor.b, 1)
        x1:SetRotation(math.rad(45))
        btn.x1 = x1

        local x2 = btn:CreateTexture(nil, "ARTWORK")
        x2:SetSize(xSize, xThickness)
        x2:SetPoint("CENTER")
        x2:SetColorTexture(xNormColor.r, xNormColor.g, xNormColor.b, 1)
        x2:SetRotation(math.rad(-45))
        btn.x2 = x2

        btn:SetScript("OnEnter", function(self)
            local hoverColor = GetXHover()
            self.x1:SetColorTexture(hoverColor.r, hoverColor.g, hoverColor.b, 1)
            self.x2:SetColorTexture(hoverColor.r, hoverColor.g, hoverColor.b, 1)
        end)
        btn:SetScript("OnLeave", function(self)
            local normColor = GetXNormal()
            self.x1:SetColorTexture(normColor.r, normColor.g, normColor.b, 1)
            self.x2:SetColorTexture(normColor.r, normColor.g, normColor.b, 1)
        end)
        if onClick then
            btn:SetScript("OnClick", onClick)
        end

        -- (2026-11-10) ONE CLOSE BOX: the /rc window's (UIF_Dialogs
        -- SkinCloseBox: the close icon, white 0.53 and full under the
        -- mouse) on every window and row, not only the 5.0 pop-ups. A
        -- close colour picked on the Appearance page keeps the drawn X in
        -- that colour.
        local cc = RC.db and RC.db.customColors and RC.db.customColors.buttons
        local picked = cc and (cc.xNormal or (cc.xHover and not RC:IsStaleColor("buttons", "xHover", cc.xHover)))
        if self.SkinCloseBox and not picked then self:SkinCloseBox(btn) end

        return btn
    end

    -- Same drawn-X button as CreateXCloseButton, just a different default
    -- size for row-level remove actions.
    function RC.UI:CreateRemoveButton(parent, size, onClick)
        return self:CreateXCloseButton(parent, size or 22, onClick)
    end

    -- A LibSharedMedia sound picker: a dropdown of every registered sound
    -- (RC:GetSoundItems) and a Play button. Picking a sound plays it and
    -- calls opts.onPick(key). opts: width (dropdown, default 220),
    -- selected (sound name), fallback (file path for Play when the name
    -- is unknown). Anchor the returned frame yourself; .dropdown and
    -- .playButton hang off it.
    function RC.UI:CreateSoundPicker(parent, opts)
        opts = opts or {}
        local width = opts.width or 220
        local holder = CreateFrame("Frame", nil, parent)
        holder:SetSize(width + 66, BASE.DROPDOWN_HEIGHT or 22)
        local dd = self:CreateScrollableDropdown(holder, width, opts.selected or RCL["Choose a sound"], 10)
        dd:SetPoint("LEFT", holder, "LEFT", 0, 0)
        if dd.menu then dd.menu:SetFrameStrata("TOOLTIP") end
        holder.selected = opts.selected
        dd:SetItems(RC:GetSoundItems(), function(key)
            holder.selected = key
            RC:PlaySoundKey(key, opts.fallback)
            if opts.onPick then opts.onPick(key) end
        end)
        if opts.selected then dd:SetSelectedValue(opts.selected, opts.selected) end
        local play = self:CreateStyledButton(holder, RCL["Play"], 58, 22)
        play:SetPoint("LEFT", dd, "RIGHT", 8, 0)
        play:SetScript("OnClick", function() RC:PlaySoundKey(holder.selected, opts.fallback) end)
        holder.dropdown, holder.playButton = dd, play
        return holder
    end

    -- Makes ESC close frameOrName. If it is a named global frame, adds it
    -- to UISpecialFrames (Blizzard's ESC-close list); otherwise wires a
    -- manual OnKeyDown handler on the frame itself.
    function RC.UI:RegisterEscapeClose(frameOrName)
        if not frameOrName then return frameOrName end

        local frame, name
        if type(frameOrName) == "string" then
            name = frameOrName
            frame = _G[name]
        else
            frame = frameOrName
            name = frame.GetName and frame:GetName() or nil
        end

        if name and name ~= "" then
            if not tContains(UISpecialFrames, name) then
                tinsert(UISpecialFrames, name)
            end
        elseif frame then
            -- Unnamed frames cannot ride UISpecialFrames, so ESC is read
            -- here. SetPropagateKeyboardInput is protected in combat, so
            -- the toggle is skipped there (same guard the framework
            -- dialogs use) - ESC still closes, every other key is simply
            -- left on whatever propagation state it already had.
            frame:EnableKeyboard(true)
            frame:SetScript("OnKeyDown", function(self, key)
                local handled = (key == "ESCAPE")
                if not InCombatLockdown() then
                    self:SetPropagateKeyboardInput(not handled)
                end
                if handled then
                    self:Hide()
                end
            end)
        end

        return frame
    end

    -- Wires OnEnter/OnLeave to swap frame's fill (and optional
    -- options.text color) between normBg/hoverBg. The fill is frame.bg
    -- when the frame paints with a flat texture (every RC.UI widget), or
    -- the backdrop color when a caller-built BackdropTemplate frame is
    -- handed in. options.skipWhen names a boolean field on frame that,
    -- when true, suppresses the color swap (e.g. a selected tab) while
    -- still firing options.onEnter/onLeave. Hover is instant - no tween.
    -- Use this instead of hand-writing hover scripts.
    local function PaintHoverFill(self, c)
        if not c then return end
        if self.bg and self.bg.SetVertexColor then
            self.bg:SetVertexColor(c.r, c.g, c.b, c.a or 1)
        elseif self.SetBackdropColor then
            self:SetBackdropColor(c.r, c.g, c.b, c.a or 1)
        end
    end

    function RC.UI:AttachHover(frame, normBg, hoverBg, options)
        if not frame or not normBg or not hoverBg then return frame end
        options = options or {}

        frame.normBg  = normBg
        frame.hoverBg = hoverBg

        local skipWhen   = options.skipWhen
        local textObj    = options.text
        if textObj then
            frame._hoverNormText  = options.normTextColor  or normBg
            frame._hoverHoverText = options.hoverTextColor or hoverBg
        end
        local extraEnter = options.onEnter
        local extraLeave = options.onLeave

        frame:SetScript("OnEnter", function(self)
            if skipWhen and self[skipWhen] then
                if extraEnter then extraEnter(self) end
                return
            end
            PaintHoverFill(self, self.hoverBg)
            if textObj then
                local tc = self._hoverHoverText
                textObj:SetTextColor(tc.r, tc.g, tc.b)
            end
            if extraEnter then extraEnter(self) end
        end)
        frame:SetScript("OnLeave", function(self)
            if skipWhen and self[skipWhen] then
                if extraLeave then extraLeave(self) end
                return
            end
            PaintHoverFill(self, self.normBg)
            if textObj then
                local tc = self._hoverNormText
                textObj:SetTextColor(tc.r, tc.g, tc.b)
            end
            if extraLeave then extraLeave(self) end
        end)
        return frame
    end

    -- Returns a layout helper (not a frame) that hands out sequential
    -- x,y offsets via grid:GetNextPosition(baseX, baseY); caller still
    -- creates and positions each element itself with the returned coords.
    function RC.UI:CreateGrid(parent, columns, elementWidth, elementHeight, spacing)
        local grid = {
            parent = parent,
            columns = columns or 2,
            elementWidth = elementWidth or 200,
            elementHeight = elementHeight or 32,
            spacing = spacing or 10,
            currentColumn = 0,
            currentRow = 0,
            elements = {}
        }

        function grid:GetNextPosition(baseX, baseY)
            local x = baseX + (self.currentColumn * (self.elementWidth + self.spacing))
            local y = baseY - (self.currentRow * (self.elementHeight + self.spacing))

            self.currentColumn = self.currentColumn + 1
            if self.currentColumn >= self.columns then
                self.currentColumn = 0
                self.currentRow = self.currentRow + 1
            end

            return x, y
        end

        function grid:Reset()
            self.currentColumn = 0
            self.currentRow = 0
        end

        function grid:GetTotalHeight()
            return (self.currentRow + (self.currentColumn > 0 and 1 or 0)) * (self.elementHeight + self.spacing)
        end

        return grid
    end

    -- The standard clickable button for this addon. Registers left and
    -- right clicks, paints .bg with a FLAT fill (never the statusbar
    -- texture - that is a gradient reserved for real bars), and hangs
    -- .bg/.border/.text/.highlight on the returned frame.
    --
    -- States, all read from the theme at paint time:
    --   rest      buttons.normalBackground, 1px black, text.buttonNormal
    --   hover     buttons.hoverBackground, label gold (ui.accentGold),
    --             plus an additive white 0.05 HIGHLIGHT lift
    --   pushed    a black 0.35 overlay (SetPushedTexture) - a flat fill
    --             gives no depth cue, so without it a click reads as a
    --             missed click
    --   disabled  buttons.disabledBackground, text.buttonDisabled
    --   active    buttons.configuredBackground, gold border at 0.7,
    --             text.buttonActive (button.isConfigured, see
    --             SetButtonConfigured / button:SetActive)
    -- Caller anchors and sizes further if defaults don't fit.
    -- THE /rc WINDOW'S BUTTONS (self._rcSet): a warm dark fill, a white
    -- edge and a white label at stepped alphas, brighter under the mouse;
    -- "footer" and "close" are the footer's (the close one in the
    -- accent), and fade 0.10 s between rest and hover.
    local function Lerp(a, b, t) return a + (b - a) * t end
    local function PaintSetButton(self, hot)
        local st = self._rcSet
        local t = self._rcFadeT or (hot and 1 or 0)
        local text = RC:GetColor("settings", "text")
        if not self:IsEnabled() then
            if self._rcPlate then self._rcPlate:Paint(0.03, 0.03) end
            self.bg:SetVertexColor(RC.UI:SCol("buttonBackground", S.BTN_BG_A * 0.5))
            if self.text then self.text:SetTextColor(RC.UI:SCol("text", S.BTN_TXT_A * S.OFF_A)) end
            if self.border then RC.UI:UpdateBorderColor(self.border, text, S.BTN_BRD_A * 0.5) end
            return
        end
        local A = RC.UI:SAccent()
        -- (2026-11-09) a page button is a raised plate: a lift and a top
        -- line on its fill, the edge warming to the accent under the mouse
        local plate = (st == "button") and RC.UI:Plate(self, 0, 0, 0, 0, false, self.bg) or nil
        if plate then plate:Paint(Lerp(0.085, 0.13, t), Lerp(0.08, 0.14, t)) end
        if plate and not self.isConfigured then
            self.bg:SetVertexColor(RC.UI:SCol("buttonBackground", 1))
            if self.border then
                local a0, a1 = S.BTN_BRD_A, 0.75
                local e = Lerp(0, 1, t)
                RC.UI:UpdateBorderColor(self.border,
                    { r = Lerp(text.r, A.r, e), g = Lerp(text.g, A.g, e), b = Lerp(text.b, A.b, e) }, Lerp(a0, a1, t))
            end
            if self.text then self.text:SetTextColor(RC.UI:SCol("text", Lerp(0.82, 1, t))) end
            if self._rcAfterPaint then self._rcAfterPaint(self) end
            return
        end
        if st == "close" or self.isConfigured then
            local fa = (st == "close") and S.FOOT_BG_A or Lerp(S.BTN_BG_A, S.BTN_BG_HA, t)
            self.bg:SetVertexColor(RC.UI:SCol(st == "close" and "windowBackground" or "buttonBackground", fa))
            local a = Lerp(S.CLOSE_A, 1, t)
            if self.border then RC.UI:UpdateBorderColor(self.border, A, a) end
            if self.text then self.text:SetTextColor(A.r, A.g, A.b, a) end
        elseif st == "footer" then
            self.bg:SetVertexColor(RC.UI:SCol("windowBackground", S.FOOT_BG_A))
            if self.border then RC.UI:UpdateBorderColor(self.border, text, Lerp(S.FOOT_BRD_A, S.FOOT_BRD_HA, t)) end
            if self.text then self.text:SetTextColor(RC.UI:SCol("text", Lerp(S.FOOT_TXT_A, S.FOOT_TXT_HA, t))) end
        else
            self.bg:SetVertexColor(RC.UI:SCol("buttonBackground", Lerp(S.BTN_BG_A, S.BTN_BG_HA, t)))
            if self.border then RC.UI:UpdateBorderColor(self.border, text, Lerp(S.BTN_BRD_A, S.BTN_BRD_HA, t)) end
            if self.text then self.text:SetTextColor(RC.UI:SCol("text", Lerp(S.BTN_TXT_A, S.BTN_TXT_HA, t))) end
        end
        -- a caller's own last word on the paint (a dialog's red Delete label)
        if self._rcAfterPaint then self._rcAfterPaint(self) end
    end
    local function PaintStyledButton(self, hot)
        if not self.bg then return end
        if self._rcSet then
            local to = hot and 1 or 0
            if self._rcFade and self._rcFadeT and self._rcFadeT ~= to and self:IsVisible() then
                self._rcFadeTo = to
                self._rcFade:Show()
            else
                self._rcFadeT = self._rcFade and to or nil
            end
            return PaintSetButton(self, hot)
        end
        if not self:IsEnabled() then
            local disabledBg = GetButtonDisabledBG()
            local txtDisabled = GetButtonTextDisabled()
            self.bg:SetVertexColor(disabledBg.r, disabledBg.g, disabledBg.b, disabledBg.a or 0.6)
            if self.text then self.text:SetTextColor(txtDisabled.r, txtDisabled.g, txtDisabled.b, 1) end
            if self.border then RC.UI:UpdateBorderColor(self.border, GetBorderNormal(), 1) end
            return
        end
        if self.isConfigured then
            local fill = hot and GetButtonConfiguredHover() or GetButtonConfiguredBG()
            local txtConfig = GetButtonTextConfigured()
            self.bg:SetVertexColor(fill.r, fill.g, fill.b, 1)
            if self.text then self.text:SetTextColor(txtConfig.r, txtConfig.g, txtConfig.b, 1) end
            if self.border then RC.UI:UpdateBorderColor(self.border, GetBorderSelected(), 1) end
        else
            local fill = hot and GetButtonHoverBG() or GetButtonNormalBG()
            local txt = hot and GetAccentGold() or GetButtonTextNormal()
            self.bg:SetVertexColor(fill.r, fill.g, fill.b, 1)
            if self.text then self.text:SetTextColor(txt.r, txt.g, txt.b, 1) end
            if self.border then RC.UI:UpdateBorderColor(self.border, GetBorderNormal(), 1) end
        end
    end

    -- A string cut short on purpose (a dropdown's choice, a narrow
    -- segment, a fixed cell) shows its whole text in a tooltip while it
    -- does not fit. owner: the frame that takes the hover (default: the
    -- string's parent). Call it after the owner's own OnEnter is set.
    function RC.UI:TruncTip(fs, owner)
        fs._rcTruncTip = true
        owner = owner or fs:GetParent()
        if not (owner and owner.HookScript) then return fs end
        local list = owner._rcTruncTips
        if list then
            for _, t in ipairs(list) do if t == fs then return fs end end
            list[#list + 1] = fs
            return fs
        end
        owner._rcTruncTips = { fs }
        owner:HookScript("OnEnter", function(self)
            local any = false
            for _, t in ipairs(self._rcTruncTips) do
                local w = t:GetWidth() or 0
                local cut
                if t.IsTruncated then cut = t:IsTruncated() else cut = (t:GetStringWidth() or 0) > w + 0.5 end
                if t:IsVisible() and w > 0 and cut then
                    if not any and not (GameTooltip:IsShown() and GameTooltip:GetOwner() == self) then
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    end
                    any = true
                    local c = RC:GetColor("text", "normal")
                    GameTooltip:AddLine(t:GetText() or "", c.r, c.g, c.b, true)
                end
            end
            if any then GameTooltip:Show() end
        end)
        owner:HookScript("OnLeave", function() GameTooltip:Hide() end)
        return fs
    end

    -- THE HELP LINE: the gray note under a control, never more than one
    -- line. A note that fits shows whole; a longer one shows its first
    -- sentence (or as many words as fit) with a gold "(?)", and the whole
    -- note is the line's tooltip. The settings search reads the whole note
    -- (holder._rcHelpText). Anchored TOPLEFT at (x, y) in card, as wide as
    -- the card leaves. Returns the next y and the holder.
    --   opts: size (10), color ({ cat, key }, default text.gray), title
    --   (tooltip heading, default "More"), gap (8, under the line),
    --   width (override), wrap (true: wrap instead, for the rare note that
    --   must stay whole on the page), short (the page's own one-line
    --   version; the whole text goes in the tooltip)
    local function FitsOne(fs, w) return (fs:GetStringWidth() or 0) <= w + 0.5 end
    function RC.UI:CreateHelpLine(card, x, y, text, opts)
        opts = opts or {}
        x = x or 14
        local cw = card.GetWidth and card:GetWidth() or 0
        if not cw or cw < 100 then cw = 560 end
        local w = opts.width or math_max(60, cw - x - 14)
        local holder = CreateFrame("Frame", nil, card)
        holder:SetPoint("TOPLEFT", card, "TOPLEFT", x, y)
        holder:SetSize(w, 12)
        local fs = CreateProfessionalFontString(holder, "OVERLAY", opts.size or 10, "")
        fs:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
        fs:SetJustifyH("LEFT")
        local col = opts.color and RC:GetColor(opts.color[1], opts.color[2]) or RC:GetColor("text", "gray")
        fs:SetTextColor(col.r, col.g, col.b, 1)
        text = tostring(text or "")
        holder._rcHelpText, holder._rcHelpFS, holder.text = text, fs, fs
        if opts.wrap then
            fs:SetWidth(w)
            fs:SetWordWrap(true)
            fs:SetText(text)
            local h = math_max(12, fs:GetStringHeight() or 12)
            holder:SetHeight(h)
            return y - h - (opts.gap or 8), holder
        end
        fs:SetWordWrap(false)
        local g = RC:GetColor("ui", "accentGold")
        local mark = string.format(" |cff%02x%02x%02x(?)|r", math_floor(g.r * 255 + 0.5), math_floor(g.g * 255 + 0.5), math_floor(g.b * 255 + 0.5))
        -- the page's own one-liner (opts.short) stands in for the note;
        -- either way the line is cut to fit with the whole note in the tooltip
        local base = opts.short or text
        local short
        local function Fit(fw)
            short = opts.short ~= nil and opts.short ~= text
            fs:SetWidth(0)
            fs:SetText(short and (base .. mark) or base)
            if not FitsOne(fs, fw) then
                short = true
                local first = base:match("^(.-[%.%!%?])%s")
                local shown
                if first then
                    fs:SetText(first .. mark)
                    if FitsOne(fs, fw) then shown = first end
                end
                if not shown then
                    -- as many whole words as fit, then "..."
                    local words, cut = {}, ""
                    for word in base:gmatch("%S+") do words[#words + 1] = word end
                    for k = 1, #words do
                        local try = table.concat(words, " ", 1, k) .. "..."
                        fs:SetText(try .. mark)
                        if not FitsOne(fs, fw) then break end
                        cut = try
                    end
                    shown = cut ~= "" and cut or "..."
                end
                fs:SetText(shown .. mark)
            end
            fs:SetWidth(fw)
            holder:SetWidth(fw)
        end
        Fit(w)
        -- one line at whatever size the font is
        local lineH = math_max(12, math_ceil(fs:GetStringHeight() or 12))
        holder:SetHeight(lineH)
        local function Hover()
            if not short or holder._rcHelpHover then return end
            holder._rcHelpHover = true
            holder:EnableMouse(true)
            holder:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
                local gt = RC:GetColor("text", "gold")
                GameTooltip:AddLine(opts.title or RCL["More"], gt.r, gt.g, gt.b)
                local tn = RC:GetColor("text", "normal")
                GameTooltip:AddLine(text, tn.r, tn.g, tn.b, true)
                GameTooltip:Show()
            end)
            holder:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        Hover()
        -- set in under a switch (BindDependents): cut again to the width left
        function holder:Refit(fw)
            if fw and fw >= 30 then Fit(fw) Hover() end
        end
        return y - lineH - (opts.gap or 8), holder
    end

    function RC.UI:CreateStyledButton(parent, text, width, height)
        local button = CreateFrame("Button", nil, parent)
        button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        button:SetSize(width or BASE.BUTTON_WIDTH, height or BASE.BUTTON_HEIGHT)

        button.bg = button:CreateTexture(nil, "BACKGROUND")
        button.bg:SetAllPoints()
        button.bg:SetTexture(FLAT)
        local btnBg = GetButtonNormalBG()
        button.bg:SetVertexColor(btnBg.r, btnBg.g, btnBg.b, 1)

        button.border = self:CreateSimpleBorder(button)

        button.text = CreateProfessionalFontString(button, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
        button.text:SetPoint("CENTER")
        button.text:SetText(text)
        -- Never narrower than its label: a longer word or a wider font
        -- widens the button rather than running its text past both edges.
        do
            local need = math.ceil(button.text:GetStringWidth() or 0) + 12
            if need > (button:GetWidth() or 0) then button:SetWidth(need) end
        end
        local txtNorm = GetButtonTextNormal()
        button.text:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b, 1)

        button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
        button.highlight:SetAllPoints(button.bg)
        button.highlight:SetColorTexture(C.whiteHint[1], C.whiteHint[2], C.whiteHint[3], C.whiteHint[4])
        button.highlight:SetBlendMode("ADD")

        -- Structural black, not a theme colour: it darkens whatever fill
        -- is underneath so every theme gets the same pressed feel.
        button.pushed = button:CreateTexture(nil, "ARTWORK")
        button.pushed:SetAllPoints(button.bg)
        button.pushed:SetColorTexture(0, 0, 0, 0.35)
        button:SetPushedTexture(button.pushed)

        button:SetScript("OnEnter", function(self) PaintStyledButton(self, true) end)
        button:SetScript("OnLeave", function(self) PaintStyledButton(self, false) end)
        button:SetScript("OnDisable", function(self) PaintStyledButton(self, false) end)
        button:SetScript("OnEnable", function(self) PaintStyledButton(self, self:IsMouseOver()) end)

        -- Repaint from the theme; RefreshUIColors and the colour editor
        -- call this through button:Repaint() when a colour changes.
        function button:Repaint()
            PaintStyledButton(self, self:IsMouseOver())
        end
        function button:SetActive(on)
            RC.UI:SetButtonConfigured(self, on and true or false)
        end

        button:EnableMouse(true)

        -- (2026-11-10, Zac: "so many buttons ... not updated to match the
        -- new buttons") ONE BUTTON LOOK: every button, wherever it is built
        -- (a pop-up, the consumables window, a bar's panel), is the /rc
        -- window's raised plate. It was only the ones on the /rc pages.
        RC.UI:StyleSettingsButton(button)

        return button
    end

    -- A button in the /rc window's look (CreateStyledButton does this for
    -- every button built on the page or in the sidebar). style: nil (a
    -- page button), "footer" or "close" (the footer's two kinds, which
    -- fade 0.10 s between rest and hover).
    function RC.UI:StyleSettingsButton(button, style)
        if not (button and button.bg) then return button end
        button._rcSet = style or "button"
        if button.highlight then button.highlight:SetAlpha(0) end
        if button.pushed then button.pushed:SetAlpha(0) end
        if button.text then RC:ApplyCustomFont(button.text, (style and S.F_VALUE) or BASE.FONT_SIZE_SMALL, "OUTLINE") end
        if style and not button._rcFade then
            local fade = CreateFrame("Frame", nil, button)
            fade:Hide()
            fade:SetScript("OnUpdate", function(f, dt)
                local to = button._rcFadeTo or 0
                local cur = button._rcFadeT or to
                local step = (dt or 0.016) / S.FADE
                if cur < to then cur = math_min(to, cur + step) else cur = math_max(to, cur - step) end
                button._rcFadeT = cur
                PaintSetButton(button, to == 1)
                if cur == to then f:Hide() end
            end)
            button._rcFade = fade
            button._rcFadeT = 0
        end
        PaintStyledButton(button, false)
        return button
    end

    -- Convenience setter for button.text created by CreateStyledButton.
    function RC.UI:SetButtonText(button, text)
        if button.text then
            button.text:SetText(text)
        end
    end

    -- A quiet, borderless text action - for secondary per-row actions
    -- (like the sync page's "Only") where a full boxed button per row is
    -- visually heavy. Dim gray at rest, accent color on hover.
    function RC.UI:CreateLinkButton(parent, text, fontSize)
        local button = CreateFrame("Button", nil, parent)
        button:RegisterForClicks("LeftButtonUp")

        button.text = CreateProfessionalFontString(button, "OVERLAY", fontSize or BASE.FONT_SIZE_NORMAL)
        button.text:SetPoint("CENTER")
        button.text:SetText(text)

        local dim = GetTextGray()
        button.text:SetTextColor(dim.r, dim.g, dim.b, 1)

        local w = (button.text:GetStringWidth() or 24) + 10
        button:SetSize(w, (fontSize or BASE.FONT_SIZE_NORMAL) + 8)

        -- Colours read at hover time so a theme change shows without a rebuild.
        button:SetScript("OnEnter", function(self)
            local hover = GetAccentGold()
            self.text:SetTextColor(hover.r, hover.g, hover.b, 1)
        end)
        button:SetScript("OnLeave", function(self)
            local rest = GetTextGray()
            self.text:SetTextColor(rest.r, rest.g, rest.b, 1)
        end)

        button:EnableMouse(true)
        return button
    end

    -- Sets button.isConfigured and repaints .bg/.border/.text to the
    -- "configured" or normal palette. Call after CreateStyledButton
    -- whenever the underlying setting's configured state changes.
    function RC.UI:SetButtonConfigured(button, isConfigured)
        if not button then
            RC:DebugPrint("SetButtonConfigured: button is nil!", "config")
            return
        end

        -- Active look: green configured fill, a muted GREEN ring, green
        -- text. Normal look: flat normal fill, black ring, normal text.
        -- The ring is green rather than gold on purpose: gold is the
        -- "you are here / open" accent and green is the "this is on"
        -- state, and a gold outline around a green fill made every active
        -- control read as two competing signals at once.
        -- (in the /rc window: the accent edge and label, PaintStyledButton)
        if button._rcSet then
            button.isConfigured = isConfigured and true or false
            PaintStyledButton(button, button.IsMouseOver and button:IsMouseOver())
            return
        end
        local configBg = GetButtonConfiguredBG()
        local txtConfig = GetButtonTextConfigured()
        local btnNorm = GetButtonNormalBG()
        local txtNorm = GetButtonTextNormal()

        if isConfigured then
            if button.bg then
                button.bg:SetVertexColor(configBg.r, configBg.g, configBg.b, 1)
            end
            if button.border then
                self:UpdateBorderColor(button.border, GetBorderSelected(), 1)
            end
            if button.text then
                button.text:SetTextColor(txtConfig.r, txtConfig.g, txtConfig.b, 1)
            end
            button.isConfigured = true
        else
            if button.bg then
                button.bg:SetVertexColor(btnNorm.r, btnNorm.g, btnNorm.b, 1)
            end
            if button.border then
                self:UpdateBorderColor(button.border, GetBorderNormal(), 1)
            end
            if button.text then
                button.text:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b, 1)
            end
            button.isConfigured = false
        end
    end

    -- Fakes an outline on a small directional texture (dropdown arrow,
    -- back-button arrow) by stamping 8 black copies at 1px offsets one
    -- sublevel behind it, since these textures have no edgeFile of their
    -- own. Hooks arrowTex's Show/Hide so the copies track visibility, and
    -- SetDropdownArrowOpen's SetTexCoord flip so they stay in sync.
    function RC.UI:AddArrowBorder(arrowTex, thickness)
        if not arrowTex then return end
        local parent = arrowTex:GetParent()
        if not parent then return end
        local t = thickness or 1
        local layer, sub = arrowTex:GetDrawLayer()
        sub = sub or 0
        local texPath = arrowTex:GetTexture()
        local offsets = { {-1, 0}, {1, 0}, {0, -1}, {0, 1}, {-1, -1}, {-1, 1}, {1, -1}, {1, 1} }
        local copies = {}
        for _, o in ipairs(offsets) do
            local b = parent:CreateTexture(nil, layer)
            b:SetDrawLayer(layer, sub - 1)
            b:SetTexture(texPath)
            if arrowTex.GetRotation and b.SetRotation then
                b:SetRotation(arrowTex:GetRotation())
            end
            b:SetVertexColor(0, 0, 0, 1)
            b:SetPoint("TOPLEFT",     arrowTex, "TOPLEFT",     o[1] * t, o[2] * t)
            b:SetPoint("BOTTOMRIGHT", arrowTex, "BOTTOMRIGHT", o[1] * t, o[2] * t)
            copies[#copies + 1] = b
        end
        if not arrowTex:IsShown() then
            for _, b in ipairs(copies) do b:Hide() end
        end
        if arrowTex.__rcBorderCopies then
            local existing = arrowTex.__rcBorderCopies
            for _, b in ipairs(copies) do existing[#existing + 1] = b end
        else
            arrowTex.__rcBorderCopies = copies
            hooksecurefunc(arrowTex, "Hide", function(self)
                for _, b in ipairs(self.__rcBorderCopies) do b:Hide() end
            end)
            hooksecurefunc(arrowTex, "Show", function(self)
                for _, b in ipairs(self.__rcBorderCopies) do b:Show() end
            end)
        end
    end

    -- Adds a 1px black outline frame around a Slider's thumb texture,
    -- since WHITE8X8 thumbs have no border of their own. Result is
    -- cached on thumb.__rcThumbBorder so calling this again on the same
    -- slider is a no-op; visibility tracks the thumb via hooksecurefunc.
    function RC.UI:AddThumbBorder(slider, thickness)
        if not slider or not slider.GetThumbTexture then return end
        local thumb = slider:GetThumbTexture()
        if not thumb then return end
        if thumb.__rcThumbBorder then return thumb.__rcThumbBorder end
        local t = thickness or 1
        local ov = CreateFrame("Frame", nil, slider)
        ov:EnableMouse(false)
        ov:SetFrameLevel(slider:GetFrameLevel() + 5)
        ov:SetAllPoints(thumb)
        local function edge()
            local e = ov:CreateTexture(nil, "OVERLAY")
            e:SetColorTexture(0, 0, 0, 1)
            return e
        end
        local b = { frame = ov }
        b.top = edge()
        b.top:SetPoint("TOPLEFT", ov, "TOPLEFT", 0, 0)
        b.top:SetPoint("TOPRIGHT", ov, "TOPRIGHT", 0, 0)
        b.top:SetHeight(t)
        b.bottom = edge()
        b.bottom:SetPoint("BOTTOMLEFT", ov, "BOTTOMLEFT", 0, 0)
        b.bottom:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", 0, 0)
        b.bottom:SetHeight(t)
        b.left = edge()
        b.left:SetPoint("TOPLEFT", ov, "TOPLEFT", 0, 0)
        b.left:SetPoint("BOTTOMLEFT", ov, "BOTTOMLEFT", 0, 0)
        b.left:SetWidth(t)
        b.right = edge()
        b.right:SetPoint("TOPRIGHT", ov, "TOPRIGHT", 0, 0)
        b.right:SetPoint("BOTTOMRIGHT", ov, "BOTTOMRIGHT", 0, 0)
        b.right:SetWidth(t)
        thumb.__rcThumbBorder = b
        if not thumb:IsShown() then ov:Hide() end
        hooksecurefunc(thumb, "Hide", function() ov:Hide() end)
        hooksecurefunc(thumb, "Show", function() ov:Show() end)
        return b
    end

    -- Back-navigation button with a left arrow (.arrow) + label (.text).
    -- Strips a leading "< " from text since the arrow texture already
    -- conveys direction. Exposes button:GetText()/SetText() wrappers.
    function RC.UI:CreateBackButton(parent, text, width, height)
        width = width or 80
        height = height or 28
        text = text or "Back"

        text = text:gsub("^< ?", "")

        -- Same flat box as CreateStyledButton (fill .bg + 1px ring), with
        -- the arrow glyph taking the label's hover gold alongside it.
        local button = CreateFrame("Button", nil, parent)
        button:SetSize(width, height)
        button.bg = button:CreateTexture(nil, "BACKGROUND")
        button.bg:SetAllPoints()
        button.bg:SetTexture(FLAT)
        local btnBg = GetButtonNormalBG()
        button.bg:SetVertexColor(btnBg.r, btnBg.g, btnBg.b, 1)
        button.border = self:CreateSimpleBorder(button)

        button.arrow = button:CreateTexture(nil, "ARTWORK")
        button.arrow:SetSize(10, 10)
        button.arrow:SetPoint("LEFT", button, "LEFT", 8, 0)
        button.arrow:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrowLeft")
        local txtNorm = GetButtonTextNormal()
        button.arrow:SetVertexColor(txtNorm.r, txtNorm.g, txtNorm.b, 1)
        RC.UI:AddArrowBorder(button.arrow)

        button.text = CreateProfessionalFontString(button, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
        button.text:SetPoint("LEFT", button.arrow, "RIGHT", 4, 0)
        button.text:SetText(text)
        button.text:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b, 1)

        button.highlight = button:CreateTexture(nil, "HIGHLIGHT")
        button.highlight:SetAllPoints(button.bg)
        button.highlight:SetColorTexture(C.whiteHint[1], C.whiteHint[2], C.whiteHint[3], C.whiteHint[4])
        button.highlight:SetBlendMode("ADD")

        button.pushed = button:CreateTexture(nil, "ARTWORK")
        button.pushed:SetAllPoints(button.bg)
        button.pushed:SetColorTexture(0, 0, 0, 0.35)
        button:SetPushedTexture(button.pushed)

        button:SetScript("OnEnter", function(self)
            local hoverBg = GetButtonHoverBG()
            local gold = GetAccentGold()
            self.bg:SetVertexColor(hoverBg.r, hoverBg.g, hoverBg.b, 1)
            self.text:SetTextColor(gold.r, gold.g, gold.b, 1)
            self.arrow:SetVertexColor(gold.r, gold.g, gold.b, 1)
        end)

        button:SetScript("OnLeave", function(self)
            local normBg = GetButtonNormalBG()
            local rest = GetButtonTextNormal()
            self.bg:SetVertexColor(normBg.r, normBg.g, normBg.b, 1)
            self.text:SetTextColor(rest.r, rest.g, rest.b, 1)
            self.arrow:SetVertexColor(rest.r, rest.g, rest.b, 1)
        end)

        function button:GetText()
            return self.text:GetText()
        end

        function button:SetText(newText)
            self.text:SetText(newText)
        end

        return button
    end

    -- Measures text at fontSize using a hidden, cached measuring
    -- FontString (self.measureFrame/self.measureText) rather than
    -- creating one per call. Returns pixel width only.
    function RC.UI:CalculateTextWidth(text, fontSize)
        fontSize = fontSize or BASE.FONT_SIZE_NORMAL

        if not self.measureFrame then
            self.measureFrame = CreateFrame("Frame", nil, UIParent)
            self.measureFrame:Hide()
            self.measureText = self.measureFrame:CreateFontString(nil, "OVERLAY")
        end

        RC:ApplyCustomFont(self.measureText, fontSize, "OUTLINE")

        self.measureText:SetText(text)
        return self.measureText:GetStringWidth()
    end

    -- CreateStyledButton sized to fit its own label text. Overrides
    -- button.text:SetText so later relabeling re-measures and calls
    -- button:UpdateWidth() automatically; set button.dynamicWidth = false
    -- to opt out of that behavior after creation.
    function RC.UI:CreateDynamicButton(parent, text, height, padding, minWidth)
        height = height or BASE.BUTTON_HEIGHT
        padding = padding or 20
        minWidth = minWidth or 60

        local textWidth = self:CalculateTextWidth(text, BASE.FONT_SIZE_SMALL)
        local buttonWidth = math.max(minWidth, textWidth + (padding * 2))

        local button = self:CreateStyledButton(parent, text, buttonWidth, height)

        button.dynamicWidth = true
        button.textPadding = padding
        button.minWidth = minWidth

        function button:UpdateWidth()
            local newTextWidth = RC.UI:CalculateTextWidth(self.text:GetText(), BASE.FONT_SIZE_SMALL)
            local newWidth = math.max(self.minWidth, newTextWidth + (self.textPadding * 2))
            self:SetWidth(newWidth)
        end

        local originalSetText = button.text.SetText
        button.text.SetText = function(fontString, newText)
            originalSetText(fontString, newText)
            if button.dynamicWidth then
                button:UpdateWidth()
            end
        end

        return button
    end

    -- Tab button, text-width sized like CreateDynamicButton. Same flat
    -- box as a button, in the ZacUI tab look (no green): closed = grey
    -- label, hover = gold label, open (tab:SetSelected(true)) = lifted a
    -- shade, white label, a gold line along its foot. Exposes
    -- tab:GetText()/SetText() (SetText also re-sizes the tab).
    local function PaintTab(self, hot)
        if self._rcSet then
            -- (a segment: a page button's box; the one picked has the
            -- accent edge and a full-white label, and its accent foot)
            local text = RC:GetColor("settings", "text")
            local A = RC.UI:SAccent()
            -- (2026-11-09) the picked tab is a raised plate with the accent
            -- line along its top; the others sit back in the strip
            local plate = RC.UI:Plate(self, 0, 0, 0, 0, false, self.bg)
            if self.isSelected then
                self.bg:SetVertexColor(RC.UI:SCol("buttonBackground", 1))
                plate:Paint(0.11, 0)
                RC.UI:UpdateBorderColor(self.border, text, 0.16)
                self.text:SetTextColor(RC.UI:SCol("text", 1))
            else
                self.bg:SetVertexColor(RC.UI:SCol("shade", hot and 0.18 or 0.30))
                plate:Paint(hot and 0.05 or 0, 0)
                RC.UI:UpdateBorderColor(self.border, text, hot and 0.12 or 0.06)
                self.text:SetTextColor(RC.UI:SCol("text", hot and S.NAV_HOVER or S.BTN_TXT_A))
            end
            if self.underline then
                self.underline:SetColorTexture(A.r, A.g, A.b, 1)
                self.underline:SetShown(self.isSelected and true or false)
                if not self._rcLineTop then
                    self._rcLineTop = true
                    self.underline:ClearAllPoints()
                    self.underline:SetPoint("TOPLEFT", self, "TOPLEFT", 1, -1)
                    self.underline:SetPoint("TOPRIGHT", self, "TOPRIGHT", -1, -1)
                end
            end
            return
        end
        local fill, txt
        if self.isSelected then
            fill = GetButtonHoverBG()
            txt = GetTextNormal()
        else
            fill = hot and GetButtonHoverBG() or GetButtonNormalBG()
            txt = hot and GetAccentGold() or GetTextGray()
        end
        RC.UI:UpdateBorderColor(self.border, GetBorderNormal(), 1)
        self.bg:SetVertexColor(fill.r, fill.g, fill.b, 1)
        self.text:SetTextColor(txt.r, txt.g, txt.b, 1)
        if self.underline then
            local a = GetAccentGold()
            self.underline:SetColorTexture(a.r, a.g, a.b, 1)
            self.underline:SetShown(self.isSelected and true or false)
        end
    end

    function RC.UI:CreateTabButton(parent, text, height, padding, minWidth)
        height = height or BASE.EDITBOX_HEIGHT
        padding = padding or 16
        minWidth = minWidth or 80

        local textWidth = self:CalculateTextWidth(text, BASE.FONT_SIZE_SMALL)
        local buttonWidth = math.max(minWidth, textWidth + (padding * 2))

        local tab = CreateFrame("Button", nil, parent)
        tab:SetSize(buttonWidth, height)
        tab.bg = tab:CreateTexture(nil, "BACKGROUND")
        tab.bg:SetAllPoints()
        tab.bg:SetTexture(FLAT)
        tab.border = self:CreateSimpleBorder(tab)
        tab.underline = tab:CreateTexture(nil, "OVERLAY", nil, 2)
        tab.underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 1, 1)
        tab.underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -1, 1)
        tab.underline:SetHeight(2)
        tab.underline:Hide()

        tab.text = CreateProfessionalFontString(tab, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
        tab.text:SetPoint("CENTER")
        tab.text:SetText(text)

        tab.highlight = tab:CreateTexture(nil, "HIGHLIGHT")
        tab.highlight:SetAllPoints(tab.bg)
        tab.highlight:SetColorTexture(C.whiteHint[1], C.whiteHint[2], C.whiteHint[3], C.whiteHint[4])
        tab.highlight:SetBlendMode("ADD")

        tab.isSelected = false
        tab.dynamicWidth = true
        tab.textPadding = padding
        tab.minWidth = minWidth

        function tab:UpdateWidth()
            local newTextWidth = RC.UI:CalculateTextWidth(self.text:GetText(), BASE.FONT_SIZE_SMALL)
            local newWidth = math.max(self.minWidth, newTextWidth + (self.textPadding * 2))
            self:SetWidth(newWidth)
        end

        function tab:SetSelected(selected)
            self.isSelected = selected and true or false
            PaintTab(self, false)
        end
        function tab:Repaint()
            PaintTab(self, self:IsMouseOver())
        end

        tab:SetScript("OnEnter", function(self) PaintTab(self, true) end)
        tab:SetScript("OnLeave", function(self) PaintTab(self, false) end)
        -- (2026-11-10, Zac: "literally every menu popup etc needs to
        -- match") ONE TAB LOOK: the /rc window's tab on a tab anywhere
        do
            tab._rcSet = true
            tab.highlight:SetAlpha(0)
        end
        PaintTab(tab, false)

        function tab:GetText()
            return self.text:GetText()
        end

        function tab:SetText(newText)
            self.text:SetText(newText)
            self:UpdateWidth()
        end

        return tab
    end

    -- Builds an equal-width row of tabs from opts.tabs ({key,label}
    -- entries) that auto-resize to fill the container width. Returns
    -- (group, nextY) where nextY = opts.y - opts.advance, for stacking
    -- more UI below the tab row. group:SetSelected(key) repaints all
    -- tabs; opts.onClick(key) fires on selecting a non-active tab.
    function RC.UI:CreateTabGroup(parent, opts)
        opts = opts or {}
        local tabs = opts.tabs or {}
        local numTabs = #tabs
        local yPos = opts.y or 0
        local advance = opts.advance or 38
        if numTabs == 0 then return nil, yPos end

        -- ZacUI grid: tabs are buttons, 22 tall, 1px apart. The ZacUI tab
        -- look, no green (Zac 2026-11-02: green ring + gold line read as two
        -- themes fighting): closed tabs quiet with a grey label, the open
        -- one lifted a shade with a white label and a gold line along its
        -- foot; hover is the gold label, so hover and open never look alike.
        local height    = opts.height or BASE.EDITBOX_HEIGHT
        local tabHeight = opts.tabHeight or BASE.EDITBOX_HEIGHT
        local fontSize  = opts.fontSize or BASE.FONT_SIZE_SMALL
        local spacing   = opts.spacing or 1
        local inset     = opts.inset or 10
        -- In the /rc window: text tabs, white 0.53 / 0.86 under the mouse /
        -- 1.0 open, an accent line (the label + 14 wide) under the open one.
        -- The page's own row (opts.bar) is the window's tab bar: 40 high on
        -- a black 0.20 band, labels at 16, each tab its label + 30, 6 apart.
        local set = RC.UI:InSettings(parent)
        -- (a row of tabs straight on the page is the page's own row)
        local isBar = set and (opts.bar or parent._rcSetRoot) and true or false
        -- a caller that counted on a shorter row: the page goes down by the
        -- difference, so nothing under the row moves under it
        local extraH = 0
        if isBar and not opts.bar then extraH = math_max(0, S.TABS - tabHeight) end
        if isBar then
            height, tabHeight, fontSize, spacing = S.TABS, S.TABS, S.F_TAB, 6
            inset = 9
        end

        -- opts.palette still overrides any of these for a caller with a
        -- reason; the defaults are the framework's button palette.
        local pal     = opts.palette or {}
        local normBg  = pal.normBg  or RC:GetColor("buttons", "normalBackground")
        local hoverBg = pal.hoverBg or RC:GetColor("buttons", "hoverBackground")
        local selBg   = pal.selBg   or hoverBg
        local selTxt  = pal.selTxt  or GetTextNormal()
        local normTxt = pal.normTxt or GetTextGray()
        local hoverTxt = pal.hoverTxt or RC:GetColor("ui",    "accentGold")
        -- the open tab's ring stays the plain border unless a caller asks
        local selBorder = pal.selBorder or GetBorderNormal()
        local selBorderAlpha = pal.selBorder and (pal.selBorder.a or 1) or 1
        local lineCol = pal.selBorder or GetAccentGold()

        local container = CreateFrame("Frame", nil, parent)
        container:SetHeight(height)
        if opts.width then
            container:SetWidth(opts.width)
            container:SetPoint("TOPLEFT", parent, "TOPLEFT", inset, yPos)
        else
            container:SetPoint("TOPLEFT",  parent, "TOPLEFT",  inset, yPos)
            container:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -inset, yPos)
        end

        local group = { container = container, buttons = {}, _order = {} }
        if isBar then
            local band = container:CreateTexture(nil, "BACKGROUND")
            band:SetTexture(FLAT)
            band:SetPoint("TOPLEFT", container, "TOPLEFT", -inset - 20, 0)
            band:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", inset + 20, 0)
            band:SetVertexColor(RC.UI:SCol("shade", S.TAB_BAND_A))
            container.band = band
            group.isBar = true
        end

        local function paint(btn, lbl, isAct)
            btn.isTabSelected = isAct
            if set then
                btn.bg:SetVertexColor(0, 0, 0, 0)
                RC.UI:UpdateBorderColor(btn.border, GetBorderNormal(), 0)
                lbl:SetTextColor(RC.UI:SCol("text", isAct and 1 or (btn._rcHot and S.NAV_HOVER or S.DIM_A)))
                -- (2026-11-09, Zac: "all these buttons also didnt get styled")
                -- the open tab is a raised plate with the accent line along
                -- its top; a closed one lifts a little under the mouse
                local pl = RC.UI:Plate(btn, 0, 0, 5, 5, true)
                local hot = btn._rcHot and true or false
                local tc = RC:GetColor("settings", "text")
                pl:SetShown(isAct or hot)
                if isAct then
                    pl.box:SetVertexColor(RC.UI:SCol("buttonBackground", 1))
                    pl:Paint(0.11, 0, tc, 0.16)
                elseif hot then
                    pl.box:SetVertexColor(RC.UI:SCol("buttonBackground", 0.5))
                    pl:Paint(0.05, 0, tc, 0.10)
                end
                if btn.underline then
                    local A = RC.UI:SAccent()
                    btn.underline:SetColorTexture(A.r, A.g, A.b, 1)
                    btn.underline:ClearAllPoints()
                    btn.underline:SetPoint("TOPLEFT", pl.box, "TOPLEFT", 1, -1)
                    btn.underline:SetPoint("TOPRIGHT", pl.box, "TOPRIGHT", -1, -1)
                    btn.underline:SetShown(isAct and true or false)
                end
                return
            end
            local fill = isAct and selBg or normBg
            btn.bg:SetVertexColor(fill.r, fill.g, fill.b, 1)
            if isAct then
                RC.UI:UpdateBorderColor(btn.border, selBorder, selBorderAlpha)
            else
                RC.UI:UpdateBorderColor(btn.border, GetBorderNormal(), 1)
            end
            local txt = isAct and selTxt or normTxt
            lbl:SetTextColor(txt.r, txt.g, txt.b)
            -- the tab showing wears a 2 px bar along its foot in the "on"
            -- colour, so the row reads at a glance
            if btn.underline then
                btn.underline:SetColorTexture(lineCol.r, lineCol.g, lineCol.b, 1)
                btn.underline:SetShown(isAct and true or false)
            end
        end

        for i, td in ipairs(tabs) do
            local tKey, tLabel = td.key, td.label
            local isAct = (opts.selected == tKey)

            local tab = CreateFrame("Button", nil, container)
            tab:SetHeight(tabHeight)
            tab.bg = tab:CreateTexture(nil, "BACKGROUND")
            tab.bg:SetAllPoints()
            tab.bg:SetTexture(FLAT)
            tab.border = RC.UI:CreateSimpleBorder(tab)
            tab.underline = tab:CreateTexture(nil, "OVERLAY", nil, 2)
            tab.underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 1, 1)
            tab.underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -1, 1)
            tab.underline:SetHeight(2)
            tab.underline:Hide()

            tab.highlight = tab:CreateTexture(nil, "HIGHLIGHT")
            tab.highlight:SetAllPoints(tab.bg)
            tab.highlight:SetColorTexture(C.whiteHint[1], C.whiteHint[2], C.whiteHint[3], C.whiteHint[4])
            tab.highlight:SetBlendMode("ADD")

            local lbl = RC:CreateFontString(tab, "OVERLAY", nil, fontSize)
            lbl:SetPoint("CENTER", 0, 0)
            lbl:SetText(tLabel)

            paint(tab, lbl, isAct)

            if set then
                tab.highlight:SetAlpha(0)
                tab:SetScript("OnEnter", function(self) self._rcHot = true paint(self, lbl, self.isTabSelected) end)
                tab:SetScript("OnLeave", function(self) self._rcHot = nil paint(self, lbl, self.isTabSelected) end)
                function tab:Repaint() paint(self, lbl, self.isTabSelected) end
            else
            RC.UI:AttachHover(tab, normBg, hoverBg, {
                skipWhen = "isTabSelected",
                text = lbl,
                normTextColor  = normTxt,
                hoverTextColor = hoverTxt,
            })
            end

            local capturedKey = tKey
            tab:SetScript("OnClick", function()
                if not tab.isTabSelected and opts.onClick then
                    opts.onClick(capturedKey)
                end
            end)

            group.buttons[tKey] = { btn = tab, lbl = lbl }
            group._order[i] = tKey
        end

        -- group.selected: the tab showing now (search reads it)
        group.selected = opts.selected
        function group:SetSelected(key)
            self.selected = key
            for k, entry in pairs(self.buttons) do
                paint(entry.btn, entry.lbl, k == key)
            end
        end

        -- Equal widths while every label fits; otherwise each tab as wide
        -- as its label with the slack shared out; and when even that is too
        -- wide for one line the tabs wrap onto more rows (no label is ever
        -- cut short). group.rows is how many rows the last layout used.
        local ROW_GAP = 2
        function group:Recalc()
            local w = container:GetWidth()
            if not w or w <= 0 then return end
            local nat, widest = {}, 0
            for i = 1, numTabs do
                local e = self.buttons[self._order[i]]
                nat[i] = math.ceil(e.lbl:GetStringWidth() or 0) + (isBar and 30 or 12)
                widest = math.max(widest, nat[i])
            end
            local rows = {}
            local totalGaps = (numTabs - 1) * spacing
            local equalW = math.floor((w - totalGaps) / numTabs)
            -- (the window's tab bar: each tab its own width, from the left)
            if isBar then equalW = -1 end
            if equalW >= widest then
                rows[1] = { from = 1, to = numTabs }
            else
                local x, from = 0, 1
                for i = 1, numTabs do
                    if i > from and x + spacing + nat[i] > w + 0.5 then
                        rows[#rows + 1] = { from = from, to = i - 1 }
                        from, x = i, nat[i]
                    else
                        x = x + (i > from and spacing or 0) + nat[i]
                    end
                end
                rows[#rows + 1] = { from = from, to = numTabs }
            end
            for r, row in ipairs(rows) do
                local count = row.to - row.from + 1
                local sum = 0
                for i = row.from, row.to do sum = sum + nat[i] end
                local slack = isBar and 0 or math.max(0, w - sum - (count - 1) * spacing)
                local prev
                for i = row.from, row.to do
                    local btn = self.buttons[self._order[i]].btn
                    btn:ClearAllPoints()
                    btn:SetWidth((#rows == 1 and equalW >= widest) and equalW or math.floor(nat[i] + slack / count))
                    if not prev then
                        btn:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -(r - 1) * (tabHeight + ROW_GAP))
                    else
                        btn:SetPoint("LEFT", prev, "RIGHT", spacing, 0)
                    end
                    prev = btn
                end
            end
            self.rows = #rows
            container:SetHeight(math.max(height, #rows * tabHeight + (#rows - 1) * ROW_GAP))
            -- (the open tab's line follows its label's width)
            if set then
                for _, e in pairs(self.buttons) do paint(e.btn, e.lbl, e.btn.isTabSelected) end
            end
        end
        group:Recalc()
        container:SetScript("OnSizeChanged", function() group:Recalc() end)
        -- not measured yet (the client lays a new frame out lazily): the
        -- buttons have no place until it is, so try again next frame and
        -- whenever the row is shown
        if not group.rows then
            C_Timer.After(0, function() if not group.rows then group:Recalc() end end)
        end
        container:SetScript("OnShow", function() if not group.rows then group:Recalc() end end)

        -- (rows past the first push what follows down)
        return group, yPos - advance - extraH - ((group.rows or 1) - 1) * (tabHeight + ROW_GAP)
    end

    -- Segment buttons (CreateSegmentedControl with opts.buttons): a compact row of equal-width segments
    -- acting as radio options inside a card ("Show in: Raids | Any group
    -- | Everywhere"). Each segment is a CreateTabButton, so it wears the
    -- framework tab look - flat fill, 1px black ring, hover gold text,
    -- selected = the active look (configured fill, gold ring, green
    -- text). Where CreateTabGroup is page navigation that spans the page
    -- and hands back a nextY, this is a value control: it sits at a
    -- control x like a dropdown, repaints itself on click and carries
    -- the current key.
    -- opts:
    --   items     array of { key=, label=, tooltip= (optional) }
    --   selected  initial key
    --   width     total width; omit to span parent minus inset each side
    --   height    row height (default BASE.EDITBOX_HEIGHT)
    --   spacing   gap between segments (default 1)
    --   x, y      TOPLEFT offset in parent; omit both to anchor yourself
    --   inset     side inset when width is omitted (default 14)
    --   fontSize  label size (default BASE.FONT_SIZE_SMALL)
    --   onSelect  function(key), fires after the repaint and only when
    --             the key actually changed
    -- Returns the container frame: control:SetValue(key, silent),
    -- control:GetValue(), control:Repaint(), control.segments (ordered
    -- tab buttons, each with .segmentKey) and control.byKey[key].
    function RC.UI:CreateSegmentButtons(parent, opts)
        opts = opts or {}
        local items    = opts.items or {}
        local numSegs  = #items
        local height   = opts.height or BASE.EDITBOX_HEIGHT
        local spacing  = opts.spacing or 1
        local fontSize = opts.fontSize or BASE.FONT_SIZE_SMALL

        local control = CreateFrame("Frame", nil, parent)
        control:SetHeight(height)
        if opts.width then
            control:SetWidth(opts.width)
            if opts.y then
                control:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.x or opts.inset or 14, opts.y)
            end
        else
            local inset = opts.inset or opts.x or 14
            local y = opts.y or 0
            control:SetPoint("TOPLEFT",  parent, "TOPLEFT",  inset, y)
            control:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -inset, y)
        end

        control.segments = {}
        control.byKey    = {}
        control.value    = opts.selected
        control.onSelect = opts.onSelect

        local function ShowSegmentTooltip(seg)
            if not seg.tooltip then return end
            GameTooltip:SetOwner(seg, "ANCHOR_RIGHT")
            local gold = RC:GetColor("text", "gold")
            local norm = RC:GetColor("text", "normal")
            GameTooltip:SetText(seg.text:GetText() or "", gold.r, gold.g, gold.b)
            GameTooltip:AddLine(seg.tooltip, norm.r, norm.g, norm.b, true)
            GameTooltip:Show()
        end

        for i, item in ipairs(items) do
            local seg = self:CreateTabButton(control, item.label or tostring(item.key), height, 0, 0)
            -- Width comes from Recalc, never from the label.
            seg.dynamicWidth = false
            seg.segmentKey   = item.key
            seg.tooltip      = item.tooltip
            if fontSize ~= BASE.FONT_SIZE_SMALL and RC.ApplyCustomFont then
                RC:ApplyCustomFont(seg.text, fontSize, "OUTLINE")
            end
            if item.tooltip then
                seg:HookScript("OnEnter", ShowSegmentTooltip)
                seg:HookScript("OnLeave", function() GameTooltip:Hide() end)
            end
            self:TruncTip(seg.text, seg)
            seg:SetScript("OnClick", function(s)
                control:SetValue(s.segmentKey)
            end)
            control.segments[i]      = seg
            control.byKey[item.key]  = seg
        end

        function control:SetValue(key, silent)
            local changed = (self.value ~= key)
            self.value = key
            for _, seg in ipairs(self.segments) do
                seg:SetSelected(seg.segmentKey == key)
                seg:Repaint()
            end
            if changed and not silent then
                if self.onSelect then self.onSelect(key) end
                NotifySettingChanged("segmented")
            end
        end

        function control:GetValue()
            return self.value
        end

        function control:Repaint()
            for _, seg in ipairs(self.segments) do seg:Repaint() end
        end

        -- Equal segments while every label fits; otherwise each as wide as
        -- its label with the slack shared out; a label still too wide for
        -- its segment is cut short and shows whole on hover.
        function control:Recalc()
            local w = self:GetWidth()
            if not w or w <= 0 or numSegs == 0 then return end
            local segW = math_floor((w - (numSegs - 1) * spacing) / numSegs)
            local nat, sum, widest = {}, 0, 0
            for i, seg in ipairs(self.segments) do
                seg.text:SetWidth(0)
                nat[i] = math.ceil(seg.text:GetStringWidth() or 0) + 10
                sum, widest = sum + nat[i], math.max(widest, nat[i])
            end
            local free = w - (numSegs - 1) * spacing
            local proportional = widest > segW and sum <= free
            local prev
            for i, seg in ipairs(self.segments) do
                local sw = segW
                if proportional then sw = math_floor(nat[i] + (free - sum) / numSegs) end
                seg:ClearAllPoints()
                seg:SetWidth(sw)
                seg.text:SetWidth(math.max(10, sw - 6))
                seg.text:SetWordWrap(false)
                if prev then
                    seg:SetPoint("LEFT", prev, "RIGHT", spacing, 0)
                else
                    seg:SetPoint("LEFT", self, "LEFT", 0, 0)
                end
                prev = seg
            end
            -- The last segment soaks up the rounding so the row ends flush.
            if prev then prev:SetPoint("RIGHT", self, "RIGHT", 0, 0) end
        end
        control:Recalc()
        control:SetScript("OnSizeChanged", function() control:Recalc() end)
        control:SetValue(opts.selected, true)

        return control
    end

    -- Value picker: one of N choices for a saved setting ("Show in:
    -- Inside Raids / Dungeons & Raids / Any Group / Everywhere"). Built as
    -- the house dropdown (CreateScrollableDropdown: flat box, gold hover,
    -- the choices in its menu, each choice's tooltip on hover in the open
    -- list). Page navigation stays as tabs (CreateTabGroup); a row of
    -- buttons is kept only where opts.buttons asks for it (the world buff
    -- board's sort chips: several keys at once, shift / right click).
    -- opts:
    --   items     array of { key=, label=, tooltip= (optional) }
    --   selected  initial key
    --   label     optional caption drawn left of the dropdown, same row
    --   width     room for the control; omit to span parent minus inset
    --             each side. The dropdown itself is as wide as its
    --             longest choice (opts.ddWidth forces a width), never
    --             wider than the room.
    --   height    row height (default BASE.EDITBOX_HEIGHT)
    --   x, y      TOPLEFT offset in parent; omit both to anchor yourself
    --   inset     side inset when width is omitted (default 14)
    --   fontSize  text size (default BASE.FONT_SIZE_SMALL)
    --   onSelect  function(key), fires only when the key actually changed
    --   buttons   true: the old row of segment buttons (spacing = gap)
    -- Returns the container frame: control:SetValue(key, silent),
    -- control:GetValue(), control:Repaint(), control.dropdown,
    -- control.segments (ordered choice rows, each with .segmentKey,
    -- .text and :Click()) and control.byKey[key].
    function RC.UI:CreateSegmentedControl(parent, opts)
        opts = opts or {}
        if opts.buttons then return self:CreateSegmentButtons(parent, opts) end
        local items    = opts.items or {}
        local height   = opts.height or BASE.EDITBOX_HEIGHT
        local fontSize = opts.fontSize or BASE.FONT_SIZE_SMALL

        local control = CreateFrame("Frame", nil, parent)
        control:SetHeight(height)
        if opts.width then
            control:SetWidth(opts.width)
            if opts.y then
                control:SetPoint("TOPLEFT", parent, "TOPLEFT", opts.x or opts.inset or 14, opts.y)
            end
        else
            local inset = opts.inset or opts.x or 14
            local y = opts.y or 0
            control:SetPoint("TOPLEFT",  parent, "TOPLEFT",  inset, y)
            control:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -inset, y)
        end

        control.segments = {}
        control.byKey    = {}
        control.value    = opts.selected
        control.onSelect = opts.onSelect
        control._rcSegment = true

        local function LabelOf(key)
            for _, it in ipairs(items) do
                if it.key == key then return it.label or tostring(it.key) end
            end
            return key ~= nil and tostring(key) or ""
        end
        local function TipOf(key)
            for _, it in ipairs(items) do if it.key == key then return it.tooltip end end
        end

        local cap
        if opts.label and opts.label ~= "" then
            cap = CreateProfessionalFontString(control, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
            cap:SetPoint("LEFT", control, "LEFT", 0, 0)
            cap:SetJustifyH("LEFT")
            cap:SetWordWrap(false)
            cap:SetText(opts.label)
            local c = GetTextNormal()
            cap:SetTextColor(c.r, c.g, c.b, 1)
            control.label = cap
        end

        local dd = self:CreateScrollableDropdown(control, opts.ddWidth or 120, LabelOf(opts.selected), math_max(1, #items))
        dd:SetHeight(height)
        if cap then
            dd:SetPoint("LEFT", cap, "RIGHT", 8, 0)
        else
            dd:SetPoint("LEFT", control, "LEFT", 0, 0)
        end
        if fontSize ~= BASE.FONT_SIZE_SMALL and RC.ApplyCustomFont then
            RC:ApplyCustomFont(dd.text, fontSize, "OUTLINE")
        end
        control.dropdown = dd

        local list = {}
        for i, it in ipairs(items) do
            list[i] = { value = it.key, text = it.label or tostring(it.key), tooltip = it.tooltip }
        end
        dd:SetItems(list, function(value)
            -- the row's own click raises the one settings notification
            local changed = (control.value ~= value)
            control.value = value
            if changed and control.onSelect then control.onSelect(value) end
        end)
        dd:SetSearchEnabled(false)
        for i, row in ipairs(dd.items) do
            row.segmentKey = row.value
            row.text = row.label
            control.segments[i] = row
            control.byKey[row.value] = row
        end

        function control:SetValue(key, silent)
            local changed = (self.value ~= key)
            self.value = key
            dd:SetSelectedValue(key, LabelOf(key))
            if changed and not silent then
                if self.onSelect then self.onSelect(key) end
                NotifySettingChanged("segmented")
            end
        end

        function control:GetValue()
            return self.value
        end

        function control:Repaint()
            dd:SetSelectedValue(self.value, LabelOf(self.value))
            if cap then
                local c = GetTextNormal()
                cap:SetTextColor(c.r, c.g, c.b, 1)
            end
        end

        -- As wide as the longest choice, never wider than the room; a
        -- choice still too long is cut short in the box (whole on hover).
        local natural = 0
        for _, row in ipairs(dd.items) do
            if row.label then natural = math_max(natural, math.ceil(row.label:GetStringWidth() or 0)) end
        end
        dd.text:SetWidth(0)
        for _, it in ipairs(list) do
            dd.text:SetText(it.text)
            natural = math_max(natural, math.ceil(dd.text:GetStringWidth() or 0))
        end
        natural = math_max(opts.minWidth or 90, natural + 46)
        function control:Recalc()
            local room = self:GetWidth() or 0
            local capW = cap and (math.ceil(cap:GetStringWidth() or 0) + 8) or 0
            local want = opts.ddWidth or natural
            if room > 0 then
                if cap and room - capW < 90 then
                    -- no room for the caption: it is cut short (whole on hover)
                    capW = math_max(40, room - 90)
                    cap:SetWidth(capW - 8)
                elseif cap then
                    cap:SetWidth(0)
                end
                want = math_max(60, math_min(want, room - capW))
            end
            if dd._rcW ~= want then
                dd._rcW = want
                dd:SetDropdownWidth(want)
            end
            dd:SetSelectedIcon(nil)
        end
        if cap then self:TruncTip(cap, control) end
        control:Recalc()
        control:SetScript("OnSizeChanged", function() control:Recalc() end)
        control:SetValue(opts.selected, true)

        -- the closed box names the choice and what it does
        dd:HookScript("OnEnter", function(box)
            local tip = TipOf(control.value)
            if not tip then return end
            local gold = RC:GetColor("text", "gold")
            local norm = RC:GetColor("text", "normal")
            if not (GameTooltip:IsShown() and GameTooltip:GetOwner() == box) then
                GameTooltip:SetOwner(box, "ANCHOR_RIGHT")
                GameTooltip:SetText(LabelOf(control.value), gold.r, gold.g, gold.b)
            end
            GameTooltip:AddLine(tip, norm.r, norm.g, norm.b, true)
            GameTooltip:Show()
        end)
        dd:HookScript("OnLeave", function() GameTooltip:Hide() end)

        -- the settings search reads every choice and its tooltip
        control._rcSearchTip = function()
            local parts = {}
            for _, it in ipairs(items) do
                parts[#parts + 1] = it.label or tostring(it.key)
                if it.tooltip then parts[#parts + 1] = it.tooltip end
            end
            return table.concat(parts, " ")
        end

        return control
    end

    -- ============================================================
    -- THE RESIZE CORNER (2026-11-11, Zac: "update the resize handler and
    -- make something for it so its not just some dots"; of five drawn
    -- for him he picked the solid corner). The grip was six 2px dots. It
    -- is a filled right triangle sitting in the window's corner now, its
    -- short sides along the window's edges: muted at rest; under the
    -- mouse, and for as long as it is being pulled, the accent and two
    -- larger, over a tenth of a second. The same corner ZacUI wears.
    --
    -- One file (Media\Icons\grip: the triangle fills the lower-right half
    -- of a 32px canvas, so its legs are the canvas's edges and stay
    -- sharp at any scale) and one place that draws it:
    --   RC.UI:GripArt(grip, opts)  puts it on a grip button; returns the texture
    --       opts.corner ("BOTTOMRIGHT"), opts.size (10: legs at rest),
    --       opts.grow (2: more when lit), opts.inset (3: clear of a 1px
    --       border), opts.layer ("ARTWORK"), opts.rest / opts.hot
    --       (functions returning r, g, b, a)
    --   RC.UI:GripLit(grip, on)    the mouse is on it or not (eased)
    --   RC.UI:GripHold(grip)       it has just been pressed: it stays lit
    --                              until the left button comes up, wherever
    --                              the mouse goes meanwhile and whatever the
    --                              owner does with its own mouse-up script
    --   RC.UI:GripPaint(grip)      redraw as it stands (a theme change)
    -- ============================================================
    local GRIP_TIME = 0.1
    local function GripRest()
        local c = GetTextGray()
        return c.r * 0.7, c.g * 0.7, c.b * 0.7, 0.85
    end
    local function GripHot()
        local c = GetAccentGold()
        return c.r, c.g, c.b, 1
    end
    local function GripDraw(art)
        local p = art._p or 0
        local r, g, b, a = art._rest()
        if p > 0 then
            local r2, g2, b2, a2 = art._hot()
            r, g, b, a = r + (r2 - r) * p, g + (g2 - g) * p, b + (b2 - b) * p, (a or 1) + ((a2 or 1) - (a or 1)) * p
        end
        art:SetVertexColor(r, g, b, a or 1)
        local side = art._side + art._grow * p
        art:SetSize(side, side)
    end
    -- One driver for every grip, running only while one of them changes.
    local gripMoving, gripDriver = {}, nil
    local function GripStep(self, dt)
        local step = (dt or 0.016) / GRIP_TIME
        local busy
        for art in pairs(gripMoving) do
            -- (held: watched until the button comes up - a corner is left
            -- behind on the first frame of a pull, and several windows
            -- script the grip's mouse-up themselves)
            if art._held and not (IsMouseButtonDown and IsMouseButtonDown("LeftButton")) then
                art._held = nil
                art._want = art._over and 1 or 0
            end
            local want, p = art._want or 0, art._p or 0
            if p ~= want then
                if p < want then p = math.min(want, p + step) else p = math.max(want, p - step) end
                art._p = p
                GripDraw(art)
            end
            if p == want and not art._held then gripMoving[art] = nil else busy = true end
        end
        if not busy then self:SetScript("OnUpdate", nil) end
    end
    local function GripRun(art)
        gripMoving[art] = true
        gripDriver = gripDriver or CreateFrame("Frame")
        gripDriver:SetScript("OnUpdate", GripStep)
    end
    function RC.UI:GripArt(grip, opts)
        opts = opts or {}
        local corner = opts.corner or "BOTTOMRIGHT"
        local inset = opts.inset or 3
        local art = grip.art or grip:CreateTexture(nil, opts.layer or "ARTWORK")
        art:SetTexture((self.ICONS or "Interface\\AddOns\\Readycheck\\Media\\Icons\\") .. "grip")
        local left = corner == "BOTTOMLEFT" or corner == "TOPLEFT"
        local top = corner == "TOPLEFT" or corner == "TOPRIGHT"
        art:SetTexCoord(left and 1 or 0, left and 0 or 1, top and 1 or 0, top and 0 or 1)
        art:ClearAllPoints()
        art:SetPoint(corner, grip, corner, left and inset or -inset, top and -inset or inset)
        art._side, art._grow = opts.size or 10, opts.grow or 2
        art._rest, art._hot = opts.rest or GripRest, opts.hot or GripHot
        art._p, art._want, art._over, art._held = 0, 0, nil, nil
        grip.art = art
        GripDraw(art)
        return art
    end
    function RC.UI:GripLit(grip, on)
        local art = grip and grip.art
        if not art then return end
        local down = IsMouseButtonDown and IsMouseButtonDown("LeftButton") and true or false
        if on then
            art._cameDown = down or nil       -- (something else being dragged across it)
        elseif down and art._over and not art._cameDown then
            -- left with the button down, having arrived with it up: it is
            -- being pulled, whoever scripted the press
            art._held = true
        end
        art._over = on and true or nil
        art._want = (on or art._held) and 1 or 0
        if art._held then GripRun(art) return end      -- (watched until the button comes up)
        if (art._p or 0) == art._want then return end
        -- (unseen: nothing to ease)
        if grip.IsVisible and not grip:IsVisible() then
            art._p = art._want
            gripMoving[art] = nil
            GripDraw(art)
            return
        end
        GripRun(art)
    end
    function RC.UI:GripHold(grip)
        local art = grip and grip.art
        if not art then return end
        art._held = true
        art._want = 1
        GripRun(art)
    end
    function RC.UI:GripPaint(grip)
        if grip and grip.art then GripDraw(grip.art) end
    end

    -- Adds a bottom-right resize handle (the solid corner above) to frame
    -- and makes it resizable within opts.minW/minH/maxW/maxH.
    -- opts.onResize, if given, becomes frame's OnSizeChanged handler.
    function RC.UI:AttachResizeGrip(frame, opts)
        opts = opts or {}
        frame:SetResizable(true)
        if frame.SetResizeBounds then
            frame:SetResizeBounds(opts.minW or 200, opts.minH or 120, opts.maxW or 900, opts.maxH or 700)
        elseif frame.SetMinResize then
            frame:SetMinResize(opts.minW or 200, opts.minH or 120)
            if frame.SetMaxResize then
                frame:SetMaxResize(opts.maxW or 900, opts.maxH or 700)
            end
        end

        local grip = CreateFrame("Button", nil, frame)
        grip:SetSize(16, 16)
        grip:SetPoint("BOTTOMRIGHT", 0, 0)
        grip:SetFrameLevel(frame:GetFrameLevel() + 10)

        -- Dim at rest, gold on hover - a resize corner nobody discovers
        -- is a window nobody resizes. Lit for as long as it is held.
        RC.UI:GripArt(grip)
        grip:SetScript("OnEnter", function(self) RC.UI:GripLit(self, true) end)
        grip:SetScript("OnLeave", function(self) RC.UI:GripLit(self, false) end)
        grip:SetScript("OnMouseDown", function(self, btn)
            if btn == "LeftButton" then
                RC.UI:GripHold(self)
                frame:StartSizing("BOTTOMRIGHT")
            end
        end)
        grip:SetScript("OnMouseUp", function() frame:StopMovingOrSizing() end)
        grip:HookScript("OnHide", function(self) RC.UI:GripLit(self, false) end)

        if opts.onResize then
            frame:SetScript("OnSizeChanged", opts.onResize)
        end
        return grip
    end

    ------------------------------------------------------------------
    -- HUD HANDLE
    -- The controls every self-sizing on-screen frame (a tracker, a
    -- notice, a bar) gets: a small strip that sits just outside one top
    -- corner, invisible until the mouse is over it, holding a padlock
    -- that locks and unlocks the frame and, while unlocked, a dotted grip
    -- that drags to resize - by SCALE, because these frames lay
    -- themselves out from their content and a width would just be
    -- overwritten on the next refresh. Drag the frame itself to move it
    -- (RC.Position.MakeMovable reads the same lock).
    --   RC.UI:AttachHudHandle(frame, {
    --       getLocked = fn() -> bool,  setLocked = fn(bool),
    --       -- the grip, one of:
    --       getWidth = fn() -> n,  setWidth = fn(n) (live),  onWidthEnd = fn(n),  minW, maxW
    --       getScale = fn() -> n,  setScale = fn(n) (live),  onScaleEnd = fn(n),  minScale, maxScale
    --       corner = "TOPRIGHT" | "TOPLEFT",  idleAlpha = 0 (shown only while the mouse is over the frame),
    --       inside = true   -- the strip sits in the frame's top corner (on its
    --                       -- title bar) instead of above it
    --       strip = <an existing strip frame to add to> })
    -- Returns the strip; strip.Refresh() repaints after a setting change.
    ------------------------------------------------------------------

    function RC.UI:AttachHudHandle(frame, opts)
        opts = opts or {}
        local corner = opts.corner or "TOPRIGHT"
        local strip = opts.strip
        local idle = opts.idleAlpha or 0
        if not strip then
            strip = CreateFrame("Frame", nil, opts.inside and frame or UIParent)
            strip:SetSize(30, 12)
            strip:SetFrameStrata(frame:GetFrameStrata())
            strip:SetFrameLevel(frame:GetFrameLevel() + 5)
            if not opts.inside then
                frame:HookScript("OnShow", function() strip:Show() end)
                frame:HookScript("OnHide", function() strip:Hide() end)
                strip:SetShown(frame:IsShown())
            end
            strip.idleAlpha = idle
            strip:SetAlpha(strip.idleAlpha)
        end
        strip.frame = frame
        local hasGrip = opts.setWidth ~= nil or opts.setScale ~= nil

        -- the padlock is drawn flat, in the same language as the dot grip:
        -- an 8x5 body with a shackle of three 1.5px bars over it; unlocked,
        -- the shackle swings open (left leg gone, the rest shifted right)
        local lock = CreateFrame("Button", nil, strip)
        lock:SetSize(12, 12)
        local body = lock:CreateTexture(nil, "ARTWORK")
        body:SetTexture(FLAT)
        body:SetSize(8, 5)
        body:SetPoint("BOTTOM", lock, "BOTTOM", 0, 1)
        local shL = lock:CreateTexture(nil, "ARTWORK") shL:SetTexture(FLAT) shL:SetSize(1.5, 4)
        local shT = lock:CreateTexture(nil, "ARTWORK") shT:SetTexture(FLAT) shT:SetSize(6, 1.5)
        local shR = lock:CreateTexture(nil, "ARTWORK") shR:SetTexture(FLAT) shR:SetSize(1.5, 4)
        lock.parts = { body, shL, shT, shR }
        lock.body, lock.shL, lock.shT, lock.shR = body, shL, shT, shR
        local function Shape(locked)
            shL:ClearAllPoints() shT:ClearAllPoints() shR:ClearAllPoints()
            local dx = locked and 0 or 2
            shL:SetShown(locked)
            shT:SetPoint("BOTTOM", body, "TOP", dx, 2.5)
            shL:SetPoint("BOTTOMLEFT", shT, "BOTTOMLEFT", 0, -3)
            shR:SetPoint("BOTTOMRIGHT", shT, "BOTTOMRIGHT", 0, -3)
        end
        lock.Shape = Shape

        local grip = CreateFrame("Button", nil, strip)
        grip:SetSize(12, 12)
        -- (the solid corner, small; it points the way the frame grows)
        RC.UI:GripArt(grip, { corner = corner == "TOPLEFT" and "BOTTOMLEFT" or "BOTTOMRIGHT", size = 8, grow = 2, inset = 1,
            rest = function()
                local g = GetTextGray()
                return g.r * 0.8, g.g * 0.8, g.b * 0.8, 0.9
            end })

        -- the strip rides the frame's corner, outside it; its buttons line
        -- up from the frame's edge inwards
        local function Place()
            if not opts.strip then
                strip:ClearAllPoints()
                if opts.inside then
                    local ix, iy = opts.insetX or 6, opts.insetY or 5
                    if corner == "TOPLEFT" then strip:SetPoint("TOPLEFT", frame, "TOPLEFT", ix, -iy)
                    else strip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -ix, -iy) end
                else
                    if corner == "TOPLEFT" then strip:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 1)
                    else strip:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, 1) end
                    strip:SetScale(frame:GetScale())
                end
            end
            lock:ClearAllPoints()
            grip:ClearAllPoints()
            if corner == "TOPLEFT" then
                lock:SetPoint("LEFT", strip, "LEFT", strip.lockInset or 0, 0)
                grip:SetPoint("LEFT", lock, "RIGHT", 3, 0)
            else
                lock:SetPoint("RIGHT", strip, "RIGHT", -(strip.lockInset or 0), 0)
                grip:SetPoint("RIGHT", lock, "LEFT", -3, 0)
            end
        end

        local function Paint()
            local locked = opts.getLocked and opts.getLocked() or false
            Shape(locked)
            local c = locked and GetTextGray() or GetAccentGold()
            for _, t in ipairs(lock.parts) do t:SetVertexColor(c.r, c.g, c.b, 1) end
            grip:SetShown(not locked and hasGrip)
            RC.UI:GripPaint(grip)
            strip.idleAlpha = idle
            if not strip.hot then strip:SetAlpha(strip.idleAlpha) end
        end

        -- The handle shows while the mouse is over the FRAME (or the strip
        -- itself), and is gone otherwise. A locked frame has its mouse off,
        -- so OnEnter never fires for it: a light poll while the frame is
        -- shown reads IsMouseOver instead (one cheap call, 6x a second).
        local function Hover(on)
            if strip.hot == on then return end
            strip.hot = on
            strip:SetAlpha(on and 1 or strip.idleAlpha)
        end
        local poll
        local function Poll()
            if poll then return end
            poll = RC.Profiler:TrackTicker("HudHandle", 0.15, function()
                if not frame:IsShown() then
                    if poll then poll:Cancel() poll = nil end
                    Hover(false)
                    return
                end
                Hover(frame:IsMouseOver(4, -4, -4, 4) or strip:IsMouseOver(4, -4, -4, 4)
                    or (grip.dragX ~= nil))
            end)
        end
        frame:HookScript("OnShow", Poll)
        frame:HookScript("OnHide", function() if poll then poll:Cancel() poll = nil end Hover(false) end)
        if frame:IsShown() then Poll() end
        strip:EnableMouse(true)

        lock:SetScript("OnClick", function()
            local locked = not (opts.getLocked and opts.getLocked() or false)
            if opts.setLocked then opts.setLocked(locked) end
            Paint()
        end)
        lock:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            local locked = opts.getLocked and opts.getLocked() or false
            GameTooltip:SetText(locked and RCL["Locked"] or RCL["Unlocked"], 1, 1, 1)
            GameTooltip:AddLine(locked and RCL["Click to unlock: then drag the frame to move it, the corner to resize it."]
                or RCL["Drag the frame to move it, the corner to resize it. Click to lock."], 0.8, 0.8, 0.8, true)
            GameTooltip:Show()
        end)
        lock:HookScript("OnLeave", function() GameTooltip:Hide() end)

        -- the grip: a sideways drag changes the width (or, for a frame
        -- that has no width of its own, the scale)
        local byWidth = opts.setWidth ~= nil
        local minS, maxS = opts.minScale or 0.6, opts.maxScale or 1.6
        local minW, maxW = opts.minW or 160, opts.maxW or 600
        grip:SetScript("OnMouseDown", function(self, btn)
            if btn ~= "LeftButton" then return end
            local x = GetCursorPosition()
            self.dragX = x
            if byWidth then
                self.dragW = (opts.getWidth and opts.getWidth()) or frame:GetWidth() or 200
            else
                self.dragScale = (opts.getScale and opts.getScale()) or frame:GetScale() or 1
            end
            RC.UI:GripHold(self)
            self:SetScript("OnUpdate", function(g)
                local cx = GetCursorPosition()
                local dx = (cx - g.dragX) / (frame:GetEffectiveScale() or 1)
                if corner == "TOPLEFT" then dx = -dx end
                if byWidth then
                    local w = math.floor(g.dragW + dx + 0.5)
                    if w < minW then w = minW elseif w > maxW then w = maxW end
                    if w ~= g.lastW then
                        g.lastW = w
                        opts.setWidth(w)
                    end
                else
                    local sc = g.dragScale + dx / 160
                    if sc < minS then sc = minS elseif sc > maxS then sc = maxS end
                    sc = math.floor(sc * 100 + 0.5) / 100
                    if sc ~= g.lastScale then
                        g.lastScale = sc
                        opts.setScale(sc)
                        if not (opts.strip or opts.inside) then strip:SetScale(frame:GetScale()) end
                    end
                end
            end)
        end)
        grip:SetScript("OnMouseUp", function(self)
            self:SetScript("OnUpdate", nil)
            self.dragX = nil
            if self.lastW and opts.onWidthEnd then opts.onWidthEnd(self.lastW) end
            if self.lastScale and opts.onScaleEnd then opts.onScaleEnd(self.lastScale) end
            self.lastW, self.lastScale = nil, nil
            Paint()
        end)
        grip:HookScript("OnEnter", function(self)
            RC.UI:GripLit(self, true)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(RCL["Resize"], 1, 1, 1)
            GameTooltip:AddLine(RCL["Drag sideways."], 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        grip:HookScript("OnLeave", function(self)
            GameTooltip:Hide()
            RC.UI:GripLit(self, false)
        end)

        strip.lock, strip.grip = lock, grip
        strip.Refresh = function() Place() Paint() end
        strip.Refresh()
        return strip
    end

    -- Flips arrowTex's vertical tex coords to point up/down for
    -- open/closed dropdown state; also flips any AddArrowBorder copies
    -- so the fake outline stays aligned with the arrow.
    function RC.UI:SetDropdownArrowOpen(arrowTex, open)
        if not arrowTex then return end
        local t1, t2 = 0, 1
        if open then t1, t2 = 1, 0 end
        arrowTex:SetTexCoord(0, 1, t1, t2)
        if arrowTex.__rcBorderCopies then
            for _, c in ipairs(arrowTex.__rcBorderCopies) do
                c:SetTexCoord(0, 1, t1, t2)
            end
        end
    end

    -- Square icon tile that toggles one thing on/off (a weapon shown on
    -- a bar, an aura tracked by a tracker). Framework tile look: flat
    -- buttons.normalBackground fill, 1px black ring, icon inset 2px;
    -- ON = buttons.configuredBackground fill + ui.borderSelected (green)
    -- ring with the icon in full colour; OFF = normal fill, black ring,
    -- icon desaturated and dimmed. Hover lifts the fill to
    -- buttons.hoverBackground. Returns the Button; call tile:SetOn(bool)
    -- to repaint, wire OnClick / HookScript("OnEnter") yourself. Lived
    -- in Readycheck_Consumables' Cons_HelperCfg.lua (RC._sbc alias kept
    -- there) until the aura tracker pages in Readycheck_Reminders needed
    -- it without that addon loaded.
    local function PaintIconToggleTile(self, hot)
        local fill
        if self.isOn then
            fill = hot and GetButtonConfiguredHover() or GetButtonConfiguredBG()
            RC.UI:UpdateBorderColor(self.border, GetBorderSelected(), 1)
            self.icon:SetDesaturated(false)
            self.icon:SetAlpha(1)
        else
            fill = hot and GetButtonHoverBG() or GetButtonNormalBG()
            RC.UI:UpdateBorderColor(self.border, GetBorderNormal(), 1)
            self.icon:SetDesaturated(true)
            self.icon:SetAlpha(0.45)
        end
        self.bg:SetVertexColor(fill.r, fill.g, fill.b, 1)
    end

    function RC.UI:CreateIconToggleTile(parent, size, iconTexture)
        local tile = CreateFrame("Button", nil, parent)
        tile:SetSize(size, size)
        tile:RegisterForClicks("LeftButtonUp")

        tile.bg = tile:CreateTexture(nil, "BACKGROUND")
        tile.bg:SetAllPoints()
        tile.bg:SetTexture(FLAT)
        tile.border = self:CreateSimpleBorder(tile)

        tile.icon = tile:CreateTexture(nil, "ARTWORK")
        tile.icon:SetPoint("TOPLEFT", tile, "TOPLEFT", 2, -2)
        tile.icon:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -2, 2)
        tile.icon:SetTexture(iconTexture or 134400)
        tile.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        tile.highlight = tile:CreateTexture(nil, "HIGHLIGHT")
        tile.highlight:SetAllPoints(tile.bg)
        tile.highlight:SetTexture(FLAT)
        tile.highlight:SetVertexColor(C.whiteHint[1], C.whiteHint[2], C.whiteHint[3], C.whiteHint[4])
        tile.highlight:SetBlendMode("ADD")

        function tile:SetOn(on)
            self.isOn = on and true or false
            PaintIconToggleTile(self, self:IsMouseOver())
        end
        function tile:Repaint()
            PaintIconToggleTile(self, self:IsMouseOver())
        end
        tile:SetScript("OnEnter", function(self) PaintIconToggleTile(self, true) end)
        tile:SetScript("OnLeave", function(self) PaintIconToggleTile(self, false) end)
        tile.isOn = true
        PaintIconToggleTile(tile, false)
        WrapNotify(tile, "OnClick", "toggle")
        return tile
    end

    -- Themed CheckButton wrapped in a container frame. Returns the
    -- CheckButton (not the container); .Text is the label FontString,
    -- .check is the checkmark texture shown/hidden by the wrapped
    -- SetChecked, .parentFrame is the outer container if callers need to
    -- anchor/size the whole row.
    --
    -- Look: 14px flat box (checkbox.background, 1px checkbox.border),
    -- hover swaps to buttons.hoverBackground with a gold ring
    -- (checkbox.hoverBorder), the check glyph is the existing Checkmark
    -- texture vertex-coloured checkbox.checkmark. The label sits 7px
    -- right at 11px and the whole row is clickable: the hit rect is
    -- widened over the label so clicking the words toggles the box.
    -- The checkmark art is gold, so the default colour tints it to the
    -- gold-green tick everyone knows. A Checkmark colour picked in
    -- Appearance > Colours is drawn on a white tick instead, so it shows
    -- as exactly that colour.
    local CHECK_GOLD = "Interface\\AddOns\\Readycheck\\Media\\Checkmark.tga"
    local CHECK_WHITE = "Interface\\AddOns\\Readycheck\\Media\\CheckmarkWhite.tga"
    -- A picked Checkmark colour: a stored one that is not just a copy of
    -- the shipped colour (a profile import copies every default in as an
    -- override, and that copy must keep the gold tick and mark).
    local function PickedCheckmark()
        local cc = RC.db and RC.db.customColors
        local c = cc and cc.checkbox and cc.checkbox.checkmark
        if type(c) ~= "table" then return nil end
        local function Same(d)
            return d and math.abs((c.r or 0) - (d.r or 0)) < 0.005 and math.abs((c.g or 0) - (d.g or 0)) < 0.005
                and math.abs((c.b or 0) - (d.b or 0)) < 0.005
        end
        local d = RC.defaultColors and RC.defaultColors.checkbox and RC.defaultColors.checkbox.checkmark
        -- the shipped colour, or the green one shipped before 2026-11-02
        -- (copied into saves by a profile import), is not a pick
        if Same(d) or Same({ r = 0.45, g = 0.75, b = 0.45 }) then
            return nil
        end
        return c
    end
    function RC.UI:CheckmarkTexture()
        if PickedCheckmark() then return CHECK_WHITE end
        return CHECK_GOLD
    end

    -- The addon's mark (title bars, the main window, the minimap button)
    -- is the same tick: gold as shipped, and in the picked Checkmark
    -- colour when there is one. Returns the texture and its tint.
    local MARK_GOLD = "Interface\\AddOns\\Readycheck\\Media\\Checkmark"
    function RC.UI:MarkLook()
        local c = PickedCheckmark()
        if c then return CHECK_WHITE, c.r or 1, c.g or 1, c.b or 1 end
        return MARK_GOLD, 1, 1, 1
    end
    function RC.UI:PaintMark(tex)
        if not tex then return end
        local path, r, g, b = self:MarkLook()
        tex:SetTexture(path)
        tex:SetVertexColor(r, g, b, 1)
    end

    -- The box: the checkbox fill and its plain ring, ticked or not - only
    -- the tick carries colour (the ZacUI look; Zac 2026-11-02: a box filled
    -- and ringed green read as a solid green block next to the gold UI).
    -- Under the mouse the fill lifts and the ring goes gold.
    local function PaintCheckbox(self, hot)
        -- the /rc window's box: 18 px, a warm dark fill and a white 0.05
        -- edge, both at 0.8 while unticked and not under the mouse; ticked,
        -- the edge goes to the accent at 0.15. The label is white, 0.8
        -- while unticked (1.0 under the mouse). The tick stays the mark.
        -- (2026-11-10, Zac: "literally every menu popup etc needs to match")
        -- on a checkbox anywhere now (_rcLook), at its own size
        if self._rcSet or self._rcLook then
            local on = self:GetChecked() and true or false
            local k = (on or hot) and 1 or S.CB_REST
            self.bg:SetVertexColor(RC.UI:SCol("checkboxBackground", k))
            if on then
                RC.UI:UpdateBorderColor(self.border, RC.UI:SAccent(), S.CB_ACT_BRD_A)
            else
                RC.UI:UpdateBorderColor(self.border, RC:GetColor("settings", "text"), S.CB_BRD_A * k)
            end
            if type(rawget(self, "Text")) == "table" and not self._rcLabelColor then
                self._rcPainting = true
                self.Text:SetTextColor(RC.UI:SCol("text", (on or hot) and 1 or S.CB_REST))
                self._rcPainting = nil
            end
        else
        local fill = hot and GetButtonHoverBG() or GetCheckboxBG()
        self.bg:SetVertexColor(fill.r, fill.g, fill.b, fill.a or 1)
        local ring = hot and GetCheckboxHoverBorder() or GetCheckboxBorder()
        RC.UI:UpdateBorderColor(self.border, ring, 1)
        end
        local tex = RC.UI:CheckmarkTexture()
        if self.check._rcTex ~= tex then
            self.check:SetTexture(tex)
            self.check._rcTex = tex
        end
        -- unpicked: the gold tick art as drawn; picked: the white tick in
        -- exactly the picked colour
        local picked = PickedCheckmark()
        if picked then
            self.check:SetVertexColor(picked.r or 1, picked.g or 1, picked.b or 1, 1)
        else
            self.check:SetVertexColor(1, 1, 1, 1)
        end
    end

    function RC.UI:CreateCheckbox(parent, text, checked)
        local set = RC.UI:InSettings(parent)
        local size = set and S.CHECK or BASE.CHECKBOX_SIZE
        local checkboxFrame = CreateFrame("Frame", nil, parent)
        checkboxFrame:SetSize(size + 200, size)

        local checkbox = CreateFrame("CheckButton", nil, checkboxFrame)
        checkbox:SetSize(size, size)
        checkbox:SetPoint("LEFT")
        checkbox._rcSet = set or nil
        checkbox._rcLook = true

        checkbox.bg = checkbox:CreateTexture(nil, "BACKGROUND")
        checkbox.bg:SetAllPoints()
        checkbox.bg:SetTexture(FLAT)

        checkbox.border = self:CreateSimpleBorder(checkbox)

        checkbox.check = checkbox:CreateTexture(nil, "ARTWORK")
        checkbox.check:SetSize(size - (set and 4 or 6), size - (set and 4 or 6))
        checkbox.check:SetPoint("CENTER")
        PaintCheckbox(checkbox, false)

        local originalSetChecked = checkbox.SetChecked
        checkbox.SetChecked = function(self, value)
            originalSetChecked(self, value)

            if value then
                if self.check then self.check:Show() end
            else
                if self.check then self.check:Hide() end
            end
            if self.bg then PaintCheckbox(self, self:IsMouseOver()) end
        end

        checkbox:SetChecked(checked and true or false)

        -- PostClick runs after the caller's OnClick, so the setting is
        -- already written when the change signal goes out.
        checkbox:SetScript("PostClick", function(self)
            if self.check then
                if self:GetChecked() then self.check:Show() else self.check:Hide() end
            end
            PaintCheckbox(self, self:IsMouseOver())
            NotifySettingChanged("checkbox")
        end)

        checkbox:SetScript("OnEnter", function(self) PaintCheckbox(self, true) end)
        checkbox:SetScript("OnLeave", function(self) PaintCheckbox(self, false) end)
        function checkbox:Repaint()
            PaintCheckbox(self, self:IsMouseOver())
        end

        checkbox.Text = CreateProfessionalFontString(checkboxFrame, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
        local gap = set and 10 or 7
        checkbox.Text:SetPoint("LEFT", checkbox, "RIGHT", gap, 0)
        checkbox.Text:SetText(text)
        local txtNorm = GetButtonTextNormal()
        checkbox.Text:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b, 1)
        do
            PaintCheckbox(checkbox, false)
            -- a page that colours the label itself (a warning, a dimmed
            -- row) keeps its colour
            hooksecurefunc(checkbox.Text, "SetTextColor", function()
                if not checkbox._rcPainting then checkbox._rcLabelColor = true end
            end)
        end

        -- Whole-row click: extend the hit rect rightwards over the label.
        -- Re-measured whenever the label changes so a relabelled row
        -- keeps the right reach.
        local function SyncHitRect()
            local w = checkbox.Text:GetStringWidth() or 0
            checkbox:SetHitRectInsets(0, -(gap + math.max(10, w)), 0, 0)
        end
        SyncHitRect()
        hooksecurefunc(checkbox.Text, "SetText", SyncHitRect)

        checkbox.parentFrame = checkboxFrame
        checkboxFrame.checkbox = checkbox

        return checkbox
    end

    -- CreateCheckbox pre-anchored to a settings card's TOPLEFT at (14, y),
    -- the card's control x on the ZacUI grid.
    function RC.UI:CreateSettingCheckbox(card, y, label, initial, onClick)
        local cb = self:CreateCheckbox(card, label, initial)
        cb:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
        if onClick then cb:SetScript("OnClick", onClick) end
        return cb
    end

    -- One line of a colour list (Appearance > Colors):
    --   [22x14 swatch, 1px black ring] [label 11px] ... [#RRGGBB 10px gray] [gold dot] [Reset]
    -- 24 tall; the caller anchors LEFT/RIGHT. Row-list look from the
    -- restyle spec: alternate-row white 0.03 stripe, hover
    -- buttons.hoverBackground with a gold label, selected (editor open)
    -- buttons.configuredBackground. The dot and the Reset link only show
    -- while the colour differs from its default.
    --
    -- Built to be POOLED: frames are never garbage-collected in WoW and
    -- the colours page lists ~150 of these and rebuilds on every edit, so
    -- create a row once and re-target it with row:SetData(...) per use.
    -- Callbacks are plain fields read at click time (row.onClick(row),
    -- row.onReset(row), row.tooltipFn(row, GameTooltip)) so a reused row
    -- needs no re-wiring. row.colorTex is the swatch fill, kept under
    -- that name because the Blizzard-picker bridge paints it directly.
    --   row:SetData(label, hex, color, changed)  label text, hex string,
    --                                            swatch colour, dot/Reset
    --   row:SetStripe(on)                        alternate-row stripe
    --   row:SetSelected(on)                      editor-open look
    --   row:Repaint()                            re-read theme colours
    local function PaintColorRow(row, hot)
        local sel = row.isSelected
        -- the /rc window's swatch row: a 22 px swatch with a white edge,
        -- the name in white (the accent under the mouse or open), the hex
        -- white 0.53; the row lifts white 0.06 under the mouse
        if row._rcSet then
            if sel then row.bg:SetVertexColor(RC.UI:SCol("buttonBackground", S.BTN_BG_HA))
            elseif hot then row.bg:SetVertexColor(RC.UI:SCol("text", S.NAV_HL))
            elseif row.isStriped then row.bg:SetVertexColor(RC.UI:SCol("text", 0.03))
            else row.bg:SetVertexColor(1, 1, 1, 0) end
            local A = RC.UI:SAccent()
            if sel or hot then row.label:SetTextColor(A.r, A.g, A.b, 1) else row.label:SetTextColor(RC.UI:SCol("text", 1)) end
            row.hex:SetTextColor(RC.UI:SCol("text", S.DIM_A))
            row.dot:SetVertexColor(A.r, A.g, A.b, 1)
            row.swatch.ring:SetVertexColor(RC.UI:SCol("text", 1))
            return
        end
        local fill
        if sel then
            fill = GetButtonConfiguredBG()
            row.bg:SetVertexColor(fill.r, fill.g, fill.b, 1)
        elseif hot then
            fill = GetButtonHoverBG()
            row.bg:SetVertexColor(fill.r, fill.g, fill.b, 1)
        elseif row.isStriped then
            row.bg:SetVertexColor(1, 1, 1, 0.03)
        else
            row.bg:SetVertexColor(1, 1, 1, 0)
        end
        local lc = (sel or hot) and GetAccentGold() or GetTextNormal()
        row.label:SetTextColor(lc.r, lc.g, lc.b, 1)
        local gray = GetTextGray()
        row.hex:SetTextColor(gray.r, gray.g, gray.b, 1)
        local gold = GetAccentGold()
        row.dot:SetVertexColor(gold.r, gold.g, gold.b, 1)
        local ring = GetBorderNormal()
        row.swatch.ring:SetVertexColor(ring.r, ring.g, ring.b, 1)
    end

    function RC.UI:CreateColorRow(parent)
        local row = CreateFrame("Button", nil, parent)
        row:SetHeight(24)
        row:RegisterForClicks("LeftButtonUp")
        row:EnableMouse(true)

        row.bg = row:CreateTexture(nil, "BACKGROUND")
        row.bg:SetAllPoints()
        row.bg:SetTexture(FLAT)

        -- Swatch: a black ring with the colour inset 1px, so a dark or
        -- see-through colour still reads as a box. It is its own Button
        -- only so the tooltip can anchor to it; hover and clicks are
        -- forwarded to the row.
        local swatch = CreateFrame("Button", nil, row)
        row._rcSet = RC.UI:InSettings(parent) or nil
        swatch:SetSize(22, row._rcSet and 22 or 14)
        swatch:SetPoint("LEFT", row, "LEFT", 6, 0)
        swatch:RegisterForClicks("LeftButtonUp")
        swatch.ring = swatch:CreateTexture(nil, "BACKGROUND")
        swatch.ring:SetAllPoints()
        swatch.ring:SetTexture(FLAT)
        swatch.tex = swatch:CreateTexture(nil, "ARTWORK")
        swatch.tex:SetPoint("TOPLEFT", swatch, "TOPLEFT", 1, -1)
        swatch.tex:SetPoint("BOTTOMRIGHT", swatch, "BOTTOMRIGHT", -1, 1)
        swatch.tex:SetColorTexture(1, 1, 1, 1)
        row.swatch = swatch
        row.colorTex = swatch.tex

        row.resetLink = self:CreateLinkButton(row, RCL["Reset"], 10)
        row.resetLink:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row.resetLink:SetScript("OnClick", function()
            if row.onReset then row.onReset(row) end
        end)

        row.dot = row:CreateTexture(nil, "ARTWORK")
        row.dot:SetSize(6, 6)
        row.dot:SetPoint("RIGHT", row.resetLink, "LEFT", -4, 0)
        row.dot:SetTexture(FLAT)

        row.hex = CreateProfessionalFontString(row, "OVERLAY", 10, "OUTLINE")
        row.hex:SetPoint("RIGHT", row.dot, "LEFT", -8, 0)
        row.hex:SetJustifyH("RIGHT")

        row.label = CreateProfessionalFontString(row, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
        row.label:SetPoint("LEFT", swatch, "RIGHT", 8, 0)
        row.label:SetPoint("RIGHT", row.hex, "LEFT", -8, 0)
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        -- a long name in a narrow row is cut short on purpose: the row's
        -- own tooltip (tooltipFn) always names it in full
        row.label._rcTruncTip = true

        local function Enter()
            PaintColorRow(row, true)
            if row.tooltipFn then
                GameTooltip:SetOwner(swatch, "ANCHOR_TOP")
                row.tooltipFn(row, GameTooltip)
                GameTooltip:Show()
            end
        end
        local function Leave()
            PaintColorRow(row, false)
            GameTooltip:Hide()
        end
        row:SetScript("OnEnter", Enter)
        row:SetScript("OnLeave", Leave)
        row:SetScript("OnClick", function()
            if row.onClick then row.onClick(row) end
        end)
        -- Child buttons steal the pointer from the row; keep the row lit
        -- and forward the swatch click so the whole line is one target.
        swatch:SetScript("OnEnter", Enter)
        swatch:SetScript("OnLeave", Leave)
        swatch:SetScript("OnClick", function()
            if row.onClick then row.onClick(row) end
        end)
        row.resetLink:HookScript("OnEnter", function() PaintColorRow(row, true) end)
        row.resetLink:HookScript("OnLeave", function() PaintColorRow(row, false) end)

        function row:SetData(label, hex, color, changed)
            self.label:SetText(label or "")
            self.hex:SetText(hex or "")
            if color then
                self.colorTex:SetColorTexture(color.r or 1, color.g or 1, color.b or 1, color.a or 1)
            end
            if changed then
                self.dot:Show()
                self.resetLink:Show()
            else
                self.dot:Hide()
                self.resetLink:Hide()
            end
        end
        function row:SetStripe(on)
            self.isStriped = on and true or false
            PaintColorRow(self, self:IsMouseOver())
        end
        function row:SetSelected(on)
            self.isSelected = on and true or false
            PaintColorRow(self, self:IsMouseOver())
        end
        function row:Repaint()
            PaintColorRow(self, self:IsMouseOver())
        end

        PaintColorRow(row, false)
        return row
    end

    ------------------------------------------------------------------
    -- HEADER ART
    -- The look every Readycheck title bar wears, applied to a bar frame of
    -- ANY height: a fill that runs from the header colour into a dark
    -- wash of the accent, and a 2px accent rule along the bottom that is
    -- raised under the title block, drops through a short diagonal and
    -- runs flat to the right edge. The fill is cut off at the rule - the
    -- strip under the raised part is painted in the colour of whatever
    -- sits below it (the sidebar on the settings window, the window
    -- itself elsewhere) and the wedge under the diagonal in the window
    -- colour - so the gradient never shows below the line.
    --   RC.UI:ApplyHeaderArt(bar, { stepX=, stepY=, leftColor=fn })
    --   bar:RepaintArt() re-reads the theme (called by the theme refresh).
    -- The bar's own background texture, if it has one (bar.bg / bar.fill /
    -- .titleFill), is turned into the gradient; otherwise one is made.
    ------------------------------------------------------------------
    local HERO_H = 38
    RC.UI.HERO_H = HERO_H

    local function Mix(a, b, t)
        return a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t
    end

    function RC.UI:ApplyHeaderArt(bar, opts)
        opts = opts or {}
        -- compact = true: the small on-screen pieces (trackers, the TTK
        -- display, toasts). The gradient and the stepped rule suit a window's
        -- title bar but look busy on a strip a few icons wide (2026-10-23,
        -- Zac: "looks good for the ui not so much for the smaller ui
        -- elements"), so these get a flat bar in the header colour with one
        -- straight 1px rule under it. Same _art / RepaintArt shape, so the
        -- callers' theme refresh and show/hide code work unchanged (cutL and
        -- cutD are a texture with no anchors: never drawn).
        if opts.compact then
            local fill = opts.fill or bar.fill or bar.bg or bar.titleFill
            if not fill then
                fill = bar:CreateTexture(nil, "BACKGROUND")
                fill:SetAllPoints()
            end
            fill:SetTexture(FLAT)
            local rule = bar:CreateTexture(nil, "ARTWORK", nil, 4)
            rule:SetTexture(FLAT)
            rule:SetHeight(1)
            rule:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
            rule:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
            local none = bar:CreateTexture(nil, "BACKGROUND")
            bar._art = { fill = fill, cutL = none, cutD = none, rules = { rule }, compact = true }
            function bar:RepaintArt()
                local art = self._art
                local h = _uif.GetHeaderBG()
                art.fill:SetVertexColor(h.r, h.g, h.b, h.a or 1)
                local ru = (RC.GetColor and RC:GetColor("ui", "headerAccent")) or GetAccentGold()
                for _, t in ipairs(art.rules) do t:SetVertexColor(ru.r, ru.g, ru.b, ru.a or 0.6) end
            end
            bar:RepaintArt()
            return bar
        end
        local STEP_Y, STEP_W = opts.stepY or 4, 10
        local stepX = opts.stepX or 150
        local fill = opts.fill or bar.fill or bar.bg or bar.titleFill
        if not fill then
            fill = bar:CreateTexture(nil, "BACKGROUND")
            fill:SetAllPoints()
            fill:SetTexture(FLAT)
        end
        local function Tex(layer, sub)
            local t = bar:CreateTexture(nil, layer or "ARTWORK", nil, sub or 4)
            t:SetTexture(FLAT)
            return t
        end
        local cutL = Tex("BACKGROUND", 1)
        cutL:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
        cutL:SetPoint("TOPRIGHT", bar, "BOTTOMLEFT", stepX, STEP_Y)
        local cutD = Tex("BACKGROUND", 1)
        cutD:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", stepX, 0)
        cutD:SetPoint("TOPRIGHT", bar, "BOTTOMLEFT", stepX + STEP_W, STEP_Y)
        -- a quad with its top-right corner pulled down onto the
        -- bottom-right is the triangle under the diagonal
        if cutD.SetVertexOffset then cutD:SetVertexOffset(3, 0, -STEP_Y) end
        -- 1px, like every other rule in the UI
        local ruleL, ruleR, ruleD = Tex(), Tex(), Tex()
        ruleL:SetHeight(1)
        ruleL:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, STEP_Y)
        ruleL:SetPoint("BOTTOMRIGHT", bar, "BOTTOMLEFT", stepX, STEP_Y)
        ruleR:SetHeight(1)
        ruleR:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", stepX + STEP_W, 0)
        ruleR:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
        ruleD:SetHeight(1)
        ruleD:SetWidth(math.sqrt(STEP_W * STEP_W + STEP_Y * STEP_Y) + 1)
        ruleD:SetPoint("CENTER", bar, "BOTTOMLEFT", stepX + STEP_W / 2, STEP_Y / 2 + 0.5)
        ruleD:SetRotation(-math.atan2(STEP_Y, STEP_W))
        bar._art = { fill = fill, cutL = cutL, cutD = cutD, rules = { ruleL, ruleR, ruleD },
                     leftColor = opts.leftColor }

        function bar:RepaintArt()
            local art = self._art
            local h = _uif.GetHeaderBG()
            local a = GetAccentGold()
            -- the gradient's far end: the user's colour when they set one
            -- (Appearance > Colours, "Title Bar Gradient"), otherwise
            -- derived from the title bar BG and the accent
            local r2, g2, b2
            local own = RC.db and RC.db.customColors and RC.db.customColors.ui and RC.db.customColors.ui.headerGradient
            if own then r2, g2, b2 = own.r, own.g, own.b else r2, g2, b2 = Mix(h, a, 0.4) end
            local f = art.fill
            if CreateColor and f.SetGradient then
                f:SetVertexColor(1, 1, 1, 1)
                f:SetGradient("HORIZONTAL", CreateColor(h.r, h.g, h.b, h.a or 1), CreateColor(r2, g2, b2, h.a or 1))
            elseif f.SetGradientAlpha then
                f:SetVertexColor(1, 1, 1, 1)
                f:SetGradientAlpha("HORIZONTAL", h.r, h.g, h.b, h.a or 1, r2, g2, b2, h.a or 1)
            else
                f:SetVertexColor(h.r, h.g, h.b, h.a or 1)
            end
            -- the rule is the theme's "Header Underline" colour, alpha and all
            local ru = (RC.GetColor and RC:GetColor("ui", "headerAccent")) or a
            for _, t in ipairs(art.rules) do t:SetVertexColor(ru.r, ru.g, ru.b, ru.a or 0.6) end
            local w = _uif.GetWindowBG()
            local l = art.leftColor and art.leftColor() or w
            art.cutL:SetVertexColor(l.r, l.g, l.b, 1)
            art.cutD:SetVertexColor(w.r, w.g, w.b, 1)
        end
        bar:RepaintArt()
        -- every bar that wears this art gets the opening sheen; a header
        -- with a mark hands it to RC.UI:AnimateMark (both further down)
        if opts.anim ~= false and self.AnimateBar then self:AnimateBar(bar, { inset = STEP_Y + 1 }) end
        -- a pop-up's title icon (RC.UI:AddTitleIcon) put there before the
        -- art: the opening and the hover, no idle loops
        if opts.anim ~= false and bar.titleIcon and self.AnimateMark then
            self:AnimateMark(bar.titleIcon, bar, { idle = false, lead = 0.12 })
        end
        return bar
    end

    ------------------------------------------------------------------
    -- THE LIVING MARK
    -- The addon mark in the main window's title bar is animated, all of
    -- it with AnimationGroups - nothing runs in Lua per frame, no ticker,
    -- and nothing plays while the window is closed.
    --   OPENING  once the window is really on screen the mark drops in
    --            from double size; as it lands it does what it does on
    --            hover (the turn, the ring, the four-point flare) and a
    --            slanted sheen sweeps the bar
    --   IDLE     every few seconds a small twinkle pops somewhere on the
    --            mark (a different spot, size and wait each time), and
    --            now and then the sheen crosses the bar again
    --   HOVER    the mark makes one full turn, with the ring and the flare
    --
    --   RC.UI:AnimateMark(icon, bar, { inset = n, lead = s })
    --   icon: the mark's texture, already placed on `bar`.
    --   inset: pixels of the bar's bottom edge the sheen stays clear of.
    --   lead: seconds the drop waits once frames are flowing - the length
    --         of the window's own fade-in, if it has one.
    --   idle: false = the opening and the hover only; the sparkle and the
    --         returning sheen are left to the main window.
    --
    -- The scripts sit on a frame of this function's own, never on the
    -- window: a window's OnShow belongs to whoever builds the window, and
    -- a later SetScript there would silently drop a hook put on it here.
    -- A child frame gets OnShow when its window appears.
    ------------------------------------------------------------------
    local MARK_FLARE = "Interface\\AddOns\\Readycheck\\Media\\markFlare"
    local MARK_RING  = "Interface\\AddOns\\Readycheck\\Media\\markRing"
    local SHEEN_W, SHEEN_SLANT = 70, 14

    -- HOW STRONG AND HOW OFTEN. One place to turn the whole thing up or down.
    -- Every header gets the whole show every time it opens - main window or
    -- pop-up, however soon after the last time. What must never happen is any
    -- of it being left lit: see Light() and Sweep().
    local FX = {
        sheen    = 0.26,    -- the band of light across the bar, at its brightest
        -- The light behind the mark is a burst: it comes up to these and fades
        -- out over half a second. Nothing is lit behind the mark at rest.
        flareIn  = 0.45,    -- as the mark lands: the four-point flare
        ringIn   = 0.55,    --   ...and the ring
        flareHit = 0.36,    -- under the mouse
        ringHit  = 0.46,
        spark    = 0.70,    -- the twinkle, on every header that has a mark
        -- THE BACKLIGHT: the ring and the four-point flare that sit behind the
        -- mark for as long as the window is open. Not a fixed glow - each
        -- breathes slowly between its two values, one way in `breath` seconds.
        ringRest  = { 0.50, 0.85 },
        flareRest = { 0.30, 0.60 },
        breath    = 2.4,
        pop      = 1,       -- a pop-up's share of the above (1 = same as a main window)
        lap      = 14,      -- seconds between returns of the sheen on a main window
        hitch    = 0.09,    -- a frame longer than this many seconds is a stall
        calm     = 3,       -- ordinary frames in a row before anything starts...
        wait     = 1.5,     -- ...but it starts anyway after this many seconds
    }

    -- Runs `go` once frames are flowing: FX.calm ordinary frames in a row.
    -- The frame a window is shown in is a long one, and an auction house or a
    -- mailbox opening behind a pop-up is several; anything started then has
    -- run its course before it is drawn, or stands still half-way. `host` is
    -- a frame of the caller's own - its OnUpdate is used and then taken off.
    -- Frames that will not settle only delay it: after FX.wait seconds it
    -- goes anyway. The show is never skipped.
    local function WhenCalm(host, go)
        local calm, waited, ticks = 0, 0, 0
        host:SetScript("OnUpdate", function(self, dt)
            ticks = ticks + 1
            if ticks < 2 then return end      -- the first tick carries the show itself
            waited = waited + dt
            if dt <= FX.hitch then calm = calm + 1 else calm = 0 end
            if calm >= FX.calm or waited >= FX.wait or ticks >= 240 then
                self:SetScript("OnUpdate", nil)
                go()
            end
        end)
    end

    local function AnimScale(group, order, from, to, dur, smooth, delay)
        local a = group:CreateAnimation("Scale")
        a:SetOrder(order)
        -- the setters were renamed between client generations
        if a.SetScaleFrom then a:SetScaleFrom(from, from) a:SetScaleTo(to, to)
        elseif a.SetFromScale then a:SetFromScale(from, from) a:SetToScale(to, to)
        else a:SetScale(to / from, to / from) end
        a:SetDuration(dur)
        if smooth then a:SetSmoothing(smooth) end
        if delay then a:SetStartDelay(delay) end
        return a
    end
    local function AnimAlpha(group, order, from, to, dur, smooth, delay)
        local a = group:CreateAnimation("Alpha")
        a:SetOrder(order)
        a:SetFromAlpha(from) a:SetToAlpha(to)
        a:SetDuration(dur)
        if smooth then a:SetSmoothing(smooth) end
        if delay then a:SetStartDelay(delay) end
        return a
    end
    local function AnimTurn(group, order, degrees, dur, smooth, delay)
        local a = group:CreateAnimation("Rotation")
        a:SetOrder(order)
        a:SetDegrees(degrees)
        a:SetDuration(dur)
        if smooth then a:SetSmoothing(smooth) end
        if delay then a:SetStartDelay(delay) end
        return a
    end

    -- THE SHEEN, on its own: a soft slanted band of light that crosses a bar.
    -- One per bar, made on first ask and shared by whoever animates that bar.
    -- It is a frame inside a clipping frame the size of the bar, so it shows
    -- only while it is over the bar.
    local function Sheen(bar, inset)
        if bar._rcSheen then return bar._rcSheen end
        local clip = CreateFrame("Frame", nil, bar)
        clip:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
        clip:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, inset or 6)
        clip:SetFrameLevel(bar:GetFrameLevel() + 6)
        if clip.SetClipsChildren then clip:SetClipsChildren(true) end
        local band = CreateFrame("Frame", nil, clip)
        band:SetPoint("TOPLEFT", clip, "TOPLEFT", -(SHEEN_W + SHEEN_SLANT), 0)
        band:SetPoint("BOTTOMLEFT", clip, "BOTTOMLEFT", -(SHEEN_W + SHEEN_SLANT), 0)
        band:SetWidth(SHEEN_W)
        band:SetAlpha(0)
        -- at rest it waits off the bar's left end, clipped; hidden as well,
        -- so nothing measures or walks a band that is not sweeping
        band:Hide()
        local halves = {}
        local function Half(fromA, toA, p1, p2)
            local t = band:CreateTexture(nil, "OVERLAY")
            t:SetTexture(FLAT)
            t:SetBlendMode("ADD")
            t:SetPoint("TOPLEFT", band, p1, 0, 0)
            t:SetPoint("BOTTOMRIGHT", band, p2, 0, 0)
            -- lean it: both top corners pushed right
            if t.SetVertexOffset then
                t:SetVertexOffset(1, SHEEN_SLANT, 0)
                t:SetVertexOffset(3, SHEEN_SLANT, 0)
            end
            halves[#halves + 1] = { tex = t, from = fromA, to = toA }
        end
        Half(0, 1, "TOPLEFT", "BOTTOM")
        Half(1, 0, "TOP", "BOTTOMRIGHT")
        -- 1 on a main window, FX.pop on a pop-up (SetLevel, below)
        local level = 1

        -- ONE group with ONE animation on the band: the slide. The band is
        -- switched on for the length of a sweep and off again after it; its
        -- alpha is never animated, nothing else ever plays on it, and a sweep
        -- is never started from inside another animation's callback. (The
        -- first build ran an entrance group and a looping idle group on the
        -- band at once, each with an alpha step, and the sweep on opening
        -- came and went with whichever the client applied last.)
        local sweep = band:CreateAnimationGroup()
        local slide = sweep:CreateAnimation("Translation")
        slide:SetOrder(1) slide:SetDuration(0.8) slide:SetSmoothing("IN_OUT")
        -- `turn` counts sweeps, so the watchdog in Sweep only ever acts on
        -- the sweep that set it
        local turn = 0
        local function Off()
            turn = turn + 1
            band:SetAlpha(0)
            band:SetScript("OnUpdate", nil)
            band:Hide()
        end
        sweep:SetScript("OnFinished", Off)
        sweep:SetScript("OnStop", Off)

        -- the band travels the bar's width, whatever that is right now
        local function Span()
            local w = bar:GetWidth()
            if not w or w < 50 then w = 600 end
            slide:SetOffset(w + SHEEN_W + SHEEN_SLANT * 2, 0)
        end
        clip:SetScript("OnSizeChanged", Span)

        -- the light's colour, re-read on every sweep so a palette change shows
        local function Tint()
            local w = (RC.GetColor and RC:GetColor("text", "white")) or GetAccentGold()
            local k = FX.sheen * level
            for _, h in ipairs(halves) do
                if CreateColor and h.tex.SetGradient then
                    h.tex:SetGradient("HORIZONTAL", CreateColor(w.r, w.g, w.b, h.from * k), CreateColor(w.r, w.g, w.b, h.to * k))
                else
                    h.tex:SetVertexColor(w.r, w.g, w.b, k * 0.5)
                end
            end
        end
        Tint()

        -- A sweep is 0.8s of smooth motion or it is nothing. A stalled frame
        -- in the middle of one (something heavy loading behind the window)
        -- leaves the band standing still on the bar - so while it is lit the
        -- band watches its own frames and goes dark on the first long one,
        -- and whatever else happens it is dark a moment after a sweep should
        -- have ended.
        local function Sweep()
            Tint()
            Span()
            sweep:Stop()
            Off()
            local mine, ticks = turn, 0
            band:Show()
            band:SetAlpha(1)
            band:SetScript("OnUpdate", function(_, dt)
                ticks = ticks + 1
                if ticks > 1 and dt > FX.hitch then
                    sweep:Stop()
                    Off()
                end
            end)
            sweep:Play()
            C_Timer.After(1.3, function()
                if turn == mine then
                    sweep:Stop()
                    Off()
                end
            end)
        end

        -- THE RETURN, for a main window: a clock on the clipping frame (an
        -- alpha step from 1 to 1 - nothing to see) that sweeps on every lap.
        local clock = clip:CreateAnimationGroup()
        clock:SetLooping("REPEAT")
        local lap = clock:CreateAnimation("Alpha")
        lap:SetFromAlpha(1) lap:SetToAlpha(1) lap:SetDuration(FX.lap)
        clock:SetScript("OnLoop", function() Sweep() end)

        local s = { clip = clip, band = band, sweep = sweep, clock = clock, Span = Span, Tint = Tint, Sweep = Sweep }
        function s.StartIdle() clock:Stop() clock:Play() end
        function s.SetLevel(k) level = k end
        function s.Stop()
            clock:Stop()
            sweep:Stop()
            Off()
        end
        bar._rcSheen = s
        return s
    end

    -- THE OPENING SHEEN FOR ANY BAR. Every window and dialog that wears the
    -- header art gets this (the header-art helper calls it): when the window
    -- appears, the sheen crosses its title bar once. No idle loop - that is
    -- for the main window - and nothing plays while the window is closed.
    -- A header that also has a mark hands its sheen to AnimateMark, which
    -- times it to the mark's landing; `auto` goes false and this stands down.
    -- Like the mark, it waits for the first ordinary frame: the frame a
    -- window is shown in is a long one and would swallow the sweep.
    function RC.UI:AnimateBar(bar, opts)
        if not (bar and bar.CreateTexture) then return end
        opts = opts or {}
        local sheen = Sheen(bar, opts.inset)
        if sheen.wired then return sheen end
        sheen.wired = true
        if sheen.auto == nil then sheen.auto = true end
        sheen.SetLevel(FX.pop)      -- a bar on its own is a pop-up's
        local clip = sheen.clip
        local function Stop()
            clip:SetScript("OnUpdate", nil)
            sheen.Stop()
        end
        local function Play()
            if not sheen.auto then return end
            Stop()
            WhenCalm(clip, function()
                if sheen.auto then sheen.Sweep() end
            end)
        end
        clip:SetScript("OnShow", Play)
        clip:SetScript("OnHide", function() if sheen.auto then Stop() end end)
        if clip:IsVisible() then Play() end
        return sheen
    end

    -- THE FLIP: the mark turns over on its upright axis and back again,
    -- like a coin - over to its mirror image, a beat there, then home. A
    -- copy of the mark does the turning (its width follows the cosine of
    -- the turn, mirrored for the back half) while the mark itself is held
    -- unseen, so nothing anchored to the mark moves and its own coords and
    -- size are never touched. Returns an object with Play / Stop /
    -- IsPlaying, like an animation group. The OnUpdate only runs while it
    -- flips.
    function RC.UI:CreateMarkFlip(icon, duration)
        if not (icon and icon.GetParent and icon:GetParent()) then return nil end
        local DUR = duration or 0.8
        local parent = icon:GetParent()
        local copy = parent:CreateTexture(nil, "ARTWORK")
        copy:SetPoint("CENTER", icon, "CENTER", 0, 0)
        copy:Hide()
        local driver = CreateFrame("Frame", nil, parent)
        local t, playing, coords, w0, alpha = 0, false, nil, 0, 1
        local flip = {}
        local function Finish()
            driver:SetScript("OnUpdate", nil)
            if not playing then return end
            playing = false
            copy:Hide()
            icon:SetAlpha(alpha)
        end
        local function Step(_, elapsed)
            t = t + elapsed
            if t >= DUR then Finish() return end
            -- 0 -> 180 -> 0 degrees, easing in and out of each turn
            local c = math.cos(math.pi * math.sin(math.pi * t / DUR))
            copy:SetWidth(math.max(0.5, w0 * math.abs(c)))
            local c1, c2, c3, c4, c5, c6, c7, c8 = unpack(coords)
            if c < 0 then
                copy:SetTexCoord(c5, c6, c7, c8, c1, c2, c3, c4)   -- mirrored
            else
                copy:SetTexCoord(c1, c2, c3, c4, c5, c6, c7, c8)
            end
        end
        function flip:Play()
            if playing then return end
            w0 = icon:GetWidth() or 0
            local h = icon:GetHeight() or 0
            if w0 <= 0 or h <= 0 or not icon:GetTexture() then return end
            coords = { icon:GetTexCoord() }
            if #coords ~= 8 then return end
            copy:SetTexture(icon:GetTexture())
            copy:SetSize(w0, h)
            copy:SetVertexColor(icon:GetVertexColor())
            if icon.GetBlendMode then copy:SetBlendMode(icon:GetBlendMode()) end
            if icon.IsDesaturated then copy:SetDesaturated(icon:IsDesaturated()) end
            local layer, sub = icon:GetDrawLayer()
            copy:SetDrawLayer(layer or "ARTWORK", math.min(7, (sub or 0) + 1))
            alpha = icon:GetAlpha()
            if not alpha or alpha <= 0 then alpha = 1 end
            copy:SetAlpha(alpha)
            copy:SetTexCoord(unpack(coords))
            copy:Show()
            icon:SetAlpha(0)
            t, playing = 0, true
            driver:SetScript("OnUpdate", Step)
        end
        function flip:Stop() Finish() end
        function flip:IsPlaying() return playing end
        driver:SetScript("OnHide", Finish)
        return flip
    end

    function RC.UI:AnimateMark(icon, bar, opts)
        if not (icon and bar and icon.CreateAnimationGroup) or icon._rcMark then return end
        opts = opts or {}
        local size = icon:GetWidth()
        if not size or size < 8 then size = 20 end

        -- everything drawn here lives on one frame above the bar's own art
        local fx = CreateFrame("Frame", nil, bar)
        fx:SetAllPoints(icon)
        fx:SetFrameLevel(bar:GetFrameLevel() + 10)
        -- ...and the mark itself moves onto a frame one above that, so the
        -- light is BEHIND the mark and never across it. (It used to be drawn
        -- over the mark, and no amount of turning it down kept the mark clear.)
        local front = CreateFrame("Frame", nil, bar)
        front:SetAllPoints(bar)
        front:SetFrameLevel(bar:GetFrameLevel() + 11)
        icon:SetParent(front)

        local function Glow(tex, scale, point, x, y)
            local t = fx:CreateTexture(nil, "OVERLAY", nil, 7)
            t:SetTexture(tex)
            t:SetBlendMode("ADD")
            t:SetSize(size * scale, size * scale)
            t:SetPoint("CENTER", icon, point or "CENTER", x or 0, y or 0)
            t:SetAlpha(0)
            return t
        end
        -- the backlight (made first, so the bursts draw over it)
        local flareRest = Glow(MARK_FLARE, 3.0)
        local ringRest = Glow(MARK_RING, 1.4)
        -- the bursts
        local flare = Glow(MARK_FLARE, 3.0)
        local ring = Glow(MARK_RING, 1.4)
        local spark = Glow(MARK_FLARE, 1.5, "TOPRIGHT", -2, -2)

        -- one burst = the texture appears at full strength, then grows,
        -- turns and fades together. Every animation in a burst runs the
        -- same length, so none is left holding a finished value.
        -- `peak` is how strong the light is at its brightest - kept low: it
        -- is an accent behind the mark, not a flashbulb. It fades evenly from
        -- the first frame rather than lingering at peak.
        --
        -- LIT ONLY WHILE IT PLAYS. An alpha animation does not leave a texture
        -- at its last value: when it ends the texture is back at its OWN alpha.
        -- So each of these textures is held at 0, raised to 1 by Light() for
        -- the length of one animation, and put back to 0 the moment that
        -- animation ends or is stopped. `lit` remembers which animation holds a
        -- texture, so the end of an older one cannot darken a newer one.
        -- (They used to be left at 1: every burst was followed by the flare and
        -- the ring standing behind the mark at full strength until the window
        -- closed, and on a pop-up the twinkle sat still at the corner. Then
        -- they were held at 0 and never raised, and nothing showed at all.)
        local lit = {}
        local function Dark(tex, g)
            if g and lit[tex] ~= g then return end
            lit[tex] = nil
            tex:SetAlpha(0)
        end
        local function Light(tex, g)
            lit[tex] = g
            tex:SetAlpha(1)
            g:Play()
        end
        local function Burst(tex, peak, fromS, toS, dur, degrees)
            local g = tex:CreateAnimationGroup()
            AnimAlpha(g, 1, peak, 0, dur)
            AnimScale(g, 1, fromS, toS, dur, "OUT")
            if degrees then AnimTurn(g, 1, degrees, dur, "OUT") end
            g:SetScript("OnFinished", function() Dark(tex, g) end)
            g:SetScript("OnStop", function() Dark(tex, g) end)
            return g
        end
        -- the landing bursts (the bigger pair) and the hover bursts
        -- THE BACKLIGHT behind the mark while the window is open: the same
        -- ring and flare, at rest size, breathing. A bounce between two alphas
        -- that never ends, so it is never a still picture and never "over" -
        -- there is no last value for it to be left at. Lit by Light() like the
        -- bursts, dark the moment the window closes.
        local function Breath(tex, range)
            local g = tex:CreateAnimationGroup()
            g:SetLooping("BOUNCE")
            AnimAlpha(g, 1, range[1], range[2], FX.breath, "IN_OUT")
            g:SetScript("OnStop", function() Dark(tex, g) end)
            return g
        end
        local ringBreath = Breath(ringRest, FX.ringRest)
        local flareBreath = Breath(flareRest, FX.flareRest)

        -- strengths from FX; a pop-up's mark gets FX.pop of them
        local K = (opts.idle ~= false) and 1 or FX.pop
        local flareIn  = Burst(flare, FX.flareIn * K,  0.25, 1.25, 0.65, 110)
        local ringIn   = Burst(ring,  FX.ringIn * K,   0.6,  2.8,  0.50)
        local flareHit = Burst(flare, FX.flareHit * K, 0.25, 1.0,  0.50, 90)
        local ringHit  = Burst(ring,  FX.ringHit * K,  0.6,  2.4,  0.45)

        -- the drop: held unseen for the lead (a window that fades in gets a
        -- longer one), then down from double size onto its place. One group,
        -- two steps, so no frame falls between them; the mark's own alpha is
        -- 0 for the whole of it and the landing puts it back.
        local LEAD = opts.lead or 0.04
        -- the idle sparkle and the returning sheen are for a main window; a
        -- pop-up passes idle = false and gets the opening only
        local IDLE = opts.idle ~= false
        local markIn = icon:CreateAnimationGroup()
        AnimAlpha(markIn, 1, 0, 0, LEAD)
        AnimAlpha(markIn, 2, 0, 1, 0.26, "OUT")
        AnimScale(markIn, 2, 2.2, 1, 0.26, "IN")

        -- hover, and the landing: the flip (over and back, like a coin).
        -- It used to be one full turn, and before that a "pop" (grow, then
        -- shrink), which looked wrong in game beside the turn.
        local markHit = self:CreateMarkFlip(icon)
        if not markHit then
            markHit = icon:CreateAnimationGroup()
            AnimTurn(markHit, 1, -360, 0.5, "IN_OUT")
        end

        -- THE IDLE TWINKLE: a wait, then a small burst - and each one somewhere
        -- else. Not a looping group (a loop would twinkle on the same spot at
        -- the same beat for ever): one pass, and its finish picks a new place
        -- on the mark, a new size and a new wait, and plays it again.
        local sparkOn = false
        local sparkIdle = spark:CreateAnimationGroup()
        local sparkWait = AnimAlpha(sparkIdle, 1, 0, 0, 6.5)
        AnimAlpha(sparkIdle, 2, FX.spark, 0, 0.7, "IN")
        AnimScale(sparkIdle, 2, 0.2, 1, 0.7, "OUT")
        AnimTurn(sparkIdle, 2, 90, 0.7, "OUT")
        local function PlaceSpark()
            -- anywhere on the mark from near its middle out to just past its
            -- edge, at any angle
            local angle = math.random() * 2 * math.pi
            local reach = size * (0.15 + math.random() * 0.50)
            local s = size * (1.0 + math.random() * 0.8)
            spark:ClearAllPoints()
            spark:SetPoint("CENTER", icon, "CENTER", math.cos(angle) * reach, math.sin(angle) * reach)
            spark:SetSize(s, s)
            sparkWait:SetDuration(3.5 + math.random() * 5)
        end
        sparkIdle:SetScript("OnFinished", function()
            if not sparkOn then
                Dark(spark, sparkIdle)
                return
            end
            PlaceSpark()
            Light(spark, sparkIdle)
        end)
        sparkIdle:SetScript("OnStop", function() Dark(spark, sparkIdle) end)

        -- the bar's sheen is shared with AnimateBar; from here the mark runs
        -- it, timed to the landing
        local sheen = Sheen(bar, opts.inset)
        sheen.auto = false
        sheen.clip:SetScript("OnUpdate", nil)
        sheen.SetLevel(K)

        -- COLOUR ONLY. A texture's vertex colour carries its alpha, so after
        -- tinting each is put straight back to what Light()/Dark() last said.
        local function Paint(tex, r, g, b)
            tex:SetVertexColor(r, g, b, 1)
            tex:SetAlpha(lit[tex] and 1 or 0)
        end
        -- theme colours, re-read on every play so a palette change shows
        local function Tint()
            local a = GetAccentGold()
            local w = (RC.GetColor and RC:GetColor("text", "white")) or a
            Paint(flare, a.r, a.g, a.b)
            Paint(ring, a.r, a.g, a.b)
            Paint(flareRest, a.r, a.g, a.b)
            Paint(ringRest, a.r, a.g, a.b)
            Paint(spark, w.r, w.g, w.b)
            sheen.Tint()
        end

        -- the twinkle runs on every header that has a mark - main window or
        -- pop-up - for as long as it is open
        local function StartTwinkle()
            if not fx:IsVisible() then return end
            sparkOn = true
            PlaceSpark()
            Light(spark, sparkIdle)
        end

        local groups = { flareIn, ringIn, flareHit, ringHit, markIn, markHit, sparkIdle, ringBreath, flareBreath }
        local waiting, armed, run = false, false, 0
        local function StopAll()
            waiting, armed = false, false
            sparkOn = false
            run = run + 1
            fx:SetScript("OnUpdate", nil)
            for _, g in ipairs(groups) do g:Stop() end
            -- whatever the stops did or did not report, nothing stays lit
            Dark(flare) Dark(ring) Dark(spark) Dark(flareRest) Dark(ringRest)
            sheen.Stop()
            icon:SetAlpha(1)
        end

        -- THE LANDING: exactly what the mouse gets on hover - the turn, with
        -- the ring and the flare - plus the sheen across the bar.
        -- The idle loops start counting from here.
        local function Land()
            if not armed then return end
            armed = false
            icon:SetAlpha(1)
            if not fx:IsVisible() then return end
            markHit:Play()
            Light(ring, ringIn)
            Light(flare, flareIn)
            -- the backlight comes up under the burst and stays
            Light(ringRest, ringBreath)
            Light(flareRest, flareBreath)
            StartTwinkle()
            -- the sheen goes a beat later, and from a timer rather than
            -- from inside the drop's own finish callback
            local mine = run
            C_Timer.After(0.05, function()
                if run ~= mine or not fx:IsVisible() then return end
                sheen.Sweep()
                if IDLE then sheen.StartIdle() end
            end)
        end
        markIn:SetScript("OnFinished", Land)

        -- THE OPENING. It must not start the moment the window is shown. The
        -- frame a window is built or shown in is a long one, the next frame's
        -- clock carries that whole pause, and an animation started here has
        -- run its course before anything is drawn. So the mark is held unseen
        -- and the drop waits for the first ordinary frame: a few frames of
        -- OnUpdate, then the script takes itself off.
        local function PlayIn()
            StopAll()
            Tint()
            icon:SetAlpha(0)
            waiting = true
            local mine = run
            WhenCalm(fx, function()
                waiting = false
                armed = true
                markIn:Play()
                -- the mark must never be left unseen: if the drop's finish
                -- does not arrive, land anyway
                C_Timer.After(LEAD + 1, function()
                    if run == mine and armed then Land() end
                end)
            end)
        end
        local function PlayHit()
            if waiting or armed or markHit:IsPlaying() or markIn:IsPlaying() then return end
            flareIn:Stop() ringIn:Stop() flareHit:Stop() ringHit:Stop()
            Tint()
            markHit:Play()
            Light(ring, ringHit)
            Light(flare, flareHit)
        end

        fx:SetScript("OnShow", PlayIn)
        fx:SetScript("OnHide", StopAll)
        fx:SetScript("OnEnter", PlayHit)
        -- the mark listens for the mouse crossing it and lets clicks
        -- through, so dragging the bar from the mark is the bar's own drag
        if fx.SetMouseMotionEnabled and fx.SetMouseClickEnabled then
            fx:SetMouseMotionEnabled(true)
            fx:SetMouseClickEnabled(false)
        else
            fx:EnableMouse(true)
            fx:RegisterForDrag("LeftButton")
            fx:SetScript("OnDragStart", function()
                local h = bar:GetScript("OnDragStart")
                if h then h(bar) end
            end)
            fx:SetScript("OnDragStop", function()
                local h = bar:GetScript("OnDragStop")
                if h then h(bar) end
            end)
        end

        icon._rcMark = { PlayIn = PlayIn, PlayHit = PlayHit, StopAll = StopAll, fx = fx }
        -- a window built already on screen never fires OnShow for this
        if fx:IsVisible() then PlayIn() end
        return icon._rcMark
    end

    ------------------------------------------------------------------
    -- HERO HEADER
    -- The title bar for the MAIN window: the header art at 38px, the
    -- addon icon, the name in two tones (second word in the accent), the
    -- subtitle in grey on the same line, and the plain X. One line: the
    -- two-line 54px version read as a banner, not a title bar.
    --   RC.UI:CreateHeroHeader(parent, { first=, second=, subtitle=, icon=,
    --                                    stepX=, leftColor=fn, onClose= })
    -- Returns the bar; bar.icon, bar.first, bar.second, bar.subtitle,
    -- bar.closeButton, bar:Repaint() for the theme refresh.
    ------------------------------------------------------------------
    function RC.UI:CreateHeroHeader(parent, opts)
        opts = opts or {}
        local bar = CreateFrame("Frame", nil, parent)
        bar:SetHeight(HERO_H)
        bar:SetPoint("TOPLEFT", parent, "TOPLEFT", 1, -1)
        bar:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -1, -1)
        self:ApplyHeaderArt(bar, { stepX = opts.stepX or 250, stepY = 5, leftColor = opts.leftColor })

        local icon = bar:CreateTexture(nil, "ARTWORK", nil, 3)
        icon:SetSize(20, 20)
        icon:SetPoint("LEFT", bar, "LEFT", 12, 2)
        icon:SetTexture(opts.icon or "Interface\\AddOns\\Readycheck\\Media\\Checkmark")
        if not opts.icon then self:PaintMark(icon) end
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        bar.icon = icon
        -- the mark is alive: drops in when the window opens, sparkles
        -- while it is up, turns under the mouse
        -- lead: the window fades in over 0.18s (RC.UI:PopIn)
        self:AnimateMark(icon, bar, { inset = 6, lead = 0.16 })

        local first = CreateProfessionalFontString(bar, "OVERLAY", BASE.FONT_SIZE_LARGE, "OUTLINE")
        first:SetPoint("LEFT", icon, "RIGHT", 8, 1)
        first:SetText(opts.first or "")
        local second = CreateProfessionalFontString(bar, "OVERLAY", BASE.FONT_SIZE_LARGE, "OUTLINE")
        second:SetPoint("LEFT", first, "RIGHT", -1, 0)
        second:SetText(opts.second or "")
        -- the subtitle (the version) hugs the name on the same line, a
        -- step down to share a baseline
        local subtitle = CreateProfessionalFontString(bar, "OVERLAY", BASE.FONT_SIZE_TINY, "OUTLINE")
        subtitle:SetPoint("LEFT", second, "RIGHT", 4, -2)
        subtitle:SetJustifyH("LEFT")
        subtitle:SetWordWrap(false)
        subtitle:SetText(opts.subtitle or "")
        bar.first, bar.second, bar.subtitle = first, second, subtitle

        local close = RC.UI:CreateXCloseButton(bar, 20, opts.onClose)
        close:SetPoint("RIGHT", bar, "RIGHT", -8, 1)
        -- a long subtitle stops short of the X instead of running under it
        subtitle:SetPoint("RIGHT", close, "LEFT", -8, 0)
        bar.closeButton = close

        function bar:Repaint()
            self:RepaintArt()
            local a = GetAccentGold()
            local ht = _uif.GetHeaderText()
            self.first:SetTextColor(ht.r, ht.g, ht.b, 1)
            self.second:SetTextColor(a.r, a.g, a.b, 1)
            local g = GetTextGray()
            self.subtitle:SetTextColor(g.r, g.g, g.b, 1)
        end
        bar:Repaint()
        return bar
    end

    ------------------------------------------------------------------
    -- READY ICON
    -- The dress for an ability icon that is asking to be used - the
    -- reminder popup's icons. Inside out: the spell art (8% crop), a 1px
    -- ring in the "Reminder Icon Border" colour on the edge, a 1px black
    -- plate just outside it so the icon keeps its shape over anything
    -- behind it, and a soft halo in the "Reminder Icon Glow" colour
    -- around the lot (the client's own IconAlert glow, ADD-blended) that
    -- breathes by an AnimationGroup - no Lua runs per frame. Nothing is
    -- drawn over the art itself; the old flat green wash tinted every
    -- icon the same.
    -- db.iconBorder picks how much edge: "thick" (ring + plate), "thin"
    -- (ring only) or "none"; db.iconGlowScale is the halo's size as a
    -- multiple of the icon (default 1.5). A border colour that was never set follows
    -- a glow colour that was, so looks saved before the two were split
    -- keep their one colour on both.
    --   RC.UI:DressReadyIcon(icon, size)     creates once, resizes after
    --   RC.UI:SetReadyIconGlow(icon, mode)   "pulse" | "static" | "off"
    --   RC.UI:RepaintReadyIcon(icon)         re-reads colours and border
    -- icon.texture must already exist. Sets icon.plate/ring/halo/haloPulse.
    ------------------------------------------------------------------
    local HALO_TEX = "Interface\\SpellActivationOverlay\\IconAlert"
    local HALO_L, HALO_R, HALO_T, HALO_B = 0.00781250, 0.50781250, 0.27734375, 0.52734375
    local HALO_SCALE = 1.5

    local function ReadyBorderColor()
        local cc = RC.db and RC.db.customColors and RC.db.customColors.ui
        if cc and not cc.readyBorder and cc.readyGlow then return cc.readyGlow end
        return RC:GetColor("ui", "readyBorder")
    end

    function RC.UI:RepaintReadyIcon(icon)
        if not icon or not icon.halo then return end
        local gold = GetAccentGold()
        local g = (RC.GetColor and RC:GetColor("ui", "readyGlow")) or gold
        local b = (RC.GetColor and ReadyBorderColor()) or gold
        self:UpdateBorderColor(icon.ring, b, 1)
        icon.halo:SetVertexColor(g.r, g.g, g.b, 1)
        local style = RC.db and RC.db.iconBorder or "thick"
        for _, t in pairs(icon.ring or {}) do
            if style == "none" then t:Hide() else t:Show() end
        end
        if style == "thick" then icon.plate:Show() else icon.plate:Hide() end
        if icon.readySize then
            local k = (RC.db and tonumber(RC.db.iconGlowScale)) or HALO_SCALE
            icon.halo:SetSize(icon.readySize * k, icon.readySize * k)
        end
    end

    function RC.UI:DressReadyIcon(icon, size)
        if not (icon and icon.CreateTexture) then return end
        if not icon.halo then
            local plate = icon:CreateTexture(nil, "BACKGROUND", nil, -1)
            plate:SetTexture(FLAT)
            plate:SetVertexColor(0, 0, 0, 1)
            plate:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1)
            plate:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
            icon.plate = plate

            icon.ring = self:CreateSimpleBorder(icon, 1)

            local halo = icon:CreateTexture(nil, "BACKGROUND", nil, -2)
            halo:SetTexture(HALO_TEX)
            halo:SetTexCoord(HALO_L, HALO_R, HALO_T, HALO_B)
            halo:SetBlendMode("ADD")
            halo:SetPoint("CENTER", icon, "CENTER", 0, 0)
            icon.halo = halo

            local ag = halo:CreateAnimationGroup()
            ag:SetLooping("BOUNCE")
            local a = ag:CreateAnimation("Alpha")
            a:SetFromAlpha(1)
            a:SetToAlpha(0.4)
            a:SetDuration(0.9)
            a:SetSmoothing("IN_OUT")
            icon.haloPulse = ag
            icon.haloPulseAlpha = a
        end
        icon.readySize = size
        self:RepaintReadyIcon(icon)
    end

    -- The pulse follows the global Motion switches: its 0.9s breath is
    -- divided by the speed, and with animations off it holds steady.
    function RC.UI:SetReadyIconGlow(icon, mode)
        if not (icon and icon.halo) then return end
        local M = RC.Motion
        if mode == "pulse" and M and not M.Enabled() then mode = "static" end
        if mode == "pulse" and icon.haloPulseAlpha and M then
            local d = 0.9 / M.Speed()
            if icon._haloDur ~= d then
                icon._haloDur = d
                icon.haloPulse:Stop()
                icon.haloPulseAlpha:SetDuration(d)
            end
        end
        if mode == "off" then
            icon.haloPulse:Stop()
            icon.halo:Hide()
            return
        end
        icon.halo:Show()
        if mode == "static" then
            icon.haloPulse:Stop()
            icon.halo:SetAlpha(0.8)
        else
            icon.halo:SetAlpha(1)
            if not icon.haloPulse:IsPlaying() then icon.haloPulse:Play() end
        end
    end

    ------------------------------------------------------------------
    -- CONTEXT MENU
    -- A right-click menu in the Readycheck look (flat dropdown fill, 1px
    -- ring, gold titles, hover rows) for anything that wants one - the
    -- minimap button first. Not UIDropDownMenuTemplate: that one draws
    -- Blizzard's art whatever the theme says, is a taint magnet on this
    -- client, and its list frames are global singletons.
    --
    --   RC.UI:ShowContextMenu(items, opts)
    --   item = { text = "..", func = function() end,
    --            checked = true | function() -> bool,   -- tick on the left
    --            icon = "path",                         -- small icon on the left
    --            isTitle = true,                        -- gold, not clickable
    --            separator = true,                      -- a thin rule
    --            disabled = true,                       -- grey, not clickable
    --            tooltip = "..",                        -- shown on hover
    --            keepOpen = true,                       -- click leaves the menu up (toggles)
    --            children = { items } | function() -> items }  -- submenu, opens on hover
    --   opts.anchor: a frame to hang from (default: the cursor)
    --
    -- The levels are pooled and reused. A click anywhere outside the chain
    -- closes it, and so does the mouse leaving the whole chain for a beat.
    ------------------------------------------------------------------
    local CTX_ROW, CTX_SEP, CTX_PAD = 20, 7, 4
    local ctxLevels, ctxCatcher = {}, nil
    local ARROW_TEX = "Interface\\AddOns\\Readycheck\\Media\\arrow"
    local CHECK_TEX = "Interface\\AddOns\\Readycheck\\Media\\Checkmark"

    local function CtxCloseFrom(level)
        for i = level, #ctxLevels do
            if ctxLevels[i] then ctxLevels[i]:Hide() end
        end
        if level <= 1 and ctxCatcher then ctxCatcher:Hide() end
    end

    function RC.UI:CloseContextMenu() CtxCloseFrom(1) end

    local function CtxAnyHovered()
        for _, m in ipairs(ctxLevels) do
            if m:IsShown() and m:IsMouseOver(8, -8, -8, 8) then return true end
        end
        return false
    end

    local function CtxCatcher()
        if ctxCatcher then return ctxCatcher end
        -- everything under the menu: one click anywhere on it closes the
        -- chain. No keyboard on purpose - SetPropagateKeyboardInput is
        -- protected in combat and a menu must never be what throws.
        ctxCatcher = CreateFrame("Frame", nil, UIParent)
        ctxCatcher:SetAllPoints(UIParent)
        ctxCatcher:SetFrameStrata("FULLSCREEN_DIALOG")
        ctxCatcher:SetFrameLevel(1)
        ctxCatcher:EnableMouse(true)
        ctxCatcher:SetScript("OnMouseDown", function() CtxCloseFrom(1) end)
        ctxCatcher:Hide()
        return ctxCatcher
    end

    local function CtxLevel(i)
        local m = ctxLevels[i]
        if m then return m end
        m = CreateFrame("Frame", nil, UIParent)
        m:SetFrameStrata("FULLSCREEN_DIALOG")
        m:SetFrameLevel(10 + i * 5)
        m:SetClampedToScreen(true)
        local bg = m:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(FLAT)
        m.bg = bg
        m.border = RC.UI:CreateSimpleBorder(m)
        m.rows, m.rules = {}, {}
        if i == 1 then
            -- the mouse wandering off the whole chain closes it after a
            -- beat, the way a tooltip goes; level 1 keeps the clock
            m.away = 0
            m:SetScript("OnUpdate", function(self, elapsed)
                if CtxAnyHovered() then self.away = 0 return end
                self.away = self.away + elapsed
                if self.away > 1.5 then self.away = 0 CtxCloseFrom(1) end
            end)
            m:HookScript("OnShow", function(self) self.away = 0 end)
        end
        m:Hide()
        ctxLevels[i] = m
        return m
    end

    local function CtxRow(m, i)
        local row = m.rows[i]
        if row then return row end
        row = CreateFrame("Button", nil, m)
        row:SetHeight(CTX_ROW)
        row.hl = row:CreateTexture(nil, "BACKGROUND")
        row.hl:SetAllPoints()
        row.hl:SetTexture(FLAT)
        row.hl:Hide()
        row.label = CreateProfessionalFontString(row, "OVERLAY", BASE.FONT_SIZE_SMALL, "OUTLINE")
        row.label:SetPoint("LEFT", 22, 0)
        row.label:SetPoint("RIGHT", -16, 0)
        row.label:SetJustifyH("LEFT")
        row.label:SetWordWrap(false)
        row.tick = row:CreateTexture(nil, "ARTWORK")
        row.tick:SetSize(11, 11)
        row.tick:SetPoint("LEFT", 5, 0)
        row.tick:SetTexture(CHECK_TEX)
        row.tick:Hide()
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(14, 14)
        row.icon:SetPoint("LEFT", 4, 0)
        row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.icon:Hide()
        row.arrow = row:CreateTexture(nil, "ARTWORK")
        row.arrow:SetSize(8, 8)
        row.arrow:SetPoint("RIGHT", -5, 0)
        row.arrow:SetTexture(ARROW_TEX)
        if row.arrow.SetRotation then row.arrow:SetRotation(math.rad(90)) end
        row.arrow:Hide()
        m.rows[i] = row
        return row
    end

    local CtxShow

    local function CtxBuild(m, level, items)
        local y, n, width, sep = -CTX_PAD, 0, 120, 0
        local bgc = _uif.GetDropdownBG()
        m.bg:SetVertexColor(bgc.r, bgc.g, bgc.b, bgc.a or 0.98)
        RC.UI:UpdateBorderColor(m.border, GetBorderNormal(), 1)
        local hover, txt, gold, gray, sel, arrowc =
            _uif.GetDropdownItemHover(), _uif.GetDropdownItemText(), _uif.GetTextGold(), GetTextGray(),
            _uif.GetDropdownSelected(), _uif.GetDropdownArrow()
        for _, item in ipairs(items) do
            if item.separator then
                sep = sep + 1
                local rule = m.rules[sep]
                if not rule then
                    rule = m:CreateTexture(nil, "ARTWORK")
                    rule:SetTexture(FLAT)
                    rule:SetHeight(1)
                    m.rules[sep] = rule
                end
                rule:ClearAllPoints()
                rule:SetPoint("TOPLEFT", m, "TOPLEFT", 8, y - 3)
                rule:SetPoint("RIGHT", m, "RIGHT", -8, 0)
                local bc = GetBorderNormal()
                rule:SetVertexColor(bc.r, bc.g, bc.b, 0.6)
                rule:Show()
                y = y - CTX_SEP
            else
                n = n + 1
                local row = CtxRow(m, n)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", m, "TOPLEFT", 2, y)
                row:SetPoint("RIGHT", m, "RIGHT", -2, 0)
                row.label:SetText(item.text or "")
                local c = item.isTitle and gold or (item.disabled and gray) or txt
                row.label:SetTextColor(c.r, c.g, c.b, 1)
                local checked = item.checked
                if type(checked) == "function" then checked = checked() end
                row.tick:SetShown(checked and true or false)
                if RC.UI.CheckmarkTexture then row.tick:SetTexture(RC.UI:CheckmarkTexture()) end
                row.tick:SetVertexColor(sel.r, sel.g, sel.b, 1)
                if item.icon and not checked then
                    row.icon:SetTexture(item.icon)
                    row.icon:Show()
                else
                    row.icon:Hide()
                end
                row.arrow:SetShown(item.children ~= nil)
                row.arrow:SetVertexColor(arrowc.r, arrowc.g, arrowc.b, 1)
                row.item, row.level, row.hoverColor = item, level, hover
                row:SetScript("OnEnter", function(self)
                    local it = self.item
                    if not it.isTitle and not it.disabled then
                        self.hl:SetVertexColor(self.hoverColor.r, self.hoverColor.g, self.hoverColor.b, self.hoverColor.a or 1)
                        self.hl:Show()
                    end
                    if it.children then
                        local kids = type(it.children) == "function" and it.children() or it.children
                        CtxShow(kids, { anchor = self, level = self.level + 1 })
                    else
                        CtxCloseFrom(self.level + 1)
                    end
                    if it.tooltip then
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:SetText(it.text or "", 1, 1, 1)
                        GameTooltip:AddLine(it.tooltip, nil, nil, nil, true)
                        GameTooltip:Show()
                    end
                end)
                row:SetScript("OnLeave", function(self)
                    self.hl:Hide()
                    GameTooltip:Hide()
                end)
                row:SetScript("OnClick", function(self)
                    local it = self.item
                    if it.isTitle or it.disabled or it.children then return end
                    if it.func then it.func() end
                    if it.keepOpen then
                        CtxBuild(m, level, items)
                    else
                        CtxCloseFrom(1)
                    end
                end)
                row:Show()
                local w = row.label:GetStringWidth() + 44
                if w > width then width = w end
                y = y - CTX_ROW
            end
        end
        for i = n + 1, #m.rows do m.rows[i]:Hide() end
        for i = sep + 1, #m.rules do m.rules[i]:Hide() end
        m:SetSize(math.min(300, math.max(140, width)), -y + CTX_PAD)
    end

    CtxShow = function(items, opts)
        opts = opts or {}
        local level = opts.level or 1
        -- close what was up FIRST: CtxCloseFrom(1) hides the catcher, so
        -- the catcher is shown after it, never before
        if level == 1 and RC.UI.CloseAllDropdowns then RC.UI:CloseAllDropdowns() end
        CtxCloseFrom(level)
        if level == 1 then CtxCatcher():Show() end
        local m = CtxLevel(level)
        CtxBuild(m, level, items or {})
        m:ClearAllPoints()
        if opts.anchor and level > 1 then
            m:SetPoint("TOPLEFT", opts.anchor, "TOPRIGHT", 2, CTX_PAD)
        elseif opts.anchor then
            m:SetPoint("TOPLEFT", opts.anchor, "BOTTOMLEFT", 0, -2)
        else
            local x, y = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            m:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale - 4, y / scale + 4)
        end
        m:Show()
        return m
    end
    RC.UI.ShowContextMenu = function(_, items, opts) return CtxShow(items, opts) end


