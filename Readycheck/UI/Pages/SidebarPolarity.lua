------------------------------------------------------------------------
-- Readycheck - Polarity
-- Sidebar card builder for "Polarity Mode": a Sapphiron DPS-opener sequence
-- (Death Wish, Recklessness, trinket, LIP, Masterwork Target Dummy) driven
-- off pull-timer sources (native /countdown, DBM, BigWigs, /pull chat).
-- Settings live under RC.db.polarityMode. Bar-related fields (icon, texture,
-- width/height, voice lead) must be re-applied via RC:PolarityApplyBarSettings
-- for the running countdown bar to pick up the change.
------------------------------------------------------------------------
local function InitializeSidebarPolarity()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializeSidebarPolarity); return end
    if not RC.UI then C_Timer.After(0.2, InitializeSidebarPolarity); return end
    if not RC.db then C_Timer.After(0.2, InitializeSidebarPolarity); return end

    local function NormalTextRGB()
        local c = RC:GetColor("text", "menuNormal") or {r=0.9,g=0.9,b=0.9}
        return c.r, c.g, c.b
    end
    local function DimTextRGB()
        local c = RC:GetColor("text", "menuDisabled") or {r=0.6,g=0.6,b=0.6}
        return c.r, c.g, c.b
    end

    -- Module-level, not per-card: shared across every raid/encounter that
    -- uses this builder, so switching tabs on one instance affects all.
    local activeTab = "sources"

    local function BuildSliderRow(self, card, cardY, labelText, dbKey, minV, maxV, step, suffix, hintText)
        local db = RC.db.polarityMode
        local function Save() RC:SaveConfigurationToProfile() end

        local lbl = self:CreateFontString(card, "OVERLAY", nil, 11)
        lbl:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
        lbl:SetText(labelText)
        lbl:SetTextColor(NormalTextRGB())

        local slider = self.UI:CreateSettingSlider(card, minV, maxV, db[dbKey] or minV, step, 170, cardY + 5, (db[dbKey] or minV) .. suffix, function(s, value)
            value = math.floor(value / step + 0.5) * step
            db[dbKey] = value
            s.Text:SetText(value .. suffix)
        end)
        slider:SetScript("OnMouseUp", function() Save() end)
        cardY = cardY - 38

        if hintText then
            local hint = self:CreateFontString(card, "OVERLAY", nil, 10)
            hint:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cardY)
            hint:SetWidth(card:GetWidth() - 40)
            hint:SetJustifyH("LEFT")
            hint:SetText(hintText)
            hint:SetTextColor(DimTextRGB())
            cardY = cardY - hint:GetStringHeight() - 10
        end

        return cardY
    end

    local K = RC._disp
    local PolarityPreviewSpec
    local function Look() return K.Look(RC.db.polarityMode, "look") end
    local function ThemeOf(cat, key) return RC:GetColor(cat, key) end
    local function PhaseRGB(phase)
        local f = RC.polarityMode and RC.polarityMode._BarPhaseColor
        if f then return f(phase) end
        local c = RC:GetColor("ui", "insertionLine")
        return c.r, c.g, c.b
    end

    -- COUNTDOWN BAR PREVIEW: the real bar (RC:PolarityNewBarFrame +
    -- PolarityStyleBar + PolarityApplyBarPhaseVisuals), frozen part way
    -- down, one mode per countdown. Replay plays the phase-change light,
    -- then the exit.
    local PHASE_TIME = { lip = "3.2", dummy = "4.6", thaddw = "2.4", saph = "11" }
    local PB_W, PB_H = 300, 70
    local function PolBuild(canvas, P)
        if not RC.PolarityNewBarFrame then return end
        P.store.bar = RC:PolarityNewBarFrame(canvas)
        P.store.token = 0
    end
    local function PolUpdate(canvas, P)
        local bar = P.store.bar
        if not bar then return end
        local phase = P.mode or "lip"
        RC.Motion.Stop(bar)
        RC:PolarityStyleBar(bar)
        bar.shownPhase = nil
        RC:PolarityApplyBarPhaseVisuals(phase, bar)
        local w = bar:GetWidth() - 2 - (bar.iconW or 0)
        bar.fill:SetWidth(math.max(0.01, w * 0.6))
        bar.spark:Show()
        bar.timeText:SetText(PHASE_TIME[phase] or "3.2")
        if phase == "thaddw" and Look().urgentPulse ~= false then
            local g = Look().urgentColor or RC:GetColor("text", "gold")
            bar.timeText:SetTextColor(g.r, g.g, g.b)
        end
        -- the bar at its real size; the canvas is its box (the strip shows
        -- it as big as it is in game)
        bar:SetScale(1)
        P.Resize((bar:GetWidth() or 260) + 16, (bar:GetHeight() or 24) + 16)
        bar:ClearAllPoints()
        bar:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        bar:Show()
    end
    local function PolReplay(canvas, P)
        local bar = P.store.bar
        if not bar then return end
        local M = RC.Motion
        P.store.token = P.store.token + 1
        local t = P.store.token
        M.Stop(bar)
        bar:Show()
        RC:PolarityFlashBar(bar)
        C_Timer.After(1.4, function()
            if t ~= P.store.token or not bar:IsVisible() then return end
            local out = M.Normalize(Look().hideAnim, RC.POLARITY_HIDE)
            M.Hide(bar, out)
            C_Timer.After(M.Duration(out.duration) + M.Duration(out.delay or 0) + 0.4, function()
                if t ~= P.store.token then return end
                M.Stop(bar)
                if canvas:IsVisible() then bar:Show() end
            end)
        end)
    end
    PolarityPreviewSpec = function()
        return {
            key = "polarity.bar", title = RCL["Polarity countdown bar"],
            width = PB_W, height = PB_H,
            build = PolBuild, update = PolUpdate, replay = PolReplay,
            modes = { { id = "lip", label = RCL["LIP"] }, { id = "dummy", label = RCL["Dummy"] },
                      { id = "thaddw", label = RCL["Death Wish"] }, { id = "saph", label = RCL["Sapphiron"] } },
        }
    end

    function RC:BuildSapphironPolarityCard(parent, yPos, frame, raidName, encounterName)
        if not self.db.polarityMode then self.db.polarityMode = {} end
        if self.InitializePolarityModeDB then self:InitializePolarityModeDB() end
        local db = self.db.polarityMode

        local function Save() RC:SaveConfigurationToProfile() end

        local function RefreshPage()
            if not (raidName and encounterName and RC.ShowInlineAbilityConfig) then
                return
            end

            local compatFrame = frame
            if not (compatFrame and compatFrame.scrollChild) then
                if RC.sidebarConfigFrame then
                    compatFrame = RC.sidebarConfigFrame.compatFrame
                end
            end
            if not (compatFrame and compatFrame.scrollChild) then
                return
            end

            RC:ShowInlineAbilityConfig(compatFrame, raidName, encounterName, "boss", nil, true)
        end

        local card = self:CreateSettingsCard(parent, yPos, RCL["Polarity mode"])
        local cy = -32

        local desc = self:CreateFontString(card, "OVERLAY", nil, 10)
        desc:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        desc:SetWidth(card:GetWidth() - 30)
        desc:SetJustifyH("LEFT")
        desc:SetText(
            RCL["Reads pull timers (native /countdown, DBM, BigWigs, or /pull chat) "] ..
            RCL["and fires a DPS opener sequence for Sapphiron: Death Wish pre-pull, "] ..
            RCL["Recklessness and trinket at combat start, Limited Invulnerability "] ..
            RCL["Potion to absorb the cleave at T+6s, then Masterwork Target Dummy "] ..
            RCL["as LIP drops (6s later) to soak the next cleave. "] ..
            RCL["When Polarity is on, the normal per-boss reminders for these 5 "] ..
            RCL["abilities are suppressed on Sapphiron so you don't get duplicates."]
        )
        desc:SetTextColor(NormalTextRGB())
        cy = cy - desc:GetStringHeight() - 12

        local enableCb = self.UI:CreateSettingCheckbox(card, cy, "Enable Polarity Mode", db.enabled, function(cb)
            db.enabled = cb:GetChecked()
            RC:ForceCheckboxUpdate(cb, db.enabled)
            Save()
            RefreshPage()
        end)
        cy = cy - 28

        if not db.enabled then
            local offHint = self:CreateFontString(card, "OVERLAY", nil, 10)
            offHint:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
            offHint:SetWidth(card:GetWidth() - 30)
            offHint:SetJustifyH("LEFT")
            offHint:SetText(RCL["Turn on Polarity Mode above to configure pull timer sources, timing offsets, and per-cooldown options."])
            offHint:SetTextColor(DimTextRGB())
            cy = cy - offHint:GetStringHeight() - 12

            card:SetContentHeight(math.abs(cy))
            return yPos - card:GetHeight() - 15
        end

        local TAB_DEFS = {
            { key = "sources",   label = RCL["Sources"]   },
            { key = "cooldowns", label = RCL["Cooldowns"] },
            { key = "bar",       label = RCL["Bar"]       },
            { key = "look",      label = RCL["Look"]      },
            { key = "text",      label = RCL["Text"]      },
            { key = "animation", label = RCL["Animation"] },
        }
        local _validTab = false
        for _, t in ipairs(TAB_DEFS) do
            if t.key == activeTab then _validTab = true end
        end
        if not _validTab then activeTab = "sources" end

        local _tabH = 26
        local _tabX = 15
        for _, t in ipairs(TAB_DEFS) do
            local tabBtn = self.UI:CreateTabButton(card, t.label, _tabH, 12, 64)
            tabBtn:SetPoint("TOPLEFT", card, "TOPLEFT", _tabX, cy)
            tabBtn:SetSelected(t.key == activeTab)
            local key = t.key
            tabBtn:SetScript("OnClick", function()
                if activeTab ~= key then
                    activeTab = key
                    RefreshPage()
                end
            end)
            _tabX = _tabX + tabBtn:GetWidth() + 4
        end
        cy = cy - _tabH - 14

        -- the countdown bar's tabs show it in the preview pane
        local PV
        if activeTab == "bar" or activeTab == "look" or activeTab == "text" or activeTab == "animation" then
            PV = self.UI:DeclarePreview(PolarityPreviewSpec())
        end

        if activeTab == "sources" then

        local srcHdr = self:CreateFontString(card, "OVERLAY", nil, 11)
        srcHdr:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        srcHdr:SetText(RCL["Pull Timer Sources"])
        srcHdr:SetTextColor(NormalTextRGB())
        cy = cy - 20

        local cbCd = self.UI:CreateCheckbox(card, RCL["Native /countdown (most reliable)"], db.acceptCountdown)
        cbCd:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cy)
        cbCd:SetScript("OnClick", function(cb) db.acceptCountdown = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.acceptCountdown); Save() end)
        cy = cy - 22

        local cbDbm = self.UI:CreateCheckbox(card, RCL["DBM (Deadly Boss Mods)"], db.acceptDBM)
        cbDbm:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cy)
        cbDbm:SetScript("OnClick", function(cb) db.acceptDBM = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.acceptDBM); Save() end)
        cy = cy - 22

        local cbBw = self.UI:CreateCheckbox(card, RCL["BigWigs"], db.acceptBigWigs)
        cbBw:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cy)
        cbBw:SetScript("OnClick", function(cb) db.acceptBigWigs = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.acceptBigWigs); Save() end)
        cy = cy - 22

        local cbChat = self.UI:CreateCheckbox(card, RCL["Chat fallback (/pull N in raid chat)"], db.acceptChatFallback)
        cbChat:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cy)
        cbChat:SetScript("OnClick", function(cb) db.acceptChatFallback = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.acceptChatFallback); Save() end)
        cy = cy - 28

        local srcNote = self:CreateFontString(card, "OVERLAY", nil, 10)
        srcNote:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cy)
        srcNote:SetWidth(card:GetWidth() - 40)
        srcNote:SetJustifyH("LEFT")
        srcNote:SetText(RCL["Native /countdown fires for any /countdown N or the built-in pull timer UI - most reliable. Others are fallbacks when no one in the raid uses /countdown."])
        srcNote:SetTextColor(DimTextRGB())
        cy = cy - srcNote:GetStringHeight() - 12

        local thadHdr = self:CreateFontString(card, "OVERLAY", nil, 11)
        thadHdr:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        thadHdr:SetText(RCL["After Thaddius"])
        thadHdr:SetTextColor(NormalTextRGB())
        cy = cy - 20

        local cbThad = self.UI:CreateCheckbox(card, RCL["Start a timer when Thaddius dies"], db.thadTimer ~= false)
        cbThad:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cy)
        cbThad:SetScript("OnClick", function(cb)
            db.thadTimer = cb:GetChecked()
            RC:ForceCheckboxUpdate(cb, db.thadTimer)
            Save()
            if RC.PolarityRearmThaddiusWatch then RC:PolarityRearmThaddiusWatch() end
            if not db.thadTimer and RC.PolarityStopThaddiusTimer then RC:PolarityStopThaddiusTimer() end
        end)
        cy = cy - 28

        cy = BuildSliderRow(self, card, cy,
            "Timer length:", "thadTimerSec", 10, 60, 1, "s",
            "Counts down to Sapphiron on the polarity bar. Death Wish pops when the Death Wish lead " ..
            "(Cooldowns tab) is left on it. Test it with /rc polarity thad.")

        elseif activeTab == "cooldowns" then

        local timHdr = self:CreateFontString(card, "OVERLAY", nil, 11)
        timHdr:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        timHdr:SetText(RCL["Timing"])
        timHdr:SetTextColor(NormalTextRGB())
        cy = cy - 22

        cy = BuildSliderRow(self, card, cy,
            "Death Wish lead:", "deathWishLead", 0, 30, 1, "s left on timer",
            "Fire the Death Wish reminder when this many seconds are left on the pull timer. " ..
            "Default 5 (reminder pops with 5s left, you press DW, buff is active when combat starts). " ..
            "Bump higher if your latency or reaction time needs more lead.")

        local reckHdr = self:CreateFontString(card, "OVERLAY", nil, 11)
        reckHdr:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        reckHdr:SetText(RCL["Recklessness"])
        reckHdr:SetTextColor(NormalTextRGB())
        cy = cy - 20

        local reckCb = self.UI:CreateCheckbox(card, RCL["Include Recklessness reminder"], db.reckEnabled)
        reckCb:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cy)
        reckCb:SetScript("OnClick", function(cb)
            db.reckEnabled = cb:GetChecked()
            RC:ForceCheckboxUpdate(cb, db.reckEnabled)
            Save()
        end)
        cy = cy - 22

        local reckHint = self:CreateFontString(card, "OVERLAY", nil, 10)
        reckHint:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cy)
        reckHint:SetWidth(card:GetWidth() - 40)
        reckHint:SetJustifyH("LEFT")
        reckHint:SetText(RCL["Some guilds don't use Reck on Sapphiron. Turn off if yours doesn't."])
        reckHint:SetTextColor(DimTextRGB())
        cy = cy - reckHint:GetStringHeight() - 8

        cy = BuildSliderRow(self, card, cy,
            "Reck delay:", "reckDelay", 0, 10, 1, "s after pull",
            "Wait this long after combat starts before firing the Reck reminder. Usually 0.")

        local trnkHdr = self:CreateFontString(card, "OVERLAY", nil, 11)
        trnkHdr:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        trnkHdr:SetText(RCL["Trinket"])
        trnkHdr:SetTextColor(NormalTextRGB())
        cy = cy - 20

        local trnkCb = self.UI:CreateCheckbox(card, RCL["Include trinket reminder"], db.trinketEnabled)
        trnkCb:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cy)
        trnkCb:SetScript("OnClick", function(cb)
            db.trinketEnabled = cb:GetChecked()
            RC:ForceCheckboxUpdate(cb, db.trinketEnabled)
            Save()
        end)
        cy = cy - 22

        local slotLbl = self:CreateFontString(card, "OVERLAY", nil, 11)
        slotLbl:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cy)
        slotLbl:SetText(RCL["Which trinket slot:"])
        slotLbl:SetTextColor(NormalTextRGB())

        local slotOpts = {
            { value = 13, label = RCL["Slot 13 (top trinket)"] },
            { value = 14, label = RCL["Slot 14 (bottom trinket)"] },
        }
        local function getSlotLabel(v)
            for _, o in ipairs(slotOpts) do
                if o.value == v then return o.label end
            end
            return "Slot 13 (top trinket)"
        end
        local slotDD = self.UI:CreateScrollableDropdown(card, 200, getSlotLabel(db.trinketSlot or 13), 8)
        slotDD:SetPoint("TOPLEFT", card, "TOPLEFT", 170, cy + 5)
        do
            local slotItems = {}
            for _, opt in ipairs(slotOpts) do
                table.insert(slotItems, { text = opt.label, value = opt.value })
            end
            slotDD:SetItems(slotItems, function(value)
                db.trinketSlot = value
                Save()
                RefreshPage()
            end)
            slotDD:SetSelectedValue(db.trinketSlot or 13, getSlotLabel(db.trinketSlot or 13))
        end
        cy = cy - 38

        local slotHint = self:CreateFontString(card, "OVERLAY", nil, 10)
        slotHint:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cy)
        slotHint:SetWidth(card:GetWidth() - 40)
        slotHint:SetJustifyH("LEFT")
        slotHint:SetText(RCL["Which equipped trinket slot has your on-use. Most people use slot 13 (top) but some keep on-use trinkets in slot 14."])
        slotHint:SetTextColor(DimTextRGB())
        cy = cy - slotHint:GetStringHeight() - 8

        cy = BuildSliderRow(self, card, cy,
            "Trinket delay:", "trinketDelay", 0, 10, 1, "s after pull",
            "Wait this long after combat starts before firing the trinket reminder. Usually 0.")

        local lipHdr = self:CreateFontString(card, "OVERLAY", nil, 11)
        lipHdr:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        lipHdr:SetText(RCL["Limited Invulnerability Potion (LIP)"])
        lipHdr:SetTextColor(NormalTextRGB())
        cy = cy - 20

        cy = BuildSliderRow(self, card, cy,
            "LIP time:", "lipTime", 4, 15, 1, "s after engage",
            "When to fire the LIP reminder, counted from the moment the encounter actually starts - " ..
            "the same anchor encounter WeakAuras use. LIP gives 6s of physical immunity - DPS standing in front " ..
            "pop it to absorb Sapphiron's cleave. Masterwork Target Dummy fires automatically 6s later " ..
            "to soak the next cleave as LIP drops (LIP 5 = dummy at 11).")

        elseif activeTab == "bar" then

        local function Apply() if RC.polarityMode and RC.polarityMode.barFrame then RC:PolarityApplyBarSettings() end end
        local barHdr = self:CreateFontString(card, "OVERLAY", nil, 11)
        barHdr:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        barHdr:SetText(RCL["Countdown Bar"])
        barHdr:SetTextColor(NormalTextRGB())
        cy = cy - 22

        cy = K.Check(card, cy, RCL["Show countdown bar"], function() return db.barEnabled ~= false end,
            function(v) db.barEnabled = v end)
        cy = K.Check(card, cy, RCL["Show ability icon on bar"], function() return db.barShowIcon ~= false end,
            function(v) db.barShowIcon = v Apply() end)
        cy = K.Desc(card, cy, RCL["A compact bar that counts down to the LIP press, then flips and counts down to the dummy. "] ..
            RCL["Drag it to reposition with /rc move. Preview it with /rc polarity test."])

        -- Reads the global TTS toggle (RC.db.ttsEnabled), not polarityMode,
        -- to decide whether the bar-sound picker or the TTS note is shown.
        local ttsOn = (RC.db and RC.db.ttsEnabled) and true or false
        if not ttsOn then
            local sndLbl = self:CreateFontString(card, "OVERLAY", nil, 11)
            sndLbl:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
            sndLbl:SetText(RCL["Bar sound"])
            sndLbl:SetTextColor(NormalTextRGB())
            cy = cy - 18
            local sp = self.UI:CreateSoundPicker(card, { selected = (db.barSound ~= "" and db.barSound) or nil, width = 200,
                onPick = function(key) db.barSound = key or "" Save() end })
            sp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
            local none = self.UI:CreateStyledButton(card, RCL["No sound"], 80, 22)
            none:SetPoint("LEFT", sp, "RIGHT", 6, 0)
            none:SetScript("OnClick", function()
                db.barSound = ""
                Save()
                RC.UI:NotifySettingChanged("reset")
                RefreshPage()
            end)
            cy = cy - 30
            cy = K.Desc(card, cy, RCL["Text-to-speech is off, so this sound is the LIP/dummy cue - it plays at each "] ..
                RCL["countdown's end. Turn TTS on to have the cue spoken instead (this picker then hides)."])
        else
            cy = K.Desc(card, cy, RCL["Cue: the LIP/dummy cue is spoken by reminder text-to-speech (on). To use a bar "] ..
                RCL["sound for the cue instead, turn off TTS - the sound picker appears here when it's off."])
        end

        cy = K.Slider(card, cy, RCL["Voice lead"], 0, 2000, db.barVoiceLeadMs or 1000, 50,
            function(v) return v .. RCL[" ms"] end,
            function(v) db.barVoiceLeadMs = v Save() end)
        cy = K.Desc(card, cy + 6, RCL["Speaks the LIP/dummy cue this long before the bar reaches 0, to cancel out your "] ..
            RCL["text-to-speech start-up delay. Raise it if the spoken cue still lands late; lower it if it "] ..
            RCL["comes too early. The bar's countdown and popup are unaffected - only the voice moves."])
        cy = K.Check(card, cy, RCL["Pulse the edge before Death Wish"], function() return Look().urgentPulse ~= false end,
            function(v) Look().urgentPulse = v end,
            RCL["In the last three seconds before the Death Wish press after Thaddius, the edge pulses in the phase colour and the time turns gold."])

        elseif activeTab == "look" then
        local function Apply() if RC.polarityMode and RC.polarityMode.barFrame then RC:PolarityApplyBarSettings() end end
        cy = K.Slider(card, cy, RCL["Bar width"], 100, 400, db.barWidth or 170, 1,
            function(v) return v .. RCL[" px"] end, function(v) db.barWidth = v Save() Apply() end)
        cy = K.Slider(card, cy, RCL["Bar height"], 14, 40, db.barHeight or 22, 1,
            function(v) return v .. RCL[" px"] end, function(v) db.barHeight = v Save() Apply() end)
        local tp = self.UI:CreateTexturePicker(card, { label = RCL["Bar texture"], width = 260,
            get = function() return db.barTexture end,
            set = function(name) db.barTexture = name Save() Apply() end,
            color = function() return PhaseRGB("lip") end })
        tp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        cy = cy - tp:GetHeight() - 12
        cy = K.LookColor(card, cy, RCL["LIP countdown"], Look, "lipColor", function() return ThemeOf("ui", "insertionLine") end, Apply)
        cy = K.LookColor(card, cy, RCL["Dummy countdown"], Look, "dummyColor", function() return ThemeOf("ui", "accentGold") end, Apply)
        cy = K.LookColor(card, cy, RCL["Death Wish countdown"], Look, "dwColor", function() return ThemeOf("text", "red") end, Apply)
        cy = K.LookColor(card, cy, RCL["Sapphiron countdown"], Look, "saphColor", function() return ThemeOf("ui", "insertionLine") end, Apply)
        cy = K.LookColor(card, cy, RCL["Background"], Look, "bgColor", function() return ThemeOf("ui", "windowBackground") end, Apply, true)
        cy = K.LookColor(card, cy, RCL["Border"], Look, "borderColor", function() return ThemeOf("ui", "borderNormal") end, Apply, true)
        cy = K.Desc(card, cy, RCL["Each countdown fills in its own colour; the preview's buttons show each one."])

        elseif activeTab == "text" then
        local function Apply() if RC.polarityMode and RC.polarityMode.barFrame then RC:PolarityApplyBarSettings() end end
        local fdef = { size = (db.barHeight or 22) - 9, outline = "OUTLINE" }
        cy = K.Font(card, cy, RCL["Label"], function() return Look().font end,
            function(s) Look().font = s Apply() end, fdef, "LIP   DUMMY   DEATH WISH", 6, 30)
        cy = K.Font(card, cy, RCL["Time"], function() return Look().timeFont end,
            function(s) Look().timeFont = s Apply() end, fdef, "12   3.4", 6, 30)
        cy = K.Desc(card, cy + 4, RCL["The time uses the label's font until it has its own. Sizes follow the bar height until you set one."])
        cy = K.LookColor(card, cy, RCL["Text colour"], Look, "textColor", function() return ThemeOf("text", "menuNormal") end, Apply)
        cy = K.LookColor(card, cy, RCL["Urgent time colour"], Look, "urgentColor", function() return ThemeOf("text", "gold") end, Apply)
        -- where the label and the time sit (polarityMode.anchors.*)
        do
            local cw = card:GetWidth() or 0
            local W = (cw > 240) and math.min(460, cw - 28) or 420
            local function Root() RC.db.polarityMode = RC.db.polarityMode or {} return RC.db.polarityMode end
            local function After() RC:SaveConfigurationToProfile() Apply() end
            local BAR = { value = "bar", text = RCL["The bar"] }
            local ICON = { value = "icon", text = RCL["The icon"] }
            local ag, as = self.UI:CustomAccess(Root, "anchors", "label", After)
            local g = self.UI:CreateTextElement(card, { label = RCL["Label position"], key = "label", width = W,
                anchorGet = ag, anchorSet = as, targets = { BAR, ICON, { value = "time", text = RCL["The time"] } },
                defaultTargetLabel = RCL["Left, after the icon"],
                anchorDefaults = function() return { point = "LEFT", relPoint = "LEFT", x = 5, y = 0 } end })
            g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy - 6)
            cy = cy - 6 - g:GetHeight() - 10
            ag, as = self.UI:CustomAccess(Root, "anchors", "time", After)
            g = self.UI:CreateTextElement(card, { label = RCL["Time position"], key = "time", width = W,
                anchorGet = ag, anchorSet = as, targets = { BAR, ICON, { value = "label", text = RCL["The label"] } },
                defaultTargetLabel = RCL["Right end of the bar"],
                anchorDefaults = function() return { point = "RIGHT", relPoint = "RIGHT", x = -5, y = 0 } end })
            g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
            cy = cy - g:GetHeight() - 6
        end

        elseif activeTab == "animation" then
        cy = K.Anim(card, cy, RCL["When it changes phase"], "out",
            function() return Look().flashAnim end, function(s) Look().flashAnim = s end,
            RC.POLARITY_FLASH, { "none", "fade", "flash", "pulse" }, PV)
        cy = K.Slider(card, cy, RCL["Light brightness"], 0.1, 1, Look().flashAlpha or 0.45, 0.05,
            function(v) return math.floor(v * 100 + 0.5) .. "%" end,
            function(v) Look().flashAlpha = v Save() end, 100)
        cy = K.LookColor(card, cy, RCL["Light colour"], Look, "flashColor", function() return ThemeOf("text", "white") end, nil)
        cy = K.Anim(card, cy - 6, RCL["When it is done"], "out",
            function() return Look().hideAnim end, function(s) Look().hideAnim = s end,
            RC.POLARITY_HIDE, nil, PV)
        cy = K.Desc(card, cy, RCL["A light runs across the bar when one countdown hands over to the next; the bar goes once Sapphiron spawns. Appearance > Motion can turn every animation off or speed them all up."])

        end

        local dbgHint = self:CreateFontString(card, "OVERLAY", nil, 10)
        dbgHint:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        dbgHint:SetWidth(card:GetWidth() - 30)
        dbgHint:SetJustifyH("LEFT")
        dbgHint:SetText(RCL["Debug: /rc debugcat polarity    |    Test: /rc polarity test [seconds] (Thaddius, then the pull)    |    pull [seconds]    |    thad [seconds]"])
        dbgHint:SetTextColor(DimTextRGB())
        cy = cy - dbgHint:GetStringHeight() - 8

        card:SetContentHeight(math.abs(cy))
        local nextY = yPos - card:GetHeight() - 15
        -- the countdown bar's layer / fade / shadow (the customization standard)
        local function PolRoot() return RC.db.polarityMode end
        local function PolLive() if RC.PolarityApplyBarSettings then RC:PolarityApplyBarSettings() end end
        if activeTab == "bar" then
            nextY = self.UI:FrameVisibilityCard(parent, nextY, PolRoot, PolLive, { title = RCL["Bar fade and opacity"] })
            nextY = self.UI:FrameLayerCard(parent, nextY, PolRoot, PolLive, { title = RCL["Bar layer and scale"] })
        elseif activeTab == "look" then
            nextY = self.UI:FrameChromeCard(parent, nextY, PolRoot, PolLive, { title = RCL["Bar shadow and glow"], fields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })
        end
        return nextY
    end

    RC:DebugPrint("SidebarPolarity card builder loaded", "polarity")
end

C_Timer.After(0.6, InitializeSidebarPolarity)
