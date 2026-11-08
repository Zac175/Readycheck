------------------------------------------------------------------------
-- Readycheck - Event Dispatch, Aura Coalescing, Target/Combat State
-- Owns RC:OnEvent (the single handler every RegisterEvent frame calls
-- into), the UNIT_AURA subscriber system, target-health polling, combat
-- state tracking, gear-swap post-combat handling, and reminder
-- fade/dismiss timers.
-- UNIT_AURA and UNIT_HEALTH(target) fire at high frequency in raids -
-- handlers here only flip a dirty flag or schedule a single coalesced
-- timer; they never do real work inline on the event itself.
------------------------------------------------------------------------
local CP = Readycheck.Compat
local GetSpellInfo = GetSpellInfo or CP.GetSpellInfo
local GetSpellCooldown = GetSpellCooldown or CP.GetSpellCooldown
local GetItemCount = GetItemCount or CP.GetItemCount

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local GetTime, UnitName, UnitGUID = GetTime, UnitName, UnitGUID
local UnitHealth, UnitHealthMax, UnitExists = UnitHealth, UnitHealthMax, UnitExists
local UnitAffectingCombat = UnitAffectingCombat
local CreateFrame, UIParent = CreateFrame, UIParent
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
local _cor = RC._cor
local ResetTTSState = _cor.ResetTTSState
function RC:OnEvent(event, ...)
    if event == "PLAYER_TARGET_CHANGED" then
        self:UpdateTargetInfo()
    elseif event == "UNIT_HEALTH" then
        local unit = ...
        if unit == "target" then
            self:ScheduleTargetInfoUpdate()
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        self:UpdateCombatState()
    elseif event == "PLAYER_REGEN_ENABLED" then
        self:UpdateCombatState()
        self:ProcessGearSwapQueue()

        if self.utilityItemsUsedOnBoss then
            local now = GetTime()
            local cleaned = 0
            for key, timestamp in pairs(self.utilityItemsUsedOnBoss) do
                if now - timestamp > 300 then
                    self.utilityItemsUsedOnBoss[key] = nil
                    cleaned = cleaned + 1
                end
            end
            if cleaned > 0 then
                self:DebugPrint("Cleaned " .. cleaned .. " old boss utility tracking entries", "buff")
            end
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, castGUID, spellID = ...
        if unit == "player" then
            if RC.Profiler and RC.Profiler.CountHit then
                RC.Profiler:CountHit("Event:SpellCast(player)")
            end
            if self.ProcessSpellCastForDismissal then
                self:ProcessSpellCastForDismissal(spellID)
            end

            if self.RecordAbilityUsage then
                self:RecordAbilityUsage(spellID)
            end
        end
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local slotID = ...
        if slotID == 13 or slotID == 14 then
            self:ScanEquippedTrinkets()
        end
    end
end

do
    RC._unitAuraSubscribers = {}
    -- Aura names some subscriber watches (name -> shortest duration any
    -- of them cares about), and which live aura instance carries one.
    -- Nothing else is ever recorded by name.
    RC._auraWatchedNames = {}
    RC._auraInstanceName = {}
    RC._auraInstanceDur  = {}

    local function RebuildWatchedNames()
        local all = RC._auraWatchedNames
        for nm in pairs(all) do all[nm] = nil end
        for _, sub in pairs(RC._unitAuraSubscribers) do
            if sub.watchNames then
                for nm, minDur in pairs(sub.watchNames) do
                    if all[nm] == nil or minDur < all[nm] then all[nm] = minDur end
                end
            end
        end
    end

    -- True for an aura a subscriber watches by name. A name can carry a
    -- minimum duration, so the two-minute version of a buff that is
    -- recast all fight long is never recorded and never wakes anyone.
    local function WatchedByName(a)
        local minDur = a.name and RC._auraWatchedNames[a.name]
        return minDur ~= nil and (a.duration or 0) >= minDur
    end

    -- spellIds narrows a subscriber to those auras. spellNames (optional,
    -- only read alongside spellIds) adds auras matched by exact name: the
    -- same buff under another spell id - a different rank, an NPC's cast
    -- - shares the name but not the id, so an id list alone never wakes
    -- for it. Entries are either a plain name, or name = seconds to match
    -- only auras that last at least that long (each subscriber's own
    -- minimum is honoured, whatever the others ask for).
    function RC:RegisterUnitAuraCallback(key, interval, fn, spellIds, spellNames)
        local watch
        if type(spellIds) == "table" then
            watch = {}
            for _, id in ipairs(spellIds) do watch[id] = true end
        end
        local watchNames
        if watch and type(spellNames) == "table" then
            for k, v in pairs(spellNames) do
                local nm, minDur
                if type(k) == "number" then nm, minDur = v, 0 else nm, minDur = k, tonumber(v) or 0 end
                if type(nm) == "string" and nm ~= "" then
                    watchNames = watchNames or {}
                    watchNames[nm] = minDur
                end
            end
        end
        RC._unitAuraSubscribers[key] = {
            fn       = fn,
            name     = key,
            interval = interval or 0.2,
            dirty    = false,
            pending  = false,
            watch    = watch,
            watchNames = watchNames,
        }
        RebuildWatchedNames()
        -- Auras already up were seeded before these names were watched;
        -- read them again so their removal is recognised too.
        if watchNames and RC._auraLedgerSeeded and RC.SeedAuraLedger then
            RC:SeedAuraLedger()
        end
    end

    -- Subscribers that only care about auras for a short burst should drop
    -- out again afterwards. Every aura change otherwise costs them a timer
    -- and a call for the rest of the session, which adds up in a raid.
    function RC:UnregisterUnitAuraCallback(key)
        if key then
            RC._unitAuraSubscribers[key] = nil
            RebuildWatchedNames()
        end
    end

    -- UNIT_AURA's incremental updateInfo gives removed/updated entries
    -- only as auraInstanceIDs, not spellIds. This ledger maps instance ID
    -- to spellId so those deltas can still be resolved to "what changed"
    -- without a full aura rescan.
    RC._auraInstanceSpell = {}
    -- WoW Forever: an aura read in combat can be "secret" - not to be
    -- compared or used as a table key. Always false on the other clients.
    local issecret = issecretvalue
    local function SecretAura(a)
        return issecret ~= nil and (issecret(a.spellId) or issecret(a.name)
            or issecret(a.auraInstanceID) or issecret(a.duration))
    end
    function RC:SeedAuraLedger()
        local led = RC._auraInstanceSpell
        local ledName, ledDur = RC._auraInstanceName, RC._auraInstanceDur
        if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
            for i = 1, 40 do
                local a
                if issecret ~= nil then
                    -- (Forever can refuse the read outright: the end of the list)
                    local ok, r = pcall(C_UnitAuras.GetBuffDataByIndex, "player", i)
                    a = ok and r or nil
                else
                    a = C_UnitAuras.GetBuffDataByIndex("player", i)
                end
                if not a or SecretAura(a) then break end
                if a.auraInstanceID and a.spellId then
                    led[a.auraInstanceID] = a.spellId
                end
                if a.auraInstanceID and WatchedByName(a) then
                    ledName[a.auraInstanceID] = a.name
                    ledDur[a.auraInstanceID]  = a.duration or 0
                end
            end
        end
        if C_UnitAuras and C_UnitAuras.GetDebuffDataByIndex then
            for i = 1, 40 do
                local a
                if issecret ~= nil then
                    local ok, r = pcall(C_UnitAuras.GetDebuffDataByIndex, "player", i)
                    a = ok and r or nil
                else
                    a = C_UnitAuras.GetDebuffDataByIndex("player", i)
                end
                if not a or SecretAura(a) then break end
                if a.auraInstanceID and a.spellId then
                    led[a.auraInstanceID] = a.spellId
                end
                if a.auraInstanceID and WatchedByName(a) then
                    ledName[a.auraInstanceID] = a.name
                    ledDur[a.auraInstanceID]  = a.duration or 0
                end
            end
        end
    end

    -- This is the only UNIT_AURA registration in the addon. RC:RegisterEvent
    -- (Core_Init.lua) refuses to register UNIT_AURA for anyone else, so
    -- every aura-driven feature must go through RegisterUnitAuraCallback
    -- above rather than registering its own frame.
    local coordFrame = CreateFrame("Frame")
    coordFrame:RegisterUnitEvent("UNIT_AURA", "player")
    coordFrame:SetScript("OnEvent", function(_, event, unit, updateInfo)
        if unit ~= "player" then return end
        -- the shared aura read (Systems/AuraIndex) is stale from here on
        if RC.Auras then RC.Auras:Invalidate() end
        if not RC._auraLedgerSeeded then
            RC._auraLedgerSeeded = true
            RC:SeedAuraLedger()
        end
        local changed
        -- Watched aura names touched by this update, each with the
        -- longest duration among the instances involved; nil when none.
        -- (A short aura that is lengthened in place is not seen here - the
        -- event carries no durations for updates, and reading the aura
        -- back is work this handler does not do.)
        local changedNames
        if type(updateInfo) == "table" and not updateInfo.isFullUpdate then
            changed = {}
            local ok = true
            local led = RC._auraInstanceSpell
            local ledName, ledDur = RC._auraInstanceName, RC._auraInstanceDur
            if updateInfo.addedAuras then
                for _, a in ipairs(updateInfo.addedAuras) do
                    if type(a) == "table" and not SecretAura(a) and a.spellId then
                        changed[a.spellId] = true
                        if a.auraInstanceID then led[a.auraInstanceID] = a.spellId end
                        if WatchedByName(a) then
                            local dur = a.duration or 0
                            changedNames = changedNames or {}
                            if dur >= (changedNames[a.name] or 0) then changedNames[a.name] = dur end
                            if a.auraInstanceID then
                                ledName[a.auraInstanceID] = a.name
                                ledDur[a.auraInstanceID]  = dur
                            end
                        end
                    else
                        ok = false; break
                    end
                end
            end
            if ok and updateInfo.updatedAuraInstanceIDs then
                for _, iid in ipairs(updateInfo.updatedAuraInstanceIDs) do
                    local nm = ledName[iid]
                    if nm then
                        local dur = ledDur[iid] or 0
                        changedNames = changedNames or {}
                        if dur >= (changedNames[nm] or 0) then changedNames[nm] = dur end
                    end
                    local sid = led[iid]
                    if sid then changed[sid] = true else ok = false; break end
                end
            end
            if ok and updateInfo.removedAuraInstanceIDs then
                for _, iid in ipairs(updateInfo.removedAuraInstanceIDs) do
                    -- Name first: the id branch below can leave the loop.
                    local nm = ledName[iid]
                    if nm then
                        local dur = ledDur[iid] or 0
                        changedNames = changedNames or {}
                        if dur >= (changedNames[nm] or 0) then changedNames[nm] = dur end
                        ledName[iid], ledDur[iid] = nil, nil
                    end
                    local sid = led[iid]
                    if sid then
                        changed[sid] = true
                        led[iid] = nil
                    else
                        ok = false; break
                    end
                end
            end
            -- Any missing ledger entry means the delta can't be trusted;
            -- fall back to changed=nil, which the dispatch loop below
            -- treats as "something changed, notify every subscriber".
            if not ok then changed = nil end
        end
        for _, sub in pairs(RC._unitAuraSubscribers) do
            local hit = (sub.watch == nil) or (changed == nil)
            if not hit then
                for sid in pairs(changed) do
                    if sub.watch[sid] then hit = true; break end
                end
            end
            if not hit and changedNames and sub.watchNames then
                for nm, dur in pairs(changedNames) do
                    local minDur = sub.watchNames[nm]
                    if minDur ~= nil and dur >= minDur then hit = true; break end
                end
            end
            if hit then
            sub.dirty = true
            if not sub.pending then
                sub.pending = true
                local s = sub
                C_Timer.After(s.interval, function()
                    s.pending = false
                    if not s.dirty then return end
                    s.dirty = false
                    if RC.Profiler and RC.Profiler.StartTiming then
                        RC.Profiler:StartTiming("UnitAura:" .. (s.name or "?"))
                        s.fn()
                        RC.Profiler:StopTiming("UnitAura:" .. (s.name or "?"))
                    else
                        s.fn()
                    end
                end)
            end
            end
        end
    end)
end

local debuffAbilities = {
    ["deathwish"] = "Death Wish",
    ["death wish"] = "Death Wish",
}

local buffAbilities = {
    ["recklessness"] = "Recklessness",
    ["bloodrage"] = "Bloodrage",
    ["berserkerrage"] = "Berserker Rage",
    ["berserker rage"] = "Berserker Rage",
    ["bloodfury"] = "Blood Fury",
    ["blood fury"] = "Blood Fury",
    ["battleshout"] = "Battle Shout",
    ["battle shout"] = "Battle Shout",
    ["shieldwall"] = "Shield Wall",
    ["shield wall"] = "Shield Wall",
    ["laststand"] = "Last Stand",
    ["last stand"] = "Last Stand",
    ["retaliation"] = "Retaliation",
    ["sweepingstrikes"] = "Sweeping Strikes",
    ["sweeping strikes"] = "Sweeping Strikes",
}

local spellIdToAbility = {
    [12292] = "deathwish",
    [12328] = "deathwish",
    [1719] = "recklessness",
    [2687] = "bloodrage",
    [18499] = "berserkerrage",
    [20572] = "bloodfury",
    -- Berserking has one spell ID per resource type: 20554 mana classes,
    -- 26296 warriors, 26297 rogues. Warriors cast 26296, so tracking only
    -- 20554 never registered the racial as used.
    [20554] = "berserking",
    [26296] = "berserking",
    [26297] = "berserking",
    [6673] = "battleshout",
    [5242] = "battleshout",
    [6192] = "battleshout",
    [11549] = "battleshout",
    [11550] = "battleshout",
    [25289] = "battleshout",
    [871] = "shieldwall",
    [12975] = "laststand",
    [20230] = "retaliation",
    [12723] = "sweepingstrikes",
}

-- If the buff granted by spellId is currently on the player, returns its
-- remaining time (seconds) and localized name; otherwise returns nil.
-- Shared by the potion/utility/protection ready checks in IsAbilityReady.
local function GetActiveBuffRemaining(spellId)
    local buffName = spellId and GetSpellInfo(spellId)
    if not buffName then return nil end
    local a = RC.Auras:BuffNamed(buffName)
    if a then return a.expirationTime - GetTime(), buffName end
    return nil
end

function RC:IsAbilityReady(abilityKey, allowGracePeriod, triggerType)

    if not self.abilityData then
        return false
    end

    -- These keys are persistent/reminder-only markers, not real abilities -
    -- they always report "ready" so the popup keeps showing them until
    -- something else explicitly dismisses the reminder.
    if type(abilityKey) == "string" and (abilityKey:find("^frostBlastBuff_") or abilityKey == "boon" or abilityKey == "equipReminder" or abilityKey == "preTargetConsumable") then
        return true, nil
    end

    if abilityKey == "bloodfury" or abilityKey == "berserking" then
        local _, playerRace = UnitRace("player")
        if abilityKey == "bloodfury" and playerRace ~= "Orc" then
            return false
        elseif abilityKey == "berserking" and playerRace ~= "Troll" then
            return false
        end
    end

    -- Grace period: an ability still on a short cooldown tail can count as
    -- "ready" so the reminder doesn't flicker off and back on. Every
    -- cooldown branch below reports (false) or (true, remaining) using
    -- self.db.abilityReadyGracePeriod as the cutoff.
    allowGracePeriod = allowGracePeriod ~= false

    local isPotionKey = abilityKey and type(abilityKey) == "string" and
                       (abilityKey == "potion" or abilityKey:lower():find("potion"))
    if isPotionKey then
        local potionItemId = nil

        if self.cooldownTracker and self.cooldownTracker.potionItemIds then
            for itemId, potionName in pairs(self.cooldownTracker.potionItemIds) do
                if potionName == abilityKey then
                    potionItemId = itemId
                    break
                end
            end
        end

        if not potionItemId and RC.potionItemIds then
            for itemId, potionName in pairs(RC.potionItemIds) do
                if potionName == abilityKey then
                    potionItemId = itemId
                    break
                end
            end
        end

        if not potionItemId and RC.potionData and RC.potionData.potions and RC.potionData.potions[abilityKey] then
            potionItemId = RC.potionData.potions[abilityKey].itemId
        end

        self:DebugPrint(string.format(RCL["Potion ready check: %s -> itemId=%s"],
            abilityKey, tostring(potionItemId)), "trigger")

        if potionItemId then
            local itemCount = GetItemCount(potionItemId)

            if itemCount == 0 then
                self:DebugPrint("Potion not in bags: " .. abilityKey .. " (itemId " .. potionItemId .. ")", "trigger")
                return false
            end

            self:DebugPrint(string.format(RCL["Potion in bags: %s x%d"], abilityKey, itemCount), "trigger")

            local onCooldown = false
            local cooldownRemaining = 0

            -- duration > 1.5 filters out the shared ~1.5s GCD flash that
            -- every item/spell cooldown read also reports; this threshold
            -- repeats through the rest of this function for the same reason.
            local start, duration = self:GetItemCooldown(potionItemId)
            if start and start > 0 and duration and duration > 1.5 then
                cooldownRemaining = math.max(0, (start + duration) - GetTime())
                onCooldown = cooldownRemaining > 0
            end

            if onCooldown then
                local gracePeriod = self.db.abilityReadyGracePeriod or 0
                if allowGracePeriod and gracePeriod > 0 and cooldownRemaining <= gracePeriod then
                    self:DebugPrint("Potion in grace period: " .. abilityKey .. " (" .. math.ceil(cooldownRemaining) .. "s)", "grace")
                    return true, cooldownRemaining
                end
                self:DebugPrint("Potion on cooldown: " .. abilityKey .. " (" .. math.ceil(cooldownRemaining) .. "s)", "cooldown")
                return false
            end

            if abilityKey:find("Protection") then
                if self.potionAbsorbSpells then
                    for checkItemId, potionData in pairs(self.potionAbsorbSpells) do
                        local timeRemaining, buffName = GetActiveBuffRemaining(potionData.spellId)
                        if timeRemaining then
                            self:DebugPrint("Protection buff already active: " .. buffName .. " (" .. math.ceil(timeRemaining) .. "s remaining)", "buff")
                            return false
                        end
                    end
                end
            end

            local potionBuffId = nil
            if self.raidConsumables and self.raidConsumables.potions and self.raidConsumables.potions.items[potionItemId] then
                potionBuffId = self.raidConsumables.potions.items[potionItemId].buffId
            end

            if potionBuffId then
                local timeRemaining, buffName = GetActiveBuffRemaining(potionBuffId)
                if timeRemaining then
                    self:DebugPrint("Potion buff already active: " .. buffName .. " (" .. math.ceil(timeRemaining) .. "s remaining)", "buff")
                    return false
                end
            end

            self:DebugPrint("Potion ready: " .. abilityKey, "items")
            return true
        else
            self:DebugPrint("Unknown potion: " .. abilityKey, "items")
            return false
        end
    end

    local itemId = tonumber(abilityKey)
    if itemId and self.utilityItems and self.utilityItems[itemId] then
        local utilityData = self.utilityItems[itemId]

        local itemCount = GetItemCount(itemId)
        if itemCount == 0 then
            self:DebugPrint("Utility item not in bags: " .. (utilityData.name or abilityKey), "items")
            return false
        end

        local onCooldown = false
        local cooldownRemaining = 0

        local start, duration = self:GetItemCooldown(itemId)
        if start and start > 0 and duration and duration > 1.5 then
            cooldownRemaining = math.max(0, (start + duration) - GetTime())
            onCooldown = cooldownRemaining > 0
        end

        if onCooldown then
            local gracePeriod = self.db.abilityReadyGracePeriod or 0
            if allowGracePeriod and gracePeriod > 0 and cooldownRemaining <= gracePeriod then
                self:DebugPrint("Utility item in grace period: " .. (utilityData.name or abilityKey) .. " (" .. math.ceil(cooldownRemaining) .. "s)", "grace")
                return true, cooldownRemaining
            end
            self:DebugPrint("Utility item on cooldown: " .. (utilityData.name or abilityKey) .. " (" .. math.ceil(cooldownRemaining) .. "s)", "cooldown")
            return false
        end

        local utilityBuffId = nil

        if self.raidConsumables and self.raidConsumables.utilities and self.raidConsumables.utilities.items[itemId] then
            utilityBuffId = self.raidConsumables.utilities.items[itemId].buffId
        end

        if not utilityBuffId and utilityData.spellId then
            utilityBuffId = utilityData.spellId
        end

        if utilityBuffId then
            local timeRemaining, buffName = GetActiveBuffRemaining(utilityBuffId)
            if timeRemaining then
                self:DebugPrint("Utility buff already active: " .. buffName .. " (" .. math.ceil(timeRemaining) .. "s remaining)", "buff")
                return false
            end
        end

        self:DebugPrint("Utility item ready: " .. (utilityData.name or abilityKey), "items")
        return true
    end

    if abilityKey == "trinket1" or abilityKey == "trinket2" then
        -- Identical logic for both trinket slots: slot 1 = inventory 13,
        -- slot 2 = inventory 14.
        local slotNum = (abilityKey == "trinket1") and 1 or 2
        local invSlot = 12 + slotNum
        if self.trinketSwapSystem and self.trinketSwapSystem.trinketStates then
            local state = self.trinketSwapSystem.trinketStates["slot" .. slotNum]
            if state and state.buffExpireTime and state.buffExpireTime > GetTime() then
                local buffRemaining = state.buffExpireTime - GetTime()
                self:DebugPrint("Trinket " .. slotNum .. " buff already active: " .. math.ceil(buffRemaining) .. "s remaining", "buff")
                return false
            end
        end
        local start, duration = Readycheck.PlainCD(GetInventoryItemCooldown("player", invSlot))
        if start and start > 0 and duration > 1.5 then
            local remaining = math.max(0, (start + duration) - GetTime())
            local gracePeriod = self.db.abilityReadyGracePeriod or 0
            if allowGracePeriod and gracePeriod > 0 and remaining <= gracePeriod then
                self:DebugPrint("Trinket " .. slotNum .. " in grace period: " .. math.ceil(remaining) .. "s remaining", "grace", 2)
                return true, remaining
            end
            self:DebugPrint("Trinket " .. slotNum .. " on cooldown: " .. math.ceil(remaining) .. "s remaining", "cooldown", 5)
            return false
        end
        return true
    end

    local abilityData = self.abilityData[abilityKey]
    if not abilityData then
        return false
    end

    local gracePeriod = self.db.abilityReadyGracePeriod or 0

    if self.IsAbilityOnCooldown and self:IsAbilityOnCooldown(abilityKey) then
        if allowGracePeriod and gracePeriod > 0 then
            local remaining = self.GetAbilityCooldownRemaining and self:GetAbilityCooldownRemaining(abilityKey)
            if remaining and remaining > 0 and remaining <= gracePeriod then
                self:DebugPrint(abilityKey .. " in grace period: " .. math.ceil(remaining) .. "s remaining", "grace", 2)
                return true, remaining
            end
        end
        self:DebugPrint(abilityKey .. " on cooldown", "cooldown", 5)
        return false
    end

    if abilityData.spellId and abilityKey ~= "trinket1" and abilityKey ~= "trinket2" then
        -- Use the class's own spell ID when the ability has variants
        -- (a warrior doesn't know 20554 Berserking, only 26296).
        local checkSpellId = abilityData.spellId
        if abilityData.spellIds and IsPlayerSpell then
            for _, id in ipairs(abilityData.spellIds) do
                if IsPlayerSpell(id) then checkSpellId = id; break end
            end
        end
        local start, duration = Readycheck.PlainCD(GetSpellCooldown(checkSpellId))
        if start and duration and start > 0 and duration > 1.5 then
            local remaining = math.max(0, (start + duration) - GetTime())
            if allowGracePeriod and gracePeriod > 0 and remaining <= gracePeriod then
                self:DebugPrint(abilityKey .. " spell in grace period: " .. math.ceil(remaining) .. "s remaining", "grace", 2)
                return true, remaining
            end
            self:DebugPrint(abilityKey .. " spell on cooldown: " .. math.ceil(remaining) .. "s remaining", "cooldown", 5)
            return false
        end
    end

    if abilityData.itemId then
        local itemCount = GetItemCount(abilityData.itemId)
        local equippedSlot = nil
        for _, slotId in ipairs({13, 14}) do
            if GetInventoryItemID("player", slotId) == abilityData.itemId then
                equippedSlot = slotId
                break
            end
        end

        if itemCount == 0 and not equippedSlot then
            self:DebugPrint(abilityKey .. " missing item (not in bags or equipped)", "items", 10)
            return false
        end

        local onCooldown = false
        local cooldownRemaining = 0

        -- Covers both the equipped-slot and bag copies of the item.
        local start, duration = self:GetItemCooldown(abilityData.itemId)
        if start and start > 0 and duration and duration > 1.5 then
            cooldownRemaining = math.max(0, (start + duration) - GetTime())
            onCooldown = cooldownRemaining > 0
        end

        if onCooldown then
            local gracePeriod = self.db.abilityReadyGracePeriod or 0
            if allowGracePeriod and gracePeriod > 0 and cooldownRemaining <= gracePeriod then
                self:DebugPrint(abilityKey .. " item in grace period: " .. math.ceil(cooldownRemaining) .. "s remaining", "grace", 2)
                return true, cooldownRemaining
            end
            self:DebugPrint(abilityKey .. " item on cooldown: " .. math.ceil(cooldownRemaining) .. "s remaining", "cooldown", 5)
            return false
        end
    end

    return true
end

function RC:SmartDismissReminder(reason)
    self:DebugPrint("Smart dismiss: " .. reason, "reminder")

    if self.activeReminderData.dismissalTimer then
        self.activeReminderData.dismissalTimer:Cancel()
        self.activeReminderData.dismissalTimer = nil
    end

    self:StartReminderFadeOut()

    self.activeReminderData.abilities = {}
    ResetTTSState(self.activeReminderData)
    self.activeReminderData.popupSessionID = 0
    self.activeReminderData.reminderExpireTime = 0
end

function RC:DismissReminderKeepingPersistent(reason)
    local PERSISTENT = { equipReminder = true, preTargetConsumable = true }

    local abilities = self.activeReminderData and self.activeReminderData.abilities
    if not abilities or #abilities == 0 then
        self:SmartDismissReminder(reason)
        return
    end

    local persistentCount, otherCount = 0, 0
    for _, key in ipairs(abilities) do
        if PERSISTENT[key] then persistentCount = persistentCount + 1
        else otherCount = otherCount + 1 end
    end

    if persistentCount == 0 then
        self:SmartDismissReminder(reason)
    elseif otherCount == 0 then
        self:DebugPrint("Keeping persistent reminder through: " .. reason, "reminder")
    else
        for i = #abilities, 1, -1 do
            if not PERSISTENT[abilities[i]] then
                table.remove(abilities, i)
            end
        end
        self:DebugPrint("Pruned non-persistent reminders, keeping persistent through: " .. reason, "reminder")
        self:UpdateReminderWithRemainingAbilities()
    end
end

function RC:InstantDismissReminder(reason)
    self:DebugPrint("Instant dismiss: " .. reason, "reminder")

    if self.activeReminderData.dismissalTimer then
        self.activeReminderData.dismissalTimer:Cancel()
        self.activeReminderData.dismissalTimer = nil
    end

    self:StopReminderAnimation()

    if self.reminderFrame then
        self.reminderFrame:SetAlpha(0)
        self.reminderFrame:Hide()

        if self.reminderFrame.abilityIcons then
            for _, icon in pairs(self.reminderFrame.abilityIcons) do
                if icon.pulseTimer then
                    icon.pulseTimer:Cancel()
                    icon.pulseTimer = nil
                end
                if icon.animationTimer then
                    icon.animationTimer:Cancel()
                    icon.animationTimer = nil
                end
            end
        end
    end

    self.activeReminderData.abilities = {}
    ResetTTSState(self.activeReminderData)
    self.activeReminderData.popupSessionID = 0
    self.activeReminderData.reminderExpireTime = 0
end

-- REMINDER POPUP ANIMATION. db.animationType is the style (nil / "" /
-- "fade" = fade, "none", or any RC.Motion style), db.fadeInTime and
-- db.fadeTime the entrance and exit lengths, db.reminderMotion.show /
-- .hide the rest (easing, delay, dir, distance, loop; hide.style = an exit
-- style of its own). The defaults are the popup's old linear fade
-- exactly. A custom reminder's own choice (its abilityOverrides entry)
-- wins for a popup that holds it, both ways.
function RC:GetReminderMotion(how, abilities)
    local db = self.db or {}
    local M = RC.Motion
    local out = (how == "out")
    local own
    local list = abilities or (self.activeReminderData and self.activeReminderData.abilities) or {}
    for _, ab in ipairs(list) do
        local ao = type(ab) == "string" and ab:find("^custom_") and db.abilityOverrides and db.abilityOverrides[ab]
        if type(ao) == "table" and ao.animationType ~= nil then own = ao.animationType break end
        -- the Chronoboon page's own style (Chronoboon Reminder > Animation)
        if ab == "boon" and type(db.boonReminder) == "table" and db.boonReminder.animationType ~= nil then
            own = db.boonReminder.animationType break
        end
    end
    local rm = type(db.reminderMotion) == "table" and db.reminderMotion or {}
    local extra = rm[out and "hide" or "show"]
    extra = type(extra) == "table" and extra or {}
    local style = db.animationType
    if own ~= nil then
        style = own
    elseif out and extra.style ~= nil then
        style = extra.style
    end
    return {
        style    = M and M.StyleFromLegacy(style) or "fade",
        duration = out and (db.fadeTime or 2) or (db.fadeInTime or 0.5),
        easing   = extra.easing or "linear",
        delay    = extra.delay,
        dir      = extra.dir,
        distance = extra.distance,
        loop     = extra.loop,
    }
end

-- Stops whatever the popup is playing and puts it back at rest.
function RC:StopReminderAnimation()
    if self.reminderFrame and RC.Motion then RC.Motion.Stop(self.reminderFrame) end
end

function RC:StartReminderFadeOut()
    local frame = self.reminderFrame
    if not frame or not frame:IsShown() then
        return
    end

    local spec = self:GetReminderMotion("out")
    self:DebugPrint("Starting fade out over " .. tostring(spec.duration) .. " seconds", "reminder")

    RC.Motion.Hide(frame, spec, function()
        if frame.abilityIcons then
            for _, icon in pairs(frame.abilityIcons) do
                if icon.pulseTimer then
                    icon.pulseTimer:Cancel()
                    icon.pulseTimer = nil
                end
                if icon.animationTimer then
                    icon.animationTimer:Cancel()
                    icon.animationTimer = nil
                end
            end
        end

        ResetTTSState(self.activeReminderData)
        self.activeReminderData.popupSessionID = 0

        self:DebugPrint("Fade out complete - TTS state reset, popup session ended", "reminder")
    end)
end

-- UNIT_HEALTH(target) can fire many times per second during a fight;
-- coalesce into a single UpdateTargetInfo call per 0.1s window instead
-- of recomputing on every tick.
function RC:ScheduleTargetInfoUpdate()
    if RC.Profiler and RC.Profiler.CountHit then
        RC.Profiler:CountHit("Event:UNIT_HEALTH(target)")
    end
    if self._targetInfoUpdateScheduled then return end
    self._targetInfoUpdateScheduled = true
    C_Timer.After(0.1, function()
        self._targetInfoUpdateScheduled = false
        self:UpdateTargetInfo()
    end)
end

C_Timer.After(1.0, function()
    if RC.Profiler and RC.Profiler.WrapHandler and RC.UpdateTargetInfo
       and not RC._targetInfoProfiled then
        RC._targetInfoProfiled = true
        RC.UpdateTargetInfo = RC.Profiler:WrapHandler("TargetInfo", RC.UpdateTargetInfo)
    end
end)

function RC:UpdateTargetInfo()
    if not self.triggerSystem then
        self:InitializeSystems()
    end

    local currentTime = GetTime()
    local target = self.triggerSystem.currentTarget

    if not self.targetUpdateCache then
        self.targetUpdateCache = {
            lastUpdate = 0,
            cachedData = nil,
            cacheValidFor = 0.1
        }
    end

    -- Reuses the last computed target snapshot for 0.1s so bursts of
    -- UNIT_HEALTH/OnEvent calls in the same frame don't redo the work.
    if currentTime - self.targetUpdateCache.lastUpdate < self.targetUpdateCache.cacheValidFor then
        if self.targetUpdateCache.cachedData then
            for key, value in pairs(self.targetUpdateCache.cachedData) do
                target[key] = value
            end
            return
        end
    end

    if UnitExists("target") and UnitCanAttack("player", "target") then
        local newGUID = Readycheck.SafeGUID("target")
        local newName = Readycheck.SafeName("target")

        if target.guid ~= newGUID then
            if target.guid then
                self:DebugPrint("Target changed from " .. (target.name or "unknown") .. " to " .. (newName or "unknown"), "target")

                if self.activeReminderData.dismissalTimer then
                    self.activeReminderData.dismissalTimer:Cancel()
                    self.activeReminderData.dismissalTimer = nil
                end

                if self.reminderFrame then
                    self:StopReminderAnimation()

                    self.reminderFrame:Hide()
                    self.reminderFrame:SetAlpha(0)

                    self:DebugPrint("Cleared reminder frame state for new target", "reminder")
                end

                ResetTTSState(self.activeReminderData)
                self.activeReminderData.popupSessionID = 0
                self.activeReminderData.abilities = {}

                local oldGUID = target.guid
                C_Timer.After(0.5, function()
                    if self.triggerSystem.currentTarget.guid ~= oldGUID then
                        if self.ResetSpellCastTriggers then
                            self:ResetSpellCastTriggers(oldGUID)
                        end
                    end
                end)
            else
                self:DebugPrint("First target acquired: " .. (newName or "unknown"), "target")
            end

            target.guid = newGUID
            target.name = newName
            target.healthHistory = {}
        end

        -- 0 / 0 while WoW Forever hides the health in combat
        local curHP, maxHP = self:SafeHealth("target")
        local targetData = {
            guid = newGUID,
            name = newName,
            currentHP = curHP or 0,
            maxHP = maxHP or 0
        }

        targetData.currentHPPercent = (targetData.maxHP > 0) and (targetData.currentHP / targetData.maxHP) * 100 or 0

        self.targetUpdateCache.cachedData = targetData
        self.targetUpdateCache.lastUpdate = currentTime

        target.currentHP = targetData.currentHP
        target.maxHP = targetData.maxHP
        target.currentHPPercent = targetData.currentHPPercent

        if currentTime - (target.lastHistoryUpdate or 0) > 0.3 then
            table.insert(target.healthHistory, {
                time = currentTime,
                hp = target.currentHP,
                percent = target.currentHPPercent
            })
            target.lastHistoryUpdate = currentTime

            if #target.healthHistory > 8 then
                table.remove(target.healthHistory, 1)
            end
        end

        if self.CalculateTimeToKill then
            self:CalculateTimeToKill()
        end
    else
        self.targetUpdateCache.cachedData = nil
        target.name = nil
        target.guid = nil
        target.currentHP = 0
        target.maxHP = 0
        target.currentHPPercent = 100
        target.estimatedTimeToKill = 999
        target.healthHistory = {}
    end
end

function RC:UpdateCombatState()
    local nowInCombat = UnitAffectingCombat("player")

    if nowInCombat and not self.inCombat then
        self.inCombat = true
        if self.combatState then
            self.combatState.inCombat = true
            self.combatState.combatStartTime = GetTime()
        end

        self:DebugPrint("Combat started - preserving ability tracking", "combat")

    elseif not nowInCombat and self.inCombat then
        self.inCombat = false
        if self.combatState then
            self.combatState.inCombat = false
        end

        -- 3s delay before clearing ability-usage tracking: a quick
        -- in-and-out of combat (e.g. a stray tick) shouldn't wipe cooldown
        -- history that reminders still need to reason about.
        C_Timer.After(3, function()
            if not self.inCombat then
                if self.combatState then
                    self.combatState.usedAbilities = {}
                end

                if self.spellCastTriggers then
                    self.spellCastTriggers.usedAbilities = {}
                end

                self:DebugPrint("Combat tracking cleared after 3s delay", "combat")
            end
        end)

        self:HideAllReminders()
        ResetTTSState(self.activeReminderData)
        self.activeReminderData.popupSessionID = 0

        self:DebugPrint("Combat ended - reminders cleared", "combat")
    end
end

function RC:HandlePostCombatGearSwap()
    if not self.gearSwapState or not self.gearSwapState.postCombatSet
    or self.gearSwapState.postCombatSet == "" then
        return
    end

    local bossName = self.gearSwapState.lastBossTarget
    local bossAlive
    if self.IsEngagedBossAlive then
        bossAlive = self:IsEngagedBossAlive()
    else
        bossAlive = bossName
            and UnitExists("target")
            and not UnitIsDead("target")
            and Readycheck.SafeName("target") == bossName
    end
    -- PLAYER_REGEN_ENABLED can fire mid-encounter (e.g. player briefly
    -- leaves combat via a self-buff/root break) while the boss is still
    -- up - swapping back to a non-combat set here would be wrong, so the
    -- swap is only allowed once the boss is confirmed dead or gone.
    if bossAlive then
        self:DebugPrint("HandlePostCombatGearSwap: aborted - boss still alive (self-buff exit)", "gear")
        self.gearSwapState.engagedInCombat = nil
        return
    end

    if self.activeEncounterName then
        self:DebugPrint("HandlePostCombatGearSwap: deferred - encounter still active: " .. self.activeEncounterName, "gear")
        return
    end

    local setName = self.gearSwapState.postCombatSet
    self.gearSwapState.postCombatSet = nil
    self.gearSwapState.engagedInCombat = nil

    if self.AttemptPostCombatGearSwap then
        self:AttemptPostCombatGearSwap(setName, 1)
    else
        self:EquipGearSet(setName)
    end
    self:DebugPrint("Combat ended: post-combat gear swap to " .. setName, "gear")
end

function RC:SaveReminderFramePosition(x, y)
    if self.reminderFrame then
        RC.Position.SetFrame(self.reminderFrame, x, y)
    else
        self.db.anchorPoint = "CENTER"
        self.db.xOffset = x
        self.db.yOffset = y
        self.db.reminderPosCentred = true
        self:SaveConfigurationToProfile()
    end
end

-- Updates the settings page boxes and the drag-test frame after a move.
function RC:SyncReminderPositionUI()
    local x, y = self.db.xOffset or 0, self.db.yOffset or 200
    if self.positionEditBoxes then
        local eb = self.positionEditBoxes
        if eb.xEditBox and eb.xEditBox:IsVisible() then eb.xEditBox:SetText(tostring(math.floor(x))) end
        if eb.yEditBox and eb.yEditBox:IsVisible() then eb.yEditBox:SetText(tostring(math.floor(y))) end
    end
    if self.dragTestFrame and self.dragTestFrame:IsShown() then
        RC.Position.Apply(self.dragTestFrame, x, y, "CENTER")
    end
end

function RC:CreateReminderFrame()
    if self.reminderFrame then return end

    local frame = CreateFrame("Frame", "ReadycheckFrame", UIParent)
    frame:SetSize(600, 140)
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(100)

    RC.Position.Bind(frame, function() return RC.db end, {
        point = "CENTER", pointKey = "anchorPoint", default = { x = 0, y = 200 },
        markKey = "reminderPosCentred",
    })
    RC.Position.RestoreFrame(frame)

    local clickThrough = self.db.clickThrough or false
    local dragEnabled = self.db.dragEnabled or false
    frame:EnableMouse(not clickThrough or dragEnabled)
    RC.Position.MakeMovable(frame,
        function() return self.db.dragEnabled end,
        function() self:SyncReminderPositionUI() end)

    frame:Hide()
    self.reminderFrame = frame
end
