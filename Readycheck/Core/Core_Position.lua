local RC = _G.Readycheck
if not RC then return end

local UIParent = UIParent
local InCombatLockdown = InCombatLockdown
local type = type

------------------------------------------------------------------------
-- Readycheck - Frame Positions
-- One rule for every movable frame: the frame's pinned <point> sits at
-- (x, y) UI units from the CENTER of UIParent. Frames on the same rule
-- move the same way when the window or UI scale changes.
--
-- A position is written only by user action (drag, mover, settings).
-- Saves from older versions in other forms are converted the first time
-- they are applied, without moving the frame.
------------------------------------------------------------------------

local P = {}
RC.Position = P
-- a bound frame may be re-pinned by another corner at runtime (set
-- frame.__rcPos.point, then RestoreFrame): the save converts correctly
P.repinSafe = true

local function PointCoords(point, left, bottom, w, h)
    local x, y
    if point:find("LEFT", 1, true) then x = left
    elseif point:find("RIGHT", 1, true) then x = left + w
    else x = left + w / 2 end
    if point:find("BOTTOM", 1, true) then y = bottom
    elseif point:find("TOP", 1, true) then y = bottom + h
    else y = bottom + h / 2 end
    return x, y
end

local function CanAnchor(frame)
    return not (InCombatLockdown() and frame.IsProtected and frame:IsProtected())
end

-- Live position of the frame's `point` as centre offsets, in the
-- frame's own units (what SetPoint wants).
function P.Capture(frame, point)
    local left, bottom, w, h = frame:GetRect()
    if not left then return nil end
    local k = UIParent:GetEffectiveScale() / frame:GetEffectiveScale()
    local x, y = PointCoords(point or "CENTER", left, bottom, w, h)
    return x - UIParent:GetWidth() / 2 * k, y - UIParent:GetHeight() / 2 * k
end

function P.Apply(frame, x, y, point)
    if not CanAnchor(frame) then return false end
    frame:ClearAllPoints()
    frame:SetPoint(point or "CENTER", UIParent, "CENTER", x or 0, y or 0)
    return true
end

-- Places the frame the old way (frame `oldPoint` at UIParent `oldRel`)
-- and returns that spot in canonical form for `point`.
function P.ApplyLegacy(frame, oldPoint, oldRel, x, y, point)
    if not CanAnchor(frame) then return nil end
    oldPoint = oldPoint or "CENTER"
    frame:ClearAllPoints()
    frame:SetPoint(oldPoint, UIParent, oldRel or oldPoint, x or 0, y or 0)
    local nx, ny = P.Capture(frame, point)
    if nx then P.Apply(frame, nx, ny, point) end
    return nx, ny
end

-- Screen clamp --------------------------------------------------------
--
-- Every bound frame stays on screen and may touch the client edge. Bars
-- keep a padded rect for their background and border; with that chrome
-- hidden the padding is invisible, so the clamp is measured from the
-- visible children instead and the padding may cross the edge.

local function ChromeHidden(frame)
    -- A bar says outright whether its background is on (SyncBarChrome).
    -- Its border alone can't tell: an unlocked bar draws a gold outline
    -- while it is being moved, which made the clamp keep the invisible
    -- padding on screen exactly while dragging.
    if frame.__rcChromeHidden ~= nil then return frame.__rcChromeHidden end
    local bd = frame.border
    return (bd and bd.top and bd.top.IsShown and not bd.top:IsShown()) and true or false
end

-- Bounding rect of the shown child frames, or nil when the frame's own
-- rect is what the user sees (chrome shown, or nothing laid out yet).
-- A child flagged __rcNoClamp (an unlocked bar's title strip) is left
-- out, so it never keeps the bar off the screen edge.
function P.VisibleBounds(frame)
    local l, r, t, b
    for _, c in ipairs({ frame:GetChildren() }) do
        if c:IsShown() and not c.__rcNoClamp and c:GetLeft() then
            local cl, cr, ct, cb = c:GetLeft(), c:GetRight(), c:GetTop(), c:GetBottom()
            l = (l and math.min(l, cl)) or cl
            r = (r and math.max(r, cr)) or cr
            t = (t and math.max(t, ct)) or ct
            b = (b and math.min(b, cb)) or cb
        end
    end
    if not (l and r > l and t > b) then return nil end

    if ChromeHidden(frame) then
        -- No border or background drawn: the children ARE the frame as far
        -- as the eye is concerned, so the clamp follows them and the
        -- invisible padding is allowed to cross the screen edge.
        return l, r, t, b
    end

    -- Chrome is drawn, so the frame's own rect counts. A child that sits
    -- OUTSIDE that rect still has to stay on screen, though - a header
    -- docked above a bar was being pushed off the top, because the clamp
    -- only ever knew about the rect. Union the two, and only bother
    -- returning bounds when a child actually sticks out.
    local fl, fr, ft, fb = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    if not fl then return nil end
    if l >= fl and r <= fr and t <= ft and b >= fb then return nil end
    return math.min(l, fl), math.max(r, fr), math.max(t, ft), math.min(b, fb)
end

-- Insets are (content edge - frame edge) per side, in the frame's units.
-- The client treats a positive left/bottom and a negative right/top as
-- "this much of the frame may cross the edge", so content inside the
-- rect loosens the clamp by the invisible margin and content past the
-- rect (a dock group) tightens it. Pass explicit content edges to
-- override VisibleBounds.
-- Clamping a protected frame (the secure gear, trinket and potion
-- buttons) is refused in combat. pcall does not stop that - it only hides
-- the Lua error, and the client still reports the blocked call - so a
-- clamp asked for mid-fight (a /reload or login in combat, the mover
-- registering frames) waits for the fight to end instead.
local pendingClamp = {}
local clampWatch
local function DeferClamp(frame, cl, cr, ct, cb)
    pendingClamp[frame] = { cl, cr, ct, cb }
    if clampWatch then return end
    clampWatch = CreateFrame("Frame")
    clampWatch:RegisterEvent("PLAYER_REGEN_ENABLED")
    clampWatch:SetScript("OnEvent", function()
        local list = pendingClamp
        pendingClamp = {}
        for f, a in pairs(list) do
            P.ClampToContent(f, a[1], a[2], a[3], a[4])
        end
    end)
end

function P.ClampToContent(frame, cl, cr, ct, cb)
    if not (frame and frame.SetClampedToScreen) then return end
    if not CanAnchor(frame) then
        DeferClamp(frame, cl, cr, ct, cb)
        return
    end
    pcall(frame.SetClampedToScreen, frame, true)
    if not frame.SetClampRectInsets then return end
    local fl, fr, ft, fb = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    if not cl then cl, cr, ct, cb = P.VisibleBounds(frame) end
    if not (fl and cl) then
        pcall(frame.SetClampRectInsets, frame, 0, 0, 0, 0)
        return
    end
    pcall(frame.SetClampRectInsets, frame, cl - fl, cr - fr, ct - ft, cb - fb)
end

-- Binding -------------------------------------------------------------
--
-- P.Bind(frame, getStore, {
--     point       = "CENTER",      -- frame point that is pinned
--     xKey, yKey  = "xOffset", "yOffset",
--     pointKey    = nil,           -- store key the point is written to
--     relKey      = nil,           -- store key old saves kept their UIParent point in
--     legacyPoint = nil,           -- frame point old saves used when there is no pointKey
--     legacyRel   = nil,           -- UIParent point old saves used (default: same as point)
--     markKey     = "centred",     -- store key that marks a converted save
--     default     = { x, y } or { point, relPoint, x, y } (old form)
-- })

local function Store(frame)
    local b = frame.__rcPos
    if not b then return nil end
    return b.getStore(), b
end

-- Every frame ever bound (weak keys), for the features that act on all
-- of Readycheck's placed frames at once (UI/MapStandDown.lua).
P.bound = setmetatable({}, { __mode = "k" })

function P.Bind(frame, getStore, opts)
    opts = opts or {}
    P.bound[frame] = true
    frame.__rcPos = {
        getStore    = getStore,
        point       = opts.point or "CENTER",
        xKey        = opts.xKey or "xOffset",
        yKey        = opts.yKey or "yOffset",
        pointKey    = opts.pointKey,
        relKey      = opts.relKey,
        legacyPoint = opts.legacyPoint,
        legacyRel   = opts.legacyRel,
        markKey     = opts.markKey or "centred",
        default     = opts.default or { x = 0, y = 0 },
    }
    if not frame.__rcClampHooked and frame.HookScript then
        frame.__rcClampHooked = true
        frame:HookScript("OnSizeChanged", function(f) P.ScheduleClamp(f) end)
        frame:HookScript("OnShow", function(f) P.ScheduleClamp(f) end)
    end
    P.ScheduleClamp(frame)
end

function P.IsBound(frame)
    return frame and frame.__rcPos ~= nil
end

local function Persist(noPersist)
    if not noPersist and RC.SaveConfigurationToProfile then
        RC:SaveConfigurationToProfile()
    end
end

local function Write(s, b, x, y)
    s[b.xKey], s[b.yKey] = x, y
    if b.pointKey then s[b.pointKey] = b.point end
    if b.relKey then s[b.relKey] = "CENTER" end
    s[b.markKey] = true
end

local function IsLegacy(s, b)
    return not s[b.markKey] or (b.pointKey and s[b.pointKey] and s[b.pointKey] ~= b.point)
end

local function LegacyPoints(s, b)
    local oldPoint = (b.pointKey and s[b.pointKey]) or b.legacyPoint or b.point
    -- A converted save whose pinned point has since changed (a layout
    -- addon re-pinning a bar by another corner) holds canonical numbers:
    -- that old point measured from UIParent's CENTRE, as Write puts them.
    if s[b.markKey] then return oldPoint, "CENTER" end
    return oldPoint, (b.relKey and s[b.relKey]) or b.legacyRel or oldPoint
end

-- Coalesced: resizes arrive per animation step, so the recompute waits
-- for the next frame and runs once for the batch. The stored position
-- is re-applied afterwards: a clamp that ran under stale insets (login,
-- mid-resize) has already nudged the frame, and only the store knows
-- where it belongs.
function P.ScheduleClamp(frame)
    if not frame or frame.__rcClampPending then return end
    frame.__rcClampPending = true
    C_Timer.After(0, function()
        frame.__rcClampPending = nil
        P.ClampToContent(frame)
        if frame.__rcDragging then return end
        local s, b = Store(frame)
        if s and type(s[b.xKey]) == "number" and type(s[b.yKey]) == "number"
                and not IsLegacy(s, b) then
            P.Apply(frame, s[b.xKey], s[b.yKey], b.point)
        end
        if frame.__rcOnPlaced then frame.__rcOnPlaced(frame) end
    end)
end

local function ApplyDefault(frame, b)
    local d = b.default
    if d.point then
        return P.ApplyLegacy(frame, d.point, d.relPoint or d.point, d.x, d.y, b.point)
    end
    if P.Apply(frame, d.x or 0, d.y or 0, b.point) then return d.x or 0, d.y or 0 end
end

function P.SaveFrame(frame, noPersist)
    local s, b = Store(frame)
    if not s then return end
    local x, y = P.Capture(frame, b.point)
    if not x then return end
    Write(s, b, x, y)
    Persist(noPersist)
    return x, y
end

-- Places the frame from its store, converting an old-form save in
-- place. Falls back to the default. Returns true when placed.
function P.RestoreFrame(frame)
    local s, b = Store(frame)
    if not s then
        if frame.__rcPos then ApplyDefault(frame, frame.__rcPos) end
        return false
    end
    local x, y = s[b.xKey], s[b.yKey]
    if type(x) ~= "number" or type(y) ~= "number" then
        x, y = ApplyDefault(frame, b)
    elseif IsLegacy(s, b) then
        local oldPoint, oldRel = LegacyPoints(s, b)
        x, y = P.ApplyLegacy(frame, oldPoint, oldRel, x, y, b.point)
    else
        P.ScheduleClamp(frame)
        return P.Apply(frame, x, y, b.point)
    end
    if not x then return false end
    Write(s, b, x, y)
    P.ScheduleClamp(frame)
    return true
end

-- Like RestoreFrame but applies an old-form save as saved, without
-- converting - for frames whose size at creation is a placeholder.
function P.ApplyStored(frame)
    local s, b = Store(frame)
    if not s then
        if frame.__rcPos then ApplyDefault(frame, frame.__rcPos) end
        return false
    end
    local x, y = s[b.xKey], s[b.yKey]
    if type(x) ~= "number" or type(y) ~= "number" then
        local d = b.default
        if not CanAnchor(frame) then return false end
        frame:ClearAllPoints()
        frame:SetPoint(d.point or b.point, UIParent, d.relPoint or d.point or "CENTER", d.x or 0, d.y or 0)
        return true
    elseif IsLegacy(s, b) then
        if not CanAnchor(frame) then return false end
        local oldPoint, oldRel = LegacyPoints(s, b)
        frame:ClearAllPoints()
        frame:SetPoint(oldPoint, UIParent, oldRel, x, y)
        return true
    end
    return P.RestoreFrame(frame)
end

function P.SetFrame(frame, x, y, noPersist)
    local s, b = Store(frame)
    if not s then return end
    Write(s, b, x or 0, y or 0)
    P.Apply(frame, s[b.xKey], s[b.yKey], b.point)
    Persist(noPersist)
end

-- Changes a bound frame's scale without moving its pinned point. A
-- SetPoint offset is in the frame's own units, so a bare SetScale slides
-- the frame towards the screen centre (smaller) or away from it (bigger)
-- by the scale ratio; the saved numbers are rescaled to compensate and
-- re-applied. A frame whose save is still in the old form is just
-- scaled (RestoreFrame converts it where it lands).
function P.SetScaleKeepingPoint(frame, scale, noPersist)
    scale = tonumber(scale) or 1
    local old = frame:GetScale() or 1
    if math.abs(old - scale) < 0.0005 then return false end
    local s, b = Store(frame)
    local x, y = s and s[b.xKey], s and s[b.yKey]
    local canon = s and type(x) == "number" and type(y) == "number" and not IsLegacy(s, b)
    frame:SetScale(scale)
    if canon then
        local r = old / scale
        Write(s, b, x * r, y * r)
        P.Apply(frame, s[b.xKey], s[b.yKey], b.point)
        Persist(noPersist)
    end
    return true
end

function P.ResetFrame(frame, noPersist)
    local s, b = Store(frame)
    if not s then return end
    local x, y = ApplyDefault(frame, b)
    if x then P.SetFrame(frame, x, y, noPersist) end
end

-- Standard drag for a bound frame. `canDrag` is checked at drag start.
function P.MakeMovable(frame, canDrag, onDrop)
    frame:SetMovable(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(f)
        if canDrag and not canDrag(f) then return end
        if not CanAnchor(f) then return end
        f.__rcDragging = true
        f:StartMoving()
    end)
    frame:SetScript("OnDragStop", function(f)
        if not f.__rcDragging then return end
        f.__rcDragging = nil
        f:StopMovingOrSizing()
        P.SaveFrame(f)
        P.RestoreFrame(f)
        if onDrop then onDrop(f) end
    end)
end
