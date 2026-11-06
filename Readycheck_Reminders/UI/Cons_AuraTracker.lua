------------------------------------------------------------------------
-- Readycheck - Aura Tracker Settings
-- Two sidebar pages built from one skeleton: the Raid Buff Tracker
-- (db.raidBuffTracker) and the Boss Debuff Tracker (db.bossDebuffTracker).
-- Every change writes the db table, saves, and calls the tracker's
-- Refresh so the on-screen frame follows immediately; changes that alter
-- the card height re-render the page with the scroll kept.
-- Tabless (the search aliases scroll to card titles): the behaviour cards
-- first, then Appearance (the look), Text, Animation and Position, the
-- standard tab order as cards. The preview pane shows a sample of the
-- tracker built by its own code (tracker:NewSample).
--
-- The pages are listed by the main addon: the sidebar entries are in
-- UI\Sidebar\Sidebar_Base.lua (under Extras, lodAddon = this addon),
-- the minimap menu rows in UI\MinimapButton.lua, and the per-card search
-- words in UI\Raids\Raids_Base.lua (RC.SUBPANEL_ALIASES) - a card
-- renamed here needs its scrollTo there renamed with it. RC._sbc (the
-- "Show in" mode grid) is published by the main addon's
-- UI\Consumables\Cons_Base.lua at load; it is guarded below anyway.
------------------------------------------------------------------------
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_max, math_min = math.floor, math.max, math.min
local string_format = string.format
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbc = RC._sbc or {}
local _sbc = RC._sbc

    local function TextColor(fs, group, key)
        local c = RC:GetColor(group, key)
        fs:SetTextColor(c.r, c.g, c.b, c.a or 1)
    end

    local function SecondsLabel(v)
        v = math_floor(v + 0.5)
        if v <= 0 then return RCL["Off"] end
        if v >= 60 and v % 60 == 0 then
            local m = v / 60
            return m .. RCL[" min"]
        elseif v >= 60 then
            return string_format("%d:%02d", math_floor(v / 60), v % 60)
        end
        return v .. "s"
    end

    local K = RC._rpk
    local NONE = { style = "none" }
    local ANIM_IN  = { style = "none", duration = 0.3 }
    local ANIM_OUT = { style = "none", duration = 0.3 }
    local ANIM_URGENT = { style = "none", duration = 0.6 }
    local ROW_FONT_DEFAULTS = { size = 11, outline = "OUTLINE", shadow = false }
    local STACK_FONT_DEFAULTS = { size = 9, outline = "THICKOUTLINE", shadow = false }
    local PV_W, PV_H = 186, 100   -- update sizes the canvas to the tracker

    -- The preview: a sample of the tracker itself (tracker:NewSample) on the
    -- canvas, fed the same sample rows Edit Mode shows - every colour state,
    -- or every aura up - laid out and painted by the tracker's own code.
    local function PreviewSpec(key, title)
        local function Tracker() return RC.GetAuraTracker and RC:GetAuraTracker(key) end
        return {
            key = "auratracker." .. key, title = title, width = PV_W, height = PV_H,
            modes = { { id = "mixed", label = RCL["Every state"] }, { id = "allup", label = RCL["All up"] } },
            build = function(canvas, P)
                local holder = CreateFrame("Frame", nil, canvas)
                holder:SetPoint("CENTER", canvas, "CENTER", 0, 0)
                P.store.holder = holder
                local T = Tracker()
                if T and T.NewSample then
                    P.store.sample = T:NewSample(holder)
                    P.store.sample.frame:SetPoint("CENTER", holder, "CENTER", 0, 0)
                end
            end,
            update = function(canvas, P)
                local S = P.store.sample
                if not S then return end
                S.sampleMode = P.mode
                S:ApplyAppearance()
                S:Render(GetTime())
                local f = S.frame
                local sc = f:GetScale() or 1
                -- the tracker at its real size (five rows, one per colour
                -- state); the canvas is its box and the strip scales it
                local fw, fh = f:GetWidth() or 180, f:GetHeight() or 60
                K.FitStrip(P, P.store.holder, fw * sc, fh * sc, 4, fw, fh)
            end,
            replay = function(canvas, P)
                local S = P.store.sample
                if not S then return end
                local db = RC.db[key]
                K.Replay(P.store, canvas, { { frame = S.frame, inSpec = db.showAnim or NONE, outSpec = db.hideAnim or NONE,
                    onIn = function()
                        if not db.urgentAnim then return end
                        for _, row in ipairs(S.frame.rows) do
                            if row:IsVisible() and row.bucket == 3 then RC.Motion.Play(row, db.urgentAnim, "update") end
                        end
                    end } }, 2.0)
            end,
        }
    end

    -- Shared page. opts:
    --   key         db / tracker key
    --   panel       this page's RC method name (for re-render)
    --   title, subtitle, icon
    --   pageTitle   header text when it differs from title
    --   kind        "buff" | "debuff"
    --   catalog     the tracker's catalog list
    --   warnRange   { min, max, step } for the first warning
    --   warn2Range  { min, max, step } for the urgent warning (0 = off)
    --   sampleLine  spoken by the Test voice button
    --   refresh     RC method name that refreshes the tracker
    local function BuildTrackerPage(self, frame, preserveScroll, opts)
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local parent = frame.scrollChild
        local yPos = -20

        local tracker = self.GetAuraTracker and self:GetAuraTracker(opts.key)
        if tracker then tracker:InitDB() end
        if not self.db[opts.key] then self.db[opts.key] = {} end
        local db = self.db[opts.key]
        db.tracked = db.tracked or {}
        db.custom = db.custom or {}
        if type(db.whisperFor) ~= "table" then db.whisperFor = {} end
        local isDebuff = (opts.kind == "debuff")

        local P = self.UI:DeclarePreview(PreviewSpec(opts.key, opts.title))
        local function Replay() if P then P.Replay() end end
        local function Save() RC:SaveConfigurationToProfile() end
        local function Refresh()
            if RC[opts.refresh] then RC[opts.refresh](RC) end
        end
        local function Rerender()
            RC[opts.panel](RC, frame, true)
        end
        local function Apply()
            Refresh()
            Save()
        end

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, opts.pageTitle or opts.title, opts.subtitle, opts.icon)
        yPos = newY

        if not tracker then
            local card = self:CreateSettingsCard(parent, yPos, opts.cardTitle or opts.title)
            local msg = self:CreateFontString(card, "OVERLAY", nil, 10)
            msg:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -32)
            msg:SetPoint("RIGHT", card, "RIGHT", -14, 0)
            msg:SetJustifyH("LEFT")
            msg:SetWordWrap(true)
            msg:SetText(RCL["The tracker is still loading. Reopen this page in a moment."])
            TextColor(msg, "text", "gray")
            card:SetContentHeight(40)
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            return
        end

        -- Live repaint of the on-screen frame while a slider drags.
        local function Live()
            if tracker.LiveAppearance then tracker:LiveAppearance() end
        end

        -- Slider row: 10px label at x 14, slider from x 130, value text
        -- above the track. onChanged(v) fires live, Save on release;
        -- live = also repaint the frame while dragging.
        local function AddSlider(card, cy, label, minV, maxV, cur, step, fmt, onChanged, live)
            local lbl = self:CreateFontString(card, "OVERLAY", nil, 10)
            lbl:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
            lbl:SetText(label)
            TextColor(lbl, "text", "normal")
            local sl = self.UI:CreateSlider(card, minV, maxV, cur, step)
            sl:SetPoint("TOPLEFT", card, "TOPLEFT", 130, cy + 5)
            sl:SetWidth(math_max(120, (card:GetWidth() or 320) - 130 - 14))
            sl.Text:SetText(fmt(cur))
            sl:SetScript("OnValueChanged", function(s, v)
                v = math_floor(v / step + 0.5) * step
                sl.Text:SetText(fmt(v))
                onChanged(v)
                if live then Live() end
            end)
            sl:SetScript("OnMouseUp", function() Apply() end)
            return cy - 34
        end

        local function AddCheckbox(card, cy, label, x, initial, onClick, tip)
            local cb = self.UI:CreateCheckbox(card, label, initial)
            cb:SetPoint("TOPLEFT", card, "TOPLEFT", x or 14, cy)
            cb:SetScript("OnClick", function(c)
                local v = c:GetChecked() and true or false
                RC:ForceCheckboxUpdate(c, v)
                onClick(v)
            end)
            if tip then
                cb:HookScript("OnEnter", function(s)
                    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                    local gold, norm = RC:GetColor("text", "gold"), RC:GetColor("text", "normal")
                    GameTooltip:SetText(label, gold.r, gold.g, gold.b)
                    GameTooltip:AddLine(tip, norm.r, norm.g, norm.b, true)
                    GameTooltip:Show()
                end)
                cb:HookScript("OnLeave", function() GameTooltip:Hide() end)
            end
            return cy - 23, cb
        end

        -- one gray line at most; the rest in its tooltip (RC.UI:CreateHelpLine)
        local function AddHint(card, cy, text)
            return (RC.UI:CreateHelpLine(card, 14, cy, text, { color = { "text", "secondary" }, gap = 8 }))
        end

        local function AddLabel(card, cy, text)
            local l = self:CreateFontString(card, "OVERLAY", nil, 10)
            l:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
            l:SetText(text)
            TextColor(l, "text", "normal")
            return cy - 18
        end

        ------------------------------------------------------------
        -- 1. Main card: enable, alert mode
        ------------------------------------------------------------
        do
            local card = self:CreateSettingsCard(parent, yPos, opts.cardTitle or opts.title)
            local cardY = -32

            cardY = AddHint(card, cardY, opts.blurb)

            local enableCb
            cardY, enableCb = AddCheckbox(card, cardY, string_format(RCL["Enable %s"], opts.title), 14, db.enabled, function(v)
                db.enabled = v
                Apply()
            end)
            cardY = cardY - 6
            local enableMark = self.UI:MarkCard(card)

            self.UI:CreateSegmentedControl(card, {
                x = 14, y = cardY, height = 22, label = RCL["Alerts:"],
                items = {
                    {key = "both", label = RCL["Voice + On-screen"], tooltip = RCL["Show the timer list and speak the warnings."]},
                    {key = "tts",  label = RCL["Voice only"],        tooltip = RCL["No frame on screen; only the spoken warnings."]},
                    {key = "ui",   label = RCL["On-screen only"],    tooltip = RCL["Just the timer list, never speaks."]},
                },
                selected = db.alertMode or "both",
                onSelect = function(key)
                    db.alertMode = key
                    Apply()
                end,
            })
            cardY = cardY - 22 - 6
            cardY = AddHint(card, cardY, RCL["Voice alerts also need 'Enable voice alerts (TTS)' switched on under Reminder Settings > Sound."])

            cardY = cardY - 4
            self.UI:CreateSegmentedControl(card, {
                x = 14, y = cardY, height = 22, label = RCL["On screen:"],
                items = {
                    {key = "all", label = RCL["All"], tooltip = isDebuff
                        and RCL["Debuffs on the target with time left, plus every tracked debuff that is missing."]
                        or  RCL["Buffs you have with time left, plus every tracked buff you are missing."]},
                    {key = "active", label = RCL["Active only"], tooltip = isDebuff
                        and RCL["Only debuffs that are on the target, with time left."]
                        or  RCL["Only buffs you have, with time left."]},
                    {key = "missing", label = RCL["Missing only"], tooltip = isDebuff
                        and RCL["Hides a debuff while the target has it, so the list is only what needs putting up."]
                        or  RCL["Hides a buff while you have it, so the list is only what you still need."]},
                },
                selected = db.hidePresent and "missing" or (db.showMissing and "all" or "active"),
                onSelect = function(key)
                    db.showMissing = (key ~= "active")
                    db.hidePresent = (key == "missing")
                    Apply()
                    Rerender()
                end,
            })
            cardY = cardY - 22 - 6
            if db.hidePresent then
                cardY = AddCheckbox(card, cardY, RCL["Still show when about to expire"], 14, db.showExpiring ~= false, function(v)
                    db.showExpiring = v
                    Apply()
                end, isDebuff
                    and RCL["A debuff the target has comes back on the list once it is under the first warning time."]
                    or  RCL["A buff you have comes back on the list once it is under the first warning time."])
            end
            self.UI:BindDependents(enableCb, self.UI:CardSince(card, enableMark))

            card:SetContentHeight(math.abs(cardY))

            yPos = yPos - card:GetHeight() - 14
        end

        ------------------------------------------------------------
        -- 2. Show in
        ------------------------------------------------------------
        do
            local card = self:CreateSettingsCard(parent, yPos, RCL["Show in"])
            local cardY = -32

            local modes = {
                {key = "always",         name = "Always"},
                {key = "group",          name = "In a Group"},
                {key = "city",           name = "In Cities"},
                {key = "raids",          name = "In Raids"},
                {key = "raids_and_city", name = "Raids & Cities"},
            }
            if not db.visibilityMode then db.visibilityMode = "raids" end
            if _sbc.BuildVisibilityModeGrid then
                cardY = _sbc.BuildVisibilityModeGrid(card, cardY, modes, db, function()
                    Apply()
                    Rerender()
                end)
            else
                -- Cons_Base.lua has not published the grid (main addon
                -- load order changed); fall back to a segmented control
                -- so the mode is still editable.
                self.UI:CreateSegmentedControl(card, {
                    x = 14, y = cardY, height = 22,
                    items = {
                        {key = "always",         label = RCL["Always"]},
                        {key = "group",          label = RCL["Group"]},
                        {key = "city",           label = RCL["Cities"]},
                        {key = "raids",          label = RCL["Raids"]},
                        {key = "raids_and_city", label = RCL["Raids & Cities"]},
                    },
                    selected = db.visibilityMode or "raids",
                    onSelect = function(key)
                        db.visibilityMode = key
                        Apply()
                        Rerender()
                    end,
                })
                cardY = cardY - 22 - 6
            end
            cardY = cardY - 4

            cardY = AddCheckbox(card, cardY, RCL["Only in combat"], 14, db.onlyInCombat, function(v)
                db.onlyInCombat = v
                Apply()
            end, RCL["Hides the list and stays quiet out of combat."])

            if isDebuff then
                cardY = AddCheckbox(card, cardY, RCL["Bosses only"], 14, db.bossesOnly ~= false, function(v)
                    db.bossesOnly = v
                    Apply()
                end, RCL["Only track raid bosses and their named adds. Off = any attackable target."])
            end

            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 14
        end
        -- fade rules on top of "Show in" (the customization standard)
        local function LiveApply() Apply() if tracker.LiveAppearance then tracker:LiveAppearance() end end
        yPos = self.UI:FrameVisibilityCard(parent, yPos, db, LiveApply) + 1

        ------------------------------------------------------------
        -- 3. Warnings
        ------------------------------------------------------------
        do
            local card = self:CreateSettingsCard(parent, yPos, RCL["Warnings"])
            local cardY = -32

            local r1, r2 = opts.warnRange, opts.warn2Range
            cardY = AddSlider(card, cardY, RCL["First warning at:"], r1[1], r1[2], db.warnAt or r1[1], r1[3],
                SecondsLabel, function(v) db.warnAt = v end)
            cardY = AddSlider(card, cardY, RCL["Urgent warning at:"], r2[1], r2[2], db.warnAt2 or 0, r2[3],
                SecondsLabel, function(v) db.warnAt2 = v end)

            cardY = AddCheckbox(card, cardY, RCL["Say when missing"], 14, db.ttsMissing, function(v)
                db.ttsMissing = v
                Apply()
            end, isDebuff
                and RCL["Speaks '<debuff> missing' when a tracked debuff falls off the target mid-fight, and repeats it on the interval below while it stays off."]
                or  RCL["Speaks '<buff> missing' when a tracked buff drops off you, and repeats it on the interval below while it stays off."])
            cardY = cardY - 6

            cardY = AddSlider(card, cardY, RCL["Repeat every:"], 10, 120, db.ttsCooldown or 30, 5,
                function(v) return math_floor(v) .. "s" end, function(v) db.ttsCooldown = v end)

            local testBtn = self.UI:CreateStyledButton(card, RCL["Test voice"], 110, 22)
            testBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            testBtn:SetScript("OnClick", function()
                if RC.SpeakTTSPreview then RC:SpeakTTSPreview(opts.sampleLine) end
            end)
            cardY = cardY - 30

            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 14
        end

        ------------------------------------------------------------
        -- 3b. Whisper reminders (off by default). The rules that keep
        -- it from nagging live in the tracker (WHISPER REMINDERS in
        -- Reminders\AuraTracker.lua); this card is the switch, the repeat
        -- limit and which auras it covers.
        ------------------------------------------------------------
        do
            local card = self:CreateSettingsCard(parent, yPos, RCL["Whisper reminders"])
            local cardY = -32

            cardY = AddHint(card, cardY, isDebuff
                and RCL["When a debuff drops off the boss and is not back a few seconds later, whoever put it up gets one whisper: 'Faerie Fire has dropped off Patchwerk'. Sunder, Scorch and the other stacking or rotation debuffs are never whispered about."]
                or  RCL["When a buff runs out on you and has not been recast ten seconds later, whoever cast it gets one whisper: 'Fortitude has run out on me'. Buffs you lose by dying, being dispelled or clicking them off are ignored."])

            cardY = AddCheckbox(card, cardY, RCL["Whisper the caster when it runs out"], 14, db.whisperCaster, function(v)
                db.whisperCaster = v
                Apply()
                Rerender()
            end, RCL["Only people in your group - never yourself, never anyone dead or offline. Everything owed to one person goes in a single whisper."])

            if db.whisperCaster then
                cardY = cardY - 6
                cardY = AddSlider(card, cardY, RCL["At most once per:"], 60, 600, db.whisperCooldown or 120, 30,
                    SecondsLabel, function(v) db.whisperCooldown = v end)
                cardY = AddHint(card, cardY, RCL["How often the same person can be whispered about the same aura."])

                -- One tile per tracked aura that can be whispered about.
                -- A click stores the choice; anything never clicked keeps
                -- the built-in default (on for buffs and assigned debuffs).
                local offered = {}
                for _, c in ipairs(opts.catalog) do
                    if db.tracked[c.id] and c.remind ~= nil then
                        offered[#offered + 1] = { id = c.id, label = c.label, icon = c.icon, remind = c.remind }
                    end
                end
                for _, cu in ipairs(db.custom) do
                    if type(cu) == "table" and cu.label and cu.label ~= "" then
                        offered[#offered + 1] = { id = "custom:" .. cu.label, label = cu.label,
                            icon = (type(cu.spells) == "table" and cu.spells[1]) or cu.label, remind = false }
                    end
                end

                if #offered == 0 then
                    cardY = AddHint(card, cardY, RCL["None of the auras you track can be whispered about."])
                else
                    cardY = AddLabel(card, cardY, RCL["Whisper about:"])
                    local TILE, GAP = 30, 4
                    local innerW = (card:GetWidth() or 340) - 28
                    local cols = math_max(4, math_floor((innerW + GAP) / (TILE + GAP)))
                    local GetSpellInfo = GetSpellInfo or (RC.Compat and RC.Compat.GetSpellInfo)
                    for n, o in ipairs(offered) do
                        local icon = 134400
                        if GetSpellInfo and o.icon then
                            local _, _, ic = GetSpellInfo(o.icon)
                            if ic then icon = ic end
                        end
                        local tile = self.UI:CreateIconToggleTile(card, TILE, icon)
                        local col, row = (n - 1) % cols, math_floor((n - 1) / cols)
                        tile:SetPoint("TOPLEFT", card, "TOPLEFT", 14 + col * (TILE + GAP), cardY - row * (TILE + GAP))
                        tile:SetOn(tracker:WhisperWanted(o.id, o.remind))
                        tile:SetScript("OnClick", function(t)
                            local on = not tracker:WhisperWanted(o.id, o.remind)
                            db.whisperFor[o.id] = on
                            t:SetOn(on)
                            Apply()
                        end)
                        tile:HookScript("OnEnter", function(t)
                            GameTooltip:SetOwner(t, "ANCHOR_RIGHT")
                            local gold, dim = RC:GetColor("text", "gold"), RC:GetColor("text", "gray")
                            GameTooltip:SetText(o.label, gold.r, gold.g, gold.b)
                            GameTooltip:AddLine(tracker:WhisperWanted(o.id, o.remind)
                                and RCL["Whispering the caster - click to stop"]
                                or  RCL["Not whispering - click to whisper the caster"], dim.r, dim.g, dim.b)
                            GameTooltip:Show()
                        end)
                        tile:HookScript("OnLeave", function() GameTooltip:Hide() end)
                    end
                    cardY = cardY - math.ceil(#offered / cols) * (TILE + GAP) - 2
                end
            end

            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 14
        end

        ------------------------------------------------------------
        -- 4. Tracked auras
        ------------------------------------------------------------
        do
            local card = self:CreateSettingsCard(parent, yPos, RCL["Tracked auras"])
            local cardY = -32

            cardY = AddHint(card, cardY, isDebuff
                and RCL["Click a debuff to track it. Rows keep this order on screen, so raid leads can read them by position."]
                or  RCL["Click a buff to track it. Every rank and the group version count as the same buff."])

            local TILE, GAP = 30, 4
            local innerW = (card:GetWidth() or 340) - 28
            local cols = math_max(4, math_floor((innerW + GAP) / (TILE + GAP)))
            local GetSpellInfo = GetSpellInfo or (RC.Compat and RC.Compat.GetSpellInfo)
            local n = 0
            for _, c in ipairs(opts.catalog) do
                local icon = 134400
                if GetSpellInfo and c.icon then
                    local _, _, ic = GetSpellInfo(c.icon)
                    if ic then icon = ic end
                end
                local tile = self.UI:CreateIconToggleTile(card, TILE, icon)
                local col, row = n % cols, math_floor(n / cols)
                tile:SetPoint("TOPLEFT", card, "TOPLEFT", 14 + col * (TILE + GAP), cardY - row * (TILE + GAP))
                tile:SetOn(db.tracked[c.id] and true or false)
                tile:SetScript("OnClick", function(t)
                    local on = not db.tracked[c.id]
                    db.tracked[c.id] = on or nil
                    t:SetOn(on)
                    Apply()
                end)
                tile:HookScript("OnEnter", function(t)
                    GameTooltip:SetOwner(t, "ANCHOR_RIGHT")
                    local gold, norm, dim = RC:GetColor("text", "gold"), RC:GetColor("text", "normal"), RC:GetColor("text", "gray")
                    GameTooltip:SetText(c.label, gold.r, gold.g, gold.b)
                    GameTooltip:AddLine(table.concat(c.spells, ", "), norm.r, norm.g, norm.b, true)
                    if isDebuff and c.baseDuration then
                        GameTooltip:AddLine(string_format(RCL["%ds when someone else applies it"], c.baseDuration)
                            .. (c.stacks and RCL[", shows stacks"] or ""), dim.r, dim.g, dim.b, true)
                    end
                    GameTooltip:AddLine(db.tracked[c.id] and RCL["Tracked - click to stop"] or RCL["Not tracked - click to track"], dim.r, dim.g, dim.b)
                    GameTooltip:Show()
                end)
                tile:HookScript("OnLeave", function() GameTooltip:Hide() end)
                n = n + 1
            end
            local rowsUsed = math.ceil(n / cols)
            cardY = cardY - rowsUsed * (TILE + GAP) - 6

            -- Custom entries: one row each, matched by exact aura name.
            if #db.custom > 0 then
                cardY = AddLabel(card, cardY, RCL["Custom auras:"])
                for idx, cu in ipairs(db.custom) do
                    local rowH = 24
                    local rowF = CreateFrame("Frame", nil, card)
                    rowF:SetHeight(rowH)
                    rowF:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
                    rowF:SetPoint("TOPRIGHT", card, "TOPRIGHT", -14, cardY)
                    local stripe = rowF:CreateTexture(nil, "BACKGROUND")
                    stripe:SetAllPoints()
                    stripe:SetTexture(RC.UI.FLAT)
                    local sc = RC:GetColor("auraTracker", "rowBackground")
                    if idx % 2 == 0 then
                        stripe:SetVertexColor(sc.r, sc.g, sc.b, sc.a or 0.03)
                    else
                        stripe:SetVertexColor(sc.r, sc.g, sc.b, 0)
                    end

                    local xBtn = self.UI:CreateRemoveButton(rowF, 18, function()
                        self.UI:CreateConfirmDialog(RCL["Remove custom aura"],
                            string_format(RCL["Stop tracking '%s'?"], cu.label),
                            function()
                                table.remove(db.custom, idx)
                                Apply()
                                Rerender()
                            end, nil, RCL["Remove"], true)
                    end)
                    xBtn:SetPoint("RIGHT", rowF, "RIGHT", -2, 0)

                    local nameFs = self:CreateFontString(rowF, "OVERLAY", nil, 11)
                    nameFs:SetPoint("LEFT", rowF, "LEFT", 4, 0)
                    nameFs:SetText(cu.label)
                    nameFs:SetWordWrap(false)
                    TextColor(nameFs, "text", "normal")

                    local rightAnchor = xBtn
                    if isDebuff then
                        local stacksCb = self.UI:CreateCheckbox(rowF, RCL["Stacks"], cu.stacks)
                        stacksCb:SetPoint("RIGHT", xBtn, "LEFT", -56, 0)
                        stacksCb:SetScript("OnClick", function(c)
                            local v = c:GetChecked() and true or false
                            RC:ForceCheckboxUpdate(c, v)
                            cu.stacks = v
                            Apply()
                        end)

                        local durLbl = self:CreateFontString(rowF, "OVERLAY", nil, 10)
                        durLbl:SetText(RCL["Duration:"])
                        TextColor(durLbl, "text", "gray")
                        local durEb = self.UI:CreateBackedEditBox(rowF, {
                            width = 42, height = 18, insets = 3, maxLetters = 4,
                            numeric = true, fontSize = 10, justify = "CENTER",
                        })
                        durEb:SetPoint("RIGHT", stacksCb, "LEFT", -10, 0)
                        durEb:SetText(tostring(cu.baseDuration or 30))
                        local function CommitDur(eb)
                            local v = tonumber(eb:GetText())
                            if v and v > 0 then
                                cu.baseDuration = math_floor(v)
                                Apply()
                            else
                                eb:SetText(tostring(cu.baseDuration or 30))
                            end
                        end
                        durEb:SetScript("OnEnterPressed", function(eb) CommitDur(eb); eb:ClearFocus() end)
                        -- HookScript: the backed edit box already owns this
                        -- handler for its gold-ring reset.
                        durEb:HookScript("OnEditFocusLost", CommitDur)
                        durLbl:SetPoint("RIGHT", durEb, "LEFT", -4, 0)
                        rightAnchor = durLbl
                    end
                    nameFs:SetPoint("RIGHT", rightAnchor, "LEFT", -8, 0)

                    cardY = cardY - rowH - 2
                end
                cardY = cardY - 4
            end

            local addBtn = self.UI:CreateStyledButton(card, RCL["Add custom..."], 120, 22)
            addBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            addBtn:SetScript("OnClick", function()
                self.UI:CreateInputDialog(RCL["Add custom aura"],
                    isDebuff
                        and RCL["Exact debuff name as it appears on the target (e.g. Curse of Tongues). Set its duration and stacks in the row afterwards."]
                        or  RCL["Exact buff name as it appears in your buff bar (e.g. Blessing of Protection)."],
                    "",
                    function(text)
                        text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        if text == "" then return false end
                        for _, existing in ipairs(db.custom) do
                            if existing.label == text then return false end
                        end
                        db.custom[#db.custom + 1] = {
                            label = text,
                            spells = { text },
                            baseDuration = isDebuff and 30 or nil,
                            stacks = false,
                        }
                        Apply()
                        Rerender()
                    end)
            end)
            cardY = cardY - 30

            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 14
        end

        ------------------------------------------------------------
        -- 5. Appearance
        ------------------------------------------------------------
        do
            local card = self:CreateSettingsCard(parent, yPos, RCL["Appearance"])
            local cardY = -32

            -- Layout first: it decides which sliders below make sense, so
            -- a change re-renders the page (scroll kept).
            local compact = (db.layout == "compact")
            self.UI:CreateSegmentedControl(card, {
                x = 14, y = cardY, height = 22, label = RCL["Layout:"],
                items = {
                    {key = "list",    label = RCL["List"],    tooltip = RCL["One row per aura: icon, name and time left."]},
                    {key = "compact", label = RCL["Compact"], tooltip = RCL["A grid of icons with the time left on the bottom edge of each. Hover a cell for its name while the frame is unlocked."]},
                },
                selected = compact and "compact" or "list",
                onSelect = function(key)
                    db.layout = key
                    Apply()
                    Rerender()
                end,
            })
            cardY = cardY - 22 - 8

            local showBg = db.showBackground ~= false
            cardY = AddCheckbox(card, cardY, RCL["Show background"], 14, showBg, function(v)
                db.showBackground = v
                Apply()
                Rerender()
            end, RCL["Off: no backdrop, border or row stripes - just the icons and text."])
            cardY = cardY - 6

            local function Pct(v) return string_format("%.0f%%", v * 100) end
            local function Px(v) return math_floor(v) .. "px" end
            cardY = AddSlider(card, cardY, RCL["Scale:"], 0.5, 2.0, db.scale or 1, 0.05,
                Pct, function(v) tracker:SetScale(v) end, true)
            if showBg then
                cardY = AddSlider(card, cardY, RCL["Background opacity:"], 0.1, 1.0, db.opacity or 0.85, 0.05,
                    Pct, function(v) db.opacity = v end, true)
            end
            -- Icon size and spacing edit the live layout's own values
            -- (compact icons default larger than list icons).
            if compact then
                cardY = AddSlider(card, cardY, RCL["Icon size:"], 16, 48, db.compactIconSize or 32, 1,
                    Px, function(v) db.compactIconSize = math_floor(v) end, true)
                local vertical = (db.compactDirection == "DOWN" or db.compactDirection == "UP")
                cardY = AddSlider(card, cardY, vertical and RCL["Icons per column:"] or RCL["Icons per row:"], 1, 20, db.compactPerRow or 8, 1,
                    function(v) return tostring(math_floor(v)) end, function(v) db.compactPerRow = math_floor(v) end, true)
                cardY = AddSlider(card, cardY, RCL["Icon spacing:"], 0, 12, db.compactSpacing or 2, 1,
                    Px, function(v) db.compactSpacing = math_floor(v) end, true)
            else
                cardY = AddSlider(card, cardY, RCL["Icon size:"], 10, 32, db.iconSize or 16, 1,
                    Px, function(v) db.iconSize = math_floor(v) end, true)
                cardY = AddSlider(card, cardY, RCL["Row width:"], 120, 320, db.rowWidth or 180, 5,
                    Px, function(v) db.rowWidth = math_floor(v) end, true)
                cardY = AddSlider(card, cardY, RCL["Row spacing:"], 0, 10, db.spacing or 0, 1,
                    Px, function(v) db.spacing = math_floor(v) end, true)
            end
            cardY = cardY - 2

            -- The frame re-pins to the corner it grows away from, so that
            -- corner stays put. List rows stack down or up; compact icons
            -- run in any direction and wrap to a new line when one is full.
            local function Seg(label, items, selected, onSelect)
                self.UI:CreateSegmentedControl(card, {
                    x = 14, y = cardY, height = 22, items = items, selected = selected, label = label,
                    onSelect = function(key)
                        onSelect(key)
                        Apply()
                        Rerender()
                    end,
                })
                cardY = cardY - 22 - 6
            end
            if compact then
                local dir = db.compactDirection or "RIGHT"
                Seg(RCL["Grow direction:"], {
                    {key = "RIGHT", label = RCL["Right"], tooltip = RCL["Each new icon goes to the right; the left edge stays put."]},
                    {key = "LEFT",  label = RCL["Left"],  tooltip = RCL["Each new icon goes to the left; the right edge stays put."]},
                    {key = "DOWN",  label = RCL["Down"],  tooltip = RCL["Each new icon goes below, as a column; the top edge stays put."]},
                    {key = "UP",    label = RCL["Up"],    tooltip = RCL["Each new icon goes above, as a column; the bottom edge stays put."]},
                }, dir, function(key) tracker:SetCompactDirection(key) end)
                if dir == "DOWN" or dir == "UP" then
                    Seg(RCL["When a column is full:"], {
                        {key = "right", label = RCL["Next goes right"]},
                        {key = "left",  label = RCL["Next goes left"]},
                    }, db.growLeft and "left" or "right", function(key) tracker:SetGrowLeft(key == "left") end)
                else
                    Seg(RCL["When a row is full:"], {
                        {key = "down", label = RCL["Next goes below"]},
                        {key = "up",   label = RCL["Next goes above"]},
                    }, db.growDown and "down" or "up", function(key) tracker:SetGrowDown(key == "down") end)
                end
            else
                Seg(RCL["Grow direction:"], {
                    {key = "down", label = RCL["Down"], tooltip = RCL["New rows are added below; the top edge stays put."]},
                    {key = "up",   label = RCL["Up"],   tooltip = RCL["New rows are added above; the bottom edge stays put."]},
                }, db.growDown and "down" or "up", function(key) tracker:SetGrowDown(key == "down") end)
            end

            -- frame chrome: shared by both trackers (the auraTracker colours)
            cardY = K.ThemeColor(card, cardY, "auraTracker", "background", RCL["Background"], Apply, { alpha = true })
            cardY = K.ThemeColor(card, cardY, "auraTracker", "border", RCL["Border"], Apply)
            cardY = K.ThemeColor(card, cardY, "auraTracker", "rowBackground", RCL["Row stripe"], Apply, { alpha = true })
            cardY = AddHint(card, cardY - 2, RCL["These three colours are shared by the Raid Buff and Boss Debuff trackers."])

            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 14
        end
        -- the order and how many rows show, on top of the grow settings
        do
            local card = self:CreateSettingsCard(parent, yPos, RCL["Row order"])
            local cardY = -32
            local cw = card:GetWidth() or 0
            local lg, ls = self.UI:CustomAccess(db, "layout", nil, LiveApply)
            local lp = self.UI:CreateLayoutPicker(card, { width = (cw > 240) and math_min(460, cw - 28) or 420,
                get = lg, set = ls, fields = { sort = true, reverse = true, max = true },
                sorts = RC.AURA_TRACKER_SORTS, maxItems = 20, defaults = { max = 20 } })
            lp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            cardY = cardY - lp:GetHeight() - 8
            cardY = AddHint(card, cardY, RCL["Order by Default keeps the tracker's own order: missing first, then the least time left."])
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 14
        end
        yPos = self.UI:FrameChromeCard(parent, yPos, db, LiveApply,
            { fields = { bgColor = true, borderColor = true, shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } }) + 1
        -- a look per time state (on top of the three time colours on the Text tab)
        do
            local card = self:CreateSettingsCard(parent, yPos, RCL["Look per state"])
            local cardY = -32
            local cw = card:GetWidth() or 0
            local W = (cw > 240) and math_min(460, cw - 28) or 420
            local sg, ss = self.UI:CustomAccess(db, "states", nil, LiveApply)
            RC._atStateMem = RC._atStateMem or {}
            RC._atStateMem[opts.key] = RC._atStateMem[opts.key] or {}
            local se = self.UI:CreateCustomFold(card, { width = W, key = "states|" .. tostring(opts.key),
                label = RCL["Plenty of time, running out, urgent or missing"],
                changed = function() local t = sg() return type(t) == "table" and next(t) ~= nil end,
                ctor = "CreateStateEditor",
                args = { width = W, get = sg, set = ss, states = RC.AURA_TRACKER_STATES, remember = RC._atStateMem[opts.key],
                    fields = { textColor = true, color = true, desat = true, alpha = true } } })
            se:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            cardY = cardY - se:GetHeight() - 8
            cardY = AddHint(card, cardY, RCL["Unset, a row keeps its time colours (Text, below); the urgent animation is under Animation."])
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 14
        end

        ------------------------------------------------------------
        -- 6. Text: fonts and the three time colours
        ------------------------------------------------------------
        do
            local card = self:CreateSettingsCard(parent, yPos, RCL["Text"])
            local cardY = -32
            cardY = K.Font(card, cardY, db, "font", "fontSize", ROW_FONT_DEFAULTS,
                RCL["Names and time left"], isDebuff and "Sunder Armor  0:24" or "Fortitude  28:10", Apply, 8, 20)
            cardY = K.Font(card, cardY, db, "stackFont", nil, STACK_FONT_DEFAULTS,
                RCL["Stack count"], "1 2 3 4 5", Apply, 6, 24)
            cardY = AddHint(card, cardY, RCL["Until you set a size the stack count follows the icon size."])

            if type(db.colors) ~= "table" then db.colors = {} end
            local function TimeColor(k, label, fbGroup, fbKey)
                local cp = self.UI:CreateColorPicker(card, {
                    label = label, width = 420,
                    get = function() return db.colors[k] or RC:GetColor(fbGroup, fbKey) end,
                    set = function(r, g, b) db.colors[k] = { r = r, g = g, b = b, a = 1 }; Apply() end,
                    isChanged = function() return type(db.colors[k]) == "table" end,
                    reset = function() db.colors[k] = nil; Apply() end,
                })
                cp:SetPoint("TOPLEFT", card, "TOPLEFT", 10, cardY)
                cardY = cardY - 26
            end
            TimeColor("normal", RCL["Plenty of time"], "text", "normal")
            TimeColor("warning", RCL["Under the first warning"], "text", "warning")
            TimeColor("urgent", RCL["Urgent or missing"], "text", "red")
            cardY = K.ThemeColor(card, cardY, "auraTracker", "stackText", RCL["Stack count colour"], Apply)
            cardY = AddHint(card, cardY - 2, RCL["Name and time share one colour that changes as the aura runs down. Unset, they follow the theme's text colours."])
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 14
        end

        ------------------------------------------------------------
        -- 6b. Where each text and the icon sit, and how the time and
        --     names read (the customization standard; nil = as always)
        ------------------------------------------------------------
        do
            local card = self:CreateSettingsCard(parent, yPos, RCL["Text and part positions"])
            local cardY = -32
            local cw = card:GetWidth() or 0
            local W = (cw > 240) and math_min(460, cw - 28) or 420
            local function Root() return RC.db[opts.key] end
            local function After() Apply() if tracker.LiveAppearance then tracker:LiveAppearance() end end
            local function Others(except)
                local out = {}
                for _, t in ipairs(RC.AURA_TRACKER_TARGETS or {}) do if t.value ~= except then out[#out + 1] = t end end
                return out
            end
            local function Def(elem) return function() return RC:AuraTrackerAnchorDefault(elem, tracker:IsCompact(), db.fontSize) end end
            local function Place(g) g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY) cardY = cardY - g:GetHeight() - 14 end
            local ag, as = self.UI:CustomAccess(Root, "anchors", "name", After)
            local fg, fs = self.UI:CustomAccess(Root, "formats", "name", After)
            Place(self.UI:CreateTextElement(card, { label = RCL["Names"], key = "name", width = W,
                formatGet = fg, formatSet = fs, formatKinds = { name = true }, formatDefaults = RC.AURA_TRACKER_NAME_FORMAT,
                formatSample = function(spec) return RC.UI:FormatText(spec, nil, { value = isDebuff and "Sunder Armor" or "Arcane Intellect" }, { value = "name" }, "value") end,
                anchorGet = ag, anchorSet = as, anchorDefaults = Def("name"), targets = Others("name") }))
            ag, as = self.UI:CustomAccess(Root, "anchors", "time", After)
            fg, fs = self.UI:CustomAccess(Root, "formats", "time", After)
            Place(self.UI:CreateTextElement(card, { label = RCL["Time left"], key = "time", width = W,
                formatGet = fg, formatSet = fs, formatKinds = { time = true }, formatDefaults = RC.AURA_TRACKER_TIME_FORMAT,
                formatSample = function(spec) return RC.UI:FormatText(spec, RC.AURA_TRACKER_TIME_FORMAT, { value = 272 }, { value = "time" }, "value") end,
                anchorGet = ag, anchorSet = as, anchorDefaults = Def("time"), targets = Others("time") }))
            ag, as = self.UI:CustomAccess(Root, "anchors", "count", After)
            Place(self.UI:CreateTextElement(card, { label = RCL["Stack count"], key = "count", width = W,
                anchorGet = ag, anchorSet = as, anchorDefaults = Def("count"), targets = Others("count") }))
            ag, as = self.UI:CustomAccess(Root, "anchors", "title", After)
            Place(self.UI:CreateTextElement(card, { label = RCL["Title (while moving it)"], key = "title", width = W,
                anchorGet = ag, anchorSet = as, anchorDefaults = Def("title"),
                targets = { { value = "bar", text = RCL["Title strip"] }, { value = "frame", text = RCL["The tracker"] } } }))
            ag, as = self.UI:CustomAccess(Root, "anchors", "icon", After)
            Place(self.UI:CreateFrameElement(card, { label = RCL["Icon"], key = "icon", width = W,
                anchorGet = ag, anchorSet = as, anchorDefaults = Def("icon"), targets = Others("icon") }))
            cardY = AddHint(card, cardY, RCL["List and Compact each keep their own default places. Reset puts a part back where it always sat."])
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 14
        end

        ------------------------------------------------------------
        -- 6c. Sound when an aura turns urgent or goes missing
        ------------------------------------------------------------
        do
            local card = self:CreateSettingsCard(parent, yPos, RCL["Urgent sound"])
            local cardY = -32
            local cw = card:GetWidth() or 0
            local sg, ss = self.UI:CustomAccess(function() return RC.db[opts.key] end, "sounds", "urgent", Apply)
            local sp = self.UI:CreateSoundSpecPicker(card, { width = (cw > 240) and math_min(460, cw - 28) or 420,
                get = sg, set = ss, defaults = {} })
            sp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            cardY = cardY - sp:GetHeight() - 8
            cardY = AddHint(card, cardY, isDebuff and RCL["Plays once when a debuff turns urgent or drops off. No sound picked: silent, as before."]
                or RCL["Plays once when a buff turns urgent or runs out. No sound picked: silent, as before."])
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 14
        end

        ------------------------------------------------------------
        -- 7. Animation
        ------------------------------------------------------------
        do
            local card = self:CreateSettingsCard(parent, yPos, RCL["Animation"])
            local cardY = -32
            local function Changed() Apply(); Replay() end
            cardY = K.Anim(card, cardY, db, "showAnim", ANIM_IN, RCL["When the list appears"], "in", Changed)
            cardY = K.Anim(card, cardY, db, "urgentAnim", ANIM_URGENT,
                isDebuff and RCL["When a debuff turns urgent or drops off"] or RCL["When a buff turns urgent or runs out"], "update", Changed)
            cardY = K.Anim(card, cardY, db, "hideAnim", ANIM_OUT, RCL["When the list empties"], "out", Changed)
            cardY = AddHint(card, cardY, RCL["Appearance > Motion can turn every animation off or speed them all up."])
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 14
        end

        ------------------------------------------------------------
        -- 8. Position
        ------------------------------------------------------------
        do
            local card = self:CreateSettingsCard(parent, yPos, RCL["Position"])
            local cardY = -32
            cardY = AddCheckbox(card, cardY, RCL["Lock position (click-through)"], 14, db.locked ~= false, function(v)
                db.locked = v
                Apply()
            end)
            cardY = cardY - 6

            local resetBtn = self.UI:CreateStyledButton(card, RCL["Reset position"], 120, 22)
            resetBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            resetBtn:SetScript("OnClick", function()
                if tracker.ResetPosition then tracker:ResetPosition() end
                Apply()
            end)
            cardY = cardY - 30

            cardY = AddHint(card, cardY, RCL["Edit Mode (/rc move) shows the frame with sample rows so you can drag it into place."])

            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 14
        end
        yPos = self.UI:FrameLayerCard(parent, yPos, db, LiveApply, { scale = false }) + 1

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
        if preserveScroll then self:RestoreScrollPosition(self.sidebarConfigFrame) end
    end

    function RC:ShowSidebarRaidBuffTrackerConfig(frame, preserveScroll)
        local AT = RC.AuraTracker
        BuildTrackerPage(self, frame, preserveScroll, {
            key        = "raidBuffTracker",
            panel      = "ShowSidebarRaidBuffTrackerConfig",
            refresh    = "RefreshRaidBuffTracker",
            title      = RCL["Raid Buff Tracker"],
            cardTitle  = RCL["Raid buff tracker"],
            subtitle   = RCL["Time left on your class buffs, on screen and spoken"],
            icon       = "Interface\\Icons\\Spell_Holy_WordFortitude",
            blurb      = RCL["Watches Fortitude, Intellect, Mark of the Wild, the Blessings and the rest on you, lists how long each has left and warns before they run out."],
            kind       = "buff",
            catalog    = (AT and AT.RAID_BUFF_CATALOG) or {},
            warnRange  = { 30, 600, 30 },
            warn2Range = { 0, 300, 15 },
            sampleLine = RCL["Fortitude, 5 minutes"],
        })
    end

    function RC:ShowSidebarBossDebuffTrackerConfig(frame, preserveScroll)
        local AT = RC.AuraTracker
        BuildTrackerPage(self, frame, preserveScroll, {
            key        = "bossDebuffTracker",
            panel      = "ShowSidebarBossDebuffTrackerConfig",
            refresh    = "RefreshBossDebuffTracker",
            title      = RCL["Boss Debuff Tracker"],
            cardTitle  = RCL["Boss debuff tracker"],
            subtitle   = RCL["Time left on the raid's debuffs on your target"],
            icon       = "Interface\\Icons\\Spell_Nature_FaerieFire",
            blurb      = RCL["Watches Sunder, the curses, Scorch stacks, Demo Shout and the rest on your target, lists time left and stacks, and calls out anything about to drop or already missing. Timers for other people's debuffs are estimated from when they were applied."],
            kind       = "debuff",
            catalog    = (AT and AT.BOSS_DEBUFF_CATALOG) or {},
            warnRange  = { 3, 30, 1 },
            warn2Range = { 0, 15, 1 },
            sampleLine = RCL["Sunder, 10 seconds"],
        })
    end
