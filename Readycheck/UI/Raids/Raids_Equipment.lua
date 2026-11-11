------------------------------------------------------------------------
-- Readycheck - Equipment Reminder & Inline-Expansion Helpers
-- NOT raid-profile data: self.db.fastWeaponReminder is a single global/
-- character-level table (detect fast weapons, shields, etc. whenever
-- equipped), unrelated to the per-boss forceEquip gear swaps configured in
-- Raids_BossConfig.lua. Has no remote-edit awareness because there is no
-- per-raid selection here to redirect.
-- CycleInlineExpansion/FadeInInlineBody are generic fade helpers shared by
-- every Raids_*.lua inline expand/collapse (boss ability rows, bulk trash
-- ability rows), not specific to equipment.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format, string_lower = string.format, string.lower
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbr = RC._sbr or {}
local _sbr = RC._sbr
local INLINE_FADE_IN_DURATION, INLINE_FADE_OUT_DURATION, TEXT = _sbr.INLINE_FADE_IN_DURATION, _sbr.INLINE_FADE_OUT_DURATION, _sbr.TEXT
-- the shared gear-page setting rows (Equip_Base.lua, loaded before us)
local function _seq_look() return RC._seq.Look end
    function RC:CycleInlineExpansion(getOldFrame, commit)
        local oldFrame = getOldFrame and getOldFrame() or nil
        if oldFrame and oldFrame.IsShown and oldFrame:IsShown() and oldFrame:GetAlpha() > 0.01 then
            if UIFrameFadeOut then
                UIFrameFadeOut(oldFrame, INLINE_FADE_OUT_DURATION, oldFrame:GetAlpha(), 0)
            end
            C_Timer.After(INLINE_FADE_OUT_DURATION, function()
                if commit then commit() end
            end)
        else
            if commit then commit() end
        end
    end

    function RC:FadeInInlineBody(frame)
        if not frame then return end
        frame:SetAlpha(0)
        if UIFrameFadeIn then
            UIFrameFadeIn(frame, INLINE_FADE_IN_DURATION, 0, 1)
        else
            frame:SetAlpha(1)
        end
    end

    -- The preview: the reminder's own box (RC:BuildEquipmentReminderFrame,
    -- RC:StyleEquipmentReminder, RC:LayoutEquipmentReminderIcons from the
    -- Reminders addon) with sample items. One item shows both labels;
    -- several pack into the grid with the WARNING line only.
    local EPV_W, EPV_H = 110, 90   -- update sizes the canvas to the box and its two labels
    local SAMPLE_ITEMS = { 134955, 135321, 133441 }
    local function EquipPreviewBuild(canvas, P)
        P.store.frame = RC:BuildEquipmentReminderFrame(canvas, false)
        P.store.frame:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        P.store.token = 0
    end
    local function EquipPreviewUpdate(canvas, P)
        local f, db = P.store.frame, RC.db.fastWeaponReminder
        local n = (P.mode == "several") and 3 or 1
        local size = tonumber(db.iconSize) or 48
        local _, fsz = RC:ResolveFontSpec(db.textFont, RC:EquipReminderFontDefaults())
        local sig = n .. ":" .. size
        if P.store.sig ~= sig then
            RC.Motion.Stop(f)
            f:SetScale(1)
            P.store.sig = sig
        end
        RC:StyleEquipmentReminder(f)
        RC:LayoutEquipmentReminderIcons(f, n)
        -- the canvas is the box with the labels over and under it (at its
        -- real size), centred; the strip scales it
        if not RC.Motion.IsPlaying(f) then
            local cx, cy, w, h = P.Measure(f)
            if cx then
                f:ClearAllPoints()
                f:SetPoint("CENTER", canvas, "CENTER", -cx, -cy)
                P.Resize(w + 6, h + 6)
            else
                P.Resize(size + 60, size + 2 * (fsz or 14) + 12)
            end
        end
        for i = 1, n do f.icons[i].texture:SetTexture(SAMPLE_ITEMS[i]) end
        f.topText:SetText(n == 1 and RCL["Shield"] or "")
        f.headerText:SetText("WARNING")
    end
    local function EquipPreviewReplay(canvas, P)
        local f, st, M = P.store.frame, P.store, RC.Motion
        st.token = st.token + 1
        local t = st.token
        M.Stop(f)
        f:Hide()
        RC:ShowEquipmentReminderFrame(f, true)
        local inSpec = RC:EquipReminderAnim("showAnim")
        local fl = RC:EquipReminderAnim("flashAnim", RC.EQUIP_REMINDER_FLASH)
        local hold = M.Duration(inSpec.duration + inSpec.delay) + M.Duration(fl.duration + fl.delay) + 1
        C_Timer.After(hold, function()
            if t ~= st.token or not f:IsVisible() then return end
            local outSpec = RC:EquipReminderAnim("hideAnim")
            M.Hide(f, outSpec)
            C_Timer.After(M.Duration(outSpec.duration + outSpec.delay) + 0.4, function()
                if t ~= st.token then return end
                M.Stop(f)
                if canvas:IsVisible() then f:Show() end
            end)
        end)
    end

    local EQUIP_TABS = {
        { key = "behavior",   label = RCL["Behavior"] },
        { key = "detection",  label = RCL["Detection"] },
        { key = "custom",     label = RCL["Custom Items"] },
        { key = "look",       label = RCL["Look"] },
        { key = "text",       label = RCL["Text"] },
        { key = "animation",  label = RCL["Animation"] },
        { key = "sound",      label = RCL["Sound"] },
        { key = "position",   label = RCL["Position"] },
    }
    -- old keys: the voice options moved to Sound, the size to Look
    local EQUIP_OLD_TABS = { general = "sound", appearance = "look" }

    function RC:ShowSidebarFastWeaponConfig(frame, selectedTab)
        self:ClearSidebarContent(self.sidebarConfigFrame, selectedTab ~= nil)
        local parent = frame.scrollChild
        local yPos = -20

        local P
        if self.BuildEquipmentReminderFrame and self.StyleEquipmentReminder then
            P = self.UI:DeclarePreview({
                key = "equipment.reminder", title = RCL["Equipment reminder"],
                width = EPV_W, height = EPV_H,
                build = EquipPreviewBuild, update = EquipPreviewUpdate, replay = EquipPreviewReplay,
                modes = { { id = "one", label = RCL["One item"] }, { id = "several", label = RCL["Several"] } },
            })
        end

        local headerFrame, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Equipment Reminder"],
            RCL["Shows warning when specific gear is equipped"], "Interface\\Icons\\INV_Sword_04")
        yPos = newY

        if not self.db.fastWeaponReminder then
            self.db.fastWeaponReminder = {
                enabled = false, locked = true, alwaysShow = false,
                showIcon = true, flashOnEquip = true, playSound = false,
                scale = 1.0, fontSize = 14,
                anchorPoint = "CENTER", xOffset = 0, yOffset = 200,
                detectFastWeapons = true, detectShields = true,
                detectHealingWeapons = true, detectWrathGear = true,
                detectCustomItems = true, detectUtilityItems = true, customItems = {}
            }
        end

        if self.db.fastWeaponReminder.detectCustomItems == nil then self.db.fastWeaponReminder.detectCustomItems = true end
        if self.db.fastWeaponReminder.detectUtilityItems == nil then self.db.fastWeaponReminder.detectUtilityItems = true end
        if self.db.fastWeaponReminder.customItems == nil then self.db.fastWeaponReminder.customItems = {} end

        local L = _seq_look()
        selectedTab = L.TabKey(selectedTab or frame.equipReminderTab, EQUIP_TABS, EQUIP_OLD_TABS, "behavior")
        frame.equipReminderTab = selectedTab
        frame.equipReminderP = P

        local _, tabY = RC.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = EQUIP_TABS,
            selected = selectedTab,
            onClick = function(tk)
                frame.equipReminderTab = tk
                RC:ShowSidebarFastWeaponConfig(frame, tk)
            end,
            advance = 46,
        })
        yPos = tabY

        if selectedTab == "behavior" then
            yPos = self:ShowEquipmentReminderGeneralTab(parent, yPos, frame)
        elseif selectedTab == "detection" then
            yPos = self:ShowEquipmentReminderDetectionTab(parent, yPos, frame)
        elseif selectedTab == "custom" then
            yPos = self:ShowEquipmentReminderCustomTab(parent, yPos, frame)
        else
            yPos = self:ShowEquipmentReminderLookTabs(parent, yPos, frame, selectedTab, P)
        end
        -- where the two labels sit (fastWeaponReminder.anchors.top / .bottom)
        if selectedTab == "text" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Text positions"])
            local cy = -32
            local cw = card:GetWidth() or 0
            local W = (cw > 240) and math.min(460, cw - 28) or 420
            local function Root() return RC.db.fastWeaponReminder end
            local function After()
                RC:SaveConfigurationToProfile()
                local f = RC.fastWeaponReminder and RC.fastWeaponReminder.frame
                if f then RC:StyleEquipmentReminder(f) end
            end
            local FRAME = { value = "frame", text = RCL["The reminder"] }
            local ICONS = { value = "icons", text = RCL["The first icon"] }
            local rows = {
                { "top", RCL["Top label"], { FRAME, ICONS, { value = "bottom", text = RCL["The bottom label"] } }, RCL["Centred on the top edge"], { point = "CENTER", relPoint = "TOP", x = 0, y = 0 } },
                { "bottom", RCL["Bottom label"], { FRAME, ICONS, { value = "top", text = RCL["The top label"] } }, RCL["Centred on the bottom edge"], { point = "CENTER", relPoint = "BOTTOM", x = 0, y = 0 } },
            }
            for _, r in ipairs(rows) do
                local ag, as = self.UI:CustomAccess(Root, "anchors", r[1], After)
                local def = r[5]
                local g = self.UI:CreateTextElement(card, { label = r[2], key = "eq" .. r[1], width = W,
                    anchorGet = ag, anchorSet = as, targets = r[3], defaultTargetLabel = r[4],
                    anchorDefaults = function() return def end })
                g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                cy = cy - g:GetHeight() - 14
            end
            cy = self.UI:CreateHelpLine(card, 14, cy + 4, RCL["Reset puts a label back where the reminder always put it."])
            card:SetContentHeight(math.abs(cy) + 4)
            yPos = yPos - card:GetHeight() - 15
        end
        -- the frame's layer / fade / edge (the customization standard)
        yPos = self.UI:FrameCardsForTab(selectedTab, parent, yPos, function() return RC.db.fastWeaponReminder end, function()
            local f = RC.fastWeaponReminder and RC.fastWeaponReminder.frame
            if f then RC:StyleEquipmentReminder(f) end
        end)

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
    end

    function RC:ShowEquipmentReminderGeneralTab(parent, yPos, frame)
        local L = _seq_look()
        local db = self.db.fastWeaponReminder
        local function Refresh() if RC.UpdateFastWeaponReminder then RC:UpdateFastWeaponReminder() end end
        local enableCb
        yPos = L.Card(parent, yPos, RCL["Equipment reminder"], function(card, cy)
            cy, enableCb = L.Check(card, cy, RCL["Enable the equipment reminder"], db.enabled, function(on)
                db.enabled = on
                Refresh()
                RC:SaveConfigurationToProfile()
            end)
            local testBtn = self.UI:CreateStyledButton(card, RCL["Show Test"], 100, 24)
            testBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy - 2)
            testBtn:SetScript("OnClick", function()
                if RC.ShowFastWeaponReminderTest then RC:ShowFastWeaponReminderTest() end
            end)
            local hideBtn = self.UI:CreateStyledButton(card, RCL["Hide Test"], 100, 24)
            hideBtn:SetPoint("LEFT", testBtn, "RIGHT", 10, 0)
            hideBtn:SetScript("OnClick", function()
                if RC.HideFastWeaponReminderTest then RC:HideFastWeaponReminderTest() end
            end)
            return cy - 34
        end)
        yPos = L.Card(parent, yPos, RCL["Behavior"], function(card, cy)
            local mark = RC.UI:MarkCard(card)
            cy = L.Check(card, cy, RCL["Always show (not just raids)"], db.alwaysShow, function(on)
                db.alwaysShow = on
                Refresh()
                RC:SaveConfigurationToProfile()
            end)
            cy = L.Check(card, cy, RCL["Show the item icon"], db.showIcon, function(on)
                db.showIcon = on
                RC:SaveConfigurationToProfile()
            end)
            cy = L.Check(card, cy, RCL["Flash when it appears"], db.flashOnEquip, function(on)
                db.flashOnEquip = on
                RC:SaveConfigurationToProfile()
            end, RCL["How it flashes is on the Animation tab."])
            -- (the card under the switch: greyed with it, not set in)
            if enableCb then RC.UI:BindDependents(enableCb, RC.UI:CardSince(card, mark), { indent = 0 }) end
            return cy
        end)

        return yPos
    end

    -- Look / Text / Animation / Sound / Position
    function RC:ShowEquipmentReminderLookTabs(parent, yPos, frame, tab, P)
        local L = _seq_look()
        local db = self.db.fastWeaponReminder
        local function Apply()
            if RC.UpdateEquipmentReminderIconSize then RC:UpdateEquipmentReminderIconSize() end
            if RC.UpdateEquipmentReminderFontSize then RC:UpdateEquipmentReminderFontSize() end
        end
        local fontDefaults = RC.EquipReminderFontDefaults and RC:EquipReminderFontDefaults()
            or { size = tonumber(db.fontSize) or 14, outline = "OUTLINE", shadow = true }

        if tab == "look" then
            yPos = L.Card(parent, yPos, RCL["Frame appearance"], function(card, cy)
                cy = L.Slider(card, cy, { label = RCL["Box size"], min = 24, max = 96, step = 2,
                    value = db.iconSize or 48, fmt = function(v) return v .. RCL[" px"] end,
                    set = function(v) db.iconSize = v Apply() end })
                cy = L.Desc(card, cy, RCL["The box never grows: several items pack into it as a grid."])
                cy = L.OwnColor(card, cy, db, "cellColor", RCL["Icon background"], function()
                    local c = RC:GetColor("ui", "cardBackground")
                    return { r = c.r, g = c.g, b = c.b, a = 0.9 }
                end, Apply, nil, true)
                cy = L.Check(card, cy - 2, RCL["Show a border around each icon"], db.showBorder ~= false, function(on)
                    db.showBorder = on Apply() RC:SaveConfigurationToProfile()
                end)
                cy = L.OwnColor(card, cy, db, "borderColor", RCL["Border colour"],
                    function() return RC:GetColor("ui", "borderNormal") end, Apply)
                return cy
            end)

        elseif tab == "text" then
            yPos = L.Card(parent, yPos, RCL["Text"], function(card, cy)
                cy = L.Check(card, cy, RCL["Show the labels (item type above, WARNING below)"], db.showText ~= false, function(on)
                    db.showText = on Apply() RC:SaveConfigurationToProfile()
                end)
                -- the size is the old fontSize key; face, outline and shadow are new
                local fp = self.UI:CreateFontPicker(card, { label = RCL["Font"], width = 420,
                    get = function()
                        local t = type(db.textFont) == "table" and db.textFont or {}
                        return { face = t.face, outline = t.outline, shadow = t.shadow, size = db.fontSize }
                    end,
                    set = function(spec)
                        if spec.size then db.fontSize = spec.size end
                        db.textFont = { face = spec.face, outline = spec.outline, shadow = spec.shadow }
                        Apply()
                        RC:SaveConfigurationToProfile()
                    end,
                    defaults = fontDefaults, minSize = 8, maxSize = 32, sample = "Shield  WARNING" })
                fp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                cy = cy - fp:GetHeight() - 10
                cy = L.OwnColor(card, cy, db, "textColor", RCL["Text colour"],
                    function() return RC:GetColor("text", "red") end, Apply)
                return cy
            end)

        elseif tab == "animation" then
            local AD = RC.EQUIP_REMINDER_ANIM or { style = "none", duration = 0.3 }
            local FD = RC.EQUIP_REMINDER_FLASH or { style = "fade", duration = 0.8, easing = "linear" }
            yPos = L.Card(parent, yPos, RCL["Animation"], function(card, cy)
                cy = L.Anim(card, cy, db, "showAnim", RCL["When it appears"], "in", AD, P)
                cy = L.Anim(card, cy, db, "flashAnim", RCL["The flash (Flash when it appears)"], "update", FD, P)
                cy = L.Anim(card, cy, db, "hideAnim", RCL["When it goes"], "out", AD, P)
                return cy
            end)

        elseif tab == "sound" then
            local soundCard = self:CreateSettingsCard(parent, yPos, RCL["Sound"])
            local cardY = -35
            local soundCheck = self.UI:CreateSettingCheckbox(soundCard, cardY, RCL["Play a warning sound"], db.playSound, function(cb)
                db.playSound = cb:GetChecked()
                RC:ForceCheckboxUpdate(cb, cb:GetChecked())
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 26
            if self.UI.CreateSoundPicker then
                local sp = self.UI:CreateSoundPicker(soundCard, { width = 220, selected = db.soundKey or "WR: Warning",
                    onPick = function(key)
                        db.soundKey = key
                        if RC.GetSoundFile then db.soundFile = RC:GetSoundFile(key) or db.soundFile end
                        RC:SaveConfigurationToProfile()
                    end })
                sp:SetPoint("TOPLEFT", soundCard, "TOPLEFT", 38, cardY)
                cardY = cardY - 34
            end
            local ttsHeader = self:CreateFontString(soundCard, "OVERLAY", nil, 11)
            ttsHeader:SetPoint("TOPLEFT", soundCard, "TOPLEFT", 15, cardY)
            ttsHeader:SetText(RCL["Text-to-Speech"])
            ttsHeader:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
            cardY = cardY - 22

            local ttsCheck = self.UI:CreateSettingCheckbox(soundCard, cardY, "Speak warning out loud (TTS)", db.ttsEnabled, function(cb)
                RC.db.fastWeaponReminder.ttsEnabled = cb:GetChecked()
                RC:ForceCheckboxUpdate(cb, cb:GetChecked())
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 24

            cardY = RC.UI:CreateHelpLine(soundCard, 35, cardY, RCL['Speaks the warning when a flagged item is equipped, e.g. "Shield" or "Fast weapon". Shares the TTS voice and volume used by the consumables alerts.'])

            local ttsTypeHeader = self:CreateFontString(soundCard, "OVERLAY", nil, 10)
            ttsTypeHeader:SetPoint("TOPLEFT", soundCard, "TOPLEFT", 35, cardY)
            ttsTypeHeader:SetText(RCL["Speak for these item types:"])
            ttsTypeHeader:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 20

            local ttsTypeRows = {
                {key = "ttsFastWeapons",     label = RCL["Fast Weapons"]},
                {key = "ttsShields",         label = RCL["Shields"]},
                {key = "ttsHealingWeapons",  label = RCL["Healing Weapons"]},
                {key = "ttsWrathGear",       label = RCL["Wrath Gear"]},
                {key = "ttsUtilityItems",    label = RCL["Utility Items"]},
                {key = "ttsCustomItems",     label = RCL["Custom Items"]},
                {key = "ttsDaggerInOffhand", label = RCL["Offhand Dagger"]},
            }
            -- (2026-11-09) the T2 set and the Naxxramas off hands are Classic
            -- Era raid gear: their rows show on Classic Era only
            if RC.Flavor and RC:Flavor() ~= "era" then
                for i = #ttsTypeRows, 1, -1 do
                    local k = ttsTypeRows[i].key
                    if k == "ttsWrathGear" or k == "ttsDaggerInOffhand" then table.remove(ttsTypeRows, i) end
                end
            end
            for _, row in ipairs(ttsTypeRows) do
                local typeKey = row.key
                local typeCheck = self.UI:CreateCheckbox(soundCard, row.label, db[typeKey] ~= false)
                typeCheck:SetPoint("TOPLEFT", soundCard, "TOPLEFT", 35, cardY)
                typeCheck:SetScript("OnClick", function(cb)
                    RC.db.fastWeaponReminder[typeKey] = cb:GetChecked()
                    RC:ForceCheckboxUpdate(cb, cb:GetChecked())
                    RC:SaveConfigurationToProfile()
                end)
                cardY = cardY - 22
            end
            cardY = cardY - 6

            local ttsRepeatCheck = self.UI:CreateSettingCheckbox(soundCard, cardY, "Repeat the spoken warning", db.ttsRepeatEnabled, function(cb)
                RC.db.fastWeaponReminder.ttsRepeatEnabled = cb:GetChecked()
                RC:ForceCheckboxUpdate(cb, cb:GetChecked())
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 24

            local ttsRepDesc = self:CreateFontString(soundCard, "OVERLAY", nil, 10)
            ttsRepDesc:SetPoint("TOPLEFT", soundCard, "TOPLEFT", 35, cardY)
            ttsRepDesc:SetWidth(soundCard:GetWidth() - 50)
            ttsRepDesc:SetText(RCL["Keeps repeating while the item is still equipped, then stops once you swap it out."])
            ttsRepDesc:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            ttsRepDesc:SetJustifyH("LEFT")
            -- (the slider's value sits over its track: room for it)
            cardY = cardY - ttsRepDesc:GetStringHeight() - 12

            local repCntLbl = self:CreateFontString(soundCard, "OVERLAY", nil, 10)
            repCntLbl:SetPoint("TOPLEFT", soundCard, "TOPLEFT", 15, cardY)
            repCntLbl:SetText(RCL["Repeat count"])
            local repCntVal = db.ttsRepeatCount or 3
            local repCntSlider = self.UI:CreateSlider(soundCard, 1, 10, repCntVal, 1)
            repCntSlider:SetPoint("LEFT", repCntLbl, "RIGHT", 8, 0)
            repCntSlider:SetWidth(100)
            repCntSlider.Text:SetText(tostring(repCntVal))
            repCntSlider:SetScript("OnValueChanged", function(slider, value)
                value = math.floor(value)
                RC.db.fastWeaponReminder.ttsRepeatCount = value
                slider.Text:SetText(tostring(value))
            end)
            repCntSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 32

            local repIntLbl = self:CreateFontString(soundCard, "OVERLAY", nil, 10)
            repIntLbl:SetPoint("TOPLEFT", soundCard, "TOPLEFT", 15, cardY)
            repIntLbl:SetText(RCL["Repeat every"])
            local repIntVal = db.ttsRepeatInterval or 5
            local repIntSlider = self.UI:CreateSlider(soundCard, 2, 30, repIntVal, 1)
            repIntSlider:SetPoint("LEFT", repIntLbl, "RIGHT", 8, 0)
            repIntSlider:SetWidth(110)
            repIntSlider.Text:SetText(repIntVal .. "s")
            repIntSlider:SetScript("OnValueChanged", function(slider, value)
                value = math.floor(value)
                RC.db.fastWeaponReminder.ttsRepeatInterval = value
                slider.Text:SetText(value .. "s")
            end)
            repIntSlider:SetScript("OnMouseUp", function() RC:SaveConfigurationToProfile() end)
            cardY = cardY - 32

            if not (C_VoiceChat and C_VoiceChat.SpeakText) then
                local ttsWarn = self:CreateFontString(soundCard, "OVERLAY", nil, 10)
                ttsWarn:SetPoint("TOPLEFT", soundCard, "TOPLEFT", 35, cardY)
                ttsWarn:SetWidth(soundCard:GetWidth() - 50)
                ttsWarn:SetText(RCL["Note: text-to-speech is not available on this client version."])
                ttsWarn:SetTextColor(TEXT.yellow[1], TEXT.yellow[2], TEXT.yellow[3])
                ttsWarn:SetJustifyH("LEFT")
                cardY = cardY - 16
            end
            cardY = cardY - 6
            cardY = cardY - 6
            soundCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - soundCard:GetHeight() - 15

        elseif tab == "position" then
            yPos = L.Card(parent, yPos, RCL["Position"], function(card, cy)
                cy = L.Check(card, cy, RCL["Lock the frame position"], db.locked, function(on)
                    db.locked = on
                    RC:SaveConfigurationToProfile()
                end, RCL["Unlocked, drag the box to move it."])
                local resetBtn = self.UI:CreateStyledButton(card, RCL["Reset Position"], 120, 24)
                resetBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy - 2)
                resetBtn:SetScript("OnClick", function()
                    if RC.fastWeaponReminder and RC.fastWeaponReminder.frame then
                        RC.Position.ResetFrame(RC.fastWeaponReminder.frame)
                    else
                        db.anchorPoint = "CENTER"
                        db.xOffset = 0
                        db.yOffset = 200
                        db.centred = true
                        RC:SaveConfigurationToProfile()
                    end
                    RC.UI:NotifySettingChanged("reset")
                end)
                return cy - 32
            end)
        end
        return yPos
    end

    function RC:ShowEquipmentReminderDetectionTab(parent, yPos, frame)
        local cardY

        local detectCard = self:CreateSettingsCard(parent, yPos, RCL["Detection types"])
        cardY = -35

        local detectHint = self:CreateFontString(detectCard, "OVERLAY", nil, 10)
        detectHint:SetPoint("TOPLEFT", detectCard, "TOPLEFT", 15, cardY)
        detectHint:SetText(RCL["Enable each type and choose when to show the warning:"])
        detectHint:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
        cardY = cardY - 25

        local checks = {
            {key = "detectFastWeapons",    condKey = "detectFastWeaponsCondition",    label = RCL["Fast Weapons (speed < 2.0s)"]},
            {key = "detectShields",        condKey = "detectShieldsCondition",        label = RCL["Shields"]},
            {key = "detectHealingWeapons", condKey = "detectHealingWeaponsCondition", label = RCL["Healing Weapons"]},
            {key = "detectWrathGear",      condKey = "detectWrathGearCondition",      label = RCL["Wrath Gear (T2 tank set)"]},
            {key = "detectUtilityItems",   condKey = "detectUtilityItemsCondition",   label = RCL["Utility & On-Use Gear (Boots, Skull, Belt, Hauberk)"]},
            {key = "detectCustomItems",    condKey = "detectCustomItemsCondition",    label = RCL["Custom Items"]},
            {key = "detectDaggerInOffhand",condKey = "detectDaggerInOffhandCondition",label = RCL["Kingsfall / Claw in Offhand"]},
        }
        if RC.Flavor and RC:Flavor() ~= "era" then
            for i = #checks, 1, -1 do
                local k = checks[i].key
                if k == "detectWrathGear" or k == "detectDaggerInOffhand" then table.remove(checks, i) end
            end
        end

        local checkDefaults = {
            detectFastWeapons = true, detectShields = true,
            detectHealingWeapons = true, detectWrathGear = true,
            detectUtilityItems = true, detectCustomItems = true,
            detectDaggerInOffhand = false,
        }

        local CONDITIONS = {
            {value = "always",   label = RCL["Always"]},
            {value = "boss",     label = RCL["Boss"]},
            {value = "combat",   label = RCL["Combat"]},
            {value = "nocombat", label = RCL["No Combat"]},
        }

        -- btns and CONDITIONS are matched purely by index - condBtns[i] must
        -- have been built from CONDITIONS[i] in the same order below, or
        -- this highlights the wrong button.
        local function RefreshCondBtns(btns, currentCond)
            for i, btn in ipairs(btns) do
                RC.UI:SetButtonConfigured(btn, CONDITIONS[i].value == currentCond)
            end
        end

        for _, info in ipairs(checks) do
            if self.db.fastWeaponReminder[info.key] == nil then
                self.db.fastWeaponReminder[info.key] = checkDefaults[info.key]
            end
            if self.db.fastWeaponReminder[info.condKey] == nil then
                self.db.fastWeaponReminder[info.condKey] = "always"
            end

            local check = self.UI:CreateCheckbox(detectCard, info.label, self.db.fastWeaponReminder[info.key])
            check:SetPoint("TOPLEFT", detectCard, "TOPLEFT", 15, cardY)
            check:SetScript("OnClick", function(cb)
                RC.db.fastWeaponReminder[info.key] = cb:GetChecked()
                RC:ForceCheckboxUpdate(cb, cb:GetChecked())
                if RC.UpdateFastWeaponReminder then RC:UpdateFastWeaponReminder() end
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 24

            local condBtns = {}
            local btnW = 100
            local btnH = 20

            for i, cond in ipairs(CONDITIONS) do
                local btn = self.UI:CreateStyledButton(detectCard, cond.label, btnW, btnH)
                if i == 1 then
                    btn:SetPoint("TOPLEFT", detectCard, "TOPLEFT", 30, cardY)
                else
                    btn:SetPoint("LEFT", condBtns[i-1], "RIGHT", 4, 0)
                end
                condBtns[i] = btn
            end

            cardY = cardY - (btnH + 10)

            for i, btn in ipairs(condBtns) do
                local capturedCond = CONDITIONS[i].value
                local capturedBtns = condBtns
                btn:SetScript("OnClick", function()
                    RC.db.fastWeaponReminder[info.condKey] = capturedCond
                    RefreshCondBtns(capturedBtns, capturedCond)
                    if RC.UpdateFastWeaponReminder then RC:UpdateFastWeaponReminder() end
                    RC:SaveConfigurationToProfile()
                end)
            end

            RefreshCondBtns(condBtns, self.db.fastWeaponReminder[info.condKey])
        end

        cardY = cardY - 8
        detectCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - detectCard:GetHeight() - 15

        local infoCard = self:CreateSettingsCard(parent, yPos, RCL["About"])
        cardY = -35

        cardY = RC.UI:CreateHelpLine(infoCard, 15, cardY,
            RCL["This warns you when wrong gear is equipped:\n\n"] ..
            RCL["|cFFFFD100Fast Weapons:|r PvP daggers that don't scale with buffs\n"] ..
            RCL["|cFFFFD100Shields:|r When you should be dual-wielding or 2H\n"] ..
            RCL["|cFFFFD100Healing Weapons:|r Spell power items on melee\n"] ..
            RCL["|cFFFFD100Wrath Gear:|r T2 tank set pieces\n"] ..
            RCL["|cFFFFD100Custom Items:|r Your own item IDs\n"] ..
            RCL["|cFFFFD100Kingsfall / Claw:|r Naxx OH weapons equipped (off by default)"],
            { short = RCL["Warns you when gear that is wrong for the fight is equipped."], title = RCL["What it checks"] })

        infoCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - infoCard:GetHeight() - 15

        return yPos
    end

    function RC:ShowEquipmentReminderCustomTab(parent, yPos, frame)
        local cardY

        local addCard = self:CreateSettingsCard(parent, yPos, RCL["Add custom item"])
        cardY = -35

        local customHint = self:CreateFontString(addCard, "OVERLAY", nil, 10)
        customHint:SetPoint("TOPLEFT", addCard, "TOPLEFT", 15, cardY)
        customHint:SetWidth(addCard:GetWidth() - 30)
        customHint:SetText(RCL["Add item IDs to trigger a warning. Get IDs from Wowhead URLs."])
        customHint:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
        cardY = cardY - 25

        local idLabel = self:CreateFontString(addCard, "OVERLAY", nil, 11)
        idLabel:SetPoint("TOPLEFT", addCard, "TOPLEFT", 15, cardY)
        idLabel:SetText(RCL["Item ID:"])
        idLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

        local itemIdContainer = self.UI:CreateStyledEditBox(addCard, {
            width = 80, height = 22,
        })
        itemIdContainer:SetPoint("LEFT", idLabel, "RIGHT", 10, 0)
        local itemIdInput = itemIdContainer.editBox
        itemIdInput:SetNumeric(true)
        cardY = cardY - 30

        local labelLabel = self:CreateFontString(addCard, "OVERLAY", nil, 11)
        labelLabel:SetPoint("TOPLEFT", addCard, "TOPLEFT", 15, cardY)
        labelLabel:SetText(RCL["Label:"])
        labelLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

        local labelInputContainer = self.UI:CreateStyledEditBox(addCard, {
            width       = 120,
            height      = 22,
            maxLetters  = 20,
            initialText = "CUSTOM",
        })
        labelInputContainer:SetPoint("LEFT", labelLabel, "RIGHT", 10, 0)
        local labelInput = labelInputContainer.editBox
        cardY = cardY - 35

        local addBtn = self.UI:CreateStyledButton(addCard, RCL["Add Item"], 100, 26)
        addBtn:SetPoint("TOPLEFT", addCard, "TOPLEFT", 15, cardY)
        addBtn:SetScript("OnClick", function()
            local itemId = tonumber(itemIdInput:GetText())
            local label = labelInput:GetText()
            if not itemId or itemId == 0 then
                RC:Print(RCL["Enter a valid item ID"])
                return
            end
            if label == "" then label = "CUSTOM" end

            local success, itemName = RC:AddCustomEquipmentItem(itemId, label:upper())
            if success then
                itemIdInput:SetText("")
                labelInput:SetText("CUSTOM")
                self:ShowSidebarFastWeaponConfig(frame, "custom")
            end
        end)
        cardY = cardY - 35

        addCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - addCard:GetHeight() - 15

        local listCard = self:CreateSettingsCard(parent, yPos, RCL["Current custom items"])
        cardY = -35

        local customCount = RC:GetCustomEquipmentItemCount()
        if customCount > 0 then
            for itemId, itemData in pairs(self.db.fastWeaponReminder.customItems) do
                local itemRow = CreateFrame("Frame", nil, listCard)
                itemRow:SetPoint("TOPLEFT", listCard, "TOPLEFT", 15, cardY)
                itemRow:SetSize(listCard:GetWidth() - 30, 26)

                local icon = itemRow:CreateTexture(nil, "ARTWORK")
                icon:SetSize(22, 22)
                icon:SetPoint("LEFT", 0, 0)
                local iconTex = GetItemIcon(itemId)
                icon:SetTexture(iconTex or "Interface\\Icons\\INV_Misc_QuestionMark")
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                local itemText = self:CreateFontString(itemRow, "OVERLAY", nil, 10)
                itemText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
                itemText:SetText(string.format("[%s] %s", itemData.label or "CUSTOM", itemData.name or "ID:" .. itemId))
                itemText:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])

                local removeBtn = self.UI:CreateRemoveButton(itemRow, 20, function()
                    RC:RemoveCustomEquipmentItem(itemId)
                    self:ShowSidebarFastWeaponConfig(frame, "custom")
                end)
                removeBtn:SetPoint("RIGHT", 0, 0)

                cardY = cardY - 28
            end
        else
            local noItems = self:CreateFontString(listCard, "OVERLAY", nil, 10)
            noItems:SetPoint("TOPLEFT", listCard, "TOPLEFT", 15, cardY)
            noItems:SetText(RCL["No custom items added yet"])
            noItems:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 25
        end

        cardY = cardY - 10
        listCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - listCard:GetHeight() - 15

        return yPos
    end
