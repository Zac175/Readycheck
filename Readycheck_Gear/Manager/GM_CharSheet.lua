local AddonName = "Readycheck"
local RC = _G[AddonName]

if not RC then
    error("Readycheck core not found!")
end

local pairs, ipairs, type = pairs, ipairs, type
local InCombatLockdown = InCombatLockdown
local GetInventoryItemLink = GetInventoryItemLink
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
local C_Container = C_Container
RC._gms = RC._gms or {}
local _gms = RC._gms
local GM = RC.GearManager
------------------------------------------------------------------------
-- Readycheck - Gear Manager Character Sheet Integration
-- Queue/name overlays on Blizzard's paper doll slots, the hover-to-open-
-- flyout hook on those slots, and the Alt+Click-on-a-paperdoll-slot
-- shortcut to create/remove a docked button for that slot.
------------------------------------------------------------------------
-- Maps one queued *table* entry (bag->slot equip, unequip, or slot->slot
-- move) onto the icon its destination slot should show. Both the docked-
-- button indicators and the character-sheet indicators derive this the
-- same way; gm is the GearManager table (needed for slotInfo).
local function ApplyQueueEntryIcon(gm, queueItem, queuedForSlot)
    if queueItem.inventorySlot then
        local slot = queueItem.inventorySlot

        if queueItem.bag and queueItem.slot then
            local itemLink = C_Container.GetContainerItemLink(queueItem.bag, queueItem.slot)
            if itemLink then
                local icon = GetItemIcon(itemLink)
                if icon then
                    queuedForSlot[slot] = icon
                end
            end
        elseif queueItem.unequip then
            queuedForSlot[slot] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-" ..
                (gm.slotInfo[slot] and gm.slotInfo[slot].name or "")
        end
    elseif queueItem.toSlot then
        local fromLink = GetInventoryItemLink("player", queueItem.fromSlot)
        if fromLink then
            local icon = GetItemIcon(fromLink)
            if icon then
                queuedForSlot[queueItem.toSlot] = icon
            end
        end
    end
end

-- Maps a queued gear *set* onto the icon each of its slots should show:
-- the item going in, or the slot's empty art where the set strips it.
local function ApplyQueuedSetIcons(gm, setName, queuedForSlot)
    local gearSet = gm.sets[setName]
    if not (gearSet and gearSet.equip) then return end
    local exSet = gm.queuedSetSlotExclusions
        and gm.queuedSetSlotExclusions[setName]
    for slot, itemLink in pairs(gearSet.equip) do
        if exSet and exSet[slot] then
        elseif itemLink and itemLink ~= 0 then
            local icon = GetItemIcon(itemLink)
            if icon then
                queuedForSlot[slot] = icon
            end
        elseif itemLink == 0 then
            queuedForSlot[slot] = "Interface\\PaperDoll\\UI-PaperDoll-Slot-" ..
                (gm.slotInfo[slot] and gm.slotInfo[slot].name or "")
        end
    end
end

-- A hotswap pressed in combat (Hotswap.lua) waits in RC.Hotswap.combatQueue,
-- not in gearSwapQueue: it has to pass its own checks when combat ends and
-- be put back afterwards. It is still a queued swap to the player, so it is
-- marked like one - on the docked buttons and on the character sheet.
local function HotswapQueuedSet()
    local q = RC.Hotswap and RC.Hotswap.combatQueue
    return q and q.set or nil
end

function GM:UpdateQueueIndicators(fromPoll)
    if not RC then return end

    local queuedForSlot = {}
    local queuedGearSet = nil

    for _, queueItem in ipairs(RC.gearSwapQueue or {}) do
        if type(queueItem) == "string" then
            queuedGearSet = queueItem
            ApplyQueuedSetIcons(self, queueItem, queuedForSlot)
        elseif type(queueItem) == "table" then
            ApplyQueueEntryIcon(self, queueItem, queuedForSlot)
        end
    end

    local hotswapSet = HotswapQueuedSet()
    if hotswapSet then
        queuedGearSet = queuedGearSet or hotswapSet
        ApplyQueuedSetIcons(self, hotswapSet, queuedForSlot)
    end

    if RC.GetPendingTrinketForSlot then
        for _, slot in ipairs({ 13, 14 }) do
            if not queuedForSlot[slot] then
                local pid = RC:GetPendingTrinketForSlot(slot)
                    or (RC.GetActiveQueueFrontForSlot and RC:GetActiveQueueFrontForSlot(slot))
                if pid then
                    local icon = GetItemIcon(pid)
                    if icon then queuedForSlot[slot] = icon end
                end
            end
        end
    end

    local sigParts = {}
    for i = 1, 19 do sigParts[i] = queuedForSlot[i] or "" end
    local sig = table.concat(sigParts, "|") .. "#" .. (queuedGearSet or "")
    if fromPoll and sig == self._lastQueueIndicatorSig then return end
    self._lastQueueIndicatorSig = sig

    for slot, button in pairs(self.buttons) do
        if button.queueIndicator then
            if queuedForSlot[slot] then
                button.queueIndicator.icon:SetTexture(queuedForSlot[slot])
                button.queueIndicator:Show()
                self:DebugPrint("Queue indicator shown for slot " .. slot)
            else
                button.queueIndicator:Hide()
            end
        end
    end

    if self.buttons[999] and self.buttons[999].queueIndicator and queuedGearSet then
        -- every queued set has an icon to show: its own, ItemRack's, or
        -- the chest piece (it used to show nothing for a set without one)
        local queuedIcon = RC.GetGearSetIcon and RC:GetGearSetIcon(queuedGearSet)
        if not queuedIcon then
            local gearSet = self.sets[queuedGearSet]
            queuedIcon = gearSet and gearSet.icon
        end
        if queuedIcon then
            self.buttons[999].queueIndicator.icon:SetTexture(queuedIcon)
            self.buttons[999].queueIndicator:Show()
            self:DebugPrint("Queue indicator shown for gear set: " .. queuedGearSet)
        end
    end

    self:UpdateCharacterSheetQueueIndicators()
end

function GM:SetupCharacterSheetQueueIndicators()
    for i = 0, 19 do
        local slotInfo = self.slotInfo[i]
        if slotInfo then
            local slotFrame = _G["Character" .. slotInfo.name]
            if slotFrame and not slotFrame.queueIndicator then
                slotFrame.queueIndicator = _gms.AttachQueueIndicator(slotFrame, "Character" .. slotInfo.name .. "QueueIndicator", 14, 12, 10)
            end
        end
    end
end

function GM:SetupCharacterSheetNameOverlays()
    for i = 0, 19 do
        local slotInfo = self.slotInfo[i]
        if slotInfo then
            local slotFrame = _G["Character" .. slotInfo.name]
            if slotFrame and not slotFrame.itemNameText then
                local nameText = RC:CreateFontString(slotFrame, "OVERLAY", nil, 7)
                nameText:SetPoint("BOTTOM", slotFrame, "BOTTOM", 0, 2)
                nameText:SetWidth(slotFrame:GetWidth() - 4)
                nameText:SetHeight(10)
                nameText:SetTextColor(1, 1, 1, 1)
                nameText:SetJustifyH("CENTER")
                nameText:SetJustifyV("BOTTOM")
                nameText:SetWordWrap(false)
                nameText:SetShadowOffset(1, -1)
                nameText:SetShadowColor(0, 0, 0, 1)

                nameText:Hide()
                slotFrame.itemNameText = nameText
            end
        end
    end
end

function GM:UpdateCharacterSlotNames()
    if self.settings.showCharSlotNames == false then
        for i = 0, 19 do
            local slotInfo = self.slotInfo[i]
            if slotInfo then
                local slotFrame = _G["Character" .. slotInfo.name]
                if slotFrame and slotFrame.itemNameText then
                    slotFrame.itemNameText:Hide()
                end
            end
        end
        return
    end

    self:SetupCharacterSheetNameOverlays()

    for i = 0, 19 do
        local slotInfo = self.slotInfo[i]
        if slotInfo then
            local slotFrame = _G["Character" .. slotInfo.name]
            if slotFrame and slotFrame.itemNameText then
                local itemLink = GetInventoryItemLink("player", i)
                if itemLink then
                    local itemName = GetItemInfo(itemLink)
                    if itemName then
                        local abbrevName = RC.GetItemAbbreviation and RC:GetItemAbbreviation(itemName) or itemName:sub(1, 5) .. "."
                        slotFrame.itemNameText:SetText(abbrevName)
                        slotFrame.itemNameText:Show()
                    else
                        slotFrame.itemNameText:Hide()
                    end
                else
                    slotFrame.itemNameText:Hide()
                end
            end
        end
    end
end

-- self.charSheetQueued is the slot -> icon map last painted here (nil
-- when nothing is queued). It is kept so a replacement character sheet
-- can draw the same markers on its own slots.
function GM:UpdateCharacterSheetQueueIndicators()
    local hotswapSet = RC and HotswapQueuedSet()
    if not RC or (not RC.gearSwapQueue and not hotswapSet) then
        self.charSheetQueued = nil
        self:ClearCharacterSheetQueueIndicators()
        return
    end

    local queuedForSlot = {}

    for _, queueItem in ipairs(RC.gearSwapQueue or {}) do
        if type(queueItem) == "table" then
            ApplyQueueEntryIcon(self, queueItem, queuedForSlot)
        end
    end
    if hotswapSet then
        ApplyQueuedSetIcons(self, hotswapSet, queuedForSlot)
    end
    self.charSheetQueued = next(queuedForSlot) and queuedForSlot or nil

    for i = 0, 19 do
        local slotInfo = self.slotInfo[i]
        if slotInfo then
            local slotFrame = _G["Character" .. slotInfo.name]
            if slotFrame and slotFrame.queueIndicator then
                if queuedForSlot[i] then
                    slotFrame.queueIndicator.icon:SetTexture(queuedForSlot[i])
                    slotFrame.queueIndicator:Show()
                else
                    slotFrame.queueIndicator:Hide()
                end
            end
        end
    end
end

function GM:ClearCharacterSheetQueueIndicators()
    for i = 0, 19 do
        local slotInfo = self.slotInfo[i]
        if slotInfo then
            local slotFrame = _G["Character" .. slotInfo.name]
            if slotFrame and slotFrame.queueIndicator then
                slotFrame.queueIndicator:Hide()
            end
        end
    end
end

if CharacterFrame then
    CharacterFrame:HookScript("OnShow", function()
        GM:UpdateCharacterSheetQueueIndicators()
        GM:UpdateCharacterSlotNames()
        GM:HookCharacterSlotLeaveEvents()
    end)

    CharacterFrame:HookScript("OnHide", function()
        GM:HideMenu()
        GameTooltip:Hide()
    end)
end

local function WR_CharSlotOnEnter(self)
    GM:CancelHideTimer()
    if GM.settings.characterSheetMenus then
        local slot = nil
        for i = 0, 19 do
            if self:GetName() == "Character" .. GM.slotInfo[i].name then
                slot = i
                break
            end
        end
        if slot then
            GM:ShowMenu(slot, self)
        end
    end
end

-- For another addon's character window that stands its own slot buttons
-- over Blizzard's (ZacUI does): call this from that slot's OnEnter and it
-- gets the same flyout a Blizzard slot gets, under the same setting.
function GM:ShowCharSheetMenu(slot, anchor)
    if not anchor or type(slot) ~= "number" then return end
    anchor._rcCharSheet = true
    self:CancelHideTimer()
    if self.settings and self.settings.characterSheetMenus and self.slotInfo and self.slotInfo[slot] then
        self:ShowMenu(slot, anchor)
    end
end

GM.characterSlotsHooked = false

-- Guarded by characterSlotsHooked since CharacterFrame OnShow re-fires
-- every time the panel is opened, but HookScript must only run once per
-- slot button.
function GM:HookCharacterSlotLeaveEvents()
    if self.characterSlotsHooked then return end

    for i = 0, 19 do
        local slotName = self.slotInfo[i] and self.slotInfo[i].name
        if slotName then
            local slotButton = _G["Character" .. slotName]
            if slotButton then
                slotButton:HookScript("OnEnter", WR_CharSlotOnEnter)
            end
        end
    end
    self.characterSlotsHooked = true
end

-- Per-slot analog of the Alt+Click-on-character-model hook in
-- GM_Runtime.lua: that one toggles the single gear-set button (999),
-- this one toggles a docked button for the specific slot clicked.
-- Only a real paperdoll slot button counts. Other addons (Gargul's
-- Alt+Click bidding, for one) route bag item clicks through this same
-- function, and a bag button's GetID() is its bag slot index - 1..19
-- of which collide with inventory slot IDs, which used to spawn a docked
-- button for whatever equipment slot shared that number.
local function IsPaperDollSlotButton(btn)
    if type(btn) ~= "table" or not btn.GetName then return false end
    local name = btn:GetName()
    if not name or not GM.slotInfo then return false end
    for i = 0, 19 do
        local info = GM.slotInfo[i]
        if info and info.name and name == "Character" .. info.name then return true end
    end
    return false
end

hooksecurefunc("PaperDollItemSlotButton_OnModifiedClick", function(self, button)
    if IsAltKeyDown() and GM.enabled and IsPaperDollSlotButton(self) then
        local slotID = self:GetID()
        if GM.buttons[slotID] then
            GM:RemoveButton(slotID)
        else
            GM:CreateButton(slotID)
        end
    end
end)

function GM:TooltipsAllowed()
    if not self.settings or not self.settings.showTooltips then return false end
    if self.settings.tooltipsOutOfCombatOnly and InCombatLockdown() then return false end
    return true
end

function GM:AnchorTooltip(owner)
    local menu = self.menuFrame
    local ref  = (menu and menu:IsShown()) and menu or owner
    GameTooltip:SetOwner(owner, "ANCHOR_NONE")
    GameTooltip:ClearAllPoints()
    local cx = ref:GetCenter() or (UIParent:GetWidth() * 0.5)
    if cx > (UIParent:GetWidth() * 0.5) then
        GameTooltip:SetPoint("TOPRIGHT", ref, "TOPLEFT", -8, 0)
    else
        GameTooltip:SetPoint("TOPLEFT", ref, "TOPRIGHT", 8, 0)
    end
    GameTooltip:SetFrameStrata("TOOLTIP")
    GameTooltip:SetFrameLevel(((menu and menu:GetFrameLevel()) or 1000) + 50)
end
