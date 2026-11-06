------------------------------------------------------------------------
-- Readycheck - Bar pages: shared Look / Text / Animation / Position tabs
-- and the pane preview for the consumables, potions and weapons bars and
-- the trinket menu. Every sample is built by the bars' own code
-- (DressBarButton / DressTrinketButton, StyleBarButton, PaintBarChrome,
-- the state setters in Consumables_Style) with made-up items, so the pane
-- shows exactly what the bar draws. Settings: db[barKey].style (see
-- Consumables_Style.lua) plus the bars' existing keys and theme colours.
-- Published as RC._sbc.BarPages; the bar pages load after this file.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
local pairs, ipairs, type, tostring = pairs, ipairs, type, tostring
local math_floor, math_min, math_max = math.floor, math.min, math.max
local CreateFrame = CreateFrame
RC._sbc = RC._sbc or {}
local _sbc = RC._sbc
local TEXT = _sbc.TEXT or RC.UI.TEXT or {}

local CBS = {}
_sbc.BarPages = CBS

-- Old tab keys (search aliases, saved frame state) -> the tabs now.
CBS.LEGACY_TABS = { general = "behavior", display = "look", visibility = "behavior" }
function CBS.Tab(key, default)
    if not key then return default end
    return CBS.LEGACY_TABS[key] or key
end

------------------------------------------------------------------------
-- Per bar
------------------------------------------------------------------------
local function BS() return RC.BarStyle end

local function Rebuild(barKey)
    if InCombatLockdown() then return end
    if barKey == "consumablesHelper" then RC:UpdateConsumablesButtons()
    elseif barKey == "potionsBar" then RC:UpdatePotionsButtons()
    elseif barKey == "weaponsBar" then RC:UpdateWeaponsButtons()
    elseif barKey == "trinketBar" then RC:UpdateTrinketBarButtons() end
end

local BARS = {
    consumablesHelper = {
        page = "ShowSidebarConsumablesHelperConfig", tabField = "consumablesBarTab",
        title = RCL["Consumables bar"], glow = true, fade = true,
        text = { "count", "cooldown", "gcd", "duration", "expiry", "timer", "name", "slot" },
        extraColors = { { "conflictBackground", RCL["Clashing buff fill"] }, { "conflictBorder", RCL["Clashing buff edge"] } },
        create = function() if not RC.consumablesHelper.frame then RC:CreateConsumablesHelperFrame() end end,
        background = function() RC:UpdateConsumablesHelperBackground() end,
        visibility = function() RC:UpdateConsumablesVisibility() end,
        fadeApply = function() if RC.UpdateConsumablesBarMouseoverFade then RC:UpdateConsumablesBarMouseoverFade() end end,
        lock = function()
            RC:UpdateConsumablesHelperTitleVisibility()
            RC:UpdateConsumablesButtons()
        end,
    },
    potionsBar = {
        page = "ShowSidebarPotionsBarConfig", tabField = "potionsBarTab",
        title = RCL["Potions bar"], fade = true,
        text = { "count", "cooldown", "gcd", "expiry", "name", "absorb" },
        create = function() if not RC.potionsBar.frame then RC:CreatePotionsBarFrame() end end,
        background = function() RC:UpdatePotionsBarBackground() end,
        visibility = function() RC:UpdatePotionsVisibility() end,
        fadeApply = function() if RC.UpdatePotionsBarMouseoverFade then RC:UpdatePotionsBarMouseoverFade() end end,
        lock = function()
            RC:UpdatePotionsBarTitleVisibility()
            RC:UpdatePotionsButtons()
        end,
    },
    weaponsBar = {
        page = "ShowSidebarWeaponsBarConfig", tabField = "weaponsBarTab",
        title = RCL["Weapons bar"], fade = true,
        text = { "count", "cooldown", "gcd", "duration", "expiry", "timer", "name", "slot" },
        sharedColors = RCL["The weapons bar and the trinket menu share these colours."],
        create = function() if not RC.weaponsBar.frame then RC:CreateWeaponsBarFrame() end end,
        background = function() RC:UpdateWeaponsBarBackground() end,
        visibility = function() RC:UpdateWeaponsVisibility() end,
        fadeApply = function() if RC.UpdateWeaponsBarMouseoverFade then RC:UpdateWeaponsBarMouseoverFade() end end,
        lock = function(on)
            local f = RC.weaponsBar.frame
            if f and f.titleText then if on then f.titleText:Hide() else f.titleText:Show() end end
            RC:UpdateWeaponsButtons()
        end,
    },
    trinketBar = {
        page = "ShowSidebarTrinketBarConfig", tabField = "trinketBarTab",
        title = RCL["Trinket menu"],
        text = { "tcooldown", "tbuff", "tslot" },
        sharedColors = RCL["The weapons bar and the trinket menu share these colours."],
        create = function() if not RC.trinketBar.frame then RC:CreateTrinketBarFrame() end end,
        background = function() RC:UpdateTrinketBarBackground() end,
        visibility = function() RC:UpdateTrinketBarVisibility() end,
        lock = function(on)
            local f = RC.trinketBar.frame
            if f and f.titleText then if on then f.titleText:Hide() else f.titleText:Show() end end
            RC:UpdateTrinketBarButtons()
        end,
    },
}
CBS.BARS = BARS

-- Text elements: label, what it is, and its colour keys.
local ELEM = {
    count    = { RCL["Stack count"], RCL["How many you carry, in the bottom corner."],
                 { { "countColor", RCL["Count colour"] }, { "emptyColor", RCL["Colour when you have none"] } }, "12" },
    cooldown = { RCL["Cooldown"], RCL["Seconds left on the item's own cooldown, in the middle."],
                 { { "cooldownColor", RCL["Cooldown colour"] } }, "47" },
    gcd      = { RCL["Global cooldown"], RCL["The short countdown right after you click a button."],
                 { { "gcdColor", RCL["Global cooldown colour"] } }, "1" },
    duration = { RCL["Eating and casting"], RCL["The countdown while you eat, drink or apply a stone or oil."],
                 { { "durationColor", RCL["Eating and casting colour"] } }, "18" },
    expiry   = { RCL["Running out"], RCL["The big seconds once a buff is inside its warning time; red in the last half."],
                 { { "expirySoonColor", RCL["Running low colour"] }, { "expiryUrgentColor", RCL["Nearly gone colour"] } }, "42" },
    timer    = { RCL["Minutes left"], RCL["The minutes left on a weapon stone or oil, in the top corner."],
                 { { "timerGoodColor", RCL["Plenty left colour"] }, { "timerMidColor", RCL["Under five minutes colour"] }, { "timerLowColor", RCL["Under a minute colour"] } }, "28" },
    name     = { RCL["Item names"], RCL["The short item name across the top, when names are on."],
                 { { "nameColor", RCL["Item name colour"] } }, "Mongoose" },
    slot     = { RCL["Weapon slot"], RCL["MH and OH on the weapon buttons."],
                 { { "slotColor", RCL["Weapon slot colour"] } }, "MH  OH" },
    absorb   = { RCL["Absorb amount"], RCL["The shield left on a protection potion's bar."], {}, "1950" },
    tcooldown = { RCL["Cooldown"], RCL["Time left on a trinket's cooldown."],
                 { { "tcooldownColor", RCL["Cooldown colour"] } }, "1m" },
    tbuff    = { RCL["Buff time left"], RCL["Time left on a trinket's buff while it is up."],
                 { { "tbuffColor", RCL["Buff time colour"] } }, "18" },
    tslot    = { RCL["Slot number"], RCL["1 or 2 on the trinkets you wear."],
                 { { "tslotColor", RCL["Slot number colour"] } }, "1  2" },
}
CBS.ELEM = ELEM

------------------------------------------------------------------------
-- Small helpers
------------------------------------------------------------------------
-- one gray line at most; the rest in its tooltip (RC.UI:CreateHelpLine)
local function Desc(card, y, text, x)
    return (RC.UI:CreateHelpLine(card, x or 14, y, text))
end
CBS.Desc = Desc

local function Label(card, y, text)
    local l = RC:CreateFontString(card, "OVERLAY", nil, 11)
    l:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
    l:SetText(text)
    local c = RC:GetColor("text", "normal")
    l:SetTextColor(c.r, c.g, c.b)
    return l
end

-- A style setting changed: save, and the live bar follows at once.
local function Changed(barKey)
    RC:SaveConfigurationToProfile()
    RC:RestyleBar(barKey)
end
CBS.Changed = Changed

local function Copy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = v end
    return o
end

local function Card(self, parent, yPos, title)
    local card = self:CreateSettingsCard(parent, yPos, title)
    return card, -32
end
local function EndCard(card, cy, yPos)
    card:SetContentHeight(math.abs(cy))
    return yPos - card:GetHeight() - 15
end

------------------------------------------------------------------------
-- Look: theme colours of the bar and the expiry glow
------------------------------------------------------------------------
local function RepaintLive(barKey)
    local B = BARS[barKey]
    if B.background then B.background() end
    local bar = RC[barKey]
    for _, b in pairs(bar and bar.buttons or {}) do b._cachedStateKey = nil end
    Rebuild(barKey)
end

function CBS.BuildLook(self, frame, barKey, parent, yPos)
    local B = BARS[barKey]
    local cat = RC.BarStyle.COLOR_CAT[barKey]
    local card, cy = Card(self, parent, yPos, RCL["Bar colours"])
    cy = Desc(card, cy, RCL["The bar's background, edge and button edges. They are the same colours as Appearance > Colors."])
    if B.sharedColors then cy = Desc(card, cy, B.sharedColors) end
    local rows = {
        { "frameBackground", RCL["Background"] }, { "frameBorder", RCL["Edge"] },
        { "accentLine", RCL["Accent line"] }, { "buttonBorder", RCL["Button edge"] },
        { "activeBorder", RCL["Button edge while the buff is up"] },
    }
    for _, r in ipairs(B.extraColors or {}) do rows[#rows + 1] = r end
    for _, r in ipairs(rows) do
        local key = r[1]
        local cp = self.UI:CreateColorPicker(card, {
            label = r[2], width = 420, alpha = true,
            get = function() return RC:GetColor(cat, key) end,
            set = function(rr, g, b, a) RC:SetColor(cat, key, rr, g, b, a) RepaintLive(barKey) end,
            default = RC.defaultColors and RC.defaultColors[cat] and RC.defaultColors[cat][key],
            isChanged = function()
                local cc = RC.db.customColors
                return cc and cc[cat] and cc[cat][key] ~= nil
            end,
            reset = function() RC:ResetColor(cat, key) RepaintLive(barKey) end,
        })
        cp:SetPoint("TOPLEFT", card, "TOPLEFT", 10, cy)
        cy = cy - 28
    end
    cy = cy - 4
    yPos = EndCard(card, cy, yPos)

    if B.glow then
        local S = RC.BarStyle
        local gcard, gy = Card(self, parent, yPos, RCL["Expiry glow"])
        gy = Desc(gcard, gy, RCL["A glow round a button while its buff is about to run out (inside the warning time on the Behavior tab)."])
        self.UI:CreateSettingCheckbox(gcard, gy, RCL["Glow when a buff is running out"], S.GlowOn(barKey), function(cb)
            S.Edit(barKey).glowEnabled = cb:GetChecked() and true or false
            RC:ForceCheckboxUpdate(cb, S.Edit(barKey).glowEnabled)
            Changed(barKey)
        end)
        gy = gy - 30
        Label(gcard, gy, RCL["Glow size"])
        gy = gy - 20
        local cur = math_floor((tonumber(S.Get(barKey).glowScale) or S.GLOW_SCALE) * 100 + 0.5)
        local sl = self.UI:CreateSlider(gcard, 100, 250, cur, 5)
        sl:SetPoint("TOPLEFT", gcard, "TOPLEFT", 14, gy)
        sl.Text:SetText(cur .. "%")
        sl:SetScript("OnValueChanged", function(s, v)
            v = math_floor(v / 5 + 0.5) * 5
            s.Text:SetText(v .. "%")
            S.Edit(barKey).glowScale = v / 100
            Changed(barKey)
        end)
        gy = gy - 46
        local cp = self.UI:CreateColorPicker(gcard, {
            label = RCL["Glow colour"], width = 420, alpha = true,
            get = function() return S.Get(barKey).glowColor end,
            set = function(r, g, b, a) S.Edit(barKey).glowColor = { r = r, g = g, b = b, a = a or 1 } Changed(barKey) end,
            default = S.DefaultColor("glowColor"),
            isChanged = function() return type(S.Get(barKey).glowColor) == "table" end,
            reset = function() S.Edit(barKey).glowColor = nil Changed(barKey) end,
        })
        cp:SetPoint("TOPLEFT", gcard, "TOPLEFT", 10, gy)
        gy = gy - 32
        yPos = EndCard(gcard, gy, yPos)
    end
    yPos = RC.UI:FrameChromeCard(parent, yPos, function() return RC.db[barKey] end, function() Changed(barKey) end,
        { title = RCL["Shadow and glow"], fields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })
    return yPos
end

------------------------------------------------------------------------
-- Text: a font and colour(s) per text element
------------------------------------------------------------------------
-- every place a text can hang off but itself
local function Others(elem)
    local out = {}
    for _, t in ipairs(RC.BarStyle.ANCHOR_TARGETS) do if t.value ~= elem then out[#out + 1] = t end end
    return out
end
function CBS.BuildText(self, frame, barKey, parent, yPos)
    local S = RC.BarStyle
    local B = BARS[barKey]
    local cfg = RC.db[barKey] or {}
    local size = cfg.buttonSize or 36
    local intro, iy = Card(self, parent, yPos, RCL["Button text"])
    iy = Desc(intro, iy, RCL["Each piece of text on the buttons has its own font and colour. Until you move a size slider the text keeps scaling with the button size. The Readycheck font follows Appearance > Fonts."])
    local reset = self.UI:CreateStyledButton(intro, RCL["Put back the default text"], 190, 22)
    reset:SetPoint("TOPLEFT", intro, "TOPLEFT", 14, iy)
    reset:SetScript("OnClick", function()
        local st = S.Edit(barKey)
        for _, elem in ipairs(B.text) do
            st[S.FONT_KEY[elem]] = nil
            for _, c in ipairs(ELEM[elem][3]) do st[c[1]] = nil end
        end
        -- and every text back in its place, worded as it always was
        local bdb = RC.db[barKey]
        if type(bdb.anchors) == "table" then
            for _, elem in ipairs(B.text) do bdb.anchors[elem] = nil end
            if next(bdb.anchors) == nil then bdb.anchors = nil end
        end
        bdb.formats = nil
        Changed(barKey)
        RC.UI:NotifySettingChanged("reset")
        RC[B.page](RC, frame, true)
    end)
    iy = iy - 32
    yPos = EndCard(intro, iy, yPos)

    -- one group per text: font, colour(s), wording (the timers) and where
    -- it sits on the button (the customization standard's text element)
    local function Root() return RC.db[barKey] end
    local function After() Changed(barKey) end
    for _, elem in ipairs(B.text) do
        local info = ELEM[elem]
        local fkey = S.FONT_KEY[elem]
        local card, cy = Card(self, parent, yPos, info[1])
        cy = Desc(card, cy, info[2])
        local cw = card:GetWidth() or 0
        local W = (cw > 240) and math_min(460, cw - 28) or 420
        local colors = {}
        for _, c in ipairs(info[3]) do
            local key = c[1]
            colors[#colors + 1] = { label = c[2], alpha = true,
                get = function() return S.Get(barKey)[key] end,
                set = function(r, g, b, a) S.Edit(barKey)[key] = { r = r, g = g, b = b, a = a or 1 } Changed(barKey) end,
                default = S.DefaultColor(key),
                isChanged = function() return type(S.Get(barKey)[key]) == "table" end,
                reset = function() S.Edit(barKey)[key] = nil Changed(barKey) end }
        end
        local ag, as = self.UI:CustomAccess(Root, "anchors", elem, After)
        local o = { key = elem, width = W,
            font = { get = function() return S.Get(barKey)[fkey] end,
                set = function(spec) S.Edit(barKey)[fkey] = spec Changed(barKey) end,
                defaults = S.FontDefaults(elem, size, cfg), minSize = 6, maxSize = 40, sample = info[4] },
            colors = (#colors > 0) and colors or nil,
            anchorGet = ag, anchorSet = as, anchorDefaults = function() return S.AnchorDefault(elem) end,
            targets = Others(elem), defaultTargetLabel = RCL["Where it always sits"] }
        if S.FORMAT_DEFAULTS[elem] and barKey ~= "trinketBar" then
            local fg, fs = self.UI:CustomAccess(Root, "formats", elem, After)
            local def = S.FORMAT_DEFAULTS[elem]
            local sampleSec = (elem == "timer") and 1680 or ((elem == "expiry") and 42 or 95)
            o.formatGet, o.formatSet, o.formatKinds, o.formatDefaults = fg, fs, { time = true }, def
            o.formatSample = function(spec) return RC.UI:FormatText(spec, def, { value = sampleSec }, { value = "time" }, "value") end
        end
        local te = self.UI:CreateTextElement(card, o)
        te:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        cy = cy - te:GetHeight() - 4
        yPos = EndCard(card, cy, yPos)
    end
    return yPos
end

------------------------------------------------------------------------
-- Animation: entrance, exit, glow, mouseover fade
------------------------------------------------------------------------
local function SecondsSlider(self, card, cy, label, get, set)
    Label(card, cy, label)
    cy = cy - 20
    local cur = math_floor((get() or 0) * 100 + 0.5)
    local sl = self.UI:CreateSlider(card, 0, 100, cur, 1)
    sl:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
    sl.Text:SetText(string.format("%.2fs", cur / 100))
    sl:SetScript("OnValueChanged", function(s, v)
        v = math_floor(v + 0.5)
        s.Text:SetText(string.format("%.2fs", v / 100))
        set(v / 100)
    end)
    return cy - 46, sl
end

function CBS.BuildAnimation(self, frame, barKey, parent, yPos, P)
    local S = RC.BarStyle
    local B = BARS[barKey]
    local function Replay() Changed(barKey) if P then P.Replay() end end

    local card, cy = Card(self, parent, yPos, RCL["Bar animation"])
    cy = Desc(card, cy, RCL["How the bar comes and goes when it shows or hides (zone rules, turning it on or off). In combat it always appears at once."])
    local inP = self.UI:CreateAnimationPicker(card, {
        label = RCL["When it appears"], width = 460, how = "in", defaults = S.BAR_ANIM_DEFAULTS,
        get = function() return S.Get(barKey).showAnim end,
        set = function(spec) S.Edit(barKey).showAnim = spec Replay() end,
    })
    inP:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
    cy = cy - inP:GetHeight() - 14
    local outP = self.UI:CreateAnimationPicker(card, {
        label = RCL["When it goes"], width = 460, how = "out", defaults = S.BAR_ANIM_DEFAULTS,
        get = function() return S.Get(barKey).hideAnim end,
        set = function(spec) S.Edit(barKey).hideAnim = spec Replay() end,
    })
    outP:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
    cy = cy - outP:GetHeight() - 8
    cy = Desc(card, cy, RCL["Appearance > Motion can turn every animation off or speed them all up."])
    yPos = EndCard(card, cy, yPos)

    if B.glow then
        local gcard, gy = Card(self, parent, yPos, RCL["Expiry glow animation"])
        gy = Desc(gcard, gy, RCL["How the glow moves while a buff is running out. Pulse and flash keep repeating; set the style to none for a steady glow."])
        local gp = self.UI:CreateAnimationPicker(gcard, {
            label = RCL["Glow"], width = 460, how = "update", defaults = S.GLOW_ANIM_DEFAULTS,
            get = function() return S.Get(barKey).glowAnim end,
            set = function(spec) S.Edit(barKey).glowAnim = spec Changed(barKey) end,
        })
        gp:SetPoint("TOPLEFT", gcard, "TOPLEFT", 14, gy)
        gy = gy - gp:GetHeight() - 8
        yPos = EndCard(gcard, gy, yPos)
    end

    if B.fade then
        local db = RC.db[barKey]
        local fcard, fy = Card(self, parent, yPos, RCL["Fade when not hovered"])
        self.UI:CreateSettingCheckbox(fcard, fy, RCL["Fade bar when not hovered"], db.mouseoverFade, function(cb)
            db.mouseoverFade = cb:GetChecked()
            RC:ForceCheckboxUpdate(cb, db.mouseoverFade)
            B.fadeApply()
            RC:SaveConfigurationToProfile()
        end)
        fy = fy - 24
        fy = Desc(fcard, fy, RCL["The bar sinks to the opacity below while the mouse is away and comes back when you point at it."], 36)
        Label(fcard, fy, RCL["Faded opacity"])
        fy = fy - 20
        local fa = math_floor((db.mouseoverFadeAlpha or 0.15) * 100 + 0.5)
        local fs = self.UI:CreateSlider(fcard, 0, 100, fa, 5)
        fs:SetPoint("TOPLEFT", fcard, "TOPLEFT", 14, fy)
        fs.Text:SetText(fa .. "%")
        fs:SetScript("OnValueChanged", function(s, v)
            v = math_floor(v / 5 + 0.5) * 5
            db.mouseoverFadeAlpha = v / 100
            s.Text:SetText(v .. "%")
            B.fadeApply()
            RC:SaveConfigurationToProfile()
        end)
        local sync = self.UI:CreateStyledButton(fcard, RCL["Sync all bars"], 100, 22)
        sync:SetPoint("TOPLEFT", fs, "TOPRIGHT", 14, 4)   -- (clear of the slider's value)
        sync:SetScript("OnClick", function()
            if RC.SyncBarFadeAllSettings then RC:SyncBarFadeAllSettings(barKey) end
            RC.UI:NotifySettingChanged("sync")
        end)
        sync:HookScript("OnEnter", function(b)
            GameTooltip:SetOwner(b, "ANCHOR_TOP")
            local gold, norm = RC:GetColor("text", "gold"), RC:GetColor("text", "normal")
            GameTooltip:SetText(RCL["Sync all bars"], gold.r, gold.g, gold.b)
            GameTooltip:AddLine(RCL["Copies this bar's fade enable state and opacity to the other two bars (consumables, potions, weapons)."], norm.r, norm.g, norm.b, true)
            GameTooltip:Show()
        end)
        sync:HookScript("OnLeave", function() GameTooltip:Hide() end)
        fy = fy - 46
        fy = SecondsSlider(self, fcard, fy, RCL["Fade in when pointed at"],
            function() local i = S.FadeTimes(barKey) return i end,
            function(v) S.Edit(barKey).fadeIn = v Changed(barKey) end)
        fy = SecondsSlider(self, fcard, fy, RCL["Fade out when the mouse leaves"],
            function() local _, o = S.FadeTimes(barKey) return o end,
            function(v) S.Edit(barKey).fadeOut = v Changed(barKey) end)
        fy = Desc(fcard, fy, RCL["Replay in the preview fades the sample out and back in."])
        yPos = EndCard(fcard, fy, yPos)
    end
    return yPos
end

------------------------------------------------------------------------
-- Position: lock, show / hide now, reset
------------------------------------------------------------------------
function CBS.BuildPosition(self, frame, barKey, parent, yPos)
    local B = BARS[barKey]
    local db = RC.db[barKey]
    local card, cy = Card(self, parent, yPos, RCL["Position"])
    self.UI:CreateSettingCheckbox(card, cy, RCL["Lock position"], db.locked, function(cb)
        local on = cb:GetChecked()
        db.locked = on
        RC:ForceCheckboxUpdate(cb, on)
        B.lock(on)
        RC:SaveConfigurationToProfile()
    end)
    cy = cy - 24
    cy = Desc(card, cy, RCL["Unlocked, the bar wears a title strip you can drag it by. Edit Mode (/rc move) moves every frame at once."], 36)

    local showBtn = self.UI:CreateStyledButton(card, RCL["Show Bar"], 110, 22)
    showBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
    showBtn:SetScript("OnClick", function()
        B.create()
        db.enabled = true
        Rebuild(barKey)
        B.visibility()
    end)
    local hideBtn = self.UI:CreateStyledButton(card, RCL["Hide Bar"], 110, 22)
    hideBtn:SetPoint("LEFT", showBtn, "RIGHT", 8, 0)
    hideBtn:SetScript("OnClick", function() RC:HideBarFrame(barKey) end)
    local resetBtn = self.UI:CreateStyledButton(card, RCL["Reset Position"], 110, 22)
    resetBtn:SetPoint("LEFT", hideBtn, "RIGHT", 8, 0)
    resetBtn:SetScript("OnClick", function()
        local f = RC[barKey] and RC[barKey].frame
        if f then RC.Position.ResetFrame(f) end
    end)
    cy = cy - 34
    cy = Desc(card, cy, RCL["Show Bar and Hide Bar play the bar's animations, so they double as a test."])
    yPos = EndCard(card, cy, yPos)
    if B.glow then
        -- the parts inside a button: the expiry glow
        local pc, py = Card(self, parent, yPos, RCL["Parts"])
        local cw = pc:GetWidth() or 0
        local gg, gs = self.UI:CustomAccess(function() return RC.db[barKey] end, "anchors", "glow", function() Changed(barKey) end)
        local ge = self.UI:CreateFrameElement(pc, { label = RCL["Expiry glow"], key = "glow",
            width = (cw > 240) and math_min(460, cw - 28) or 420,
            anchorGet = gg, anchorSet = gs, targets = { { value = "button", text = RCL["The button"] } },
            defaultTargetLabel = RCL["Around the button"],
            anchorDefaults = function() return RC.BarStyle.ANCHOR_DEFAULTS.glow end })
        ge:SetPoint("TOPLEFT", pc, "TOPLEFT", 14, py)
        py = py - ge:GetHeight() - 8
        py = Desc(pc, py, RCL["Each text's place is on the Text tab. Reset puts a part back where it always sat."])
        yPos = EndCard(pc, py, yPos)
    end
    yPos = RC.UI:FrameLayerCard(parent, yPos, function() return RC.db[barKey] end, function() Changed(barKey) end, { scale = false })
    return yPos
end

------------------------------------------------------------------------
-- The preview
------------------------------------------------------------------------
local I = "Interface\\Icons\\"
local SAMPLES = {
    consumablesHelper = {
        { id = 13510, icon = I .. "INV_Potion_62", data = { name = "Flask of the Titans", buffId = 17626 } },
        { id = 13452, icon = I .. "INV_Potion_32", data = { name = "Elixir of the Mongoose", buffId = 17538 } },
        { id = 12451, icon = I .. "INV_Misc_MonsterScales_11", data = { name = "Juju Power", buffId = 16323 } },
        { id = 20452, icon = I .. "INV_Misc_Food_64", data = { name = "Smoked Desert Dumplings", category = "food" } },
        { id = 21151, icon = I .. "INV_Drink_04", data = { name = "Rumsey Rum Black Label" } },
        { id = 999901, icon = I .. "INV_Sword_39", data = { name = "Main Hand", slot = "mainhand", isUnifiedWeaponButton = true, baseItemId = 18262 } },
    },
    potionsBar = {
        { id = 13446, icon = I .. "INV_Potion_54", data = { name = "Major Healing Potion" } },
        { id = 13442, icon = I .. "INV_Potion_41", data = { name = "Mighty Rage Potion" } },
        { id = 13457, icon = I .. "INV_Potion_24", data = { name = "Greater Fire Protection Potion", buffId = 17543 } },
        { id = 5634,  icon = I .. "INV_Potion_04", data = { name = "Free Action Potion" } },
        { id = 3387,  icon = I .. "INV_Potion_62", data = { name = "Limited Invulnerability Potion" } },
    },
    weaponsBar = {
        { id = 999901, icon = I .. "INV_Sword_39", data = { name = "Main Hand", slot = "mainhand", isUnifiedWeaponButton = true, baseItemId = 18262 } },
        { id = 999902, icon = I .. "INV_Sword_36", data = { name = "Off Hand", slot = "offhand", isUnifiedWeaponButton = true, baseItemId = 18262 } },
        { id = 900001, icon = I .. "INV_Axe_09", data = { name = "Bag Weapon", slot = "mainhand", isBagWeapon = true, weaponTexture = I .. "INV_Axe_09", baseItemId = 18262 } },
    },
    trinketBar = {
        { id = 23041, icon = I .. "INV_Misc_Bone_04", equipped = true, slotIndex = 13 },
        { id = 22954, icon = I .. "INV_Trinket_Naxxramas04", equipped = true, slotIndex = 14 },
        { id = 21180, icon = I .. "Spell_Nature_EarthBind" },
        { id = 20130, icon = I .. "INV_Drink_01" },
    },
}

-- TBC and Forever (also under the developer override) show that
-- version's items; an icon the client does not know keeps the Era
-- sample's icon in that place. The third consumable clashes with the
-- second on both (two battle elixirs; Juju Power and Greater Strength).
local FLAVOR_SAMPLES = {
    tbc = {
        consumablesHelper = {
            { id = 22854, data = { name = "Flask of Relentless Assault", buffId = 28520 } },
            { id = 22831, data = { name = "Elixir of Major Agility", buffId = 28497 } },
            { id = 28104, data = { name = "Elixir of Mastery", buffId = 33726 } },
            { id = 27658, data = { name = "Roasted Clefthoof", category = "food" } },
            { id = 27503, data = { name = "Scroll of Strength V", buffId = 33082 } },
            { id = 999901, data = { name = "Main Hand", slot = "mainhand", isUnifiedWeaponButton = true, baseItemId = 23529 } },
        },
        potionsBar = {
            { id = 22829, data = { name = "Super Healing Potion" } },
            { id = 22838, data = { name = "Haste Potion" } },
            { id = 22841, data = { name = "Major Fire Protection Potion", buffId = 28511 } },
            { id = 5634,  data = { name = "Free Action Potion" } },
            { id = 22828, data = { name = "Insane Strength Potion" } },
        },
        weaponsBar = {
            { id = 999901, data = { name = "Main Hand", slot = "mainhand", isUnifiedWeaponButton = true, baseItemId = 23529 } },
            { id = 999902, data = { name = "Off Hand", slot = "offhand", isUnifiedWeaponButton = true, baseItemId = 23529 } },
            { id = 900001, data = { name = "Bag Weapon", slot = "mainhand", isBagWeapon = true, weaponTexture = I .. "INV_Axe_09", baseItemId = 23529 } },
        },
    },
    forever = {
        consumablesHelper = {
            { id = 274274, data = { name = "Flask of Natural Aggression", buffId = 1293741 } },
            { id = 9206, data = { name = "Elixir of Greater Strength", buffId = 11405 } },
            { id = 12451, data = { name = "Juju Power", buffId = 16323 } },
            { id = 13934, data = { name = "Mightfish Steak", category = "food" } },
            { id = 246948, data = { name = "Distilled Firewater", buffId = 17038 } },
            { id = 999901, data = { name = "Main Hand", slot = "mainhand", isUnifiedWeaponButton = true, baseItemId = 18262 } },
        },
        potionsBar = {
            { id = 13446, data = { name = "Major Healing Potion" } },
            { id = 250943, data = { name = "Major Frenzy Potion" } },
            { id = 13457, data = { name = "Greater Fire Protection Potion", buffId = 17543 } },
            { id = 5634,  data = { name = "Free Action Potion" } },
            { id = 3387,  data = { name = "Limited Invulnerability Potion" } },
        },
    },
}
do
    local mine = FLAVOR_SAMPLES[RC:Flavor()]
    local GetItemIcon = GetItemIcon or (RC.Compat and RC.Compat.GetItemIcon)
    for barKey, list in pairs(mine or {}) do
        local era = SAMPLES[barKey]
        for i, smp in ipairs(list) do
            smp.icon = (GetItemIcon and smp.id < 900000 and GetItemIcon(smp.id)) or era[i].icon
        end
        SAMPLES[barKey] = list
    end
end
CBS.SAMPLES = SAMPLES

-- Per mode, per sample: count, buff time left (s), cooldown left (s).
local STATES = {
    consumablesHelper = {
        ready    = { { c = 3, left = 2400 }, { c = 7 }, { c = 12 }, { c = 0 }, { c = 5 }, { c = 4, left = 1500 } },
        expiring = { { c = 3, left = 22 }, { c = 7, left = 45 }, { c = 12 }, { c = 0 }, { c = 5 }, { c = 4, left = 1500 } },
        cooldown = { { c = 3, left = 2400 }, { c = 7 }, { c = 12, cd = 47 }, { c = 0 }, { c = 5, cd = 95 }, { c = 4, left = 1500 } },
        -- the Mongoose is up, so the Juju Power that shares its buff slot
        -- shows the clash look (the live bar's conflict state)
        clash    = { { c = 3, left = 2400 }, { c = 7, left = 1800 }, { c = 12, clash = SAMPLES.consumablesHelper[2].id }, { c = 0 }, { c = 5 }, { c = 4, left = 1500 } },
    },
    potionsBar = {
        ready    = { { c = 5 }, { c = 8 }, { c = 2 }, { c = 0 }, { c = 1 } },
        expiring = { { c = 5 }, { c = 8 }, { c = 2, left = 25, buff = true }, { c = 0 }, { c = 1 } },
        cooldown = { { c = 5, cd = 84 }, { c = 8 }, { c = 2 }, { c = 0 }, { c = 1 } },
    },
    weaponsBar = {
        ready    = { { c = 6, left = 1500 }, { c = 6, left = 1680 }, { c = 6 } },
        expiring = { { c = 6, left = 1500 }, { c = 6, left = 20 }, { c = 6 } },
        cooldown = { { c = 6, left = 240 }, { c = 6, left = 45 }, { c = 0 } },
    },
    trinketBar = {
        ready    = { {}, {}, {}, {} },
        cooldown = { { buff = 14 }, { cd = 95 }, {}, { cd = 600 } },
    },
}
-- update sizes the canvas to the bar (the strip scales it); a bar laid out
-- in more than two lines shows its first buttons, two lines' worth
local PV_W, PV_H = 260, 54

local function SampleState(barKey, P)
    local m = P and P.mode or "ready"
    if m == "faded" then m = "ready" end
    local t = STATES[barKey]
    return t[m] or t.ready
end

local function HideReadouts(b)
    for _, f in ipairs({ "cooldownText", "gcdText", "durationText", "expiryText", "weaponTimeText", "timeLabel" }) do
        local fs = b[f]
        if fs then fs:Hide() fs._cachedText = nil end
    end
    if b.cooldownFrame then b.cooldownFrame:Hide() end
    if b.gcdFrame then b.gcdFrame:Hide() end
    if b.castFrame then b.castFrame:Hide() end
end

local function BuildPreview(barKey)
    return function(canvas, P)
        local holder = CreateFrame("Frame", nil, canvas)
        holder:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        holder:SetSize(PV_W, PV_H)
        local bar = CreateFrame("Frame", nil, holder)
        bar:SetPoint("CENTER", holder, "CENTER", 0, 0)
        bar:SetSize(100, 50)
        bar.bg = bar:CreateTexture(nil, "BACKGROUND")
        bar.bg:SetAllPoints()
        local cat = RC.BarStyle.COLOR_CAT[barKey]
        RC:ApplyBarChrome(bar, RC:GetColor(cat, "frameBorder"), true, cat)
        P.store.holder, P.store.bar, P.store.btns, P.store.token = holder, bar, {}, 0
    end
end

-- each text of a sample carries its element key, so a click on it can
-- open its controls (RC.CustomPick)
local TAG_FIELDS = { count = "count", cooldownText = "cooldown", gcdText = "gcd", durationText = "duration",
    expiryText = "expiry", weaponTimeText = "timer", timeLabel = "timer", slotLabel = "slot", nameLabel = "name",
    absorbText = "absorb", buffDurationText = "tbuff", slotText = "tslot", expiryGlowFrame = "glow" }
local function TagSample(b, barKey)
    for field, key in pairs(TAG_FIELDS) do
        local r = b[field]
        if r and r._zElement == nil then
            if barKey == "trinketBar" and field == "cooldownText" then key = "tcooldown" end
            RC.UI:TagElement(r, key)
        end
    end
end

local function NewSample(barKey, bar, s, size, cfg)
    local b = CreateFrame("Button", nil, bar)
    b:SetSize(size, size)
    b:EnableMouse(false)
    if barKey == "trinketBar" then
        b._rcBarKey = "trinketBar"
        b.trinketData = { itemId = s.id, icon = s.icon, equipped = s.equipped, slotIndex = s.slotIndex }
        RC:DressTrinketButton(b, size, b.trinketData)
    else
        RC:DressBarButton(b, {
            size = size, config = cfg, itemData = s.data, itemId = s.id, barKey = barKey,
            isPotionBar = barKey == "potionsBar", isWeaponsBar = barKey == "weaponsBar",
            barType = RC.BarStyle.COLOR_CAT[barKey], iconTexture = s.icon,
        })
        b.itemId = s.id
    end
    b.fullyInitialized = true
    return b
end

local function UpdatePreview(barKey)
    return function(canvas, P)
        local S = RC.BarStyle
        local st = P.store
        local cfg = RC.db[barKey] or {}
        local size = cfg.buttonSize or 36
        local spacing = cfg.iconSpacing or 4
        local perRow = cfg.buttonsPerRow or ((barKey == "weaponsBar" or barKey == "trinketBar") and 4 or 10)
        local growDir = cfg.growDirection or ((barKey == "weaponsBar" or barKey == "trinketBar") and "RIGHT" or "DOWN")
        local list = SAMPLES[barKey]
        local states = SampleState(barKey, P)
        local n = #list
        -- every sample button, laid out as the bar lays them out in game
        -- (its rows, growth and size); the strip shows it at real size
        local w, h = S.BarSize(n, perRow, size, spacing, growDir)
        local sig = n .. ":" .. w .. ":" .. h
        if st.sig ~= sig then
            RC.Motion.Stop(st.bar)
            st.bar:SetSize(w, h)
            st.bar:SetScale(1)
            st.holder:SetSize(w, h)
            st.sig = sig
        end
        P.Resize(w + 8, h + 8)
        local cat = S.COLOR_CAT[barKey]
        local showBg
        if barKey == "weaponsBar" or barKey == "trinketBar" then showBg = cfg.showBackground ~= false
        else showBg = cfg.showBackground and true or false end
        RC:PaintBarChrome(st.bar, cat, showBg, false)
        local threshold = cfg.showBeforeExpiry or 60
        local now = GetTime()
        for i = 1, n do
            local s = list[i]
            local b = st.btns[i]
            if not b then
                b = NewSample(barKey, st.bar, s, size, cfg)
                st.btns[i] = b
            end
            RC:FitButtonSize(b, size)
            local x, y = S.GridOffset(i, perRow, size, spacing, growDir)
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", st.bar, "TOPLEFT", x, y)
            b:Show()
            local sv = states[i] or {}
            if barKey == "trinketBar" then
                RC:StyleBarButton(b, barKey, size)
                TagSample(b, barKey)
                local td = b.trinketData
                if td.equipped and cfg.showSlotNumbers ~= false then
                    b.slotText:SetText(td.slotIndex == 13 and "1" or "2")
                    b.slotBg:Show() b.slotText:Show()
                else
                    b.slotBg:Hide() b.slotText:Hide()
                end
                b.cooldownText:Hide() b.buffDurationText:Hide()
                b.cooldownFrame:Hide()
                local showText = cfg.showCooldownText ~= false
                if sv.buff then
                    b.cooldownFrame:SetCooldown(now - (20 - sv.buff), 20) b.cooldownFrame:Show()
                    b.buffDurationText:SetText(RC:FormatCooldownTime(sv.buff))
                    if showText then b.buffDurationText:Show() end
                elseif sv.cd then
                    b.cooldownFrame:SetCooldown(now - (120 - sv.cd), 120) b.cooldownFrame:Show()
                    b.cooldownText:SetText(RC:FormatCooldownTime(sv.cd))
                    if showText then b.cooldownText:Show() end
                end
            else
                local hasBuff = (sv.left ~= nil) and (sv.buff or s.data.buffId ~= nil or s.data.slot ~= nil)
                if cfg.showCount ~= false then
                    RC:EnsureButtonTextElements(b, cfg, size)
                    RC:SetBarButtonCount(b, sv.c or 0)
                    b.count:Show()
                elseif b.count then
                    b.count:Hide()
                end
                b._cachedStateKey = nil
                RC:ApplyBarButtonState(b, sv.c or 0, hasBuff, sv.clash ~= nil, sv.clash, s.id)
                RC:StyleBarButton(b, barKey, size)
                TagSample(b, barKey)
                if b.nameLabel then
                    local weaponBtn = s.data.isUnifiedWeaponButton or s.data.isBagWeapon
                    if cfg.showItemNames and not (barKey == "consumablesHelper" and weaponBtn) then
                        b.nameLabel:Show()
                    else
                        b.nameLabel:Hide()
                    end
                end
                HideReadouts(b)
                if sv.cd then
                    b.cooldownFrame:SetCooldown(now - (120 - sv.cd), 120)
                    b.cooldownFrame:Show()
                    RC:SetBarButtonCooldownText(b, sv.cd)
                elseif sv.left and cfg.showExpiryTimer ~= false then
                    if sv.left <= threshold then
                        RC:SetBarButtonExpiryText(b, sv.left, threshold)
                    elseif barKey == "weaponsBar" then
                        RC:SetBarButtonWeaponTime(b, sv.left)
                    end
                end
                if b.timeLabel then RC:UpdateBarButtonTimeLabel(b, hasBuff, sv.left or 0, threshold) end
                RC:SetBarButtonGlow(b, hasBuff and sv.left ~= nil and sv.left <= threshold)
            end
        end
        for i = n + 1, #st.btns do st.btns[i]:Hide() end
        -- the faded look, unless an animation owns the alpha right now
        if not RC.Motion.IsPlaying(st.bar) and not st.bar._mouseoverFadeTicker then
            local faded = P.mode == "faded" and cfg.mouseoverFade
            st.bar:SetAlpha(faded and (cfg.mouseoverFadeAlpha or 0.15) or 1)
        end
    end
end

-- Entrance, a beat, the fade out and back (fade on), the exit, then rest.
local function ReplayPreview(barKey)
    return function(canvas, P)
        local S = RC.BarStyle
        local M = RC.Motion
        local st = P.store
        local bar = st.bar
        st.token = st.token + 1
        local t = st.token
        local cfg = RC.db[barKey] or {}
        M.Stop(bar)
        bar:SetAlpha(1)
        bar:Hide()
        local inSpec = S.Spec(barKey, "showAnim")
        M.Show(bar, inSpec)
        local function Live() return t == st.token and bar:IsVisible() end
        local function Exit()
            local outSpec = S.Spec(barKey, "hideAnim")
            M.Hide(bar, outSpec)
            C_Timer.After(M.Duration(outSpec.duration) + M.Duration(outSpec.delay) + 0.4, function()
                if t ~= st.token then return end
                M.Stop(bar)
                if canvas:IsVisible() then bar:Show() P.Update() end
            end)
        end
        C_Timer.After(M.Duration(inSpec.duration) + M.Duration(inSpec.delay) + 1.0, function()
            if not Live() then return end
            if BARS[barKey].fade and cfg.mouseoverFade then
                local fi, fo = S.FadeTimes(barKey)
                RC:_FadeFrameAlpha(bar, cfg.mouseoverFadeAlpha or 0.15, fo)
                C_Timer.After(M.Duration(fo) + 0.6, function()
                    if not Live() then return end
                    RC:_FadeFrameAlpha(bar, 1, fi)
                    C_Timer.After(M.Duration(fi) + 0.6, function()
                        if Live() then Exit() end
                    end)
                end)
            else
                Exit()
            end
        end)
    end
end

function CBS.DeclarePreview(self, barKey)
    local modes
    if barKey == "trinketBar" then
        modes = { { id = "ready", label = RCL["Ready"] }, { id = "cooldown", label = RCL["In use"] } }
    else
        modes = {
            { id = "ready", label = RCL["Ready"] },
            { id = "expiring", label = RCL["Running out"] },
            { id = "cooldown", label = RCL["Cooldown"] },
            { id = "faded", label = RCL["Faded"] },
        }
        -- the main bar's items can clash (two from one buff group)
        if barKey == "consumablesHelper" then table.insert(modes, 4, { id = "clash", label = RCL["Clash"] }) end
    end
    -- a click on a sample's text opens the tab with its controls
    if RC.CustomPick then
        RC.CustomPick.SetHandler("consumables." .. barKey, function(k)
            local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
            if not cf then return end
            cf[BARS[barKey].tabField] = (k == "glow") and "position" or "text"
            RC[BARS[barKey].page](RC, cf, true)
        end)
    end
    return self.UI:DeclarePreview({
        key = "consumables." .. barKey, title = BARS[barKey].title,
        width = PV_W, height = PV_H,
        build = BuildPreview(barKey), update = UpdatePreview(barKey), replay = ReplayPreview(barKey),
        modes = modes, modesLabel = RCL["Show"],
    })
end
