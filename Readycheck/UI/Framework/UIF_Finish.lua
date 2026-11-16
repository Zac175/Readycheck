------------------------------------------------------------------------
-- Readycheck - UI Framework: the surface finish
-- A window's ground was one flat colour. It keeps that colour; this lays
-- four quiet things over it, the same four ZacUI's windows wear, so the
-- two addons' windows match:
--   the grain     a brushed-metal tile (Media/Textures/brushed - made for
--                 these two addons, the same file ZacUI ships), light and
--                 dark streaks at a few percent
--   the lift      the window's text colour, strongest at the top
--   the sink      the window's shade colour, strongest at the foot
--   the lit edge  one pixel of pale light along the inside of the top
--
--   RC.UI:Finish(host, fill, role, alpha)   lay it on (once) and paint it
--       host  the window; fill: its fill texture, or nil where the window
--             is drawn by a backdrop (the pieces then sit one pixel inside
--             the frame); role: "window" (default) or "card"; alpha: how
--             see-through the window is drawn (the /rc window's opacity)
--   RC.UI:FinishStrength()           0 .. 2 (1 as shipped)
--   RC.UI:FinishRefresh()            repaint every one (a look change)
--
-- Beside ZacUI the strength is ZacUI's (its Style page's "Surface finish"
-- slider: 0 turns it off in both); on its own Readycheck draws it as
-- shipped. Nothing is saved by Readycheck.
--
-- This file and its texture are new in the update that brought them: the
-- game only finds new files after a restart. Callers ask
-- `RC.UI.Finish and ...`, so a client that was only reloaded keeps the
-- flat windows instead of drawing a texture it cannot find.
------------------------------------------------------------------------
local type, pairs, ipairs, tonumber, setmetatable = type, pairs, ipairs, tonumber, setmetatable
local math_min, math_max = math.min, math.max

local RC = _G.Readycheck
if not RC then return end
RC._uif = RC._uif or {}
local _uif = RC._uif
if not RC.UI then return end

    local FLAT = _uif.FLAT or "Interface\\Buttons\\WHITE8X8"
    local TEX = "Interface\\AddOns\\Readycheck\\Media\\Textures\\brushed"

    -- How much of each piece a kind of surface takes (alphas, over the
    -- fill). The numbers are ZacUI's (Core_Finish), so the two match.
    -- (2026-11-16 07:13, Zac, after seeing it in the game: "its too much with the
    -- texturing i don't like it".) The grain is OFF: no brushed tile is drawn.
    -- The soft depth stays until he has picked what replaces it.
    local GRAIN = 0
    local ROLES = {
        window = { grain = 1.00, lift = { 0.028, 0 }, sink = { 0, 0.14 }, lit = 0.055 },
        card   = { grain = 0.80, lift = { 0.030, 0 }, sink = { 0, 0.08 }, lit = 0.050 },
    }

    local finished = setmetatable({}, { __mode = "k" })   -- host -> record
    local hooked = false

    function RC.UI:FinishStrength()
        local Z = _G.ZacUI
        local F = type(Z) == "table" and Z.Finish or nil
        if type(F) == "table" and type(F.Strength) == "function" then
            -- ZacUI repaints its own windows when its slider moves; ours
            -- are repainted from the same call
            if not hooked and type(F.Refresh) == "function" and hooksecurefunc then
                hooked = true
                hooksecurefunc(F, "Refresh", function() RC.UI:FinishRefresh() end)
            end
            local v = tonumber(F.Strength())
            if v then return math_max(0, math_min(2, v)) end
        end
        return 1
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

    local function Paint(d)
        local k = RC.UI:FinishStrength()
        local on = k > 0
        for _, t in ipairs(d.parts) do t:SetShown(on) end
        if not on then return end
        local role = d.role
        -- (a window drawn see-through carries that much of the finish)
        local a = d.alpha or 1
        k = k * a
        local depth = math_min(1, RC.UI:FinishStrength()) * a
        local lr, lg, lb = Light()
        local dr, dg, db = Dark()
        -- (the tile carries its own light and dark; its light streaks
        -- take the window's light colour, as the lift does)
        d.grain:SetVertexColor(lr, lg, lb, GRAIN * role.grain * k)
        Ramp(d.lift, lr, lg, lb, role.lift[1] * depth, role.lift[2] * depth)
        Ramp(d.sink, dr, dg, db, role.sink[1] * depth, role.sink[2] * depth)
        d.lit:SetVertexColor(lr, lg, lb, role.lit * depth)
    end

    function RC.UI:Finish(host, fill, role, alpha)
        if type(host) ~= "table" or not host.CreateTexture then return nil end
        local d = finished[host]
        if not d then
            local r = ROLES[role or "window"] or ROLES.window
            local layer, sub = "BACKGROUND", -8
            if fill and fill.GetDrawLayer then
                local l, s = fill:GetDrawLayer()
                if type(l) == "string" then layer, sub = l, tonumber(s) or 0 end
            end
            d = { role = r, parts = {} }
            local function Part(n)
                local t = host:CreateTexture(nil, layer, nil, math_max(-8, math_min(7, sub + n)))
                t:SetTexture(FLAT)
                d.parts[#d.parts + 1] = t
                return t
            end
            -- over the fill; with no fill texture (a backdrop draws the
            -- window) one pixel inside the frame, clear of its edge
            local function Cover(t)
                if fill then
                    t:SetAllPoints(fill)
                else
                    t:SetPoint("TOPLEFT", host, "TOPLEFT", 1, -1)
                    t:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -1, 1)
                end
            end
            d.grain = Part(1)
            d.grain:SetTexture(TEX, "REPEAT", "REPEAT")
            if d.grain.SetHorizTile then d.grain:SetHorizTile(true) end
            if d.grain.SetVertTile then d.grain:SetVertTile(true) end
            Cover(d.grain)
            d.lift = Part(2)
            Cover(d.lift)
            d.sink = Part(3)
            Cover(d.sink)
            d.lit = Part(4)
            d.lit:SetHeight(1)
            local anchor = fill or host
            d.lit:SetPoint("TOPLEFT", anchor, "TOPLEFT", 1, -1)
            d.lit:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -1, -1)
            finished[host] = d
            RC:DebugPrint("Finish: " .. tostring(host.GetName and host:GetName() or "?"), "ui")
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
