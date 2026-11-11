------------------------------------------------------------------------
-- Readycheck - Trinket Swap UI
-- Toggle button and queue dropdown menu only; no swap logic lives
-- here. Reads trinketSwapSystem/bossTrinketState for status display
-- and calls RC:SetActiveQueue to change the active queue.
------------------------------------------------------------------------
local pairs, ipairs, type = pairs, ipairs, type
local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local WRF = _G.Readycheck
if not WRF then return end
WRF._tssInit = WRF._tssInit or {}
WRF._tss = WRF._tss or {}
WRF._tssInit[#WRF._tssInit + 1] = function()
    local RC = _G.Readycheck
    local _tss = WRF._tss
    function RC:GetQueueTrinketIcons(queueKey)
        local out = { slot1 = {}, slot2 = {} }
        local q = self.db.trinketSwap.queues and self.db.trinketSwap.queues[queueKey]
        if not q then return out end
        for _, slotKey in ipairs({"slot1", "slot2"}) do
            local slot = q[slotKey]
            local list = out[slotKey]
            local seen = {}
            if type(slot) == "table" then
                for _, itemID in ipairs(slot) do
                    if itemID and not seen[itemID] then
                        seen[itemID] = true
                        local icon = GetItemIcon and GetItemIcon(itemID)
                        if icon then
                            list[#list + 1] = icon
                            if #list >= 2 then break end
                        end
                    end
                end
            end
        end
        return out
    end

    local CLICK_DEFAULTS = {
        left = "toggle", right = "menu", middle = "hide",
        altLeft = "lock", altRight = "none", altMiddle = "none",
        ctrlLeft = "none", ctrlRight = "none", ctrlMiddle = "none",
        shiftLeft = "none", shiftRight = "none", shiftMiddle = "none",
    }
    function RC:GetTrinketButtonClicks()
        local ts = self.db and self.db.trinketSwap
        if not ts then return CLICK_DEFAULTS end
        if ts.swapButtonClicks ~= nil then
            if ts.swapButtonClicks == true then
                ts.buttonClicks = ts.buttonClicks or {}
                ts.buttonClicks.left  = ts.buttonClicks.left  or "menu"
                ts.buttonClicks.right = ts.buttonClicks.right or "toggle"
            end
            ts.swapButtonClicks = nil
        end
        local bc = ts.buttonClicks
        if not bc then return CLICK_DEFAULTS end
        local out = {}
        for k, v in pairs(CLICK_DEFAULTS) do out[k] = bc[k] or v end
        return out
    end

    function RC:CreateTrinketDropdown()
        if self.trinketDropdownMenu and self.trinketDropdownMenu:IsShown() then
            self.trinketDropdownMenu:Hide()
            return nil
        end

        local goldC = self:GetColor("ui", "accentGold")        or {r=0.85, g=0.65, b=0.25, a=1}
        local bordC = self:GetColor("ui", "borderNormal")      or {r=0,    g=0,    b=0,    a=1}

        if not self.trinketDropdownMenu then
            local menu = CreateFrame("Frame", "WRTrinketDropdownMenu", UIParent)
            menu:SetFrameStrata("FULLSCREEN_DIALOG")
            menu:SetFrameLevel(100)
            menu:EnableMouse(true)
            menu:SetClampedToScreen(true)

            local bg = menu:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            menu.bg = bg

            menu.borders = RC.UI:CreateSimpleBorder(menu)

            menu:SetScript("OnLeave", function(self)
                C_Timer.After(0.5, function()
                    if self:IsShown() and not self:IsMouseOver()
                       and not (RC.trinketToggleButton and RC.trinketToggleButton:IsMouseOver()) then
                        self:Hide()
                    end
                end)
            end)
            -- Named singleton, so ESC closes it through UISpecialFrames -
            -- the same wiring the consumables stone picker uses.
            if RC.UI and RC.UI.RegisterEscapeClose then
                RC.UI:RegisterEscapeClose("WRTrinketDropdownMenu")
            end

            self.trinketDropdownMenu = menu
        end
        local menu = self.trinketDropdownMenu

        -- Flat dropdown box: the menu is a list, so it paints the dropdown
        -- background rather than the statusbar texture.
        local menuC = self:GetColor("dropdown", "background") or {r=0.12, g=0.12, b=0.12, a=0.98}
        if menu.bg then
            menu.bg:SetTexture(RC.UI.FLAT)
            menu.bg:SetVertexColor(menuC.r, menuC.g, menuC.b, menuC.a or 1)
        end
        if menu.borders then
            for _, side in pairs(menu.borders) do
                if side and side.SetColorTexture then
                    side:SetColorTexture(bordC.r, bordC.g, bordC.b, bordC.a or 1)
                end
            end
        end

        -- WoW frames are never garbage collected, so the content frame and
        -- its rows are built once and reused/re-laid-out on every open
        -- instead of being thrown away and rebuilt (which grew the frame
        -- count on every menu open for the life of the session).
        local content = menu.content
        if not content then
            content = CreateFrame("Frame", nil, menu)
            content:SetPoint("TOPLEFT",     menu, "TOPLEFT",      1,  -1)
            content:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", -1,   1)
            menu.content = content
        end
        menu.rowPool = menu.rowPool or {}

        local function applyFont(fs, size, flags)
            if self.ApplyCustomFont then
                self:ApplyCustomFont(fs, size, flags or "OUTLINE")
            end
        end

        -- Rows carry their per-open state (goldC/isActive/queueKey) as
        -- fields so the scripts can stay attached across reuses.
        local function AcquireRow(index)
            local row = menu.rowPool[index]
            if row then return row end

            row = CreateFrame("Button", nil, content)
            row:SetHeight(22)

            row.bg = row:CreateTexture(nil, "BACKGROUND")
            row.bg:SetAllPoints()

            row.stripe = row:CreateTexture(nil, "ARTWORK")
            row.stripe:SetPoint("TOPLEFT",    row, "TOPLEFT",    0, 0)
            row.stripe:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
            row.stripe:SetWidth(2)

            row.check = row:CreateTexture(nil, "OVERLAY")
            row.check:SetSize(10, 10)
            row.check:SetPoint("LEFT", row, "LEFT", 5, 0)
            row.check:SetTexture("Interface\\AddOns\\Readycheck\\Media\\Checkmark.tga")

            row.nameFs = row:CreateFontString(nil, "OVERLAY")
            row.icons = {}

            -- Hover is a flat dropdown.itemHover fill; the selected row is
            -- marked by gold text and the accent stripe, never a gold fill.
            row:SetScript("OnEnter", function(rowSelf)
                if not rowSelf.goldC then return end
                local hc = RC:GetColor("dropdown", "itemHover")
                rowSelf.bg:SetColorTexture(hc.r, hc.g, hc.b, hc.a or 1)
            end)
            row:SetScript("OnLeave", function(rowSelf)
                if not rowSelf.goldC then return end
                rowSelf.bg:SetColorTexture(0, 0, 0, 0)
            end)
            row:SetScript("OnClick", function(rowSelf)
                if rowSelf.queueKey then
                    RC:SetActiveQueue(rowSelf.queueKey)
                end
                menu:Hide()
            end)

            menu.rowPool[index] = row
            return row
        end

        -- The menu belongs to the button, so it starts from the
        -- button's own width and only widens when a row actually needs
        -- more room. A fixed 200px list hanging off a 75px button reads
        -- as two unrelated frames.
        local btnW = (self.trinketToggleButton and self.trinketToggleButton.GetWidth
            and self.trinketToggleButton:GetWidth()) or 75
        local menuWidth = math.max(math.floor(btnW + 0.5), 120)
        local yPos      = -5

        local function collectTrinketIconsPerSlot(queueKey)
            return self:GetQueueTrinketIcons(queueKey)
        end

        local showIcons = self.db.trinketSwap.showQueueIcons ~= false
        local hasConfigs = false
        local rowIndex = 0
        for _, queueKey in ipairs(self.trinketSwapSystem.queueOrder) do
            if self:IsConfigPopulated(queueKey) then
                hasConfigs = true
                rowIndex = rowIndex + 1
                local displayName = self.trinketSwapSystem.queueNames[queueKey] or queueKey
                local isActive    = (self.trinketSwapSystem.currentQueue == queueKey)

                local row = AcquireRow(rowIndex)
                row.goldC    = goldC
                row.isActive = isActive
                row.queueKey = queueKey
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT",  content, "TOPLEFT",  3, yPos)
                row:SetPoint("TOPRIGHT", content, "TOPRIGHT",-3, yPos)
                row:Show()

                local rowBg = row.bg
                rowBg:SetColorTexture(0, 0, 0, 0)

                if isActive then
                    row.stripe:SetColorTexture(goldC.r, goldC.g, goldC.b, 1)
                    row.stripe:Show()

                    local checkC = self:GetColor("checkbox", "checkmark") or {r=0.3, g=1, b=0.3, a=1}
                    row.check:SetVertexColor(checkC.r, checkC.g, checkC.b, checkC.a or 1)
                    row.check:Show()
                else
                    row.stripe:Hide()
                    row.check:Hide()
                end

                local nameFs = row.nameFs
                applyFont(nameFs, 10, "OUTLINE")
                nameFs:ClearAllPoints()
                nameFs:SetPoint("LEFT", row, "LEFT", isActive and 20 or 8, 0)
                nameFs:SetText(displayName)
                if isActive then
                    local sc = RC:GetColor("dropdown", "selected")
                    nameFs:SetTextColor(sc.r, sc.g, sc.b, sc.a or 1)
                else
                    local nc = RC:GetColor("trinketSwap", "nameText")
                    nameFs:SetTextColor(nc.r, nc.g, nc.b, nc.a or 1)
                end

                for _, t in ipairs(row.icons) do t:Hide() end
                if showIcons then
                    local groups   = collectTrinketIconsPerSlot(queueKey)
                    local iconSize = 11
                    local iconGap  = 2
                    local slotGap  = 6
                    local lastAnchor, lastPoint, xOff = row, "RIGHT", -6
                    local iconIdx = 0

                    for groupIdx, slotKey in ipairs({"slot2", "slot1"}) do
                        local list = groups[slotKey]
                        if list and #list > 0 then
                            local firstOfGroup = true
                            for i = #list, 1, -1 do
                                iconIdx = iconIdx + 1
                                local tex = row.icons[iconIdx]
                                if not tex then
                                    tex = row:CreateTexture(nil, "OVERLAY")
                                    tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                                    row.icons[iconIdx] = tex
                                end
                                tex:SetSize(iconSize, iconSize)
                                local thisOff = xOff
                                if firstOfGroup and groupIdx > 1 then
                                    thisOff = -slotGap
                                end
                                tex:ClearAllPoints()
                                tex:SetPoint("RIGHT", lastAnchor, lastPoint, thisOff, 0)
                                tex:SetTexture(list[i])
                                if isActive then
                                    -- Pooled textures keep the previous
                                    -- open's tint, so clear it explicitly.
                                    tex:SetVertexColor(1, 1, 1, 1)
                                else
                                    local dim = RC:GetColor("trinketSwap", "iconDimmed")
                                    tex:SetVertexColor(dim.r, dim.g, dim.b, dim.a or 0.85)
                                end
                                tex:Show()
                                lastAnchor, lastPoint, xOff = tex, "LEFT", -iconGap
                                firstOfGroup = false
                            end
                        end
                    end
                end

                local needed = (nameFs:GetStringWidth() or 0) + (isActive and 26 or 16) + 12
                if showIcons then needed = needed + 46 end
                if needed > menuWidth then menuWidth = math.min(math.ceil(needed), 230) end

                yPos = yPos - 23
            end
        end

        for i = rowIndex + 1, #menu.rowPool do
            menu.rowPool[i]:Hide()
        end

        if not hasConfigs then
            -- Empty state, same shape the settings dropdowns use: a title
            -- line saying what is missing and a hint saying where to fix
            -- it, centred with real padding instead of two strings jammed
            -- against the top of the box.
            if not menu.emptyFs then
                menu.emptyFs     = content:CreateFontString(nil, "OVERLAY")
                menu.emptyHintFs = content:CreateFontString(nil, "OVERLAY")
            end

            yPos = yPos - 9

            local empty = menu.emptyFs
            applyFont(empty, 11, "OUTLINE")
            empty:ClearAllPoints()
            empty:SetPoint("TOP",   content, "TOP",   0, yPos)
            empty:SetPoint("LEFT",  content, "LEFT",  8, 0)
            empty:SetPoint("RIGHT", content, "RIGHT", -8, 0)
            empty:SetJustifyH("CENTER")
            empty:SetText(RCL["No configs yet"])
            local ec = RC:GetColor("trinketSwap", "emptyText")
            empty:SetTextColor(ec.r, ec.g, ec.b, ec.a or 1)
            empty:Show()
            yPos = yPos - 17

            local emptyHint = menu.emptyHintFs
            applyFont(emptyHint, 9, "OUTLINE")
            emptyHint:ClearAllPoints()
            emptyHint:SetPoint("TOP",   content, "TOP",   0, yPos)
            emptyHint:SetPoint("LEFT",  content, "LEFT",  10, 0)
            emptyHint:SetPoint("RIGHT", content, "RIGHT", -10, 0)
            emptyHint:SetJustifyH("CENTER")
            emptyHint:SetWordWrap(true)
            emptyHint:SetText(RCL["Add one in Gear > Trinket Queues."])
            local ehc = RC:GetColor("trinketSwap", "emptyHintText")
            emptyHint:SetTextColor(ehc.r, ehc.g, ehc.b, ehc.a or 1)
            emptyHint:Show()
            -- Measured, not assumed: at this width the hint wraps to two
            -- lines on most fonts, and a fixed 18 clipped the second one.
            yPos = yPos - math.max(11, emptyHint:GetStringHeight() or 11) - 7

            -- An empty list only has to hold two short lines, so it stays
            -- close to the button's own width rather than opening a panel.
            if menuWidth < 140 then menuWidth = 140 end
        elseif menu.emptyFs then
            menu.emptyFs:Hide()
            menu.emptyHintFs:Hide()
        end

        yPos = yPos - 4
        do
            local p13 = RC.GetPendingTrinketForSlot and RC:GetPendingTrinketForSlot(13)
            local p14 = RC.GetPendingTrinketForSlot and RC:GetPendingTrinketForSlot(14)
            if p13 or p14 then
                if not menu.pendingStrip then
                    local st = CreateFrame("Frame", nil, menu)
                    st:SetHeight(20)
                    st.label = RC:CreateFontString(st, "OVERLAY", nil, 9)
                    st.label:SetPoint("LEFT", st, "LEFT", 8, 0)
                    st.icon13 = st:CreateTexture(nil, "ARTWORK")
                    st.icon13:SetSize(14, 14)
                    st.icon14 = st:CreateTexture(nil, "ARTWORK")
                    st.icon14:SetSize(14, 14)
                    menu.pendingStrip = st
                end
                local st = menu.pendingStrip
                st:ClearAllPoints()
                st:SetPoint("BOTTOMLEFT", menu, "BOTTOMLEFT", 0, 2)
                st:SetPoint("BOTTOMRIGHT", menu, "BOTTOMRIGHT", 0, 2)
                st.label:SetText(RCL["Queued:"])
                local gx = st.label
                if p13 and GetItemIcon then
                    st.icon13:SetTexture(GetItemIcon(p13))
                    st.icon13:ClearAllPoints()
                    st.icon13:SetPoint("LEFT", gx, "RIGHT", 6, 0)
                    st.icon13:Show()
                    gx = st.icon13
                else
                    st.icon13:Hide()
                end
                if p14 and GetItemIcon then
                    st.icon14:SetTexture(GetItemIcon(p14))
                    st.icon14:ClearAllPoints()
                    st.icon14:SetPoint("LEFT", gx, "RIGHT", 4, 0)
                    st.icon14:Show()
                else
                    st.icon14:Hide()
                end
                st:Show()
                yPos = yPos - 22
            elseif menu.pendingStrip then
                menu.pendingStrip:Hide()
            end
        end
        menu:SetSize(menuWidth, math.abs(yPos))

        if self.trinketToggleButton then
            menu:ClearAllPoints()
            menu:SetPoint("TOPLEFT", self.trinketToggleButton, "BOTTOMLEFT", 0, -2)
        end

        menu:Show()
        return menu
    end

    -- Single source of truth for the toggle button's status colouring.
    -- Used both by the button's own UpdateButtonState (below) and by
    -- RC:UpdateTrinketToggleButtonState (TSS_Events.lua), which used to
    -- carry a second copy of the same branch tree.
    -- Returns statusColor, textColor.
    function RC:GetTrinketToggleStateColors()
        local ts = self.db and self.db.trinketSwap
        if not ts or not ts.enabled then
            return self:GetColor("trinketSwap", "statusDisabled"),
                   self:GetColor("trinketSwap", "buttonTextOff")
        end

        local status
        if ts.autoSwapActive then
            status = self:GetColor("trinketSwap", "statusActive")
        elseif self.trinketBossPauseState and self.trinketBossPauseState.pausedByBossFight then
            status = self:GetColor("trinketSwap", "statusPaused")
        else
            status = self:GetColor("trinketSwap", "statusManualPause")
        end

        return status, self:GetColor("trinketSwap", "buttonTextOn")
    end

    ------------------------------------------------------------------
    -- THE TOGGLE BUTTON'S LOOK. Built by RC:BuildTrinketToggleFace and
    -- painted by RC:StyleTrinketToggle(button, state): the live button and
    -- the settings preview sample both go through these. Every look
    -- option is optional in db.trinketSwap; nil is the shipped look.
    ------------------------------------------------------------------
    RC.TRINKET_TOGGLE = { width = 75, height = 22, compactSize = 24, iconSize = 9, stripe = 2 }
    RC.TRINKET_TOGGLE_ANIM = { style = "none", duration = 0.3, easing = "easeOutQuad" }

    -- what an unset button font means: the global size less one (9-12)
    function RC:TrinketToggleFontDefaults()
        local fontSize = 10
        if self.db and self.db.fontSettings and self.db.fontSettings.fontSize then
            fontSize = math.max(9, math.min(12, self.db.fontSettings.fontSize - 1))
        end
        return { size = fontSize, outline = "OUTLINE", shadow = false }
    end

    function RC:BuildTrinketToggleFace(button)
        local buttonBg = button:CreateTexture(nil, "BACKGROUND")
        buttonBg:SetAllPoints()
        buttonBg:SetTexture(RC.UI.FLAT)
        button.buttonBg = buttonBg

        button.borders = RC.UI:CreateSimpleBorder(button)

        local stateStripe = button:CreateTexture(nil, "ARTWORK")
        stateStripe:SetPoint("TOPLEFT",    button, "TOPLEFT",    1, -1)
        stateStripe:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 1,  1)
        stateStripe:SetWidth(2)
        stateStripe:SetTexture("Interface\\BUTTONS\\WHITE8X8")
        button.stateStripe = stateStripe

        local dotBorder = button:CreateTexture(nil, "ARTWORK")
        dotBorder:SetTexture(RC.UI.FLAT)
        dotBorder:Hide()

        local statusDot = button:CreateTexture(nil, "OVERLAY")
        statusDot:SetPoint("CENTER", dotBorder, "CENTER")
        statusDot.border = dotBorder
        button.statusDot = statusDot

        -- Arrow cell: a 1px black rule and a gold glyph on the right,
        -- exactly like a settings dropdown, so the button reads as "this
        -- opens a list" instead of as a label that happens to be clickable.
        local arrowRule = button:CreateTexture(nil, "ARTWORK")
        arrowRule:SetWidth(1)
        arrowRule:SetPoint("TOPRIGHT",    button, "TOPRIGHT",    -15, -1)
        arrowRule:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -15,  1)
        arrowRule:SetTexture(RC.UI.FLAT)
        button.arrowRule = arrowRule

        local arrow = button:CreateTexture(nil, "OVERLAY")
        arrow:SetSize(8, 8)
        arrow:SetPoint("RIGHT", button, "RIGHT", -4, 0)
        arrow:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrow")
        button.arrow = arrow

        -- template = a placeholder font until StyleTrinketToggle sets the
        -- real one (the client refuses SetText on a font-less string, and
        -- the compact layout blanks the text before the font is applied)
        local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        text:SetJustifyH("LEFT")
        text:SetWordWrap(false)
        button.text = text
        button.queueIconPool = {}
        return button
    end

    -- The live button's state: queue name and icons, status colours.
    function RC:TrinketToggleLiveState()
        local tss = self.trinketSwapSystem
        local q = tss and tss.currentQueue
        local status, textC = self:GetTrinketToggleStateColors()
        return {
            name = (tss and tss.queueNames[q]) or "Default",
            icons = (self.db.trinketSwap.showQueueIcons ~= false) and self:GetQueueTrinketIcons(q) or nil,
            status = status, textColor = textC,
        }
    end

    local function Col(ts, key, cat, ckey)
        local c = ts[key]
        if type(c) == "table" then return c end
        return RC:GetColor(cat, ckey) or { r = 0, g = 0, b = 0, a = 1 }
    end

    -- Size, layout (compact or full), colours, font and queue icons.
    -- state: { name, icons = { slot1 = {...}, slot2 = {...} } | nil,
    --          status = colour, textColor = colour, hover = bool }
    function RC:StyleTrinketToggle(button, state)
        local ts = self.db.trinketSwap
        local D = RC.TRINKET_TOGGLE
        local isCompact = ts.compactButton and true or false
        local statusDot, dotBorder, text = button.statusDot, button.statusDot.border, button.text

        if isCompact then
            local cs = tonumber(ts.compactSize) or D.compactSize
            button:SetSize(cs, cs)
            dotBorder:ClearAllPoints()
            dotBorder:SetPoint("CENTER", button, "CENTER")
            local ds = math.max(8, cs - 8)
            dotBorder:SetSize(ds, ds)
            statusDot:SetTexture("Interface\\AddOns\\Readycheck\\Media\\rotate")
            statusDot:SetSize(ds, ds)
            if not statusDot.__rcBorderCopies and RC.UI and RC.UI.AddArrowBorder then
                RC.UI:AddArrowBorder(statusDot)
            end
            statusDot:Show()
            button.stateStripe:Hide()
            button.arrow:Hide()
            button.arrowRule:Hide()
            text:Hide()
            text:SetText("")
        else
            button:SetSize(tonumber(ts.buttonWidth) or D.width, tonumber(ts.buttonHeight) or D.height)
            dotBorder:ClearAllPoints()
            dotBorder:SetPoint("LEFT", button, "LEFT", 5, 0)
            dotBorder:SetSize(8, 8)
            statusDot:SetSize(6, 6)
            statusDot:Hide()
            button.stateStripe:SetWidth(tonumber(ts.stripeWidth) or D.stripe)
            button.stateStripe:Show()
            button.arrow:Show()
            button.arrowRule:Show()
            text:Show()
        end
        dotBorder:Hide()
        button.isCompact = isCompact

        local fill = state.hover and RC:GetColor("buttons", "hoverBackground") or Col(ts, "buttonBgColor", "ui", "elementBackground")
        button.buttonBg:SetTexture(RC.UI.FLAT)
        button.buttonBg:SetVertexColor(fill.r, fill.g, fill.b, 1)
        local bordC = Col(ts, "buttonBorderColor", "ui", "borderNormal")
        -- The ring is the border colour in every state; status lives in
        -- the left stripe and the dot, never in the frame outline - a red
        -- box around the whole button read as an error. Gold on hover.
        RC.UI:UpdateBorderColor(button.borders, state.hover and RC:GetColor("ui", "accentGold") or bordC, 1)
        local arrowC = RC:GetColor("dropdown", "arrow") or { r = 0.8, g = 0.65, b = 0.35, a = 1 }
        button.arrow:SetVertexColor(arrowC.r, arrowC.g, arrowC.b, 1)
        button.arrowRule:SetVertexColor(bordC.r, bordC.g, bordC.b, bordC.a or 1)
        local dotBordC = RC:GetColor("ui", "borderNormal") or { r = 0, g = 0, b = 0, a = 1 }
        dotBorder:SetVertexColor(dotBordC.r, dotBordC.g, dotBordC.b, dotBordC.a or 1)

        local st = state.status or RC:GetColor("trinketSwap", "statusActive")
        statusDot:SetVertexColor(st.r, st.g, st.b, 1)
        button.stateStripe:SetVertexColor(st.r, st.g, st.b, 1)

        RC:ApplyFontSpec(text, ts.buttonFont, self:TrinketToggleFontDefaults())
        local tc = state.textColor or RC:GetColor("trinketSwap", "buttonTextOn")
        text:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)

        local pool = button.queueIconPool
        for _, t in ipairs(pool) do t:Hide() end
        if isCompact then return end
        text:SetText(state.name or "Default")

        local anyIcons = false
        local groups = state.icons
        if groups then
            local isz = tonumber(ts.queueIconSize) or D.iconSize
            local idx, lastAnchor, xOff = 0, button, 6
            for groupIdx, slotKey in ipairs({ "slot1", "slot2" }) do
                local list = groups[slotKey]
                if list and #list > 0 then
                    local firstOfGroup = true
                    for i = 1, #list do
                        idx = idx + 1
                        local tex = pool[idx]
                        if not tex then
                            tex = button:CreateTexture(nil, "OVERLAY")
                            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                            pool[idx] = tex
                        end
                        tex:SetSize(isz, isz)
                        tex:ClearAllPoints()
                        local thisOff = xOff
                        if firstOfGroup and groupIdx > 1 then thisOff = 4 end
                        if idx == 1 then
                            tex:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", thisOff, 2)
                        else
                            tex:SetPoint("LEFT", lastAnchor, "RIGHT", thisOff, 0)
                        end
                        tex:SetTexture(list[i])
                        tex:Show()
                        lastAnchor, xOff = tex, 2
                        firstOfGroup = false
                    end
                end
            end
            anyIcons = idx > 0
        end
        text:ClearAllPoints()
        if anyIcons then
            text:SetPoint("TOPLEFT",  button, "TOPLEFT",  6, -1)
            text:SetPoint("TOPRIGHT", button, "TOPRIGHT", -16, -1)
            local own = type(ts.buttonFont) == "table" and tonumber(ts.buttonFont.size)
            text:SetHeight(own and math.max(10, own) or 10)
        else
            text:SetPoint("LEFT",  button, "LEFT", 6, 0)
            text:SetPoint("RIGHT", button.arrowRule, "LEFT", -4, 0)
            text:SetHeight(0)
        end
        -- layer / fade / edge (Trinket Manager); the preview's sample takes
        -- the look only. Nothing set = the button as it always was.
        if self.ApplyFrameCustom then
            self:ApplyFrameCustom(button, function() return RC.db and RC.db.trinketSwap end,
                { sample = (button ~= self.trinketToggleButton), parts = { bg = button.buttonBg, border = button.borders } })
        end
    end

    function RC:TrinketToggleAnim(key)
        return RC.Motion.Normalize(self.db.trinketSwap[key], RC.TRINKET_TOGGLE_ANIM)
    end

    function RC:ShowTrinketToggleButton()
        if self.trinketToggleButton then
            self:CleanupTrinketButtonFontStrings()
            local b = self.trinketToggleButton
            if not b:IsShown() and RC.Motion then RC.Motion.Show(b, self:TrinketToggleAnim("buttonShowAnim")) else b:Show() end
            self:UpdateTrinketButtonCompactMode()
            return
        end

        local button = CreateFrame("Button", "ReadycheckTrinketToggle", UIParent)
        local D = RC.TRINKET_TOGGLE
        button:SetSize(D.width, D.height)

        RC.Position.Bind(button, function()
            self.db.trinketSwap.toggleButtonPosition = self.db.trinketSwap.toggleButtonPosition or {}
            return self.db.trinketSwap.toggleButtonPosition
        end, { point = "CENTER", pointKey = "point", xKey = "x", yKey = "y", default = { x = 0, y = 0 },
               gen2 = { x = 0, y = -180 } })   -- (a fresh character: under the character, not on it)
        RC.Position.RestoreFrame(button)

        self:BuildTrinketToggleFace(button)

        local lastStatus
        local function UpdateButtonState()
            RC:StyleTrinketToggle(button, RC:TrinketToggleLiveState())
            -- a change of state (on, paused, off) gets the attention animation
            local key = RC.db.trinketSwap.enabled and (RC.db.trinketSwap.autoSwapActive and "on" or "paused") or "off"
            if lastStatus and lastStatus ~= key and button:IsVisible() and RC.Motion then
                RC.Motion.Play(button, RC:TrinketToggleAnim("buttonStateAnim"), "update")
            end
            lastStatus = key
        end

        UpdateButtonState()

        button:SetMovable(true)
        button:EnableMouse(true)
        RC.Position.MakeMovable(button, function() return not RC.db.trinketSwap.toggleButtonLocked end)

        local function DoToggleClick()
            RC.db.trinketSwap.enabled = not RC.db.trinketSwap.enabled

            if RC.db.trinketSwap.enabled then
                RC.db.trinketSwap.autoSwapActive = true
                if RC.trinketBossPauseState then
                    RC.trinketBossPauseState.pausedByBossFight = false
                    RC.trinketBossPauseState.originalAutoSwapState = nil
                end
                RC.db.trinketSwap.bossPausedAutoSwap = nil
                RC:ScanAvailableTrinkets()
                for slotNumber = 1, 2 do
                    RC:UpdateTrinketState(slotNumber)
                end
                RC:StartTrinketPolling()
                if not InCombatLockdown() then
                    C_Timer.After(0.3, function()
                        RC:EquipTrinketsFromConfig()
                    end)
                end
                RC:StartEquipRetryLoop(30)
            else
                RC:StopTrinketPolling()
            end

            UpdateButtonState()
            RC:SaveConfigurationToProfile()
        end

        button:RegisterForClicks("LeftButtonUp", "RightButtonUp", "MiddleButtonUp")

        local ACTIONS = {
            toggle = DoToggleClick,
            menu   = function() RC:CreateTrinketDropdown() end,
            hide   = function()
                RC:HideTrinketToggleButton()
                RC.db.trinketSwap.showToggleButton = false
                RC:SaveConfigurationToProfile()
            end,
            lock   = function()
                RC.db.trinketSwap.toggleButtonLocked = not RC.db.trinketSwap.toggleButtonLocked
                RC:Print(RCL["Trinket button "] .. (RC.db.trinketSwap.toggleButtonLocked and "locked" or "unlocked"))
                RC:SaveConfigurationToProfile()
            end,
            none   = function() end,
        }

        button:SetScript("OnClick", function(self, mouseButton)
            local cfg = RC:GetTrinketButtonClicks()
            local base = (mouseButton == "LeftButton") and "Left"
                or (mouseButton == "RightButton") and "Right" or "Middle"
            local mod = IsAltKeyDown() and "alt"
                or IsControlKeyDown() and "ctrl"
                or IsShiftKeyDown() and "shift" or nil
            local slot = mod and (mod .. base) or base:lower()
            local action = cfg[slot] or "none"
            local fn = ACTIONS[action]
            if fn then fn() end
        end)

        button:SetScript("OnEnter", function(self)
            -- Same hover as a settings dropdown: lift the fill, ring it
            -- gold. Gold is the hover/focus accent; the status colour
            -- stays on the left stripe.
            if self.buttonBg then
                local hb = RC:GetColor("buttons", "hoverBackground")
                self.buttonBg:SetVertexColor(hb.r, hb.g, hb.b, 1)
            end
            if self.borders then
                RC.UI:UpdateBorderColor(self.borders, RC:GetColor("ui", "accentGold"), 1)
            end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(RCL["Trinket Auto-Swap"], 1, 1, 1)
            GameTooltip:AddLine(" ")

            if RC.db.trinketSwap.enabled then
                if RC.db.trinketSwap.autoSwapActive then
                    GameTooltip:AddLine(RCL["Status: |cff00ff00Active|r"], 0.8, 0.8, 0.8)
                elseif RC.trinketBossPauseState and RC.trinketBossPauseState.pausedByBossFight then
                    GameTooltip:AddLine(RCL["Status: |cff4d99ffPaused (Boss Fight)|r"], 0.8, 0.8, 0.8)
                else
                    GameTooltip:AddLine(RCL["Status: |cffffcc00Paused (Manual)|r"], 0.8, 0.8, 0.8)
                end
            else
                GameTooltip:AddLine(RCL["Status: |cffff3333Disabled|r"], 0.8, 0.8, 0.8)
            end

            GameTooltip:AddLine(" ")
            local cfg = RC:GetTrinketButtonClicks()
            local NAMES = { toggle = "Toggle ON/OFF", menu = "Open menu",
                            hide = "Hide button", lock = "Lock/Unlock" }
            local ORDER = { {"left","Left-click"}, {"right","Right-click"},
                            {"middle","Middle-click"}, {"altLeft","Alt+Left"},
                            {"altRight","Alt+Right"}, {"altMiddle","Alt+Middle"},
                            {"ctrlLeft","Ctrl+Left"}, {"ctrlRight","Ctrl+Right"},
                            {"ctrlMiddle","Ctrl+Middle"}, {"shiftLeft","Shift+Left"},
                            {"shiftRight","Shift+Right"}, {"shiftMiddle","Shift+Middle"} }
            for _, e in ipairs(ORDER) do
                local label = NAMES[cfg[e[1]]]
                if label then
                    GameTooltip:AddLine(e[2] .. ": " .. label, 0.8, 0.8, 0.8)
                end
            end
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(RCL["Queue: "] .. (RC.trinketSwapSystem.queueNames[RC.trinketSwapSystem.currentQueue] or "Default"), 1, 1, 0)
            if not RC.db.trinketSwap.toggleButtonLocked then
                GameTooltip:AddLine(RCL["Drag to move"], 0.6, 0.6, 0.6)
            end
            GameTooltip:Show()
        end)

        button:SetScript("OnLeave", function(self)
            -- back to the configured fill and ring
            if self.UpdateButtonState then self.UpdateButtonState() end
            GameTooltip:Hide()
        end)

        self.trinketToggleButton = button
        if self.ApplyFrameCustom then
            self:ApplyFrameCustom(button, function() return RC.db and RC.db.trinketSwap end,
                { parts = { bg = button.buttonBg, border = button.borders } })
        end
        button.UpdateButtonState = UpdateButtonState

        RC:AttachMouseoverFade(button, RC._GetTrinketFadeSettings)
        RC:UpdateTrinketButtonMouseoverFade()

        if RC.Motion then RC.Motion.Show(button, self:TrinketToggleAnim("buttonShowAnim")) else button:Show() end
    end

    function RC:UpdateTrinketButtonCompactMode()
        local button = self.trinketToggleButton
        if not button then return end
        if button.UpdateButtonState then button.UpdateButtonState() end
    end

    function RC:HideTrinketToggleButton()
        if self.trinketToggleButton then
            if self.trinketToggleButton.text then
                self.trinketToggleButton.text:SetText("")
            end
            self.trinketToggleButton:Hide()
        end
    end

    function RC:CleanupTrinketButtonFontStrings()
        local button = self.trinketToggleButton
        if not button then return end

        local regions = {button:GetRegions()}
        local foundOrphan = false

        for _, region in ipairs(regions) do
            if region and region:GetObjectType() == "FontString" then
                if region ~= button.text then
                    self:DebugPrint("Found orphaned fontstring on trinket button, cleaning up", "trinket")
                    region:SetText("")
                    region:Hide()
                    region:ClearAllPoints()
                    foundOrphan = true
                end
            end
        end

        if button.textOverlay then
            local overlayRegions = {button.textOverlay:GetRegions()}
            for _, region in ipairs(overlayRegions) do
                if region and region:GetObjectType() == "FontString" then
                    self:DebugPrint("Found orphaned fontstring on trinket button textOverlay, cleaning up", "trinket")
                    region:SetText("")
                    region:Hide()
                    region:ClearAllPoints()
                    foundOrphan = true
                end
            end
        end

        return foundOrphan
    end

    function RC:UpdateTrinketToggleButtonFont()
        local button = self.trinketToggleButton
        if not button or not button.text then return end
        if button.UpdateButtonState then button.UpdateButtonState() end
    end
end
