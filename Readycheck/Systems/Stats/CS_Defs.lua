------------------------------------------------------------------------
-- Readycheck - Character Stats: Definitions
-- Defines RC.CharacterStats (CS) and its state fields, the per-stat
-- getter/formatter table (STAT_DEFS), default stat lists per class/spec,
-- and durability slot/name maps. Loads before CS_Bar.lua and CS_Buffs.lua,
-- which both read these tables via the _css bridge table.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local UnitBuff = UnitBuff or (RCC and RCC.Compat and RCC.Compat.UnitBuff)
local AddonName = "Readycheck"

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local string_format = string.format
local GetTime = GetTime
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local RC = _G[AddonName]
if not RC then
    error("Readycheck addon not found!")
    return
end

RC._css = RC._css or {}
local _css = RC._css
RC.CharacterStats = {
    panelFrame = nil,
    toggleButton = nil,
    isPanelVisible = false,

    barFrame = nil,
    barStatTexts = {},

    eventFrame = nil,
    updateTimer = nil,
    lastUpdate = 0,
    pendingUpdate = false,

    panelWidth = 240,
    panelHeight = 400,

    statLines = {},

    statCache = {}
}

local CS = RC.CharacterStats

local function GetCardBg()
    return RC:GetColor("ui", "cardBackground")
end
local function GetHeaderBg()
    return RC:GetColor("ui", "headerBackground")
end
local function GetAccentGold()
    return RC:GetColor("ui", "accentGold")
end
local function GetTitleText()
    return RC:GetColor("ui", "headerText")
end
local function GetBorderHover()
    return RC:GetColor("ui", "borderHover")
end

local function GetStatLabelColor()
    return RC:GetColor("text", "disabled")
end
local function GetStatValueColor()
    return RC:GetColor("status", "success")
end

-- School indices 2-7 (Holy, Fire, Nature, Frost, Shadow, Arcane) skip 1 (Physical),
-- which GetSpellBonusDamage does not apply to.
local function GetMaxSpellPower()
    local best = 0
    if GetSpellBonusDamage then
        for school = 2, 7 do
            local v = GetSpellBonusDamage(school) or 0
            if v > best then best = v end
        end
    end
    if GetSpellBonusHealing then
        local h = GetSpellBonusHealing() or 0
        if h > best then best = h end
    end
    return math_floor(best)
end

local function GetHealingPower()
    if not GetSpellBonusHealing then return 0 end
    return math_floor(GetSpellBonusHealing() or 0)
end

local function GetMaxSpellDamage()
    local best = 0
    if GetSpellBonusDamage then
        for school = 2, 7 do
            local v = GetSpellBonusDamage(school) or 0
            if v > best then best = v end
        end
    end
    return math_floor(best)
end

local function GetMaxSpellCrit()
    local best = 0
    if GetSpellCritChance then
        for school = 2, 7 do
            local v = GetSpellCritChance(school) or 0
            if v > best then best = v end
        end
    end
    return best
end

local function GetMp5FromRegen()
    if not GetManaRegen then return 0 end
    local base, casting = GetManaRegen()
    return math_floor((casting or 0) * 5)
end

local function GetRangedAttackPower()
    if not UnitRangedAttackPower then return 0 end
    local ap, pos, neg = UnitRangedAttackPower("player")
    return (ap or 0) + (pos or 0) + (neg or 0)
end

-- Inventory slot IDs with durability; excludes shirt/tabard/trinkets/rings/neck/cloak.
local DURABILITY_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 16, 17, 18 }
local DURABILITY_SLOT_NAMES = {
    [1] = "Head", [3] = "Shoulder", [5] = "Chest", [6] = "Waist",
    [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands",
    [16] = "Main Hand", [17] = "Off Hand", [18] = "Ranged",
}

local function GetOverallDurability()
    local totalCur, totalMax = 0, 0
    for _, slot in ipairs(DURABILITY_SLOTS) do
        local cur, max = GetInventoryItemDurability(slot)
        if max and max > 0 then
            totalCur = totalCur + cur
            totalMax = totalMax + max
        end
    end
    if totalMax <= 0 then return 100 end
    return (totalCur / totalMax) * 100
end

-- GetMoney() returns copper; 10000 copper = 1 gold (100 copper/silver * 100 silver/gold).
local function GetPlayerGold()
    return math_floor((GetMoney() or 0) / 10000)
end

-- get(self) reads the live value; fmt(v) formats it for bar/panel display.
-- Keys here double as the enable/order keys used by CS:GetStatList (CS_Bar.lua).
local STAT_DEFS = {
    buffs = {
        label = "BUFFS",
        get   = function(self) return self:CountWarriorBuffs() end,
        fmt   = function(v) return tostring(v) end,
    },
    hit = {
        label = "HIT",
        get   = function(self) return self:GetMeleeHit() end,
        fmt   = function(v) return string_format("%.1f%%", v) end,
    },
    crit = {
        label = "CRIT",
        get   = function() return GetCritChance() or 0 end,
        fmt   = function(v) return string_format("%.1f%%", v) end,
    },
    ap = {
        label = "AP",
        get   = function()
            local ap, pos, neg = UnitAttackPower("player")
            return (ap or 0) + (pos or 0) + (neg or 0)
        end,
        fmt   = function(v) return tostring(v) end,
    },
    dmg = {
        label = "DMG",
        get   = function(self) return self:GetDamageBonus() end,
        fmt   = function(v) return string_format("%.0f%%", v) end,
    },
    sp = {
        label = "SP",
        get   = function() return GetMaxSpellPower() end,
        fmt   = function(v) return tostring(v) end,
    },
    hp = {
        label = "HEAL",
        get   = function() return GetHealingPower() end,
        fmt   = function(v) return tostring(v) end,
    },
    sdmg = {
        label = "SPD",
        get   = function() return GetMaxSpellDamage() end,
        fmt   = function(v) return tostring(v) end,
    },
    spellcrit = {
        label = "S.CRIT",
        get   = function() return GetMaxSpellCrit() end,
        fmt   = function(v) return string_format("%.1f%%", v) end,
    },
    mp5 = {
        label = "MP5",
        get   = function() return GetMp5FromRegen() end,
        fmt   = function(v) return tostring(v) end,
    },
    rap = {
        label = "RAP",
        get   = function() return GetRangedAttackPower() end,
        fmt   = function(v) return tostring(v) end,
    },
    rcrit = {
        label = "R.CRIT",
        get   = function() return (GetRangedCritChance and GetRangedCritChance()) or 0 end,
        fmt   = function(v) return string_format("%.1f%%", v) end,
    },
    fps = {
        label = "FPS",
        get   = function() return math.min(GetFramerate() or 0, 999) end,
        fmt   = function(v) return string_format("%.0f", v) end,
    },
    ms = {
        label = "MS",
        get   = function()
            local _, _, home, world = GetNetStats()
            return math.min(world or home or 0, 999)
        end,
        fmt   = function(v) return string_format("%.0f", v) end,
    },
    durability = {
        label = "DUR",
        get   = function() return GetOverallDurability() end,
        fmt   = function(v) return string_format("%.0f%%", v) end,
    },
    gold = {
        label = "GOLD",
        get   = function()
            if RC.GetGoldGrandTotal then return RC:GetGoldGrandTotal() end
            return GetPlayerGold()
        end,
        fmt   = function(v)
            return (BreakUpLargeNumbers and BreakUpLargeNumbers(v) or tostring(v)) .. "g"
        end,
    },
}

local CLASS_STAT_DEFAULTS = {
    WARRIOR = { "buffs", "hit", "crit", "ap", "dmg" },
    ROGUE   = { "buffs", "hit", "crit", "ap", "dmg" },
    HUNTER  = { "buffs", "hit", "crit", "rap", "ap" },
    SHAMAN  = { "buffs", "hit", "crit", "ap", "sp" },
    DRUID   = { "buffs", "hit", "crit", "ap", "sp" },
    MAGE    = { "buffs", "spellcrit", "sp", "mp5" },
    WARLOCK = { "buffs", "spellcrit", "sp", "mp5" },
}

local HYBRID_SPEC_STATS = {
    PRIEST = {
        heal = { "buffs", "hp", "spellcrit", "mp5" },
        dps  = { "buffs", "spellcrit", "sdmg", "mp5" },
    },
    PALADIN = {
        heal = { "buffs", "hp", "spellcrit", "mp5" },
        dps  = { "buffs", "hit", "crit", "ap", "dmg" },
    },
}

local DEFAULT_STAT_LIST = { "buffs", "hit", "crit", "ap" }

local STAT_ORDER = { "buffs", "hit", "crit", "ap", "dmg", "rap", "rcrit", "sp", "sdmg", "spellcrit", "hp", "mp5", "fps", "ms" }

-- Bridge these locals onto RC._css so CS_Bar.lua/CS_Buffs.lua can read them
-- without needing this file's local scope.
_css.GetCardBg = GetCardBg
_css.GetHeaderBg = GetHeaderBg
_css.GetAccentGold = GetAccentGold
_css.GetTitleText = GetTitleText
_css.GetBorderHover = GetBorderHover
_css.GetStatLabelColor = GetStatLabelColor
_css.GetStatValueColor = GetStatValueColor
_css.DURABILITY_SLOTS = DURABILITY_SLOTS
_css.DURABILITY_SLOT_NAMES = DURABILITY_SLOT_NAMES
_css.STAT_DEFS = STAT_DEFS
_css.CLASS_STAT_DEFAULTS = CLASS_STAT_DEFAULTS
_css.HYBRID_SPEC_STATS = HYBRID_SPEC_STATS
_css.DEFAULT_STAT_LIST = DEFAULT_STAT_LIST
_css.STAT_ORDER = STAT_ORDER

-- Duplicate of the assignments above: _css is the same table as RC._css
-- (local _css = RC._css, above), so this block re-sets the identical keys a second time.
RC._css = RC._css or {}
RC._css.GetCardBg = GetCardBg
RC._css.GetHeaderBg = GetHeaderBg
RC._css.GetAccentGold = GetAccentGold
RC._css.GetTitleText = GetTitleText
RC._css.GetBorderHover = GetBorderHover
RC._css.GetStatLabelColor = GetStatLabelColor
RC._css.GetStatValueColor = GetStatValueColor
