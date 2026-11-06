local RCC = _G.Readycheck
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)
local AddonName = "Readycheck"
local RC = _G[AddonName]

if not RC then
    error("Readycheck core not found!")
end

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GetInventoryItemLink = GetInventoryItemLink
local GetInventoryItemID = GetInventoryItemID
local C_Container = C_Container
local C_Timer = C_Timer
RC._gms = RC._gms or {}
local _gms = RC._gms
local GM = RC.GearManager
local C = _gms.C
------------------------------------------------------------------------
-- Readycheck - Gear Sets
-- Owns the gear set schema and the equip pipeline that applies it.
--
-- set.equip[slot] convention: a string item link is a target item; 0
-- means explicitly unequip this slot; a slot key absent from the table
-- means "leave it alone" - never touched. SaveCurrentGear always writes
-- all 20 slots (link or 0); imported/hand-edited sets are the ones that
-- can have gaps.
--
-- EquipSet/EquipSetInstant resolve weapon 16/17 cross-moves first, hand
-- every explicit-0 slot to GM_Base.lua's RunSequencedUnequips (the one
-- shared batch unequipper), then place the rest. Both queue to
-- RC:QueueGearSwap and bail under combat lockdown.
------------------------------------------------------------------------
function GM:SaveCurrentGear(setName)
    if not setName or setName == "" then return false end

    local gear = {
        equip = {},
        icon = "Interface\\Icons\\INV_Misc_QuestionMark"
    }

    for slot = 0, 19 do
        local itemLink = GetInventoryItemLink("player", slot)
        gear.equip[slot] = itemLink or 0
    end

    self.sets[setName] = gear

    self:DebugPrint("=== GEAR SET SAVED ===")
    self:DebugPrint("Set name: " .. setName)
    self:DebugPrint("self.sets IS WR.db.gearSets: " .. tostring(self.sets == RC.db.gearSets))

    local setCount = 0
    for name in pairs(self.sets) do
        setCount = setCount + 1
    end
    self:DebugPrint("Total sets in self.sets: " .. setCount)

    local charKey = RC:GetCharacterKey()
    local dbSetCount = 0
    if ReadycheckDB.characters and ReadycheckDB.characters[charKey] and ReadycheckDB.characters[charKey].gearSets then
        for name in pairs(ReadycheckDB.characters[charKey].gearSets) do
            dbSetCount = dbSetCount + 1
        end
    end
    self:DebugPrint("Total sets in ReadycheckDB.characters[charKey].gearSets: " .. dbSetCount)

    if RC and RC.SaveConfigurationToProfile then
        RC:SaveConfigurationToProfile()
    end

    return true
end

function GM:FindBagCopiesForID(itemID, need)
    local locs = {}
    if not itemID then return locs end
    RC.Bags:Each(function(bag, bagSlot, id)
        if id == itemID then
            locs[#locs + 1] = { bag = bag, slot = bagSlot }
            if need and #locs >= need then return true end
        end
    end)
    return locs
end

function GM:FindBagCopy(itemId, enchantId)
    if not itemId then return nil end
    if not enchantId then return RC.Bags:Find(itemId) end
    local anyB, anyS, hitB, hitS
    RC.Bags:Each(function(bag, sl, id)
        if id ~= itemId then return end
        local lk = C_Container.GetContainerItemLink(bag, sl)
        local eid = tonumber((lk and lk:match("item:%d+:(%d*)")) or "") or 0
        if eid == enchantId then hitB, hitS = bag, sl; return true end
        if not anyB then anyB, anyS = bag, sl end
    end)
    if hitB then return hitB, hitS end
    return anyB, anyS
end

function GM:EquipBagItemToSlot(bag, bagSlot, invSlot)
    if InCombatLockdown() then return false end
    return (RC.Equip:BagToSlot(bag, bagSlot, invSlot, { by = "gearset", cursor = "backpack" }))
end

function GM:EquipSetInstant(setName, excludeSlots)
    if not setName or setName == "" then return false end
    if InCombatLockdown() then
        RC:QueueGearSwap(setName)
        return false
    end
    local set = self.sets[setName]
    if not set or not set.equip then
        return RC:EquipGearSet(setName)
    end

    -- Resolve the 16/17 weapon swap before the generic slot loop below -
    -- otherwise both weapons would be seen as "elsewhere" targets and the
    -- generic path would try to swap them through the same slot twice.
    local crossHandled = {}
    do
        local eq16 = (not (excludeSlots and excludeSlots[16])) and set.equip[16] or nil
        local eq17 = (not (excludeSlots and excludeSlots[17])) and set.equip[17] or nil
        if eq16 then
            local wid = (eq16 ~= 0) and self:GetItemID(eq16) or nil
            if wid == GetInventoryItemID("player", 16) then eq16 = nil end
        end
        if eq17 then
            local wid = (eq17 ~= 0) and self:GetItemID(eq17) or nil
            if wid == GetInventoryItemID("player", 17) then eq17 = nil end
        end
        if eq16 or eq17 then
            local h16, h17 = self:ResolveWeaponCrossMove(eq16, eq17, setName)
            if h16 then crossHandled[16] = true end
            if h17 then crossHandled[17] = true end
        end
    end

    local fromBag  = {}
    local fromSlot = {}
    local unequips = {}
    local idWanted = {}
    for slot, targetLink in pairs(set.equip) do
        if not (excludeSlots and excludeSlots[slot]) and not crossHandled[slot] then
            local targetID = (targetLink ~= 0) and self:GetItemID(targetLink) or nil
            local curLink  = GetInventoryItemLink("player", slot)
            local curID    = curLink and self:GetItemID(curLink) or nil
            if curID ~= targetID then
                if targetLink == 0 then
                    table.insert(unequips, slot)
                else
                    local elsewhere = nil
                    for checkSlot = 0, 19 do
                        if checkSlot ~= slot then
                            local eLink = GetInventoryItemLink("player", checkSlot)
                            if eLink and self:GetItemID(eLink) == targetID then
                                local otherTarget   = set.equip[checkSlot]
                                local otherTargetID = (otherTarget and otherTarget ~= 0) and self:GetItemID(otherTarget) or nil
                                if otherTargetID ~= targetID then
                                    elsewhere = checkSlot
                                    break
                                end
                            end
                        end
                    end
                    if elsewhere then
                        table.insert(fromSlot, { slot = slot, from = elsewhere, id = targetID, link = targetLink })
                    else
                        table.insert(fromBag, { slot = slot, link = targetLink, id = targetID })
                        if targetID then idWanted[targetID] = (idWanted[targetID] or 0) + 1 end
                    end
                end
            end
        end
    end

    local dupCopies = {}
    local hadDuplicates = false
    for id, n in pairs(idWanted) do
        if n > 1 then dupCopies[id] = self:FindBagCopiesForID(id, n) end
    end
    for _, m in ipairs(fromSlot) do
        local srcLink = GetInventoryItemLink("player", m.from)
        if not (srcLink and self:GetItemID(srcLink) == m.id) then
            RC:FastEquipItem(m.link, m.slot)
        else
            local destLink = GetInventoryItemLink("player", m.slot)
            if destLink and not self:ItemFitsInvSlot(destLink, m.from) and RC.Equip:FreeBagSlot() then
                -- off to a bag that takes gear (never a herb, ammo or soul bag)
                self:SafeUnequipToSlot(m.slot)
            end
            self:SafeSwapSlotToSlot(m.from, m.slot)
        end
    end
    for _, c in ipairs(fromBag) do
        if c.id and dupCopies[c.id] then
            local list = dupCopies[c.id]
            local pref = RC.db and RC.db.itemEnchantPreference
                and RC.db.itemEnchantPreference[c.id]
            local loc
            if pref ~= nil and list then
                for li, L in ipairs(list) do
                    local lk = C_Container.GetContainerItemLink(L.bag, L.slot)
                    local eid = tonumber((lk and lk:match("item:%d+:(%d*)")) or "") or 0
                    if eid == pref then loc = table.remove(list, li) break end
                end
            end
            loc = loc or table.remove(list, 1)
            if loc then
                self:EquipBagItemToSlot(loc.bag, loc.slot, c.slot)
                hadDuplicates = true
            else
                RC:FastEquipItem(c.link, c.slot)
            end
        else
            RC:FastEquipItem(c.link, c.slot)
        end
    end
    self:RunSequencedUnequips(unequips)
    if hadDuplicates then
        C_Timer.After(0, function()
            if self.UpdateAllButtonIcons   then self:UpdateAllButtonIcons()   end
            if self.UpdateGearSetButtonIcon then self:UpdateGearSetButtonIcon() end
        end)
    end

    self.lastEquippedSetName = setName
    if self.UpdateAllButtonIcons   then self:UpdateAllButtonIcons()   end
    if self.UpdateGearSetButtonIcon then self:UpdateGearSetButtonIcon() end
    return true
end

function GM:EquipSet(setName, instant)
    local _setEx = self.queuedSetSlotExclusions
        and self.queuedSetSlotExclusions[setName]
    if _setEx then self.queuedSetSlotExclusions[setName] = nil end
    if not self.sets[setName] then
        return false
    end

    if InCombatLockdown() then
        RC:QueueGearSwap(setName)
        return false
    end

    -- The release below reads a set equip as "the player picked a different
    -- set, so the boss override is no longer wanted". Equipping the locked
    -- boss's OWN on-target set is not that: it is this addon re-asserting the
    -- boss's own gear, and it arrives here through EquipGearSet from the
    -- gear-swap queue (a set queued under combat lockdown) and from route
    -- steps, not from a player click. Tearing the lock down there leaves the
    -- trinket auto-swap rotation free to pull the boss's forceEquip trinket
    -- back out on its next 1 Hz tick.
    local _lockedBoss = RC.bossTrinketState and RC.bossTrinketState.appliedBoss
    local _isBossOwnSet = false
    if _lockedBoss and setName and setName ~= "" then
        local _raid = RC.bossTrinketState.appliedRaid
                      or (RC.GetEffectiveRaidName and RC:GetEffectiveRaidName())
        local _rp = _raid and RC.GetActiveRaidProfile and RC:GetActiveRaidProfile(_raid)
        local _cfg = _rp and _rp.bosses and _rp.bosses[_lockedBoss]
        local _gs = _cfg and _cfg.abilities and _cfg.abilities.gearswap
        local _bossSet = _gs and (_gs.gearSet or _gs.itemRackSet)
        _isBossOwnSet = (_bossSet ~= nil) and (_bossSet ~= "") and (_bossSet == setName)
    end

    if _isBossOwnSet then
        RC:DebugPrint("Boss trinket lock kept: '" .. tostring(setName)
            .. "' is " .. tostring(_lockedBoss) .. "'s own on-target set", "trinket")
    elseif RC.bossTrinketState and RC.bossTrinketState.appliedBoss
       and RC.ReleaseBossTrinketLock and not UnitAffectingCombat("player") then
        RC:ReleaseBossTrinketLock("manual set change: " .. tostring(setName))
        if RC.gearSwapState then
            RC.gearSwapState.postCombatSet   = nil
            RC.gearSwapState.lastEquippedSet = nil
            RC.gearSwapState.engagedInCombat = nil
            RC.gearSwapState.engagedBossGUID = nil
            RC.gearSwapState.lastBossTarget  = nil
        end
    end

    if self.settings.equipToggle and self:IsSetEquipped(setName) then
        return false
    end

    local set = self.sets[setName]
    if not set.equip then
        return false
    end

    -- The one "put targetLink into slot" primitive, previously copy-pasted
    -- five times through this function. targetLink == 0 means unequip into
    -- the first free bag slot; otherwise look for the item already worn in
    -- another slot first, then in the bags.
    -- opts (all optional) carries the extra rules only the serialized
    -- special-slot pass needs:
    --   skipCheckSlot(checkSlot, targetID) -> true to ignore an equipped slot
    --   skipBagSlot(bagKey)                -> true to ignore a bag slot
    --   onBagUsed(bagKey)                  -> called after a bag slot is consumed
    --   debugNotFound                      -> log when nothing was found
    -- Returns true when something was placed or unequipped.
    local function PlaceItemInSlot(slot, targetLink, opts)
        if targetLink == 0 then
            if GetInventoryItemLink("player", slot) and RC.Equip:FreeBagSlot() then
                self:SafeUnequipToSlot(slot)
                return true
            end
            return false
        end

        local targetID = self:GetItemID(targetLink)
        local found = false

        for checkSlot = 0, 19 do
            if checkSlot ~= slot then
                local skipThisSlot = false
                if opts and opts.skipCheckSlot then
                    skipThisSlot = opts.skipCheckSlot(checkSlot, targetID) and true or false
                end

                if not skipThisSlot then
                    local equippedLink = GetInventoryItemLink("player", checkSlot)
                    if equippedLink and self:GetItemID(equippedLink) == targetID then
                        self:SafeSwapSlotToSlot(checkSlot, slot)
                        found = true
                        break
                    end
                end
            end
        end

        if not found then
            RC.Bags:Each(function(bag, bagSlot, id)
                if id ~= targetID then return end
                local bagKey = bag .. "_" .. bagSlot
                if opts and opts.skipBagSlot and opts.skipBagSlot(bagKey) then return end
                self:SafeSwapBagToSlot(bag, bagSlot, slot, C_Container.GetContainerItemLink(bag, bagSlot))
                if opts and opts.onBagUsed then opts.onBagUsed(bagKey) end
                found = true
                return true
            end)
        end

        if not found and opts and opts.debugNotFound then
            GM:DebugPrint("Slot " .. slot .. ": Item not found in bags")
        end

        return found
    end

    local swapList = {}
    for slot, targetLink in pairs(set.equip) do
        if _setEx and _setEx[slot] then
            targetLink = nil
        end
        local targetID = (targetLink ~= 0) and self:GetItemID(targetLink) or nil
        local currentLink = GetInventoryItemLink("player", slot)
        local currentID = currentLink and self:GetItemID(currentLink)

        if currentID ~= targetID then
            swapList[slot] = targetLink
        end
    end

    do
        local handled16, handled17 = self:ResolveWeaponCrossMove(swapList[16], swapList[17], setName)
        if handled16 then swapList[16] = nil end
        if handled17 then swapList[17] = nil end
    end

    do
        local unequips = {}
        for slot, targetLink in pairs(swapList) do
            if targetLink == 0 then
                table.insert(unequips, slot)
                swapList[slot] = nil
            end
        end
        self:RunSequencedUnequips(unequips)
    end

    local regularSlots = {}
    local specialSlots = {}
    local shirtSlot = nil

    local weapon16 = swapList[16]
    local weapon17 = swapList[17]
    local needWeaponDelay = false

    -- Equipping the same item id into both weapon slots in one pass can
    -- have the second PickupInventoryItem grab back the first one before
    -- it settles - route this case through specialSlots for serialization.
    if weapon16 and weapon17 and weapon16 ~= 0 and weapon17 ~= 0 then
        local id16 = self:GetItemID(weapon16)
        local id17 = self:GetItemID(weapon17)
        if id16 == id17 then
            needWeaponDelay = true
        end
    end

    -- Per-set flag, with the old hardcoded personal set name kept as the
    -- fallback so existing saved sets behave exactly as before.
    local equipShirtWithT2
    if set.equipShirtWithT2 ~= nil then
        equipShirtWithT2 = set.equipShirtWithT2 and true or false
    else
        equipShirtWithT2 = (setName == "Battle Shout")
    end

    for slot, targetLink in pairs(swapList) do
        if instant then
            if slot == 4 and targetLink ~= 0 then
                shirtSlot = targetLink
            else
                table.insert(regularSlots, {slot = slot, link = targetLink})
            end
        elseif slot == 11 or slot == 12 or slot == 13 or slot == 14 then
            table.insert(specialSlots, {slot = slot, link = targetLink})
        elseif slot == 16 or slot == 17 then
            if needWeaponDelay then
                table.insert(specialSlots, {slot = slot, link = targetLink})
            else
                table.insert(regularSlots, {slot = slot, link = targetLink})
            end
        elseif slot == 4 then
            if targetLink == 0 then
                table.insert(regularSlots, {slot = 4, link = targetLink})
            elseif equipShirtWithT2 then
                table.insert(regularSlots, {slot = 4, link = targetLink})
            else
                shirtSlot = targetLink
            end
        else
            table.insert(regularSlots, {slot = slot, link = targetLink})
        end
    end

    table.sort(specialSlots, function(a, b) return a.slot < b.slot end)
    table.sort(regularSlots, function(a, b) return a.slot < b.slot end)

    for _, data in ipairs(regularSlots) do
        local slot = data.slot
        local targetLink = data.link

        PlaceItemInSlot(slot, targetLink)
    end

    -- Rings, trinkets, and same-id-in-both-hands weapon swaps are processed
    -- one at a time via ProcessNextSpecialSlot instead of all at once - firing
    -- PickupInventoryItem for both ring slots in the same frame lets the
    -- client's cursor state clobber itself and drop an item.
    if #specialSlots > 0 then
        local currentIndex = 1
        local usedBagSlots = {}
        local processedSlots = {}

        local function ProcessNextSpecialSlot()
            if currentIndex > #specialSlots then
                self:UpdateAllButtonIcons()
                self:UpdateGearSetButtonIcon()
                return
            end

            local data = specialSlots[currentIndex]
            local slot = data.slot
            local targetLink = data.link
            local isLastSlot = (currentIndex == #specialSlots)
            currentIndex = currentIndex + 1

            if isLastSlot and shirtSlot then
                local shirtSlotNum = 4
                local shirtTargetLink = shirtSlot

                -- delayShirt: whether the shirt swap has to wait for the
                -- special-slot swap in front of it to settle. Per-set flag
                -- when present, otherwise the legacy set-name behaviour so
                -- existing sets are unchanged.
                local delayShirt
                if set.delayShirt ~= nil then
                    delayShirt = set.delayShirt and true or false
                else
                    delayShirt = (setName ~= "Diamond Flask")
                end

                if not delayShirt then
                    PlaceItemInSlot(shirtSlotNum, shirtTargetLink)
                else
                    C_Timer.After(0.3, function()
                        PlaceItemInSlot(shirtSlotNum, shirtTargetLink)
                    end)
                end
            end

            if targetLink == 0 then
                PlaceItemInSlot(slot, targetLink)
                processedSlots[slot] = true
                local delay = (slot == 11 or slot == 12) and 0.5 or 0.1
                C_Timer.After(delay, ProcessNextSpecialSlot)
            else
                local targetID = self:GetItemID(targetLink)
                local currentLink = GetInventoryItemLink("player", slot)
                local currentID = currentLink and self:GetItemID(currentLink)

                if currentID == targetID then
                    processedSlots[slot] = true
                    ProcessNextSpecialSlot()
                else
                    local isWeaponSlot = (slot == 16 or slot == 17)

                    PlaceItemInSlot(slot, targetLink, {
                        -- Don't steal back a weapon this pass already
                        -- placed, and don't pull an item out of a slot the
                        -- same set wants it in.
                        skipCheckSlot = function(checkSlot, targetID)
                            if isWeaponSlot and (checkSlot == 16 or checkSlot == 17)
                               and processedSlots[checkSlot] then
                                return true
                            end
                            local otherTarget   = set.equip[checkSlot]
                            local otherTargetID = (otherTarget and otherTarget ~= 0) and self:GetItemID(otherTarget) or nil
                            return otherTargetID == targetID
                        end,
                        -- Two weapon slots wanting the same item id must
                        -- not both consume the same bag slot.
                        skipBagSlot = function(bagKey)
                            return isWeaponSlot and usedBagSlots[bagKey]
                        end,
                        onBagUsed = function(bagKey)
                            if isWeaponSlot then
                                usedBagSlots[bagKey] = true
                            end
                        end,
                        debugNotFound = true,
                    })

                    processedSlots[slot] = true
                    local delay = (slot == 11 or slot == 12) and 0.5 or 0.1
                    C_Timer.After(delay, ProcessNextSpecialSlot)
                end
            end
        end

        ProcessNextSpecialSlot()
    else
        if shirtSlot then
            -- Same per-set delayShirt flag as the special-slot path above,
            -- with its own legacy set-name fallback for this branch.
            local delayShirt
            if set.delayShirt ~= nil then
                delayShirt = set.delayShirt and true or false
            else
                delayShirt = (setName == "Battle Shout" or setName == "Diamond Flask")
            end

            local shirtDelay = delayShirt and 0.3 or 0

            C_Timer.After(shirtDelay, function()
                PlaceItemInSlot(4, shirtSlot)
            end)
        end

        C_Timer.After(0.5, function()
            self:UpdateAllButtonIcons()
            self:UpdateGearSetButtonIcon()
        end)
    end

    if set.showHelm ~= nil then
        ShowHelm(set.showHelm and true or false)
        self:DebugPrint("showHelm=" .. (set.showHelm and "1" or "0") .. " for: " .. setName, "gear")
    end
    if set.showCloak ~= nil then
        ShowCloak(set.showCloak and true or false)
        self:DebugPrint("showCloak=" .. (set.showCloak and "1" or "0") .. " for: " .. setName, "gear")
    end

    self.lastEquippedSetName = setName
    self.settings.lastEquippedSetName = setName
    if self.SaveSettings then self:SaveSettings() end
    self:DebugPrint("Set lastEquippedSetName to: " .. setName)

    return true
end

function GM:ToggleSet(setName)
    if not self.sets[setName] then
        return false
    end

    if self:IsSetEquipped(setName) then
        return false
    else
        return self:EquipSet(setName)
    end
end

function GM:IsSetEquipped(setName)
    if not self.sets[setName] then return false end

    local set = self.sets[setName]
    if not set.equip then return false end

    for slot, itemLink in pairs(set.equip) do
        local equippedLink = GetInventoryItemLink("player", slot)

        if itemLink == 0 then
            if equippedLink then
                return false
            end
        elseif itemLink and equippedLink then
            local setItemID = self:GetItemID(itemLink)
            local equippedItemID = self:GetItemID(equippedLink)
            if setItemID ~= equippedItemID then
                return false
            end
        elseif itemLink and not equippedLink then
            return false
        end
    end
    return true
end

function GM:GetCurrentEquippedSet()
    if self.lastEquippedSetName and self.sets[self.lastEquippedSetName] then
        if self:IsSetEquipped(self.lastEquippedSetName) then
            return self.lastEquippedSetName
        end
        if self:IsSetPartiallyEquipped(self.lastEquippedSetName, 0.5, true) then
            return self.lastEquippedSetName
        end
    end

    for setName, set in pairs(self.sets) do
        if self:IsSetEquipped(setName) then
            return setName
        end
    end

    -- Only guess a fuzzy match when nothing is exactly equipped, and only
    -- if it is a near-perfect match (>90%) - a looser threshold would
    -- mislabel casual gear as a set the player never actually put on.
    local bestMatch = nil
    local bestScore = 0.9
    for setName, set in pairs(self.sets) do
        local score = self:GetSetMatchScore(setName, true)
        if score > bestScore then
            bestScore = score
            bestMatch = setName
        end
    end
    if bestMatch then
        return bestMatch
    end

    if self.lastEquippedSetName and self.sets[self.lastEquippedSetName] then
        return self.lastEquippedSetName
    end

    return nil
end

function GM:GetSetMatchScore(setName, excludeAutoSwapSlots)
    if not self.sets[setName] then return 0 end
    local set = self.sets[setName]
    if not set.equip then return 0 end

    -- Trinkets are excluded from match/completion scoring here: the
    -- trinket swap system changes 13/14 independently of any saved set,
    -- so counting them would mark an otherwise-correct set as "not
    -- equipped" whenever an automated trinket swap is in progress.
    local autoSwapSlots = {
        [13] = true,
        [14] = true,
    }

    local total = 0
    local matched = 0

    for slot, itemLink in pairs(set.equip) do
        if not (excludeAutoSwapSlots and autoSwapSlots[slot]) then
            total = total + 1
            local equippedLink = GetInventoryItemLink("player", slot)
            if itemLink == 0 then
                if not equippedLink then matched = matched + 1 end
            elseif itemLink and equippedLink then
                local setItemID = self:GetItemID(itemLink)
                local equippedItemID = self:GetItemID(equippedLink)
                if setItemID and setItemID == equippedItemID then
                    matched = matched + 1
                end
            end
        end
    end

    if total == 0 then return 0 end
    return matched / total
end

function GM:IsSetPartiallyEquipped(setName, threshold, excludeAutoSwapSlots)
    if not self.sets[setName] then return false end

    local set = self.sets[setName]
    if not set.equip then return false end

    -- Same trinket exclusion as GetSetMatchScore above.
    local autoSwapSlots = {
        [13] = true,
        [14] = true,
    }

    local totalItems = 0
    local matchingItems = 0

    for slot, itemLink in pairs(set.equip) do
        if excludeAutoSwapSlots and autoSwapSlots[slot] then
        else
            totalItems = totalItems + 1
            local equippedLink = GetInventoryItemLink("player", slot)

            if itemLink == 0 then
                if not equippedLink then
                    matchingItems = matchingItems + 1
                end
            elseif itemLink and equippedLink then
                local setItemID = self:GetItemID(itemLink)
                local equippedItemID = self:GetItemID(equippedLink)
                if setItemID and setItemID == equippedItemID then
                    matchingItems = matchingItems + 1
                end
            end
        end
    end

    if totalItems == 0 then return true end
    return (matchingItems / totalItems) >= threshold
end

function GM:IsSetComplete(setName)
    local set = self.sets[setName]
    if not set or not set.equip then return true end
    local equippedCount = {}
    for slot = 0, 19 do
        local link = GetInventoryItemLink("player", slot)
        local id = link and self:GetItemID(link)
        if id then equippedCount[id] = (equippedCount[id] or 0) + 1 end
    end
    local need = {}
    for _, targetLink in pairs(set.equip) do
        if targetLink and targetLink ~= 0 then
            local id = self:GetItemID(targetLink)
            if id then need[id] = (need[id] or 0) + 1 end
        end
    end
    for id, n in pairs(need) do
        local have = (GetItemCount(id) or 0) + (equippedCount[id] or 0)
        if have < n then return false end
    end
    return true
end

-- The status of a set as the gear set button shows it: red = pieces
-- missing from your bags, gold = not all on, green = worn; nil = no set.
function GM:SetStatusColor(setName)
    if not setName then return nil end
    if not self:IsSetComplete(setName) then return C.red end
    if not self:IsSetEquipped(setName) then return C.gold end
    return C.green
end

-- Paints that status on a gear set button (the live one or a preview
-- sample): the name in the status colour (white when worn) and the ring.
function GM:PaintSetStatus(button, col)
    if button.nameText and self.settings.showGearSetName ~= false and col then
        local t = (col == C.green) and self:LookColor("nameColor", "text", "white") or col
        button.nameText:SetTextColor(t.r or t[1], t.g or t[2], t.b or t[3], t.a or t[4] or 1)
    end
    if self.settings.showGearSetStatusBorder == false then
        if button.statusBorder then
            for _, tex in pairs(button.statusBorder) do tex:Hide() end
        end
        return
    end
    -- Sublevel 1: the button's own black border sits in OVERLAY 0 and
    -- the hover border in OVERLAY 2, so the status ring has to be
    -- explicitly between them. Left on the default sublevel it shared
    -- OVERLAY 0 with the black border and which one won came down to
    -- creation order. Re-check .top rather than the table itself -
    -- CreateSimpleBorder returns an empty table if its frame guard
    -- fails, and caching that would block every later retry.
    if (not button.statusBorder or not button.statusBorder.top)
       and RC.UI and RC.UI.CreateSimpleBorder then
        local made = RC.UI:CreateSimpleBorder(button, math.max(1, button.borderWidth or 1), 1)
        if made and made.top then button.statusBorder = made end
    end
    if button.statusBorder and button.statusBorder.top then
        for _, tex in pairs(button.statusBorder) do
            if col then
                tex:SetColorTexture(col[1], col[2], col[3], col[4])
                tex:Show()
            else
                tex:Hide()
            end
        end
    end
end

function GM:ScheduleGearSetStatusRefresh()
    if self._gearSetStatusPending then return end
    self._gearSetStatusPending = true
    C_Timer.After(0.4, function()
        GM._gearSetStatusPending = false
        local button = GM.buttons[999]
        if not button then return end
        GM:PaintSetStatus(button, GM:SetStatusColor(GM:GetCurrentEquippedSet()))
    end)
end

function GM:ScheduleEquipmentRefresh()
    if self._equipRefreshTimer then
        self._equipRefreshTimer:Cancel()
    end
    self._equipRefreshTimer = C_Timer.NewTimer(0.2, function()
        GM._equipRefreshTimer = nil
        GM:UpdateAllButtonIcons()
        GM:UpdateGearSetButtonIcon()
        GM:UpdateButtonCooldowns()
        if CharacterFrame and CharacterFrame:IsShown() then
            GM:UpdateCharacterSlotNames()
        end
    end)
end

-- The gear-set button is just button 999, and GM:UpdateButtonIcon
-- (GM_Buttons.lua) already owns the icon/name refresh for it. This entry
-- point stays because a dozen call sites - plus core's Equip_GMConfig -
-- use it by name; it used to carry a second, drifting copy of that code.
function GM:UpdateGearSetButtonIcon()
    if self.UpdateButtonIcon then
        self:UpdateButtonIcon(999)
    end
end

-- Does not clear cross-references to this name: settings.lastEquippedSetName,
-- fungalBloomActiveSet/fungalBloomSet, per-set keybinds (SetBinding stays
-- registered), or pinned buttons of kind "set". Callers relying on those
-- after a delete/rename must clean them up themselves.
function GM:DeleteSet(setName)
    self.sets[setName] = nil

    if RC and RC.SaveConfigurationToProfile then
        RC:SaveConfigurationToProfile()
    end

    self:DebugPrint("Deleted set: " .. setName)
    return true
end

function GM:GetSetNames()
    local names = {}
    for name in pairs(self.sets) do
        table.insert(names, name)
    end
    table.sort(names)
    return names
end

function GM:LoadSets()
    self:DebugPrint("=== LoadSets START ===")

    local dbSetCount = 0
    if RC.db.gearSets then
        for setName in pairs(RC.db.gearSets) do
            dbSetCount = dbSetCount + 1
            self:DebugPrint("Found set in WR.db.gearSets: " .. setName)
        end
    end
    self:DebugPrint("Total sets in WR.db.gearSets: " .. dbSetCount)

    if not RC.db.gearSets then
        RC.db.gearSets = {}
    end

    self.sets = RC.db.gearSets

    self:DebugPrint("Loaded " .. self:GetTableSize(self.sets) .. " gear sets from character profile (DIRECT REFERENCE)")
end

function GM:RestoreButtonsFromProfile()
    if InCombatLockdown() then
        self:DebugPrint("RestoreButtonsFromProfile deferred - in combat lockdown")
        if not self.pendingRestoreButtons then
            self.pendingRestoreButtons = true
            local frame = CreateFrame("Frame")
            frame:RegisterEvent("PLAYER_REGEN_ENABLED")
            frame:SetScript("OnEvent", function(f)
                f:UnregisterAllEvents()
                self.pendingRestoreButtons = nil
                self:RestoreButtonsFromProfile()
            end)
        end
        return
    end

    if not RC or not RC.db then
        self:Print(RCL["ERROR: Cannot restore buttons - WR.db is nil"])
        return
    end

    if not RC.db.gearButtons then
        RC.db.gearButtons = {}
    end

    for slot in pairs(RC.db.gearButtons) do
        if type(slot) == "number" and slot >= 1000 and not self:GetPinnedDef(slot) then
            RC.db.gearButtons[slot] = nil
            if RC.db.gearButtonPositions then RC.db.gearButtonPositions[slot] = nil end
            self:DebugPrint("Pruned pinned button " .. slot .. " (no definition)")
        end
    end

    local buttonCount = 0
    for slot, active in pairs(RC.db.gearButtons) do
        if active then
            buttonCount = buttonCount + 1
        end
    end

    self:DebugPrint("RestoreButtonsFromProfile called - Found " .. buttonCount .. " buttons to restore")

    if not self.enabled then
        self:DebugPrint("GearManager disabled - skipping button restoration")
        return
    end

    if buttonCount == 0 then
        self:DebugPrint("No buttons to restore")
        return
    end

    self._restoringButtons = true

    self:DebugPrint("Restoring " .. buttonCount .. " dockable menu buttons...")

    local independent = {}
    local dependent = {}

    for slot, active in pairs(RC.db.gearButtons) do
        if active then
            local pos = RC.db.gearButtonPositions and RC.db.gearButtonPositions[slot]
            if pos and pos.dockTo then
                table.insert(dependent, slot)
                self:DebugPrint("Slot " .. slot .. " is docked to slot " .. pos.dockTo)
            else
                table.insert(independent, slot)
                self:DebugPrint("Slot " .. slot .. " is independent")
            end
        end
    end

    local restoredCount = 0
    local skippedCount = 0

    self:DebugPrint("PHASE 1: Creating " .. #independent .. " independent buttons")
    for _, slot in ipairs(independent) do
        if self.buttons[slot] then
            self:DebugPrint("Button " .. slot .. " already exists - ensuring visible")
            self.buttons[slot]:Show()
            skippedCount = skippedCount + 1
        else
            self:DebugPrint("Creating independent button for slot " .. slot)
            self:CreateButton(slot)
            restoredCount = restoredCount + 1
        end
    end

    self:DebugPrint("PHASE 2: Creating " .. #dependent .. " dependent buttons")

    local maxPasses = 10
    local remainingButtons = {}
    for _, slot in ipairs(dependent) do
        table.insert(remainingButtons, slot)
    end

    for pass = 1, maxPasses do
        if #remainingButtons == 0 then break end

        self:DebugPrint("Pass " .. pass .. ": " .. #remainingButtons .. " buttons remaining")
        local stillRemaining = {}

        for _, slot in ipairs(remainingButtons) do
            local pos = RC.db.gearButtonPositions[slot]
            local parentExists = pos and pos.dockTo and self.buttons[pos.dockTo]

            if parentExists then
                if self.buttons[slot] then
                    self:DebugPrint("Button " .. slot .. " already exists - ensuring visible")
                    self.buttons[slot]:Show()
                    skippedCount = skippedCount + 1
                else
                    self:DebugPrint("Creating dependent button " .. slot .. " (parent " .. pos.dockTo .. " exists)")
                    self:CreateButton(slot)
                    restoredCount = restoredCount + 1
                end
            else
                self:DebugPrint("Parent for button " .. slot .. " doesn't exist yet, deferring...")
                table.insert(stillRemaining, slot)
            end
        end

        remainingButtons = stillRemaining
    end

    -- Whatever is left points at a parent that is not coming back.
    -- LoadButtonPosition drops the stale link and stands the button at
    -- its last known spot, so it still comes back instead of vanishing.
    for _, slot in ipairs(remainingButtons) do
        self:DebugPrint("Parent for button " .. slot .. " is gone - restoring it standalone")
        if not self.buttons[slot] then
            self:CreateButton(slot)
            restoredCount = restoredCount + 1
        end
    end

    C_Timer.After(0.2, function()
        self._restoringButtons = false

        local visibleCount = 0
        for slot in pairs(self.buttons) do
            self:UpdateButtonIcon(slot)
            if self.buttons[slot]:IsShown() then
                visibleCount = visibleCount + 1
            end
        end
        self:UpdateAllLockIcons()
        self:UpdateButtonsMouseoverFade()
        self:DebugPrint("Restoration complete: " .. restoredCount .. " created, " .. skippedCount .. " already existed, " .. visibleCount .. " visible")

        self:StartButtonCooldownUpdates()
        self:UpdateButtonCooldowns()

        if RC and RC.SaveConfigurationToProfile then
            RC:SaveConfigurationToProfile()
            GM:DebugPrint("RestoreButtonsFromProfile: single consolidated save complete")
        end
    end)
end

function GM:Enable()
    self.enabled = true
    if RC.db and RC.db.gearManager then
        RC.db.gearManager.enabled = true
    end
    self:SaveSettings()

    self:RestoreButtonsFromProfile()

    self:DebugPrint("Gear Manager ENABLED")
end

function GM:Disable()
    self.enabled = false
    if RC.db and RC.db.gearManager then
        RC.db.gearManager.enabled = false
    end
    self:SaveSettings()

    if InCombatLockdown() then
        self:DebugPrint("Button hiding deferred - in combat lockdown")
        local frame = CreateFrame("Frame")
        frame:RegisterEvent("PLAYER_REGEN_ENABLED")
        frame:SetScript("OnEvent", function(f)
            f:UnregisterAllEvents()
            if self.buttons then
                for slot, button in pairs(self.buttons) do
                    if button then
                        button:Hide()
                    end
                end
            end
            if self.menus then
                for slot, menu in pairs(self.menus) do
                    if menu then
                        menu:Hide()
                    end
                end
            end
        end)
    else
        if self.buttons then
            for slot, button in pairs(self.buttons) do
                if button then
                    button:Hide()
                end
            end
        end

        if self.menus then
            for slot, menu in pairs(self.menus) do
                if menu then
                    menu:Hide()
                end
            end
        end
    end

    self:DebugPrint("Gear Manager DISABLED")
end
