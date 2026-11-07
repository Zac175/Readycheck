local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local math_floor, math_ceil, math_max, math_min, math_abs = math.floor, math.ceil, math.max, math.min, math.abs
local table_insert = table.insert
local CreateFrame = CreateFrame
local C_Timer = C_Timer

------------------------------------------------------------------------
-- Readycheck - UI Framework Dialogs and EditBoxes
-- Owns the modal confirm/input popups and every EditBox variant (plain,
-- backed, scrollable, search). EditBox helpers here are the reason
-- callers should never CreateFrame("EditBox") directly - SetBackdrop on
-- an EditBox itself causes a flashing white cursor in Classic, so every
-- helper below wraps the EditBox in a separate BackdropTemplate frame.
------------------------------------------------------------------------

local RC = _G.Readycheck
if not RC then return end
RC._uif = RC._uif or {}
local _uif = RC._uif
local BASE, C, FLAT, CreateProfessionalFontString, GetAccentGold, GetBorderNormal, GetButtonHoverBG, GetButtonNormalBG, GetButtonTexture, GetCloseHover, GetCloseNormal, GetElementBG, GetHeaderBG, GetHeaderText, GetTextGray, GetTextNormal, GetWindowBG, RegisterTexture =
      _uif.BASE, _uif.C, _uif.FLAT, _uif.CreateProfessionalFontString, _uif.GetAccentGold, _uif.GetBorderNormal, _uif.GetButtonHoverBG, _uif.GetButtonNormalBG, _uif.GetButtonTexture, _uif.GetCloseHover, _uif.GetCloseNormal, _uif.GetElementBG, _uif.GetHeaderBG, _uif.GetHeaderText, _uif.GetTextGray, _uif.GetTextNormal, _uif.GetWindowBG, _uif.RegisterTexture

    -- Modal dim: one full-screen black 0.45 sheet (structural, not a
    -- theme colour) that both singleton dialogs sit on. EnableMouse so
    -- clicks behind the dialog are swallowed; unnamed so it adds no
    -- global. Lives in DIALOG strata like the config window and is
    -- Raise()d on every show so it lands above it.
    local function GetModalOverlay()
        local ov = _uif.modalOverlay
        if ov then return ov end
        ov = CreateFrame("Frame", nil, UIParent)
        ov:SetAllPoints(UIParent)
        ov:SetFrameStrata("DIALOG")
        ov:SetFrameLevel(200)
        ov:EnableMouse(true)
        ov.dim = ov:CreateTexture(nil, "BACKGROUND")
        ov.dim:SetAllPoints()
        ov.dim:SetColorTexture(0, 0, 0, 0.45)
        ov:SetScript("OnMouseDown", function() end)
        ov:Hide()
        _uif.modalOverlay = ov
        return ov
    end

    -- Only one modal at a time: a new request silently replaces the one
    -- on screen (no callbacks fire for the replaced dialog).
    local function ShowModal(dialog)
        local ov = GetModalOverlay()
        local prev = _uif.activeModal
        if prev and prev ~= dialog and prev:IsShown() then
            prev._resolved = true
            RC.UI:StopAnimations(prev)
            prev:Hide()
            prev:SetAlpha(1)
            prev:SetScale(1)
        end
        _uif.activeModal = dialog
        dialog._resolved = false

        RC.UI:StopAnimations(ov)
        ov:Show()
        ov:Raise()
        RC.UI:FadeIn(ov, 0.12)

        dialog:SetFrameLevel((ov:GetFrameLevel() or 200) + 10)
        dialog:ClearAllPoints()
        dialog:SetPoint("CENTER", ov, "CENTER", 0, 40)
        -- Keyboard (Enter/ESC) is only claimed out of combat - the
        -- propagate toggle it needs is protected in combat, where ESC
        -- still works through UISpecialFrames.
        dialog:EnableKeyboard(not InCombatLockdown())
        RC.UI:PopIn(dialog, 0.12)
    end

    -- Resolves the dialog (so OnHide does not treat it as an ESC-cancel),
    -- pops it out, fades the dim with it and runs the chosen callback
    -- right away - callers rebuilding UI or opening another dialog from
    -- the callback must not wait on the animation.
    local function CloseModal(dialog, callback)
        dialog._resolved = true
        if dialog.editBox then dialog.editBox:ClearFocus() end
        local ov = GetModalOverlay()
        if _uif.activeModal == dialog then
            _uif.activeModal = nil
            RC.UI:FadeFrame(ov, ov:GetAlpha(), 0, 0.1)
        end
        RC.UI:PopOut(dialog, 0.1)
        if callback then callback() end
    end

    -- Shared dialog shell: flat ui.windowBackground fill at 0.97, 1px
    -- black ring, a 30px flat ui.headerBackground title bar with a 1px
    -- gold rule along its bottom, the title 15px gold at x 10, and a
    -- chromeless X at the right. Both singleton dialogs are built on
    -- this so they and the main window read as one family. Hangs
    -- .titleBar/.titleText/.closeBtn/.accentLine on the dialog; onClose
    -- runs from the X. Drag by the title bar only.
    local function BuildDialogShell(self, dialog, onClose)
        local winBg  = GetWindowBG()
        local hdrBg  = GetHeaderBG()
        local hdrTxt = GetHeaderText()
        local accent = GetAccentGold()

        dialog:SetBackdrop({
            bgFile   = FLAT,
            edgeFile = FLAT,
            edgeSize = 1,
        })
        dialog:SetBackdropColor(winBg.r, winBg.g, winBg.b, 0.97)
        local bk = GetBorderNormal()
        dialog:SetBackdropBorderColor(bk.r, bk.g, bk.b, bk.a or 1)

        local titleBar = CreateFrame("Frame", nil, dialog)
        titleBar:SetHeight(30)
        titleBar:SetPoint("TOPLEFT", dialog, "TOPLEFT", 1, -1)
        titleBar:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -1, -1)
        titleBar:EnableMouse(true)
        titleBar:RegisterForDrag("LeftButton")
        titleBar:SetScript("OnDragStart", function() dialog:StartMoving() end)
        titleBar:SetScript("OnDragStop", function() dialog:StopMovingOrSizing() end)
        local titleFill = titleBar:CreateTexture(nil, "BACKGROUND")
        titleFill:SetAllPoints()
        titleFill:SetTexture(FLAT)
        titleFill:SetVertexColor(hdrBg.r, hdrBg.g, hdrBg.b, hdrBg.a or 1)
        titleBar.bg = titleFill
        dialog.titleBar = titleBar

        -- Addon mark at the left of the bar, title 8px to its right.
        -- LayoutDialogBody hides it again when the caller supplies its own
        -- opts.icon, so only one mark is ever on screen.
        local titleIcon = self:AddTitleIcon(titleBar, 16, 8)
        dialog.titleIcon = titleIcon

        local titleText = CreateProfessionalFontString(titleBar, "OVERLAY", 15, "OUTLINE")
        titleText:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        titleText:SetPoint("RIGHT", titleBar, "RIGHT", -30, 0)
        titleText:SetJustifyH("LEFT")
        titleText:SetTextColor(hdrTxt.r, hdrTxt.g, hdrTxt.b, 1)
        dialog.titleText = titleText

        local closeBtn = self:CreateXCloseButton(titleBar, 22, onClose)
        closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -5, 0)
        dialog.closeBtn = closeBtn

        local accentLine = titleBar:CreateTexture(nil, "ARTWORK")
        accentLine:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
        accentLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
        accentLine:SetHeight(1)
        accentLine:SetTexture(FLAT)
        accentLine:SetVertexColor(accent.r, accent.g, accent.b, 0.6)
        dialog.accentLine = accentLine
        -- the header art every Readycheck window wears (the stepped
        -- rule replaces the flat line, which stays for callers that hold it)
        if self.ApplyHeaderArt then
            accentLine:Hide()
            self:ApplyHeaderArt(titleBar, { stepX = 140 })
        end

        -- Optional 28px icon left of the body; the body text shifts
        -- right by 40 when it is set (see LayoutDialogBody).
        local icon = dialog:CreateTexture(nil, "ARTWORK")
        icon:SetSize(28, 28)
        icon:SetPoint("TOPLEFT", dialog, "TOPLEFT", 18, -45)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:Hide()
        dialog.icon = icon

        -- Body: 11px text.normal, wrapped, 18px side padding, 14px
        -- below the gold rule.
        local txtNorm = GetTextNormal()
        local messageText = CreateProfessionalFontString(dialog, "OVERLAY", BASE.FONT_SIZE_SMALL, "")
        messageText:SetPoint("TOPLEFT", dialog, "TOPLEFT", 18, -45)
        messageText:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -18, -45)
        messageText:SetJustifyH("LEFT")
        messageText:SetJustifyV("TOP")
        messageText:SetWordWrap(true)
        messageText:SetTextColor(txtNorm.r, txtNorm.g, txtNorm.b, 1)
        dialog.messageText = messageText

        -- Whole-dialog keyboard: Enter confirms, ESC cancels, anything
        -- else passes through. Handlers are looked up at press time so
        -- each Create* call can rebind them.
        dialog:SetScript("OnKeyDown", function(self, key)
            local handled = false
            if key == "ESCAPE" then
                handled = true
                if self.DoCancel then self:DoCancel() end
            elseif key == "ENTER" then
                handled = true
                if self.DoConfirm then self:DoConfirm() end
            end
            if not InCombatLockdown() then
                self:SetPropagateKeyboardInput(not handled)
            end
        end)

        -- Hidden from outside (UISpecialFrames ESC in combat, a caller's
        -- own Hide) without a button choice: that is a cancel.
        dialog:SetScript("OnHide", function(self)
            if self._resolved then return end
            self._resolved = true
            local ov = GetModalOverlay()
            if _uif.activeModal == self then
                _uif.activeModal = nil
                RC.UI:FadeFrame(ov, ov:GetAlpha(), 0, 0.1)
            end
            if self.onCancel then self.onCancel() end
        end)
    end

    -- Applies opts.icon / opts.width, re-anchors the body text next to
    -- the icon (or back to the padding), and returns the body height
    -- (text or icon, whichever is taller) for the caller's height sum.
    local function LayoutDialogBody(dialog, opts, defaultWidth)
        opts = opts or {}
        local width = opts.width or defaultWidth
        dialog:SetWidth(width)

        -- A caller-supplied icon wins: the addon mark steps aside and the
        -- title falls back to the bar's own left padding.
        local titleIcon = dialog.titleIcon
        if titleIcon and dialog.titleText then
            dialog.titleText:ClearAllPoints()
            if opts.icon then
                titleIcon:Hide()
                dialog.titleText:SetPoint("LEFT", dialog.titleBar, "LEFT", 10, 0)
            else
                titleIcon:Show()
                dialog.titleText:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
            end
            dialog.titleText:SetPoint("RIGHT", dialog.titleBar, "RIGHT", -30, 0)
        end

        local textX = 18
        if opts.icon then
            dialog.icon:SetTexture(opts.icon)
            dialog.icon:Show()
            textX = 18 + 40
        else
            dialog.icon:Hide()
        end
        dialog.messageText:ClearAllPoints()
        dialog.messageText:SetPoint("TOPLEFT", dialog, "TOPLEFT", textX, -45)
        dialog.messageText:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -18, -45)
        dialog.messageText:SetWidth(width - textX - 18)
        local textH = dialog.messageText:GetStringHeight() or 14
        if opts.icon then textH = math.max(textH, 28) end
        return textH
    end

    -- Destructive confirm: normal fill, red label (text.red at rest,
    -- buttons.closeHover under the pointer). Layered on top of the
    -- styled button's own paint so the red survives hover/Repaint.
    local function PaintDestructive(btn)
        if not btn._destructive or not btn.text then return end
        local c = btn:IsMouseOver() and GetCloseHover() or RC:GetColor("text", "red")
        btn.text:SetTextColor(c.r, c.g, c.b, 1)
    end

    -- Shows a modal Yes/No dialog with a destructive-styled confirm
    -- button by default (set isDestructive = false for a neutral action).
    -- The dialog frame is a singleton (_G.WRConfirmDialog) built once and
    -- reused/restyled on each call - only one modal can be on screen
    -- addon-wide at a time (a new request replaces the old one).
    -- opts (optional): icon (texture path), width, confirmIsPrimary.
    -- Returns the dialog frame.
    function RC.UI:CreateConfirmDialog(title, message, onConfirm, onCancel, confirmText, isDestructive, opts)
        confirmText = confirmText or "Delete"
        if isDestructive == nil then isDestructive = true end
        local dialogName = "WRConfirmDialog"
        local dialog = _G[dialogName]

        if not dialog then
            dialog = CreateFrame("Frame", dialogName, UIParent, "BackdropTemplate")
            dialog:SetSize(380, 120)
            dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
            dialog:SetFrameStrata("DIALOG")
            dialog:SetFrameLevel(210)
            dialog:SetToplevel(true)
            dialog:EnableMouse(true)
            dialog:SetMovable(true)
            dialog:SetClampedToScreen(true)

            BuildDialogShell(self, dialog, function()
                if dialog.DoCancel then dialog:DoCancel() end
            end)

            function dialog:DoConfirm()
                if self._resolved then return end
                CloseModal(self, self.onConfirm)
            end
            function dialog:DoCancel()
                if self._resolved then return end
                CloseModal(self, self.onCancel)
            end

            -- Button row, bottom-right, 10px gap: Cancel then Confirm.
            local confirmBtn = self:CreateStyledButton(dialog, RCL["Delete"], 110, 22)
            confirmBtn:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -18, 14)
            confirmBtn:HookScript("OnEnter", PaintDestructive)
            confirmBtn:HookScript("OnLeave", PaintDestructive)
            local baseRepaint = confirmBtn.Repaint
            confirmBtn.Repaint = function(b)
                baseRepaint(b)
                PaintDestructive(b)
            end
            confirmBtn:SetScript("OnClick", function() dialog:DoConfirm() end)
            dialog.confirmBtn = confirmBtn

            local cancelBtn = self:CreateStyledButton(dialog, RCL["Cancel"], 110, 22)
            cancelBtn:SetPoint("RIGHT", confirmBtn, "LEFT", -10, 0)
            cancelBtn:SetScript("OnClick", function() dialog:DoCancel() end)
            dialog.cancelBtn = cancelBtn

            self:RegisterEscapeClose(dialogName)

            dialog._resolved = true
            dialog:Hide()
        end

        dialog.titleText:SetText(title or RCL["Confirm"])
        dialog.messageText:SetText(message or RCL["Are you sure?"])
        dialog.onConfirm = onConfirm
        dialog.onCancel = onCancel
        dialog.cancelBtn.text:SetText(RCL["Cancel"])

        local btn = dialog.confirmBtn
        btn.text:SetText(confirmText)
        btn._destructive = isDestructive and true or false
        local primary = false
        if opts and opts.confirmIsPrimary ~= nil then
            primary = opts.confirmIsPrimary and true or false
        else
            primary = not isDestructive
        end
        btn:SetActive(primary)
        btn:Repaint()

        -- Height fits content: title bar 31 + 14 + body + 16 + buttons
        -- 22 + 14, never under 120.
        local textH = LayoutDialogBody(dialog, opts, 380)
        dialog:SetHeight(math.max(120, 97 + textH))

        ShowModal(dialog)

        return dialog
    end

    -- Returns container (a BackdropTemplate frame - never the EditBox
    -- itself gets SetBackdrop, to avoid the Classic white-cursor flicker
    -- bug). container.editBox is the real EditBox; container.scrollBar/
    -- .scrollFrame exist only when opts.scrollable is set. opts:
    -- height, multiLine, readOnly, font, scrollable, scrollHeight,
    -- maxLetters, textColor, initialText, onTextChanged, onFocusLost.
    function RC.UI:CreateStyledEditBox(parent, opts)
        opts = opts or {}
        local height     = opts.height or BASE.EDITBOX_HEIGHT
        local multiLine  = opts.multiLine == true
        local readOnly   = opts.readOnly == true
        local fontSize   = opts.font or 11
        local scrollable = opts.scrollable == true and multiLine
        local scrollH    = opts.scrollHeight or 96

        local elBG  = GetElementBG()
        local bNorm = GetBorderNormal()

        -- Flat ui.elementBackground box, 1px ring; focus lights the ring
        -- gold, the only focus affordance a flat box gets.
        local container = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        if opts.width then container:SetWidth(opts.width) end
        container:SetHeight(scrollable and (scrollH + 12) or height)
        container:SetBackdrop({
            bgFile   = FLAT,
            edgeFile = FLAT,
            edgeSize = 1,
        })
        container:SetBackdropColor(elBG.r, elBG.g, elBG.b, 1)
        container:SetBackdropBorderColor(bNorm.r, bNorm.g, bNorm.b, bNorm.a or 1)

        local eb
        local scrollFrame
        if scrollable then
            local scrollBarWidth = 10

            scrollFrame = CreateFrame("ScrollFrame", nil, container)
            scrollFrame:SetPoint("TOPLEFT",     container, "TOPLEFT",                6, -6)
            scrollFrame:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -(scrollBarWidth + 6),  6)

            local scrollBar = self:AttachScrollbar(scrollFrame, container, { width = scrollBarWidth })
            container.scrollBar = scrollBar

            eb = CreateFrame("EditBox", nil, scrollFrame)
            eb:SetMultiLine(true)
            eb:SetAutoFocus(false)
            eb:SetFontObject("ChatFontNormal")
            -- (Readycheck's font, like every text; the size the box always had)
            if RC.ApplyCustomFont then RC:ApplyCustomFont(eb, 14, "") end
            scrollFrame:SetScrollChild(eb)
            container.scrollFrame = scrollFrame

            scrollFrame:SetScript("OnSizeChanged", function(sf, w, h)
                eb:SetWidth(w)
                scrollBar:SyncRange(eb:GetHeight() or 0, h or 0)
            end)
            eb:SetScript("OnTextChanged", function(e)
                if opts.onTextChanged then opts.onTextChanged(e) end
                C_Timer.After(0, function()
                    if not eb:IsShown() then return end
                    scrollBar:SyncRange(eb:GetHeight() or 0, scrollFrame:GetHeight() or 0)
                end)
            end)
        else
            eb = CreateFrame("EditBox", nil, container)
            if multiLine then
                eb:SetPoint("TOPLEFT",     container, "TOPLEFT",      8, -6)
                eb:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -8,  6)
                eb:SetMultiLine(true)
            else
                eb:SetPoint("LEFT",  container, "LEFT",   8, 0)
                eb:SetPoint("RIGHT", container, "RIGHT", -8, 0)
                eb:SetHeight(height - 6)
            end
            eb:SetAutoFocus(false)
        end

        if opts.maxLetters and opts.maxLetters > 0 then eb:SetMaxLetters(opts.maxLetters) end
        if RC.ApplyCustomFont then RC:ApplyCustomFont(eb, fontSize, "") end
        if opts.textColor then
            eb:SetTextColor(opts.textColor.r or opts.textColor[1] or 1,
                            opts.textColor.g or opts.textColor[2] or 1,
                            opts.textColor.b or opts.textColor[3] or 1, 1)
        else
            local tn = GetTextNormal()
            eb:SetTextColor(tn.r, tn.g, tn.b, 1)
        end
        if opts.initialText then eb:SetText(opts.initialText) end
        eb:SetCursorPosition(0)

        eb:SetScript("OnEditFocusGained", function(s)
            local accent = GetAccentGold()
            container:SetBackdropBorderColor(accent.r, accent.g, accent.b, 1)
            if readOnly then s:HighlightText() end
        end)
        eb:SetScript("OnEditFocusLost", function(s)
            local bk = GetBorderNormal()
            container:SetBackdropBorderColor(bk.r, bk.g, bk.b, bk.a or 1)
            if readOnly then
                s:HighlightText(0, 0)
                if opts.initialText then
                    s:SetText(opts.initialText)
                    s:SetCursorPosition(0)
                end
            end
            if opts.onFocusLost then opts.onFocusLost(s) end
        end)
        eb:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
        -- A typed value counts as a setting change when it is committed:
        -- Enter on a line, leaving the box on a multi-line one.
        if not multiLine then
            eb:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)
            _uif.WrapNotify(eb, "OnEnterPressed", "editbox")
        elseif not readOnly then
            _uif.WrapNotify(eb, "OnEditFocusLost", "editbox")
        end
        if opts.onTextChanged and not scrollable then
            eb:SetScript("OnTextChanged", function(s, userInput) opts.onTextChanged(s, userInput) end)
        end

        container:EnableMouse(true)
        container:SetScript("OnMouseUp", function() eb:SetFocus() end)

        container.editBox = eb
        return container
    end

-- Bare EditBox with no background of its own - intended as a building
-- block for CreateBackedEditBox or callers that supply their own
-- container. opts: width/height (else auto-pads to container),
-- maxLetters, multiLine, numeric, fontSize, fontFlags, justify, insets,
-- textColor.
function RC.UI:CreateEditBox(container, opts)
    opts = opts or {}
    local eb = CreateFrame("EditBox", nil, container)
    if opts.width or opts.height then
        if opts.width then eb:SetWidth(opts.width) end
        if opts.height then eb:SetHeight(opts.height) end
    else
        local px = opts.padX or 4
        eb:SetPoint("TOPLEFT", container, "TOPLEFT", px, -(opts.padTopY or 0))
        eb:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -px, opts.padBottomY or 0)
    end
    eb:SetAutoFocus(false)
    eb:SetMaxLetters(opts.maxLetters or 0)
    if opts.multiLine then eb:SetMultiLine(true) end
    if opts.numeric then eb:SetNumeric(true) end
    RC:ApplyCustomFont(eb, opts.fontSize or 10, opts.fontFlags)
    if opts.justify then eb:SetJustifyH(opts.justify) end
    if opts.insets then eb:SetTextInsets(opts.insets, opts.insets, 0, 0) end
    local c = opts.textColor
    if c then eb:SetTextColor(c[1], c[2], c[3], c[4] or 1)
    else eb:SetTextColor(1, 1, 1, 1) end
    eb:SetScript("OnEscapePressed", function(sf) sf:ClearFocus() end)
    if not opts.multiLine then _uif.WrapNotify(eb, "OnEnterPressed", "editbox") end
    return eb
end

-- CreateEditBox plus a separate BackdropTemplate frame (eb.bg) drawn
-- behind it for the background/border, again to keep SetBackdrop off
-- the EditBox itself. Returns the EditBox; eb.bg is the backing frame.
function RC.UI:CreateBackedEditBox(parent, opts)
    opts = opts or {}
    local eb = self:CreateEditBox(parent, opts)
    local bg = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    bg:SetFrameLevel(math.max(0, (eb:GetFrameLevel() or 1) - 1))
    bg:SetPoint("TOPLEFT", eb, "TOPLEFT", -1, 1)
    bg:SetPoint("BOTTOMRIGHT", eb, "BOTTOMRIGHT", 1, -1)
    bg:SetBackdrop({
        bgFile = FLAT,
        edgeFile = FLAT,
        edgeSize = 1,
    })
    local bc = opts.bgColor
    if bc then bg:SetBackdropColor(bc[1], bc[2], bc[3], bc[4] or 1)
    else
        local el = GetElementBG()
        bg:SetBackdropColor(el.r, el.g, el.b, 1)
    end
    local bk = GetBorderNormal()
    bg:SetBackdropBorderColor(bk.r, bk.g, bk.b, bk.a or 1)
    -- Gold ring while typing, like every other edit box in the framework.
    eb:HookScript("OnEditFocusGained", function()
        local accent = GetAccentGold()
        bg:SetBackdropBorderColor(accent.r, accent.g, accent.b, 1)
    end)
    eb:HookScript("OnEditFocusLost", function()
        local b2 = GetBorderNormal()
        bg:SetBackdropBorderColor(b2.r, b2.g, b2.b, b2.a or 1)
    end)
    eb.bg = bg
    return eb
end

-- CreateStyledEditBox plus a placeholder label and a clear (X) button
-- that appear/hide based on text content. opts.onChange(text) fires on
-- user-driven text changes; container:GetSearchText()/ClearSearch() are
-- exposed for callers that need to read or reset it programmatically.
function RC.UI:CreateSearchBox(parent, opts)
        opts = opts or {}
        local placeholder = opts.placeholder or "Search..."
        local onChange    = opts.onChange
        local fontSize    = opts.font or 11

        local container = self:CreateStyledEditBox(parent, {
            width      = opts.width,
            height     = opts.height or BASE.EDITBOX_HEIGHT,
            font       = fontSize,
            maxLetters = opts.maxLetters or 50,
            initialText = opts.initialText,
        })
        local eb = container.editBox

        local ph = container:CreateFontString(nil, "OVERLAY")
        ph:SetPoint("LEFT",  container, "LEFT",   8, 0)
        ph:SetPoint("RIGHT", container, "RIGHT", -22, 0)
        ph:SetJustifyH("LEFT")
        if RC.ApplyCustomFont then RC:ApplyCustomFont(ph, fontSize, "") end
        local g = GetTextGray()
        ph:SetTextColor(g.r, g.g, g.b, 0.8)
        ph:SetText(placeholder)
        container.placeholderText = ph

        local clear = self:CreateXCloseButton(container, 14, function()
            eb:SetText("")
            eb:ClearFocus()
            if onChange then onChange("") end
        end)
        clear:ClearAllPoints()
        clear:SetPoint("RIGHT", container, "RIGHT", -3, 0)
        clear:SetFrameLevel(eb:GetFrameLevel() + 2)
        clear:Hide()
        container.clearButton = clear

        local function refresh(txt)
            txt = txt or ""
            if txt == "" then ph:Show() else ph:Hide() end
            if txt == "" then clear:Hide() else clear:Show() end
        end

        eb:SetScript("OnTextChanged", function(s, userInput)
            local txt = s:GetText() or ""
            refresh(txt)
            if userInput and onChange then onChange(txt) end
        end)

        eb:HookScript("OnEditFocusGained", function() ph:Hide() end)
        eb:HookScript("OnEditFocusLost", function()
            if (eb:GetText() or "") == "" then ph:Show() end
        end)

        function container:GetSearchText() return eb:GetText() or "" end
        function container:ClearSearch()
            eb:SetText("")
            eb:ClearFocus()
            refresh("")
            if onChange then onChange("") end
        end

        refresh(eb:GetText() or "")
        return container
    end

    -- Modal single-line text prompt (OK/Cancel). Singleton dialog frame
    -- like CreateConfirmDialog (_G.WRInputDialog) - only one instance
    -- exists addon-wide. onAccept(text) may return false to keep the
    -- dialog open (e.g. failed validation) instead of closing it.
    -- opts (optional): icon (texture path), width. Enter in the box (or
    -- anywhere on the dialog) accepts, ESC cancels.
    function RC.UI:CreateInputDialog(title, message, initialText, onAccept, onCancel, opts)
        local dialogName = "WRInputDialog"
        local dialog = _G[dialogName]

        if not dialog then
            dialog = CreateFrame("Frame", dialogName, UIParent, "BackdropTemplate")
            dialog:SetSize(420, 150)
            dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
            dialog:SetFrameStrata("DIALOG")
            dialog:SetFrameLevel(210)
            dialog:SetToplevel(true)
            dialog:EnableMouse(true)
            dialog:SetMovable(true)
            dialog:SetClampedToScreen(true)

            BuildDialogShell(self, dialog, function()
                if dialog.DoCancel then dialog:DoCancel() end
            end)

            function dialog:DoConfirm()
                if self._resolved then return end
                if self.onAccept then
                    local keepOpen = self.onAccept(self.editBox:GetText())
                    if keepOpen == false then return end
                end
                CloseModal(self, nil)
            end
            function dialog:DoCancel()
                if self._resolved then return end
                CloseModal(self, self.onCancel)
            end

            -- Flat 22px edit box with a gold ring while focused; built on
            -- CreateStyledEditBox so it matches every other input. Sits
            -- 8px under the body text, 18px in from each side.
            local inputBox = self:CreateStyledEditBox(dialog, {
                height     = BASE.EDITBOX_HEIGHT,
                font       = BASE.FONT_SIZE_SMALL,
                maxLetters = 60,
            })
            inputBox:SetPoint("LEFT",  dialog, "LEFT",  18, 0)
            inputBox:SetPoint("RIGHT", dialog, "RIGHT", -18, 0)
            inputBox:SetPoint("BOTTOM", dialog, "BOTTOM", 0, 52)
            local eb = inputBox.editBox
            eb:SetScript("OnEnterPressed", function() dialog:DoConfirm() end)
            eb:SetScript("OnEscapePressed", function(s)
                s:ClearFocus()
                dialog:DoCancel()
            end)
            dialog.editBox = eb
            dialog.inputBox = inputBox

            -- Button row, bottom-right, 10px gap: Cancel then OK (primary).
            local acceptBtn = self:CreateStyledButton(dialog, RCL["OK"], 110, 22)
            acceptBtn:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -18, 14)
            acceptBtn:SetActive(true)
            acceptBtn:SetScript("OnClick", function() dialog:DoConfirm() end)
            dialog.acceptBtn = acceptBtn

            local cancelBtn = self:CreateStyledButton(dialog, RCL["Cancel"], 110, 22)
            cancelBtn:SetPoint("RIGHT", acceptBtn, "LEFT", -10, 0)
            cancelBtn:SetScript("OnClick", function() dialog:DoCancel() end)
            dialog.cancelBtn = cancelBtn

            self:RegisterEscapeClose(dialogName)
            dialog._resolved = true
            dialog:Hide()
        end

        dialog.titleText:SetText(title or RCL["Input"])
        dialog.messageText:SetText(message or RCL["Enter a value:"])
        dialog.editBox:SetText(initialText or "")
        dialog.editBox:HighlightText()
        dialog.onAccept = onAccept
        dialog.onCancel = onCancel
        dialog.acceptBtn:Repaint()

        -- Height: title bar 31 + 14 + body + 8 + edit box 22 + 16 +
        -- buttons 22 + 14, never under 150.
        local textH = LayoutDialogBody(dialog, opts, 420)
        dialog:SetHeight(math.max(150, 127 + textH))

        ShowModal(dialog)
        dialog.editBox:SetFocus()

        return dialog
    end

    RC:DebugPrint("UI Framework loaded with CUSTOM SCROLLBARS, CLOSE BUTTON, STYLED DROPDOWNS, AND ANIMATIONS", "system")
