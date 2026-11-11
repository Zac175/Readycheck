------------------------------------------------------------------------
-- Readycheck - World Tools: buff drop countdown bars
-- Owns the pull-timer bar stack, the screen alert banner and the alert
-- routing that WT_Timers / WBT_Detect push their events into.
-- Anchors "wtPullTimersMain" / "wtPullTimersIdle" / "wtScreenAlert" are
-- registered with RC.UIMover (/rc moveui).
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end
local RC = _G.Readycheck
if not RC then return end
local WT = RC.WorldTools
if not WT then return end

WT.Bars = {}
local PT = WT.Bars

------------------------------------------------------------------------
-- Game data
------------------------------------------------------------------------

-- Seconds from the yell that starts a timer to the buff actually landing.
local REND_SECONDS = { rendOrg = 6, rendBarrens = 17, rendBarrensShort = 6 }

-- [key] = { first yell, second yell }. Second-yell values are recorded for
-- reference; callers reject yellNum 2 because it is too tight to be useful.
local YELL_SECONDS = {
    onyH = { 14.5, 7.2 },
    onyA = { 15,   7.2 },
    nefH = { 15,   8 },
    nefA = { 12,   8 },
    zan  = { 50.5, 29 },
}

local ICON = {
    rend = "Interface\\Icons\\spell_arcane_teleportorgrimmar",
    ony  = "Interface\\Icons\\inv_misc_head_dragon_01",
    nef  = "Interface\\Icons\\inv_misc_head_dragon_black",
    zan  = "Interface\\Icons\\ability_creature_poison_05",
}

-- \226\128\148 is an em dash; kept as bytes so the file stays ASCII.
local BAR_DEF = {
    rendOrg          = { text = "Orgrimmar \226\128\148 Rend", icon = ICON.rend },
    rendBarrens      = { text = "Barrens \226\128\148 Rend",   icon = ICON.rend },
    rendBarrensShort = { text = "Barrens \226\128\148 Rend",   icon = ICON.rend },
    onyH             = { text = "Horde Ony",                   icon = ICON.ony },
    onyA             = { text = "Alliance Ony",                icon = ICON.ony },
    nefH             = { text = "Horde Nef",                   icon = ICON.nef },
    nefA             = { text = "Alliance Nef",                icon = ICON.nef },
    zan              = { text = "Zandalar",                    icon = ICON.zan },
}

local HANDIN_NAMES = {
    rend = "Rend (Warchief's Blessing)",
    zan  = "Zandalar",
    onyH = "Onyxia (Horde)",
    onyA = "Onyxia (Alliance)",
    ony  = "Onyxia",
    nefH = "Nefarian (Horde)",
    nefA = "Nefarian (Alliance)",
    nef  = "Nefarian",
}

-- onyH/onyA and nefH/nefA share one settings entry each.
local ALERT_ALIAS = { onyH = "ony", onyA = "ony", nefH = "nef", nefA = "nef" }
local function AlertKeyFor(buff)
    return ALERT_ALIAS[buff] or buff
end

-- Fixed tints for the two banner flavours; not user configurable.
local TINT_INCOMING = { 1, 0.85, 0.2 }
local TINT_DEATH    = { 1, 0.2, 0.2 }

local FLAT_TEXTURE = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"

-- The countdown fill is a real duration bar, so it is the one place the
-- user's statusbar texture (LibSharedMedia) belongs; chrome stays FLAT.
local function BarFillTexture()
    local path = RC.GetTexturePath and RC:GetTexturePath()
    if type(path) == "string" and path ~= "" then return path end
    return FLAT_TEXTURE
end

------------------------------------------------------------------------
-- Sound catalogue: "value|Label|file stem", no stem means silence.
------------------------------------------------------------------------
local SOUND_DIR = "Interface\\AddOns\\Readycheck\\Media\\Sounds\\"

local SOUND_CATALOG = {
    "none|None",
    "bell|Bell|bell",
    "happy_bells|Happy Bells|happybells",
    "elevator|Elevator Tone|elevator",
    "clear_announce|Clear Announce|announce",
    "digital_tone|Digital Tone|quicktone",
    "access_allowed|Access Allowed|access",
    "magic_ring|Magic Ring|magicring",
    "magic_marimba|Magic Marimba|marimba",
    "arabian_harp|Harp|harp",
    "guitar|Guitar Alert|guitar",
    "flute|Flute|flute",
    "correct_reward|Correct Reward|correct",
    "game_win|Victory|win",
    "final_bonus|Final Bonus|levelbonus",
    "unlock|Unlock|unlock",
    "tile_reveal|Tile Reveal|reveal",
    "dry_popup|Dry Pop|popup",
    "atm_press|Key Press|keypress",
    "interface_select|Interface Select|select",
    "interface_start|Interface Start|start",
    "interface_remove|Interface Remove|remove",
    "wrong_answer|Wrong Answer|wrong",
}

-- Every catalogue sound is also registered with LibSharedMedia as
-- "Readycheck: <Label>", so the rest of Readycheck (and any other addon's
-- sound picker) can use them, and the alert rows can pick ANY sound in
-- LibSharedMedia. Saved values stay the short ids above for our own
-- sounds (existing settings keep working); anything else is stored as its
-- LibSharedMedia name.
local LSM_PREFIX = "Readycheck: "

PT.SOUND_OPTIONS = {}
PT.SOUND_FILES = {}
local ownLSMName = {}     -- LSM name -> true for the ones registered here

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

for index = 1, #SOUND_CATALOG do
    local id, label, stem = strsplit("|", SOUND_CATALOG[index])
    PT.SOUND_OPTIONS[index] = { value = id, label = label, file = stem }
    if stem then
        local path = SOUND_DIR .. stem .. ".ogg"
        PT.SOUND_FILES[id] = path
        if LSM then
            local name = LSM_PREFIX .. label
            pcall(LSM.Register, LSM, "sound", name, path)
            ownLSMName[name] = true
        end
    end
end

-- Built-in catalogue first, then every other LibSharedMedia sound A-Z.
-- Built fresh each call: other addons register media after we load.
function PT.GetSoundOptions()
    local list = {}
    for i = 1, #PT.SOUND_OPTIONS do list[i] = PT.SOUND_OPTIONS[i] end
    local lsm = LSM or (LibStub and LibStub("LibSharedMedia-3.0", true))
    local all = lsm and lsm:HashTable("sound")
    if all then
        local names = {}
        for name in pairs(all) do
            if not ownLSMName[name] and name ~= "None" then names[#names + 1] = name end
        end
        table.sort(names)
        for _, name in ipairs(names) do
            list[#list + 1] = { value = name, label = name }
        end
    end
    return list
end

-- A saved sound key -> file path: our own ids, else a LibSharedMedia name.
function PT.ResolveSound(soundKey)
    if not soundKey or soundKey == "none" or soundKey == "" then return nil end
    local path = PT.SOUND_FILES[soundKey]
    if path then return path end
    local lsm = LSM or (LibStub and LibStub("LibSharedMedia-3.0", true))
    if lsm then
        local f = lsm:Fetch("sound", soundKey, true)
        if f and f ~= "" then return f end
    end
    return nil
end

local function PlayConfigSound(soundKey, channel)
    local path = PT.ResolveSound(soundKey)
    if path then
        pcall(PlaySoundFile, path, channel or "Master")
    end
end
PT.PlayConfigSound = PlayConfigSound

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local function TimerStore()
    local db = WT.Store()
    return db and db.timerSettings
end

-- { field, saved-variable key, default }. A boolean default means the
-- saved value is opt-out (anything but false counts as on).
local CFG_SPEC = {
    { "enabled",         "pullTimerEnabled",         true },
    { "mainW",           "pullTimerMainBarWidth",    224 },
    { "mainH",           "pullTimerMainBarHeight",   18 },
    { "smallW",          "pullTimerSmallBarWidth",   150 },
    { "smallH",          "pullTimerSmallBarHeight",  14 },
    { "mainOffX",        "pullTimerMainOffsetX",     8 },
    { "mainOffY",        "pullTimerMainOffsetY",     188 },
    { "idleOffX",        "pullTimerIdleOffsetX",     -527 },
    { "idleOffY",        "pullTimerIdleOffsetY",     -323 },
    { "expandThreshold", "pullTimerExpandThreshold", 10 },
    { "colorBase",       "pullTimerBarColor",        { 0.2, 0.8, 0.2 } },
    { "colorWarn",       "pullTimerBarColorWarn",    { 1.0, 0.8, 0.0 } },
    { "colorCrit",       "pullTimerBarColorCrit",    { 1.0, 0.2, 0.2 } },
    { "soundChannel",    "soundChannel",             "Master" },
    { "alertOffX",       "alertOffsetX",             0 },
    { "alertOffY",       "alertOffsetY",             -180 },
}

-- One reusable table: the animation driver reads this every frame and no
-- caller keeps a reference past its own call.
local cfg = {}

local function Cfg()
    local ts = TimerStore()
    for i = 1, #CFG_SPEC do
        local field, savedKey, fallback = CFG_SPEC[i][1], CFG_SPEC[i][2], CFG_SPEC[i][3]
        local stored = ts and ts[savedKey]
        if type(fallback) == "boolean" then
            cfg[field] = stored ~= false
        else
            cfg[field] = stored or fallback
        end
    end
    return cfg
end

-- Shared predicate (Core_Boot): a raid GROUP in the open world is not a
-- raid, so the raid kill-switch and mutes only bite inside the instance.
local function InsideRaidInstance()
    if RC.IsInRaidInstance then return RC:IsInRaidInstance() end
    return select(2, IsInInstance()) == "raid"
end

-- Palette lookup with a literal fallback so bars still draw before the
-- colour tables are populated.
local function Chrome(key, r, g, b, a)
    local c = RC.GetColor and RC:GetColor("ui", key)
    if type(c) == "table" and c.r then
        return c.r, c.g, c.b, c.a or a
    end
    return r, g, b, a
end

------------------------------------------------------------------------
-- Anchors
------------------------------------------------------------------------
local mainAnchor = CreateFrame("Frame", "RC_WTPullTimerMainAnchor", UIParent)
local idleAnchor = CreateFrame("Frame", "RC_WTPullTimerIdleAnchor", UIParent)
mainAnchor:SetFrameStrata("HIGH")
idleAnchor:SetFrameStrata("HIGH")

local alertFrame = CreateFrame("Frame", "RC_WTAlertFrame", UIParent)
alertFrame:SetSize(600, 40)
alertFrame:SetFrameStrata("DIALOG")
alertFrame:Hide()

-- Each anchor plus the banner: pinned point, saved-variable pair, default.
local POS_SPEC = {
    { id = "wtPullTimersMain", frame = mainAnchor, point = "CENTER",
      label = "WT Buff Drop Bars (Main)", x = 8, y = 188, gen2y = 112,
      xKey = "pullTimerMainOffsetX", yKey = "pullTimerMainOffsetY" },
    { id = "wtPullTimersIdle", frame = idleAnchor, point = "TOPRIGHT",
      label = "WT Buff Drop Bars (Small)", x = -527, y = -323,
      xKey = "pullTimerIdleOffsetX", yKey = "pullTimerIdleOffsetY" },
    { id = "wtScreenAlert", frame = alertFrame, point = "TOP",
      label = "WT Screen Alert", x = 0, y = -180,
      xKey = "alertOffsetX", yKey = "alertOffsetY" },
}

for i = 1, #POS_SPEC do
    local spec = POS_SPEC[i]
    RC.Position.Bind(spec.frame, TimerStore, {
        point = spec.point, xKey = spec.xKey, yKey = spec.yKey,
        markKey = spec.xKey .. "Centred",
        default = { point = spec.point, x = spec.x, y = spec.y },
        -- (a fresh character: under the reminder text, not inside it)
        gen2 = spec.gen2y and { point = spec.point, x = spec.x, y = spec.gen2y } or nil,
    })
end

local function Place(spec)
    if not RC.Position.RestoreFrame(spec.frame) then
        spec.frame:ClearAllPoints()
        spec.frame:SetPoint(spec.point, UIParent, spec.point, spec.x, spec.y)
    end
end

-- An anchor covers exactly one bar so the UIMover overlay matches the top
-- bar's real footprint; the stack grows downward from there.
local ANCHOR_SIZING = {
    { mainAnchor, "mainW", "mainH" },
    { idleAnchor, "smallW", "smallH" },
}

local function UpdateAnchorSizes()
    local c = Cfg()
    for i = 1, #ANCHOR_SIZING do
        local row = ANCHOR_SIZING[i]
        row[1]:SetSize(math.max(c[row[2]], 50), c[row[3]])
    end
end
PT.UpdateAnchorSizes = UpdateAnchorSizes

local function ApplyAnchorPositions()
    Place(POS_SPEC[1])
    Place(POS_SPEC[2])
    UpdateAnchorSizes()
end
PT.ApplyAnchorPositions = ApplyAnchorPositions

local function ApplyAlertPosition()
    Place(POS_SPEC[3])
end
PT.ApplyAlertPosition = ApplyAlertPosition

ApplyAnchorPositions()
ApplyAlertPosition()

------------------------------------------------------------------------
-- Bar widget
------------------------------------------------------------------------

-- Hairline border pieces: { anchor A, anchor B, sizing setter, thickness }.
local EDGE_SPEC = {
    { "TOPLEFT",    "TOPRIGHT",    "SetHeight", 1 },
    { "BOTTOMLEFT", "BOTTOMRIGHT", "SetHeight", 1 },
    { "TOPLEFT",    "BOTTOMLEFT",  "SetWidth",  1 },
    { "TOPRIGHT",   "BOTTOMRIGHT", "SetWidth",  1 },
}

-- { frame field, justify, font size }. The label is anchored by SetIcon
-- because its left edge depends on whether an icon is showing.
local TEXT_SPEC = {
    { "label", "LEFT",  12 },
    { "time",  "RIGHT", 13 },
}

-- Shared methods, copied onto each frame so pooled bars do not each carry
-- their own closures.
local BarMixin = {}

-- Iconless bars keep their text flush with the frame edge instead of
-- leaving a hole where the icon would sit.
function BarMixin:SetIcon(path)
    local withIcon = (path ~= nil)
    if withIcon then self.icon:SetTexture(path) end
    self.icon:SetShown(withIcon)
    self.label:ClearAllPoints()
    self.label:SetPoint("LEFT", withIcon and self.icon or self,
        withIcon and "RIGHT" or "LEFT", withIcon and 4 or 6, 0)
end

function BarMixin:SetBarColor(r, g, b, a)
    self:SetStatusBarColor(r, g, b, a or 0.85)
end

function BarMixin:SetBarSize(width, height)
    self:SetSize(width, height)
    self.icon:SetSize(height - 4, height - 4)
    self.spark:SetSize(12, height + 8)
end

-- parent: UIParent for the live stack, the settings preview's canvas for
-- its sample (strata nil: the parent's).
local function BuildBar(strata, clamped, parent)
    local bar = CreateFrame("StatusBar", nil, parent or UIParent)
    bar:SetSize(300, 28)
    if strata then bar:SetFrameStrata(strata) end
    bar:SetClampedToScreen(clamped and true or false)
    bar:EnableMouse(false)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar:SetStatusBarTexture(BarFillTexture())
    bar:SetStatusBarColor(0.2, 0.8, 0.2, 0.85)

    -- Chrome: flat element fill behind the bar and a 1px black ring
    -- (ui.borderNormal) drawn as four hairlines, no edge art.
    local br, bgc, bb = Chrome("elementBackground", 0.12, 0.12, 0.12, 1)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetTexture(FLAT_TEXTURE)
    bar.bg:SetVertexColor(br, bgc, bb, 0.9)

    local er, eg, eb, ea = Chrome("borderNormal", 0, 0, 0, 1)
    for i = 1, #EDGE_SPEC do
        local spec = EDGE_SPEC[i]
        local edge = bar:CreateTexture(nil, "BORDER")
        edge:SetColorTexture(er, eg, eb, ea)
        edge:SetPoint(spec[1], 0, 0)
        edge:SetPoint(spec[2], 0, 0)
        edge[spec[3]](edge, spec[4])
    end

    bar.icon = bar:CreateTexture(nil, "OVERLAY")
    bar.icon:SetSize(24, 24)
    bar.icon:SetPoint("LEFT", 3, 0)
    bar.icon:Hide()

    bar.spark = bar:CreateTexture(nil, "OVERLAY")
    bar.spark:SetTexture("Interface\\CastingBar\\UI-CastingBar-Spark")
    bar.spark:SetSize(12, 36)
    bar.spark:SetBlendMode("ADD")
    bar.spark:SetPoint("CENTER", bar:GetStatusBarTexture(), "RIGHT", 0, 0)

    for i = 1, #TEXT_SPEC do
        local field, align, size = TEXT_SPEC[i][1], TEXT_SPEC[i][2], TEXT_SPEC[i][3]
        local fs = bar:CreateFontString(nil, "OVERLAY")
        if RC.ApplyCustomFont then RC:ApplyCustomFont(fs, size) end
        fs:SetJustifyH(align)
        fs:SetTextColor(1, 1, 1)
        bar[field] = fs
    end
    bar.time:SetPoint("RIGHT", -6, 0)

    for name, method in pairs(BarMixin) do
        bar[name] = method
    end

    -- Anchors the label; every caller overrides it with a real icon.
    bar:SetIcon(nil)
    bar:Hide()
    return bar
end

-- Generic downward stacker, shared by the live stack and the preview.
local function StackBars(list, anchor, corner, width, height, gap)
    local drop = 0
    for i = 1, #list do
        list[i]:ClearAllPoints()
        list[i]:SetPoint(corner, anchor, corner, 0, drop)
        list[i]:SetBarSize(width, height)
        drop = drop - (height + gap)
    end
end

------------------------------------------------------------------------
-- Screen alert banner
------------------------------------------------------------------------
-- The banner is a flat plate (ui.windowBackground fill, 1px black ring)
-- hugging the text. It is a child of the 600x40 anchor rather than the
-- anchor itself so the mover footprint and saved offsets stay untouched;
-- ShowScreenAlert re-fits its width to the message each time.
local ALERT_PLATE_PAD = 16

-- The plate and its text, on any parent (the live banner's anchor, or the
-- settings preview's canvas). plate.label is the message.
local function NewAlertPlate(parent)
    local plate = CreateFrame("Frame", nil, parent)
    plate:SetPoint("CENTER", parent, "CENTER", 0, 0)
    plate:SetSize(200, 40)
    plate.bg = plate:CreateTexture(nil, "BACKGROUND")
    plate.bg:SetAllPoints()
    plate.bg:SetTexture(FLAT_TEXTURE)
    local pr, pg, pb, pa = Chrome("windowBackground", 0.08, 0.08, 0.08, 0.95)
    plate.bg:SetVertexColor(pr, pg, pb, pa or 0.95)
    if RC.UI and RC.UI.CreateSimpleBorder then
        plate.border = RC.UI:CreateSimpleBorder(plate)
    end
    local label = plate:CreateFontString(nil, "OVERLAY")
    if RC.ApplyCustomFont then RC:ApplyCustomFont(label, 18, "OUTLINE") end
    label:SetPoint("CENTER")
    label:SetJustifyH("CENTER")
    label:SetTextColor(1, 0.85, 0.2)
    plate.label = label
    return plate
end
PT.NewAlertPlate = NewAlertPlate

-- Hugs the message: its width plus padding, 120 at least, maxW at most.
local function FitPlate(plate, maxW, h)
    local w = (plate.label:GetStringWidth() or 0) + ALERT_PLATE_PAD * 2
    if w > maxW then w = maxW end
    if w < 120 then w = 120 end
    plate:SetSize(w, h)
end
PT.FitAlertPlate = FitPlate

local alertPlate = NewAlertPlate(alertFrame)
local alertLabel = alertPlate.label

local function FitAlertPlate()
    FitPlate(alertPlate, alertFrame:GetWidth() or 600, alertFrame:GetHeight() or 40)
end

local alertHideTimer

local function ShowScreenAlert(msg, duration, r, g, b)
    alertLabel:SetText(msg)
    alertLabel:SetTextColor(r or TINT_INCOMING[1], g or TINT_INCOMING[2], b or TINT_INCOMING[3])
    FitAlertPlate()
    alertFrame:SetAlpha(1)
    alertFrame:Show()
    if alertHideTimer then alertHideTimer:Cancel() end
    alertHideTimer = C_Timer.NewTimer(duration or 5, function()
        alertHideTimer = nil
        alertFrame:Hide()
    end)
end
PT.ShowScreenAlert = ShowScreenAlert

------------------------------------------------------------------------
-- Alert routing
------------------------------------------------------------------------

-- A real incoming drop repeats within seconds; corroborating events
-- (quest hand-ins, NPC deaths, cooldown notices) get a much wider window.
local DEDUP_PULL, DEDUP_SLOW = 10, 60
local lastAlertAt = {}

-- Ordered output channels. Each entry is { settings field, emitter }; the
-- matching field on ts.alerts.raidDisable mutes it inside a raid.
local ALERT_SINKS = {
    { "notify", function(_, msg, r, g, b) ShowScreenAlert(msg, 5, r, g, b) end },
    { "chat",   function(_, msg) RC:Print("|cFFFFAA00" .. msg .. "|r") end },
    { "flash",  function() if FlashClientIcon then FlashClientIcon() end end },
    { "sound",  function(entry) PlayConfigSound(entry.sound, Cfg().soundChannel) end },
}

-- dedupTag separates several legitimately distinct messages that share one
-- category+buff inside the window (cooldown 10m / 1m / ready).
function PT:DispatchAlert(category, buff, text, color, dedupTag)
    local ts = TimerStore()
    -- Master switch sits in front of every per-buff toggle.
    if not (ts and ts.alertsEnabled and ts.alerts) then return end

    local group = ts.alerts[category]
    local entry = group and group[buff]
    if not entry or entry.enabled == false then return end

    local stamp = GetTime()
    local dedupKey = table.concat({ category or "-", buff or "-", dedupTag or "-" }, ":")
    -- Battle shout is announced per cast and must never squelch itself.
    if buff ~= "battleshout" then
        local seen = lastAlertAt[dedupKey]
        local window = (category == "pullTimer") and DEDUP_PULL or DEDUP_SLOW
        if seen and (stamp - seen) < window then return end
    end
    lastAlertAt[dedupKey] = stamp

    local muted = InsideRaidInstance() and ts.alerts.raidDisable or nil
    local r, g, b = 1, 1, 1
    if color then r, g, b = color[1], color[2], color[3] end

    for i = 1, #ALERT_SINKS do
        local field, emit = ALERT_SINKS[i][1], ALERT_SINKS[i][2]
        local want = entry[field]
        if field == "sound" then want = want and want ~= "none" end
        if want and not (muted and muted[field]) then
            emit(entry, text, r, g, b)
        end
    end
end

------------------------------------------------------------------------
-- Zone classification
------------------------------------------------------------------------
local ZONE_KIND = {
    ["orgrimmar"]          = "orgrimmar",
    ["the barrens"]        = "barrens",
    ["barrens"]            = "barrens",
    ["stormwind city"]     = "stormwind",
    ["stormwind"]          = "stormwind",
    ["stranglethorn vale"] = "stv",
    ["stranglethorn"]      = "stv",
}

local function PlayerZoneKind()
    -- The coordinate pin wins: the Rend camps sit in sub-zones whose zone
    -- text would otherwise classify as "other".
    local pin = WT.GetCoordinateLocation and WT:GetCoordinateLocation()
    if pin and string.find(string.lower(pin), "rend", 1, true) then
        return "barrens"
    end
    return ZONE_KIND[string.lower(GetRealZoneText() or "")] or "other"
end

-- Which zone promotes a timer to the large stack; "*" means always large.
local MAIN_WHEN = {
    rendOrg          = "orgrimmar",
    rendBarrens      = "barrens",
    rendBarrensShort = "barrens",
    onyH             = "orgrimmar",
    nefH             = "orgrimmar",
    onyA             = "stormwind",
    nefA             = "stormwind",
    zan              = "*",
}

local function WantsMainSlot(timerKey)
    local need = MAIN_WHEN[timerKey]
    if not need then return false end
    return need == "*" or need == PlayerZoneKind()
end

------------------------------------------------------------------------
-- Live bar stack
------------------------------------------------------------------------

-- slots is an ordered list of records: { key, bar, endsAt, span, big }.
-- Ordering falls out of insertion, so no separate sort list is needed.
local slots = {}
local pool = {}

-- Late relays keep arriving after a bar finishes; a key stays shut for a
-- minute so a stale packet cannot restart a countdown that already ran.
local RESTART_BLOCK = 60
local blockedUntil = {}

-- Upper bound on distinct keys that can coexist: three rend variants, two
-- ony, two nef and zan.
local SLOT_LIMIT = 8

local function SlotOf(timerKey)
    for i = 1, #slots do
        if slots[i].key == timerKey then return slots[i], i end
    end
end

local function KeyIsFree(timerKey)
    if SlotOf(timerKey) then return false end
    local gate = blockedUntil[timerKey]
    return not (gate and GetTime() < gate)
end

local function TakeBar()
    return table.remove(pool) or BuildBar("HIGH", true)
end

local function RecycleBar(bar)
    bar:Hide()
    bar:ClearAllPoints()
    pool[#pool + 1] = bar
end

local CRITICAL_AT = 3

local function TierColor(left, c)
    local tint, dim = c.colorBase, 1
    if left <= CRITICAL_AT then
        -- Hold the red channel steady and breathe the other two.
        tint = c.colorCrit
        dim = (math.sin(GetTime() * 4.0) + 1) * 0.5
    elseif left <= c.expandThreshold then
        tint = c.colorWarn
    end
    return tint[1], tint[2] * dim, tint[3] * dim
end

local function ClockText(left)
    if left <= 0 then return "0.0" end
    if left >= 60 then
        return string.format("%d:%02d", math.floor(left / 60), math.floor(left % 60))
    end
    if left >= 5 then return string.format("%d", math.ceil(left)) end
    return string.format("%.1f", left)
end

PT.TierColor = TierColor
PT.ClockText = ClockText

local bigList, smallList = {}, {}

local function RelayoutBars()
    local c = Cfg()
    wipe(bigList)
    wipe(smallList)
    for i = 1, #slots do
        local slot = slots[i]
        if slot.bar:IsShown() then
            local target = slot.big and bigList or smallList
            target[#target + 1] = slot.bar
        end
    end
    StackBars(bigList, mainAnchor, "CENTER", c.mainW, c.mainH, 4)
    StackBars(smallList, idleAnchor, "TOPRIGHT", c.smallW, c.smallH, 3)
end

-- Sub-second bar animation needs per-frame work, so this stays an OnUpdate.
-- It only runs while something is on screen and stops itself when empty.
local driver = CreateFrame("Frame", nil, UIParent)
driver:Hide()

driver:SetScript("OnUpdate", function(self)
    local now = GetTime()
    local c = Cfg()
    local dirty = false

    for i = #slots, 1, -1 do
        local slot = slots[i]
        local left = slot.endsAt - now
        if left > 0 then
            slot.bar:SetValue(left / slot.span)
            slot.bar:SetBarColor(TierColor(left, c))
            slot.bar.time:SetText(ClockText(left))
            -- Walking between zones can promote or demote a running bar.
            local big = WantsMainSlot(slot.key)
            if big ~= slot.big then
                slot.big = big
                dirty = true
            end
        else
            blockedUntil[slot.key] = now + RESTART_BLOCK
            RecycleBar(slot.bar)
            table.remove(slots, i)
            dirty = true
        end
    end

    if dirty then RelayoutBars() end

    if #slots == 0 then
        self:Hide()
        for key, gate in pairs(blockedUntil) do
            if now >= gate then blockedUntil[key] = nil end
        end
    end
end)

function PT:StartBar(timerKey, duration, epoch, triggerSource)
    local c = Cfg()
    if not c.enabled then return end

    -- The bar stack has its own raid kill-switch, separate from the
    -- per-channel alert toggles.
    local ts = TimerStore()
    local rd = ts and ts.alerts and ts.alerts.raidDisable
    if rd and rd.pullTimerBars and InsideRaidInstance() then return end

    local now = GetTime()
    local gate = blockedUntil[timerKey]
    if gate and now < gate then return end

    -- A relayed event carries the server time of the yell, so show what is
    -- actually left rather than a fresh full-length countdown.
    local left = duration
    if epoch and epoch > 0 then
        local age = GetServerTime() - epoch
        if age > 0 then left = duration - age end
    end
    if left <= 0 then return end

    local slot = SlotOf(timerKey)
    if slot then
        -- Two sources describing the same drop: only correct the running
        -- bar when the new estimate disagrees by more than a couple seconds.
        local running = slot.endsAt - now
        if running > 0 and math.abs(running - left) <= 2 then return end
        slot.endsAt = now + left
        slot.span = left
        return
    end

    if #slots >= SLOT_LIMIT then return end

    local def = BAR_DEF[timerKey]
    local bar = TakeBar()
    bar:SetIcon(def and def.icon or ICON.rend)
    bar.label:SetText(def and def.text or timerKey)
    bar.time:SetText(ClockText(left))
    bar:SetValue(1)
    bar:SetBarColor(TierColor(left, c))
    bar:Show()

    slots[#slots + 1] = {
        key = timerKey,
        bar = bar,
        endsAt = now + left,
        span = left,
        big = WantsMainSlot(timerKey),
    }

    RelayoutBars()
    driver:Show()
    -- Sound belongs to DispatchAlert at the call site so raid disable and
    -- per-event toggles still apply.
end

function PT:HasActiveBar(timerKey)
    return SlotOf(timerKey) ~= nil
end

------------------------------------------------------------------------
-- Yell entry points
------------------------------------------------------------------------
local THRALL_KEYS = { "rendOrg", "rendBarrens" }
local HERALD_KEYS = { "rendBarrensShort" }

function PT:OnRendYell(source, yellNum, epoch, triggerSource)
    if yellNum == 2 then return false end

    local keys
    if source == "thrall" then
        keys = THRALL_KEYS
    elseif source == "herald" then
        -- The Crossroads herald is only useful when Thrall's yell was
        -- missed; the long Barrens bar already covers the same drop.
        if SlotOf("rendBarrens") then return false end
        keys = HERALD_KEYS
    else
        return false
    end

    local started = false
    for i = 1, #keys do
        if KeyIsFree(keys[i]) then
            self:StartBar(keys[i], REND_SECONDS[keys[i]], epoch, triggerSource)
            started = true
        end
    end
    return started
end

local function DragonYell(self, prefix, faction, yellNum, epoch, triggerSource)
    if yellNum == 2 then return false end
    local key = prefix .. ((faction == "H") and "H" or "A")
    if not KeyIsFree(key) then return false end
    self:StartBar(key, YELL_SECONDS[key][1], epoch, triggerSource)
    return true
end

function PT:OnOnyYell(faction, yellNum, epoch, triggerSource)
    return DragonYell(self, "ony", faction, yellNum, epoch, triggerSource)
end

function PT:OnNefYell(faction, yellNum, epoch, triggerSource)
    return DragonYell(self, "nef", faction, yellNum, epoch, triggerSource)
end

function PT:OnZanYell(yellNum, epoch, triggerSource)
    if not KeyIsFree("zan") then return false end
    self:StartBar("zan", YELL_SECONDS.zan[yellNum == 1 and 1 or 2], epoch, triggerSource)
    return true
end

function PT:OnQuestHandin(buff, questID, isExternal)
    -- An external hand-in is only a rumour, so it gets a softer wording.
    local tail = isExternal and "MAYBE Buff!" or "buff incoming!"
    local msg = (HANDIN_NAMES[buff] or buff) .. " quest handed in \226\128\148 " .. tail
    self:DispatchAlert("questHandin", AlertKeyFor(buff), msg, TINT_INCOMING)
end

function PT:OnNpcDeath(npcName, npcBuff)
    local msg = npcName .. " has been killed!"
    self:DispatchAlert("npcDied", AlertKeyFor(npcBuff or "ony"), msg, TINT_DEATH)
end

------------------------------------------------------------------------
-- Settings page preview
------------------------------------------------------------------------

-- Rows are { label, icon, time text, fill }.
local PREVIEW_ROWS = {
    main = {
        { "Orgrimmar \226\128\148 Rend", ICON.rend, "4.2", 0.75 },
        { "Horde Ony",                   ICON.ony,  "11",  0.5 },
        { "Horde Nef",                   ICON.nef,  "13",  0.3 },
    },
    idle = {
        { "Barrens \226\128\148 Rend", ICON.rend, "16", 0.6 },
        { "Alliance Ony",              ICON.ony,  "12", 0.6 },
        { "Zandalar",                  ICON.zan,  "45", 0.6 },
    },
}

local PREVIEW_GROUPS = {
    {
        id = "main", anchor = mainAnchor, corner = "CENTER", gap = 4,
        wKey = "mainW", hKey = "mainH",
        tint = function(i)
            if i == 1 then return 1, 0.8, 0 end
            return 0.2, 0.8, 0.2
        end,
    },
    {
        id = "idle", anchor = idleAnchor, corner = "TOPRIGHT", gap = 3,
        wKey = "smallW", hKey = "smallH",
        tint = function() return 0.2, 0.6, 0.8 end,
    },
}

local previewFrames = { main = {}, idle = {} }
local previewTimer

local function BuildPreview()
    for g = 1, #PREVIEW_GROUPS do
        local id = PREVIEW_GROUPS[g].id
        local rows, frames = PREVIEW_ROWS[id], previewFrames[id]
        for i = 1, #rows do
            if not frames[i] then frames[i] = BuildBar("DIALOG", false) end
            frames[i]:SetIcon(rows[i][2])
            frames[i].label:SetText(rows[i][1])
            frames[i].time:SetText(rows[i][3])
            frames[i]:SetValue(rows[i][4])
        end
    end
end

function PT:RefreshPreviewLayout()
    if not previewTimer then return end
    local c = Cfg()
    UpdateAnchorSizes()
    for g = 1, #PREVIEW_GROUPS do
        local grp = PREVIEW_GROUPS[g]
        local frames = previewFrames[grp.id]
        StackBars(frames, grp.anchor, grp.corner, c[grp.wKey], c[grp.hKey], grp.gap)
        for i = 1, #frames do
            frames[i]:SetBarColor(grp.tint(i))
            frames[i]:Show()
        end
    end
end

function PT:HidePreview()
    if previewTimer then
        previewTimer:Cancel()
        previewTimer = nil
    end
    for _, frames in pairs(previewFrames) do
        for i = 1, #frames do frames[i]:Hide() end
    end
end

function PT:ShowPreview(seconds)
    BuildPreview()
    if previewTimer then previewTimer:Cancel() end
    previewTimer = C_Timer.NewTimer(seconds or 8, function()
        previewTimer = nil
        PT:HidePreview()
    end)
    PT:RefreshPreviewLayout()
end

------------------------------------------------------------------------
-- The settings page preview (the /rc window's strip): the same bars and
-- banner, built by the code above on the strip's canvas with sample
-- timers, stacked and sized exactly as the live ones.
------------------------------------------------------------------------
-- { label, icon, seconds left, fill }: one bar in the warning colour, two
-- in the base colour (as they read 4, 11 and 13 seconds out)
PT.SAMPLE_ROWS = {
    main = {
        { BAR_DEF.rendOrg.text, ICON.rend, 4.2, 0.75 },
        { BAR_DEF.onyH.text,    ICON.ony,  11,  0.5 },
        { BAR_DEF.nefH.text,    ICON.nef,  13,  0.3 },
    },
    idle = {
        { BAR_DEF.rendBarrens.text, ICON.rend, 16, 0.6 },
        { BAR_DEF.onyA.text,        ICON.ony,  12, 0.6 },
        { BAR_DEF.zan.text,         ICON.zan,  45, 0.6 },
    },
}
PT.SAMPLE_ALERT = HANDIN_NAMES.onyH .. " quest handed in \226\128\148 buff incoming!"
PT.STACK = { main = { wKey = "mainW", hKey = "mainH", gap = 4, corner = "CENTER" },
             idle = { wKey = "smallW", hKey = "smallH", gap = 3, corner = "TOPRIGHT" } }
PT.ALERT_SIZE = function() return alertFrame:GetWidth() or 600, alertFrame:GetHeight() or 40 end
PT.Cfg = Cfg

-- A bar for the preview (no strata, not clamped, on `parent`).
function PT.NewBar(parent) return BuildBar(nil, false, parent) end

-- Lays `bars` out as the live stack `which` ("main" / "idle") lays its
-- bars, fills them with the sample timers and paints them with the live
-- tier colours. Returns the stack's width and height.
function PT.LayoutSample(bars, which, anchor)
    local c = Cfg()
    local st = PT.STACK[which]
    local rows = PT.SAMPLE_ROWS[which]
    local w, h = c[st.wKey], c[st.hKey]
    StackBars(bars, anchor, "TOP", w, h, st.gap)
    for i = 1, #bars do
        local row, bar = rows[i], bars[i]
        bar:SetIcon(row[2])
        bar.label:SetText(row[1])
        bar.time:SetText(ClockText(row[3]))
        bar:SetValue(row[4])
        bar:SetStatusBarTexture(BarFillTexture())
        bar:SetBarColor(TierColor(row[3], c))
        bar:Show()
    end
    return w, #bars * h + (#bars - 1) * st.gap
end

------------------------------------------------------------------------
-- UIMover hookup
------------------------------------------------------------------------

-- UIMover comes up around t+1s and accepts late registrations, so poll for
-- it instead of assuming load order.
local function RegisterMovers(triesLeft)
    if not (RC.UIMover and RC.UIMover.RegisterFrame) then
        if triesLeft > 0 then
            C_Timer.After(1, function() RegisterMovers(triesLeft - 1) end)
        end
        return
    end

    for i = 1, #POS_SPEC do
        local spec = POS_SPEC[i]
        RC.UIMover:RegisterFrame(spec.id, spec.frame, spec.label,
            { point = spec.point, relPoint = spec.point, x = spec.x, y = spec.y })
    end

    RC:DebugPrint("WorldTools bars registered with UIMover", "worldbuffs")
end

local function ReapplyPositions()
    ApplyAnchorPositions()
    ApplyAlertPosition()
end

-- Store() can still be nil at file scope, so re-read the saved offsets once
-- the database is definitely loaded.
C_Timer.After(1, ReapplyPositions)
C_Timer.After(2, function() RegisterMovers(9) end)
