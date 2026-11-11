------------------------------------------------------------------------
-- Readycheck - Trinket Swap Boss Death Handling
-- Owns OnBossUnitDied (arms death-trinket/death-slot swaps that fire
-- once combat ends), ReleaseDeathSwapLockForSlot and
-- ReleaseBossTrinketLock (the release half of the lock machine defined
-- in TSS_Locks.lua), and ScanAvailableTrinkets (bag + equipped scan).
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)

local pairs, tostring = pairs, tostring
local GetTime = GetTime
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local GetInventoryItemID = GetInventoryItemID
local GetInventoryItemLink = GetInventoryItemLink
local InCombatLockdown = InCombatLockdown
local UnitAffectingCombat = UnitAffectingCombat
local C_Container = C_Container
local C_Timer = C_Timer
local WRF = _G.Readycheck
if not WRF then return end
WRF._tssInit = WRF._tssInit or {}
WRF._tss = WRF._tss or {}
WRF._tssInit[#WRF._tssInit + 1] = function()
    local RC = _G.Readycheck
    local _tss = WRF._tss
    local INVENTORY_SLOTS = _tss.INVENTORY_SLOTS
    function RC:RunPendingDeathSlotSwap()
        if not RC.pendingDeathSlotSwap then return end
        local pending = RC.pendingDeathSlotSwap
        RC.pendingDeathSlotSwap = nil

        local slotsMap = pending.slots
        local enchMap  = pending.enchants
        if not slotsMap or not next(slotsMap) then return end

        local MAX_ATTEMPTS, RETRY_GAP = RC:GearSwapRetryCfg()
        local attempt = 0

        local function Verify()
            local mismatches = {}
            for invSlot, wantId in pairs(slotsMap) do
                local haveId, haveEnch = RC:GetEquippedIdEnchant(invSlot)
                local wantEnch = enchMap and enchMap[invSlot]
                if wantId == -1 then
                    if haveId then mismatches[#mismatches + 1] = invSlot end
                elseif haveId ~= wantId or (wantEnch and wantEnch ~= 0 and haveEnch ~= wantEnch) then
                    mismatches[#mismatches + 1] = invSlot
                end
            end
            return #mismatches == 0, mismatches
        end

        local function DoAttempt()
            attempt = attempt + 1
            if InCombatLockdown() then
                local st = RC.bossTrinketState
                local newBossActive = st and st.appliedBoss
                                      and st.appliedBoss ~= pending.boss
                                      and not st.deathSwap
                                      and not pending.isRoute
                if not newBossActive then
                    RC.pendingDeathSlotSwap = pending
                    RC:DebugPrint("Death slot swap re-queued: combat re-engaged with adds", "gear")
                else
                    RC:DebugPrint("Death slot swap dropped: different boss now active", "gear")
                end
                return
            end

            local st = RC.bossTrinketState
            if st and st.appliedBoss and st.appliedBoss ~= pending.boss
               and not st.deathSwap and not pending.isRoute then
                RC:DebugPrint(string.format(
                    RCL["Death slot swap for %s skipped - new boss lock active (%s)"],
                    pending.boss or "?", tostring(st.appliedBoss)), "gear")
                return
            end

            if RC.NoteSwapIntent and attempt == 1 then
                RC:NoteSwapIntent(RCL["Slot gear"], nil)
                if pending.boss and RC.NoteSwapContext then
                    RC:NoteSwapContext(pending.isRoute and pending.boss or (RCL["After "] .. pending.boss))
                end
            end
            RC:ApplyBossForceEquipSlots(slotsMap,
                "boss death: " .. (pending.boss or "?") .. " attempt " .. attempt,
                enchMap)

            C_Timer.After(0.6, function()
                local ok, mismatches = Verify()
                if ok then
                    RC:DebugPrint(string.format(RCL["Death slot swap verified (attempt %d) for %s"],
                        attempt, pending.boss or "?"), "gear")
                elseif attempt < MAX_ATTEMPTS then
                    RC:DebugPrint(string.format(RCL["Death slot swap attempt %d incomplete (slots %s) - retrying"],
                        attempt, table.concat(mismatches or {}, ",")), "gear")
                    C_Timer.After(RETRY_GAP, DoAttempt)
                else
                    RC:DebugPrint(string.format(RCL["Death slot swap could not fully equip for %s after %d attempts (slots still off: %s)"],
                        pending.boss or "?", MAX_ATTEMPTS, table.concat(mismatches or {}, ",")), "gear")
                    RC:GearSwapWarn(RCL["after-boss gear for "] .. (pending.boss or "?"), MAX_ATTEMPTS, mismatches)
                end
            end)
        end

        local startDelay = pending.hasFullSet and 1.0 or 0.3
        C_Timer.After(startDelay, DoAttempt)
    end
    -- Only releases if the locked id still matches this boss's recorded
    -- deathSwap entry, so a stale call can't release someone else's lock.
    function RC:ReleaseDeathSwapLockForSlot(slotNumber)
        local st = RC.bossTrinketState
        if not st or not st.deathSwap then return end
        if not st.locked then return end
        if not st.locked[slotNumber] then return end

        local ds = st.deathSwap
        local matches = (slotNumber == 1 and ds.slot1 and ds.slot1 ~= 0)
                     or (slotNumber == 2 and ds.slot2 and ds.slot2 ~= 0)
        if not matches then return end

        st.locked[slotNumber] = nil
        RC:DebugPrint(string.format(
            RCL["Death trinket lock released for slot %d (%s used)"],
            slotNumber, ds.boss or "?"), "trinket")

        local slot1Done = (not ds.slot1) or ds.slot1 == 0 or not st.locked[1]
        local slot2Done = (not ds.slot2) or ds.slot2 == 0 or not st.locked[2]
        if slot1Done and slot2Done then
            st.deathSwap = nil
            RC:DebugPrint("Death trinket lock fully released - auto-swap resumes", "trinket")
        end
    end

    function RC:OnBossUnitDied(destGUID, destName, raidNameOpt)
        if not destName then return end
        -- after-kill gear comes from a Classic Era boss config (Core_Flavor)
        if not self:FeatureOn("boss_gear_kill") then return end

        local raidName = raidNameOpt
                       or (RC.bossTrinketState and RC.bossTrinketState.appliedRaid)
                       or (self.GetEffectiveRaidName and self:GetEffectiveRaidName())
                       or nil
        if not raidName then
            RC:DebugPrint("Death gear: no raid context for " .. destName, "gear")
            return
        end

        local bossName = self:GetEncounterNameForBoss(raidName, destName) or destName

        -- 5s dedupe: multiple death events for the same boss (add
        -- cleanup, multi-hit kill credit) must not re-arm the death
        -- swap repeatedly.
        RC._lastBossDeathApply = RC._lastBossDeathApply or {}
        local lastT = RC._lastBossDeathApply[bossName]
        if lastT and (GetTime() - lastT) < 5 then return end
        RC._lastBossDeathApply[bossName] = GetTime()

        local raidProfile = self.GetActiveRaidProfile and self:GetActiveRaidProfile(raidName)
        local bossCfg = raidProfile and raidProfile.bosses and raidProfile.bosses[bossName]
        local fe = bossCfg and bossCfg.forceEquip
        if not fe then
            return
        end

        local deathConfig = fe.deathConfig
        if deathConfig and deathConfig ~= ""
           and self.db.trinketSwap and self.db.trinketSwap.enabled
           and self.trinketSwapSystem.queueNames[deathConfig]
           and self.trinketSwapSystem.currentQueue ~= deathConfig then
            local cfgLabel = self.trinketSwapSystem.queueNames[deathConfig]
            if InCombatLockdown() then
                RC.pendingDeathConfigSwitch = { config = deathConfig, boss = bossName }
                RC:DebugPrint("Trinket config switch to '" .. cfgLabel .. "' queued for "
                    .. bossName .. " - fires when combat ends", "trinket")
            elseif self:SetActiveQueue(deathConfig) then
                RC:Print(RCL["Trinket config: "] .. cfgLabel .. " (" .. bossName .. RCL[" killed)"])
            end
        end
        local postCombatSet = bossCfg.abilities
                              and bossCfg.abilities.gearswap
                              and bossCfg.abilities.gearswap.postCombatSet
        local hasFullSet = postCombatSet and postCombatSet ~= ""
        if not hasFullSet then
            local GM = RC.GearManager
            if GM and GM.settings and GM.settings.fungalBloomEnabled
            and (GM.settings.fungalBloomActiveSet ~= "" or GM.settings.fungalBloomSet ~= "") then
                hasFullSet = true
            end
        end

        if postCombatSet and postCombatSet ~= "" then
            RC.gearSwapState = RC.gearSwapState or {}
            if not RC.gearSwapState.postCombatSet or RC.gearSwapState.postCombatSet == "" then
                local gsCfg = bossCfg.abilities and bossCfg.abilities.gearswap
                local gearSet = gsCfg and (gsCfg.gearSet or gsCfg.itemRackSet)
                if gearSet and gearSet ~= "" then
                    RC.gearSwapState.lastEquippedSet = gearSet
                else
                    RC.gearSwapState.lastEquippedSet = postCombatSet
                end
                RC.gearSwapState.postCombatSet  = postCombatSet
                RC.gearSwapState.lastBossTarget = bossName
                if not RC.gearSwapState.engagedInCombat then
                    RC.gearSwapState.engagedInCombat = bossName
                end
                RC:DebugPrint("OnBossUnitDied: armed post-combat set '" .. postCombatSet
                    .. "' for " .. bossName .. " (authoritative kill fallback)", "gear")
            end
        end

        local deathT1 = fe.deathSlot1 or (fe.onDeath and fe.onDeath[13])
        local deathT2 = fe.deathSlot2 or (fe.onDeath and fe.onDeath[14])

        local deathSlotsMap = nil
        local deathEnchants = nil
        if fe.onDeath then
            for invSlot, itemId in pairs(fe.onDeath) do
                if invSlot ~= 13 and invSlot ~= 14 and itemId and itemId ~= 0 then
                    deathSlotsMap = deathSlotsMap or {}
                    deathSlotsMap[invSlot] = itemId
                    local e = fe.onDeathEnchant and fe.onDeathEnchant[invSlot]
                    if e and e ~= 0 then
                        deathEnchants = deathEnchants or {}
                        deathEnchants[invSlot] = e
                    end
                end
            end
        end

        local hasDeathTrinkets = deathT1 or deathT2
        local hasDeathSlots    = deathSlotsMap ~= nil

        if not hasDeathTrinkets and not hasDeathSlots then
            return
        end

        if RC.bossTrinketState and RC.bossTrinketState.appliedBoss == bossName then
            self:ReleaseBossTrinketLock("boss died")
        end

        if hasDeathTrinkets then
            RC.pendingDeathTrinketSwap = {
                slot1 = deathT1, slot2 = deathT2,
                boss = bossName,
                src = "boss",
                hasFullSet = hasFullSet,
            }
            RC:DebugPrint("Death trinket swap queued for " .. bossName
                .. (hasFullSet and " (after full set)" or "")
                .. " - will fire when combat ends", "trinket")
        end
        if hasDeathSlots then
            RC.pendingDeathSlotSwap = {
                src = "boss",
                slots = deathSlotsMap,
                enchants = deathEnchants,
                boss = bossName,
                hasFullSet = hasFullSet,
            }
            local count = 0
            for _ in pairs(deathSlotsMap) do count = count + 1 end
            RC:DebugPrint("Death slot swap queued for " .. bossName .. " (" .. count .. " slot(s)"
                .. (hasFullSet and ", after full set" or "")
                .. ") - will fire when combat ends", "gear")
        end

        if InCombatLockdown() and RC.QueueGearSwap then
            if postCombatSet and postCombatSet ~= "" then
                RC:QueueGearSwap(postCombatSet)
            end
            local function previewTrinket(itemId, invSlot)
                if not itemId or itemId == 0 then return end
                local loc = self.FindTrinketInBags and self:FindTrinketInBags(itemId)
                if loc then
                    RC:QueueGearSwap({ display = true, inventorySlot = invSlot, bag = loc.bag, slot = loc.slot })
                end
            end
            previewTrinket(deathT1, 13)
            previewTrinket(deathT2, 14)
            if deathSlotsMap then
                for invSlot, itemId in pairs(deathSlotsMap) do
                    if itemId and itemId ~= 0 then
                        local b, s = RC.Bags:Find(itemId)
                        if b then
                            RC:QueueGearSwap({ display = true, inventorySlot = invSlot, bag = b, slot = s })
                        end
                    end
                end
            end
        end

        if not InCombatLockdown() then
            C_Timer.After(0.5, function()
                if InCombatLockdown() then return end
                if RC.FireDeathGearSwap then
                    RC:FireDeathGearSwap()
                else
                    if RC.RunPendingDeathTrinketSwap then RC:RunPendingDeathTrinketSwap() end
                    if RC.RunPendingDeathSlotSwap    then RC:RunPendingDeathSlotSwap()    end
                end
            end)
        end
    end

    -- Full reset, not a per-slot release: used when the boss context
    -- itself changes (re-apply, boss died), not when a trinket is "used".
    function RC:ReleaseBossTrinketLock(reason)
        if RC.bossTrinketState.appliedBoss then
            self:DebugPrint("ReleaseBossTrinketLock (" .. (reason or "unknown") .. "): was " .. tostring(RC.bossTrinketState.appliedBoss), "trinket")
        end
        RC.bossTrinketState.locked = {}
        RC.bossTrinketState.appliedBoss = nil
        RC.bossTrinketState.appliedRaid = nil
        RC.bossTrinketState.deathSwap = nil
        RC.bossTrinketState.lockEngagedAt = nil
    end

    -- Boss and trash gear swaps differ in exactly one thing: a boss config
    -- is keyed by the encounter name, a trash config by the mob's own
    -- name. Returns nil unless a usable gearswap config exists.
    -- For trash the encounter name is resolved last, so the lookup order
    -- of the two original functions is preserved byte for byte.
    local function ResolveGearSwapConfig(self, targetName, isTrash)
        local raidName = self:GetEffectiveRaidName()
        if not raidName then return nil end

        local encounterName, mobConfig
        if isTrash then
            mobConfig = self:GetMobConfig(raidName, targetName)
        else
            encounterName = self:GetEncounterNameForBoss(raidName, targetName)
            mobConfig = self:GetMobConfig(raidName, encounterName)
        end
        if not mobConfig then return nil end

        local gearswapConfig = mobConfig.abilities and mobConfig.abilities.gearswap
        if not gearswapConfig then return nil end

        local gearSetName = gearswapConfig.gearSet or gearswapConfig.itemRackSet
        if not gearSetName or gearSetName == "" then return nil end

        if isTrash then
            encounterName = self:GetEncounterNameForBoss(raidName, targetName) or targetName
        end

        return gearswapConfig, gearSetName, encounterName
    end

    function RC:CheckGearSwapForTarget(targetName, isTrash)
        if not targetName or UnitAffectingCombat("player") then return end

        local gearswapConfig, gearSetName, encounterName =
            ResolveGearSwapConfig(self, targetName, isTrash)
        if not gearswapConfig then return end

        local label = isTrash and "CheckTrashGearSwap" or "CheckBossGearSwap"

        if RC.gearSwapState
           and RC.gearSwapState.engageHandledBoss == encounterName
           and RC.gearSwapState.engageHandledTime
           and (GetTime() - RC.gearSwapState.engageHandledTime) < 30 then
            self:DebugPrint(label .. ": skipped (handled by ApplyBossForceEquip) for " .. targetName, "gear")
            self.gearSwapState.lastBossTarget = targetName
            self.gearSwapState.lastEquippedSet = gearSetName
            self.gearSwapState.postCombatSet = gearswapConfig.postCombatSet
            self.gearSwapState.postCombatBoss = (gearswapConfig.postCombatSet and gearswapConfig.postCombatSet ~= "") and encounterName or nil
            return true
        end

        self:DebugPrint(label .. ": Equipping " .. gearSetName .. " for " .. targetName, "gear")

        if self:EquipGearSet(gearSetName) then
            self.gearSwapState.lastBossTarget = targetName
            self.gearSwapState.lastEquippedSet = gearSetName
            self.gearSwapState.postCombatSet = gearswapConfig.postCombatSet
            self.gearSwapState.postCombatBoss = (gearswapConfig.postCombatSet and gearswapConfig.postCombatSet ~= "") and encounterName or nil
            return true
        end
        return false
    end

    -- Named "WithRetry" historically; it has never retried. It re-checks
    -- that the same target is still selected and the player is still out
    -- of combat, then makes a single swap attempt. Kept as-is.
    function RC:CheckGearSwapForTargetWithRetry(targetName, isTrash)
        local gearswapConfig = ResolveGearSwapConfig(self, targetName, isTrash)
        if not gearswapConfig then return end

        if UnitExists("target") and Readycheck.SafeName("target") == targetName and not UnitAffectingCombat("player") then
            self:CheckGearSwapForTarget(targetName, isTrash)
        end
    end

    function RC:CheckBossGearSwap(targetName)
        return self:CheckGearSwapForTarget(targetName, false)
    end

    function RC:CheckBossGearSwapWithRetry(targetName)
        self:CheckGearSwapForTargetWithRetry(targetName, false)
    end

    function RC:CheckTrashGearSwap(targetName)
        return self:CheckGearSwapForTarget(targetName, true)
    end

    function RC:CheckTrashGearSwapWithRetry(targetName)
        self:CheckGearSwapForTargetWithRetry(targetName, true)
    end

    -- 5s cache: BAG_UPDATE can fire repeatedly; this bounds how often
    -- the full bag+equipped iteration actually runs.
    function RC:ScanAvailableTrinkets()
        local now = GetTime()
        if self.trinketSwapSystem.lastScanTime and (now - self.trinketSwapSystem.lastScanTime) < 5 then
            return self.trinketSwapSystem.availableTrinkets
        end

        self.trinketSwapSystem.lastScanTime = now
        self.trinketSwapSystem.availableTrinkets = {}
        self.trinketSwapSystem.bagTrinketCooldowns = {}
        self.trinketSwapSystem.bagLocationLookup = {}

        for slotNumber = 1, 2 do
            local inventorySlot = INVENTORY_SLOTS[slotNumber]
            local itemId = GetInventoryItemID("player", inventorySlot)
            if itemId then
                local info = self:GetCachedTrinketInfo(itemId)
                if not info then
                    local name = GetItemInfo(itemId)
                    if not name then
                        local link = GetInventoryItemLink("player", inventorySlot)
                        name = link and link:match("%[(.-)%]") or ("Trinket (" .. itemId .. ")")
                    end
                    info = { name = name, icon = GetInventoryItemTexture("player", inventorySlot) or 0 }
                end
                table.insert(self.trinketSwapSystem.availableTrinkets, {
                    itemId = itemId, name = info.name, icon = info.icon,
                    equipped = true, slotNumber = slotNumber
                })
            end
        end

        RC.Bags:Each(function(bag, slot, itemId)
            local itemEquipLoc = select(4, GetItemInfoInstant(itemId))
            if not itemEquipLoc or itemEquipLoc == "" then
                itemEquipLoc = select(9, GetItemInfo(itemId))
            end
            if itemEquipLoc ~= "INVTYPE_TRINKET" then return end
            local info = self:GetCachedTrinketInfo(itemId)
            if not info then
                local itemInfo = C_Container.GetContainerItemInfo(bag, slot)
                local name = itemInfo and itemInfo.hyperlink and itemInfo.hyperlink:match("%[(.-)%]")
                info = { name = name or ("Trinket (" .. itemId .. ")"), icon = itemInfo and itemInfo.iconFileID or 0 }
            end
            table.insert(self.trinketSwapSystem.availableTrinkets, {
                itemId = itemId, name = info.name, icon = info.icon,
                equipped = false, bag = bag, slot = slot
            })
            self.trinketSwapSystem.bagLocationLookup[itemId] = {bag = bag, slot = slot}

            if self:IsTrinketOnUse(itemId) then
                local start, duration = self:GetItemCooldownSafe(itemId)
                if start and start > 0 and duration > 1.5 then
                    self.trinketSwapSystem.bagTrinketCooldowns[itemId] = {
                        start = start, duration = duration,
                        remaining = duration - (now - start)
                    }
                end
            end
        end)

        return self.trinketSwapSystem.availableTrinkets
    end
end
