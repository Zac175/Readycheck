------------------------------------------------------------------------
-- Readycheck - Consumables Checker Ordering & Boss Ability Data
-- Owns the user-configurable item/category order for the consumables
-- checker, plus static boss cooldown-suggestion data and a few small
-- lookup tables used by the checker and trinket UI.
--
-- bossData[bossName] = { zone, phase, dpsAbilities, tankAbilities, notes }.
-- dpsAbilities/tankAbilities mix RC.abilityData keys (e.g. "deathwish")
-- with potion keys from RC.potionData (e.g. "mightyRagePotion") - two
-- different namespaces in the same list, resolved by whichever lookup
-- the caller tries first.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)
local RC = _G.Readycheck
if not RC then
    print("ERROR: Readycheck not initialized before Database files")
    return
end
    function RC:InitializeCheckerItemOrder()
        if not self.db.consumablesChecker then return end
        if not self.db.consumablesChecker.itemOrder then
            self.db.consumablesChecker.itemOrder = {}
        end
    end

    function RC:GetCheckerItemOrder(categoryKey, itemId)
        self:InitializeCheckerItemOrder()
        local orderTable = self.db.consumablesChecker.itemOrder[categoryKey]
        if orderTable and orderTable[itemId] then
            return orderTable[itemId]
        end
        return nil
    end

    function RC:GetSortedCheckerItems(categoryKey, items)
        if not items or #items == 0 then return items end

        self:InitializeCheckerItemOrder()

        table.sort(items, function(a, b)
            local orderA = self:GetCheckerItemOrder(categoryKey, a.id) or 1000
            local orderB = self:GetCheckerItemOrder(categoryKey, b.id) or 1000
            if orderA ~= orderB then
                return orderA < orderB
            end
            return (a.data.name or "") < (b.data.name or "")
        end)

        return items
    end

    function RC:InsertCheckerItemAt(categoryKey, itemId, position, allItemIds)
        self:InitializeCheckerItemOrder()

        if not self.db.consumablesChecker.itemOrder[categoryKey] then
            self.db.consumablesChecker.itemOrder[categoryKey] = {}
        end

        local orders = self.db.consumablesChecker.itemOrder[categoryKey]

        local newList = {}
        for _, id in ipairs(allItemIds) do
            if id ~= itemId then
                table.insert(newList, id)
            end
        end

        position = math.max(1, math.min(position, #newList + 1))
        table.insert(newList, position, itemId)

        for i, id in ipairs(newList) do
            orders[id] = i
        end

        self:SaveConfigurationToProfile()
    end

    function RC:InsertCheckerItemAfter(categoryKey, itemId, afterItemId, allItemIds)
        if allItemIds then
            local pos = 1
            for i, id in ipairs(allItemIds) do
                if id == afterItemId then
                    pos = i + 1
                    break
                end
            end
            self:InsertCheckerItemAt(categoryKey, itemId, pos, allItemIds)
        else
            self:InitializeCheckerItemOrder()
            if not self.db.consumablesChecker.itemOrder[categoryKey] then
                self.db.consumablesChecker.itemOrder[categoryKey] = {}
            end
            -- Fractional order slots the item between neighbors without
            -- renumbering the whole category; the loop below immediately
            -- collapses everything back to consecutive integers.
            local orders = self.db.consumablesChecker.itemOrder[categoryKey]
            local afterOrder = orders[afterItemId] or 1000
            orders[itemId] = afterOrder + 0.5
            local items = {}
            for id, order in pairs(orders) do
                table.insert(items, {id = id, order = order})
            end
            table.sort(items, function(a, b) return a.order < b.order end)
            for i, item in ipairs(items) do
                orders[item.id] = i
            end
            self:SaveConfigurationToProfile()
        end
    end

    function RC:InsertCheckerItemBefore(categoryKey, itemId, beforeItemId, allItemIds)
        if allItemIds then
            local pos = 1
            for i, id in ipairs(allItemIds) do
                if id == beforeItemId then
                    pos = i
                    break
                end
            end
            self:InsertCheckerItemAt(categoryKey, itemId, pos, allItemIds)
        else
            self:InitializeCheckerItemOrder()
            if not self.db.consumablesChecker.itemOrder[categoryKey] then
                self.db.consumablesChecker.itemOrder[categoryKey] = {}
            end
            local orders = self.db.consumablesChecker.itemOrder[categoryKey]
            local beforeOrder = orders[beforeItemId] or 1000
            orders[itemId] = beforeOrder - 0.5
            local items = {}
            for id, order in pairs(orders) do
                table.insert(items, {id = id, order = order})
            end
            table.sort(items, function(a, b) return a.order < b.order end)
            for i, item in ipairs(items) do
                orders[item.id] = i
            end
            self:SaveConfigurationToProfile()
        end
    end

    function RC:InitializeCheckerCategoryOverrides()
        if not self.db.consumablesChecker then return end
        if not self.db.consumablesChecker.categoryOverrides then
            self.db.consumablesChecker.categoryOverrides = {}
        end
    end

    function RC:GetItemEffectiveCategory(itemId, originalCategory)
        self:InitializeCheckerCategoryOverrides()
        local override = self.db.consumablesChecker.categoryOverrides[itemId]
        if override then
            return override
        end
        return originalCategory
    end

    function RC:SetItemCategoryOverride(itemId, newCategory)
        self:InitializeCheckerCategoryOverrides()
        self.db.consumablesChecker.categoryOverrides[itemId] = newCategory
        self:SaveConfigurationToProfile()
        self:DebugPrint("Item " .. itemId .. " moved to category: " .. newCategory, "items")
    end

    function RC:GetOverriddenItemsForCategory(targetCategory)
        self:InitializeCheckerCategoryOverrides()
        local items = {}

        if self.raidConsumables then
            for catKey, category in pairs(self.raidConsumables) do
                if category.items then
                    for itemId, itemData in pairs(category.items) do
                        local effectiveCat = self:GetItemEffectiveCategory(itemId, catKey)
                        if effectiveCat == targetCategory and catKey ~= targetCategory then
                            items[itemId] = {
                                data = itemData,
                                originalCategory = catKey
                            }
                        end
                    end
                end
            end
        end

        return items
    end

    RC.bossData = {
        ["Lucifron"] = {
            zone = "Molten Core",
            phase = "start",
            dpsAbilities = {"deathwish", "recklessness", "bloodrage", "mightyRagePotion"},
            tankAbilities = {"laststand", "stoneshieldPotion"},
            notes = "High damage output boss, use cooldowns early"
        },
        ["Magmadar"] = {
            zone = "Molten Core",
            phase = "start",
            dpsAbilities = {"deathwish", "berserkerrage", "mightyRagePotion"},
            tankAbilities = {"shieldwall", "laststand", "stoneshieldPotion"},
            notes = "Fear immune phases, berserker rage recommended"
        },
        ["Ragnaros"] = {
            zone = "Molten Core",
            phase = "start",
            dpsAbilities = {"recklessness", "deathwish", "mightyRagePotion"},
            tankAbilities = {"shieldwall", "laststand", "stoneshieldPotion"},
            notes = "Final boss, use all cooldowns"
        },

        ["Vaelastrasz the Corrupt"] = {
            zone = "Blackwing Lair",
            phase = "start",
            dpsAbilities = {"recklessness", "deathwish", "mightyRagePotion"},
            tankAbilities = {"shieldwall", "laststand", "stoneshieldPotion"},
            notes = "Infinite rage, use all cooldowns immediately"
        },
        ["Chromaggus"] = {
            zone = "Blackwing Lair",
            phase = "start",
            dpsAbilities = {"deathwish", "recklessness", "mightyRagePotion"},
            tankAbilities = {"shieldwall", "laststand", "stoneshieldPotion"},
            notes = "Long fight, use cooldowns on pull and when available"
        },

        ["Twin Emperors"] = {
            zone = "Temple of Ahn'Qiraj",
            phase = "start",
            dpsAbilities = {"deathwish", "mightyRagePotion"},
            tankAbilities = {"shieldwall", "laststand", "stoneshieldPotion"},
            notes = "Tank swap fight, coordinate cooldowns"
        },
        ["C'Thun"] = {
            zone = "Temple of Ahn'Qiraj",
            phase = "start",
            dpsAbilities = {"deathwish", "recklessness", "mightyRagePotion"},
            tankAbilities = {"shieldwall", "laststand", "stoneshieldPotion"},
            notes = "Two phase fight, save cooldowns for Phase 2"
        },

        ["Patchwerk"] = {
            zone = "Naxxramas",
            phase = "start",
            dpsAbilities = {"deathwish", "recklessness", "mightyRagePotion"},
            tankAbilities = {"shieldwall", "laststand", "stoneshieldPotion"},
            notes = "Pure DPS race, use all cooldowns"
        },
        ["Four Horsemen"] = {
            zone = "Naxxramas",
            phase = "start",
            dpsAbilities = {"deathwish", "mightyRagePotion"},
            tankAbilities = {"shieldwall", "laststand", "stoneshieldPotion"},
            notes = "Complex positioning fight, use cooldowns strategically"
        }
    }

    RC.fastWeapons = {
        [23456] = {name = "Grand Marshal's Swiftblade", speed = 1.80},
        [23014] = {name = "Iblis, Blade of the Fallen Seraph", speed = 1.60},
        [23577] = {name = "The Hungering Cold", speed = 1.50}
    }

    RC.classicDpsTrinkets = {
        [21670] = {name = "Badge of the Swarmguard", spellId = 26480},
        [20130] = {name = "Diamond Flask", spellId = 24427},
        [19849] = {name = "Jom Gabbar", spellId = 29602},
        [21180] = {name = "Earthstrike", spellId = 25891},
        [23041] = {name = "Slayer's Crest", spellId = 28777},
        [22954] = {name = "Kiss of the Spider", spellId = 28866}
    }

    -- Normalizes zone-name variants (e.g. player's current zone text) to the
    -- canonical raid name used as a key in DB_Raids.lua's RC.raidData.
    RC.raidZoneMap = {
        ["Molten Core"] = "Molten Core",
        ["Blackwing Lair"] = "Blackwing Lair",
        ["Temple of Ahn'Qiraj"] = "Temple of Ahn'Qiraj",
        ["Ahn'Qiraj"] = "Temple of Ahn'Qiraj",
        ["Ruins of Ahn'Qiraj"] = "Ruins of Ahn'Qiraj",
        ["Naxxramas"] = "Naxxramas"
    }
