------------------------------------------------------------------------
-- Readycheck - Consumables Checker: Bootstrap
-- Runs each queued _cckInit initializer once RC.db exists. The other
-- Checker_*.lua files push their init closures onto WRF._cckInit and
-- rely on this running exactly once (RC._cckInitDone).
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format = string.format
local GetTime = GetTime
local GetItemCount = GetItemCount or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemCount)
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local function InitCheckerSections()
    local RC = _G.Readycheck
    if not RC or not RC.db then
        C_Timer.After(0.2, InitCheckerSections)
        return
    end
    if RC._cckInitDone then return end
    RC._cckInitDone = true
    local list = RC._cckInit or {}
    for i = 1, #list do
        list[i]()
    end
end

InitCheckerSections()
