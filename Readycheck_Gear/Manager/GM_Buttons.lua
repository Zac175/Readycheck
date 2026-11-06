local AddonName = "Readycheck"
local RC = _G[AddonName]

if not RC then
    error("Readycheck core not found!")
end

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local GetTime = GetTime
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GetInventoryItemLink = GetInventoryItemLink
local GetInventoryItemID = GetInventoryItemID
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
local C_Container = C_Container
local C_Timer = C_Timer
RC._gms = RC._gms or {}
local _gms = RC._gms
local GM = RC.GearManager
local C, GetGMSlotHoverBorder = _gms.C, _gms.GetGMSlotHoverBorder
local TruncateToWidth = _gms.TruncateToWidth
------------------------------------------------------------------------
-- Readycheck - Gear Manager Buttons
-- Creates/destroys the docked gear buttons (CreateButton/RemoveButton)
-- and the ItemRack set importer at the bottom. Positioning, docking and
-- drag/drop live in GM_Position.lua.
------------------------------------------------------------------------

------------------------------------------------------------------------
-- LOOK. Every look option is optional in RC.db.gearManager.look; nil is
-- the shipped look. The docked buttons, the hover-menu tiles and the
-- settings preview samples are all built by GM:BuildButtonFace and
-- styled by GM:StyleButtonFace, so they always look alike.
------------------------------------------------------------------------
GM.NAME_FONT  = { size = 8,  outline = "OUTLINE", shadow = true }
GM.TIMER_FONT = { size = 14, outline = "OUTLINE", shadow = true }
GM.SWAP_ANIM  = { style = "fade", duration = 0.25, easing = "easeOutQuad" }
GM.MENU_ANIM  = { style = "none", duration = 0.15, easing = "easeOutCubic" }

function GM:Look()
    local g = RC.db and RC.db.gearManager
    if not g then return {} end
    if type(g.look) ~= "table" then g.look = {} end
    return g.look
end

function GM:LookColor(key, cat, ckey)
    local c = self:Look()[key]
    if type(c) == "table" then return c end
    return RC:GetColor(cat, ckey)
end

-- room for a button's name label (32 at the default 36px button)
function GM:NameWidth(button)
    local w = button and button.GetWidth and button:GetWidth() or 0
    if not w or w <= 0 then w = self:GetButtonUnitSize() end
    return math.max(12, w - 4)
end

local function EdgeSize(borders, w)
    if not borders then return end
    if borders.top then borders.top:SetHeight(w) end
    if borders.bottom then borders.bottom:SetHeight(w) end
    if borders.left then borders.left:SetWidth(w) end
    if borders.right then borders.right:SetWidth(w) end
end

local NAME_POINTS = {
    bottom = { "BOTTOM", 0, 2, "BOTTOM" },
    top    = { "TOP", 0, -2, "TOP" },
    center = { "CENTER", 0, 0, "MIDDLE" },
}

-- gearManager.anchors.name / .timer: a spec moves a button's (or a menu
-- tile's) name / timer from the place the look puts it; no spec = left
-- alone (a cleared one puts it back). Targets: the button, its icon, the
-- other text.
local function ButtonTarget(button, k)
    if k == "button" then return button elseif k == "icon" then return button.icon
    elseif k == "name" then return button.nameText elseif k == "timer" then return button.cdText end
    return nil
end
local function TextAnchors()
    local g = RC.db and RC.db.gearManager
    local a = g and g.anchors
    return type(a) == "table" and a or nil
end
local function ButtonTo(button)
    local fn = button._gmTo
    if not fn then
        fn = function(k) return ButtonTarget(button, k) end
        button._gmTo = fn
    end
    return fn
end

-- gearManager.formats.timer: a dockable button's countdown. Nothing saved
-- = today's "2m" / "45" (the fast path); a format words it from the
-- seconds left (GM.TIMER_FORMAT the defaults, as the bars' timers).
GM.TIMER_FORMAT = { time = "short" }
local tfVals, tfKinds = {}, { value = "time" }
function GM:TimerFormatSpec()
    local g = RC.db and RC.db.gearManager
    local f = g and g.formats
    return type(f) == "table" and f.timer or nil
end
function GM:CooldownText(remaining, spec)
    if type(spec) ~= "table" then
        if remaining >= 60 then return math.ceil(remaining / 60) .. "m" end
        return tostring(math.ceil(remaining))
    end
    tfVals.value = remaining
    return RC.UI:FormatText(spec, GM.TIMER_FORMAT, tfVals, tfKinds, "value")
end

-- Fonts, colours, edge and label place from the look settings. Safe on
-- a secure button in combat: only regions are touched.
function GM:StyleButtonFace(button)
    if not button then return end
    local look = self:Look()
    local bw = tonumber(look.borderSize) or 1
    if bw < 0 then bw = 0 end
    button.borderWidth = bw
    if button.icon then
        button.icon:ClearAllPoints()
        button.icon:SetPoint("TOPLEFT", button, "TOPLEFT", bw, -bw)
        button.icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -bw, bw)
    end
    if button.borders then
        EdgeSize(button.borders, math.max(1, bw))
        RC.UI:UpdateBorderColor(button.borders, self:LookColor("borderColor", "ui", "borderNormal"))
        for _, side in pairs(button.borders) do side:SetShown(bw > 0) end
    end
    if button.hoverBorder then
        EdgeSize(button.hoverBorder, math.max(1, bw))
        RC.UI:UpdateBorderColor(button.hoverBorder, GetGMSlotHoverBorder())
    end
    if button.statusBorder and button.statusBorder.top then
        EdgeSize(button.statusBorder, math.max(1, bw))
    end
    if button.cdText then
        RC:ApplyFontSpec(button.cdText, look.timerFont, GM.TIMER_FONT)
        local sh = type(look.timerFont) == "table" and look.timerFont.shadow
        if sh == nil then sh = GM.TIMER_FONT.shadow end
        if sh then button.cdText:SetShadowOffset(2, -2) end
        -- menu tiles paint their countdown once; buttons per tick
        if button.isMenuTile then
            local c = self:LookColor("timerColor", "text", "yellow")
            button.cdText:SetTextColor(c.r, c.g, c.b, c.a or 1)
        end
        local anc = TextAnchors()
        local sp = anc and anc.timer or nil
        if sp or button._gmTimerMoved then
            local ct = button.cdText
            local to = ct:GetParent()
            -- (the justify it was made with, kept from the first move)
            if not button._gmTimerMoved then button._gmTimerJH = ct:GetJustifyH() end
            ct:ClearAllPoints()
            ct:SetPoint("CENTER", to, "CENTER", 0, 0)
            if button._gmTimerJH then ct:SetJustifyH(button._gmTimerJH) end
            if sp then
                button._gmTimerDef = button._gmTimerDef or {}
                RC.UI:AnchorOver(ct, sp, button._gmTimerDef, "CENTER", to, "CENTER", 0, 0, ButtonTo(button))
            end
            button._gmTimerMoved = sp ~= nil
        end
    end
    if button.nameText then
        local nt = button.nameText
        RC:ApplyFontSpec(nt, look.nameFont, GM.NAME_FONT)
        local _, size = RC:ResolveFontSpec(look.nameFont, GM.NAME_FONT)
        nt:SetHeight(math.max(10, (size or 8) + 2))
        nt:SetWidth(self:NameWidth(button) + 2)
        local p = NAME_POINTS[look.namePos or "bottom"] or NAME_POINTS.bottom
        nt:ClearAllPoints()
        nt:SetPoint(p[1], p[2], p[3])
        nt:SetJustifyV(p[4])
        local anc = TextAnchors()
        local sp = anc and anc.name or nil
        if sp and not button._gmNameMoved then button._gmNameJH = nt:GetJustifyH() end
        if button._gmNameMoved and button._gmNameJH then nt:SetJustifyH(button._gmNameJH) end
        if sp then
            button._gmNameDef = button._gmNameDef or {}
            RC.UI:AnchorOver(nt, sp, button._gmNameDef, p[1], nt:GetParent(), p[1], p[2], p[3], ButtonTo(button))
        end
        button._gmNameMoved = sp ~= nil
        local c = self:LookColor("nameColor", "text", "white")
        nt:SetTextColor(c.r, c.g, c.b, c.a or 1)
    end
end

-- The parts of a gear button (or a hover-menu tile, or a preview sample):
-- icon, black backing, cooldown swipe and number, the two rings, the
-- docking glow, the hover lift, the queued-next badge and the name.
-- name: the global name prefix for a real button; nil for a sample.
function GM:BuildButtonFace(button, buttonName)
    local function N(suffix) return buttonName and (buttonName .. suffix) or nil end

    local iconBg = button:CreateTexture(N("IconBg"), "BACKGROUND", nil, -8)
    iconBg:SetAllPoints(button)
    iconBg:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
    button.iconBg = iconBg

    -- The border rides inside the button's own rect, so the black edge
    -- costs no extra space no matter how buttons are docked.
    button.borderWidth = 1

    local icon = button:CreateTexture(N("Icon"), "BACKGROUND")
    icon:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
    icon:SetDesaturated(false)
    icon:SetVertexColor(1, 1, 1, 1)
    button.icon = icon

    -- the outgoing icon of a swap, on its own frame so the swap
    -- animation can move and scale it (made here, out of combat)
    local ghost = CreateFrame("Frame", nil, button)
    ghost:SetPoint("TOPLEFT", icon, "TOPLEFT", 0, 0)
    ghost:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0)
    ghost:SetFrameLevel(button:GetFrameLevel() + 1)
    ghost.tex = ghost:CreateTexture(nil, "ARTWORK")
    ghost.tex:SetAllPoints()
    ghost:Hide()
    button.swapGhost = ghost

    local cooldownFrame = CreateFrame("Cooldown", N("Cooldown"), button, "CooldownFrameTemplate")
    cooldownFrame:SetAllPoints(icon)
    cooldownFrame:SetDrawEdge(false)
    cooldownFrame:SetDrawSwipe(true)
    cooldownFrame:SetSwipeColor(0, 0, 0, 0.7)
    cooldownFrame:SetHideCountdownNumbers(true)
    cooldownFrame:SetFrameLevel(button:GetFrameLevel() + 2)
    button.cooldownFrame = cooldownFrame

    -- Both rings are the same 1px four-texture edge the core helper
    -- builds; the explicit sublevels keep the hover ring above the base
    -- ring, exactly as the hand-rolled versions did.
    button.borders = RC.UI:CreateSimpleBorder(button, 1, 0)

    local hoverBorder = RC.UI:CreateSimpleBorder(button, 1, 2)
    for _, side in pairs(hoverBorder) do
        side:Hide()
    end
    button.hoverBorder = hoverBorder

    local dockGlow = button:CreateTexture(nil, "ARTWORK")
    dockGlow:SetAllPoints()
    dockGlow:SetColorTexture(C.yellowHint[1], C.yellowHint[2], C.yellowHint[3], C.yellowHint[4])
    dockGlow:Hide()
    button.dockGlow = dockGlow

    local hoverHighlight = button:CreateTexture(nil, "ARTWORK", nil, 7)
    hoverHighlight:SetAllPoints()
    hoverHighlight:SetColorTexture(C.whiteHint[1], C.whiteHint[2], C.whiteHint[3], C.whiteHint[4])
    hoverHighlight:SetBlendMode("ADD")
    hoverHighlight:Hide()
    button.hoverHighlight = hoverHighlight

    local cdTextFrame = CreateFrame("Frame", N("CooldownText"), button)
    cdTextFrame:SetAllPoints(button)
    -- a preview sample keeps its canvas's strata
    cdTextFrame:SetFrameStrata(buttonName and "HIGH" or button:GetFrameStrata())
    cdTextFrame:SetFrameLevel(button:GetFrameLevel() + 20)

    local cdText = cdTextFrame:CreateFontString(N("Time"), "OVERLAY")
    cdText:SetPoint("CENTER", cdTextFrame, "CENTER", 0, 0)
    cdText:SetTextColor(1, 1, 0, 1)
    cdText:SetDrawLayer("OVERLAY", 7)
    cdText:SetShadowOffset(2, -2)
    cdText:SetShadowColor(0, 0, 0, 1)
    cdText:Hide()
    button.cdText = cdText
    button.cdTextFrame = cdTextFrame
    cdTextFrame:Show()

    button.queueIndicator = _gms.AttachQueueIndicator(button, N("QueueIndicator"), 16, 14, 25)
    self:FitQueueIndicator(button)

    -- on its own frame at the cooldown number's level, so it draws over
    -- the queued-next badge (a child frame) instead of under it; not on
    -- the cooldown frame itself, which hides when cooldown text is off
    local nameFrame = CreateFrame("Frame", nil, button)
    nameFrame:SetAllPoints(button)
    nameFrame:SetFrameStrata(buttonName and "HIGH" or button:GetFrameStrata())
    nameFrame:SetFrameLevel(button:GetFrameLevel() + 20)
    local nameText = RC:CreateFontString(nameFrame, "OVERLAY", nil, 8)
    nameText:SetPoint("BOTTOM", 0, 2)
    nameText:SetWidth(34)
    nameText:SetHeight(10)
    nameText:SetTextColor(1, 1, 1, 1)
    nameText:SetJustifyH("CENTER")
    nameText:SetJustifyV("BOTTOM")
    nameText:SetWordWrap(false)
    nameText:SetShadowOffset(1, -1)
    nameText:SetShadowColor(0, 0, 0, 1)
    nameText:Hide()
    button.nameText = nameText

    self:StyleButtonFace(button)
    return button
end

-- Every live button and menu tile after a look change.
-- layer / fade / edge of a gear button (Gear manager settings; nothing
-- set = the button as it always was). Secure buttons: the layer waits for
-- the end of combat (ApplyFramePosition refuses under lockdown), the fade
-- is alpha only.
function GM:ApplyButtonCustom(b)
    if b and RC.ApplyFrameCustom then
        RC:ApplyFrameCustom(b, function() return RC.db and RC.db.gearManager end,
            { scale = false, parts = { border = b.borders } })
    end
end

function GM:RestyleAllButtons()
    for _, b in pairs(self.buttons or {}) do
        self:StyleButtonFace(b)
        self:FitQueueIndicator(b)
        self:ApplyButtonCustom(b)
    end
    for _, b in pairs(self.menuButtons or {}) do self:StyleButtonFace(b) end
    if self.menuFrame and self.StyleMenuFrame then self:StyleMenuFrame(self.menuFrame) end
    if self.UpdateAllButtonIcons then self:UpdateAllButtonIcons() end
    if self.ScheduleGearSetStatusRefresh then self:ScheduleGearSetStatusRefresh() end
    if self.UpdateButtonCooldowns then self:UpdateButtonCooldowns() end
end

function GM:CreateButton(slot)
    self:DebugPrint("CreateButton called for slot " .. tostring(slot))

    if self.settings and self.settings.buttonsLocked ~= nil then
        self.locked = self.settings.buttonsLocked
    end

    -- Valid ids: 0-19 (inventory slots), 999 (gear-set button), or any
    -- id >= 1000 with a pinned definition in RC.db.gearPinnedButtons.
    if not slot then
        self:DebugPrint("CreateButton rejected: slot is nil")
        return
    end

    if slot ~= 999 and not self:GetPinnedDef(slot) and (slot < 0 or slot > 19) then
        self:DebugPrint("CreateButton rejected: invalid slot " .. tostring(slot))
        return
    end

    -- Same defer-to-PLAYER_REGEN_ENABLED pattern as RemoveButton and
    -- RestoreButtonsFromProfile - creating SecureActionButtonTemplate
    -- buttons is protected under combat lockdown.
    if InCombatLockdown() then
        self:DebugPrint("CreateButton deferred for slot " .. slot .. " - in combat lockdown")
        if not self.pendingCreateButtons then
            self.pendingCreateButtons = {}
            local frame = CreateFrame("Frame")
            frame:RegisterEvent("PLAYER_REGEN_ENABLED")
            frame:SetScript("OnEvent", function(f)
                f:UnregisterAllEvents()
                local pending = self.pendingCreateButtons
                self.pendingCreateButtons = nil
                for _, pendingSlot in ipairs(pending) do
                    self:CreateButton(pendingSlot)
                end
            end)
        end
        table.insert(self.pendingCreateButtons, slot)
        return
    end

    if self.buttons[slot] then
        self:DebugPrint("Button " .. slot .. " already exists, showing it")
        self.buttons[slot]:Show()
        self:UpdateButtonIcon(slot)
        return
    end

    self:DebugPrint("Creating new button for slot " .. slot)

    local buttonName = "WRGearButton" .. slot
    local btnSz = self:GetButtonUnitSize()

    local button = CreateFrame("Button", buttonName, UIParent, "SecureActionButtonTemplate")
    button:SetSize(btnSz, btnSz)
    button:SetID(slot)
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    button:RegisterForClicks("LeftButtonDown", "LeftButtonUp", "RightButtonDown", "RightButtonUp")
    -- shift-type*/alt-type* are custom secure action types consumed by
    -- RC's secure click handler (defined outside this file), not built-in
    -- Blizzard action types.
    if GM.settings and GM.settings.shiftCancelQueue ~= false then
        button:SetAttribute("shift-type1", "cancelqueue")
        button:SetAttribute("shift-type2", "cancelqueue")
    end
    button:SetAttribute("alt-type1", "lockbtn")
    button:SetAttribute("alt-type2", "lockbtn")

    if slot ~= 999 and not self:GetPinnedDef(slot) then
        self:UpdateButtonUseAction(slot, button)
    end

    self:BuildButtonFace(button, buttonName)
    local icon = button.icon
    local nameText = button.nameText

    if slot == 999 then
        local currentSet = self:GetCurrentEquippedSet()
        if currentSet and self.sets[currentSet] and self.sets[currentSet].icon then
            icon:SetTexture(self.sets[currentSet].icon)
        else
            icon:SetTexture("Interface\\Icons\\INV_Chest_Plate16")
        end
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    elseif self:GetPinnedDef(slot) then
        local def = self:GetPinnedDef(slot)
        if def.kind == "set" then
            local s = self.sets and self.sets[def.set]
            icon:SetTexture((s and s.icon) or "Interface\\Icons\\INV_Chest_Plate16")
        else
            icon:SetTexture(def.texture or GetItemIcon(def.itemId) or "Interface\\Icons\\INV_Misc_QuestionMark")
        end
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        icon:SetTexture(self:GetSlotTexture(slot))
    end

    if slot == 999 then
        local currentSet = self:GetCurrentEquippedSet()
        if currentSet and self.settings.showGearSetName ~= false then
            TruncateToWidth(nameText, currentSet, self:NameWidth(button))
            nameText:Show()
        end
    elseif self:GetPinnedDef(slot) then
        local def = self:GetPinnedDef(slot)
        local label = (def.kind == "set") and def.set or def.name
        if label and self.settings.showGearSetName ~= false then
            TruncateToWidth(nameText, label, self:NameWidth(button))
            nameText:Show()
        end
    end

    -- Core's drawn-X button: size 14 gives the same 7x2 bars this used to
    -- build by hand, and the normal/hover colours now come from the theme
    -- (buttons.xNormal / buttons.closeHover) instead of local literals.
    -- The CancelHideTimer side effect is hooked back on.
    local closeBtn = RC.UI:CreateXCloseButton(button, 14, function()
        GM:HideMenu()
        GM:RemoveButton(slot)
    end)
    closeBtn:SetPoint("TOPRIGHT", 0, 0)
    closeBtn:SetFrameLevel(button:GetFrameLevel() + 10)
    closeBtn:HookScript("OnEnter", function()
        GM:CancelHideTimer()
    end)

    closeBtn:Hide()
    button.closeBtn = closeBtn

    local lockBtn = CreateFrame("Button", nil, button)
    lockBtn:SetSize(10, 10)
    lockBtn:SetPoint("TOPRIGHT", button, "TOPRIGHT", -14, -2)
    lockBtn:SetFrameLevel(button:GetFrameLevel() + 10)
    lockBtn:EnableMouse(true)

    local lockBody = lockBtn:CreateTexture(nil, "ARTWORK")
    lockBody:SetSize(6, 4)
    lockBody:SetPoint("BOTTOM", lockBtn, "BOTTOM", 0, 0)
    lockBody:SetColorTexture(C.lightGray[1], C.lightGray[2], C.lightGray[3], C.lightGray[4])
    lockBtn.body = lockBody

    local shackleLeft = lockBtn:CreateTexture(nil, "ARTWORK")
    shackleLeft:SetSize(1, 3)
    shackleLeft:SetPoint("BOTTOMLEFT", lockBody, "TOPLEFT", 1, 0)
    shackleLeft:SetColorTexture(C.lightGray[1], C.lightGray[2], C.lightGray[3], C.lightGray[4])
    lockBtn.shackleLeft = shackleLeft

    local shackleRight = lockBtn:CreateTexture(nil, "ARTWORK")
    shackleRight:SetSize(1, 3)
    shackleRight:SetPoint("BOTTOMRIGHT", lockBody, "TOPRIGHT", -1, 0)
    shackleRight:SetColorTexture(C.lightGray[1], C.lightGray[2], C.lightGray[3], C.lightGray[4])
    lockBtn.shackleRight = shackleRight

    local shackleTop = lockBtn:CreateTexture(nil, "ARTWORK")
    shackleTop:SetSize(2, 1)
    shackleTop:SetPoint("BOTTOM", shackleLeft, "TOP", 1, 0)
    shackleTop:SetColorTexture(C.lightGray[1], C.lightGray[2], C.lightGray[3], C.lightGray[4])
    lockBtn.shackleTop = shackleTop

    lockBtn:SetScript("OnEnter", function(self)
        self.body:SetColorTexture(C.green[1], C.green[2], C.green[3], C.green[4])
        self.shackleLeft:SetColorTexture(C.green[1], C.green[2], C.green[3], C.green[4])
        self.shackleRight:SetColorTexture(C.green[1], C.green[2], C.green[3], C.green[4])
        self.shackleTop:SetColorTexture(C.green[1], C.green[2], C.green[3], C.green[4])
        GM:CancelHideTimer()
    end)

    lockBtn:SetScript("OnLeave", function(self)
        self.body:SetColorTexture(C.lightGray[1], C.lightGray[2], C.lightGray[3], C.lightGray[4])
        self.shackleLeft:SetColorTexture(C.lightGray[1], C.lightGray[2], C.lightGray[3], C.lightGray[4])
        self.shackleRight:SetColorTexture(C.lightGray[1], C.lightGray[2], C.lightGray[3], C.lightGray[4])
        self.shackleTop:SetColorTexture(C.lightGray[1], C.lightGray[2], C.lightGray[3], C.lightGray[4])
    end)

    lockBtn:SetScript("OnClick", function()
        GM:Lock()
    end)

    if self.locked or self.settings.buttonsLocked then
        lockBtn:Hide()
        closeBtn:Hide()
    else
        lockBtn:Show()
        closeBtn:Show()
    end

    button.lockIcon = lockBtn

    self.buttons[slot] = button
    self.buttonData[slot] = {
        slot = slot,
        locked = self.locked or self.settings.buttonsLocked or false,
        dockTo = nil,
        dockSide = nil
    }

    button:SetScript("OnEnter", function(self)
        local slot = self:GetID()

        self.isHovered = true

        if self.hoverHighlight then
            self.hoverHighlight:Show()
        end

        if self.hoverBorder then
            self.hoverBorder.top:Show()
            self.hoverBorder.bottom:Show()
            self.hoverBorder.left:Show()
            self.hoverBorder.right:Show()
        end

        GM:CancelHideTimer()

        if GM.menuShowTimer then
            GM.menuShowTimer:Cancel()
            GM.menuShowTimer = nil
        end

        local overCloseBtn = self.closeBtn and self.closeBtn:IsShown() and self.closeBtn:IsMouseOver()

        if overCloseBtn then
            return
        end

        if GM:TooltipsAllowed() then
            GM:AnchorTooltip(self)

            if slot == 999 then
                GameTooltip:SetText(RCL["Gear Sets"], 1, 1, 1)
                GameTooltip:AddLine(RCL["Hover to show all your gear sets"], 1, 1, 1)
            elseif GM:GetPinnedDef(slot) then
                local def = GM:GetPinnedDef(slot)
                if def.kind == "set" then
                    GameTooltip:SetText(RCL["Gear Set: "]
                        .. (RC.GetGearSetIconText and (RC:GetGearSetIconText(def.set, 14) .. " ") or "")
                        .. tostring(def.set), 1, 1, 1)
                    GameTooltip:AddLine(RCL["Left-click: Equip this set"], 0.8, 0.8, 0.8)
                else
                    if def.itemId then
                        GameTooltip:SetItemByID(def.itemId)
                    else
                        GameTooltip:SetText(def.name or RCL["Pinned Item"], 1, 1, 1)
                    end
                    GameTooltip:AddLine(RCL["Left-click: Equip this item"], 0.8, 0.8, 0.8)
                end
                GameTooltip:AddLine(RCL["Unlock and click the X to remove"], 0.6, 0.6, 0.6)
            else
                local slotName = GM.slotInfo[slot] and GM.slotInfo[slot].real or "Unknown Slot"
                GameTooltip:SetText(slotName, 1, 1, 1)

                local equippedLink = (GM.remoteEquippedBySlot and GM.remoteEquippedBySlot[slot] and GM.remoteEquippedBySlot[slot].link)
                                  or GetInventoryItemLink("player", slot)
                if equippedLink then
                    GameTooltip:SetHyperlink(equippedLink)
                else
                    GameTooltip:AddLine(RCL["No item equipped"], 0.7, 0.7, 0.7)
                end
            end
            GameTooltip:Show()
        end

        if GM:GetPinnedDef(slot) then return end

        if GM.menuFrame and GM.menuFrame:IsShown() then
            if GM.currentMenuSlot ~= slot then
                GM:ShowMenu(slot, self)
            end
        else
            GM.menuShowTimer = C_Timer.NewTimer(0.08, function()
                GM.menuShowTimer = nil
                if self.isHovered then
                    local stillOverClose = self.closeBtn and self.closeBtn:IsShown() and self.closeBtn:IsMouseOver()
                    if not stillOverClose then
                        GM:ShowMenu(slot, self)
                    end
                end
            end)
        end
    end)

    button:SetScript("OnLeave", function(self)
        local slot = self:GetID()

        self.isHovered = false

        if GM.menuShowTimer then
            GM.menuShowTimer:Cancel()
            GM.menuShowTimer = nil
        end

        if self.hoverHighlight then
            self.hoverHighlight:Hide()
        end

        if self.hoverBorder then
            self.hoverBorder.top:Hide()
            self.hoverBorder.bottom:Hide()
            self.hoverBorder.left:Hide()
            self.hoverBorder.right:Hide()
        end

        -- Menu hiding is driven by the menu frame's own OnUpdate hover
        -- poll (GM_Menu.lua), not from here.
    end)

    if RC.AttachMouseoverFade and RC._GetGearManagerFadeSettings then
        RC:AttachMouseoverFade(button, RC._GetGearManagerFadeSettings)
    end

    button:SetScript("OnHide", function(self)
        if GM.currentMenuAnchor == self and GM.menuFrame and GM.menuFrame:IsShown() then
            GM:HideMenu()
        end
    end)

    button:SetScript("OnDragStart", function(self) GM:StartButtonDrag(self) end)
    button:SetScript("OnDragStop", function(self) GM:StopButtonDrag(self) end)

    button:SetScript("PostClick", function(self, btn, down)
        if down then return end
        local slot = self:GetID()

        -- Record which inventory slot this click just used the item from.
        -- Two worn items can share one on-use spell (Barbaric Belt and
        -- Fire Hardened Hauberk both cast 9174), and the swap-back watcher
        -- in GM_Runtime otherwise has only the cooldown to tell them
        -- apart; a click is definitive, so hand it the answer.
        if not IsShiftKeyDown() and not IsAltKeyDown() then
            local info = GM.slotInfo and GM.slotInfo[slot]
            if info and info.invSlot and info.invSlot > 0
                    and GetInventoryItemID("player", info.invSlot) then
                RC.lastGearUseSlot = info.invSlot
                RC.lastGearUseTime = GetTime()
            end
        end

        if (btn == "LeftButton" or btn == "RightButton") and IsShiftKeyDown()
                and GM.settings and GM.settings.shiftCancelQueue ~= false then
            GM:DebugPrint("Shift-cancel invoked for slot " .. tostring(slot), "gear")
            local q = RC.gearSwapQueue
            if slot == 999 then
                local names
                if q then
                    for i = #q, 1, -1 do
                        if type(q[i]) == "string" then
                            names = names or {}
                            names[#names + 1] = q[i]
                            table.remove(q, i)
                        end
                    end
                end
                if names then
                    GM:Print(RCL["Cancelled queued gear set: "]
                        .. table.concat(names, ", ") .. ".")
                    if GM.queuedSetSlotExclusions then
                        for _, nm in ipairs(names) do
                            GM.queuedSetSlotExclusions[nm] = nil
                        end
                    end
                    GM:UpdateQueueIndicators()
                else
                    GM:Print(RCL["No queued gear set."])
                end
                return
            end
            local removed = RC.CancelQueuedSwapsForSlot
                and RC:CancelQueuedSwapsForSlot(slot) or 0
            if removed > 0 then
                GM:Print(RCL["Cancelled "] .. removed .. RCL[" queued swap(s) for that slot."])
                GM:UpdateQueueIndicators()
            else
                local covered
                if q then
                    for i = 1, #q do
                        local e = q[i]
                        if type(e) == "string" then
                            local gs = GM.sets and GM.sets[e]
                            if gs and gs.equip and gs.equip[slot] and gs.equip[slot] ~= 0 then
                                covered = e
                                break
                            end
                        end
                    end
                end
                if covered then
                    GM.queuedSetSlotExclusions = GM.queuedSetSlotExclusions or {}
                    local ex = GM.queuedSetSlotExclusions[covered]
                    if not ex then
                        ex = {}
                        GM.queuedSetSlotExclusions[covered] = ex
                    end
                    local slotName = (GM.slotData and GM.slotData[slot]
                        and GM.slotData[slot].real) or ("slot " .. slot)
                    if ex[slot] then
                        ex[slot] = nil
                        GM:Print(RCL["Restored "] .. slotName .. RCL[" to queued set '"]
                            .. covered .. "'.")
                    else
                        ex[slot] = true
                        GM:Print(RCL["Removed "] .. slotName .. RCL[" from queued set '"]
                            .. covered .. RCL["' - that slot will stay as it is."])
                    end
                    GM:UpdateQueueIndicators()
                else
                    RC:DebugPrint("No queued swap for that slot.", "gear")
                end
            end
            return
        end

        if btn == "LeftButton" and IsAltKeyDown() then
            GM.buttonData[slot].locked = not GM.buttonData[slot].locked
            GM:SaveButtonLockState(slot)
            GM:DebugPrint((GM.buttonData[slot].locked and "Locked: " or "Unlocked: ")
                .. (GM.slotInfo[slot] and GM.slotInfo[slot].real or ("button " .. slot)))
        elseif (btn == "LeftButton" or btn == "RightButton")
               and not IsAltKeyDown() and GM:GetPinnedDef(slot) then
            GM:ClickPinned(slot)
        end
    end)

    self:LoadButtonPosition(slot)
    self:UpdateButtonIcon(slot)

    self:DebugPrint("About to show button for slot " .. slot)
    button:Show()
    self:DebugPrint("Button shown, should be visible now")

    self:MarkButtonActive(slot)
    self:ApplyButtonCustom(button)

    -- The status border lives on the frame, so a freshly created button
    -- has none. Only bag and equipment events used to schedule it, which
    -- left the gear set button unbordered from creation until the next
    -- one of those fired - and permanently after a remove/re-add, since
    -- that builds a brand new frame.
    if slot == 999 then
        self:ScheduleGearSetStatusRefresh()
    end

    self:DebugPrint("Created " .. (self.slotInfo[slot] and self.slotInfo[slot].real or ("pinned " .. slot)) .. " button")
end

function GM:GetPinnedDef(slot)
    if type(slot) ~= "number" or slot < 1000 then return nil end
    return RC.db and RC.db.gearPinnedButtons and RC.db.gearPinnedButtons[slot] or nil
end

function GM:NextPinnedId()
    local defs = RC.db.gearPinnedButtons
    local id = 1000
    while defs[id] or self.buttons[id] do id = id + 1 end
    return id
end

function GM:PinSet(setName)
    if not setName or not (self.sets and self.sets[setName]) then return end
    if not RC.db.gearPinnedButtons then RC.db.gearPinnedButtons = {} end
    for _, def in pairs(RC.db.gearPinnedButtons) do
        if def.kind == "set" and def.set == setName then
            self:Print(RCL["Set is already pinned: "] .. setName)
            return
        end
    end
    local id = self:NextPinnedId()
    RC.db.gearPinnedButtons[id] = { kind = "set", set = setName }
    self:CreateButton(id)
    self:Print(RCL["Pinned set: "] .. setName .. RCL[" - unlock and click its X to remove"])
end

function GM:PinItem(itemLink, invSlot)
    local itemId = self:GetItemID(itemLink)
    if not itemId then return end
    if not RC.db.gearPinnedButtons then RC.db.gearPinnedButtons = {} end
    for _, def in pairs(RC.db.gearPinnedButtons) do
        if def.kind == "item" and def.itemId == itemId and def.invSlot == invSlot then
            self:Print(RCL["Item is already pinned"])
            return
        end
    end
    local name = GetItemInfo(itemLink)
    local id = self:NextPinnedId()
    RC.db.gearPinnedButtons[id] = {
        kind = "item", itemId = itemId, invSlot = invSlot,
        name = name, texture = GetItemIcon(itemId),
    }
    self:CreateButton(id)
    self:Print(RCL["Pinned item: "] .. (name or itemId) .. RCL[" - unlock and click its X to remove"])
end

function GM:ClickPinned(slot)
    local def = self:GetPinnedDef(slot)
    if not def then return end

    if def.kind == "set" then
        if not (self.sets and self.sets[def.set]) then
            self:Print(RCL["Pinned set no longer exists: "] .. tostring(def.set))
            return
        end
        if InCombatLockdown() then
            if RC and RC.QueueGearSwap then
                RC:QueueGearSwap(def.set)
            else
                self:Print(RCL["Cannot equip sets in combat"])
            end
            return
        end
        self:EquipSet(def.set)

    elseif def.kind == "item" then
        local invSlot = def.invSlot or 16
        if GetInventoryItemID("player", invSlot) == def.itemId then
            self:Print((def.name or "Item") .. RCL[" is already equipped"])
            return
        end
        for bag = 0, 4 do
            local numSlots = C_Container.GetContainerNumSlots(bag) or 0
            for bagSlot = 1, numSlots do
                if C_Container.GetContainerItemID(bag, bagSlot) == def.itemId then
                    local link = C_Container.GetContainerItemLink(bag, bagSlot)
                    self:SafeSwapBagToSlot(bag, bagSlot, invSlot, link)
                    return
                end
            end
        end
        self:Print((def.name or ("Item " .. def.itemId)) .. RCL[" is not in your bags"])
    end
end

function GM:RemoveButton(slot)
    if not self.buttons[slot] then return end

    -- Same guarded single-frame deferral as pendingCreateButtons above:
    -- one event frame is reused for the whole batch instead of leaking a
    -- fresh (never garbage-collected) frame per blocked call.
    if InCombatLockdown() then
        self:DebugPrint("RemoveButton deferred for slot " .. slot .. " - in combat lockdown")
        if not self.pendingRemoveButtons then
            self.pendingRemoveButtons = {}
            local frame = self._removeCombatFrame
            if not frame then
                frame = CreateFrame("Frame")
                self._removeCombatFrame = frame
            end
            frame:RegisterEvent("PLAYER_REGEN_ENABLED")
            frame:SetScript("OnEvent", function(f)
                f:UnregisterAllEvents()
                local pending = self.pendingRemoveButtons
                self.pendingRemoveButtons = nil
                if pending then
                    for _, pendingSlot in ipairs(pending) do
                        self:RemoveButton(pendingSlot)
                    end
                end
            end)
        end
        local seen = false
        for _, pendingSlot in ipairs(self.pendingRemoveButtons) do
            if pendingSlot == slot then seen = true; break end
        end
        if not seen then
            table.insert(self.pendingRemoveButtons, slot)
        end
        return
    end

    self:DetachDockChildren(slot)

    local button = self.buttons[slot]
    button:Hide()
    button:SetParent(nil)

    self.buttons[slot] = nil
    self.buttonData[slot] = nil

    if RC.db and RC.db.gearButtonPositions then
        RC.db.gearButtonPositions[slot] = nil
    end

    if RC.db and RC.db.gearButtons then
        RC.db.gearButtons[slot] = nil
    end

    if RC.db and RC.db.gearPinnedButtons then
        RC.db.gearPinnedButtons[slot] = nil
    end

    if RC.SaveConfigurationToProfile then
        RC:SaveConfigurationToProfile()
    end

    self:DebugPrint("Removed " .. (self.slotInfo[slot] and self.slotInfo[slot].real or ("button " .. slot)) .. " button")
end

function GM:MarkButtonActive(slot)
    if not RC.db then
        self:Print(RCL["ERROR: WR.db is nil - cannot save button!"])
        return
    end
    if not RC.db.gearButtons then RC.db.gearButtons = {} end
    RC.db.gearButtons[slot] = true

    self:DebugPrint("Marked slot " .. slot .. " (" .. (self.slotInfo[slot] and self.slotInfo[slot].real or "pinned") .. ") as active in WR.db.gearButtons")

    if self._restoringButtons then return end

    if RC.SaveConfigurationToProfile then
        RC:SaveConfigurationToProfile()
        self:DebugPrint("Called SaveConfigurationToProfile for button " .. slot)
    else
        self:Print(RCL["ERROR: WR.SaveConfigurationToProfile is nil!"])
    end
end

-- ITEM CHANGE ANIMATION. A slot button used to cut straight from one
-- icon to the next. The outgoing icon is copied onto a ghost that sits
-- over the real one and leaves with the "When an item changes"
-- animation (look.swapAnim, RC.Motion; a fade by default), so the new
-- item shows under it. The outgoing item's cooldown swipe and countdown
-- fade out on the same clock, and the incoming item's cooldown eases in
-- afterwards (EaseCooldownIn, GM_Runtime.lua, reads _cdEaseUntil) - a
-- swapped-in trinket's 30s swipe used to snap fully dark over a
-- half-faded icon.
-- Must be called before the icon is repainted - it copies what is there.
local CD_EASE_WINDOW = 1.0

function GM:SwapAnimSpec()
    return RC.Motion.Normalize(self:Look().swapAnim, GM.SWAP_ANIM)
end

-- FadeFrame hides at alpha 0 and leaves it there; put it back so a later
-- plain Show() of the cooldown is not invisible.
local function FadeOutAndRestore(frame, dur)
    RC.UI:FadeFrame(frame, nil, 0, dur, "easeOutQuad", function()
        frame:SetAlpha(1)
    end)
end

-- the ghost part only: the preview plays this on its samples
function GM:PlaySwapGhost(button)
    local icon, ghost = button.icon, button.swapGhost
    if not (icon and ghost and RC.Motion) then return end
    ghost.tex:SetTexture(icon:GetTexture())
    ghost.tex:SetTexCoord(icon:GetTexCoord())
    ghost.tex:SetDesaturated(icon:IsDesaturated())
    ghost.tex:SetVertexColor(icon:GetVertexColor())
    RC.Motion.Stop(ghost)
    ghost:SetAlpha(1)
    ghost:Show()
    RC.Motion.Hide(ghost, self:SwapAnimSpec())
end

local function PlaySwapAnim(button)
    if not (RC.UI and RC.UI.FadeFrame) then return end
    GM:PlaySwapGhost(button)
    local dur = GM:SwapAnimSpec().duration
    if button.cooldownFrame and button.cooldownFrame:IsShown() then
        FadeOutAndRestore(button.cooldownFrame, dur)
    end
    if button.cdTextFrame and button.cdText and button.cdText:IsShown() then
        FadeOutAndRestore(button.cdTextFrame, dur)
    end
    button._cdEaseUntil = GetTime() + CD_EASE_WINDOW
end

function GM:UpdateButtonIcon(slot)
    if not self.buttons[slot] then return end

    local button = self.buttons[slot]
    local icon = button.icon

    if not icon then return end

    self:UpdateButtonUseAction(slot)

    if slot == 999 then
        local currentSet = self:GetCurrentEquippedSet()
        if currentSet and self.sets[currentSet] and self.sets[currentSet].icon then
            icon:SetTexture(self.sets[currentSet].icon)

            if button.nameText then
                if self.settings.showGearSetName ~= false then
                    TruncateToWidth(button.nameText, currentSet, self:NameWidth(button))
                    button.nameText:Show()
                else
                    button.nameText:Hide()
                end
            end
        else
            icon:SetTexture("Interface\\Icons\\INV_Chest_Plate16")

            if button.nameText then
                button.nameText:Hide()
            end
        end
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        if not self.enabled then
            icon:SetDesaturated(true)
            icon:SetVertexColor(0.5, 0.5, 0.5, 1)
        else
            icon:SetDesaturated(false)
            icon:SetVertexColor(1, 1, 1, 1)
        end
        return
    end

    local pinnedDef = self:GetPinnedDef(slot)
    if pinnedDef then
        if pinnedDef.kind == "set" then
            local s = self.sets and self.sets[pinnedDef.set]
            icon:SetTexture((s and s.icon) or "Interface\\Icons\\INV_Chest_Plate16")
        else
            icon:SetTexture(pinnedDef.texture or GetItemIcon(pinnedDef.itemId) or "Interface\\Icons\\INV_Misc_QuestionMark")
        end
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        if button.nameText then
            local label = (pinnedDef.kind == "set") and pinnedDef.set or pinnedDef.name
            if label and self.settings.showGearSetName ~= false then
                TruncateToWidth(button.nameText, label, self:NameWidth(button))
                button.nameText:Show()
            else
                button.nameText:Hide()
            end
        end
        if not self.enabled then
            icon:SetDesaturated(true)
            icon:SetVertexColor(0.5, 0.5, 0.5, 1)
        else
            icon:SetDesaturated(false)
            icon:SetVertexColor(1, 1, 1, 1)
        end
        return
    end

    local texture = GetInventoryItemTexture("player", slot)
    local itemLink = GetInventoryItemLink("player", slot)

    -- A swap just asked for (GM:PredictSlotItem, GM_Base.lua) is shown
    -- until the slot really holds it or the hold runs out. Without the
    -- hold a refresh landing before the server answered would flip the
    -- button back to the old item and then forward again.
    local shownID = GetInventoryItemID("player", slot) or false
    local pred = button._predicted
    if pred then
        if shownID == pred.id or GetTime() >= pred.expires then
            button._predicted = nil
        else
            texture, itemLink, shownID = pred.texture, pred.link, pred.id
        end
    end

    -- Only a change of item animates: not the first paint, not a repaint
    -- of the same item, and not a prediction turning into the real thing
    -- (same id, so the fade is not played twice for one swap).
    if button._shownID ~= nil and button._shownID ~= shownID
       and not self._restoringButtons and button:IsVisible() then
        PlaySwapAnim(button)
    end
    button._shownID = shownID

    if texture then
        icon:SetTexture(texture)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        if button.nameText and self.settings.showButtonNames ~= false then
            local itemName = itemLink and GetItemInfo(itemLink)
            if itemName then
                local abbrevName = RC.GetItemAbbreviation and RC:GetItemAbbreviation(itemName) or itemName:sub(1, 5) .. "."
                button.nameText:SetText(abbrevName)
                button.nameText:Show()
            else
                button.nameText:Hide()
            end
        elseif button.nameText then
            button.nameText:Hide()
        end
    else
        local emptyTexture = RC:GetSlotEmptyTexture(self.slotInfo[slot].name)
        icon:SetTexture(emptyTexture or "Interface\\Icons\\INV_Misc_QuestionMark")
        icon:SetTexCoord(0.15, 0.85, 0.15, 0.85)

        if button.nameText then
            button.nameText:Hide()
        end

        icon:SetDesaturated(true)
        icon:SetVertexColor(0.6, 0.6, 0.6, 1)
        return
    end

    icon:SetDesaturated(false)
    icon:SetVertexColor(1, 1, 1, 1)
end

function GM:UpdateAllButtonIcons()
    for slot in pairs(self.buttons) do
        self:UpdateButtonIcon(slot)
    end
end

function GM:RefreshAllButtonFonts()

    for slot, button in pairs(self.buttons) do
        if button.cdText then
            button.cdText:SetShadowOffset(2, -2)
            button.cdText:SetShadowColor(0, 0, 0, 1)
        end
        if button.nameText then
            button.nameText:SetShadowOffset(1, -1)
            button.nameText:SetShadowColor(0, 0, 0, 1)
        end
    end

    for _, btn in pairs(self.menuButtons or {}) do
        if btn.cdText then
            btn.cdText:SetShadowOffset(2, -2)
            btn.cdText:SetShadowColor(0, 0, 0, 1)
        end
        if btn.nameText then
            btn.nameText:SetShadowOffset(1, -1)
            btn.nameText:SetShadowColor(0, 0, 0, 1)
        end
    end

    for i = 0, 19 do
        local slotInfo = self.slotInfo[i]
        if slotInfo then
            local slotFrame = _G["Character" .. slotInfo.name]
            if slotFrame and slotFrame.itemNameText then
                slotFrame.itemNameText:SetShadowOffset(1, -1)
                slotFrame.itemNameText:SetShadowColor(0, 0, 0, 1)
            end
        end
    end

    self:DebugPrint("Refreshed shadows on all button fonts")
end

-- ===== ITEMRACK IMPORT =====
-- Reconstructs GM_Sets.lua's set.equip schema from ItemRack's raw item ids:
-- explicit 0 stays 0 (unequip), a real id becomes a resolved item link, and
-- any slot ItemRack simply never wrote is left absent (leave slot alone).
function GM:ImportItemRackSets()
    local src = _G.ItemRackUser and _G.ItemRackUser.Sets
    if type(src) ~= "table" then
        RC:Print(RCL["ItemRack data not found. ItemRack must be enabled while importing (its saved sets only load with the addon). Import once, then ItemRack can be disabled."])
        return 0
    end
    local imported, renamed, skipped = 0, 0, 0
    for name, setData in pairs(src) do
        if type(name) == "string" and name:sub(1, 1) ~= "~"
                and type(setData) == "table" and type(setData.equip) == "table" then
            local target = name
            if self.sets[target] then
                target = name .. " (ItemRack)"
            end
            if self.sets[target] then
                skipped = skipped + 1
            else
                local gear = {
                    equip = {},
                    icon = setData.icon or "Interface\\Icons\\INV_Misc_QuestionMark",
                }
                for slot, v in pairs(setData.equip) do
                    slot = tonumber(slot)
                    if slot and slot >= 0 and slot <= 19 then
                        if v == 0 or v == "0" then
                            gear.equip[slot] = 0
                        else
                            local id = tonumber(v) or tonumber(tostring(v):match("^(%d+)"))
                            if id and id > 0 then
                                local link = select(2, GetItemInfo(id))
                                gear.equip[slot] = link or ("item:" .. id)
                            end
                        end
                    end
                end
                if next(gear.equip) then
                    self.sets[target] = gear
                    imported = imported + 1
                    if target ~= name then renamed = renamed + 1 end
                else
                    skipped = skipped + 1
                end
            end
        end
    end
    if imported > 0 then
        RC:SaveConfigurationToProfile()
    end
    RC:Print(RCL["ItemRack import: "] .. imported .. RCL[" set(s) imported"]
        .. (renamed > 0 and (", " .. renamed .. " kept with an (ItemRack) suffix because the name was taken") or "")
        .. (skipped > 0 and (", " .. skipped .. " skipped") or "") .. ".")
    return imported
end

local _WRm = _G.Readycheck
if _WRm then
    _WRm._buildMarks = _WRm._buildMarks or {}
    _WRm._buildMarks["gm_buttons"] = "dragstop-gate"
end
