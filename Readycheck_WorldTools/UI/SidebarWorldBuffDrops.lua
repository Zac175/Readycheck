------------------------------------------------------------------------
-- Readycheck World - World Buff Drops
-- Sidebar page over the buff board's roster: which toons can still hand
-- in a head / heart (the quests are one-time per character) and which
-- already have. The data rides the board's WBUFF payload ("t" held,
-- "u" completed); WorldBuffSync owns detection and the wire, this file
-- only draws it.
-- (Was Readycheck_Testing\TestingWorldBuffDrops.lua until 2026-11-18,
-- Zac: "move all the testing stuff into the main addon".)
--
-- WHICH TOONS ARE LISTED (2026-11-18, Zac: "it shows that all my low lvls
-- and stuff can drop buffs which is true but i need maybe filtering with
-- like it only shows lvl 60s at the start"). Every character that has
-- not handed a head in "can drop", so a bank alt filled the list. The
-- list and the counts now take only toons of a lowest level, picked at
-- the top of the page: level 60 as it starts, lower steps, or everyone
-- (db.worldBuffTimers.dropsMinLevel; unset = 60, 1 = everyone). A toon
-- whose level is not known (an older build on it) is listed, with "?"
-- for its level, since it cannot be told from a 60.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local PAGE_ID  = "wt_wbdrops"
local ROW_H    = 22
local NAME_W   = 130
local LVL_W    = 34
local COL_W    = 96

-- the lowest level listed
local MIN_DEFAULT = 60
local MIN_CHOICES = { 60, 58, 55, 50, 40, 20, 1 }
local function Settings()
    local db = RC.db
    if not db then return nil end
    if type(db.worldBuffTimers) ~= "table" then db.worldBuffTimers = {} end
    return db.worldBuffTimers
end
local function MinLevel()
    local s = Settings()
    local v = s and tonumber(s.dropsMinLevel)
    if not v or v ~= v then return MIN_DEFAULT end
    return math.max(1, math.min(MIN_DEFAULT, math.floor(v)))
end
local function SetMinLevel(v)
    local s = Settings()
    if not s then return end
    v = tonumber(v)
    s.dropsMinLevel = (v and v ~= MIN_DEFAULT) and math.max(1, math.min(MIN_DEFAULT, math.floor(v))) or nil
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
end
local function MinLabel(v)
    if v >= MIN_DEFAULT then return RCL["Level 60 only"] end
    if v <= 1 then return RCL["Everyone"] end
    return string.format(RCL["Level %d and up"], v)
end
-- listed: at the lowest level or over it, or of a level nobody has told us
local function Listed(info, minLevel)
    local lvl = tonumber(info.level)
    return lvl == nil or lvl >= minLevel
end
RC.WBDropsMinLevel, RC.SetWBDropsMinLevel, RC.WBDropsListed = MinLevel, SetMinLevel, Listed

local HORDE_RACES = { Orc = true, Troll = true, Tauren = true, Scourge = true }

local function ClassColor(classFile)
    if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
        return RAID_CLASS_COLORS[classFile]
    end
    return nil
end

-- State of one turn-in column for one roster row.
-- Returns text, color name, rank (lower sorts first).
local function CellState(info, def)
    if def.horde and info.race and not HORDE_RACES[info.race] then
        return "-", "disabled", 9
    end
    if not info.dropped then
        -- Older build on that toon: it never reports completion.
        return "?", "gray", 8
    end
    if info.dropped[def.key] then
        return RCL["Dropped"], "orange", 5
    end
    if info.heads and info.heads[def.key] then
        return RCL["Ready (has head)"], "green", 1
    end
    return RCL["Can drop"], "yellow", 3
end

local panelTicker
local function StopTicker()
    if panelTicker then
        if panelTicker.Cancel then panelTicker:Cancel() end
        panelTicker = nil
    end
end

local function EnsureTicker()
    if panelTicker then return end
    local function tick()
        local outer = RC.sidebarConfigFrame
        if not outer or not outer:IsShown()
            or not RC.SidebarState or RC.SidebarState.selectedItem ~= PAGE_ID then
            StopTicker()
            return
        end
        if MouseIsOver(outer) then return end
        local compat = outer.compatFrame
        if not compat then return end
        RC:ShowSidebarWBDrops(compat, true)
    end
    if RC.Profiler and RC.Profiler.TrackTicker then
        panelTicker = RC.Profiler:TrackTicker("WorldTools:WBDrops", 2.0, tick)
    else
        panelTicker = C_Timer.NewTicker(2.0, tick)
    end
end

function RC:ShowSidebarWBDrops(frame, preserveScroll)
    self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
    local parent = frame.scrollChild
    if not parent then return end
    local WB = self.WorldBuffs
    local defs = (WB and WB.TURNINS) or {}
    local yPos = -20

    local _, newY = self:CreateSettingsPageHeader(parent, yPos,
        RCL["World Buff Drops"],
        RCL["Who can still hand in a head or heart, and who already did"],
        "Interface\\Icons\\INV_Misc_Head_Dragon_01")
    yPos = newY

    local everyone = (WB and WB.GetRoster and WB:GetRoster()) or {}
    -- only toons of the lowest level picked, here and in the counts
    local minLevel = MinLevel()
    local roster, hidden = {}, 0
    for _, info in ipairs(everyone) do
        if Listed(info, minLevel) then roster[#roster + 1] = info else hidden = hidden + 1 end
    end

    ----------------------------------------------------------------
    -- Which toons: the lowest level listed.
    local showCard = self:CreateSettingsCard(parent, yPos, RCL["Toons listed"])
    do
        local items = {}
        for _, v in ipairs(MIN_CHOICES) do items[#items + 1] = { text = MinLabel(v), value = v } end
        -- (a saved level that is not one of the steps is shown as itself)
        local known = false
        for _, v in ipairs(MIN_CHOICES) do if v == minLevel then known = true end end
        if not known then items[#items + 1] = { text = MinLabel(minLevel), value = minLevel } end
        local dd = self.UI:CreateScrollableDropdown(showCard, 200, MinLabel(minLevel), 8)
        dd:SetPoint("TOPLEFT", showCard, "TOPLEFT", 14, -32)
        dd:SetItems(items, function(value)
            SetMinLevel(value)
            -- (after the menu's own click has finished: the page is rebuilt)
            C_Timer.After(0, function()
                if RC.SidebarState and RC.SidebarState.selectedItem == PAGE_ID then RC:ShowSidebarWBDrops(frame, true) end
            end)
        end)
        dd:SetSelectedValue(minLevel, MinLabel(minLevel))
        local note = self:CreateFontString(showCard, "OVERLAY", nil, 10)
        note:SetPoint("LEFT", dd, "RIGHT", 12, 0)
        note:SetJustifyH("LEFT")
        if hidden == 0 then
            note:SetText(RCL["Every toon reporting is listed."])
        elseif hidden == 1 then
            note:SetText(RCL["1 lower-level toon is not listed."])
        else
            note:SetText(string.format(RCL["%d lower-level toons are not listed."], hidden))
        end
        local nc = self:GetColor("text", "gray")
        note:SetTextColor(nc.r, nc.g, nc.b, 1)
    end
    showCard:SetHeight(72)
    yPos = yPos - showCard:GetHeight() - 12

    ----------------------------------------------------------------
    -- Summary: toons that can still drop each buff (and how many of
    -- those already hold the head).
    local sumCard = self:CreateSettingsCard(parent, yPos, RCL["Can still drop"])
    -- the counts flow left to right and wrap to a new line when the card
    -- is too narrow for the next one
    local sx, sy = 14, -34
    local maxX = (sumCard:GetWidth() or 560) - 14
    for _, d in ipairs(defs) do
        local can, ready = 0, 0
        for _, info in ipairs(roster) do
            local _, _, rank = CellState(info, d)
            if rank <= 3 then can = can + 1 end
            if rank == 1 then ready = ready + 1 end
        end
        local fs = self:CreateFontString(sumCard, "OVERLAY", nil, 11)
        fs:SetText(string.format(RCL["%s: %d (%d ready)"], d.label, can, ready))
        local fw = math.ceil(fs:GetStringWidth() or COL_W)
        if sx > 14 and sx + fw > maxX then sx, sy = 14, sy - 18 end
        fs:SetPoint("TOPLEFT", sumCard, "TOPLEFT", sx, sy)
        local c = self:GetColor("text", can > 0 and "green" or "gray")
        fs:SetTextColor(c.r, c.g, c.b, 1)
        sx = sx + math.max(COL_W, fw + 18)
    end
    sumCard:SetHeight(-sy + 26)
    yPos = yPos - sumCard:GetHeight() - 12

    ----------------------------------------------------------------
    -- Roster table: name, then one column per turn-in.
    local listCard = self:CreateSettingsCard(parent, yPos, RCL["Toons"])
    local rowY = -30

    -- THE NAME COLUMN IS AS WIDE AS ITS LONGEST NAME (2026-11-25, the
    -- in-game audit: a toon of another realm, "name-realm", was wider than
    -- the 124 the column had and was drawn with its ends cut off). From
    -- 130 to 220; a name longer than that is cut with dots and shows whole
    -- under the mouse.
    local function RowLabel(info)
        if info.isLocal then return (info.name or "?") .. " " .. RCL["(you)"] end
        return info.label or info.name or "?"
    end
    local NAME_W = NAME_W
    do
        local probe = self:CreateFontString(listCard, "OVERLAY", nil, 11)
        probe:Hide()
        local widest = 0
        for _, info in ipairs(roster) do
            probe:SetText(RowLabel(info))
            local w = (probe.GetUnboundedStringWidth and probe:GetUnboundedStringWidth()) or probe:GetStringWidth() or 0
            if w > widest then widest = w end
        end
        probe:SetText("")
        NAME_W = math.max(NAME_W, math.min(220, math.ceil(widest) + 2 + 6))
    end

    local hc = self:GetColor("ui", "headerText")
    local hdr = self:CreateFontString(listCard, "OVERLAY", nil, 10)
    hdr:SetPoint("TOPLEFT", listCard, "TOPLEFT", 14, rowY)
    hdr:SetText(RCL["Toon"])
    hdr:SetTextColor(hc.r, hc.g, hc.b, 1)
    local lh = self:CreateFontString(listCard, "OVERLAY", nil, 10)
    lh:SetPoint("TOPLEFT", listCard, "TOPLEFT", 14 + NAME_W, rowY)
    lh:SetText(RCL["Lvl"])
    lh:SetTextColor(hc.r, hc.g, hc.b, 1)
    local hx = 14 + NAME_W + LVL_W
    for _, d in ipairs(defs) do
        local h = self:CreateFontString(listCard, "OVERLAY", nil, 10)
        h:SetPoint("TOPLEFT", listCard, "TOPLEFT", hx, rowY)
        h:SetText(d.label)
        h:SetTextColor(hc.r, hc.g, hc.b, 1)
        hx = hx + COL_W
    end
    rowY = rowY - ROW_H

    -- Best cell decides the row order: ready toons first, then anyone
    -- who can still drop something, then the rest by name.
    local rows = {}
    for _, info in ipairs(roster) do
        local best = 9
        for _, d in ipairs(defs) do
            local _, _, rank = CellState(info, d)
            if rank < best then best = rank end
        end
        rows[#rows + 1] = { info = info, rank = best }
    end
    table.sort(rows, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.info.isLocal ~= b.info.isLocal then return a.info.isLocal end
        return (a.info.name or "") < (b.info.name or "")
    end)

    if #rows == 0 then
        local empty = self:CreateFontString(listCard, "OVERLAY", nil, 11)
        empty:SetPoint("TOPLEFT", listCard, "TOPLEFT", 14, rowY)
        empty:SetText(hidden > 0 and RCL["No toon of that level is reporting."] or RCL["No toons reporting yet."])
        local ec = self:GetColor("text", "gray")
        empty:SetTextColor(ec.r, ec.g, ec.b, 1)
        rowY = rowY - ROW_H
    end

    for _, r in ipairs(rows) do
        local info = r.info
        local nameFs = self:CreateFontString(listCard, "OVERLAY", nil, 11)
        nameFs:SetPoint("TOPLEFT", listCard, "TOPLEFT", 14, rowY)
        nameFs:SetWidth(NAME_W - 6)
        nameFs:SetJustifyH("LEFT")
        nameFs:SetWordWrap(false)
        -- (2026-11-24, seen in game: this character's own row read "(you)"
        -- and nothing else) its name, then "(you)"
        nameFs:SetText(RowLabel(info))
        -- (longer than the widest column: whole under the mouse)
        if RC.UI and RC.UI.TruncTip then
            local hit = CreateFrame("Frame", nil, listCard)
            hit:SetPoint("TOPLEFT", listCard, "TOPLEFT", 14, rowY + 3)
            hit:SetSize(NAME_W - 6, ROW_H - 2)
            hit:EnableMouse(true)
            RC.UI:TruncTip(nameFs, hit)
        end
        local nc = ClassColor(info.class)
            or (info.isLocal and self:GetColor("text", "gold") or self:GetColor("ui", "headerText"))
        local dim = (not info.online and not info.isLocal) and 0.55 or 1
        nameFs:SetTextColor(nc.r, nc.g, nc.b, dim)

        local lvlFs = self:CreateFontString(listCard, "OVERLAY", nil, 10)
        lvlFs:SetPoint("TOPLEFT", listCard, "TOPLEFT", 14 + NAME_W, rowY)
        lvlFs:SetWidth(LVL_W - 4)
        lvlFs:SetJustifyH("LEFT")
        lvlFs:SetText(info.level and tostring(info.level) or "?")
        local lc = self:GetColor("text", "gray")
        lvlFs:SetTextColor(lc.r, lc.g, lc.b, dim)

        local cx = 14 + NAME_W + LVL_W
        for _, d in ipairs(defs) do
            local text, colorKey = CellState(info, d)
            local fs = self:CreateFontString(listCard, "OVERLAY", nil, 10)
            fs:SetPoint("TOPLEFT", listCard, "TOPLEFT", cx, rowY)
            fs:SetWidth(COL_W - 6)
            fs:SetJustifyH("LEFT")
            fs:SetText(text)
            local c = self:GetColor("text", colorKey)
            fs:SetTextColor(c.r, c.g, c.b, dim)
            cx = cx + COL_W
        end
        rowY = rowY - ROW_H
    end
    listCard:SetHeight(math.abs(rowY) + 10)
    yPos = yPos - listCard:GetHeight() - 12

    local note = self:CreateFontString(parent, "OVERLAY", nil, 10)
    -- (level with the text inside the cards: it sat 18 to their left)
    note:SetPoint("TOPLEFT", parent, "TOPLEFT", 32, yPos)
    note:SetPoint("RIGHT", parent, "RIGHT", -32, 0)
    note:SetJustifyH("LEFT")
    note:SetText(RCL["These hand-ins are one-time per character. Green = can still drop and holds the head/heart. Yellow = can still drop, no head yet. Orange = already dropped on that toon. ? = that toon's build does not report yet. Rend is Horde only."])
    local noteC = self:GetColor("text", "gray")
    note:SetTextColor(noteC.r, noteC.g, noteC.b, 1)
    yPos = yPos - 44

    self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
    EnsureTicker()
end

local function RegisterPage()
    if type(RC.MenuStructure) ~= "table" then return end
    local entry = {
        id = PAGE_ID,
        name = RCL["World Buff Drops"],
        icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",
        panel = "ShowSidebarWBDrops",
        aliases = { "drops", "heads", "turn in", "turn-in", "who can drop" },
    }
    for _, item in ipairs(RC.MenuStructure) do
        if item.id == "world_tools" and item.children then
            for _, child in ipairs(item.children) do
                if child.id == PAGE_ID then return end
            end
            table.insert(item.children, entry)
            return
        end
    end
    for _, item in ipairs(RC.MenuStructure) do
        if item.id == PAGE_ID then return end
    end
    table.insert(RC.MenuStructure, entry)
end

if RC.MenuStructure then
    RegisterPage()
else
    C_Timer.After(2, function() if RC.MenuStructure then RegisterPage() end end)
end
