------------------------------------------------------------------------
-- Readycheck - Gear Manager Core
-- Shared GearManager state (slot map, button/menu tables, color palette)
-- and the low-level equip primitives: SafeSwapBagToSlot/SlotToSlot/
-- UnequipToSlot and RunSequencedUnequips, the shared batch-unequip
-- routine every set-equip path in GM_Sets.lua funnels through.
------------------------------------------------------------------------
local AddonName = "Readycheck"
local RC = _G[AddonName]

if not RC then
    error("Readycheck core not found!")
end

local pairs, ipairs, tostring, tonumber = pairs, ipairs, tostring, tonumber
local GetTime = GetTime
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GetInventoryItemLink = GetInventoryItemLink
local GetInventoryItemID = GetInventoryItemID
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local C_Container = C_Container
local C_Timer = C_Timer
RC._gms = RC._gms or {}
local _gms = RC._gms

local function GetGMSlotHoverBorder()
    return RC:GetColor("gearManager", "slotHoverBorder")
end

-- Palette entries that have an exact equivalent in the core theme are
-- resolved through RC:GetColor on every access (via __index below), so
-- user colour overrides apply to the Gear Manager too. Everything left in
-- the literal table has no core equivalent: pure-black structural fills,
-- low-alpha hint tints, and shades that only look close to a core key.
local C_CORE_KEYS = {
    white = {"text", "white"},
    gold  = {"text", "gold"},
    red   = {"text", "red"},
}

-- One reusable {r,g,b,a} array per mapped key: call sites index these as
-- C.white[1] .. C.white[4], so returning a fresh table per lookup would
-- churn garbage on every UI refresh.
local C_CACHE = {
    white = {1, 1, 1, 1},
    gold  = {1, 0.82, 0, 1},
    red   = {1, 0.3, 0.3, 1},
}

local C = setmetatable({
    black = {0, 0, 0, 1},
    blackDim = {0, 0, 0, 0.8},
    whiteHint = {1, 1, 1, 0.15},
    lightGray = {0.85, 0.85, 0.85, 1},
    darkGray = {0.2, 0.2, 0.2, 0.4},
    elementBg = {0.12, 0.12, 0.12, 0.5},
    green = {0.5, 1, 0.5, 1},
    yellowHint = {1, 1, 0, 0.3},
    brownHint = {0.3, 0.3, 0, 0.5},
}, {
    __index = function(_, key)
        local map = C_CORE_KEYS[key]
        if not map then return nil end
        local cache = C_CACHE[key]
        local col = RC.GetColor and RC:GetColor(map[1], map[2])
        if col then
            cache[1], cache[2], cache[3], cache[4] = col.r, col.g, col.b, col.a or 1
        end
        return cache
    end,
})

-- Sets fontString to text, then byte-trims from the end (appending "...")
-- until it fits maxWidth. Replaces five hand-rolled copies of this loop in
-- GM_Buttons/GM_Menu/GM_Sets; the >3 minimum length and byte-wise
-- string.sub are kept exactly as those copies had them.
local function TruncateToWidth(fontString, text, maxWidth)
    if not fontString then return end
    fontString:SetText(text or "")
    if not text or not maxWidth then return end
    if fontString:GetStringWidth() <= maxWidth then return end

    local truncated = text
    while fontString:GetStringWidth() > maxWidth and #truncated > 3 do
        truncated = string.sub(truncated, 1, -2)
        fontString:SetText(truncated .. "...")
    end
end

RC.GearManager = {
    sets = {},
    buttons = {},
    buttonData = {},
    menuFrame = nil,
    menuButtons = {},
    menuShowTimer = nil,
    hideTimerId = 0,
    currentMenuSlot = nil,
    enabled = true,
    locked = false,
    lastEquippedSetName = nil,
    settingsLoaded = false,

    settings = {
        characterSheetMenus = true,
        showTooltips = false,
        tooltipsOutOfCombatOnly = false,
        buttonSize = 36,
        buttonSpacing = 0,
        shiftCancelQueue = true,
        buttonsLocked = false,
        equipToggle = false,
        mouseoverFade = false,
        mouseoverFadeAlpha = 0.15,
        showButtonNames = true,
        showGearSetName = true,
        showGearSetStatusBorder = true,
        showMenuNames = true,
        showCharSlotNames = true,
        showCharPaneNames = true,
        showCooldownTextButtons = true,
        showCooldownTextMenus   = true,
        trinketDockSplitClick = false,
        -- Hover-menu entries hidden from dockable buttons (char sheet
        -- menus and the set editor always show everything), and the key
        -- that shows them again while it is held over an open menu.
        hiddenMenuItems = {},    -- [itemID] = true
        hiddenMenuSets  = {},    -- [set name] = true
        menuRevealKey   = "SHIFT",
        fungalBloomEnabled = false,
        fungalBloomActiveSet = "",
        fungalBloomSet = "",
        lastEquippedSetName = "",
    },

    fungalBloomWasActive = false,

    slotInfo = {
        [0] = { name="AmmoSlot", real="Ammo", invSlot=0 },
        [1] = { name="HeadSlot", real="Head", invSlot=1 },
        [2] = { name="NeckSlot", real="Neck", invSlot=2 },
        [3] = { name="ShoulderSlot", real="Shoulder", invSlot=3 },
        [4] = { name="ShirtSlot", real="Shirt", invSlot=4 },
        [5] = { name="ChestSlot", real="Chest", invSlot=5 },
        [6] = { name="WaistSlot", real="Waist", invSlot=6 },
        [7] = { name="LegsSlot", real="Legs", invSlot=7 },
        [8] = { name="FeetSlot", real="Feet", invSlot=8 },
        [9] = { name="WristSlot", real="Wrist", invSlot=9 },
        [10] = { name="HandsSlot", real="Hands", invSlot=10 },
        [11] = { name="Finger0Slot", real="Ring 1", invSlot=11 },
        [12] = { name="Finger1Slot", real="Ring 2", invSlot=12 },
        [13] = { name="Trinket0Slot", real="Trinket 1", invSlot=13 },
        [14] = { name="Trinket1Slot", real="Trinket 2", invSlot=14 },
        [15] = { name="BackSlot", real="Back", invSlot=15 },
        [16] = { name="MainHandSlot", real="Main Hand", invSlot=16 },
        [17] = { name="SecondaryHandSlot", real="Off Hand", invSlot=17 },
        [18] = { name="RangedSlot", real="Ranged", invSlot=18 },
        [19] = { name="TabardSlot", real="Tabard", invSlot=19 },
        -- 999 is the virtual "equip a set" button. Real pinned buttons
        -- (single item or single set shortcuts) start at id 1000 - see
        -- GetPinnedDef/NextPinnedId in GM_Buttons.lua.
        [999] = { name="GearSetButton", real="Gear Sets", invSlot=999 },
    },
}

local GM = RC.GearManager

-- A character pane slot: Blizzard's own (CharacterHeadSlot and friends),
-- or another addon's slot standing in for it - ZacUI's character window
-- covers Blizzard's slots with its own and opens the menu from those via
-- GM:ShowCharSheetMenu, which marks them. Every "is this the character
-- sheet" decision goes through here rather than matching the name.
function GM:IsCharSheetAnchor(anchor)
    if not anchor then return false end
    if anchor._rcCharSheet then return true end
    local name = anchor.GetName and anchor:GetName() or ""
    return string.find(name, "^Character") ~= nil
end

function GM:IsMouseOverMenuSystem()
    if self.menuFrame and self.menuFrame:IsShown() and self.menuFrame:IsMouseOver() then
        return true
    end

    if self.currentMenuAnchor and self.currentMenuAnchor:IsShown() and self.currentMenuAnchor:IsMouseOver() then
        return true
    end

    if self.buttons then
        for _, btn in pairs(self.buttons) do
            if btn and btn:IsShown() and btn:IsMouseOver() then
                return true
            end
        end
    end

    if CharacterFrame and CharacterFrame:IsShown() then
        for i = 0, 19 do
            local slotName = self.slotInfo[i] and self.slotInfo[i].name
            if slotName then
                local slotButton = _G["Character" .. slotName]
                -- A slot faded out under another addon's character window
                -- is not something the mouse can be "on".
                if slotButton and slotButton:IsShown() and slotButton:IsMouseOver()
                        and (slotButton:GetEffectiveAlpha() or 1) > 0.05 then
                    return true
                end
            end
        end
    end

    if self.editorFrame and self.editorFrame:IsShown() and self.editorFrame:IsMouseOver() then
        return true
    end

    return false
end

function GM:CancelHideTimer()
    self.hideTimerId = self.hideTimerId + 1
    if self.menuFrame then
        self.menuFrame.notHoveredCount = 0
    end
end

function GM:Print(msg)
    if RC and RC.Print then
        RC:Print(RCL["[Gear] "] .. tostring(msg))
    else
        print("|cFF00FF00[Gear]|r " .. tostring(msg))
    end
end

-- cat is forwarded to core so callers that pass an explicit category
-- ("gearswap", "trinket", ...) are not silently downgraded to "gear".
function GM:DebugPrint(msg, cat)
    if RC and RC.DebugPrint then
        RC:DebugPrint(tostring(msg), cat or "gear")
    end
end

function GM:GetItemID(itemLink)
    if not itemLink then return nil end
    return tonumber(string.match(itemLink, "item:(%d+)"))
end

function GM:GetSlotTexture(slot)
    if slot == 999 then
        return "Interface\\Icons\\INV_Chest_Plate16"
    end
    return GetInventoryItemTexture("player", slot) or ("Interface\\PaperDoll\\UI-PaperDoll-Slot-" .. self.slotInfo[slot].name)
end

function GM:GetTableSize(tbl)
    if RC and RC.TableCount then
        return RC:TableCount(tbl)
    end
    if not tbl then return 0 end
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

-- PREDICTED ICONS. An equip is a round trip to the server, and the slot
-- button used to keep the old item's icon until PLAYER_EQUIPMENT_CHANGED
-- came back and the refresh debounce ran out - long enough for a click to
-- look like it had done nothing. The Safe* helpers below paint the button
-- with what was asked for at once. UpdateButtonIcon (GM_Buttons.lua)
-- leaves that in place until the slot really holds it, or PREDICT_HOLD
-- passes (the swap was refused) and the truth is painted again; the timer
-- here makes sure that second case is looked at even if no event comes.
-- itemID nil = the slot is expected to end up empty.
local PREDICT_HOLD = 0.75
function GM:PredictSlotItem(slot, itemID, texture, itemLink)
    local button = self.buttons and self.buttons[slot]
    if not button or slot == 999 or not self.UpdateButtonIcon then return end
    button._predicted = {
        id = itemID or false, texture = texture, link = itemLink,
        expires = GetTime() + PREDICT_HOLD,
    }
    self:UpdateButtonIcon(slot)
    -- A refused swap puts the old icon back with no event behind it, so
    -- its cooldown (faded out with the icon) has to be repainted here too.
    C_Timer.After(PREDICT_HOLD + 0.05, function()
        if GM.buttons[slot] then
            GM:UpdateButtonIcon(slot)
            if GM.UpdateButtonCooldowns then GM:UpdateButtonCooldowns() end
        end
    end)
end

-- Combat lockdown makes PickupContainerItem/PickupInventoryItem protected.
-- All three Safe* helpers below take the same shape: queue the action via
-- RC:QueueGearSwap and return false instead of touching protected API,
-- so callers must check the return value rather than assume the swap ran.
function GM:SafeSwapBagToSlot(bag, bagSlot, inventorySlot, itemLink)
    if InCombatLockdown() then
        RC:QueueGearSwap({
            bag = bag,
            slot = bagSlot,
            inventorySlot = inventorySlot,
            itemLink = itemLink
        })
        self:UpdateQueueIndicators()
        return false
    end

    self.pendingEquipSlot = inventorySlot
    self.pendingEquipBag = bag
    self.pendingEquipBagSlot = bagSlot
    self.pendingEquipTime = GetTime()

    -- read before the pickup: the bag slot is locked and blank after it
    local incoming = C_Container.GetContainerItemInfo(bag, bagSlot)

    -- the cursor is kept for a bind dialog, handled just below
    local moved = RC.Equip:BagToSlot(bag, bagSlot, inventorySlot, { by = "gearset", cursor = "keep" })

    if not moved then
        self.pendingEquipSlot = nil
    elseif CursorHasItem() then
        self:DebugPrint("Cursor has item after equip attempt - waiting for possible bind dialog")
        C_Timer.After(0.05, function()
            local bindDialogShowing = StaticPopup_Visible("EQUIP_BIND") or
                                       StaticPopup_Visible("EQUIP_BIND_REFUNDABLE") or
                                       StaticPopup_Visible("EQUIP_BIND_TRADEABLE")

            if bindDialogShowing then
                GM:DebugPrint("Bind dialog detected - leaving cursor for player to confirm")
            elseif CursorHasItem() then
                GM:DebugPrint("No bind dialog but cursor still has item - clearing")
                ClearCursor()
                GM.pendingEquipSlot = nil
            end
        end)
    else
        self.pendingEquipSlot = nil
        if incoming and incoming.itemID then
            self:PredictSlotItem(inventorySlot, incoming.itemID,
                incoming.iconFileID, incoming.hyperlink or itemLink)
        end
        -- the trinket bar shows it at once too
        if RC.PredictTrinketBarMove then RC:PredictTrinketBarMove(inventorySlot, bag, bagSlot) end
    end

    -- Safety net: clears pendingEquipSlot if EQUIP_BIND_CONFIRM/USE_BIND_CONFIRM
    -- never fires (player closes the bind dialog without confirming).
    C_Timer.After(5.0, function()
        if GM.pendingEquipSlot == inventorySlot and GM.pendingEquipTime and (GetTime() - GM.pendingEquipTime) > 4.5 then
            GM.pendingEquipSlot = nil
            GM.pendingEquipTime = nil
        end
    end)

    return true
end

function GM:SafeSwapSlotToSlot(fromSlot, toSlot)
    if InCombatLockdown() then
        RC:QueueGearSwap({
            fromSlot = fromSlot,
            toSlot = toSlot
        })
        self:UpdateQueueIndicators()
        return false
    end

    local fromID, fromTex, fromLink = GetInventoryItemID("player", fromSlot),
        GetInventoryItemTexture("player", fromSlot), GetInventoryItemLink("player", fromSlot)
    local toID, toTex, toLink = GetInventoryItemID("player", toSlot),
        GetInventoryItemTexture("player", toSlot), GetInventoryItemLink("player", toSlot)

    local ok, why = RC.Equip:SlotToSlot(fromSlot, toSlot, { by = "gearset" })
    if ok and why ~= "cursor" then
        -- the two slots trade contents
        self:PredictSlotItem(toSlot, fromID, fromTex, fromLink)
        self:PredictSlotItem(fromSlot, toID, toTex, toLink)
        if RC.PredictTrinketBarMove then RC:PredictTrinketBarMove(toSlot, nil, nil, fromSlot) end
    end
    return true
end

function GM:ItemFitsInvSlot(itemLink, invSlot)
    if invSlot ~= 16 and invSlot ~= 17 then return true end
    if not itemLink then return true end
    local equipLoc = select(9, GetItemInfo(itemLink))
    if not equipLoc or equipLoc == "" then return true end
    if invSlot == 16 then
        return equipLoc == "INVTYPE_WEAPON"
            or equipLoc == "INVTYPE_WEAPONMAINHAND"
            or equipLoc == "INVTYPE_2HWEAPON"
    end
    return equipLoc == "INVTYPE_WEAPON"
        or equipLoc == "INVTYPE_WEAPONOFFHAND"
        or equipLoc == "INVTYPE_SHIELD"
        or equipLoc == "INVTYPE_HOLDABLE"
end

-- Handles the case a set wants slot 16's item in 17 and vice versa: a plain
-- swap only needs SafeSwapSlotToSlot, but if one target slot is empty the
-- other weapon has to go to bag first (UnequipToFreeBag) and back in on a
-- delay - PickupInventoryItem right after PutItemInBackpack can miss the
-- item still settling into the bag, hence the 0.4s/0.5s ScheduleStep2 waits.
function GM:ResolveWeaponCrossMove(target16, target17, setName)
    local id16 = (target16 and target16 ~= 0) and self:GetItemID(target16) or nil
    local id17 = (target17 and target17 ~= 0) and self:GetItemID(target17) or nil
    if id16 and id17 and id16 == id17 then return false, false end
    local cur16 = GetInventoryItemID("player", 16)
    local cur17 = GetInventoryItemID("player", 17)

    -- into a bag that takes gear (never a herb, ammo or soul bag)
    local function UnequipToFreeBag(invSlot)
        if not RC.Equip:FreeBagSlot() then return false end
        self:SafeUnequipToSlot(invSlot)
        return true
    end

    local function ScheduleStep2(link, slot)
        C_Timer.After(0.4, function()
            if InCombatLockdown() then
                if setName then RC:QueueGearSwap(setName) end
                return
            end
            RC:FastEquipItem(link, slot)
            C_Timer.After(0.5, function()
                if not InCombatLockdown() then
                    RC:FastEquipItem(link, slot)
                end
                if GM.UpdateAllButtonIcons   then GM:UpdateAllButtonIcons()   end
                if GM.UpdateGearSetButtonIcon then GM:UpdateGearSetButtonIcon() end
            end)
        end)
    end

    if id16 and id17 and id16 == cur17 and id17 == cur16 then
        self:SafeSwapSlotToSlot(16, 17)
        return true, true
    elseif id16 and id16 == cur17 and target17 ~= nil then
        if id17 then
            RC:FastEquipItem(target17, 17)
        else
            UnequipToFreeBag(17)
        end
        ScheduleStep2(target16, 16)
        return true, true
    elseif id17 and id17 == cur16 and target16 ~= nil then
        if id16 then
            RC:FastEquipItem(target16, 16)
        else
            UnequipToFreeBag(16)
        end
        ScheduleStep2(target17, 17)
        return true, true
    end
    return false, false
end

-- bag/bagSlot may be nil: the first free gear-taking bag slot is used.
function GM:SafeUnequipToSlot(inventorySlot, bag, bagSlot)
    if InCombatLockdown() then
        RC:QueueGearSwap({
            inventorySlot = inventorySlot,
            unequip = true
        })
        self:UpdateQueueIndicators()
        return false
    end

    local hadItem = GetInventoryItemID("player", inventorySlot) ~= nil

    if RC.Equip:Unequip(inventorySlot, bag, bagSlot, { by = "gearset" }) and hadItem then
        self:PredictSlotItem(inventorySlot)
    end
    return true
end

function GM:RunSequencedUnequips(unequips, _retry)
    if not unequips or #unequips == 0 then return end

    -- PickupInventoryItem is protected under combat lockdown: calling it in
    -- combat raises ADDON_ACTION_BLOCKED and the unequip is silently dropped.
    -- The 0.3s retry pass below is the usual way in - combat can start inside
    -- that window even when the first pass was fine. Queue and resume instead.
    if InCombatLockdown() then
        local q, seen = self._pendingUnequips or {}, {}
        for _, s in ipairs(q) do seen[s] = true end
        for _, s in ipairs(unequips) do
            if not seen[s] then q[#q + 1] = s; seen[s] = true end
        end
        self._pendingUnequips      = q
        self._pendingUnequipRetry  = self._pendingUnequipRetry or _retry
        if not self._unequipCombatFrame then
            local frame = CreateFrame("Frame")
            self._unequipCombatFrame = frame
            frame:RegisterEvent("PLAYER_REGEN_ENABLED")
            frame:SetScript("OnEvent", function(f)
                f:UnregisterAllEvents()
                GM._unequipCombatFrame = nil
                local pending, retry = GM._pendingUnequips, GM._pendingUnequipRetry
                GM._pendingUnequips, GM._pendingUnequipRetry = nil, nil
                if pending and #pending > 0 then
                    GM:RunSequencedUnequips(pending, retry)
                end
            end)
        end
        RC:DebugPrint("Batch unequip deferred until combat ends ("
            .. #q .. " slot(s) queued)", "gear")
        return
    end

    -- unequips holds inventory slot numbers already resolved to "explicit
    -- 0 in the set's equip table" by the caller - not raw item links.
    table.sort(unequips)

    local dests, di = {}, 0
    for bag = 0, 4 do
        local free, bagType = C_Container.GetContainerNumFreeSlots(bag)
        if free and free > 0 and (bagType == 0 or bag == 0) then
            for bagSlot = 1, C_Container.GetContainerNumSlots(bag) do
                if not C_Container.GetContainerItemLink(bag, bagSlot) then
                    di = di + 1
                    dests[di] = { bag = bag, slot = bagSlot }
                    if di >= #unequips then break end
                end
            end
        end
        if di >= #unequips then break end
    end

    local fired = 0
    for i, invSlot in ipairs(unequips) do
        if GetInventoryItemLink("player", invSlot) then
            local d = dests[fired + 1]
            if not d then
                RC:Print(RCL["Bags full - stopped unequipping remaining gear."])
                break
            end
            fired = fired + 1
            PickupInventoryItem(invSlot)
            C_Container.PickupContainerItem(d.bag, d.slot)
            if CursorHasItem() then
                PutItemInBackpack()
            end
            ClearCursor()
        end
    end

    C_Timer.After(0.3, function()
        local leftover = {}
        for _, invSlot in ipairs(unequips) do
            if GetInventoryItemLink("player", invSlot) then
                leftover[#leftover + 1] = invSlot
            end
        end
        if #leftover > 0 and not _retry then
            RC:DebugPrint("Batch unequip: " .. #leftover
                .. " slot(s) bounced - one retry pass", "gear")
            GM:RunSequencedUnequips(leftover, true)
        elseif #leftover > 0 then
            RC:DebugPrint("Batch unequip: " .. #leftover
                .. " slot(s) still worn after retry (bag lock or no room)", "gear")
        end
        if GM.UpdateAllButtonIcons    then GM:UpdateAllButtonIcons()    end
        if GM.UpdateGearSetButtonIcon then GM:UpdateGearSetButtonIcon() end
    end)
end

local function AttachQueueIndicator(parent, name, size, iconSize, levelBump)
    local qi = CreateFrame("Frame", name, parent)
    qi:SetSize(size, size)
    qi:SetPoint("TOPLEFT", parent, "TOPLEFT", 1, -1)
    qi:SetFrameStrata("HIGH")
    qi:SetFrameLevel(parent:GetFrameLevel() + levelBump)

    local bg = qi:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(C.blackDim[1], C.blackDim[2], C.blackDim[3], C.blackDim[4])
    qi.bg = bg

    local icon = qi:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("CENTER")
    icon:SetSize(iconSize, iconSize)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    qi.icon = icon

    local sides = {
        { "TOPLEFT", "TOPRIGHT", "SetHeight" },
        { "BOTTOMLEFT", "BOTTOMRIGHT", "SetHeight" },
        { "TOPLEFT", "BOTTOMLEFT", "SetWidth" },
        { "TOPRIGHT", "BOTTOMRIGHT", "SetWidth" },
    }
    for i = 1, #sides do
        local s = sides[i]
        local t = qi:CreateTexture(nil, "OVERLAY")
        t:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
        t:SetDrawLayer("OVERLAY", 1)
        t:SetPoint(s[1], 0, 0)
        t:SetPoint(s[2], 0, 0)
        t[s[3]](t, 1)
    end

    qi:Hide()
    return qi
end

-- On the docked buttons the badge (what's queued next for that slot) is a
-- corner chip about a third of the button, so the item that's equipped
-- now stays readable under it. Follows the button size setting.
function GM:FitQueueIndicator(button)
    local qi = button and button.queueIndicator
    if not qi then return end
    local s = math.floor(self:GetButtonUnitSize() * 0.33 + 0.5)
    if s < 9 then s = 9 end
    qi:SetSize(s, s)
    qi.icon:SetSize(s - 2, s - 2)
    -- under the button's text (the cooldown number and the item name sit
    -- on HIGH +20 frames), so text always reads on top of it
    qi:SetFrameLevel(button:GetFrameLevel() + 15)
end

_gms.C = C
_gms.GetGMSlotHoverBorder = GetGMSlotHoverBorder
_gms.AttachQueueIndicator = AttachQueueIndicator
_gms.TruncateToWidth = TruncateToWidth
