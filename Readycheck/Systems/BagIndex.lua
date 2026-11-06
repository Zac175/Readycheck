------------------------------------------------------------------------
-- Readycheck - Bag Index
-- One shared picture of the player's bags (0-4): which item sits in
-- which slot, how many of each item, and where the first one is.
--
-- Before this, every feature that needed "where is item X" or "what is
-- its cooldown" walked all five bags itself - the trinket bar, the
-- weapons bar, the potion and explosive cooldowns, smart macros, the
-- trinket swap, world buff tools - so one loot or one potion meant the
-- same 100-odd slots were read eight or nine times over.
--
-- Now BAG_UPDATE only marks the bag it names; the next reader (or a
-- short coalescing timer) rescans just the bags that changed, once, for
-- everyone. Readers always get current data: any pending bag is read
-- before an answer is given, so nothing waits on the timer.
--
--   RC.Bags:Find(itemID)          -> bag, slot of the first one (or nil)
--   RC.Bags:Count(itemID)         -> how many are carried (stacks summed)
--   RC.Bags:Cooldown(itemID)      -> start, duration (0, 0 if none carried)
--   RC.Bags:ItemAt(bag, slot)     -> itemID or nil
--   RC.Bags:Each(fn)              -> fn(bag, slot, itemID, count); return true to stop
--   RC.Bags:Version()             -> bumps whenever any bag's contents change
--   RC.Bags:OnChange(key, fn)     -> fn(version) after a change (nil fn removes)
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local GetNumSlots = C_Container.GetContainerNumSlots
local GetItemID   = C_Container.GetContainerItemID
local GetInfo     = C_Container.GetContainerItemInfo
local GetCooldown = C_Container.GetContainerItemCooldown
local pairs, next, type, wipe = pairs, next, type, wipe
local C_Timer = C_Timer

local FIRST_BAG, LAST_BAG = 0, 4

local Bags = {}
RC.Bags = Bags

local slots   = {}    -- [bag] = { [slot] = itemID }
local stacks  = {}    -- [bag] = { [slot] = count }
local counts  = {}    -- [itemID] = total carried
local where   = {}    -- [itemID] = bag * 1000 + slot of the first one (bag order, then slot)
local dirty   = {}    -- [bag] = true while its slots are not read yet
local anyDirty = true
local version = 0
local listeners = {}
local flushQueued = false

for bag = FIRST_BAG, LAST_BAG do
    slots[bag], stacks[bag], dirty[bag] = {}, {}, true
end

local function StackCount(bag, slot)
    local info = GetInfo(bag, slot)
    return (type(info) == "table" and info.stackCount) or 1
end

-- The first location must follow bag order, then slot order, which is the
-- order every old scan used ("the first one found"), so callers that use
-- that item get the same stack as before.
local function RebuildWhere()
    wipe(where)
    for bag = FIRST_BAG, LAST_BAG do
        local s = slots[bag]
        local n = GetNumSlots(bag) or 0
        for slot = 1, n do
            local id = s[slot]
            if id and not where[id] then where[id] = bag * 1000 + slot end
        end
    end
end

local function ReadBag(bag)
    local s, st = slots[bag], stacks[bag]
    local changed = false
    local n = GetNumSlots(bag) or 0
    -- a bag swapped for a smaller one leaves old slots behind
    for slot in pairs(s) do
        if slot > n then
            local old = s[slot]
            counts[old] = (counts[old] or 0) - (st[slot] or 0)
            if counts[old] <= 0 then counts[old] = nil end
            s[slot], st[slot] = nil, nil
            changed = true
        end
    end
    for slot = 1, n do
        local id = GetItemID(bag, slot)
        local c = id and StackCount(bag, slot) or nil
        local oldId, oldC = s[slot], st[slot]
        if id ~= oldId or c ~= oldC then
            if oldId then
                counts[oldId] = (counts[oldId] or 0) - (oldC or 0)
                if counts[oldId] <= 0 then counts[oldId] = nil end
            end
            if id then counts[id] = (counts[id] or 0) + c end
            s[slot], st[slot] = id, c
            changed = true
        end
    end
    dirty[bag] = nil
    return changed
end

local function Notify()
    for key, fn in pairs(listeners) do
        local ok, err = pcall(fn, version)
        if not ok and RC.DebugPrint then
            RC:DebugPrint("BagIndex listener " .. tostring(key) .. ": " .. tostring(err), "system")
        end
    end
end

-- Reads every bag that changed since the last read. Cheap when nothing
-- is pending (one flag test), so every reader calls it first.
function Bags:Flush()
    if not anyDirty then return false end
    anyDirty = false
    local changed = false
    for bag = FIRST_BAG, LAST_BAG do
        if dirty[bag] and ReadBag(bag) then changed = true end
    end
    if changed then
        RebuildWhere()
        version = version + 1
        if next(listeners) then Notify() end
    end
    return changed
end

local function MarkAll()
    for bag = FIRST_BAG, LAST_BAG do dirty[bag] = true end
    anyDirty = true
end

local function QueueFlush()
    if flushQueued then return end
    flushQueued = true
    C_Timer.After(0.05, function()
        flushQueued = false
        Bags:Flush()
    end)
end

function Bags:Find(itemID)
    if not itemID then return nil end
    if anyDirty then self:Flush() end
    local w = where[itemID]
    if not w then return nil end
    return (w - w % 1000) / 1000, w % 1000
end

function Bags:Count(itemID)
    if not itemID then return 0 end
    if anyDirty then self:Flush() end
    return counts[itemID] or 0
end

function Bags:Cooldown(itemID)
    local bag, slot = self:Find(itemID)
    if not bag then return 0, 0 end
    local start, duration = GetCooldown(bag, slot)
    return start or 0, duration or 0
end

function Bags:ItemAt(bag, slot)
    if anyDirty then self:Flush() end
    local s = slots[bag]
    return s and s[slot] or nil
end

function Bags:Each(fn)
    if anyDirty then self:Flush() end
    for bag = FIRST_BAG, LAST_BAG do
        local s, st = slots[bag], stacks[bag]
        local n = GetNumSlots(bag) or 0
        for slot = 1, n do
            local id = s[slot]
            if id and fn(bag, slot, id, st[slot] or 1) then return end
        end
    end
end

function Bags:Version()
    if anyDirty then self:Flush() end
    return version
end

function Bags:OnChange(key, fn)
    listeners[key] = fn
end

-- BAG_UPDATE names the bag; only that one is read again. It can fire a
-- dozen times for one loot, so the event only marks and queues.
local ev = CreateFrame("Frame")
ev:RegisterEvent("BAG_UPDATE")
ev:RegisterEvent("BAG_UPDATE_DELAYED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:SetScript("OnEvent", function(_, event, bag)
    if event == "BAG_UPDATE" then
        if type(bag) == "number" and bag >= FIRST_BAG and bag <= LAST_BAG then
            dirty[bag] = true
            anyDirty = true
            QueueFlush()
        end
    elseif event == "BAG_UPDATE_DELAYED" then
        if anyDirty then Bags:Flush() end
    else
        MarkAll()
        QueueFlush()
    end
end)
