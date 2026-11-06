------------------------------------------------------------------------
-- Readycheck - Sidebar Navigation
-- Builds and maintains the settings sidebar: category/child buttons,
-- search-result buttons, selection state, and the scroll-preserving
-- content-clear/restore pair used when a click should not jerk the view
-- back to the top. Does not read or write raid profile data directly;
-- OpenRaidBossPage just picks which boss page to land on.
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
    -- Nav row, ZacUI look: 28 tall, flat sidebar.buttonNormal fill with a
    -- 1px black ring, a 3px sidebar.selectionIndicator bar down the left
    -- edge shown only while selected, selected fill sidebar.buttonSelected
    -- with text.menuSelected text, hover fill sidebar.buttonHover.
    -- Category rows carry a small gold chevron at the right (down when
    -- expanded, right when collapsed) and text.menuCategory text.
    --
    -- Deliberately NOT a BackdropTemplate frame: FontSystem's
    -- UpdateAllTextures re-skins any sidebar button that has SetBackdrop
    -- with the user's statusbar gradient, and nav furniture stays flat.
    local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
    local TEX_ARROW  = "Interface\\AddOns\\Readycheck\\Media\\arrow"
    local TEX_ARROWL = "Interface\\AddOns\\Readycheck\\Media\\arrowLeft"

    function RC:CreateSidebarButton(parent, menuItem, yOffset, isSubmenu)
        local isRaid = menuItem.raidKey ~= nil
        local isCategory = (menuItem.category and not isSubmenu) and true or false
        local buttonHeight = isRaid and RC.SIDEBAR.RAID_BUTTON_HEIGHT or RC.SIDEBAR.BUTTON_HEIGHT

        local btnNormal = RC.SIDEBAR:GetButtonNormal()
        local txtNormal = isCategory and RC:GetColor("text", "menuCategory") or RC.SIDEBAR:GetTextNormal()
        local accentCol = RC.SIDEBAR:GetAccentColor()
        local borderCol = RC:GetColor("ui", "borderNormal")

        local button = CreateFrame("Button", nil, parent)
        button:SetSize(RC.SIDEBAR.WIDTH - (isSubmenu and 28 or 22), buttonHeight)
        button:SetPoint("TOPLEFT", parent, "TOPLEFT", isSubmenu and 10 or 4, yOffset)

        button.bg = button:CreateTexture(nil, "BACKGROUND")
        button.bg:SetAllPoints()
        button.bg:SetTexture(FLAT)
        button.bg:SetVertexColor(btnNormal.r, btnNormal.g, btnNormal.b, btnNormal.a or 1)
        button.border = RC.UI:CreateSimpleBorder(button)
        RC.UI:UpdateBorderColor(button.border, borderCol, 1)

        button.selectIndicator = button:CreateTexture(nil, "ARTWORK")
        button.selectIndicator:SetWidth(3)
        button.selectIndicator:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        button.selectIndicator:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 1, 1)
        button.selectIndicator:SetTexture(FLAT)
        button.selectIndicator:SetVertexColor(accentCol.r, accentCol.g, accentCol.b, accentCol.a or 1)
        button.selectIndicator:Hide()

        if menuItem.icon and isSubmenu then
            button.icon = button:CreateTexture(nil, "ARTWORK")
            button.icon:SetSize(16, 16)
            button.icon:SetPoint("LEFT", button, "LEFT", isSubmenu and 7 or 9, isRaid and 5 or 0)
            button.icon:SetTexture(menuItem.icon)
            button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end

        button.text = self:CreateFontString(button, "OVERLAY", nil, isSubmenu and 11 or 12)
        button.text:SetPoint("LEFT", button.icon or button, button.icon and "RIGHT" or "LEFT", button.icon and 6 or 9, isRaid and 8 or 0)
        button.text:SetJustifyH("LEFT")
        button.text:SetWordWrap(false)
        if not isRaid then
            button.text:SetPoint("RIGHT", button, "RIGHT", menuItem.id == "mesh_sync" and -18 or -6, 0)
        end
        button.text:SetText(menuItem.name)
        button.text:SetTextColor(txtNormal.r, txtNormal.g, txtNormal.b)

        if isCategory then
            local chev = button:CreateTexture(nil, "ARTWORK")
            chev:SetSize(8, 8)
            chev:SetPoint("RIGHT", button, "RIGHT", -8, 0)
            chev:SetTexture(TEX_ARROW)
            local gold = RC:GetColor("ui", "accentGold")
            chev:SetVertexColor(gold.r, gold.g, gold.b, 0.65)
            button.chevron = chev
        end

        if menuItem.id == "mesh_sync" then
            local MS = RC.MeshSync
            local msOn = MS and MS:IsEnabled()
            local dot = CreateFrame("Frame", nil, button)
            dot:SetSize(6, 6)
            dot:SetPoint("RIGHT", button, "RIGHT", -6, 0)
            local dotFill = dot:CreateTexture(nil, "ARTWORK")
            dotFill:SetAllPoints()
            dotFill:SetTexture(FLAT)
            local dotCol = msOn and RC:GetColor("ui", "configured") or RC:GetColor("text", "gray")
            dotFill:SetVertexColor(dotCol.r, dotCol.g, dotCol.b, 1)
            dot.bg = dotFill
            dot.border = RC.UI:CreateSimpleBorder(dot)
            button.meshDot = dot
        end

        if isRaid then
            button.text:SetPoint("RIGHT", button, "RIGHT", -8, 10)

            button.profileText = self:CreateFontString(button, "OVERLAY", nil, 9)
            button.profileText:SetPoint("TOPLEFT", button.text, "BOTTOMLEFT", 0, -1)
            button.profileText:SetPoint("RIGHT", button, "RIGHT", -8, 0)
            button.profileText:SetJustifyH("LEFT")

            button.countText = self:CreateFontString(button, "OVERLAY", nil, 9)
            button.countText:SetPoint("TOPLEFT", button.profileText, "BOTTOMLEFT", 0, -1)
            button.countText:SetPoint("RIGHT", button, "RIGHT", -8, 0)
            button.countText:SetJustifyH("LEFT")

            local profileName = "Default"
            if self.GetActiveRaidProfile then
                local _, name = self:GetActiveRaidProfile(menuItem.raidKey)
                profileName = name or "Default"
            end

            local bossCount, trashCount = self:GetRaidConfigCounts(menuItem.raidKey)
            local greenCol = RC:GetColor("text", "green")
            local dimCol   = RC:GetColor("text", "gray")
            local offNote = self.FeatureOffForPage and self:FeatureOffForPage(menuItem)
                and self:FeatureOffNote(self:FeatureOffForPage(menuItem))

            button.profileText:SetText(RCL["Profile: "] .. profileName)
            if offNote then
                -- this game version does not run the Era raids: say so
                button.profileText:SetTextColor(dimCol.r, dimCol.g, dimCol.b)
                button.countText:SetText(offNote)
                button.countText:SetTextColor(dimCol.r, dimCol.g, dimCol.b)
            elseif bossCount > 0 or trashCount > 0 then
                button.profileText:SetTextColor(greenCol.r, greenCol.g, greenCol.b)
                button.countText:SetText(bossCount .. RCL[" Bosses  "] .. trashCount .. RCL[" Trash"])
                button.countText:SetTextColor(greenCol.r, greenCol.g, greenCol.b)
            else
                button.profileText:SetTextColor(dimCol.r, dimCol.g, dimCol.b)
                button.countText:SetText(RCL["Not Configured"])
                button.countText:SetTextColor(dimCol.r, dimCol.g, dimCol.b)
            end

            button.raidKey = menuItem.raidKey
        else
            button.text:SetPoint("RIGHT", button, "RIGHT", -20, 0)
        end

        button.menuItem = menuItem
        button.isSubmenu = isSubmenu
        button.isCategory = isCategory
        button.buttonHeight = buttonHeight

        button.isSelected = false
        RC.UI:AttachHover(button, btnNormal, RC.SIDEBAR:GetButtonHover(), {
            skipWhen = "isSelected",
            onEnter = function(self)
                if self.chevron then
                    local gold = RC:GetColor("ui", "accentGold")
                    self.chevron:SetVertexColor(gold.r, gold.g, gold.b, 1)
                end
            end,
            onLeave = function(self)
                if self.chevron then
                    local gold = RC:GetColor("ui", "accentGold")
                    self.chevron:SetVertexColor(gold.r, gold.g, gold.b, 0.65)
                end
            end,
        })

        return button
    end

    function RC:SetSidebarButtonState(button, selected, expanded)
        if not button then return end

        button.isSelected = selected

        local btnNormal = RC.SIDEBAR:GetButtonNormal()
        local btnSelected = RC.SIDEBAR:GetButtonSelected()
        local txtNormal = button.isCategory and RC:GetColor("text", "menuCategory") or RC.SIDEBAR:GetTextNormal()
        local txtSelected = RC.SIDEBAR:GetTextSelected()
        local accentCol = RC.SIDEBAR:GetAccentColor()
        local borderCol = RC:GetColor("ui", "borderNormal")

        -- Colours re-read here so a theme change lands on the next repaint.
        button.normBg = btnNormal
        button.hoverBg = RC.SIDEBAR:GetButtonHover()
        RC.UI:UpdateBorderColor(button.border, borderCol, 1)
        button.selectIndicator:SetVertexColor(accentCol.r, accentCol.g, accentCol.b, accentCol.a or 1)

        -- A folded group that holds the open page keeps a dimmed bar down
        -- its edge, so the page you are on is never lost from sight.
        local holdsPage = false
        if button.isCategory and not selected and not expanded and button.menuItem and button.menuItem.children then
            local cur = RC.SidebarState and RC.SidebarState.selectedItem
            for _, child in ipairs(button.menuItem.children) do
                if cur ~= nil and child.id == cur then holdsPage = true break end
            end
        end
        button.holdsPage = holdsPage

        if selected then
            button.bg:SetVertexColor(btnSelected.r, btnSelected.g, btnSelected.b, btnSelected.a or 1)
            button.text:SetTextColor(txtSelected.r, txtSelected.g, txtSelected.b)
            button.selectIndicator:Show()
        else
            button.bg:SetVertexColor(btnNormal.r, btnNormal.g, btnNormal.b, btnNormal.a or 1)
            button.text:SetTextColor(txtNormal.r, txtNormal.g, txtNormal.b)
            if holdsPage then
                button.selectIndicator:SetVertexColor(accentCol.r, accentCol.g, accentCol.b, 0.5)
                button.selectIndicator:Show()
            else
                button.selectIndicator:Hide()
            end
        end

        -- Down when open, right when closed. The addon ships a down arrow
        -- and a left arrow; the right-pointing one is the left arrow
        -- mirrored on X, so the texcoord is reset on the open branch.
        if button.chevron then
            if expanded then
                button.chevron:SetTexture(TEX_ARROW)
                button.chevron:SetTexCoord(0, 1, 0, 1)
            else
                button.chevron:SetTexture(TEX_ARROWL)
                button.chevron:SetTexCoord(1, 0, 0, 1)
            end
        end

    end

    -- ONE ANSWER TO "DOES THIS SIDEBAR ITEM SHOW FOR THIS CHARACTER RIGHT
    -- NOW". The sidebar, the minimap button's menu and anything else that
    -- lists pages all ask here, so a page gated off by class, by a missing
    -- Readycheck addon, or by its own switch is gated off everywhere at
    -- once. Cheap enough to call per item: a handful of table lookups.
    function RC:SidebarItemVisible(item)
        if not item then return false end
        local isWarrior = self.isWarrior
        local nonWarEnabled = (self.db and self.db.nonWarriorEnabled) or {}
        local _isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
        local hasSystems  = true
        local hasFeatures = not _isLoaded or _isLoaded("Readycheck_Features")
        local hasGear     = not _isLoaded or _isLoaded("Readycheck_Gear")
        local hasReminders   = not _isLoaded or _isLoaded("Readycheck_Reminders")
        local hasConsumables = not _isLoaded or _isLoaded("Readycheck_Consumables")
        local hasWorld       = not _isLoaded or _isLoaded("Readycheck_WorldTools")
        -- Keys here must match MenuStructure item ids exactly; an id with no
        -- entry defaults to visible (LAYER_OK[item.id] == false is the only
        -- hiding condition below), so a typo'd key silently does nothing.
        --
        -- Gate on whichever addon owns the FEATURE, not the page. Several
        -- pages live in the main addon while the thing they configure does
        -- not (equipment_reminder, smart_macros, boss_notes, the gear pages),
        -- and a config page for an absent feature is worse than no page.
        local LAYER_OK = {
            mesh_sync = hasSystems, remote_raid_cfg = hasSystems,
            spec_detection = hasSystems, stats_bar = hasSystems,
            buff_pushoff = hasSystems, raids = hasSystems,
            mc = hasSystems, bwl = hasSystems, aq40 = hasSystems,
            naxx = hasSystems,
            -- Readycheck_Reminders: the popup, TTK and the raid route
            reminder_settings = hasReminders, battle_shout = hasReminders,
            boon_reminder = hasReminders, custom_reminders = hasReminders,
            equipment_reminder = hasReminders, execute = hasReminders,
            ttk_display = hasReminders,
            -- Readycheck_Consumables: the four bars and the checker
            consumables = hasConsumables, consumables_checker = hasConsumables,
            consumables_bar = hasConsumables, potions_bar = hasConsumables,
            weapons_bar = hasConsumables, trinket_bar = hasConsumables,
            -- Readycheck_Features
            nameplate_auras = hasFeatures, smart_macros = hasFeatures,
            boss_notes = hasFeatures,
            -- Readycheck_Gear. trinket_bar is NOT here: the trinket *menu*
            -- is a consumable bar, only trinket *swapping* is gear.
            gear_manager = hasGear, speed_swaps = hasGear,
            trinkets = hasGear, hotswap = hasGear,
            repair_reminder = hasGear,
            -- Readycheck_WorldTools
            world_buffs = hasWorld,
        }
        -- a page this game version does not run stays listed and shows
        -- why (Core_Flavor), even when its addon is not loaded
        local flavorOff = self.FeatureOffForPage and self:FeatureOffForPage(item)
        if item.id and LAYER_OK[item.id] == false and not flavorOff then
            return false
        end
        local p = item.panel
        if (p == "ShowSidebarProfiler"
            or p == "ShowSidebarWorldBuffs"
            or p == "ShowSidebarBoonReminderConfig"
            or p == "ShowSidebarSmartMacro")
           and not RC[p] and not flavorOff then
            return false
        end
        -- class: a warrior-only item shows for warriors, for a character
        -- that opted into it, or for a category with an opted-in child
        if item.warriorOnly and not isWarrior and nonWarEnabled[item.id] ~= true then
            local optedIn = false
            if item.children then
                for _, child in ipairs(item.children) do
                    if child.warriorOnly and nonWarEnabled[child.id] == true then
                        optedIn = true
                        break
                    end
                end
            end
            if not optedIn then return false end
        end
        if item.sidebarVisibleKey and self.db and self.db.sidebarNav
           and self.db.sidebarNav[item.sidebarVisibleKey] == false then
            return false
        end
        if item.enabledKey and self.db then
            local tbl = self.db[item.enabledKey[1]]
            if not (tbl and tbl[item.enabledKey[2]]) then return false end
        end
        return true
    end

    function RC:BuildSidebar(frame, isInitialBuild)
        if not frame.sidebar then return end

        local listHost = frame.sidebar.scrollChild or frame.sidebar
        if listHost then
            if listHost.GetChildren then
                local kids = { listHost:GetChildren() }
                for i = 1, #kids do
                    if kids[i].Hide then kids[i]:Hide() end
                end
            end
            if listHost.GetRegions then
                local regs = { listHost:GetRegions() }
                for i = 1, #regs do
                    if regs[i].Hide then regs[i]:Hide() end
                end
            end
        end

        local function warriorVisible(item) return self:SidebarItemVisible(item) end

        -- Captured before buttons are wiped below so the rebuild can tell
        -- "category was already expanded" from "category just expanded",
        -- which decides whether child buttons fade in or appear instantly.
        local hadVisibleChildren = {}
        if frame.sidebar.buttons then
            for _, button in ipairs(frame.sidebar.buttons) do
                if button.isSubmenu and button.menuItem then
                    for _, cat in ipairs(self.MenuStructure) do
                        if cat.children then
                            for _, child in ipairs(cat.children) do
                                if child.id == button.menuItem.id then
                                    hadVisibleChildren[cat.id] = true
                                    break
                                end
                            end
                        end
                    end
                end
            end
        end

        if frame.sidebar.buttons then
            for _, button in ipairs(frame.sidebar.buttons) do
                if self.UI and self.UI.StopAnimations then
                    self.UI:StopAnimations(button)
                end
                button:Hide()
                button:SetParent(nil)
            end
        end
        frame.sidebar.buttons = {}

        local scrollChild = frame.sidebar.scrollChild or frame.sidebar
        local yOffset = -8

        local searchText = frame.sidebarSearchText
        if searchText and searchText ~= "" then
            local found = 0
            -- Hard cap across all three passes below (panels/items, subpanel
            -- aliases, boss/ability matches) - not per-pass.
            local MAX_SEARCH_RESULTS = 20
            local searchCapped = false

            -- Words in any order ("bar position" finds "position bar"), and
            -- a page also counts when the settings search found something
            -- on it - a checkbox label, a card title - even though its name
            -- and aliases never mention the word.
            local SS = self.SidebarSearch
            local tokens = SS and SS.Tokens(searchText) or { searchText }
            local function Matches(hay)
                if SS then return SS.MatchAll(hay, tokens) end
                return hay:find(searchText, 1, true) ~= nil
            end

            local function ItemMatches(item, parentCategory)
                if SS and SS.hits and SS.hits[item.id] then return true end
                local parts = { (item.name or ""):lower() }
                if parentCategory then parts[#parts + 1] = (parentCategory.name or ""):lower() end
                for _, alias in ipairs(item.aliases or {}) do parts[#parts + 1] = alias:lower() end
                return Matches(table.concat(parts, " "))
            end

            -- While searching, a page in this list opens at the best thing
            -- it matched rather than at its top.
            local function Go(itemId, fallback)
                return function()
                    local best = SS and SS.BestFor and SS.BestFor(itemId)
                    if best then SS.JumpTo(best) else fallback() end
                end
            end

            local function AddResult(item, clickFn)
                if found >= MAX_SEARCH_RESULTS then searchCapped = true; return end
                found = found + 1
                local btn = self:CreateSidebarButton(scrollChild, item, yOffset, true)
                btn:SetScript("OnClick", clickFn)
                local isSelected = (self.SidebarState.selectedItem == item.id)
                self:SetSidebarButtonState(btn, isSelected, false)
                table.insert(frame.sidebar.buttons, btn)
                yOffset = yOffset - (btn.buttonHeight + RC.SIDEBAR.BUTTON_SPACING)
            end

            for _, category in ipairs(self.MenuStructure) do
                if warriorVisible(category) then
                    if category.panel and ItemMatches(category, nil) then
                        local capturedCat = category
                        AddResult(capturedCat, Go(capturedCat.id, function()
                            self.SidebarState.expandedCategories[capturedCat.id] = true
                            self:SelectSidebarItem(frame, capturedCat, nil)
                        end))
                    end
                    local items = (category.children and #category.children > 0) and category.children or (not category.category and {category} or {})
                    for _, item in ipairs(items) do
                        if warriorVisible(item) and not item.category then
                            if ItemMatches(item, category.children and category or nil) then
                                local capturedItem = item
                                local capturedCat = category.children and category or nil
                                AddResult(capturedItem, Go(capturedItem.id, function()
                                    self:SelectSidebarItem(frame, capturedItem, capturedCat)
                                end))
                            end
                        end
                    end
                end
            end

            local alreadyMatchedParents = {}
            for _, btn in ipairs(frame.sidebar.buttons) do
                if btn.menuItem and btn.menuItem.id then
                    alreadyMatchedParents[btn.menuItem.id] = true
                end
            end

            for _, sub in ipairs(RC.SUBPANEL_ALIASES or {}) do
                local parentItem, parentCat = nil, nil
                for _, cat in ipairs(self.MenuStructure) do
                    if cat.id == sub.parentId then
                        parentItem = cat
                        break
                    end
                    if cat.children then
                        for _, child in ipairs(cat.children) do
                            if child.id == sub.parentId then
                                parentItem = child
                                parentCat = cat
                                break
                            end
                        end
                        if parentItem then break end
                    end
                end

                if parentItem and warriorVisible(parentItem) then
                    local matched = false
                    local targets = {}
                    for _, kw in ipairs(sub.keywords) do table.insert(targets, kw:lower()) end
                    table.insert(targets, (sub.tabLabel or ""):lower())
                    table.insert(targets, (parentItem.name or ""):lower())
                    table.insert(targets, ((parentItem.name or "") .. " " .. (sub.tabLabel or "")):lower())
                    matched = Matches(table.concat(targets, " "))

                    if matched then
                        if not alreadyMatchedParents[parentItem.id] then
                            alreadyMatchedParents[parentItem.id] = true
                            local capturedParent1 = parentItem
                            local capturedCat1    = parentCat
                            AddResult(capturedParent1, function()
                                self:SelectSidebarItem(frame, capturedParent1, capturedCat1)
                            end)
                        end

                        local shortName = sub.tabLabel or sub.tabKey or "?"
                        if #shortName > 22 then
                            shortName = shortName:sub(1, 20) .. ".."
                        end

                        local synthetic = {
                            id   = parentItem.id .. ":" .. sub.tabKey,
                            name = shortName,
                            icon = parentItem.icon,
                        }
                        local capturedSub    = sub
                        local capturedParent = parentItem
                        local capturedCat    = parentCat
                        AddResult(synthetic, function()
                            if capturedSub.setTab then capturedSub.setTab(frame) end
                            self:SelectSidebarItem(frame, capturedParent, capturedCat)
                            if capturedSub.scrollTo and self.ScrollSidebarToCard then
                                self:ScrollSidebarToCard(frame, capturedSub.scrollTo)
                            end
                            if capturedSub.after then
                                C_Timer.After(0, function()
                                    capturedSub.after(frame)
                                end)
                            end
                        end)
                    end
                end
            end

            -- (its own reads: the ones in SidebarItemVisible are that function's locals)
            local isWarrior = self.isWarrior
            local nonWarEnabled = (self.db and self.db.nonWarriorEnabled) or {}
            local anyRaidEnabled = nonWarEnabled.mc or nonWarEnabled.bwl or nonWarEnabled.aq40 or nonWarEnabled.naxx
            if (isWarrior or anyRaidEnabled) and RC.raidMobConfigs then
                local raidIcons = {
                    ["Molten Core"]          = "Interface\\Icons\\Spell_Fire_Incinerate",
                    ["Blackwing Lair"]       = "Interface\\Icons\\INV_Misc_Head_Dragon_Black",
                    ["Temple of Ahn'Qiraj"] = "Interface\\Icons\\INV_Misc_QirajiCrystal_05",
                    ["Naxxramas"]            = "Interface\\Icons\\Achievement_Boss_KelThuzad_01",
                }
                local raidMenuIds = {
                    ["Molten Core"]          = "mc",
                    ["Blackwing Lair"]       = "bwl",
                    ["Temple of Ahn'Qiraj"] = "aq40",
                    ["Naxxramas"]            = "naxx",
                }
                local bossResults = {}
                for raidName, raidBosses in pairs(RC.raidMobConfigs) do
                    for bossName, bossData in pairs(raidBosses) do
                        local hay = { bossName:lower(), raidName:lower() }
                        for abilityKey, _ in pairs(bossData.abilities or {}) do
                            hay[#hay + 1] = tostring(abilityKey):lower()
                        end
                        local matched = Matches(table.concat(hay, " "))
                        if matched then
                            table.insert(bossResults, {raidName = raidName, bossName = bossName})
                        end
                    end
                end
                table.sort(bossResults, function(a, b)
                    if a.raidName ~= b.raidName then return a.raidName < b.raidName end
                    return a.bossName < b.bossName
                end)

                if #bossResults > 0 then
                    for _, res in ipairs(bossResults) do
                        local rn, bn = res.raidName, res.bossName
                        local synItem = {
                            id   = "boss_" .. bn,
                            name = bn .. "  |cFF888888(" .. rn .. ")|r",
                            icon = raidIcons[rn] or "Interface\\Icons\\Spell_Shadow_DeathsEmbrace",
                        }
                        -- Jumps straight to ShowInlineAbilityConfig instead of
                        -- SelectSidebarItem, so the sidebar button highlight
                        -- is only approximated (raidMenuIds[rn]) - there is no
                        -- real button for an individual boss to select.
                        AddResult(synItem, function()
                            local cf = frame.compatFrame
                            if not cf then return end
                            cf.configState = cf.configState or {}
                            cf.configState.selectedRaid = rn
                            cf.configState.selectedEncounter = bn
                            cf.configState.selectedEncounterType = "boss"
                            self.SidebarState.expandedCategories["raids"] = true
                            self.SidebarState.selectedItem = raidMenuIds[rn]
                            RC:ShowInlineAbilityConfig(cf, rn, bn, "boss", nil)
                        end)
                    end
                end
            end

            if found == 0 then
                local noResult = self:CreateFontString(scrollChild, "OVERLAY", nil, 10)
                noResult:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 10, yOffset - 10)
                local gc = self:GetColor("text", "gray")
                noResult:SetTextColor(gc.r, gc.g, gc.b, 1)
                noResult:SetText(RCL["No results found."])
                yOffset = yOffset - 30
            end

            if searchCapped then
                local moreHint = self:CreateFontString(scrollChild, "OVERLAY", nil, 10)
                moreHint:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 10, yOffset - 6)
                local hc = self:GetColor("text", "gray")
                moreHint:SetTextColor(hc.r, hc.g, hc.b, 1)
                moreHint:SetText(RCL["Type more to narrow results..."])
                yOffset = yOffset - 26
            end

            frame.sidebar.contentHeight = math.max(math.abs(yOffset) + 1, 100)

            if not frame.suppressScrollbarUpdate then
                local sc2 = frame.sidebar.scrollChild
                if sc2 then sc2:SetHeight(frame.sidebar.contentHeight) end
            end
            self:UpdateSidebarMenuScrollbar(frame)
            return
        end

        for _, category in ipairs(self.MenuStructure) do
            if not warriorVisible(category) then
            else
                local hasVisibleChildren = false
                if category.children then
                    for _, child in ipairs(category.children) do
                        if warriorVisible(child) then
                            hasVisibleChildren = true
                            break
                        end
                    end
                end

                if category.category and category.children and not hasVisibleChildren then
                else
                    local catButton = self:CreateSidebarButton(scrollChild, category, yOffset, false)
                    table.insert(frame.sidebar.buttons, catButton)

                    local isExpanded = self.SidebarState.expandedCategories[category.id]
                    local isSelected = (self.SidebarState.selectedItem == category.id)
                    self:SetSidebarButtonState(catButton, isSelected, isExpanded)

                    catButton:SetScript("OnClick", function()
                        if category.category and category.children then
                            if category.panel then
                                self.SidebarState.expandedCategories[category.id] =
                                    not self.SidebarState.expandedCategories[category.id]
                                self.SidebarState.selectedItem = category.id
                                if self.db then self.db.lastSidebarSelection = category.id end
                                self:RememberSidebarState()
                                self:BuildSidebar(frame, false)
                                self:ShowSidebarPanel(frame, category)
                            else
                                self.SidebarState.expandedCategories[category.id] =
                                    not self.SidebarState.expandedCategories[category.id]
                                self:RememberSidebarState()
                                self:BuildSidebar(frame, false)
                            end
                        elseif category.panel then
                            self:SelectSidebarItem(frame, category, nil)
                        end
                    end)

                    yOffset = yOffset - (catButton.buttonHeight + RC.SIDEBAR.BUTTON_SPACING)

                    if isExpanded and category.children then
                        local shouldAnimate = not hadVisibleChildren[category.id] and not isInitialBuild
                        local animIndex = 0

                        for i, child in ipairs(category.children) do
                            if not warriorVisible(child) then
                            elseif child.sidebarVisibleKey and RC.db and RC.db.sidebarNav and
                                   RC.db.sidebarNav[child.sidebarVisibleKey] == false then
                            elseif child.enabledKey and RC.db then
                                local tbl = RC.db[child.enabledKey[1]]
                                local isEnabled = tbl and tbl[child.enabledKey[2]]
                                if not isEnabled then
                                else
                                    animIndex = animIndex + 1
                                    local childButton = self:CreateSidebarButton(scrollChild, child, yOffset, true)
                                    table.insert(frame.sidebar.buttons, childButton)
                                    local childSelected = (self.SidebarState.selectedItem == child.id)
                                    self:SetSidebarButtonState(childButton, childSelected, false)
                                    if shouldAnimate and self.UI and self.UI.FadeIn then
                                        childButton:SetAlpha(0)
                                        C_Timer.After(animIndex * 0.025, function()
                                            if childButton and childButton:IsShown() then
                                                self.UI:FadeIn(childButton, 0.15)
                                            end
                                        end)
                                    end
                                    childButton:SetScript("OnClick", function()
                                        self:SelectSidebarItem(frame, child, category)
                                    end)
                                    yOffset = yOffset - (childButton.buttonHeight + RC.SIDEBAR.BUTTON_SPACING)
                                end
                            else
                                animIndex = animIndex + 1
                                local childButton = self:CreateSidebarButton(scrollChild, child, yOffset, true)
                                table.insert(frame.sidebar.buttons, childButton)

                                local childSelected = (self.SidebarState.selectedItem == child.id)
                                self:SetSidebarButtonState(childButton, childSelected, false)

                                if shouldAnimate and self.UI and self.UI.FadeIn then
                                    childButton:SetAlpha(0)
                                    C_Timer.After(animIndex * 0.025, function()
                                        if childButton and childButton:IsShown() then
                                            self.UI:FadeIn(childButton, 0.15)
                                        end
                                    end)
                                end

                                childButton:SetScript("OnClick", function()
                                    self:SelectSidebarItem(frame, child, category)
                                end)

                                yOffset = yOffset - (childButton.buttonHeight + RC.SIDEBAR.BUTTON_SPACING)
                            end
                        end
                    end

                    if category.category then
                        yOffset = yOffset - RC.SIDEBAR.CATEGORY_SPACING
                    end
                end
            end
        end

        frame.sidebar.contentHeight = math.abs(yOffset) + 1

        self:UpdateSidebarMenuScrollbar(frame)
    end

    function RC:UpdateSidebarMenuScrollbar(frame)
        if not frame or not frame.sidebar then return end

        local sidebar     = frame.sidebar
        local scrollFrame = sidebar.scrollFrame
        local scrollChild = sidebar.scrollChild
        local scrollBar   = scrollFrame and scrollFrame.scrollBar

        if not scrollFrame or not scrollChild or not scrollBar then return end

        frame.suppressScrollbarUpdate = nil

        local contentHeight = sidebar.contentHeight or 100
        scrollChild:SetHeight(contentHeight)

        local scrollFrameH = scrollFrame:GetHeight()
        local visibleH  = (scrollFrameH and scrollFrameH > 100) and scrollFrameH or (sidebar.knownScrollHeight or 636)
        local maxScroll = math.max(0, contentHeight - visibleH)

        scrollBar:SetMinMaxValues(0, maxScroll)
        if scrollBar.SizeThumb then scrollBar:SizeThumb(contentHeight, visibleH) end

        if maxScroll > 0 then
            local cur = scrollBar:GetValue()
            if cur > maxScroll then scrollBar:SetValue(maxScroll) end
            if scrollBar:GetAlpha() ~= 1 then scrollBar:SetAlpha(1) end
        else
            scrollBar:SetValue(0)
            scrollFrame:SetVerticalScroll(0)
            if scrollBar:GetAlpha() ~= 0 then scrollBar:SetAlpha(0) end
        end
    end

    function RC:SelectSidebarItem(frame, menuItem, parentCategory)
        self.SidebarState.selectedCategory = parentCategory and parentCategory.id or nil
        self.SidebarState.selectedItem = menuItem.id

        for _, button in ipairs(frame.sidebar.buttons or {}) do
            local isSelected = (button.menuItem.id == menuItem.id)
            self:SetSidebarButtonState(button, isSelected, self.SidebarState.expandedCategories[button.menuItem.id])
        end

        self:ShowSidebarPanel(frame, menuItem)
    end

    function RC:RefreshSidebarProfiles()
        if not self.sidebarConfigFrame or not self.sidebarConfigFrame.sidebar then return end

        for _, button in ipairs(self.sidebarConfigFrame.sidebar.buttons or {}) do
            if button.raidKey then
                local profileName = "Default"
                if self.GetActiveRaidProfile then
                    local _, name = self:GetActiveRaidProfile(button.raidKey)
                    profileName = name or "Default"
                end

                local bossCount, trashCount = self:GetRaidConfigCounts(button.raidKey)
                local greenCol = RC:GetColor("text", "green")
                local dimCol   = RC:GetColor("text", "gray")

                if button.profileText then
                    button.profileText:SetText(RCL["Profile: "] .. profileName)
                end
                local offId = self.FeatureOffForPage and self:FeatureOffForPage(button.menuItem)
                if offId then
                    if button.profileText then
                        button.profileText:SetTextColor(dimCol.r, dimCol.g, dimCol.b)
                    end
                    if button.countText then
                        button.countText:SetText(self:FeatureOffNote(offId))
                        button.countText:SetTextColor(dimCol.r, dimCol.g, dimCol.b)
                    end
                elseif bossCount > 0 or trashCount > 0 then
                    if button.profileText then
                        button.profileText:SetTextColor(greenCol.r, greenCol.g, greenCol.b)
                    end
                    if button.countText then
                        button.countText:SetText(bossCount .. RCL[" Bosses  "] .. trashCount .. RCL[" Trash"])
                        button.countText:SetTextColor(greenCol.r, greenCol.g, greenCol.b)
                    end
                else
                    if button.profileText then
                        button.profileText:SetTextColor(dimCol.r, dimCol.g, dimCol.b)
                    end
                    if button.countText then
                        button.countText:SetText(RCL["Not Configured"])
                        button.countText:SetTextColor(dimCol.r, dimCol.g, dimCol.b)
                    end
                end
            end
        end
    end

    -- preserveScroll: capture the scrollbar value before wiping content so a
    -- same-page refresh (dropdown onChange, move/toggle buttons) doesn't snap
    -- back to the top. Callers that navigate to a different page (back,
    -- sidebar nav) omit it so the new page opens scrolled to the top.
    -- Pairs with RestoreScrollPosition, which applies the saved value next
    -- frame after the new content's height is known.
    function RC:ClearSidebarContent(frame, preserveScroll)
        GameTooltip:Hide()

        RC._lastPageFrame = nil

        local compatFrame = frame.compatFrame
        if not compatFrame then return end

        local savedScrollValue = nil
        if preserveScroll and frame.contentFrame and frame.contentFrame.scrollBar then
            savedScrollValue = frame.contentFrame.scrollBar:GetValue()
        end

        frame.suppressScrollbarUpdate = true

        if RC._consumablesBarSearchTimer then RC._consumablesBarSearchTimer:Cancel(); RC._consumablesBarSearchTimer = nil; RC._consumablesBarSearchFocus = nil end
        if RC._potionsBarSearchTimer then RC._potionsBarSearchTimer:Cancel(); RC._potionsBarSearchTimer = nil; RC._potionsBarSearchFocus = nil end
        if RC._specDetectionSearchTimer then RC._specDetectionSearchTimer:Cancel(); RC._specDetectionSearchTimer = nil; RC._specDetectionSearchFocus = nil end

        if frame.scrollbarUpdateTimer then
            frame.scrollbarUpdateTimer:Cancel()
            frame.scrollbarUpdateTimer = nil
        end
        if frame.scrollbarUpdateTimer2 then
            frame.scrollbarUpdateTimer2:Cancel()
            frame.scrollbarUpdateTimer2 = nil
        end

        if frame.contentFrame and frame.contentFrame.scrollBar then
            if not preserveScroll then
                frame.contentFrame.scrollBar:SetMinMaxValues(0, 0)
                frame.contentFrame.scrollBar:SetValue(0)
                frame.contentFrame:SetVerticalScroll(0)
                frame.contentFrame.scrollBar:SetAlpha(0)
            end
        end

        if compatFrame.scrollChild then
            compatFrame.scrollChild:SetHeight(1)
        end

        if compatFrame.scrollChild then
            -- pooled pickers go back to the pool first (no new frames for
            -- them on the next build)
            if RC.UI and RC.UI.ReleaseCustomBlocks then
                RC.UI:ReleaseCustomBlocks(compatFrame.scrollChild)
            end
            local children = {compatFrame.scrollChild:GetChildren()}
            for _, child in ipairs(children) do
                child:Hide()
                child:SetParent(nil)
                -- thrown away for good (font refresh list, dropdown lists)
                if RC.UI and RC.UI.DiscardTree then RC.UI:DiscardTree(child) else child._rcDiscarded = true end
            end

            if not RC._regionGraveyard then
                RC._regionGraveyard = CreateFrame("Frame")
                RC._regionGraveyard:Hide()
            end
            local regions = {compatFrame.scrollChild:GetRegions()}
            for _, region in ipairs(regions) do
                if region.Hide then
                    region:Hide()
                end
                if region.SetParent then
                    region:SetParent(RC._regionGraveyard)
                end
            end
            RC._regionGraveyard._rcDiscarded = true
            if RC.PruneTrackedFonts then RC:PruneTrackedFonts() end
        end

        compatFrame.currentBackButton = nil

        compatFrame.elements = {}
        compatFrame.layoutRows = {}
        compatFrame.currentRow = 0
        compatFrame.rowHeight = 0

        if preserveScroll and savedScrollValue then
            frame.pendingScrollRestore = savedScrollValue
        end
    end

    -- 0.02s delay gives the new content's layout a frame to settle so
    -- GetMinMaxValues reflects the rebuilt scrollChild height, not the
    -- stale one from before ClearSidebarContent ran.
    function RC:RestoreScrollPosition(frame)
        if frame.pendingScrollRestore and frame.contentFrame and frame.contentFrame.scrollBar then
            local savedValue = frame.pendingScrollRestore
            frame.pendingScrollRestore = nil

            C_Timer.After(0.02, function()
                if frame.contentFrame and frame.contentFrame.scrollBar then
                    local _, maxScroll = frame.contentFrame.scrollBar:GetMinMaxValues()
                    local restoreValue = math.min(savedValue, maxScroll)
                    frame.contentFrame.scrollBar:SetValue(restoreValue)
                    frame.contentFrame:SetVerticalScroll(restoreValue)
                end
            end)
        end
    end

    -- Entry point used both for normal raid nav and for EnterRemoteEditMode
    -- (which calls this against the just-opened remote raid). Falls back to
    -- bossList[1] when there's no remembered boss or it's no longer valid
    -- for this raid, so it always lands somewhere rather than opening blank.
    function RC:OpenRaidBossPage(frame, raidName)
        frame._lastBossViewed = frame._lastBossViewed or {}
        local target = frame._lastBossViewed[raidName]
        local bossList = self.raidData and self.raidData[raidName] and self.raidData[raidName].bosses

        local valid = false
        if target and bossList then
            for _, bn in ipairs(bossList) do
                if bn == target then
                    valid = true
                    break
                end
            end
        end
        if not valid then target = bossList and bossList[1] end

        if target then
            frame.configState = frame.configState or {}
            frame.configState.selectedRaid = raidName
            frame.configState.selectedEncounter = target
            frame.configState.selectedEncounterType = "boss"
            self:ShowInlineAbilityConfig(frame, raidName, target, "boss", nil)
        else
            if self.ShowSidebarWelcome then self:ShowSidebarWelcome(frame) end
        end
    end
