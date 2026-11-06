------------------------------------------------------------------------
-- Readycheck - Warrior Ability & Utility Item Data
-- Base ability/cooldown reminder data for warriors, plus generic raid
-- utility consumables. DB_ClassAbilities.lua extends RC.abilityData with
-- entries for every other class; both tables are read by the reminder
-- and cooldown-tracking UI.
--
-- abilityData[key] = { name, icon, description, spellId or spellIds,
--   cooldown, duration, isDebuff, itemId, buffId, isItem,
--   isFrostBlastReminder }. spellIds (plural) is used where a spell has
--   rank/race variants sharing one reminder.
-- utilityItems[itemId] = { name, spellId, cooldown, description, icon }.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)
local RC = _G.Readycheck
if not RC then
    print("ERROR: Readycheck not initialized before Database files")
    return
end
    RC.abilityData = {
        deathwish = {
            name = "Death Wish",
            icon = "Interface\\Icons\\Spell_Shadow_DeathPact",
            description = RCL["Increases damage by 20% but also damage taken by 5%"],
            spellId = 12328,
            cooldown = 180,
            duration = 30
        },
        recklessness = {
            name = "Recklessness",
            icon = "Interface\\Icons\\Ability_CriticalStrike",
            description = RCL["Increases critical hit chance by 100% but reduces armor by 75%"],
            spellId = 1719,
            cooldown = 1800,
            duration = 15
        },
        bloodrage = {
            name = "Bloodrage",
            icon = "Interface\\Icons\\Ability_Racial_BloodRage",
            description = RCL["Generates rage over time"],
            spellId = 2687,
            cooldown = 60,
            duration = 10
        },
        bloodfury = {
            name = "Blood Fury",
            icon = 135726,
            description = RCL["Increases melee attack power at the cost of reduced healing received (Orc racial)"],
            spellId = 20572,
            cooldown = 120,
            duration = 25,
            isDebuff = true,
        },
        berserking = {
            name = "Berserking",
            icon = 135727,
            description = RCL["Increases attack speed and casting speed based on missing health (Troll racial)"],
            spellId = 20554,
            cooldown = 180,
            duration = 10,
        },
        berserkerrage = {
            name = "Berserker Rage",
            icon = "Interface\\Icons\\Spell_Nature_AncestralGuardian",
            description = RCL["Generates rage and removes fear/charm effects"],
            spellId = 18499,
            cooldown = 30,
            duration = 10
        },
        laststand = {
            name = "Last Stand",
            icon = "Interface\\Icons\\Spell_Holy_AshesToAshes",
            description = RCL["Increases health by 30% for 20 seconds"],
            spellId = 12975,
            cooldown = 600,
            duration = 20
        },
        shieldwall = {
            name = "Shield Wall",
            icon = "Interface\\Icons\\Ability_Warrior_ShieldWall",
            description = RCL["Reduces all damage taken by 75% for 10 seconds"],
            spellId = 871,
            cooldown = 1800,
            duration = 10
        },
        battleChicken = {
            name = "Battle Chicken",
            icon = "Interface\\Icons\\Spell_Magic_PolymorphChicken",
            description = RCL["Summon Gnomish Battle Chicken for raid DPS boost (Battle Squawk)"],
            itemId = 10576,
            spellId = 23133,
            buffId = 23060,
            cooldown = 1800,
            duration = 0,
            isItem = true
        },
        arcaniteDragonling = {
            name = "Arcanite Dragonling",
            icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
            description = RCL["Summon Arcanite Dragonling for fire damage"],
            itemId = 16022,
            cooldown = 3600,
            duration = 0,
            isItem = true
        },
        frostBlast = {
            name = "Drop Stam Consumes",
            icon = "Interface\\Icons\\Spell_Frost_FrostBlast",
            description = RCL["Reminder to click off staminable consumes when HP is high - reduces max HP so Frost Blast heals for less"],
            cooldown = 0,
            duration = 0,
            isFrostBlastReminder = true
        },
        boon = {
            name = "Chronoboon",
            icon = "Interface\\Icons\\inv_misc_enggizmos_24",
            description = RCL["Unboon to restore your stored buffs"],
            spellId = 349977,
            cooldown = 0,
            duration = 0,
        }
    }

    RC.utilityItems = {
        [10646] = {
            name = "Goblin Sapper Charge",
            spellId = 13241,
            cooldown = 300,
            description = RCL["AoE damage to nearby enemies"],
            icon = "Interface\\Icons\\INV_Misc_Bomb_05"
        },
        [18641] = {
            name = "Dense Dynamite",
            spellId = 23063,
            cooldown = 60,
            description = RCL["Throws dynamite dealing AoE damage"],
            icon = "Interface\\Icons\\INV_Misc_Bomb_08"
        },
        [13515] = {
            name = "Ramstein's Lightning Bolts",
            spellId = 17668,
            cooldown = 1800,
            description = RCL["AoE nature damage to nearby enemies"],
            icon = "Interface\\Icons\\Spell_Nature_Lightning"
        },
        [13180] = {
            name = "Stratholme Holy Water",
            spellId = 17291,
            cooldown = 60,
            description = RCL["Undead/Demon damage"],
            icon = "Interface\\Icons\\INV_Potion_17"
        },
        [16023] = {
            name = "Masterwork Target Dummy",
            spellId = 19805,
            cooldown = 0,
            description = RCL["Creates a target dummy to distract enemies"],
            icon = "Interface\\Icons\\INV_Misc_Shovel_01"
        },
        [4392] = {
            name = "Advanced Target Dummy",
            spellId = 4072,
            cooldown = 0,
            description = RCL["Creates a target dummy to distract enemies (30s duration)"],
            icon = "Interface\\Icons\\INV_Crate_05"
        },
        [22261] = {
            name = "Love Fool",
            spellId = 27661,
            cooldown = 0,
            description = RCL["Tosses a Love Fool to distract enemies"],
            icon = "Interface\\Icons\\INV_ValentinesCard02"
        },
        [11951] = {
            name = "Whipper Root Tuber",
            spellId = 15700,
            cooldown = 0,
            description = RCL["Restores 700-900 health"],
            icon = "Interface\\Icons\\INV_Misc_Root_02"
        },
        [2091] = {
            name = "Magic Dust",
            spellId = 2687,
            cooldown = 1800,
            description = RCL["Puts target to sleep"],
            icon = "Interface\\Icons\\INV_Misc_Dust_01"
        },
        [8956] = {
            name = "Oil of Immolation",
            spellId = 11350,
            cooldown = 0,
            description = RCL["Deals fire damage to nearby enemies for 15 seconds (resets swing timer)"],
            icon = "Interface\\Icons\\INV_Potion_62"
        },
        [10576] = {
            name = "Gnomish Battle Chicken",
            spellId = 23133,
            buffId = 23060,
            cooldown = 1800,
            description = RCL["Summons a Battle Chicken that boosts raid melee DPS"],
            icon = "Interface\\Icons\\Spell_Magic_PolymorphChicken"
        },
        [16022] = {
            name = "Arcanite Dragonling",
            spellId = 19804,
            cooldown = 3600,
            description = RCL["Summons an Arcanite Dragonling for fire damage"],
            icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01"
        },
        [22682] = {
            name = "Frozen Rune",
            spellId = 29432,
            cooldown = 120,
            description = RCL["Absorbs 1500-2500 fire damage (Naxxramas drop)"],
            icon = "Interface\\Icons\\Spell_Frost_FrozenCore"
        },
    }
