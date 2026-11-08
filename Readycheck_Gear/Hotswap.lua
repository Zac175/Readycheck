-- Taint-safe API locals (fallbacks on RC.Compat, built in Core;
-- never write _G - a written Blizzard global taints its readers)
local RCC = _G.Readycheck
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)
local GetSpellCooldown = GetSpellCooldown or (RCC and RCC.Compat and RCC.Compat.GetSpellCooldown)
------------------------------------------------------------------------
-- Readycheck - Hotswap
-- Spell-triggered temporary gear swaps (T2 Battle Shout, Diamond Flask,
-- Bloodrage-triggered Battle Shout). QueueSpellHotswap equips swapSet up
-- front and arms a watch for UNIT_SPELLCAST_SUCCEEDED on spellName;
-- StopSpellHotswap then restores gear from a full pre-swap snapshot
-- (falling back to the previously-equipped set name, then an ItemRack
-- unequip). Armour cannot move under combat lockdown, so a press in
-- combat is either refused with the block message or - with
-- db.hotswapCombatQueue on - remembered and run when combat ends.
------------------------------------------------------------------------
local function InitializeHotswap()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeHotswap)
        return
    end

    if not RC.db then
        C_Timer.After(0.1, InitializeHotswap)
        return
    end

    RC.Hotswap = {}
    local HS = RC.Hotswap

    HS.queueSet = nil
    HS.queueSpell = nil
    HS.queueDelayTimestamp = GetTime()
    HS.enabled = RC.db.hotswapEnabled ~= false
    HS.previousSet = nil
    HS.combatQueue = nil        -- a swap asked for in combat, waiting for it to end
    HS.restorePending = false   -- the swap-back was due while lockdown was up
    HS.swapGen = 0

    -- HOLD: how long the boost set stays on waiting for the cast before it
    -- is put back. A swap that fired by itself when combat ended gets
    -- HOLD_QUEUED: the player did not pick the moment and has to see it.
    local HOLD, HOLD_QUEUED = 3.0, 5.0
    -- Queued swap timing after combat ends: first try, first try when the
    -- boss gear-swap system has post-combat equips of its own in flight
    -- (those land at 1.0-1.2s and would undo or be undone by this one),
    -- retry step, and how long to keep trying before letting it go.
    local QUEUE_FIRST, QUEUE_FIRST_BOSS, QUEUE_RETRY, QUEUE_GIVE_UP = 0.3, 1.5, 0.3, 8

    HS.eventFrame = CreateFrame("Frame", "WRHotswapEventFrame")
    HS.eventFrame:SetScript("OnEvent", function(self, event, ...)
        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            HS:OnSpellCast(...)
        elseif event == "PLAYER_REGEN_ENABLED" then
            HS:OnCombatEnd()
        end
    end)
    HS.eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

    local function BossGearActive()
        local gs = RC.gearSwapState
        if not gs then return false end
        if gs.lastBossTarget or (gs.postCombatSet and gs.postCombatSet ~= "") then
            return true
        end
        return (gs._postSwapActiveUntil and GetTime() < gs._postSwapActiveUntil) and true or false
    end

    -- The one place combatQueue is written. The queue markers on the
    -- docked buttons and the character sheet (GM:UpdateQueueIndicators,
    -- GM_CharSheet.lua) read it from here, so every change repaints them:
    -- that is how a press in combat is seen to have been taken.
    function HS:SetCombatQueue(q)
        self.combatQueue = q
        local GM = RC.GearManager
        if GM and GM.UpdateQueueIndicators then GM:UpdateQueueIndicators() end
    end

    -- Remember a press made in combat. Pressing again (the macro is
    -- usually spammed) just keeps the one entry; a different hotswap
    -- replaces it.
    function HS:QueueForCombatEnd(swapSet, spellName, usableCheck, spellCheck, itemCheck)
        if self.queueSet then
            RC:DebugPrint("Hotswap: boost set still on - nothing to queue", "hotswap")
            return
        end
        local q = self.combatQueue
        if q and q.set == swapSet and q.spell == spellName then
            -- the same entry again: nothing to repaint or announce
            q.boss = q.boss or BossGearActive()
            return
        end
        self:SetCombatQueue({
            set = swapSet, spell = spellName, usable = usableCheck,
            spellCheck = spellCheck, itemCheck = itemCheck,
            boss = BossGearActive(),
        })
        RC:Print(RCL["%s swap queued - gear swaps when combat ends."]:format(swapSet))
    end

    function HS:OnCombatEnd()
        if self.restorePending then
            C_Timer.After(0.2, function()
                if self.restorePending and not InCombatLockdown() then
                    self:StopSpellHotswap(false)
                end
            end)
            return
        end
        if self.combatQueue then self:RunCombatQueue() end
    end

    -- Runs the queued swap once combat is over and the gear is at rest.
    -- It goes through QueueSpellHotswap, so T2 protection and the
    -- Bloodrage / item-ready checks still decide; "can the spell be cast
    -- this instant" does not (see there). A check that fails is retried
    -- until QUEUE_GIVE_UP - a party member a moment behind on leaving
    -- combat is the usual reason - and the last one to fail is named when
    -- the swap is let go, so a queue that did nothing says why. Combat
    -- starting again leaves the entry queued for the next time it ends.
    function HS:RunCombatQueue()
        local q = self.combatQueue
        if not q then return end
        q.run = (q.run or 0) + 1
        q.why = nil
        local run = q.run
        local deadline = GetTime() + QUEUE_GIVE_UP

        local function attempt()
            if self.combatQueue ~= q or q.run ~= run then return end
            if InCombatLockdown() then return end
            if UnitIsDeadOrGhost("player") or not (RC.db and RC.db.hotswapCombatQueue) then
                self:SetCombatQueue(nil)
                return
            end
            local gearBusy = (RC.gearSwapQueue and #RC.gearSwapQueue > 0)
                or (RC.GearManager and RC.GearManager._pendingUnequips ~= nil)
            if gearBusy then
                q.why = RCL["other gear swaps were still running"]
            else
                self._firingQueue = true
                local ok, why = self:QueueSpellHotswap(q.set, q.spell, q.usable, q.spellCheck, q.itemCheck)
                self._firingQueue = nil
                if ok then
                    self:SetCombatQueue(nil)
                    RC:Print(RCL["Combat over - %s gear is on. Press your macro."]:format(q.set))
                    return
                end
                q.why = why or q.why
            end
            if GetTime() >= deadline then
                self:SetCombatQueue(nil)
                RC:Print(RCL["%s swap dropped - %s."]:format(q.set,
                    q.why or RCL["it could not be used after combat"]))
                return
            end
            C_Timer.After(QUEUE_RETRY, attempt)
        end

        C_Timer.After((q.boss or BossGearActive()) and QUEUE_FIRST_BOSS or QUEUE_FIRST, attempt)
    end

    function HS:QueueSpellHotswap(swapSet, spellName, usableCheck, spellCheck, itemCheck)
        if not self.enabled then
            return
        end

        if not swapSet or swapSet == "" then
            RC:DebugPrint("Hotswap: No swap set specified", "hotswap")
            return
        end

        if not spellName or spellName == "" then
            RC:DebugPrint("Hotswap: No spell name specified", "hotswap")
            return
        end

        if InCombatLockdown() then
            if RC.db and RC.db.hotswapCombatQueue then
                self:QueueForCombatEnd(swapSet, spellName, usableCheck, spellCheck, itemCheck)
                return
            end
            local msgTemplate = (RC.db and RC.db.hotswapCombatBlockMessage
                and RC.db.hotswapCombatBlockMessage ~= "")
                and RC.db.hotswapCombatBlockMessage
                or "%player% in combat -- not equipping T2!"
            RC:Print(msgTemplate:gsub("%%player%%", UnitName("player") or "?"))
            -- Once a session: the refusal above is the only thing a press
            -- in combat shows, and it does not say the queue exists.
            if not self._queueTipShown then
                self._queueTipShown = true
                RC:Print(RCL["Queue In Combat is off. Turn it on in the Hotswap settings and a press in combat waits for combat to end instead."])
            end
            return
        end

        if self.queueSet or self.queueSpell then
            RC:DebugPrint("Hotswap: Already queued", "hotswap")
            return
        end

        -- The checks below return (nil, why): a press ignores the reason,
        -- RunCombatQueue keeps it for its "swap dropped" line.

        -- Debounces re-triggering: without this, spamming the same spell
        -- (or its rank-swap variants) while already mid-swap would queue
        -- overlapping hotswaps that stomp each other's restore snapshot.
        if GetTime() <= self.queueDelayTimestamp then
            RC:DebugPrint("Hotswap: On cooldown", "hotswap")
            return nil, RCL["it had only just been used"]
        end

        -- Asked only of a key press, where an unusable spell means the
        -- macro's cast is about to fail and the swap would be for nothing.
        -- A queued swap is not followed by a cast: it puts the gear on and
        -- leaves the press to the player, and at the end of a fight the
        -- spell is nearly always on the GCD or short of rage (the same
        -- macro has been casting it in combat) - asking would hold the
        -- gear back for exactly the case the queue exists for.
        if usableCheck == nil then usableCheck = true end
        if usableCheck and not self._firingQueue and not self:CheckSpellUsable(spellName) then
            RC:DebugPrint("Hotswap: Spell not usable: " .. spellName, "hotswap")
            return nil, RCL["%s was not usable (not enough rage, or on cooldown)"]:format(spellName)
        end

        if spellCheck and not self:CheckSpellUsable(spellCheck) then
            RC:DebugPrint("Hotswap: Spell check failed: " .. spellCheck, "hotswap")
            return nil, RCL["%s was not ready"]:format(spellCheck)
        end

        if itemCheck and not self:CheckItemUsable(itemCheck) then
            RC:DebugPrint("Hotswap: Item check failed: " .. itemCheck, "hotswap")
            return nil, RCL["the item was not ready"]
        end

        if swapSet == "Battle Shout" and RC.db and RC.db.hotswapT2Protect then
            if self:IsPartyInCombatNearby() then
                RC:DebugPrint("Party in combat - not equipping T2 for Battle Shout", "hotswap")
                return nil, RCL["a party member was still in combat (T2 Protection)"]
            end
        end

        -- Snapshot uses the same schema as GM_Sets.lua's set.equip: a
        -- link or 0 per slot. StopSpellHotswap below feeds this straight
        -- back into EquipSet as a throwaway set.
        --
        -- Only the slots the boost set moves are recorded. The restore
        -- used to put back all twenty, which also undid anything else
        -- that changed while the boost set was on - above all the trinket
        -- auto-swap, which is at its busiest right after combat, exactly
        -- when a queued swap fires. Main and off hand travel together: a
        -- two-hander going on empties the other hand. A set the gear
        -- manager does not hold (ItemRack) still gets every slot.
        local previousGear = {}
        local function snap(slot)
            previousGear[slot] = GetInventoryItemLink("player", slot) or 0
        end
        local gmSet = RC.GearManager and RC.GearManager.sets and RC.GearManager.sets[swapSet]
        local moved = gmSet and gmSet.equip
        if moved and next(moved) then
            for slot in pairs(moved) do snap(slot) end
            if moved[16] ~= nil or moved[17] ~= nil then snap(16); snap(17) end
        else
            for slot = 0, 19 do snap(slot) end
        end
        self.previousGear = previousGear

        local previousSet = nil
        if RC.GearManager and RC.GearManager.GetCurrentEquippedSet then
            previousSet = RC.GearManager:GetCurrentEquippedSet()
            if previousSet then
                RC:DebugPrint("Hotswap: Detected previous set: " .. previousSet, "hotswap")
            end
        end
        self.previousSet = previousSet

        self.queueSet = swapSet
        self.queueSpell = spellName
        self.eventFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")

        -- This press is doing the swap, so it stands in for one still
        -- waiting from the fight just ended. Only here, past every check:
        -- the queue used to be cleared at the top, so a press that then
        -- failed one (the macro is mashed as combat ends, into the GCD)
        -- threw the queued swap away and did nothing in its place.
        if not self._firingQueue and self.combatQueue then self:SetCombatQueue(nil) end

        local equipped = false

        if RC.GearManager and RC.GearManager.sets and RC.GearManager.sets[swapSet] then
            equipped = RC.GearManager:EquipSet(swapSet)
            if equipped then
                RC:DebugPrint("Hotswap: Equipped " .. swapSet .. " via GearManager", "hotswap")
            end
        end

        if not equipped and RC.itemRackIntegration.available and ItemRack then
            ItemRack.EquipSet(swapSet)
            RC:DebugPrint("Hotswap: Equipped " .. swapSet .. " via ItemRack", "hotswap")
        end

        -- The timer only ends the swap it was started for: holds differ in
        -- length now, so an old one must not cut a newer swap short.
        self.swapGen = self.swapGen + 1
        local gen = self.swapGen
        C_Timer.After(self._firingQueue and HOLD_QUEUED or HOLD, function()
            if self.swapGen == gen then self:StopSpellHotswap(false) end
        end)
        return true
    end

    function HS:CheckSpellUsable(spell)
        if not IsUsableSpell(spell) then
            return false
        end

        local start, duration = GetSpellCooldown(spell)
        if start > 0 and duration > 0 then
            return false
        end

        return true
    end

    function HS:CheckItemUsable(itemID)
        if not IsEquippedItem(itemID) then
            return false
        end

        for slot = 1, 19 do
            if GetInventoryItemID("player", slot) == itemID then
                local start, duration = Readycheck.PlainCD(GetInventoryItemCooldown("player", slot))
                if start and start > 0 and duration and duration > 1.5 then
                    return false
                end
                return true
            end
        end

        return true
    end

    function HS:IsPartyInCombatNearby()
        local rangeItem = 3013

        local inRaid = IsInRaid()
        local unitsToCheck = {}

        if inRaid then
            local playerName = UnitName("player")
            local playerGroup = nil

            for i = 1, 40 do
                local name, _, group = GetRaidRosterInfo(i)
                if name == playerName then
                    playerGroup = group
                    break
                end
            end

            if playerGroup then
                for i = 1, 40 do
                    local name, _, group = GetRaidRosterInfo(i)
                    if group == playerGroup then
                        table.insert(unitsToCheck, "raid" .. i)
                    end
                end
            end
        else
            for i = 1, 4 do
                table.insert(unitsToCheck, "party" .. i)
            end
        end

        local msgTemplate = (RC.db and RC.db.hotswapCombatBlockMessage and RC.db.hotswapCombatBlockMessage ~= "")
            and RC.db.hotswapCombatBlockMessage
            or "%player% in combat -- not equipping T2!"

        local function printCombatMsg(unitName)
            -- A queued swap asks this on a timer, several times, with no
            -- key pressed: it must not talk in chat on the player's behalf
            -- (and SAY cannot be sent without a key press at all).
            if self._firingQueue then return end
            self:Announce((msgTemplate:gsub("%%player%%", unitName or "?")))
        end

        for _, unit in ipairs(unitsToCheck) do
            if UnitExists(unit) and UnitAffectingCombat(unit) and IsItemInRange(rangeItem, unit) then
                printCombatMsg(UnitName(unit))
                return true
            end

            local petUnit = unit .. "pet"
            if UnitExists(petUnit) and UnitAffectingCombat(petUnit) and IsItemInRange(rangeItem, petUnit) then
                printCombatMsg(UnitName(petUnit))
                return true
            end
        end

        return false
    end

    -- The only visible-chat output in the addon. Off unless the user
    -- turned it on; one line per 10s at most; never to a channel the
    -- player is not in (that errors).
    local ANNOUNCE_GAP = 10
    function HS:Announce(message)
        if not (RC.db and RC.db.hotswapPartyAnnounce) then return end
        local now = GetTime()
        if self._lastAnnounceAt and (now - self._lastAnnounceAt) < ANNOUNCE_GAP then return end
        local channel = RC.db.hotswapAnnounceChannel or "PARTY"
        if channel == "YELL" then channel = "SAY" end
        if channel == "RAID" and not IsInRaid() then channel = "PARTY" end
        if channel == "PARTY" and not IsInGroup() then return end
        if channel == "GUILD" and not IsInGuild() then return end
        self._lastAnnounceAt = now
        SendChatMessage(message, channel)
        RC:DebugPrint("Hotswap: announced to " .. channel .. ": " .. message, "hotswap")
    end

    function HS:OnSpellCast(unit, spellGUID, spellID)
        if unit == "player" then
            local spellName = GetSpellInfo(spellID)
            if spellName == self.queueSpell then
                if self.queueSet == "Battle Shout" then
                    local message = (RC.db and RC.db.hotswapAnnounceMessage) or "%player% T2 Battle Shout"
                    self:Announce((message:gsub("%%player%%", UnitName("player"))))
                end

                self:StopSpellHotswap(true)
            end
        end
    end

    function HS:StopSpellHotswap(setTimestamp)
        if not self.queueSet and not self.queueSpell then
            return
        end

        if setTimestamp then
            self.queueDelayTimestamp = GetTime() + 3.0
        end

        -- Combat started while the boost set was on. Nothing can be put
        -- back under lockdown - EquipSet would queue the throwaway restore
        -- set by name, and that set is gone again a few lines below - so
        -- keep the snapshot and finish from OnCombatEnd.
        if InCombatLockdown() then
            if not self.restorePending then
                self.restorePending = true
                RC:DebugPrint("Hotswap: restore deferred until combat ends", "hotswap")
            end
            return
        end
        self.restorePending = false

        if self.queueSet then
            local setToRestore = self.previousSet
            local gearToRestore = self.previousGear

            local restored = false

            if gearToRestore and next(gearToRestore) then
                RC:DebugPrint("Hotswap: Restoring exact gear snapshot", "hotswap")

                -- Reuses EquipSet's own resolution logic (weapon cross-moves,
                -- serialized ring/trinket swaps) by registering the snapshot
                -- as a throwaway set rather than re-implementing that here.
                local tempSet = {
                    name = "HotswapRestore",
                    icon = "Interface\\Icons\\INV_Misc_QuestionMark",
                    equip = gearToRestore
                }

                if RC.GearManager then
                    local originalSet = RC.GearManager.sets["HotswapRestore"]
                    RC.GearManager.sets["HotswapRestore"] = tempSet

                    RC.GearManager:EquipSet("HotswapRestore", true)

                    if originalSet then
                        RC.GearManager.sets["HotswapRestore"] = originalSet
                    else
                        RC.GearManager.sets["HotswapRestore"] = nil
                    end

                    restored = true
                end
            end

            if not restored and setToRestore and RC.GearManager and RC.GearManager.sets and RC.GearManager.sets[setToRestore] then
                RC.GearManager:EquipSet(setToRestore, true)
                RC:DebugPrint("Hotswap: Restored previous set: " .. setToRestore, "hotswap")
                restored = true
            end

            if not restored and RC.itemRackIntegration.available and ItemRack and ItemRack.UnequipSet then
                ItemRack.UnequipSet(self.queueSet)
                RC:DebugPrint("Hotswap: Unequipped via ItemRack", "hotswap")
            end
        end

        self.queueSet = nil
        self.queueSpell = nil
        self.previousSet = nil
        self.previousGear = nil
        self.eventFrame:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    end

    function RC:HotswapBattleShout()
        if not self.Hotswap then return end
        self.Hotswap:QueueSpellHotswap("Battle Shout", "Battle Shout")
    end

    function RC:HotswapBloodrage()
        if not self.Hotswap then return end
        self.Hotswap:QueueSpellHotswap("Battle Shout", "Battle Shout", false, "Bloodrage")
    end

    function RC:HotswapDiamondFlask()
        if not self.Hotswap then return end
        self.Hotswap:QueueSpellHotswap("Diamond Flask", "Diamond Flask", false, nil, 20130)
    end

    if RC.db.hotswapEnabled == nil then
        RC.db.hotswapEnabled = true
    end
    if RC.db.hotswapT2Protect == nil then
        RC.db.hotswapT2Protect = true
    end
    if RC.db.hotswapPartyAnnounce == nil then
        RC.db.hotswapPartyAnnounce = false
    end
    if RC.db.hotswapCombatBlockMessage == nil then
        RC.db.hotswapCombatBlockMessage = "%player% in combat -- not equipping T2!"
    end
    if RC.db.hotswapCombatQueue == nil then
        RC.db.hotswapCombatQueue = false
    end
end

C_Timer.After(1, InitializeHotswap)
