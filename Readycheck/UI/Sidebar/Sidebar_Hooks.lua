------------------------------------------------------------------------
-- Readycheck - Sidebar Shell: Legacy Hooks & Commands Page
-- Delayed hooks that redirect ConfigUI's old Show*Selection/Configuration
-- entry points into the sidebar renderers once frame.isSidebarMode is set,
-- plus the Commands page (SLASH_SECTIONS) shown as menu item "commands".
-- Hooks run via C_Timer.After so Core/ConfigUI finish defining the
-- originals first; guard flags stop double-hooking on /reload.
------------------------------------------------------------------------
local RC = _G.Readycheck
-- HOOK INTO SAVE/PROFILE FUNCTIONS TO REFRESH SIDEBAR
C_Timer.After(1, function()
    if not RC then return end

    -- Guard flag: prevents re-wrapping SaveConfigurationToProfile again if this file reloads.
    if RC.SaveConfigurationToProfile and not RC._sidebarHookedSave then
        RC._sidebarHookedSave = true
        local originalSaveConfig = RC.SaveConfigurationToProfile
        RC.SaveConfigurationToProfile = function(self, ...)
            local result = originalSaveConfig(self, ...)
            C_Timer.After(0.1, function()
                if RC and RC.RefreshSidebarProfiles and RC.sidebarConfigFrame and RC.sidebarConfigFrame:IsShown() then
                    RC:RefreshSidebarProfiles()
                end
            end)
            return result
        end
        if RC.DebugPrint then
            RC:DebugPrint("Sidebar: Hooked SaveConfigurationToProfile", "system")
        end
    end

    if RC.SetActiveRaidProfile and not RC._sidebarHookedProfile then
        RC._sidebarHookedProfile = true
        local originalSetActiveRaidProfile = RC.SetActiveRaidProfile
        RC.SetActiveRaidProfile = function(self, ...)
            local result = originalSetActiveRaidProfile(self, ...)
            C_Timer.After(0.1, function()
                if RC and RC.RefreshSidebarProfiles and RC.sidebarConfigFrame and RC.sidebarConfigFrame:IsShown() then
                    RC:RefreshSidebarProfiles()
                end
            end)
            return result
        end
        if RC.DebugPrint then
            RC:DebugPrint("Sidebar: Hooked SetActiveRaidProfile", "system")
        end
    end
end)

C_Timer.After(0.5, function()
    local RC = _G.Readycheck
    if not RC then return end

    local originalShowEncounterSelection = RC.ShowEncounterSelection
    function RC:ShowEncounterSelection(frame)
        if frame and frame.isSidebarMode then
            local cs = frame.configState
            if cs and cs.selectedRaid and self.OpenRaidBossPage then
                self:OpenRaidBossPage(frame, cs.selectedRaid)
            else
                self:ShowSidebarWelcome(frame)
            end
            return
        end
        if originalShowEncounterSelection then
            return originalShowEncounterSelection(self, frame)
        end
    end

    local originalShowTrashSectionConfiguration = RC.ShowTrashSectionConfiguration
    function RC:ShowTrashSectionConfiguration(frame)
        if frame and frame.isSidebarMode then
            local raidName = frame.configState and frame.configState.selectedRaid
            if raidName then
                local sectionName = frame.configState.selectedTrashSection
                if not frame.bulkTrashState then
                    frame.bulkTrashState = { selectedMobs = {} }
                end
                if frame.bulkTrashState.lastRaid and frame.bulkTrashState.lastRaid ~= raidName then
                    frame.bulkTrashState.selectedMobs = {}
                end
                frame.bulkTrashState.lastRaid = raidName
                if frame.bulkTrashState.selectedQuarter ~= sectionName then
                    frame.bulkTrashState.currentAbility = nil
                end
                frame.bulkTrashState.selectedQuarter = sectionName
                self:ShowSidebarBulkTrashConfig(frame, raidName)
                return
            end
        end
        if originalShowTrashSectionConfiguration then
            return originalShowTrashSectionConfiguration(self, frame)
        end
    end

    local originalShowAbilitySelection = RC.ShowAbilitySelection
    function RC:ShowAbilitySelection(frame)
        if frame and frame.isSidebarMode then
            local raidName = frame.configState and frame.configState.selectedRaid
            local encounterName = frame.configState and frame.configState.selectedEncounter
            local encounterType = frame.configState and frame.configState.selectedEncounterType
            if raidName and encounterName then
                local raidSettings = self:GetActiveRaidProfile(raidName)
                if raidSettings then
                    self:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType or "boss", raidSettings)
                    return
                end
            end
        end
        if originalShowAbilitySelection then
            return originalShowAbilitySelection(self, frame)
        end
    end

    local originalShowAbilityConfiguration = RC.ShowAbilityConfiguration
    function RC:ShowAbilityConfiguration(frame)
        if frame and frame.isSidebarMode then
            local raidName = frame.configState and frame.configState.selectedRaid
            local encounterName = frame.configState and frame.configState.selectedEncounter
            local encounterType = frame.configState and frame.configState.selectedEncounterType
            local abilityKey = frame.configState and frame.configState.selectedAbility
            if raidName and encounterName and abilityKey then
                local raidSettings = self:GetActiveRaidProfile(raidName)
                if raidSettings then
                    self:ShowSidebarAbilityConfig(frame, raidName, encounterName, encounterType or "boss", raidSettings, abilityKey)
                    return
                end
            end
        end
        if originalShowAbilityConfiguration then
            return originalShowAbilityConfiguration(self, frame)
        end
    end

    local originalShowBulkTrashConfiguration = RC.ShowBulkTrashConfiguration
    function RC:ShowBulkTrashConfiguration(frame)
        if frame and frame.isSidebarMode then
            local raidName = frame.configState and frame.configState.selectedRaid
            if raidName then
                self:ShowSidebarBulkTrashConfig(frame, raidName)
                return
            end
        end
        if originalShowBulkTrashConfiguration then
            return originalShowBulkTrashConfiguration(self, frame)
        end
    end

    local originalShowBulkAbilityConfiguration = RC.ShowBulkAbilityConfiguration
    function RC:ShowBulkAbilityConfiguration(frame)
        if frame and frame.isSidebarMode then
            local raidName = frame.configState and frame.configState.selectedRaid
            local abilityKey = frame.bulkTrashState and frame.bulkTrashState.currentAbility
            if raidName and abilityKey then
                self:ShowSidebarBulkAbilityConfig(frame, raidName, abilityKey)
                return
            end
        end
        if originalShowBulkAbilityConfiguration then
            return originalShowBulkAbilityConfiguration(self, frame)
        end
    end

    if RC.DebugPrint then
        RC:DebugPrint("Sidebar: Installed ConfigUI function overrides", "system")
    end

    -- Fallback error page shown only if UI\Pages\SidebarCustomReminders.lua failed to load.
    if not RC.ShowSidebarCustomReminders then
        function RC:ShowSidebarCustomReminders(frame)
            if not frame or not frame.scrollChild then return end
            local sc = frame.scrollChild
            for _, c in pairs({sc:GetChildren()}) do c:Hide(); c:SetParent(nil) end
            for _, r in pairs({sc:GetRegions()}) do r:Hide() end
            local lbl = sc:CreateFontString(nil, "OVERLAY")
            if RC.ApplyCustomFont then RC:ApplyCustomFont(lbl, 11, "") end
            lbl:SetPoint("CENTER")
            lbl:SetText(RCL["Custom Reminders failed to load. Check that UI\\Pages\\SidebarCustomReminders.lua is in your addon folder."])
            local gt = RC.GetColor and RC:GetColor("text","disabled") or {r=0.6,g=0.6,b=0.6}
            lbl:SetTextColor(gt.r, gt.g, gt.b, 1)
        end
    end

    local SLASH_SECTIONS = {
        {
            title = RCL["General"],
            rows = {
                { cmd = "/rc",                          desc = RCL["Open settings"] },
                { cmd = "/rc help",                     desc = RCL["Open this page"] },
                { cmd = "/rc changelog",                desc = RCL["Show what's new"] },
                { cmd = "/rc tutorial",                 desc = RCL["Take a quick tour of this window"] },
                { cmd = "/rc setup",                    desc = RCL["Run the setup wizard again"] },
                { cmd = "/rc test",                     desc = RCL["Fire a test reminder animation"] },
                { cmd = "/rc clear",                    desc = RCL["Dismiss all active alerts"] },
                { cmd = "/rc minimap",                  desc = RCL["Toggle the minimap button (/rc show, /rc hide, /rc reset position)"] },
                { cmd = "/rc move | /rc moveui | /rc unlock", desc = RCL["Unlock frames for repositioning"] },
                { cmd = "/rc lock",                     desc = RCL["Lock all frames in place"] },
                { cmd = "/rc mesh",                     desc = RCL["Print mesh sync status"] },
                { cmd = "/rc flavor",                   desc = RCL["Show which game version Readycheck runs as and what it switches off there"] },
            },
        },
        {
            title = RCL["Gear & hotswap"],
            rows = {
                { cmd = "/rc equip(Item,slot)",         desc = RCL["Equip an item to a gear slot - queues it if you are in combat. Great in macros: /rc equip(Kiss of the Spider,13). Slots 13/14 are trinkets."] },
                { cmd = "/rc gearset <name>  |  /rc gs", desc = RCL["Equip a saved gear set by name - works in macros"] },
                { cmd = "/rc hotswap  |  /rc hs",         desc = RCL["Hotswap controls; 'flask' / 'bloodrage' fire those swaps directly"] },
            },
        },
        {
            title = RCL["Combat & encounters"],
            rows = {
                { cmd = "/rc sim <raid> <boss>",        desc = RCL["Simulate a boss encounter for testing"] },
                { cmd = "/rc stopsim",                  desc = RCL["Stop active simulation"] },
                { cmd = "/rc gearsim [boss]",           desc = RCL["Simulate a gear-swap for a boss to test swap timing"] },
                { cmd = "/rc encounter start <boss>",   desc = RCL["Manually trigger encounter start"] },
                { cmd = "/rc encounter end [kill]",     desc = RCL["Manually trigger encounter end (add 'kill' for a kill)"] },
                { cmd = "/rc encounter status",         desc = RCL["Show current encounter state"] },
                { cmd = "/rc routever",                 desc = RCL["Print the RaidRoute build stamp"] },
                { cmd = "/rc routedebug",               desc = RCL["Toggle the route debug overlay"] },
            },
        },
        {
            title = RCL["ML predictions & TTK"],
            rows = {
                { cmd = "/rc ttk",                      desc = RCL["Show TTK summary for all bosses"] },
                { cmd = "/rc ttk clear <boss>",         desc = RCL["Clear history for a specific boss"] },
                { cmd = "/rc ttk clearall confirm",     desc = RCL["Wipe all fight history"] },
                { cmd = "/rc fixttk",                   desc = RCL["Flag suspect kills from add-phase bosses"] },
                { cmd = "/rc fixhistory",               desc = RCL["Migrate and deduplicate fight history data"] },
                { cmd = "/rc summary",                  desc = RCL["Print the fight-data summary for every boss"] },
                { cmd = "/rc dmfdump [boss]",           desc = RCL["List a boss's kill-history buckets with DMF/profile stamps"] },
            },
        },
        {
            title = RCL["Consumables"],
            rows = {
                { cmd = "/rc consumreport  |  /rc cr",  desc = RCL["Print consumables report to chat"] },
                { cmd = "/rc consumcheck  |  /rc cc",   desc = RCL["Open consumables checker"] },
                { cmd = "/cc",                          desc = RCL["Standalone consumables check shortcut"] },
            },
        },
        {
            title = RCL["Voice (TTS)"],
            rows = {
                { cmd = "/rc ttsvol [0-100]",           desc = RCL["Show or set the consumable voice volume"] },
                { cmd = "/rc ttstest",                  desc = RCL["Play the TTS test matrix"] },
                { cmd = "/rc ttsloop",                  desc = RCL["Loop a TTS test line"] },
                { cmd = "/rc ttstrace",                 desc = RCL["Toggle printing the source module of every spoken line"] },
            },
        },
        {
            title = RCL["Reminders"],
            rows = {
                { cmd = "/rc reminders",                desc = RCL["Open custom reminders panel"] },
                { cmd = "/rc testreminder",             desc = RCL["Fire a test custom reminder"] },
                { cmd = "/rc battleshout  |  /rc bs",   desc = RCL["Toggle battle shout party tracker"] },
            },
        },
        {
            title = RCL["World buffs & cross-faction"],
            rows = {
                { cmd = "/wb  |  /rc wb",                desc = RCL["Open the World Buffs mini-board"] },
                { cmd = "/rc crossfaction  |  /rc xfaction", desc = RCL["Toggle cross-faction (Battle.net) world-buff sync"] },
                { cmd = "/rc xfpeer <BattleTag>",       desc = RCL["Add a cross-faction sync peer; bare command lists them"] },
                { cmd = "/rc xfpeerclear",              desc = RCL["Clear all cross-faction sync peers"] },
                { cmd = "/rc wbclear",                  desc = RCL["Clear world-buff removal tombstones (un-hide removed toons)"] },
                { cmd = "/rc wbself",                   desc = RCL["Print what this client parses from its own boon/buffs right now"] },
            },
        },
        {
            title = RCL["Polarity mode"],
            rows = {
                { cmd = "/rc polarity on",              desc = RCL["Enable Polarity Mode (Sapphiron)"] },
                { cmd = "/rc polarity off",             desc = RCL["Disable Polarity Mode"] },
                { cmd = "/rc polarity test [seconds]",  desc = RCL["Test the whole sequence: the Thaddius timer, then a pull timer on Sapphiron"] },
                { cmd = "/rc polarity pull [seconds]",  desc = RCL["Test only the pull timer on Sapphiron"] },
                { cmd = "/rc polarity thad [seconds]",  desc = RCL["Test the timer that starts when Thaddius dies"] },
                { cmd = "/rc polarity",                 desc = RCL["Show current Polarity Mode status"] },
            },
        },
        {
            title = RCL["Trinkets"],
            rows = {
                { cmd = "/rc scantrinket",              desc = RCL["Scan a single targeted trinket"] },
                { cmd = "/rc scantrinkets  |  /rc scanall", desc = RCL["Scan all trinkets in bags"] },
                { cmd = "/rc scanbuff",                 desc = RCL["Scan a buff on the player"] },
                { cmd = "/rc dumptrinkets",             desc = RCL["Dump trinket data to chat"] },
                { cmd = "/rc trinketlog",               desc = RCL["Show recent trinket swap log"] },
            },
        },
        {
            title = RCL["Profiler"],
            rows = {
                { cmd = "/rc profiler",                 desc = RCL["Open the addon performance profiler"] },
                { cmd = "/rc profilereset",             desc = RCL["Reset profiler stats before a pull (lightweight, no lag)"] },
                { cmd = "/rc profiledump",              desc = RCL["Print the heaviest tickers and modules after a pull"] },
                { cmd = "/rc spikes [on|off|clear]",    desc = RCL["Show recent frametime spikes; 'threshold <ms>' sets the cutoff"] },
            },
        },
        {
            title = RCL["Debug"],
            rows = {
                { cmd = "/rc debugcats",                desc = RCL["List all debug categories"], showCatPopup = true },
                { cmd = "/rc debugcat <category>",      desc = RCL["Toggle a specific debug category on/off"] },
                { cmd = "/rc debugall on|off",          desc = RCL["Enable or disable all debug output at once"] },
            },
        },
        {
            title = RCL["Profile & data"],
            rows = {
                { cmd = "/rc cleanup",                  desc = RCL["Clean up stale data in saved variables"] },
                { cmd = "/rc resetprofile confirm",     desc = RCL["Reset current character profile to defaults"] },
                { cmd = "/rc raidprofdump",             desc = RCL["Print every raid's profiles and active pointer"] },
                { cmd = "/rc notesdump",                desc = RCL["Print every stored boss/trash note key (nothing modified)"] },
                { cmd = "/rc notesadopt <old profile>", desc = RCL["Copy notes saved under an old profile name into the active profiles"] },
                { cmd = "/rc meshhash",                 desc = RCL["Print per-category mesh hashes - run on two toons to compare"] },
            },
        },
    }

    local function GetDebugCatPopup()
        if RC._debugCatPopup then return RC._debugCatPopup end

        local CATS = {
            { header = RCL["Core"],              cats = {"core", "config", "combat", "system", "general"} },
            { header = RCL["Reminders"],         cats = {"reminder", "trigger", "dismissal"} },
            { header = RCL["Audio / Visual"],    cats = {"tts", "animation"} },
            { header = RCL["Gear & Items"],      cats = {"gear", "trinket", "hotswap", "itemrack", "items", "consumables"} },
            { header = RCL["Combat Analytics"],  cats = {"ttk", "execute", "charstats", "cooldown", "timer", "abilities", "swing"} },
            { header = RCL["Misc"],              cats = {"buff", "polarity", "profile", "test"} },
        }

        local popup = CreateFrame("Frame", nil, UIParent)
        popup:SetFrameStrata("TOOLTIP")
        popup:SetToplevel(true)
        popup:EnableMouse(true)
        popup:Hide()

        -- Flat tooltip-style popup: WHITE8X8 window fill, 1px black ring.
        local bg = popup:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        local winBg = RC:GetColor("ui", "windowBackground")
        bg:SetVertexColor(winBg.r, winBg.g, winBg.b, 0.97)
        RC.UI:CreateSimpleBorder(popup)

        local gold   = RC:GetColor("text", "gold")
        local disCol = RC:GetColor("text", "gray")

        local PAD = 10
        local yOff = -PAD
        local maxW = 0

        for _, group in ipairs(CATS) do
            local hdr = popup:CreateFontString(nil, "OVERLAY")
            RC:ApplyCustomFont(hdr, 11, "OUTLINE")
            hdr:SetTextColor(gold.r, gold.g, gold.b, 1)
            hdr:SetText(group.header)
            hdr:SetJustifyH("LEFT")
            hdr:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD, yOff)
            if RC.trackedFonts then tinsert(RC.trackedFonts, hdr) end
            yOff = yOff - 16

            local catLine = table.concat(group.cats, "   ")
            local cfs = popup:CreateFontString(nil, "OVERLAY")
            RC:ApplyCustomFont(cfs, 10, "OUTLINE")
            cfs:SetTextColor(disCol.r, disCol.g, disCol.b, 1)
            cfs:SetText(catLine)
            cfs:SetJustifyH("LEFT")
            cfs:SetPoint("TOPLEFT", popup, "TOPLEFT", PAD + 8, yOff)
            if RC.trackedFonts then tinsert(RC.trackedFonts, cfs) end
            cfs:SetWidth(400)
            local lineW = cfs:GetStringWidth() + PAD * 2 + 8
            if lineW > maxW then maxW = lineW end
            yOff = yOff - 16
        end

        yOff = yOff - PAD
        popup:SetSize(math.max(maxW, 200), math.abs(yOff))

        -- Click-toggled and parented to UIParent, so nothing else hides it:
        -- without this ESC closes the settings window and leaves the popup
        -- floating. Unnamed, so this takes the OnKeyDown path and swallows
        -- the ESC - the popup closes first, the window behind stays open.
        RC.UI:RegisterEscapeClose(popup)

        RC._debugCatPopup = popup
        return popup
    end

    -- Registered as menu item "commands" (panel = "ShowSidebarCommands") in Sidebar_Base.lua's
    -- MenuStructure. Clears content itself, then reports final height via UpdateSidebarScrollbar.
    function RC:ShowSidebarCommands(frame)
        self:ClearSidebarContent(self.sidebarConfigFrame)
        local parent = frame.scrollChild
        local yPos   = -15

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Commands"],
            RCL["All /rc slash commands at a glance"], "Interface\\Icons\\INV_Misc_Note_01")
        yPos = newY

        local cmdColor  = RC:GetColor("ui", "accentGold")
        local descColor = RC:GetColor("text", "secondary") or { r=0.75, g=0.75, b=0.75 }

        -- Hide command groups whose owning module isn't loaded this session.
        local visibleSections = {}
        for _, s in ipairs(SLASH_SECTIONS) do
            local hide =
                -- RC.Profiler always exists (Core_Stubs no-op stub); only the
                -- real one from Readycheck_Debug registers these commands.
                ((s.title == "Profiler" or s.title == "Debug")
                    and (not RC.Profiler or RC.Profiler.isStub))
                or (s.title == "World buffs & cross-faction" and not RC.WorldBuffs)
                or (s.title == "Polarity mode" and not RC.PolarityReset)
            if not hide then
                table.insert(visibleSections, s)
            end
        end
        for _, section in ipairs(visibleSections) do
            local card = self:CreateSettingsCard(parent, yPos, section.title)
            local cardY = -32
            local CMD_W = 210

            for _, row in ipairs(section.rows) do
                local cmdFS = self:CreateFontString(card, "OVERLAY", nil, 11)
                cmdFS:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
                cmdFS:SetWidth(CMD_W)
                cmdFS:SetText(row.cmd)
                cmdFS:SetTextColor(cmdColor.r, cmdColor.g, cmdColor.b, 1)
                cmdFS:SetJustifyH("LEFT")

                local descFS = self:CreateFontString(card, "OVERLAY", nil, 11)
                descFS:SetPoint("TOPLEFT", card, "TOPLEFT", CMD_W + 20, cardY)
                descFS:SetWidth(card:GetWidth() - CMD_W - 34)
                descFS:SetText(row.desc)
                descFS:SetTextColor(descColor.r, descColor.g, descColor.b, 1)
                descFS:SetJustifyH("LEFT")

                -- a long meaning wraps: the next command goes under all of it
                cardY = cardY - math.max(22, math.ceil(descFS:GetStringHeight() or 12) + 8)

                if row.showCatPopup then
                    local btn = CreateFrame("Button", nil, card)
                    btn:SetSize(110, 16)
                    btn:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)

                    local dimCol = RC:GetColor("text", "disabled") or {r=0.55,g=0.55,b=0.55}
                    local hovCol = RC:GetColor("ui", "accentGold")
                    local arrCol = RC:GetColor("scrollbar", "arrow") or hovCol

                    local arrowTex = btn:CreateTexture(nil, "ARTWORK")
                    arrowTex:SetSize(8, 8)
                    arrowTex:SetPoint("LEFT", btn, "LEFT", 0, 0)
                    arrowTex:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrow")
                    arrowTex:SetVertexColor(arrCol.r, arrCol.g, arrCol.b, 1)
                    arrowTex:SetRotation(math.rad(-90))
                    btn.arrowTex = arrowTex

                    local btnFS = btn:CreateFontString(nil, "OVERLAY")
                    RC:ApplyCustomFont(btnFS, 10, "OUTLINE")
                    btnFS:SetPoint("LEFT", arrowTex, "RIGHT", 4, 0)
                    btnFS:SetText(RCL["view categories"])
                    btnFS:SetTextColor(dimCol.r, dimCol.g, dimCol.b, 1)
                    if RC.trackedFonts then tinsert(RC.trackedFonts, btnFS) end
                    btn.label = btnFS

                    btn:SetScript("OnEnter", function(self)
                        self.label:SetTextColor(hovCol.r, hovCol.g, hovCol.b, 1)
                        self.arrowTex:SetVertexColor(hovCol.r, hovCol.g, hovCol.b, 1)
                    end)
                    btn:SetScript("OnLeave", function(self)
                        self.label:SetTextColor(dimCol.r, dimCol.g, dimCol.b, 1)
                        self.arrowTex:SetVertexColor(arrCol.r, arrCol.g, arrCol.b, 1)
                    end)
                    btn:SetScript("OnClick", function(self)
                        local pop = GetDebugCatPopup()
                        if pop:IsShown() and pop._anchor == self then
                            pop:Hide()
                            pop._anchor = nil
                            self.arrowTex:SetRotation(math.rad(-90))
                        else
                            pop:ClearAllPoints()
                            pop:SetPoint("BOTTOMLEFT", self, "TOPLEFT", 0, 4)
                            pop._anchor = self
                            pop:Show()
                            self.arrowTex:SetRotation(0)
                        end
                    end)

                    cardY = cardY - 20
                end
            end

            card:SetHeight(math.abs(cardY) + 14)
            yPos = yPos - card:GetHeight() - 10
        end

        if self.UpdateSidebarScrollbar then
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
        end
    end
end)

