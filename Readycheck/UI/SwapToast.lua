------------------------------------------------------------------------
-- Readycheck - Swap notices
-- A small on-screen notice when Readycheck changes your gear for you:
-- a route step, a boss pull or kill, a trinket rotation, a queued swap
-- that lands when combat ends. It says WHY (the set, the step, the
-- boss) and WHAT (the pieces that went on, with icons), then fades.
--
-- How it knows a change was ours and not you dragging an item: every
-- place in the addon that equips something first calls
-- RC:NoteSwapIntent(label, icon) (a short window of "the next
-- equipment changes are mine"); PLAYER_EQUIPMENT_CHANGED inside that
-- window is collected for half a second and shown as one notice. Your
-- own manual swaps never make one.
--
-- Off by default. Settings in RC.db.swapToast; the full set of options
-- (look, text, animation, sound, position, with a live preview) is on
-- the Gear Manager page, and the Raid Route tab keeps a short card.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local GetTime = GetTime
local GetInventoryItemID = GetInventoryItemID
local GetInventoryItemTexture = GetInventoryItemTexture
local GetItemInfo = GetItemInfo or (RC.Compat and RC.Compat.GetItemInfo)
local string_format = string.format
local table_sort = table.sort

local ST = {}
RC.SwapToast = ST

local DEFAULTS = {
    enabled = false,        -- off by default: it is a notice, not a feature you asked for
    duration = 4,           -- seconds on screen before the fade
    scale = 1.0,
    showNames = true,       -- the pieces by name on the second line (up to four)
    showBackground = true,  -- the box; off, the text sits on the world with a shadow
    locked = true,
    soundKey = "",          -- a LibSharedMedia sound, "" = silent
    anchorPoint = "CENTER",
    xOffset = 0,
    yOffset = 220,
}

local MAX_NAMED = 4         -- pieces named on the second line; more than that is a count
local MAX_STRIP = 10        -- icons in the strip
local MAX_W = 320           -- untouched, the notice never grows past this; names truncate
local MIN_W, MAX_USER_W = 180, 480   -- what the grip may drag it to
local HANDLE_W = 34         -- the title bar's far end: padlock + grip
local INTENT_WINDOW = 5     -- seconds an intent covers equipment changes
local COALESCE = 0.5        -- seconds to collect the slots of one swap
local EMPTY_ICON = "Interface\\Icons\\INV_Misc_Bag_08"

local SLOT_NAMES = {
    [1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest",
    [6] = "Waist", [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands",
    [11] = "Ring 1", [12] = "Ring 2", [13] = "Trinket 1", [14] = "Trinket 2",
    [15] = "Back", [16] = "Main hand", [17] = "Off hand", [18] = "Ranged", [19] = "Tabard",
}

function ST:Wanted()
    return self:Settings().enabled == true
end

function ST:Settings()
    if not RC.db then return DEFAULTS end
    local s = RC.db.swapToast
    if type(s) ~= "table" then
        s = {}
        RC.db.swapToast = s
    end
    for k, v in pairs(DEFAULTS) do
        if s[k] == nil then s[k] = v end
    end
    return s
end

-- Swaps are collected while the notice is on, or while something else
-- listens: RC:SwapFeedWanted() (the route tracker's bar style shows each
-- swap on a line under the bar) and RC:OnSwapFeed(entry) receives them.
local function Collecting()
    return ST:Wanted() or (RC.SwapFeedWanted and RC:SwapFeedWanted()) or false
end

------------------------------------------------------------------------
-- INTENT - "the next equipment changes are Readycheck's"
------------------------------------------------------------------------
local intent = nil      -- { label, icon, context, untilAt }
-- what was in each slot when the window opened, so a listener can show
-- old -> new (slot -> { id, icon })
local before = {}
local function SnapBefore()
    for slot = 1, 19 do
        local id = GetInventoryItemID("player", slot)
        local b = before[slot]
        if not b then b = {} before[slot] = b end
        b.id = id
        b.icon = id and GetInventoryItemTexture("player", slot) or nil
    end
end

-- label: what is being put on ("Gear set: DPS", "Trinkets"); icon: for
-- the title (a set's icon), nil for the default. `weak` keeps a better
-- label already in the window (a caller higher up named the reason).
function RC:NoteSwapIntent(label, icon, weak)
    if not Collecting() then return end
    local now = GetTime()
    if weak and intent and intent.untilAt >= now then
        intent.untilAt = now + INTENT_WINDOW
        return
    end
    if not (intent and intent.untilAt >= now) then SnapBefore() end
    local context = intent and intent.untilAt >= now and intent.context or nil
    intent = { label = label or RCL["Gear swap"], icon = icon, context = context,
               untilAt = now + INTENT_WINDOW }
end

-- The reason behind the swaps that follow: a route step, a boss. Shown
-- as the notice's second line.
function RC:NoteSwapContext(text)
    if not Collecting() then return end
    local now = GetTime()
    if intent and intent.untilAt >= now then
        intent.context = text
        intent.untilAt = now + INTENT_WINDOW
    else
        SnapBefore()
        intent = { label = nil, icon = nil, context = text, untilAt = now + INTENT_WINDOW }
    end
end

------------------------------------------------------------------------
-- COLLECTING THE CHANGES
------------------------------------------------------------------------
local changed = {}          -- invSlot -> true, the slots of the swap in flight
local collecting = false

local function Flush()
    collecting = false
    local now = GetTime()
    local it = intent
    if not (it and it.untilAt + COALESCE >= now) then
        for k in pairs(changed) do changed[k] = nil end
        return
    end
    local slots = {}
    for slot in pairs(changed) do slots[#slots + 1] = slot end
    for k in pairs(changed) do changed[k] = nil end
    if #slots == 0 then return end
    table_sort(slots)
    local items = {}
    for _, slot in ipairs(slots) do
        local id = GetInventoryItemID("player", slot)
        local icon = id and GetInventoryItemTexture("player", slot) or EMPTY_ICON
        local name
        if id then
            name = GetItemInfo(id)
            if not name then name = RCL["item"] .. " " .. id end
        else
            name = RCL["Nothing"] .. " (" .. (SLOT_NAMES[slot] or slot) .. ")"
        end
        local b = before[slot]
        items[#items + 1] = { slot = slot, id = id, icon = icon, name = name,
                              oldId = b and b.id, oldIcon = b and b.icon or EMPTY_ICON }
        -- a second change to this slot in the same window starts from here
        if b then b.id, b.icon = id, id and icon or nil end
    end
    if ST:Wanted() then ST:Show(it.label or RCL["Gear swap"], it.icon, it.context, items) end
    if RC.OnSwapFeed then
        RC:OnSwapFeed({ label = it.label or RCL["Gear swap"], icon = it.icon, context = it.context,
                        items = items, at = now })
    end
end

local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
ev:SetScript("OnEvent", function(_, _, slot)
    -- hot-ish during a set swap (one per slot): one table write and at
    -- most one timer per burst
    if not intent or intent.untilAt < GetTime() then return end
    if slot then changed[slot] = true end
    if collecting then return end
    collecting = true
    C_Timer.After(COALESCE, Flush)
end)

------------------------------------------------------------------------
-- THE NOTICE
-- Built by ST.BuildNotice(parent, live), styled by ST:Style(f) and laid
-- out by ST:Layout(cur, f): the live notice and the settings preview
-- sample both go through these, so they always look the same. Every
-- look setting is optional in RC.db.swapToast; nil is the shipped look.
------------------------------------------------------------------------
local frame
local hideTimer

-- what an unset setting means (the shipped look and timings)
ST.SHOW_ANIM    = { style = "fade", duration = 0.15, easing = "easeOutCubic" }
ST.HIDE_ANIM    = { style = "fade", duration = 0.4, easing = "easeInOutQuad" }
ST.TITLE_FONT   = { size = 12, outline = "OUTLINE", shadow = true }
ST.NAMES_FONT   = { size = 11, outline = "OUTLINE", shadow = true }
ST.CONTEXT_FONT = { size = 10, outline = "OUTLINE", shadow = true }
ST.ICON_SIZE    = 18
ST.ICON_GAP     = 3
ST.BG_ALPHA     = 0.94

-- the font spec, then the notice's softer shadow (0.9) when it has one
local function Font(fs, spec, defaults)
    RC:ApplyFontSpec(fs, spec, defaults)
    local sh = type(spec) == "table" and spec.shadow or nil
    if sh == nil then sh = defaults.shadow end
    if sh then fs:SetShadowColor(0, 0, 0, 0.9) end
end

local function Ring(f, ic, color)
    local bd = f:CreateTexture(nil, "ARTWORK", nil, -1)
    bd:SetPoint("TOPLEFT", ic, "TOPLEFT", -1, 1)
    bd:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT", 1, -1)
    bd:SetColorTexture(color.r, color.g, color.b, 1)
    bd:Hide()
    ic.bd = bd
    return ic
end

local PAD, HEAD_H = 8, 22

-- The same small panel as the route tracker: a Readycheck title bar
-- (header art) carrying the reason's icon and "<set> equipped", the
-- pieces that went on as a strip of icons underneath with their names
-- in one line, and the route step or boss as a quiet line when known.
-- live = the real notice (named, positioned, movable, in Edit Mode);
-- otherwise a plain sample for the settings preview.
function ST.BuildNotice(parent, live)
    local f = CreateFrame("Frame", live and "ReadycheckSwapToast" or nil, parent)
    f:SetSize(240, 56)
    if live then
        f:SetFrameStrata("MEDIUM")
        f:SetClampedToScreen(true)
        f:SetScale(tonumber(ST:Settings().scale) or 1)   -- the saved spot is in the frame's units
        RC.Position.Bind(f, function() return ST:Settings() end,
            { point = "TOPLEFT", pointKey = "anchorPoint", default = { point = "CENTER", relPoint = "CENTER", x = 0, y = 220 } })
        RC.Position.RestoreFrame(f)
        RC.Position.MakeMovable(f, function() return ST:Settings().locked ~= true end)
        f:Hide()
    end

    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(RC.UI.FLAT)
    f.bg = bg
    f.border = RC.UI:CreateSimpleBorder(f)

    local head = CreateFrame("Frame", nil, f)
    head:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
    head:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
    head:SetHeight(HEAD_H)
    local hfill = head:CreateTexture(nil, "BACKGROUND")
    hfill:SetAllPoints()
    hfill:SetTexture(RC.UI.FLAT)
    head.fill = hfill
    if RC.UI.ApplyHeaderArt then
        RC.UI:ApplyHeaderArt(head, { compact = true })
    end
    f.head = head

    local ring = RC:GetColor("ui", "borderNormal")
    local tIcon = Ring(head, head:CreateTexture(nil, "ARTWORK"), ring)
    tIcon:SetSize(14, 14)
    tIcon:SetPoint("LEFT", head, "LEFT", PAD, 1)
    tIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    f.titleIcon = tIcon

    local title = RC:CreateFontString(head, "OVERLAY", nil, 12)
    title:SetPoint("LEFT", tIcon, "RIGHT", 6, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    f.title = title

    f.strip = {}
    for i = 1, MAX_STRIP do
        local ic = Ring(f, f:CreateTexture(nil, "ARTWORK"), ring)
        ic:SetSize(ST.ICON_SIZE, ST.ICON_SIZE)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ic:Hide()
        f.strip[i] = ic
    end
    local names = RC:CreateFontString(f, "OVERLAY", nil, 11)
    names:SetJustifyH("LEFT")
    names:SetWordWrap(false)
    f.names = names

    local ctx = RC:CreateFontString(f, "OVERLAY", nil, 10)
    ctx:SetJustifyH("LEFT")
    ctx:SetWordWrap(false)
    f.ctx = ctx

    if live then
        if RC.UIMover and RC.UIMover.RegisterFrame then
            RC.UIMover:RegisterFrame("swapToast", f, "Gear swap notice",
                { point = "CENTER", relPoint = "CENTER", x = 0, y = 220 })
        end
        -- padlock + resize grip over the top-right corner
        if RC.UI.AttachHudHandle then
            f.handle = RC.UI:AttachHudHandle(f, {
                getLocked = function() return ST:Settings().locked ~= false end,
                setLocked = function(locked)
                    ST:Settings().locked = locked
                    RC:SaveConfigurationToProfile()
                end,
                inside = true, corner = "TOPRIGHT", insetX = 7, insetY = 6,
                getWidth = function() return f:GetWidth() end,
                setWidth = function(w)
                    ST:Settings().width = w
                    if ST.current then ST:Layout(ST.current) end
                end,
                onWidthEnd = function() RC:SaveConfigurationToProfile() end,
                minW = MIN_W, maxW = MAX_USER_W,
            })
        end
    end
    ST:Style(f)
    return f
end

local function Build()
    if frame then return frame end
    if not (RC.UI and RC.GetColor and RC.CreateFontString and RC.Position) then return nil end
    frame = ST.BuildNotice(UIParent, true)
    return frame
end

-- The live notice made (hidden) while the notice is switched on, so the
-- frame mover can place it before the first swap. nil while it is off.
function ST:Ensure()
    if not self:Wanted() then return nil end
    return Build()
end

local function SetBox(f, on)
    f.bg:SetShown(on)
    if f.border and RC.UI.SetBorderShown then
        RC.UI:SetBorderShown(f.border, on)
    elseif f.border then
        for _, t in pairs(f.border) do
            if type(t) == "table" and t.SetShown then t:SetShown(on) end
        end
    end
end

local function ColorOr(c, cat, key)
    if type(c) == "table" then return c end
    return RC:GetColor(cat, key)
end

-- Colours, fonts, background and icon size from the settings.
function ST:Style(f)
    if not f then return end
    local s = self:Settings()
    local bgc = s.bgColor
    if type(bgc) == "table" then
        f.bg:SetVertexColor(bgc.r or 0, bgc.g or 0, bgc.b or 0, bgc.a or ST.BG_ALPHA)
    else
        local cardBg = RC:GetColor("ui", "cardBackground")
        f.bg:SetVertexColor(cardBg.r, cardBg.g, cardBg.b, ST.BG_ALPHA)
    end
    if f.border and RC.UI.UpdateBorderColor then
        RC.UI:UpdateBorderColor(f.border, ColorOr(s.borderColor, "ui", "borderNormal"))
    end
    Font(f.title, s.titleFont, ST.TITLE_FONT)
    Font(f.names, s.namesFont, ST.NAMES_FONT)
    Font(f.ctx, s.contextFont, ST.CONTEXT_FONT)
    local ht = ColorOr(s.titleColor, "ui", "headerText")
    f.title:SetTextColor(ht.r, ht.g, ht.b)
    local nt = ColorOr(s.namesColor, "text", "normal")
    f.names:SetTextColor(nt.r, nt.g, nt.b)
    local tg = ColorOr(s.contextColor, "text", "gray")
    f.ctx:SetTextColor(tg.r, tg.g, tg.b)
    local isz = tonumber(s.iconSize) or ST.ICON_SIZE
    local gap = tonumber(s.iconGap) or ST.ICON_GAP
    for i, ic in ipairs(f.strip) do
        ic:SetSize(isz, isz)
        ic:ClearAllPoints()
        if i == 1 then
            ic:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -(HEAD_H + 8))
        else
            ic:SetPoint("LEFT", f.strip[i - 1], "RIGHT", gap, 0)
        end
    end
    -- layer / clamp, fade rules, shadow / glow (the standard; its own scale
    -- and colours stay its own)
    if RC.ApplyFrameCustom then
        RC:ApplyFrameCustom(f, function() return ST:Settings() end,
            { scale = false, sample = (f:GetName() ~= "ReadycheckSwapToast") })
    end
end

function ST:ShowSpec() return RC.Motion.Normalize(self:Settings().showAnim, ST.SHOW_ANIM) end
function ST:HideSpec() return RC.Motion.Normalize(self:Settings().hideAnim, ST.HIDE_ANIM) end

-- the generic labels a chokepoint gives; a named set beats them
local GENERIC = { [RCL["Trinkets"]] = true, [RCL["Slot gear"]] = true,
                  [RCL["Queued gear swap"]] = true, [RCL["Gear swap"]] = true }

-- "Gear set: DPS" -> "DPS equipped"; "Trinkets" -> "Trinkets swapped"
local function Headline(label)
    local set = label and label:match("^" .. RCL["Gear set: "] .. "(.+)$")
    if set then return set .. RCL[" equipped"] end
    if GENERIC[label] then return label .. RCL[" swapped"] end
    return label or RCL["Gear swapped"]
end
ST.Headline = Headline
ST.GENERIC = GENERIC

-- items: { { icon, name, id, slot }, ... }
function ST:Show(label, icon, context, items)
    local s = self:Settings()
    if not s.enabled then return end
    local f = Build()
    if not f then return end

    -- One route step (or one boss) equips in waves: the set, then the
    -- trinkets a second later, then slot items. While the notice for the
    -- first wave is still up, a later wave with the same reason is added
    -- to it - pieces appended (a slot that changed twice shows its final
    -- item), the named set kept as the title - instead of replacing it.
    local cur = self.current
    if cur and f:IsShown() and (cur.context == context or context == nil or cur.context == nil)
            and (GetTime() - cur.at) <= (tonumber(s.duration) or 4) + 1 then
        local merged, bySlot = {}, {}
        for _, it in ipairs(cur.items) do
            merged[#merged + 1] = it
            if it.slot then bySlot[it.slot] = #merged end
        end
        for _, it in ipairs(items) do
            if it.slot and bySlot[it.slot] then merged[bySlot[it.slot]] = it
            else merged[#merged + 1] = it if it.slot then bySlot[it.slot] = #merged end end
        end
        items = merged
        if GENERIC[label] and not GENERIC[cur.label] then
            label, icon = cur.label, cur.icon
        elseif GENERIC[label] and GENERIC[cur.label] and label ~= cur.label then
            label = RCL["Gear swap"]
        end
        context = context or cur.context
    end
    self.current = { label = label, icon = icon, context = context, items = items, at = GetTime() }

    if f.popAnimation then f.popAnimation:Cancel() f.popAnimation = nil end
    if hideTimer then hideTimer:Cancel() hideTimer = nil end
    self:Style(f)
    self:Layout(self.current)

    if s.soundKey and s.soundKey ~= "" and RC.PlaySoundKey then
        RC:PlaySoundKey(s.soundKey)
    end
    if RC.Motion then RC.Motion.Show(f, self:ShowSpec()) else f:SetAlpha(1) f:Show() end
    hideTimer = C_Timer.NewTimer(tonumber(s.duration) or 4, function()
        hideTimer = nil
        ST.current = nil
        if RC.Motion then RC.Motion.Hide(f, ST:HideSpec()) else f:Hide() end
    end)
end

-- Lays the notice out for one swap. The panel is as wide as the user
-- dragged it (width); untouched it is as wide as its content needs,
-- never past MAX_W. Called again live while the grip is dragged.
-- f: a preview sample; nil = the live notice.
function ST:Layout(cur, f)
    local s = self:Settings()
    local live = not f
    f = f or Build()
    if not f then return end
    local label, icon, context, items = cur.label, cur.icon, cur.context, cur.items or {}
    local fixedW = tonumber(s.width)
    if fixedW and (fixedW < MIN_W or fixedW > MAX_USER_W) then fixedW = nil end
    local wrapW = fixedW or MAX_W
    local handleW = f.handle and HANDLE_W or 0
    local isz = tonumber(s.iconSize) or ST.ICON_SIZE
    local gap = tonumber(s.iconGap) or ST.ICON_GAP

    local sc = tonumber(s.scale) or 1
    if math.abs((f:GetScale() or 1) - sc) > 0.001 then
        if live and RC.Position.SetScaleKeepingPoint then RC.Position.SetScaleKeepingPoint(f, sc, true)
        else f:SetScale(sc) end
    end
    SetBox(f, s.showBackground ~= false)
    if f.head.RepaintArt then f.head:RepaintArt() end

    -- title bar
    f.titleIcon:SetTexture(icon or (items[1] and items[1].icon) or EMPTY_ICON)
    f.titleIcon.bd:Show()
    f.title:SetText(Headline(label))
    f.title:SetWidth(math.max(40, wrapW - PAD - 14 - 6 - PAD - handleW))
    local natW = PAD + 14 + 6 + (f.title:GetStringWidth() or 60) + PAD + handleW

    -- the pieces
    local y = -(HEAD_H + 8)
    local n = #items
    local shown = math.min(n, MAX_STRIP)
    for i = 1, MAX_STRIP do
        local ic = f.strip[i]
        if i <= shown then ic:SetTexture(items[i].icon) ic:Show() ic.bd:Show()
        else ic:Hide() ic.bd:Hide() end
    end
    local text
    if n > 0 and s.showNames ~= false and n <= MAX_NAMED then
        local parts = {}
        for i = 1, n do parts[i] = items[i].name end
        text = table.concat(parts, ", ")
    elseif n > 0 then
        text = (n == 1) and RCL["1 piece"] or string_format(RCL["%d pieces"], n)
    end
    local rowW = PAD + (shown > 0 and (shown * (isz + gap) - gap) or 0)
    f.names:ClearAllPoints()
    if text then
        f.names:SetText(text)
        if shown > 0 then f.names:SetPoint("LEFT", f.strip[shown], "RIGHT", 7, 0)
        else f.names:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y - 2) end
        local nw = f.names:GetStringWidth() or 0
        local room = wrapW - rowW - 7 - PAD
        if nw > room then nw = room end
        f.names:SetWidth(math.max(20, nw + 2))
        f.names:Show()
        rowW = rowW + 7 + nw
    else
        f.names:Hide()
    end
    if natW < rowW + PAD then natW = rowW + PAD end
    if shown > 0 or text then
        local nh = (f.names:GetStringHeight() or 12)
        y = y - math.max(shown > 0 and isz or 0, text and nh or 0) - 5
    end

    -- the reason
    if context and context ~= "" then
        f.ctx:SetText(context)
        f.ctx:ClearAllPoints()
        f.ctx:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
        f._stCtxY = y
        f.ctx:SetWidth(wrapW - 2 * PAD)
        f.ctx:Show()
        local cw = (f.ctx:GetStringWidth() or 0) + 2 * PAD
        if cw > natW then natW = cw end
        y = y - math.max(14, (f.ctx:GetStringHeight() or 10) + 2)
    else
        f.ctx:Hide()
    end
    f:SetSize(fixedW or math.min(MAX_W, math.max(MIN_W, natW)), -y + 4)
    -- swapToast.anchors.title / .names / .context: a spec moves the text
    -- from where the notice put it (the size above stays the notice's)
    local anc = type(s.anchors) == "table" and s.anchors or nil
    if anc then
        local function To(k)
            if k == "icon" then return f.titleIcon elseif k == "title" then return f.title
            elseif k == "names" then return f.names elseif k == "strip" then return f.strip[1]
            elseif k == "frame" then return f end
        end
        f._stDef = f._stDef or { title = {}, names = {}, context = {} }
        RC.UI:AnchorOver(f.title, anc.title, f._stDef.title, "LEFT", f.titleIcon, "RIGHT", 6, 0, To)
        if text then
            if shown > 0 then RC.UI:AnchorOver(f.names, anc.names, f._stDef.names, "LEFT", f.strip[shown], "RIGHT", 7, 0, To)
            else RC.UI:AnchorOver(f.names, anc.names, f._stDef.names, "TOPLEFT", f, "TOPLEFT", PAD, -(HEAD_H + 8) - 2, To) end
        end
        if context and context ~= "" then
            RC.UI:AnchorOver(f.ctx, anc.context, f._stDef.context, "TOPLEFT", f, "TOPLEFT", PAD, f._stCtxY or 0, To)
        end
    end
    if f.handle then f.handle.Refresh() end
end

function ST:Hide()
    if hideTimer then hideTimer:Cancel() hideTimer = nil end
    self.current = nil
    if frame then
        if RC.Motion then RC.Motion.Stop(frame) end
        frame:Hide()
    end
end

-- What the Test button and the settings preview show: a set, a route
-- step and three pieces. kind = "set" (default), "trinkets", "many".
function ST.Sample(kind)
    local function Icon(id, fb) return (GetItemInfo and select(10, GetItemInfo(id))) or fb end
    local three = {
        { icon = Icon(19019, 135349), name = "Thunderfury, Blessed Blade of the Windseeker", slot = 16 },
        { icon = Icon(19406, 133440), name = "Drake Fang Talisman", slot = 13 },
        { icon = Icon(11815, 133439), name = "Hand of Justice", slot = 14 },
    }
    if kind == "trinkets" then
        return { label = RCL["Trinkets"], context = nil, items = { three[2], three[3] } }
    elseif kind == "many" then
        local many = {}
        for i = 1, 8 do many[i] = three[(i - 1) % 3 + 1] end
        return { label = RCL["Gear set: "] .. "Tank", icon = "Interface\\Icons\\INV_Shield_06",
                 context = RCL["Boss: "] .. (RC:RaidSample("boss2") or "Patchwerk"), items = many }
    end
    return { label = RCL["Gear set: "] .. "DPS", icon = "Interface\\Icons\\INV_Chest_Plate16",
             context = RCL["Route: "] .. "3x Plague Beast", items = three }
end

-- the settings card's Test button
function ST:Test()
    local s = self:Settings()
    local was = s.enabled
    s.enabled = true
    local d = ST.Sample("set")
    self:Show(d.label, d.icon, d.context, d.items)
    s.enabled = was
end

function ST:Refresh()
    if frame then
        local s = self:Settings()
        frame:SetScale(tonumber(s.scale) or 1)
        self:Style(frame)
        SetBox(frame, s.showBackground ~= false)
        if self.current and frame:IsShown() then self:Layout(self.current) end
        RC.Position.RestoreFrame(frame)
        if frame.handle then frame.handle.Refresh() end
    end
end
