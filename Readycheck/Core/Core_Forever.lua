------------------------------------------------------------------------
-- Readycheck - WoW Forever
-- WoW Forever (Interface 16001) runs on the modern client API: a number
-- of the old global functions this addon calls are gone there, moved
-- into C_Spell, C_Item, C_SpellBook, C_Container, C_AddOns, C_UnitAuras
-- and C_ChatInfo. This file puts back the old names, with the old return
-- shapes, built on the new ones - so the rest of the addon runs
-- unchanged.
--
-- ONLY ON FOREVER, ONLY WHERE MISSING. On Classic Era every check below
-- fails (the game is not Forever, and every name already exists), so
-- nothing here changes Era at all. On Forever a name is only filled in
-- when the game does not have it.
--
-- SECRET VALUES. In combat Forever hands addons "secret" aura data that
-- may not be compared or used in arithmetic. The aura stand-ins answer
-- "no aura" for a secret instead of handing it on, so a feature that
-- reads buffs in combat goes quiet rather than throwing errors.
--
-- Loaded before everything else in the TOC (libraries included).
-- Identical copy in Zacui\Core\Core_Forever.lua; whichever loads first
-- fills a name, the other sees it already there.
------------------------------------------------------------------------
local build = select(4, GetBuildInfo()) or 0
local FOREVER = (WOW_PROJECT_ID == 18) or (build >= 16000 and build < 20000)
_G.READYCHECK_IS_FOREVER = FOREVER and true or false
if not FOREVER then return end

local G = _G
local function Fill(name, fn)
    if G[name] == nil and type(fn) == "function" then G[name] = fn end
end
local function Secret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

-- Spells ---------------------------------------------------------------
local CS = C_Spell
if CS then
    Fill("GetSpellInfo", CS.GetSpellInfo and function(spell)
        if spell == nil then return nil end
        local s = CS.GetSpellInfo(spell)
        if not s then return nil end
        return s.name, nil, s.iconID, s.castTime, s.minRange, s.maxRange, s.spellID, s.originalIconID
    end)
    Fill("GetSpellTexture", CS.GetSpellTexture)
    Fill("GetSpellLink", CS.GetSpellLink)
    Fill("GetSpellDescription", CS.GetSpellDescription)
    Fill("GetSpellPowerCost", CS.GetSpellPowerCost)
    Fill("GetSpellCooldown", CS.GetSpellCooldown and function(spell)
        local c = CS.GetSpellCooldown(spell)
        if not c then return 0, 0, 0, 1 end
        return c.startTime, c.duration, c.isEnabled and 1 or 0, c.modRate or 1
    end)
    Fill("GetSpellCharges", CS.GetSpellCharges and function(spell)
        local c = CS.GetSpellCharges(spell)
        if not c then return nil end
        return c.currentCharges, c.maxCharges, c.cooldownStartTime, c.cooldownDuration, c.chargeModRate
    end)
    Fill("IsSpellInRange", CS.IsSpellInRange and function(spell, unit)
        local r = CS.IsSpellInRange(spell, unit)
        if r == true then return 1 elseif r == false then return 0 end
        return nil
    end)
    Fill("IsUsableSpell", CS.IsSpellUsable)
    Fill("IsCurrentSpell", CS.IsCurrentSpell)
    Fill("IsPassiveSpell", CS.IsSpellPassive)
    Fill("IsAutoRepeatSpell", CS.IsAutoRepeatSpell)
end

-- The spellbook ---------------------------------------------------------
local SB = C_SpellBook
if SB then
    local bank = Enum and Enum.SpellBookSpellBank
    local function Bank(book)
        if not bank then return book end
        if book == "pet" or book == (BOOKTYPE_PET or "pet") then return bank.Pet end
        return bank.Player
    end
    local typeName = {}
    if Enum and Enum.SpellBookItemType then
        for k, v in pairs(Enum.SpellBookItemType) do
            if k == "Spell" then typeName[v] = "SPELL"
            elseif k == "FutureSpell" then typeName[v] = "FUTURESPELL"
            elseif k == "PetAction" then typeName[v] = "PETACTION"
            elseif k == "Flyout" then typeName[v] = "FLYOUT" end
        end
    end
    Fill("GetSpellBookItemName", SB.GetSpellBookItemName and function(slot, book)
        return SB.GetSpellBookItemName(slot, Bank(book))
    end)
    Fill("GetSpellBookItemTexture", SB.GetSpellBookItemTexture and function(slot, book)
        return SB.GetSpellBookItemTexture(slot, Bank(book))
    end)
    Fill("GetSpellBookItemInfo", SB.GetSpellBookItemInfo and function(slot, book)
        local i = SB.GetSpellBookItemInfo(slot, Bank(book))
        if not i then return nil end
        return typeName[i.itemType] or "SPELL", i.spellID or i.actionID
    end)
    Fill("PickupSpellBookItem", SB.PickupSpellBookItem and function(slot, book)
        return SB.PickupSpellBookItem(slot, Bank(book))
    end)
    Fill("GetSpellAutocast", SB.GetSpellBookItemAutoCast and function(slot, book)
        return SB.GetSpellBookItemAutoCast(slot, Bank(book))
    end)
    Fill("GetNumSpellTabs", SB.GetNumSpellBookSkillLines)
    Fill("GetSpellTabInfo", SB.GetSpellBookSkillLineInfo and function(tab)
        local t = SB.GetSpellBookSkillLineInfo(tab)
        if not t then return nil end
        return t.name, t.iconID, t.itemIndexOffset, t.numSpellBookItems, t.isGuild, t.offSpecID
    end)
end

-- Items ------------------------------------------------------------------
local CI = C_Item
if CI then
    Fill("GetItemInfo", CI.GetItemInfo)
    Fill("GetItemInfoInstant", CI.GetItemInfoInstant)
    Fill("GetItemCount", CI.GetItemCount)
    Fill("GetItemSpell", CI.GetItemSpell)
    Fill("GetItemQualityColor", CI.GetItemQualityColor)
    Fill("GetItemStats", CI.GetItemStats)
    Fill("GetDetailedItemLevelInfo", CI.GetDetailedItemLevelInfo)
    Fill("IsEquippedItem", CI.IsEquippedItem)
    Fill("IsEquippableItem", CI.IsEquippableItem)
    Fill("IsUsableItem", CI.IsUsableItem)
    Fill("IsCurrentItem", CI.IsCurrentItem)
    Fill("IsItemInRange", CI.IsItemInRange)
    Fill("ItemHasRange", CI.ItemHasRange)
    -- the gear swaps put gear on through these two (EquipEngine, Core_Gear)
    Fill("EquipItemByName", CI.EquipItemByName)
    Fill("UseItemByName", CI.UseItemByName)
    Fill("GetItemIcon", function(item)
        local id = tonumber(item)
        if not id and CI.GetItemInfoInstant then id = (CI.GetItemInfoInstant(item)) end
        if id and CI.GetItemIconByID then return CI.GetItemIconByID(id) end
        return nil
    end)
end

-- Bags -------------------------------------------------------------------
local CC = C_Container
if CC then
    Fill("GetContainerNumSlots", CC.GetContainerNumSlots)
    Fill("GetContainerNumFreeSlots", CC.GetContainerNumFreeSlots)
    Fill("GetContainerItemLink", CC.GetContainerItemLink)
    Fill("GetContainerItemID", CC.GetContainerItemID)
    Fill("GetContainerItemCooldown", CC.GetContainerItemCooldown)
    Fill("UseContainerItem", CC.UseContainerItem)
    Fill("PickupContainerItem", CC.PickupContainerItem)
    Fill("SplitContainerItem", CC.SplitContainerItem)
    Fill("GetItemCooldown", CC.GetItemCooldown)
    Fill("GetContainerItemInfo", CC.GetContainerItemInfo and function(bag, slot)
        local i = CC.GetContainerItemInfo(bag, slot)
        if not i then return nil end
        return i.iconFileID, i.stackCount, i.isLocked, i.quality, i.isReadable, i.hasLoot,
            i.hyperlink, i.isFiltered, i.hasNoValue, i.itemID, i.isBound
    end)
end

-- Auras (secret-safe) ------------------------------------------------------
local UA = C_UnitAuras
if UA then
    local function Tuple(fetch)
        return function(unit, index, filter)
            local a = fetch(unit, index, filter)
            if not a then return nil end
            if Secret(a.name) or Secret(a.spellId) or Secret(a.expirationTime) then return nil end
            return a.name, a.icon, a.applications, a.dispelName, a.duration, a.expirationTime,
                a.sourceUnit, a.isStealable, a.nameplateShowPersonal, a.spellId, a.canApplyAura,
                a.isBossAura, a.isFromPlayerOrPlayerPet, a.nameplateShowAll, a.timeMod
        end
    end
    if UA.GetBuffDataByIndex then Fill("UnitBuff", Tuple(UA.GetBuffDataByIndex)) end
    if UA.GetDebuffDataByIndex then Fill("UnitDebuff", Tuple(UA.GetDebuffDataByIndex)) end
    if UA.GetAuraDataByIndex then Fill("UnitAura", Tuple(UA.GetAuraDataByIndex)) end
end

-- AddOns -----------------------------------------------------------------
local CA = C_AddOns
if CA then
    Fill("GetAddOnMetadata", CA.GetAddOnMetadata)
    Fill("IsAddOnLoaded", CA.IsAddOnLoaded)
    Fill("GetAddOnInfo", CA.GetAddOnInfo)
    Fill("GetNumAddOns", CA.GetNumAddOns)
    Fill("EnableAddOn", CA.EnableAddOn)
    Fill("DisableAddOn", CA.DisableAddOn)
    Fill("LoadAddOn", CA.LoadAddOn)
    Fill("IsAddOnLoadOnDemand", CA.IsAddOnLoadOnDemand)
    -- (the old order was character, addon; the new one is addon, character)
    Fill("GetAddOnEnableState", CA.GetAddOnEnableState and function(character, addon)
        return CA.GetAddOnEnableState(addon, character)
    end)
end

-- Odds and ends ------------------------------------------------------------
Fill("GetMouseFocus", GetMouseFoci and function()
    local t = GetMouseFoci()
    return t and t[1] or nil
end)
if C_ChatInfo then
    Fill("SendAddonMessage", C_ChatInfo.SendAddonMessage)
    Fill("RegisterAddonMessagePrefix", C_ChatInfo.RegisterAddonMessagePrefix)
end
