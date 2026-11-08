------------------------------------------------------------------------
-- Readycheck - World Tools Settings UI
-- Replaces ShadowNetwork's standalone window: pages inside Readycheck's
-- settings sidebar (/rc) via a "World Tools" category in RC.MenuStructure.
-- Zac-only testing module - not shipped to users.
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not (_G.Readycheck:FeatureOn("world_tools")
    or _G.Readycheck:FeatureOn("world_summons")) then return end
local RC = _G.Readycheck
if not RC then return end
local WT = RC.WorldTools
if not WT then return end

local RCC = RC.Compat or {}
local GetSpellInfo = GetSpellInfo or RCC.GetSpellInfo

-- Shared helpers
local GRAY  = function() return RC:GetColor("text", "gray")   or { r = 0.5, g = 0.5, b = 0.5 } end
local WHITE = function() return RC:GetColor("text", "normal") or { r = 0.9, g = 0.9, b = 0.9 } end

-- Readycheck's own alert sounds first, then everything registered with
-- LibSharedMedia (WT_Bars builds the list fresh each time).
local function SoundOptions()
    local PT = WT.Bars
    if PT and PT.GetSoundOptions then return PT.GetSoundOptions() end
    return PT and PT.SOUND_OPTIONS or nil
end

local function SoundItems()
    local items = {}
    local opts = SoundOptions()
    if opts then
        for _, opt in ipairs(opts) do
            items[#items + 1] = { text = opt.label, value = opt.value }
        end
    else
        items[1] = { text = "None", value = "none" }
    end
    return items
end

local function SoundLabel(value)
    local opts = SoundOptions()
    if opts then
        for _, opt in ipairs(opts) do
            if opt.value == value then return opt.label end
        end
    end
    return value or "None"
end

-- Wrapped description text inside a card. Returns new cardY.
-- (as wide as the card leaves, so it wraps at any window width)
-- one gray line at most; the rest in its tooltip (RC.UI:CreateHelpLine)
local function AddDesc(card, cy, text, width)
    return (RC.UI:CreateHelpLine(card, 15, cy, text, { gap = 10 }))
end

-- Standard settings checkbox inside a card. onSet(value) writes storage.
local function AddCheck(card, cy, label, checked, onSet, indent)
    local cb = RC.UI:CreateCheckbox(card, label, checked)
    cb:SetPoint("TOPLEFT", card, "TOPLEFT", 15 + (indent or 0), cy)
    cb:SetScript("OnClick", function(c)
        local v = c:GetChecked() and true or false
        onSet(v)
        RC:ForceCheckboxUpdate(c, v)
    end)
    return cy - 22, cb
end

-- Alert row builder (label + On/Screen/Chat/Flash + sound + test)
--
-- The row icon is looked up from the spell each row is about, rather than
-- from a hardcoded texture id. One less magic number to get wrong, and it
-- follows the client's own art if Blizzard ever reworks it.
--
-- Onyxia and Nefarian are the exception and have to be named explicitly:
-- both heads grant the same Rallying Cry buff, so the buff's own icon
-- cannot tell the two rows apart. The dragon heads can.
local ALERT_ROW_SPELL = {
    rend        = 16609,   -- Warchief's Blessing
    zan         = 24425,   -- Spirit of Zandalar
    battleshout = 6673,    -- Battle Shout
    dmf         = 23768,   -- Sayge's Dark Fortune
}
local ALERT_ROW_TEXTURE = {
    ony = "Interface\\Icons\\inv_misc_head_dragon_01",
    nef = "Interface\\Icons\\inv_misc_head_dragon_black",
}
-- Returns nil when the spell is not cached yet; the caller then draws the
-- label with no icon rather than a question mark.
local function AlertRowIcon(buffKey)
    local tex = ALERT_ROW_TEXTURE[buffKey]
    if tex then return tex end
    local spellId = ALERT_ROW_SPELL[buffKey]
    if not spellId then return nil end
    return GetSpellInfo and select(3, GetSpellInfo(spellId)) or nil
end

local function AlertEntry(categoryKey, buffKey)
    local s = WT.Store()
    local ts = s and s.timerSettings
    local cat = ts and ts.alerts and ts.alerts[categoryKey]
    return cat and cat[buffKey] or nil
end

local function AddAlertRow(card, cy, label, categoryKey, buffKey)
    local entry = AlertEntry(categoryKey, buffKey)
    if not entry then return cy end

    local w = WHITE()
    local lbl = RC:CreateFontString(card, "OVERLAY", nil, 11)
    lbl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy - 4)
    lbl:SetWidth(130)
    lbl:SetJustifyH("LEFT")
    lbl:SetWordWrap(false)
    lbl:SetTextColor(w.r, w.g, w.b)
    local iconRef = AlertRowIcon(buffKey)
    local iconMarkup = iconRef and ("|T" .. iconRef .. ":14|t ") or ""
    lbl:SetText(iconMarkup .. label)

    local function toggler(field)
        return function(c)
            local v = c:GetChecked() and true or false
            local e = AlertEntry(categoryKey, buffKey)
            if e then e[field] = v end
            RC:ForceCheckboxUpdate(c, v)
        end
    end

    -- Column layout sized to fit the card at the window's minimum width
    -- (850px window -> ~587px card): rightmost element ends at x=585.
    local COLS = {
        { field = "enabled", label = "On",     x = 150 },
        { field = "notify",  label = "Screen", x = 200 },
        { field = "chat",    label = "Chat",   x = 275 },
        { field = "flash",   label = "Flash",  x = 335 },
    }
    for _, col in ipairs(COLS) do
        local cb = RC.UI:CreateCheckbox(card, col.label, entry[col.field] ~= false)
        cb:SetPoint("TOPLEFT", card, "TOPLEFT", col.x, cy)
        cb:SetScript("OnClick", toggler(col.field))
    end

    local dd = RC.UI:CreateScrollableDropdown(card, 140, "Sound", 6)
    dd:SetPoint("TOPLEFT", card, "TOPLEFT", 400, cy - 1)
    dd:SetItems(SoundItems(), function(value)
        local e = AlertEntry(categoryKey, buffKey)
        if e then e.sound = value end
    end)
    dd:SetSelectedValue(entry.sound or "none", SoundLabel(entry.sound or "none"))

    local testBtn = RC.UI:CreateStyledButton(card, "Test", 40, 21)
    testBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 545, cy)
    testBtn:SetScript("OnClick", function()
        local e = AlertEntry(categoryKey, buffKey)
        local PT = WT.Bars
        if e and PT then
            local st = WT.Store()
            local channel = (st and st.timerSettings and st.timerSettings.soundChannel) or "Master"
            PT.PlayConfigSound(e.sound, channel)
        end
    end)

    -- 30px pitch: the 28px-tall dropdowns need >27px to avoid overlap
    return cy - 30
end

-- PREVIEW: the buff drop bars and the screen alert, exactly as they show
-- in game - the bars' own constructor and stacking (WT_Bars), the sizes
-- and colours set below, sample timers. One stack (or the banner) at a
-- time: in game they sit in different places on screen.
local BAR_MODES = {
    { id = "main",  label = RCL["Main bars"] },
    { id = "idle",  label = RCL["Small bars"] },
    { id = "alert", label = RCL["Screen alert"] },
}
local function BarsPreviewBuild(canvas, P)
    local PT = WT.Bars
    if not (PT and PT.NewBar) then return end
    local st = P.store
    st.holder = CreateFrame("Frame", nil, canvas)
    st.holder:SetPoint("CENTER", canvas, "CENTER", 0, 0)
    st.holder:SetSize(10, 10)
    st.bars = { main = {}, idle = {} }
    for _, which in ipairs({ "main", "idle" }) do
        for i = 1, #PT.SAMPLE_ROWS[which] do st.bars[which][i] = PT.NewBar(st.holder) end
    end
    st.alert = PT.NewAlertPlate(st.holder)
end
local function BarsPreviewUpdate(canvas, P)
    local PT = WT.Bars
    local st = P.store
    if not (PT and st.bars) then return end
    local mode = P.mode or "main"
    local w, h
    for _, which in ipairs({ "main", "idle" }) do
        local list = st.bars[which]
        if which == mode then
            w, h = PT.LayoutSample(list, which, st.holder)
        else
            for _, b in ipairs(list) do b:Hide() end
        end
    end
    if mode == "alert" then
        local aw, ah = PT.ALERT_SIZE()
        st.alert.label:SetText(PT.SAMPLE_ALERT)
        st.alert.label:SetTextColor(1, 0.85, 0.2)
        PT.FitAlertPlate(st.alert, aw, ah)
        st.alert:ClearAllPoints()
        st.alert:SetPoint("TOP", st.holder, "TOP", 0, 0)
        st.alert:Show()
        w, h = st.alert:GetWidth(), st.alert:GetHeight()
    else
        st.alert:Hide()
    end
    -- the holder is the stack's box; the canvas is the holder plus a margin
    st.holder:SetSize(w or 10, h or 10)
    P.Resize((w or 10) + 12, (h or 10) + 12)
end

-- PAGE: Pull Timers (account-wide)
function RC:ShowSidebarWTTimers(frame, preserveScroll)
    self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
    local parent = frame.scrollChild
    local s = WT.Store()
    if not s then return end
    local ts = s.timerSettings
    local PT = WT.Bars
    if PT and PT.NewBar then
        self.UI:DeclarePreview({
            key = "worldtools.bars", title = RCL["Buff drop bars"],
            width = 236, height = 70,
            modes = BAR_MODES, modesLabel = RCL["Show"],
            build = BarsPreviewBuild, update = BarsPreviewUpdate,
        })
    end

    local yPos = -20
    local _, newY = self:CreateSettingsPageHeader(parent, yPos,
        "Buff Drops",
        "World buff drop countdown bars, alerts and sounds",
        "Interface\\Icons\\INV_Misc_PocketWatch_02")
    yPos = newY

    -- Card: Buff Drop Bars
    local card = self:CreateSettingsCard(parent, yPos, "Buff drop bars |cff777777(testing)|r")
    local cy = -35

    cy = AddDesc(card, cy,
        "Countdown bars for Rend, Ony, Nef and ZG drops, driven by local detection "
        .. "(NPC yells/says you see, NPC deaths, your own quest hand-ins). You must be "
        .. "in the zone when the drop starts. Bars in your current drop zone render at "
        .. "Main size; other timers use the Small stack.")

    local barsCb
    cy, barsCb = AddCheck(card, cy, "Enable pull timer countdown bars", ts.pullTimerEnabled ~= false, function(v)
        ts.pullTimerEnabled = v
    end)
    cy = cy - 6
    local barsMark = RC.UI:MarkCard(card)

    local wcol = WHITE()
    local function AddSizeSlider(label, key, minV, maxV)
        local lbl = RC:CreateFontString(card, "OVERLAY", nil, 11)
        lbl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy - 2)
        lbl:SetTextColor(wcol.r, wcol.g, wcol.b)
        lbl:SetText(label)
        cy = cy - 20
        -- slider.Text is the framework's numeric value display; overwrite the
        -- built-in OnValueChanged and keep it updated (TestingTargeting pattern)
        local sl = self.UI:CreateSlider(card, minV, maxV, ts[key], 1)
        sl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
        sl.Text:SetText(tostring(ts[key]))
        sl:SetScript("OnValueChanged", function(slider, value)
            value = math.floor(value + 0.5)
            slider.Text:SetText(tostring(value))
            ts[key] = value
            if PT then
                PT.UpdateAnchorSizes()
                PT:RefreshPreviewLayout()
            end
        end)
        cy = cy - 34
    end

    AddSizeSlider("Main bar width",  "pullTimerMainBarWidth",  150, 500)
    AddSizeSlider("Main bar height", "pullTimerMainBarHeight", 16, 48)
    AddSizeSlider("Small bar width",  "pullTimerSmallBarWidth",  100, 400)
    AddSizeSlider("Small bar height", "pullTimerSmallBarHeight", 10, 32)
    AddSizeSlider("Warn color threshold (seconds)", "pullTimerExpandThreshold", 0, 30)
    -- the sizes only matter while the bars are on (preview and move stay live)
    RC.UI:BindDependents(barsCb, RC.UI:CardSince(card, barsMark))

    cy = cy - 8
    local previewBtn = self.UI:CreateStyledButton(card, "Preview Bars (8s)", 140, 24)
    previewBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
    previewBtn:SetScript("OnClick", function()
        if PT then PT:ShowPreview(8) end
    end)

    local moveBtn = self.UI:CreateStyledButton(card, "Move Bars", 110, 24)
    moveBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 165, cy)
    moveBtn:SetScript("OnClick", function()
        if PT then PT:ShowPreview(30) end
        if RC.UIMover and RC.UIMover.EnterMoveMode then
            RC.UIMover:EnterMoveMode()
        end
    end)

    -- the note wraps in what the two buttons leave of the card, or goes
    -- under them when that is too narrow
    local hint = RC:CreateFontString(card, "OVERLAY", nil, 10)
    local g = GRAY()
    local cw = card:GetWidth() or 0
    if cw < 100 then cw = 570 end
    local hx = 285
    local beside = (cw - hx - 15) >= 160
    if not beside then hx = 15 end
    hint:SetPoint("TOPLEFT", card, "TOPLEFT", hx, beside and (cy - 6) or (cy - 32))
    hint:SetWidth(cw - hx - 15)
    hint:SetJustifyH("LEFT")
    hint:SetWordWrap(true)
    hint:SetTextColor(g.r, g.g, g.b)
    hint:SetText("Anchors: WT Buff Drop Bars (Main / Small) + WT Screen Alert in /rc moveui")
    local hh = hint:GetStringHeight() or 12
    cy = cy - (beside and math.max(34, hh + 18) or (32 + hh + 10))

    card:SetContentHeight(math.abs(cy))
    yPos = yPos - card:GetHeight() - 15

    -- Card: Alerts master switch (gates every alert row below)
    local cardA = self:CreateSettingsCard(parent, yPos, "Alerts")
    cy = -35
    cy = AddDesc(cardA, cy,
        "Master switch for every alert on this page - screen, chat, flash and "
        .. "sound. Each row below can still be turned off on its own.")
    local alertsCb
    cy, alertsCb = AddCheck(cardA, cy, "Enable buff drop alerts", ts.alertsEnabled ~= false, function(v)
        ts.alertsEnabled = v
    end)
    -- the alert rows on the cards below follow this master switch
    local alertRows = {}
    local function GateCard(c, m)
        for _, x in ipairs(RC.UI:CardSince(c, m)) do alertRows[#alertRows + 1] = x end
    end
    cardA:SetContentHeight(math.abs(cy))
    yPos = yPos - cardA:GetHeight() - 15

    -- Card: Raid Override
    local card2 = self:CreateSettingsCard(parent, yPos, "Raid override")
    cy = -35
    cy = AddDesc(card2, cy, "Suppress channels while you are inside a raid instance.")

    local rd = ts.alerts.raidDisable
    cy = AddCheck(card2, cy, "Disable screen alerts in raid", rd.notify == true, function(v) rd.notify = v end)
    cy = AddCheck(card2, cy, "Disable chat alerts in raid",   rd.chat == true,   function(v) rd.chat = v end)
    cy = AddCheck(card2, cy, "Disable flash icon in raid",    rd.flash == true,  function(v) rd.flash = v end)
    cy = AddCheck(card2, cy, "Disable sounds in raid",        rd.sound == true,  function(v) rd.sound = v end)
    cy = AddCheck(card2, cy, "Disable pull timer bars in raid", rd.pullTimerBars == true, function(v) rd.pullTimerBars = v end)

    card2:SetContentHeight(math.abs(cy))
    yPos = yPos - card2:GetHeight() - 15

    -- Alert cards
    local card3 = self:CreateSettingsCard(parent, yPos, "Quest hand-in alerts")
    local mark3 = RC.UI:MarkCard(card3)
    cy = -35
    cy = AddAlertRow(card3, cy, "Rend",     "questHandin", "rend")
    cy = AddAlertRow(card3, cy, "Onyxia",   "questHandin", "ony")
    cy = AddAlertRow(card3, cy, "Nefarian", "questHandin", "nef")
    cy = AddAlertRow(card3, cy, "Zandalar", "questHandin", "zan")
    GateCard(card3, mark3)
    card3:SetContentHeight(math.abs(cy))
    yPos = yPos - card3:GetHeight() - 15

    local card4 = self:CreateSettingsCard(parent, yPos, "Buff incoming alerts")
    local mark4 = RC.UI:MarkCard(card4)
    cy = -35
    cy = AddAlertRow(card4, cy, "Rend",        "pullTimer", "rend")
    cy = AddAlertRow(card4, cy, "Onyxia",      "pullTimer", "ony")
    cy = AddAlertRow(card4, cy, "Nefarian",    "pullTimer", "nef")
    cy = AddAlertRow(card4, cy, "Zandalar",    "pullTimer", "zan")
    cy = AddAlertRow(card4, cy, "Battleshout", "pullTimer", "battleshout")
    GateCard(card4, mark4)
    card4:SetContentHeight(math.abs(cy))
    yPos = yPos - card4:GetHeight() - 15

    local card5 = self:CreateSettingsCard(parent, yPos, "NPC died alerts")
    local mark5 = RC.UI:MarkCard(card5)
    cy = -35
    cy = AddAlertRow(card5, cy, "Onyxia NPC",   "npcDied", "ony")
    cy = AddAlertRow(card5, cy, "Nefarian NPC", "npcDied", "nef")
    GateCard(card5, mark5)
    card5:SetContentHeight(math.abs(cy))
    yPos = yPos - card5:GetHeight() - 15

    local card5b = self:CreateSettingsCard(parent, yPos, "Buff cooldown ready |cff777777(guild timer network)|r")
    local mark5b = RC.UI:MarkCard(card5b)
    cy = -35
    -- No Nefarian row: its head turn-in has no cooldown on Era/Anniversary,
    -- so there is no "ready" moment to announce and the alert never fires.
    -- The Nefarian rows on the Buff Dropped card below stay - a drop is a
    -- real event either way.
    cy = AddAlertRow(card5b, cy, "Rend",      "buffCooldown", "rend")
    cy = AddAlertRow(card5b, cy, "Onyxia",    "buffCooldown", "ony")
    GateCard(card5b, mark5b)
    card5b:SetContentHeight(math.abs(cy))
    yPos = yPos - card5b:GetHeight() - 15

    local card5c = self:CreateSettingsCard(parent, yPos, "Buff dropped |cff777777(guild timer network)|r")
    local mark5c = RC.UI:MarkCard(card5c)
    cy = -35
    cy = AddAlertRow(card5c, cy, "Rend",     "buffDropped", "rend")
    cy = AddAlertRow(card5c, cy, "Onyxia",   "buffDropped", "ony")
    cy = AddAlertRow(card5c, cy, "Nefarian", "buffDropped", "nef")
    GateCard(card5c, mark5c)
    RC.UI:BindDependents(alertsCb, alertRows, { indent = 0 })
    card5c:SetContentHeight(math.abs(cy))

    yPos = yPos - card5c:GetHeight() - 15

    -- Card: Sound Channel
    local card6 = self:CreateSettingsCard(parent, yPos, "Sound channel")
    cy = -35
    local w = WHITE()
    local chLbl = RC:CreateFontString(card6, "OVERLAY", nil, 11)
    chLbl:SetPoint("TOPLEFT", card6, "TOPLEFT", 15, cy - 4)
    chLbl:SetTextColor(w.r, w.g, w.b)
    chLbl:SetText("Output channel:")

    local CHANNEL_ITEMS = {
        { text = "Master",        value = "Master" },
        { text = "Sound Effects", value = "SFX" },
        { text = "Music",         value = "Music" },
        { text = "Ambience",      value = "Ambience" },
        { text = "Dialog",        value = "Dialog" },
    }
    local chDd = self.UI:CreateScrollableDropdown(card6, 170, "Master", 5)
    chDd:SetPoint("TOPLEFT", card6, "TOPLEFT", 130, cy - 1)
    chDd:SetItems(CHANNEL_ITEMS, function(value)
        ts.soundChannel = value
    end)
    local curCh = ts.soundChannel or "Master"
    for _, item in ipairs(CHANNEL_ITEMS) do
        if item.value == curCh then
            chDd:SetSelectedValue(curCh, item.text)
            break
        end
    end
    cy = cy - 34

    card6:SetContentHeight(math.abs(cy))
    yPos = yPos - card6:GetHeight() - 15

    if self.UpdateSidebarScrollbar then
        self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
    end
end

-- PAGE: Automation (faction-scoped: summon / gossip / quest)
local DMF_BUFF_OPTIONS = {
    { text = "Damage (+10% Dmg)",        value = "Damage" },
    { text = "Agility (+10% Agi)",       value = "Agility" },
    { text = "Intelligence (+10% Int)",  value = "Intelligence" },
    { text = "Spirit (+10% Spi)",        value = "Spirit" },
    { text = "Stamina (+10% Stam)",      value = "Stamina" },
    { text = "Strength (+10% Str)",      value = "Strength" },
    { text = "Armor (+10% Armor)",       value = "Armor" },
    { text = "Resistance (+25 All Res)", value = "Resistance" },
}

-- Built from the client's own class tables rather than a hand-written
-- list. CLASS_SORT_ORDER carries the tags in Blizzard's canonical order
-- and LOCALIZED_CLASS_NAMES_MALE the display names, so the rows come out
-- in the player's own language instead of English-only, and the list
-- cannot drift out of step with the client it is running on.
local ALL_CLASSES = {}
do
    local order = _G.CLASS_SORT_ORDER
    local names = _G.LOCALIZED_CLASS_NAMES_MALE
    if type(order) == "table" then
        for i = 1, #order do
            local tag = order[i]
            local nm  = names and names[tag]
            if tag and nm then
                ALL_CLASSES[#ALL_CLASSES + 1] = { tag = tag, name = nm }
            end
        end
    end
    -- Last resort for a client exposing neither global: the tags are the
    -- only thing spelled out, and the label is derived from the tag
    -- (WARRIOR -> Warrior) rather than written a second time.
    if #ALL_CLASSES == 0 then
        local ERA_CLASSES =
            "WARRIOR ROGUE HUNTER MAGE WARLOCK PRIEST DRUID PALADIN SHAMAN"
        for tag in string.gmatch(ERA_CLASSES, "%S+") do
            ALL_CLASSES[#ALL_CLASSES + 1] = {
                tag  = tag,
                name = string.sub(tag, 1, 1) .. string.lower(string.sub(tag, 2)),
            }
        end
    end
end

local function BuildSummonSection(self, parent, yPos, Rerender)
    local fs = WT:GetFactionSettings()
    if not fs then return yPos end
    local as = fs.autoSummon

    -- world buffs are Classic Era's (Core_Flavor): elsewhere only the
    -- always / taxi accepts, no buff triggers
    local worldBuffs = RC:FeatureOn("world_tools")
    local card = self:CreateSettingsCard(parent, yPos, "Auto-accept summon |cff777777(testing)|r")
    local cy = -35

    if worldBuffs then
    cy = AddDesc(card, cy,
        "Automatically accept a pending summon when a selected tracked buff is freshly "
        .. "gained. A buff is fresh if it was not previously active (not from un-booning) "
        .. "or if its duration jumped significantly. The accept window runs from the "
        .. "moment the fresh buff is detected.")
    else
    cy = AddDesc(card, cy, RCL["Accept a pending summon on its own: every time, or after your PvP flag drops on a taxi."])
    end

    local summonCb
    cy, summonCb = AddCheck(card, cy, "Enable auto-accept summon", as.enabled == true, function(v)
        as.enabled = v
    end)
    local summonMark = RC.UI:MarkCard(card)
    cy = AddCheck(card, cy, worldBuffs and "Always accept summon (ignore buff triggers)" or RCL["Always accept summon"], as.alwaysAccept == true, function(v)
        as.alwaysAccept = v
    end)
    cy = AddCheck(card, cy, "Taxi PVP drop (accept when PVP flag drops on a taxi)", as.taxiPvpDrop == true, function(v)
        as.taxiPvpDrop = v
    end)
    cy = cy - 6

    -- Auto-accept window (seconds) - numeric editbox, commit on focus lost
    local w = WHITE()
    local winLbl = RC:CreateFontString(card, "OVERLAY", nil, 11)
    winLbl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy - 4)
    winLbl:SetTextColor(w.r, w.g, w.b)
    winLbl:SetText("Auto-accept window (seconds, 5\226\128\1473600):")

    local winBox = self.UI:CreateStyledEditBox(card, {
        width = 60,
        height = 22,
        maxLetters = 4,
        initialText = tostring(as.summonWindow or 19),
        onFocusLost = function(eb)
            local val = tonumber(eb:GetText()) or 19
            if val < 5 then val = 5 end
            if val > 3600 then val = 3600 end
            as.summonWindow = val
            eb:SetText(tostring(val))
        end,
    })
    -- after the label, however wide the font makes it
    winBox:SetPoint("TOPLEFT", card, "TOPLEFT", math.max(265, 15 + math.ceil(winLbl:GetStringWidth() or 0) + 10), cy)
    cy = cy - 32
    if not worldBuffs then
        -- (no buff triggers where world buffs are off: Core_Flavor lists
        -- why on the Game version page, nowhere else)
        RC.UI:BindDependents(summonCb, RC.UI:CardSince(card, summonMark))
        card:SetContentHeight(math.abs(cy))
        return yPos - card:GetHeight() - 15
    end

    local trigHdr = RC:CreateFontString(card, "OVERLAY", nil, 11)
    trigHdr:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy - 2)
    trigHdr:SetTextColor(w.r, w.g, w.b)
    trigHdr:SetText("Buff triggers - which fresh buffs arm the auto-accept:")
    cy = cy - 22

    local auras = WT:GetTrackedAuraList()
    local triggers = as.buffTriggers or {}
    for displayPos = 1, #WT.AURA_DISPLAY_ORDER do
        local auraIndex = WT.AURA_DISPLAY_ORDER[displayPos]
        local aura = auras[auraIndex]
        if aura then
            local option = aura.options and aura.options[1]
            local spellName, iconID
            if option then
                spellName = (GetSpellInfo and GetSpellInfo(option.id)) or option.label
                iconID = option.icon
            end
            local iconMarkup = iconID and ("|T" .. iconID .. ":14|t ") or ""
            local label = iconMarkup .. (aura.short or ("Aura " .. auraIndex))
                .. " |cff999999" .. (spellName or (option and option.label) or "") .. "|r"
            cy = AddCheck(card, cy, label, triggers[auraIndex] == true, function(v)
                as.buffTriggers[auraIndex] = v and true or nil
            end, 8)
        end
    end
    RC.UI:BindDependents(summonCb, RC.UI:CardSince(card, summonMark))

    card:SetContentHeight(math.abs(cy))
    return yPos - card:GetHeight() - 15
end

local function BuildGossipSection(self, parent, yPos, Rerender)
    local fs = WT:GetFactionSettings()
    if not fs then return yPos end
    local ag = fs.autoGossip

    -- DMT + BWL card
    local card = self:CreateSettingsCard(parent, yPos, "Auto-gossip |cff777777(testing)|r")
    local cy = -35
    cy = AddDesc(card, cy,
        "Dire Maul Tribute: auto-accept buffs from the DMT guards (Mol'dar, Fengus, "
        .. "Slip'kik, Mizzle, Komcrush) on gossip open.")
    cy = AddCheck(card, cy, "Auto-accept DMT buffs", ag.dmtEnabled ~= false, function(v)
        ag.dmtEnabled = v
    end)
    cy = cy - 6
    cy = AddDesc(card, cy, "BWL Portal: automatically use the Orb of Command on gossip open.")
    cy = AddCheck(card, cy, "Auto-use Orb of Command", ag.bwlEnabled ~= false, function(v)
        ag.bwlEnabled = v
    end)
    card:SetContentHeight(math.abs(cy))
    yPos = yPos - card:GetHeight() - 15

    -- DMF card
    local card2 = self:CreateSettingsCard(parent, yPos, "Darkmoon Faire (Sayge)")
    cy = -35
    cy = AddDesc(card2, cy,
        "Automatically select your DMF fortune from Sayge on gossip open. "
        .. "|cFFFF6600Use with caution|r - this instantly picks your buff on NPC click.")
    local dmfCb
    cy, dmfCb = AddCheck(card2, cy, "Auto-select DMF buff from Sayge", ag.dmfEnabled == true, function(v)
        ag.dmfEnabled = v
    end)
    local dmfMark = RC.UI:MarkCard(card2)
    cy = AddCheck(card2, cy, "Skip fortune cookie (auto-close gossip after buff)", ag.dmfSkipCookie ~= false, function(v)
        ag.dmfSkipCookie = v
    end)
    cy = cy - 8

    local w = WHITE()
    local perClass = RC:CreateFontString(card2, "OVERLAY", nil, 11)
    perClass:SetPoint("TOPLEFT", card2, "TOPLEFT", 15, cy - 2)
    perClass:SetTextColor(w.r, w.g, w.b)
    perClass:SetText("Buff type per class:")
    cy = cy - 24

    local activeFaction = WT:GetActiveFaction()
    local buffTypes = ag.dmfBuffTypes or {}
    for _, cls in ipairs(ALL_CLASSES) do
        local isFactionClass = true
        if cls.tag == "PALADIN" and activeFaction == "Horde" then isFactionClass = false end
        if cls.tag == "SHAMAN"  and activeFaction == "Alliance" then isFactionClass = false end
        if isFactionClass then
            local clsLbl = RC:CreateFontString(card2, "OVERLAY", nil, 11)
            clsLbl:SetPoint("TOPLEFT", card2, "TOPLEFT", 25, cy - 5)
            clsLbl:SetWidth(80)
            clsLbl:SetJustifyH("LEFT")
            clsLbl:SetTextColor(w.r, w.g, w.b)
            clsLbl:SetText(cls.name)

            local dd = self.UI:CreateScrollableDropdown(card2, 200, "Damage", 8)
            dd:SetPoint("TOPLEFT", card2, "TOPLEFT", 110, cy)
            dd:SetItems(DMF_BUFF_OPTIONS, function(value)
                ag.dmfBuffTypes = ag.dmfBuffTypes or {}
                ag.dmfBuffTypes[cls.tag] = value
            end)
            local cur = buffTypes[cls.tag] or "Damage"
            for _, item in ipairs(DMF_BUFF_OPTIONS) do
                if item.value == cur then
                    dd:SetSelectedValue(cur, item.text)
                    break
                end
            end
            cy = cy - 27
        end
    end
    RC.UI:BindDependents(dmfCb, RC.UI:CardSince(card2, dmfMark))

    card2:SetContentHeight(math.abs(cy))
    return yPos - card2:GetHeight() - 15
end

local function BuildQuestSection(self, parent, yPos, Rerender)
    local fs = WT:GetFactionSettings()
    if not fs then return yPos end
    local aq = fs.autoQuest

    local card = self:CreateSettingsCard(parent, yPos, "Auto quest turn-ins |cff777777(testing)|r")
    local cy = -35

    cy = AddDesc(card, cy,
        "Hold Shift while opening an NPC's gossip to skip any auto turn-in once.")

    cy = AddDesc(card, cy, "|cffd6a640Winterspring E'ko|r - turn in all E'ko types at Witch Doctor Mau'ari.")
    cy = AddCheck(card, cy, "Auto-turn-in E'ko quests", aq.ekoEnabled ~= false, function(v)
        aq.ekoEnabled = v
    end)
    cy = cy - 6

    cy = AddDesc(card, cy, "|cffd6a640Yojamba Isle Coins|r - turn in complete ZG coin sets at Vinchaxa.")
    cy = AddCheck(card, cy, "Auto-turn-in Yojamba coin quests", aq.coinsEnabled ~= false, function(v)
        aq.coinsEnabled = v
    end)
    cy = cy - 6

    cy = AddDesc(card, cy,
        "|cffd6a640Yojamba Isle Zanza|r - turn in Zandalar Honor Tokens at Rin'wosho, picking "
        .. "the first enabled zanza you don't already own (bag + bank snapshot aware).")
    local zanzaCb
    cy, zanzaCb = AddCheck(card, cy, "Auto-turn-in Zandalar Honor Tokens", aq.zanzaEnabled ~= false, function(v)
        aq.zanzaEnabled = v
    end)
    local picks = aq.zanzaPicks
    local zanzaDeps, box = {}, nil
    cy, box = AddCheck(card, cy, "Pick Swiftness of Zanza", picks.swiftness ~= false, function(v)
        picks.swiftness = v
    end)
    zanzaDeps[#zanzaDeps + 1] = box
    cy, box = AddCheck(card, cy, "Pick Spirit of Zanza", picks.spirit ~= false, function(v)
        picks.spirit = v
    end)
    zanzaDeps[#zanzaDeps + 1] = box
    cy, box = AddCheck(card, cy, "Pick Sheen of Zanza", picks.sheen ~= false, function(v)
        picks.sheen = v
    end)
    zanzaDeps[#zanzaDeps + 1] = box
    cy, box = AddCheck(card, cy, "Auto-repair gear at Rin'wosho after turn-in", aq.autoRepairEnabled ~= false, function(v)
        aq.autoRepairEnabled = v
    end)
    zanzaDeps[#zanzaDeps + 1] = box
    -- the picks and the repair happen only with the token turn-in on
    RC.UI:BindDependents(zanzaCb, zanzaDeps)

    cy = cy - 6

    cy = AddDesc(card, cy,
        "|cffd6a640Blasted Lands R.O.I.D.S.|r - auto-accept and auto-complete Rage of Ages "
        .. "at Bloodmage Drazial (needs 3x Jowl, 2x Lung, 1x Pincer).")
    cy = AddCheck(card, cy, "Auto-turn-in Rage of Ages (R.O.I.D.S.)", aq.roidsEnabled ~= false, function(v)
        aq.roidsEnabled = v
    end)

    card:SetContentHeight(math.abs(cy))
    return yPos - card:GetHeight() - 15
end

function RC:ShowSidebarWTAutomation(frame, preserveScroll)
    self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
    local parent = frame.scrollChild
    if not WT.Store() then return end

    local function Rerender()
        RC:ShowSidebarWTAutomation(frame, true)
    end

    local yPos = -20
    local _, newY = self:CreateSettingsPageHeader(parent, yPos,
        "Automation",
        RC:FeatureOn("world_tools") and "Auto-accept summon, auto-gossip and auto quest turn-ins"
            or RCL["Auto-accept summons"],
        "Interface\\Icons\\INV_Misc_EngGizmos_20")
    yPos = newY

    -- Faction being edited (settings are per-faction)
    local activeFaction = WT:GetActiveFaction()
    -- (a saved choice, so a dropdown, not tabs)
    self.UI:CreateSegmentedControl(parent, {
        x = 20, y = yPos - 4, width = 320, height = 22,
        label = RCL["Settings for:"],
        items = {
            { key = "Alliance", label = RCL["Alliance"], tooltip = RCL["Edit the automation used on your Alliance characters."] },
            { key = "Horde",    label = RCL["Horde"],    tooltip = RCL["Edit the automation used on your Horde characters."] },
        },
        selected = activeFaction,
        onSelect = function(k)
            WT:SetActiveFaction(k)
            Rerender()
        end,
    })
    yPos = yPos - 38

    local tab = RC._wtAutoTab or "summon"
    -- the gossip and the turn-ins pick world buffs (Core_Flavor)
    local tabs = { { "summon", "Accept Summon" }, { "gossip", "Gossip" }, { "quest",  "Quest" } }
    if not RC:FeatureOn("world_tools") then
        tabs = { { "summon", "Accept Summon" } }
        tab = "summon"
    end
    yPos = self:BuildSettingsTabBar(parent, yPos, tabs, tab, function(key)
        RC._wtAutoTab = key
        Rerender()
    end)

    if tab == "summon" then
        yPos = BuildSummonSection(self, parent, yPos, Rerender)
    elseif tab == "gossip" then
        yPos = BuildGossipSection(self, parent, yPos, Rerender)
    else
        yPos = BuildQuestSection(self, parent, yPos, Rerender)
    end

    if self.UpdateSidebarScrollbar then
        self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
    end
end

-- Sidebar registration: insert the World Tools category into
-- RC.MenuStructure (just above "mesh").
local function RegisterMenu()
    if type(RC.MenuStructure) ~= "table" then return end
    for _, item in ipairs(RC.MenuStructure) do
        if item.id == "world_tools" then return end  -- already registered
    end

    local entry = {
        id = "world_tools",
        name = "World Tools",
        category = true,
        icon = "Interface\\Icons\\INV_Misc_PocketWatch_02",
        panel = "ShowSidebarWorldToolsOverview",
        aliases = {"world tools", "pull timer",
                   "automation", "auto", "summon", "gossip", "turn in", "turnin"},
        children = {
            {
                id = "wt_pulltimers",
                name = "Buff Drops",
                icon = "Interface\\Icons\\INV_Misc_PocketWatch_02",
                panel = "ShowSidebarWTTimers",
                aliases = {"buff drops", "buff drop", "drops", "pull timer", "pull timers",
                           "timer bars", "countdown", "rend timer", "ony timer", "nef timer",
                           "zg timer", "drop alert", "npc died", "buff incoming", "alert sound",
                           "enable alerts", "buff dropped", "cooldown ready", "hand-in", "raid override"},
            },
            {
                id = "wt_automation",
                name = "Automation",
                icon = "Interface\\Icons\\INV_Misc_EngGizmos_20",
                panel = "ShowSidebarWTAutomation",
                aliases = {"automation", "auto summon", "accept summon", "auto gossip",
                           "dmt", "dire maul", "bwl portal", "orb of command", "dmf", "sayge",
                           "eko", "e'ko", "zanza", "coins", "roids", "auto repair", "turn in"},
            },
        },
    }

    -- just above the Mesh Network group (the world pages sit together:
    -- World Tools, then the mesh with its world buff board)
    local insertAt = #RC.MenuStructure + 1
    for i, item in ipairs(RC.MenuStructure) do
        if item.id == "mesh" then
            insertAt = i
            break
        end
    end
    table.insert(RC.MenuStructure, insertAt, entry)
end

RegisterMenu()
