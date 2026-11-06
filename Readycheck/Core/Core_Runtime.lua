------------------------------------------------------------------------
-- Readycheck - Runtime Glue: Trinket Intent, ADDON_LOADED, Macro Migration
-- Tracks "why is this trinket about to swap" (trinketIntent / pending
-- indicators), handles the ADDON_LOADED bootstrap (SavedVariables
-- migration, companion addon auto-enable, RC:Initialize/OnEnable), and
-- rewrites old WarriorReminder-named macros to Readycheck on login.
------------------------------------------------------------------------
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
local RC = _G.Readycheck
if not RC then return end
local _cor = RC._cor
RC.weaponsBar = {
    frame = nil,
    buttons = {},
    stableStateReached = false,
    cachedShouldShow = nil,
    lastZoneCheck = 0
}

function RC:CleanupEvents()
    if self.events then
        for event, frame in pairs(self.events) do
            if frame and frame.UnregisterAllEvents then
                frame:UnregisterAllEvents()
            end
        end
    end

    if self.timers then
        for id, timer in pairs(self.timers) do
            if timer and timer.Cancel then
                timer:Cancel()
            end
        end
        wipe(self.timers)
    end

    if self.activeReminderData then
        if self.activeReminderData.dismissalTimer then
            self.activeReminderData.dismissalTimer:Cancel()
            self.activeReminderData.dismissalTimer = nil
        end
    end
    if self.StopReminderAnimation then self:StopReminderAnimation() end

    self:DebugPrint("Event cleanup complete", "system")
end

-- ============================================================
-- ============================================================
RC.trinketIntent = {}

function RC:SetTrinketIntent(slotNumber, source)
    if slotNumber ~= 13 and slotNumber ~= 14 then return end
    self.trinketIntent[slotNumber] = { source = source, t = GetTime() }
    self:DebugPrint("Trinket intent slot " .. slotNumber .. " -> " .. source, "trinket")
    self:RefreshPendingTrinketIndicators()
end

do
    local rf = CreateFrame("Frame")
    rf:RegisterEvent("PLAYER_REGEN_ENABLED")
    rf:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    rf:SetScript("OnEvent", function(_, event, slot)
        if event == "PLAYER_EQUIPMENT_CHANGED" then
            if slot == 13 or slot == 14 then
                RC:RefreshPendingTrinketIndicators()
            end
            return
        end
        -- 1.5s delay: PLAYER_REGEN_ENABLED can fire before queued gear
        -- swaps (Core_Gear.lua's ProcessGearSwapQueue) finish equipping,
        -- so refreshing indicators immediately would show stale state.
        C_Timer.After(1.5, function() RC:RefreshPendingTrinketIndicators() end)
    end)
end

-- Same three pending sources CancelQueuedSwapsForSlot (Core_Gear.lua)
-- reconciles: boss-death swap, the macro/gearset queue, and gear-set
-- links. Checked in this priority order (death swap wins over queue).
function RC:GetPendingTrinketForSlot(slotNumber)
    local pd = self.pendingDeathTrinketSwap
    if pd then
        local id = (slotNumber == 13) and pd.slot1 or (slotNumber == 14) and pd.slot2 or nil
        if id and id ~= 0 then return id, pd.isRoute and "route" or "boss" end
    end
    if self.gearSwapQueue then
        for i = #self.gearSwapQueue, 1, -1 do
            local qi = self.gearSwapQueue[i]
            if type(qi) == "string" then
                local gs = self.GearManager and self.GearManager.sets
                    and self.GearManager.sets[qi]
                local link = gs and gs.equip and gs.equip[slotNumber]
                if link and link ~= 0 then
                    local iid = tonumber(tostring(link):match("item:(%d+)")) or link
                    if type(iid) == "number" then return iid, "gearset" end
                end
            elseif type(qi) == "table" and qi.inventorySlot == slotNumber
                   and not qi.display then
                local iid = qi.itemId
                if not iid and qi.bag and qi.slot and C_Container
                   and C_Container.GetContainerItemID then
                    iid = C_Container.GetContainerItemID(qi.bag, qi.slot)
                end
                if iid then return iid, "dock" end
            end
        end
    end
    return nil
end

function RC:GetActiveQueueFrontForSlot(slotNumber)
    local ts = self.db and self.db.trinketSwap
    if not (ts and ts.enabled) then return nil end
    local q = ts.queues and ts.queues[ts.currentQueue or "default"]
    local list = q and ((slotNumber == 13) and q.slot1 or (slotNumber == 14) and q.slot2)
    if type(list) ~= "table" then return nil end
    local worn = GetInventoryItemID and GetInventoryItemID("player", slotNumber)
    local iid
    for _, entry in ipairs(list) do
        if entry and entry ~= 0 and entry ~= worn then
            iid = entry
            break
        end
    end
    if not iid then return nil end
    -- A shift-clicked "hide" only applies to the item that was at the
    -- front of the rotation when hidden; once the rotation advances past
    -- it, the hide is cleared automatically rather than sticking forever.
    local hid = self._queueFrontHidden and self._queueFrontHidden[slotNumber]
    if hid then
        if hid == iid then return nil end
        self._queueFrontHidden[slotNumber] = nil
    end
    return iid
end

function RC:RefreshPendingTrinketIndicators()
    local p13 = self:GetPendingTrinketForSlot(13)
    local p14 = self:GetPendingTrinketForSlot(14)
    local bar = self.trinketBar
    if bar and bar.buttons then
        for _, b in pairs(bar.buttons) do
            if b.queueBadge then b.queueBadge:Hide() end
        end
        for _, spec in ipairs({ { 13, p13 }, { 14, p14 } }) do
            local slot, pid = spec[1], spec[2]
            if pid then
                local dest, own
                for _, b in pairs(bar.buttons) do
                    local td = b.trinketData
                    if td then
                        if td.equipped and td.slotIndex == slot then dest = b end
                        if td.itemId == pid then own = b end
                    end
                end
                local target = dest or own
                if target and target.queueBadge then
                    local icon = GetItemIcon and GetItemIcon(pid)
                    if icon then target.queueBadge.icon:SetTexture(icon) end
                    target.queueBadge:Show()
                end
            end
        end
    end
    local GM = self.GearManager
    if GM then
        if GM.UpdateQueueIndicators then GM:UpdateQueueIndicators() end
        if GM.buttons then
            for _, sn in ipairs({ 13, 14 }) do
                local btn = GM.buttons[sn]
                if btn and btn._pendingTex then btn._pendingTex:Hide() end
            end
        end
    end
end

function RC:MacroEquip(spec, slotNumber)
    slotNumber = tonumber(slotNumber)
    if not spec or spec == "" or not slotNumber
       or slotNumber < 1 or slotNumber > 19 then
        self:Print(RCL["Usage: /rc equip(Item Name or itemId, slot). Slots: 1-19 (13/14 = trinkets)."])
        return
    end
    local itemId = tonumber(spec)
    local shownName = spec
    if not itemId then
        local want = spec:lower()
        local exact, partial, exactName, partialName
        RC.Bags:Each(function(_, _, iid)
            local nm = GetItemInfo(iid)
            if nm then
                local nl = nm:lower()
                if nl == want and not exact then
                    exact, exactName = iid, nm
                elseif not partial and nl:find(want, 1, true) then
                    partial, partialName = iid, nm
                end
            end
        end)
        itemId = exact or partial
        shownName = exactName or partialName or spec
    else
        shownName = GetItemInfo(itemId) or ("item " .. itemId)
    end
    if not itemId then
        self:Print(RCL["equip: no item matching '"] .. spec .. RCL["' in your bags."])
        return
    end
    if GetInventoryItemID("player", slotNumber) == itemId then
        self:Print(shownName .. RCL[" is already equipped in slot "] .. slotNumber .. ".")
        return
    end
    local inCombat = InCombatLockdown()
    if slotNumber == 13 or slotNumber == 14 then
        local pd = self.pendingDeathTrinketSwap or { boss = "Macro" }
        pd.boss = pd.boss or "Macro"
        pd.src = "macro"
        if slotNumber == 13 then pd.slot1 = itemId else pd.slot2 = itemId end
        self.pendingDeathTrinketSwap = pd
        if self.RefreshPendingTrinketIndicators then self:RefreshPendingTrinketIndicators() end
        if inCombat then
            self:Print(shownName .. RCL[" queued for slot "] .. slotNumber .. RCL[" - equips when combat ends."])
        else
            if self.RunPendingDeathTrinketSwap then self:RunPendingDeathTrinketSwap() end
            self:Print(RCL["Equipping "] .. shownName .. RCL[" to slot "] .. slotNumber .. ".")
        end
    else
        local ps = self.pendingDeathSlotSwap or { slots = {}, boss = "Macro" }
        ps.slots = ps.slots or {}
        ps.boss = ps.boss or "Macro"
        ps.src = "macro"
        ps.slots[slotNumber] = itemId
        self.pendingDeathSlotSwap = ps
        if inCombat then
            self:Print(shownName .. RCL[" queued for slot "] .. slotNumber .. RCL[" - equips when combat ends."])
        else
            if self.RunPendingDeathSlotSwap then self:RunPendingDeathSlotSwap() end
            self:Print(RCL["Equipping "] .. shownName .. RCL[" to slot "] .. slotNumber .. ".")
        end
    end
end

function RC:HasFreshManualTrinketIntent(slotNumber, maxAge)
    local it = self.trinketIntent[slotNumber]
    return it ~= nil and it.source ~= "tss"
        and (GetTime() - it.t) <= (maxAge or 10)
end

function RC:OnDisable()
    self:CleanupEvents()
    self.enabled = false
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:SetScript("OnEvent", function(self, event, addonName)
    if addonName == AddonName then
        if type(ReadycheckDB) ~= "table" and type(WarriorReminderDB) == "table" then
            ReadycheckDB = WarriorReminderDB
        end
        WarriorReminderDB = nil
        do
            local EnableFn = (C_AddOns and C_AddOns.EnableAddOn) or EnableAddOn
            local LoadFn   = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
            local StateFn  = C_AddOns and C_AddOns.GetAddOnEnableState
            local companions = { "Readycheck_Features", "Readycheck_Consumables",
                                 "Readycheck_Reminders",
                                 "Readycheck_Gear", "Readycheck_Extras",
                                 "Readycheck_WorldTools" }
            -- FRESH INSTALL. This is the first code to see the saved
            -- variables, so "the table does not exist" means exactly that:
            -- no character has run the addon on this account before. Only
            -- such an install gets the first-run tour (Readycheck_Extras
            -- Tutorial.lua, started by RC:MaybeStartTutorial); an existing
            -- install never gets the stamp and the tour never auto-opens.
            local freshInstall = type(ReadycheckDB) ~= "table"
            ReadycheckDB = ReadycheckDB or {}
            if freshInstall and type(ReadycheckDB.tutorial) ~= "table" then
                ReadycheckDB.tutorial = { fresh = true, opens = 0 }
            end

            -- Each companion gets exactly ONE automatic enable, recorded by
            -- name. After that its state is the user's to set and we never
            -- touch it again.
            --
            -- This used to be a single companionsAutoEnabled boolean, which
            -- broke the moment a new companion shipped: every existing
            -- install already had the flag set, so anything added later was
            -- never enabled and the load pass below then skipped it. An
            -- update that splits the addon further would have arrived with
            -- the new pieces silently switched off - which is exactly what
            -- addon managers do to newly installed folders anyway.
            local seen = ReadycheckDB.companionsSeen
            if type(seen) ~= "table" then
                seen = {}
                ReadycheckDB.companionsSeen = seen
                -- Carry the old boolean across: it meant "the companions
                -- that existed back then have had their one turn". Mark
                -- exactly those, so a user who deliberately switched one
                -- off does not get it forced back on, while genuinely new
                -- ones still get enabled once.
                if ReadycheckDB.companionsAutoEnabled then
                    seen["Readycheck_Features"]   = true
                    seen["Readycheck_Gear"]       = true
                    seen["Readycheck_Extras"]     = true
                    seen["Readycheck_WorldTools"] = true
                end
            end

            local justEnabled = {}
            for _, name in ipairs(companions) do
                if not seen[name] then
                    seen[name] = true
                    justEnabled[name] = true
                    if EnableFn then pcall(EnableFn, name) end
                end
            end
            ReadycheckDB.companionsAutoEnabled = true

            -- Order matters: Readycheck_Consumables lists Readycheck_Features
            -- as a dependency, and Readycheck_Reminders publishes the trigger
            -- engine that everything after it calls into. Both must be up
            -- before RC:Initialize() runs below, since the first event can
            -- fire immediately after.
            -- this game version's consumables list, before anything that
            -- reads it loads (DB_Consumables; nothing on Classic Era)
            RC:ApplyConsumableFlavor()

            local needsReload = nil
            for _, name in ipairs({ "Readycheck_Features", "Readycheck_Consumables",
                                    "Readycheck_Reminders", "Readycheck_Gear",
                                    "Readycheck_WorldTools" }) do
                -- Skip the state check for one we just enabled: the client
                -- can still report the old value this session, and treating
                -- that as "user disabled it" would skip a load we want.
                -- A companion this client does not run (Core_Flavor) is
                -- not loaded at all.
                local enabled = not RC:AddonOffByFlavor(name)
                if enabled and not justEnabled[name] and StateFn then
                    local ok, state = pcall(StateFn, name)
                    if ok and state == 0 then enabled = false end
                end
                if enabled and LoadFn then
                    local ok, err = pcall(LoadFn, name)
                    -- Enabling mid-session does not always let the client
                    -- load it before the next restart. Only worth a nag for
                    -- one we just switched on ourselves; a load that fails
                    -- for any other reason is the user's own choice.
                    if justEnabled[name] and (not ok or err == false) then
                        needsReload = (needsReload or 0) + 1
                    end
                end
            end
            if needsReload then
                RC._companionsNeedReload = needsReload
            end
            -- what a switched-off feature leaves behind goes quiet or
            -- says why (Core_Flavor)
            RC:ApplyFlavorStubs()
            RC:AddFlavorMenuStubs()
        end

        if RC:Initialize() then
            RC:OnEnable()
        end
        eventFrame:UnregisterEvent("ADDON_LOADED")
    end
end)

-- Blizzard tooltips can stay shown after their owner frame is hidden via
-- SetAlpha(0) rather than :Hide() (icons fading out do exactly this).
-- Poll while any tooltip is visible and force-hide it once the mouse is
-- no longer over the owner. Ticks stop the instant GameTooltip hides.
do
    local watchdog = CreateFrame("Frame")
    watchdog:Hide()
    watchdog._elapsed = 0

    watchdog:SetScript("OnUpdate", function(self, elapsed)
        self._elapsed = self._elapsed + elapsed
        if self._elapsed < 0.25 then return end
        self._elapsed = 0

        if not GameTooltip:IsShown() then
            self:Hide()
            return
        end

        local owner = GameTooltip:GetOwner()
        if owner and not owner:IsMouseOver() then
            GameTooltip:Hide()
        end
    end)

    GameTooltip:HookScript("OnShow", function() watchdog:Show() end)
    GameTooltip:HookScript("OnHide", function()
        watchdog:Hide()
        watchdog._elapsed = 0
    end)
end

-- One-time macro migration: older versions had users paste macros that
-- called the WarriorReminder / WarriorReminderGear globals, which no
-- longer exist. Rewrite any macro that still uses the old names to the
-- Readycheck equivalents. Idempotent: scans at login, only edits when an
-- old name is actually present, so after one pass it never edits again.
do
    local function FixOldMacros()
        if InCombatLockdown() then return false end
        local RC = _G.Readycheck
        local maxGlobal = MAX_ACCOUNT_MACROS or 120
        local numGlobal, numChar = GetNumMacros()
        local fixed = 0
        local function FixIndex(idx)
            local name, icon, body = GetMacroInfo(idx)
            if body and body:find("WarriorReminder", 1, true) then
                local newBody = body:gsub("WarriorReminderGear", "ReadycheckGear")
                newBody = newBody:gsub("WarriorReminder", "Readycheck")
                if newBody ~= body then
                    EditMacro(idx, name, icon, newBody)
                    fixed = fixed + 1
                end
            end
        end
        for i = 1, (numGlobal or 0) do FixIndex(i) end
        for i = maxGlobal + 1, maxGlobal + (numChar or 0) do FixIndex(i) end
        if fixed > 0 and RC and RC.DebugPrint then
            RC:DebugPrint("Updated " .. fixed .. " macro(s) from WarriorReminder to Readycheck", "config")
        end
        return true
    end

    local macroFixFrame = CreateFrame("Frame")
    macroFixFrame:RegisterEvent("PLAYER_LOGIN")
    macroFixFrame:SetScript("OnEvent", function(self, event)
        if event == "PLAYER_LOGIN" then
            C_Timer.After(5, function()
                if not FixOldMacros() then
                    self:RegisterEvent("PLAYER_REGEN_ENABLED")
                end
            end)
        elseif event == "PLAYER_REGEN_ENABLED" then
            if FixOldMacros() then
                self:UnregisterEvent("PLAYER_REGEN_ENABLED")
            end
        end
    end)
end

local _WRm = _G.Readycheck
if _WRm then
    _WRm._buildMarks = _WRm._buildMarks or {}
    _WRm._buildMarks["core_runtime"] = "equipped-aware-front"
end
