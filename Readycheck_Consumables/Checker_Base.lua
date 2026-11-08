------------------------------------------------------------------------
-- Readycheck - Consumables Checker: Data & Popups
-- Owns checker saved-variable defaults, recommended-count resolution
-- (GetRecommendedCount/SetRecommendedCount), the dummy-variant and
-- recommended-amount edit popups, and the raid-entry "missing
-- consumables" alert (RunRaidConsumablesCheck).
------------------------------------------------------------------------
local RCC = _G.Readycheck
local RC = RCC
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

    if not RC.raidConsumables then
        RC:Print(RCL["ERROR: WR.raidConsumables not loaded from Database.lua!"])
        RC:Print(RCL["Make sure Database.lua loads before ConsumablesChecker.lua"])
        return
    end

    -- Furniture is flat (WHITE8X8 vertex-coloured); the statusbar texture
    -- is reserved for real bars. MELLI_TEXTURE keeps its name because
    -- Checker_Popup.lua reads it from _cck for the item-row fill.
    local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
    local MELLI_TEXTURE = FLAT
    local ARROW_UP = "Interface\\AddOns\\Readycheck\\Media\\arrowUp"
    local ARROW_DOWN = "Interface\\AddOns\\Readycheck\\Media\\arrow"
    local SCROLL_THUMB = "Interface\\AddOns\\Readycheck\\Media\\scrollThumb"

    local function GetCardBg()
        return RC:GetColor("ui", "cardBackground")
    end
    local function GetHeaderBg()
        return RC:GetColor("ui", "headerBackground")
    end
    local function GetAccentGold()
        return RC:GetColor("ui", "accentGold")
    end

    function RC:GetCachedIcon(itemId)
        -- Never hard-depend on the bars' icon cache being initialized;
        -- fall back to a direct icon lookup so the checker can't crash.
        if self.GetCachedItemIcon then
            return self:GetCachedItemIcon(itemId) or 134400
        end
        return (GetItemIcon and GetItemIcon(itemId)) or 134400
    end

    RC.consumablesChecker = {
        frame = nil,
        categoryFrames = {},
        updateTimer = nil,
        wasManuallyShown = false,
        mailboxOpen = false,
        currentContext = "manual"
    }

    function RC:InitializeConsumablesCheckerDefaults()
        if not RC.db.consumablesChecker then
            RC.db.consumablesChecker = {
                enabled = true,
                locked = false,
                anchorPoint = "CENTER",
                xOffset = 0,
                yOffset = 0,
                width = 320,
                height = 480,
                showInCity = true,
                showInRaid = true,
                hideInCombat = false,
                showOnlyMissing = false,
                disabledItems = {},
                collapsedCategories = {},
                showRecommended = true,
                customRecommended = {},
                ahPosition = { anchorPoint = "CENTER", xOffset = 0, yOffset = 0, width = 320, height = 480 },
                mailboxPosition = { anchorPoint = "CENTER", xOffset = 0, yOffset = 0, width = 320, height = 480 },
                anchorToAH = true,
                anchorToMailbox = true
            }
        end

        if not RC.db.consumablesChecker.disabledItems then
            RC.db.consumablesChecker.disabledItems = {}
        end
        if not RC.db.consumablesChecker.collapsedCategories then
            RC.db.consumablesChecker.collapsedCategories = {}
        end
        if not RC.db.consumablesChecker.width then
            RC.db.consumablesChecker.width = 320
        end
        if not RC.db.consumablesChecker.height then
            RC.db.consumablesChecker.height = 480
        end
        if RC.db.consumablesChecker.showRecommended == nil then
            RC.db.consumablesChecker.showRecommended = true
        end
        if not RC.db.consumablesChecker.customRecommended then
            RC.db.consumablesChecker.customRecommended = {}
        end
        if not RC.db.consumablesChecker.ahPosition then
            RC.db.consumablesChecker.ahPosition = { anchorPoint = "CENTER", xOffset = 0, yOffset = 0, width = 320, height = 480 }
        end
        if not RC.db.consumablesChecker.mailboxPosition then
            RC.db.consumablesChecker.mailboxPosition = { anchorPoint = "CENTER", xOffset = 0, yOffset = 0, width = 320, height = 480 }
        end
        if not RC.db.consumablesChecker.ahPosition.width then
            RC.db.consumablesChecker.ahPosition.width = 320
            RC.db.consumablesChecker.ahPosition.height = 480
        end
        if not RC.db.consumablesChecker.mailboxPosition.width then
            RC.db.consumablesChecker.mailboxPosition.width = 320
            RC.db.consumablesChecker.mailboxPosition.height = 480
        end
        if RC.db.consumablesChecker.anchorToAH == nil then
            RC.db.consumablesChecker.anchorToAH = true
        end
        if RC.db.consumablesChecker.anchorToMailbox == nil then
            RC.db.consumablesChecker.anchorToMailbox = true
        end
        if RC.db.consumablesChecker.reportOnAHOpen == nil then
            RC.db.consumablesChecker.reportOnAHOpen = false
        end
        if not RC.db.consumablesChecker.priorityItems then
            RC.db.consumablesChecker.priorityItems = {}
        end
        if RC.db.consumablesChecker.raidEntryAlertPrioOnly == nil then
            RC.db.consumablesChecker.raidEntryAlertPrioOnly = false
        end
        RC.db.consumablesChecker.scale = nil
        RC.db.consumablesChecker.warningThreshold = nil
    end

    -- Recommended count precedence: per-item custom override (set via the
    -- recommended-amount popup) beats the itemData.recommended default from
    -- raidConsumables. 0/nil means "not tracked" - callers gate missing/low
    -- calculations on recommended > 0.
    function RC:GetRecommendedCount(itemId, itemData)
        if self.db.consumablesChecker.customRecommended and self.db.consumablesChecker.customRecommended[itemId] then
            return self.db.consumablesChecker.customRecommended[itemId]
        end
        return itemData.recommended or 0
    end

    function RC:SetRecommendedCount(itemId, value)
        if not self.db.consumablesChecker.customRecommended then
            self.db.consumablesChecker.customRecommended = {}
        end
        if value and value > 0 then
            self.db.consumablesChecker.customRecommended[itemId] = value
        else
            self.db.consumablesChecker.customRecommended[itemId] = nil
        end
        self:SaveConfigurationToProfile()
        self:UpdateConsumablesCheckerDisplay()
    end

    function RC:FilterConsumablesCheckerByQuery()
        if not self.consumablesChecker or not self.consumablesChecker.categoryFrames then
            return
        end
        local q = (self.consumablesChecker._searchQuery or ""):gsub("^%s*(.-)%s*$", "%1"):lower()
        local hasQuery = q and q ~= ""

        local frame = self.consumablesChecker.frame
        local scrollChild = frame and frame.scrollChild
        local scrollFrame = frame and frame.scrollFrame
        if not scrollChild or not scrollFrame then return end

        local categoryOrder = {"flasks", "elixirs", "food", "drinks", "potions",
            "protectionPotions", "buffs", "utilities", "classItems", "reagents",
            "chronoboon", "special"}

        local seen = {}
        for _, k in ipairs(categoryOrder) do seen[k] = true end
        for catKey in pairs(self.consumablesChecker.categoryFrames) do
            if not seen[catKey] then table.insert(categoryOrder, catKey) end
        end

        local ITEM_ROW_H  = 28
        local CAT_HEAD_H  = 20
        local CAT_GAP     = 6
        local yOffset     = -4

        for _, catKey in ipairs(categoryOrder) do
            local catFrame = self.consumablesChecker.categoryFrames[catKey]
            if catFrame and catFrame.items then
                local catName = ((catFrame._categoryName or catKey) or ""):lower()
                local categoryWholeMatch = hasQuery and catName:find(q, 1, true) ~= nil

                local visibleRows = {}
                for _, itemFrame in ipairs(catFrame.items) do
                    local data = itemFrame.itemData
                    local name = ((data and data.name) or ""):lower()
                    local match = not hasQuery or categoryWholeMatch
                                  or name:find(q, 1, true) ~= nil

                    if hasQuery and not match and data and data.aliases then
                        for _, alias in ipairs(data.aliases) do
                            if tostring(alias):lower():find(q, 1, true) then
                                match = true; break
                            end
                        end
                    end

                    if match then
                        table.insert(visibleRows, itemFrame)
                    else
                        itemFrame:Hide()
                    end
                end

                if #visibleRows == 0 and hasQuery then
                    catFrame:Hide()
                else
                    catFrame:Show()
                    catFrame:ClearAllPoints()
                    catFrame:SetPoint("TOPLEFT",  scrollChild, "TOPLEFT",  0, yOffset)
                    catFrame:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, yOffset)

                    local rowY = -(CAT_HEAD_H + 2)
                    for _, itemFrame in ipairs(visibleRows) do
                        itemFrame:Show()
                        itemFrame:ClearAllPoints()
                        itemFrame:SetPoint("TOPLEFT",  catFrame, "TOPLEFT",   8, rowY)
                        itemFrame:SetPoint("TOPRIGHT", catFrame, "TOPRIGHT", -8, rowY)
                        rowY = rowY - ITEM_ROW_H
                    end

                    local consumed = CAT_HEAD_H + 2 + (#visibleRows * ITEM_ROW_H) + CAT_GAP
                    yOffset = yOffset - consumed
                end
            end
        end

        local totalHeight = math.abs(yOffset) + 16
        scrollChild:SetHeight(totalHeight)
        if scrollFrame.scrollBar then
            local viewH = scrollFrame:GetHeight()
            if scrollFrame.scrollBar.SyncRange then
                local maxScroll = math.max(0, totalHeight - viewH)
                if scrollFrame.scrollBar:GetValue() > maxScroll then
                    scrollFrame.scrollBar:SetValue(maxScroll)
                end
                scrollFrame.scrollBar:SyncRange(totalHeight, viewH)
            else
                local maxScroll = math.max(0, totalHeight - viewH)
                scrollFrame.scrollBar:SetMinMaxValues(0, maxScroll)
                if scrollFrame.scrollBar:GetValue() > maxScroll then
                    scrollFrame.scrollBar:SetValue(maxScroll)
                end
            end
        end
    end

    -- Shared shell for the checker's small popups (target dummies,
    -- recommended amount, materials search, add custom item): flat
    -- ui.windowBackground at 0.97 with a 1px black ring, a 30px flat
    -- ui.headerBackground title bar carrying the addon mark, a 15px gold
    -- title and a chromeless X, a 1px gold rule under the bar, drag by
    -- the bar, ESC closes. popup:Close() fades it out (PopOut) and
    -- popup:Open() fades it in (PopIn) after the caller has anchored it.
    -- Hangs .titleBar/.titleText/.closeBtn/.accentLine on the popup.
    local function BuildPopupShell(name, titleText, width, height)
        local popup = CreateFrame("Frame", name, UIParent)
        popup:SetSize(width or 240, height or 100)
        popup:SetFrameStrata("DIALOG")
        popup:SetToplevel(true)
        popup:EnableMouse(true)
        popup:SetMovable(true)
        popup:SetClampedToScreen(true)
        popup:Hide()

        local winBg = RC:GetColor("ui", "windowBackground")
        popup.bg = popup:CreateTexture(nil, "BACKGROUND")
        popup.bg:SetAllPoints()
        popup.bg:SetTexture(FLAT)
        popup.bg:SetVertexColor(winBg.r, winBg.g, winBg.b, 0.97)
        popup.border = RC.UI:CreateSimpleBorder(popup)

        local titleBar = CreateFrame("Frame", nil, popup)
        titleBar:SetHeight(30)
        titleBar:SetPoint("TOPLEFT", popup, "TOPLEFT", 1, -1)
        titleBar:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -1, -1)
        titleBar:EnableMouse(true)
        titleBar:RegisterForDrag("LeftButton")
        titleBar:SetScript("OnDragStart", function() popup:StartMoving() end)
        titleBar:SetScript("OnDragStop", function() popup:StopMovingOrSizing() end)
        local hdrBg = GetHeaderBg()
        titleBar.bg = titleBar:CreateTexture(nil, "BACKGROUND")
        titleBar.bg:SetAllPoints()
        titleBar.bg:SetTexture(FLAT)
        titleBar.bg:SetVertexColor(hdrBg.r, hdrBg.g, hdrBg.b, hdrBg.a or 1)
        popup.titleBar = titleBar
        popup.headerBar = titleBar

        local accent = titleBar:CreateTexture(nil, "ARTWORK")
        accent:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
        accent:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
        accent:SetHeight(1)
        accent:SetTexture(FLAT)
        local accCol = GetAccentGold()
        accent:SetVertexColor(accCol.r, accCol.g, accCol.b, 0.6)
        popup.accentLine = accent
        if RC.UI.ApplyHeaderArt then
            accent:Hide()
            RC.UI:ApplyHeaderArt(titleBar, { stepX = 160 })
        end

        local titleIcon = RC.UI:AddTitleIcon(titleBar, 16, 8)
        local titleCol = RC:GetColor("ui", "headerText")
        popup.titleText = RC:CreateFontString(titleBar, "OVERLAY", nil, 15)
        popup.titleText:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        popup.titleText:SetPoint("RIGHT", titleBar, "RIGHT", -30, 0)
        popup.titleText:SetJustifyH("LEFT")
        popup.titleText:SetWordWrap(false)
        popup.titleText:SetTextColor(titleCol.r, titleCol.g, titleCol.b, 1)
        popup.titleText:SetText(titleText or "")

        function popup:Close()
            if RC.UI.PopOut then RC.UI:PopOut(self, 0.1) else self:Hide() end
        end
        function popup:Open()
            if RC.UI.PopIn then RC.UI:PopIn(self, 0.12) else self:Show() end
            self:Raise()
        end

        popup.closeBtn = RC.UI:CreateXCloseButton(titleBar, 22, function() popup:Close() end)
        popup.closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -5, 0)
        -- the 5.0 popup look (UIF_Dialogs); its buttons join on each open
        RC.UI:SkinPopup(popup, { header = titleBar, title = popup.titleText, close = popup.closeBtn })

        RC.UI:RegisterEscapeClose(name)
        return popup
    end
    _cck.BuildPopupShell = BuildPopupShell

    local DUMMY_VARIANTS_INFO = {
        { itemId = 16023, name = "Masterwork Target Dummy" },
        { itemId = 4392,  name = "Advanced Target Dummy"   },
        { itemId = 22261, name = "Love Fool"               },
    }

    function RC:ShowDummyVariantsPopup(anchor)
        if not self.dummyVariantsPopup then
            local popup = BuildPopupShell("WRDummyVariantsPopup", RCL["Target Dummies"], 256, 100)
            popup.rows = {}
            self.dummyVariantsPopup = popup
        end

        local popup = self.dummyVariantsPopup

        local PADDING = 8
        local BTN_H   = 24
        local BTN_W   = 240
        local yOff    = -(30 + PADDING)

        for i, info in ipairs(DUMMY_VARIANTS_INFO) do
            local row = popup.rows[i]
            if not row then
                row = RC.UI:CreateStyledButton(popup, "", BTN_W, BTN_H)
                row:RegisterForClicks("LeftButtonUp")

                row.icon = row:CreateTexture(nil, "ARTWORK")
                row.icon:SetSize(18, 18)
                row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
                row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                row.nameText = self:CreateFontString(row, "OVERLAY", nil, 10)
                row.nameText:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
                row.nameText:SetPoint("RIGHT", row, "RIGHT", -60, 0)
                row.nameText:SetJustifyH("LEFT")

                row.countText = self:CreateFontString(row, "OVERLAY", nil, 10)
                row.countText:SetPoint("RIGHT", row, "RIGHT", -8, 0)
                row.countText:SetJustifyH("RIGHT")

                popup.rows[i] = row
            end

            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", popup, "TOPLEFT", PADDING, yOff)

            row.icon:SetTexture(self:GetCachedIcon(info.itemId))
            local count = (GetItemCount and GetItemCount(info.itemId)) or 0
            row.icon:SetDesaturated(count == 0)

            row.nameText:SetText(info.name)
            if count > 0 then
                local normC = RC:GetColor("text", "normal")
                local okC   = RC:GetColor("text", "success")
                row.nameText:SetTextColor(normC.r, normC.g, normC.b, 1)
                row.countText:SetText(tostring(count))
                row.countText:SetTextColor(okC.r, okC.g, okC.b, 1)
            else
                local grayC = RC:GetColor("text", "gray")
                row.nameText:SetTextColor(grayC.r, grayC.g, grayC.b, 1)
                row.countText:SetText("-")
                row.countText:SetTextColor(grayC.r, grayC.g, grayC.b, 1)
            end

            local infoItemId = info.itemId
            local infoName   = info.name
            row:SetScript("OnClick", function()
                popup:Close()
                if RC.OpenAuctionHouseForItem then
                    RC:OpenAuctionHouseForItem(infoItemId, infoName)
                end
            end)
            row:Show()

            yOff = yOff - (BTN_H + 4)
        end

        for i = #DUMMY_VARIANTS_INFO + 1, #popup.rows do
            popup.rows[i]:Hide()
        end

        local totalH = 30 + PADDING + (#DUMMY_VARIANTS_INFO * (BTN_H + 4)) + PADDING
        popup:SetSize(BTN_W + PADDING * 2, totalH)

        popup:ClearAllPoints()
        if anchor then
            popup:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
        else
            popup:SetPoint("CENTER")
        end
        popup:Open()
    end

    function RC:ShowRecommendedEditPopup(itemId, itemData, anchor)
        if not self.recommendedEditPopup then
            local popup = BuildPopupShell("WRRecommendedEditPopup", RCL["Recommended Amount"], 290, 112)

            local normC = RC:GetColor("text", "normal")
            popup.nameText = self:CreateFontString(popup, "OVERLAY", nil, 11)
            popup.nameText:SetPoint("TOPLEFT", popup, "TOPLEFT", 12, -38)
            popup.nameText:SetPoint("RIGHT", popup, "RIGHT", -12, 0)
            popup.nameText:SetJustifyH("LEFT")
            popup.nameText:SetWordWrap(false)
            popup.nameText:SetTextColor(normC.r, normC.g, normC.b, 1)

            local hintC = RC:GetColor("text", "secondary")
            popup.hintText = self:CreateFontString(popup, "OVERLAY", nil, 10)
            popup.hintText:SetPoint("TOPLEFT", popup, "TOPLEFT", 12, -54)
            popup.hintText:SetPoint("RIGHT", popup, "RIGHT", -12, 0)
            popup.hintText:SetJustifyH("LEFT")
            popup.hintText:SetTextColor(hintC.r, hintC.g, hintC.b, 1)

            local box = self.UI:CreateStyledEditBox(popup, {
                width = 60, height = 22, maxLetters = 4, initialText = "",
            })
            box:SetPoint("TOPLEFT", popup, "TOPLEFT", 12, -74)
            popup.amountBox = box
            if box.editBox then box.editBox:SetNumeric(true) end

            local function Commit()
                local eb = popup.amountBox.editBox
                local v = eb and tonumber(eb:GetText() or "") or nil
                RC:SetRecommendedCount(popup.curItemId, v)
                popup:Close()
            end

            -- Primary action wears the active look; the fallback is plain.
            local setBtn = self.UI:CreateStyledButton(popup, RCL["Save Amount"], 96, 22)
            setBtn:SetPoint("LEFT", box, "RIGHT", 8, 0)
            setBtn:SetActive(true)
            setBtn:SetScript("OnClick", Commit)

            local defBtn = self.UI:CreateStyledButton(popup, RCL["Use Default"], 96, 22)
            defBtn:SetPoint("LEFT", setBtn, "RIGHT", 6, 0)
            defBtn:SetScript("OnClick", function()
                RC:SetRecommendedCount(popup.curItemId, nil)
                popup:Close()
            end)

            if box.editBox then
                box.editBox:SetScript("OnEnterPressed", Commit)
                box.editBox:SetScript("OnEscapePressed", function() popup:Close() end)
            end

            self.recommendedEditPopup = popup
        end

        local popup = self.recommendedEditPopup
        popup.curItemId = itemId
        popup.nameText:SetText((itemData and itemData.name) or ("item " .. tostring(itemId)))
        local defRec = (itemData and itemData.recommended) or 0
        popup.hintText:SetText(RCL["Default: "] .. defRec .. RCL[" - 0 or empty goes back to default"])
        local cur = self:GetRecommendedCount(itemId, itemData or {})
        local eb = popup.amountBox.editBox
        if eb then
            eb:SetText(tostring(cur))
            eb:SetFocus()
            eb:HighlightText()
        end
        popup:ClearAllPoints()
        if anchor then
            popup:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
        else
            popup:SetPoint("CENTER")
        end
        popup:Open()
    end

    _cck.GetAccentGold = GetAccentGold
    _cck.GetCardBg = GetCardBg
    _cck.GetHeaderBg = GetHeaderBg
    _cck.MELLI_TEXTURE = MELLI_TEXTURE
end

function RC:RunRaidConsumablesCheck(manual)
    do
        do
            local RC = _G.Readycheck
            if not (RC and RC.db) then return end
            if not manual then
                local raid = RC.GetEffectiveRaidName and RC:GetEffectiveRaidName()
                if not raid then
                    RC._raidConsAlertKey = nil
                    return
                end
                if RC._raidConsAlertKey == raid then return end
                RC._raidConsAlertKey = raid
            end
            local ch = RC.db.consumablesChecker
            if not ch then return end
            if not manual and ch.raidEntryAlert == false then return end
            local disabled = ch.disabledItems or {}
            local prioOnly = ch.raidEntryAlertPrioOnly
            local prio = ch.priorityItems or {}
            local missing = {}
            local scanCategories = { "flasks", "elixirs", "food", "drinks",
                "potions", "protectionPotions", "buffs", "utilities",
                "classItems", "reagents", "chronoboon", "special" }
            for _, catKey in ipairs(scanCategories) do
                local category = RC.raidConsumables and RC.raidConsumables[catKey]
                if category and category.items then
                    for itemId, itemData in pairs(category.items) do
                        if type(itemId) == "number" and not disabled[itemId]
                            and (not prioOnly or prio[itemId]) then
                            local rec = RC.GetRecommendedCount
                                and RC:GetRecommendedCount(itemId, itemData) or 0
                            if rec and rec > 0 then
                                local have = 0
                                if itemData.aggregateItemIds then
                                    for _, aid in ipairs(itemData.aggregateItemIds) do
                                        have = have + (GetItemCount and GetItemCount(aid, false, false) or 0)
                                    end
                                else
                                    -- Weapon-stone rows use virtual ids (e.g.
                                    -- 182621 = Elemental MH); the real item
                                    -- lives in baseItemId. Count exactly like
                                    -- the checker window does.
                                    local countId = itemData.baseItemId or itemId
                                    have = GetItemCount and GetItemCount(countId, false, false) or 0
                                end
                                -- Raid-entry alert reports only items you have
                                -- NONE of - low stock is not "missing".
                                if have <= 0 then
                                    missing[#missing + 1] = {
                                        name = itemData.displayName or itemData.name
                                            or GetItemInfo(itemId) or ("item " .. itemId),
                                        have = have, rec = rec,
                                    }
                                end
                            end
                        end
                    end
                end
            end
            if #missing == 0 then
                if manual then RC:Print(RCL["Consumables check: nothing missing."]) end
                return
            end
            table.sort(missing, function(a, b) return a.name < b.name end)
            local parts = {}
            for i, m in ipairs(missing) do
                if i <= 8 then
                    parts[#parts + 1] = m.name .. " " .. m.have .. "/" .. m.rec
                end
            end
            local line = table.concat(parts, ", ")
            if #missing > 8 then
                line = line .. " +" .. (#missing - 8) .. " more"
            end
            RC:Print(RCL["|cFFFF4444Missing consumables:|r "] .. line)
            if ch.playSound and RC.PlaySoundKey then
                RC:PlaySoundKey(ch.soundKey or "WR: Warning")
            end
            if RC.ShowReminderForced then
                RC:ShowReminderForced("Missing: " .. line, {}, 12)
            end
            if RC.db.ttsEnabled and RC.SpeakTTS then
                RC:SpeakTTS(RCL["Missing consumables"], true)
            end
        end
    end
end

if _G.Readycheck then
    local raf = CreateFrame("Frame")
    raf:RegisterEvent("PLAYER_ENTERING_WORLD")
    raf:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    raf:SetScript("OnEvent", function()
        C_Timer.After(3, function()
            local RC = _G.Readycheck
            if RC and RC.RunRaidConsumablesCheck then
                RC:RunRaidConsumablesCheck(false)
            end
        end)
    end)
end

local _WRm = _G.Readycheck
if _WRm then
    _WRm._buildMarks = _WRm._buildMarks or {}
    _WRm._buildMarks["checker"] = "raid-entry-alert"
end
