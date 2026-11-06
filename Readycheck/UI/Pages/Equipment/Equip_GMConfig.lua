------------------------------------------------------------------------
-- Readycheck - Equipment: Gear Manager Config
-- Settings/Dockable/Sets/Remote tabs for the Gear Manager (docked equip
-- buttons, character-sheet menus, gear set create/delete/rename).
-- Edits GM.settings (pokes GM:SaveSettings) and RC.db.gearSets (pokes
-- RC:SaveConfigurationToProfile). The Remote tab edits another warrior's
-- gear sets (same-account alt or mesh peer) - distinct from the raid-wide
-- RC.remoteEditMode used on Route/Raid Config pages.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_max, math_min = math.floor, math.max, math.min
local table_insert, table_sort = table.insert, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._seq = RC._seq or {}
local _seq = RC._seq
local C, GetCardBg, GetGearSetPreviewPath, TEXT = _seq.C, _seq.GetCardBg, _seq.GetGearSetPreviewPath, _seq.TEXT
    ------------------------------------------------------------------
    -- THE PREVIEW: the docked buttons, the gear set menu and a swap
    -- notice, built and styled by the Gear Manager's own code
    -- (GM:BuildButtonFace, GM:BuildMenuTile, RC.SwapToast.BuildNotice)
    -- with your real sets and gear and sample cooldowns. Clicking a set in
    -- the preview equips it out of combat, exactly as the real menu does;
    -- in combat it never touches your gear.
    ------------------------------------------------------------------
    -- update sizes the canvas to what the mode shows (the strip scales it):
    -- the button row, the set button with its menu beside it (two rows of
    -- sets at most), or the swap notice
    local GPV_W, GPV_H = 200, 48
    local FALLBACK_ICONS = { [13] = 133439, [14] = 133440, [16] = 135349 }
    local ALT_ICONS = { [13] = 133441, [14] = 134183, [16] = 135321 }
    local SAMPLE_ABBR = { [13] = "HoJ", [14] = "DFT", [16] = "TF" }
    local SAMPLE_SETS = { "DPS", "Tank", "Fire Res" }
    local CHEST = "Interface\\Icons\\INV_Chest_Plate16"

    local function PreviewEquip(name)
        local GM = RC.GearManager
        if not (GM and GM.sets and GM.sets[name]) then return end
        if InCombatLockdown() then
            GM:Print(RCL["In combat the preview does not swap gear - use your gear buttons."])
            return
        end
        GM:EquipSet(name)
    end

    local function Hover(b, on)
        if b.hoverHighlight then b.hoverHighlight:SetShown(on) end
        if b.hoverBorder then for _, t in pairs(b.hoverBorder) do t:SetShown(on) end end
    end

    -- a click on a sample's name / timer opens its controls (Text tab)
    local function TagGearTexts(b)
        if b.nameText then RC.UI:TagElement(b.nameText, "gmName") end
        if b.cdText then RC.UI:TagElement(b.cdText, "gmTimer") end
        RC.UI:PickOnClick(b, "gear.manager")
    end

    local function SampleButton(parent, onClick)
        local b = CreateFrame("Button", nil, parent)
        b:SetSize(36, 36)
        RC.GearManager:BuildButtonFace(b, nil)
        TagGearTexts(b)
        b:SetScript("OnEnter", function(self) Hover(self, true) end)
        b:SetScript("OnLeave", function(self) Hover(self, false) end)
        if RC.AttachMouseoverFade and RC._GetGearManagerFadeSettings then
            RC:AttachMouseoverFade(b, RC._GetGearManagerFadeSettings)
        end
        if onClick then b:SetScript("OnClick", onClick) end
        return b
    end

    local function GearPreviewBuild(canvas, P)
        local st = P.store
        st.row = CreateFrame("Frame", nil, canvas)
        st.row:SetSize(10, 10)
        st.row:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        st.set = SampleButton(st.row)
        st.slots = { { slot = 13, b = SampleButton(st.row) }, { slot = 14, b = SampleButton(st.row) },
                     { slot = 16, b = SampleButton(st.row) } }
        st.pin = SampleButton(st.row, function(self) if self.setName then PreviewEquip(self.setName) end end)
        -- the menu panel: the live menu's fill and edge, styled by
        -- GM:StyleMenuFrame; tiles from GM:BuildMenuTile
        local menu = CreateFrame("Frame", nil, st.row)
        menu.bg = menu:CreateTexture(nil, "BACKGROUND", nil, -8)
        menu.bg:SetAllPoints()
        menu.bg:SetTexture(RC.UI.FLAT)
        menu.borders = RC.UI:CreateSimpleBorder(menu, 1)
        st.menu = menu
        st.tiles = {}
        if RC.SwapToast and RC.SwapToast.BuildNotice then
            st.notice = RC.SwapToast.BuildNotice(canvas, false)
            st.notice:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        end
        st.cdStart = GetTime()
        st.token = 0
    end

    local function PaintSlot(GM, st, e, i)
        local b, slot = e.b, e.slot
        local tex = st.swapped and ALT_ICONS[slot] or (GetInventoryItemTexture("player", slot) or FALLBACK_ICONS[slot])
        b.icon:SetTexture(tex)
        b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.icon:SetDesaturated(false)
        b.icon:SetVertexColor(1, 1, 1, 1)
        local link = not st.swapped and GetInventoryItemLink("player", slot)
        local name = link and GetItemInfo(link)
        if GM.settings.showButtonNames ~= false then
            local abbr = name and (RC.GetItemAbbreviation and RC:GetItemAbbreviation(name) or name:sub(1, 5) .. ".") or SAMPLE_ABBR[slot]
            b.nameText:SetText(abbr)
            b.nameText:Show()
        else
            b.nameText:Hide()
        end
        -- trinket 1 on cooldown, trinket 2 with its buff up, the weapon
        -- with a swap queued
        local now = GetTime()
        if now - st.cdStart > 110 then st.cdStart = now end
        local showTimer = GM.settings.showCooldownTextButtons ~= false
        if i <= 2 then
            b.cooldownFrame:SetCooldown(st.cdStart, 120)
            b.cooldownFrame:Show()
            local c = (i == 1) and GM:LookColor("timerColor", "text", "yellow") or GM:LookColor("buffColor", "text", "green")
            b.cdText:SetText(GM:CooldownText(i == 1 and 60 or 12, GM:TimerFormatSpec()))
            b.cdText:SetTextColor(c.r, c.g, c.b)
            b.cdText:SetShown(showTimer)
        else
            b.cooldownFrame:Hide()
            b.cdText:Hide()
        end
        if b.queueIndicator then
            if i == 3 then
                b.queueIndicator.icon:SetTexture(ALT_ICONS[16])
                b.queueIndicator:Show()
            else
                b.queueIndicator:Hide()
            end
        end
    end

    local function GearPreviewUpdate(canvas, P)
        local GM = RC.GearManager
        if not GM then return end
        local st, mode = P.store, P.mode or "buttons"
        local size = GM:GetButtonUnitSize()
        local gap = (GM.settings and GM.settings.buttonSpacing) or 0
        local trunc = RC._gms and RC._gms.TruncateToWidth
        local C = RC._gms and RC._gms.C

        local real = GM:GetSetNames()
        local sets = {}
        for _, n in ipairs(real) do
            if not n:match("^~") and not (GM.IsMenuSetHidden and GM:IsMenuSetHidden(n)) then sets[#sets + 1] = n end
        end
        local fake = #sets == 0
        if fake then sets = SAMPLE_SETS end
        local current = (not fake) and (GM:GetCurrentEquippedSet() or sets[1]) or sets[1]

        local all = { st.set, st.slots[1].b, st.slots[2].b, st.slots[3].b, st.pin }
        for _, b in ipairs(all) do
            b:SetSize(size, size)
            GM:StyleButtonFace(b)
            GM:FitQueueIndicator(b)
            if RC.ApplyMouseoverFade then RC:ApplyMouseoverFade(b, RC._GetGearManagerFadeSettings) end
        end

        -- the gear set button: the set you wear, its icon and status
        local sb = st.set
        sb.icon:SetTexture(fake and CHEST or RC:GetGearSetIcon(current) or CHEST)
        sb.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        sb.icon:SetDesaturated(not GM.enabled)
        sb.icon:SetVertexColor(GM.enabled and 1 or 0.5, GM.enabled and 1 or 0.5, GM.enabled and 1 or 0.5, 1)
        if GM.settings.showGearSetName ~= false and trunc then
            trunc(sb.nameText, current, GM:NameWidth(sb))
            sb.nameText:Show()
        else
            sb.nameText:Hide()
        end
        sb.cooldownFrame:Hide()
        sb.cdText:Hide()
        if sb.queueIndicator then sb.queueIndicator:Hide() end
        GM:PaintSetStatus(sb, (not fake) and GM:SetStatusColor(current) or (C and C.green))

        for i, e in ipairs(st.slots) do PaintSlot(GM, st, e, i) end

        -- a pinned set button (one of yours; clicking it equips it)
        local pinName = (not fake) and (sets[2] or sets[1]) or nil
        local pb = st.pin
        pb.setName = pinName
        if pinName then
            pb.icon:SetTexture(RC:GetGearSetIcon(pinName) or CHEST)
            pb.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            if GM.settings.showGearSetName ~= false and trunc then
                trunc(pb.nameText, pinName, GM:NameWidth(pb))
                pb.nameText:Show()
            else
                pb.nameText:Hide()
            end
            pb.cooldownFrame:Hide()
            pb.cdText:Hide()
            if pb.queueIndicator then pb.queueIndicator:Hide() end
        end

        -- layout per mode; never re-anchor under a running animation
        local sig = mode .. ":" .. size .. ":" .. gap .. ":" .. #sets .. ":" .. tostring(pinName)
        local relayout = st.sig ~= sig
        st.sig = sig
        if relayout then
            RC.Motion.StopTree(st.row)
            if st.notice then RC.Motion.Stop(st.notice) end
        end

        st.row:SetShown(mode ~= "notice")
        if st.notice then st.notice:SetShown(mode == "notice") end

        if mode == "notice" and st.notice then
            local ST = RC.SwapToast
            local d = ST.Sample(P.noticeKind or "set")
            ST:Style(st.notice)
            ST:Layout(d, st.notice)
            local w, h = st.notice:GetWidth() or 240, st.notice:GetHeight() or 60
            -- the canvas is the notice as drawn in game, its own scale
            -- included (the strip shows it at real size)
            local sc = tonumber(ST:Settings().scale) or 1
            st.notice:SetScale(sc)
            P.Resize(w * sc + 10, h * sc + 10)
            return
        end

        -- the menu as the game opens it: every set, three to a row, over
        -- its button
        local shown = sets
        local cols = math.min(3, #shown)
        local menuW, menuH = cols * size, math.ceil(#shown / cols) * size
        local rowW, rowH
        if mode == "menu" then
            for _, e in ipairs(st.slots) do e.b:Hide() end
            pb:Hide()
            sb:Show()
            rowW, rowH = math.max(size, menuW), size + 2 + menuH
            if relayout then
                sb:ClearAllPoints()
                sb:SetPoint("BOTTOM", st.row, "BOTTOM", 0, 0)
                st.menu:ClearAllPoints()
                st.menu:SetPoint("BOTTOM", sb, "TOP", 0, 2)
            end
            st.menu:SetSize(menuW, menuH)
            GM:StyleMenuFrame(st.menu)
            st.menu:Show()
            for i, name in ipairs(shown) do
                local t = st.tiles[i]
                if not t then
                    t = CreateFrame("Button", nil, st.menu)
                    GM:BuildMenuTile(t, nil)
                    TagGearTexts(t)
                    t:SetScript("OnEnter", function(self) Hover(self, true) end)
                    t:SetScript("OnLeave", function(self) Hover(self, false) end)
                    t:SetScript("OnClick", function(self) if self.setName then PreviewEquip(self.setName) end end)
                    st.tiles[i] = t
                end
                t:SetSize(size, size)
                GM:StyleButtonFace(t)
                t:ClearAllPoints()
                t:SetPoint("TOPLEFT", st.menu, "TOPLEFT", ((i - 1) % cols) * size, -math.floor((i - 1) / cols) * size)
                t.icon:SetTexture(fake and CHEST or (RC:GetGearSetIcon(name) or CHEST))
                t.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
                t.setName = (not fake) and name or nil
                if GM.settings.showMenuNames ~= false and trunc then
                    trunc(t.nameText, name, GM:NameWidth(t))
                    local ok = fake or GM:IsSetComplete(name)
                    local c = ok and GM:LookColor("nameColor", "text", "white") or RCC:GetColor("text", "red")
                    t.nameText:SetTextColor(c.r, c.g, c.b, c.a or 1)
                    t.nameText:Show()
                else
                    t.nameText:Hide()
                end
                t:Show()
            end
            for i = #shown + 1, #st.tiles do st.tiles[i]:Hide() end
        else
            st.menu:Hide()
            local order = { sb, st.slots[1].b, st.slots[2].b, st.slots[3].b }
            if pinName then order[#order + 1] = pb else pb:Hide() end
            rowW = #order * size + (#order - 1) * gap + (pinName and 10 or 0)
            rowH = size
            if relayout then
                local x = 0
                for i, b in ipairs(order) do
                    if b == pb then x = x + 10 end
                    b:ClearAllPoints()
                    b:SetPoint("LEFT", st.row, "LEFT", x, 0)
                    x = x + size + gap
                end
            end
            for _, b in ipairs(order) do b:Show() end
        end
        if relayout then
            st.row:SetSize(rowW, rowH)
            st.row:SetScale(1)
        end
        P.Resize(rowW + 12, rowH + 12)
    end

    -- Buttons: the swap animation on the slot buttons. Menu: the menu
    -- opening. Notice: in, a beat, out, back at rest.
    local function GearPreviewReplay(canvas, P)
        local GM = RC.GearManager
        if not GM then return end
        local st, M = P.store, RC.Motion
        local mode = P.mode or "buttons"
        st.token = st.token + 1
        local t = st.token
        if mode == "buttons" then
            for _, e in ipairs(st.slots) do GM:PlaySwapGhost(e.b) end
            st.swapped = not st.swapped
            for i, e in ipairs(st.slots) do PaintSlot(GM, st, e, i) end
        elseif mode == "menu" then
            M.Stop(st.menu)
            st.menu:Hide()
            M.Show(st.menu, M.Normalize(GM:Look().menuAnim, GM.MENU_ANIM))
        elseif mode == "notice" and st.notice then
            local ST, f = RC.SwapToast, st.notice
            M.Stop(f)
            f:Hide()
            local inSpec = ST:ShowSpec()
            M.Show(f, inSpec)
            local hold = M.Duration(inSpec.duration + inSpec.delay) + 1.4
            C_Timer.After(hold, function()
                if t ~= st.token or not f:IsVisible() then return end
                local outSpec = ST:HideSpec()
                M.Hide(f, outSpec)
                C_Timer.After(M.Duration(outSpec.duration + outSpec.delay) + 0.4, function()
                    if t ~= st.token then return end
                    M.Stop(f)
                    if canvas:IsVisible() and (P.mode or "buttons") == "notice" then f:Show() end
                end)
            end)
        end
    end

    local GEAR_PREVIEW_MODES = {
        { id = "buttons", label = RCL["Buttons"] },
        { id = "menu",    label = RCL["Set menu"] },
        { id = "notice",  label = RCL["Swap notice"] },
    }

    local function DeclareGearPreview(self)
        if RC.CustomPick then
            RC.CustomPick.SetHandler("gear.manager", function(k)
                if k ~= "gmName" and k ~= "gmTimer" then return end
                local cf = RC.sidebarConfigFrame and RC.sidebarConfigFrame.compatFrame
                if not cf then return end
                RC.gearManagerTab, RC.gearManagerSettingsTab = "settings", "text"
                RC:ShowSidebarGearManagerConfig(cf, true)
            end)
        end
        return self.UI:DeclarePreview({
            key = "gear.manager", title = RCL["Gear Manager"],
            width = GPV_W, height = GPV_H,
            build = GearPreviewBuild, update = GearPreviewUpdate, replay = GearPreviewReplay,
            modes = GEAR_PREVIEW_MODES, modesLabel = RCL["Show"],
        })
    end

    ------------------------------------------------------------------
    -- SETTINGS TAB: Behavior / Look / Text / Animation / Sound /
    -- Position / Advanced for the gear buttons, hover menus and swap
    -- notices. Every key is the one it always was (GM.settings,
    -- gearSwapRetry, swapToast); the new look options live in
    -- RC.db.gearManager.look and RC.db.swapToast, nil = shipped look.
    ------------------------------------------------------------------
    local GM_SETTINGS_TABS = {
        { key = "behavior",  label = RCL["Behavior"] },
        { key = "look",      label = RCL["Look"] },
        { key = "text",      label = RCL["Text"] },
        { key = "animation", label = RCL["Animation"] },
        { key = "sound",     label = RCL["Sound"] },
        { key = "position",  label = RCL["Position"] },
        { key = "advanced",  label = RCL["Advanced"] },
    }
    -- the sub-tab keys before this layout (search aliases, the session)
    local GM_OLD_TABS = { general = "behavior", buttons = "look", swaps = "advanced" }

    -- the Button text positions card's bindings (module level: the pooled
    -- pickers get every function through their opts)
    local function GearRoot() RC.db.gearManager = RC.db.gearManager or {} return RC.db.gearManager end
    local function GearTextsChanged()
        RC:SaveConfigurationToProfile()
        local GM = RC.GearManager
        if GM then GM:RestyleAllButtons() end
    end
    local GEAR_NAME_TARGETS = { { value = "button", text = RCL["The button"] }, { value = "icon", text = RCL["The icon"] },
        { value = "timer", text = RCL["The timer"] } }
    local GEAR_TIMER_TARGETS = { GEAR_NAME_TARGETS[1], GEAR_NAME_TARGETS[2], { value = "name", text = RCL["The name"] } }
    local GEAR_TIMER_KINDS = { time = true }
    local GEAR_NAME_PT = { bottom = { "BOTTOM", 2 }, top = { "TOP", -2 }, center = { "CENTER", 0 } }
    local function GearNameDefaults()
        local GM = RC.GearManager
        local p = GEAR_NAME_PT[(GM and GM:Look().namePos) or "bottom"] or GEAR_NAME_PT.bottom
        return { point = p[1], relPoint = p[1], x = 0, y = p[2] }
    end
    local function GearTimerDefaults() return { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 } end
    local function GearTimerSample(spec) return RC.GearManager:CooldownText(75, spec or {}) end

    function RC:BuildGearManagerSettingsTab(parent, yPos, frame, GM, P)
        local L = _seq.Look
        local ST = RC.SwapToast
        local sts = ST and ST:Settings() or {}
        local look = GM:Look()
        local sub = L.TabKey(RC.gearManagerSettingsTab, GM_SETTINGS_TABS, GM_OLD_TABS, "behavior")
        RC.gearManagerSettingsTab = sub
        local _, tabY = self.UI:CreateTabGroup(parent, { y = yPos, tabs = GM_SETTINGS_TABS, selected = sub,
            inset = 18, advance = 34,
            onClick = function(k) RC.gearManagerSettingsTab = k RC:ShowSidebarGearManagerConfig(frame, true) end })
        yPos = tabY

        local function Save() if GM.SaveSettings then GM:SaveSettings() else RC:SaveConfigurationToProfile() end end
        local function Restyle() GM:RestyleAllButtons() end
        local function Notice() if ST then ST:Refresh() end end
        local function Rebuild() RC:ShowSidebarGearManagerConfig(frame, true) end
        local function GSet(key, on, after)
            GM.settings[key] = on
            Save()
            if after then after() end
        end

        if sub == "behavior" then
            yPos = L.Card(parent, yPos, RCL["Gear manager"], function(card, cy)
                local enableCb
                cy, enableCb = L.Check(card, cy, RCL["Enable the Gear Manager"], GM.enabled, function(on)
                    GM.enabled = on
                    if on and GM.Enable then GM:Enable() elseif GM.Disable then GM:Disable() end
                end)
                local mark = RC.UI:MarkCard(card)
                cy = L.Check(card, cy, RCL["Character sheet menus (hold Alt over a slot)"], GM.settings.characterSheetMenus, function(on)
                    GSet("characterSheetMenus", on)
                end)
                cy = L.Desc(card, cy, RCL["Pin buttons: Alt+Click a set in the gear set menu, or Alt+Click an item in any slot menu, to keep it on screen as its own one-click equip button. Pinned buttons drag and dock like the rest. Unlock and click the X on one to remove it."])
                RC.UI:BindDependents(enableCb, RC.UI:CardSince(card, mark))
                return cy

            end)
            yPos = L.Card(parent, yPos, RCL["Dockable buttons"], function(card, cy)
                cy = L.Check(card, cy, RCL["Shift+Left-click cancels that slot's queued swap"], GM.settings.shiftCancelQueue ~= false, function(on)
                    GM.settings.shiftCancelQueue = on
                    local gdb = RC.db.gearManager
                    if gdb and gdb.settings then gdb.settings.shiftCancelQueue = on end
                    RC:SaveConfigurationToProfile()
                    if not InCombatLockdown() then
                        for _, b in pairs(GM.buttons or {}) do
                            if b.SetAttribute then b:SetAttribute("shift-type1", on and "cancelqueue" or nil) end
                        end
                    end
                end)
                cy = L.Check(card, cy, RCL["Trinket docks: left-click slot 13, right-click slot 14"], GM.settings.trinketDockSplitClick == true, function(on)
                    GSet("trinketDockSplitClick", on)
                end)
                cy = L.Check(card, cy, RCL["Fade the buttons until you hover them"], GM.settings.mouseoverFade, function(on)
                    GSet("mouseoverFade", on, function() if GM.UpdateButtonsMouseoverFade then GM:UpdateButtonsMouseoverFade() end end)
                end)
                cy = L.Slider(card, cy - 4, { label = RCL["Faded opacity"], min = 0, max = 100, step = 5,
                    value = math.floor((GM.settings.mouseoverFadeAlpha or 0.15) * 100 + 0.5),
                    fmt = function(v) return v .. "%" end,
                    set = function(v)
                        GM.settings.mouseoverFadeAlpha = v / 100
                        Save()
                        if GM.UpdateButtonsMouseoverFade then GM:UpdateButtonsMouseoverFade() end
                    end })
                return cy
            end)
            yPos = L.Card(parent, yPos, RCL["Tooltips"], function(card, cy)
                cy = L.Check(card, cy, RCL["Show tooltips on gear buttons and menus"], GM.settings.showTooltips == true, function(on)
                    GSet("showTooltips", on)
                end)
                cy = L.Check(card, cy, RCL["Only out of combat"], GM.settings.tooltipsOutOfCombatOnly == true, function(on)
                    GSet("tooltipsOutOfCombatOnly", on)
                end)
                return cy
            end)
            if ST then
                yPos = L.Card(parent, yPos, RCL["Swap notices"], function(card, cy)
                    cy = L.Desc(card, cy, RCL["A small notice each time Readycheck changes your gear for you - a route step, a boss pull or kill, a trinket rotation, a queued swap landing after combat: what went on, with icons, and why. Your own manual swaps never make one."])
                    cy = L.Check(card, cy, RCL["Show a notice when Readycheck swaps my gear"], sts.enabled == true, function(on)
                        sts.enabled = on
                        RC:SaveConfigurationToProfile()
                    end)
                    cy = L.Check(card, cy, RCL["Name each piece (a full set shows an icon strip)"], sts.showNames ~= false, function(on)
                        sts.showNames = on
                        RC:SaveConfigurationToProfile()
                    end)
                    cy = L.Slider(card, cy - 4, { label = RCL["On screen for"], min = 1, max = 10, step = 0.5, scale = 2,
                        value = tonumber(sts.duration) or 4, fmt = function(v) return string_format("%.1fs", v) end,
                        set = function(v) sts.duration = v end })
                    return cy
                end)
            end

        elseif sub == "look" then
            yPos = L.Card(parent, yPos, RCL["Buttons"], function(card, cy)
                cy = L.Slider(card, cy, { label = RCL["Button size"], min = 20, max = 64, step = 2,
                    value = GM:GetButtonUnitSize(), fmt = function(v) return v .. RCL[" px"] end,
                    set = function(v)
                        GM.settings.buttonSize = v
                        Save()
                        GM:ApplyButtonSize()
                        Restyle()
                    end })
                cy = L.Slider(card, cy, { label = RCL["Space between docked buttons"], min = 0, max = 12, step = 1,
                    value = GM.settings.buttonSpacing or 0, fmt = function(v) return v .. RCL[" px"] end,
                    set = function(v)
                        GM.settings.buttonSpacing = v
                        Save()
                        if GM.RefreshDockGaps then GM:RefreshDockGaps() end
                    end })
                cy = L.Slider(card, cy, { label = RCL["Border thickness"], min = 0, max = 4, step = 1,
                    value = tonumber(look.borderSize) or 1, fmt = function(v) return v == 0 and RCL["None"] or (v .. RCL[" px"]) end,
                    set = function(v) look.borderSize = v Restyle() end })
                cy = L.OwnColor(card, cy, look, "borderColor", RCL["Border colour"],
                    function() return RC:GetColor("ui", "borderNormal") end, Restyle)
                cy = L.ThemeColor(card, cy, "gearManager", "slotHoverBorder", RCL["Hover ring colour"],
                    RCL["Also the hover ring on gear set and slot menus (Appearance > Colors)."], Restyle)
                cy = L.Check(card, cy - 2, RCL["Status ring on the gear set button"], GM.settings.showGearSetStatusBorder ~= false, function(on)
                    GSet("showGearSetStatusBorder", on, function() if GM.ScheduleGearSetStatusRefresh then GM:ScheduleGearSetStatusRefresh() end end)
                end, RCL["Green: the set is on. Gold: some pieces are not. Red: a piece is missing from your bags."])
                return cy
            end)
            yPos = L.Card(parent, yPos, RCL["Hover menus"], function(card, cy)
                cy = L.ThemeColor(card, cy, "gearManager", "frameBackground", RCL["Menu background"], nil, Restyle)
                cy = L.ThemeColor(card, cy, "gearManager", "frameBorder", RCL["Menu border"], nil, Restyle)
                return cy
            end)
            if ST then
                yPos = L.Card(parent, yPos, RCL["Swap notice"], function(card, cy)
                    cy = L.Check(card, cy, RCL["Show the background box"], sts.showBackground ~= false, function(on)
                        sts.showBackground = on Notice() RC:SaveConfigurationToProfile()
                    end, RCL["Off: the text sits on the world with a shadow, like the route tracker."])
                    cy = L.OwnColor(card, cy, sts, "bgColor", RCL["Background colour"], function()
                        local c = RC:GetColor("ui", "cardBackground")
                        return { r = c.r, g = c.g, b = c.b, a = ST.BG_ALPHA }
                    end, Notice, nil, true)
                    cy = L.OwnColor(card, cy, sts, "borderColor", RCL["Border colour"],
                        function() return RC:GetColor("ui", "borderNormal") end, Notice)
                    cy = L.Slider(card, cy - 2, { label = RCL["Icon size"], min = 12, max = 36, step = 1,
                        value = tonumber(sts.iconSize) or ST.ICON_SIZE, fmt = function(v) return v .. RCL[" px"] end,
                        set = function(v) sts.iconSize = v Notice() end })
                    cy = L.Slider(card, cy, { label = RCL["Space between icons"], min = 0, max = 10, step = 1,
                        value = tonumber(sts.iconGap) or ST.ICON_GAP, fmt = function(v) return v .. RCL[" px"] end,
                        set = function(v) sts.iconGap = v Notice() end })
                    cy = L.Slider(card, cy, { label = RCL["Scale"], min = 0.6, max = 1.6, step = 0.05, scale = 100,
                        value = tonumber(sts.scale) or 1, fmt = function(v) return math.floor(v * 100 + 0.5) .. "%" end,
                        set = function(v) sts.scale = v Notice() end })
                    if sts.width then
                        local autoW = self.UI:CreateStyledButton(card, RCL["Auto width"], 90, 22)
                        autoW:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                        autoW:SetScript("OnClick", function()
                            sts.width = nil
                            RC:SaveConfigurationToProfile()
                            if ST.current then ST:Layout(ST.current) end
                            Rebuild()
                        end)
                        cy = L.Desc(card, cy - 26, RCL["Forget the width you dragged the notice to; it sizes to its content again."])
                    end
                    return cy
                end)
            end

        elseif sub == "text" then
            yPos = L.Card(parent, yPos, RCL["What the buttons show"], function(card, cy)
                local rows = {
                    { "showButtonNames", RCL["Item names on dockable buttons"], function() if GM.RestoreButtonsFromProfile then GM:RestoreButtonsFromProfile() end end },
                    { "showGearSetName", RCL["Set name on the gear set button"], function() if GM.UpdateGearSetButtonIcon then GM:UpdateGearSetButtonIcon() end end },
                    { "showMenuNames", RCL["Item names in hover menus"] },
                    { "showCharSlotNames", RCL["Item names on character pane slots"] },
                    { "showCharPaneNames", RCL["Item names in character pane menus"] },
                    { "showCooldownTextButtons", RCL["Timer text on dockable buttons"], function() if GM.UpdateButtonCooldowns then GM:UpdateButtonCooldowns() end end },
                    { "showCooldownTextMenus", RCL["Timer text in hover menus"], function() if GM.UpdateMenuCooldowns then GM:UpdateMenuCooldowns() end end },
                }
                for _, r in ipairs(rows) do
                    cy = L.Check(card, cy, r[2], GM.settings[r[1]] ~= false, function(on) GSet(r[1], on, r[3]) end)
                end
                return cy
            end)
            yPos = L.Card(parent, yPos, RCL["Button text"], function(card, cy)
                cy = L.Font(card, cy, look, "nameFont", RCL["Name text"], GM.NAME_FONT, "DPS  HoJ  TF", Restyle)
                cy = L.OwnColor(card, cy, look, "nameColor", RCL["Name colour"],
                    function() return RC:GetColor("text", "white") end, Restyle,
                    RCL["The gear set name still turns gold or red while the set is not fully on."])
                cy = cy - 2
                self.UI:CreateSegmentedControl(card, { x = 14, y = cy, height = 22, label = RCL["Name position"],
                    items = { { key = "bottom", label = RCL["Bottom"] }, { key = "center", label = RCL["Middle"] }, { key = "top", label = RCL["Top"] } },
                    selected = look.namePos or "bottom",
                    onSelect = function(k) look.namePos = (k ~= "bottom") and k or nil Restyle() RC:SaveConfigurationToProfile() end })
                cy = cy - 34
                cy = L.Font(card, cy, look, "timerFont", RCL["Timer text"], GM.TIMER_FONT, "1m  12  45", Restyle)
                cy = L.OwnColor(card, cy, look, "timerColor", RCL["Cooldown timer colour"],
                    function() return RC:GetColor("text", "yellow") end, Restyle)
                cy = L.OwnColor(card, cy, look, "buffColor", RCL["Buff timer colour"],
                    function() return RC:GetColor("text", "green") end, Restyle,
                    RCL["The seconds left on an on-use item's buff while it is up."])
                return cy
            end)
            -- where the name and timer sit on a button (gearManager.anchors.*)
            -- and how the timer reads (gearManager.formats.timer)
            yPos = L.Card(parent, yPos, RCL["Button text positions"], function(card, cy)
                local cw = card:GetWidth() or 0
                local W = (cw > 240) and math.min(460, cw - 28) or 420
                local ag, as = RC.UI:CustomAccess(GearRoot, "anchors", "name", GearTextsChanged)
                local g = RC.UI:CreateTextElement(card, { label = RCL["Name position"], key = "gmName", width = W,
                    anchorGet = ag, anchorSet = as, targets = GEAR_NAME_TARGETS,
                    defaultTargetLabel = RCL["Where Name position puts it"], anchorDefaults = GearNameDefaults })
                g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                cy = cy - g:GetHeight() - 14
                ag, as = RC.UI:CustomAccess(GearRoot, "anchors", "timer", GearTextsChanged)
                local fg, fs = RC.UI:CustomAccess(GearRoot, "formats", "timer", GearTextsChanged)
                g = RC.UI:CreateTextElement(card, { label = RCL["Timer"], key = "gmTimer", width = W,
                    formatGet = fg, formatSet = fs, formatDefaults = GM.TIMER_FORMAT, formatKinds = GEAR_TIMER_KINDS,
                    formatSample = GearTimerSample,
                    anchorGet = ag, anchorSet = as, targets = GEAR_TIMER_TARGETS,
                    defaultTargetLabel = RCL["Middle of the button"],
                    anchorDefaults = GearTimerDefaults })
                g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                cy = cy - g:GetHeight() - 14
                return L.Desc(card, cy + 4, RCL["Positions also apply to the hover menu tiles; the timer format is for the dockable buttons. Reset puts a text back."])
            end)
            if ST then
                yPos = L.Card(parent, yPos, RCL["Swap notice text"], function(card, cy)
                    cy = L.Font(card, cy, sts, "titleFont", RCL["Title"], ST.TITLE_FONT, "DPS equipped", Notice)
                    cy = L.OwnColor(card, cy, sts, "titleColor", RCL["Title colour"], function() return RC:GetColor("ui", "headerText") end, Notice)
                    cy = L.Font(card, cy, sts, "namesFont", RCL["Piece names"], ST.NAMES_FONT, "Hand of Justice, Drake Fang Talisman", Notice)
                    cy = L.OwnColor(card, cy, sts, "namesColor", RCL["Piece names colour"], function() return RC:GetColor("text", "normal") end, Notice)
                    cy = L.Font(card, cy, sts, "contextFont", RCL["Reason line"], ST.CONTEXT_FONT, "Route: 3x Plague Beast", Notice)
                    cy = L.OwnColor(card, cy, sts, "contextColor", RCL["Reason line colour"], function() return RC:GetColor("text", "gray") end, Notice)
                    return cy
                end)
                -- where each notice text sits (swapToast.anchors.*)
                yPos = L.Card(parent, yPos, RCL["Swap notice text positions"], function(card, cy)
                    local cw = card:GetWidth() or 0
                    local W = (cw > 240) and math.min(460, cw - 28) or 420
                    local function After() RC:SaveConfigurationToProfile() Notice() end
                    local function Root() return ST:Settings() end
                    local T = { icon = { value = "icon", text = RCL["The title icon"] }, title = { value = "title", text = RCL["The title"] },
                        names = { value = "names", text = RCL["The piece names"] }, strip = { value = "strip", text = RCL["The piece icons"] },
                        frame = { value = "frame", text = RCL["The whole notice"] } }
                    local rows = {
                        { "title", RCL["Title"], { T.icon, T.frame }, RCL["Right of the title icon"], { point = "LEFT", relPoint = "RIGHT", x = 6, y = 0 } },
                        { "names", RCL["Piece names"], { T.strip, T.title, T.frame }, RCL["Right of the piece icons"], { point = "LEFT", relPoint = "RIGHT", x = 7, y = 0 } },
                        { "context", RCL["Reason line"], { T.names, T.title, T.frame }, RCL["Under the pieces"], { point = "TOPLEFT", relPoint = "TOPLEFT", x = 8, y = -50 } },
                    }
                    for _, r in ipairs(rows) do
                        local ag, as = RC.UI:CustomAccess(Root, "anchors", r[1], After)
                        local def = r[5]
                        local g = RC.UI:CreateTextElement(card, { label = r[2], key = "toast" .. r[1], width = W,
                            anchorGet = ag, anchorSet = as, targets = r[3], defaultTargetLabel = r[4],
                            anchorDefaults = function() return def end })
                        g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                        cy = cy - g:GetHeight() - 14
                    end
                    return L.Desc(card, cy + 4, RCL["Reset puts a text back where the notice always put it."])
                end)
            end

        elseif sub == "animation" then
            yPos = L.Card(parent, yPos, RCL["Gear buttons"], function(card, cy)
                cy = L.Anim(card, cy, look, "swapAnim", RCL["When an item changes (the old icon goes)"], "out", GM.SWAP_ANIM, P)
                cy = L.Anim(card, cy, look, "menuAnim", RCL["When a hover menu opens"], "in", GM.MENU_ANIM, P,
                    { "none", "fade", "slide", "pop", "bounce" })
                return L.Desc(card, cy, RCL["Replay in the preview shows each one: Buttons for the item change, Set menu for the menu."])
            end)
            if ST then
                yPos = L.Card(parent, yPos, RCL["Swap notice"], function(card, cy)
                    cy = L.Anim(card, cy, sts, "showAnim", RCL["When it appears"], "in", ST.SHOW_ANIM, P)
                    cy = L.Anim(card, cy, sts, "hideAnim", RCL["When it goes"], "out", ST.HIDE_ANIM, P)
                    return cy
                end)
            end

        elseif sub == "sound" then
            if ST then
                yPos = L.Card(parent, yPos, RCL["Swap notice"], function(card, cy)
                    cy = L.Label(card, cy, RCL["Sound when a notice shows"])
                    local picker = self.UI:CreateSoundPicker(card, { width = 220,
                        selected = (sts.soundKey ~= "" and sts.soundKey) or nil,
                        onPick = function(key) sts.soundKey = key or "" RC:SaveConfigurationToProfile() end })
                    picker:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                    local noSnd = self.UI:CreateStyledButton(card, RCL["No sound"], 80, 22)
                    noSnd:SetPoint("LEFT", picker.playButton, "RIGHT", 6, 0)   -- after the picker's own Play
                    noSnd:SetScript("OnClick", function()
                        sts.soundKey = ""
                        RC:SaveConfigurationToProfile()
                        Rebuild()
                    end)
                    cy = cy - 32
                    return L.Desc(card, cy, (sts.soundKey and sts.soundKey ~= "") and sts.soundKey or RCL["Silent."])
                end)
            end

        elseif sub == "position" then
            yPos = L.Card(parent, yPos, RCL["Gear buttons"], function(card, cy)
                cy = L.Check(card, cy, RCL["Lock the dockable buttons"], GM.locked == true, function(on)
                    if on then if GM.Lock then GM:Lock() end elseif GM.Unlock then GM:Unlock() end
                end, RCL["Stops accidental drags and hides the remove button. Alt+Click a slot on your character sheet to add a button; drag one onto another to dock them."])
                return cy
            end)
            if ST then
                yPos = L.Card(parent, yPos, RCL["Swap notice"], function(card, cy)
                    cy = L.Check(card, cy, RCL["Lock its position (drag to move when unlocked)"], sts.locked ~= false, function(on)
                        sts.locked = on
                        RC:SaveConfigurationToProfile()
                        Notice()
                    end)
                    local test = self.UI:CreateStyledButton(card, RCL["Test"], 70, 22)
                    test:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy - 2)
                    test:SetScript("OnClick", function() ST:Test() end)
                    local reset = self.UI:CreateStyledButton(card, RCL["Reset position"], 110, 22)
                    reset:SetPoint("LEFT", test, "RIGHT", 6, 0)
                    reset:SetScript("OnClick", function()
                        sts.anchorPoint, sts.xOffset, sts.yOffset = "CENTER", 0, 220
                        sts.centred = nil
                        RC:SaveConfigurationToProfile()
                        Notice()
                        RC.UI:NotifySettingChanged("reset")
                    end)
                    cy = cy - 30
                    return L.Desc(card, cy, RCL["It is in Edit Mode too, as Gear swap notice."])
                end)
            end

        elseif sub == "advanced" then
            -- Boss gear swap retries: engage overrides, after-boss overrides
            -- and the post-combat set all verify what landed and retry with
            -- these numbers.
            RC.db.gearSwapRetry = RC.db.gearSwapRetry or {}
            local rt = RC.db.gearSwapRetry
            local attempts, interval = RC:GearSwapRetryCfg()
            yPos = L.Card(parent, yPos, RCL["Boss gear swap retries"], function(card, cy)
                cy = L.Slider(card, cy, { label = RCL["Attempts before giving up"], min = 1, max = 10, step = 1,
                    value = attempts, set = function(v) rt.attempts = v end })
                cy = L.Slider(card, cy, { label = RCL["Time between attempts"], min = 0.5, max = 5, step = 0.25, scale = 100,
                    value = interval, fmt = function(v) return string_format("%.2fs", v) end,
                    set = function(v) rt.interval = v end })
                cy = L.Check(card, cy, RCL["Warn in chat when a swap could not complete"], rt.warn ~= false, function(on)
                    rt.warn = on
                    RC:SaveConfigurationToProfile()
                end)
                return L.Desc(card, cy, RCL["Applies to engage overrides, after-boss overrides and the post-combat set. Each attempt equips, waits, and checks what actually landed. Attempts made in combat are held until it ends."])
            end)
            yPos = L.Card(parent, yPos, RCL["Reset the look"], function(card, cy)
                local r1 = self.UI:CreateStyledButton(card, RCL["Reset button look"], 150, 22)
                r1:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                r1:SetScript("OnClick", function()
                    RC.db.gearManager.look = {}
                    RC:SaveConfigurationToProfile()
                    Restyle()
                    Rebuild()
                end)
                local r2 = self.UI:CreateStyledButton(card, RCL["Reset notice look"], 150, 22)
                r2:SetPoint("LEFT", r1, "RIGHT", 6, 0)
                r2:SetScript("OnClick", function()
                    for _, k in ipairs({ "showAnim", "hideAnim", "titleFont", "namesFont", "contextFont", "titleColor",
                        "namesColor", "contextColor", "bgColor", "borderColor", "iconSize", "iconGap" }) do sts[k] = nil end
                    RC:SaveConfigurationToProfile()
                    Notice()
                    Rebuild()
                end)
                cy = cy - 28
                return L.Desc(card, cy, RCL["Fonts, colours, sizes and animations go back to how Readycheck ships. Your sets, buttons and positions stay."])
            end)
        end
        -- the gear buttons' layer / fade / shadow (the customization standard)
        yPos = self.UI:FrameCardsForTab(sub, parent, yPos, function() return RC.db.gearManager end, function() GM:RestyleAllButtons() end,
            { scale = false, prefix = RCL["Gear buttons "], chromeFields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })
        -- the swap notice's layer / fade / shadow (the customization standard)
        if ST then
            yPos = self.UI:FrameCardsForTab(sub, parent, yPos, function() return ST:Settings() end, Notice,
                { scale = false, prefix = RCL["Swap notice "], chromeFields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })
        end
        return yPos
    end

    function RC:ShowSidebarGearManagerConfig(frame, preserveScroll)
        local cardY
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local parent = frame.scrollChild
        local yPos = -20

        local headerFrame, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Gear Manager"],
            RCL["Create and manage gear sets"], "Interface\\Icons\\INV_Chest_Plate16")
        yPos = newY

        if not self.GearManager then
            local errorCard = self:CreateSettingsCard(parent, yPos, RCL["Error"])
            local cardY = -32
            local errorText = self:CreateFontString(errorCard, "OVERLAY", nil, 11)
            errorText:SetPoint("TOPLEFT", errorCard, "TOPLEFT", 14, cardY)
            errorText:SetText(RCL["Gear Manager not loaded. Please /reload."])
            errorText:SetTextColor(TEXT.red[1], TEXT.red[2], TEXT.red[3])
            errorCard:SetContentHeight(50)
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            return
        end

        local GM = self.GearManager
        local P = DeclareGearPreview(self)

        GM.currentEditingSet = nil
        GM.inSidebarEditorMode = nil
        GM:HideMenu()

        GM.remoteItemsOverride  = nil
        GM.remoteEquippedBySlot = nil
        GM.remoteSetBuffers     = GM.remoteSetBuffers     or {}
        GM.remoteEditCallbacks  = GM.remoteEditCallbacks  or {}
        -- These buffers only persist while the Remote tab stays open;
        -- leaving it drops any un-saved remote edit state so it can't
        -- leak into the local gear set editor.
        if RC.gearManagerTab ~= "remote" then
            GM.remoteSetBuffers    = {}
            GM.remoteEditCallbacks = {}
        end

        for i = 0, 19 do
            local oldBtn = _G["WRGearSetSlot" .. i]
            if oldBtn then
                oldBtn:Hide()
                oldBtn:ClearAllPoints()
                if oldBtn.icon then oldBtn.icon:SetTexture(nil) end
                oldBtn:SetParent(nil)
                _G["WRGearSetSlot" .. i] = nil
            end
        end

        if GM.HideMenu then GM:HideMenu() end

        RC.gearManagerTab = RC.gearManagerTab or "settings"
        local _meshOnGear = (function()
            local t = ReadycheckDB and ReadycheckDB.meshSyncEnabledPerChar
            if not t then return false end
            -- Normalized toon key, same as every mesh table (Mesh_Proto).
            local k = (RC._mss and RC._mss.GetToonKey and RC._mss.GetToonKey())
                or ((UnitName("player") or "") .. "-" .. (GetRealmName() or ""))
            return t[k] == true
        end)()
        if RC.gearManagerTab == "remote" and not _meshOnGear then
            RC.gearManagerTab = "settings"
        end
        local gearManagerTabs = {
            { "settings", "Settings"          },
            { "sets",     "Sets"              },
            { "dockable", "Dockable & Macros" },
        }
        if _meshOnGear then
            table.insert(gearManagerTabs, { "remote", "Remote Warriors" })
        end
        yPos = self:BuildSettingsTabBar(parent, yPos, gearManagerTabs, RC.gearManagerTab, function(k)
            RC.gearManagerTab = k
            RC:ShowSidebarGearManagerConfig(frame, true)
        end)

        if RC.gearManagerTab == "settings" then
        yPos = self:BuildGearManagerSettingsTab(parent, yPos, frame, GM, P)

        elseif RC.gearManagerTab == "dockable" then
        local dockCard = self:CreateSettingsCard(parent, yPos, RCL["Dockable buttons"])
        cardY = -30

        cardY = RC.UI:CreateHelpLine(dockCard, 14, cardY, RCL["Floating gear icons you can place anywhere on screen. Hover one to see every item you own for that slot and click to equip. Great for one-click trinket and weapon swaps."],
            { color = { "text", "disabled" }, gap = 10 })

        local dockLines = {
            { key = "Alt+Click a slot on your character sheet",  val = "create or remove a dockable button" },
            { key = "Drag a dockable button",                    val = "move it anywhere, or dock it onto another UI frame" },
            { key = "Hover a dockable button",                   val = "shows a menu of items you can equip in that slot" },
            { key = "Alt+Hover a character sheet slot",          val = "same menu directly on the character pane (toggle above)" },
            { key = "Lock Dockable Buttons",                     val = "stops accidental drags and hides the remove button" },
        }
        local normCol = self:GetColor("text", "normal")
        for _, row in ipairs(dockLines) do
            local keyText = self:CreateFontString(dockCard, "OVERLAY", nil, 10)
            keyText:SetPoint("TOPLEFT", dockCard, "TOPLEFT", 20, cardY)
            keyText:SetText(row.key)
            local gc = self:GetColor("ui", "accentGold")
            keyText:SetTextColor(gc.r, gc.g, gc.b)

            local valText = self:CreateFontString(dockCard, "OVERLAY", nil, 10)
            -- top-aligned with its key: a value that wraps grows down,
            -- never up into the row above
            valText:SetPoint("TOPLEFT", keyText, "TOPRIGHT", 8, 0)
            valText:SetPoint("RIGHT", dockCard, "RIGHT", -14, 0)
            valText:SetJustifyH("LEFT")
            valText:SetText("- " .. row.val)
            valText:SetTextColor(normCol.r, normCol.g, normCol.b)

            local rowH = math.max(keyText:GetStringHeight() or 12, valText:GetStringHeight() or 12)
            cardY = cardY - rowH - 4
        end
        cardY = cardY - 6

        dockCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - dockCard:GetHeight() - 15

        -- Entries hidden from dockable buttons' hover menus (GM_Menu.lua).
        do
            local hideCard = self:CreateSettingsCard(parent, yPos, RCL["Hidden in hover menus"])
            cardY = -30
            local function Redraw()
                C_Timer.After(0, function() RC:ShowSidebarGearManagerConfig(frame, true) end)
            end
            local function Gray(fs)
                local c = self:GetColor("text", "disabled")
                fs:SetTextColor(c.r, c.g, c.b)
            end

            cardY = RC.UI:CreateHelpLine(hideCard, 14, cardY, string_format(RCL["Hide: Ctrl+Right-click an item or set in a dockable button's hover menu.\nShow again: hold %s over the menu so hidden ones show faded, then %s the one you want back - or untick it below.\nCopies with a different enchant are separate, so you can hide the plain pair and keep the enchanted one. Character sheet menus and the set editor always show everything."],
                GM:MenuRevealKeyLabel(), GM:MenuUnhideComboLabel()),
                { short = RCL["Ctrl+Right-click an entry in a hover menu to hide it; untick it below to bring it back."],
                  title = RCL["Hiding entries"], gap = 10 })

            local rkLbl = self:CreateFontString(hideCard, "OVERLAY", nil, 10)
            rkLbl:SetPoint("TOPLEFT", hideCard, "TOPLEFT", 14, cardY)
            rkLbl:SetText(RCL["Hold to show hidden entries"])
            Gray(rkLbl)
            cardY = cardY - 18
            local rkNames = { SHIFT = "Shift", CTRL = "Ctrl", ALT = "Alt" }
            local rkDD = self.UI:CreateScrollableDropdown(hideCard, 140, rkNames[GM.settings.menuRevealKey or "SHIFT"] or "Shift", 3)
            rkDD:SetPoint("TOPLEFT", hideCard, "TOPLEFT", 14, cardY)
            rkDD:SetItems({
                { text = "Shift", value = "SHIFT" },
                { text = "Ctrl",  value = "CTRL" },
                { text = "Alt",   value = "ALT" },
            }, function(value)
                GM.settings.menuRevealKey = value
                GM:SaveSettings()
                Redraw()
            end)
            if rkDD.SetSearchEnabled then rkDD:SetSearchEnabled(false) end
            cardY = cardY - 40

            -- Everything hidden right now, every slot, one Show button each.
            do
                local hl = self:CreateFontString(hideCard, "OVERLAY", nil, 12)
                hl:SetPoint("TOPLEFT", hideCard, "TOPLEFT", 14, cardY)
                hl:SetText(RCL["Hidden right now"])
                local gc = self:GetColor("text", "gold")
                hl:SetTextColor(gc.r, gc.g, gc.b)
                cardY = cardY - 20
                local list = {}
                for name in pairs(GM.settings.hiddenMenuSets or {}) do
                    local set = GM.sets[name]
                    list[#list + 1] = { label = name, where = RCL["Gear Sets"],
                        icon = (set and set.icon) or "Interface\\Icons\\INV_Chest_Plate16", set = name }
                end
                for key in pairs(GM.settings.hiddenMenuItems or {}) do
                    local id = tonumber(type(key) == "string" and key:match("^(%d+)") or key)
                    if id then
                        local name, _, q, _, _, _, _, _, equipSlot, tex = GetItemInfo(id)
                        local ench = (type(key) == "string" and tonumber(key:match("^%d+:(%d+)"))) or 0
                        local tag = (type(key) == "number") and RCL["every copy"]
                            or ((ench > 0) and RCL["enchanted"] or RCL["no enchant"])
                        local where = equipSlot and _G[equipSlot] or ""
                        list[#list + 1] = { label = (name or ("item " .. id)) .. " (" .. tag .. ")", where = where,
                            icon = tex, quality = q, key = key }
                    end
                end
                table_sort(list, function(a, b) return a.label < b.label end)
                if #list == 0 then
                    local none = self:CreateFontString(hideCard, "OVERLAY", nil, 10)
                    none:SetPoint("TOPLEFT", hideCard, "TOPLEFT", 14, cardY)
                    none:SetText(RCL["Nothing is hidden."])
                    Gray(none)
                    cardY = cardY - 22
                end
                for _, r in ipairs(list) do
                    local ic = hideCard:CreateTexture(nil, "ARTWORK")
                    ic:SetSize(20, 20)
                    ic:SetPoint("TOPLEFT", hideCard, "TOPLEFT", 14, cardY)
                    ic:SetTexture(r.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                    ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                    local nm = self:CreateFontString(hideCard, "OVERLAY", nil, 11)
                    nm:SetPoint("LEFT", ic, "RIGHT", 8, 0)
                    nm:SetPoint("RIGHT", hideCard, "RIGHT", -110, 0)
                    nm:SetJustifyH("LEFT")
                    nm:SetWordWrap(false)
                    nm:SetText(r.label .. ((r.where ~= "") and ("  |cFF808080" .. r.where .. "|r") or ""))
                    local qc = r.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[r.quality]
                    local c = qc or self:GetColor("text", "normal")
                    nm:SetTextColor(c.r, c.g, c.b, 1)
                    local show = self.UI:CreateStyledButton(hideCard, RCL["Show"], 70, 20)
                    show:SetPoint("TOPRIGHT", hideCard, "TOPRIGHT", -14, cardY)
                    show:SetScript("OnClick", function()
                        if r.set then GM:SetMenuSetHidden(r.set, false) else GM:SetMenuItemHidden(r.key, false) end
                        Redraw()
                    end)
                    cardY = cardY - 26
                end
                cardY = cardY - 10
            end

            -- Browse one menu at a time: every entry it can show, with a
            -- Hidden box. Hidden items no longer carried still list so
            -- they can be brought back.
            local viewLbl = self:CreateFontString(hideCard, "OVERLAY", nil, 10)
            viewLbl:SetPoint("TOPLEFT", hideCard, "TOPLEFT", 14, cardY)
            viewLbl:SetText(RCL["Menu"])
            Gray(viewLbl)
            cardY = cardY - 18
            RC.gmHideView = RC.gmHideView or 999
            local viewItems = { { text = RCL["Gear Sets"], value = 999 } }
            for sl = 0, 19 do
                local info = GM.slotInfo[sl]
                if info then viewItems[#viewItems + 1] = { text = info.real, value = sl } end
            end
            local viewName = (RC.gmHideView == 999) and RCL["Gear Sets"]
                or (GM.slotInfo[RC.gmHideView] and GM.slotInfo[RC.gmHideView].real) or RCL["Gear Sets"]
            local viewDD = self.UI:CreateScrollableDropdown(hideCard, 180, viewName, 10)
            viewDD:SetPoint("TOPLEFT", hideCard, "TOPLEFT", 14, cardY)
            viewDD:SetItems(viewItems, function(value)
                RC.gmHideView = value
                Redraw()
            end)
            if viewDD.SetSearchEnabled then viewDD:SetSearchEnabled(false) end

            local unhideAll = self.UI:CreateStyledButton(hideCard, RCL["Show everything again"], 170, 22)
            unhideAll:SetPoint("TOPLEFT", hideCard, "TOPLEFT", 210, cardY)
            unhideAll:SetScript("OnClick", function()
                GM.settings.hiddenMenuItems = {}
                GM.settings.hiddenMenuSets = {}
                GM:SaveSettings()
                Redraw()
            end)
            cardY = cardY - 34

            local rows = {}
            if RC.gmHideView == 999 then
                for _, n in ipairs(GM:GetSetNames()) do
                    local set = GM.sets[n]
                    rows[#rows + 1] = { label = n, icon = (set and set.icon) or "Interface\\Icons\\INV_Chest_Plate16",
                        hidden = GM:IsMenuSetHidden(n), set = n }
                end
            else
                -- One row per copy the game can tell apart: item, enchant
                -- and random suffix (GM:MenuItemKey). When an item shows up
                -- in more than one form, each row says which.
                local seen, perItem = {}, {}
                local savedAnchor = GM.currentMenuAnchor
                GM.currentMenuAnchor = nil
                local ok, list = pcall(GM.GetItemsForSlot, GM, RC.gmHideView)
                GM.currentMenuAnchor = savedAnchor
                for _, it in ipairs(ok and list or {}) do
                    local key, id = GM:MenuItemKey(it.itemLink)
                    if key and not seen[key] then
                        seen[key] = true
                        perItem[id] = (perItem[id] or 0) + 1
                        local ench = tonumber(key:match("^%d+:(%d+)")) or 0
                        rows[#rows + 1] = { label = GetItemInfo(it.itemLink) or it.name or ("item " .. id),
                            icon = it.texture, quality = it.quality, hidden = GM:IsMenuItemHidden(it.itemLink),
                            key = key, id = id, ench = ench }
                    end
                end
                for key in pairs(GM.settings.hiddenMenuItems or {}) do
                    local id = tonumber(type(key) == "string" and key:match("^(%d+)") or key)
                    if id and not seen[key] then
                        local name, _, q, _, _, _, _, _, equipSlot, tex = GetItemInfo(id)
                        if name and GM:CanItemGoInSlot(equipSlot, RC.gmHideView) then
                            seen[key] = true
                            local ench = (type(key) == "string" and tonumber(key:match("^%d+:(%d+)"))) or 0
                            rows[#rows + 1] = { label = name, note = RCL["not in bags"], icon = tex,
                                quality = q, hidden = true, key = key, id = id, ench = ench,
                                allCopies = type(key) == "number" }
                            perItem[id] = (perItem[id] or 0) + 1
                        end
                    end
                end
                for _, r in ipairs(rows) do
                    local bits = {}
                    if r.allCopies then
                        bits[#bits + 1] = RCL["every copy"]
                    elseif perItem[r.id] and perItem[r.id] > 1 then
                        bits[#bits + 1] = (r.ench > 0) and RCL["enchanted"] or RCL["no enchant"]
                    end
                    if r.note then bits[#bits + 1] = r.note end
                    if #bits > 0 then r.label = r.label .. " (" .. table.concat(bits, ", ") .. ")" end
                end
            end

            if #rows == 0 then
                local none = self:CreateFontString(hideCard, "OVERLAY", nil, 10)
                none:SetPoint("TOPLEFT", hideCard, "TOPLEFT", 14, cardY)
                none:SetText(RC.gmHideView == 999 and RCL["No gear sets yet."] or RCL["Nothing you carry fits this slot."])
                Gray(none)
                cardY = cardY - 22
            end
            for _, r in ipairs(rows) do
                local ic = hideCard:CreateTexture(nil, "ARTWORK")
                ic:SetSize(20, 20)
                ic:SetPoint("TOPLEFT", hideCard, "TOPLEFT", 14, cardY)
                ic:SetTexture(r.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                if r.hidden then ic:SetDesaturated(true) end

                local nm = self:CreateFontString(hideCard, "OVERLAY", nil, 11)
                nm:SetPoint("LEFT", ic, "RIGHT", 8, 0)
                nm:SetPoint("RIGHT", hideCard, "RIGHT", -110, 0)
                nm:SetJustifyH("LEFT")
                nm:SetWordWrap(false)
                nm:SetText(r.label)
                local qc = r.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[r.quality]
                if qc then
                    nm:SetTextColor(qc.r, qc.g, qc.b, r.hidden and 0.55 or 1)
                else
                    local c = self:GetColor("text", "normal")
                    nm:SetTextColor(c.r, c.g, c.b, r.hidden and 0.55 or 1)
                end

                local cb = self.UI:CreateCheckbox(hideCard, RCL["Hidden"], r.hidden)
                cb:SetPoint("TOPRIGHT", hideCard, "TOPRIGHT", -80, cardY - 1)
                cb:SetScript("OnClick", function(b)
                    local on = b:GetChecked() and true or false
                    RC:ForceCheckboxUpdate(b, on)
                    if r.set then GM:SetMenuSetHidden(r.set, on) else GM:SetMenuItemHidden(r.key, on) end
                    Redraw()
                end)
                cardY = cardY - 26
            end
            cardY = cardY - 6

            hideCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - hideCard:GetHeight() - 15
        end

        local macroCard = self:CreateSettingsCard(parent, yPos, RCL["Macros & keybinds"])
        cardY = -30

        cardY = RC.UI:CreateHelpLine(macroCard, 14, cardY, RCL["Click inside the box below to select all commands, then Ctrl+C to copy. Paste any line into a /macro, drag the macro to your action bar, and bind the slot to a key. Works in combat - the swap queues and applies the moment combat ends."],
            { short = RCL["Click the box to select every command, Ctrl+C to copy, then paste a line into a macro."], title = RCL["Macro commands"], gap = 10 })

        local successCol = self:GetColor("status", "success")
        local elBG       = self:GetColor("ui", "elementBackground")
        local bNorm      = self:GetColor("ui", "borderNormal")
        local accentCol  = self:GetColor("ui", "accentGold") or {r=0.85,g=0.65,b=0.25}

        local macroLines = {
            "/rc gearset Execute",
            "/rc gearset Battle Shout",
            "",
            "-- Equip or queue ANY item to a slot (13/14 = trinkets):",
            "/rc equip(Kiss of the Spider,13)",
            "/rc equip(Onyxia Blood Talisman,14)",
        }
        local yourSets = RC:GetAllGearSets()
        if yourSets and #yourSets > 0 then
            table.insert(macroLines, "")
            table.insert(macroLines, "-- Your saved sets:")
            for _, s in ipairs(yourSets) do
                table.insert(macroLines, "/rc gearset " .. s.name)
            end
        end
        local macroText = table.concat(macroLines, "\n")

        local macroBox = self.UI:CreateStyledEditBox(macroCard, {
            multiLine    = true,
            scrollable   = true,
            scrollHeight = 120,
            readOnly     = true,
            initialText  = macroText,
            textColor    = successCol,
            font         = 11,
        })
        macroBox:SetPoint("TOPLEFT",  macroCard, "TOPLEFT",  14, cardY)
        macroBox:SetPoint("RIGHT",    macroCard, "RIGHT",   -14,  0)

        cardY = cardY - macroBox:GetHeight() - 8

        macroCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - macroCard:GetHeight() - 15

        elseif RC.gearManagerTab == "sets" then
        local createCard = self:CreateSettingsCard(parent, yPos, RCL["Create new set"])
        cardY = -32

        local nameLabel = self:CreateFontString(createCard, "OVERLAY", nil, 11)
        nameLabel:SetPoint("TOPLEFT", createCard, "TOPLEFT", 14, cardY)
        nameLabel:SetText(RCL["Name:"])
        nameLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

        local setNameContainer = self.UI:CreateStyledEditBox(createCard, {
            width       = 150,
            height      = 22,
            maxLetters  = 50,
        })
        setNameContainer:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
        local setNameEditBox = setNameContainer.editBox

        local selectedIcon = 134400
        local iconLabel = self:CreateFontString(createCard, "OVERLAY", nil, 11)
        iconLabel:SetPoint("LEFT", setNameContainer, "RIGHT", 15, 0)
        iconLabel:SetText(RCL["Icon:"])
        iconLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

        local iconButton = CreateFrame("Frame", nil, createCard)
        iconButton:SetPoint("LEFT", iconLabel, "RIGHT", 8, 0)
        iconButton:SetSize(24, 24)
        iconButton:EnableMouse(true)

        local iconBg = iconButton:CreateTexture(nil, "BACKGROUND")
        iconBg:SetAllPoints()
        iconBg:SetColorTexture(C.blackHalf[1], C.blackHalf[2], C.blackHalf[3], C.blackHalf[4])

        local iconTexture = iconButton:CreateTexture(nil, "ARTWORK")
        iconTexture:SetAllPoints()
        iconTexture:SetTexture(selectedIcon)
        iconTexture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        iconButton.texture = iconTexture

        iconButton:SetScript("OnMouseUp", function(self)
            if GM.ShowIconPickerGrid then
                GM:ShowIconPickerGrid(function(iconID)
                    selectedIcon = iconID
                    iconTexture:SetTexture(iconID)
                end, selectedIcon, self, "RIGHT")
            end
        end)
        cardY = cardY - 30

        local createEmptyBtn = self.UI:CreateStyledButton(createCard, RCL["Create Empty"], 100, 26)
        createEmptyBtn:SetPoint("TOPLEFT", createCard, "TOPLEFT", 14, cardY)
        createEmptyBtn:SetScript("OnClick", function()
            local setName = setNameEditBox:GetText()
            if setName and setName ~= "" then
                if GM.sets[setName] then
                    return
                end
                GM.sets[setName] = { equip = {}, textures = {}, icon = selectedIcon }
                if not RC.db.gearSets then RC.db.gearSets = {} end
                RC.db.gearSets[setName] = GM.sets[setName]
                RC:SaveConfigurationToProfile()
                setNameEditBox:SetText("")
                RC:ShowSidebarGearManagerConfig(frame)
            end
        end)

        local createCurrentBtn = self.UI:CreateStyledButton(createCard, RCL["From Current Gear"], 130, 26)
        createCurrentBtn:SetPoint("LEFT", createEmptyBtn, "RIGHT", 8, 0)
        createCurrentBtn:SetScript("OnClick", function()
            local setName = setNameEditBox:GetText()
            if setName and setName ~= "" then
                if GM.sets[setName] then
                    return
                end
                local newSet = { equip = {}, textures = {}, icon = selectedIcon }
                for i = 0, 19 do
                    local itemLink = GetInventoryItemLink("player", i)
                    if itemLink then
                        newSet.equip[i] = itemLink
                        local texture = GetInventoryItemTexture("player", i)
                        if texture then newSet.textures[i] = texture end
                    end
                end
                GM.sets[setName] = newSet
                if not RC.db.gearSets then RC.db.gearSets = {} end
                RC.db.gearSets[setName] = newSet
                RC:SaveConfigurationToProfile()
                setNameEditBox:SetText("")
                RC:ShowSidebarGearManagerConfig(frame)
            end
        end)
        cardY = cardY - 35

        local irLoaded = (_G.ItemRackUser and type(_G.ItemRackUser.Sets) == "table") and true or false
        if not irLoaded then
            local isLoadedFn = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
            irLoaded = (isLoadedFn and isLoadedFn("ItemRack")) and true or false
        end
        if irLoaded then
        local irBtn = self.UI:CreateStyledButton(createCard, RCL["Import ItemRack Gear Sets"], 220, 24)
        irBtn:SetPoint("TOPLEFT", createCard, "TOPLEFT", 14, cardY)
        irBtn:SetScript("OnClick", function()
            if GM.ImportItemRackSets then
                GM:ImportItemRackSets()
                RC:ShowSidebarGearManagerConfig(frame, true)
            end
        end)
        irBtn:HookScript("OnEnter", function(btnSelf)
            GameTooltip:SetOwner(btnSelf, "ANCHOR_RIGHT")
            GameTooltip:SetText(RCL["Import ItemRack Gear Sets"], 1, 1, 1)
            GameTooltip:AddLine(RCL["Copies this character's ItemRack sets into Readycheck as native sets - same slots, same unequip behavior, partial sets stay partial. ItemRack must be enabled during the import; afterwards it can be turned off."], 0.7, 0.7, 0.7, true)
            GameTooltip:AddLine(RCL["Existing Readycheck sets are never overwritten - a taken name imports with an (ItemRack) suffix."], 0.7, 0.7, 0.7, true)
            GameTooltip:Show()
        end)
        irBtn:HookScript("OnLeave", function() GameTooltip:Hide() end)
        cardY = cardY - 34
        end

        createCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - createCard:GetHeight() - 15

        local setsCard = self:CreateSettingsCard(parent, yPos, RCL["Saved gear sets"])
        cardY = -32

        local setCount = 0
        for name in pairs(GM.sets) do
            if not string.match(name, "^~") then setCount = setCount + 1 end
        end

        if setCount > 0 then
            local setNames = {}
            for name in pairs(GM.sets) do
                if not string.match(name, "^~") then table.insert(setNames, name) end
            end
            table.sort(setNames)

            local cardBg = GetCardBg()

            frame._expandedSets = frame._expandedSets or {}

            frame._expandedSetFrames = {}

            for _, setName in ipairs(setNames) do
                local setData = GM.sets[setName]
                local setFrame = CreateFrame("Button", nil, setsCard, "BackdropTemplate")
                setFrame:SetHeight(32)
                setFrame:SetPoint("TOPLEFT", setsCard, "TOPLEFT", 14, cardY)
                setFrame:SetPoint("RIGHT", setsCard, "RIGHT", -14, 0)
                setFrame:SetBackdrop({
                    bgFile = RC.UI.FLAT,
                    edgeFile = "Interface\\Buttons\\WHITE8X8",
                    edgeSize = 1,
                })
                setFrame:SetBackdropColor(cardBg.r, cardBg.g, cardBg.b, 1)
                do local _bn = RC:GetColor("ui", "borderNormal"); setFrame:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
                setFrame:RegisterForClicks("LeftButtonUp")

                local rowPreviewPath = GetGearSetPreviewPath(setName)
                if rowPreviewPath then
                    setFrame:SetScript("OnEnter", function(self)
                        if not RC._gearPreviewPopup then
                            -- Same shell as every Readycheck window: flat
                            -- ui.windowBackground fill, 1px black ring, 30px
                            -- flat title bar with the set name in gold, a gold
                            -- rule and a chromeless X; the 200px preview sits
                            -- under it inside its own 1px ring.
                            local FLAT = RC.UI.FLAT
                            local winBg = RC:GetColor("ui", "windowBackground")
                            local hdrBg = RC:GetColor("ui", "headerBackground")
                            local hdrTx = RC:GetColor("ui", "headerText")
                            local gold  = RC:GetColor("ui", "accentGold")
                            local p = CreateFrame("Frame", "WRGearPreviewPopup", UIParent)
                            p:SetSize(216, 30 + 8 + 200 + 8)
                            p:SetFrameStrata("TOOLTIP")
                            p.bg = p:CreateTexture(nil, "BACKGROUND")
                            p.bg:SetAllPoints()
                            p.bg:SetTexture(FLAT)
                            p.bg:SetVertexColor(winBg.r, winBg.g, winBg.b, 0.97)
                            p.border = RC.UI:CreateSimpleBorder(p)

                            local titleBar = CreateFrame("Frame", nil, p)
                            titleBar:SetHeight(30)
                            titleBar:SetPoint("TOPLEFT", p, "TOPLEFT", 1, -1)
                            titleBar:SetPoint("TOPRIGHT", p, "TOPRIGHT", -1, -1)
                            titleBar.bg = titleBar:CreateTexture(nil, "BACKGROUND")
                            titleBar.bg:SetAllPoints()
                            titleBar.bg:SetTexture(FLAT)
                            titleBar.bg:SetVertexColor(hdrBg.r, hdrBg.g, hdrBg.b, hdrBg.a or 1)
                            local rule = titleBar:CreateTexture(nil, "ARTWORK")
                            rule:SetPoint("BOTTOMLEFT", titleBar, "BOTTOMLEFT", 0, 0)
                            rule:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
                            rule:SetHeight(1)
                            rule:SetTexture(FLAT)
                            rule:SetVertexColor(gold.r, gold.g, gold.b, 0.6)
                            if RC.UI.ApplyHeaderArt then
                                rule:Hide()
                                RC.UI:ApplyHeaderArt(titleBar, { stepX = 140 })
                            end
                            p.titleText = RC:CreateFontString(titleBar, "OVERLAY", nil, 15, "")
                            p.titleText:SetPoint("LEFT", titleBar, "LEFT", 10, 0)
                            p.titleText:SetPoint("RIGHT", titleBar, "RIGHT", -30, 0)
                            p.titleText:SetJustifyH("LEFT")
                            p.titleText:SetTextColor(hdrTx.r, hdrTx.g, hdrTx.b, 1)
                            p.closeBtn = RC.UI:CreateXCloseButton(titleBar, 22, function() p:Hide() end)
                            p.closeBtn:SetPoint("RIGHT", titleBar, "RIGHT", -5, 0)

                            local imgHost = CreateFrame("Frame", nil, p)
                            imgHost:SetSize(200, 200)
                            imgHost:SetPoint("TOP", titleBar, "BOTTOM", 0, -8)
                            p.tex = imgHost:CreateTexture(nil, "ARTWORK")
                            p.tex:SetAllPoints()
                            imgHost.border = RC.UI:CreateSimpleBorder(imgHost)
                            p:Hide()
                            RC._gearPreviewPopup = p
                        end
                        local p = RC._gearPreviewPopup
                        p.tex:SetTexture(rowPreviewPath)
                        p.titleText:SetText(RC:GetGearSetIconText(setName, 16) .. " " .. setName)
                        p:ClearAllPoints()
                        p:SetPoint("LEFT", self, "RIGHT", 8, 0)
                        if not p:IsShown() then
                            RC.UI:PopIn(p, 0.12)
                        end
                    end)
                    setFrame:SetScript("OnLeave", function()
                        local p = RC._gearPreviewPopup
                        if p then
                            RC.UI:StopAnimations(p)
                            p:Hide()
                            p:SetAlpha(1)
                            p:SetScale(1)
                        end
                    end)
                end

                local iconHolder = CreateFrame("Frame", nil, setFrame)
                iconHolder:SetSize(24, 24)
                iconHolder:SetPoint("LEFT", setFrame, "LEFT", 5, 0)
                iconHolder:EnableMouse(false)
                local icon = iconHolder:CreateTexture(nil, "ARTWORK")
                icon:SetAllPoints()
                icon:SetTexture(RC:GetGearSetIcon(setName) or setData.icon or 134400)
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                local function MakeRowIconBorder(point1, point2, h, w)
                    local t = iconHolder:CreateTexture(nil, "OVERLAY")
                    t:SetColorTexture(0, 0, 0, 1)
                    t:SetPoint(point1, 0, 0)
                    t:SetPoint(point2, 0, 0)
                    if h then t:SetHeight(h) end
                    if w then t:SetWidth(w) end
                end
                MakeRowIconBorder("TOPLEFT",    "TOPRIGHT",    1, nil)
                MakeRowIconBorder("BOTTOMLEFT", "BOTTOMRIGHT", 1, nil)
                MakeRowIconBorder("TOPLEFT",    "BOTTOMLEFT",  nil, 1)
                MakeRowIconBorder("TOPRIGHT",   "BOTTOMRIGHT", nil, 1)

                local deleteBtn = self:CreateXCloseButton(setFrame, 24, function()
                    local MS = RC.MeshSync
                    local meshActive = MS and MS:IsEnabled() and MS:GetConfig()
                                    and MS:GetConfig().members
                                    and #MS:GetConfig().members > 0

                    local function doLocalDelete()
                        if GM.DeleteSet then GM:DeleteSet(setName) end
                        if frame._expandedSets then
                            frame._expandedSets[setName] = nil
                        end
                        if GM.editorStates then
                            GM.editorStates[setName] = nil
                        end
                        RC:ShowSidebarGearManagerConfig(frame, true)
                    end

                    RC.UI:CreateConfirmDialog(
                        RCL["Delete Gear Set"],
                        RCL["Delete gear set '"] .. setName .. RCL["' from this character?\n\nThis cannot be undone."],
                        function()
                            doLocalDelete()
                        end,
                        nil, RCL["Delete"], true,
                        { icon = RC:GetGearSetIcon(setName) }
                    )
                end)
                deleteBtn:SetPoint("RIGHT", setFrame, "RIGHT", -5, 0)

                local isExpanded = (frame._expandedSets[setName] == true)
                local capturedSetName = setName
                setFrame:SetScript("OnClick", function()
                    RC:CycleInlineExpansion(
                        function()
                            return frame._expandedSetFrames
                                and frame._expandedSetFrames[capturedSetName]
                        end,
                        function()
                            local wasExpanded = frame._expandedSets[capturedSetName] == true
                            if wasExpanded then
                                frame._expandedSets[capturedSetName] = nil
                            else
                                frame._expandedSets[capturedSetName] = true
                                frame._pendingFadeInGearSet = capturedSetName
                            end
                            RC:ShowSidebarGearManagerConfig(frame, true)
                        end
                    )
                end)

                local setLabel = self:CreateFontString(setFrame, "OVERLAY", nil, 11)
                setLabel:SetPoint("LEFT", iconHolder, "RIGHT", 8, 0)
                setLabel:SetPoint("RIGHT", deleteBtn, "LEFT", -10, 0)
                setLabel:SetJustifyH("LEFT")
                setLabel:SetText(setName)
                setLabel:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])

                cardY = cardY - 36

                if isExpanded then
                    local startY = cardY - 6

                    local inlineSub = CreateFrame("Frame", nil, setsCard)
                    inlineSub:SetPoint("TOPLEFT", setsCard, "TOPLEFT", 0, startY)
                    inlineSub:SetWidth(setsCard:GetWidth() > 0 and setsCard:GetWidth() or 400)
                    inlineSub:SetHeight(1)
                    inlineSub:SetAlpha(1)
                    frame._expandedSetFrames[setName] = inlineSub

                    local newY = RC:BuildGearSetEditorBody(inlineSub, 0, setName, setData, frame, {
                        onSave = function()
                            if frame._expandedSets then frame._expandedSets[setName] = nil end
                            RC:ShowSidebarGearManagerConfig(frame, true)
                        end,
                        onCancel = function()
                            if frame._expandedSets then frame._expandedSets[setName] = nil end
                            RC:ShowSidebarGearManagerConfig(frame, true)
                        end,
                        onRefresh = function()
                            RC:ShowSidebarGearManagerConfig(frame, true)
                        end,
                    })
                    cardY = startY + newY - 8

                    if frame._pendingFadeInGearSet == setName then
                        RC:FadeInInlineBody(inlineSub)
                        frame._pendingFadeInGearSet = nil
                    else
                        inlineSub:SetAlpha(1)
                    end
                end
            end
        else
            local noSetsText = self:CreateFontString(setsCard, "OVERLAY", nil, 10)
            noSetsText:SetPoint("TOPLEFT", setsCard, "TOPLEFT", 14, cardY)
            noSetsText:SetText(RCL["No gear sets saved yet. Create one above!"])
            noSetsText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 20
        end

        cardY = cardY - 5
        setsCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - setsCard:GetHeight() - 15
        end

        if RC.gearManagerTab == "remote" then
            local MS = RC.MeshSync
            local members   = MS and MS:GetMembers() or {}
            local rWarriors = (ReadycheckDB and ReadycheckDB.remoteWarriors) or {}
            local gearCache = (ReadycheckDB and ReadycheckDB.meshSyncGearCache) or {}
            local myCharKey = RC:GetCharacterKey()

            local selCard = self:CreateSettingsCard(parent, yPos, RCL["Remote warrior"])
            local sy = -30

            local function NormKey(name)
                if not name then return nil end
                if name:find("-", 1, true) then return name end
                local realm = (GetNormalizedRealmName and GetNormalizedRealmName())
                           or (GetRealmName() or ""):gsub("%s+","")
                return realm ~= "" and (name .. "-" .. realm) or name
            end

            local warriorItems = {}
            local charKeyMap   = {}
            local seenKeys     = {}

            local function addWarrior(ck, displayName, memberRef, isSameAccount)
                if not ck or seenKeys[ck] or ck == myCharKey then return end
                seenKeys[ck] = true
                local sfx = isSameAccount and "  [same account]" or "  [network]"
                warriorItems[#warriorItems+1] = { text = displayName..sfx, value = ck }
                charKeyMap[ck] = { charKey=ck, memberRef=memberRef,
                                   isSameAccount=isSameAccount, displayName=displayName }
            end

            if ReadycheckDB and ReadycheckDB.characters then
                for ck in pairs(ReadycheckDB.characters) do
                    if ck ~= myCharKey then
                        local cache = gearCache[ck]
                        local lvl   = cache and cache.level or nil
                        if lvl == nil or lvl >= 60 then
                            local charName = ck:match("^(.-)%-") or ck
                            addWarrior(ck, charName, nil, true)
                        end
                    end
                end
            end
            for _, m in ipairs(members) do
                addWarrior(NormKey(m.name), m.label or m.name, m, false)
            end
            for ck, r in pairs(rWarriors) do
                addWarrior(ck, r.label or ck, nil, false)
            end

            frame._remoteWarriorSel = frame._remoteWarriorSel or {}
            local sel = frame._remoteWarriorSel

            if sel.charKey and not charKeyMap[sel.charKey] then
                sel.charKey=nil; sel.label=nil; sel.memberRef=nil; sel.isSameAccount=nil
            end

            local selDispName = sel.charKey and charKeyMap[sel.charKey]
                             and charKeyMap[sel.charKey].displayName or "Select warrior..."
            local selDropW = math.max(180, (selCard:GetWidth() or 400) - 100)
            local selDrop  = self.UI:CreateScrollableDropdown(selCard, selDropW, selDispName, 8)
            selDrop:SetEmptyText(RCL["No other warriors found"], RCL["Mesh members and your other warriors show up here."])
            selDrop:SetPoint("TOPLEFT", selCard, "TOPLEFT", 14, sy)
            selDrop:SetItems(warriorItems, function(value)
                local info = charKeyMap[value]
                if not info then return end
                sel.charKey       = info.charKey
                sel.memberRef     = info.memberRef
                sel.isSameAccount = info.isSameAccount
                sel.label         = info.displayName
                frame._remoteExpandedSets      = {}
                frame._remoteExpandedSetFrames = {}
                RC:ShowSidebarGearManagerConfig(frame)
            end)
            sy = sy - 36

            local ghc = RC:GetColor("text","gray") or {r=0.5,g=0.5,b=0.5}
            if sel.charKey then
                local statusLbl = self:CreateFontString(selCard,"OVERLAY",nil,10)
                statusLbl:SetPoint("TOPLEFT",selCard,"TOPLEFT",14,sy)
                statusLbl:SetPoint("RIGHT",  selCard,"RIGHT",  -10,0)
                statusLbl:SetJustifyH("LEFT")
                statusLbl:SetTextColor(ghc.r,ghc.g,ghc.b)
                if sel.isSameAccount then
                    statusLbl:SetText(RCL["Same account - edits write directly to their saved data, no push needed."])
                else
                    local rw = rWarriors[sel.charKey]
                    if rw and (rw.lastReceived or 0) > 0 then
                        statusLbl:SetText(string.format(RCL["Network data, %d min ago."], math.floor((GetTime()-rw.lastReceived)/60)))
                    else
                        statusLbl:SetText(RCL["No data yet. Use Refresh when they are online."])
                    end
                end
                sy = sy - 18
            end

            local reqBtn = self.UI:CreateStyledButton(selCard, RCL["Refresh from Network"], 155, 24)
            reqBtn:SetPoint("TOPLEFT", selCard,"TOPLEFT",14,sy)
            if not sel.charKey or sel.isSameAccount then reqBtn:SetAlpha(0.4) end
            reqBtn:SetScript("OnClick", function()
                if sel.isSameAccount then return end
                if not MS or not MS:IsEnabled() then RC:Print(RCL["Mesh: Not enabled."]); return end
                if not sel.memberRef then RC:Print(RCL["Mesh: Warrior not in Mesh roster."]); return end
                if MS.Broadcast then MS:Broadcast("REQ_remoteGearData","",sel.charKey) end
                RC:Print(RCL["Mesh: Request sent to "]..(sel.label or sel.charKey)..".")
            end)
            local reqHint = self:CreateFontString(selCard,"OVERLAY",nil,10)
            reqHint:SetPoint("LEFT",reqBtn,"RIGHT",8,0)
            reqHint:SetPoint("RIGHT",selCard,"RIGHT",-10,0)
            reqHint:SetTextColor(ghc.r,ghc.g,ghc.b)
            reqHint:SetText(RCL["Same-account warriors always available."])
            sy = sy - 32

            selCard:SetContentHeight(math.abs(sy))
            yPos = yPos - selCard:GetHeight() - 10

            local selInfo = sel.charKey and charKeyMap[sel.charKey]
            if selInfo then
                local srcGearSets, srcAvailableItems, isSameAcct
                isSameAcct = selInfo.isSameAccount

                -- Same-account alts write straight into ReadycheckDB.characters
                -- (no push needed). Network warriors stage into rWarriors[ck]
                -- .localEdits/.pendingPush and require an explicit mesh push.
                if isSameAcct then
                    local charProfile = ReadycheckDB.characters
                                     and ReadycheckDB.characters[sel.charKey]
                    srcGearSets      = (charProfile and charProfile.gearSets) or {}
                    local cache = gearCache[sel.charKey]
                    srcAvailableItems = (cache and cache.availableItems) or {}
                    if not cache then
                        local noteCard = self:CreateSettingsCard(parent, yPos, "")
                        local ny = -20
                        local noteLbl = self:CreateFontString(noteCard,"OVERLAY",nil,10)
                        noteLbl:SetPoint("TOPLEFT",noteCard,"TOPLEFT",12,ny)
                        noteLbl:SetPoint("RIGHT",  noteCard,"RIGHT",  -12,0)
                        noteLbl:SetJustifyH("LEFT")
                        noteLbl:SetTextColor(ghc.r,ghc.g,ghc.b)
                        noteLbl:SetText(RCL["Item picker unavailable: log into "] .. (sel.label or sel.charKey) .. RCL[" once to populate their bag data. Gear set structure is still editable."])
                        ny = ny - noteLbl:GetStringHeight() - 8
                        noteCard:SetContentHeight(math.abs(ny))
                        yPos = yPos - noteCard:GetHeight() - 6
                    end
                else
                    local rw = rWarriors[sel.charKey]
                    if not rw then
                        local noDataCard = self:CreateSettingsCard(parent, yPos, "")
                        local ny = -25
                        local noLbl = self:CreateFontString(noDataCard,"OVERLAY",nil,10)
                        noLbl:SetPoint("TOPLEFT",noDataCard,"TOPLEFT",14,ny)
                        noLbl:SetTextColor(ghc.r,ghc.g,ghc.b)
                        noLbl:SetText(RCL["No data received yet. Click Refresh from Network while they are online."])
                        ny = ny - 20
                        noDataCard:SetContentHeight(math.abs(ny))
                        yPos = yPos - noDataCard:GetHeight() - 10
                        srcGearSets = nil
                    else
                        srcGearSets       = rw.gearSets or {}
                        srcAvailableItems = rw.availableItems or {}
                    end
                end

                if srcGearSets then
                    if not rWarriors[sel.charKey] then
                        ReadycheckDB.remoteWarriors = ReadycheckDB.remoteWarriors or {}
                        ReadycheckDB.remoteWarriors[sel.charKey] = { localEdits={}, pendingPush={} }
                        rWarriors = ReadycheckDB.remoteWarriors
                    end
                    local rwData = rWarriors[sel.charKey]
                    rwData.gearSets       = srcGearSets
                    rwData.availableItems = srcAvailableItems
                    rwData.label          = selInfo.displayName

                    GM.remoteItemsOverride = srcAvailableItems

                    local remoteEquippedBySlot = {}
                    for _, item in ipairs(srcAvailableItems or {}) do
                        if item.equipped and item.slot then
                            remoteEquippedBySlot[item.slot] = { link=item.link, texture=item.icon }
                        end
                    end
                    GM.remoteEquippedBySlot = remoteEquippedBySlot

                    local capCK       = sel.charKey
                    local capSameAcct = isSameAcct

                -- GM.remoteEditCallbacks[setName] (set below, once a set row is
                -- expanded) is the write path Equip_SetEditor.lua's
                -- SaveCurrentGearSetEditorState calls instead of touching
                -- GM.sets directly while a remote buffer is open.
                local createCard2 = self:CreateSettingsCard(parent, yPos, RCL["Create set for "] .. selInfo.displayName)
                local cc2y = -32

                local selectedIcon2 = 134400
                local iconLabel2 = self:CreateFontString(createCard2,"OVERLAY",nil,10)
                iconLabel2:SetPoint("TOPLEFT",createCard2,"TOPLEFT",14,cc2y)
                iconLabel2:SetText(RCL["Name:"])
                local nlc = RC:GetColor("text","normal") or {r=0.8,g=0.8,b=0.8}
                iconLabel2:SetTextColor(nlc.r,nlc.g,nlc.b)

                local nameBox2 = self.UI:CreateStyledEditBox(createCard2,
                    { width=180, height=22, placeholder=RCL["New set name..."] })
                local nameEB2 = nameBox2.editBox or nameBox2
                local nameBoxFrame2 = nameBox2.frame or nameBox2
                nameBoxFrame2:SetPoint("TOPLEFT",createCard2,"TOPLEFT",55,cc2y)
                cc2y = cc2y - 30

                local createEmptyBtn2 = self.UI:CreateStyledButton(createCard2,RCL["Create Empty"],110,26)
                createEmptyBtn2:SetPoint("TOPLEFT",createCard2,"TOPLEFT",14,cc2y)
                createEmptyBtn2:SetScript("OnClick", function()
                    local nm = nameEB2:GetText()
                    if not nm or nm == "" then return end
                    nm = nm:match("^%s*(.-)%s*$")
                    if nm == "" then return end
                    if capSameAcct then
                        if ReadycheckDB and ReadycheckDB.characters
                                and ReadycheckDB.characters[capCK] then
                            local charGS = ReadycheckDB.characters[capCK].gearSets or {}
                            ReadycheckDB.characters[capCK].gearSets = charGS
                            charGS[nm] = charGS[nm] or { equip={}, textures={}, icon=selectedIcon2 }
                        end
                    else
                        rwData.localEdits = rwData.localEdits or {}
                        if not rwData.localEdits[nm] then
                            rwData.localEdits[nm] = { equip={}, textures={}, icon=selectedIcon2 }
                            rwData.pendingPush = rwData.pendingPush or {}
                            local found2 = false
                            for _, pn in ipairs(rwData.pendingPush) do if pn==nm then found2=true; break end end
                            if not found2 then table_insert(rwData.pendingPush, nm) end
                        end
                    end
                    RC:ShowSidebarGearManagerConfig(frame, true)
                end)
                cc2y = cc2y - 32
                createCard2:SetContentHeight(math.abs(cc2y))
                yPos = yPos - createCard2:GetHeight() - 10

                local allSetNames = {}
                local seenSet = {}
                for sn in pairs(rwData.gearSets or {}) do
                    if not seenSet[sn] then seenSet[sn]=true; allSetNames[#allSetNames+1]=sn end
                end
                for sn in pairs(rwData.localEdits or {}) do
                    if not seenSet[sn] then seenSet[sn]=true; allSetNames[#allSetNames+1]=sn end
                end
                table_sort(allSetNames)

                local setsCard2 = self:CreateSettingsCard(parent, yPos,
                    selInfo.displayName .. RCL["'s gear sets"])
                local sc2y = -32

                if #allSetNames == 0 then
                    local emptyLbl = self:CreateFontString(setsCard2,"OVERLAY",nil,10)
                    emptyLbl:SetPoint("TOPLEFT",setsCard2,"TOPLEFT",14,sc2y)
                    emptyLbl:SetTextColor(ghc.r,ghc.g,ghc.b)
                    emptyLbl:SetText(RCL["No sets yet. Select this warrior to auto-load from account cache, or use Refresh from Network if they are online."])
                    sc2y = sc2y - 30
                else
                    frame._remoteExpandedSets      = frame._remoteExpandedSets or {}
                    frame._remoteExpandedSetFrames = frame._remoteExpandedSetFrames or {}

                    local cardBg2 = RC:GetColor("ui","cardBackground") or {r=0.1,g=0.1,b=0.1}

                    -- another character's set: its own saved icon when it
                    -- has a real one, else what that name shows as here
                    local function RemoteSetIcon(name, data)
                        local ic = data and data.icon
                        if ic == nil or ic == "" or ic == 134400
                           or (type(ic) == "string" and ic:lower():find("questionmark", 1, true)) then
                            return RC:GetGearSetIcon(name)
                        end
                        return ic
                    end

                    for _, setName in ipairs(allSetNames) do
                        local setData2 = (rwData.localEdits and rwData.localEdits[setName])
                                      or (rwData.gearSets and rwData.gearSets[setName])
                                      or { equip={}, textures={}, icon=134400 }

                        local isPending = false
                        for _, pn in ipairs(rwData.pendingPush or {}) do
                            if pn == setName then isPending = true; break end
                        end

                        local rowF = CreateFrame("Button", nil, setsCard2, "BackdropTemplate")
                        rowF:SetHeight(32)
                        rowF:SetPoint("TOPLEFT", setsCard2, "TOPLEFT", 14, sc2y)
                        rowF:SetPoint("RIGHT",   setsCard2, "RIGHT",  -14, 0)
                        rowF:SetBackdrop({ bgFile = RC.UI.FLAT,
                            edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
                        rowF:SetBackdropColor(cardBg2.r, cardBg2.g, cardBg2.b, 1)
                        do local _bn = RC:GetColor("ui", "borderNormal"); rowF:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
                        rowF:RegisterForClicks("LeftButtonUp")

                        local iconH2 = CreateFrame("Frame", nil, rowF)
                        iconH2:SetSize(24,24); iconH2:SetPoint("LEFT",rowF,"LEFT",5,0)
                        iconH2:EnableMouse(false)
                        local iconT2 = iconH2:CreateTexture(nil,"ARTWORK")
                        iconT2:SetAllPoints(); iconT2:SetTexture(setData2.icon or 134400)
                        iconT2:SetTexCoord(0.08,0.92,0.08,0.92)

                        local setLbl2 = self:CreateFontString(rowF,"OVERLAY",nil,11)
                        setLbl2:SetPoint("LEFT",iconH2,"RIGHT",8,0)
                        setLbl2:SetPoint("RIGHT",rowF,"RIGHT",-40,0)
                        setLbl2:SetJustifyH("LEFT")
                        local lblTxt = setName .. (isPending and " |cFFFFD700[unsent]|r" or "")
                        setLbl2:SetText(lblTxt)
                        local brightC = RC:GetColor("text","bright") or {r=1,g=1,b=1}
                        setLbl2:SetTextColor(brightC.r,brightC.g,brightC.b)

                        local delBtn2 = self.UI:CreateXCloseButton(rowF)
                        delBtn2:SetPoint("RIGHT",rowF,"RIGHT",-5,0)
                        local capSN2      = setName
                        local capRW       = rwData
                        local capDelSame  = isSameAcct
                        local capDelCK    = sel.charKey
                        delBtn2:SetScript("OnClick", function()
                            local MS = RC.MeshSync
                            local meshActive = MS and MS:IsEnabled() and MS:GetConfig()
                                            and MS:GetConfig().members
                                            and #MS:GetConfig().members > 0

                            local function doLocalRemove()
                                if capRW.gearSets   then capRW.gearSets[capSN2]   = nil end
                                if capRW.localEdits then capRW.localEdits[capSN2]  = nil end
                                if capRW.pendingPush then
                                    for i = #capRW.pendingPush, 1, -1 do
                                        if capRW.pendingPush[i] == capSN2 then
                                            table.remove(capRW.pendingPush, i)
                                        end
                                    end
                                end
                                if capDelSame and ReadycheckDB
                                        and ReadycheckDB.characters
                                        and ReadycheckDB.characters[capDelCK]
                                        and ReadycheckDB.characters[capDelCK].gearSets then
                                    ReadycheckDB.characters[capDelCK].gearSets[capSN2] = nil
                                end
                                if GM.remoteSetBuffers    then GM.remoteSetBuffers[capSN2]    = nil end
                                if GM.remoteEditCallbacks then GM.remoteEditCallbacks[capSN2] = nil end
                                if frame._remoteExpandedSets then frame._remoteExpandedSets[capSN2] = nil end
                                RC:ShowSidebarGearManagerConfig(frame, true)
                            end

                            -- Deleting a network warrior's set always removes it from
                            -- the local cache; "Delete" additionally queues a network
                            -- delete so it applies when they next log in.
                            if meshActive then
                                local warriorLabel = capRW.label or capDelCK
                                RC.UI:CreateConfirmDialog(
                                    RCL["Delete Gear Set"],
                                    RCL["Delete '"] .. capSN2 .. RCL["' from "] .. warriorLabel .. RCL["?\n\nThis will be queued and applied when they next log in.\n\n'Cache Only' removes it from your local view without touching their data."],
                                    function()
                                        doLocalRemove()
                                        if MS and MS.QueueNetworkGearDelete then
                                            MS:QueueNetworkGearDelete(capSN2, capDelCK)
                                        end
                                    end,
                                    function()
                                        doLocalRemove()
                                    end,
                                    RCL["Delete"],
                                    true,
                                    { icon = RemoteSetIcon(capSN2, setData2) }
                                )
                                local dlg = _G["WRConfirmDialog"]
                                if dlg and dlg.cancelBtn and dlg.cancelBtn.text then
                                    dlg.cancelBtn.text:SetText(RCL["Cache Only"])
                                end
                            else
                                RC.UI:CreateConfirmDialog(
                                    RCL["Delete Gear Set"],
                                    RCL["Remove '"] .. capSN2 .. RCL["' from the remote view?\n\nThis only removes it from your local cache."],
                                    function()
                                        doLocalRemove()
                                    end,
                                    nil, RCL["Remove"], true,
                                    { icon = RemoteSetIcon(capSN2, setData2) }
                                )
                            end
                        end)

                        local isExpanded2 = (frame._remoteExpandedSets[setName] == true)
                        local capSN3 = setName
                        rowF:SetScript("OnClick", function()
                            RC:CycleInlineExpansion(
                                function()
                                    return frame._remoteExpandedSetFrames
                                        and frame._remoteExpandedSetFrames[capSN3]
                                end,
                                function()
                                    if frame._remoteExpandedSets[capSN3] then
                                        frame._remoteExpandedSets[capSN3] = nil
                                        if GM.remoteSetBuffers    then GM.remoteSetBuffers[capSN3]    = nil end
                                        if GM.remoteEditCallbacks then GM.remoteEditCallbacks[capSN3] = nil end
                                    else
                                        frame._remoteExpandedSets[capSN3] = true
                                        frame._pendingFadeInGearSet = capSN3
                                    end
                                    RC:ShowSidebarGearManagerConfig(frame, true)
                                end
                            )
                        end)

                        sc2y = sc2y - 36

                        if isExpanded2 then
                            if not GM.remoteSetBuffers[setName] then
                                GM.remoteSetBuffers[setName] = RC.DeepCopy(setData2)
                            end
                            local buf = GM.remoteSetBuffers[setName]

                            local capCK2      = sel.charKey
                            local capRW2      = rwData
                            local capSameAcct2 = isSameAcct
                            GM.remoteEditCallbacks[setName] = function(sn, sd)
                                if capSameAcct2 then
                                    if ReadycheckDB and ReadycheckDB.characters
                                            and ReadycheckDB.characters[capCK2] then
                                        ReadycheckDB.characters[capCK2].gearSets =
                                            ReadycheckDB.characters[capCK2].gearSets or {}
                                        ReadycheckDB.characters[capCK2].gearSets[sn] = RC.DeepCopy(sd)
                                    end
                                    if capRW2.gearSets then capRW2.gearSets[sn] = sd end
                                else
                                    if MS then MS:SaveRemoteEdit(capCK2, sn, sd) end
                                    if capRW2.localEdits then
                                        capRW2.localEdits[sn] = capRW2.localEdits[sn] or {}
                                        if sd.icon then capRW2.localEdits[sn].icon = sd.icon end
                                    end
                                end
                            end

                            local startY2 = sc2y - 6
                            local inlineSub2 = CreateFrame("Frame", nil, setsCard2)
                            inlineSub2:SetPoint("TOPLEFT", setsCard2,"TOPLEFT", 0, startY2)
                            inlineSub2:SetWidth(setsCard2:GetWidth() > 0 and setsCard2:GetWidth() or 400)
                            inlineSub2:SetHeight(1)
                            inlineSub2:SetAlpha(1)
                            frame._remoteExpandedSetFrames[setName] = inlineSub2

                            local newY2 = RC:BuildGearSetEditorBody(inlineSub2, 0, setName, buf, frame, {
                                onSave   = function()
                                    frame._remoteExpandedSets[setName] = nil
                                    GM.remoteSetBuffers[setName]    = nil
                                    GM.remoteEditCallbacks[setName] = nil
                                    RC:ShowSidebarGearManagerConfig(frame, true)
                                end,
                                onCancel = function()
                                    frame._remoteExpandedSets[setName] = nil
                                    GM.remoteSetBuffers[setName]    = nil
                                    GM.remoteEditCallbacks[setName] = nil
                                    RC:ShowSidebarGearManagerConfig(frame, true)
                                end,
                                onRefresh = function()
                                    RC:ShowSidebarGearManagerConfig(frame, true)
                                end,
                            })
                            sc2y = startY2 + newY2 - 8

                            if frame._pendingFadeInGearSet == setName then
                                RC:FadeInInlineBody(inlineSub2)
                                frame._pendingFadeInGearSet = nil
                            else
                                inlineSub2:SetAlpha(1)
                            end
                        end
                    end
                end

                sc2y = sc2y - 6
                setsCard2:SetContentHeight(math.abs(sc2y))
                yPos = yPos - setsCard2:GetHeight() - 10

                end
            end
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end

