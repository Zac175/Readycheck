------------------------------------------------------------------------
-- Readycheck - WoW Forever and Retail (the modern clients)
-- WoW Forever (Interface 16001) runs on the modern client API: a number
-- of the old global functions this addon calls are gone there, moved
-- into C_Spell, C_Item, C_SpellBook, C_Container, C_AddOns, C_UnitAuras
-- and C_ChatInfo. This file puts back the old names, with the old return
-- shapes, built on the new ones - so the rest of the addon runs
-- unchanged.
--
-- ONLY ON THE MODERN CLIENTS, ONLY WHERE MISSING. On Classic Era every
-- check below fails (the game is not Forever or Retail, and every name
-- already exists), so nothing here changes Era at all. On Forever and on
-- Retail (Mainline 12.x, which removed the same names in 12.0) a name is
-- only filled in when the game does not have it.
--
-- TWO TRUTHS (2026-11-07). _G.READYCHECK_MODERN: the client runs the Mainline
-- UI family (Forever or Retail: Mainline templates, no combat log, secret
-- values, the C_ namespaces, AddOnMessageLockdown). _G.READYCHECK_IS_FOREVER:
-- Forever alone (the Camelot character sheet and pane hosts, Camelot
-- nameplate constants, StableUI, the PLAYER_SWING event). Retail sets
-- _G.READYCHECK_IS_RETAIL beside them.
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
if type(build) ~= "number" then build = tonumber(build) or 0 end
local FOREVER = (WOW_PROJECT_ID == 18) or (build >= 16000 and build < 20000)
-- (Retail: WOW_PROJECT_MAINLINE is 1; its interface number is 100000+)
local RETAIL = (WOW_PROJECT_ID == 1) or (build >= 100000)
local MODERN = FOREVER or RETAIL
_G.READYCHECK_IS_FOREVER = FOREVER and true or false
_G.READYCHECK_IS_RETAIL = RETAIL and true or false
_G.READYCHECK_MODERN = MODERN and true or false
if not MODERN then return end

local G = _G
local function Fill(name, fn)
    if G[name] == nil and type(fn) == "function" then G[name] = fn end
end
local function Secret(v)
    return issecretvalue ~= nil and issecretvalue(v) or false
end

-- A cooldown the game hands back hidden (in a fight: secret values, no
-- maths or comparing) reads as the last plain one while that still runs,
-- else as ready - so no caller of these stand-ins ever gets a secret it
-- can't count with (2026-11-07).
local lastCD = {}
local function PlainCD(key, s, d, en, m)
    if Secret(s) or Secret(d) then
        local l = key ~= nil and lastCD[key]
        if l and l[1] + l[2] > GetTime() then return l[1], l[2], 1, 1 end
        return 0, 0, 1, 1
    end
    if key ~= nil and type(s) == "number" and type(d) == "number" and d > 0 then
        local l = lastCD[key] or {}
        lastCD[key] = l
        l[1], l[2] = s, d
    end
    if Secret(en) then en = true end
    if Secret(m) then m = 1 end
    return s, d, en and 1 or 0, m or 1
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
        return PlainCD(spell, c.startTime, c.duration, c.isEnabled, c.modRate)
    end)
    Fill("GetSpellCharges", CS.GetSpellCharges and function(spell)
        local c = CS.GetSpellCharges(spell)
        if not c then return nil end
        -- (hidden: read as a spell without charges)
        if Secret(c.currentCharges) or Secret(c.maxCharges) then return nil end
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
    Fill("GetSpellSubtext", CS.GetSpellSubtext)
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
            -- the game can refuse the read outright in combat ("Auras cannot
            -- be accessed when secret while tainted"): that's "no aura" too
            local ok, a = pcall(fetch, unit, index, filter)
            if not ok or not a then return nil end
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

-- More of the old names Forever moved (2026-11-07; Forever's own API
-- documentation and UI code have only the C_ forms) --------------------
local SBK = C_SpellBook
if SBK and SBK.IsSpellKnown then
    local bank = Enum and Enum.SpellBookSpellBank
    Fill("IsSpellKnown", function(spellID, isPet)
        if spellID == nil then return false end
        local b = bank and (isPet and bank.Pet or bank.Player) or nil
        return SBK.IsSpellKnown(spellID, b) and true or false
    end)
    Fill("IsPlayerSpell", function(spellID)
        if spellID == nil then return false end
        local f = SBK.IsSpellKnownOrInSpellBook or SBK.IsSpellKnown
        return f(spellID) and true or false
    end)
end
local CUR = C_CurrencyInfo
if CUR then
    Fill("GetCoinTextureString", CUR.GetCoinTextureString)
    Fill("GetCoinText", CUR.GetCoinText)
end
local PD = C_PaperDollInfo
if PD then
    Fill("GetInventorySlotInfo", PD.GetInventorySlotInfo)
    Fill("CursorCanGoInSlot", PD.CursorCanGoInSlot)
    -- the old flat answer: has, ms left, charges, enchant id - for the main
    -- hand, the off hand and the ranged slot in turn
    -- Forever (1.60.1) keeps an imbue (Windfury...) and an oil / stone /
    -- poison on a weapon side by side; GetTemporaryEnchantmentInfo answers
    -- only one of them (the imbue wins), C_Item.GetWeaponEnchantInfo(
    -- Enum.WeaponSlot.*) lists them all. The old answer was one per weapon:
    -- the temporary one (what a consumable reminder asks about) before the
    -- imbue. Its time comes from GetTemporaryEnchantmentInfo's
    -- remainingTimeMs when that is the same enchant, else from the list.
    local CIt, WS = C_Item, Enum and Enum.WeaponSlot
    local IET = Enum and Enum.ItemEnchantType
    local function FromList(i)
        if not (CIt and CIt.GetWeaponEnchantInfo and WS) then return nil end
        local ok, list = pcall(CIt.GetWeaponEnchantInfo, ({ WS.MainHand, WS.OffHand, WS.Ranged })[i])
        if not ok or type(list) ~= "table" then return nil end
        local temp, imbue
        for _, e in ipairs(list) do
            if type(e) == "table" and e.hasEnchant and not Secret(e.enchantType) then
                if IET and e.enchantType == IET.Temporary then temp = temp or e
                elseif IET and e.enchantType == IET.Imbue then imbue = imbue or e end
            end
        end
        return temp or imbue
    end
    Fill("GetWeaponEnchantInfo", PD.GetTemporaryEnchantmentInfo and function()
        local out = {}
        for i, slot in ipairs({ 16, 17, 18 }) do
            local e = PD.GetTemporaryEnchantmentInfo(slot)
            local at = (i - 1) * 4
            local l = FromList(i)
            if l and not (e and e.enchantID == l.enchantID) then
                out[at + 1], out[at + 2], out[at + 3], out[at + 4] = true, l.timeLeft, l.charges, l.enchantID
            else
                out[at + 1] = e and true or false
                if e then out[at + 2], out[at + 3], out[at + 4] = e.remainingTimeMs, e.chargesRemaining, e.enchantID end
            end
        end
        return unpack(out, 1, 12)
    end)
    Fill("CancelItemTempEnchantment", PD.CancelTemporaryEnchantment and function(index)
        local slot = ({ 16, 17, 18 })[index]
        if slot then PD.CancelTemporaryEnchantment(slot) end
    end)
end
local SK = C_SkillInfo
if SK and SK.GetSkillLineInfo then
    Fill("GetNumSkillLines", SK.GetNumSkillLines)
    Fill("ExpandSkillHeader", SK.ExpandSkillHeader)
    Fill("CollapseSkillHeader", SK.CollapseSkillHeader)
    Fill("GetSelectedSkill", SK.GetSelectedSkill)
    Fill("SetSelectedSkill", SK.SetSelectedSkill)
    Fill("GetSkillLineInfo", function(index)
        local s = SK.GetSkillLineInfo(index)
        if not s then return nil end
        return s.name, s.isHeader, not s.isCollapsed, s.rank, s.tempPoints, s.modifier, s.maxRank,
            s.isAbandonable, s.stepCost, s.rankCost, s.minLevel, s.costType, s.description
    end)
end
local AB = C_ActionBar
if AB then
    Fill("HasAction", AB.HasAction)
    Fill("GetActionTexture", AB.GetActionTexture)
    Fill("GetActionText", AB.GetActionText)
    Fill("IsUsableAction", AB.IsUsableAction)
    Fill("IsActionInRange", AB.IsActionInRange)
    Fill("IsCurrentAction", AB.IsCurrentAction)
    Fill("IsAutoRepeatAction", AB.IsAutoRepeatAction)
    Fill("IsAttackAction", AB.IsAttackAction)
    Fill("IsEquippedAction", AB.IsEquippedAction)
    Fill("IsConsumableAction", AB.IsConsumableAction)
    Fill("IsStackableAction", AB.IsStackableAction)
    Fill("GetActionCooldown", AB.GetActionCooldown and function(action)
        local c = AB.GetActionCooldown(action)
        if not c then return 0, 0, 0, 1 end
        return PlainCD("action" .. tostring(action), c.startTime, c.duration, c.isEnabled, c.modRate)
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
-- MouseIsOver(frame) and UIParentLoadAddOn(name) are gone from Forever's UI
-- code (2026-11-07, Zac's Forever client: "attempt to call a nil value")
Fill("MouseIsOver", function(frame, top, bottom, left, right)
    return frame and frame.IsMouseOver and frame:IsMouseOver(top, bottom, left, right) or false
end)
Fill("UIParentLoadAddOn", function(name)
    local load = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if load then return load(name) end
end)
