------------------------------------------------------------------------
-- Readycheck - Must-Have Items
-- The few things a raider must never walk in without (by default a
-- Limited Invulnerability Potion, an Elixir of Poison Resistance and a
-- target dummy). When any of them is missing from the bags, big icons
-- with big text go up in the middle of the screen, with an optional air
-- horn, so it cannot be missed the way a chat line can.
--
-- Settings: RC.db.consumablesChecker.essentials = { enabled, airhorn
-- (play a sound), soundKey (a LibSharedMedia sound name, the air horn by
-- default), iconSize, items = { itemId, ... }, xOffset, yOffset }. An item in the
-- target dummy family stands for the whole family: any dummy counts.
--
-- When it checks: only on entering a raid (logging in inside one counts),
-- only at max level, never in combat. While the alert is up, buying
-- the item takes it off (bag changes only set a flag; a one-second
-- ticker does the counting and stops when the alert goes away).
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
local GetItemCount = GetItemCount or (RC.Compat and RC.Compat.GetItemCount)
local GetItemInfo = GetItemInfo or (RC.Compat and RC.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (RC.Compat and RC.Compat.GetItemIcon)

local ESS = {}
RC.Essentials = ESS

ESS.AIRHORN = "Interface\\AddOns\\Readycheck\\Media\\Sounds\\horn.ogg"
ESS.AIRHORN_KEY = "Readycheck: Air Horn"
ESS.DEFAULT_ITEMS = RC.flavorEssentials or { 3387, 3386, 16023 }

-- Names for the defaults, for before the game has the item cached
local KNOWN_NAMES = {
    [3387]  = "Limited Invulnerability Potion",
    [3386]  = "Elixir of Poison Resistance",
    [16023] = "Target Dummy",
}
-- Any one of these counts as "a target dummy"
local DUMMIES = { 4366, 4392, 16023, 22261 }
local IS_DUMMY = {}
for _, id in ipairs(DUMMIES) do IS_DUMMY[id] = true end

local function C(cat, key) return RC:GetColor(cat, key) end

function ESS.Settings()
    local cc = RC.db and RC.db.consumablesChecker
    if not cc then return nil end
    if type(cc.essentials) ~= "table" then cc.essentials = {} end
    local e = cc.essentials
    if e.enabled == nil then e.enabled = true end
    if e.airhorn == nil then e.airhorn = false end
    if type(e.soundKey) ~= "string" or e.soundKey == "" then e.soundKey = ESS.AIRHORN_KEY end
    if type(e.iconSize) ~= "number" then e.iconSize = 56 end
    if type(e.items) ~= "table" then
        e.items = {}
        for i, id in ipairs(ESS.DEFAULT_ITEMS) do e.items[i] = id end
    end
    return e
end

function ESS.IsDummy(id) return IS_DUMMY[id] == true end

-- On TBC / Forever an Era item the version does not have stays saved on
-- the list but is not shown or checked (the dummy family always counts).
function ESS.Shown(id)
    return IS_DUMMY[id] == true or not RC:ConsumableNotInFlavor(id)
end

function ESS.ItemName(id)
    if IS_DUMMY[id] then return RCL["Target Dummy"] end
    local name = GetItemInfo and GetItemInfo(id)
    return name or KNOWN_NAMES[id] or ("item " .. tostring(id))
end

function ESS.ItemIcon(id)
    return (GetItemIcon and GetItemIcon(id)) or 134400
end

function ESS.Count(id)
    if not GetItemCount then return 0 end
    if IS_DUMMY[id] then
        local n = 0
        for _, d in ipairs(DUMMIES) do n = n + (GetItemCount(d, false, false) or 0) end
        return n
    end
    return GetItemCount(id, false, false) or 0
end

-- the items on the list you have none of, in list order
function ESS.Missing()
    local e = ESS.Settings()
    local out = {}
    if not e then return out end
    for _, id in ipairs(e.items) do
        if type(id) == "number" and ESS.Shown(id) and ESS.Count(id) <= 0 then out[#out + 1] = id end
    end
    return out
end

-- Adds an item from what was typed: an item link, an id, or the exact
-- name of an item the game knows. Returns the id, or nil and why.
function ESS.Add(text)
    local e = ESS.Settings()
    if not e or type(text) ~= "string" then return nil, RCL["nothing entered"] end
    text = text:match("^%s*(.-)%s*$")
    if text == "" then return nil, RCL["nothing entered"] end
    local id = tonumber(text:match("item:(%d+)")) or tonumber(text)
    if not id and GetItemInfo then
        local _, link = GetItemInfo(text)
        id = link and tonumber(link:match("item:(%d+)"))
    end
    if not id then return nil, RCL["no item by that name - shift-click it from your bags instead"] end
    for _, have in ipairs(e.items) do
        if have == id or (IS_DUMMY[id] and IS_DUMMY[have]) then return nil, RCL["already on the list"] end
    end
    e.items[#e.items + 1] = id
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
    return id
end

function ESS.Remove(id)
    local e = ESS.Settings()
    if not e then return end
    for i, have in ipairs(e.items) do
        if have == id then table.remove(e.items, i) break end
    end
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
    ESS.Refresh()
end

-- puts back any default that was taken off, keeping what was added
function ESS.RestoreDefaults()
    local e = ESS.Settings()
    if not e then return end
    for _, id in ipairs(ESS.DEFAULT_ITEMS) do
        local found = false
        for _, have in ipairs(e.items) do
            if have == id or (IS_DUMMY[id] and IS_DUMMY[have]) then found = true end
        end
        if not found then e.items[#e.items + 1] = id end
    end
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
end

------------------------------------------------------------------------
-- the alert
------------------------------------------------------------------------
local alert
local tiles = {}
local ticker
local dirty = false

local function StopTicker()
    if ticker then ticker:Cancel() ticker = nil end
end

-- The look (all nil = today's): titleFont / nameFont / hintFont (font
-- specs), titleColor / nameColor / ringColor / hintColor, gap (space
-- between icons as a share of the icon size), showAnim / hideAnim
-- (RC.Motion specs; "none" = instant, as it always was).
ESS.FONT_DEFAULTS = {
    title = { size = 26, outline = "THICKOUTLINE", shadow = false },
    name  = { size = 14, outline = "OUTLINE", shadow = false },
    hint  = { size = 11, outline = "OUTLINE", shadow = false },
}
ESS.COLOR_DEFAULTS = { titleColor = { "text", "red" }, nameColor = { "text", "gold" },
    ringColor = { "text", "red" }, hintColor = { "text", "gray" } }
ESS.ANIM_DEFAULTS = { style = "none", duration = 0.3 }
ESS.GAP = 0.9

function ESS.Color(key)
    local e = ESS.Settings()
    local c = e and e[key]
    if type(c) == "table" and c.r then return c.r, c.g or 0, c.b or 0, c.a or 1 end
    local d = ESS.COLOR_DEFAULTS[key]
    local dc = C(d[1], d[2])
    return dc.r, dc.g, dc.b, dc.a or 1
end

function ESS.Anim(which)
    local e = ESS.Settings()
    local s = e and e[which]
    return RC.Motion.Normalize(type(s) == "table" and s or nil, ESS.ANIM_DEFAULTS)
end

-- The alert's text and tiles on any frame: the live alert and the pane
-- sample are both made here.
function ESS.BuildAlertFrame(f)
    f.tiles = f.tiles or {}
    f.title = RC:CreateFontString(f, "OVERLAY", nil, 26, "THICKOUTLINE")
    f.title:SetPoint("TOP", f, "TOP", 0, 0)
    f.title:SetText(RCL["MISSING"])
    f.hint = RC:CreateFontString(f, "OVERLAY", nil, 11)
    f.hint:SetPoint("BOTTOM", f, "BOTTOM", 0, 0)
    f.hint:SetText(RCL["click to dismiss"])
    ESS.StyleAlert(f)
    return f
end

local function Build()
    if alert then return alert end
    local e = ESS.Settings()
    local f = CreateFrame("Button", "ReadycheckMustHaveAlert", UIParent)
    f:SetSize(300, 140)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(120)
    f:SetClampedToScreen(true)
    f:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 180)
    f:Hide()
    ESS.BuildAlertFrame(f)
    f.live = true

    f:SetScript("OnClick", function() ESS.Hide() end)
    f:SetScript("OnHide", StopTicker)
    -- shown by the frame mover before any alert: lay out the list so there
    -- is something to place
    f:SetScript("OnShow", function(self)
        if not self._laidOut then ESS._Layout(ESS.Settings().items) end
    end)

    if RC.Position and RC.Position.Bind then
        RC.Position.Bind(f, function() return ESS.Settings() end,
            { point = "CENTER", default = { point = "CENTER", x = 0, y = 180 },
              -- (a fresh character: left of the reminder text, not under it)
              gen2 = { point = "CENTER", x = -470, y = 240 } })
        RC.Position.RestoreFrame(f)
    end
    if RC.UIMover and RC.UIMover.RegisterFrame then
        RC.UIMover:RegisterFrame("mustHaveAlert", f, "Missing Must-Have Items",
            { point = "CENTER", relPoint = "CENTER", x = 0, y = 180 })
    end
    alert = f
    return f
end

local function Tile(f, i)
    local t = f.tiles[i]
    if t then return t end
    t = CreateFrame("Frame", nil, f)
    t.icon = t:CreateTexture(nil, "ARTWORK")
    t.icon:SetAllPoints()
    t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    -- a red ring, two pixels, so the icon reads as "missing" at a glance
    t.ring = {}
    for k = 1, 4 do
        local r = t:CreateTexture(nil, "OVERLAY")
        r:SetTexture((RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8")
        t.ring[k] = r
    end
    t.ring[1]:SetPoint("TOPLEFT", -2, 2)    t.ring[1]:SetPoint("TOPRIGHT", 2, 2)    t.ring[1]:SetHeight(2)
    t.ring[2]:SetPoint("BOTTOMLEFT", -2, -2) t.ring[2]:SetPoint("BOTTOMRIGHT", 2, -2) t.ring[2]:SetHeight(2)
    t.ring[3]:SetPoint("TOPLEFT", -2, 2)    t.ring[3]:SetPoint("BOTTOMLEFT", -2, -2) t.ring[3]:SetWidth(2)
    t.ring[4]:SetPoint("TOPRIGHT", 2, 2)    t.ring[4]:SetPoint("BOTTOMRIGHT", 2, -2) t.ring[4]:SetWidth(2)
    t.name = RC:CreateFontString(t, "OVERLAY", nil, 14, "OUTLINE")
    t.name:SetPoint("TOP", t, "BOTTOM", 0, -6)
    t.name:SetJustifyH("CENTER")
    t.name:SetWordWrap(true)
    if f.live then
        t:EnableMouse(true)
        t:SetScript("OnEnter", function(self)
            if not self.itemId then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            if GameTooltip.SetItemByID then GameTooltip:SetItemByID(self.itemId)
            else GameTooltip:SetHyperlink("item:" .. self.itemId) end
            GameTooltip:Show()
        end)
        t:SetScript("OnLeave", function() GameTooltip:Hide() end)
        t:SetScript("OnMouseUp", function() ESS.Hide() end)
    end
    f.tiles[i] = t
    return t
end

-- Fonts and colours of an alert frame (live or sample).
function ESS.StyleAlert(f)
    local e = ESS.Settings() or {}
    local function Spec(k) local v = e[k] return type(v) == "table" and v or nil end
    RC:ApplyFontSpec(f.title, Spec("titleFont"), ESS.FONT_DEFAULTS.title)
    RC:ApplyFontSpec(f.hint, Spec("hintFont"), ESS.FONT_DEFAULTS.hint)
    f.title:SetTextColor(ESS.Color("titleColor"))
    f.hint:SetTextColor(ESS.Color("hintColor"))
    for _, t in ipairs(f.tiles) do
        RC:ApplyFontSpec(t.name, Spec("nameFont"), ESS.FONT_DEFAULTS.name)
        t.name:SetTextColor(ESS.Color("nameColor"))
        local r, g, b, a = ESS.Color("ringColor")
        for _, rr in ipairs(t.ring) do rr:SetVertexColor(r, g, b, a) end
    end
end

-- Lays out an alert frame for a list of item ids.
function ESS.LayoutAlert(f, list)
    local e = ESS.Settings()
    local size = math.max(32, math.min(e and e.iconSize or 56, 128))
    local gap = math.floor(size * (tonumber(e and e.gap) or ESS.GAP))
    local nameW = size + gap - 8
    local n = #list
    local width = math.max(n * size + (n - 1) * gap, 240)
    for i, id in ipairs(list) do
        local t = Tile(f, i)
        t.itemId = id
        t:SetSize(size, size)
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", f, "TOPLEFT", (width - (n * size + (n - 1) * gap)) / 2 + (i - 1) * (size + gap), -36)
        t.icon:SetTexture(ESS.ItemIcon(id))
        t.name:SetWidth(nameW)
        t.name:SetText(ESS.ItemName(id))
        t:Show()
    end
    for i = n + 1, #f.tiles do f.tiles[i]:Hide() end
    ESS.StyleAlert(f)
    f:SetSize(width, 36 + size + 52 + 16)
    f._laidOut = true
end

local function Layout(list)
    ESS.LayoutAlert(alert, list)
end
ESS._Layout = Layout

-- the chosen sound (LibSharedMedia), the air horn if that name is gone
function ESS.PlaySound()
    local e = ESS.Settings()
    if RC.PlaySoundKey then
        RC:PlaySoundKey(e and e.soundKey or ESS.AIRHORN_KEY, ESS.AIRHORN)
    else
        pcall(PlaySoundFile, ESS.AIRHORN, "Master")
    end
end

function ESS.Hide()
    StopTicker()
    if alert and alert:IsShown() then
        if InCombatLockdown() then RC.Motion.Stop(alert) alert:Hide()
        else RC.Motion.Hide(alert, ESS.Anim("hideAnim")) end
    end
end

local function Tick()
    if not (alert and alert:IsShown()) then StopTicker() return end
    if not dirty then return end
    dirty = false
    local missing = ESS.Missing()
    if #missing == 0 then ESS.Hide() return end
    Layout(missing)
end

local function StartTicker()
    if ticker then return end
    if RC.Profiler and RC.Profiler.TrackTicker then
        ticker = RC.Profiler:TrackTicker("mustHaveAlert", 1.0, Tick)
    else
        ticker = C_Timer.NewTicker(1.0, Tick)
    end
end

-- Shows the alert for whatever is missing now. test: show every item on
-- the list as if missing, to see how it looks.
function ESS.Show(test)
    local e = ESS.Settings()
    if not e then return false end
    if not test and not e.enabled then return false end
    if InCombatLockdown() and not test then return false end
    local list = test and e.items or ESS.Missing()
    if #list == 0 then
        ESS.Hide()
        return false
    end
    Build()
    Layout(list)
    if alert:IsShown() and not (alert._rcMotion and alert._rcMotion.how == "out") then
        -- already up: the new list is enough
    else
        RC.Motion.Show(alert, ESS.Anim("showAnim"))
    end
    if e.airhorn then ESS.PlaySound() end
    RC:DebugPrint("Must-have alert: " .. #list .. " item(s)" .. (test and " (test)" or ""), "consumables")
    if not test then StartTicker() end
    return true
end

function ESS.Refresh()
    if alert and alert:IsShown() then
        dirty = true
        Tick()
    end
end

------------------------------------------------------------------------
-- when it checks
------------------------------------------------------------------------
do
    local ev = CreateFrame("Frame")
    local loggedIn = false
    local pending = false
    local lastRaid
    local function AtMaxLevel()
        local maxLevel = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
        return (UnitLevel("player") or 0) >= maxLevel
    end
    local function Check(delay)
        C_Timer.After(delay, function()
            if not AtMaxLevel() then return end
            if InCombatLockdown() then
                pending = true
                return
            end
            ESS.Show(false)
        end)
    end
    -- the shared bag index says when the bags really changed; only a
    -- flag here, the ticker (running only while the alert is up) counts
    RC.Bags:OnChange("MustHaveAlert", function()
        if alert and alert:IsShown() then dirty = true end
    end)
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:RegisterEvent("PLAYER_REGEN_ENABLED")
    ev:RegisterEvent("PLAYER_REGEN_DISABLED")
    ev:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_ENTERING_WORLD" then
            local _, kind = IsInInstance()
            local raid = (kind == "raid") and (GetInstanceInfo and select(8, GetInstanceInfo())) or nil
            if not loggedIn then
                loggedIn = true
                -- made now (hidden) so the frame mover can place it
                if RC.db then Build() end
            end
            -- only walking into a raid (or logging in inside one)
            if raid and raid ~= lastRaid then
                Check(4)
            end
            lastRaid = raid
        elseif event == "PLAYER_REGEN_DISABLED" then
            if alert and alert:IsShown() then ESS.Hide() end
        elseif event == "PLAYER_REGEN_ENABLED" then
            if pending then
                pending = false
                Check(1)
            end
        end
    end)
end
