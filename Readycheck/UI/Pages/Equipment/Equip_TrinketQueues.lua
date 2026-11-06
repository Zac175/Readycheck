------------------------------------------------------------------------
-- Readycheck - Equipment: Trinket Auto-Swap Queues
-- Configures db.trinketSwap (enabled/autoSwapActive/pauseDuringBossFight,
-- buttonClicks, queues[configKey].slot1/slot2) and the toggle button.
-- Slot queue order is priority: the highest trinket in a slot's list that
-- is ready wins the swap when more than one is ready (Up / Down move it).
-- Or, with trinketSwap.order = "priority", each trinket's own number
-- (trinketSwap.priorities) decides, highest first.
-- Pokes RC:StartTrinketPolling/StopTrinketPolling and
-- RC:SaveConfigurationToProfile on change.
------------------------------------------------------------------------
local pairs, ipairs = pairs, ipairs
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._seq = RC._seq or {}
local _seq = RC._seq
local C, GetCardBg, GetTabHoverBg, TEXT = _seq.C, _seq.GetCardBg, _seq.GetTabHoverBg, _seq.TEXT
    -- The preview: the toggle button itself, built and painted by the
    -- same code as the live one (RC:BuildTrinketToggleFace /
    -- RC:StyleTrinketToggle), with your current queue. One mode per state;
    -- clicking it flips the sample on and off like the real one (the
    -- sample only: your auto-swap is not touched).
    local TPV_W, TPV_H = 90, 36
    local TRINKET_MODES = {
        { id = "on",     label = RCL["On"] },
        { id = "boss",   label = RCL["Boss pause"] },
        { id = "manual", label = RCL["Paused"] },
        { id = "off",    label = RCL["Off"] },
    }
    local STATE_KEYS = {
        on = { "statusActive", "buttonTextOn" }, boss = { "statusPaused", "buttonTextOn" },
        manual = { "statusManualPause", "buttonTextOn" }, off = { "statusDisabled", "buttonTextOff" },
    }

    local function TrinketSampleState(P, hover)
        local m = P.store.flip or P.mode or "on"
        local k = STATE_KEYS[m] or STATE_KEYS.on
        local tss = RC.trinketSwapSystem
        local q = tss and tss.currentQueue
        local icons
        if RC.db.trinketSwap.showQueueIcons ~= false then
            icons = q and RC.GetQueueTrinketIcons and RC:GetQueueTrinketIcons(q) or nil
            if not icons or ((not icons.slot1 or #icons.slot1 == 0) and (not icons.slot2 or #icons.slot2 == 0)) then
                icons = { slot1 = { 133439, 133440 }, slot2 = { 133441 } }
            end
        end
        return { name = (tss and q and tss.queueNames[q]) or "Default", icons = icons,
                 status = RC:GetColor("trinketSwap", k[1]), textColor = RC:GetColor("trinketSwap", k[2]), hover = hover }
    end

    local PREVIEW_MIN_ALPHA = 0.35
    local function PreviewFadeSettings()
        local s = RC._GetTrinketFadeSettings and RC._GetTrinketFadeSettings()
        if not s then return nil end
        return { enabled = s.enabled, alpha = math.max(PREVIEW_MIN_ALPHA, tonumber(s.alpha) or 1) }
    end

    local function TrinketPreviewBuild(canvas, P)
        P.store.fadeSettings = PreviewFadeSettings
        local b = CreateFrame("Button", nil, canvas)
        b:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        RC:BuildTrinketToggleFace(b)
        b:SetScript("OnEnter", function(self) RC:StyleTrinketToggle(self, TrinketSampleState(P, true)) end)
        b:SetScript("OnLeave", function(self) RC:StyleTrinketToggle(self, TrinketSampleState(P, false)) end)
        b:SetScript("OnClick", function(self)
            local cur = P.store.flip or P.mode or "on"
            P.store.flip = (cur == "off") and "on" or "off"
            RC:StyleTrinketToggle(self, TrinketSampleState(P, true))
            RC.Motion.Play(self, RC:TrinketToggleAnim("buttonStateAnim"), "update")
        end)
        -- the sample fades like the live button, but never out of sight: a
        -- fade to 0 left the preview empty (Zac 2026-11-02). Faded, it shows
        -- at least faint; hovering it shows it whole.
        if RC.AttachMouseoverFade then RC:AttachMouseoverFade(b, P.store.fadeSettings) end
        P.store.button = b
        P.store.token = 0
    end

    local function TrinketPreviewUpdate(canvas, P)
        local st = P.store
        if st.lastMode ~= P.mode then st.flip = nil st.lastMode = P.mode end
        local b = st.button
        local sig = tostring(RC.db.trinketSwap.compactButton) .. ":" .. tostring(RC.db.trinketSwap.buttonWidth)
            .. ":" .. tostring(RC.db.trinketSwap.buttonHeight) .. ":" .. tostring(RC.db.trinketSwap.compactSize)
        if st.sig ~= sig then RC.Motion.Stop(b) st.sig = sig end
        RC:StyleTrinketToggle(b, TrinketSampleState(P, b:IsMouseOver()))
        -- the button at its real size; the canvas is its box (the strip
        -- shows it as big as it is in game)
        if b:GetScale() ~= 1 then RC.Motion.Stop(b) b:SetScale(1) end
        local cx, cy, w, h = P.Measure(b)
        if cx then
            local _, _, _, px, py = b:GetPoint(1)
            if math.abs((px or 0) + cx) > 0.5 or math.abs((py or 0) + cy) > 0.5 then
                RC.Motion.Stop(b)
                b:ClearAllPoints()
                b:SetPoint("CENTER", canvas, "CENTER", -cx, -cy)
            end
            P.Resize(w + 12, h + 12)
        end
        if RC.ApplyMouseoverFade then RC:ApplyMouseoverFade(b, PreviewFadeSettings) end
    end

    local function TrinketPreviewReplay(canvas, P)
        local st, M = P.store, RC.Motion
        local b = st.button
        st.token = st.token + 1
        local t = st.token
        M.Stop(b)
        b:Hide()
        local inSpec = RC:TrinketToggleAnim("buttonShowAnim")
        M.Show(b, inSpec)
        C_Timer.After(M.Duration(inSpec.duration + inSpec.delay) + 0.4, function()
            if t ~= st.token or not b:IsVisible() then return end
            M.Play(b, RC:TrinketToggleAnim("buttonStateAnim"), "update")
        end)
    end

    local function DeclareTrinketPreview(self)
        if not (self.BuildTrinketToggleFace and self.StyleTrinketToggle) then return nil end
        return self.UI:DeclarePreview({
            key = "trinket.toggle", title = RCL["Trinket toggle button"],
            width = TPV_W, height = TPV_H,
            build = TrinketPreviewBuild, update = TrinketPreviewUpdate, replay = TrinketPreviewReplay,
            modes = TRINKET_MODES, modesLabel = RCL["State"],
        })
    end

    function RC:ShowSidebarTrinketSwapConfig(frame, preserveScroll)
        local cardY
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local parent = frame.scrollChild
        local yPos = -20
        local P = DeclareTrinketPreview(self)

        local headerFrame, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Trinket Manager"],
            RCL["Configure automatic trinket rotation queues"], "Interface\\Icons\\inv_trinket_naxxramas03")
        yPos = newY

        if not self.trinketSwapSystem or not self.db.trinketSwap then
            local errorCard = self:CreateSettingsCard(parent, yPos, RCL["Error"])
            local cardY = -32
            local errorText = self:CreateFontString(errorCard, "OVERLAY", nil, 11)
            errorText:SetPoint("TOPLEFT", errorCard, "TOPLEFT", 14, cardY)
            errorText:SetText(RCL["Trinket swap system not initialized. Please /reload."])
            errorText:SetTextColor(TEXT.red[1], TEXT.red[2], TEXT.red[3])
            errorCard:SetContentHeight(50)
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            return
        end

        local tmLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded
                and C_AddOns.IsAddOnLoaded("TrinketMenu"))
            or (IsAddOnLoaded and IsAddOnLoaded("TrinketMenu"))
            or (_G.TrinketMenu ~= nil)
        if tmLoaded then
            local warnCard = self:CreateSettingsCard(parent, yPos, RCL["TrinketMenu detected"])
            local warnText = self:CreateFontString(warnCard, "OVERLAY", nil, 10)
            warnText:SetPoint("TOPLEFT", warnCard, "TOPLEFT", 14, -35)
            warnText:SetPoint("RIGHT", warnCard, "RIGHT", -14, 0)
            warnText:SetJustifyH("LEFT")
            warnText:SetText(RCL["The TrinketMenu addon also swaps trinkets automatically. "]
                .. RCL["Two automatic swappers will fight over the same slots - use "]
                .. RCL["auto-queues in only one of them."])
            do local _c = RC:GetColor("text", "warning") or { r = 1, g = 0.8, b = 0.2 }
                warnText:SetTextColor(_c.r, _c.g, _c.b) end
            warnCard:SetContentHeight(70)
            yPos = yPos - 78
        end

        RC.trinketSwapTab = RC.trinketSwapTab or "behavior"
        local _meshOnTrinket = (function()
            local t = ReadycheckDB and ReadycheckDB.meshSyncEnabledPerChar
            if not t then return false end
            -- Normalized toon key, same as every mesh table (Mesh_Proto).
            local k = (RC._mss and RC._mss.GetToonKey and RC._mss.GetToonKey())
                or ((UnitName("player") or "") .. "-" .. (GetRealmName() or ""))
            return t[k] == true
        end)()
        if RC.trinketSwapTab == "remote" and not _meshOnTrinket then
            RC.trinketSwapTab = "behavior"
        end
        -- Behavior, the queues, then the toggle button's Look / Text /
        -- Animation / Position. Old keys (search aliases) still land.
        local trinketSwapTabs = {
            { "behavior",  RCL["Behavior"]  },
            { "queues",    RCL["Queues"]    },
            { "look",      RCL["Look"]      },
            { "text",      RCL["Text"]      },
            { "animation", RCL["Animation"] },
            { "position",  RCL["Position"]  },
            { "help",      RCL["Help"]      },
        }
        if _meshOnTrinket then
            table.insert(trinketSwapTabs, 7, { "remote", RCL["Remote"] })
        end
        RC.trinketSwapTab = _seq.Look.TabKey(RC.trinketSwapTab, trinketSwapTabs,
            { main = "behavior", button = "look" }, "behavior")
        yPos = self:BuildSettingsTabBar(parent, yPos, trinketSwapTabs, RC.trinketSwapTab, function(k)
            RC.trinketSwapTab = k
            RC:ShowSidebarTrinketSwapConfig(frame, true)
        end)

        if RC.trinketSwapTab == "behavior" then
        local enableCard = self:CreateSettingsCard(parent, yPos, RCL["Trinket auto-swap"])
        local cardY = -32

        local enableCheck = self.UI:CreateSettingCheckbox(enableCard, cardY, "Enable Trinket System", self.db.trinketSwap.enabled, function(cb)
            local newState = cb:GetChecked()
            RC.db.trinketSwap.enabled = newState
            RC:ForceCheckboxUpdate(cb, newState)
            if newState then
                if RC.db.trinketSwap.autoSwapActive == nil then
                    RC.db.trinketSwap.autoSwapActive = true
                end
                RC:StartTrinketPolling()
                -- Skips the immediate apply while in combat; polling still
                -- starts, so the next ready-trinket check picks it up once
                -- combat ends instead of equipping right here.
                if not InCombatLockdown() then
                    C_Timer.After(0.3, function()
                        RC:EquipTrinketsFromConfig()
                    end)
                end
            else
                RC:StopTrinketPolling()
            end
            RC:SaveConfigurationToProfile()
            if RC.db.trinketSwap.showToggleButton and RC.trinketToggleButton then
                if newState then
                    RC.trinketToggleButton:Show()
                else
                    RC.trinketToggleButton:Hide()
                end
            end
            C_Timer.After(0.05, function()
                RC:ShowSidebarTrinketSwapConfig(frame)
            end)
        end)
        cardY = cardY - 28

        local autoSwapValue = self.db.trinketSwap.autoSwapActive
        if autoSwapValue == nil then autoSwapValue = true end
        local autoSwapCheck = self.UI:CreateCheckbox(enableCard, RCL["Auto-swap trinkets when ready"], autoSwapValue)
        autoSwapCheck:SetPoint("TOPLEFT", enableCard, "TOPLEFT", 14, cardY)
        autoSwapCheck:SetScript("OnClick", function(cb)
            local newState = cb:GetChecked()
            RC.db.trinketSwap.autoSwapActive = newState
            RC:ForceCheckboxUpdate(cb, newState)

            -- Manually touching this checkbox cancels any in-progress boss-fight
            -- auto-pause, so the pause logic doesn't later "resume" over the
            -- user's explicit choice.
            if RC.trinketBossPauseState then
                RC.trinketBossPauseState.pausedByBossFight = false
                RC.trinketBossPauseState.originalAutoSwapState = nil
            end
            if RC.db.trinketSwap then RC.db.trinketSwap.bossPausedAutoSwap = nil end

            RC:SaveConfigurationToProfile()

            if RC.trinketToggleButton then
                RC:UpdateTrinketToggleButtonState()
            end
        end)
        cardY = cardY - 22

        local autoSwapHint = self:CreateFontString(enableCard, "OVERLAY", nil, 10)
        autoSwapHint:SetPoint("TOPLEFT", enableCard, "TOPLEFT", 35, cardY)
        autoSwapHint:SetText(RCL["When off, system monitors trinkets but doesn't swap them"])
        autoSwapHint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
        cardY = cardY - 20

        local pauseDuringBossValue = self.db.trinketSwap.pauseDuringBossFight
        if pauseDuringBossValue == nil then pauseDuringBossValue = false end
        local pauseBossCheck = self.UI:CreateCheckbox(enableCard, RCL["Pause auto-swap during boss fights"], pauseDuringBossValue)
        pauseBossCheck:SetPoint("TOPLEFT", enableCard, "TOPLEFT", 14, cardY)
        pauseBossCheck:SetScript("OnClick", function(cb)
            local newState = cb:GetChecked()
            RC.db.trinketSwap.pauseDuringBossFight = newState
            RC:ForceCheckboxUpdate(cb, newState)
            RC:SaveConfigurationToProfile()
        end)
        cardY = cardY - 22

        local pauseHint = self:CreateFontString(enableCard, "OVERLAY", nil, 10)
        pauseHint:SetPoint("TOPLEFT", enableCard, "TOPLEFT", 35, cardY)
        pauseHint:SetText(RCL["Automatically pauses swapping when fighting a raid boss, resumes after"])
        pauseHint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
        cardY = cardY - 18
        -- the boss pause only matters while auto-swap is on, and both only
        -- while the system is on (the bag scan stays live)
        self.UI:BindDependents(autoSwapCheck, { pauseBossCheck, pauseHint })
        self.UI:BindDependents(enableCheck, { autoSwapCheck, autoSwapHint, pauseBossCheck, pauseHint })


        local scanBtn = self.UI:CreateStyledButton(enableCard, RCL["Scan Bags for Trinkets"], 160, 26)
        scanBtn:SetPoint("TOPLEFT", enableCard, "TOPLEFT", 14, cardY)
        scanBtn:SetScript("OnClick", function()
            RC:ScanAvailableTrinkets()
        end)
        cardY = cardY - 35

        enableCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - enableCard:GetHeight() - 15


        -- What each click on the toggle button does.
        local clickCard = self:CreateSettingsCard(parent, yPos, RCL["Toggle button clicks"])
        cardY = -32
        local bcLabel = self:CreateFontString(clickCard, "OVERLAY", nil, 11)
        bcLabel:SetPoint("TOPLEFT", clickCard, "TOPLEFT", 14, cardY)
        bcLabel:SetText(RCL["Button clicks:"])
        bcLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
        cardY = cardY - 18

        local bcHint = self:CreateFontString(clickCard, "OVERLAY", nil, 10)
        bcHint:SetPoint("TOPLEFT", clickCard, "TOPLEFT", 14, cardY)
        bcHint:SetWidth(clickCard:GetWidth() - 30)
        bcHint:SetJustifyH("LEFT")
        bcHint:SetText(RCL["Defaults: Left = Toggle, Right = Menu, Middle = Hide, Alt+Left = Lock. Add a click below to override it."])
        bcHint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
        cardY = cardY - 24

        local tbcOptions = {
            { text = RCL["Toggle ON/OFF"], value = "toggle" },
            { text = RCL["Open Menu"],     value = "menu"   },
            { text = RCL["Hide Button"],   value = "hide"   },
            { text = RCL["Lock/Unlock"],   value = "lock"   },
            { text = RCL["Nothing"],       value = "none"   },
        }
        local function _tbcLabel(v)
            for _, o in ipairs(tbcOptions) do if o.value == v then return o.text end end
            return "Nothing"
        end
        local tbcSlots = {
            { key = "left",        label = RCL["Left-click"]     },
            { key = "right",       label = RCL["Right-click"]    },
            { key = "middle",      label = RCL["Middle-click"]   },
            { key = "altLeft",     label = RCL["Alt + Left"]     },
            { key = "altRight",    label = RCL["Alt + Right"]    },
            { key = "altMiddle",   label = RCL["Alt + Middle"]   },
            { key = "ctrlLeft",    label = RCL["Ctrl + Left"]    },
            { key = "ctrlRight",   label = RCL["Ctrl + Right"]   },
            { key = "ctrlMiddle",  label = RCL["Ctrl + Middle"]  },
            { key = "shiftLeft",   label = RCL["Shift + Left"]   },
            { key = "shiftRight",  label = RCL["Shift + Right"]  },
            { key = "shiftMiddle", label = RCL["Shift + Middle"] },
        }
        self.db.trinketSwap.buttonClicks = self.db.trinketSwap.buttonClicks or {}
        local bc = self.db.trinketSwap.buttonClicks

        for _, cs in ipairs(tbcSlots) do
            local slotKey = cs.key
            if bc[slotKey] ~= nil then
                local lbl = self:CreateFontString(clickCard, "OVERLAY", nil, 11)
                lbl:SetPoint("TOPLEFT", clickCard, "TOPLEFT", 14, cardY)
                lbl:SetText(cs.label)
                lbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

                local dd = self.UI:CreateScrollableDropdown(clickCard, 150, _tbcLabel(bc[slotKey]), 10)
                dd:SetPoint("TOPLEFT", clickCard, "TOPLEFT", 140, cardY + 5)
                dd:SetItems(tbcOptions, function(value)
                    RC.db.trinketSwap.buttonClicks[slotKey] = value
                    RC:SaveConfigurationToProfile()
                end)

                local rm = self.UI:CreateStyledButton(clickCard, "X", 22, 22)
                rm:SetPoint("TOPLEFT", clickCard, "TOPLEFT", 296, cardY + 5)
                rm:SetScript("OnClick", function()
                    RC.db.trinketSwap.buttonClicks[slotKey] = nil
                    RC:SaveConfigurationToProfile()
                    RC:ShowSidebarTrinketSwapConfig(frame, true)
                end)
                cardY = cardY - 30
            end
        end

        local freeSlots = {}
        for _, cs in ipairs(tbcSlots) do
            if bc[cs.key] == nil then
                freeSlots[#freeSlots + 1] = { text = cs.label, value = cs.key }
            end
        end
        if #freeSlots > 0 then
            local addDD = self.UI:CreateScrollableDropdown(clickCard, 150, RCL["Add click..."], 10)
            addDD:SetEmptyText(RCL["Every click is assigned"], RCL["Remove one below to free it up."])
            addDD:SetPoint("TOPLEFT", clickCard, "TOPLEFT", 14, cardY + 2)
            addDD:SetItems(freeSlots, function(value)
                local cur = RC:GetTrinketButtonClicks()
                RC.db.trinketSwap.buttonClicks[value] = cur[value] or "none"
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarTrinketSwapConfig(frame, true)
            end)
            cardY = cardY - 32
        end

        local macroHint = self:CreateFontString(clickCard, "OVERLAY", nil, 10)
        macroHint:SetPoint("TOPLEFT", clickCard, "TOPLEFT", 14, cardY)
        macroHint:SetWidth(clickCard:GetWidth() - 30)
        macroHint:SetJustifyH("LEFT")
        macroHint:SetText(RCL["Macros: /rc equip(Kiss of the Spider,13) equips that item - or queues it if you are in combat. Works for every gear slot; 13 and 14 are your trinkets."])
        macroHint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
        cardY = cardY - 30
        cardY = cardY - 4

        clickCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - clickCard:GetHeight() - 15
        yPos = self.UI:FrameVisibilityCard(parent, yPos, function() return RC.db.trinketSwap end, function() if RC.trinketToggleButton then RC:StyleTrinketToggle(RC.trinketToggleButton, RC:TrinketToggleLiveState()) end end,
            { title = RCL["Toggle button fade and opacity"] })

        elseif RC.trinketSwapTab == "queues" then
        local queuesCard = self:CreateSettingsCard(parent, yPos, RCL["Trinket rotation queues"])
        cardY = -32

        local queueInfo = self:CreateFontString(queuesCard, "OVERLAY", nil, 10)
        queueInfo:SetPoint("TOPLEFT", queuesCard, "TOPLEFT", 14, cardY)
        queueInfo:SetWidth(queuesCard:GetWidth() - 30)
        queueInfo:SetText(RCL["Configure separate rotation queues for each trinket slot. The system cycles through trinkets based on cooldowns."])
        queueInfo:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
        cardY = cardY - 30

        local currentQueueName = self.trinketSwapSystem.queueNames[self.trinketSwapSystem.currentQueue] or "Default"
        -- Label and value are two font strings so the value follows the
        -- theme (text.success) instead of an inline colour code.
        local activeText = self:CreateFontString(queuesCard, "OVERLAY", nil, 11)
        activeText:SetPoint("TOPLEFT", queuesCard, "TOPLEFT", 14, cardY)
        activeText:SetText(RCL["Active Queue:"])
        activeText:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
        local activeValue = self:CreateFontString(queuesCard, "OVERLAY", nil, 11)
        activeValue:SetPoint("LEFT", activeText, "RIGHT", 4, 0)
        activeValue:SetText(currentQueueName)
        do local _ok = RC:GetColor("text", "success"); activeValue:SetTextColor(_ok.r, _ok.g, _ok.b, 1) end
        cardY = cardY - 25

        for _, queueKey in ipairs(self.trinketSwapSystem.queueOrder) do
            local cardBg = GetCardBg()
            local queueFrame = CreateFrame("Frame", nil, queuesCard, "BackdropTemplate")
            queueFrame:SetHeight(32)
            queueFrame:SetPoint("TOPLEFT", queuesCard, "TOPLEFT", 14, cardY)
            queueFrame:SetPoint("RIGHT", queuesCard, "RIGHT", -14, 0)
            queueFrame:SetBackdrop({
                bgFile = RC.UI.FLAT,
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                edgeSize = 1,
            })
            queueFrame:SetBackdropColor(cardBg.r, cardBg.g, cardBg.b, 1)
            do local _bn = RC:GetColor("ui", "borderNormal"); queueFrame:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
            local renameBtn = self.UI:CreateStyledButton(queueFrame, RCL["Rename"], 55, 24)
            renameBtn:SetPoint("RIGHT", queueFrame, "RIGHT", -5, 0)
            renameBtn:SetScript("OnClick", function()
                frame.trinketConfigState = { renamingQueue = queueKey }
                RC:ShowSidebarRenameQueue(frame)
            end)

            local isActive = (self.trinketSwapSystem.currentQueue == queueKey)
            local leftmostBtn = renameBtn

            if not isActive then
                local activateBtn = self.UI:CreateStyledButton(queueFrame, RCL["Activate"], 60, 24)
                activateBtn:SetPoint("RIGHT", renameBtn, "LEFT", -5, 0)
                activateBtn:SetScript("OnClick", function()
                    RC:SetActiveQueue(queueKey)
                    C_Timer.After(0.1, function()
                        RC:ShowSidebarTrinketSwapConfig(frame)
                    end)
                end)

                local configBtn = self.UI:CreateStyledButton(queueFrame, RCL["Configure"], 70, 24)
                configBtn:SetPoint("RIGHT", activateBtn, "LEFT", -5, 0)
                configBtn:SetScript("OnClick", function()
                    frame.trinketConfigState = { selectedQueue = queueKey }
                    RC:ShowSidebarQueueConfiguration(frame)
                end)
                leftmostBtn = configBtn
            else
                local configBtn = self.UI:CreateStyledButton(queueFrame, RCL["Configure"], 70, 24)
                configBtn:SetPoint("RIGHT", renameBtn, "LEFT", -5, 0)
                configBtn:SetScript("OnClick", function()
                    frame.trinketConfigState = { selectedQueue = queueKey }
                    RC:ShowSidebarQueueConfiguration(frame)
                end)
                leftmostBtn = configBtn
            end

            local queueName = self.trinketSwapSystem.queueNames[queueKey] or queueKey
            local queueText = self:CreateFontString(queueFrame, "OVERLAY", nil, 11)
            queueText:SetPoint("LEFT", queueFrame, "LEFT", 10, 0)
            queueText:SetJustifyH("LEFT")
            queueText:SetWordWrap(false)
            queueText:SetText(queueName)
            queueText:SetTextColor(TEXT.white[1], TEXT.white[2], TEXT.white[3])

            -- Status and active tag are separate font strings coloured from
            -- the theme (text.success / text.disabled), not inline codes.
            local isPopulated = self:IsConfigPopulated(queueKey)
            local statusText = self:CreateFontString(queueFrame, "OVERLAY", nil, 11)
            statusText:SetPoint("LEFT", queueText, "RIGHT", 5, 0)
            statusText:SetWordWrap(false)
            if isPopulated then
                statusText:SetText(RCL["(Configured)"])
                local _ok = RC:GetColor("text", "success"); statusText:SetTextColor(_ok.r, _ok.g, _ok.b, 1)
            else
                statusText:SetText(RCL["(Empty)"])
                local _dim = RC:GetColor("text", "disabled"); statusText:SetTextColor(_dim.r, _dim.g, _dim.b, 1)
            end

            if isActive then
                local activeTag = self:CreateFontString(queueFrame, "OVERLAY", nil, 11)
                activeTag:SetPoint("LEFT", statusText, "RIGHT", 5, 0)
                activeTag:SetPoint("RIGHT", leftmostBtn, "LEFT", -10, 0)
                activeTag:SetJustifyH("LEFT")
                activeTag:SetWordWrap(false)
                activeTag:SetText(RCL["[ACTIVE]"])
                local _ok = RC:GetColor("text", "success"); activeTag:SetTextColor(_ok.r, _ok.g, _ok.b, 1)
                local selCol = RC:GetColor("ui", "borderSelected")
                queueFrame:SetBackdropBorderColor(selCol.r, selCol.g, selCol.b, 1)
                do local _cb = RC:GetColor("buttons", "configuredBackground"); queueFrame:SetBackdropColor(_cb.r, _cb.g, _cb.b, 1) end
            end

            cardY = cardY - 36
        end

        cardY = cardY - 5
        queuesCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - queuesCard:GetHeight() - 15

        elseif RC.trinketSwapTab == "look" then
        local L = _seq.Look
        local ts = self.db.trinketSwap
        local D = RC.TRINKET_TOGGLE or { width = 75, height = 22, compactSize = 24, iconSize = 9, stripe = 2 }
        local function Apply()
            if RC.trinketToggleButton and RC.trinketToggleButton.UpdateButtonState then
                RC.trinketToggleButton.UpdateButtonState()
            end
        end
        yPos = L.Card(parent, yPos, RCL["Toggle button"], function(card, cy)
            cy = L.Check(card, cy, RCL["Use the compact button (icon only)"], ts.compactButton, function(on)
                ts.compactButton = on
                if RC.UpdateTrinketButtonCompactMode then RC:UpdateTrinketButtonCompactMode() end
                RC:SaveConfigurationToProfile()
            end)
            cy = L.Check(card, cy, RCL["Show trinket icons (button + dropdown)"], ts.showQueueIcons ~= false, function(on)
                ts.showQueueIcons = on
                if RC.trinketDropdownMenu and RC.trinketDropdownMenu:IsShown() then RC.trinketDropdownMenu:Hide() end
                Apply()
                RC:SaveConfigurationToProfile()
            end)
            cy = L.Slider(card, cy - 4, { label = RCL["Width"], min = 50, max = 200, step = 1,
                value = tonumber(ts.buttonWidth) or D.width, fmt = function(v) return v .. RCL[" px"] end,
                set = function(v) ts.buttonWidth = v Apply() end })
            cy = L.Slider(card, cy, { label = RCL["Height"], min = 14, max = 48, step = 1,
                value = tonumber(ts.buttonHeight) or D.height, fmt = function(v) return v .. RCL[" px"] end,
                set = function(v) ts.buttonHeight = v Apply() end })
            cy = L.Slider(card, cy, { label = RCL["Compact button size"], min = 16, max = 48, step = 1,
                value = tonumber(ts.compactSize) or D.compactSize, fmt = function(v) return v .. RCL[" px"] end,
                set = function(v) ts.compactSize = v Apply() end })
            cy = L.Slider(card, cy, { label = RCL["Trinket icon size"], min = 6, max = 20, step = 1,
                value = tonumber(ts.queueIconSize) or D.iconSize, fmt = function(v) return v .. RCL[" px"] end,
                set = function(v) ts.queueIconSize = v Apply() end })
            cy = L.Slider(card, cy, { label = RCL["Status stripe width"], min = 0, max = 8, step = 1,
                value = tonumber(ts.stripeWidth) or D.stripe, fmt = function(v) return v .. RCL[" px"] end,
                set = function(v) ts.stripeWidth = v Apply() end })
            cy = L.OwnColor(card, cy, ts, "buttonBgColor", RCL["Background"],
                function() return RC:GetColor("ui", "elementBackground") end, Apply)
            cy = L.OwnColor(card, cy, ts, "buttonBorderColor", RCL["Border"],
                function() return RC:GetColor("ui", "borderNormal") end, Apply)
            return cy
        end)
        yPos = L.Card(parent, yPos, RCL["Status colours"], function(card, cy)
            cy = L.Desc(card, cy, RCL["The stripe on the left (the arrows on the compact button) shows what auto-swap is doing."])
            cy = L.ThemeColor(card, cy, "trinketSwap", "statusActive", RCL["Swapping"], nil, Apply)
            cy = L.ThemeColor(card, cy, "trinketSwap", "statusPaused", RCL["Paused for a boss"], nil, Apply)
            cy = L.ThemeColor(card, cy, "trinketSwap", "statusManualPause", RCL["Paused by you"], nil, Apply)
            cy = L.ThemeColor(card, cy, "trinketSwap", "statusDisabled", RCL["Off"], nil, Apply)
            return cy
        end)
        yPos = L.Card(parent, yPos, RCL["Fade"], function(card, cy)
            cy = L.Check(card, cy, RCL["Fade the button until you hover it"], ts.mouseoverFade, function(on)
                ts.mouseoverFade = on
                if RC.UpdateTrinketButtonMouseoverFade then RC:UpdateTrinketButtonMouseoverFade() end
                RC:SaveConfigurationToProfile()
            end)
            cy = L.Slider(card, cy - 4, { label = RCL["Faded opacity"], min = 0, max = 100, step = 5,
                value = math.floor((ts.mouseoverFadeAlpha or 0.15) * 100 + 0.5), fmt = function(v) return v .. "%" end,
                set = function(v)
                    ts.mouseoverFadeAlpha = v / 100
                    if RC.UpdateTrinketButtonMouseoverFade then RC:UpdateTrinketButtonMouseoverFade() end
                end })
            return cy
        end)
        yPos = self.UI:FrameChromeCard(parent, yPos, function() return RC.db.trinketSwap end, function() if RC.trinketToggleButton then RC:StyleTrinketToggle(RC.trinketToggleButton, RC:TrinketToggleLiveState()) end end,
            { title = RCL["Toggle button shadow and glow"], fields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })

        elseif RC.trinketSwapTab == "text" then
        local L = _seq.Look
        local ts = self.db.trinketSwap
        local function Apply()
            if RC.trinketToggleButton and RC.trinketToggleButton.UpdateButtonState then
                RC.trinketToggleButton.UpdateButtonState()
            end
        end
        yPos = L.Card(parent, yPos, RCL["Button text"], function(card, cy)
            cy = L.Font(card, cy, ts, "buttonFont", RCL["Queue name"],
                RC.TrinketToggleFontDefaults and RC:TrinketToggleFontDefaults() or { size = 10, outline = "OUTLINE" },
                "Default  AQ40  Naxx", Apply)
            cy = L.ThemeColor(card, cy, "trinketSwap", "buttonTextOn", RCL["Text while on"], nil, Apply)
            cy = L.ThemeColor(card, cy, "trinketSwap", "buttonTextOff", RCL["Text while off"], nil, Apply)
            return L.Desc(card, cy, RCL["Unset, the font follows the Readycheck font one size smaller (9 to 12)."])
        end)

        elseif RC.trinketSwapTab == "animation" then
        local L = _seq.Look
        local ts = self.db.trinketSwap
        local AD = RC.TRINKET_TOGGLE_ANIM or { style = "none", duration = 0.3 }
        yPos = L.Card(parent, yPos, RCL["Toggle button"], function(card, cy)
            cy = L.Anim(card, cy, ts, "buttonShowAnim", RCL["When it appears"], "in", AD, P)
            cy = L.Anim(card, cy, ts, "buttonStateAnim", RCL["When auto-swap turns on, pauses or stops"], "update", AD, P)
            return L.Desc(card, cy, RCL["Click the button in the preview to see it change state."])
        end)

        elseif RC.trinketSwapTab == "position" then
        local L = _seq.Look
        local ts = self.db.trinketSwap
        yPos = L.Card(parent, yPos, RCL["Toggle button"], function(card, cy)
            cy = L.Check(card, cy, RCL["Show the trinket swap toggle button"], ts.showToggleButton, function(on)
                ts.showToggleButton = on
                if on then RC:ShowTrinketToggleButton() else RC:HideTrinketToggleButton() end
                RC:SaveConfigurationToProfile()
            end)
            cy = L.Check(card, cy, RCL["Lock its position"], ts.toggleButtonLocked, function(on)
                ts.toggleButtonLocked = on
                RC:SaveConfigurationToProfile()
            end, RCL["Tip: Alt+Left-click the button to quickly lock/unlock position. It is in Edit Mode too, as Trinket Toggle."])
            local reset = self.UI:CreateStyledButton(card, RCL["Reset position"], 110, 22)
            reset:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy - 2)
            reset:SetScript("OnClick", function()
                ts.toggleButtonPosition = {}
                if RC.trinketToggleButton then RC.Position.RestoreFrame(RC.trinketToggleButton) end
                RC:SaveConfigurationToProfile()
                RC.UI:NotifySettingChanged("reset")
            end)
            return cy - 30
        end)
        yPos = self.UI:FrameLayerCard(parent, yPos, function() return RC.db.trinketSwap end, function() if RC.trinketToggleButton then RC:StyleTrinketToggle(RC.trinketToggleButton, RC:TrinketToggleLiveState()) end end,
            { title = RCL["Toggle button layer and scale"] })

        elseif RC.trinketSwapTab == "help" then
        local helpCard = self:CreateSettingsCard(parent, yPos, RCL["How trinket auto-swap works"])
        cardY = -32

        local helpText = self:CreateFontString(helpCard, "OVERLAY", nil, 10)
        helpText:SetPoint("TOPLEFT", helpCard, "TOPLEFT", 14, cardY)
        helpText:SetWidth(helpCard:GetWidth() - 30)
        helpText:SetJustifyH("LEFT")
        helpText:SetText(
            RCL["The system automatically rotates trinkets for maximum uptime:\n\n"] ..
            RCL["- Configure rotation queues for each slot (Slot 1 = Top, Slot 2 = Bottom)\n"] ..
            RCL["- Create multiple configurations for different situations\n"] ..
            RCL["- Swaps when on-use buff expires and cooldown has time remaining\n"] ..
            RCL["- Replaces passive trinkets with ready on-use trinkets\n"] ..
            RCL["- Pre-equips on-use trinkets 30s before ready"]
        )
        helpText:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
        cardY = cardY - 110

        helpCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - helpCard:GetHeight() - 15
        elseif RC.trinketSwapTab == "remote" then
        local MS        = RC.MeshSync
        local members   = MS and MS:GetMembers() or {}
        local rWarriors = (ReadycheckDB and ReadycheckDB.remoteTrinketWarriors) or {}
        local gearCache = (ReadycheckDB and ReadycheckDB.meshSyncGearCache) or {}
        local myCharKey = RC:GetCharacterKey()
        local ghc       = RC:GetColor("text","gray") or {r=0.5,g=0.5,b=0.5}
        local wc        = RC:GetColor("text","white") or {r=1,g=1,b=1}

        local function NormKey(name)
            if not name then return nil end
            if name:find("-", 1, true) then return name end
            local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
                       or (GetRealmName() or ""):gsub("%s+","")
            return realm ~= "" and (name .. "-" .. realm) or name
        end

        local warriorItems = {}
        local charKeyMap   = {}
        local seenKeys     = {}
        local function addWarrior(ck, displayName, memberRef, isSameAccount)
            if not ck or seenKeys[ck] or ck == myCharKey then return end
            seenKeys[ck] = true
            local sfx = isSameAccount and "  [same account]" or "  [network]"
            warriorItems[#warriorItems+1] = { text = displayName..sfx, value = ck }
            charKeyMap[ck] = { charKey=ck, memberRef=memberRef,
                               isSameAccount=isSameAccount, displayName=displayName }
        end
        if ReadycheckDB and ReadycheckDB.characters then
            for ck in pairs(ReadycheckDB.characters) do
                if ck ~= myCharKey then
                    local cache = gearCache[ck]
                    local lvl   = cache and cache.level or nil
                    if lvl == nil or lvl >= 60 then
                        addWarrior(ck, ck:match("^(.-)%-") or ck, nil, true)
                    end
                end
            end
        end
        for _, m in ipairs(members) do
            addWarrior(NormKey(m.name), m.label or m.name, m, false)
        end
        for ck, r in pairs(rWarriors) do
            addWarrior(ck, r.label or ck, nil, false)
        end

        local selCard = self:CreateSettingsCard(parent, yPos, RCL["Remote warrior"])
        local sy = -30
        frame._remoteTrinketSel = frame._remoteTrinketSel or {}
        local sel = frame._remoteTrinketSel
        if sel.charKey and not charKeyMap[sel.charKey] then
            sel.charKey=nil; sel.label=nil; sel.memberRef=nil; sel.isSameAccount=nil
        end
        local selDisp = sel.charKey and charKeyMap[sel.charKey]
                     and charKeyMap[sel.charKey].displayName or "Select warrior..."
        local selDropW = math.max(180, (selCard:GetWidth() or 400) - 100)
        local selDrop  = self.UI:CreateScrollableDropdown(selCard, selDropW, selDisp, 8)
        selDrop:SetEmptyText(RCL["No other warriors found"], RCL["Mesh members and your other warriors show up here."])
        selDrop:SetPoint("TOPLEFT", selCard, "TOPLEFT", 14, sy)
        selDrop:SetItems(warriorItems, function(value)
            local info = charKeyMap[value]
            if not info then return end
            sel.charKey       = info.charKey
            sel.memberRef     = info.memberRef
            sel.isSameAccount = info.isSameAccount
            sel.label         = info.displayName
            frame._remoteTrinketEdits    = nil
            frame._remoteTrinketConfigKey = nil
            RC:ShowSidebarTrinketSwapConfig(frame)
        end)
        sy = sy - 36
        if sel.charKey then
            local statusLbl = self:CreateFontString(selCard,"OVERLAY",nil,10)
            statusLbl:SetPoint("TOPLEFT",selCard,"TOPLEFT",14,sy)
            statusLbl:SetPoint("RIGHT",  selCard,"RIGHT",  -10,0)
            statusLbl:SetJustifyH("LEFT")
            statusLbl:SetTextColor(ghc.r,ghc.g,ghc.b)
            if sel.isSameAccount then
                statusLbl:SetText(RCL["Same account - reads directly from their saved data."])
            else
                local rw2 = rWarriors[sel.charKey]
                if rw2 and (rw2.lastReceived or 0) > 0 then
                    statusLbl:SetText(string.format(RCL["Network data, %d min ago."],
                        math.floor((GetTime()-rw2.lastReceived)/60)))
                else
                    statusLbl:SetText(RCL["No data yet. Use Refresh when they are online."])
                end
            end
            sy = sy - 18
        end
        local reqBtn = self.UI:CreateStyledButton(selCard, RCL["Refresh from Network"], 155, 24)
        reqBtn:SetPoint("TOPLEFT", selCard, "TOPLEFT", 14, sy)
        if not sel.charKey or sel.isSameAccount then reqBtn:SetAlpha(0.4) end
        reqBtn:SetScript("OnClick", function()
            if sel.isSameAccount or not sel.charKey then return end
            if not MS or not MS:IsEnabled() then
                RC:Print(RCL["Mesh: Not enabled."]); return
            end
            local memRef = sel.memberRef or { name = sel.charKey, label = sel.label }
            if MS.RequestRemoteTrinketData then
                MS:RequestRemoteTrinketData(memRef)
            end
            RC:Print(RCL["Mesh: Trinket data request sent to "] ..
                (sel.label or sel.charKey) .. ".")
        end)
        sy = sy - 32
        selCard:SetContentHeight(math.abs(sy))
        yPos = yPos - selCard:GetHeight() - 10

        local selInfo = sel.charKey and charKeyMap[sel.charKey]
        if selInfo then
            local srcConfig, srcTrinkets, isSameAcct
            isSameAcct = selInfo.isSameAccount

            -- Same-account: read/write ReadycheckDB.characters directly, no
            -- push needed. Network: stage into rWarriors[ck].config and push
            -- explicitly via MS:QueueNetworkTrinketPush.
            if isSameAcct then
                local charProf = ReadycheckDB.characters
                              and ReadycheckDB.characters[sel.charKey]
                srcConfig = charProf and charProf.trinketSwap or nil
                local cache = gearCache[sel.charKey]
                local allItems = (cache and cache.availableItems) or {}
                srcTrinkets = {}
                for _, item in ipairs(allItems) do
                    if item.equipLoc == "INVTYPE_TRINKET" then
                        srcTrinkets[#srcTrinkets+1] = item
                    end
                end
                if not cache then
                    local noteCard = self:CreateSettingsCard(parent, yPos, "")
                    local ny = -20
                    local noteLbl = self:CreateFontString(noteCard,"OVERLAY",nil,10)
                    noteLbl:SetPoint("TOPLEFT",noteCard,"TOPLEFT",12,ny)
                    noteLbl:SetPoint("RIGHT",  noteCard,"RIGHT",  -12,0)
                    noteLbl:SetJustifyH("LEFT")
                    noteLbl:SetTextColor(ghc.r,ghc.g,ghc.b)
                    noteLbl:SetText(RCL["Item picker unavailable: log into "] ..
                        (sel.label or sel.charKey) .. RCL[" once to populate their bag data."])
                    ny = ny - noteLbl:GetStringHeight() - 8
                    noteCard:SetContentHeight(math.abs(ny))
                    yPos = yPos - noteCard:GetHeight() - 6
                end
            else
                local rw3 = rWarriors[sel.charKey]
                if not rw3 then
                    local ndCard = self:CreateSettingsCard(parent, yPos, "")
                    local ny = -25
                    local ndLbl = self:CreateFontString(ndCard,"OVERLAY",nil,10)
                    ndLbl:SetPoint("TOPLEFT",ndCard,"TOPLEFT",14,ny)
                    ndLbl:SetTextColor(ghc.r,ghc.g,ghc.b)
                    ndLbl:SetText(RCL["No data received yet. Click Refresh from Network while they are online."])
                    ny = ny - 20
                    ndCard:SetContentHeight(math.abs(ny))
                    yPos = yPos - ndCard:GetHeight() - 10
                    srcConfig = nil
                else
                    srcConfig   = rw3.config
                    srcTrinkets = rw3.availableTrinkets or {}
                end
            end

            if srcConfig then
                if not frame._remoteTrinketEdits then
                    frame._remoteTrinketEdits = RC.DeepCopy and RC.DeepCopy(srcConfig) or {}
                end
                local edits = frame._remoteTrinketEdits

                -- Fixed key set for the remote editor; it does not read the
                -- live trinketSwapSystem.queueOrder, so it can drift if that
                -- system ever grows configs beyond config1-5.
                local queueOrder   = { "default","config1","config2","config3","config4","config5" }
                local configNames2 = edits.configNames or {}
                frame._remoteTrinketConfigKey = frame._remoteTrinketConfigKey or "default"
                local configKey = frame._remoteTrinketConfigKey
                local cfgItems  = {}
                for _, k in ipairs(queueOrder) do
                    cfgItems[#cfgItems+1] = { text = configNames2[k] or k, value = k }
                end
                local cfgCard = self:CreateSettingsCard(parent, yPos, RCL["Config"])
                local cy2 = -30
                local cfgDrop = self.UI:CreateScrollableDropdown(cfgCard, 220,
                    configNames2[configKey] or configKey, 6)
                cfgDrop:SetPoint("TOPLEFT", cfgCard, "TOPLEFT", 14, cy2)
                cfgDrop:SetItems(cfgItems, function(v)
                    frame._remoteTrinketConfigKey = v
                    RC:ShowSidebarTrinketSwapConfig(frame)
                end)
                cy2 = cy2 - 36
                cfgCard:SetContentHeight(math.abs(cy2))
                yPos = yPos - cfgCard:GetHeight() - 8

                if not edits.queues then edits.queues = {} end
                if not edits.queues[configKey] then
                    edits.queues[configKey] = { slot1 = {}, slot2 = {} }
                end
                local q = edits.queues[configKey]
                q.slot1 = q.slot1 or {}
                q.slot2 = q.slot2 or {}

                local trinketByID = {}
                for _, t in ipairs(srcTrinkets) do
                    trinketByID[t.id] = t
                end

                local function RenderSlotCard(slotKey, slotLabel)
                    local slotCard = self:CreateSettingsCard(parent, yPos, slotLabel)
                    local ky = -32
                    local queue = q[slotKey]

                    for i, itemId in ipairs(queue) do
                        local tinfo  = trinketByID[itemId]
                        local nm     = tinfo and tinfo.name or GetItemInfo(itemId) or ("item:"..itemId)
                        local icon   = tinfo and tinfo.icon

                        local tf = CreateFrame("Frame", nil, slotCard)
                        tf:SetHeight(26)
                        tf:SetPoint("TOPLEFT", slotCard, "TOPLEFT", 14, ky)
                        tf:SetPoint("RIGHT", slotCard, "RIGHT", -14, 0)

                        if icon then
                            local ic = tf:CreateTexture(nil, "ARTWORK")
                            ic:SetSize(20, 20)
                            ic:SetPoint("LEFT", tf, "LEFT", 0, 0)
                            ic:SetTexture(icon)
                        end
                        local nmFs = self:CreateFontString(tf,"OVERLAY",nil,10)
                        nmFs:SetPoint("LEFT",  tf, "LEFT", icon and 24 or 0, 0)
                        nmFs:SetPoint("RIGHT", tf, "RIGHT", -30, 0)
                        nmFs:SetJustifyH("LEFT")
                        nmFs:SetText(nm)
                        nmFs:SetTextColor(wc.r, wc.g, wc.b)

                        local idx2     = i
                        local capSlot  = slotKey
                        local rmBtn = self:CreateXCloseButton(tf, 22, function()
                            table.remove(q[capSlot], idx2)
                            if not isSameAcct and MS and MS.QueueNetworkTrinketPush
                                    and sel.charKey then
                                MS:QueueNetworkTrinketPush(sel.charKey,
                                    frame._remoteTrinketEdits,
                                    sel.label or sel.charKey)
                            elseif isSameAcct and ReadycheckDB
                                    and ReadycheckDB.characters
                                    and ReadycheckDB.characters[sel.charKey] then
                                ReadycheckDB.characters[sel.charKey].trinketSwap =
                                    RC.DeepCopy and RC.DeepCopy(frame._remoteTrinketEdits)
                                    or frame._remoteTrinketEdits
                            end
                            RC:ShowSidebarTrinketSwapConfig(frame)
                        end)
                        rmBtn:SetPoint("RIGHT", tf, "RIGHT", 0, 0)
                        ky = ky - 28
                    end

                    if #srcTrinkets > 0 then
                        local addItems = {}
                        for _, t in ipairs(srcTrinkets) do
                            local already = false
                            for _, id in ipairs(queue) do
                                if id == t.id then already = true; break end
                            end
                            if not already then
                                addItems[#addItems+1] = {
                                    text  = t.name or ("item:"..t.id),
                                    value = t.id,
                                }
                            end
                        end
                        if #addItems > 0 then
                            local addDrop = self.UI:CreateScrollableDropdown(slotCard, 200,
                                RCL["+ Add trinket"], 8)
                            addDrop:SetPoint("TOPLEFT", slotCard, "TOPLEFT", 14, ky)
                            local capSlot2 = slotKey
                            addDrop:SetItems(addItems, function(v)
                                table.insert(q[capSlot2], v)
                                if not isSameAcct and MS and MS.QueueNetworkTrinketPush
                                        and sel.charKey then
                                    MS:QueueNetworkTrinketPush(sel.charKey,
                                        frame._remoteTrinketEdits,
                                        sel.label or sel.charKey)
                                elseif isSameAcct and ReadycheckDB
                                        and ReadycheckDB.characters
                                        and ReadycheckDB.characters[sel.charKey] then
                                    ReadycheckDB.characters[sel.charKey].trinketSwap =
                                        RC.DeepCopy and RC.DeepCopy(frame._remoteTrinketEdits)
                                        or frame._remoteTrinketEdits
                                end
                                RC:ShowSidebarTrinketSwapConfig(frame)
                            end)
                            ky = ky - 36
                        else
                            local allLbl = self:CreateFontString(slotCard,"OVERLAY",nil,10)
                            allLbl:SetPoint("TOPLEFT",slotCard,"TOPLEFT",14,ky)
                            allLbl:SetTextColor(ghc.r,ghc.g,ghc.b)
                            allLbl:SetText(RCL["All available trinkets are already in queue."])
                            ky = ky - 16
                        end
                    else
                        local noTLbl = self:CreateFontString(slotCard,"OVERLAY",nil,10)
                        noTLbl:SetPoint("TOPLEFT",slotCard,"TOPLEFT",14,ky)
                        noTLbl:SetTextColor(ghc.r,ghc.g,ghc.b)
                        noTLbl:SetText(RCL["No trinket data available. Click Refresh from Network first."])
                        ky = ky - 16
                    end

                    slotCard:SetContentHeight(math.abs(ky))
                    yPos = yPos - slotCard:GetHeight() - 8
                end

                RenderSlotCard("slot1", "Slot 1 Queue")
                RenderSlotCard("slot2", "Slot 2 Queue")

                local pushCard = self:CreateSettingsCard(parent, yPos, RCL["Push config"])
                local py = -28
                local pushHint = self:CreateFontString(pushCard,"OVERLAY",nil,10)
                pushHint:SetPoint("TOPLEFT",pushCard,"TOPLEFT",14,py)
                pushHint:SetPoint("RIGHT",  pushCard,"RIGHT",  -14,0)
                pushHint:SetJustifyH("LEFT")
                pushHint:SetTextColor(ghc.r,ghc.g,ghc.b)
                if isSameAcct then
                    pushHint:SetText(RCL["Same account - changes apply immediately on add/remove. Use this to push manually."])
                else
                    pushHint:SetText(RCL["Changes are queued automatically on add/remove. Use this to push manually if needed."])
                end
                py = py - 20
                local pushBtn = self.UI:CreateStyledButton(pushCard, RCL["Push Trinket Config"], 160, 26)
                pushBtn:SetPoint("TOPLEFT", pushCard, "TOPLEFT", 14, py)
                pushBtn:SetScript("OnClick", function()
                    if isSameAcct then
                        if ReadycheckDB and ReadycheckDB.characters
                                and ReadycheckDB.characters[sel.charKey] then
                            ReadycheckDB.characters[sel.charKey].trinketSwap =
                                RC.DeepCopy and RC.DeepCopy(edits) or edits
                            RC:Print(RCL["Mesh: Trinket config written to "] ..
                                (sel.label or sel.charKey) .. ".")
                        end
                    else
                        if MS and MS.QueueNetworkTrinketPush then
                            MS:QueueNetworkTrinketPush(sel.charKey, edits,
                                sel.label or sel.charKey)
                        end
                    end
                end)
                py = py - 36
                pushCard:SetContentHeight(math.abs(py))
                yPos = yPos - pushCard:GetHeight() - 10
            end
        end

        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
        if preserveScroll then
            self:RestoreScrollPosition(self.sidebarConfigFrame)
        end
    end

    function RC:ShowSidebarQueueConfiguration(frame)
        self:ClearSidebarContent(self.sidebarConfigFrame)
        local parent = frame.scrollChild
        local yPos = -20

        if not frame.trinketConfigState or not frame.trinketConfigState.selectedQueue then
            self:ShowSidebarTrinketSwapConfig(frame)
            return
        end

        local queueKey = frame.trinketConfigState.selectedQueue
        local queueName = self.trinketSwapSystem.queueNames[queueKey] or queueKey

        local backButton = self.UI:CreateBackButton(parent, "Back", 80, 28)
        backButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
        backButton:SetScript("OnClick", function()
            frame.trinketConfigState = nil
            RC:ShowSidebarTrinketSwapConfig(frame)
        end)

        local header = self:CreateFontString(parent, "OVERLAY", nil, 16)
        header:SetPoint("LEFT", backButton, "RIGHT", 15, 0)
        header:SetText(RCL["Configure: "] .. queueName)
        header:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
        yPos = yPos - 50

        if #self.trinketSwapSystem.availableTrinkets == 0 then
            self:ScanAvailableTrinkets()
        end

        if not self.db.trinketSwap.queues then
            self.db.trinketSwap.queues = {}
        end
        if not self.db.trinketSwap.queues[queueKey] then
            self.db.trinketSwap.queues[queueKey] = { slot1 = {}, slot2 = {} }
        end

        -- HOW IT PICKS: the list's order, or a priority number per trinket
        -- (RC:GetRankedQueue). The number belongs to the trinket, so it is
        -- the same in both slots and in every config.
        local ts = self.db.trinketSwap
        local byPriority = RC:TrinketOrderIsPriority()
        local orderCard = self:CreateSettingsCard(parent, yPos, RCL["How trinkets are picked"])
        local oy = -32
        self.UI:CreateSegmentedControl(orderCard, {
            x = 14, y = oy, inset = 14, height = 22,
            items = {
                { key = "priority", label = RCL["Priority numbers"],
                  tooltip = RCL["Every trinket has a number; the highest ready one in a slot's list goes on. A trinket's number is the same in both slots and every config."] },
                { key = "list", label = RCL["List order"],
                  tooltip = RCL["The highest trinket in a slot's list that is ready goes on. Move trinkets up and down to change the order."] },
            },
            selected = byPriority and "priority" or "list",
            onSelect = function(key)
                ts.order = key
                ts.orderPicked = true
                RC:SaveConfigurationToProfile()
                RC:ShowSidebarQueueConfiguration(frame)
            end,
        })
        oy = oy - 22 - 8
        local orderHint = self:CreateFontString(orderCard, "OVERLAY", nil, 10)
        orderHint:SetPoint("TOPLEFT", orderCard, "TOPLEFT", 14, oy)
        orderHint:SetPoint("RIGHT", orderCard, "RIGHT", -14, 0)
        orderHint:SetJustifyH("LEFT")
        orderHint:SetWordWrap(true)
        orderHint:SetText(byPriority
            and RCL["Higher number wins. Each list is shown in the order it will be tried. A trinket that is ready to use is never swapped off for one ranked below it."]
            or RCL["Top of the list wins. A trinket that is ready to use is never swapped off for one lower in the list."])
        orderHint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
        oy = oy - math.max(14, orderHint:GetStringHeight() or 14) - 10
        orderCard:SetContentHeight(math.abs(oy))
        yPos = yPos - orderCard:GetHeight() - 15

        local function SlotCard(slotIdx, title)
            local card = self:CreateSettingsCard(parent, yPos, title)
            local cy = -32
            local slotQueue = self.db.trinketSwap.queues[queueKey]["slot" .. slotIdx] or {}
            self.db.trinketSwap.queues[queueKey]["slot" .. slotIdx] = slotQueue

            -- the order rows are shown in: the list, or as they will be tried
            local rows = {}
            for i, itemId in ipairs(slotQueue) do rows[#rows + 1] = { i = i, id = itemId } end
            if byPriority then
                table.sort(rows, function(x, y)
                    local px, py = RC:TrinketPriority(x.id), RC:TrinketPriority(y.id)
                    if px ~= py then return px > py end
                    return x.i < y.i
                end)
            end

            if #rows > 0 then
                for rank, row in ipairs(rows) do
                    local i, itemId = row.i, row.id
                    local itemName, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(itemId)

                    local trinketFrame = CreateFrame("Frame", nil, card)
                    trinketFrame:SetHeight(32)
                    trinketFrame:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                    trinketFrame:SetPoint("RIGHT", card, "RIGHT", -14, 0)

                    local trinketBg = trinketFrame:CreateTexture(nil, "BACKGROUND")
                    trinketBg:SetAllPoints()
                    do local _eb = RC:GetColor("ui", "elementBackground"); trinketBg:SetColorTexture(_eb.r, _eb.g, _eb.b, 1) end
                    RC.UI:CreateSimpleBorder(trinketFrame)

                    local removeBtn = self:CreateXCloseButton(trinketFrame, 24, function()
                        table.remove(slotQueue, i)
                        RC:SaveConfigurationToProfile()
                        RC:ShowSidebarQueueConfiguration(frame)
                    end)
                    removeBtn:SetPoint("RIGHT", trinketFrame, "RIGHT", -5, 0)

                    -- list order: move up / down; priority: the number
                    local rightEdge = removeBtn
                    if byPriority then
                        local box = self.UI:CreateStyledEditBox(trinketFrame, { width = 46, height = 22 })
                        box:SetPoint("RIGHT", removeBtn, "LEFT", -8, 0)
                        local eb = box.editBox
                        eb:SetNumeric(true)
                        eb:SetMaxLetters(3)
                        eb:SetText(tostring(math.floor(RC:TrinketPriority(itemId))))
                        local function Save()
                            local v = tonumber(eb:GetText())
                            if not v then
                                eb:SetText(tostring(math.floor(RC:TrinketPriority(itemId))))
                                return
                            end
                            ts.priorities = ts.priorities or {}
                            if ts.priorities[itemId] == v then return end
                            ts.priorities[itemId] = v
                            RC:SaveConfigurationToProfile()
                            C_Timer.After(0, function() RC:ShowSidebarQueueConfiguration(frame) end)
                        end
                        eb:SetScript("OnEnterPressed", function(e) e:ClearFocus() end)
                        eb:SetScript("OnEditFocusLost", Save)
                        local lbl = self:CreateFontString(trinketFrame, "OVERLAY", nil, 10)
                        lbl:SetPoint("RIGHT", box, "LEFT", -6, 0)
                        lbl:SetText(RCL["Priority"])
                        lbl:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                        rightEdge = lbl
                    else
                        local function Move(delta)
                            local j = i + delta
                            if j < 1 or j > #slotQueue then return end
                            slotQueue[i], slotQueue[j] = slotQueue[j], slotQueue[i]
                            RC:SaveConfigurationToProfile()
                            RC:ShowSidebarQueueConfiguration(frame)
                        end
                        local down = self.UI:CreateStyledButton(trinketFrame, RCL["Down"], 44, 22)
                        down:SetPoint("RIGHT", removeBtn, "LEFT", -8, 0)
                        down:SetScript("OnClick", function() Move(1) end)
                        if i == #slotQueue then down:Disable() down:SetAlpha(0.4) end
                        local up = self.UI:CreateStyledButton(trinketFrame, RCL["Up"], 36, 22)
                        up:SetPoint("RIGHT", down, "LEFT", -4, 0)
                        up:SetScript("OnClick", function() Move(-1) end)
                        if i == 1 then up:Disable() up:SetAlpha(0.4) end
                        rightEdge = up
                    end

                    local icon = trinketFrame:CreateTexture(nil, "ARTWORK")
                    icon:SetSize(24, 24)
                    icon:SetPoint("LEFT", trinketFrame, "LEFT", 5, 0)
                    icon:SetTexture(itemTexture or 134400)
                    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                    local orderText = self:CreateFontString(trinketFrame, "OVERLAY", nil, 11)
                    orderText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
                    orderText:SetPoint("RIGHT", rightEdge, "LEFT", -8, 0)
                    orderText:SetJustifyH("LEFT")
                    orderText:SetWordWrap(false)
                    orderText:SetText("#" .. rank .. ": " .. (itemName or "Loading..."))
                    orderText:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])

                    cy = cy - 36
                end
            else
                local emptyText = self:CreateFontString(card, "OVERLAY", nil, 10)
                emptyText:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                emptyText:SetText(RCL["No trinkets - add below"])
                emptyText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cy = cy - 20
            end

            local addBtn = self.UI:CreateStyledButton(card, RCL["+ Add Trinket"], 100, 26)
            addBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
            addBtn:SetScript("OnClick", function()
                frame.trinketConfigState.addingToSlot = slotIdx
                RC:ShowSidebarAddTrinketToQueue(frame)
            end)
            cy = cy - 35

            card:SetContentHeight(math.abs(cy))
            yPos = yPos - card:GetHeight() - 15
        end

        SlotCard(1, RCL["Slot 1 (Top) Rotation"])
        SlotCard(2, RCL["Slot 2 (Bottom) Rotation"])

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end

    function RC:ShowSidebarAddTrinketToQueue(frame)
        self:ClearSidebarContent(self.sidebarConfigFrame)
        local parent = frame.scrollChild
        local yPos = -20

        if not frame.trinketConfigState then
            self:ShowSidebarTrinketSwapConfig(frame)
            return
        end

        local queueKey = frame.trinketConfigState.selectedQueue
        local slotNum = frame.trinketConfigState.addingToSlot
        local queueName = self.trinketSwapSystem.queueNames[queueKey] or queueKey

        local backButton = self.UI:CreateBackButton(parent, "Back", 80, 28)
        backButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
        backButton:SetScript("OnClick", function()
            frame.trinketConfigState.addingToSlot = nil
            RC:ShowSidebarQueueConfiguration(frame)
        end)

        local header = self:CreateFontString(parent, "OVERLAY", nil, 16)
        header:SetPoint("LEFT", backButton, "RIGHT", 15, 0)
        header:SetText(RCL["Add to Slot "] .. slotNum .. " - " .. queueName)
        header:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
        yPos = yPos - 50

        local trinketsCard = self:CreateSettingsCard(parent, yPos, RCL["Available trinkets"])
        local cardY = -32

        local cardBg = GetCardBg()
        local hoverBg = GetTabHoverBg()

        if #self.trinketSwapSystem.availableTrinkets > 0 then
            for _, trinketData in ipairs(self.trinketSwapSystem.availableTrinkets) do
                local trinketFrame = CreateFrame("Button", nil, trinketsCard, "BackdropTemplate")
                trinketFrame:SetHeight(36)
                trinketFrame:SetPoint("TOPLEFT", trinketsCard, "TOPLEFT", 14, cardY)
                trinketFrame:SetPoint("RIGHT", trinketsCard, "RIGHT", -14, 0)
                trinketFrame:SetBackdrop({
                    bgFile = RC.UI.FLAT,
                    edgeFile = "Interface\\Buttons\\WHITE8X8",
                    edgeSize = 1,
                })
                trinketFrame:SetBackdropColor(cardBg.r, cardBg.g, cardBg.b, 1)
                do local _bn = RC:GetColor("ui", "borderNormal"); trinketFrame:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
                trinketFrame.cardBg = cardBg
                trinketFrame.hoverBg = hoverBg

                local icon = trinketFrame:CreateTexture(nil, "ARTWORK")
                icon:SetSize(28, 28)
                icon:SetPoint("LEFT", trinketFrame, "LEFT", 5, 0)
                local iconTexture = trinketData.icon
                if not iconTexture and trinketData.itemId then
                    local _, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(trinketData.itemId)
                    iconTexture = itemIcon
                end
                icon:SetTexture(iconTexture or 134400)
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                local nameText = self:CreateFontString(trinketFrame, "OVERLAY", nil, 11)
                nameText:SetPoint("LEFT", icon, "RIGHT", 8, 0)
                nameText:SetPoint("RIGHT", trinketFrame, "RIGHT", -10, 0)
                nameText:SetJustifyH("LEFT")
                nameText:SetText(trinketData.name or RCL["Unknown"])
                nameText:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])

                trinketFrame:SetScript("OnEnter", function(self)
                    self:SetBackdropColor(self.hoverBg.r, self.hoverBg.g, self.hoverBg.b, 1)
                end)
                trinketFrame:SetScript("OnLeave", function(self)
                    self:SetBackdropColor(self.cardBg.r, self.cardBg.g, self.cardBg.b, 1)
                end)
                trinketFrame:SetScript("OnClick", function()
                    local slotKey = "slot" .. slotNum
                    local queue = RC.db.trinketSwap.queues[queueKey][slotKey]

                    for _, existingId in ipairs(queue) do
                        if existingId == trinketData.itemId then
                            return
                        end
                    end

                    table.insert(queue, trinketData.itemId)
                    RC:SaveConfigurationToProfile()
                    frame.trinketConfigState.addingToSlot = nil
                    RC:ShowSidebarQueueConfiguration(frame)
                end)

                cardY = cardY - 40
            end
        else
            local noText = self:CreateFontString(trinketsCard, "OVERLAY", nil, 10)
            noText:SetPoint("TOPLEFT", trinketsCard, "TOPLEFT", 14, cardY)
            noText:SetText(RCL["No trinkets found - go back and click 'Scan Bags'"])
            noText:SetTextColor(TEXT.red[1], TEXT.red[2], TEXT.red[3])
            cardY = cardY - 25
        end

        cardY = cardY - 5
        trinketsCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - trinketsCard:GetHeight() - 15

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end

    function RC:ShowSidebarRenameQueue(frame)
        self:ClearSidebarContent(self.sidebarConfigFrame)
        local parent = frame.scrollChild
        local yPos = -20

        if not frame.trinketConfigState or not frame.trinketConfigState.renamingQueue then
            self:ShowSidebarTrinketSwapConfig(frame)
            return
        end

        local queueKey = frame.trinketConfigState.renamingQueue
        local currentName = self.trinketSwapSystem.queueNames[queueKey] or queueKey

        local backButton = self.UI:CreateBackButton(parent, "Back", 80, 28)
        backButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
        backButton:SetScript("OnClick", function()
            frame.trinketConfigState = nil
            RC:ShowSidebarTrinketSwapConfig(frame)
        end)

        local header = self:CreateFontString(parent, "OVERLAY", nil, 16)
        header:SetPoint("LEFT", backButton, "RIGHT", 15, 0)
        header:SetText(RCL["Rename Queue"])
        header:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
        yPos = yPos - 50

        local renameCard = self:CreateSettingsCard(parent, yPos, RCL["Enter new name"])
        local cardY = -32

        local nameLabel = self:CreateFontString(renameCard, "OVERLAY", nil, 11)
        nameLabel:SetPoint("TOPLEFT", renameCard, "TOPLEFT", 14, cardY)
        nameLabel:SetText(RCL["Queue Name:"])
        nameLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
        cardY = cardY - 25

        local nameEditBoxContainer = self.UI:CreateStyledEditBox(renameCard, {
            width       = 200,
            height      = 24,
            initialText = currentName,
            maxLetters  = 30,
        })
        nameEditBoxContainer:SetPoint("TOPLEFT", renameCard, "TOPLEFT", 14, cardY)
        local nameEditBox = nameEditBoxContainer.editBox
        cardY = cardY - 35

        local saveBtn = self.UI:CreateStyledButton(renameCard, RCL["Save Name"], 100, 28)
        saveBtn:SetPoint("TOPLEFT", renameCard, "TOPLEFT", 14, cardY)
        saveBtn:SetScript("OnClick", function()
            local newName = nameEditBox:GetText()
            if newName and newName ~= "" then
                RC:SetConfigName(queueKey, newName)
                RC:SaveConfigurationToProfile()
                frame.trinketConfigState = nil
                RC:ShowSidebarTrinketSwapConfig(frame)
            end
        end)
        cardY = cardY - 40

        renameCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - renameCard:GetHeight() - 15

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end
