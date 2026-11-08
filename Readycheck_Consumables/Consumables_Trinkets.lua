------------------------------------------------------------------------
-- Readycheck - Trinket Bar
-- Owns the movable trinket bar frame, scanning equipped (slots 13/14)
-- and bag trinkets, and per-button cooldown/buff display. "On use"
-- status (IsTrinketOnUse, defined in TrinketScanner.lua) merges the
-- hardcoded RC.onUseTrinkets table with TrinketScanner's learned data.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local WRF = _G.Readycheck
if not WRF then return end
WRF._chInit = WRF._chInit or {}
WRF._chs = WRF._chs or {}
WRF._chInit[#WRF._chInit + 1] = function()
    local RC = _G.Readycheck
    local GetTime = GetTime
    local InCombatLockdown = InCombatLockdown
    local math_floor = math.floor
    local pairs = pairs
    local ipairs = ipairs

    local _chs = WRF._chs
    local C, SmoothSetSize = _chs.C, _chs.SmoothSetSize
    local function GetTrinketBarBg()
        return RC:GetColor("weaponBar", "frameBackground") or {r = 0.05, g = 0.05, b = 0.05, a = 0.90}
    end
    local function GetTrinketBarBorder()
        return RC:GetColor("weaponBar", "frameBorder") or {r = 0.3, g = 0.3, b = 0.3, a = 1}
    end
    local function GetTrinketBarTitle()
        return RC:GetColor("weaponBar", "titleText") or {r = 0.8, g = 0.6, b = 0.2, a = 1}
    end

    function RC:ShouldShowTrinketBar()
        return _chs.EvalBarVisibility(self.trinketBar, self.db and self.db.trinketBar, _chs.RaidsCityMode)
    end

    function RC:UpdateTrinketBarVisibility()
        if not self.trinketBar.frame then return end

        if not self.db.trinketBar.enabled then
            if not InCombatLockdown() then
                self:HideBarFrame("trinketBar")
            end
            return
        end

        self.trinketBar.cachedShouldShow = nil
        self.trinketBar.lastZoneCheck = 0

        if InCombatLockdown() then return end

        if self:ShouldShowTrinketBar() then
            self:ShowBarFrame("trinketBar")
            self:UpdateTrinketBarButtons()
        else
            self:HideBarFrame("trinketBar")
        end
    end

    function RC:CreateTrinketBarFrame()
        if not self.db.trinketBar then return nil end
        if self.trinketBar.frame then return self.trinketBar.frame end

        local db = self.db.trinketBar

        local frame = CreateFrame("Frame", "ReadycheckTrinketBar", UIParent)
        frame:SetSize(200, 50)
        RC.Position.Bind(frame, function() return self.db.trinketBar end, {
            point = "TOPRIGHT", pointKey = "anchorPoint",
            default = { point = "TOPRIGHT", x = -10, y = -400 },
        })
        RC.Position.ApplyStored(frame) -- real layout restores at true size
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:SetClampedToScreen(true)
        frame:RegisterForDrag("LeftButton")

        frame.bg = frame:CreateTexture(nil, "BACKGROUND")
        frame.bg:SetAllPoints()
        local shouldShowBg = db.showBackground ~= false
        local frameBgCol = GetTrinketBarBg()
        if shouldShowBg then
            frame.bg:SetColorTexture(frameBgCol.r, frameBgCol.g, frameBgCol.b, frameBgCol.a or 0.90)
        else
            frame.bg:SetColorTexture(C.transparent[1], C.transparent[2], C.transparent[3], C.transparent[4])
        end

        local borderCol = GetTrinketBarBorder()
        self:ApplyBarChrome(frame, borderCol, shouldShowBg)
        local titleCol = GetTrinketBarTitle()
        frame.titleText = self:CreateFontString(frame, "OVERLAY", nil, 10)
        frame.titleText:SetPoint("BOTTOM", frame, "TOP", 0, 20)
        frame.titleText:SetText(RCL["Trinkets  (drag to move)"])
        frame.titleText:SetTextColor(titleCol.r, titleCol.g, titleCol.b, 1)
        if db.locked then
            frame.titleText:Hide()
        end

        frame.unlockHint = self:CreateFontString(frame, "OVERLAY", nil, 10)
        frame.unlockHint:SetPoint("BOTTOM", frame, "TOP", 0, 8)
        frame.unlockHint:SetText(RCL["Right-click to lock"])
        frame.unlockHint:SetTextColor(C.whiteDim[1], C.whiteDim[2], C.whiteDim[3], C.whiteDim[4])
        frame.unlockHint:Hide()

        frame:SetScript("OnEnter", function()
            local currentDb = self.db.trinketBar
            if not currentDb.locked then
                frame.unlockHint:SetText(RCL["Right-click to lock"])
            else
                frame.unlockHint:SetText(RCL["Right-click to unlock"])
            end
            frame.unlockHint:Show()
        end)

        frame:SetScript("OnLeave", function()
            frame.unlockHint:Hide()
        end)

        RC.Position.MakeMovable(frame, function() return not self.db.trinketBar.locked end)

        frame:SetScript("OnMouseUp", function(f, button)
            if button == "RightButton" and not InCombatLockdown() then
                self:ToggleTrinketBarLock()
            end
        end)

        -- Shared bar events (Consumables_Events). No settle hold: a
        -- rescan after a loading screen is cheap and wanted.
        local function Rescan()
            if not InCombatLockdown() then
                self.trinketBar.lastScanTime = 0
                self:UpdateTrinketBarButtons()
            end
        end
        RC:RegisterBarEvents("trinketBar", {
            visibility = "UpdateTrinketBarVisibility",
            combatEnd = function()
                self:ProcessPendingTrinketBarEquips()
                self:UpdateTrinketBarVisibility()
            end,
            bags = Rescan,
            -- A trinket slot changing is the answer to a swap, however it
            -- was asked for (this bar, a gear button, a macro, the
            -- auto-swap): a quick refresh of its own, at most one pending.
            -- (A swap between the two slots changes no bag, so the bag
            -- news alone would miss it.)
            equip = function(slotId)
                if (slotId == 13 or slotId == 14) and not self.trinketBar.pendingFastUpdate then
                    self.trinketBar.pendingFastUpdate = true
                    C_Timer.After(0.1, function()
                        self.trinketBar.pendingFastUpdate = false
                        Rescan()
                    end)
                end
            end,
        })

        self.trinketBar.frame = frame

        -- UpdateTrinketBarVisibility decides shown/hidden from the zone
        -- mode and builds the buttons when shown. The old unconditional
        -- Show() after the rebuild re-surfaced a bar the mode had hidden.
        if db.enabled then
            self.trinketBar.stableStateReached = true
            self:UpdateTrinketBarVisibility()
        else
            frame:Hide()
        end

        -- the customization standard's layer / fade / shadow (unset = as always)
        if self.ApplyFrameCustom then self:ApplyFrameCustom(frame, function() return RC.db and RC.db.trinketBar end, { scale = false }) end

        return frame
    end

    function RC:ToggleTrinketBarLock()
        if InCombatLockdown() then return end

        local db = self.db.trinketBar
        db.locked = not db.locked

        if self.trinketBar.frame then
            if db.locked then
                self.trinketBar.frame.titleText:Hide()
            else
                self.trinketBar.frame.titleText:Show()
            end
        end

        self:UpdateTrinketBarBackground()
        self:UpdateTrinketBarButtons()
        self:SaveConfigurationToProfile()
    end

    function RC:UpdateTrinketBarBackground()
        if not self.trinketBar.frame then return end

        local db = self.db.trinketBar
        local shouldShowBg = db.showBackground ~= false
        local frame = self.trinketBar.frame
        self:PaintBarChrome(frame, "weaponBar", shouldShowBg, db.locked == false)
    end

    -- PREDICTED SWAP. Clicking a bag trinket used to change nothing on the
    -- bar until a fixed 0.3s timer (or the 0.5s bag debounce) rescanned,
    -- so every swap looked like it lagged. The click now rewrites the
    -- cached scan to what the swap will produce and lays the bar out from
    -- that at once. While trinketBar.predicted is set, ScanTrinketsForBar
    -- keeps handing that cache back - a rescan before the server answered
    -- would put the old layout back for a moment - until the slot holds
    -- the new trinket AND the old one has landed in the bag slot it was
    -- traded for, or PREDICT_HOLD passes (the swap was refused) and the
    -- real state is read again.
    local PREDICT_HOLD = 0.75

    function RC:PredictTrinketBarEquip(td, targetSlot, bag, bagSlot, oldItemId)
        local db = self.db.trinketBar
        local cache = self.trinketBar.trinketCache
        -- the two filtered modes add and drop buttons on a swap; let the
        -- real rescan handle those
        if not cache or not td or db.showBagOnly or db.showEquippedOnly then return end

        for _, t in ipairs(cache) do
            if t ~= td and t.equipped and t.slotIndex == targetSlot then
                t.equipped, t.slotIndex, t.bag, t.slot = false, nil, bag, bagSlot
                break
            end
        end
        td.equipped, td.slotIndex, td.bag, td.slot = true, targetSlot, nil, nil

        self.trinketBar.predicted = {
            slot = targetSlot, itemId = td.itemId, oldItemId = oldItemId,
            bag = bag, bagSlot = bagSlot, expires = GetTime() + PREDICT_HOLD,
        }
        self.trinketBar.lastScanTime = GetTime()
        self:UpdateTrinketBarButtons()
    end

    -- A trinket swap asked for from the gear buttons or their flyouts is
    -- shown on the bar at once too, the same as the bar's own clicks.
    -- From the bags: bag, bagSlot. From the other trinket slot: fromSlot.
    function RC:PredictTrinketBarMove(targetSlot, bag, bagSlot, fromSlot)
        if targetSlot ~= 13 and targetSlot ~= 14 then return end
        local db = self.db.trinketBar
        local cache = self.trinketBar and self.trinketBar.trinketCache
        if not db or not db.enabled or not cache or db.showBagOnly or db.showEquippedOnly then return end
        if InCombatLockdown() then return end

        local moving, current
        for _, t in ipairs(cache) do
            if t.equipped and t.slotIndex == targetSlot then
                current = t
            elseif bag and not t.equipped and t.bag == bag and t.slot == bagSlot then
                moving = t
            elseif fromSlot and t.equipped and t.slotIndex == fromSlot then
                moving = t
            end
        end
        if not moving then return end

        if bag then
            self:PredictTrinketBarEquip(moving, targetSlot, bag, bagSlot, current and current.itemId)
        else
            moving.slotIndex = targetSlot
            if current then current.slotIndex = fromSlot end
            self.trinketBar.predicted = {
                slot = targetSlot, itemId = moving.itemId,
                otherSlot = fromSlot, oldItemId = current and current.itemId,
                expires = GetTime() + PREDICT_HOLD,
            }
            self.trinketBar.lastScanTime = GetTime()
            self:UpdateTrinketBarButtons()
        end

        -- a swap the server turned down sends no event: the real state
        -- is read again once the prediction runs out
        C_Timer.After(PREDICT_HOLD + 0.05, function()
            if InCombatLockdown() then return end
            RC.trinketBar.lastScanTime = 0
            RC:UpdateTrinketBarButtons()
        end)
    end

    -- Queue badges for picks that are no longer waiting (another pick
    -- replaced them) come off.
    function RC:RefreshTrinketBarQueueBadges()
        local pd = self.pendingDeathTrinketSwap
        local q1 = pd and pd.src == "bar" and pd.slot1
        local q2 = pd and pd.src == "bar" and pd.slot2
        for _, b in pairs(self.trinketBar and self.trinketBar.buttons or {}) do
            local td = b.trinketData
            if b.queueBadge and b.queueBadge:IsShown() and td then
                local waiting
                if td.equipped then
                    waiting = (td.slotIndex == 13 and q1) or (td.slotIndex == 14 and q2)
                else
                    waiting = (q1 == td.itemId) or (q2 == td.itemId)
                end
                if not waiting then b.queueBadge:Hide() end
            end
        end
    end

    function RC:ScanTrinketsForBar()
        local now = GetTime()
        local p = self.trinketBar.predicted
        if p then
            local settled = GetInventoryItemID("player", p.slot) == p.itemId
                and (not p.oldItemId
                     or (p.otherSlot and GetInventoryItemID("player", p.otherSlot) == p.oldItemId)
                     or (p.bag and C_Container.GetContainerItemID(p.bag, p.bagSlot) == p.oldItemId))
            if settled or now >= p.expires or not self.trinketBar.trinketCache then
                self.trinketBar.predicted = nil
            else
                return self.trinketBar.trinketCache
            end
        end
        if self.trinketBar.lastScanTime and (now - self.trinketBar.lastScanTime) < 0.5 then
            return self.trinketBar.trinketCache
        end

        self.trinketBar.lastScanTime = now
        self.trinketBar.trinketCache = {}

        local db = self.db.trinketBar
        local hiddenTrinkets = db.hiddenTrinkets or {}

        -- Classic Era has no GetItemCooldown(itemId): equipped slots read
        -- via GetInventoryItemCooldown, bag slots via
        -- C_Container.GetContainerItemCooldown below.
        if not db.showBagOnly then
        for slotIndex = 13, 14 do
            local itemId = GetInventoryItemID("player", slotIndex)
            if itemId and not hiddenTrinkets[itemId] then
                local name, link, rarity, _, _, _, _, _, _, icon = GetItemInfo(itemId)
                if name then
                    local start, duration, enabled = Readycheck.PlainCD(GetInventoryItemCooldown("player", slotIndex))
                    local cooldownRemaining = 0
                    if start and start > 0 and duration > 1.5 then
                        cooldownRemaining = (start + duration) - now
                        if cooldownRemaining < 0 then cooldownRemaining = 0 end
                    end

                    table.insert(self.trinketBar.trinketCache, {
                        itemId = itemId,
                        name = name,
                        icon = icon,
                        rarity = rarity,
                        equipped = true,
                        slotIndex = slotIndex,
                        cooldownStart = start or 0,
                        cooldownDuration = duration or 0,
                        cooldownRemaining = cooldownRemaining,
                        isOnUse = (self.IsTrinketOnUse and self:IsTrinketOnUse(itemId)) or false
                    })
                end
            end
        end

        end

        if not db.showEquippedOnly then
            local cache = self.trinketBar.trinketCache
            local function AddBagTrinket(bag, slot, itemID)
                local _, _, _, itemEquipLoc = GetItemInfoInstant(itemID)
                if itemEquipLoc == "INVTYPE_TRINKET" and not hiddenTrinkets[itemID] then
                    local name, link, rarity, _, _, _, _, _, _, icon = GetItemInfo(itemID)
                    if name then
                        local start, duration = C_Container.GetContainerItemCooldown(bag, slot)
                        local cooldownRemaining = 0
                        if start and start > 0 and duration > 1.5 then
                            cooldownRemaining = (start + duration) - now
                            if cooldownRemaining < 0 then cooldownRemaining = 0 end
                        end

                        table.insert(cache, {
                            itemId = itemID,
                            name = name,
                            icon = icon,
                            rarity = rarity,
                            equipped = false,
                            bag = bag,
                            slot = slot,
                            cooldownStart = start or 0,
                            cooldownDuration = duration or 0,
                            cooldownRemaining = cooldownRemaining,
                            isOnUse = (self.IsTrinketOnUse and self:IsTrinketOnUse(itemID)) or false
                        })
                    end
                end
            end
            RC.Bags:Each(AddBagTrinket)
        end

        return self.trinketBar.trinketCache
    end

    -- Everything a trinket menu button shows, on any Button: the secure
    -- live buttons and the plain pane samples alike.
    function RC:DressTrinketButton(button, size, trinketData)
        local db = self.db.trinketBar
        button.bg = button:CreateTexture(nil, "BACKGROUND")
        button.bg:SetAllPoints()
        button.bg:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])

        button.icon = button:CreateTexture(nil, "BORDER")
        button.icon:SetPoint("TOPLEFT", 1, -1)
        button.icon:SetPoint("BOTTOMRIGHT", -1, 1)
        button.icon:SetTexture(trinketData.icon)
        button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        button.icon:SetAlpha(1)

        local highlight = button:CreateTexture(nil, "HIGHLIGHT")
        highlight:SetPoint("TOPLEFT", 1, -1)
        highlight:SetPoint("BOTTOMRIGHT", -1, 1)
        highlight:SetColorTexture(1, 1, 1, 0.12)
        highlight:SetBlendMode("ADD")
        button:SetHighlightTexture(highlight)

        local pushed = button:CreateTexture(nil, "ARTWORK")
        pushed:SetPoint("TOPLEFT", 1, -1)
        pushed:SetPoint("BOTTOMRIGHT", -1, 1)
        pushed:SetColorTexture(0, 0, 0, 0.5)
        button:SetPushedTexture(pushed)
        button:SetPushedTextOffset(1, -1)

        button.slotBg = button:CreateTexture(nil, "OVERLAY")
        button.slotBg:SetSize(14, 14)
        button.slotBg:SetPoint("BOTTOMRIGHT", -1, 1)
        button.slotBg:SetColorTexture(0, 0, 0, 0.85)
        button.slotBg:Hide()

        local slotFontSize = math.max(9, math.floor(size * 0.28))
        button.slotText = self:CreateFontString(button, "OVERLAY", nil, slotFontSize)
        button.slotText:SetPoint("CENTER", button.slotBg, "CENTER", 0, 0)
        local slotActiveC = RC:GetColor("text", "buttonActive")
        button.slotText:SetTextColor(slotActiveC.r, slotActiveC.g, slotActiveC.b, 1)
        button.slotText:SetShadowOffset(1, -1)
        button.slotText:SetShadowColor(0, 0, 0, 1)
        button.slotText:Hide()

        if trinketData.equipped and db.showSlotNumbers ~= false then
            local slotNum = trinketData.slotIndex == 13 and "1" or "2"
            button.slotText:SetText(slotNum)
            button.slotBg:Show()
            button.slotText:Show()
        end

        button.cooldownFrame = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        button.cooldownFrame:SetAllPoints(button.icon)
        button.cooldownFrame:SetDrawEdge(false)
        button.cooldownFrame:SetDrawSwipe(true)
        button.cooldownFrame:SetSwipeColor(0, 0, 0, 0.7)
        button.cooldownFrame:SetHideCountdownNumbers(true)
        button.cooldownFrame:SetFrameLevel(button:GetFrameLevel() + 2)

        button.textOverlay = CreateFrame("Frame", nil, button)
        button.textOverlay:SetAllPoints(button)
        button.textOverlay:SetFrameLevel(button:GetFrameLevel() + 5)

        local textScale = (self.db.trinketBar and self.db.trinketBar.cooldownTextScale) or 1.0
        local buffFontSize = math.max(8, math.floor(size * 0.55 * textScale))
        button.buffDurationText = self:CreateFontString(button.textOverlay, "OVERLAY", nil, buffFontSize)
        button.buffDurationText:SetPoint("CENTER", button, "CENTER", 0, 0)
        local buffActiveC = RC:GetColor("text", "buttonActive")
        button.buffDurationText:SetTextColor(buffActiveC.r, buffActiveC.g, buffActiveC.b, 1)
        button.buffDurationText:SetShadowOffset(2, -2)
        button.buffDurationText:SetShadowColor(0, 0, 0, 1)
        button.buffDurationText:SetDrawLayer("OVERLAY", 7)
        button.buffDurationText:Hide()

        local cdFontSize = math.max(8, math.floor(size * 0.55 * textScale))
        button.cooldownText = self:CreateFontString(button.textOverlay, "OVERLAY", nil, cdFontSize)
        button.cooldownText:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.cooldownText:SetTextColor(C.yellow[1], C.yellow[2], C.yellow[3], C.yellow[4])
        button.cooldownText:SetShadowOffset(2, -2)
        button.cooldownText:SetShadowColor(0, 0, 0, 1)
        button.cooldownText:SetDrawLayer("OVERLAY", 7)
        button.cooldownText:Hide()

        local queueBadge = CreateFrame("Frame", nil, button)
        queueBadge:SetSize(16, 16)
        queueBadge:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        queueBadge:SetFrameStrata("HIGH")
        queueBadge:SetFrameLevel(button:GetFrameLevel() + 25)

        local qbg = queueBadge:CreateTexture(nil, "BACKGROUND")
        qbg:SetAllPoints()
        qbg:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
        queueBadge.bg = qbg

        local qicon = queueBadge:CreateTexture(nil, "ARTWORK")
        qicon:SetPoint("CENTER")
        qicon:SetSize(14, 14)
        qicon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        queueBadge.icon = qicon

        local qbTop = queueBadge:CreateTexture(nil, "OVERLAY")
        qbTop:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
        qbTop:SetDrawLayer("OVERLAY", 1)
        qbTop:SetPoint("TOPLEFT", 0, 0)
        qbTop:SetPoint("TOPRIGHT", 0, 0)
        qbTop:SetHeight(1)

        local qbBottom = queueBadge:CreateTexture(nil, "OVERLAY")
        qbBottom:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
        qbBottom:SetDrawLayer("OVERLAY", 1)
        qbBottom:SetPoint("BOTTOMLEFT", 0, 0)
        qbBottom:SetPoint("BOTTOMRIGHT", 0, 0)
        qbBottom:SetHeight(1)

        local qbLeft = queueBadge:CreateTexture(nil, "OVERLAY")
        qbLeft:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
        qbLeft:SetDrawLayer("OVERLAY", 1)
        qbLeft:SetPoint("TOPLEFT", 0, 0)
        qbLeft:SetPoint("BOTTOMLEFT", 0, 0)
        qbLeft:SetWidth(1)

        local qbRight = queueBadge:CreateTexture(nil, "OVERLAY")
        qbRight:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
        qbRight:SetDrawLayer("OVERLAY", 1)
        qbRight:SetPoint("TOPRIGHT", 0, 0)
        qbRight:SetPoint("BOTTOMRIGHT", 0, 0)
        qbRight:SetWidth(1)

        queueBadge:Hide()
        button.queueBadge = queueBadge
        button._rcBarKey = "trinketBar"
        self:StyleBarButton(button, "trinketBar", size)
    end

    function RC:CreateTrinketButton(trinketData, index)
        local db = self.db.trinketBar
        local size = db.buttonSize or 36
        local spacing = db.iconSpacing or 4
        local perRow = db.buttonsPerRow or 4
        local growDir = db.growDirection or "RIGHT"
        local topOffset = -5

        local button = CreateFrame("Button", "WRTrinketBarButton" .. trinketData.itemId,
            self.trinketBar.frame, "SecureActionButtonTemplate")
        button:SetSize(size, size)
        button:RegisterForClicks("LeftButtonDown", "LeftButtonUp", "RightButtonDown", "RightButtonUp")
        button:SetAttribute("ctrl-type1", "qedit")
        button:SetAttribute("ctrl-type2", "qedit")
        button:EnableMouse(true)
        button:SetAlpha(1)

        local row, col
        if growDir == "DOWN" then
            row = math_floor((index - 1) / perRow)
            col = (index - 1) % perRow
        else
            col = math_floor((index - 1) / perRow)
            row = (index - 1) % perRow
        end

        local xPos = 5 + (col * (size + spacing))
        local yPos = topOffset - (row * (size + spacing))
        button:SetPoint("TOPLEFT", self.trinketBar.frame, "TOPLEFT", xPos, yPos)

        self:DressTrinketButton(button, size, trinketData)

        button.itemId = trinketData.itemId
        button.trinketData = trinketData
        if button.trinketData and button.trinketData.equipped and button.trinketData.slotIndex then
            button:SetAttribute("type1", "item")
            button:SetAttribute("type2", "item")
            button:SetAttribute("item1", button.trinketData.slotIndex)
            button:SetAttribute("item2", button.trinketData.slotIndex)
        else
            button:SetAttribute("type1", nil)
            button:SetAttribute("type2", nil)
            button:SetAttribute("item1", nil)
            button:SetAttribute("item2", nil)
        end

        button:SetScript("OnEnter", function(btn)
            if db.showTooltips then
                GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
                if btn.trinketData.equipped then
                    GameTooltip:SetInventoryItem("player", btn.trinketData.slotIndex)
                else
                    GameTooltip:SetBagItem(btn.trinketData.bag, btn.trinketData.slot)
                end
                GameTooltip:AddLine(" ")
                if btn.trinketData.equipped then
                    GameTooltip:AddLine(RCL["Equipped in Slot "] .. (btn.trinketData.slotIndex == 13 and "1" or "2"), 0.2, 0.8, 0.2)
                else
                    GameTooltip:AddLine(RCL["Left-click: Equip to Slot 1"], 0.7, 0.7, 0.7)
                    GameTooltip:AddLine(RCL["Right-click: Equip to Slot 2"], 0.7, 0.7, 0.7)
                end
                GameTooltip:Show()
            end
        end)

        button:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        button:SetScript("PostClick", function(btn, mouseButton, down)
            if down then return end
            if btn.trinketData and btn.trinketData.equipped
               and not IsControlKeyDown() then
                return
            end
            if btn.trinketData.equipped then
                return
            end

            -- A swap involving this trinket is still in flight: a second
            -- click now would act on where it is predicted to be, not on
            -- where it is.
            local flying = RC.trinketBar.predicted
            if flying and GetTime() < flying.expires
               and (flying.itemId == btn.itemId or flying.oldItemId == btn.itemId) then
                return
            end

            -- Determine target slot (middle operand 13 is always truthy, so this
            -- and/or form is safe in Lua 5.1)
            local targetSlot = mouseButton == "LeftButton" and 13 or 14

            if IsControlKeyDown() and RC.db.trinketSwap then
                local ts = RC.db.trinketSwap
                ts.queues = ts.queues or {}
                local qk = ts.currentQueue or "default"
                ts.queues[qk] = ts.queues[qk] or {}
                local key = (targetSlot == 13) and "slot1" or "slot2"
                local list = ts.queues[qk][key] or {}
                for i = #list, 1, -1 do
                    if list[i] == btn.trinketData.itemId then table.remove(list, i) end
                end
                table.insert(list, 1, btn.trinketData.itemId)
                ts.queues[qk][key] = list
                RC:SaveConfigurationToProfile()
                if RC.RefreshPendingTrinketIndicators then RC:RefreshPendingTrinketIndicators() end
                RC:Print((btn.trinketData.name or "Trinket") .. RCL[" is now first in the "]
                    .. qk .. RCL[" queue for slot "] .. ((targetSlot == 13) and "1" or "2") .. ".")
                return
            end

            if InCombatLockdown() then
                RC:QueueTrinketBarEquip(btn.trinketData, targetSlot)
                return
            end

            local pd = RC.pendingDeathTrinketSwap
            if pd and pd.src == "bar" then
                if targetSlot == 13 then pd.slot1 = nil else pd.slot2 = nil end
                if not pd.slot1 and not pd.slot2 then RC.pendingDeathTrinketSwap = nil end
            end
            if btn.queueBadge then btn.queueBadge:Hide() end

            if btn.trinketData.bag and btn.trinketData.slot then
                local td = btn.trinketData
                local fromBag, fromSlot = td.bag, td.slot
                local oldItemId = GetInventoryItemID("player", targetSlot)
                -- read before the move: the bag slot is locked after it
                local inLink = C_Container.GetContainerItemLink(fromBag, fromSlot)

                -- the equip engine moves it (busy and lock checks, clean
                -- cursor); still on the cursor means the client refused it
                local ok, why = RC.Equip:BagToSlot(fromBag, fromSlot, targetSlot,
                    { by = "trinketbar", method = "cursor", wantId = td.itemId })
                local refused = not ok or why == "cursor"

                if not refused then
                    RC:PredictTrinketBarEquip(td, targetSlot, fromBag, fromSlot, oldItemId)
                    -- the gear button for that slot shows it at once too
                    local GM = RC.GearManager
                    if GM and GM.PredictSlotItem then
                        GM:PredictSlotItem(targetSlot, td.itemId, td.icon, inLink)
                    end
                end

                -- Confirmation normally arrives as PLAYER_EQUIPMENT_CHANGED
                -- (the frame's event handler). This is the net under it: a
                -- swap the server turned down sends nothing, and the
                -- prediction has to come off the bar by itself.
                C_Timer.After(PREDICT_HOLD + 0.05, function()
                    if InCombatLockdown() then return end
                    RC.trinketBar.lastScanTime = 0
                    RC:UpdateTrinketBarButtons()
                end)
            end
        end)


        return button
    end

    function RC:QueueTrinketBarEquip(trinketData, targetInvSlot)
        self:SetTrinketIntent(targetInvSlot, "bar")
        if not trinketData or not trinketData.bag or not trinketData.slot then return end
        if not self.trinketBar then return end
        -- replaces any pick (here or on the gear buttons) still waiting
        -- for that slot
        self:DropQueuedPicksForSlot(targetInvSlot)
        local pd = self.pendingDeathTrinketSwap or { boss = "Trinket bar" }
        pd.boss = pd.boss or "Trinket bar"
        pd.src = "bar"
        if targetInvSlot == 13 then pd.slot1 = trinketData.itemId
        else pd.slot2 = trinketData.itemId end
        self.pendingDeathTrinketSwap = pd
        if self.RefreshPendingTrinketIndicators then self:RefreshPendingTrinketIndicators() end

        local destButton
        for _, b in pairs(self.trinketBar.buttons) do
            if b.trinketData and b.trinketData.equipped and b.trinketData.slotIndex == targetInvSlot then
                destButton = b
                break
            end
        end
        if not destButton then
            destButton = self.trinketBar.buttons[trinketData.itemId]
        end
        if destButton and destButton.queueBadge then
            destButton.queueBadge.icon:SetTexture(trinketData.icon)
            destButton.queueBadge:Show()
        end

        local slotNum = (targetInvSlot == 13) and "1" or "2"
        local itemName = trinketData.name or GetItemInfo(trinketData.itemId) or "trinket"
        self:DebugPrint("Queued " .. itemName .. " for slot " .. slotNum .. " - equips when combat ends", "trinket")
    end

    function RC:ProcessPendingTrinketBarEquips()
        if InCombatLockdown() then return end
        C_Timer.After(1.2, function()
            if InCombatLockdown() then return end
            if not RC.pendingDeathTrinketSwap then
                for _, b in pairs(RC.trinketBar.buttons or {}) do
                    if b.queueBadge then b.queueBadge:Hide() end
                end
                if RC.RefreshPendingTrinketIndicators then RC:RefreshPendingTrinketIndicators() end
                RC.trinketBar.lastScanTime = 0
                RC:UpdateTrinketBarButtons()
            end
        end)
    end

    function RC:UpdateTrinketBarButtons()
        if not self.db.trinketBar or not self.db.trinketBar.enabled then return end
        if not self.trinketBar.frame or InCombatLockdown() then return end

        if not self:ShouldShowTrinketBar() then
            self:HideBarFrame("trinketBar")
            return
        end

        local db = self.db.trinketBar
        local size = db.buttonSize or 36
        local spacing = db.iconSpacing or 4
        local perRow = db.buttonsPerRow or 4
        local maxRows = db.maxRows or 5
        local growDir = db.growDirection or "RIGHT"
        local topOffset = -5
        local maxButtons = perRow * maxRows

        local trinkets = self:ScanTrinketsForBar()

        table.sort(trinkets, function(a, b)
            if (a.name or "") ~= (b.name or "") then return (a.name or "") < (b.name or "") end
            return (a.itemId or 0) < (b.itemId or 0)
        end)

        local savedOrder = self.db.trinketBar.trinketOrder
        local hasCustomOrder = savedOrder ~= nil and #savedOrder > 0
        if hasCustomOrder then
            local pos = {}
            for i, id in ipairs(savedOrder) do pos[id] = i end
            local idx = {}
            for i, t in ipairs(trinkets) do idx[t] = i end
            table.sort(trinkets, function(a, b)
                local pa, pb = pos[a.itemId], pos[b.itemId]
                if pa and pb then return pa < pb end
                if pa then return true end
                if pb then return false end
                return idx[a] < idx[b]
            end)
        end

        if self.db.consumablesHelper.trinketBarEquippedFirst == true
           and not hasCustomOrder then
            local equipped, rest = {}, {}
            for _, t in ipairs(trinkets) do
                if t.equipped then
                    equipped[#equipped + 1] = t
                else
                    rest[#rest + 1] = t
                end
            end
            table.sort(equipped, function(a, b)
                return (a.slotIndex or 0) < (b.slotIndex or 0)
            end)
            trinkets = {}
            for _, t in ipairs(equipped) do trinkets[#trinkets + 1] = t end
            for _, t in ipairs(rest)     do trinkets[#trinkets + 1] = t end
        end

        for itemId, button in pairs(self.trinketBar.buttons) do
            button:Hide()
            if button.queueBadge then button.queueBadge:Hide() end
        end

        local visibleCount = 0
        for i, trinketData in ipairs(trinkets) do
            if visibleCount >= maxButtons then break end

            local itemId = trinketData.itemId
            local button = self.trinketBar.buttons[itemId]

            if not button then
                button = self:CreateTrinketButton(trinketData, i)
                self.trinketBar.buttons[itemId] = button
            end

            button.trinketData = trinketData
        -- The two trinkets of a swap still in flight keep the click
        -- actions they had before it: until the server answers, the slot
        -- still holds the old trinket, so the old button must keep using
        -- it and the new button must not use anything (a second click on
        -- it would fire the old trinket). Only the picture is predicted.
        local predicted = self.trinketBar.predicted
        local inFlight = predicted and (predicted.itemId == itemId
            or (predicted.oldItemId ~= nil and predicted.oldItemId == itemId))
        if inFlight then
            -- untouched until the confirmed rescan
        elseif button.trinketData and button.trinketData.equipped and button.trinketData.slotIndex then
            button:SetAttribute("type1", "item")
            button:SetAttribute("type2", "item")
            button:SetAttribute("item1", button.trinketData.slotIndex)
            button:SetAttribute("item2", button.trinketData.slotIndex)
        else
            button:SetAttribute("type1", nil)
            button:SetAttribute("type2", nil)
            button:SetAttribute("item1", nil)
            button:SetAttribute("item2", nil)
        end
            button.itemId = itemId

            if button.cooldownText then
                button.cooldownText:SetText("")
                button.cooldownText:Hide()
            end
            if button.buffDurationText then
                button.buffDurationText:SetText("")
                button.buffDurationText:Hide()
            end

            button:SetSize(size, size)
            -- text follows the size and the menu's style at once
            self:StyleBarButton(button, "trinketBar", size)

            button.icon:SetTexture(trinketData.icon)

            if trinketData.equipped and db.showSlotNumbers ~= false then
                local slotNum = trinketData.slotIndex == 13 and "1" or "2"
                if button.slotText then
                    button.slotText:SetText(slotNum)
                    button.slotBg:Show()
                    button.slotText:Show()
                end
            else
                if button.slotBg then
                    button.slotBg:Hide()
                    button.slotText:Hide()
                end
            end

            local buffRemaining = 0
            -- Two sources for the buff spell id: the hardcoded RC.trinketBuffs
            -- table wins if present, else TrinketScanner's learned data. Both
            -- must key by the same itemId or the cooldown swipe shows but the
            -- buff-remaining overlay never triggers for that trinket.
            local trinketBuffData = RC.trinketBuffs and RC.trinketBuffs[trinketData.itemId]
            local buffSpellId = trinketBuffData and trinketBuffData.buffId
            if not buffSpellId and RC.TrinketScanner and RC.TrinketScanner.autoDetectedTrinkets then
                local scanned = RC.TrinketScanner.autoDetectedTrinkets[trinketData.itemId]
                if scanned then buffSpellId = scanned.buffId or scanned.spellId end
            end
            local aura = buffSpellId and RC.Auras:Buff(buffSpellId)
            if aura and aura.expirationTime > 0 then
                buffRemaining = aura.expirationTime - GetTime()
                if buffRemaining < 0 then buffRemaining = 0 end
            end

            if trinketData.cooldownStart > 0 and trinketData.cooldownDuration > 1.5 then
                button.cooldownFrame:SetCooldown(trinketData.cooldownStart, trinketData.cooldownDuration)
            else
                button.cooldownFrame:Clear()
            end

            if db.showCooldownText and self:ShouldShowOwnCooldownText() then
                if buffRemaining > 0 then
                    if button.buffDurationText then
                        button.buffDurationText:SetText(self:FormatCooldownTime(buffRemaining))
                        button.buffDurationText:Show()
                    end
                    if button.cooldownText then
                        button.cooldownText:SetText("")
                        button.cooldownText:Hide()
                    end
                elseif trinketData.cooldownRemaining > 0 then
                    if button.cooldownText then
                        button.cooldownText:SetText(self:FormatCooldownTime(trinketData.cooldownRemaining))
                        button.cooldownText:Show()
                    end
                    if button.buffDurationText then
                        button.buffDurationText:SetText("")
                        button.buffDurationText:Hide()
                    end
                else
                    if button.cooldownText then
                        button.cooldownText:SetText("")
                        button.cooldownText:Hide()
                    end
                    if button.buffDurationText then
                        button.buffDurationText:SetText("")
                        button.buffDurationText:Hide()
                    end
                end
            else
                if button.cooldownText then
                    button.cooldownText:SetText("")
                    button.cooldownText:Hide()
                end
                if button.buffDurationText then
                    button.buffDurationText:SetText("")
                    button.buffDurationText:Hide()
                end
            end

            visibleCount = visibleCount + 1
            local row, col
            if growDir == "DOWN" then
                row = math_floor((visibleCount - 1) / perRow)
                col = (visibleCount - 1) % perRow
            else
                col = math_floor((visibleCount - 1) / perRow)
                row = (visibleCount - 1) % perRow
            end

            local xPos = 5 + (col * (size + spacing))
            local yPos = topOffset - (row * (size + spacing))

            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", self.trinketBar.frame, "TOPLEFT", xPos, yPos)
            button:Show()
        end

        if visibleCount > 0 then
            local cols, rows
            if growDir == "DOWN" then
                cols = math.min(visibleCount, perRow)
                rows = math.ceil(visibleCount / perRow)
            else
                rows = math.min(visibleCount, perRow)
                cols = math.ceil(visibleCount / perRow)
            end

            local frameWidth = (cols * size) + ((cols - 1) * spacing) + 10
            local frameHeight = (rows * size) + ((rows - 1) * spacing) + (10)

            SmoothSetSize(self.trinketBar.frame,
                math.max(frameWidth, 50), math.max(frameHeight, 50))
        else
            SmoothSetSize(self.trinketBar.frame, 100, 40)
        end
        if not InCombatLockdown() then
            RC.Position.RestoreFrame(self.trinketBar.frame)
        end

        self:ShowBarFrame("trinketBar")

        self:StartCooldownTicker()

        if self.RefreshPendingTrinketIndicators then
            self:RefreshPendingTrinketIndicators()
        end
    end
end
