------------------------------------------------------------------------
-- Readycheck - Consumables Frames and Buttons
-- Builds the consumables and potions bar frames, gives each its part in
-- the shared bar events (Consumables_Events), and constructs every
-- consumable button.
-- Buttons are SecureActionButtonTemplate: their type/item/macrotext
-- attributes, parent, size, position and Show/Hide state may only be
-- changed out of combat. Anything blocked by lockdown is queued on
-- pendingRebuildOnCombatEnd and drained by the combat-end handler here.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local UnitAura = UnitAura or (RCC and RCC.Compat and RCC.Compat.UnitAura)
local WRF = _G.Readycheck
if not WRF then return end
WRF._chInit = WRF._chInit or {}
WRF._chs = WRF._chs or {}
WRF._chInit[#WRF._chInit + 1] = function()
    local RC = _G.Readycheck
    local GetTime = GetTime
    local GetItemCount = GetItemCount or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemCount)
    local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
    local UnitBuff = UnitBuff or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.UnitBuff)
    local GetWeaponEnchantInfo = GetWeaponEnchantInfo
    local IsInInstance = IsInInstance
    local IsInRaid = IsInRaid
    local IsResting = IsResting
    local InCombatLockdown = InCombatLockdown
    local UnitGetTotalAbsorbs = UnitGetTotalAbsorbs
    local UnitGUID = UnitGUID
    local UnitCastingInfo = UnitCastingInfo
    local UnitChannelInfo = UnitChannelInfo
    local GetSpellCooldown = GetSpellCooldown or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetSpellCooldown)
    local math_floor = math.floor
    local math_ceil = math.ceil
    local math_max = math.max
    local math_min = math.min
    local math_abs = math.abs
    local string_format = string.format
    local string_lower = string.lower
    local pairs = pairs
    local ipairs = ipairs
    local type = type

    local _chs = WRF._chs
    local C, GetConsBarBg, GetConsBarBorder, GetConsBarTitle, GetPotBarBg, GetPotBarBorder, GetPotBarTitle = _chs.C, _chs.GetConsBarBg, _chs.GetConsBarBorder, _chs.GetConsBarTitle, _chs.GetPotBarBg, _chs.GetPotBarBorder, _chs.GetPotBarTitle
    local SetBarButtonVisualHidden = _chs.SetBarButtonVisualHidden

    function RC:CreateConsumablesHelperFrame()
        if self.consumablesHelper.frame then
            return self.consumablesHelper.frame
        end

        local db = self.db.consumablesHelper

        local frame = CreateFrame("Frame", "ReadycheckConsumablesHelper", UIParent)
        frame:SetSize(100, 400)
        RC.Position.Bind(frame, function() return self.db.consumablesHelper end, {
            point = "TOPLEFT", pointKey = "anchorPoint",
            default = { point = "TOPRIGHT", x = -10, y = -200 },
        })
        RC.Position.ApplyStored(frame) -- real layout restores at true size
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:SetClampedToScreen(true)
        if not db.locked then
            frame:RegisterForDrag("LeftButton")
        end

        frame.bg = frame:CreateTexture(nil, "BACKGROUND")
        frame.bg:SetAllPoints()
        local shouldShowBg = (db.showBackground)
        local frameBgCol = GetConsBarBg()
        if shouldShowBg then
            frame.bg:SetColorTexture(frameBgCol.r, frameBgCol.g, frameBgCol.b, frameBgCol.a or 0.90)
        else
            frame.bg:SetColorTexture(C.transparent[1], C.transparent[2], C.transparent[3], C.transparent[4])
        end

        local borderCol = GetConsBarBorder()
        frame.border = RC.UI:CreateSimpleBorder(frame)
        RC.UI:UpdateBorderColor(frame.border, borderCol)
        if not shouldShowBg then
            if frame.border.top    then frame.border.top:Hide()    end
            if frame.border.bottom then frame.border.bottom:Hide() end
            if frame.border.left   then frame.border.left:Hide()   end
            if frame.border.right  then frame.border.right:Hide()  end
        end

        self:ApplyBarAccent(frame, "consumablesBar", borderCol, shouldShowBg)

        -- Unlocked-mode chrome: a 30px flat title bar docked above the
        -- bar (so the button layout, size and saved anchor are untouched),
        -- flat ui.headerBackground fill, 1px black ring, one gold rule
        -- along its bottom, 15px title and a chromeless X. It is shown
        -- exactly when the old floating "(drag to move)" caption was:
        -- frame.titleText still exists and Show/Hide on it toggles the
        -- whole bar, so the lock/unlock code keeps working unchanged.
        local FLAT = RC.UI.FLAT or "Interface\\Buttons\\WHITE8X8"
        local titleBar = CreateFrame("Frame", nil, frame)
        -- 20px, not the 30px a settings window gets. This bar can be a
        -- 100px-wide vertical strip, and a full-height header with a
        -- 15px title and a hint line beside it simply ran off the end of
        -- it. The header has to be proportionate to the thing it labels.
        titleBar:SetHeight(20)
        titleBar:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
        titleBar:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, 2)
        titleBar:SetFrameLevel(frame:GetFrameLevel() + 5)
        titleBar:EnableMouse(true)
        frame.titleBar = titleBar
        -- Not part of the bar's edge: the bar may sit flush on the top of
        -- the screen while unlocked; the strip then drops below it.
        titleBar.__rcNoClamp = true

        titleBar.bg = titleBar:CreateTexture(nil, "BACKGROUND")
        titleBar.bg:SetAllPoints()
        titleBar.bg:SetTexture(FLAT)
        local hdrBg = RC:GetColor("ui", "headerBackground")
        titleBar.bg:SetVertexColor(hdrBg.r, hdrBg.g, hdrBg.b, hdrBg.a or 1)
        titleBar.border = RC.UI:CreateSimpleBorder(titleBar)

        local titleRule = titleBar:CreateTexture(nil, "ARTWORK")
        titleRule:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 1, 1)
        titleRule:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", -1, 1)
        titleRule:SetHeight(1)
        titleRule:SetTexture(FLAT)
        local goldC = RC:GetColor("ui", "accentGold")
        titleRule:SetVertexColor(goldC.r, goldC.g, goldC.b, 0.6)

        local titleCol = GetConsBarTitle()
        local titleIcon = RC.UI:AddTitleIcon(titleBar, 12, 5)

        frame.titleText = self:CreateFontString(titleBar, "OVERLAY", nil, 11)
        frame.titleText:SetPoint("LEFT", titleIcon, "RIGHT", 5, 0)
        frame.titleText:SetJustifyH("LEFT")
        frame.titleText:SetWordWrap(false)
        frame.titleText:SetText(RCL["Consumables"])
        frame.titleText:SetTextColor(titleCol.r, titleCol.g, titleCol.b, 1)

        -- The drag/lock hint used to sit on the bar beside the title,
        -- which is what pushed the header off the end of a narrow bar.
        -- It lives in the tooltip now, where length costs nothing.
        titleBar:SetScript("OnEnter", function(tb)
            GameTooltip:SetOwner(tb, "ANCHOR_TOP")
            GameTooltip:SetText(RCL["Consumables"], 1, 1, 1)
            GameTooltip:AddLine(RCL["drag to move  -  right-click to lock"], 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        titleBar:SetScript("OnLeave", function() GameTooltip:Hide() end)

        -- The X locks the bar (same as right-clicking it), which hides
        -- this chrome; the bar itself is never closed from here.
        local lockX = RC.UI:CreateXCloseButton(titleBar, 16, function()
            if InCombatLockdown() then return end
            if not self.db.consumablesHelper.locked then
                self:ToggleConsumablesHelperLock()
            end
        end)
        lockX:SetPoint("RIGHT", titleBar, "RIGHT", -3, 0)
        titleBar.closeBtn = lockX
        frame.titleText:SetPoint("RIGHT", lockX, "LEFT", -4, 0)

        -- On a narrow bar even the short title will not fit beside the
        -- icon and the X, so it steps aside and the icon carries it. The
        -- tooltip still names the bar either way.
        local function FitTitle()
            local w = frame:GetWidth() or 0
            frame.titleText:SetShown(w >= 96)
        end
        FitTitle()
        frame:HookScript("OnSizeChanged", FitTitle)

        -- Dragging the title bar moves the bar through its own drag
        -- scripts (RC.Position.MakeMovable below), so the saved position
        -- is written exactly as a drag on the bar itself would write it.
        titleBar:RegisterForDrag("LeftButton")
        titleBar:SetScript("OnDragStart", function()
            local h = frame:GetScript("OnDragStart")
            if h then h(frame) end
        end)
        titleBar:SetScript("OnDragStop", function()
            local h = frame:GetScript("OnDragStop")
            if h then h(frame) end
        end)
        titleBar:SetScript("OnMouseUp", function(_, button)
            if button == "RightButton" and not InCombatLockdown() then
                self:ToggleConsumablesHelperLock()
            end
        end)

        -- titleText Show/Hide is the existing lock/unlock signal; mirror
        -- it onto the whole title bar.
        hooksecurefunc(frame.titleText, "Show", function() titleBar:Show() end)
        hooksecurefunc(frame.titleText, "Hide", function() titleBar:Hide() end)
        if db.locked then
            frame.titleText:Hide()
        end

        frame.unlockHint = self:CreateFontString(frame, "OVERLAY", nil, 10)
        frame.unlockHint:SetPoint("BOTTOM", frame, "TOP", 0, 8)
        frame.unlockHint:SetText(RCL["Right-click to lock"])
        frame.unlockHint:SetTextColor(C.whiteDim[1], C.whiteDim[2], C.whiteDim[3], C.whiteDim[4])
        frame.unlockHint:Hide()

        frame:SetScript("OnEnter", function()
            local currentDb = self.db.consumablesHelper
            if not currentDb.locked then
                -- The title bar above already carries the drag/lock hint.
                frame.unlockHint:Hide()
            else
                frame.unlockHint:SetText(RCL["Right-click to unlock"])
                frame.unlockHint:Show()
            end
        end)

        frame:SetScript("OnLeave", function()
            frame.unlockHint:Hide()
        end)

        RC.Position.MakeMovable(frame, function() return not self.db.consumablesHelper.locked end)

        -- The title strip goes above the bar, or under it when the bar is
        -- against the top of the screen and there is no room above.
        local function PlaceTitleBar()
            local top = frame:GetTop()
            if not top then return end
            local k = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
            local below = top + 22 > UIParent:GetTop() * k
            if titleBar.__below == below then return end
            titleBar.__below = below
            titleBar:ClearAllPoints()
            if below then
                titleBar:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -2)
                titleBar:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, -2)
            else
                titleBar:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 2)
                titleBar:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, 2)
            end
        end
        frame:HookScript("OnDragStop", function() C_Timer.After(0, PlaceTitleBar) end)
        frame.__rcOnPlaced = PlaceTitleBar   -- mover drops, restores
        titleBar:HookScript("OnShow", PlaceTitleBar)
        frame:HookScript("OnShow", PlaceTitleBar)
        frame:HookScript("OnSizeChanged", PlaceTitleBar)

        frame:SetScript("OnMouseUp", function(f, button)
            if button == "RightButton" and not InCombatLockdown() then
                self:ToggleConsumablesHelperLock()
            end
        end)

        self:StartBarsMaintTicker()

        -- This bar's part in the shared bar events (Consumables_Events):
        -- zone, rest and roster changes re-run UpdateConsumablesVisibility,
        -- and loading screens hold bag-driven rebuilds for 2s
        -- (stableStateReached). The combat hide is shared too, except
        -- that a consumable buff dropping mid-fight keeps the bar up.
        local bar = {
            visibility = "UpdateConsumablesVisibility",
            settle = true,
            keepInCombat = function() return self.consumablesHelper.buffExpiredInCombat end,
            -- Combat over: the one place secure-button work can be done.
            -- Restores spent-in-combat buttons, then drains whichever
            -- rebuild flag was set while locked down.
            combatEnd = function()
                self.consumablesHelper.cachedShouldShow = nil
                self.consumablesHelper.lastZoneCheck = 0
                self.consumablesHelper.buffExpiredInCombat = false

                for _, bar in RC:EachBar() do
                    if bar and bar.buttons then
                        for _, spentButton in pairs(bar.buttons) do
                            -- _iconHiddenByCd is an independent hide reason
                            -- (item still on cooldown); do not un-hide a
                            -- button that is being suppressed for that too.
                            if spentButton._spentInCombat then
                                spentButton._spentInCombat = false
                                if not spentButton._iconHiddenByCd then
                                    SetBarButtonVisualHidden(spentButton, false)
                                    if spentButton.icon then
                                        local sk = spentButton._cachedStateKey
                                        spentButton.icon:SetAlpha((sk == "unavailable" and 0.4) or (sk == "conflictBuff" and 0.7) or 1.0)
                                    end
                                end
                                spentButton._cachedStateKey = nil
                            end
                        end
                    end
                end

                if self.consumablesHelper.pendingRebuildOnCombatEnd or self.consumablesHelper.pendingWeaponRebuildOnCombatEnd then
                    local weaponRebuild = self.consumablesHelper.pendingWeaponRebuildOnCombatEnd
                    self.consumablesHelper.pendingRebuildOnCombatEnd = false
                    self.consumablesHelper.pendingWeaponRebuildOnCombatEnd = false
                    self:DebugPrint("Executing pending rebuild after combat end", "consumables")
                    self.consumablesHelper.lastRebuildTime = 0
                    self.consumablesHelper.rebuildScheduled = false
                    C_Timer.After(0.3, function()
                        if not self then return end
                        if weaponRebuild and self.ForceRebuildWeaponButtons then
                            self:ForceRebuildWeaponButtons()
                        elseif self.UpdateConsumablesButtons then
                            self:UpdateConsumablesButtons()
                        end
                    end)
                else
                    self:UpdateConsumablesVisibility()
                end
            end,
            -- UNIT_AURA arrives through the addon-wide aura dispatcher, which
            -- already holds it to one call per 0.2s however fast auras
            -- change, so the drain runs here directly.
            aura = function()
                local spellSet = RC._consumableSpellIdSet
                local nameSet  = RC._consumableBuffNameSet
                local function IsConsumableBuff(spellId, entry)
                    if spellSet and spellSet[spellId] then return true end
                    local nm = entry and entry.name
                    return nm ~= nil and nameSet ~= nil
                        and nameSet[nm:lower()] == true
                end
                local oldCache = self.consumablesHelper.buffCache
                local consumableChanged = false
                local newCache = self:SnapshotAllBuffs()
                local inCombat = InCombatLockdown()
                local gained    -- consumable buffs new since the last drain, in combat only

                -- Second filter, and the one that saves the work: most
                -- aura churn is procs and other people's buffs. Only an
                -- added, removed or retimed CONSUMABLE buff justifies a
                -- rebuild; the rest updates the cache and stops.
                if spellSet and oldCache then
                    for spellId, entry in pairs(newCache) do
                        if IsConsumableBuff(spellId, entry) and not oldCache[spellId] then
                            consumableChanged = true
                            if not inCombat then break end
                            gained = gained or {}
                            gained[#gained + 1] = spellId
                        end
                    end
                    if not consumableChanged then
                        for spellId, entry in pairs(oldCache) do
                            if IsConsumableBuff(spellId, entry) and not newCache[spellId] then
                                consumableChanged = true; break
                            end
                            local ne = newCache[spellId]
                            if ne and IsConsumableBuff(spellId, entry) then
                                local oe = entry.expirationTime or 0
                                local nx = ne.expirationTime or 0
                                -- 2s tolerance: expiration times jitter
                                -- between scans, and reacting to that
                                -- would rebuild constantly.
                                if math.abs(nx - oe) > 2 then
                                    consumableChanged = true; break
                                end
                            end
                        end
                    end
                else
                    consumableChanged = true
                end

                self.consumablesHelper.buffCache = newCache
                self.consumablesHelper.buffCacheTime = GetTime()
                if consumableChanged then
                    self.performanceCache.conflictGroups = {}
                end

                if not consumableChanged then
                    if RC:IsDebugEnabled("consumables") then
                        local added, n = {}, 0
                        for spellId, e in pairs(newCache) do
                            if not oldCache or not oldCache[spellId] then
                                n = n + 1
                                if n <= 3 then
                                    added[#added + 1] = spellId .. ":" .. tostring(e.name)
                                end
                            end
                        end
                        RC:DebugPrint("UNIT_AURA: no consumable change, skipped rebuild"
                            .. (#added > 0 and (" (new: " .. table.concat(added, ", ") .. ")") or ""),
                            "consumables")
                    end
                    return
                end

                -- Queue-until-combat-ends: a rebuild would move secure
                -- buttons. CheckBuffExpiredInCombat can still un-hide
                -- the non-secure container so an expiry stays visible.
                if inCombat then
                    if gained and self.HideItemsOfBuffsGainedInCombat then
                        self:HideItemsOfBuffsGainedInCombat(gained)
                    end
                    self:CheckBuffExpiredInCombat()
                    self.consumablesHelper.pendingRebuildOnCombatEnd = true
                else
                    self:UpdateConsumablesButtons()
                end
            end,
            -- Slots 13/14 are the trinkets; the trinket bar owns those and
            -- a trinket swap changes nothing about consumables or weapons.
            equip = function(slotId)
                if slotId == 13 or slotId == 14 then return end

                self.bagWeaponEnchantCache = nil
                if (slotId == 16 or slotId == 17) and InCombatLockdown() then
                    self.consumablesHelper.pendingWeaponRebuildOnCombatEnd = true
                end

                -- Cancel-and-restart debounce: equipping a set fires once
                -- per slot. A non-nil weaponUpdateTimer also tells
                -- UpdateButtonStates to skip weapon buttons meanwhile.
                if self.consumablesHelper.weaponUpdateTimer then
                    self.consumablesHelper.weaponUpdateTimer:Cancel()
                end

                self.consumablesHelper.weaponUpdateTimer = C_Timer.NewTimer(0.3, function()
                    self.consumablesHelper.weaponUpdateTimer = nil
                    self.bagWeaponEnchantCache = nil
                    if not InCombatLockdown() then
                        self:RefreshWeaponButtons()
                        self:RefreshWeaponsBarConfigPanel()
                    else
                        self.consumablesHelper.pendingRebuildOnCombatEnd = true
                        -- the rebuild waits for combat; the faces need not
                        for _, b in pairs(self.consumablesHelper.buttons or {}) do
                            self:RefreshUnifiedWeaponIcon(b)
                        end
                    end
                end)
            end,
            -- The bags changed (already debounced; item counts follow the
            -- bag index on their own): the stone and oil buttons depend on
            -- what is carried. An auto trinket swap's own bag shuffle has
            -- nothing to do with consumables and is skipped.
            bags = function()
                if RC.trinketSwapSystem and RC.trinketSwapSystem.lastAutoSwapTime then
                    if (GetTime() - RC.trinketSwapSystem.lastAutoSwapTime) < 1.5 then return end
                end
                self.bagWeaponEnchantCache = nil
                if not self.consumablesHelper.stableStateReached then return end
                -- an equip already rebuilt the weapon buttons for these bags
                if self.consumablesHelper._weaponsBagVersion == RC.Bags:Version() then return end
                if InCombatLockdown() then
                    self.consumablesHelper.pendingRebuildOnCombatEnd = true
                    return
                end
                self:RefreshWeaponButtons()
                self:RefreshWeaponsBarConfigPanel()
            end,
        }

        RC:RegisterBarEvents("consumablesHelper", bar)
        RC:RegisterUnitAuraCallback("ConsumablesHelper", 0.2, bar.aura)

        self.consumablesHelper.frame = frame

        self:UpdateConsumablesHelperBackground()
        self:UpdateConsumablesHelperLock()

        if RC.AttachContainerMouseoverFade then
            RC:AttachContainerMouseoverFade(frame, function()
                local d = RC.db and RC.db.consumablesHelper
                if not d then return nil end
                local fi, fo = RC.BarStyle.FadeTimes("consumablesHelper")
                return { enabled = d.mouseoverFade, alpha = d.mouseoverFadeAlpha or 0.15, fadeIn = fi, fadeOut = fo }
            end)
            if RC.UpdateConsumablesBarMouseoverFade then
                RC:UpdateConsumablesBarMouseoverFade()
            end
        end

        if not InCombatLockdown() then
            if self:ShouldShowConsumablesBar() then
                frame:Show()
            else
                frame:Hide()
            end
        end

        self.consumablesHelper.stableStateReached = true
        self:UpdateConsumablesButtons()

        -- the customization standard's layer / fade / shadow (unset = as always)
        if self.ApplyFrameCustom then self:ApplyFrameCustom(frame, function() return RC.db and RC.db.consumablesHelper end, { scale = false }) end

        return frame
    end

    function RC:CreatePotionsBarFrame()
        if not self.db.potionsBar then return nil end
        if self.potionsBar.frame then return self.potionsBar.frame end

        local db = self.db.potionsBar

        local frame = CreateFrame("Frame", "ReadycheckPotionsBar", UIParent)
        frame:SetSize(100, 400)
        RC.Position.Bind(frame, function() return self.db.potionsBar end, {
            point = "TOPLEFT", pointKey = "anchorPoint",
            default = { point = "TOPRIGHT", x = -10, y = -400 },
        })
        RC.Position.ApplyStored(frame) -- real layout restores at true size
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:SetClampedToScreen(true)
        if not db.locked then
            frame:RegisterForDrag("LeftButton")
        end

        frame.bg = frame:CreateTexture(nil, "BACKGROUND")
        frame.bg:SetAllPoints()
        local shouldShowBg = (db.showBackground)
        local frameBgCol = GetPotBarBg()
        if shouldShowBg then
            frame.bg:SetColorTexture(frameBgCol.r, frameBgCol.g, frameBgCol.b, frameBgCol.a or 0.90)
        else
            frame.bg:SetColorTexture(C.transparent[1], C.transparent[2], C.transparent[3], C.transparent[4])
        end

        local borderCol = GetPotBarBorder()
        frame.border = RC.UI:CreateSimpleBorder(frame)
        RC.UI:UpdateBorderColor(frame.border, borderCol)
        if not shouldShowBg then
            if frame.border.top    then frame.border.top:Hide()    end
            if frame.border.bottom then frame.border.bottom:Hide() end
            if frame.border.left   then frame.border.left:Hide()   end
            if frame.border.right  then frame.border.right:Hide()  end
        end

        self:ApplyBarAccent(frame, "potionsBar", borderCol, shouldShowBg)

        local titleCol = GetPotBarTitle()
        frame.titleText = self:CreateFontString(frame, "OVERLAY", nil, 10)
        frame.titleText:SetPoint("BOTTOM", frame, "TOP", 0, 20)
        frame.titleText:SetText(RCL["Potions  (drag to move)"])
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
            local currentDb = self.db.potionsBar
            if not currentDb.locked then
                frame.unlockHint:SetText(RCL["Right-click to lock"])
                frame.unlockHint:Show()
            else
                frame.unlockHint:SetText(RCL["Right-click to unlock"])
                frame.unlockHint:Show()
            end
        end)

        frame:SetScript("OnLeave", function()
            frame.unlockHint:Hide()
        end)

        RC.Position.MakeMovable(frame, function() return not self.db.potionsBar.locked end)

        frame:SetScript("OnMouseUp", function(f, button)
            if button == "RightButton" and not InCombatLockdown() then
                self:TogglePotionsBarLock()
            end
        end)

        self:StartBarsMaintTicker()

        -- Shared bar events (Consumables_Events), same shape as the
        -- consumables bar: the 2s settle hold gates bag-driven rebuilds.
        RC:RegisterBarEvents("potionsBar", {
            visibility = "UpdatePotionsVisibility",
            settle = true,
            combatEnd = function()
                self:UpdatePotionsVisibility()
            end,
            bags = function()
                if self.potionsBar.stableStateReached
                    and self.potionsBar._bagVersion ~= RC.Bags:Version() then
                    self:UpdatePotionsButtons()
                end
            end,
        })

        self.potionsBar.frame = frame

        self:UpdatePotionsBarBackground()
        self:UpdatePotionsBarLock()

        if RC.AttachContainerMouseoverFade then
            RC:AttachContainerMouseoverFade(frame, function()
                local d = RC.db and RC.db.potionsBar
                if not d then return nil end
                local fi, fo = RC.BarStyle.FadeTimes("potionsBar")
                return { enabled = d.mouseoverFade, alpha = d.mouseoverFadeAlpha or 0.15, fadeIn = fi, fadeOut = fo }
            end)
            if RC.UpdatePotionsBarMouseoverFade then
                RC:UpdatePotionsBarMouseoverFade()
            end
        end

        if db.enabled then
            -- Decide shown/hidden from the zone mode rather than showing
            -- unconditionally; UpdatePotionsButtons below only hides when
            -- its data has loaded, so a city-only bar would otherwise sit
            -- on screen until the first retry.
            self.potionsBar.stableStateReached = true
            if not InCombatLockdown() then
                if self:ShouldShowPotionsBar() then
                    frame:Show()
                else
                    frame:Hide()
                end
            end

                if self.debugCategories and self.debugCategories.items and self.debugCategories.items.enabled then
                    local hasData = (self.raidConsumables ~= nil)
                    local hasPotionItems = (self.potionBarItems ~= nil)
                    local count = 0
                    if hasPotionItems then
                        for _ in pairs(self.potionBarItems) do
                            count = count + 1
                        end
                    end
                    self:DebugPrint(string.format(RCL[" Potions bar created - raidConsumables: %s, potionBarItems: %s (count: %d)"],
                        tostring(hasData), tostring(hasPotionItems), count), "items")
                end

            self:UpdatePotionsButtons()
        else
            frame:Hide()
        end

        -- the customization standard's layer / fade / shadow (unset = as always)
        if self.ApplyFrameCustom then self:ApplyFrameCustom(frame, function() return RC.db and RC.db.potionsBar end, { scale = false }) end

        return frame
    end

    function RC:UpdateConsumablesHelperTitleVisibility()
        if not self.consumablesHelper.frame then return end

        local db = self.db.consumablesHelper
        local frame = self.consumablesHelper.frame

        if db.locked then
            frame.titleText:Hide()
        else
            frame.titleText:Show()
        end
    end

    function RC:UpdatePotionsBarTitleVisibility()
        if not self.potionsBar.frame then return end

        local db = self.db.potionsBar
        local frame = self.potionsBar.frame

        if db.locked then
            frame.titleText:Hide()
        else
            frame.titleText:Show()
        end
    end

    -- Everything a bar button shows, on any Button: the secure live
    -- buttons (CreateConsumableButton) and the plain pane samples alike.
    -- o = { size, config, itemData, itemId, isPotionBar, barType,
    --       iconTexture (optional: skips the live icon lookups) }
    function RC:DressBarButton(button, o)
        local size, config, itemData, itemId, isPotionBar = o.size, o.config, o.itemData, o.itemId, o.isPotionBar
        local barType = o.barType
        button.bg = button:CreateTexture(nil, "BACKGROUND")
        button.bg:SetAllPoints()
        button.bg:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])

        local displayItemId = itemData.baseItemId or itemId
        local iconTexture = GetItemIcon(displayItemId) or 134400

        local showWeaponIcons = self.db.consumablesHelper.showWeaponIcons

        if itemData.isBagWeapon and itemData.weaponTexture then
            iconTexture = itemData.weaponTexture
        elseif itemData.isUnifiedWeaponButton then
            if showWeaponIcons then
                if itemData.slot == "mainhand" then
                    local weaponTexture = GetInventoryItemTexture("player", 16)
                    if weaponTexture then
                        iconTexture = weaponTexture
                    end
                elseif itemData.slot == "offhand" then
                    local weaponTexture = GetInventoryItemTexture("player", 17)
                    if weaponTexture then
                        iconTexture = weaponTexture
                    end
                end
            end
        elseif showWeaponIcons and itemData.slot then
            if itemData.slot == "mainhand" then
                local weaponTexture = GetInventoryItemTexture("player", 16)
                if weaponTexture then
                    iconTexture = weaponTexture
                end
            elseif itemData.slot == "offhand" then
                local weaponTexture = GetInventoryItemTexture("player", 17)
                if weaponTexture then
                    iconTexture = weaponTexture
                end
            end
        end

        if o.iconTexture then iconTexture = o.iconTexture end

        button.icon = button:CreateTexture(nil, "BORDER")
        button.icon:SetPoint("TOPLEFT", 1, -1)
        button.icon:SetPoint("BOTTOMRIGHT", -1, 1)
        button.icon:SetTexture(iconTexture)
        -- Standard 8% crop that trims the built-in border baked into WoW
        -- item icon textures.
        button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        button.icon:SetAlpha(1)
        button.lastIconTexture = iconTexture

        button.stoneTexture = GetItemIcon(displayItemId) or 134400

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

        local borderCol = RC:GetColor(barType, "buttonBorder")

        button.borderFrame = CreateFrame("Frame", nil, button, "BackdropTemplate")
        button.borderFrame:SetAllPoints()
        button.borderFrame:SetFrameLevel(button:GetFrameLevel() + 2)
        button.borderFrame:SetBackdrop({
            bgFile = nil,
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        button.borderFrame:SetBackdropBorderColor(borderCol.r, borderCol.g, borderCol.b, borderCol.a or 1)

        button.border = button.borderFrame

        button.innerBorder = button:CreateTexture(nil, "ARTWORK")
        button.innerBorder:SetAllPoints()
        button.innerBorder:SetColorTexture(0.3, 0.3, 0.3, 0)
        button.innerBorder:SetDrawLayer("ARTWORK", 1)

        -- Three Cooldown frames, deliberately not one: gcdFrame (GCD swirl
        -- with leading edge), cooldownFrame (real cooldown, no edge),
        -- castFrame (reversed cast/eat swirl, on top). They can be live at
        -- once, and each keeps its own alpha - hence the explicit handling
        -- of all three in SetBarButtonVisualHidden.
        button.gcdFrame = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        button.gcdFrame:SetAllPoints(button.icon)
        button.gcdFrame:SetDrawEdge(true)
        button.gcdFrame:SetDrawSwipe(true)
        button.gcdFrame:SetSwipeColor(0, 0, 0, 0.7)
        button.gcdFrame:SetHideCountdownNumbers(true)
        button.gcdFrame:SetFrameLevel(button:GetFrameLevel() + 2)
        button.gcdFrame:Hide()

        button.cooldownFrame = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        button.cooldownFrame:SetAllPoints(button.icon)
        button.cooldownFrame:SetDrawEdge(false)
        button.cooldownFrame:SetDrawSwipe(true)
        button.cooldownFrame:SetSwipeColor(0, 0, 0, 0.7)
        button.cooldownFrame:SetHideCountdownNumbers(true)
        button.cooldownFrame:SetFrameLevel(button:GetFrameLevel() + 2)
        button.cooldownFrame:Hide()
        button.lastCooldownStart = 0

        button.castFrame = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
        button.castFrame:SetAllPoints(button.icon)
        button.castFrame:SetDrawEdge(false)
        button.castFrame:SetDrawSwipe(true)
        button.castFrame:SetSwipeColor(0, 0, 0, 0.6)
        button.castFrame:SetHideCountdownNumbers(true)
        button.castFrame:SetFrameLevel(button:GetFrameLevel() + 3)
        button.castFrame:SetReverse(true)
        button.castFrame:Hide()
        button.lastCastStart = 0

        -- All text lives on this child frame so it draws above the three
        -- Cooldown frames. Consequence: those font strings do not inherit
        -- the button's alpha, so hiding the button also has to zero them.
        button.textOverlay = CreateFrame("Frame", nil, button)
        button.textOverlay:SetAllPoints(button)
        button.textOverlay:SetFrameLevel(button:GetFrameLevel() + 5)

        if config.showCount then
            local countFontSize = math.max(8, math.floor(size * 0.33))
            button.count = self:CreateFontString(button.textOverlay, "OVERLAY", nil, countFontSize)
            button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
            button.count:SetTextColor(C.white[1], C.white[2], C.white[3], C.white[4])
            button.count:SetShadowOffset(1, -1)
            button.count:SetShadowColor(0, 0, 0, 1)
            button.count:SetDrawLayer("OVERLAY", 6)
            button.count:SetAlpha(1)
            button.count:Hide()
        end

        local gcdFontSize = math.max(14, math.floor(size * 0.6))
        button.gcdText = self:CreateFontString(button.textOverlay, "OVERLAY", nil, gcdFontSize)
        button.gcdText:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.gcdText:SetTextColor(C.white[1], C.white[2], C.white[3], C.white[4])
        button.gcdText:SetShadowOffset(3, -3)
        button.gcdText:SetShadowColor(0, 0, 0, 1)
        button.gcdText:SetDrawLayer("OVERLAY", 7)
        button.gcdText:SetAlpha(1)
        button.gcdText:Hide()

        local expiryFontSize = math.max(12, math.floor(size * 0.5))
        button.expiryText = self:CreateFontString(button.textOverlay, "OVERLAY", nil, expiryFontSize)
        button.expiryText:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.expiryText:SetTextColor(C.yellow[1], C.yellow[2], C.yellow[3], C.yellow[4])
        button.expiryText:SetShadowOffset(2, -2)
        button.expiryText:SetShadowColor(0, 0, 0, 1)
        button.expiryText:SetDrawLayer("OVERLAY", 7)
        button.expiryText:SetAlpha(1)
        button.expiryText:Hide()

        local timeFontSize = math.max(10, math.floor(size * 0.33))
        button.weaponTimeText = self:CreateFontString(button.textOverlay, "OVERLAY", nil, timeFontSize)
        button.weaponTimeText:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
        button.weaponTimeText:SetTextColor(C.yellowLight[1], C.yellowLight[2], C.yellowLight[3], C.yellowLight[4])
        button.weaponTimeText:SetShadowOffset(1, -1)
        button.weaponTimeText:SetShadowColor(0, 0, 0, 1)
        button.weaponTimeText:SetDrawLayer("OVERLAY", 6)
        button.weaponTimeText:SetAlpha(1)
        button.weaponTimeText:Hide()

        local durationFontSize = math.max(14, math.floor(size * 0.6))
        button.durationText = self:CreateFontString(button.textOverlay, "OVERLAY", nil, durationFontSize)
        button.durationText:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.durationText:SetTextColor(C.yellow[1], C.yellow[2], C.yellow[3], C.yellow[4])
        button.durationText:SetShadowOffset(3, -3)
        button.durationText:SetShadowColor(0, 0, 0, 1)
        button.durationText:SetDrawLayer("OVERLAY", 7)
        button.durationText:SetAlpha(1)
        button.durationText:Hide()

        local cooldownFontSize = math.max(12, math.floor(size * 0.55))
        button.cooldownText = self:CreateFontString(button.textOverlay, "OVERLAY", nil, cooldownFontSize)
        button.cooldownText:SetPoint("CENTER", button, "CENTER", 3, 0)
        button.cooldownText:SetTextColor(C.white[1], C.white[2], C.white[3], C.white[4])
        button.cooldownText:SetShadowOffset(2, -2)
        button.cooldownText:SetShadowColor(0, 0, 0, 1)
        button.cooldownText:SetDrawLayer("OVERLAY", 7)
        button.cooldownText:SetAlpha(1)
        button.cooldownText:Hide()

        button.cooldownOverlay = button:CreateTexture(nil, "OVERLAY")
        button.cooldownOverlay:SetAllPoints(button.icon)
        button.cooldownOverlay:SetColorTexture(0, 0, 0, 0.7)
        button.cooldownOverlay:SetDrawLayer("OVERLAY", 6)
        button.cooldownOverlay:SetAlpha(1)
        button.cooldownOverlay:Hide()

        -- The expiry glow: a halo (the client's IconAlert ring, ADD) on its
        -- own frame hung from one point, so RC.Motion can pulse it about
        -- the button's centre. Colour, size and animation: BarStyle.
        -- (It used to be a flat square whose colour alpha was 0 - never seen.)
        button.expiryGlowFrame = CreateFrame("Frame", nil, button)
        button.expiryGlowFrame:SetSize(size, size)
        button.expiryGlowFrame:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.expiryGlowFrame:SetFrameLevel(button:GetFrameLevel() + 4)
        button.expiryGlow = button.expiryGlowFrame:CreateTexture(nil, "OVERLAY")
        button.expiryGlow:SetPoint("CENTER")
        button.expiryGlow:SetSize(size * 1.5, size * 1.5)
        button.expiryGlow:SetTexture("Interface\\SpellActivationOverlay\\IconAlert")
        button.expiryGlow:SetTexCoord(0.00781250, 0.50781250, 0.27734375, 0.52734375)
        button.expiryGlow:SetBlendMode("ADD")
        button.expiryGlowFrame:Hide()

		if isPotionBar and RC.potionAbsorbSpells[itemId] then
			button.absorbContainer = CreateFrame("Frame", nil, button)
			button.absorbContainer:SetSize(size - 4, 5)
			button.absorbContainer:SetPoint("TOP", button, "TOP", 0, -2)
			button.absorbContainer:SetFrameLevel(button:GetFrameLevel() + 20)

			button.absorbBG = button.absorbContainer:CreateTexture(nil, "OVERLAY")
			button.absorbBG:SetAllPoints()
			button.absorbBG:SetColorTexture(0, 0, 0, 0.85)
			button.absorbBG:SetDrawLayer("OVERLAY", 0)

			button.absorbBar = button.absorbContainer:CreateTexture(nil, "OVERLAY")
			button.absorbBar:SetPoint("TOPLEFT", 1, -1)
			button.absorbBar:SetPoint("BOTTOMLEFT", 1, 1)
			button.absorbBar:SetWidth(1)

			local absorbData = RC.potionAbsorbSpells[itemId]
			if absorbData and absorbData.school and RC.schoolColors[absorbData.school] then
				local color = RC.schoolColors[absorbData.school]
				button.absorbBar:SetColorTexture(color.r, color.g, color.b, 1)
			else
				button.absorbBar:SetColorTexture(C.blue[1], C.blue[2], C.blue[3], 1)
			end

			button.absorbBar:SetDrawLayer("OVERLAY", 1)

			button.absorbText = self:CreateFontString(button.absorbContainer, "OVERLAY", nil, 9)
			button.absorbText:SetPoint("CENTER")
			button.absorbText:SetTextColor(C.white[1], C.white[2], C.white[3], C.white[4])
			button.absorbText:SetShadowOffset(1, -1)
			button.absorbText:SetShadowColor(0, 0, 0, 1)
			button.absorbText:SetDrawLayer("OVERLAY", 7)

			button.absorbContainer:Hide()
		end

        local hoverBorderContainer = CreateFrame("Frame", nil, button)
        hoverBorderContainer:SetAllPoints()
        hoverBorderContainer:SetFrameLevel(button:GetFrameLevel() + 5)
        local hoverBorderColor = RC:GetColor("ui", "accentGold")
        button.hoverBorder = RC.UI:CreateSimpleBorder(hoverBorderContainer)
        RC.UI:UpdateBorderColor(button.hoverBorder, hoverBorderColor)
        if button.hoverBorder.top    then button.hoverBorder.top:Hide()    end
        if button.hoverBorder.bottom then button.hoverBorder.bottom:Hide() end
        if button.hoverBorder.left   then button.hoverBorder.left:Hide()   end
        if button.hoverBorder.right  then button.hoverBorder.right:Hide()  end

        if itemData.slot then
            local slotFontSize = math.max(7, math.floor(size * 0.25))
            button.slotLabel = self:CreateFontString(button, "OVERLAY", nil, slotFontSize)
            button.slotLabel:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
            button.slotLabel:SetTextColor(C.white[1], C.white[2], C.white[3], C.white[4])
            button.slotLabel:SetShadowOffset(1, -1)
            button.slotLabel:SetShadowColor(0, 0, 0, 1)
            button.slotLabel:SetAlpha(1)

            if itemData.isBagWeapon then
                button.slotLabel:SetText("B")
                button.slotLabel:SetTextColor(C.blue[1], C.blue[2], C.blue[3], C.blue[4])
            elseif itemData.slot == "mainhand" then
                button.slotLabel:SetText("MH")
            elseif itemData.slot == "offhand" then
                button.slotLabel:SetText("OH")
            else
                button.slotLabel:SetText(itemData.slot:upper():sub(1,2))
            end

            -- Corner badge showing which stone this button will apply, so a
            -- slot button reads as "weapon + stone" rather than just weapon.
            local baseStoneId = itemData.baseItemId or RC.db.consumablesHelper.selectedStoneType or 18262
            local shouldShowStoneIndicator = itemData.isUnifiedWeaponButton or itemData.isBagWeapon or
                                              (RC.weaponStoneIds[baseStoneId] and config.showWeaponIcons)

            if shouldShowStoneIndicator then
                local stoneIcon = GetItemIcon(baseStoneId)
                if stoneIcon then
                    local indicatorSize = math.max(10, math.floor(size * 0.33))
                    local iconSize = indicatorSize - 2

                    button.stoneTypeBorder = button:CreateTexture(nil, "OVERLAY")
                    button.stoneTypeBorder:SetSize(indicatorSize, indicatorSize)
                    button.stoneTypeBorder:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 2, 2)
                    button.stoneTypeBorder:SetColorTexture(0, 0, 0, 0.8)
                    button.stoneTypeBorder:SetDrawLayer("OVERLAY", 6)

                    button.stoneTypeIcon = button:CreateTexture(nil, "OVERLAY")
                    button.stoneTypeIcon:SetSize(iconSize, iconSize)
                    button.stoneTypeIcon:SetPoint("CENTER", button.stoneTypeBorder, "CENTER", 0, 0)
                    button.stoneTypeIcon:SetTexture(stoneIcon)
                    button.stoneTypeIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    button.stoneTypeIcon:SetDrawLayer("OVERLAY", 7)

                    button.hasStoneIcon = true
                end
            end

            local timeLabelSize = math.max(10, math.floor(size * 0.33))
            button.timeLabel = self:CreateFontString(button, "OVERLAY", nil, timeLabelSize)
            button.timeLabel:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
            button.timeLabel:SetTextColor(C.yellowLight[1], C.yellowLight[2], C.yellowLight[3], C.yellowLight[4])
            button.timeLabel:SetShadowOffset(1, -1)
            button.timeLabel:SetShadowColor(0, 0, 0, 1)
            button.timeLabel:SetDrawLayer("OVERLAY", 6)
            button.timeLabel:Hide()

            -- Four separate 1px textures rather than a backdrop border:
            -- UpdateButtonStates hides the right/bottom edges where two
            -- enchanted buttons touch, so the grid shows no doubled line.
            button.appliedBorder = CreateFrame("Frame", nil, button)
            button.appliedBorder:SetAllPoints()
            button.appliedBorder:SetFrameLevel(button:GetFrameLevel() + 4)

            button.appliedBorder.top = button.appliedBorder:CreateTexture(nil, "OVERLAY")
            button.appliedBorder.top:SetHeight(1)
            button.appliedBorder.top:SetPoint("TOPLEFT")
            button.appliedBorder.top:SetPoint("TOPRIGHT")
            button.appliedBorder.top:SetColorTexture(C.cyan[1], C.cyan[2], C.cyan[3], C.cyan[4])
            button.appliedBorder.top:SetDrawLayer("OVERLAY", 7)
            button.appliedBorder.top:Hide()

            button.appliedBorder.bottom = button.appliedBorder:CreateTexture(nil, "OVERLAY")
            button.appliedBorder.bottom:SetHeight(1)
            button.appliedBorder.bottom:SetPoint("BOTTOMLEFT")
            button.appliedBorder.bottom:SetPoint("BOTTOMRIGHT")
            button.appliedBorder.bottom:SetColorTexture(C.cyan[1], C.cyan[2], C.cyan[3], C.cyan[4])
            button.appliedBorder.bottom:SetDrawLayer("OVERLAY", 7)
            button.appliedBorder.bottom:Hide()

            button.appliedBorder.left = button.appliedBorder:CreateTexture(nil, "OVERLAY")
            button.appliedBorder.left:SetWidth(1)
            button.appliedBorder.left:SetPoint("TOPLEFT")
            button.appliedBorder.left:SetPoint("BOTTOMLEFT")
            button.appliedBorder.left:SetColorTexture(C.cyan[1], C.cyan[2], C.cyan[3], C.cyan[4])
            button.appliedBorder.left:SetDrawLayer("OVERLAY", 7)
            button.appliedBorder.left:Hide()

            button.appliedBorder.right = button.appliedBorder:CreateTexture(nil, "OVERLAY")
            button.appliedBorder.right:SetWidth(1)
            button.appliedBorder.right:SetPoint("TOPRIGHT")
            button.appliedBorder.right:SetPoint("BOTTOMRIGHT")
            button.appliedBorder.right:SetColorTexture(C.cyan[1], C.cyan[2], C.cyan[3], C.cyan[4])
            button.appliedBorder.right:SetDrawLayer("OVERLAY", 7)
            button.appliedBorder.right:Hide()
        end

        -- Squeezes an item name into a 36px button: user abbreviation first,
        -- then strip the common Classic Era prefixes/suffixes, then fall
        -- back to the first word, then a hard 7-char truncation.
        local function GetShortItemName(fullName)
            if not fullName then return "" end

            if RC.GetItemAbbreviation then
                local abbrev = RC:GetItemAbbreviation(fullName)
                if abbrev then return abbrev end
            end

            local shortName = fullName
            shortName = shortName:gsub("^Greater%s+", "")
            shortName = shortName:gsub("^Lesser%s+", "")
            shortName = shortName:gsub("^Elixir%s+of%s+the%s+", "")
            shortName = shortName:gsub("^Elixir%s+of%s+", "")
            shortName = shortName:gsub("^Flask%s+of%s+", "")
            shortName = shortName:gsub("^Juju%s+", "")
            shortName = shortName:gsub("^Spirit%s+of%s+", "")
            shortName = shortName:gsub("^Scroll%s+of%s+", "")
            shortName = shortName:gsub("^Potion%s+of%s+", "")
            shortName = shortName:gsub("%s+Potion$", "")
            shortName = shortName:gsub("%s+Elixir$", "")
            shortName = shortName:gsub("%s+Protection$", "Prot")

            if #shortName > 7 then
                local firstWord = shortName:match("^(%S+)")
                if firstWord and #firstWord >= 3 then
                    shortName = firstWord
                end
            end

            if #shortName > 7 then
                shortName = shortName:sub(1, 6) .. "."
            end

            return shortName
        end

        button.nameLabel = self:CreateFontString(button, "OVERLAY", nil, 7)
        local isWeaponButton = itemData.slot or itemData.isBagWeapon or itemData.isUnifiedWeaponButton
        if isWeaponButton then
            button.nameLabel:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -12)
            button.nameLabel:SetJustifyH("LEFT")
        else
            button.nameLabel:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
            button.nameLabel:SetPoint("TOPRIGHT", button, "TOPRIGHT", -2, -2)
            button.nameLabel:SetJustifyH("CENTER")
        end
        button.nameLabel:SetHeight(10)
        button.nameLabel:SetTextColor(C.white[1], C.white[2], C.white[3], C.white[4])
        button.nameLabel:SetShadowOffset(1, -1)
        button.nameLabel:SetShadowColor(0, 0, 0, 1)
        button.nameLabel:SetJustifyV("TOP")
        button.nameLabel:SetWordWrap(false)
        button.nameLabel:SetText(GetShortItemName(itemData.name))
        button.nameLabel:SetDrawLayer("OVERLAY", 6)
        button._rcBarKey = o.barKey or button._rcBarKey
        button.itemData = itemData
        button.isPotionBar = isPotionBar
        button.isWeaponsBar = o.isWeaponsBar and true or false
        self:StyleBarButton(button, nil, size)
    end

    -- Builds one bar button; the bar is selected by isPotionBar or by
    -- overrideConfig/overrideFrame. Only called from a rebuild, which has
    -- already ruled out combat lockdown - the secure template and every
    -- SetAttribute below require it.
    function RC:CreateConsumableButton(itemId, itemData, index, category, isPotionBar, overrideConfig, overrideFrame)
        local config = overrideConfig or (isPotionBar and self.db.potionsBar or self.db.consumablesHelper)
        local frame = overrideFrame or (isPotionBar and self.potionsBar.frame or self.consumablesHelper.frame)

        local size = config.buttonSize or 36
        local spacing = config.iconSpacing or 4
        local perRow = config.buttonsPerRow or 2
        local growDir = config.growDirection or "DOWN"
        local topOffset = -5

        local buttonPrefix
        if isPotionBar then
            buttonPrefix = "WRPotionButton"
        elseif overrideFrame == self.weaponsBar.frame then
            buttonPrefix = "WRWeaponBarButton"
        else
            buttonPrefix = "WRConsumableButton"
        end
        local button = CreateFrame("Button", buttonPrefix..itemId, frame, "SecureActionButtonTemplate")
        button:SetSize(size, size)
        button:RegisterForClicks("AnyDown", "AnyUp")
        button:EnableMouse(true)
        button:SetAlpha(1)

        -- PreClick timestamps the use before the item leaves the bag, which
        -- is what lets the cooldown ticker distinguish a click-driven GCD
        -- from an unrelated one. Guarded because HookScript stacks.
        if not button._wrPreHook then
            button._wrPreHook = true
        button:HookScript("PreClick", function(self)
            RC._lastBarItemUse = GetTime()
            if self and self.itemId then
                RC._lastUsedBarItemId = self.itemId
            end
        end)
        end

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

        button:SetPoint("TOPLEFT", frame, "TOPLEFT", xPos, yPos)

        if button.count then
            self:ApplyCustomFont(button.count, math.max(8, math.floor(size * 0.33)))
        end

        button.gridRow = row
        button.gridCol = col

        local displayItemId = itemData.baseItemId or itemId
        self:DressBarButton(button, {
            size = size, config = config, itemData = itemData, itemId = itemId,
            isPotionBar = isPotionBar, isWeaponsBar = overrideConfig ~= nil and overrideConfig == self.db.weaponsBar,
            barType = isPotionBar and "potionsBar" or (overrideFrame and "weaponBar" or "consumablesBar"),
        })

        local isWeaponsBarButton = (overrideConfig == self.db.weaponsBar)
        if isWeaponsBarButton then
            if config.showItemNames then
                button.nameLabel:Show()
            else
                button.nameLabel:Hide()
            end
        elseif itemData.isUnifiedWeaponButton or itemData.isBagWeapon then
            button.nameLabel:Hide()
        elseif config.showItemNames then
            button.nameLabel:Show()
        else
            button.nameLabel:Hide()
        end

        button.itemId = itemId
        button.itemData = itemData or {}
        button._consumableName = itemData and itemData.name or nil
        button.itemData.category = category
        button.sortIndex = index
        button.isPotionBar = isPotionBar
        button.isWeaponsBar = (overrideConfig == self.db.weaponsBar)
        button.fullyInitialized = true
        button.lastAbsorbUpdate = 0

        button:SetScript("OnEnter", function(self)
            button.hoverBorder.top:Show()
            button.hoverBorder.bottom:Show()
            button.hoverBorder.left:Show()
            button.hoverBorder.right:Show()

            if RC.db.consumablesHelper.groupConflictButtons then
                local conflictGroup = RC:GetConflictGroup(displayItemId)
                if conflictGroup then
                    RC:StartModifierPreview(button, conflictGroup, displayItemId)
                end
            end

            if not config.showTooltips then return end

            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

            if itemData.isBagWeapon and itemData.weaponLink then
                GameTooltip:SetHyperlink(itemData.weaponLink)
                local stoneName = RC:GetStoneName(displayItemId)
                local stoneCount = GetItemCount(displayItemId)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(RCL["Apply: "] .. stoneName, 0.5, 0.8, 1)
                GameTooltip:AddLine(RCL["Stones in bags: "] .. stoneCount, 0.7, 0.7, 0.7)
                if stoneCount > 0 then
                    GameTooltip:AddLine(RCL["Click to apply stone"], 0.3, 1, 0.3)
                else
                    GameTooltip:AddLine(RCL["No stones available!"], 1, 0.3, 0.3)
                end
                GameTooltip:Show()
                return
            end

            GameTooltip:SetItemByID(displayItemId)

            local count = GetItemCount(displayItemId)
            local hasBuff, timeRemaining = RC:HasConsumableBuff(displayItemId)

            local charges = 0
            if itemData.slot then
                hasBuff, timeRemaining = RC:HasWeaponEnchant(displayItemId, itemData.slot)
                -- a poison: its real time left, and its charges
                if hasBuff and RC.GetWeaponCharges then
                    local ch, real = RC:GetWeaponCharges(itemData.slot)
                    if ch > 0 then charges, timeRemaining = ch, real end
                end
            elseif itemData.enchantId then
                hasBuff, timeRemaining = RC:HasWeaponEnchant(displayItemId, "mainhand")
            end

            local conflictGroup = RC:TimerConflictGroup(displayItemId)
            local hasConflict, conflictTime, conflictItemId = false, 0, nil
            if conflictGroup then
                hasConflict, conflictTime, conflictItemId = RC:HasConflictGroupBuff(conflictGroup)
            end

            if hasBuff then
                GameTooltip:AddLine(" ")
                local minutes = math_floor(timeRemaining / 60)
                local seconds = math_floor(timeRemaining % 60)
                local timeText = minutes > 0 and string_format("Active: %dm %ds remaining", minutes, seconds) or string_format("Active: %ds remaining", seconds)

                if itemData.slot then
                    local slotName = itemData.slot == "mainhand" and "Main Hand" or (itemData.slot == "offhand" and "Off Hand" or "Bag Weapon")
                    local _, _, enchantId = RC:HasWeaponEnchant(displayItemId, itemData.slot)
                    local appliedStone = enchantId and RC:GetStoneFromEnchantId(enchantId)
                    local appliedStoneName = appliedStone and RC:GetStoneName(appliedStone) or "Unknown enchant"

                    GameTooltip:AddLine(RCL["Applied to "] .. slotName .. ": " .. appliedStoneName, 0.3, 1, 0.3)
                    GameTooltip:AddLine(timeText, 0.3, 1, 0.3)
                    if charges > 0 then
                        local low = charges <= (RC.POISON_LOW_CHARGES or 10)
                        local cc = RC:GetColor("text", low and "red" or "green")
                        GameTooltip:AddLine(string_format(RCL["%d charges left"], charges), cc.r, cc.g, cc.b)
                    end
                    if count > 0 then
                        GameTooltip:AddLine(RCL["Left-click to reapply"], 1, 1, 0.5)
                    end
                else
                    GameTooltip:AddLine(timeText, 0.3, 1, 0.3)
                end
            elseif hasConflict and conflictItemId ~= displayItemId then
                GameTooltip:AddLine(" ")
                local minutes = math_floor(conflictTime / 60)
                local seconds = math_floor(conflictTime % 60)
                local timeText = minutes > 0 and string_format("Conflict buff active: %dm %ds", minutes, seconds) or string_format("Conflict buff active: %ds", seconds)
                GameTooltip:AddLine(timeText, 1, 0.8, 0.3)
            elseif count > 0 then
                GameTooltip:AddLine(" ")
                if itemData.slot == "mainhand" or itemData.enchantId then
                    GameTooltip:AddLine(RCL["Left-click to apply to main hand"], 0.3, 1, 0.3)
                elseif itemData.slot == "offhand" then
                    GameTooltip:AddLine(RCL["Left-click to apply to off hand"], 0.3, 1, 0.3)
                elseif itemData.slot == "bag" then
                    GameTooltip:AddLine(RCL["Left-click to apply stone"], 0.3, 1, 0.3)
                else
                    GameTooltip:AddLine(RCL["Left-click to use"], 0.3, 1, 0.3)
                end
            else
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(RCL["Not in bags"], 1, 0.3, 0.3)
            end

            if itemData.isUnifiedWeaponButton or itemData.isBagWeapon then
                GameTooltip:AddLine(" ")
                local currentStone = RC:GetShortStoneName(RC:GetValidStoneType(button.weaponSlot or itemData.slot))
                GameTooltip:AddLine(RCL["Current: "] .. currentStone, 0.9, 0.8, 0.5)
                local _, myCls = UnitClass("player")
                GameTooltip:AddLine(myCls == "ROGUE" and RCL["Right-click to change poison or stone"] or RCL["Right-click to change stone type"], 0.7, 0.7, 0.7)
            end

            GameTooltip:Show()
        end)

        button:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            button.hoverBorder.top:Hide()
            button.hoverBorder.bottom:Hide()
            button.hoverBorder.left:Hide()
            button.hoverBorder.right:Hide()

            RC:StopModifierPreview()
        end)

        local isPotion = RC.potionBarItems[itemId] or (itemData.category == "potions") or (itemData.category == "protectionPotions")
        local isElixirOrFlask = (itemData.category == "elixirs") or (itemData.category == "flasks")

        if itemData.isUnifiedWeaponButton or itemData.isBagWeapon then
            button.weaponSlot = itemData.slot
            button.isWeaponButton = true
            if itemData.isBagWeapon then
                button.bagSlot = itemData.bagSlot
                button.bagPosition = itemData.bagPosition
            end
        end

        -- Weapons-bar buttons open the stone picker when the clicked slot's
        -- configured action is "picker". Guarded because HookScript stacks.
        local function InstallWeaponsBarPickerHook(btn)
            if btn._wrPickerHook then return end
            btn._wrPickerHook = true
            btn:HookScript("OnMouseUp", function(self, mouseButton)
                if InCombatLockdown() then return end
                if self.isWeaponsBar and RC:GetWeaponClickAction(RC:GetWeaponBarClickSlot(mouseButton)) == "picker" then
                    RC:ShowStonePicker(self)
                end
            end)
        end

        -- Click wiring; every branch writes secure attributes. On the
        -- weapons bar right-click is a configurable action so the button
        -- takes any click; elsewhere right-click is reserved for the stone
        -- picker and only left-click reaches the secure handler.
        if itemData.isBagWeapon then
            local _onWB = overrideFrame and RC.weaponsBar
                and overrideFrame == RC.weaponsBar.frame
            if _onWB then
                button:RegisterForClicks("AnyDown", "AnyUp")
            else
                button:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
            end
            RC:UpdateWeaponButtonMacro(button)
            InstallWeaponsBarPickerHook(button)
        elseif itemData.isUnifiedWeaponButton then
            RC:UpdateWeaponButtonMacro(button)
            InstallWeaponsBarPickerHook(button)
        -- "/use item:X" then "/use 16|17": pick up the stone, apply it to
        -- the equipped weapon, then dismiss the replace-enchant confirmation
        -- popup. 16 = main hand, 17 = off hand.
        elseif itemData.slot == "mainhand" then
            local baseItemId = itemData.baseItemId or itemId
            button:SetAttribute("type", "macro")
            button:SetAttribute("macrotext", "/use item:" .. baseItemId .. "\n/use 16\n/click [nodead] StaticPopup1Button1")
        elseif itemData.slot == "offhand" then
            button:SetAttribute("type", "macro")
            button:SetAttribute("macrotext", "/use item:" .. itemData.baseItemId .. "\n/use 17\n/click [nodead] StaticPopup1Button1")
        elseif itemData.enchantId then
            button:SetAttribute("type", "macro")
            button:SetAttribute("macrotext", "/use item:" .. itemId .. "\n/use 16\n/click [nodead] StaticPopup1Button1")
        -- 13506 Flask of Petrification: opt-in mode that chains /camp to the
        -- use, the standard "log out while immune" wipe-save.
        elseif itemId == 13506 and ((isPotionBar and RC.db.potionsBar.petrificationCampMode) or ((not isPotionBar) and RC.db.consumablesHelper.petrificationCampMode)) then
            button:SetAttribute("type", "macro")
            button:SetAttribute("macrotext", "/use Flask of Petrification\n/camp")
            button.originalItemName = "Flask of Petrification"
            if not button._wrPetriHook then
                button._wrPetriHook = true
                button:HookScript("PostClick", function(self, mouseButton)
                    if not InCombatLockdown() then
                        self:SetAttribute("type", "macro")
                        self:SetAttribute("macrotext", "/use Flask of Petrification\n/camp")
                    end
                end)
            end
        -- Jujus and similar are castable on others; [@player] stops a
        -- hostile or friendly target from eating the click.
        elseif itemData.selfCastOnly and RC.db.consumablesHelper.selfCastJujus then
            button:SetAttribute("type", "macro")
            button:SetAttribute("macrotext", "/use [@player] " .. itemData.name)

            button.originalItemName = itemData.name
            button.selfCastOnly = true

            button:HookScript("PostClick", function(self, mouseButton)
                if not InCombatLockdown() then
                    local preview = RC.modifierPreview
                    if preview.hoveredButton == self then
                        return
                    end
                    self:SetAttribute("type", "macro")
                    self:SetAttribute("macrotext", "/use [@player] " .. itemData.name)
                end
            end)
        else
            button:SetAttribute("type", "item")
            button:SetAttribute("item", itemData.name)

            button.originalItemName = itemData.name

            -- Restore the base item after a click, since the modifier
            -- preview may have swapped the attribute. Skipped while still
            -- hovered: the preview owns the attribute then.
            button:HookScript("PostClick", function(self, mouseButton)
                if not InCombatLockdown() then
                    local preview = RC.modifierPreview
                    if preview.hoveredButton == self then
                        return
                    end
                    self:SetAttribute("type", "item")
                    self:SetAttribute("item", itemData.name)
                end
            end)
        end

        -- Buttons cover the whole bar, so dragging one has to move the
        -- parent frame: forward the drag scripts up rather than duplicate
        -- the position-saving logic.
        button:RegisterForDrag("LeftButton")
        button:SetScript("OnDragStart", function(self)
            local parent = self:GetParent()
            if parent and parent.GetScript then
                local parentDragStart = parent:GetScript("OnDragStart")
                if parentDragStart then
                    parentDragStart(parent)
                end
            end
        end)
        button:SetScript("OnDragStop", function(self)
            local parent = self:GetParent()
            if parent and parent.GetScript then
                local parentDragStop = parent:GetScript("OnDragStop")
                if parentDragStop then
                    parentDragStop(parent)
                end
            end
        end)

        button:Show()
        if itemData and (itemData.isBagWeapon or itemData.isUnifiedWeaponButton) then
            local onWeaponsBar = overrideFrame and RC.weaponsBar
                and overrideFrame == RC.weaponsBar.frame
            if not onWeaponsBar then
                button:SetAttribute("type2", "")
                button:HookScript("OnMouseUp", function(self, mb)
                    if mb ~= "RightButton" or InCombatLockdown() then return end
                    if self.isWeaponsBar or not RC.ShowStonePicker then return end
                    RC:ShowStonePicker(self)
                    local dd = RC.stonePickerDropdown
                    if dd and dd:IsShown() then
                        dd:ClearAllPoints()
                        if (self:GetBottom() or 0) < (UIParent:GetHeight() / 2) then
                            dd:SetPoint("BOTTOMLEFT", self, "TOPLEFT", 0, 4)
                        else
                            dd:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -4)
                        end
                    end
                end)
            end
        end

        return button
    end

    function RC:ShowConflictGroupPicker(anchorButton, groupName)
        if not groupName or not self.conflictGroupPriority or not self.conflictGroupPriority[groupName] then
            return
        end

        local priority = self.conflictGroupPriority[groupName]
        local prefs = self.db.consumablesHelper.conflictGroupPreferences or {}
        local currentPref = prefs[groupName]

        if not self.conflictGroupMenu then
            self.conflictGroupMenu = CreateFrame("Frame", "WRConflictGroupMenu", UIParent, "UIDropDownMenuTemplate")
        end

        local menu = self.conflictGroupMenu

        UIDropDownMenu_Initialize(menu, function(dropdown, level)
            local autoInfo = UIDropDownMenu_CreateInfo()
            autoInfo.text = RCL["Auto (first available)"]
            autoInfo.value = nil
            autoInfo.func = function()
                if not RC.db.consumablesHelper.conflictGroupPreferences then
                    RC.db.consumablesHelper.conflictGroupPreferences = {}
                end
                RC.db.consumablesHelper.conflictGroupPreferences[groupName] = nil
                RC:UpdateConsumablesButtons()
                RC:SaveConfigurationToProfile()
                CloseDropDownMenus()
            end
            autoInfo.checked = (currentPref == nil)
            UIDropDownMenu_AddButton(autoInfo, level)

            local sepInfo = UIDropDownMenu_CreateInfo()
            sepInfo.text = ""
            sepInfo.isTitle = true
            sepInfo.notCheckable = true
            UIDropDownMenu_AddButton(sepInfo, level)

            for _, itemId in ipairs(priority) do
                local itemName, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(itemId)
                itemName = itemName or RC:FlavorItemName(itemId)
                local count = GetItemCount(itemId)

                local info = UIDropDownMenu_CreateInfo()
                info.text = (itemName or ("Item #" .. itemId)) .. (count > 0 and " (" .. count .. ")" or " |cff888888(none)|r")
                info.value = itemId
                info.icon = itemTexture
                info.func = function()
                    if not RC.db.consumablesHelper.conflictGroupPreferences then
                        RC.db.consumablesHelper.conflictGroupPreferences = {}
                    end
                    RC.db.consumablesHelper.conflictGroupPreferences[groupName] = itemId
                    RC:UpdateConsumablesButtons()
                    RC:SaveConfigurationToProfile()
                    CloseDropDownMenus()
                end
                info.checked = (currentPref == itemId)
                UIDropDownMenu_AddButton(info, level)
            end
        end, "MENU")

        ToggleDropDownMenu(1, nil, menu, anchorButton, 0, 0)
    end

    -- Sort weight per category; anything absent (custom items, chronoboon)
    -- falls to 99 and lands after these.
    local categoryOrder = {
		["flasks"] = 1,
		["elixirs"] = 2,
		["potions"] = 3,
		["protectionPotions"] = 4,
		["food"] = 5,
		["drinks"] = 6,
		["buffs"] = 7,
		["utilities"] = 8,
		["classItems"] = 9
	}

    local conflictGroupSortKey = {
        ["zanza"] = 1,
        ["apStrength"] = 2,
        ["wellFed"] = 3,
        ["sharpeningStone"] = 4
    }

    -- Backfills text elements and the cast frame on a pooled button: one
    -- created before an option was enabled can be missing any of them, and
    -- every consumer assumes they exist.
    -- A pooled button keeps the size it was created with: when the bar's
    -- button size changes afterwards (the options, or a layout fitting
    -- the bar to the chat's width), the buttons were laid out on the new
    -- pitch at the old size, leaving a gap between them. Called from a
    -- rebuild, which has ruled out combat lockdown.
    function RC:FitButtonSize(button, size)
        if not (button and size and button.GetWidth) then return end
        if math.abs((button:GetWidth() or 0) - size) <= 0.5 or InCombatLockdown() then return end
        button:SetSize(size, size)
        if button.absorbContainer then button.absorbContainer:SetSize(size - 4, 5) end
        -- fonts, stone badge and glow follow the new size at once
        self:FitBarButtonParts(button, size)
    end

    -- The size-derived parts a pooled button was created with: the text
    -- (BarStyle), the stone badge in the corner and the glow.
    function RC:FitBarButtonParts(button, size)
        if button.stoneTypeBorder then
            local indicatorSize = math.max(10, math.floor(size * 0.33))
            button.stoneTypeBorder:SetSize(indicatorSize, indicatorSize)
            if button.stoneTypeIcon then button.stoneTypeIcon:SetSize(indicatorSize - 2, indicatorSize - 2) end
        end
        self:StyleBarButton(button, nil, size)
    end

    function RC:EnsureButtonTextElements(button, config, size)
        if not button then return end
        self:FitButtonSize(button, size)

        if not button.textOverlay then
            button.textOverlay = CreateFrame("Frame", nil, button)
            button.textOverlay:SetAllPoints(button)
            button.textOverlay:SetFrameLevel(button:GetFrameLevel() + 5)
        end

        local textParent = button.textOverlay

        if not button.expiryText then
            -- Same scaled formula as CreateConsumableButton, so a pooled
            -- button's text matches a freshly created one.
            local expiryFontSize = math.max(12, math.floor(size * 0.5))
            button.expiryText = self:CreateFontString(textParent, "OVERLAY", nil, expiryFontSize)
            button.expiryText:SetPoint("CENTER", button, "CENTER", 3, 0)
            button.expiryText:SetTextColor(C.yellow[1], C.yellow[2], C.yellow[3], C.yellow[4])
            button.expiryText:SetShadowOffset(2, -2)
            button.expiryText:SetShadowColor(0, 0, 0, 1)
            button.expiryText:SetDrawLayer("OVERLAY", 7)
            button.expiryText:SetAlpha(1)
            button.expiryText:Hide()

                self:DebugPrint(" Created missing expiryText for button " .. tostring(button.itemId), "items")
        end

        if not button.weaponTimeText then
            local timeFontSize = math.max(10, math.floor(size * 0.33))
            button.weaponTimeText = self:CreateFontString(textParent, "OVERLAY", nil, timeFontSize)
            button.weaponTimeText:SetPoint("TOPRIGHT", button, "TOPRIGHT", -1, -1)
            button.weaponTimeText:SetTextColor(C.yellowLight[1], C.yellowLight[2], C.yellowLight[3], C.yellowLight[4])
            button.weaponTimeText:SetShadowOffset(1, -1)
            button.weaponTimeText:SetShadowColor(0, 0, 0, 1)
            button.weaponTimeText:SetDrawLayer("OVERLAY", 6)
            button.weaponTimeText:SetAlpha(1)
            button.weaponTimeText:Hide()
        end

        if not button.cooldownText then
            local cooldownFontSize = math.max(12, math.floor(size * 0.55))
            button.cooldownText = self:CreateFontString(textParent, "OVERLAY", nil, cooldownFontSize)
            button.cooldownText:SetPoint("CENTER", button, "CENTER", 3, 0)
            button.cooldownText:SetTextColor(C.white[1], C.white[2], C.white[3], C.white[4])
            button.cooldownText:SetShadowOffset(2, -2)
            button.cooldownText:SetShadowColor(0, 0, 0, 1)
            button.cooldownText:SetDrawLayer("OVERLAY", 7)
            button.cooldownText:SetAlpha(1)
            button.cooldownText:Hide()

                self:DebugPrint(" Created missing cooldownText for button " .. tostring(button.itemId), "items")
        end

        if not button.gcdText then
            local gcdFontSize = math.max(14, math.floor(size * 0.6))
            button.gcdText = self:CreateFontString(textParent, "OVERLAY", nil, gcdFontSize)
            button.gcdText:SetPoint("CENTER", button, "CENTER", 0, 0)
            button.gcdText:SetTextColor(C.white[1], C.white[2], C.white[3], C.white[4])
            button.gcdText:SetShadowOffset(3, -3)
            button.gcdText:SetShadowColor(0, 0, 0, 1)
            button.gcdText:SetDrawLayer("OVERLAY", 7)
            button.gcdText:SetAlpha(1)
            button.gcdText:Hide()

                self:DebugPrint(" Created missing gcdText for button " .. tostring(button.itemId), "items")
        end

        if not button.durationText then
            local durationFontSize = math.max(14, math.floor(size * 0.6))
            button.durationText = self:CreateFontString(textParent, "OVERLAY", nil, durationFontSize)
            button.durationText:SetPoint("CENTER", button, "CENTER", 0, 0)
            button.durationText:SetTextColor(C.yellow[1], C.yellow[2], C.yellow[3], C.yellow[4])
            button.durationText:SetShadowOffset(3, -3)
            button.durationText:SetShadowColor(0, 0, 0, 1)
            button.durationText:SetDrawLayer("OVERLAY", 7)
            button.durationText:SetAlpha(1)
            button.durationText:Hide()

                self:DebugPrint(" Created missing durationText for button " .. tostring(button.itemId), "items")
        end

        if config.showCount and not button.count then
            local countFontSize = math.max(8, math.floor(size * 0.33))
            button.count = self:CreateFontString(textParent, "OVERLAY", nil, countFontSize)
            button.count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
            button.count:SetTextColor(C.white[1], C.white[2], C.white[3], C.white[4])
            button.count:SetShadowOffset(1, -1)
            button.count:SetShadowColor(0, 0, 0, 1)
            button.count:SetDrawLayer("OVERLAY", 6)
            button.count:SetAlpha(1)
            button.count:Hide()

                self:DebugPrint(" Created missing count for button " .. tostring(button.itemId), "items")
        end

        if not button.castFrame then
            button.castFrame = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
            button.castFrame:SetAllPoints(button.icon or button)
            button.castFrame:SetDrawEdge(false)
            button.castFrame:SetDrawSwipe(true)
            button.castFrame:SetSwipeColor(0, 0, 0, 0.6)
            button.castFrame:SetHideCountdownNumbers(true)
            button.castFrame:SetFrameLevel(button:GetFrameLevel() + 3)
            button.castFrame:SetReverse(true)
            button.castFrame:Hide()
            button.lastCastStart = 0

            self:DebugPrint(" Created missing castFrame for button " .. tostring(button.itemId), "items")
        end
        -- anything just created takes the bar's style (no-op otherwise)
        self:StyleBarButton(button, nil, size)
    end

    _chs.categoryOrder = categoryOrder
    _chs.conflictGroupSortKey = conflictGroupSortKey
end
