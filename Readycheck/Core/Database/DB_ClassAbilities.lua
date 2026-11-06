------------------------------------------------------------------------
-- Readycheck - Non-Warrior Class Ability Data
-- Extends RC.abilityData (from DB_Abilities.lua) with cooldowns for every
-- class besides warrior, builds the per-class grid roster shown in the
-- reminder config UI, and resolves which tiles a player actually has
-- learned (GetAvailableAbilities / PrintClassAbilityRoster).
------------------------------------------------------------------------
local AddonName = "Readycheck"

local function InitializeClassAbilities()
    local RC = _G[AddonName]
    -- DB_Abilities.lua may not have run yet depending on load order; retry
    -- until RC.abilityData exists rather than assuming file load order.
    if not RC or not RC.abilityData then
        C_Timer.After(0.1, InitializeClassAbilities)
        return
    end
    if RC.classAbilitiesLoaded then return end
    RC.classAbilitiesLoaded = true

    local A = RC.abilityData

    if A.berserking and not A.berserking.spellIds then
        A.berserking.spellIds = {20554, 26296, 26297}
    end

    -- ============================= MAGE =============================
    A.arcanepower = { class = "MAGE", name = "Arcane Power",
        icon = "Interface\\Icons\\Spell_Nature_Lightning",
        description = RCL["Spells deal 30% more damage, cost 30% more mana"],
        spellId = 12042, cooldown = 180, duration = 15 }
    A.presenceofmind = { class = "MAGE", name = "Presence of Mind",
        icon = "Interface\\Icons\\Spell_Nature_EnchantArmor",
        description = RCL["Your next spell is instant cast"],
        spellId = 12043, cooldown = 180, duration = 15 }
    A.combustion = { class = "MAGE", name = "Combustion",
        icon = "Interface\\Icons\\Spell_Fire_SealOfFire",
        description = RCL["Guaranteed fire crits, consumed by 3 crits"],
        spellId = 11129, cooldown = 180, duration = 0 }
    A.evocation = { class = "MAGE", name = "Evocation",
        icon = "Interface\\Icons\\Spell_Nature_Purge",
        description = RCL["Regenerate 60% mana over 8 sec"],
        spellId = 12051, cooldown = 480, duration = 8 }
    A.coldsnap = { class = "MAGE", name = "Cold Snap",
        icon = "Interface\\Icons\\Spell_Frost_WizardMark",
        description = RCL["Resets your Frost cooldowns"],
        spellId = 12472, cooldown = 600, duration = 0 }
    A.iceblock = { class = "MAGE", name = "Ice Block",
        icon = "Interface\\Icons\\Spell_Frost_Frost",
        description = RCL["Immune to all attacks and spells for 10 sec"],
        spellId = 11958, cooldown = 300, duration = 10 }
    A.fireward = { class = "MAGE", name = "Fire Ward",
        icon = "Interface\\Icons\\Spell_Fire_FireArmor",
        description = RCL["Absorbs fire damage"],
        spellIds = {543, 8457, 8458, 10223, 10225}, cooldown = 30, duration = 30 }
    A.frostward = { class = "MAGE", name = "Frost Ward",
        icon = "Interface\\Icons\\Spell_Frost_FrostWard",
        description = RCL["Absorbs frost damage"],
        spellIds = {6143, 8461, 8462, 10177, 28609}, cooldown = 30, duration = 30 }
    A.counterspell = { class = "MAGE", name = "Counterspell",
        icon = "Interface\\Icons\\Spell_Frost_IceShock",
        description = RCL["Interrupt assignment"],
        spellId = 2139, cooldown = 30, duration = 0 }
    A.blink = { class = "MAGE", name = "Blink",
        icon = "Interface\\Icons\\Spell_Arcane_Blink",
        description = RCL["Teleport forward, break stuns"],
        spellId = 1953, cooldown = 15, duration = 0 }
    A.icebarrier = { class = "MAGE", name = "Ice Barrier",
        icon = "Interface\\Icons\\Spell_Ice_Lament",
        description = RCL["Absorb shield, prevents pushback"],
        spellIds = {11426, 13031, 13032, 13033}, cooldown = 30, duration = 60 }

    -- ============================= ROGUE ============================
    A.adrenalinerush = { class = "ROGUE", name = "Adrenaline Rush",
        icon = "Interface\\Icons\\Spell_Shadow_ShadowWordDominate",
        description = RCL["Energy regeneration increased by 100%"],
        spellId = 13750, cooldown = 300, duration = 15 }
    A.bladeflurry = { class = "ROGUE", name = "Blade Flurry",
        icon = "Interface\\Icons\\Ability_Warrior_PunishingBlow",
        description = RCL["Attack speed +20%, attacks strike a second target"],
        spellId = 13877, cooldown = 120, duration = 15 }
    A.coldblood = { class = "ROGUE", name = "Cold Blood",
        icon = "Interface\\Icons\\Spell_Ice_Lament",
        description = RCL["Your next ability is a guaranteed critical strike"],
        spellId = 14177, cooldown = 180, duration = 0 }
    A.evasion = { class = "ROGUE", name = "Evasion",
        icon = "Interface\\Icons\\Spell_Shadow_ShadowWard",
        description = RCL["Dodge chance increased by 50% for 15 sec"],
        spellId = 5277, cooldown = 300, duration = 15 }
    A.sprint = { class = "ROGUE", name = "Sprint",
        icon = "Interface\\Icons\\Ability_Rogue_Sprint",
        description = RCL["Movement speed increased for 15 sec"],
        spellIds = {2983, 8696, 11305}, cooldown = 300, duration = 15 }
    A.vanish = { class = "ROGUE", name = "Vanish",
        icon = "Interface\\Icons\\Ability_Vanish",
        description = RCL["Drop combat and threat, enter stealth"],
        spellIds = {1856, 1857}, cooldown = 300, duration = 10 }

    A.preparation = { class = "ROGUE", name = "Preparation",
        icon = "Interface\\Icons\\Spell_Shadow_AntiShadow",
        description = RCL["Resets your Rogue cooldowns (talent)"],
        spellId = 14185, cooldown = 600, duration = 0 }
    A.kick = { class = "ROGUE", name = "Kick",
        icon = "Interface\\Icons\\Ability_Kick",
        description = RCL["Interrupt assignment"],
        spellIds = {1766, 1767, 1768, 1769}, cooldown = 10, duration = 0 }
    A.blind = { class = "ROGUE", name = "Blind",
        icon = "Interface\\Icons\\Spell_Shadow_MindSteal",
        description = RCL["Disorient a target for 10 sec"],
        spellId = 2094, cooldown = 300, duration = 10 }

    -- ============================ HUNTER ============================
    A.rapidfire = { class = "HUNTER", name = "Rapid Fire",
        icon = "Interface\\Icons\\Ability_Hunter_RunningShot",
        description = RCL["Ranged attack speed increased by 40%"],
        spellId = 3045, cooldown = 300, duration = 15 }
    A.bestialwrath = { class = "HUNTER", name = "Bestial Wrath",
        icon = "Interface\\Icons\\Ability_Druid_FerociousBite",
        description = RCL["Pet enrages: +50% damage, fear immune"],
        spellId = 19574, cooldown = 120, duration = 18 }
    A.readiness = { class = "HUNTER", name = "Readiness",
        icon = "Interface\\Icons\\Ability_Hunter_Readiness",
        description = RCL["Resets all your Hunter cooldowns"],
        spellId = 23989, cooldown = 900, duration = 0 }
    A.feigndeath = { class = "HUNTER", name = "Feign Death",
        icon = "Interface\\Icons\\Ability_Rogue_FeignDeath",
        description = RCL["Drop all threat by feigning death"],
        spellId = 5384, cooldown = 30, duration = 0 }
    A.deterrence = { class = "HUNTER", name = "Deterrence",
        icon = "Interface\\Icons\\Ability_Whirlwind",
        description = RCL["Parry and dodge chance increased by 25%"],
        spellId = 19263, cooldown = 300, duration = 10 }

    A.tranqshot = { class = "HUNTER", name = "Tranquilizing Shot",
        icon = "Interface\\Icons\\Spell_Nature_Drowsy",
        description = RCL["Dispel frenzy (Magmadar, Flamegor)"],
        spellId = 19801, cooldown = 20, duration = 0 }
    A.freezingtrap = { class = "HUNTER", name = "Freezing Trap",
        icon = "Interface\\Icons\\Spell_Frost_ChainsOfIce",
        description = RCL["CC assignment"],
        spellIds = {1499, 14310, 14311}, cooldown = 15, duration = 0 }
    A.scattershot = { class = "HUNTER", name = "Scatter Shot",
        icon = "Interface\\Icons\\Ability_GolemStormBolt",
        description = RCL["Short disorient (talent)"],
        spellId = 19503, cooldown = 30, duration = 4 }
    A.intimidation = { class = "HUNTER", name = "Intimidation",
        icon = "Interface\\Icons\\Ability_Devour",
        description = RCL["Pet stuns its target (talent)"],
        spellId = 19577, cooldown = 60, duration = 3 }

    -- ============================ PRIEST ============================
    A.powerinfusion = { class = "PRIEST", name = "Power Infusion",
        icon = "Interface\\Icons\\Spell_Holy_PowerInfusion",
        description = RCL["Target's spell damage and healing +20%"],
        spellId = 10060, cooldown = 180, duration = 15 }
    A.innerfocus = { class = "PRIEST", name = "Inner Focus",
        icon = "Interface\\Icons\\Spell_Frost_WindWalkOn",
        description = RCL["Next spell free and +25% crit"],
        spellId = 14751, cooldown = 180, duration = 0 }
    A.fearward = { class = "PRIEST", name = "Fear Ward",
        icon = "Interface\\Icons\\Spell_Holy_Excorcism",
        description = RCL["Wards the target against the next fear (Dwarf)"],
        spellId = 6346, cooldown = 30, duration = 600 }
    A.fade = { class = "PRIEST", name = "Fade",
        icon = "Interface\\Icons\\Spell_Magic_LesserInvisibilty",
        description = RCL["Temporarily reduce your threat"],
        spellIds = {586, 9578, 9579, 10941, 10942}, cooldown = 30, duration = 10 }
    A.desperateprayer = { class = "PRIEST", name = "Desperate Prayer",
        icon = "Interface\\Icons\\Spell_Holy_Restoration",
        description = RCL["Instantly heal yourself (Human/Dwarf)"],
        spellIds = {13908, 19236, 19238, 19240, 19241, 19242, 19243},
        cooldown = 600, duration = 0 }

    A.shackleundead = { class = "PRIEST", name = "Shackle Undead",
        icon = "Interface\\Icons\\Spell_Nature_Slow",
        description = RCL["CC assignment (Naxxramas)"],
        spellIds = {9484, 9485, 10955}, cooldown = 0, duration = 50 }
    A.silence = { class = "PRIEST", name = "Silence",
        icon = "Interface\\Icons\\Spell_Shadow_ImpPhaseShift",
        description = RCL["Interrupt assignment (talent)"],
        spellId = 15487, cooldown = 45, duration = 5 }

    -- =========================== WARLOCK ============================
    A.amplifycurse = { class = "WARLOCK", name = "Amplify Curse",
        icon = "Interface\\Icons\\Spell_Shadow_Contagion",
        description = RCL["Empowers your next curse"],
        spellId = 18288, cooldown = 180, duration = 30 }
    A.deathcoil = { class = "WARLOCK", name = "Death Coil",
        icon = "Interface\\Icons\\Spell_Shadow_DeathCoil",
        description = RCL["Horrify the target, heal for damage done"],
        spellIds = {6789, 17925, 17926}, cooldown = 120, duration = 0 }
    A.shadowward = { class = "WARLOCK", name = "Shadow Ward",
        icon = "Interface\\Icons\\Spell_Shadow_AntiShadow",
        description = RCL["Absorbs shadow damage"],
        spellIds = {6229, 11739, 11740, 28610}, cooldown = 30, duration = 30 }
    A.feldomination = { class = "WARLOCK", name = "Fel Domination",
        icon = "Interface\\Icons\\Spell_Nature_RemoveCurse",
        description = RCL["Next demon summon is instant and cheap"],
        spellId = 18708, cooldown = 900, duration = 15 }

    A.darkpact = { class = "WARLOCK", name = "Dark Pact",
        icon = "Interface\\Icons\\Spell_Shadow_DarkRitual",
        description = RCL["Drain your pet's mana (talent)"],
        spellIds = {18220, 18937, 18938}, cooldown = 0, duration = 0 }
    A.banish = { class = "WARLOCK", name = "Banish",
        icon = "Interface\\Icons\\Spell_Shadow_Cripple",
        description = RCL["CC assignment (demons/elementals)"],
        spellIds = {710, 18647}, cooldown = 0, duration = 30 }
    A.soulstone = { class = "WARLOCK", name = "Soulstone",
        icon = "Interface\\Icons\\Spell_Shadow_SoulGem",
        description = RCL["Soulstone a resurrector before the pull"],
        spellIds = {20707, 20762, 20763, 20764, 20765, 20766},
        cooldown = 1800, duration = 1800 }
    A.curseofdoom = { class = "WARLOCK", name = "Curse of Doom",
        icon = "Interface\\Icons\\Spell_Shadow_AuraOfDarkness",
        description = RCL["One-minute doom timing on the pull"],
        spellId = 603, cooldown = 60, duration = 60 }

    -- ============================ DRUID =============================
    A.innervate = { class = "DRUID", name = "Innervate",
        icon = "Interface\\Icons\\Spell_Nature_Lightning",
        description = RCL["Massive mana regeneration for the target"],
        spellId = 29166, cooldown = 360, duration = 20 }
    A.natureswiftnessdruid = { class = "DRUID", name = "Nature's Swiftness",
        icon = "Interface\\Icons\\Spell_Nature_RavenForm",
        description = RCL["Your next nature spell is instant"],
        spellId = 17116, cooldown = 180, duration = 0 }
    A.rebirth = { class = "DRUID", name = "Rebirth",
        icon = "Interface\\Icons\\Spell_Nature_Reincarnation",
        description = RCL["Combat resurrection"],
        spellIds = {20484, 20739, 20742, 20747, 20748}, cooldown = 1800, duration = 0 }
    A.barkskin = { class = "DRUID", name = "Barkskin",
        icon = "Interface\\Icons\\Spell_Nature_StoneClawTotem",
        description = RCL["Damage taken reduced, spells uninterruptible"],
        spellId = 22812, cooldown = 60, duration = 15 }
    A.frenziedregen = { class = "DRUID", name = "Frenzied Regeneration",
        icon = "Interface\\Icons\\Ability_BullRush",
        description = RCL["Convert rage into health (Bear)"],
        spellIds = {22842, 22895, 22896}, cooldown = 180, duration = 10 }
    A.dash = { class = "DRUID", name = "Dash",
        icon = "Interface\\Icons\\Ability_Druid_Dash",
        description = RCL["Movement speed increased (Cat)"],
        spellIds = {1850, 9821}, cooldown = 300, duration = 15 }

    A.hibernate = { class = "DRUID", name = "Hibernate",
        icon = "Interface\\Icons\\Spell_Nature_Sleep",
        description = RCL["CC assignment (beasts/dragonkin)"],
        spellIds = {2637, 18657, 18658}, cooldown = 0, duration = 40 }
    A.tranquility = { class = "DRUID", name = "Tranquility",
        icon = "Interface\\Icons\\Spell_Nature_Tranquility",
        description = RCL["Big group heal channel"],
        spellIds = {740, 8918, 9862, 9863}, cooldown = 300, duration = 10 }

    -- ============================ SHAMAN ============================
    A.natureswiftnessshaman = { class = "SHAMAN", name = "Nature's Swiftness",
        icon = "Interface\\Icons\\Spell_Nature_RavenForm",
        description = RCL["Your next nature spell is instant"],
        spellId = 16188, cooldown = 180, duration = 0 }
    A.elementalmastery = { class = "SHAMAN", name = "Elemental Mastery",
        icon = "Interface\\Icons\\Spell_Nature_WispHeal",
        description = RCL["Next spell guaranteed crit and free"],
        spellId = 16166, cooldown = 180, duration = 0 }
    A.manatide = { class = "SHAMAN", name = "Mana Tide Totem",
        icon = "Interface\\Icons\\Spell_Frost_SummonWaterElemental",
        description = RCL["Party regenerates mana rapidly"],
        spellId = 16190, cooldown = 300, duration = 12 }

    A.tremortotem = { class = "SHAMAN", name = "Tremor Totem",
        icon = "Interface\\Icons\\Spell_Nature_TremorTotem",
        description = RCL["Fear-break totem for fear fights"],
        spellId = 8143, cooldown = 0, duration = 120 }
    A.groundingtotem = { class = "SHAMAN", name = "Grounding Totem",
        icon = "Interface\\Icons\\Spell_Nature_GroundingTotem",
        description = RCL["Absorb one harmful spell"],
        spellId = 8177, cooldown = 15, duration = 45 }

    -- =========================== PALADIN ============================
    A.divineshield = { class = "PALADIN", name = "Divine Shield",
        icon = "Interface\\Icons\\Spell_Holy_DivineIntervention",
        description = RCL["Immune to all damage and spells"],
        spellIds = {642, 1020}, cooldown = 300, duration = 10 }
    A.divineprotection = { class = "PALADIN", name = "Divine Protection",
        icon = "Interface\\Icons\\Spell_Holy_Restoration",
        description = RCL["Protected from all damage (short)"],
        spellIds = {498, 5573}, cooldown = 300, duration = 6 }
    A.blessingofprotection = { class = "PALADIN", name = "Blessing of Protection",
        icon = "Interface\\Icons\\Spell_Holy_SealOfProtection",
        description = RCL["Target immune to physical damage"],
        spellIds = {1022, 5599, 10278}, cooldown = 300, duration = 6 }
    A.layonhands = { class = "PALADIN", name = "Lay on Hands",
        icon = "Interface\\Icons\\Spell_Holy_LayOnHands",
        description = RCL["Heal target to full, drains your mana"],
        spellIds = {633, 2800, 10310}, cooldown = 3600, duration = 0 }
    A.divinefavor = { class = "PALADIN", name = "Divine Favor",
        icon = "Interface\\Icons\\Spell_Holy_Heal",
        description = RCL["Next heal is a guaranteed critical"],
        spellId = 20216, cooldown = 120, duration = 0 }

    -- =========================== RACIALS ============================
    A.escapeartist = { name = "Escape Artist",
        icon = "Interface\\Icons\\Ability_Rogue_Trip",
        description = RCL["Escape roots and snares (Gnome)"],
        spellId = 20589, cooldown = 60, duration = 0 }
    A.stoneform = { name = "Stoneform",
        icon = "Interface\\Icons\\Spell_Shadow_UnholyStrength",
        description = RCL["Remove bleed/poison/disease, +10% armor (Dwarf)"],
        spellId = 20594, cooldown = 180, duration = 8 }
    A.willoftheforsaken = { name = "Will of the Forsaken",
        icon = "Interface\\Icons\\Spell_Shadow_RaiseDead",
        description = RCL["Break and resist Charm/Fear/Sleep (Undead)"],
        spellId = 7744, cooldown = 120, duration = 5 }
    A.warstomp = { name = "War Stomp",
        icon = "Interface\\Icons\\Ability_WarStomp",
        description = RCL["Stun up to 5 nearby enemies (Tauren)"],
        spellId = 20549, cooldown = 120, duration = 2 }
    A.perception = { name = "Perception",
        icon = "Interface\\Icons\\Spell_Nature_Sleep",
        description = RCL["Dramatically increase stealth detection (Human)"],
        spellId = 20600, cooldown = 180, duration = 20 }
    A.shadowmeld = { name = "Shadowmeld",
        icon = "Interface\\Icons\\Ability_Ambush",
        description = RCL["Blend into the shadows while still (Night Elf)"],
        spellId = 20580, cooldown = 10, duration = 0 }
    A.cannibalize = { name = "Cannibalize",
        icon = "Interface\\Icons\\Ability_Racial_Cannibalize",
        description = RCL["Regenerate health from a nearby corpse (Undead)"],
        spellId = 20577, cooldown = 120, duration = 10 }

    RC.racialAbilityKeys = {
        "bloodfury", "berserking", "escapeartist", "stoneform",
        "willoftheforsaken", "warstomp", "perception", "shadowmeld",
        "cannibalize",
    }

    -- Appended after racialAbilityKeys rather than grouped with the other
    -- PALADIN entries above; still referenced by classAbilityGrids.PALADIN.
    A.repentance = { class = "PALADIN", name = "Repentance",
        icon = "Interface\\Icons\\Spell_Holy_PrayerOfHealing",
        description = RCL["Incapacitate a humanoid (talent)"],
        spellId = 20066, cooldown = 60, duration = 6 }
    A.blessingoffreedom = { class = "PALADIN", name = "Blessing of Freedom",
        icon = "Interface\\Icons\\Spell_Holy_SealOfValor",
        description = RCL["Free the target from movement effects"],
        spellId = 1044, cooldown = 25, duration = 10 }
    A.blessingofsacrifice = { class = "PALADIN", name = "Blessing of Sacrifice",
        icon = "Interface\\Icons\\Spell_Holy_SealOfSacrifice",
        description = RCL["Redirect part of target's damage to you"],
        spellIds = {6940, 20729}, cooldown = 30, duration = 30 }
    A.fireresaura = { class = "PALADIN", name = "Fire Resistance Aura",
        icon = "Interface\\Icons\\Spell_Fire_SealOfFire",
        description = RCL["Aura assignment (Molten Core, BWL)"],
        spellIds = {19891, 19899, 19900}, cooldown = 0, duration = 0 }
    A.frostresaura = { class = "PALADIN", name = "Frost Resistance Aura",
        icon = "Interface\\Icons\\Spell_Frost_WizardMark",
        description = RCL["Aura assignment (Sapphiron)"],
        spellIds = {19888, 19897, 19898}, cooldown = 0, duration = 0 }
    A.shadowresaura = { class = "PALADIN", name = "Shadow Resistance Aura",
        icon = "Interface\\Icons\\Spell_Shadow_SealOfKings",
        description = RCL["Aura assignment (Naxxramas)"],
        spellIds = {19876, 19895, 19896}, cooldown = 0, duration = 0 }

    -- ================== PER-CLASS GRID ROSTERS ======================
    RC.classAbilityGrids = {
        MAGE    = { "arcanepower", "presenceofmind", "combustion", "coldsnap",
                    "iceblock", "icebarrier", "fireward", "frostward",
                    "counterspell", "blink", "evocation" },
        ROGUE   = { "adrenalinerush", "bladeflurry", "preparation", "coldblood", "evasion",
                    "sprint", "vanish", "kick", "blind" },
        HUNTER  = { "rapidfire", "bestialwrath", "readiness", "tranqshot",
                    "feigndeath", "deterrence", "freezingtrap", "scattershot",
                    "intimidation" },
        PRIEST  = { "powerinfusion", "innerfocus", "fearward", "shackleundead",
                    "fade", "silence", "desperateprayer" },
        WARLOCK = { "amplifycurse", "deathcoil", "darkpact", "shadowward", "banish",
                    "soulstone", "curseofdoom", "feldomination" },
        DRUID   = { "innervate", "natureswiftnessdruid", "rebirth", "barkskin",
                    "frenziedregen", "hibernate", "tranquility", "dash" },
        SHAMAN  = { "natureswiftnessshaman", "elementalmastery", "manatide",
                    "tremortotem", "groundingtotem" },
        PALADIN = { "divineshield", "divineprotection", "blessingofprotection",
                    "layonhands", "divinefavor", "repentance", "blessingoffreedom",
                    "blessingofsacrifice", "fireresaura", "frostresaura",
                    "shadowresaura" },
    }

    -- IsPlayerSpell is unavailable on some clients; treat as "known" rather
    -- than hiding every tile when we can't check.
    local function Knows(entry)
        if not IsPlayerSpell then return true end
        if entry.spellIds then
            for _, id in ipairs(entry.spellIds) do
                if IsPlayerSpell(id) then return true end
            end
            return false
        end
        return entry.spellId and IsPlayerSpell(entry.spellId) or false
    end

    function RC:GetAvailableAbilities(encounterType, encounterName)
        local list
        if self.isWarrior then
            if encounterType == "boss" then
                list = {
                    {"deathwish",     "Death Wish",         "Interface\\Icons\\Spell_Shadow_DeathPact"},
                    {"recklessness",  "Recklessness",       "Interface\\Icons\\Ability_CriticalStrike"},
                    {"potion",        "Consumable Potion",  "Interface\\Icons\\INV_Potion_41"},
                    {"trinkets",      "Trinkets / Summons", "Interface\\Icons\\INV_Trinket_Naxxramas04"},
                    {"utility",       "Utility Item",       "Interface\\Icons\\INV_Misc_Bomb_06"},
                    {"defensives",    "Defensives",         "Interface\\Icons\\Ability_Warrior_ShieldWall"},
                }
            else
                list = {
                    {"deathwish",     "Death Wish",         "Interface\\Icons\\Spell_Shadow_DeathPact"},
                    {"recklessness",  "Recklessness",       "Interface\\Icons\\Ability_CriticalStrike"},
                    {"gearswap",      "Gear Swap",          "Interface\\Icons\\INV_Chest_Plate16"},
                    {"bloodrage",     "Bloodrage",          "Interface\\Icons\\Ability_Racial_BloodRage"},
                    {"berserkerrage", "Berserker Rage",     "Interface\\Icons\\Spell_Nature_AncestralGuardian"},
                    {"potion",        "Consumable Potion",  "Interface\\Icons\\INV_Potion_41"},
                    {"trinkets",      "Trinkets",           "Interface\\Icons\\INV_Trinket_Naxxramas04"},
                    {"utility",       "Utility Item",       "Interface\\Icons\\INV_Misc_Bomb_06"},
                    {"defensives",    "Defensives",         "Interface\\Icons\\Ability_Warrior_ShieldWall"},
                }
            end
        else
            list = {}
            local _, classToken = UnitClass("player")
            local roster = classToken and self.classAbilityGrids[classToken]
            if roster then
                for _, key in ipairs(roster) do
                    local entry = self.abilityData[key]
                    if entry and Knows(entry) then
                        list[#list + 1] = { key, entry.name, entry.icon }
                    end
                end
            end
            list[#list + 1] = {"potion",   "Consumable Potion",  "Interface\\Icons\\INV_Potion_41"}
            list[#list + 1] = {"trinkets", (encounterType == "boss") and "Trinkets / Summons" or "Trinkets",
                               "Interface\\Icons\\INV_Trinket_Naxxramas04"}
            list[#list + 1] = {"utility",  "Utility Item",       "Interface\\Icons\\INV_Misc_Bomb_06"}
        end

        -- Insert known racials as a block immediately before the "potion"
        -- entry, regardless of which class branch built the list above.
        do
            local insertAt = #list + 1
            for i, e in ipairs(list) do
                if e[1] == "potion" then insertAt = i break end
            end
            for _, key in ipairs(self.racialAbilityKeys) do
                local entry = self.abilityData[key]
                if entry and Knows(entry) then
                    table.insert(list, insertAt, { key, entry.name, entry.icon })
                    insertAt = insertAt + 1
                end
            end
        end

        if encounterType == "boss" and encounterName == "Kel'Thuzad" then
            list[#list + 1] = {"frostBlast", "Frost Blast HP", "Interface\\Icons\\Spell_Frost_FrostBlast"}
        end
        return list
    end

    function RC:PrintClassAbilityRoster()
        local _, classToken = UnitClass("player")
        local roster
        if self.isWarrior then
            roster = { "deathwish", "recklessness", "bloodrage", "berserkerrage" }
        else
            roster = classToken and self.classAbilityGrids[classToken]
        end
        if not roster then self:Print(RCL["No ability roster for this class."]); return end
        self:Print(RCL["Ability roster for "] .. (classToken or "?")
            .. RCL[" (unknown = not learned yet; tiles appear when learned):"])
        for _, key in ipairs(roster) do
            local e = self.abilityData[key]
            if e then
                local known = Knows(e)
                self:Print("  " .. (known and "|cff00ff00KNOWN|r   " or "|cff888888unknown|r ") .. e.name)
            end
        end
        self:Print(RCL["  Racials:"])
        for _, key in ipairs(self.racialAbilityKeys) do
            local e = self.abilityData[key]
            if e and Knows(e) then
                self:Print("  |cff00ff00KNOWN|r   " .. e.name)
            end
        end
    end

    RC:DebugPrint("Class abilities loaded (multi-class rosters active)", "system")
end

InitializeClassAbilities()
