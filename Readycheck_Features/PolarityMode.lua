------------------------------------------------------------------------
-- Readycheck - Polarity Mode
-- Naxxramas cooldown helper: takes a pull timer, schedules Death Wish
-- before the pull and Recklessness / trinket at it, then arms a second
-- stage that fires Limited Invulnerability Potion and the target dummy.
-- The polarity charge itself is read from the player's own debuffs -
-- spell ids 28059 / 28084 in IsInPolarityContext - alongside the
-- Sapphiron encounter and Frostwyrm Lair zone checks that gate the rest.
-- Stage one is measured backwards from countdown zero; stage two is
-- anchored to the ACTUAL engage (ENCOUNTER_START id 1119, boss CLEU, or
-- player combat with the boss up), never to countdown zero, because the
-- raid's run-in time varies pull to pull.
-- A separate timer starts when Thaddius dies: the bar counts down to
-- Sapphiron's spawn and Death Wish pops at the usual lead.
------------------------------------------------------------------------

-- Taint-safe API locals (fallbacks on RC.Compat, built in Core;
-- never write _G - a written Blizzard global taints its readers)
local RCC = _G.Readycheck
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local function InitializePolarityMode()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializePolarityMode); return end
    if not RC.db then C_Timer.After(0.2, InitializePolarityMode); return end
    -- Thaddius and Sapphiron: Classic Era only (Core_Flavor)
    if RC.FeatureOn and not RC:FeatureOn("polarity") then return end

    RC.polarityMode = RC.polarityMode or {
        pullTimerEnd   = nil,
        pullTimerStart = nil,
        pullTimerSource = nil,
        scheduledTimers = {},
        sequenceFired  = false,
        armed          = false,
        armedLipTime   = 5,
        armedLipBuff   = 6,
        thadTimers     = {},
    }

    function RC:InitializePolarityModeDB()
        if not self.db.polarityMode then self.db.polarityMode = {} end
        local db = self.db.polarityMode
        local defaults = {
            enabled          = false,
            deathWishLead    = 5,
            reckEnabled      = true,
            reckDelay        = 0,
            trinketEnabled   = true,
            trinketDelay     = 0,
            trinketSlot      = 13,
            lipTime          = 5,
            acceptCountdown  = true,
            acceptDBM        = true,
            acceptBigWigs    = true,
            acceptChatFallback = true,
            barEnabled       = true,
            barTexture       = "Readycheck Smooth",
            barSound         = "",
            barWidth         = 170,
            barHeight        = 22,
            barShowIcon      = true,
            barAnchorPoint   = "CENTER",
            barXOffset       = 0,
            barYOffset       = 80,
            barVoiceLeadMs   = 1000,
            thadTimer        = true,
            thadTimerSec     = 24,
        }
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end
        -- One-time rebase: LIP time used to default to 6, counted from
        -- countdown zero. It now counts from the actual engage, matching
        -- the reference WeakAura pack (LIP at 5, dummy at 11). Rebase a
        -- stored old default once; a value set deliberately after this
        -- sticks, including 6.
        if not db.lipEngageRebased then
            db.lipEngageRebased = true
            if db.lipTime == 6 then db.lipTime = 5 end
        end
    end

    local function dbg(msg)
        RC:DebugPrint(msg, "polarity")
    end

    local DEFAULT_VOICE_LEAD = 1.0
    local function VoiceLeadSec()
        local d = RC.db and RC.db.polarityMode
        local ms = d and d.barVoiceLeadMs
        if type(ms) == "number" and ms >= 0 then return ms / 1000 end
        return DEFAULT_VOICE_LEAD
    end

    local function CancelAllTimers()
        local state = RC.polarityMode
        if state.scheduledTimers then
            for _, t in ipairs(state.scheduledTimers) do
                if t and t.Cancel then
                    pcall(t.Cancel, t)
                end
            end
        end
        if RC.polarityMode._StopEngageWatch then
            RC.polarityMode._StopEngageWatch()
        end
        state.scheduledTimers = {}
    end

    -- Display names for the dummy the addon may prompt; the actual
    -- pick comes from RC:ResolveTargetDummy (what is in the bags).
    local DUMMY_NAMES = {
        [16023] = "Masterwork Target Dummy",
        [4392]  = "Advanced Target Dummy",
        [22261] = "Love Fool",
    }

    local function ResolvePolarityDummy()
        local itemId = (RC.ResolveTargetDummy and RC:ResolveTargetDummy()) or 16023
        return itemId, DUMMY_NAMES[itemId] or "Target Dummy"
    end
    RC.polarityMode._ResolveDummy = ResolvePolarityDummy

    -- Polarity charge read: 28059 Positive Charge, 28084 Negative Charge,
    -- from the shared aura read (RC.Auras), by spell id rather than the
    -- localized aura name.
    local function IsInPolarityContext()
        if RC.Auras:Debuff(28059) or RC.Auras:Debuff(28084) then
            return true
        end
        if RC.polarityMode.inSapphironZone then
            return true
        end
        if RC.activeEncounterName and RC.activeEncounterName:lower():find("sapphiron", 1, true) then
            return true
        end
        for i = 1, 5 do
            local unit = "boss" .. i
            if UnitExists(unit) then
                local n = UnitName(unit)
                if n and n:lower():find("sapphiron", 1, true) then
                    return true
                end
            end
        end
        return false
    end

    local function IsSapphironEngaged()
        if RC.activeEncounterName
           and RC.activeEncounterName:lower():find("sapphiron", 1, true) then
            return true
        end
        for i = 1, 5 do
            local unit = "boss" .. i
            if UnitExists(unit) then
                local n = UnitName(unit)
                if n and n:lower():find("sapphiron", 1, true) then
                    return true
                end
            end
        end
        return false
    end

    -- Sapphiron's creature id, parsed out of field 6 of a unit GUID.
    local SAPPHIRON_NPC_ID = 15989
    local engageWatchFrame

    local function GuidIsSapphiron(guid)
        if not guid then return false end
        local unitType, _, _, _, _, npcId = strsplit("-", guid)
        return (unitType == "Creature" or unitType == "Vehicle")
            and tonumber(npcId) == SAPPHIRON_NPC_ID
    end

    local function StopEngageWatch()
        if engageWatchFrame then
            engageWatchFrame:UnregisterAllEvents()
            engageWatchFrame:SetScript("OnEvent", nil)
        end
    end
    RC.polarityMode._StopEngageWatch = StopEngageWatch

    -- Backstop engage anchor for servers that never fire ENCOUNTER_START:
    -- registered only while armed, and torn down on the first boss line.
    -- Project rule reserves COMBAT_LOG_EVENT_UNFILTERED for RC.KillWatch;
    -- this is a second reader, kept alive only inside the armed window.
    local function StartEngageWatch()
        if not engageWatchFrame then
            engageWatchFrame = CreateFrame("Frame")
        end
        engageWatchFrame:SetScript("OnEvent", function()
            if not RC.polarityMode.armed then
                StopEngageWatch()
                return
            end
            local _, _, _, sourceGUID, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
            if GuidIsSapphiron(sourceGUID) or GuidIsSapphiron(destGUID) then
                RC:PolarityFireCombatAnchored("CLEU_SAPPHIRON_ENGAGE", true)
                if not RC.polarityMode.armed then
                    StopEngageWatch()
                end
            end
        end)
        if not _G.READYCHECK_IS_FOREVER then   -- (no combat log on WoW Forever)
            engageWatchFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
        end
    end

    -- While this mode owns the fight, the normal reminder engine must stay
    -- off every ability the scheduled sequence is going to fire itself,
    -- or the player gets two prompts at different times for each one.
    function RC:PolaritySuppressesAbility(abilityKey, encounterName)
        if not self.db or not self.db.polarityMode then return false end
        if not self.db.polarityMode.enabled then return false end

        if not encounterName then return false end
        if not encounterName:lower():find("sapphiron", 1, true) then return false end

        local db = self.db.polarityMode

        if abilityKey == "deathwish"                    then return true end
        if abilityKey == "recklessness"                 then return true end
        if abilityKey == "limitedInvulnerabilityPotion" then return true end
        if abilityKey == 16023 or abilityKey == "16023"
           or abilityKey == 4392  or abilityKey == "4392"
           or abilityKey == 22261 or abilityKey == "22261" then
            return true
        end

        local polaritySlot = (db.trinketSlot == 14) and "trinket2" or "trinket1"
        if abilityKey == polaritySlot then return true end

        return false
    end

    local function ForceSpeak(abilityKey)
        if not (RC.db and RC.db.ttsEnabled and RC.SpeakTTS) then return end
        if abilityKey == nil then return end

        local ready
        if type(abilityKey) == "number" then
            ready = ((GetItemCount and GetItemCount(abilityKey)) or 0) > 0
        elseif RC.IsAbilityReady then
            ready = RC:IsAbilityReady(abilityKey, true)
        else
            ready = true
        end
        if not ready then
            dbg("ForceSpeak skipped (not ready): " .. tostring(abilityKey))
            return
        end

        local speakName
        if RC.ttsSpokenNames then
            speakName = RC.ttsSpokenNames[abilityKey]
            if not speakName and type(abilityKey) == "number" then
                speakName = RC.ttsSpokenNames[tostring(abilityKey)]
            end
        end
        speakName = speakName or tostring(abilityKey)

        RC:SpeakTTS(speakName, true)

        if RC.activeReminderData then
            RC.activeReminderData.ttsPlayed = true
        end

        dbg("ForceSpeak: " .. tostring(abilityKey) .. " -> " .. tostring(speakName))
    end

    -- outOfCombat: the caller fires while nobody is fighting (the gap
    -- after Thaddius), so "show reminders in combat only" must not eat it
    local function FireReminder(label, abilities, outOfCombat)
        if not RC.db or not RC.db.polarityMode or not RC.db.polarityMode.enabled then
            return
        end
        if not RC.ShowReminder then
            dbg("ShowReminder missing - can't fire: " .. tostring(label))
            return
        end

        -- Merge into whatever the reminder frame is already showing rather
        -- than replacing it: two stages can overlap, and the second must
        -- not blank the first one's icon out from under the player.
        local merged = {}
        local seen   = {}
        if RC.activeReminderData and RC.activeReminderData.abilities then
            for _, a in ipairs(RC.activeReminderData.abilities) do
                if not seen[a] then
                    seen[a] = true
                    table.insert(merged, a)
                end
            end
        end
        for _, a in ipairs(abilities) do
            if not seen[a] then
                seen[a] = true
                table.insert(merged, a)
            end
        end

        dbg("Firing: " .. label .. " (new=" .. table.concat(abilities, ",") ..
            " | merged=" .. #merged .. " total)")
        RC._suppressReminderTTSOnce = true
        local combatOnly = RC.db.showInCombatOnly
        if outOfCombat and combatOnly then RC.db.showInCombatOnly = false end
        local ok, err = pcall(RC.ShowReminder, RC, label, merged, 0)
        if outOfCombat and combatOnly then RC.db.showInCombatOnly = combatOnly end
        RC._suppressReminderTTSOnce = nil
        if not ok then dbg("ShowReminder failed: " .. tostring(err)) end
    end

    function RC:PolarityScheduleSequence(pullInSeconds, source)
        if not self.db.polarityMode or not self.db.polarityMode.enabled then return end

        if not IsInPolarityContext() then
            dbg("Pull timer received from " .. tostring(source) ..
                " but Sapphiron not active - ignored")
            return
        end

        local db   = self.db.polarityMode
        local now  = GetTime()
        local T    = now + (pullInSeconds or 0)

        RC.polarityMode.pullTimerEnd    = T
        RC.polarityMode.pullTimerStart  = now
        RC.polarityMode.pullTimerSource = source or "unknown"
        RC.polarityMode.sequenceFired   = false

        if source ~= "resume_from_saved" then
            db.pendingPullEndAt = GetServerTime() + (pullInSeconds or 0)
            db.pendingPullSource = source or "unknown"
        end

        CancelAllTimers()

        local trinketAbilityKey = (db.trinketSlot == 14) and "trinket2" or "trinket1"

        -- Limited Invulnerability Potion grants 6s of immunity; the dummy
        -- is timed to land exactly as that runs out.
        local LIP_BUFF_DURATION = 6

        -- Stage one is measured backwards from countdown zero: deathWishLead
        -- is "seconds still on the pull timer when Death Wish fires", so a
        -- 30s pull with lead 5 schedules it 25s out.
        local dwAt = (pullInSeconds or 0) - (db.deathWishLead or 5)
        if dwAt > 0 then
            table.insert(RC.polarityMode.scheduledTimers,
                C_Timer.NewTimer(dwAt, function()
                    ForceSpeak("deathwish")
                    FireReminder("Death Wish", {"deathwish"})
                end))
            dbg(string.format(RCL["DW scheduled with %ds remaining on timer (in %.1fs)"],
                db.deathWishLead or 5, dwAt))
        else
            dbg("Pull timer too short for pre-combat DW - firing now")
            ForceSpeak("deathwish")
            FireReminder("Death Wish", {"deathwish"})
        end

        -- Reck and trinket are offsets from countdown zero itself, so their
        -- delays are added to the remaining pull time, not subtracted.
        local reckAt = db.reckEnabled and math.max(0, (pullInSeconds or 0) + (db.reckDelay or 0)) or nil
        local trinkAt = db.trinketEnabled and math.max(0, (pullInSeconds or 0) + (db.trinketDelay or 0)) or nil

        local function FireReckAndTrinketCombined()
            local speakKey = nil
            if db.reckEnabled then
                local reckReady = false
                if RC.IsAbilityReady then
                    local ready = RC:IsAbilityReady("recklessness", true)
                    reckReady = ready == true
                end
                if reckReady then
                    speakKey = "recklessness"
                end
            end
            if not speakKey and db.trinketEnabled then
                speakKey = trinketAbilityKey
            end

            local merged = {}
            if db.reckEnabled then table.insert(merged, "recklessness") end
            if db.trinketEnabled then table.insert(merged, trinketAbilityKey) end

            if #merged > 0 then
                if speakKey then
                    ForceSpeak(speakKey)
                end
                FireReminder("Recklessness + Trinket", merged)
            end
        end

        if reckAt and trinkAt and reckAt == trinkAt then
            if reckAt <= 0 then
                FireReckAndTrinketCombined()
            else
                table.insert(RC.polarityMode.scheduledTimers,
                    C_Timer.NewTimer(reckAt, FireReckAndTrinketCombined))
            end
        else
            if reckAt then
                if reckAt <= 0 then
                    ForceSpeak("recklessness")
                    FireReminder("Recklessness", {"recklessness"})
                else
                    table.insert(RC.polarityMode.scheduledTimers,
                        C_Timer.NewTimer(reckAt, function()
                            ForceSpeak("recklessness")
                            FireReminder("Recklessness", {"recklessness"})
                        end))
                end
            end
            if trinkAt then
                if trinkAt <= 0 then
                    ForceSpeak(trinketAbilityKey)
                    FireReminder("Trinket", {trinketAbilityKey})
                else
                    table.insert(RC.polarityMode.scheduledTimers,
                        C_Timer.NewTimer(trinkAt, function()
                            ForceSpeak(trinketAbilityKey)
                            FireReminder("Trinket", {trinketAbilityKey})
                        end))
                end
            end
        end

        RC.polarityMode.armedLipTime       = db.lipTime or 5
        RC.polarityMode.armedLipBuff       = LIP_BUFF_DURATION
        -- Armed, not scheduled: the LIP/dummy stage waits for a real engage
        -- and its offsets are captured now so a later settings edit cannot
        -- shift a sequence that is already mid-pull.
        RC.polarityMode.armed              = true
        StartEngageWatch()
        -- If combat has not started 30s past the expected pull, the pull was
        -- called off; disarm so a later unrelated fight cannot trigger it.
        local armTimeoutAt = (pullInSeconds or 0) + 30
        table.insert(RC.polarityMode.scheduledTimers,
            C_Timer.NewTimer(armTimeoutAt, function()
                if RC.polarityMode.armed then
                    dbg("Arm timeout - combat never started within 30s of expected pull, disarming")
                    RC.polarityMode.armed = false
                    StopEngageWatch()
                    if RC.db and RC.db.polarityMode then
                        RC.db.polarityMode.pendingPullEndAt = nil
                        RC.db.polarityMode.pendingPullSource = nil
                    end
                end
            end))

        dbg(string.format(
            RCL["Sequence scheduled: DW when %ds left | Reck T+%ds (%s) | Trinket T+%ds slot%d (%s) | LIP armed at T+%ds real-combat | MW armed at T+%ds real-combat"],
            db.deathWishLead or 5,
            db.reckDelay or 0,     tostring(db.reckEnabled),
            db.trinketDelay or 0,  db.trinketSlot or 13, tostring(db.trinketEnabled),
            db.lipTime or 5,
            (db.lipTime or 5) + LIP_BUFF_DURATION))
    end

    function RC:PolarityFireCombatAnchored(reason, contextConfirmed)
        local state = RC.polarityMode
        if not state.armed then return end
        if not self.db.polarityMode or not self.db.polarityMode.enabled then return end
        -- contextConfirmed means the caller already proved this is the right
        -- boss (encounter id, or a boss GUID off the log). Without it,
        -- player combat alone is not enough - Bloodrage or a stray pull
        -- would anchor the countdown early - so the frame stays armed.
        if not contextConfirmed then
            if reason == "PLAYER_REGEN_DISABLED" then
                if not IsSapphironEngaged() then
                    dbg("Combat-anchored fire: player combat without Sapphiron engaged ("
                        .. tostring(reason) .. ") - ignoring (Bloodrage/pre-pull), staying armed")
                    return
                end
            elseif not IsInPolarityContext() then
                dbg("Combat-anchored fire: context not ready (" .. tostring(reason) .. ") - keeping armed")
                return
            end
        end

        state.armed = false
        StopEngageWatch()

        local lipTime  = state.armedLipTime or 5
        local lipBuff  = state.armedLipBuff or 6
        local LIP_KEY  = "limitedInvulnerabilityPotion"

        -- Anchor strictly at the real engage (ENCOUNTER_START / first boss
        -- combat). The old countdown-zero re-anchor subtracted the run-in
        -- time from the offsets, so LIP fired early by however long the raid
        -- took to reach the boss - and that varies every pull. The reference
        -- WeakAura triggers on Entering Encounter; timing must match it
        -- exactly: LIP at engage + lipTime, dummy at engage + lipTime + buff.
        local lipAt   = lipTime
        local dummyAt = lipTime + lipBuff

        dbg(string.format(RCL["Combat anchor from %s - scheduling LIP at +%.1fs, Masterwork at +%.1fs"],
            tostring(reason), lipAt, dummyAt))

        RC:PolarityStartBar(lipAt, lipBuff)

        -- TTS is spoken barVoiceLeadMs early so the phrase has finished by
        -- the time the bar hits zero; the visual reminder still fires on
        -- the exact second.
        local voiceLead = VoiceLeadSec()

        table.insert(state.scheduledTimers,
            C_Timer.NewTimer(math.max(0, lipAt - voiceLead), function()
                ForceSpeak(LIP_KEY)
            end))
        table.insert(state.scheduledTimers,
            C_Timer.NewTimer(math.max(0, dummyAt - voiceLead), function()
                local dId = ResolvePolarityDummy()
                ForceSpeak(dId)
            end))

        -- With the bar on, its OnUpdate fires both reminders as each phase
        -- expires; these timers are the no-bar path only, so the reminders
        -- are never scheduled twice.
        if RC.db.polarityMode.barEnabled == false then
            table.insert(state.scheduledTimers,
                C_Timer.NewTimer(lipAt, function()
                    FireReminder("Limited Invulnerability Potion", { LIP_KEY })
                end))
            table.insert(state.scheduledTimers,
                C_Timer.NewTimer(dummyAt, function()
                    local dummyId, dummyName = ResolvePolarityDummy()
                    FireReminder(dummyName, { dummyId })
                    if RC.db and RC.db.polarityMode then
                        RC.db.polarityMode.pendingPullEndAt = nil
                        RC.db.polarityMode.pendingPullSource = nil
                    end
                end))
        end
    end

    function RC:PolarityCombatStartNoTimer()
        if not self.db.polarityMode or not self.db.polarityMode.enabled then return end
        if not IsInPolarityContext() then return end
        if RC.polarityMode.sequenceFired then return end
        if RC.polarityMode.pullTimerEnd and RC.polarityMode.pullTimerEnd > (GetTime() - 30) then
            RC.polarityMode.sequenceFired = true
            return
        end

        dbg("Combat started without pull timer - running sequence from T+0")
        RC.polarityMode.sequenceFired = true
        self:PolarityScheduleSequence(0, "combat_start_fallback")
    end

    function RC:PolarityReset()
        CancelAllTimers()
        RC.polarityMode.pullTimerEnd    = nil
        RC.polarityMode.pullTimerStart  = nil
        RC.polarityMode.pullTimerSource = nil
        RC.polarityMode.sequenceFired   = false
        RC.polarityMode.armed           = false
        if self.db and self.db.polarityMode then
            self.db.polarityMode.pendingPullEndAt = nil
            self.db.polarityMode.pendingPullSource = nil
        end
        dbg("Sequence reset")
        -- Leaving combat after Thaddius resets the sequence; the timer to
        -- Sapphiron it just started keeps running.
        local bar = RC.polarityMode.barFrame
        if not (bar and (bar.phase == "thaddw" or bar.phase == "saph") and (bar.phaseEnd or 0) > GetTime()) then
            RC:PolarityStopBar()
        end
    end

    -- ============================================================
    -- AFTER THADDIUS
    -- ============================================================
    local THADDIUS_ENCOUNTER_ID = 1120
    local NAXX_INSTANCE_ID = 533

    local function CancelThadTimers()
        local state = RC.polarityMode
        for _, t in ipairs(state.thadTimers or {}) do
            if t and t.Cancel then pcall(t.Cancel, t) end
        end
        state.thadTimers = {}
        state.thadEnd = nil
    end

    function RC:PolarityStopThaddiusTimer()
        CancelThadTimers()
        local bar = RC.polarityMode.barFrame
        if bar and (bar.phase == "thaddw" or bar.phase == "saph" or bar.phase == "done") then
            if RC.UI and RC.UI.StopAnimations then RC.UI:StopAnimations(bar) end
            bar:SetAlpha(1)
            bar.phase = nil
            bar:Hide()
        end
    end

    -- Two bar phases: "DEATH WISH" counts down to the press (deathWishLead
    -- before Sapphiron, from the settings), then "SAPHIRON" counts the
    -- lead down to the spawn. The reminder fires at the press even though
    -- nobody is in combat and no pull timer exists. Its timers are its
    -- own, so the reset on leaving the Thaddius fight does not cancel them.
    function RC:PolarityStartThaddiusTimer(seconds, source)
        local db = self.db and self.db.polarityMode
        if not (db and db.enabled) then return end
        local state = RC.polarityMode
        local now = GetTime()
        -- one start per kill: the death and ENCOUNTER_END both land here
        if source ~= "manual_test" and state.thadStartedAt and now - state.thadStartedAt < 30 then
            return
        end
        seconds = tonumber(seconds) or tonumber(db.thadTimerSec) or 24
        if seconds <= 0 then return end
        CancelThadTimers()
        state.thadStartedAt = now
        state.thadEnd = now + seconds

        local function DW()
            local d = RC.db and RC.db.polarityMode
            if not (d and d.enabled) then return end
            ForceSpeak("deathwish")
            FireReminder("Death Wish", {"deathwish"}, true)
        end
        local dwAt = seconds - (db.deathWishLead or 5)
        if dwAt > 0 then
            table.insert(state.thadTimers, C_Timer.NewTimer(dwAt, DW))
        else
            DW()
        end

        if db.barEnabled ~= false then
            local bar = self:PolarityEnsureBar()
            if bar then
                if dwAt > 0 then
                    bar.phase         = "thaddw"
                    bar.phaseEnd      = now + dwAt
                    bar.phaseDuration = dwAt
                    bar.saphEnd       = state.thadEnd
                else
                    bar.phase         = "saph"
                    bar.phaseEnd      = state.thadEnd
                    bar.phaseDuration = seconds
                end
                if RC.UI and RC.UI.StopAnimations then RC.UI:StopAnimations(bar) end
                bar:SetAlpha(1)
                bar.shownPhase = nil
                RC:PolarityApplyBarSettings()
                bar:Show()
            end
        end
        dbg(string.format("Thaddius timer (%s): Sapphiron in %ds, Death Wish with %ds left",
            tostring(source), seconds, db.deathWishLead or 5))
    end

    local function OnThaddiusDeath()
        local db = RC.db and RC.db.polarityMode
        if db and db.enabled and db.thadTimer ~= false then
            RC:PolarityStartThaddiusTimer(db.thadTimerSec, "thaddius_death")
        end
    end

    -- The death watch only listens inside Naxxramas with the timer on.
    function RC:PolarityRearmThaddiusWatch()
        local db = self.db and self.db.polarityMode
        local inNaxx = false
        if GetInstanceInfo then
            local instanceID = select(8, GetInstanceInfo())
            inNaxx = instanceID == NAXX_INSTANCE_ID
        end
        local want = inNaxx and db and db.enabled and db.thadTimer ~= false
        if not self.KillWatchRegister then return end
        if want then
            self:KillWatchRegister("polarityThaddius", { ["Thaddius"] = true }, OnThaddiusDeath)
        else
            self:KillWatchUnregister("polarityThaddius")
        end
    end
    RC.polarityMode._OnThaddiusDeath = OnThaddiusDeath
    RC.polarityMode._ThaddiusEncounterID = THADDIUS_ENCOUNTER_ID

    -- The bar's look settings (polarityMode.look); every nil field is
    -- the bar's original look.
    -- read-only: the bar's OnUpdate calls this every frame, and the look
    -- table only exists once the page has written one
    local NO_LOOK = {}
    local function BarLook()
        local d = RC.db and RC.db.polarityMode
        local l = d and d.look
        return type(l) == "table" and l or NO_LOOK
    end
    RC.polarityMode._BarLook = BarLook
    -- what nil means for the bar's animations: the old 0.45s light across
    -- it on a phase change, and the old 0.3s fade when it is done
    RC.POLARITY_FLASH = { style = "fade", duration = 0.45, easing = "easeOutQuad" }
    RC.POLARITY_HIDE = { style = "fade", duration = 0.3, easing = "easeInOutQuad" }
    local PHASE_LOOK_KEY = { thaddw = "dwColor", dummy = "dummyColor", saph = "saphColor", lip = "lipColor" }

    local function BarPhaseColor(phase)
        local own = BarLook()[PHASE_LOOK_KEY[phase] or "lipColor"]
        if type(own) == "table" then return own.r, own.g, own.b end
        if phase == "thaddw" then
            local c = RC:GetColor("text", "red") or {r=0.9,g=0.25,b=0.2}
            return c.r, c.g, c.b
        end
        if phase == "dummy" then
            local c = RC:GetColor("ui", "accentGold") or {r=0.85,g=0.65,b=0.25}
            return c.r, c.g, c.b
        end
        local c = RC:GetColor("ui", "insertionLine") or {r=0.3,g=0.8,b=1}
        return c.r, c.g, c.b
    end
    RC.polarityMode._BarPhaseColor = BarPhaseColor

    local function BarTextColor()
        return BarLook().textColor or RC:GetColor("text", "menuNormal") or {r=0.95,g=0.95,b=0.95}
    end

    local function PlayBarSound()
        local db = RC.db and RC.db.polarityMode
        if not db or not db.barSound or db.barSound == "" then return end
        if RC.db and RC.db.ttsEnabled then return end
        local file
        if RC.LSM then file = RC.LSM:Fetch("sound", db.barSound) end
        if file and file ~= "" then
            pcall(PlaySoundFile, file, "Master")
        end
    end

    -- THE BAR'S CHROME, shared by the live bar and the settings preview:
    -- icon square, divider, track, fill, spark, the phase-change light and
    -- the two texts. No position, no OnUpdate, no mover here.
    function RC:PolarityNewBarFrame(parent, name)
        local db = (self.db and self.db.polarityMode) or {}
        local bar = CreateFrame("Frame", name, parent, "BackdropTemplate")
        bar:SetSize(db.barWidth or 170, db.barHeight or 22)
        -- Flat chrome (fill + 1px black edge); only the fill texture
        -- below keeps the user's statusbar art.
        local flat = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
        bar:SetBackdrop({
            bgFile   = flat,
            edgeFile = flat,
            edgeSize = 1,
            insets   = { left = 1, right = 1, top = 1, bottom = 1 },
        })

        -- The icon sits in its own square at the left edge, split from the
        -- bar by a 1px line; the fill runs from there. Behind the fill, the
        -- empty part of the track wears the phase colour, faintly.
        local icon = bar:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        bar.icon = icon

        local divider = bar:CreateTexture(nil, "ARTWORK", nil, 1)
        divider:SetTexture(flat)
        divider:SetWidth(1)
        divider:SetPoint("TOPLEFT", icon, "TOPRIGHT", 0, 0)
        divider:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 0, 0)
        bar.divider = divider

        local track = bar:CreateTexture(nil, "BORDER")
        track:SetTexture(flat)
        bar.track = track

        local fill = bar:CreateTexture(nil, "ARTWORK")
        fill:SetTexture(self:GetTexturePath(db.barTexture))
        bar.fill = fill

        local spark = bar:CreateTexture(nil, "OVERLAY")
        spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
        spark:SetBlendMode("ADD")
        spark:SetPoint("CENTER", fill, "RIGHT", 0, 0)
        spark:Hide()
        bar.spark = spark

        -- a quick light across the bar when it changes phase: its own
        -- frame, so it plays through RC.Motion (the Animation setting)
        local flashFrame = CreateFrame("Frame", nil, bar)
        flashFrame:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
        flashFrame:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
        flashFrame:SetFrameLevel(bar:GetFrameLevel() + 3)
        flashFrame:Hide()
        local flash = flashFrame:CreateTexture(nil, "OVERLAY", nil, 2)
        flash:SetTexture(flat)
        flash:SetBlendMode("ADD")
        flash:SetAllPoints()
        bar.flash = flash
        bar.flashFrame = flashFrame

        local textHost = CreateFrame("Frame", nil, bar)
        textHost:SetAllPoints()
        textHost:SetFrameLevel(bar:GetFrameLevel() + 2)
        local label = textHost:CreateFontString(nil, "OVERLAY")
        bar.label = label

        local timeText = textHost:CreateFontString(nil, "OVERLAY")
        timeText:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
        timeText:SetJustifyH("RIGHT")
        bar.timeText = timeText
        self:PolarityStyleBar(bar)
        return bar
    end

    -- The light across the bar, at the look's brightness, played as the
    -- Animation tab's phase-change animation (an exit: it fades away).
    function RC:PolarityFlashBar(bar)
        local ff = bar and bar.flashFrame
        if not ff then return end
        local look = BarLook()
        local wc = look.flashColor or self:GetColor("text", "white") or {r=1,g=1,b=1}
        bar.flash:SetVertexColor(wc.r, wc.g, wc.b)
        RC.Motion.Stop(ff)
        ff:SetAlpha(look.flashAlpha or 0.45)
        ff:Show()
        RC.Motion.Hide(ff, RC.Motion.Normalize(look.flashAnim, RC.POLARITY_FLASH))
    end

    -- Size, textures, fonts and colours from the settings (live or preview).
    function RC:PolarityStyleBar(bar)
        local db = (self.db and self.db.polarityMode) or {}
        local look = BarLook()
        local h = db.barHeight or 22
        bar:SetSize(db.barWidth or 170, h)
        local bg = look.bgColor or self:GetColor("ui", "windowBackground") or {r=0.06,g=0.06,b=0.06,a=0.95}
        local bd = look.borderColor or self:GetColor("ui", "borderNormal") or {r=0,g=0,b=0,a=1}
        bar:SetBackdropColor(bg.r, bg.g, bg.b, bg.a or 0.95)
        bar:SetBackdropBorderColor(bd.r, bd.g, bd.b, bd.a or 1)
        bar.edgeCol = bd
        bar.divider:SetVertexColor(bd.r, bd.g, bd.b, bd.a or 1)
        bar.fill:SetTexture(self:GetTexturePath(db.barTexture))
        local fdef = { size = h - 9, outline = "OUTLINE" }
        self:ApplyFontSpec(bar.label, look.font, fdef)
        self:ApplyFontSpec(bar.timeText, look.timeFont or look.font, fdef)
        -- polarityMode.anchors.time: a spec moves the time from its place
        local anc = db.anchors
        if type(anc) == "table" or bar._pmTimeMoved then
            local spec = type(anc) == "table" and anc.time or nil
            bar.timeText:ClearAllPoints()
            bar.timeText:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
            bar._pmTimeDef = bar._pmTimeDef or {}
            RC.UI:AnchorOver(bar.timeText, spec, bar._pmTimeDef, "RIGHT", bar, "RIGHT", -5, 0,
                function(k) if k == "label" then return bar.label elseif k == "icon" then return bar.icon elseif k == "bar" then return bar end end)
            bar._pmTimeMoved = spec ~= nil
        end
        -- layer / scale / clamp, fade rules, shadow / glow (the standard;
        -- its own fill and edge stay its own)
        if self.ApplyFrameCustom then
            self:ApplyFrameCustom(bar, function() return RC.db and RC.db.polarityMode end,
                { sample = (bar:GetName() ~= "WRPolarityCountdownBar") })
        end
    end

    function RC:PolarityEnsureBar()
        local state = RC.polarityMode
        if state.barFrame then return state.barFrame end
        local db = self.db and self.db.polarityMode
        if not db then return nil end

        local bar = self:PolarityNewBarFrame(UIParent, "WRPolarityCountdownBar")
        RC.Position.Bind(bar, function() return self.db.polarityMode end, {
            point = "CENTER", pointKey = "barAnchorPoint", xKey = "barXOffset", yKey = "barYOffset",
            markKey = "barCentred", default = { x = 0, y = 80 },
        })
        RC.Position.RestoreFrame(bar)
        bar:SetFrameStrata("MEDIUM")
        bar:SetClampedToScreen(true)

        bar:Hide()
        bar:SetScript("OnUpdate", function(self2)
            -- fading out after the last phase: nothing left to count
            if self2.phase == "done" then return end
            local now = GetTime()
            local remaining = (self2.phaseEnd or now) - now
            if remaining < 0 then remaining = 0 end
            local dur = self2.phaseDuration or 1
            local frac = dur > 0 and (remaining / dur) or 0
            if frac > 1 then frac = 1 elseif frac < 0 then frac = 0 end

            local w = (self2:GetWidth() - 2 - (self2.iconW or 0))
            self2.fill:SetWidth(math.max(0.01, w * frac))
            self2.spark:SetShown(frac > 0.005 and frac < 0.995)
            -- whole seconds above ten, tenths for the last ten
            local txt = remaining >= 10 and tostring(math.ceil(remaining))
                or string.format("%.1f", remaining)
            if txt ~= self2.lastTxt then
                self2.lastTxt = txt
                self2.timeText:SetText(txt)
            end
            -- the last three seconds before the Death Wish press: the
            -- edge pulses in the phase colour and the time turns gold
            local urgent = self2.phase == "thaddw" and remaining > 0 and remaining <= 3
                and BarLook().urgentPulse ~= false
            if urgent then
                local k = 0.5 + 0.5 * math.sin(now * 10)
                local bd2, pr, pg, pb = self2.edgeCol, BarPhaseColor("thaddw")
                self2:SetBackdropBorderColor(bd2.r + (pr - bd2.r) * k, bd2.g + (pg - bd2.g) * k,
                    bd2.b + (pb - bd2.b) * k, 1)
                if not self2.urgent then
                    local gold = BarLook().urgentColor or RC:GetColor("text", "gold") or {r=1,g=0.82,b=0}
                    self2.timeText:SetTextColor(gold.r, gold.g, gold.b)
                end
                self2.urgent = true
            elseif self2.urgent then
                self2.urgent = nil
                local bd2 = self2.edgeCol
                self2:SetBackdropBorderColor(bd2.r, bd2.g, bd2.b, bd2.a or 1)
                local txtc = BarTextColor()
                self2.timeText:SetTextColor(txtc.r, txtc.g, txtc.b)
            end

            if remaining <= 0 then
                if self2.phase == "thaddw" then
                    -- Death Wish is due (its own timer fires the reminder);
                    -- the rest of the bar counts down to the spawn
                    local saphEnd = self2.saphEnd or now
                    self2.phase         = "saph"
                    self2.phaseEnd      = saphEnd
                    self2.phaseDuration = math.max(0.1, saphEnd - now)
                    RC:PolarityApplyBarPhaseVisuals("saph")
                    if saphEnd <= now then self2.phase = nil self2:Hide() end
                elseif self2.phase == "saph" then
                    PlayBarSound()
                    self2.phase = "done"
                    RC.Motion.Hide(self2, RC.Motion.Normalize(BarLook().hideAnim, RC.POLARITY_HIDE), function()
                        if self2.phase == "done" then self2.phase = nil end
                    end)
                elseif self2.phase == "lip" then
                    FireReminder("Limited Invulnerability Potion", { "limitedInvulnerabilityPotion" })
                    PlayBarSound()
                    self2.phase         = "dummy"
                    self2.phaseEnd      = (self2.combatStart or now) + (self2.lipTime or 5) + (self2.lipBuff or 6)
                    self2.phaseDuration = (self2.lipBuff or 6)
                    RC:PolarityApplyBarPhaseVisuals("dummy")
                else
                    local dummyId, dummyName = ResolvePolarityDummy()
                    FireReminder(dummyName, { dummyId })
                    if RC.db and RC.db.polarityMode then
                        RC.db.polarityMode.pendingPullEndAt = nil
                        RC.db.polarityMode.pendingPullSource = nil
                    end
                    PlayBarSound()
                    self2:Hide()
                end
            end
        end)

        state.barFrame = bar

        -- Same key/defaultPos/save shape as core's RegisterAddonFrames pass,
        -- so a bar created lazily after that pass is still movable at once.
        -- RegisterFrame is idempotent for the same frame object.
        local UM = RC.UIMover
        if UM and UM.RegisterFrame then
            UM:RegisterFrame("polarityBar", bar, "Polarity Bar",
                {point = "CENTER", relPoint = "CENTER", x = 0, y = 80})
        end

        return bar
    end

    function RC:PolarityApplyBarPhaseVisuals(phase, bar)
        bar = bar or RC.polarityMode.barFrame
        if not bar then return end
        local db = self.db and self.db.polarityMode

        local r, g, b = BarPhaseColor(phase)
        bar.fill:SetVertexColor(r, g, b, 0.95)
        bar.track:SetVertexColor(r, g, b, 0.16)
        local h = bar:GetHeight()
        bar.spark:SetSize(math.max(8, h * 0.6), h * 1.7)
        -- a light across the bar when it moves on to a new phase
        if bar:IsShown() and bar.shownPhase and bar.shownPhase ~= phase and bar.flashFrame then
            self:PolarityFlashBar(bar)
        end
        bar.shownPhase = phase

        local txt = BarTextColor()
        bar.label:SetTextColor(txt.r, txt.g, txt.b)
        bar.timeText:SetTextColor(txt.r, txt.g, txt.b)

        local showIcon = not db or db.barShowIcon ~= false
        if showIcon then
            if phase == "dummy" then
                local id = (RC.polarityMode._ResolveDummy and select(1, RC.polarityMode._ResolveDummy())) or 16023
                bar.icon:SetTexture(GetItemIcon and GetItemIcon(id) or "Interface\\Icons\\INV_Misc_Wrench_01")
            elseif phase == "thaddw" then
                -- 12328 = Death Wish.
                bar.icon:SetTexture((GetSpellTexture and GetSpellTexture(12328)) or "Interface\\Icons\\Spell_Shadow_DeathPact")
            elseif phase == "saph" then
                bar.icon:SetTexture("Interface\\Icons\\INV_Misc_Head_Dragon_Blue")
            else
                -- 3387 = Limited Invulnerability Potion.
                bar.icon:SetTexture(GetItemIcon and GetItemIcon(3387) or "Interface\\Icons\\INV_Potion_27")
            end
            bar.icon:Show()
            bar.divider:Show()
            bar.icon:SetSize(h - 2, h - 2)
            bar.iconW = h - 1
            bar.label:ClearAllPoints()
            bar.label:SetPoint("LEFT", bar.divider, "RIGHT", 5, 0)
        else
            bar.icon:Hide()
            bar.divider:Hide()
            bar.iconW = 0
            bar.label:ClearAllPoints()
            bar.label:SetPoint("LEFT", bar, "LEFT", 5, 0)
        end
        -- polarityMode.anchors.label: a spec moves the label from there
        local anc = RC.db and RC.db.polarityMode and RC.db.polarityMode.anchors
        if type(anc) == "table" and anc.label then
            bar._pmLabelDef = bar._pmLabelDef or {}
            local withIcon = bar.divider:IsShown()
            RC.UI:AnchorOver(bar.label, anc.label, bar._pmLabelDef, "LEFT", withIcon and bar.divider or bar, withIcon and "RIGHT" or "LEFT", 5, 0,
                function(k) if k == "time" then return bar.timeText elseif k == "icon" then return bar.icon elseif k == "bar" then return bar end end)
        end
        -- the fill and its track start right of the icon
        local x0 = 1 + (bar.iconW or 0)
        bar.fill:ClearAllPoints()
        bar.fill:SetPoint("TOPLEFT", bar, "TOPLEFT", x0, -1)
        bar.fill:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", x0, 1)
        bar.track:ClearAllPoints()
        bar.track:SetPoint("TOPLEFT", bar, "TOPLEFT", x0, -1)
        bar.track:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
        bar.label:SetJustifyH("LEFT")
        -- Compare against the internal phase VALUE directly - RCL must not
        -- be indexed with config/state values, only display strings.
        bar.label:SetText(phase == "dummy" and "DUMMY" or phase == "thaddw" and "DEATH WISH"
            or phase == "saph" and "SAPHIRON" or "LIP")
    end

    function RC:PolarityApplyBarSettings()
        local bar = RC.polarityMode.barFrame
        if not bar then
            bar = self:PolarityEnsureBar()
            if not bar then return end
        end
        local db = self.db and self.db.polarityMode
        if not db then return end
        self:PolarityStyleBar(bar)
        RC.Position.RestoreFrame(bar)
        RC:PolarityApplyBarPhaseVisuals(bar.phase or "lip")
    end

    function RC:PolarityStartBar(lipTime, lipBuff)
        local db = self.db and self.db.polarityMode
        if not db or not db.enabled or db.barEnabled == false then return end
        local bar = self:PolarityEnsureBar()
        if not bar then return end
        local now = GetTime()
        bar.combatStart   = now
        bar.lipTime       = lipTime or 5
        bar.lipBuff       = lipBuff or 6
        bar.phase         = "lip"
        bar.phaseEnd      = now + bar.lipTime
        bar.phaseDuration = bar.lipTime
        if RC.UI and RC.UI.StopAnimations then RC.UI:StopAnimations(bar) end
        bar:SetAlpha(1)
        bar.shownPhase = nil
        RC:PolarityApplyBarSettings()
        RC:PolarityApplyBarPhaseVisuals("lip")
        bar:Show()
        dbg(string.format(RCL["Countdown bar started: LIP in %ss, Dummy in %ss"],
            tostring(bar.lipTime), tostring(bar.lipTime + bar.lipBuff)))
    end

    function RC:PolarityStopBar()
        local bar = RC.polarityMode and RC.polarityMode.barFrame
        if bar then bar:Hide() end
    end

    function RC:PolarityTryResumeFromSaved()
        if not self.db or not self.db.polarityMode then return end
        local db = self.db.polarityMode
        if not db.enabled then return end
        if not db.pendingPullEndAt then return end

        local nowWall = GetServerTime()
        local remaining = db.pendingPullEndAt - nowWall

        -- Persisted across reloads in server time, not GetTime, which
        -- restarts at zero. Over 600s left means the stored value is junk.
        if remaining <= 0 or remaining > 600 then
            dbg("Stored pull timer stale or invalid (remaining=" .. remaining ..
                "s) - clearing")
            db.pendingPullEndAt = nil
            db.pendingPullSource = nil
            return
        end

        if not IsInPolarityContext() then
            dbg("Stored pull timer exists but Sapphiron not active - keeping persisted state, will retry when encounter changes")
            return
        end

        dbg(string.format(RCL["Resuming persisted pull timer: %ds remaining (source=%s)"],
            remaining, tostring(db.pendingPullSource)))
        self:PolarityScheduleSequence(remaining, "resume_from_saved")
    end

    -- Every DBM major-version prefix still in the wild. A pull timer is
    -- tab-separated, "Name-Realm, protocol, PT, seconds, ..." on current
    -- DBM (and BigWigs, which speaks it too); older builds led with "PT".
    -- The "PT" field is found wherever it sits, with seconds right after.
    local DBM_PREFIXES = { ["D4"] = true, ["D4C"] = true, ["D5"] = true, ["D3"] = true }

    local function HandleDBMMessage(prefix, message, channel, sender)
        if not DBM_PREFIXES[prefix] then return end
        if not RC.db.polarityMode.acceptDBM then return end
        if not message then return end

        local parts = { strsplit("\t", message) }
        local seconds
        for i = 1, #parts - 1 do
            if parts[i] == "PT" or parts[i] == "U" then
                seconds = tonumber(parts[i + 1])
                if seconds then break end
            end
        end
        if not seconds then return end

        if seconds <= 0 then
            RC:PolarityReset()
            dbg("DBM pull CANCELED by " .. tostring(sender))
            return
        end

        dbg(string.format(RCL["DBM pull timer: %ds from %s"], seconds, tostring(sender)))
        RC:PolarityScheduleSequence(seconds, "DBM")
    end

    local function HandleBigWigsMessage(prefix, message, channel, sender)
        if prefix ~= "BigWigs" then return end
        if not RC.db.polarityMode.acceptBigWigs then return end
        if not message then return end

        -- Current BigWigs: "P^Pull^seconds". Older builds: "BWPull<tab>seconds".
        local seconds
        local a, b, c = strsplit("^", message)
        if a == "P" and b == "Pull" then
            seconds = tonumber(c)
        else
            local key, rest = message:match("^([^\t]+)\t(.*)$")
            if key == "BWPull" or key == "Pull" or key == "U" then
                seconds = rest and tonumber(rest:match("^(%-?%d+%.?%d*)"))
            end
        end
        if not seconds then return end

        if seconds <= 0 then
            RC:PolarityReset()
            dbg("BigWigs pull CANCELED by " .. tostring(sender))
            return
        end

        dbg(string.format(RCL["BigWigs pull timer: %ds from %s"], seconds, tostring(sender)))
        RC:PolarityScheduleSequence(seconds, "BW")
    end

    local function HandleChatMessage(event, text, sender)
        if not RC.db.polarityMode.acceptChatFallback then return end
        if not text or text == "" then return end
        local lower = text:lower()

        if not IsInPolarityContext() then return end

        local seconds
        seconds = lower:match("pull[^%d]*(%d+)")
            or lower:match("(%d+)%s*sec[^%a]*pull")
            or lower:match("pulling[^%d]*(%d+)")
        if not seconds then return end

        -- Chat is the loosest source, so it is capped at 60s and gated on
        -- the encounter context: "pull 15" in raid chat is a pull timer,
        -- "we wiped on pull 200" is not.
        seconds = tonumber(seconds)
        if not seconds or seconds <= 0 or seconds > 60 then return end

        dbg(string.format(RCL["Chat pull timer: %ds from %s (%s)"],
            seconds, tostring(sender), event))
        RC:PolarityScheduleSequence(seconds, "chat")
    end

    local eventFrame = CreateFrame("Frame", "WRPolarityModeEvents")

    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix("D4")
        C_ChatInfo.RegisterAddonMessagePrefix("D4C")
        C_ChatInfo.RegisterAddonMessagePrefix("D5")
        C_ChatInfo.RegisterAddonMessagePrefix("D3")
        C_ChatInfo.RegisterAddonMessagePrefix("BigWigs")
    end

    eventFrame:RegisterEvent("CHAT_MSG_ADDON")
    eventFrame:RegisterEvent("CHAT_MSG_RAID_WARNING")
    eventFrame:RegisterEvent("CHAT_MSG_RAID_LEADER")
    eventFrame:RegisterEvent("CHAT_MSG_PARTY_LEADER")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("ENCOUNTER_START")
    eventFrame:RegisterEvent("ENCOUNTER_END")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    pcall(function()
        eventFrame:RegisterEvent("START_PLAYER_COUNTDOWN")
        eventFrame:RegisterEvent("CANCEL_PLAYER_COUNTDOWN")
    end)

    eventFrame:SetScript("OnEvent", function(_, event, ...)
        if not RC.db or not RC.db.polarityMode then return end
        if not RC.db.polarityMode.enabled then
            if RC.polarityMode.pullTimerEnd or #RC.polarityMode.scheduledTimers > 0 then
                RC:PolarityReset()
            end
            if RC.polarityMode.thadEnd then RC:PolarityStopThaddiusTimer() end
            if event == "PLAYER_ENTERING_WORLD" or event == "ZONE_CHANGED_NEW_AREA" then
                RC:PolarityRearmThaddiusWatch()
            end
            return
        end

        if event == "CHAT_MSG_ADDON" then
            local prefix, message, channel, sender = ...
            if channel ~= "RAID" and channel ~= "PARTY" and channel ~= "INSTANCE_CHAT" then
                return
            end
            if prefix == "BigWigs" then
                HandleBigWigsMessage(prefix, message, channel, sender)
            else
                HandleDBMMessage(prefix, message, channel, sender)
            end

        elseif event == "START_PLAYER_COUNTDOWN" then
            if not RC.db.polarityMode.acceptCountdown then return end
            local guid, duration = ...
            duration = tonumber(duration)
            if not duration or duration <= 0 or duration > 600 then return end
            local senderName = "unknown"
            if guid and GetPlayerInfoByGUID then
                local _, _, _, _, _, name = GetPlayerInfoByGUID(guid)
                if name and name ~= "" then senderName = name end
            end
            dbg(string.format(RCL["Native /countdown pull timer: %ds from %s"], duration, senderName))
            RC:PolarityScheduleSequence(duration, "countdown")

        elseif event == "CANCEL_PLAYER_COUNTDOWN" then
            if not RC.db.polarityMode.acceptCountdown then return end
            dbg("Native /countdown CANCELED")
            RC:PolarityReset()

        elseif event == "CHAT_MSG_RAID_WARNING"
            or event == "CHAT_MSG_RAID_LEADER"
            or event == "CHAT_MSG_PARTY_LEADER" then
            local text, sender = ...
            HandleChatMessage(event, text, sender)

        elseif event == "PLAYER_REGEN_DISABLED" then
            RC:PolarityCombatStartNoTimer()
            if IsInPolarityContext() then
                RC.polarityMode.sequenceFired = true
            end
            if RC.polarityMode.armed then
                RC:PolarityFireCombatAnchored("PLAYER_REGEN_DISABLED")
            end

        elseif event == "ENCOUNTER_START" then
            if RC.polarityMode.armed then
                -- Confirm Sapphiron straight from the event payload (id 1119,
                -- same trigger the reference WeakAura uses) so this anchor
                -- can never lose a handler-order race on activeEncounterName.
                local encId, encName = ...
                -- 1119 is Sapphiron's encounter journal id.
                local isSapphiron = (encId == 1119)
                    or (type(encName) == "string"
                        and encName:lower():find("sapphiron", 1, true) ~= nil)
                RC:PolarityFireCombatAnchored("ENCOUNTER_START", isSapphiron)
            end

        elseif event == "PLAYER_REGEN_ENABLED" or event == "ENCOUNTER_END" then
            if event == "ENCOUNTER_END" then
                RC.polarityMode.inSapphironZone = false
                local encId, encName, _, _, success = ...
                if success == 1 and (encId == THADDIUS_ENCOUNTER_ID
                    or (type(encName) == "string" and encName:lower():find("thaddius", 1, true))) then
                    OnThaddiusDeath()
                end
            end
            if RC.polarityMode.sequenceFired
               and RC.polarityMode.pullTimerSource ~= "manual_test" then
                RC:PolarityReset()
            end

        elseif event == "PLAYER_ENTERING_WORLD" then
            RC.polarityMode.inSapphironZone = false
            RC:PolarityRearmThaddiusWatch()
            C_Timer.After(1.0, function()
                -- Subzone matched on substring so any locale that keeps the
                -- proper noun still resolves; the zone flag is only a
                -- fallback context signal, never an engage anchor.
                local z = (GetSubZoneText and GetSubZoneText() or ""):lower()
                if z:find("frostwyrm", 1, true) or z:find("sapphiron", 1, true) then
                    RC.polarityMode.inSapphironZone = true
                    dbg("Entered Frostwyrm Lair after load - inSapphironZone=true")
                end
                RC:PolarityTryResumeFromSaved()
            end)

        elseif event == "ZONE_CHANGED_NEW_AREA" then
            local z = (GetSubZoneText and GetSubZoneText() or ""):lower()
            if z:find("frostwyrm", 1, true) or z:find("sapphiron", 1, true) then
                RC.polarityMode.inSapphironZone = true
                dbg("Entered Frostwyrm Lair - inSapphironZone=true")
            end
            RC:PolarityRearmThaddiusWatch()
            RC:PolarityTryResumeFromSaved()
        end
    end)

    RC:InitializePolarityModeDB()
    -- The countdown bar is created lazily (PolarityStartBar /
    -- PolarityApplyBarSettings call PolarityEnsureBar), not at init;
    -- everything that touches barFrame directly already nil-checks it.
    C_Timer.After(2.0, function()
        RC:PolarityRearmThaddiusWatch()
        RC:PolarityTryResumeFromSaved()
    end)
    RC:DebugPrint("PolarityMode module loaded", "polarity")
end

C_Timer.After(0.5, InitializePolarityMode)
