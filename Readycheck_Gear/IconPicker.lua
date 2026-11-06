------------------------------------------------------------------------
-- Readycheck - Icon Picker
-- Resizable icon-grid popup used to choose a gear set's button icon.
-- Pulls candidate icons from equipped/bagged/banked items plus a fixed
-- commonIcons fallback list, so the grid is never empty on a fresh set.
------------------------------------------------------------------------
local function AddIconPicker()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, AddIconPicker)
        return
    end

    local GM = RC.GearManager
    if not GM then
        C_Timer.After(0.5, AddIconPicker)
        return
    end

    -- Fixed fallback icon IDs (generic weapon/armor art) so a brand new
    -- character with nothing equipped still gets a usable grid. Hoisted to
    -- module scope: the list is constant, rebuilding it on every
    -- GetPlayerIcons call just churned a 21-entry table.
    local commonIcons = {
        132761,
        134400,
        136235,
        132602,
        135026,
        132366,
        135641,
        132223,
        132365,
        136021,
        134583,
        133608,
        136192,
        132344,
        132333,
        134916,
        132351,
        132349,
        133476,
        134712,
        134797,
    }

    function GM:GetPlayerIcons()
        local icons = {}
        local seenIcons = {}

        if self.sets then
            for setName, set in pairs(self.sets) do
                if set.icon and type(set.icon) == "number" and not seenIcons[set.icon] then
                    table.insert(icons, set.icon)
                    seenIcons[set.icon] = true
                end
            end
        end

        for slot = 0, 19 do
            local itemTexture = GetInventoryItemTexture("player", slot)
            if itemTexture and type(itemTexture) == "number" and not seenIcons[itemTexture] then
                table.insert(icons, itemTexture)
                seenIcons[itemTexture] = true
            end
        end

        for bag = 0, 4 do
            local numSlots = C_Container.GetContainerNumSlots(bag)
            for bagSlot = 1, numSlots do
                local containerInfo = C_Container.GetContainerItemInfo(bag, bagSlot)
                if containerInfo and containerInfo.iconFileID then
                    local itemTexture = containerInfo.iconFileID
                    if type(itemTexture) == "number" and not seenIcons[itemTexture] then
                        table.insert(icons, itemTexture)
                        seenIcons[itemTexture] = true
                    end
                end
            end
        end

        if BankFrame and BankFrame:IsShown() then
            for bankSlot = 1, 28 do
                local itemTexture = GetInventoryItemTexture("player", BankButtonIDToInvSlotID(bankSlot))
                if itemTexture and type(itemTexture) == "number" and not seenIcons[itemTexture] then
                    table.insert(icons, itemTexture)
                    seenIcons[itemTexture] = true
                end
            end
        end

        for _, iconID in ipairs(commonIcons) do
            if not seenIcons[iconID] then
                table.insert(icons, iconID)
                seenIcons[iconID] = true
            end
        end

        table.sort(icons)

        return icons
    end

    ------------------------------------------------------------------
    -- Picker window
    --
    -- The popup and its icon grid are built exactly once and cached on
    -- pickerFrame (also exposed as _G.WRIconPickerGrid). WoW frames are
    -- never garbage collected, so the old "recreate the window on every
    -- open, and recreate every grid button again on every resize" flow
    -- leaked the whole window plus one Button (and six textures) per icon
    -- every single time. The grid buttons are now pooled by index in
    -- picker.iconButtons: reused and re-textured in place, with the
    -- surplus hidden rather than orphaned.
    --
    -- Handlers are created once, shared by every pooled button, and read
    -- the icon they act on from self.iconID / self.isSelected (set during
    -- layout), so a recycled button can never fire on the icon it used to
    -- display.
    ------------------------------------------------------------------
    local pickerFrame

    local MIN_WIDTH, MAX_WIDTH = 280, 600
    local MIN_HEIGHT, MAX_HEIGHT = 200, 500

    local SCROLL_BAR_WIDTH = 16
    -- Title bar (30) + search row (22 + gaps) sit above the grid.
    local CONTENT_TOP, CONTENT_BOTTOM = -66, 20
    local CONTENT_LEFT = 10
    local CONTENT_RIGHT = 10 + SCROLL_BAR_WIDTH + 6

    local ICON_PADDING = 3
    local ICONS_PER_ROW = 8

    local function BuildIconPicker()
        -- Furniture paints with the flat pixel, never the statusbar
        -- texture (that is a gradient reserved for real bars).
        local function GetTexture()
            if RC.UI and RC.UI.FLAT then
                return RC.UI.FLAT
            end
            return "Interface\\Buttons\\WHITE8X8"
        end

        local picker = CreateFrame("Frame", "WRIconPickerGrid", UIParent)
        picker:SetSize(370, 280)
        picker:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        picker:SetFrameStrata("DIALOG")
        picker:SetToplevel(true)
        picker:EnableMouse(true)
        picker:SetMovable(true)
        picker:Hide()

        -- Per-open state the cached frame's scripts read instead of the
        -- upvalues the old rebuild-every-time version closed over.
        picker.icons = {}
        picker.iconButtons = {}
        picker.callback = nil
        picker.currentIcon = nil
        picker.searchText = ""

        picker:SetScript("OnShow", function(self)
            self:Raise()
        end)

        picker:SetScript("OnMouseDown", function(self)
            self:Raise()
        end)

        RC.UI:RegisterEscapeClose("WRIconPickerGrid")

        local windowCol = RC:GetColor("ui", "windowBackground")
        local bg = picker:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(GetTexture())
        bg:SetVertexColor(windowCol.r, windowCol.g, windowCol.b, 0.95)
        picker.bg = bg

        RC.UI:CreateSimpleBorder(picker, 1)

        local headerBar = CreateFrame("Frame", nil, picker)
        headerBar:SetPoint("TOPLEFT", picker, "TOPLEFT", 1, -1)
        headerBar:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -1, -1)
        headerBar:SetHeight(30)
        headerBar:EnableMouse(true)
        headerBar:RegisterForDrag("LeftButton")
        headerBar:SetScript("OnDragStart", function() picker:StartMoving() end)
        headerBar:SetScript("OnDragStop", function() picker:StopMovingOrSizing() end)

        local headerCol = RC:GetColor("ui", "headerBackground")
        local headerBg = headerBar:CreateTexture(nil, "BACKGROUND")
        headerBg:SetAllPoints()
        headerBg:SetTexture(GetTexture())
        headerBg:SetVertexColor(headerCol.r, headerCol.g, headerCol.b, 1)
        picker.headerBg = headerBg

        -- One gold rule under the title bar - the only accent on the shell.
        local headerAccent = headerBar:CreateTexture(nil, "ARTWORK")
        headerAccent:SetPoint("BOTTOMLEFT", headerBar, "BOTTOMLEFT", 0, 0)
        headerAccent:SetPoint("BOTTOMRIGHT", headerBar, "BOTTOMRIGHT", 0, 0)
        headerAccent:SetHeight(1)
        local accentCol = RC:GetColor("ui", "accentGold")
        headerAccent:SetTexture(GetTexture())
        headerAccent:SetVertexColor(accentCol.r, accentCol.g, accentCol.b, 0.6)

        local titleCol = RC:GetColor("ui", "headerText")
        local titleIcon = RC.UI:AddTitleIcon(headerBar, 14, 8)
        headerBg:SetTexture(RC.UI.FLAT or "Interface\\Buttons\\WHITE8X8")
        -- the header art every Readycheck window wears (gradient fill, the
        -- stepped accent rule); replaces the flat fill and the single rule
        if RC.UI.ApplyHeaderArt then
            headerAccent:Hide()
            RC.UI:ApplyHeaderArt(headerBar, { fill = headerBg, stepX = 160 })
        end

        local title = RC:CreateFontString(headerBar, "OVERLAY", nil, 15)
        title:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        title:SetTextColor(titleCol.r, titleCol.g, titleCol.b, titleCol.a or 1)
        picker.titleText = title

        -- Chromeless X from the framework (buttons.xNormal -> xHover).
        -- Hides the cached frame; it is never discarded, so the next open
        -- reuses it (and its pooled grid buttons) instead of rebuilding.
        local closeBtn = RC.UI:CreateXCloseButton(headerBar, 22, function()
            picker:Close()
        end)
        closeBtn:SetPoint("RIGHT", headerBar, "RIGHT", -5, 0)
        closeBtn:SetFrameLevel(headerBar:GetFrameLevel() + 2)
        picker.closeBtn = closeBtn

        -- Search row under the title bar: filters the grid by icon ID
        -- (the only text the picker knows about each icon).
        local searchBox = RC.UI:CreateSearchBox(picker, {
            placeholder = RCL["Search..."],
            font = 11,
            maxLetters = 20,
            onChange = function(txt)
                picker.searchText = txt or ""
                if picker.LayoutIconGrid then
                    picker:LayoutIconGrid()
                    if picker.scrollBar then picker.scrollBar:SetValue(0) end
                end
            end,
        })
        searchBox:SetPoint("TOPLEFT", picker, "TOPLEFT", CONTENT_LEFT, -38)
        searchBox:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -CONTENT_LEFT, -38)
        searchBox:SetFrameLevel(picker:GetFrameLevel() + 2)
        picker.searchBox = searchBox

        local scrollFrame = CreateFrame("ScrollFrame", nil, picker)
        scrollFrame:SetPoint("TOPLEFT", CONTENT_LEFT, CONTENT_TOP)
        scrollFrame:SetPoint("BOTTOMRIGHT", -CONTENT_RIGHT, CONTENT_BOTTOM)
        scrollFrame:SetFrameLevel(picker:GetFrameLevel() + 1)
        scrollFrame:EnableMouseWheel(true)
        picker.scrollFrame = scrollFrame

        local scrollChild = CreateFrame("Frame", nil, scrollFrame)
        scrollChild:SetSize(scrollFrame:GetWidth(), 1)
        scrollFrame:SetScrollChild(scrollChild)
        picker.scrollChild = scrollChild

        -- Framework scrollbar (flat track, block thumb, 1px edge). The
        -- gutter frame reproduces the old geometry: 16px strip hugging the
        -- picker's right edge between the search row and the bottom pad.
        local scrollGutter = CreateFrame("Frame", nil, picker)
        scrollGutter:SetWidth(SCROLL_BAR_WIDTH + 6)
        scrollGutter:SetPoint("TOPRIGHT", picker, "TOPRIGHT", -3, CONTENT_TOP + 6)
        scrollGutter:SetPoint("BOTTOMRIGHT", picker, "BOTTOMRIGHT", -3, CONTENT_BOTTOM - 6)
        local scrollBar = RC.UI:AttachScrollbar(scrollFrame, scrollGutter, { width = SCROLL_BAR_WIDTH })
        picker.scrollBar = scrollBar

        scrollFrame:SetScript("OnMouseWheel", function(self, delta)
            local current = scrollBar:GetValue()
            local min, max = scrollBar:GetMinMaxValues()
            local step = 40
            local newValue = math.max(min, math.min(max, current - (delta * step)))
            scrollBar:SetValue(newValue)
        end)

        local function GetButtonSize()
            local availableWidth = scrollFrame:GetWidth() - 4
            local size = math.floor((availableWidth - (ICON_PADDING * (ICONS_PER_ROW - 1))) / ICONS_PER_ROW)
            return math.max(24, math.min(48, size))
        end

        -- Tile look: flat buttons.normalBackground fill under the icon and
        -- a 1px black ring at rest; the selected tile wears the green
        -- configured fill with a muted GREEN ring (same as an active
        -- button); hover swaps the fill to buttons.hoverBackground. Gold
        -- is the "open / you are here" accent and never rings a green fill.
        local function PaintTile(btn, hot)
            local border
            if btn.isSelected then
                local fill = RC:GetColor("buttons", "configuredBackground")
                btn.bg:SetVertexColor(fill.r, fill.g, fill.b, 1)
                border = RC:GetColor("ui", "borderSelected")
                for _, side in pairs(btn.borders) do
                    side:SetColorTexture(border.r, border.g, border.b, 1)
                end
            else
                local fill = hot and RC:GetColor("buttons", "hoverBackground") or RC:GetColor("buttons", "normalBackground")
                btn.bg:SetVertexColor(fill.r, fill.g, fill.b, 1)
                border = RC:GetColor("ui", "borderNormal")
                for _, side in pairs(btn.borders) do
                    side:SetColorTexture(border.r, border.g, border.b, border.a or 1)
                end
            end
        end

        local function ApplyBorderColor(btn)
            PaintTile(btn, false)
        end

        local function IconButtonOnEnter(self)
            self.hoverHighlight:Show()
            PaintTile(self, true)

            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(RCL["Icon ID: "] .. tostring(self.iconID))
            if self.isSelected then
                GameTooltip:AddLine(RCL["(Currently selected)"], 0, 1, 0)
            end
            GameTooltip:Show()
        end

        local function IconButtonOnLeave(self)
            self.hoverHighlight:Hide()
            PaintTile(self, false)
            GameTooltip:Hide()
        end

        local function IconButtonOnClick(self)
            local iconID = self.iconID
            if not iconID then return end
            local callback = picker.callback
            if callback then
                callback(iconID)
            end
            picker:Close()
        end

        -- Returns the pooled button for this grid index, creating it only
        -- the first time that index is ever needed.
        local function AcquireIconButton(index)
            local btn = picker.iconButtons[index]
            if btn then return btn end

            btn = CreateFrame("Button", nil, scrollChild)
            btn:SetFrameLevel(scrollChild:GetFrameLevel() + 2)

            -- Flat tile fill behind the icon (inset 2px like every other
            -- icon tile), painted by PaintTile.
            local tileBg = btn:CreateTexture(nil, "BACKGROUND")
            tileBg:SetAllPoints(btn)
            tileBg:SetTexture(GetTexture())
            btn.bg = tileBg

            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetPoint("TOPLEFT", btn, "TOPLEFT", 2, -2)
            tex:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
            tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            btn.icon = tex

            -- 1px ring from the framework; PaintTile recolours it (black
            -- at rest, gold 0.7 when selected).
            btn.borders = RC.UI:CreateSimpleBorder(btn, 1, 0)

            -- Same additive white 0.05 lift the framework's buttons use.
            local lift = RC.UI.C and RC.UI.C.whiteHint or { 1, 1, 1, 0.05 }
            local hoverHighlight = btn:CreateTexture(nil, "ARTWORK", nil, 7)
            hoverHighlight:SetAllPoints()
            hoverHighlight:SetColorTexture(lift[1], lift[2], lift[3], lift[4])
            hoverHighlight:SetBlendMode("ADD")
            hoverHighlight:Hide()
            btn.hoverHighlight = hoverHighlight

            -- Kept as a field for the layout code, but the selected state
            -- is now carried by the green fill + gold ring (PaintTile), so
            -- this overlay stays hidden.
            local selOverlay = btn:CreateTexture(nil, "ARTWORK", nil, 6)
            selOverlay:SetAllPoints()
            selOverlay:SetColorTexture(0, 0, 0, 0)
            selOverlay:Hide()
            btn.selOverlay = selOverlay

            btn:SetScript("OnEnter", IconButtonOnEnter)
            btn:SetScript("OnLeave", IconButtonOnLeave)
            btn:SetScript("OnClick", IconButtonOnClick)

            picker.iconButtons[index] = btn
            return btn
        end

        -- Re-flows the pooled buttons over picker.icons. Called on open and
        -- on resize; never creates a button that already exists.
        local function LayoutIconGrid()
            local allIcons = picker.icons or {}
            local buttonSize = GetButtonSize()
            local xOffset, yOffset = 2, -2

            -- Search filters by icon ID substring; an empty box shows all.
            local needle = picker.searchText or ""
            local icons = allIcons
            if needle ~= "" then
                icons = {}
                for i = 1, #allIcons do
                    if string.find(tostring(allIcons[i]), needle, 1, true) then
                        icons[#icons + 1] = allIcons[i]
                    end
                end
            end

            for i = 1, #icons do
                local iconID = icons[i]
                local btn = AcquireIconButton(i)

                btn.iconID = iconID
                btn.isSelected = (picker.currentIcon == iconID)

                btn:SetSize(buttonSize, buttonSize)
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", xOffset, yOffset)

                btn.icon:SetTexture(iconID)
                btn.hoverHighlight:Hide()
                btn.selOverlay:Hide()
                ApplyBorderColor(btn)
                btn:Show()

                xOffset = xOffset + buttonSize + ICON_PADDING
                if i % ICONS_PER_ROW == 0 then
                    xOffset = 2
                    yOffset = yOffset - (buttonSize + ICON_PADDING)
                end
            end

            -- Surplus pooled buttons stay parented but hidden and lose
            -- their icon, so a stale one can never be clicked.
            for i = #icons + 1, #picker.iconButtons do
                local btn = picker.iconButtons[i]
                btn.iconID = nil
                btn.isSelected = false
                btn.hoverHighlight:Hide()
                btn.selOverlay:Hide()
                btn:Hide()
            end

            local rows = math.ceil(#icons / ICONS_PER_ROW)
            local contentHeight = rows * (buttonSize + ICON_PADDING) + 10
            scrollChild:SetHeight(contentHeight)
            scrollChild:SetWidth(scrollFrame:GetWidth())

            -- SyncRange sets the thumb range and auto-hides the bar when
            -- everything fits.
            scrollBar:SyncRange(contentHeight, scrollFrame:GetHeight())
        end

        picker.LayoutIconGrid = LayoutIconGrid

        -- PopOut then hide; the ESC path (UISpecialFrames) still hides
        -- instantly, which is fine for a keyboard dismiss.
        function picker:Close()
            if not self:IsShown() then return end
            if self.popAnimation then return end
            RC.UI:PopOut(self, 0.1, function()
                -- PopOut resets scale to 1; put the user's scale back.
                local s = GM.settings and GM.settings.iconPicker
                self:SetScale((s and s.scale) or 1.0)
            end)
        end

        -- Core resize grip (same bounds the picker used before). Only the
        -- mouse-up script is overridden, so the user's remembered size is
        -- still saved and the pooled grid re-flows to the new width.
        local resizeGrip = RC.UI:AttachResizeGrip(picker, {
            minW = MIN_WIDTH, minH = MIN_HEIGHT,
            maxW = MAX_WIDTH, maxH = MAX_HEIGHT,
            onResize = function(self)
                if self.scrollChild and self.scrollFrame then
                    self.scrollChild:SetWidth(self.scrollFrame:GetWidth())
                end
            end,
        })

        -- Size only persists on mouse-up, not during the drag, so the grid
        -- isn't re-laid out every frame while resizing.
        resizeGrip:SetScript("OnMouseUp", function()
            picker:StopMovingOrSizing()
            GM.settings = GM.settings or {}
            GM.settings.iconPicker = GM.settings.iconPicker or {}
            GM.settings.iconPicker.width = picker:GetWidth()
            GM.settings.iconPicker.height = picker:GetHeight()
            GM:SaveSettings()
            LayoutIconGrid()
        end)

        picker.resizeGrip = resizeGrip

        pickerFrame = picker
        _G.WRIconPickerGrid = picker
        return picker
    end

    -- anchorButton/anchorDirection are accepted because call sites pass
    -- them, but the picker has always opened centred on screen.
    function GM:ShowIconPickerGrid(callback, currentIcon, anchorButton, anchorDirection)
        if not RC or not RC.UI then
            self:DebugPrint("UI Framework not loaded")
            return
        end

        local picker = pickerFrame or BuildIconPicker()
        if not picker then return end

        local settings = (self.settings and self.settings.iconPicker) or {}
        if picker.popAnimation then RC.UI:StopAnimations(picker) end
        picker:SetSize(settings.width or 370, settings.height or 280)
        picker:SetScale(settings.scale or 1.0)
        picker:ClearAllPoints()
        picker:SetPoint("CENTER", UIParent, "CENTER", 0, 0)

        picker.callback = callback
        picker.currentIcon = currentIcon
        picker.icons = self:GetPlayerIcons()
        picker.searchText = ""
        if picker.searchBox and picker.searchBox.editBox then
            picker.searchBox.editBox:SetText("")
            picker.searchBox.editBox:ClearFocus()
        end

        picker.titleText:SetText(RCL["Choose Icon ("] .. #picker.icons .. RCL[" available)"])

        picker:LayoutIconGrid()
        picker.scrollBar:SetValue(0)
        picker:Raise()
        -- PopIn ends at scale 1, so a picker the user has scaled gets the
        -- alpha-only fade instead of the scale pop.
        if (settings.scale or 1.0) == 1.0 then
            RC.UI:PopIn(picker, 0.12)
        else
            RC.UI:FadeIn(picker, 0.12)
        end
    end
end

C_Timer.After(2, AddIconPicker)
