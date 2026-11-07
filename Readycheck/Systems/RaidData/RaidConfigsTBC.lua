------------------------------------------------------------------------
-- Readycheck - Raid data for TBC Anniversary
-- Every TBC raid and boss, with the ids the lookups use (NPC ids,
-- encounter ids, instance ids), the trash lists and each boss's default
-- ability config (all off, like Classic Era's). Names are exactly as in
-- game; ids checked against Wowhead TBC (catalogue: zui_tests/raids/
-- TBC_RAIDS.md). A nil id is one that could not be confirmed.
-- RC:ApplyRaidFlavor (RaidFlavor.lua) builds the configs from it once,
-- at load, when Readycheck runs as TBC; on any other version nothing
-- here is read.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
RC._raidFlavors = RC._raidFlavors or {}

-- Ability sets. TBC potions in place of Mighty Rage / Stoneshield; the
-- potion keys name their potion (potionType) so the reminder can fire.
local function Off(t) t.enabled = false return t end
local function Engi(a)
    a.battleChicken = Off({ triggerType = "combat_start", combatTime = 0, equipAfterDeath = false })
    a.arcaniteDragonling = Off({ triggerType = "combat_start", combatTime = 0, equipAfterDeath = false })
    return a
end
local function Haste(t) t.potionType = "hastePotion" return Off(t) end
local function Ironshield() return Off({ triggerType = "combat_start", combatTime = 3, potionType = "ironshieldPotion" }) end

-- kind: "std" (cooldowns after the opening), "burst" (on the pull),
-- "final" (a last boss: held for the end, both trinkets)
local function Abilities(kind, o)
    o = o or {}
    local a
    if kind == "burst" then
        a = {
            deathwish = Off({ triggerType = "combat_start", combatTime = 5 }),
            recklessness = Off({ triggerType = "combat_start", combatTime = 10 }),
            hastePotion = Haste({ triggerType = "combat_start", combatTime = 3 }),
            trinket1 = Off({ triggerType = "combat_start", combatTime = 8 }),
            trinket2 = Off({ triggerType = "combat_start", combatTime = 15 }),
        }
    elseif kind == "final" then
        a = {
            deathwish = Off({ triggerType = "hp_percent", hpValue = 75 }),
            recklessness = Off({ triggerType = "hp_percent", hpValue = 40 }),
            hastePotion = Haste({ triggerType = "deathwish_time", buffTimeRemaining = 5 }),
            trinket1 = Off({ triggerType = "hp_percent", hpValue = 70 }),
            trinket2 = Off({ triggerType = "hp_percent", hpValue = 35 }),
        }
    else
        a = {
            deathwish = Off({ triggerType = "hp_percent", hpValue = o.dw or 85 }),
            recklessness = Off({ triggerType = "buff_remaining", buffTimeRemaining = 10 }),
            hastePotion = Haste({ triggerType = "deathwish_time", buffTimeRemaining = 5 }),
            trinket1 = Off({ triggerType = "hp_percent", hpValue = 80 }),
        }
    end
    if o.tank then
        a.ironshieldPotion = Ironshield()
        a.laststand = Off({ triggerType = "player_hp", playerHpValue = 40 })
    end
    if o.fear then a.berserkerrage = Off({ triggerType = "debuff_present", debuffName = o.fear }) end
    return Engi(a)
end

local function Trash(o)
    local a = {}
    if o.rage then a.bloodrage = Off({ triggerType = "rage_threshold", rageValue = 20 }) end
    if o.dw then a.deathwish = Off({ triggerType = "hp_percent", hpValue = o.dw }) end
    if o.tank then a.ironshieldPotion = Ironshield() end
    return { abilities = a }
end

-- One row per raid. name: the raid's key (its zone text); zones: the
-- other names the client gives it (instance name). Each boss: name (the
-- config key: the encounter's name), encounterId, npcIds, members (the
-- bosses of a council / event, by name and NPC id), adds, the kind of
-- ability set, notes.
local RAIDS = {
    { name = "Karazhan", code = "kara", abbr = "Kara", label = "Karazhan", size = 10,
      instanceId = 532, zoneId = 3457, icon = 254651, zones = { "Karazhan" },
      bosses = {
        { name = "Attumen the Huntsman", encounterId = 652, npcIds = { 15550, 16152 },
          members = { { "Midnight", 16151 } }, kind = "std" },
        { name = "Moroes", encounterId = 653, npcIds = { 15687 }, kind = "std" },
        { name = "Maiden of Virtue", encounterId = 654, npcIds = { 16457 }, kind = "std" },
        { name = "Opera Hall", encounterId = 655, npcIds = {}, kind = "std", event = true,
          members = { { "Romulo", 17533 }, { "Julianne", 17534 }, { "The Big Bad Wolf", 17521 },
                      { "Dorothee", 17535 }, { "Tito", 17548 }, { "Strawman", 17543 },
                      { "Tinhead", 17547 }, { "Roar", 17546 }, { "The Crone", 18168 } },
          notes = "One of three plays: Romulo and Julianne, The Big Bad Wolf, or The Wizard of Oz" },
        { name = "The Curator", encounterId = 656, npcIds = { 15691 }, kind = "burst" },
        { name = "Terestian Illhoof", encounterId = 657, npcIds = { 15688 }, kind = "std" },
        { name = "Shade of Aran", encounterId = 658, npcIds = { 16524 }, kind = "std" },
        { name = "Netherspite", encounterId = 659, npcIds = { 15689 }, kind = "std" },
        { name = "Chess Event", encounterId = 660, npcIds = {}, kind = "none", event = true,
          members = { { "Echo of Medivh", 16816 }, { "King Llane", 21684 }, { "Warchief Blackhand", 21752 } },
          notes = "Chess: you control the pieces, no melee reminders" },
        { name = "Prince Malchezaar", encounterId = 661, npcIds = { 15690 }, kind = "final" },
        { name = "Nightbane", encounterId = 662, npcIds = { 17225 }, kind = "std",
          fear = "Bellowing Roar" },
      },
      sections = {
        { "Stables", { "Spectral Charger", "Spectral Stallion", "Spectral Stable Hand" } },
        { "Servants' Quarters", { "Coldmist Widow", "Coldmist Stalker", "Shadowbat", "Vampiric Shadowbat",
            "Greater Shadowbat", "Dreadbeast", "Phase Hound", "Shadowbeast" } },
        { "Banquet Hall", { "Spectral Servant", "Skeletal Waiter", "Phantom Guest", "Ghostly Steward",
            "Phantom Valet", "Phantom Attendant", "Spectral Retainer", "Spectral Chef", "Ghostly Baker",
            "Night Lord", "Night Mistress", "Wanton Host", "Wanton Hostess", "Zealous Consort",
            "Zealous Paramour" } },
        { "Guards", { "Phantom Guardsman", "Spectral Sentry", "Spectral Apprentice" } },
        { "Opera House", { "Phantom Stagehand", "Skeletal Usher", "Spectral Performer", "Spectral Patron",
            "Ghostly Philanthropist", "Ghastly Haunt" } },
        { "Arcane", { "Astral Flare", "Arcane Watchman", "Arcane Anomaly", "Syphoner" } },
      },
      configs = {
        ["Phantom Guardsman"] = { rage = true },
        ["Ghastly Haunt"] = { dw = 85 },
        ["Arcane Watchman"] = { dw = 85, tank = true },
      },
      packs = {
        { key = "stables", label = "Stable horses", mobs = { "Spectral Charger", "Spectral Stallion",
            "Spectral Stable Hand" } },
        { key = "banquet", label = "Banquet Hall guests", mobs = { "Phantom Guest", "Ghostly Steward",
            "Phantom Valet", "Phantom Attendant", "Spectral Retainer", "Night Lord", "Night Mistress",
            "Wanton Host", "Wanton Hostess", "Zealous Consort", "Zealous Paramour" } },
        { key = "opera", label = "Opera House", mobs = { "Phantom Stagehand", "Skeletal Usher",
            "Spectral Performer", "Spectral Patron", "Ghostly Philanthropist", "Ghastly Haunt" } },
        { key = "arcane", label = "Arcane trash", mobs = { "Astral Flare", "Arcane Watchman",
            "Arcane Anomaly", "Syphoner" } },
      },
    },
    { name = "Gruul's Lair", code = "gruul", abbr = "Gruul", label = "Gruul's Lair", size = 25,
      instanceId = 565, zoneId = 3923, icon = 236412, zones = { "Gruul's Lair" },
      bosses = {
        { name = "High King Maulgar", encounterId = 649, npcIds = { 18831 }, kind = "std",
          adds = { "Kiggler the Crazed", "Blindeye the Seer", "Olm the Summoner", "Krosh Firehand" },
          addIds = { 18835, 18836, 18834, 18832 }, addsFirst = true, fear = "Intimidating Roar",
          notes = "Ogre council - Maulgar with Kiggler, Blindeye, Olm and Krosh" },
        { name = "Gruul the Dragonkiller", encounterId = 650, npcIds = { 19044 }, kind = "final", tank = true },
      },
      sections = {
        { "Gronn", { "Lair Brute", "Gronn-Priest" } },
      },
      configs = { ["Lair Brute"] = { dw = 85, tank = true } },
      packs = { { key = "gronn", label = "Lair Brutes and Gronn-Priests", mobs = { "Lair Brute", "Gronn-Priest" } } },
    },
    { name = "Magtheridon's Lair", code = "mag", abbr = "Mag", label = "Magtheridon's Lair", size = 25,
      instanceId = 544, zoneId = 3836, icon = 236423, zones = { "Magtheridon's Lair" },
      bosses = {
        { name = "Magtheridon", encounterId = 651, npcIds = { 17257 }, kind = "final", tank = true,
          adds = { "Hellfire Channeler" }, addIds = { 17256 }, addsFirst = true, fear = "Fear",
          notes = "Kill the five Hellfire Channelers before Magtheridon breaks free" },
      },
      sections = {
        { "Hellfire Warders", { "Hellfire Warder" } },
      },
      configs = { ["Hellfire Warder"] = { rage = true } },
      packs = { { key = "warders", label = "Hellfire Warders", mobs = { "Hellfire Warder" } } },
    },
    { name = "Serpentshrine Cavern", code = "ssc", abbr = "SSC", label = "Serpentshrine Cavern", size = 25,
      instanceId = 548, zoneId = 3607, icon = 236422,
      zones = { "Serpentshrine Cavern", "Coilfang: Serpentshrine Cavern" },
      bosses = {
        { name = "Hydross the Unstable", encounterId = 623, npcIds = { 21216 }, kind = "std", tank = true,
          adds = { "Tainted Spawn of Hydross", "Pure Spawn of Hydross" } },
        { name = "The Lurker Below", encounterId = 624, npcIds = { 21217 }, kind = "std",
          adds = { "Coilfang Ambusher", "Coilfang Guardian" } },
        { name = "Leotheras the Blind", encounterId = 625, npcIds = { 21215 }, kind = "std", tank = true,
          adds = { "Inner Demon", "Shadow of Leotheras" } },
        { name = "Fathom-Lord Karathress", encounterId = 626, npcIds = { 21214 }, kind = "std",
          adds = { "Fathom-Guard Caribdis", "Fathom-Guard Tidalvess", "Fathom-Guard Sharkkis" },
          addIds = { 21964, 21965, 21966 }, addsFirst = true },
        { name = "Morogrim Tidewalker", encounterId = 627, npcIds = { 21213 }, kind = "std", tank = true,
          adds = { "Tidewalker Lurker" } },
        { name = "Lady Vashj", encounterId = 628, npcIds = { 21212 }, kind = "final",
          adds = { "Coilfang Elite", "Coilfang Strider", "Tainted Elemental", "Enchanted Elemental" } },
      },
      sections = {
        { "Underbog Colossi", { "Underbog Colossus", "Colossus Lurker", "Colossus Rager" } },
        { "Greyheart", { "Greyheart Technician", "Greyheart Tidecaller", "Greyheart Skulker",
                         "Greyheart Nether-Mage", "Greyheart Spellbinder", "Greyheart Shield-Bearer" } },
        { "Coilfang", { "Coilfang Beast-Tamer", "Coilfang Hate-Screamer", "Coilfang Shatterer",
                        "Coilfang Priestess", "Coilfang Serpentguard", "Coilfang Fathom-Witch",
                        "Coilfang Frenzy", "Vashj'ir Honor Guard", "Serpentshrine Sporebat",
                        "Serpentshrine Lurker" } },
        { "Tidewalker", { "Tidewalker Depth-Seer", "Tidewalker Hydromancer", "Tidewalker Shaman",
                          "Tidewalker Warrior" } },
        { "Water Elementals", { "Tainted Water Elemental", "Purified Water Elemental" } },
      },
      configs = {
        ["Underbog Colossus"] = { dw = 90, tank = true },
        ["Vashj'ir Honor Guard"] = { dw = 85 },
        ["Greyheart Nether-Mage"] = { rage = true },
      },
      packs = {
        { key = "colossus", label = "Underbog Colossi", mobs = { "Underbog Colossus", "Colossus Lurker", "Colossus Rager" } },
        { key = "greyheart", label = "Greyheart packs", mobs = { "Greyheart Technician", "Greyheart Tidecaller",
            "Greyheart Skulker", "Greyheart Nether-Mage", "Greyheart Spellbinder", "Greyheart Shield-Bearer" } },
        { key = "coilfang", label = "Coilfang and Vashj'ir", mobs = { "Coilfang Beast-Tamer", "Coilfang Hate-Screamer",
            "Coilfang Shatterer", "Coilfang Priestess", "Coilfang Serpentguard", "Coilfang Fathom-Witch",
            "Vashj'ir Honor Guard" } },
      },
    },
    { name = "Tempest Keep", code = "tk", abbr = "TK", label = "Tempest Keep: The Eye", size = 25,
      instanceId = 550, zoneId = 3845, icon = 236440, zones = { "Tempest Keep", "The Eye" },
      bosses = {
        { name = "Al'ar", encounterId = 730, npcIds = { 19514 }, kind = "std", adds = { "Ember of Al'ar" } },
        { name = "Void Reaver", encounterId = 731, npcIds = { 19516 }, kind = "burst" },
        { name = "High Astromancer Solarian", encounterId = 732, npcIds = { 18805 }, kind = "std" },
        { name = "Kael'thas Sunstrider", encounterId = 733, npcIds = { 19622 }, kind = "final",
          adds = { "Thaladred the Darkener", "Lord Sanguinar", "Grand Astromancer Capernian", "Master Engineer Telonicus" },
          addIds = { 20064, 20060, 20062, 20063 }, addsFirst = true,
          notes = "Four advisors and their weapons before Kael'thas himself" },
      },
      sections = {
        { "Bloodwarder", { "Bloodwarder Legionnaire", "Bloodwarder Marshal", "Bloodwarder Squire",
                           "Bloodwarder Vindicator" } },
        { "Phoenix", { "Phoenix-Hawk", "Phoenix-Hawk Hatchling", "Tempest Falconer" } },
        { "Astromancers", { "Astromancer", "Star Scryer", "Apprentice Star Scryer", "Astromancer Lord",
                            "Nether Scryer", "Novice Astromancer" } },
        { "Crystalcore", { "Crystalcore Devastator", "Crystalcore Mechanic", "Crystalcore Sentinel",
                           "Tempest-Smith" } },
        { "Crimson Hand", { "Crimson Hand Blood Knight", "Crimson Hand Centurion", "Crimson Hand Inquisitor",
                            "Crimson Hand Battle Mage" } },
      },
      configs = {
        ["Crystalcore Devastator"] = { dw = 90, tank = true },
        ["Phoenix-Hawk"] = { dw = 85 },
        ["Bloodwarder Legionnaire"] = { rage = true },
      },
      packs = {
        { key = "bloodwarder", label = "Bloodwarder packs", mobs = { "Bloodwarder Legionnaire", "Bloodwarder Marshal",
            "Bloodwarder Squire", "Bloodwarder Vindicator" } },
        { key = "constructs", label = "Crystalcore and Tempest-Smiths", mobs = { "Crystalcore Devastator",
            "Crystalcore Mechanic", "Crystalcore Sentinel", "Tempest-Smith" } },
        { key = "solarium", label = "Astromancers and Crimson Hand", mobs = { "Astromancer", "Star Scryer",
            "Astromancer Lord", "Crimson Hand Blood Knight", "Crimson Hand Centurion", "Crimson Hand Inquisitor",
            "Crimson Hand Battle Mage" } },
      },
    },
    { name = "Hyjal Summit", code = "hyjal", abbr = "Hyjal", label = "Battle for Mount Hyjal", size = 25,
      instanceId = 534, zoneId = 3606, icon = 236402,
      zones = { "Hyjal Summit", "The Battle for Mount Hyjal", "Battle for Mount Hyjal" },
      bosses = {
        { name = "Rage Winterchill", encounterId = 618, npcIds = { 17767 }, kind = "std" },
        { name = "Anetheron", encounterId = 619, npcIds = { 17808 }, kind = "std" },
        { name = "Kaz'rogal", encounterId = 620, npcIds = { 17888 }, kind = "burst" },
        { name = "Azgalor", encounterId = 621, npcIds = { 17842 }, kind = "std", tank = true },
        { name = "Archimonde", encounterId = 622, npcIds = { 17968 }, kind = "final", fear = "Fear" },
      },
      sections = {
        { "Scourge waves", { "Ghoul", "Crypt Fiend", "Abomination", "Banshee", "Gargoyle", "Frost Wyrm",
            "Shadowy Necromancer", "Skeleton Invader", "Skeleton Mage" } },
        { "Burning Legion waves", { "Giant Infernal", "Fel Stalker" } },
      },
      configs = {
        ["Abomination"] = { dw = 85 },
        ["Giant Infernal"] = { dw = 85, tank = true },
        ["Crypt Fiend"] = { rage = true },
      },
      packs = {
        { key = "scourge", label = "Scourge waves", mobs = { "Ghoul", "Crypt Fiend", "Abomination", "Banshee",
            "Gargoyle", "Frost Wyrm", "Shadowy Necromancer" } },
        { key = "legion", label = "Burning Legion waves", mobs = { "Giant Infernal", "Fel Stalker" } },
      },
    },
    { name = "Black Temple", code = "bt", abbr = "BT", label = "Black Temple", size = 25,
      instanceId = 564, zoneId = 3959, icon = 236415, zones = { "Black Temple", "The Black Temple" },
      bosses = {
        { name = "High Warlord Naj'entus", encounterId = 601, npcIds = { 22887 }, kind = "std" },
        { name = "Supremus", encounterId = 602, npcIds = { 22898 }, kind = "std" },
        { name = "Shade of Akama", encounterId = 603, npcIds = { 22841 }, kind = "std",
          adds = { "Ashtongue Channeler", "Ashtongue Defender", "Ashtongue Elementalist", "Ashtongue Rogue",
                   "Ashtongue Sorcerer", "Ashtongue Spiritbinder" }, addsFirst = true },
        { name = "Teron Gorefiend", encounterId = 604, npcIds = { 22871 }, kind = "std",
          adds = { "Shadowy Construct" } },
        { name = "Gurtogg Bloodboil", encounterId = 605, npcIds = { 22948 }, kind = "std", tank = true },
        { name = "Reliquary of Souls", encounterId = 606, npcIds = { 22856 }, kind = "std", event = true,
          members = { { "Reliquary of the Lost", 22856 }, { "Essence of Suffering", 23418 },
                      { "Essence of Desire", 23419 }, { "Essence of Anger", 23420 } },
          adds = { "Enslaved Soul", "Angered Soul Fragment", "Hungering Soul Fragment", "Suffering Soul Fragment" },
          notes = "Three essences in turn - Suffering, Desire, Anger" },
        { name = "Mother Shahraz", encounterId = 607, npcIds = { 22947 }, kind = "std" },
        { name = "The Illidari Council", encounterId = 608, npcIds = {}, kind = "std", event = true,
          members = { { "Gathios the Shatterer", 22949 }, { "High Nethermancer Zerevor", 22950 },
                      { "Lady Malande", 22951 }, { "Veras Darkshadow", 22952 } },
          notes = "Four council members - Gathios, Zerevor, Malande and Veras" },
        { name = "Illidan Stormrage", encounterId = 609, npcIds = { 22917 }, kind = "final" },
      },
      sections = {
        { "Ashtongue and Coilskar", { "Aqueous Lord", "Coilskar General", "Coilskar Harpooner",
            "Coilskar Sea-Caller", "Coilskar Soothsayer", "Coilskar Wrangler", "Dragon Turtle", "Leviathan",
            "Storm Fury", "Ashtongue Battlelord", "Ashtongue Feral Spirit", "Ashtongue Mystic",
            "Ashtongue Primalist", "Ashtongue Stalker", "Ashtongue Stormcaller" } },
        { "Bonechewer and Illidari", { "Bonechewer Taskmaster", "Bonechewer Worker", "Dragonmaw Sky Stalker",
            "Dragonmaw Wind Reaver", "Dragonmaw Wyrmcaller", "Illidari Fearbringer", "Illidari Boneslicer",
            "Illidari Centurion", "Illidari Defiler", "Illidari Heartseeker", "Illidari Nightlord" } },
        { "Gorefiend's Vigil", { "Bonechewer Shield Disciple", "Bonechewer Blade Fury", "Bonechewer Blood Prophet",
            "Mutant War Hound", "Bonechewer Brawler", "Bonechewer Combatant", "Bonechewer Spectator" } },
        { "Shadowmoon", { "Shadowmoon Blood Mage", "Shadowmoon Champion", "Shadowmoon Deathshaper",
            "Shadowmoon Grunt", "Shadowmoon Houndmaster", "Shadowmoon Reaver", "Shadowmoon Riding Hound",
            "Shadowmoon Soldier", "Shadowmoon Weapon Master", "Wrathbone Flayer" } },
        { "Den of Mortal Delights", { "Mistress of Dementia", "Mistress of Woe", "Priestess of Delight",
            "Priestess of Torment", "Charming Patron", "Ardent Host", "Devoted Steward", "Temple Acolyte" } },
      },
      configs = {
        ["Coilskar General"] = { dw = 85 },
        ["Aqueous Lord"] = { dw = 85, tank = true },
        ["Bonechewer Taskmaster"] = { rage = true },
        ["Illidari Nightlord"] = { dw = 85 },
      },
      packs = {
        { key = "coilskar", label = "Coilskar and Aqueous Lords", mobs = { "Aqueous Lord", "Coilskar General",
            "Coilskar Harpooner", "Coilskar Sea-Caller", "Coilskar Soothsayer", "Coilskar Wrangler" } },
        { key = "illidari", label = "Illidari and Bonechewer", mobs = { "Bonechewer Taskmaster", "Illidari Fearbringer",
            "Illidari Boneslicer", "Illidari Centurion", "Illidari Defiler", "Illidari Heartseeker", "Illidari Nightlord" } },
        { key = "shadowmoon", label = "Shadowmoon", mobs = { "Shadowmoon Blood Mage", "Shadowmoon Champion",
            "Shadowmoon Deathshaper", "Shadowmoon Houndmaster", "Shadowmoon Reaver", "Shadowmoon Weapon Master" } },
        { key = "shahraz", label = "Shahraz's courtesans", mobs = { "Mistress of Dementia", "Mistress of Woe",
            "Priestess of Delight", "Priestess of Torment", "Charming Patron", "Ardent Host", "Devoted Steward",
            "Temple Acolyte" } },
      },
    },
    { name = "Zul'Aman", code = "za", abbr = "ZA", label = "Zul'Aman", size = 10,
      instanceId = 568, zoneId = 3805, icon = 236438, zones = { "Zul'Aman" },
      bosses = {
        -- encounter ids for the TBC Zul'Aman could not be confirmed
        { name = "Akil'zon", encounterId = nil, npcIds = { 23574 }, kind = "std" },
        { name = "Nalorakk", encounterId = nil, npcIds = { 23576 }, kind = "std", tank = true },
        { name = "Jan'alai", encounterId = nil, npcIds = { 23578 }, kind = "std" },
        { name = "Halazzi", encounterId = nil, npcIds = { 23577 }, kind = "std" },
        { name = "Hex Lord Malacrass", encounterId = nil, npcIds = { 24239 }, kind = "std" },
        { name = "Zul'jin", encounterId = nil, npcIds = { 23863 }, kind = "final" },
      },
      sections = {
        { "Amani'shi", { "Amani'shi Guardian", "Amani'shi Savage", "Amani'shi Wind Walker",
            "Amani'shi Medicine Man", "Amani'shi Tribesman", "Amani'shi Axe Thrower", "Amani'shi Warbringer",
            "Amani'shi Scout", "Amani'shi Reinforcement", "Amani'shi Handler", "Amani'shi Lookout",
            "Amani'shi Tempest", "Amani'shi Flame Caster", "Amani'shi Beast Tamer", "Amani'shi Protector",
            "Amani'shi Trainer", "Amani'shi Warrior", "Amani'shi Berserker" } },
        { "Amani beasts", { "Amani Bear", "Amani Bear Mount", "Amani Crocolisk", "Tamed Amani Crocolisk",
            "Amani Lynx", "Amani Lynx Cub", "Amani Elder Lynx" } },
      },
      configs = {
        ["Amani'shi Berserker"] = { dw = 85 },
        ["Amani Elder Lynx"] = { dw = 85 },
        ["Amani'shi Warrior"] = { rage = true },
      },
      packs = {
        { key = "amanishi", label = "Amani'shi trolls", mobs = { "Amani'shi Guardian", "Amani'shi Savage",
            "Amani'shi Medicine Man", "Amani'shi Axe Thrower", "Amani'shi Warbringer", "Amani'shi Tempest",
            "Amani'shi Flame Caster", "Amani'shi Protector", "Amani'shi Warrior", "Amani'shi Berserker" } },
        { key = "beasts", label = "Amani beasts", mobs = { "Amani Bear", "Amani Crocolisk", "Amani Lynx",
            "Amani Elder Lynx" } },
      },
    },
    { name = "Sunwell Plateau", code = "swp", abbr = "SWP", label = "Sunwell Plateau", size = 25,
      instanceId = 580, zoneId = 4075, icon = 236418, zones = { "Sunwell Plateau", "The Sunwell" },
      bosses = {
        { name = "Kalecgos", encounterId = 724, npcIds = { 24850 }, kind = "std",
          members = { { "Sathrovarr the Corruptor", 24892 } } },
        { name = "Brutallus", encounterId = 725, npcIds = { 24882 }, kind = "burst" },
        { name = "Felmyst", encounterId = 726, npcIds = { 25038 }, kind = "std", adds = { "Unyielding Dead" } },
        { name = "Eredar Twins", encounterId = 727, npcIds = {}, kind = "std", event = true,
          members = { { "Lady Sacrolash", 25165 }, { "Grand Warlock Alythess", 25166 } },
          notes = "Twin encounter - Lady Sacrolash and Grand Warlock Alythess" },
        { name = "M'uru", encounterId = 728, npcIds = { 25741 }, kind = "std",
          members = { { "Entropius", 25840 } } },
        { name = "Kil'jaeden", encounterId = 729, npcIds = { 25315 }, kind = "final" },
      },
      sections = {
        { "Sunblade", { "Sunblade Arch Mage", "Sunblade Cabalist", "Sunblade Dawn Priest", "Sunblade Dragonhawk",
            "Sunblade Dusk Priest", "Sunblade Protector", "Sunblade Scout", "Sunblade Slayer",
            "Sunblade Vindicator" } },
        { "Shadowsword", { "Shadowsword Assassin", "Shadowsword Lifeshaper", "Shadowsword Manafiend",
            "Shadowsword Soulbinder", "Shadowsword Vanquisher" } },
        { "Demons", { "Blazing Infernal", "Felguard Slayer" } },
      },
      configs = {
        ["Sunblade Protector"] = { dw = 90, tank = true },
        ["Shadowsword Vanquisher"] = { dw = 85 },
        ["Felguard Slayer"] = { rage = true },
      },
      packs = {
        { key = "sunblade", label = "Sunblade packs", mobs = { "Sunblade Arch Mage", "Sunblade Cabalist",
            "Sunblade Dawn Priest", "Sunblade Dusk Priest", "Sunblade Protector", "Sunblade Scout",
            "Sunblade Slayer", "Sunblade Vindicator" } },
        { key = "shadowsword", label = "Shadowsword packs", mobs = { "Shadowsword Assassin", "Shadowsword Lifeshaper",
            "Shadowsword Manafiend", "Shadowsword Soulbinder", "Shadowsword Vanquisher" } },
      },
    },
}

-- TBC potions the raid configs offer (item and use spell from the TBC
-- consumables catalogue), ahead of the Classic Era ones it still has.
local POTIONS = {
    hastePotion          = { name = "Haste Potion",           itemId = 22838, spellId = 28507 },
    insaneStrengthPotion = { name = "Insane Strength Potion", itemId = 22828, spellId = 28494 },
    heroicPotion         = { name = "Heroic Potion",          itemId = 22837, spellId = 28506 },
    ironshieldPotion     = { name = "Ironshield Potion",      itemId = 22849, spellId = 28515 },
    destructionPotion    = { name = "Destruction Potion",     itemId = 22839, spellId = 28508 },
}
local POTION_ORDER = { "hastePotion", "insaneStrengthPotion", "heroicPotion", "ironshieldPotion", "destructionPotion" }

-- Samples the previews draw (route tracker, swap toast, TTK display)
local SAMPLE = {
    raid = "Serpentshrine Cavern",
    boss = "Hydross the Unstable", boss2 = "Morogrim Tidewalker", boss3 = "Lady Vashj",
    routeSteps = {
        { type = "kills", mobs = { { mob = "Underbog Colossus", kills = 2 } } },
        { type = "encounter", boss = "Hydross the Unstable", when = "end" },
        { type = "kills", mobs = { { mob = "Greyheart Tidecaller", kills = 4 }, { mob = "Greyheart Nether-Mage", kills = 2 } } },
        { type = "encounter", boss = "The Lurker Below", when = "start" },
        { type = "kills", mobs = { { mob = "Coilfang Serpentguard", kills = 6 } } },
    },
    routeCounts = { ["Greyheart Tidecaller"] = 3, ["Greyheart Nether-Mage"] = 1, ["Coilfang Serpentguard"] = 0 },
    routeMob = "Greyheart Tidecaller",
}

RC._raidFlavors.tbc = {
    raids = RAIDS,
    Abilities = Abilities,
    Trash = Trash,
    potions = POTIONS,
    potionOrder = POTION_ORDER,
    defaultPotionType = "hastePotion",
    sample = SAMPLE,
}
