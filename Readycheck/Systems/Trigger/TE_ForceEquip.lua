------------------------------------------------------------------------
-- Readycheck - Trigger Engine Force Equip
-- Applies a boss's forceEquip overrides on engage, layered over any full set.
-- forceEquip shape: slot1/slot2 (trinket shorthand for inventory 13/14),
-- onTarget[invSlot] = itemId, onTargetEnchant[invSlot], and the onDeath /
-- onDeathEnchant pair that TE_GearSwap fires after the kill.
-- itemId 0 means "no override for this slot"; -1 means unequip into bags.
-- Nothing here runs under combat lockdown - slot requests are stashed on
-- RC._pendingOnTargetSlots and replayed by TE_Events at the regen edge.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)
local UnitBuff = UnitBuff or (RCC and RCC.Compat and RCC.Compat.UnitBuff)
local UnitDebuff = UnitDebuff or (RCC and RCC.Compat and RCC.Compat.UnitDebuff)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local GetTime, UnitGUID, UnitHealth, UnitHealthMax = GetTime, UnitGUID, UnitHealth, UnitHealthMax
local UnitExists, UnitIsDead, UnitName = UnitExists, UnitIsDead, UnitName
local UnitAffectingCombat, InCombatLockdown = UnitAffectingCombat, InCombatLockdown
local GetSpellCooldown = GetSpellCooldown or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetSpellCooldown)
local C_Timer = C_Timer
local wipe = wipe
local string_format = string.format
local string_lower = string.lower
local string_find = string.find

local reuseAbilitiesToShow = {}
local reuseMacroCasts = {}
local reuseAbilitiesRemoved = {}
local RC = _G.Readycheck
if not RC then return end
RC._tes = RC._tes or {}
local _tes = RC._tes
    function RC:ApplyBossForceEquip(forceEquip, encounterName, raidName, options)
        if InCombatLockdown() then return end
        if not forceEquip then return end
        options = options or {}

        local trinket1 = forceEquip.slot1 or (forceEquip.onTarget and forceEquip.onTarget[13])
        local trinket2 = forceEquip.slot2 or (forceEquip.onTarget and forceEquip.onTarget[14])

        local nonTrinketSlots = nil
        local nonTrinketEnchants = nil
        if forceEquip.onTarget then
            for invSlot, itemId in pairs(forceEquip.onTarget) do
                if invSlot ~= 13 and invSlot ~= 14 and itemId and itemId ~= 0 then
                    nonTrinketSlots = nonTrinketSlots or {}
                    nonTrinketSlots[invSlot] = itemId
                    local e = forceEquip.onTargetEnchant and forceEquip.onTargetEnchant[invSlot]
                    if e and e ~= 0 then
                        nonTrinketEnchants = nonTrinketEnchants or {}
                        nonTrinketEnchants[invSlot] = e
                    end
                end
            end
        end

        local hasTrinkets   = trinket1 or trinket2
        local hasOtherSlots = nonTrinketSlots ~= nil
        local gearSetName   = options.gearSetName
        local hasFullSet    = gearSetName and gearSetName ~= ""

        if not hasFullSet and not hasTrinkets and not hasOtherSlots then return end

        -- 30s dedupe: re-targeting the same boss during a fight must not re-run
        -- the whole engage. Cleared on target loss and on an ENCOUNTER_END wipe.
        if RC.gearSwapState
           and RC.gearSwapState.engageHandledBoss == encounterName
           and RC.gearSwapState.engageHandledTime
           and (GetTime() - RC.gearSwapState.engageHandledTime) < 30 then
            if RC:IsDebugEnabled("gear") then
                RC:DebugPrint("ApplyBossForceEquip: skipped (already handled " .. tostring(encounterName) .. ")", "gear")
            end
            return
        end

        RC.gearSwapState = RC.gearSwapState or {}
        RC.gearSwapState.engageHandledBoss = encounterName
        RC.gearSwapState.engageHandledTime = GetTime()

        RC.gearSwapState._swapGen = (RC.gearSwapState._swapGen or 0) + 1

        RC.gearSwapState._verifyGen = (RC.gearSwapState._verifyGen or 0) + 1

        RC.gearSwapState.engagedInCombat = nil

        if UnitExists("target") then
            RC.gearSwapState.engagedBossGUID = Readycheck.SafeGUID("target")
        end
        RC.gearSwapState._postSwapActiveSet   = nil
        RC.gearSwapState._postSwapActiveUntil = nil

        -- Engage the boss trinket lock BEFORE any gear moves so the trinket
        -- auto-swap can never race the boss swap and yank a boss trinket.
        -- Trinkets sourced from the full set (not just per-slot overrides)
        -- are locked too.
        local setTrinket1, setTrinket2
        if hasFullSet then
            local GMset = self.GearManager and self.GearManager.sets
                          and self.GearManager.sets[gearSetName]
            local src = GMset and (GMset.equip or GMset.items or GMset.slots)
            if src then
                local function SlotItemId(invSlot)
                    local v = src[invSlot]
                    if type(v) == "string" then
                        return tonumber(v:match("item:(%d+)"))
                    elseif type(v) == "number" then
                        return v
                    elseif type(v) == "table" and v.itemId then
                        return v.itemId
                    end
                end
                setTrinket1 = SlotItemId(13)
                setTrinket2 = SlotItemId(14)
            end
        end
        local lockT1 = trinket1 or setTrinket1
        local lockT2 = trinket2 or setTrinket2
        local wasAlreadyLockedForBoss =
            encounterName and RC.bossTrinketState
            and RC.bossTrinketState.appliedBoss == encounterName
        if (lockT1 or lockT2) and RC.bossTrinketState and not wasAlreadyLockedForBoss then
            if RC.bossTrinketState.appliedBoss then
                RC:ReleaseBossTrinketLock("new boss target")
            end
            RC.bossTrinketState.locked = {}
            -- A previous boss's death swap engages the lock without setting
            -- appliedBoss, so the ReleaseBossTrinketLock above does not run
            -- and .deathSwap survives into this fresh engage. Left behind it
            -- makes an engage lock look like a death lock, which is what the
            -- route-swap guards read to decide whether they may take a slot.
            RC.bossTrinketState.deathSwap = nil
            if lockT1 then RC.bossTrinketState.locked[1] = lockT1 end
            if lockT2 then RC.bossTrinketState.locked[2] = lockT2 end
            RC.bossTrinketState.appliedBoss   = encounterName
            RC.bossTrinketState.appliedRaid   = raidName
            RC.bossTrinketState.lockEngagedAt = GetTime()
        end

        -- A GearManager-native set equips synchronously, so the per-slot
        -- overrides can follow in the same frame. Any other backend (ItemRack)
        -- needs 1.5s to settle first or the overrides get overwritten.
        local sameFrame = true
        if hasFullSet then
            local GMs = self.GearManager
            local gmNative = GMs and GMs.sets and GMs.sets[gearSetName]
                             and GMs.sets[gearSetName].equip
            if not gmNative then sameFrame = false end
            local excl = nil
            if gmNative then
                if nonTrinketSlots then
                    excl = {}
                    for s in pairs(nonTrinketSlots) do excl[s] = true end
                end
                if trinket1 then excl = excl or {}; excl[13] = true end
                if trinket2 then excl = excl or {}; excl[14] = true end
            end
            if RC:IsDebugEnabled("gear") then
                RC:DebugPrint("Boss engage: equipping set '" .. gearSetName .. "' for " .. tostring(encounterName), "gear")
            end
            RC:EquipGearSetFast(gearSetName, excl)
        end

        local function ApplyOverrides()
            local inCombat = InCombatLockdown()
            if encounterName and UnitExists("target") then
                local curName = Readycheck.SafeName("target")
                if curName then
                    local curRaid = RC.GetEffectiveRaidName and RC:GetEffectiveRaidName() or nil
                    local curEnc  = curRaid and RC.GetEncounterNameForBoss and RC:GetEncounterNameForBoss(curRaid, curName)
                    if curEnc and curEnc ~= encounterName then
                        if RC:IsDebugEnabled("gear") then
                            RC:DebugPrint("Boss override apply skipped: target changed (" .. curEnc .. " ~= " .. encounterName .. ")", "gear")
                        end
                        return
                    end
                end
            end

            -- Lock is already engaged up front in ApplyBossForceEquip;
            -- here we only perform the override equips themselves.
            if hasTrinkets and not wasAlreadyLockedForBoss and not inCombat then
                local slotTable = { slot1 = trinket1, slot2 = trinket2 }
                RC:EquipTrinketSet(slotTable, "boss target: " .. tostring(encounterName))
            end

            if hasOtherSlots then
                RC:ApplyBossForceEquipSlots(nonTrinketSlots, "boss target: " .. tostring(encounterName), nonTrinketEnchants)
            end

            if encounterName and UnitAffectingCombat("player") then
                RC.gearSwapState = RC.gearSwapState or {}
                RC.gearSwapState.engagedInCombat = encounterName
            end
        end

        local myGen = RC.gearSwapState._swapGen or 0

        local function BuildWantMap()
            local m = {}
            if trinket1 and trinket1 ~= 0 then m[13] = trinket1 end
            if trinket2 and trinket2 ~= 0 then m[14] = trinket2 end
            if nonTrinketSlots then
                for s, id in pairs(nonTrinketSlots) do m[s] = id end
            end
            return m
        end

        -- Verify passes per the retry setting. Combat defers by 2s without
        -- burning an attempt; a newer engage (_swapGen moved) or an active
        -- post-combat swap aborts outright rather than fighting over slots.
        local function VerifyAndRetryOverrides(attempt)
            attempt = attempt or 1
            local MAX, GAP = RC:GearSwapRetryCfg()
            if InCombatLockdown() then
                if RC:IsDebugEnabled("gear") then
                    RC:DebugPrint("Engage override verify deferred - in combat (attempt " .. attempt .. ")", "gear")
                end
                C_Timer.After(2.0, function() VerifyAndRetryOverrides(attempt) end)
                return
            end
            if RC.gearSwapState and RC.gearSwapState._postSwapActiveUntil
               and GetTime() < RC.gearSwapState._postSwapActiveUntil then
                if RC:IsDebugEnabled("gear") then
                    RC:DebugPrint("Engage override retry yielding - post-combat swap active", "gear")
                end
                return
            end
            if (RC.gearSwapState and RC.gearSwapState._swapGen or 0) ~= myGen then return end
            if encounterName and UnitExists("target") then
                local curName = Readycheck.SafeName("target")
                local curRaid = RC.GetEffectiveRaidName and RC:GetEffectiveRaidName() or nil
                local curEnc  = curRaid and curName and RC.GetEncounterNameForBoss and RC:GetEncounterNameForBoss(curRaid, curName)
                if curEnc and curEnc ~= encounterName then return end
            end
            local want   = BuildWantMap()
            local misses = {}
            for s, id in pairs(want) do
                local have, haveEnch = RC:GetEquippedIdEnchant(s)
                local wantEnch = nonTrinketEnchants and nonTrinketEnchants[s]
                if wantEnch == 0 then wantEnch = nil end
                if have ~= id or (wantEnch and haveEnch ~= wantEnch) then
                    misses[#misses + 1] = s
                end
            end
            if #misses == 0 then
                if RC:IsDebugEnabled("gear") then
                    RC:DebugPrint(string.format(RCL["Engage overrides verified (attempt %d) for %s"], attempt, tostring(encounterName)), "gear")
                end
                return
            end
            if attempt >= MAX then
                if RC:IsDebugEnabled("gear") then
                    RC:DebugPrint(string.format(RCL["Engage overrides incomplete after %d attempts for %s (slots %s)"], MAX, tostring(encounterName), table.concat(misses, ",")), "gear")
                end
                RC:GearSwapWarn(RCL["engage overrides for "] .. tostring(encounterName), MAX, misses)
                return
            end
            local retryTrinkets = {}
            local retrySlots
            for _, s in ipairs(misses) do
                if s == 13 then retryTrinkets.slot1 = trinket1
                elseif s == 14 then retryTrinkets.slot2 = trinket2
                else retrySlots = retrySlots or {}; retrySlots[s] = want[s] end
            end
            if retryTrinkets.slot1 or retryTrinkets.slot2 then
                RC:EquipTrinketSet(retryTrinkets, "engage override retry: " .. tostring(encounterName))
            end
            if retrySlots then
                RC:ApplyBossForceEquipSlots(retrySlots, "engage override retry: " .. tostring(encounterName), nonTrinketEnchants)
            end
            C_Timer.After(GAP, function() VerifyAndRetryOverrides(attempt + 1) end)
        end

        local function ApplyOverridesAndVerify()
            ApplyOverrides()
            C_Timer.After(0.5, function() VerifyAndRetryOverrides(1) end)
        end

        if sameFrame then
            ApplyOverridesAndVerify()
        else
            C_Timer.After(1.5, ApplyOverridesAndVerify)
        end
    end

    -- Two copies of the same item can differ only by enchant, so match on the
    -- item:<id>:<enchant> pair rather than the item ID alone.
    local function FindBagCopyWithEnchant(itemId, enchantId)
        local hitB, hitS
        RC.Bags:Each(function(bag, s, id)
            if id ~= itemId then return end
            local link = C_Container.GetContainerItemLink(bag, s)
            local ench = link and link:match("item:%d+:?(%d*)")
            if (tonumber(ench) or 0) == enchantId then hitB, hitS = bag, s; return true end
        end)
        return hitB, hitS
    end

    function RC:ApplyBossForceEquipSlots(slotsMap, reason, enchantMap)
        if not slotsMap then return end
        if InCombatLockdown() then
            -- Combat lockdown: store the request for the next regen (covers
            -- add-combat and self-buff combat). Newest boss target wins.
            RC._pendingOnTargetSlots    = slotsMap
            RC._pendingOnTargetReason   = reason
            RC._pendingOnTargetEnchants = enchantMap
            self:DebugPrint(
                "ApplyBossForceEquipSlots queued for out-of-combat retry: " .. (reason or "?"), "gear")
            return
        end

        RC._pendingOnTargetSlots    = nil
        RC._pendingOnTargetReason   = nil
        RC._pendingOnTargetEnchants = nil

        -- Swapping main hand and off hand with each other cannot be done slot by
        -- slot without dropping a weapon, so route it through GearManager's
        -- sequenced resolver and mark those slots as already handled.
        local handledWeapon = {}
        do
            local GMw = self.GearManager
            local want16, want17 = slotsMap[16], slotsMap[17]
            if GMw and GMw.ResolveWeaponCrossMove and (want16 or want17) then
                local cur16 = GetInventoryItemID("player", 16)
                local cur17 = GetInventoryItemID("player", 17)
                local id16 = (want16 and want16 ~= -1 and want16 ~= 0) and want16 or nil
                local id17 = (want17 and want17 ~= -1 and want17 ~= 0) and want17 or nil
                if id16 and id16 == cur16 then want16, id16 = nil, nil end
                if id17 and id17 == cur17 then want17, id17 = nil, nil end
                local cross16 = id16 ~= nil and id16 == cur17
                local cross17 = id17 ~= nil and id17 == cur16
                if cross16 or cross17 then
                    local function AsTarget(want)
                        if want == nil then return nil end
                        if want == -1 or want == 0 then return 0 end
                        return "item:" .. want
                    end
                    local t16, t17 = AsTarget(want16), AsTarget(want17)
                    local function FitsHand(itemId, hand)
                        if not itemId then return false end
                        local _, _, _, _, _, _, _, _, es = GetItemInfo(itemId)
                        return ((es and GMw.CanItemGoInSlot) and GMw:CanItemGoInSlot(es, hand)) and true or false
                    end
                    if cross16 and t17 == nil then
                        t17 = FitsHand(cur16, 17) and ("item:" .. cur16) or 0
                    end
                    if cross17 and t16 == nil then
                        t16 = FitsHand(cur17, 16) and ("item:" .. cur17) or 0
                    end
                    local h16, h17 = GMw:ResolveWeaponCrossMove(t16, t17, nil)
                    if h16 then handledWeapon[16] = true end
                    if h17 then handledWeapon[17] = true end
                    if (h16 or h17) and self:IsDebugEnabled("gear") then
                        self:DebugPrint("Weapon cross-move routed through sequenced resolver ("
                            .. (reason or "?") .. ")", "gear")
                    end
                end
            end
        end

        local equipped = 0
        for invSlot, itemId in pairs(slotsMap) do
            if handledWeapon[invSlot] then
            -- -1 = unequip this slot, into a bag that takes gear; with every
            -- bag full the item stays on and the player is told
            elseif itemId == -1 then
                if GetInventoryItemID("player", invSlot) then
                    local ok, why = RC.Equip:Unequip(invSlot, nil, nil, { by = "force" })
                    if ok then
                        equipped = equipped + 1
                        self:DebugPrint("Unequipped slot " .. invSlot
                            .. " (" .. (reason or "?") .. ")", "gear")
                    elseif why == "bags full" then
                        RC:Print(RCL["Could not unequip slot "] .. invSlot .. RCL[" - bags are full"])
                    end
                end
            elseif itemId and itemId ~= 0 then
                local wantEnch = enchantMap and enchantMap[invSlot]
                if wantEnch == 0 then wantEnch = nil end
                local curId, curEnch = self:GetEquippedIdEnchant(invSlot)
                local alreadyCorrect = (curId == itemId) and (not wantEnch or curEnch == wantEnch)
                if not alreadyCorrect then
                    if wantEnch then
                        local GMr = self.GearManager
                        local bag, bagSlot = FindBagCopyWithEnchant(itemId, wantEnch)
                        if bag and GMr and GMr.EquipBagItemToSlot then
                            if GMr:EquipBagItemToSlot(bag, bagSlot, invSlot) then
                                equipped = equipped + 1
                            end
                        elseif self:FastEquipItem(itemId, invSlot) then
                            equipped = equipped + 1
                        end
                    -- Weapon slots: equip straight from the bag slot so the game
                    -- cannot pick the wrong hand for a one-hander.
                    elseif invSlot == 16 or invSlot == 17 then
                        local GMr2 = self.GearManager
                        local fb, fsl = RC.Bags:Find(itemId)
                        if fb and GMr2 and GMr2.EquipBagItemToSlot
                           and GMr2:EquipBagItemToSlot(fb, fsl, invSlot) then
                            equipped = equipped + 1
                        elseif self:FastEquipItem(itemId, invSlot) then
                            equipped = equipped + 1
                        end
                    else
                        if self:FastEquipItem(itemId, invSlot) then
                            equipped = equipped + 1
                        end
                    end
                end
            end
        end

        if equipped > 0 and self:IsDebugEnabled("gear") then
            self:DebugPrint("ApplyBossForceEquipSlots (" .. (reason or "?") .. "): equipped " .. equipped .. " slot(s)", "gear")
        end
    end

    -- A /reload mid-fight loses gearSwapState and the trinket lock, which would
    -- strand the death and post-combat swaps. Rebuild both from the current
    -- target and boss config. Equips nothing - it only restores bookkeeping.
    function RC:ReengageBossStateAfterReload()
        if not UnitExists("target") or UnitIsDead("target") then return end
        if not UnitCanAttack("player", "target") then return end

        local raidName = self.GetEffectiveRaidName and self:GetEffectiveRaidName() or nil
        if not raidName then return end

        local targetName = Readycheck.SafeName("target")
        if not targetName then return end

        local encounterName = self.GetEncounterNameForBoss
                              and self:GetEncounterNameForBoss(raidName, targetName)
                              or targetName
        if not encounterName then return end

        local raidProfile = self.GetActiveRaidProfile and self:GetActiveRaidProfile(raidName)
        local bossCfg = raidProfile and raidProfile.bosses and raidProfile.bosses[encounterName]
        if not bossCfg then return end

        local fe       = bossCfg.forceEquip
        local gsCfg    = bossCfg.abilities and bossCfg.abilities.gearswap
        local gearSet  = gsCfg and (gsCfg.gearSet or gsCfg.itemRackSet)
        local postSet  = gsCfg and gsCfg.postCombatSet

        local trinket1 = fe and (fe.slot1 or (fe.onTarget and fe.onTarget[13]))
        local trinket2 = fe and (fe.slot2 or (fe.onTarget and fe.onTarget[14]))

        local hasFE  = fe and (trinket1 or trinket2 or (fe.onTarget and next(fe.onTarget) ~= nil))
        local hasSet = gearSet and gearSet ~= ""

        if not hasFE and not hasSet then return end

        RC.gearSwapState = RC.gearSwapState or {}

        if (trinket1 or trinket2) and RC.bossTrinketState then
            RC.bossTrinketState.locked = RC.bossTrinketState.locked or {}
            if trinket1 then RC.bossTrinketState.locked[1] = trinket1 end
            if trinket2 then RC.bossTrinketState.locked[2] = trinket2 end
            RC.bossTrinketState.appliedBoss = encounterName
            RC.bossTrinketState.appliedRaid = raidName
            RC.bossTrinketState.lockEngagedAt = GetTime()
        end

        if hasSet then
            RC.gearSwapState.lastEquippedSet = gearSet
            RC.gearSwapState.lastBossTarget  = targetName
            RC.gearSwapState.engagedBossGUID = Readycheck.SafeGUID("target")
        end
        if postSet and postSet ~= "" then
            RC.gearSwapState.postCombatSet = postSet
        end

        if UnitAffectingCombat("player") then
            RC.gearSwapState.engagedInCombat = encounterName
        end

        RC.gearSwapState.engageHandledBoss = encounterName
        RC.gearSwapState.engageHandledTime = GetTime()

        if self:IsDebugEnabled("trinket") then
            self:DebugPrint(string.format(
                RCL["Reload recovery: re-engaged state for %s (lock=%s/%s set=%s post=%s combat=%s)"],
                encounterName,
                tostring(trinket1), tostring(trinket2),
                tostring(gearSet), tostring(postSet),
                tostring(UnitAffectingCombat("player"))), "trinket")
        end
    end
