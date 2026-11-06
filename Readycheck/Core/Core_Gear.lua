------------------------------------------------------------------------
-- Readycheck - Gear Set Equipping / ItemRack Integration
-- Owns gear-set equip/queue logic for both the built-in GearManager sets
-- and third-party ItemRack sets, plus the combat-lockdown queue that
-- defers any equip attempt made while in combat until PLAYER_REGEN_ENABLED.
-- Trinket-slot swaps are also requested from Core_Runtime.lua (macro
-- equip) and the trinket-swap rotation system - CancelQueuedSwapsForSlot
-- below is the one place that reconciles all of those queues at once.
------------------------------------------------------------------------
local CP = Readycheck.Compat
local GetItemInfo = GetItemInfo or CP.GetItemInfo
local GetItemCount = GetItemCount or CP.GetItemCount

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local GetTime, UnitName = GetTime, UnitName
local UnitAffectingCombat, InCombatLockdown = UnitAffectingCombat, InCombatLockdown
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
function RC:GetCharacterKey()
    local playerName = UnitName("player")
    local realmName = GetRealmName()
    return playerName .. "-" .. realmName
end

-- Retry policy shared by every boss gear swap that verifies its result
-- (engage overrides, after-boss overrides, post-combat set). Stored in
-- the profile as db.gearSwapRetry = { attempts, interval, warn }.
function RC:GearSwapRetryCfg()
    local c = self.db and self.db.gearSwapRetry or {}
    return tonumber(c.attempts) or 3, tonumber(c.interval) or 1.0, c.warn ~= false
end

-- Chat warning for a swap that gave up; nothing else in the swap paths
-- speaks to the player.
function RC:GearSwapWarn(what, attempts, slots)
    local _, _, warn = self:GearSwapRetryCfg()
    if not warn then return end
    local byInv = {}
    for _, e in ipairs(self.GEAR_SLOT_ORDER or {}) do byInv[e.invSlot] = e.name end
    local names = {}
    for _, s in ipairs(slots or {}) do
        names[#names + 1] = byInv[s] or tostring(s)
    end
    self:Print(string.format(RCL["|cffff6060Gear swap:|r %s could not be fully equipped after %d attempts%s"],
        tostring(what), attempts,
        #names > 0 and (" (" .. table.concat(names, ", ") .. ")") or ""))
end

-- The icon a gear set was saved with (built-in sets first, then
-- ItemRack's), or the plain chest piece when it has none. Blizzard's
-- question-mark placeholder (file 134400) counts as none.
function RC:GetGearSetIcon(setName)
    local function real(ic)
        if ic == nil or ic == "" or ic == 134400 then return nil end
        if type(ic) == "string" and ic:lower():find("questionmark", 1, true) then return nil end
        return ic
    end
    -- some saved fields hold an ItemRack set as "ItemRack:<name>"
    if type(setName) == "string" then setName = setName:gsub("^ItemRack:", "") end
    local gm = self.GearManager and self.GearManager.sets and self.GearManager.sets[setName]
    local ic = type(gm) == "table" and real(gm.icon)
    if ic then return ic end
    local ir = ItemRackUser and ItemRackUser.Sets and ItemRackUser.Sets[setName]
    ic = type(ir) == "table" and real(ir.icon)
    if ic then return ic end
    return "Interface\\Icons\\INV_Chest_Plate16"
end

-- The same icon as an inline texture, to sit in front of the set's name
-- in a line of text (a tooltip title, a label): "|T...|t". size in pixels.
function RC:GetGearSetIconText(setName, size)
    size = size or 14
    return "|T" .. tostring(self:GetGearSetIcon(setName)) .. ":" .. size .. ":" .. size
        .. ":0:0:64:64:5:59:5:59|t"
end

function RC:GetAllGearSets()
    local sets = {}

    if self.GearManager and self.GearManager.sets then
        for setName in pairs(self.GearManager.sets) do
            -- Sets named with a leading "~" are internal/hidden (used by
            -- other systems as scratch sets) and never listed to the user.
            if not string.match(setName, "^~") then
                table.insert(sets, {
                    name = setName,
                    source = "GearManager",
                    icon = self:GetGearSetIcon(setName)
                })
            end
        end
    end

    if self.itemRackIntegration.sets then
        for _, setName in ipairs(self.itemRackIntegration.sets) do
            table.insert(sets, {
                name = setName,
                source = "ItemRack",
                icon = self:GetGearSetIcon(setName)
            })
        end
    end

    table.sort(sets, function(a, b) return a.name < b.name end)

    return sets
end

function RC:CheckItemRackAvailability()
    if ItemRackUser and ItemRackUser.Sets then
        self.itemRackIntegration.available = true
        self:ScanItemRackSets()
        self:DebugPrint("ItemRack detected - gear set swapping available", "itemrack")
        return true
    else
        self.itemRackIntegration.available = false
        self:DebugPrint("ItemRack not detected", "itemrack")
        return false
    end
end

function RC:ScanItemRackSets()
    if not ItemRackUser or not ItemRackUser.Sets then
        return
    end

    self.itemRackIntegration.sets = {}

    for setName, setData in pairs(ItemRackUser.Sets) do
        table.insert(self.itemRackIntegration.sets, setName)
    end

    table.sort(self.itemRackIntegration.sets)

    self:DebugPrint("Found " .. #self.itemRackIntegration.sets .. " ItemRack sets", "itemrack")
end

-- Item IDs for the three Classic Era training dummies (Target Dummy,
-- Advanced Target Dummy, Master's Target Dummy) used to test rotations.
RC.TARGET_DUMMY_IDS = { [16023] = true, [4392] = true, [22261] = true }
function RC:ResolveTargetDummy()
    for _, itemId in ipairs({ 16023, 4392, 22261 }) do
        if GetItemCount and (GetItemCount(itemId) or 0) > 0 then
            return itemId
        end
    end
    return 16023
end

-- ITEM PICKERS AND LISTS. Every target dummy is one item to the player:
-- "Target Dummy", whichever one is in the bags. Catalog rows that merge
-- several items (aggregateItemIds: poisons, mana gems) count as carried
-- when any of their items is. Pickers offer the dummy always and other
-- items only while they are in the bags.
RC.TARGET_DUMMY_ICON = "Interface\\Icons\\INV_Crate_02"

function RC:IsTargetDummy(itemId)
    local id = tonumber(itemId)
    return id ~= nil and RC.TARGET_DUMMY_IDS[id] == true
end

-- The item actually in the bags for this entry (a dummy or a merged row
-- resolves to whichever version is carried), or nil.
function RC:CarriedVersion(itemId, data)
    local id = tonumber(itemId)
    if not id or not GetItemCount then return nil end
    if RC.TARGET_DUMMY_IDS[id] then
        for _, d in ipairs({ 16023, 4392, 22261 }) do
            if (GetItemCount(d) or 0) > 0 then return d end
        end
        return nil
    end
    if (GetItemCount(id) or 0) > 0 then return id end
    if type(data) == "table" and type(data.aggregateItemIds) == "table" then
        for _, a in ipairs(data.aggregateItemIds) do
            if (GetItemCount(a) or 0) > 0 then return a end
        end
    end
    return nil
end

function RC:CarriesItem(itemId, data)
    return RC:CarriedVersion(itemId, data) ~= nil
end

-- The name an entry goes by in pickers and lists.
function RC:ItemLabel(itemId, data)
    if RC:IsTargetDummy(itemId) then return RCL["Target Dummy"] end
    if type(data) == "table" and (data.displayName or data.name) then
        return data.displayName or data.name
    end
    local id = tonumber(itemId)
    return (id and GetItemInfo and GetItemInfo(id)) or ("Item " .. tostring(itemId))
end

function RC:ItemLabelIcon(itemId, data)
    if RC:IsTargetDummy(itemId) then return RC.TARGET_DUMMY_ICON end
    local id = tonumber(itemId)
    local tex = id and GetItemIcon and GetItemIcon(id)
    return tex or (type(data) == "table" and data.icon) or "Interface\\Icons\\INV_Misc_QuestionMark"
end

-- The catalog row for an item id (raidConsumables), if any.
function RC:ConsumableRow(itemId)
    for _, cat in pairs(RC.raidConsumables or {}) do
        local row = cat.items and cat.items[itemId]
        if row then return row end
    end
    return nil
end

function RC:EquipGearSet(setName)
    if not setName or setName == "" then
        self:DebugPrint("ERROR: EquipGearSet called with nil or empty setName", "gear")
        return false
    end

    -- Equip calls are protected during combat lockdown; queue instead of
    -- calling and let ProcessGearSwapQueue retry once combat ends.
    if InCombatLockdown() then
        self:DebugPrint("In combat - queuing gear swap: " .. setName, "gear")
        self:QueueGearSwap(setName)
        return false
    end

    local isItemRackSet = setName:find("^ItemRack:")
    local actualSetName = setName
    if isItemRackSet then
        actualSetName = setName:gsub("^ItemRack:", "")
    end

    -- the swap notice: the pieces that change in the next moments are this set
    if self.NoteSwapIntent then
        local icon
        local gm = not isItemRackSet and self.GearManager and self.GearManager.sets
            and self.GearManager.sets[actualSetName]
        if gm and gm.icon and gm.icon ~= 134400 then icon = gm.icon end
        if not icon and ItemRackUser and ItemRackUser.Sets and ItemRackUser.Sets[actualSetName] then
            icon = ItemRackUser.Sets[actualSetName].icon
        end
        self:NoteSwapIntent(RCL["Gear set: "] .. actualSetName, icon or "Interface\\Icons\\INV_Chest_Plate16")
    end

    if not isItemRackSet and self.GearManager and self.GearManager.sets and self.GearManager.sets[actualSetName] then
        self:DebugPrint("Using built-in Gear Manager for set: " .. actualSetName, "gear")
        return self.GearManager:EquipSet(actualSetName)
    end

    if self.itemRackIntegration.available then
        self:DebugPrint("Using ItemRack for set: " .. actualSetName, "gear")
        return self:EquipItemRackSet(actualSetName)
    end

    return false
end

function RC:FastEquipItem(item, invSlot)
    if not item or item == 0 or not invSlot then return false end
    if InCombatLockdown() then return false end
    local wantId = item
    if type(item) == "string" then wantId = tonumber(item:match("item:(%d+)")) or item end
    local curId = GetInventoryItemID("player", invSlot)
    if curId and wantId and curId == wantId then return true end
    local pref = type(wantId) == "number" and RC.db
        and RC.db.itemEnchantPreference
        and RC.db.itemEnchantPreference[wantId]
    if pref ~= nil and RC.GearManager and RC.GearManager.FindBagCopy then
        local pb, ps = RC.GearManager:FindBagCopy(wantId, pref)
        if pb then
            RC.GearManager:EquipBagItemToSlot(pb, ps, invSlot)
            return true
        end
    end
    RC.Equip:ByName(item, invSlot, { by = "gearset" })
    return true
end

function RC:EquipGearSetFast(setName, excludeSlots)
    if not setName or setName == "" then return false end
    if self.GearManager and self.GearManager.EquipSetInstant
       and self.GearManager.sets and self.GearManager.sets[setName] then
        return self.GearManager:EquipSetInstant(setName, excludeSlots)
    end
    return self:EquipGearSet(setName)
end

-- A pick made in combat for a slot - from the gear buttons or the trinket
-- bar - replaces whatever either of them already has waiting for that
-- slot, so only the latest choice runs when combat ends. (Each slot the
-- new pick touches is passed; a swap between two slots passes both.)
function RC:DropQueuedPicksForSlot(slotA, slotB)
    local droppedQueue, droppedBar = false, false
    local q = self.gearSwapQueue
    if q then
        for i = #q, 1, -1 do
            local e = q[i]
            if type(e) == "table" then
                local s1, s2, s3 = e.inventorySlot, e.fromSlot, e.toSlot
                if (slotA and (s1 == slotA or s2 == slotA or s3 == slotA))
                   or (slotB and (s1 == slotB or s2 == slotB or s3 == slotB)) then
                    table.remove(q, i)
                    droppedQueue = true
                end
            end
        end
    end
    local pd = self.pendingDeathTrinketSwap
    if pd then
        for _, s in ipairs({ slotA or 0, slotB or 0 }) do
            local key = (s == 13 and "slot1") or (s == 14 and "slot2") or nil
            if key and pd[key] then
                pd[key] = nil
                droppedBar = true
            end
        end
        if not pd.slot1 and not pd.slot2 then self.pendingDeathTrinketSwap = nil end
    end
    if droppedBar then
        if self.RefreshTrinketBarQueueBadges then self:RefreshTrinketBarQueueBadges() end
        if self.RefreshPendingTrinketIndicators then self:RefreshPendingTrinketIndicators() end
    end
    if droppedQueue and self.GearManager and self.GearManager.UpdateQueueIndicators then
        self.GearManager:UpdateQueueIndicators()
    end
end

-- Trinket swaps can be pending in three independent places at once:
-- gearSwapQueue (macro/gearset queue), pendingDeathTrinketSwap (boss-death
-- swap), and the trinketSwap rotation queue. This walks all three so
-- shift-clicking a slot actually clears whatever is really queued for it.
function RC:CancelQueuedSwapsForSlot(inventorySlot)
    local removed = 0
    local q = self.gearSwapQueue
    if q then
        for i = #q, 1, -1 do
            local e = q[i]
            if type(e) == "table" and e.inventorySlot == inventorySlot then
                table.remove(q, i)
                removed = removed + 1
            end
        end
    end
    if inventorySlot == 13 or inventorySlot == 14 then
        local pd = self.pendingDeathTrinketSwap
        local key = (inventorySlot == 13) and "slot1" or "slot2"
        if pd and pd[key] and pd[key] ~= 0 then
            pd[key] = nil
            if not pd.slot1 and not pd.slot2 then
                self.pendingDeathTrinketSwap = nil
            end
            removed = removed + 1
        else
            local ts = self.db and self.db.trinketSwap
            local q = ts and ts.queues and ts.queues[ts.currentQueue or "default"]
            local qkey = (inventorySlot == 13) and "slot1" or "slot2"
            local list = q and q[qkey]
            if type(list) == "table" and list[1] then
                self._queueFrontHidden = self._queueFrontHidden or {}
                if self._queueFrontHidden[inventorySlot] == list[1] then
                    self._queueFrontHidden[inventorySlot] = nil
                    removed = removed + 1
                    self:Print(RCL["Showing the rotation's next trinket again for that slot."])
                else
                    self._queueFrontHidden[inventorySlot] = list[1]
                    removed = removed + 1
                    self:Print(RCL["Hidden: that was the auto-swap rotation's next trinket."]
                        .. RCL[" The icon stays hidden until the rotation moves on"]
                        .. RCL[" (shift-click again to show it). The rotation list itself"]
                        .. RCL[" is never changed."])
                end
            end
        end
        if removed > 0 and self.RefreshPendingTrinketIndicators then
            self:RefreshPendingTrinketIndicators()
        end
    end
    return removed
end

function RC:QueueGearSwap(setNameOrSwapData)
    if not self.gearSwapQueue then
        self.gearSwapQueue = {}
    end

    if type(setNameOrSwapData) == "string" then
        local setName = setNameOrSwapData

        for _, queued in ipairs(self.gearSwapQueue) do
            if type(queued) == "string" and queued == setName then
                self:DebugPrint("Gear set already queued: " .. setName, "gear")
                return
            end
        end

        table.insert(self.gearSwapQueue, setName)
    if self.RefreshPendingTrinketIndicators then self:RefreshPendingTrinketIndicators() end
        self:DebugPrint("Gear swap queued: " .. setName .. " (will equip when combat ends)", "gear")

    elseif type(setNameOrSwapData) == "table" then
        local swapData = setNameOrSwapData
        table.insert(self.gearSwapQueue, swapData)
    if self.RefreshPendingTrinketIndicators then self:RefreshPendingTrinketIndicators() end

        if swapData.itemLink then
            local itemName = C_Item.GetItemNameByID(swapData.itemLink) or "item"
            self:DebugPrint("Item swap queued: " .. itemName .. " to slot " .. swapData.inventorySlot, "gear")
        end
    end

    if self.GearManager and self.GearManager.UpdateQueueIndicators then
        self.GearManager:UpdateQueueIndicators()
    end

    -- Registered once for the life of the session - ProcessGearSwapQueue
    -- (called from PLAYER_REGEN_ENABLED in Core_Events.lua) drains
    -- whatever is in gearSwapQueue every time combat ends.
    if not self.gearSwapCombatWatcher then
        self.gearSwapCombatWatcher = true
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
    end
end

function RC:ProcessGearSwapQueue()
    if not self.gearSwapQueue or #self.gearSwapQueue == 0 then
        return
    end

    self:DebugPrint("Processing " .. #self.gearSwapQueue .. " queued gear swap(s)", "gear")

    local snapshot = self.gearSwapQueue
    self.gearSwapQueue = {}

    -- Each queued swap fires 0.3s after the previous one instead of all
    -- at once, spacing out the protected equip calls right after combat
    -- ends rather than issuing a burst of them in the same frame.
    local delay = 0
    for _, queuedItem in ipairs(snapshot) do
        local capturedItem = queuedItem
        C_Timer.After(delay, function()
            if InCombatLockdown() then
                self:QueueGearSwap(capturedItem)
                self:DebugPrint("ProcessGearSwapQueue: combat re-engaged, item re-queued", "gear")
                return
            end
            if type(capturedItem) == "table" and capturedItem.display then
                return
            end
            if type(capturedItem) == "string" then
                local gs = self.gearSwapState

                if gs and gs._postSwapActiveSet
                   and gs._postSwapActiveUntil and GetTime() < gs._postSwapActiveUntil
                   and capturedItem ~= gs._postSwapActiveSet then
                    self:DebugPrint("ProcessGearSwapQueue: skipped stale queued set '" .. capturedItem .. "' - post-combat swap to '" .. tostring(gs._postSwapActiveSet) .. "' is in flight", "gear")
                    return
                end

                if gs and gs.postCombatSet and gs.postCombatSet ~= ""
                   and capturedItem == gs.lastEquippedSet
                   and capturedItem ~= gs.postCombatSet
                   and self.IsEngagedBossAlive and not self:IsEngagedBossAlive() then
                    self:DebugPrint("ProcessGearSwapQueue: skipped stale combat set '" .. capturedItem .. "' - boss dead with post-combat set '" .. tostring(gs.postCombatSet) .. "' armed", "gear")
                    return
                end

                self:EquipGearSet(capturedItem)
            elseif type(capturedItem) == "table" then
                self:ExecuteQueuedItemSwap(capturedItem)
            end
        end)
        delay = delay + 0.3
    end

    C_Timer.After(delay + 0.5, function()
        if self.GearManager and self.GearManager.UpdateQueueIndicators then
            self.GearManager:UpdateQueueIndicators()
        end
    end)
end

function RC:ExecuteQueuedItemSwap(swapData)
    if not swapData then return end

    if InCombatLockdown() then
        self:DebugPrint("Still in combat - cannot execute swap", "gear")
        return
    end
    -- a better reason may already be in the window (the set or step that queued it)
    if self.NoteSwapIntent then self:NoteSwapIntent(RCL["Queued gear swap"], nil, true) end

    -- a queued bag slot is checked against the item that was meant to be
    -- there (and found again if the bags moved during the fight); an
    -- unequip only goes to a bag that takes gear
    local E = RC.Equip
    if swapData.bag and swapData.slot and swapData.inventorySlot then
        local wantId = swapData.itemLink and tonumber(tostring(swapData.itemLink):match("item:(%d+)"))
        local ok, why = E:BagToSlot(swapData.bag, swapData.slot, swapData.inventorySlot,
            { by = "queue", wantId = wantId, cursor = "backpack" })
        self:DebugPrint("Executed queued swap: " .. (ok and "ok" or tostring(why)), "gear")
    elseif swapData.fromSlot and swapData.toSlot then
        local ok, why = E:SlotToSlot(swapData.fromSlot, swapData.toSlot, { by = "queue" })
        self:DebugPrint("Executed queued slot swap: " .. swapData.fromSlot .. " <-> " .. swapData.toSlot
            .. (ok and "" or (" (" .. tostring(why) .. ")")), "gear")
    elseif swapData.inventorySlot and swapData.unequip then
        local ok, why = E:Unequip(swapData.inventorySlot, nil, nil, { by = "queue" })
        self:DebugPrint("Executed queued unequip from slot " .. swapData.inventorySlot
            .. (ok and "" or (" (" .. tostring(why) .. ")")), "gear")
    end
end

function RC:EquipItemRackSet(setName, attemptNumber)
    if not setName or setName == "" then
        self:DebugPrint("ERROR: EquipItemRackSet called with nil or empty setName", "itemrack")
        return false
    end

    if not self.itemRackIntegration.available then
        self:DebugPrint("ItemRack not available", "itemrack")
        return false
    end

    if not ItemRackUser or not ItemRackUser.Sets or not ItemRackUser.Sets[setName] then
        self:DebugPrint("ItemRack set not found: " .. setName, "itemrack")
        return false
    end

    if UnitAffectingCombat("player") then
        self:DebugPrint("In combat - queuing ItemRack swap: " .. setName, "itemrack")
        self:QueueGearSwap(setName)
        return false
    end

    local currentTime = GetTime()
    attemptNumber = attemptNumber or 1

    if attemptNumber == 1 and self.itemRackIntegration.lastGlobalSwap then
        local timeSinceLastSwap = currentTime - self.itemRackIntegration.lastGlobalSwap
        if timeSinceLastSwap < 4.0 then
            self:DebugPrint("ItemRack recently used - skipping swap", "itemrack")
            return false
        end
    end

    if attemptNumber == 1 and (currentTime - self.itemRackIntegration.lastSwap) < self.itemRackIntegration.swapCooldown then
        self:DebugPrint("Gear swap on cooldown", "itemrack")
        return false
    end

    local preSwapState = {}
    for slot, item in pairs(ItemRackUser.Sets[setName]) do
        local slotId = tonumber(slot)
        if slotId then
            local currentLink = GetInventoryItemLink("player", slotId)
            preSwapState[slotId] = currentLink
        end
    end

    if ItemRack then
    ItemRack.EquipSet(setName)
    self.itemRackIntegration.lastGlobalSwap = currentTime
elseif ItemRackOpt then
    ItemRackOpt.EquipSet(setName)
    self.itemRackIntegration.lastGlobalSwap = currentTime
else
        for slot, item in pairs(ItemRackUser.Sets[setName]) do
            if item and item ~= 0 then
                EquipItemByName(item)
            end
        end
    end

    self.itemRackIntegration.lastSwap = currentTime
    self:DebugPrint("Equipped ItemRack set: " .. setName .. " (attempt " .. attemptNumber .. ")", "itemrack")

    local retryDelay = self.itemRackIntegration.retrySystem.retryDelay
    C_Timer.After(retryDelay, function()
        if not self:VerifyGearSwap(setName, preSwapState) then
            local maxRetries = self.itemRackIntegration.retrySystem.maxRetries

            if attemptNumber < maxRetries then
                self:DebugPrint("Gear swap verification failed - retrying (" .. (attemptNumber + 1) .. "/" .. maxRetries .. ")", "itemrack")

                C_Timer.After(0.3, function()
                    self:EquipItemRackSet(setName, attemptNumber + 1)
                end)
            else
                self:DebugPrint("Gear swap failed after " .. maxRetries .. " attempts", "itemrack")
                self:Print(RCL["WARNING: Gear swap failed after "] .. maxRetries .. RCL[" attempts. Please manually equip: "] .. setName)
            end
        else
            self:DebugPrint("Gear swap verified successfully", "itemrack")
        end
    end)

    return true
end

-- ItemRack.EquipSet is fire-and-forget with no completion callback, so
-- the only way to know a swap actually landed is to re-read equipped
-- items shortly after and compare against the target set (see the
-- retryDelay timer in EquipItemRackSet above).
function RC:VerifyGearSwap(setName, preSwapState)
    if not ItemRackUser or not ItemRackUser.Sets or not ItemRackUser.Sets[setName] then
        return false
    end

    local targetSet = ItemRackUser.Sets[setName]
    local allCorrect = true
    local mismatchCount = 0

    for slot, targetItem in pairs(targetSet) do
        if targetItem and targetItem ~= 0 then
            local slotId = tonumber(slot)
            if slotId then
                local currentLink = GetInventoryItemLink("player", slotId)

                local currentItemId = currentLink and tonumber(currentLink:match("item:(%d+)"))
                local targetItemId = tonumber(targetItem)

                if not currentItemId and currentLink then
                    -- The equipped link didn't parse to an item ID. Fall back
                    -- to a name comparison; if the names don't both resolve
                    -- and match, leave currentItemId nil so this counts as a
                    -- mismatch (never assume a match from an unparseable link).
                    local currentName = GetItemInfo(currentLink)
                    local targetName = GetItemInfo(targetItem)
                    if currentName and targetName and currentName == targetName then
                        currentItemId = targetItemId
                    end
                end

                if currentItemId ~= targetItemId then
                    allCorrect = false
                    mismatchCount = mismatchCount + 1

                    local slotName = self:GetSlotName(slotId)
                    local targetItemName = GetItemInfo(targetItem) or "Unknown"
                    local currentItemName = currentLink and GetItemInfo(currentLink) or "Empty"

                    self:DebugPrint("Mismatch in " .. slotName .. ": expected " .. targetItemName .. ", found " .. currentItemName, "itemrack")
                end
            end
        end
    end

    if mismatchCount > 0 then
        self:DebugPrint("Gear swap verification: " .. mismatchCount .. " slot(s) incorrect", "itemrack")
    end

    return allCorrect
end

local SLOT_NAMES = {
    [1] = "Head",
    [2] = "Neck",
    [3] = "Shoulder",
    [5] = "Chest",
    [6] = "Waist",
    [7] = "Legs",
    [8] = "Feet",
    [9] = "Wrist",
    [10] = "Hands",
    [11] = "Finger 1",
    [12] = "Finger 2",
    [13] = "Trinket 1",
    [14] = "Trinket 2",
    [15] = "Back",
    [16] = "Main Hand",
    [17] = "Off Hand",
    [18] = "Ranged"
}

function RC:GetSlotName(slotId)
    return SLOT_NAMES[slotId] or "Slot " .. slotId
end

RC.trinketData = {
    slot1 = {
        slotId = 13,
        itemId = nil,
        name = "Trinket Slot 1",
        icon = "Interface\\Icons\\INV_Jewelry_Trinket_01",
        hasOnUse = false,
        cooldown = 0
    },
    slot2 = {
        slotId = 14,
        itemId = nil,
        name = "Trinket Slot 2",
        icon = "Interface\\Icons\\INV_Jewelry_Trinket_02",
        hasOnUse = false,
        cooldown = 0
    }
}

RC.cooldownTracker = {
    activeCooldowns = {},
    lastPotionUsed = 0,
    abilityLastUsed = {},
    potionSpellIds = {},
    potionItemIds = {}
}

