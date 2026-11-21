------------------------------------------------------------------------
-- Readycheck - UI Framework: the surface finish
-- A surface was one flat colour. It keeps that colour; this lays a few
-- quiet things over it, the same ones ZacUI's surfaces wear (Core_Finish
-- there, the same numbers), so the two addons' windows match:
--   a window's ground   the window's text colour lifting its top, its shade
--                 colour sinking its foot, one pixel of pale light along
--                 the inside of its top
--   a card        the same, a little lighter: a plate on the window
--   a title bar   a raised bar: lifted, lit along its top, a dark line
--                 along its foot and a pale one under that, so the page
--                 under it reads as cut in. No gradient across it.
--   a band        a section's raised header: lifted, lit, a dark foot
--   a strip       a row of chrome along a window's foot: lifted, lit
--   a well        a field cut into the surface: dark under its top lip,
--                 light caught under its foot
-- (2026-11-16 12:39, Zac: "why did you only do zui and not both addons".
-- Readycheck had the ground alone; ZacUI's windows also had the raised
-- title bar, the cards, the strip and the wells. Now both have all of it.)
--
--   RC.UI:Finish(host, fill, role, alpha, opts)   lay it on (once) and paint it
--       host  the frame; fill: its fill texture, or nil where the frame has
--             none of its own (a window drawn by a backdrop: the pieces sit
--             one pixel inside it; a title bar: they cover it)
--       role  "window" (default), "card", "bar", "band", "strip", "well"
--       alpha how see-through the surface is drawn (the /rc window's
--             opacity)
--       opts.inset  the lit edge sits this far in from the sides and top
--             (default 1: inside a one-pixel border)
--       opts.step = false  no pale line under a bar's foot
--   RC.UI:FinishStrength()           0 .. 2 (1 as shipped)
--   RC.UI:FinishRefresh()            repaint every one (a look change)
--
-- THE FINISH IS A CHOICE (2026-11-18; RC.UI:Look in UIF_Base has the
-- settings). Soft depth, above, is what ships. The other kinds:
--   "bands"  no shading: title bars, strips, cards and bands are flat
--            DARKER pieces
--   "plain"  flat: strips and bands a step lighter
-- and, with any kind: an accent line under a window's title bar, and a
-- ground texture (nine, the same tiles as ZacUI's) at its own strength.
-- Beside ZacUI all of it is ZacUI's (its Style page; depth 0 turns the
-- shading off in both) unless Readycheck is set to use its own.
--
-- This file is newer than the windows it dresses: the game only finds a
-- new file after a restart. Callers ask `RC.UI.Finish and ...`, so a
-- client that was only reloaded keeps the flat surfaces.
------------------------------------------------------------------------
local type, pairs, ipairs, tonumber, setmetatable = type, pairs, ipairs, tonumber, setmetatable
local math_min, math_max = math.min, math.max

local RC = _G.Readycheck
if not RC then return end
RC._uif = RC._uif or {}
local _uif = RC._uif
if not RC.UI then return end

    local FLAT = _uif.FLAT or "Interface\\Buttons\\WHITE8X8"
    local TEXDIR = "Interface\\AddOns\\Readycheck\\Media\\Textures\\"

    -- How much of each piece a kind of surface takes (alphas, over the
    -- fill). The numbers are ZacUI's (Core_Finish), so the two match.
    -- (2026-11-16 07:13, Zac, after seeing it in the game: "its too much with the
    -- texturing i don't like it".) No texture is drawn unless one is asked
    -- for (the look's grain); GRAIN is the tile's alpha at 100%, the first
    -- build's.
    local GRAIN = 0.055
    --   grain  share of GRAIN            lift  { at the top, at the foot }
    --   sink   { at the top, at the foot }      lit   the pale line inside the top
    --   foot   the dark line along the foot     step  the pale line under that foot
    --   shade  dark under a well's top lip (shadeH tall)   catch  light under its foot
    local ROLES = {
        window = { grain = 1.00, lift = { 0.028, 0 }, sink = { 0, 0.14 }, lit = 0.055 },
        card   = { grain = 0.80, lift = { 0.030, 0 }, sink = { 0, 0.08 }, lit = 0.050 },
        bar    = { lift = { 0.070, 0.022 }, lit = 0.10, foot = 0.70, step = 0.05 },
        band   = { lift = { 0.090, 0.030 }, lit = 0.09, foot = 0.60 },
        strip  = { lift = { 0.045, 0.010 }, lit = 0.07 },
        well   = { shade = 0.30, shadeH = 5, catch = 0.05 },
    }
    RC.UI.FINISH_ROLES = ROLES
    RC.UI.FINISH_GRAIN = GRAIN
    -- the other two kinds (ZacUI's Core_Finish KINDS, the same numbers); a
    -- role with nothing listed is the bare surface
    local KINDS = {
        depth = ROLES,
        bands = {
            window = {}, well = {},
            bar   = { sink = { 0.42, 0.42 } },
            strip = { sink = { 0.42, 0.42 } },
            card  = { sink = { 0.50, 0.50 } },
            band  = { sink = { 0.30, 0.30 } },
        },
        plain = {
            window = {}, well = {}, bar = {}, card = {},
            strip = { lift = { 0.035, 0.035 } },
            band  = { lift = { 0.05, 0.05 } },
        },
    }
    RC.UI.FINISH_KIND_ROLES = KINDS
    local RULE = 0.9      -- the accent line under a title bar

    local finished = setmetatable({}, { __mode = "k" })   -- host -> record
    local hooked = false

    function RC.UI:FinishStrength()
        local Z = _G.ZacUI
        local F = type(Z) == "table" and Z.Finish or nil
        if type(F) == "table" and type(F.Strength) == "function" then
            -- ZacUI repaints its own windows when a finish setting moves;
            -- ours are repainted from the same call
            if not hooked and type(F.Refresh) == "function" and hooksecurefunc then
                hooked = true
                hooksecurefunc(F, "Refresh", function() RC.UI:FinishRefresh() end)
            end
        end
        return (RC.UI:Look()).depth
    end

    -- the window's light and dark, from the theme ("settings": its text
    -- colour and its shade colour, the one the row bands are drawn in)
    local function Light()
        local c = RC:GetColor("settings", "text")
        return c.r or 1, c.g or 1, c.b or 1
    end
    local function Dark()
        local c = RC:GetColor("settings", "shade")
        return c.r or 0, c.g or 0, c.b or 0
    end

    -- colour (r, g, b) from one alpha at the top to another at the foot
    local function Ramp(tex, r, g, b, top, bot)
        if CreateColor and tex.SetGradient then
            tex:SetVertexColor(1, 1, 1, 1)
            tex:SetGradient("VERTICAL", CreateColor(r, g, b, bot), CreateColor(r, g, b, top))
        elseif tex.SetGradientAlpha then
            tex:SetVertexColor(1, 1, 1, 1)
            tex:SetGradientAlpha("VERTICAL", r, g, b, bot, r, g, b, top)
        else
            tex:SetVertexColor(r, g, b, (top + bot) / 2)
        end
    end

    -- One piece over a surface, made the first time it is wanted.
    -- Sublevels over the fill: texture 1, lift 2, sink 3, the lines 4,
    -- the accent line 5.
    local function Make(d, key)
        local host, fill, anchor, inset = d.host, d.fill, d.anchor, d.inset
        local function Part(n)
            local t = host:CreateTexture(nil, d.layer, nil, math_max(-8, math_min(7, d.sub + n)))
            t:SetTexture(FLAT)
            d[key] = t
            d.parts[#d.parts + 1] = t
            return t
        end
        -- over the fill; with no fill texture, a window (a backdrop
        -- draws it) is covered one pixel inside the frame, clear of
        -- its edge, and any other piece whole
        local function Cover(t)
            if fill then
                t:SetAllPoints(fill)
            else
                t:SetPoint("TOPLEFT", host, "TOPLEFT", d.edge, -d.edge)
                t:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -d.edge, d.edge)
            end
        end
        local t
        if key == "grain" then
            t = Part(1)
            d.grainTex = TEXDIR .. "brushed"
            t:SetTexture(d.grainTex, "REPEAT", "REPEAT")
            if t.SetHorizTile then t:SetHorizTile(true) end
            if t.SetVertTile then t:SetVertTile(true) end
            Cover(t)
        elseif key == "lift" then
            t = Part(2)
            Cover(t)
        elseif key == "sink" then
            t = Part(3)
            Cover(t)
        elseif key == "lit" then
            t = Part(4)
            if RC.Line then RC.Line(t, "H", 1) else t:SetHeight(1) end
            t:SetPoint("TOPLEFT", anchor, "TOPLEFT", inset, -inset)
            t:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -inset, -inset)
        elseif key == "foot" then
            t = Part(4)
            if RC.Line then RC.Line(t, "H", 1) else t:SetHeight(1) end
            t:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 0, 0)
            t:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
        elseif key == "accent" then
            t = Part(5)
            if RC.Line then RC.Line(t, "H", 1) else t:SetHeight(1) end
            t:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 0, 0)
            t:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
        elseif key == "step" then
            t = Part(4)
            if RC.Line then RC.Line(t, "H", 1) else t:SetHeight(1) end
            t:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, 0)
            t:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
        elseif key == "shade" then
            t = Part(1)
            t:SetHeight(ROLES[d.name].shadeH or 5)
            t:SetPoint("TOPLEFT", anchor, "TOPLEFT", inset, -inset)
            t:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -inset, -inset)
        elseif key == "catch" then
            t = Part(1)
            if RC.Line then RC.Line(t, "H", 1) else t:SetHeight(1) end
            t:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, 0)
            t:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
        end
        return t
    end
    -- (the order pieces are made in when a surface is dressed)
    local ORDER = { "grain", "lift", "sink", "lit", "foot", "step", "shade", "catch" }

    -- Paints what lies over one surface from the look in force. A piece
    -- that look does not have is hidden; one it has and the surface never
    -- needed before is made here.
    local function Paint(d)
        RC.UI:FinishStrength()        -- (hooks ZacUI's repaint the first time)
        local L = RC.UI:Look()
        local k, g = L.depth, L.grain
        local rule = L.rule and d.name == "bar"
        local share = ROLES[d.name].grain
        if k <= 0 and not rule and not (share and g > 0) then
            for _, t in ipairs(d.parts) do t:SetShown(false) end
            return
        end
        local role = KINDS[L.kind][d.name] or ROLES[d.name]
        -- (a window drawn see-through carries that much of the finish)
        local a = d.alpha or 1
        local depth = math_min(1, k) * a
        local lr, lg, lb = Light()
        local dr, dg, db = Dark()
        -- (the tile carries its own light and dark; its light streaks
        -- take the window's light colour, as the lift does. A surface
        -- dressed while no texture was asked for keeps its piece at
        -- nothing, as it always had)
        if share and (d.grain or g > 0) then
            local t = d.grain or Make(d, "grain")
            local path = TEXDIR .. (RC.UI.FINISH_TEX_FILE[L.texture] or "brushed")
            if d.grainTex ~= path then
                d.grainTex = path
                t:SetTexture(path, "REPEAT", "REPEAT")
            end
            t:SetShown(true)
            t:SetVertexColor(lr, lg, lb, GRAIN * share * g * a)
        end
        local function Piece(key)
            local want = role[key] ~= nil and depth > 0 and not (key == "step" and d.noStep)
            local t = d[key]
            if want and not t then t = Make(d, key) end
            if t then t:SetShown(want) end
            return want and t or nil
        end
        local t = Piece("lift")
        if t then Ramp(t, lr, lg, lb, role.lift[1] * depth, role.lift[2] * depth) end
        t = Piece("sink")
        if t then Ramp(t, dr, dg, db, role.sink[1] * depth, role.sink[2] * depth) end
        t = Piece("lit")
        if t then t:SetVertexColor(lr, lg, lb, role.lit * depth) end
        t = Piece("foot")
        if t then t:SetVertexColor(dr, dg, db, role.foot * depth) end
        t = Piece("step")
        if t then t:SetVertexColor(lr, lg, lb, role.step * depth) end
        t = Piece("shade")
        if t then Ramp(t, dr, dg, db, role.shade * depth, 0) end
        t = Piece("catch")
        if t then t:SetVertexColor(lr, lg, lb, role.catch * depth) end
        -- the accent line under a window's title bar
        if rule or d.accent then
            local line = d.accent or Make(d, "accent")
            line:SetShown(rule)
            if rule then
                local A = RC.UI:SAccent()
                line:SetVertexColor(A.r, A.g, A.b, RULE * a)
            end
        end
    end

    function RC.UI:Finish(host, fill, role, alpha, opts)
        if type(host) ~= "table" or not host.CreateTexture then return nil end
        local d = finished[host]
        if not d then
            local name = ROLES[role or "window"] and (role or "window") or "window"
            local r = ROLES[name]
            opts = opts or {}
            local layer, sub = "BACKGROUND", -8
            if fill and fill.GetDrawLayer then
                local l, s = fill:GetDrawLayer()
                if type(l) == "string" then layer, sub = l, tonumber(s) or 0 end
            end
            d = { role = r, name = name, parts = {}, host = host, fill = fill, anchor = fill or host,
                  layer = layer, sub = sub, inset = tonumber(opts.inset) or 1,
                  edge = (name == "window" or name == "card") and 1 or 0,
                  noStep = (opts.step == false) or nil }
            -- the shipped finish's pieces, as before; another finish's
            -- are made when it is first painted
            for _, key in ipairs(ORDER) do
                if r[key] ~= nil and not (key == "step" and d.noStep) then Make(d, key) end
            end
            finished[host] = d
            RC:DebugPrint("Finish (" .. name .. "): " .. tostring(host.GetName and host:GetName() or "?"), "ui")
        end
        d.alpha = (type(alpha) == "number") and math_max(0, math_min(1, alpha)) or 1
        Paint(d)
        return d
    end

    function RC.UI:FinishRefresh()
        for _, d in pairs(finished) do Paint(d) end
    end

    -- for the suites: what lies over a window
    function RC.UI:FinishOf(host) return host and finished[host] or nil end
