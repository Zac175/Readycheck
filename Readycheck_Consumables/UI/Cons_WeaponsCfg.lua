local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_sort = table.insert, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbc = RC._sbc or {}
local _sbc = RC._sbc
local GetTabHoverBg, GetTabNormalBg, GetTabNormalText, GetTabSelectedBg, GetTabSelectedText, TEXT = _sbc.GetTabHoverBg, _sbc.GetTabNormalBg, _sbc.GetTabNormalText, _sbc.GetTabSelectedBg, _sbc.GetTabSelectedText, _sbc.TEXT
------------------------------------------------------------------------
-- Readycheck - Weapons Bar Settings
-- Behavior/Weapons/Look/Text/Animation/Position tabs edit db.weaponsBar
-- (the last four and the preview: Cons_BarStyle.lua).
-- "Show weapon icons" and "Default stone type" write into
-- db.consumablesHelper instead (see below), since the consumables bar's
-- weapon buttons share those two settings with this page.
------------------------------------------------------------------------
    function RC:ShowSidebarWeaponsBarConfig(frame, preserveScroll)
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local CBS = _sbc.BarPages
        -- the bar itself, drawn by its own button code (Cons_BarStyle)
        local P = CBS.DeclarePreview(self, "weaponsBar")
        local parent = frame.scrollChild
        local yPos = -20

        local headerFrame, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Weapons Bar"],
            RCL["Configure the separate weapons bar for sharpening stones"], "Interface\\Icons\\INV_Stone_02")
        yPos = newY

        if not self.db.weaponsBar then
            self.db.weaponsBar = {enabled = false, locked = false, buttonSize = 36, buttonsPerRow = 4, showBackground = true, iconSpacing = 4, visibilityMode = "always", growDirection = "RIGHT"}
        end

        local db = self.db.weaponsBar

        -- old tab keys (search aliases, saved state) land on the tab that has them now
        frame.weaponsBarTab = CBS.Tab(frame.weaponsBarTab, "behavior")

        local _, newTabY = self.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = {
                { key = "behavior", label = RCL["Behavior"] },
                { key = "weapons", label = RCL["Weapons"] },
                { key = "look", label = RCL["Look"] },
                { key = "text", label = RCL["Text"] },
                { key = "animation", label = RCL["Animation"] },
                { key = "position", label = RCL["Position"] },
            },
            selected = frame.weaponsBarTab,
            onClick = function(tk)
                frame.weaponsBarTab = tk
                RC:ShowSidebarWeaponsBarConfig(frame, true)
            end,
            inset = 18,
            fontSize = 10,
            advance = 34,
        })
        yPos = newTabY

        local currentTab = frame.weaponsBarTab or "behavior"
        -- the card holding the on switch (Behavior tab): it stays live
        local liveCard

        if currentTab == "behavior" then
            local generalCard = self:CreateSettingsCard(parent, yPos, RCL["General"])
            liveCard = generalCard
            local cardY = -32

            local enableCheck = self.UI:CreateSettingCheckbox(generalCard, cardY, "Enable Weapons Bar", db.enabled, function(cb)
                local newState = cb:GetChecked()
                RC.db.weaponsBar.enabled = newState
                RC:ForceCheckboxUpdate(cb, newState)
                if newState then
                    if not RC.weaponsBar.frame then
                        RC:CreateWeaponsBarFrame()
                    end
                    if RC.weaponsBar.frame then
                        RC.weaponsBar.stableStateReached = true
                        RC:UpdateWeaponsButtons()
                    end
                end
                -- Show/hide through the visibility evaluator so the bar's
                -- "show in" mode is honoured instead of forcing it on.
                RC:UpdateWeaponsVisibility()
                RC:ForceRebuildWeaponButtons()
                RC:SaveConfigurationToProfile()
                C_Timer.After(0, function() RC:ShowSidebarWeaponsBarConfig(frame, true) end)
            end)
            cardY = cardY - 27

            local combatCheck = self.UI:CreateSettingCheckbox(generalCard, cardY, "Hide in combat", db.hideInCombat, function(cb)
                local newState = cb:GetChecked()
                RC.db.weaponsBar.hideInCombat = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 27
            cardY = cardY - 4
            generalCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - generalCard:GetHeight() - 15

        end

        if currentTab == "look" then
            local displayCard = self:CreateSettingsCard(parent, yPos, RCL["Display"])
            local cardY = -32

            local sizeLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            sizeLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            sizeLabel:SetText(RCL["Button Size:"])
            sizeLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local sizeSlider = self.UI:CreateSettingSlider(displayCard, 24, 64, db.buttonSize or 36, 2, 100, cardY + 5, (db.buttonSize or 36) .. "px", function(slider, value)
                value = math.floor(value / 2) * 2
                RC.db.weaponsBar.buttonSize = value
                slider.Text:SetText(value .. RCL["px"])
                RC:UpdateWeaponsButtons()
            end)
            sizeSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            local perRowLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            perRowLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            perRowLabel:SetText(RCL["Per Row:"])
            perRowLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local perRowSlider = self.UI:CreateSettingSlider(displayCard, 1, 12, db.buttonsPerRow or 4, 1, 100, cardY + 5, db.buttonsPerRow or 4, function(slider, value)
                value = math.floor(value)
                RC.db.weaponsBar.buttonsPerRow = value
                slider.Text:SetText(value)
                RC:UpdateWeaponsButtons()
            end)
            perRowSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            local spacingLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            spacingLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            spacingLabel:SetText(RCL["Spacing:"])
            spacingLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local spacingSlider = self.UI:CreateSettingSlider(displayCard, 0, 12, db.iconSpacing or 4, 1, 100, cardY + 5, db.iconSpacing or 4, function(slider, value)
                value = math.floor(value)
                RC.db.weaponsBar.iconSpacing = value
                slider.Text:SetText(value)
                RC:UpdateWeaponsButtons()
            end)
            spacingSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            if db.showBackground == nil then db.showBackground = true end
            local bgCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show background and borders", db.showBackground, function(cb)
                local newState = cb:GetChecked()
                RC.db.weaponsBar.showBackground = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:UpdateWeaponsBarBackground()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26

            if db.showCount == nil then db.showCount = true end
            local countCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show item count", db.showCount, function(cb)
                local newState = cb:GetChecked()
                RC.db.weaponsBar.showCount = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:UpdateWeaponsButtons()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26

            if db.showItemNames == nil then db.showItemNames = false end
            local nameCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show item names on icons", db.showItemNames, function(cb)
                local newState = cb:GetChecked()
                RC.db.weaponsBar.showItemNames = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:UpdateWeaponsBarNameLabels()
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 35

            local ttCheck = self.UI:CreateSettingCheckbox(displayCard, cardY, "Show item tooltips on hover", db.showTooltips == true, function(cb)
                local newState = cb:GetChecked()
                RC.db.weaponsBar.showTooltips = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 35

            local alertLabel = self:CreateFontString(displayCard, "OVERLAY", nil, 11)
            alertLabel:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            alertLabel:SetText(RCL["Alert Below:"])
            alertLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local alertValue = db.showBeforeExpiry or 60
            local alertSlider = self.UI:CreateSettingSlider(displayCard, 0, 300, alertValue, 10, 100, cardY + 5, alertValue .. "s", function(slider, value)
                value = math.floor(value / 10) * 10
                RC.db.weaponsBar.showBeforeExpiry = value
                slider.Text:SetText(value .. "s")
            end)
            alertSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 35

            local alertHint = self:CreateFontString(displayCard, "OVERLAY", nil, 10)
            alertHint:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            alertHint:SetText(RCL["Big centered timer appears when time drops below this value"])
            alertHint:SetWidth(displayCard:GetWidth() - 30)
            alertHint:SetJustifyH("LEFT")
            alertHint:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 20

            local wttsCheck = self.UI:CreateCheckbox(displayCard,
                RCL["Speak name when expiring (TTS)"],
                db.ttsEnabled)
            wttsCheck:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 14, cardY)
            wttsCheck:SetScript("OnClick", function()
                RC.db.weaponsBar.ttsEnabled = wttsCheck:GetChecked()
                self:ForceCheckboxUpdate(wttsCheck, RC.db.weaponsBar.ttsEnabled)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 22
            local wttsHint = self:CreateFontString(displayCard, "OVERLAY", nil, 10)
            wttsHint:SetPoint("TOPLEFT", displayCard, "TOPLEFT", 35, cardY)
            wttsHint:SetText(RCL["Volume set in Reminder Settings > Sound"])
            wttsHint:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 18

            self.UI:CreateSegmentedControl(displayCard, {
                x = 14, y = cardY + 5, height = 22, label = RCL["Grow Direction:"],
                items = {
                    { key = "RIGHT", label = RCL["Right"], tooltip = RCL["New rows are added to the right of the anchor."] },
                    { key = "DOWN",  label = RCL["Down"],  tooltip = RCL["New rows are added below the anchor."] },
                },
                selected = db.growDirection or "RIGHT",
                onSelect = function(key)
                    RC.db.weaponsBar.growDirection = key
                    RC:UpdateWeaponsButtons()
                    RC:SaveConfigurationToProfile()
                end,
            })
            cardY = cardY - 40

            displayCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - displayCard:GetHeight() - 15

            yPos = CBS.BuildLook(self, frame, "weaponsBar", parent, yPos)

        end

        if currentTab == "weapons" then
            local shownCard = self:CreateSettingsCard(parent, yPos, RCL["Weapons shown"])
            local cardY = -32

            local shownInfo = self:CreateFontString(shownCard, "OVERLAY", nil, 10)
            shownInfo:SetPoint("TOPLEFT", shownCard, "TOPLEFT", 14, cardY)
            shownInfo:SetWidth(shownCard:GetWidth() - 30)
            shownInfo:SetText(RCL["Choose which of your weapons appear on the weapons bar. This is weapons-bar-only and never touches the consumables bar."])
            shownInfo:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            cardY = cardY - 34

            local hordeCheck = self.UI:CreateSettingCheckbox(shownCard, cardY, "Horde mode: hide the main-hand weapon button", RC:IsHordeMode("weaponsBar"), function(cb)
                local newState = cb:GetChecked()
                RC:SetHordeMode("weaponsBar", newState)
                RC:ForceCheckboxUpdate(cb, newState)
                RC:ForceRebuildWeaponButtons()
                RC:SaveConfigurationToProfile()
            end)

            hordeCheck:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local gold, norm, gray = RC:GetColor("text", "gold"), RC:GetColor("text", "normal"), RC:GetColor("text", "gray")
                GameTooltip:SetText(RCL["Horde Mode"], gold.r, gold.g, gold.b)
                GameTooltip:AddLine(RCL["Hides the main-hand weapon button on this bar, so stones and oils only go on the off-hand. The consumables bar has its own switch."], norm.r, norm.g, norm.b, true)
                GameTooltip:AddLine(RCL["Remembered for this character's faction only: on for Horde and off for Alliance until you change it."], norm.r, norm.g, norm.b, true)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(RCL["Horde warriors use Windfury Totem on their main-hand,"], gray.r, gray.g, gray.b, true)
                GameTooltip:AddLine(RCL["so only the off-hand needs a sharpening stone."], gray.r, gray.g, gray.b, true)
                GameTooltip:Show()
            end)
            hordeCheck:SetScript("OnLeave", function() GameTooltip:Hide() end)
            cardY = cardY - 30


            if self.db.weaponsBar.showEquippedWeapons == nil then
                self.db.weaponsBar.showEquippedWeapons = true
            end
            local equippedWeaponCheck = self.UI:CreateSettingCheckbox(shownCard, cardY, "Show equipped weapons (main hand / off hand)", self.db.weaponsBar.showEquippedWeapons, function(cb)
                local newState = cb:GetChecked()
                RC.db.weaponsBar.showEquippedWeapons = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:RefreshWeaponButtons()
                RC:SaveConfigurationToProfile()
                if RC.ShowSidebarWeaponsBarConfig then RC:ShowSidebarWeaponsBarConfig(frame, true) end
            end)
            cardY = cardY - 26
            -- (2026-11-09) not offered on TBC
            if RC.Flavor and RC:Flavor() == "tbc" then hordeCheck:Hide() cardY = cardY + 26 end

            if self.db.weaponsBar.showBagWeapons == nil then
                self.db.weaponsBar.showBagWeapons = true
            end
            local bagWeaponCheck = self.UI:CreateSettingCheckbox(shownCard, cardY, "Show bag weapons (apply stones to weapons in bags)", self.db.weaponsBar.showBagWeapons, function(cb)
                local newState = cb:GetChecked()
                RC.db.weaponsBar.showBagWeapons = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:RefreshWeaponButtons()
                RC:SaveConfigurationToProfile()
                if RC.ShowSidebarWeaponsBarConfig then RC:ShowSidebarWeaponsBarConfig(frame, true) end
            end)
            cardY = cardY - 27

            if not self.db.weaponsBar.hiddenWeapons then
                self.db.weaponsBar.hiddenWeapons = {}
            end

            local function _wbSharpenable(itemId, allowPolearm)
                if not itemId then return false end
                local nm, _, _, _, _, _, sub, _, eqLoc, _, _, classID = GetItemInfo(itemId)
                if classID ~= 2 or eqLoc == "INVTYPE_SHIELD" then return false, nm end
                local s = sub and sub:lower() or ""
                local ok = s:find("sword") or s:find("axe") or s:find("mace") or s:find("dagger") or s:find("fist") or (allowPolearm and s:find("polearm"))
                return (ok and true or false), nm
            end

            local wbRows = {}
            if self.db.weaponsBar.showEquippedWeapons then
                local mhId = GetInventoryItemID("player", 16)
                local mhOK = _wbSharpenable(mhId, true)
                if mhOK then wbRows[#wbRows + 1] = { id = mhId, tag = "Main Hand", texture = GetItemIcon(mhId) } end
                local ohId = GetInventoryItemID("player", 17)
                local ohOK = _wbSharpenable(ohId, false)
                if ohOK then wbRows[#wbRows + 1] = { id = ohId, tag = "Off Hand", texture = GetItemIcon(ohId) } end
            end
            if self.db.weaponsBar.showBagWeapons then
                local seenW = {}
                for _, weapon in ipairs(self:ScanBagWeapons()) do
                    local iid = weapon.itemId
                    if iid and not seenW[iid] then
                        seenW[iid] = true
                        wbRows[#wbRows + 1] = { id = iid, tag = "Bag", texture = weapon.texture or GetItemIcon(iid) }
                    end
                end
            end

            local listLabel = self:CreateFontString(shownCard, "OVERLAY", nil, 11)
            listLabel:SetPoint("TOPLEFT", shownCard, "TOPLEFT", 14, cardY)
            listLabel:SetText(RCL["Show each weapon (click an icon to toggle):"])
            listLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 26

            if #wbRows == 0 then
                local noneText = self:CreateFontString(shownCard, "OVERLAY", nil, 10)
                noneText:SetPoint("TOPLEFT", shownCard, "TOPLEFT", 14, cardY)
                noneText:SetWidth(shownCard:GetWidth() - 30)
                noneText:SetText(RCL["No sharpenable weapons found in the enabled categories above."])
                noneText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY = cardY - 24
            else
                local iconSize = 38
                local iconGap = 8
                local avail = shownCard:GetWidth() - 30
                local perRow = math.floor((avail + iconGap) / (iconSize + iconGap))
                if perRow < 1 then perRow = 1 end
                for i, w in ipairs(wbRows) do
                    local wid = w.id
                    local col = (i - 1) % perRow
                    local rowN = math.floor((i - 1) / perRow)
                    -- Flat icon tile (Cons_HelperCfg.lua): on = green
                    -- configured fill + green ring, off = desaturated.
                    local btn = _sbc.CreateIconToggleTile(shownCard, iconSize, w.texture or GetItemIcon(wid) or 134400)
                    btn:SetPoint("TOPLEFT", shownCard, "TOPLEFT", 14 + col * (iconSize + iconGap), cardY - rowN * (iconSize + iconGap))

                    local function applyState()
                        btn:SetOn(not RC.db.weaponsBar.hiddenWeapons[wid])
                    end
                    applyState()

                    btn:SetScript("OnClick", function()
                        if RC.db.weaponsBar.hiddenWeapons[wid] then
                            RC.db.weaponsBar.hiddenWeapons[wid] = nil
                        else
                            RC.db.weaponsBar.hiddenWeapons[wid] = true
                        end
                        applyState()
                        RC:RefreshWeaponButtons()
                        RC:SaveConfigurationToProfile()
                    end)
                    btn:HookScript("OnEnter", function(selfBtn)
                        GameTooltip:SetOwner(selfBtn, "ANCHOR_RIGHT")
                        GameTooltip:SetHyperlink("item:" .. tostring(wid))
                        local hidden = RC.db.weaponsBar.hiddenWeapons[wid]
                        local sc = hidden and RC:GetColor("text", "red") or RC:GetColor("text", "success")
                        GameTooltip:AddLine(w.tag .. "  " .. (hidden and RCL["(hidden - click to show)"] or RCL["(shown - click to hide)"]), sc.r, sc.g, sc.b)
                        GameTooltip:Show()
                    end)
                    btn:HookScript("OnLeave", function() GameTooltip:Hide() end)
                end
                local numRows = math.ceil(#wbRows / perRow)
                cardY = cardY - numRows * (iconSize + iconGap)
            end
            cardY = cardY - 6

            shownCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - shownCard:GetHeight() - 15

            -- shared with the consumables bar's page (both bars' weapon buttons)
            yPos = self:BuildWeaponEnhancementCard(parent, yPos)

            local clickCard = self:CreateSettingsCard(parent, yPos, RCL["Weapon button clicks"])
            cardY = -32
            cardY = RC.UI:CreateHelpLine(clickCard, 14, cardY, RCL["Set what each click does on the weapon buttons (equipped main/off hand and bag weapons). Equip uses a secure weapon swap, so it works in combat."], { gap = 12 })

            local clickActionOptions = {
                { text = RCL["Apply Stone"],     value = "stone"   },
                { text = RCL["Stone Picker"],    value = "picker"  },
                { text = RCL["Equip Main Hand"], value = "equipMH" },
                { text = RCL["Equip Off Hand"],  value = "equipOH" },
                { text = RCL["Nothing"],         value = "none"    },
            }
            local function _clickActionLabel(v)
                for _, o in ipairs(clickActionOptions) do if o.value == v then return o.text end end
                return "Nothing"
            end
            local clickSlots = {
                { key = "left",       label = RCL["Left-click"]    },
                { key = "right",      label = RCL["Right-click"]   },
                { key = "shiftLeft",  label = RCL["Shift + Left"]  },
                { key = "shiftRight", label = RCL["Shift + Right"] },
                { key = "ctrlLeft",   label = RCL["Ctrl + Left"]   },
                { key = "ctrlRight",  label = RCL["Ctrl + Right"]  },
            }
            for _, cs in ipairs(clickSlots) do
                local slotKey = cs.key
                local lbl = self:CreateFontString(clickCard, "OVERLAY", nil, 11)
                lbl:SetPoint("TOPLEFT", clickCard, "TOPLEFT", 14, cardY)
                lbl:SetText(cs.label)
                lbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

                local curVal = RC:GetWeaponClickAction(slotKey)
                local dd = self.UI:CreateScrollableDropdown(clickCard, 150, _clickActionLabel(curVal), 10)
                dd:SetPoint("TOPLEFT", clickCard, "TOPLEFT", 140, cardY + 5)
                dd:SetItems(clickActionOptions, function(value)
                    if not RC.db.weaponsBar then RC.db.weaponsBar = {} end
                    if not RC.db.weaponsBar.clickActions then RC.db.weaponsBar.clickActions = {} end
                    RC.db.weaponsBar.clickActions[slotKey] = value
                    RC:RefreshWeaponButtons()
                    RC:SaveConfigurationToProfile()
                end)
                cardY = cardY - 27
            end
            clickCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - clickCard:GetHeight() - 15

        end

        if currentTab == "behavior" then
            local visCard = self:CreateSettingsCard(parent, yPos, RCL["Visibility"])
            local cardY = -32

            local visLabel = self:CreateFontString(visCard, "OVERLAY", nil, 11)
            visLabel:SetPoint("TOPLEFT", visCard, "TOPLEFT", 14, cardY)
            visLabel:SetText(RCL["Show the weapons bar:"])
            visLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            -- Keys are the saved values; labels/tooltips come from
            -- BuildVisibilityModeGrid ("group" = any party/raid anywhere,
            -- "raids_only" = inside a raid instance, "city" = resting in
            -- an inn or capital). The raid modes get a per-raid filter
            -- block underneath, so onPick re-renders to resize.
            local modes = {
                {key = "always", name = "Always"},
                {key = "group", name = "In a Group"},
                {key = "city", name = "In Cities"},
                {key = "raids_only", name = "In Raids"},
                {key = "raids_and_city", name = "Raids & Cities"}
            }

            cardY = _sbc.BuildVisibilityModeGrid(visCard, cardY, modes, RC.db.weaponsBar, function()
                RC.weaponsBar.cachedShouldShow = nil
                RC.weaponsBar.lastZoneCheck = 0
                RC:UpdateWeaponsVisibility()
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarWeaponsBarConfig(frame, true)
            end)

            visCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - visCard:GetHeight() - 15
            -- fade rules on top of "Show in" (the customization standard)
            yPos = self.UI:FrameVisibilityCard(parent, yPos, function() return RC.db.weaponsBar end,
                function() RC:RestyleBar("weaponsBar") end, { fields = { show = true, alpha = true, combatAlpha = true, fadeIn = true, fadeOut = true },
                note = RCL["On top of 'Show in' and the mouseover fade: a rule that is not met fades the bar out."] })
        end

        if currentTab == "text" then yPos = CBS.BuildText(self, frame, "weaponsBar", parent, yPos) end
        if currentTab == "animation" then yPos = CBS.BuildAnimation(self, frame, "weaponsBar", parent, yPos, P) end
        if currentTab == "position" then yPos = CBS.BuildPosition(self, frame, "weaponsBar", parent, yPos) end

        if not db.enabled then
            self:LockSettingsCards(parent, RCL["The weapons bar is off. Turn it on to change these."], liveCard, 58)
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
        if preserveScroll then
            self:RestoreScrollPosition(self.sidebarConfigFrame)
        end
    end

------------------------------------------------------------------------
-- The "Weapon Enhancement" card: weapon icons and the default stone.
-- Both settings live in db.consumablesHelper and drive the weapon
-- buttons of BOTH bars, so the weapons bar page and the consumables bar
-- page each show this same card (and a page locked because its own bar
-- is off never hides it from the other).
------------------------------------------------------------------------
function RC:BuildWeaponEnhancementCard(parent, yPos)
    local cardY
        local weaponCard = self:CreateSettingsCard(parent, yPos, RCL["Weapon enhancement"])
        cardY = -32

        local weaponInfo = self:CreateFontString(weaponCard, "OVERLAY", nil, 10)
        weaponInfo:SetPoint("TOPLEFT", weaponCard, "TOPLEFT", 14, cardY)
        weaponInfo:SetWidth(weaponCard:GetWidth() - 30)
        weaponInfo:SetText(RCL["Show your actual weapon icons and apply stones to bag weapons."])
        weaponInfo:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
        cardY = cardY - 25

        -- Lives in consumablesHelper, not weaponsBar: shared with the
        -- consumables bar's own weapon buttons.
        if self.db.consumablesHelper.showWeaponIcons == nil then
            self.db.consumablesHelper.showWeaponIcons = true
        end
        local weaponIconCheck = self.UI:CreateSettingCheckbox(weaponCard, cardY, "Show weapon icons (instead of stone icons)", self.db.consumablesHelper.showWeaponIcons, function(cb)
            local newState = cb:GetChecked()
            RC.db.consumablesHelper.showWeaponIcons = newState
            RC:ForceCheckboxUpdate(cb, newState)
            RC:ForceRebuildWeaponButtons()
            RC:SaveConfigurationToProfile()
        end)
        cardY = cardY - 27

        local stoneLabel = self:CreateFontString(weaponCard, "OVERLAY", nil, 11)
        stoneLabel:SetPoint("TOPLEFT", weaponCard, "TOPLEFT", 14, cardY)
        stoneLabel:SetText(RCL["Default stone type:"])
        stoneLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

        local stoneHint = self:CreateFontString(weaponCard, "OVERLAY", nil, 10)
        stoneHint:SetPoint("TOPLEFT", stoneLabel, "TOPRIGHT", 5, 0)
        stoneHint:SetText(RCL["(Right-click weapon buttons to change)"])
        stoneHint:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
        cardY = cardY - 22

        local stoneTypes = {}
        do
            -- poisons only for a rogue (the only class that carries them)
            local _, myCls = UnitClass("player")
            local isRogue = (myCls == "ROGUE")
            local seen, stones, oils, poisons = {}, {}, {}, {}
            for _, info in pairs(RC.temporaryWeaponEnchants or {}) do
                if type(info) == "table" and info.itemId and not seen[info.itemId] and not info.isFishing
                    and (isRogue or not info.isPoison) then
                    seen[info.itemId] = true
                    if info.isPoison then
                        poisons[#poisons + 1] = { id = info.itemId, name = info.name }
                    elseif info.isOil then
                        oils[#oils + 1] = { id = info.itemId, name = info.name }
                    else
                        stones[#stones + 1] = { id = info.itemId, name = info.name }
                    end
                end
            end
            local byName = function(a, b) return (a.name or "") < (b.name or "") end
            table.sort(stones, byName)
            table.sort(oils, byName)
            table.sort(poisons, byName)
            for _, e in ipairs(poisons) do stoneTypes[#stoneTypes + 1] = e end
            for _, e in ipairs(stones) do stoneTypes[#stoneTypes + 1] = e end
            for _, e in ipairs(oils) do stoneTypes[#stoneTypes + 1] = e end
        end

        local selectedStone = self.db.consumablesHelper.selectedStoneType or 18262
        local selectedName = "Select stone or oil..."
        local stoneItems = {}
        for _, stone in ipairs(stoneTypes) do
            stoneItems[#stoneItems + 1] = { text = stone.name, value = stone.id }
            if stone.id == selectedStone then selectedName = stone.name end
        end

        local stoneDD = self.UI:CreateScrollableDropdown(weaponCard, 220, selectedName, 10)
        stoneDD:SetPoint("TOPLEFT", weaponCard, "TOPLEFT", 14, cardY + 2)
        stoneDD:SetEmptyText(RCL["No stones or oils known"], RCL["Weapon enhancement data has not loaded yet - try again after a reload."])
        stoneDD:SetItems(stoneItems, function(value)
            RC.db.consumablesHelper.selectedStoneType = value
            RC:ForceRebuildWeaponButtons()
            RC:SaveConfigurationToProfile()
        end)
        stoneDD:SetSelectedValue(selectedStone, selectedName)
        cardY = cardY - 34

        weaponCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - weaponCard:GetHeight() - 15
    return yPos
end
