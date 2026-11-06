------------------------------------------------------------------------
-- Readycheck - Sidebar Shell: Window & Page Contract
-- Builds the /rc config window frame and compatFrame shim, and owns
-- ShowSidebarPanel - the single dispatcher every sidebar button calls.
-- Page functions are handed compatFrame (not the real window frame),
-- render into compatFrame.scrollChild, and must call
-- RC:UpdateSidebarScrollbar(sidebarConfigFrame, height) when done.
-- ClearSidebarContent/RestoreScrollPosition (Raids_Nav.lua) wipe and
-- restore scroll. Capture GetValue() via preserveScroll=true before
-- clearing (dropdown onChange, move/toggle) to survive a rebuild;
-- back/navigate-away calls omit it and reset to top.
------------------------------------------------------------------------
-- Taint-safe API locals (fallbacks on RC.Compat, built in Core; never write _G)
local pairs, ipairs, type = pairs, ipairs, type
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
RC._sbs = RC._sbs or {}
local _sbs = RC._sbs
local SIDEBAR, TEXT = _sbs.SIDEBAR, _sbs.TEXT

-- Where the back button lands when there is no raid/encounter to pop back
-- to: SidebarState.currentPanel -> page method. Four of these pages live
-- in companion addons the user can untick (Readycheck_Reminders for
-- execute, Readycheck_Consumables for the three bar pages), so the back
-- handler looks the method up instead of calling it, and falls through to
-- the welcome page when it is not there. Unlike the sidebar's normal
-- dispatcher this path never LoadAddOns: reaching it means the page was
-- already open, so the module is already up unless it is disabled.
local BACK_PANELS = {
    execute             = "ShowSidebarExecuteSettings",
    trinkets            = "ShowSidebarTrinketSwapConfig",
    gear_manager        = "ShowSidebarGearManagerConfig",
    consumables_checker = "ShowSidebarConsumablesCheckerConfig",
    consumables_bar     = "ShowSidebarConsumablesHelperConfig",
    potions_bar         = "ShowSidebarPotionsBarConfig",
    equipment_reminder  = "ShowSidebarFastWeaponConfig",
    hotswap             = "ShowSidebarHotswapMacros",
    profile_export      = "ShowSidebarProfileExport",
}

    function RC:CreateCompactRaidProfileBar(parent, yPos, raidName, frame, refreshFn)
        if not raidName or not parent then return yPos end
        local function BarRefresh()
            if refreshFn then
                refreshFn()
            else
                RC:OpenRaidBossPage(frame, raidName)
            end
        end

        local raidStructure
        local _rem = RC.remoteEditMode
        if _rem and _rem.raidKey == raidName and RC._remoteEditData then
            raidStructure = RC._remoteEditData
        else
            raidStructure = self:GetRaidProfileStructure(raidName)
        end
        if not raidStructure then return yPos end

        local profileName = raidStructure.activeProfile or "Default"
        local profileNames = {}
        for pName in pairs(raidStructure.profiles or {}) do
            table.insert(profileNames, pName)
        end
        table.sort(profileNames)

        local barFrame = CreateFrame("Frame", nil, parent)
        barFrame:SetHeight(22)
        barFrame:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
        barFrame:SetPoint("RIGHT",   parent, "RIGHT",   -20, 0)

        frame._profileBarFrame = barFrame
        -- How to redraw the raid page this bar sits on, for an import that
        -- arrives while it is open (RC:RefreshAfterImport). Good for as
        -- long as this bar is on screen.
        RC._raidPageRedraw = { bar = barFrame, fn = BarRefresh }
        frame._profileBarGen = (frame._profileBarGen or 0) + 1
        local profileDropdown = self.UI:CreateScrollableDropdown(barFrame, 200, profileName, 11)
        profileDropdown:SetPoint("LEFT", barFrame, "LEFT", 0, 0)
        profileDropdown:SetHeight(22)

        do
            local profileItems = {}
            for _, pName in ipairs(profileNames) do
                table.insert(profileItems, { text = pName, value = pName })
            end
            profileDropdown:SetItems(profileItems, function(value)
                local _rem2 = RC.remoteEditMode
                if _rem2 and _rem2.raidKey == raidName and RC._remoteEditData then
                    RC._remoteEditData.activeProfile = value
                    RC:SaveConfigurationToProfile()
                else
                    RC:SetActiveRaidProfile(raidName, value)
                end
                -- preserveScroll=true: keeps scroll position across the rebuild triggered by switching profiles.
                C_Timer.After(0.05, function()
                    RC:ClearSidebarContent(RC.sidebarConfigFrame, true)
                    BarRefresh()
                    RC:RestoreScrollPosition(RC.sidebarConfigFrame)
                end)
            end)
            profileDropdown:SetSelectedValue(profileName, profileName)
        end

        local manageDropdown = self.UI:CreateScrollableDropdown(barFrame, 110, RCL["Manage"], 11)
        manageDropdown:SetWidth(110)
        manageDropdown:SetHeight(22)
        manageDropdown:SetPoint("RIGHT", barFrame, "RIGHT", 0, 0)
        profileDropdown:SetPoint("RIGHT", manageDropdown, "LEFT", -6, 0)
        local chipZone = CreateFrame("Frame", nil, barFrame)
        chipZone:SetPoint("LEFT", barFrame, "LEFT", 0, 0)
        chipZone:SetPoint("RIGHT", profileDropdown, "LEFT", -14, 0)
        chipZone:SetHeight(22)
        chipZone:SetClipsChildren(true)
        chipZone._gen = frame._profileBarGen
        frame._profileBarChipZone = chipZone
        if manageDropdown.SetSearchEnabled then manageDropdown:SetSearchEnabled(false) end

        do
            local otherProfiles = {}
            for _, pName in ipairs(profileNames) do
                if pName ~= profileName then
                    table.insert(otherProfiles, pName)
                end
            end
            local builtInProfile = RC.builtInProfiles
                and RC.builtInProfiles[raidName]
                and RC.builtInProfiles[raidName][1]

            -- No preserveScroll here: new/rename/delete/merge/import change the profile list
            -- itself, so the rebuild resets scroll to top.
            local function ReloadBar()
                C_Timer.After(0.05, function()
                    RC:ClearSidebarContent(RC.sidebarConfigFrame)
                    BarRefresh()
                end)
            end

            local function OpenMergePicker()
                if #otherProfiles == 0 then return end
                if manageDropdown._mergePicker then
                    manageDropdown._mergePicker:Hide()
                    manageDropdown._mergePicker:SetParent(nil)
                    manageDropdown._mergePicker = nil
                end

                local picker = RC.UI:CreateScrollableDropdown(barFrame, 200, RCL["Select profile to merge..."], 12)
                manageDropdown._mergePicker = picker

                picker:ClearAllPoints()
                picker:SetPoint("LEFT",  manageDropdown, "LEFT", 0, 0)
                picker:SetPoint("RIGHT", manageDropdown, "RIGHT", 0, 0)
                picker:SetFrameLevel((manageDropdown:GetFrameLevel() or 0) + 4)

                local function TearDown()
                    if manageDropdown._mergePicker == picker then
                        manageDropdown._mergePicker = nil
                    end
                    if picker.menu then picker.menu:Hide() end
                    picker:Hide()
                    picker:SetParent(nil)
                end

                local function OpenMenu(dd)
                    if not dd or not dd.menu then return end
                    if RC.UI._openDropdown and RC.UI._openDropdown ~= dd then
                        local other = RC.UI._openDropdown
                        if other.menu then other.menu:Hide() end
                        other.isOpen = false
                    end
                    dd.menu:Show()
                    dd.isOpen = true
                    RC.UI._openDropdown = dd
                end

                local srcItems = {
                    {
                        text       = RCL["Back"],
                        value      = "__back__",
                        icon       = "Interface\\AddOns\\Readycheck\\Media\\arrowLeft",
                        iconColor  = RC:GetColor("dropdown", "arrow"),
                        iconNoCrop = true,
                        iconBorder = true,
                        iconSize   = 10,
                    },
                }
                for _, sourceName in ipairs(otherProfiles) do
                    table.insert(srcItems, { text = sourceName, value = sourceName })
                end
                picker:SetItems(srcItems, function(value)
                    if value == "__back__" then
                        TearDown()
                        C_Timer.After(0, function() OpenMenu(manageDropdown) end)
                        return
                    end
                    local sourceName = value
                    TearDown()
                    RC.UI:CreateConfirmDialog(RCL["Merge Profile"],
                        RCL["Merge '"] .. sourceName .. RCL["' into '"] .. profileName .. RCL["'?\n\nCopies anything '"] .. profileName .. RCL["' is missing from '"] .. sourceName .. RCL["'. Existing settings stay as-is. '"] .. sourceName .. RCL["' is not deleted."],
                        function()
                            if RC:MergeRaidProfiles(raidName, sourceName, profileName) then
                                ReloadBar()
                            end
                        end,
                        nil,
                        RCL["Merge"],
                        false)
                end)

                picker.menu:HookScript("OnHide", function()
                    C_Timer.After(0, function()
                        if manageDropdown._mergePicker == picker then TearDown() end
                    end)
                end)

                C_Timer.After(0, function() OpenMenu(picker) end)
            end

            local manageItems = {
                { text = RCL["New profile..."],    value = "__new__" },
                { text = RCL["Rename profile..."],  value = "__rename__" },
                { text = RCL["Delete profile..."],  value = "__delete__" },
                { text = RCL["Export profile..."],  value = "__export__" },
                { text = RCL["Import profile..."],  value = "__import__" },
            }
            if #otherProfiles > 0 then
                table.insert(manageItems, { text = RCL["Merge from profile..."], value = "__merge__" })
            end
            if builtInProfile then
                table.insert(manageItems, { text = RCL["Built-in: "] .. builtInProfile.name, value = "__builtin__" })
            end

            manageDropdown:SetItems(manageItems, function(value)
                manageDropdown:SetSelectedValue("__manage__", "Manage")

                if value == "__new__" then
                    RC.UI:CreateInputDialog("New Profile", "Enter name for new profile:", "", function(newName)
                        if newName and newName ~= "" then
                            if RC:CreateRaidProfile(raidName, newName) then
                                RC:SetActiveRaidProfile(raidName, newName)
                                ReloadBar()
                            end
                        end
                    end)
                elseif value == "__rename__" then
                    RC.UI:CreateInputDialog("Rename Profile",
                        "Enter new name for '" .. profileName .. "':",
                        profileName,
                        function(newName)
                            if newName and newName ~= "" and newName ~= profileName then
                                if RC:RenameRaidProfile(raidName, profileName, newName) then
                                    ReloadBar()
                                end
                            end
                        end)
                elseif value == "__delete__" then
                    RC.UI:CreateConfirmDialog(RCL["Delete Profile"],
                        RCL["Delete profile '"] .. profileName .. RCL["'?\n\nThis cannot be undone."],
                        function()
                            if RC:DeleteRaidProfile(raidName, profileName) then
                                ReloadBar()
                            end
                        end,
                        nil, RCL["Delete"], true)
                elseif value == "__export__" then
                    local exportString = RC:ExportRaidProfile(raidName, profileName)
                    if exportString then
                        RC:ShowExportDialog(exportString)
                    end
                elseif value == "__import__" then
                    -- The one import window: it imports and activates a
                    -- raid profile itself (RC:ImportAny), and takes any
                    -- other Readycheck export too. The page under this
                    -- bar is redrawn by RC:RefreshAfterImport when what
                    -- came in changes it - a raid profile or a route.
                    RC:ShowUniversalImport({ from = "raidProfile" })
                elseif value == "__builtin__" then
                    if builtInProfile then
                        RC.UI:CreateConfirmDialog(RCL["Import Built-in Profile"],
                            RCL["Import '"] .. builtInProfile.name .. "'?\n\n" .. (builtInProfile.description or ""),
                            function()
                                if builtInProfile and builtInProfile.data then
                                    local success, importedRaid, importedProfileName = RC:ImportRaidProfile(builtInProfile.data)
                                    if success and importedRaid and importedProfileName then
                                        RC:SetActiveRaidProfile(importedRaid, importedProfileName)
                                        ReloadBar()
                                    else
                                        RC:Print(RCL["Failed to import built-in profile"])
                                    end
                                end
                            end,
                            nil,
                            RCL["Import"],
                            false)
                    end
                elseif value == "__merge__" then
                    OpenMergePicker()
                end
            end)
            manageDropdown:SetSelectedValue("__manage__", "Manage")
        end

        return yPos - 36
    end

    -- Master page dispatcher: every sidebar button and deep-link routes here.
    -- Always clears without preserveScroll (navigating to a different page resets scroll),
    -- then dispatches by raidKey / panel / first child of a bare category.
    function RC:ShowSidebarPanel(frame, menuItem)
        local compatFrame = frame.compatFrame

        self:RefreshSidebarProfiles()

        self:ClearSidebarContent(frame)

        compatFrame.isSidebarMode = true
        -- the page being built (customization sections remember their
        -- open state per page; currentMenuItem is only set after the build)
        self.SidebarState.buildingItem = menuItem

        -- a feature this game version does not run: one plain note, and
        -- its addon is not loaded for it (Core_Flavor)
        local offFeature = self.FeatureOffForPage and self:FeatureOffForPage(menuItem)
        if offFeature then
            self:ShowSidebarFeatureOff(compatFrame, menuItem, offFeature)
        elseif menuItem.raidKey then
            compatFrame.configState.selectedRaid = menuItem.raidKey
            compatFrame.configState.selectedEncounterType = nil
            compatFrame.configState.selectedAbility = nil
            compatFrame.configState.selectedTrashSection = nil
            self:OpenRaidBossPage(compatFrame, menuItem.raidKey)
        -- Panel contract: self[panel] is called with compatFrame, never the raw window frame.
        elseif menuItem.panel then
            if not self[menuItem.panel] and menuItem.lodAddon then
                local L = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
                if L then pcall(L, menuItem.lodAddon) end
            end
            if self[menuItem.panel] then
                self[menuItem.panel](self, compatFrame)
            else
                self:ShowSidebarPlaceholder(frame, menuItem.name)
            end
        elseif menuItem.category and menuItem.children and menuItem.children[1] then
            local firstChild = menuItem.children[1]
            if firstChild.panel and self[firstChild.panel] then
                self[firstChild.panel](self, compatFrame)
            end
        end

        self.SidebarState.currentPanel = menuItem.id
        self.SidebarState.currentMenuItem = menuItem

        if self.db then
            self.db.lastSidebarSelection = menuItem.id
        end

        -- Keep the search index in step with what this page shows now.
        if self.SidebarSearch then
            self.SidebarSearch.searchMode = false
            pcall(self.SidebarSearch.RefreshFromPage, menuItem.id)
        end
    end

    -- After a resize the page is built again at the new width: the cards
    -- stretch on their own, but what sits inside them was laid out for the
    -- old one (columns, wrapping, rows that flow). The scroll is kept.
    function RC:RelayoutSidebarPage(frame)
        if not (frame and frame:IsShown() and frame.compatFrame) then return end
        if self.SidebarSearch and self.SidebarSearch.searchMode then return end
        local item = self.SidebarState and self.SidebarState.currentMenuItem
        if not item then return end
        local scroll = frame.contentFrame and frame.contentFrame:GetVerticalScroll() or 0
        self:ShowSidebarPanel(frame, item)
        C_Timer.After(0, function()
            local sb = frame.contentFrame and frame.contentFrame.scrollBar
            if not sb then return end
            local _, maxV = sb:GetMinMaxValues()
            local v = math.min(scroll, maxV or 0)
            sb:SetValue(v)
            frame.contentFrame:SetVerticalScroll(v)
        end)
    end

    function RC:UpdateSidebarScrollbar(frame, explicitHeight, forceResetScroll)
        if not frame or not frame.contentFrame or not frame.contentFrame.scrollBar then return end

        local scrollChild = frame.compatFrame and frame.compatFrame.scrollChild
        local scrollBar = frame.contentFrame.scrollBar
        local scrollFrame = frame.contentFrame

        if not scrollChild then return end

        -- a page with a preview: its title pinned and the strip placed
        -- before the page is measured (it moves the top of the scroll area)
        if RC.Preview and RC.Preview.Settle then
            RC.Preview.Settle(frame)
            if explicitHeight and explicitHeight > 0 then
                explicitHeight = math.max(1, explicitHeight - (RC.Preview.PinShift() or 0))
            end
        end

        if frame.scrollbarUpdateTimer then
            frame.scrollbarUpdateTimer:Cancel()
            frame.scrollbarUpdateTimer = nil
        end
        if frame.scrollbarUpdateTimer2 then
            frame.scrollbarUpdateTimer2:Cancel()
            frame.scrollbarUpdateTimer2 = nil
        end

        frame.suppressScrollbarUpdate = nil

        local currentAlpha = scrollBar:GetAlpha()

        local function ApplyScrollbar(height, resetScroll)
            if not scrollChild or not scrollBar or not scrollFrame then return end

            -- +50: bottom padding so the last widget isn't flush against the scroll edge.
            local actualHeight = height + 50
            scrollChild:SetHeight(actualHeight)

            local frameHeight = scrollFrame:GetHeight() or 600
            local maxScroll = math.max(0, actualHeight - frameHeight)
            if scrollBar.SizeThumb then scrollBar:SizeThumb(actualHeight, frameHeight) end

            local currentMin, currentMax = scrollBar:GetMinMaxValues()
            if currentMax ~= maxScroll then
                scrollBar:SetMinMaxValues(0, maxScroll)
            end

            if resetScroll then
                scrollBar:SetValue(0)
                scrollFrame:SetVerticalScroll(0)
            else
                local currentVal = scrollBar:GetValue()
                if currentVal > maxScroll then
                    scrollBar:SetValue(maxScroll)
                end
            end

            -- Hide the scrollbar entirely when there is effectively nothing to scroll.
            local targetAlpha = (maxScroll <= 1) and 0 or 1
            if scrollBar:GetAlpha() ~= targetAlpha then
                scrollBar:SetAlpha(targetAlpha)
            end
        end

        if explicitHeight and explicitHeight > 0 then
            ApplyScrollbar(explicitHeight, forceResetScroll == true)
            return
        end

        local function MeasureAndApply()
            if not scrollChild or not scrollBar or not scrollFrame then return end
            if not frame:IsShown() then return end

            local scrollChildTop = scrollChild:GetTop()
            if not scrollChildTop then
                if scrollBar:GetAlpha() > 0 then
                    scrollBar:SetAlpha(0)
                end
                return
            end

            local lowestPoint = scrollChildTop

            -- Depth cap of 5: bounds the recursive scan of nested content frames.
            local function CheckChildren(parent, depth)
                if depth > 5 then return end
                local children = {parent:GetChildren()}
                for _, child in ipairs(children) do
                    if child:IsShown() then
                        local bottom = child:GetBottom()
                        if bottom and bottom < lowestPoint then
                            lowestPoint = bottom
                        end
                        CheckChildren(child, depth + 1)
                    end
                end
            end

            CheckChildren(scrollChild, 0)

            local actualHeight = scrollChildTop - lowestPoint
            if actualHeight < 100 then actualHeight = 100 end

            ApplyScrollbar(actualHeight, forceResetScroll == true)
        end

        -- 0.1s delay lets SetPoint layout settle before GetTop/GetBottom are measured.
        -- RestoreScrollPosition applies any scroll saved by ClearSidebarContent(frame, true).
        frame.scrollbarUpdateTimer = C_Timer.NewTimer(0.1, function()
            MeasureAndApply()
            RC:RestoreScrollPosition(frame)
        end)
    end

    function RC:ShowSidebarWelcome(frame)
        if self.ShowSidebarGeneralBehavior then
            self:ShowSidebarGeneralBehavior(frame)
        end
    end

    function RC:ShowSidebarPlaceholder(frame, name)
        local parent = frame.compatFrame and frame.compatFrame.scrollChild or frame.scrollChild
        local yPos = -30

        local header = self:CreateFontString(parent, "OVERLAY", nil, 16)
        header:SetPoint("TOPLEFT", parent, "TOPLEFT", 30, yPos)
        header:SetText(name)
        header:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
        yPos = yPos - 35

        local desc = self:CreateFontString(parent, "OVERLAY", nil, 12)
        desc:SetPoint("TOPLEFT", parent, "TOPLEFT", 30, yPos)
        desc:SetText(RCL["This panel is coming soon."])
        desc:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
    end

    -- The page of a feature this game version does not run (Core_Flavor):
    -- its name and one plain line saying why, e.g. "Not on TBC: Classic
    -- Era content".
    function RC:ShowSidebarFeatureOff(frame, menuItem, featureId)
        local parent = frame.scrollChild
        local _, y = self:CreateSettingsPageHeader(parent, -15, menuItem.name or "",
            self:FeatureOffNote(featureId), menuItem.icon)
        self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(y))
    end

    -- Shared Edit Mode entry point for the title-bar button and the
    -- minimap menu. There is only one edit-mode system - UIMover, the same
    -- overlay /rc moveui opens - so this only gets the config window out of
    -- its way and puts it back when the mover exits (UIMover:ExitMoveMode
    -- has no notion of the window, hence the one-time hook).
    function RC:EnterEditMode()
        local UM = self.UIMover
        if not (UM and UM.EnterMoveMode) then
            self:DebugPrint("Edit Mode: UIMover is not loaded.", "uimover")
            return
        end

        if not UM._rcEditModeHooked then
            UM._rcEditModeHooked = true
            hooksecurefunc(UM, "ExitMoveMode", function()
                local f = RC.sidebarConfigFrame
                if not f then return end
                if f._rcReopenAfterEdit then
                    f._rcReopenAfterEdit = nil
                    -- An exit inside the pop-out's 0.12s would otherwise
                    -- let the still-running ticker hide the window again.
                    if f.popAnimation then
                        f.popAnimation:Cancel()
                        f.popAnimation = nil
                        f:SetAlpha(1)
                        f:SetScale(1)
                    end
                    f:Show()
                end
                if f.editModeToolButton then f.editModeToolButton:SetActive(false) end
            end)
        end

        local frame = self.sidebarConfigFrame
        if frame and frame:IsShown() then
            frame._rcReopenAfterEdit = true
            if frame.editModeToolButton then frame.editModeToolButton:SetActive(true) end
            -- PopOut restores alpha/scale to 1 before it hides, so the
            -- plain Show() on the way back out is safe.
            if self.UI and self.UI.PopOut then
                self.UI:PopOut(frame, 0.12)
            else
                frame:Hide()
            end
        end

        UM:EnterMoveMode()
    end

    function RC:CreateSidebarConfigWindow()
        if self.LoadConfigurationFromProfile then
            self:LoadConfigurationFromProfile()
        end

        if self.sidebarConfigFrame then
            if self.sidebarConfigFrame:IsShown() then
                if self.pendingNavigation then
                    self:HandlePendingNavigation(self.sidebarConfigFrame)
                    return
                end

                if self.UI and self.UI.PopOut then
                    self.UI:PopOut(self.sidebarConfigFrame, 0.12)
                else
                    self.sidebarConfigFrame:Hide()
                end
            else
                self.sidebarConfigFrame.suppressScrollbarUpdate = true

                if self.UI and self.UI.PopIn then
                    self.sidebarConfigFrame:SetAlpha(0)
                    self.sidebarConfigFrame:SetScale(0.95)
                    self.sidebarConfigFrame:Show()
                    self.UI:PopIn(self.sidebarConfigFrame, 0.18)

                    C_Timer.After(0.2, function()
                        if self.sidebarConfigFrame and self.sidebarConfigFrame:IsShown() then
                            self.sidebarConfigFrame.suppressScrollbarUpdate = nil
                            self:UpdateSidebarMenuScrollbar(self.sidebarConfigFrame)
                            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
                        end
                    end)
                else
                    self.sidebarConfigFrame.suppressScrollbarUpdate = nil
                    self.sidebarConfigFrame:Show()
                    self:UpdateSidebarMenuScrollbar(self.sidebarConfigFrame)
                end

                if self.pendingNavigation then
                    C_Timer.After(0.05, function()
                        self:HandlePendingNavigation(self.sidebarConfigFrame)
                    end)
                end
                if self.MaybeStartTutorial then self:MaybeStartTutorial() end
            end
            return
        end

        local version = self.version or "3.0.0"

        local WINDOW_WIDTH = 1050
        local WINDOW_HEIGHT = 700
        local CONTENT_WIDTH = WINDOW_WIDTH - SIDEBAR.WIDTH - 5

        local frame = CreateFrame("Frame", "ReadycheckSidebarConfig", UIParent)
        frame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
        frame:SetPoint("CENTER")
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:SetClampedToScreen(true)
        frame:SetFrameStrata("DIALOG")
        frame:SetToplevel(true)

        frame:SetScript("OnMouseDown", function(self)
            self:Raise()
        end)

        RC.UI:RegisterEscapeClose("ReadycheckSidebarConfig")

        local windowBgColor = self:GetColor("ui", "windowBackground")

        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(windowBgColor.r, windowBgColor.g, windowBgColor.b, windowBgColor.a or 1)
        frame.bg = bg

        frame.border = self.UI:CreateSimpleBorder(frame)

        -- Window shell: flat windowBackground fill + 1px ring (above) and
        -- the hero header (RC.UI:CreateHeroHeader): round badge, two-tone
        -- name, version and character under it, the stepped gold rule and
        -- the boxed X. Drag by the bar.
        local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
        local TITLEBAR_H = RC.UI.HERO_H or 38
        local titleBar = self.UI:CreateHeroHeader(frame, {
            first = RCL["Ready"], second = RCL["check"],
            subtitle = "v" .. tostring(version),
            stepX = SIDEBAR.WIDTH,
            leftColor = function() return RC:GetColor("sidebar", "background") end,
            onClose = function() frame:Hide() end,
        })
        titleBar:EnableMouse(true)
        titleBar:RegisterForDrag("LeftButton")
        frame.titleBar = titleBar
        frame.heroHeader = titleBar

        local dragOffsetX, dragOffsetY = 0, 0

        titleBar:SetScript("OnDragStart", function(self)
            local cursorX, cursorY = GetCursorPosition()
            local scale = frame:GetEffectiveScale()
            cursorX, cursorY = cursorX / scale, cursorY / scale

            local frameX, frameY = frame:GetCenter()
            dragOffsetX = cursorX - frameX
            dragOffsetY = cursorY - frameY

            frame:StartMoving()
        end)

        titleBar:SetScript("OnDragStop", function(self)
            frame:StopMovingOrSizing()
        end)

        local sidebarBgColor = self:GetColor("sidebar", "background")
        local scrollTrackColor = self:GetColor("scrollbar", "track")
        local scrollThumbColor = self:GetColor("scrollbar", "thumb")

        -- A glow over the badge icon, played by frame.PlayIconAnimation().
        -- It used to fire on every open; the opening is now the header's
        -- own mark animation (RC.UI:AnimateMark), and firing both put a
        -- ghost of the icon on screen before the mark had landed. The
        -- function stays for anything that wants to blink the icon.
        local titleIcon = titleBar.icon
        local iconGlow = titleBar:CreateTexture(nil, "OVERLAY")
        iconGlow:SetSize(20, 20)
        iconGlow:SetPoint("CENTER", titleIcon, "CENTER", 0, 0)
        iconGlow:SetTexture("Interface\\AddOns\\Readycheck\\Media\\Checkmark")
        if RC.UI and RC.UI.PaintMark then RC.UI:PaintMark(iconGlow) end
        iconGlow:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        iconGlow:SetBlendMode("ADD")
        iconGlow:SetAlpha(0)

        frame.titleIcon = titleIcon
        frame.iconGlow = iconGlow
        frame.glowAnimating = false

        frame.PlayIconAnimation = function()
            if frame.glowAnimating then return end
            if not frame.iconGlow then return end
            frame.glowAnimating = true

            local glow = frame.iconGlow
            local elapsed = 0
            local duration = 0.5

            frame:SetScript("OnUpdate", function(self, delta)
                elapsed = elapsed + delta
                local progress = elapsed / duration

                if progress >= 1 then
                    glow:SetAlpha(0)
                    frame:SetScript("OnUpdate", nil)
                    frame.glowAnimating = false
                else
                    local alpha
                    if progress < 0.4 then
                        alpha = (progress / 0.4) * 0.6
                    else
                        alpha = 0.6 * (1 - ((progress - 0.4) / 0.6))
                    end
                    glow:SetAlpha(alpha)
                end
            end)
        end

        -- titleText is the subtitle line (version - character); the name
        -- itself is two font strings the header repaints on its own.
        local titleText = titleBar.subtitle
        frame.titleText = nil

        local closeButton = titleBar.closeButton
        frame.closeButton = closeButton

        -- TITLE BAR TOOLS, right-to-left, left of the X: Edit Mode (the
        -- existing UIMover overlay, same thing /rc moveui opens) and a
        -- reload. Anchored off the X, which is anchored to the bar's right
        -- edge, so both follow a drag-resize. The title's RIGHT is pinned
        -- to the leftmost of them so a long character key truncates
        -- instead of running under the buttons.
        local function AttachTitleTooltip(button, header, ...)
            local lines = { ... }
            button:HookScript("OnEnter", function(btn)
                GameTooltip:SetOwner(btn, "ANCHOR_BOTTOM")
                GameTooltip:SetText(header, 1, 1, 1)
                for _, line in ipairs(lines) do
                    GameTooltip:AddLine(line, 0.7, 0.7, 0.7, true)
                end
                GameTooltip:Show()
            end)
            button:HookScript("OnLeave", function() GameTooltip:Hide() end)
        end

        AttachTitleTooltip(closeButton, RCL["Close"])

        local editModeButton = self.UI:CreateStyledButton(titleBar, RCL["Edit Mode"], 78, 20)
        editModeButton:SetPoint("RIGHT", closeButton, "LEFT", -8, 0)
        editModeButton:SetFrameLevel(titleBar:GetFrameLevel() + 1)
        editModeButton:SetScript("OnClick", function()
            if RC.EnterEditMode then RC:EnterEditMode() end
        end)
        AttachTitleTooltip(editModeButton,
            RCL["Edit Mode"],
            RCL["Show every movable Readycheck frame at once over a grid and drag them into place."],
            RCL["Escape or Save & Lock to finish."])
        frame.editModeToolButton = editModeButton

        local reloadButton = self.UI:CreateStyledButton(titleBar, RCL["Reload"], 58, 20)
        reloadButton:SetPoint("RIGHT", editModeButton, "LEFT", -8, 0)
        reloadButton:SetFrameLevel(titleBar:GetFrameLevel() + 1)
        reloadButton:SetScript("OnClick", function() ReloadUI() end)
        AttachTitleTooltip(reloadButton,
            RCL["Reload"],
            RCL["Reloads the interface. Needed for font, skin and minimap-button changes to fully apply."])
        frame.reloadButton = reloadButton

        titleText:SetPoint("RIGHT", reloadButton, "LEFT", -10, 0)

        -- Opening the window while the mover is already up (/rc moveui,
        -- then /rc) should still show the button in its active state.
        frame:HookScript("OnShow", function()
            local UM = RC.UIMover
            editModeButton:SetActive(UM and UM.isMoving and true or false)
        end)

        -- NAV COLUMN: sidebar.background fill with a 1px black rule down its
        -- right edge separating it from the content pane.
        local sidebar = CreateFrame("Frame", nil, frame)
        sidebar:SetWidth(SIDEBAR.WIDTH)
        sidebar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -(TITLEBAR_H + 1))
        sidebar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
        -- 31 = titlebar height + border inset, 30 = search box row.
        sidebar.knownScrollHeight = WINDOW_HEIGHT - (TITLEBAR_H + 1) - 30

        local sidebarBg = sidebar:CreateTexture(nil, "BACKGROUND")
        sidebarBg:SetAllPoints()
        sidebarBg:SetTexture(FLAT)
        sidebarBg:SetVertexColor(sidebarBgColor.r, sidebarBgColor.g, sidebarBgColor.b, sidebarBgColor.a or 1)
        sidebar.bg = sidebarBg

        local sidebarRule = sidebar:CreateTexture(nil, "OVERLAY")
        sidebarRule:SetTexture(FLAT)
        sidebarRule:SetWidth(1)
        sidebarRule:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", 0, 0)
        sidebarRule:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", 0, 0)
        local ruleColor = self:GetColor("ui", "borderNormal")
        sidebarRule:SetVertexColor(ruleColor.r, ruleColor.g, ruleColor.b, ruleColor.a or 1)
        sidebar.rule = sidebarRule

        -- Search: flat uiMover.inputBackground box, 1px ring, gold on focus.
        local searchContainer = CreateFrame("Frame", nil, sidebar, "BackdropTemplate")
        searchContainer:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 4, -4)
        searchContainer:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -22, -4)
        searchContainer:SetHeight(22)
        local _searchElBG   = self:GetColor("uiMover", "inputBackground")
        local _searchBNorm  = self:GetColor("ui", "borderNormal")
        local _searchAccent = self:GetColor("ui", "accentGold")
        searchContainer:SetBackdrop({
            bgFile   = FLAT,
            edgeFile = FLAT,
            edgeSize = 1,
        })
        searchContainer:SetBackdropColor(_searchElBG.r, _searchElBG.g, _searchElBG.b, 1)
        searchContainer:SetBackdropBorderColor(_searchBNorm.r, _searchBNorm.g, _searchBNorm.b, _searchBNorm.a or 1)
        sidebar.searchContainer = searchContainer
        local searchBox = CreateFrame("EditBox", nil, searchContainer)
        searchBox:SetAllPoints(searchContainer)
        searchBox:SetAutoFocus(false)
        searchBox:SetMaxLetters(64)
        searchBox:SetTextInsets(6, 6, 2, 2)
        self:ApplyCustomFont(searchBox, 11)
        local placeholder = searchBox:CreateFontString(nil, "OVERLAY")
        self:ApplyCustomFont(placeholder, 11)
        local phColor = self:GetColor("text", "gray")
        placeholder:SetTextColor(phColor.r, phColor.g, phColor.b, 0.8)
        placeholder:SetPoint("LEFT", searchBox, "LEFT", 8, 0)
        placeholder:SetText(RCL["Search..."])
        sidebar.searchPlaceholder = placeholder
        searchBox:SetScript("OnTextChanged", function(self)
            local txt = self:GetText()
            placeholder:SetShown(txt == "")
            frame.sidebarSearchText = (txt ~= "") and txt:lower() or nil
            if sidebar.searchClearBtn then
                sidebar.searchClearBtn:SetShown(txt ~= "")
            end
            RC:BuildSidebar(frame, false)
            -- The settings search: results in the content pane, ranked,
            -- each one a jump to the setting itself.
            if RC.SidebarSearch then RC.SidebarSearch.OnTextChanged(frame, txt) end
        end)
        searchBox:SetScript("OnEscapePressed", function(self)
            self:SetText("")
            self:ClearFocus()
        end)
        searchBox:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
            if RC.SidebarSearch then RC.SidebarSearch.OnEnter(frame, self:GetText()) end
        end)
        searchBox:SetScript("OnEditFocusGained", function()
            searchContainer:SetBackdropBorderColor(_searchAccent.r, _searchAccent.g, _searchAccent.b, 1)
            -- Reading the pages starts as soon as the box is clicked, so
            -- most of the index is there by the time a word is typed.
            if RC.SidebarSearch then RC.SidebarSearch.OnFocus() end
        end)
        searchBox:SetScript("OnEditFocusLost", function()
            searchContainer:SetBackdropBorderColor(_searchBNorm.r, _searchBNorm.g, _searchBNorm.b, _searchBNorm.a or 1)
        end)
        sidebar.searchBox = searchBox

        -- Clear: the framework's chromeless X (buttons.xNormal -> xHover).
        local clearBtn = self.UI:CreateXCloseButton(searchContainer, 14, function()
            searchBox:SetText("")
            searchBox:ClearFocus()
        end)
        clearBtn:SetPoint("RIGHT", searchContainer, "RIGHT", -3, 0)
        clearBtn:SetFrameLevel(searchBox:GetFrameLevel() + 2)
        clearBtn:Hide()
        sidebar.searchClearBtn = clearBtn

        searchBox:SetTextInsets(6, 20, 2, 2)

        local sidebarScroll = CreateFrame("ScrollFrame", "WRSidebarMenuScroll", sidebar)
        sidebarScroll:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 0, -30)
        sidebarScroll:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -18, 0)

        local sidebarChild = CreateFrame("Frame", nil, sidebarScroll)
        sidebarChild:SetWidth(SIDEBAR.WIDTH - 4)
        sidebarChild:SetHeight(800)
        sidebarScroll:SetScrollChild(sidebarChild)

        -- Scrollbar: 16 wide flat scrollbar.track rail with a 1px ring and a
        -- flat block thumb (scrollbar.thumb) ringed by AddThumbBorder.
        local sidebarScrollBar = CreateFrame("Slider", nil, sidebar)
        sidebarScrollBar:SetWidth(16)
        sidebarScrollBar:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -2, -30)
        sidebarScrollBar:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -2, 2)
        sidebarScrollBar:SetOrientation("VERTICAL")
        sidebarScrollBar:SetMinMaxValues(0, 0)
        sidebarScrollBar:SetValue(0)
        sidebarScrollBar:SetValueStep(1)

        local sidebarScrollBg = sidebarScrollBar:CreateTexture(nil, "BACKGROUND")
        sidebarScrollBg:SetAllPoints()
        sidebarScrollBg:SetTexture(FLAT)
        sidebarScrollBg:SetVertexColor(scrollTrackColor.r, scrollTrackColor.g, scrollTrackColor.b, scrollTrackColor.a or 0.8)
        sidebarScrollBar.bg = sidebarScrollBg

        sidebarScrollBar.border = self.UI:CreateSimpleBorder(sidebarScrollBar)

        local sidebarThumb = sidebarScrollBar:CreateTexture(nil, "OVERLAY")
        sidebarThumb:SetTexture(FLAT)
        sidebarThumb:SetVertexColor(scrollThumbColor.r, scrollThumbColor.g, scrollThumbColor.b, 1)
        sidebarThumb:SetSize(16, 60)
        sidebarScrollBar:SetThumbTexture(sidebarThumb)
        if RC.UI and RC.UI.AddThumbBorder then RC.UI:AddThumbBorder(sidebarScrollBar) end
        sidebarScrollBar.thumb = sidebarThumb

        sidebarScrollBar:SetScript("OnValueChanged", function(self, value)
            sidebarScroll:SetVerticalScroll(value)
        end)
        self.UI:StyleScrollBar(sidebarScrollBar)

        sidebar:EnableMouseWheel(true)
        sidebar:SetScript("OnMouseWheel", function(self, delta)
            local current = sidebarScrollBar:GetValue()
            local minVal, maxVal = sidebarScrollBar:GetMinMaxValues()
            if maxVal <= 0 then return end
            local newValue = math.max(minVal, math.min(maxVal, current - (delta * 30)))
            sidebarScrollBar:SetValue(newValue)
        end)

        sidebarScroll.scrollBar = sidebarScrollBar
        sidebar.scrollFrame = sidebarScroll
        sidebar.scrollChild = sidebarChild
        sidebar.buttons = {}

        sidebarScrollBar:SetAlpha(0)

        frame.sidebar = sidebar

        frame:HookScript("OnShow", function()
            if RC and RC.UpdateSidebarMenuScrollbar and RC.sidebarConfigFrame then
                RC:UpdateSidebarMenuScrollbar(RC.sidebarConfigFrame)
            end
        end)

        frame:HookScript("OnSizeChanged", function()
            local newH = frame:GetHeight()
            if newH and newH > 100 then
                frame.sidebar.knownScrollHeight = newH - (TITLEBAR_H + 1) - 30
            end
            -- Debounced: OnSizeChanged fires repeatedly during a drag-resize.
            if frame._menuResizeTimer then frame._menuResizeTimer:Cancel() end
            frame._menuResizeTimer = C_Timer.After(0.1, function()
                frame._menuResizeTimer = nil
                if RC and RC.UpdateSidebarMenuScrollbar and RC.sidebarConfigFrame then
                    RC:UpdateSidebarMenuScrollbar(RC.sidebarConfigFrame)
                end
            end)
        end)

        -- CONTENT PANE: the window fill shows through (cards float on it),
        -- so the pane only carries a transparent-by-default flat texture the
        -- opacity setting and RefreshUIColors can still reach.
        local contentBgColor = self:GetColor("ui", "windowBackground")

        -- pageW: the width you sized the window to (menu + page).
        local pageW = WINDOW_WIDTH

        local contentArea = CreateFrame("Frame", nil, frame)
        contentArea:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 1, 0)
        contentArea:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)

        local contentBg = contentArea:CreateTexture(nil, "BACKGROUND")
        contentBg:SetAllPoints()
        contentBg:SetTexture(FLAT)
        contentBg:SetVertexColor(contentBgColor.r, contentBgColor.g, contentBgColor.b, contentBgColor.a or 1)
        contentArea.bg = contentBg
        frame.contentBg = contentBg

        local contentScroll = CreateFrame("ScrollFrame", "WRSidebarContentScroll", contentArea)
        contentScroll:SetPoint("TOPLEFT", contentArea, "TOPLEFT", 0, 0)
        contentScroll:SetPoint("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", -22, 0)

        local contentChild = CreateFrame("Frame", nil, contentScroll)
        contentChild:SetWidth(CONTENT_WIDTH - 18)
        contentChild:SetHeight(1500)
        contentScroll:SetScrollChild(contentChild)

        local scrollBar = CreateFrame("Slider", nil, contentArea)
        scrollBar:SetWidth(16)
        scrollBar:SetPoint("TOPRIGHT", contentArea, "TOPRIGHT", -2, -4)
        scrollBar:SetPoint("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", -2, 20)
        scrollBar:SetOrientation("VERTICAL")
        scrollBar:SetMinMaxValues(0, 1)
        scrollBar:SetValue(0)
        scrollBar:SetValueStep(1)

        local scrollBg = scrollBar:CreateTexture(nil, "BACKGROUND")
        scrollBg:SetAllPoints()
        scrollBg:SetTexture(FLAT)
        scrollBg:SetVertexColor(scrollTrackColor.r, scrollTrackColor.g, scrollTrackColor.b, scrollTrackColor.a or 0.8)
        scrollBar.bg = scrollBg

        scrollBar.border = self.UI:CreateSimpleBorder(scrollBar)

        local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
        thumb:SetTexture(FLAT)
        thumb:SetVertexColor(scrollThumbColor.r, scrollThumbColor.g, scrollThumbColor.b, 1)
        thumb:SetSize(16, 60)
        scrollBar:SetThumbTexture(thumb)
        if RC.UI and RC.UI.AddThumbBorder then RC.UI:AddThumbBorder(scrollBar) end
        scrollBar.thumb = thumb

        scrollBar:SetScript("OnValueChanged", function(self, value)
            contentScroll:SetVerticalScroll(value)
        end)
        self.UI:StyleScrollBar(scrollBar)

        contentScroll.scrollBar = scrollBar

        scrollBar:SetAlpha(0)

        contentArea:EnableMouseWheel(true)
        contentArea:SetScript("OnMouseWheel", function(self, delta)
            local current = scrollBar:GetValue()
            local minVal, maxVal = scrollBar:GetMinMaxValues()
            local newValue = math.max(minVal, math.min(maxVal, current - (delta * 40)))
            scrollBar:SetValue(newValue)
        end)

        -- THE PINNED TOP: on a page with a preview, the page's title and
        -- the preview strip under it (UIF_Preview), above the scroll area.
        local pinnedTop = CreateFrame("Frame", nil, contentArea)
        pinnedTop:SetPoint("TOPLEFT", contentArea, "TOPLEFT", 0, 0)
        pinnedTop:SetSize(CONTENT_WIDTH - 18, 1)
        pinnedTop:Hide()
        frame.pinnedTop = pinnedTop

        frame.contentArea = contentArea
        frame.contentFrame = contentScroll
        frame.contentScrollChild = contentChild

        local MIN_WIDTH = 850
        local MAX_WIDTH = 1400
        local MIN_HEIGHT = 500
        local MAX_HEIGHT = 900

        frame:SetResizable(true)
        frame:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, MAX_WIDTH, MAX_HEIGHT)

        local resizeGrip = CreateFrame("Button", nil, frame)
        frame.resizeGrip = resizeGrip
        resizeGrip:SetSize(16, 16)
        resizeGrip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        resizeGrip:SetFrameLevel(frame:GetFrameLevel() + 120)

        resizeGrip.dots = {}
        local dotPositions = {
            {2, 2}, {6, 2}, {10, 2},
            {6, 6}, {10, 6},
            {10, 10}
        }
        for i, pos in ipairs(dotPositions) do
            local dot = resizeGrip:CreateTexture(nil, "ARTWORK")
            dot:SetSize(2, 2)
            dot:SetPoint("BOTTOMLEFT", resizeGrip, "BOTTOMLEFT", pos[1], pos[2])
            local dotCol = RC:GetColor("text", "gray")
            dot:SetColorTexture(dotCol.r * 0.7, dotCol.g * 0.7, dotCol.b * 0.7, 0.85)
            resizeGrip.dots[i] = dot
        end

        resizeGrip:SetScript("OnEnter", function()
            local gold = RC:GetColor("ui", "accentGold")
            for _, dot in ipairs(resizeGrip.dots) do
                dot:SetColorTexture(gold.r, gold.g, gold.b, 1)
            end
        end)

        resizeGrip:SetScript("OnLeave", function()
            local dotCol = RC:GetColor("text", "gray")
            for _, dot in ipairs(resizeGrip.dots) do
                dot:SetColorTexture(dotCol.r * 0.7, dotCol.g * 0.7, dotCol.b * 0.7, 0.85)
            end
        end)

        resizeGrip:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" then
                frame:StartSizing("BOTTOMRIGHT")
            end
        end)

        resizeGrip:SetScript("OnMouseUp", function(self, button)
            frame:StopMovingOrSizing()
            local oldW = pageW
            pageW = math.max(MIN_WIDTH, frame:GetWidth() or pageW)
            if RC.db then
                RC.db.configWindowWidth = pageW
                RC.db.configWindowHeight = frame:GetHeight()
                if RC.SaveConfigurationToProfile then
                    RC:SaveConfigurationToProfile()
                end
            end
            -- a new width lays the page out again (after the content's own
            -- width has followed: OnSizeChanged sets it)
            if math.abs(pageW - (oldW or pageW)) > 0.5 and RC.RelayoutSidebarPage then
                RC:RelayoutSidebarPage(frame)
            end
        end)

        frame:SetScript("OnSizeChanged", function(self, width, height)
            -- -23 accounts for the content scrollbar gutter + border inset (vs -5 used for the initial CONTENT_WIDTH).
            local newContentWidth = width - SIDEBAR.WIDTH - 23
            local cw = contentChild:GetWidth()
            if not cw or math.abs(cw - newContentWidth) > 3 then
                contentChild:SetWidth(newContentWidth)
            end
            pinnedTop:SetWidth(contentChild:GetWidth())

            if self._resizeTimer then
                self._resizeTimer:Cancel()
            end
            self._resizeTimer = C_Timer.After(0.05, function()
                self._resizeTimer = nil
                if RC.UpdateSidebarScrollbar then
                    RC:UpdateSidebarScrollbar(self)
                end
                if RC.UpdateSidebarMenuScrollbar then
                    RC:UpdateSidebarMenuScrollbar(self)
                end
            end)
        end)

        if self.db and self.db.configWindowWidth and self.db.configWindowHeight then
            local savedWidth = math.max(MIN_WIDTH, math.min(MAX_WIDTH, self.db.configWindowWidth))
            local savedHeight = math.max(MIN_HEIGHT, math.min(MAX_HEIGHT, self.db.configWindowHeight))
            frame:SetSize(savedWidth, savedHeight)
            pageW = savedWidth
        end

        -- THE PREVIEW STRIP'S ROOM (UIF_Preview calls this through
        -- Preview.Attach): a strip h high, stripY down the pinned top (0:
        -- none; the page's title alone when it is pinned), and the scroll
        -- area moved to start below it. The window never changes size.
        local function PlaceStrip(stripY, h, pinned)
            local cw = contentChild:GetWidth() or (CONTENT_WIDTH - 18)
            local sw = cw - 36
            pinnedTop:SetWidth(cw)
            local top = 0
            local strip = RC.Preview and RC.Preview.Frame()
            if h and h > 0 and strip then
                strip:ClearAllPoints()
                strip:SetPoint("TOPLEFT", pinnedTop, "TOPLEFT", 18, -stripY)
                strip:SetWidth(sw)
                top = stripY + h + 8
            elseif pinned then
                top = stripY
            end
            pinnedTop:SetHeight(math.max(1, top))
            if top > 0 then pinnedTop:Show() else pinnedTop:Hide() end
            local _, _, _, _, oldTop = contentScroll:GetPoint(1)
            contentScroll:SetPoint("TOPLEFT", contentArea, "TOPLEFT", 0, -top)
            scrollBar:SetPoint("TOPRIGHT", contentArea, "TOPRIGHT", -2, -4 - top)
            -- the scroll area's height changed: measure the page again
            if oldTop ~= -top and RC.UpdateSidebarScrollbar then RC:UpdateSidebarScrollbar(frame) end
            return sw
        end
        frame.PageWidth = function() return frame:GetWidth() or pageW end

        frame.resizeGrip = resizeGrip

        -- compatFrame mimics a real Frame's API (Show/Hide/GetScript/etc.) so page code written
        -- against a plain frame works unchanged when handed this shim instead. Must be built after
        -- contentChild/contentScroll/contentArea exist, since its methods close over them.
        local compatFrame = {
            scrollChild = contentChild,
            contentFrame = contentScroll,
            isSidebarMode = true,
            configState = {
                selectedRaid = nil,
                selectedEncounter = nil,
                selectedEncounterType = nil,
                selectedAbility = nil,
                selectedTrashSection = nil
            },
            bulkTrashState = {
                selectedMobs = {},
                currentAbility = nil
            },
            trinketState = nil,
            executeViewerState = nil,
            profileViewState = nil,
            trinketConfigState = nil,
            currentBackButton = nil,
            elements = {},
            layoutRows = {},
            currentRow = 0,
            rowHeight = 0,
            desiredScrollPosition = 0
        }

        function compatFrame:IsShown() return frame:IsShown() end
        function compatFrame:IsVisible() return frame:IsVisible() end
        function compatFrame:Show() frame:Show() end
        function compatFrame:Hide() frame:Hide() end
        function compatFrame:GetParent() return frame end
        function compatFrame:GetWidth() return contentArea:GetWidth() end
        function compatFrame:GetHeight() return contentArea:GetHeight() end
        function compatFrame:EnableMouseWheel(enable) contentArea:EnableMouseWheel(enable) end
        function compatFrame:EnableMouse(enable) contentArea:EnableMouse(enable) end
        function compatFrame:SetScript(event, handler)
            if not compatFrame._scripts then compatFrame._scripts = {} end
            compatFrame._scripts[event] = handler
        end
        function compatFrame:GetScript(event)
            return compatFrame._scripts and compatFrame._scripts[event]
        end
        function compatFrame:RegisterForDrag(button) end

        frame.compatFrame = compatFrame
        self.sidebarConfigFrame = frame
        self.advancedConfigFrame = compatFrame
        -- the preview strip lives in the pinned top; attached before the
        -- first page builds so that page's preview shows
        -- (the strip's cap is a share of the page's height; its width the page's)
        if RC.Preview then RC.Preview.Attach(frame, { holder = pinnedTop, Place = PlaceStrip,
            ContentHeight = function() return contentArea:GetHeight() end,
            StripWidth = function() return (contentChild:GetWidth() or (CONTENT_WIDTH - 18)) - 36 end }) end

        local savedBgOpacity = (self.db and self.db.fontSettings and self.db.fontSettings.mainWindowBgOpacity) or 1.0
        if frame.bg then frame.bg:SetAlpha(savedBgOpacity) end
        if frame.sidebar and frame.sidebar.bg then frame.sidebar.bg:SetAlpha(savedBgOpacity) end
        if frame.contentBg then frame.contentBg:SetAlpha(savedBgOpacity) end

        if self.db and self.db.sidebarState and self.db.sidebarState.expandedCategories then
            self.SidebarState.expandedCategories = self.db.sidebarState.expandedCategories
        end
        if not next(self.SidebarState.expandedCategories or {}) then
            self.SidebarState.expandedCategories = {home = true}
        end

        self:BuildSidebar(frame, true)

        -- With nothing remembered the window opens on Settings > General
        -- (the master switch), wherever that group sits in the list. Only
        -- the group holding the page that opens is unfolded; every other
        -- group keeps the open/closed state it was left in.
        local initialItem, initialCat
        for _, category in ipairs(self.MenuStructure) do
            for _, child in ipairs(category.children or {}) do
                if child.id == "general_behavior" then initialItem, initialCat = child, category break end
            end
            if initialItem then break end
        end
        if not initialItem then
            initialCat = self.MenuStructure[1]
            initialItem = initialCat and ((initialCat.children and initialCat.children[1]) or initialCat)
        end
        local defaultItem = initialItem

        if self.pendingNavigation then
            local nav = self.pendingNavigation
            self.pendingNavigation = nil

            if nav.type == "general" then
                for _, category in ipairs(self.MenuStructure) do
                    if category.id == "home" and category.children then
                        self.SidebarState.expandedCategories["home"] = true
                        for _, child in ipairs(category.children) do
                            if child.id == "general_behavior" then
                                initialItem = child
                                break
                            end
                        end
                        break
                    end
                end
            elseif nav.type == "raid" and nav.raidName then
                for _, category in ipairs(self.MenuStructure) do
                    if category.id == "raids" and category.children then
                        self.SidebarState.expandedCategories["raids"] = true
                        for _, child in ipairs(category.children) do
                            if child.raidKey == nav.raidName then
                                initialItem = child
                                break
                            end
                        end
                        break
                    end
                end
            elseif nav.type == "panel" and nav.panelId then
                for _, category in ipairs(self.MenuStructure) do
                    if category.children then
                        for _, child in ipairs(category.children) do
                            if child.id == nav.panelId then
                                self.SidebarState.expandedCategories[category.id] = true
                                initialItem = child
                                break
                            end
                        end
                    end
                    if initialItem and initialItem.id == nav.panelId then break end
                end
            end
        elseif self.db and self.db.lastSidebarSelection then
            if self.db.lastSidebarSelection == "home_welcome" then
                self.db.lastSidebarSelection = "home"
            end
            for _, category in ipairs(self.MenuStructure) do
                if category.id == self.db.lastSidebarSelection then
                    initialItem = category
                    break
                end
                if category.children then
                    for _, child in ipairs(category.children) do
                        if child.id == self.db.lastSidebarSelection then
                            self.SidebarState.expandedCategories[category.id] = true
                            initialItem = child
                            break
                        end
                    end
                end
            end
        end

        if initialItem == defaultItem and initialCat and initialItem ~= initialCat then
            self.SidebarState.expandedCategories[initialCat.id] = true
        end

        self:BuildSidebar(frame, true)
        self.SidebarState.selectedItem = initialItem.id
        self:ShowSidebarPanel(frame, initialItem)

        for _, button in ipairs(frame.sidebar.buttons or {}) do
            local isSelected = (button.menuItem.id == initialItem.id)
            self:SetSidebarButtonState(button, isSelected, self.SidebarState.expandedCategories[button.menuItem.id])
        end

        frame:SetScript("OnHide", function()
            if self.db.dragEnabled and self.dragTestFrame then
                self:HideDragTestFrame()
            end
            if self.GearManager and self.GearManager.HideMenu then
                self.GearManager:HideMenu()
            end
            if self.SaveConfigurationToProfile then
                self:SaveConfigurationToProfile()
            end
        end)

        -- Suppressed while the pop-in animation runs; sizes aren't settled until PopIn's
        -- delayed callback clears this and forces a scrollbar recalc.
        frame.suppressScrollbarUpdate = true

        if self.UI and self.UI.PopIn then
            frame:SetAlpha(0)
            frame:SetScale(0.95)
            frame:Show()
            self.UI:PopIn(frame, 0.18)

            C_Timer.After(0.2, function()
                if RC.sidebarConfigFrame and RC.sidebarConfigFrame:IsShown() then
                    RC.sidebarConfigFrame.suppressScrollbarUpdate = nil
                    RC:UpdateSidebarMenuScrollbar(RC.sidebarConfigFrame)
                    RC:UpdateSidebarScrollbar(RC.sidebarConfigFrame)
                end
            end)
        else
            frame.suppressScrollbarUpdate = nil
            frame:Show()
            self:UpdateSidebarMenuScrollbar(frame)
        end
        if self.MaybeStartTutorial then self:MaybeStartTutorial() end
        self:DebugPrint("Sidebar config window created", "config")
    end

    -- Legacy ConfigUI entry points get redirected to the sidebar equivalents whenever
    -- frame.isSidebarMode is set, so page files written for the old window keep working.
    local originalEnsureScrollbarWorks = RC.EnsureScrollbarWorks
    function RC:EnsureScrollbarWorks(frame)
        if frame and frame.isSidebarMode then
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            C_Timer.After(0.05, function()
                if self.sidebarConfigFrame and self.sidebarConfigFrame:IsShown() then
                    self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
                end
            end)
            return
        end
        if originalEnsureScrollbarWorks then
            return originalEnsureScrollbarWorks(self, frame)
        end
    end

    local originalSafeUpdateScrollHeight = RC.SafeUpdateScrollHeight
    function RC:SafeUpdateScrollHeight(frame, height, precalculatedMax)
        if frame and frame.isSidebarMode then
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            C_Timer.After(0.05, function()
                if self.sidebarConfigFrame and self.sidebarConfigFrame:IsShown() then
                    self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
                end
            end)
            C_Timer.After(0.15, function()
                if self.sidebarConfigFrame and self.sidebarConfigFrame:IsShown() then
                    self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
                end
            end)
            C_Timer.After(0.3, function()
                if self.sidebarConfigFrame and self.sidebarConfigFrame:IsShown() then
                    self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
                end
            end)
            C_Timer.After(0.5, function()
                if self.sidebarConfigFrame and self.sidebarConfigFrame:IsShown() then
                    self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
                end
            end)
            return
        end
        if originalSafeUpdateScrollHeight then
            return originalSafeUpdateScrollHeight(self, frame, height, precalculatedMax)
        end
    end

    local originalCreateBackButton = RC.CreateBackButton
    function RC:CreateBackButton(frame, targetFunction, text)
        if frame and frame.isSidebarMode then
            local parent = frame.scrollChild
            if not parent then return nil end

            local configState = frame.configState
            local needsBackButton = false

            if configState then
                needsBackButton = configState.selectedAbility or
                                  configState.selectedEncounter or
                                  configState.selectedTrashSection or
                                  (frame.bulkTrashState ~= nil)
            end

            -- Hidden 1x1 stand-in: callers expect a real button object even when no back
            -- action applies for this page state.
            if not needsBackButton then
                local dummyButton = CreateFrame("Button", nil, parent)
                dummyButton:SetSize(1, 1)
                dummyButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, -15)
                dummyButton:Hide()
                frame.currentBackButton = dummyButton
                return dummyButton
            end

            local normBg = self:GetColor("sidebar", "buttonNormal")
            local hoverBg = self:GetColor("sidebar", "buttonHover")

            local backButton = RC.UI:CreateBackButton(parent, "Back", 80, 28)
            backButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, -15)

            backButton:SetScript("OnClick", function()
                self:RefreshSidebarProfiles()

                self:ClearSidebarContent(self.sidebarConfigFrame)

                if configState.selectedAbility then
                    configState.selectedAbility = nil
                    local raidName = configState.selectedRaid
                    local encounterName = configState.selectedEncounter
                    local encounterType = configState.selectedEncounterType
                    if raidName and encounterName and encounterType then
                        local raidSettings = self:GetActiveRaidProfile(raidName)
                        if raidSettings then
                            self:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings)
                        else
                            self:OpenRaidBossPage(frame, raidName)
                        end
                    elseif configState.selectedRaid then
                        self:OpenRaidBossPage(frame, configState.selectedRaid)
                    else
                        self:ShowSidebarWelcome(frame)
                    end
                elseif configState.selectedEncounter then
                    configState.selectedEncounter = nil
                    configState.selectedEncounterType = nil
                    self:OpenRaidBossPage(frame, configState.selectedRaid)
                elseif configState.selectedTrashSection then
                    configState.selectedTrashSection = nil
                    self:OpenRaidBossPage(frame, configState.selectedRaid)
                elseif frame.bulkTrashState and frame.bulkTrashState.currentAbility then
                    frame.bulkTrashState.currentAbility = nil
                    self:ShowSidebarBulkTrashConfig(frame, configState.selectedRaid)
                else
                    local currentPanel = self.SidebarState and self.SidebarState.currentPanel
                    local backPanel = currentPanel and BACK_PANELS[currentPanel]
                    if backPanel and self[backPanel] then
                        self[backPanel](self, frame)
                    elseif configState.selectedRaid then
                        self:OpenRaidBossPage(frame, configState.selectedRaid)
                    else
                        self:ShowSidebarWelcome(frame)
                    end
                end
            end)

            frame.currentBackButton = backButton
            return backButton
        end

        if originalCreateBackButton then
            return originalCreateBackButton(self, frame, targetFunction, text)
        end
    end

    -- Redirects buttons parented to a compatFrame-shaped table (no CreateTexture, has scrollChild)
    -- onto its real scrollChild frame, since only real Frames can parent UI widgets.
    local originalUICreateButton = RC.UI.CreateButton
    RC.UI.CreateButton = function(self, parent, text, width, height)
        local actualParent = parent
        if type(parent) == "table" and not parent.CreateTexture and parent.scrollChild then
            actualParent = parent.scrollChild
        end
        return originalUICreateButton(self, actualParent, text, width, height)
    end

    function RC:CreateAdvancedConfigWindow()
        self:CreateSidebarConfigWindow()
    end

    local originalShowInitialConfiguration = RC.ShowInitialConfiguration
    function RC:ShowInitialConfiguration(frame)
        if frame and frame.isSidebarMode then
            local configState = frame.configState
            if configState and configState.selectedRaid then
                self:OpenRaidBossPage(frame, configState.selectedRaid)
                return
            end
            self:ShowSidebarWelcome(frame)
            return
        end

        if originalShowInitialConfiguration then
            return originalShowInitialConfiguration(self, frame)
        end
    end

    local originalOptimizedUITransition = RC.OptimizedUITransition
    -- Used for in-page state transitions (e.g. ability drill-down) rather than full navigation:
    -- clears scrollChild directly instead of going through ClearSidebarContent, and always resets
    -- scroll to 0 (no preserveScroll option here).
    function RC:OptimizedUITransition(targetFunction, frame)
        if frame and frame.isSidebarMode then
            local savedConfigState = {}
            if frame.configState then
                for k, v in pairs(frame.configState) do
                    savedConfigState[k] = v
                end
            end
            local savedBulkTrashState = frame.bulkTrashState
            local savedTrinketState = frame.trinketState
            local savedExecuteViewerState = frame.executeViewerState
            local savedProfileViewState = frame.profileViewState
            local savedTrinketConfigState = frame.trinketConfigState

            if frame.scrollChild then
                local children = {frame.scrollChild:GetChildren()}
                for _, child in ipairs(children) do
                    if child then
                        child:Hide()
                        child:SetParent(nil)
                    end
                end

                local regions = {frame.scrollChild:GetRegions()}
                for _, region in ipairs(regions) do
                    if region and region.Hide then
                        region:Hide()
                    end
                end
            end

            if frame.currentBackButton then
                frame.currentBackButton:Hide()
                frame.currentBackButton:SetParent(nil)
                frame.currentBackButton = nil
            end

            frame.elements = {}
            frame.layoutRows = {}
            frame.currentRow = 0
            frame.rowHeight = 0

            frame.configState = savedConfigState
            frame.bulkTrashState = savedBulkTrashState
            frame.trinketState = savedTrinketState
            frame.executeViewerState = savedExecuteViewerState
            frame.profileViewState = savedProfileViewState
            frame.trinketConfigState = savedTrinketConfigState

            if frame.contentFrame and frame.contentFrame.scrollBar then
                frame.contentFrame:SetVerticalScroll(0)
                frame.contentFrame.scrollBar:SetValue(0)
            end

            targetFunction(self, frame)

            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            C_Timer.After(0.05, function()
                if self.sidebarConfigFrame and self.sidebarConfigFrame:IsShown() then
                    self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
                end
            end)

            C_Timer.After(0.05, function()
                self:RefreshAllCheckboxes(frame)
            end)

            return
        end

        if originalOptimizedUITransition then
            return originalOptimizedUITransition(self, targetFunction, frame)
        end
    end

    RC:DebugPrint("Sidebar Config UI module loaded", "system")
