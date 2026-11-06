------------------------------------------------------------------------
-- Readycheck - Raid Mob Ability Configs
-- Per-boss/per-trash default ability trigger settings (deathwish,
-- potions, trinkets, gearswap-adjacent items) for every 40-man raid,
-- keyed by exact in-game mob name and read by the reminder engine via
-- RC.raidMobConfigs. RC.trashPacks below is a separate, UI-only grouping
-- of trash mobs for the settings list.
------------------------------------------------------------------------
local function InitializeCompleteRaidConfigs()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeCompleteRaidConfigs)
        return
    end

    RC.raidMobConfigs = {

        ["Molten Core"] = {
            ["Lucifron"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    laststand = { enabled = false, triggerType = "player_hp", playerHpValue = 40 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Magmadar"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    berserkerrage = { enabled = false, triggerType = "debuff_present", debuffName = "Panic" },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 75 },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Gehennas"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Garr"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 90 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 8 },
                    mightyRagePotion = { enabled = false, triggerType = "combat_start", combatTime = 5 },
                    trinket1 = { enabled = false, triggerType = "combat_start", combatTime = 10 },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Shazzrah"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Baron Geddon"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 75 },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Golemagg the Incinerator"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Sulfuron Harbinger"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Majordomo Executus"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 90 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 8 },
                    mightyRagePotion = { enabled = false, triggerType = "combat_start", combatTime = 5 },
                    trinket1 = { enabled = false, triggerType = "combat_start", combatTime = 10 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Ragnaros"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    recklessness = { enabled = false, triggerType = "hp_percent", hpValue = 50 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 75 },
                    trinket2 = { enabled = false, triggerType = "hp_percent", hpValue = 45 },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },

            ["Lava Surger"] = {
                abilities = {
                    bloodrage = { enabled = false, triggerType = "rage_threshold", rageValue = 20 },
                    stoneshieldPotion = { enabled = false, triggerType = "specific_mob", packSize = 3 }
                }
            },
            ["Firewalker"] = {
                abilities = {
                    bloodrage = { enabled = false, triggerType = "rage_threshold", rageValue = 20 }
                }
            },
            ["Core Hound Pack"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "specific_mob", packSize = 4 },
                    goblinSapperCharge = { enabled = false, triggerType = "specific_mob", packSize = 3 },
                    stoneshieldPotion = { enabled = false, triggerType = "specific_mob", packSize = 3 }
                }
            },
            ["Lava Elemental"] = {
                abilities = {
                    bloodrage = { enabled = false, triggerType = "rage_threshold", rageValue = 25 }
                }
            },
            ["Molten Giant"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 90 },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 }
                }
            },
            ["Ancient Core Hound"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 }
                }
            }
        },

        ["Blackwing Lair"] = {
            ["Razorgore the Untamed"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "combat_start", combatTime = 5 },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Vaelastrasz the Corrupt"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "combat_start", combatTime = 5 },
                    recklessness = { enabled = false, triggerType = "combat_start", combatTime = 8 },
                    mightyRagePotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    trinket1 = { enabled = false, triggerType = "combat_start", combatTime = 10 },
                    trinket2 = { enabled = false, triggerType = "combat_start", combatTime = 15 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Broodlord Lashlayer"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    berserkerrage = { enabled = false, triggerType = "debuff_present", debuffName = "Mortal Strike" },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Firemaw"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Ebonroc"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Flamegor"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Chromaggus"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 75 },
                    berserkerrage = { enabled = false, triggerType = "debuff_present", debuffName = "Time Lapse" },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Nefarian"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 75 },
                    recklessness = { enabled = false, triggerType = "hp_percent", hpValue = 40 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 70 },
                    trinket2 = { enabled = false, triggerType = "hp_percent", hpValue = 35 },
                    berserkerrage = { enabled = false, triggerType = "debuff_present", debuffName = "Fear" },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },

            ["Blackwing Legionnaire"] = {
                abilities = {
                    bloodrage = { enabled = false, triggerType = "rage_threshold", rageValue = 20 }
                }
            },
            ["Blackwing Mage"] = {
                abilities = {
                    berserkerrage = { enabled = false, triggerType = "debuff_present", debuffName = "Polymorph" }
                }
            },
            ["Dragonkin"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 }
                }
            },
            ["Death Talon Dragonspawn"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 }
                }
            }
        },

        ["Temple of Ahn'Qiraj"] = {
            ["The Prophet Skeram"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    berserkerrage = { enabled = false, triggerType = "debuff_present", debuffName = "Mind Control" },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Silithid Royalty"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Battleguard Sartura"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 8 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Fankriss the Unyielding"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Viscidus"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Princess Huhuran"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 8 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Emperor Vek'lor"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 8 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    trinket2 = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Emperor Vek'nilash"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 8 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    trinket2 = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Ouro"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 8 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Eye of C'Thun"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["C'Thun"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 8 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },

            ["Anubisath Sentinel"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 }
                }
            },
            ["Anubisath Defender"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 }
                }
            },
            ["Qiraji Slayer"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 }
                }
            }
        },

        ["Naxxramas"] = {
            ["Anub'Rekhan"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Grand Widow Faerlina"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    berserkerrage = { enabled = false, triggerType = "debuff_present", debuffName = "Silence" },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Maexxna"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },

                }
            },

            ["Noth the Plaguebringer"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Heigan the Unclean"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Loatheb"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "combat_start", combatTime = 5 },
                    recklessness = { enabled = false, triggerType = "combat_start", combatTime = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    trinket1 = { enabled = false, triggerType = "combat_start", combatTime = 8 },
                    trinket2 = { enabled = false, triggerType = "combat_start", combatTime = 15 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },

            ["Instructor Razuvious"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Gothik the Harvester"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Four Horsemen"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    trinket2 = { enabled = false, triggerType = "hp_percent", hpValue = 75 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Highlord Mograine"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    mightyRagePotion = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    trinket2 = { enabled = false, triggerType = "hp_percent", hpValue = 75 },
                }
            },
            ["Lady Blaumeux"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    mightyRagePotion = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    trinket2 = { enabled = false, triggerType = "hp_percent", hpValue = 75 },
                }
            },
            ["Thane Korth'azz"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    mightyRagePotion = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    trinket2 = { enabled = false, triggerType = "hp_percent", hpValue = 75 },
                }
            },
            ["Sir Zeliek"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    mightyRagePotion = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    trinket2 = { enabled = false, triggerType = "hp_percent", hpValue = 75 },
                }
            },

            ["Patchwerk"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "combat_start", combatTime = 5 },
                    recklessness = { enabled = false, triggerType = "combat_start", combatTime = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    trinket1 = { enabled = false, triggerType = "combat_start", combatTime = 8 },
                    trinket2 = { enabled = false, triggerType = "combat_start", combatTime = 15 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Grobbulus"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Gluth"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Thaddius"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "combat_start", combatTime = 5 },
                    recklessness = { enabled = false, triggerType = "combat_start", combatTime = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    trinket1 = { enabled = false, triggerType = "combat_start", combatTime = 8 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },

            ["Sapphiron"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 80 },
                    recklessness = { enabled = false, triggerType = "buff_remaining", buffTimeRemaining = 10 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 75 },
                    greaterFrostProtectionPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    battleChicken = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
                }
            },
            ["Kel'Thuzad"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 75 },
                    recklessness = { enabled = false, triggerType = "hp_percent", hpValue = 45 },
                    mightyRagePotion = { enabled = false, triggerType = "deathwish_time", buffTimeRemaining = 5 },
                    trinket1 = { enabled = false, triggerType = "hp_percent", hpValue = 70 },
                    trinket2 = { enabled = false, triggerType = "hp_percent", hpValue = 40 },
                    greaterShadowProtectionPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 },
                    battleChicken = { enabled = false, triggerType = "hp_percent", hpValue = 75, equipAfterDeath = false },
                    arcaniteDragonling = { enabled = false, triggerType = "hp_percent", hpValue = 75, equipAfterDeath = false },
                    -- Absolute HP threshold, not a percent - the only trigger
                    -- in this file scaled that way. Recheck against current
                    -- health pools before reusing this trigger elsewhere.
                    frostBlast = { enabled = false, triggerType = "player_hp_above", playerHpAboveValue = 8500 }
                }
            },

            ["Crypt Guard"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 }
                }
            },
            ["Death Knight Captain"] = {
                abilities = {
                    deathwish = { enabled = false, triggerType = "hp_percent", hpValue = 85 },
                    berserkerrage = { enabled = false, triggerType = "debuff_present", debuffName = "Death Coil" },
                    stoneshieldPotion = { enabled = false, triggerType = "combat_start", combatTime = 3 }
                }
            }
        }
    }

    -- UI-only trash grouping, keyed by short raid code (mc/bwl/aq40/naxx/zg/
    -- onyxia). These codes are duplicated in RaidProfilesSystem's boss-note
    -- rekey logic - keep both lists in sync if a raid is added or renamed.
    RC.trashPacks = {
        mc = {
            {key = "corehounds", label = RCL["Core Hound packs"], mobs = {
                "Core Hound", "Ancient Core Hound",
            }},
            {key = "flamewakers", label = RCL["Flamewaker packs"], mobs = {
                "Flamewaker", "Flamewaker Elite", "Flamewaker Priest",
            }},
            {key = "lava", label = RCL["Lava mobs (Surger/Reaver/Annihilator/Giant/Firelord)"], mobs = {
                "Lava Surger", "Lava Reaver", "Lava Annihilator",
                "Molten Giant", "Firelord",
            }},
        },
        bwl = {
            {key = "whelps", label = RCL["Whelp hallway (Razorgore)"], mobs = {
                "Chromatic Whelp", "Chromatic Dragonspawn",
            }},
            {key = "drakonoid", label = RCL["Drakonoid / Dragonspawn (post-Vael)"], mobs = {
                "Blackwing Spellbinder", "Blackwing Technician",
                "Blackwing Legionnaire", "Blackwing Mage",
                "Death Talon Wyrmguard", "Death Talon Flamescale",
                "Death Talon Seether", "Death Talon Hatcher",
            }},
            {key = "scarshield", label = RCL["Scarshield / end wing"], mobs = {
                "Scarshield Spellbinder", "Scarshield Legionnaire", "Scarshield Sentry",
                "Master Elemental Shaper Krixix", "Grethok the Controller",
            }},
        },
        aq40 = {
            {key = "anubisath", label = RCL["Anubisath (pre-bug-trio)"], mobs = {
                "Anubisath Sentinel", "Anubisath Defender",
                "Anubisath Guardian", "Anubisath Warrior",
                "Giant Anubisath Sentinel",
            }},
            {key = "qiraji", label = RCL["Qiraji / Ruins (post-Sartura)"], mobs = {
                "Qiraji Warrior", "Qiraji Swarmguard", "Qiraji Mindslayer",
                "Qiraji Battle Tank", "Qiraji Slayer",
                "Ruins Warder", "Ruins Sentinel",
            }},
        },
        naxx = {
            {key = "spider", label = RCL["Arachnid Quarter"], mobs = {
                "Naxxramas Acolyte", "Naxxramas Cultist",
                "Venom Stalker", "Tomb Horror", "Naxxramas Skeleton",
            }},
            {key = "plague", label = RCL["Plague Quarter"], mobs = {
                "Naxxramas Warrior", "Infectious Ghoul",
                "Plague Slime", "Stoneskin Gargoyle",
            }},
            {key = "military", label = RCL["Military Quarter (DK Wing)"], mobs = {
                "Deathknight Cavalier", "Patchwork Golem",
                "Soldier of the Frozen Wastes",
            }},
            {key = "frostwyrm", label = RCL["Frostwyrm Lair (Sapph/KT)"], mobs = {
                "Crypt Reaver", "Undead Horror", "Guardian of Icecrown",
            }},
        },
        zg = {
            {key = "gurubashi", label = RCL["Gurubashi humanoids"], mobs = {
                "Gurubashi Warrior", "Gurubashi Berserker",
                "Gurubashi Blood Drinker", "Gurubashi Headhunter",
            }},
            {key = "animals", label = RCL["Tigers / Prowlers / Hydras / Crocs"], mobs = {
                "Zulian Prowler", "Zulian Tiger",
                "Zulian Crocolisk", "Zulian Hydra",
            }},
            {key = "bats", label = RCL["Vile Bats / Axe Throwers"], mobs = {
                "Vile Bat", "Bloodseeker Bat", "Vilebranch Axe Thrower",
            }},
        },
        onyxia = {
            {key = "whelps", label = RCL["Onyxia whelp phase adds"], mobs = {
                "Onyxian Whelp", "Onyxian Warder", "Onyxian Lair Guard",
            }},
        },
    }

end

InitializeCompleteRaidConfigs()
