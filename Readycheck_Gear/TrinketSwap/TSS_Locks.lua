------------------------------------------------------------------------
-- Readycheck - Trinket Swap Locks and Boss Death Swaps
-- Owns trinketSwapSystem/bossTrinketState init, the EquipTrinketById/
-- EquipTrinketSet equip primitives, and RunPendingDeathTrinketSwap.
--
-- bossTrinketState.locked[slotNum] is the boss lock: set here once a
-- death-trinket swap verifies equipped (EngageDeathSwapLock), read by
-- every equip path via IsBossTrinketLocked, and cleared per-slot by
-- ReleaseDeathSwapLockForSlot (TSS_Death.lua) once that trinket is
-- confirmed used. .deathSwap records what earned the lock so release
-- only fires for the trinket that actually caused it. .lockEngagedAt
-- opens a 12s grace window (TSS_Combat.lua) so auto-swap cannot race
-- the boss-swap sequence. A passive locked trinket can never be
-- "used", so TSS_Combat.lua releases it once a queued on-use trinket
-- is ready instead of holding the slot forever.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local UnitBuff = UnitBuff or (RCC and RCC.Compat and RCC.Compat.UnitBuff)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_max, math_min = math.floor, math.max, math.min
local table_insert, table_remove = table.insert, table.remove
local GetTime = GetTime
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
local GetInventoryItemID = GetInventoryItemID
local GetInventoryItemLink = GetInventoryItemLink
local GetInventoryItemCooldown = GetInventoryItemCooldown
local InCombatLockdown = InCombatLockdown
local UnitAffectingCombat = UnitAffectingCombat
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local C_Container = C_Container
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local WRF = _G.Readycheck
if not WRF then return end
WRF._tssInit = WRF._tssInit or {}
WRF._tss = WRF._tss or {}
WRF._tssInit[#WRF._tssInit + 1] = function()
    local RC = _G.Readycheck
    local _tss = WRF._tss
    local SLOT_KEYS = {"slot1", "slot2"}
    local INVENTORY_SLOTS = {13, 14}

    RC.trinketSwapSystem = {
        enabled = false,
        lastSwapTime = {slot1 = 0, slot2 = 0},
        -- Anti-spam throttle: SwapTrinket (TSS_Queue.lua) refuses a
        -- second swap for a slot within this many seconds.
        swapCooldown = 1.0,
        availableTrinkets = {},
        currentQueue = "default",
        pollingActive = false,
        ourSwapInProgress = false,
        manualSwapActive = {slot1 = false, slot2 = false},
        manualSwapItem = {slot1 = nil, slot2 = nil},
        -- [slotKey] = { itemId, at }. A trinket this addon pushed into a
        -- slot by exchanging with the other one. It was not the user's
        -- choice, so the rotation must be free to replace it instead of
        -- treating an unqueued trinket as a deliberate manual pick.
        displacedInto = {},
        lastCombatChange = 0,
        combatStateStable = true,
        pollCount = 0,
        itemInfoCache = {},
        lastScanTime = 0,
        trinketPool = {},
        pendingUpdate = false,

        trinketStates = {
            slot1 = {
                itemId = nil, isOnUse = false, cooldownStart = 0, cooldownDuration = 0,
                fullCooldown = 0, lastEquipTime = 0, wasOnCooldown = false,
                buffExpireTime = 0, cooldownDetectedAt = 0, lockedOutUntil = 0, expectedItemId = nil,
                inheritedCD = false
            },
            slot2 = {
                itemId = nil, isOnUse = false, cooldownStart = 0, cooldownDuration = 0,
                fullCooldown = 0, lastEquipTime = 0, wasOnCooldown = false,
                buffExpireTime = 0, cooldownDetectedAt = 0, lockedOutUntil = 0, expectedItemId = nil,
                inheritedCD = false
            }
        },

        bagTrinketCooldowns = {},
        bagLocationLookup = {},
        retryCount = {slot1 = 0, slot2 = 0},
        retryPending = {slot1 = false, slot2 = false},
        equipRetryActive = false,
        equipRetryElapsed = 0,
        equipRetryMaxTime = 0,

        queueNames = {
            default = "Default", config1 = "Config 1", config2 = "Config 2",
            config3 = "Config 3", config4 = "Config 4", config5 = "Config 5"
        },
        queueOrder = {"default", "config1", "config2", "config3", "config4", "config5"}
    }

    function RC:GetCachedTrinketInfo(itemId)
        if not itemId then return nil end
        local cache = self.trinketSwapSystem.itemInfoCache
        if not cache[itemId] then
            local name, link, rarity, _, _, _, _, _, _, icon = GetItemInfo(itemId)
            if name then
                cache[itemId] = {name = name, link = link, rarity = rarity, icon = icon}
            end
        end
        return cache[itemId]
    end

    -- The old built-in "Priority" flag (Kiss, Slayer's Crest) is retired
    -- (2026-10-23): the player's own order decides - their list, or their
    -- priority numbers (RC:GetRankedQueue). Kept as a function for callers.
    function RC:IsPriorityTrinket(itemId)
        return false
    end

    RC.gearSwapState = {
        lastBossTarget = nil,
        lastEquippedSet = nil,
        postCombatSet = nil
    }

    RC.bossTrinketState = {
        locked      = {},
        appliedBoss = nil,
        appliedRaid = nil,
    }

    -- Is the given slot currently protected from auto-swap by a boss lock?
    function RC:IsBossTrinketLocked(slotNumber)
        return RC.bossTrinketState
           and RC.bossTrinketState.locked
           and RC.bossTrinketState.locked[slotNumber] ~= nil
    end

    -- allowExchange: the caller is setting BOTH trinket slots and accepts
    -- that pulling from the other slot displaces its trinket, because it
    -- is about to overwrite that slot too. Single-slot callers must leave
    -- it false.
    function RC:EquipTrinketById(itemId, slotNumber, forceSeq, allowExchange, mode)
        if not itemId or not slotNumber then return false end
        if InCombatLockdown() then
            self:DebugPrint("EquipTrinketById blocked - in combat", "trinket")
            return false
        end
        local inventorySlot = INVENTORY_SLOTS[slotNumber]
        if not inventorySlot then return false end
        local currentItemId = GetInventoryItemID("player", inventorySlot)
        -- Idempotent: a repeated call (e.g. a spammed gear-set macro) for
        -- a trinket already in place is a no-op, not a fresh equip.
        if currentItemId == itemId then
            self:DebugPrint("EquipTrinketById: " .. itemId .. " already in slot " .. slotNumber, "trinket")
            return true
        end

        local otherSlotNumber = slotNumber == 1 and 2 or 1
        local otherInventorySlot = INVENTORY_SLOTS[otherSlotNumber]
        if otherInventorySlot then
            local otherItemId = GetInventoryItemID("player", otherInventorySlot)
            -- Taking the trinket from the OTHER equipped slot is an
            -- exchange, not a move: this slot's current trinket is pushed
            -- over there. That is only acceptable when the caller is
            -- setting BOTH slots and will immediately correct the other
            -- one. For a single-slot request it silently plants a trinket
            -- in a slot the user never configured for it - which is how
            -- Hand of Justice ended up in slot 13 when it was only ever
            -- queued for slot 14.
            --
            -- So when a bag copy exists, always prefer it: the displaced
            -- trinket goes back to the bag and the other slot is untouched.
            if otherItemId == itemId and not allowExchange
                and self:FindTrinketInBags(itemId) then
                self:DebugPrint("EquipTrinketById: " .. itemId
                    .. " is in the other slot but also in bags - using the bag copy"
                    .. " so slot " .. otherSlotNumber .. " is left alone", "trinket")
                otherItemId = nil
            end
            if otherItemId == itemId then
                if not allowExchange then
                    self:DebugPrint("EquipTrinketById: " .. itemId
                        .. " only exists in slot " .. otherSlotNumber
                        .. " - exchanging, slot " .. otherSlotNumber
                        .. " will receive " .. tostring(currentItemId), "trinket")
                end
                self:DebugPrint("EquipTrinketById: " .. itemId .. " is in the other trinket slot - moving directly", "trinket")
                -- this slot's trinket comes off here: it may not be one that
                -- has to stay (see TrinketSwapVeto). The one being moved
                -- stays equipped, so it is not asked about.
                local veto = self:TrinketSwapVeto(slotNumber, itemId, mode)
                if veto then
                    self:DebugPrint("EquipTrinketById: move kept off - " .. veto, "trinket")
                    if self.DiagLog then self:DiagLog("trinket", "slot %d kept: %s (wanted %s from slot %d, %s)", slotNumber, veto, self:TrinketDiagName(itemId), otherSlotNumber, tostring(mode or "auto")) end
                    return false
                end

                local sysT = self.trinketSwapSystem
                local thisKey  = SLOT_KEYS[slotNumber]
                local otherKey = SLOT_KEYS[otherSlotNumber]
                sysT.ourSwapInProgress           = true
                sysT.manualSwapActive[thisKey]   = false
                sysT.manualSwapActive[otherKey]  = false
                sysT.manualSwapItem[thisKey]     = nil
                sysT.manualSwapItem[otherKey]    = nil

                if RC.Equip:SlotToSlot(otherInventorySlot, inventorySlot, { by = "tss", method = "cursor" }) then
                    sysT.lastSwapTime[thisKey]  = GetTime()
                    sysT.lastSwapTime[otherKey] = GetTime()

                    local stateThis  = sysT.trinketStates and sysT.trinketStates[thisKey]
                    local stateOther = sysT.trinketStates and sysT.trinketStates[otherKey]
                    if stateThis  then stateThis.expectedItemId  = itemId end
                    -- The direct move exchanges the two slots: the other slot
                    -- receives this slot's previous trinket. Expect it there so
                    -- the displaced trinket isn't mis-detected as a manual
                    -- swap and permanently pinned.
                    if stateOther then stateOther.expectedItemId = currentItemId end
                    -- Record WHY it is there. expectedItemId above only
                    -- stops the manual-swap pin; the rotation has its own
                    -- hold for an unqueued on-use trinket, and without
                    -- this the displaced item sits in the wrong slot until
                    -- it is used - which for a trinket you never press is
                    -- forever.
                    if currentItemId then
                        sysT.displacedInto[otherKey] = {
                            itemId = currentItemId, at = GetTime(),
                        }
                    end
                    sysT.displacedInto[thisKey] = nil

                    C_Timer.After(1.2, function()
                        if RC.trinketSwapSystem then
                            RC.trinketSwapSystem.ourSwapInProgress = false
                        end
                    end)

                    return true
                end

                sysT.ourSwapInProgress = false
                return false
            end
        end

        local loc = self:FindTrinketInBags(itemId)
        if not loc then
            self:DebugPrint("EquipTrinketById: " .. itemId .. " not found in bags or equipped slots", "trinket")
            return false
        end
        return self:SwapTrinket(loc.bag, loc.slot, inventorySlot, slotNumber, true, forceSeq, mode) and true or false
    end

    function RC:EquipTrinketSet(slotTable, reason)
        if not slotTable then return end
        -- who is asking decides how firmly (see TrinketSwapVeto)
        local r = tostring(reason or "")
        local mode = slotTable.mode
            or ((r:find("^boss death") and "death") or ((r:find("^boss") or r:find("^engage")) and "boss") or "auto")
        if self.DiagLog then
            self:DiagLog("trinket", "asked (%s): slot 1 %s, slot 2 %s", r,
                slotTable.slot1 and self:TrinketDiagName(slotTable.slot1) or "-",
                slotTable.slot2 and self:TrinketDiagName(slotTable.slot2) or "-")
        end

        local want1 = slotTable.slot1
        local want2 = slotTable.slot2
        if RC.NoteSwapIntent then RC:NoteSwapIntent(RCL["Trinkets"], nil, true) end

        if want1 and want2 and want1 == want2 then
            self:DebugPrint("EquipTrinketSet: want1 == want2 (" .. want1 .. ") - skipping", "trinket")
            return
        end

        local cur1 = GetInventoryItemID("player", INVENTORY_SLOTS[1])
        local cur2 = GetInventoryItemID("player", INVENTORY_SLOTS[2])

        local need1 = want1 and want1 ~= 0 and want1 ~= cur1
        local need2 = want2 and want2 ~= 0 and want2 ~= cur2

        if need1 and need2 and want2 == cur1 and want1 ~= cur2 then
            self:DebugPrint("EquipTrinketSet: cross-slot  -  equip slot1 first then slot2", "trinket")
            self:EquipTrinketById(want1, 1, nil, true, mode)
            C_Timer.After(0.4, function()
                if not InCombatLockdown() then
                    RC:EquipTrinketById(want2, 2, true, true, mode)
                    RC:DebugPrint("EquipTrinketSet (" .. (reason or "?") .. "): cross-slot complete", "trinket")
                    C_Timer.After(0.5, function()
                        if not InCombatLockdown() then RC:EquipTrinketById(want2, 2, true, true, mode) end
                    end)
                end
            end)
            return

        elseif need1 and need2 and want1 == cur2 and want2 ~= cur1 then
            self:DebugPrint("EquipTrinketSet: cross-slot  -  equip slot2 first then slot1", "trinket")
            self:EquipTrinketById(want2, 2, nil, true, mode)
            C_Timer.After(0.4, function()
                if not InCombatLockdown() then
                    RC:EquipTrinketById(want1, 1, true, true, mode)
                    RC:DebugPrint("EquipTrinketSet (" .. (reason or "?") .. "): cross-slot complete", "trinket")
                    C_Timer.After(0.5, function()
                        if not InCombatLockdown() then RC:EquipTrinketById(want1, 1, true, true, mode) end
                    end)
                end
            end)
            return

        elseif need1 and need2 and want1 == cur2 and want2 == cur1 then
            self:DebugPrint("EquipTrinketSet: full exchange  -  single slot-to-slot swap", "trinket")
            self:EquipTrinketById(want1, 1, nil, true, mode)
            C_Timer.After(0.4, function()
                if not InCombatLockdown() then
                    RC:EquipTrinketById(want2, 2, true, true, mode)
                    RC:DebugPrint("EquipTrinketSet (" .. (reason or "?") .. "): full exchange complete", "trinket")
                end
            end)
            return
        end

        local equipped = 0
        for slotNumber = 1, 2 do
            local key    = SLOT_KEYS[slotNumber]
            local itemId = slotTable[key]
            if itemId and itemId ~= 0 then
                if self:EquipTrinketById(itemId, slotNumber, nil, nil, mode) then
                    equipped = equipped + 1
                end
            end
        end
        if equipped > 0 then
            self:DebugPrint("EquipTrinketSet (" .. (reason or "unknown") .. "): equipped " .. equipped .. " trinket(s)", "trinket")
        end
    end

    function RC:RunPendingDeathTrinketSwap()
        if not RC.pendingDeathTrinketSwap then return end
        local dt = RC.pendingDeathTrinketSwap
        RC.pendingDeathTrinketSwap = nil
        -- 8s window read by ProcessTrinketRotation (TSS_Combat.lua) to
        -- hold rotation off these slots while this sequence is in flight.
        if RC.bossTrinketState then
            RC.bossTrinketState.deathTrinketApplyingUntil = GetTime() + 8
            RC.bossTrinketState.deathTrinketApplyingSlots = {
                [1] = (dt.slot1 and dt.slot1 ~= 0) and true or nil,
                [2] = (dt.slot2 and dt.slot2 ~= 0) and true or nil,
            }
        end
        local MAX_ATTEMPTS, RETRY_GAP = RC:GearSwapRetryCfg()
        local attempt = 0

        local function Verify()
            local e13 = GetInventoryItemID and GetInventoryItemID("player", 13) or nil
            local e14 = GetInventoryItemID and GetInventoryItemID("player", 14) or nil
            local ok1 = (not dt.slot1) or dt.slot1 == 0 or e13 == dt.slot1
            local ok2 = (not dt.slot2) or dt.slot2 == 0 or e14 == dt.slot2
            return ok1 and ok2, e13, e14
        end

        -- Only engages the boss lock after Verify() below confirms both
        -- trinkets are actually equipped - never locks a slot pre-emptively.
        local function EngageDeathSwapLock()
            if not RC.bossTrinketState then return end
            RC.bossTrinketState.locked = RC.bossTrinketState.locked or {}
            if dt.slot1 and dt.slot1 ~= 0 then
                RC.bossTrinketState.locked[1] = dt.slot1
            end
            if dt.slot2 and dt.slot2 ~= 0 then
                RC.bossTrinketState.locked[2] = dt.slot2
            end
            RC.bossTrinketState.lockEngagedAt = GetTime()
            RC.bossTrinketState.deathSwap = {
                slot1  = dt.slot1,
                slot2  = dt.slot2,
                boss   = dt.boss,
                armedAt = GetTime(),
            }
            RC:DebugPrint(string.format(
                RCL["Death trinket lock engaged for %s (slots %s / %s) - will release on use"],
                dt.boss or "?", tostring(dt.slot1), tostring(dt.slot2)), "trinket")
        end

        local deferred = 0
        local function DoAttempt()
            attempt = attempt + 1
            if InCombatLockdown() then
                local st = RC.bossTrinketState
                local newBossActive = st and st.appliedBoss
                                      and st.appliedBoss ~= dt.boss
                                      and not dt.isRoute
                if not newBossActive then
                    RC.pendingDeathTrinketSwap = dt
                    RC:DebugPrint("Death trinket swap re-queued: combat re-engaged with adds", "trinket")
                else
                    RC:DebugPrint("Death trinket swap dropped: different boss now active", "trinket")
                end
                return
            end
            local st = RC.bossTrinketState
            if st and st.appliedBoss and st.appliedBoss ~= dt.boss and not dt.isRoute then
                RC:DebugPrint(string.format(
                    RCL["Death trinket swap for %s aborted - different boss now active (%s)"],
                    dt.boss or "?", tostring(st.appliedBoss)), "trinket")
                return
            end
            if RC.NoteSwapIntent and attempt == 1 then
                RC:NoteSwapIntent(RCL["Trinkets"], nil)
                if dt.boss and RC.NoteSwapContext then
                    RC:NoteSwapContext(dt.isRoute and dt.boss or (RCL["After "] .. dt.boss))
                end
            end
            -- a slot whose trinket has to stay (a buff still running, or a
            -- ready one for one still cooling down) is left as it is
            -- a buff still running only delays it (checked again every 4s,
            -- for up to 40s); a ready one for one still cooling down drops it
            local wait = false
            for s = 1, 2 do
                local want = dt["slot" .. s]
                if want and want ~= 0 and GetInventoryItemID("player", INVENTORY_SLOTS[s]) ~= want
                    and RC:TrinketKeepReason(s) == "buff" then
                    wait = true
                end
            end
            if wait and deferred < 10 then
                deferred = deferred + 1
                attempt = attempt - 1
                if deferred == 1 then
                    RC:DebugPrint("Death trinket swap for " .. tostring(dt.boss) .. " waits for a trinket buff to end", "trinket")
                    if RC.DiagLog then RC:DiagLog("trinket", "after %s: waiting for a trinket buff to end", tostring(dt.boss)) end
                end
                C_Timer.After(4, DoAttempt)
                return
            end
            for s = 1, 2 do
                local key = "slot" .. s
                local want = dt[key]
                if want and want ~= 0 and GetInventoryItemID("player", INVENTORY_SLOTS[s]) ~= want then
                    local veto = RC:TrinketSwapVeto(s, want, "death")
                    if veto then
                        RC:DebugPrint("Death trinket swap: slot " .. s .. " kept - " .. veto, "trinket")
                        if RC.DiagLog then RC:DiagLog("trinket", "after %s: slot %d kept - %s", tostring(dt.boss), s, veto) end
                        dt[key] = nil
                    end
                end
            end
            if not (dt.slot1 and dt.slot1 ~= 0) and not (dt.slot2 and dt.slot2 ~= 0) then return end
            RC:EquipTrinketSet({ slot1 = dt.slot1, slot2 = dt.slot2 },
                "boss death: " .. (dt.boss or "?") .. " attempt " .. attempt)
            C_Timer.After(0.6, function()
                local ok, e13, e14 = Verify()
                if ok then
                    RC:DebugPrint(string.format(RCL["Death trinket swap verified (attempt %d) for %s"],
                        attempt, dt.boss or "?"), "trinket")
                    -- (an old rotation replay is not a boss's pick: no lock)
                    if dt.src ~= "tss" then EngageDeathSwapLock() end
                elseif attempt < MAX_ATTEMPTS then
                    RC:DebugPrint(string.format(RCL["Death trinket swap attempt %d incomplete (t13=%s/%s t14=%s/%s) - retrying"],
                        attempt, tostring(e13), tostring(dt.slot1), tostring(e14), tostring(dt.slot2)), "trinket")
                    C_Timer.After(RETRY_GAP, DoAttempt)
                else
                    RC:DebugPrint(string.format(RCL["Death trinket swap could not fully equip for %s after %d attempts"],
                        dt.boss or "?", MAX_ATTEMPTS), "trinket")
                    local off = {}
                    if dt.slot1 and dt.slot1 ~= 0 and e13 ~= dt.slot1 then off[#off + 1] = 13 end
                    if dt.slot2 and dt.slot2 ~= 0 and e14 ~= dt.slot2 then off[#off + 1] = 14 end
                    RC:GearSwapWarn(RCL["after-boss trinkets for "] .. (dt.boss or "?"), MAX_ATTEMPTS, off)
                end
            end)
        end

        local startDelay = dt.hasFullSet and 1.0 or 0.3
        C_Timer.After(startDelay, DoAttempt)
    end

    _tss.SLOT_KEYS = SLOT_KEYS
    _tss.INVENTORY_SLOTS = INVENTORY_SLOTS

    -- How early a trinket sitting in bags counts as "ready" and may be
    -- pre-equipped. Priority trinkets used to get a wider 45s window than
    -- everything else, which left a Priority trinket eligible almost
    -- continuously so nothing else in the queue ever got a turn. One
    -- window for everything - queue order decides, not the flag.
    _tss.PRE_EQUIP_WINDOW = 33
end
