------------------------------------------------------------------------
-- Readycheck - Consumables Events
-- One event frame for the four bars (consumables, potions, weapons,
-- trinkets) and the cooldown machinery behind them.
--
-- Each bar used to keep its own frame with the same zone / rest / roster
-- / combat / bag events, so one loot fired four BAG_UPDATE handlers and
-- four timers, and a zone change ran four copies of the same settle
-- logic. The bars stay separate - own frame, own settings, own look -
-- but now hear the world through here:
--
--   * zone, rest and roster changes: one pass that re-decides every
--     bar's visibility - and only when something the visibility rules
--     read actually changed. Walking through a city fires subzone events
--     by the dozen and a forming raid fires roster events constantly;
--     each used to re-decide (and so rebuild) all four bars;
--   * loading screens: one 2s hold on bag-driven rebuilds for the bars
--     that want it, instead of one timer per bar per event;
--   * combat start: one pass that hides the bars set to hide in combat,
--     reading each bar's settings live (a profile switch used to leave
--     the bars reading the old profile's choice);
--   * bags: no BAG_UPDATE at all. The shared bag index (RC.Bags) says
--     when the contents actually changed - a loot storm is one call, and
--     a durability tick or a re-sort that changed nothing is none - and
--     one short timer then hands every bar the news together.
--
--   RC:RegisterBarEvents(key, spec)    key = "consumablesHelper", ...
--     spec.visibility    RC method name that re-decides shown/hidden
--     spec.settle        true: the bar's stableStateReached goes false for
--                        2s after a loading screen (its bags handler checks it)
--     spec.keepInCombat  optional fn() -> true to skip the combat hide
--     spec.combatEnd     fn() when combat ends
--     spec.bags          optional fn() after the bag contents changed
--     spec.equip         optional fn(slotId) on PLAYER_EQUIPMENT_CHANGED
--   RC:OnBarsEvent(event, fn, unit)    any other event: fn(event, ...);
--                                      unit = "player" for unit events
------------------------------------------------------------------------
local WRF = _G.Readycheck
if not WRF then return end
WRF._chInit = WRF._chInit or {}
WRF._chInit[#WRF._chInit + 1] = function()
    local RC = _G.Readycheck
    local C_Timer = C_Timer
    local xpcall, geterrorhandler = xpcall, geterrorhandler
    local GetInstanceInfo, IsResting, IsInRaid, IsInGroup = GetInstanceInfo, IsResting, IsInRaid, IsInGroup
    local tostring = tostring

    local frame = CreateFrame("Frame")
    local handlers = {}     -- [event] = { fn, ... } in the order added

    function RC:OnBarsEvent(event, fn, unit)
        local list = handlers[event]
        if not list then
            list = {}
            handlers[event] = list
            if unit then frame:RegisterUnitEvent(event, unit) else frame:RegisterEvent(event) end
        end
        list[#list + 1] = fn
    end

    -- An event with several handlers runs each one protected, so one that
    -- throws (reported as usual) cannot silently skip the rest. The
    -- arguments go through upvalues rather than a closure per call -
    -- BAG_UPDATE_COOLDOWN is one of the shared ones - and are restored
    -- afterwards in case a handler fires another event on the spot.
    local runFn, runEvent, r1, r2, r3, r4
    local function Run() runFn(runEvent, r1, r2, r3, r4) end
    frame:SetScript("OnEvent", function(_, event, ...)
        local list = handlers[event]
        if #list == 1 then return list[1](event, ...) end
        local pf, pe, p1, p2, p3, p4 = runFn, runEvent, r1, r2, r3, r4
        runEvent, r1, r2, r3, r4 = event, ...
        for i = 1, #list do
            runFn = list[i]
            xpcall(Run, geterrorhandler())
        end
        runFn, runEvent, r1, r2, r3, r4 = pf, pe, p1, p2, p3, p4
    end)

    -- The bars, in the order they registered. A bar's handler that throws
    -- is reported and the rest still run.
    local bars, order = {}, {}

    function RC:RegisterBarEvents(key, spec)
        if not bars[key] then order[#order + 1] = key end
        bars[key] = spec
    end

    local function Each(field, a)
        for i = 1, #order do
            local key = order[i]
            local st, fn = RC[key], bars[key][field]
            if fn and st and st.frame then
                if a == nil then
                    xpcall(fn, geterrorhandler())
                else
                    xpcall(function() fn(a) end, geterrorhandler())
                end
            end
        end
    end

    RC:OnBarsEvent("PLAYER_REGEN_DISABLED", function()
        -- the containers are not secure, so hiding them in combat is legal
        for i = 1, #order do
            local key = order[i]
            local st, spec, d = RC[key], bars[key], RC.db and RC.db[key]
            if st and st.frame and d and d.hideInCombat
                and not (spec.keepInCombat and spec.keepInCombat()) then
                st.frame:Hide()
            end
        end
    end)

    RC:OnBarsEvent("PLAYER_REGEN_ENABLED", function() Each("combatEnd") end)

    RC:OnBarsEvent("PLAYER_EQUIPMENT_CHANGED", function(_, slotId) Each("equip", slotId) end)

    local function QueueAll(settle)
        for i = 1, #order do
            local key = order[i]
            local st = RC[key]
            if st and st.frame then
                RC:QueueVisibilityCheck(st, bars[key].visibility, settle)
            end
        end
    end

    -- What the visibility modes read: rested (city), the instance and
    -- which raid it is (raid modes and the raid filter), and the group.
    local function WorldKey()
        local _, instanceType, _, _, _, _, _, instanceID = GetInstanceInfo()
        return (IsResting() and "r" or "-") .. tostring(instanceType) .. tostring(instanceID)
            .. (IsInRaid() and "R" or IsInGroup() and "P" or "S")
    end

    -- Loading screens always re-decide and re-arm the settle hold;
    -- PLAYER_ENTERING_WORLD also asks for the second look ~1s later (the
    -- zone APIs lag a loading screen). Subzone, rest and roster signals
    -- wait out their burst (0.3s) and re-decide only if WorldKey moved.
    local settleTimer, lastWorld, worldPending
    local function WorldCheck()
        worldPending = false
        local k = WorldKey()
        if k == lastWorld then return end
        lastWorld = k
        QueueAll(false)
    end
    local function OnZone(event)
        if event ~= "PLAYER_ENTERING_WORLD" and event ~= "ZONE_CHANGED_NEW_AREA" then
            if not worldPending then
                worldPending = true
                C_Timer.After(0.3, WorldCheck)
            end
            return
        end
        -- this re-decide (and its settle re-run) covers the world as it
        -- is now, so the subzone events that ride along with a loading
        -- screen find nothing new
        lastWorld = WorldKey()
        QueueAll(event == "PLAYER_ENTERING_WORLD")
        local hold = false
        for i = 1, #order do
            local key = order[i]
            local st = RC[key]
            if st and st.frame and bars[key].settle then
                st.stableStateReached = false
                hold = true
            end
        end
        if hold then
            if settleTimer then settleTimer:Cancel() end
            settleTimer = C_Timer.NewTimer(2.0, function()
                settleTimer = nil
                for i = 1, #order do
                    local key = order[i]
                    if bars[key].settle and RC[key] then RC[key].stableStateReached = true end
                end
            end)
        end
    end
    RC:OnBarsEvent("PLAYER_ENTERING_WORLD", OnZone)
    RC:OnBarsEvent("ZONE_CHANGED_NEW_AREA", OnZone)
    RC:OnBarsEvent("ZONE_CHANGED", OnZone)
    RC:OnBarsEvent("ZONE_CHANGED_INDOORS", OnZone)
    RC:OnBarsEvent("PLAYER_UPDATE_RESTING", OnZone)
    RC:OnBarsEvent("GROUP_ROSTER_UPDATE", OnZone)

    -- The bag index calls this inside its own read (only after a real
    -- change), so it only arms the timer.
    local bagsPending = false
    local function RunBags()
        bagsPending = false
        Each("bags")
    end
    RC.Bags:OnChange("ConsumableBars", function()
        if bagsPending then return end
        bagsPending = true
        C_Timer.After(0.3, RunBags)
    end)
end
