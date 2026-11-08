local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local math_floor, math_max, math_min, math_ceil, math_abs = math.floor, math.max, math.min, math.ceil, math.abs
local CreateFrame = CreateFrame
local C_Timer = C_Timer

------------------------------------------------------------------------
-- Readycheck - UI Framework: the preview strip
-- A live sample of what the settings page on screen sets up, shown as a
-- short band pinned under the page's title in the /rc window, the full
-- width of the page. The page's title and the strip stay put while the
-- page scrolls under them; the window never changes size for it.
--
-- THE SAMPLE IS SHOWN AT ITS REAL SIZE: the canvas is scaled so one
-- canvas unit on screen is one unit of the live frame in game (the
-- game's UI scale over the /rc window's own scale), and the strip grows
-- to fit it (at least 56 px). Only when the sample is taller than the
-- strip's cap (Compact 15% / Normal 22% / Tall 34% of the window's page
-- height; Normal unless picked - Zac 2026-11-02 wanted them much smaller) or wider than the strip is it scaled
-- down, evenly, and the control line says "Scaled to 72%". Folded, the
-- strip is a slim 18 px bar.
--
-- A PAGE DECLARES ONE while it builds (after its ClearSidebarContent):
--   local P = RC.UI:DeclarePreview({
--       key = "reminders.popup",     -- unique; one canvas per key, kept all session
--       title = "Reminder popup",
--       width = 300, height = 60,    -- the canvas at scale 1, wide and short (scaled to fit the strip)
--       build = function(canvas, P) end,   -- ONCE per key: make the samples
--       update = function(canvas, P) end,  -- read the settings, restyle in place
--       replay = function(canvas, P) end,  -- optional: play the animations
--       modes = { { id = "one", label = "One icon" }, ... },  -- optional; P.mode
--       modesLabel = "Show",
--   })
-- It returns P, or nil when the build is not the one on screen (the
-- settings search builds every page unseen). A page that declares
-- nothing has no strip.
--
-- The controls run along the strip's top edge so the sample keeps the
-- middle: the mode pills on the left (squeezed, then a small menu when
-- they do not fit), and on the right the background swatches, Replay,
-- the strip's height and the fold.
--
-- EVERY CHANGE SHOWS UP ON ITS OWN: every framework control raises
-- RC.UI:NotifySettingChanged after its handler (a slider on every step
-- of a drag); the strip runs the current update once on the next frame,
-- however many changes landed. A page rebuild re-declares the same key,
-- which is one coalesced update too; build never runs twice for a key.
--
-- P (per key, survives rebuilds): P.key, P.mode, P.bg ("dark" | "light"
-- | "checker"), P.scale, P.store (the page's own table), P.Update(),
-- P.Replay().
--
-- LAY THE SAMPLE OUT EXACTLY AS IT SITS IN GAME (same pieces, same
-- places, same size) and make the canvas its box:
--   P.boxW, P.boxH   the sample box in canvas units at scale 1 (set
--                    before every update; nil in the very first build)
--   P.realScale      the canvas scale that shows the sample at its real
--                    size; P.fit = P.scale / P.realScale (1 = real size)
--   P.Resize(w, h)   the canvas wants another size (the scale follows at
--                    once; kept for the key across rebuilds)
--   P.Row(parts, o)  places frames left to right, centred in the canvas,
--                    o.gap apart (default 10), at o.y; parts may be
--                    { frame =, w =, h =, dy = } to give a size. With
--                    o.fit the canvas becomes the row's box plus o.pad
--                    (default 4), at least o.minW x o.minH. Hidden parts
--                    are skipped; a part mid-animation is stopped before
--                    it moves. Returns the row's width and height.
--   P.Measure(root)  the box of everything visible under root: its centre
--                    relative to root's centre, and its size, in root's
--                    units (nil while the game has not placed it yet; the
--                    strip then updates once more on the next frame).
--                    For samples whose extent the settings decide.
------------------------------------------------------------------------

local RC = _G.Readycheck
if not RC then return end
RC._uif = RC._uif or {}
local _uif = RC._uif
local BASE, FLAT, CreateProfessionalFontString = _uif.BASE, _uif.FLAT, _uif.CreateProfessionalFontString

    local Preview = {}
    RC.Preview = Preview
    Preview.stats = { updates = 0, builds = 0, replays = 0 }

    -- the cap on the strip's height, a share of the window's page height
    local CAPS = { compact = 0.15, normal = 0.22, tall = 0.34 }
    local HEIGHT_ORDER = { "compact", "normal", "tall" }
    local HEIGHT_NAME = { compact = "Compact", normal = "Normal", tall = "Tall" }
    local LEGACY_HEIGHT = { small = "compact" }   -- the fixed-height era's names
    local MIN_H = 56                -- the strip is never shorter
    local SLIM_H = 18               -- folded
    local EDGE = 4                  -- strip edge -> its contents
    local BAR_Y, BTN_H = 3, 16      -- the control line along the top edge
    local VIEW_Y = BAR_Y + BTN_H + 3
    local ICON = 16                 -- Replay / height / fold
    local SW = 11                   -- a background swatch
    local GAP = 3
    local RIGHT_W = 3 * ICON + 2 * 2 + 8 + 3 * SW + 2 * GAP
    local CELL = 8
    local INSET = 18                -- the page's cards sit 18 in
    local ARROW = "Interface\\AddOns\\Readycheck\\Media\\arrow"

    local window, host, realChild, pane, bar, view, label, slim, scaleLabel
    local foldBtn, foldArrow, heightBtn, replayBtn, playTex, upTex, downTex
    local swatches, rightItems = {}, {}
    local entries = {}
    local current
    local declared
    local token, endPending, pending = 0, false, false
    local laying = false
    local complained = {}
    -- the page's title, pinned above the strip, and how far the rest of
    -- the page moved up to fill its room
    local pageHeaders = {}
    local pinnedHeader, pinShift, stripY = nil, 0, 8

    local function Clamp(v, lo, hi) return math_max(lo, math_min(hi, v)) end

    -- The canvas scale that shows a sample at its real size: the live
    -- frame's effective scale in game (UIParent's) over the box's (the
    -- /rc window's, its own scale setting included).
    local function RealScale()
        local us = UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1
        local vs = view and view.GetEffectiveScale and view:GetEffectiveScale() or 1
        if not (us and us > 0 and vs and vs > 0) then return 1 end
        return us / vs
    end
    Preview.RealScale = RealScale

    -- Real size, or evenly smaller when the box is too small for it.
    local function FitScale(cw, ch, bw, bh)
        local r = RealScale()
        return Clamp(math_min(r, bw / math_max(1, cw), bh / math_max(1, ch)), 0.05, r), r
    end

    local function FitCanvas(e)
        local bw, bh = e.P.boxW, e.P.boxH
        if not (bw and e.canvas and e.spec) then return end
        local s, r = FitScale(e.spec.width or 260, e.spec.height or 140, bw, bh)
        e.canvas:SetScale(s)
        e.P.scale, e.P.realScale = s, r
        e.P.fit = s / r
        if scaleLabel then
            if e.P.fit < 0.995 then
                scaleLabel:SetText(string.format(RCL["Scaled to %d%%"], math_floor(e.P.fit * 100 + 0.5)))
                scaleLabel:Show()
            else
                scaleLabel:SetText("")
                scaleLabel:Hide()
            end
        end
    end

    -- Fold, background, height and the mode per key; window state, never
    -- shared. The column-era sample size goes quietly.
    local function Store()
        local db = RC.db
        if not db then return { modes = {} } end
        db.previewPane = type(db.previewPane) == "table" and db.previewPane or {}
        local s = db.previewPane
        s.modes = type(s.modes) == "table" and s.modes or {}
        s.size, s.width = nil, nil
        return s
    end

    local function HeightId()
        local s = Store()
        local id = s.height
        if LEGACY_HEIGHT[id] then id = LEGACY_HEIGHT[id] s.height = id end
        return CAPS[id] and id or "normal"
    end

    -- the window's page height (the strip and the page share it)
    local function ContentHeight()
        local h = host and host.ContentHeight and host.ContentHeight()
        if not (h and h > 0) then h = (window and window:GetHeight() or 600) - 60 end
        return h
    end

    local function CapHeight(id)
        return math_max(MIN_H, math_floor(ContentHeight() * CAPS[id or HeightId()]))
    end

    local function Fail(e, what, err)
        local k = tostring(e and e.key) .. "/" .. what
        if complained[k] then return end
        complained[k] = true
        RC:DebugPrint("Preview '" .. tostring(e and e.key) .. "' " .. what .. " failed: " .. tostring(err), "config")
    end

    -- The samples are the features' own frames, and their constructors
    -- often put them in MEDIUM or HIGH strata (or at a fixed frame level)
    -- for the live screen. The strip sits in the window's strata (DIALOG),
    -- so such a piece drew underneath the window's own background: built,
    -- but invisible. After every build, update and replay, every frame
    -- under the canvas whose strata is below the canvas's is lifted into
    -- it, and a piece whose levels sit at or under the canvas's is moved
    -- up as a whole, so the pieces keep their order among themselves.
    local STRATA_RANK = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5,
        FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
    local liftList = {}
    local function CollectFrames(f, depth, out)
        if depth > 20 then return end
        for _, c in ipairs({ f:GetChildren() }) do
            out[#out + 1] = c
            CollectFrames(c, depth + 1, out)
        end
    end
    local function LiftIntoCanvas(canvas)
        if not (canvas and canvas.GetChildren) then return end
        local strata = canvas:GetFrameStrata()
        local rank = STRATA_RANK[strata] or 0
        local base = canvas:GetFrameLevel() or 1
        for _, top in ipairs({ canvas:GetChildren() }) do
            local list = liftList
            for i = #list, 1, -1 do list[i] = nil end
            list[1] = top
            CollectFrames(top, 1, list)
            local minLevel
            for i = 1, #list do
                local f = list[i]
                local fs = f:GetFrameStrata()
                if (STRATA_RANK[fs] or 0) < rank then f:SetFrameStrata(strata) end
                local lv = f:GetFrameLevel() or 0
                if not minLevel or lv < minLevel then minLevel = lv end
            end
            if minLevel and minLevel <= base then
                local shift = base + 1 - minLevel
                for i = 1, #list do
                    local f = list[i]
                    f:SetFrameLevel(math_min(10000, (f:GetFrameLevel() or 0) + shift))
                end
            end
        end
        for i = #liftList, 1, -1 do liftList[i] = nil end
    end
    Preview.LiftIntoCanvas = LiftIntoCanvas

    local function ModeOf(e)
        local modes = e.spec and e.spec.modes
        if type(modes) ~= "table" or #modes == 0 then return nil end
        local saved = Store().modes[e.key]
        for _, m in ipairs(modes) do
            if m.id == saved then return saved end
        end
        return modes[1].id
    end

    local function IsLive(f)
        return f ~= nil and realChild ~= nil and f.compatFrame ~= nil and f.compatFrame.scrollChild == realChild
    end

    ------------------------------------------------------------------
    -- Update / replay
    ------------------------------------------------------------------
    local function PaneVisible() return pane ~= nil and pane:IsVisible() end

    local function PaintSwatches()
        local mode = Store().bg or "dark"
        local bn, sel = RC:GetColor("ui", "borderNormal"), RC:GetColor("ui", "borderSelected")
        for id, s in pairs(swatches) do
            s.active = (id == mode) or nil
            RC.UI:UpdateBorderColor(s.border, s.active and sel or bn, 1)
        end
    end

    local function RepaintChrome()
        if not pane then return end
        local cb, bn = RC:GetColor("ui", "cardBackground"), RC:GetColor("ui", "borderNormal")
        pane.bg:SetVertexColor(cb.r, cb.g, cb.b, cb.a or 1)
        RC.UI:UpdateBorderColor(pane.border, bn, 0.55)
        RC.UI:UpdateBorderColor(view.border, bn, 0.55)
        local gr = RC:GetColor("text", "gray")
        label:SetTextColor(gr.r, gr.g, gr.b, 1)
        -- (in the /rc window, 5.0: the /zui preview band - black 0.10, no
        -- box, a white 0.06 line along its foot; the sample box a white
        -- 0.05 edge; the word "Preview" white 0.45)
        if pane._rcSetRoot then
            pane.bg:SetVertexColor(RC.UI:SCol("shade", 0.10))
            RC.UI:UpdateBorderColor(pane.border, bn, 0)
            if pane.border.bottom then pane.border.bottom:SetColorTexture(RC.UI:SCol("text", 0.06)) end
            RC.UI:UpdateBorderColor(view.border, RC:GetColor("settings", "text"), 0.05)
            label:SetTextColor(RC.UI:SCol("text", 0.45))
        end
        if scaleLabel then scaleLabel:SetTextColor(gr.r, gr.g, gr.b, 1) end
        local ar = RC:GetColor("dropdown", "arrow")
        for _, t in ipairs({ foldArrow, playTex, upTex, downTex }) do t:SetVertexColor(ar.r, ar.g, ar.b, 1) end
        foldBtn:Repaint()
        heightBtn:Repaint()
        replayBtn:Repaint()
        PaintSwatches()
        for _, e in pairs(entries) do
            local row = e.row
            if row then
                for _, b in pairs(row.buttons) do b:Repaint() end
                if row.pick then
                    row.pick:Repaint()
                    row.pickArrow:SetVertexColor(ar.r, ar.g, ar.b, 1)
                    for _, mb in pairs(row.menuButtons) do mb:Repaint() end
                    row.menu.bg:SetVertexColor(cb.r, cb.g, cb.b, 1)
                    RC.UI:UpdateBorderColor(row.menu.border, bn, 1)
                end
            end
        end
    end

    ------------------------------------------------------------------
    -- KEEPING A SAMPLE'S ANIMATION THROUGH AN UPDATE (flicker guard)
    ------------------------------------------------------------------
    -- Many updates stop a sample's animation before laying it out again
    -- (the rule: never re-lay a frame mid-animation). In the client the
    -- update also runs for every unrelated change on the page, and a few
    -- frames after arriving (P.Measure waits for the game to place new
    -- frames), so the arrival replay was cut short and the sample popped
    -- to rest: a flash. While an update runs, a stop asked for a playing
    -- sample waits; afterwards, if the update left that frame where its
    -- animation rests (same anchors within half a pixel, same scale) the
    -- stop was not needed: the animated pose goes back and it plays on.
    -- Only a frame the update really moved is stopped - and the update
    -- runs once more with everything at rest.
    local M = RC.Motion
    local held, heldOrder = {}, {}
    local holding = false
    local function SnapPose(f)
        local pts = {}
        for i = 1, (f:GetNumPoints() or 0) do
            local p, rel, rp, x, y = f:GetPoint(i)
            pts[i] = { p, rel, rp, x or 0, y or 0 }
        end
        return { alpha = f:GetAlpha() or 1, scale = f:GetScale() or 1, points = pts }
    end
    local function SamePoints(a, b)
        if #a ~= #b then return false end
        for i = 1, #a do
            local p, q = a[i], b[i]
            if p[1] ~= q[1] or p[2] ~= q[2] or (p[3] or p[1]) ~= (q[3] or q[1]) then return false end
            if math_abs((p[4] or 0) - (q[4] or 0)) > 0.5 or math_abs((p[5] or 0) - (q[5] or 0)) > 0.5 then return false end
        end
        return true
    end
    local function UnderCanvas(f, canvas)
        local p, d = f, 0
        while p and d < 25 do
            if p == canvas then return true end
            p = p.GetParent and p:GetParent() or nil
            d = d + 1
        end
        return false
    end
    local function Hold(f)
        if held[f] then return true end
        local st = f and rawget(f, "_rcMotion")
        local rest = st and st.rest
        -- (an entrance only: a highlight or a loop the update stops is a
        -- state ending, and an exit hides the frame - those stop as asked)
        if not (rest and st.how == "in" and current and UnderCanvas(f, current.canvas)) then return false end
        held[f] = { pose = SnapPose(f), rest = rest }
        heldOrder[#heldOrder + 1] = f
        return true
    end
    local rawStop, rawStopTree
    local function HeldStop(f)
        if holding and f and M.IsPlaying(f) and Hold(f) then return end
        return rawStop(f)
    end
    local function HeldStopTree(root)
        if not (holding and root) then return rawStopTree(root) end
        local function Walk(f, d)
            if d > 25 then return end
            if M.IsPlaying(f) then HeldStop(f) end
            for _, c in ipairs({ f:GetChildren() }) do Walk(c, d + 1) end
        end
        Walk(root, 0)
    end
    -- what the update decided, frame by frame; true = run it once more
    local function Settle()
        local again = false
        for i, f in ipairs(heldOrder) do
            local h = held[f]
            held[f], heldOrder[i] = nil, nil
            local now = SnapPose(f)
            local rest = h.rest
            local same = SamePoints(now.points, rest.points or {}) and math_abs((now.scale or 1) - (rest.scale or 1)) < 0.001
            if same and M.IsPlaying(f) then
                -- nothing moved: back to the animated pose, it plays on
                f:SetAlpha(h.pose.alpha)
                if f:GetScale() ~= h.pose.scale then f:SetScale(h.pose.scale) end
                if not SamePoints(now.points, h.pose.points) then
                    f:ClearAllPoints()
                    for _, q in ipairs(h.pose.points) do f:SetPoint(q[1], q[2], q[3], q[4], q[5]) end
                end
                Preview.stats.keptPlaying = (Preview.stats.keptPlaying or 0) + 1
            else
                rawStop(f)
                again = true
            end
        end
        return again
    end
    local function GuardedUpdate(e)
        -- (an update that leads to another - a page built from inside one -
        -- runs plainly inside the first)
        if holding or not (M and M.Stop and M.IsPlaying) or M.Stop == HeldStop then
            return pcall(e.spec.update, e.canvas, e.P)
        end
        rawStop, rawStopTree = M.Stop, M.StopTree
        M.Stop, M.StopTree = HeldStop, HeldStopTree
        holding = true
        local ok, err = pcall(e.spec.update, e.canvas, e.P)
        holding = false
        M.Stop, M.StopTree = rawStop, rawStopTree
        if Settle() and ok then
            ok, err = pcall(e.spec.update, e.canvas, e.P)
        end
        return ok, err
    end
    Preview.SamePoints = SamePoints

    local function RunUpdate()
        local e = current
        if not (e and PaneVisible()) then return end
        RepaintChrome()
        if Store().collapsed then e.stale = true return end
        e.stale = nil
        e.P.mode = ModeOf(e)
        e.P.bg = Store().bg or "dark"
        if e.spec.update then
            local ok, err = GuardedUpdate(e)
            if not ok then Fail(e, "update", err) end
        end
        LiftIntoCanvas(e.canvas)
        Preview.stats.updates = Preview.stats.updates + 1
    end

    -- (a replay asked for again within a quarter second while the last
    -- one still plays - a slider on an animation picker being dragged -
    -- plays once now and once when the drag settles, not on every step:
    -- each restart was a flash)
    local REPLAY_GAP = 0.25
    local lastReplay, trailing = -1, false
    local RunReplay
    local function ReplayNow()
        local e = current
        if not (e and PaneVisible()) or Store().collapsed then return end
        if not e.spec.replay then return end
        lastReplay = GetTime()
        e.P.mode = ModeOf(e)
        local ok, err = pcall(e.spec.replay, e.canvas, e.P)
        if not ok then Fail(e, "replay", err) end
        LiftIntoCanvas(e.canvas)
        Preview.stats.replays = Preview.stats.replays + 1
    end
    local function AnyPlaying(root, d)
        if not root or d > 25 then return false end
        if M and M.IsPlaying and M.IsPlaying(root) then return true end
        for _, c in ipairs({ root:GetChildren() }) do
            if AnyPlaying(c, d + 1) then return true end
        end
        return false
    end
    RunReplay = function(force)
        local now = GetTime()
        -- (only a replay that would cut one still playing waits)
        if force == true or now - lastReplay >= REPLAY_GAP
            or not (current and current.canvas and AnyPlaying(current.canvas, 0)) then return ReplayNow() end
        if trailing then return end
        trailing = true
        C_Timer.After(math_max(0.01, REPLAY_GAP - (now - lastReplay)), function()
            trailing = false
            ReplayNow()
        end)
    end

    local function Flush()
        if not pending then return end
        pending = false
        RunUpdate()
    end

    -- One update on the next frame, however often this is asked first.
    function Preview.Request()
        if pending or not current then return end
        pending = true
        C_Timer.After(0, Flush)
    end

    RC.UI:OnSettingsChanged(function()
        if current and PaneVisible() then Preview.Request() end
    end)

    ------------------------------------------------------------------
    -- Background
    ------------------------------------------------------------------
    -- Neutral backdrops, deliberately not theme colours: a sample is
    -- judged against a dark world, a bright one, and a pattern that shows
    -- what is see-through.
    local BG = { dark = { 0.05, 0.05, 0.05 }, light = { 0.78, 0.78, 0.78 }, checker = { 0.3, 0.3, 0.3 } }
    local BG_ORDER = { { "dark", "Dark" }, { "light", "Light" }, { "checker", "Checker" } }

    local function PaintBackground()
        if not view then return end
        local mode = Store().bg or "dark"
        local c = BG[mode] or BG.dark
        view.base:SetVertexColor(c[1], c[2], c[3], 1)
        local used = 0
        if mode == "checker" then
            local w, h = view:GetWidth() or 0, view:GetHeight() or 0
            local function Stripe()
                used = used + 1
                local t = view.stripes[used]
                if not t then
                    t = view:CreateTexture(nil, "BACKGROUND", nil, -6)
                    t:SetTexture(FLAT)
                    view.stripes[used] = t
                end
                t:ClearAllPoints()
                t:SetVertexColor(1, 1, 1, 0.09)
                t:Show()
                return t
            end
            local x = CELL
            while x < w do
                local t = Stripe()
                t:SetPoint("TOPLEFT", view, "TOPLEFT", x, 0)
                t:SetPoint("BOTTOMLEFT", view, "BOTTOMLEFT", x, 0)
                t:SetWidth(math_min(CELL, w - x))
                x = x + CELL * 2
            end
            local y = CELL
            while y < h do
                local t = Stripe()
                t:SetPoint("TOPLEFT", view, "TOPLEFT", 0, -y)
                t:SetPoint("TOPRIGHT", view, "TOPRIGHT", 0, -y)
                t:SetHeight(math_min(CELL, h - y))
                y = y + CELL * 2
            end
        end
        for i = used + 1, #view.stripes do view.stripes[i]:Hide() end
        PaintSwatches()
    end

    ------------------------------------------------------------------
    -- Layout
    ------------------------------------------------------------------
    -- Widths for a run of buttons sharing `space`: their natural widths
    -- when they fit, else all shrunk by the same share towards the least
    -- each needs for its text.
    local function Squeeze(items, space)
        local nat, min = 0, 0
        for _, it in ipairs(items) do nat, min = nat + it.nat, min + it.min end
        local widths = {}
        if #items > 0 and nat > space and min < nat then
            local k = Clamp((space - min) / (nat - min), 0, 1)
            for i, it in ipairs(items) do widths[i] = math_floor(it.min + (it.nat - it.min) * k) end
        else
            for i, it in ipairs(items) do widths[i] = it.nat end
        end
        return widths
    end

    -- THE MODE PILLS FIT THE LINE: natural widths when there is room,
    -- shrunk together (never below their text) when there is not, and
    -- one small button with the chosen mode that opens a menu when even
    -- that does not fit.
    local function LayoutRow(e, avail)
        local row = e.row
        if not row then return end
        local items, n = row.items, #row.items
        local need = GAP * math_max(0, n - 1)
        for _, it in ipairs(items) do need = need + it.min end
        local pills = need <= avail
        row.mode = pills and "pills" or "pick"
        for _, it in ipairs(items) do
            if pills then it.frame:Show() else it.frame:Hide() end
        end
        if pills then
            row.pick:Hide()
            row.menu:Hide()
            local widths = Squeeze(items, avail - GAP * (n - 1))
            local x = 0
            for i, it in ipairs(items) do
                it.frame:SetWidth(widths[i])
                it.frame:ClearAllPoints()
                it.frame:SetPoint("LEFT", row, "LEFT", x, 0)
                x = x + widths[i] + GAP
            end
        else
            row.pick:Show()
            row.pick:SetWidth(Clamp(avail, 40, row.pickNat))
            row.pick:ClearAllPoints()
            row.pick:SetPoint("LEFT", row, "LEFT", 0, 0)
        end
        row:SetSize(math_max(1, avail), BTN_H)
    end

    -- As tall as the sample at its real size needs (the control line and
    -- the box's margins on top), at least MIN_H, at most the cap.
    local function StripHeight(e, w)
        if Store().collapsed then return SLIM_H end
        local cap = CapHeight()
        if not (e and e.spec) then return MIN_H end
        local bw = math_max(10, w - 2 * EDGE - 4)
        local ch = e.spec.height or 140
        local s = FitScale(e.spec.width or 260, ch, bw, cap - VIEW_Y - EDGE - 4)
        local need = math_ceil(ch * s - 0.01) + 4 + VIEW_Y + EDGE
        return Clamp(need, MIN_H, cap)
    end

    -- Lays the strip out at w x h; the window has already placed it.
    local function LayoutInside(e, w, h)
        local collapsed = Store().collapsed and true or false
        pane:SetSize(w, h)
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", pane, "TOPLEFT", EDGE, collapsed and -1 or -BAR_Y)
        local bw = math_max(1, w - 2 * EDGE)
        bar:SetSize(bw, BTN_H)
        for _, other in pairs(entries) do
            if other.row then
                if other == e and not collapsed then other.row:Show() else
                    other.row:Hide()
                    other.row.menu:Hide()
                end
            end
        end
        for _, it in ipairs(rightItems) do
            if collapsed then it:Hide() else it:Show() end
        end
        if collapsed then view:Hide() slim:Show() else view:Show() slim:Hide() end
        -- up folds it away, down opens it again
        foldArrow:SetTexCoord(0, 1, collapsed and 0 or 1, collapsed and 1 or 0)
        if collapsed then
            if scaleLabel then scaleLabel:Hide() end
            return
        end
        local vw, vh = bw, math_max(10, h - VIEW_Y - EDGE)
        view:ClearAllPoints()
        view:SetPoint("TOPLEFT", pane, "TOPLEFT", EDGE, -VIEW_Y)
        view:SetSize(vw, vh)
        -- real size, or evenly smaller to fit, centred
        e.P.boxW, e.P.boxH = vw - 4, vh - 4
        FitCanvas(e)
        local labW = math_ceil(label:GetStringWidth() or 40)
        local scaleW = (scaleLabel and scaleLabel:IsShown()) and (math_ceil(scaleLabel:GetStringWidth() or 0) + 8) or 0
        if e.row then
            e.row:ClearAllPoints()
            e.row:SetPoint("LEFT", bar, "LEFT", labW + 8, 0)
            LayoutRow(e, bw - labW - 8 - RIGHT_W - 8 - scaleW)
        end
        PaintBackground()
    end

    -- (flicker guard) The strip's height follows its width when a wide
    -- sample is fitted, and the page's scroll area follows the strip: a
    -- few px of width back and forth (a scroll bar coming and going, a
    -- half-pixel resize) must not refit and move everything each time. A
    -- width within 3px of the one the strip was fitted at keeps that fit;
    -- the height grows at once (the sample at its real size) but only
    -- shrinks by more than 2px.
    local WIDTH_SLACK, SHRINK_SLACK = 3, 2
    local function Layout()
        local e = current
        if not (pane and e and window) or laying then return end
        laying = true
        local w = (host and host.StripWidth and host.StripWidth()) or pane:GetWidth() or 0
        local fitW = w
        local cap = CapHeight()
        local sig = tostring(Store().collapsed) .. ":" .. cap
        local size = tostring(e.spec and e.spec.width) .. "x" .. tostring(e.spec and e.spec.height)
        if e.layW and e.laySig == sig and e.laySize == size and math_abs(w - e.layW) < WIDTH_SLACK then fitW = e.layW end
        local h = StripHeight(e, fitW)
        if e.layH and e.laySig == sig and h < e.layH and e.layH - h <= SHRINK_SLACK then h = e.layH end
        if fitW == w then e.layW = w end
        e.layH, e.laySig, e.laySize = h, sig, size
        if host and host.Place then w = host.Place(stripY, h, pinnedHeader ~= nil) or w end
        LayoutInside(e, w, h)
        laying = false
    end

    -- Lays the strip out again (the window was resized or rescaled).
    function Preview.Place()
        if current and pane and pane:IsShown() then Layout() end
    end

    function Preview.SetCollapsed(on)
        Store().collapsed = on and true or nil
        Layout()
        if not on and current and current.stale then
            pending = false
            RunUpdate()
            RunReplay(true)
        end
    end

    function Preview.SetBackground(id)
        if not BG[id] then return end
        Store().bg = id
        PaintBackground()
        Preview.Request()
    end

    -- Compact / Normal / Tall caps: the strip resizes, the sample redraws once.
    function Preview.SetHeight(id)
        id = LEGACY_HEIGHT[id] or id
        if not CAPS[id] then return end
        Store().height = (id ~= "normal") and id or nil
        if current and PaneVisible() then
            Layout()
            Preview.Request()
        end
    end

    -- the cap picked, and its height in px now
    function Preview.HeightId() return HeightId(), CapHeight() end

    ------------------------------------------------------------------
    -- The strip
    ------------------------------------------------------------------
    local function AddTip(b, tip, tipTitle)
        if not tip then return end
        b:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            local tn = RC:GetColor("text", "normal")
            local tt = type(tipTitle) == "function" and tipTitle() or tipTitle
            if tt then
                local g = RC:GetColor("text", "gold")
                GameTooltip:AddLine(tt, g.r, g.g, g.b)
            end
            GameTooltip:AddLine(type(tip) == "function" and tip() or tip, tn.r, tn.g, tn.b, true)
            GameTooltip:Show()
        end)
        b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    end

    local function SmallButton(parent, text, width, onClick, tip, tipTitle)
        local b = RC.UI:CreateStyledButton(parent, text, width, BTN_H)
        RC:ApplyCustomFont(b.text, 10, "OUTLINE")
        if b.text.SetWordWrap then b.text:SetWordWrap(false) end
        b:SetScript("OnClick", onClick)
        AddTip(b, tip, tipTitle)
        return b
    end

    local function Arrow(parent, w, h)
        local t = parent:CreateTexture(nil, "OVERLAY")
        t:SetTexture(ARROW)
        t:SetSize(w, h)
        return t
    end

    local function NextHeight()
        local id = HeightId()
        for i, k in ipairs(HEIGHT_ORDER) do
            if k == id then return HEIGHT_ORDER[i % #HEIGHT_ORDER + 1] end
        end
        return "normal"
    end

    local function EnsurePane()
        if pane or not window then return pane end
        local parent = (host and host.holder) or window
        -- The strip: an inset panel like the page's cards (the card fill,
        -- a soft 1px border), placed by the window under the page's title.
        pane = CreateFrame("Frame", nil, parent)
        pane:SetSize(400, MIN_H)
        pane:SetFrameLevel((parent:GetFrameLevel() or 1) + 20)
        pane.bg = pane:CreateTexture(nil, "BACKGROUND")
        pane.bg:SetAllPoints()
        pane.bg:SetTexture(FLAT)
        pane.border = RC.UI:CreateSimpleBorder(pane)
        pane:EnableMouse(true)
        pane:Hide()
        -- its controls wear the /rc window's look; the samples on the
        -- canvas below keep their own (they are the real thing, shrunk)
        if parent == (host and host.holder) then pane._rcSetRoot = true end

        -- THE CONTROL LINE along the top edge
        bar = CreateFrame("Frame", nil, pane)
        bar:SetSize(392, BTN_H)
        label = CreateProfessionalFontString(bar, "OVERLAY", 10, "OUTLINE")
        label:SetPoint("LEFT", bar, "LEFT", 1, 0)
        label:SetText(RCL["Preview"])
        pane.label = label

        -- the right-hand cluster, right to left: fold, height, Replay, swatches
        foldBtn = SmallButton(bar, "", ICON, function() Preview.SetCollapsed(not Store().collapsed) end,
            RCL["Folds the preview down to a slim bar, or opens it again."], RCL["Fold"])
        foldBtn.isFold = true
        foldBtn:SetPoint("RIGHT", bar, "RIGHT", 0, 0)
        foldArrow = Arrow(foldBtn, 9, 9)
        foldArrow:SetPoint("CENTER")
        pane.fold = foldBtn

        heightBtn = SmallButton(bar, "", ICON, function() Preview.SetHeight(NextHeight()) end,
            function() return string.format(RCL["The strip grows to show the sample at its real size, up to %d%% of the window. Click for %s (%d%%)."],
                math_floor(CAPS[HeightId()] * 100 + 0.5), RCL[HEIGHT_NAME[NextHeight()]], math_floor(CAPS[NextHeight()] * 100 + 0.5)) end,
            function() return RCL["Preview height"] .. ": " .. RCL[HEIGHT_NAME[HeightId()]] end)
        heightBtn.isHeight = true
        heightBtn:SetPoint("RIGHT", foldBtn, "LEFT", -2, 0)
        upTex = Arrow(heightBtn, 7, 5)
        upTex:SetTexCoord(0, 1, 1, 0)
        upTex:SetPoint("BOTTOM", heightBtn, "CENTER", 0, 1)
        downTex = Arrow(heightBtn, 7, 5)
        downTex:SetPoint("TOP", heightBtn, "CENTER", 0, -1)
        pane.height = heightBtn

        -- Replay: a play arrow (the arrow turned a quarter)
        replayBtn = SmallButton(bar, "", ICON, function() RunReplay(true) end,
            RCL["Plays the preview's animations again."], RCL["Replay"])
        replayBtn.isReplay = true
        replayBtn:SetPoint("RIGHT", heightBtn, "LEFT", -2, 0)
        playTex = Arrow(replayBtn, 8, 8)
        playTex:SetTexCoord(1, 0, 0, 0, 1, 1, 0, 1)
        playTex:SetPoint("CENTER", 1, 0)
        pane.replay = replayBtn

        -- the background: three swatches, picked like a tab
        local prev = replayBtn
        for i = #BG_ORDER, 1, -1 do
            local id, name = BG_ORDER[i][1], BG_ORDER[i][2]
            local s = CreateFrame("Button", nil, bar)
            s:SetSize(SW, SW)
            s:SetPoint("RIGHT", prev, "LEFT", prev == replayBtn and -8 or -GAP, 0)
            local c = BG[id]
            local base = s:CreateTexture(nil, "ARTWORK")
            base:SetTexture(FLAT)
            base:SetPoint("TOPLEFT", s, "TOPLEFT", 1, -1)
            base:SetPoint("BOTTOMRIGHT", s, "BOTTOMRIGHT", -1, 1)
            base:SetVertexColor(c[1], c[2], c[3], 1)
            if id == "checker" then
                for _, q in ipairs({ "TOPLEFT", "BOTTOMRIGHT" }) do
                    local sq = s:CreateTexture(nil, "ARTWORK", nil, 1)
                    sq:SetTexture(FLAT)
                    sq:SetSize(math_floor(SW / 2) - 1, math_floor(SW / 2) - 1)
                    sq:SetPoint(q, base, q, 0, 0)
                    sq:SetVertexColor(0.62, 0.62, 0.62, 1)
                end
            end
            s.border = RC.UI:CreateSimpleBorder(s)
            local hl = s:CreateTexture(nil, "HIGHLIGHT")
            hl:SetAllPoints()
            hl:SetColorTexture(1, 1, 1, 0.12)
            hl:SetBlendMode("ADD")
            s:SetScript("OnClick", function() Preview.SetBackground(id) end)
            AddTip(s, id == "checker" and RCL["Judge the sample against a pattern that shows what is see-through."]
                or (id == "light" and RCL["Judge the sample against a light backdrop."] or RCL["Judge the sample against a dark backdrop."]),
                RCL["Background"] .. ": " .. RCL[name])
            s.bgId = id
            swatches[id] = s
            rightItems[#rightItems + 1] = s
            prev = s
        end
        rightItems[#rightItems + 1] = replayBtn
        rightItems[#rightItems + 1] = heightBtn
        -- "Scaled to 72%": only when the sample is shown smaller than in game
        scaleLabel = CreateProfessionalFontString(bar, "OVERLAY", 10, "OUTLINE")
        scaleLabel:SetPoint("RIGHT", prev, "LEFT", -8, 0)
        scaleLabel:SetJustifyH("RIGHT")
        scaleLabel:SetText("")
        scaleLabel:Hide()
        pane.scaleLabel = scaleLabel

        -- The sample box: backdrop and canvases, clipped to the box.
        view = CreateFrame("Frame", nil, pane)
        view._rcSetStop = true
        view.base = view:CreateTexture(nil, "BACKGROUND", nil, -6)
        view.base:SetTexture(FLAT)
        view.base:SetAllPoints()
        view.stripes = {}
        view.border = RC.UI:CreateSimpleBorder(view)
        if view.SetClipsChildren then view:SetClipsChildren(true) end
        pane.view = view

        -- FOLDED: the whole slim bar opens it again, lit on hover.
        slim = CreateFrame("Button", nil, pane)
        slim.isFoldStrip = true
        slim:SetAllPoints(pane)
        slim:SetFrameLevel(pane:GetFrameLevel() + 1)
        local shl = slim:CreateTexture(nil, "HIGHLIGHT")
        shl:SetAllPoints()
        shl:SetColorTexture(1, 1, 1, 0.05)
        shl:SetBlendMode("ADD")
        slim:SetScript("OnClick", function() Preview.SetCollapsed(false) end)
        AddTip(slim, RCL["Opens the preview again."], RCL["Preview"])
        slim:Hide()
        foldBtn:SetFrameLevel(slim:GetFrameLevel() + 2)
        pane.slim = slim

        -- Hidden with the window or by a page without a preview: nothing
        -- on a canvas may keep moving unseen, and the next showing counts
        -- as a fresh arrival.
        pane:SetScript("OnHide", function()
            pending = false
            for _, e in pairs(entries) do
                if e.canvas and RC.Motion then RC.Motion.StopTree(e.canvas) end
                if e.row then e.row.menu:Hide() end
            end
            pane._arrivedKey = nil
        end)
        -- the window reopened on the same page: catch up and play once
        pane:SetScript("OnShow", function()
            if not current or pane._arrivedKey == current.key then return end
            pane._arrivedKey = current.key
            pending = false
            Layout()
            RunUpdate()
            RunReplay(true)
        end)
        RepaintChrome()
        return pane
    end

    local function SelectMode(e, id)
        Store().modes[e.key] = id
        local row = e.row
        for mid, other in pairs(row.buttons) do other:SetActive(mid == id) end
        for _, m in ipairs(e.spec.modes) do
            if m.id == id then RC.UI:SetButtonText(row.pick, m.label or m.id) end
        end
        for mid, mb in pairs(row.menuButtons) do mb:SetActive(mid == id) end
        row.menu:Hide()
        if current == e then
            pending = false
            RunUpdate()
            RunReplay(true)
        end
    end

    -- The per-key mode pills on the control line, and the menu they fold
    -- into on a narrow window. Made once, with the key's canvas.
    local function BuildRow(e)
        local row = CreateFrame("Frame", nil, bar)
        row:SetSize(200, BTN_H)
        row.buttons, row.items = {}, {}
        local widest = 0
        for _, m in ipairs(e.spec.modes) do
            local id = m.id
            local text = m.label or id
            local b = SmallButton(row, text, 40, function() SelectMode(e, id) end)
            local tw = math_ceil(b.text:GetStringWidth() or (#text * 6))
            local nat = tw + 14
            b:SetWidth(nat)
            row.items[#row.items + 1] = { frame = b, nat = nat, min = tw + 8 }
            row.buttons[id] = b
            widest = math_max(widest, tw)
        end
        row.pick = SmallButton(row, e.spec.modes[1].label or e.spec.modes[1].id, 60, function()
            if row.menu:IsShown() then row.menu:Hide() return end
            row.menu:ClearAllPoints()
            row.menu:SetPoint("TOPLEFT", row.pick, "BOTTOMLEFT", 0, -2)
            row.menu:Show()
        end, RCL["Shows the sample as one of these."], e.spec.modesLabel or RCL["Show"])
        row.pick.isModePick = true
        row.pick.text:ClearAllPoints()
        row.pick.text:SetPoint("LEFT", row.pick, "LEFT", 5, 0)
        row.pick.text:SetPoint("RIGHT", row.pick, "RIGHT", -14, 0)
        row.pick.text:SetJustifyH("LEFT")
        row.pickArrow = Arrow(row.pick, 8, 8)
        row.pickArrow:SetPoint("RIGHT", row.pick, "RIGHT", -4, 0)
        row.pickNat = widest + 26
        row.pick:Hide()
        local menu = CreateFrame("Frame", nil, pane)
        menu:SetFrameStrata("FULLSCREEN_DIALOG")
        menu.bg = menu:CreateTexture(nil, "BACKGROUND")
        menu.bg:SetAllPoints()
        menu.bg:SetTexture(FLAT)
        menu.border = RC.UI:CreateSimpleBorder(menu)
        menu:EnableMouse(true)
        menu:Hide()
        row.menu, row.menuButtons = menu, {}
        local mw = widest + 20
        for i, m in ipairs(e.spec.modes) do
            local id = m.id
            local mb = SmallButton(menu, m.label or id, mw, function() SelectMode(e, id) end)
            mb:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -4 - (i - 1) * (BTN_H + 2))
            row.menuButtons[id] = mb
        end
        menu:SetSize(mw + 8, #e.spec.modes * (BTN_H + 2) + 6)
        e.row = row
    end

    local function PaintModes(e)
        if not (e.row and e.row.buttons) then return end
        local mode = ModeOf(e)
        for id, b in pairs(e.row.buttons) do b:SetActive(id == mode) end
        for _, m in ipairs(e.spec.modes) do
            if m.id == mode then RC.UI:SetButtonText(e.row.pick, m.label or m.id) end
        end
        for id, mb in pairs(e.row.menuButtons) do mb:SetActive(id == mode) end
    end

    -- A row of sample parts, left to right and centred in the canvas.
    local function Row(e, parts, o)
        o = o or {}
        local gap = o.gap or 10
        local list, total, tall = {}, 0, 0
        for _, p in ipairs(parts) do
            local f = type(p) == "table" and p.frame or p
            if f and (f.IsShown == nil or f:IsShown()) then
                local k = (f.GetScale and f:GetScale()) or 1
                local w = ((type(p) == "table" and p.frame and p.w) or f:GetWidth() or 0) * k
                local h = ((type(p) == "table" and p.frame and p.h) or f:GetHeight() or 0) * k
                list[#list + 1] = { f = f, w = w, h = h, k = k, dy = type(p) == "table" and p.frame and p.dy or 0 }
                total = total + w
                tall = math_max(tall, h)
            end
        end
        total = total + gap * math_max(0, #list - 1)
        local canvas = e.canvas
        local M = RC.Motion
        local x = -total / 2
        for _, it in ipairs(list) do
            local ox, oy = (x + it.w / 2) / it.k, ((o.y or 0) + it.dy) / it.k
            local p1, rel, p2, px, py = it.f:GetPoint(1)
            if not (it.f:GetNumPoints() == 1 and p1 == "CENTER" and rel == canvas and p2 == "CENTER"
                and math.abs((px or 0) - ox) < 0.01 and math.abs((py or 0) - oy) < 0.01) then
                if M and M.IsPlaying and M.IsPlaying(it.f) then M.Stop(it.f) end
                it.f:ClearAllPoints()
                it.f:SetPoint("CENTER", canvas, "CENTER", ox, oy)
            end
            x = x + it.w + gap
        end
        if o.fit and e.P.Resize then
            local pad = o.pad or 4
            e.P.Resize(math_max(o.minW or 1, math_ceil(total + 2 * pad)),
                math_max(o.minH or 1, math_ceil(tall + 2 * math.abs(o.y or 0) + 2 * pad)))
        end
        return total, tall
    end

    -- The box of everything visible under root, relative to root's centre.
    local function Measure(root)
        if not (root and root.GetCenter) then return nil end
        local rs = root:GetEffectiveScale() or 1
        local rcx, rcy = root:GetCenter()
        if not rcx then return nil end
        local l, b, r, t
        local function Add(x)
            if x.GetObjectType and x:GetObjectType() == "FontString" then
                local s = x:GetText()
                if not s or s == "" then return end
            end
            local xl, xb, xr0, xt0 = x:GetLeft(), x:GetBottom(), x:GetRight(), x:GetTop()
            if not (xl and xb and xr0 and xt0) then return end
            local w, h = xr0 - xl, xt0 - xb
            if w <= 0 or h <= 0 then return end
            local k = (x:GetEffectiveScale() or 1) / rs
            xl, xb = xl * k, xb * k
            local xr, xt = xl + w * k, xb + h * k
            l, b = math.min(l or xl, xl), math.min(b or xb, xb)
            r, t = math_max(r or xr, xr), math_max(t or xt, xt)
        end
        local function Visit(f, depth)
            if depth > 12 then return end
            for _, x in ipairs({ f:GetRegions() }) do
                if x:IsVisible() then Add(x) end
            end
            for _, x in ipairs({ f:GetChildren() }) do
                if x:IsVisible() then
                    Add(x)
                    Visit(x, depth + 1)
                end
            end
        end
        Visit(root, 0)
        if not l then return nil end
        return (l + r) / 2 - rcx, (b + t) / 2 - rcy, r - l, t - b
    end

    local function Entry(key)
        local e = entries[key]
        if e then return e end
        e = { key = key }
        e.P = {
            key = key, store = {}, scale = 1,
            Update = function() if current == e then Preview.Request() end end,
            Replay = function() if current == e then RunReplay() end end,
        }
        -- the page wants another canvas: kept for the key, the scale follows
        e.P.Resize = function(w, h)
            -- (a size that only jitters by a fraction of a pixel around the
            -- current one - measured text, half-pixel centring - keeps it:
            -- rounding it flipped the canvas 1px back and forth)
            local cw, ch = e.spec and e.spec.width, e.spec and e.spec.height
            if cw and math_abs(w - cw) < 0.75 then w = cw end
            if ch and math_abs(h - ch) < 0.75 then h = ch end
            w, h = math_max(1, math_floor(w + 0.5)), math_max(1, math_floor(h + 0.5))
            e.size = { w, h }
            if not (e.spec and e.canvas) then return end
            if e.spec.width == w and e.spec.height == h then return end
            e.spec.width, e.spec.height = w, h
            e.canvas:SetSize(w, h)
            -- the strip grows or shrinks with the sample (Layout fits it)
            if current == e and pane and pane:IsShown() and not laying then Layout() else FitCanvas(e) end
        end
        e.P.Row = function(parts, o) return Row(e, parts, o) end
        -- not placed yet (the game lays new frames out lazily): one more
        -- update next frame, a few times at most
        e.P.Measure = function(root)
            local cx, cy, w, h = Measure(root)
            if cx then e.measureTries = nil
            elseif (e.measureTries or 0) < 5 and not e.measureWait then
                e.measureTries, e.measureWait = (e.measureTries or 0) + 1, true
                C_Timer.After(0, function() e.measureWait = nil e.P.Update() end)
            end
            return cx, cy, w, h
        end
        entries[key] = e
        return e
    end

    ------------------------------------------------------------------
    -- The page's title, pinned
    ------------------------------------------------------------------
    -- On a page with a preview the title (CreateSettingsPageHeader, made
    -- at the top of the page) moves out of the scrolled page into the
    -- window's pinned top, the strip goes under it, and everything else on
    -- the page moves up by the room the title took. A piece the page adds
    -- after that (a late build) is moved up too, once.
    local function ShiftUp(obj, dy)
        local n = obj.GetNumPoints and obj:GetNumPoints() or 0
        if n == 0 then return end
        local pts = {}
        for i = 1, n do pts[i] = { obj:GetPoint(i) } end
        obj:ClearAllPoints()
        for i, q in ipairs(pts) do
            local p, rel, rp, x, y = q[1], q[2], q[3], q[4] or 0, q[5] or 0
            if (rel == nil or rel == realChild) and rp and rp:find("TOP") then y = y + dy end
            obj:SetPoint(p, rel or realChild, rp, x, y)
        end
        -- what the client reads back (it keeps 32-bit floats), so the next
        -- pass knows this piece has moved already
        obj._rcPinY = select(5, obj:GetPoint(1)) or 0
    end

    -- A piece the page anchored again since it moved up: its offset no
    -- longer reads back as the one it was given. Compared with a margin:
    -- an exact compare saw float rounding as a fresh anchor and moved a
    -- piece up again and again (the TTK page's tab row went behind the
    -- strip, leaving a gap where it stood).
    local function Reanchored(o)
        if o._rcPinTok ~= token or o._rcPinY == nil then return false end
        if (o.GetNumPoints and o:GetNumPoints() or 0) == 0 then return false end
        return math.abs((select(5, o:GetPoint(1)) or 0) - o._rcPinY) > 0.5
    end

    -- (a piece the page anchored again since - a section opening - has
    -- page coordinates again and moves up again)
    local function ShiftPage()
        if pinShift == 0 or not realChild then return end
        for _, list in ipairs({ { realChild:GetChildren() }, { realChild:GetRegions() } }) do
            for _, o in ipairs(list) do
                if o._rcPinTok ~= token or Reanchored(o) then
                    o._rcPinTok = token
                    ShiftUp(o, pinShift)
                end
            end
        end
    end

    local function Unpin()
        if pinnedHeader then
            pinnedHeader:Hide()
            pinnedHeader:ClearAllPoints()
            pinnedHeader:SetParent(nil)
            -- thrown away with its page (font refresh list)
            if RC.UI.DiscardTree then RC.UI:DiscardTree(pinnedHeader) end
        end
        pinnedHeader, pinShift, stripY = nil, 0, 8
    end

    -- A page that declared its preview before making its title (most do):
    -- the title is pinned the moment it is made, and the page is handed
    -- back the y its next piece takes at the top of the scroll area, so
    -- the page lays itself out where it belongs from the start - nothing
    -- has to be moved up after the fact (a piece missed by that move, or
    -- moved twice, used to leave a gap or hide a tab row). Returns nil
    -- when the title is not the page's top piece; Pin() then does it the
    -- old way once the page has built.
    local function EarlyPin(hf, y)
        -- (5.0: every page's title is pinned in the window's header, as in
        -- ZacUI's /zui, with or without a preview under it)
        if pinnedHeader or not (endPending and host and host.holder) then return nil end
        local p, rel, _, hx, hy = hf:GetPoint(1)
        hy = hy or -15
        if hy < -40 or (rel ~= nil and rel ~= realChild) then return nil end
        for _, list in ipairs({ { realChild:GetChildren() }, { realChild:GetRegions() } }) do
            for _, o in ipairs(list) do
                if o ~= hf and o:IsShown() and (o.GetNumPoints and o:GetNumPoints() or 0) > 0 then
                    local _, orel, rp, _, oy = o:GetPoint(1)
                    if (orel == nil or orel == realChild) and rp and rp:find("TOP") and (oy or 0) > hy + 0.5 then return nil end
                end
            end
        end
        local hh = hf:GetHeight() or 30
        hf:SetParent(host.holder)
        hf:ClearAllPoints()
        hf:SetPoint("TOPLEFT", host.holder, "TOPLEFT", hx or INSET, hy)
        hf:SetPoint("RIGHT", host.holder, "RIGHT", -INSET, 0)
        hf:Show()
        pinnedHeader = hf
        stripY = math_floor(-hy + hh + 10 + 0.5)
        pinShift = 0
        -- the page went on 12 under the title; its first piece now sits 6 down
        return (y or (hy - hh - 12)) + math_floor(-hy + hh + 6 + 0.5)
    end
    Preview.EarlyPin = EarlyPin

    local function Pin()
        if pinnedHeader or not (host and host.holder) then return end
        local hf
        for _, f in ipairs(pageHeaders) do
            if f:GetParent() == realChild then
                local _, _, _, _, hy = f:GetPoint(1)
                if (hy or 0) >= -40 then hf = f break end
            end
        end
        if not hf then return end
        local p, _, _, hx, hy = hf:GetPoint(1)
        hy = hy or -15
        -- only a title at the very top: a page that puts its tabs (or
        -- anything else) above its title keeps it all in the scroll
        for _, list in ipairs({ { realChild:GetChildren() }, { realChild:GetRegions() } }) do
            for _, o in ipairs(list) do
                if o ~= hf and o:IsShown() and (o.GetNumPoints and o:GetNumPoints() or 0) > 0 then
                    local _, rel, rp, _, y = o:GetPoint(1)
                    if (rel == nil or rel == realChild) and rp and rp:find("TOP") and (y or 0) > hy + 0.5 then return end
                end
            end
        end
        local hh = hf:GetHeight() or 30
        hf:SetParent(host.holder)
        hf:ClearAllPoints()
        hf:SetPoint("TOPLEFT", host.holder, "TOPLEFT", hx or INSET, hy)
        hf:SetPoint("RIGHT", host.holder, "RIGHT", -INSET, 0)
        hf:Show()
        pinnedHeader = hf
        -- whole pixels: a fraction would leave every moved piece off the grid
        stripY = math_floor(-hy + hh + 10 + 0.5)
        -- the page went on 12 under the title; its first card now sits 6 down
        pinShift = math_floor(-hy + hh + 6 + 0.5)
        ShiftPage()
    end

    ------------------------------------------------------------------
    -- The page side
    ------------------------------------------------------------------
    local function HidePane()
        if pane then pane:Hide() end
        current = nil
        pending = false
        if host and host.Place then host.Place(stripY, 0, pinnedHeader ~= nil) end
    end
    Preview.Hide = HidePane

    local function EndPage(t)
        if t ~= token then return end
        if not endPending then
            -- placed already (the page measured its height): pieces the
            -- page added since still move up with the rest
            ShiftPage()
            return
        end
        endPending = false
        local spec = declared
        declared = nil
        if not spec or not window then
            HidePane()
            return
        end
        EnsurePane()
        Pin()
        local e = Entry(spec.key)
        e.spec = spec
        -- a size the page asked for since (P.Resize) stays for the key
        if e.size then spec.width, spec.height = e.size[1], e.size[2] end
        if not e.canvas then
            e.canvas = CreateFrame("Frame", nil, view)
            e.canvas:SetPoint("CENTER", view, "CENTER", 0, 0)
            if e.canvas.SetClipsChildren then e.canvas:SetClipsChildren(true) end
        end
        e.canvas:SetSize(spec.width or 260, spec.height or 140)
        if not e.built then
            e.built = true
            Preview.stats.builds = Preview.stats.builds + 1
            if spec.build then
                local ok, err = pcall(spec.build, e.canvas, e.P)
                if not ok then Fail(e, "build", err) end
                LiftIntoCanvas(e.canvas)
            end
        end
        if not e.row and type(spec.modes) == "table" and #spec.modes > 0 then BuildRow(e) end
        PaintModes(e)
        for _, other in pairs(entries) do
            if other ~= e and other.canvas then
                if RC.Motion then RC.Motion.StopTree(other.canvas) end
                other.canvas:Hide()
            end
        end
        e.canvas:Show()

        local arrived = (current ~= e) or not pane:IsShown() or pane._arrivedKey ~= e.key
        current = e
        if spec.replay then replayBtn:Enable() else replayBtn:Disable() end
        -- marked before Show so the strip's own OnShow does not run it twice
        if arrived then pane._arrivedKey = e.key end
        if window:IsShown() then pane:Show() end
        Layout()
        if arrived then
            -- a new page or the window reopened: draw now, play once
            pending = false
            RunUpdate()
            RunReplay(true)
        else
            Preview.Request()
        end
    end

    local function ScheduleEnd()
        endPending = true
        local t = token
        C_Timer.After(0, function() EndPage(t) end)
    end

    -- Called (through the hook below) every time the page is cleared.
    function Preview.BeginPage(f)
        if not IsLive(f) then return end
        token = token + 1
        declared = nil
        Unpin()
        for i = #pageHeaders, 1, -1 do pageHeaders[i] = nil end
        ScheduleEnd()
    end

    -- The window asks before it measures the page (UpdateSidebarScrollbar):
    -- a build still waiting to end ends now, so the page is measured with
    -- its title pinned and the strip in place, in the same frame.
    function Preview.Settle(f)
        if not (f and IsLive(f)) then return end
        if endPending then EndPage(token) else ShiftPage() end
    end

    -- How far the page moved up for its pinned title (0: not pinned).
    function Preview.PinShift() return pinShift end

    function RC.UI:DeclarePreview(spec)
        if type(spec) ~= "table" or type(spec.key) ~= "string" then
            RC:DebugPrint("DeclarePreview needs a table with a key", "config")
            return nil
        end
        if not IsLive(RC.sidebarConfigFrame) then return nil end
        declared = spec
        if not endPending then
            token = token + 1
            ScheduleEnd()
        end
        return Entry(spec.key).P
    end

    -- The window calls this once it is built. host.holder is the pinned
    -- top of the page (the title and the strip live on it);
    -- host.Place(stripY, h, pinned) puts a strip h high stripY down in it
    -- (0: none), moves the scroll area under it and returns the strip's
    -- width.
    function Preview.Attach(win, h)
        if window then return end
        window = win
        host = h
        realChild = win.contentScrollChild
        if not RC._previewClearHooked and RC.ClearSidebarContent then
            RC._previewClearHooked = true
            hooksecurefunc(RC, "ClearSidebarContent", function(_, f) Preview.BeginPage(f) end)
        end
        -- the page headers made on the live page, so the one at its top
        -- can be pinned above the strip
        if not RC._previewHeaderHooked and RC.CreateSettingsPageHeader then
            RC._previewHeaderHooked = true
            local make = RC.CreateSettingsPageHeader
            RC.CreateSettingsPageHeader = function(self, parent, ...)
                local f, y = make(self, parent, ...)
                if f and parent == realChild then
                    pageHeaders[#pageHeaders + 1] = f
                    local ny = EarlyPin(f, y)
                    if ny then return f, ny end
                end
                return f, y
            end
        end
        -- a resized window: the strip follows the page's width
        win:HookScript("OnSizeChanged", function()
            if laying or not (current and pane and pane:IsShown()) then return end
            Layout()
        end)
    end

    function Preview.IsShown()
        return current ~= nil and PaneVisible()
    end

    function Preview.Current()
        return current and current.key, current and current.canvas, current and current.P
    end

    -- How tall the strip is right now (0 when there is none).
    function Preview.Height()
        if not (pane and pane:IsShown() and current) then return 0 end
        return pane:GetHeight() or 0
    end

    -- A SAMPLE THAT IS A WHOLE WINDOW (built on the canvas by the
    -- feature's own window code, its dropdowns, boxes, buttons and scroll
    -- area included) takes no clicks, no wheel and no keys: everything
    -- under root goes mouse-, wheel- and keyboard-dead, root as well
    -- unless keepRoot (a root that picks texts on a click keeps its
    -- mouse). Call it again after the sample grows new pieces.
    --   RC.UI:InertSample(root, keepRoot)
    local function Inert(f, d)
        if d > 25 then return end
        if f.EnableMouse then f:EnableMouse(false) end
        if f.EnableMouseWheel then f:EnableMouseWheel(false) end
        if f.GetObjectType and f:GetObjectType() == "EditBox" then
            if f.SetAutoFocus then f:SetAutoFocus(false) end
            if f.EnableKeyboard then f:EnableKeyboard(false) end
            if f.ClearFocus then f:ClearFocus() end
        end
        for _, c in ipairs({ f:GetChildren() }) do Inert(c, d + 1) end
    end
    function RC.UI:InertSample(root, keepRoot)
        if not (root and root.GetChildren) then return end
        if not keepRoot then return Inert(root, 0) end
        for _, c in ipairs({ root:GetChildren() }) do Inert(c, 1) end
    end

    Preview.Replay = RunReplay
    Preview.Frame = function() return pane end
    Preview.View = function() return view end
