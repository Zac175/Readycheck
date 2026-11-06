------------------------------------------------------------------------
-- Readycheck - Character Stats: the buff list
-- Clicking the stats bar's Buffs cell opens this under the bar: every
-- buff on you, then every hidden slot, then how many slots are free.
-- With a buff remover hung on the counter (ZacUI's), each buff shows
-- Keep or Remove and a click switches it; shift-clicking the Buffs cell
-- pauses the remover.
--
-- The list sits on the bar and moves with it, so it has no position of
-- its own to save. Escape closes it.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
local CS = RC.CharacterStats
local BC = RC.BuffCap
if not (CS and BC) then return end

local ipairs, tostring = ipairs, tostring
local math_floor, math_ceil, math_max = math.floor, math.ceil, math.max
local string_format = string.format
local GetTime = GetTime
local CreateFrame = CreateFrame

local ROW_H, LIST_W, PAD = 16, 260, 5
local HIDDEN_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local STATE_LABEL = { k = "Keep", r = "Remove", s = "Can't remove" }
local HIDDEN_NOTE = {
    learned  = "Measured when a buff was pushed off. Reset it on the Buff Pushoff page.",
    tracking = "Right-click the tracking icon on the minimap to turn it off and free the slot.",
    reserved = "Not on you right now, but it comes back in every fight, so its slot is kept free.",
    stance   = "Your stance takes a buff slot without showing one.",
    defensive = "Comes for 5 seconds after you dodge, parry or block.",
}

local function Brief(rem)
    if rem >= 3600 then return math_floor(rem / 3600) .. "h" end
    if rem >= 60 then return math_ceil(rem / 60) .. "m" end
    return tostring(math_ceil(rem))
end

local function TimeText(untilAt, now)
    if not untilAt or untilAt <= 0 then return "" end
    local rem = untilAt - now
    if rem <= 0 then return "" end
    return Brief(rem)
end

local function StateOf(a)
    local rem = BC:Remover()
    if not (rem and rem.State) then return nil end
    local ok, st = pcall(rem.State, a)
    if ok then return st end
    return nil
end

local function StateColor(st)
    if st == "r" then return RC:GetColor("text", "red") end
    if st == "k" then return RC:GetColor("text", "green") end
    return RC:GetColor("text", "gray")
end

local function CategoryLabel(a)
    local id = a.e and a.e.cat or "seen"
    for _, c in ipairs(RC.BuffCapData.CATEGORIES) do
        if c.id == id then return RCL[c.label] end
    end
    return ""
end

------------------------------------------------------------------------
-- ROWS
------------------------------------------------------------------------
local function RowTooltip(row)
    local gray = RC:GetColor("text", "gray")
    local title = RC:GetColor("text", "gold")
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    if row.hiddenInfo then
        local h = row.hiddenInfo
        GameTooltip:SetText(h.label, title.r, title.g, title.b)
        GameTooltip:AddLine(RCL["Takes a buff slot but never shows on your buff bar."], 1, 1, 1, true)
        if HIDDEN_NOTE[h.src] then GameTooltip:AddLine(RCL[HIDDEN_NOTE[h.src]], gray.r, gray.g, gray.b, true) end
        GameTooltip:Show()
        return
    end
    local a = row.aura
    if not a then return end
    if a.inst and GameTooltip.SetUnitBuffByAuraInstanceID then
        GameTooltip:SetUnitBuffByAuraInstanceID("player", a.inst)
    else
        GameTooltip:SetUnitBuff("player", a.idx)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(CategoryLabel(a), gray.r, gray.g, gray.b)
    local st = row.state
    if a.e and a.e.provided then
        GameTooltip:AddLine(RCL["The player giving it keeps putting it back."], gray.r, gray.g, gray.b, true)
    elseif a.e and a.e.locked then
        GameTooltip:AddLine(RCL["The game does not let this buff be cancelled."], gray.r, gray.g, gray.b, true)
    end
    if st then
        local c = StateColor(st)
        GameTooltip:AddLine(RCL[STATE_LABEL[st]], c.r, c.g, c.b)
        if st ~= "s" then
            GameTooltip:AddLine(RCL["Click to switch between Keep and Remove."], gray.r, gray.g, gray.b)
        end
    end
    GameTooltip:Show()
end

local function MakeRow(ui, i)
    local r = CreateFrame("Button", nil, ui)
    r:SetHeight(ROW_H)
    r:SetPoint("TOPLEFT", ui, "TOPLEFT", PAD, -(PAD + (i - 1) * ROW_H))
    r:SetPoint("TOPRIGHT", ui, "TOPRIGHT", -PAD, -(PAD + (i - 1) * ROW_H))
    r.bg = r:CreateTexture(nil, "BACKGROUND")
    r.bg:SetAllPoints()
    r.bg:SetTexture(RC.UI.FLAT)
    local barCol = RC:GetColor("statsBar", "background")
    local lift = 0.14
    local hover = { r = barCol.r + (1 - barCol.r) * lift, g = barCol.g + (1 - barCol.g) * lift,
                    b = barCol.b + (1 - barCol.b) * lift, a = 0.85 }
    local norm = { r = hover.r, g = hover.g, b = hover.b, a = 0 }
    r.bg:SetVertexColor(norm.r, norm.g, norm.b, 0)
    RC.UI:AttachHover(r, norm, hover, {
        onEnter = RowTooltip,
        onLeave = function() GameTooltip:Hide() end,
    })
    r.icon = r:CreateTexture(nil, "ARTWORK")
    r.icon:SetSize(ROW_H - 2, ROW_H - 2)
    r.icon:SetPoint("LEFT", r, "LEFT", 1, 0)
    r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    r.badge = RC:CreateFontString(r, "OVERLAY", nil, 9)
    r.badge:SetPoint("RIGHT", r, "RIGHT", -2, 0)
    r.badge:SetJustifyH("RIGHT")
    r.time = RC:CreateFontString(r, "OVERLAY", nil, 10)
    r.time:SetPoint("RIGHT", r.badge, "LEFT", -4, 0)
    r.time:SetWidth(30)
    r.time:SetJustifyH("RIGHT")
    r.name = RC:CreateFontString(r, "OVERLAY", nil, 10)
    r.name:SetPoint("LEFT", r.icon, "RIGHT", 4, 0)
    r.name:SetPoint("RIGHT", r.time, "LEFT", -2, 0)
    r.name:SetJustifyH("LEFT")
    r.name:SetWordWrap(false)
    r:SetScript("OnClick", function(self)
        local a = self.aura
        local rem = BC:Remover()
        if not a or not (rem and rem.Toggle) or self.state == nil or self.state == "s" then return end
        local ok, err = pcall(rem.Toggle, a)
        if not ok then RC:DebugPrint("BuffList: toggle failed: " .. tostring(err), "charstats") end
        CS:FillBuffList()
        RowTooltip(self)
    end)
    -- (a settings preview's row: looks the same, answers nothing)
    if ui._rcSample then r:EnableMouse(false) end
    ui.rows[i] = r
    return r
end

------------------------------------------------------------------------
-- THE LIST
------------------------------------------------------------------------
-- The list's frame and its parts, on any parent: the live list (on
-- UIParent, named) and the settings preview's sample (on its canvas,
-- no clicks) are the same frame.
local function NewList(parent, name, sample)
    local ui = CreateFrame("Frame", name, parent)
    ui:SetWidth(LIST_W)
    ui:SetFrameStrata("DIALOG")
    ui:SetClampedToScreen(true)
    ui:EnableMouse(not sample)
    ui._rcSample = sample or nil
    ui.bg = ui:CreateTexture(nil, "BACKGROUND")
    ui.bg:SetAllPoints()
    ui.bg:SetTexture(RC.UI.FLAT)
    ui.border = RC.UI:CreateSimpleBorder(ui, 1)
    ui.rows = {}
    ui.foot = RC:CreateFontString(ui, "OVERLAY", nil, 10)
    ui.foot:SetJustifyH("LEFT")
    ui.foot2 = RC:CreateFontString(ui, "OVERLAY", nil, 9)
    ui.foot2:SetJustifyH("LEFT")
    return ui
end

local function Build()
    local ui = NewList(UIParent, "ReadycheckBuffCapList")
    ui:Hide()
    ui:SetScript("OnHide", function()
        BC:Subscribe("buffList", nil)
        if CS._buffListTicker then
            CS._buffListTicker:Cancel()
            CS._buffListTicker = nil
        end
    end)
    if RC.UI.RegisterEscapeClose then RC.UI:RegisterEscapeClose(ui) end
    CS.buffListFrame = ui
    return ui
end

local function Paint(ui)
    local bg = RC:GetColor("statsBar", "background")
    ui.bg:SetVertexColor(bg.r, bg.g, bg.b, math_max(bg.a or 0.95, 0.9))
    RC.UI:UpdateBorderColor(ui.border, RC:GetColor("ui", "borderNormal"))
end

-- By category, then name: a click that switches Keep and Remove must not
-- move the row out from under the mouse.
local CAT_ORDER = {}
for i, c in ipairs(RC.BuffCapData.CATEGORIES) do CAT_ORDER[c.id] = i end
local function Sorted()
    local out = {}
    for _, a in ipairs(BC:List()) do
        out[#out + 1] = { a = a, state = StateOf(a), cat = CAT_ORDER[a.e and a.e.cat or "seen"] or 99 }
    end
    table.sort(out, function(x, y)
        if x.cat ~= y.cat then return x.cat < y.cat end
        if x.a.name ~= y.a.name then return (x.a.name or "") < (y.a.name or "") end
        return x.a.idx < y.a.idx
    end)
    return out
end

-- Draws the list from src = { items = { { a =, state = } }, hidden =
-- { line, ... }, free =, cap =, realCap =, hint =, now = }: the live list
-- (from the buff counter, CS:FillBuffList) and the preview's sample
-- (made-up buffs) both come through here.
local function FillList(ui, src)
    local now = src.now or GetTime()
    local norm = RC:GetColor("text", "normal")
    local gray = RC:GetColor("text", "gray")
    local n = 0
    for _, it in ipairs(src.items) do
        n = n + 1
        local r = ui.rows[n] or MakeRow(ui, n)
        local a = it.a
        r.aura, r.hiddenInfo, r.state = a, nil, it.state
        r.icon:SetTexture(a.icon or HIDDEN_ICON)
        r.icon:SetDesaturated(false)
        r.name:SetText(a.name or "?")
        r.name:SetTextColor(norm.r, norm.g, norm.b)
        r.time:SetText(TimeText(a.exp, now))
        r.time:SetTextColor(gray.r, gray.g, gray.b)
        if it.state then
            local c = StateColor(it.state)
            r.badge:SetText(RCL[STATE_LABEL[it.state]])
            r.badge:SetTextColor(c.r, c.g, c.b)
        else
            r.badge:SetText(CategoryLabel(a))
            r.badge:SetTextColor(gray.r, gray.g, gray.b)
        end
        r:Show()
    end
    for _, h in ipairs(src.hidden) do
        n = n + 1
        local r = ui.rows[n] or MakeRow(ui, n)
        r.aura, r.hiddenInfo, r.state = nil, h, nil
        r.icon:SetTexture(h.icon or HIDDEN_ICON)
        r.icon:SetDesaturated(true)
        r.name:SetText(h.label)
        r.name:SetTextColor(gray.r, gray.g, gray.b)
        r.time:SetText(TimeText(h.untilAt, now))
        r.time:SetTextColor(gray.r, gray.g, gray.b)
        r.badge:SetText(h.src == "reserved" and RCL["Kept free"] or RCL["Hidden"])
        r.badge:SetTextColor(gray.r, gray.g, gray.b)
        r:Show()
    end
    for i = n + 1, #ui.rows do ui.rows[i]:Hide() end

    local free = math_max(0, src.free)
    local col = norm
    if free <= 0 then col = RC:GetColor("text", "red") elseif free <= 1 then col = RC:GetColor("text", "orange") end
    ui.foot:SetText(string_format(RCL["%d of %d slots free (real cap %d)"], free, src.cap, src.realCap))
    ui.foot:SetTextColor(col.r, col.g, col.b)
    ui.foot:ClearAllPoints()
    ui.foot:SetPoint("TOPLEFT", ui, "TOPLEFT", PAD + 2, -(PAD + n * ROW_H + 4))
    local hint = src.hint
    ui.foot2:SetText(hint or "")
    ui.foot2:SetTextColor(gray.r, gray.g, gray.b)
    ui.foot2:ClearAllPoints()
    ui.foot2:SetPoint("TOPLEFT", ui.foot, "BOTTOMLEFT", 0, -3)
    ui.foot2:SetWidth(LIST_W - PAD * 2 - 4)
    local footH = 4 + (ui.foot:GetStringHeight() or 12) + (hint and (3 + (ui.foot2:GetStringHeight() or 10)) or 0)
    ui:SetHeight(PAD * 2 + n * ROW_H + footH + 2)
end

function CS:FillBuffList()
    local ui = self.buffListFrame
    if not (ui and ui:IsShown()) then return end
    local st = BC.state
    local rem = BC:Remover()
    local hint
    if rem and rem.Paused then
        local okp, paused = pcall(rem.Paused)
        if okp and paused then
            hint = RCL["Buff removal is paused. Shift-click Buffs to resume."]
        else
            hint = RCL["Click a buff to keep or remove it. Shift-click Buffs to pause."]
        end
    elseif st.learned < 0 then
        hint = string_format(RCL["%d fewer hidden than expected."], -st.learned)
    end
    FillList(ui, { items = Sorted(), hidden = BC:HiddenLines(), free = st.free, cap = BC.CAP,
        realCap = st.cap, hint = hint, now = GetTime() })
end

-- The settings preview's sample: the list's own frame on the canvas, and
-- its fill with made-up buffs (src as FillList's). Paint as the live list.
function CS.NewBuffListSample(parent)
    local ui = NewList(parent, nil, true)
    return ui
end
function CS.FillBuffListSample(ui, src)
    Paint(ui)
    FillList(ui, src)
    return ui:GetWidth(), ui:GetHeight()
end

local function Tick()
    local ui = CS.buffListFrame
    if not (ui and ui:IsShown()) then return end
    local now = GetTime()
    for _, r in ipairs(ui.rows) do
        if r:IsShown() then
            local untilAt = (r.aura and r.aura.exp) or (r.hiddenInfo and r.hiddenInfo.untilAt)
            r.time:SetText(TimeText(untilAt, now))
        end
    end
end

function CS:ToggleBuffList(anchor)
    local ui = self.buffListFrame or Build()
    if ui:IsShown() then
        ui:Hide()
        return
    end
    Paint(ui)
    ui:ClearAllPoints()
    local bar = self.barFrame or anchor
    local top = bar and bar:GetTop() or 0
    -- open downwards unless the bar sits low on the screen
    if top > 0 and top < (UIParent:GetHeight() or 768) * 0.45 then
        ui:SetPoint("BOTTOMLEFT", anchor or bar, "TOPLEFT", 0, 2)
    else
        ui:SetPoint("TOPLEFT", anchor or bar, "BOTTOMLEFT", 0, -2)
    end
    ui:Show()
    BC:Current()
    BC:Subscribe("buffList", function() CS:FillBuffList() end)
    self:FillBuffList()
    if not self._buffListTicker then
        if RC.Profiler and RC.Profiler.TrackTicker then
            self._buffListTicker = RC.Profiler:TrackTicker("StatsBuffList", 0.5, Tick)
        else
            self._buffListTicker = C_Timer.NewTicker(0.5, Tick)
        end
    end
end

-- The Buffs cell: click lists the buffs, shift-click pauses the remover.
function CS:OnBuffCellClick(cell)
    local rem = BC:Remover()
    if IsShiftKeyDown() and rem and rem.SetPaused and rem.Paused then
        local okp, paused = pcall(rem.Paused)
        pcall(rem.SetPaused, not (okp and paused))
        self:FillBuffList()
        if GameTooltip:IsOwned(cell) then self:ShowStatTooltip(cell) end
        return
    end
    self:ToggleBuffList(cell)
end
