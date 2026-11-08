------------------------------------------------------------------------
-- Readycheck - Sidebar Search Box
-- The dropdown of results under the /rc window's search box, and what
-- the box does as you type. The index and the ranking are
-- Sidebar_Search's (RC.SidebarSearch); the box itself is drawn by
-- Sidebar_Window. This file hooks the window the first time it is made.
--
-- HOW IT READS. Type, and a list drops under the box: up to twelve rows,
-- each with what kind of thing it is (Page / Section / Setting /
-- Command) in the accent colour, its title, and under that where it
-- lives ("Reminders  >  Battle Shout  >  Look"). The first row is lit;
-- the arrow keys (or Tab) move the light, Enter opens the lit row,
-- Escape closes the list, a click anywhere else closes it, a click on a
-- row opens it. The page behind stays as it was - the results never take
-- the content pane over - and the sidebar still narrows to the pages
-- that have a hit, as it always did.
--
-- Opening a result: a page opens; a section or setting opens its page on
-- the right tab, scrolls it into view and flashes it (Sidebar_Search's
-- jump); a command runs, or is put in the chat box when it needs words
-- added. Ctrl+F while the window is open puts the cursor in the box;
-- /rc search <words> opens the window with the words typed.
--
-- The index is read the first time the box is focused (one page per
-- frame, see Sidebar_Search) and never at login; nothing here persists.
------------------------------------------------------------------------
local ipairs, type, tostring = ipairs, type, tostring
local math_max, math_min, math_ceil = math.max, math.min, math.ceil
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not (RC and RC.UI and RC.SidebarSearch) then return end

local S = RC.SidebarSearch
local Box = {}
RC.SidebarSearchBox = Box

local MAX_ROWS = 12
local DEBOUNCE = 0.12
local TITLE_SIZE, SUB_SIZE = 11, 10

local win, box, popup
local rows = {}
local shown = {}      -- the results on the rows now
local sel = 1
local serial = 0

-- ============================================================
-- STATE FOR THE WINDOW AND THE SIDEBAR
-- ============================================================
function Box.IsOpen() return popup ~= nil and popup:IsShown() end
function Box.Selected() return shown[sel] end
function Box.Results() return S.results end

-- Best result on one page, for a sidebar row clicked while searching
-- (Raids_Nav reads this off RC.SidebarSearch).
function S.BestFor(itemId)
    for _, r in ipairs(S.results) do
        if r.item == itemId then return r end
    end
end

-- ============================================================
-- THE DROPDOWN
-- ============================================================
-- (the lit row wears the dropdown's item hover; the rest are clear)
local CLEAR = { r = 0, g = 0, b = 0, a = 0 }
local function PaintRow(row)
    local on = row._rcSel or row._rcHot
    local c = on and RC:GetColor("dropdown", "itemHover") or CLEAR
    row.bg:SetVertexColor(c.r, c.g, c.b, c.a or 1)
    local tc = row._rcMuted and RC:GetColor("text", "gray") or RC:GetColor("text", "normal")
    row.title:SetTextColor(tc.r, tc.g, tc.b, 1)
    local gc = RC:GetColor("text", "gray")
    row.sub:SetTextColor(gc.r, gc.g, gc.b, 1)
end

local function Select(i, paintOnly)
    local n = #shown
    if n == 0 then sel = 1 return end
    if not paintOnly then
        if i < 1 then i = n elseif i > n then i = 1 end
        sel = i
    end
    for k, row in ipairs(rows) do
        row._rcSel = (k == sel) and row:IsShown()
        PaintRow(row)
    end
end

local Go

local function NewRow(i)
    local FLAT = RC.UI.FLAT or "Interface\\Buttons\\WHITE8X8"
    local row = CreateFrame("Button", nil, popup)
    row:SetPoint("LEFT", popup, "LEFT", 2, 0)
    row:SetPoint("RIGHT", popup, "RIGHT", -2, 0)
    -- (.bg: the fill RC.UI:AttachHover paints)
    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetTexture(FLAT)
    row.bg:SetVertexColor(0, 0, 0, 0)
    -- "Setting: Expiry glow" - the kind in the accent, the title plain
    row.title = RC:CreateFontString(row, "OVERLAY", nil, TITLE_SIZE)
    row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -5)
    row.title:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.title:SetJustifyH("LEFT")
    row.title:SetWordWrap(false)
    -- where it lives, in the muted text
    row.sub = RC:CreateFontString(row, "OVERLAY", nil, SUB_SIZE)
    row.sub:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
    row.sub:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    row.sub:SetJustifyH("LEFT")
    row.sub:SetWordWrap(false)
    -- hover lights the row (and makes it the one Enter opens); the light
    -- stays on the row last lit when the mouse leaves
    RC.UI:AttachHover(row, CLEAR, RC:GetColor("dropdown", "itemHover"), {
        onEnter = function(self)
            self._rcHot = true
            if shown[i] then Select(i) else PaintRow(self) end
        end,
        onLeave = function(self)
            self._rcHot = nil
            PaintRow(self)
        end,
    })
    -- a title or breadcrumb cut short shows whole on hover (after the
    -- hover above: TruncTip hooks the row's own OnEnter)
    RC.UI:TruncTip(row.title, row)
    RC.UI:TruncTip(row.sub, row)
    row:SetScript("OnClick", function()
        if shown[i] then Go(shown[i]) end
    end)
    rows[i] = row
    return row
end

local function Row(i) return rows[i] or NewRow(i) end

-- Two lines of this font size, plus air. Measured off a row, so a bigger
-- font makes taller rows rather than clipped ones.
local function RowHeight()
    local r = rows[1]
    local th = (r and r.title.GetStringHeight and r.title:GetStringHeight()) or 0
    local sh = (r and r.sub.GetStringHeight and r.sub:GetStringHeight()) or 0
    if type(th) ~= "number" or th < 6 then th = TITLE_SIZE + 2 end
    if type(sh) ~= "number" or sh < 6 then sh = SUB_SIZE + 2 end
    return math_ceil(th + sh) + 12
end

local function PopupWidth()
    local ww = (win and win:GetWidth()) or 1050
    return math_max(260, math_min(420, ww - 24))
end

local function Hide()
    if popup then popup:Hide() end
end
Box.Hide = Hide

local function Place()
    popup:ClearAllPoints()
    popup:SetPoint("TOPLEFT", win.sidebar.searchContainer, "BOTTOMLEFT", 0, -3)
    popup:SetWidth(PopupWidth())
end

-- Draw the results on the rows (the first lit) and show the list.
local function Draw()
    if not popup then return end
    local hex = S.AccentHex()
    local results = S.results
    local n = math_min(#results, MAX_ROWS)
    for k = 1, MAX_ROWS do
        local r = results[k]
        local row = Row(k)
        if r and k <= n then
            shown[k] = r
            row._rcMuted = nil
            row.title:SetText("|cff" .. hex .. S.Kind(r) .. ":|r " .. (r.label or ""))
            row.sub:SetText(S.Crumb(r))
            row:Show()
        else
            shown[k] = nil
            row:Hide()
        end
    end
    for k = n + 1, #shown do shown[k] = nil end
    -- nothing (yet): one quiet line says so, so the search is seen to run
    if n == 0 then
        local row = Row(1)
        row._rcMuted = true
        row.title:SetText(S.IsIndexing()
            and RCL["Still reading the pages - results appear as they come in."]
            or RCL["Nothing matches. Try fewer words, or the start of a word."])
        row.sub:SetText("")
        row:Show()
    end
    local rh = RowHeight()
    local count = math_max(n, 1)
    for k = 1, count do
        local row = rows[k]
        row:SetHeight(rh)
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", popup, "TOPLEFT", 2, -2 - (k - 1) * rh)
        row:SetPoint("RIGHT", popup, "RIGHT", -2, 0)
    end
    popup:SetHeight(count * rh + 4)
    Place()
    -- the list's own colours, fresh each time (the palette may have changed)
    local bg = RC:GetColor("dropdown", "background")
    popup.bg:SetVertexColor(bg.r, bg.g, bg.b, bg.a or 1)
    RC.UI:UpdateBorderColor(popup.border, RC:GetColor("ui", "borderNormal"), 1)
    if sel > n then sel = 1 end
    Select(sel, true)
    if not popup:IsShown() then
        if RC.UI.CloseAllDropdowns then RC.UI:CloseAllDropdowns() end
        popup:Show()
    end
end

-- ============================================================
-- RUNNING A SEARCH
-- ============================================================
local function Run(text)
    S.query = text or ""
    S.results, S.hits = S.Run(S.query)
end

local function Clear()
    S.query, S.results, S.hits = "", {}, {}
    for k in pairs(shown) do shown[k] = nil end
    sel = 1
    Hide()
end

local function EB() return win and win.sidebar and win.sidebar.searchBox end

-- The index fills in over a few frames; once it is complete, redraw
-- whatever is showing so partial results become whole.
local function OnIndexed()
    if not (win and win:IsShown()) then return end
    local eb = EB()
    local text = eb and eb:GetText() or ""
    if not text:find("%S") then return end
    Run(text)
    RC:BuildSidebar(win, false)
    if popup:IsShown() or eb:HasFocus() then Draw() end
end

-- Sidebar_Window calls this on every keystroke (after it has narrowed
-- the sidebar by name); the search waits a beat so a fast word is one
-- search, not six half-word redraws.
function S.OnTextChanged(outer, text)
    serial = serial + 1
    local mine = serial
    C_Timer.After(DEBOUNCE, function()
        if mine ~= serial or not (outer and outer:IsShown()) then return end
        local eb = EB()
        local now = eb and eb:GetText() or text or ""
        if not now:find("%S") then
            Clear()
            RC:BuildSidebar(outer, false)
            return
        end
        S.EnsureIndex(OnIndexed)
        Run(now)
        sel = 1
        -- (the sidebar again: the pages the settings search hit join it)
        RC:BuildSidebar(outer, false)
        Draw()
    end)
end

-- Open a result: the box empties and the list goes, then the page (and
-- its setting) shows, or the command runs.
Go = function(r)
    if not r then return end
    serial = serial + 1   -- a pending redraw would undo the jump
    local eb = EB()
    if eb then
        eb:SetText("")      -- (Sidebar_Window's OnTextChanged redraws the sidebar)
        eb:ClearFocus()
    end
    Clear()
    if r.kind == "command" then
        local how = S.RunCommand(r)
        if how == false then RC:Print(RCL["That command is not here on this client."]) end
        return
    end
    S.JumpTo(r)
end
Box.Go = Go

-- Enter in the box: the lit row opens (the first, when the list is not up).
function S.OnEnter(outer, text)
    text = text or (EB() and EB():GetText()) or ""
    if not text:find("%S") then return end
    if #shown == 0 or S.query ~= text then
        serial = serial + 1
        S.EnsureIndex(OnIndexed)
        Run(text)
        sel = 1
    end
    local r = (S.results[sel] and sel <= MAX_ROWS) and S.results[sel] or S.results[1]
    if r then Go(r) else Draw() end
end

-- Focusing the box starts reading the pages; a word already in the box
-- brings its list back.
function S.OnFocus()
    S.EnsureIndex(OnIndexed)
    local eb = EB()
    local text = eb and eb:GetText() or ""
    if text:find("%S") and popup and not popup:IsShown() then
        Run(text)
        Draw()
    end
end

local function Step(d)
    if not (popup and popup:IsShown()) or #shown == 0 then return end
    Select(sel + d)
end

-- ============================================================
-- PUBLIC
-- ============================================================
function Box.Focus()
    local eb = EB()
    if not eb then return end
    eb:SetFocus()
end

-- /rc search <words>: the window up (never toggled shut), the words in
-- the box, the list under it. Bare: just the cursor in the box.
function Box.Open(text)
    text = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not (win and win:IsShown()) then
        RC:CreateSidebarConfigWindow()
    end
    local eb = EB()
    if not eb then return end
    serial = serial + 1
    eb:SetText(text)   -- (Sidebar_Window's OnTextChanged narrows the sidebar)
    sel = 1
    if text == "" then
        Clear()
        eb:SetFocus()
        return
    end
    S.EnsureIndex(OnIndexed)
    Run(text)
    RC:BuildSidebar(win, false)
    eb:SetFocus()
    Draw()
end

-- Ctrl+F while the window is up puts the cursor in the box. The window
-- listens for keys but passes every one on (SetPropagateKeyboardInput,
-- which cannot be set in combat - so armed only out of it; a window
-- opened mid-fight gets the shortcut once the fight ends).
local function ArmKeys()
    if not win or win._rcSearchKeys then return end
    if InCombatLockdown() then
        if not win._rcSearchKeyWait then
            win._rcSearchKeyWait = CreateFrame("Frame")
            win._rcSearchKeyWait:RegisterEvent("PLAYER_REGEN_ENABLED")
            win._rcSearchKeyWait:SetScript("OnEvent", function(self)
                self:UnregisterAllEvents()
                win._rcSearchKeyWait = nil
                ArmKeys()
            end)
        end
        return
    end
    win._rcSearchKeys = true
    if win.SetPropagateKeyboardInput then win:SetPropagateKeyboardInput(true) end
    win:EnableKeyboard(true)
    win:SetScript("OnKeyDown", function(self, key)
        local ctrl = type(IsControlKeyDown) == "function" and IsControlKeyDown()
        local mine = (key == "F" and ctrl) and true or false
        if self.SetPropagateKeyboardInput and not InCombatLockdown() then
            self:SetPropagateKeyboardInput(not mine)
        end
        if mine then Box.Focus() end
    end)
end

-- ============================================================
-- HOOKING THE WINDOW
-- ============================================================
-- The first time the window is made (RC:CreateSidebarConfigWindow builds
-- it once and toggles it after), the list is hung under its search box
-- and the box's arrow keys are wired. Sidebar_Window's own scripts on
-- the box (typing narrows the sidebar, Escape empties it, Enter opens)
-- already call into RC.SidebarSearch, so nothing there changes.
local function Attach()
    local frame = RC.sidebarConfigFrame
    if not frame or frame._rcSearchBox then return end
    local sb = frame.sidebar
    local eb = sb and sb.searchBox
    if not (eb and sb.searchContainer) then return end
    frame._rcSearchBox = true
    win = frame
    box = eb

    -- the arrows (and Tab) walk the list; Enter is the box's own (above)
    eb:SetScript("OnArrowPressed", function(_, key)
        if key == "UP" then Step(-1) elseif key == "DOWN" then Step(1) end
    end)
    eb:SetScript("OnTabPressed", function()
        local shift = type(IsShiftKeyDown) == "function" and IsShiftKeyDown()
        Step(shift and -1 or 1)
    end)
    -- Escape (the box's own script empties it and drops the cursor): the
    -- list goes at once, not after the typing pause
    eb:HookScript("OnEscapePressed", function()
        serial = serial + 1
        Clear()
    end)

    -- THE LIST. A child of the window (it moves with it), above the
    -- content pane and the page's own dropdowns.
    local FLAT = RC.UI.FLAT or "Interface\\Buttons\\WHITE8X8"
    popup = CreateFrame("Frame", nil, frame)
    popup:SetFrameStrata("FULLSCREEN_DIALOG")
    popup:SetFrameLevel(200)
    popup:SetClampedToScreen(true)
    popup:SetSize(PopupWidth(), 40)
    popup.bg = popup:CreateTexture(nil, "BACKGROUND")
    popup.bg:SetAllPoints()
    popup.bg:SetTexture(FLAT)
    popup.border = RC.UI:CreateSimpleBorder(popup)
    popup:Hide()
    Place()
    Box.popup = popup
    sb.searchResults = popup

    -- A click anywhere else closes the list: a mouse-down listener that
    -- exists only while the list is up. Row clicks land on mouse-up, and
    -- the down lands over the list, so results stay clickable.
    local clickOff = CreateFrame("Frame")
    clickOff:SetScript("OnEvent", function()
        if not popup:IsMouseOver() and not sb.searchContainer:IsMouseOver() then Hide() end
    end)
    popup:SetScript("OnShow", function() clickOff:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
    popup:SetScript("OnHide", function()
        clickOff:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        for _, row in ipairs(rows) do row._rcHot = nil row._rcSel = nil end
    end)
    -- the window going (Escape, the X) takes the list and the search with it
    frame:HookScript("OnHide", function()
        serial = serial + 1
        Clear()
    end)
    frame:HookScript("OnShow", function()
        -- a fresh open starts unfiltered; a stale search from last time
        -- would hide most of the sidebar for no visible reason
        if eb:GetText() ~= "" then eb:SetText("") end
        Clear()
    end)

    ArmKeys()
    RC:DebugPrint("Settings search box attached", "config")
end
Box.Attach = Attach

if RC.CreateSidebarConfigWindow then
    hooksecurefunc(RC, "CreateSidebarConfigWindow", Attach)
end
-- (the window may already be up when this file loads late)
Attach()

RC:DebugPrint("Sidebar search box loaded", "system")
