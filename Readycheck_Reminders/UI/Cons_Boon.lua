local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbc = RC._sbc or {}
local _sbc = RC._sbc
local TEXT = _sbc.TEXT
------------------------------------------------------------------------
-- Readycheck - Chronoboon Reminder Settings
-- Behavior / Boss Exclusions / Text / Animation tabs for the boon icon in
-- the reminder popup. Edits db.boonReminder (disabledBosses keyed by boss
-- name, label = the icon's text, animationType = its own popup style,
-- nil = the Reminder Settings one). Must poke UpdateBoonReminderAppearance
-- / UpdateBoonReminder after saving so the live reminder picks it up.
-- The old "settings" tab key opens Behavior, so search aliases still land.
-- The preview is the popup's own icon (RC:CreateReminderIcon) as the
-- boon, alone or beside another reminder.
------------------------------------------------------------------------
    local BOON_RAID_BOSSES = {
        { key = "mc",   label = RCL["Molten Core"],           bosses = {
            "Lucifron","Magmadar","Gehennas","Garr","Shazzrah",
            "Baron Geddon","Golemagg the Incinerator","Sulfuron Harbinger",
            "Majordomo Executus","Ragnaros",
        }},
        { key = "bwl",  label = RCL["Blackwing Lair"],        bosses = {
            "Razorgore the Untamed","Vaelastrasz the Corrupt","Broodlord Lashlayer",
            "Firemaw","Ebonroc","Flamegor","Chromaggus","Nefarian",
        }},
        { key = "aq40", label = RCL["Temple of Ahn'Qiraj"],   bosses = {
            "The Prophet Skeram","Silithid Royalty","Battleguard Sartura",
            "Fankriss the Unyielding","Viscidus","Princess Huhuran",
            "Emperor Vek'lor","Emperor Vek'nilash","Ouro","C'Thun",
        }},
        { key = "naxx", label = RCL["Naxxramas"],              bosses = {
            "Anub'Rekhan","Grand Widow Faerlina","Maexxna",
            "Noth the Plaguebringer","Heigan the Unclean","Loatheb",
            "Instructor Razuvious","Gothik the Harvester","Four Horsemen",
            "Patchwerk","Grobbulus","Gluth","Thaddius",
            "Sapphiron","Kel'Thuzad",
        }},
    }

    local function BuildBoonTabBar(self, parent, yPos, frame, selectedTab, tabKeys, tabLabels)
        local tabs = {}
        for i, tabKey in ipairs(tabKeys) do
            tabs[i] = { key = tabKey, label = tabLabels[i] }
        end
        local _, newY = self.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = tabs,
            selected = selectedTab,
            onClick = function(tk)
                frame.boonTab = tk
                RC:ShowSidebarBoonReminderConfig(frame, tk)
            end,
            advance = 34,
        })
        return newY
    end

    local K = RC._rpk
    local BOON_ICON = "Interface\\Icons\\inv_misc_enggizmos_24"
    local PV_W, PV_H = 94, 94   -- one 80 px icon; update sizes the canvas to the icons
    local SAMPLE_OTHER = { key = "deathwish", icon = "Interface\\Icons\\Spell_Shadow_DeathPact", text = "USE", color = "green" }

    local function PreviewList(P)
        local boon = { key = "boon", icon = BOON_ICON, text = RC:GetBoonLabel(), color = "gold" }
        if (P and P.mode) == "with" then return { SAMPLE_OTHER, boon } end
        return { boon }
    end

    local function PreviewBuild(canvas, P)
        local holder = CreateFrame("Frame", nil, canvas)
        holder:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        P.store.holder = holder
        P.store.icons = {}
    end

    -- the popup's own icons, laid out as the popup lays them out
    local function PreviewUpdate(canvas, P)
        local st, db = P.store, RC.db
        local list = PreviewList(P)
        local size = math.max(8, db.iconSize or 80)
        local spacing = db.iconSpacing or 5
        local n = #list
        local totalW = n * size + (n - 1) * spacing
        -- the icons at their real size; the canvas is their box
        K.FitStrip(P, st.holder, totalW + 14, size + 14, 0)
        for i, sample in ipairs(list) do
            local icon = st.icons[i]
            if not icon then icon = RC:CreateReminderIcon(st.holder, size); st.icons[i] = icon end
            icon:SetSize(size, size)
            icon.originalSize = size
            RC.UI:DressReadyIcon(icon, size)
            icon.texture:SetTexture(sample.icon)
            icon:ClearAllPoints()
            icon:SetPoint("CENTER", st.holder, "CENTER", (i - 1 - (n - 1) / 2) * (size + spacing), 0)
            icon:Show()
            if db.showIconText then
                RC:EnsureReminderIconText(icon)
                icon.cooldownText:SetWidth(size)
                RC:SetReminderIconLabel(icon, sample.text, sample.color)
                icon.cooldownText:Show()
            elseif icon.cooldownText then
                icon.cooldownText:Hide()
            end
            RC.UI:SetReadyIconGlow(icon, db.iconGlow or "pulse")
        end
        for i = n + 1, #st.icons do st.icons[i]:Hide() end
    end

    local function PreviewReplay(canvas, P)
        local st = P.store
        local keys = {}
        for i, s in ipairs(PreviewList(P)) do keys[i] = s.key end
        K.Replay(st, canvas, { { frame = st.holder,
            inSpec = RC:GetReminderMotion("in", keys), outSpec = RC:GetReminderMotion("out", keys) } })
    end

    function RC:ShowSidebarBoonReminderConfig(frame, selectedTab)
        -- A non-nil selectedTab means this call came from a tab click, not the
        -- initial open - treat it as a scroll-preserving redraw (see
        -- RestoreScrollPosition at the bottom of this function).
        local isTabSwitch = (selectedTab ~= nil)
        self:ClearSidebarContent(self.sidebarConfigFrame, isTabSwitch)
        selectedTab = K.Tab(selectedTab or frame.boonTab, { settings = "behavior" }, "behavior")
        frame.boonTab = selectedTab

        local parent = frame.scrollChild
        local yPos   = -15

        if not self.db.boonReminder then self.db.boonReminder = {} end
        local db = self.db.boonReminder

        local function Save()
            RC:SaveConfigurationToProfile()
            if RC.UpdateBoonReminderAppearance then RC:UpdateBoonReminderAppearance() end
            if RC.UpdateBoonReminder           then RC:UpdateBoonReminder()           end
        end

        local P
        if self.CreateReminderIcon then
            P = self.UI:DeclarePreview({
                key = "boon.popup", title = RCL["Chronoboon reminder"],
                width = PV_W, height = PV_H,
                build = PreviewBuild, update = PreviewUpdate, replay = PreviewReplay,
                modes = { { id = "alone", label = RCL["Boon alone"] }, { id = "with", label = RCL["With another reminder"] } },
            })
        end

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Chronoboon Reminder"],
            RCL["Shows a boon icon when you have stored world buffs"], "Interface\\Icons\\inv_misc_enggizmos_24")
        yPos = newY

        local tabKeys   = { "behavior", "bosses", "text", "animation" }
        local tabLabels = { RCL["Behavior"], RCL["Boss Exclusions"], RCL["Text"], RCL["Animation"] }
        yPos = BuildBoonTabBar(self, parent, yPos, frame, selectedTab, tabKeys, tabLabels)

        if selectedTab == "text" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Icon text"])
            local cardY = -32
            K.Label(card, 14, cardY, RCL["Text under the boon icon"])
            cardY = cardY - 20
            local eb = self.UI:CreateBackedEditBox(card, { width = 200, height = 22, fontSize = 11, insets = 6, maxLetters = 16 })
            eb:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            eb:SetText(db.label or "")
            local function Commit(box)
                local t = (box:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                local was = db.label
                db.label = (t ~= "") and t or nil
                if was ~= db.label then Save() return true end
            end
            -- Enter raises the change signal itself; leaving the box does not
            eb:SetScript("OnEnterPressed", function(box) Commit(box); box:ClearFocus() end)
            eb:HookScript("OnEditFocusLost", function(box)
                if Commit(box) then RC.UI:NotifySettingChanged("editbox") end
            end)
            local resetBtn = self.UI:CreateStyledButton(card, RCL["Reset"], 70, 22)
            resetBtn:SetPoint("LEFT", eb, "RIGHT", 8, 0)
            resetBtn:SetScript("OnClick", function()
                db.label = nil
                eb:SetText("")
                Save()
                RC.UI:NotifySettingChanged("reset")
            end)
            cardY = cardY - 30
            cardY = K.Desc(card, cardY, RCL["Press Enter to apply. Empty reads 'unboon'. The font, size and colour are shared by every reminder icon: Reminder Settings > Text."])
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 15

        elseif selectedTab == "animation" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Popup animation"])
            local cardY = -32
            K.Label(card, 14, cardY, RCL["When the boon is in the popup:"])
            cardY = cardY - 20
            local items = { { text = RCL["Global default"], value = "" } }
            for _, st in ipairs(RC.Motion.STYLES) do items[#items + 1] = { text = st.label, value = st.id } end
            local function LabelOf(v)
                for _, it in ipairs(items) do if it.value == v then return it.text end end
                return items[1].text
            end
            local cur = db.animationType and RC.Motion.StyleFromLegacy(db.animationType) or ""
            local dd = self.UI:CreateScrollableDropdown(card, 200, LabelOf(cur), 8)
            dd:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            dd:SetItems(items, function(v)
                db.animationType = (v ~= "") and v or nil
                RC:SaveConfigurationToProfile()
                if P then P.Replay() end
            end)
            dd:SetSelectedValue(cur, LabelOf(cur))
            cardY = cardY - 32
            cardY = K.Desc(card, cardY, RCL["The style the popup appears and goes with while the boon is in it. Global default plays the Reminder Settings animation; its length, easing and direction apply either way. Replay in the preview shows it."])
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 15

        elseif selectedTab == "behavior" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Chronoboon reminder"])
            local cardY = -32

            local hint = self:CreateFontString(card, "OVERLAY", nil, 10)
            hint:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            hint:SetWidth(card:GetWidth() - 30)
            hint:SetText(RCL["Shows the boon icon in the reminder popup when you have Chronoboon stored buffs. Zero overhead when unbooned."])
            hint:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
            hint:SetJustifyH("LEFT")
            cardY = cardY - hint:GetStringHeight() - 12

            local enableCb = self.UI:CreateSettingCheckbox(card, cardY, RCL["Enable Chronoboon reminder"], db.enabled, function(cb) db.enabled = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.enabled); Save() end)
            cardY = cardY - 26
            local enableMark = self.UI:MarkCard(card)

            local mL = self:CreateFontString(card, "OVERLAY", nil, 11)
            mL:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            mL:SetText(RCL["Show when:"])
            mL:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            local modeOpts = {
                { value = "boss",        label = RCL["Targeting a boss"] },
                { value = "trash",       label = RCL["Targeting trash"] },
                { value = "both",        label = RCL["Targeting boss or trash"] },
                { value = "always_raid", label = RCL["Always (while in raid zone)"] },
            }
            local function getModeLabel(v) for _, o in ipairs(modeOpts) do if o.value == v then return o.label end end return "Targeting a boss" end
            local mDD = self.UI:CreateScrollableDropdown(card, 220, getModeLabel(db.mode), 8)
            mDD:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            do
                local modeItems = {}
                for _, opt in ipairs(modeOpts) do
                    table.insert(modeItems, { text = opt.label, value = opt.value })
                end
                mDD:SetItems(modeItems, function(value)
                    db.mode = value; Save()
                end)
                mDD:SetSelectedValue(db.mode, getModeLabel(db.mode))
            end
            cardY = cardY - 42

            local function IsBoonPreviewing()
                if not RC.activeReminderData or not RC.activeReminderData.abilities then return false end
                for _, k in ipairs(RC.activeReminderData.abilities) do
                    if k == "boon" then return true end
                end
                return false
            end

            local isPreviewActive = IsBoonPreviewing()
            local previewBtn = self.UI:CreateStyledButton(card,
                isPreviewActive and RCL["Hide Preview"] or RCL["Preview Reminder"], 140, 24)
            previewBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            previewBtn:SetScript("OnClick", function()
                if IsBoonPreviewing() then
                    if RC.activeReminderData and RC.activeReminderData.abilities then
                        for i = #RC.activeReminderData.abilities, 1, -1 do
                            if RC.activeReminderData.abilities[i] == "boon" then
                                table.remove(RC.activeReminderData.abilities, i)
                            end
                        end
                        if #RC.activeReminderData.abilities == 0 then
                            if RC.SmartDismissReminder then RC:SmartDismissReminder("Boon preview hidden") end
                        elseif RC.UpdateReminderWithRemainingAbilities then
                            RC:UpdateReminderWithRemainingAbilities()
                        end
                    end
                else
                    if RC.ShowReminderForced then
                        RC:ShowReminderForced("unboon", {"boon"}, 8)
                    elseif RC.ShowReminder then
                        RC:ShowReminder("unboon", {"boon"}, 0)
                    end
                end
                RC:ShowSidebarBoonReminderConfig(frame, "behavior")
            end)
            cardY = cardY - 36
            -- (the preview button stays live: it shows the popup either way)
            self.UI:BindDependents(enableCb, { mL, mDD })

            card:SetContentHeight(math.abs(cardY))

            yPos = yPos - card:GetHeight() - 15

        elseif selectedTab == "bosses" then
            local raidTab = frame.boonRaidTab or "naxx"
            frame.boonRaidTab = raidTab

            local raidTabKeys   = {}
            local raidTabLabels = {}
            for _, r in ipairs(BOON_RAID_BOSSES) do
                table.insert(raidTabKeys,   r.key)
                table.insert(raidTabLabels, r.label)
            end

            local rtItems = {}
            for i, rtKey in ipairs(raidTabKeys) do
                rtItems[i] = { key = rtKey, label = raidTabLabels[i] }
            end
            -- Framework segmented control: spans the page between the 10px
            -- insets, equal-width segments that re-lay on resize, selected
            -- raid in the active look. Picking a raid rebuilds this tab.
            self.UI:CreateSegmentedControl(parent, {
                inset = 10, y = yPos, height = 26, spacing = 3,
                -- picks which raid's bosses are listed: navigation, so tabs
                buttons = true,
                items = rtItems, selected = raidTab,
                onSelect = function(key)
                    frame.boonRaidTab = key
                    RC:ShowSidebarBoonReminderConfig(frame, "bosses")
                end,
            })
            yPos = yPos - 34

            if not db.disabledBosses then db.disabledBosses = {} end

            local currentRaidData = nil
            for _, r in ipairs(BOON_RAID_BOSSES) do
                if r.key == raidTab then currentRaidData = r; break end
            end

            if currentRaidData then
                local bossCard = self:CreateSettingsCard(parent, yPos, currentRaidData.label .. RCL[" bosses"])
                local cardY    = -32

                local enableAllBtn = self.UI:CreateStyledButton(bossCard, RCL["Enable All"], 100, 22)
                enableAllBtn:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 14, cardY)
                enableAllBtn:SetScript("OnClick", function()
                    for _, bossName in ipairs(currentRaidData.bosses) do
                        db.disabledBosses[bossName] = nil
                    end
                    RC:SaveConfigurationToProfile()
                    RC:ShowSidebarBoonReminderConfig(frame, "bosses")
                end)

                local disableAllBtn = self.UI:CreateStyledButton(bossCard, RCL["Disable All"], 100, 22)
                disableAllBtn:SetPoint("LEFT", enableAllBtn, "RIGHT", 8, 0)
                disableAllBtn:SetScript("OnClick", function()
                    for _, bossName in ipairs(currentRaidData.bosses) do
                        db.disabledBosses[bossName] = true
                    end
                    RC:SaveConfigurationToProfile()
                    RC:ShowSidebarBoonReminderConfig(frame, "bosses")
                end)
                cardY = cardY - 30

                local hint2 = self:CreateFontString(bossCard, "OVERLAY", nil, 10)
                hint2:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 14, cardY)
                hint2:SetWidth(bossCard:GetWidth() - 30)
                hint2:SetText(RCL["Checked = reminder fires. Uncheck to suppress."])
                hint2:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
                hint2:SetJustifyH("LEFT")
                cardY = cardY - hint2:GetStringHeight() - 8

                for _, bossName in ipairs(currentRaidData.bosses) do
                    local isEnabled = not db.disabledBosses[bossName]
                    local cb = self.UI:CreateCheckbox(bossCard, bossName, isEnabled)
                    cb:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 14, cardY)
                    local bn = bossName
                    cb:SetScript("OnClick", function(s)
                        local checked = s:GetChecked()
                        db.disabledBosses[bn] = checked and nil or true
                        RC:ForceCheckboxUpdate(s, checked)
                        RC:SaveConfigurationToProfile()
                    end)
                    cardY = cardY - 24
                end
                cardY = cardY - 4
                bossCard:SetContentHeight(math.abs(cardY))
                yPos = yPos - bossCard:GetHeight() - 15
            end

        end
        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
        if isTabSwitch then self:RestoreScrollPosition(self.sidebarConfigFrame) end
    end

