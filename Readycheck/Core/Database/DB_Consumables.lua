------------------------------------------------------------------------
-- Readycheck - Consumables & Raid Item Data
-- Potion registry, the full raid consumables catalog (flasks, elixirs,
-- food, jujus, weapon coatings, etc.), and the derived lookup tables the
-- consumables checker/helper/potions bar build from them at load.
--
-- raidConsumables[categoryKey] = { name, items = { [itemId] = {
--   name, recommended, buffId (nil if no trackable buff), nonWarrior,
--   selfCastOnly, materials, ahSearchName, minAbsorb/maxAbsorb, school,
--   slot/baseItemId (MH/OH weaponstone variants), enchantId,
--   aggregateItemIds/displayName (merge several itemIds into one row),
--   class ("ROGUE", or a list: only that class sees the row),
--   noBar (checker only, never a consumables-bar button) } } }
-- customItemCategories lists the same category keys plus "custom" for
-- user-added items (see DB_CustomItems.lua).
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)
local RC = _G.Readycheck
if not RC then
    print("ERROR: Readycheck not initialized before Database files")
    return
end
    function RC:CacheUtilityItemInfo()
        if not self.utilityItems then return end

        local totalItems = 0
        local cachedItems = 0

        for itemId, itemData in pairs(self.utilityItems) do
            totalItems = totalItems + 1

            local itemName, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(itemId)

            if itemName and itemTexture then
                itemData.name = itemName
                itemData.icon = itemTexture
                cachedItems = cachedItems + 1
            else
                -- GetItemInfo can miss on first call if the item isn't in the
                -- client's local cache yet; retry once after the server reply.
                C_Timer.After(0.5, function()
                    local retryName, _, _, _, _, _, _, _, _, retryTexture = GetItemInfo(itemId)
                    if retryName and retryTexture then
                        itemData.name = retryName
                        itemData.icon = retryTexture
                    end
                end)
            end
        end

        self:DebugPrint("Cached " .. cachedItems .. "/" .. totalItems .. " utility items on initial load", "items")
    end

    RC.potionData = {
        potions = {
            mightyRagePotion = {
                name = "Mighty Rage Potion",
                itemId = 13442,
                spellId = 17528,
                icon = "Interface\\Icons\\INV_Potion_41"
            },
            stoneshieldPotion = {
                name = "Stoneshield Potion",
                itemId = 13455,
                spellId = 17540,
                icon = "Interface\\Icons\\INV_Potion_69"
            },
            limitedInvulnerabilityPotion = {
                name = "Limited Invulnerability Potion",
                itemId = 3387,
                spellId = 3169,
                icon = "Interface\\Icons\\INV_Potion_62"
            },
            freeActionPotion = {
                name = "Free Action Potion",
                itemId = 5634,
                spellId = 6615,
                icon = "Interface\\Icons\\INV_Potion_04"
            },
            greatRagePotion = {
                name = "Great Rage Potion",
                itemId = 5631,
                spellId = 5405,
                icon = "Interface\\Icons\\INV_Potion_24"
            },
            greaterArcaneProtectionPotion = {
                name = "Greater Arcane Protection Potion",
                itemId = 13461,
                spellId = 17549,
                icon = "Interface\\Icons\\INV_Potion_83"
            },
            greaterFireProtectionPotion = {
                name = "Greater Fire Protection Potion",
                itemId = 13457,
                spellId = 17543,
                icon = "Interface\\Icons\\INV_Potion_24"
            },
            greaterFrostProtectionPotion = {
                name = "Greater Frost Protection Potion",
                itemId = 13456,
                spellId = 17544,
                icon = "Interface\\Icons\\INV_Potion_20"
            },
            greaterNatureProtectionPotion = {
                name = "Greater Nature Protection Potion",
                itemId = 13458,
                spellId = 17546,
                icon = "Interface\\Icons\\INV_Potion_22"
            },
            greaterShadowProtectionPotion = {
                name = "Greater Shadow Protection Potion",
                itemId = 13459,
                spellId = 17548,
                icon = "Interface\\Icons\\INV_Potion_23"
            },
            frozenRune = {
                name = "Frozen Rune",
                itemId = 22682,
                spellId = 29432,
                icon = "Interface\\Icons\\Spell_Frost_FrozenCore"
            },
            filledFestiveMug = {
                name = "Filled Festive Mug",
                noPotionCd = true,
                itemId = 21171,
                spellId = 25851,
                icon = "Interface\\Icons\\INV_Drink_Milk_01"
            }
        },

        displayOrder = {
            "mightyRagePotion",
            "stoneshieldPotion",
            "limitedInvulnerabilityPotion",
            "freeActionPotion",
            "greaterArcaneProtectionPotion",
            "greaterFireProtectionPotion",
            "greaterFrostProtectionPotion",
            "greaterNatureProtectionPotion",
            "greaterShadowProtectionPotion",
            "frozenRune",
            "filledFestiveMug"
        }
    }

    RC.potionItemIds = {}
    RC.potionSpellIds = {}
    RC.availablePotions = {}
    RC.potionIcons = {}
    RC.potionDisplayOrder = RC.potionData.displayOrder

    for key, data in pairs(RC.potionData.potions) do
        RC.potionItemIds[data.itemId] = key
        RC.potionSpellIds[data.spellId] = key
        RC.availablePotions[key] = data.name
        RC.potionIcons[key] = data.icon
    end

    RC.raidConsumables = {

        flasks = {
            name = "Flasks",
            items = {
                [13510] = {name = "Flask of the Titans", recommended = 1, buffId = 17626},
                [13506] = {name = "Flask of Petrification", recommended = 1, buffId = 17624},
                [13512] = {name = "Flask of Supreme Power", recommended = 1, buffId = 17628, nonWarrior = true},
                [13511] = {name = "Flask of Distilled Wisdom", recommended = 1, buffId = 17627, nonWarrior = true},
                [13513] = {name = "Flask of Chromatic Resistance", recommended = 1, buffId = 17629, nonWarrior = true}
            }
        },
        elixirs = {
            name = "Battle Elixirs",
            items = {
                [3825] = {name = "Elixir of Fortitude", recommended = 5, buffId = 3593},
                [13452] = {name = "Elixir of the Mongoose", recommended = 5, buffId = 17538},
                [13454] = {name = "Greater Arcane Elixir", recommended = 5, buffId = 17539},
                [20004] = {name = "Major Troll's Blood Potion", recommended = 5, buffId = 24361},
                [13445] = {name = "Elixir of Superior Defense", recommended = 5, buffId = 11348},
                [21546] = {name = "Elixir of Greater Firepower", recommended = 5, buffId = 26276},
                [9206] = {name = "Elixir of Giants", recommended = 5, buffId = 11405},
                [3386] = {name = "Elixir of Poison Resistance", recommended = 10, buffId = 26677},
                [17708] = {name = "Elixir of Frost Power", recommended = 5, buffId = 21920, nonWarrior = true},
                [6373] = {name = "Elixir of Firepower", recommended = 5, buffId = 7844, nonWarrior = true},
                [20007] = {name = "Mageblood Potion", recommended = 5, buffId = 24363, nonWarrior = true},
                [9264] = {name = "Elixir of Shadow Power", recommended = 5, buffId = 11474, nonWarrior = true}
            }
        },
        potions = {
            name = "Combat Potions",
            items = {
                [13442] = {name = "Mighty Rage Potion", recommended = 15, buffId = 17528},
                [13446] = {name = "Major Healing Potion", recommended = 5, buffId = nil},
                [13455] = {name = "Greater Stoneshield Potion", recommended = 5, buffId = 17540, minAbsorb = 1750, maxAbsorb = 2900},
                [3387] = {name = "Limited Invulnerability Potion", recommended = 5, buffId = 3169},
                [5634] = {name = "Free Action Potion", recommended = 10, buffId = 6615},
                [9030] = {name = "Restorative Potion", recommended = 5, buffId = nil},
                [2459] = {name = "Swiftness Potion", recommended = 5, buffId = 2379},
                [13444] = {name = "Major Mana Potion", recommended = 20, buffId = 17531}
            }
        },
        protectionPotions = {
            name = "Protection Potions",
            items = {
                [13457] = {name = "Greater Fire Protection Potion", recommended = 5, buffId = 17543, school = 4, minAbsorb = 1950, maxAbsorb = 3250},
                [13456] = {name = "Greater Frost Protection Potion", recommended = 5, buffId = 17544, school = 16, minAbsorb = 1950, maxAbsorb = 3250},
                [13458] = {name = "Greater Nature Protection Potion", recommended = 5, buffId = 17546, school = 8, minAbsorb = 1950, maxAbsorb = 3250},
                [13459] = {name = "Greater Shadow Protection Potion", recommended = 5, buffId = 17548, school = 32, minAbsorb = 1950, maxAbsorb = 3250},
                [13461] = {name = "Greater Arcane Protection Potion", recommended = 5, buffId = 17549, school = 64, minAbsorb = 1950, maxAbsorb = 3250},
                [22682] = {name = "Frozen Rune", recommended = 5, buffId = 29432, school = 4, minAbsorb = 1500, maxAbsorb = 2500}
            }
        },
        food = {
            name = "Food",
            items = {
                [13810] = {name = "Blessed Sunfruit", recommended = 20, buffId = 18125},
                [20452] = {name = "Smoked Desert Dumplings", recommended = 20, buffId = 24799},
                [21023] = {name = "Dirge's Kickin' Chimaerok Chops", recommended = 5, buffId = 25661},
                [12217] = {name = "Dragonbreath Chili", recommended = 20, buffId = 15852},
                [23326] = {name = "Midsummer Sausage", recommended = 10, buffId = 29333},
                [23211] = {name = "Toasted Smorc", recommended = 10, buffId = 29334},
                [13931] = {name = "Nightfin Soup", recommended = 20, buffId = 18194, nonWarrior = true}
            }
        },
        drinks = {
            name = "Drinks & Desserts",
            items = {
                [21151] = {name = "Rumsey Rum Black Label", recommended = 10, buffId = 25804},
                [18269] = {name = "Gordok Green Grog", recommended = 10, buffId = 22789},
                [21171] = {name = "Filled Festive Mug", recommended = 1, buffId = 25851},
                [23327] = {name = "Fire-toasted Bun", recommended = 1, buffId = 29332},
                [22236] = {name = "Buttermilk Delight", recommended = 1, buffId = 27720},
                [22237] = {name = "Dark Desire", recommended = 1, buffId = 27723},
                [22238] = {name = "Very Berry Cream", recommended = 1, buffId = 27721},
                [22239] = {name = "Sweet Surprise", recommended = 1, buffId = 27722}
            }
        },
        buffs = {
            name = "Jujus & Buffs",
            items = {
                [12460] = {name = "Juju Might", ahSearchName = "Frostmaul E'ko", recommended = 20, buffId = 16329, selfCastOnly = true,
                    materials = {{name = "Frostmaul E'ko", qty = 1, itemId = 12241}}},
                [12451] = {name = "Juju Power", ahSearchName = "Winterfall E'ko", recommended = 20, buffId = 16323, selfCastOnly = true,
                    materials = {{name = "Winterfall E'ko", qty = 1, itemId = 12236}}},
                [12457] = {name = "Juju Chill", ahSearchName = "Chillwind E'ko", recommended = 20, buffId = 16325, selfCastOnly = true,
                    materials = {{name = "Chillwind E'ko", qty = 1, itemId = 12238}}},
                [12455] = {name = "Juju Ember", ahSearchName = "Shardtooth E'ko", recommended = 20, buffId = 16326, selfCastOnly = true,
                    materials = {{name = "Shardtooth E'ko", qty = 1, itemId = 12240}}},
                [12458] = {name = "Juju Guile", ahSearchName = "Wildkin E'ko", recommended = 20, buffId = 16327, selfCastOnly = true,
                    materials = {{name = "Wildkin E'ko", qty = 1, itemId = 12242}}},
                [19183] = {name = "Hourglass Sand", recommended = 4, buffId = 23736},
                [20081] = {name = "Swiftness of Zanza", recommended = 1, buffId = 24383,
                    materials = {{name = "Zandalar Honor Token", qty = 1, itemId = 19858, ahSearchName = "Bijou"}}},
                [20079] = {name = "Spirit of Zanza", recommended = 1, buffId = 24382,
                    materials = {{name = "Zandalar Honor Token", qty = 1, itemId = 19858, ahSearchName = "Bijou"}}},
                [20080] = {name = "Sheen of Zanza", recommended = 1, buffId = 24417,
                    materials = {{name = "Zandalar Honor Token", qty = 1, itemId = 19858, ahSearchName = "Bijou"}}},
                [8410] = {name = "R.O.I.D.S.", recommended = 1, buffId = 10667,
                    materials = {{name = "Snickerfang Jowl", qty = 3, itemId = 8391}, {name = "Blasted Boar Lung", qty = 2, itemId = 8392}, {name = "Scorpok Pincer", qty = 1, itemId = 8393}}},
                [8412] = {name = "Ground Scorpok Assay", recommended = 1, buffId = 10669,
                    materials = {{name = "Scorpok Pincer", qty = 3, itemId = 8393}, {name = "Vulture Gizzard", qty = 2, itemId = 8396}, {name = "Blasted Boar Lung", qty = 1, itemId = 8392}}},
                [226365] = {name = "Darnassus Gift Collection", recommended = 1, buffId = nil, faction = "Alliance",
                    materials = {{name = "Box of Woodcrafts", qty = 1, itemId = 226367}, {name = "Darnassus Pledge Collection", qty = 1, itemId = 226368}, {name = "Stack of Cards", qty = 1, itemId = 226369}}},
                [226370] = {name = "Orgrimmar Gift Collection", recommended = 1, buffId = nil, faction = "Horde",
                    materials = {{name = "Box of Fresh Pies", qty = 1, itemId = 226371}, {name = "Orgrimmar Pledge Collection", qty = 1, itemId = 226372}, {name = "Package of Cards", qty = 1, itemId = 226373}}},
                [5206] = {name = "Bogling Root", recommended = 6, buffId = 5665},
                [9088] = {name = "Gift of Arthas", recommended = 5, buffId = 11371},
                [12820] = {name = "Winterfall Firewater", recommended = 10, buffId = 17038},
                [23196] = {name = "Greater Mark of the Dawn", recommended = 3, buffId = 30090},
                [1322] = {name = "Fisherliver Oil", recommended = 10, buffId = 7396},
                [5951] = {name = "Moist Towelette", recommended = 10, buffId = 7108},
                [8423] = {name = "Cerebral Cortex Compound", recommended = 1, buffId = 10692, nonWarrior = true},
                [12662] = {name = "Demonic Rune", recommended = 20, buffId = nil},
                [20520] = {name = "Dark Rune", recommended = 20, buffId = nil}
            }
        },
        utilities = {
            name = "Utilities & Tools",
            items = {
                [8956] = {name = "Oil of Immolation", recommended = 10, buffId = 11350},
                [18262] = {name = "Elemental Sharpening Stone", recommended = 20, buffId = 22756},
                [23122] = {name = "Consecrated Sharpening Stone", recommended = 20, buffId = 28891},
                [12404] = {name = "Dense Sharpening Stone", recommended = 20, buffId = 16138},
                [182621] = {name = "Elemental Sharpening Stone (MH)", slot = "mainhand", baseItemId = 18262, recommended = 20, buffId = 22756},
                [182622] = {name = "Elemental Sharpening Stone (OH)", slot = "offhand", baseItemId = 18262, recommended = 20, buffId = 22756},
                [231221] = {name = "Consecrated Sharpening Stone (MH)", slot = "mainhand", baseItemId = 23122, recommended = 20, buffId = 28891},
                [231222] = {name = "Consecrated Sharpening Stone (OH)", slot = "offhand", baseItemId = 23122, recommended = 20, buffId = 28891},
                [3829] = {name = "Frost Oil", recommended = 2, buffId = 3595},
                [20749] = {name = "Brilliant Wizard Oil", recommended = 10, buffId = 25122, enchantId = 2628},
                [20748] = {name = "Brilliant Mana Oil", recommended = 10, buffId = 25123, enchantId = 2629},
                [10646] = {name = "Goblin Sapper Charge", recommended = 10, buffId = nil},
                [18641] = {name = "Dense Dynamite", recommended = 20, buffId = nil},
                [13180] = {name = "Stratholme Holy Water", recommended = 20, buffId = nil},
                [14530] = {name = "Heavy Runecloth Bandage", recommended = 20, buffId = nil},
                [11951] = {name = "Whipper Root Tuber", recommended = 20, buffId = nil},
                [2091] = {name = "Magic Dust", recommended = 5, buffId = nil},
                [17202] = {name = "Snowball", recommended = 5, buffId = nil},
                [16023] = {name = "Masterwork Target Dummy", recommended = 10, buffId = nil, aggregateItemIds = {16023, 4392, 22261}, displayName = "Target Dummy"},
                [23123] = {name = "Blessed Wizard Oil", recommended = 10, buffId = 28898, enchantId = 2685, nonWarrior = true}
            }
        },
        reagents = {
            name = "Class Reagents",
            items = {
                [21177] = {name = "Symbol of Kings", recommended = 200, buffId = nil, nonWarrior = true, class = "PALADIN"},
                [17033] = {name = "Symbol of Divinity", recommended = 5, buffId = nil, nonWarrior = true, class = "PALADIN"},
                [17029] = {name = "Sacred Candle", recommended = 100, buffId = nil, nonWarrior = true, class = "PRIEST"},
                [17026] = {name = "Wild Thornroot", recommended = 40, buffId = nil, nonWarrior = true, class = "DRUID"},
                [17020] = {name = "Arcane Powder", recommended = 40, buffId = nil, nonWarrior = true, class = "MAGE"},
                [17031] = {name = "Rune of Teleportation", recommended = 10, buffId = nil, nonWarrior = true, class = "MAGE"},
                [17032] = {name = "Rune of Portals", recommended = 10, buffId = nil, nonWarrior = true, class = "MAGE"},
                [17030] = {name = "Ankh", recommended = 10, buffId = nil, nonWarrior = true, class = "SHAMAN"},
                [6265] = {name = "Soul Shard", recommended = 10, buffId = nil, nonWarrior = true, class = "WARLOCK"},
                [5140] = {name = "Flash Powder", recommended = 20, buffId = nil, nonWarrior = true, class = "ROGUE"},
                [5530] = {name = "Blinding Powder", recommended = 10, buffId = nil, nonWarrior = true, class = "ROGUE"}
            }
        },
        -- Usable class items: rogue poisons (every rank counts toward one
        -- row; the key is the top rank), Thistle Tea, mage mana gems,
        -- hunter ammo. Poisons also go on weapons through the weapons bar.
        classItems = {
            name = "Class Consumables",
            items = {
                [8928] = {name = "Instant Poison", recommended = 20, buffId = nil, nonWarrior = true, class = "ROGUE",
                    aggregateItemIds = {8928, 8927, 8926, 6950, 6949, 6947}, displayName = "Instant Poison"},
                [20844] = {name = "Deadly Poison", recommended = 20, buffId = nil, nonWarrior = true, class = "ROGUE",
                    aggregateItemIds = {20844, 8985, 8984, 2893, 2892}, displayName = "Deadly Poison"},
                [10922] = {name = "Wound Poison", recommended = 10, buffId = nil, nonWarrior = true, class = "ROGUE",
                    aggregateItemIds = {10922, 10921, 10920, 10918}, displayName = "Wound Poison"},
                [3776] = {name = "Crippling Poison", recommended = 10, buffId = nil, nonWarrior = true, class = "ROGUE",
                    aggregateItemIds = {3776, 3775}, displayName = "Crippling Poison"},
                [9186] = {name = "Mind-numbing Poison", recommended = 5, buffId = nil, nonWarrior = true, class = "ROGUE",
                    aggregateItemIds = {9186, 6951, 5237}, displayName = "Mind-numbing Poison"},
                [7676] = {name = "Thistle Tea", recommended = 5, buffId = nil, nonWarrior = true, class = "ROGUE"},
                [8008] = {name = "Mana Gem", recommended = 1, buffId = nil, nonWarrior = true, class = "MAGE",
                    aggregateItemIds = {8008, 8007, 5513, 5514}, displayName = "Mana Gem"},
                -- arrows and bullets as one row: a hunter carries one kind
                [18042] = {name = "Ammo", recommended = 1000, buffId = nil, nonWarrior = true, class = "HUNTER",
                    aggregateItemIds = {18042, 11285, 15997, 11284}, displayName = "Ammo", noBar = true}
            }
        },
        chronoboon = {
            name = "Chronoboon Displacers",
            items = {
                [184938] = {name = "Supercharged Chronoboon Displacer", recommended = 1, buffId = nil},
                [184937] = {name = "Chronoboon Displacer", recommended = 5, buffId = nil}
            }
        },
        special = {
            name = "Special Items",
            items = {
                [15138] = {name = "Onyxia Scale Cloak", recommended = 1, buffId = nil},
                [21218] = {name = "Blue Qiraji Resonating Crystal", recommended = 1, buffId = nil},
                [21324] = {name = "Yellow Qiraji Resonating Crystal", recommended = 1, buffId = nil},
                [21323] = {name = "Green Qiraji Resonating Crystal", recommended = 1, buffId = nil},
                [21321] = {name = "Red Qiraji Resonating Crystal", recommended = 1, buffId = nil},
                [22754] = {name = "Eternal Quintessence", recommended = 1, buffId = nil},
                [2820] = {name = "Nifty Stopwatch", recommended = 1, buffId = nil},
                [810] = {name = "Hammer of the Northern Wind", recommended = 1, buffId = nil},
                [10761] = {name = "Coldrage Dagger", recommended = 1, buffId = nil},
                [7189] = {name = "Goblin Rocket Boots", recommended = 1, buffId = nil},
                [4984] = {name = "Skull of Impending Doom", recommended = 1, buffId = nil}
            }
        }
    }

    -- CLASS ROWS (2026-10-21). A row with a class belongs to that class:
    -- it is dropped from this character's catalogue at load, so the
    -- checker, the bars and the reminders never offer a rogue's poisons
    -- to a priest. Every such id stays listed in RC.classItemIds, which
    -- profile cleanup counts as valid so a profile shared between classes
    -- keeps its settings for them. If the class is not known yet at load
    -- (it normally is), nothing is dropped.
    do
        local _, myClass
        if UnitClass then _, myClass = UnitClass("player") end
        RC.classItemIds = {}
        for _, category in pairs(RC.raidConsumables) do
            for itemId, itemData in pairs(category.items or {}) do
                local c = itemData.class
                if c then
                    RC.classItemIds[itemId] = true
                    if myClass then
                        local mine = false
                        if type(c) == "table" then
                            for _, x in ipairs(c) do if x == myClass then mine = true end end
                        else
                            mine = (c == myClass)
                        end
                        if not mine then category.items[itemId] = nil end
                    end
                end
            end
        end
    end

    RC.bothBarsItems = {
        [13810] = true,
        [20452] = true,
        [21023] = true,
        [12217] = true,
        [23326] = true,
        [23211] = true,
        [13931] = true,
        [14530] = true,
        [21171] = true,
        [13506] = true,
    }

    RC.potionBarItems = {
        [13442] = true,
        [13446] = true,
        [13455] = true,
        [3387] = true,
        [13506] = true,
        [5634] = true,
        [9030]  = true,
        [2459] = true,
        [13457] = true,
        [13456] = true,
        [13458] = true,
        [13459] = true,
        [13461] = true,
        [22682] = true,
        [1322] = true,
        [5951] = true,
        [13444] = true,
        [12662] = true,
        [20520] = true,
        [21171] = true,
        [13810] = true,
        [20452] = true,
        [21023] = true,
        [12217] = true,
        [23326] = true,
        [23211] = true,
        [13931] = true,
        [14530] = true
    }

    -- Keyed by WoW resistance school bitmask (2=Holy, 4=Fire, 8=Nature,
    -- 16=Frost, 32=Shadow, 64=Arcane), matching the "school" field above.
    RC.schoolColors = {
        [2] = {r = 1, g = 0.9, b = 0.5},
        [4] = {r = 1, g = 0.5, b = 0},
        [8] = {r = 0.3, g = 1, b = 0.3},
        [16] = {r = 0.5, g = 1, b = 1},
        [32] = {r = 0.5, g = 0.5, b = 1},
        [64] = {r = 1, g = 0.5, b = 1}
    }

    -- Keyed by the enchant id GetWeaponEnchantInfo() reports for a temporary
    -- weapon buff, so weapon-bar code can name/classify whatever is applied.
    RC.temporaryWeaponEnchants = {
        -- Every id below checked against the enchant id list
        -- (warcraft.wiki.gg EnchantId/Enchant_IDs). The stones were shifted
        -- one rank or more (Dense read as Coarse, Solid as Rough) and four
        -- were Burning Crusade or unrelated ids.
        [2506] = {itemId = 18262, name = "Elemental Sharpening Stone", isStone = true},
        [2684] = {itemId = 23122, name = "Consecrated Sharpening Stone", isStone = true},
        [40]   = {itemId = 2862, name = "Rough Sharpening Stone", isStone = true},
        [13]   = {itemId = 2863, name = "Coarse Sharpening Stone", isStone = true},
        [14]   = {itemId = 2871, name = "Heavy Sharpening Stone", isStone = true},
        [483]  = {itemId = 7964, name = "Solid Sharpening Stone", isStone = true},
        [1643] = {itemId = 12404, name = "Dense Sharpening Stone", isStone = true},
        [19]   = {itemId = 3239, name = "Rough Weightstone", isStone = true},
        [20]   = {itemId = 3240, name = "Coarse Weightstone", isStone = true},
        [21]   = {itemId = 3241, name = "Heavy Weightstone", isStone = true},
        [484]  = {itemId = 7965, name = "Solid Weightstone", isStone = true},
        [1703] = {itemId = 12643, name = "Dense Weightstone", isStone = true},
        [2628] = {itemId = 20749, name = "Brilliant Wizard Oil", isOil = true},
        [2627] = {itemId = 20750, name = "Wizard Oil", isOil = true},
        [2626] = {itemId = 20746, name = "Lesser Wizard Oil", isOil = true},
        [2623] = {itemId = 20744, name = "Minor Wizard Oil", isOil = true},
        [2685] = {itemId = 23123, name = "Blessed Wizard Oil", isOil = true},
        [2629] = {itemId = 20748, name = "Brilliant Mana Oil", isOil = true},
        [2625] = {itemId = 20747, name = "Lesser Mana Oil", isOil = true},
        [2624] = {itemId = 20745, name = "Minor Mana Oil", isOil = true},
        [26] = {itemId = 3829, name = "Frost Oil", isOil = true},
        [25] = {itemId = 3824, name = "Shadow Oil", isOil = true},
        -- (Oil of Immolation is drunk for a fire shield, not put on a
        -- weapon; 2504 is the permanent spell power enchant, listed below.
        -- Listing it here hid the oil from the consumables bar.)
        [263] = {itemId = 6529, name = "Shiny Bauble", isFishing = true},
        [264] = {itemId = 6530, name = "Nightcrawlers", isFishing = true},
        [265] = {itemId = 6532, name = "Bright Baubles", isFishing = true},
        [266] = {itemId = 6533, name = "Aquadynamic Fish Attractor", isFishing = true},
        -- rogue poisons, every rank
        [323] = {itemId = 6947, name = "Instant Poison", isPoison = true},
        [324] = {itemId = 6949, name = "Instant Poison II", isPoison = true},
        [325] = {itemId = 6950, name = "Instant Poison III", isPoison = true},
        [623] = {itemId = 8926, name = "Instant Poison IV", isPoison = true},
        [624] = {itemId = 8927, name = "Instant Poison V", isPoison = true},
        [625] = {itemId = 8928, name = "Instant Poison VI", isPoison = true},
        [7] = {itemId = 2892, name = "Deadly Poison", isPoison = true},
        [8] = {itemId = 2893, name = "Deadly Poison II", isPoison = true},
        [626] = {itemId = 8984, name = "Deadly Poison III", isPoison = true},
        [627] = {itemId = 8985, name = "Deadly Poison IV", isPoison = true},
        [2630] = {itemId = 20844, name = "Deadly Poison V", isPoison = true},
        [22] = {itemId = 3775, name = "Crippling Poison", isPoison = true},
        [603] = {itemId = 3776, name = "Crippling Poison II", isPoison = true},
        [35] = {itemId = 5237, name = "Mind-numbing Poison", isPoison = true},
        [23] = {itemId = 6951, name = "Mind-numbing Poison II", isPoison = true},
        [643] = {itemId = 9186, name = "Mind-numbing Poison III", isPoison = true},
        [703] = {itemId = 10918, name = "Wound Poison", isPoison = true},
        [704] = {itemId = 10920, name = "Wound Poison II", isPoison = true},
        [705] = {itemId = 10921, name = "Wound Poison III", isPoison = true},
        [706] = {itemId = 10922, name = "Wound Poison IV", isPoison = true},
    }

    RC.GEAR_SLOT_ORDER = {
        { invSlot = 1,  name = "Head",       bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Head"          },
        { invSlot = 2,  name = "Neck",       bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Neck"          },
        { invSlot = 3,  name = "Shoulder",   bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Shoulder"      },
        { invSlot = 15, name = "Back",       bgTex = "Interface\\Icons\\INV_Misc_Cape_19"                    },
        { invSlot = 5,  name = "Chest",      bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest"         },
        { invSlot = 9,  name = "Wrist",      bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Wrists"        },
        { invSlot = 10, name = "Hands",      bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Hands"         },
        { invSlot = 6,  name = "Waist",      bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Waist"         },
        { invSlot = 7,  name = "Legs",       bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Legs"          },
        { invSlot = 8,  name = "Feet",       bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Feet"          },
        { invSlot = 11, name = "Ring 1",     bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger"        },
        { invSlot = 12, name = "Ring 2",     bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger"        },
        { invSlot = 13, name = "Trinket 1",  bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket"       },
        { invSlot = 14, name = "Trinket 2",  bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket"       },
        { invSlot = 16, name = "Main Hand",  bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-MainHand"      },
        { invSlot = 17, name = "Off Hand",   bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-SecondaryHand" },
        { invSlot = 18, name = "Ranged",     bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Ranged"        },
    }

    RC.itemGCDTypes = {
        [13442] = "instant",
        [13446] = "instant",
        [13455] = "instant",
        [3387] = "instant",
        [5634] = "instant",
        [2459] = "instant",
        [13457] = "instant",
        [13456] = "instant",
        [13458] = "instant",
        [13459] = "instant",
        [13461] = "instant",
        [13444] = "instant",
        [12662] = "instant",
        [20520] = "instant",

        [13510] = "standard",
        [13506] = "standard",
        [13512] = "standard",
        [13511] = "standard",
        [13513] = "standard",
        [3825] = "standard",
        [13452] = "standard",
        [13454] = "standard",
        [20004] = "standard",
        [13445] = "standard",
        [21546] = "standard",
        [9206] = "standard",
        [12820] = "standard",
        [1322] = "standard",
        [5951] = "standard",
        [3386] = "standard",
        [17708] = "standard",
        [6373] = "standard",
        [20007] = "standard",
        [9264] = "standard",
        [8423] = "standard",

        [12460] = "instant",
        [12451] = "instant",
        [12457] = "instant",
        [12455] = "instant",
        [12458] = "instant",

        [19183] = "standard",
        [20081] = "standard",
        [20079] = "standard",
        [20080] = "standard",
        [8410] = "standard",
        [5206] = "standard",
        [9088] = "standard",

        [13810] = "food",
        [20452] = "food",
        [21023] = "food",
        [12217] = "food",
        [23326] = "food",
        [23211] = "food",
        [13931] = "food",

        [21151] = "instant",
        [18269] = "instant",
        [21171] = "instant",
        [23327] = "instant",
        [22236] = "instant",
        [22237] = "instant",
        [22238] = "instant",
        [22239] = "instant",

        [18262] = "weaponstone",
        [23122] = "weaponstone",
        [182621] = "weaponstone",
        [182622] = "weaponstone",
        [231221] = "weaponstone",
        [231222] = "weaponstone",
        [23123] = "weaponoil",

        [8956] = "standard",
        [3829] = "standard",
        [10646] = "standard",
        [18641] = "standard",
        [2091] = "standard",
        [16023] = "standard",
        [4392]  = "standard",
        [22261] = "standard"
    }

    RC.consumableConflictGroups = {
        zanza = {
            [20081] = true,
            [20079] = true,
            [20080] = true,
            [8410] = true,
            -- Blasted Lands buffs share the Zanza exclusivity family on Era:
            -- using any of them wipes the others.
            [8412] = true,
            [8423] = true
        },
        strengthElixir = {
            [12451] = true,
            [9206] = true
        },
        apStrength = {
            [12460] = true,
            [12820] = true
        },
        wellFed = {
            [13810] = true,
            [20452] = true,
            [21023] = true,
        },
        -- Fire-toasted Bun (Midsummer) and Dark Desire (Love is in the Air)
        -- are the same "+2% hit for 1 hour" buff; eating one overwrites
        -- the other.
        hitFood = {
            [23327] = true,
            [22237] = true
        },
        sharpeningStone = {
            [18262] = true,
            [23122] = true
        },
        wizardOil = {
            [20749] = true,
            [20748] = true,
            [23123] = true
        },
        engineeringExplosives = {
            [10646] = true,
            [18641] = true,
            [4390] = true,
            [4852] = true,
            [10577] = true,
            [15993] = true,
            [16040] = true,
            [13180] = true
        }
    }

    -- Same group keys as consumableConflictGroups above; item order here
    -- is the preference order used to pick which one to recommend/use
    -- when several members of a mutually-exclusive group are available.
    RC.conflictGroupPriority = {
        strengthElixir = {12451, 9206},
        apStrength = {12460, 12820},
        zanza = {20081, 20079, 20080, 8410, 8412, 8423},
        wellFed = {21023, 20452, 13810},
        hitFood = {23327, 22237},
        sharpeningStone = {18262, 23122},
        wizardOil = {20749, 23123, 20748},
        engineeringExplosives = {10646, 18641, 15993, 16040, 10577, 4390, 4852}
    }

    -- Built once at load from raidConsumables' buffId fields. GetSpellInfo
    -- can return nil for an uncached spell during load; those buffs are
    -- still tracked by id (_consumableSpellIdSet) but skip the name-based
    -- sets, so add-time ordering matters less than it looks like it should.
    RC._buffIdLookup = {}
    RC._consumableSpellIdSet = {}
    RC._consumableBuffNameSet = {}
    RC._buffNameById = {}
    do
        for _, category in pairs(RC.raidConsumables) do
            if category.items then
                for itemId, itemData in pairs(category.items) do
                    if itemData.buffId then
                        RC._buffIdLookup[itemId] = itemData.buffId
                        RC._consumableSpellIdSet[itemData.buffId] = true
                        if GetSpellInfo then
                            local bn = GetSpellInfo(itemData.buffId)
                            if bn then
                                RC._consumableBuffNameSet[bn:lower()] = true
                                RC._buffNameById[itemData.buffId] = bn:lower()
                            end
                        end
                    end
                end
            end
        end
    end

    function RC:GetConsumableBuffId(itemId)
        return self._buffIdLookup[itemId]
    end

    RC.customItemCategories = {
        {key = "flasks", name = "Flasks"},
        {key = "elixirs", name = "Battle Elixirs"},
        {key = "potions", name = "Combat Potions"},
        {key = "protectionPotions", name = "Protection Potions"},
        {key = "food", name = "Food"},
        {key = "drinks", name = "Drinks & Desserts"},
        {key = "buffs", name = "Jujus & Buffs"},
        {key = "utilities", name = "Utilities & Tools"},
        {key = "classItems", name = "Class Consumables"},
        {key = "chronoboon", name = "Chronoboon Displacers"},
        {key = "special", name = "Special Items"},
        {key = "custom", name = "Custom"},
    }

    -- Exposed via RC._dbs so DB_CustomItems.lua can call it once at its own
    -- load time; DB_Consumables.lua must load first for this hook to exist.
    local function _purgeMirrorTwins(self)
        local db = self.db
        if not db or db._customMirrorPurged then return end
        db._customMirrorPurged = true
        local helper = db.consumablesHelper and db.consumablesHelper.customItems
        local checker = db.consumablesChecker and db.consumablesChecker.customItems
        if not (helper and checker) then return end
        for id, d in pairs(checker) do
            local h = helper[id]
            if h and h.name == d.name and h.category == d.category then
                helper[id] = nil
            end
        end
    end
    if RC._dbs then RC._dbs._purgeMirrorTwins = _purgeMirrorTwins end

RC._dbs = RC._dbs or {}

------------------------------------------------------------------------
-- GAME VERSIONS (2026-11-06). Everything above is Classic Era's list. On
-- TBC and Forever that version's list (DB_ConsumablesTBC.lua /
-- DB_ConsumablesForever.lua, generated from the catalogues) replaces it
-- once, at load: Core_Runtime calls RC:ApplyConsumableFlavor() as soon as
-- the flavor is fixed and before the companions load. The tables are
-- refilled in place, so a file that kept a reference reads the new list.
-- On Classic Era nothing here changes anything.
--
-- Saved picks for items the version does not have stay saved (they come
-- back on Era); RC:ConsumableNotInFlavor(id) tells a page to leave them
-- out, and profile cleanup off Era counts every version's items as valid.
------------------------------------------------------------------------
-- the raw stones the weapon slot buttons apply, and the colour type of
-- each on the weapon button's border
RC.weaponStoneIds = { [18262] = true, [23122] = true, [12404] = true, [3829] = true }
RC.stoneColourType = { [18262] = "elemental", [23122] = "consecrated", [12404] = "dense", [3829] = "frost" }

-- A conflict group's members plus those of the groups linked to it (TBC:
-- a flask fills both elixir slots, so it clashes with battle and guardian
-- elixirs alike). With no links (Era, Forever) it is the group's own set.
function RC:ConflictMembers(groupName)
    local groups = self.consumableConflictGroups
    local own = groups and groups[groupName]
    local links = own and self.conflictGroupLinks and self.conflictGroupLinks[groupName]
    if not links then return own end
    local cache = self._conflictMembers
    if not cache then cache = {} self._conflictMembers = cache end
    local set = cache[groupName]
    if set then return set end
    set = {}
    for id in pairs(own) do set[id] = true end
    for _, g in ipairs(links) do
        for id in pairs(groups[g] or {}) do set[id] = true end
    end
    cache[groupName] = set
    return set
end

-- The catalogue's name for an item the client has no info for (a Forever
-- item on an Era client under the developer override); nil on Classic Era.
function RC:FlavorItemName(itemId)
    local t = self._flavorItemNames
    return (t and itemId and t[itemId]) or nil
end

-- true for an item of Era's list that this version does not have
function RC:ConsumableNotInFlavor(itemId)
    local t = self._consumablesNotInFlavor
    return (t and itemId and t[itemId]) and true or false
end

-- Off Classic Era: every item id any version's list knows, so profile
-- cleanup keeps the saved picks for all of them. On Era: none (cleanup
-- works exactly as it always has).
local NONE = {}
function RC:KnownConsumableItemIds()
    if not self._consumableFlavorApplied then return NONE end
    local set = self._knownConsumableIds
    if set then return set end
    set = {}
    for _, src in pairs(self._consumableFlavors or {}) do
        for _, id in ipairs(src.ids or {}) do set[id] = true end
    end
    for id in pairs(self._eraConsumableIds or {}) do set[id] = true end
    self._knownConsumableIds = set
    return set
end

do
    local function Refill(t, src)
        for k in pairs(t) do t[k] = nil end
        for k, v in pairs(src or {}) do t[k] = v end
    end
    local function Set(list)
        local s = {}
        for _, id in ipairs(list or {}) do s[id] = true end
        return s
    end

    -- Returns true when this version's list replaced Era's.
    function RC:ApplyConsumableFlavor()
        if self._consumableFlavorApplied ~= nil then return self._consumableFlavorApplied end
        local flavor = self.Flavor and self:Flavor() or "era"
        local src = flavor ~= "era" and self._consumableFlavors and self._consumableFlavors[flavor]
        if not src then
            self._consumableFlavorApplied = false
            return false
        end
        local data = src.Build()
        self._consumableFlavorApplied = true

        -- Era's ids (rows, rank aggregates, every class's rows)
        local eraIds = {}
        for _, category in pairs(self.raidConsumables) do
            for itemId, itemData in pairs(category.items or {}) do
                eraIds[itemId] = true
                for _, a in ipairs(itemData.aggregateItemIds or {}) do eraIds[a] = true end
            end
        end
        for itemId in pairs(self.classItemIds or {}) do eraIds[itemId] = true end
        self._eraConsumableIds = eraIds
        self._knownConsumableIds = nil

        Refill(self.raidConsumables, data.categories)
        local names = {}
        for _, category in pairs(self.raidConsumables) do
            for itemId, itemData in pairs(category.items) do names[itemId] = itemData.name end
        end
        self._flavorItemNames = names

        -- class rows, as at load: another class's rows leave the list
        -- (cleanup still counts them)
        local _, myClass
        if UnitClass then _, myClass = UnitClass("player") end
        for _, category in pairs(self.raidConsumables) do
            for itemId, itemData in pairs(category.items) do
                if itemData.class then
                    self.classItemIds[itemId] = true
                    if myClass and itemData.class ~= myClass then category.items[itemId] = nil end
                end
            end
        end

        Refill(self.itemGCDTypes, data.gcdTypes)
        local groups = {}
        for g, list in pairs(data.conflictGroups or {}) do groups[g] = Set(list) end
        Refill(self.consumableConflictGroups, groups)
        Refill(self.conflictGroupPriority, data.conflictPriority)
        self.conflictGroupLinks = data.conflictLinks
        self._conflictMembers = nil
        Refill(self.potionBarItems, Set(data.potionBar))
        Refill(self.bothBarsItems, Set(data.bothBars))
        Refill(self.temporaryWeaponEnchants, data.weaponEnchants)
        Refill(self.weaponStoneIds, Set(data.stoneIds))
        Refill(self.stoneColourType, data.stoneColour)
        self.weaponOilExtra = data.oilItems and Set(data.oilItems) or nil
        self.flavorStoneOfEnchant = data.stoneOfEnchant
        self.flavorStoneShort = data.stoneShort
        self.flavorStoneTypes = data.stoneTypes
        self.poisonsNoCharges = data.poisonsNoCharges or nil
        self.flavorEssentials = data.essentials
        self.flavorGroupLabels = data.groupLabels
        self.flavorConsumeRemind = data.consumeRemind

        -- the buff lookups, as at load; a row with no aura id (Forever
        -- food) carries -itemId and is matched by name (namedBuffs)
        local named = data.namedBuffs
        self._namedBuffMatch = named
        local lookups = { self._buffIdLookup, self._consumableSpellIdSet,
                          self._consumableBuffNameSet, self._buffNameById }
        for _, t in ipairs(lookups) do Refill(t, nil) end
        self._trackedBuffIdSet = nil
        local potionSpells = {}
        for categoryKey, category in pairs(self.raidConsumables) do
            for itemId, itemData in pairs(category.items) do
                local b = itemData.buffId
                if b then
                    self._buffIdLookup[itemId] = b
                    self._consumableSpellIdSet[b] = true
                    local bn = named and named[b] and named[b].name
                    if not bn and b > 0 and GetSpellInfo then
                        bn = GetSpellInfo(b)
                        bn = bn and bn:lower()
                    end
                    if bn then
                        self._consumableBuffNameSet[bn] = true
                        self._buffNameById[b] = bn
                    end
                end
                if categoryKey == "potions" or categoryKey == "protectionPotions" then
                    local s = itemData.useSpellId or (b and b > 0 and b)
                    if s then potionSpells[s] = true end
                end
            end
        end
        self.flavorPotionSpellIds = potionSpells

        -- spoken names for the new items (a name already known keeps its own)
        if self.ttsSpokenNames then
            for name, said in pairs(data.spoken or {}) do
                if self.ttsSpokenNames[name] == nil then self.ttsSpokenNames[name] = said end
            end
        end

        -- the custom item categories follow the version's list
        for i = #self.customItemCategories, 1, -1 do
            local c = self.customItemCategories[i]
            local mine = self.raidConsumables[c.key]
            if mine then
                c.name = mine.name
            elseif c.key ~= "custom" then
                table.remove(self.customItemCategories, i)
            end
        end

        -- new defaults for this version: the must-have alert's items
        local ess = self.defaults and self.defaults.consumablesChecker
            and self.defaults.consumablesChecker.essentials
        if ess and data.essentials then
            Refill(ess.items, nil)
            for i, id in ipairs(data.essentials) do ess.items[i] = id end
        end

        -- Era's items this version does not have
        local mine = Set(src.ids)
        local notIn = {}
        for itemId in pairs(eraIds) do
            if not mine[itemId] then notIn[itemId] = true end
        end
        self._consumablesNotInFlavor = notIn

        self:DebugPrint("Consumables: " .. tostring(flavor) .. " list in use", "items")
        return true
    end
end
