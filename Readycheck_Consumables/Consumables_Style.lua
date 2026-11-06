------------------------------------------------------------------------
-- Readycheck - Consumables Bar Style
-- The look of the bar buttons, shared by the live bars and the settings
-- pane previews: one font spec and colour per text element, the expiry
-- glow, the bar's entrance / exit and the mouseover fade speeds.
--
-- Settings live in db[barKey].style (barKey = consumablesHelper,
-- potionsBar, weaponsBar, trinketBar). Every field is nil until picked,
-- and nil is today's look:
--   <elem>Font   font spec   size nil = scales with the button, as before
--   <key>Color   { r, g, b, a }
--   glowEnabled, glowScale, glowAnim       the expiry glow
--   showAnim, hideAnim                     RC.Motion specs, "none" = instant
--   fadeIn, fadeOut                        mouseover fade lengths (s)
-- Nothing here reads RC.db at load time.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
local pairs, ipairs, type, tonumber = pairs, ipairs, type, tonumber
local math_floor, math_max = math.floor, math.max

local BS = {}
RC.BarStyle = BS

-- Today's palette for the button text (Consumables_State's C table, which
-- loads its values only once RC.db exists; these mirror it so a sample can
-- be drawn before any bar was built).
local P = {
    white       = { 1, 1, 1, 1 },
    red         = { 1, 0.2, 0.2, 1 },
    redBright   = { 1, 0.4, 0.4, 1 },
    redMed      = { 0.9, 0.3, 0.3, 1 },
    gold        = { 1, 0.82, 0, 1 },
    green       = { 0.2, 0.8, 0.2, 1 },
    greenBright = { 0.4, 1, 0.4, 1 },
    yellow      = { 1, 1, 0, 1 },
    yellowLight = { 1, 1, 0.6, 1 },
    blue        = { 0.3, 0.6, 1, 1 },
    orange      = { 1, 0.5, 0, 1 },
}
BS.PALETTE = P

-- Text elements: today's size formula (max(min, floor(size * k)), or a
-- fixed size) and drop shadow offset.
BS.TEXT = {
    count    = { min = 8,  k = 0.33, sh = 1 },
    cooldown = { min = 12, k = 0.55, sh = 2 },
    gcd      = { min = 14, k = 0.6,  sh = 3 },
    duration = { min = 14, k = 0.6,  sh = 3 },
    expiry   = { min = 12, k = 0.5,  sh = 2 },
    timer    = { min = 10, k = 0.33, sh = 1 },
    slot     = { min = 7,  k = 0.25, sh = 1 },
    name     = { fixed = 7, sh = 1 },
    absorb   = { fixed = 9, sh = 1 },
    -- trinket menu
    tcooldown = { min = 8, k = 0.55, sh = 2, scaleKey = "cooldownTextScale" },
    tbuff     = { min = 8, k = 0.55, sh = 2, scaleKey = "cooldownTextScale" },
    tslot     = { min = 9, k = 0.28, sh = 1 },
}

-- Which font strings on a button each element styles.
local FIELDS = {
    count = { "count" }, cooldown = { "cooldownText" }, gcd = { "gcdText" },
    duration = { "durationText" }, expiry = { "expiryText" },
    timer = { "weaponTimeText", "timeLabel" }, slot = { "slotLabel" },
    name = { "nameLabel" }, absorb = { "absorbText" },
    tcooldown = { "cooldownText" }, tbuff = { "buffDurationText" }, tslot = { "slotText" },
}
local BAR_ELEMS = { "count", "cooldown", "gcd", "duration", "expiry", "timer", "slot", "name", "absorb" }
local TRINKET_ELEMS = { "tcooldown", "tbuff", "tslot" }
BS.BAR_ELEMS, BS.TRINKET_ELEMS = BAR_ELEMS, TRINKET_ELEMS

-- The style key that holds each element's font.
local FONT_KEY = {
    count = "countFont", cooldown = "cooldownFont", gcd = "gcdFont", duration = "durationFont",
    expiry = "expiryFont", timer = "timerFont", slot = "slotFont", name = "nameFont", absorb = "absorbFont",
    tcooldown = "cooldownFont", tbuff = "buffFont", tslot = "slotFont",
}
BS.FONT_KEY = FONT_KEY

-- Colour keys and the element default each stands for. A key whose
-- default is a function picks per text element (the two corner timers
-- had different shades of the same idea).
local function TextColor(key)
    return function() local c = RC:GetColor("text", key) return { c.r, c.g, c.b, c.a or 1 } end
end
BS.COLOR_DEFAULTS = {
    countColor        = P.white,
    emptyColor        = P.red,
    cooldownColor     = P.white,
    gcdColor          = P.white,
    durationColor     = P.yellow,
    expirySoonColor   = P.gold,
    expiryUrgentColor = P.redBright,
    timerGoodColor    = P.greenBright,
    timerMidColor     = P.gold,
    timerLowColor     = P.redBright,
    nameColor         = P.white,
    slotColor         = P.white,
    glowColor         = P.orange,
    -- trinket menu
    tcooldownColor    = P.yellow,
    tbuffColor        = TextColor("buttonActive"),
    tslotColor        = TextColor("buttonActive"),
}
-- the slot buttons' corner label used these before it shared the keys
local TIMELABEL_DEFAULTS = { timerGoodColor = P.green, timerMidColor = P.yellowLight, timerLowColor = P.redMed }
BS.TIMELABEL_DEFAULTS = TIMELABEL_DEFAULTS

-- Per-bar defaults for the non-colour, non-font fields.
local GLOW_ANIM = { style = "flash", duration = 1.6, loop = true }
local BAR_ANIM = { style = "none", duration = 0.3 }
BS.GLOW_ANIM_DEFAULTS, BS.BAR_ANIM_DEFAULTS = GLOW_ANIM, BAR_ANIM
BS.FADE_IN, BS.FADE_OUT = 0.18, 0.30
BS.GLOW_SCALE = 1.5
-- only the consumables bar has ever had an expiry glow
local GLOW_BARS = { consumablesHelper = true }
BS.GLOW_BARS = GLOW_BARS

local EMPTY = {}

function BS.KeyOf(button)
    if not button then return "consumablesHelper" end
    if button._rcBarKey then return button._rcBarKey end
    if button.isPotionBar then return "potionsBar" end
    if button.isWeaponsBar then return "weaponsBar" end
    if button.trinketData then return "trinketBar" end
    return "consumablesHelper"
end

-- The bar's style table for reading (never nil, never written through).
function BS.Get(barKey)
    local d = RC.db and RC.db[barKey]
    local s = d and d.style
    return type(s) == "table" and s or EMPTY
end

-- The bar's style table for writing (created on first write).
function BS.Edit(barKey)
    if not RC.db then return {} end
    RC.db[barKey] = RC.db[barKey] or {}
    local d = RC.db[barKey]
    if type(d.style) ~= "table" then d.style = {} end
    return d.style
end

-- Font size today for an element at a button size.
function BS.DefaultSize(elem, size, cfg)
    local t = BS.TEXT[elem]
    if not t then return 12 end
    if t.fixed then return t.fixed end
    local k = t.k
    if t.scaleKey and cfg then k = k * (tonumber(cfg[t.scaleKey]) or 1) end
    return math_max(t.min, math_floor((size or 36) * k))
end

function BS.FontDefaults(elem, size, cfg)
    return { size = BS.DefaultSize(elem, size, cfg), outline = "OUTLINE", shadow = true }
end

-- Styles one font string; keeps the element's own shadow depth.
function BS.ApplyFont(fs, barKey, elem, size)
    if not (fs and fs.SetFont) then return end
    local cfg = RC.db and RC.db[barKey]
    local spec = BS.Get(barKey)[FONT_KEY[elem]]
    local defaults = BS.FontDefaults(elem, size, cfg)
    RC:ApplyFontSpec(fs, type(spec) == "table" and spec or nil, defaults)
    local _, _, _, shadow = RC:ResolveFontSpec(spec, defaults)
    if shadow then
        local off = BS.TEXT[elem].sh or 1
        fs:SetShadowOffset(off, -off)
        fs:SetShadowColor(0, 0, 0, 1)
    end
end

-- r, g, b, a for a colour key; elemDefault (an array) overrides the
-- shared default for elements that always had their own shade.
function BS.Color(barKey, key, elemDefault)
    local c = BS.Get(barKey)[key]
    if type(c) == "table" and c.r then return c.r, c.g or 0, c.b or 0, c.a or 1 end
    local d = elemDefault or BS.COLOR_DEFAULTS[key] or P.white
    if type(d) == "function" then d = d() end
    return d[1], d[2], d[3], d[4] or 1
end

-- The default as a colour table (pickers).
function BS.DefaultColor(key)
    local d = BS.COLOR_DEFAULTS[key] or P.white
    if type(d) == "function" then d = d() end
    return { r = d[1], g = d[2], b = d[3], a = d[4] or 1 }
end

-- Colours a font string from a key; the old cached colour key it stands
-- for is kept so a restyle can repaint it.
function BS.Paint(fs, button, key, elemDefault)
    if not fs then return end
    fs:SetTextColor(BS.Color(BS.KeyOf(button), key, elemDefault))
end

-- The cached colour keys the runtime writes, mapped to style keys.
local CACHED = {
    count = { white = "countColor", red = "emptyColor" },
    expiryText = { gold = "expirySoonColor", red = "expiryUrgentColor" },
    weaponTimeText = { green = "timerGoodColor", gold = "timerMidColor", red = "timerLowColor" },
    timeLabel = { green = "timerGoodColor", yellow = "timerMidColor", red = "timerLowColor" },
}

function BS.Spec(barKey, which)
    local s = BS.Get(barKey)[which]
    local d = (which == "glowAnim") and GLOW_ANIM or BAR_ANIM
    return RC.Motion.Normalize(type(s) == "table" and s or nil, d)
end

function BS.GlowOn(barKey)
    local v = BS.Get(barKey).glowEnabled
    if v == nil then return GLOW_BARS[barKey] == true end
    return v and true or false
end

------------------------------------------------------------------------
-- The customization standard on the bars: db[barKey].anchors.<elem> moves
-- a text (or the expiry glow) anywhere on or around its button,
-- db[barKey].formats.<cooldown|expiry|timer> words its time. Nothing is
-- touched until a spec is set: every text sits where the dress put it.
------------------------------------------------------------------------
local function A(p, x, y, j) return { point = p, relPoint = p, x = x, y = y, to = "button", justify = j } end
BS.ANCHOR_DEFAULTS = {
    count = A("BOTTOMRIGHT", -1, 1), cooldown = A("CENTER", 3, 0), gcd = A("CENTER", 0, 0),
    duration = A("CENTER", 0, 0), expiry = A("CENTER", 0, 0), timer = A("TOPRIGHT", -1, -1),
    slot = A("TOPLEFT", 2, -2), absorb = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0, to = "absorbBox" },
    name = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 2, y = -2, to = "button", justify = "CENTER",
             point2 = "TOPRIGHT", relPoint2 = "TOPRIGHT", x2 = -2, y2 = -2, to2 = "button" },
    tcooldown = A("CENTER", 0, 0), tbuff = A("CENTER", 0, 0),
    tslot = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0, to = "slotBox" },
    glow = A("CENTER", 0, 0),
}
-- a weapon button's name sits under the slot label, on its own
local NAME_WEAPON = A("TOPLEFT", 2, -12, "LEFT")
function BS.AnchorDefault(elem, button)
    if elem == "name" and button and button.itemData then
        local d = button.itemData
        if d.slot or d.isBagWeapon or d.isUnifiedWeaponButton then return NAME_WEAPON end
    end
    return BS.ANCHOR_DEFAULTS[elem]
end
-- what each element can hang off (the page's "Anchor to")
BS.ANCHOR_TARGETS = {
    { value = "button", text = RCL["The button"] }, { value = "count", text = RCL["Stack count"] },
    { value = "cooldown", text = RCL["Cooldown"] }, { value = "timer", text = RCL["Minutes left"] },
    { value = "slot", text = RCL["Weapon slot"] }, { value = "name", text = RCL["Item names"] },
}
BS.FORMAT_DEFAULTS = { cooldown = { time = "short" }, expiry = { time = "seconds" }, timer = { time = "short" } }

local function SpecTable(barKey, family)
    local d = RC.db and RC.db[barKey]
    local t = d and d[family]
    return type(t) == "table" and t or nil
end
BS.SpecTable = SpecTable

local function ButtonTo(button)
    if not button._rcAnchorTo then
        button._rcAnchorTo = function(k)
            if k == "button" then return button
            elseif k == "absorbBox" then return button.absorbContainer or button
            elseif k == "slotBox" then return button.slotBg or button
            elseif k == "glow" then return button.expiryGlowFrame end
            local f = FIELDS[k]
            if f then return button[f[1]] or button[f[2] or ""] end
        end
    end
    return button._rcAnchorTo
end

-- Every text with a spec placed (and one whose spec was cleared put back).
function BS.PlaceTexts(button, barKey)
    local a = SpecTable(barKey, "anchors")
    if not (a or button._rcAnchored) then return end
    button._rcAnchored = a ~= nil
    local to = ButtonTo(button)
    local elems = (barKey == "trinketBar") and TRINKET_ELEMS or BAR_ELEMS
    for _, elem in ipairs(elems) do
        local spec = a and a[elem]
        for _, field in ipairs(FIELDS[elem]) do
            local fs = button[field]
            if fs and (spec or fs._rcAnch) then
                RC.UI:ApplyAnchor(fs, spec, BS.AnchorDefault(elem, button), to)
                fs._rcAnch = spec ~= nil
            end
        end
    end
    local g = button.expiryGlowFrame
    if g and ((a and a.glow) or g._rcAnch) then
        RC.UI:ApplyAnchor(g, a and a.glow, BS.ANCHOR_DEFAULTS.glow, to)
        g._rcAnch = (a and a.glow) ~= nil
    end
end

-- The count's corner, as the refresh passes have always re-set it.
function BS.PlaceCount(button)
    local fs = button and button.count
    if not fs then return end
    local a = SpecTable(BS.KeyOf(button), "anchors")
    if a and a.count then
        RC.UI:ApplyAnchor(fs, a.count, BS.ANCHOR_DEFAULTS.count, ButtonTo(button))
        fs._rcAnch = true
    else
        fs:ClearAllPoints()
        fs:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
        fs._rcAnch = nil
    end
end

-- A time worded by the bar's format for that text, or nil (no format:
-- the setter keeps its own wording).
local fmtValues, fmtKinds = {}, { value = "time" }
function BS.FormatTimeText(button, elem, seconds)
    local f = SpecTable(BS.KeyOf(button), "formats")
    local spec = f and f[elem]
    if not spec then return nil end
    fmtValues.value = seconds
    return RC.UI:FormatText(spec, BS.FORMAT_DEFAULTS[elem], fmtValues, fmtKinds, "value")
end

------------------------------------------------------------------------
-- Buttons
------------------------------------------------------------------------

-- Fonts, the steady colours and the glow size of one bar button. Cheap
-- when nothing changed (a signature per button), so the rebuild calls it
-- for every button; RestyleBar clears the signatures.
function RC:StyleBarButton(button, barKey, size)
    if not button then return end
    barKey = barKey or BS.KeyOf(button)
    size = size or (button.GetWidth and button:GetWidth()) or 36
    if size <= 0 then size = 36 end
    local gen = BS._gen or 0
    local elems = (barKey == "trinketBar") and TRINKET_ELEMS or BAR_ELEMS
    -- which strings exist: a pooled button can grow one later
    local mask, bit = 0, 1
    for _, elem in ipairs(elems) do
        for _, field in ipairs(FIELDS[elem]) do
            if button[field] then mask = mask + bit end
            bit = bit * 2
        end
    end
    local sig = size
    if barKey == "trinketBar" then
        -- the menu's text also scales with its own slider
        local cfg = RC.db and RC.db.trinketBar
        sig = size .. ":" .. tostring(cfg and cfg.cooldownTextScale or 1)
    end
    -- texts moved by the settings (cheap when none are)
    BS.PlaceTexts(button, barKey)
    if button._rcStyleSig == sig and button._rcStyleGen == gen and button._rcStyleMask == mask then return end
    button._rcStyleSig, button._rcStyleGen, button._rcStyleMask = sig, gen, mask
    -- a restyle may have changed a time format: the next pass rewrites them
    for _, field in ipairs({ "cooldownText", "expiryText", "weaponTimeText", "timeLabel" }) do
        local fs = button[field]
        if fs then fs._cachedText = nil end
    end
    for _, elem in ipairs(elems) do
        for _, field in ipairs(FIELDS[elem]) do
            local fs = button[field]
            if fs then BS.ApplyFont(fs, barKey, elem, size) end
        end
    end
    if barKey == "trinketBar" then
        BS.Paint(button.cooldownText, button, "tcooldownColor")
        BS.Paint(button.buffDurationText, button, "tbuffColor")
        BS.Paint(button.slotText, button, "tslotColor")
    else
        BS.Paint(button.cooldownText, button, "cooldownColor")
        BS.Paint(button.gcdText, button, "gcdColor")
        BS.Paint(button.durationText, button, "durationColor")
        BS.Paint(button.nameLabel, button, "nameColor")
        if button.slotLabel and not (button.itemData and button.itemData.isBagWeapon) then
            BS.Paint(button.slotLabel, button, "slotColor")
        end
        -- text whose colour follows its state: repaint from the cached key
        for field, map in pairs(CACHED) do
            local fs = button[field]
            local ck = fs and fs._cachedColorKey
            if ck and map[ck] then
                local def = (field == "timeLabel") and TIMELABEL_DEFAULTS[map[ck]] or nil
                BS.Paint(fs, button, map[ck], def)
            end
        end
        if button.expiryGlow then
            local k = tonumber(BS.Get(barKey).glowScale) or BS.GLOW_SCALE
            button.expiryGlow:SetSize(size * k, size * k)
            button.expiryGlow:SetVertexColor(BS.Color(barKey, "glowColor"))
            if button.expiryGlowFrame then button.expiryGlowFrame:SetSize(size, size) end
        end
    end
end

-- The centred cooldown seconds ("2m" past a minute). Hidden while the
-- client draws its own cooldown numbers.
function RC:SetBarButtonCooldownText(button, remaining)
    local fs = button and button.cooldownText
    if not fs then return end
    local newText = BS.FormatTimeText(button, "cooldown", remaining)
    if not newText then
        if remaining > 60 then
            newText = string.format("%dm", math.ceil(remaining / 60))
        else
            newText = string.format("%d", math.ceil(remaining))
        end
    end
    if fs._cachedText ~= newText then
        fs:SetText(newText)
        fs._cachedText = newText
    end
    if not self.ShouldShowOwnCooldownText or self:ShouldShowOwnCooldownText() then fs:Show() else fs:Hide() end
end

-- The count in the bottom corner (white, red at zero).
function RC:SetBarButtonCount(button, count)
    local fs = button and button.count
    if not fs then return end
    local newText = (count and count > 0) and tostring(count) or "0"
    local recolor = false
    if fs._cachedText ~= newText then
        fs:SetText(newText)
        fs._cachedText = newText
        recolor = true
    end
    if recolor or not fs._cachedColorKey then
        if count and count > 0 then
            BS.Paint(fs, button, "countColor")
            fs._cachedColorKey = "white"
        else
            BS.Paint(fs, button, "emptyColor")
            fs._cachedColorKey = "red"
        end
    end
end

-- The big centred seconds inside the warning window: gold, red in the
-- last half of it. Shared by the live state pass and the samples.
function RC:SetBarButtonExpiryText(button, displayTime, threshold, chargeText)
    local fs = button and button.expiryText
    if not fs then return end
    local newText = chargeText or BS.FormatTimeText(button, "expiry", displayTime) or string.format("%d", math.ceil(displayTime))
    if fs._cachedText ~= newText then
        fs:SetText(newText)
        fs._cachedText = newText
    end
    local urgent = displayTime < (threshold or 60) * 0.5
    local colorKey = urgent and "red" or "gold"
    if fs._cachedColorKey ~= colorKey then
        BS.Paint(fs, button, urgent and "expiryUrgentColor" or "expirySoonColor")
        fs._cachedColorKey = colorKey
    end
    fs:Show()
end

-- The corner minutes while a weapon enchant is healthy (weapons bar and
-- oil buttons): green, gold under 5 minutes, red under one.
function RC:SetBarButtonWeaponTime(button, displayTime)
    local fs = button and button.weaponTimeText
    if not fs then return end
    local newText = BS.FormatTimeText(button, "timer", displayTime) or tostring(math.ceil(displayTime / 60))
    if fs._cachedText ~= newText then
        fs:SetText(newText)
        fs._cachedText = newText
    end
    local colorKey = (displayTime < 60 and "red") or (displayTime < 300 and "gold") or "green"
    if fs._cachedColorKey ~= colorKey then
        BS.Paint(fs, button, CACHED.weaponTimeText[colorKey])
        fs._cachedColorKey = colorKey
    end
    fs:Show()
end

-- The slot buttons' corner label (hours past an hour, else minutes).
function RC:SetBarButtonTimeLabel(button, timeRemaining)
    local fs = button and button.timeLabel
    if not fs then return end
    local timeStr = BS.FormatTimeText(button, "timer", timeRemaining)
    if timeStr then
        -- the bar's own wording for the minutes left
    elseif timeRemaining >= 3600 then
        timeStr = tostring(math_floor(timeRemaining / 3600))
    else
        timeStr = tostring(math.ceil(timeRemaining / 60))
    end
    if fs._cachedText ~= timeStr then
        fs:SetText(timeStr)
        fs._cachedText = timeStr
    end
    local colorKey = (timeRemaining > 300 and "green") or (timeRemaining > 60 and "yellow") or "red"
    if fs._cachedColorKey ~= colorKey then
        local key = CACHED.timeLabel[colorKey]
        BS.Paint(fs, button, key, TIMELABEL_DEFAULTS[key])
        fs._cachedColorKey = colorKey
    end
    fs:Show()
end

-- The expiry glow: a halo round the button while its buff is inside the
-- warning window, animated by the bar's glow animation (RC.Motion, so the
-- global Motion switches apply; with animations off it holds steady).
function RC:SetBarButtonGlow(button, on)
    local f = button and button.expiryGlowFrame
    if not f then return end
    local barKey = BS.KeyOf(button)
    if on and BS.GlowOn(barKey) then
        local M = RC.Motion
        if not f:IsShown() then
            f:Show()
            M.Play(f, BS.Spec(barKey, "glowAnim"), "update")
        elseif not M.IsPlaying(f) then
            -- a loop ends while its bar is hidden: pick it up again
            local spec = BS.Spec(barKey, "glowAnim")
            if spec.loop and M.LOOPS[spec.style] then M.Play(f, spec, "update") end
        end
    elseif f:IsShown() then
        RC.Motion.Stop(f)
        f:Hide()
    end
end

-- Every button of a bar restyled now (a style setting changed).
function RC:RestyleBar(barKey)
    BS._gen = (BS._gen or 0) + 1
    local bar = self[barKey]
    -- layer / clamp, fade rules, shadow / glow on the bar frame (the
    -- standard; its own scale, fill and edge stay its own)
    if bar and bar.frame and self.ApplyFrameCustom then
        self:ApplyFrameCustom(bar.frame, function() return RC.db and RC.db[barKey] end, { scale = false })
    end
    if not (bar and bar.buttons) then return end
    local size = self.db and self.db[barKey] and self.db[barKey].buttonSize or 36
    for _, button in pairs(bar.buttons) do
        self:StyleBarButton(button, barKey, size)
        local f = button.expiryGlowFrame
        if f and f:IsShown() then
            -- a new animation or the glow switched off
            RC.Motion.Stop(f)
            f:Hide()
            self:SetBarButtonGlow(button, true)
        end
    end
end

function RC:RestyleAllBars()
    for _, k in ipairs({ "consumablesHelper", "potionsBar", "weaponsBar", "trinketBar" }) do
        self:RestyleBar(k)
    end
end

------------------------------------------------------------------------
-- Bar chrome: the frame's fill, 1px edge (gold while unlocked) and the
-- accent hairlines, from the bar's Appearance > Colors category. One body
-- for the four bars and the samples.
------------------------------------------------------------------------
BS.COLOR_CAT = { consumablesHelper = "consumablesBar", potionsBar = "potionsBar",
    weaponsBar = "weaponBar", trinketBar = "weaponBar" }
local EDGES = { "top", "bottom", "left", "right" }
function RC:PaintBarChrome(frame, cat, showBg, unlocked)
    if not frame then return end
    local bg, bc = self:GetColor(cat, "frameBackground"), self:GetColor(cat, "frameBorder")
    local border = frame.border or EMPTY
    for _, k in ipairs(EDGES) do
        local t = border[k]
        if t then
            t:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
            if showBg then t:Show() else t:Hide() end
        end
    end
    if frame.bg then
        if showBg then
            frame.bg:SetColorTexture(bg.r, bg.g, bg.b, bg.a or 0.90)
        else
            frame.bg:SetColorTexture(0, 0, 0, 0)
        end
    end
    if unlocked then
        local gc = self:GetColor("ui", "accentGold")
        for _, k in ipairs(EDGES) do
            local t = border[k]
            if t then t:SetColorTexture(gc.r, gc.g, gc.b, 0.9) t:Show() end
        end
    end
    local ac = self:GetColor(cat, "accentLine") or bc
    for _, t in pairs(frame.accentLine or EMPTY) do
        t:SetColorTexture(ac.r, ac.g, ac.b, (ac.a or 1) * 0.5)
    end
    if self.SyncBarChrome then self:SyncBarChrome(frame, showBg) end
end

------------------------------------------------------------------------
-- Bar entrance and exit
------------------------------------------------------------------------
-- In combat (the bar holds secure buttons) the old instant Show/Hide is
-- kept exactly; out of it the bar's animation plays. A show during an
-- exit turns it round. The bar is marked protected for RC.Motion, which
-- then finishes an entrance or exit still playing when combat starts.
local function MarkProtected(f)
    if not f._rcBarProtected and RC.Motion.SetProtected then
        f._rcBarProtected = true
        RC.Motion.SetProtected(f, true)
    end
end

function RC:ShowBarFrame(barKey)
    local f = self[barKey] and self[barKey].frame
    if not f then return end
    MarkProtected(f)
    local st = f._rcMotion
    local leaving = st and st.how == "out"
    if f:IsShown() and not leaving then return end
    if InCombatLockdown() then
        if st then RC.Motion.Stop(f) end
        f:Show()
        return
    end
    RC.Motion.Show(f, BS.Spec(barKey, "showAnim"))
end

function RC:HideBarFrame(barKey)
    local f = self[barKey] and self[barKey].frame
    if not (f and f:IsShown()) then return end
    MarkProtected(f)
    local st = f._rcMotion
    if st and st.how == "out" then return end
    if InCombatLockdown() then
        if st then RC.Motion.Stop(f) end
        f:Hide()
        return
    end
    RC.Motion.Hide(f, BS.Spec(barKey, "hideAnim"))
end

------------------------------------------------------------------------
-- Mouseover fade lengths
------------------------------------------------------------------------
-- A bar's fade getter hands these to the core fade (UIF_Anim) as fadeIn /
-- fadeOut, which it reads itself.
function BS.FadeTimes(barKey)
    local s = BS.Get(barKey)
    return tonumber(s.fadeIn) or BS.FADE_IN, tonumber(s.fadeOut) or BS.FADE_OUT
end

------------------------------------------------------------------------
-- A global font change re-applies fixed sizes to the bar buttons
-- (FontSystem's UpdateAllFonts); put their own styles back after it.
------------------------------------------------------------------------
if RC.UpdateAllFonts and not RC._rcBarFontsWrapped then
    RC._rcBarFontsWrapped = true
    local rawUpdate = RC.UpdateAllFonts
    function RC:UpdateAllFonts(...)
        local r = rawUpdate(self, ...)
        if self.RestyleAllBars then self:RestyleAllBars() end
        return r
    end
end

------------------------------------------------------------------------
-- Grid position of the index-th button (today's formula, shared by the
-- samples): x from the bar's left, y from its top.
------------------------------------------------------------------------
function BS.GridOffset(index, perRow, size, spacing, growDir)
    local row, col
    if growDir == "DOWN" then
        row = math_floor((index - 1) / perRow)
        col = (index - 1) % perRow
    else
        col = math_floor((index - 1) / perRow)
        row = (index - 1) % perRow
    end
    return 5 + col * (size + spacing), -5 - row * (size + spacing), row, col
end

-- Bar size for n buttons (today's formula).
function BS.BarSize(n, perRow, size, spacing, growDir)
    local cols, rows
    if growDir == "DOWN" then
        cols = math.min(n, perRow)
        rows = math.ceil(n / perRow)
    else
        cols = math.ceil(n / perRow)
        rows = math.min(n, perRow)
    end
    return 10 + cols * size + (cols - 1) * spacing, 10 + rows * size + (rows - 1) * spacing
end
