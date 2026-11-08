------------------------------------------------------------------------
-- Readycheck - Trinket Swap Rotation
-- Owns ProcessTrinketRotation, the per-slot decision loop that picks
-- which trinket to equip next; runs off the 1Hz poll ticker, never
-- off high-frequency combat events. Also owns the retry/polling
-- tickers and the swap-away anti-thrash tracking.
------------------------------------------------------------------------
local ipairs, tostring = ipairs, tostring
local math_floor, math_max = math.floor, math.max
local GetTime = GetTime
local GetInventoryItemID = GetInventoryItemID
local GetInventoryItemCooldown = GetInventoryItemCooldown
local InCombatLockdown = InCombatLockdown
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
    -- InCombatLockdown can flicker right at the transition edge; hold
    -- rotation for 0.6s so ProcessTrinketRotation never acts on a stale
    -- reading immediately after combat starts or ends.
    function RC:OnCombatStateChange(inCombat)
        local system = self.trinketSwapSystem
        local now = GetTime()

        system.combatStateStable = false
        system.lastCombatChange = now

        C_Timer.After(0.6, function()
            system.combatStateStable = true
        end)

        if not inCombat then
            C_Timer.After(0.8, function()
                if RC:HasFreshManualTrinketIntent(13) or RC:HasFreshManualTrinketIntent(14) then
                    RC:DebugPrint("TSS post-combat equip yielded to manual trinket intent", "trinket")
                    return
                end
                if not InCombatLockdown() and self.db.trinketSwap.enabled and self.db.trinketSwap.autoSwapActive then
                    RC:RefreshTrinketScan()
                    self:UpdateTrinketStates()
                    self:EquipTrinketsFromConfig()
                    self:StartEquipRetryLoop(6)
                end
            end)
        end
    end

    function RC:ProcessTrinketRotation(slotNumber)
        local Profiler = RC.Profiler
        if Profiler then Profiler:StartTiming("TrinketRotation") end

        local system = self.trinketSwapSystem
        local slotKey = SLOT_KEYS[slotNumber]

        if InCombatLockdown() or system.ourSwapInProgress or not system.combatStateStable then
            if Profiler then Profiler:StopTiming("TrinketRotation") end
            return
        end
        if RC.HasFreshManualTrinketIntent and RC:HasFreshManualTrinketIntent(INVENTORY_SLOTS[slotNumber], 120) then
            if Profiler then Profiler:StopTiming("TrinketRotation") end
            return
        end

        local inventorySlot = INVENTORY_SLOTS[slotNumber]
        local currentItemId = GetInventoryItemID("player", inventorySlot)
        if not currentItemId then
            if Profiler then Profiler:StopTiming("TrinketRotation") end
            return
        end

        do
            -- Boss-death trinket swap is still being sequenced (8s window
            -- set in RunPendingDeathTrinketSwap): hold rotation so it
            -- cannot race or yank a trinket mid-application.
            local bts = RC.bossTrinketState
            local hold = bts and bts.deathTrinketApplyingSlots
                         and bts.deathTrinketApplyingSlots[slotNumber]
                         and GetTime() < (bts.deathTrinketApplyingUntil or 0)
            if not hold then
                -- Also holds for a plain combat-blocked swap (src="tss"
                -- from SwapTrinket), not just a boss-death swap; only
                -- RunPendingDeathTrinketSwap/FireDeathGearSwap clears
                -- this, so it must fire after combat or the slot stays
                -- held indefinitely.
                local pdt = RC.pendingDeathTrinketSwap
                if pdt then
                    if (slotNumber == 1 and pdt.slot1 and pdt.slot1 ~= 0)
                       or (slotNumber == 2 and pdt.slot2 and pdt.slot2 ~= 0) then
                        hold = true
                    end
                end
            end
            if hold then
                self:DebugPrint("Slot " .. slotNumber .. ": death trinket override applying - holding rotation", "trinket")
                if Profiler then Profiler:StopTiming("TrinketRotation") end
                return
            end
        end

        local pinnedItem = system.manualSwapItem[slotKey]
        if pinnedItem then
            if pinnedItem == currentItemId then
                if Profiler then Profiler:StopTiming("TrinketRotation") end
                return
            end
            system.manualSwapItem[slotKey] = nil
            system.manualSwapActive[slotKey] = false
        end

        local state = system.trinketStates[slotKey]
        local now = GetTime()

        if state.isOnUse and now < (system.loginProtectionExpiry or 0) then
            self:DebugPrint("Slot " .. slotNumber .. ": login/reload protection active - holding equipped on-use trinket", "trinket")
            if Profiler then Profiler:StopTiming("TrinketRotation") end
            return
        end

        if state and (state.lockedOutUntil or 0) > now then
            self:DebugPrint("Slot " .. slotNumber .. ": locked out for "
                .. string.format("%.1f", state.lockedOutUntil - now) .. "s - holding", "trinket")
            if Profiler then Profiler:StopTiming("TrinketRotation") end
            return
        end

        if self:IsBossTrinketLocked(slotNumber) then
            local lockedId = RC.bossTrinketState.locked[slotNumber]
            if lockedId ~= currentItemId then
                -- The boss swap may still be in flight (swap throttle, casting,
                -- cross-slot sequencing, engage retries). During the engage
                -- grace window, hold rotation instead of releasing the lock -
                -- releasing here let auto-swap yank boss trinkets mid-equip.
                if GetTime() - (RC.bossTrinketState.lockEngagedAt or 0) < 12 then
                    self:DebugPrint("Slot " .. slotNumber .. ": boss trinket swap in flight - holding rotation", "trinket")
                    if Profiler then Profiler:StopTiming("TrinketRotation") end
                    return
                end
                if self.ReleaseDeathSwapLockForSlot then self:ReleaseDeathSwapLockForSlot(slotNumber) end
                RC.bossTrinketState.locked[slotNumber] = nil
            else
                local notUsed = state.isOnUse and not state.wasOnCooldown
                local timeSinceCD = state.cooldownDetectedAt > 0 and (now - state.cooldownDetectedAt) or 0
                local buffActive = state.isOnUse and (timeSinceCD < 3 or self:IsTrinketBuffActive(currentItemId))
                if not state.isOnUse then
                    -- A passive trinket can never be "used", so a death-swap
                    -- lock on it would never release and the slot would be
                    -- frozen forever. Release the death lock once a queued
                    -- on-use trinket is ready; engage boss locks still hold.
                    local ds = RC.bossTrinketState.deathSwap
                    local isDeathLock = ds and ((slotNumber == 1 and ds.slot1 == currentItemId)
                                             or (slotNumber == 2 and ds.slot2 == currentItemId))
                    local readyId = nil
                    if isDeathLock then
                        local q = self:GetActiveQueue(slotNumber)
                        if q then
                            for _, qId in ipairs(q) do
                                if qId and qId ~= 0 and qId ~= currentItemId and self:IsTrinketOnUse(qId) then
                                    local loc = self:FindTrinketInBags(qId)
                                    if loc and self:IsBagTrinketReady(qId, PRE_EQUIP_WINDOW) then
                                        readyId = qId
                                        break
                                    end
                                end
                            end
                        end
                    end
                    if not readyId then
                        if Profiler then Profiler:StopTiming("TrinketRotation") end
                        return
                    end
                    if self.ReleaseDeathSwapLockForSlot then self:ReleaseDeathSwapLockForSlot(slotNumber) end
                    RC.bossTrinketState.locked[slotNumber] = nil
                    self:DebugPrint("Slot " .. slotNumber .. ": passive death trinket " .. currentItemId
                        .. " - queued on-use " .. readyId .. " ready, lock released, rotation resumes", "trinket")
                end
                if state.isOnUse then
                    if notUsed or buffActive then
                        if Profiler then Profiler:StopTiming("TrinketRotation") end
                        return
                    end
                    if self.ReleaseDeathSwapLockForSlot then self:ReleaseDeathSwapLockForSlot(slotNumber) end
                    RC.bossTrinketState.locked[slotNumber] = nil
                    self:DebugPrint("Slot " .. slotNumber .. ": override trinket "
                        .. currentItemId .. " used - lock released, rotation resumes", "trinket")
                end
            end
        end

        local queue = self:GetRankedQueue(slotNumber)

        if not queue or #queue == 0 then
            if Profiler then Profiler:StopTiming("TrinketRotation") end
            return
        end

        -- Absolute: an on-use trinket is never taken off while the buff it
        -- just granted could still be running. This sits ahead of every
        -- other check because a used cooldown thrown away mid-buff is
        -- unrecoverable, and the guards below all depend on the buff spell
        -- id being known and correct, which it is not for every item.
        if state.isOnUse and self:IsUseBuffPossiblyActive(currentItemId, inventorySlot) then
            self:DebugPrint("Slot " .. slotNumber .. ": " .. tostring(currentItemId)
                .. " buff may still be up - holding", "trinket")
            if Profiler then Profiler:StopTiming("TrinketRotation") end
            return
        end

        local isInQueue = false
        for _, qId in ipairs(queue) do
            if qId == currentItemId then isInQueue = true; break end
        end

        if not isInQueue then
            -- Unless WE put it here. A cross-slot exchange displaces the
            -- other slot's trinket, and that is the addon's doing, not a
            -- choice to respect - so it must not earn the manual pin
            -- below, or an unqueued trinket the user never presses stays
            -- in the wrong slot indefinitely.
            local displaced = system.displacedInto and system.displacedInto[slotKey]
            local weDisplacedIt = displaced and displaced.itemId == currentItemId
                and (now - (displaced.at or 0)) < 300
            if weDisplacedIt then
                self:DebugPrint("Slot " .. slotNumber .. ": " .. currentItemId
                    .. " was displaced here by a slot exchange, not chosen"
                    .. " - rotation may replace it", "trinket")
            elseif state.isOnUse then
                -- Not part of the rotation at all. You put it on by hand,
                -- so the rotation leaves it alone until it is spent - used
                -- and past its buff, which the guard above already proved.
                if not state.wasOnCooldown then
                    self:DebugPrint("Slot " .. slotNumber .. ": " .. currentItemId .. " not in queue, unused on-use - pinned", "trinket")
                    if Profiler then Profiler:StopTiming("TrinketRotation") end
                    return
                end
            end
        else
            if system.displacedInto then system.displacedInto[slotKey] = nil end
            if state.isOnUse and not state.wasOnCooldown then
                if Profiler then Profiler:StopTiming("TrinketRotation") end
                return
            end
        end

        -- Priority trinket reserves its slot: skip the swap-out entirely
        -- while it is unused or its buff might still be running.
        if self:IsPriorityTrinket(currentItemId) then
            local notUsed = state.isOnUse and not state.wasOnCooldown
            local timeSinceCooldown = state.cooldownDetectedAt > 0 and (now - state.cooldownDetectedAt) or 0
            local buffActive = state.isOnUse and (timeSinceCooldown < 3 or self:IsTrinketBuffActive(currentItemId))
            if notUsed or buffActive then
                if Profiler then Profiler:StopTiming("TrinketRotation") end
                return
            end
        end

        if state.isOnUse and state.wasOnCooldown and not state.inheritedCD then
            local timeSinceCooldown = state.cooldownDetectedAt > 0 and (now - state.cooldownDetectedAt) or 0
            if timeSinceCooldown < 3 then
                if Profiler then Profiler:StopTiming("TrinketRotation") end
                return
            end
        end
        if state.isOnUse then
            if self:IsTrinketBuffActive(currentItemId) then
                if Profiler then Profiler:StopTiming("TrinketRotation") end
                return
            end
            if state.wasOnCooldown and state.buffExpireTime > 0 and now < state.buffExpireTime
               and not self:HasKnownTrinketBuffId(currentItemId) then
                if Profiler then Profiler:StopTiming("TrinketRotation") end
                return
            end
        end

        local queueLen = #queue

        local lastSwappedAway = system.lastSwappedAwayFrom and system.lastSwappedAwayFrom[slotKey]
        local lastSwapAwayTime = system.lastSwapAwayTime and system.lastSwapAwayTime[slotKey] or 0

        -- Where each trinket sits in the queue. Lowest index wins, so a
        -- duplicate entry keeps its best position.
        local queueRank = {}
        for i = queueLen, 1, -1 do
            local qId = queue[i]
            if qId and qId ~= 0 then queueRank[qId] = i end
        end

        local incomingPriId, incomingPriLoc, incomingPriRank = nil, nil, nil
        for _, qId in ipairs(queue) do
            if qId and qId ~= 0 and qId ~= currentItemId and self:IsPriorityTrinket(qId) then
                local loc = self:FindTrinketInBags(qId)
                if loc and self:IsBagTrinketReady(qId, PRE_EQUIP_WINDOW) then
                    incomingPriId = qId
                    incomingPriLoc = loc
                    incomingPriRank = queueRank[qId]
                    break
                end
            end
        end

        local function trySwap(itemId, location)
            -- Hold the slot for an incoming Priority trinket only against
            -- candidates the user ranked below it. This used to veto every
            -- other trinket unconditionally, so anything queued above a
            -- Priority trinket was blocked by it too.
            if incomingPriId and itemId ~= incomingPriId then
                local myRank = queueRank[itemId]
                if not myRank or not incomingPriRank or myRank > incomingPriRank then
                    self:DebugPrint("Slot " .. slotNumber .. ": holding for priority " .. incomingPriId .. ", skipping " .. itemId, "trinket")
                    return false
                end
            end
            if itemId == lastSwappedAway and (now - lastSwapAwayTime) < 10 then return false end
            self:RecordSwapAway(slotKey, currentItemId)
            local ok = self:SwapTrinket(location.bag, location.slot, inventorySlot, slotNumber)
            if not ok then
                self:ScheduleTrinketRetry(slotNumber)
            end
            return ok
        end

        local cdRemaining = 0
        if state.isOnUse and state.wasOnCooldown and state.fullCooldown > 0 and state.cooldownStart > 0 then
            cdRemaining = math_max(0, state.fullCooldown - (now - state.cooldownStart))
        end

        local bestReady, bestPassive

        -- Absolute queue order, not rotation order from the equipped
        -- trinket: queue position IS the priority ranking. With Kiss /
        -- Badge / Slayer's queued in that order, a ready Badge always
        -- beats Slayer's but never beats a ready Kiss.
        --
        -- bestReady is the first eligible on-use trinket in queue order and
        -- is what gets picked. Candidates used to be sorted into Priority
        -- and non-Priority buckets with the Priority bucket winning
        -- outright, so a Priority trinket at #3 outranked a plain one at
        -- #2 - the opposite of what the queue said.
        for i = 1, queueLen do
            local qId = queue[i]
            if qId and qId ~= 0 and qId ~= currentItemId then
                local loc = self:FindTrinketInBags(qId)
                if loc then
                    local isOu = self:IsTrinketOnUse(qId)
                    if isOu then
                        if self:IsBagTrinketReady(qId, PRE_EQUIP_WINDOW) then
                            if not bestReady then
                                bestReady = {itemId = qId, location = loc}
                            end
                        end
                    else
                        if not bestPassive then
                            bestPassive = {itemId = qId, location = loc}
                        end
                    end
                end
            end
        end

        if state.isOnUse and state.wasOnCooldown then
            local best
            if bestReady then
                local currentSoonReady = cdRemaining > 0 and cdRemaining <= (PRE_EQUIP_WINDOW + 5)
                if cdRemaining > PRE_EQUIP_WINDOW and not currentSoonReady then
                    best = bestReady
                end
            elseif bestPassive and cdRemaining > 60 then
                best = bestPassive
            end

            if best then
                if trySwap(best.itemId, best.location) then
                    if Profiler then Profiler:StopTiming("TrinketRotation") end
                    return
                end
            end
        end

        -- Both candidates on cooldown: take whichever becomes ready sooner
        -- instead of waiting out the equipped trinket's full remaining CD.
        if state.isOnUse and state.wasOnCooldown and queueLen == 2 then
            local otherId
            for i = 1, queueLen do
                local qId = queue[i]
                if qId and qId ~= 0 and qId ~= currentItemId then otherId = qId; break end
            end
            if otherId and self:IsTrinketOnUse(otherId) and not self:IsTrinketBuffActive(otherId) then
                local otherLoc = self:FindTrinketInBags(otherId)
                if otherLoc then
                    local oStart, oDur = self:GetItemCooldownSafe(otherId)
                    local otherRemaining = 0
                    if oStart and oStart > 0 and oDur and oDur > 1.5 then
                        otherRemaining = math_max(0, oDur - (GetTime() - oStart))
                    end
                    if otherRemaining < cdRemaining then
                        if trySwap(otherId, otherLoc) then
                            self:DebugPrint("Slot " .. slotNumber .. ": two-trinket pre-stage - "
                                .. otherId .. " ready in " .. math_floor(otherRemaining)
                                .. "s vs " .. math_floor(cdRemaining) .. "s equipped - swapping", "trinket")
                            if Profiler then Profiler:StopTiming("TrinketRotation") end
                            return
                        end
                    end
                end
            end
        end

        -- Equipped trinket is passive: take the highest-queued on-use
        -- trinket that is ready, whatever its Priority flag says.
        if not state.isOnUse then
            if bestReady then
                trySwap(bestReady.itemId, bestReady.location)
                if Profiler then Profiler:StopTiming("TrinketRotation") end
                return
            end
        end

        -- Last resort: pull a Priority trinket in even though the equipped
        -- one is not on cooldown. Skipped when something the user queued
        -- above it is also ready, otherwise this path would quietly undo
        -- the queue order the selection above just honoured.
        local priOutranked = bestReady and bestReady.itemId ~= incomingPriId
        if incomingPriId and incomingPriLoc and not priOutranked
           and not self:IsPriorityTrinket(currentItemId) then
            if self:IsBagTrinketReady(incomingPriId, 5) then
                local buffStillActive = state.isOnUse and (
                    self:IsTrinketBuffActive(currentItemId) or
                    (state.wasOnCooldown and state.buffExpireTime > 0 and now < state.buffExpireTime
                     and not self:HasKnownTrinketBuffId(currentItemId))
                )
                local currentNearlyReady = false
                if state.isOnUse then
                    local invStart, invDur = Readycheck.PlainCD(GetInventoryItemCooldown("player", inventorySlot))
                    if invStart and invStart > 0 and invDur and invDur > 1.5 then
                        local invRemaining = invDur - (now - invStart)
                        if invRemaining > 0 and invRemaining <= PRE_EQUIP_WINDOW then
                            currentNearlyReady = true
                        end
                    end
                end
                if not buffStillActive and not currentNearlyReady then
                    if incomingPriId ~= lastSwappedAway or (now - lastSwapAwayTime) >= 10 then
                        self:RecordSwapAway(slotKey, currentItemId)
                        self:SwapTrinket(incomingPriLoc.bag, incomingPriLoc.slot, inventorySlot, slotNumber)
                    end
                end
            end
        end

        if Profiler then Profiler:StopTiming("TrinketRotation") end
    end

    -- Remembers what a slot last swapped away from so trySwap can refuse
    -- to swap straight back for 10s - stops shared-cooldown trinkets from
    -- bouncing back and forth every poll tick.
    function RC:RecordSwapAway(slotKey, itemId)
        if not self.trinketSwapSystem.lastSwappedAwayFrom then
            self.trinketSwapSystem.lastSwappedAwayFrom = {}
        end
        if not self.trinketSwapSystem.lastSwapAwayTime then
            self.trinketSwapSystem.lastSwapAwayTime = {}
        end
        self.trinketSwapSystem.lastSwappedAwayFrom[slotKey] = itemId
        self.trinketSwapSystem.lastSwapAwayTime[slotKey] = GetTime()
    end

    -- Caps at 5 retries (1.5s apart) then gives up silently; retryCount
    -- resets so a later trigger can start a fresh retry burst.
    function RC:ScheduleTrinketRetry(slotNumber)
        local system = self.trinketSwapSystem
        local slotKey = SLOT_KEYS[slotNumber]

        if system.retryPending[slotKey] then return end
        if system.retryCount[slotKey] >= 5 then
            system.retryCount[slotKey] = 0
            return
        end

        system.retryPending[slotKey] = true
        system.retryCount[slotKey] = system.retryCount[slotKey] + 1

        self:DebugPrint("Rotation retry " .. system.retryCount[slotKey] .. " for slot " .. slotNumber, "trinket")

        C_Timer.After(1.5, function()
            if not RC.trinketSwapSystem then return end
            RC.trinketSwapSystem.retryPending[slotKey] = false
            if not InCombatLockdown() and RC.db.trinketSwap.enabled and RC.db.trinketSwap.autoSwapActive then
                RC:UpdateTrinketState(slotNumber)
                RC:ProcessTrinketRotation(slotNumber)
            end
        end)
    end

    -- Bounded retry loop (2s ticks) for post-toggle/post-combat equip;
    -- stops on success, timeout, or once every unmatched slot is pinned.
    function RC:StartEquipRetryLoop(maxTime)
        local system = self.trinketSwapSystem
        if system.equipRetryActive then
            system.equipRetryMaxTime = math_max(system.equipRetryMaxTime or 0, (system.equipRetryElapsed or 0) + maxTime)
            return
        end
        system.equipRetryActive = true
        system.equipRetryElapsed = 0
        system.equipRetryMaxTime = maxTime

        local interval = 2.0

        self:DebugPrint("Starting equip retry loop (max " .. maxTime .. "s)", "trinket")

        local function attempt()
            if not RC.trinketSwapSystem or not RC.trinketSwapSystem.equipRetryActive then return end
            local sys = RC.trinketSwapSystem
            sys.equipRetryElapsed = sys.equipRetryElapsed + interval

            if not RC.db or not RC.db.trinketSwap then
                sys.equipRetryActive = false
                return
            end

            if not RC.db.trinketSwap.enabled or not RC.db.trinketSwap.autoSwapActive then
                sys.equipRetryActive = false
                return
            end

            if not InCombatLockdown() and not RC:IsEquipBlockedNonCombat() then
                local allGood = true
                for slotNumber = 1, 2 do
                    local inventorySlot = INVENTORY_SLOTS[slotNumber]
                    local currentItemId = GetInventoryItemID("player", inventorySlot)
                    local queue = RC:GetActiveQueue(slotNumber)
                    if queue and #queue > 0 and not RC:IsBossTrinketLocked(slotNumber) then
                        local found = false
                        for _, qId in ipairs(queue) do
                            if qId == currentItemId then found = true; break end
                        end
                        if not found then allGood = false; break end
                    end
                end

                if allGood then
                    RC:DebugPrint("Equip retry loop: all slots correct", "trinket")
                    sys.equipRetryActive = false
                    return
                end

                if sys.equipRetryElapsed >= sys.equipRetryMaxTime then
                    RC:DebugPrint("Equip retry loop: timed out", "trinket")
                    sys.equipRetryActive = false
                    return
                end

                RC:EquipTrinketsFromConfig()

                local allPinned = true
                for slotNumber = 1, 2 do
                    local slotKey = SLOT_KEYS[slotNumber]
                    if not RC.trinketSwapSystem.manualSwapItem[slotKey] then
                        allPinned = false; break
                    end
                end
                if allPinned then
                    RC:DebugPrint("Equip retry loop: all slots pinned - stopping", "trinket")
                    sys.equipRetryActive = false
                    return
                end
            else
                sys.equipRetryElapsed = sys.equipRetryElapsed - interval
            end

            C_Timer.After(interval, attempt)
        end

        C_Timer.After(interval, attempt)
    end

    function RC:IsNonQueueTrinketPinned(slotNumber, currentItemId)
        if not currentItemId then return false end

        local queue = self:GetActiveQueue(slotNumber)
        if not queue or #queue == 0 then return false end

        for _, itemId in ipairs(queue) do
            if itemId == currentItemId then
                return false
            end
        end

        local inventorySlot = INVENTORY_SLOTS[slotNumber]
        if self:IsTrinketOnUse(currentItemId) then
            local start, duration = Readycheck.PlainCD(GetInventoryItemCooldown("player", inventorySlot))
            if not start or start == 0 or duration <= 1.5 then
                self:DebugPrint("Slot " .. slotNumber .. ": " .. currentItemId .. " not in queue but unused on-use trinket - pinned", "trinket")
                return true
            end
            return false
        else
            self:DebugPrint("Slot " .. slotNumber .. ": " .. currentItemId .. " not in queue (passive) - pinned", "trinket")
            return true
        end
    end

    -- Consumes the BAG_UPDATE_COOLDOWN dirty flag raised in TSS_Events.
    -- BAG_UPDATE_COOLDOWN fires 10-20x/sec in combat, so the actual
    -- GetInventoryItemCooldown reads happen here on the 1 Hz poll.
    function RC:CheckDeathSwapLockCooldowns()
        local tss = self.trinketSwapSystem
        if not tss or not tss._deathSwapCDDirty then return end
        tss._deathSwapCDDirty = false

        local st = self.bossTrinketState
        if not (st and st.deathSwap and st.locked) then return end

        if st.locked[1] then
            local start, duration = Readycheck.PlainCD(GetInventoryItemCooldown("player", 13))
            if start and start > 0 and duration and duration > 5 then
                self:ReleaseDeathSwapLockForSlot(1)
            end
        end
        if st.locked[2] then
            local start, duration = Readycheck.PlainCD(GetInventoryItemCooldown("player", 14))
            if start and start > 0 and duration and duration > 5 then
                self:ReleaseDeathSwapLockForSlot(2)
            end
        end
    end

    function RC:StartTrinketPolling()
        if self.trinketSwapSystem.pollingActive then return end

        self.trinketSwapSystem.pollingActive = true
        self.trinketSwapSystem.pollCount = 0

        local pollFn = function()
            if not RC.trinketSwapSystem.pollingActive then
                if RC.trinketPollTicker then
                    RC.trinketPollTicker:Cancel()
                    RC.trinketPollTicker = nil
                end
                return
            end

            RC.trinketSwapSystem.pollCount = RC.trinketSwapSystem.pollCount + 1

            RC:CheckDeathSwapLockCooldowns()

            RC:UpdateTrinketStates()

            if RC.GearManager and RC.GearManager.UpdateQueueIndicators then
                RC.GearManager:UpdateQueueIndicators(true)
            end

            if RC.db.trinketSwap.enabled and RC.db.trinketSwap.autoSwapActive then
                for slotNumber = 1, 2 do
                    RC:CheckManualPinExpired(slotNumber)
                    RC:ProcessTrinketRotation(slotNumber)
                end
            end
        end

        if RC.Profiler and RC.Profiler.TrackTicker then
            self.trinketPollTicker = RC.Profiler:TrackTicker("TrinketSwap:Poll", 1.0, pollFn)
        else
            self.trinketPollTicker = C_Timer.NewTicker(1.0, pollFn)
        end
    end

    function RC:StopTrinketPolling()
        self.trinketSwapSystem.pollingActive = false
        if self.trinketPollTicker then
            self.trinketPollTicker:Cancel()
            self.trinketPollTicker = nil
        end
    end

    function RC:PerformInitialTrinketEquip()
        if InCombatLockdown() or not self.db.trinketSwap.enabled then return end

        for slotNumber = 1, 2 do
            local inventorySlot = INVENTORY_SLOTS[slotNumber]
            local currentItemId = GetInventoryItemID("player", inventorySlot)
            local slotKey = SLOT_KEYS[slotNumber]

            local swapBack = self.db.speedSwapPending and self.db.speedSwapPending[inventorySlot]
            local swapBackHeld = swapBack and swapBack.item == currentItemId
                and ((swapBack.prev or 0) ~= 0
                     or (self.db.speedSwapTargets and self.db.speedSwapTargets[swapBack.item]))
            if currentItemId and self:IsNonQueueTrinketPinned(slotNumber, currentItemId) then
                self:DebugPrint("InitialEquip: slot " .. slotNumber .. " has pinned non-queue trinket " .. currentItemId .. " - skipping", "trinket")
            elseif swapBackHeld then
                -- The on-use swap-back owns this slot until it puts the
                -- previous item back.
                self:DebugPrint("InitialEquip: slot " .. slotNumber .. " is held by the on-use swap-back - skipping", "trinket")
            else
                local queue = self:GetActiveQueue(slotNumber)
                if queue and #queue > 0 then
                    local inQueue = false
                    if currentItemId then
                        for _, itemId in ipairs(queue) do
                            if itemId == currentItemId then inQueue = true; break end
                        end
                    end

                    local needsSwap = not inQueue

                    if needsSwap then
                        if currentItemId and self:IsTrinketOnUse(currentItemId)
                           and self:IsTrinketBuffActive(currentItemId) then
                            self:DebugPrint("InitialEquip: slot " .. slotNumber .. " trinket " .. currentItemId .. " still buffed - keeping", "trinket")
                        else
                            local bestItemId, location = self:GetBestTrinketToEquip(slotNumber)
                            if bestItemId and location then
                                self:SwapTrinket(location.bag, location.slot, inventorySlot, slotNumber)
                            end
                        end
                    end
                end
            end
        end
    end

end
