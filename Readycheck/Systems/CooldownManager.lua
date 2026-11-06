------------------------------------------------------------------------
-- Readycheck - Cooldown Manager
-- Tracks ability/item/potion cooldowns for the reminder engine: spell
-- cooldowns via GetSpellCooldown, item cooldowns via a hand-rolled
-- equipped-slot + bag scan (Classic Era has no retail GetItemCooldown).
-- Potions share one 120s "category" cooldown keyed by potionSpellIds/
-- potionItemIds, which Core populates onto RC before this file reads them.
------------------------------------------------------------------------
-- Taint-safe API locals (fallbacks on RC.Compat, built in Core;
-- never write _G - a written Blizzard global taints its readers)
local RCC = _G.Readycheck
local GetSpellCooldown = GetSpellCooldown or (RCC and RCC.Compat and RCC.Compat.GetSpellCooldown)
local function InitializeCooldownManager()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeCooldownManager)
        return
    end

    if not RC.cooldownTracker then
        RC.cooldownTracker = {
            activeCooldowns = {},
            lastPotionUsed = 0,
            abilityLastUsed = {}
        }
    end

    if not RC.cooldownTracker.potionSpellIds or not next(RC.cooldownTracker.potionSpellIds) then
        if RC.potionSpellIds then
            RC.cooldownTracker.potionSpellIds = RC.potionSpellIds
        end
    end

    if not RC.cooldownTracker.potionItemIds or not next(RC.cooldownTracker.potionItemIds) then
        if RC.potionItemIds then
            RC.cooldownTracker.potionItemIds = RC.potionItemIds
        end
    end

    -- Classic Era has no retail GetItemCooldown: equipped slots 1-19 first,
    -- then the bags.
    function RC:GetItemCooldown(itemId)
        if not itemId then return 0, 0 end

        for slot = 1, 19 do
            local equippedId = GetInventoryItemID("player", slot)
            if equippedId == itemId then
                local start, duration = GetInventoryItemCooldown("player", slot)
                if start and start > 0 then
                    return start, duration
                end
            end
        end

        -- then the first one carried, found through the shared bag index
        local start, duration = RC.Bags:Cooldown(itemId)
        if start > 0 then return start, duration end
        return 0, 0
    end

    function RC:IsCombatPotion(spellID)
        return spellID ~= nil
           and self.cooldownTracker
           and self.cooldownTracker.potionSpellIds
           and self.cooldownTracker.potionSpellIds[spellID] ~= nil
    end

    function RC:RecordAbilityUsage(spellID)
        local currentTime = GetTime()

        local potionAbilityKey = self.cooldownTracker.potionSpellIds[spellID]
        if potionAbilityKey then
            self.cooldownTracker.abilityLastUsed[potionAbilityKey] = {
                timestamp = currentTime,
                cooldownEnd = currentTime + 120
            }

            self.cooldownTracker.lastPotionUsed = currentTime
            self:UpdateAllPotionCooldowns(currentTime)

            self:DebugPrint("Tracked potion usage: " .. potionAbilityKey .. " (Spell ID: " .. spellID .. ")", "cooldown")
            return
        end

        if self.abilityData then
            for abilityKey, abilityData in pairs(self.abilityData) do
                -- Some abilities have one spell ID per class (Berserking:
                -- 20554 mana users, 26296 warriors, 26297 rogues) - match
                -- any ID in the spellIds list, not just the primary one.
                local matches = abilityData.spellId == spellID
                if not matches and abilityData.spellIds then
                    for _, id in ipairs(abilityData.spellIds) do
                        if id == spellID then matches = true; break end
                    end
                end
                if matches then
                    self.cooldownTracker.abilityLastUsed[abilityKey] = {
                        timestamp = currentTime,
                        cooldownEnd = currentTime + (abilityData.cooldown or 0)
                    }

                    self:DebugPrint("Tracked " .. abilityData.name .. " usage (Spell ID: " .. spellID .. ")", "cooldown")

                    if spellID == 12328 then
                        self:DebugPrint("SUCCESS: Death Wish tracked with corrected Anniversary spell ID 12328!", "cooldown")
                    end
                    break
                end
            end
        end
    end

    function RC:UpdateAllPotionCooldowns(usageTime)
        if self.abilityData then
            for abilityKey, abilityData in pairs(self.abilityData) do
                if abilityData.category == "potion" then
                    self.cooldownTracker.abilityLastUsed[abilityKey] = {
                        timestamp = usageTime,
                        cooldownEnd = usageTime + 120
                    }
                end
            end
        end
    end

    function RC:IsAbilityOnCooldown(abilityKey)
        if not self.abilityData then return false end

        local abilityData = self.abilityData[abilityKey]
        if not abilityData then return false end

        local usage = self.cooldownTracker.abilityLastUsed[abilityKey]
        if usage then
            return GetTime() < usage.cooldownEnd
        end

        if abilityData.spellId then
            -- Use the class's own spell ID when the ability has variants
            -- (a warrior doesn't know 20554 Berserking, only 26296).
            local sid = abilityData.spellId
            if abilityData.spellIds and IsPlayerSpell then
                for _, id in ipairs(abilityData.spellIds) do
                    if IsPlayerSpell(id) then sid = id; break end
                end
            end
            local start, duration = GetSpellCooldown(sid)
            -- duration > 1.5 excludes global-cooldown blips, which also
            -- report a start/duration through this API but aren't a real cooldown.
            if start and duration and start > 0 and duration > 1.5 then
                return true
            end
        end

        if abilityData.itemId then
            local start, duration = self:GetItemCooldown(abilityData.itemId)
            if start and duration and start > 0 and duration > 1.5 then
                return true
            end

            if self.TimerConflictGroup then
                local conflictGroup = self:TimerConflictGroup(abilityData.itemId)
                if conflictGroup then
                    local hasConflict, conflictTime, conflictItemId = self:HasConflictGroupBuff(conflictGroup)
                    if hasConflict and conflictItemId ~= abilityData.itemId then
                        return true
                    end
                end
            end
        end

        return false
    end

    function RC:GetAbilityCooldownRemaining(abilityKey)
        if not abilityKey then return 0 end

        local currentTime = GetTime()

        -- Slots 13/14 are the two trinket slots; these two keys bypass
        -- abilityData entirely since trinkets are matched by slot, not spellId/itemId.
        if abilityKey == "trinket1" then
            local start, duration = GetInventoryItemCooldown("player", 13)
            if start and start > 0 and duration and duration > 1.5 then
                return math.max(0, (start + duration) - currentTime)
            end
            return 0
        elseif abilityKey == "trinket2" then
            local start, duration = GetInventoryItemCooldown("player", 14)
            if start and start > 0 and duration and duration > 1.5 then
                return math.max(0, (start + duration) - currentTime)
            end
            return 0
        end

        if type(abilityKey) == "string" and abilityKey:find("Potion") then
            local potionItemId
            if self.cooldownTracker and self.cooldownTracker.potionItemIds then
                for itemId, potionName in pairs(self.cooldownTracker.potionItemIds) do
                    if potionName == abilityKey then
                        potionItemId = itemId
                        break
                    end
                end
            end
            if potionItemId then
                local start, duration = self:GetItemCooldown(potionItemId)
                if start and start > 0 and duration and duration > 1.5 then
                    return math.max(0, (start + duration) - currentTime)
                end
            end
            return 0
        end

        local numericItemId = tonumber(abilityKey)
        if numericItemId and self.utilityItems and self.utilityItems[numericItemId] then
            local start, duration = self:GetItemCooldown(numericItemId)
            if start and start > 0 and duration and duration > 1.5 then
                return math.max(0, (start + duration) - currentTime)
            end
            return 0
        end

        if not self.abilityData then return 0 end
        local abilityData = self.abilityData[abilityKey]
        if not abilityData then return 0 end

        local usage = self.cooldownTracker.abilityLastUsed[abilityKey]
        if usage then
            return math.max(0, usage.cooldownEnd - currentTime)
        end

        if abilityData.spellId then
            local start, duration = GetSpellCooldown(abilityData.spellId)
            if start and duration and start > 0 and duration > 1.5 then
                return math.max(0, (start + duration) - currentTime)
            end
        end

        if abilityData.itemId then
            local start, duration = self:GetItemCooldown(abilityData.itemId)
            if start and duration and start > 0 and duration > 1.5 then
                return math.max(0, (start + duration) - currentTime)
            end

            if self.TimerConflictGroup then
                local conflictGroup = self:TimerConflictGroup(abilityData.itemId)
                if conflictGroup then
                    local hasConflict, conflictTime, conflictItemId = self:HasConflictGroupBuff(conflictGroup)
                    if hasConflict and conflictItemId ~= abilityData.itemId then
                        return math.max(0, conflictTime)
                    end
                end
            end
        end

        return 0
    end

    function RC:ScanCurrentCooldowns()
        if not self.abilityData then return end

        local currentTime = GetTime()

        for abilityKey, abilityData in pairs(self.abilityData) do
            if abilityData.spellId then
                local start, duration = GetSpellCooldown(abilityData.spellId)
                if start and duration and start > 0 and duration > 1.5 then
                    self.cooldownTracker.abilityLastUsed[abilityKey] = {
                        timestamp = start,
                        cooldownEnd = start + duration
                    }

                    if abilityData.category == "potion" and duration >= 120 then
                        self.cooldownTracker.lastPotionUsed = start
                        self:UpdateAllPotionCooldowns(start)
                    end

                    if abilityData.spellId == 12328 then
                        self:DebugPrint("Detected Death Wish cooldown with corrected spell ID 12328", "cooldown")
                    end
                end
            end

            if abilityData.itemId then
                local start, duration = self:GetItemCooldown(abilityData.itemId)
                if start and duration and start > 0 and duration > 1.5 then
                    self.cooldownTracker.abilityLastUsed[abilityKey] = {
                        timestamp = start,
                        cooldownEnd = start + duration
                    }
                end
            end
        end

        local count = 0
        for _ in pairs(self.cooldownTracker.abilityLastUsed) do
            count = count + 1
        end
        self:DebugPrint("Scanned " .. count .. " active cooldowns with corrected spell IDs", "cooldown")
    end

    RC:DebugPrint("Enhanced cooldown manager loaded with CORRECTED Classic Era spell ID tracking", "cooldown")
    RC:DebugPrint("CORRECTED: Death Wish now tracked with spell ID 12328", "cooldown")
    RC:DebugPrint("Tracking " .. (RC.cooldownTracker.potionSpellIds and 9 or 0) .. " potion spell IDs including Free Action Potion", "cooldown")
end

local function InitializeCooldowns()
    C_Timer.After(3, function()
        local RC = _G.Readycheck
        if RC and RC.ScanCurrentCooldowns then
            RC:ScanCurrentCooldowns()
        end
    end)
end

local cooldownFrame = CreateFrame("Frame")
cooldownFrame:RegisterEvent("PLAYER_LOGIN")
cooldownFrame:SetScript("OnEvent", InitializeCooldowns)

InitializeCooldownManager()
