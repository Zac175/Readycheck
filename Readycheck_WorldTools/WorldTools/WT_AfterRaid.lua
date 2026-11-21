------------------------------------------------------------------------
-- Readycheck - World buffs after the raid
--
-- When the raid is over and world buffs are still running (not stored
-- in a Chronoboon) a small window opens: one icon per buff with the time
-- it has left - a click cancels that buff - and one button that boons
-- what is left. Once they are stored the same window says so and its
-- button becomes Unboon. (2026-11-13, Zac: "a popup window that lets me
-- click each of the buffs to cancel them and then a button to boon or
-- unboon")
--
-- "Over" is either of two moments: the raid's last boss dies (Zac:
-- "should also show if we killed the last boss but im still in the raid
-- instance"), or the character leaves the raid instance. "Keep them"
-- after the last boss is an answer: leaving does not ask again. A window
-- closed any other way (the X, Escape) is asked once more on the way out.
--
-- Off until ticked (Chronoboon page > After the raid). The switch and
-- the window's spot live in the character profile, in db.boonReminder
-- (afterRaid, afterRaidPos), so they travel with that category.
--
-- THE ROW KEEPS ITS PLACES. A world buff that is not on the player is
-- drawn dimmed in its own place instead of being left out, so a click
-- that cancels one buff does not slide the next one under the mouse
-- (2026-11-18, Zac: "i want it to not hide buffs that i dont have so it
-- doesnt move icons around"). Which buffs keep a place is a choice
-- (db.boonReminder.afterRaidRow; unset = "all"):
--   "all"     every world buff this character can carry, always
--   "opened"  the buffs that were running when the window opened
--   "live"    only the buffs still running (the icons close up)
-- How dim a kept place is drawn is a setting too (afterRaidDim, 0.1 to 1;
-- unset = 0.3), and so is whether the Boon button waits while the
-- Chronoboon is on cooldown (afterRaidCdLock = false: it stays live; the
-- time left is shown either way).
--
-- COMBAT. The Boon button uses an item, so it is a secure button, and a
-- window with a secure button in it cannot be shown, hidden, moved or
-- sized by an addon in combat. The window therefore only ever opens,
-- changes and closes out of combat: PLAYER_REGEN_DISABLED (which fires
-- just before the lockdown) hides it, PLAYER_REGEN_ENABLED brings it
-- back. Cancelling a buff from addon code is also out of combat only.
--
-- UNIT_AURA never does work here: the shared aura dispatcher wakes the
-- window (coalesced), and only while it is open.
------------------------------------------------------------------------
if _G.Readycheck and _G.Readycheck.FeatureOn
    and not (_G.Readycheck:FeatureOn("world_tools") and _G.Readycheck:FeatureOn("chronoboon")) then return end
local RC = _G.Readycheck
if not RC then return end
local WT = RC.WorldTools
if not (WT and WT.TrackedAuraSlot) then return end

local ipairs, pairs, type, tonumber = ipairs, pairs, type, tonumber
local math_floor, math_max = math.floor, math.max
local string_format = string.format
local InCombatLockdown = InCombatLockdown
local GetTime = GetTime
local GetItemCount = GetItemCount or (RC.Compat and RC.Compat.GetItemCount)

local AR = {}
RC.AfterRaidBuffs = AR

-- the buff a stored Chronoboon leaves on the player (as BoonReminder)
local STORED_AURAS = { [349981] = true, [349977] = true }
local ITEM_EMPTY, ITEM_FULL = 184937, 184938    -- Chronoboon Displacer / Supercharged
-- Battle Shout sits in the tracked catalogue for the summon trigger; it
-- is not a world buff anyone cancels or boons after a raid
local NOT_SHOWN = { BS = true }
-- Warchief's Blessing is handed out in Orgrimmar: an Alliance character
-- only carries it after a mind control, so it gets no standing place
-- there (it still shows, at the row's end, when it is on the player)
local HORDE_ONLY = { Rend = true }

local W_MIN, PAD = 372, 24
local HEADER_H, FOOTER_H = 44, 50
local ICON, GAP = 36, 12
local SMALL, SMALL_GAP = 24, 6
local HINT_H, TIME_H = 12, 12
local PRIMARY_W, SECOND_W = 132, 96
local AURA_KEY, TICK = "AfterRaidBuffs", 1.0
local GRACE = 4     -- seconds a Boon / Unboon click may take to show up

-- The boss that ends each raid, by encounter id (ENCOUNTER_END's first
-- value; warcraft.wiki.gg DungeonEncounterID) and, in case a client
-- reports another id, by its English name.
local LAST_BOSS_ID = {
    [672] = true,   -- Ragnaros (Molten Core)
    [617] = true,   -- Nefarian (Blackwing Lair)
    [717] = true,   -- C'Thun (Temple of Ahn'Qiraj)
    [1114] = true,  -- Kel'Thuzad (Naxxramas)
    [1084] = true,  -- Onyxia (Onyxia's Lair)
    [793] = true,   -- Hakkar (Zul'Gurub)
    [723] = true,   -- Ossirian the Unscarred (Ruins of Ahn'Qiraj)
}
local LAST_BOSS_NAME = {
    ["Ragnaros"] = true, ["Nefarian"] = true, ["C'Thun"] = true, ["Kel'Thuzad"] = true,
    ["Onyxia"] = true, ["Hakkar"] = true, ["Ossirian the Unscarred"] = true,
}

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------
local function Settings()
    local db = RC.db
    if type(db) ~= "table" then return nil end
    if type(db.boonReminder) ~= "table" then db.boonReminder = {} end
    return db.boonReminder
end

function AR.Enabled()
    local s = Settings()
    return (s ~= nil and s.afterRaid == true) or false
end

function AR.SetEnabled(on)
    local s = Settings()
    if not s then return end
    s.afterRaid = on and true or nil
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
    if not on then AR.Close() end
end

local function PosStore()
    local s = Settings()
    if not s then return nil end
    if type(s.afterRaidPos) ~= "table" then s.afterRaidPos = {} end
    return s.afterRaidPos
end

-- Which buffs keep a place in the row (see the head of this file).
local ROW_DEFAULT = "all"
AR.ROW_MODES = {
    { value = "all",    label = RCL["Keep a place for every world buff"] },
    { value = "opened", label = RCL["Keep the place of a buff that goes"] },
    { value = "live",   label = RCL["Hide them (the icons close up)"] },
}
local ROW_KNOWN = { all = true, opened = true, live = true }

function AR.RowMode()
    local s = Settings()
    local v = s and s.afterRaidRow
    return (v and ROW_KNOWN[v]) and v or ROW_DEFAULT
end

-- How strongly a buff that is not on the player is drawn, 0.1 .. 1.
local MISSING_ALPHA = 0.3
AR.MISSING_ALPHA = MISSING_ALPHA
function AR.MissingAlpha()
    local s = Settings()
    local v = s and tonumber(s.afterRaidDim)
    if not v or v ~= v then return MISSING_ALPHA end
    return math_max(0.1, math.min(1, v))
end
-- Whether the Boon / Unboon button waits while its Chronoboon is on cooldown.
-- How big the running buffs are drawn (afterRaidIcon, 24 to 64; nothing
-- saved = 36). The space between two of them follows the size (a third
-- of it: 12 at 36).
AR.ICON_MIN, AR.ICON_MAX, AR.ICON_DEFAULT = 24, 64, ICON
function AR.IconSize()
    local s = Settings()
    local v = s and tonumber(s.afterRaidIcon)
    if not v or v ~= v then return ICON end
    return math_max(AR.ICON_MIN, math.min(AR.ICON_MAX, math_floor(v + 0.5)))
end
function AR.IconGap()
    local size = AR.IconSize()
    if size == ICON then return GAP end
    return math_max(4, math_floor(size / 3 + 0.5))
end
function AR.CooldownLocks()
    local s = Settings()
    return not (s and s.afterRaidCdLock == false)
end

------------------------------------------------------------------------
-- What is on the player
------------------------------------------------------------------------
local function OrderOf()
    local rank = {}
    for position, slot in ipairs(WT.AURA_DISPLAY_ORDER or {}) do rank[slot] = position end
    return rank
end

-- The world buffs running on the player, in the board's order, and
-- whether a Chronoboon is holding stored ones. One entry per buff:
-- { slot, spellId, name, icon, expires, boonable }.
function AR.Live()
    local list, stored = {}, false
    local catalogue = WT:GetTrackedAuraList()
    for _, a in ipairs(RC.Auras:Buffs()) do
        if a.spellId and STORED_AURAS[a.spellId] then stored = true end
        local slot = WT:TrackedAuraSlot(a.spellId, a.name)
        local entry = slot and catalogue[slot]
        if entry and not NOT_SHOWN[entry.short] then
            list[#list + 1] = {
                slot = slot, spellId = a.spellId, name = a.name,
                icon = a.icon or (entry.options[1] and entry.options[1].icon),
                expires = a.expirationTime or 0,
                boonable = WT:IsAuraBoonable(slot),
                order = #list,
            }
        end
    end
    local rank = OrderOf()
    table.sort(list, function(x, y)
        local rx, ry = rank[x.slot] or 99, rank[y.slot] or 99
        if rx ~= ry then return rx < ry end
        return x.order < y.order
    end)
    return list, stored
end

-- Sample buffs for the preview and the mover: this class's world buffs
-- from the catalogue, with made-up times.
local SAMPLE_LEFT = { 4320, 1860, 6000, 3900, 3900, 1320, 2880 }
local function SampleList()
    local list = {}
    local catalogue = WT:GetTrackedAuraList()
    local _, class = UnitClass("player")
    for _, slot in ipairs(WT.AURA_DISPLAY_ORDER or {}) do
        local entry = catalogue[slot]
        if entry and not NOT_SHOWN[entry.short] and not entry.optional
            and (not entry.requiredClasses or entry.requiredClasses[class]) then
            local option = entry.options[1]
            list[#list + 1] = {
                slot = slot, spellId = option.id, name = option.label, icon = option.icon,
                left = SAMPLE_LEFT[#list % #SAMPLE_LEFT + 1], boonable = WT:IsAuraBoonable(slot),
                sample = true,
            }
        end
    end
    return list
end

local function Have(itemId)
    return ((GetItemCount and GetItemCount(itemId)) or 0) > 0
end

-- The world buffs this character can carry, in the board's order: the
-- places an "all" row always has.
local function StandingPlaces()
    local places = {}
    local catalogue = WT:GetTrackedAuraList()
    local _, class = UnitClass("player")
    local alliance = UnitFactionGroup and UnitFactionGroup("player") == "Alliance"
    for _, slot in ipairs(WT.AURA_DISPLAY_ORDER or {}) do
        local entry = catalogue[slot]
        if entry and not NOT_SHOWN[entry.short] and not entry.optional
            and (not entry.requiredClasses or entry.requiredClasses[class])
            and not (alliance and HORDE_ONLY[entry.short]) then
            local option = entry.options[1]
            if option then
                places[#places + 1] = {
                    key = slot, slot = slot, spellId = option.id, name = option.label, icon = option.icon,
                }
            end
        end
    end
    return places
end

-- "1h 12m", "31m", "45s"; nothing for a buff with no end
function AR.TimeText(seconds)
    seconds = tonumber(seconds)
    if not seconds or seconds <= 0 then return "" end
    seconds = math_floor(seconds)
    if seconds >= 3600 then
        return string_format("%dh %02dm", math_floor(seconds / 3600), math_floor((seconds % 3600) / 60))
    elseif seconds >= 60 then
        return string_format("%dm", math_floor(seconds / 60))
    end
    return string_format("%ds", seconds)
end

-- Seconds until the Chronoboon the button would use can be used again
-- (nil: it is ready, or none is carried). The cooldown is read off the
-- item in the bags; one of a few seconds is the global cooldown, not
-- the item's own. A cooldown that began before the computer was started
-- comes with a start time one turn of the client's 32-bit millisecond
-- clock ahead: that turn is taken off. An answer that still makes no
-- sense (more left than the cooldown is long) is not shown.
local CD_REAL = 10
local CLOCK_TURN = 4294967.296
function AR.CooldownLeft(itemId)
    if not (itemId and RC.Bags and RC.Bags.Cooldown) then return nil end
    local start, duration = RC.Bags:Cooldown(itemId)
    if not (start and start > 0 and duration and duration > CD_REAL) then return nil end
    local now = GetTime()
    if start > now + 1 then start = start - CLOCK_TURN end
    local left = start + duration - now
    if left <= 0 or left > duration then return nil end
    return left
end

local function CooldownText(left)
    return string_format(RCL["Chronoboon cooldown: %s"], AR.TimeText(left))
end

local function LeftOf(buff)
    if buff.left then return buff.left end
    if (buff.expires or 0) <= 0 then return nil end
    return buff.expires - GetTime()
end

------------------------------------------------------------------------
-- The window
------------------------------------------------------------------------
local frame
local state = { open = false, sample = false, shown = {}, kept = {}, sig = "" }
AR.state = state

-- The row for the buffs running now: one cell per place, in an order
-- that does not change while the window is open. A cell is the running
-- buff itself, or - for a place whose buff is not on the player - a
-- stand-in { missing = true } that is drawn dimmed and takes no click.
-- state.row remembers the places (and the last buff seen in each); a
-- buff with no place yet gets one at the end - the one way the row
-- grows while the window is open.
function AR.Cells(live)
    local mode = AR.RowMode()
    if mode == "live" then
        state.row = nil
        return live
    end
    if not state.row or state.rowMode ~= mode then
        state.row = (mode == "all") and StandingPlaces() or {}
        state.rowMode = mode
    end
    local row = state.row
    local byKey, taken = {}, {}
    for _, place in ipairs(row) do byKey[place.key] = place end
    for _, buff in ipairs(live) do
        local key = buff.slot
        if taken[key] then
            -- a second buff of one slot (two of Sayge's fortunes never
            -- run together, but nothing here depends on that)
            key = tostring(buff.slot) .. ":" .. tostring(buff.spellId or buff.name)
        end
        local place = byKey[key]
        if not place then
            place = { key = key, slot = buff.slot }
            row[#row + 1] = place
            byKey[key] = place
        end
        taken[key] = buff
        place.spellId, place.name, place.icon = buff.spellId, buff.name, buff.icon
    end
    local cells = {}
    for i, place in ipairs(row) do
        cells[i] = taken[place.key] or {
            slot = place.slot, spellId = place.spellId, name = place.name, icon = place.icon,
            missing = true,
        }
    end
    return cells
end

local function Red() return RC:GetColor("text", "red") end

local function PaintIcon(b, hot)
    local accent = RC.UI:SAccent()
    local lit = hot and b.buff and not b.buff.sample and not b.buff.missing and not b.stored
    if lit then
        RC.UI:UpdateBorderColor(b.border, Red(), 1)
    else
        RC.UI:UpdateBorderColor(b.border, RC:GetColor("ui", "borderNormal"), 1)
    end
    b.cross:SetShown(lit and true or false)
    local c = lit and Red() or accent
    b.time:SetTextColor(c.r, c.g, c.b, 1)
end

local function ShowBuffTip(b)
    local buff = b.buff
    if not buff then return end
    GameTooltip:SetOwner(b, "ANCHOR_TOP")
    GameTooltip:SetText(buff.name or "", 1, 1, 1)
    local gray = RC:GetColor("text", "gray")
    if b.stored then
        GameTooltip:AddLine(RCL["Stored in your Chronoboon"], gray.r, gray.g, gray.b)
    elseif buff.missing then
        GameTooltip:AddLine(RCL["Not on you"], gray.r, gray.g, gray.b)
    elseif buff.sample then
        GameTooltip:AddLine(RCL["A sample - nothing to cancel"], gray.r, gray.g, gray.b)
    else
        local red = Red()
        GameTooltip:AddLine(RCL["Click to cancel this buff"], red.r, red.g, red.b)
        if not buff.boonable then
            GameTooltip:AddLine(RCL["A Chronoboon cannot store this one"], gray.r, gray.g, gray.b)
        end
    end
    GameTooltip:Show()
end

-- Cancels the buff an icon stands for. Read afresh at the click: the
-- buff's place in the list moves whenever another buff comes or goes.
function AR.Cancel(buff)
    if not buff or buff.sample or buff.missing then return false end
    if InCombatLockdown() then
        RC:DebugPrint("AfterRaid: cancel refused in combat", "worldbuffs")
        return false
    end
    RC.Auras:Invalidate()
    for _, a in ipairs(RC.Auras:Buffs()) do
        if (buff.spellId and a.spellId == buff.spellId) or (not buff.spellId and a.name == buff.name) then
            CancelUnitBuff("player", a.index, "HELPFUL")
            RC:DebugPrint("AfterRaid: cancelled " .. tostring(a.name), "worldbuffs")
            RC.Auras:Invalidate()
            return true
        end
    end
    return false
end

local function AcquireIcon(i)
    local f = frame
    local b = f.icons[i]
    if b then return b end
    b = CreateFrame("Button", nil, f.body)
    b:RegisterForClicks("LeftButtonUp")
    b.tex = b:CreateTexture(nil, "ARTWORK")
    b.tex:SetAllPoints()
    b.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.border = RC.UI:CreateSimpleBorder(b)
    b.cross = b:CreateTexture(nil, "OVERLAY", nil, 2)
    b.cross:SetPoint("CENTER")
    b.cross:SetTexture((RC.UI.ICONS or "Interface\\AddOns\\Readycheck\\Media\\Icons\\") .. "close")
    b.cross:Hide()
    b.time = RC:CreateFontString(f.body, "OVERLAY", nil, 10)
    b.time:SetPoint("TOP", b, "BOTTOM", 0, -4)
    local accent = RC.UI:SAccent()
    RC.UI:AttachHover(b, accent, accent, {
        onEnter = function(self) PaintIcon(self, true) ShowBuffTip(self) end,
        onLeave = function(self) PaintIcon(self, false) GameTooltip:Hide() end,
    })
    b:SetScript("OnClick", function(self)
        if self.stored or not self.buff or self.buff.missing then return end
        if AR.Cancel(self.buff) then
            GameTooltip:Hide()
            AR.Refresh()
        end
    end)
    f.icons[i] = b
    return b
end

-- One row of icons, centred (the live buffs) or from the left (stored).
-- A cell whose buff is not on the player is dimmed and has no time.
local function LayIcons(list, size, gap, top, stored)
    local f = frame
    local n = #list
    local rowW = n * size + math_max(0, n - 1) * gap
    local x0 = stored and PAD or math_floor((f:GetWidth() - rowW) / 2 + 0.5)
    for i, buff in ipairs(list) do
        local b = AcquireIcon(i)
        b.buff, b.stored = buff, stored
        b:SetSize(size, size)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", f.body, "TOPLEFT", x0 + (i - 1) * (size + gap), top)
        local missing = buff.missing and true or false
        b.tex:SetTexture(buff.icon)
        b.tex:SetDesaturated((stored or missing) and true or false)
        b.tex:SetAlpha(stored and 0.45 or (missing and AR.MissingAlpha()) or 1)
        local red = Red()
        b.cross:SetSize(size / 2, size / 2)
        b.cross:SetVertexColor(red.r, red.g, red.b, 1)
        b.time:SetShown(not stored and not missing)
        b.time:SetText((stored or missing) and "" or AR.TimeText(LeftOf(buff)))
        PaintIcon(b, (not stored) and b:IsMouseOver() or false)
        b:Show()
    end
    for i = n + 1, #f.icons do
        f.icons[i].buff = nil
        f.icons[i]:Hide()
        f.icons[i].time:Hide()
    end
end

-- The Boon / Unboon button: what a click uses (nil = nothing to use).
-- While that Chronoboon is on cooldown the button waits and the footer
-- shows the time left in place of its usual line (2026-11-18, Zac: "can
-- we show chrono cd if its not up"); the ticker counts it down and lays
-- the window out again when it is over.
local function SetAction(label, itemId)
    local f = frame
    local left = itemId and AR.CooldownLeft(itemId) or nil
    state.cdItem = left and itemId or nil
    if left then
        f.status:SetText(CooldownText(left))
        if AR.CooldownLocks() then itemId = nil end
    end
    RC.UI:SetButtonText(f.primary, label)
    f.primary:SetEnabled(itemId ~= nil)
    f.primary:Repaint()
    f.action = itemId
    f.secure:SetAttribute("type", itemId and "macro" or nil)
    f.secure:SetAttribute("macrotext", itemId and ("/use item:" .. itemId) or nil)
end

local function SizeTo(n, bodyH)
    local f = frame
    local w = math_max(W_MIN, PAD * 2 + n * AR.IconSize() + math_max(0, n - 1) * AR.IconGap())
    f:SetSize(w, HEADER_H + bodyH + FOOTER_H + 2)
end

-- What the window is showing, as one string: it is only laid out again
-- when this changes (the ticker asks every second).
local function Signature(live, stored)
    local parts = { stored and "S" or "-", Have(ITEM_EMPTY) and "E" or "-", Have(ITEM_FULL) and "F" or "-",
        AR.CooldownLeft(ITEM_EMPTY) and "e" or "-", AR.CooldownLeft(ITEM_FULL) and "f" or "-" }
    for _, buff in ipairs(live) do parts[#parts + 1] = tostring(buff.spellId or buff.name) end
    return table.concat(parts, ",")
end

local function Layout(live, stored)
    local f = frame
    local nLive = #live
    local shown = live
    if nLive > 0 then
        -- buffs still running
        local boonable = 0
        for _, buff in ipairs(live) do if buff.boonable then boonable = boonable + 1 end end
        -- the row: the running buffs, and the places kept for the others
        local cells = state.sample and live or AR.Cells(live)
        shown = cells
        f.titleText:SetText(RCL["World buffs still on you"])
        f.hint:SetText(state.sample and RCL["Preview: sample buffs."] or RCL["Click a buff to cancel it."])
        local size = AR.IconSize()
        SizeTo(#cells, 4 + HINT_H + 12 + size + 4 + TIME_H + 10)
        LayIcons(cells, size, AR.IconGap(), -(4 + HINT_H + 12), false)
        RC.UI:SetButtonText(f.second, RCL["Keep them"])
        if state.sample then
            f.status:SetText("")
            SetAction(string_format(RCL["Boon all %d"], boonable), nil)
        elseif stored then
            f.status:SetText(RCL["Chronoboon is full"])
            SetAction(RCL["Unboon"], Have(ITEM_FULL) and ITEM_FULL or nil)
        elseif boonable == 0 then
            f.status:SetText("")
            SetAction(RCL["Nothing to boon"], nil)
        else
            local have = Have(ITEM_EMPTY)
            f.status:SetText(have and RCL["Chronoboon ready"] or RCL["No Chronoboon in your bags"])
            SetAction(boonable == 1 and RCL["Boon 1 buff"] or string_format(RCL["Boon all %d"], boonable),
                have and ITEM_EMPTY or nil)
        end
        -- what a Boon click will store, for the stored view. (Right after
        -- the click the buffs may leave in more than one step: the list
        -- from before the click is the one that was stored.)
        local kept = {}
        for _, buff in ipairs(live) do
            if buff.boonable then kept[#kept + 1] = buff end
        end
        local midBoon = state.graceFor == ITEM_EMPTY and GetTime() < (state.graceUntil or 0)
        if not (midBoon and #kept < #state.kept) then state.kept = kept end
    else
        -- stored in the Chronoboon
        local kept = state.kept
        f.titleText:SetText(RCL["World buffs stored"])
        if #kept == 1 then
            f.hint:SetText(RCL["1 buff is in your Chronoboon."])
        elseif #kept > 1 then
            f.hint:SetText(string_format(RCL["%d buffs are in your Chronoboon."], #kept))
        else
            f.hint:SetText(RCL["Your world buffs are in your Chronoboon."])
        end
        SizeTo(0, 4 + HINT_H + ((#kept > 0) and (12 + SMALL + 10) or 10))
        LayIcons(kept, SMALL, SMALL_GAP, -(4 + HINT_H + 12), true)
        f.status:SetText("")
        RC.UI:SetButtonText(f.second, RCL["Close"])
        SetAction(RCL["Unboon"], Have(ITEM_FULL) and ITEM_FULL or nil)
    end
    state.shown = shown
end

local function StopTicker()
    if state.ticker then
        state.ticker:Cancel()
        state.ticker = nil
    end
end

local function Tick()
    local f = frame
    if not (f and state.open and f:IsShown()) or InCombatLockdown() then return end
    if state.sample then return end
    local live, stored = AR.Live()
    if Signature(live, stored) ~= state.sig then
        AR.Refresh()
        return
    end
    for i, buff in ipairs(state.shown) do
        local b = f.icons[i]
        if b and b.buff == buff and not b.stored then b.time:SetText(AR.TimeText(LeftOf(buff))) end
    end
    if state.cdItem then
        local left = AR.CooldownLeft(state.cdItem)
        if left then f.status:SetText(CooldownText(left)) end
    end
end

local function StartTicker()
    if state.ticker then return end
    if RC.Profiler and RC.Profiler.TrackTicker then
        state.ticker = RC.Profiler:TrackTicker("AfterRaidBuffs", TICK, Tick)
    else
        state.ticker = C_Timer.NewTicker(TICK, Tick)
    end
end

local watchIds
local function WatchAuras(on)
    if not on then
        RC:UnregisterUnitAuraCallback(AURA_KEY)
        return
    end
    if not watchIds then
        watchIds = {}
        for id in pairs(STORED_AURAS) do watchIds[#watchIds + 1] = id end
        for _, entry in ipairs(WT:GetTrackedAuraList()) do
            for _, option in ipairs(entry.options) do watchIds[#watchIds + 1] = option.id end
        end
    end
    RC:RegisterUnitAuraCallback(AURA_KEY, 0.25, function()
        if state.open then AR.Refresh() end
    end, watchIds)
end

local function Build()
    local UI = RC.UI
    local f = UI:CreatePopupShell("ReadycheckAfterRaidBuffs", {
        width = W_MIN, height = HEADER_H + 90 + FOOTER_H + 2, title = RCL["World buffs still on you"],
        headerH = HEADER_H, footerH = FOOTER_H, strata = "HIGH",
        onClose = function() AR.Close() end,
    })
    f.icons = {}

    f.hint = RC:CreateFontString(f.body, "OVERLAY", nil, 11, "")
    f.hint:SetPoint("TOPLEFT", f.body, "TOPLEFT", PAD, -4)
    f.hint:SetJustifyH("LEFT")

    -- right to left: Keep them, then the gold Boon button
    f.second = f:AddFooterButton(RCL["Keep them"], SECOND_W, false, function()
        -- "Keep them" inside the raid is an answer: leaving does not ask again
        if not state.sample and #state.shown > 0 and RC:IsInRaidInstance() then state.keep = true end
        AR.Close()
    end, "right")
    f.primary = f:AddFooterButton(RCL["Boon all %d"], PRIMARY_W, true, nil, "right")

    f.status = RC:CreateFontString(f.footer, "OVERLAY", nil, 10, "")
    f.status:SetPoint("LEFT", f.footer, "LEFT", PAD, 0)
    f.status:SetPoint("RIGHT", f.primary, "LEFT", -10, 0)
    f.status:SetJustifyH("LEFT")
    f.status:SetWordWrap(true)
    if f.status.SetMaxLines then f.status:SetMaxLines(2) end
    UI:SkinPopup(f, { texts = { f.hint }, dims = { f.status } })

    -- The gold button is the look; the click lands on a secure button
    -- laid over it (only a secure button may use an item).
    f.primary:EnableMouse(false)
    local secure = CreateFrame("Button", nil, f.footer, "SecureActionButtonTemplate")
    secure:SetAllPoints(f.primary)
    secure:SetFrameLevel((f.primary:GetFrameLevel() or 1) + 2)
    -- both edges, so it works whichever way "cast on key down" is set
    secure:RegisterForClicks("LeftButtonDown", "LeftButtonUp")
    local accent = UI:SAccent()
    UI:AttachHover(secure, accent, accent, {
        onEnter = function() local s = f.primary:GetScript("OnEnter") if s then s(f.primary) end end,
        onLeave = function() local s = f.primary:GetScript("OnLeave") if s then s(f.primary) end end,
    })
    secure:HookScript("PostClick", function()
        if f.action then state.graceUntil, state.graceFor = GetTime() + GRACE, f.action end
    end)
    f.secure = secure

    -- dragged by its header, kept where it is put (pinned by its top
    -- middle, so a taller or wider window grows down and out from there)
    f.header:SetScript("OnDragStart", function()
        if InCombatLockdown() then return end
        f.__rcDragging = true
        f:StartMoving()
    end)
    f.header:SetScript("OnDragStop", function()
        if not f.__rcDragging then return end
        f.__rcDragging = nil
        f:StopMovingOrSizing()
        if RC.Position and RC.Position.IsBound(f) then
            RC.Position.SaveFrame(f)
            RC.Position.RestoreFrame(f)
        end
    end)

    -- closed any other way (Escape): the same tidy-up as Close. Hidden
    -- for combat is not closed.
    f:HookScript("OnHide", function()
        if state.hiddenForCombat then return end
        if state.open then AR.Closed() end
    end)
    -- shown by something else (the mover): a sample, so it has its size
    f:HookScript("OnShow", function()
        if state.open or InCombatLockdown() then return end
        state.sample = true
        Layout(SampleList(), false)
        state.sample = false
    end)
    return f
end

-- Built on first use; the mover calls it so the window can be placed
-- before a raid ever opens it. Never built in combat.
function AR.Ensure()
    if frame then return frame end
    if InCombatLockdown() then return nil end
    if not (RC.UI and RC.UI.CreatePopupShell and RC.db) then return nil end
    frame = Build()
    state.sample = true
    Layout(SampleList(), false)
    state.sample = false
    if RC.Position and RC.Position.Bind then
        RC.Position.Bind(frame, PosStore,
            { point = "TOP", xKey = "x", yKey = "y", default = { point = "CENTER", x = 0, y = 140 } })
        RC.Position.RestoreFrame(frame)
    end
    if RC.UIMover and RC.UIMover.RegisterFrame then
        RC.UIMover:RegisterFrame("afterRaidBuffs", frame, "After-Raid World Buffs",
            { point = "CENTER", relPoint = "CENTER", x = 0, y = 140 })
    end
    return frame
end
RC.EnsureAfterRaidBuffs = AR.Ensure

-- Lays the window out for what is on the player now; closes it when
-- there is nothing left to show. Out of combat only.
function AR.Refresh()
    local f = frame
    if not (f and state.open) or InCombatLockdown() then return end
    local live, stored
    if state.sample then
        live, stored = SampleList(), false
    else
        live, stored = AR.Live()
        if #live == 0 and not stored then
            -- Just after a Boon or Unboon click the buffs and the stored
            -- mark do not always change in the same moment: wait (the
            -- ticker asks again) instead of closing in between.
            if GetTime() < (state.graceUntil or 0) then return end
            AR.Close()
            return
        end
    end
    state.sig = Signature(live, stored)
    Layout(live, stored)
end

-- The row choice, from the settings page. An open window is laid out
-- again at once (out of combat; in a fight it follows when it comes back).
function AR.SetRowMode(mode)
    local s = Settings()
    if not s then return end
    s.afterRaidRow = (ROW_KNOWN[mode] and mode ~= ROW_DEFAULT) and mode or nil
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
    state.row = nil
    if state.open then AR.Refresh() end
end

function AR.SetMissingAlpha(v)
    local s = Settings()
    if not s then return end
    v = tonumber(v)
    s.afterRaidDim = (v and math.abs(v - MISSING_ALPHA) > 0.001) and math_max(0.1, math.min(1, v)) or nil
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
    if state.open then AR.Refresh() end
end
function AR.SetIconSize(v)
    local s = Settings()
    if not s then return end
    v = tonumber(v)
    if v then v = math_max(AR.ICON_MIN, math.min(AR.ICON_MAX, math_floor(v + 0.5))) end
    s.afterRaidIcon = (v and v ~= ICON) and v or nil
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
    if state.open then AR.Refresh() end
end
function AR.SetCooldownLocks(on)
    local s = Settings()
    if not s then return end
    if on then s.afterRaidCdLock = nil else s.afterRaidCdLock = false end
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
    if state.open then AR.Refresh() end
end

-- Opens the window. reason: "boss" (the raid's last boss died), "raid"
-- (left a raid instance) or "manual" (the settings page's button, which
-- shows samples when no world buff is running). In combat it waits for
-- the fight to end.
function AR.Open(reason)
    if InCombatLockdown() then
        state.pending = reason or "manual"
        return false
    end
    state.pending = nil
    local live, stored = AR.Live()
    local sample = false
    if #live == 0 then
        -- nothing running: nothing to ask about after a raid (buffs that
        -- are already stored need no window). By hand it still opens:
        -- the stored view, or samples.
        if reason ~= "manual" then return false end
        sample = not stored
    end
    local f = AR.Ensure()
    if not f then return false end
    state.open, state.sample = true, sample
    state.row = nil          -- the places are worked out afresh for each window
    if not sample then state.kept = {} end
    AR.Refresh()
    if not state.open then return false end
    f:Show()
    if not sample then
        WatchAuras(true)
        StartTicker()
    end
    RC:DebugPrint("AfterRaid: window opened (" .. tostring(reason) .. (sample and ", sample" or "") .. ")", "worldbuffs")
    return true
end

-- the bookkeeping of a close, however the window went away
function AR.Closed()
    state.open, state.sample, state.pending = false, false, nil
    state.shown = {}
    state.row = nil
    state.cdItem = nil
    state.hiddenForCombat, state.graceUntil, state.graceFor = nil, nil, nil
    StopTicker()
    WatchAuras(false)
end

function AR.Close()
    local wasOpen = state.open
    AR.Closed()
    if frame and frame:IsShown() and not InCombatLockdown() then frame:Hide() end
    if wasOpen then RC:DebugPrint("AfterRaid: window closed", "worldbuffs") end
end

function AR.IsOpen() return state.open end

------------------------------------------------------------------------
-- When it opens
------------------------------------------------------------------------
-- nil until the first loading screen has been read: logging in outside
-- a raid is not "leaving" one
local wasInRaid

function AR.OnZone()
    local inRaid = RC:IsInRaidInstance() and true or false
    local left = (wasInRaid == true) and not inRaid
    local entered = (wasInRaid == false) and inRaid
    wasInRaid = inRaid
    if entered then
        -- walked into a raid: the window is for after it, and whatever
        -- was answered in the last one is over
        if state.open and not state.sample then AR.Close() end
        state.pending, state.keep = nil, nil
        return
    end
    if not left then return end
    local kept = state.keep
    state.keep = nil
    if kept or not AR.Enabled() then return end
    if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return end
    -- (already open since the last boss: it simply stays)
    if state.open and not state.sample then return end
    AR.Open("raid")
end

-- ENCOUNTER_END: the raid's last boss killed, still inside. The fight is
-- usually not over for the client yet, so the window waits for it (Open).
function AR.OnEncounterEnd(encounterID, encounterName, success)
    if success ~= 1 then return end
    if not (LAST_BOSS_ID[tonumber(encounterID) or 0] or LAST_BOSS_NAME[encounterName or ""]) then return end
    if not AR.Enabled() or not RC:IsInRaidInstance() then return end
    state.keep = nil
    RC:DebugPrint("AfterRaid: last boss down (" .. tostring(encounterName) .. ")", "worldbuffs")
    -- a moment, so the buff list is the one after the kill
    C_Timer.After(1, function()
        if UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") then return end
        if state.open and not state.sample then return end
        AR.Open("boss")
    end)
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_REGEN_DISABLED")
ev:RegisterEvent("PLAYER_REGEN_ENABLED")
ev:RegisterEvent("ENCOUNTER_END")
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        -- a moment for the buffs to be readable after the loading screen
        C_Timer.After(2, AR.OnZone)
    elseif event == "ENCOUNTER_END" then
        local encounterID, encounterName, _, _, success = ...
        AR.OnEncounterEnd(encounterID, encounterName, success)
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- fires just before the lockdown: the last moment it can be hidden
        if frame and state.open and frame:IsShown() and not InCombatLockdown() then
            state.hiddenForCombat = true
            frame:Hide()
            StopTicker()
        end
    else
        if state.hiddenForCombat and state.open and frame then
            state.hiddenForCombat = nil
            AR.Refresh()
            if state.open then
                frame:Show()
                if not state.sample then StartTicker() end
            end
        elseif state.pending then
            AR.Open(state.pending)
        end
    end
end)
