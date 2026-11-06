local AddonName = "Readycheck"
local RC = _G[AddonName]

if not RC then
    error("Readycheck core not found!")
end

local pairs, ipairs = pairs, ipairs
local math_abs = math.abs
local tinsert = table.insert
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local IsShiftKeyDown = IsShiftKeyDown
local C_Timer = C_Timer
local GM = RC.GearManager
local P = RC.Position

------------------------------------------------------------------------
-- Readycheck - Gear Manager Button Positioning
-- Drag and drop, docking buttons to each other, and saving/loading
-- positions.
--
-- GM.buttonData[slot] = { locked, dockTo, dockSide }. dockSide is the
-- side of the PARENT the child sits on. A group is one root button
-- (anchored to the screen) with a tree of children anchored to each
-- other. Only the root has a position of its own; positions are saved
-- on drop and never rewritten automatically.
------------------------------------------------------------------------

local DOCK_RANGE  = 20   -- an edge within this many units docks
local ALIGN_SLOP  = 5    -- edges this far out of line still count as a row/column
local GLOW_PERIOD = 0.1  -- dock-glow poll while dragging

local OPPOSITE = { LEFT = "RIGHT", RIGHT = "LEFT", TOP = "BOTTOM", BOTTOM = "TOP" }

function GM:GetButtonUnitSize()
    return (self.settings and self.settings.buttonSize) or 36
end

-- Saved data ----------------------------------------------------------

local function Positions()
    if not RC.db then return nil end
    RC.db.gearButtonPositions = RC.db.gearButtonPositions or {}
    return RC.db.gearButtonPositions
end

local function Persist()
    if GM._restoringButtons then return end
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
end

local function WritePosition(slot)
    local pos = Positions()
    local data = GM.buttonData[slot]
    local button = GM.buttons[slot]
    if not pos or not data or not button then return end
    local x, y = P.Capture(button, "CENTER")
    pos[slot] = {
        point = "CENTER", x = x or 0, y = y or 0, centred = true,
        locked = data.locked or false,
        dockTo = data.dockTo,
        dockSide = data.dockSide,
    }
end

local function WriteAll(slots)
    for _, s in ipairs(slots) do WritePosition(s) end
    Persist()
end

function GM:SaveButtonPosition(slot)
    WriteAll({ slot })
end

function GM:SaveDockGroup(root)
    WriteAll(self:CollectDockGroup(root))
end

function GM:SaveButtonLockState(slot)
    local pos = Positions()
    local data = self.buttonData[slot]
    if not pos or not data then return end
    if not pos[slot] then return self:SaveButtonPosition(slot) end
    pos[slot].locked = data.locked or false
    Persist()
end

-- Dock tree -----------------------------------------------------------

function GM:GetDockRoot(slot)
    local data = self.buttonData
    local seen = {}
    while data[slot] and data[slot].dockTo and data[data[slot].dockTo] and not seen[slot] do
        seen[slot] = true
        slot = data[slot].dockTo
    end
    return slot
end
GM.FindParentButton = GM.GetDockRoot

-- Root followed by every button in its subtree, parents before children.
function GM:CollectDockGroup(root)
    local list, seen = { root }, { [root] = true }
    local i = 1
    while i <= #list do
        for s, d in pairs(self.buttonData) do
            if d.dockTo == list[i] and not seen[s] then
                seen[s] = true
                tinsert(list, s)
            end
        end
        i = i + 1
    end
    return list
end

function GM:AddDockedChildren(parentSlot, list)
    local grp = self:CollectDockGroup(parentSlot)
    for i = 2, #grp do tinsert(list, grp[i]) end
end

-- Anchors `slot` to `targetSlot` on `side` of the target. Refuses links
-- that would form a cycle.
function GM:ApplyDocking(slot, targetSlot, side)
    local button, target = self.buttons[slot], self.buttons[targetSlot]
    local data = self.buttonData[slot]
    if not button or not target or not data or slot == targetSlot or not OPPOSITE[side] then
        return false
    end
    for _, s in ipairs(self:CollectDockGroup(slot)) do
        if s == targetSlot then return false end
    end

    local gap = (self.settings and self.settings.buttonSpacing) or 0
    button:ClearAllPoints()
    if side == "RIGHT" then
        button:SetPoint("LEFT", target, "RIGHT", gap, 0)
    elseif side == "LEFT" then
        button:SetPoint("RIGHT", target, "LEFT", -gap, 0)
    elseif side == "TOP" then
        button:SetPoint("BOTTOM", target, "TOP", 0, gap)
    else
        button:SetPoint("TOP", target, "BOTTOM", 0, -gap)
    end

    data.dockTo, data.dockSide = targetSlot, side
    if button.dockGlow then button.dockGlow:Hide() end
    return true
end

function GM:RefreshDockGaps()
    if InCombatLockdown() then return end
    for s, d in pairs(self.buttonData) do
        if d.dockTo then self:ApplyDocking(s, d.dockTo, d.dockSide) end
    end
end

-- Makes `slot` the root of its group by flipping the parent links on
-- the path to the old root (same picture on screen). Returns the path,
-- in the order anchors must be re-applied.
local function Reroot(slot)
    local data = GM.buttonData
    local path = { slot }
    local cur, parent, side = slot, data[slot].dockTo, data[slot].dockSide
    data[slot].dockTo, data[slot].dockSide = nil, nil
    while parent and data[parent] do
        local nextParent, nextSide = data[parent].dockTo, data[parent].dockSide
        data[parent].dockTo, data[parent].dockSide = cur, OPPOSITE[side]
        tinsert(path, parent)
        cur, parent, side = parent, nextParent, nextSide
    end
    return path
end

-- Placement ------------------------------------------------------------

function GM:PlaceButton(slot, x, y)
    local button = self.buttons[slot]
    if not button then return end
    P.Apply(button, x, y, "CENTER")
    if button.dockGlow then button.dockGlow:Hide() end
end

-- Cuts a button loose from its parent where it stands; its own children
-- stay attached.
function GM:Undock(slot)
    local data = self.buttonData[slot]
    local button = self.buttons[slot]
    if not data or not button then return end
    local x, y = P.Capture(button, "CENTER")
    data.dockTo, data.dockSide = nil, nil
    self:PlaceButton(slot, x, y)
end

-- Frees every direct child of `slot` before it is removed.
function GM:DetachDockChildren(slot)
    for s, d in pairs(self.buttonData) do
        if d.dockTo == slot then
            self:Undock(s)
            WritePosition(s)
        end
    end
end

function GM:LoadButtonPosition(slot)
    local button, data = self.buttons[slot], self.buttonData[slot]
    if not button or not data then return end

    local pos = Positions()
    local saved = pos and pos[slot]
    if not saved then return self:PlaceButton(slot, 0, 0) end

    if self.locked or (self.settings and self.settings.buttonsLocked) then
        data.locked = true
    else
        data.locked = saved.locked or false
    end

    if saved.dockTo and saved.dockSide and self:ApplyDocking(slot, saved.dockTo, saved.dockSide) then
        return
    end

    -- Parent gone: stand alone and drop the link.
    saved.dockTo, saved.dockSide = nil, nil
    data.dockTo, data.dockSide = nil, nil

    if saved.centred or (saved.point or "CENTER") == "CENTER" then
        return self:PlaceButton(slot, saved.x, saved.y)
    end

    -- Older save anchored to a screen corner: convert in place.
    local x, y = P.ApplyLegacy(button, saved.point, saved.point, saved.x, saved.y, "CENTER")
    if button.dockGlow then button.dockGlow:Hide() end
    if x then
        saved.point, saved.x, saved.y, saved.centred = "CENTER", x, y, true
        saved.edgeAnchored = nil
    end
end

-- Resizes every button (docked anchors are edge-based and follow).
function GM:ApplyButtonSize()
    if InCombatLockdown() then return end
    local size = self:GetButtonUnitSize()
    for _, button in pairs(self.buttons) do
        button:SetSize(size, size)
        self:FitQueueIndicator(button)
        self:StyleButtonFace(button)
    end
end

-- Drag and drop --------------------------------------------------------

-- Best dock for a group being moved together: any member may dock
-- against any visible button outside the group. Returns member, target,
-- side - or nil.
function GM:FindDockTarget(group)
    local inGroup = {}
    for _, s in ipairs(group) do inGroup[s] = true end

    -- Both ends of every existing link are spoken for.
    local taken = {}
    for s, d in pairs(self.buttonData) do
        if d.dockTo and d.dockSide and self.buttons[s] and self.buttons[d.dockTo] then
            taken[d.dockTo .. "_" .. d.dockSide] = true
            taken[s .. "_" .. OPPOSITE[d.dockSide]] = true
        end
    end

    local bestDist, bestMember, bestTarget, bestSide = DOCK_RANGE
    local function Consider(dist, m, t, side)
        if dist < bestDist and not taken[t .. "_" .. side] and not taken[m .. "_" .. OPPOSITE[side]] then
            bestDist, bestMember, bestTarget, bestSide = dist, m, t, side
        end
    end

    for _, m in ipairs(group) do
        local mb = self.buttons[m]
        local mL, mB, mW, mH
        if mb then mL, mB, mW, mH = mb:GetRect() end
        if mL then
            local mR, mT = mL + mW, mB + mH
            for t, tb in pairs(self.buttons) do
                if not inGroup[t] and tb:IsVisible() then
                    local tL, tB, tW, tH = tb:GetRect()
                    if tL then
                        local tR, tT = tL + tW, tB + tH
                        if mB < tT + ALIGN_SLOP and mT > tB - ALIGN_SLOP then
                            Consider(math_abs(mL - tR), m, t, "RIGHT")
                            Consider(math_abs(mR - tL), m, t, "LEFT")
                        end
                        if mL < tR + ALIGN_SLOP and mR > tL - ALIGN_SLOP then
                            Consider(math_abs(mB - tT), m, t, "TOP")
                            Consider(math_abs(mT - tB), m, t, "BOTTOM")
                        end
                    end
                end
            end
        end
    end

    return bestMember, bestTarget, bestSide
end

local function SetGlow(slot, shown)
    local b = slot and GM.buttons[slot]
    if not b or not b.dockGlow then return end
    if shown then
        b.dockGlow:SetAlpha(0.3)
        b.dockGlow:Show()
    else
        b.dockGlow:Hide()
    end
end

local function DragOnUpdate(button, elapsed)
    local drag = GM._drag
    if not drag then return button:SetScript("OnUpdate", nil) end
    drag.acc = drag.acc + elapsed
    if drag.acc < GLOW_PERIOD then return end
    drag.acc = 0

    local member = GM:FindDockTarget(drag.group)
    if member ~= drag.glowSlot then
        SetGlow(drag.glowSlot, false)
        SetGlow(member, true)
        drag.glowSlot = member
    end
end

-- Plain drag moves the whole group by its root; Shift-drag tears this
-- button (with anything docked to it) out of the group.
function GM:StartButtonDrag(button)
    local slot = button:GetID()
    local data = self.buttonData[slot]
    if not data then return end

    self._lastDragAttempt = {
        t = GetTime(), slot = slot,
        mover = RC._uiMoverActive and true or false,
        locked = data.locked and true or false,
    }

    if data.locked and not RC._uiMoverActive then return end
    if InCombatLockdown() then return end
    if self._drag then
        self._drag.mover:StopMovingOrSizing()
        SetGlow(self._drag.glowSlot, false)
        self._drag = nil
    end

    local root = slot
    if IsShiftKeyDown() then
        data.dockTo, data.dockSide = nil, nil
    else
        root = self:GetDockRoot(slot)
    end

    local mover = self.buttons[root] or button
    self._drag = { root = root, mover = mover, group = self:CollectDockGroup(root), acc = 0 }
    mover:StartMoving()
    button:SetScript("OnUpdate", DragOnUpdate)
end

function GM:StopButtonDrag(button)
    button:SetScript("OnUpdate", nil)
    local drag = self._drag
    if not drag then return end
    self._drag = nil

    drag.mover:StopMovingOrSizing()
    SetGlow(drag.glowSlot, false)
    -- Resolve next frame so the final rect has been committed.
    C_Timer.After(0, function() GM:FinishButtonDrop(drag) end)
end

function GM:FinishButtonDrop(drag)
    local group = drag.group
    for _, s in ipairs(group) do
        if not self.buttons[s] then return end
    end

    if not InCombatLockdown() then
        local member, target, side = self:FindDockTarget(group)
        if member then
            local path = Reroot(member)
            if self:ApplyDocking(member, target, side) then
                for i = 2, #path do
                    local d = self.buttonData[path[i]]
                    self:ApplyDocking(path[i], d.dockTo, d.dockSide)
                end
            else
                self:Undock(member)
            end
        end
    end

    WriteAll(group)
end
