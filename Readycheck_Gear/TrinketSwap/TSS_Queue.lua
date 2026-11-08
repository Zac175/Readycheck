------------------------------------------------------------------------
-- Readycheck - Trinket Swap Queue and State
-- Owns per-slot trinket state (cooldown/buff/lockout classification),
-- active-queue lookup, the config-driven best-pick scorer, and the
-- SwapTrinket primitive that actually performs an equip.
-- Queue position is the priority order; see ProcessTrinketRotation in
-- TSS_Combat.lua for how a ready trinket is chosen against it.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)

local ipairs, tostring = ipairs, tostring
local math_floor = math.floor
local GetTime = GetTime
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local GetInventoryItemID = GetInventoryItemID
local GetInventoryItemCooldown = GetInventoryItemCooldown
local InCombatLockdown = InCombatLockdown
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local C_Container = C_Container
local C_Timer = C_Timer
local WRF = _G.Readycheck
if not WRF then return end
WRF._tssInit = WRF._tssInit or {}
WRF._tss = WRF._tss or {}
WRF._tssInit[#WRF._tssInit + 1] = function()
    local RC = _G.Readycheck
    local _tss = WRF._tss
    local SLOT_KEYS, INVENTORY_SLOTS = _tss.SLOT_KEYS, _tss.INVENTORY_SLOTS
    local PRE_EQUIP_WINDOW = _tss.PRE_EQUIP_WINDOW or 33
    function RC:RefreshTrinketScan()
        self.trinketSwapSystem.lastScanTime = 0
        self.trinketSwapSystem.bagLocationLookup = {}
        return self:ScanAvailableTrinkets()
    end

    local onUseCache = {}

    function RC:IsTrinketOnUse(itemId)
        if not itemId then return false end
        if RC.onUseTrinkets and RC.onUseTrinkets[itemId] == true then return true end
        if RC.TrinketScanner and RC.TrinketScanner.autoDetectedTrinkets then
            local data = RC.TrinketScanner.autoDetectedTrinkets[itemId]
            if data then return data.isOnUse == true end
        end
        local cached = onUseCache[itemId]
        if cached ~= nil then return cached end
        local result = GetItemSpell(itemId) ~= nil
        onUseCache[itemId] = result
        return result
    end

    function RC:GetActiveQueue(slotNumber)
        if not self.db.trinketSwap.queues then
            self.db.trinketSwap.queues = {default = {slot1 = {}, slot2 = {}}}
        end

        local context = self.trinketSwapSystem.currentQueue or "default"
        local slotKey = SLOT_KEYS[slotNumber]

        if not self.db.trinketSwap.queues[context] then
            self.db.trinketSwap.queues[context] = {slot1 = {}, slot2 = {}}
        end

        local queue = self.db.trinketSwap.queues[context][slotKey]
        if not queue or #queue == 0 then
            if not self.db.trinketSwap.queues.default then
                self.db.trinketSwap.queues.default = {slot1 = {}, slot2 = {}}
            end
            queue = self.db.trinketSwap.queues.default[slotKey] or {}
        end

        return queue, context
    end

    -- HOW IT PICKS (2026-10-23, Zac: "do prio system or list and give user
    -- the option and maybe allow users to change prio of trinkets instead
    -- of hardcoded numbers"). trinketSwap.order:
    --   "priority"  (default - how it has always picked) each trinket's
    --               priority number, highest first; the lists still say
    --               which trinkets may go in which slot, and equal
    --               numbers keep list order
    --   "list"      each slot's list, top to bottom - only once the player
    --               has picked it (orderPicked), so a "list" that only ever
    --               came in as a default never changes how it picks
    -- trinketSwap.priorities[itemId] is the player's number; without one a
    -- trinket uses Readycheck's suggestion (RC.trinketSwapPriority), else
    -- 50 for an on-use trinket and 10 for a passive one.
    function RC:TrinketPriority(itemId)
        local ts = self.db and self.db.trinketSwap
        local own = ts and ts.priorities and tonumber(ts.priorities[itemId])
        if own then return own end
        local sug = RC.trinketSwapPriority and RC.trinketSwapPriority[itemId]
        if sug then return sug end
        return self:IsTrinketOnUse(itemId) and 50 or 10
    end

    function RC:TrinketOrderIsPriority()
        local ts = self.db and self.db.trinketSwap
        if not ts then return true end
        return not (ts.order == "list" and ts.orderPicked)
    end

    -- The slot's trinkets in the order they are tried: the list as it is,
    -- or sorted by priority number. A copy in priority mode, so the saved
    -- list itself never changes order.
    function RC:GetRankedQueue(slotNumber)
        local queue, context = self:GetActiveQueue(slotNumber)
        if not (queue and #queue > 1 and self:TrinketOrderIsPriority()) then return queue, context end
        local out, pos = {}, {}
        for i, id in ipairs(queue) do
            out[i] = id
            if not pos[id] then pos[id] = i end
        end
        table.sort(out, function(a, b)
            local pa, pb = self:TrinketPriority(a), self:TrinketPriority(b)
            if pa ~= pb then return pa > pb end
            return (pos[a] or 0) < (pos[b] or 0)
        end)
        return out, context
    end

    function RC:SetActiveQueue(queueName)
        if not self.trinketSwapSystem.queueNames[queueName] then return false end

        local previousQueue = self.trinketSwapSystem.currentQueue
        self.trinketSwapSystem.currentQueue = queueName
        self.db.trinketSwap.currentQueue = queueName
        if self.RefreshPendingTrinketIndicators then
            self:RefreshPendingTrinketIndicators()
        end

        self:DebugPrint("Switched to queue: " .. self.trinketSwapSystem.queueNames[queueName], "trinket")

        if self.trinketToggleButton and self.trinketToggleButton.UpdateButtonState then
            self.trinketToggleButton.UpdateButtonState()
        end

        self:SaveConfigurationToProfile()

        if previousQueue ~= queueName and not InCombatLockdown() then
            if self.db.trinketSwap.enabled and self.db.trinketSwap.autoSwapActive == nil then
                self.db.trinketSwap.autoSwapActive = true
                self:SaveConfigurationToProfile()
            end

            if self.db.trinketSwap.enabled and self.db.trinketSwap.autoSwapActive then
                C_Timer.After(0.2, function()
                    RC:EquipTrinketsFromConfig(true)
                end)
            else
                self:DebugPrint("Config changed but auto-swap disabled - not swapping trinkets", "trinket")
            end
        end

        return true
    end

    function RC:EquipTrinketsFromConfig(forceSwap)
        if InCombatLockdown() then
            self:DebugPrint("Config swap blocked - in combat", "trinket")
            return
        end
        if self:IsEquipBlockedNonCombat() then
            self:DebugPrint("Config swap deferred - casting/channeling", "trinket")
            return
        end

        self:DebugPrint("EquipTrinketsFromConfig called (force=" .. tostring(forceSwap) .. ")", "trinket")

        -- forceSwap (queue switch / forced re-equip) clears all pins and
        -- the boss lock so the new queue's picks aren't blocked by state
        -- left over from the previous queue.
        if forceSwap then
            self.trinketSwapSystem.manualSwapActive.slot1 = false
            self.trinketSwapSystem.manualSwapActive.slot2 = false
            self.trinketSwapSystem.manualSwapItem.slot1   = nil
            self.trinketSwapSystem.manualSwapItem.slot2   = nil
            self.trinketSwapSystem.lastSwapTime.slot1     = 0
            self.trinketSwapSystem.lastSwapTime.slot2     = 0
            if RC.bossTrinketState then
                RC.bossTrinketState.locked = {}
            end
        end

        self.trinketSwapSystem.pendingRetryAt = self.trinketSwapSystem.pendingRetryAt or {}
        local targets = {}
        local preHoldTargets = {}
        local READY_SOON_WINDOW = 30
        for slotNumber = 1, 2 do
            local inventorySlot = INVENTORY_SLOTS[slotNumber]
            local currentItemId = GetInventoryItemID("player", inventorySlot)
            local slotKey = SLOT_KEYS[slotNumber]
            local queue = self:GetRankedQueue(slotNumber)

            if not queue or #queue == 0 then
                self:DebugPrint("Slot " .. slotNumber .. ": no queue", "trinket")
            elseif self:IsBossTrinketLocked(slotNumber) then
                -- Boss gear swap owns this slot while the boss is alive; this
                -- path goes through EquipTrinketById which bypasses the
                -- SwapTrinket lock check, so it must be guarded here.
                self:DebugPrint("Slot " .. slotNumber .. ": boss trinket lock active - config equip skipped", "trinket")
            else
                local bestId, bestPriority = nil, -1
                local currentPriority = -1
                local otherItemId = GetInventoryItemID("player", INVENTORY_SLOTS[slotNumber == 1 and 2 or 1])
                -- the other slot's trinket is only a candidate here when it
                -- does not belong over there: taking a trinket that sits in
                -- its own queue's slot moves two trinkets (30s equip
                -- cooldown on both) for nothing
                local otherQueued = false
                for _, oq in ipairs(self:GetActiveQueue(slotNumber == 1 and 2 or 1) or {}) do
                    if oq == otherItemId then otherQueued = true break end
                end
                local slotState = self.trinketSwapSystem.trinketStates[slotKey]
                local bestCDRetry = 0
                local bestCDId, bestCDPri = nil, -1

                -- Score = the trinket's place in this slot's queue (2026-10-22:
                -- it was RC.trinketSwapPriority's built-in values, with the
                -- Priority flag on top, so this pass disagreed with the 1Hz
                -- rotation - which goes by queue order - and the two undid
                -- each other's picks). On-use above passive, as the rotation
                -- does: a ready on-use trinket replaces a passive one.
                local qn = #queue
                for qi, qId in ipairs(queue) do
                    if qId and qId ~= 0 then
                        local pri = qn - qi + 1
                        if self:IsTrinketOnUse(qId) then pri = pri + 500 end
                        if qId == currentItemId and pri > currentPriority then currentPriority = pri end

                        local inBags = self:FindTrinketInBags(qId) ~= nil
                        local inOtherSlot = (qId == otherItemId) and not otherQueued

                        if inBags or inOtherSlot then
                            local skipDueToCD = false
                            local cdRetryDelay = 0
                            if self:IsTrinketOnUse(qId) and not (inOtherSlot and forceSwap) then
                                local cs, cd
                                if inBags then
                                    cs, cd = self:GetItemCooldownSafe(qId)
                                else
                                    local otherSlot = slotNumber == 1 and 2 or 1
                                    cs, cd = Readycheck.PlainCD(GetInventoryItemCooldown("player", INVENTORY_SLOTS[otherSlot]))
                                end
                                if cs and cs > 0 and cd and cd > 1.5 then
                                    local remaining = cd - (GetTime() - cs)
                                    if remaining > 0 then
                                        skipDueToCD = true
                                        cdRetryDelay = remaining + 0.5
                                    end
                                end
                            end
                            if not skipDueToCD then
                                if pri > bestPriority then
                                    bestPriority = pri
                                    bestId = qId
                                end
                            else
                                if cdRetryDelay > 0 and (bestCDRetry == 0 or cdRetryDelay < bestCDRetry) then
                                    bestCDRetry = cdRetryDelay
                                end
                                if pri > bestCDPri then
                                    bestCDPri = pri
                                    bestCDId  = qId
                                end
                            end
                        end
                    end
                end

                if forceSwap and not bestId and bestCDId then
                    self:DebugPrint("Slot " .. slotNumber .. ": all queue picks on CD - config change equips cooling "
                        .. bestCDId .. " anyway", "trinket")
                    bestId, bestPriority = bestCDId, bestCDPri
                end

                if bestId and bestId ~= currentItemId then
                    preHoldTargets[slotNumber] = bestId
                end

                if forceSwap and currentItemId and bestId and bestId ~= currentItemId
                   and self:IsTrinketOnUse(currentItemId) then
                    local cs, cd = Readycheck.PlainCD(GetInventoryItemCooldown("player", inventorySlot))
                    local expectedCD = RC.trinketCooldowns and RC.trinketCooldowns[currentItemId]
                    local cdRemaining = (cs and cs > 0 and cd) and (cd - (GetTime() - cs)) or 0
                    local onRealUseCD = cdRemaining > 0 and (
                        (expectedCD and expectedCD > 0 and cd >= (expectedCD - 5))
                        or (not expectedCD and cd > 35))
                    local buffActive = self:IsUseBuffPossiblyActive(currentItemId, inventorySlot)
                    if buffActive or not onRealUseCD or cdRemaining <= READY_SOON_WINDOW then
                        self:DebugPrint("Slot " .. slotNumber
                            .. ": config change - keeping equipped on-use "
                            .. currentItemId .. " (buff active or ready, still in new queue)", "trinket")
                        bestId = currentItemId
                        bestPriority = currentPriority
                    end
                end

                local shouldHold = false
                local retryAfter = 0

                if bestId and bestId ~= currentItemId
                   and (forceSwap and bestPriority >= currentPriority or bestPriority > currentPriority) then
                    if not forceSwap and currentItemId and self:IsTrinketOnUse(currentItemId) then
                        if self:IsUseBuffPossiblyActive(currentItemId, inventorySlot) then
                            shouldHold = true
                            self:DebugPrint("Slot " .. slotNumber .. ": buff active - holding", "trinket")
                        else
                            local cdStart, cdDur = Readycheck.PlainCD(GetInventoryItemCooldown("player", inventorySlot))
                            local onCD = cdStart and cdStart > 0 and cdDur and cdDur > 1.5
                            if onCD then
                                local remaining = cdDur - (GetTime() - cdStart)
                                if remaining > 0 then
                                    shouldHold = true
                                    retryAfter = remaining + 0.5
                                    self:DebugPrint("Slot " .. slotNumber .. ": on CD (" .. math_floor(remaining) .. "s) - holding", "trinket")
                                end
                            elseif (not slotState or not slotState.wasOnCooldown) then
                                shouldHold = true
                                self:DebugPrint("Slot " .. slotNumber .. ": ready, not yet used - holding", "trinket")
                            end
                        end
                    end
                end

                if not forceSwap and self.trinketSwapSystem.manualSwapItem[slotKey] then
                    self:DebugPrint("Slot " .. slotNumber .. ": manual pin active - skipping", "trinket")
                elseif not shouldHold and bestId and bestId ~= currentItemId
                   and (forceSwap and bestPriority >= currentPriority or bestPriority > currentPriority) then
                    targets[slotNumber] = bestId
                elseif shouldHold and retryAfter > 0 then
                    local pendingAt = self.trinketSwapSystem.pendingRetryAt
                    local fireAt = GetTime() + retryAfter
                    if not pendingAt[slotNumber] or fireAt < pendingAt[slotNumber] then
                        pendingAt[slotNumber] = fireAt
                        local retrySlot = slotNumber
                        C_Timer.After(retryAfter, function()
                            if not InCombatLockdown() and not RC.trinketSwapSystem.manualSwapActive[slotKey] then
                                RC.trinketSwapSystem.pendingRetryAt[retrySlot] = nil
                                RC:DebugPrint("Retrying swap for slot " .. retrySlot, "trinket")
                                RC:EquipTrinketsFromConfig(false)
                            else
                                RC.trinketSwapSystem.pendingRetryAt[retrySlot] = nil
                            end
                        end)
                    end
                elseif not bestId and bestCDRetry > 0 then
                    local retrySlot = slotNumber
                    C_Timer.After(bestCDRetry, function()
                        if not InCombatLockdown() and not RC.trinketSwapSystem.manualSwapActive[slotKey] then
                            RC:DebugPrint("Retrying slot " .. retrySlot .. " after incoming trinket CD", "trinket")
                            RC:EquipTrinketsFromConfig(false)
                        end
                    end)
                else
                    self:DebugPrint("Slot " .. slotNumber .. ": no change needed (best=" .. tostring(bestId) .. " current=" .. tostring(currentItemId) .. ")", "trinket")
                end
            end
        end

        for a = 1, 2 do
            local b = a == 1 and 2 or 1
            if targets[b] and not targets[a]
               and targets[b] == GetInventoryItemID("player", INVENTORY_SLOTS[a])
               and preHoldTargets[a] and preHoldTargets[a] ~= targets[b] then
                targets[a] = preHoldTargets[a]
                self:DebugPrint("Slot " .. a .. ": reconciled to queue pick "
                    .. targets[a] .. " (slot " .. b .. " is claiming its current trinket)", "trinket")
            end
        end

        for a = 1, 2 do
            local b = a == 1 and 2 or 1
            if targets[a] and self:IsBossTrinketLocked(b)
               and targets[a] == GetInventoryItemID("player", INVENTORY_SLOTS[b]) then
                targets[a] = nil
                self:DebugPrint("Slot " .. a .. ": wanted trinket is boss-locked in slot " .. b .. " - skipping", "trinket")
            end
        end

        -- Same trinket picked for both slots (it can sit in both queues):
        -- give it to slot 1 this pass instead of skipping both; slot 2 gets
        -- its next-best pick on the following pass or rotation tick.
        if targets[1] and targets[1] == targets[2] then
            targets[2] = nil
            self:DebugPrint("Both slots want " .. targets[1] .. " - slot 1 takes it this pass", "trinket")
        end

        if targets[1] or targets[2] then
            self:EquipTrinketSet(
                { slot1 = targets[1],
                  slot2 = targets[2] },
                forceSwap and "force config change" or "auto rotation"
            )
        end
    end

    function RC:IsConfigPopulated(configKey)
        if not self.db.trinketSwap.queues or not self.db.trinketSwap.queues[configKey] then
            return false
        end

        local config = self.db.trinketSwap.queues[configKey]
        local slot1Count = config.slot1 and #config.slot1 or 0
        local slot2Count = config.slot2 and #config.slot2 or 0

        return (slot1Count + slot2Count) > 0
    end

    function RC:SetConfigName(configKey, newName)
        if not self.trinketSwapSystem.queueNames[configKey] then return false end

        self.trinketSwapSystem.queueNames[configKey] = newName

        if not self.db.trinketSwap.configNames then
            self.db.trinketSwap.configNames = {}
        end
        self.db.trinketSwap.configNames[configKey] = newName

        self:SaveConfigurationToProfile()
        return true
    end

    -- Where a bag copy of a trinket is (shared bag index), as the same
    -- { bag, slot } table each time while it stays there.
    function RC:FindTrinketInBags(itemId)
        if not itemId then return nil end
        local _, _, _, itemEquipLoc = GetItemInfoInstant(itemId)
        if itemEquipLoc ~= "INVTYPE_TRINKET" then return nil end
        local bag, slot = RC.Bags:Find(itemId)
        if not bag then return nil end
        local lookup = self.trinketSwapSystem.bagLocationLookup
        local loc = lookup[itemId]
        if not (loc and loc.bag == bag and loc.slot == slot) then
            loc = { bag = bag, slot = slot }
            lookup[itemId] = loc
        end
        return loc
    end

    -- WORTH KEEPING (2026-10-22, Zac: "trinket auto swapping ... just swaps
    -- ready to use trinkets off"). Why the on-use trinket in a slot must
    -- stay right now, or nil: its use buff may still be running, or it is
    -- ready - no cooldown, or only the 30s equip lock / a short shared
    -- lockout, or its own cooldown ends within 3s.
    function RC:TrinketKeepReason(slotNumber)
        local inv = INVENTORY_SLOTS[slotNumber]
        local cur = inv and GetInventoryItemID("player", inv)
        if not cur or not self:IsTrinketOnUse(cur) then return nil end
        if self:IsTrinketBuffActive(cur) then return "buff", cur end
        local s, d = Readycheck.PlainCD(GetInventoryItemCooldown("player", inv))
        if not (s and s > 0 and d and d > 1.5) then return "ready", cur end
        local full = RC.trinketCooldowns and RC.trinketCooldowns[cur]
        local useCD = (full and d >= full - 5) or (not full and d > 35)
        -- (the 30s equip lock is not a use: no buff behind it)
        if not useCD then return "ready", cur end
        if self:IsUseBuffPossiblyActive(cur, inv) then return "buff", cur end
        if d - (GetTime() - s) <= 3 then return "ready", cur end
        return nil
    end

    function RC:TrinketDiagName(id)
        if not id then return "nothing" end
        return (GetItemInfo(id)) or ("item " .. tostring(id))
    end

    -- Why an automatic swap of `incomingId` into this slot must not happen,
    -- or nil. mode: nil/"auto" (rotation, config pass), "boss" (a boss
    -- target / engage override: only a running buff stops it), "death"
    -- (after a boss dies: also not a ready one for one still cooling down).
    -- Automatic swaps never take off a ready on-use trinket that belongs in
    -- the slot, unless the incoming one is above it in the slot's queue and
    -- ready itself; nor one that is not in the queue at all (put on by
    -- hand, or moved there) until it has been used.
    function RC:TrinketSwapVeto(slotNumber, incomingId, mode)
        local why, cur = self:TrinketKeepReason(slotNumber)
        if not why or cur == incomingId then return nil end
        -- a boss's own trinket (on target / engage) goes on as asked
        if mode == "boss" then return nil end
        local curName = self:TrinketDiagName(cur)
        if why == "buff" then return curName .. "'s buff may still be up" end
        local inOnUse = incomingId and self:IsTrinketOnUse(incomingId)
        if mode == "death" then
            if inOnUse and not self:IsBagTrinketReady(incomingId, PRE_EQUIP_WINDOW) then
                return curName .. " is ready and " .. self:TrinketDiagName(incomingId) .. " is still on cooldown"
            end
            return nil
        end
        local rankCur, rankIn
        for i, q in ipairs(self:GetRankedQueue(slotNumber) or {}) do
            if q == cur and not rankCur then rankCur = i end
            if q == incomingId and not rankIn then rankIn = i end
        end
        if not rankCur then
            -- unless this addon pushed it here in a slot exchange: that was
            -- not a choice to respect (see displacedInto)
            local sys = self.trinketSwapSystem
            local dis = sys and sys.displacedInto and sys.displacedInto[SLOT_KEYS[slotNumber]]
            if dis and dis.itemId == cur and (GetTime() - (dis.at or 0)) < 300 then return nil end
            return curName .. " is ready (not queued here - kept until used)"
        end
        if rankIn and rankIn < rankCur and inOnUse and self:IsBagTrinketReady(incomingId, 0) then
            return nil
        end
        return curName .. " is ready"
    end

    -- Every non-combat equip path (config swap, EquipTrinketById, initial
    -- equip) checks this first: a cast or channel in progress blocks the
    -- swap so gear doesn't change out from under an in-flight cast.
    function RC:IsEquipBlockedNonCombat()
        if UnitCastingInfo and UnitCastingInfo("player") then return true end
        if UnitChannelInfo and UnitChannelInfo("player") then return true end
        return false
    end

    function RC:SwapTrinket(bag, slot, inventorySlot, slotNumber, _bypassBossLock, _skipThrottle, mode)
        if not _bypassBossLock and self:IsBossTrinketLocked(slotNumber) then
            self:DebugPrint("SwapTrinket blocked by boss lock for slot " .. slotNumber, "trinket")
            return false
        end
        -- Blocked by combat: dropped. (It used to be saved and replayed
        -- after the fight through the boss-death queue - a pick made for
        -- the fight's state put on after it, then LOCKED there as if a boss
        -- had asked for it. The rotation and the post-combat pass decide
        -- again from what is true then.)
        if InCombatLockdown() then
            self:SetTrinketIntent(inventorySlot, "tss")
            return false
        end
        do
            local inId = C_Container and C_Container.GetContainerItemID
                and C_Container.GetContainerItemID(bag, slot)
            local veto = inId and self:TrinketSwapVeto(slotNumber, inId, mode)
            if veto then
                self:DebugPrint("Slot " .. slotNumber .. ": kept - " .. veto, "trinket")
                self._tssVetoAt = GetTime()
                -- one log line per slot and reason a minute (the rotation asks every second)
                local sys = self.trinketSwapSystem
                sys._vetoLog = sys._vetoLog or {}
                local vk = slotNumber .. veto .. tostring(inId)
                if self.DiagLog and (GetTime() - (sys._vetoLog[vk] or -100)) > 60 then
                    sys._vetoLog[vk] = GetTime()
                    self:DiagLog("trinket", "slot %d kept: %s (wanted %s, %s)", slotNumber, veto, self:TrinketDiagName(inId), tostring(mode or "auto"))
                end
                return false
            end
        end
        if self:IsEquipBlockedNonCombat() then
            return false
        end

        local slotKey = SLOT_KEYS[slotNumber]
        local now = GetTime()

        -- 1s per-slot throttle (swapCooldown) absorbs a spammed gear-set
        -- macro; _skipThrottle is only used by the boss/death-swap path.
        if not _skipThrottle
           and (now - self.trinketSwapSystem.lastSwapTime[slotKey]) < self.trinketSwapSystem.swapCooldown then
            return false
        end

        local bagItemInfo = C_Container.GetContainerItemInfo(bag, slot)
        if not bagItemInfo then return false end

        local newItemId = bagItemInfo.itemID
        local currentItemId = GetInventoryItemID("player", inventorySlot)

        if newItemId == currentItemId then return false end

        self.trinketSwapSystem.ourSwapInProgress = true
        self.trinketSwapSystem.lastAutoSwapTime = now
        self.trinketSwapSystem.manualSwapActive[slotKey] = false
        self.trinketSwapSystem.manualSwapItem[slotKey] = nil

        if RC.Equip:BagToSlot(bag, slot, inventorySlot, { by = "tss", method = "cursor" }) then
            self.trinketSwapSystem.lastSwapTime[slotKey] = now

            C_Timer.After(0.5, function()
                if not RC.trinketSwapSystem then return end
                RC.trinketSwapSystem.ourSwapInProgress = false

                local actualItemId = GetInventoryItemID("player", inventorySlot)
                if actualItemId == newItemId then
                    local state = RC.trinketSwapSystem.trinketStates[slotKey]
                    state.itemId = newItemId
                    state.expectedItemId = newItemId
                    state.isOnUse = RC:IsTrinketOnUse(newItemId)
                    state.lastEquipTime = GetTime()
                    state.cooldownDetectedAt = 0
                    state.wasOnCooldown = false
                    state.buffExpireTime = 0
                    state.readySinceTime = RC:IsTrinketOnUse(newItemId) and GetTime() or 0
                    if RC.trinketSwapSystem.retryCount then
                        RC.trinketSwapSystem.retryCount[slotKey] = 0
                    end
                    RC:DebugPrint("Swap confirmed: " .. newItemId .. " in slot " .. slotNumber, "trinket")

                    if not RC.trinketSwapSystem.swapHistory then
                        RC.trinketSwapSystem.swapHistory = {}
                    end
                    local newName  = GetItemInfo(newItemId)     or ("Item " .. newItemId)
                    local oldName  = currentItemId and GetItemInfo(currentItemId) or "Empty"
                    local elapsed  = GetTime() - (RC.trinketSwapSystem.combatStartTime or GetTime())
                    local timeStr  = RC:FormatTime(elapsed)
                    table.insert(RC.trinketSwapSystem.swapHistory, {
                        time    = timeStr,
                        rawTime = GetTime(),
                        slot    = slotNumber,
                        inn     = newName,
                        out     = oldName,
                    })
                    if #RC.trinketSwapSystem.swapHistory > 50 then
                        table.remove(RC.trinketSwapSystem.swapHistory, 1)
                    end

                    RC:RefreshTrinketScan()
                else
                    local otherInv = (inventorySlot == INVENTORY_SLOTS[1]) and INVENTORY_SLOTS[2] or INVENTORY_SLOTS[1]
                    RC:DebugPrint(string.format(
                        RCL["Swap failed silently: wanted %s in slot %d, slot still has %s, other slot has %s | inCombat=%s casting=%s channel=%s mounted=%s"],
                        tostring(newItemId), slotNumber,
                        -- an empty slot returns NO value, not nil: wrap so
                        -- tostring always gets its one argument
                        tostring((GetInventoryItemID("player", inventorySlot))),
                        tostring((GetInventoryItemID("player", otherInv))),
                        tostring(InCombatLockdown()),
                        tostring((UnitCastingInfo and UnitCastingInfo("player")) and true or false),
                        tostring((UnitChannelInfo and UnitChannelInfo("player")) and true or false),
                        tostring((IsMounted and IsMounted()) or false)), "trinket")
                    RC:StartEquipRetryLoop(30)
                end
            end)

            return true
        end

        self.trinketSwapSystem.ourSwapInProgress = false
        self:DebugPrint("SwapTrinket pickup failed for " .. tostring(newItemId) .. " slot " .. slotNumber, "trinket")
        return false
    end

    function RC:UpdateTrinketStates()
        if RC.Profiler then RC.Profiler:StartTiming("TrinketState") end

        local now = GetTime()

        for slotNumber = 1, 2 do
            local slotKey = SLOT_KEYS[slotNumber]
            local state = self.trinketSwapSystem.trinketStates and self.trinketSwapSystem.trinketStates[slotKey]

            if not state or not state.lastEquipTime or (now - state.lastEquipTime) > 0.5 then
                self:UpdateTrinketState(slotNumber, true)
            end
        end

        if RC.Profiler then RC.Profiler:StopTiming("TrinketState") end
    end

    function RC:UpdateTrinketState(slotNumber, skipProfiler)
        if not skipProfiler and RC.Profiler then RC.Profiler:StartTiming("TrinketState") end

        if not self.trinketSwapSystem or not self.trinketSwapSystem.trinketStates then
            if not skipProfiler and RC.Profiler then RC.Profiler:StopTiming("TrinketState") end
            return
        end

        local now = GetTime()
        local inventorySlot = INVENTORY_SLOTS[slotNumber]
        local slotKey = SLOT_KEYS[slotNumber]
        local state = self.trinketSwapSystem.trinketStates[slotKey]
        if not state then
            if not skipProfiler and RC.Profiler then RC.Profiler:StopTiming("TrinketState") end
            return
        end

        local itemId = GetInventoryItemID("player", inventorySlot)

        -- Equipped item changed. expectedItemId is a one-shot allowance
        -- set by EquipTrinketById's cross-slot move so the displaced
        -- trinket landing here isn't mis-detected as a manual swap; any
        -- other unexpected change gets pinned so the rotation leaves it
        -- alone until it is used (see CheckManualPinExpired below).
        if state.itemId ~= itemId then
            if state.itemId ~= nil and not self.trinketSwapSystem.ourSwapInProgress then
                local expectedId = state.expectedItemId
                if expectedId ~= nil then
                    if itemId ~= expectedId then
                        self.trinketSwapSystem.manualSwapItem[slotKey] = itemId
                        self.trinketSwapSystem.manualSwapActive[slotKey] = true
                        self:DebugPrint("Manual swap detected in slot " .. slotNumber .. " (expected=" .. tostring(expectedId) .. " got=" .. tostring(itemId) .. ") - pinning", "trinket")
                    end
                    state.expectedItemId = nil
                else
                    self.trinketSwapSystem.manualSwapItem[slotKey] = itemId
                    self.trinketSwapSystem.manualSwapActive[slotKey] = true
                    self:DebugPrint("Manual swap detected in slot " .. slotNumber .. " (item " .. tostring(itemId) .. ") - pinning", "trinket")
                end
            end

            state.itemId = itemId
            state.isOnUse = itemId and self:IsTrinketOnUse(itemId) or false
            state.lastEquipTime = GetTime()
            state.cooldownDetectedAt = 0
            state.lockedOutUntil = 0
            self:DebugPrint("Trinket " .. (itemId or 0) .. " equipped in slot " .. slotNumber, "trinket")
        end

        state.itemId = itemId
        state.isOnUse = itemId and self:IsTrinketOnUse(itemId) or false

        if itemId and state.isOnUse then
            local start, duration = Readycheck.PlainCD(GetInventoryItemCooldown("player", inventorySlot))

            if start and start > 0 and duration and duration > 1.5 then
                local expectedTrinketCD = RC.trinketCooldowns[itemId]
                local timeSinceEquip = now - state.lastEquipTime
                local isEquipCooldown = (duration >= 25 and duration <= 35 and timeSinceEquip < 40) and
                                        (not expectedTrinketCD or expectedTrinketCD > 35)

                if isEquipCooldown then
                    state.cooldownStart    = start
                    state.cooldownDuration = duration
                    state.fullCooldown     = 30
                    state.wasOnCooldown    = false
                    state.buffExpireTime   = 0
                    state.cooldownDetectedAt = 0
                else
                    local isCategoryCD = (duration <= 20)

                    local isLockout = false
                    if not isCategoryCD and not self:IsTrinketBuffActive(itemId) then
                        if expectedTrinketCD then
                            if math.abs(duration - expectedTrinketCD) >= 5 then
                                isLockout = true
                            end
                        else
                            local otherSlotNum = (slotNumber == 1) and 2 or 1
                            local otherInv = INVENTORY_SLOTS[otherSlotNum]
                            local otherId = otherInv and GetInventoryItemID("player", otherInv)
                            if otherId and self:IsTrinketBuffActive(otherId) then
                                isLockout = true
                            end
                        end
                    end

                    if isCategoryCD or isLockout then
                        state.cooldownStart    = start
                        state.cooldownDuration = duration
                        state.buffExpireTime   = 0
                        if isLockout then
                            state.lockedOutUntil = start + duration
                        else
                            state.lockedOutUntil = 0
                        end
                    else
                        local wasOnCooldown = state.wasOnCooldown
                        state.cooldownStart    = start
                        state.cooldownDuration = duration
                        state.fullCooldown     = RC.trinketCooldowns[itemId] or duration
                        state.wasOnCooldown    = true
                        state.readySinceTime   = 0
                        state.lockedOutUntil   = 0

                        if not wasOnCooldown or state.cooldownDetectedAt == 0 then
                            state.cooldownDetectedAt = GetTime()
                        end
                        if not wasOnCooldown then
                            state.inheritedCD = false
                        end

                        if not wasOnCooldown and self.NotifyTrinketUsedForCapture then
                            self:NotifyTrinketUsedForCapture(itemId, start)
                        end

                        local elapsed      = GetTime() - start
                        local buffDuration = self:GetTrinketBuffDuration(itemId)
                        if buffDuration and elapsed < buffDuration then
                            state.buffExpireTime = start + buffDuration
                        else
                            state.buffExpireTime = 0
                        end
                    end
                end
            else
                if state.wasOnCooldown then
                    self:DebugPrint("Trinket " .. itemId .. " ready", "trinket")
                    state.readySinceTime = GetTime()
                end
                state.cooldownStart = 0
                state.cooldownDuration = 0
                state.wasOnCooldown = false
                state.buffExpireTime = 0
                state.cooldownDetectedAt = 0
                state.lockedOutUntil = 0
            end
        else
            state.cooldownStart = 0
            state.cooldownDuration = 0
            state.fullCooldown = 0
            state.wasOnCooldown = false
            state.buffExpireTime = 0
            state.cooldownDetectedAt = 0
            state.lockedOutUntil = 0
        end

        if not skipProfiler and RC.Profiler then RC.Profiler:StopTiming("TrinketState") end
    end

    -- Classic Era bag-item cooldown lookup, routed through
    -- RC:GetItemCooldownSafe (TSS_Base.lua) so it works whether or not the
    -- client exposes C_Container.GetItemCooldown; equipped-slot cooldowns
    -- use GetInventoryItemCooldown instead. There is no GetItemCooldown
    -- global on this client, unlike retail.
    function RC:IsBagTrinketReady(itemId, preEquipWindow)
        preEquipWindow = preEquipWindow or 30

        local start, duration = self:GetItemCooldownSafe(itemId)
        if not start or start == 0 then return true end
        if duration <= 1.5 then return true end

        local remaining = duration - (GetTime() - start)
        return remaining <= preEquipWindow
    end

    -- The buff is looked up in the shared aura read (RC.Auras), so this is
    -- a table lookup however often the rotation asks. Every time it finds
    -- the buff up it notes when (buffSeenAt), so IsUseBuffPossiblyActive
    -- below can tell "seen and now gone" from "never seen".
    local buffSeenAt = {}
    function RC:IsTrinketBuffActive(itemId)
        if not itemId then return false end
        local idA, idB = nil, nil
        local buffData = RC.trinketBuffs and RC.trinketBuffs[itemId]
        if buffData then idA = buffData.buffId end
        local scanned = nil
        if RC.TrinketScanner and RC.TrinketScanner.autoDetectedTrinkets then
            scanned = RC.TrinketScanner.autoDetectedTrinkets[itemId]
            if scanned then
                idB = scanned.buffId
                if not idA and not idB then idB = scanned.spellId end
            end
        end
        local aura = (idA and RC.Auras:Buff(idA)) or (idB and RC.Auras:Buff(idB))
        if not aura then return false end
        buffSeenAt[itemId] = GetTime()
        local count = aura.count
        if count > 1 and scanned and (not scanned.buffStacks or count > scanned.buffStacks) then
            scanned.buffStacks = count
        end
        return true
    end

    function RC:HasKnownTrinketBuffId(itemId)
        if not itemId then return false end
        local buffData = RC.trinketBuffs and RC.trinketBuffs[itemId]
        if buffData and buffData.buffId then return true end
        if RC.TrinketScanner and RC.TrinketScanner.autoDetectedTrinkets then
            local scanned = RC.TrinketScanner.autoDetectedTrinkets[itemId]
            if scanned and scanned.buffId then return true end
        end
        return false
    end

    -- Conservative "could this trinket's on-use buff still be running?".
    -- IsTrinketBuffActive is exact but only works when the buff spell id
    -- is known, and for some items it is missing or wrong - Nifty
    -- Stopwatch is recorded at a 10s buff but runs longer, so the
    -- rotation happily ripped it off mid-buff. So when the aura check
    -- comes back negative, fall back to the item's own cooldown: if it
    -- started more recently than the buff could possibly have lasted,
    -- treat the buff as up. The floor exists precisely because the
    -- recorded durations cannot be trusted; erring long only delays a
    -- swap by a few seconds, erring short throws away a used cooldown.
    -- But when the buff WAS seen up during this use and is gone now, it is
    -- over: the floor is only for buffs we cannot see. (It used to hold
    -- every on-use trinket for 30s after use - Kiss of the Spider's 15s
    -- buff kept its slot for another 15s, which looked like the slot was
    -- waiting on the other trinket's 30s buff.)
    local MIN_ASSUMED_BUFF = 30

    function RC:IsUseBuffPossiblyActive(itemId, inventorySlot)
        if not itemId or not inventorySlot then return false end
        if self:IsTrinketBuffActive(itemId) then return true end

        local start, duration = Readycheck.PlainCD(GetInventoryItemCooldown("player", inventorySlot))
        if not start or start <= 0 or not duration or duration <= 1.5 then
            return false
        end

        local elapsed = GetTime() - start
        if elapsed < 0 then return false end

        local seen = buffSeenAt[itemId]
        if seen and seen >= start then return false end

        local known = (RC.trinketBuffDurations and RC.trinketBuffDurations[itemId]) or 0
        local window = known > MIN_ASSUMED_BUFF and known or MIN_ASSUMED_BUFF
        return elapsed < window
    end

    function RC:GetTrinketBuffDuration(itemId)
        if not itemId then return nil end
        local d = RC.trinketBuffDurations and RC.trinketBuffDurations[itemId]
        if d then return d end
        if RC.TrinketScanner and RC.TrinketScanner.autoDetectedTrinkets then
            local scanned = RC.TrinketScanner.autoDetectedTrinkets[itemId]
            if scanned and scanned.buffDuration and scanned.buffDuration > 0 then
                return scanned.buffDuration
            end
        end
        return nil
    end

    -- Releases a manual pin only once the pinned trinket has done its
    -- job: an on-use pin releases when spent (on CD, buff gone); a
    -- passive pin releases once a queued on-use trinket is ready.
    function RC:CheckManualPinExpired(slotNumber)
        local system = self.trinketSwapSystem
        local slotKey = SLOT_KEYS[slotNumber]
        if not system.manualSwapItem[slotKey] then return end

        local pinnedId = system.manualSwapItem[slotKey]

        if self:IsTrinketOnUse(pinnedId) then
            local inventorySlot = INVENTORY_SLOTS[slotNumber]
            local start, duration = Readycheck.PlainCD(GetInventoryItemCooldown("player", inventorySlot))
            local isOnCD = start and start > 0 and duration and duration > 1.5

            if not isOnCD then return end

            local now = GetTime()
            local state = system.trinketStates[slotKey]
            local buffActive = self:IsTrinketBuffActive(pinnedId)
                           or (not self:HasKnownTrinketBuffId(pinnedId)
                               and state and state.buffExpireTime > 0 and now < state.buffExpireTime)

            if not buffActive then
                self:DebugPrint("Manual pin released - " .. pinnedId ..
                    " buff expired, CD running, resuming auto-swap", "trinket")
                system.manualSwapItem[slotKey] = nil
                system.manualSwapActive[slotKey] = false
            end
        else
            local queue = self:GetRankedQueue(slotNumber)
            if queue then
                local pinnedInQueue = false
                for _, qId in ipairs(queue) do
                    if qId == pinnedId then pinnedInQueue = true; break end
                end
                if pinnedInQueue then
                    for _, qId in ipairs(queue) do
                        if qId and qId ~= 0 and qId ~= pinnedId and self:IsTrinketOnUse(qId) then
                            local loc = self:FindTrinketInBags(qId)
                            if loc and self:IsBagTrinketReady(qId, PRE_EQUIP_WINDOW) then
                                self:DebugPrint("Passive manual pin released - " .. pinnedId
                                    .. " is in the rotation and queued on-use " .. qId
                                    .. " is ready, resuming auto-swap", "trinket")
                                system.manualSwapItem[slotKey] = nil
                                system.manualSwapActive[slotKey] = false
                                break
                            end
                        end
                    end
                end
            end
        end
    end

    -- Priority+on-use first, then any on-use, then passive - used only
    -- for initial equip and non-queue pinned-trinket replacement, not
    -- by the normal rotation (see ProcessTrinketRotation for that).
    function RC:GetBestTrinketToEquip(slotNumber)
        local queue = self:GetRankedQueue(slotNumber)
        if not queue or #queue == 0 then return nil, nil end

        for _, itemId in ipairs(queue) do
            if itemId and itemId ~= 0 then
                if self:IsPriorityTrinket(itemId) and self:IsTrinketOnUse(itemId) and self:IsBagTrinketReady(itemId, 35) then
                    local location = self:FindTrinketInBags(itemId)
                    if location then return itemId, location end
                end
            end
        end

        for _, itemId in ipairs(queue) do
            if itemId and itemId ~= 0 then
                if self:IsTrinketOnUse(itemId) and self:IsBagTrinketReady(itemId, 35) then
                    local location = self:FindTrinketInBags(itemId)
                    if location then return itemId, location end
                end
            end
        end

        for _, itemId in ipairs(queue) do
            if itemId and itemId ~= 0 and not self:IsTrinketOnUse(itemId) then
                local location = self:FindTrinketInBags(itemId)
                if location then return itemId, location end
            end
        end

        return nil, nil
    end
end
