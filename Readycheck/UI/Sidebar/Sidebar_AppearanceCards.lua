------------------------------------------------------------------------
-- Readycheck - Appearance: Color Category Cards (Core/Bars/Raid tabs)
-- Custom (non-generic) color cards for the Colors sub-tab: opacity slider,
-- grouped text-color cards, input controls, stats bar gradients, buff
-- pushoff/TTK/UI-mover cards, and Reset All. COLOR_MANIFEST at the
-- bottom drives RC:RenderColorTab (called from Sidebar_AppearanceColors.lua
-- per sub-tab); { custom = fn } entries run one of these builders instead
-- of the generic CreateColorCategoryCard.
-- Every colour card here is built with RC:CreateColorRowCard from
-- Sidebar_AppearanceColors.lua (rows + the shared inline editor), fed by
-- RC:MakeColorEntry for db.customColors keys or, for the stats bar
-- gradients, a hand-built entry of the same shape over db.statsBarColors
-- (a separate store RC:GetColor/SetColor never touch).
------------------------------------------------------------------------
-- Taint-safe API locals (fallbacks on RC.Compat, built in Core; never write _G)
local RCC = _G.Readycheck
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
RC._sbs = RC._sbs or {}
local _sbs = RC._sbs
local ColorPreviews = _sbs.ColorPreviews

    local function IsSearching()
        return RC._colorEditor and (RC._colorEditor.search or "") ~= ""
    end

    -- Builds entries for a fixed list of {key=, label=} over one category.
    local function EntriesFor(cat, list, after)
        local out = {}
        for _, info in ipairs(list) do
            local e = RC:MakeColorEntry(cat, info.key, info.label, after)
            if e then table_insert(out, e) end
        end
        return out
    end

    local function BuildOpacityCard(self, parent, yPos, frame)
        -- Not a colour; hidden while a search is active so the results
        -- read as one list.
        if IsSearching() then return yPos end

        local opacityCard = self:CreateSettingsCard(parent, yPos, RCL["Background opacity"])
        local cardY = -32
        local txtNormC = self:GetColor("text", "normal")
        local txtGrayC = self:GetColor("text", "gray")

        local opacityLabel = self:CreateFontString(opacityCard, "OVERLAY", nil, 11)
        opacityLabel:SetPoint("TOPLEFT", opacityCard, "TOPLEFT", 14, cardY)
        opacityLabel:SetText(RCL["Opacity"])
        opacityLabel:SetTextColor(txtNormC.r, txtNormC.g, txtNormC.b)
        cardY = cardY - 18

        if not self.db.fontSettings then self.db.fontSettings = {} end
        local currentPct = math.floor(((self.db.fontSettings.mainWindowBgOpacity or 1.0) * 100) + 0.5)

        local bgOpacitySlider = self.UI:CreateSlider(opacityCard, 0, 100, currentPct, 5)
        bgOpacitySlider:SetPoint("TOPLEFT", opacityCard, "TOPLEFT", 14, cardY)
        bgOpacitySlider.Text:SetText(currentPct .. "%")

        bgOpacitySlider:HookScript("OnValueChanged", function(slider, value)
            value = math.floor(value)
            slider.Text:SetText(value .. "%")
            local alpha = value / 100
            RC.db.fontSettings.mainWindowBgOpacity = alpha
            -- Pokes the three known translucent layers directly (no generic
            -- repaint hook for this); add new layers here if the window
            -- gains more of them.
            local f = RC.sidebarConfigFrame
            if f then
                if f.bg then f.bg:SetAlpha(alpha) end
                if f.sidebar and f.sidebar.bg then
                    f.sidebar.bg:SetAlpha(alpha * ((RC.UI and RC.UI.S and RC.UI.S.SIDEBAR_A) or 0.20))
                end
                if f.contentBg then f.contentBg:SetAlpha(alpha) end
            end
            if slider.saveTimer then slider.saveTimer:Cancel() end
            slider.saveTimer = C_Timer.NewTimer(0.3, function()
                RC:SaveConfigurationToProfile()
            end)
        end)

        local opacityDesc = self:CreateFontString(opacityCard, "OVERLAY", nil, 10)
        opacityDesc:SetPoint("TOPLEFT", bgOpacitySlider, "BOTTOMLEFT", 0, -8)
        opacityDesc:SetTextColor(txtGrayC.r, txtGrayC.g, txtGrayC.b)
        opacityDesc:SetText(RCL["Controls background transparency - cards and buttons are unaffected"])

        cardY = cardY - 50
        opacityCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - opacityCard:GetHeight() - 14
        return yPos
    end

    -- Four grouped cards over the `text` category. Their previews live in
    -- the preview pane (the window miniature and its Text mode).
    local function BuildTextCards(self, parent, yPos, frame)
        local card
        card, yPos = self:CreateColorRowCard(parent, yPos, RCL["General text"],
            EntriesFor("text", {
                {key = "normal",    label = RCL["Default"]},
                {key = "white",     label = RCL["White"]},
                {key = "bright",    label = RCL["Bright"]},
                {key = "secondary", label = RCL["Secondary / hints"]},
                {key = "gray",      label = RCL["Gray"]},
                {key = "muted",     label = RCL["Muted"]},
                {key = "disabled",  label = RCL["Disabled"]},
                {key = "gold",      label = RCL["Gold"]},
            }))
        card, yPos = self:CreateColorRowCard(parent, yPos, RCL["Status text"],
            EntriesFor("text", {
                {key = "success", label = RCL["Success"]},
                {key = "green",   label = RCL["Green"]},
                {key = "warning", label = RCL["Warning"]},
                {key = "yellow",  label = RCL["Yellow"]},
                {key = "orange",  label = RCL["Caution"]},
                {key = "red",     label = RCL["Error"]},
                {key = "blue",    label = RCL["Info"]},
            }))
        card, yPos = self:CreateColorRowCard(parent, yPos, RCL["Button text"],
            EntriesFor("text", {
                {key = "buttonNormal",   label = RCL["Normal"]},
                {key = "buttonHover",    label = RCL["Hover"]},
                {key = "buttonActive",   label = RCL["Active"]},
                {key = "buttonDisabled", label = RCL["Disabled"]},
            }))
        card, yPos = self:CreateColorRowCard(parent, yPos, RCL["Sidebar menu text"],
            EntriesFor("text", {
                {key = "menuNormal",   label = RCL["Normal"]},
                {key = "menuSelected", label = RCL["Selected"]},
                {key = "menuDisabled", label = RCL["Disabled"]},
                {key = "menuCategory", label = RCL["Category"]},
            }))
        return yPos
    end

    -- Checkbox + dropdown colours on one card (two categories).
    local function BuildInputCard(self, parent, yPos, frame)
        local entries = {}
        for _, e in ipairs(EntriesFor("checkbox", {
            {key = "background",  label = RCL["Checkbox Background"]},
            {key = "border",      label = RCL["Checkbox Border"]},
            {key = "checkmark",   label = RCL["Checkmark"]},
            {key = "hoverBorder", label = RCL["Checkbox Hover Border"]},
        })) do table_insert(entries, e) end
        for _, e in ipairs(EntriesFor("dropdown", {
            {key = "background", label = RCL["Dropdown Background"]},
            {key = "itemHover",  label = RCL["Dropdown Item Hover"]},
            {key = "itemText",   label = RCL["Dropdown Item Text"]},
            {key = "arrow",      label = RCL["Dropdown Arrow"]},
            {key = "selected",   label = RCL["Dropdown Selected"]},
        })) do table_insert(entries, e) end

        -- previewed on the real checkbox and dropdown in the preview pane
        local card
        card, yPos = self:CreateColorRowCard(parent, yPos, RCL["Input controls"], entries, {
            resetAll = function()
                RC:ResetColorCategory("checkbox")
                RC:ResetColorCategory("dropdown")
            end,
        })
        return yPos
    end

    -- Stats bar gradients live in db.statsBarColors (low/high per stat),
    -- a separate store from db.customColors - RC:GetColor/SetColor never
    -- touch this table. Module-level so the row entries, the card's
    -- reset and RC:OpenStatsBarColorPicker all read the same defaults.
    local STATS_GRADIENT_DEFAULTS = {
        buffs = {low = {r=0.3, g=0.9, b=0.3}, high = {r=1.0, g=0.15, b=0.1}, label = RCL["Buffs"], range = "0 - 32"},
        hit = {low = {r=1.0, g=0.3, b=0.3}, high = {r=0.3, g=1.0, b=0.3}, label = RCL["Hit"], range = "0% - 6%"},
        crit = {low = {r=0.5, g=0.6, b=0.8}, high = {r=0.4, g=0.85, b=1.0}, label = RCL["Crit"], range = "10% - 40%"},
        ap = {low = {r=0.6, g=0.6, b=0.6}, high = {r=1.0, g=0.15, b=0.1}, label = "AP", range = "500 - 3000"},
        dmg = {low = {r=0.8, g=0.5, b=0.2}, high = {r=1.0, g=0.7, b=0.3}, label = "DMG", range = "50 - 200"},
    }
    local STATS_GRADIENT_ORDER = {"buffs", "hit", "crit", "ap", "dmg"}

    local function StatsBarChanged()
        if RC.CharacterStats and RC.CharacterStats.UpdateBarStats then
            RC.CharacterStats:UpdateBarStats()
        end
    end

    -- One editor entry for a stat's low or high end of its gradient.
    local function MakeStatsGradientEntry(statKey, side)
        local grad = STATS_GRADIENT_DEFAULTS[statKey]
        local def = grad[side]
        local isHigh = (side == "high")
        local sideLabel = isHigh and RCL["High value"] or RCL["Low value"]
        return {
            id = "statsbar:" .. statKey .. ":" .. side,
            key = statKey .. " " .. side,
            label = string_format("%s - %s (%s)", grad.label, sideLabel, grad.range),
            hasAlpha = false,
            statKey = statKey,
            isHigh = isHigh,
            default = { r = def.r, g = def.g, b = def.b, a = 1 },
            get = function()
                local s = RC.db.statsBarColors and RC.db.statsBarColors[statKey]
                local c = (s and s[side]) or def
                return { r = c.r, g = c.g, b = c.b, a = 1 }
            end,
            set = function(r, g, b)
                if not RC.db.statsBarColors then RC.db.statsBarColors = {} end
                if not RC.db.statsBarColors[statKey] then
                    RC.db.statsBarColors[statKey] = {
                        low  = { r = grad.low.r,  g = grad.low.g,  b = grad.low.b },
                        high = { r = grad.high.r, g = grad.high.g, b = grad.high.b },
                    }
                end
                RC.db.statsBarColors[statKey][side] = { r = r, g = g, b = b }
                RC:SaveConfigurationToProfile()
            end,
            reset = function()
                local s = RC.db.statsBarColors and RC.db.statsBarColors[statKey]
                if s then
                    s[side] = nil
                    if not s.low and not s.high then
                        RC.db.statsBarColors[statKey] = nil
                    end
                end
                RC:SaveConfigurationToProfile()
            end,
            after = StatsBarChanged,
            wheel = function(row) RC:OpenStatsBarColorPicker(row, STATS_GRADIENT_DEFAULTS) end,
        }
    end

    local function BuildStatsBarCard(self, parent, yPos, frame)
        if not self.db.statsBarColors then
            self.db.statsBarColors = {}
        end

        local entries = {}
        local CSo = RC.CharacterStats
        for _, statKey in ipairs(STATS_GRADIENT_ORDER) do
            -- (no Buffs cell where there is no buff limit: Core_Flavor)
            if not (CSo and CSo.StatOffHere and CSo.StatOffHere(statKey)) then
            table_insert(entries, MakeStatsGradientEntry(statKey, "low"))
            table_insert(entries, MakeStatsGradientEntry(statKey, "high"))
            end
        end

        local card
        card, yPos = self:CreateColorRowCard(parent, yPos, RCL["Stats bar gradients"], entries, {
            -- (the gradients show on the real stats bar in the preview pane)
            above = function(cardRef, cardY)
                local txtGray = RC:GetColor("text", "gray")
                local gradientInfo = RC:CreateFontString(cardRef, "OVERLAY", nil, 10)
                gradientInfo:SetPoint("TOPLEFT", cardRef, "TOPLEFT", 14, cardY)
                gradientInfo:SetText(RCL["Colors blend from |cFFFFD100Low|r -> |cFFFFD100High|r based on value"])
                gradientInfo:SetTextColor(txtGray.r, txtGray.g, txtGray.b)
                return cardY - 18
            end,
            resetAll = function()
                RC.db.statsBarColors = {}
                StatsBarChanged()
                RC:SaveConfigurationToProfile()
            end,
        })
        return yPos
    end

    local function BuildPushoffCard(self, parent, yPos, frame)
        local function after()
            if RC.CharacterStats and RC.CharacterStats.RefreshAlertFrameColors then
                RC.CharacterStats:RefreshAlertFrameColors()
            end
        end
        local card
        card, yPos = self:CreateColorRowCard(parent, yPos, RCL["Buff pushoff alert colors"],
            EntriesFor("buffPushoffAlert", {
                {key = "text",       label = RCL["Alert Text"]},
                {key = "background", label = RCL["Alert Background"]},
                {key = "border",     label = RCL["Alert Border"]},
            }, after), {
            resetAll = function()
                RC:ResetColorCategory("buffPushoffAlert")
                after()
            end,
        })
        return yPos
    end

    local function BuildTTKCard(self, parent, yPos, frame)
        local function after()
            if RC.TTKDisplay and RC.TTKDisplay.RefreshTTKDisplayColors then
                RC.TTKDisplay:RefreshTTKDisplayColors()
            end
        end
        local card
        card, yPos = self:CreateColorRowCard(parent, yPos, RCL["TTK display colors"],
            EntriesFor("ttkDisplay", {
                {key = "background",    label = RCL["Background"]},
                {key = "border",        label = RCL["Border"]},
                {key = "headerText",    label = RCL["Header (Boss Name)"]},
                {key = "labelText",     label = RCL["Labels"]},
                {key = "predictedText", label = RCL["Predicted TTK"]},
                {key = "realtimeText",  label = RCL["Real-time TTK"]},
            }, after), {
            resetAll = function()
                RC:ResetColorCategory("ttkDisplay")
                after()
            end,
        })
        return yPos
    end

    local function BuildMoverCard(self, parent, yPos, frame)
        local card
        card, yPos = self:CreateColorRowCard(parent, yPos, RCL["UI mover colors"],
            EntriesFor("uiMover", {
                {key = "panelBackground", label = RCL["Panel Background"]},
                {key = "panelBorder", label = RCL["Panel Border"]},
                {key = "headerBackground", label = RCL["Header Background"]},
                {key = "headerText", label = RCL["Header Text"]},
                {key = "anchorBackground", label = RCL["Anchor Background"]},
                {key = "anchorBorder", label = RCL["Anchor Border"]},
                {key = "anchorSelected", label = RCL["Anchor Selected"]},
                {key = "anchorSelectedBorder", label = RCL["Selected Border"]},
                {key = "anchorText", label = RCL["Anchor Label"]},
                {key = "anchorPosText", label = RCL["Position Text"]},
                {key = "gridLine", label = RCL["Grid Lines"]},
                {key = "gridCenter", label = RCL["Grid Center"]},
                {key = "inputBackground", label = RCL["Input Background"]},
                {key = "labelText", label = RCL["Label Text"]},
                {key = "buttonBackground", label = RCL["Button Background"]},
                {key = "buttonBackgroundHover", label = RCL["Button Hover"]},
                {key = "borderBlack", label = RCL["Button Border"]},
                {key = "arrowNormal", label = RCL["Arrow Normal"]},
                {key = "arrowHover", label = RCL["Arrow Hover"]},
                {key = "arrowPushed", label = RCL["Arrow Pushed"]},
                {key = "arrowHighlight", label = RCL["Arrow Highlight"]},
                {key = "checkboxBackground", label = RCL["Checkbox Background"]},
                {key = "checkboxLabel", label = RCL["Checkbox Label"]},
                {key = "checkmarkColor", label = RCL["Checkmark"]},
                {key = "whiteText", label = RCL["White Text"]},
                {key = "tooltipText", label = RCL["Tooltip Text"]},
                {key = "saveButtonBg", label = RCL["Save Button"]},
                {key = "saveButtonBgHover", label = RCL["Save Button Hover"]},
            }), {
            resetAll = function() RC:ResetColorCategory("uiMover") end,
        })
        return yPos
    end

    local function BuildResetCard(self, parent, yPos, frame)
        if IsSearching() then return yPos end

        local resetCard = self:CreateSettingsCard(parent, yPos, RCL["Reset all"])
        local cardY = -32

        local resetAllBtn = self.UI:CreateStyledButton(resetCard, RCL["Reset ALL Colors"], 140, 22)
        resetAllBtn:SetPoint("TOPLEFT", resetCard, "TOPLEFT", 14, cardY)
        resetAllBtn:SetScript("OnClick", function()
            -- ResetAllColors only clears db.customColors; statsBarColors is
            -- a separate store and must be wiped here too.
            self:ResetAllColors()
            self.db.statsBarColors = {}
            if self.CharacterStats and self.CharacterStats.UpdateBarStats then
                self.CharacterStats:UpdateBarStats()
            end
            self:SaveConfigurationToProfile()
            self:RefreshUIColors()
            self:ClearSidebarContent(self.sidebarConfigFrame, true)
            self:ShowSidebarFontSettings(frame, true)
            C_Timer.After(0.05, function()
                self:RestoreScrollPosition(self.sidebarConfigFrame)
            end)
        end)
        cardY = cardY - 30

        resetCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - resetCard:GetHeight() - 20
        return yPos
    end

    local COLOR_TABS = {
        { key = "core", label = RCL["Core UI"] },
        { key = "bars", label = RCL["Bars"] },
        { key = "raid", label = RCL["Raid Tools"] },
    }
    local COLOR_MANIFEST = {
        core = {
            { custom = BuildOpacityCard },
            { cat = "ui", label = RCL["Windows & panels"],
              desc = RCL["Window backgrounds, card fills, borders and the gold accent used across the addon."] },
            { cat = "buttons", label = RCL["Buttons"],
              desc = RCL["Every styled button: normal, hover and pressed states, borders and text."] },
            { cat = "sidebar", label = RCL["Sidebar"],
              desc = RCL["The settings sidebar: menu backgrounds, selection and hover states."] },
            { custom = BuildTextCards },
            { custom = BuildInputCard },
            { cat = "scrollbar", label = RCL["Scrollbars"],
              desc = RCL["Scroll tracks, thumbs and arrow buttons everywhere."] },
            { cat = "tooltip", label = RCL["Tooltips"],
              desc = RCL["The addon's tooltips: background, border, title and body text."] },
            { custom = BuildMoverCard },
            { custom = BuildResetCard },
        },
        bars = {
            { cat = "actionBars", label = RCL["Shared bar elements"],
              desc = RCL["Slot states, borders and timers shared by every bar below."] },
            { cat = "weaponBar", label = RCL["Weapon bar"],
              desc = RCL["Weapon slots, stone-type labels and time remaining."] },
            { cat = "consumablesBar", label = RCL["Consumables bar"],
              desc = RCL["Consumable slots, counts and category headers."] },
            { cat = "potionsBar", label = RCL["Potions bar"],
              desc = RCL["Potion slots, cooldown states and counts."] },
            { custom = BuildStatsBarCard },
        },
        raid = {
            { cat = "raids", label = RCL["Raid config"], feature = "raid_configs",
              desc = RCL["Boss rows, enabled/disabled states and ability boxes on the raid pages."] },
            { cat = "consumables", label = RCL["Consumables checker"],
              desc = RCL["The raid-ready consumables checklist: items, counts and hover."] },
            { cat = "gearManager", label = RCL["Gear manager"],
              desc = RCL["Gear set rows, slots and equip states."] },
            { cat = "battleShoutReminder", label = RCL["Battle Shout reminder"],
              desc = RCL["The Battle Shout uptime reminder display."] },
            { cat = "battleShoutPartyTracker", label = RCL["Battle Shout party tracker"], feature = "battle_shout_party",
              desc = RCL["The party coverage tracker rows."] },
            -- The trackers live in Readycheck_Reminders, which loads
            -- after this file, so the gate is checked at render time.
            { cat = "auraTracker", label = RCL["Buff & debuff trackers"],
              desc = RCL["The raid buff and boss debuff timer lists: frame, stack counts and row stripe."],
              whenAddon = "Readycheck_Reminders" },
            { custom = BuildPushoffCard, feature = "buff_pushoff" },
            { cat = "nameplate", label = RCL["Nameplate auras"],
              desc = RCL["Aura icons and text drawn on enemy nameplates."] },
            { custom = BuildTTKCard, feature = "ttk" },
            { cat = "trinketSwap", label = RCL["Trinket swap"],
              desc = RCL["Trinket auto-swap indicators and queue markers."] },
        },
    }

    -- THE BARS / RAID TOOLS PREVIEW: every sample of the tab stacked in
    -- the preview pane instead of a box inside each card. The category
    -- samples are the colour previews (pooled: a repaint creates nothing);
    -- the stats bar and the pushoff alert are the features' own samples.
    local PANE_SECTIONS = {
        bars = { { cat = "actionBars", label = RCL["Shared Bar Elements"] }, { cat = "weaponBar", label = RCL["Weapon Bar"] },
                 { cat = "consumablesBar", label = RCL["Consumables Bar"] }, { cat = "potionsBar", label = RCL["Potions Bar"] },
                 { own = "statsbar", label = RCL["Stats Bar"] } },
        raid = { { cat = "raids", label = RCL["Raid Config"], feature = "raid_configs" }, { cat = "consumables", label = RCL["Consumables Checker"] },
                 { cat = "gearManager", label = RCL["Gear Manager"] }, { cat = "battleShoutReminder", label = RCL["Battle Shout Reminder"] },
                 { own = "pushoff", label = RCL["Buff Pushoff Alert"], feature = "buff_pushoff" } },
    }
    -- a colour group of a feature this game version does not run is not
    -- there (Core_Flavor: feature = its row)
    local function Here(e) return not (e.feature and RC.FeatureOn and not RC:FeatureOn(e.feature)) end
    local function Sections(tab)
        local out = {}
        for _, sec in ipairs(PANE_SECTIONS[tab]) do if Here(sec) then out[#out + 1] = sec end end
        return out
    end
    local PANE_W, SEC_H, LBL_H = 320, 55, 16
    local STATS_SAMPLE = { buffs = 15, hit = 4, crit = 25, ap = 1800, dmg = 104, durability = 76 }
    local PUSH_SAMPLE = { { name = "Flask of the Titans", icon = "Interface\\Icons\\INV_Potion_62", by = { "Battle Shout" } } }
    -- One section at a time (a mode each), so the preview strip shows it
    -- at a readable size; every section is built once and kept.
    local function SecId(sec) return sec.cat or sec.own end
    local function PaneHeight(tab) return SEC_H + LBL_H + 10 end
    local function PaneModes(tab)
        local out = {}
        for _, sec in ipairs(Sections(tab)) do out[#out + 1] = { id = SecId(sec), label = sec.label } end
        return out
    end
    local function PaneBuild(tab)
        return function(canvas, P)
            local y = -4
            P.store.secs = {}
            for i, sec in ipairs(Sections(tab)) do
                local lbl = RC:CreateFontString(canvas, "OVERLAY", nil, 10)
                lbl:SetPoint("TOPLEFT", canvas, "TOPLEFT", 6, y)
                lbl:SetText(sec.label)
                local box = CreateFrame("Frame", nil, canvas)
                box:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, y - LBL_H)
                box:SetPoint("RIGHT", canvas, "RIGHT", -4, 0)
                box:SetHeight(SEC_H)
                box.bg = box:CreateTexture(nil, "BACKGROUND")
                box.bg:SetAllPoints()
                box.bg:SetTexture(RC.UI.FLAT)
                box.border = RC.UI:CreateSimpleBorder(box, 1)
                local entry = { sec = sec, box = box, lbl = lbl, card = {} }
                local CS = RC.CharacterStats
                if sec.cat and ColorPreviews[sec.cat] then
                    ColorPreviews[sec.cat](box, entry.card)
                elseif sec.own == "statsbar" and CS and CS.NewBarPreview then
                    entry.pv = CS:NewBarPreview(box)
                elseif sec.own == "pushoff" and CS and CS.NewPushoffAlertFrame then
                    entry.alert = CS:NewPushoffAlertFrame(box)
                end
                P.store.secs[i] = entry
            end
        end
    end
    local function PaneUpdate(canvas, P)
        local CS = RC.CharacterStats
        local w = RC:GetColor("ui", "windowBackground")
        local bn = RC:GetColor("ui", "borderNormal")
        local gold = RC:GetColor("text", "gold")
        local first = P.store.secs and P.store.secs[1]
        local want = P.mode or (first and SecId(first.sec))
        for _, e in ipairs(P.store.secs or {}) do
            local on = SecId(e.sec) == want
            e.box:SetShown(on)
            e.lbl:SetShown(on)
            e.box.bg:SetVertexColor(w.r, w.g, w.b, 0.95)
            RC.UI:UpdateBorderColor(e.box.border, bn)
            e.lbl:SetTextColor(gold.r, gold.g, gold.b, 1)
            if e.card.rebuildPreview then e.card.rebuildPreview() end
            -- the features' own samples at their real size: the section and
            -- the canvas grow to them (the strip shows them as in game)
            local sw, sh
            if e.pv then
                local bw, bh = CS:FillBarPreview(e.pv, STATS_SAMPLE)
                e.pv.barFrame:SetScale(1)
                e.pv.barFrame:ClearAllPoints()
                e.pv.barFrame:SetPoint("CENTER", e.box, "CENTER", 0, 0)
                e.pv.barFrame:Show()
                sw, sh = bw, bh
            end
            if e.alert then
                CS:LayoutPushoffAlert(e.alert, PUSH_SAMPLE, RC.db.buffPushoffAlert or {})
                e.alert:SetScale(1)
                e.alert:ClearAllPoints()
                e.alert:SetPoint("CENTER", e.box, "CENTER", 0, 0)
                e.alert:Show()
                sw, sh = e.alert:GetWidth(), e.alert:GetHeight()
            end
            if on then
                if sw then
                    e.box:SetHeight(math_max(SEC_H, sh + 8))
                    P.Resize(math_max(PANE_W, sw + 24), LBL_H + math_max(SEC_H, sh + 8) + 10)
                else
                    e.box:SetHeight(SEC_H)
                    P.Resize(PANE_W, PaneHeight())
                end
            end
        end
    end

    function RC:RenderColorTab(parent, yPos, frame, tabKey)
        local list = COLOR_MANIFEST[tabKey]
        if not list then return yPos end
        local inPane = PANE_SECTIONS[tabKey] ~= nil
        if inPane then
            self.UI:DeclarePreview({
                key = "appearance.colors." .. tabKey,
                title = tabKey == "bars" and RCL["Bar colours"] or RCL["Raid tool colours"],
                width = PANE_W, height = PaneHeight(tabKey),
                build = PaneBuild(tabKey), update = PaneUpdate,
                modes = PaneModes(tabKey), modesLabel = RCL["Show"],
            })
        end
        local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
        local card
        for _, entry in ipairs(list) do
            if (entry.whenAddon and isLoaded and not isLoaded(entry.whenAddon)) or not Here(entry) then
                -- Colour group for a feature this install (or this game
                -- version) does not have.
            elseif entry.custom then
                yPos = entry.custom(self, parent, yPos, frame)
            else
                -- the Bars / Raid Tools samples live in the pane
                card, yPos = self:CreateColorCategoryCard(parent, yPos,
                    entry.cat, entry.label, (not inPane) and ColorPreviews[entry.cat] or nil, entry.desc)
            end
        end
        return yPos
    end

    -- Opens Blizzard's colour wheel for `swatch` - any frame carrying
    -- .currentColor/.colorTex/.categoryKey/.colorKey/.defaultColor/.card
    -- (today: the editor's rows, reached through "Colour wheel..."; other
    -- code may still hand in a plain swatch). Live while dragging, and if
    -- the swatch has an OnPickerChanged method (the rows do) it is told
    -- after every change so the inline editor follows the wheel.
    function RC:OpenAppearanceColorPickerLive(swatch)
        local r, g, b, a = swatch.currentColor.r, swatch.currentColor.g, swatch.currentColor.b, swatch.currentColor.a or 1
        local categoryKey = swatch.categoryKey
        local colorKey = swatch.colorKey
        local defColor = swatch.defaultColor
        local card = swatch.card

        local origR, origG, origB, origA = r, g, b, a
        -- Whether the colour was an override before the wheel opened, so
        -- Cancel can put the store back exactly (the live callback below
        -- writes on every drag).
        local origWasOverride = (RC.db and RC.db.customColors and RC.db.customColors[categoryKey]
            and RC.db.customColors[categoryKey][colorKey]) and true or false

        RC.colorPickerInfo = {
            pickerType = "appearance",
            swatch = swatch,
            categoryKey = categoryKey,
            colorKey = colorKey,
            defColor = defColor,
            card = card,
            origR = origR,
            origG = origG,
            origB = origB,
            origA = origA,
            origWasOverride = origWasOverride,
        }

        local function ColorCallback()
            local info = RC.colorPickerInfo
            if not info or not info.swatch then return end
            if info.pickerType ~= "appearance" then return end

            local newR, newG, newB = ColorPickerFrame:GetColorRGB()
            local newA = 1
            if ColorPickerFrame.hasOpacity then
                newA = 1 - OpacitySliderFrame:GetValue()
            end

            info.swatch.colorTex:SetColorTexture(newR, newG, newB, newA)
            info.swatch.currentColor = {r = newR, g = newG, b = newB, a = newA}

            RC:SetColor(info.categoryKey, info.colorKey, newR, newG, newB, newA)

            if info.swatch.OnPickerChanged then
                -- Rows coalesce the preview rebuild + repaint themselves.
                info.swatch:OnPickerChanged()
            elseif info.card and info.card.rebuildPreview then
                info.card.rebuildPreview()
            end
        end

        local function CancelCallback()
            local info = RC.colorPickerInfo
            if not info or not info.swatch then return end
            if info.pickerType ~= "appearance" then return end
            info.swatch.colorTex:SetColorTexture(info.origR, info.origG, info.origB, info.origA)
            info.swatch.currentColor = {r = info.origR, g = info.origG, b = info.origB, a = info.origA}
            if info.origWasOverride then
                RC:SetColor(info.categoryKey, info.colorKey, info.origR, info.origG, info.origB, info.origA)
            else
                RC:ResetColor(info.categoryKey, info.colorKey)
            end
            if info.swatch.OnPickerChanged then
                info.swatch:OnPickerChanged()
            elseif info.card and info.card.rebuildPreview then
                info.card.rebuildPreview()
            end
        end

        ColorPickerFrame:Hide()
        ColorPickerFrame.func = ColorCallback
        ColorPickerFrame.swatchFunc = ColorCallback
        ColorPickerFrame.cancelFunc = CancelCallback
        ColorPickerFrame.hasOpacity = (a ~= nil and a < 1)
        ColorPickerFrame.opacity = 1 - (a or 1)
        ColorPickerFrame.previousValues = {r = origR, g = origG, b = origB}
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame:Show()

        if ColorPickerOkayButton and not ColorPickerOkayButton.wrLiveHooked then
            ColorPickerOkayButton:HookScript("OnClick", function()
                if RC.colorPickerInfo and RC.colorPickerInfo.pickerType == "appearance" then
                    ColorCallback()
                    C_Timer.After(0.1, function()
                        RC:RefreshUIColors()
                    end)
                end
            end)
            ColorPickerOkayButton.wrLiveHooked = true
        end
    end

    -- Same bridge for a stats-bar gradient end: `swatch` carries
    -- .currentColor/.colorTex/.statKey/.isHigh; defaultGradients is the
    -- low/high default table per stat. OnPickerChanged, when present, is
    -- told after every change like above.
    function RC:OpenStatsBarColorPicker(swatch, defaultGradients)
        local r, g, b = swatch.currentColor.r, swatch.currentColor.g, swatch.currentColor.b
        local statKey = swatch.statKey
        local isHigh = swatch.isHigh
        local defGrad = defaultGradients[statKey]

        local origR, origG, origB = r, g, b
        local side = isHigh and "high" or "low"
        local origWasOverride = (RC.db and RC.db.statsBarColors and RC.db.statsBarColors[statKey]
            and RC.db.statsBarColors[statKey][side]) and true or false

        RC.colorPickerInfo = {
            pickerType = "statsbar",
            swatch = swatch,
            statKey = statKey,
            isHigh = isHigh,
            defGrad = defGrad,
            origR = origR,
            origG = origG,
            origB = origB,
            origWasOverride = origWasOverride,
        }

        local function WriteSide(info, cr, cg, cb)
            if not RC.db.statsBarColors then RC.db.statsBarColors = {} end
            if not RC.db.statsBarColors[info.statKey] then
                RC.db.statsBarColors[info.statKey] = {
                    low = {r = info.defGrad.low.r, g = info.defGrad.low.g, b = info.defGrad.low.b},
                    high = {r = info.defGrad.high.r, g = info.defGrad.high.g, b = info.defGrad.high.b}
                }
            end
            if info.isHigh then
                RC.db.statsBarColors[info.statKey].high = {r = cr, g = cg, b = cb}
            else
                RC.db.statsBarColors[info.statKey].low = {r = cr, g = cg, b = cb}
            end
            if RC.CharacterStats and RC.CharacterStats.UpdateBarStats then
                RC.CharacterStats:UpdateBarStats()
            end
            RC:SaveConfigurationToProfile()
        end

        local function ColorCallback()
            local info = RC.colorPickerInfo
            if not info or not info.swatch then return end
            if info.pickerType ~= "statsbar" then return end

            local newR, newG, newB = ColorPickerFrame:GetColorRGB()

            info.swatch.colorTex:SetColorTexture(newR, newG, newB, 1)
            info.swatch.currentColor = {r = newR, g = newG, b = newB}

            WriteSide(info, newR, newG, newB)
            if info.swatch.OnPickerChanged then info.swatch:OnPickerChanged() end
        end

        local function CancelCallback()
            local info = RC.colorPickerInfo
            if not info or not info.swatch then return end
            if info.pickerType ~= "statsbar" then return end
            info.swatch.colorTex:SetColorTexture(info.origR, info.origG, info.origB, 1)
            info.swatch.currentColor = {r = info.origR, g = info.origG, b = info.origB}
            if info.origWasOverride then
                WriteSide(info, info.origR, info.origG, info.origB)
            else
                local s = RC.db.statsBarColors and RC.db.statsBarColors[info.statKey]
                if s then
                    if info.isHigh then s.high = nil else s.low = nil end
                    if not s.low and not s.high then RC.db.statsBarColors[info.statKey] = nil end
                end
                if RC.CharacterStats and RC.CharacterStats.UpdateBarStats then
                    RC.CharacterStats:UpdateBarStats()
                end
                RC:SaveConfigurationToProfile()
            end
            if info.swatch.OnPickerChanged then info.swatch:OnPickerChanged() end
        end

        ColorPickerFrame:Hide()
        ColorPickerFrame.func = ColorCallback
        ColorPickerFrame.swatchFunc = ColorCallback
        ColorPickerFrame.cancelFunc = CancelCallback
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.previousValues = {r = origR, g = origG, b = origB}
        ColorPickerFrame:SetColorRGB(r, g, b)
        ColorPickerFrame:Show()

        if ColorPickerOkayButton and not ColorPickerOkayButton.wrStatsBarHooked then
            ColorPickerOkayButton:HookScript("OnClick", function()
                if RC.colorPickerInfo and RC.colorPickerInfo.pickerType == "statsbar" then
                    ColorCallback()
                end
            end)
            ColorPickerOkayButton.wrStatsBarHooked = true
        end
    end

