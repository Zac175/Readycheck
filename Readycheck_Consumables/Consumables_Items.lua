------------------------------------------------------------------------
-- Readycheck - Consumables Item Queries
-- Item-level lookups the bars run against: bag/inventory cooldowns, buff
-- and conflict-group state, weapon-enchant readers, stone selection and
-- the secure macro text on weapon buttons.
-- Classic Era only: there is no retail GetItemCooldown. Bag items go
-- through C_Container.GetContainerItemCooldown (bag,slot), equipped slots
-- through GetInventoryItemCooldown - so any cooldown by itemId needs the
-- bag-scan map below, not a direct call.
-- Every read here is cached; the hot path calls these, never the raw APIs.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local UnitAura = UnitAura or (RCC and RCC.Compat and RCC.Compat.UnitAura)
local GetSpellCooldown = GetSpellCooldown or (RCC and RCC.Compat and RCC.Compat.GetSpellCooldown)
local WRF = _G.Readycheck
if not WRF then return end
WRF._chInit = WRF._chInit or {}
WRF._chs = WRF._chs or {}
WRF._chInit[#WRF._chInit + 1] = function()
    local RC = _G.Readycheck
    local GetTime = GetTime
    local GetItemCount = GetItemCount or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemCount)
    local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
    local UnitBuff = UnitBuff or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.UnitBuff)
    local GetWeaponEnchantInfo = GetWeaponEnchantInfo
    local IsInInstance = IsInInstance
    local IsInRaid = IsInRaid
    local IsResting = IsResting
    local InCombatLockdown = InCombatLockdown
    local UnitGetTotalAbsorbs = UnitGetTotalAbsorbs
    local UnitGUID = UnitGUID
    local UnitCastingInfo = UnitCastingInfo
    local UnitChannelInfo = UnitChannelInfo
    local GetSpellCooldown = GetSpellCooldown or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetSpellCooldown)
    local math_floor = math.floor
    local math_ceil = math.ceil
    local math_max = math.max
    local math_min = math.min
    local math_abs = math.abs
    local string_format = string.format
    local string_lower = string.lower
    local pairs = pairs
    local ipairs = ipairs
    local type = type

    local _chs = WRF._chs

    -- Predictive: the client reports no shared potion cooldown until
    -- BAG_UPDATE_COOLDOWN lands, so assume it on cast success.
    function RC:TriggerConsumableCooldown(duration, cooldownType)
        cooldownType = cooldownType or "potion"
        duration = duration or 3

        local now = GetTime()
        if cooldownType == "elixir" then
            self.elixirCooldown.active = true
            self.elixirCooldown.endTime = now + duration
            self.elixirCooldown.duration = duration
        else
            self.consumableCooldown.active = true
            self.consumableCooldown.endTime = now + duration
            self.consumableCooldown.duration = duration
        end
    end

    function RC:OnPotionUsed(spellId)
        if not spellId or not self.raidConsumables then return end

        local isPotion = false
        local isElixir = false
        local usedItemId = nil

        if self.raidConsumables.potions and self.raidConsumables.potions.items then
            for itemId, itemData in pairs(self.raidConsumables.potions.items) do
                if itemData.buffId == spellId or itemData.useSpellId == spellId then
                    isPotion = true
                    usedItemId = itemId
                    break
                end
            end
        end

        if not isPotion and self.raidConsumables.protectionPotions and self.raidConsumables.protectionPotions.items then
            for itemId, itemData in pairs(self.raidConsumables.protectionPotions.items) do
                if itemData.buffId == spellId then
                    isPotion = true
                    usedItemId = itemId
                    break
                end
            end
        end

        if not isPotion and self.raidConsumables.elixirs and self.raidConsumables.elixirs.items then
            for itemId, itemData in pairs(self.raidConsumables.elixirs.items) do
                if itemData.buffId == spellId then
                    isElixir = true
                    usedItemId = itemId
                    break
                end
            end
        end

        if not isPotion and not isElixir and self.raidConsumables.flasks and self.raidConsumables.flasks.items then
            for itemId, itemData in pairs(self.raidConsumables.flasks.items) do
                if itemData.buffId == spellId then
                    isElixir = true
                    usedItemId = itemId
                    break
                end
            end
        end

        -- 120s = the Classic Era shared potion cooldown. Elixirs share none,
        -- so 3s only covers the round trip before the buff appears.
        if isPotion then
            self:TriggerConsumableCooldown(120, "potion")
        elseif isElixir then
            self:TriggerConsumableCooldown(3, "elixir")
        end

        local hideUsed = self.db and self.db.consumablesHelper
            and self.db.consumablesHelper.hideUsedInCombat
        if hideUsed == nil then hideUsed = true end
        if hideUsed and usedItemId and InCombatLockdown() then
            self:HideSpentConsumableInCombat(usedItemId)
        end
    end

    -- Visual-only hide. Buttons are secure/protected; :Hide() on them is
    -- forbidden in combat, so the bar zeroes alpha instead.
    -- Every child listed here is a separate frame or a font string on the
    -- textOverlay child frame, and neither inherits the button's alpha:
    --   cooldownFrame/gcdFrame/castFrame - Cooldown frames, own alpha
    --   count/durationText              - parented to textOverlay
    -- Miss one and it keeps drawing over an otherwise invisible button.
    local function SetBarButtonVisualHidden(button, hidden)
        if not button then return end
        local a = hidden and 0 or 1
        button:SetAlpha(a)
        if button.cooldownFrame then button.cooldownFrame:SetAlpha(a) end
        if button.gcdFrame then button.gcdFrame:SetAlpha(a) end
        if button.castFrame then button.castFrame:SetAlpha(a) end
        if button.count then button.count:SetAlpha(a) end
        if button.durationText then button.durationText:SetAlpha(a) end
    end
    _chs.SetBarButtonVisualHidden = SetBarButtonVisualHidden

    -- _spentInCombat is cleared by PLAYER_REGEN_ENABLED, the only place a
    -- secure button can legally be re-shown. The button is found by its
    -- own id or by the base item it stands for (rank/variant buttons).
    function RC:HideSpentConsumableInCombat(itemId)
        if not itemId then return end
        if not InCombatLockdown() then return end
        local hideUsed = self.db and self.db.consumablesHelper
            and self.db.consumablesHelper.hideUsedInCombat
        if hideUsed == nil then hideUsed = true end
        if not hideUsed then return end
        local bar = self.consumablesHelper
        if not (bar and bar.buttons) then return end
        local function Hide(button)
            if button and button.icon and not button.isWeaponsBar and not button._spentInCombat then
                button._spentInCombat = true
                button.icon:SetAlpha(0)
                SetBarButtonVisualHidden(button, true)
                self:DebugPrint("Spent in combat, hidden: item " .. tostring(button.itemId), "consumables")
            end
        end
        Hide(bar.buttons[itemId])
        -- the base item the used one stands for, if it is a variant
        local base
        for _, category in pairs(self.raidConsumables or {}) do
            local d = type(category) == "table" and category.items and category.items[itemId]
            if d and d.baseItemId then base = d.baseItemId break end
        end
        if base then Hide(bar.buttons[base]) end
        for _, button in pairs(bar.buttons) do
            local d = button.itemData
            if d and d.baseItemId and (d.baseItemId == itemId or d.baseItemId == base) then Hide(button) end
        end
    end

    -- buffId -> list of item ids that give it, from the shipped tables and
    -- the custom items. Built on first use and again when the number of
    -- custom items changes.
    function RC:ItemsForBuff(spellId)
        if not spellId then return nil end
        local custom = self.db and self.db.consumablesHelper and self.db.consumablesHelper.customItems
        local nCustom = 0
        for _ in pairs(custom or {}) do nCustom = nCustom + 1 end
        local map = self._itemsByBuffId
        if not map or self._itemsByBuffIdCustom ~= nCustom then
            self._itemsByBuffIdCustom = nCustom
            map = {}
            local function Add(itemId, itemData)
                local b = itemData and itemData.buffId
                if b then
                    map[b] = map[b] or {}
                    map[b][#map[b] + 1] = itemId
                end
            end
            for _, category in pairs(self.raidConsumables or {}) do
                if type(category) == "table" and category.items then
                    for itemId, itemData in pairs(category.items) do Add(itemId, itemData) end
                end
            end
            for itemId, itemData in pairs(custom or {}) do Add(itemId, itemData) end
            self._itemsByBuffId = map
        end
        return map[spellId]
    end

    -- A consumable buff that appeared during combat: whatever item gives
    -- it has done its job, so its button goes. Reached from the UNIT_AURA
    -- drain only, with the buffs that were not there at the last drain.
    function RC:HideItemsOfBuffsGainedInCombat(addedSpellIds)
        if not InCombatLockdown() or not addedSpellIds then return end
        for _, spellId in ipairs(addedSpellIds) do
            local items = self:ItemsForBuff(spellId)
            if items then
                for _, itemId in ipairs(items) do self:HideSpentConsumableInCombat(itemId) end
            end
        end
    end

    -- 61304 is Blizzard's dummy "Global Cooldown" spell; querying its
    -- cooldown is the standard way to read the GCD without owning a spell.
    local gcdSpellId = 61304
    function RC:GetGCDInfo()
        local start, duration = Readycheck.PlainCD(GetSpellCooldown(Readycheck.GCDSpell and Readycheck.GCDSpell() or gcdSpellId))

        if start and duration and start > 0 and duration > 0 then
            local remaining = start + duration - GetTime()
            if remaining > 0 then
                return remaining, duration
            end
        end

        return 0, 0
    end

    -- Classic Era has no GetItemCooldown(itemId): a bag item's cooldown is
    -- read from its slot, which the shared bag index finds without a walk.
    -- itemId > 900000 is a synthetic bar id with no real item behind it.
    function RC:GetItemCooldownByID(itemId)
        if not itemId or itemId > 900000 then return 0, 0 end
        return RC.Bags:Cooldown(itemId)
    end

    -- 24800 Food, 18124 Drink: the two generic "eating/drinking" auras every
    -- Classic Era consumable of those types applies.
    local foodSpellIds = {[24800] = true, [18124] = true}
    -- Eating breaks on damage, so in combat the answer is always no.
    function RC:IsEating()
        if InCombatLockdown() then return false, 0 end
        local allBuffs = self:SnapshotAllBuffs()
        if not allBuffs then return false, 0 end
        local now = GetTime()
        for spellId in pairs(foodSpellIds) do
            local buffData = allBuffs[spellId]
            if buffData and buffData.expirationTime and buffData.expirationTime > 0 then
                local timeRemaining = buffData.expirationTime - now
                if timeRemaining > 0 then
                    return true, timeRemaining
                end
            end
        end
        return false, 0
    end

    -- Inverts the data files' group -> set-of-itemIds declaration into
    -- itemId -> group, once. Membership is symmetric: every item in a group
    -- excludes every other item in it, in both directions.
    function RC:GetConflictGroup(itemId)
        if not self.conflictGroupReverseLookup then
            self.conflictGroupReverseLookup = {}
            if self.consumableConflictGroups then
                for groupName, items in pairs(self.consumableConflictGroups) do
                    for itemIdInGroup, _ in pairs(items) do
                        self.conflictGroupReverseLookup[itemIdInGroup] = groupName
                    end
                end
            end
        end

        return self.conflictGroupReverseLookup[itemId]
    end

    -- A group's shared timer (a rival's buff, or the explosives' shared
    -- cooldown) is shown on, and gates, its members. Stratholme Holy Water
    -- sits with the explosives for grouping and quick-use, but its cooldown
    -- is its own (HasConflictGroupBuff already skips it when reading the
    -- shared one), so the explosives' timer must never land on it.
    local OWN_TIMER = { [13180] = true }
    function RC:TimerConflictGroup(itemId)
        if OWN_TIMER[itemId] then return nil end
        return self:GetConflictGroup(itemId)
    end

    -- "Potion ready" TTS watcher, installed once at module init. All data
    -- reads inside are lazy (PotFam builds its cache on first tick), so
    -- nothing here needs the potion data files to be loaded yet.
    if not RC._potionReadyHooked then
        RC._potionReadyHooked = true
        local armed = false
        local idleTicks = 0
        local potionTicker
        local famCache
        local function PotFam()
            if famCache then return famCache end
            famCache = {}
            local pd = RC.potionData and RC.potionData.potions
            if pd then
                for _, entry in pairs(pd) do
                    if type(entry) == "table" and entry.itemId
                       and not entry.noPotionCd then
                        famCache[entry.itemId] = true
                    end
                end
            end
            local rc = RC.raidConsumables
            for _, key in ipairs({ "potions", "protectionPotions" }) do
                local c = rc and rc[key]
                if c and c.items then
                    for iid, d in pairs(c.items) do
                        if type(iid) == "number"
                           and not (type(d) == "table" and (d.baseItemId or d.slot)) then
                            famCache[iid] = true
                        end
                    end
                end
            end
            return famCache
        end
        -- nil when no potion is carried. Stops at the first one found:
        -- they all share one cooldown, so one sample suffices.
        local function PotionCDRemaining()
            local ids = PotFam()
            if not next(ids) or not C_Container then return nil end
            -- the first potion carried, in bag order (shared bag index);
            -- du > 1.5 tells a real cooldown from the GCD shown on bag items
            local bestBag, bestSlot
            for iid in pairs(ids) do
                local b, sl = RC.Bags:Find(iid)
                if b and (not bestBag or b < bestBag or (b == bestBag and sl < bestSlot)) then
                    bestBag, bestSlot = b, sl
                end
            end
            if not bestBag then return nil end
            local st, du = C_Container.GetContainerItemCooldown(bestBag, bestSlot)
            if st and st > 0 and du and du > 1.5 then
                return st + du - GetTime()
            end
            return 0
        end
        -- Arms only above 60s remaining, so logging in mid-cooldown
        -- does not announce instantly. Cancels itself after five idle
        -- ticks, so nothing runs while no potion is on cooldown.
        local function Tick()
            local cdb = RC.db and RC.db.consumablesHelper
            if not (cdb and cdb.enabled and cdb.potionReadyTTS == true) then
                -- the bar or the voice was switched off mid-cooldown
                armed = false
                if potionTicker then potionTicker:Cancel(); potionTicker = nil end
                return
            end
            local left = PotionCDRemaining()
            if not armed then
                if left and left > 60 then
                    armed = true
                    idleTicks = 0
                else
                    idleTicks = idleTicks + 1
                    if idleTicks > 5 and potionTicker then
                        potionTicker:Cancel()
                        potionTicker = nil
                    end
                end
            elseif not left or left <= 0 then
                armed = false
                if RC.SpeakTTS then RC:SpeakTTS(RCL["Potion ready"], true) end
                if potionTicker then
                    potionTicker:Cancel()
                    potionTicker = nil
                end
            end
        end
        -- HOT EVENT. BAG_UPDATE_COOLDOWN fires many times per second in
        -- combat. This handler does no bag scan and touches no button:
        -- it only starts the 1.0s ticker, behind the `not potionTicker`
        -- early-return guard that makes repeat events free.
        RC:OnBarsEvent("BAG_UPDATE_COOLDOWN", function()
            local db = RC.db and RC.db.consumablesHelper
            -- a consumables bar option: nothing while that bar is off
            if not (db and db.enabled and db.potionReadyTTS == true) then return end
            if not potionTicker then
                idleTicks = 0
                if RC.Profiler and RC.Profiler.TrackTicker then
                    potionTicker = RC.Profiler:TrackTicker(
                        "potionReady", 1.0, Tick)
                else
                    potionTicker = C_Timer.NewTicker(1.0, Tick)
                end
            end
        end)
    end

    -- Returns the active member so callers can tell "mine" from "a rival's".
    -- Cached 0.5s per group; the UNIT_AURA drain wipes the cache when a
    -- consumable buff actually changes.
    function RC:HasConflictGroupBuff(groupName)
        local conflictGroups = self.consumableConflictGroups
        if not conflictGroups or not conflictGroups[groupName] then
            return false, 0, nil
        end

        local cache = self.performanceCache.conflictGroups
        local now = GetTime()
        local cached = cache[groupName]

        if cached and (now - cached.cacheTime) < self.performanceCache.conflictGroupCacheTTL then
            return cached.hasBuff, cached.timeRemaining, cached.itemId
        end

        local result = { hasBuff = false, timeRemaining = 0, itemId = nil, cacheTime = now }

        -- Explosives grant no buff, so "in conflict" means "on cooldown"
        -- and must be read from the bags. 13180 (Stratholme Holy Water) is
        -- excluded: its cooldown is independent of the shared one.
        if groupName == "engineeringExplosives" then
            -- every stack of one item shares its cooldown: the first one
            -- found (the shared bag index) answers for all of them
            for itemId in pairs(conflictGroups[groupName]) do
                if itemId ~= 13180 then
                    local start, duration = RC.Bags:Cooldown(itemId)
                    if start > 0 and duration > 0 then
                        local timeRemaining = (start + duration) - now
                        if timeRemaining > 0 then
                            result.hasBuff = true
                            result.timeRemaining = timeRemaining
                            result.itemId = itemId
                            cache[groupName] = result
                            return true, timeRemaining, itemId
                        end
                    end
                end
            end
            cache[groupName] = result
            return false, 0, nil
        end

        for itemId in pairs(self:ConflictMembers(groupName)) do
            local hasBuff, timeRemaining = self:HasConsumableBuff(itemId)
            if hasBuff then
                result.hasBuff = true
                result.timeRemaining = timeRemaining
                result.itemId = itemId
                cache[groupName] = result
                return true, timeRemaining, itemId
            end
        end

        cache[groupName] = result
        return false, 0, nil
    end

    function RC:HasConsumableBuff(itemId)
        local buffId = self:GetConsumableBuffId(itemId)
        if not buffId then
            return false, 0
        end

        local allBuffs = self:SnapshotAllBuffs()
        local buffData = self:ResolveConsumableBuff(allBuffs, buffId)

        if buffData then
            local timeRemaining = buffData.expirationTime and buffData.expirationTime > 0
                and (buffData.expirationTime - GetTime()) or 0
            return true, timeRemaining
        end

        return false, 0
    end

    -- GetWeaponEnchantInfo returns an enchantId, not an itemId: map back to
    -- the consumable that applies it, so borders can colour by stone type.
    -- 2506 Elemental, 2684 Consecrated, 1643 Dense, 26 Frost Oil (8 is
    -- Deadly Poison II, which this used to call Frost Oil).
    RC.enchantIdToStone = {
        [2506] = 18262,
        [2684] = 23122,
        [1643] = 12404,
        [26] = 3829,
    }
    for enchantId, stoneId in pairs(RC.flavorStoneOfEnchant or {}) do
        RC.enchantIdToStone[enchantId] = stoneId
    end

    function RC:GetStoneFromEnchantId(enchantId)
        return self.enchantIdToStone[enchantId]
    end

    -- POISON CHARGES. A Classic poison runs out by charges as well as by
    -- time (Instant Poison VI: 30 minutes or 115 charges, whichever goes
    -- first), and the charges usually go first. With POISON_LOW_CHARGES or
    -- fewer left the enchant reads as about to run out - a few seconds left
    -- - everywhere that asks how long it has: the bars show the button
    -- again, the voice warns, the reminders count it. The buttons and the
    -- tooltip show the charges themselves (RC:GetWeaponCharges). Stones and
    -- oils have no charges and are untouched.
    -- TBC poisons last an hour with no charges: no low-charges warning.
    local POISON_LOW_CHARGES = 10
    RC.POISON_LOW_CHARGES = POISON_LOW_CHARGES
    local CHARGES_COUNT = not RC.poisonsNoCharges
    local function SlotEntry(has, expiration, charges, enchantId, now)
        local secs = has and ((expiration or 0) / 1000) or 0
        local ch = has and tonumber(charges) or 0
        local low = CHARGES_COUNT and has and ch > 0 and ch <= POISON_LOW_CHARGES or false
        return {
            hasEnchant = has or false,
            timeRemaining = low and math.min(secs, 5) or secs,
            realTime = secs,
            charges = ch,
            lowCharges = low,
            enchantId = enchantId,
            cacheTime = now
        }
    end

    -- Loose reader: reports ANY temporary enchant on the slot. `slot` must
    -- be the canonical "mainhand"/"offhand" - anything else misses both the
    -- cache check and the return branches and silently yields false.
    -- One API call fills both slots; itemId is unused. The 4th return is
    -- the poison charges left (0 for a stone or oil).
    function RC:HasWeaponEnchant(itemId, slot)
        local cache = self.performanceCache.weaponEnchants
        local now = GetTime()

        if slot == "mainhand" or slot == "offhand" then
            local slotCache = cache[slot]
            if slotCache and (now - slotCache.cacheTime) < self.performanceCache.weaponEnchantCacheTTL then
                return slotCache.hasEnchant, slotCache.timeRemaining, slotCache.enchantId, slotCache.charges
            end
        end

        local hasMainHandEnchant, mainHandExpiration, mainHandCharges, mainHandEnchantID,
              hasOffHandEnchant, offHandExpiration, offHandCharges, offHandEnchantID = GetWeaponEnchantInfo()

        -- Expiration arrives in milliseconds; the addon works in seconds.
        cache.mainhand = SlotEntry(hasMainHandEnchant, mainHandExpiration, mainHandCharges, mainHandEnchantID, now)
        cache.offhand = SlotEntry(hasOffHandEnchant, offHandExpiration, offHandCharges, offHandEnchantID, now)

        if slot == "mainhand" and hasMainHandEnchant then
            return true, cache.mainhand.timeRemaining, mainHandEnchantID, cache.mainhand.charges
        elseif slot == "offhand" and hasOffHandEnchant then
            return true, cache.offhand.timeRemaining, offHandEnchantID, cache.offhand.charges
        end

        return false, 0, nil, 0
    end

    -- charges left (0: none, or a stone/oil), the real time left, and
    -- whether it is low on charges
    function RC:GetWeaponCharges(slot)
        if slot ~= "mainhand" and slot ~= "offhand" then return 0, 0, false end
        self:HasWeaponEnchant(nil, slot)
        local c = self.performanceCache.weaponEnchants[slot]
        if not (c and c.hasEnchant) then return 0, 0, false end
        return c.charges or 0, c.realTime or c.timeRemaining or 0, c.lowCharges and true or false
    end

    -- Strict variant for a SPECIFIC enchant consumable (the oils, which
    -- carry itemData.enchantId): only counts as active when the enchant
    -- currently on the slot is the one THIS item applies. Without this,
    -- every oil claimed any mainhand enchant as its own, so a sharpening
    -- stone nearing expiry got announced by TTS as "Wizard Oil".
    -- The loose HasWeaponEnchant stays for the slot-tracker buttons,
    -- which deliberately treat any enchant on the slot as active.
    function RC:HasOwnWeaponEnchant(itemId, slot, wantEnchantId)
        local hasEnchant, timeRemaining, appliedId = self:HasWeaponEnchant(itemId, slot)
        if hasEnchant and wantEnchantId and appliedId ~= wantEnchantId then
            return false, 0
        end
        return hasEnchant, timeRemaining
    end

    -- No Classic Era API exposes an unequipped weapon's temp enchant, so it
    -- is read off the tooltip - by far the most expensive read in this file,
    -- hence the 2s cache that a bag or weapon change nils wholesale.
    function RC:HasBagWeaponEnchant(bag, slot)
        if not self.bagWeaponEnchantCache then
            self.bagWeaponEnchantCache = {}
        end

        local cacheKey = bag .. "-" .. slot
        local cached = self.bagWeaponEnchantCache[cacheKey]
        local now = GetTime()

        if cached and (now - cached.time) < 2 then
            return cached.result, cached.timeRemaining
        end

        local scanLines = RC.Compat.TooltipLines("bagitem", bag, slot)
        for i = 1, #scanLines do
            local l = scanLines[i]
            if l.r == nil then l.r, l.g, l.b = 1, 1, 1 end
        end

        local hasEnchant = false
        local timeRemaining = 0

        for i = 1, #scanLines do
            local text = scanLines[i].text
            local textLower = text:lower()

            local r, g, b = scanLines[i].r, scanLines[i].g, scanLines[i].b
            local isGreenText = (g > 0.8 and r < 0.5 and b < 0.5)

            local mins = text:match("(%d+)%s*min")
            local secs = text:match("(%d+)%s*sec")

            -- A duration alone is not enough - proc, DoT and cooldown lines
            -- all have one. A real temp enchant line is short and green and
            -- either ends in a parenthesised duration or says "remaining".
            if mins or secs then
                local isEffectDescription =
                    textLower:find("over%s+%d+%s*sec") or
                    textLower:find("for%s+%d+%s*sec") or
                    textLower:find("damage") or
                    textLower:find("wounds") or
                    textLower:find("restore") or
                    textLower:find("heal") or
                    textLower:find("shadow") or
                    textLower:find("fire") or
                    textLower:find("frost") or
                    textLower:find("nature") or
                    textLower:find("arcane") or
                    textLower:find("holy") or
                    textLower:find("target") or
                    textLower:find("chance") or
                    textLower:find("proc") or
                    textLower:find("struck") or
                    textLower:find("when hit") or
                    textLower:find("attacker")

                local isCooldown = textLower:find("cooldown")

                local hasParenDuration = text:match("%(%d+%s*min%)%s*$") or text:match("%(%d+%s*sec%)%s*$")
                local hasRemaining = textLower:find("remaining")
                local isStandaloneShort = (#text < 20) and isGreenText

                local isValidTempEnchant = (hasParenDuration or hasRemaining or isStandaloneShort)
                                           and not isEffectDescription
                                           and not isCooldown

                if isValidTempEnchant then
                    hasEnchant = true
                    if mins then
                        timeRemaining = tonumber(mins) * 60
                    end
                    if secs then
                        timeRemaining = timeRemaining + tonumber(secs)
                    end
                    break
                end
            end
        end

        self.bagWeaponEnchantCache[cacheKey] = {
            time = now,
            result = hasEnchant,
            timeRemaining = timeRemaining
        }

        return hasEnchant, timeRemaining
    end

    -- Bag weapons that take a stone or oil, rebuilt only when the bags
    -- changed (the bag index's version). Called from rebuilds only.
    local WEAPON_SLOTS = {
        INVTYPE_WEAPON = true, INVTYPE_WEAPONMAINHAND = true,
        INVTYPE_WEAPONOFFHAND = true, INVTYPE_2HWEAPON = true,
    }
    function RC:ScanBagWeapons()
        local ch = self.consumablesHelper
        local v = RC.Bags:Version()
        if ch.cachedBagWeapons and ch._weaponsVersion == v then
            return ch.cachedBagWeapons
        end

        local weapons = {}
        -- Item class 2 in a weapon slot (shields are class 4), typed by
        -- GetItemInfoInstant, which never misses: full item info can be
        -- unloaded right after login, and a weapon skipped then stayed
        -- missing until the bags next changed. The link is read for those
        -- only.
        RC.Bags:Each(function(bag, slot, itemId)
            local _, _, itemSubType, equipLoc, icon, classID = GetItemInfoInstant(itemId)
            if classID ~= 2 or not WEAPON_SLOTS[equipLoc] or not itemSubType then return end
            local sub = itemSubType:lower()
            if not (sub:find("sword") or sub:find("axe") or sub:find("mace") or sub:find("dagger")
               or sub:find("polearm") or sub:find("fist")) then return end
            local itemLink = C_Container.GetContainerItemLink(bag, slot)
            if not itemLink then return end
            weapons[#weapons + 1] = {
                bag = bag,
                slot = slot,
                itemLink = itemLink,
                itemName = GetItemInfo(itemLink) or "Weapon",
                texture = icon or GetItemIcon(itemLink),
                itemId = itemId,
            }
        end)

        ch.cachedBagWeapons, ch._weaponsVersion = weapons, v
        return weapons
    end

    function RC:GetStoneName(itemId)
        local stoneNames = {
            [18262] = "Elemental Sharpening Stone",
            [23122] = "Consecrated Sharpening Stone",
            [12404] = "Dense Sharpening Stone",
            [3829] = "Frost Oil",
            [20749] = "Brilliant Wizard Oil",
            [20748] = "Brilliant Mana Oil",
            [23123] = "Blessed Wizard Oil",
        }
        if stoneNames[itemId] then return stoneNames[itemId] end
        -- poisons (and any other coating the enchant table knows)
        for _, info in pairs(self.temporaryWeaponEnchants or {}) do
            if type(info) == "table" and info.itemId == itemId and info.name then return info.name end
        end
        return "Sharpening Stone"
    end

    function RC:GetShortStoneName(itemId)
        local shortNames = {
            [18262] = "Elemental",
            [23122] = "Consecrated",
            [12404] = "Dense",
            [3829] = "Frost Oil",
            [20749] = "Wizard Oil",
            [20748] = "Mana Oil",
            [23123] = "Blessed Oil",
        }
        if shortNames[itemId] then return shortNames[itemId] end
        if self.flavorStoneShort and self.flavorStoneShort[itemId] then return self.flavorStoneShort[itemId] end
        for _, info in pairs(self.temporaryWeaponEnchants or {}) do
            if type(info) == "table" and info.itemId == itemId and info.isPoison and info.name then
                return (info.name:gsub(" Poison", ""))
            end
        end
        return "Stone"
    end

    -- Display order for the stone picker; also the fallback search order in
    -- GetValidStoneType, so the highest-value stone must stay first.
    local STONE_TYPES = {
        {id = 18262, name = "Elemental", color = {1, 0.82, 0}, spellId = 22756},
        {id = 23122, name = "Consecrated", color = {1, 0.9, 0.6}, spellId = 28891},
        {id = 12404, name = "Dense", color = {0.6, 0.6, 0.65}, spellId = 16138},
        {id = 3829, name = "Frost Oil", color = {0.4, 0.8, 1}, spellId = 3595},
        {id = 20749, name = "Wizard", color = {0.64, 0.4, 1}, spellId = 25122},
        {id = 20748, name = "Mana", color = {0.3, 0.6, 1}, spellId = 25123},
        {id = 23123, name = "Blessed", color = {1, 0.85, 0.4}, spellId = 28898},
        -- rogue poisons (2026-10-21), top rank first in each kind; only a
        -- rogue carries them, so nobody else ever sees these rows
        {id = 8928,  name = "Instant VI",       color = {0.45, 0.9, 0.45}, poison = "instant"},
        {id = 8927,  name = "Instant V",        color = {0.45, 0.9, 0.45}, poison = "instant"},
        {id = 8926,  name = "Instant IV",       color = {0.45, 0.9, 0.45}, poison = "instant"},
        {id = 6950,  name = "Instant III",      color = {0.45, 0.9, 0.45}, poison = "instant"},
        {id = 6949,  name = "Instant II",       color = {0.45, 0.9, 0.45}, poison = "instant"},
        {id = 6947,  name = "Instant",          color = {0.45, 0.9, 0.45}, poison = "instant"},
        {id = 20844, name = "Deadly V",         color = {0.6, 0.85, 0.25}, poison = "deadly"},
        {id = 8985,  name = "Deadly IV",        color = {0.6, 0.85, 0.25}, poison = "deadly"},
        {id = 8984,  name = "Deadly III",       color = {0.6, 0.85, 0.25}, poison = "deadly"},
        {id = 2893,  name = "Deadly II",        color = {0.6, 0.85, 0.25}, poison = "deadly"},
        {id = 2892,  name = "Deadly",           color = {0.6, 0.85, 0.25}, poison = "deadly"},
        {id = 10922, name = "Wound IV",         color = {0.95, 0.45, 0.4}, poison = "wound"},
        {id = 10921, name = "Wound III",        color = {0.95, 0.45, 0.4}, poison = "wound"},
        {id = 10920, name = "Wound II",         color = {0.95, 0.45, 0.4}, poison = "wound"},
        {id = 10918, name = "Wound",            color = {0.95, 0.45, 0.4}, poison = "wound"},
        {id = 3776,  name = "Crippling II",     color = {0.55, 0.65, 0.95}, poison = "crippling"},
        {id = 3775,  name = "Crippling",        color = {0.55, 0.65, 0.95}, poison = "crippling"},
        {id = 9186,  name = "Mind-numbing III", color = {0.8, 0.5, 0.95}, poison = "mind"},
        {id = 6951,  name = "Mind-numbing II",  color = {0.8, 0.5, 0.95}, poison = "mind"},
        {id = 5237,  name = "Mind-numbing",     color = {0.8, 0.5, 0.95}, poison = "mind"},
    }
    if RC.flavorStoneTypes then
        local colourOf = {}
        for _, s in ipairs(STONE_TYPES) do colourOf[s.id] = s.color end
        local list = {}
        for i, s in ipairs(RC.flavorStoneTypes) do
            list[i] = { id = s.id, name = s.name, color = colourOf[s.like] or colourOf[18262], poison = s.poison }
        end
        STONE_TYPES = list
    end

    -- POISONS PER HAND. A rogue's weapons bar remembers a pick for each
    -- hand (consumablesHelper.selectedStoneBySlot), stones included, so
    -- Instant on the main hand and Deadly on the off hand both stick.
    -- With no pick yet a hand takes the first poison carried in its usual
    -- order, and a poison that runs out falls back to another rank of the
    -- same poison. Everyone else keeps the one stone for both hands.
    local POISON_KIND = {}
    for _, s in ipairs(STONE_TYPES) do
        if s.poison then POISON_KIND[s.id] = s.poison end
    end
    local SLOT_POISON_ORDER = {
        mainhand = { "instant", "wound", "mind", "crippling", "deadly" },
        offhand  = { "deadly", "instant", "crippling", "wound", "mind" },
    }
    local function IsRogue()
        local _, c = UnitClass("player")
        return c == "ROGUE"
    end
    local function FirstCarriedOfKind(kind)
        for _, s in ipairs(STONE_TYPES) do
            if s.poison == kind and GetItemCount(s.id) > 0 then return s.id end
        end
        return nil
    end
    function RC:CreateStonePickerDropdown()
        if self.stonePickerDropdown then return self.stonePickerDropdown end

        -- Floating menu: flat dropdown.background box, 1px black edge,
        -- 6px inner padding, 22px rows. No statusbar texture on chrome.
        local FLAT = RC.UI.FLAT or "Interface\\Buttons\\WHITE8X8"
        local MENU_W, MENU_PAD, ROW_H, HEADER_H = (IsRogue() and 170 or 140), 6, 22, 16

        local dropdown = CreateFrame("Frame", "WRStonePickerDropdown", UIParent, "BackdropTemplate")
        dropdown:SetFrameStrata("TOOLTIP")
        dropdown:SetBackdrop({
            bgFile = FLAT,
            edgeFile = FLAT,
            edgeSize = 1,
        })
        local dropBg  = RC:GetColor("dropdown", "background")
        local dropBdr = RC:GetColor("ui", "borderNormal")
        dropdown:SetBackdropColor(dropBg.r, dropBg.g, dropBg.b, dropBg.a or 0.98)
        dropdown:SetBackdropBorderColor(dropBdr.r, dropBdr.g, dropBdr.b, dropBdr.a or 1)
        dropdown:Hide()

        RC.UI:RegisterEscapeClose("WRStonePickerDropdown")

        -- Section header: 10px gray, text inset 8.
        local title = self:CreateFontString(dropdown, "OVERLAY", nil, 10)
        title:SetPoint("TOPLEFT", dropdown, "TOPLEFT", MENU_PAD + 8, -MENU_PAD)
        title:SetText(IsRogue() and RCL["Select Poison or Stone"] or RCL["Select Stone Type"])
        local hdrC = RC:GetColor("text", "gray")
        title:SetTextColor(hdrC.r, hdrC.g, hdrC.b, 1)
        dropdown.title = title

        dropdown.noStonesText = self:CreateFontString(dropdown, "OVERLAY", nil, 10)
        dropdown.noStonesText:SetPoint("TOPLEFT", dropdown, "TOPLEFT", MENU_PAD + 8, -(MENU_PAD + HEADER_H + 4))
        dropdown.noStonesText:SetText(IsRogue() and RCL["No poisons or stones in bags"] or RCL["No stones in bags"])
        local disC = RC:GetColor("text", "disabled")
        dropdown.noStonesText:SetTextColor(disC.r, disC.g, disC.b, 1)
        dropdown.noStonesText:Hide()

        dropdown.buttons = {}

        -- Rows: transparent at rest, dropdown.itemHover under the mouse,
        -- the current stone marked by gold text and a check glyph.
        local restC = { r = 0, g = 0, b = 0, a = 0 }
        for i = 1, #STONE_TYPES do
            local btn = CreateFrame("Button", nil, dropdown)
            btn:SetSize(MENU_W - MENU_PAD * 2, ROW_H)
            btn:Hide()

            btn.bg = btn:CreateTexture(nil, "BACKGROUND")
            btn.bg:SetAllPoints()
            btn.bg:SetTexture(FLAT)
            btn.bg:SetVertexColor(0, 0, 0, 0)
            RC.UI:AttachHover(btn, restC, RC:GetColor("dropdown", "itemHover"))

            local icon = btn:CreateTexture(nil, "ARTWORK")
            icon:SetSize(16, 16)
            icon:SetPoint("LEFT", btn, "LEFT", 8, 0)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            btn.icon = icon

            btn.text = self:CreateFontString(btn, "OVERLAY", nil, 11)
            btn.text:SetPoint("LEFT", icon, "RIGHT", 6, 0)
            btn.text:SetPoint("RIGHT", btn, "RIGHT", -20, 0)
            btn.text:SetJustifyH("LEFT")

            local selected = btn:CreateTexture(nil, "OVERLAY")
            selected:SetSize(10, 10)
            selected:SetPoint("RIGHT", btn, "RIGHT", -6, 0)
            selected:SetTexture("Interface\\AddOns\\Readycheck\\Media\\Checkmark.tga")
            local checkC = RC:GetColor("checkbox", "checkmark")
            selected:SetVertexColor(checkC.r, checkC.g, checkC.b, 1)
            selected:Hide()
            btn.selected = selected

            dropdown.buttons[i] = btn
        end

        dropdown:SetScript("OnShow", function(self)
            local tb = self.targetButton
            local currentStone = RC:GetValidStoneType(tb and tb.weaponSlot)
            local visibleCount = 0

            for _, btn in ipairs(self.buttons) do
                btn:Hide()
            end

            for i, stone in ipairs(STONE_TYPES) do
                local count = GetItemCount(stone.id)
                if count > 0 then
                    visibleCount = visibleCount + 1
                    local btn = self.buttons[visibleCount]
                    if btn then
                        btn:ClearAllPoints()
                        btn:SetPoint("TOPLEFT", self, "TOPLEFT", MENU_PAD, -(MENU_PAD + HEADER_H) - (visibleCount-1) * ROW_H)
                        btn.icon:SetTexture(GetItemIcon(stone.id))
                        btn.text:SetText(stone.name .. " (" .. count .. ")")
                        btn.stoneId = stone.id

                        if stone.id == currentStone then
                            local selC = RC:GetColor("dropdown", "selected")
                            btn.text:SetTextColor(selC.r, selC.g, selC.b, 1)
                            btn.selected:Show()
                        else
                            btn.text:SetTextColor(stone.color[1], stone.color[2], stone.color[3])
                            btn.selected:Hide()
                        end

                        btn:SetScript("OnClick", function()
                            RC:SelectStoneType(stone.id, self.targetButton)
                            self:Hide()
                        end)

                        btn:Show()
                    end
                end
            end

            if visibleCount == 0 then
                self.noStonesText:Show()
                self:SetSize(MENU_W, MENU_PAD * 2 + HEADER_H + 4 + 16)
            else
                self.noStonesText:Hide()
                self:SetSize(MENU_W, MENU_PAD * 2 + HEADER_H + visibleCount * ROW_H)
            end
        end)

        -- The only OnUpdate in the folder, scoped to a dropdown that is
        -- hidden the rest of the time. Auto-closes 0.5s after mouse-off.
        dropdown:SetScript("OnUpdate", function(self, elapsed)
            if not MouseIsOver(self) and not MouseIsOver(self.targetButton) then
                self.hideTimer = (self.hideTimer or 0) + elapsed
                if self.hideTimer > 0.5 then
                    self:Hide()
                    self.hideTimer = 0
                end
            else
                self.hideTimer = 0
            end
        end)

        self.stonePickerDropdown = dropdown
        return dropdown
    end

    function RC:ShowStonePicker(button)
        local dropdown = self:CreateStonePickerDropdown()
        dropdown.targetButton = button

        dropdown:ClearAllPoints()
        dropdown:SetPoint("TOPLEFT", button, "TOPRIGHT", 5, 0)
        dropdown:Show()
    end

    function RC:IsWeaponOilItem(itemId)
        if not self._oilItemSet then
            local set = {}
            for _, info in pairs(self.temporaryWeaponEnchants or {}) do
                if type(info) == "table" and info.itemId and info.isOil then
                    set[info.itemId] = true
                end
            end
            for itemId in pairs(self.weaponOilExtra or {}) do set[itemId] = true end
            self._oilItemSet = set
        end
        return self._oilItemSet[itemId] or false
    end

    -- User's pick if carried, else the first carried STONE_TYPES entry,
    -- else 18262 so the macro and icon always resolve to something.
    -- slot ("mainhand"/"offhand") asks for that hand's pick (rogues).
    function RC:GetValidStoneType(slot)
        local ch = self.db.consumablesHelper
        if (slot == "mainhand" or slot == "offhand") and IsRogue() then
            local bySlot = ch.selectedStoneBySlot
            local pick = type(bySlot) == "table" and bySlot[slot] or nil
            if pick then
                if GetItemCount(pick) > 0 then return pick end
                local kind = POISON_KIND[pick]
                local alt = kind and FirstCarriedOfKind(kind)
                if alt then return alt end
            end
            if not pick or POISON_KIND[pick] then
                for _, kind in ipairs(SLOT_POISON_ORDER[slot]) do
                    local id = FirstCarriedOfKind(kind)
                    if id then return id end
                end
            end
        end
        local currentStone = ch.selectedStoneType or 18262

        if GetItemCount(currentStone) > 0 then
            return currentStone
        end

        for _, stone in ipairs(STONE_TYPES) do
            if GetItemCount(stone.id) > 0 then
                return stone.id
            end
        end

        return STONE_TYPES[1].id
    end

    function RC:SelectStoneType(stoneId, button)
        local slot = button and button.weaponSlot
        if (slot == "mainhand" or slot == "offhand") and IsRogue() then
            local ch = self.db.consumablesHelper
            if type(ch.selectedStoneBySlot) ~= "table" then ch.selectedStoneBySlot = {} end
            ch.selectedStoneBySlot[slot] = stoneId
        else
            self.db.consumablesHelper.selectedStoneType = stoneId
        end
        self:SaveConfigurationToProfile()

        if button and button.weaponSlot then
            self:UpdateWeaponButtonMacro(button)
            self:UpdateWeaponButtonStoneIcon(button)
        end

        if not InCombatLockdown() then
            self:ForceRebuildWeaponButtons()
        end
    end

    local WEAPON_CLICK_DEFAULTS = {
        left = "stone", right = "picker",
        shiftLeft = "equipMH", shiftRight = "equipOH",
        ctrlLeft = "none", ctrlRight = "none",
    }

    function RC:GetWeaponClickAction(slot)
        local wb = self.db and self.db.weaponsBar
        local ca = wb and wb.clickActions
        if ca and ca[slot] ~= nil then return ca[slot] end
        return WEAPON_CLICK_DEFAULTS[slot] or "none"
    end

    function RC:GetWeaponBarClickSlot(mouseButton)
        local isRight = (mouseButton == "RightButton")
        if IsShiftKeyDown() then
            return isRight and "shiftRight" or "shiftLeft"
        elseif IsControlKeyDown() then
            return isRight and "ctrlRight" or "ctrlLeft"
        end
        return isRight and "right" or "left"
    end

    -- Rewrites a weapon button's secure macrotext. SetAttribute on a
    -- protected button is forbidden in combat, so this bails outright;
    -- callers queue via pendingWeaponRebuildOnCombatEnd instead.
    function RC:UpdateWeaponButtonMacro(button)
        if InCombatLockdown() then return end
        if not button or not button.weaponSlot then return end

        local stoneId = self:GetValidStoneType(button.weaponSlot)

        local stoneTarget, weaponName
        if button.weaponSlot == "bag" and button.bagSlot and button.bagPosition then
            stoneTarget = button.bagSlot .. " " .. button.bagPosition
            weaponName = button.itemData and button.itemData.name
        elseif button.weaponSlot == "mainhand" or button.weaponSlot == "offhand" then
            -- 16/17 are the inventory slot ids for main hand / off hand;
            -- "/use <slot>" targets the equipped weapon by number.
            local invSlot = (button.weaponSlot == "mainhand") and 16 or 17
            stoneTarget = tostring(invSlot)
            local link = GetInventoryItemLink("player", invSlot)
            weaponName = link and link:match("%[(.-)%]")
        else
            return
        end

        local clause = {
            left       = "button:1,nomod",     right      = "button:2,nomod",
            shiftLeft  = "button:1,mod:shift",  shiftRight = "button:2,mod:shift",
            ctrlLeft   = "button:1,mod:ctrl",   ctrlRight  = "button:2,mod:ctrl",
        }
        local cond = { stone = "", equipMH = "", equipOH = "" }
        if button.isWeaponsBar then
            for _, slot in ipairs({ "left", "right", "shiftLeft", "shiftRight", "ctrlLeft", "ctrlRight" }) do
                local act = self:GetWeaponClickAction(slot)
                if cond[act] ~= nil then
                    cond[act] = cond[act] .. "[" .. clause[slot] .. "]"
                end
            end
        else
            cond.stone = "[" .. clause.left .. "][" .. clause.right .. "]"
        end
        local lines = {}
        if cond.stone ~= "" then
            table.insert(lines, "/use " .. cond.stone .. " item:" .. tostring(stoneId))
            table.insert(lines, "/use " .. cond.stone .. " " .. stoneTarget)
        end
        if cond.equipMH ~= "" and weaponName then
            table.insert(lines, "/equipslot " .. cond.equipMH .. " 16 " .. weaponName)
        end
        if cond.equipOH ~= "" and weaponName then
            table.insert(lines, "/equipslot " .. cond.equipOH .. " 17 " .. weaponName)
        end
        -- Applying an enchant over an existing one raises a confirmation
        -- popup; clicking it from the same macro makes reapply one click.
        -- [nodead]: dead, the first popup is "Release Spirit" - a press
        -- of this button must never release you (Zac 2026-11-02).
        table.insert(lines, "/click [nodead] StaticPopup1Button1")
        -- Clear per-modifier attributes first: a leftover type1/shift-type1
        -- outranks plain "type" and would swallow the click.
        for _, a in ipairs({ "type1","macrotext1","type2","macrotext2",
                             "shift-type1","shift-macrotext1","shift-type2","shift-macrotext2",
                             "ctrl-type1","ctrl-macrotext1","ctrl-type2","ctrl-macrotext2" }) do
            button:SetAttribute(a, nil)
        end
        button:SetAttribute("type", "macro")
        button:SetAttribute("macrotext", table.concat(lines, "\n"))
            if button.isWeaponsBar then
                button:RegisterForClicks("AnyDown", "AnyUp")
            else
                button:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
            end
    end

    function RC:UpdateWeaponButtonStoneIcon(button)
        if not button then return end

        local stoneId = self:GetValidStoneType(button.weaponSlot)

        if button.stoneTypeIcon then
            button.stoneTypeIcon:SetTexture(GetItemIcon(stoneId))
        end
    end

    -- SetParent(nil) on a secure button is combat-forbidden: in combat it
    -- is queued for the consumables bar's combat-end handler instead.
    function RC:ForceRebuildWeaponButtons()
        if InCombatLockdown() then
            self.consumablesHelper.pendingWeaponRebuildOnCombatEnd = true
            return
        end

        self:DebugPrint("ForceRebuildWeaponButtons: Clearing weapon buttons for rebuild", "items")

        if self.consumablesHelper.buttons then
            local toRemove = {}
            -- Synthetic ids the weapon system owns, all invalidated by an
            -- equipment change: 999901/999902 slot buttons, <stoneId><1|2>
            -- per-stone buttons, 900000+bag*100+slot bag weapons.
            for itemId, button in pairs(self.consumablesHelper.buttons) do
                local isUnifiedButton = (itemId == 999901 or itemId == 999902)
                local isOldWeaponStone = (itemId == 182621 or itemId == 182622 or
                                          itemId == 231221 or itemId == 231222 or
                                          itemId == 124041 or itemId == 124042 or
                                          itemId == 38291 or itemId == 38292)
                local isBagWeapon = (itemId >= 900000 and itemId < 999900)

                if isUnifiedButton or isOldWeaponStone or isBagWeapon then
                    table.insert(toRemove, itemId)
                end
            end

            for _, itemId in ipairs(toRemove) do
                local button = self.consumablesHelper.buttons[itemId]
                if button then
                    button:Hide()
                    button:SetParent(nil)
                    self.consumablesHelper.buttons[itemId] = nil
                end
            end

            self:DebugPrint(string.format(RCL["ForceRebuildWeaponButtons: Removed %d consumables buttons"], #toRemove), "items")
        end

        if self.weaponsBar.buttons then
            for itemId, button in pairs(self.weaponsBar.buttons) do
                if button then
                    button:Hide()
                    button:SetParent(nil)
                end
            end
            self.weaponsBar.buttons = {}
            self:DebugPrint("ForceRebuildWeaponButtons: Cleared weapons bar buttons", "items")
        end

        self:UpdateConsumablesButtons()
        self:UpdateWeaponsButtons()
    end

    function RC:RefreshWeaponButtons()
        if InCombatLockdown() then return end

        -- the bags this rebuild saw; the bag-change handler skips a
        -- second rebuild for the same ones (an equip from the bags fires
        -- both the equip and the bag news)
        self.consumablesHelper._weaponsBagVersion = RC.Bags:Version()
        self:UpdateConsumablesButtons()
        self:UpdateWeaponsButtons()

        local function refreshButtonMacro(btn)
            if btn and btn.weaponSlot and self.UpdateWeaponButtonMacro then
                self:UpdateWeaponButtonMacro(btn)
                if self.UpdateWeaponButtonStoneIcon then
                    self:UpdateWeaponButtonStoneIcon(btn)
                end
            end
        end
        if self.consumablesHelper and self.consumablesHelper.buttons then
            for _, btn in pairs(self.consumablesHelper.buttons) do refreshButtonMacro(btn) end
        end
        if self.weaponsBar and self.weaponsBar.buttons then
            for _, btn in pairs(self.weaponsBar.buttons) do refreshButtonMacro(btn) end
        end
    end

    function RC:RefreshWeaponsBarConfigPanel()
        if InCombatLockdown() then return end
        if not (self.SidebarState and self.SidebarState.currentPanel == "weapons_bar") then return end
        if not (self.sidebarConfigFrame and self.sidebarConfigFrame:IsShown()) then return end
        if self.sidebarConfigFrame.weaponsBarTab ~= "weapons" then return end
        if self.ShowSidebarWeaponsBarConfig then
            self:ShowSidebarWeaponsBarConfig(self.sidebarConfigFrame, true)
        end
    end
end
