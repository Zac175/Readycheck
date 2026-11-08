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

    -- FOLD (the box left of the close): the window shrinks to its mark and
    -- name at its top-left corner - the game shows past it, previews and
    -- Edit Mode keep running - and the same box (now a +) opens it again
    -- at the size it had. Not saved: the next open is the full window.
    function RC:FoldSidebarConfig()
        local f = self.sidebarConfigFrame
        if not (f and f.sidebar) then return end
        local S = RC.UI.S
        local parts = { f.contentArea, f.footer, f.sidebar.scrollFrame, f.sidebar.searchContainer,
            f.editModeToolButton, f.resizeGrip, f.sidebar.scrollFrame and f.sidebar.scrollFrame.scrollBar }
        -- the corner stays where it is
        local l, t = f:GetLeft(), f:GetTop()
        if l and t then
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", l, t)
        end
        if f._rcFolded then
            local w, h = f._rcFolded[1], f._rcFolded[2]
            f._rcFolded = nil
            f:SetSize(w, h)
            for _, p in ipairs(parts) do p:Show() end
            if f.foldButton then f.foldButton.icon:SetTexture(RC.UI.ICONS .. "collapse") end
            self:UpdateSidebarMenuScrollbar(f)
            self:UpdateSidebarScrollbar(f)
        else
            f._rcFolded = { f:GetWidth(), f:GetHeight() }
            for _, p in ipairs(parts) do p:Hide() end
            f:SetSize(S.SIDEBAR + 100, S.NAV_TOP)
            if f.foldButton then f.foldButton.icon:SetTexture(RC.UI.ICONS .. "add") end
        end
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
            end
            return
        end

        local version = self.version or "3.0.0"

        -- THE WINDOW (5.0): ZacUI's /zui shell, number for number
        -- (RC.UI.S; zui_tests/MATCH_OPTIONS_1107.md has where each was read).
        -- No title bar: a 295 px sidebar (the mark and name, Edit Mode, the
        -- search, the groups), on the right the page under a pinned title,
        -- an 82 px footer (Reload, the window's scale, Close), and the
        -- close and fold boxes in the top right corner. The whole window
        -- drags.
        local S = RC.UI.S
        local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
        local ICONS = RC.UI.ICONS
        local SW = SIDEBAR.WIDTH
        local function SC(key, a) return RC.UI:SCol(key, a) end

        -- a first open: 1300 x 946, no more than 92% of the screen
        local WINDOW_WIDTH, WINDOW_HEIGHT = S.W, S.H
        do
            local sw0 = (UIParent and UIParent:GetWidth()) or 0
            local sh0 = (UIParent and UIParent:GetHeight()) or 0
            if sw0 > 0 then WINDOW_WIDTH = math.max(S.MIN_W, math.min(S.W, math.floor(sw0 * 0.92))) end
            if sh0 > 0 then WINDOW_HEIGHT = math.max(S.MIN_H, math.min(S.H, math.floor(sh0 * 0.92))) end
        end
        -- the page's own width: the right side less the room each side
        -- (cards sit 18 in from it, so they land at 45 from the pane)
        local function ContentW(w) return (w or WINDOW_WIDTH) - SW - 2 * S.PAGE_X end
        local CONTENT_WIDTH = ContentW(WINDOW_WIDTH)

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

        local bg = frame:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(FLAT)
        frame.bg = bg

        -- 1 px white 0.05 all round
        frame.border = self.UI:CreateSimpleBorder(frame)

        -- THE DRAG SURFACE: the whole window, under everything on it
        local titleBar = CreateFrame("Frame", nil, frame)
        titleBar:SetAllPoints(frame)
        titleBar:SetFrameLevel(frame:GetFrameLevel() + 1)
        titleBar:EnableMouse(true)
        titleBar:RegisterForDrag("LeftButton")
        titleBar:SetScript("OnMouseDown", function() frame:Raise() end)
        titleBar:SetScript("OnDragStart", function()
            frame:StartMoving()
        end)
        titleBar:SetScript("OnDragStop", function()
            frame:StopMovingOrSizing()
        end)
        frame.titleBar = titleBar

        -- NAV COLUMN: black 0.20 over the window, a 1 px white 0.05 rule
        local sidebar = CreateFrame("Frame", nil, frame)
        sidebar:SetWidth(SW)
        sidebar:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        sidebar:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        sidebar:SetFrameLevel(frame:GetFrameLevel() + 3)
        sidebar._rcSetRoot = true
        local LIST_TOP = S.NAV_TOP + S.NAV_ROW + S.SB_TOP + S.SB_H + S.SB_BOT
        sidebar.knownScrollHeight = WINDOW_HEIGHT - LIST_TOP - 12

        local sidebarBg = sidebar:CreateTexture(nil, "BACKGROUND")
        sidebarBg:SetAllPoints()
        sidebarBg:SetTexture(FLAT)
        sidebar.bg = sidebarBg

        local sidebarRule = sidebar:CreateTexture(nil, "OVERLAY")
        sidebarRule:SetTexture(FLAT)
        sidebarRule:SetWidth(1)
        sidebarRule:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", 0, 0)
        sidebarRule:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", 0, 0)
        sidebar.rule = sidebarRule

        -- THE MARK AND THE NAME in the sidebar's top 114: the mark 40 px at
        -- (22, 30), "Ready" white and "check" in the accent at 28, the
        -- version under them at 13, white 0.53
        local logo = CreateFrame("Frame", nil, sidebar)
        logo:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 0, 0)
        logo:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -1, 0)
        logo:SetHeight(S.NAV_TOP)
        logo:EnableMouse(false)
        local titleIcon = logo:CreateTexture(nil, "ARTWORK", nil, 3)
        titleIcon:SetSize(40, 40)
        titleIcon:SetPoint("TOPLEFT", logo, "TOPLEFT", 22, -30)
        titleIcon:SetTexture("Interface\\AddOns\\Readycheck\\Media\\Checkmark")
        if RC.UI and RC.UI.PaintMark then RC.UI:PaintMark(titleIcon) end
        titleIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local brandFirst = self:CreateFontString(logo, "OVERLAY", nil, S.F_BRAND)
        brandFirst:SetPoint("BOTTOMLEFT", titleIcon, "RIGHT", 10, -7)
        brandFirst:SetText(RCL["Ready"])
        local brandSecond = self:CreateFontString(logo, "OVERLAY", nil, S.F_BRAND)
        brandSecond:SetPoint("LEFT", brandFirst, "RIGHT", 0, 0)
        brandSecond:SetText(RCL["check"])
        local titleText = self:CreateFontString(logo, "OVERLAY", nil, S.F_VALUE)
        titleText:SetPoint("TOPLEFT", brandFirst, "BOTTOMLEFT", 1, -3)
        titleText:SetText("v" .. tostring(version))
        logo.first, logo.second, logo.version = brandFirst, brandSecond, titleText
        sidebar.logo = logo
        if RC.UI.AnimateMark then pcall(RC.UI.AnimateMark, RC.UI, titleIcon, logo, { inset = 0 }) end

        -- NEED HELP (2026-11-08): a speech bubble at the band's right,
        -- level with the mark (28 centred on the 40 px mark: 36 down). It
        -- opens "Message Zac on Discord" with the name ready to copy
        -- (UIF_Dialogs RC.UI:ShowDiscordContact). White at the window's
        -- dim alpha, the accent under the mouse.
        local contactButton = CreateFrame("Button", nil, sidebar)
        do
            local help = contactButton
            help:SetSize(28, 28)
            help:SetPoint("TOPRIGHT", logo, "TOPRIGHT", -22, -36)
            help:SetFrameLevel(sidebar:GetFrameLevel() + 5)
            local glyph = help:CreateTexture(nil, "ARTWORK")
            glyph:SetAllPoints()
            glyph:SetTexture(ICONS .. "discord")
            help.icon = glyph
            function help:Repaint()
                if self._rcHot then
                    local A = RC.UI:SAccent()
                    glyph:SetVertexColor(A.r, A.g, A.b, 1)
                else
                    glyph:SetVertexColor(SC("text", S.DIM_A))
                end
            end
            RC.UI:AttachHover(help, RC:GetColor("buttons", "normalBackground"), RC:GetColor("buttons", "hoverBackground"), {
                onEnter = function(b)
                    b._rcHot = true
                    b:Repaint()
                    GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
                    local tc = RC:GetColor("text", "gold") or RC.UI:SAccent()
                    GameTooltip:SetText(RCL["Need help?"], tc.r, tc.g, tc.b)
                    local bc = RC:GetColor("text", "gray") or { r = 0.7, g = 0.7, b = 0.7 }
                    GameTooltip:AddLine(RCL["Message Zac on Discord: "] .. tostring(RC.CONTACT_DISCORD or "Zac12")
                        .. RCL[". Click to copy the name."], bc.r, bc.g, bc.b, true)
                    GameTooltip:Show()
                end,
                onLeave = function(b)
                    b._rcHot = nil
                    b:Repaint()
                    GameTooltip:Hide()
                end,
            })
            help:SetScript("OnClick", function()
                if RC.UI.ShowDiscordContact then RC.UI:ShowDiscordContact() end
            end)
            help:Repaint()
            sidebar.contactButton = help
            frame.contactButton = help
        end

        -- A glow over the mark, played by frame.PlayIconAnimation() (the
        -- opening itself is the mark's own animation, above).
        local iconGlow = logo:CreateTexture(nil, "OVERLAY")
        iconGlow:SetSize(40, 40)
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
        frame.titleText = nil

        local function AttachTitleTooltip(button, header, ...)
            local lines = { ... }
            button:HookScript("OnEnter", function(btn)
                GameTooltip:SetOwner(btn, "ANCHOR_RIGHT")
                GameTooltip:SetText(header, 1, 1, 1)
                for _, line in ipairs(lines) do
                    GameTooltip:AddLine(line, 0.7, 0.7, 0.7, true)
                end
                GameTooltip:Show()
            end)
            button:HookScript("OnLeave", function() GameTooltip:Hide() end)
        end

        -- EDIT MODE: the sidebar's one fixed row (40 tall, a 45 x 32 icon
        -- box 20 in, the label 10 after it). The existing UIMover overlay,
        -- the same thing /rc moveui opens.
        local editModeButton = CreateFrame("Button", nil, sidebar)
        do
            local row = editModeButton
            row:SetHeight(S.NAV_ROW)
            row:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 0, -S.NAV_TOP)
            row:SetPoint("RIGHT", sidebar, "RIGHT", -1, 0)
            row:SetFrameLevel(sidebar:GetFrameLevel() + 5)
            local function Tex(layer, sub)
                local t = row:CreateTexture(nil, layer, nil, sub)
                t:SetTexture(FLAT)
                return t
            end
            local hl = Tex("BACKGROUND", 3) hl:SetAllPoints()
            local glow = Tex("BACKGROUND", 2) glow:SetAllPoints()
            local ind = Tex("ARTWORK", 1) ind:SetWidth(3)
            ind:SetPoint("TOPLEFT") ind:SetPoint("BOTTOMLEFT")
            local icon = row:CreateTexture(nil, "ARTWORK", nil, 2)
            icon:SetSize(S.NAV_ICON_H, S.NAV_ICON_H)
            icon:SetPoint("LEFT", row, "LEFT", S.NAV_LEFT + (S.NAV_ICON_W - S.NAV_ICON_H) / 2, 0)
            icon:SetTexture(ICONS .. "mode")
            local label = self:CreateFontString(row, "OVERLAY", nil, S.F_NAV)
            label:SetPoint("LEFT", row, "LEFT", S.NAV_LEFT + S.NAV_ICON_W + S.NAV_GAP, 0)
            label:SetText(RCL["Edit Mode"])
            row.text, row.icon = label, icon
            function row:Repaint()
                local hot, on = self._rcHot, self._rcActive
                local A = RC.UI:SAccent()
                local h = RC:GetColor("settings", "hoverTint")
                hl:SetShown(hot and not on and true or false)
                hl:SetVertexColor(SC("text", S.NAV_HL))
                glow:SetShown((hot or on) and true or false)
                if on then RC.UI:Grad(glow, A, S.NAV_GLOW) elseif hot then RC.UI:Grad(glow, h, S.NAV_HOVER_GLOW) end
                ind:SetShown((hot or on) and true or false)
                if on then ind:SetVertexColor(A.r, A.g, A.b, 1) else ind:SetVertexColor(h.r, h.g, h.b, S.NAV_HOVER_IND) end
                local a = on and 1 or (hot and S.NAV_HOVER or S.NAV_EN)
                label:SetTextColor(SC("text", a))
                icon:SetVertexColor(SC("text", a))
            end
            function row:SetActive(on) self._rcActive = on and true or false self:Repaint() end
            row:SetScript("OnEnter", function(b) b._rcHot = true b:Repaint() end)
            row:SetScript("OnLeave", function(b) b._rcHot = nil b:Repaint() end)
            row:SetScript("OnClick", function()
                if RC.EnterEditMode then RC:EnterEditMode() end
            end)
            row:Repaint()
        end
        AttachTitleTooltip(editModeButton,
            RCL["Edit Mode"],
            RCL["Show every movable Readycheck frame at once over a grid and drag them into place."],
            RCL["Escape or Save & Lock to finish."])
        frame.editModeToolButton = editModeButton

        -- Opening the window while the mover is already up (/rc moveui,
        -- then /rc) should still show the row in its active state.
        frame:HookScript("OnShow", function()
            local UM = RC.UIMover
            editModeButton:SetActive(UM and UM.isMoving and true or false)
        end)

        -- SEARCH: 28 high, 22 in, 13 under Edit Mode; input fill 0.35, a
        -- white 0.10 edge (the accent while typing); text 13, hint 12
        local searchContainer = CreateFrame("Frame", nil, sidebar)
        searchContainer:SetPoint("TOPLEFT", sidebar, "TOPLEFT", S.SB_INSET + 2, -(S.NAV_TOP + S.NAV_ROW + S.SB_TOP))
        searchContainer:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -S.SB_INSET, -(S.NAV_TOP + S.NAV_ROW + S.SB_TOP))
        searchContainer:SetHeight(S.SB_H)
        searchContainer:SetFrameLevel(sidebar:GetFrameLevel() + 5)
        searchContainer.bg = searchContainer:CreateTexture(nil, "BACKGROUND")
        searchContainer.bg:SetAllPoints()
        searchContainer.bg:SetTexture(FLAT)
        searchContainer.border = self.UI:CreateSimpleBorder(searchContainer)
        function searchContainer:Repaint()
            self.bg:SetVertexColor(SC("input", S.INPUT_A))
            local A = RC.UI:SAccent()
            if self._rcFocus then
                RC.UI:UpdateBorderColor(self.border, A, S.INPUT_FOCUS_A)
            else
                RC.UI:UpdateBorderColor(self.border, RC:GetColor("settings", "text"), S.INPUT_BRD_A)
            end
        end
        sidebar.searchContainer = searchContainer
        local searchBox = CreateFrame("EditBox", nil, searchContainer)
        searchBox:SetAllPoints(searchContainer)
        searchBox:SetAutoFocus(false)
        searchBox:SetMaxLetters(64)
        self:ApplyCustomFont(searchBox, S.F_VALUE)
        searchBox:SetTextColor(SC("text", 1))
        local placeholder = searchBox:CreateFontString(nil, "OVERLAY")
        self:ApplyCustomFont(placeholder, S.F_HINT)
        placeholder:SetTextColor(SC("text", S.OFF_A))
        placeholder:SetPoint("LEFT", searchBox, "LEFT", 10, 0)
        placeholder:SetText(RCL["Search settings..."])
        sidebar.searchPlaceholder = placeholder
        searchBox:SetScript("OnTextChanged", function(self)
            local txt = self:GetText()
            placeholder:SetShown(txt == "")
            frame.sidebarSearchText = (txt ~= "") and txt:lower() or nil
            if sidebar.searchClearBtn then
                sidebar.searchClearBtn:SetShown(txt ~= "")
            end
            RC:BuildSidebar(frame, false)
            -- The settings search: ranked results in a dropdown under the
            -- box (Sidebar_SearchBox), each one a jump to the setting itself.
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
            searchContainer._rcFocus = true
            searchContainer:Repaint()
            -- Reading the pages starts as soon as the box is clicked, so
            -- most of the index is there by the time a word is typed.
            if RC.SidebarSearch then RC.SidebarSearch.OnFocus() end
        end)
        searchBox:SetScript("OnEditFocusLost", function()
            searchContainer._rcFocus = nil
            searchContainer:Repaint()
        end)
        sidebar.searchBox = searchBox
        searchContainer:Repaint()

        -- Clear: the framework's chromeless X, 20 x 20 at 4 from the right
        local clearBtn = self.UI:CreateXCloseButton(searchContainer, 20, function()
            searchBox:SetText("")
            searchBox:ClearFocus()
        end)
        clearBtn:SetPoint("RIGHT", searchContainer, "RIGHT", -4, 0)
        clearBtn:SetFrameLevel(searchBox:GetFrameLevel() + 2)
        clearBtn:Hide()
        sidebar.searchClearBtn = clearBtn

        searchBox:SetTextInsets(10, 24, 0, 0)

        -- THE GROUPS: 6 under the search, to 12 above the window's foot
        local sidebarScroll = CreateFrame("ScrollFrame", "WRSidebarMenuScroll", sidebar)
        sidebarScroll:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 0, -LIST_TOP)
        sidebarScroll:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -1, 12)
        if sidebarScroll.SetClipsChildren then sidebarScroll:SetClipsChildren(true) end

        local sidebarChild = CreateFrame("Frame", nil, sidebarScroll)
        sidebarChild:SetWidth(SW - 1)
        sidebarChild:SetHeight(800)
        sidebarScroll:SetScrollChild(sidebarChild)

        -- a thin rail at the right edge (3 px, white 0.03 / thumb 0.25)
        local sidebarScrollBar = CreateFrame("Slider", nil, sidebar)
        sidebarScrollBar:SetWidth(16)
        sidebarScrollBar:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", 5, -LIST_TOP - 2)
        sidebarScrollBar:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", 5, 14)
        sidebarScrollBar:SetOrientation("VERTICAL")
        sidebarScrollBar:SetMinMaxValues(0, 0)
        sidebarScrollBar:SetValue(0)
        sidebarScrollBar:SetValueStep(1)
        sidebarScrollBar:SetFrameLevel(sidebar:GetFrameLevel() + 6)

        local sidebarScrollBg = sidebarScrollBar:CreateTexture(nil, "BACKGROUND")
        sidebarScrollBg:SetAllPoints()
        sidebarScrollBg:SetTexture(FLAT)
        sidebarScrollBar.bg = sidebarScrollBg

        local sidebarThumb = sidebarScrollBar:CreateTexture(nil, "OVERLAY")
        sidebarThumb:SetTexture(FLAT)
        sidebarThumb:SetSize(3, 60)
        sidebarScrollBar:SetThumbTexture(sidebarThumb)
        sidebarScrollBar.thumb = sidebarThumb

        sidebarScrollBar:SetScript("OnValueChanged", function(self, value)
            sidebarScroll:SetVerticalScroll(value)
        end)
        self.UI:StyleScrollBar(sidebarScrollBar, { settings = true, width = 3, track = S.SCROLL_TRACK_A + 0.01, thumb = S.SCROLL_THUMB_A - 0.02 })

        sidebar:EnableMouseWheel(true)
        self.UI:SmoothWheel(sidebar, sidebarScrollBar, S.WHEEL)

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
                frame.sidebar.knownScrollHeight = newH - LIST_TOP - 12
            end
            -- Debounced: OnSizeChanged fires repeatedly during a drag-resize.
            if frame._menuResizeTimer then frame._menuResizeTimer:Cancel() end
            frame._menuResizeTimer = C_Timer.NewTimer(0.1, function()
                frame._menuResizeTimer = nil
                if RC and RC.UpdateSidebarMenuScrollbar and RC.sidebarConfigFrame then
                    RC:UpdateSidebarMenuScrollbar(RC.sidebarConfigFrame)
                end
            end)
        end)

        -- THE RIGHT SIDE: the page, above the 82 px footer. The window's
        -- fill shows through (sections are rows on the panel); the pane
        -- keeps a see-through texture the opacity setting can still reach.
        local pageW = WINDOW_WIDTH

        local contentArea = CreateFrame("Frame", nil, frame)
        contentArea:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 0, 0)
        contentArea:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, S.FOOTER)
        contentArea:SetFrameLevel(frame:GetFrameLevel() + 3)

        local contentBg = contentArea:CreateTexture(nil, "BACKGROUND")
        contentBg:SetAllPoints()
        contentBg:SetTexture(FLAT)
        contentArea.bg = contentBg
        frame.contentBg = contentBg

        -- the page scrolls 27 in from each side: what it puts 18 in (cards,
        -- headers, tab rows) lands on the window's 45 px content pad
        local contentScroll = CreateFrame("ScrollFrame", "WRSidebarContentScroll", contentArea)
        contentScroll:SetPoint("TOPLEFT", contentArea, "TOPLEFT", S.PAGE_X, 0)
        contentScroll:SetPoint("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", -S.PAGE_X, 0)

        local contentChild = CreateFrame("Frame", nil, contentScroll)
        contentChild:SetWidth(CONTENT_WIDTH)
        contentChild:SetHeight(1500)
        contentChild._rcSetRoot = true
        contentScroll:SetScrollChild(contentChild)

        -- the page's scrollbar: 4 px at 12 from the right, white 0.02 rail,
        -- white 0.27 thumb, hidden when the page fits
        local scrollBar = CreateFrame("Slider", nil, contentArea)
        scrollBar:SetWidth(16)
        scrollBar:SetPoint("TOPRIGHT", contentArea, "TOPRIGHT", -6, -4)
        scrollBar:SetPoint("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", -6, 4)
        scrollBar:SetOrientation("VERTICAL")
        scrollBar:SetMinMaxValues(0, 1)
        scrollBar:SetValue(0)
        scrollBar:SetValueStep(1)
        scrollBar:SetFrameLevel(contentArea:GetFrameLevel() + 8)

        local scrollBg = scrollBar:CreateTexture(nil, "BACKGROUND")
        scrollBg:SetAllPoints()
        scrollBg:SetTexture(FLAT)
        scrollBar.bg = scrollBg

        local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
        thumb:SetTexture(FLAT)
        thumb:SetSize(S.SCROLL_W, 60)
        scrollBar:SetThumbTexture(thumb)
        scrollBar.thumb = thumb

        scrollBar:SetScript("OnValueChanged", function(self, value)
            contentScroll:SetVerticalScroll(value)
        end)
        self.UI:StyleScrollBar(scrollBar, { settings = true, width = S.SCROLL_W })

        contentScroll.scrollBar = scrollBar

        scrollBar:SetAlpha(0)

        contentArea:EnableMouseWheel(true)
        self.UI:SmoothWheel(contentArea, scrollBar, S.WHEEL)

        -- THE PINNED TOP: the page's title, and on a page with a preview
        -- the strip under it (UIF_Preview), above the scroll area. Set in
        -- like the page, so the title lands at 45.
        local pinnedTop = CreateFrame("Frame", nil, contentArea)
        pinnedTop:SetPoint("TOPLEFT", contentArea, "TOPLEFT", S.PAGE_X, 0)
        pinnedTop:SetSize(CONTENT_WIDTH, 1)
        pinnedTop:Hide()
        frame.pinnedTop = pinnedTop

        frame.contentArea = contentArea
        frame.contentFrame = contentScroll
        frame.contentScrollChild = contentChild

        -- THE CORNER: fold and close, 40 x 40 boxes at the top right
        local function CornerBox(iconName, onClick)
            local b = CreateFrame("Button", nil, titleBar)
            b:SetSize(S.CLOSE_BOX, S.CLOSE_BOX)
            b:SetFrameLevel(frame:GetFrameLevel() + 30)
            local t = b:CreateTexture(nil, "ARTWORK")
            t:SetSize(16, 16)
            t:SetPoint("CENTER")
            t:SetTexture(ICONS .. iconName)
            b.icon = t
            function b:Repaint() t:SetVertexColor(SC("text", self._rcHot and 1 or S.DIM_A)) end
            b:SetScript("OnEnter", function(self) self._rcHot = true self:Repaint() end)
            b:SetScript("OnLeave", function(self) self._rcHot = nil self:Repaint() GameTooltip:Hide() end)
            b:SetScript("OnClick", onClick)
            b:Repaint()
            return b
        end
        local closeButton = CornerBox("close", function() frame:Hide() end)
        closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -11)
        frame.closeButton = closeButton
        AttachTitleTooltip(closeButton, RCL["Close"])

        -- FOLD: the window shrinks to its mark and name (it keeps running,
        -- previews and Edit Mode included); the same box brings it back.
        local foldButton = CornerBox("collapse", function() RC:FoldSidebarConfig() end)
        foldButton:SetPoint("TOPRIGHT", closeButton, "TOPLEFT", -4, 0)
        frame.foldButton = foldButton
        AttachTitleTooltip(foldButton, RCL["Fold"],
            RCL["Fold this window to its name so you can see the game. Click again to open it."])

        -- THE FOOTER (82): Reload on the left, Close on the right, the
        -- window's own scale between them
        local footer = CreateFrame("Frame", nil, frame)
        footer:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMRIGHT", 0, 0)
        footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        footer:SetHeight(S.FOOTER)
        footer:SetFrameLevel(frame:GetFrameLevel() + 20)
        footer._rcSetRoot = true
        frame.footer = footer

        local reloadButton = self.UI:CreateStyledButton(footer, RCL["Reload"], S.FOOT_BTN_W, S.FOOT_BTN_H)
        self.UI:StyleSettingsButton(reloadButton, "footer")
        reloadButton:SetPoint("BOTTOMLEFT", footer, "BOTTOMLEFT", S.FOOT_PAD, S.FOOT_PAD)
        reloadButton:SetScript("OnClick", function() ReloadUI() end)
        AttachTitleTooltip(reloadButton,
            RCL["Reload"],
            RCL["Reloads the interface. Needed for font, skin and minimap-button changes to fully apply."])
        frame.reloadButton = reloadButton

        local doneButton = self.UI:CreateStyledButton(footer, RCL["Close"], S.FOOT_CLOSE_W, S.FOOT_BTN_H)
        self.UI:StyleSettingsButton(doneButton, "close")
        doneButton:SetPoint("BOTTOMRIGHT", footer, "BOTTOMRIGHT", -S.FOOT_PAD, S.FOOT_PAD)
        doneButton:SetScript("OnClick", function() frame:Hide() end)
        frame.doneButton = doneButton

        -- THE WINDOW'S SCALE (fontSettings.mainWindowScale, nil = 100%):
        -- this window only, 60-140% in 5% steps
        local function WinScale()
            local fs = RC.db and RC.db.fontSettings
            return (fs and tonumber(fs.mainWindowScale)) or 1
        end
        local scaleText
        local function SetWinScale(v)
            v = math.max(0.6, math.min(1.4, math.floor(v * 20 + 0.5) / 20))
            if RC.db then
                RC.db.fontSettings = RC.db.fontSettings or {}
                RC.db.fontSettings.mainWindowScale = (math.abs(v - 1) < 0.001) and nil or v
            end
            frame:SetScale(v)
            if scaleText then scaleText:SetText(math.floor(v * 100 + 0.5) .. "%") end
            -- the preview keeps its sample at the real, in-game size
            if RC.Preview and RC.Preview.Place then pcall(RC.Preview.Place) end
        end
        local plus = self.UI:CreateStyledButton(footer, "+", S.FOOT_BTN_H, S.FOOT_BTN_H)
        self.UI:StyleSettingsButton(plus, "footer")
        plus:SetPoint("RIGHT", doneButton, "LEFT", -20, 0)
        plus:SetScript("OnClick", function() SetWinScale(WinScale() + 0.05) end)
        scaleText = self:CreateFontString(footer, "OVERLAY", nil, S.F_VALUE)
        scaleText:SetWidth(52)
        scaleText:SetJustifyH("CENTER")
        scaleText:SetPoint("RIGHT", plus, "LEFT", 0, 0)
        scaleText:SetTextColor(SC("text", S.DIM_A))
        scaleText:SetText(math.floor(WinScale() * 100 + 0.5) .. "%")
        local minus = self.UI:CreateStyledButton(footer, "-", S.FOOT_BTN_H, S.FOOT_BTN_H)
        self.UI:StyleSettingsButton(minus, "footer")
        minus:SetPoint("RIGHT", scaleText, "LEFT", 0, 0)
        minus:SetScript("OnClick", function() SetWinScale(WinScale() - 0.05) end)
        AttachTitleTooltip(plus, RCL["Window scale"], RCL["Grows or shrinks this window only."])
        AttachTitleTooltip(minus, RCL["Window scale"], RCL["Grows or shrinks this window only."])
        frame.scaleText, frame.scaleUp, frame.scaleDown = scaleText, plus, minus
        if math.abs(WinScale() - 1) > 0.001 then frame:SetScale(WinScale()) end

        -- The shell's own colours (RefreshUIColors calls this).
        function frame:RepaintShell()
            local op = (RC.db and RC.db.fontSettings and RC.db.fontSettings.mainWindowBgOpacity) or 1.0
            -- (the old repaint may have made it a colour texture)
            self.bg:SetTexture(FLAT)
            self.bg:SetVertexColor(SC("windowBackground", 1))
            self.bg:SetAlpha(op)
            RC.UI:UpdateBorderColor(self.border, RC:GetColor("settings", "text"), S.BORDER_A)
            sidebarBg:SetVertexColor(SC("shade", S.SIDEBAR_A))
            sidebarBg:SetAlpha(op)
            sidebarRule:SetVertexColor(SC("text", S.BORDER_A))
            contentBg:SetVertexColor(0, 0, 0, 0)
            local A = RC.UI:SAccent()
            brandFirst:SetTextColor(SC("text", 1))
            brandSecond:SetTextColor(A.r, A.g, A.b, 1)
            titleText:SetTextColor(SC("text", S.DIM_A))
            scaleText:SetTextColor(SC("text", S.DIM_A))
            editModeButton:Repaint()
            contactButton:Repaint()
            searchContainer:Repaint()
            closeButton:Repaint()
            foldButton:Repaint()
            for _, b in ipairs({ reloadButton, doneButton, plus, minus }) do
                if b.Repaint then b:Repaint() end
            end
        end
        frame:RepaintShell()

        local MIN_WIDTH = S.MIN_W
        local MAX_WIDTH = S.MAX_W
        local MIN_HEIGHT = S.MIN_H
        local MAX_HEIGHT = S.MAX_H

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
            dot:SetColorTexture(SC("text", 0.25))
            resizeGrip.dots[i] = dot
        end

        resizeGrip:SetScript("OnEnter", function()
            local A = RC.UI:SAccent()
            for _, dot in ipairs(resizeGrip.dots) do
                dot:SetColorTexture(A.r, A.g, A.b, 1)
            end
        end)

        resizeGrip:SetScript("OnLeave", function()
            for _, dot in ipairs(resizeGrip.dots) do
                dot:SetColorTexture(SC("text", 0.25))
            end
        end)

        resizeGrip:SetScript("OnMouseDown", function(self, button)
            if button == "LeftButton" and not frame._rcFolded then
                frame:StartSizing("BOTTOMRIGHT")
            end
        end)

        resizeGrip:SetScript("OnMouseUp", function(self, button)
            frame:StopMovingOrSizing()
            if frame._rcFolded then return end
            local oldW = pageW
            pageW = math.max(MIN_WIDTH, frame:GetWidth() or pageW)
            if RC.db then
                RC.db.configWindowWidth = pageW
                RC.db.configWindowHeight = frame:GetHeight()
                RC.db.fontSettings = RC.db.fontSettings or {}
                RC.db.fontSettings.windowLayout = 5
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
            if self._rcFolded then return end
            local newContentWidth = ContentW(width)
            local cw = contentChild:GetWidth()
            if not cw or math.abs(cw - newContentWidth) > 3 then
                contentChild:SetWidth(newContentWidth)
            end
            pinnedTop:SetWidth(contentChild:GetWidth())

            if self._resizeTimer then
                self._resizeTimer:Cancel()
            end
            self._resizeTimer = C_Timer.NewTimer(0.05, function()
                self._resizeTimer = nil
                if RC.UpdateSidebarScrollbar then
                    RC:UpdateSidebarScrollbar(self)
                end
                if RC.UpdateSidebarMenuScrollbar then
                    RC:UpdateSidebarMenuScrollbar(self)
                end
            end)
        end)

        -- A size saved before 5.0 was chosen for the old window (a 200 px
        -- menu, no footer): the first open of this one starts at its own
        -- size; a size saved since wins.
        local fsv = self.db and self.db.fontSettings
        if self.db and self.db.configWindowWidth and self.db.configWindowHeight and fsv and fsv.windowLayout == 5 then
            local savedWidth = math.max(MIN_WIDTH, math.min(MAX_WIDTH, self.db.configWindowWidth))
            local savedHeight = math.max(MIN_HEIGHT, math.min(MAX_HEIGHT, self.db.configWindowHeight))
            frame:SetSize(savedWidth, savedHeight)
            pageW = savedWidth
            contentChild:SetWidth(ContentW(savedWidth))
            pinnedTop:SetWidth(contentChild:GetWidth())
        end

        -- THE PREVIEW STRIP'S ROOM (UIF_Preview calls this through
        -- Preview.Attach): a strip h high, stripY down the pinned top (0:
        -- none; the page's title alone when it is pinned), and the scroll
        -- area moved to start below it. The window never changes size.
        local function PlaceStrip(stripY, h, pinned)
            local cw = contentChild:GetWidth() or CONTENT_WIDTH
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
            contentScroll:SetPoint("TOPLEFT", contentArea, "TOPLEFT", S.PAGE_X, -top)
            scrollBar:SetPoint("TOPRIGHT", contentArea, "TOPRIGHT", -6, -4 - top)
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
                if self.ResolvePageId then nav.panelId = self:ResolvePageId(nav.panelId) end
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
            if self.ResolvePageId then
                self.db.lastSidebarSelection = self:ResolvePageId(self.db.lastSidebarSelection)
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

        -- a page this game version does not have (Core_Flavor) opens the
        -- first page instead
        if initialItem ~= defaultItem and self.FeatureOffForPage and self:FeatureOffForPage(initialItem) then
            initialItem = defaultItem
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
            -- closed while folded: it opens full size next time
            if frame._rcFolded then self:FoldSidebarConfig() end
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
