------------------------------------------------------------------------
-- Readycheck - Raid & Static Game Data
-- Boss/encounter metadata, raid trash groupings, trinket/potion lookup
-- tables, item abbreviations, per-profile defaults, and UI color themes.
-- All read-only reference data assembled once at load.
--
-- encounterAddPhases[bossName] = { zone, adds, combatContinuous,
--   trackBossDeath, addPhasesBeforeBoss, aliases, aliasesAreEncounter,
--   notes, phases }
-- raidData[raidName] = { bosses = {...}, trashSections = { [group] = {mobNames} } }
-- defaults = shape of a fresh RC.db profile; PM_Profile.lua deep-copies this
--   into ReadycheckDB.characters[charKey]. Removing a key here means it also
--   needs removing from PM_Cleanup.lua's dead-field lists on existing saves.
-- defaultColors[category][key] = {r,g,b,a,label}, the user-overridable theme
--   (see RC:GetColor/SetColor); RC.colors near the end is a separate flat
--   palette used directly by code and not user-configurable.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)
local RC = _G.Readycheck
if not RC then
    print("ERROR: Readycheck not initialized before Database files")
    return
end
RC.encounterAddPhases = {
    ["Lucifron"] = {
        zone = "Molten Core",
        adds = {"Flamewaker Protector", "Flamewaker Healer"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Magmadar"] = {
        zone = "Molten Core",
        adds = {},
        combatContinuous = false,
        trackBossDeath = false
    },
    ["Gehennas"] = {
        zone = "Molten Core",
        adds = {"Flamewaker"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Garr"] = {
        zone = "Molten Core",
        adds = {"Firesworn"},
        combatContinuous = true,
        trackBossDeath = true,
        addPhasesBeforeBoss = true
    },
    ["Baron Geddon"] = {
        zone = "Molten Core",
        adds = {},
        combatContinuous = false,
        trackBossDeath = false
    },
    ["Shazzrah"] = {
        zone = "Molten Core",
        adds = {},
        combatContinuous = false,
        trackBossDeath = false
    },
    ["Sulfuron Harbinger"] = {
        zone = "Molten Core",
        adds = {"Flamewaker Priest"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Golemagg the Incinerator"] = {
        zone = "Molten Core",
        adds = {"Core Rager"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Majordomo Executus"] = {
        zone = "Molten Core",
        adds = {"Flamewaker Healer", "Flamewaker Elite"},
        combatContinuous = true,
        trackBossDeath = true,
        addPhasesBeforeBoss = true
    },
    ["Ragnaros"] = {
        zone = "Molten Core",
        adds = {"Son of Flame"},
        combatContinuous = true,
        trackBossDeath = true
    },

    ["Razorgore the Untamed"] = {
        zone = "Blackwing Lair",
        adds = {
            "Death Talon Dragonspawn", "Death Talon Dragonspawns",
            "Blackwing Mage",          "Blackwing Mages",
            "Blackwing Legionnaire",   "Blackwing Legionnaires",
        },
        combatContinuous = true,
        trackBossDeath = true,
        addPhasesBeforeBoss = true
    },
    ["Vaelastrasz the Corrupt"] = {
        zone = "Blackwing Lair",
        adds = {},
        combatContinuous = false,
        trackBossDeath = false
    },
    ["Broodlord Lashlayer"] = {
        zone = "Blackwing Lair",
        adds = {},
        combatContinuous = false,
        trackBossDeath = false
    },
    ["Firemaw"] = {
        zone = "Blackwing Lair",
        adds = {},
        combatContinuous = false,
        trackBossDeath = false
    },
    ["Ebonroc"] = {
        zone = "Blackwing Lair",
        adds = {},
        combatContinuous = false,
        trackBossDeath = false
    },
    ["Flamegor"] = {
        zone = "Blackwing Lair",
        adds = {},
        combatContinuous = false,
        trackBossDeath = false
    },
    ["Chromaggus"] = {
        zone = "Blackwing Lair",
        adds = {},
        combatContinuous = false,
        trackBossDeath = false
    },
    ["Nefarian"] = {
        zone = "Blackwing Lair",
        adds = {
            "Blue Drakonid",     "Blue Drakonids",
            "Red Drakonid",      "Red Drakonids",
            "Bronze Drakonid",   "Bronze Drakonids",
            "Green Drakonid",    "Green Drakonids",
            "Chromatic Drakonid","Chromatic Drakonids",
            "Bone Construct",
        },
        combatContinuous = true,
        trackBossDeath = true,
        addPhasesBeforeBoss = true
    },

    ["The Prophet Skeram"] = {
        zone = "Temple of Ahn'Qiraj",
        adds = {},
        combatContinuous = false,
        trackBossDeath = false
    },
    ["Silithid Royalty"] = {
        zone = "Temple of Ahn'Qiraj",
        aliases = {"Lord Kri", "Princess Yauj", "Vem"},
        aliasesAreEncounter = true,
        adds = {},
        combatContinuous = true,
        trackBossDeath = true,
        notes = "Triple boss encounter - Lord Kri, Princess Yauj, and Vem"
    },
    ["Battleguard Sartura"] = {
        zone = "Temple of Ahn'Qiraj",
        adds = {"Sartura's Royal Guard"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Fankriss the Unyielding"] = {
        zone = "Temple of Ahn'Qiraj",
        adds = {"Spawn of Fankriss"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Viscidus"] = {
        zone = "Temple of Ahn'Qiraj",
        adds = {"Glob of Viscidus"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Princess Huhuran"] = {
        zone = "Temple of Ahn'Qiraj",
        adds = {"Hive'Zara Sandstalker"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Twin Emperors"] = {
        zone = "Temple of Ahn'Qiraj",
        aliases = {"Emperor Vek'lor", "Emperor Vek'nilash"},
        aliasesAreEncounter = true,
        adds = {},
        combatContinuous = true,
        trackBossDeath = true,
        notes = "Dual boss encounter - Emperor Vek'lor and Emperor Vek'nilash"
    },
    ["Ouro"] = {
        zone = "Temple of Ahn'Qiraj",
        adds = {"Ouro Scarab"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["C'Thun"] = {
        zone = "Temple of Ahn'Qiraj",
        aliases = {"Eye of C'Thun"},
        adds = {"Eye Tentacle", "Claw Tentacle", "Giant Eye Tentacle", "Giant Claw Tentacle"},
        combatContinuous = true,
        trackBossDeath = true,
        phases = {
            [1] = {name = "Phase 1 (Eye)", key = "phase1"},
            [2] = {name = "Phase 2 (Body)", key = "phase2"}
        }
    },

    ["Anub'Rekhan"] = {
        zone = "Naxxramas",
        adds = {"Crypt Guard"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Grand Widow Faerlina"] = {
        zone = "Naxxramas",
        adds = {"Naxxramas Worshipper", "Naxxramas Follower"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Maexxna"] = {
        zone = "Naxxramas",
        adds = {"Spiderling"},
        combatContinuous = true,
        trackBossDeath = true
    },

    ["Noth the Plaguebringer"] = {
        zone = "Naxxramas",
        adds = {"Plagued Warrior", "Plagued Champion", "Plagued Guardian"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Heigan the Unclean"] = {
        zone = "Naxxramas",
        adds = {"Eye Stalk"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Loatheb"] = {
        zone = "Naxxramas",
        adds = {"Spore"},
        combatContinuous = true,
        trackBossDeath = true
    },

    ["Instructor Razuvious"] = {
        zone = "Naxxramas",
        adds = {"Death Knight Understudy"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Gothik the Harvester"] = {
        zone = "Naxxramas",
        adds = {"Unrelenting Trainee", "Unrelenting Deathknight", "Unrelenting Rider"},
        combatContinuous = true,
        trackBossDeath = true,
        addPhasesBeforeBoss = true
    },
    ["Four Horsemen"] = {
        zone = "Naxxramas",
        aliases = {"Lady Blaumeux", "Thane Korth'azz", "Highlord Mograine", "Sir Zeliek"},
        aliasesAreEncounter = true,
        adds = {},
        combatContinuous = true,
        trackBossDeath = true,
        notes = "Quad boss encounter - Lady Blaumeux, Thane Korth'azz, Highlord Mograine, Sir Zeliek"
    },

    ["Patchwerk"] = {
        zone = "Naxxramas",
        adds = {},
        combatContinuous = false,
        trackBossDeath = false
    },
    ["Grobbulus"] = {
        zone = "Naxxramas",
        adds = {"Fallout Slime"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Gluth"] = {
        zone = "Naxxramas",
        adds = {"Zombie Chow"},
        combatContinuous = true,
        trackBossDeath = true
    },
    ["Thaddius"] = {
        zone = "Naxxramas",
        aliases = {"Stalagg", "Feugen"},
        adds = {"Stalagg", "Feugen"},
        combatContinuous = true,
        trackBossDeath = true,
        addPhasesBeforeBoss = true,
        notes = "Must kill Feugen and Stalagg before Thaddius becomes active"
    },

    ["Sapphiron"] = {
        zone = "Naxxramas",
        adds = {},
        combatContinuous = false,
        trackBossDeath = false
    },
    ["Kel'Thuzad"] = {
        zone = "Naxxramas",
        adds = {"Soldier of the Frozen Wastes", "Unstoppable Abomination", "Soul Weaver"},
        combatContinuous = true,
        trackBossDeath = true,
        addPhasesBeforeBoss = true
    }
}
    RC.raidData = {
        ["Molten Core"] = {
            bosses = {"Lucifron", "Magmadar", "Gehennas", "Garr", "Baron Geddon", "Shazzrah", "Sulfuron Harbinger", "Golemagg the Incinerator", "Majordomo Executus", "Ragnaros"},
            trashSections = {
                ["Core Hounds"] = {
                    "Core Hound", "Ancient Core Hound"
                },
                ["Elementals"] = {
                    "Lava Annihilator", "Lava Elemental", "Lava Reaver", "Lava Surger"
                },
                ["Giants"] = {
                    "Molten Destroyer", "Molten Giant"
                },
                ["Flamewakers"] = {
                    "Flamewaker Healer", "Flamewaker Elite", "Flamewaker Priest", "Flamewaker Protector"
                },
                ["Other"] = {
                    "Firewalker", "Flame Imp", "Flameguard", "Firelord"
                }
            }
        },

        ["Blackwing Lair"] = {
            bosses = {"Razorgore the Untamed", "Vaelastrasz the Corrupt", "Broodlord Lashlayer", "Firemaw", "Ebonroc", "Flamegor", "Chromaggus", "Nefarian"},
            trashSections = {
                ["Blackwing"] = {
                    "Blackwing Legionnaire", "Blackwing Mage", "Blackwing Spellbinder", "Blackwing Taskmaster",
                    "Blackwing Technician", "Blackwing Warlock"
                },
                ["Death Talon"] = {
                    "Death Talon Captain", "Death Talon Dragonspawn", "Death Talon Flamescale",
                    "Death Talon Hatcher", "Death Talon Overseer", "Death Talon Seether",
                    "Death Talon Wyrmguard", "Death Talon Wyrmkin"
                },
                ["Suppression Room"] = {
                    "Corrupted Whelp"
                }
            }
        },

        ["Temple of Ahn'Qiraj"] = {
            bosses = {"The Prophet Skeram", "Silithid Royalty", "Battleguard Sartura", "Fankriss the Unyielding", "Viscidus", "Princess Huhuran", "Twin Emperors", "Ouro", "C'Thun"},
            trashSections = {
                ["Anubisath"] = {
                    "Anubisath Sentinel", "Anubisath Defender", "Anubisath Guardian", "Anubisath Warder"
                },
                ["Qiraji"] = {
                    "Qiraji Slayer", "Qiraji Champion", "Qiraji Warrior", "Qiraji Gladiator",
                    "Qiraji Mindslayer", "Qiraji Brainwasher", "Qiraji Lasher"
                },
                ["Obsidian"] = {
                    "Obsidian Destroyer", "Obsidian Nullifier", "Obsidian Eradicator"
                },
                ["Vekniss"] = {
                    "Vekniss Drone", "Vekniss Guardian", "Vekniss Soldier", "Vekniss Stinger",
                    "Vekniss Warrior", "Vekniss Wasp", "Vekniss Hatchling", "Vekniss Borer",
                    "Vekniss Hive Crawler"
                }
            }
        },

        ["Naxxramas"] = {
            bosses = {
                "Anub'Rekhan", "Grand Widow Faerlina", "Maexxna",
                "Noth the Plaguebringer", "Heigan the Unclean", "Loatheb",
                "Instructor Razuvious", "Gothik the Harvester", "Four Horsemen",
                "Patchwerk", "Grobbulus", "Gluth", "Thaddius",
                "Sapphiron", "Kel'Thuzad"
            },
            trashSections = {
                ["Spider Quarter"] = {
                    "Crypt Guard", "Crypt Reaver", "Crypt Crawler", "Venom Stalker", "Tomb Horror",
                    "Naxxramas Follower", "Necropolis Acolyte", "Naxxramas Cultist", "Naxxramas Worshipper",
                    "Necro Knight", "Necro Stalker", "Infectious Skitterer", "Dread Creeper", "Carrion Spinner",
                    "Spirit of Naxxramas", "Shade of Naxxramas", "Infectious Ghoul", "Plagued Gargoyle"
                },
                ["Plague Quarter"] = {
                    "Plagued Warrior", "Plagued Champion", "Plagued Guardian", "Plagued Ghoul",
                    "Plagued Bat", "Plagued Insect", "Plagued Maggot", "Frenzied Bat",
                    "Infectious Ghoul", "Stoneskin Gargoyle", "Plague Beast", "Plague Slime",
                    "Eye Stalk"
                },
                ["Military Quarter"] = {
                    "Deathknight", "Deathknight Captain", "Deathknight Cavalier", "Death Knight Understudy",
                    "Shade of Naxxramas", "Spirit of Naxxramas", "Unholy Staff", "Unholy Swords", "Unholy Axe",
                    "Spectral Deathknight", "Spectral Horseman", "Spectral Rider", "Spectral Trainee",
                    "Unrelenting Trainee", "Unrelenting Deathknight", "Unrelenting Rider",
                    "Risen Deathknight", "Skeletal Smith", "Skeletal Steed",
                    "Necro Knight", "Necro Stalker",
                    "Infectious Ghoul", "Plagued Gargoyle", "Necropolis Acolyte"
                },
                ["Construct Quarter"] = {
                    "Patchwork Golem", "Bile Retcher", "Sewage Slime", "Embalming Slime",
                    "Mad Scientist", "Surgical Assistant", "Living Monstrosity", "Stitched Spewer",
                    "Sludge Belcher"
                },
                ["Frostwyrm Lair"] = {
                    "Unstoppable Abomination", "Soul Weaver", "Soldier of the Frozen Wastes"
                }
            }
        }
    }

    -- self.fastWeapons is defined in DB_Checker.lua; requires that file to load first.
    function RC:IsFastWeapon(itemId)
        return self.fastWeapons[itemId] ~= nil
    end

    -- Reverse lookup: known-ability spellId -> RC.abilityData key. Lets combat
    -- log / aura scanning identify a tracked ability without walking abilityData.
    RC.spellIdMap = {
        [12328] = "deathwish",
        [1719] = "recklessness",
        [2687] = "bloodrage",
        [18499] = "berserkerrage",
        [12975] = "laststand",
        [871] = "shieldwall",
        [20572] = "bloodfury",
        [20554] = "berserking",
        [26296] = "berserking",
        [26297] = "berserking",
        [17528] = "mightyRagePotion",
        [5405] = "greatRagePotion",
        [17540] = "stoneshieldPotion",
        [3169] = "limitedInvulnerabilityPotion",
        [6615] = "freeActionPotion",
        [17543] = "greaterFireProtectionPotion",
        [17546] = "greaterNatureProtectionPotion",
        [17548] = "greaterShadowProtectionPotion",
        [17544] = "greaterFrostProtectionPotion",
        [23133] = "battleChicken",
    }

    RC.trinketSpellIds = {
        [26480] = true,
        [25891] = true,
        [29602] = true,
        [28777] = true,
        [28866] = true,
        [24427] = true,
        [24658] = true,
        [24571] = true
    }

    RC.potionBuffIds = {
        [17528] = true,
        [5405] = true,
        [17540] = true,
        [3169] = true,
        [6615] = true,
        [17543] = true,
        [17546] = true,
        [17548] = true,
        [17544] = true,
        [7396] = true,
        [7108] = true
    }

    RC.utilitySpellIds = {
        [13241] = 10646,
        [23063] = 18641,
        [17291] = 13180,
        [15700] = 11951,
        [11350] = 8956,
        [3595] = 3829,
        [2687] = 2091,
        [19805] = 16023,
        [4072]  = 4392,
        [27661] = 22261,
        [29432] = 22682
    }

    -- Trinket registry: trinketCooldowns/trinketBuffDurations/itemBuffSpellIds/
    -- trinketSwapPriority/onUseTrinkets/trinketBuffs all key by the same
    -- on-use trinket itemId. Adding a new trinket means updating all of them.
    RC.trinketCooldowns = {
        [21670] = 180,
        [20130] = 360,
        [23041] = 120,
        [19849] = 120,
        [22954] = 120,
        [21180] = 120,
        [23570] = 120,

        [23047] = 120,
        [23046] = 120,
        [23017] = 120,
        [19950] = 120,
        [19951] = 180,
        [19339] = 300,
        [19024] = 120,
        [19891] = 120,
        [11819] = 120,

        [10725] = 3600,
        [7189] = 300,
        [9452] = 300,
        [2820] = 1800,
        [16022] = 3600,
        [13120] = 300,
        [4984] = 300,
        [7391] = 3600,
    }

    RC.trinketBuffDurations = {
        [21670] = 30,
        [20130] = 60,
        [23041] = 20,
        [19849] = 20,
        [19950] = 20,
        [22954] = 15,
        [21180] = 20,
        [23570] = 15,

        [23047] = 30,
        [23046] = 20,
        [23017] = 20,
        -- Gri'lek's Charm of Might is an instant +30 rage, no aura at all,
        -- so it is deliberately absent from itemBuffSpellIds/trinketBuffs:
        -- its use spell (24571) shares the name "Blood Fury" with the orc
        -- racial, and the buff lookup in GM_Runtime matches by name.
        [19951] = 0,
        [19339] = 20,
        [19024] = 10,
        [19891] = 20,
        [11819] = 0,

        [19395] = 0,
        [23018] = 0,
        [12930] = 20,

        [10725] = 0,
        [7189] = 20,
        [9452] = 20,
        [2820] = 10,
        [16022] = 0,
        [13120] = 60,
        [4984] = 10,
        [7391] = 15,
    }

    RC.itemBuffSpellIds = {
        [7189] = 8892,
        [9452] = 8892,
        [7391] = 9175,

        [2820] = 14530,
        [4984] = 5024,

        [21670] = 26480,
        [20130] = 24427,
        [23041] = 28093,
        [19849] = 24658,
        [22954] = 28866,
        [21180] = 25891,
        [23570] = 30458,

        [23047] = 29346,
        [23046] = 29338,
        [23017] = 28780,
        [19950] = 24658,
        [19339] = 23723,
        [19024] = 23271,
        [12930] = 17593,
        [11819] = 15667,
    }

    RC.trinketSwapPriority = {
        [22954] = 95,
		[23041] = 95,
        [21670] = 90,
        [20130] = 85,
        [19849] = 80,
        [21180] = 75,
        [23570] = 70,

        [23047] = 85,
        [23046] = 85,
        [23017] = 80,
        [19950] = 80,
        [19951] = 55,
        [19339] = 70,
        [19024] = 70,
        [19891] = 70,
        [11819] = 55,

        [23018] = 60,
        [19395] = 55,
        [23207] = 50,
        [23206] = 50,
        [11815] = 50,
        [13965] = 50,
        [12930] = 45,
        [17774] = 45,

    }

    RC.onUseTrinkets = {
        [21670] = true,
        [20130] = true,
        [23041] = true,
        [19849] = true,
        [22954] = true,
        [21180] = true,
        [23570] = true,

        [23047] = true,
        [23046] = true,
        [23017] = true,
        [19950] = true,
        [19951] = true,
        [19339] = true,
        [19024] = true,
        [19891] = true,
        [11819] = true,

        [12930] = true,

        [2820] = true,
        [10725] = true,
        [16022] = true,
    }

    RC.trinketBuffs = {
        [21670] = {buffId = 26480, duration = 30},
        [20130] = {buffId = 24427, duration = 60},
        [23041] = {buffId = 28777, duration = 20},
        [19849] = {buffId = 24658, duration = 20},
        [19950] = {buffId = 24658, duration = 20},
        [22954] = {buffId = 28866, duration = 15},
        [21180] = {buffId = 25891, duration = 20},
        [23570] = {buffId = 30458, duration = 15},

        [23047] = {buffId = 29346, duration = 30},
        [23046] = {buffId = 29338, duration = 20},
        [23017] = {buffId = 28780, duration = 20},
        [19339] = {buffId = 23723, duration = 20},
        [19024] = {buffId = 23271, duration = 10},
        [11819] = {buffId = 15667, duration = 0},

        [19891] = {buffId = 24348, duration = 20},

        [2820] = {buffId = 14530, duration = 10},
    }

    RC.potionSpellToItem = {
        [17528] = 13442,
        [5405] = 13446,
        [17540] = 13455,
        [3169] = 3387,
        [6615] = 5634,
        [2379] = 2459,
        [17543] = 13457,
        [17544] = 13456,
        [17546] = 13458,
        [17548] = 13459,
        [17549] = 13461
    }

    RC:DebugPrint("Database loaded: FIXED food/drinks categories", "system")

    local function countTrashMobs(raidName)
        local count = 0
        if RC.raidData[raidName] and RC.raidData[raidName].trashSections then
            for _, mobs in pairs(RC.raidData[raidName].trashSections) do
                count = count + #mobs
            end
        end
        return count
    end

    RC:DebugPrint("MC: " .. countTrashMobs("Molten Core") .. " trash mobs", "system")
    RC:DebugPrint("BWL: " .. countTrashMobs("Blackwing Lair") .. " trash mobs", "system")
    RC:DebugPrint("AQ40: " .. countTrashMobs("Temple of Ahn'Qiraj") .. " trash mobs", "system")
    RC:DebugPrint("Naxxramas: " .. countTrashMobs("Naxxramas") .. " trash mobs across 5 quarters", "system")

    RC.availableRaids = {
        "Molten Core",
        "Blackwing Lair",
        "Temple of Ahn'Qiraj",
        "Naxxramas",
        "Onyxia's Lair",
        "Zul'Gurub",
        "Ruins of Ahn'Qiraj"
    }

    if RC.cooldownTracker then
        RC.cooldownTracker.potionItemIds = RC.potionItemIds
        RC.cooldownTracker.potionSpellIds = RC.potionSpellIds
    end

    -- key: exact item name, value: short label for narrow bars/tooltips.
    -- Checked first by GetItemAbbreviation before the heuristic fallbacks below.
    RC.itemAbbreviations = {
        ["Kiss of the Spider"] = "KOTS",
        ["Slayer's Crest"] = "Slayer",
        ["The Restrained Essence of Sapphiron"] = "Sapph",
        ["Eye of the Dead"] = "EOTD",
        ["Loatheb's Reflection"] = "Loath",
        ["The Phylactery of Kel'Thuzad"] = "KT",
        ["Mark of the Champion"] = "MOTC",

        ["Iblis, Blade of the Fallen Seraph"] = "Iblis",
        ["Gressil, Dawn of Ruin"] = "Gressil",
        ["The Hungering Cold"] = "THC",
        ["Kingsfall"] = "Kings",
        ["Harbinger of Doom"] = "Harb",
        ["Misplaced Servo Arm"] = "Servo",
        ["Claymore of Unholy Might"] = "Unholy",
        ["Ghoul Skin Tunic"] = "GST",
        ["Girdle of the Mentor"] = "Mentor",
        ["Plated Abomination Ribcage"] = "PAR",
        ["Rime Covered Mantle"] = "Rime",
        ["Leggings of Apocalypse"] = "Apoc",
        ["Hatchet of Sundered Bone"] = "Sunderd",
        ["Widow's Remorse"] = "Widow",
        ["Wraith Blade"] = "Wraith",
        ["Nerubian Slavemaker"] = "NSM",
        ["Sadist's Collar"] = "Sadist",
        ["Cloak of Suturing"] = "Suture",
        ["Cloak of the Necropolis"] = "Necro",
        ["Polar Tunic"] = "Polar",
        ["Polar Gloves"] = "Polar",
        ["Polar Bracers"] = "Polar",
        ["Icebane Breastplate"] = "Icebane",
        ["Icebane Gauntlets"] = "Icebane",
        ["Icebane Bracers"] = "Icebane",

        ["Dreadnaught Helmet"] = "Dread",
        ["Dreadnaught Pauldrons"] = "Dread",
        ["Dreadnaught Breastplate"] = "Dread",
        ["Dreadnaught Gauntlets"] = "Dread",
        ["Dreadnaught Waistguard"] = "Dread",
        ["Dreadnaught Legplates"] = "Dread",
        ["Dreadnaught Sabatons"] = "Dread",
        ["Dreadnaught Bracers"] = "Dread",

        ["Badge of the Swarmguard"] = "BOTS",
        ["Jom Gabbar"] = "Jom",
        ["Death's Sting"] = "DSting",
        ["Larvae of the Great Worm"] = "Larvae",

        ["Cloak of the Fallen God"] = "Fallen",
        ["Dark Edge of Insanity"] = "DEOI",
        ["Blessed Qiraji War Axe"] = "BQWA",
        ["Blessed Qiraji Pugio"] = "Pugio",
        ["Gauntlets of Annihilation"] = "Annih",
        ["Silithid Claw"] = "SClaw",
        ["Hive Defiler Wristguards"] = "Hive",
        ["Barb of the Sand Reaver"] = "Barb",
        ["Onslaught Girdle"] = "Onslght",
        ["Amulet of the Fallen God"] = "Fallen",
        ["Ring of the Godslayer"] = "GodSlay",
        ["Boots of the Fallen Hero"] = "FalHero",
        ["Boots of the Redeemed Prophecy"] = "Redeemd",
        ["Pauldrons of the Unrelenting"] = "Unrlnt",
        ["Breastplate of Annihilation"] = "Annih",
        ["Gloves of Enforcement"] = "Enforc",
        ["Cloak of the Golden Hive"] = "GldHive",
        ["Angelista's Grasp"] = "Angel",
        ["Wristguards of True Flight"] = "TruFlt",
        ["Belt of Never-ending Agony"] = "Agony",
        ["Kalimdor's Revenge"] = "Kalimdr",
        ["Ravencrest's Legacy"] = "Ravncst",

        ["Conqueror's Crown"] = "Conq",
        ["Conqueror's Spaulders"] = "Conq",
        ["Conqueror's Breastplate"] = "Conq",
        ["Conqueror's Greaves"] = "Conq",
        ["Conqueror's Legguards"] = "Conq",

        ["Drake Fang Talisman"] = "DFT",
        ["Lifegiving Gem"] = "LGG",
        ["Rejuvenating Gem"] = "RejGem",
        ["Mind Quickening Gem"] = "MQG",

        ["Chromatically Tempered Sword"] = "CTS",
        ["Crul'shorukh, Edge of Chaos"] = "Crul",
        ["Maladath, Runed Blade of the Black Flight"] = "Mala",
        ["Doom's Edge"] = "Doom",
        ["Dragonfang Blade"] = "DFang",
        ["Spineshatter"] = "Spine",
        ["Ashkandi, Greatsword of the Brotherhood"] = "Ash",
        ["Chromatic Boots"] = "Chromat",
        ["Boots of the Shadow Flame"] = "Shadow",
        ["Cloak of the Brood Lord"] = "Brood",
        ["Cloak of Draconic Might"] = "Dracon",
        ["Neltharion's Tear"] = "NelTear",
        ["Elementium Reinforced Bulwark"] = "ERB",
        ["Archimtiros' Ring of Reckoning"] = "Arch",
        ["Circle of Applied Force"] = "COAF",
        ["Styleens Impeding Scarab"] = "Styleen",
        ["Prestor's Talisman of Connivery"] = "Prestor",
        ["Cloak of Firemaw"] = "Firemaw",
        ["Black Brood Pauldrons"] = "BBPauld",
        ["Legguards of the Fallen Crusader"] = "Crusadr",

        ["Helm of Wrath"] = "Wrath",
        ["Pauldrons of Wrath"] = "Wrath",
        ["Breastplate of Wrath"] = "Wrath",
        ["Gauntlets of Wrath"] = "Wrath",
        ["Waistband of Wrath"] = "Wrath",
        ["Legplates of Wrath"] = "Wrath",
        ["Sabatons of Wrath"] = "Wrath",
        ["Bracers of Wrath"] = "Wrath",

        ["Earthstrike"] = "Earth",
        ["Blackhand's Breadth"] = "BHB",
        ["Hand of Justice"] = "HOJ",
        ["Talisman of Ephemeral Power"] = "TOEP",

        ["Perdition's Blade"] = "Perd",
        ["Gutgutter"] = "Gut",
        ["Brutality Blade"] = "Brut",
        ["Core Hound Tooth"] = "CHT",
        ["Deathbringer"] = "Death",
        ["Bonereaver's Edge"] = "BRE",
        ["Striker's Mark"] = "Striker",
        ["Quick Strike Ring"] = "QSR",
        ["Band of Accuria"] = "BOA",
        ["Flameguard Gauntlets"] = "Flame",
        ["Flamewaker Legplates"] = "FWaker",
        ["Heavy Dark Iron Ring"] = "HDIR",
        ["Onslaught Girdle"] = "Onslght",
        ["Wristguards of Stability"] = "Stable",
        ["Wristguards of True Flight"] = "TruFlt",

        ["Helm of Might"] = "Might",
        ["Pauldrons of Might"] = "Might",
        ["Breastplate of Might"] = "Might",
        ["Gauntlets of Might"] = "Might",
        ["Belt of Might"] = "Might",
        ["Legplates of Might"] = "Might",
        ["Sabatons of Might"] = "Might",
        ["Bracers of Might"] = "Might",

        ["Diamond Flask"] = "Flask",
        ["Rune of the Guard Captain"] = "ROTGC",
        ["Mark of the Chosen"] = "Chosen",
        ["Counterattack Lodestone"] = "CAL",
        ["Zandalarian Hero Medallion"] = "ZHM",
        ["Zandalarian Hero Charm"] = "ZHC",
        ["Venomous Totem"] = "Venom",
        ["Darkmoon Card: Maelstrom"] = "Mael",
        ["Darkmoon Card: Heroism"] = "Hero",
        ["Darkmoon Card: Blue Dragon"] = "BluDrg",
        ["Royal Seal of Eldre'Thalas"] = "Royal",
        ["Renataki's Charm of Beasts"] = "Renatki",
        ["Hazza'rah's Charm of Healing"] = "Hazzarh",

        ["Master Dragonslayer's Ring"] = "MDR",
        ["Ring of the Qiraji Fury"] = "QFury",
        ["Signet Ring of the Bronze Dragonflight"] = "Bronze",
        ["Don Julio's Band"] = "DJB",
        ["Seal of the Gurubashi Berserker"] = "Gurub",
        ["Band of Unnatural Forces"] = "BOUF",
        ["Ring of the Earthshatterer"] = "EarthSh",
        ["Seal of Jin"] = "Jin",
        ["Band of Jin"] = "Jin",
        ["Ring of the Godslayer"] = "GodSlay",

        ["Onyxia Tooth Pendant"] = "OTP",
        ["Stormrage's Talisman of Seething"] = "Storm",
        ["Mark of C'Thun"] = "CThun",
        ["Pendant of the Qiraji Guardian"] = "QGuard",
        ["Barbed Choker"] = "Barbed",
        ["The Eye of Hakkar"] = "Hakkar",
        ["Amulet of the Fallen God"] = "Fallen",
        ["Pendant of the Fallen Dragon"] = "PDrag",
        ["Eye of C'Thun"] = "CThun",
        ["Choker of the Fire Lord"] = "FireLrd",
        ["Eskhandar's Collar"] = "Eskhand",

        ["Cloak of the Shrouded Mists"] = "Shroud",
        ["Cloak of the Unseen Path"] = "Unseen",
        ["Cloak of Concentrated Hatred"] = "Hatred",
        ["Puissant Cape"] = "Puiss",
        ["Cape of the Trinity"] = "Trinity",
        ["Drape of Unyielding Strength"] = "Unyld",
        ["Shroud of Dominion"] = "Domin",
        ["Cloak of the Fallen God"] = "Fallen",
        ["Cloak of the Golden Hive"] = "GldHive",
        ["Cape of the Black Baron"] = "Baron",

        ["Bloodlord's Defender"] = "BLD",
        ["Thekal's Grasp"] = "Thekal",
        ["Arlokk's Grasp"] = "Arlokk",
        ["Warblade of the Hakkari"] = "WBHakk",
        ["Fang of the Faceless"] = "Facels",
        ["Zin'rokh, Destroyer of Worlds"] = "Zinrokh",
        ["Bloodcaller"] = "BCaller",
        ["Jin'do's Judgement"] = "Jindo",
        ["Jin'do's Hexxer"] = "Hexxer",
        ["Touch of Chaos"] = "ToChaos",
        ["Halberd of Smiting"] = "Smiting",
        ["Zulian Hacker"] = "ZHacker",
        ["Fang of Venoxis"] = "Venoxis",

        ["Lionheart Helm"] = "LHH",
        ["Helm of Endless Rage"] = "Rage",
        ["Titanic Leggings"] = "Titanic",
        ["Edgemaster's Handguards"] = "Edge",
        ["Aged Core Leather Gloves"] = "ACLG",
        ["Devilsaur Gauntlets"] = "Devsaur",
        ["Devilsaur Leggings"] = "Devsaur",
        ["Black Dragonscale Shoulders"] = "BDS",
        ["Black Dragonscale Boots"] = "BDS",
        ["Black Dragonscale Breastplate"] = "BDS",
        ["Black Dragonscale Leggings"] = "BDS",
        ["Savage Gladiator Chain"] = "SGC",
        ["Truestrike Shoulders"] = "TrueStr",
        ["Cadaverous Armor"] = "Cadavr",
        ["Mask of the Unforgiven"] = "Unforgv",
        ["Barman Shanker"] = "Barman",
        ["Felstriker"] = "Felstk",
        ["Ironfoe"] = "Ironfoe",
        ["Alcor's Sunrazor"] = "Alcor",
        ["Bonescraper"] = "BoneScp",
        ["Dal'Rend's Sacred Charge"] = "Sacred",
        ["Dal'Rend's Tribal Guardian"] = "Tribal",
        ["Blackblade of Shahram"] = "Shahram",
        ["Heartstriker"] = "HrtStrk",
        ["Satyr's Bow"] = "Satyr",
        ["Blackcrow"] = "BCrow",
        ["Cloudkeeper Legplates"] = "Cloud",
        ["Stockade Pauldrons"] = "Stock",
        ["Eldritch Reinforced Legplates"] = "Eldritc",
        ["Bloodsoaked Legplates"] = "BSoaked",
        ["Mugger's Belt"] = "Mugger",
        ["Battleborn Armbraces"] = "Battle",
        ["Carapace of Black Dragonscale"] = "Carapce",
        ["Legguards of the Chromatic Defier"] = "Defier",
        ["Taut Dragonhide Belt"] = "Taut",
        ["Taut Dragonhide Gloves"] = "Taut",
        ["Taut Dragonhide Shoulderpads"] = "Taut",

        ["Flask of Supreme Power"] = "Suprm",
        ["Flask of the Titans"] = "Titans",
        ["Flask of Distilled Wisdom"] = "Wisdom",
        ["Flask of Chromatic Resistance"] = "Chroma",

        ["Elixir of the Mongoose"] = "Mongse",
        ["Elixir of the Giants"] = "Giants",
        ["Elixir of Brute Force"] = "Brute",
        ["Elixir of Greater Agility"] = "Agility",
        ["Elixir of Firepower"] = "FirePw",
        ["Elixir of Shadow Power"] = "Shadow",
        ["Elixir of Frost Power"] = "Frost",
        ["Arcane Elixir"] = "Arcane",
        ["Winterfall Firewater"] = "FireH2O",
        ["Fisherliver Oil"] = "FishOil",
        ["Moist Towelette"] = "Towel",

        ["Elixir of Fortitude"] = "Fort",
        ["Elixir of Superior Defense"] = "SupDef",
        ["Elixir of Greater Firepower"] = "GrFire",
        ["Elixir of Poison Resistance"] = "Poison",
        ["Gift of Arthas"] = "Arthas",

        ["Greater Fire Protection Potion"] = "GFPP",
        ["Greater Frost Protection Potion"] = "GFrPP",
        ["Greater Nature Protection Potion"] = "GNPP",
        ["Greater Shadow Protection Potion"] = "GSPP",
        ["Greater Arcane Protection Potion"] = "GAPP",
        ["Fire Protection Potion"] = "FPP",
        ["Frost Protection Potion"] = "FrPP",
        ["Nature Protection Potion"] = "NPP",
        ["Shadow Protection Potion"] = "SPP",

        ["Mighty Rage Potion"] = "MRage",
        ["Greater Stoneshield Potion"] = "Stone",
        ["Thistle Tea"] = "Tea",
        ["Free Action Potion"] = "FAP",
        ["Limited Invulnerability Potion"] = "LIP",
        ["Living Action Potion"] = "LAP",
        ["Restorative Potion"] = "Restve",
        ["Swiftness Potion"] = "Swift",

        ["Juju Power"] = "Power",
        ["Juju Might"] = "Might",
        ["Juju Flurry"] = "Flurry",
        ["Juju Chill"] = "Chill",
        ["Juju Ember"] = "Ember",
        ["Juju Escape"] = "Escape",
        ["Juju Guile"] = "Guile",

        ["Spirit of Zanza"] = "Zanza",
        ["Swiftness of Zanza"] = "ZSwift",
        ["Sheen of Zanza"] = "ZSheen",

        ["Grilled Squid"] = "Squid",
        ["Smoked Desert Dumplings"] = "Dumpls",
        ["Blessed Sunfruit"] = "SunFrt",
        ["Blessed Sunfruit Juice"] = "SunJce",
        ["Dirge's Kickin' Chimaerok Chops"] = "Dirge",
        ["Runn Tum Tuber Surprise"] = "Tuber",
        ["Monster Omelet"] = "Omelet",
        ["Tender Wolf Steak"] = "Wolf",
        ["Nightfin Soup"] = "NtFin",

        ["Elemental Sharpening Stone"] = "ElemS",
        ["Consecrated Sharpening Stone"] = "ConscS",
        ["Dense Sharpening Stone"] = "DenseS",
        ["Brilliant Wizard Oil"] = "BrWizO",
        ["Brilliant Mana Oil"] = "BrMana",
        ["Shadow Oil"] = "ShadO",
        ["Frost Oil"] = "FrstO",

        ["Goblin Sapper Charge"] = "Sapper",
        ["Dense Dynamite"] = "Dynmte",
        ["Thorium Grenade"] = "Grenad",
        ["Dark Rune"] = "DRune",
        ["Demonic Rune"] = "DmRune",
        ["Major Mana Potion"] = "MMana",
        ["Major Healing Potion"] = "MHeal",
        ["Rumsey Rum Black Label"] = "Rumsey",
        ["Gordok Green Grog"] = "Grog",
        ["Kreeg's Stout Beatdown"] = "Kreeg",
    }

    -- Fallback inputs for GetItemAbbreviation below, consulted in this order:
    -- itemPrefixStrip/itemPrefixAbbreviations (PvP rank prefixes), then
    -- itemWeaponTypes (weapon-name suffix), then itemStripWords (generic
    -- word heuristic).
    RC.itemPrefixAbbreviations = {
        ["Grand Marshal's "] = "GM",
        ["High Warlord's "] = "HWL",
        ["Field Marshal's "] = "FMarshl",
        ["Warlord's "] = "Warlord",
        ["Marshal's "] = "Marshal",
        ["General's "] = "General",
        ["Lieutenant Commander's "] = "LtCmdr",
        ["Champion's "] = "Champ",
        ["Legionnaire's "] = "Legion",
        ["Blood Guard's "] = "BGuard",
        ["Knight-Captain's "] = "KCap",
        ["Knight-Lieutenant's "] = "KLt",
        ["Sergeant Major's "] = "SgtMaj",
        ["Master Sergeant's "] = "MSgt",
        ["Senior Sergeant's "] = "SSgt",
        ["First Sergeant's "] = "1stSgt",
        ["Stone Guard's "] = "SGuard",
        ["Sergeant's "] = "Sgt",
        ["Grunt's "] = "Grunt",
        ["Scout's "] = "Scout",
        ["Private's "] = "Pvt",
    }

    RC.itemPrefixStrip = {
        "Grand Marshal's ",
        "High Warlord's ",
        "Field Marshal's ",
        "Lieutenant Commander's ",
        "Warlord's ",
        "Marshal's ",
        "General's ",
        "Champion's ",
        "Legionnaire's ",
        "Blood Guard's ",
        "Knight-Captain's ",
        "Knight-Lieutenant's ",
        "Sergeant Major's ",
        "Master Sergeant's ",
        "Senior Sergeant's ",
        "First Sergeant's ",
        "Stone Guard's ",
        "Sergeant's ",
        "Grunt's ",
        "Scout's ",
        "Private's ",
    }

    RC.itemWeaponTypes = {
        ["Longsword"] = "Long",
        ["Swiftblade"] = "Swift",
        ["Claymore"] = "Clay",
        ["Quickblade"] = "Quick",
        ["Pulverizer"] = "Pulv",
        ["Slicer"] = "Slicer",
        ["Destroyer"] = "Destr",
        ["Aegis"] = "Aegis",
        ["Stave"] = "Stave",
        ["Warblade"] = "WBlade",
        ["Handaxe"] = "HAxe",
        ["Dirk"] = "Dirk",
        ["Punisher"] = "Punish",
        ["Pigsticker"] = "Pig",
        ["Battle Hammer"] = "Hammer",
        ["War Staff"] = "Staff",
        ["Recurve"] = "Recurve",
        ["Repeater"] = "Repeat",
        ["Musket"] = "Musket",
        ["Crossbow"] = "XBow",
    }

    RC.itemStripWords = {
        "of", "the", "a", "an", "and", "with", "from",
    }

    local function toTitleCase(str)
        if not str or #str == 0 then return str end
        return str:sub(1,1):upper() .. str:sub(2):lower()
    end

    -- Match order matters: exact name, then PvP rank prefix, then "of the X" /
    -- "of X" / possessive / "The X" patterns, then last-word heuristic.
    function RC:GetItemAbbreviation(itemName)
        if not itemName then return nil end

        if self.itemAbbreviations[itemName] then
            return self.itemAbbreviations[itemName]
        end

        for _, prefix in ipairs(self.itemPrefixStrip) do
            if itemName:sub(1, #prefix) == prefix then
                local remainder = itemName:sub(#prefix + 1)

                for weaponType, abbrev in pairs(self.itemWeaponTypes) do
                    if remainder == weaponType then
                        return abbrev
                    end
                end

                return self.itemPrefixAbbreviations[prefix]
            end
        end

        local ofTheMatch = itemName:match("of the (%w+)")
        if ofTheMatch and #ofTheMatch >= 4 then
            local result = toTitleCase(ofTheMatch)
            if #result > 6 then
                return result:sub(1, 5) .. "."
            end
            return result
        end

        local ofMatch = itemName:match("of (%w+)")
        if ofMatch and #ofMatch >= 4 then
            local result = toTitleCase(ofMatch)
            if #result > 6 then
                return result:sub(1, 5) .. "."
            end
            return result
        end

        local possessiveMatch = itemName:match("'s (%w+)")
        if possessiveMatch and #possessiveMatch >= 3 then
            local result = toTitleCase(possessiveMatch)
            if #result > 6 then
                return result:sub(1, 5) .. "."
            end
            return result
        end

        local theMatch = itemName:match("^The (%w+)")
        if theMatch and #theMatch >= 3 then
            local result = toTitleCase(theMatch)
            if #result > 6 then
                return result:sub(1, 5) .. "."
            end
            return result
        end

        local words = {}
        for word in itemName:gmatch("%w+") do
            local lowerWord = word:lower()
            local isStripWord = false
            for _, strip in ipairs(self.itemStripWords) do
                if lowerWord == strip then
                    isStripWord = true
                    break
                end
            end
            if not isStripWord and #word >= 3 then
                table.insert(words, word)
            end
        end

        if #words > 0 then
            local lastWord = words[#words]
            local result = toTitleCase(lastWord)
            if #result <= 6 then
                return result
            else
                return result:sub(1, 5) .. "."
            end
        end

        if #itemName > 6 then
            return toTitleCase(itemName:sub(1, 5)) .. "."
        end
        return toTitleCase(itemName)
    end

    local abbrevCount = 0
    for _ in pairs(RC.itemAbbreviations) do abbrevCount = abbrevCount + 1 end
    RC:DebugPrint("Item abbreviation system loaded: " .. abbrevCount .. " direct abbreviations", "system")

    RC.defaults = {
        enabled = true,
        showInCombatOnly = false,
        abilityReadyGracePeriod = 0,
        fadeInTime = 0.3,
        fadeTime = 0.3,
        soundEnabled = false,
        soundKey  = "WR: Warning",
        soundFile = "Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg",
        abilityOverrides = {},
        -- Master voice switch. Every spoken line in the addon passes through
        -- RC:SpeakTTS, which refuses to speak while this is off.
        ttsEnabled = true,
        -- Read by ShowReminder's repeat chain. Both were used there with no
        -- default and no UI, so the count resolved to nil -> 0 and reminder
        -- TTS could never repeat.
        ttsRepeatCount = 0,
        ttsRepeatInterval = 30,

        nonWarriorEnabled = {},

        -- Hotswap: a press in combat is queued for when it ends instead
        -- of refused. Off by default - the swap then fires unasked.
        hotswapCombatQueue = false,

        showStatsBar = false,
        showStatsButton = false,
        statsBarLocked = false,
        statsBarHeight = 20,
        statsBarFontSize = 12,
        statsBarSpacing = 10,
        statsBarShowPushoffIcon = true,
        statsBarDurability = true,
        statsBarGold = false,
        -- Character Stats Bar looks (fonts, background texture, border);
        -- every nil field is the bar's original look
        statsBarLook = {},

        -- the buff cap counter behind the Buffs cell (CS_BuffCap.lua)
        buffCap = {
            countHidden = true,  -- stance, Defensive State, tracking, worn items
            learn = true,        -- learn slots it cannot see from push-offs
            chatWarn = true,     -- a chat line when the cap pushes a buff off
            barText = "used",    -- the cell shows "used", "ratio" or "free"
        },
        -- what this character's counter has measured; never shared
        buffCapLearned = { learned = 0, pushes = {} },

        buffPushoffAlert = {
            enabled = false,
            locked = false,
            showBackground = true,
            showIcon = true,
            showText = true,
            textFormat = "%s pushed off!",
            duration = 3,
            fontSize = 18,
            iconSize = 32,
            scale = 1.0,
            anchorPoint = "CENTER",
            xOffset = 0,
            yOffset = 150,
            ttsEnabled = false,
            -- warn when a Darkmoon Faire fortune carried as a debuff is
            -- pushed off by the 16-debuff cap (works with `enabled` off)
            dmfDebuff = true,
            -- name what took the slot, under the alert and in the voice line
            showPusher = true,
            ttsPusher = false,
            -- fonts, colours, background texture, size, entrance/exit
            look = {},
        },

        -- a notice when Readycheck changes gear for you (route steps, boss
        -- pulls and kills, trinket rotations); off unless asked for
        swapToast = {
            enabled = false,
            duration = 4,
            scale = 1.0,
            showNames = true,
            showBackground = true,
            locked = true,
            soundKey = "",
            anchorPoint = "CENTER",
            xOffset = 0,
            yOffset = 220,
        },

        sidebarNav = {
            trinkets            = true,
            gear_manager        = true,
            equipment_reminder  = true,
            hotswap             = true,
            spec_detection      = true,
            stats_bar           = true,
            battle_shout        = true,
            boon_reminder       = true,
            execute             = true,
            ttk_display         = true,
        },

        ttkDisplay = {
            enabled = false,
            locked = false,
            showBackground = true,
            width = 120,
            height = 70,
            anchorPoint = "TOP",
            xOffset = 0,
            yOffset = -100,
            fontSize = 14,
            headerFontSize = 10,
            scale = 1.0,
            showConfidence = true,
            showHealthPercent = true,
            showOutOfCombat = false,
            showLabels = false,
            shortLabels = false,
            centerText = true,
            showPace = true,
            showHeader = true,
        },

        anchorPoint = "CENTER",
        xOffset = 0,
        yOffset = 200,
        iconSize = 80,
        iconSpacing = 5,
        showIconText = true,
        iconGlow = "pulse",
        iconBorder = "thick",
        iconGlowScale = 1.5,
        showTooltips = true,
        dragEnabled = false,
        clickThrough = true,
        hideUnderMap = false,     -- on-screen frames fade while the world map covers them (UI/MapStandDown.lua); off: Zac keeps the world-buff timers over the map
        animationType = "fade",
        -- The reminder popup's animation beyond animationType and the fade
        -- times: show/hide hold easing, delay, dir, distance, loop, and
        -- hide.style (nil = same style as the entrance). Empty = the
        -- linear fade the popup has always had.
        reminderMotion = { show = {}, hide = {} },
        -- The reminder icon label (USE / REMOVE / a custom alert's text):
        -- font spec (nil fields = Readycheck's font, 12, outline, shadow)
        -- and colour (nil = coloured by state, as always).
        reminderText = { font = {} },
        -- The popup on the customization standard (anchors / layout /
        -- states / formats); empty = the popup as it always was.
        reminderPopup = {},
        -- The glow on the raid consume reminder icons (RC.UI:CreateEdgeGlow):
        -- style "edge" | "pixel" | "autocast" | "border" | "none"; alpha =
        -- strength; size = how far it reaches; halo = the soft wide layer;
        -- pulse / speed (seconds per breath) / depth; lines / length (px) /
        -- lineSpeed (laps a second) for the lines and sparkles; color (nil =
        -- Readycheck's accent). Empty = every field at the framework's
        -- defaults (RC.UI.EDGE_GLOW_DEFAULTS: a pulsing edge glow, no halo).
        consumeRemindGlow = {},
        -- Appearance > Motion: every Readycheck animation on/off and its speed.
        motion = { enabled = true, speed = 1 },
        -- Preview strip fold, background, height and chosen mode per page
        -- (window state). height: "small" | "tall"; nil = Normal.
        previewPane = { height = nil },
        -- Game version: override = nil (this client) or "era" / "tbc" /
        -- "forever", the developer override that switches off what that
        -- client does not run. Set from Readycheck_Testing or /rc flavor,
        -- read once per session (Core_Flavor.lua). Never exported or synced.
        flavor = {},

        spikeLogger = {
            enabled = false,
            thresholdMs = 50,
            maxEntries = 200,
        },

        nameplateAuras = {
            enabled = false,
            fontSize = 11,
            -- fonts, icon border / crop, entrance and expiring animations
            look = {},
            groups = {
                { id = "armor", name = "Sunder / Expose", mode = "single", attach = "center", timerPos = "beside", offsetX = 0, offsetY = 22, enabled = true, fontSize = 11, timerSize = 7, timerGap = 0,
                  showIcon = true, showCount = true, showTimer = true,
                  members = { "sunder", "expose" } },
                { id = "armorextra", name = "Faerie Fire / Curse", mode = "row", attach = "center", timerPos = "beside", growDir = "right", offsetX = 0, offsetY = 40, enabled = true, fontSize = 11, timerSize = 7, timerGap = 0,
                  showIcon = true, showCount = false, showTimer = true,
                  members = { "faeriefire", "faeriefireferal", "cor" } },
                { id = "other", name = "Other Debuffs", mode = "row", attach = "center", timerPos = "beside", growDir = "right", offsetX = 0, offsetY = -22, enabled = true, fontSize = 11, timerSize = 7, timerGap = 0,
                  showIcon = true, showCount = false, showTimer = true,
                  members = { "demoshout", "demoroar", "curseofweakness", "thunderclap", "thunderfury", "disarm" } },
                { id = "overpower", name = "Overpower Proc", mode = "single", attach = "center", timerPos = "beside", offsetX = 0, offsetY = -40, enabled = true, fontSize = 11, timerSize = 7, timerGap = 0,
                  showIcon = true, showCount = false, showTimer = true,
                  members = { "overpower" } },
                { id = "execute", name = "Execute Range", mode = "single", attach = "center", timerPos = "beside", offsetX = 0, offsetY = 58, enabled = true, fontSize = 11, timerSize = 7, timerGap = 0,
                  showIcon = true, showCount = false, showTimer = false, bossOnly = false,
                  members = { "execute" } },
            },
        },

        fontSettings = {
            selectedFont = "default",
            fontSize = 12,
            fontOutline = "OUTLINE",
            mainWindowBgOpacity = 1.0,
        },

        executeSettings = {
            executeThreshold = 20,
            raidMultiplier = 1.6
        },

        consumablesHelper = {
            enabled = false,
            buttonSize = 32,
            -- Horde Mode by faction ("Horde"/"Alliance" = true/false);
            -- unset means on for Horde characters, off for Alliance ones
            hordeByFaction = {},
            buttonsPerRow = 10,
            iconSpacing = 4,
            growDirection = "DOWN",
            showBackground = false,
            showCount = true,
            hideInCombat = false,
            alwaysShowStones = false,
            hideWhenActive = false,
            hideConflictingBuffs = false,
            showBeforeExpiry = 60,
            hiddenItems = {},
            hiddenWeapons = {},
            -- the weapons bar's pick per hand ("mainhand"/"offhand" =
            -- itemId); a poison picked on one hand stays on that hand
            selectedStoneBySlot = {},
            itemOrder = {},
            locked = false,
            anchorPoint = "TOPRIGHT",
            xOffset = -10,
            yOffset = -200,
            mouseoverFade = false,
            mouseoverFadeAlpha = 0.15,
            petrificationCampMode = false,
            consumableTTSEnabled       = false,
            consumableTTSVolume        = 100,
            potionReadyTTS             = false,
            consumableTTSRepeatEnabled  = false,
            consumableTTSRepeatInterval = 60,
            consumableTTSRepeatCount    = 1,
            consumableTTSSettings       = {},
            ttsVoiceId                 = nil,
        },

        bossNotes = {
            enabled         = true,
            locked          = true,
            xOffset         = 0,
            yOffset         = 150,
            scale           = 1.0,
            opacity         = 0.85,
            fontSize        = 14,
            showBackground  = true,
            showForTrash    = true,
            lingerDuration  = 0,
            trashNote       = "",
            notes           = {},
            ttsEnabled      = false,
            ttsTrigger      = "encounter_start",
        },

        boonReminder = {
            enabled = true,
            mode = "boss",
            locked = false,
            iconSize = 40,
            showLabel = true,
            fontSize = 12,
            anchorPoint = "CENTER",
            xOffset = 200,
            yOffset = 200,
            playSound = false,
            soundKey  = "WR: Warning",
            soundFile = "Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg",
            animationType = "fade",
            disabledBosses = {
                ["Instructor Razuvious"] = true,
                ["Gothik the Harvester"] = true,
            },
        },

        repairReminder = {
            enabled   = true,
            threshold = 50,
            playSound = false,
            soundKey  = "WR: Warning",
            soundFile = "Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg",
            tts       = false,
            -- on login, name carried weapons below full weapon skill
            weaponSkill = true,
        },

        worldBuffs = {
            hideBelowMax = true,
            enabled = true,
            boardSort = "buffs",
            boardSortTopClass = "",
            -- board fonts, state colours, compact cell size / row height
            look = {},
        },

        raidRoute = {
            enabled = false,
            trackerEnabled = true,
            trackerShowContext = false,
        },
        gearUseRevert = true,
        speedSwapTargets = {},
        gearSwapRetry = { attempts = 3, interval = 1.0, warn = true },
        -- the after-boss gear set picker: where it sits (x, y from screen
        -- centre) and how big its buttons are (buttonWidth, rowHeight);
        -- empty until it is moved or resized
        gearSetPrompt = {},

        frostBlastConfig = {
            alsoShowWhenDebuffed = false,
            cancelAuraBuffs = {},
            showMacroButton = false,
            history      = {},
            maxHpSamples = {},
            peakMaxHp    = nil,
        },

        consumablesChecker = {
            warningThreshold = 5,
            showOnlyMissing = false,
            disabledItems = {},
            openWithAH = false,
            openWithMail = false,
            soundKey = "WR: Warning",
            -- must-have items: big on-screen icons when one is missing
            -- (Checker_Essentials.lua); items are item ids, a target dummy
            -- stands for any dummy
            essentials = {
                enabled = true,
                airhorn = false,
                soundKey = "Readycheck: Air Horn",
                iconSize = 56,
                items = { 3387, 3386, 16023 },
            },
        },

        potionsBar = {
            enabled = false,
            petrificationCampMode = false,
            itemOrder = {},
            buttonSize = 32,
            buttonsPerRow = 10,
            iconSpacing = 4,
            growDirection = "DOWN",
            showBackground = false,
            showCount = true,
            hideInCombat = false,
            hideWhenActive = false,
            showBeforeExpiry = 60,
            -- Core_Init's FillMissing re-seeds any key missing from a saved
            -- profile on every login, so "unhide" must write false rather
            -- than delete the key - see RC:ShowAllPotionBarItems.
            hiddenItems = {
                [21171] = true,
                [13810] = true,
                [20452] = true,
                [21023] = true,
                [12217] = true,
                [23326] = true,
                [23211] = true,
                [13931] = true,
                [14530] = true,
            },
            locked = false,
            anchorPoint = "TOPRIGHT",
            xOffset = -10,
            yOffset = -400,
            mouseoverFade = false,
            mouseoverFadeAlpha = 0.15,
            ttsEnabled = false
        },

        weaponsBar = {
            enabled = false,
            buttonSize = 36,
            -- Horde Mode by faction ("Horde"/"Alliance" = true/false);
            -- unset means on for Horde characters, off for Alliance ones
            hordeByFaction = {},
            buttonsPerRow = 4,
            iconSpacing = 4,
            growDirection = "RIGHT",
            showBackground = true,
            showCount = true,
            showItemNames = false,
            showEquippedWeapons = true,
            showBagWeapons = true,
            hiddenWeapons = {},
            hideInCombat = false,
            showBeforeExpiry = 60,
            visibilityMode = "always",
            -- visibilityRaids: optional { [raidName]=true } set (keys from
            -- RC.availableRaids) that narrows the raid modes to the ticked
            -- raids. Created on demand by the settings page and removed
            -- again when emptied, so absent = every raid counts. Same
            -- field on consumablesHelper, potionsBar and trinketBar.
            locked = false,
            anchorPoint = "BOTTOMLEFT",
            xOffset = 300,
            yOffset = 100,
            mouseoverFade = false,
            mouseoverFadeAlpha = 0.15,
            ttsEnabled = false
        },

        trinketSwap = {
            enabled = false,
            autoSwapActive = true,
            showToggleButton = false,
            toggleButtonLocked = false,
            compactButton = false,
            mouseoverFade = false,
            mouseoverFadeAlpha = 0.15,
            showQueueIcons = true,
            pauseDuringBossFight = false,
            currentQueue = "default",
            -- how a slot's trinkets are tried: "priority" (priorities[itemId],
            -- highest first - the default, as it always was) or "list" (top
            -- to bottom, once picked on the page: orderPicked)
            order = "priority",
            priorities = {},
            toggleButtonPosition = {
                point = "CENTER",
                x = 0,
                y = 0
            },
            configNames = {
                default = "Default",
                config1 = "Config 1",
                config2 = "Config 2",
                config3 = "Config 3",
                config4 = "Config 4",
                config5 = "Config 5"
            },
            queues = {
                default = { slot1 = {}, slot2 = {} },
                config1 = { slot1 = {}, slot2 = {} },
                config2 = { slot1 = {}, slot2 = {} },
                config3 = { slot1 = {}, slot2 = {} },
                config4 = { slot1 = {}, slot2 = {} },
                config5 = { slot1 = {}, slot2 = {} }
            },
        },

        setupWizard = {
            completed = false,
            lastStep = 1,
        },

        customReminders = {
            reminders = {},
            nextId = 1,
        },
    }

    -- Ready-made raid profiles offered in the profile picker. Each entry's
    -- "data" field is an opaque WR1: base64 export blob (see PM_Export.lua's
    -- import decoder) - do not hand-edit; regenerate via the export UI.
    RC.builtInProfiles = {
        ["Naxxramas"] = {
            {
                name = "DPS Speed (by Zac)",
                description = RCL["Optimized DPS profile for speed clearing Naxx. Uses FAPs, weapon stones, potion timing, and TTK-based cooldown usage."],
                data = "WR1:e1sndmVyc2lvbiddPTEsWydyYWlkTmFtZSddPSdOYXh4cmFtYXMnLFsnYWRkb24nXT0nV2FycmlvclJlbWluZGVyJyxbJ3RpbWVzdGFtcCddPTE3NjcwNTMyNjQsWydkYXRhJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmFzaCddPXtbJ1BhdGNod29yayBHb2xlbSddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsndXRpbGl0eVR5cGUnXT0nMTg2NDEnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydwb3Rpb25UeXBlJ109J2ZyZWVBY3Rpb25Qb3Rpb24nLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsndHJpbmtldDEnXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50J30sWydibG9vZHJhZ2UnXT17WydlbmFibGVkJ109ZmFsc2UsWydocFZhbHVlJ109MjAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50J30sWyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2JyxbJ3BvdGlvblR5cGUnXT0nZnJlZUFjdGlvblBvdGlvbid9LFsncG90aW9uJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsncG90aW9uVHlwZSddPSdmcmVlQWN0aW9uUG90aW9uJ30sWydkZWF0aHdpc2gnXT17WydlbmFibGVkJ109ZmFsc2UsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlfSxbJ3RyaW5rZXQyJ109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsncmVja2xlc3NuZXNzJ109e1snZW5hYmxlZCddPWZhbHNlLFsnaHBWYWx1ZSddPTIwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsnYmVyc2Vya2VycmFnZSddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ2hwVmFsdWUnXT0yMCxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJ3V0aWxpdHknXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ319fSxbJ1BsYWd1ZWQgR2hvdWwnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J2ZhZGUnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ3V0aWxpdHlUeXBlJ109JzE4NjQxJ30sWyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J2ZhZGUnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2JyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfX19LFsnVW5ob2x5IFN3b3JkcyddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdmYWRlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nODk1NicsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50J319fSxbJ1BsYWd1ZWQgTWFnZ290J109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17WycxODY0MSddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydwb3Rpb25UeXBlJ109J3N0b25lc2hpZWxkUG90aW9uJyxbJ3V0aWxpdHlUeXBlJ109JzE4NjQxJyxbJ2hwVmFsdWUnXT0xMDB9LFsnMTMxODAnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWydlbmFibGVUVFMnXT10cnVlLFsncG90aW9uVHlwZSddPSdzdG9uZXNoaWVsZFBvdGlvbicsWyd1dGlsaXR5VHlwZSddPScxMzE4MCcsWydocFZhbHVlJ109MTAwfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWydlbmFibGVUVFMnXT10cnVlLFsncG90aW9uVHlwZSddPSdzdG9uZXNoaWVsZFBvdGlvbicsWyd1dGlsaXR5VHlwZSddPSc4OTU2JyxbJ2hwVmFsdWUnXT0xMDB9fX0sWydQbGFndWVkIEJhdCddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsncG90aW9uVHlwZSddPSdzdG9uZXNoaWVsZFBvdGlvbicsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109JzE4NjQxJyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJzEzMTgwJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3BvdGlvblR5cGUnXT0nc3RvbmVzaGllbGRQb3Rpb24nLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPScxMzE4MCcsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50J30sWyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3BvdGlvblR5cGUnXT0nc3RvbmVzaGllbGRQb3Rpb24nLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2JyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfX19LFsnU3RvbmVza2luIEdhcmdveWxlJ109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17WycxODY0MSddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109JzE4NjQxJyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfX19LFsnVW5ob2x5IFN0YWZmJ109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17Wyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J2ZhZGUnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfX19LFsnRW1iYWxtaW5nIFNsaW1lJ109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17WycxODY0MSddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydwb3Rpb25UeXBlJ109J2ZyZWVBY3Rpb25Qb3Rpb24nLFsndXRpbGl0eVR5cGUnXT0nMTg2NDEnLFsnaHBWYWx1ZSddPTEwMH0sWycxNjAyMyddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydocFZhbHVlJ109MTAwLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3BvdGlvblR5cGUnXT0nZnJlZUFjdGlvblBvdGlvbicsWyd1dGlsaXR5VHlwZSddPScxNjAyMycsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWydwb3Rpb24nXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPWZhbHNlLFsncG90aW9uVHlwZSddPSdtaWdodHlSYWdlUG90aW9uJyxbJ2hwVmFsdWUnXT05MH0sWydkZWF0aHdpc2gnXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPWZhbHNlfSxbJ3NoaWVsZHdhbGwnXT17WydlbmFibGVkJ109ZmFsc2UsWydwbGF5ZXJIcFZhbHVlJ109MjAsWyd0cmlnZ2VyVHlwZSddPSdwbGF5ZXJfaHAnLFsnZW5hYmxlVFRTJ109ZmFsc2V9LFsnbGFzdHN0YW5kJ109e1snZW5hYmxlZCddPWZhbHNlLFsncGxheWVySHBWYWx1ZSddPTMwLFsndHJpZ2dlclR5cGUnXT0ncGxheWVyX2hwJyxbJ2VuYWJsZVRUUyddPWZhbHNlfX19LFsnQ3J5cHQgR3VhcmQnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nMTg2NDEnLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsnODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9fX0sWydTdXJnaWNhbCBBc3Npc3RhbnQnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPScxODY0MScsWydwb3Rpb25UeXBlJ109J2ZyZWVBY3Rpb25Qb3Rpb24nfSxbJzE2MDIzJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPScxNjAyMycsWydwb3Rpb25UeXBlJ109J2ZyZWVBY3Rpb25Qb3Rpb24nfSxbJ2RlYXRod2lzaCddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydocFZhbHVlJ109MTAwLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3BvdGlvblR5cGUnXT0nZnJlZUFjdGlvblBvdGlvbicsWyd1dGlsaXR5VHlwZSddPScxODY0MScsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWycxMzE4MCddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydocFZhbHVlJ109MTAwLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3BvdGlvblR5cGUnXT0nZnJlZUFjdGlvblBvdGlvbicsWyd1dGlsaXR5VHlwZSddPScxMzE4MCcsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3BvdGlvblR5cGUnXT0nZnJlZUFjdGlvblBvdGlvbicsWyd1dGlsaXR5VHlwZSddPSc4OTU2JyxbJ2hwVmFsdWUnXT0xMDB9LFsnMTA2NDYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsncG90aW9uVHlwZSddPSdmcmVlQWN0aW9uUG90aW9uJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nMTA2NDYnLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9fX0sWydTcGVjdHJhbCBIb3JzZW1hbiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1sncG90aW9uJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsncG90aW9uVHlwZSddPSdzdG9uZXNoaWVsZFBvdGlvbid9fX0sWydJbmZlY3Rpb3VzIEdob3VsJ109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17WycxODY0MSddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydocFZhbHVlJ109MTAwLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3BvdGlvblR5cGUnXT0nc3RvbmVzaGllbGRQb3Rpb24nLFsndXRpbGl0eVR5cGUnXT0nMTg2NDEnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsnMTMxODAnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsncG90aW9uVHlwZSddPSdzdG9uZXNoaWVsZFBvdGlvbicsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109JzEzMTgwJyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWydlbmFibGVUVFMnXT10cnVlLFsncG90aW9uVHlwZSddPSdzdG9uZXNoaWVsZFBvdGlvbicsWyd1dGlsaXR5VHlwZSddPSc4OTU2JyxbJ2hwVmFsdWUnXT0xMDB9fX0sWydQbGFndWUgQmVhc3QnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPScxODY0MScsWydwb3Rpb25UeXBlJ109J3N0b25lc2hpZWxkUG90aW9uJ30sWycxMzE4MCddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nMTMxODAnLFsncG90aW9uVHlwZSddPSdzdG9uZXNoaWVsZFBvdGlvbid9LFsnODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nODk1NicsWydwb3Rpb25UeXBlJ109J3N0b25lc2hpZWxkUG90aW9uJ319fSxbJ0RlYXRoIEtuaWdodCBDYXZhbGllciddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsndXRpbGl0eVR5cGUnXT0nODk1Nid9LFsndXRpbGl0eSddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT05MCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfX19LFsnTWFkIFNjaWVudGlzdCddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsncG90aW9uVHlwZSddPSdmcmVlQWN0aW9uUG90aW9uJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nMTg2NDEnLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsnMTMxODAnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109JzEzMTgwJyxbJ3BvdGlvblR5cGUnXT0nZnJlZUFjdGlvblBvdGlvbid9LFsnZGVhdGh3aXNoJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPScxODY0MScsWydwb3Rpb25UeXBlJ109J2ZyZWVBY3Rpb25Qb3Rpb24nfSxbJzE2MDIzJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3BvdGlvblR5cGUnXT0nZnJlZUFjdGlvblBvdGlvbicsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109JzE2MDIzJyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnaHBWYWx1ZSddPTEwMCxbJ2VuYWJsZVRUUyddPXRydWUsWydwb3Rpb25UeXBlJ109J2ZyZWVBY3Rpb25Qb3Rpb24nLFsndXRpbGl0eVR5cGUnXT0nODk1NicsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWycxMDY0NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydwb3Rpb25UeXBlJ109J2ZyZWVBY3Rpb25Qb3Rpb24nLFsndXRpbGl0eVR5cGUnXT0nMTA2NDYnLFsnaHBWYWx1ZSddPTEwMH19fSxbJ0xpdmluZyBNb25zdHJvc2l0eSddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWydlbmFibGVUVFMnXT10cnVlLFsncG90aW9uVHlwZSddPSdmcmVlQWN0aW9uUG90aW9uJyxbJ3V0aWxpdHlUeXBlJ109JzE4NjQxJyxbJ2hwVmFsdWUnXT0xMDB9LFsnMTYwMjMnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWydlbmFibGVUVFMnXT10cnVlLFsncG90aW9uVHlwZSddPSdmcmVlQWN0aW9uUG90aW9uJyxbJ3V0aWxpdHlUeXBlJ109JzE2MDIzJyxbJ2hwVmFsdWUnXT0xMDB9LFsnZGVhdGh3aXNoJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3BvdGlvblR5cGUnXT0nZnJlZUFjdGlvblBvdGlvbicsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109JzE4NjQxJyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJzEzMTgwJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3BvdGlvblR5cGUnXT0nZnJlZUFjdGlvblBvdGlvbicsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109JzEzMTgwJyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnLFsncG90aW9uVHlwZSddPSdmcmVlQWN0aW9uUG90aW9uJ30sWycxMDY0NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydocFZhbHVlJ109MTAwLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3BvdGlvblR5cGUnXT0nZnJlZUFjdGlvblBvdGlvbicsWyd1dGlsaXR5VHlwZSddPScxMDY0NicsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ319fSxbJ1Vuc3RvcHBhYmxlIEFib21pbmF0aW9uJ109e1snZW5hYmxlZCddPWZhbHNlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWyd1dGlsaXR5VHlwZSddPScxODY0MSd9fX0sWydVbmhvbHkgQXhlJ109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17Wyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J2ZhZGUnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2JyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfX19LFsnVG9tYiBIb3Jyb3InXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nMTg2NDEnLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsnODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9fX0sWydGcmVuemllZCBCYXQnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2hwVmFsdWUnXT0xMDAsWydlbmFibGVUVFMnXT10cnVlLFsncG90aW9uVHlwZSddPSdzdG9uZXNoaWVsZFBvdGlvbicsWyd1dGlsaXR5VHlwZSddPScxODY0MScsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWycxMzE4MCddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydocFZhbHVlJ109MTAwLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3BvdGlvblR5cGUnXT0nc3RvbmVzaGllbGRQb3Rpb24nLFsndXRpbGl0eVR5cGUnXT0nMTMxODAnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsnODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydocFZhbHVlJ109MTAwLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3BvdGlvblR5cGUnXT0nc3RvbmVzaGllbGRQb3Rpb24nLFsndXRpbGl0eVR5cGUnXT0nODk1NicsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ319fSxbJ1NwZWN0cmFsIERlYXRoIEtuaWdodCddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1sncG90aW9uJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsncG90aW9uVHlwZSddPSdzdG9uZXNoaWVsZFBvdGlvbid9fX0sWydDcnlwdCBDcmF3bGVyJ109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17WycxODY0MSddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsndXRpbGl0eVR5cGUnXT0nMTg2NDEnfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfSxbJ3V0aWxpdHknXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ319fSxbJ0NyeXB0IFJlYXZlciddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ3V0aWxpdHlUeXBlJ109JzE4NjQxJ30sWyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWyd1dGlsaXR5VHlwZSddPSc4OTU2J319fSxbJ1NwZWN0cmFsIFRyYWluZWUnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJ3BvdGlvbiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3BvdGlvblR5cGUnXT0nc3RvbmVzaGllbGRQb3Rpb24nfX19LFsnQ2FycmlvbiBTcGlubmVyJ109e1snZW5hYmxlZCddPWZhbHNlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPScxODY0MSd9LFsnODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfSxbJzEwNjQ2J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nMTA2NDYnfX19LFsnRHJlYWQgQ3JlZXBlciddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPScxODY0MSd9LFsnODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfSxbJzEwNjQ2J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nMTA2NDYnfX19LFsnU3BlY3RyYWwgUmlkZXInXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJ3BvdGlvbiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3BvdGlvblR5cGUnXT0nc3RvbmVzaGllbGRQb3Rpb24nfX19LFsnSW5mZWN0aW91cyBTa2l0dGVyZXInXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWyd1dGlsaXR5VHlwZSddPScxODY0MSd9LFsnODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsnMTA2NDYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ3V0aWxpdHlUeXBlJ109JzEwNjQ2J319fSxbJ1Zlbm9tIFN0YWxrZXInXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nMTg2NDEnfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2J30sWycxMDY0NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109JzEwNjQ2J319fX0sWydib3NzZXMnXT17WydHcmFuZCBXaWRvdyBGYWVybGluYSddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1sncmVja2xlc3NuZXNzJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsndHJpbmtldDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWydnZWFyc3dhcCddPXtbJ2VuYWJsZWQnXT10cnVlLFsncG9zdENvbWJhdFN3YXAnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWydpdGVtUmFja1NldCddPSdQYXBlcicsWydwb3N0Q29tYmF0U2V0J109J1RhbmsnfSxbJ3V0aWxpdHknXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWyd0cmlua2V0MiddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd1dGlsaXR5VHlwZSddPScxODY0MSd9LFsnMTA2NDYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3V0aWxpdHlUeXBlJ109JzEwNjQ2J319fSxbJ1RoYWRkaXVzJ109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17WydnZWFyc3dhcCddPXtbJ2VuYWJsZWQnXT10cnVlLFsncG9zdENvbWJhdFN3YXAnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWydwb3N0Q29tYmF0U2V0J109J1VEQycsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTkwLFsnaXRlbVJhY2tTZXQnXT0nUGFwZXInLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9fX0sWydHbHV0aCddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPScxODY0MScsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWyd0cmlua2V0MSddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd0dGtWYWx1ZSddPTIsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ2J1ZmZSZW1haW5pbmdWYWx1ZSddPTE2LFsndHJpZ2dlclR5cGUnXT0ndHRrJ30sWyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd1dGlsaXR5VHlwZSddPSc4OTU2J30sWycxMzE4MCddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsndXRpbGl0eVR5cGUnXT0nMTMxODAnfSxbJ3BvdGlvbiddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT05MCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsncG90aW9uVHlwZSddPSdtaWdodHlSYWdlUG90aW9uJ30sWydkZWF0aHdpc2gnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J3R0aycsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsndHRrVmFsdWUnXT0zM30sWycxMDY0NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsndXRpbGl0eVR5cGUnXT0nMTA2NDYnfSxbJ3RyaW5rZXQyJ109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsndXRpbGl0eSddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT05MCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfX19LFsnR290aGlrIHRoZSBIYXJ2ZXN0ZXInXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJ2dlYXJzd2FwJ109e1snZW5hYmxlZCddPXRydWUsWydwb3N0Q29tYmF0U3dhcCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3Bvc3RDb21iYXRTZXQnXT0nUGFwZXIgQ2xhdyd9fX0sWydHcm9iYnVsdXMnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd1dGlsaXR5VHlwZSddPScxODY0MSd9LFsnMTMxODAnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3V0aWxpdHlUeXBlJ109JzEzMTgwJ30sWyd0cmlua2V0MSddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfSxbJ3RyaW5rZXQyJ109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsndXRpbGl0eSddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT05MCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfSxbJ2dlYXJzd2FwJ109e1snZW5hYmxlZCddPXRydWUsWydwb3N0Q29tYmF0U3dhcCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydwb3N0Q29tYmF0U2V0J109J1BhcGVyJyxbJ2l0ZW1SYWNrU2V0J109J1BhcGVyJyxbJ2dlYXJTZXQnXT0nUGFwZXInfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2JyxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfSxbJzEwNjQ2J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd1dGlsaXR5VHlwZSddPScxMDY0Nid9fX0sWydJbnN0cnVjdG9yIFJhenV2aW91cyddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3V0aWxpdHlUeXBlJ109JzE4NjQxJ30sWyd0cmlua2V0MSddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0ndHRrJyxbJ2hwVmFsdWUnXT0yMCxbJ2J1ZmZSZW1haW5pbmdWYWx1ZSddPTE2LFsndHRrVmFsdWUnXT0yfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2JyxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfSxbJzEzMTgwJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nMTMxODAnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsncG90aW9uJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydwb3Rpb25UeXBlJ109J21pZ2h0eVJhZ2VQb3Rpb24nLFsnaHBWYWx1ZSddPTIwfSxbJ3RyaW5rZXQyJ109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsnZ2VhcnN3YXAnXT17WydpdGVtUmFja1NldCddPSdQYXBlcicsWydwb3N0Q29tYmF0U3dhcCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ2VuYWJsZWQnXT10cnVlLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT05MCxbJ3Bvc3RDb21iYXRTZXQnXT0nVGFuaycsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50J30sWydkZWF0aHdpc2gnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J3R0aycsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3R0a1ZhbHVlJ109MzMsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWydyZWNrbGVzc25lc3MnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2J1ZmZfcmVtYWluaW5nJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MjAsWydidWZmUmVtYWluaW5nVmFsdWUnXT0xNn0sWyd1dGlsaXR5J109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTkwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9fX0sWydMb2F0aGViJ109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17WycxODY0MSddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3V0aWxpdHlUeXBlJ109JzE4NjQxJ30sWyd0cmlua2V0MiddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJ3RyaW5rZXQxJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3R0a1ZhbHVlJ109MixbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYnVmZlJlbWFpbmluZ1ZhbHVlJ109MTcsWyd0cmlnZ2VyVHlwZSddPSd0dGsnfSxbJ2RlYXRod2lzaCddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0ndHRrJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3R0a1ZhbHVlJ109MzN9LFsncG90aW9uJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydwb3Rpb25UeXBlJ109J21pZ2h0eVJhZ2VQb3Rpb24nLFsnaHBWYWx1ZSddPTIwfSxbJ2dlYXJzd2FwJ109e1snZW5hYmxlZCddPXRydWUsWydwb3N0Q29tYmF0U3dhcCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3Bvc3RDb21iYXRTZXQnXT0nVURDJ30sWyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd1dGlsaXR5VHlwZSddPSc4OTU2J30sWyd1dGlsaXR5J109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTkwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9fX0sWydLZWxcJ1RodXphZCddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3V0aWxpdHlUeXBlJ109JzE4NjQxJ30sWycxMzE4MCddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsndXRpbGl0eVR5cGUnXT0nMTMxODAnfSxbJ3RyaW5rZXQxJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYnVmZlJlbWFpbmluZ1ZhbHVlJ109MzAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWyd0cmlua2V0MiddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJ3V0aWxpdHknXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWydkZWF0aHdpc2gnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWydwb3Rpb24nXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3BvdGlvblR5cGUnXT0nbWlnaHR5UmFnZVBvdGlvbicsWydocFZhbHVlJ109MjB9LFsnMTA2NDYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPScxMDY0NicsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ319fSxbJ01hZXh4bmEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJ3RyaW5rZXQxJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3R0a1ZhbHVlJ109MixbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYnVmZlJlbWFpbmluZ1ZhbHVlJ109MTYsWyd0cmlnZ2VyVHlwZSddPSd0dGsnfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2JyxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfSxbJ3NoaWVsZHdhbGwnXT17WydlbmFibGVkJ109ZmFsc2UsWydwbGF5ZXJIcFZhbHVlJ109MjAsWyd0cmlnZ2VyVHlwZSddPSdwbGF5ZXJfaHAnfSxbJ3BvdGlvbiddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109ZmFsc2UsWydocFZhbHVlJ109OTAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3BvdGlvblR5cGUnXT0nbWlnaHR5UmFnZVBvdGlvbid9LFsnZ2VhcnN3YXAnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3Bvc3RDb21iYXRTd2FwJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTkwLFsnaXRlbVJhY2tTZXQnXT0nUGFwZXInLFsncG9zdENvbWJhdFNldCddPSdUYW5rJ30sWydsYXN0c3RhbmQnXT17WydlbmFibGVkJ109ZmFsc2UsWydwbGF5ZXJIcFZhbHVlJ109MzAsWyd0cmlnZ2VyVHlwZSddPSdwbGF5ZXJfaHAnfSxbJ3RyaW5rZXQyJ109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsnZGVhdGh3aXNoJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsndXRpbGl0eSddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT05MCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfX19LFsnRm91ciBIb3JzZW1lbiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1sndXRpbGl0eSddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT05MCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfSxbJ3RyaW5rZXQxJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsnZ2VhcnN3YXAnXT17WydpdGVtUmFja1NldCddPSdQYXBlcicsWydwb3N0Q29tYmF0U3dhcCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ3Bvc3RDb21iYXRTZXQnXT0nUGFwZXIgQ2xhdycsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTkwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWydlbmFibGVkJ109dHJ1ZX0sWydkZWF0aHdpc2gnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWydwb3Rpb24nXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3BvdGlvblR5cGUnXT0nbWlnaHR5UmFnZVBvdGlvbid9LFsnODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsndXRpbGl0eVR5cGUnXT0nODk1Nid9LFsnMTA2NDYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3V0aWxpdHlUeXBlJ109JzEwNjQ2J319fSxbJ1BhdGNod2VyayddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPScxODY0MScsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWyd0cmlua2V0MSddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd0dGtWYWx1ZSddPTIsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTkwLFsnYnVmZlJlbWFpbmluZ1ZhbHVlJ109MTYsWyd0cmlnZ2VyVHlwZSddPSd0dGsnfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfSxbJ3V0aWxpdHknXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWycxMzE4MCddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsndXRpbGl0eVR5cGUnXT0nMTMxODAnfSxbJ3BvdGlvbiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsncG90aW9uVHlwZSddPSdtaWdodHlSYWdlUG90aW9uJyxbJ2hwVmFsdWUnXT0yMH0sWyd0cmlua2V0MiddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJ3JlY2tsZXNzbmVzcyddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2J1ZmZfcmVtYWluaW5nJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MjAsWydidWZmUmVtYWluaW5nVmFsdWUnXT0xNX0sWydkZWF0aHdpc2gnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J3R0aycsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTkwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd0dGtWYWx1ZSddPTMzfSxbJ2dlYXJzd2FwJ109e1snZW5hYmxlZCddPXRydWUsWydwb3N0Q29tYmF0U3dhcCddPXRydWUsWydwb3N0Q29tYmF0U2V0J109J1BhcGVyIENsYXcnLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTkwLFsnaXRlbVJhY2tTZXQnXT0nUGFwZXInLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsnMTA2NDYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3V0aWxpdHlUeXBlJ109JzEwNjQ2J319fSxbJ0FudWJcJ1Jla2hhbiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1sndHJpbmtldDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd1dGlsaXR5VHlwZSddPSc4OTU2J30sWydzaGllbGR3YWxsJ109e1snZW5hYmxlZCddPWZhbHNlLFsncGxheWVySHBWYWx1ZSddPTIwLFsndHJpZ2dlclR5cGUnXT0ncGxheWVyX2hwJyxbJ2VuYWJsZVRUUyddPWZhbHNlfSxbJ3BvdGlvbiddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2FiaWxpdHlfcmVhZHknLFsnZW5hYmxlVFRTJ109ZmFsc2UsWydocFZhbHVlJ109MjAsWydwb3Rpb25UeXBlJ109J3N0b25lc2hpZWxkUG90aW9uJ30sWyd0cmlua2V0MiddPXtbJ2VuYWJsZWQnXT1mYWxzZX0sWydkZWF0aHdpc2gnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWydsYXN0c3RhbmQnXT17WydlbmFibGVkJ109ZmFsc2UsWydocFZhbHVlJ109MjAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPWZhbHNlfSxbJ2dlYXJzd2FwJ109e1snZW5hYmxlZCddPXRydWUsWydwb3N0Q29tYmF0U3dhcCddPXRydWUsWydwb3N0Q29tYmF0U2V0J109J1RhbmsnLFsnZW5hYmxlVFRTJ109ZmFsc2UsWydocFZhbHVlJ109OTAsWydpdGVtUmFja1NldCddPSdQYXBlcicsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ2dlYXJTZXQnXT0nUGFwZXInLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsndXRpbGl0eSddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTkwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9fX0sWydTYXBwaGlyb24nXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nMTg2NDEnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsnMTYwMjMnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsnY29tYmF0U3RhcnREZWxheSddPTEyLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT05MCxbJ3V0aWxpdHlUeXBlJ109JzE2MDIzJyxbJ3RyaWdnZXJUeXBlJ109J2NvbWJhdF9zdGFydCd9LFsndHJpbmtldDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT05NSxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfSxbJzEzMTgwJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nMTMxODAnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsncG90aW9uJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdjb21iYXRfc3RhcnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3BvdGlvblR5cGUnXT0nbGltaXRlZEludnVsbmVyYWJpbGl0eVBvdGlvbicsWydjb21iYXRTdGFydERlbGF5J109NixbJ2hwVmFsdWUnXT0yMH0sWydnZWFyc3dhcCddPXtbJ2VuYWJsZWQnXT10cnVlLFsncG9zdENvbWJhdFN3YXAnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTkwLFsncG9zdENvbWJhdFNldCddPSdQYXBlcicsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWycxMDY0NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnLFsndXRpbGl0eVR5cGUnXT0nMTA2NDYnfSxbJ3JlY2tsZXNzbmVzcyddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0nYnVmZl9yZW1haW5pbmcnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT05MCxbJ2J1ZmZSZW1haW5pbmdWYWx1ZSddPTI2LFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsnZGVhdGh3aXNoJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsndXRpbGl0eSddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT05MCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfX19LFsnTm90aCB0aGUgUGxhZ3VlYnJpbmdlciddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWyd1dGlsaXR5VHlwZSddPScxODY0MScsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWyd0cmlua2V0MSddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0ndHRrJyxbJ2VuYWJsZVRUUyddPXRydWUsWydwbGF5ZXJIcFZhbHVlJ109MTAwLFsnYnVmZlJlbWFpbmluZ1ZhbHVlJ109MTYsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3R0a1ZhbHVlJ109MixbJ2J1ZmZOYW1lJ109J0RlYXRoIFdpc2gnLFsnaHBWYWx1ZSddPTc3fSxbJ3BvdGlvbiddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109ZmFsc2UsWydocFZhbHVlJ109MjAsWydwb3Rpb25UeXBlJ109J21pZ2h0eVJhZ2VQb3Rpb24nfSxbJ2RlYXRod2lzaCddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0ndHRrJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109ODAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3R0a1ZhbHVlJ109MzN9LFsndHJpbmtldDInXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50J30sWydnZWFyc3dhcCddPXtbJ2VuYWJsZWQnXT10cnVlLFsncG9zdENvbWJhdFN3YXAnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWydpdGVtUmFja1NldCddPSdQYXBlcicsWydwb3N0Q29tYmF0U2V0J109J1BhcGVyJ30sWyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZScsWyd1dGlsaXR5VHlwZSddPSc4OTU2J30sWyd1dGlsaXR5J109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTkwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9fX0sWydIZWlnYW4gdGhlIFVuY2xlYW4nXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdhYmlsaXR5X3JlYWR5JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109OTAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3V0aWxpdHlUeXBlJ109JzE4NjQxJ30sWyd0cmlua2V0MSddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2JyxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfSxbJ3NoaWVsZHdhbGwnXT17WydlbmFibGVkJ109ZmFsc2UsWydwbGF5ZXJIcFZhbHVlJ109MjAsWyd0cmlnZ2VyVHlwZSddPSdwbGF5ZXJfaHAnfSxbJzEzMTgwJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nMTMxODAnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsncG90aW9uJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdjb21iYXRfc3RhcnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3BvdGlvblR5cGUnXT0nbGltaXRlZEludnVsbmVyYWJpbGl0eVBvdGlvbicsWydjb21iYXRTdGFydERlbGF5J109NSxbJ2hwVmFsdWUnXT0yMH0sWyd0cmlua2V0MiddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJ2dlYXJzd2FwJ109e1snZW5hYmxlZCddPXRydWUsWydwb3N0Q29tYmF0U3dhcCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJyxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT05MCxbJ2l0ZW1SYWNrU2V0J109J1BhcGVyJyxbJ3Bvc3RDb21iYXRTZXQnXT0nVURDJ30sWydsYXN0c3RhbmQnXT17WydlbmFibGVkJ109ZmFsc2UsWydwbGF5ZXJIcFZhbHVlJ109MzAsWyd0cmlnZ2VyVHlwZSddPSdwbGF5ZXJfaHAnLFsnZW5hYmxlVFRTJ109ZmFsc2V9LFsnZGVhdGh3aXNoJ109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT1mYWxzZSxbJ2hwVmFsdWUnXT0xMDAsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWyd1dGlsaXR5J109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTkwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9fX19fSxbJ3Byb2ZpbGVOYW1lJ109J0RQUy1TcGVlZCd9"
            }
        },
        ["Temple of Ahn'Qiraj"] = {
            {
                name = "DPS (by Zac)",
                description = RCL["DPS profile for AQ40. Includes weapon stone reminders and cooldown usage."],
                data = "WR1:e1sndmVyc2lvbiddPTEsWydyYWlkTmFtZSddPSdUZW1wbGUgb2YgQWhuXCdRaXJhaicsWydhZGRvbiddPSdXYXJyaW9yUmVtaW5kZXInLFsndGltZXN0YW1wJ109MTc2NzA1MzMyNCxbJ2RhdGEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyYXNoJ109e1snVmVrbmlzcyBTdGluZ2VyJ109e1snZW5hYmxlZCddPWZhbHNlLFsnYWJpbGl0aWVzJ109e1snODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfX19LFsnVmVrbmlzcyBCb3JlciddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfX19LFsnUWlyYWppIFNsYXllciddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0nZmFkZScsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3RyaWdnZXJUeXBlJ109J2FiaWxpdHlfcmVhZHknLFsndXRpbGl0eVR5cGUnXT0nMTg2NDEnfSxbJ3BvdGlvbiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0nYWJpbGl0eV9yZWFkeScsWydlbmFibGVUVFMnXT10cnVlLFsncG90aW9uVHlwZSddPSdzdG9uZXNoaWVsZFBvdGlvbicsWydocFZhbHVlJ109MjB9LFsnZGVhdGh3aXNoJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J2ZhZGUnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50J30sWyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J2ZhZGUnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfSxbJzEwNjQ2J109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J2ZhZGUnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdhYmlsaXR5X3JlYWR5JyxbJ3V0aWxpdHlUeXBlJ109JzEwNjQ2J319fSxbJ1Zla25pc3MgRHJvbmUnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2J319fSxbJ1Zla25pc3MgU29sZGllciddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfX19LFsnUWlyYWppIExhc2hlciddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdmYWRlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWyd1dGlsaXR5VHlwZSddPSc4OTU2J319fSxbJ0FudWJpc2F0aCBEZWZlbmRlciddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfX19LFsnQW51YmlzYXRoIEd1YXJkaWFuJ109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17Wyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nODk1Nid9fX0sWydRaXJhamkgTWluZHNsYXllciddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snMTg2NDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0nZmFkZScsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3RyaWdnZXJUeXBlJ109J2FiaWxpdHlfcmVhZHknLFsndXRpbGl0eVR5cGUnXT0nMTg2NDEnfSxbJ3BvdGlvbiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0nYWJpbGl0eV9yZWFkeScsWydlbmFibGVUVFMnXT10cnVlLFsncG90aW9uVHlwZSddPSdzdG9uZXNoaWVsZFBvdGlvbicsWydocFZhbHVlJ109MjB9LFsnZGVhdGh3aXNoJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J2ZhZGUnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50J30sWyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J2ZhZGUnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfSxbJzEwNjQ2J109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J2ZhZGUnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdhYmlsaXR5X3JlYWR5JyxbJ3V0aWxpdHlUeXBlJ109JzEwNjQ2J319fSxbJ0FudWJpc2F0aCBTZW50aW5lbCddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1sndHJpbmtldDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0nZmFkZScsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJ2RlYXRod2lzaCddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdmYWRlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsndHJpbmtldDInXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0nZmFkZScsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2J30sWycxMDY0NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdmYWRlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWyd1dGlsaXR5VHlwZSddPScxMDY0Nid9fX0sWydRaXJhamkgQnJhaW53YXNoZXInXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FuaW1hdGlvblR5cGUnXT0nZmFkZScsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsndXRpbGl0eVR5cGUnXT0nODk1Nid9fX0sWydRaXJhamkgV2FycmlvciddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdmYWRlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWyd1dGlsaXR5VHlwZSddPSc4OTU2J319fSxbJ1Zla25pc3MgSGF0Y2hsaW5nJ109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17Wyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nODk1Nid9fX0sWydRaXJhamkgQ2hhbXBpb24nXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzE4NjQxJ109e1snZW5hYmxlZCddPXRydWUsWydhbmltYXRpb25UeXBlJ109J2ZhZGUnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdhYmlsaXR5X3JlYWR5JyxbJ3V0aWxpdHlUeXBlJ109JzE4NjQxJ30sWydwb3Rpb24nXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2FiaWxpdHlfcmVhZHknLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3BvdGlvblR5cGUnXT0nc3RvbmVzaGllbGRQb3Rpb24nLFsnaHBWYWx1ZSddPTIwfSxbJ2RlYXRod2lzaCddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdmYWRlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsnODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdmYWRlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWyd1dGlsaXR5VHlwZSddPSc4OTU2J30sWycxMDY0NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYW5pbWF0aW9uVHlwZSddPSdmYWRlJyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0nYWJpbGl0eV9yZWFkeScsWyd1dGlsaXR5VHlwZSddPScxMDY0Nid9fX0sWydWZWtuaXNzIFdhc3AnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2J319fSxbJ1Zla25pc3MgV2FycmlvciddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1snODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfX19LFsnVmVrbmlzcyBIaXZlIENyYXdsZXInXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2J319fSxbJ1Zla25pc3MgR3VhcmRpYW4nXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2J319fSxbJ0FudWJpc2F0aCBXYXJkZXInXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2J319fX0sWydib3NzZXMnXT17WydUaGUgUHJvcGhldCBTa2VyYW0nXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJ3RyaW5rZXQxJ109e1snZW5hYmxlZCddPXRydWUsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlfSxbJ2dlYXJzd2FwJ109e1snZW5hYmxlZCddPXRydWUsWydwb3N0Q29tYmF0U3dhcCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydwb3N0Q29tYmF0U2V0J109J1BhcGVyIENsYXcnLFsnaXRlbVJhY2tTZXQnXT0nUGFwZXInLFsnZ2VhclNldCddPSdQYXBlcid9LFsnZGVhdGh3aXNoJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsnODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnfSxbJ3RyaW5rZXQyJ109e1snZW5hYmxlZCddPWZhbHNlLFsnaHBWYWx1ZSddPTIwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9fX0sWydQcmluY2VzcyBIdWh1cmFuJ109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17WycxNjAyMyddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTcwLFsndXRpbGl0eVR5cGUnXT0nMTYwMjMnfSxbJ3RyaW5rZXQxJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSd0dGsnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0yMCxbJ2J1ZmZSZW1haW5pbmdWYWx1ZSddPTE2LFsndHRrVmFsdWUnXT0yfSxbJ2RlYXRod2lzaCddPXtbJ2VuYWJsZWQnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJ2dlYXJzd2FwJ109e1snZW5hYmxlZCddPXRydWUsWydwb3N0Q29tYmF0U3dhcCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydwb3N0Q29tYmF0U2V0J109J1BhcGVyJyxbJ2l0ZW1SYWNrU2V0J109J1BhcGVyJyxbJ2dlYXJTZXQnXT0nUGFwZXInfSxbJ3RyaW5rZXQyJ109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsnODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsndXRpbGl0eSddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9fX0sWydGYW5rcmlzcyB0aGUgVW55aWVsZGluZyddPXtbJ2VuYWJsZWQnXT10cnVlLFsnYWJpbGl0aWVzJ109e1sndHJpbmtldDEnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2VuYWJsZVRUUyddPXRydWUsWyd0dGtWYWx1ZSddPTIsWyd0cmlnZ2VyVHlwZSddPSd0dGsnfSxbJ3RyaW5rZXQyJ109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0nYnVmZl9yZW1haW5pbmcnLFsnZW5hYmxlVFRTJ109ZmFsc2UsWydocFZhbHVlJ109MjAsWydidWZmUmVtYWluaW5nVmFsdWUnXT0xNn0sWydnZWFyc3dhcCddPXtbJ2VuYWJsZWQnXT10cnVlLFsncG9zdENvbWJhdFN3YXAnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsncG9zdENvbWJhdFNldCddPSdQYXBlcicsWydpdGVtUmFja1NldCddPSdQYXBlcicsWydnZWFyU2V0J109J1BhcGVyJ30sWydkZWF0aHdpc2gnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50J30sWyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nODk1NicsWydhbmltYXRpb25UeXBlJ109J3B1bHNlJ30sWyd1dGlsaXR5J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50J319fSxbJ091cm8nXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJ3RyaW5rZXQxJ109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSd0dGsnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0yMCxbJ2J1ZmZSZW1haW5pbmdWYWx1ZSddPTE2LFsndHRrVmFsdWUnXT0yfSxbJ2RlYXRod2lzaCddPXtbJ2VuYWJsZWQnXT10cnVlLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J3R0aycsWyd0dGtWYWx1ZSddPTMzfSxbJ2dlYXJzd2FwJ109e1snZW5hYmxlZCddPXRydWUsWydwb3N0Q29tYmF0U3dhcCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydwb3N0Q29tYmF0U2V0J109J1BhcGVyJyxbJ2l0ZW1SYWNrU2V0J109J1BhcGVyJyxbJ2dlYXJTZXQnXT0nUGFwZXInfSxbJ3RyaW5rZXQyJ109e1snZW5hYmxlZCddPWZhbHNlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9LFsnODk1NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109Jzg5NTYnLFsnYW5pbWF0aW9uVHlwZSddPSdwdWxzZSd9LFsndXRpbGl0eSddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9fX0sWydTaWxpdGhpZCBSb3lhbHR5J109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17Wyc4OTU2J109e1snZW5hYmxlZCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydocFZhbHVlJ109MTAwLFsndXRpbGl0eVR5cGUnXT0nODk1Nid9LFsnZ2VhcnN3YXAnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3Bvc3RDb21iYXRTd2FwJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ3Bvc3RDb21iYXRTZXQnXT0nUGFwZXIgQ2xhdycsWydpdGVtUmFja1NldCddPSdQYXBlcicsWydnZWFyU2V0J109J1BhcGVyJ319fSxbJ1R3aW4gRW1wZXJvcnMnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2FiaWxpdGllcyddPXtbJ3RyaW5rZXQxJ109e1snZW5hYmxlZCddPXRydWUsWydocFZhbHVlJ109MjAsWyd0cmlnZ2VyVHlwZSddPSdhYmlsaXR5X3JlYWR5JyxbJ2VuYWJsZVRUUyddPXRydWV9LFsndHJpbmtldDInXT17WydlbmFibGVkJ109ZmFsc2UsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50J30sWydnZWFyc3dhcCddPXtbJ2VuYWJsZWQnXT10cnVlLFsncG9zdENvbWJhdFN3YXAnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsncG9zdENvbWJhdFNldCddPSdUYW5rJyxbJ2l0ZW1SYWNrU2V0J109J1BhcGVyJyxbJ2dlYXJTZXQnXT0nUGFwZXInfSxbJ2RlYXRod2lzaCddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0nYWJpbGl0eV9yZWFkeSd9LFsndXRpbGl0eSddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCd9fX0sWydCYXR0bGVndWFyZCBTYXJ0dXJhJ109e1snZW5hYmxlZCddPXRydWUsWydhYmlsaXRpZXMnXT17WydyZWNrbGVzc25lc3MnXT17WydlbmFibGVkJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50J30sWycxMDY0NiddPXtbJ2VuYWJsZWQnXT10cnVlLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3V0aWxpdHlUeXBlJ109JzEwNjQ2JyxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfSxbJ3RyaW5rZXQxJ109e1snZW5hYmxlZCddPXRydWUsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlfSxbJ2dlYXJzd2FwJ109e1snZW5hYmxlZCddPXRydWUsWydwb3N0Q29tYmF0U3dhcCddPXRydWUsWyd0cmlnZ2VyVHlwZSddPSdocF9wZXJjZW50JyxbJ2VuYWJsZVRUUyddPXRydWUsWydwb3N0Q29tYmF0U2V0J109J1BhcGVyJyxbJ2l0ZW1SYWNrU2V0J109J1BhcGVyJyxbJ2dlYXJTZXQnXT0nUGFwZXInfSxbJ3RyaW5rZXQyJ109e1snZW5hYmxlZCddPXRydWUsWydocFZhbHVlJ109MTAwLFsndHJpZ2dlclR5cGUnXT0naHBfcGVyY2VudCcsWydlbmFibGVUVFMnXT10cnVlfSxbJ2RlYXRod2lzaCddPXtbJ2VuYWJsZWQnXT10cnVlLFsnaHBWYWx1ZSddPTEwMCxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfSxbJzg5NTYnXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnLFsnZW5hYmxlVFRTJ109dHJ1ZSxbJ2hwVmFsdWUnXT0xMDAsWyd1dGlsaXR5VHlwZSddPSc4OTU2JyxbJ2FuaW1hdGlvblR5cGUnXT0ncHVsc2UnfSxbJ3V0aWxpdHknXT17WydlbmFibGVkJ109dHJ1ZSxbJ3RyaWdnZXJUeXBlJ109J2hwX3BlcmNlbnQnfX19LFsnQ1wnVGh1biddPXtbJ2VuYWJsZWQnXT1mYWxzZSxbJ2FiaWxpdGllcyddPXt9fX19LFsncHJvZmlsZU5hbWUnXT0nRGVmYXVsdCd9"
            }
        }
    }

    -- Theme defaults, grouped by UI area. RC:GetColor(category, key) returns
    -- db.customColors[category][key] if the user overrode it, else this.
    RC.defaultColors = {

        ui = {
            windowBackground = {r = 0.08, g = 0.08, b = 0.08, a = 0.95, label = RCL["Main Window BG"]},
            elementBackground = {r = 0.12, g = 0.12, b = 0.12, a = 1, label = RCL["Headers/Panels BG"]},
            cardBackground = {r = 0.10, g = 0.10, b = 0.10, a = 1, label = RCL["Settings Cards BG"]},
            headerBackground = {r = 0.12, g = 0.12, b = 0.12, a = 1, label = RCL["Title Bar BG"]},

            borderNormal = {r = 0, g = 0, b = 0, a = 1, label = RCL["Default Border"]},
            borderHover = {r = 0.85, g = 0.65, b = 0.25, a = 1, label = RCL["Hover Border"]},
            borderSelected = {r = 0.32, g = 0.62, b = 0.38, a = 1, label = RCL["Selected/Active"]},
            configured = {r = 0.25, g = 0.9, b = 0.25, a = 1, label = RCL["Configured (green)"]},

            accentGold = {r = 0.85, g = 0.65, b = 0.25, a = 0.6, label = RCL["Accent Lines"]},
            accentGreen = {r = 0.35, g = 0.6, b = 0.35, a = 1, label = RCL["Success Accent"]},
            insertionLine = {r = 0.3, g = 0.8, b = 1, a = 1, label = RCL["Drag Insert Line"]},
            headerText = {r = 1, g = 0.82, b = 0, a = 1, label = RCL["Titles/Headers"]},
            -- the "Readycheck" name and the highlights in chat messages
            chatBrand = {r = 1, g = 0.82, b = 0, a = 1, label = RCL["Chat Messages"]},
            headerAccent = {r = 0.85, g = 0.65, b = 0.25, a = 0.6, label = RCL["Header Underline"]},
            -- The right-hand end of a title bar's fill. Until you set it,
            -- it is derived from the title bar BG and the accent
            -- (UIF_Widgets); this is only the default swatch.
            headerGradient = {r = 0.41, g = 0.33, b = 0.17, a = 1, label = RCL["Title Bar Gradient"]},
            -- the halo around a reminder icon, and its 1px ring
            -- (UIF_Widgets DressReadyIcon)
            readyGlow = {r = 0.85, g = 0.65, b = 0.25, a = 1, label = RCL["Reminder Icon Glow"]},
            readyBorder = {r = 0.85, g = 0.65, b = 0.25, a = 1, label = RCL["Reminder Icon Border"]},
            closeX = {r = 0.7, g = 0.7, b = 0.7, a = 1, label = RCL["Close X Normal"]},
            closeXHover = {r = 0.9, g = 0.3, b = 0.3, a = 1, label = RCL["Close X Hover"]},
        },

        buttons = {
            normalBackground = {r = 0.12, g = 0.12, b = 0.12, a = 1, label = RCL["Normal BG"]},
            hoverBackground = {r = 0.18, g = 0.18, b = 0.18, a = 1, label = RCL["Hover BG"]},
            pressedBackground = {r = 0.06, g = 0.06, b = 0.06, a = 1, label = RCL["Pressed BG"]},
            disabledBackground = {r = 0.08, g = 0.08, b = 0.08, a = 0.6, label = RCL["Disabled BG"]},
            configuredBackground = {r = 0.10, g = 0.18, b = 0.12, a = 1, label = RCL["Active/Selected BG"]},
            configuredHover = {r = 0.13, g = 0.23, b = 0.15, a = 1, label = RCL["Active Hover BG"]},

            closeNormal = {r = 0.9, g = 0.2, b = 0.2, a = 1, label = RCL["Red X Color"]},
            closeHover = {r = 1, g = 0.4, b = 0.4, a = 1, label = RCL["Red X Hover"]},
            xNormal = {r = 0.7, g = 0.7, b = 0.7, a = 1, label = RCL["Simple X Normal"]},
            xHover = {r = 0.9, g = 0.3, b = 0.3, a = 1, label = RCL["Simple X Hover"]},
        },

        sidebar = {
            background = {r = 0.07, g = 0.07, b = 0.07, a = 1, label = RCL["Menu BG"]},
            buttonNormal = {r = 0.12, g = 0.12, b = 0.12, a = 1, label = RCL["Item Normal"]},
            buttonHover = {r = 0.18, g = 0.18, b = 0.18, a = 1, label = RCL["Item Hover"]},
            buttonSelected = {r = 0.10, g = 0.18, b = 0.12, a = 1, label = RCL["Item Selected"]},
            selectionIndicator = {r = 0.35, g = 0.70, b = 0.40, a = 1, label = RCL["Selection Bar"]},
        },

        checkbox = {
            background = {r = 0.1, g = 0.1, b = 0.1, a = 1, label = RCL["Background"]},
            border = {r = 0, g = 0, b = 0, a = 1, label = RCL["Border"]},
            -- gold, like the rest of the UI (Zac 2026-11-02); unpicked, the tick is
            -- the gold Checkmark art itself, untinted (UIF_Widgets PaintCheckbox)
            checkmark = {r = 0.85, g = 0.65, b = 0.25, a = 1, label = RCL["Checkmark"]},
            hoverBorder = {r = 0.85, g = 0.65, b = 0.25, a = 1, label = RCL["Hover Border"]},
        },

        dropdown = {
            background = {r = 0.12, g = 0.12, b = 0.12, a = 0.98, label = RCL["Background"]},
            itemHover = {r = 0.2, g = 0.18, b = 0.12, a = 1, label = RCL["Item Hover"]},
            itemText = {r = 0.9, g = 0.9, b = 0.9, a = 1, label = RCL["Item Text"]},
            arrow = {r = 0.8, g = 0.65, b = 0.35, a = 1, label = RCL["Arrow"]},
            selected = {r = 0.85, g = 0.65, b = 0.25, a = 1, label = RCL["Selected"]},
        },

        nameplate = {
            sunderLow = {r = 1, g = 0.25, b = 0.25, a = 1, label = RCL["Sunder 1 Stack"]},
            sunderHigh = {r = 0.3, g = 1, b = 0.3, a = 1, label = RCL["Sunder 5 Stacks"]},
            exposeArmor = {r = 0.3, g = 0.8, b = 1, a = 1, label = RCL["Expose Armor"]},
        },

        scrollbar = {
            track = {r = 0.08, g = 0.08, b = 0.08, a = 0.8, label = RCL["Track"]},
            thumb = {r = 0.6, g = 0.46, b = 0.18, a = 0.9, label = RCL["Thumb"]},
            arrowBackground = {r = 0.12, g = 0.12, b = 0.12, a = 1, label = RCL["Arrow BG"]},
            arrowBackgroundHover = {r = 0.18, g = 0.18, b = 0.18, a = 1, label = RCL["Arrow BG Hover"]},
            arrow = {r = 0.7, g = 0.7, b = 0.7, a = 1, label = RCL["Arrow Icon"]},
        },

        text = {
            normal = {r = 0.9, g = 0.9, b = 0.9, a = 1, label = RCL["Default"]},
            white = {r = 1, g = 1, b = 1, a = 1, label = RCL["Bright"]},
            gray = {r = 0.6, g = 0.6, b = 0.6, a = 1, label = RCL["Gray"]},
            gold = {r = 1, g = 0.82, b = 0, a = 1, label = RCL["Gold/Titles"]},

            green = {r = 0.5, g = 0.8, b = 0.5, a = 1, label = RCL["Success"]},
            red = {r = 1, g = 0.3, b = 0.3, a = 1, label = RCL["Error"]},
            orange = {r = 1, g = 0.6, b = 0.2, a = 1, label = RCL["Caution"]},
            yellow = {r = 1, g = 1, b = 0.3, a = 1, label = RCL["Warning"]},
            blue = {r = 0.4, g = 0.7, b = 1, a = 1, label = RCL["Info"]},
            -- Aliases several pages already look up; without them GetColor
            -- fell through to plain white and "dimmed" text read as bright.
            disabled = {r = 0.5, g = 0.5, b = 0.5, a = 1, label = RCL["Disabled"]},
            muted = {r = 0.5, g = 0.5, b = 0.5, a = 1, label = RCL["Muted"]},
            secondary = {r = 0.6, g = 0.6, b = 0.6, a = 1, label = RCL["Secondary"]},
            bright = {r = 1, g = 1, b = 1, a = 1, label = RCL["Bright Alias"]},
            success = {r = 0.5, g = 0.8, b = 0.5, a = 1, label = RCL["Success Alias"]},
            warning = {r = 1, g = 1, b = 0.3, a = 1, label = RCL["Warning Alias"]},

            buttonNormal = {r = 0.9, g = 0.9, b = 0.9, a = 1, label = RCL["Button Normal"]},
            buttonHover = {r = 1, g = 1, b = 0.9, a = 1, label = RCL["Button Hover"]},
            buttonDisabled = {r = 0.5, g = 0.5, b = 0.5, a = 1, label = RCL["Button Disabled"]},
            buttonActive = {r = 0.7, g = 0.9, b = 0.7, a = 1, label = RCL["Button Active"]},

            menuNormal = {r = 0.9, g = 0.9, b = 0.9, a = 1, label = RCL["Menu Normal"]},
            menuSelected = {r = 0.7, g = 0.9, b = 0.7, a = 1, label = RCL["Menu Selected"]},
            menuDisabled = {r = 0.5, g = 0.5, b = 0.5, a = 1, label = RCL["Menu Disabled"]},
            menuCategory = {r = 1, g = 0.82, b = 0, a = 1, label = RCL["Menu Category"]},
        },

        tooltip = {
            background = {r = 0.1, g = 0.1, b = 0.1, a = 0.95, label = RCL["Background"]},
            border = {r = 0, g = 0, b = 0, a = 1, label = RCL["Border"]},
            titleText = {r = 1, g = 0.82, b = 0, a = 1, label = RCL["Title"]},
            bodyText = {r = 0.9, g = 0.9, b = 0.9, a = 1, label = RCL["Body"]},
        },

        raids = {
            enabled = {r = 0.35, g = 0.6, b = 0.35, a = 1, label = RCL["Enabled Dot"]},
            disabled = {r = 0.5, g = 0.5, b = 0.5, a = 1, label = RCL["Disabled Dot"]},
            bossEnabled = {r = 0.10, g = 0.18, b = 0.12, a = 1, label = RCL["Boss Enabled BG"]},
            bossDisabled = {r = 0.15, g = 0.15, b = 0.15, a = 1, label = RCL["Boss Disabled BG"]},
            trashBackground = {r = 0.12, g = 0.12, b = 0.15, a = 1, label = RCL["Trash BG"]},
            abilityActive = {r = 0.10, g = 0.18, b = 0.12, a = 1, label = RCL["Ability Active"]},
            abilityInactive = {r = 0.15, g = 0.15, b = 0.15, a = 1, label = RCL["Ability Inactive"]},
        },

        consumables = {
            stockFull = {r = 0.4, g = 0.7, b = 0.4, a = 1, label = RCL["Full (Green)"]},
            stockMedium = {r = 1, g = 0.6, b = 0.2, a = 1, label = RCL["Medium (Orange)"]},
            stockLow = {r = 1, g = 1, b = 0.3, a = 1, label = RCL["Low (Yellow)"]},
            stockEmpty = {r = 1, g = 0.3, b = 0.3, a = 1, label = RCL["Empty (Red)"]},
            categoryHeader = {r = 0.9, g = 0.75, b = 0.5, a = 1, label = RCL["Category"]},
            hoverBorder = {r = 0.85, g = 0.65, b = 0.25, a = 1, label = RCL["Hover Border"]},
        },

        actionBars = {
            timeGood = {r = 0.5, g = 0.8, b = 0.5, a = 1, label = RCL["Time OK"]},
            timeWarning = {r = 1, g = 0.8, b = 0, a = 1, label = RCL["Time Warning"]},
            timeCritical = {r = 1, g = 0.2, b = 0.2, a = 1, label = RCL["Time Critical"]},

            itemBorder = {r = 0, g = 0, b = 0, a = 1, label = RCL["Item Border"]},
            itemNormalBg = {r = 0.1, g = 0.1, b = 0.1, a = 0.8, label = RCL["Item Normal"]},
            itemHoverBg = {r = 0.2, g = 0.2, b = 0.2, a = 0.9, label = RCL["Item Hover"]},
            itemActiveBg = {r = 0.15, g = 0.25, b = 0.15, a = 0.9, label = RCL["Item Active"]},
            itemCooldownBg = {r = 0.12, g = 0.12, b = 0.12, a = 0.7, label = RCL["On Cooldown"]},

            countNormal = {r = 1, g = 1, b = 1, a = 1, label = RCL["Count Normal"]},
            countLow = {r = 1, g = 0.3, b = 0.3, a = 1, label = RCL["Count Low"]},
        },

        weaponBar = {
            frameBackground = {r = 0.08, g = 0.08, b = 0.1, a = 0.95, label = RCL["Frame BG"]},
            frameBorder = {r = 0.5, g = 0.8, b = 1, a = 0.3, label = RCL["Frame Border"]},
            accentLine = {r = 0.5, g = 0.8, b = 1, a = 0.5, label = RCL["Accent Line"]},
            titleText = {r = 0.5, g = 0.8, b = 1, a = 1, label = RCL["Title"]},

            buttonBorder = {r = 0, g = 0, b = 0, a = 1, label = RCL["Button Border"]},
            buttonNormal = {r = 0.15, g = 0.15, b = 0.15, a = 1, label = RCL["Button Normal"]},
            buttonHover = {r = 0.22, g = 0.22, b = 0.22, a = 1, label = RCL["Button Hover"]},
            buttonSelected = {r = 0.12, g = 0.16, b = 0.12, a = 1, label = RCL["Button Selected"]},
            buttonSelectedBorder = {r = 0.85, g = 0.65, b = 0.25, a = 1, label = RCL["Selected Border"]},
            activeBorder = {r = 0.3, g = 0.9, b = 0.3, a = 1, label = RCL["Active Border"]},

            elementalStone = {r = 0.2, g = 0.7, b = 1, a = 1, label = RCL["Elemental"]},
            consecratedStone = {r = 1, g = 0.85, b = 0.4, a = 1, label = RCL["Consecrated"]},
            denseStone = {r = 0.7, g = 0.7, b = 0.7, a = 1, label = RCL["Dense"]},
            frostOil = {r = 0.4, g = 0.8, b = 1, a = 1, label = RCL["Frost Oil"]},

            slotMH = {r = 1, g = 0.8, b = 0.3, a = 1, label = RCL["Main Hand"]},
            slotOH = {r = 0.6, g = 0.8, b = 1, a = 1, label = RCL["Off Hand"]},
            slotBag = {r = 0.5, g = 0.8, b = 1, a = 1, label = RCL["Bag Weapon"]},
        },

        consumablesBar = {
            frameBackground = {r = 0.08, g = 0.08, b = 0.08, a = 0.95, label = RCL["Frame BG"]},
            frameBorder = {r = 0.5, g = 0.8, b = 1, a = 0.3, label = RCL["Frame Border"]},
            accentLine = {r = 0.5, g = 0.8, b = 1, a = 0.5, label = RCL["Accent Line"]},
            titleText = {r = 1, g = 0.88, b = 0.12, a = 1, label = RCL["Title"]},

            buttonBorder = {r = 0, g = 0, b = 0, a = 1, label = RCL["Button Border"]},
            buttonNormal = {r = 0.15, g = 0.15, b = 0.15, a = 1, label = RCL["Button Normal"]},
            buttonHover = {r = 0.22, g = 0.22, b = 0.22, a = 1, label = RCL["Button Hover"]},
            buttonActive = {r = 0.15, g = 0.25, b = 0.15, a = 1, label = RCL["Button Active"]},
            activeBorder = {r = 0.3, g = 0.9, b = 0.3, a = 1, label = RCL["Active Border"]},

            conflictBackground = {r = 0.3, g = 0.15, b = 0.1, a = 0.9, label = RCL["Conflict BG"]},
            conflictBorder = {r = 0.8, g = 0.4, b = 0.2, a = 1, label = RCL["Conflict Border"]},
            conflictText = {r = 1, g = 0.6, b = 0.4, a = 1, label = RCL["Conflict Text"]},

            gcdText = {r = 1, g = 1, b = 1, a = 1, label = RCL["GCD Text"]},
        },

        potionsBar = {
            frameBackground = {r = 0.08, g = 0.06, b = 0.08, a = 0.95, label = RCL["Frame BG"]},
            frameBorder = {r = 0.7, g = 0.5, b = 0.7, a = 0.3, label = RCL["Frame Border"]},
            accentLine = {r = 0.7, g = 0.5, b = 0.7, a = 0.5, label = RCL["Accent Line"]},
            titleText = {r = 1, g = 0.7, b = 0.9, a = 1, label = RCL["Title"]},

            buttonBorder = {r = 0, g = 0, b = 0, a = 1, label = RCL["Button Border"]},
            buttonNormal = {r = 0.15, g = 0.15, b = 0.15, a = 1, label = RCL["Button Normal"]},
            buttonHover = {r = 0.22, g = 0.22, b = 0.22, a = 1, label = RCL["Button Hover"]},
            buttonActive = {r = 0.15, g = 0.25, b = 0.15, a = 1, label = RCL["Button Active"]},
            activeBorder = {r = 0.3, g = 0.9, b = 0.3, a = 1, label = RCL["Active Border"]},

            expiryText = {r = 1, g = 1, b = 0, a = 1, label = RCL["Timer"]},
        },

        gearManager = {
            frameBackground = {r = 0.08, g = 0.08, b = 0.08, a = 0.95, label = RCL["Panel BG"]},
            frameBorder = {r = 0, g = 0, b = 0, a = 1, label = RCL["Panel Border"]},
            titleText = {r = 1, g = 0.82, b = 0, a = 1, label = RCL["Title"]},

            slotEmpty = {r = 0.2, g = 0.2, b = 0.2, a = 0.8, label = RCL["Empty Slot"]},
            slotFilled = {r = 0.12, g = 0.16, b = 0.12, a = 0.9, label = RCL["Filled Slot"]},
            slotHover = {r = 0.22, g = 0.22, b = 0.22, a = 1, label = RCL["Hover"]},
            slotHoverBorder = {r = 0.85, g = 0.65, b = 0.25, a = 1, label = RCL["Hover Border"]},

            setRowNormal = {r = 0.12, g = 0.12, b = 0.12, a = 1, label = RCL["Set Row Normal"]},
            setRowHover = {r = 0.18, g = 0.18, b = 0.18, a = 1, label = RCL["Set Row Hover"]},
            setRowActive = {r = 0.12, g = 0.16, b = 0.12, a = 1, label = RCL["Active Set"]},
        },

        trinketSwap = {
            iconDimmed     = {r = 0.7,  g = 0.7,  b = 0.7,  a = 0.85, label = RCL["Icon Dimmed"]},
            nameText       = {r = 0.85, g = 0.85, b = 0.85, a = 1,    label = RCL["Trinket Name"]},
            emptyText      = {r = 0.66, g = 0.66, b = 0.66, a = 1,    label = RCL["Empty Slot Text"]},
            emptyHintText  = {r = 0.50, g = 0.50, b = 0.50, a = 1,    label = RCL["Empty Slot Hint"]},

            buttonTextOn   = {r = 0.9,  g = 0.9,  b = 0.9,  a = 1,    label = RCL["Button Text Active"]},
            buttonTextOff  = {r = 0.7,  g = 0.7,  b = 0.7,  a = 1,    label = RCL["Button Text Inactive"]},

            statusActive       = {r = 0.2, g = 1,   b = 0.2, a = 1, label = RCL["Active (Green)"]},
            statusPaused       = {r = 0.3, g = 0.6, b = 1,   a = 1, label = RCL["Paused by Boss (Blue)"]},
            statusManualPause  = {r = 1,   g = 0.8, b = 0.2, a = 1, label = RCL["Manually Paused (Yellow)"]},
            statusDisabled     = {r = 0.8, g = 0.2, b = 0.2, a = 1, label = RCL["Disabled (Red)"]},
        },

        statsBar = {
            -- the panel grey (ui.elementBackground / headerBackground)
            background = {r = 0.12, g = 0.12, b = 0.12, a = 0.95, label = RCL["Background"]},
            labelText = {r = 0.6, g = 0.6, b = 0.6, a = 1, label = RCL["Labels"]},
            separator = {r = 0.3, g = 0.3, b = 0.3, a = 0.5, label = RCL["Separators"]},
        },

        ttkDisplay = {
            background = {r = 0.08, g = 0.08, b = 0.08, a = 0.9, label = RCL["Background"]},
            border = {r = 0, g = 0, b = 0, a = 1, label = RCL["Border"]},
            headerText = {r = 1, g = 0.82, b = 0, a = 1, label = RCL["Boss Name"]},
            labelText = {r = 0.6, g = 0.6, b = 0.6, a = 1, label = RCL["Labels"]},
            predictedText = {r = 0.4, g = 0.8, b = 1, a = 1, label = RCL["Predicted Time"]},
            realtimeText = {r = 0.4, g = 1, b = 0.4, a = 1, label = RCL["Real-time"]},
            paceFaster = {r = 0.3, g = 1, b = 0.3, a = 1, label = RCL["Pace Faster"]},
            paceSlower = {r = 1, g = 0.3, b = 0.3, a = 1, label = RCL["Pace Slower"]},
            paceNeutral = {r = 0.7, g = 0.7, b = 0.7, a = 1, label = RCL["Pace Neutral"]},
        },

        buffPushoffAlert = {
            text = {r = 1, g = 0.4, b = 0.4, a = 1, label = RCL["Alert Text"]},
            background = {r = 0.1, g = 0.1, b = 0.1, a = 0.8, label = RCL["Background"]},
            border = {r = 0.8, g = 0.3, b = 0.3, a = 1, label = RCL["Border"]},
        },

        battleShoutReminder = {
            normalBorder = {r = 0, g = 0, b = 0, a = 1, label = RCL["Normal Border"]},
            missingBorder = {r = 1, g = 0.3, b = 0.3, a = 1, label = RCL["Missing Border"]},
            missingText = {r = 1, g = 0.3, b = 0.3, a = 1, label = RCL["Missing Count"]},
            allBuffedText = {r = 0.3, g = 1, b = 0.3, a = 1, label = RCL["All Buffed"]},
            background = {r = 0.08, g = 0.08, b = 0.08, a = 0.9, label = RCL["Background"]},
        },

        battleShoutPartyTracker = {
            background      = {r = 0.06, g = 0.06, b = 0.06, a = 0.95, label = RCL["Background"]},
            border          = {r = 0,    g = 0,    b = 0,    a = 1,    label = RCL["Border"]},
            headerBackground= {r = 0.10, g = 0.10, b = 0.10, a = 1,    label = RCL["Header BG"]},
            titleText       = {r = 1,    g = 0.82, b = 0,    a = 1,    label = RCL["Title Text"]},
            apGood          = {r = 0.3,  g = 1,    b = 0.3,  a = 1,    label = RCL["AP Good"]},
            apWarning       = {r = 1,    g = 0.8,  b = 0.1,  a = 1,    label = RCL["AP Warning"]},
            apMissing       = {r = 1,    g = 0.3,  b = 0.3,  a = 1,    label = RCL["AP Missing"]},
            durationBar     = {r = 0.3,  g = 0.7,  b = 0.3,  a = 0.35, label = RCL["Duration Bar"]},
            rowBackground   = {r = 1,    g = 1,    b = 1,    a = 0.03, label = RCL["Row BG"]},
            bloodrageActive = {r = 1,    g = 0.25, b = 0.25, a = 1,    label = RCL["Bloodraging Name"]},
        },

        -- Shared by the raid buff and boss debuff tracker frames
        -- (Readycheck_Reminders\Reminders\AuraTracker.lua). Kept
        -- here so profiles carry the group whether or not that addon is
        -- loaded. Row text colours come from text.normal / text.warning /
        -- text.red.
        auraTracker = {
            background    = {r = 0.06, g = 0.06, b = 0.06, a = 0.9,  label = RCL["Background"]},
            border        = {r = 0,    g = 0,    b = 0,    a = 1,    label = RCL["Border"]},
            titleText     = {r = 1,    g = 0.82, b = 0,    a = 1,    label = RCL["Title Text"]},
            stackText     = {r = 1,    g = 1,    b = 1,    a = 1,    label = RCL["Stack Count"]},
            rowBackground = {r = 1,    g = 1,    b = 1,    a = 0.03, label = RCL["Row BG"]},
        },

        uiMover = {
            panelBackground = {r = 0.08, g = 0.08, b = 0.08, a = 0.95, label = RCL["Panel BG"]},
            panelBorder = {r = 0, g = 0, b = 0, a = 1, label = RCL["Panel Border"]},
            headerBackground = {r = 0.12, g = 0.12, b = 0.12, a = 1, label = RCL["Header BG"]},
            headerText = {r = 1, g = 0.82, b = 0, a = 1, label = RCL["Header Text"]},

            anchorBackground = {r = 1, g = 1, b = 1, a = 0.06, label = RCL["Anchor BG"]},
            anchorBorder = {r = 0.42, g = 0.42, b = 0.42, a = 1, label = RCL["Anchor Border"]},
            anchorSelected = {r = 0.85, g = 0.65, b = 0.25, a = 0.18, label = RCL["Anchor Selected"]},
            anchorSelectedBorder = {r = 0.85, g = 0.65, b = 0.25, a = 1, label = RCL["Selected Border"]},
            anchorText = {r = 1, g = 1, b = 1, a = 1, label = RCL["Anchor Label"]},
            anchorPosText = {r = 0.85, g = 0.65, b = 0.25, a = 1, label = RCL["Position Text"]},

            gridLine = {r = 1, g = 1, b = 1, a = 0.05, label = RCL["Grid Lines"]},
            gridCenter = {r = 0.85, g = 0.65, b = 0.25, a = 0.35, label = RCL["Center Lines"]},
            inputBackground = {r = 0.07, g = 0.07, b = 0.07, a = 1, label = RCL["Input BG"]},
            labelText = {r = 0.7, g = 0.7, b = 0.7, a = 1, label = RCL["Labels"]},

            buttonBackground = {r = 0.12, g = 0.12, b = 0.12, a = 1, label = RCL["Button BG"]},
            buttonBackgroundHover = {r = 0.18, g = 0.18, b = 0.18, a = 1, label = RCL["Button Hover"]},
            borderBlack = {r = 0, g = 0, b = 0, a = 1, label = RCL["Button Border"]},

            arrowNormal = {r = 0.85, g = 0.65, b = 0.25, a = 1, label = RCL["Arrow Normal"]},
            arrowHover = {r = 1, g = 1, b = 1, a = 1, label = RCL["Arrow Hover"]},
            arrowPushed = {r = 1, g = 0.82, b = 0, a = 1, label = RCL["Arrow Pushed"]},
            arrowHighlight = {r = 0.85, g = 0.65, b = 0.25, a = 0.3, label = RCL["Arrow Highlight"]},

            checkboxBackground = {r = 0.07, g = 0.07, b = 0.07, a = 1, label = RCL["Checkbox BG"]},
            checkboxLabel = {r = 0.7, g = 0.7, b = 0.7, a = 1, label = RCL["Checkbox Label"]},
            checkmarkColor = {r = 0.3, g = 1, b = 0.3, a = 1, label = RCL["Checkmark"]},

            whiteText = {r = 1, g = 1, b = 1, a = 1, label = RCL["White Text"]},
            tooltipText = {r = 0.8, g = 0.8, b = 0.8, a = 1, label = RCL["Tooltip Text"]},

            saveButtonBg = {r = 0.12, g = 0.16, b = 0.12, a = 1, label = RCL["Save Button"]},
            saveButtonBgHover = {r = 0.15, g = 0.2, b = 0.15, a = 1, label = RCL["Save Hover"]},
        },
    }

    function RC:GetColor(category, colorKey)
        if self.db and self.db.customColors and self.db.customColors[category] and self.db.customColors[category][colorKey] then
            return self.db.customColors[category][colorKey]
        end
        if self.defaultColors and self.defaultColors[category] and self.defaultColors[category][colorKey] then
            -- Returned directly (no per-lookup clone): callers only read
            -- r/g/b/a - the customColors branch above already hands out the
            -- live table, so mutation was never safe anyway.
            return self.defaultColors[category][colorKey]
        end
        return {r = 1, g = 1, b = 1, a = 1}
    end

    function RC:SetColor(category, colorKey, r, g, b, a)
        if not self.db.customColors then
            self.db.customColors = {}
        end
        if not self.db.customColors[category] then
            self.db.customColors[category] = {}
        end
        self.db.customColors[category][colorKey] = {r = r, g = g, b = b, a = a or 1}
        self:SaveConfigurationToProfile()
        if self.consumablesChecker then
            self.consumablesChecker._colorsDirty = true
        end
        -- every colour write, from any editor, reaches the preview pane
        if self.UI and self.UI.NotifySettingChanged then self.UI:NotifySettingChanged("color") end
    end

    function RC:ResetColor(category, colorKey)
        if self.db and self.db.customColors and self.db.customColors[category] then
            self.db.customColors[category][colorKey] = nil
            if not next(self.db.customColors[category]) then
                self.db.customColors[category] = nil
            end
            self:SaveConfigurationToProfile()
            if self.UI and self.UI.NotifySettingChanged then self.UI:NotifySettingChanged("color") end
        end
    end

    function RC:ResetColorCategory(category)
        if self.db and self.db.customColors then
            self.db.customColors[category] = nil
            self:SaveConfigurationToProfile()
            if self.UI and self.UI.NotifySettingChanged then self.UI:NotifySettingChanged("color") end
        end
    end

    function RC:ResetAllColors()
        if self.db then
            self.db.customColors = {}
            self:SaveConfigurationToProfile()
            if self.UI and self.UI.NotifySettingChanged then self.UI:NotifySettingChanged("color") end
        end
    end

    -- Slot order for the boss gear-swap config UI; the two tables below are
    -- derived lookups (by invSlot, and by equip-slot invType string).
    RC.bossGearSwapSlots = {
        { invSlot = 1,  name = "Head",      defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Head"     },
        { invSlot = 2,  name = "Neck",      defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Neck"     },
        { invSlot = 3,  name = "Shoulder",  defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Shoulder" },
        { invSlot = 15, name = "Back",      defaultIcon = "Interface\\Icons\\INV_Misc_Cape_19"               },
        { invSlot = 5,  name = "Chest",     defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Chest"    },
        { invSlot = 9,  name = "Wrist",     defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Wrists"   },

        { invSlot = 10, name = "Hands",     defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Hands"    },
        { invSlot = 6,  name = "Waist",     defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Waist"    },
        { invSlot = 7,  name = "Legs",      defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Legs"     },
        { invSlot = 8,  name = "Feet",      defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Feet"     },
        { invSlot = 11, name = "Finger 1",  defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger"   },
        { invSlot = 12, name = "Finger 2",  defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Finger"   },

        { invSlot = 13, name = "Trinket 1", defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket"  },
        { invSlot = 14, name = "Trinket 2", defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Trinket"  },
        { invSlot = 16, name = "Main Hand", defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-MainHand" },
        { invSlot = 17, name = "Off Hand",  defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-SecondaryHand" },
        { invSlot = 18, name = "Ranged",    defaultIcon = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Ranged"   },
    }

    RC.bossGearSwapSlotByInv = {}
    for _, e in ipairs(RC.bossGearSwapSlots) do
        RC.bossGearSwapSlotByInv[e.invSlot] = e
    end

    -- Flat palette used directly by code (not user-configurable, unlike
    -- defaultColors above which backs the theme editor).
    RC.colors = {
        black = {r = 0, g = 0, b = 0, a = 1},
        white = {r = 1, g = 1, b = 1, a = 1},
        transparent = {r = 0, g = 0, b = 0, a = 0},

        borderNormal = {r = 0, g = 0, b = 0, a = 1},
        borderHover = {r = 0.85, g = 0.65, b = 0.25, a = 1},

        gold = {r = 1, g = 0.82, b = 0, a = 1},
        goldHover = {r = 0.85, g = 0.65, b = 0.25, a = 1},
        yellow = {r = 1, g = 1, b = 0, a = 1},

        red = {r = 1, g = 0.3, b = 0.3, a = 1},
        green = {r = 0.3, g = 1, b = 0.3, a = 1},
        brightGreen = {r = 0, g = 1, b = 0, a = 1},
        softGreen = {r = 0.3, g = 0.7, b = 0.3, a = 1},
        cyan = {r = 0, g = 1, b = 0.5, a = 1},

        gray = {r = 0.5, g = 0.5, b = 0.5, a = 1},
        darkGray = {r = 0.2, g = 0.2, b = 0.2, a = 1},
        lightGray = {r = 0.6, g = 0.6, b = 0.6, a = 1},
        veryLightGray = {r = 0.85, g = 0.85, b = 0.85, a = 1},
        medGray = {r = 0.4, g = 0.4, b = 0.4, a = 1},
        dimGray = {r = 0.3, g = 0.3, b = 0.3, a = 1},

        windowBg = {r = 0.08, g = 0.08, b = 0.08, a = 0.95},
        windowBgLight = {r = 0.08, g = 0.08, b = 0.08, a = 0.9},
        elementBg = {r = 0.12, g = 0.12, b = 0.12, a = 0.9},
        cardBg = {r = 0.06, g = 0.06, b = 0.06, a = 1},
        headerBg = {r = 0.1, g = 0.1, b = 0.1, a = 1},
        buttonBg = {r = 0.15, g = 0.15, b = 0.15, a = 1},

        blackHalf = {r = 0, g = 0, b = 0, a = 0.5},
        black80 = {r = 0, g = 0, b = 0, a = 0.8},
    }

    -- One-time migration gated by consumablesMigrated_potionBarFoodBandage;
    -- use a new flag name if this list changes again, or it will silently
    -- skip existing installs that already ran this version.
    C_Timer.After(0, function()
        if not RC.db then return end
        if RC.db.consumablesMigrated_potionBarFoodBandage then return end
        RC.db.consumablesMigrated_potionBarFoodBandage = true

        if not RC.db.potionsBar then RC.db.potionsBar = {} end
        if not RC.db.potionsBar.hiddenItems then RC.db.potionsBar.hiddenItems = {} end
        local hi = RC.db.potionsBar.hiddenItems

        local newItems = {
            13810,
            20452,
            21023,
            12217,
            23326,
            23211,
            13931,
            14530,
        }
        for _, itemId in ipairs(newItems) do
            if hi[itemId] == nil then
                hi[itemId] = true
            end
        end

        if RC.SaveConfigurationToProfile then
            RC:SaveConfigurationToProfile()
        end
        RC:DebugPrint("Potion bar food/bandage migration: hid new items for existing profile", "system")
    end)

    -- One-time migration for warriors only; nonWarrior flag comes from the
    -- item entries defined in DB_Consumables.lua's raidConsumables.
    C_Timer.After(1.0, function()
        if not RC.db then return end
        if RC.db.consumablesMigrated_nonWarriorItems then return end
        RC.db.consumablesMigrated_nonWarriorItems = true

        local isWarrior = RC.isWarrior
        if isWarrior == nil then
            local _, class = UnitClass("player")
            isWarrior = (class == "WARRIOR")
        end

        if isWarrior then
            if not RC.db.consumablesChecker then RC.db.consumablesChecker = {} end
            if not RC.db.consumablesChecker.disabledItems then RC.db.consumablesChecker.disabledItems = {} end

            for _, category in pairs(RC.raidConsumables) do
                if category.items then
                    for itemId, itemData in pairs(category.items) do
                        if itemData.nonWarrior then
                            RC.db.consumablesChecker.disabledItems[itemId] = true
                        end
                    end
                end
            end
            RC:DebugPrint("Warrior migration: hid non-warrior consumables", "system")
        end

        if RC.SaveConfigurationToProfile then
            RC:SaveConfigurationToProfile()
        end
    end)

-- GetInventorySlotInfo returns no usable icon for BackSlot in Classic Era;
-- override so the gear-swap UI doesn't show a blank tile for cloak.
local SLOT_EMPTY_TEXTURE_OVERRIDE = {
    BackSlot = "Interface\\Icons\\INV_Misc_Cape_19",
}

function RC:GetSlotEmptyTexture(slotKey)
    if not slotKey then return nil end
    if SLOT_EMPTY_TEXTURE_OVERRIDE[slotKey] then
        return SLOT_EMPTY_TEXTURE_OVERRIDE[slotKey]
    end
    local _, tex = GetInventorySlotInfo(slotKey)
    return tex
end

