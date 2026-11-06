local C_Timer = C_Timer
local GetTime = GetTime
local math_min, math_max, math_abs, math_sin, math_cos, math_pi = math.min, math.max, math.abs, math.sin, math.cos, math.pi
local ipairs, type, tonumber = ipairs, type, tonumber

------------------------------------------------------------------------
-- Readycheck - UI Framework Animations
-- One tween engine (Tween) driven by tracked C_Timer tickers, never
-- OnUpdate, and everything built on it:
--   RC.UI:FadeFrame / FadeIn / PopIn / PopOut   the window helpers
--   RC.Motion                                   show / hide / highlight
--                                               animations for any frame
--   the mouseover alpha fades for bars
-- Each running tween lives in a slot on its frame (fadeAnimation,
-- popAnimation, motionAnimation) and is cancelled before a new one starts
-- in the same slot, so callers never track tickers themselves.
-- StopAnimations(frame) stops all of them.
--
-- THE GLOBAL SWITCHES (Appearance > Motion, db.motion):
--   enabled  false = every animation here is an instant change
--   speed    divides every duration and delay (2 = twice as fast)
-- Read when an animation starts, never cached. nil reads as on, 1x.
------------------------------------------------------------------------

local RC = _G.Readycheck
if not RC then return end
RC._uif = RC._uif or {}
local _uif = RC._uif

    local STEP = 0.016

    -- t in [0,1] -> eased progress; the overshooting curves pass 1.
    local EASE = {
        linear = function(t) return t end,
        easeOutQuad = function(t) return 1 - (1 - t) * (1 - t) end,
        easeInQuad = function(t) return t * t end,
        easeInOutQuad = function(t)
            if t < 0.5 then return 2 * t * t end
            return 1 - ((-2 * t + 2) ^ 2) / 2
        end,
        easeOutCubic = function(t) return 1 - (1 - t) ^ 3 end,
        easeInOutCubic = function(t)
            if t < 0.5 then return 4 * t * t * t end
            return 1 - ((-2 * t + 2) ^ 3) / 2
        end,
        easeOutBack = function(t)
            local c1 = 1.70158
            return 1 + (c1 + 1) * (t - 1) ^ 3 + c1 * (t - 1) ^ 2
        end,
        easeInBack = function(t)
            local c1 = 1.70158
            return (c1 + 1) * t * t * t - c1 * t * t
        end,
        easeOutBounce = function(t)
            local n1, d1 = 7.5625, 2.75
            if t < 1 / d1 then return n1 * t * t end
            if t < 2 / d1 then t = t - 1.5 / d1 return n1 * t * t + 0.75 end
            if t < 2.5 / d1 then t = t - 2.25 / d1 return n1 * t * t + 0.9375 end
            t = t - 2.625 / d1
            return n1 * t * t + 0.984375
        end,
    }

    local function GetEasingFunction(name)
        return EASE[name] or EASE.easeOutQuad
    end

    ------------------------------------------------------------------
    -- Global switches
    ------------------------------------------------------------------
    local function MotionEnabled()
        local m = RC.db and RC.db.motion
        return not (type(m) == "table" and m.enabled == false)
    end

    local function MotionSpeed()
        local m = RC.db and RC.db.motion
        local s = type(m) == "table" and tonumber(m.speed) or nil
        if not s or s <= 0 then return 1 end
        return math_max(0.25, math_min(4, s))
    end

    -- A duration as it plays now: divided by the speed, 0 when off.
    local function ScaledDuration(d)
        if not MotionEnabled() then return 0 end
        return (tonumber(d) or 0) / MotionSpeed()
    end

    ------------------------------------------------------------------
    -- The engine
    ------------------------------------------------------------------
    local function NewTicker(name, fn)
        if RC.Profiler and RC.Profiler.TrackTicker then
            return RC.Profiler:TrackTicker(name, STEP, fn)
        end
        return C_Timer.NewTicker(STEP, fn)
    end

    local function CancelSlot(frame, slot)
        local t = frame[slot]
        if t then
            t:Cancel()
            frame[slot] = nil
        end
    end

    -- apply(eased, raw) runs every tick and once at 1; onDone after the
    -- last apply. Real time, not tick count, so a slow frame never
    -- stretches a tween. dur <= 0 finishes on the spot.
    local function Tween(frame, slot, name, dur, easing, apply, onDone)
        CancelSlot(frame, slot)
        local ease = type(easing) == "function" and easing or GetEasingFunction(easing)
        if not dur or dur <= 0 then
            apply(1, 1)
            if onDone then onDone() end
            return nil
        end
        local t0 = GetTime()
        local ticker
        ticker = NewTicker(name, function(self)
            local raw = math_min((GetTime() - t0) / dur, 1)
            if raw >= 1 then
                self:Cancel()
                -- onDone may already have started the next tween here
                if frame[slot] == self or frame[slot] == ticker then frame[slot] = nil end
            end
            apply(ease(raw), raw)
            if raw >= 1 and onDone then onDone() end
        end)
        frame[slot] = ticker
        return ticker
    end
    _uif.Tween = Tween

    ------------------------------------------------------------------
    -- Window helpers
    ------------------------------------------------------------------
    -- Animates alpha fromAlpha -> toAlpha (defaults: current -> 1, 0.2s,
    -- easeOutQuad). Shows a frame fading in from 0, hides one that faded
    -- to 0. Cancels any fade already running on frame.
    function RC.UI:FadeFrame(frame, fromAlpha, toAlpha, duration, easing, onComplete)
        if not frame then return end
        duration = duration or 0.2
        fromAlpha = fromAlpha or frame:GetAlpha()
        toAlpha = toAlpha or 1

        frame:SetAlpha(fromAlpha)
        if fromAlpha == 0 and toAlpha > 0 then
            frame:Show()
        end

        Tween(frame, "fadeAnimation", "UIAnim:Fade", ScaledDuration(duration), easing or "easeOutQuad",
            function(e) frame:SetAlpha(fromAlpha + (toAlpha - fromAlpha) * e) end,
            function()
                frame:SetAlpha(toAlpha)
                if toAlpha == 0 then frame:Hide() end
                if onComplete then onComplete() end
            end)
    end

    function RC.UI:FadeIn(frame, duration, onComplete)
        self:FadeFrame(frame, 0, 1, duration or 0.2, "easeOutQuad", onComplete)
    end

    -- Shows frame and fades alpha 0->1 (frame.popAnimation).
    -- ALPHA ONLY, deliberately: a frame's anchor offsets are in its own
    -- scaled units, so scaling a window that is not dead centre drags it
    -- toward its anchor while it animates and re-rasterises its text each
    -- tick (the raid profile picker read as flashing). It also used to
    -- force SetScale(1), stomping a user-set scale.
    function RC.UI:PopIn(frame, duration)
        if not frame then return end
        frame:SetAlpha(0)
        frame:Show()
        Tween(frame, "popAnimation", "UIAnim:PopIn", ScaledDuration(duration or 0.15), "easeOutCubic",
            function(e) frame:SetAlpha(e) end,
            function() frame:SetAlpha(1) end)
    end

    -- Inverse of PopIn: alpha 1->0, then hidden with alpha back at 1 so
    -- it is ready to PopIn again.
    function RC.UI:PopOut(frame, duration, onComplete)
        if not frame then return end
        Tween(frame, "popAnimation", "UIAnim:PopOut", ScaledDuration(duration or 0.1), "easeInOutQuad",
            function(e) frame:SetAlpha(1 - e) end,
            function()
                frame:Hide()
                frame:SetAlpha(1)
                if onComplete then onComplete() end
            end)
    end

    -- Cancels every tween on frame (fade, pop, Motion - the last put back
    -- at rest). Call before hiding or reusing a frame.
    function RC.UI:StopAnimations(frame)
        if not frame then return end
        CancelSlot(frame, "fadeAnimation")
        CancelSlot(frame, "popAnimation")
        if RC.Motion then RC.Motion.Stop(frame) end
    end

    ------------------------------------------------------------------
    -- MOTION - show, hide and highlight animations for any frame
    ------------------------------------------------------------------
    --   RC.Motion.Play(frame, spec, "in"|"out"|"update", onDone) -> bool
    --   RC.Motion.Show(frame, spec, onDone)  /  Hide(frame, spec, onDone)
    --   RC.Motion.Stop(frame)       stop now, frame put back at rest
    --   RC.Motion.StopTree(root)    Stop on root and everything under it
    --   RC.Motion.IsPlaying(frame)
    --   RC.Motion.Normalize(spec, defaults)  a full copy, gaps filled
    --   RC.Motion.Enabled() / Speed() / Duration(d)   the global switches
    --   RC.Motion.StyleFromLegacy(v)  a stored animationType -> style id
    --
    -- THE SPEC (the animation setting shape every feature saves):
    --   { style = "none"|"fade"|"slide"|"pop"|"pulse"|"bounce"|"flash",
    --     duration = s, delay = s, easing = an EASE key,
    --     dir = "up"|"down"|"left"|"right"  side it enters from / leaves to
    --     distance = px (slide, bounce), loop = true (pulse, flash repeat) }
    --
    -- AT REST, EXACTLY: a play captures the frame's anchors, alpha and
    -- scale and puts all three back when it ends (finished, stopped or
    -- replaced); an "out" hides first so the next Show starts at rest. A
    -- play replacing one in flight keeps the first rest. onDone runs only
    -- when a play finishes by itself (or at once when it cannot animate).
    -- A protected frame in combat gets the alpha part only: no anchors,
    -- scale, Show or Hide; an "out" ends at alpha 0, still shown.
    --
    -- PROTECTED means the client calls the frame protected (a bar
    -- holding secure buttons is, implicitly) or the caller said so with
    -- RC.Motion.SetProtected(frame). A play already running on one when
    -- combat starts is finished on PLAYER_REGEN_DISABLED, while the client
    -- still allows it: back on its anchor and scale, shown or hidden as
    -- the play would have left it, onDone called. A play started during
    -- that event ends at once. If the lock still lands mid-play, the ticks
    -- write alpha only and the anchors, scale and a pending hide are put
    -- back when combat ends.
    local Motion = {}
    RC.Motion = Motion

    Motion.STYLES = {
        { id = "none",   label = RCL["None"] },
        { id = "fade",   label = RCL["Fade"] },
        { id = "slide",  label = RCL["Slide"] },
        { id = "pop",    label = RCL["Pop"] },
        { id = "pulse",  label = RCL["Pulse"] },
        { id = "bounce", label = RCL["Bounce"] },
        { id = "flash",  label = RCL["Flash"] },
    }
    Motion.EASINGS = {
        { id = "linear",        label = RCL["Steady"] },
        { id = "easeOutQuad",   label = RCL["Smooth"] },
        { id = "easeOutCubic",  label = RCL["Quick start"] },
        { id = "easeInOutQuad", label = RCL["Smooth both ends"] },
        { id = "easeInQuad",    label = RCL["Speed up"] },
        { id = "easeOutBack",   label = RCL["Overshoot"] },
        { id = "easeOutBounce", label = RCL["Bounce"] },
    }
    Motion.DIRS = {
        { id = "up",    label = RCL["Above"] },
        { id = "down",  label = RCL["Below"] },
        { id = "left",  label = RCL["Left"] },
        { id = "right", label = RCL["Right"] },
    }
    -- styles that use direction + distance, and those that can repeat
    Motion.MOVES = { slide = true, bounce = true }
    Motion.LOOPS = { pulse = true, flash = true }
    Motion.DEFAULT = { style = "fade", duration = 0.3, delay = 0, easing = "easeOutQuad",
                       dir = "up", distance = 20, loop = false }
    Motion.EASE = EASE

    local VALID_STYLE = {}
    for _, s in ipairs(Motion.STYLES) do VALID_STYLE[s.id] = true end
    local DIR_VEC = { up = { 0, 1 }, down = { 0, -1 }, left = { -1, 0 }, right = { 1, 0 } }

    Motion.Enabled = MotionEnabled
    Motion.Speed = MotionSpeed
    Motion.Duration = ScaledDuration

    local function Pick(key, spec, defaults)
        local v = spec and spec[key]
        if v == nil and defaults then v = defaults[key] end
        if v == nil then v = Motion.DEFAULT[key] end
        return v
    end

    function Motion.Normalize(spec, defaults)
        spec = type(spec) == "table" and spec or nil
        defaults = type(defaults) == "table" and defaults or nil
        local out = {}
        local st = Pick("style", spec, defaults)
        out.style = VALID_STYLE[st] and st or Motion.DEFAULT.style
        out.duration = math_max(0, tonumber(Pick("duration", spec, defaults)) or Motion.DEFAULT.duration)
        out.delay = math_max(0, tonumber(Pick("delay", spec, defaults)) or 0)
        local ez = Pick("easing", spec, defaults)
        out.easing = EASE[ez or ""] and ez or Motion.DEFAULT.easing
        local dir = Pick("dir", spec, defaults)
        out.dir = DIR_VEC[dir or ""] and dir or Motion.DEFAULT.dir
        out.distance = tonumber(Pick("distance", spec, defaults)) or Motion.DEFAULT.distance
        out.loop = Pick("loop", spec, defaults) and true or false
        return out
    end

    -- Stored animationType values: nil / "" mean the global default
    -- (fade), "none" is none, a style id is that style, anything retired
    -- reads as fade.
    function Motion.StyleFromLegacy(v)
        if v == nil or v == "" then return "fade" end
        if VALID_STYLE[v] then return v end
        return "fade"
    end

    -- anchor point -> vector to the frame's centre, in its own units
    local CENTRE = {
        CENTER = { 0, 0 }, TOP = { 0, -0.5 }, BOTTOM = { 0, 0.5 },
        LEFT = { 0.5, 0 }, RIGHT = { -0.5, 0 },
        TOPLEFT = { 0.5, -0.5 }, TOPRIGHT = { -0.5, -0.5 },
        BOTTOMLEFT = { 0.5, 0.5 }, BOTTOMRIGHT = { -0.5, 0.5 },
    }

    local function Capture(frame)
        local rest = { alpha = frame:GetAlpha() or 1, scale = frame:GetScale() or 1, points = {} }
        local n = frame.GetNumPoints and frame:GetNumPoints() or 0
        for i = 1, n do
            local p, rel, rp, x, y = frame:GetPoint(i)
            if p then rest.points[#rest.points + 1] = { p, rel, rp or p, x or 0, y or 0 } end
        end
        return rest
    end

    -- A frame hung from ONE point keeps its centre still while it scales
    -- (a pop grows from the middle); one stretched between several points
    -- slides and scales as it is.
    local function Pose(frame, rest, a, s, dx, dy, moves)
        frame:SetAlpha(math_max(0, math_min(1, rest.alpha * a)))
        if not moves then return end
        if s ~= 1 or frame:GetScale() ~= rest.scale then
            frame:SetScale(math_max(0.01, rest.scale * s))
        end
        local pts = rest.points
        if #pts == 0 then return end
        frame:ClearAllPoints()
        if #pts == 1 then
            local p = pts[1]
            local c = CENTRE[p[1]] or CENTRE.CENTER
            local cx, cy = c[1] * (frame:GetWidth() or 0), c[2] * (frame:GetHeight() or 0)
            frame:SetPoint(p[1], p[2], p[3], (p[4] + dx + cx) / s - cx, (p[5] + dy + cy) / s - cy)
        else
            for _, p in ipairs(pts) do
                frame:SetPoint(p[1], p[2], p[3], (p[4] + dx) / s, (p[5] + dy) / s)
            end
        end
    end

    local function RestoreGeometry(frame, rest)
        frame:SetScale(rest.scale)
        if #rest.points > 0 then
            frame:ClearAllPoints()
            for _, p in ipairs(rest.points) do frame:SetPoint(p[1], p[2], p[3], p[4], p[5]) end
        end
    end

    local function Restore(frame, rest, alphaOnly)
        frame:SetAlpha(rest.alpha)
        if not alphaOnly then RestoreGeometry(frame, rest) end
    end

    -- COMBAT. running: frames with a play (weak, pruned as it goes).
    -- owed: frame -> { rest, how } whose anchors, scale or hide the lock
    -- kept back, put right on PLAYER_REGEN_ENABLED. lockPending: inside
    -- PLAYER_REGEN_DISABLED, until the lock itself starts.
    local running = setmetatable({}, { __mode = "k" })
    local owed = setmetatable({}, { __mode = "k" })
    local lockPending = false

    -- looked up at call time: Interface 16001 may not have it
    local function InLockdown()
        local f = _G.InCombatLockdown
        return f ~= nil and f() and true or false
    end

    -- the client's word (a frame holding secure buttons is implicitly
    -- protected) or the caller's flag; cheap enough for every tick
    local function Secure(frame)
        if frame._rcMotionProtected then return true end
        return (frame.IsProtected and frame:IsProtected()) and true or false
    end

    -- the first rest owed is the true one; a later ending only updates
    -- whether the frame still has to be hidden
    local function Owe(frame, rest, how)
        local d = owed[frame]
        if d then d.how = how else owed[frame] = { rest = rest, how = how } end
    end

    -- token changes on every new play or stop, so a delay or a loop that
    -- outlived its play does nothing
    local function Halt(frame, keepState)
        local st = frame._rcMotion
        if not st then return nil end
        st.token = st.token + 1
        CancelSlot(frame, "motionAnimation")
        if not keepState then
            local held = not st.alphaOnly and st.secure and InLockdown()
            if held then Owe(frame, st.rest, nil) end
            Restore(frame, st.rest, st.alphaOnly or held)
            frame._rcMotion = nil
        end
        return st
    end

    -- Caller flag for a frame the client does not call protected but that
    -- must be treated as one (on = false clears it).
    function Motion.SetProtected(frame, on)
        if frame then frame._rcMotionProtected = (on ~= false) or nil end
    end

    -- PLAYER_REGEN_DISABLED: every play on a protected frame ends now.
    local function FinishProtected()
        local list = {}
        for f in pairs(running) do
            local st = f._rcMotion
            if not st then
                running[f] = nil
            elseif st.finish and not st.alphaOnly and (st.secure or Secure(f)) then
                list[#list + 1] = f
            end
        end
        for _, f in ipairs(list) do
            local st = f._rcMotion
            if st and st.finish then st.finish() end
        end
    end

    -- PLAYER_REGEN_ENABLED: what the lock kept back.
    local function SettleOwed()
        if InLockdown() then return end
        local list = {}
        for f in pairs(owed) do list[#list + 1] = f end
        for _, f in ipairs(list) do
            local d = owed[f]
            owed[f] = nil
            if d then
                RestoreGeometry(f, d.rest)
                if d.how == "out" and not f._rcMotion then
                    f:Hide()
                    f:SetAlpha(d.rest.alpha)
                end
            end
        end
    end

    if CreateFrame then
        local ev = CreateFrame("Frame")
        if ev and ev.RegisterEvent and ev.SetScript then
            ev:RegisterEvent("PLAYER_REGEN_DISABLED")
            ev:RegisterEvent("PLAYER_REGEN_ENABLED")
            ev:SetScript("OnEvent", function(_, event)
                if event == "PLAYER_REGEN_DISABLED" then
                    lockPending = true
                    FinishProtected()
                    -- the lock is on by the next frame
                    if C_Timer and C_Timer.After then
                        C_Timer.After(0, function() lockPending = false end)
                    end
                else
                    lockPending = false
                    SettleOwed()
                end
            end)
        end
    end

    function Motion.Stop(frame)
        if frame then Halt(frame) end
    end

    function Motion.IsPlaying(frame)
        return frame ~= nil and frame._rcMotion ~= nil
    end

    function Motion.StopTree(root, depth)
        depth = depth or 0
        if not root or depth > 10 then return end
        if root._rcMotion then Halt(root) end
        if root.GetChildren then
            for _, c in ipairs({ root:GetChildren() }) do Motion.StopTree(c, depth + 1) end
        end
    end

    -- THE CURVES: each returns alpha, scale, dx, dy for raw time t and
    -- eased e; D is the distance, (vx, vy) the side it enters from.
    local function Bump(t) return math_sin(math_pi * t) end
    local function Blink(t) return 1 - 0.75 * (0.5 - 0.5 * math_cos(4 * math_pi * t)) end

    local CURVES = {
        fade = {
            ["in"]  = function(t, e) return e, 1, 0, 0 end,
            ["out"] = function(t, e) return 1 - e, 1, 0, 0 end,
            update  = function(t) return 1 - 0.6 * Bump(t), 1, 0, 0 end,
        },
        slide = {
            ["in"]  = function(t, e, D, vx, vy) local k = (1 - e) * D return math_min(1, e * 1.5), 1, vx * k, vy * k end,
            ["out"] = function(t, e, D, vx, vy) local k = e * D return 1 - e, 1, vx * k, vy * k end,
            update  = function(t, e, D, vx, vy) local k = Bump(t) * D * 0.3 return 1, 1, vx * k, vy * k end,
        },
        pop = {
            ["in"]  = function(t, e) return math_min(1, t * 3), 0.6 + 0.4 * e, 0, 0 end,
            ["out"] = function(t, e) return 1 - e, 1 - 0.4 * e, 0, 0 end,
            update  = function(t) return 1, 1 + 0.15 * Bump(t), 0, 0 end,
        },
        pulse = {
            ["in"]  = function(t) return math_min(1, t * 4), 1 + 0.12 * Bump(t), 0, 0 end,
            ["out"] = function(t, e) return 1 - e, 1 + 0.12 * e, 0, 0 end,
            update  = function(t) return 1, 1 + 0.12 * Bump(t), 0, 0 end,
            loop    = function(t) return 1, 1 + 0.12 * Bump(t), 0, 0 end,
        },
        bounce = {
            ["in"]  = function(t, e, D, vx, vy) local k = (1 - EASE.easeOutBounce(t)) * D return math_min(1, t * 4), 1, vx * k, vy * k end,
            ["out"] = function(t, e, D, vx, vy) local k = EASE.easeInBack(t) * D return 1 - t, 1, vx * k, vy * k end,
            update  = function(t, e, D, vx, vy) local k = math_abs(math_sin(math_pi * 2 * t)) * (1 - t) * D * 0.4 return 1, 1, vx * k, vy * k end,
        },
        flash = {
            ["in"]  = function(t) return Blink(t), 1, 0, 0 end,
            ["out"] = function(t) return Blink(t) * (1 - t), 1, 0, 0 end,
            update  = function(t) return Blink(t), 1, 0, 0 end,
            loop    = function(t) return Blink(t), 1, 0, 0 end,
        },
    }
    -- these shape their own timing; the easing choice does not apply
    local OWN_TIMING = { bounce = true, flash = true, pulse = true }

    function Motion.Play(frame, spec, how, onDone)
        if not frame then return false end
        how = (how == "out" or how == "update") and how or "in"
        local secure = Secure(frame)
        local alphaOnly = secure and InLockdown()
        local s = Motion.Normalize(spec)

        local prev = Halt(frame, true)
        -- anchors the lock kept back are the true rest
        local debt = owed[frame]
        local rest = prev and prev.rest or (debt and debt.rest) or Capture(frame)
        if debt then
            debt.how = nil -- this play decides whether it is shown now
            if not alphaOnly then owed[frame] = nil end
        end
        if alphaOnly and rest.alpha < 0.01 then rest.alpha = 1 end
        -- an "out" leaves from wherever the frame is now (a half-done
        -- entrance fades from its current alpha, not from full)
        local startA = 1
        if how == "out" and rest.alpha > 0 then
            startA = math_max(0, math_min(1, (frame:GetAlpha() or rest.alpha) / rest.alpha))
        end
        -- a replaced play may have left the frame moved or scaled (in
        -- combat that waits for the end of it)
        if (prev and not prev.alphaOnly) or debt then
            if alphaOnly then Owe(frame, rest, nil) else RestoreGeometry(frame, rest) end
        end

        -- a protected frame the lock reached mid-play: alpha only
        local function Held() return secure and not alphaOnly and InLockdown() end

        local function EndNow()
            frame._rcMotion = nil
            if alphaOnly then
                if how == "out" then frame:SetAlpha(0) else Restore(frame, rest, true) end
            elseif Held() then
                Owe(frame, rest, how)
                if how == "out" then frame:SetAlpha(0) else Restore(frame, rest, true) end
                if RC.DebugPrint then RC:DebugPrint("Motion: combat locked mid-play on a protected frame; its place is put back after combat", "animation") end
            else
                if how == "out" then frame:Hide() elseif how == "in" then frame:Show() end
                Restore(frame, rest)
            end
            if onDone then onDone() end
        end

        local dur = ScaledDuration(s.duration)
        -- PLAYER_REGEN_DISABLED is the last moment a protected frame can
        -- move: no time to animate, end it now
        if secure and not alphaOnly and lockPending then dur = 0 end
        local curve = CURVES[s.style]
        if s.style == "none" or not curve or dur <= 0 then
            EndNow()
            return false
        end
        local shown = frame:IsShown()
        if (how ~= "in" and not shown) or (alphaOnly and how == "in" and not shown) then
            frame._rcMotion = nil
            if not alphaOnly then Restore(frame, rest) end
            if onDone then onDone() end
            return false
        end

        local st = { rest = rest, token = (prev and prev.token or 0) + 1, how = how, alphaOnly = alphaOnly, secure = secure }
        frame._rcMotion = st
        running[frame] = true
        local token = st.token
        local vec = DIR_VEC[s.dir]
        local D = s.distance
        local moves = not alphaOnly and (Motion.MOVES[s.style] or s.style == "pop" or s.style == "pulse")
        local ease = OWN_TIMING[s.style] and "linear" or s.easing
        local fn = curve[how]
        local looping = s.loop and Motion.LOOPS[s.style] and how ~= "out"

        local function Live() return frame._rcMotion == st and st.token == token end

        local function Apply(e, raw)
            local a, sc, dx, dy = fn(raw, e, D, vec[1], vec[2])
            Pose(frame, rest, a * startA, sc, dx, dy, moves and not Held())
        end

        -- combat is starting: the end state now. An entrance its owner
        -- hid on the way (a bar hidden in combat) stays hidden.
        st.finish = function()
            if not Live() then return end
            st.token = st.token + 1
            CancelSlot(frame, "motionAnimation")
            if how == "in" and not frame:IsShown() then
                frame._rcMotion = nil
                Restore(frame, rest)
                if onDone then onDone() end
            else
                EndNow()
            end
        end

        local function Done()
            if not Live() then return end
            EndNow()
        end

        local Cycle
        -- One pass of the loop curve after another while the frame is on
        -- screen; a hidden frame ends the loop at rest.
        Cycle = function()
            if not Live() then return end
            local cd = ScaledDuration(s.duration)
            if cd <= 0 or not frame:IsVisible() then
                frame._rcMotion = nil
                local held = Held()
                if held then Owe(frame, rest, nil) end
                Restore(frame, rest, alphaOnly or held)
                return
            end
            local lf = curve.loop or fn
            Tween(frame, "motionAnimation", "UIAnim:Motion", cd, "linear", function(_, raw)
                local a, sc, dx, dy = lf(raw, raw, D, vec[1], vec[2])
                Pose(frame, rest, a, sc, dx, dy, moves and not Held())
            end, Cycle)
        end

        local function Begin()
            if not Live() then return end
            if how == "in" and not alphaOnly and not Held() then frame:Show() end
            Tween(frame, "motionAnimation", "UIAnim:Motion", dur, ease, Apply, looping and Cycle or Done)
        end

        -- the start pose at once, so a delayed "in" is not seen at rest
        if how == "in" then
            Apply(GetEasingFunction(ease)(0), 0)
            if not alphaOnly then frame:Show() end
        end
        local delay = ScaledDuration(s.delay)
        if delay > 0 then
            C_Timer.After(delay, Begin)
        else
            Begin()
        end
        return true
    end

    function Motion.Show(frame, spec, onDone) return Motion.Play(frame, spec, "in", onDone) end
    function Motion.Hide(frame, spec, onDone) return Motion.Play(frame, spec, "out", onDone) end

------------------------------------------------------------------------
-- Mouseover alpha-fade helpers
-- Generic "dim when the mouse is away, brighten on hover" machinery used
-- by the trinket toggle button (Readycheck_Gear) and by the consumables,
-- potions and weapons bars (Readycheck_Consumables). They live in core
-- rather than in either companion addon because disabling one addon must
-- not strip fade from the other's frames.
-- Attached to RC (not RC.UI) - existing call sites use RC:AttachMouseoverFade
-- etc., so the names and the table they hang off must not change.
------------------------------------------------------------------------

    local DEFAULT_FADE_ALPHA = 0.15
    local DEFAULT_FADE_IN, DEFAULT_FADE_OUT = 0.18, 0.30

    -- A settings table may carry its own fade lengths (fadeIn, fadeOut,
    -- seconds); nil keeps the defaults above.
    local function FadeInTime(s) return tonumber(s.fadeIn) or DEFAULT_FADE_IN end
    local function FadeOutTime(s) return tonumber(s.fadeOut) or DEFAULT_FADE_OUT end

    function RC:_FadeFrameAlpha(frame, target, duration)
        if not frame then return end
        local startAlpha = frame:GetAlpha() or 1
        if math_abs(startAlpha - target) < 0.005 then
            CancelSlot(frame, "_mouseoverFadeTicker")
            frame:SetAlpha(target)
            return
        end
        Tween(frame, "_mouseoverFadeTicker", "TrinketSwap:MouseoverFade", ScaledDuration(duration or 0.2), "linear",
            function(e) frame:SetAlpha(startAlpha + (target - startAlpha) * e) end)
    end

    function RC:AttachMouseoverFade(frame, getSettings)
        if not frame or not getSettings then return end
        frame:HookScript("OnEnter", function(self)
            local s = getSettings()
            if s and s.enabled then
                RC:_FadeFrameAlpha(self, 1, FadeInTime(s))
            end
        end)
        frame:HookScript("OnLeave", function(self)
            local s = getSettings()
            if s and s.enabled then
                RC:_FadeFrameAlpha(self, s.alpha or DEFAULT_FADE_ALPHA, FadeOutTime(s))
            end
        end)
    end

    -- Container bars (potions/weapons/consumables helper) are covered
    -- by child buttons that swallow OnEnter/OnLeave, so hover has to
    -- be polled. The poll exists only while the frame is visible AND
    -- fade is enabled - it is cancelled the instant either stops being
    -- true, so a disabled fade costs nothing (the old per-frame
    -- OnUpdate hook ran forever on every bar).
    local function ContainerFadeTick(frame)
        local getSettings = frame._containerFadeGetSettings
        local s = getSettings and getSettings()
        if not (s and s.enabled) or not frame:IsVisible() then
            RC:StopContainerMouseoverFadePoll(frame)
            return
        end

        local isOver = frame:IsMouseOver()
        if frame._containerFadeOver == nil then
            frame._containerFadeOver = isOver
            frame:SetAlpha(isOver and 1 or (s.alpha or DEFAULT_FADE_ALPHA))
        elseif isOver and not frame._containerFadeOver then
            frame._containerFadeOver = true
            RC:_FadeFrameAlpha(frame, 1, FadeInTime(s))
        elseif not isOver and frame._containerFadeOver then
            frame._containerFadeOver = false
            RC:_FadeFrameAlpha(frame, s.alpha or DEFAULT_FADE_ALPHA, FadeOutTime(s))
        end
    end

    function RC:StopContainerMouseoverFadePoll(frame)
        if frame and frame._containerFadePoll then
            frame._containerFadePoll:Cancel()
            frame._containerFadePoll = nil
        end
    end

    -- Starts the poll if it should be running and is not, stops it if
    -- it should not be. Safe to call repeatedly (options changes,
    -- OnShow, bar rebuilds).
    function RC:RefreshContainerMouseoverFadePoll(frame)
        if not frame or not frame._containerFadeGetSettings then return end
        local s = frame._containerFadeGetSettings()
        if not (s and s.enabled) or not frame:IsVisible() then
            self:StopContainerMouseoverFadePoll(frame)
            return
        end
        if frame._containerFadePoll then return end
        frame._containerFadeOver = nil
        local tickFn = function() ContainerFadeTick(frame) end
        if RC.Profiler and RC.Profiler.TrackTicker then
            frame._containerFadePoll = RC.Profiler:TrackTicker("TrinketSwap:ContainerFade", 0.2, tickFn)
        else
            frame._containerFadePoll = C_Timer.NewTicker(0.2, tickFn)
        end
    end

    function RC:AttachContainerMouseoverFade(frame, getSettings)
        if not frame or not getSettings then return end
        frame._containerFadeOver = nil
        frame._containerFadeGetSettings = getSettings
        if not frame._containerFadeHooked then
            frame._containerFadeHooked = true
            frame:HookScript("OnShow", function(self)
                RC:RefreshContainerMouseoverFadePoll(self)
            end)
            frame:HookScript("OnHide", function(self)
                RC:StopContainerMouseoverFadePoll(self)
            end)
        end
        self:RefreshContainerMouseoverFadePoll(frame)
    end

    function RC:ApplyMouseoverFade(frame, getSettings)
        if not frame then return end
        local s = getSettings and getSettings()
        if s and s.enabled then
            if frame:IsMouseOver() then
                frame:SetAlpha(1)
            else
                frame:SetAlpha(s.alpha or DEFAULT_FADE_ALPHA)
            end
        else
            CancelSlot(frame, "_mouseoverFadeTicker")
            frame:SetAlpha(1)
        end
        -- Container bars route their settings changes through here,
        -- so this is also where the hover poll is re-evaluated.
        if frame._containerFadeGetSettings then
            frame._containerFadeOver = nil
            self:RefreshContainerMouseoverFadePoll(frame)
        end
    end
