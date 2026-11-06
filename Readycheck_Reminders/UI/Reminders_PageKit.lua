------------------------------------------------------------------------
-- Readycheck - Reminder page kit
-- Small row builders the reminder-group pages share (Battle Shout,
-- Chronoboon, the aura trackers, TTK, the route): a labelled slider, a
-- gray description, a theme colour row bound to RC:GetColor/SetColor, a
-- font picker whose size stays on the feature's old size key, and an
-- animation picker over one saved spec. All of it is built on the
-- framework widgets, so every control already raises
-- RC.UI:NotifySettingChanged and the preview pane follows on its own.
-- Candidates for UIF_Pickers once the framework is open again.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
local math_floor, math_max = math.floor, math.max
local type, pairs = type, pairs

local K = {}
RC._rpk = K

local function Col(cat, key) return RC:GetColor(cat, key) end

-- 11px light label at (x, y) in a card
function K.Label(card, x, y, text)
    local fs = RC:CreateFontString(card, "OVERLAY", nil, 11)
    fs:SetPoint("TOPLEFT", card, "TOPLEFT", x or 14, y)
    fs:SetText(text)
    local c = Col("text", "light") or Col("text", "normal")
    fs:SetTextColor(c.r, c.g, c.b, 1)
    return fs
end

-- gray 10px note under a control, one line at most (the rest in its
-- tooltip: RC.UI:CreateHelpLine); returns the next y and the line
function K.Desc(card, y, text, x)
    local ny, h = RC.UI:CreateHelpLine(card, x or 14, y, text)
    return ny, h.text
end

-- Label above a full-width slider. fmt(v) is the value text, onChange(v)
-- runs on every step with the stepped value; the profile saves 0.5s after
-- the last move. Returns the next y and the slider.
function K.Slider(card, y, label, minV, maxV, cur, step, fmt, onChange, x)
    x = x or 14
    K.Label(card, x, y, label)
    local sl = RC.UI:CreateSlider(card, minV, maxV, cur, step)
    sl.rpkLabel = label
    sl:SetPoint("TOPLEFT", card, "TOPLEFT", x, y - 18)
    sl:SetPoint("RIGHT", card, "RIGHT", -14, 0)
    sl.Text:SetText(fmt(cur))
    sl:SetScript("OnValueChanged", function(s, v)
        v = math_floor(v / step + 0.5) * step
        if step < 1 then v = math_floor(v * 1000 + 0.5) / 1000 end
        s.Text:SetText(fmt(v))
        onChange(v)
        if s.saveTimer then s.saveTimer:Cancel() end
        s.saveTimer = C_Timer.NewTimer(0.5, function() RC:SaveConfigurationToProfile() end)
    end)
    return y - 52, sl
end

function K.Px(v) return math_floor(v + 0.5) .. " px" end
function K.Pt(v) return math_floor(v + 0.5) .. " pt" end
function K.Pct(v) return math_floor(v * 100 + 0.5) .. "%" end

-- A theme colour (customColors[cat][key]) as a colour row. onChange runs
-- after every pick so the live frame can repaint.
function K.ThemeColor(card, y, cat, key, label, onChange, opts)
    opts = opts or {}
    local def = RC.defaultColors and RC.defaultColors[cat] and RC.defaultColors[cat][key]
    local cp = RC.UI:CreateColorPicker(card, {
        label = label, alpha = opts.alpha, width = opts.width or 420, tooltip = opts.tooltip,
        get = function() return RC:GetColor(cat, key) end,
        set = function(r, g, b, a)
            local cur = RC:GetColor(cat, key)
            RC:SetColor(cat, key, r, g, b, a or (cur and cur.a) or 1)
            if onChange then onChange() end
        end,
        default = def,
        isChanged = function()
            local cc = RC.db and RC.db.customColors
            return cc and cc[cat] and cc[cat][key] ~= nil or false
        end,
        reset = function()
            RC:ResetColor(cat, key)
            if onChange then onChange() end
        end,
    })
    cp:SetPoint("TOPLEFT", card, "TOPLEFT", opts.x or 10, y)
    return y - 26, cp
end

-- The runtime font spec for a feature that keeps its size on an old key:
-- face / outline / shadow from tbl[specKey], size from tbl[sizeKey].
function K.FontSpec(tbl, specKey, sizeKey)
    local s = type(tbl) == "table" and tbl[specKey]
    s = type(s) == "table" and s or {}
    return { face = s.face, outline = s.outline, shadow = s.shadow, size = sizeKey and tbl[sizeKey] or s.size }
end

-- Font picker bound to that pair. Without sizeKey the size lives in the
-- spec itself (nil = defaults.size).
function K.Font(card, y, tbl, specKey, sizeKey, defaults, label, sample, onChange, minS, maxS)
    local fp = RC.UI:CreateFontPicker(card, {
        label = label, width = 420, defaults = defaults,
        minSize = minS or 6, maxSize = maxS or 32, sample = sample,
        get = function() return K.FontSpec(tbl, specKey, sizeKey) end,
        set = function(spec)
            if sizeKey then
                if spec.size then tbl[sizeKey] = math_floor(spec.size + 0.5) end
                tbl[specKey] = { face = spec.face, outline = spec.outline, shadow = spec.shadow }
            else
                tbl[specKey] = { face = spec.face, outline = spec.outline, shadow = spec.shadow, size = spec.size }
            end
            RC:SaveConfigurationToProfile()
            if onChange then onChange() end
        end,
    })
    fp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
    return y - fp:GetHeight() - 10, fp
end

-- Animation picker over tbl[key] (a full spec once picked, nil = defaults).
function K.Anim(card, y, tbl, key, defaults, label, how, onChange, styles)
    local ap = RC.UI:CreateAnimationPicker(card, {
        label = label, width = 460, how = how or "in", defaults = defaults, styles = styles,
        get = function() return tbl[key] end,
        set = function(spec)
            tbl[key] = spec
            RC:SaveConfigurationToProfile()
            if onChange then onChange() end
        end,
    })
    ap:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
    return y - ap:GetHeight() - 14, ap
end

-- A saved tab key from before the standard tabs, mapped onto them.
function K.Tab(saved, map, default)
    if saved and map[saved] then return map[saved] end
    return saved or default
end

-- Gives the whole sample a scale that fits it in the canvas (never
-- enlarges); re-laid out only when the size really changed, stopping any
-- animation first so its rest is not fought.
function K.Fit(holder, w, h, cw, ch, pad)
    pad = pad or 16
    local fit = math.min(1, (cw - pad) / math_max(1, w), (ch - pad) / math_max(1, h))
    local sig = math_floor(w) .. ":" .. math_floor(h) .. ":" .. fit
    if holder._rpkSig ~= sig then
        RC.Motion.StopTree(holder)
        holder:SetSize(w, h)
        holder:SetScale(fit)
        holder._rpkSig = sig
    end
end

-- The strip fit: the whole sample at its real size, as drawn in game
-- (its own scale setting included), and the preview canvas made its box
-- plus `pad`; the strip shows the canvas at real size and only scales it
-- down when it would not fit (P.Resize). w, h: the sample's size as
-- drawn. natW, natH are accepted for older callers and ignored: a scale
-- setting shows as the real thing growing or shrinking. Re-laid out only
-- when the size really changed, stopping any animation first so its rest
-- is not fought.
function K.FitStrip(P, holder, w, h, pad)
    pad = pad or 6
    local sig = math_floor(w) .. ":" .. math_floor(h) .. ":strip"
    if holder._rpkSig ~= sig then
        RC.Motion.StopTree(holder)
        holder:SetSize(w, h)
        holder:SetScale(1)
        holder._rpkSig = sig
    end
    if P and P.Resize then P.Resize(w + pad, h + pad) end
end

-- Entrance, a beat on screen, the exit, back at rest - for every
-- { frame, inSpec, outSpec } in list. Chained with C_Timer and a token,
-- checking IsVisible at every step (the pane's replay contract).
function K.Replay(st, canvas, list, hold, afterIn)
    local M = RC.Motion
    st.token = (st.token or 0) + 1
    local t = st.token
    local longest = 0
    for _, e in ipairs(list) do
        M.Stop(e.frame)
        e.frame:Hide()
        M.Show(e.frame, e.inSpec, e.onIn)
        local d = M.Duration(e.inSpec and e.inSpec.duration or 0) + M.Duration(e.inSpec and e.inSpec.delay or 0)
        if e.inSpec and e.inSpec.style == "none" then d = 0 end
        if d > longest then longest = d end
    end
    if afterIn then afterIn() end
    C_Timer.After(longest + (hold or 1.2), function()
        if t ~= st.token or not canvas:IsVisible() then return end
        local outLongest = 0
        for _, e in ipairs(list) do
            M.Hide(e.frame, e.outSpec)
            local d = M.Duration(e.outSpec and e.outSpec.duration or 0) + M.Duration(e.outSpec and e.outSpec.delay or 0)
            if d > outLongest then outLongest = d end
        end
        C_Timer.After(outLongest + 0.4, function()
            if t ~= st.token then return end
            for _, e in ipairs(list) do
                M.Stop(e.frame)
                if canvas:IsVisible() and e.keep ~= false then e.frame:Show() end
            end
        end)
    end)
end
