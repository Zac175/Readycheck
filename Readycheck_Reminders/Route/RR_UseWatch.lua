------------------------------------------------------------------------
-- Readycheck - Route Use-Watch and Kill Watch
-- Clears a route reminder when its item/ability is actually used, and
-- hosts RC.KillWatch, this addon's single CLEU reader - other features
-- register a lowercase-name payload set instead of reading CLEU directly.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local RC = _G.Readycheck
if not RC then return end
RC._rrs = RC._rrs or {}
local _rrs = RC._rrs
local RR = RC.RaidRoute
local PotionFamily, eventFrame = _rrs.PotionFamily, _rrs.eventFrame
    local useWatch = CreateFrame("Frame")

    local function RemItemSpellId(r)
        local iid = r.itemId
        if iid == "dummy" then
            iid = (RC.ResolveTargetDummy and RC:ResolveTargetDummy()) or 16023
        end
        if not iid or iid == 0 then return nil end
        local util = RC.utilityItems and RC.utilityItems[iid]
        if util and util.spellId then return util.spellId end
        if RC.potionItemIds and RC.potionData and RC.potionData.potions then
            local key = RC.potionItemIds[iid]
            local p = key and RC.potionData.potions[key]
            if p and p.spellId then return p.spellId end
        end
        local _, sid = GetItemSpell(iid)
        return sid
    end

    -- ability (not item) reminders match by this spellId -> key map since
    -- they have no itemId to key off of.
    local SPELL_TO_ABILITY = {
        [12292] = "deathwish", [12328] = "deathwish",
        [1719]  = "recklessness",
        [2687]  = "bloodrage",
        [18499] = "berserkerrage",
        [20572] = "bloodfury",
        [20554] = "berserking", [26296] = "berserking", [26297] = "berserking",
        [6673]  = "battleshout", [5242] = "battleshout", [6192] = "battleshout",
        [11549] = "battleshout", [11550] = "battleshout", [11551] = "battleshout",
        [25289] = "battleshout",
    }
    local KNOWN_ABILITY_KEYS = {}
    for _, k in pairs(SPELL_TO_ABILITY) do KNOWN_ABILITY_KEYS[k] = true end
    local function AbilityKeyFromText(text)
        if type(text) ~= "string" then return nil end
        local k = text:lower():gsub("[^%a]", "")
        return KNOWN_ABILITY_KEYS[k] and k or nil
    end

    local function ActiveReminderStep()
        local steps = RR:GetSteps()
        local st = steps and steps[RR.active]
        if st and (RR:IsReminderStep(st) or RR._awaitUse) then return st end
        return nil
    end

    local function UpdateUseWatchRegistration()
        local any = false
        for _, r in ipairs(RR.activeReminders) do
            if r.spellId or r.abilityKey then any = true; break end
        end
        if not any then
            local st = ActiveReminderStep()
            if st then
                for _, r in ipairs(st.actions.reminders) do
                    if RemItemSpellId(r) then any = true; break end
                end
            end
        end
        if not any then
            useWatch:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
        end
    end
    RR.UpdateUseWatch = UpdateUseWatchRegistration

    useWatch:SetScript("OnEvent", function(_, _, unit, _, spellId)
        if not spellId then return end
        local isPotionCast = false
        if RC.potionData and RC.potionData.potions then
            for _, p in pairs(RC.potionData.potions) do
                if p.spellId == spellId then isPotionCast = true break end
            end
        end
        if not isPotionCast then
            for iid in pairs(PotionFamily()) do
                local _, isp = GetItemSpell(iid)
                if isp and isp == spellId then isPotionCast = true break end
            end
        end
        local removed = false
        local castKey = SPELL_TO_ABILITY[spellId]
        for idx, r in ipairs(RR.activeReminders) do
            local hit = (r.spellId == spellId)
                or (castKey ~= nil and r.abilityKey == castKey)
            if not hit and isPotionCast and r.itemId
               and PotionFamily()[r.itemId] then
                hit = true
            end
            if hit then
                table.remove(RR.activeReminders, idx)
                removed = true
                break
            end
        end
        if removed then
            UpdateUseWatchRegistration()
            RR:RefreshTracker()
        end
        local st = ActiveReminderStep()
        if st then
            local matched = false
            for _, r in ipairs(st.actions.reminders) do
                if RemItemSpellId(r) == spellId then matched = true break end
                if isPotionCast and r.itemId
                   and PotionFamily()[r.itemId] then
                    matched = true
                    break
                end
            end
            if matched then
                local outstanding = 0
                for _, rec in ipairs(RR.activeReminders) do
                    if rec.spellId then outstanding = outstanding + 1 end
                end
                if outstanding == 0 then
                    RR:AdvanceReminderStep()
                else
                    RC:DebugPrint("Route: item used - " .. outstanding
                        .. " use-item reminder(s) still outstanding", "route")
                end
            end
        end
    end)

    local function ItemUseSpellId(itemId)
        if not itemId or itemId == 0 then return nil end
        local util = RC.utilityItems and RC.utilityItems[itemId]
        if util and util.spellId then return util.spellId end
        if RC.potionItemIds and RC.potionData and RC.potionData.potions then
            local key = RC.potionItemIds[itemId]
            local p = key and RC.potionData.potions[key]
            if p and p.spellId then return p.spellId end
        end
        if GetItemSpell then
            local _, sid = GetItemSpell(itemId)
            return sid
        end
        return nil
    end

    local REMINDER_MAX = 4

    function RR:ClearReminders()
        self._payloadGen = (self._payloadGen or 0) + 1
        if next(self.activeReminders) then
            self.activeReminders = {}
            self:RefreshTracker()
        end
        UpdateUseWatchRegistration()
    end

    function RR:ShowRouteReminder(text, icon, itemId)
        if icon == 134400 or icon == "134400" or (type(icon) == "string"
           and icon:lower():find("questionmark", 1, true)) then
            icon = "Interface\\Icons\\INV_Misc_Note_01"
        end
        -- a reminder made on the route page carries the item but no icon
        if not icon and type(itemId) == "number" and itemId > 0 and GetItemIcon then
            icon = GetItemIcon(itemId)
        end
        icon = icon or "Interface\\Icons\\INV_Misc_Note_01"
        if itemId == "dummy" then
            itemId = (RC.ResolveTargetDummy and RC:ResolveTargetDummy()) or 16023
            icon = (GetItemIcon and GetItemIcon(itemId)) or icon
        end
        self._remGen = (self._remGen or 0) + 1
        local rec = {
            text = text or "",
            icon = icon or 134400,
            itemId = itemId,
            spellId = ItemUseSpellId(itemId),
            abilityKey = (not itemId) and AbilityKeyFromText(text) or nil,
            gen = self._remGen,
        }
        if itemId and not rec.spellId then
            RC:DebugPrint("Route: no use-spell known for item " .. tostring(itemId)
                .. " - reminder will not auto-clear on use", "route")
        end
        local list = self.activeReminders
        list[#list + 1] = rec
        -- keep at most REMINDER_MAX entries, matching the tracker's
        -- remLines slot count.
        if #list > REMINDER_MAX then table.remove(list, 1) end
        if rec.spellId or rec.abilityKey then
            useWatch:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
        end
        if not self.raidName then
            local gen = rec.gen
            C_Timer.After(10, function()
                for idx, r in ipairs(RR.activeReminders) do
                    if r.gen == gen then
                        table.remove(RR.activeReminders, idx)
                        RR:RefreshTracker()
                        UpdateUseWatchRegistration()
                        break
                    end
                end
            end)
        end
        self:RefreshTracker()
    end

    function RR:UpdateUICount()
        self:UpdateTrackerCount()
        local fr = self._uiFrame
        if fr and not fr:IsVisible() then return end
        local fn = self._uiCountUpdate
        if fn then pcall(fn) end
    end

    function RR:RefreshUI()
        if not self._uiRefresh then return end
        local fr = self._uiFrame
        if fr and not fr:IsVisible() then return end
        if InCombatLockdown() then
            self._refreshAfterCombat = true
            self:UpdateUICount()
            return
        end
        if self._refreshPending then return end
        self._refreshPending = true
        C_Timer.After(0.1, function()
            RR._refreshPending = false
            local fn = RR._uiRefresh
            if fn then pcall(fn) end
        end)
    end

    -- RC.KillWatch: the addon's only COMBAT_LOG_EVENT_UNFILTERED reader.
    -- New features register via RC:KillWatchRegister(id, set, cb), set
    -- keyed by CanonMob(name); the route registers as "route" and gets
    -- back its own configured mob name as the payload in OnHostileDeath.
    do
        local DEATH_SUBEVENTS = {
            UNIT_DIED = true, UNIT_DESTROYED = true, SPELL_INSTAKILL = true,
        }
        local KW = { consumers = {}, n = 0 }
        RC.KillWatch = KW
        local kwFrame = CreateFrame("Frame")

        -- one creature, one death: an instakill logs SPELL_INSTAKILL and
        -- then UNIT_DIED for the same GUID, which counted twice for every
        -- consumer. GUIDs seen in the last DEATH_DEDUPE..2x seconds are
        -- kept in two generations that swap on a timer, so a lookup is one
        -- table index and the tables never outgrow a few seconds of deaths.
        local DEATH_DEDUPE = 5
        local deadCur, deadPrev, deadT0 = {}, {}, 0

        -- listens for CLEU only while a consumer is registered.
        local function Rearm()
            local want = KW.n > 0 and not _G.READYCHECK_IS_FOREVER   -- (no combat log on WoW Forever)
                and RC:FeatureOn("kill_watch")
            if want ~= KW.armed then
                if want then
                    kwFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
                else
                    kwFrame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
                end
                KW.armed = want
            end
        end

        local function CanonMob(n)
            return n and n:lower():gsub("%s+", "") or nil
        end
        KW.CanonMob = CanonMob

        function RC:KillWatchRegister(id, set, cb)
            if not id or not set or not next(set) or not cb then
                return self:KillWatchUnregister(id)
            end
            local canon = {}
            for k, v in pairs(set) do
                local ck = CanonMob(k)
                if ck then canon[ck] = v end
            end
            if not next(canon) then return self:KillWatchUnregister(id) end
            if not KW.consumers[id] then KW.n = KW.n + 1 end
            KW.consumers[id] = { set = canon, cb = cb }
            Rearm()
        end

        function RC:KillWatchUnregister(id)
            if id and KW.consumers[id] then
                KW.consumers[id] = nil
                KW.n = KW.n - 1
                Rearm()
            end
        end

        -- every CLEU event lands here; cheap subevent-type early-out
        -- keeps this safe at combat-log frequency.
        kwFrame:SetScript("OnEvent", function()
            local _, sub, _, _, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
            if not DEATH_SUBEVENTS[sub] then return end
            if not destName then return end
            if destGUID then
                local now = GetTime()
                if now - deadT0 >= DEATH_DEDUPE then
                    if now - deadT0 >= DEATH_DEDUPE * 2 then
                        deadPrev = {}
                    else
                        deadPrev = deadCur
                    end
                    deadCur = {}
                    deadT0 = now
                end
                if deadCur[destGUID] or deadPrev[destGUID] then return end
                deadCur[destGUID] = true
            end
            local dl = KW.CanonMob(destName)
            local matched = false
            for _, consumer in pairs(KW.consumers) do
                local payload = consumer.set[dl]
                if payload ~= nil then
                    matched = true
                    -- "Creature" GUID prefix excludes player/pet deaths.
                    if destGUID and destGUID:sub(1, 8) == "Creature" then
                        consumer.cb(payload, destName)
                    end
                end
            end
            if not matched then
                local seen = RR._unmatchedDeaths
                if not seen then seen = {}; RR._unmatchedDeaths = seen end
                if not seen[destName] then
                    seen[destName] = true
                    RC:DebugPrint("KillWatch: unmatched death '" .. destName .. "'", "route")
                end
            end
        end)
    end

    -- routes run on the game versions whose raids are listed (Core_Flavor)
    if RC:FeatureOn("raid_route") then
        eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
        eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
        eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    end
    eventFrame:SetScript("OnEvent", function(_, event, ...)
        -- combat ended: run work deferred while InCombatLockdown() blocked
        -- it (queued equips, held announcements, awaited use-reminder).
        if event == "PLAYER_REGEN_ENABLED" then
            if RR._refreshAfterCombat then
                RR._refreshAfterCombat = false
                RR:RefreshUI()
            end
            if RR._finishAnnounce then
                local f = RR._finishAnnounce
                RR._finishAnnounce = nil
                C_Timer.After(2.5, f)
            end
            if RR._pendingEquipFlash then
                local pf = RR._pendingEquipFlash
                RR._pendingEquipFlash = nil
                RR:SetTransitionHold(pf)
            end
            if RR._awaitUse then
                local idx = RR.active
                C_Timer.After(2.5, function()
                    RR:OnRouteEquipsLanded(idx)
                end)
            end
        else
            RR:UpdateArming()
            C_Timer.After(2, function() RR:UpdateArming() end)
        end
    end)

    RC:DebugPrint("Raid Route engine loaded", "route")
