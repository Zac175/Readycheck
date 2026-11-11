------------------------------------------------------------------------
-- Readycheck - Consumables Sidebar Shared Helpers
-- Shared building blocks used by the other Cons_*.lua sidebar pages:
-- tab color getters, the visibility-mode grid widget, the TTS "Say:"
-- editbox (writes store[key].ttsText), and the shared custom-item
-- category dropdown menu frame. Populates RC._sbc, which the pages read
-- into locals at file scope - this file must load before all of them.
--
-- Stays in the main addon because its readers are now spread across three
-- addons: the bar and checker pages in Readycheck_Consumables, the Battle
-- Shout and Chronoboon pages in Readycheck_Reminders, and Cons_Notes.lua
-- next door. Companions load after the whole main addon, so file-scope
-- reads of RC._sbc are always satisfied.
------------------------------------------------------------------------
local RCC = _G.Readycheck

local function MakeSayBox(row, anchorTo, store, key, displayName)
    local hint = row:CreateFontString(nil, "OVERLAY")
    RCC:ApplyCustomFont(hint, 10)
    hint:SetPoint("LEFT", anchorTo, "RIGHT", 8, 0)
    hint:SetText(RCL["Say:"])
    do local c = RCC:GetColor("text", "muted") or { r = 0.6, g = 0.6, b = 0.6 }
        hint:SetTextColor(c.r, c.g, c.b) end
    -- Framework edit box: flat ui.elementBackground, 1px black ring,
    -- gold ring while typing (eb.bg is the backing frame).
    local eb = RCC.UI:CreateBackedEditBox(row, {
        width = 110, height = 18, insets = 4, maxLetters = 40, fontSize = 10,
    })
    eb:SetPoint("LEFT", hint, "RIGHT", 4, 0)
    local builtIn = ""
    if displayName and displayName ~= "" then
        builtIn = (RCC.ttsSpokenNames and RCC.ttsSpokenNames[displayName])
            or (RCC.ShortenConsumableName and RCC.ShortenConsumableName(displayName))
            or displayName
    end
    local function ShowGrey()
        eb:SetText(builtIn)
        local c = RCC:GetColor("text", "buttonDisabled") or { r = 0.5, g = 0.5, b = 0.5 }
        eb:SetTextColor(c.r, c.g, c.b, c.a or 1)
    end
    local function ShowWhite(t)
        eb:SetText(t)
        local c = RCC:GetColor("text", "white") or { r = 1, g = 1, b = 1 }
        eb:SetTextColor(c.r, c.g, c.b, 1)
    end
    local cur = store[key]
    local saved = cur and cur.ttsText
    if saved and saved ~= "" then ShowWhite(saved) else ShowGrey() end
    local function Save()
        local t = eb:GetText() or ""
        t = t:gsub("^%s+", ""):gsub("%s+$", "")
        if not store[key] then store[key] = {} end
        if t == "" or t == builtIn then
            store[key].ttsText = nil
            ShowGrey()
        else
            store[key].ttsText = t
            ShowWhite(t)
        end
        RCC:SaveConfigurationToProfile()
    end
    eb:SetScript("OnEditFocusGained", function(s)
        local c2 = store[key]
        if not (c2 and c2.ttsText and c2.ttsText ~= "") then
            s:SetText("")
            local c = RCC:GetColor("text", "white") or { r = 1, g = 1, b = 1 }
            s:SetTextColor(c.r, c.g, c.b, 1)
        end
    end)
    eb:SetScript("OnEnterPressed", function(s) Save(); s:ClearFocus() end)
    eb:SetScript("OnEditFocusLost", Save)
    eb:SetScript("OnEscapePressed", function(s)
        local c2 = store[key]
        local sv = c2 and c2.ttsText
        if sv and sv ~= "" then ShowWhite(sv) else ShowGrey() end
        s:ClearFocus()
    end)
    return eb
end
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_sort = table.insert, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbc = RC._sbc or {}
local _sbc = RC._sbc
    local function GetTabSelectedBg()
        return RC:GetColor("sidebar", "buttonSelected")
    end

    local function GetTabNormalBg()
        return RC:GetColor("sidebar", "buttonNormal")
    end

    local function GetTabHoverBg()
        return RC:GetColor("sidebar", "buttonHover")
    end

    local function GetTabSelectedText()
        return RC:GetColor("text", "menuSelected")
    end

    local function GetTabNormalText()
        return RC:GetColor("text", "menuNormal")
    end

    local TEXT = RC.UI and RC.UI.TEXT or {}

    -- Visibility-mode picker: "Show in:" and a dropdown of the modes
    -- (RC.UI:CreateSegmentedControl). Writes cfg.visibilityMode and calls
    -- onPick() exactly like the old two-column grid did; returns the
    -- next free cardY. Labels/tooltips are normalised here so every bar
    -- says the same thing: "raids" means INSIDE a raid instance (a raid
    -- group in the open world does not count) and "city" means resting
    -- (inns and capital cities). A caller's mode.name is the fallback
    -- for keys not listed.
    local VIS_MODE_INFO = {
        always         = { label = RCL["Always"],
                           tooltip = RCL["Shown everywhere, whenever the bar is enabled."] },
        group          = { label = RCL["In a Group"],
                           tooltip = RCL["Only while you are in a party or raid group, anywhere in the world."] },
        raids          = { label = RCL["In Raids"],
                           tooltip = RCL["Only while you are inside a raid instance. Being in a raid group outside an instance does not count."] },
        raids_only     = { label = RCL["In Raids"],
                           tooltip = RCL["Only while you are inside a raid instance. Being in a raid group outside an instance does not count."] },
        city           = { label = RCL["In Cities"],
                           tooltip = RCL["Only while you are resting - inside an inn or a capital city."] },
        raids_and_city = { label = RCL["Raids & Cities"],
                           tooltip = RCL["Inside a raid instance, or while resting in an inn or a capital city."] },
        instances      = { label = RCL["Dungeons & Raids"],
                           tooltip = RCL["Inside a dungeon or a raid instance."] },
    }

    -- Modes that gate on being inside a raid instance, and so get the
    -- per-raid filter block underneath the segment row.
    local RAID_GATED_MODES = { raids = true, raids_only = true, raids_and_city = true, instances = true }

    -- Display order for the raid filter rows (same as Raids_Remote.lua);
    -- anything in RC.availableRaids that is missing here is appended so
    -- the checkbox keys always match the predicate's key set.
    local RAID_FILTER_ORDER = {
        "Naxxramas", "Temple of Ahn'Qiraj", "Blackwing Lair",
        "Molten Core", "Onyxia's Lair", "Zul'Gurub", "Ruins of Ahn'Qiraj",
    }
    local function RaidFilterList()
        local avail, seen, out = {}, {}, {}
        -- (options audit 2026-11-09) a game version whose raids Readycheck
        -- does not list yet (Core_Flavor's "raid_configs" row: Forever) has
        -- no raid to tick: the names left are Classic Era's. No rows there;
        -- a saved pick stays as it is.
        if RC.FeatureOn and not RC:FeatureOn("raid_configs") then return out end
        for _, name in ipairs(RC.availableRaids or {}) do avail[name] = true end
        for _, name in ipairs(RAID_FILTER_ORDER) do
            if avail[name] then out[#out + 1] = name; seen[name] = true end
        end
        for _, name in ipairs(RC.availableRaids or {}) do
            if not seen[name] then out[#out + 1] = name end
        end
        return out
    end

    -- Per-raid filter for a raid-gated visibility mode. Writes
    -- cfg.visibilityRaids = { [raidName]=true, ... } (RC.availableRaids
    -- keys, the set RC:IsInRaidInstance(filter) reads): the table is
    -- created on the first tick and dropped again when the last tick is
    -- cleared, so "no table" is the clean "every raid" default. Every
    -- change calls onPick(), which is the caller's save + re-evaluate +
    -- re-render, exactly as for a mode change.
    --
    -- Layout inside the card, starting at cardY:
    --   [label 10px secondary, x 14]           [All] [None]  (50x20 each)
    --   4 rows x 2 columns of RC.UI:CreateCheckbox, 23px stride, column-
    --   major in RAID_FILTER_ORDER (left: Naxx, AQ40, BWL, MC; right:
    --   Ony, ZG, AQ20); right column starts at 14 + half the inner width.
    -- Returns the next free cardY. Shared with the Battle Shout page via
    -- RC._sbc.BuildRaidFilter.
    local function BuildRaidFilter(card, cardY, cfg, onPick)
        local raids = RaidFilterList()
        if #raids == 0 then return cardY end

        local label = RC:CreateFontString(card, "OVERLAY", nil, 10)
        label:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY - 5)
        label:SetText(RCL["Which raids count (none ticked = all raids)"])
        local lc = RC:GetColor("text", "secondary")
        label:SetTextColor(lc.r, lc.g, lc.b, 1)

        local rows = {}
        local function SyncRows()
            local set = cfg.visibilityRaids
            for _, row in ipairs(rows) do
                RC:ForceCheckboxUpdate(row.cb, (set and set[row.name]) and true or false)
            end
        end

        local allBtn = RC.UI:CreateStyledButton(card, RCL["All"], 50, 20)
        allBtn:SetPoint("LEFT", label, "RIGHT", 10, 0)
        allBtn:SetScript("OnClick", function()
            cfg.visibilityRaids = {}
            for _, name in ipairs(raids) do cfg.visibilityRaids[name] = true end
            SyncRows()
            onPick()
        end)

        local noneBtn = RC.UI:CreateStyledButton(card, RCL["None"], 50, 20)
        noneBtn:SetPoint("LEFT", allBtn, "RIGHT", 4, 0)
        noneBtn:SetScript("OnClick", function()
            cfg.visibilityRaids = nil
            SyncRows()
            onPick()
        end)
        cardY = cardY - 24

        local innerW = (card:GetWidth() or 0) - 28
        local colW = math_max(150, math_floor(innerW / 2))
        local perCol = math_ceil(#raids / 2)
        local set = cfg.visibilityRaids
        for idx, name in ipairs(raids) do
            local col = (idx > perCol) and 1 or 0
            local row = (idx - 1) % perCol
            local cb = RC.UI:CreateCheckbox(card, name, set and set[name])
            cb:SetPoint("TOPLEFT", card, "TOPLEFT", 14 + col * colW, cardY - row * 23)
            cb:SetScript("OnClick", function(self)
                local on = self:GetChecked() and true or false
                RC:ForceCheckboxUpdate(self, on)
                if on then
                    cfg.visibilityRaids = cfg.visibilityRaids or {}
                    cfg.visibilityRaids[name] = true
                elseif cfg.visibilityRaids then
                    cfg.visibilityRaids[name] = nil
                    if not RC:HasRaidFilter(cfg.visibilityRaids) then
                        cfg.visibilityRaids = nil
                    end
                end
                onPick()
            end)
            rows[#rows + 1] = { cb = cb, name = name }
        end
        cardY = cardY - perCol * 23 - 4

        return cardY
    end

    local function BuildVisibilityModeGrid(card, cardY, modes, cfg, onPick)
        local items = {}
        for idx, mode in ipairs(modes) do
            local info = VIS_MODE_INFO[mode.key]
            items[idx] = {
                key     = mode.key,
                label   = (info and info.label) or mode.name or tostring(mode.key),
                tooltip = info and info.tooltip or nil,
            }
        end

        RC.UI:CreateSegmentedControl(card, {
            x = 14, y = cardY, inset = 14, height = 22,
            label    = RCL["Show in:"],
            items    = items,
            selected = cfg.visibilityMode,
            onSelect = function(key)
                cfg.visibilityMode = key
                onPick()
            end,
        })
        cardY = cardY - 22 - 6

        -- One-line reminder of what the two zone words mean, since the
        -- choice labels alone read as "raid group" to most people.
        local hint = RC:CreateFontString(card, "OVERLAY", nil, 10)
        hint:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
        hint:SetPoint("RIGHT", card, "RIGHT", -14, 0)
        hint:SetJustifyH("LEFT")
        hint:SetWordWrap(true)
        hint:SetText(RCL["Group = in any party or raid, anywhere. Raids = inside a raid instance. Cities = resting in an inn or capital city."])
        local hc = RC:GetColor("text", "secondary")
        hint:SetTextColor(hc.r, hc.g, hc.b, 1)
        cardY = cardY - math.max(14, hint:GetStringHeight() or 14) - 6

        -- Per-raid filter, only for the raid-gated modes. The block is not
        -- toggled in place: every caller's onPick re-renders its page, so
        -- a mode change rebuilds the card with or without the block and
        -- the returned cardY (hence the card height) is right either way.
        if RAID_GATED_MODES[cfg.visibilityMode] then
            cardY = BuildRaidFilter(card, cardY, cfg, onPick)
        end

        return cardY
    end

    local _catMenu
    local function GetCustomItemCategoryMenu()
        if not _catMenu then
            _catMenu = CreateFrame("Frame", "WRCustomItemCategoryMenu", UIParent, "UIDropDownMenuTemplate")
        end
        return _catMenu
    end

    _sbc.BuildVisibilityModeGrid = BuildVisibilityModeGrid
    _sbc.BuildRaidFilter = BuildRaidFilter
    _sbc.RAID_GATED_MODES = RAID_GATED_MODES
    _sbc.GetCustomItemCategoryMenu = GetCustomItemCategoryMenu
    _sbc.MakeSayBox = MakeSayBox
    _sbc.GetTabSelectedBg = GetTabSelectedBg
    _sbc.GetTabNormalBg = GetTabNormalBg
    _sbc.GetTabHoverBg = GetTabHoverBg
    _sbc.GetTabSelectedText = GetTabSelectedText
    _sbc.GetTabNormalText = GetTabNormalText
    _sbc.TEXT = TEXT
