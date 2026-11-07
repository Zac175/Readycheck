------------------------------------------------------------------------
-- Readycheck - Raid Route: Step List Renderer
-- Renders the per-raid Route Steps/Settings body for RC.RaidRoute; step
-- editing uses the shared helpers from Route_Helpers.lua via RC._srr.
-- Edits RC.db.raidRoute (settings/uiTab) and RR:GetRoute(raidName).steps,
-- an ORDERED ARRAY - reordering, inserting and deleting steps here must
-- keep index order intact since a full route syncs over the mesh as a
-- full-replace of the array, not a per-key merge.
-- Pokes RC:SaveConfigurationToProfile and RR:UpdateArming/RefreshTracker.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not (RC and RC.UI and RC.CreateSettingsCard) then return end
RC._srr = RC._srr or {}
local _srr = RC._srr
local BossOverrideList, CopyStep, GatherReminderItems, GatherSets, GatherSlotItems, GatherTrashMobs, GatherTrinketItems, GetBossGearswap, GetSetIcon, ICON_QUESTION, ItemIcon, ItemName, MakeArrowButton, MakeEditBox =
      _srr.BossOverrideList, _srr.CopyStep, _srr.GatherReminderItems, _srr.GatherSets, _srr.GatherSlotItems, _srr.GatherTrashMobs, _srr.GatherTrinketItems, _srr.GetBossGearswap, _srr.GetSetIcon, _srr.ICON_QUESTION, _srr.ItemIcon, _srr.ItemName, _srr.MakeArrowButton, _srr.MakeEditBox
local SLOT_LIST, SLOT_NAME, ShowRouteSharePopup, SlotEnchantLabel, StepIcon, StepSummary, T_GOLD, T_GRAY, T_GREEN, T_NORM, T_WHITE =
      _srr.SLOT_LIST, _srr.SLOT_NAME, _srr.ShowRouteSharePopup, _srr.SlotEnchantLabel, _srr.StepIcon, _srr.StepSummary, _srr.T_GOLD, _srr.T_GRAY, _srr.T_GREEN, _srr.T_NORM, _srr.T_WHITE
    -- The preview: the route tracker itself (RR:BuildTrackerFrame on the
    -- canvas) drawn by RR:RefreshTracker through a stand-in route object -
    -- a sample route, sample kill counts, the live settings - so every
    -- tracker setting shows on it. Replay plays the swap line's entrance.
    local RT_PV_W, RT_PV_H = 320, 230
    local RT_STEPS = {
        { type = "kills", mobs = { { mob = "Patchwork Golem", kills = 4 } } },
        { type = "encounter", boss = "Patchwerk", when = "end" },
        { type = "kills", mobs = { { mob = "Living Monstrosity", kills = 4 }, { mob = "Stitched Spewer", kills = 2 } } },
        { type = "encounter", boss = "Grobbulus", when = "start" },
        { type = "kills", mobs = { { mob = "Embalming Slime", kills = 6 } } },
    }
    local function RouteSample(P, canvas)
        local RR = RC.RaidRoute
        local st = P.store
        if st.rr then return st.rr end
        local holder = CreateFrame("Frame", nil, canvas)
        holder:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        st.holder = holder
        local sf = RR:BuildTrackerFrame(holder)
        sf:SetPoint("CENTER", holder, "CENTER", 0, 0)
        local view = setmetatable({}, { __index = function(_, k) local s = RR:GetSettings() return s and s[k] end })
        view.enabled, view.trackerEnabled, view.trackerUnlocked = true, true, false
        st.rr = setmetatable({
            trackerFrame = sf, raidName = RC:RaidSample("raid") or "Naxxramas", active = 3, finished = false,
            activeReminders = {}, counts = RC:RaidSample("routeCounts")
                or { ["Living Monstrosity"] = 3, ["Stitched Spewer"] = 1, ["Embalming Slime"] = 0 },
            _stepBase = {},
            GetSteps = function() return RC:RaidSample("routeSteps") or RT_STEPS end,
            GetSettings = function() return view end,
        }, { __index = RR })
        return st.rr
    end
    local function RouteFeed(rr, mode, fresh)
        if mode ~= "swap" then rr._swapFeed = nil return end
        rr._swapFeed = { label = RCL["Gear set: "] .. "Frost Resist", at = GetTime(), step = rr.active, fresh = fresh,
            items = { { slot = 1, icon = "Interface\\Icons\\INV_Helmet_08", oldIcon = "Interface\\Icons\\INV_Helmet_03" },
                      { slot = 5, icon = "Interface\\Icons\\INV_Chest_Plate16", oldIcon = "Interface\\Icons\\INV_Chest_Chain_05" } } }
    end
    local function RoutePreviewUpdate(canvas, P)
        local rr = P.store.rr
        if not rr then return end
        rr.active = (P.mode == "boss") and 4 or 3
        RouteFeed(rr, P.mode, nil)
        rr:RefreshTracker()
        local f = rr.trackerFrame
        local sc = f:GetScale() or 1
        -- the tracker at its real size; the canvas is its box (the swap
        -- feed hangs 16 px under it) and the strip scales it
        local fw, fh = f:GetWidth() or 240, f:GetHeight() or 80
        RC._rpk.FitStrip(P, P.store.holder, fw * sc, fh * sc + 16, 4, fw, fh + 16)
    end
    local function RoutePreviewReplay(canvas, P)
        local rr = P.store.rr
        if not rr then return end
        if P.mode ~= "swap" then return end
        RouteFeed(rr, "swap", true)
        rr:RefreshTracker()
    end
    function RC:DeclareRouteTrackerPreview()
        local RR = RC.RaidRoute
        if not (RR and RR.BuildTrackerFrame and RC._rpk) then return nil end
        return self.UI:DeclarePreview({
            key = "route.tracker", title = RCL["Route tracker"], width = RT_PV_W, height = RT_PV_H,
            modes = { { id = "kills", label = RCL["Kill step"] }, { id = "boss", label = RCL["Boss step"] },
                      { id = "swap", label = RCL["Gear swap (bar style)"] } },
            build = function(canvas, P) RouteSample(P, canvas) end,
            update = RoutePreviewUpdate, replay = RoutePreviewReplay,
        })
    end

    function RC:RenderRaidRouteBody(frame, raidName, parent, yPos)
        local RR = RC.RaidRoute
        if not RR then return yPos end
        local routeP = self:DeclareRouteTrackerPreview()

        -- Remote edit mode: editing another raider's route. RR:GetSettings/
        -- GetRoute resolve to their buffered data while this is true; the
        -- runtime tracker (RR.raidName/RR.active) stays pinned to the local
        -- profile, so "tracking here" is always false while remote.
        local _rem = RC.remoteEditMode
        local isRemoteRoute = (_rem and _rem.raidKey == raidName and RC._remoteEditData) and true or false
        local trackingHere = (not isRemoteRoute) and (RR.raidName == raidName)
        if isRemoteRoute then
            local banner = self:CreateFontString(parent, "OVERLAY", nil, 11)
            banner:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
            banner:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
            banner:SetJustifyH("LEFT")
            banner:SetWordWrap(true)
            banner:SetText(RCL["REMOTE EDIT: you are editing "]
                .. tostring((_rem.member and (_rem.member.label or _rem.member.name)) or "this raider")
                .. RCL["'s route. Changes push to them over the mesh (live if online, on next login otherwise). "]
                .. RCL["Their tracker picks the changes up mid-raid."])
            banner:SetTextColor(T_GOLD[1], T_GOLD[2], T_GOLD[3])
            yPos = yPos - (banner:GetStringHeight() or 28) - 10
        end

        local settings = RR:GetSettings()
        local route    = RR:GetRoute(raidName)
        if not settings or not route then
            local note = self:CreateFontString(parent, "OVERLAY", nil, 11)
            note:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
            note:SetText(RCL["Route data is not ready yet - reopen this page in a moment."])
            note:SetTextColor(T_GRAY[1], T_GRAY[2], T_GRAY[3])
            return yPos - 24
        end
        local steps = route.steps

        if not isRemoteRoute then
            RR:UpdateArming()
        end

        frame.configState = frame.configState or {}
        frame.configState.selectedRaid = raidName
        frame.configState.selectedEncounter = "Route"
        frame.configState.selectedEncounterType = "route"

        local function Rerender()
            if GameTooltip:IsShown() then GameTooltip:Hide() end
            if self.UI.CloseAllDropdowns then self.UI:CloseAllDropdowns() end
            RC:ShowInlineAbilityConfig(frame, raidName, "Route", "route", nil, true)
        end
        local function Save()
            RC:SaveConfigurationToProfile()
            RR:UpdateArming()
        end

        local editIdx = nil
        if frame._routeEdit and frame._routeEdit.raid == raidName then
            editIdx = frame._routeEdit.idx
        end
        local function SetEditIdx(idx)
            if idx then
                frame._routeEdit = { raid = raidName, idx = idx }
            else
                frame._routeEdit = nil
            end
        end

        local _acGold = RC:GetColor("ui", "accentGold")
        local _bBlack = { r = 0, g = 0, b = 0, a = 1 }

        RC.db.raidRoute = RC.db.raidRoute or {}
        local uiTab = RC.db.raidRoute.uiTab or "steps"
        if uiTab == "planner" then uiTab = "steps" end
        -- Shared with RR._uiCountUpdate below: whichever tab renders
        -- assigns the font strings it creates, the other stays nil.
        local statusFS = nil
        local activeCountFS = nil
        do
            local tabs = {
                { id = "steps",    label = RCL["Route Steps"] },
                { id = "settings", label = RCL["Settings"] },
            }
            local tx = 0
            for _, td in ipairs(tabs) do
                local tb = self.UI:CreateTabButton(parent, td.label, 24, 12, 90)
                tb:SetPoint("TOPLEFT", parent, "TOPLEFT", 10 + tx, yPos)
                tx = tx + tb:GetWidth() + 6
                tb:SetSelected(uiTab == td.id)
                tb:SetScript("OnClick", function()
                    RC.db.raidRoute.uiTab = td.id
                    Rerender()
                end)
            end
            yPos = yPos - 32
        end

        if uiTab == "settings" then
        local setCard = self:CreateSettingsCard(parent, yPos, RCL["Raid route"])
        local cy = -30

        local routeOnCb = self.UI:CreateSettingCheckbox(setCard, cy, "Enable route tracking",
            settings.enabled, function(cb)
                settings.enabled = cb:GetChecked() and true or false
                Save()
                Rerender()
            end)
        cy = cy - 24
        local routeMark = self.UI:MarkCard(setCard)

        self.UI:CreateSettingCheckbox(setCard, cy, "Show next-step tracker in raid",
            settings.trackerEnabled ~= false, function(cb)
                settings.trackerEnabled = cb:GetChecked() and true or false
                Save()
                RR:RefreshTracker()
            end)
        cy = cy - 24

        self.UI:CreateSettingCheckbox(setCard, cy, "Play a loud ping with spoken reminders",
            settings.reminderPing == true, function(cb)
                settings.reminderPing = cb:GetChecked() and true or false
                RC:SaveConfigurationToProfile()
            end); cy = cy - 26

        self.UI:CreateSettingCheckbox(setCard, cy, "Tracker: show the next step below",
            settings.trackerShowContext == true, function(cb)
                settings.trackerShowContext = cb:GetChecked() and true or false
                Save()
                RR:RefreshTracker()
                Rerender()
            end)
        cy = cy - 24

        self.UI:CreateSettingCheckbox(setCard, cy, "Tracker: unlock (drag to move)",
            settings.trackerUnlocked == true, function(cb)
                settings.trackerUnlocked = cb:GetChecked() and true or false
                Save()
                if RR.ApplyTrackerLock then RR:ApplyTrackerLock() end
            end)
        cy = cy - 24

        local naLbl = self:CreateFontString(setCard, "OVERLAY", nil, 10)
        naLbl:SetPoint("TOPLEFT", setCard, "TOPLEFT", 14, cy)
        naLbl:SetText(RCL["Step arrow visibility:"])
        naLbl:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
        local curNa = tonumber(settings.trackerNavAlpha) or 0
        if curNa < 0 then curNa = 0 elseif curNa > 1 then curNa = 1 end
        local naSlider = self.UI:CreateSlider(setCard, 0, 1, curNa, 0.05)
        naSlider:SetPoint("TOPLEFT", setCard, "TOPLEFT", 150, cy + 8)
        naSlider.Text:SetText(curNa == 0 and RCL["Hover only"] or string.format("%d%%", curNa * 100))
        naSlider:SetScript("OnValueChanged", function(slider, value)
            if value < 0 then value = 0 elseif value > 1 then value = 1 end
            settings.trackerNavAlpha = value
            slider.Text:SetText(value == 0 and RCL["Hover only"] or string.format("%d%%", value * 100))
            RR:RefreshTracker()
            if slider.saveTimer then slider.saveTimer:Cancel() end
            slider.saveTimer = C_Timer.NewTimer(0.5, function() Save() end)
        end)
        cy = cy - 32

        self.UI:CreateSettingCheckbox(setCard, cy, "TTS: announce when a swapped-in trinket is ready",
            settings.trinketReadyTTS ~= false, function(cb)
                settings.trinketReadyTTS = cb:GetChecked() and true or false
                Save()
            end)
        cy = cy - 24

        local navLbl = self:CreateFontString(setCard, "OVERLAY", nil, 10)
        navLbl:SetPoint("TOPLEFT", setCard, "TOPLEFT", 14, cy)
        navLbl:SetText(RCL["Step arrows:"])
        navLbl:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
        local NAV_OPTS = {
            { text = RCL["Auto (opposite text)"], value = "auto" },
            { text = RCL["Top left"],             value = "tl" },
            { text = RCL["Top right"],            value = "tr" },
            { text = RCL["Bottom left"],          value = "bl" },
            { text = RCL["Bottom right"],         value = "br" },
        }
        local navCur = settings.trackerNavPos or "auto"
        local navLabel = "Auto (opposite text)"
        for _, o in ipairs(NAV_OPTS) do
            if o.value == navCur then navLabel = o.text end
        end
        local navDD = self.UI:CreateScrollableDropdown(setCard, 150, navLabel, 5)
        navDD:SetPoint("TOPLEFT", setCard, "TOPLEFT", 150, cy + 4)
        navDD:SetItems(NAV_OPTS, function(value)
            settings.trackerNavPos = value
            Save()
            RR:RefreshTracker()
        end)
        cy = cy - 30

        self.UI:CreateSettingCheckbox(setCard, cy, "Tracker: anchor and align to the right",
            settings.trackerAlignRight == true, function(cb)
                settings.trackerAlignRight = cb:GetChecked() and true or false
                Save()
                if RR.ApplyTrackerAlign then RR:ApplyTrackerAlign() end
                RR:RefreshTracker()
            end)
        cy = cy - 24

        self.UI:CreateSettingCheckbox(setCard, cy, "Tracker: transparent background (no box)",
            settings.trackerNoBg == true, function(cb)
                settings.trackerNoBg = cb:GetChecked() and true or false
                Save()
                RR:RefreshTracker()
            end)
        cy = cy - 24

        local bandCb = self.UI:CreateSettingCheckbox(setCard, cy, "Tracker: bar style (one row, a segment per kill)",
            settings.trackerBand == true, function(cb)
                settings.trackerBand = cb:GetChecked() and true or false
                Save()
                RR:RefreshTracker()
            end)
        cy = cy - 24

        local bandSwapsCb = self.UI:CreateSettingCheckbox(setCard, cy, "Bar style: show gear swaps on a line under the bar",
            settings.trackerBandSwaps ~= false, function(cb)
                settings.trackerBandSwaps = cb:GetChecked() and true or false
                Save()
                RR:RefreshTracker()
            end)
        cy = cy - 24
        self.UI:BindDependents(bandCb, { bandSwapsCb })

        self.UI:CreateSettingCheckbox(setCard, cy, "Basic tracker: only show this step's actions (no kill counts)",
            settings.trackerBasic == true, function(cb)
                settings.trackerBasic = cb:GetChecked() and true or false
                Save()
                RR:RefreshTracker()
            end)
        cy = cy - 24

        self.UI:CreateSettingCheckbox(setCard, cy, "Tracker: gold accent stripe",
            settings.trackerAccent ~= false, function(cb)
                settings.trackerAccent = cb:GetChecked() and true or false
                Save()
                RR:RefreshTracker()
            end)
        cy = cy - 24

        local szLbl = self:CreateFontString(setCard, "OVERLAY", nil, 10)
        szLbl:SetPoint("TOPLEFT", setCard, "TOPLEFT", 14, cy)
        szLbl:SetText(RCL["Tracker scale:"])
        szLbl:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
        local curScale = tonumber(settings.trackerScale) or RR.TRACKER_SCALE or 0.85
        local scaleSlider = self.UI:CreateSlider(setCard, 0.6, 1.6, curScale, 0.05)
        scaleSlider:SetPoint("TOPLEFT", setCard, "TOPLEFT", 110, cy + 8)
        scaleSlider.Text:SetText(math.floor(curScale * 100 + 0.5) .. "%")
        scaleSlider:SetScript("OnValueChanged", function(slider, value)
            value = math.floor(value * 20 + 0.5) / 20
            settings.trackerScale = value
            slider.Text:SetText(math.floor(value * 100 + 0.5) .. "%")
            RR:RefreshTracker()
            if slider.saveTimer then slider.saveTimer:Cancel() end
            slider.saveTimer = C_Timer.NewTimer(0.5, function() Save() end)
        end)
        if settings.trackerW then
            local autoW = self.UI:CreateStyledButton(setCard, RCL["Auto width"], 80, 20)
            autoW:SetPoint("TOPLEFT", setCard, "TOPLEFT", 300, cy + 2)
            autoW:SetScript("OnClick", function()
                settings.trackerW = nil
                Save()
                RR:RefreshTracker()
                Rerender()
            end)
            autoW:HookScript("OnEnter", function(b)
                GameTooltip:SetOwner(b, "ANCHOR_TOP")
                GameTooltip:SetText(RCL["Forget the width you dragged the tracker to; it sizes to its content again."], nil, nil, nil, nil, true)
                GameTooltip:Show()
            end)
            autoW:HookScript("OnLeave", function() GameTooltip:Hide() end)
        end
        cy = cy - 32

        if settings.trackerShowContext == true then
        local pvLbl = self:CreateFontString(setCard, "OVERLAY", nil, 10)
        pvLbl:SetPoint("TOPLEFT", setCard, "TOPLEFT", 14, cy)
        pvLbl:SetText(RCL["Preview upcoming steps:"])
        pvLbl:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
        local curPv = tonumber(settings.trackerNextCount)
        if curPv == nil then curPv = 1 end
        if curPv < 0 then curPv = 0 elseif curPv > 3 then curPv = 3 end
        local pvSlider = self.UI:CreateSlider(setCard, 0, 3, curPv, 1)
        pvSlider:SetPoint("TOPLEFT", setCard, "TOPLEFT", 150, cy + 8)
        pvSlider.Text:SetText(curPv == 0 and RCL["Off"] or tostring(curPv))
        pvSlider:SetScript("OnValueChanged", function(slider, value)
            value = math.floor(value + 0.5)
            if value < 0 then value = 0 elseif value > 3 then value = 3 end
            settings.trackerNextCount = value
            slider.Text:SetText(value == 0 and RCL["Off"] or tostring(value))
            RR:RefreshTracker()
            if slider.saveTimer then slider.saveTimer:Cancel() end
            slider.saveTimer = C_Timer.NewTimer(0.5, function() Save() end)
        end)
        cy = cy - 32
        end
        -- the tracker options only matter while route tracking is on (the
        -- test, status and route buttons below stay live)
        self.UI:BindDependents(routeOnCb, self.UI:CardSince(setCard, routeMark))

        local remLbl = self:CreateFontString(setCard, "OVERLAY", nil, 10)

        remLbl:SetPoint("TOPLEFT", setCard, "TOPLEFT", 14, cy)
        remLbl:SetPoint("RIGHT", setCard, "RIGHT", -66, 0)
        remLbl:SetJustifyH("LEFT")
        remLbl:SetWordWrap(false)
        remLbl:SetText(RCL["Reminders stay until the route advances; item picks clear on use."])
        remLbl:SetTextColor(T_GRAY[1], T_GRAY[2], T_GRAY[3])

        local testRemBtn = self.UI:CreateStyledButton(setCard, RCL["Test"], 46, 20)
        testRemBtn:SetPoint("TOPRIGHT", setCard, "TOPRIGHT", -12, cy + 4)
        testRemBtn:SetScript("OnClick", function()
            RR:ShowRouteReminder("Sapper this pack", 134400)
        end)
        cy = cy - 26

        statusFS = self:CreateFontString(setCard, "OVERLAY", nil, 11)
        statusFS:SetPoint("TOPLEFT", setCard, "TOPLEFT", 14, cy)
        statusFS:SetPoint("RIGHT", setCard, "RIGHT", -14, 0)
        statusFS:SetJustifyH("LEFT")
        statusFS:SetText(RR:GetStatusText(raidName))
        statusFS:SetTextColor(T_GREEN[1], T_GREEN[2], T_GREEN[3])
        cy = cy - 22

        local realRaidNow  = RC.GetEffectiveRaidName and RC:GetEffectiveRaidName() or nil
        do
            local bx = 15
            local function BarBtn(label, width, onClick, tooltip)
                local b = self.UI:CreateStyledButton(setCard, label, width, 22)
                b:SetPoint("TOPLEFT", setCard, "TOPLEFT", bx, cy)
                b:SetScript("OnClick", onClick)
                if tooltip then
                    b:HookScript("OnEnter", function()
                        GameTooltip:SetOwner(b, "ANCHOR_TOP")
                        GameTooltip:SetText(tooltip, 1, 1, 1, 1, true)
                        GameTooltip:Show()
                    end)
                    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
                end
                bx = bx + width + 6
                return b
            end

            if trackingHere then
                BarBtn("Reset Progress", 100, function()
                    C_Timer.After(0.05, Rerender)
                    RR:ResetProgress()
                end, "Set the pointer back to step 1.")
                BarBtn("Sim Step", 70, function()
                    C_Timer.After(0.05, Rerender)
                    RR:SimulateStep(IsShiftKeyDown())
                end, "Simulate the active step: an AoE-style burst of every remaining kill at once (or its boss event). Shift-click: a single kill, to watch the counter tick.")
                if RR.isTest then
                    BarBtn("Stop Test", 76, function()
                        C_Timer.After(0.05, Rerender)
                        RR:StopTest()
                    end, "Stop test-tracking this raid.")
                end
            elseif (not realRaidNow) and (not isRemoteRoute) then
                BarBtn("Track Here (test)", 116, function()
                    C_Timer.After(0.05, Rerender)
                    RR:StartTest(raidName)
                end, "Arm the route for this raid from anywhere so Sim Step and Test Actions work. Clears automatically when you enter a real raid.")
            end
        end
        cy = cy - 28

        do
            local sx = 15
            local function ShareBtn(label, width, onClick, tooltip)
                local b = self.UI:CreateStyledButton(setCard, label, width, 22)
                b:SetPoint("TOPLEFT", setCard, "TOPLEFT", sx, cy)
                b:SetScript("OnClick", onClick)
                if tooltip then
                    b:HookScript("OnEnter", function()
                        GameTooltip:SetOwner(b, "ANCHOR_TOP")
                        GameTooltip:SetText(tooltip, 1, 1, 1, 1, true)
                        GameTooltip:Show()
                    end)
                    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
                end
                sx = sx + width + 6
            end
            ShareBtn("Export Route", 96, function()
                ShowRouteSharePopup("export", raidName)
            end, "Copyable string of this raid's route (steps, mobs, gear and reminder payloads).")
            ShareBtn("Import Route", 96, function()
                ShowRouteSharePopup("import", raidName, function() Rerender() end)
            end, "Paste a route string - REPLACES this raid's route on the active profile. A route made from Warcraft Logs keeps the gear and reminders of your old steps where it can.")
            -- Make the route on the Readycheck Routes web page (its link is
            -- handed over to copy), then paste what it gives back.
            ShareBtn("From Logs", 84, function()
                if _srr.ShowFromLogs then _srr.ShowFromLogs(raidName, function() Rerender() end) end
            end, "Make this route from a Warcraft Logs report: the pulls you did, in order, with how many of each mob died.")
            ShareBtn("Mesh Share", 88, function()
                local MSm = RC.MeshSync
                local route = RR:GetRoute(raidName)
                if MSm and MSm.ShareRoute then
                    MSm:ShareRoute(raidName, route)
                else
                    RC:Print(RCL["Mesh Sync is not loaded."])
                end
            end, "Push this route to EVERY online mesh member right now. They receive it into their active profile and their tracker updates live.")
        end
        cy = cy - 28

        local desc = self:CreateFontString(setCard, "OVERLAY", nil, 10)
        desc:SetPoint("TOPLEFT", setCard, "TOPLEFT", 14, cy)
        desc:SetPoint("RIGHT", setCard, "RIGHT", -14, 0)
        desc:SetJustifyH("LEFT")
        desc:SetWordWrap(true)
        desc:SetText(RCL["Raid Route automates a PLANNED kill order: you script the whole raid as steps - "]
            .. RCL["trash packs to count and bosses as checkpoints - and as your raid executes that exact plan, "]
            .. RCL["each step fires its payload the moment its trigger completes: gear and trinket swaps "]
            .. RCL["(queued safely if you are in combat), on-screen reminders and spoken alerts. "]
            .. RCL["An on-screen tracker follows along and boss pulls resync the plan automatically."])
        desc:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
        cy = cy - (desc:GetStringHeight() or 48) - 8

        local who = self:CreateFontString(setCard, "OVERLAY", nil, 10)
        who:SetPoint("TOPLEFT", setCard, "TOPLEFT", 14, cy)
        who:SetPoint("RIGHT", setCard, "RIGHT", -14, 0)
        who:SetJustifyH("LEFT")
        who:SetWordWrap(true)
        who:SetText(RCL["This is really only for extremely coordinated raids at the highest level - groups that "]
            .. RCL["run a rehearsed route the same way every week. If the raid improvises its pathing, the "]
            .. RCL["plan and reality drift apart fast. Not recommended for normal, chill raids - the boss "]
            .. RCL["gear and reminder systems already cover those without any scripting."])
        who:SetTextColor(T_GOLD[1], T_GOLD[2], T_GOLD[3])
        cy = cy - (who:GetStringHeight() or 48) - 8

        local perf = self:CreateFontString(setCard, "OVERLAY", nil, 10)
        perf:SetPoint("TOPLEFT", setCard, "TOPLEFT", 14, cy)
        perf:SetPoint("RIGHT", setCard, "RIGHT", -14, 0)
        perf:SetJustifyH("LEFT")
        perf:SetWordWrap(true)
        perf:SetText(RCL["Performance: kill detection reads the combat log through one scoped "]
            .. RCL["reader that is registered only while a kill step is actually armed, and each "]
            .. RCL["combat-log event costs a single check - no scanning, no per-frame work. "]
            .. RCL["Idle cost is zero."])
        perf:SetTextColor(T_GRAY[1], T_GRAY[2], T_GRAY[3])
        cy = cy - (perf:GetStringHeight() or 36) - 10

        local hint = self:CreateFontString(setCard, "OVERLAY", nil, 10)
        hint:SetPoint("TOPLEFT", setCard, "TOPLEFT", 14, cy)
        hint:SetPoint("RIGHT", setCard, "RIGHT", -14, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)
        hint:SetText(RCL["Click a step to open it. Kill steps count their mobs while active; boss steps resync the route on pull or kill."])
        hint:SetTextColor(T_GRAY[1], T_GRAY[2], T_GRAY[3])
        cy = cy - 30

        setCard:SetContentHeight(-cy)
        yPos = yPos - setCard:GetHeight() - 10

        -- The tracker's one animation: the bar-style swap line sliding in
        -- as a piece lands (raidRoute.trackerSwapAnim; unset = the old
        -- 0.25s slide from the text side's far end).
        local K = RC._rpk
        if K and RR.SwapLineDefaults then
            local anCard = self:CreateSettingsCard(parent, yPos, RCL["Tracker animation"])
            local ay = -32
            ay = K.Anim(anCard, ay, settings, "trackerSwapAnim", RR:SwapLineDefaults(),
                RCL["When a gear swap lands (bar style)"], "in", function()
                    RR:RefreshTracker()
                    if routeP then routeP.Replay() end
                end)
            ay = K.Desc(anCard, ay, RCL["Plays on the line under the bar each time Readycheck puts a piece on. Appearance > Motion can turn it off or speed it up."])
            anCard:SetContentHeight(-ay)
            yPos = yPos - anCard:GetHeight() - 10
        end

        -- where the title, count, body line and when-label sit (the
        -- customization standard; the alignment and rows make the
        -- defaults, a position set here goes on top)
        if RR.TEXT_ELEMENTS then
            local tpCard = self:CreateSettingsCard(parent, yPos, RCL["Tracker text positions"])
            local ty = -32
            local cw = tpCard:GetWidth() or 0
            local W = (cw > 240) and math.min(460, cw - 28) or 420
            local function Saved() RC:SaveConfigurationToProfile() RR:RefreshTracker() end
            local sample = routeP and routeP.store and routeP.store.rr and routeP.store.rr.trackerFrame
            for _, e in ipairs(RR.TEXT_ELEMENTS) do
                local ag, as = self.UI:CustomAccess(settings, "anchors", e.key, Saved)
                local targets = {}
                for _, t in ipairs(RR.TEXT_TARGETS) do if t.value ~= e.key then targets[#targets + 1] = t end end
                local g = self.UI:CreateTextElement(tpCard, { label = e.label, key = e.key, width = W,
                    anchorGet = ag, anchorSet = as, targets = targets,
                    defaultTargetLabel = RCL["Where the layout puts it"],
                    anchorDefaults = function() return RR:TrackerAnchorDefault(e.key, sample) end })
                g:SetPoint("TOPLEFT", tpCard, "TOPLEFT", 14, ty)
                ty = ty - g:GetHeight() - 14
            end
            -- the pooled rows: one place for every mob row / reminder row
            for _, e in ipairs(RR.ROW_ELEMENTS or {}) do
                local ag, as = self.UI:CustomAccess(settings, "anchors", e.key, Saved)
                local targets = { { value = "panel", text = RCL["The panel"] } }
                for _, t in ipairs(e.targets) do targets[#targets + 1] = t end
                local g = self.UI:CreateTextElement(tpCard, { label = e.label, key = e.key, width = W,
                    anchorGet = ag, anchorSet = as, targets = targets,
                    defaultTargetLabel = RCL["Where the layout puts it"],
                    anchorDefaults = function() return RR:TrackerAnchorDefault(e.key, sample) end })
                g:SetPoint("TOPLEFT", tpCard, "TOPLEFT", 14, ty)
                ty = ty - g:GetHeight() - 14
            end
            if K then ty = K.Desc(tpCard, ty, RCL["Reset puts a text back where the panel's own layout puts it. A row's place counts for every row of its kind."]) end
            tpCard:SetContentHeight(-ty)
            yPos = yPos - tpCard:GetHeight() - 10
            -- the panel's fade rules, shadow / glow and layer, and the ping
            local function Live() RR:RefreshTracker() end
            local function RouteRoot() return RR:GetSettings() end
            yPos = self.UI:FrameVisibilityCard(parent, yPos, RouteRoot, Live, { title = RCL["Tracker fade and opacity"] }) + 5
            yPos = self.UI:FrameChromeCard(parent, yPos, RouteRoot, Live,
                { title = RCL["Tracker shadow and glow"], fields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } }) + 5
            yPos = self.UI:FrameLayerCard(parent, yPos, RouteRoot, Live, { title = RCL["Tracker layer"], scale = false }) + 5
            local pingCard = self:CreateSettingsCard(parent, yPos, RCL["Reminder ping sound"])
            local py = -32
            local cw = pingCard:GetWidth() or 0
            local sg, ss = self.UI:CustomAccess(RouteRoot, "sounds", "ping", function() RC:SaveConfigurationToProfile() end)
            local sp = self.UI:CreateSoundSpecPicker(pingCard, { width = (cw > 240) and math.min(460, cw - 28) or 420,
                get = sg, set = ss, defaults = {} })
            sp:SetPoint("TOPLEFT", pingCard, "TOPLEFT", 14, py)
            py = py - sp:GetHeight() - 8
            py = self.UI:CreateHelpLine(pingCard, 14, py, RCL["Plays with spoken reminders while the loud ping is on (Settings). No sound picked: the ready-check ping."])
            pingCard:SetContentHeight(-py)
            yPos = yPos - pingCard:GetHeight() - 10
        end

        -- Swap notices: the quiet alternative to the always-on tracker. A
        -- short notice each time Readycheck changes gear for you - what
        -- went on, with icons, and why (the step, the boss, the set).
        -- Covers boss pulls and kills and trinket rotations too, not only
        -- the route, so it is kept in RC.db.swapToast under Gear.
        local ST = RC.SwapToast
        if ST then
        local sts = ST:Settings()
        local swCard = self:CreateSettingsCard(parent, yPos, RCL["Swap notices"])
        local sy = -30
        local swDesc = self:CreateFontString(swCard, "OVERLAY", nil, 10)
        swDesc:SetPoint("TOPLEFT", swCard, "TOPLEFT", 14, sy)
        swDesc:SetPoint("RIGHT", swCard, "RIGHT", -14, 0)
        swDesc:SetJustifyH("LEFT")
        swDesc:SetWordWrap(true)
        swDesc:SetText(RCL["A small notice each time Readycheck changes your gear for you - a route step, "
            .. "a boss pull or kill, a trinket rotation, a queued swap landing after combat: what went on, "
            .. "with icons, and why. Your own manual swaps never make one."])
        swDesc:SetTextColor(T_GRAY[1], T_GRAY[2], T_GRAY[3])
        sy = sy - math.max(28, swDesc:GetStringHeight() + 10)

        self.UI:CreateSettingCheckbox(swCard, sy, "Show a notice when Readycheck swaps my gear",
            sts.enabled == true, function(cb)
                sts.enabled = cb:GetChecked() and true or false
                RC:SaveConfigurationToProfile()
                Rerender()
            end)
        sy = sy - 24

        if sts.enabled then
            self.UI:CreateSettingCheckbox(swCard, sy, "Name each piece (a full set shows an icon strip)",
                sts.showNames ~= false, function(cb)
                    sts.showNames = cb:GetChecked() and true or false
                    RC:SaveConfigurationToProfile()
                end)
            sy = sy - 24

            self.UI:CreateSettingCheckbox(swCard, sy, "Show background box (off: text on the world, like the tracker)",
                sts.showBackground ~= false, function(cb)
                    sts.showBackground = cb:GetChecked() and true or false
                    RC:SaveConfigurationToProfile()
                    ST:Refresh()
                end)
            sy = sy - 24

            self.UI:CreateSettingCheckbox(swCard, sy, "Lock position (drag to move when unlocked)",
                sts.locked ~= false, function(cb)
                    sts.locked = cb:GetChecked() and true or false
                    RC:SaveConfigurationToProfile()
                end)
            sy = sy - 24

            local duLbl = self:CreateFontString(swCard, "OVERLAY", nil, 10)
            duLbl:SetPoint("TOPLEFT", swCard, "TOPLEFT", 14, sy)
            duLbl:SetText(RCL["On screen for:"])
            duLbl:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
            local curDu = tonumber(sts.duration) or 4
            local duSlider = self.UI:CreateSlider(swCard, 1, 10, curDu, 0.5)
            duSlider:SetPoint("TOPLEFT", swCard, "TOPLEFT", 150, sy + 8)
            duSlider.Text:SetText(string.format("%.1fs", curDu))
            duSlider:SetScript("OnValueChanged", function(slider, value)
                value = math.floor(value * 2 + 0.5) / 2
                sts.duration = value
                slider.Text:SetText(string.format("%.1fs", value))
                if slider.saveTimer then slider.saveTimer:Cancel() end
                slider.saveTimer = C_Timer.NewTimer(0.5, function() RC:SaveConfigurationToProfile() end)
            end)
            sy = sy - 32

            local scLbl = self:CreateFontString(swCard, "OVERLAY", nil, 10)
            scLbl:SetPoint("TOPLEFT", swCard, "TOPLEFT", 14, sy)
            scLbl:SetText(RCL["Notice scale:"])
            scLbl:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
            local curSc = tonumber(sts.scale) or 1
            local scSlider = self.UI:CreateSlider(swCard, 0.6, 1.6, curSc, 0.05)
            scSlider:SetPoint("TOPLEFT", swCard, "TOPLEFT", 150, sy + 8)
            scSlider.Text:SetText(math.floor(curSc * 100 + 0.5) .. "%")
            scSlider:SetScript("OnValueChanged", function(slider, value)
                value = math.floor(value * 20 + 0.5) / 20
                sts.scale = value
                slider.Text:SetText(math.floor(value * 100 + 0.5) .. "%")
                ST:Refresh()
                if slider.saveTimer then slider.saveTimer:Cancel() end
                slider.saveTimer = C_Timer.NewTimer(0.5, function() RC:SaveConfigurationToProfile() end)
            end)
            sy = sy - 32

            local sdLbl = self:CreateFontString(swCard, "OVERLAY", nil, 10)
            sdLbl:SetPoint("TOPLEFT", swCard, "TOPLEFT", 14, sy)
            sdLbl:SetText(RCL["Sound:"])
            sdLbl:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
            local picker = self.UI:CreateSoundPicker(swCard, { width = 180,
                selected = (sts.soundKey ~= "" and sts.soundKey) or nil,
                onPick = function(key)
                    sts.soundKey = key or ""
                    RC:SaveConfigurationToProfile()
                end })
            picker:SetPoint("TOPLEFT", swCard, "TOPLEFT", 150, sy + 5)
            sy = sy - 30
            local noSnd = self.UI:CreateStyledButton(swCard, RCL["No sound"], 70, 20)
            noSnd:SetPoint("TOPLEFT", swCard, "TOPLEFT", 150, sy + 2)
            noSnd:SetScript("OnClick", function()
                sts.soundKey = ""
                RC:SaveConfigurationToProfile()
                Rerender()
            end)
            local testSw = self.UI:CreateStyledButton(swCard, RCL["Test"], 46, 20)
            testSw:SetPoint("LEFT", noSnd, "RIGHT", 6, 0)
            testSw:SetScript("OnClick", function() ST:Test() end)
            if sts.width then
                local autoW = self.UI:CreateStyledButton(swCard, RCL["Auto width"], 80, 20)
                autoW:SetPoint("LEFT", testSw, "RIGHT", 6, 0)
                autoW:SetScript("OnClick", function()
                    sts.width = nil
                    RC:SaveConfigurationToProfile()
                    if ST.current and ST.Layout then ST:Layout(ST.current) end
                    Rerender()
                end)
                autoW:HookScript("OnEnter", function(b)
                    GameTooltip:SetOwner(b, "ANCHOR_TOP")
                    GameTooltip:SetText(RCL["Forget the width you dragged the notice to; it sizes to its content again."], nil, nil, nil, nil, true)
                    GameTooltip:Show()
                end)
                autoW:HookScript("OnLeave", function() GameTooltip:Hide() end)
            end
            sy = sy - 26
        end
        swCard:SetContentHeight(-sy)
        yPos = yPos - swCard:GetHeight() - 10
        end

        end

        if uiTab == "steps" then
        local stepsCard = self:CreateSettingsCard(parent, yPos, RCL["Route steps"])
        local cy = -30

        if #steps == 0 then
            local none = self:CreateFontString(stepsCard, "OVERLAY", nil, 11)
            none:SetPoint("TOPLEFT", stepsCard, "TOPLEFT", 14, cy)
            none:SetText(RCL["No steps yet - add a kill step or a boss step below."])
            none:SetTextColor(T_GRAY[1], T_GRAY[2], T_GRAY[3])
            cy = cy - 24
        end

        RC.routeStepDrag = RC.routeStepDrag or {}
        local dragState = RC.routeStepDrag
        if not stepsCard._dragIndicator then
            local ind = stepsCard:CreateTexture(nil, "OVERLAY")
            ind:SetHeight(2)
            local _ag = RC:GetColor("ui", "accentGold")
            ind:SetColorTexture(_ag.r, _ag.g, _ag.b, 0.9)
            ind:Hide()
            stepsCard._dragIndicator = ind
        end
        dragState.indicator = stepsCard._dragIndicator
        local stepRows = {}

        for i = 1, #steps do
            local step = steps[i]
            step.desc = step.desc or ""
            step.actions = step.actions or {}
            do
                local ma = step.actions
                if not ma.reminders and (ma.reminderText or ma.reminderIcon or ma.reminderItemId) then
                    ma.reminders = { {
                        text = ma.reminderText or "",
                        icon = ma.reminderIcon,
                        itemId = ma.reminderItemId,
                        tts = ma.tts,
                    } }
                    ma.reminderText, ma.reminderIcon, ma.reminderItemId, ma.tts = nil, nil, nil, nil
                end
            end
            if step.type == "kills" then
                if not step.mobs then
                    step.mobs = {}
                    if step.mob and step.mob ~= "" then
                        step.mobs[1] = { mob = step.mob, kills = step.kills or 1 }
                    end
                    step.mob, step.kills = nil, nil
                end
            else
                step.boss = step.boss or ""
                step.when = step.when or "start"
            end

            local isDisabled = (step.enabled == false)
            local isActive  = trackingHere and (RR.active == i) and not isDisabled
            local isEditing = (editIdx == i)

            local row = CreateFrame("Button", nil, stepsCard)
            row:SetPoint("TOPLEFT", stepsCard, "TOPLEFT", 12, cy)
            row:SetPoint("RIGHT", stepsCard, "RIGHT", -12, 0)
            row:SetHeight(30)
            row:RegisterForClicks("AnyUp")

            -- D6 row: flat cardBackground fill; the open (editing) step wears
            -- the configured fill + 3px gold bar, hover lifts to
            -- buttons.hoverBackground.
            local rowBg = row:CreateTexture(nil, "BACKGROUND")
            rowBg:SetAllPoints()
            rowBg:SetTexture(RC.UI.FLAT)
            local cardBg = RC:GetColor("ui", "cardBackground")
            local rowRest = isEditing and RC:GetColor("buttons", "configuredBackground") or cardBg
            rowBg:SetVertexColor(rowRest.r, rowRest.g, rowRest.b, 1)

            local rowBorder = self.UI:CreateSimpleBorder(row)
            self.UI:UpdateBorderColor(rowBorder, isActive and _acGold or _bBlack)

            stepRows[i] = row
            row.stepIndex = i

            do
                local grip = CreateFrame("Frame", nil, row)
                grip:SetSize(18, 30)
                grip:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
                local gripBg = grip:CreateTexture(nil, "BACKGROUND", nil, 2)
                gripBg:SetAllPoints()
                gripBg:SetTexture(RC.UI.FLAT)
                local _zb = RC:GetColor("ui", "elementBackground")
                gripBg:SetVertexColor(_zb.r, _zb.g, _zb.b, 1)
                grip.bg = gripBg
                if isEditing then
                    local selBar = grip:CreateTexture(nil, "ARTWORK", nil, -1)
                    selBar:SetPoint("TOPLEFT", grip, "TOPLEFT", 1, -1)
                    selBar:SetPoint("BOTTOMLEFT", grip, "BOTTOMLEFT", 1, 1)
                    selBar:SetWidth(3)
                    selBar:SetTexture(RC.UI.FLAT)
                    do local _sg = RC:GetColor("ui", "borderSelected")
                       selBar:SetVertexColor(_sg.r, _sg.g, _sg.b, 1) end
                end
                grip:EnableMouse(true)
                local up = grip:CreateTexture(nil, "ARTWORK")
                up:SetSize(8, 8)
                up:SetPoint("CENTER", grip, "CENTER", 0, 5)
                up:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrowUp")
                local dn = grip:CreateTexture(nil, "ARTWORK")
                dn:SetSize(8, 8)
                dn:SetPoint("CENTER", grip, "CENTER", 0, -5)
                dn:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrow")
                local _gc = RC:GetColor("buttons", "xNormal")
                up:SetVertexColor(_gc.r, _gc.g, _gc.b, 1)
                dn:SetVertexColor(_gc.r, _gc.g, _gc.b, 1)
                grip:SetScript("OnEnter", function()
                    local _ag = RC:GetColor("ui", "accentGold")
                    up:SetVertexColor(_ag.r, _ag.g, _ag.b, 1)
                    dn:SetVertexColor(_ag.r, _ag.g, _ag.b, 1)
                    local _hb = RC:GetColor("buttons", "hoverBackground")
                    gripBg:SetVertexColor(_hb.r, _hb.g, _hb.b, 1)
                end)
                grip:SetScript("OnLeave", function()
                    up:SetVertexColor(_gc.r, _gc.g, _gc.b, 1)
                    dn:SetVertexColor(_gc.r, _gc.g, _gc.b, 1)
                    gripBg:SetVertexColor(_zb.r, _zb.g, _zb.b, 1)
                end)
                grip:SetScript("OnMouseDown", function(selfGrip, mb)
                    if mb ~= "LeftButton" then return end
                    dragState.dragging    = true
                    dragState.sourceIndex = row.stepIndex
                    dragState.rows        = stepRows
                    selfGrip:SetScript("OnUpdate", function()
                        if not dragState.dragging then return end
                        local ind = dragState.indicator
                        local _, cyq = GetCursorPosition()
                        cyq = cyq / UIParent:GetEffectiveScale()
                        local insertIndex = nil
                        for idx, r in ipairs(dragState.rows) do
                            if r:IsVisible() then
                                local top, bottom = r:GetTop(), r:GetBottom()
                                if top and bottom then
                                    if cyq > (top + bottom) / 2 then
                                        insertIndex = idx
                                        ind:ClearAllPoints()
                                        ind:SetPoint("TOPLEFT",  r, "TOPLEFT",  0, 2)
                                        ind:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, 2)
                                        ind:Show()
                                        break
                                    elseif idx == #dragState.rows then
                                        insertIndex = idx + 1
                                        ind:ClearAllPoints()
                                        ind:SetPoint("BOTTOMLEFT",  r, "BOTTOMLEFT",  0, -2)
                                        ind:SetPoint("BOTTOMRIGHT", r, "BOTTOMRIGHT", 0, -2)
                                        ind:Show()
                                    end
                                end
                            end
                        end
                        dragState.insertIndex = insertIndex
                    end)
                end)
                grip:SetScript("OnMouseUp", function(selfGrip, mb)
                    if mb ~= "LeftButton" or not dragState.dragging then return end
                    dragState.dragging = false
                    selfGrip:SetScript("OnUpdate", nil)
                    if dragState.indicator then dragState.indicator:Hide() end
                    local src = dragState.sourceIndex
                    local dst = dragState.insertIndex
                    dragState.insertIndex = nil
                    if not (src and dst) or dst == src or dst == src + 1 then return end
                    -- Reorders in place on the shared ordered array; Save()
                    -- below pushes the whole steps array as a full replace
                    -- to any mesh peers, not a per-index patch.
                    local edStep = editIdx and steps[editIdx] or nil
                    local snap = RR:SnapshotActiveStep(steps)
                    local moved = table.remove(steps, src)
                    if dst > src then dst = dst - 1 end
                    table.insert(steps, dst, moved)
                    if edStep then
                        for k = 1, #steps do
                            if steps[k] == edStep then SetEditIdx(k) break end
                        end
                    end
                    -- keep the route on the step it was on, not the index
                    RR:ReanchorActiveStep(snap)
                    Save()
                    Rerender()
                end)
            end

            if isEditing then
                local edBg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
                edBg:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -30)
                edBg:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -1, 1)
                edBg:SetTexture(RC.UI.FLAT)
                local _wb = RC:GetColor("ui", "windowBackground")
                edBg:SetVertexColor(_wb.r, _wb.g, _wb.b, 1)

                local edDiv = row:CreateTexture(nil, "ARTWORK")
                edDiv:SetPoint("TOPLEFT", row, "TOPLEFT", 1, -30)
                edDiv:SetPoint("TOPRIGHT", row, "TOPRIGHT", -1, -30)
                edDiv:SetHeight(1)
                edDiv:SetColorTexture(0, 0, 0, 1)
            end

            local idxFS = self:CreateFontString(row, "OVERLAY", nil, 11)
            idxFS:SetPoint("TOPLEFT", row, "TOPLEFT", 24, -8)
            idxFS:SetText(tostring(i))
            idxFS:SetTextColor(T_GOLD[1], T_GOLD[2], T_GOLD[3])

            local tIcon = row:CreateTexture(nil, "ARTWORK")
            tIcon:SetSize(16, 16)
            tIcon:SetPoint("TOPLEFT", row, "TOPLEFT", 41, -7)
            tIcon:SetTexture(StepIcon(step))
            tIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            if isDisabled then tIcon:SetAlpha(0.45) end

            local iconCount = 0
            -- boss slot items and the boss's set, read once per row: the
            -- width pass here and the icon pass below both use them
            local ovListC, ovSlotsC, dispSet
            if not isEditing then
                local a = step.actions
                ovListC = BossOverrideList(raidName, step)
                ovSlotsC = {}
                for _, ov in ipairs(ovListC) do ovSlotsC[ov.slot] = true end
                if a.reminders then
                    for _, r in ipairs(a.reminders) do
                        if r.text and r.text ~= "" then iconCount = iconCount + 1 end
                    end
                elseif a.reminderText and a.reminderText ~= "" then
                    iconCount = iconCount + 1
                end
                if a.slots then
                    for _, e in ipairs(SLOT_LIST) do
                        local itemId = a.slots[e[1]]
                        if itemId and itemId ~= 0 and not ovSlotsC[e[1]] then
                            iconCount = iconCount + 1
                        end
                    end
                end
                if a.trinket2 and a.trinket2 ~= 0 and not ovSlotsC[14] then iconCount = iconCount + 1 end
                if a.trinket1 and a.trinket1 ~= 0 and not ovSlotsC[13] then iconCount = iconCount + 1 end
                dispSet = a.gearSet
                if step.type == "encounter" and step.boss and step.boss ~= "" then
                    local gs = GetBossGearswap(raidName, step.boss)
                    dispSet = gs and ((step.when == "start") and gs.gearSet or gs.postCombatSet)
                end
                if dispSet and dispSet ~= "" then iconCount = iconCount + 1 end
                iconCount = iconCount + #ovListC
            end
            local textRight = -150
            if isActive and step.type == "kills" then textRight = -186 end
            if iconCount > 0 then textRight = textRight - 16 * iconCount - 4 end

            local sumFS = self:CreateFontString(row, "OVERLAY", nil, 11)
            sumFS:SetPoint("TOPLEFT", row, "TOPLEFT", 62, -9)
            sumFS:SetPoint("RIGHT", row, "RIGHT", textRight, 0)
            sumFS:SetJustifyH("LEFT")
            sumFS:SetWordWrap(false)
            local sumText = StepSummary(step)
            if isDisabled then
                sumText = sumText .. " |cff707070(off)|r"
            end
            sumFS:SetText(sumText)
            if isActive then
                sumFS:SetTextColor(T_WHITE[1], T_WHITE[2], T_WHITE[3])
            elseif isDisabled then
                sumFS:SetTextColor(T_GRAY[1], T_GRAY[2], T_GRAY[3])
            else
                sumFS:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
            end

            if isActive and step.type == "kills" then
                local cFS = self:CreateFontString(row, "OVERLAY", nil, 11)
                cFS:SetPoint("TOPRIGHT", row, "TOPRIGHT", -150, -9)
                cFS:SetText(RR:GetProgressText())
                cFS:SetTextColor(T_GREEN[1], T_GREEN[2], T_GREEN[3])
                activeCountFS = cFS
            end

            if not isEditing then
                local a = step.actions
                local px = -150
                if isActive and step.type == "kills" then px = -186 end
                local function MiniIcon(tex)
                    if not tex then return end
                    local mi = row:CreateTexture(nil, "ARTWORK")
                    mi:SetSize(14, 14)
                    mi:SetPoint("TOPRIGHT", row, "TOPRIGHT", px, -8)
                    mi:SetTexture(tex)
                    mi:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    if isDisabled then mi:SetAlpha(0.45) end
                    px = px - 16
                end
                if a.reminders then
                    for _, r in ipairs(a.reminders) do
                        if r.text and r.text ~= "" then MiniIcon(r.icon or ICON_QUESTION) end
                    end
                elseif a.reminderText and a.reminderText ~= "" then
                    MiniIcon(a.reminderIcon or ICON_QUESTION)
                end
                local ovSlots2 = ovSlotsC
                if a.slots then
                    for _, e in ipairs(SLOT_LIST) do
                        local itemId = a.slots[e[1]]
                        if itemId and itemId ~= 0 and not ovSlots2[e[1]] then
                            MiniIcon(ItemIcon(itemId, e[1]))
                        end
                    end
                end
                if a.trinket2 and a.trinket2 ~= 0 and not ovSlots2[14] then MiniIcon(ItemIcon(a.trinket2)) end
                if a.trinket1 and a.trinket1 ~= 0 and not ovSlots2[13] then MiniIcon(ItemIcon(a.trinket1)) end
                if dispSet and dispSet ~= "" then MiniIcon(GetSetIcon(dispSet)) end
                for _, ov in ipairs(ovListC) do
                    MiniIcon(ItemIcon(ov.id, ov.slot))
                end
            end

            local bx = -6
            local function PlaceBtn(b, width, yOff)
                b:SetFrameLevel(row:GetFrameLevel() + 12)
                b:SetPoint("TOPRIGHT", row, "TOPRIGHT", bx, yOff or -5)
                bx = bx - width - 3
                return b
            end
            local function RowBtn(label, width, onClick)
                local b = self.UI:CreateStyledButton(row, label, width, 20)
                b:SetScript("OnClick", onClick)
                return PlaceBtn(b, width)
            end

            PlaceBtn(self.UI:CreateXCloseButton(row, 16, function()
                local snap = RR:SnapshotActiveStep(steps)
                table.remove(steps, i)
                RR:ReanchorActiveStep(snap)
                if editIdx == i then
                    SetEditIdx(nil)
                elseif editIdx and editIdx > i then
                    SetEditIdx(editIdx - 1)
                end
                Save()
                Rerender()
            end), 16, -7)

            PlaceBtn(MakeArrowButton(row, false, function()
                if i < #steps then
                    local snap = RR:SnapshotActiveStep(steps)
                    steps[i], steps[i + 1] = steps[i + 1], steps[i]
                    RR:ReanchorActiveStep(snap)
                    if editIdx == i then SetEditIdx(i + 1)
                    elseif editIdx == i + 1 then SetEditIdx(i) end
                    Save()
                    Rerender()
                end
            end), 20)

            PlaceBtn(MakeArrowButton(row, true, function()
                if i > 1 then
                    local snap = RR:SnapshotActiveStep(steps)
                    steps[i], steps[i - 1] = steps[i - 1], steps[i]
                    RR:ReanchorActiveStep(snap)
                    if editIdx == i then SetEditIdx(i - 1)
                    elseif editIdx == i - 1 then SetEditIdx(i) end
                    Save()
                    Rerender()
                end
            end), 20)

            if trackingHere and not isActive and not isDisabled then
                RowBtn("Set Active", 66, function()
                    RR:SetActiveStep(i)
                end)
            end

            local zArrow = row:CreateTexture(nil, "OVERLAY")
            zArrow:SetSize(8, 8)
            zArrow:SetPoint("TOPLEFT", row, "TOPLEFT", 3, -10)
            zArrow:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrow")
            if isEditing then
                zArrow:SetTexCoord(0, 1, 0, 1)
            else
                zArrow:SetTexCoord(0, 1, 1, 1, 0, 0, 1, 0)
            end
            local zc = RC:GetColor("dropdown", "arrow")
            zArrow:SetVertexColor(zc.r, zc.g, zc.b, 1)

            row:SetScript("OnClick", function()
                if not isEditing then
                    SetEditIdx(i)
                    Rerender()
                    return
                end
                local top = row:GetTop()
                local scale = row:GetEffectiveScale()
                if top and scale and scale > 0 then
                    local _, cy = GetCursorPosition()
                    if (top - (cy / scale)) <= 30 then
                        SetEditIdx(nil)
                        Rerender()
                    end
                end
            end)
            row:SetScript("OnEnter", function()
                if not isEditing then
                    local _hb = RC:GetColor("buttons", "hoverBackground")
                    rowBg:SetVertexColor(_hb.r, _hb.g, _hb.b, 1)
                end
                if not isActive then
                    sumFS:SetTextColor(T_WHITE[1], T_WHITE[2], T_WHITE[3])
                end
                GameTooltip:SetOwner(row, "ANCHOR_TOPLEFT")
                GameTooltip:SetText(StepSummary(step), 1, 1, 1, 1, true)
                if step.desc and step.desc ~= "" then
                    GameTooltip:AddLine(step.desc, 0.7, 0.7, 0.7, true)
                end
                GameTooltip:AddLine(isEditing and RCL["Click header to close"] or RCL["Click to open"], 0.5, 0.5, 0.5)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function()
                GameTooltip:Hide()
                rowBg:SetVertexColor(rowRest.r, rowRest.g, rowRest.b, 1)
                if isActive then return end
                if isDisabled then
                    sumFS:SetTextColor(T_GRAY[1], T_GRAY[2], T_GRAY[3])
                else
                    sumFS:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
                end
            end)

            if isEditing then
                local ey = -34
                local LBL_X, FLD_X = 10, 100

                local function FieldLabel(txt)
                    local l = self:CreateFontString(row, "OVERLAY", nil, 11)
                    l:SetPoint("TOPLEFT", row, "TOPLEFT", LBL_X, ey)
                    l:SetText(txt)
                    l:SetTextColor(T_GOLD[1], T_GOLD[2], T_GOLD[3])
                    return l
                end

                local enCB = self.UI:CreateCheckbox(row, RCL["Step enabled"],
                    step.enabled ~= false)
                enCB:SetPoint("TOPLEFT", row, "TOPLEFT", LBL_X, ey + 2)
                enCB:SetScript("OnClick", function(cb)
                    step.enabled = cb:GetChecked() and true or false
                    Save()
                    Rerender()
                end)
                ey = ey - 28

                if step.type == "kills" then
                    local mobs = step.mobs

                    for mi = 1, #mobs do
                        local entry = mobs[mi]
                        local col = (mi - 1) % 2
                        if col == 0 then FieldLabel(mi == 1 and "Mobs:" or "") end
                        local cellX = FLD_X + col * 132
                        local cntEB = MakeEditBox(row, 30, tostring(entry.kills or 1), true,
                            function(txt, viaEnter, eb2)
                                local n = tonumber(txt) or 1
                                if n < 1 then n = 1 end
                                if n > 99 then n = 99 end
                                if n ~= entry.kills then
                                    entry.kills = n
                                    Save()
                                    if viaEnter then Rerender() end
                                end
                                if not viaEnter and eb2 then
                                    eb2:SetText(tostring(n))
                                    eb2:SetCursorPosition(0)
                                end
                            end)
                        cntEB:SetPoint("TOPLEFT", row, "TOPLEFT", cellX, ey + 2)

                        local mn = self:CreateFontString(row, "OVERLAY", nil, 10)
                        mn:SetPoint("TOPLEFT", row, "TOPLEFT", cellX + 30, ey)
                        mn:SetWidth(82)
                        mn:SetJustifyH("LEFT")
                        mn:SetWordWrap(false)
                        mn:SetText("x " .. (entry.mob or "?"))
                        mn:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])

                        local mx = self.UI:CreateXCloseButton(row, 12, function()
                            table.remove(mobs, mi)
                            Save()
                            Rerender()
                        end)
                        mx:SetPoint("TOPLEFT", row, "TOPLEFT", cellX + 114, ey + 1)
                        if col == 1 or mi == #mobs then ey = ey - 24 end
                    end

                    local rd = RC.raidData and RC.raidData[raidName]
                    local hasWings = rd and rd.trashSections and next(rd.trashSections) ~= nil
                    local mobPool

                    if hasWings then
                        local ALL_WINGS = "*"
                        local wingNames = {}
                        for sn in pairs(rd.trashSections) do
                            wingNames[#wingNames + 1] = sn
                        end
                        table.sort(wingNames)

                        local curWing = frame._routeMobWing
                        if curWing and curWing ~= ALL_WINGS and not rd.trashSections[curWing] then
                            curWing = nil
                        end
                        curWing = curWing or wingNames[1]
                        local allWings = (curWing == ALL_WINGS)

                        FieldLabel("Wing:")
                        local wingLabel = allWings and RCL["All wings"] or curWing
                        local wingDD = self.UI:CreateScrollableDropdown(row, 220, wingLabel, 8)
                        wingDD:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 4)
                        local wingItems = { { text = RCL["All wings"], value = ALL_WINGS } }
                        for _, sn in ipairs(wingNames) do
                            wingItems[#wingItems + 1] = { text = sn, value = sn }
                        end
                        wingDD:SetItems(wingItems, function(value)
                            frame._routeMobWing = value
                            Rerender()
                        end)
                        wingDD:SetSelectedValue(curWing, wingLabel)
                        ey = ey - 30

                        local seen = {}
                        if allWings then
                            mobPool = GatherTrashMobs(raidName)
                            for _, m in ipairs(mobPool) do seen[m] = true end
                        else
                            mobPool = {}
                            for _, m in ipairs(rd.trashSections[curWing]) do
                                if not seen[m] then mobPool[#mobPool + 1] = m; seen[m] = true end
                            end
                        end
                        -- Mobs already on this step stay pickable even when the
                        -- wing filter would exclude them, so a mob can never
                        -- vanish from the list it is visibly part of.
                        for _, e in ipairs(mobs) do
                            if e.mob and e.mob ~= "" and not seen[e.mob] then
                                mobPool[#mobPool + 1] = e.mob
                                seen[e.mob] = true
                            end
                        end
                        table.sort(mobPool)
                    else
                        mobPool = GatherTrashMobs(raidName)
                    end

                    FieldLabel("Add mob:")
                    local mobDD = self.UI:CreateScrollableDropdown(row, 220, RCL["Pick a mob..."], 10)
                    mobDD:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 4)
                    local mobItems = {}
                    for _, m in ipairs(mobPool) do
                        mobItems[#mobItems + 1] = { text = m, value = m }
                    end
                    mobDD:SetItems(mobItems, function(value)
                        for _, e in ipairs(mobs) do
                            if e.mob == value then
                                e.kills = math.min((e.kills or 1) + 1, 99)
                                Save()
                                Rerender()
                                return
                            end
                        end
                        mobs[#mobs + 1] = { mob = value, kills = 1 }
                        Save()
                        Rerender()
                    end)
                    ey = ey - 30
                else
                    FieldLabel("Boss:")
                    local bossDD = self.UI:CreateScrollableDropdown(row, 220,
                        (step.boss ~= "" and step.boss) or RCL["Pick a boss..."], 10)
                    bossDD:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 4)
                    local bossItems = {}
                    local rd = RC.raidData and RC.raidData[raidName]
                    if rd and rd.bosses then
                        for _, bn in ipairs(rd.bosses) do
                            bossItems[#bossItems + 1] = { text = bn, value = bn }
                        end
                    end
                    bossDD:SetItems(bossItems, function(value)
                        step.boss = value
                        Save()
                        Rerender()
                    end)
                    if step.boss ~= "" then bossDD:SetSelectedValue(step.boss, step.boss) end
                    ey = ey - 30

                    FieldLabel("Fires on:")
                    local whenLabels = {
                        start = "Pull (encounter start)",
                        ["end"] = "Kill (encounter end)",
                        wipe = "Wipe (any time, no gate)",
                    }
                    local whenDD = self.UI:CreateScrollableDropdown(row, 220,
                        whenLabels[step.when] or whenLabels.start, 4)
                    whenDD:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 4)
                    whenDD:SetItems({
                        { text = whenLabels.start,  value = "start" },
                        { text = whenLabels["end"], value = "end" },
                        { text = whenLabels.wipe,   value = "wipe" },
                    }, function(value)
                        step.when = value
                        Save()
                        Rerender()
                    end)
                    whenDD:SetSelectedValue(step.when, whenLabels[step.when] or whenLabels.start)
                    ey = ey - 30
                end

                FieldLabel("Label:")
                local descEB = MakeEditBox(row, 220, step.desc, false, function(txt, viaEnter)
                    if txt ~= step.desc then
                        step.desc = txt
                        Save()
                        if viaEnter then Rerender() end
                    end
                end)
                descEB:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 2)
                ey = ey - 32

                local a = step.actions
                frame._routeReveal = frame._routeReveal or {}
                local revealKey = raidName .. ":" .. i .. ":"
                local function Revealed(k) return frame._routeReveal[revealKey .. k] end
                local function Reveal(k) frame._routeReveal[revealKey .. k] = true end
                local function Unreveal(k) frame._routeReveal[revealKey .. k] = nil end

                local bossGS, bossGSField
                local isBossStep = step.type == "encounter" and step.boss and step.boss ~= "" and true or false
                if isBossStep then
                    bossGS = GetBossGearswap(raidName, step.boss, false)
                    bossGSField = (step.when == "start") and "gearSet" or "postCombatSet"
                    -- One-time migration: a legacy per-step gear pick moves into
                    -- the boss's shared Raid Config entry the first time this
                    -- boss step is opened, then the step-local field is cleared.
                    if a.gearSet ~= nil then
                        if a.gearSet ~= "" then
                            bossGS = bossGS or GetBossGearswap(raidName, step.boss, true)
                            if bossGS and (not bossGS[bossGSField] or bossGS[bossGSField] == "") then
                                RC:SetBossGearSet(bossGS, bossGSField, a.gearSet)
                            end
                        end
                        a.gearSet = nil
                        Save()
                    end
                end
                local sharedSet = bossGS and bossGS[bossGSField] or ""
                local hasGear  = (a.gearSet ~= nil and a.gearSet ~= "")
                    or (sharedSet ~= "") or Revealed("gear")

                if isBossStep then
                    -- Read from the same config the gear picker above writes
                    -- to, so this summary matches while remote editing.
                    local prof2 = RC.GetEditableActiveProfile and RC:GetEditableActiveProfile(raidName)
                    local bCfg = prof2 and prof2.bosses and prof2.bosses[step.boss]
                    local abNames = {}
                    if bCfg and bCfg.abilities then
                        for k, v in pairs(bCfg.abilities) do
                            if k ~= "gearswap" and type(v) == "table" and v.enabled ~= false then
                                local nm = k:gsub("(%u)", " %1")
                                nm = nm:sub(1, 1):upper() .. nm:sub(2)
                                abNames[#abNames + 1] = nm
                            end
                        end
                    end
                    if #abNames > 0 then
                        table.sort(abNames)
                        FieldLabel("Reminders:")
                        local rl = self:CreateFontString(row, "OVERLAY", nil, 10)
                        rl:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey)
                        rl:SetWidth(240)
                        rl:SetJustifyH("LEFT")
                        rl:SetWordWrap(true)
                        rl:SetText(table.concat(abNames, ", ")
                            .. RCL[" |cff808080(from Raid Config)|r"])
                        rl:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
                        ey = ey - math.max(18, (rl:GetStringHeight() or 12) + 6)
                    end
                    local ovList = BossOverrideList(raidName, step)
                    local ovParts = {}
                    for _, ov in ipairs(ovList) do
                        local sn = SLOT_NAME[ov.slot]
                            or (ov.slot == 13 and "Trinket 1")
                            or (ov.slot == 14 and "Trinket 2")
                            or ("Slot " .. tostring(ov.slot))
                        ovParts[#ovParts + 1] = sn .. ": "
                            .. (ItemName(ov.id) or ("item " .. tostring(ov.id)))
                    end
                    do
                        local bCfg2 = bCfg
                        local fe = bCfg2 and bCfg2.forceEquip
                        if step.when ~= "start" and fe and fe.deathConfig
                           and fe.deathConfig ~= "" then
                            ovParts[#ovParts + 1] = "Trinket config switch"
                        end
                    end
                    if #ovParts > 0 then
                        FieldLabel("Overrides:")
                        local ol = self:CreateFontString(row, "OVERLAY", nil, 10)
                        ol:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey)
                        ol:SetWidth(240)
                        ol:SetJustifyH("LEFT")
                        ol:SetWordWrap(true)
                        ol:SetText(table.concat(ovParts, ", ")
                            .. RCL[" |cff808080(from Raid Config)|r"])
                        ol:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
                        ey = ey - math.max(18, (ol:GetStringHeight() or 12) + 6)
                    end
                end
                local hasT1    = (a.trinket1 ~= nil and a.trinket1 ~= 0) or Revealed("t1")
                local hasT2    = (a.trinket2 ~= nil and a.trinket2 ~= 0) or Revealed("t2")
                local hasSlots = (a.slots ~= nil and next(a.slots) ~= nil) or Revealed("slots")
                local remFilter = Revealed("rem")
                local hasRem   = (a.reminders ~= nil and #a.reminders > 0)
                              or (remFilter ~= nil)

                local addItems = {}
                if not hasGear  then addItems[#addItems + 1] = { text = RCL["Gear set"],  value = "gear" } end
                if not hasT1    then addItems[#addItems + 1] = { text = RCL["Trinket 1"], value = "t1" } end
                if not hasT2    then addItems[#addItems + 1] = { text = RCL["Trinket 2"], value = "t2" } end
                if not hasSlots then addItems[#addItems + 1] = { text = RCL["Equip item in slot"], value = "slots" } end
                addItems[#addItems + 1] = { text = RCL["Reminder: potion"], value = "rem_potion" }
                addItems[#addItems + 1] = { text = RCL["Reminder: engineering"], value = "rem_engi" }
                addItems[#addItems + 1] = { text = RCL["Reminder: custom text"], value = "rem_all" }
                if #addItems > 0 then
                    FieldLabel("Add action:")
                    local addDD = self.UI:CreateScrollableDropdown(row, 220, RCL["Add action..."], 8)
                    addDD:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 4)
                    addDD:SetItems(addItems, function(value)
                        local filter = value:match("^rem_(%a+)$")
                        if filter then
                            frame._routeReveal[revealKey .. "rem"] = filter
                        else
                            Reveal(value)
                        end
                        frame._routeFlash = revealKey
                            .. (filter and "rem" or value)
                        Rerender()
                    end)
                    ey = ey - 30
                end

                local function SectionLabel(txt, k, clearFn)
                    local l = FieldLabel(txt)
                    if frame._routeFlash == revealKey .. k then
                        frame._routeFlash = nil
                        local ac = RC:GetColor("ui", "accentGold")
                        l:SetTextColor(ac.r, ac.g, ac.b)
                        C_Timer.After(1.6, function()
                            if l.SetTextColor then
                                l:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])
                            end
                        end)
                    end
                    local x = self.UI:CreateXCloseButton(row, 12, function()
                        clearFn()
                        Unreveal(k)
                        Save()
                        Rerender()
                    end)
                    x:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, ey + 1)
                    return l
                end

                if hasGear then
                    local gs, gsField = bossGS, bossGSField
                    SectionLabel("Gear set:", "gear", function()
                        if isBossStep then
                            -- same flags as the Raid Config gear page
                            if gs then
                                RC:SetBossGearSet(gs, gsField, "")
                                local p = RC:GetEditableActiveProfile(raidName)
                                RC:RecomputeEncounterEnabled(p and p.bosses and p.bosses[step.boss])
                            end
                        else
                            a.gearSet = nil
                        end
                    end)
                    local curSet = (isBossStep and gs) and (gs[gsField] or "") or (a.gearSet or "")
                    local setDD = self.UI:CreateScrollableDropdown(row, 220,
                        (curSet ~= "" and curSet) or RCL["None"], 10)
                    setDD:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 4)
                    local setItems = { { text = RCL["None (don't swap)"], value = "" } }
                    for _, sn in ipairs(GatherSets()) do
                        setItems[#setItems + 1] = { text = sn, value = sn, icon = GetSetIcon(sn) }
                    end
                    setDD:SetItems(setItems, function(value)
                        if isBossStep then
                            gs = gs or (value ~= "" and GetBossGearswap(raidName, step.boss, true)) or nil
                            if gs then
                                RC:SetBossGearSet(gs, gsField, value)
                                local p = RC:GetEditableActiveProfile(raidName)
                                RC:RecomputeEncounterEnabled(p and p.bosses and p.bosses[step.boss])
                            end
                        else
                            a.gearSet = value
                        end
                        Save()
                        Rerender()
                    end)
                    setDD:SetSelectedValue(curSet, (curSet ~= "" and curSet) or "None")
                    if curSet ~= "" then setDD:SetSelectedIcon(GetSetIcon(curSet)) end
                    ey = ey - 30
                    if isBossStep then
                        local sh = self:CreateFontString(row, "OVERLAY", nil, 9)
                        sh:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 6)
                        sh:SetText(RCL["Shared with Raid Config - one setting, both places."])
                        sh:SetTextColor(T_GRAY[1], T_GRAY[2], T_GRAY[3])
                        ey = ey - 14
                    end
                end

                local function TrinketRow(labelText, key, rkey)
                    SectionLabel(labelText, rkey, function() a[key] = nil end)
                    local cur = a[key]
                    local curName = "None"
                    if cur and cur ~= 0 then curName = ItemName(cur) end
                    local dd = self.UI:CreateScrollableDropdown(row, 220, curName, 10)
                    dd:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 4)
                    dd:SetItems(GatherTrinketItems(cur), function(value)
                        if value == 0 then
                            a[key] = nil
                        else
                            a[key] = value
                        end
                        Save()
                        Rerender()
                    end)
                    dd:SetSelectedValue(cur or 0, curName)
                    if cur and cur ~= 0 then dd:SetSelectedIcon(ItemIcon(cur)) end
                    ey = ey - 30
                end
                if hasT1 then TrinketRow("Trinket 1:", "trinket1", "t1") end
                if hasT2 then TrinketRow("Trinket 2:", "trinket2", "t2") end

                if hasSlots then
                    SectionLabel("Slot gear:", "slots", function() a.slots = nil end)
                    local ovrSlot = frame._routeOvrSlot or 1
                    local slotDD = self.UI:CreateScrollableDropdown(row, 104,
                        SLOT_NAME[ovrSlot] or RCL["Head"], 8)
                    slotDD:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 4)
                    local slotItems = {}
                    for _, e in ipairs(SLOT_LIST) do
                        slotItems[#slotItems + 1] = { text = e[2], value = e[1] }
                    end
                    slotDD:SetItems(slotItems, function(value)
                        frame._routeOvrSlot = value
                        Rerender()
                    end)
                    slotDD:SetSelectedValue(ovrSlot, SLOT_NAME[ovrSlot] or "Head")

                    local curSlotItem = a.slots and a.slots[ovrSlot]
                    local slotItemDD = self.UI:CreateScrollableDropdown(row, 210,
                        (curSlotItem and curSlotItem ~= 0) and ItemName(curSlotItem) or RCL["Pick an item..."], 10)
                    slotItemDD:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X + 110, ey + 4)
                    slotItemDD:SetItems(GatherSlotItems(ovrSlot, curSlotItem),
                        function(value)
                            local vid, vench = value, nil
                            if type(value) == "string" then
                                local i2, e2 = value:match("^(%d+):(%d+)$")
                                vid, vench = tonumber(i2), tonumber(e2)
                            end
                            a.slots = a.slots or {}
                            a.slots[ovrSlot] = vid
                            if vench ~= nil and vid then
                                RC.db.itemEnchantPreference =
                                    RC.db.itemEnchantPreference or {}
                                RC.db.itemEnchantPreference[vid] = vench
                            end
                            for _, e in ipairs(SLOT_LIST) do
                                if not a.slots[e[1]] then
                                    frame._routeOvrSlot = e[1]
                                    break
                                end
                            end
                            Save()
                            Rerender()
                        end)
                    if curSlotItem and curSlotItem ~= 0 then
                        slotItemDD:SetSelectedValue(curSlotItem, ItemName(curSlotItem))
                        slotItemDD:SetSelectedIcon(ItemIcon(curSlotItem))
                    end
                    ey = ey - 30

                    if a.slots then
                        for _, e in ipairs(SLOT_LIST) do
                            local invSlot, slotName = e[1], e[2]
                            local itemId = a.slots[invSlot]
                            if itemId and itemId ~= 0 then
                                local oi = row:CreateTexture(nil, "ARTWORK")
                                oi:SetSize(14, 14)
                                oi:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey - 1)
                                oi:SetTexture(ItemIcon(itemId, invSlot) or ICON_QUESTION)
                                oi:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                                local ot = self:CreateFontString(row, "OVERLAY", nil, 10)
                                ot:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X + 18, ey - 2)
                                local chipTxt = slotName .. ": " .. ItemName(itemId)
                                local pref = RC.db.itemEnchantPreference
                                    and RC.db.itemEnchantPreference[itemId]
                                if pref and pref ~= 0 then
                                    local elbl
                                    local GMx = RC.GearManager
                                    if GMx and GMx.FindBagCopy then
                                        local eb, es = GMx:FindBagCopy(itemId, pref)
                                        if eb then
                                            local elk = C_Container.GetContainerItemLink(eb, es)
                                            elbl = SlotEnchantLabel(elk, pref, eb, es)
                                        end
                                    end
                                    elbl = elbl or ("Enchant " .. tostring(pref))
                                    local tg = (RC.UI.TEXT and RC.UI.TEXT.green)
                                        or { 0.45, 1, 0.45 }
                                    chipTxt = chipTxt .. string.format(
                                        " |cff%02x%02x%02x%s|r",
                                        (tg[1] or 0.45) * 255,
                                        (tg[2] or 1) * 255,
                                        (tg[3] or 0.45) * 255, elbl)
                                end
                                ot:SetText(chipTxt)
                                ot:SetTextColor(T_NORM[1], T_NORM[2], T_NORM[3])

                                local ox = self.UI:CreateXCloseButton(row, 14, function()
                                    a.slots[invSlot] = nil
                                    if not next(a.slots) then a.slots = nil end
                                    Save()
                                    Rerender()
                                end)
                                ox:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X + 230, ey + 2)
                                ey = ey - 22
                            end
                        end
                    end
                    ey = ey - 4
                end

                if hasRem then
                    SectionLabel("Reminders:", "rem", function()
                        a.reminders = nil
                    end)
                    a.reminders = a.reminders or {}
                    local rems = a.reminders

                    local firstRow = true
                    for ri = 1, #rems do
                        local r = rems[ri]
                        if r.itemId == "dummy"
                           and r.icon == "Interface\\Icons\\INV_Misc_Toy_04" then
                            r.icon = "Interface\\Icons\\INV_Crate_02"
                        end
                        if not firstRow then FieldLabel("") end
                        firstRow = false

                        local iconBtn = CreateFrame("Button", nil, row)
                        iconBtn:SetSize(20, 20)
                        iconBtn:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 1)
                        local ibTex = iconBtn:CreateTexture(nil, "ARTWORK")
                        ibTex:SetAllPoints()
                        ibTex:SetTexture(r.icon or ICON_QUESTION)
                        ibTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        local ibBorder = self.UI:CreateSimpleBorder(iconBtn)
                        self.UI:UpdateBorderColor(ibBorder, _bBlack)
                        iconBtn:SetScript("OnEnter", function()
                            self.UI:UpdateBorderColor(ibBorder, _acGold)
                            GameTooltip:SetOwner(iconBtn, "ANCHOR_TOP")
                            GameTooltip:SetText(RCL["Reminder icon"], 1, 1, 1)
                            GameTooltip:Show()
                        end)
                        iconBtn:SetScript("OnLeave", function()
                            self.UI:UpdateBorderColor(ibBorder, _bBlack)
                            GameTooltip:Hide()
                        end)
                        iconBtn:SetScript("OnClick", function()
                            local GM = RC.GearManager
                            if GM and GM.ShowIconPickerGrid then
                                GM:ShowIconPickerGrid(function(icon)
                                    r.icon = icon
                                    Save()
                                    Rerender()
                                end, r.icon, iconBtn)
                            end
                        end)

                        local remEB = MakeEditBox(row, 140, r.text or "", false,
                            function(txt, viaEnter)
                                if txt ~= (r.text or "") then
                                    r.text = txt
                                    Save()
                                    if viaEnter then Rerender() end
                                end
                            end)
                        remEB:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X + 26, ey + 2)

                        local ttsCB = self.UI:CreateCheckbox(row, "TTS", r.tts ~= false)
                        ttsCB:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X + 174, ey + 2)
                        ttsCB:SetScript("OnClick", function(cb)
                            r.tts = cb:GetChecked() and true or false
                            Save()
                        end)

                        local dEB = MakeEditBox(row, 26, tostring(r.delay or 0), true,
                            function(txt, viaEnter, eb2)
                                local n = tonumber(txt) or 0
                                if n < 0 then n = 0 end
                                if n > 600 then n = 600 end
                                n = math.floor(n)
                                if n ~= (r.delay or 0) then
                                    r.delay = (n > 0) and n or nil
                                    Save()
                                end
                                if not viaEnter and eb2 then
                                    eb2:SetText(tostring(n))
                                    eb2:SetCursorPosition(0)
                                end
                            end)
                        dEB:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X + 224, ey + 2)
                        local dLbl = self:CreateFontString(row, "OVERLAY", nil, 9)
                        dLbl:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X + 252, ey - 3)
                        dLbl:SetText(RCL["s late"])
                        dLbl:SetTextColor(T_GRAY[1], T_GRAY[2], T_GRAY[3])

                        local rx = self.UI:CreateXCloseButton(row, 12, function()
                            table.remove(rems, ri)
                            Save()
                            Rerender()
                        end)
                        rx:SetPoint("TOPRIGHT", row, "TOPRIGHT", -8, ey + 1)
                        ey = ey - 28
                    end

                    local pickLabel = "Add: pick item..."
                    if remFilter == "potion" then pickLabel = "Add: pick a potion..." end
                    if remFilter == "engi" then pickLabel = "Add: pick engi item..." end
                    local quickDD = self.UI:CreateScrollableDropdown(row, 176, pickLabel, 10)
                    quickDD:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 4)
                    quickDD:SetItems(GatherReminderItems(remFilter, isRemoteRoute), function(value)
                        if value and value ~= 0 then
                            if value == "dummy" then
                                rems[#rems + 1] = {
                                    text = RCL["Use Target Dummy"],
                                    icon = "Interface\\Icons\\INV_Crate_02",
                                    itemId = "dummy",
                                    tts = true,
                                }
                            else
                                rems[#rems + 1] = {
                                    text = RCL["Use "] .. ItemName(value),
                                    icon = ItemIcon(value),
                                    itemId = value,
                                    tts = true,
                                }
                            end
                            Save()
                            Rerender()
                        end
                    end)

                    local addTxtBtn = self.UI:CreateStyledButton(row, RCL["+ Text"], 50, 20)
                    addTxtBtn:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X + 182, ey + 2)
                    addTxtBtn:SetScript("OnClick", function()
                        rems[#rems + 1] = { text = "", tts = true,
                            icon = "Interface\\Icons\\INV_Misc_Note_01" }
                        Save()
                        Rerender()
                    end)
                    ey = ey - 30

                    local remNote = self:CreateFontString(row, "OVERLAY", nil, 9)
                    remNote:SetPoint("TOPLEFT", row, "TOPLEFT", FLD_X, ey + 4)
                    remNote:SetText(RCL["Item reminders clear when used"])
                    remNote:SetTextColor(T_GRAY[1], T_GRAY[2], T_GRAY[3])
                    ey = ey - 18
                end

                local testBtn = self.UI:CreateStyledButton(row, RCL["Test Actions"], 90, 22)
                testBtn:SetPoint("TOPLEFT", row, "TOPLEFT", LBL_X, ey)
                testBtn:SetScript("OnClick", function()
                    if isRemoteRoute then
                        RC:Print(RCL["Test Actions fires the LOCAL runtime - not available while remote editing."])
                        return
                    end
                    RR:FireStepActions(step)
                end)
                testBtn:HookScript("OnEnter", function()
                    GameTooltip:SetOwner(testBtn, "ANCHOR_TOP")
                    GameTooltip:SetText(RCL["Fire this step's gear swap and reminder right now (out of combat: equips immediately)."], 1, 1, 1, 1, true)
                    GameTooltip:Show()
                end)
                testBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

                local dupBtn = self.UI:CreateStyledButton(row, RCL["Duplicate"], 70, 22)
                dupBtn:SetPoint("TOPLEFT", row, "TOPLEFT", LBL_X + 96, ey)
                dupBtn:SetScript("OnClick", function()
                    local snap = RR:SnapshotActiveStep(steps)
                    table.insert(steps, i + 1, CopyStep(step))
                    RR:ReanchorActiveStep(snap)
                    SetEditIdx(i + 1)
                    Save()
                    Rerender()
                end)
                ey = ey - 30

                row:SetHeight(-ey + 8)
                cy = cy - (-ey + 8) - 4
            else
                cy = cy - 34
            end
        end

        cy = cy - 4
        local addKill = self.UI:CreateStyledButton(stepsCard, RCL["+ Kill Step"], 90, 22)
        addKill:SetPoint("TOPLEFT", stepsCard, "TOPLEFT", 12, cy)
        addKill:SetScript("OnClick", function()
            steps[#steps + 1] = { type = "kills", mob = "", kills = 1, desc = "", actions = {} }
            SetEditIdx(#steps)
            Save()
            Rerender()
        end)

        local addBoss = self.UI:CreateStyledButton(stepsCard, RCL["+ Boss Step"], 90, 22)
        addBoss:SetPoint("TOPLEFT", stepsCard, "TOPLEFT", 108, cy)
        addBoss:SetScript("OnClick", function()
            steps[#steps + 1] = { type = "encounter", boss = "", when = "start", desc = "", actions = {} }
            SetEditIdx(#steps)
            Save()
            Rerender()
        end)
        cy = cy - 30

        stepsCard:SetContentHeight(-cy)
        yPos = yPos - stepsCard:GetHeight() - 10

        end

        RR._uiFrame = frame
        RR._uiRefresh = function()
            if not (frame and frame.IsVisible and frame:IsVisible()) then return end
            local cs = frame.configState
            if not (cs and cs.selectedEncounterType == "route" and cs.selectedRaid == raidName) then return end
            RC:ShowInlineAbilityConfig(frame, raidName, "Route", "route", nil, true)
        end
        RR._uiCountUpdate = function()
            if not (frame and frame.IsVisible and frame:IsVisible()) then return end
            local cs = frame.configState
            if not (cs and cs.selectedEncounterType == "route" and cs.selectedRaid == raidName) then return end
            if statusFS then statusFS:SetText(RR:GetStatusText(raidName)) end
            if activeCountFS then
                activeCountFS:SetText(RR:GetProgressText())
            end
        end

        return yPos
    end

    RC:DebugPrint("Sidebar Raid Route loaded", "route")
