------------------------------------------------------------------------
-- Readycheck - Buff Cap: the buff list
-- Everything the buff cap counter knows about buffs: what each one is,
-- where it comes from, and the slots the game fills without showing a
-- buff icon. Read by CS_BuffCap.lua, and by any other addon that wants
-- the same list (ZacUI's buff remover reads it through RC.BuffCapData).
--
-- A buff entry is { name, { spell ids } } plus any of:
--   provided  another player's aura or totem: it comes straight back
--   locked    the game does not let it be cancelled
--   fades     ends on its own (a proc, a short cooldown, a shield), so
--             it is never mistaken for a buff the cap pushed off
--   class     only that class can have it (race: only that race)
--   family    tags; two buffs sharing a tag replace each other, so one
--             leaving as the other lands is not a push-off
--   group     the "one of these at a time" group it belongs to
--   byName    matched by its spell ids AND by the buff's name (for buffs
--             whose ids differ by the target's class, like the tier-set
--             procs a healer's armour puts on you); such an entry has no
--             key, and a choice about it is saved under its name
--   note      a few words on where it comes from
-- The first spell id is the buff's key wherever a choice about it is
-- saved, so it must never change for an existing entry.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local D = {}
RC.BuffCapData = D

-- the client's buff limit; hidden slots come off this
D.CAP = 32
-- Each game version's buff limit, where it is confirmed (Classic Era: 32).
-- A version without one (TBC, Forever) has its limit measured instead,
-- from the first push-offs on that character (CS_BuffCap.lua).
D.CAP_BY_FLAVOR = { era = 32 }

D.CATEGORIES = {
    { id = "world", label = "World buffs" },
    { id = "cons",  label = "Consumables" },
    { id = "raid",  label = "From other players" },
    { id = "self",  label = "Your own" },
    { id = "proc",  label = "Procs and trinkets" },
    { id = "fun",   label = "Fun and utility" },
    { id = "seen",  label = "Other buffs you have had" },
}

D.GROUP_LABEL = {
    food = "Food", flask = "Flask", zanza = "Zanza and Blasted Lands", agi = "Agility elixir",
    str = "Strength elixir and Juju Power", armor = "Armor elixir and Scroll of Protection",
    arc = "Arcane elixir", firep = "Firepower elixir", int = "Intellect elixir",
    jap = "Juju Might and Firewater", stone = "Stoneshield", rum = "Alcohol",
    ssta = "Stamina: Fortitude or scroll", sint = "Intellect: Arcane Intellect or scroll",
    sspi = "Spirit: Divine Spirit or scroll", spp = "Shadow Protection", motw = "Mark of the Wild",
    bom = "Blessing of Might", bow = "Blessing of Wisdom", bok = "Blessing of Kings",
    salv = "Blessing of Salvation", bol = "Blessing of Light", bosanc = "Blessing of Sanctuary",
    seal = "Seal", aspect = "Aspect", marmor = "Mage armor", larmor = "Warlock armor",
    haste = "Power Infusion or Arcane Power", stealth = "Stealth",
}

------------------------------------------------------------------------
-- HIDDEN SLOTS: things that take one of the 32 without an icon.
------------------------------------------------------------------------
-- a buff that brings a second, invisible effect along with it
D.SECOND_EFFECT = {
    [24417] = "Sheen of Zanza (second effect)",
    [24659] = "Unstable Power (second effect)",
    [24662] = "Restless Strength (second effect)",
    [24575] = "Brittle Armor (second effect)",
    [26464] = "Mercurial Shield (second effect)",
    [29604] = "Jom Gabbar (second effect)",
    [28682] = "Combustion (second effect)",
}

-- equipped items that sit on a hidden aura while worn (item id -> labels)
D.EQUIPPED = {
    [18168] = { "Force Reactive Disk", "Force Reactive Disk (second effect)" },
    [23238] = { "Stygian Buckler" },
    [12628] = { "Demon Forged Breastplate" },
    [12805] = { "Orb of Fire" },
}

-- a cast that leaves a hidden aura for a while (spell id -> seconds, label)
D.AFTER_CAST = {
    [19638] = { 30, "Prismstone" },
}

-- tracking spells; when one shows as a buff its slot is already counted
D.TRACKING = {
    [2383] = true, [8387] = true, [2580] = true, [8388] = true, [2481] = true, [1494] = true,
    [19878] = true, [19879] = true, [19880] = true, [19882] = true, [19883] = true, [19884] = true,
    [5225] = true, [5500] = true, [5502] = true,
}

-- druid cat and bear forms carry two passives as hidden auras
D.FERAL_FORMS = { [1] = true, [5] = true, [8] = true }
D.FELINE_SWIFTNESS = { 17002, 24866 }
D.PREDATORY_STRIKES = { 16972, 16974, 16975 }

-- The "Defensive State" aura behind Revenge, Mongoose Bite and Riposte
-- takes a slot for 5 seconds after the attack it needs: which kinds of
-- avoided attack wake it, per class (hunters and rogues only once the
-- spell is learned).
D.DEFENSIVE_STATE = {
    WARRIOR = { DODGE = true, PARRY = true, BLOCK = true },
    HUNTER  = { DODGE = true },
    ROGUE   = { PARRY = true },
}
D.DEFENSIVE_NEEDS = {
    HUNTER = { 1495, 14269, 14270, 14271 },  -- Mongoose Bite
    ROGUE  = { 14251 },                      -- Riposte
}
D.DEFENSIVE_SECONDS = 5

-- tanking, for the "drop Salvation while tanking" choice
D.TANK_FORMS = { [18] = true, [5] = true, [8] = true }
D.RIGHTEOUS_FURY = 25780

------------------------------------------------------------------------
-- THE BUFFS, by category
------------------------------------------------------------------------
D.BUFFS = {}

D.BUFFS.world = {
    { "Rallying Cry of the Dragonslayer", { 22888, 355363 } },
    { "Spirit of Zandalar", { 24425, 355365 } },
    { "Warchief's Blessing", { 16609, 355366 } },
    { "Songflower Serenade", { 15366 } },
    { "Fengus' Ferocity", { 22817 } },
    { "Mol'dar's Moxie", { 22818 } },
    { "Slip'kik's Savvy", { 22820 } },
    { "Sayge's Dark Fortune", { 23768, 23735, 23736, 23737, 23738, 23766, 23767, 23769 }, family = "dmf" },
    { "Blessing of Blackfathom", { 8733 } },
    { "Chronoboon (stored buffs)", { 349981 }, locked = true },
    { "Elune's Blessing", { 26393 } },
    { "Fire Festival Fury", { 29338, 29846 } },
}

D.BUFFS.cons = {
    { "Flask of the Titans", { 17626 }, family = "flask", group = "flask" },
    { "Flask of Distilled Wisdom", { 17627 }, family = "flask", group = "flask" },
    { "Flask of Supreme Power", { 17628 }, family = "flask", group = "flask" },
    { "Flask of Chromatic Resistance", { 17629 }, family = "flask", group = "flask" },
    { "Flask of Petrification", { 17624 }, family = "flask", group = "flask" },
    { "Spirit of Zanza", { 24382 }, family = "g1003 g1004 zanza", group = "zanza" },
    { "Swiftness of Zanza", { 24383 }, family = "g1003 zanza", group = "zanza" },
    { "Sheen of Zanza", { 24417 }, family = "g1003 zanza", group = "zanza" },
    { "Rage of Ages (R.O.I.D.S.)", { 10667 }, family = "g1008 zanza", group = "zanza" },
    { "Strike of the Scorpok", { 10669 }, family = "g1008 zanza", group = "zanza" },
    { "Spirit of Boar", { 10668 }, family = "g1004 g1008 zanza", group = "zanza" },
    { "Infallible Mind", { 10692 }, family = "g1008 zanza", group = "zanza" },
    { "Spiritual Domination", { 10693 }, family = "g1004 g1008 zanza", group = "zanza" },
    { "Juju Power", { 16323 }, family = "jstr", group = "str" },
    { "Juju Might", { 16329 }, family = "g1072 jap", group = "jap" },
    { "Juju Flurry", { 16322 } },
    { "Juju Guile", { 16327 } },
    { "Juju Ember", { 16326 } },
    { "Juju Chill", { 16325 } },
    { "Juju Escape", { 16321 } },
    { "Winterfall Firewater", { 17038 }, family = "g1072 jap", group = "jap" },
    { "Elixir of the Mongoose", { 17538 }, family = "agi", group = "agi" },
    { "Greater Agility (elixir)", { 11334 }, family = "agi", group = "agi" },
    { "Agility (elixir)", { 11328, 3160 }, family = "agi", group = "agi" },
    { "Lesser Agility (elixir)", { 2374 }, family = "agi", group = "agi" },
    { "Elixir of the Giants", { 11405 }, family = "str", group = "str" },
    { "Strength (elixir)", { 3164 }, family = "str", group = "str" },
    { "Lesser Strength (elixir)", { 2367 }, family = "str", group = "str" },
    { "Elixir of Brute Force", { 17537 }, family = "str" },
    { "Health II (Elixir of Fortitude)", { 3593 } },
    { "Health (Elixir of Minor Fortitude)", { 2378 } },
    { "Greater Armor (Superior Defense)", { 11348 }, family = "armor", group = "armor" },
    { "Armor (elixir)", { 11349, 3220 }, family = "armor g1022", group = "armor" },
    { "Lesser Armor (elixir)", { 673 }, family = "armor g1022", group = "armor" },
    { "Greater Arcane Elixir", { 17539 }, family = "arc g1023", group = "arc" },
    { "Arcane Elixir", { 11390 }, family = "arc g1023", group = "arc" },
    { "Shadow Power", { 11474 } },
    { "Greater Firepower", { 26276 }, family = "firep g1024", group = "firep" },
    { "Fire Power", { 7844 }, family = "firep g1024", group = "firep" },
    { "Frost Power", { 21920 } },
    { "Greater Intellect (elixir)", { 11396 }, family = "int", group = "int" },
    { "Lesser Intellect (elixir)", { 3166 }, family = "int", group = "int" },
    { "Elixir of the Sages", { 17535 }, family = "int" },
    { "Mana Regeneration (Mageblood)", { 24363 } },
    { "Regeneration (Troll's Blood)", { 24361, 3223, 3222, 3219 }, family = "troll" },
    { "Elixir of Demonslaying", { 11406 } },
    { "Elixir of Dodging", { 27653 } },
    { "Elixir of Resistance", { 27652 } },
    { "Stealth Detection (Catseye)", { 12608 } },
    { "Detect Undead (elixir)", { 11389 } },
    { "Detect Demon (elixir)", { 11407 } },
    { "Detect Lesser Invisibility (elixir)", { 6512 } },
    { "Water Breathing (elixir)", { 7178, 22807 } },
    { "Water Walking (elixir)", { 11319 } },
    { "Enlarge (Giant Growth)", { 8212 } },
    { "Greater Fire Protection", { 17543, 7233 }, fades = true, family = "fpp g1074" },
    { "Greater Frost Protection", { 17544, 7239 }, fades = true, family = "frpp g1075" },
    { "Greater Nature Protection", { 17546, 7254 }, fades = true, family = "g1076 npp" },
    { "Greater Shadow Protection", { 17548, 7242 }, fades = true, family = "g1077 sppot" },
    { "Greater Holy Protection", { 17545, 7245 }, fades = true, family = "hpp" },
    { "Greater Arcane Protection", { 17549 }, fades = true, family = "app" },
    { "Free Action", { 6615, 24364 } },
    { "Restoration (Restorative Potion)", { 11359 } },
    { "Invulnerability (LIP)", { 3169 } },
    { "Mighty Rage", { 17528 } },
    { "Speed (Swiftness Potion)", { 2379 } },
    { "Swim Speed", { 7840 } },
    { "Resistance (Magic Resistance Potion)", { 11364, 2380 } },
    { "Greater Stoneshield", { 17540 }, family = "stone", group = "stone" },
    { "Stoneshield", { 4941 }, family = "stone", group = "stone" },
    { "Invisibility (potion)", { 11392, 3680 }, fades = true },
    { "Gift of Arthas", { 11371 } },
    { "Fire Shield (Oil of Immolation)", { 11350 } },
    { "Well Fed (Desert Dumplings)", { 24799 }, family = "food g1001", group = "food" },
    { "Increased Stamina (Chimaerok Chops)", { 25661 }, family = "food g1001", group = "food" },
    { "Increased Agility (Grilled Squid)", { 18192 }, family = "food g1001", group = "food" },
    { "Mana Regeneration (Nightfin Soup)", { 18194 }, family = "food g1001", group = "food" },
    { "Increased Intellect (Runn Tum Tuber)", { 22730 }, family = "food g1001", group = "food" },
    { "Increased Stamina (Mightfish)", { 18191 }, family = "food g1001", group = "food" },
    { "Increased Spirit (Smoked Bass)", { 18193 }, family = "food", group = "food" },
    { "Health Regeneration (Sunscale Salmon)", { 18222 }, family = "food g1001", group = "food" },
    { "Well Fed (other food)", { 19710, 19705, 19706, 19708, 19709, 19711, 24870, 25694, 25941 }, family = "food g1001", group = "food" },
    { "Blessed Sunfruit", { 18125 }, family = "food g1001", group = "food" },
    { "Blessed Sunfruit Juice", { 18141 }, family = "food g1001", group = "food" },
    { "Alterac Spring Water", { 23697 }, family = "g1001" },
    { "Dragonbreath Chili", { 15852 }, fades = true, family = "food", group = "food" },
    { "Rumsey Rum", { 25804, 25722, 25037, 20875 }, family = "g1054 rum", group = "rum" },
    { "Gordok Green Grog", { 22789 }, family = "g1054 rum", group = "rum" },
    { "Kreeg's Stout Beatdown", { 22790 }, family = "g1054 rum", group = "rum" },
    { "Agility (scroll)", { 12174, 8117, 8116, 8115 }, family = "g1018 g1061 sagi" },
    { "Strength (scroll)", { 12179, 8120, 8119, 8118 }, family = "g1017 g1062 sstr" },
    { "Armor (Scroll of Protection)", { 12175, 8095, 8094, 8091 }, family = "g1022 sprot", group = "armor" },
    { "Spirit (scroll)", { 12177, 8114, 8113, 8112 }, family = "g1021 g1057 g1058 sspi", group = "sspi" },
    { "Stamina (scroll)", { 12178, 8101, 8100, 8099 }, family = "g1019 g1055 g1056 ssta", group = "ssta" },
    { "Intellect (scroll)", { 12176, 8098, 8097, 8096 }, family = "g1020 g1059 g1060 sint", group = "sint" },
    { "Crystal Force", { 15231 } },
    { "Crystal Ward", { 15233 } },
    { "Crystal Spire", { 15279 } },
    { "Fury of the Bogling", { 5665 } },
    { "Holy Mightstone", { 24833 } },
}

D.BUFFS.raid = {
    -- healers' tier-set procs that land on YOU (each takes a slot)
    -- (ids per the target's class: armor for warriors, then attack power,
    -- spell damage, mana regeneration)
    { "Holy Power", { 28790, 28791, 28793, 28795 }, byName = true, note = "Paladin tier 3, 6 pieces" },
    { "Armor of Faith", { 28810 }, byName = true, note = "Priest tier 3, 4 pieces" },
    { "Totemic Power", { 28827, 28826, 28825, 28824 }, byName = true, note = "Shaman tier 3, 6 pieces" },
    { "Blessing of the Claw", { 28750 }, byName = true, note = "Druid tier 3, 6 pieces" },
    { "Power of the Guardian (Atiesh)", { 28142, 28143, 28144, 28145 }, provided = true },
    { "Power Word: Fortitude", { 10938, 10937, 2791, 1245, 1244, 1243, 23947, 23948 }, family = "g1055 ssta", group = "ssta" },
    { "Prayer of Fortitude", { 21564, 21562 }, family = "g1055 ssta", group = "ssta" },
    { "Divine Spirit", { 27841, 14819, 14818, 14752, 16875 }, family = "g1057 sspi", group = "sspi" },
    { "Prayer of Spirit", { 27681 }, family = "g1057 sspi", group = "sspi" },
    { "Shadow Protection (priest)", { 10958, 10957, 976, 16874 }, family = "g1071 spp", group = "spp" },
    { "Prayer of Shadow Protection", { 27683 }, family = "spp", group = "spp" },
    { "Fear Ward", { 6346 }, fades = true },
    { "Power Word: Shield", { 10901, 10900, 10899, 10898, 6066, 6065, 3747, 600, 592, 17 }, fades = true },
    { "Renew", { 25315, 10929, 10928, 10927, 6078, 6077, 6076, 6075, 6074, 139 }, family = "g1031" },
    { "Power Infusion", { 10060 }, family = "g1063", group = "haste" },
    { "Inspiration", { 15359, 15357, 14893 } },
    { "Abolish Disease", { 552 } },
    { "Lightwell Renew", { 27874, 27873, 7001 }, fades = true },
    { "Arcane Intellect", { 10157, 10156, 1461, 1460, 1459, 16876 }, family = "g1060 sint", group = "sint" },
    { "Arcane Brilliance", { 23028 }, family = "g1060 sint", group = "sint" },
    { "Amplify Magic", { 10170, 10169, 8455, 1008 } },
    { "Dampen Magic", { 10174, 10173, 8451, 8450, 604 } },
    { "Mark of the Wild", { 9885, 9884, 8907, 5234, 6756, 5232, 1126, 16878, 24752 }, family = "g1056 g1058 g1059 g1061 g1062", group = "motw" },
    { "Gift of the Wild", { 21850, 21849 }, family = "g1056 g1058 g1059 g1061 g1062", group = "motw" },
    { "Thorns", { 9910, 9756, 8914, 1075, 782, 467, 16877 } },
    { "Rejuvenation", { 25299, 9841, 9840, 9839, 8910, 3627, 2091, 2090, 1430, 1058, 774 }, family = "g1030" },
    { "Regrowth", { 9858, 9857, 9856, 9750, 8941, 8940, 8939, 8938, 8936 } },
    { "Innervate", { 29166 } },
    { "Abolish Poison", { 2893 } },
    { "Leader of the Pack", { 24932 }, provided = true },
    { "Moonkin Aura", { 24907 }, provided = true },
    { "Blessing of Might", { 25291, 19838, 19837, 19836, 19835, 19834, 19740 }, family = "bless bom g1002 g1045 g1046", group = "bom" },
    { "Greater Blessing of Might", { 25916, 25782 }, family = "bless bom g1002 g1045 g1046", group = "bom" },
    { "Blessing of Wisdom", { 25290, 19854, 19853, 19852, 19850, 19742 }, family = "bless bow g1005 g1047 g1048", group = "bow" },
    { "Greater Blessing of Wisdom", { 25918, 25894 }, family = "bless bow g1005 g1047 g1048", group = "bow" },
    { "Blessing of Kings", { 20217 }, family = "bless bok g1006 g1049 g1050 g1051", group = "bok" },
    { "Greater Blessing of Kings", { 25898 }, family = "bless bok g1006 g1049 g1050 g1051", group = "bok" },
    { "Blessing of Salvation", { 1038 }, family = "bless g1044 salv", group = "salv" },
    { "Greater Blessing of Salvation", { 25895 }, family = "bless g1044 salv", group = "salv" },
    { "Blessing of Light", { 19979, 19978, 19977 }, family = "bless bol g1068", group = "bol" },
    { "Greater Blessing of Light", { 25890 }, family = "bless bol g1068", group = "bol" },
    { "Blessing of Sanctuary", { 20914, 20913, 20912, 20911 }, family = "bless bosanc g1007 g1052 g1053", group = "bosanc" },
    { "Greater Blessing of Sanctuary", { 25899 }, family = "bless bosanc g1007 g1052 g1053", group = "bosanc" },
    { "Blessing of Freedom", { 1044 } },
    { "Blessing of Protection", { 10278, 5599, 1022 } },
    { "Blessing of Sacrifice", { 20729, 6940 } },
    { "Divine Intervention", { 19753 } },
    { "Lay on Hands (armor)", { 20236, 20233 } },
    { "Devotion Aura", { 10293, 10292, 1032, 10291, 643, 10290, 465 }, provided = true, family = "g1040 g1041" },
    { "Retribution Aura", { 10301, 10300, 10299, 10298, 7294 }, provided = true },
    { "Concentration Aura", { 19746 }, provided = true },
    { "Sanctity Aura", { 20218 }, provided = true },
    { "Shadow Resistance Aura", { 19896, 19895, 19876 }, provided = true },
    { "Frost Resistance Aura", { 19898, 19897, 19888 }, provided = true, family = "g1042" },
    { "Fire Resistance Aura", { 19900, 19899, 19891 }, provided = true, family = "g1043" },
    { "Strength of Earth", { 25362, 10441, 8163, 8162, 8076 }, provided = true, family = "g1045 g1049" },
    { "Grace of Air", { 25360, 10626, 8836 }, provided = true, family = "g1050" },
    { "Mana Spring", { 10494, 10493, 10491, 5677, 24853 }, provided = true, family = "g1047" },
    { "Mana Tide", { 17360, 17355, 16191 }, provided = true, family = "g1048" },
    { "Tranquil Air", { 25909 }, provided = true, family = "g1044" },
    { "Fire Resistance (totem)", { 10535, 10534, 8185 }, provided = true, family = "g1043" },
    { "Frost Resistance (totem)", { 10477, 10476, 8182 }, provided = true, family = "g1042" },
    { "Nature Resistance (totem)", { 10599, 10598, 10596 }, provided = true },
    { "Stoneskin", { 10405, 10404, 10403, 8157, 8156, 8072 }, provided = true, family = "g1040 g1052" },
    { "Healing Stream", { 10461, 10460, 6372, 6371, 5672 }, provided = true },
    { "Windwall", { 15110, 15109, 15108 }, provided = true, family = "g1041 g1053" },
    { "Ancestral Fortitude", { 16237, 16236, 16177 } },
    { "Healing Way", { 29203 } },
    { "Water Walking (shaman)", { 546 }, fades = true },
    { "Water Breathing (shaman)", { 131 } },
    { "Battle Shout", { 25289, 11551, 11550, 11549, 6192, 5242, 6673, 27578 }, family = "g1065" },
    { "Trueshot Aura", { 20906, 20905, 19506 }, provided = true },
    { "Aspect of the Pack", { 13159 }, provided = true, fades = true },
    { "Aspect of the Wild", { 20190, 20043 }, provided = true },
    { "Blood Pact", { 11767, 11766, 7805, 7804, 6307 }, provided = true },
    { "Paranoia", { 19480 }, provided = true },
    { "Fire Shield (Imp)", { 11771, 11770, 8317, 8316, 2947 } },
    { "Unending Breath", { 5697 } },
    { "Detect Invisibility", { 11743, 2970, 132 }, family = "g1066" },
    { "Soulstone Resurrection", { 20765, 20764, 20763, 20762, 20707 } },
    { "Levitate", { 1706 }, fades = true },
    { "Slow Fall", { 130 } },
}

D.BUFFS.self = {
    { "Bloodrage", { 29131 }, class = "WARRIOR" },
    { "Berserker Rage", { 18499 }, class = "WARRIOR" },
    { "Recklessness", { 1719 }, class = "WARRIOR" },
    { "Shield Wall", { 871 }, class = "WARRIOR" },
    { "Last Stand", { 12976 }, class = "WARRIOR" },
    { "Shield Block", { 2565 }, fades = true, class = "WARRIOR" },
    { "Sweeping Strikes", { 12292 }, fades = true, class = "WARRIOR" },
    { "Retaliation", { 20230 }, fades = true, class = "WARRIOR" },
    { "Flurry", { 12970, 12969, 12968, 12967, 12966 }, fades = true, class = "WARRIOR" },
    { "Enrage", { 14204, 14203, 14202, 14201, 12880 }, fades = true, class = "WARRIOR" },
    { "Slice and Dice", { 6774, 5171 }, class = "ROGUE" },
    { "Blade Flurry", { 13877 }, class = "ROGUE" },
    { "Adrenaline Rush", { 13750 }, class = "ROGUE" },
    { "Evasion", { 5277 }, class = "ROGUE" },
    { "Sprint", { 11305, 8696, 2983 }, class = "ROGUE" },
    { "Stealth", { 1787, 1786, 1785, 1784 }, fades = true, class = "ROGUE", family = "g1070", group = "stealth" },
    { "Vanish", { 11329, 11327 }, fades = true, class = "ROGUE" },
    { "Cold Blood", { 14177 }, fades = true, class = "ROGUE" },
    { "Remorseless", { 14151, 14149, 14143 }, fades = true, class = "ROGUE" },
    { "Mage Armor", { 22783, 22782, 6117 }, class = "MAGE", family = "marmor", group = "marmor" },
    { "Ice Armor", { 10220, 10219, 7320, 7302 }, class = "MAGE", family = "marmor", group = "marmor" },
    { "Frost Armor", { 7301, 7300, 168 }, class = "MAGE", family = "marmor", group = "marmor" },
    { "Arcane Power", { 12042 }, class = "MAGE", family = "g1063", group = "haste" },
    { "Presence of Mind", { 12043 }, fades = true, class = "MAGE" },
    { "Combustion", { 28682 }, class = "MAGE" },
    { "Ice Barrier", { 13033, 13032, 13031, 11426 }, fades = true, class = "MAGE" },
    { "Mana Shield", { 10193, 10192, 10191, 8495, 8494, 1463 }, fades = true, class = "MAGE" },
    { "Ice Block", { 11958 }, class = "MAGE" },
    { "Evocation", { 12051 }, class = "MAGE" },
    { "Fire Ward", { 10225, 10223, 8458, 8457, 543 }, fades = true, class = "MAGE" },
    { "Frost Ward", { 28609, 10177, 8462, 8461, 6143 }, fades = true, class = "MAGE" },
    { "Clearcasting (mage)", { 12536 }, fades = true, class = "MAGE" },
    { "Rapid Fire", { 3045 }, class = "HUNTER" },
    { "Quick Shots", { 6150 }, class = "HUNTER" },
    { "Deterrence", { 19263 }, class = "HUNTER" },
    { "Eagle Eye", { 6197 }, class = "HUNTER" },
    { "Aspect of the Hawk", { 25296, 14322, 14321, 14320, 14319, 14318, 13165 }, class = "HUNTER", family = "aspect", group = "aspect" },
    { "Aspect of the Monkey", { 13163 }, class = "HUNTER", family = "aspect", group = "aspect" },
    { "Aspect of the Cheetah", { 5118 }, fades = true, class = "HUNTER", family = "aspect", group = "aspect" },
    { "Aspect of the Beast", { 13161 }, class = "HUNTER", family = "aspect", group = "aspect" },
    { "Feign Death", { 5384 }, fades = true, class = "HUNTER" },
    { "Demon Armor", { 11735, 11734, 11733, 1086, 706 }, class = "WARLOCK", family = "larmor", group = "larmor" },
    { "Demon Skin", { 696, 687 }, class = "WARLOCK", family = "larmor", group = "larmor" },
    { "Shadow Ward", { 28610, 11740, 11739, 6229 }, fades = true, class = "WARLOCK" },
    { "Amplify Curse", { 18288 }, fades = true, class = "WARLOCK" },
    { "Fel Domination", { 18708 }, fades = true, class = "WARLOCK" },
    { "Shadow Trance", { 17941 }, class = "WARLOCK" },
    { "Demonic Sacrifice", { 18789, 18791, 18792, 18790 }, class = "WARLOCK" },
    { "Sacrifice (Voidwalker)", { 19443, 19442, 19441, 19440, 19438, 7812 }, fades = true, class = "WARLOCK" },
    { "Inner Fire", { 10952, 10951, 1006, 602, 7128, 588 }, fades = true, class = "PRIEST" },
    { "Inner Focus", { 14751 }, fades = true, class = "PRIEST" },
    { "Spirit Tap", { 15271 }, class = "PRIEST" },
    { "Shadowform", { 15473 }, class = "PRIEST" },
    { "Elune's Grace", { 19293, 19292, 19291, 19289, 2651 }, class = "PRIEST" },
    { "Feedback", { 19275, 19274, 19273, 19271, 13896 }, class = "PRIEST" },
    { "Shadowguard", { 19312, 19311, 19310, 19309, 19308, 18137 }, fades = true, class = "PRIEST" },
    { "Touch of Weakness", { 19266, 19265, 19264, 19262, 19261, 2652 }, fades = true, class = "PRIEST" },
    { "Blessed Recovery", { 27818, 27817, 27813 }, class = "PRIEST" },
    { "Focused Casting", { 27828, 14743 }, class = "PRIEST" },
    { "Righteous Fury", { 25780 }, class = "PALADIN" },
    { "Seal of Righteousness", { 20293, 20292, 20291, 20290, 20289, 20288, 20287, 20154, 21084 }, class = "PALADIN", family = "seal", group = "seal" },
    { "Seal of the Crusader", { 20308, 20307, 20306, 20305, 20162, 21082 }, class = "PALADIN", family = "seal", group = "seal" },
    { "Seal of Command", { 20920, 20919, 20918, 20915, 20375 }, class = "PALADIN", family = "seal", group = "seal" },
    { "Seal of Wisdom", { 20357, 20356, 20166 }, class = "PALADIN", family = "seal", group = "seal" },
    { "Seal of Light", { 20349, 20348, 20347, 20165 }, class = "PALADIN", family = "seal", group = "seal" },
    { "Seal of Justice", { 20164 }, class = "PALADIN", family = "seal", group = "seal" },
    { "Divine Shield", { 1020, 642 }, class = "PALADIN" },
    { "Divine Protection", { 5573, 498 }, class = "PALADIN" },
    { "Divine Favor", { 20216 }, fades = true, class = "PALADIN" },
    { "Vengeance", { 20055, 20054, 20053, 20052, 20050 }, class = "PALADIN" },
    { "Barkskin", { 22812 }, class = "DRUID" },
    { "Dash", { 9821, 1850 }, class = "DRUID" },
    { "Nature's Grasp", { 17329, 16813, 16812, 16811, 16810, 16689 }, fades = true, class = "DRUID" },
    { "Nature's Swiftness (druid)", { 17116 }, fades = true, class = "DRUID" },
    { "Omen of Clarity", { 16864 }, class = "DRUID" },
    { "Clearcasting (druid)", { 16870 }, fades = true, class = "DRUID" },
    { "Tiger's Fury", { 9846, 9845, 6793, 5217 }, class = "DRUID" },
    { "Frenzied Regeneration", { 22896, 22895, 22842 }, class = "DRUID" },
    { "Enrage (druid)", { 5229 }, class = "DRUID" },
    { "Prowl", { 9913, 6783, 5215 }, fades = true, class = "DRUID" },
    { "Tranquility", { 9863, 8918, 740 }, provided = true, class = "DRUID" },
    { "Lightning Shield", { 10432, 10431, 8134, 945, 905, 325, 324 }, fades = true, class = "SHAMAN" },
    { "Elemental Mastery", { 16166 }, fades = true, class = "SHAMAN" },
    { "Nature's Swiftness (shaman)", { 16188 }, fades = true, class = "SHAMAN" },
    { "Clearcasting (shaman)", { 16246 }, fades = true, class = "SHAMAN" },
    { "Flurry (shaman)", { 16280, 16279, 16278, 16277, 16257 }, fades = true, class = "SHAMAN" },
    { "Ghost Wolf", { 2645 }, class = "SHAMAN" },
    { "Berserking (Troll)", { 26635 }, race = "Troll" },
    { "Blood Fury (Orc)", { 23234 }, race = "Orc" },
    { "Perception (Human)", { 20600 }, race = "Human" },
    { "Stoneform (Dwarf)", { 20594 }, race = "Dwarf" },
    { "Will of the Forsaken", { 7744 }, race = "Scourge" },
    { "Shadowmeld (Night Elf)", { 20580 }, fades = true, race = "NightElf", family = "g1070", group = "stealth" },
}

D.BUFFS.proc = {
    { "Holy Strength (Crusader)", { 20007 } },
    { "Haste (Empyrean Demolisher)", { 21165 } },
    { "Haste (Crowd Pummeler)", { 13494 } },
    { "Untamed Fury", { 23719 } },
    { "Spell Blasting", { 25907 } },
    { "Aura of the Blue Dragon", { 23684 } },
    { "Kiss of the Spider", { 28866 } },
    { "Jom Gabbar", { 29604 } },
    { "Earthstrike", { 25891 } },
    { "Diamond Flask", { 24427 } },
    { "Badge of the Swarmguard", { 26480 } },
    { "Insight of the Qiraji", { 26481 } },
    { "Unstable Power (Hero Charm)", { 24659 } },
    { "Restless Strength (Hero Medallion)", { 24662 } },
    { "Brittle Armor (Hero Badge)", { 24575 } },
    { "Ephemeral Power (TOEP)", { 23271 } },
    { "Mind Quickening", { 23723 } },
    { "Nature Aligned", { 23734 } },
    { "Obsidian Insight", { 26166 } },
    { "Devilsaur Fury", { 24352 } },
    { "Prayer Beads Blessing", { 24354 } },
    { "Healing of the Ages", { 24998 } },
    { "Chromatic Infusion", { 27675 } },
    { "Essence of Sapphiron", { 28779 } },
    { "Slayer's Crest", { 28777 } },
    { "Glyph of Deflection", { 28773 } },
    { "The Burrower's Shell", { 29506 }, fades = true },
    { "The Eye of the Dead", { 28780 }, fades = true },
    { "Persistent Shield", { 26467 } },
    { "Mercurial Shield (Petrified Scarab)", { 26464 } },
    { "Arcane Shroud", { 26400 } },
    { "Ascendance", { 28200, 28204 }, fades = true },
    { "Fearless", { 12733 } },
    { "Mar'li's Brain Boost", { 24268 } },
    { "Aegis of Preservation", { 23780 } },
    { "Massive Destruction", { 24543 } },
    { "Arcane Potency", { 24544 } },
    { "Rapid Healing", { 24546 } },
    { "Nimble Healing Touch", { 24542 } },
    { "Energized Shield", { 24499 } },
    { "Brilliant Light", { 24498 } },
    { "Rocket Boots", { 13141, 8892 } },
    { "Speed (Nifty Stopwatch)", { 14530 } },
    { "Static Barrier (Gigaflux)", { 11841 } },
}

D.BUFFS.fun = {
    { "Noggenfogger", { 16591, 16593, 16595 } },
    { "Flip Out", { 8219, 8220 } },
    { "Yaaarrrr", { 8221, 8222 } },
    { "Furbolg Form", { 6405 }, fades = true },
    { "Mistletoe", { 26004 } },
    { "Snowman", { 21848 }, fades = true },
    { "Toast", { 26008 } },
    { "Costumes (Hallowed Wand)", { 24732, 24723, 24740, 24708, 24709, 24710, 24711, 24712, 24713 } },
    { "Perfume / Cologne", { 26682, 26681 } },
    { "Gift of Friendship", { 27664, 27665, 27666, 27669, 27670, 27671 } },
}

------------------------------------------------------------------------
-- LOOKUPS: D.ALL (every entry, category order), D.BY_ID (any spell id
-- -> entry), D.BY_KEY (first spell id -> entry). Family tags become sets.
------------------------------------------------------------------------
D.ALL, D.BY_ID, D.BY_KEY, D.BY_NAME = {}, {}, {}, {}
for _, cat in ipairs(D.CATEGORIES) do
    for _, e in ipairs(D.BUFFS[cat.id] or {}) do
        e.name, e.ids, e[1], e[2] = e[1], e[2], nil, nil
        e.cat = cat.id
        e.key = (not e.byName) and e.ids[1] or nil
        if e.family then
            local set = {}
            for tag in e.family:gmatch("%S+") do set[tag] = true end
            e.family = set
        end
        D.ALL[#D.ALL + 1] = e
        if e.key then D.BY_KEY[e.key] = e end
        for _, id in ipairs(e.ids) do D.BY_ID[id] = e end
        if e.byName then D.BY_NAME[e.name] = e end
    end
end
