------------------------------------------------------------------------
-- Readycheck - Consumables Checker: Frame Construction & Item Rows
-- Builds the checker frame chrome (header buttons, search box, scroll
-- area, resize grip) and CreateItemRow, including edit-mode drag/drop
-- reordering across categories. IsWeaponStone here is the same test
-- Checker_Render.lua uses to exclude stone/oil rows from this window.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format = string.format
local GetTime = GetTime
local GetItemCount = GetItemCount or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemCount)
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local WRF = _G.Readycheck
if not WRF then return end
WRF._cckInit = WRF._cckInit or {}
WRF._cck = WRF._cck or {}
WRF._cckInit[#WRF._cckInit + 1] = function()
    local RC = _G.Readycheck
    local _cck = WRF._cck
    local GetAccentGold, GetCardBg, GetHeaderBg, MELLI_TEXTURE = _cck.GetAccentGold, _cck.GetCardBg, _cck.GetHeaderBg, _cck.MELLI_TEXTURE
    local BuildPopupShell = _cck.BuildPopupShell
    local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
    function RC:ShowAddItemPopup()
        if not self.addItemPopup then
            -- Shared flat popup shell from Checker_Base.lua (30px title
            -- bar, gold rule, chromeless X, drag, ESC, PopIn/PopOut).
            local popup = BuildPopupShell("WRAddItemPopup", RCL["Add Custom Item"], 280, 128)
            popup:SetPoint("CENTER")

            local instructLabel = self:CreateFontString(popup, "OVERLAY", nil, 10)
            instructLabel:SetPoint("TOPLEFT", popup, "TOPLEFT", 12, -38)
            instructLabel:SetText(RCL["Enter an item ID (shift-click item for ID):"])
            local instrGray = RC:GetColor("text", "secondary")
            instructLabel:SetTextColor(instrGray.r, instrGray.g, instrGray.b, 1)

            local idEditContainer = RC.UI:CreateStyledEditBox(popup, {
                width = 120, height = 22,
                maxLetters = 8,
                font = 11,
            })
            idEditContainer:SetPoint("TOPLEFT", instructLabel, "BOTTOMLEFT", 0, -8)
            popup.idEditBox = idEditContainer.editBox
            popup.idEditBox:SetAutoFocus(true)
            popup.idEditBox:SetNumeric(true)

            popup.idEditBox:SetScript("OnEscapePressed", function(self)
                self:ClearFocus()
                popup:Close()
            end)

            -- Result line: its colour carries the verdict (success green,
            -- red for a failure) so no colour codes ride in the string.
            popup.resultLabel = self:CreateFontString(popup, "OVERLAY", nil, 10)
            popup.resultLabel:SetPoint("LEFT", idEditContainer, "RIGHT", 8, 0)
            popup.resultLabel:SetPoint("RIGHT", popup, "RIGHT", -12, 0)
            popup.resultLabel:SetJustifyH("LEFT")
            popup.resultLabel:SetText("")
            local function SetResult(text, ok)
                local c = ok and RC:GetColor("text", "success") or RC:GetColor("text", "red")
                popup.resultLabel:SetTextColor(c.r, c.g, c.b, 1)
                popup.resultLabel:SetText(text or "")
            end

            local addBtn = RC.UI:CreateStyledButton(popup, RCL["Add Item"], 110, 22)
            addBtn:SetPoint("BOTTOMLEFT", popup, "BOTTOMLEFT", 12, 12)
            addBtn:SetActive(true)
            addBtn:SetScript("OnClick", function()
                local itemId = tonumber(popup.idEditBox:GetText())
                if itemId and itemId > 0 then
                    local success, msg = RC:AddCustomConsumableItem(itemId, "checker", "custom")
                    if success then
                        SetResult(RCL["Added!"], true)
                        popup.idEditBox:SetText("")
                        if RC.PopulateConsumablesChecker then
                            RC.consumablesChecker._populated = false
                            RC:PopulateConsumablesChecker()
                        end
                        C_Timer.After(0.5, function()
                            if popup:IsShown() then
                                popup.resultLabel:SetText("")
                            end
                        end)
                    else
                        SetResult(msg or RCL["Failed"], false)
                    end
                else
                    SetResult(RCL["Invalid ID"], false)
                end
            end)
            popup.idEditBox:SetScript("OnEnterPressed", function(self)
                addBtn:Click()
            end)

            local cancelBtn = RC.UI:CreateStyledButton(popup, RCL["Close"], 110, 22)
            cancelBtn:SetPoint("LEFT", addBtn, "RIGHT", 10, 0)
            cancelBtn:SetScript("OnClick", function() popup:Close() end)

            self.addItemPopup = popup
        end

        local popup = self.addItemPopup
        popup.idEditBox:SetText("")
        popup.resultLabel:SetText("")
        popup:Open()
        popup.idEditBox:SetFocus()
    end

    function RC:SaveConsumablesCheckerToProfile()
        self:SaveConfigurationToProfile()
    end

    local function GetMailboxBounds()
        if not MailFrame or not MailFrame:IsShown() then return nil end
        local left  = MailFrame:GetLeft()  or 0
        local right = MailFrame:GetRight() or 0
        local top   = MailFrame:GetTop()   or 0
        if OpenMailFrame and OpenMailFrame:IsShown() then
            local r = OpenMailFrame:GetRight() or right
            if r > right then right = r end
            local l = OpenMailFrame:GetLeft() or left
            if l < left then left = l end
        end
        if SendMailFrame and SendMailFrame:IsShown() then
            local r = SendMailFrame:GetRight() or right
            if r > right then right = r end
            local l = SendMailFrame:GetLeft() or left
            if l < left then left = l end
        end
        return left, right, top
    end

    -- One position each for the auction house, the mailbox, and elsewhere.
    local function CheckerStore()
        local cc = RC.db.consumablesChecker
        local context = RC.consumablesChecker.currentContext
        if context == "ah" then
            cc.ahPosition = cc.ahPosition or {}
            return cc.ahPosition
        elseif context == "mailbox" then
            cc.mailboxPosition = cc.mailboxPosition or {}
            return cc.mailboxPosition
        end
        return cc
    end

    function RC:ApplyConsumablesCheckerPosition()
        if not self.consumablesChecker.frame then return end

        local context = self.consumablesChecker.currentContext
        local frame   = self.consumablesChecker.frame

        if context == "ah" and self.db.consumablesChecker.anchorToAH ~= false then
            if AuctionFrame and AuctionFrame:IsShown() then
                local width  = (self.db.consumablesChecker.ahPosition and self.db.consumablesChecker.ahPosition.width)  or 320
                local height = (self.db.consumablesChecker.ahPosition and self.db.consumablesChecker.ahPosition.height) or 480
                frame:SetSize(width, height)
                frame:ClearAllPoints()
                local ahLeft = AuctionFrame:GetLeft() or 0
                if ahLeft > (width + 10) then
                    frame:SetPoint("TOPRIGHT", AuctionFrame, "TOPLEFT", -4, 0)
                else
                    frame:SetPoint("TOPLEFT", AuctionFrame, "TOPRIGHT", 4, 0)
                end
                if frame.scrollChild and frame.scrollFrame then
                    frame.scrollChild:SetWidth(frame.scrollFrame:GetWidth())
                end
                return
            end
        end

        if context == "mailbox" and self.db.consumablesChecker.anchorToMailbox ~= false then
            local left, right, top = GetMailboxBounds()
            if left then
                local width  = (self.db.consumablesChecker.mailboxPosition and self.db.consumablesChecker.mailboxPosition.width)  or 320
                local height = (self.db.consumablesChecker.mailboxPosition and self.db.consumablesChecker.mailboxPosition.height) or 480
                frame:SetSize(width, height)
                frame:ClearAllPoints()
                if left > (width + 10) then
                    frame:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", left - 4, top)
                else
                    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", right + 4, top)
                end
                if frame.scrollChild and frame.scrollFrame then
                    frame.scrollChild:SetWidth(frame.scrollFrame:GetWidth())
                end
                return
            end
        end

        local pos = CheckerStore()
        frame:SetSize(pos.width or 320, pos.height or 480)
        RC.Position.RestoreFrame(frame)
        if frame.scrollChild and frame.scrollFrame then
            frame.scrollChild:SetWidth(frame.scrollFrame:GetWidth())
        end
    end

    local function CheckerFollowsOtherFrame()
        local context = RC.consumablesChecker.currentContext
        local cc = RC.db.consumablesChecker
        if context == "ah" and cc.anchorToAH ~= false then
            return AuctionFrame and AuctionFrame:IsShown()
        end
        if context == "mailbox" and cc.anchorToMailbox ~= false then
            return GetMailboxBounds() ~= nil
        end
        return false
    end

    function RC:SaveConsumablesCheckerPosition()
        local frame = self.consumablesChecker.frame
        if not frame then return end
        local store = CheckerStore()
        store.width, store.height = frame:GetWidth(), frame:GetHeight()
        if not CheckerFollowsOtherFrame() then
            RC.Position.SaveFrame(frame, true)
        end
        self:SaveConsumablesCheckerToProfile()
    end

    -- The window's opening: a PopOut still in flight is cancelled first
    -- (so it cannot hide the window again), then the fade-in. The live
    -- window plays it on every show; the settings preview on Replay.
    local function PlayCheckerOpen(f)
        if f.popAnimation then f.popAnimation:Cancel(); f.popAnimation = nil end
        if RC.UI and RC.UI.FadeIn then RC.UI:FadeIn(f, 0.12) end
    end

    -- The window's parts on frame, in the order the window makes them:
    -- fill and ring, the title bar (mark, title, close, X/Y, +, Edit,
    -- Share), the narrow-window tool row, the search box, the scroll area
    -- and the resize grip, with the header layout that moves the tools.
    -- The live window and the settings preview's sample are the same
    -- window; a sample (sample = true) resets nothing the live window
    -- keeps, makes no drag overlay, and RC.UI:InertSample takes its
    -- clicks away.
    local function BuildCheckerParts(self, frame, sample)
        -- Window shell: flat ui.windowBackground fill, 1px black ring,
        -- 30px flat ui.headerBackground title bar with the addon mark, a
        -- 15px gold title, a 1px gold rule and a chromeless X.
        local bgMainC = RC:GetColor("ui", "windowBackground")
        frame.bg = frame:CreateTexture(nil, "BACKGROUND")
        frame.bg:SetAllPoints()
        frame.bg:SetTexture(FLAT)
        frame.bg:SetVertexColor(bgMainC.r, bgMainC.g, bgMainC.b, 0.97)

        if self.UI and self.UI.CreateSimpleBorder then
            frame.border = self.UI:CreateSimpleBorder(frame, 1)
        end

        local headerBar = CreateFrame("Frame", nil, frame)
        headerBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
        headerBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
        headerBar:SetHeight(30)
        headerBar:SetFrameLevel(frame:GetFrameLevel() + 1)

        local hdrBgC = RC:GetColor("ui", "headerBackground")
        headerBar.bg = headerBar:CreateTexture(nil, "BACKGROUND")
        headerBar.bg:SetAllPoints()
        headerBar.bg:SetTexture(FLAT)
        headerBar.bg:SetVertexColor(hdrBgC.r, hdrBgC.g, hdrBgC.b, hdrBgC.a or 1)

        frame.headerBar = headerBar

        local accentCol = RC:GetColor("ui", "accentGold")
        local headerAccent = headerBar:CreateTexture(nil, "ARTWORK")
        headerAccent:SetPoint("BOTTOMLEFT", headerBar, "BOTTOMLEFT", 0, 0)
        headerAccent:SetPoint("BOTTOMRIGHT", headerBar, "BOTTOMRIGHT", 0, 0)
        headerAccent:SetHeight(1)
        headerAccent:SetTexture(FLAT)
        headerAccent:SetVertexColor(accentCol.r, accentCol.g, accentCol.b, 0.6)
        frame.headerAccent = headerAccent
        -- the header art every Readycheck window wears (UIF_Widgets)
        if RC.UI.ApplyHeaderArt then
            headerAccent:Hide()
            RC.UI:ApplyHeaderArt(headerBar, { stepX = 120 })
        end

        local titleIcon = RC.UI:AddTitleIcon(headerBar, 16, 8)
        local titleCol = RC:GetColor("ui", "headerText")
        frame.title = self:CreateFontString(headerBar, "OVERLAY", nil, 15)
        frame.title:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        frame.title:SetText(RCL["Consumables"])
        frame.title:SetTextColor(titleCol.r, titleCol.g, titleCol.b, 1)
        frame.title:SetWordWrap(false)

        local closeButton = RC.UI:CreateXCloseButton(headerBar, 22, function()
            if sample then return end
            RC.consumablesChecker.wasManuallyShown = false
            if RC.UI.PopOut then RC.UI:PopOut(frame, 0.1) else frame:Hide() end
        end)
        closeButton:SetPoint("RIGHT", headerBar, "RIGHT", -5, 0)
        closeButton:SetFrameLevel(headerBar:GetFrameLevel() + 1)
        frame.closeButton = closeButton
        -- the 5.0 popup header (UIF_Dialogs); the window keeps its own look
        RC.UI:SkinPopup(frame, { header = headerBar, title = frame.title, close = closeButton, chrome = false, scan = false })

        -- Title-bar tools: 20px framework buttons. "On" states (X/Y
        -- showing, edit mode) wear the active look via SetActive rather
        -- than a hand-painted label colour.
        local toggleBtn = RC.UI:CreateStyledButton(headerBar, "X/Y", 34, 20)
        toggleBtn:SetPoint("RIGHT", closeButton, "LEFT", -4, 0)
        toggleBtn:SetFrameLevel(headerBar:GetFrameLevel() + 1)

        local function UpdateToggleButton()
            if RC.db.consumablesChecker.showRecommended then
                toggleBtn.text:SetText("X/Y")
                toggleBtn:SetActive(true)
            else
                toggleBtn.text:SetText("X")
                toggleBtn:SetActive(false)
            end
        end
        UpdateToggleButton()

        toggleBtn:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            local gold = RC:GetColor("text", "gold")
            if RC.db.consumablesChecker.showRecommended then
                local n = RC:GetColor("text", "normal")
                GameTooltip:SetText(RCL["Showing: Count/Recommended"], gold.r, gold.g, gold.b)
                GameTooltip:AddLine(RCL["Click to show count only"], n.r, n.g, n.b)
            else
                local n = RC:GetColor("text", "normal")
                GameTooltip:SetText(RCL["Showing: Count only"], gold.r, gold.g, gold.b)
                GameTooltip:AddLine(RCL["Click to show count/recommended"], n.r, n.g, n.b)
            end
            GameTooltip:AddLine(" ")
            local h = RC:GetColor("ui", "accentGold")
            GameTooltip:AddLine(RCL["Right-click any item to edit its"], h.r, h.g, h.b)
            GameTooltip:AddLine(RCL["recommended amount"], h.r, h.g, h.b)
            GameTooltip:Show()
        end)
        toggleBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
        toggleBtn:SetScript("OnClick", function()
            if sample then return end
            RC.db.consumablesChecker.showRecommended = not RC.db.consumablesChecker.showRecommended
            UpdateToggleButton()
            RC:SaveConsumablesCheckerToProfile()
            RC:UpdateConsumablesCheckerDisplay()
        end)

        frame.toggleBtn = toggleBtn
        frame.UpdateToggleButton = UpdateToggleButton

        local addItemBtn = RC.UI:CreateStyledButton(headerBar, "+", 22, 20)
        addItemBtn:SetPoint("RIGHT", toggleBtn, "LEFT", -4, 0)

        addItemBtn:HookScript("OnEnter", function(btn)
            GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
            local ac = RC:GetColor("text", "gold")
            GameTooltip:SetText(RCL["Add Custom Item"], ac.r, ac.g, ac.b)
            local n = RC:GetColor("text", "normal")
            GameTooltip:AddLine(RCL["Enter an item ID to add a custom consumable"], n.r, n.g, n.b)
            GameTooltip:Show()
        end)
        addItemBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
        addItemBtn:SetScript("OnClick", function()
            if sample then return end
            RC:ShowAddItemPopup()
        end)
        frame.addItemBtn = addItemBtn

        local editBtn = RC.UI:CreateStyledButton(headerBar, RCL["Edit"], 40, 20)
        editBtn:SetPoint("RIGHT", addItemBtn, "LEFT", -4, 0)

        local shareBtn = RC.UI:CreateStyledButton(headerBar, RCL["Share"], 44, 20)
        shareBtn:SetPoint("RIGHT", editBtn, "LEFT", -4, 0)

        shareBtn:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            local gold = RC:GetColor("ui", "accentGold")
            GameTooltip:SetText(RCL["Consumables Report"], gold.r, gold.g, gold.b)
            local n = RC:GetColor("text", "normal")
            GameTooltip:AddLine(RCL["Prints missing and low items to chat."], n.r, n.g, n.b)
            GameTooltip:AddLine(RCL["x = missing   ! = low stock"], n.r, n.g, n.b)
            GameTooltip:Show()
        end)
        shareBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
        shareBtn:SetScript("OnClick", function()
            if sample then return end
            RC:PrintConsumablesReport()
        end)
        frame.shareBtn = shareBtn

        -- RESPONSIVE TOOLS. Five buttons need ~190px; the window can be
        -- 200 wide. Below 340px the tools drop onto their own 24px row
        -- under the title bar and the search box and list move down with
        -- it; above, they sit inline left of the X as before.
        local TOOLS_H, NARROW = 24, 340
        local toolRow = CreateFrame("Frame", nil, frame)
        toolRow:SetPoint("TOPLEFT", headerBar, "BOTTOMLEFT", 0, 0)
        toolRow:SetPoint("TOPRIGHT", headerBar, "BOTTOMRIGHT", 0, 0)
        toolRow:SetHeight(TOOLS_H)
        toolRow:SetFrameLevel(headerBar:GetFrameLevel())
        toolRow.bg = toolRow:CreateTexture(nil, "BACKGROUND")
        toolRow.bg:SetAllPoints()
        toolRow.bg:SetTexture(FLAT)
        do local e = RC:GetColor("ui", "elementBackground"); toolRow.bg:SetVertexColor(e.r, e.g, e.b, 0.6) end
        toolRow:Hide()
        frame.toolRow = toolRow

        local function LayoutHeader(width)
            width = width or frame:GetWidth() or 0
            local narrow = width < NARROW
            if frame._toolsNarrow == narrow then return end
            frame._toolsNarrow = narrow
            local host = narrow and toolRow or headerBar
            for _, b in ipairs({ toggleBtn, addItemBtn, editBtn, shareBtn }) do
                b:SetParent(host)
                b:SetFrameLevel(host:GetFrameLevel() + 1)
            end
            toggleBtn:ClearAllPoints()
            frame.title:ClearAllPoints()
            frame.title:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
            local extra = 0
            if narrow then
                toolRow:Show()
                toggleBtn:SetPoint("RIGHT", toolRow, "RIGHT", -6, 0)
                frame.title:SetPoint("RIGHT", closeButton, "LEFT", -6, 0)
                extra = TOOLS_H
            else
                toolRow:Hide()
                toggleBtn:SetPoint("RIGHT", closeButton, "LEFT", -4, 0)
                frame.title:SetPoint("RIGHT", shareBtn, "LEFT", -8, 0)
            end
            if frame.searchContainer then
                frame.searchContainer:SetPoint("TOPLEFT",  frame, "TOPLEFT",   8, -(36 + extra))
                frame.searchContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -(36 + extra))
            end
            if frame.contentArea then
                frame.contentArea:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -(64 + extra))
            end
        end
        frame.LayoutHeader = LayoutHeader

        if not sample then
            self.consumablesChecker.editMode = false
            self.consumablesChecker.dragData = nil
        end

        if not sample and not self.consumablesChecker.dragOverlay then
            local dragOverlay = CreateFrame("Frame", "WRDragOverlay", UIParent)
            dragOverlay:SetSize(180, 24)
            dragOverlay:SetFrameStrata("TOOLTIP")
            dragOverlay:Hide()

            dragOverlay.bg = dragOverlay:CreateTexture(nil, "BACKGROUND")
            dragOverlay.bg:SetAllPoints()
            dragOverlay.bg:SetTexture(FLAT)
            local dragBg = RC:GetColor("buttons", "hoverBackground")
            dragOverlay.bg:SetVertexColor(dragBg.r, dragBg.g, dragBg.b, 0.95)

            dragOverlay.icon = dragOverlay:CreateTexture(nil, "ARTWORK")
            dragOverlay.icon:SetSize(20, 20)
            dragOverlay.icon:SetPoint("LEFT", 4, 0)
            dragOverlay.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

            dragOverlay.text = dragOverlay:CreateFontString(nil, "OVERLAY")
            RC:ApplyCustomFont(dragOverlay.text, 10)
            dragOverlay.text:SetPoint("LEFT", dragOverlay.icon, "RIGHT", 4, 0)
            dragOverlay.text:SetPoint("RIGHT", -4, 0)
            dragOverlay.text:SetJustifyH("LEFT")
            do local _tn = RC:GetColor("text", "normal"); dragOverlay.text:SetTextColor(_tn.r, _tn.g, _tn.b, 1) end

            local dragAccent = RC:GetColor("ui", "accentGold")
            local b = RC.UI:CreateSimpleBorder(dragOverlay)
            if b.top    then b.top:SetColorTexture(dragAccent.r, dragAccent.g, dragAccent.b, 1) end
            if b.bottom then b.bottom:SetColorTexture(dragAccent.r, dragAccent.g, dragAccent.b, 1) end
            if b.left   then b.left:SetColorTexture(dragAccent.r, dragAccent.g, dragAccent.b, 1) end
            if b.right  then b.right:SetColorTexture(dragAccent.r, dragAccent.g, dragAccent.b, 1) end

            self.consumablesChecker.dragOverlay = dragOverlay
        end

        if not sample and not self.consumablesChecker.insertIndicator then
            local indicator = CreateFrame("Frame", "WRInsertIndicator", UIParent)
            indicator:SetHeight(3)
            indicator:SetWidth(200)
            indicator:SetFrameStrata("TOOLTIP")
            indicator:Hide()

            local line = indicator:CreateTexture(nil, "ARTWORK")
            line:SetAllPoints()
            line:SetTexture(FLAT)
            indicator.line = line

            -- Flat end cap instead of Blizzard radio-button art; kept on
            -- .arrow so UpdateColors below still recolours it.
            local arrow = indicator:CreateTexture(nil, "ARTWORK")
            arrow:SetSize(5, 7)
            arrow:SetPoint("RIGHT", indicator, "LEFT", 1, 0)
            arrow:SetTexture(FLAT)
            indicator.arrow = arrow

            indicator.UpdateColors = function(self)
                local col = RC:GetColor("ui", "insertionLine")
                self.line:SetVertexColor(col.r, col.g, col.b, col.a or 1)
                self.arrow:SetVertexColor(col.r, col.g, col.b, col.a or 1)
            end
            indicator:UpdateColors()

            self.consumablesChecker.insertIndicator = indicator
        end

        local function UpdateEditButton()
            if RC.consumablesChecker.editMode and not sample then
                editBtn.text:SetText(RCL["Done"])
                editBtn:SetActive(true)
            else
                editBtn.text:SetText(RCL["Edit"])
                editBtn:SetActive(false)
            end
        end
        UpdateEditButton()

        editBtn:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            local ac = RC:GetColor("text", "success")
            local g  = RC:GetColor("text", "gold")
            local n  = RC:GetColor("text", "normal")
            if RC.consumablesChecker.editMode then
                GameTooltip:SetText(RCL["Edit Mode: ON"], ac.r, ac.g, ac.b)
                GameTooltip:AddLine(RCL["Click to exit edit mode"], n.r, n.g, n.b)
            else
                GameTooltip:SetText(RCL["Edit Mode"], g.r, g.g, g.b)
                GameTooltip:AddLine(RCL["Drag items to reorder"], n.r, n.g, n.b)
                local h = RC:GetColor("ui", "accentGold")
                GameTooltip:AddLine(RCL["A line shows where the item will land"], h.r, h.g, h.b)
            end
            GameTooltip:Show()
        end)
        editBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
        editBtn:SetScript("OnClick", function()
            if sample then return end
            RC.consumablesChecker.editMode = not RC.consumablesChecker.editMode
            RC.consumablesChecker.dragData = nil
            if RC.consumablesChecker.dragOverlay then
                RC.consumablesChecker.dragOverlay:Hide()
            end
            if RC.consumablesChecker.insertIndicator then
                RC.consumablesChecker.insertIndicator:Hide()
            end
            UpdateEditButton()
            RC.consumablesChecker._populated = false
            RC:PopulateConsumablesChecker()
        end)

        frame.editBtn = editBtn
        frame.UpdateEditButton = UpdateEditButton

        frame:SetScript("OnDragStart", function(f)
            if not RC.db.consumablesChecker.locked then
                f:StartMoving()
            end
        end)

        frame:SetScript("OnDragStop", function(f)
            f:StopMovingOrSizing()
            RC:SaveConsumablesCheckerPosition()
        end)

        headerBar:EnableMouse(true)
        headerBar:RegisterForDrag("LeftButton")
        headerBar:SetScript("OnDragStart", function()
            if not RC.db.consumablesChecker.locked then
                frame:StartMoving()
            end
        end)
        headerBar:SetScript("OnDragStop", function()
            frame:StopMovingOrSizing()
            RC:SaveConsumablesCheckerPosition()
        end)

        -- Framework search box: flat 22px field, gold ring on focus,
        -- placeholder and clear-X built in. Filtering is driven from
        -- onChange exactly as the old hand-rolled OnTextChanged did.
        local function ApplySearch(text)
            RC.consumablesChecker._searchQuery = (text or ""):lower()
            RC:FilterConsumablesCheckerByQuery()
        end
        local searchContainer = self.UI:CreateSearchBox(frame, {
            placeholder = RCL["Search..."],
            font = 10,
            maxLetters = 40,
            onChange = (not sample) and ApplySearch or nil,
        })
        searchContainer:SetPoint("TOPLEFT",  frame, "TOPLEFT",   8, -36)
        searchContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -36)
        frame.searchContainer = searchContainer
        frame.searchEdit = searchContainer.editBox
        frame.searchPlaceholder = searchContainer.placeholderText

        -- ESC clears the filter as before (ClearSearch also fires onChange).
        frame.searchEdit:SetScript("OnEscapePressed", function()
            searchContainer:ClearSearch()
        end)

        local contentArea = CreateFrame("Frame", nil, frame)
        contentArea:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -64)
        contentArea:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 20)
        frame.contentArea = contentArea

        frame.scrollFrame = CreateFrame("ScrollFrame", nil, contentArea)
        frame.scrollFrame:SetPoint("TOPLEFT", contentArea, "TOPLEFT", 0, 0)
        frame.scrollFrame:SetPoint("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", -14, 0)

        frame.scrollChild = CreateFrame("Frame", nil, frame.scrollFrame)
        frame.scrollChild:SetSize(frame.scrollFrame:GetWidth(), 1000)
        frame.scrollFrame:SetScrollChild(frame.scrollChild)

        local scrollBar = RC.UI:AttachScrollbar(frame.scrollFrame, contentArea)
        frame.scrollFrame.scrollBar = scrollBar

        -- Core resize grip (same bounds as the SetResizeBounds call above);
        -- the mouse scripts are overridden so the checker's lock flag and
        -- position saving keep working exactly as before.
        local resizeGrip = RC.UI:AttachResizeGrip(frame, {
            minW = 200, minH = 200, maxW = 500, maxH = 800,
        })

        resizeGrip:SetScript("OnMouseDown", function(self, button)
            if sample then return end
            if button == "LeftButton" and not RC.db.consumablesChecker.locked then
                frame:StartSizing("BOTTOMRIGHT")
            end
        end)

        resizeGrip:SetScript("OnMouseUp", function(self, button)
            if sample then return end
            frame:StopMovingOrSizing()
            RC:SaveConsumablesCheckerPosition()
            if frame.scrollChild then
                frame.scrollChild:SetWidth(frame.scrollFrame:GetWidth())
            end
        end)

        frame:SetScript("OnSizeChanged", function(self, width, height)
            if self.LayoutHeader then self.LayoutHeader(width) end
            if self.scrollChild and self.scrollFrame then
                self.scrollChild:SetWidth(self.scrollFrame:GetWidth())
            end
        end)
        LayoutHeader(frame:GetWidth())

        frame.resizeGrip = resizeGrip
    end

    function RC:CreateConsumablesCheckerFrame()
        if self.consumablesChecker.frame then
            return self.consumablesChecker.frame
        end

        local frame = CreateFrame("Frame", "ReadycheckConsumablesChecker", UIParent)
        local savedWidth = self.db.consumablesChecker.width or 320
        local savedHeight = self.db.consumablesChecker.height or 480
        frame:SetSize(savedWidth, savedHeight)
        RC.Position.Bind(frame, CheckerStore, {
            point = "TOPLEFT", pointKey = "anchorPoint",
            default = { point = "CENTER", x = 0, y = 0 },
        })
        RC.Position.RestoreFrame(frame)
        frame:SetMovable(true)
        frame:SetResizable(true)
        frame:SetResizeBounds(200, 200, 500, 800)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetClampedToScreen(true)
        frame:SetFrameStrata("DIALOG")
        frame:SetToplevel(true)

        RC.UI:RegisterEscapeClose("ReadycheckConsumablesChecker")

        BuildCheckerParts(self, frame)

        -- The 2s display ticker (Checker_Window.lua) exists only while the
        -- window is on screen: started here, cancelled on hide. The show
        -- paths (toggle, AH/mailbox auto-open, sidebar button) all call
        -- frame:Show(), so the fade-in rides OnShow (PlayCheckerOpen).
        frame:HookScript("OnShow", function(f)
            PlayCheckerOpen(f)
            if RC.StartCheckerDisplayTicker then RC:StartCheckerDisplayTicker() end
        end)
        frame:HookScript("OnHide", function()
            if RC.StopCheckerDisplayTicker then RC:StopCheckerDisplayTicker() end
        end)

        self.consumablesChecker.frame = frame
        frame:Hide()
        -- layer / fade / edge (checker page); nothing set = as made
        if self.ApplyFrameCustom then
            self:ApplyFrameCustom(frame, function() return RC.db and RC.db.consumablesChecker end,
                { parts = { bg = frame.bg, border = frame.border } })
        end

        return frame
    end

    -- THE SETTINGS PREVIEW'S WINDOW: the same window (BuildCheckerParts)
    -- on any parent, inert, and never named, in UIParent, the escape list,
    -- UIMover or RC.consumablesChecker.
    function RC:NewCheckerWindowSample(parent)
        local f = CreateFrame("Frame", nil, parent)
        local cc = self.db and self.db.consumablesChecker or {}
        f:SetSize(tonumber(cc.width) or 320, 240)
        f._rcSample = true
        BuildCheckerParts(self, f, true)
        if self.NewCheckerHeaderSample then f.sampleHeader = self:NewCheckerHeaderSample(f.scrollChild) end
        f.sampleRows = {}
        RC.UI:InertSample(f)
        return f
    end

    -- The sample as the window shows one category of these rows (data as
    -- FillCheckerRowSample): its header, a row every 28 px, X/Y as saved,
    -- at the saved width (within the window's bounds) and at the least
    -- height the window can be sized to, so it reads on the strip (the
    -- list scrolls as it does in game). Returns its size.
    function RC:FillCheckerWindowSample(f, categoryName, rows)
        local cc = self.db and self.db.consumablesChecker or {}
        f.UpdateToggleButton()
        f.UpdateEditButton()
        local w = math_max(200, math_min(500, tonumber(cc.width) or 320))
        f:SetWidth(w)
        f.LayoutHeader(w)
        local child = f.scrollChild
        child:SetWidth(f.scrollFrame:GetWidth())
        local y = -4
        local hdr = f.sampleHeader
        if hdr then
            hdr:ClearAllPoints()
            hdr:SetPoint("TOPLEFT", child, "TOPLEFT", 0, y)
            hdr:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, y)
            self:FillCheckerHeaderSample(hdr, categoryName, #rows)
            y = y - 22
        end
        for i, data in ipairs(rows) do
            local row = f.sampleRows[i]
            if not row then
                row = self:NewCheckerRowSample(child)
                f.sampleRows[i] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", child, "TOPLEFT", 2, y)
            row:SetPoint("TOPRIGHT", child, "TOPRIGHT", -2, y)
            row:Show()
            self:FillCheckerRowSample(row, data)
            y = y - 28
        end
        for i = #rows + 1, #f.sampleRows do f.sampleRows[i]:Hide() end
        y = y - 6
        -- the list and its scroll bar as PopulateConsumablesChecker sizes them
        local listH = math.abs(y) + 16
        child:SetHeight(listH)
        f:SetHeight(200)
        local bar = f.scrollFrame.scrollBar
        if bar and bar.SyncRange then bar:SyncRange(listH, f.scrollFrame:GetHeight() or 0) end
        if self.ApplyFrameCustom then
            self:ApplyFrameCustom(f, function() return RC.db and RC.db.consumablesChecker end,
                { parts = { bg = f.bg, border = f.border }, sample = true })
        end
        RC.UI:InertSample(f, true)
        return f:GetWidth(), f:GetHeight()
    end
    -- the window's opening, on the live window or a sample
    function RC:PlayCheckerOpen(f) if f then PlayCheckerOpen(f) end end

    local function IsWeaponStone(itemData)
        return itemData.slot == "mainhand" or itemData.slot == "offhand"
    end

    -- Raid data lists MH/OH weapon-stone entries as separate rows with
    -- "(MH)"/"(OH)" suffixes so they sort and key independently; this strips
    -- the suffix for display only.
    local function GetCleanItemName(itemData)
        local cleanName = itemData.name:gsub("%s*%(MH%)", ""):gsub("%s*%(OH%)", "")
        return cleanName:gsub("%s+$", "")
    end

    local function GetAHSearchName(itemData)
        return itemData.ahSearchName or GetCleanItemName(itemData)
    end

    -- Item rows are pooled: a collapse click repopulates the whole window,
    -- and detaching + recreating every row churned frames that WoW never
    -- garbage-collects. Static children are built once per pool slot; ALL
    -- dynamic state (points, scripts, texts, colors, caches) is reset on
    -- every acquire below. Checker_Render.lua resets the pool at the top
    -- of each populate via _cck.ResetCheckerRowPool.
    local rowPool = {}
    local rowPoolUsed = 0

    -- One row's pieces, built once per pooled row (and by the settings
    -- preview's sample rows, so they look exactly like the real ones).
    local function BuildCheckerRowParts(itemFrame)
        itemFrame:SetHeight(26)

        itemFrame.bg = itemFrame:CreateTexture(nil, "BACKGROUND")
        itemFrame.bg:SetAllPoints()
        itemFrame.bg:SetTexture(MELLI_TEXTURE)

        itemFrame.hoverBorder = RC.UI:CreateSimpleBorder(itemFrame)

        itemFrame.statusBar = itemFrame:CreateTexture(nil, "ARTWORK")
        itemFrame.statusBar:SetPoint("LEFT", itemFrame, "LEFT", 0, 0)
        itemFrame.statusBar:SetSize(3, 26)

        itemFrame.icon = itemFrame:CreateTexture(nil, "ARTWORK")
        itemFrame.icon:SetSize(20, 20)
        itemFrame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        itemFrame.name = RC:CreateFontString(itemFrame, "OVERLAY", nil, 10)
        itemFrame.name:SetPoint("LEFT", itemFrame.icon, "RIGHT", 5, 0)
        itemFrame.name:SetPoint("RIGHT", itemFrame, "RIGHT", -42, 0)
        itemFrame.name:SetJustifyH("LEFT")
        itemFrame.name:SetWordWrap(false)

        itemFrame.count = RC:CreateFontString(itemFrame, "OVERLAY", nil, 10)
        itemFrame.count:SetPoint("RIGHT", itemFrame, "RIGHT", -6, 0)
        itemFrame.count:SetJustifyH("RIGHT")

        -- (a click on a preview sample picks its controls)
        if RC.UI.TagElement then
            RC.UI:TagElement(itemFrame.name, "rowName")
            RC.UI:TagElement(itemFrame.count, "rowCount")
        end
    end

    -- consumablesChecker.anchors.rowName / .rowCount: a spec moves a row's
    -- name / count from where the row puts it; no spec = untouched (a
    -- cleared one puts the row's own points back).
    local function RowTarget(row, k)
        if k == "icon" then return row.icon elseif k == "row" then return row
        elseif k == "name" then return row.name elseif k == "count" then return row.count end
        return nil
    end
    local function PlaceCheckerRowTexts(row)
        local cc = RC.db and RC.db.consumablesChecker
        local anc = cc and type(cc.anchors) == "table" and cc.anchors or nil
        local sn = anc and anc.rowName or nil
        local sc = anc and anc.rowCount or nil
        if (sn or sc) and not row._ccTo then
            row._ccTo = function(k) return RowTarget(row, k) end
        end
        if sn or row._ccNameMoved then
            row.name:ClearAllPoints()
            row.name:SetPoint("LEFT", row.icon, "RIGHT", 5, 0)
            row.name:SetPoint("RIGHT", row, "RIGHT", -42, 0)
            row.name:SetJustifyH("LEFT")
            if sn then
                local d = row._ccNameDef
                if not d then
                    d = { point = "LEFT", relPoint = "RIGHT", x = 5, y = 0, justify = "LEFT",
                          point2 = "RIGHT", relPoint2 = "RIGHT", x2 = -42, y2 = 0 }
                    row._ccNameDef = d
                end
                d.to, d.to2 = row.icon, row
                RC.UI:ApplyAnchor(row.name, sn, d, row._ccTo)
            end
            row._ccNameMoved = sn ~= nil
        end
        if sc or row._ccCountMoved then
            row.count:ClearAllPoints()
            row.count:SetPoint("RIGHT", row, "RIGHT", -6, 0)
            row.count:SetJustifyH("RIGHT")
            if sc then
                row._ccCountDef = row._ccCountDef or { justify = "RIGHT" }
                RC.UI:AnchorOver(row.count, sc, row._ccCountDef, "RIGHT", row, "RIGHT", -6, 0, row._ccTo)
            end
            row._ccCountMoved = sc ~= nil
        end
    end
    _cck.PlaceCheckerRowTexts = PlaceCheckerRowTexts
    -- the rows on screen again after a position changes on the page
    _cck.ApplyCheckerRowCustom = function()
        for i = 1, rowPoolUsed do
            local row = rowPool[i]
            if row then PlaceCheckerRowTexts(row) end
        end
    end

    -- consumablesChecker.formats.count: the count's wording. Nothing saved =
    -- today's "12" / "12/20" (the fast path); the template's [count] / [rec]
    -- default to that same shape.
    local CNT_KINDS = { count = "number", rec = "number" }
    local cntVals = {}
    local CNT_DEF_REC = { abbrev = "full", template = "[count]/[rec]" }
    local CNT_DEF_PLAIN = { abbrev = "full", template = "[count]" }
    RC.CHECKER_COUNT_FORMAT = CNT_DEF_REC          -- "Show recommended" on
    RC.CHECKER_COUNT_FORMAT_PLAIN = CNT_DEF_PLAIN  -- off (or nothing recommended)
    RC.CHECKER_COUNT_TOKENS = { { token = "count", label = RCL["in your bags"] }, { token = "rec", label = RCL["recommended"] } }
    function RC:CheckerCountText(count, recommended, showRecommended, spec)
        if type(spec) ~= "table" then
            if showRecommended and recommended > 0 then return count .. "/" .. recommended end
            return tostring(count)
        end
        cntVals.count, cntVals.rec = count, recommended
        local def = (showRecommended and recommended > 0) and CNT_DEF_REC or CNT_DEF_PLAIN
        return RC.UI:FormatText(spec, def, cntVals, CNT_KINDS, "count")
    end

    -- the icon and name as a row shows them (the live rows and the samples)
    local function DressCheckerRow(itemFrame, iconTex, name, iconLeftOffset, isEnabled)
        itemFrame.icon:ClearAllPoints()
        itemFrame.icon:SetPoint("LEFT", itemFrame, "LEFT", 6 + iconLeftOffset, 0)
        itemFrame.icon:SetTexture(iconTex)
        itemFrame.icon:SetDesaturated(not isEnabled)

        itemFrame.name:SetText(name)
        do local _tw = RC:GetColor("text", "white"); itemFrame.name:SetTextColor(_tw.r, _tw.g, _tw.b, 1) end
        itemFrame.name:SetAlpha(isEnabled and 1 or 0.4)
        PlaceCheckerRowTexts(itemFrame)
    end

    -- The settings preview's sample row: the same pieces, no scripts, never
    -- in the pool. data = { icon, name, count, rec, stock = good|medium|warning|bad }
    local STOCK_COLOR = { bad = "stockEmpty", warning = "stockMedium", medium = "stockLow", good = "stockFull" }
    function RC:NewCheckerRowSample(parent)
        local row = CreateFrame("Button", nil, parent)
        BuildCheckerRowParts(row)
        row:EnableMouse(false)
        row.bg:SetVertexColor(0, 0, 0, 0)
        for _, edge in pairs(row.hoverBorder) do edge:Hide() end
        return row
    end
    function RC:FillCheckerRowSample(row, data)
        local cc = self.db and self.db.consumablesChecker or {}
        DressCheckerRow(row, data.icon, data.name, 3, true)
        local c = RC:GetColor("consumables", STOCK_COLOR[data.stock] or "stockFull")
        local fmt = type(cc.formats) == "table" and cc.formats.count or nil
        row.count:SetText(self:CheckerCountText(data.count, data.rec, cc.showRecommended, fmt))
        row.name:SetTextColor(c.r, c.g, c.b, 1)
        row.count:SetTextColor(c.r, c.g, c.b, 1)
        row.statusBar:SetColorTexture(c.r, c.g, c.b, (data.stock == "bad" or data.stock == "warning") and 1 or 0.8)
    end
    _cck.ResetCheckerRowPool = function()
        rowPoolUsed = 0
        for i = 1, #rowPool do
            rowPool[i]:Hide()
        end
    end

    function RC:CreateItemRow(parent, itemId, itemData, yOffset)
        rowPoolUsed = rowPoolUsed + 1
        local itemFrame = rowPool[rowPoolUsed]
        if not itemFrame then
            itemFrame = CreateFrame("Button", nil, parent)
            BuildCheckerRowParts(itemFrame)

            itemFrame:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            rowPool[rowPoolUsed] = itemFrame
        end

        itemFrame:SetParent(parent)
        itemFrame:ClearAllPoints()
        itemFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 2, yOffset)
        itemFrame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -2, yOffset)
        itemFrame:Show()
        itemFrame.itemId = itemId
        itemFrame.itemData = itemData
        itemFrame.categoryKey = itemData.categoryKey
        itemFrame._cachedColorKey = nil

        local isEnabled = not (self.db.consumablesChecker.disabledItems and self.db.consumablesChecker.disabledItems[itemId])

        itemFrame.bg:SetVertexColor(0, 0, 0, 0)

        local borderHoverCol = RC:GetColor("consumables", "hoverBorder")
        for _, edge in pairs(itemFrame.hoverBorder) do
            edge:SetColorTexture(borderHoverCol.r, borderHoverCol.g, borderHoverCol.b, 1)
            edge:Hide()
        end

        itemFrame.statusBar:SetColorTexture(0, 0, 0, 0)

        itemFrame.count:SetText("")
        itemFrame.count._cachedText = nil

        itemFrame:SetScript("OnClick", function(self, button)
            if button == "RightButton" then
                if RC.ShowRecommendedEditPopup then
                    RC:ShowRecommendedEditPopup(itemId, itemData, self)
                end
                return
            else
                -- 16023/4392/22261: the three Target Dummy variants
                -- (Masterwork/Advanced/Love Fool), see DUMMY_VARIANTS_INFO
                -- in Checker_Base.lua - left-click offers a choice instead
                -- of going straight to an AH search.
                if itemId == 16023 or itemId == 4392 or itemId == 22261 then
                    RC:ShowDummyVariantsPopup(self)
                elseif itemData.materials and #itemData.materials > 0 then
                    RC:ShowMaterialsSearchPopup(itemData, self, itemData.baseItemId or itemId)
                else
                    local searchName = GetAHSearchName(itemData)
                    -- ahSearchName overrides are intentionally broad terms;
                    -- everything else searches exactly so recipes and
                    -- patterns stop outranking the consumable itself.
                    RC:OpenAuctionHouseForItem(itemData.baseItemId or itemId, searchName, itemData.ahSearchName == nil)
                end
            end
        end)

        -- Hover through the framework helper: transparent at rest,
        -- buttons.hoverBackground under the pointer, the ring shown and
        -- the tooltip built in onEnter. Re-attached on every acquire
        -- because the tooltip closes over this row's itemId/itemData.
        local hoverBg = RC:GetColor("buttons", "hoverBackground")
        RC.UI:AttachHover(itemFrame, { r = 0, g = 0, b = 0, a = 0 }, hoverBg, {
            onEnter = function(self)
                self.hoverBorder.top:Show()
                self.hoverBorder.bottom:Show()
                self.hoverBorder.left:Show()
                self.hoverBorder.right:Show()

                local white = RC:GetColor("text", "white")
                local gray  = RC:GetColor("text", "gray")
                local gold  = RC:GetColor("text", "gold")
                local blue  = RC:GetColor("text", "blue")
                local ok    = RC:GetColor("text", "success")
                local norm  = RC:GetColor("text", "normal")

                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(itemData.name, white.r, white.g, white.b)

                local searchName = GetAHSearchName(itemData)
                if searchName ~= itemData.name then
                    GameTooltip:AddLine(RCL["Searches for: "] .. searchName, blue.r, blue.g, blue.b)
                end

                local recommended = RC:GetRecommendedCount(itemId, itemData)
                local isCustom = RC.db.consumablesChecker.customRecommended and RC.db.consumablesChecker.customRecommended[itemId]
                if recommended > 0 then
                    if isCustom then
                        GameTooltip:AddLine(RCL["Recommended: "] .. recommended .. RCL[" (custom)"], gold.r, gold.g, gold.b)
                    else
                        GameTooltip:AddLine(RCL["Recommended: "] .. recommended, gray.r, gray.g, gray.b)
                    end
                end

                if itemData.materials then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(RCL["Required materials:"], gold.r, gold.g, gold.b)
                    for _, mat in ipairs(itemData.materials) do
                        GameTooltip:AddLine("  " .. mat.qty .. "x " .. mat.name, norm.r, norm.g, norm.b)
                    end
                end

                GameTooltip:AddLine(" ")
                if itemData.materials then
                    GameTooltip:AddLine(RCL["Left-click to search materials on AH"], ok.r, ok.g, ok.b)
                else
                    GameTooltip:AddLine(RCL["Left-click to search Auction House"], ok.r, ok.g, ok.b)
                end
                GameTooltip:AddLine(RCL["Right-click to edit recommended amount"], blue.r, blue.g, blue.b)
                GameTooltip:AddLine(RCL["Checkbox toggles tracking"], gray.r, gray.g, gray.b)
                GameTooltip:Show()
            end,
            onLeave = function(self)
                self.hoverBorder.top:Hide()
                self.hoverBorder.bottom:Hide()
                self.hoverBorder.left:Hide()
                self.hoverBorder.right:Hide()
                GameTooltip:Hide()
            end,
        })

        local iconLeftOffset = 3

        if self.consumablesChecker.editMode then
            iconLeftOffset = 22

            -- The handle's chrome is built once per pooled row; the mouse
            -- scripts close over this acquire's itemId/itemData, so they
            -- are re-set on every acquire below.
            local dragHandle = itemFrame.dragHandle
            if not dragHandle then
                dragHandle = CreateFrame("Frame", nil, itemFrame)
                dragHandle:SetSize(18, 24)
                dragHandle:SetPoint("LEFT", itemFrame, "LEFT", 5, 0)
                dragHandle:EnableMouse(true)

                local handleBg = dragHandle:CreateTexture(nil, "BACKGROUND")
                handleBg:SetAllPoints()
                dragHandle.bg = handleBg

                local gripCol = RC:GetColor("text", "disabled")
                for i = 0, 2 do
                    local line = dragHandle:CreateTexture(nil, "ARTWORK")
                    line:SetSize(10, 2)
                    line:SetPoint("CENTER", 0, (i - 1) * 5)
                    line:SetColorTexture(gripCol.r, gripCol.g, gripCol.b, 0.9)
                end

                dragHandle:SetScript("OnEnter", function(self)
                    local hov = RC:GetColor("ui", "accentGold")
                    self.bg:SetColorTexture(hov.r, hov.g, hov.b, 0.35)
                    GameTooltip:SetOwner(self, "ANCHOR_TOP")
                    local w = RC:GetColor("text", "white")
                    GameTooltip:SetText(RCL["Drag to reorder"], w.r, w.g, w.b)
                    local n = RC:GetColor("text", "normal")
                    GameTooltip:AddLine(RCL["A line shows where the item will land"], n.r, n.g, n.b)
                    GameTooltip:AddLine(RCL["Drop on a header to change category"], n.r, n.g, n.b)
                    GameTooltip:Show()
                end)

                dragHandle:SetScript("OnLeave", function(self)
                    local ec = RC:GetColor("ui", "elementBackground")
                    self.bg:SetColorTexture(ec.r, ec.g, ec.b, 0.6)
                    GameTooltip:Hide()
                end)

                itemFrame.dragHandle = dragHandle
            end

            local elemBgC = RC:GetColor("ui", "elementBackground")
            dragHandle.bg:SetColorTexture(elemBgC.r, elemBgC.g, elemBgC.b, 0.6)
            dragHandle:Show()

            dragHandle:SetScript("OnMouseDown", function(self, button)
                if button == "LeftButton" then
                    RC.consumablesChecker.dragData = {
                        itemId = itemId,
                        itemData = itemData,
                        fromCategory = itemFrame.categoryKey,
                        sourceFrame = itemFrame,
                        insertAfter = nil,
                        insertCategory = nil
                    }

                    local overlay = RC.consumablesChecker.dragOverlay
                    if overlay then
                        overlay.icon:SetTexture(RC:GetCachedIcon(itemData.baseItemId or itemId))
                        overlay.text:SetText(itemData.name or ("Item " .. itemId))
                        overlay:Show()

                        -- OnUpdate (project law is normally no OnUpdate) is
                        -- scoped to this drag gesture only: set on mouse-down
                        -- above, cleared on mouse-up below, so it can't run
                        -- unbounded like a background ticker would.
                        overlay:SetScript("OnUpdate", function(self)
                            local cx, cy = GetCursorPosition()
                            local scale = UIParent:GetEffectiveScale()
                            cx = cx / scale
                            cy = cy / scale

                            self:ClearAllPoints()
                            self:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx, cy)

                            local indicator = RC.consumablesChecker.insertIndicator
                            local dragData = RC.consumablesChecker.dragData
                            if not indicator or not dragData then return end

                            local foundInsert = false
                            dragData.insertAfter = nil
                            dragData.insertCategory = nil

                            for catKey, catFrame in pairs(RC.consumablesChecker.categoryFrames or {}) do
                                if catFrame and catFrame.items and catFrame:IsVisible() then
                                    local items = catFrame.items

                                    for i, frame in ipairs(items) do
                                        if frame:IsVisible() and frame ~= dragData.sourceFrame then
                                            local fTop = frame:GetTop()
                                            local fBottom = frame:GetBottom()
                                            local fLeft = frame:GetLeft()
                                            local fRight = frame:GetRight()

                                            if fTop and fBottom and fLeft and fRight then
                                                local midY = (fTop + fBottom) / 2

                                                if cx >= fLeft - 30 and cx <= fRight + 30 and cy >= fBottom - 14 and cy <= fTop + 14 then
                                                    if indicator.UpdateColors then indicator:UpdateColors() end
                                                    if cy >= midY then
                                                        indicator:ClearAllPoints()
                                                        indicator:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", fLeft, fTop + 2)
                                                        indicator:SetWidth(fRight - fLeft)
                                                        indicator:Show()
                                                        dragData.insertAfter = (i > 1) and items[i-1].itemId or "FIRST"
                                                        dragData.insertBefore = frame.itemId
                                                        dragData.insertCategory = catKey
                                                        foundInsert = true
                                                    else
                                                        indicator:ClearAllPoints()
                                                        indicator:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", fLeft, fBottom - 2)
                                                        indicator:SetWidth(fRight - fLeft)
                                                        indicator:Show()
                                                        dragData.insertAfter = frame.itemId
                                                        dragData.insertBefore = items[i+1] and items[i+1].itemId or nil
                                                        dragData.insertCategory = catKey
                                                        foundInsert = true
                                                    end
                                                    break
                                                end
                                            end
                                        end
                                    end
                                    if foundInsert then break end
                                end
                            end

                            if not foundInsert then
                                indicator:Hide()
                            end
                        end)
                    end
                end
            end)

            dragHandle:SetScript("OnMouseUp", function(self, button)
                if button == "LeftButton" and RC.consumablesChecker.dragData then
                    local dragData = RC.consumablesChecker.dragData

                    local overlay = RC.consumablesChecker.dragOverlay
                    if overlay then
                        overlay:Hide()
                        overlay:SetScript("OnUpdate", nil)
                    end

                    local indicator = RC.consumablesChecker.insertIndicator
                    if indicator then
                        indicator:Hide()
                    end

                    if dragData.insertCategory and (dragData.insertAfter or dragData.insertBefore) then
                        local allItemIds = {}
                        local targetCatFrame = RC.consumablesChecker.categoryFrames[dragData.insertCategory]
                        if targetCatFrame and targetCatFrame.items then
                            for _, frame in ipairs(targetCatFrame.items) do
                                if frame.itemId then
                                    table.insert(allItemIds, frame.itemId)
                                end
                            end
                        end

                        if dragData.insertAfter == "FIRST" then
                            if dragData.insertBefore then
                                RC:InsertCheckerItemBefore(dragData.insertCategory, dragData.itemId, dragData.insertBefore, allItemIds)
                            end
                        else
                            RC:InsertCheckerItemAfter(dragData.insertCategory, dragData.itemId, dragData.insertAfter, allItemIds)
                        end

                        if dragData.insertCategory ~= dragData.fromCategory and RC.SetItemCategoryOverride then
                            RC:SetItemCategoryOverride(dragData.itemId, dragData.insertCategory)
                        end
                        RC.consumablesChecker._populated = false
                        RC:PopulateConsumablesChecker()
                    else
                        local cx, cy = GetCursorPosition()
                        local scale = UIParent:GetEffectiveScale()
                        cx = cx / scale
                        cy = cy / scale

                        for catKey, catFrame in pairs(RC.consumablesChecker.categoryFrames or {}) do
                            if catFrame and catFrame:IsVisible() then
                                local l, b = catFrame:GetLeft(), catFrame:GetBottom()
                                local w, h = catFrame:GetWidth(), catFrame:GetHeight()
                                if l and cx >= l and cx <= (l + w) and cy >= b and cy <= (b + h) then
                                    if catKey ~= dragData.fromCategory and RC.SetItemCategoryOverride then
                                        RC:SetItemCategoryOverride(dragData.itemId, catKey)
                                        RC.consumablesChecker._populated = false
                                        RC:PopulateConsumablesChecker()
                                    end
                                    break
                                end
                            end
                        end
                    end

                    RC.consumablesChecker.dragData = nil
                end
            end)
        elseif itemFrame.dragHandle then
            itemFrame.dragHandle:Hide()
        end

        DressCheckerRow(itemFrame, self:GetCachedIcon(itemData.baseItemId or itemId), GetCleanItemName(itemData),
            iconLeftOffset, isEnabled)

        return itemFrame
    end

    _cck.IsWeaponStone = IsWeaponStone
end
