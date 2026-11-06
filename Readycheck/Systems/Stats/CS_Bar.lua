------------------------------------------------------------------------
-- Readycheck - Character Stats Bar (Melee/Caster Stat Display)
-- Builds and maintains the on-screen stats bar and its detail panel:
-- stat selection/ordering, drag-to-move, colored stat text, and the
-- toggle button embedded in the character frame.
-- Shares CS (RC.CharacterStats) and the _css color-getter table with
-- CS_Buffs.lua and CS_Defs.lua, which own STAT_DEFS and buff logic.
------------------------------------------------------------------------
local AddonName = "Readycheck"

local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local GetTime = GetTime
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local RC = _G[AddonName]
if not RC then
    error("Readycheck addon not found!")
    return
end

RC._css = RC._css or {}
local _css = RC._css
local CS = RC.CharacterStats
local CLASS_STAT_DEFAULTS, DEFAULT_STAT_LIST, GetAccentGold, GetBorderHover, GetCardBg, GetHeaderBg, GetTitleText, HYBRID_SPEC_STATS, STAT_DEFS, STAT_ORDER =
      _css.CLASS_STAT_DEFAULTS, _css.DEFAULT_STAT_LIST, _css.GetAccentGold, _css.GetBorderHover, _css.GetCardBg, _css.GetHeaderBg, _css.GetTitleText, _css.HYBRID_SPEC_STATS, _css.STAT_DEFS, _css.STAT_ORDER
-- Classic Era talent API; returns nil if no points are spent anywhere (fresh alt).
local function GetDominantTabIndex()
    if not GetNumTalentTabs or not GetTalentTabInfo then return nil end
    local numTabs = GetNumTalentTabs()
    if not numTabs or numTabs == 0 then return nil end
    local best, bestIdx = -1, nil
    for i = 1, numTabs do
        local _, _, pointsSpent = GetTalentTabInfo(i)
        local points = tonumber(pointsSpent) or 0
        if points > best then
            best = points
            bestIdx = i
        end
    end
    if best <= 0 then return nil end
    return bestIdx
end

function CS:GetDefaultStatKeys()
    local _, class = UnitClass("player")

    local hybrid = HYBRID_SPEC_STATS[class]
    if hybrid then
        local tab = GetDominantTabIndex()
        -- Fixed Classic Era tab order: Priest 1=Discipline 2=Holy 3=Shadow.
        if class == "PRIEST" then
            return (tab == 3) and hybrid.dps or hybrid.heal
        -- Paladin 1=Holy 2=Protection 3=Retribution.
        elseif class == "PALADIN" then
            return (tab == 1) and hybrid.heal or hybrid.dps
        else
            return hybrid.heal
        end
    end
    return CLASS_STAT_DEFAULTS[class] or DEFAULT_STAT_LIST
end

function CS:GetEffectiveStatKeys()
    local custom = RC.db and RC.db.statsBarStats
    if type(custom) == "table" and #custom > 0 then
        local out = {}
        for _, key in ipairs(custom) do
            if STAT_DEFS[key] then table.insert(out, key) end
        end
        if #out > 0 then return out end
    end
    return self:GetDefaultStatKeys()
end

function CS:GetStatList()
    local result, seen = {}, {}
    for _, key in ipairs(self:GetEffectiveStatKeys()) do
        local ok = STAT_DEFS[key] ~= nil and not seen[key]
        if key == "durability" then ok = ok and RC.db and RC.db.statsBarDurability ~= false end
        if key == "gold" then ok = ok and RC.db and RC.db.statsBarGold == true end
        if ok then
            seen[key] = true
            table.insert(result, { key = key, label = STAT_DEFS[key].label })
        end
    end
    if not seen.durability and RC.db and RC.db.statsBarDurability ~= false then
        table.insert(result, { key = "durability", label = STAT_DEFS.durability.label })
    end
    if not seen.gold and RC.db and RC.db.statsBarGold == true then
        table.insert(result, { key = "gold", label = STAT_DEFS.gold.label })
    end
    return result
end

function CS:MoveStatTo(fromIndex, toSlot)
    if not RC.db then return end
    local order = {}
    for _, s in ipairs(self:GetStatList()) do
        table.insert(order, s.key)
    end
    local item = table.remove(order, fromIndex)
    if not item then return end
    local insertAt = (fromIndex < toSlot) and (toSlot - 1) or toSlot
    insertAt = math.max(1, math.min(#order + 1, insertAt))
    table.insert(order, insertAt, item)
    RC.db.statsBarStats = order
    if RC.db.showStatsBar and self.RebuildStatsBar then self:RebuildStatsBar() end
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
end

-- fps/ms need polling since no event fires on change; ticker only runs while
-- the bar is shown and one of those stats is enabled, and cancels itself otherwise.
-- It reads those two stats and nothing else (CS:UpdateLiveStats).
function CS:UpdateLiveTicker()
    local want = false
    if self.barFrame and self.barFrame:IsShown() then
        for _, s in ipairs(self:GetStatList()) do
            if s.key == "fps" or s.key == "ms" then want = true break end
        end
    end
    if want and not self._liveTicker then
        local fn = function()
            if not (CS.barFrame and CS.barFrame:IsShown()) then
                if CS._liveTicker then CS._liveTicker:Cancel() CS._liveTicker = nil end
                return
            end
            CS:UpdateLiveStats()
        end
        if RC.Profiler and RC.Profiler.TrackTicker then
            self._liveTicker = RC.Profiler:TrackTicker("StatsBar:LiveStats", 1.0, fn)
        else
            self._liveTicker = C_Timer.NewTicker(1.0, fn)
        end
    elseif not want and self._liveTicker then
        self._liveTicker:Cancel()
        self._liveTicker = nil
    end
end

function CS:GetAllStatOptions()
    local out = {}
    for _, key in ipairs(STAT_ORDER) do
        if STAT_DEFS[key] then table.insert(out, { key = key, label = STAT_DEFS[key].label }) end
    end
    table.insert(out, { key = "durability", label = STAT_DEFS.durability.label })
    table.insert(out, { key = "gold", label = STAT_DEFS.gold.label })
    return out
end

function CS:IsStatEnabled(key)
    if key == "durability" then return RC.db ~= nil and RC.db.statsBarDurability ~= false end
    if key == "gold" then return RC.db ~= nil and RC.db.statsBarGold == true end
    for _, k in ipairs(self:GetEffectiveStatKeys()) do
        if k == key then return true end
    end
    return false
end

-- durability/gold live behind their own db booleans (statsBarDurability/statsBarGold)
-- in addition to being list entries, so they can be toggled without reordering the list.
function CS:SetStatEnabled(key, on)
    if not STAT_DEFS[key] or not RC.db then return end
    if type(RC.db.statsBarStats) ~= "table" or #RC.db.statsBarStats == 0 then
        RC.db.statsBarStats = {}
        for _, k in ipairs(self:GetEffectiveStatKeys()) do
            table.insert(RC.db.statsBarStats, k)
        end
    end
    if key == "durability" or key == "gold" then
        if key == "durability" then
            RC.db.statsBarDurability = on and true or false
        else
            RC.db.statsBarGold = on and true or false
            if on and RC.SaveToonGold then RC:SaveToonGold() end
        end
        if on then
            local found = false
            for _, v in ipairs(RC.db.statsBarStats) do
                if v == key then found = true break end
            end
            if not found then table.insert(RC.db.statsBarStats, key) end
        end
    else
        for i = #RC.db.statsBarStats, 1, -1 do
            if RC.db.statsBarStats[i] == key then table.remove(RC.db.statsBarStats, i) end
        end
        if on then table.insert(RC.db.statsBarStats, key) end
    end
    if RC.db.showStatsBar and self.RebuildStatsBar then self:RebuildStatsBar() end
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
end

function CS:Initialize()
    if not RC.db then
        return
    end

    RC:DebugPrint("Initializing Character Stats module", "charstats")

    self.lastDominantTab = GetDominantTabIndex()

    self:CreateToggleButton()

    self:CreateStatsPanel()

    if RC.db.showStatsBar then
        self:CreateStatsBar()
    end

    self.panelFrame:Hide()

    self:HookCharacterFrame()

    self:InitializeBuffPushoffTracking()

    if not self.goldEventFrame then
        local gf = CreateFrame("Frame")
        gf:RegisterEvent("PLAYER_MONEY")
        gf:RegisterEvent("PLAYER_ENTERING_WORLD")
        gf:SetScript("OnEvent", function()
            if RC.SaveToonGold then RC:SaveToonGold() end
            -- Coalesce bursts of PLAYER_MONEY (vendor stacks, loot) into one bar refresh.
            if RC.db and RC.db.statsBarGold == true and CS.ForceUpdateBarStats then
                if not CS._goldRefreshPending then
                    CS._goldRefreshPending = true
                    C_Timer.After(1.0, function()
                        CS._goldRefreshPending = false
                        if CS.ForceUpdateBarStats then CS:ForceUpdateBarStats() end
                    end)
                end
            end
        end)
        self.goldEventFrame = gf
    end
    if RC.SaveToonGold then RC:SaveToonGold() end

    if RC.db.ttkDisplay and RC.db.ttkDisplay.enabled then
        if RC.TTKDisplay and RC.TTKDisplay.InitializeTTKDisplay then
            RC.TTKDisplay:InitializeTTKDisplay()
        end
    end

    RC:DebugPrint("Character Stats module initialized", "charstats")
end

function CS:CreateToggleButton()
    if not RC.db or not RC.db.showStatsButton then
        RC:DebugPrint("Stats button disabled - skipping creation", "charstats")
        return
    end

    local function GetTexture()
        if RC.GetButtonTexture then
            return RC:GetButtonTexture()
        end
        return "Interface\\AddOns\\Readycheck\\Media\\normTex"
    end
    local ARROW_UP = "Interface\\AddOns\\Readycheck\\Media\\arrowUp"

    local button = CreateFrame("Button", "WR_CharacterStatsToggle", PaperDollItemsFrame)
    button:SetSize(26, 22)
    button:SetFrameStrata("HIGH")
    button:SetPoint("BOTTOMRIGHT", PaperDollItemsFrame, "BOTTOMRIGHT", -38, 87)

    button.bg = button:CreateTexture(nil, "BACKGROUND")
    button.bg:SetAllPoints()
    button.bg:SetTexture(GetTexture())
    local initBg = GetHeaderBg()
    button.bg:SetVertexColor(initBg.r, initBg.g, initBg.b, 1)

    if RC.UI and RC.UI.CreateSimpleBorder then
        RC.UI:CreateSimpleBorder(button, 1)
    end

    button.arrow = button:CreateTexture(nil, "ARTWORK")
    button.arrow:SetSize(10, 10)
    button.arrow:SetPoint("CENTER", 0, 0)
    button.arrow:SetTexture(ARROW_UP)
    button.arrow:SetTexCoord(1, 1, 0, 1, 1, 0, 0, 0)
    local arrowCol = RC:GetColor("text", "gray")
    button.arrow:SetVertexColor(arrowCol.r, arrowCol.g, arrowCol.b, 1)

    button.panelOpen = false

    button:SetScript("OnEnter", function(self)
        local hoverBg = GetHeaderBg()
        self.bg:SetVertexColor(hoverBg.r + 0.08, hoverBg.g + 0.04, hoverBg.b - 0.04, 1)
        if self.border then
            local hoverCol = GetBorderHover()
            self.border.top:SetColorTexture(hoverCol.r, hoverCol.g, hoverCol.b, 1)
            self.border.bottom:SetColorTexture(hoverCol.r, hoverCol.g, hoverCol.b, 1)
            self.border.left:SetColorTexture(hoverCol.r, hoverCol.g, hoverCol.b, 1)
            self.border.right:SetColorTexture(hoverCol.r, hoverCol.g, hoverCol.b, 1)
        end

        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(RCL["Warrior Stats"], 1, 1, 1)
        GameTooltip:AddLine(RCL["Click to show/hide melee statistics"], nil, nil, nil, true)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function(self)
        local normBg = GetHeaderBg()
        self.bg:SetVertexColor(normBg.r, normBg.g, normBg.b, 1)
        if self.border then
            self.border.top:SetColorTexture(0, 0, 0, 1)
            self.border.bottom:SetColorTexture(0, 0, 0, 1)
            self.border.left:SetColorTexture(0, 0, 0, 1)
            self.border.right:SetColorTexture(0, 0, 0, 1)
        end
        GameTooltip:Hide()
    end)

    button:SetScript("OnClick", function()
        CS:TogglePanel()
    end)

    self.toggleButton = button
    RC:DebugPrint("Toggle button created with arrow", "charstats")
end

function CS:ShowStatsButton()
    if self.toggleButton then
        self.toggleButton:Show()
        RC:DebugPrint("Stats button shown", "charstats")
    else
        self:CreateToggleButton()
        if self.toggleButton then
            self.toggleButton:Show()
        end
    end
end

function CS:HideStatsButton()
    if self.toggleButton then
        self.toggleButton:Hide()
        RC:DebugPrint("Stats button hidden", "charstats")
    end
end

function CS:CreateStatsPanel()
    -- Flat window: WHITE8X8 fills only. The bar texture belongs to the
    -- on-screen stats bar, not to this popup's chrome.
    local FLAT = "Interface\\Buttons\\WHITE8X8"

    local frame = CreateFrame("Frame", "WR_CharacterStatsPanel", UIParent)
    frame:SetWidth(self.panelWidth)
    frame:SetHeight(420)
    if PaperDollFrame then
        frame:SetPoint("TOPLEFT", PaperDollFrame, "TOPRIGHT", -20, -12)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    end
    frame:SetFrameStrata("MEDIUM")
    if CharacterFrame then
        frame:SetFrameLevel(CharacterFrame:GetFrameLevel())
    end
    RC.UI:RegisterEscapeClose(frame)

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(FLAT)
    local bgCol = RC:GetColor("ui", "windowBackground")
    bg:SetVertexColor(bgCol.r, bgCol.g, bgCol.b, bgCol.a or 0.95)
    frame.bg = bg

    RC.UI:CreateSimpleBorder(frame, 1)

    -- 30px flat title bar, gold hairline under it, chromeless X.
    local headerBar = CreateFrame("Frame", nil, frame)
    headerBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    headerBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    headerBar:SetHeight(30)
    headerBar:SetFrameLevel(frame:GetFrameLevel() + 1)

    headerBar.bg = headerBar:CreateTexture(nil, "BACKGROUND")
    headerBar.bg:SetAllPoints()
    headerBar.bg:SetTexture(FLAT)
    local hdrBgCol = GetHeaderBg()
    headerBar.bg:SetVertexColor(hdrBgCol.r, hdrBgCol.g, hdrBgCol.b, hdrBgCol.a or 1)

    local headerAccent = headerBar:CreateTexture(nil, "ARTWORK")
    headerAccent:SetPoint("BOTTOMLEFT", headerBar, "BOTTOMLEFT", 0, 0)
    headerAccent:SetPoint("BOTTOMRIGHT", headerBar, "BOTTOMRIGHT", 0, 0)
    headerAccent:SetHeight(1)
    headerAccent:SetTexture(FLAT)
    local accCol = GetAccentGold()
    headerAccent:SetVertexColor(accCol.r, accCol.g, accCol.b, 0.6)

    local titleIcon = RC.UI:AddTitleIcon(headerBar, 16, 8)
    -- the header art every Readycheck window wears (gradient fill, the
    -- stepped accent rule); replaces the flat fill and the single rule
    if RC.UI.ApplyHeaderArt then
        headerAccent:Hide()
        RC.UI:ApplyHeaderArt(headerBar, { fill = headerBar.bg, stepX = 160 })
    end

    local titleText = RC:CreateFontString(headerBar, "OVERLAY", nil, 15)
    titleText:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
    titleText:SetText(RCL["Warrior Stats"])
    local titleCol = GetTitleText()
    titleText:SetTextColor(titleCol.r, titleCol.g, titleCol.b, 1)
    frame.titleText = titleText

    local closeButton = RC.UI:CreateXCloseButton(headerBar, 22, function()
        CS:TogglePanel()
    end)
    closeButton:SetPoint("RIGHT", headerBar, "RIGHT", -5, 0)

    frame.closeButton = closeButton
    frame.headerBar = headerBar

    frame.scrollChild = CreateFrame("Frame", nil, frame)
    frame.scrollChild:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -36)
    frame.scrollChild:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -8, 35)

    -- Footer strip: flat header fill with a black divider above it.
    local buttonContainer = CreateFrame("Frame", nil, frame)
    buttonContainer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 1, 1)
    buttonContainer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    buttonContainer:SetHeight(30)

    buttonContainer.bg = buttonContainer:CreateTexture(nil, "BACKGROUND")
    buttonContainer.bg:SetAllPoints()
    buttonContainer.bg:SetTexture(FLAT)
    local btnContainerBg = GetHeaderBg()
    buttonContainer.bg:SetVertexColor(btnContainerBg.r, btnContainerBg.g, btnContainerBg.b, btnContainerBg.a or 1)
    frame.buttonContainer = buttonContainer

    local bottomAccent = buttonContainer:CreateTexture(nil, "ARTWORK")
    bottomAccent:SetPoint("TOPLEFT", buttonContainer, "TOPLEFT", 0, 0)
    bottomAccent:SetPoint("TOPRIGHT", buttonContainer, "TOPRIGHT", 0, 0)
    bottomAccent:SetHeight(1)
    bottomAccent:SetTexture(FLAT)
    local divCol = RC:GetColor("ui", "borderNormal")
    bottomAccent:SetVertexColor(divCol.r, divCol.g, divCol.b, divCol.a or 1)

    frame.updateButton = RC.UI:CreateStyledButton(buttonContainer, RCL["Update"], 65, 22)
    frame.updateButton:SetPoint("BOTTOMLEFT", buttonContainer, "BOTTOMLEFT", 8, 4)
    frame.updateButton:SetScript("OnClick", function()
        CS:UpdatePanelStats()
    end)

    local autoCheck = RC.UI:CreateCheckbox(buttonContainer, RCL["Auto"], true)
    autoCheck.parentFrame:SetPoint("BOTTOMLEFT", buttonContainer, "BOTTOMLEFT", 80, 5)
    frame.autoUpdateCheckbox = autoCheck

    local originalOnClick = autoCheck:GetScript("OnClick")
    autoCheck:SetScript("OnClick", function(self)
        if originalOnClick then
            originalOnClick(self)
        end

        if self:GetChecked() then
            CS:StartAutoUpdate()
        else
            CS:StopAutoUpdate()
        end
    end)

    self.panelFrame = frame

    self:StartAutoUpdate()

    RC:DebugPrint("Stats panel created", "charstats")
end

-- min/max bounds used to normalize each stat into a 0-1 t for color lerp below.
local STAT_RANGES = {
    ap = {min = 500, max = 3000},
    hit = {min = 0, max = 6},
    crit = {min = 10, max = 40},
    buffs = {min = 0, max = 32},
    dmg = {min = 50, max = 200},
    sp        = {min = 100, max = 900},
    spellcrit = {min = 5,   max = 35},
    mp5       = {min = 0,   max = 200},
    rap       = {min = 500, max = 3000},
    rcrit     = {min = 10,  max = 40},
    durability = {min = 0, max = 100},
    gold       = {min = 0, max = 1},
    fps        = {min = 20, max = 120},
    ms         = {min = 20, max = 250},
}

-- ms/durability are "lower or higher is bad" stats, so their low/high colors
-- are intentionally reversed relative to stats like ap/crit.
local DEFAULT_GRADIENTS = {
    ap = {low = {r=0.6, g=0.6, b=0.6}, high = {r=1.0, g=0.15, b=0.1}},
    hit = {low = {r=1.0, g=0.3, b=0.3}, high = {r=0.3, g=1.0, b=0.3}},
    crit = {low = {r=0.5, g=0.6, b=0.8}, high = {r=0.4, g=0.85, b=1.0}},
    buffs = {low = {r=0.3, g=0.9, b=0.3}, high = {r=1.0, g=0.15, b=0.1}},
    dmg = {low = {r=0.8, g=0.5, b=0.2}, high = {r=1.0, g=0.7, b=0.3}},
    sp        = {low = {r=0.6, g=0.5, b=0.8}, high = {r=0.4, g=0.85, b=1.0}},
    spellcrit = {low = {r=0.5, g=0.6, b=0.8}, high = {r=0.4, g=0.85, b=1.0}},
    mp5       = {low = {r=0.4, g=0.5, b=0.9}, high = {r=0.3, g=0.7, b=1.0}},
    rap       = {low = {r=0.6, g=0.6, b=0.6}, high = {r=0.8, g=0.5, b=0.1}},
    rcrit     = {low = {r=0.5, g=0.6, b=0.8}, high = {r=0.4, g=0.85, b=1.0}},
    durability = {low = {r=1.0, g=0.25, b=0.2}, high = {r=0.3, g=1.0, b=0.35}},
    gold       = {low = {r=1.0, g=0.82, b=0.0}, high = {r=1.0, g=0.82, b=0.0}},
    fps        = {low = {r=1.0, g=0.25, b=0.2}, high = {r=0.3, g=1.0, b=0.35}},
    ms         = {low = {r=0.3, g=1.0, b=0.35}, high = {r=1.0, g=0.25, b=0.2}},
}

local function LerpColor(lowColor, highColor, t)
    t = math.max(0, math.min(1, t))
    return {
        r = lowColor.r + (highColor.r - lowColor.r) * t,
        g = lowColor.g + (highColor.g - lowColor.g) * t,
        b = lowColor.b + (highColor.b - lowColor.b) * t
    }
end

function CS:GetStatColor(statKey, value)
    local range = STAT_RANGES[statKey]
    if not range then
        return {r=1, g=1, b=1}
    end

    local defaults = DEFAULT_GRADIENTS[statKey]
    if not defaults then
        return {r=1, g=1, b=1}
    end

    local lowColor = defaults.low
    local highColor = defaults.high

    -- Per-stat user color overrides only replace low/high anchors; the lerp math is unchanged.
    if RC.db and RC.db.statsBarColors and RC.db.statsBarColors[statKey] then
        local custom = RC.db.statsBarColors[statKey]
        if custom.low then
            lowColor = custom.low
        end
        if custom.high then
            highColor = custom.high
        end
    end

    local t = (value - range.min) / (range.max - range.min)

    return LerpColor(lowColor, highColor, t)
end

-- The ONE place the stats bar position is persisted. Both the bar's own
-- drag handler and the UIMover saveCallback go through here, so the saved
-- table always has the full point/relativePoint/xOfs/yOfs shape the
-- restore validation in CreateStatsBar expects.
function CS:SaveBarPosition(xOfs, yOfs)
    if not self.barFrame then return end
    RC.Position.SetFrame(self.barFrame, xOfs, yOfs)
end

-- The bar's chrome: a flat panel, one grey fill and a thin black edge.
-- Flat on purpose (until a background texture is picked on the settings
-- page), so it is not on the tracked-texture list that hands out the
-- status bar texture. Colour and show / hide are applied in
-- BuildBarStats, which runs on every rebuild. Shared by the live bar and
-- the settings preview.
function CS:NewStatsBarFrame(parent, name)
    local frame = CreateFrame("Frame", name, parent)
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(RC.UI.FLAT)
    frame.bg = bg
    frame.border = RC.UI:CreateSimpleBorder(frame, 1)
    return frame
end

-- The settings page's look table (db.statsBarLook); nil fields are the
-- bar's original look.
function CS:BarLook()
    local l = RC.db and RC.db.statsBarLook
    return type(l) == "table" and l or {}
end

function CS:CreateStatsBar()
    if self.barFrame then
        return
    end

    local frame = self:NewStatsBarFrame(UIParent, "WR_StatsBar")

    local barHeight = RC.db.statsBarHeight or 22

    frame:SetSize(400, barHeight)
    RC.Position.Bind(frame, function()
        RC.db.statsBarPosition = RC.db.statsBarPosition or {}
        return RC.db.statsBarPosition
    end, {
        point = "TOP", pointKey = "point", relKey = "relativePoint", xKey = "xOfs", yKey = "yOfs",
        default = { point = "TOP", x = 0, y = -2 },
    })
    RC.Position.RestoreFrame(frame)
    frame:SetClampedToScreen(true)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(10)
    frame:HookScript("OnShow", function() CS:UpdateLiveTicker() end)

    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetClampedToScreen(true)

    RC.Position.MakeMovable(frame, function() return not RC.db.statsBarLocked end)
    frame:HookScript("OnDragStart", function(self) self.isDragging = true end)
    frame:HookScript("OnDragStop", function(self) self.isDragging = false end)

    frame:SetMovable(not RC.db.statsBarLocked)

    frame:SetScript("OnMouseDown", function(self, button)
        if button == "RightButton" then
            RC.db.statsBarLocked = not RC.db.statsBarLocked
            if RC.db.statsBarLocked then
                self:SetMovable(false)
            else
                self:SetMovable(true)
            end
            if RC.SaveConfigurationToProfile then
                RC:SaveConfigurationToProfile()
            end
        end
    end)

    frame:SetClampedToScreen(true)

    self.barFrame = frame
    -- Debug-only: logs a stack trace whenever something hides the bar, to catch
    -- unexpected callers hiding it outside our own show/hide paths.
    if not frame._hideTraced then
        frame._hideTraced = true
        hooksecurefunc(frame, "Hide", function()
            CS._lastHideAt = GetTime()
            CS._lastHideStack = debugstack(2, 5, 0)
            RC:DebugPrint("StatsBar HIDDEN by:\n" .. CS._lastHideStack, "charstats")
        end)
    end

    self:BuildBarStats()
    frame:Show()
    -- A frame is born shown, so the Show above fires no OnShow and the hook
    -- further up never ran: after a login or a reload the fps / latency
    -- clock was never started, and those two only moved when some other
    -- event happened to refresh the bar. Start it here.
    self:UpdateLiveTicker()

    C_Timer.After(0.5, function()
        CS:ForceUpdateBarStats()
    end)

    RC:DebugPrint("Stats bar created with dynamic colors", "charstats")
end

------------------------------------------------------------------------
-- THE BAR'S CELLS
-- One cell per stat: a dim label on the left, the value in its own colour
-- on the right, a divider on its left edge and a hover wash.
--
-- EVERY CELL HAS A FIXED WIDTH. The value's share is reserved from the
-- widest text that stat is expected to show (SAMPLE), and only ever
-- grows. The bar used to be exactly as wide as its text, so every change
-- of attack power or frame rate resized it - and a bar anchored by its
-- middle then slid every other stat sideways with it.
--
-- Cells are pooled whole: a rebuild (spec change, a stat ticked on or
-- off, a font size) re-homes them rather than making new frames, which
-- the client never frees.
------------------------------------------------------------------------
local SAMPLE = {
    buffs = "32", hit = "10.0%", crit = "45.0%", ap = "3000", dmg = "200%",
    sp = "1000", hp = "1500", sdmg = "1000", spellcrit = "40.0%", mp5 = "200",
    rap = "3000", rcrit = "45.0%", fps = "999", ms = "999", durability = "100%",
}

-- what the short labels stand for, for the tooltip
local STAT_NAMES = {
    buffs = "Buffs", hit = "Melee hit chance", crit = "Melee crit chance", ap = "Attack power",
    dmg = "Damage dealt", sp = "Spell power", hp = "Healing power", sdmg = "Spell damage",
    spellcrit = "Spell crit chance", mp5 = "Mana per 5 seconds", rap = "Ranged attack power",
    rcrit = "Ranged crit chance", fps = "Frames per second", ms = "Latency",
    durability = "Durability", gold = "Gold",
}

-- the two stats no event announces; the live clock reads only these
local LIVE_KEYS = { "fps", "ms" }

-- THE BAR'S FILL: one flat colour - the stats bar's own Background
-- colour, by default the dark grey of Readycheck's panels - on a flat
-- texture. It used to wear the status bar texture, whose own shading
-- turned any colour given to it into a darker, streakier one.
local function PaintBarFill(tex)
    local bg = RC:GetColor("statsBar", "background")
    local v = CS:BarLook().bgTexture
    if v == nil then
        tex:SetTexture(RC.UI.FLAT)
    else
        -- nil = flat, "" = the global texture, else an LSM name
        RC:ApplyTextureSpec(tex, (v ~= "" and v) or nil)
    end
    tex:SetVertexColor(bg.r, bg.g, bg.b, bg.a or 0.95)
end

local function MeasureText(fs, text)
    if not text or text == "" then return 0 end
    local m = CS._barMeasure
    if not m then
        -- one hidden string for the live bar and the preview alike
        m = UIParent:CreateFontString(nil, "OVERLAY")
        m:Hide()
        CS._barMeasure = m
    end
    local path, size, flags = fs:GetFont()
    if not path then return 0 end
    m:SetFont(path, size, flags)
    m:SetText(text)
    return m:GetStringWidth() or 0
end

local function NewBarCell(frame, preview)
    local FLAT = RC.UI.FLAT
    local cell = CreateFrame("Frame", nil, frame)
    cell:EnableMouse(not preview)
    cell:RegisterForDrag("LeftButton")

    -- the hover wash (AttachHover paints frame.bg)
    cell.bg = cell:CreateTexture(nil, "BACKGROUND")
    cell.bg:SetAllPoints()
    cell.bg:SetTexture(FLAT)

    cell.sep = cell:CreateTexture(nil, "ARTWORK")
    cell.sep:SetTexture(FLAT)
    cell.sep:SetWidth(1)
    cell.sep:SetPoint("TOPLEFT", cell, "TOPLEFT", 0, -3)
    cell.sep:SetPoint("BOTTOMLEFT", cell, "BOTTOMLEFT", 0, 3)

    cell.label = RC:CreateFontString(cell, "OVERLAY", nil, 10)
    cell.label:SetJustifyH("LEFT")
    cell.value = RC:CreateFontString(cell, "OVERLAY", nil, 11)
    cell.value:SetJustifyH("RIGHT")
    if RC.UI.TagElement then RC.UI:TagElement(cell.label, "label") RC.UI:TagElement(cell.value, "value") end
    -- a settings preview sample: drawn, never clicked or dragged
    if preview then return cell end

    local clear = { r = 0, g = 0, b = 0, a = 0 }
    RC.UI:AttachHover(cell, clear, clear, {
        onEnter = function(c) CS:ShowStatTooltip(c) end,
        onLeave = function() GameTooltip:Hide() end,
    })
    cell.bg:SetVertexColor(0, 0, 0, 0)

    -- The bar is dragged, and locked with a right-click, from anywhere on
    -- it. The cells cover nearly all of it, so they hand both on.
    cell:SetScript("OnDragStart", function(c)
        -- a locked bar does not move, so a wobble there is still a click
        c._dragging = (not (RC.db and RC.db.statsBarLocked)) or nil
        local h = frame:GetScript("OnDragStart")
        if h then h(frame) end
    end)
    cell:SetScript("OnDragStop", function(c)
        if c._dragging then c._dragAt = GetTime() end
        c._dragging = nil
        local h = frame:GetScript("OnDragStop")
        if h then h(frame) end
    end)
    -- a click (not the end of a drag) on the Buffs cell opens the buff list
    cell:SetScript("OnMouseUp", function(c, button)
        if c._dragging then
            c._dragging = nil
            return
        end
        if button ~= "LeftButton" or c.key ~= "buffs" then return end
        if c._dragAt and GetTime() - c._dragAt < 0.3 then return end
        if CS.OnBuffCellClick then CS:OnBuffCellClick(c) end
    end)
    cell:SetScript("OnMouseDown", function(_, button)
        local h = frame:GetScript("OnMouseDown")
        if h then h(frame, button) end
    end)
    return cell
end

-- (Re)populates the bar's cells, reusing pooled ones across rebuilds.
function CS:BuildBarStats()
    local frame = self.barFrame
    if not frame or not RC.db then return end

    local barHeight = RC.db.statsBarHeight or 22
    local fontSize = RC.db.statsBarFontSize or 11
    local spacing = RC.db.statsBarSpacing or 8
    local showBg = RC.db.statsBarShowBg ~= false
    local look = self:BarLook()
    -- the edge follows the background unless set on its own
    local showEdge = showBg
    if look.showBorder ~= nil then showEdge = look.showBorder and true or false end

    frame:SetHeight(barHeight)
    if frame.bg then
        PaintBarFill(frame.bg)
        if showBg then frame.bg:Show() else frame.bg:Hide() end
    end
    if frame.border then
        RC.UI:UpdateBorderColor(frame.border, look.borderColor or RC:GetColor("ui", "borderNormal"))
        for _, side in ipairs({ "top", "bottom", "left", "right" }) do
            local edge = frame.border[side]
            if edge then
                if showEdge then edge:Show() else edge:Hide() end
            end
        end
    end

    -- Release the current cells into the pool before repopulating.
    self._barCellPool = self._barCellPool or {}
    local pool = self._barCellPool
    if self.barCells then
        for _, cell in pairs(self.barCells) do
            cell:Hide()
            cell:ClearAllPoints()
            cell.key = nil
            table.insert(pool, cell)
        end
    end

    self.barCells = {}
    self.barStatTexts = {}
    self.barStatLabels = {}
    self.barStatOrder = {}

    local labelCol = RC:GetColor("statsBar", "labelText")
    local sepCol = RC:GetColor("statsBar", "separator")
    local normCol = RC:GetColor("text", "normal")
    -- The hover wash is the bar's own Background colour, lifted: the
    -- theme's button hover grey is darker than a grey bar, and a stat
    -- that goes DARK under the mouse reads as switched off.
    local barCol = RC:GetColor("statsBar", "background")
    local hoverBg = { r = barCol.r + (1 - barCol.r) * 0.14, g = barCol.g + (1 - barCol.g) * 0.14,
                      b = barCol.b + (1 - barCol.b) * 0.14, a = 0.85 }
    local normBg = { r = hoverBg.r, g = hoverBg.g, b = hoverBg.b, a = 0 }

    for _, stat in ipairs(self:GetStatList()) do
        local key = stat.key
        local enableKey = "statsBar" .. key:gsub("^%l", string.upper)
        if RC.db[enableKey] == nil and not self.preview then
            RC.db[enableKey] = true
        end

        if RC.db[enableKey] ~= false then
            local cell = table.remove(pool) or NewBarCell(frame, self.preview)
            cell.key = key
            cell:SetFrameLevel(frame:GetFrameLevel() + 1)
            cell.normBg, cell.hoverBg = normBg, hoverBg
            cell.bg:SetVertexColor(normBg.r, normBg.g, normBg.b, 0)

            -- own font per text with the global font as fallback; sizes
            -- stay on statsBarFontSize (labels one smaller unless set)
            RC:ApplyFontSpec(cell.label, look.labelFont, { size = fontSize - 1 })
            RC:ApplyFontSpec(cell.value, look.valueFont, { size = fontSize })
            cell.label:SetText(stat.label)
            cell.label:SetTextColor(labelCol.r, labelCol.g, labelCol.b, labelCol.a or 1)
            cell.value:SetText("0")
            cell.value:SetTextColor(normCol.r, normCol.g, normCol.b, 1)

            cell.sep:SetVertexColor(sepCol.r, sepCol.g, sepCol.b, sepCol.a or 0.5)

            -- room for the widest value this stat should ever show
            cell.reserve = MeasureText(cell.value, SAMPLE[key])

            self.barCells[key] = cell
            self.barStatTexts[key] = cell.value
            self.barStatLabels[key] = cell.label
            table.insert(self.barStatOrder, key)

            if key == "buffs" then
                local iconSize = fontSize
                local pushoffIcon = self.buffsPushoffIcon
                if not pushoffIcon then
                    pushoffIcon = CreateFrame("Button", nil, cell)

                    pushoffIcon.texture = pushoffIcon:CreateTexture(nil, "ARTWORK")
                    pushoffIcon.texture:SetAllPoints()
                    pushoffIcon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                    if self.preview then
                        pushoffIcon:EnableMouse(false)
                    else
                        pushoffIcon:SetScript("OnEnter", function(self)
                            CS:ShowBuffPushoffTooltip(self)
                        end)

                        pushoffIcon:SetScript("OnLeave", function(self)
                            GameTooltip:Hide()
                        end)
                    end

                    self.buffsPushoffIcon = pushoffIcon
                end
                pushoffIcon:SetParent(cell)
                pushoffIcon:SetSize(iconSize, iconSize)
                pushoffIcon:SetFrameLevel(cell:GetFrameLevel() + 1)
                pushoffIcon:Show()
                self.buffsPushoffIconWidth = iconSize + 4
            end

            cell:Show()
        end
    end

    -- The pushoff icon lives outside the pool; hide it when the buffs
    -- stat is no longer on the bar.
    if self.buffsPushoffIcon and not self.barCells.buffs then
        self.buffsPushoffIcon:Hide()
    end

    self.barSpacing = spacing
    self:LayoutBarStats()
    if self.UpdateBuffCapWant and not self.preview then self:UpdateBuffCapWant() end
    -- layer / scale / clamp, fade rules, shadow / glow (the customization
    -- standard, db.statsBarLook); its own fill and edge stay its own
    if RC.ApplyFrameCustom and self.barFrame then
        RC:ApplyFrameCustom(self.barFrame, function() return RC.db and RC.db.statsBarLook end, { sample = self.preview })
    end
end

------------------------------------------------------------------------
-- THE SETTINGS PREVIEW: the same bar, built by the same code, on the
-- preview pane's canvas. A preview object reads CS's methods but owns
-- every piece of bar state (cells, pool, icon), so nothing of the live
-- bar is touched; its cells take no mouse and it registers nothing.
------------------------------------------------------------------------
function CS:NewBarPreview(parent)
    local pv = setmetatable({}, { __index = CS })
    pv.preview = true
    pv.barFrame = CS:NewStatsBarFrame(parent)
    pv.barCells, pv._barCellPool = {}, {}
    pv.barStatTexts, pv.barStatLabels, pv.barStatOrder = {}, {}, {}
    pv.buffsPushoffIcon, pv.buffsPushoffIconWidth = false, false
    pv.barSpacing, pv.statCache = 8, {}
    return pv
end

-- Restyles the sample from the settings and fills it: values[key] =
-- number, or nil for a stat's own sample. Returns the bar's size.
function CS:FillBarPreview(pv, values, pushIcon)
    pv:BuildBarStats()
    for _, key in ipairs(pv.barStatOrder) do
        local def = STAT_DEFS[key]
        local v = values and values[key]
        local txt
        if v ~= nil and def and def.fmt then
            local ok, f = pcall(def.fmt, v)
            txt = ok and f or tostring(v)
        else
            txt = tostring(v or "-")
        end
        pv:PaintBarStat(key, v or 0, txt)
    end
    if pv.buffsPushoffIcon and pv.barCells.buffs then
        pv.buffsPushoffIcon.texture:SetTexture(pushIcon or "Interface\\Icons\\INV_Potion_54")
        pv.buffsPushoffIcon:SetShown(not RC.db or RC.db.statsBarShowPushoffIcon ~= false)
    end
    pv:LayoutBarStats()
    return pv.barFrame:GetWidth(), pv.barFrame:GetHeight()
end

------------------------------------------------------------------------
-- The customization standard on the bar (db.statsBarLook.anchors.label /
-- .value / .pushoff, db.statsBarLook.formats.value): every cell's label
-- and value (and the push-off icon) placeable, the values worded. Nil:
-- each sits where the layout puts it, worded as the stat words it.
------------------------------------------------------------------------
CS.ANCHOR_TARGETS = {
    { value = "cell", text = RCL["The cell"] }, { value = "label", text = RCL["Label"] },
    { value = "value", text = RCL["Value"] },
}
local cellDef = { label = {}, value = {}, pushoff = {} }
-- a part's default in a cell with this padding / icon room (reused tables)
function CS:CellAnchorDefault(part, pad, iconW)
    pad = pad or math.max(3, math.floor((self.barSpacing or 8) * 0.8 + 0.5))
    local d = cellDef[part]
    if part == "label" then
        d.point, d.relPoint, d.x, d.y, d.to, d.justify = "LEFT", "LEFT", pad, 0, "cell", "LEFT"
    elseif part == "value" then
        d.point, d.relPoint, d.x, d.y, d.to, d.justify = "RIGHT", "RIGHT", -(pad + (iconW or 0)), 0, "cell", "RIGHT"
    else
        d.point, d.relPoint, d.x, d.y, d.to = "RIGHT", "RIGHT", -pad, 0, "cell"
    end
    return d
end
local function CellAnchors()
    local a = CS:BarLook().anchors
    return type(a) == "table" and a or nil
end
local function CellTo(cell, icon)
    if not cell._csTo then
        cell._csTo = function(k)
            if k == "cell" then return cell elseif k == "label" then return cell.label
            elseif k == "value" then return cell.value end
        end
    end
    return cell._csTo
end

-- A value worded by the bar's format: percents keep their sign, numbers
-- follow "big numbers", anything else just gets the before / after / case.
local fmtVals, fmtKinds = {}, {}
local VALUE_FORMAT_DEFAULTS = { abbrev = "full", decimals = 1 }
CS.VALUE_FORMAT_DEFAULTS = VALUE_FORMAT_DEFAULTS
function CS:FormatBarValue(value, text)
    local f = self:BarLook().formats
    local spec = type(f) == "table" and f.value or nil
    if not spec or type(text) ~= "string" then return text end
    local kind, pct = "text", ""
    if text:match("^%-?[%d%.]+%%$") then kind, pct = "percent", "%"
    elseif text:match("^%-?[%d%.]+$") then kind = "number" end
    fmtVals.value = (kind == "text") and text or (tonumber(value) or tonumber((text:gsub("%%", ""))) or 0)
    fmtKinds.value = kind
    local out = RC.UI:FormatText(spec, VALUE_FORMAT_DEFAULTS, fmtVals, fmtKinds, "value")
    if pct ~= "" then
        -- the sign goes back after the number, inside before / after
        local pre = spec.prefix or ""
        local suf = spec.suffix or ""
        local core = out
        if pre ~= "" and core:sub(1, #pre) == pre then core = core:sub(#pre + 1) end
        if suf ~= "" and core:sub(-#suf) == suf then core = core:sub(1, -#suf - 1) end
        out = pre .. core .. pct .. suf
    end
    return out
end

-- Sets every cell's width and place, and the bar's own width. Runs on a
-- rebuild and when a value outgrows the room reserved for it - not when
-- a value merely changes.
function CS:LayoutBarStats()
    local frame = self.barFrame
    if not frame or not self.barStatOrder or not self.barCells then return end

    local spacing = self.barSpacing or 8
    local pad = math.max(3, math.floor(spacing * 0.8 + 0.5))
    -- inside the 1px edge, when there is one
    local edge = (not RC.db or RC.db.statsBarShowBg ~= false) and 1 or 0
    local x = edge
    local iconOn = self.buffsPushoffIconWidth and (not RC.db or RC.db.statsBarShowPushoffIcon ~= false)

    for i, key in ipairs(self.barStatOrder) do
        local cell = self.barCells[key]
        if cell then
            local labelW = math.ceil(cell.label:GetStringWidth() or 0)
            local valueW = math.ceil(cell.reserve or 0)
            local iconW = (key == "buffs" and iconOn) and self.buffsPushoffIconWidth or 0
            local w = pad + labelW + 4 + valueW + iconW + pad

            cell:ClearAllPoints()
            cell:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -edge)
            cell:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", x, edge)
            cell:SetWidth(w)
            if i > 1 then cell.sep:Show() else cell.sep:Hide() end

            cell.label:ClearAllPoints()
            cell.label:SetPoint("LEFT", cell, "LEFT", pad, 0)
            cell.value:ClearAllPoints()
            cell.value:SetPoint("RIGHT", cell, "RIGHT", -(pad + iconW), 0)

            if key == "buffs" and self.buffsPushoffIcon then
                self.buffsPushoffIcon:ClearAllPoints()
                self.buffsPushoffIcon:SetPoint("RIGHT", cell, "RIGHT", -pad, 0)
            end
            -- a label / value / icon the settings moved (a pooled cell
            -- moved last time gets its own sides back first)
            if cell._csMoved then
                cell.label:SetJustifyH("LEFT")
                cell.value:SetJustifyH("RIGHT")
                cell._csMoved = nil
            end
            local a = CellAnchors()
            if a then cell._csMoved = true end
            if a then
                local to = CellTo(cell)
                if a.label then RC.UI:ApplyAnchor(cell.label, a.label, self:CellAnchorDefault("label", pad), to) end
                if a.value then RC.UI:ApplyAnchor(cell.value, a.value, self:CellAnchorDefault("value", pad, iconW), to) end
                if a.pushoff and key == "buffs" and self.buffsPushoffIcon then
                    RC.UI:ApplyAnchor(self.buffsPushoffIcon, a.pushoff, self:CellAnchorDefault("pushoff", pad), to)
                end
            end

            x = x + w
        end
    end

    frame:SetWidth(x + edge)
end

-- Puts one stat's value on the bar: text and colour. Returns true
-- when the text has outgrown the room reserved for it, which is the only
-- time the bar needs laying out again.
function CS:PaintBarStat(key, value, text)
    local cell = self.barCells and self.barCells[key]
    if not cell then return false end
    value = tonumber(value) or 0

    cell.value:SetText(self:FormatBarValue(value, text))
    local color = self:GetStatColor(key, value)
    if color then
        cell.value:SetTextColor(color.r, color.g, color.b)
    end

    local w = cell.value:GetStringWidth() or 0
    if w > (cell.reserve or 0) + 0.5 then
        cell.reserve = w
        return true
    end
    return false
end

-- The live clock's whole job: frame rate and latency, nothing else. It
-- used to push the entire bar through a refresh every second, buff scan
-- included, to move two numbers.
function CS:UpdateLiveStats()
    if not (self.barFrame and self.barFrame:IsShown() and self.barCells) then return end
    local cache = self.statCache
    local grew = false
    for _, key in ipairs(LIVE_KEYS) do
        local def = STAT_DEFS[key]
        if def and self.barCells[key] then
            local value = math.floor((def.get(self) or 0) + 0.5)
            if value ~= cache[key] then
                cache[key] = value
                if self:PaintBarStat(key, value, def.fmt(value)) then grew = true end
            end
        end
    end
    if grew then self:LayoutBarStats() end
end

-- The settings page and the font system both call this after a look
-- change (background on or off, a new texture or font).
function CS:RefreshStatsBar()
    if not self.barFrame then return end
    self:RebuildStatsBar()
end

function CS:ShowStatTooltip(cell)
    local key = cell and cell.key
    if not key then return end
    local gray = RC:GetColor("text", "gray")
    local norm = RC:GetColor("text", "normal")

    if key == "durability" then
        self:ShowDurabilityTooltip(cell)
    elseif key == "gold" and self.ShowGoldTooltip then
        self:ShowGoldTooltip(cell)
    else
        GameTooltip:SetOwner(cell, "ANCHOR_BOTTOM")
        local title = GetTitleText()
        GameTooltip:SetText(RCL[STAT_NAMES[key] or key], title.r, title.g, title.b)
        if key == "gold" then
            GameTooltip:AddLine(GetCoinTextureString(GetMoney()), norm.r, norm.g, norm.b)
        elseif key == "buffs" then
            self:AddBuffCapLines(GameTooltip)
            if RC.db and RC.db.statsBarShowPushoffIcon ~= false then
                GameTooltip:AddLine(RCL["The icon is the buff a new one would push off next."], gray.r, gray.g, gray.b, true)
            end
            GameTooltip:AddLine(RCL["Click: list your buffs."], gray.r, gray.g, gray.b)
            local rem = RC.BuffCap and RC.BuffCap:Remover()
            if rem and rem.SetPaused then
                local okp, paused = pcall(rem.Paused)
                GameTooltip:AddLine((okp and paused) and RCL["Shift-click: resume buff removal."]
                    or RCL["Shift-click: pause buff removal."], gray.r, gray.g, gray.b)
            end
        elseif key == "hit" then
            local okSame, same = pcall(self.GetMissChance, self, 0)
            local okBoss, boss = pcall(self.GetMissChance, self, 3)
            if okSame and same then
                GameTooltip:AddDoubleLine(RCL["Miss, same level"], string.format("%.1f%%", same), norm.r, norm.g, norm.b, norm.r, norm.g, norm.b)
            end
            if okBoss and boss then
                GameTooltip:AddDoubleLine(RCL["Miss, boss (+3)"], string.format("%.1f%%", boss), norm.r, norm.g, norm.b, norm.r, norm.g, norm.b)
            end
        elseif key == "ms" then
            local _, _, home, world = GetNetStats()
            GameTooltip:AddDoubleLine(RCL["Home"], (home or 0) .. " ms", norm.r, norm.g, norm.b, norm.r, norm.g, norm.b)
            GameTooltip:AddDoubleLine(RCL["World"], (world or 0) .. " ms", norm.r, norm.g, norm.b, norm.r, norm.g, norm.b)
        else
            GameTooltip:AddLine(cell.value:GetText() or "", norm.r, norm.g, norm.b)
        end
    end

    GameTooltip:AddLine(" ")
    if RC.db and RC.db.statsBarLocked then
        GameTooltip:AddLine(RCL["Locked. Right-click to unlock."], gray.r, gray.g, gray.b)
    else
        GameTooltip:AddLine(RCL["Drag to move. Right-click to lock."], gray.r, gray.g, gray.b)
    end
    GameTooltip:Show()
end

function CS:TogglePanel()
    if not self.panelFrame then
        return
    end

    if self.panelFrame:IsShown() then
        self.panelFrame:Hide()
        self.isPanelVisible = false
        if self.toggleButton and self.toggleButton.arrow then
            self.toggleButton.arrow:SetTexCoord(1, 1, 0, 1, 1, 0, 0, 0)
        end
    else
        self.panelFrame:Show()
        self.isPanelVisible = true
        self:UpdatePanelStats()
        if self.toggleButton and self.toggleButton.arrow then
            self.toggleButton.arrow:SetTexCoord(0, 0, 1, 0, 0, 1, 1, 1)
        end
    end
end

-- Repopulates the existing bar frame in place via BuildBarStats instead of
-- discarding and recreating it (frames are never GC'd by the client).
function CS:RebuildStatsBar()
    if not self.barFrame then return end
    local wasShown = self.barFrame:IsShown()
    self.statCache = {}
    self:BuildBarStats()
    if wasShown then
        self:UpdateBarStats()
    end
    self:UpdateLiveTicker()
    RC:DebugPrint("Rebuilt stats bar for new spec", "charstats")
end

function CS:HookCharacterFrame()
    CharacterFrame:HookScript("OnHide", function()
        if CS.panelFrame then
            CS.panelFrame:Hide()
            CS.isPanelVisible = false
            if CS.toggleButton and CS.toggleButton.arrow then
                CS.toggleButton.arrow:SetTexCoord(1, 1, 0, 1, 1, 0, 0, 0)
            end
        end
    end)

    CharacterFrame:HookScript("OnShow", function()
        if CS.toggleButton then
            CS.toggleButton:Show()
        end
    end)
end

function CS:StartAutoUpdate()
    if self.eventFrame then
        return
    end

    -- UNIT_AURA/UNIT_STATS/UNIT_ATTACK_POWER can fire many times per second in combat.
    -- The handler below only sets a dirty flag and starts a 0.3s guarded timer;
    -- actual stat recompute happens in ThrottledUpdate, never directly here.
    self.eventFrame = CreateFrame("Frame")
    self.eventFrame:RegisterUnitEvent("UNIT_STATS", "player")
    RC:RegisterUnitAuraCallback("CharacterStats", 0.3, function()
        CS:ThrottledUpdate()
    end)
    self.eventFrame:RegisterUnitEvent("UNIT_ATTACK_POWER", "player")
    self.eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    self.eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    self.eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    self.eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    self.eventFrame:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
    -- (not every client still has this event; a missing one must not stop the rest)
    pcall(self.eventFrame.RegisterEvent, self.eventFrame, "CHARACTER_POINTS_CHANGED")
    -- durability used to ride along on the once-a-second fps refresh; now
    -- that refresh only reads fps and latency, it gets its own event (the
    -- handler below still only sets a flag)
    self.eventFrame:RegisterEvent("UPDATE_INVENTORY_DURABILITY")

    pcall(function() self.eventFrame:RegisterEvent("COMBAT_RATING_UPDATE") end)

    self.eventFrame:SetScript("OnEvent", function(frame, event, arg1)
        if event == "UNIT_STATS" or event == "UNIT_ATTACK_POWER" then
            if arg1 ~= "player" then
                return
            end
        end

        if event == "CHARACTER_POINTS_CHANGED" then
            local newTab = GetDominantTabIndex()
            if newTab and newTab ~= CS.lastDominantTab then
                CS.lastDominantTab = newTab
                CS:RebuildStatsBar()
            end
        end

        if event == "PLAYER_ENTERING_WORLD" then
            C_Timer.After(0.5, function()
                CS.lastUpdate = 0
                CS:ThrottledUpdate()
            end)
            return
        end

        CS._statsDirty = true
        -- C_Timer.After returns nothing, so a handle can't be used as the
        -- "already scheduled" guard - use a boolean pending flag instead.
        if not CS._statsTimerPending then
            CS._statsTimerPending = true
            C_Timer.After(0.3, function()
                CS._statsTimerPending = false
                if not CS._statsDirty then return end
                CS._statsDirty = false
                CS:ThrottledUpdate()
            end)
        end
    end)

    RC:DebugPrint("Event-driven auto-update started", "charstats")
end

-- 0.3s floor matches the dirty-flag timer in StartAutoUpdate; keep in sync.
function CS:ThrottledUpdate()
    local now = GetTime()
    if now - self.lastUpdate < 0.3 then
        return
    end
    self.lastUpdate = now

    if self.panelFrame and self.panelFrame:IsShown() then
        self:UpdatePanelStats()
    end

    if self.barFrame and self.barFrame:IsShown() then
        self:UpdateBarStats()
    end
end

function CS:StopAutoUpdate()
    if self.eventFrame then
        self.eventFrame:UnregisterAllEvents()
        self.eventFrame:SetScript("OnEvent", nil)
        self.eventFrame = nil
    end
    if self.updateTimer then
        self.updateTimer:Cancel()
        self.updateTimer = nil
    end
    if self.fallbackTicker then
        self.fallbackTicker:Cancel()
        self.fallbackTicker = nil
    end
    RC:DebugPrint("Event-driven auto-update stopped", "charstats")
end

function CS:UpdatePanelStats()
    if not self.panelFrame or not self.panelFrame.scrollChild then
        return
    end

    for _, line in ipairs(self.statLines) do
        line:Hide()
    end
    self.statLines = {}

    local yOffset = -10

    yOffset = self:CreateHeader("MELEE STATS", yOffset)

    local ap, posBuff, negBuff = UnitAttackPower("player")
    local totalAP = ap + posBuff + negBuff
    yOffset = self:CreateStat("Attack Power", tostring(totalAP), yOffset)

    local mainSpeed, offSpeed = UnitAttackSpeed("player")
    yOffset = self:CreateStat("Main Hand Speed", string.format("%.2f", mainSpeed), yOffset)
    if offSpeed then
        yOffset = self:CreateStat("Off Hand Speed", string.format("%.2f", offSpeed), yOffset)
    end

    yOffset = yOffset - 5
    yOffset = self:CreateHeader("CRITICAL STRIKE", yOffset)

    local critChance = GetCritChance() or 0
    yOffset = self:CreateStat("Crit Chance", string.format("%.2f%%", critChance), yOffset)

    yOffset = yOffset - 5
    yOffset = self:CreateHeader("HIT", yOffset)

    local hitFromGear = self:GetMeleeHit()
    yOffset = self:CreateStat("Hit %", string.format("%.2f%%", hitFromGear), yOffset)

    local missChanceSame = self:GetMissChance(0)
    yOffset = self:CreateStat("Miss (Same Level)", string.format("%.2f%%", missChanceSame), yOffset)

    local missChanceBoss = self:GetMissChance(3)
    yOffset = self:CreateStat("Miss (Boss +3)", string.format("%.2f%%", missChanceBoss), yOffset)

    yOffset = yOffset - 5
    yOffset = self:CreateHeader("DEFENSIVE STATS", yOffset)

    local base, effectiveArmor, armor, posBuff, negBuff = UnitArmor("player")
    yOffset = self:CreateStat("Armor", tostring(effectiveArmor), yOffset)

    local defense = self:GetDefenseSkill()
    yOffset = self:CreateStat("Defense", tostring(defense), yOffset)

    local dodge = GetDodgeChance()
    yOffset = self:CreateStat("Dodge", string.format("%.2f%%", dodge), yOffset)

    local parry = GetParryChance()
    yOffset = self:CreateStat("Parry", string.format("%.2f%%", parry), yOffset)

    local block = GetBlockChance()
    yOffset = self:CreateStat("Block", string.format("%.2f%%", block), yOffset)

    local contentHeight = math.abs(yOffset) + 20
    self.panelFrame.scrollChild:SetHeight(contentHeight)
end

function CS:ForceUpdateBarStats()
    if not self.barFrame then
        return
    end

    -- Wipe the change-detection cache so UpdateBarStats treats every stat as changed.
    self.statCache = {}

    local wasShown = self.barFrame:IsShown()
    if not wasShown then self.barFrame:Show() end
    self:UpdateBarStats()
    if not wasShown then self.barFrame:Hide() end

    RC:DebugPrint("Force update bar stats completed", "charstats")
end

