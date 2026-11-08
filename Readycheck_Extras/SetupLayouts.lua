------------------------------------------------------------------------
-- Readycheck_Extras - Layout presets for the setup's Layout step
-- A few named arrangements of Readycheck's bars, reminders and trackers
-- for this screen, previewed as ghost boxes over the world before anything
-- moves, then applied through the UI Mover (the same save a drag makes).
--
-- TARGETS are the frames registered with the UI Mover (UM.frames): every
-- bar and reminder a player can see, by its mover key, with the mover's
-- own label. A PLACEMENT is resolution-aware: { fx, fy } are FRACTIONS of
-- the screen's width and height from its centre, so a layout lands the
-- same on every resolution. "Keep mine" is always offered and selected
-- first; "Default" puts every frame back to its own default. The step is
-- a row of tiles: the one picked is the choice, applied by the setup's
-- Finish. The on-screen preview only looks (it has no Apply of its own).
--
--   RC.SetupLayouts.Available()        the mover is up with frames
--   RC.SetupLayouts.Targets()          the targets, discovered now
--   RC.SetupLayouts.PRESETS            in order
--   RC.SetupLayouts.Preview(id)        the ghost overlay (false: nothing to show)
--   RC.SetupLayouts.EndPreview()
--   RC.SetupLayouts.Apply(id, opts)    moves everything; how many
--                                      (opts.quiet: no chat hint)
--   RC.SetupLayouts.BuildStep(host, y, ctx)   the setup's step
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local LP = {}
local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"

local function C(cat, key) return RC:GetColor(cat, key) end
local function InCombat() return (InCombatLockdown and InCombatLockdown()) or false end

local function Screen()
    local w = UIParent and UIParent.GetWidth and UIParent:GetWidth() or 0
    local h = UIParent and UIParent.GetHeight and UIParent:GetHeight() or 0
    if not (w and w > 0) then w = 1920 end
    if not (h and h > 0) then h = 1080 end
    return w, h
end

local function FrameSize(f)
    if not (f and f.GetWidth) then return 100, 30 end
    local w, h = f:GetWidth(), f:GetHeight()
    local s = (f.GetScale and f:GetScale()) or 1
    if type(w) ~= "number" or w < 2 then w = 100 end
    if type(h) ~= "number" or h < 2 then h = 30 end
    return w * s, h * s
end

------------------------------------------------------------------------
-- Targets
------------------------------------------------------------------------
function LP.Targets()
    local out = {}
    local UM = RC.UIMover
    if not (UM and type(UM.frames) == "table") then return out end
    -- the mover registers the frames a moment after login; asked before
    -- that (the setup's first open), it registers them now (idempotent)
    if next(UM.frames) == nil and UM.RegisterAddonFrames then pcall(UM.RegisterAddonFrames, UM) end
    local keys = {}
    for k, data in pairs(UM.frames) do if data and data.frame then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do
        local data = UM.frames[k]
        local f = data.frame
        out[#out + 1] = {
            key = k, label = data.displayName or (UM.LABELS and UM.LABELS[k]) or k,
            size = function() return FrameSize(f) end,
            current = function()
                local P = RC.Position
                if P and P.Capture then
                    local ok, x, y = pcall(P.Capture, f, "CENTER")
                    if ok and x then return x, y end
                end
                local cx, cy = f:GetCenter()
                local sw, sh = Screen()
                if cx then return cx - sw / 2, cy - sh / 2 end
                return 0, 0
            end,
            place = function(cx, cy) return UM:PlaceFrame(k, cx, cy) end,
            reset = function() UM:ResetFramePosition(k) end,
        }
    end
    return out
end

function LP.Available()
    local UM = RC.UIMover
    return UM ~= nil and type(UM.frames) == "table" and UM.PlaceFrame ~= nil
end

------------------------------------------------------------------------
-- Presets: places[moverKey] = { fx, fy } from the screen's centre
------------------------------------------------------------------------
local function P(fx, fy) return { fx = fx, fy = fy } end

LP.PRESETS = {
    { id = "keep", name = RCL["Keep mine"], short = RCL["Nothing moves"],
      desc = RCL["Nothing moves. Every bar and reminder stays exactly where it is."] },
    { id = "default", name = RCL["Default"], reset = true, short = RCL["Every frame at its own default"],
      desc = RCL["Every bar and reminder back at its own default spot."] },
    { id = "compact", name = RCL["Compact"], short = RCL["Gathered low in the middle"],
      desc = RCL["Everything gathered low in the middle: the consumables, potions and weapon bars stacked just above the action bars, the reminder popup and the time-to-kill display above them, the two trackers to the right, the stats bar along the bottom."],
      places = {
          consumablesHelper = P(0, -0.30), potionsBar = P(0, -0.345), weaponsBar = P(0, -0.39), trinketBar = P(0, -0.435),
          reminderFrame = P(0, 0.10), ttkDisplay = P(0, 0.19), buffPushoffAlert = P(0, 0.27),
          raidBuffTracker = P(0.30, 0.05), bossDebuffTracker = P(0.30, -0.12), battleShoutPartyTracker = P(0.30, -0.26),
          battleShoutReminder = P(-0.18, -0.30), fastWeaponReminder = P(0.18, -0.30),
          statsBar = P(0, -0.47), trinketToggle = P(0.12, -0.47), bossNotes = P(0, 0.33),
          polarityBar = P(0, 0.05), mustHaveAlert = P(0, 0.22), routeTracker = P(-0.36, 0.0),
          swapToast = P(0, 0.30), gearSetPrompt = P(0, 0.0), specPopup = P(0, 0.15),
      } },
}

function LP.Preset(id)
    for _, p in ipairs(LP.PRESETS) do if p.id == id then return p end end
    return nil
end

function LP.Resolve(place)
    local w, h = Screen()
    return math.floor((place.fx or 0) * w + 0.5), math.floor((place.fy or 0) * h + 0.5)
end

-- { target, cx, cy, w, h, moves } per target the preset touches (the
-- default shows the frame's default spot where the mover knows it)
function LP.Ghosts(id, targets)
    local preset = LP.Preset(id)
    if not preset then return {} end
    targets = targets or LP.Targets()
    local UM = RC.UIMover
    local out = {}
    for _, t in ipairs(targets) do
        local pl = preset.places and preset.places[t.key]
        local cx, cy, moves
        if pl then
            cx, cy = LP.Resolve(pl)
            moves = true
        elseif preset.reset then
            local data = UM and UM.frames[t.key]
            local def = data and data.defaultPos
            if def and (def.point == "CENTER" or def.point == nil) and (def.relPoint == "CENTER" or def.relPoint == nil) then
                cx, cy = def.x or 0, def.y or 0
                moves = true
            end
        end
        if not cx then cx, cy = t.current() moves = moves or false end
        local w, h = t.size()
        out[#out + 1] = { target = t, cx = cx or 0, cy = cy or 0, w = w, h = h, moves = moves and true or false }
    end
    return out
end

------------------------------------------------------------------------
-- Ghost overlay
------------------------------------------------------------------------
local overlay, control
-- the preview never outlives a fight: watched only while it shows (made on
-- the first preview, so nothing exists until the step is used)
local watch
local function Watch(on)
    if on and not watch then
        watch = CreateFrame("Frame")
        watch:SetScript("OnEvent", function() LP.EndPreview() end)
    end
    if not watch then return end
    if on then watch:RegisterEvent("PLAYER_REGEN_DISABLED") else watch:UnregisterEvent("PLAYER_REGEN_DISABLED") end
end
local function BuildOverlay()
    overlay = CreateFrame("Frame", "ReadycheckLayoutGhosts", UIParent)
    overlay:SetAllPoints(UIParent)
    overlay:SetFrameStrata("FULLSCREEN")
    overlay:EnableMouse(false)
    local dim = overlay:CreateTexture(nil, "BACKGROUND")
    dim:SetAllPoints()
    dim:SetTexture(FLAT)
    dim:SetVertexColor(0, 0, 0, 0.45)
    overlay.ghosts = {}
    overlay:Hide()

    control = CreateFrame("Frame", "ReadycheckLayoutPreview", UIParent)
    control:SetSize(340, 104)
    control:SetPoint("TOP", UIParent, "TOP", 0, -80)
    control:SetFrameStrata("FULLSCREEN_DIALOG")
    control:EnableMouse(true)
    control:SetMovable(true)
    control:RegisterForDrag("LeftButton")
    control:SetScript("OnDragStart", control.StartMoving)
    control:SetScript("OnDragStop", control.StopMovingOrSizing)
    control.bg = control:CreateTexture(nil, "BACKGROUND")
    control.bg:SetAllPoints()
    control.bg:SetTexture(FLAT)
    local wb = C("ui", "windowBackground")
    control.bg:SetVertexColor(wb.r, wb.g, wb.b, wb.a or 0.95)
    RC.UI:CreateSimpleBorder(control)
    RC.UI:RegisterEscapeClose("ReadycheckLayoutPreview")
    local header = CreateFrame("Frame", nil, control)
    header:SetPoint("TOPLEFT", control, "TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", control, "TOPRIGHT", -1, -1)
    header:SetHeight(30)
    header.bg = header:CreateTexture(nil, "BACKGROUND")
    header.bg:SetAllPoints()
    header.bg:SetTexture(FLAT)
    local hb = C("ui", "headerBackground")
    header.bg:SetVertexColor(hb.r, hb.g, hb.b, hb.a or 1)
    if RC.UI.ApplyHeaderArt then RC.UI:ApplyHeaderArt(header, { stepX = 120 }) end
    local icon = RC.UI:AddTitleIcon(header, 16, 8)
    local title = RC:CreateFontString(header, "OVERLAY", nil, 13)
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    title:SetText(RCL["Layout preview"])
    local hc = C("ui", "headerText")
    title:SetTextColor(hc.r, hc.g, hc.b, 1)
    local closeBtn = RC.UI:CreateXCloseButton(header, 22, function() LP.EndPreview() end)
    closeBtn:SetPoint("RIGHT", header, "RIGHT", -5, 0)
    control.text = RC:CreateFontString(control, "OVERLAY", nil, 10)
    control.text:SetPoint("TOPLEFT", control, "TOPLEFT", 14, -40)
    control.text:SetPoint("RIGHT", control, "RIGHT", -14, 0)
    control.text:SetJustifyH("LEFT")
    control.text:SetWordWrap(true)
    local g = C("text", "normal")
    control.text:SetTextColor(g.r, g.g, g.b, 1)
    -- look only: the choice is the tile, applied by the setup's Finish
    control.back = RC.UI:CreateStyledButton(control, RCL["Back to setup"], 130, 26)
    control.back:SetPoint("BOTTOMRIGHT", control, "BOTTOMRIGHT", -14, 12)
    control.back:SetScript("OnClick", function() LP.EndPreview() end)
    control:HookScript("OnHide", function() if overlay then overlay:Hide() end end)
    RC.UI:SkinPopup(control, { header = header, title = title, close = closeBtn, texts = { control.text }, primary = control.back })
    control:Hide()
end

local function Ghost(i)
    local g = overlay.ghosts[i]
    if not g then
        g = CreateFrame("Frame", nil, overlay)
        g.bg = g:CreateTexture(nil, "BACKGROUND")
        g.bg:SetAllPoints()
        g.bg:SetTexture(FLAT)
        local a = C("ui", "accentGold")
        g.bg:SetVertexColor(a.r, a.g, a.b, 0.2)
        g.border = RC.UI:CreateSimpleBorder(g)
        RC.UI:UpdateBorderColor(g.border, a, 1)
        g.label = RC:CreateFontString(g, "OVERLAY", nil, 10)
        g.label:SetPoint("CENTER")
        g.label:SetWordWrap(false)
        local n = C("text", "normal")
        g.label:SetTextColor(n.r, n.g, n.b, 1)
        overlay.ghosts[i] = g
    end
    return g
end

function LP.Preview(id)
    local ghosts = LP.Ghosts(id)
    if #ghosts == 0 then return false end
    if not overlay then BuildOverlay() end
    for i, gh in ipairs(ghosts) do
        local g = Ghost(i)
        g:ClearAllPoints()
        g:SetSize(math.max(12, gh.w), math.max(8, gh.h))
        g:SetPoint("CENTER", UIParent, "CENTER", gh.cx, gh.cy)
        g.label:SetText(gh.target.label)
        g.label:SetWidth(math.max(40, gh.w - 4))
        g:SetAlpha(gh.moves and 1 or 0.45)
        g:Show()
    end
    for i = #ghosts + 1, #overlay.ghosts do overlay.ghosts[i]:Hide() end
    local preset = LP.Preset(id)
    control.presetId = id
    control.text:SetText((preset and preset.name or id) .. RCL[": the lit boxes are where things land. Nothing moves until you press Finish in the setup."])
    overlay:Show()
    control:Show()
    control:Raise()
    Watch(true)
    return true
end

function LP.EndPreview()
    Watch(false)
    if overlay then overlay:Hide() end
    if control then control:Hide() end
end

function LP.PreviewShown() return overlay ~= nil and overlay:IsShown() end

------------------------------------------------------------------------
-- Apply
------------------------------------------------------------------------
function LP.Apply(id, opts)
    local preset = LP.Preset(id)
    if not preset or id == "keep" then return 0 end
    local n = 0
    for _, t in ipairs(LP.Targets()) do
        local pl = preset.places and preset.places[t.key]
        if preset.reset then
            if pcall(t.reset) then n = n + 1 end
        end
        if pl then
            local cx, cy = LP.Resolve(pl)
            local ok, placed = pcall(t.place, cx, cy)
            if ok and placed then n = n + 1 end
        end
    end
    RC:SaveConfigurationToProfile()
    if RC.Hints and not (opts and opts.quiet) then
        RC.Hints.Say("layout_applied", RCL["A layout was applied. Every frame can still be dragged: the UI Mover (Settings > Interface) shows them all."])
    end
    return n
end

------------------------------------------------------------------------
-- The step: a tile per preset (a thumbnail of the screen with a box
-- where each frame lands, the name and one line), the picked one in the
-- accent. ctx: pageW, pad, canvas (the setup's), chosen (the id picked
-- so far), choose(id) (the setup records it; nothing moves here).
------------------------------------------------------------------------
function LP.BuildStep(host, y, ctx)
    local S = RC.UI.S
    local x = ctx.pad or 24
    local pageW = ctx.pageW or 718
    local chosen = ctx.chosen or "keep"
    local targets = LP.Targets()
    local n = #LP.PRESETS
    local gap = 12
    local tileW = math.floor((pageW - 2 * x - (n - 1) * gap) / n)
    local sw, sh = Screen()
    local TW = tileW - 24
    local TH = math.floor(TW * sh / sw + 0.5)
    local tileH = 12 + TH + 12 + 18 + 4 + 16 + 12
    host.layoutTiles = {}

    local function Paint()
        local A = RC.UI:SAccent()
        local edge = RC:GetColor("settings", "text")
        for id, t in pairs(host.layoutTiles) do
            local on = id == chosen
            if on then RC.UI:UpdateBorderColor(t.border, A, 1) else RC.UI:UpdateBorderColor(t.border, edge, S.BORDER_A * 2) end
            t.tick:SetShown(on)
            t.name:SetTextColor(RC.UI:SCol("text", on and 1 or 0.86))
        end
    end

    local function Thumb(tile, id)
        local thumb = ctx.canvas(tile, TW, TH)
        thumb:SetPoint("TOPLEFT", tile, "TOPLEFT", 12, -12)
        local k = TW / sw
        for _, gh in ipairs(LP.Ghosts(id, targets)) do
            local w, h = math.max(2, gh.w * k), math.max(2, gh.h * k)
            local l = TW / 2 + gh.cx * k - w / 2
            local b = TH / 2 + gh.cy * k - h / 2
            l = math.max(0, math.min(TW - w, l))
            b = math.max(0, math.min(TH - h, b))
            thumb:Rect(l, TH - b - h, w, h, "settings", "accent", gh.moves and 0.8 or 0.3)
        end
        return thumb
    end

    local desc
    local function Describe()
        local p = LP.Preset(chosen)
        local moved = 0
        for _, gh in ipairs(LP.Ghosts(chosen, targets)) do if gh.moves then moved = moved + 1 end end
        desc:SetText((p and p.desc or "") .. (chosen ~= "keep" and (RCL[" Moves "] .. moved .. RCL[" of "] .. #targets .. RCL[" frames."]) or ""))
    end

    for i, p in ipairs(LP.PRESETS) do
        local tile = CreateFrame("Button", nil, host)
        tile:SetSize(tileW, tileH)
        tile:SetPoint("TOPLEFT", host, "TOPLEFT", x + (i - 1) * (tileW + gap), y)
        tile.bg = tile:CreateTexture(nil, "BACKGROUND")
        tile.bg:SetAllPoints()
        tile.bg:SetTexture(FLAT)
        tile.bg:SetVertexColor(RC.UI:SCol("shade", S.ROW_EVEN))
        tile.border = RC.UI:CreateSimpleBorder(tile)
        tile.thumb = Thumb(tile, p.id)
        tile.name = RC:CreateFontString(tile, "OVERLAY", nil, 14, "OUTLINE")
        tile.name:SetPoint("TOPLEFT", tile.thumb, "BOTTOMLEFT", 0, -12)
        tile.name:SetText(p.name)
        tile.line = RC:CreateFontString(tile, "OVERLAY", nil, 11, "")
        tile.line:SetPoint("TOPLEFT", tile.name, "BOTTOMLEFT", 0, -4)
        tile.line:SetWidth(TW)
        tile.line:SetJustifyH("LEFT")
        tile.line:SetWordWrap(false)
        tile.line:SetText(p.short or "")
        tile.line:SetTextColor(RC.UI:SCol("text", S.DIM_A))
        tile.tick = tile:CreateTexture(nil, "OVERLAY")
        tile.tick:SetSize(18, 18)
        tile.tick:SetPoint("TOPRIGHT", tile, "TOPRIGHT", -6, -6)
        tile.tick:SetTexture("Interface\\AddOns\\Readycheck\\Media\\Checkmark")
        tile.tick:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        if RC.UI.PaintMark then RC.UI:PaintMark(tile.tick) end
        local id = p.id
        tile:SetScript("OnClick", function()
            chosen = id
            if ctx.choose then ctx.choose(id) end
            Describe()
            Paint()
        end)
        tile:SetScript("OnEnter", function(self)
            if id ~= chosen then RC.UI:UpdateBorderColor(self.border, RC.UI:SAccent(), 0.5) end
        end)
        tile:SetScript("OnLeave", function() Paint() end)
        host.layoutTiles[id] = tile
    end
    y = y - tileH - 16

    desc = RC:CreateFontString(host, "OVERLAY", nil, S.F_HINT, "")
    desc:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
    desc:SetWidth(pageW - 2 * x)
    desc:SetJustifyH("LEFT")
    desc:SetWordWrap(true)
    desc:SetTextColor(RC.UI:SCol("text", 0.86))
    host.layoutDesc = desc
    Describe()
    y = y - math.max(28, (desc:GetStringHeight() or 12) + 4) - 10

    local preview = RC.UI:CreateStyledButton(host, RCL["Preview on screen"], 160, 28)
    preview:SetPoint("TOPLEFT", host, "TOPLEFT", x, y)
    preview:SetScript("OnClick", function()
        if chosen == "keep" then RC:Print(RCL["Keep mine moves nothing - there is nothing to preview."]) return end
        if InCombat() then return end
        if not LP.Preview(chosen) then RC:Print(RCL["Nothing to preview on this install."]) end
    end)
    if RC.SetupTip then RC.SetupTip(preview, RCL["Preview on screen"], RCL["Dims the world and shows a box where every frame would land. Look only: it closes back to this step."]) end
    host.layoutPreview = preview
    local note = RC:CreateFontString(host, "OVERLAY", nil, 11, "")
    note:SetPoint("LEFT", preview, "RIGHT", 12, 0)
    note:SetText(RCL["Every frame can still be dragged later (Edit Mode)."])
    note:SetTextColor(RC.UI:SCol("text", S.DIM_A))
    host.layoutTargets = targets
    Paint()
end


RC.SetupLayouts = LP
