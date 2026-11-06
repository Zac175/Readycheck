------------------------------------------------------------------------
-- Readycheck - Consumables Init Driver
-- Drains RC._chInit, the ordered queue of init closures appended by every
-- other Consumables file, exactly once RC.db is available.
-- Must load LAST in the folder: the queue is only complete at that point.
-- Retries on a timer rather than an event because RC.db is populated by
-- profile load, which has no single reliable event in Classic Era.
------------------------------------------------------------------------

-- Taint-safe API locals (fallbacks on RC.Compat, built in Core;
-- never write _G - a written Blizzard global taints its readers)
local RCC = _G.Readycheck
local RC = RCC
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local UnitAura = UnitAura or (RCC and RCC.Compat and RCC.Compat.UnitAura)

local function RunConsumablesInit()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, RunConsumablesInit)
        return
    end
    if not RC.db then
        C_Timer.After(0.2, RunConsumablesInit)
        return
    end
    -- Latch: the retry timers above can queue more than one pending call,
    -- and running an init closure twice duplicates frames and event hooks.
    if RC._chInitDone then return end
    RC._chInitDone = true
    local list = RC._chInit or {}
    for i = 1, #list do
        list[i]()
    end
end
RunConsumablesInit()

-- The deferred InitConsumableTTSVoice call moved to the main addon's
-- Systems\TTSEngine.lua along with the rest of the speech engine, so the
-- voice still gets picked when this addon is switched off.

