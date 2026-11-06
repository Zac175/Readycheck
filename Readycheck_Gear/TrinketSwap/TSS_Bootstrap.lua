------------------------------------------------------------------------
-- Readycheck - Trinket Swap Bootstrap
-- First attempt fires 3s after load, retrying every 0.1s until RC.db
-- exists. RC._tssInitDone guards every TSS_*.lua init function queued
-- in RC._tssInit so it runs exactly once regardless of retries.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local UnitBuff = UnitBuff or (RCC and RCC.Compat and RCC.Compat.UnitBuff)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_max, math_min = math.floor, math.max, math.min
local table_insert, table_remove = table.insert, table.remove
local GetTime = GetTime
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
local GetInventoryItemID = GetInventoryItemID
local GetInventoryItemLink = GetInventoryItemLink
local GetInventoryItemCooldown = GetInventoryItemCooldown
local InCombatLockdown = InCombatLockdown
local UnitAffectingCombat = UnitAffectingCombat
local UnitCastingInfo = UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local C_Container = C_Container
local C_Timer = C_Timer
local CreateFrame = CreateFrame

local function SafeInitialize()
    local RC = _G.Readycheck
    if not RC or not RC.db then
        C_Timer.After(0.1, SafeInitialize)
        return
    end
    if RC._tssInitDone then return end
    RC._tssInitDone = true
    local list = RC._tssInit or {}
    for i = 1, #list do
        list[i]()
    end
    RC:DebugPrint("Trinket Swap System loaded", "trinket")
end

C_Timer.After(3.0, SafeInitialize)
