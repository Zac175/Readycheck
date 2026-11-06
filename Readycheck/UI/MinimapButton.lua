------------------------------------------------------------------------
-- Readycheck - Minimap Button
-- Owns the minimap icon: LibDBIcon-backed by default (the libraries ship
-- in Libs, and a LibDBIcon button is what HidingBar, MBB and ZacUI's
-- button tray all know how to collect), with a manual fallback button
-- (angle-around-Minimap drag) should LibDataBroker or LibDBIcon ever be
-- missing. Position is stored as a degree angle, not x/y.
-- self.usingLibDBIcon picks which of the two position systems is live.
-- The right-click menu lists the sidebar's pages from RC.MenuStructure,
-- gated by RC:SidebarItemVisible, so it never drifts from the sidebar.
------------------------------------------------------------------------
local function InitializeMinimapButton()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.3, InitializeMinimapButton)
        return
    end

    RC.MinimapButton = {}
    local MB = RC.MinimapButton

    local LDB = LibStub:GetLibrary("LibDataBroker-1.1", true)
    local LDBI = LibStub:GetLibrary("LibDBIcon-1.0", true)

    -- Everything the menu lists comes from RC.MenuStructure, the same
    -- registry the sidebar is built from, filtered by the same predicate
    -- (RC:SidebarItemVisible: class, which Readycheck addons are loaded,
    -- per-page switches). A page added to the sidebar is in this menu the
    -- same moment; a page the sidebar would hide, this hides too.
    local function MenuCategories()
        local out = {}
        if not RC.MenuStructure then return out end
        for _, cat in ipairs(RC.MenuStructure) do
            if cat.children and (not RC.SidebarItemVisible or RC:SidebarItemVisible(cat)) then
                local pages = {}
                for _, child in ipairs(cat.children) do
                    if not RC.SidebarItemVisible or RC:SidebarItemVisible(child) then
                        pages[#pages + 1] = child
                    end
                end
                if #pages > 0 then out[#out + 1] = { cat = cat, pages = pages } end
            end
        end
        return out
    end

    function MB:ToggleLock()
        if not RC.db or not RC.db.minimapButton then return end
        local locked = not RC.db.minimapButton.lock
        RC.db.minimapButton.lock = locked
        if self.usingLibDBIcon and LDBI then
            if locked and LDBI.Lock then
                LDBI:Lock("Readycheck")
            elseif (not locked) and LDBI.Unlock then
                LDBI:Unlock("Readycheck")
            end
        end
    end

    -- The menu, in the Readycheck look (RC.UI:ShowContextMenu). Falls
    -- back to Blizzard's dropdown only if the framework is somehow absent.
    function MB:ShowMenu()
        if not RC then return end
        if not (RC.UI and RC.UI.ShowContextMenu) then
            if RC.Print then RC:Print(RCL["The menu needs the UI framework, which did not load."]) end
            return
        end

        local function nav(id)
            return function()
                if RC.OpenConfig then RC:OpenConfig({ type = "panel", panelId = id }) end
            end
        end
        local function pageItems(entry)
            local out = {}
            for _, page in ipairs(entry.pages) do
                local it = { text = page.name, icon = page.icon }
                if page.raidKey then
                    local raidKey = page.raidKey
                    it.func = function()
                        if RC.OpenConfig then RC:OpenConfig({ type = "raid", raidName = raidKey }) end
                    end
                else
                    it.func = nav(page.id)
                end
                out[#out + 1] = it
            end
            return out
        end

        local items = {
            { text = RCL["Readycheck"], isTitle = true },
            { text = RCL["Open Readycheck"], tooltip = RCL["Opens the settings window (/rc)."],
              func = function()
                  if RC.OpenConfig then RC:OpenConfig()
                  elseif RC.CreateAdvancedConfigWindow then RC:CreateAdvancedConfigWindow() end
              end },
            { text = RCL["World Buffs Board"], tooltip = RCL["Toggles the world buff board for your group."],
              func = function() if RC.ToggleWorldBuffMini then RC:ToggleWorldBuffMini() end end },
            { separator = true },
        }
        -- one submenu per sidebar category, in sidebar order
        for _, entry in ipairs(MenuCategories()) do
            local e = entry
            items[#items + 1] = { text = e.cat.name, children = function() return pageItems(e) end }
        end
        items[#items + 1] = { separator = true }
        items[#items + 1] = { text = RCL["Test Reminders"], tooltip = RCL["Fires a sample reminder so you can see where it lands."],
            func = function() if RC.ShowTestReminder then RC:ShowTestReminder(true) end end }
        -- Same entry point as the settings window's title bar and
        -- /rc moveui: the one UIMover overlay, never a second one.
        items[#items + 1] = { text = RCL["Edit Mode"],
            tooltip = RCL["Show every movable Readycheck frame at once over a grid and drag them into place."]
                .. " " .. RCL["Escape or Save & Lock to finish."],
            func = function() if RC.EnterEditMode then RC:EnterEditMode() end end }
        items[#items + 1] = { text = RCL["Setup Wizard"], tooltip = RCL["Walks through the first-time setup again (/rc setup)."],
            func = function() if RC.SetupWizardCommand then RC:SetupWizardCommand() end end }
        items[#items + 1] = { text = RCL["Tour"], tooltip = RCL["The guided tour of the settings window (/rc tour)."],
            func = function() if RC.TutorialCommand then RC:TutorialCommand() end end }
        items[#items + 1] = { separator = true }
        items[#items + 1] = { text = RCL["Lock Minimap Button"], keepOpen = true,
            checked = function() return (RC.db and RC.db.minimapButton and RC.db.minimapButton.lock) and true or false end,
            tooltip = RCL["Stops the minimap button from being dragged around the minimap."],
            func = function() MB:ToggleLock() end }
        items[#items + 1] = { text = RCL["Hide Minimap Button"],
            tooltip = RCL["Hides this button. Bring it back with the \"Show minimap button\" option on the General & Behavior page."],
            func = function() if MB.SetVisible then MB:SetVisible(false) end end }

        RC.UI:ShowContextMenu(items)
    end

    local function HandleClick(self, button)
        local RC = _G.Readycheck
        if not RC then return end
        if button == "LeftButton" then
            if RC.OpenConfig then
                RC:OpenConfig()
            elseif RC.CreateAdvancedConfigWindow then
                RC:CreateAdvancedConfigWindow()
            end
        elseif button == "RightButton" then
            MB:ShowMenu()
        elseif button == "MiddleButton" then
            if RC.ToggleWorldBuffMini then RC:ToggleWorldBuffMini() end
        end
    end

    local function FillTooltip(tt)
        if not tt or not tt.AddLine then return end
        tt:SetText(RCL["Readycheck"], 1, 1, 1)
        tt:AddLine(" ")
        tt:AddLine(RCL["Left-Click: Open Readycheck"], 0.2, 1, 0.2)
        tt:AddLine(RCL["Right-Click: Menu"], 0.7, 0.85, 1)
        tt:AddLine(RCL["Middle-Click: World Buffs board"], 0.7, 0.85, 1)
        tt:AddLine(RCL["Drag: Reposition"], 0.6, 0.6, 0.6)
        tt:Show()
    end

    function MB:CreateDataBrokerObject()
        if not LDB then
            RC:DebugPrint("LibDataBroker not found - using fallback minimap button", "system")
            return nil
        end

        -- "Readycheck" is the LDB/LibDBIcon registration name other
        -- minimap-button-collector addons key on; changing it orphans
        -- saved positions and breaks those integrations.
        local dataObj = LDB:NewDataObject("Readycheck", {
            type = "data source",
            text = RCL["Readycheck"],
            icon = "Interface\\AddOns\\Readycheck\\Media\\Checkmark",
            OnClick = function(clickedframe, button)
                HandleClick(clickedframe, button)
            end,
            OnTooltipShow = function(tooltip)
                FillTooltip(tooltip)
            end,
        })
        -- the mark in the picked Checkmark colour, when there is one
        if RC.UI and RC.UI.MarkLook then
            local path, r, g, b = RC.UI:MarkLook()
            dataObj.icon = path
            if r ~= 1 or g ~= 1 or b ~= 1 then dataObj.iconR, dataObj.iconG, dataObj.iconB = r, g, b end
        end

        return dataObj
    end

    -- The icon flips over and back (like a coin turning on its upright
    -- axis) each time the mouse crosses the button - the same flip as the
    -- mark on every Readycheck window (RC.UI:CreateMarkFlip).
    local function AttachSpin(btn)
        if not (btn and btn.icon) or btn._rcFlip then return end
        local flip = RC.UI and RC.UI.CreateMarkFlip and RC.UI:CreateMarkFlip(btn.icon)
        if not flip then return end
        btn._rcFlip = flip
        btn:HookScript("OnEnter", function() flip:Play() end)
    end

    function MB:Initialize()
        if self.initialized then return end

        -- position: read/written by this file's own fallback-button drag
        -- (GetButtonPosition/UpdatePosition). minimapPos: the field
        -- LibDBIcon reads/writes internally once registered. Both are
        -- seeded together so whichever system is active stays in sync.
        if not RC.db.minimapButton then
            RC.db.minimapButton = {
                hide = false,
                position = 225,
                minimapPos = 225,
                lock = false
            }
        end

        if LDBI then
            local dataObj = self:CreateDataBrokerObject()
            if dataObj then
                LDBI:Register("Readycheck", dataObj, RC.db.minimapButton)
                self.usingLibDBIcon = true
                self.dataObj = dataObj
                AttachSpin(LDBI.GetMinimapButton and LDBI:GetMinimapButton("Readycheck"))

                RC:DebugPrint("Minimap button registered with LibDBIcon (compatible with HidingBar, MBB, etc.)", "system")

                if RC.db.minimapButton.hide then
                    LDBI:Hide("Readycheck")
                else
                    LDBI:Show("Readycheck")
                end

                self.initialized = true
                return
            end
        end

        self:InitializeFallbackButton()
        self.initialized = true
    end

    -- The button's face (the mark and the round minimap border), shared
    -- by the fallback button and the settings preview's sample.
    function MB.BuildFace(button)
        local icon = button:CreateTexture(nil, "BACKGROUND")
        icon:SetSize(20, 20)
        icon:SetPoint("CENTER", 0, 1)
        icon:SetTexture("Interface\\AddOns\\Readycheck\\Media\\Checkmark")
        if RC.UI and RC.UI.PaintMark then RC.UI:PaintMark(icon) end
        button.icon = icon

        local overlay = button:CreateTexture(nil, "OVERLAY")
        overlay:SetSize(52, 52)
        overlay:SetPoint("TOPLEFT")
        overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        button.overlay = overlay
        return button
    end
    -- A sample for the settings preview: the same face on a plain button,
    -- the same flip on hover, no clicks, no drag, not on the minimap.
    function MB.NewSample(parent)
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(32, 32)
        b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        MB.BuildFace(b)
        AttachSpin(b)
        return b
    end

    function MB:InitializeFallbackButton()
        if self.button then return end

        local button = CreateFrame("Button", "ReadycheckMinimapButton", Minimap)
        button:SetSize(32, 32)
        button:SetFrameStrata("MEDIUM")
        button:SetFrameLevel(8)
        button:RegisterForClicks("LeftButtonDown", "RightButtonDown", "MiddleButtonDown")
        button:RegisterForDrag("LeftButton")
        button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

        MB.BuildFace(button)

        local position = RC.db.minimapButton.position or 225
        self:UpdatePosition(button, position)

        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            FillTooltip(GameTooltip)
        end)

        button:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
        end)

        button:SetScript("OnClick", function(self, buttonName)
            HandleClick(self, buttonName)
        end)

        local function dragUpdateFn(self)
            local position = MB:GetButtonPosition(self)
            MB:UpdatePosition(self, position)
        end

        button:SetScript("OnDragStart", function(self)
            if RC.db.minimapButton and RC.db.minimapButton.lock then return end
            self:LockHighlight()
            self.isDragging = true
            self:SetScript("OnUpdate", dragUpdateFn)
        end)

        button:SetScript("OnDragStop", function(self)
            self:UnlockHighlight()
            self.isDragging = false
            self:SetScript("OnUpdate", nil)
            local position = MB:GetButtonPosition(self)
            RC.db.minimapButton.position = position
        end)

        self.button = button
        AttachSpin(button)     -- after its OnEnter is set
        self.usingLibDBIcon = false

        if RC.db.minimapButton.hide then
            button:Hide()
        else
            button:Show()
        end

        RC:DebugPrint("Minimap button initialized (fallback mode - LibDBIcon not available)", "system")
    end

    function MB:UpdatePosition(button, position)
        if not button then return end
        -- 80 approximates the minimap's pixel radius so the icon sits on
        -- its rim; 225 degrees is the conventional LibDBIcon default spot.
        local angle = math.rad(position or 225)
        local x = math.cos(angle) * 80
        local y = math.sin(angle) * 80
        button:ClearAllPoints()
        button:SetPoint("CENTER", Minimap, "CENTER", x, y)
    end

    function MB:GetButtonPosition(button)
        local mx, my = Minimap:GetCenter()
        local px, py = GetCursorPosition()
        local scale = Minimap:GetEffectiveScale()
        px, py = px / scale, py / scale
        local angle = math.deg(math.atan2(py - my, px - mx))
        return angle
    end

    function MB:SetVisible(visible)
        if not RC.db or not RC.db.minimapButton then return end

        RC.db.minimapButton.hide = not visible

        if self.usingLibDBIcon and LDBI then
            local button = LDBI:GetMinimapButton("Readycheck")

            if visible then
                if not LDBI:IsRegistered("Readycheck") and self.dataObj then
                    LDBI:Register("Readycheck", self.dataObj, RC.db.minimapButton)
                end
                LDBI:Show("Readycheck")
                if button then
                    button:Show()
                end
            else
                LDBI:Hide("Readycheck")
                if button then
                    button:Hide()
                    local parent = button:GetParent()
                    if parent and parent:GetName() and parent:GetName():find("LibDBIcon") then
                        parent:Hide()
                    end
                end
            end
        elseif self.button then
            if visible then
                self.button:Show()
            else
                self.button:Hide()
            end
        end
    end

    function MB:IsVisible()
        if not RC.db or not RC.db.minimapButton then return false end
        if self.usingLibDBIcon and LDBI then
            return not RC.db.minimapButton.hide
        elseif self.button then
            return self.button:IsShown()
        end
        return false
    end

    function RC:ShowMinimapButton()
        MB:SetVisible(true)
    end

    function RC:HideMinimapButton()
        MB:SetVisible(false)
    end

    function RC:ResetMinimapButtonPosition()
        if not (RC.db and RC.db.minimapButton) then return end
        RC.db.minimapButton.minimapPos = 225
        RC.db.minimapButton.position = 225
        if MB.usingLibDBIcon and LDBI then
            if LDBI.Refresh then
                LDBI:Refresh("Readycheck", RC.db.minimapButton)
            end
        elseif MB.button then
            MB:UpdatePosition(MB.button, 225)
        end
        RC:SaveConfigurationToProfile()
    end

    -- This default-table seed duplicates the one inside MB:Initialize
    -- above; MB:Initialize() re-checks the same condition immediately
    -- below, so this block only matters if something reads RC.db.minimapButton
    -- between here and that call.
    C_Timer.After(1, function()
        if RC.db then
            if not RC.db.minimapButton then
                RC.db.minimapButton = {
                    hide = false,
                    position = 225,
                    minimapPos = 225,
                    lock = false
                }
            end

            MB:Initialize()

            if MB.usingLibDBIcon then
                RC:DebugPrint("Minimap button loaded with LibDBIcon (compatible with HidingBar)", "system")
            else
                RC:DebugPrint("Minimap button loaded (fallback mode)", "system")
            end
        end
    end)
end

InitializeMinimapButton()
