------------------------------------------------------------------------
-- Readycheck - Raid data for WoW Forever
-- Empty for now: Forever's raids are not listed yet, so the raid features
-- stay off there (Core_Flavor says why). Adding them is data only: fill
-- RAIDS in the same shape as RaidConfigsTBC.lua (name, code, abbr, label,
-- instanceId, icon, zones, bosses, sections, configs, packs) and
-- RC:ApplyRaidFlavor (RaidFlavor.lua) lists them and switches the raid
-- features on for Forever.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
RC._raidFlavors = RC._raidFlavors or {}

local function Off(t) t.enabled = false return t end

-- Forever is a level 60 game: Classic Era's potions
local function Abilities(kind, o)
    o = o or {}
    local a = {
        deathwish = Off({ triggerType = "hp_percent", hpValue = o.dw or 85 }),
        recklessness = Off({ triggerType = "buff_remaining", buffTimeRemaining = 10 }),
        mightyRagePotion = Off({ triggerType = "deathwish_time", buffTimeRemaining = 5, potionType = "mightyRagePotion" }),
        trinket1 = Off({ triggerType = "hp_percent", hpValue = 80 }),
    }
    if o.tank then
        a.stoneshieldPotion = Off({ triggerType = "combat_start", combatTime = 3, potionType = "stoneshieldPotion" })
        a.laststand = Off({ triggerType = "player_hp", playerHpValue = 40 })
    end
    if o.fear then a.berserkerrage = Off({ triggerType = "debuff_present", debuffName = o.fear }) end
    return a
end

local function Trash(o)
    local a = {}
    if o.rage then a.bloodrage = Off({ triggerType = "rage_threshold", rageValue = 20 }) end
    if o.dw then a.deathwish = Off({ triggerType = "hp_percent", hpValue = o.dw }) end
    return { abilities = a }
end

local RAIDS = {}

RC._raidFlavors.forever = {
    raids = RAIDS,
    Abilities = Abilities,
    Trash = Trash,
}
