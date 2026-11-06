------------------------------------------------------------------------
-- Readycheck - ML Predictions (Execute Calculator) & TTK Display
-- Execute/TTK settings pages. Edits self.executeCalculator.* (mode,
-- dataCollection, testMode, mlConfig, classicMultipliers), saved via
-- RC:SaveExecuteSettings() - a separate store from self.db.
-- Data tab parses fightHistory keys ("Raid|Profile_Boss" or legacy
-- "Raid_Boss") to group fights by raid/boss for the collapsible tree UI.
------------------------------------------------------------------------
-- Taint-safe API locals (fallbacks on RC.Compat, built in Core; never write _G)
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
RC._sbs = RC._sbs or {}
local _sbs = RC._sbs
local TEXT = _sbs.TEXT

------------------------------------------------------------------------
-- THE FIGHT GRID (Data tab)
-- A boss's fights, laid out as a grid of small cells and shown a page at
-- a time. It used to be one full-width 22px row per fight - a line of
-- text 230px long in a window 800 wide - and every row was three fresh
-- frames and nine regions, built again on every rebuild of the page and
-- never freed (the client does not destroy frames). A boss with a
-- thousand fights was a 23,000px card of three thousand frames, each
-- anchored to both sides of the card, so every pixel of a window resize
-- re-laid out all of them.
--
--   * CELLS, not rows: as many columns as the card is wide (three at
--     the default window width), filled down then across.
--   * A PAGE at a time: ROWS per column, with first / previous / next /
--     last when there is more than a page.
--   * POOLED: at most one page of cells exists, ever. A rebuild re-homes
--     and refills them; scripts are set once and read the cell's data.
--   * THE COLUMNS SHARE THE WHOLE CARD. MIN_W is the narrowest a cell
--     may be; however many of those fit, they are then widened to reach
--     the card's right edge, and the slack goes to the profile name -
--     the one label that was being cut short. Inside a cell the date
--     and the two buttons hang from the right, so they travel with it.
--   * Widening the card re-places the page's cells as it moves (one
--     page of them, never more); the page itself is rebuilt only when
--     the column count changes, and only once the drag pauses.
------------------------------------------------------------------------
local FightGrid = { ROWS = 20, ROW_H = 23, MIN_W = 232, GAP = 8, cells = {}, heads = {} }

-- how many columns fit a card this wide (10px inset each side)
function FightGrid.Columns(cardW)
    local inner = (cardW or 0) - 20
    return math.max(1, math.floor((inner + FightGrid.GAP) / (FightGrid.MIN_W + FightGrid.GAP)))
end

-- `cols` columns across a card this wide: how far apart their left edges
-- are, and how wide each one is. `cols` is given rather than worked out
-- when the page on show was built for a different width and has not been
-- rebuilt yet - it squeezes for the quarter second until it is.
function FightGrid.Measure(cardW, cols)
    cols = cols or FightGrid.Columns(cardW)
    local inner = math.max(120, (cardW or 0) - 20)
    local pitch = (inner + FightGrid.GAP) / cols
    return pitch, math.max(120, math.floor(pitch - FightGrid.GAP))
end

local function PaintCellSayge(cell)
    local ico = cell.saygeIco
    if cell.d and cell.d.sayge then
        ico:SetDesaturated(false)
        ico:SetVertexColor(1, 1, 1)
        ico:SetAlpha(1)
    else
        if not ico:SetDesaturated(true) then
            ico:SetVertexColor(0.35, 0.35, 0.35)
        end
        ico:SetAlpha(0.3)
    end
end

local function DeleteCellFight(cell)
    local d = cell.d
    local ec = RC.executeCalculator
    if not (d and d.fight and ec and ec.fightHistory and ec.fightHistory.data) then return end
    local bossData = ec.fightHistory.data[d.srcKey]
    if not bossData then return end
    local removed = false
    for j = #bossData, 1, -1 do
        if bossData[j] == d.fight then
            table.remove(bossData, j)
            removed = true
            break
        end
    end
    if not removed and bossData[d.index] then
        table.remove(bossData, d.index)
    end
    if #bossData == 0 then
        ec.fightHistory.data[d.srcKey] = nil
        if d.frame and d.frame.executeDataState then d.frame.executeDataState.expandedBoss = nil end
    end
    RC:SaveExecuteSettings()
    RC:ShowSidebarExecuteSettings(d.frame, true)
end

-- WHERE THINGS SIT IN A CELL, in one place because the column titles
-- above the grid have to line up with them. Number, time and the class
-- icon hang from the left; the delete X, the Darkmoon button and the date
-- hang from the right; the profile name takes whatever is between.
local SPOT = { idx = 4, idxW = 20, time = 24, timeW = 36, cls = 62, prof = 80,
               del = -2, sayge = -20, date = -36, dateW = 64, btn = 14 }

-- the five labels of a cell (or, at `size` 10, of a column's titles)
local function Labels(host, size)
    local function L()
        local fs = RC:CreateFontString(host, "OVERLAY", nil, size)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        return fs
    end
    local idx = L()
    idx:SetPoint("LEFT", host, "LEFT", SPOT.idx, 0)
    idx:SetWidth(SPOT.idxW)
    local time = L()
    time:SetPoint("LEFT", host, "LEFT", SPOT.time, 0)
    time:SetWidth(SPOT.timeW)
    local date = L()
    date:SetPoint("RIGHT", host, "RIGHT", SPOT.date, 0)
    date:SetWidth(SPOT.dateW)
    -- pinned at both ends, so it is as wide as the cell allows and the
    -- client cuts the name where it has to
    local prof = L()
    prof:SetPoint("LEFT", host, "LEFT", SPOT.prof, 0)
    prof:SetPoint("RIGHT", date, "LEFT", -4, 0)
    return idx, time, prof, date
end

-- the titles over the n-th column of cells: pooled like the cells, made
-- on first use and re-homed onto `card`
function FightGrid.Head(n, card)
    local head = FightGrid.heads[n]
    if not head then
        head = CreateFrame("Frame", nil, card)
        head:SetSize(FightGrid.MIN_W, 12)
        local idx, time, prof, date = Labels(head, 10)
        local dmf = RC:CreateFontString(head, "OVERLAY", nil, 10)
        dmf:SetJustifyH("LEFT")
        dmf:SetWordWrap(false)
        dmf:SetPoint("LEFT", head, "RIGHT", SPOT.sayge - SPOT.btn - 2, 0)
        -- over the class icon and the profile name both
        prof:ClearAllPoints()
        prof:SetPoint("LEFT", head, "LEFT", SPOT.cls, 0)
        prof:SetPoint("RIGHT", date, "LEFT", -4, 0)
        idx:SetText("#"); time:SetText("Time"); prof:SetText(RCL["Class / Profile"])
        date:SetText("Date"); dmf:SetText("DMF")
        for _, fs in ipairs({ idx, time, prof, date, dmf }) do
            fs:SetTextColor(TEXT.dimGray[1], TEXT.dimGray[2], TEXT.dimGray[3])
        end
        FightGrid.heads[n] = head
    end
    head:SetParent(card)
    head:SetFrameLevel(card:GetFrameLevel() + 1)
    head:Show()
    return head
end

-- Size and place the page on show for a card this wide. card._grid is
-- what the build left behind: the column count it was built for, the
-- title frames, how many cells are in use and where the grid starts.
function FightGrid.Place(card, cardW)
    local g = card and card._grid
    if not g or FightGrid.owner ~= card then return end
    if g.w == cardW then return end
    g.w = cardW
    local pitch, cellW = FightGrid.Measure(cardW, g.cols)
    for c, head in ipairs(g.heads) do
        head:SetWidth(cellW)
        head:ClearAllPoints()
        head:SetPoint("TOPLEFT", card, "TOPLEFT", 10 + math.floor((c - 1) * pitch + 0.5), g.headY)
    end
    for n = 1, g.used do
        local cell = FightGrid.cells[n]
        if cell then
            local col = math.floor(cell.slot / FightGrid.ROWS)
            local row = cell.slot % FightGrid.ROWS
            cell:SetWidth(cellW)
            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", card, "TOPLEFT",
                10 + math.floor(col * pitch + 0.5), g.top - row * FightGrid.ROW_H)
        end
    end
end

-- the n-th cell of the page, made on first use and re-homed onto `card`
function FightGrid.Acquire(n, card)
    local cell = FightGrid.cells[n]
    if not cell then
        cell = CreateFrame("Button", nil, card)
        cell:SetSize(FightGrid.MIN_W, 22)
        cell:EnableMouse(true)
        cell.d = {}
        cell.slot = 0

        local bg = cell:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(RC.UI.FLAT)
        cell.bg = bg
        cell:SetScript("OnEnter", function(self)
            local hb = RC:GetColor("buttons", "hoverBackground")
            self.bg:SetVertexColor(hb.r, hb.g, hb.b, 1)
        end)
        cell:SetScript("OnLeave", function(self)
            self.bg:SetVertexColor(1, 1, 1, self.d.stripe or 0)
        end)
        cell:SetScript("OnClick", function(self)
            local d = self.d
            if d.fight and RC.ShowFightEditDialog then
                RC:ShowFightEditDialog(d.fight, d.srcKey, function()
                    RC:ShowSidebarExecuteSettings(d.frame, true)
                end)
            end
        end)

        cell.idxText, cell.timeText, cell.profText, cell.dateText = Labels(cell, 9)

        local sayge = CreateFrame("Button", nil, cell)
        sayge:SetSize(SPOT.btn, SPOT.btn)
        sayge:SetPoint("RIGHT", cell, "RIGHT", SPOT.sayge, 0)
        local ico = sayge:CreateTexture(nil, "ARTWORK")
        ico:SetAllPoints()
        ico:SetTexture("Interface\\Icons\\inv_misc_orb_02")
        ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        cell.sayge, cell.saygeIco = sayge, ico
        sayge:SetScript("OnEnter", function(sb)
            GameTooltip:SetOwner(sb, "ANCHOR_RIGHT")
            GameTooltip:SetText(RCL["Darkmoon Faire buff: "] .. (cell.d.sayge and "yes" or "no"), 1, 1, 1)
            GameTooltip:AddLine(RCL["Click to toggle for this kill."], 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        sayge:SetScript("OnLeave", function() GameTooltip:Hide() end)
        sayge:SetScript("OnClick", function()
            local d = cell.d
            if not d.fight then return end
            d.sayge = not d.sayge
            d.fight.hasSayge = d.sayge
            PaintCellSayge(cell)
            if RC.SaveExecuteSettings then RC:SaveExecuteSettings() end
            local MS = RC.MeshSync
            if MS and MS.Push then MS:Push("executeCalc", nil, nil, true) end
        end)

        -- the class the kill was played on; a click edits the kill
        local cls = CreateFrame("Button", nil, cell)
        cls:SetSize(SPOT.btn, SPOT.btn)
        cls:SetPoint("LEFT", cell, "LEFT", SPOT.cls, 0)
        local clsIco = cls:CreateTexture(nil, "ARTWORK")
        clsIco:SetAllPoints()
        cell.cls, cell.clsIco = cls, clsIco
        cls:SetScript("OnEnter", function(cb)
            GameTooltip:SetOwner(cb, "ANCHOR_RIGHT")
            if RC.AddClassTooltip then RC:AddClassTooltip(cell.d.class) end
            GameTooltip:Show()
        end)
        cls:SetScript("OnLeave", function() GameTooltip:Hide() end)
        cls:SetScript("OnClick", function()
            local click = cell:GetScript("OnClick")
            if click then click(cell) end
        end)

        local del = RC.UI:CreateXCloseButton(cell, SPOT.btn, function() DeleteCellFight(cell) end)
        del:SetPoint("RIGHT", cell, "RIGHT", SPOT.del, 0)
        cell.del = del

        FightGrid.cells[n] = cell
    end
    cell:SetParent(card)
    local lvl = card:GetFrameLevel() + 1
    cell:SetFrameLevel(lvl)
    cell.sayge:SetFrameLevel(lvl + 2)
    cell.cls:SetFrameLevel(lvl + 2)
    cell.del:SetFrameLevel(lvl + 5)
    cell:Show()
    return cell
end

-- hide the cells from index n on (a short last page, or a smaller boss)
function FightGrid.Release(n)
    for i = n, #FightGrid.cells do FightGrid.cells[i]:Hide() end
end

-- put one fight into a cell
--   frame    the page frame (for the rebuild after an edit or a delete)
--   fight    the fight record; srcKey its key in fightHistory.data
--   index    its number in the boss's list; row its row on the page
--   outlier  flagged by the z-score test
function FightGrid.Fill(cell, frame, fight, srcKey, index, row, outlier)
    local d = cell.d
    d.frame, d.fight, d.srcKey, d.index = frame, fight, srcKey, index
    d.stripe = (row % 2 == 1) and 0.03 or 0
    d.sayge = (fight.hasSayge == true) or (fight.hasSayge == 1) or (fight.hasSayge == "true")
    d.class = RC.FightClass and RC:FightClass(fight) or nil
    cell.bg:SetVertexColor(1, 1, 1, d.stripe)

    cell.idxText:SetText(tostring(index))
    cell.idxText:SetTextColor(TEXT.dimGray[1], TEXT.dimGray[2], TEXT.dimGray[3])

    local fightTime = fight.totalFightTime or 0
    local timeStr = (fightTime > 0) and RC:FormatTime(fightTime) or "No data"
    if outlier then
        local c = RC:GetColor("text", "red")
        cell.timeText:SetText(timeStr .. "!")
        cell.timeText:SetTextColor(c.r, c.g, c.b, c.a)
    else
        cell.timeText:SetText(timeStr)
        cell.timeText:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])
    end

    local profName = fight.profileName
    if not profName or profName == "" then
        if srcKey and srcKey:find("|", 1, true) then
            local rest = srcKey:match("^[^|]+|(.+)$")
            if rest then profName = rest:match("^(.-)_") end
        end
    end
    if not profName or profName == "" then profName = "-" end
    -- no cutting it to ten letters here: the label is as wide as the cell
    -- has room for, and the client shortens it only when it must
    local gc = RC:GetColor("text", "gold")
    cell.profText:SetText(profName)
    cell.profText:SetTextColor(gc.r, gc.g, gc.b, 0.85)

    cell.dateText:SetText(fight.timestamp and date("%m/%d %H:%M", fight.timestamp) or "")
    cell.dateText:SetTextColor(TEXT.dimGray[1], TEXT.dimGray[2], TEXT.dimGray[3])

    PaintCellSayge(cell)
    if RC.PaintClassIcon then RC:PaintClassIcon(cell.clsIco, d.class) end
end

-- push the TTK settings over the mesh when this character broadcasts them
local function PushExecuteCalc()
    local MS = RC.MeshSync
    if MS and MS.IsEnabled and MS:IsEnabled() then
        local cc = MS:GetCharConfig()
        if cc and cc.autoBroadcast and cc.syncCategories
                and cc.syncCategories["executeCalc"] then
            MS:Push("executeCalc", nil, nil, true)
        end
    end
end

    function RC:ShowSidebarExecuteSettings(frame, preserveScroll)
        local cardY
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local parent = frame.scrollChild
        local yPos = -20

        local headerFrame, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["ML Predictions"],
            RCL["Track and predict boss kill times"], "Interface\\Icons\\Ability_Warrior_Savageblow")
        yPos = newY

        if frame.executeSettingsRefreshTimer then
            frame.executeSettingsRefreshTimer:Cancel()
            frame.executeSettingsRefreshTimer = nil
        end

        local currentMode = self.executeCalculator and self.executeCalculator.mode or "intelligent"

        if not frame.executeSettingsTab then
            frame.executeSettingsTab = "settings"
        end

        local tabDefs
        if currentMode == "intelligent" then
            tabDefs = {
                { key = "settings",   label = RCL["Settings"] },
                { key = "data",       label = RCL["Data"] },
                { key = "advanced",   label = RCL["Advanced"] },
                { key = "exclusions", label = RCL["Exclusions"] },
            }
        else
            tabDefs = {
                { key = "settings",    label = RCL["Settings"] },
                { key = "multipliers", label = RCL["Multipliers"] },
                { key = "exclusions",  label = RCL["Exclusions"] },
            }
        end

        local tabKeyValid = false
        for _, td in ipairs(tabDefs) do
            if td.key == frame.executeSettingsTab then
                tabKeyValid = true
                break
            end
        end
        if not tabKeyValid then
            frame.executeSettingsTab = "settings"
        end

        local _, tabY = RC.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = tabDefs,
            selected = frame.executeSettingsTab,
            onClick = function(tk)
                frame.executeSettingsTab = tk
                RC:ShowSidebarExecuteSettings(frame, true)
            end,
            advance = 38,
        })
        yPos = tabY

        local modeRow = CreateFrame("Frame", nil, parent)
        modeRow:SetHeight(30)
        modeRow:SetPoint("TOPLEFT",  parent, "TOPLEFT",  20, yPos)
        modeRow:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -20, yPos)

        local modeLabel = self:CreateFontString(modeRow, "OVERLAY", nil, 11)
        modeLabel:SetPoint("LEFT", modeRow, "LEFT", 0, 0)
        modeLabel:SetText(RCL["Prediction Method:"])
        local _lc = self:GetColor("text", "normal"); modeLabel:SetTextColor(_lc.r, _lc.g, _lc.b)

        local modeNames = {
            intelligent = "Intelligent (AI Learning)",
            classic     = "Classic (Simple Multiplier)"
        }
        local modeDropdown = self.UI:CreateScrollableDropdown(modeRow, 220, modeNames[currentMode], 8)
        modeDropdown:SetPoint("LEFT", modeLabel, "RIGHT", 10, 0)
        do
            local modeItems = {}
            for modeKey, modeName in pairs(modeNames) do
                table.insert(modeItems, { text = modeName, value = modeKey })
            end
            modeDropdown:SetItems(modeItems, function(value)
                RC.executeCalculator.mode = value
                frame.executeSettingsTab = "settings"
                RC:SaveExecuteSettings()
                C_Timer.After(0.1, function() RC:ShowSidebarExecuteSettings(frame, true) end)
            end)
            modeDropdown:SetSelectedValue(currentMode, modeNames[currentMode])
        end

        local modeDesc = self:CreateFontString(modeRow, "OVERLAY", nil, 10)
        modeDesc:SetPoint("LEFT", modeDropdown, "RIGHT", 10, 0)
        if currentMode == "intelligent" then
            modeDesc:SetText(RCL["Learns over time"])
            local _c = self:GetColor("text", "green"); modeDesc:SetTextColor(_c.r, _c.g, _c.b)
        else
            modeDesc:SetText(RCL["Fixed multipliers"])
            local _c = self:GetColor("text", "blue"); modeDesc:SetTextColor(_c.r, _c.g, _c.b)
        end
        yPos = yPos - 40

        local currentTab = frame.executeSettingsTab or "settings"

        local raidIcons = {
            ["Molten Core"] = "Interface\\Icons\\INV_Hammer_Unique_Sulfuras",
            ["Blackwing Lair"] = "Interface\\Icons\\INV_Misc_Head_Dragon_Black",
            ["Temple of Ahn'Qiraj"] = "Interface\\Icons\\INV_Misc_AhnQirajTrinket_01",
            ["Naxxramas"] = "Interface\\Icons\\Achievement_Boss_KelThuzad_01"
        }

        if currentTab == "settings" then
            local settingsCard = self:CreateSettingsCard(parent, yPos, RCL["General"])
            cardY = -32

            if not self.executeCalculator then return end
            if not self.executeCalculator.dataCollection then
                self.executeCalculator.dataCollection = { disabled = false }
            end
            local isCollectionEnabled = not self.executeCalculator.dataCollection.disabled

            local collectCheck = self.UI:CreateSettingCheckbox(settingsCard, cardY, "Enable data collection", isCollectionEnabled, function(cb)
                local newState = cb:GetChecked()
                RC.executeCalculator.dataCollection.disabled = not newState
                RC.executeCalculator.collectData = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveExecuteSettings()
            end)
            cardY = cardY - 28

            local collectInfo = self:CreateFontString(settingsCard, "OVERLAY", nil, 10)
            collectInfo:SetPoint("TOPLEFT", settingsCard, "TOPLEFT", 14, cardY)
            collectInfo:SetText(RCL["Records fight data when enabled"])
            collectInfo:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 25

            if not self.executeCalculator.testMode then
                self.executeCalculator.testMode = { enabled = false }
            end
            local isTestMode = self.executeCalculator.testMode.enabled or false
            local testCheck = self.UI:CreateSettingCheckbox(settingsCard, cardY, "Test Mode (track ANY target)", isTestMode, function(cb)
                local newState = cb:GetChecked()
                RC.executeCalculator.testMode.enabled = newState
                RC:ForceCheckboxUpdate(cb, newState)
                RC:SaveExecuteSettings()
            end)
            cardY = cardY - 28

            settingsCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - settingsCard:GetHeight() - 12

        elseif currentTab == "data" and currentMode == "intelligent" then
            if not frame.executeDataState then
                frame.executeDataState = { expanded = {}, expandedBoss = nil }
            end

            do
                local addCard = self:CreateSettingsCard(parent, yPos, RCL["Add kill data"])
                local acY = -32

                local selRaid = frame.executeAddKillRaid
                if not (selRaid and self.raidMobConfigs and self.raidMobConfigs[selRaid]) then
                    selRaid = "Naxxramas"
                    if not (self.raidMobConfigs and self.raidMobConfigs[selRaid]) then
                        selRaid = self.raidMobConfigs and next(self.raidMobConfigs) or "Naxxramas"
                    end
                end
                frame.executeAddKillRaid = selRaid
                local selBoss = frame.executeAddKillBoss

                local aliasSkip = {}
                if self.encounterAddPhases then
                    for _, info in pairs(self.encounterAddPhases) do
                        if info.aliases then
                            for _, a in ipairs(info.aliases) do aliasSkip[a] = true end
                        end
                        if info.adds then
                            for _, a in ipairs(info.adds) do aliasSkip[a] = true end
                        end
                    end
                end

                local function BossListFor(raidName)
                    local list = {}
                    local cfgTbl = self.raidMobConfigs and self.raidMobConfigs[raidName]
                    if cfgTbl then
                        for bossName in pairs(cfgTbl) do
                            if not aliasSkip[bossName] then
                                list[#list + 1] = bossName
                            end
                        end
                        table.sort(list)
                    end
                    return list
                end

                local raidLbl = self:CreateFontString(addCard, "OVERLAY", nil, 11)
                raidLbl:SetPoint("TOPLEFT", addCard, "TOPLEFT", 14, acY)
                raidLbl:SetText(RCL["Raid:"])
                raidLbl:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])

                local bossDD

                local function SetBossItems(raidName)
                    if not bossDD then return end
                    local items = {}
                    for _, bn in ipairs(BossListFor(raidName)) do
                        items[#items + 1] = { text = bn, value = bn }
                    end
                    bossDD:SetItems(items, function(value)
                        selBoss = value
                        frame.executeAddKillBoss = value
                    end)
                    local valid = false
                    if selBoss then
                        for _, it in ipairs(items) do
                            if it.value == selBoss then
                                valid = true
                                break
                            end
                        end
                    end
                    if not valid then
                        selBoss = nil
                        frame.executeAddKillBoss = nil
                    end
                    local lbl = selBoss or "Select boss..."
                    if self.UI.SetButtonText then
                        self.UI:SetButtonText(bossDD, lbl)
                    elseif bossDD.text and bossDD.text.SetText then
                        bossDD.text:SetText(lbl)
                    end
                end

                local raidDD = self.UI:CreateScrollableDropdown(addCard, 165, "", 8)
                raidDD:SetPoint("LEFT", raidLbl, "RIGHT", 8, 0)
                local raidItems = {}
                for _, rn in ipairs({ "Molten Core", "Blackwing Lair", "Temple of Ahn'Qiraj", "Naxxramas" }) do
                    if self.raidMobConfigs and self.raidMobConfigs[rn] then
                        raidItems[#raidItems + 1] = { text = rn, value = rn }
                    end
                end
                raidDD:SetItems(raidItems, function(value)
                    selRaid = value
                    frame.executeAddKillRaid = value
                    SetBossItems(value)
                end)
                if self.UI.SetButtonText then
                    self.UI:SetButtonText(raidDD, selRaid)
                elseif raidDD.text and raidDD.text.SetText then
                    raidDD.text:SetText(selRaid)
                end

                local raidBulkBtn = self.UI:CreateStyledButton(addCard, RCL["Raid Bulk"], 78, 22)
                raidBulkBtn:SetPoint("LEFT", raidDD, "RIGHT", 10, 0)
                raidBulkBtn:SetScript("OnClick", function()
                    if RC.ShowBulkKillDialog then
                        RC:ShowBulkKillDialog(selRaid, nil, function()
                            RC:ShowSidebarExecuteSettings(frame, true)
                        end)
                    end
                end)

                -- kills are filed per raid profile: this moves or copies a
                -- whole profile's worth (or one boss's) into another
                local moveBtn = self.UI:CreateStyledButton(addCard, RCL["Move / Copy"], 96, 22)
                moveBtn:SetPoint("LEFT", raidBulkBtn, "RIGHT", 10, 0)
                moveBtn:SetScript("OnClick", function()
                    if RC.ShowFightTransferDialog then
                        RC:ShowFightTransferDialog(selRaid, function()
                            RC:ShowSidebarExecuteSettings(frame, true)
                        end)
                    end
                end)
                moveBtn:HookScript("OnEnter", function(btn)
                    GameTooltip:SetOwner(btn, "ANCHOR_TOP")
                    GameTooltip:SetText(RCL["Move or copy kills from one raid profile to another"])
                    GameTooltip:Show()
                end)
                moveBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)

                acY = acY - 30

                local bossLbl = self:CreateFontString(addCard, "OVERLAY", nil, 11)
                bossLbl:SetPoint("TOPLEFT", addCard, "TOPLEFT", 14, acY)
                bossLbl:SetText(RCL["Boss:"])
                bossLbl:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])

                bossDD = self.UI:CreateScrollableDropdown(addCard, 165, "", 10)
                bossDD:SetPoint("LEFT", bossLbl, "RIGHT", 8, 0)
                SetBossItems(selRaid)

                local goBtn = self.UI:CreateStyledButton(addCard, RCL["Add Kills"], 80, 22)
                goBtn:SetPoint("LEFT", bossDD, "RIGHT", 10, 0)
                goBtn:SetScript("OnClick", function()
                    if not selBoss then
                        RC:Print(RCL["Pick a boss first."])
                        return
                    end
                    if RC.ShowBulkKillDialog then
                        RC:ShowBulkKillDialog(selRaid, selBoss, function()
                            RC:ShowSidebarExecuteSettings(frame, true)
                        end)
                    end
                end)

                acY = acY - 30
                addCard:SetContentHeight(math.abs(acY))
                yPos = yPos - addCard:GetHeight() - 12
            end

            local historyData = nil
            if self.executeCalculator and self.executeCalculator.fightHistory and self.executeCalculator.fightHistory.data then
                historyData = self.executeCalculator.fightHistory.data
            end

            if not historyData or next(historyData) == nil then
                local emptyCard = self:CreateSettingsCard(parent, yPos, RCL["No data yet"])
                cardY = -32

                local noDataText = self:CreateFontString(emptyCard, "OVERLAY", nil, 11)
                noDataText:SetPoint("TOPLEFT", emptyCard, "TOPLEFT", 14, cardY)
                noDataText:SetText(RCL["No fight data recorded yet."])
                noDataText:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
                cardY = cardY - 25

                local tipText = self:CreateFontString(emptyCard, "OVERLAY", nil, 10)
                tipText:SetPoint("TOPLEFT", emptyCard, "TOPLEFT", 14, cardY)
                tipText:SetText(RCL["Fight some raid bosses with data collection enabled!"])
                tipText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY = cardY - 25

                emptyCard:SetContentHeight(math.abs(cardY))
                yPos = yPos - emptyCard:GetHeight() - 12
            else
                if RC.PruneUnrecognizedFightKeys and RC:PruneUnrecognizedFightKeys() > 0 then
                    if RC.SaveExecuteSettings then RC:SaveExecuteSettings() end
                end

                -- THE CLASS EACH KILL WAS PLAYED ON. classFilter is this
                -- page's own: nil every kill, "" the kills with no class
                -- recorded, otherwise a class token ("WARRIOR").
                local classFilter = frame.executeDataState.classFilter
                local function ClassPasses(f)
                    if classFilter == nil then return true end
                    return (RC:FightClass(f) or "") == classFilter
                end
                local function FilterLabel()
                    if classFilter == nil then return RCL["all classes"] end
                    return RC:ClassLabelColored(classFilter ~= "" and classFilter or nil)
                end
                do
                    local byClass, none, total = {}, 0, 0
                    for _, list in pairs(historyData) do
                        if type(list) == "table" then
                            for _, f in ipairs(list) do
                                total = total + 1
                                local c = RC:FightClass(f)
                                if c then byClass[c] = (byClass[c] or 0) + 1 else none = none + 1 end
                            end
                        end
                    end
                    -- a filter left on a class that has no kills any more
                    if classFilter ~= nil and not ((classFilter == "" and none > 0) or byClass[classFilter]) then
                        classFilter = nil
                        frame.executeDataState.classFilter = nil
                    end

                    local clsCard = self:CreateSettingsCard(parent, yPos, RCL["Class played"])
                    local ccY = -32

                    local showLbl = self:CreateFontString(clsCard, "OVERLAY", nil, 11)
                    showLbl:SetPoint("TOPLEFT", clsCard, "TOPLEFT", 14, ccY)
                    showLbl:SetText(RCL["Show kills played on:"])
                    showLbl:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])

                    local items = { { text = string.format(RCL["All classes (%d)"], total), value = "*" } }
                    for _, token in ipairs(RC.TTK_CLASS_ORDER or {}) do
                        if byClass[token] then
                            items[#items + 1] = { text = RC:ClassLabelColored(token) .. " (" .. byClass[token] .. ")", value = token }
                        end
                    end
                    if none > 0 then
                        items[#items + 1] = { text = string.format(RCL["Not recorded (%d)"], none), value = "" }
                    end
                    local clsDD = self.UI:CreateScrollableDropdown(clsCard, 190, "", 11)
                    clsDD:SetPoint("LEFT", showLbl, "RIGHT", 8, 0)
                    clsDD:SetItems(items, function(value)
                        frame.executeDataState.classFilter = (value ~= "*") and value or nil
                        RC:ShowSidebarExecuteSettings(frame, true)
                    end)
                    local shown = items[1].text
                    for _, it in ipairs(items) do
                        if it.value == (classFilter or "*") then shown = it.text end
                    end
                    if self.UI.SetButtonText then
                        self.UI:SetButtonText(clsDD, shown)
                    elseif clsDD.text and clsDD.text.SetText then
                        clsDD.text:SetText(shown)
                    end
                    if classFilter ~= nil then
                        local clsIco = clsCard:CreateTexture(nil, "ARTWORK")
                        clsIco:SetSize(18, 18)
                        clsIco:SetPoint("LEFT", clsDD, "RIGHT", 8, 0)
                        RC:PaintClassIcon(clsIco, classFilter ~= "" and classFilter or nil)
                    end
                    ccY = ccY - 30

                    local mine = RC:PlayerClassToken()
                    local ml = self.executeCalculator.mlConfig
                    local matchCB = self.UI:CreateCheckbox(clsCard,
                        string.format(RCL["Predictions prefer kills played on your class (%s)"], RC:ClassLabelColored(mine)),
                        ml and ml.matchClass == true)
                    matchCB:SetPoint("TOPLEFT", clsCard, "TOPLEFT", 14, ccY)
                    matchCB:SetScript("OnClick", function(cbBtn)
                        local on = cbBtn:GetChecked() and true or false
                        RC:ForceCheckboxUpdate(cbBtn, on)
                        if RC.executeCalculator.mlConfig then RC.executeCalculator.mlConfig.matchClass = on end
                        RC:SaveExecuteSettings()
                        PushExecuteCalc()
                    end)
                    matchCB:HookScript("OnEnter", function(cbBtn)
                        GameTooltip:SetOwner(cbBtn, "ANCHOR_RIGHT")
                        GameTooltip:SetText(RCL["Predict from your own class's kills"], 1, 1, 1)
                        GameTooltip:AddLine(RCL["Once there are enough kills on the class you are playing, only those are used. Until then every kill counts. Kills with no class recorded never count as yours."], 0.8, 0.8, 0.8, true)
                        GameTooltip:Show()
                    end)
                    matchCB:HookScript("OnLeave", function() GameTooltip:Hide() end)
                    ccY = ccY - 26

                    -- related raid configs share their kill times (on by default)
                    local shareCB = self.UI:CreateCheckbox(clsCard,
                        RCL["Predictions use kills from related raid configs"],
                        not (ml and ml.shareRelated == false))
                    shareCB:SetPoint("TOPLEFT", clsCard, "TOPLEFT", 14, ccY)
                    shareCB:SetScript("OnClick", function(cbBtn)
                        local on = cbBtn:GetChecked() and true or false
                        RC:ForceCheckboxUpdate(cbBtn, on)
                        if RC.executeCalculator.mlConfig then RC.executeCalculator.mlConfig.shareRelated = on end
                        RC:SaveExecuteSettings()
                        PushExecuteCalc()
                    end)
                    shareCB:HookScript("OnEnter", function(cbBtn)
                        GameTooltip:SetOwner(cbBtn, "ANCHOR_RIGHT")
                        GameTooltip:SetText(RCL["Share kill times between related configs"], 1, 1, 1)
                        GameTooltip:AddLine(RCL["Raid configs whose names start with the same two words count as one - \"Crit Crush DPS\" and \"Crit Crush Spider Tank\", say. Predictions for any of them use all of their kills, whichever one is selected. Each kill stays saved under the config it was recorded on."], 0.8, 0.8, 0.8, true)
                        GameTooltip:Show()
                    end)
                    shareCB:HookScript("OnLeave", function() GameTooltip:Hide() end)
                    ccY = ccY - 26

                    if none > 0 and mine then
                        local markBtn = self.UI:CreateStyledButton(clsCard,
                            string.format(RCL["Mark %d unrecorded kills as %s"], none, RC:ClassLabel(mine)), 270, 22)
                        markBtn:SetPoint("TOPLEFT", clsCard, "TOPLEFT", 14, ccY)
                        markBtn:SetScript("OnClick", function()
                            RC.UI:CreateConfirmDialog(
                                RCL["Mark Unrecorded Kills"],
                                string.format(RCL["Mark the %d kills with no class recorded as played on %s?\n\nOnly do this if you played them on this class. Single kills can be changed by clicking them."],
                                    none, RC:ClassLabel(mine)),
                                function()
                                    local hist = RC.executeCalculator and RC.executeCalculator.fightHistory
                                        and RC.executeCalculator.fightHistory.data
                                    if not hist then return end
                                    for _, list in pairs(hist) do
                                        if type(list) == "table" then
                                            for _, f in ipairs(list) do
                                                if type(f) == "table" and not RC:FightClass(f) then f.class = mine end
                                            end
                                        end
                                    end
                                    RC:SaveExecuteSettings()
                                    PushExecuteCalc()
                                    RC:ShowSidebarExecuteSettings(frame, true)
                                end,
                                nil, RCL["Mark"]
                            )
                        end)
                        ccY = ccY - 30
                    end

                    clsCard:SetContentHeight(math.abs(ccY))
                    yPos = yPos - clsCard:GetHeight() - 12
                end

                local raidData = {}
                for bossKey, fights in pairs(historyData) do
                    local raidName, bossName
                    -- New keys: "Raid|Profile_Boss" (text after "|" still has a
                    -- profile prefix). Legacy keys: "Raid_Boss", no profile.
                    if type(bossKey) == "string" and bossKey:find("|", 1, true) then
                        local rest
                        raidName, rest = bossKey:match("^([^|]+)|(.+)$")
                        if rest then
                            bossName = rest:match("^.-_(.+)$")
                        end
                    else
                        raidName, bossName = bossKey and bossKey:match("^(.-)_(.+)$")
                    end
                    -- a bucket with no kill on show under the class filter
                    -- is left out, so a boss can drop out of the tree
                    local anyShown = false
                    if raidName and bossName and type(fights) == "table" then
                        for _, f in ipairs(fights) do
                            if ClassPasses(f) then anyShown = true break end
                        end
                    end
                    if raidName and bossName and anyShown then
                        if not raidData[raidName] then
                            raidData[raidName] = {}
                        end
                        if raidData[raidName][bossName] then
                            local entry = raidData[raidName][bossName]
                            for _, f in ipairs(fights) do
                                if ClassPasses(f) then
                                    table.insert(entry.fights, f)
                                    table.insert(entry.fightKeys, bossKey)
                                end
                            end
                            table.insert(entry.bossKeys, bossKey)
                        else
                            local fightsCopy = {}
                            local fightKeys = {}
                            for _, f in ipairs(fights) do
                                if ClassPasses(f) then
                                    table.insert(fightsCopy, f)
                                    table.insert(fightKeys, bossKey)
                                end
                            end
                            raidData[raidName][bossName] = { fights = fightsCopy, fightKeys = fightKeys, bossKey = bossKey, bossKeys = {bossKey} }
                        end
                    else
                        raidName = nil
                    end
                end

                if classFilter ~= nil and next(raidData) == nil then
                    local noneCard = self:CreateSettingsCard(parent, yPos, RCL["No kills"])
                    local nl = self:CreateFontString(noneCard, "OVERLAY", nil, 11)
                    nl:SetPoint("TOPLEFT", noneCard, "TOPLEFT", 14, -32)
                    nl:SetText(string.format(RCL["No kills played on %s."], FilterLabel()))
                    nl:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
                    noneCard:SetContentHeight(57)
                    yPos = yPos - noneCard:GetHeight() - 12
                end

                local raidOrder = {
                    ["Molten Core"] = 1,
                    ["Blackwing Lair"] = 2,
                    ["Temple of Ahn'Qiraj"] = 3,
                    ["Naxxramas"] = 4
                }
                local sortedRaids = {}
                for raidName in pairs(raidData) do
                    table.insert(sortedRaids, raidName)
                end
                table.sort(sortedRaids, function(a, b)
                    return (raidOrder[a] or 99) < (raidOrder[b] or 99)
                end)

                for _, raidName in ipairs(sortedRaids) do
                    local bosses = raidData[raidName]
                    local isExpanded = frame.executeDataState.expanded[raidName]

                    local bossCount, fightCount = 0, 0
                    for _, entry in pairs(bosses) do
                        bossCount = bossCount + 1
                        fightCount = fightCount + #entry.fights
                    end

                    local sbSelected = RC:GetColor("sidebar", "buttonSelected")
                    local sbHover = RC:GetColor("buttons", "configuredHover")
                    local txtSelected = RC:GetColor("text", "menuSelected")

                    local raidHeader = CreateFrame("Button", nil, parent, "BackdropTemplate")
                    raidHeader:SetHeight(32)
                    raidHeader:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yPos)
                    raidHeader:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -10, yPos)
                    -- Flat category row (no statusbar gradient), 1px black ring.
                    raidHeader:SetBackdrop({
                        bgFile = RC.UI.FLAT,
                        edgeFile = RC.UI.FLAT,
                        edgeSize = 1,
                    })
                    raidHeader:SetBackdropColor(sbSelected.r, sbSelected.g, sbSelected.b, 1)
                    local _bn = RC:GetColor("ui", "borderNormal")
                    raidHeader:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1)

                    raidHeader.sbSelected = sbSelected
                    raidHeader.sbHover = sbHover
                    RC.UI:AttachHover(raidHeader, sbSelected, sbHover)

                    local raidIcon = raidHeader:CreateTexture(nil, "ARTWORK")
                    raidIcon:SetSize(24, 24)
                    raidIcon:SetPoint("LEFT", raidHeader, "LEFT", 8, 0)
                    raidIcon:SetTexture(raidIcons[raidName] or "Interface\\Icons\\INV_Misc_QuestionMark")

                    local indicator = self:CreateFontString(raidHeader, "OVERLAY", nil, 12)
                    indicator:SetPoint("LEFT", raidIcon, "RIGHT", 6, 0)
                    indicator:SetText(isExpanded and "-" or "+")
                    indicator:SetTextColor(txtSelected.r * 0.9, txtSelected.g * 0.9, txtSelected.b * 0.9)

                    local raidText = self:CreateFontString(raidHeader, "OVERLAY", nil, 12)
                    raidText:SetPoint("LEFT", indicator, "RIGHT", 6, 0)
                    raidText:SetText(raidName)
                    local wc = RC:GetColor("text", "normal"); raidText:SetTextColor(wc.r, wc.g, wc.b, wc.a or 1)

                    local countText = self:CreateFontString(raidHeader, "OVERLAY", nil, 10)
                    countText:SetPoint("RIGHT", raidHeader, "RIGHT", -10, 0)
                    countText:SetText(string.format(RCL["%d bosses, %d fights"], bossCount, fightCount))
                    countText:SetTextColor(txtSelected.r * 0.9, txtSelected.g * 0.9, txtSelected.b * 0.9)
                    raidHeader:SetScript("OnClick", function()
                        frame.executeDataState.expanded[raidName] = not isExpanded
                        RC:ShowSidebarExecuteSettings(frame, true)
                    end)

                    yPos = yPos - 36

                    if isExpanded then
                        local sortedBosses = {}
                        for bossName in pairs(bosses) do
                            table.insert(sortedBosses, bossName)
                        end
                        table.sort(sortedBosses)

                        for _, bossName in ipairs(sortedBosses) do
                            local entry = bosses[bossName]
                            local fights = entry.fights
                            local fightNum = #fights
                            local bossKey = entry.bossKey
                            local isBossExpanded = (frame.executeDataState.expandedBoss == bossKey)

                            local totalTime, validCount = 0, 0
                            local fightTimes = {}
                            for _, fight in ipairs(fights) do
                                if fight.totalFightTime and fight.totalFightTime > 0 then
                                    totalTime = totalTime + fight.totalFightTime
                                    validCount = validCount + 1
                                    table.insert(fightTimes, fight.totalFightTime)
                                end
                            end
                            local avgTime = validCount > 0 and (totalTime / validCount) or 0

                            local outlierCount = 0
                            local threshold = (self.executeCalculator.mlConfig and self.executeCalculator.mlConfig.outlierThreshold) or 2.0
                            if validCount >= 3 then
                                local variance = 0
                                for _, t in ipairs(fightTimes) do
                                    variance = variance + (t - avgTime)^2
                                end
                                variance = variance / validCount
                                local stdDev = math.sqrt(variance)
                                if stdDev > 0 then
                                    for _, t in ipairs(fightTimes) do
                                        local zScore = math.abs((t - avgTime) / stdDev)
                                        if zScore > threshold then
                                            outlierCount = outlierCount + 1
                                        end
                                    end
                                end
                            end

                            -- D6 row: flat cardBackground fill, hover buttons.hoverBackground;
                            -- the expanded boss wears the selected look (configured fill +
                            -- 3px gold bar down the left edge).
                            local rowBg = isBossExpanded
                                and self:GetColor("buttons", "configuredBackground")
                                or  self:GetColor("ui", "cardBackground")
                            local rowHover = isBossExpanded
                                and self:GetColor("buttons", "configuredHover")
                                or  self:GetColor("buttons", "hoverBackground")

                            local bossRow = CreateFrame("Button", nil, parent, "BackdropTemplate")
                            bossRow:SetHeight(28)
                            bossRow:SetPoint("TOPLEFT", parent, "TOPLEFT", 30, yPos)
                            bossRow:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -10, yPos)
                            bossRow:SetBackdrop({
                                bgFile = RC.UI.FLAT,
                                edgeFile = RC.UI.FLAT,
                                edgeSize = 1,
                            })
                            bossRow:SetBackdropColor(rowBg.r, rowBg.g, rowBg.b, 1)
                            local _rbn = RC:GetColor("ui", "borderNormal")
                            bossRow:SetBackdropBorderColor(_rbn.r, _rbn.g, _rbn.b, _rbn.a or 1)
                            bossRow.rowBg = rowBg
                            bossRow.rowHover = rowHover
                            RC.UI:AttachHover(bossRow, rowBg, rowHover)

                            if isBossExpanded then
                                local selBar = bossRow:CreateTexture(nil, "ARTWORK")
                                selBar:SetPoint("TOPLEFT", bossRow, "TOPLEFT", 1, -1)
                                selBar:SetPoint("BOTTOMLEFT", bossRow, "BOTTOMLEFT", 1, 1)
                                selBar:SetWidth(3)
                                selBar:SetTexture(RC.UI.FLAT)
                                local _sg = RC:GetColor("ui", "borderSelected")
                                selBar:SetVertexColor(_sg.r, _sg.g, _sg.b, 1)
                            end

                            local bossIcon = bossRow:CreateTexture(nil, "ARTWORK")
                            bossIcon:SetSize(22, 22)
                            bossIcon:SetPoint("LEFT", bossRow, "LEFT", 6, 0)
                            local iconPath = self.bossIcons and self.bossIcons[bossName] or "Interface\\Icons\\Ability_Creature_Cursed_02"
                            bossIcon:SetTexture(iconPath)

                            local bossIndicator = self:CreateFontString(bossRow, "OVERLAY", nil, 10)
                            bossIndicator:SetPoint("LEFT", bossIcon, "RIGHT", 4, 0)
                            bossIndicator:SetText(isBossExpanded and "-" or "+")
                            bossIndicator:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])

                            local bossText = self:CreateFontString(bossRow, "OVERLAY", nil, 11)
                            bossText:SetPoint("LEFT", bossIndicator, "RIGHT", 4, 0)
                            bossText:SetText(bossName)
                            local _c = self:GetColor("text", "normal"); bossText:SetTextColor(_c.r, _c.g, _c.b, _c.a)

                            local statsStr = string.format(RCL["%d fights"], fightNum)
                            if avgTime > 0 then
                                statsStr = statsStr .. string.format(RCL[" | Avg: %ds"], math.floor(avgTime + 0.5))
                            end
                            if outlierCount > 0 then
                                statsStr = statsStr .. string.format(RCL[" | %d outliers"], outlierCount)
                            end

                            local statsText = self:CreateFontString(bossRow, "OVERLAY", nil, 10)
                            statsText:SetPoint("RIGHT", bossRow, "RIGHT", -10, 0)
                            statsText:SetText(statsStr)

                            if fightNum >= 10 then
                                statsText:SetTextColor(TEXT.green[1], TEXT.green[2], TEXT.green[3])
                            elseif fightNum >= 5 then
                                local _c = self:GetColor("text", "green"); statsText:SetTextColor(_c.r, _c.g, _c.b, _c.a)
                            elseif fightNum >= 3 then
                                local yellC = RC:GetColor("ui", "accentGold")
                                statsText:SetTextColor(yellC.r, 1, 0.6)
                            else
                                local hovC = RC:GetColor("text", "buttonHover")
                                statsText:SetTextColor(hovC.r, hovC.g, hovC.b, 1)
                            end

                            bossRow:SetScript("OnClick", function()
                                if frame.executeDataState.expandedBoss == bossKey then
                                    frame.executeDataState.expandedBoss = nil
                                else
                                    frame.executeDataState.expandedBoss = bossKey
                                end
                                RC:ShowSidebarExecuteSettings(frame, true)
                            end)

                            yPos = yPos - 32

                            if isBossExpanded then
                                local detailsCard = CreateFrame("Frame", nil, parent, "BackdropTemplate")
                                detailsCard:SetPoint("TOPLEFT", parent, "TOPLEFT", 40, yPos)
                                detailsCard:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -10, yPos)
                                -- Card look: flat cardBackground, 1px borderNormal at 0.55,
                                -- 3px gold accent bar down the left edge.
                                detailsCard:SetBackdrop({
                                    bgFile = RC.UI.FLAT,
                                    edgeFile = RC.UI.FLAT,
                                    edgeSize = 1,
                                })
                                local cardBg = self:GetColor("ui", "cardBackground")
                                detailsCard:SetBackdropColor(cardBg.r, cardBg.g, cardBg.b, 1)
                                local cardBn = self:GetColor("ui", "borderNormal")
                                detailsCard:SetBackdropBorderColor(cardBn.r, cardBn.g, cardBn.b, 0.55)
                                local cardBar = detailsCard:CreateTexture(nil, "ARTWORK")
                                cardBar:SetPoint("TOPLEFT", detailsCard, "TOPLEFT", 1, -1)
                                cardBar:SetPoint("BOTTOMLEFT", detailsCard, "BOTTOMLEFT", 1, 1)
                                cardBar:SetWidth(3)
                                cardBar:SetTexture(RC.UI.FLAT)
                                local cardGold = self:GetColor("ui", "accentGold")
                                cardBar:SetVertexColor(cardGold.r, cardGold.g, cardGold.b, 0.8)

                                local detailY = -8

                                local summaryText = self:CreateFontString(detailsCard, "OVERLAY", nil, 10)
                                summaryText:SetPoint("TOPLEFT", detailsCard, "TOPLEFT", 10, detailY)
                                local summaryStr = string.format(RCL["Avg: |cff00ff00%ds|r  |  Outliers: |cffff8800%d|r"], math.floor(avgTime + 0.5), outlierCount)
                                -- what the reminders go by on the active config
                                -- (its own kills plus related configs')
                                local pred, _, used = RC:PredictTTK(raidName, bossName)
                                if pred then
                                    local gc = RC:GetColor("text", "green")
                                    local hex = string.format("|cff%02x%02x%02x", math.floor(gc.r * 255), math.floor(gc.g * 255), math.floor(gc.b * 255))
                                    summaryStr = summaryStr .. string.format(RCL["  |  Predicted: %s from %d kills"],
                                        hex .. RC:FormatTime(pred) .. "|r", used or 0)
                                end
                                summaryText:SetText(summaryStr)
                                summaryText:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])

                                local saygeTotal, saygeCount = 0, 0
                                for _, fight in ipairs(fights) do
                                    if fight.hasSayge and fight.totalFightTime and fight.totalFightTime > 0 then
                                        saygeTotal = saygeTotal + fight.totalFightTime
                                        saygeCount = saygeCount + 1
                                    end
                                end
                                if saygeCount > 0 then
                                    local saygeAvg = saygeTotal / saygeCount
                                    local saygeIcon = detailsCard:CreateTexture(nil, "ARTWORK")
                                    saygeIcon:SetSize(12, 12)
                                    saygeIcon:SetPoint("TOPLEFT", summaryText, "BOTTOMLEFT", 0, -4)
                                    saygeIcon:SetTexture("Interface\\Icons\\inv_misc_orb_02")
                                    saygeIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                                    local saygeAvgText = self:CreateFontString(detailsCard, "OVERLAY", nil, 10)
                                    saygeAvgText:SetPoint("LEFT", saygeIcon, "RIGHT", 3, 0)
                                    saygeAvgText:SetText(string.format(RCL["Sayge avg: |cff00ff00%ds|r  (%d kill%s)"], math.floor(saygeAvg + 0.5), saygeCount, saygeCount == 1 and "" or "s"))
                                    saygeAvgText:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])
                                    detailY = detailY - 16
                                end

                                -- which classes these kills were played on
                                if classFilter == nil then
                                    local byClass, noClass = {}, 0
                                    for _, fight in ipairs(fights) do
                                        local c = RC:FightClass(fight)
                                        if c then byClass[c] = (byClass[c] or 0) + 1 else noClass = noClass + 1 end
                                    end
                                    if next(byClass) then
                                        local parts = {}
                                        for _, token in ipairs(RC.TTK_CLASS_ORDER or {}) do
                                            if byClass[token] then
                                                parts[#parts + 1] = RC:ClassLabelColored(token) .. " " .. byClass[token]
                                            end
                                        end
                                        if noClass > 0 then
                                            parts[#parts + 1] = string.format(RCL["not recorded %d"], noClass)
                                        end
                                        local clsText = self:CreateFontString(detailsCard, "OVERLAY", nil, 10)
                                        clsText:SetPoint("TOPLEFT", detailsCard, "TOPLEFT", 10, detailY - 16)
                                        clsText:SetText(RCL["Played as:  "] .. table.concat(parts, "   "))
                                        clsText:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])
                                        detailY = detailY - 16
                                    end
                                end

                                -- Destructive button: framework button with red text on the
                                -- normal fill (hover still lifts to gold like every button).
                                local deleteAllBtn = self.UI:CreateStyledButton(detailsCard, RCL["Delete All"], 70, 18)
                                deleteAllBtn:SetPoint("TOPRIGHT", detailsCard, "TOPRIGHT", -8, detailY + 4)
                                local function PaintDeleteAllText()
                                    local _rd = RC:GetColor("text", "red")
                                    deleteAllBtn.text:SetTextColor(_rd.r, _rd.g, _rd.b, 1)
                                end
                                PaintDeleteAllText()
                                deleteAllBtn:HookScript("OnLeave", PaintDeleteAllText)
                                deleteAllBtn:SetScript("OnClick", function()
                                    RC.UI:CreateConfirmDialog(
                                        RCL["Delete TTK Data"],
                                        classFilter and string.format(
                                            RCL["Delete the %d kills on %s for %s?\n\nKills on other classes stay. This cannot be undone."],
                                            fightNum, FilterLabel(), bossName)
                                            or (RCL["Delete all fight data for "] .. bossName .. RCL["?\n\nThis cannot be undone."]),
                                        function()
                                            if RC.executeCalculator and RC.executeCalculator.fightHistory and RC.executeCalculator.fightHistory.data then
                                                local hist = RC.executeCalculator.fightHistory.data
                                                for _, k in ipairs(entry.bossKeys or {entry.bossKey}) do
                                                    if classFilter == nil then
                                                        hist[k] = nil
                                                    elseif hist[k] then
                                                        -- a class filter is on: only the kills on show go
                                                        local list = hist[k]
                                                        for j = #list, 1, -1 do
                                                            if ClassPasses(list[j]) then table.remove(list, j) end
                                                        end
                                                        if #list == 0 then hist[k] = nil end
                                                    end
                                                end
                                                RC:SaveExecuteSettings()
                                                frame.executeDataState.expandedBoss = nil
                                                RC:ShowSidebarExecuteSettings(frame, true)
                                            end
                                        end,
                                        nil, RCL["Delete"], true
                                    )
                                end)

                                local addKillsBtn = self.UI:CreateStyledButton(detailsCard, RCL["Add Kills"], 66, 18)
                                addKillsBtn:SetPoint("RIGHT", deleteAllBtn, "LEFT", -6, 0)
                                addKillsBtn:SetScript("OnClick", function()
                                    if RC.ShowBulkKillDialog then
                                        RC:ShowBulkKillDialog(raidName, bossName, function()
                                            RC:ShowSidebarExecuteSettings(frame, true)
                                        end)
                                    end
                                end)

                                detailY = detailY - 22

                                -- THE FIGHT LIST: a grid of pooled cells, a page at a time
                                -- (FightGrid, top of this file).
                                -- the card spans the page less its insets (40 left, 10
                                -- right); measured from the page, whose width is always
                                -- set, so the build and the resize check below agree
                                local function CardWidth()
                                    return (parent:GetWidth() or 800) - 50
                                end
                                local function ColumnsNow()
                                    return FightGrid.Columns(CardWidth())
                                end
                                local cols = ColumnsNow()
                                local perPage = cols * FightGrid.ROWS
                                local pages = math.max(1, math.ceil(#fights / perPage))
                                local dataState = frame.executeDataState
                                -- remembered as the first fight on show, not a page number,
                                -- so the same fights stay up when the column count changes
                                dataState.fightTop = dataState.fightTop or {}
                                local top = dataState.fightTop[bossKey] or 1
                                local page = math.max(1, math.min(pages, math.floor((top - 1) / perPage) + 1))
                                local first = (page - 1) * perPage + 1
                                dataState.fightTop[bossKey] = first
                                local last = math.min(#fights, page * perPage)

                                local fightsHeader = self:CreateFontString(detailsCard, "OVERLAY", nil, 10)
                                fightsHeader:SetPoint("TOPLEFT", detailsCard, "TOPLEFT", 10, detailY)
                                if pages > 1 then
                                    fightsHeader:SetText(string.format(RCL["Fights %d-%d of %d - click to edit, X to delete:"], first, last, #fights))
                                else
                                    fightsHeader:SetText(string.format(RCL["All %d Fights - click to edit, X to delete:"], #fights))
                                end
                                fightsHeader:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])

                                if pages > 1 then
                                    -- pager, right of the same line: first, previous, "3 / 17", next, last
                                    local function PageButton(label, target, tip)
                                        local b = self.UI:CreateStyledButton(detailsCard, label, 26, 18)
                                        if target < 1 or target > pages or target == page then
                                            b:EnableMouse(false)
                                            b:SetAlpha(0.35)
                                        else
                                            b:SetScript("OnClick", function()
                                                dataState.fightTop[bossKey] = (target - 1) * perPage + 1
                                                RC:ShowSidebarExecuteSettings(frame, true)
                                            end)
                                            b:HookScript("OnEnter", function(btn)
                                                GameTooltip:SetOwner(btn, "ANCHOR_TOP")
                                                GameTooltip:SetText(tip)
                                                GameTooltip:Show()
                                            end)
                                            b:HookScript("OnLeave", function() GameTooltip:Hide() end)
                                        end
                                        return b
                                    end
                                    local lastBtn = PageButton(">>", pages, RCL["Last page"])
                                    lastBtn:SetPoint("TOPRIGHT", detailsCard, "TOPRIGHT", -8, detailY + 4)
                                    local nextBtn = PageButton(">", page + 1, RCL["Next page"])
                                    nextBtn:SetPoint("RIGHT", lastBtn, "LEFT", -4, 0)
                                    local pageText = self:CreateFontString(detailsCard, "OVERLAY", nil, 10)
                                    pageText:SetPoint("RIGHT", nextBtn, "LEFT", -8, 0)
                                    pageText:SetText(string.format("%d / %d", page, pages))
                                    pageText:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])
                                    local prevBtn = PageButton("<", page - 1, RCL["Previous page"])
                                    prevBtn:SetPoint("RIGHT", pageText, "LEFT", -8, 0)
                                    local firstBtn = PageButton("<<", 1, RCL["First page"])
                                    firstBtn:SetPoint("RIGHT", prevBtn, "LEFT", -4, 0)
                                    detailY = detailY - 20
                                else
                                    detailY = detailY - 14
                                end

                                -- column titles, once per column of cells
                                -- (placed with the cells, by FightGrid.Place below)
                                local usedCols = math.max(1, math.min(cols, math.ceil((last - first + 1) / FightGrid.ROWS)))
                                local heads = {}
                                for c = 1, usedCols do heads[c] = FightGrid.Head(c, detailsCard) end
                                for c = usedCols + 1, #FightGrid.heads do FightGrid.heads[c]:Hide() end
                                local headY = detailY
                                detailY = detailY - 14
                                local displayStdDev = 0
                                if validCount >= 3 then
                                    local variance = 0
                                    for _, t in ipairs(fightTimes) do
                                        variance = variance + (t - avgTime)^2
                                    end
                                    displayStdDev = math.sqrt(variance / validCount)
                                end

                                local used = 0
                                for i = first, last do
                                    local fight = fights[i]
                                    if fight then
                                        used = used + 1
                                        local slot = i - first
                                        local row = slot % FightGrid.ROWS
                                        local fightTime = fight.totalFightTime or 0
                                        local isOutlier = false
                                        if displayStdDev > 0 and fightTime > 0 then
                                            isOutlier = math.abs((fightTime - avgTime) / displayStdDev) > threshold
                                        end
                                        local cell = FightGrid.Acquire(used, detailsCard)
                                        cell.slot = slot
                                        FightGrid.Fill(cell, frame, fight,
                                            entry.fightKeys and entry.fightKeys[i] or entry.bossKey, i, row, isOutlier)
                                    end
                                end
                                FightGrid.Release(used + 1)
                                -- the columns share the card's whole width
                                detailsCard._grid = { cols = cols, heads = heads, headY = headY,
                                                      top = detailY, used = used }
                                FightGrid.owner = detailsCard
                                FightGrid.Place(detailsCard, CardWidth())
                                -- the first column is the fullest one
                                detailY = detailY - math.min(FightGrid.ROWS, last - first + 1) * FightGrid.ROW_H

                                -- A wider or narrower window: the page on show stretches
                                -- with it as it moves. If a different number of columns
                                -- now fits, rebuild for that - but only when the count
                                -- really changes and only once the drag has paused.
                                detailsCard._cols = cols
                                detailsCard:SetScript("OnSizeChanged", function(card, w)
                                    if FightGrid.owner ~= card then return end
                                    FightGrid.Place(card, (w and w > 0) and w or CardWidth())
                                    if card._colTimer then card._colTimer:Cancel(); card._colTimer = nil end
                                    if ColumnsNow() == card._cols then return end
                                    card._colTimer = C_Timer.NewTimer(0.25, function()
                                        card._colTimer = nil
                                        if card:IsVisible() and ColumnsNow() ~= card._cols then
                                            RC:ShowSidebarExecuteSettings(frame, true)
                                        end
                                    end)
                                end)

                                detailY = detailY - 8

                                local cardHeight = math.abs(detailY)
                                detailsCard:SetHeight(cardHeight)

                                yPos = yPos - cardHeight - 5
                            end
                        end

                        yPos = yPos - 5
                    end
                end

            end

        elseif currentTab == "advanced" and currentMode == "intelligent" then
            local learnCard = self:CreateSettingsCard(parent, yPos, RCL["Learning"])
            cardY = -32

            local outlierLabel = self:CreateFontString(learnCard, "OVERLAY", nil, 11)
            outlierLabel:SetPoint("TOPLEFT", learnCard, "TOPLEFT", 14, cardY)
            outlierLabel:SetText(RCL["Outlier Detection (Std Devs):"])
            outlierLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 25

            if not self.executeCalculator.mlConfig then
                self.executeCalculator.mlConfig = { outlierThreshold = 2.0 }
            end
            local currentOutlier = self.executeCalculator.mlConfig.outlierThreshold or 2.0
            local outlierSlider = self.UI:CreateSettingSlider(learnCard, 1.5, 4.0, currentOutlier, 0.1, 14, cardY, string.format("%.1f", currentOutlier), function(slider, value)
                value = math.floor(value * 10 + 0.5) / 10
                RC.executeCalculator.mlConfig.outlierThreshold = value
                slider.Text:SetText(string.format("%.1f", value))
            end)
            outlierSlider:SetScript("OnMouseUp", function()
                RC:SaveExecuteSettings()
            end)
            cardY = cardY - 50

            local outlierInfo = self:CreateFontString(learnCard, "OVERLAY", nil, 10)
            outlierInfo:SetPoint("TOPLEFT", learnCard, "TOPLEFT", 14, cardY)
            outlierInfo:SetText(RCL["Lower = stricter filtering. Default: 2.0"])
            outlierInfo:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 25

            learnCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - learnCard:GetHeight() - 12

            -- RC.Profiler always exists (Core_Stubs no-op stub); this card is
            -- only meaningful with the real one from Readycheck_Debug.
            if RC.Profiler and not RC.Profiler.isStub then
            local debugCard = self:CreateSettingsCard(parent, yPos, RCL["Debug"])
            cardY = -32

            local isDebugEnabled = self.debugCategories and self.debugCategories["execute"] and self.debugCategories["execute"].enabled or false
            local debugCheck = self.UI:CreateSettingCheckbox(debugCard, cardY, "Enable debug output", isDebugEnabled, function(cb)
                local newState = cb:GetChecked()
                if RC.debugCategories and RC.debugCategories["execute"] then
                    RC.debugCategories["execute"].enabled = newState
                end
                RC:ForceCheckboxUpdate(cb, newState)
            end)
            cardY = cardY - 28

            debugCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - debugCard:GetHeight() - 12
            end

        elseif currentTab == "multipliers" and currentMode == "classic" then
            local multCard = self:CreateSettingsCard(parent, yPos, RCL["Global multiplier"])
            cardY = -32

            if not self.executeCalculator.classicMultipliers then
                self.executeCalculator.classicMultipliers = { global = 1.8 }
            end
            local globalMult = self.executeCalculator.classicMultipliers.global or 1.8

            local multLabel = self:CreateFontString(multCard, "OVERLAY", nil, 11)
            multLabel:SetPoint("TOPLEFT", multCard, "TOPLEFT", 14, cardY)
            multLabel:SetText(RCL["Execute DPS Multiplier:"])
            multLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 25

            local globalMultSlider = self.UI:CreateSettingSlider(multCard, 1.2, 3.0, globalMult, 0.1, 14, cardY, string.format("%.1fx", globalMult), function(slider, value)
                value = math.floor(value * 10) / 10
                RC.executeCalculator.classicMultipliers.global = value
                slider.Text:SetText(string.format("%.1fx", value))
            end)
            globalMultSlider:SetScript("OnMouseUp", function()
                RC:SaveExecuteSettings()
            end)
            cardY = cardY - 50

            local multHelp = self:CreateFontString(multCard, "OVERLAY", nil, 10)
            multHelp:SetPoint("TOPLEFT", multCard, "TOPLEFT", 14, cardY)
            multHelp:SetText(RCL["1.8x = 80% more damage below 20% HP"])
            multHelp:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 25

            multCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - multCard:GetHeight() - 12

            local bossCard = self:CreateSettingsCard(parent, yPos, RCL["Per-boss overrides"])
            cardY = -32

            local bossInfo = self:CreateFontString(bossCard, "OVERLAY", nil, 10)
            bossInfo:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 14, cardY)
            bossInfo:SetText(RCL["Set different multipliers for specific bosses"])
            bossInfo:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
            cardY = cardY - 25

            local perBossBtn = self.UI:CreateStyledButton(bossCard, RCL["Configure Per-Boss Multipliers"], 200, 26)
            perBossBtn:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 14, cardY)
            perBossBtn:SetScript("OnClick", function()
                RC:ShowClassicBossMultipliers(frame)
            end)
            cardY = cardY - 35

            bossCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - bossCard:GetHeight() - 12

        elseif currentTab == "exclusions" then
            local dc = self.executeCalculator and self.executeCalculator.dataCollection
            if not dc then
                dc = { disabled = false, disabledBosses = {} }
                if self.executeCalculator then self.executeCalculator.dataCollection = dc end
            end
            if not dc.disabledBosses then dc.disabledBosses = {} end

            local RAID_SHORT = {
                ["Molten Core"]            = "MC",
                ["Blackwing Lair"]         = "BWL",
                ["Temple of Ahn'Qiraj"]    = "AQ40",
                ["Naxxramas"]              = "Naxx",
                ["Onyxia's Lair"]          = "Onyxia",
                ["Zul'Gurub"]              = "ZG",
                ["Ruins of Ahn'Qiraj"]     = "AQ20",
            }
            local RAID_ORDER = {
                "Molten Core", "Blackwing Lair", "Temple of Ahn'Qiraj",
                "Naxxramas", "Onyxia's Lair", "Zul'Gurub", "Ruins of Ahn'Qiraj",
            }

            local validRaids = {}
            for _, rn in ipairs(RAID_ORDER) do
                if self.raidData and self.raidData[rn] and self.raidData[rn].bosses
                        and #self.raidData[rn].bosses > 0 then
                    validRaids[#validRaids + 1] = rn
                end
            end

            local selRaid = frame.executeExclusionsRaid
            local selValid = false
            for _, rn in ipairs(validRaids) do
                if rn == selRaid then selValid = true; break end
            end
            if not selValid then
                selRaid = validRaids[1] or ""
                frame.executeExclusionsRaid = selRaid
            end

            if #validRaids > 0 then
                -- Raid segmented control: the framework tab row (flat tabs,
                -- 1px gaps, selected tab wears the active look).
                local raidTabs = {}
                for i, rn in ipairs(validRaids) do
                    raidTabs[i] = { key = rn, label = RAID_SHORT[rn] or rn }
                end
                RC.UI:CreateTabGroup(parent, {
                    tabs      = raidTabs,
                    selected  = selRaid,
                    y         = yPos,
                    inset     = 10,
                    height    = 24,
                    tabHeight = 22,
                    fontSize  = 10,
                    onClick   = function(key)
                        frame.executeExclusionsRaid = key
                        RC:ShowSidebarExecuteSettings(frame, true)
                    end,
                })
                yPos = yPos - 32

                local raidBosses = self.raidData and self.raidData[selRaid]
                                   and self.raidData[selRaid].bosses or {}
                local bossCard = self:CreateSettingsCard(parent, yPos, selRaid)
                local bcy = -32

                local descFs = self:CreateFontString(bossCard, "OVERLAY", nil, 10)
                descFs:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 14, bcy)
                descFs:SetPoint("RIGHT",   bossCard, "RIGHT",  -14, 0)
                descFs:SetText(RCL["Uncheck a boss to stop recording fight data for it. All bosses are tracked by default."])
                descFs:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                bcy = bcy - 24

                local allBtn = self.UI:CreateStyledButton(bossCard, RCL["Check All"],   80, 22)
                allBtn:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 14, bcy)
                allBtn:SetScript("OnClick", function()
                    for _, bn in ipairs(raidBosses) do
                        dc.disabledBosses[selRaid .. "_" .. bn] = nil
                    end
                    RC:SaveExecuteSettings()
                    RC:ShowSidebarExecuteSettings(frame, true)
                end)
                local noneBtn = self.UI:CreateStyledButton(bossCard, RCL["Uncheck All"], 90, 22)
                noneBtn:SetPoint("LEFT", allBtn, "RIGHT", 6, 0)
                noneBtn:SetScript("OnClick", function()
                    for _, bn in ipairs(raidBosses) do
                        dc.disabledBosses[selRaid .. "_" .. bn] = true
                    end
                    RC:SaveExecuteSettings()
                    RC:ShowSidebarExecuteSettings(frame, true)
                end)
                bcy = bcy - 30

                for _, bossName in ipairs(raidBosses) do
                    local excKey = selRaid .. "_" .. bossName
                    local isTracked = dc.disabledBosses[excKey] ~= true
                    local cb = self.UI:CreateCheckbox(bossCard, bossName, isTracked)
                    cb:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 14, bcy)
                    local capturedKey = excKey
                    cb:SetScript("OnClick", function(cbBtn)
                        local newState = cbBtn:GetChecked()
                        RC:ForceCheckboxUpdate(cbBtn, newState)
                        dc.disabledBosses[capturedKey] = newState and nil or true
                        RC:SaveExecuteSettings()
                        local MS = RC.MeshSync
                        if MS and MS:IsEnabled() then
                            local cc = MS:GetCharConfig()
                            if cc and cc.autoBroadcast and cc.syncCategories
                                    and cc.syncCategories["executeCalc"] then
                                MS:Push("executeCalc", nil, nil, true)
                            end
                        end
                    end)
                    bcy = bcy - 22
                end
                bcy = bcy - 8
                bossCard:SetContentHeight(math.abs(bcy))
                yPos = yPos - bossCard:GetHeight() - 12
            end

        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end

    -- TTK Display page: Behavior / Look / Text / Animation / Position on
    -- db.ttkDisplay. Old tab keys (display, appearance) still open the
    -- right tab. The preview is the HUD itself (TTK:BuildDisplayFrame +
    -- StyleDisplay) filled with a sample fight.
    local TTK_PV_W, TTK_PV_H = 106, 56   -- update sizes the canvas to the HUD
    local TTK_NONE = { style = "none" }
    local TTK_SAMPLES = {
        fight = { boss = "Patchwerk", exp = "3:05", expSec = 185, conf = 82, left = "2:41", leftSec = 161, hp = 64, pace = "6% faster", paceKey = "paceFaster" },
        slow  = { boss = "Thaddius", exp = "4:10", expSec = 250, conf = 71, left = "3:52", leftSec = 232, hp = 81, pace = "9% slower", paceKey = "paceSlower" },
        new   = { boss = "Sapphiron", nodata = true, left = "--:--" },
    }
    local function TTKPreviewUpdate(canvas, P)
        local T = RC.TTKDisplay
        local f = P.store.hud
        if not (T and f) then return end
        local s = RC.db.ttkDisplay or {}
        T:StyleDisplay(f, s)
        local d = TTK_SAMPLES[P.mode or "fight"] or TTK_SAMPLES.fight
        f.header:SetText(d.boss)
        if d.nodata then
            f.predictedValue:SetText(RCL["No data"])
            local c = RC:GetColor("ttkDisplay", "labelText")
            f.predictedValue:SetTextColor(c.r, c.g, c.b, 1)
            f.realtimeValue:SetText(d.left)
            f.paceValue:SetText("--")
        else
            -- a time format set: the sample's times read through it, as the HUD's do
            local exp, left = d.exp, d.left
            if type(s.formats) == "table" and s.formats.time then exp, left = T:FormatTime(d.expSec), T:FormatTime(d.leftSec) end
            f.predictedValue:SetText(s.showConfidence ~= false and string.format("%s (%d%%)", exp, d.conf) or exp)
            f.realtimeValue:SetText(s.showHealthPercent ~= false and string.format("%s (%d%%)", left, d.hp) or left)
            f.paceValue:SetText(d.pace)
            local c = RC:GetColor("ttkDisplay", d.paceKey)
            f.paceValue:SetTextColor(c.r, c.g, c.b, 1)
        end
        local K = RC._rpk
        -- the HUD at its real size; the canvas is its box, the strip scales it
        if K then K.FitStrip(P, P.store.holder, f:GetWidth() or 120, f:GetHeight() or 70, 6) end
    end

    function RC:ShowSidebarTTKSettings(frame)
        local keepScroll = frame._ttkKeepScroll
        self:ClearSidebarContent(self.sidebarConfigFrame, keepScroll)
        frame._ttkKeepScroll = nil
        local parent = frame.scrollChild
        local yPos = -20
        local K = RC._rpk

        if not self.db.ttkDisplay then
            self.db.ttkDisplay = {
                enabled = false, locked = false, showBackground = true,
                width = 100, height = 50, anchorPoint = "TOP", xOffset = 0, yOffset = -100,
                fontSize = 14, headerFontSize = 10, showConfidence = true,
                showHealthPercent = true, showOutOfCombat = false,
                showLabels = false, shortLabels = false, centerText = true
            }
        end
        local s = self.db.ttkDisplay
        local TTK = self.TTKDisplay

        local P
        if TTK and TTK.BuildDisplayFrame then
            P = self.UI:DeclarePreview({
                key = "ttk.display", title = RCL["TTK Display"], width = TTK_PV_W, height = TTK_PV_H,
                modes = { { id = "fight", label = RCL["Faster"] }, { id = "slow", label = RCL["Slower"] }, { id = "new", label = RCL["No history"] } },
                build = function(canvas, PP)
                    local holder = CreateFrame("Frame", nil, canvas)
                    holder:SetPoint("CENTER", canvas, "CENTER", 0, 0)
                    PP.store.holder = holder
                    PP.store.hud = RC.TTKDisplay:BuildDisplayFrame(holder)
                    PP.store.hud:SetPoint("CENTER", holder, "CENTER", 0, 0)
                end,
                update = TTKPreviewUpdate,
                replay = function(canvas, PP)
                    local ss = RC.db.ttkDisplay or {}
                    K.Replay(PP.store, canvas, { { frame = PP.store.hud, inSpec = ss.showAnim or TTK_NONE, outSpec = ss.hideAnim or TTK_NONE } })
                end,
            })
        end
        local function Replay() if P then P.Replay() end end

        local function Look()
            if TTK and TTK.UpdateTTKDisplayAppearance then TTK:UpdateTTKDisplayAppearance() end
        end
        local function Save() self:SaveConfigurationToProfile() end

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["TTK Display"],
            RCL["On-screen time-to-kill overlay during boss fights"], "Interface\\Icons\\INV_Misc_PocketWatch_01")
        yPos = newY

        local currentTab = K.Tab(frame.ttkSettingsTab, { display = "behavior", appearance = "look" }, "behavior")
        frame.ttkSettingsTab = currentTab

        local _, tabY = RC.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = {
                { key = "behavior",  label = RCL["Behavior"] },
                { key = "look",      label = RCL["Look"] },
                { key = "text",      label = RCL["Text"] },
                { key = "animation", label = RCL["Animation"] },
                { key = "position",  label = RCL["Position"] },
            },
            selected = currentTab,
            onClick = function(tk)
                frame.ttkSettingsTab = tk
                frame._ttkKeepScroll = true
                RC:ShowSidebarTTKSettings(frame)
            end,
            advance = 38,
        })
        yPos = tabY

        local function Finish(card, cy)
            card:SetContentHeight(math.abs(cy))
            yPos = yPos - card:GetHeight() - 12
        end
        local function Check(card, cy, label, get, set, x)
            local cb = self.UI:CreateCheckbox(card, label, get())
            cb:SetPoint("TOPLEFT", card, "TOPLEFT", x or 14, cy)
            cb:SetScript("OnClick", function(c)
                local v = c:GetChecked() and true or false
                self:ForceCheckboxUpdate(c, v)
                set(v)
                Save()
            end)
            self:RegisterCheckboxWithData(cb, get, set)
            return cy - 28, cb
        end

        if currentTab == "behavior" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["TTK display"])
            local cy = -32
            local enableCb
            cy, enableCb = Check(card, cy, RCL["Enable TTK display"], function() return s.enabled end, function(v)
                s.enabled = v
                if TTK then
                    if v then
                        TTK:InitializeTTKDisplay()
                        if s.showOutOfCombat and TTK.ttkFrame then TTK:UpdateDisplay(); TTK.ttkFrame:Show() end
                    elseif TTK.ttkFrame then
                        TTK.ttkFrame:Hide()
                    end
                end
                if self.UpdateTTKDisplayActive then self:UpdateTTKDisplayActive() end
            end)
            local enableMark = self.UI:MarkCard(card)
            cy = Check(card, cy, RCL["Show display out of combat"], function() return s.showOutOfCombat end, function(v)
                s.showOutOfCombat = v
                if TTK and TTK.ttkFrame and s.enabled then
                    if v then TTK:UpdateDisplay(); TTK.ttkFrame:Show()
                    elseif not UnitAffectingCombat("player") then TTK.ttkFrame:Hide() end
                end
            end)
            cy = Check(card, cy, RCL["Show confidence % for predicted TTK"], function() return s.showConfidence ~= false end, function(v) s.showConfidence = v end)
            cy = Check(card, cy, RCL["Show boss health % with real-time TTK"], function() return s.showHealthPercent ~= false end, function(v) s.showHealthPercent = v end)
            cy = Check(card, cy, RCL["Show pace (faster or slower than usual)"], function() return s.showPace ~= false end, function(v) s.showPace = v; Look() end)
            cy = K.Desc(card, cy + 4, RCL["Expected is the usual kill time for this boss, Time left the shared estimate the reminders use, Pace this pull against the usual one."])
            self.UI:BindDependents(enableCb, self.UI:CardSince(card, enableMark))
            Finish(card, cy)
            local function LookSaved() Look() end
            yPos = self.UI:FrameVisibilityCard(parent, yPos, s, LookSaved) + 3


        elseif currentTab == "look" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Size & font"])
            local cy = -32
            cy = Check(card, cy, RCL["Show background"], function() return s.showBackground ~= false end, function(v)
                s.showBackground = v
                if TTK and TTK.UpdateTTKDisplayBackground then TTK:UpdateTTKDisplayBackground() end
            end)
            cy = Check(card, cy, RCL["Show title bar (boss name)"], function() return s.showHeader ~= false end, function(v) s.showHeader = v; Look() end)
            cy = K.Slider(card, cy, RCL["Width"], 100, 300, s.width or 120, 5, K.Px, function(v) s.width = v; Look() end)
            cy = K.Slider(card, cy, RCL["Height"], 40, 120, s.height or 70, 5, K.Px, function(v) s.height = v; Look() end)
            cy = K.Desc(card, cy + 4, RCL["The frame grows taller by itself when the rows would not fit the font."])
            cy = K.Slider(card, cy, RCL["Border thickness"], 0, 4, tonumber(s.borderSize) or 1, 1, K.Px, function(v) s.borderSize = v; Look() end)
            cy = K.ThemeColor(card, cy, "ttkDisplay", "background", RCL["Background"], Look, { alpha = true })
            cy = K.ThemeColor(card, cy, "ttkDisplay", "border", RCL["Border"], Look)
            Finish(card, cy - 6)
            yPos = self.UI:FrameChromeCard(parent, yPos, s, Look,
                { title = RCL["Shadow and glow"], fields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } }) + 3

        elseif currentTab == "text" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Text"])
            local cy = -32
            cy = Check(card, cy, RCL["Show labels (Expected/Time left/Pace)"], function() return (s.showLabels == true) or (s.showLabels == nil) end, function(v)
                s.showLabels = v; Look()
                frame._ttkKeepScroll = true
                RC:ShowSidebarTTKSettings(frame)
            end)
            local showLabels = (s.showLabels == true) or (s.showLabels == nil)
            local shortCb
            cy, shortCb = Check(card, cy, RCL["Use short labels (Exp/Left)"], function() return s.shortLabels == true end, function(v) s.shortLabels = v; Look() end, 30)
            if not showLabels then self.UI:SetWidgetEnabled(shortCb, false) end
            cy = Check(card, cy, RCL["Center-align text"], function() return s.centerText == true end, function(v) s.centerText = v; Look() end)
            cy = K.Font(card, cy, s, "valueFont", "fontSize", { size = 14, shadow = true }, RCL["Times"], "3:05 (82%)  2:41", Look, 8, 24)
            do
                -- how the times read (the customization standard; unset = 3:05)
                local fg, fs2 = self.UI:CustomAccess(s, "formats", "time", function() Save() Look() end)
                local cw = card:GetWidth() or 0
                local fp = self.UI:CreateTextFormatPicker(card, { label = RCL["Time format"], width = (cw > 240) and math.min(460, cw - 28) or 420,
                    get = fg, set = fs2, kinds = { time = true }, defaults = TTK and TTK.TIME_FORMAT,
                    sample = function(spec) return RC.UI:FormatText(spec, TTK and TTK.TIME_FORMAT, { value = 185 }, { value = "time" }, "value") end })
                fp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                cy = cy - fp:GetHeight() - 8
            end
            cy = K.Font(card, cy, s, "labelFont", nil, { size = (s.fontSize or 14) - 2, shadow = true }, RCL["Labels"], "Expected:  Time left:  Pace:", Look, 6, 22)
            cy = K.Desc(card, cy, RCL["Until you set a label size the labels stay 2 pt under the times."])
            cy = K.Font(card, cy, s, "headerFont", "headerFontSize", { size = 10, shadow = true }, RCL["Title (boss name)"], "Patchwerk", Look, 8, 18)
            cy = K.ThemeColor(card, cy, "ttkDisplay", "headerText", RCL["Boss name"], Look)
            cy = K.ThemeColor(card, cy, "ttkDisplay", "labelText", RCL["Labels and untrusted times"], Look)
            cy = K.ThemeColor(card, cy, "ttkDisplay", "predictedText", RCL["Expected"], Look)
            cy = K.ThemeColor(card, cy, "ttkDisplay", "realtimeText", RCL["Time left"], Look)
            cy = K.ThemeColor(card, cy, "ttkDisplay", "paceFaster", RCL["Pace: faster"], Look)
            cy = K.ThemeColor(card, cy, "ttkDisplay", "paceSlower", RCL["Pace: slower"], Look)
            cy = K.ThemeColor(card, cy, "ttkDisplay", "paceNeutral", RCL["Pace: on pace"], Look)
            Finish(card, cy - 6)

            -- where each text sits (the customization standard: the choices
            -- above make the defaults, a position set here goes on top)
            local pc = self:CreateSettingsCard(parent, yPos, RCL["Text positions"])
            local py = -32
            local cw = pc:GetWidth() or 0
            local W = (cw > 240) and math.min(460, cw - 28) or 420
            local function Saved() Save() Look() end
            local sample = P and P.store and P.store.hud
            for _, e in ipairs(TTK and TTK.TEXT_ELEMENTS or {}) do
                local ag, as = self.UI:CustomAccess(s, "anchors", e.key, Saved)
                local targets = {}
                for _, t in ipairs(TTK.TEXT_TARGETS) do if t.value ~= e.key then targets[#targets + 1] = t end end
                local g = self.UI:CreateTextElement(pc, { label = e.label, key = e.key, width = W,
                    anchorGet = ag, anchorSet = as, targets = targets,
                    defaultTargetLabel = RCL["Where the layout puts it"],
                    anchorDefaults = function() return TTK:TextAnchorDefault(e.key, sample) end })
                g:SetPoint("TOPLEFT", pc, "TOPLEFT", 14, py)
                py = py - g:GetHeight() - 14
            end
            py = K.Desc(pc, py, RCL["Reset puts a text back where the label and centring choices above put it."])
            Finish(pc, py - 6)

        elseif currentTab == "animation" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Animation"])
            local cy = -32
            cy = K.Anim(card, cy, s, "showAnim", { style = "none", duration = 0.3 }, RCL["When it appears"], "in", Replay)
            cy = K.Anim(card, cy, s, "hideAnim", { style = "none", duration = 0.3 }, RCL["When it goes"], "out", Replay)
            cy = K.Desc(card, cy, RCL["Appearance > Motion can turn every animation off or speed them all up."])
            Finish(card, cy)

        elseif currentTab == "position" then
            local posCard = self:CreateSettingsCard(parent, yPos, RCL["Position"])
            local cardY = -32
            cardY = Check(posCard, cardY, RCL["Lock position (right-click to toggle)"], function() return s.locked end, function(v)
                s.locked = v
                if TTK and TTK.ttkFrame then TTK.ttkFrame:SetMovable(not v) end
            end)

            local ttkPosLabel = self:CreateFontString(posCard, "OVERLAY", nil, 11)
            ttkPosLabel:SetPoint("TOPLEFT", posCard, "TOPLEFT", 14, cardY)
            ttkPosLabel:SetText(RCL["Offset:"])
            ttkPosLabel:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])
            local ttkXLabel = self:CreateFontString(posCard, "OVERLAY", nil, 11)
            ttkXLabel:SetPoint("LEFT", ttkPosLabel, "RIGHT", 10, 0)
            ttkXLabel:SetText("X:")
            ttkXLabel:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
            local ttkXInput = self.UI:CreateBackedEditBox(posCard, { width = 50, height = 22, fontSize = 11, maxLetters = 6, insets = 5 })
            ttkXInput:SetPoint("LEFT", ttkXLabel, "RIGHT", 5, 0)
            ttkXInput:SetNumeric(false)
            ttkXInput:SetText(tostring(s.xOffset or 0))
            local ttkYLabel = self:CreateFontString(posCard, "OVERLAY", nil, 11)
            ttkYLabel:SetPoint("LEFT", ttkXInput, "RIGHT", 10, 0)
            ttkYLabel:SetText("Y:")
            ttkYLabel:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
            local ttkYInput = self.UI:CreateBackedEditBox(posCard, { width = 50, height = 22, fontSize = 11, maxLetters = 6, insets = 5 })
            ttkYInput:SetPoint("LEFT", ttkYLabel, "RIGHT", 5, 0)
            ttkYInput:SetNumeric(false)
            ttkYInput:SetText(tostring(s.yOffset or -100))
            local applyTtkPosBtn = self.UI:CreateStyledButton(posCard, RCL["Apply Position"], 110, 22)
            applyTtkPosBtn:SetPoint("LEFT", ttkYInput, "RIGHT", 10, 0)
            applyTtkPosBtn:SetScript("OnClick", function()
                local newX = tonumber(ttkXInput:GetText()) or 0
                local newY = tonumber(ttkYInput:GetText()) or -100
                local f = TTK and TTK.ttkFrame
                if f and RC.Position.IsBound(f) then
                    RC.Position.SetFrame(f, newX, newY)
                else
                    s.xOffset = newX
                    s.yOffset = newY
                    s.anchorPoint = "TOP"
                    s.centred = true
                    self:SaveConfigurationToProfile()
                end
            end)
            cardY = cardY - 34

            local testTtkBtn = self.UI:CreateStyledButton(posCard, RCL["Test Display"], 120, 24)
            testTtkBtn:SetPoint("TOPLEFT", posCard, "TOPLEFT", 14, cardY)
            if TTK and TTK.testDisplayActive then
                self.UI:SetButtonText(testTtkBtn, "Hide Test Display")
            end
            testTtkBtn:SetScript("OnClick", function()
                if not TTK then return end
                TTK:InitializeTTKDisplay()
                local f = TTK.ttkFrame
                if not f then return end
                if TTK.testDisplayActive then
                    TTK.testDisplayActive = false
                    if TTK.UpdateActive then TTK:UpdateActive() end
                    if f:IsShown() then f:Hide() end
                    RC.UI:SetButtonText(testTtkBtn, "Test Display")
                else
                    f.header:SetText(RCL["Test Boss"])
                    f.predictedValue:SetText("2:45 (75%)")
                    f.realtimeValue:SetText("2:30 (65%)")
                    TTK.testDisplayActive = true
                    if TTK.UpdateActive then TTK:UpdateActive() end
                    f:Show()
                    RC.UI:SetButtonText(testTtkBtn, "Hide Test Display")
                end
            end)
            cardY = cardY - 30
            cardY = K.Desc(posCard, cardY, RCL["Drag the display while it is unlocked, or place it with Edit Mode (/rc moveui)."])
            Finish(posCard, cardY)
            yPos = self.UI:FrameLayerCard(parent, yPos, s, Look) + 3
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
        if keepScroll then self:RestoreScrollPosition(self.sidebarConfigFrame) end
    end

    function RC:ShowClassicBossMultipliers(frame)
        self:ClearSidebarContent(self.sidebarConfigFrame)
        local parent = frame.scrollChild
        local yPos = -20

        local backBtn = self.UI:CreateBackButton(parent, "Back", 65, 22)
        backBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 10, yPos)
        -- Omits preserveScroll on purpose: navigating away from Per-Boss
        -- Multipliers should reset scroll, unlike in-page tab/dropdown
        -- changes elsewhere on this page which pass true.
        backBtn:SetScript("OnClick", function()
            RC:ShowSidebarExecuteSettings(frame)
        end)

        local headerText = self:CreateFontString(parent, "OVERLAY", nil, 14)
        headerText:SetPoint("LEFT", backBtn, "RIGHT", 10, 0)
        headerText:SetText(RCL["Per-Boss Multipliers"])
        headerText:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])

        yPos = yPos - 30

        if not self.executeCalculator.classicMultipliers then
            self.executeCalculator.classicMultipliers = { global = 1.8, perBoss = {} }
        end
        if not self.executeCalculator.classicMultipliers.perBoss then
            self.executeCalculator.classicMultipliers.perBoss = {}
        end

        local globalDefault = self.executeCalculator.classicMultipliers.global or 1.8

        local infoCard = self:CreateSettingsCard(parent, yPos, RCL["Settings"])
        local cardY = -32

        local globalText = self:CreateFontString(infoCard, "OVERLAY", nil, 11)
        globalText:SetPoint("TOPLEFT", infoCard, "TOPLEFT", 14, cardY)
        globalText:SetText(string.format(RCL["Global Default: |cffffd700%.1fx|r  (Bosses without custom setting use this)"], globalDefault))
        globalText:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
        cardY = cardY - 25

        infoCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - infoCard:GetHeight() - 15

        local raids = {
            {key = "MC", name = "Molten Core", short = "MC"},
            {key = "BWL", name = "Blackwing Lair", short = "BWL"},
            {key = "AQ40", name = "Temple of Ahn'Qiraj", short = "AQ40"},
            {key = "Naxx", name = "Naxxramas", short = "Naxx"}
        }

        if not frame.classicMultiplierTab then
            frame.classicMultiplierTab = "MC"
        end

        local tabX = 10
        for _, raid in ipairs(raids) do
            local isSelected = (frame.classicMultiplierTab == raid.key)

            local tabBtn = self.UI:CreateStyledButton(parent, raid.short, 68, 24)
            tabBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", tabX, yPos)

            if isSelected then
                tabBtn.isConfigured = true
                local _cb = RC:GetColor("buttons", "configuredBackground")
                tabBtn.bg:SetVertexColor(_cb.r, _cb.g, _cb.b, 1)
                tabBtn.text:SetTextColor(TEXT.green[1], TEXT.green[2], TEXT.green[3])
            end

            local thisRaidKey = raid.key
            tabBtn:SetScript("OnClick", function()
                frame.classicMultiplierTab = thisRaidKey
                RC:ShowClassicBossMultipliers(frame)
            end)

            tabX = tabX + 72
        end

        yPos = yPos - 35

        local selectedRaid = nil
        for _, raid in ipairs(raids) do
            if raid.key == frame.classicMultiplierTab then
                selectedRaid = raid.name
                break
            end
        end

        if not selectedRaid then
            selectedRaid = "Molten Core"
        end

        local bossCard = self:CreateSettingsCard(parent, yPos, selectedRaid)
        cardY = -32

        local raidInfo = self.raidData and self.raidData[selectedRaid]
        local bossList = raidInfo and raidInfo.bosses

        if bossList and #bossList > 0 then
            for _, bossName in ipairs(bossList) do
                local bossKey = selectedRaid .. "_" .. bossName
                local currentMultiplier = self.executeCalculator.classicMultipliers.perBoss[bossKey]
                local displayValue = currentMultiplier or globalDefault

                local rowFrame = CreateFrame("Frame", nil, bossCard)
                rowFrame:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 10, cardY)
                rowFrame:SetSize(bossCard:GetWidth() - 20, 24)

                local bossText = self:CreateFontString(rowFrame, "OVERLAY", nil, 10)
                bossText:SetPoint("LEFT", rowFrame, "LEFT", 5, 0)
                bossText:SetWidth(95)
                bossText:SetJustifyH("LEFT")
                bossText:SetText(bossName)
                if currentMultiplier then
                    bossText:SetTextColor(TEXT.green[1], TEXT.green[2], TEXT.green[3])
                else
                    bossText:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
                end

                local multiplierSlider = self.UI:CreateSlider(rowFrame, 1.2, 3.0, displayValue, 0.1)
                multiplierSlider:SetPoint("LEFT", bossText, "RIGHT", 5, 0)
                multiplierSlider:SetWidth(100)
                multiplierSlider.Text:SetText(string.format("%.1fx", displayValue))

                local thisBossKey = bossKey
                local thisBossText = bossText
                local thisRaidName = selectedRaid
                local thisBossName = bossName

                -- Apply live while dragging; persist once on mouse-up (like
                -- the global slider) - SetClassicMultiplier saves via
                -- SaveExecuteSettings, which deep-copies the fight history.
                multiplierSlider:SetScript("OnValueChanged", function(slider, value)
                    value = math.floor(value * 10 + 0.5) / 10
                    RC.executeCalculator.classicMultipliers.perBoss[thisBossKey:gsub("|", "_")] = value
                    slider.Text:SetText(string.format("%.1fx", value))
                    thisBossText:SetTextColor(TEXT.green[1], TEXT.green[2], TEXT.green[3])
                end)
                multiplierSlider:SetScript("OnMouseUp", function(slider)
                    local value = math.floor(slider:GetValue() * 10 + 0.5) / 10
                    RC:SetClassicMultiplier(thisRaidName, thisBossName, value)
                end)

                local resetBtn = self.UI:CreateStyledButton(rowFrame, RCL["Reset"], 40, 18)
                resetBtn:SetPoint("LEFT", multiplierSlider, "RIGHT", 5, 0)
                if currentMultiplier then
                    resetBtn:SetScript("OnClick", function()
                        RC:ClearBossClassicMultiplier(thisRaidName, thisBossName)
                        RC:ShowClassicBossMultipliers(frame)
                    end)
                else
                    resetBtn:Disable()
                    resetBtn:SetAlpha(0.4)
                end

                cardY = cardY - 26
            end
        else
            local noDataText = self:CreateFontString(bossCard, "OVERLAY", nil, 11)
            noDataText:SetPoint("TOPLEFT", bossCard, "TOPLEFT", 14, cardY)
            noDataText:SetText(RCL["No boss data available for this raid"])
            noDataText:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
            cardY = cardY - 25
        end

        bossCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - bossCard:GetHeight() - 15

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end

