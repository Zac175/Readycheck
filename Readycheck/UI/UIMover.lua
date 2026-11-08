------------------------------------------------------------------------
-- Readycheck - UI Mover
-- Drag-to-reposition overlay for every movable Readycheck frame, via
-- UM:RegisterFrame(frameKey, frame, displayName, defaultPos, saveCallback).
-- Frames bound to RC.Position are saved through it (their own pinned
-- point, whole units) and ignore saveCallback; other frames are saved as
-- CENTER offsets through saveCallback(x, y). defaultPos = {point,
-- relPoint, x, y} is the Reset spot for unbound frames.
-- Re-registering the same key with the same frame keeps its overlay;
-- a different frame under the same key gets a new one.
-- opts (6th, optional, unbound frames only): { point, relPoint } = the
-- frame's own convention (its `point` at UIParent's `relPoint`), so the
-- readout and saveCallback(x, y) use the numbers its settings page shows;
-- onReset = what Reset does instead of moving to defaultPos.
-- Every handle is named from LABELS by its key (one plain name per frame,
-- whoever registers it); a key not listed keeps the name it was given.
-- Secure frames (and bars holding secure buttons) cannot move in combat:
-- their handles show a lock and refuse to start a drag until it ends; a
-- drag already under way when combat starts is put down after combat.
------------------------------------------------------------------------
local function InitializeUIMover()
    local RC = _G.Readycheck or _G.WR
    if not RC then
        C_Timer.After(0.5, InitializeUIMover)
        return
    end

    if not RC.UI then
        C_Timer.After(0.5, InitializeUIMover)
        return
    end

    local UM = {}
    RC.UIMover = UM

    UM.isMoving = false
    UM.frames = {}
    UM.anchors = {}
    UM.grid = nil
    UM.controlPanel = nil
    UM.selectedFrame = nil
    UM.gridSize = 25
    UM.showGrid = true
    UM.snapEnabled = false
    UM.snapSize = 10

    local function GetColor(key)
        if RC.GetColor then
            return RC:GetColor("uiMover", key)
        end
        local fallbacks = {
            panelBackground = {r = 0.06, g = 0.06, b = 0.06, a = 0.95},
            panelBorder = {r = 0, g = 0, b = 0, a = 1},
            headerBackground = {r = 0.12, g = 0.12, b = 0.12, a = 1},
            headerText = {r = 1, g = 0.82, b = 0, a = 1},
            anchorBackground = {r = 0.1, g = 0.4, b = 0.7, a = 0.18},
            anchorBorder = {r = 0.2, g = 0.6, b = 1, a = 0.85},
            anchorSelected = {r = 0.2, g = 0.7, b = 0.3, a = 0.8},
            anchorSelectedBorder = {r = 0.3, g = 1, b = 0.4, a = 1},
            anchorText = {r = 1, g = 1, b = 1, a = 1},
            anchorPosText = {r = 0.8, g = 0.8, b = 0.8, a = 1},
            gridLine = {r = 0.3, g = 0.3, b = 0.3, a = 0.3},
            gridCenter = {r = 0.5, g = 0.5, b = 0.8, a = 0.5},
            inputBackground = {r = 0.1, g = 0.1, b = 0.1, a = 1},
            labelText = {r = 0.7, g = 0.7, b = 0.7, a = 1},
        }
        return fallbacks[key] or {r = 1, g = 1, b = 1, a = 1}
    end

    -- Positions are plain UI units. The mover moves a frame by its
    -- CENTER; a frame bound to RC.Position is then saved through it (in
    -- that frame's own pinned point), so the numbers on the panel are
    -- exactly the numbers in the profile. Nothing is rounded except to
    -- whole units on a drop.
    local function Round(v) return math.floor(v + 0.5) end

    local function FmtCoord(v)
        local r = math.floor(v * 10 + 0.5) / 10
        if r == math.floor(r) then return tostring(math.floor(r)) end
        return tostring(r)
    end

    -- UIParent units per unit of `frame` (1 unless the frame is scaled).
    local function ScaleK(frame)
        return UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
    end

    -- Every registered frame stays on screen but may touch the client edge:
    -- clamp on, zero insets. Insets follow the client's sign convention
    -- (positive left / negative right / negative top / positive bottom
    -- let that much cross the edge; the opposite signs hold the frame in).
    local function ClampFrame(frame, l, r, t, b)
        if not (frame and frame.SetClampedToScreen) then return end
        pcall(frame.SetClampedToScreen, frame, true)
        if frame.SetClampRectInsets then
            pcall(frame.SetClampRectInsets, frame, l or 0, r or 0, t or 0, b or 0)
        end
    end

    -- True per axis when the overlay box is resting on a screen edge
    -- (its BOX_PAD overhang plus a unit of slack).
    function UM.EdgeContact(box)
        if not (box and box.GetLeft and box:GetLeft()) then return false, false end
        local tol = 2
        local w, h = UIParent:GetWidth(), UIParent:GetHeight()
        local ex = box:GetLeft() <= tol or box:GetRight() >= w - tol
        local ey = box:GetBottom() <= tol or box:GetTop() >= h - tol
        return ex, ey
    end

    -- Defined after VisibleBounds below: clamps a frame by what the mover
    -- box shows (visible content, or a dock group's full extent), not by
    -- its raw rect, so the visible edge is what stops at the screen edge.
    local ClampToContent

    -- Screen-centre offsets of the frame's centre, in the frame's units.
    local function FrameCenter(frame)
        local x, y = RC.Position.Capture(frame, "CENTER")
        return x or 0, y or 0
    end

    -- Defined after the anchor-fitting helpers below.
    local Readout, AttachAnchor, MoveCenter, SetStored, ResetStored

    -- The name on each handle, in the list and in the dropdown: what the
    -- frame is called on its settings page, in plain words.
    local LABELS = {
        reminderFrame           = RCL["Reminder Popup"],
        statsBar                = RCL["Stats Bar"],
        ttkDisplay              = RCL["Time-to-Kill Display"],
        buffPushoffAlert        = RCL["Buff Pushoff Alert"],
        consumablesChecker      = RCL["Consumables Checker"],
        consumablesHelper       = RCL["Consumables Bar"],
        potionsBar              = RCL["Potions Bar"],
        weaponsBar              = RCL["Weapons Bar"],
        trinketBar              = RCL["Trinket Bar"],
        fastWeaponReminder      = RCL["Equipment Reminder"],
        battleShoutReminder     = RCL["Battle Shout Reminder"],
        trinketToggle           = RCL["Trinket Swap Button"],
        battleShoutPartyTracker = RCL["Battle Shout Party Tracker"],
        raidBuffTracker         = RCL["Raid Buff Tracker"],
        bossDebuffTracker       = RCL["Boss Debuff Tracker"],
        bossNotes               = RCL["Boss Notes"],
        polarityBar             = RCL["Polarity Countdown Bar"],
        mustHaveAlert           = RCL["Must-Have Items Alert"],
        routeTracker            = RCL["Route Tracker"],
        worldBuffMini           = RCL["World Buffs Board"],
        swapToast               = RCL["Gear Swap Notice"],
        meshProgress            = RCL["Sync Transfer Bar"],
        gearSetPrompt           = RCL["Gear Set Picker"],
        wtPullTimersMain        = RCL["Buff Drop Bars (Main)"],
        wtPullTimersIdle        = RCL["Buff Drop Bars (Small)"],
        wtScreenAlert           = RCL["Buff Drop Screen Alert"],
        specPopup               = RCL["Spec Popup"],
    }
    UM.LABELS = LABELS

    -- Called repeatedly (every RegisterAddonFrames pass, including each
    -- EnterMoveMode); it must stay idempotent for a frame that is still
    -- the same object, and must tear down the stale anchor when the
    -- frame object behind a key changes (dock buttons get rebuilt).
    function UM:RegisterFrame(frameKey, frame, displayName, defaultPos, saveCallback, opts)
        if not frame then return end

        local prior = self.frames[frameKey]
        ClampToContent(frame)

        local spare = self._spareAnchors and self._spareAnchors[frameKey]
        if spare then self._spareAnchors[frameKey] = nil end
        local data = {
            frame = frame,
            displayName = LABELS[frameKey] or displayName or frameKey,
            defaultPos = defaultPos or {point = "CENTER", relPoint = "CENTER", x = 0, y = 0},
            saveCallback = saveCallback,
            convPoint = opts and opts.point,
            convRel = opts and (opts.relPoint or opts.point),
            onReset = opts and opts.onReset,
            -- The overlay is reused (frames are never freed); it is
            -- re-fitted to the current frame on the next AttachAnchor.
            anchor = (prior and prior.anchor) or spare,
        }
        if prior and prior.frame == frame then
            -- Re-registered mid-session: keep the preview bookkeeping so
            -- Save & Lock can still undo it.
            data._hideBlocked, data._hideReported = prior._hideBlocked, prior._hideReported
            data._previewShown, data._previewReminder = prior._previewShown, prior._previewReminder
            data._previewNote, data._pausedOnUpdate = prior._previewNote, prior._pausedOnUpdate
            data._pending, data._hideAfterCombat = prior._pending, prior._hideAfterCombat
        end
        if data.anchor then
            data.anchor.frameKey = frameKey
            data.anchor.targetFrame = frame
        end
        self.frames[frameKey] = data

        if RC.DebugPrint then
            RC:DebugPrint("UIMover: Registered '" .. frameKey .. "'", "uimover")
        end
    end

    -- The /moveui panel: a flat 300px window in the ZacUI family - fill
    -- + 1px border, 30px title bar with a gold hairline under it, and a
    -- chromeless X. Every fill below is WHITE8X8 vertex-coloured; no
    -- Blizzard input/button art anywhere on it.
    local FLAT = "Interface\\Buttons\\WHITE8X8"
    local PANEL_W, PANEL_PAD, TITLEBAR_H = 300, 12, 30

    local function FlatFill(frame, color, alpha, layer)
        local tex = frame:CreateTexture(nil, layer or "BACKGROUND")
        tex:SetAllPoints()
        tex:SetTexture(FLAT)
        tex:SetVertexColor(color.r, color.g, color.b, alpha or color.a or 1)
        return tex
    end

    function UM:CreateControlPanel()
        if self.controlPanel then return self.controlPanel end

        local panelBg = GetColor("panelBackground")
        local panelBorder = GetColor("panelBorder")
        local headerBg = GetColor("headerBackground")
        local headerTxt = GetColor("headerText")
        local labelTxt = GetColor("labelText")
        local INNER_W = PANEL_W - 2 * PANEL_PAD

        local panel = CreateFrame("Frame", "WR_UIMoverPanel", UIParent)
        panel:SetSize(PANEL_W, 430)
        panel:SetPoint("RIGHT", UIParent, "RIGHT", -30, 0)
        panel:SetFrameStrata("TOOLTIP")
        -- above every handle (ANCHOR_LEVEL + one level per handle)
        panel:SetFrameLevel(2000)
        panel:SetMovable(true)
        panel:EnableMouse(true)
        panel:RegisterForDrag("LeftButton")
        panel:SetClampedToScreen(true)
        panel:SetScript("OnDragStart", panel.StartMoving)
        panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
        RC.UI:RegisterEscapeClose(panel)
        panel:HookScript("OnHide", function()
            if not UM.isMoving or UM.panelless then return end
            if RC._editModeDroveMover and EditModeManagerFrame
                    and EditModeManagerFrame:IsShown() then
                UM.panelless = true
                UM:HideGrid()
                if UM.editModeButton then UM.editModeButton:Show() end
            else
                -- The panel sits in UISpecialFrames, so ESC (or any
                -- CloseSpecialWindows cascade) hides it. This used to
                -- re-show the panel a frame later, which made ESC look
                -- like it flashed the window and did nothing. ESC now
                -- means what it means everywhere else: leave move mode,
                -- exactly as Save & Lock does, positions kept.
                C_Timer.After(0, function()
                    if UM._exiting then return end
                    if UM.isMoving and not UM.panelless
                       and UM.controlPanel and not UM.controlPanel:IsShown() then
                        UM:ExitMoveMode("escape")
                    end
                end)
            end
        end)

        panel.bg = FlatFill(panel, panelBg)
        panel.border = RC.UI:CreateSimpleBorder(panel)
        RC.UI:UpdateBorderColor(panel.border, panelBorder)

        -- Title bar: flat header fill, 1px gold rule along its bottom,
        -- 15px gold title, chromeless X at the right.
        local header = CreateFrame("Frame", nil, panel)
        header:SetHeight(TITLEBAR_H)
        header:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1)
        header:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -1, -1)
        local headerFill = FlatFill(header, headerBg)

        local accent = header:CreateTexture(nil, "ARTWORK")
        accent:SetTexture(FLAT)
        accent:SetHeight(1)
        accent:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
        accent:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
        local gold = RC:GetColor("ui", "accentGold")
        accent:SetVertexColor(gold.r, gold.g, gold.b, 0.6)
        -- the same header as every other Readycheck window: gradient fill,
        -- stepped rule, the sheen on opening and the living mark
        if RC.UI.ApplyHeaderArt then
            accent:Hide()
            RC.UI:ApplyHeaderArt(header, { fill = headerFill, stepX = 110 })
        end

        local titleIcon = RC.UI:AddTitleIcon(header, 16, 8)

        local title = RC:CreateFontString(header, "OVERLAY", nil, 15)
        title:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        title:SetText(RCL["Move UI"])
        title:SetTextColor(headerTxt.r, headerTxt.g, headerTxt.b, 1)

        local closeButton = RC.UI:CreateXCloseButton(header, 22, function()
            UM:ExitMoveMode("x button")
        end)
        closeButton:SetPoint("RIGHT", header, "RIGHT", -5, 0)

        local yPos = -(TITLEBAR_H + 1 + 10)

        -- "Frame" label over the dropdown; the selected frame's anchor
        -- point rides at the right of the same line.
        local selectLabel = RC:CreateFontString(panel, "OVERLAY", nil, 10)
        selectLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, yPos)
        selectLabel:SetText(RCL["Frame"])
        selectLabel:SetTextColor(labelTxt.r, labelTxt.g, labelTxt.b, 1)

        local selectedLabel = RC:CreateFontString(panel, "OVERLAY", nil, 10)
        selectedLabel:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PANEL_PAD, yPos)
        selectedLabel:SetJustifyH("RIGHT")
        selectedLabel:SetText("")
        local grayTxt = RC:GetColor("text", "gray")
        selectedLabel:SetTextColor(grayTxt.r, grayTxt.g, grayTxt.b, 1)
        panel.selectedLabel = selectedLabel
        yPos = yPos - 13

        local dropdownFrame = RC.UI:CreateScrollableDropdown(panel, INNER_W, RCL["-- Select Element --"], 10)
        dropdownFrame:SetEmptyText(RCL["Nothing movable yet"], RCL["Frames register here as you turn their features on."])
        dropdownFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, yPos)
        dropdownFrame:SetHeight(24)
        panel.dropdownFrame = dropdownFrame
        yPos = yPos - 24 - 10

        local ARROW_UP = "Interface\\AddOns\\Readycheck\\Media\\arrowUp"
        local ARROW_DOWN = "Interface\\AddOns\\Readycheck\\Media\\arrow"
        local ARROW_LEFT = "Interface\\AddOns\\Readycheck\\Media\\arrowLeft"

        local function CreateArrowButton(parent, direction, size)
            local btn = CreateFrame("Button", nil, parent)
            btn:SetSize(size, size)

            btn.bg = FlatFill(btn, GetColor("buttonBackground"))
            btn.border = RC.UI:CreateSimpleBorder(btn, 1)
            RC.UI:UpdateBorderColor(btn.border, GetColor("borderBlack"))

            local arrow = btn:CreateTexture(nil, "ARTWORK")
            arrow:SetSize(size - 12, size - 12)
            arrow:SetPoint("CENTER")

            if direction == "up" then
                arrow:SetTexture(ARROW_UP)
            elseif direction == "down" then
                arrow:SetTexture(ARROW_DOWN)
            elseif direction == "left" then
                arrow:SetTexture(ARROW_LEFT)
            elseif direction == "right" then
                arrow:SetTexture(ARROW_UP)
                arrow:SetRotation(-math.pi / 2)
            end
            local arrowNormal = GetColor("arrowNormal")
            arrow:SetVertexColor(arrowNormal.r, arrowNormal.g, arrowNormal.b, 1)
            btn.arrow = arrow

            btn:SetScript("OnEnter", function(self)
                local btnHoverBg = GetColor("buttonBackgroundHover")
                self.bg:SetVertexColor(btnHoverBg.r, btnHoverBg.g, btnHoverBg.b, btnHoverBg.a or 1)
                local arrowHover = GetColor("arrowHover")
                self.arrow:SetVertexColor(arrowHover.r, arrowHover.g, arrowHover.b, 1)
            end)
            btn:SetScript("OnLeave", function(self)
                local btnBg = GetColor("buttonBackground")
                self.bg:SetVertexColor(btnBg.r, btnBg.g, btnBg.b, btnBg.a or 1)
                local arrowNormal = GetColor("arrowNormal")
                self.arrow:SetVertexColor(arrowNormal.r, arrowNormal.g, arrowNormal.b, 1)
            end)

            return btn
        end

        -- One axis: a 10px label over a 24px strip of
        -- [arrow][flat value box][arrow]. Returns the EditBox.
        local COL_GAP = 8
        local COL_W = math.floor((INNER_W - COL_GAP) / 2)
        local STRIP_H = 24
        local function CreateAxisStrip(x, y, axisLabel, negDir, posDir, onNeg, onPos)
            local lbl = RC:CreateFontString(panel, "OVERLAY", nil, 10)
            lbl:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
            lbl:SetText(axisLabel)
            lbl:SetTextColor(labelTxt.r, labelTxt.g, labelTxt.b, 1)

            local sy = y - 13
            local negBtn = CreateArrowButton(panel, negDir, STRIP_H)
            negBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", x, sy)
            negBtn:SetScript("OnClick", onNeg)

            local box = CreateFrame("Frame", nil, panel)
            box:SetSize(COL_W - 2 * STRIP_H - 4, STRIP_H)
            box:SetPoint("LEFT", negBtn, "RIGHT", 2, 0)
            box.bg = FlatFill(box, GetColor("inputBackground"))
            box.border = RC.UI:CreateSimpleBorder(box)
            RC.UI:UpdateBorderColor(box.border, GetColor("borderBlack"))

            local input = CreateFrame("EditBox", nil, box)
            input:SetPoint("TOPLEFT", box, "TOPLEFT", 4, 0)
            input:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -4, 0)
            input:SetAutoFocus(false)
            input:SetNumeric(false)
            input:SetMaxLetters(7)
            input:SetJustifyH("CENTER")
            if RC.ApplyCustomFont then RC:ApplyCustomFont(input, 11) end
            local whiteText = GetColor("whiteText")
            input:SetTextColor(whiteText.r, whiteText.g, whiteText.b, 1)
            input:SetText("0")
            input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
            -- Focus lights the box gold; it is the only affordance a flat
            -- box has for "you are typing here".
            input:SetScript("OnEditFocusGained", function()
                RC.UI:UpdateBorderColor(box.border, RC:GetColor("ui", "borderHover"))
            end)
            input:SetScript("OnEditFocusLost", function()
                RC.UI:UpdateBorderColor(box.border, GetColor("borderBlack"))
            end)

            local posBtn = CreateArrowButton(panel, posDir, STRIP_H)
            posBtn:SetPoint("LEFT", box, "RIGHT", 2, 0)
            posBtn:SetScript("OnClick", onPos)

            return input
        end

        panel.xInput = CreateAxisStrip(PANEL_PAD, yPos, RCL["X"], "left", "right",
            function() UM:NudgePosition(-1, 0) end,
            function() UM:NudgePosition(1, 0) end)
        panel.yInput = CreateAxisStrip(PANEL_PAD + COL_W + COL_GAP, yPos, RCL["Y"], "down", "up",
            function() UM:NudgePosition(0, -1) end,
            function() UM:NudgePosition(0, 1) end)
        yPos = yPos - 13 - STRIP_H - 10

        -- Apply / Reset / Reset all: three equal buttons across the row.
        local BTN_GAP = 4
        local BTN_W = math.floor((INNER_W - 2 * BTN_GAP) / 3)
        local BTN_H = 22

        local applyBtn = RC.UI:CreateStyledButton(panel, RCL["Apply"], BTN_W, BTN_H)
        applyBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, yPos)
        applyBtn:SetScript("OnClick", function()
            UM:ApplyCoordinates()
        end)

        local resetBtn = RC.UI:CreateStyledButton(panel, RCL["Reset"], BTN_W, BTN_H)
        resetBtn:SetPoint("LEFT", applyBtn, "RIGHT", BTN_GAP, 0)
        resetBtn:SetScript("OnClick", function()
            if UM.selectedFrame then
                UM:ResetFramePosition(UM.selectedFrame)
                UM:UpdateCoordinateInputs(UM.selectedFrame)
            end
        end)

        local resetAllBtn = RC.UI:CreateStyledButton(panel, RCL["Reset all"], INNER_W - 2 * (BTN_W + BTN_GAP), BTN_H)
        resetAllBtn:SetPoint("LEFT", resetBtn, "RIGHT", BTN_GAP, 0)
        if resetAllBtn.text then
            local red = RC:GetColor("text", "red")
            resetAllBtn.text:SetTextColor(red.r, red.g, red.b, 1)
        end
        resetAllBtn:SetScript("OnClick", function()
            for frameKey, _ in pairs(UM.frames) do
                UM:ResetFramePosition(frameKey)
            end
            if UM.selectedFrame then
                UM:UpdateCoordinateInputs(UM.selectedFrame)
            end
        end)
        yPos = yPos - BTN_H - 6

        -- The list of every frame, with a tick to hide each one while
        -- moving (see SHOW / HIDE WHILE MOVING below).
        local visBtn = RC.UI:CreateStyledButton(panel, RCL["Show / hide frames"], INNER_W, BTN_H)
        visBtn:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, yPos)
        visBtn:SetScript("OnClick", function()
            UM:ToggleVisibilityList()
        end)
        panel.visBtn = visBtn
        yPos = yPos - BTN_H - 10

        local divider = panel:CreateTexture(nil, "ARTWORK")
        divider:SetTexture(FLAT)
        divider:SetHeight(1)
        divider:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, yPos)
        divider:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -PANEL_PAD, yPos)
        local divCol = RC:GetColor("ui", "borderNormal")
        divider:SetVertexColor(divCol.r, divCol.g, divCol.b, divCol.a or 1)
        yPos = yPos - 1 - 10

        -- A slider row: 60px label at the left, the slider filling the
        -- middle, its value text at the right. The value/edit containers
        -- are only re-anchored when the helper keeps them as separate
        -- frames; otherwise the helper's own placement stands.
        local SLIDER_ROW_H = 30
        local SLIDER_LABEL_W = 60
        local SLIDER_VALUE_W = 44
        local function LayoutSliderRow(y, labelText, slider)
            local row = CreateFrame("Frame", nil, panel)
            row:SetSize(INNER_W, SLIDER_ROW_H)
            row:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, y)

            local lbl = RC:CreateFontString(row, "OVERLAY", nil, 10)
            lbl:SetPoint("LEFT", row, "LEFT", 0, 0)
            lbl:SetWidth(SLIDER_LABEL_W)
            lbl:SetText(labelText)
            lbl:SetTextColor(labelTxt.r, labelTxt.g, labelTxt.b, 1)

            local host = slider.parentFrame
            if host then
                host:SetSize(INNER_W - SLIDER_LABEL_W - SLIDER_VALUE_W, SLIDER_ROW_H)
            end
            slider:SetPoint("LEFT", row, "LEFT", SLIDER_LABEL_W, 0)

            local function ParkRight(f)
                if f and f ~= host and f ~= slider then
                    f:ClearAllPoints()
                    f:SetSize(SLIDER_VALUE_W, 20)
                    f:SetPoint("RIGHT", row, "RIGHT", 0, 0)
                end
            end
            ParkRight(slider.Text and slider.Text:GetParent())
            ParkRight(slider.editBox and slider.editBox:GetParent())
            return row
        end

        local gridCheckbox = RC.UI:CreateCheckbox(panel, RCL["Show alignment grid"], UM.showGrid)
        gridCheckbox.parentFrame:SetSize(INNER_W, 14)
        gridCheckbox.parentFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, yPos)

        gridCheckbox:SetScript("OnClick", function(self)
            UM.showGrid = self:GetChecked() and true or false
            if UM.showGrid then
                if UM.isMoving then
                    UM:ShowGrid()
                end
            else
                UM:HideGrid()
            end
        end)

        panel.gridCheckbox = gridCheckbox
        yPos = yPos - 14 - 8

        local gridSizeSlider = RC.UI:CreateSlider(panel, 10, 100, UM.gridSize, 5)
        gridSizeSlider.Text:SetText(UM.gridSize .. RCL["px"])
        gridSizeSlider:SetScript("OnValueChanged", function(slider, value)
            value = math.floor(value)
            UM.gridSize = value
            slider.Text:SetText(value .. RCL["px"])
            if UM.isMoving and UM.showGrid then
                -- Re-lays out the one pooled grid frame at the new size;
                -- the frame and its line textures are reused, not recreated.
                UM:ShowGrid()
            end
        end)
        LayoutSliderRow(yPos, RCL["Grid"], gridSizeSlider)
        yPos = yPos - SLIDER_ROW_H - 6

        local snapCheckbox = RC.UI:CreateCheckbox(panel, RCL["Snap to grid while dragging"], UM.snapEnabled)
        snapCheckbox.parentFrame:SetSize(INNER_W, 14)
        snapCheckbox.parentFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, yPos)

        snapCheckbox:SetScript("OnClick", function(self)
            UM.snapEnabled = self:GetChecked() and true or false
        end)

        panel.snapCheckbox = snapCheckbox
        yPos = yPos - 14 - 8

        local snapSizeSlider = RC.UI:CreateSlider(panel, 2, 50, UM.snapSize, 1)
        snapSizeSlider.Text:SetText(UM.snapSize .. RCL["px"])
        snapSizeSlider:SetScript("OnValueChanged", function(slider, value)
            value = math.floor(value)
            if value < 1 then value = 1 end
            UM.snapSize = value
            slider.Text:SetText(value .. RCL["px"])
        end)
        LayoutSliderRow(yPos, RCL["Snap"], snapSizeSlider)
        yPos = yPos - SLIDER_ROW_H - 8

        local infoText = RC:CreateFontString(panel, "OVERLAY", nil, 10)
        infoText:SetPoint("TOPLEFT", panel, "TOPLEFT", PANEL_PAD, yPos)
        infoText:SetWidth(INNER_W)
        infoText:SetJustifyH("LEFT")
        infoText:SetText(RCL["|cff888888Click anchors or dropdown to select.\nDrag anchors to move. Right-click to reset.\nShift+Right-click to hide one while you move the rest.\nEnter exact X/Y values and click Apply.|r"])

        -- Save & lock: the one "positive" fill on the panel - green fill
        -- with a gold ring, full width along the bottom.
        local saveBtn = RC.UI:CreateStyledButton(panel, RCL["Save & lock"], INNER_W, 26)
        saveBtn:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", PANEL_PAD, PANEL_PAD)
        saveBtn:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -PANEL_PAD, PANEL_PAD)
        saveBtn:SetScript("OnClick", function()
            UM:ExitMoveMode("save & lock")
        end)
        if RC.UI.SetButtonConfigured then
            RC.UI:SetButtonConfigured(saveBtn, true)
        end
        if saveBtn.bg then
            local saveBtnBg = GetColor("saveButtonBg")
            saveBtn.bg:SetVertexColor(saveBtnBg.r, saveBtnBg.g, saveBtnBg.b, 1)
        end
        saveBtn:SetScript("OnEnter", function(self)
            if self.bg then
                local saveBtnHover = GetColor("saveButtonBgHover")
                self.bg:SetVertexColor(saveBtnHover.r, saveBtnHover.g, saveBtnHover.b, 1)
            end
        end)
        saveBtn:SetScript("OnLeave", function(self)
            if self.bg then
                local saveBtnBg = GetColor("saveButtonBg")
                self.bg:SetVertexColor(saveBtnBg.r, saveBtnBg.g, saveBtnBg.b, 1)
            end
        end)

        -- the 5.0 popup header (UIF_Dialogs); the panel keeps its own
        -- Move UI colours and buttons
        RC.UI:SkinPopup(panel, { header = header, title = title, close = closeButton, chrome = false, scan = false })
        panel:Hide()
        self.controlPanel = panel

        return panel
    end

    function UM:InitializeDropdown()
        if not self.controlPanel or not self.controlPanel.dropdownFrame then return end
        local dd = self.controlPanel.dropdownFrame
        local items = {}
        for frameKey, data in pairs(self.frames) do
            items[#items + 1] = { text = data.displayName, value = frameKey }
        end
        table.sort(items, function(a, b) return a.text < b.text end)
        dd:SetItems(items, function(value)
            UM:SelectFrame(value)
        end)
    end

    function UM:SelectFrame(frameKey)
        self.selectedFrame = frameKey
        local data = self.frames[frameKey]
        if not data then return end

        if self.controlPanel and self.controlPanel.dropdownFrame then
            local dd = self.controlPanel.dropdownFrame
            if dd.text then dd.text:SetText(data.displayName) end
        end

        self:UpdateCoordinateInputs(frameKey)

        self:HighlightAnchor(frameKey)
    end

    function UM:UpdateCoordinateInputs(frameKey)
        if not self.controlPanel then return end
        local data = self.frames[frameKey]
        if not data or not data.frame then return end
        local point, x, y = Readout(data)
        self.controlPanel.xInput:SetText(FmtCoord(x))
        self.controlPanel.yInput:SetText(FmtCoord(y))
        -- The dropdown already names the frame; the label only carries
        -- the anchor point the numbers are relative to.
        if self.controlPanel.selectedLabel then
            self.controlPanel.selectedLabel:SetText(point)
        end
    end

    -- Refuses (and says why, in debug) while the frame is combat-locked.
    function UM:RefuseLocked(frameKey)
        if not self:IsLocked(frameKey) then return false end
        if RC.DebugPrint then
            RC:DebugPrint("Mover: '" .. tostring(frameKey) .. "' is locked in combat", "uimover")
        end
        return true
    end

    function UM:ApplyCoordinates()
        if not self.selectedFrame or not self.controlPanel then return end
        if self:RefuseLocked(self.selectedFrame) then
            self:UpdateCoordinateInputs(self.selectedFrame)
            return
        end
        local data = self.frames[self.selectedFrame]
        if not data or not data.frame then return end
        SetStored(data,
            tonumber(self.controlPanel.xInput:GetText()) or 0,
            tonumber(self.controlPanel.yInput:GetText()) or 0)
        self:UpdateCoordinateInputs(self.selectedFrame)
    end

    -- One arrow press = one UI unit.
    function UM:NudgePosition(deltaX, deltaY)
        if not self.selectedFrame or not self.controlPanel then return end
        if self:RefuseLocked(self.selectedFrame) then return end
        local data = self.frames[self.selectedFrame]
        if not data or not data.frame then return end
        local _, x, y = Readout(data)
        SetStored(data, x + deltaX, y + deltaY)
        self:UpdateCoordinateInputs(self.selectedFrame)
    end

    function UM:HighlightAnchor(frameKey)
        local normalBg = GetColor("anchorBackground")
        local normalBorder = GetColor("anchorBorder")
        local selectedBg = GetColor("anchorSelected")
        local selectedBorder = GetColor("anchorSelectedBorder")

        for key, data in pairs(self.frames) do
            if data.anchor then
                if key == frameKey then
                    data.anchor.bg:SetColorTexture(selectedBg.r, selectedBg.g, selectedBg.b, selectedBg.a)
                    if data.anchor.border then
                        data.anchor.border.top:SetColorTexture(selectedBorder.r, selectedBorder.g, selectedBorder.b, selectedBorder.a)
                        data.anchor.border.bottom:SetColorTexture(selectedBorder.r, selectedBorder.g, selectedBorder.b, selectedBorder.a)
                        data.anchor.border.left:SetColorTexture(selectedBorder.r, selectedBorder.g, selectedBorder.b, selectedBorder.a)
                        data.anchor.border.right:SetColorTexture(selectedBorder.r, selectedBorder.g, selectedBorder.b, selectedBorder.a)
                    end
                else
                    data.anchor.bg:SetColorTexture(normalBg.r, normalBg.g, normalBg.b, normalBg.a)
                    if data.anchor.border then
                        data.anchor.border.top:SetColorTexture(normalBorder.r, normalBorder.g, normalBorder.b, normalBorder.a)
                        data.anchor.border.bottom:SetColorTexture(normalBorder.r, normalBorder.g, normalBorder.b, normalBorder.a)
                        data.anchor.border.left:SetColorTexture(normalBorder.r, normalBorder.g, normalBorder.b, normalBorder.a)
                        data.anchor.border.right:SetColorTexture(normalBorder.r, normalBorder.g, normalBorder.b, normalBorder.a)
                    end
                end
                -- a locked handle keeps its red edge whichever is selected
                if data.anchor._locked and UM.PaintLock then UM.PaintLock(data) end
            end
        end
    end

    -- The blue line is drawn just OUTSIDE the rect it marks, one unit
    -- all round, so it hugs the frame's edge without covering the
    -- frame's own border. The overlay's centre is the frame's centre,
    -- which is all the drop math uses, so the extra unit changes nothing.
    local BOX_PAD = 1

    -- A bar that has hidden its background and border shows nothing but
    -- its buttons; the box follows what is visible.
    local function VisibleBounds(frame)
        if RC.Position and RC.Position.VisibleBounds then return RC.Position.VisibleBounds(frame) end
        local bd = frame.border
        if not (bd and bd.top and not bd.top:IsShown()) then return nil end
        local l, r, t, b
        for _, c in ipairs({ frame:GetChildren() }) do
            if c:IsShown() and c:GetLeft() then
                local cl, cr, ct, cb = c:GetLeft(), c:GetRight(), c:GetTop(), c:GetBottom()
                l = (l and math.min(l, cl)) or cl
                r = (r and math.max(r, cr)) or cr
                t = (t and math.max(t, ct)) or ct
                b = (b and math.min(b, cb)) or cb
            end
        end
        if l and r > l and t > b then return l, r, t, b end
        return nil
    end

    -- Insets are (frame edge - content edge) per side: a rect larger than
    -- its visible content loosens the clamp by the invisible margin, a
    -- dock group whose children reach past the root tightens it. Same
    -- units as the frame's own rect.
    ClampToContent = function(frame, slots)
        local P = RC.Position
        if not (P and P.ClampToContent) then return ClampFrame(frame) end
        if not (slots and frame and frame.GetLeft and frame:GetLeft()) then
            return P.ClampToContent(frame)
        end
        -- Dock group: the content rect is every button in the group.
        local cl, cr, ct, cb = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
        local GM = RC.GearManager
        if GM and GM.buttons then
            for _, s in ipairs(slots) do
                local b = GM.buttons[s]
                if b and b.GetLeft and b:GetLeft() and b:IsShown() then
                    cl = math.min(cl, b:GetLeft())
                    cr = math.max(cr, b:GetRight())
                    ct = math.max(ct, b:GetTop())
                    cb = math.min(cb, b:GetBottom())
                end
            end
        end
        P.ClampToContent(frame, cl, cr, ct, cb)
    end

    local function FitAnchorToFrame(anchor, frame)
        local k = ScaleK(frame)
        local w, h, offX, offY = frame:GetWidth() or 0, frame:GetHeight() or 0, 0, 0
        local l, r, t, b = VisibleBounds(frame)
        if l then
            local cx, cy = frame:GetCenter()
            w, h = r - l, t - b
            offX, offY = (l + r) / 2 - cx, (t + b) / 2 - cy
        end
        anchor:SetSize(w / k + 2 * BOX_PAD, h / k + 2 * BOX_PAD)
        anchor:ClearAllPoints()
        anchor:SetPoint("CENTER", frame, "CENTER", offX / k, offY / k)
        anchor.contentOffX, anchor.contentOffY = offX / k, offY / k
    end

    -- Dock groups: the box is the exact bounding rect of every button in
    -- the group, offset from the root button so the drop math is exact.
    local function FitAnchorToDockGroup(anchor, parentBtn, slots)
        local GM = RC.GearManager
        if not GM or not GM.buttons or not parentBtn or not slots then return false end
        local minL, maxR, maxT, minB
        for _, s in ipairs(slots) do
            local b = GM.buttons[s]
            if b and b.GetLeft and b:GetLeft() and b:IsShown() then
                local l, r, t, bm = b:GetLeft(), b:GetRight(), b:GetTop(), b:GetBottom()
                minL = (minL and math.min(minL, l)) or l
                maxR = (maxR and math.max(maxR, r)) or r
                maxT = (maxT and math.max(maxT, t)) or t
                minB = (minB and math.min(minB, bm)) or bm
            end
        end
        if not (minL and maxR and maxT and minB) then return false end
        local pcx, pcy = parentBtn:GetCenter()
        if not pcx or not pcy then return false end
        local offX = ((minL + maxR) / 2) - pcx
        local offY = ((minB + maxT) / 2) - pcy
        anchor:SetSize((maxR - minL) + 2 * BOX_PAD, (maxT - minB) + 2 * BOX_PAD)
        anchor:ClearAllPoints()
        anchor:SetPoint("CENTER", parentBtn, "CENTER", offX, offY)
        anchor.contentOffX, anchor.contentOffY = offX, offY
        return true
    end

    -- The convention a frame's numbers are in: its pinned point and the
    -- UIParent point they are measured from. RC.Position frames pin their
    -- own point at UIParent's CENTER; a frame registered with opts.point
    -- uses that pair (the spec popup: TOP at TOP); anything else CENTER.
    local function Convention(data)
        local P = RC.Position
        if P and P.IsBound(data.frame) then return data.frame.__rcPos.point, "CENTER" end
        if data.convPoint then return data.convPoint, data.convRel or data.convPoint end
        return "CENTER", "CENTER"
    end

    local FXF = { TOPLEFT = 0, LEFT = 0, BOTTOMLEFT = 0, TOP = 0.5, CENTER = 0.5, BOTTOM = 0.5,
                  TOPRIGHT = 1, RIGHT = 1, BOTTOMRIGHT = 1 }
    local FYF = { TOPLEFT = 1, TOP = 1, TOPRIGHT = 1, LEFT = 0.5, CENTER = 0.5, RIGHT = 0.5,
                  BOTTOMLEFT = 0, BOTTOM = 0, BOTTOMRIGHT = 0 }

    -- Where `point` of a frame whose CENTER sits at screen-centre offsets
    -- (fx, fy) lands, measured from UIParent's `relPoint`; all in the
    -- frame's own units (what its SetPoint, and so its save, wants).
    local function PointFromCenter(frame, point, relPoint, fx, fy)
        local k = ScaleK(frame)
        local w, h = frame:GetWidth() or 0, frame:GetHeight() or 0
        local W, H = UIParent:GetWidth() * k, UIParent:GetHeight() * k
        local x = fx + ((FXF[point] or 0.5) - 0.5) * w - ((FXF[relPoint] or 0.5) - 0.5) * W
        local y = fy + ((FYF[point] or 0.5) - 0.5) * h - ((FYF[relPoint] or 0.5) - 0.5) * H
        return x, y
    end
    UM.PointFromCenter = PointFromCenter

    local function FormatReadout(point, x, y)
        return point .. "  X: " .. FmtCoord(x) .. "  Y: " .. FmtCoord(y)
    end

    -- What the panel shows and what gets saved: the bound point's offsets
    -- for RC.Position frames, the frame's own convention for frames
    -- registered with one, CENTER offsets for everything else.
    Readout = function(data)
        local frame = data.frame
        local P = RC.Position
        if P and P.IsBound(frame) then
            local b = frame.__rcPos
            local st = b.getStore()
            if st and st[b.markKey] and type(st[b.xKey]) == "number" and type(st[b.yKey]) == "number" then
                return b.point, st[b.xKey], st[b.yKey]
            end
            local x, y = P.Capture(frame, b.point)
            return b.point, x or 0, y or 0
        end
        local x, y = FrameCenter(frame)
        if data.convPoint then
            local point, rel = Convention(data)
            local px, py = PointFromCenter(frame, point, rel, x, y)
            return point, px, py
        end
        return "CENTER", x, y
    end
    UM.Readout = Readout

    -- COMBAT. A secure frame - a gear button, or a bar that holds secure
    -- buttons (the client protects the parent too) - cannot be anchored in
    -- combat, so its handle is locked: no drag starts, the panel's arrows,
    -- Apply and Reset leave it alone, and the handle says so. A drop that
    -- lands in combat (the drag began before it) is kept and put down the
    -- moment combat ends.
    -- PLAYER_REGEN_DISABLED fires just before the lockdown starts, so
    -- the flag counts that moment as combat already.
    local function InCombat()
        return (UM._inCombat or InCombatLockdown()) and true or false
    end

    local function FrameProtected(data)
        local f = data.frame
        if f and f.IsProtected and f:IsProtected() then return true end
        if data.groupSlots then
            local GM = RC.GearManager
            for _, s in ipairs(data.groupSlots) do
                local b = GM and GM.buttons and GM.buttons[s]
                if b and b.IsProtected and b:IsProtected() then return true end
            end
        end
        return false
    end

    function UM:IsLocked(frameKey)
        local data = self.frames[frameKey]
        return (data and InCombat() and FrameProtected(data)) and true or false
    end

    -- Small handles carry their name above the box and the numbers under
    -- it, on a dark plate, so neither is squeezed into (or past) the box.
    local function LayoutTexts(anchor)
        local label, pos = anchor.label, anchor.posText
        if not (label and pos) then return end
        local w, h = anchor:GetWidth() or 0, anchor:GetHeight() or 0
        local need = math.max(label:GetStringWidth() or 0, pos:GetStringWidth() or 0) + 8
        local inside = w >= need and h >= 30
        if anchor._textsInside == inside then return end
        anchor._textsInside = inside
        label:ClearAllPoints()
        pos:ClearAllPoints()
        if inside then
            label:SetPoint("CENTER", anchor, "CENTER", 0, 7)
            pos:SetPoint("CENTER", anchor, "CENTER", 0, -8)
        else
            label:SetPoint("BOTTOM", anchor, "TOP", 0, 4)
            pos:SetPoint("TOP", anchor, "BOTTOM", 0, -4)
        end
        if anchor.labelPlate then anchor.labelPlate:SetShown(not inside) end
        if anchor.posPlate then anchor.posPlate:SetShown(not inside) end
    end
    UM.LayoutTexts = LayoutTexts

    -- Border, lock line and level-independent look of one handle: red and
    -- "Locked in combat" while its frame cannot move.
    local function PaintLock(data)
        local anchor = data.anchor
        if not anchor then return end
        local locked = InCombat() and FrameProtected(data)
        anchor._locked = locked or nil
        if anchor.lockText then
            if data._pending then
                anchor.lockText:SetText(RCL["Moves when combat ends"])
            else
                anchor.lockText:SetText(RCL["Locked in combat"])
            end
            anchor.lockText:SetShown((locked or data._pending) and true or false)
        end
        if anchor.border then
            if locked then
                RC.UI:UpdateBorderColor(anchor.border, RC:GetColor("text", "red"))
            else
                local key = (UM.selectedFrame == anchor.frameKey) and "anchorSelectedBorder" or "anchorBorder"
                RC.UI:UpdateBorderColor(anchor.border, GetColor(key))
            end
        end
    end
    UM.PaintLock = PaintLock

    -- The overlay is re-anchored to its frame after every move, so the
    -- box and the frame can never disagree.
    AttachAnchor = function(data)
        local anchor = data.anchor
        if not anchor or not data.frame then return end
        if data._pending then return end   -- stays where it was dropped until combat ends
        FitAnchorToFrame(anchor, data.frame)
        if data.groupSlots then
            anchor._groupSlots = data.groupSlots
            FitAnchorToDockGroup(anchor, data.frame, data.groupSlots)
        end
        ClampToContent(data.frame, data.groupSlots)
        if anchor.posText then
            local point, x, y = Readout(data)
            anchor.posText:SetText(FormatReadout(point, x, y))
        end
        LayoutTexts(anchor)
    end

    -- Saves whatever the frame's stored form is; whole units.
    local function Commit(data)
        local frame = data.frame
        local P = RC.Position
        if P and P.IsBound(frame) then
            local x, y = P.Capture(frame, frame.__rcPos.point)
            if x then P.SetFrame(frame, Round(x), Round(y)) end
        elseif data.convPoint then
            local point, rel = Convention(data)
            local fx, fy = FrameCenter(frame)
            local x, y = PointFromCenter(frame, point, rel, fx, fy)
            x, y = Round(x), Round(y)
            frame:ClearAllPoints()
            frame:SetPoint(point, UIParent, rel, x, y)
            if data.saveCallback then data.saveCallback(x, y) end
        else
            local x, y = FrameCenter(frame)
            x, y = Round(x), Round(y)
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
            if data.saveCallback then data.saveCallback(x, y) end
        end
        AttachAnchor(data)
    end

    -- Puts the frame's CENTER at screen-centre offsets (cx, cy) and saves.
    -- In combat a secure frame keeps the drop for later (see COMBAT).
    MoveCenter = function(data, cx, cy)
        if InCombat() and FrameProtected(data) then
            data._pending = { cx, cy }
            PaintLock(data)
            return
        end
        data.frame:ClearAllPoints()
        data.frame:SetPoint("CENTER", UIParent, "CENTER", cx, cy)
        Commit(data)
    end

    -- Sets the stored coordinates directly (panel inputs, nudge arrows).
    SetStored = function(data, x, y)
        local frame = data.frame
        local P = RC.Position
        if P and P.IsBound(frame) then
            P.SetFrame(frame, x, y)
            AttachAnchor(data)
        elseif data.convPoint then
            local point, rel = Convention(data)
            frame:ClearAllPoints()
            frame:SetPoint(point, UIParent, rel, x, y)
            Commit(data)
        else
            MoveCenter(data, x, y)
        end
    end

    ResetStored = function(data)
        local frame = data.frame
        local P = RC.Position
        if P and P.IsBound(frame) then
            P.ResetFrame(frame)
            AttachAnchor(data)
        elseif data.onReset then
            data.onReset()
            AttachAnchor(data)
        else
            local def = data.defaultPos
            frame:ClearAllPoints()
            frame:SetPoint(def.point or "CENTER", UIParent, def.relPoint or "CENTER", def.x or 0, def.y or 0)
            Commit(data)
        end
    end

    -- Combat over: put down every drop that waited, repaint the locks.
    function UM:OnCombatEnd()
        for _, data in pairs(self.frames) do
            local p = data._pending
            if p then
                data._pending = nil
                if data.frame then MoveCenter(data, p[1], p[2]) end
            end
            if data._hideAfterCombat then
                data._hideAfterCombat = nil
                if data.frame and not self.isMoving then data.frame:Hide() end
            end
            PaintLock(data)
        end
        if self.isMoving and self.selectedFrame then self:UpdateCoordinateInputs(self.selectedFrame) end
    end

    function UM:OnCombatStart()
        if not self.isMoving then return end
        for _, data in pairs(self.frames) do PaintLock(data) end
    end

    do
        local combatWatch = CreateFrame("Frame")
        combatWatch:RegisterEvent("PLAYER_REGEN_DISABLED")
        combatWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
        combatWatch:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_REGEN_DISABLED" then
                UM._inCombat = true
                UM:OnCombatStart()
            else
                UM._inCombat = nil
                UM:OnCombatEnd()
            end
        end)
    end

    function UM:CreateAnchor(frameKey)
        local data = self.frames[frameKey]
        if not data or not data.frame then return nil end

        local frame = data.frame
        local anchorBg = GetColor("anchorBackground")
        local anchorBorder = GetColor("anchorBorder")
        local anchorTxt = GetColor("anchorText")
        local anchorPos = GetColor("anchorPosText")

        local anchor = CreateFrame("Frame", "WR_Anchor_" .. frameKey, UIParent)
        anchor:SetFrameStrata("TOOLTIP")
        anchor:SetFrameLevel(10)

        -- Flat fill + 1px ring; HighlightAnchor swaps both to the
        -- selected pair, so the textures stay colour-swappable.
        anchor.bg = anchor:CreateTexture(nil, "BACKGROUND")
        anchor.bg:SetAllPoints()
        anchor.bg:SetColorTexture(anchorBg.r, anchorBg.g, anchorBg.b, anchorBg.a)

        anchor.border = RC.UI:CreateSimpleBorder(anchor, 1)
        RC.UI:UpdateBorderColor(anchor.border, anchorBorder)

        local label = RC:CreateFontString(anchor, "OVERLAY", nil, 12)
        label:SetPoint("CENTER", anchor, "CENTER", 0, 7)
        label:SetJustifyH("CENTER")
        label:SetText(data.displayName)
        label:SetTextColor(anchorTxt.r, anchorTxt.g, anchorTxt.b, 1)
        anchor.label = label

        local posText = RC:CreateFontString(anchor, "OVERLAY", nil, 10)
        posText:SetPoint("CENTER", anchor, "CENTER", 0, -8)
        posText:SetJustifyH("CENTER")
        posText:SetTextColor(anchorPos.r, anchorPos.g, anchorPos.b, 1)
        anchor.posText = posText

        -- Dark plates behind the name and numbers when a small handle
        -- carries them outside its box (LayoutTexts).
        local plateCol = GetColor("panelBackground")
        local function Plate(fs)
            local t = anchor:CreateTexture(nil, "BORDER")
            t:SetColorTexture(plateCol.r, plateCol.g, plateCol.b, 0.85)
            t:SetPoint("TOPLEFT", fs, "TOPLEFT", -3, 2)
            t:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 3, -2)
            t:Hide()
            return t
        end
        anchor.labelPlate = Plate(label)
        anchor.posPlate = Plate(posText)

        -- "Locked in combat" / "Moves when combat ends", over the box.
        local lockText = RC:CreateFontString(anchor, "OVERLAY", nil, 10)
        lockText:SetPoint("BOTTOM", label, "TOP", 0, 2)
        local red = RC:GetColor("text", "red")
        lockText:SetTextColor(red.r, red.g, red.b, 1)
        lockText:Hide()
        anchor.lockText = lockText

        anchor:SetMovable(true)
        anchor:EnableMouse(true)
        anchor:RegisterForDrag("LeftButton")
        -- The box overhangs the frame by BOX_PAD; let exactly that much
        -- cross the edge so the frame itself can reach it.
        ClampFrame(anchor, BOX_PAD, -BOX_PAD, -BOX_PAD, BOX_PAD)

        anchor.frameKey = frameKey
        anchor.targetFrame = frame
        data.anchor = anchor
        AttachAnchor(data)

        anchor:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                UM:SelectFrame(self.frameKey)
                -- a secure frame cannot move in combat: no drag starts
                if UM:IsLocked(self.frameKey) then return end
                self:StartMoving()
                self.isDragging = true
            end
        end)

        anchor:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" and self.isDragging then
                self:StopMovingOrSizing()
                self.isDragging = false
                UM:SaveFramePosition(self.frameKey, self)
                UM:UpdateCoordinateInputs(self.frameKey)
            elseif button == "RightButton" and IsShiftKeyDown() then
                GameTooltip:Hide()
                UM:SetFrameHidden(self.frameKey, true)
            elseif button == "RightButton" then
                UM:ResetFramePosition(self.frameKey)
                UM:UpdateCoordinateInputs(self.frameKey)
            end
        end)

        -- Live readout while dragging: where the frame will land, in the
        -- same point and numbers its settings show (and the drop saves).
        anchor:SetScript("OnUpdate", function(self)
            if not self.isDragging or not self.posText then return end
            local x, y = FrameCenter(self)
            x, y = x - (self.contentOffX or 0), y - (self.contentOffY or 0)
            if UM.snapEnabled and UM.snapSize and UM.snapSize > 0 then
                local g = UM.snapSize
                local sx, sy = Round(x / g) * g, Round(y / g) * g
                -- An axis resting on the screen edge stays there; the grid
                -- must not pull it back in.
                local ex, ey = UM.EdgeContact(self)
                if ex then sx = x end
                if ey then sy = y end
                if sx ~= x or sy ~= y then
                    self:ClearAllPoints()
                    self:SetPoint("CENTER", UIParent, "CENTER",
                        sx + (self.contentOffX or 0), sy + (self.contentOffY or 0))
                    x, y = sx, sy
                end
            end
            local d = UM.frames[self.frameKey]
            if not (d and d.frame) then return end
            local k = ScaleK(d.frame)
            local point, rel = Convention(d)
            local px, py = PointFromCenter(d.frame, point, rel, x * k, y * k)
            self.posText:SetText(FormatReadout(point, Round(px), Round(py)))
        end)

        anchor:SetScript("OnEnter", function(self)
            local d = UM.frames[self.frameKey]
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            local nameCol = GetColor("anchorText")
            GameTooltip:AddLine((d and d.displayName) or "", nameCol.r, nameCol.g, nameCol.b)
            local tooltipText = GetColor("tooltipText")
            if d and d.frame then
                local point, x, y = Readout(d)
                local posCol = GetColor("anchorPosText")
                GameTooltip:AddLine(FormatReadout(point, x, y), posCol.r, posCol.g, posCol.b)
            end
            if UM:IsLocked(self.frameKey) then
                local red = RC:GetColor("text", "red")
                GameTooltip:AddLine(RCL["Locked in combat: it can be moved again when combat ends."], red.r, red.g, red.b, true)
            end
            GameTooltip:AddLine(RCL["Left-click: Select & drag"], tooltipText.r, tooltipText.g, tooltipText.b)
            GameTooltip:AddLine(RCL["Right-click: Reset position"], tooltipText.r, tooltipText.g, tooltipText.b)
            GameTooltip:AddLine(RCL["Shift+Right-click: Hide while moving"], tooltipText.r, tooltipText.g, tooltipText.b)
            GameTooltip:Show()
        end)

        anchor:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        anchor:Hide()
        return anchor
    end

    -- Drop: the frame's CENTER goes where the overlay's centre is, less
    -- the overlay's content offset.
    function UM:SaveFramePosition(frameKey, anchor)
        local data = self.frames[frameKey]
        if not data or not data.frame then return end
        local cx, cy = FrameCenter(anchor)
        cx, cy = cx - (anchor.contentOffX or 0), cy - (anchor.contentOffY or 0)
        if self.snapEnabled and self.snapSize and self.snapSize > 0 then
            local g = self.snapSize
            local ex, ey = UM.EdgeContact(anchor)
            if not ex then cx = Round(cx / g) * g end
            if not ey then cy = Round(cy / g) * g end
        end
        local k = ScaleK(data.frame)
        MoveCenter(data, cx * k, cy * k)
    end

    function UM:ResetFramePosition(frameKey)
        local data = self.frames[frameKey]
        if not data or not data.frame then return end
        if self:RefuseLocked(frameKey) then return end
        data._pending = nil
        ResetStored(data)
    end

    -- SETUP2: a registered frame put at a screen spot by code (the setup's
    -- layout presets): cx, cy are CENTER offsets from the screen's centre
    -- in UIParent units, saved the way a drop saves them. In combat a
    -- protected frame waits for the fight to end, as a drop does.
    function UM:PlaceFrame(frameKey, cx, cy)
        local data = self.frames[frameKey]
        if not data or not data.frame then return false end
        local k = ScaleK(data.frame)
        MoveCenter(data, (tonumber(cx) or 0) * k, (tonumber(cy) or 0) * k)
        return true
    end

    -- One persistent WR_MoverGrid frame for the addon session. Line
    -- textures are pooled in grid.lines and re-laid out when the grid
    -- size changes - recreating the frame per size change orphaned it
    -- (frames are never GC'd by the client).
    local function LayoutGrid(grid)
        local gridLine = GetColor("gridLine")
        local gridCenter = GetColor("gridCenter")

        local screenWidth = UIParent:GetWidth()
        local screenHeight = UIParent:GetHeight()
        local gridSize = UM.gridSize

        grid.lines = grid.lines or {}
        local used = 0
        local function AcquireLine()
            used = used + 1
            local line = grid.lines[used]
            if not line then
                line = grid:CreateTexture(nil, "BACKGROUND")
                line:SetTexture(FLAT)
                grid.lines[used] = line
            end
            line:SetVertexColor(gridLine.r, gridLine.g, gridLine.b, gridLine.a)
            line:ClearAllPoints()
            line:Show()
            return line
        end

        for x = gridSize, screenWidth, gridSize do
            local line = AcquireLine()
            line:SetSize(1, screenHeight)
            line:SetPoint("TOPLEFT", grid, "TOPLEFT", x, 0)
        end

        for y = gridSize, screenHeight, gridSize do
            local line = AcquireLine()
            line:SetSize(screenWidth, 1)
            line:SetPoint("TOPLEFT", grid, "TOPLEFT", 0, -y)
        end

        for i = used + 1, #grid.lines do
            grid.lines[i]:Hide()
        end

        -- Centre lines: same 1px hairline, just the brighter colour, so
        -- the middle of the screen is findable at a glance.
        if not grid.centerV then
            grid.centerV = grid:CreateTexture(nil, "ARTWORK")
            grid.centerV:SetTexture(FLAT)
            grid.centerH = grid:CreateTexture(nil, "ARTWORK")
            grid.centerH:SetTexture(FLAT)
        end
        grid.centerV:SetVertexColor(gridCenter.r, gridCenter.g, gridCenter.b, gridCenter.a)
        grid.centerV:SetSize(1, screenHeight)
        grid.centerV:ClearAllPoints()
        grid.centerV:SetPoint("CENTER", grid, "CENTER", 0, 0)

        grid.centerH:SetVertexColor(gridCenter.r, gridCenter.g, gridCenter.b, gridCenter.a)
        grid.centerH:SetSize(screenWidth, 1)
        grid.centerH:ClearAllPoints()
        grid.centerH:SetPoint("CENTER", grid, "CENTER", 0, 0)

        grid._layoutSize = gridSize
    end

    function UM:ShowGrid()
        if not self.grid then
            local grid = CreateFrame("Frame", "WR_MoverGrid", UIParent)
            grid:SetAllPoints(UIParent)
            grid:SetFrameStrata("BACKGROUND")
            grid:SetFrameLevel(0)
            self.grid = grid
        end
        if self.grid._layoutSize ~= self.gridSize then
            LayoutGrid(self.grid)
        end
        self.grid:Show()
    end

    function UM:HideGrid()
        if self.grid then
            self.grid:Hide()
        end
    end

    -- ============================================================
    -- SHOW / HIDE WHILE MOVING
    -- A frame unticked in the list (or Shift+Right-clicked on its box) is
    -- out of the way for as long as the mover is open: its box goes and
    -- the frame itself is faded to nothing, so the rest is easy to reach.
    -- Leaving the mover (Save & lock, Escape, the game's Edit Mode
    -- closing) fades everything back in. The ticks are kept for the
    -- session, so the next pass starts with the same frames out of the
    -- way; a /reload shows everything again. Nothing is saved.
    -- Faded (alpha), not hidden: owners show and hide these frames
    -- themselves and the previews swallow Hide() while moving. Some
    -- owners also set their own alpha, so a light ticker puts the fade
    -- back while anything is hidden.
    -- ============================================================
    UM.hiddenKeys = UM.hiddenKeys or {}
    local faded = {}      -- [frame] = the alpha it had before the fade

    -- The frame, and for a dock group every button in it.
    local function ContentFrames(data)
        local list = {}
        if data.frame then list[1] = data.frame end
        if data.groupSlots then
            local GM = RC.GearManager
            for _, s in ipairs(data.groupSlots) do
                local b = GM and GM.buttons and GM.buttons[s]
                if b and b ~= data.frame then list[#list + 1] = b end
            end
        end
        return list
    end

    local function Fade(frame)
        if not (frame and frame.SetAlpha and frame.GetAlpha) then return end
        if faded[frame] == nil then faded[frame] = frame:GetAlpha() or 1 end
        frame:SetAlpha(0)
    end

    local function Unfade(frame)
        local a = faded[frame]
        if a == nil then return end
        faded[frame] = nil
        frame:SetAlpha(a)
    end

    local function StopKeeper()
        if UM._keepTicker then
            UM._keepTicker:Cancel()
            UM._keepTicker = nil
        end
    end

    local function KeepTick()
        if not UM.isMoving or next(faded) == nil then
            StopKeeper()
            return
        end
        for frame in pairs(faded) do
            if frame:GetAlpha() ~= 0 then frame:SetAlpha(0) end
        end
    end

    local function StartKeeper()
        if UM._keepTicker or next(faded) == nil then return end
        UM._keepTicker = RC.Profiler:TrackTicker("UIMover:KeepHidden", 0.25, KeepTick)
    end

    -- Puts one frame in the state its tick asks for. Only while moving.
    function UM:ApplyHidden(frameKey)
        local data = self.frames[frameKey]
        if not (data and self.isMoving) then return end
        if self.hiddenKeys[frameKey] then
            if data.anchor then data.anchor:Hide() end
            for _, f in ipairs(ContentFrames(data)) do Fade(f) end
            StartKeeper()
        else
            for _, f in ipairs(ContentFrames(data)) do Unfade(f) end
            if data.anchor and data.frame then
                AttachAnchor(data)
                data.anchor:Show()
            end
        end
    end

    function UM:SetFrameHidden(frameKey, hide)
        self.hiddenKeys[frameKey] = hide and true or nil
        self:ApplyHidden(frameKey)
        self:RefreshVisibilityList()
    end

    -- Every faded frame back to the alpha it had. The ticks stay.
    function UM:RestoreHidden()
        StopKeeper()
        local list = {}
        for frame in pairs(faded) do list[#list + 1] = frame end
        for _, frame in ipairs(list) do Unfade(frame) end
    end

    -- The list: a small window in the panel's style, one tick per frame.
    local VIS_W, VIS_H, VIS_ROW = 260, 420, 22

    function UM:CreateVisibilityList()
        if self.visList then return self.visList end
        local panelBg = GetColor("panelBackground")
        local panelBorder = GetColor("panelBorder")
        local headerTxt = GetColor("headerText")
        local INNER = VIS_W - 2 * PANEL_PAD

        local w = CreateFrame("Frame", "WR_UIMoverVisibility", UIParent)
        w:SetSize(VIS_W, VIS_H)
        w:SetFrameStrata("TOOLTIP")
        w:SetFrameLevel(2020)
        w:SetMovable(true)
        w:EnableMouse(true)
        w:RegisterForDrag("LeftButton")
        w:SetClampedToScreen(true)
        w:SetScript("OnDragStart", w.StartMoving)
        w:SetScript("OnDragStop", w.StopMovingOrSizing)
        RC.UI:RegisterEscapeClose(w)

        w.bg = FlatFill(w, panelBg)
        w.border = RC.UI:CreateSimpleBorder(w)
        RC.UI:UpdateBorderColor(w.border, panelBorder)

        local header = CreateFrame("Frame", nil, w)
        header:SetHeight(TITLEBAR_H)
        header:SetPoint("TOPLEFT", w, "TOPLEFT", 1, -1)
        header:SetPoint("TOPRIGHT", w, "TOPRIGHT", -1, -1)
        local headerFill = FlatFill(header, GetColor("headerBackground"))
        if RC.UI.ApplyHeaderArt then
            RC.UI:ApplyHeaderArt(header, { fill = headerFill, stepX = 90 })
        end
        local titleIcon = RC.UI:AddTitleIcon(header, 16, 8)
        local title = RC:CreateFontString(header, "OVERLAY", nil, 15)
        title:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        title:SetText(RCL["Show / hide"])
        title:SetTextColor(headerTxt.r, headerTxt.g, headerTxt.b, 1)
        local close = RC.UI:CreateXCloseButton(header, 22, function() w:Hide() end)
        close:SetPoint("RIGHT", header, "RIGHT", -5, 0)

        local y = -(TITLEBAR_H + 1 + 10)
        local desc = RC:CreateFontString(w, "OVERLAY", nil, 10)
        desc:SetPoint("TOPLEFT", w, "TOPLEFT", PANEL_PAD, y)
        desc:SetWidth(INNER)
        desc:SetJustifyH("LEFT")
        desc:SetText(RCL["Untick a frame to hide it while you move the rest. Everything comes back when you lock."])
        local gray = RC:GetColor("text", "gray")
        desc:SetTextColor(gray.r, gray.g, gray.b, 1)
        y = y - 30

        local half = math.floor((INNER - 4) / 2)
        local showAll = RC.UI:CreateStyledButton(w, RCL["Show all"], half, 22)
        showAll:SetPoint("TOPLEFT", w, "TOPLEFT", PANEL_PAD, y)
        showAll:SetScript("OnClick", function()
            for key in pairs(UM.frames) do
                if UM.hiddenKeys[key] then
                    UM.hiddenKeys[key] = nil
                    UM:ApplyHidden(key)
                end
            end
            UM:RefreshVisibilityList()
        end)
        local hideAll = RC.UI:CreateStyledButton(w, RCL["Hide all"], INNER - half - 4, 22)
        hideAll:SetPoint("LEFT", showAll, "RIGHT", 4, 0)
        hideAll:SetScript("OnClick", function()
            for key, data in pairs(UM.frames) do
                if data.frame and not UM.hiddenKeys[key] then
                    UM.hiddenKeys[key] = true
                    UM:ApplyHidden(key)
                end
            end
            UM:RefreshVisibilityList()
        end)
        y = y - 22 - 8

        local body = CreateFrame("Frame", nil, w)
        body:SetPoint("TOPLEFT", w, "TOPLEFT", PANEL_PAD, y)
        body:SetPoint("BOTTOMRIGHT", w, "BOTTOMRIGHT", -PANEL_PAD + 6, PANEL_PAD)
        local scroll = CreateFrame("ScrollFrame", nil, body)
        scroll:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
        scroll:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", -22, 0)
        local content = CreateFrame("Frame", nil, scroll)
        content:SetSize(INNER - 22, 1)
        scroll:SetScrollChild(content)
        w.scroll, w.content = scroll, content
        w.scrollBar = RC.UI:AttachScrollbar(scroll, body, { width = 12 })
        w.rows = {}

        RC.UI:SkinPopup(w, { header = header, title = title, close = close, chrome = false, scan = false })
        w:Hide()
        self.visList = w
        return w
    end

    function UM:RefreshVisibilityList()
        local w = self.visList
        if not (w and w:IsShown()) then return end
        local items = {}
        for key, data in pairs(self.frames) do
            if data.frame then
                items[#items + 1] = { key = key, text = data.displayName or key }
            end
        end
        table.sort(items, function(a, b) return a.text < b.text end)
        for i, it in ipairs(items) do
            local cb = w.rows[i]
            if not cb then
                cb = RC.UI:CreateCheckbox(w.content, "", true)
                cb.parentFrame:SetSize(w.content:GetWidth(), VIS_ROW)
                cb:SetScript("OnClick", function(self)
                    if self.frameKey then
                        UM:SetFrameHidden(self.frameKey, not self:GetChecked())
                    end
                end)
                w.rows[i] = cb
            end
            cb.frameKey = it.key
            cb.Text:SetText(it.text)
            cb:SetChecked(not self.hiddenKeys[it.key])
            cb.parentFrame:ClearAllPoints()
            cb.parentFrame:SetPoint("TOPLEFT", w.content, "TOPLEFT", 0, -(i - 1) * VIS_ROW)
            cb.parentFrame:Show()
        end
        for i = #items + 1, #w.rows do
            w.rows[i].frameKey = nil
            w.rows[i].parentFrame:Hide()
        end
        local contentH = math.max(1, #items * VIS_ROW)
        w.content:SetHeight(contentH)
        w.scrollBar:SyncRange(contentH, w.scroll:GetHeight())
    end

    -- Beside the panel, or under the Edit Mode buttons when there is no
    -- panel (the game's Edit Mode is open).
    function UM:ToggleVisibilityList()
        local w = self:CreateVisibilityList()
        if w:IsShown() then
            w:Hide()
            return
        end
        w:ClearAllPoints()
        local p = self.controlPanel
        if p and p:IsShown() then
            w:SetPoint("TOPRIGHT", p, "TOPLEFT", -6, 0)
        elseif self.editModeVisButton and self.editModeVisButton:IsVisible() then
            w:SetPoint("TOP", self.editModeVisButton, "BOTTOM", 0, -6)
        else
            w:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        end
        w:Show()
        self:RefreshVisibilityList()
    end

    function UM:CreateEditModeButton()
        if self.editModeButton then return self.editModeButton end
        local host = EditModeManagerFrame
        local btn = RC.UI:CreateStyledButton(host or UIParent, RCL["Readycheck Mover"], 200, 26)
        if host then
            btn:SetPoint("TOP", host, "BOTTOM", 0, -6)
        else
            btn:SetPoint("TOP", UIParent, "TOP", 0, -140)
        end
        btn:SetFrameStrata("TOOLTIP")
        btn:SetFrameLevel(2000)
        btn:SetScript("OnClick", function()
            UM:OpenPanelFromEditMode()
        end)
        btn:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(RCL["Readycheck Mover"], 1, 1, 1)
            GameTooltip:AddLine(RCL["Open the full mover panel - frame list, nudge arrows and coordinates - while staying in Edit Mode."], 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        btn:HookScript("OnLeave", function() GameTooltip:Hide() end)

        -- A child of the Mover button, so it shows and hides with it.
        local vis = RC.UI:CreateStyledButton(btn, RCL["Show / hide Readycheck frames"], 200, 26)
        vis:SetPoint("TOP", btn, "BOTTOM", 0, -4)
        vis:SetFrameStrata("TOOLTIP")
        vis:SetFrameLevel(2001)
        vis:SetScript("OnClick", function()
            UM:ToggleVisibilityList()
        end)
        vis:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(RCL["Show / hide Readycheck frames"], 1, 1, 1)
            GameTooltip:AddLine(RCL["Hide Readycheck frames you are not moving, so the rest is easy to reach. They come back when you leave Edit Mode."], 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        vis:HookScript("OnLeave", function() GameTooltip:Hide() end)
        self.editModeVisButton = vis

        btn:Hide()
        self.editModeButton = btn
        return btn
    end

    function UM:OpenPanelFromEditMode()
        if not self.isMoving then return end
        self.panelless = false
        if self.editModeButton then self.editModeButton:Hide() end
        self:CreateControlPanel()
        self:InitializeDropdown()
        self.controlPanel:Show()
        if self.showGrid then
            self:ShowGrid()
        end
    end

    -- While the mover is open, hidden frames are force-shown with their real
    -- content (bars stay populated via the RC._uiMoverActive visibility
    -- gates) so you place actual UI, not empty labeled boxes. Everything is
    -- restored on Save & Lock.
    local function IsPreviewSkipped(frameKey)
        if frameKey == "minimapButton" then return true end
        return frameKey:find("^dockGrp") ~= nil or frameKey:find("^dockBtn") ~= nil
    end

    function UM:ActivatePreviews()
        local nShown, nVisible, nSkipped, nErr, nTotal = 0, 0, 0, 0, 0
        for frameKey, data in pairs(self.frames) do
            nTotal = nTotal + 1
            local frame = data.frame
            if not frame then
                nSkipped = nSkipped + 1
            elseif IsPreviewSkipped(frameKey) then
                nSkipped = nSkipped + 1
            elseif InCombat() and FrameProtected(data) then
                -- a secure frame cannot be shown in combat
                nSkipped = nSkipped + 1
            elseif frame:IsShown() then
                nVisible = nVisible + 1
            else
                local ok, err = pcall(UM.PreviewOneFrame, UM, frameKey, data, frame)
                if ok then
                    nShown = nShown + 1
                else
                    nErr = nErr + 1
                    if RC.DebugPrint then
                        RC:DebugPrint("Mover preview error [" .. tostring(frameKey) .. "]: " .. tostring(err), "uimover")
                    end
                end
            end
        end
        self._lastPreviewCounts = { shown = nShown, visible = nVisible, skipped = nSkipped, err = nErr, total = nTotal }
        if RC.DebugPrint then
            RC:DebugPrint(string.format("Mover previews: %d force-shown, %d already visible, %d skipped, %d errors (of %d frames)",
                nShown, nVisible, nSkipped, nErr, nTotal), "uimover")
        end

        UM:_PreviewExtras()

        -- Self-diagnosis (debug only): a moment after entering, report any
        -- preview that is no longer shown or is shown-but-invisible.
        if RC.IsDebugEnabled and RC:IsDebugEnabled("uimover") then
            C_Timer.After(1.5, function()
                if not UM.isMoving then return end
                local bad = 0
                for fk, d in pairs(UM.frames) do
                    if d._previewShown and d.frame then
                        local f = d.frame
                        if not f:IsShown() then
                            bad = bad + 1
                            RC:DebugPrint("Mover check: [" .. fk .. "] got HIDDEN after preview", "uimover")
                        elseif f.IsVisible and not f:IsVisible() then
                            bad = bad + 1
                            local p = f.GetParent and f:GetParent()
                            local pname = p and ((p.GetName and p:GetName()) or "unnamed parent") or "no parent"
                            local pshown = p and p.IsShown and p:IsShown()
                            RC:DebugPrint("Mover check: [" .. fk .. "] shown but INVISIBLE - parent "
                                .. tostring(pname) .. " (parent shown=" .. tostring(pshown) .. ")", "uimover")
                        end
                    end
                end
                if bad == 0 then
                    RC:DebugPrint("Mover check: all previewed frames visible", "uimover")
                end
            end)
        end
    end

    function UM:PreviewOneFrame(frameKey, data, frame)
        do
                -- Owners aggressively re-hide these frames (no route, no
                -- fight, no buffs, empty party, OnShow validators...).
                -- Swallow Hide/SetShown(false) BEFORE showing so not even a
                -- synchronous re-hide can win; restored on Save & Lock.
                if not data._hideBlocked then
                    data._hideBlocked = true
                    frame.Hide = function()
                        if not data._hideReported then
                            data._hideReported = true
                            if RC.DebugPrint then
                                RC:DebugPrint("Mover: swallowed Hide() on [" .. frameKey .. "]", "uimover")
                            end
                        end
                    end
                    frame.SetShown = function(s, shown) if shown then s:Show() end end
                end

                if frameKey == "reminderFrame" and RC.ShowReminderForced then
                    -- Real reminder popup with sample text; dismissed on exit.
                    -- No ability keys here: the forced path speaks them via
                    -- TTS (possibly on a delayed timer), and the mover must
                    -- stay silent.
                    RC._suppressReminderTTSOnce = true
                    RC:ShowReminderForced(RCL["Reminder preview - place me"], {}, 0)
                    RC._suppressReminderTTSOnce = nil
                    data._previewReminder = frame:IsShown() and true or nil
                    data._previewShown = true
                    frame:Show()
                elseif frameKey == "specPopup" and RC.FillSpecDisplay and RC.specDetection then
                    -- the real popup with this character's spec (or Fury),
                    -- held still: no entrance, no timer to fade it out
                    if RC.Motion and RC.Motion.Stop then RC.Motion.Stop(frame) end
                    if frame._rcHoldTimer then frame._rcHoldTimer:Cancel() frame._rcHoldTimer = nil end
                    local specs = RC.specDetection.specs or {}
                    local spec = RC.DetectWarriorSpec and RC:DetectWarriorSpec()
                    if not (spec and specs[spec]) then spec = "fury" end
                    if specs[spec] then
                        if RC.StyleSpecDisplay then RC:StyleSpecDisplay(frame) end
                        local talents = RC.GetDisplayTalents and RC:GetDisplayTalents(spec, 8) or nil
                        RC:FillSpecDisplay(frame, specs[spec], spec, talents)
                    end
                    frame:SetAlpha(1)
                    data._previewShown = true
                    frame:Show()
                elseif frameKey == "swapToast" and RC.SwapToast and RC.SwapToast.Sample then
                    -- a sample swap laid out, so the box is its real size
                    local ST = RC.SwapToast
                    ST:Style(frame)
                    ST:Layout(ST.Sample("set"))
                    frame:SetAlpha(1)
                    data._previewShown = true
                    frame:Show()
                else
                    data._previewShown = true
                    frame:Show()
                end

                if frameKey == "polarityBar" and frame:IsShown() then
                    -- Freeze the bar full instead of letting its OnUpdate
                    -- count down and fire real LIP/dummy reminders.
                    data._pausedOnUpdate = frame:GetScript("OnUpdate")
                    frame:SetScript("OnUpdate", nil)
                    if RC.PolarityApplyBarSettings then RC:PolarityApplyBarSettings() end
                    if frame.fill then
                        frame.fill:SetWidth(math.max(0.01, (frame:GetWidth() or 170) - 2))
                    end
                    if frame.timeText then
                        local lip = (RC.db and RC.db.polarityMode and RC.db.polarityMode.lipTime) or 5
                        frame.timeText:SetText(string.format("%.1f", lip))
                    end
                end
            end
        end

    function UM:_PreviewExtras()
        local function TryCall(label, fn)
            if not fn then return end
            local ok, err = pcall(fn, RC)
            if not ok and RC.DebugPrint then
                RC:DebugPrint("Mover preview error [" .. label .. "]: " .. tostring(err), "uimover")
            end
        end

        -- Rebuild the bars right away so the previews come up populated
        -- instead of waiting for the next bag/zone event (their ShouldShow
        -- gates return true while the mover is active).
        TryCall("consumablesBar", RC.UpdateConsumablesButtons)
        TryCall("potionsBar", RC.UpdatePotionsButtons)
        TryCall("weaponsBar", RC.UpdateWeaponsButtons)
        TryCall("trinketBar", RC.UpdateTrinketBarButtons)

        -- Party tracker renders a fake party while the mover is active.
        TryCall("bsPartyTracker", RC.UpdateBattleShoutPartyTracker)
        TryCall("bsPartyTrackerTicker", RC.StartBattleShoutPartyTrackerUpdates)

        -- Aura trackers render sample rows while the mover is active;
        -- Refresh starts their tickers (ShouldRun is true under the mover).
        TryCall("raidBuffTracker", RC.RefreshRaidBuffTracker)
        TryCall("bossDebuffTracker", RC.RefreshBossDebuffTracker)

        -- Boss notes: use the built-in note preview with sample text.
        local notesData = self.frames.bossNotes
        if notesData and notesData._previewShown and RC.PreviewBossNoteText
           and RC.bossNotes and not RC.bossNotes.isPreviewing then
            local ok, err = pcall(RC.PreviewBossNoteText, RC,
                RCL["Note preview: tank swap at 2 stacks - hug the wall on the teleport."])
            if not ok and RC.DebugPrint then
                RC:DebugPrint("Mover preview error [bossNotes]: " .. tostring(err), "uimover")
            end
            notesData._previewNote = true
        end

        -- TTK display: sample numbers instead of blank dashes.
        local ttkData = self.frames.ttkDisplay
        if ttkData and ttkData._previewShown and ttkData.frame then
            local tf = ttkData.frame
            if tf.predictedValue then tf.predictedValue:SetText("1:24") end
            if tf.realtimeValue then tf.realtimeValue:SetText("1:31") end
            if tf.paceValue then tf.paceValue:SetText("-7s") end
        end

        -- Enforcement pass: the refresh calls above may have re-hidden a
        -- previewed frame through a path we don't own - put them back up.
        local shown = 0
        for frameKey, data in pairs(self.frames) do
            if data._previewShown and data.frame then
                if not data.frame:IsShown() then data.frame:Show() end
                shown = shown + 1
            end
        end
        if RC.DebugPrint then
            RC:DebugPrint("UIMover previews: " .. shown .. " hidden frame(s) force-shown", "uimover")
        end
    end

    function UM:DeactivatePreviews()
        for frameKey, data in pairs(self.frames) do
            local frame = data.frame
            if frame then
                if data._pausedOnUpdate then
                    frame:SetScript("OnUpdate", data._pausedOnUpdate)
                    data._pausedOnUpdate = nil
                end
                if data._hideBlocked then
                    frame.Hide = nil
                    frame.SetShown = nil
                    data._hideBlocked = nil
                end
                if data._previewNote then
                    if RC.HideBossNotesPreview then RC:HideBossNotesPreview() end
                    data._previewNote = nil
                end
                if data._previewReminder then
                    if RC.HideReminder then RC:HideReminder() end
                    data._previewReminder = nil
                    data._previewShown = nil
                elseif data._previewShown then
                    if InCombat() and FrameProtected(data) then
                        data._hideAfterCombat = true   -- OnCombatEnd hides it
                    else
                        frame:Hide()
                    end
                    data._previewShown = nil
                end
            end
        end

        -- TTK display: clear the sample numbers back to idle.
        if RC.TTKDisplay and RC.TTKDisplay.ttkFrame then
            local tf = RC.TTKDisplay.ttkFrame
            if tf.predictedValue then tf.predictedValue:SetText("--:--") end
            if tf.realtimeValue then tf.realtimeValue:SetText("--:--") end
            if tf.paceValue then tf.paceValue:SetText("--") end
        end
    end

    -- Overlapping handles stay grabbable: the smaller box always sits
    -- above the bigger one, all of them above any frame they cover (the
    -- spec popup draws at TOOLTIP level 1000) and below the panel (2000).
    local ANCHOR_LEVEL = 1100
    function UM:StackAnchors()
        local list = {}
        for key, data in pairs(self.frames) do
            if data.anchor then list[#list + 1] = { key = key, a = data.anchor } end
        end
        for _, e in ipairs(list) do
            e.area = (e.a:GetWidth() or 0) * (e.a:GetHeight() or 0)
        end
        table.sort(list, function(p, q)
            if p.area ~= q.area then return p.area > q.area end
            return p.key < q.key
        end)
        for i, e in ipairs(list) do e.a:SetFrameLevel(ANCHOR_LEVEL + i) end
    end

    -- Moves are guarded per frame (see COMBAT): addon frames move freely
    -- in combat, secure ones (gear buttons, bars of secure buttons) wait.
    function UM:EnterMoveMode(opts)
        if self.isMoving then return end
        self.isMoving = true
        do
            local GM = RC.GearManager
            if GM and GM.Unlock and GM.Lock then
                self._gmWasLocked = GM.locked and true or false
                if self._gmWasLocked then GM:Unlock() end
            end
            RC._uiMoverActive = true
        end
        self.panelless = (opts and opts.noPanel) and true or false

        self:RegisterAddonFrames()
        self:ActivatePreviews()

        if self.panelless then
            if self.controlPanel then self.controlPanel:Hide() end
            self:CreateEditModeButton():Show()
        else
            if self.editModeButton then self.editModeButton:Hide() end
            self:CreateControlPanel()
            self:InitializeDropdown()
            self.controlPanel:Show()
        end

        for frameKey, data in pairs(self.frames) do
            if data.frame then
                if not data.anchor then
                    self:CreateAnchor(frameKey)
                end
                if data.anchor then
                    AttachAnchor(data)
                    data.anchor:Show()

                    if not data.frame:IsShown() then
                        data.anchor:SetAlpha(0.5)
                        if data.anchor.label then
                            data.anchor.label:SetText(data.displayName .. RCL[" |cff888888(Hidden)|r"])
                        end
                    else
                        data.anchor:SetAlpha(1)
                        if data.anchor.label then
                            data.anchor.label:SetText(data.displayName)
                        end
                    end
                    data.anchor._textsInside = nil
                    LayoutTexts(data.anchor)
                    PaintLock(data)
                end
            end
        end
        self:StackAnchors()

        -- frames ticked off earlier this session stay out of the way
        for frameKey in pairs(self.hiddenKeys) do
            self:ApplyHidden(frameKey)
        end
        self:RefreshVisibilityList()

        if self.showGrid and not self.panelless then
            self:ShowGrid()
        end
    end

    -- LEAVING MOVE MODE LOCKS EVERYTHING IT MOVES. Some frames carry a
    -- lock of their own, flipped on the frame itself: right-click a bar or
    -- the TTK display, the padlock on a gear button. One left unlocked
    -- that way used to stay unlocked after "Save & lock", which then had
    -- not locked it. Each bar is locked through its own toggle, so it
    -- repaints (title, gold edge, hint) exactly as when locked by hand.
    -- A frame whose lock is only a checkbox on its settings page is left
    -- as the player set it.
    local BAR_LOCKS = {
        { "weaponsBar",        "ToggleWeaponsBarLock" },
        { "trinketBar",        "ToggleTrinketBarLock" },
        { "consumablesHelper", "ToggleConsumablesHelperLock" },
        { "potionsBar",        "TogglePotionsBarLock" },
    }
    function UM:LockOwnLocks()
        local db = RC.db
        if type(db) ~= "table" then return end
        for _, e in ipairs(BAR_LOCKS) do
            local cfg, toggle = db[e[1]], RC[e[2]]
            local state = RC[e[1]]
            if type(cfg) == "table" and not cfg.locked and toggle
               and type(state) == "table" and state.frame then
                toggle(RC)
            end
        end
        local ttk = db.ttkDisplay
        if type(ttk) == "table" and not ttk.locked then
            ttk.locked = true
            local f = RC.TTKDisplay and RC.TTKDisplay.ttkFrame
            if f and f.SetMovable then f:SetMovable(false) end
        end
    end

    function UM:ExitMoveMode(reason)
        -- Hiding the panel below fires its OnHide, which is also the hook
        -- that turns an ESC into an exit. Without this guard the two call
        -- each other.
        if self._exiting then return end
        self._exiting = true
        if RC.DebugPrint then
            RC:DebugPrint("Mover: exit requested (" .. tostring(reason or "?")
                .. ") isMoving=" .. tostring(self.isMoving), "uimover")
        end
        if not self.isMoving then
            local uiUp = self.controlPanel and self.controlPanel:IsShown()
            if not uiUp then
                for _, d in pairs(self.frames) do
                    if d.anchor and d.anchor:IsShown() then uiUp = true; break end
                end
            end
            if not uiUp then self._exiting = nil; return end
            if RC.DebugPrint then
                RC:DebugPrint(RCL["Mover: state was desynced - forcing Save & Lock cleanup."], "uimover")
            end
        end
        self.isMoving = false
        self.panelless = nil
        do
            -- Always locked on the way out, not put back to how they were:
            -- buttons unlocked from their own padlock are part of what
            -- "Save & lock" is expected to lock.
            local GM = RC.GearManager
            if GM and GM.Lock and GM.settings and GM.buttonData then
                GM:Lock()
            end
            self._gmWasLocked = nil
            RC._uiMoverActive = nil
            if GM and GM.buttons then
                for _, btn in pairs(GM.buttons) do
                    if btn and btn._moverGlow then btn._moverGlow:Hide() end
                end
            end
        end
        if self.editModeButton then self.editModeButton:Hide() end
        if self.visList then self.visList:Hide() end
        self:RestoreHidden()

        self:DeactivatePreviews()

        for frameKey, data in pairs(self.frames) do
            if data.anchor then
                data.anchor:SetAlpha(1)
                if data.anchor.label then
                    data.anchor.label:SetText(data.displayName)
                end
                data.anchor:Hide()
            end
        end

        if self.controlPanel then
            self.controlPanel:Hide()
        end

        self:HideGrid()

        -- After the previews are gone, so each bar repaints from its real
        -- state. Guarded: an error here must not leave _exiting set, or
        -- move mode could never be left again.
        local ok, err = pcall(self.LockOwnLocks, self)
        if not ok and RC.DebugPrint then
            RC:DebugPrint("Mover: lock pass failed: " .. tostring(err), "uimover")
        end

        if RC.SaveConfigurationToProfile then
            pcall(RC.SaveConfigurationToProfile, RC)
        end

        self._exiting = nil
    end

    function UM:RegisterAddonFrames()
        if not RC then return end

        if RC.RaidRoute and RC.RaidRoute.EnsureTrackerFrame and RC:FeatureOn("raid_route") then
            RC.RaidRoute:EnsureTrackerFrame()
        end

        if RC.EnsureMeshProgressBar then RC.EnsureMeshProgressBar() end
        if RC.EnsureWorldBuffMini then RC.EnsureWorldBuffMini() end
        if RC.EnsureGearSetPrompt and RC:FeatureOn("boss_gear_prompt") then RC.EnsureGearSetPrompt() end

        -- Frames their features make only when first needed: made now
        -- (hidden) for a feature that is on, so it can be placed before it
        -- ever shows. Only on the way into the mover, never at login.
        if self.isMoving then
            local db = RC.db or {}
            local function Make(label, fn, ...)
                if not fn then return end
                local ok, err = pcall(fn, ...)
                if not ok and RC.DebugPrint then
                    RC:DebugPrint("Mover: could not make " .. label .. ": " .. tostring(err), "uimover")
                end
            end
            if type(db.polarityMode) == "table" and db.polarityMode.enabled and RC:FeatureOn("polarity") then
                Make("polarityBar", RC.PolarityEnsureBar, RC)
            end
            local CS = RC.CharacterStats
            if CS and type(db.buffPushoffAlert) == "table" and db.buffPushoffAlert.enabled
               and RC:FeatureOn("buff_pushoff") then
                Make("buffPushoffAlert", CS.CreateBuffPushoffAlertFrame, CS)
            end
            if RC.SwapToast and RC.SwapToast.Ensure then
                Make("swapToast", RC.SwapToast.Ensure, RC.SwapToast)
            end
            if RC.consumablesChecker and RC.CreateConsumablesCheckerFrame then
                Make("consumablesChecker", RC.CreateConsumablesCheckerFrame, RC)
            end
            local sd = db.specDetection
            if not (type(sd) == "table" and sd.enabled == false) and RC.CreateSpecDisplayFrame then
                Make("specPopup", RC.CreateSpecDisplayFrame, RC)
            end
        end

        -- Frames bound to RC.Position in their own files.
        local function Bound(key, frame, label, point, x, y)
            if not frame then return end
            self:RegisterFrame(key, frame, label,
                {point = point, relPoint = point, x = x, y = y})
        end

        Bound("reminderFrame", RC.reminderFrame, "Reminder Alert", "CENTER", 0, 200)
        Bound("statsBar", RC.CharacterStats and RC.CharacterStats.barFrame, "Stats Bar", "TOP", 0, -5)
        Bound("ttkDisplay", RC.TTKDisplay and RC.TTKDisplay.ttkFrame, "TTK Display", "TOP", 0, -100)
        Bound("buffPushoffAlert", RC.CharacterStats and RC.CharacterStats.buffPushoffAlertFrame,
            "Buff Alert", "CENTER", 0, 150)
        Bound("consumablesChecker", RC.consumablesChecker and RC.consumablesChecker.frame,
            "Consumables Checker", "CENTER", 0, 0)
        Bound("consumablesHelper", RC.consumablesHelper and RC.consumablesHelper.frame,
            "Consumables Helper", "TOPLEFT", -200, -100)
        Bound("potionsBar", RC.potionsBar and RC.potionsBar.frame, "Potions Bar", "TOPLEFT", -10, -300)
        Bound("weaponsBar", RC.weaponsBar and RC.weaponsBar.frame, "Weapons Bar", "TOPLEFT", -10, -200)

        do
            local GM = RC.GearManager
            if GM and GM.buttons then
                -- Dock groups are rebuilt from the live tree each pass;
                -- their overlays are parked and reused (frames are never
                -- freed).
                self._spareAnchors = self._spareAnchors or {}
                for k, d in pairs(self.frames) do
                    if type(k) == "string"
                       and (k:find("^dockBtn") or k:find("^dockGrp")) then
                        if d.anchor then
                            d.anchor:Hide()
                            self._spareAnchors[k] = d.anchor
                        end
                        self.frames[k] = nil
                    end
                end
                for slot, btn in pairs(GM.buttons) do
                    local parentSlot = (GM.FindParentButton
                        and GM:FindParentButton(slot)) or slot
                    if btn and parentSlot == slot then
                        local group = { slot }
                        if GM.AddDockedChildren then
                            GM:AddDockedChildren(slot, group)
                        end
                        local nm = (GM.slotInfo and GM.slotInfo[slot]
                            and GM.slotInfo[slot].real)
                            or (slot == 999 and "Gear Set")
                            or ("Button " .. tostring(slot))
                        local label = (#group > 1)
                            and string.format(RCL["Gear Buttons: %s + %d docked"], nm, #group - 1)
                            or string.format(RCL["Gear Button: %s"], nm)
                        local capSlot = slot
                        self:RegisterFrame("dockGrp" .. slot, btn, label,
                            nil, function()
                                if GM.SaveDockGroup then
                                    GM:SaveDockGroup(capSlot)
                                end
                            end)
                        local ent = self.frames["dockGrp" .. slot]
                        if ent then
                            -- Keep the slot list, not two edge buttons: the box
                            -- is measured from every button in the group.
                            ent.groupSlots = group
                            ClampToContent(btn, group)
                        end
                    end
                end
            end
        end

        Bound("trinketBar", RC.trinketBar and RC.trinketBar.frame, "Trinket Bar", "TOPRIGHT", -10, -400)
        Bound("fastWeaponReminder", RC.fastWeaponReminder and RC.fastWeaponReminder.frame,
            "Weapon Reminder", "CENTER", 0, 100)
        Bound("battleShoutReminder", RC.battleShoutReminder and RC.battleShoutReminder.frame,
            "Battle Shout", "CENTER", 200, 0)
        Bound("trinketToggle", RC.trinketToggleButton, "Trinket Toggle", "CENTER", 200, -200)
        Bound("battleShoutPartyTracker", RC.battleShoutPartyTracker and RC.battleShoutPartyTracker.frame,
            "BS Party Tracker", "CENTER", 300, 100)
        Bound("raidBuffTracker", RC.raidBuffTracker and RC.raidBuffTracker.frame,
            "Raid Buff Tracker", "CENTER", 260, 140)
        Bound("bossDebuffTracker", RC.bossDebuffTracker and RC.bossDebuffTracker.frame,
            "Boss Debuff Tracker", "CENTER", 260, 20)
        Bound("bossNotes", RC.bossNotes and RC.bossNotes.frame, "Boss Notes", "CENTER", 0, 150)
        Bound("polarityBar", RC.polarityMode and RC.polarityMode.barFrame, "Polarity Bar", "CENTER", 0, 80)

        -- Frames that register themselves when made; made before the mover
        -- was up (login), their own call found nothing to register with.
        do
            local ess = RC.Essentials and RC.Essentials.Settings and RC.Essentials.Settings()
            if not (type(ess) == "table" and ess.enabled == false) then
                Bound("mustHaveAlert", _G.ReadycheckMustHaveAlert, nil, "CENTER", 0, 180)
            end
            Bound("swapToast", _G.ReadycheckSwapToast, nil, "CENTER", 0, 220)
        end

        -- The spec popup keeps its own numbers (Spec Detection > Position:
        -- its top middle from the top middle of the screen, in
        -- specDetection.look.x / .y), so its handle reads and saves those.
        local spec = RC.specDisplayFrame
        if spec then
            local function SpecLookStore()
                local d = RC.db
                if not d then return nil end
                if type(d.specDetection) ~= "table" then d.specDetection = {} end
                if type(d.specDetection.look) ~= "table" then d.specDetection.look = {} end
                return d.specDetection.look
            end
            local function Place()
                local L = (RC.SpecPopupLook and RC:SpecPopupLook()) or {}
                spec:ClearAllPoints()
                spec:SetPoint("TOP", UIParent, "TOP", L.x or 0, L.y or -150)
            end
            -- not while it is up for real: ShowSpecDisplay placed it
            if not spec:IsShown() then Place() end
            self:RegisterFrame("specPopup", spec, nil,
                { point = "TOP", relPoint = "TOP", x = 0, y = -150 },
                function(x, y)
                    local L = SpecLookStore()
                    if not L then return end
                    L.x, L.y = x, y
                    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
                end,
                { point = "TOP", relPoint = "TOP", onReset = function()
                    local L = SpecLookStore()
                    if L then L.x, L.y = nil, nil end
                    Place()
                    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
                end })
        end

        if RC.DebugPrint then
            local count = 0
            for _ in pairs(self.frames) do count = count + 1 end
            RC:DebugPrint("UIMover: Registered " .. count .. " frames", "uimover")
        end
    end

    C_Timer.After(2.5, function()
        UM:RegisterAddonFrames()
    end)

    if RC.DebugPrint then
        RC:DebugPrint("UIMover module initialized", "uimover")
    end
end

C_Timer.After(1, InitializeUIMover)

local _WRm = _G.Readycheck
if _WRm then
    _WRm._buildMarks = _WRm._buildMarks or {}
    _WRm._buildMarks["uimover"] = "mover-previews"
end
