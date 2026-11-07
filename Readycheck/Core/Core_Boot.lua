------------------------------------------------------------------------
-- Readycheck - Boot / Compat Shim
-- Builds Readycheck.Compat: shims that let the rest of the addon call
-- retail-style APIs (C_TooltipInfo, C_Spell, C_Item, C_UnitAuras) or the
-- old Classic Era globals interchangeably. Also creates the RC addon
-- table published as _G.Readycheck and _G.WR (WR kept only so old
-- macros/SavedVariables referencing WarriorReminder-era globals resolve).
-- Must load before every other Core_*.lua file: they read Compat and
-- _G.Readycheck at file-chunk scope, not inside a function.
------------------------------------------------------------------------
Readycheck = Readycheck or {}
Readycheck.Compat = Readycheck.Compat or {}
do
    local CP = Readycheck.Compat

    local function SurfaceLeft(td)
        if type(td) ~= "table" or type(td.lines) ~= "table" then return nil end
        local out = {}
        for i = 1, #td.lines do
            local l = td.lines[i]
            if l and l.leftText == nil and TooltipUtil and TooltipUtil.SurfaceArgs then
                TooltipUtil.SurfaceArgs(l)
            end
            local c = l and l.leftColor
            out[#out + 1] = {
                text = (l and l.leftText) or "",
                r = c and c.r, g = c and c.g, b = c and c.b,
            }
        end
        return out
    end

    local scanTip
    local function FrameLines(setter, a, b)
        if not scanTip then
            scanTip = CreateFrame("GameTooltip", "WRCompatScanTooltip",
                nil, "GameTooltipTemplate")
            scanTip:SetOwner(UIParent, "ANCHOR_NONE")
        end
        scanTip:ClearLines()
        scanTip[setter](scanTip, a, b)
        local out = {}
        for i = 1, scanTip:NumLines() do
            local fs = _G["WRCompatScanTooltipTextLeft" .. i]
            local r, g, b
            if fs then r, g, b = fs:GetTextColor() end
            out[#out + 1] = { text = (fs and fs:GetText()) or "", r = r, g = g, b = b }
        end
        return out
    end

    -- Prefer the data-only C_TooltipInfo API (no real tooltip frame, safe
    -- to call off-screen); fall back to scanning a hidden GameTooltip
    -- when the client/kind combo has no C_TooltipInfo getter.
    function CP.TooltipLines(kind, a, b)
        local ti = C_TooltipInfo
        if ti then
            local td
            if kind == "unitbuff" and ti.GetUnitBuff then
                td = ti.GetUnitBuff(a, b)
            elseif kind == "bagitem" and ti.GetBagItem then
                td = ti.GetBagItem(a, b)
            elseif kind == "inventory" and ti.GetInventoryItem then
                td = ti.GetInventoryItem(a, b)
            elseif kind == "hyperlink" and ti.GetHyperlink then
                td = ti.GetHyperlink(a)
            end
            local lines = SurfaceLeft(td)
            if lines and #lines > 0 then return lines end
        end
        if kind == "unitbuff" then return FrameLines("SetUnitBuff", a, b) end
        if kind == "bagitem" then return FrameLines("SetBagItem", a, b) end
        if kind == "inventory" then return FrameLines("SetInventoryItem", a, b) end
        if kind == "hyperlink" then return FrameLines("SetHyperlink", a) end
        return {}
    end

    function CP.TooltipLinesFrame(kind, a, b)
        if kind == "unitbuff" then return FrameLines("SetUnitBuff", a, b) end
        if kind == "bagitem" then return FrameLines("SetBagItem", a, b) end
        if kind == "inventory" then return FrameLines("SetInventoryItem", a, b) end
        if kind == "hyperlink" then return FrameLines("SetHyperlink", a) end
        return {}
    end

    function CP.ReadPlayerBuff(unit, i)
        if C_UnitAuras and C_UnitAuras.GetBuffDataByIndex then
            local a = C_UnitAuras.GetBuffDataByIndex(unit, i)
            if not a then return nil end
            -- WoW Forever hides auras in combat ("secret" values that may
            -- not be compared): read that as no aura, like the shims
            if issecretvalue and (issecretvalue(a.name) or issecretvalue(a.spellId)) then return nil end
            return a.name, a.icon, a.applications or a.charges or 0,
                a.dispelName, a.duration, a.expirationTime,
                a.sourceUnit, a.spellId
        end
        local name, icon, count, debuffType, duration, expirationTime,
            source, _, _, spellId = UnitBuff(unit, i)
        return name, icon, count, debuffType, duration, expirationTime,
            source, spellId
    end
    CP.GetMouseFocus = GetMouseFocus or (GetMouseFoci and function()
        local t = GetMouseFoci()
        return t and t[1] or nil
    end)
    CP.GetAddOnMetadata = GetAddOnMetadata
        or (C_AddOns and C_AddOns.GetAddOnMetadata)
    CP.GetSpellInfo = GetSpellInfo
        or (C_Spell and C_Spell.GetSpellInfo and function(spell)
            local sp = C_Spell.GetSpellInfo(spell)
            if not sp then return nil end
            return sp.name, nil, sp.iconID, sp.castTime, sp.minRange,
                sp.maxRange, sp.spellID, sp.originalIconID
        end)
    CP.GetSpellTexture = GetSpellTexture
        or (C_Spell and C_Spell.GetSpellTexture)
    CP.GetSpellCooldown = GetSpellCooldown
        or (C_Spell and C_Spell.GetSpellCooldown and function(spell)
            local c = C_Spell.GetSpellCooldown(spell)
            if not c then return 0, 0, 0, 0 end
            return c.startTime, c.duration, c.isEnabled and 1 or 0, c.modRate
        end)
    CP.IsSpellInRange = IsSpellInRange
        or (C_Spell and C_Spell.IsSpellInRange and function(spell, unit)
            local r = C_Spell.IsSpellInRange(spell, unit)
            if r == true then return 1 elseif r == false then return 0 end
            return nil
        end)
    if C_Item then
        CP.GetItemInfo = GetItemInfo or C_Item.GetItemInfo
        CP.GetItemInfoInstant = GetItemInfoInstant or C_Item.GetItemInfoInstant
        CP.GetItemCount = GetItemCount or C_Item.GetItemCount
        CP.GetItemSpell = GetItemSpell or C_Item.GetItemSpell
        CP.GetItemIcon = GetItemIcon or function(item)
            local id = tonumber(item)
            if not id then
                local giii = GetItemInfoInstant or C_Item.GetItemInfoInstant
                if giii then id = select(1, giii(item)) end
            end
            return id and C_Item.GetItemIconByID(id) or nil
        end
        CP.GetItemQualityColor = GetItemQualityColor or C_Item.GetItemQualityColor
    else
        CP.GetItemInfo = GetItemInfo
        CP.GetItemInfoInstant = GetItemInfoInstant
        CP.GetItemCount = GetItemCount
        CP.GetItemSpell = GetItemSpell
        CP.GetItemIcon = GetItemIcon
        CP.GetItemQualityColor = GetItemQualityColor
    end
    -- Reconstructs the old UnitBuff/UnitDebuff positional return tuple from
    -- the newer table-based aura APIs. Field order here must match the
    -- legacy signature exactly - callers destructure by position.
    local function AuraTuple(fetch)
        return function(unit, index, filter)
            local a = fetch(unit, index, filter)
            if not a then return nil end
            local pts = a.points or {}
            return a.name, a.icon, a.applications, a.dispelName, a.duration,
                a.expirationTime, a.sourceUnit, a.isStealable,
                a.nameplateShowPersonal, a.spellId, a.canApplyAura,
                a.isBossAura, a.isFromPlayerOrPlayerPet, a.nameplateShowAll,
                a.timeMod, unpack(pts)
        end
    end
    CP.UnitBuff = UnitBuff or (C_UnitAuras
        and C_UnitAuras.GetBuffDataByIndex
        and AuraTuple(C_UnitAuras.GetBuffDataByIndex))
    CP.UnitDebuff = UnitDebuff or (C_UnitAuras
        and C_UnitAuras.GetDebuffDataByIndex
        and AuraTuple(C_UnitAuras.GetDebuffDataByIndex))
    CP.UnitAura = UnitAura or (C_UnitAuras
        and C_UnitAuras.GetAuraDataByIndex
        and AuraTuple(C_UnitAuras.GetAuraDataByIndex))
end
local CP = Readycheck.Compat
local GetMouseFocus = GetMouseFocus or CP.GetMouseFocus
local GetAddOnMetadata = GetAddOnMetadata or CP.GetAddOnMetadata
local GetSpellInfo = GetSpellInfo or CP.GetSpellInfo
local GetSpellTexture = GetSpellTexture or CP.GetSpellTexture
local GetSpellCooldown = GetSpellCooldown or CP.GetSpellCooldown
local IsSpellInRange = IsSpellInRange or CP.IsSpellInRange
local GetItemInfo = GetItemInfo or CP.GetItemInfo
local GetItemInfoInstant = GetItemInfoInstant or CP.GetItemInfoInstant
local GetItemCount = GetItemCount or CP.GetItemCount
local GetItemSpell = GetItemSpell or CP.GetItemSpell
local GetItemIcon = GetItemIcon or CP.GetItemIcon
local GetItemQualityColor = GetItemQualityColor or CP.GetItemQualityColor
local UnitBuff = UnitBuff or CP.UnitBuff
local UnitDebuff = UnitDebuff or CP.UnitDebuff
local UnitAura = UnitAura or CP.UnitAura

local AddonName = "Readycheck"

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local string_format, string_match, string_find = string.format, string.match, string.find
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local GetTime, UnitName, UnitGUID = GetTime, UnitName, UnitGUID
local UnitHealth, UnitHealthMax, UnitExists = UnitHealth, UnitHealthMax, UnitExists
local UnitAffectingCombat, InCombatLockdown = UnitAffectingCombat, InCombatLockdown
local GetSpellInfo, GetSpellCooldown = GetSpellInfo, GetSpellCooldown
local GetItemInfo, GetItemCount = GetItemInfo, GetItemCount
local CreateFrame, UIParent = CreateFrame, UIParent
local C_Timer = C_Timer

local COLORS = {
    black = {0, 0, 0, 1},
    white = {1, 1, 1, 1},
    gold = {1, 0.82, 0, 1},
    goldHover = {0.85, 0.65, 0.25, 1},
    red = {1, 0.3, 0.3, 1},
    green = {0.3, 1, 0.3, 1},
    brightGreen = {0, 1, 0, 1},
    yellow = {1, 1, 0, 1},
    gray = {0.5, 0.5, 0.5, 1},
    darkGray = {0.2, 0.2, 0.2, 1},
    lightGray = {0.6, 0.6, 0.6, 1},
    windowBg = {0.08, 0.08, 0.08, 0.95},
    elementBg = {0.12, 0.12, 0.12, 0.9},
}

-- Copy the Compat table off the old Readycheck global before overwriting
-- it below - order matters, RC.Compat would be nil otherwise.
local RC = {}
RC.Compat = (Readycheck and Readycheck.Compat) or {}
_G.Readycheck = RC
_G.WR = RC
RC.version = RC.Compat.GetAddOnMetadata("Readycheck", "Version")
          or "0.0.0"

function RC:IsOmniCCActive()
    if self._omniCCActive ~= nil then return self._omniCCActive end
    local loaded = false
    if C_AddOns and C_AddOns.IsAddOnLoaded then
        if C_AddOns.IsAddOnLoaded("OmniCC") then loaded = true end
    elseif IsAddOnLoaded then
        if IsAddOnLoaded("OmniCC") then loaded = true end
    end
    if not loaded and _G.OmniCC ~= nil then loaded = true end
    self._omniCCActive = loaded and true or false
    if self._omniCCActive then
        self:DebugPrint("OmniCC detected - suppressing Readycheck's own cooldown numbers on swirl surfaces", "omnicc")
    end
    return self._omniCCActive
end

function RC:ShouldShowOwnCooldownText()
    return not self:IsOmniCCActive()
end

RC.utilityItems = {}
RC.playerClass = nil
RC.playerLevel = nil
RC.isWarrior = nil
RC.inCombat = false
RC.currentZone = nil
RC.reminderFrame = nil
RC.activeReminders = {}
RC.events = {}

local reuseUsableAbilities = {}
local reuseFilteredAbilities = {}
local reuseAbilitiesOnCooldown = {}
local wipe = wipe

function RC:GetScanTooltip()
    if not self.scanTooltip then
        self.scanTooltip = CreateFrame("GameTooltip", "WRScanTooltip", nil, "GameTooltipTemplate")
        self.scanTooltip:SetOwner(UIParent, "ANCHOR_NONE")
    end
    return self.scanTooltip
end

-- Maps internal ability keys / item IDs to short words the TTS voice
-- reads aloud instead of the full spell or item name (exact-key lookup).
local WR_TTS_SPOKEN = {
    trinket1                          = "trinket",
    trinket2                          = "trinket",
    mightyRagePotion                  = "M R P",
    freeActionPotion                  = "F A P",
    limitedInvulnerabilityPotion      = "lip",
    superiorManaPotion                = "mana pot",
    greaterFireProtectionPotion       = "fire pot",
    greaterFrostProtectionPotion      = "frost pot",
    greaterNatureProtectionPotion     = "nature pot",
    greaterShadowProtectionPotion     = "shadow pot",
    greaterArcaneProtectionPotion     = "arcane pot",
    flaskOfTheTitans                  = "flask",
    flaskOfDistilledWisdom            = "flask",
    flaskOfSupremePower               = "flask",
    flaskOfChromaticResistance        = "flask",
    elixirOfTheMongoose               = "mongoose",
    jujuPower                         = "juju",
    jujuFlurry                        = "juju",
    deathWish                         = "death wish",
    bloodrage                         = "bloodrage",
    recklessness                      = "reck",
    boon                              = "boon",
    ["18641"]                         = "dynamite",
    ["10646"]                         = "sapper",
    ["8956"]                          = "oil",
    ["11951"]                         = "whipper",
    ["13180"]                         = "water",
    ["16023"]                         = "dummy",
    ["2091"]                          = "dust",
}
RC.ttsSpokenNames = WR_TTS_SPOKEN

local _ttsLastSoundFire = {}
-- Minimum gap between repeats of the same spoken sound key; keeps a
-- burst of reminder rebuilds from re-triggering the same TTS line.
local TTS_SOUND_CD = 8

local function ResolveSpeakName(selectedSound, abilityData)
    local spoken = WR_TTS_SPOKEN[selectedSound]
    if spoken then return spoken end

    local itemId = tonumber(selectedSound)
    if itemId then
        local itemName = GetItemInfo(itemId)
        if itemName then
            return itemName:lower()
        end
        return "item"
    end

    if abilityData and abilityData[selectedSound] and abilityData[selectedSound].name then
        return abilityData[selectedSound].name
    end

    if RC.GetTTSName then
        local short = RC:GetTTSName(selectedSound)
        if short and short ~= selectedSound then return short end
    end

    return selectedSound
end

local _chainLastStart = {}

local function TTSSuppressed(soundKey)
    local last = _ttsLastSoundFire[soundKey]
    if last and (GetTime() - last) < TTS_SOUND_CD then
        return true
    end
    return false
end

local function TTSMarkFired(soundKey)
    _ttsLastSoundFire[soundKey] = GetTime()
end

local function ResetTTSState(ard)
    if ard.ttsRepeatTimer then
        ard.ttsRepeatTimer:Cancel()
        ard.ttsRepeatTimer = nil
    end
    ard.ttsPlayed    = false
    ard.ttsPlayCount = 0
end

function RC:GetSoundFile(soundKey)
    if soundKey and self.LSM then
        return self.LSM:Fetch("sound", soundKey)
    end
    return nil
end

-- Every sound LibSharedMedia knows - Readycheck's own and any other
-- addon's - as dropdown items { text, value }, sorted by name.
function RC:GetSoundItems()
    local items = {}
    local all = self.LSM and self.LSM:HashTable("sound")
    if type(all) == "table" then
        for key in pairs(all) do items[#items + 1] = { text = key, value = key } end
    end
    table.sort(items, function(a, b) return a.text:lower() < b.text:lower() end)
    return items
end

-- Plays a LibSharedMedia sound by name; fallback is a file path used
-- when the name is unknown (or the library is missing).
function RC:PlaySoundKey(soundKey, fallback)
    local file = self:GetSoundFile(soundKey) or fallback
    if file and file ~= "" then pcall(PlaySoundFile, file, "Master") end
end

RC.activeReminderData = {
    abilities = {},
    showTime = 0,
    reminderExpireTime = 0,
    dismissalTimer = nil,
    fadeTimer = nil,
    ttsPlayed = false,
    ttsPlayCount = 0,
    ttsRepeatTimer = nil,
    reminderID = 0,
    popupSessionID = 0
}

RC.itemRackIntegration = {
    available = false,
    sets = {},
    lastSwap = 0,
    swapCooldown = 2,
    enabledForBosses = {},
    enabledForTrash = {},
    lastGlobalSwap = 0,
    retrySystem = {
        maxRetries = 3,
        retryDelay = 0.5,
        activeRetries = {}
    }
}

function RC:TableCount(tbl)
    if type(tbl) ~= "table" then return 0 end
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

-- Every font string in the addon is built here so RC.trackedFonts stays
-- the single list FontSystem re-applies the user's font choice over.
-- Lived in Core_Reminders.lua until that file moved to
-- Readycheck_Reminders; ~600 call sites across the main addon and every
-- companion mean it has to exist before anything draws.
function RC:CreateFontString(parent, layer, template, size, outline)
    local fontString = parent:CreateFontString(nil, layer or "OVERLAY")

    local fontSize = size or 12
    local fontOutline = outline or "OUTLINE"

    fontString._wrFontSize = fontSize
    fontString._wrFontOutline = fontOutline

    if self.ApplyCustomFont then
        self:ApplyCustomFont(fontString, fontSize, fontOutline)
    end

    if not fontString:GetFont() then
        fontString:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF",
            fontSize, fontOutline)
    end

    fontString:SetJustifyH("LEFT")

    if not self.trackedFonts then
        self.trackedFonts = {}
    end
    table.insert(self.trackedFonts, fontString)

    return fontString
end

-- Durations render as m:ss, or h:mm:ss past an hour. Lived in
-- TTKDisplay.lua, which moved to Readycheck_Reminders; the stats bar,
-- world buff timers and cooldown text all format through it.
function RC:FormatTime(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    if seconds >= 3600 then
        return string.format("%d:%02d:%02d", math.floor(seconds/3600), math.floor((seconds%3600)/60), seconds%60)
    end
    return string.format("%d:%02d", math.floor(seconds/60), seconds%60)
end

-- Zone predicates shared by every visibility-mode gate in the suite
-- (consumables/potions/weapons/trinket bars, shout reminder, WT bars).
-- "Raids" means physically inside a raid instance; a raid GROUP standing
-- in Orgrimmar does not count. "City" is the rested state (cities and
-- inns), which is what PLAYER_UPDATE_RESTING tracks.
-- Keys are exactly the strings in RC.availableRaids (DB_Raids.lua), which
-- is also what the per-bar raid filter tables (cfg.visibilityRaids) are
-- keyed by. Values are Classic Era instance IDs (8th return of
-- GetInstanceInfo), matched before the localised zone name.
RC.raidInstanceIDs = {
    ["Molten Core"]         = 409,
    ["Blackwing Lair"]      = 469,
    ["Temple of Ahn'Qiraj"] = 531,
    ["Naxxramas"]           = 533,
    ["Onyxia's Lair"]       = 249,
    ["Zul'Gurub"]           = 309,
    ["Ruins of Ahn'Qiraj"]  = 509,
}

-- fn(raids) runs once another game version's raid list has replaced
-- Classic Era's (RC:ApplyRaidFlavor, RaidFlavor.lua), so a file holding
-- its own raid tables can add that version's raids. Never runs on Era.
function RC:OnRaidFlavor(fn)
    if self._raidFlavorApplied then fn(self._flavorRaids) return end
    if self._raidFlavorApplied == false then return end
    self._raidFlavorHooks = self._raidFlavorHooks or {}
    self._raidFlavorHooks[#self._raidFlavorHooks + 1] = fn
end

-- Canonical raid name (an RC.availableRaids string) for the raid instance
-- the player is standing in, or nil anywhere else. Only called from the
-- debounced visibility checks, so no caching.
function RC:GetCurrentRaidName()
    local inInstance, instanceType = IsInInstance()
    if not (inInstance and instanceType == "raid") then return nil end
    local name, _, _, _, _, _, _, instanceID = GetInstanceInfo()
    if instanceID then
        for raidName, id in pairs(RC.raidInstanceIDs) do
            if id == instanceID then return raidName end
        end
    end
    if name then
        for _, raidName in ipairs(RC.availableRaids or {}) do
            if raidName == name then return raidName end
        end
    end
    return nil
end

-- True when a raid-filter set ({ ["Molten Core"]=true, ... }) restricts
-- anything, i.e. has at least one true entry. nil / {} means "all raids".
function RC:HasRaidFilter(set)
    if type(set) ~= "table" then return false end
    for _, v in pairs(set) do
        if v then return true end
    end
    return false
end

-- filter (optional): a raid-filter set as above. With an active filter
-- this is true only inside one of the ticked raids; with nil or an empty
-- set it is the plain "inside any raid instance" test every existing
-- zero-arg caller relies on.
function RC:IsInRaidInstance(filter)
    local inInstance, instanceType = IsInInstance()
    if not (inInstance and instanceType == "raid") then return false end
    if RC:HasRaidFilter(filter) then
        local raidName = RC:GetCurrentRaidName()
        return (raidName and filter[raidName]) and true or false
    end
    return true
end

-- Inside a dungeon (5-man) or a raid instance. The raid filter, when
-- given, narrows the raid side only: every dungeon counts.
function RC:IsInDungeonOrRaid(filter)
    local inInstance, instanceType = IsInInstance()
    if not inInstance then return false end
    if instanceType == "party" then return true end
    if instanceType == "raid" then return RC:IsInRaidInstance(filter) end
    return false
end

-- Party OR raid group, anywhere in the world.
function RC:IsInGroup()
    return IsInGroup() and true or false
end

function RC:IsInCity()
    return IsResting() and true or false
end

-- One coalesced visibility re-evaluate per frame. Every zone, rest,
-- roster and combat-end event funnels here; any number of them inside
-- the window collapse into ONE call of RC[methodName], which must
-- recompute shown/hidden from scratch. settle=true is for
-- PLAYER_ENTERING_WORLD: IsResting/IsInInstance can still report the old
-- zone for a frame or two after a loading screen, so it runs once more
-- ~1s later. Clearing cachedShouldShow/lastZoneCheck here is what makes
-- the bars' 1s ShouldShow cache miss on the re-evaluate.
function RC:QueueVisibilityCheck(state, methodName, settle)
    if not state then return end
    state.cachedShouldShow = nil
    state.lastZoneCheck = 0
    if settle then state._visSettlePending = true end
    if state._visCheckPending then return end
    state._visCheckPending = true
    C_Timer.After(0.3, function()
        state._visCheckPending = nil
        state.cachedShouldShow = nil
        state.lastZoneCheck = 0
        local fn = RC[methodName]
        if fn then fn(RC) end
        if state._visSettlePending then
            state._visSettlePending = nil
            C_Timer.After(1.0, function()
                state.cachedShouldShow = nil
                state.lastZoneCheck = 0
                local fn2 = RC[methodName]
                if fn2 then fn2(RC) end
            end)
        end
    end)
end

-- Cross-file locals handoff: each Core_*.lua file is a separate chunk
-- with its own `local`s, so shared helpers/state (colors, TTS dedupe)
-- are stashed on RC._cor here and pulled back out via `local x = _cor.x`
-- at the top of the files that need them.
RC._cor = RC._cor or {}
RC._cor.COLORS           = COLORS
RC._cor.ResolveSpeakName = ResolveSpeakName
RC._cor.TTSSuppressed    = TTSSuppressed
RC._cor.TTSMarkFired     = TTSMarkFired
RC._cor.ResetTTSState    = ResetTTSState
RC._cor._chainLastStart  = _chainLastStart
