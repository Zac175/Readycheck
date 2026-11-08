------------------------------------------------------------------------
-- Readycheck - TTK Display
-- The TTK HUD, three rows:
--   Expected   the usual kill time for this boss (history), fixed for the
--              fight; "~" when there is no history yet and it is this
--              pull's own projection instead
--   Time left  THE time left - RC:GetTTKRemaining(), the very number the
--              ability reminders fire on and custom reminders read, so it
--              never depends on what is targeted
--   Pace       this pull's projected kill time against the usual one
-- tracking.currentTTK still carries the time left for older Lua reminders.
-- CalculateRealtimeTTK (raw target-health extrapolation) is no longer what
-- the HUD shows; it stays for anything else that calls it.
------------------------------------------------------------------------
local AddonName = "Readycheck"

local math_floor = math.floor
local string_format = string.format
local GetTime = GetTime
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitExists = UnitExists
local UnitGUID = UnitGUID
local UnitName = UnitName
local UnitAffectingCombat = UnitAffectingCombat
local GetScreenWidth = GetScreenWidth
local GetScreenHeight = GetScreenHeight
local CreateFrame = CreateFrame
local C_Timer = C_Timer

local function InitializeTTKDisplayModule()
    local RC = _G[AddonName]
    if not RC then
        C_Timer.After(0.1, InitializeTTKDisplayModule)
        return
    end

    if RC.TTKDisplay and RC.TTKDisplay.moduleLoaded then
        return
    end
    -- reads enemy health, which Forever hides in combat (Core_Flavor)
    if RC.FeatureOn and not RC:FeatureOn("ttk") then return end

    RC.TTKDisplay = RC.TTKDisplay or {}
    local TTK = RC.TTKDisplay
    TTK.moduleLoaded = true

    TTK.ttkFrame = nil
    TTK.eventFrame = nil
    TTK.initialized = false
    TTK.ttkDisplayInitialized = false
    TTK.testMode = false

    -- health0/time0 anchor the damage window at the first sub-max health
    -- reading; mhealth/mtime are a halving running midpoint that forms
    -- the far end of that window. currentTTK is the cached result other
    -- modules read directly.
    TTK.tracking = {
        bossGUID = nil,
        lastHealth = nil,
        health0 = nil,
        time0 = nil,
        mhealth = nil,
        mtime = nil,
        currentTTK = nil
    }

-- RC:FormatTime moved to the main addon's Core\Core_Boot.lua - consumed
-- addon-wide (stats bar, world buff timers, cooldown text), so it cannot
-- live in an addon the user can switch off. TTK:FormatTime below still
-- wraps it for the "--:--" empty case.

-- ttkDisplay.formats.time (the customization standard) words every time
-- on the HUD; unset, RC:FormatTime as always.
TTK.TIME_FORMAT = { time = "mmss" }
local ttkVals, ttkKinds = {}, { value = "time" }
function TTK:FormatTime(seconds)
    if not seconds or seconds <= 0 then return "--:--" end
    local s = RC.db and RC.db.ttkDisplay
    local f = s and type(s.formats) == "table" and s.formats.time or nil
    if f then
        ttkVals.value = seconds
        return RC.UI:FormatText(f, TTK.TIME_FORMAT, ttkVals, ttkKinds, "value")
    end
    return RC:FormatTime(seconds)
end

function TTK:ResetTracking()
    self.tracking.health0 = nil
    self.tracking.time0 = nil
    self.tracking.mhealth = nil
    self.tracking.mtime = nil
    self.tracking.currentTTK = nil
    self.tracking.lastHealth = nil
    self.tracking.bossGUID = nil
end

-- Returns (remainingSeconds, health, maxHealth). The estimate is
-- health * (windowElapsed / healthLostOverWindow), in raw health units
-- rather than percent, so maxHealth never enters the arithmetic.
-- Purely observational: no history, no model, no encounter config.
function TTK:CalculateRealtimeTTK()
    if not RC.executeCalculator or not RC.executeCalculator.currentFight then
        self:ResetTracking()
        return nil, nil, nil
    end

    local fight = RC.executeCalculator.currentFight
    if not fight.started then
        self:ResetTracking()
        return nil, nil, nil
    end

    local aliasSet
    local encCfg = RC.encounterAddPhases and RC.encounterAddPhases[fight.encounterName]
    if encCfg and encCfg.aliases then
        aliasSet = {}
        for _, a in ipairs(encCfg.aliases) do
            aliasSet[a] = true
        end
    end

    -- During an add phase only the canonical encounter name is accepted;
    -- the original targetName and the aliases are adds at that point and
    -- must not be allowed to seed the damage window.
    local isAddPhase = (encCfg and encCfg.addPhasesBeforeBoss) and not fight.bossEngaged

    local trackedGUID = fight.primaryBoss and fight.primaryBoss.guid
    local function isTrackedBoss(unit)
        if not UnitExists(unit) or UnitIsDead(unit) then return false end
        if trackedGUID and UnitGUID(unit) == trackedGUID then return true end
        local name = UnitName(unit)
        if not name then return false end
        if name == fight.encounterName then return true end
        if not isAddPhase then
            if name == fight.targetName then return true end
            if aliasSet and aliasSet[name] then return true end
        end
        return false
    end

    -- Target-only, unlike the model paths which fall back to raid scans:
    -- the window needs a continuous health series from one unit, so the
    -- row goes blank the moment the player looks away.
    if not isTrackedBoss("target") then return nil, nil, nil end
    local bossUnit = "target"


    local health = UnitHealth(bossUnit)
    local maxHealth = UnitHealthMax(bossUnit)
    if not health or not maxHealth or maxHealth == 0 then return nil, nil, nil end

    local time = GetTime()
    local track = self.tracking

    local currentGUID = UnitGUID(bossUnit)
    if track.bossGUID and track.bossGUID ~= currentGUID then
        self:ResetTracking()
    end
    track.bossGUID = currentGUID

    -- Unchanged health carries no new information. Reuse the cached
    -- value instead of extending the window, which would otherwise let
    -- timeElapsed grow against a fixed healthLost and inflate the result.
    if track.lastHealth and track.lastHealth == health then
        return track.currentTTK, health, maxHealth
    end
    track.lastHealth = health

    if health >= maxHealth then
        self:ResetTracking()
        return nil, health, maxHealth
    end

    if not track.health0 then
        track.health0 = health
        track.time0 = time
        track.mhealth = health
        track.mtime = time
        return nil, health, maxHealth
    end

    -- Halving average: each reading drags the midpoint halfway toward
    -- itself, so recent damage carries roughly double the weight of the
    -- sample before it. This is the only smoothing in the realtime path.
    track.mhealth = (track.mhealth + health) / 2
    track.mtime = (track.mtime + time) / 2

    -- Net healing past the anchor invalidates the window entirely.
    if track.mhealth >= track.health0 then
        self:ResetTracking()
        return nil, health, maxHealth
    end

    local healthLost = track.health0 - track.mhealth
    local timeElapsed = track.mtime - track.time0

    if healthLost <= 0 or timeElapsed <= 0 then
        return track.currentTTK, health, maxHealth
    end

    local calculatedTTK = health * (timeElapsed / healthLost)

    -- Over 900s is noise from a very small damage window rather than a
    -- real 15-minute fight; discard rather than display it.
    if calculatedTTK <= 0 or calculatedTTK > 900 then
        track.currentTTK = nil
        return nil, health, maxHealth
    end

    track.currentTTK = math_floor(calculatedTTK)
    return track.currentTTK, health, maxHealth
end

-- The fonts: valueFont, labelFont and headerFont hold face / outline /
-- shadow; the sizes stay on fontSize (values; labels 2 smaller unless
-- labelFont.size) and headerFontSize.
local VALUE_FONT  = { shadow = true }
local HEADER_FONT = { shadow = true }

-- The HUD's visual parts with no position, mouse or name, so the settings
-- preview builds one on its canvas; StyleDisplay paints both alike.
function TTK:BuildDisplayFrame(parent, name)
    local f = CreateFrame("Frame", name, parent)
    f:SetSize(120, 70)

    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetAllPoints()

    f.borderTop = f:CreateTexture(nil, "BORDER")
    f.borderTop:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.borderTop:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    f.borderTop:SetHeight(1)

    f.borderBottom = f:CreateTexture(nil, "BORDER")
    f.borderBottom:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    f.borderBottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    f.borderBottom:SetHeight(1)

    f.borderLeft = f:CreateTexture(nil, "BORDER")
    f.borderLeft:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.borderLeft:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 0, 0)
    f.borderLeft:SetWidth(1)

    f.borderRight = f:CreateTexture(nil, "BORDER")
    f.borderRight:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    f.borderRight:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    f.borderRight:SetWidth(1)

    -- The title bar every Readycheck tracker wears (the route tracker, the
    -- Battle Shout tracker): the header art's gradient fill and stepped
    -- accent rule, the title left-aligned in the header text colour. It
    -- takes exactly the room the old centred caption did, so the rows and
    -- a saved frame size line up as before.
    f.head = CreateFrame("Frame", nil, f)
    f.head:SetPoint("TOPLEFT",  f, "TOPLEFT",  1, -1)
    f.head:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    f.head:SetHeight(16)
    local hfill = f.head:CreateTexture(nil, "BACKGROUND")
    hfill:SetAllPoints()
    hfill:SetTexture(RC.UI.FLAT)
    f.head.fill = hfill
    if RC.UI.ApplyHeaderArt then
        RC.UI:ApplyHeaderArt(f.head, { compact = true })
    else
        local hb = RC:GetColor("ui", "headerBackground")
        hfill:SetVertexColor(hb.r, hb.g, hb.b, hb.a or 1)
    end

    -- templates = placeholder fonts until StyleDisplay sets the real ones
    -- (the client refuses SetText on a font-less string)
    f.header = f.head:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.header:SetPoint("LEFT",  f.head, "LEFT",  6, 1)
    f.header:SetPoint("RIGHT", f.head, "RIGHT", -6, 1)
    f.header:SetJustifyH("LEFT")
    f.header:SetWordWrap(false)
    if f.header.SetMaxLines then f.header:SetMaxLines(1) end
    f.header:SetText(RCL["TTK Display"])
    if RC.UI.TagElement then RC.UI:TagElement(f.header, "header") end

    f.predictedLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.predictedValue = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.predictedValue:SetText("--:--")
    f.realtimeLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.realtimeValue = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.realtimeValue:SetText("--:--")
    f.paceLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.paceValue = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.paceValue:SetText("--")
    if RC.UI.TagElement then
        for _, e in ipairs({ { "predictedLabel", "expectedLabel" }, { "predictedValue", "expected" }, { "realtimeLabel", "leftLabel" },
            { "realtimeValue", "left" }, { "paceLabel", "paceLabel" }, { "paceValue", "pace" } }) do
            RC.UI:TagElement(f[e[1]], e[2])
        end
    end

    self:StyleDisplay(f, RC.db and RC.db.ttkDisplay or {})
    return f
end

local function Spec(t, key, size)
    local s = type(t[key]) == "table" and t[key] or {}
    return { face = s.face, outline = s.outline, shadow = s.shadow, size = size or s.size }
end

-- Size, fonts, colours, background, border thickness and the text layout
-- from the settings: the live HUD and the preview sample alike.
function TTK:StyleDisplay(f, settings)
    settings = settings or {}
    local width          = settings.width or 120
    local height         = self:FitHeight(settings)
    local fontSize       = settings.fontSize or 14
    local headerFontSize = settings.headerFontSize or 10
    local showLabels     = (settings.showLabels == true) or (settings.showLabels == nil)
    local shortLabels    = settings.shortLabels == true
    local centerText     = settings.centerText == true
    local showPace       = settings.showPace ~= false

    f:SetSize(width, height)

    local headArea  = self:HeaderArea(settings)
    local rowCount  = showPace and 3 or 2
    local rowHeight = math.max(fontSize, (height - headArea - 3) / rowCount)
    local row1Y = -headArea
    local row2Y = row1Y - rowHeight
    local row3Y = row1Y - rowHeight * 2

    f.head:SetHeight(headerFontSize + 6)
    f.head:SetShown(settings.showHeader ~= false)
    RC:ApplyFontSpec(f.header, Spec(settings, "headerFont", headerFontSize), HEADER_FONT)
    f.header:SetShadowColor(0, 0, 0, 0.9)

    local vSpec = Spec(settings, "valueFont", fontSize)
    local lf = type(settings.labelFont) == "table" and settings.labelFont or {}
    local lSpec = Spec(settings, "labelFont", lf.size or (fontSize - 2))
    for _, fs in ipairs({ f.predictedLabel, f.realtimeLabel, f.paceLabel }) do RC:ApplyFontSpec(fs, lSpec, VALUE_FONT) end
    for _, fs in ipairs({ f.predictedValue, f.realtimeValue, f.paceValue }) do RC:ApplyFontSpec(fs, vSpec, VALUE_FONT) end

    local bs = tonumber(settings.borderSize) or 1
    for _, t in ipairs({ f.borderTop, f.borderBottom }) do t:SetHeight(math.max(bs, 0.01)) end
    for _, t in ipairs({ f.borderLeft, f.borderRight }) do t:SetWidth(math.max(bs, 0.01)) end
    f._noBorder = bs <= 0

    self:PaintDisplayColors(f)
    self:ApplyBackgroundVisibility(f, settings)
    self:ApplyTextPositioning(f, showLabels, shortLabels, centerText, row1Y, row2Y, row3Y, showPace)
    self:ApplyTextAnchors(f, settings)
    -- layer / scale / clamp, fade rules and shadow / glow (the standard)
    if RC.ApplyFrameCustom then
        RC:ApplyFrameCustom(f, function() return RC.db and RC.db.ttkDisplay end, { sample = (f ~= self.ttkFrame) })
    end
end

------------------------------------------------------------------------
-- The customization standard on the HUD (settings.anchors.<element>):
-- every text placeable. Each text's default is where the layout above
-- just put it (labels on / off, centred, the pace row), so "Labels: on"
-- or "Centre the text" still decide the defaults and a spec goes on top.
------------------------------------------------------------------------
TTK.TEXT_ELEMENTS = {
    { key = "header", field = "header", label = RCL["Title"] },
    { key = "expectedLabel", field = "predictedLabel", label = RCL["Expected label"] },
    { key = "expected", field = "predictedValue", label = RCL["Expected time"] },
    { key = "leftLabel", field = "realtimeLabel", label = RCL["Time left label"] },
    { key = "left", field = "realtimeValue", label = RCL["Time left"] },
    { key = "paceLabel", field = "paceLabel", label = RCL["Pace label"] },
    { key = "pace", field = "paceValue", label = RCL["Pace"] },
}
local FIELD_OF = {}
for _, e in ipairs(TTK.TEXT_ELEMENTS) do FIELD_OF[e.key] = e.field end
TTK.TEXT_TARGETS = { { value = "frame", text = RCL["The display"] }, { value = "head", text = RCL["Title bar"] } }
for _, e in ipairs(TTK.TEXT_ELEMENTS) do TTK.TEXT_TARGETS[#TTK.TEXT_TARGETS + 1] = { value = e.key, text = e.label } end

-- the point a text has now, as an anchor default (one reused table each)
local function Capture(f, key, region)
    f._ttkDef = f._ttkDef or {}
    local d = f._ttkDef[key] or {}
    f._ttkDef[key] = d
    local n = region:GetNumPoints() or 0
    d.point, d.to, d.relPoint, d.x, d.y = nil, nil, nil, nil, nil
    d.point2, d.to2, d.relPoint2, d.x2, d.y2 = nil, nil, nil, nil, nil
    if n >= 1 then d.point, d.to, d.relPoint, d.x, d.y = region:GetPoint(1) end
    if n >= 2 then d.point2, d.to2, d.relPoint2, d.x2, d.y2 = region:GetPoint(2) end
    d.justify = region.GetJustifyH and region:GetJustifyH() or nil
    return d
end
function TTK:ApplyTextAnchors(f, settings)
    local a = type(settings.anchors) == "table" and settings.anchors or nil
    if not f._ttkTo then
        f._ttkTo = function(k)
            if k == "frame" then return f elseif k == "head" then return f.head end
            local fld = FIELD_OF[k]
            return fld and f[fld] or nil
        end
    end
    for _, e in ipairs(self.TEXT_ELEMENTS) do
        local region = f[e.field]
        if region then
            -- the title's place is set once at build: put it back before
            -- reading it, in case a spec moved it last time
            if e.key == "header" and f._ttkHeaderMoved then
                region:ClearAllPoints()
                region:SetPoint("LEFT", f.head, "LEFT", 6, 1)
                region:SetPoint("RIGHT", f.head, "RIGHT", -6, 1)
                region:SetJustifyH("LEFT")
                f._ttkHeaderMoved = nil
            end
            local def = Capture(f, e.key, region)
            local spec = a and a[e.key]
            if spec and def.point then
                RC.UI:ApplyAnchor(region, spec, def, f._ttkTo)
                if e.key == "header" then f._ttkHeaderMoved = true end
            end
        end
    end
end
-- an element's default for the settings page (the live HUD's, else the
-- preview sample's)
function TTK:TextAnchorDefault(key, sample)
    local f = self.ttkFrame or sample
    return f and f._ttkDef and f._ttkDef[key] or { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
end

function TTK:CreateTTKDisplay()
    if self.ttkFrame then return self.ttkFrame end

    local settings = RC.db.ttkDisplay or {}
    local f = self:BuildDisplayFrame(UIParent, "WR_TTKDisplay")
    f:SetFrameStrata("MEDIUM")
    f:SetFrameLevel(50)
    f:SetClampedToScreen(true)

    RC.Position.Bind(f, function()
        RC.db.ttkDisplay = RC.db.ttkDisplay or {}
        return RC.db.ttkDisplay
    end, { point = "TOP", pointKey = "anchorPoint", default = { point = "TOP", x = 0, y = -100 } })
    RC.Position.RestoreFrame(f)

    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetMovable(not settings.locked)
    f.wantMouse = true

    RC.Position.MakeMovable(f, function()
        return RC.db.ttkDisplay and not RC.db.ttkDisplay.locked
    end)

    f:SetScript("OnMouseDown", function(frame, button)
        if button == "RightButton" and RC.db.ttkDisplay then
            RC.db.ttkDisplay.locked = not RC.db.ttkDisplay.locked
            frame:SetMovable(not RC.db.ttkDisplay.locked)
            RC:Print(RC.db.ttkDisplay.locked and RCL["TTK display locked"] or RCL["TTK display unlocked - drag to move"])
            if RC.SaveConfigurationToProfile then
                RC:SaveConfigurationToProfile()
            end
        end
    end)

    f:Hide()
    self.ttkFrame = f

    return f
end

-- Entrance / exit of the live HUD (ttkDisplay.showAnim / hideAnim; nil =
-- instant, as it has always been).
local NO_MOTION = { style = "none" }
function TTK:ShowHUD()
    local f = self.ttkFrame
    if not f then return end
    if f:IsShown() and not f._ttkLeaving then return end
    f._ttkLeaving = nil
    local s = RC.db and RC.db.ttkDisplay or {}
    if not RC.Motion.Show(f, s.showAnim or NO_MOTION) then f:Show() end
end
function TTK:HideHUD()
    local f = self.ttkFrame
    if not f or not f:IsShown() or f._ttkLeaving then return end
    local s = RC.db and RC.db.ttkDisplay or {}
    f._ttkLeaving = true
    RC.Motion.Hide(f, s.hideAnim or NO_MOTION, function() f._ttkLeaving = nil end)
    if not f:IsShown() then f._ttkLeaving = nil end
end

-- Tall enough for every row at the chosen font size: a big font in a short
-- frame used to draw the rows over each other. The saved height is kept;
-- the frame is only drawn taller when the rows would otherwise overlap.
function TTK:FitHeight(settings)
    settings = settings or {}
    local height = settings.height or 70
    local fontSize = settings.fontSize or 14
    local rows = (settings.showPace ~= false) and 3 or 2
    local need = self:HeaderArea(settings) + 3 + rows * fontSize
    return math.max(height, need)
end

-- The room the top of the frame takes before the first row: the title
-- bar and the gap under it, or with the title bar switched off (showHeader
-- false) a few pixels of padding, so the rows move up into its place.
function TTK:HeaderArea(settings)
    settings = settings or {}
    if settings.showHeader == false then return 4 end
    return (settings.headerFontSize or 10) + 7
end

-- A locked HUD lets clicks through to the world while in combat; out of
-- combat it still takes the right-click that unlocks it.
function TTK:UpdateMouse(enteringCombat)
    local f = self.ttkFrame
    if not f then return end
    local s = RC.db and RC.db.ttkDisplay
    local inCombat = enteringCombat or InCombatLockdown() or UnitAffectingCombat("player")
    local want = not (s and s.locked and inCombat)
    if f.wantMouse ~= want then
        f.wantMouse = want
        f:EnableMouse(want)
    end
end

function TTK:ApplyBackgroundVisibility(frame, settings)
    local show = settings.showBackground ~= false
    local edge = show and not frame._noBorder
    if frame.bg then frame.bg:SetShown(show) end
    if frame.borderTop then frame.borderTop:SetShown(edge) end
    if frame.borderBottom then frame.borderBottom:SetShown(edge) end
    if frame.borderLeft then frame.borderLeft:SetShown(edge) end
    if frame.borderRight then frame.borderRight:SetShown(edge) end
    -- a chromeless display keeps its title but drops the bar behind it
    local head = frame.head
    if head then
        if head.fill then head.fill:SetShown(show) end
        local art = head._art
        if art then
            if art.cutL then art.cutL:SetShown(show) end
            if art.cutD then art.cutD:SetShown(show) end
            for _, t in ipairs(art.rules or {}) do t:SetShown(show) end
        end
    end
end

function TTK:ApplyTextPositioning(frame, showLabels, shortLabels, centerText, row1Y, row2Y, row3Y, showPace)
    if not frame then return end

    if frame.predictedLabel then frame.predictedLabel:ClearAllPoints() end
    if frame.predictedValue  then frame.predictedValue:ClearAllPoints()  end
    if frame.realtimeLabel   then frame.realtimeLabel:ClearAllPoints()   end
    if frame.realtimeValue   then frame.realtimeValue:ClearAllPoints()   end
    if frame.paceLabel       then frame.paceLabel:ClearAllPoints()       end
    if frame.paceValue       then frame.paceValue:ClearAllPoints()       end

    local predLbl  = shortLabels and "Exp:" or "Expected:"
    local realLbl  = shortLabels and "Left:" or "Time left:"
    local paceLbl  = "Pace:" -- no shorter form; same in both modes

    if showLabels then
        if frame.predictedLabel then frame.predictedLabel:SetText(predLbl) frame.predictedLabel:Show() end
        if frame.realtimeLabel  then frame.realtimeLabel:SetText(realLbl)  frame.realtimeLabel:Show()  end
        if frame.paceLabel      then frame.paceLabel:SetText(paceLbl)      frame.paceLabel:Show()      end
    else
        if frame.predictedLabel then frame.predictedLabel:SetText("") frame.predictedLabel:Hide() end
        if frame.realtimeLabel  then frame.realtimeLabel:SetText("") frame.realtimeLabel:Hide()  end
        if frame.paceLabel      then frame.paceLabel:SetText("")     frame.paceLabel:Hide()      end
    end

    local xPad = 6
    -- Values stay inside the frame: one line each, cut at the edge rather
    -- than spilling past it ("Expected: 3:00 (45%)" is wider than 120px).
    for _, v in ipairs({ frame.predictedValue, frame.realtimeValue, frame.paceValue }) do
        v:SetWordWrap(false)
        if v.SetMaxLines then v:SetMaxLines(1) end
        v:SetWidth(0)
    end
    local fullW = math.max(20, (frame:GetWidth() or 120) - xPad * 2)
    if centerText and showLabels then
        -- centred with labels: a two-column table split near the middle,
        -- labels right-aligned up to the split, values left-aligned after
        -- it and cut at the frame's edge (the split moves right when a
        -- label is wider than half the frame)
        local frameW = frame:GetWidth() or 120
        local L = 0
        for _, l in ipairs({ frame.predictedLabel, frame.realtimeLabel, showPace and frame.paceLabel or nil }) do
            local w = l and l.GetStringWidth and l:GetStringWidth() or 0
            if w > L then L = w end
        end
        local split = math.max(math.floor(frameW / 2), xPad + math.ceil(L) + 1)
        local rows = { { frame.predictedLabel, frame.predictedValue, row1Y },
                       { frame.realtimeLabel, frame.realtimeValue, row2Y } }
        if showPace then rows[3] = { frame.paceLabel, frame.paceValue, row3Y } end
        for _, r in ipairs(rows) do
            local l, v, y = r[1], r[2], r[3]
            if l then
                l:SetJustifyH("RIGHT")
                l:SetPoint("TOPRIGHT", frame, "TOPLEFT", split - 1, y)
            end
            if v then
                v:SetJustifyH("LEFT")
                v:SetPoint("TOPLEFT", frame, "TOPLEFT", split + 2, y)
                v:SetPoint("RIGHT", frame, "RIGHT", -xPad, 0)
            end
        end
        if frame.paceValue then frame.paceValue:SetShown(showPace) end
    elseif centerText then
        for _, v in ipairs({ frame.predictedValue, frame.realtimeValue, frame.paceValue }) do
            v:SetWidth(fullW)
            v:SetJustifyH("CENTER")
        end
        if frame.predictedValue then frame.predictedValue:SetPoint("TOP", frame, "TOP", 0, row1Y) end
        if frame.realtimeValue  then frame.realtimeValue:SetPoint("TOP", frame, "TOP", 0, row2Y) end
        if showPace and frame.paceValue then
            frame.paceValue:SetPoint("TOP", frame, "TOP", 0, row3Y)
            frame.paceValue:Show()
        elseif frame.paceValue then
            frame.paceValue:Hide()
        end
    else
        for _, v in ipairs({ frame.predictedValue, frame.realtimeValue, frame.paceValue }) do
            v:SetJustifyH("LEFT")
        end
        if showLabels then
            if frame.predictedLabel then frame.predictedLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", xPad, row1Y) end
            if frame.predictedValue then
                frame.predictedValue:SetPoint("LEFT", frame.predictedLabel, "RIGHT", 3, 0)
                frame.predictedValue:SetPoint("RIGHT", frame, "RIGHT", -xPad, 0)
            end
            if frame.realtimeLabel  then frame.realtimeLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", xPad, row2Y) end
            if frame.realtimeValue  then
                frame.realtimeValue:SetPoint("LEFT", frame.realtimeLabel, "RIGHT", 3, 0)
                frame.realtimeValue:SetPoint("RIGHT", frame, "RIGHT", -xPad, 0)
            end
            if showPace then
                if frame.paceLabel then frame.paceLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", xPad, row3Y) end
                if frame.paceValue then
                    frame.paceValue:SetPoint("LEFT", frame.paceLabel, "RIGHT", 3, 0)
                    frame.paceValue:SetPoint("RIGHT", frame, "RIGHT", -xPad, 0)
                end
            end
        else
            if frame.predictedValue then frame.predictedValue:SetPoint("TOPLEFT", frame, "TOPLEFT", xPad, row1Y); frame.predictedValue:SetWidth(fullW) end
            if frame.realtimeValue  then frame.realtimeValue:SetPoint("TOPLEFT", frame, "TOPLEFT", xPad, row2Y); frame.realtimeValue:SetWidth(fullW) end
            if showPace and frame.paceValue then frame.paceValue:SetPoint("TOPLEFT", frame, "TOPLEFT", xPad, row3Y); frame.paceValue:SetWidth(fullW) end
        end
        if showPace and frame.paceValue then frame.paceValue:Show()
        elseif frame.paceValue then frame.paceValue:Hide() end
    end
end

function TTK:UpdateTTKDisplayAppearance()
    if not self.ttkFrame then return end
    self:StyleDisplay(self.ttkFrame, RC.db.ttkDisplay or {})
end

function TTK:UpdateTTKDisplayBackground()
    if not self.ttkFrame then return end
    local settings = RC.db.ttkDisplay or {}
    self:ApplyBackgroundVisibility(self.ttkFrame, settings)
end

-- The theme colours (Appearance > Colors > the ttkDisplay group, also on
-- the TTK page) onto a HUD frame.
function TTK:PaintDisplayColors(f)
    -- colours are written straight below; forget what the live update
    -- last painted so it paints its own again on the next refresh
    for _, fs in ipairs({ f.predictedValue, f.realtimeValue, f.paceValue }) do
        if fs then fs._shownColor = nil end
    end
    local function C(k) return RC:GetColor("ttkDisplay", k) end
    local bgColor = C("background")
    f.bg:SetColorTexture(bgColor.r, bgColor.g, bgColor.b, bgColor.a or 0.8)
    local headerColor = C("headerText")
    f.header:SetTextColor(headerColor.r, headerColor.g, headerColor.b, 1)
    if f.head and f.head.RepaintArt then f.head:RepaintArt() end
    local labelColor = C("labelText")
    for _, fs in ipairs({ f.predictedLabel, f.realtimeLabel, f.paceLabel }) do
        fs:SetTextColor(labelColor.r, labelColor.g, labelColor.b, 1)
    end
    local p, r, n = C("predictedText"), C("realtimeText"), C("paceNeutral")
    f.predictedValue:SetTextColor(p.r, p.g, p.b, 1)
    f.realtimeValue:SetTextColor(r.r, r.g, r.b, 1)
    f.paceValue:SetTextColor(n.r, n.g, n.b, 1)
    local borderColor = C("border")
    for _, t in ipairs({ f.borderTop, f.borderBottom, f.borderLeft, f.borderRight }) do
        t:SetColorTexture(borderColor.r, borderColor.g, borderColor.b, 1)
    end
end

function TTK:RefreshTTKDisplayColors()
    if not self.ttkFrame then return end
    self:PaintDisplayColors(self.ttkFrame)
end

-- Text and colour are only handed to the font strings when they change:
-- the HUD refreshes twice a second and most ticks change nothing.
local function SetTextIf(fs, text)
    if fs and fs._shownText ~= text then
        fs._shownText = text
        fs:SetText(text)
    end
end
local function SetColorIf(fs, c)
    if not (fs and c) then return end
    local k = c.r * 1000000 + c.g * 1000 + c.b
    if fs._shownColor ~= k then
        fs._shownColor = k
        fs:SetTextColor(c.r, c.g, c.b, 1)
    end
end

function TTK:UpdateDisplay()
    if not self.ttkFrame then
        return
    end

    local settings = RC.db.ttkDisplay
    if not settings then
        return
    end

    if RC.Profiler then RC.Profiler:StartTiming("TTKDisplay") end

    local f = self.ttkFrame
    local fight = RC.executeCalculator and RC.executeCalculator.currentFight
    local sim = RC.activeSimulation
    local activeFight = (fight and fight.started) and fight or nil

    local bossName = "No Target"
    if activeFight and activeFight.encounterName then
        bossName = activeFight.historyName or activeFight.encounterName
        if sim then bossName = bossName .. " (Sim)" end
    elseif sim and sim.bossName then
        bossName = sim.bossName .. " (Sim)"
    end
    SetTextIf(f.header, bossName)

    local calc = RC.executeCalculator
    local classicMode = calc and calc.mode == "classic"
    local threshold = (calc and calc.mlConfig and calc.mlConfig.confidenceThreshold) or 0.25

    -- the usual kill time, fixed for the fight
    local expected, confidence, kills = nil, 0, 0
    if sim then
        expected, confidence = sim.predictedTTK, sim.confidence or 0.5
    elseif activeFight and RC.GetFightExpectedTTK and not classicMode then
        expected, confidence, kills = RC:GetFightExpectedTTK(activeFight)
    end

    -- the one shared time left
    local remaining, total, _, source, liveTotal
    if RC.GetTTKRemaining then
        remaining, total, _, source, liveTotal = RC:GetTTKRemaining()
    end
    self.tracking.currentTTK = remaining and math_floor(remaining) or nil

    local elapsed = 0
    if activeFight and activeFight.bossEngaged and activeFight.bossEngageTime and activeFight.bossEngageTime > 0 then
        elapsed = GetTime() - activeFight.bossEngageTime
    end

    -- No history (or Classic mode): Expected becomes this pull's own
    -- projected kill time, marked "~", and there is no pace to compare.
    local isLiveEstimate = false
    if (not expected or expected <= 0) and not sim and total and source == "pace" then
        expected = total
        confidence = 0
        isLiveEstimate = true
    end

    if expected and expected > 0 then
        local timeStr = self:FormatTime(expected)
        local text
        if isLiveEstimate then
            text = "~" .. timeStr
        elseif settings.showConfidence and confidence > 0 then
            text = string_format("%s (%d%%)", timeStr, math_floor(confidence * 100))
        else
            text = timeStr
        end
        SetTextIf(f.predictedValue, text)
        -- shown dim while too uncertain for the reminders to use it
        local trusted = isLiveEstimate or sim or confidence >= threshold
        SetColorIf(f.predictedValue, RC:GetColor("ttkDisplay", trusted and "predictedText" or "labelText"))
    else
        SetTextIf(f.predictedValue, RCL["No data"])
        SetColorIf(f.predictedValue, RC:GetColor("ttkDisplay", "labelText"))
    end

    if remaining then
        local timeStr = remaining > 0 and self:FormatTime(remaining) or "0:00"
        -- this pull's speed alone, and the boss has not lost health for a
        -- while (Sapphiron in the air): say so rather than guess
        local hpPct = RC.GetEncounterHP and RC:GetEncounterHP()
        if source == "pace" and activeFight and activeFight.hpChangedAt
           and (GetTime() - activeFight.hpChangedAt) >= 5 then
            timeStr = RCL["paused"]
        end
        if settings.showHealthPercent and hpPct then
            SetTextIf(f.realtimeValue, string_format("%s (%d%%)", timeStr, math_floor(hpPct)))
        else
            SetTextIf(f.realtimeValue, timeStr)
        end
    elseif sim then
        local left = (sim.predictedTTK or 60) - (GetTime() - (sim.startTime or GetTime()))
        SetTextIf(f.realtimeValue, left > 0 and (self:FormatTime(left) .. RCL[" (sim)"]) or "0:00")
    else
        SetTextIf(f.realtimeValue, "--:--")
    end

    if f.paceValue and settings.showPace ~= false then
        -- this pull's own projected kill time (its live speed alone, never
        -- the blended number, which leans on the history it is compared
        -- with) against the usual kill time
        local projected = liveTotal
        if not projected and remaining and remaining > 0 and source ~= "history" then
            projected = elapsed + remaining
        end
        if not isLiveEstimate and expected and expected > 0 and projected and projected > 0 then
            -- Deadband: within 5% either way reads as "on pace" so the
            -- label does not flicker on normal DPS variance.
            local pct = math_floor(((expected - projected) / expected) * 100 + 0.5)
            local paceStr, paceKey
            if pct > 5 then
                paceStr, paceKey = string_format(RCL["%d%% faster"], pct), "paceFaster"
            elseif pct < -5 then
                paceStr, paceKey = string_format(RCL["%d%% slower"], -pct), "paceSlower"
            else
                paceStr, paceKey = RCL["on pace"], "paceNeutral"
            end
            SetTextIf(f.paceValue, paceStr)
            SetColorIf(f.paceValue, RC:GetColor("ttkDisplay", paceKey))
        else
            SetTextIf(f.paceValue, "--")
            SetColorIf(f.paceValue, RC:GetColor("ttkDisplay", "paceNeutral"))
        end
    end

    if RC.Profiler then RC.Profiler:StopTiming("TTKDisplay") end
end

function TTK:ShouldShow()
    if self.testMode then
        return true
    end

    if RC._stressTestCombat then
        return true
    end

    local settings = RC.db.ttkDisplay
    if not settings or not settings.enabled then
        return false
    end

    local isSimulation = RC.activeSimulation ~= nil
    if isSimulation then
        return true
    end

    if settings.showOutOfCombat then
        return true
    end

    local fight = RC.executeCalculator and RC.executeCalculator.currentFight
    if not fight or not fight.started then
        return false
    end

    if not fight.encounterName then
        return false
    end

    -- Out of combat only hides it when the fight is really over: some
    -- encounters drop combat between phases and the fight carries on.
    local inCombat = UnitAffectingCombat("player")
    if not inCombat and not (fight.isMultiCombatEncounter or RC.activeEncounterName) then
        return false
    end

    -- During an unengaged add phase the HUD only shows while the boss
    -- itself is targeted, because CalculateRealtimeTTK returns nothing
    -- for adds and both value rows would sit blank.
    if fight.addPhasesBeforeBoss and not fight.bossEngaged then
        if UnitExists("target") then
            local targetName = UnitName("target")
            if targetName == fight.encounterName or targetName == fight.targetName then
                return true
            end
        end
        return false
    end

    return true
end

function TTK:InitializeTTKDisplay()
    if self.initialized then return end
    self.initialized = true
    self.ttkDisplayInitialized = true

    self:CreateTTKDisplay()

    self:UpdateTTKDisplayAppearance()
    self:UpdateTTKDisplayBackground()

    local function Refresh()

        if TTK.testDisplayActive then
            if TTK.ttkFrame and not TTK.ttkFrame:IsShown() then
                TTK.ttkFrame:Show()
            end
            return
        end

        TTK:UpdateMouse()
        if TTK:ShouldShow() then
            TTK:UpdateDisplay()
            TTK:ShowHUD()
        else
            if TTK.ttkFrame and TTK.ttkFrame:IsShown() and not TTK.ttkFrame._ttkLeaving then
                TTK:HideHUD()
                TTK:ResetTracking()
            end
        end
    end
    self._Refresh = Refresh

    self.eventFrame = CreateFrame("Frame")
    self.eventFrame:SetScript("OnEvent", function(_, event, ...)
        if event == "ENCOUNTER_START" then
            Refresh()
        elseif event == "ENCOUNTER_END" then
            if TTK.ttkFrame and TTK.ttkFrame:IsShown() and not TTK.ttkFrame._ttkLeaving then
                TTK:HideHUD()
                TTK:ResetTracking()
            end
        elseif event == "PLAYER_REGEN_ENABLED" then
            Refresh()
        elseif event == "PLAYER_REGEN_DISABLED" then
            TTK:UpdateMouse(true)
        elseif event == "PLAYER_ENTERING_WORLD" then
            Refresh()
        end
    end)

    local function StartEvents()
        local ef = TTK.eventFrame
        if not ef or TTK._eventsRegistered then return end
        ef:RegisterEvent("ENCOUNTER_START")
        ef:RegisterEvent("ENCOUNTER_END")
        ef:RegisterEvent("PLAYER_REGEN_ENABLED")
        ef:RegisterEvent("PLAYER_REGEN_DISABLED")
        ef:RegisterEvent("PLAYER_ENTERING_WORLD")
        TTK._eventsRegistered = true
    end

    local function StopEvents()
        local ef = TTK.eventFrame
        if not ef or not TTK._eventsRegistered then return end
        ef:UnregisterAllEvents()
        TTK._eventsRegistered = false
    end

    -- Named a safety net, but it is the sole update driver: the four
    -- registered events only force a single refresh or hide the frame.
    -- 0.5s matches the execute ticker that feeds currentFight.
    local function StartTicker()
        if TTK._ticker then return end
        if RC.Profiler and RC.Profiler.TrackTicker then
            TTK._ticker = RC.Profiler:TrackTicker("TTKDisplay:SafetyNet", 0.5, Refresh)
        else
            TTK._ticker = C_Timer.NewTicker(0.5, Refresh)
        end
    end

    local function StopTicker()
        if TTK._ticker then
            TTK._ticker:Cancel()
            TTK._ticker = nil
        end
    end

    -- Master switch. When the HUD is off, both the event registrations
    -- and the ticker are torn down, so a disabled display costs nothing.
    -- Re-run from the settings page and on profile load.
    function TTK:UpdateActive()
        local enabled = RC.db and RC.db.ttkDisplay and RC.db.ttkDisplay.enabled
        local shouldRun = enabled or self.testDisplayActive or RC._stressTestCombat
        if shouldRun then
            StartEvents()
            StartTicker()
            Refresh()
        else
            StopEvents()
            StopTicker()
            if self.ttkFrame and self.ttkFrame:IsShown() then
                RC.Motion.Stop(self.ttkFrame)
                self.ttkFrame._ttkLeaving = nil
                self.ttkFrame:Hide()
                self:ResetTracking()
            end
        end
    end

    function RC:UpdateTTKDisplayActive()
        if TTK.UpdateActive then TTK:UpdateActive() end
    end

    local function ArmWhenDbReady()
        if RC.db then
            TTK:UpdateActive()
        else
            C_Timer.After(0.5, ArmWhenDbReady)
        end
    end
    ArmWhenDbReady()

    RC:DebugPrint("TTK Display initialized", "ttk")
end

local function InitWhenDbReady()
    if RC.db then
        TTK:InitializeTTKDisplay()
    else
        C_Timer.After(0.5, InitWhenDbReady)
    end
end
C_Timer.After(0.5, InitWhenDbReady)

RC:DebugPrint("TTKDisplay module loaded", "ttk")

end

-- not where the game hides enemy health (Core_Flavor)
if not (_G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("ttk")) then
    C_Timer.After(0.1, InitializeTTKDisplayModule)
end
