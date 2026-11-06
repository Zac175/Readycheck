local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber

------------------------------------------------------------------------
-- Readycheck - UI Framework: the customization standard
-- One saved shape per family of "make it yours" setting and the runtime
-- helper that turns it into a real frame. Every feature adopts these so
-- every frame, text and part can be moved, laid out, shown, dressed,
-- restated and worded the same way. The pickers are in UIF_CustomUI.
--
-- THE RULE FOR EVERY FAMILY: nil = today's behaviour. A field left out
-- reads the feature's own `defaults` (exactly what it did before), so
-- nothing changes for anyone until they change it.
--
-- FAMILIES (shape -> helper), all on RC.UI unless noted:
--   anchor     { point, relPoint, x, y, to, justify,
--                point2, relPoint2, x2, y2, to2, fill }
--              RC.UI:ApplyAnchor(region, spec, defaults, resolveTo) -> ok, twoPoint
--              RC.UI:ResolveAnchor(spec, defaults) -> point, relPoint, x, y, to, justify, moved, retarget
--   frame pos  anchor fields + { strata, level, scale, clamp }
--              RC.UI:ApplyFramePosition(frame, spec, defaults, resolveTo)
--   layout     { grow, wrap, perLine, spacingX, spacingY, padding, itemW, itemH, sort, reverse, max }
--              RC.UI:LayoutItems(items, n, container, spec, defaults, opts) -> w, h, shown
--              RC.UI:SortItems(list, spec, defaults, comparators)
--   visibility { show, alpha, combatAlpha, mouseover, hoverAlpha, fadeIn, fadeOut, zones }
--              RC.Visibility.Register(frame, getSpec, opts) / Refresh / Allowed / Unregister
--              RC.UI:VisibilityMacro(spec) -> a state-driver string, or nil
--   chrome     { bgTexture, bgColor, bgInset, borderSize, borderColor,
--                shadowSize, shadowColor, glowSize, glowColor }
--              RC.UI:ApplyChrome(frame, spec, defaults, parts)
--   states     { [stateName] = { color, desat, alpha, border, glow, textColor, anim } }
--              RC.UI:ApplyState(states, name, defaults, parts) / RC.UI:StateValue(...)
--   text fmt   { abbrev, decimals, time, timeDecimalsUnder, maxLen, mark,
--                prefix, suffix, case, template }
--              RC.UI:FormatNumber / FormatTime / FormatName / FormatText
--   sound      { sound, channel, throttle }
--              RC.UI:PlaySoundSpec(spec, defaults, key) -> true if it played
--              (RC.UI:CreateSoundPicker stays the plain sound-name picker)
--   pick       RC.UI:TagElement(region, key), RC.CustomPick.SetHandler / Pick / ElementAt
--
-- WHERE SPECS LIVE (one convention for all of Readycheck): inside the
-- feature's own settings root (an RC.SETTINGS key), one sub-table per
-- family, keyed by element:
--   <root>.anchors.<element>   <root>.layout   <root>.visibility   <root>.chrome
--   <root>.states.<state>      <root>.formats.<element>   <root>.sounds.<event>
-- Because they sit under a registered root, export / import and mesh sync
-- carry them; each family table needs ONE registry row (see GUIDE_RC.md,
-- "Customization standard" > persistence). RC.UI:CustomAccess(owner,
-- family, key, after) -> get, set binds a picker and drops empty tables.
--
-- The implementation below is shared line for line with ZacUI's
-- (UIF_Custom there); only the bindings at the end differ.
------------------------------------------------------------------------

local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._uif = RC._uif or {}
local _uif = RC._uif

-- the implementation table (the ZacUI-shaped names the shared code uses)
local ns = {}
ns.FLAT = _uif.FLAT or "Interface\\Buttons\\WHITE8X8"
ns.DebugPrint = function(msg) RC:DebugPrint(msg, "ui") end
ns.ColorOf = function(c, fb) return RC.UI:ColorOf(c, fb) end
ns.ResolveBarTexture = function(name) return RC:ResolveTexture(name) end
-- alpha moves on the framework's own tracked tween (follows Appearance >
-- Motion); never Show / Hide, so a protected frame is safe in combat
ns.Motion = {
    FadeTo = function(frame, target, spec)
        target = tonumber(target) or 1
        local dur = spec and tonumber(spec.duration) or 0
        if RC.Motion and RC.Motion.Duration then dur = RC.Motion.Duration(dur) end
        local from = frame:GetAlpha() or 1
        local Tw = _uif.Tween
        if not Tw or dur <= 0 or math.abs(from - target) < 0.005 then
            if frame._rcVisFade then frame._rcVisFade:Cancel() frame._rcVisFade = nil end
            frame:SetAlpha(target)
            return false
        end
        Tw(frame, "_rcVisFade", "Custom:VisFade", dur, "linear", function(e) frame:SetAlpha(from + (target - from) * e) end)
        return true
    end,
    Play = function(frame, spec, how, onDone) return RC.Motion and RC.Motion.Play(frame, spec, how, onDone) end,
}

local type, tonumber, tostring, pairs, ipairs, next = type, tonumber, tostring, pairs, ipairs, next
local math_floor, math_max, math_min, math_abs, math_ceil = math.floor, math.max, math.min, math.abs, math.ceil
local string_format = string.format

local FLAT = ns.FLAT or "Interface\\Buttons\\WHITE8X8"
local EMPTY = setmetatable({}, { __newindex = function() end })

local Custom = {}
ns.Custom = Custom
Custom.EMPTY = EMPTY

-- Notes for whoever is looking (an anchor cycle, say): kept, never
-- printed to chat. ns.DebugPrint is used when a build has one.
Custom.notes = {}
local warned = setmetatable({}, { __mode = "k" })
local function Note(region, msg)
    if region and warned[region] then return end
    if region then warned[region] = true end
    if ns.DebugPrint then pcall(ns.DebugPrint, msg, "custom") end
    local n = Custom.notes
    if #n < 50 then n[#n + 1] = msg end
end
Custom.Note = Note

local function Copy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = (type(v) == "table") and Copy(v) or v end
    return o
end
Custom.Copy = Copy

-- A spec with nothing in it is no spec: nil, so the saved table stays clean.
local function Clean(t)
    if type(t) ~= "table" then return nil end
    for k, v in pairs(t) do
        if v == "" then t[k] = nil end
    end
    if next(t) == nil then return nil end
    return t
end
Custom.Clean = Clean

-- get / set for one spec inside a feature's settings table:
--   owner   the settings table, or a function returning it
--   family  "anchors" | "formats" | "states" | "sounds" (keyed by element)
--           or "layout" | "visibility" | "chrome" with key nil (one spec)
--   after   called after every set (re-apply the live frames)
function ns.CustomAccess(owner, family, key, after)
    local function T()
        if type(owner) == "function" then return owner() end
        return owner
    end
    local function get()
        local t = T()
        local f = type(t) == "table" and t[family]
        if key == nil then return f end
        return type(f) == "table" and f[key] or nil
    end
    local function set(spec)
        local t = T()
        if type(t) ~= "table" then return end
        spec = Clean(spec)
        if key == nil then
            t[family] = spec
        elseif spec == nil then
            local f = t[family]
            if type(f) == "table" then
                f[key] = nil
                if next(f) == nil then t[family] = nil end
            end
        else
            if type(t[family]) ~= "table" then t[family] = {} end
            t[family][key] = spec
        end
        if after then after() end
    end
    return get, set
end

-- ============================================================
-- ANCHOR
-- ============================================================
-- spec / defaults:
--   point     where on the element: TOPLEFT TOP TOPRIGHT LEFT CENTER RIGHT
--             BOTTOMLEFT BOTTOM BOTTOMRIGHT
--   relPoint  where on the target (nil = the same as point once point is
--             changed; the default's relPoint while it is not)
--   x, y      offset. nil = the default's while point and relPoint are the
--             default's, 0 once either changed (the default's insets
--             belong to the default's corner)
--   to        what it hangs off: an element key the feature resolves
--             (resolveTo(key) -> region), "parent", "screen" (UIParent);
--             in a defaults table also a region itself. nil = default.
--   justify   LEFT | CENTER | RIGHT for a FontString. nil = the default's
--             while the point is the default's; follows the point (a LEFT
--             side point -> LEFT) once it moved, unless defaults.keepJustify
--   point2, relPoint2, x2, y2, to2   an explicit second point
--   fill      false = never keep the default's second point
-- TWO-POINT ELEMENTS (a bar's text held LEFT + RIGHT): the defaults carry
-- point2 / relPoint2 / x2 / y2 (/ to2). The second point is kept, shifted
-- by the same x/y nudge, while point, relPoint and target are the default's
-- (so a nudge slides the whole span); once the element is moved elsewhere
-- it is single-point (ApplyAnchor returns twoPoint = false so the caller
-- can give it a width), unless the spec names its own point2.
local POINTS = { "TOPLEFT", "TOP", "TOPRIGHT", "LEFT", "CENTER", "RIGHT", "BOTTOMLEFT", "BOTTOM", "BOTTOMRIGHT" }
local VALID = {}
for _, p in ipairs(POINTS) do VALID[p] = true end
local JUSTIFY = { LEFT = true, CENTER = true, RIGHT = true }
ns.ANCHOR_POINTS = POINTS
Custom.VALID_POINT = VALID

function ns.AnchorJustifyFor(point)
    if type(point) ~= "string" then return nil end
    if point:find("LEFT", 1, true) then return "LEFT" end
    if point:find("RIGHT", 1, true) then return "RIGHT" end
    return "CENTER"
end
local JustifyFor = ns.AnchorJustifyFor

function ns.ResolveAnchor(spec, def)
    if type(spec) ~= "table" then spec = EMPTY end
    if type(def) ~= "table" then def = EMPTY end
    local dp = VALID[def.point] and def.point or "CENTER"
    local drp = VALID[def.relPoint] and def.relPoint or dp
    local sp = VALID[spec.point] and spec.point or nil
    local srp = VALID[spec.relPoint] and spec.relPoint or nil
    local pointMoved = sp ~= nil and sp ~= dp
    local point = sp or dp
    local relPoint = srp or (pointMoved and sp) or drp
    local moved = pointMoved or (relPoint ~= drp)
    local x = tonumber(spec.x)
    if x == nil then x = moved and 0 or (tonumber(def.x) or 0) end
    local y = tonumber(spec.y)
    if y == nil then y = moved and 0 or (tonumber(def.y) or 0) end
    local to = spec.to
    local retarget = false
    if to == nil or to == "" then
        to = def.to
    elseif to ~= def.to then
        retarget = true
    end
    local justify = JUSTIFY[spec.justify] and spec.justify or nil
    if not justify then
        if moved and not def.keepJustify then justify = JustifyFor(point)
        else justify = JUSTIFY[def.justify] and def.justify or nil end
    end
    return point, relPoint, x, y, to, justify, moved, retarget
end

-- what a `to` stands for; nil when a key cannot be resolved
local function Target(region, to, resolveTo)
    if to == nil or to == "parent" then return region:GetParent() end
    if type(to) == "table" then return to end
    if to == "screen" then return UIParent end
    if resolveTo then
        local ok, f = pcall(resolveTo, to)
        if ok and type(f) == "table" then return f end
    end
    return nil
end
Custom.Target = Target

-- Would anchoring `region` to `target` make a loop? Walks what the target
-- hangs off (and what that hangs off...). One reused stack, bounded.
local stack = {}
local function DependsOn(target, region)
    if target == region then return true end
    if type(target) ~= "table" or not target.GetNumPoints then return false end
    local top, seen, hit = 1, 0, false
    stack[1] = target
    while top > 0 do
        local f = stack[top]
        stack[top] = nil
        top = top - 1
        seen = seen + 1
        if seen > 200 then break end
        local n = f.GetNumPoints and f:GetNumPoints() or 0
        for i = 1, n do
            -- pcall: a region on a nameplate can't be measured (the client
            -- throws in instances); its anchors then aren't walked
            local ok, _, rel = pcall(f.GetPoint, f, i)
            if not ok then break end
            if rel == region then hit = true break end
            if type(rel) == "table" and rel ~= f and rel ~= UIParent then
                top = top + 1
                stack[top] = rel
            end
        end
        if hit then break end
    end
    for i = 1, top do stack[i] = nil end
    return hit
end
Custom.DependsOn = DependsOn

local function Place(region, point, target, relPoint, x, y)
    region:SetPoint(point, target, relPoint, x, y)
end

-- -> true, twoPoint. Callers apply on style / layout changes only, never
-- per frame; nothing is allocated here.
function ns.ApplyAnchor(region, spec, def, resolveTo, _fallback)
    if not (region and region.SetPoint) then return false end
    if type(def) ~= "table" then def = EMPTY end
    if type(spec) ~= "table" then spec = EMPTY end
    local point, relPoint, x, y, to, justify, moved, retarget = ns.ResolveAnchor(spec, def)
    local target = Target(region, to, resolveTo)
    if target == nil and to ~= def.to then
        target = Target(region, def.to, resolveTo)   -- a key this feature does not know
        retarget = false
    end
    if target == nil then target = region:GetParent() or UIParent end
    if DependsOn(target, region) then
        Note(region, "anchor: " .. tostring(spec.to or def.to) .. " would loop back; using the default")
        if spec ~= EMPTY and not _fallback then
            return ns.ApplyAnchor(region, nil, def, resolveTo, true)
        end
        target = region:GetParent() or UIParent
        if DependsOn(target, region) then target = UIParent end
    end
    region:ClearAllPoints()
    Place(region, point, target, relPoint, x, y)
    local two = false
    local sp2 = VALID[spec.point2] and spec.point2 or nil
    if sp2 then
        local t2 = target
        if spec.to2 ~= nil then
            t2 = Target(region, spec.to2, resolveTo) or target
            if DependsOn(t2, region) then t2 = target end
        end
        Place(region, sp2, t2, VALID[spec.relPoint2] and spec.relPoint2 or sp2,
            tonumber(spec.x2) or 0, tonumber(spec.y2) or 0)
        two = true
    elseif VALID[def.point2] and not moved and not retarget and spec.fill ~= false then
        local t2 = target
        if def.to2 ~= nil then
            t2 = Target(region, def.to2, resolveTo) or target
            if DependsOn(t2, region) then t2 = target end
        end
        local dx = x - (tonumber(def.x) or 0)
        local dy = y - (tonumber(def.y) or 0)
        Place(region, def.point2, t2, VALID[def.relPoint2] and def.relPoint2 or def.point2,
            (tonumber(def.x2) or 0) + dx, (tonumber(def.y2) or 0) + dy)
        two = true
    end
    if justify and region.SetJustifyH then region:SetJustifyH(justify) end
    return true, two
end

-- ============================================================
-- FRAME POSITION (a top-level frame: anchor + strata / level / scale / clamp)
-- ============================================================
--   strata  "BACKGROUND" | "LOW" | "MEDIUM" | "HIGH" | "DIALOG" | "FULLSCREEN" | "TOOLTIP"
--   level   an offset added to the default level (defaults.level, else the
--           level the frame had the first time this ran)
--   scale   number;  clamp  true | false (keep on screen)
-- A frame that already has a mover / saved position binds the anchor part
-- to its own keys (defaults = where the mover puts it) and uses these for
-- the rest. Protected frames in combat are left alone (returns false).
ns.STRATAS = { "BACKGROUND", "LOW", "MEDIUM", "HIGH", "DIALOG", "FULLSCREEN", "TOOLTIP" }
function ns.ApplyFramePosition(frame, spec, def, resolveTo)
    if not frame then return false end
    if InCombatLockdown and InCombatLockdown() and frame.IsProtected and frame:IsProtected() then return false end
    local s = type(spec) == "table" and spec or EMPTY
    def = type(def) == "table" and def or EMPTY
    if def.point or s.point or s.x or s.y or s.to then
        ns.ApplyAnchor(frame, s, def, resolveTo)
    end
    local strata = s.strata or def.strata
    if strata and frame.SetFrameStrata then frame:SetFrameStrata(strata) end
    if s.level ~= nil or def.level ~= nil then
        local base = tonumber(def.level) or frame._zcBaseLevel
        if not base then base = frame:GetFrameLevel() or 0 frame._zcBaseLevel = base end
        frame:SetFrameLevel(math_max(0, base + (tonumber(s.level) or 0)))
    end
    local sc = tonumber(s.scale) or tonumber(def.scale)
    if sc and sc > 0 then frame:SetScale(sc) end
    local clamp = s.clamp
    if clamp == nil then clamp = def.clamp end
    if clamp ~= nil and frame.SetClampedToScreen then frame:SetClampedToScreen(clamp and true or false) end
    return true
end

-- ============================================================
-- LAYOUT (several items: icon rows / grids, bar stacks, lists)
-- ============================================================
--   grow      RIGHT | LEFT | UP | DOWN | CENTER (a centred row)
--   wrap      the second axis when a line is full: DOWN | UP (rows) or
--             RIGHT | LEFT (columns). Default: DOWN for rows, RIGHT for columns
--   perLine   items per row / column; 0 or nil = all on one line
--   spacingX, spacingY, padding (container edge -> first item)
--   itemW, itemH   item size (nil = leave the items' own size)
--   sort      a key from the feature's own comparators (ns.SortItems)
--   reverse   true = last item first
--   max       most items shown (the rest are hidden)
-- opts.stretch: a vertical list whose items span the container's width
-- (each item gets two points, inset by padding).
-- opts.top / bottom / left / right: extra room kept clear at that edge of
-- the container (a header, a border) on top of the padding.
local GROWS = { RIGHT = true, LEFT = true, UP = true, DOWN = true, CENTER = true }
ns.LAYOUT_GROWS = { "RIGHT", "LEFT", "DOWN", "UP", "CENTER" }

local function LV(s, d, k, fb)
    local v = s[k]
    if v == nil then v = d[k] end
    if v == nil then v = fb end
    return v
end
Custom.Pick = LV

function ns.LayoutItems(items, n, container, spec, def, opts)
    local s = type(spec) == "table" and spec or EMPTY
    local d = type(def) == "table" and def or EMPTY
    opts = opts or EMPTY
    n = n or #items
    local mx = tonumber(LV(s, d, "max"))
    if mx and mx >= 0 and n > mx then n = mx end
    local grow = LV(s, d, "grow", "RIGHT")
    if not GROWS[grow] then grow = "RIGHT" end
    local horiz = (grow == "RIGHT" or grow == "LEFT" or grow == "CENTER")
    local wrap = LV(s, d, "wrap", horiz and "DOWN" or "RIGHT")
    if horiz and wrap ~= "UP" then wrap = "DOWN" end
    if not horiz and wrap ~= "LEFT" then wrap = "RIGHT" end
    local per = math_floor(tonumber(LV(s, d, "perLine", 0)) or 0)
    if per <= 0 or per > n then per = math_max(1, n) end
    local sx = tonumber(LV(s, d, "spacingX", 0)) or 0
    local sy = tonumber(LV(s, d, "spacingY", 0)) or 0
    local pad = tonumber(LV(s, d, "padding", 0)) or 0
    local iw, ih = tonumber(LV(s, d, "itemW")), tonumber(LV(s, d, "itemH"))
    local reverse = LV(s, d, "reverse", false)
    local lines = math_max(1, math_ceil(n / per))

    -- the container corner everything grows from
    local v, h
    if horiz then
        v = (wrap == "UP") and "BOTTOM" or "TOP"
        h = (grow == "LEFT") and "RIGHT" or (grow == "CENTER" and "" or "LEFT")
    else
        v = (grow == "UP") and "BOTTOM" or "TOP"
        h = (wrap == "LEFT") and "RIGHT" or "LEFT"
    end
    local corner = (v .. h)
    if corner == "" then corner = "CENTER" end
    local signX = (h == "RIGHT") and -1 or 1
    local signY = (v == "BOTTOM") and 1 or -1
    local edgeX = (h == "RIGHT") and (opts.right or 0) or (h == "LEFT" and (opts.left or 0) or 0)
    local edgeY = (v == "BOTTOM") and (opts.bottom or 0) or (opts.top or 0)
    local maxW, maxH = 0, 0
    for k = 0, n - 1 do
        local item = items[reverse and (n - k) or (k + 1)]
        if item then
            local w = iw or (item.GetWidth and item:GetWidth()) or 0
            local hh = ih or (item.GetHeight and item:GetHeight()) or 0
            if iw and ih and not opts.stretch then item:SetSize(iw, ih)
            elseif ih and opts.stretch then item:SetHeight(ih) end
            local line, pos = math_floor(k / per), k % per
            local x, y
            if horiz then
                if grow == "CENTER" then
                    local inLine = math_min(per, n - line * per)
                    x = (pos - (inLine - 1) / 2) * (w + sx)
                else
                    x = signX * (edgeX + pad + pos * (w + sx))
                end
                y = signY * (edgeY + pad + line * (hh + sy))
            else
                x = signX * (edgeX + pad + line * (w + sx))
                y = signY * (edgeY + pad + pos * (hh + sy))
            end
            item:ClearAllPoints()
            if opts.stretch and not horiz then
                item:SetPoint(v .. "LEFT", container, v .. "LEFT", pad + (opts.left or 0), y)
                item:SetPoint(v .. "RIGHT", container, v .. "RIGHT", -pad - (opts.right or 0), y)
            else
                item:SetPoint(corner, container, corner, x, y)
            end
            if item.Show then item:Show() end
            if w > maxW then maxW = w end
            if hh > maxH then maxH = hh end
        end
    end
    local cols = horiz and math_min(per, n) or lines
    local rows = horiz and lines or math_min(per, n)
    if n == 0 then return 2 * pad, 2 * pad, 0 end
    local W = cols * maxW + (cols - 1) * sx + 2 * pad
    local H = rows * maxH + (rows - 1) * sy + 2 * pad
    return W, H, n
end

-- sort a feature's own item list in place by the chosen key:
-- comparators = { name = function(a, b) ... end, time = ... }
function ns.SortItems(list, spec, def, comparators)
    local key = LV(type(spec) == "table" and spec or EMPTY, type(def) == "table" and def or EMPTY, "sort")
    local cmp = key and comparators and comparators[key]
    if cmp and #list > 1 then table.sort(list, cmp) end
    return key
end

-- ============================================================
-- VISIBILITY
-- ============================================================
--   show        "always" (nil) | "combat" | "nocombat" | "group" | "raid" |
--               "instance" | "target" | "resting" | "mouseover" | "never"
--   alpha       opacity out of combat (nil = leave the frame's own)
--   combatAlpha opacity in combat (nil = alpha)
--   mouseover   true = rise to hoverAlpha (1) while the mouse is over it
--   fadeIn, fadeOut   seconds for those moves (0.2 / 0.3)
--   zones       { [zone name] = true } only there (features that offer it)
-- ONE evaluator for every registered frame, driven by events only (combat,
-- roster, zone, target, resting) and OnEnter / OnLeave hooks for hover.
-- How a frame is driven (opts.control):
--   "alpha"  (default) only the alpha moves (Motion.FadeTo): safe on secure
--            frames in combat. A "hidden" secure frame is alpha 0 and can
--            still be clicked: give such frames a state driver instead
--            (ns.VisibilityMacro) where they already use one.
--   "shown"  Show / Hide as well (never on a protected frame in combat)
--   "gate"   nothing is touched: the feature reads Visibility.Allowed(frame)
--            in its own show logic and gets opts.onChange(frame, allowed, alpha)
-- A frame whose spec is nil is never touched (and gets its alpha back if a
-- spec is removed).
ns.VIS_SHOW = { "always", "combat", "nocombat", "group", "raid", "instance", "target", "resting", "mouseover", "never" }
local Vis = { frames = {}, combat = false, hover = setmetatable({}, { __mode = "k" }) }
ns.Visibility = Vis
local visEvents

local function InInstance()
    if not IsInInstance then return false end
    local inside, kind = IsInInstance()
    return inside and kind ~= "none" and kind ~= "pvp" and kind ~= "arena" or false
end

local function ShowMet(cond, frame)
    if cond == nil or cond == "always" then return true end
    if cond == "never" then return false end
    if cond == "combat" then return Vis.combat end
    if cond == "nocombat" then return not Vis.combat end
    if cond == "group" then return (IsInGroup and IsInGroup()) or false end
    if cond == "raid" then return (IsInRaid and IsInRaid()) or false end
    if cond == "instance" then return InInstance() end
    if cond == "target" then return (UnitExists and UnitExists("target")) or false end
    if cond == "resting" then return (IsResting and IsResting()) or false end
    if cond == "mouseover" then return Vis.hover[frame] or false end
    return true
end

local function SpecOf(e)
    if not e.get then return nil end
    local ok, s = pcall(e.get)
    if ok and type(s) == "table" and next(s) ~= nil then return s end
    return nil
end

function Vis.Allowed(frame)
    local e = Vis.frames[frame]
    if not e then return true end
    local s = SpecOf(e)
    if not s then return true end
    if not ShowMet(s.show, frame) then return false end
    if type(s.zones) == "table" and next(s.zones) ~= nil then
        local z = GetRealZoneText and GetRealZoneText() or ""
        if not s.zones[z] then return false end
    end
    if e.opts.extra then
        local ok, r = pcall(e.opts.extra, s)
        if ok and r == false then return false end
    end
    return true
end

-- the alpha the rule wants now, or nil (no spec / nothing about alpha)
function Vis.TargetAlpha(frame)
    local e = Vis.frames[frame]
    local s = e and SpecOf(e)
    if not s then return nil end
    if not Vis.Allowed(frame) then return 0 end
    local a = tonumber(s.alpha)
    if Vis.combat and s.combatAlpha ~= nil then a = tonumber(s.combatAlpha) end
    if (s.mouseover or s.show == "mouseover") and Vis.hover[frame] then
        a = tonumber(s.hoverAlpha) or 1
    end
    return a
end

local FADE = { style = "fade", duration = 0.2, easing = "linear" }
local function Evaluate(frame, e, instant)
    local s = SpecOf(e)
    local control = e.opts.control or "alpha"
    if not s then
        if e.touched then
            e.touched = nil
            if control ~= "gate" then
                local base = e.opts.baseAlpha or 1
                if ns.Motion and ns.Motion.FadeTo then ns.Motion.FadeTo(frame, base) else frame:SetAlpha(base) end
            end
            if e.opts.onChange then pcall(e.opts.onChange, frame, true, nil) end
        end
        return
    end
    if (s.mouseover or s.show == "mouseover") and not e.hooked then
        local hf = e.opts.hoverFrame or frame
        e.hooked = true
        hf:HookScript("OnEnter", function() Vis.hover[frame] = true Evaluate(frame, e) end)
        hf:HookScript("OnLeave", function()
            if hf.IsMouseOver and hf:IsMouseOver() and hf ~= frame then return end
            Vis.hover[frame] = nil
            Evaluate(frame, e)
        end)
    end
    local allowed = Vis.Allowed(frame)
    local a = Vis.TargetAlpha(frame)
    e.touched = true
    if control == "shown" then
        local locked = InCombatLockdown and InCombatLockdown() and frame.IsProtected and frame:IsProtected()
        if not locked then
            if allowed then frame:Show() else frame:Hide() end
        end
    end
    if control ~= "gate" and a ~= nil then
        local cur = frame:GetAlpha() or 1
        local up = a > cur
        local dur = tonumber(up and s.fadeIn or s.fadeOut) or (up and 0.2 or 0.3)
        if instant or dur <= 0 or not (ns.Motion and ns.Motion.FadeTo) then
            if ns.Motion and ns.Motion.FadeTo then ns.Motion.FadeTo(frame, a) else frame:SetAlpha(a) end
        else
            FADE.duration = dur
            ns.Motion.FadeTo(frame, a, FADE)
        end
    end
    if e.opts.onChange then pcall(e.opts.onChange, frame, allowed, a) end
end

local pending = false
local function RunAll()
    pending = false
    for f, e in pairs(Vis.frames) do Evaluate(f, e) end
end
function Vis.RefreshAll()
    if pending then return end
    pending = true
    C_Timer.After(0, RunAll)
end

local function EnsureEvents()
    if visEvents then return end
    visEvents = CreateFrame("Frame")
    for _, ev in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "GROUP_ROSTER_UPDATE",
        "ZONE_CHANGED_NEW_AREA", "PLAYER_ENTERING_WORLD", "PLAYER_TARGET_CHANGED", "PLAYER_UPDATE_RESTING" }) do
        pcall(visEvents.RegisterEvent, visEvents, ev)
    end
    visEvents:SetScript("OnEvent", function(_, ev)
        if ev == "PLAYER_REGEN_DISABLED" then Vis.combat = true
        elseif ev == "PLAYER_REGEN_ENABLED" then Vis.combat = false end
        Vis.RefreshAll()
    end)
    Vis.combat = (InCombatLockdown and InCombatLockdown()) or false
end

-- opts: control ("alpha" | "shown" | "gate"), hoverFrame, onChange(frame, allowed, alpha),
--       extra(spec) -> false to hide (a feature's own zone / raid filter), baseAlpha
function Vis.Register(frame, getSpec, opts)
    if not frame then return end
    EnsureEvents()
    local e = Vis.frames[frame]
    if not e then
        e = {}
        Vis.frames[frame] = e
    end
    e.get, e.opts = getSpec, opts or {}
    Evaluate(frame, e, true)
end
function Vis.Unregister(frame) Vis.frames[frame] = nil end
function Vis.Refresh(frame, instant)
    local e = frame and Vis.frames[frame]
    if e then Evaluate(frame, e, instant) end
end

-- The rule as a state-driver string for secure headers that already drive
-- their visibility that way (the bars): nil when the rule needs something a
-- macro condition cannot say (instance, resting, mouseover, zones).
local MACRO = { always = "show", never = "hide", combat = "[combat] show; hide",
    nocombat = "[combat] hide; show", group = "[group] show; hide", raid = "[group:raid] show; hide",
    target = "[@target,exists] show; hide" }
function ns.VisibilityMacro(spec)
    local s = type(spec) == "table" and spec or EMPTY
    if type(s.zones) == "table" and next(s.zones) ~= nil then return nil end
    return MACRO[s.show or "always"]
end

-- ============================================================
-- CHROME (background, border, shadow, glow)
-- ============================================================
--   bgTexture   a SharedMedia statusbar name (nil = flat)
--   bgColor     { r, g, b, a };   bgInset   px in from the edge
--   borderSize  px (0 = none);    borderColor { r, g, b, a }
--   shadowSize  px around the outside (0 = none); shadowColor
--   glowSize    px of glow outside the border (0 = none); glowColor
-- parts (optional): the feature's own pieces to dress instead of new ones:
--   { bg = texture, border = { top =, bottom =, left =, right = } or an array }
-- Only pieces with a value (spec or defaults) are touched or created.
-- Edges are flat strips (the house look); a corner style would need a
-- backdrop edge file and is not offered.
local SIDES = { "top", "bottom", "left", "right" }
local function Strips(frame, key, layer, sub)
    local own = frame[key]
    if own then return own end
    own = {}
    for _, side in ipairs(SIDES) do
        local t = frame:CreateTexture(nil, layer, nil, sub)
        t._zui_own = true
        t:SetTexture(FLAT)
        own[side] = t
    end
    frame[key] = own
    return own
end
local function EachStrip(strips, fn)
    if strips[1] then for _, t in ipairs(strips) do fn(t) end
    else for _, side in ipairs(SIDES) do if strips[side] then fn(strips[side], side) end end end
end
local function PlaceRing(frame, strips, size, out)
    local o = out and size or 0
    local tp, bt, lf, rt = strips.top, strips.bottom, strips.left, strips.right
    if not (tp and bt and lf and rt) then return end
    tp:ClearAllPoints() tp:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", -o, out and 0 or -size) tp:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", o, out and 0 or -size)
    tp:SetHeight(size)
    bt:ClearAllPoints() bt:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", -o, out and 0 or size) bt:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", o, out and 0 or size)
    bt:SetHeight(size)
    lf:ClearAllPoints() lf:SetPoint("TOPRIGHT", frame, "TOPLEFT", out and 0 or size, 0) lf:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", out and 0 or size, 0)
    lf:SetWidth(size)
    rt:ClearAllPoints() rt:SetPoint("TOPLEFT", frame, "TOPRIGHT", out and 0 or -size, 0) rt:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", out and 0 or -size, 0)
    rt:SetWidth(size)
end

local function ColorOf(c, fb)
    if ns.ColorOf then return ns.ColorOf(c, fb) end
    c = type(c) == "table" and c or fb or EMPTY
    return c.r or c[1] or 1, c.g or c[2] or 1, c.b or c[3] or 1, c.a or c[4] or 1
end

function ns.ApplyChrome(frame, spec, def, parts)
    if not frame then return end
    local s = type(spec) == "table" and spec or EMPTY
    local d = type(def) == "table" and def or EMPTY
    parts = parts or EMPTY
    -- background
    local tex, col, inset = LV(s, d, "bgTexture"), LV(s, d, "bgColor"), LV(s, d, "bgInset")
    if tex ~= nil or col ~= nil or inset ~= nil then
        local bg = parts.bg or frame._zcBg
        if not bg then
            bg = frame:CreateTexture(nil, "BACKGROUND", nil, -7)
            bg._zui_own = true
            frame._zcBg = bg
        end
        if tex ~= nil or not parts.bg then
            bg:SetTexture(tex and ns.ResolveBarTexture and ns.ResolveBarTexture(tex) or FLAT)
        end
        if col ~= nil then bg:SetVertexColor(ColorOf(col)) end
        if inset ~= nil or not parts.bg then
            local i = tonumber(inset) or 0
            bg:ClearAllPoints()
            bg:SetPoint("TOPLEFT", frame, "TOPLEFT", i, -i)
            bg:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -i, i)
        end
        bg:Show()
    end
    -- border
    local bs, bc = LV(s, d, "borderSize"), LV(s, d, "borderColor")
    if bs ~= nil or bc ~= nil then
        local strips = parts.border or Strips(frame, "_zcBorder", "OVERLAY", 7)
        local size = tonumber(bs)
        if size ~= nil and not parts.border then PlaceRing(frame, strips, size, false) end
        EachStrip(strips, function(t, side)
            if size ~= nil then
                if size <= 0 then t:Hide() else
                    t:Show()
                    if parts.border then
                        if side == "top" or side == "bottom" then t:SetHeight(size) elseif side then t:SetWidth(size) end
                    end
                end
            end
            if bc ~= nil then
                local r, g, b, a = ColorOf(bc)
                if t.SetColorTexture and parts.border then t:SetColorTexture(r, g, b, a) else t:SetVertexColor(r, g, b, a) end
            end
        end)
    end
    -- shadow: a dark margin behind the frame
    local ss, sc = LV(s, d, "shadowSize"), LV(s, d, "shadowColor")
    if ss ~= nil or sc ~= nil or frame._zcShadow then
        local sh = frame._zcShadow
        if not sh then
            sh = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
            sh._zui_own = true
            sh:SetTexture(FLAT)
            frame._zcShadow = sh
        end
        local n = tonumber(ss) or 0
        sh:ClearAllPoints()
        sh:SetPoint("TOPLEFT", frame, "TOPLEFT", -n, n)
        sh:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", n, -n)
        local r, g, b, a = ColorOf(sc, { r = 0, g = 0, b = 0, a = 0.6 })
        sh:SetVertexColor(r, g, b, a)
        sh:SetShown(n > 0)
    end
    -- glow: soft strips outside the edge
    local gs, gc = LV(s, d, "glowSize"), LV(s, d, "glowColor")
    if gs ~= nil or gc ~= nil or frame._zcGlow then
        local strips = Strips(frame, "_zcGlow", "OVERLAY", 6)
        local n = tonumber(gs) or 0
        PlaceRing(frame, strips, math_max(1, n), true)
        local r, g, b, a = ColorOf(gc, { r = 1, g = 0.82, b = 0, a = 0.8 })
        EachStrip(strips, function(t)
            t:SetBlendMode("ADD")
            t:SetVertexColor(r, g, b, a)
            t:SetShown(n > 0)
        end)
    end
end

-- ============================================================
-- PER-STATE STYLES
-- ============================================================
-- states = { [name] = { color, desat, alpha, border, glow, textColor, anim } }
--   color      tint of the icon / bar      desat   true | false
--   alpha      the frame's opacity         border  border colour
--   glow       a glow colour (nil = none)  textColor  text colour
--   anim       an animation spec played (as a highlight) when the state starts
-- defaults: { [name] = { the same fields } } - today's look per state.
-- parts: { frame, icon, bar, text (FontString or array), border (strips),
--          glow = function(on, r, g, b, a) }  (whatever the feature has)
-- Call it after the feature painted the state its usual way: only fields
-- that have a value are applied.
function ns.StateValue(states, name, field, defaults)
    local s = type(states) == "table" and states[name]
    local v = type(s) == "table" and s[field] or nil
    if v == nil and type(defaults) == "table" then
        local d = defaults[name]
        v = type(d) == "table" and d[field] or nil
    end
    return v
end
local SV = ns.StateValue

function ns.ApplyState(states, name, defaults, parts)
    if not (parts and name) then return end
    local c = SV(states, name, "color", defaults)
    if c ~= nil then
        local r, g, b, a = ColorOf(c)
        if parts.icon then parts.icon:SetVertexColor(r, g, b, a) end
        if parts.bar and parts.bar.SetStatusBarColor then parts.bar:SetStatusBarColor(r, g, b, a) end
    end
    local ds = SV(states, name, "desat", defaults)
    if ds ~= nil and parts.icon and parts.icon.SetDesaturated then parts.icon:SetDesaturated(ds and true or false) end
    local al = SV(states, name, "alpha", defaults)
    if al ~= nil and parts.frame then parts.frame:SetAlpha(tonumber(al) or 1) end
    local bc = SV(states, name, "border", defaults)
    if bc ~= nil and parts.border then
        local r, g, b, a = ColorOf(bc)
        EachStrip(parts.border, function(t)
            if t.SetColorTexture then t:SetColorTexture(r, g, b, a) else t:SetVertexColor(r, g, b, a) end
        end)
    end
    local tc = SV(states, name, "textColor", defaults)
    if tc ~= nil and parts.text then
        local r, g, b, a = ColorOf(tc)
        if parts.text.SetTextColor then parts.text:SetTextColor(r, g, b, a)
        else for _, fs in ipairs(parts.text) do fs:SetTextColor(r, g, b, a) end end
    end
    local gl = SV(states, name, "glow", defaults)
    if parts.glow then
        if gl ~= nil and gl ~= false then parts.glow(true, ColorOf(gl)) else parts.glow(false) end
    end
    local f = parts.frame
    if f then
        local was = f._zcState
        f._zcState = name
        if was ~= name and was ~= nil then
            local an = SV(states, name, "anim", defaults)
            if type(an) == "table" and ns.Motion and ns.Motion.Play then ns.Motion.Play(f, an, "update") end
        end
    end
end

-- ============================================================
-- TEXT FORMAT
-- ============================================================
--   abbrev   "short" (12.3k / 1.2m) | "comma" (12,345) | "full" (12345)
--   decimals digits after the point for short numbers and percents
--   time     "mmss" (1:05) | "clock" (1:05, under a minute 45s) |
--            "short" (1m / 45s) | "seconds" (65s)
--   timeDecimalsUnder  show tenths below this many seconds (0 = never)
--   maxLen   longest name / label (0 = no limit);  mark  what ends a cut ("...")
--   prefix, suffix   around the result;  case  "upper" | "lower" | nil
--   template "[cur] / [max] ([pct]%)" - only tokens the feature supplies
local function Round(v, d)
    local m = 10 ^ (d or 0)
    return math_floor(v * m + 0.5) / m
end

local function Comma(n)
    local s = tostring(math_floor(math_abs(n) + 0.5))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return (n < 0 and "-" or "") .. out
end

function ns.FormatNumber(v, spec, def)
    v = tonumber(v) or 0
    local s = type(spec) == "table" and spec or EMPTY
    local d = type(def) == "table" and def or EMPTY
    local ab = LV(s, d, "abbrev", "short")
    local dec = tonumber(LV(s, d, "decimals", 1)) or 1
    if ab == "comma" then return Comma(v) end
    if ab == "full" then return tostring(math_floor(v + 0.5)) end
    local a = math_abs(v)
    local fmt = "%." .. dec .. "f"
    if a >= 1e9 then return string_format(fmt .. "b", v / 1e9)
    elseif a >= 1e6 then return string_format(fmt .. "m", v / 1e6)
    elseif a >= 1e4 then return string_format(fmt .. "k", v / 1e3) end
    return tostring(math_floor(v + 0.5))
end

function ns.FormatTime(sec, spec, def)
    sec = tonumber(sec) or 0
    if sec < 0 then sec = 0 end
    local s = type(spec) == "table" and spec or EMPTY
    local d = type(def) == "table" and def or EMPTY
    local under = tonumber(LV(s, d, "timeDecimalsUnder", 0)) or 0
    if under > 0 and sec < under then return string_format("%.1f", sec) end
    local mode = LV(s, d, "time", "mmss")
    if mode == "seconds" then return math_floor(sec) .. "s" end
    if mode == "clock" then
        if sec >= 60 then return string_format("%d:%02d", math_floor(sec / 60), math_floor(sec % 60)) end
        return math_floor(sec) .. "s"
    end
    if mode == "short" then
        if sec >= 3600 then return math_floor(sec / 3600 + 0.5) .. "h" end
        if sec >= 60 then return math_floor(sec / 60 + 0.5) .. "m" end
        return math_floor(sec) .. "s"
    end
    if sec >= 3600 then
        return string_format("%d:%02d:%02d", math_floor(sec / 3600), math_floor(sec % 3600 / 60), math_floor(sec % 60))
    end
    if sec >= 60 then return string_format("%d:%02d", math_floor(sec / 60), math_floor(sec % 60)) end
    return tostring(math_floor(sec))
end

local function CaseOf(str, s, d)
    local c = LV(s, d, "case")
    if c == "upper" then return str:upper() elseif c == "lower" then return str:lower() end
    return str
end

function ns.FormatName(str, spec, def)
    str = tostring(str or "")
    local s = type(spec) == "table" and spec or EMPTY
    local d = type(def) == "table" and def or EMPTY
    local n = tonumber(LV(s, d, "maxLen", 0)) or 0
    if n > 0 and #str > n then
        local mark = LV(s, d, "mark", "...")
        local keep = math_max(1, n - #mark)
        str = str:sub(1, keep) .. mark
    end
    return CaseOf(str, s, d)
end

-- the whole line. values: the feature's own (reused) table of token ->
-- value; kinds: token -> "number" | "percent" | "time" | "name" | "text".
-- With no template the first token in `order` (or "value") is formatted.
local curValues, curKinds, curS, curD
local function Token(tok)
    local v = curValues[tok]
    if v == nil then return "" end
    local k = curKinds and curKinds[tok] or "text"
    if k == "number" then return ns.FormatNumber(v, curS, curD) end
    if k == "percent" then
        local dec = tonumber(LV(curS, curD, "decimals", 0)) or 0
        if dec > 0 then return string_format("%." .. dec .. "f", v) end
        return tostring(math_floor(v + 0.5))
    end
    if k == "time" then return ns.FormatTime(v, curS, curD) end
    if k == "name" then return ns.FormatName(v, curS, curD) end
    return tostring(v)
end

function ns.FormatText(spec, def, values, kinds, fallbackToken)
    local s = type(spec) == "table" and spec or EMPTY
    local d = type(def) == "table" and def or EMPTY
    curValues, curKinds, curS, curD = values or EMPTY, kinds, s, d
    local tpl = LV(s, d, "template")
    local out
    if type(tpl) == "string" and tpl ~= "" then
        out = tpl:gsub("%[(%w+)%]", Token)
    else
        out = Token(fallbackToken or "value")
    end
    curValues, curKinds, curS, curD = nil, nil, nil, nil
    local pre, suf = LV(s, d, "prefix", ""), LV(s, d, "suffix", "")
    if pre ~= "" or suf ~= "" then out = pre .. out .. suf end
    return CaseOf(out, s, d)
end

-- ============================================================
-- SOUND (per event)
-- ============================================================
--   sound     a SharedMedia sound name or a file path; nil = the feature's
--             default; "none" = silent
--   channel   "Master" | "SFX" | "Music" | "Ambience" | "Dialog"
--   throttle  seconds before the same event may sound again
-- The client has no per-sound volume, so there is none.
ns.SOUND_CHANNELS = { "Master", "SFX", "Music", "Ambience", "Dialog" }
local lastPlayed = {}
function ns.ResolveSoundLSM(name)
    if name == nil or name == "" or name == "none" then return nil end
    local lsm = LibStub and LibStub("LibSharedMedia-3.0", true)
    local p = lsm and lsm:Fetch("sound", name, true)
    if p then return p end
    if type(name) == "string" and (name:find("\\", 1, true) or name:find("/", 1, true)) then return name end
    return nil
end
function ns.PlaySoundSpec(spec, def, key)
    local s = type(spec) == "table" and spec or EMPTY
    local d = type(def) == "table" and def or EMPTY
    local path = ns.ResolveSound(LV(s, d, "sound"))
    if not path then return false end
    local th = tonumber(LV(s, d, "throttle", 0)) or 0
    if key and th > 0 then
        local now = GetTime and GetTime() or 0
        if lastPlayed[key] and now - lastPlayed[key] < th then return false end
        lastPlayed[key] = now
    end
    local ok = pcall(PlaySoundFile, path, LV(s, d, "channel", "Master"))
    return ok
end

-- ============================================================
-- "CUSTOMIZE THIS ELEMENT" (pick in the preview -> its controls)
-- ============================================================
-- A sample region carries the element key it shows (ns.TagElement); the
-- preview (or anything else) calls ns.CustomPick.Pick(previewKey, elementKey)
-- when one is clicked. The page decides what that means
-- (SetHandler: switch to the tab, pick the element in its dropdown); a
-- control group for that element already on screen (UI.TextElement /
-- UI.FrameElement with a `key`) is scrolled to and flashed.
local Pick = { handlers = {}, groups = setmetatable({}, { __mode = "v" }) }
ns.CustomPick = Pick
function ns.TagElement(region, key)
    if region then region._zElement = key end
    return region
end
function Pick.SetHandler(previewKey, fn) Pick.handlers[previewKey] = fn end
function Pick.RegisterGroup(elementKey, frame) if elementKey and frame then Pick.groups[elementKey] = frame end end
-- the element key a region (or one of its parents) was tagged with
function Pick.ElementAt(region)
    local f, depth = region, 0
    while f and depth < 12 do
        if f._zElement then return f._zElement end
        f = f.GetParent and f:GetParent() or nil
        depth = depth + 1
    end
    return nil
end
Pick.last = nil
function Pick.Pick(previewKey, elementKey)
    if not elementKey then return false end
    Pick.last = elementKey
    local fn = previewKey and Pick.handlers[previewKey]
    if fn then pcall(fn, elementKey) end
    local g = Pick.groups[elementKey]
    if g and g.IsVisible and g:IsVisible() then
        if g._zFlash then pcall(g._zFlash, g) end
        return true
    end
    return fn ~= nil
end


-- ============================================================
-- BINDINGS (Readycheck's names)
-- ============================================================
RC.Custom = Custom
RC.Visibility = ns.Visibility
RC.CustomPick = ns.CustomPick
RC.ANCHOR_POINTS = ns.ANCHOR_POINTS
RC.STRATAS = ns.STRATAS
RC.LAYOUT_GROWS = ns.LAYOUT_GROWS
RC.VIS_SHOW = ns.VIS_SHOW
RC.SOUND_CHANNELS = ns.SOUND_CHANNELS
function RC.UI:CustomAccess(owner, family, key, after) return ns.CustomAccess(owner, family, key, after) end
function RC.UI:ResolveAnchor(spec, defaults) return ns.ResolveAnchor(spec, defaults) end
function RC.UI:ApplyAnchor(region, spec, defaults, resolveTo) return ns.ApplyAnchor(region, spec, defaults, resolveTo) end
function RC.UI:AnchorJustifyFor(point) return ns.AnchorJustifyFor(point) end
function RC.UI:ApplyFramePosition(frame, spec, defaults, resolveTo) return ns.ApplyFramePosition(frame, spec, defaults, resolveTo) end
function RC.UI:LayoutItems(items, n, container, spec, defaults, opts) return ns.LayoutItems(items, n, container, spec, defaults, opts) end
function RC.UI:SortItems(list, spec, defaults, comparators) return ns.SortItems(list, spec, defaults, comparators) end
function RC.UI:VisibilityMacro(spec) return ns.VisibilityMacro(spec) end
function RC.UI:ApplyChrome(frame, spec, defaults, parts) return ns.ApplyChrome(frame, spec, defaults, parts) end
function RC.UI:StateValue(states, name, field, defaults) return ns.StateValue(states, name, field, defaults) end
function RC.UI:ApplyState(states, name, defaults, parts) return ns.ApplyState(states, name, defaults, parts) end
function RC.UI:FormatNumber(v, spec, defaults) return ns.FormatNumber(v, spec, defaults) end
function RC.UI:FormatTime(sec, spec, defaults) return ns.FormatTime(sec, spec, defaults) end
function RC.UI:FormatName(str, spec, defaults) return ns.FormatName(str, spec, defaults) end
function RC.UI:FormatText(spec, defaults, values, kinds, fallbackToken) return ns.FormatText(spec, defaults, values, kinds, fallbackToken) end
function RC.UI:ResolveSound(name)
    if name == nil or name == "" or name == "none" then return nil end
    return (RC.GetSoundFile and RC:GetSoundFile(name)) or ns.ResolveSoundLSM(name)
end
ns.ResolveSound = function(name) return RC.UI:ResolveSound(name) end
function RC.UI:PlaySoundSpec(spec, defaults, key) return ns.PlaySoundSpec(spec, defaults, key) end
function RC.UI:TagElement(region, key) return ns.TagElement(region, key) end
