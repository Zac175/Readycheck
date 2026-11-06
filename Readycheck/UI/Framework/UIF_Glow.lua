local math_floor, math_max, math_min, math_abs = math.floor, math.max, math.min, math.abs
local type, tonumber, pairs, ipairs = type, tonumber, pairs, ipairs

------------------------------------------------------------------------
-- Readycheck - UI Framework: the edge glow
-- A soft light just outside an icon's edge, in the glow's own colour, the
-- way the warrior HUD's buffs glow: two layers of Readycheck's own art
-- (Media\EdgeGlow, the tight light on the edge, and Media\EdgeGlowWide,
-- a soft halo further out), pure white so a colour really is that colour,
-- ADD-blended, breathing in and out.
--
--   RC.UI:CreateEdgeGlow(parent, opts) -> glow   (a frame over parent,
--                                                hidden until :Show())
--   glow:Configure(opts)       restyle in place (unchanged opts: no work)
--   glow:SetColor(r, g, b, a)  a new colour, nothing else touched
--   glow:Refit()               follow the parent's size (OnSizeChanged
--                              does it; a caller may after a resize)
--   glow:Show() / glow:Hide()  the frame's own; the pulse and the moving
--                              styles run only while it is shown
--   glow:IsGlowing()           shown and drawing something
--
-- opts (every field optional; RC.UI.EDGE_GLOW_DEFAULTS fills the gaps):
--   style      "edge" (default) | "pixel" (lines running round the edge)
--              | "autocast" (sparkles running round it) | "border" (a
--              solid ring just outside) | "none"
--   color      {r=,g=,b=,a=} or {r, g, b, a}; nil = the accent colour
--   alpha      strength, 0.05..1
--   size       how far it reaches, 0.5..2 (1 = the HUD's reach)
--   halo       the soft wide layer on (edge style)
--   pulse      breathes in and out; speed = seconds per breath (half a
--              cycle), depth = how far it fades (0..0.95)
--   lines      lines / sparkles going round (1..16)
--   length     a line's length in px (2..60)
--   lineSpeed  laps per second (0.02..2)
--   level      frame levels above the parent (default 8)
-- Art: the texture is twice the hole it leaves for the icon (256 px with
-- a 128 px hole, the light peaking on the hole's edge). It is laid as nine
-- pieces - the middle one exactly over the icon, the edges and corners
-- outside it - so a bigger or smaller reach stretches only the outside
-- falloff and the brightest line stays on the icon's edge at any size.
-- The pulse is an AnimationGroup on the glow frame (no Lua per frame);
-- lines and sparkles move by an OnUpdate set only while they are shown.
-- Both follow the global Motion switches (off: steady, still; the speed
-- divides the breath and multiplies the laps).
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
RC._uif = RC._uif or {}
local _uif = RC._uif
local FLAT = _uif.FLAT or "Interface\\Buttons\\WHITE8X8"

    local MEDIA = "Interface\\AddOns\\Readycheck\\Media\\"
    local EDGE_TEX = MEDIA .. "EdgeGlow"
    local WIDE_TEX = MEDIA .. "EdgeGlowWide"
    local SPARK_TEX = "Interface\\Cooldown\\star4"
    local EDGE_ALPHA = 0.65   -- the tight layer at full strength
    local WIDE_ALPHA = 0.6    -- the soft halo at full strength

    local DEFAULTS = {
        style = "edge", alpha = 1, size = 1, halo = false,
        pulse = true, speed = 0.6, depth = 0.55,
        lines = 8, length = 12, lineSpeed = 0.25,
    }
    RC.UI.EDGE_GLOW_DEFAULTS = DEFAULTS
    RC.UI.EDGE_GLOW_STYLES = {
        { key = "edge",     label = RCL["Edge glow"],         tooltip = RCL["A soft light just outside the icon's edge."] },
        { key = "pixel",    label = RCL["Pixel lines"],       tooltip = RCL["Thin lines running round the icon."] },
        { key = "autocast", label = RCL["Autocast sparkles"], tooltip = RCL["Sparkles running round the icon."] },
        { key = "border",   label = RCL["Solid border"],      tooltip = RCL["A plain ring just outside the icon."] },
        { key = "none",     label = RCL["None"],              tooltip = RCL["No glow."] },
    }
    local STYLE_OK = { edge = true, pixel = true, autocast = true, border = true, none = true }

    local function Num(v, d, lo, hi)
        v = tonumber(v) or d
        if v < lo then v = lo elseif v > hi then v = hi end
        return v
    end
    local function Flag(v, d)
        if v == nil then return d end
        return v and true or false
    end

    -- opts -> a full spec in out (colour resolved to r, g, b, a)
    local function Normalize(o, out)
        o = type(o) == "table" and o or {}
        out.style = STYLE_OK[o.style] and o.style or DEFAULTS.style
        out.alpha = Num(o.alpha, DEFAULTS.alpha, 0.05, 1)
        out.size = Num(o.size, DEFAULTS.size, 0.5, 2)
        out.halo = Flag(o.halo, DEFAULTS.halo)
        out.pulse = Flag(o.pulse, DEFAULTS.pulse)
        out.speed = Num(o.speed, DEFAULTS.speed, 0.15, 3)
        out.depth = Num(o.depth, DEFAULTS.depth, 0, 0.95)
        out.lines = math_floor(Num(o.lines, DEFAULTS.lines, 1, 16) + 0.5)
        out.length = Num(o.length, DEFAULTS.length, 2, 60)
        out.lineSpeed = Num(o.lineSpeed, DEFAULTS.lineSpeed, 0.02, 2)
        out.level = math_floor(Num(o.level, 8, 0, 50))
        local c = o.color
        if type(c) == "table" then
            out.r, out.g, out.b, out.a = RC.UI:ColorOf(c)
        else
            -- the accent, at full alpha (its own alpha is for thin lines)
            local ac = RC.GetColor and RC:GetColor("ui", "accentGold")
            out.r, out.g, out.b, out.a = (ac and ac.r) or 1, (ac and ac.g) or 0.8, (ac and ac.b) or 0.3, 1
        end
        return out
    end
    RC.UI.NormalizeEdgeGlow = function(_, o) return Normalize(o, {}) end

    local function Motion()
        local M = RC.Motion
        local on = not (M and M.Enabled and not M.Enabled())
        local speed = (M and M.Speed and M.Speed()) or 1
        return on, speed
    end

    -- How far past the icon's edge a glow of this spec draws (px), for
    -- callers that leave room for it.
    function RC.UI:EdgeGlowReach(iconSize, opts)
        local s = Normalize(opts, {})
        iconSize = tonumber(iconSize) or 30
        if s.style == "none" then return 0 end
        if s.style == "edge" then
            -- the tight light fades out about a fifth of the way out
            local k = s.halo and 0.45 or 0.2
            return math.ceil(iconSize * 0.5 * s.size * k)
        end
        local th = math_max(1, math_floor(2 * s.size + 0.5))
        if s.style == "border" then return 1 + th end
        local off = math_floor(1 + 2 * s.size + 0.5)
        if s.style == "autocast" then return off + math.ceil(math_max(4, iconSize * 0.14 * s.size) / 2) end
        return off
    end

    ------------------------------------------------------------------
    -- the nine-piece layer (edge style)
    ------------------------------------------------------------------
    local CUT = { { 0, 0.25 }, { 0.25, 0.75 }, { 0.75, 1 } }
    local function NineLayer(g, tex, sub)
        local t = {}
        for row = 1, 3 do
            for col = 1, 3 do
                local x = g:CreateTexture(nil, "OVERLAY", nil, sub)
                x:SetTexture(tex)
                x:SetBlendMode("ADD")
                x:SetTexCoord(CUT[col][1], CUT[col][2], CUT[row][1], CUT[row][2])
                x.col, x.row = col, row
                t[#t + 1] = x
            end
        end
        -- anchored once: the middle on the icon, the rest round it
        for _, x in ipairs(t) do
            local c, r = x.col, x.row
            if c == 2 and r == 2 then
                x:SetAllPoints(g)
            elseif c == 2 then
                local edge = (r == 1) and "TOP" or "BOTTOM"
                local far = (r == 1) and "BOTTOM" or "TOP"
                x:SetPoint(far .. "LEFT", g, edge .. "LEFT", 0, 0)
                x:SetPoint(far .. "RIGHT", g, edge .. "RIGHT", 0, 0)
            elseif r == 2 then
                local edge = (c == 1) and "LEFT" or "RIGHT"
                local far = (c == 1) and "RIGHT" or "LEFT"
                x:SetPoint("TOP" .. far, g, "TOP" .. edge, 0, 0)
                x:SetPoint("BOTTOM" .. far, g, "BOTTOM" .. edge, 0, 0)
            else
                local v = (r == 1) and "TOP" or "BOTTOM"
                local h = (c == 1) and "LEFT" or "RIGHT"
                local fv = (r == 1) and "BOTTOM" or "TOP"
                local fh = (c == 1) and "RIGHT" or "LEFT"
                x:SetPoint(fv .. fh, g, v .. h, 0, 0)
            end
        end
        return t
    end
    local function NineSize(t, rx, ry)
        for _, x in ipairs(t) do
            local c, r = x.col, x.row
            if c ~= 2 and r ~= 2 then x:SetSize(rx, ry)
            elseif c == 2 and r ~= 2 then x:SetHeight(ry)
            elseif r == 2 and c ~= 2 then x:SetWidth(rx) end
        end
    end
    local function ShowList(t, on)
        for _, x in pairs(t or {}) do if on then x:Show() else x:Hide() end end
    end

    ------------------------------------------------------------------
    -- lines and sparkles: positions round a rectangle `off` px outside
    ------------------------------------------------------------------
    -- a distance d round the outer rect (clockwise from its top-left) ->
    -- side (1 top, 2 right, 3 bottom, 4 left) and the distance along it
    local function SideAt(g, d)
        local W, H = g._W, g._H
        if d < W then return 1, d end
        d = d - W
        if d < H then return 2, d end
        d = d - H
        if d < W then return 3, d end
        return 4, math_min(H, d - W)
    end
    -- a piece of side `side` from a to b (along it), th thick, inside the
    -- outer rect; offsets from the glow's top-left
    local function PlaceLine(g, t, side, a, b)
        local W, H, th, off = g._W, g._H, g._th, g._off
        local len = b - a
        -- a sliver this side of a corner is not worth a piece
        if len < 0.5 then t:Hide() return end
        t:ClearAllPoints()
        if side == 1 then
            t:SetPoint("TOPLEFT", g, "TOPLEFT", a - off, off)
            t:SetSize(len, th)
        elseif side == 2 then
            t:SetPoint("TOPLEFT", g, "TOPLEFT", W - th - off, -(a - off))
            t:SetSize(th, len)
        elseif side == 3 then
            t:SetPoint("TOPLEFT", g, "TOPLEFT", W - b - off, -(H - th - off))
            t:SetSize(len, th)
        else
            t:SetPoint("TOPLEFT", g, "TOPLEFT", -off, -(H - b - off))
            t:SetSize(th, len)
        end
        t:Show()
    end
    local function PointAt(g, d)
        local W, H = g._W, g._H
        local side, a = SideAt(g, d)
        if side == 1 then return a, 0
        elseif side == 2 then return W, a
        elseif side == 3 then return W - a, H end
        return 0, H - a
    end

    local function Moving(g)
        local s = g.spec
        return s.style == "pixel" or s.style == "autocast"
    end

    -- one step of the lines / sparkles at phase g._t (0..1 of a lap)
    local function DrawMoving(g)
        local s = g.spec
        local P = g._P or 0
        if P <= 0 then return end
        local n = s.lines
        if s.style == "pixel" then
            local L = math_min(s.length, g._W, g._H)
            for i = 1, n do
                local ln = g.lineTex[i]
                local d0 = ((g._t + (i - 1) / n) % 1) * P
                local side, a = SideAt(g, d0)
                local sideLen = (side == 1 or side == 3) and g._W or g._H
                local first = math_min(L, sideLen - a)
                PlaceLine(g, ln[1], side, a, a + first)
                PlaceLine(g, ln[2], side % 4 + 1, 0, L - first)
            end
        else
            local off = g._off
            for i = 1, n do
                local sp = g.sparkTex[i]
                local x, y = PointAt(g, ((g._t + (i - 1) / n) % 1) * P)
                sp:ClearAllPoints()
                sp:SetPoint("CENTER", g, "TOPLEFT", x - off, -(y - off))
            end
        end
    end

    local function Step(g, elapsed)
        local s = g.spec
        g._t = (g._t + (elapsed or 0) * s.lineSpeed * (g._mSpeed or 1)) % 1
        DrawMoving(g)
    end

    ------------------------------------------------------------------
    -- painting
    ------------------------------------------------------------------
    local function Paint(g)
        local s = g.spec
        local r, gg, b, A = s.r, s.g, s.b, (s.a or 1) * s.alpha
        if g.edge9 then for _, x in ipairs(g.edge9) do x:SetVertexColor(r, gg, b, A * EDGE_ALPHA) end end
        if g.wide9 then for _, x in ipairs(g.wide9) do x:SetVertexColor(r, gg, b, A * WIDE_ALPHA) end end
        for _, ln in ipairs(g.lineTex or {}) do
            ln[1]:SetVertexColor(r, gg, b, A)
            ln[2]:SetVertexColor(r, gg, b, A)
        end
        for _, sp in ipairs(g.sparkTex or {}) do sp:SetVertexColor(r, gg, b, A) end
        if g.ring then RC.UI:UpdateBorderColor(g.ring, { r = r, g = gg, b = b }, A) end
    end

    -- sizes and which pieces show, for the current spec and frame size
    local function Layout(g)
        local s = g.spec
        local w, h = g._w, g._h
        local st = s.style
        -- edge
        if st == "edge" then
            if not g.edge9 then g.edge9 = NineLayer(g, EDGE_TEX, 2) end
            NineSize(g.edge9, w * 0.5 * s.size, h * 0.5 * s.size)
            ShowList(g.edge9, true)
            if s.halo then
                if not g.wide9 then g.wide9 = NineLayer(g, WIDE_TEX, 1) end
                NineSize(g.wide9, w * 0.5 * s.size, h * 0.5 * s.size)
            end
            ShowList(g.wide9, s.halo)
        else
            ShowList(g.edge9, false)
            ShowList(g.wide9, false)
        end
        -- lines and sparkles share the outer rect
        local th = math_max(1, math_floor(2 * s.size + 0.5))
        local off = math_floor(1 + 2 * s.size + 0.5)
        g._th, g._off = th, off
        g._W, g._H = w + 2 * off, h + 2 * off
        g._P = 2 * (g._W + g._H)
        g.lineTex = g.lineTex or {}
        g.sparkTex = g.sparkTex or {}
        local nLines = (st == "pixel") and s.lines or 0
        for i = 1, math_max(nLines, #g.lineTex) do
            local ln = g.lineTex[i]
            if i <= nLines and not ln then
                ln = {}
                for k = 1, 2 do
                    local t = g:CreateTexture(nil, "OVERLAY", nil, 3)
                    t:SetTexture(FLAT)
                    ln[k] = t
                end
                g.lineTex[i] = ln
            end
            if ln and i > nLines then ln[1]:Hide() ln[2]:Hide() end
        end
        local nSparks = (st == "autocast") and s.lines or 0
        local base = math_max(4, math_min(w, h) * 0.14 * s.size)
        for i = 1, math_max(nSparks, #g.sparkTex) do
            local sp = g.sparkTex[i]
            if i <= nSparks and not sp then
                sp = g:CreateTexture(nil, "OVERLAY", nil, 3)
                sp:SetTexture(SPARK_TEX)
                sp:SetBlendMode("ADD")
                g.sparkTex[i] = sp
            end
            if sp then
                if i <= nSparks then
                    -- three sizes, big to small, round the ring
                    local k = ({ 1, 0.75, 0.55 })[(i - 1) % 3 + 1]
                    sp:SetSize(base * k, base * k)
                    sp:Show()
                else
                    sp:Hide()
                end
            end
        end
        -- solid border: a ring just outside the icon's own 1px edge
        if st == "border" then
            if not g.ringFrame then
                g.ringFrame = CreateFrame("Frame", nil, g)
                g.ring = RC.UI:CreateSimpleBorder(g.ringFrame, th)
                g.ringTh = th
            end
            local rf = g.ringFrame
            rf:ClearAllPoints()
            rf:SetPoint("TOPLEFT", g, "TOPLEFT", -(1 + th), 1 + th)
            rf:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", 1 + th, -(1 + th))
            if g.ringTh ~= th then
                g.ring.top:SetHeight(th) g.ring.bottom:SetHeight(th)
                g.ring.left:SetWidth(th) g.ring.right:SetWidth(th)
                g.ringTh = th
            end
            rf:Show()
        elseif g.ringFrame then
            g.ringFrame:Hide()
        end
        if Moving(g) then DrawMoving(g) end
    end

    -- the pulse and the OnUpdate, from the spec and the Motion switches
    local function Run(g)
        local s = g.spec
        local ag, a = g.anim, g.animAlpha
        local wantPulse = s.pulse and s.depth > 0 and s.style ~= "none" and g._mOn
        if wantPulse then
            local d = s.speed / (g._mSpeed or 1)
            if g._pulseDur ~= d or g._pulseTo ~= 1 - s.depth then
                ag:Stop()
                a:SetDuration(d)
                a:SetToAlpha(1 - s.depth)
                g._pulseDur, g._pulseTo = d, 1 - s.depth
            end
            g.pulsing = true
            if g:IsShown() and not ag:IsPlaying() then ag:Play() end
        else
            g.pulsing = false
            ag:Stop()
            g:SetAlpha(1)
        end
        local move = Moving(g) and g._mOn and g:IsShown()
        if move then
            if not g.moving then g:SetScript("OnUpdate", Step) end
        elseif g.moving then
            g:SetScript("OnUpdate", nil)
        end
        g.moving = move and true or false
    end

    local Methods = {}

    -- the frame's size now (30 until it has one)
    local function FrameSize(g)
        local w = g:GetWidth() or 0
        local h = g:GetHeight() or 0
        if w <= 0 then w = 30 end
        if h <= 0 then h = 30 end
        return w, h
    end

    function Methods:Configure(opts)
        local new = Normalize(opts, self._next or {})
        local mOn, mSpeed = Motion()
        local w, h = FrameSize(self)
        local old = self.spec
        local same = old and mOn == self._mOn and mSpeed == self._mSpeed
            and math_abs(w - (self._w or 0)) < 0.01 and math_abs(h - (self._h or 0)) < 0.01
        if same then
            for k, v in pairs(new) do
                if old[k] ~= v then same = false break end
            end
        end
        if same then return false end
        self._next = old
        self.spec = new
        self._mOn, self._mSpeed = mOn, mSpeed
        self._w, self._h = w, h
        self:SetFrameLevel((self:GetParent():GetFrameLevel() or 1) + new.level)
        Layout(self)
        Paint(self)
        Run(self)
        self.configures = (self.configures or 0) + 1
        return true
    end

    -- the parent was resized: the pieces follow, nothing else changes
    function Methods:Refit()
        if not self.spec then return end
        local w, h = FrameSize(self)
        if math_abs(w - (self._w or 0)) < 0.01 and math_abs(h - (self._h or 0)) < 0.01 then return end
        self._w, self._h = w, h
        Layout(self)
        Paint(self)
    end

    function Methods:SetColor(r, g, b, a)
        local s = self.spec
        if type(r) == "table" then r, g, b, a = RC.UI:ColorOf(r) end
        s.r, s.g, s.b, s.a = r or 1, g or 1, b or 1, a or 1
        Paint(self)
    end

    function Methods:IsGlowing()
        return self:IsShown() and self.spec.style ~= "none"
    end

    function RC.UI:CreateEdgeGlow(parent, opts)
        if not (parent and parent.GetFrameLevel) then return nil end
        local g = CreateFrame("Frame", nil, parent)
        g:SetAllPoints(parent)
        if g.EnableMouse then g:EnableMouse(false) end
        g._t = 0
        for k, fn in pairs(Methods) do g[k] = fn end
        local ag = g:CreateAnimationGroup()
        ag:SetLooping("BOUNCE")
        local a = ag:CreateAnimation("Alpha")
        a:SetFromAlpha(1)
        a:SetToAlpha(1 - DEFAULTS.depth)
        a:SetDuration(DEFAULTS.speed)
        if a.SetSmoothing then a:SetSmoothing("IN_OUT") end
        g.anim, g.animAlpha = ag, a
        g:Hide()
        g:SetScript("OnShow", function(self) Run(self) end)
        g:SetScript("OnHide", function(self)
            self.anim:Stop()
            if self.moving then self:SetScript("OnUpdate", nil) self.moving = false end
        end)
        g:SetScript("OnSizeChanged", function(self) self:Refit() end)
        g:Configure(opts)
        return g
    end
