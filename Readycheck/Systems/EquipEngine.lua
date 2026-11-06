------------------------------------------------------------------------
-- Readycheck - Equip Engine
-- The one place that physically moves gear. Gear sets, boss swaps, the
-- queued post-combat swaps, the trinket rotation, the trinket bar and the
-- forced boss slots all used to drive the cursor themselves - each with
-- its own "find a free bag slot", its own idea of when a slot is busy and
-- its own way of leaving (or not leaving) the cursor clean. They now ask
-- here, and keep their own decisions (what to wear, when, and why).
--
-- What every move gets from here:
--   * a busy check first: an item already on the cursor, or a source or
--     target that the client has locked (mid-move), is not touched;
--   * the item it was asked for: a queued bag/slot is checked against the
--     item that was meant to be there, and found again through the shared
--     bag index if the bags moved since (looting in a fight used to make a
--     queued swap equip whatever ended up in that slot);
--   * free-slot search that skips profession bags (herb, ammo, soul...),
--     which never accept gear - an unequip aimed at one used to fail;
--   * a clean cursor afterwards unless the caller wants it kept (a bind
--     dialog waiting for the player);
--   * a record of the last move per slot (who, when, which item), so the
--     callers - and the swap notices - can tell their own moves apart.
--
--   RC.Equip:Busy(bag, slot, invSlot)                   -> reason or nil
--   RC.Equip:FreeBagSlot()                              -> bag, slot or nil
--   RC.Equip:ResolveBagItem(bag, slot, wantId)          -> bag, slot or nil
--   RC.Equip:BagToSlot(bag, slot, invSlot, opts)        -> ok, why
--   RC.Equip:SlotToSlot(fromSlot, toSlot, opts)         -> ok, why
--   RC.Equip:Unequip(invSlot, bag, slot, opts)          -> ok, why
--   RC.Equip:ByName(item, invSlot, opts)                -> ok, why
--   RC.Equip:LastMove(invSlot)                          -> { by, at, itemId } or nil
-- opts: by = who asked ("gearset", "tss", "trinketbar", "queue", "force"...),
--       cursor = "clear" (default) | "backpack" | "keep",
--       method = "pickup" (default) | "cursor" (EquipCursorItem),
--       wantId = the item the bag slot should hold.
-- None of these run in combat lockdown; they return false, "combat" and
-- the caller queues as it always has.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local GetItemID   = C_Container.GetContainerItemID
local GetInfo     = C_Container.GetContainerItemInfo
local GetNumSlots = C_Container.GetContainerNumSlots
local GetNumFree  = C_Container.GetContainerNumFreeSlots
local Pickup      = C_Container.PickupContainerItem
local GetTime, type, tonumber = GetTime, type, tonumber
local InCombatLockdown = InCombatLockdown

local E = {}
RC.Equip = E

local lastMove = {}     -- [invSlot] = { by, at, itemId }

local function Note(invSlot, by, itemId)
    lastMove[invSlot] = { by = by or "?", at = GetTime(), itemId = itemId }
end

function E:LastMove(invSlot)
    return lastMove[invSlot]
end

local function BagLocked(bag, slot)
    local info = GetInfo(bag, slot)
    return type(info) == "table" and info.isLocked and true or false
end

local function SlotLocked(invSlot)
    return IsInventoryItemLocked(invSlot) and true or false
end

-- Why a move cannot start right now, or nil when it can.
function E:Busy(bag, slot, invSlot)
    if InCombatLockdown() then return "combat" end
    if CursorHasItem() then return "cursor" end
    if bag and BagLocked(bag, slot) then return "bag locked" end
    if invSlot and SlotLocked(invSlot) then return "slot locked" end
    return nil
end

-- A free slot in a bag that takes anything (bag type 0): the backpack
-- first, then bags 1-4 in order, as every old search did - minus the
-- profession bags.
function E:FreeBagSlot()
    for bag = 0, 4 do
        local free, bagType = GetNumFree(bag)
        if (free or 0) > 0 and (bag == 0 or (bagType or 0) == 0) then
            for s = 1, GetNumSlots(bag) or 0 do
                if not GetItemID(bag, s) then return bag, s end
            end
        end
    end
    return nil
end

-- The bag slot that holds wantId: the one given if it still does, else
-- wherever the shared bag index finds it. nil when it is gone.
function E:ResolveBagItem(bag, slot, wantId)
    if not wantId then return bag, slot end
    if bag and slot and GetItemID(bag, slot) == wantId then return bag, slot end
    return RC.Bags:Find(wantId)
end

local function Finish(mode)
    if CursorHasItem() then
        if mode == "keep" then return true end
        if mode == "backpack" then PutItemInBackpack() end
        if CursorHasItem() then ClearCursor() end
        return true
    end
    return false
end

-- bag/slot -> invSlot. Returns ok, and whether something was left on the
-- cursor before Finish tidied it (the client refused, or a bind dialog).
function E:BagToSlot(bag, slot, invSlot, opts)
    opts = opts or {}
    if opts.wantId then
        bag, slot = self:ResolveBagItem(bag, slot, opts.wantId)
        if not bag then return false, "gone" end
    end
    local why = self:Busy(bag, slot, invSlot)
    if why == "cursor" then ClearCursor(); why = self:Busy(bag, slot, invSlot) end
    if why then return false, why end
    local itemId = GetItemID(bag, slot)
    if not itemId then return false, "empty" end
    Pickup(bag, slot)
    if not CursorHasItem() then return false, "no pickup" end
    if opts.method == "cursor" then EquipCursorItem(invSlot) else PickupInventoryItem(invSlot) end
    local left = Finish(opts.cursor or "clear")
    Note(invSlot, opts.by, itemId)
    return true, left and "cursor" or nil
end

function E:SlotToSlot(fromSlot, toSlot, opts)
    opts = opts or {}
    local why = self:Busy(nil, nil, fromSlot) or (SlotLocked(toSlot) and "slot locked") or nil
    if why == "cursor" then ClearCursor(); why = self:Busy(nil, nil, fromSlot) or (SlotLocked(toSlot) and "slot locked") or nil end
    if why then return false, why end
    local fromId = GetInventoryItemID("player", fromSlot)
    local toId = GetInventoryItemID("player", toSlot)
    PickupInventoryItem(fromSlot)
    if not CursorHasItem() then return false, "no pickup" end
    if opts.method == "cursor" then EquipCursorItem(toSlot) else PickupInventoryItem(toSlot) end
    local left = Finish(opts.cursor or "clear")
    Note(toSlot, opts.by, fromId)
    Note(fromSlot, opts.by, toId)
    return true, left and "cursor" or nil
end

-- invSlot -> the bag slot given, or the first free gear-taking one.
function E:Unequip(invSlot, bag, slot, opts)
    opts = opts or {}
    if not GetInventoryItemID("player", invSlot) then return false, "empty" end
    local why = self:Busy(nil, nil, invSlot)
    if why == "cursor" then ClearCursor(); why = self:Busy(nil, nil, invSlot) end
    if why then return false, why end
    if not bag or GetItemID(bag, slot) then bag, slot = self:FreeBagSlot() end
    if not bag then return false, "bags full" end
    PickupInventoryItem(invSlot)
    if not CursorHasItem() then return false, "no pickup" end
    Pickup(bag, slot)
    if CursorHasItem() then PutItemInBackpack() end
    if CursorHasItem() then
        ClearCursor()
        return false, "bags full"
    end
    Note(invSlot, opts.by, nil)
    return true
end

-- The client's own pick (EquipItemByName) for callers that only know an
-- item name, id or link.
function E:ByName(item, invSlot, opts)
    opts = opts or {}
    if not item or item == 0 then return false, "no item" end
    if InCombatLockdown() then return false, "combat" end
    if invSlot and SlotLocked(invSlot) then return false, "slot locked" end
    ClearCursor()
    EquipItemByName(item, invSlot)
    local id = type(item) == "number" and item
        or (type(item) == "string" and tonumber(item:match("item:(%d+)"))) or nil
    if invSlot then Note(invSlot, opts.by, id) end
    return true
end
