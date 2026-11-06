------------------------------------------------------------------------
-- Readycheck - Boss Ability & Gear Swap Page
-- Owns the per-boss config page: raidSettings.bosses[bossName or
-- bossName_phaseN] -> abilities{} (ability grid, trinkets/utility/
-- defensives handoff to Raids_AbilityPages.lua), plus boss gear swap
-- (encounterSettings.forceEquip), Loatheb's Fungal Bloom auto-swap,
-- Sapphiron's Polarity Mode suppression banner, per-horseman sub-config,
-- and the Kill History tab.
-- Remote edit: this file re-derives "am I looking at the remote profile"
-- inline (RC.remoteEditMode/RC._remoteEditData) instead of calling the
-- canonical RC:GetEditableActiveProfile/GetEditableRaidProfileStructure
-- helpers that Raids_BulkTrash.lua and Raids_AbilityPages.lua use - same
-- end result, just duplicated logic to keep in sync if the contract changes.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbr = RC._sbr or {}
local _sbr = RC._sbr
local GetConfiguredHover, GetTabHoverBg, GetTabNormalBg, GetTabSelectedBg, TEXT = _sbr.GetConfiguredHover, _sbr.GetTabHoverBg, _sbr.GetTabNormalBg, _sbr.GetTabSelectedBg, _sbr.TEXT
    -- Horizontal tile strip shared by every encounter page: a flat band
    -- (card fill, 1px border, 3px gold bar, small caption) holding 44x50
    -- icon tiles that wrap to a second row when the content width runs
    -- out. Tile look per the house spec: flat normal fill + 1px black
    -- border; configured = green fill + 6x6 green corner square; open =
    -- gold underline + element fill; hover = hover fill; dimmed tiles keep
    -- their fill at 70% with a desaturated icon.
    -- opts.tiles entries: { key, label, icon, enabled, open, dimmed,
    -- tooltip(btn), onClick() } or { divider = true }.
    local TILE_W, TILE_H, TILE_GAP, TILE_ICON, STRIP_PAD = 44, 50, 6, 30, 8
    -- The strip stretches with the window: tiles grow to fill the row
    -- up to TILE_MAX_W, and only shrink to TILE_MIN_W (then wrap) when
    -- the window is too narrow to hold them all.
    local TILE_MIN_W, TILE_MAX_W = 38, 72

    local function CreateStripTile(strip, px, py, t)
        local FLAT   = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
        local normBg = RC:GetColor("buttons", "normalBackground")
        local hovBg  = RC:GetColor("buttons", "hoverBackground")
        local cfgBg  = RC:GetColor("buttons", "configuredBackground")
        local openBg = RC:GetColor("ui", "elementBackground")
        local greenRing = RC:GetColor("ui", "borderSelected")
        local gold   = RC:GetColor("ui", "accentGold")
        local dimF   = t.dimmed and 0.7 or 1
        local isOn   = t.enabled and not t.dimmed

        local btn = CreateFrame("Button", nil, strip)
        btn:SetSize(TILE_W, TILE_H)
        btn.tileKey = t.key

        local fill = btn:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints()
        fill:SetTexture(FLAT)
        btn.border = RC.UI:CreateSimpleBorder(btn)

        local restBg = t.open and openBg or (isOn and cfgBg) or normBg
        local function Paint(hot)
            local c = hot and hovBg or restBg
            fill:SetVertexColor(c.r * dimF, c.g * dimF, c.b * dimF, 1)
        end
        Paint(false)

        if t.icon then
            local icon = btn:CreateTexture(nil, "ARTWORK")
            icon:SetSize(TILE_ICON, TILE_ICON)
            icon:SetPoint("TOP", btn, "TOP", 0, -2)
            icon:SetTexture(t.icon)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            icon:SetDesaturated(t.dimmed or not t.enabled)
            if t.dimmed then icon:SetAlpha(0.55) end
            btn.tileIcon = icon
        end

        local lbl = RC:CreateFontString(btn, "OVERLAY", nil, 9)
        lbl:SetPoint("TOP", btn, "TOP", 0, -(2 + TILE_ICON + 2))
        lbl:SetWidth(TILE_W - 2)
        lbl:SetJustifyH("CENTER")
        lbl:SetWordWrap(false)
        lbl:SetText(t.label or "")
        btn.tileLabel = lbl
        local lc
        if t.dimmed then
            lc = RC:GetColor("text", "disabled")
        elseif t.open then
            lc = RC:GetColor("text", "gold")
        elseif isOn then
            lc = RC:GetColor("text", "buttonActive")
        else
            lc = RC:GetColor("text", "gray")
        end
        lbl:SetTextColor(lc.r, lc.g, lc.b, 1)

        -- "Configured" is carried by the green fill and the green label,
        -- not by a marker: a corner square on every configured tile turned
        -- a page of tiles into a field of dots.
        if isOn and not t.open then
            RC.UI:UpdateBorderColor(btn.border, greenRing, 1)
        end
        if t.open then
            local ul = btn:CreateTexture(nil, "OVERLAY", nil, 1)
            ul:SetHeight(2)
            ul:SetPoint("BOTTOMLEFT",  btn, "BOTTOMLEFT",  1, 1)
            ul:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
            ul:SetColorTexture(gold.r, gold.g, gold.b, 1)
        end

        btn:SetScript("OnEnter", function(s)
            Paint(true)
            if t.tooltip then t.tooltip(s) end
        end)
        btn:SetScript("OnLeave", function()
            Paint(false)
            GameTooltip:Hide()
        end)
        btn:SetScript("OnClick", function()
            if t.onClick then t.onClick() end
        end)

        -- The strip re-lays out whenever the window is resized (see
        -- LayoutStrip), so a tile has to be able to take a new size rather
        -- than being frozen at the width it was born with.
        function btn:ApplyTileSize(w, iconSz)
            local h = iconSz + 20
            self:SetSize(w, h)
            if self.tileIcon then
                self.tileIcon:SetSize(iconSz, iconSz)
            end
            if self.tileLabel then
                self.tileLabel:ClearAllPoints()
                self.tileLabel:SetPoint("TOP", self, "TOP", 0, -(2 + iconSz + 2))
                self.tileLabel:SetWidth(w - 2)
            end
        end
        return btn
    end

    local function BuildTileStrip(parent, yPos, opts)
        opts = opts or {}
        local FLAT   = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
        local margin = opts.margin or 18
        local strip = CreateFrame("Frame", nil, parent)
        strip:SetPoint("TOPLEFT", parent, "TOPLEFT", margin, yPos)
        strip:SetPoint("RIGHT",   parent, "RIGHT",   -margin, 0)
        local stripW = (parent:GetWidth() or 0) - margin * 2
        if stripW <= 0 then stripW = opts.fallbackWidth or 460 end

        local cardBg = RC:GetColor("ui", "cardBackground")
        local bg = strip:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(FLAT)
        bg:SetVertexColor(cardBg.r, cardBg.g, cardBg.b, cardBg.a or 1)

        local bn = RC:GetColor("ui", "borderNormal")
        local borders = RC.UI:CreateSimpleBorder(strip)
        RC.UI:UpdateBorderColor(borders, { r = bn.r, g = bn.g, b = bn.b, a = 0.55 })

        local gold = RC:GetColor("ui", "accentGold")
        local bar = strip:CreateTexture(nil, "ARTWORK")
        bar:SetPoint("TOPLEFT",    strip, "TOPLEFT",    0, 0)
        bar:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", 0, 0)
        bar:SetWidth(3)
        bar:SetColorTexture(gold.r, gold.g, gold.b, 0.8)

        local tilesX0 = 3 + STRIP_PAD
        if opts.caption then
            local cap = RC:CreateFontString(strip, "OVERLAY", nil, 10)
            cap:SetPoint("TOPLEFT", strip, "TOPLEFT", tilesX0, -(STRIP_PAD + math.floor(TILE_H / 2) - 6))
            cap:SetText(opts.caption)
            local gc = RC:GetColor("text", "gray")
            cap:SetTextColor(gc.r, gc.g, gc.b, 1)
            local capW = cap:GetStringWidth() or 0
            if capW < 26 then capW = 26 end
            tilesX0 = tilesX0 + capW + 10
        end

        -- Build every element once, then lay them out. Layout runs again
        -- on every resize, so the tiles stretch with the window the same
        -- way the boss icons above them do instead of staying pinned to
        -- the width the page happened to be built at.
        strip.tiles = {}
        local elements = {}
        for _, t in ipairs(opts.tiles or {}) do
            if t.divider then
                local d = strip:CreateTexture(nil, "ARTWORK")
                d:SetSize(1, TILE_H)
                d:SetColorTexture(bn.r, bn.g, bn.b, 1)
                elements[#elements + 1] = { divider = true, obj = d }
            else
                local b = CreateStripTile(strip, 0, 0, t)
                if t.key then strip.tiles[t.key] = b end
                elements[#elements + 1] = { obj = b }
            end
        end

        local nTiles = 0
        for _, e in ipairs(elements) do
            if not e.divider then nTiles = nTiles + 1 end
        end

        local lastRows, lastW
        local function LayoutStrip(force)
            local w = strip:GetWidth() or 0
            if w <= 1 then w = stripW end
            if not force and lastW and math.abs(w - lastW) < 1 then return lastRows end
            lastW = w

            local avail = w - tilesX0 - STRIP_PAD
            if avail < TILE_W then avail = TILE_W end

            -- Widen the tiles to use the row rather than leaving a gutter,
            -- and only wrap when even the narrowest tile will not fit.
            local tileW, perRow = TILE_W, nTiles
            if nTiles > 0 then
                local fitAll = math.floor((avail + TILE_GAP) / (TILE_W + TILE_GAP))
                if fitAll >= nTiles then
                    perRow = nTiles
                    tileW = math.floor((avail - (nTiles - 1) * TILE_GAP) / nTiles)
                    if tileW > TILE_MAX_W then tileW = TILE_MAX_W end
                    if tileW < TILE_W then tileW = TILE_W end
                else
                    tileW = TILE_MIN_W
                    perRow = math.max(1, math.floor((avail + TILE_GAP) / (tileW + TILE_GAP)))
                    local used = perRow * tileW + (perRow - 1) * TILE_GAP
                    local slack = avail - used
                    if perRow > 0 and slack > 0 then
                        tileW = tileW + math.floor(slack / perRow)
                        if tileW > TILE_MAX_W then tileW = TILE_MAX_W end
                    end
                end
            end

            local iconSz = math.min(TILE_ICON, math.max(18, tileW - 12))
            local tileH  = iconSz + 20

            local col, row = 0, 0
            for _, e in ipairs(elements) do
                if e.divider then
                    -- A divider that lands at the start of a row separates
                    -- nothing, so it is skipped rather than drawn.
                    if col == 0 then
                        e.obj:Hide()
                    else
                        e.obj:Show()
                        e.obj:SetSize(1, tileH)
                        e.obj:ClearAllPoints()
                        e.obj:SetPoint("TOPLEFT", strip, "TOPLEFT",
                            tilesX0 + col * (tileW + TILE_GAP) - math.floor(TILE_GAP / 2) - 1,
                            -(STRIP_PAD + row * (tileH + TILE_GAP)))
                    end
                else
                    if col >= perRow then
                        col = 0
                        row = row + 1
                    end
                    e.obj:ApplyTileSize(tileW, iconSz)
                    e.obj:ClearAllPoints()
                    e.obj:SetPoint("TOPLEFT", strip, "TOPLEFT",
                        tilesX0 + col * (tileW + TILE_GAP),
                        -(STRIP_PAD + row * (tileH + TILE_GAP)))
                    col = col + 1
                end
            end

            local rows = row + 1
            strip:SetHeight(STRIP_PAD * 2 + rows * tileH + (rows - 1) * TILE_GAP)

            -- A change in row count moves everything below the strip, and
            -- the panel under it is placed at a fixed offset rather than
            -- anchored, so the page is rebuilt once when that happens.
            if lastRows and rows ~= lastRows and opts.onReflow then
                lastRows = rows
                opts.onReflow()
            else
                lastRows = rows
            end
            return rows
        end

        LayoutStrip(true)
        strip:SetScript("OnSizeChanged", function() LayoutStrip() end)
        C_Timer.After(0, function()
            if strip:IsShown() then LayoutStrip() end
        end)

        return strip:GetHeight(), strip
    end

    -- Public wrapper so other encounter pages (bulk trash, route) can draw
    -- the identical strip. Returns height used, strip frame.
    function RC:BuildAbilityTileStrip(parent, yPos, opts)
        return BuildTileStrip(parent, yPos, opts)
    end
    -- THE GEAR SET PICKER'S PREVIEW (boss Gear tab): the picker's own
    -- window (TE_GearSwap.lua, RC.NewGearSetPromptSample) laid out as this
    -- boss's kill would put it up - the sets it offers, the saved button
    -- size - and popping in as it does. No sets yet: made-up names, so the
    -- look still shows.
    local PROMPT_FAKE = { "Fire resist", "Nature resist", "Fury DPS", "Tank" }
    local PROMPT_MANY = { "Arcane resist", "Fire resist", "Frost resist", "Nature resist", "Shadow resist",
        "Fury DPS", "Fury DPS (Loatheb)", "Tank", "Off-tank", "Threat" }
    local function PromptSets(dp, many)
        local out = {}
        if many then
            for _, n in ipairs(PROMPT_MANY) do out[#out + 1] = { name = n } end
            return out
        end
        local sets = RC.GetGearPromptSets and RC:GetGearPromptSets(dp and dp.sets) or {}
        for _, e in ipairs(sets) do out[#out + 1] = e end
        if #out == 0 then
            for _, n in ipairs(PROMPT_FAKE) do out[#out + 1] = { name = n } end
        end
        return out
    end
    function RC:DeclareGearSetPromptPreview(encounterName, encounterSettings)
        if not (RC.NewGearSetPromptSample and RC.FillGearSetPromptSample) then return nil end
        return self.UI:DeclarePreview({
            key = "gear.setprompt", title = RCL["Gear set picker"], width = 200, height = 150,
            modes = { { id = "kill", label = RCL["After the kill"] }, { id = "many", label = RCL["Many sets"] } },
            modesLabel = RCL["Show"],
            build = function(canvas, P)
                P.store.f = RC.NewGearSetPromptSample(canvas)
                if P.store.f then P.store.f:SetPoint("CENTER", canvas, "CENTER", 0, 0) end
            end,
            update = function(canvas, P)
                local f = P.store.f
                if not f then return end
                local fe = encounterSettings and encounterSettings.forceEquip
                local dp = fe and fe.deathPrompt
                local w, h = RC.FillGearSetPromptSample(f, PromptSets(dp, P.mode == "many"),
                    (encounterName or RCL["Boss"]) .. RCL[" is down - pick a set"])
                if not RC.Motion.IsPlaying(f) then f:SetScale(1) end
                P.Resize((w or 192) + 8, (h or 120) + 8)
            end,
            -- the picker pops in as it does after a kill
            replay = function(canvas, P)
                local f = P.store.f
                if not (f and f:IsVisible()) then return end
                RC.Motion.Stop(f)
                f:Hide()
                if RC.UI.PopIn then RC.UI:PopIn(f, 0.15) else f:Show() end
            end,
        })
    end

    function RC:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings, preserveScroll)
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        -- Set after clearing: ClearSidebarContent resets it, and the strip's
        -- re-layout on resize (onReflow below) only runs while it matches.
        RC._lastPageFrame = frame

        -- Re-fetches raidSettings from the profile actually being edited
        -- (the remote toon's RC._remoteEditData while a remote session for
        -- THIS raid is open, otherwise this character's own profile) so a
        -- stale raidSettings reference passed in by a caller never wins.
        local freshRaidSettings = RC.GetEditableActiveProfile and RC:GetEditableActiveProfile(raidName)

        if freshRaidSettings then
            if raidSettings ~= freshRaidSettings then
                self:DebugPrint("ShowInlineAbilityConfig: Switching to fresh raidSettings", "config")
            end
            raidSettings = freshRaidSettings
        end
        if type(raidSettings) ~= "table" then return end
        raidSettings.bosses = raidSettings.bosses or {}
        raidSettings.trash  = raidSettings.trash  or {}
        -- What this page was built from, so a profile switched somewhere
        -- else (SetActiveRaidProfile) can tell the page is out of date.
        frame._pageRaid, frame._pageEncounter, frame._pageType = raidName, encounterName, encounterType
        frame._pageRaidSettings = raidSettings

        -- Contributor stamping records OUR race/class into OUR profile;
        -- must not fire while merely viewing/editing someone else's raid.
        do
            local _rem = RC.remoteEditMode
            local isRemote = _rem and raidName == _rem.raidKey and RC._remoteEditData
            if not isRemote and RC.StampRaidProfileContributor then
                self:StampRaidProfileContributor(raidName)
            end
        end

        local parent = frame.scrollChild
        local yPos = -20

        local encounterIcon = nil
        if encounterType == "boss" then
            encounterIcon = self.bossIcons and self.bossIcons[encounterName] or "Interface\\Icons\\Ability_Creature_Cursed_02"
        elseif encounterType == "trashsection" then
            local wsRaidIcons = {
                ["Molten Core"] = "Interface\\Icons\\Spell_Fire_Incinerate",
                ["Blackwing Lair"] = "Interface\\Icons\\INV_Misc_Head_Dragon_Black",
                ["Temple of Ahn'Qiraj"] = "Interface\\Icons\\INV_Misc_QirajiCrystal_05",
                ["Naxxramas"] = "Interface\\Icons\\Achievement_Boss_KelThuzad_01",
            }
            encounterIcon = wsRaidIcons[raidName] or "Interface\\Icons\\Ability_Creature_Cursed_02"
        elseif encounterType == "route" then
            encounterIcon = "Interface\\Icons\\INV_Misc_Map_01"
        end

        if encounterIcon then
            local iconTex = parent:CreateTexture(nil, "ARTWORK")
            iconTex:SetSize(20, 20)
            iconTex:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos - 2)
            iconTex:SetTexture(encounterIcon)

            local header = self:CreateFontString(parent, "OVERLAY", nil, 13)
            header:SetPoint("LEFT", iconTex, "RIGHT", 10, 0)
            header:SetText(encounterName)
            header:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
        else
            local header = self:CreateFontString(parent, "OVERLAY", nil, 13)
            header:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos - 8)
            header:SetText(encounterName)
            header:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
        end

        local navBossList, navLookupName, navCurIdx, JumpToBoss
        if encounterType == "boss" or encounterType == "trashsection" or encounterType == "route" then
            -- Nav-strip lookup only: the four horsemen share one slot in
            -- navBossList ("Four Horsemen"), but each has its own storage
            -- key under raidSettings.bosses (see the "Individual Horseman
            -- Config" card near the end of this function). This alias only
            -- redirects which strip icon highlights as current.
            navBossList = self.raidData and self.raidData[raidName] and self.raidData[raidName].bosses
            local HORSEMEN_ALIASES = {
                ["Highlord Mograine"] = true, ["Lady Blaumeux"] = true,
                ["Thane Korth'azz"]   = true, ["Sir Zeliek"]    = true,
            }
            navLookupName = nil
            if encounterType == "boss" then
                navLookupName = HORSEMEN_ALIASES[encounterName] and "Four Horsemen" or encounterName
            end
            if navBossList then
                for i, bn in ipairs(navBossList) do
                    if bn == navLookupName then
                        navCurIdx = i
                        break
                    end
                end
            end

            JumpToBoss = function(bossName)
                frame.configState = frame.configState or {}
                frame.configState.selectedEncounter = bossName
                frame.configState.selectedEncounterType = "boss"
                RC:ShowInlineAbilityConfig(frame, raidName, bossName, "boss", nil)
            end

            if encounterType == "boss" and navLookupName then
                frame._lastBossViewed = frame._lastBossViewed or {}
                frame._lastBossViewed[raidName] = navLookupName
            end
        end

        yPos = yPos - 26

        if (encounterType == "boss" or encounterType == "trashsection" or encounterType == "route") and navBossList and #navBossList > 0 then
            local _acGold = RC:GetColor("ui", "accentGold")

            -- The horsemen save under their own names and fold into
            -- "Four Horsemen" (RC:EncounterMenuName). A gear
            -- set, slot override or other non-reminder setup counts too
            -- (RC:EncounterHasConfig), not just the reminder flag.
            local configuredBoss = {}
            for key, cfg in pairs(raidSettings.bosses) do
                if RC:EncounterHasConfig(cfg) then
                    configuredBoss[RC:EncounterMenuName(key)] = true
                end
            end
            local function BossHasConfig(bn) return configuredBoss[bn] or false end

            local ICON_MAX, ICON_MIN, GAP = 32, 18, 4
            local CHIP_H     = 22
            local CHIP_ROW_Y = -(ICON_MAX + 6)
            local stripH = ICON_MAX + 6 + CHIP_H

            local strip = CreateFrame("Frame", nil, parent)
            strip:SetPoint("TOPLEFT",  parent, "TOPLEFT",  20, yPos)
            strip:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -10, yPos)
            strip:SetHeight(stripH)

            local iconButtons = {}
            for _, bn in ipairs(navBossList) do
                local ib = CreateFrame("Button", nil, strip)
                ib:SetSize(ICON_MAX, ICON_MAX)

                local tex = ib:CreateTexture(nil, "ARTWORK")
                tex:SetPoint("TOPLEFT", 2, -2)
                tex:SetPoint("BOTTOMRIGHT", -2, 2)
                tex:SetTexture((self.bossIcons and self.bossIcons[bn]) or "Interface\\Icons\\INV_Misc_QuestionMark")
                tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                -- Same tile look as the ability strip below: flat fill,
                -- 1px black border, gold underline on the current boss and
                -- a green corner square on bosses with something enabled.
                local isCurrent = (bn == navLookupName)
                local hasCfg = BossHasConfig(bn)
                local navFill = ib:CreateTexture(nil, "BACKGROUND")
                navFill:SetAllPoints()
                navFill:SetTexture((RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8")
                local _navNorm = RC:GetColor("buttons", "normalBackground")
                local _navHov  = RC:GetColor("buttons", "hoverBackground")
                local _navRest = isCurrent and RC:GetColor("ui", "elementBackground")
                    or (hasCfg and RC:GetColor("buttons", "configuredBackground"))
                    or _navNorm
                navFill:SetVertexColor(_navRest.r, _navRest.g, _navRest.b, 1)
                ib.border = self.UI:CreateSimpleBorder(ib)
                local restDesat = not (hasCfg or isCurrent)
                if restDesat then
                    if not tex:SetDesaturated(true) then
                        tex:SetVertexColor(0.45, 0.45, 0.45)
                    end
                else
                    tex:SetDesaturated(false)
                end
                tex:SetAlpha((hasCfg or isCurrent) and 1 or 0.55)
                -- Configured bosses read through the tile fill and a
                -- muted green ring; no corner marker (see CreateStripTile).
                -- The current boss wins the gold underline and keeps a
                -- black ring, so gold and green never share one icon.
                if hasCfg and not isCurrent and ib.border then
                    RC.UI:UpdateBorderColor(ib.border, RC:GetColor("ui", "borderSelected"), 1)
                end
                if isCurrent then
                    local ul = ib:CreateTexture(nil, "OVERLAY", nil, 1)
                    ul:SetHeight(2)
                    ul:SetPoint("BOTTOMLEFT",  ib, "BOTTOMLEFT",  1, 1)
                    ul:SetPoint("BOTTOMRIGHT", ib, "BOTTOMRIGHT", -1, 1)
                    ul:SetColorTexture(_acGold.r, _acGold.g, _acGold.b, 1)
                end

                ib:SetScript("OnEnter", function(sBtn)
                    navFill:SetVertexColor(_navHov.r, _navHov.g, _navHov.b, 1)
                    if restDesat then
                        tex:SetDesaturated(false)
                        tex:SetVertexColor(1, 1, 1)
                        tex:SetAlpha(0.9)
                    end
                    GameTooltip:SetOwner(sBtn, "ANCHOR_TOP")
                    GameTooltip:SetText(bn, 1, 1, 1)
                    if hasCfg then
                        GameTooltip:AddLine(RCL["Configured"], 0.4, 0.9, 0.4)
                    else
                        GameTooltip:AddLine(RCL["Not configured"], 0.6, 0.6, 0.6)
                    end
                    GameTooltip:Show()
                end)
                ib:SetScript("OnLeave", function()
                    navFill:SetVertexColor(_navRest.r, _navRest.g, _navRest.b, 1)
                    if restDesat then
                        if not tex:SetDesaturated(true) then
                            tex:SetVertexColor(0.45, 0.45, 0.45)
                        end
                        tex:SetAlpha(0.55)
                    end
                    GameTooltip:Hide()
                end)
                ib:SetScript("OnClick", function()
                    if not isCurrent then JumpToBoss(bn) end
                end)

                iconButtons[#iconButtons + 1] = ib
            end

            local function RelayoutStrip()
                local w = strip:GetWidth() or 0
                local n = #iconButtons
                if w <= 0 or n == 0 then return end
                local size = math.floor((w - (n - 1) * GAP) / n)
                if size > ICON_MAX then size = ICON_MAX end
                if size < ICON_MIN then size = ICON_MIN end
                for idx, ib in ipairs(iconButtons) do
                    ib:SetSize(size, size)
                    ib:ClearAllPoints()
                    if n == 1 then
                        ib:SetPoint("TOPLEFT", strip, "TOPLEFT", 0, 0)
                    else
                        local x = math.floor((w - size) * (idx - 1) / (n - 1) + 0.5)
                        ib:SetPoint("TOPLEFT", strip, "TOPLEFT", x, 0)
                    end
                end
            end
            strip:SetScript("OnSizeChanged", RelayoutStrip)
            RelayoutStrip()
            C_Timer.After(0, RelayoutStrip)

            local chipLeftX = 0
            local function ChipLeft(labelText, width, onClick)
                local b = self.UI:CreateStyledButton(strip, labelText, width, CHIP_H)
                if b.text then RC:ApplyCustomFont(b.text, 10) end
                -- the chip is as wide as its label needs (a styled button
                -- grows to fit, and the font may be bigger than the guess
                -- in width): the next one starts after the REAL width, or
                -- the chips run into each other (Zac 2026-11-02)
                local need = b.text and math.ceil((b.text:GetStringWidth() or 0) + 14) or width
                local w = math.max(width, need, b:GetWidth() or 0)
                b:SetWidth(w)
                b:SetPoint("TOPLEFT", strip, "TOPLEFT", chipLeftX, CHIP_ROW_Y)
                b:SetScript("OnClick", onClick)
                chipLeftX = chipLeftX + w + 4
                return b
            end

            do
                local rd = self.raidData and self.raidData[raidName]
                local sections = {}
                if rd and rd.trashSections then
                    for sn in pairs(rd.trashSections) do sections[#sections + 1] = sn end
                    table.sort(sections)
                end
                if #sections > 0 then
                    for i = 1, #sections do
                        local sn = sections[i]
                        local isActiveSection = (encounterType == "trashsection" and sn == encounterName)
                        local short = sn:gsub(" Quarter", ""):gsub(" Lair", "")
                        local chip = ChipLeft(short, math.max(40, 10 + #short * 5), function()
                            frame.bulkTrashState = frame.bulkTrashState or {}
                            frame.bulkTrashState.selectedQuarter = sn
                            RC:ShowInlineAbilityConfig(frame, raidName, sn, "trashsection", nil)
                        end)
                        if isActiveSection then
                            self.UI:UpdateBorderColor(chip.border, _acGold)
                            chip.text:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
                        end
                    end
                elseif rd and rd.trash then
                    local chip = ChipLeft("Trash", 48, function()
                        frame.bulkTrashState = frame.bulkTrashState or {}
                        frame.bulkTrashState.selectedQuarter = "Trash"
                        RC:ShowInlineAbilityConfig(frame, raidName, "Trash", "trashsection", nil)
                    end)
                    if encounterType == "trashsection" then
                        self.UI:UpdateBorderColor(chip.border, _acGold)
                        chip.text:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
                    end
                end

            end

            frame._chipStrip, frame._chipRowY = strip, CHIP_ROW_Y
            local routeChip = ChipLeft("Route", 44, function()
                frame.configState = frame.configState or {}
                frame.configState.selectedEncounter = "Route"
                frame.configState.selectedEncounterType = "route"
                RC:ShowInlineAbilityConfig(frame, raidName, "Route", "route", nil)
            end)
            frame._chipRowEndX = chipLeftX
            if encounterType == "route" then
                self.UI:UpdateBorderColor(routeChip.border, _acGold)
                routeChip.text:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
            end

            yPos = yPos - (stripH + 8)
        end

        -- Banner only, boss pages only: reminds the editor which toon's
        -- config is on screen. Trash/route pages show their own equivalent
        -- via ShowSidebarRemoteRaidConfig / RenderBulkTrashBody instead.
        do
            local _remBan = RC.remoteEditMode
            if encounterType == "boss" and _remBan and _remBan.raidKey == raidName and RC._remoteEditData then
                local who = (_remBan.member and (_remBan.member.label or _remBan.member.name)) or "?"
                local banCard = self:CreateSettingsCard(parent, yPos, RCL["Remote edit active"])
                local bcy = -32
                local banTxt = self:CreateFontString(banCard, "OVERLAY", nil, 10)
                banTxt:SetPoint("TOPLEFT", banCard, "TOPLEFT", 15, bcy)
                banTxt:SetText(RCL["Editing "] .. raidName .. RCL[" for "] .. who .. RCL[" - changes sync automatically."])
                banTxt:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])
                local exitBtn = self.UI:CreateStyledButton(banCard, RCL["Exit Remote Edit"], 130, 22)
                exitBtn:SetPoint("TOPRIGHT", banCard, "TOPRIGHT", -12, bcy + 4)
                exitBtn:SetScript("OnClick", function()
                    if RC.ExitRemoteEditMode then RC:ExitRemoteEditMode() end
                end)
                bcy = bcy - 28
                banCard:SetContentHeight(math.abs(bcy))
                yPos = yPos - banCard:GetHeight() - 10
            end
        end

        -- Profile bar's onChange callback re-renders this same page with
        -- preserveScroll=true (see ClearSidebarContent) so switching the
        -- active raid profile doesn't jerk the view back to the top.
        if self.CreateCompactRaidProfileBar then
            local preBarY = yPos
            yPos = self:CreateCompactRaidProfileBar(parent, yPos, raidName, frame, function()
                RC:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, nil, true)
            end)
            local pb = frame._profileBarFrame
            if pb and frame._chipStrip then
                pb:ClearAllPoints()
                pb:SetPoint("TOPLEFT", frame._chipStrip, "TOPLEFT",
                    (frame._chipRowEndX or 232) + 10, frame._chipRowY or -42)
                pb:SetPoint("RIGHT", parent, "RIGHT", -20, 0)
                pb:SetHeight(22)
                yPos = preBarY
            end
        end

        if encounterType == "trashsection" then
            frame.bulkTrashState = frame.bulkTrashState or {}
            frame.bulkTrashState.selectedQuarter = encounterName
            yPos = self:RenderBulkTrashBody(frame, raidName, parent, yPos) or yPos
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            if preserveScroll then
                self:RestoreScrollPosition(self.sidebarConfigFrame)
            end
            return
        end

        if encounterType == "route" then
            yPos = (self.RenderRaidRouteBody and self:RenderRaidRouteBody(frame, raidName, parent, yPos)) or yPos
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            if preserveScroll then
                self:RestoreScrollPosition(self.sidebarConfigFrame)
            end
            return
        end
        -- settingsKey is the raidSettings.bosses/trash storage key: the
        -- encounter name (per-phase entries were retired).
        local effectiveEncounterName = encounterName
        local settingsKey = encounterName
        local encounterSettings
        if encounterType == "boss" then
            if not raidSettings.bosses[settingsKey] then
                raidSettings.bosses[settingsKey] = { enabled = false, abilities = {} }
                self:DebugPrint("ShowInlineAbilityConfig: Created NEW boss config for " .. settingsKey, "config")
            end
            encounterSettings = raidSettings.bosses[settingsKey]
        else
            if not raidSettings.trash[settingsKey] then
                raidSettings.trash[settingsKey] = { enabled = false, abilities = {} }
                self:DebugPrint("ShowInlineAbilityConfig: Created NEW trash config for " .. settingsKey, "config")
            end
            encounterSettings = raidSettings.trash[settingsKey]
        end

        if encounterSettings.abilities then
            local ac = 0
            for _ in pairs(encounterSettings.abilities) do ac = ac + 1 end
            self:DebugPrint(string.format(RCL["ShowInlineAbilityConfig: %s has %d configured abilities"], settingsKey, ac), "config")
        else
            self:DebugPrint("ShowInlineAbilityConfig: No abilities table for " .. settingsKey, "config")
        end

        local function HasEnabledAbilities()
            if encounterSettings.abilities then
                for _, cfg in pairs(encounterSettings.abilities) do
                    if cfg and cfg.enabled then return true end
                end
            end
            if encounterSettings.postDeathConsumables
               and next(encounterSettings.postDeathConsumables) then
                return true
            end
            return false
        end

        local function UpdateEncounterEnabledState(shouldSave)
            local has = HasEnabledAbilities()
            if encounterSettings.enabled ~= has then
                encounterSettings.enabled = has
                if shouldSave then
                    RC:SaveConfigurationToProfile()
                    RC:RefreshSidebarProfiles()
                end
                return true
            end
            return false
        end

        local stateChanged = UpdateEncounterEnabledState(false)
        if stateChanged then RC:SaveConfigurationToProfile() end
        frame.UpdateEncounterEnabledState = function() UpdateEncounterEnabledState(true) end

        local availableAbilities = RC:GetAvailableAbilities(encounterType, encounterName)

        -- "trinkets"/"defensives"/"potion"/"utility" are grid-tile pseudo
        -- keys, not real ability storage keys - each is enabled if ANY of
        -- the underlying abilities.* entries it groups is enabled.
        local function IsAbilityEnabled(abilityKey)
            if abilityKey == "trinkets" then
                local t1 = encounterSettings.abilities["trinket1"]
                local t2 = encounterSettings.abilities["trinket2"]
                local bc = encounterSettings.abilities["battleChicken"]
                local ad = encounterSettings.abilities["arcaniteDragonling"]
                return (t1 and t1.enabled) or (t2 and t2.enabled) or (bc and bc.enabled) or (ad and ad.enabled)
            elseif abilityKey == "defensives" then
                local ls = encounterSettings.abilities["laststand"]
                local sw = encounterSettings.abilities["shieldwall"]
                return (ls and ls.enabled) or (sw and sw.enabled)
            elseif abilityKey == "potion" then
                for key, cfg in pairs(encounterSettings.abilities) do
                    if type(key) == "string" and (key == "potion" or key:lower():find("potion")) and cfg and cfg.enabled then
                        return true
                    end
                end
                return false
            elseif abilityKey == "utility" then
                for key, cfg in pairs(encounterSettings.abilities) do
                    if tonumber(key) and RC.utilityItems and RC.utilityItems[tonumber(key)] and cfg and cfg.enabled then
                        return true
                    end
                end
                if encounterSettings.postDeathConsumables then
                    if next(encounterSettings.postDeathConsumables) then
                        return true
                    end
                end
                return false
            else
                local cfg = encounterSettings.abilities[abilityKey]
                return cfg and cfg.enabled
            end
        end

        -- Racial tiles only show for races that can cast them: the local
        -- toon's race, or the remote toon's while remote editing.
        local racialAbilityRace = {
            bloodfury  = "Orc",
            berserking = "Troll",
        }
        local isRemoteRaid
        do
            local _rem = RC.remoteEditMode
            isRemoteRaid = (_rem and raidName == _rem.raidKey and RC._remoteEditData) and true or false
            local allowedRaces = self:GetRaidConfigRacialRaces(raidName, raidSettings, not isRemoteRaid)
            local filtered = {}
            for _, info in ipairs(availableAbilities) do
                local needed = racialAbilityRace[info[1]]
                if not needed or allowedRaces[needed] then
                    filtered[#filtered + 1] = info
                end
            end
            availableAbilities = filtered
        end

        -- Polarity Mode is a separate always-on system for Sapphiron that
        -- fires these specific reminders itself; polarityOwnedKeys just
        -- greys them out here and blocks the click handler below so the
        -- player doesn't configure a duplicate/conflicting trigger.
        local polarityActive =
            (encounterType == "boss")
            and (encounterName == "Sapphiron")
            and self.db.polarityMode
            and self.db.polarityMode.enabled

        local polarityOwnedKeys = {}
        if polarityActive then
            polarityOwnedKeys.deathwish = true
            polarityOwnedKeys.recklessness = true
            polarityOwnedKeys.potion     = true
            polarityOwnedKeys.trinkets   = true
            polarityOwnedKeys.utility    = true
        end

        -- Strip/panel state. frame.bossPageTab[encounterName] names the
        -- open panel: "abilities" (an ability tile - or nothing - is open;
        -- frame._expandedAbility[settingsKey] says which) or one of the
        -- page tiles "gear" / "fungal" / "horsemen" / "history". Opening a
        -- page tile clears the expanded ability; clicking an ability tile
        -- puts the tab back on "abilities".
        frame.bossPageTab = frame.bossPageTab or {}
        frame._expandedAbility = frame._expandedAbility or {}
        local activeTab = "abilities"
        if encounterType == "boss" then
            if not frame.bossPageTab[encounterName] then
                frame.bossPageTab[encounterName] = "abilities"
            end
            activeTab = frame.bossPageTab[encounterName]
            if (activeTab == "fungal" and encounterName ~= "Loatheb")
               or (activeTab == "horsemen" and encounterName ~= "Four Horsemen") then
                activeTab = "abilities"
                frame.bossPageTab[encounterName] = "abilities"
            end
        end
        if activeTab ~= "abilities" then
            frame._expandedAbility[settingsKey] = nil
        end
        local expandedKey = frame._expandedAbility[settingsKey]

        local HORSEMEN = {
            "Highlord Mograine",
            "Lady Blaumeux",
            "Thane Korth'azz",
            "Sir Zeliek",
        }

        -- The kills this boss's predictions read: this config's own plus
        -- its related configs' (the same list the reminders use), each
        -- still filed under the config it was recorded on. fightKeyOf maps
        -- every kill shown to the bucket it really lives in, so deleting
        -- or editing a row acts on the real kill, wherever it is filed.
        local fights, bossKey
        local fightKeyOf, linkedConfigs = {}, 0
        local histBoss = (self.TTKBossName and self:TTKBossName(raidName, effectiveEncounterName)) or effectiveEncounterName
        if encounterType == "boss" and self.GetLinkedFightHistoryForBoss then
            local linked
            linked, bossKey, linkedConfigs = self:GetLinkedFightHistoryForBoss(raidName, histBoss)
            fights = {}
            for i, f in ipairs(linked or {}) do fights[i] = f end
            local data = self.executeCalculator and self.executeCalculator.fightHistory
                and self.executeCalculator.fightHistory.data
            -- only the History tab shows (and edits) individual kills; the
            -- strip just needs the count
            if data and activeTab == "history" then
                local want = {}
                for _, f in ipairs(fights) do want[f] = true end
                local suffix = "_" .. histBoss
                for k, list in pairs(data) do
                    if type(k) == "string" and type(list) == "table" and k:sub(1, #raidName) == raidName
                       and k:sub(-#suffix) == suffix then
                        for _, f in ipairs(list) do
                            if want[f] then fightKeyOf[f] = k end
                        end
                    end
                end
            end
        elseif encounterType == "boss" then
            if self.GetFightHistoryForBoss then
                fights, bossKey = self:GetFightHistoryForBoss(raidName, effectiveEncounterName)
            else
                bossKey = raidName .. "_" .. effectiveEncounterName
                fights = self.executeCalculator and self.executeCalculator.fightHistory and
                         self.executeCalculator.fightHistory.data and
                         self.executeCalculator.fightHistory.data[bossKey]
            end

            if fights and bossKey then
                local keyProfile
                if bossKey:find("|", 1, true) then
                    local rest = bossKey:match("^[^|]+|(.+)$")
                    if rest then keyProfile = rest:match("^(.-)_") end
                end
                if keyProfile and keyProfile ~= "" then
                    local filtered = {}
                    for _, f in ipairs(fights) do
                        if not f.profileName or f.profileName == "" or f.profileName == keyProfile then
                            table.insert(filtered, f)
                        end
                    end
                    fights = filtered
                end
            end
        end
        local stripFightCount = fights and #fights or 0

        local function AbilityDisplayName(key)
            for _, info in ipairs(availableAbilities) do
                if info[1] == key then return info[2] end
            end
            local ad = self.abilityData and self.abilityData[key]
            return (ad and ad.name) or tostring(key)
        end

        -- "Apply to all <raid> bosses": copies this boss's settings for the
        -- open ability tile onto every other boss entry of this raid
        -- (phased bosses get every phase key; the four horsemen only their
        -- group key, since that is the only one in raidData.bosses). Copies
        -- exactly the keys each ability page writes: trinkets -> the four
        -- slot entries, defensives -> laststand/shieldwall, utility -> every
        -- utility item entry plus postDeathConsumables, anything else -> its
        -- own abilities[abilityKey]. Wholesale replace, same as the trash
        -- bulk fan-out in Raids_AbilityPages.lua.
        local RAID_SHORT = {
            ["Molten Core"]          = "MC",
            ["Blackwing Lair"]       = "BWL",
            ["Temple of Ahn'Qiraj"]  = "AQ40",
            ["Naxxramas"]            = "Naxx",
        }
        local function IsUtilityItemKey(k)
            local id = tonumber(k)
            return id and RC.utilityItems and RC.utilityItems[id] and true or false
        end
        local function LocalDeepCopy(v)
            if type(v) ~= "table" then return v end
            local c = {}
            for k, x in pairs(v) do c[k] = LocalDeepCopy(x) end
            return c
        end
        local function ApplyAbilityToAllBosses(abilityKey)
            local copy = RC.DeepCopy or LocalDeepCopy
            local keys, withPdc = nil, false
            if abilityKey == "trinkets" then
                keys = { "trinket1", "trinket2", "battleChicken", "arcaniteDragonling" }
            elseif abilityKey == "defensives" then
                keys = { "laststand", "shieldwall" }
            elseif abilityKey == "utility" then
                keys = {}
                for k in pairs(encounterSettings.abilities or {}) do
                    if IsUtilityItemKey(k) then keys[#keys + 1] = k end
                end
                withPdc = true
            else
                keys = { abilityKey }
            end

            local bossList = self.raidData and self.raidData[raidName] and self.raidData[raidName].bosses or {}
            local targets = {}
            for _, bn in ipairs(bossList) do
                targets[#targets + 1] = bn
            end

            raidSettings.bosses = raidSettings.bosses or {}
            local n = 0
            for _, tk in ipairs(targets) do
                if tk ~= settingsKey then
                    local tgt = raidSettings.bosses[tk]
                    if not tgt then
                        tgt = { enabled = false, abilities = {} }
                        raidSettings.bosses[tk] = tgt
                    end
                    tgt.abilities = tgt.abilities or {}
                    if abilityKey == "utility" then
                        for k in pairs(tgt.abilities) do
                            if IsUtilityItemKey(k) then tgt.abilities[k] = nil end
                        end
                    end
                    for _, k in ipairs(keys) do
                        local src = encounterSettings.abilities and encounterSettings.abilities[k]
                        tgt.abilities[k] = src and copy(src) or nil
                    end
                    if withPdc then
                        tgt.postDeathConsumables = encounterSettings.postDeathConsumables
                            and copy(encounterSettings.postDeathConsumables) or nil
                    end
                    local has = false
                    for _, c in pairs(tgt.abilities) do
                        if c and c.enabled then has = true break end
                    end
                    if not has and tgt.postDeathConsumables and next(tgt.postDeathConsumables) then
                        has = true
                    end
                    tgt.enabled = has
                    n = n + 1
                end
            end

            self:SaveConfigurationToProfile()
            self:RefreshSidebarProfiles()
            RC:Print(string.format(RCL["Applied %s from %s to %d other %s boss%s."],
                AbilityDisplayName(abilityKey), encounterName, n,
                RAID_SHORT[raidName] or raidName, n == 1 and "" or "es"))
            RC:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings, true)
        end

        -- Ability tile click: same toggle/seed semantics as before, just
        -- routed through the strip. Page tabs hand back to "abilities".
        local function AbilityTileClick(ak, akIsPolarityOwned)
            if akIsPolarityOwned then
                RC:Print(RCL["|cFFFFD700[Polarity Mode]|r This reminder is handled by Polarity Mode. Disable Polarity on the Sapphiron page if you want to configure it normally."])
                return
            end

            if encounterType == "boss" then
                frame.bossPageTab[encounterName] = "abilities"
            end
            frame._expandedAbility = frame._expandedAbility or {}
            local oldKey = frame._expandedAbility[settingsKey]

            self:CycleInlineExpansion(
                function() return frame._expandedAbilityFrame end,
                function()
                    if ak == "trinkets" or ak == "utility" or ak == "defensives" then
                        if frame._expandedAbility[settingsKey] == ak then
                            frame._expandedAbility[settingsKey] = nil
                        else
                            frame._expandedAbility[settingsKey] = ak
                        end
                        if ak == "utility"
                           and not frame._expandedAbility[settingsKey]
                           and frame._expandedUtilityItem
                        then
                            frame._expandedUtilityItem[settingsKey] = nil
                        end
                    else
                        local wasExpanded = (frame._expandedAbility[settingsKey] == ak)

                        if wasExpanded then
                            frame._expandedAbility[settingsKey] = nil
                        else
                            if not encounterSettings.abilities[ak] then
                                local nc = { enabled = true, triggerType = "hp_percent", enableTTS = true }
                                if ak == "frostBlast" then nc.triggerType = "player_hp_above"; nc.playerHpAboveValue = 8500 end
                                if type(ak) == "string" and ak:lower():find("potion") then nc.potionType = "mightyRagePotion"; nc.hpValue = 20 end
                                encounterSettings.abilities[ak] = nc
                            elseif not encounterSettings.abilities[ak].enabled then
                                encounterSettings.abilities[ak].enabled = true
                                encounterSettings.abilities[ak].enableTTS = true
                            end
                            frame._expandedAbility[settingsKey] = ak
                        end

                        if frame.UpdateEncounterEnabledState then frame.UpdateEncounterEnabledState() end
                        self:SaveConfigurationToProfile()
                    end

                    local newKey = frame._expandedAbility[settingsKey]
                    if newKey and newKey ~= oldKey then
                        frame._pendingFadeInBossKey = newKey
                    end

                    self:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings, true)
                end
            )
        end

        -- Page tile click: opens that panel, or closes it back to an empty
        -- abilities panel when it is already the open one.
        local function PageTileClick(key)
            if activeTab == key then
                frame.bossPageTab[encounterName] = "abilities"
            else
                frame.bossPageTab[encounterName] = key
            end
            frame._expandedAbility[settingsKey] = nil
            RC:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings, true)
        end

        -- Short tile captions: known keys get a fixed word, the rest derive
        -- from the display name (cut at 8 chars + "." when it is long).
        local SHORT_LABELS = {
            deathwish = "Death Wish", recklessness = "Reckless.", potion = "Potion",
            trinkets = "Trinkets", utility = "Utility", defensives = "Defensives",
            bloodfury = "Racial", berserking = "Racial", gearswap = "Gear swap",
        }
        local function ShortLabel(key, name)
            if SHORT_LABELS[key] then return RCL[SHORT_LABELS[key]] end
            name = name or tostring(key)
            if #name <= 10 then return name end
            return name:sub(1, 8) .. "."
        end

        local stripTiles = {}
        for _, abilityInfo in ipairs(availableAbilities) do
            local ak, an, ai = abilityInfo[1], abilityInfo[2], abilityInfo[3]
            local isEnabled = IsAbilityEnabled(ak) and true or false
            local owned = polarityOwnedKeys[ak] == true
            stripTiles[#stripTiles + 1] = {
                key = ak, label = ShortLabel(ak, an), icon = ai,
                enabled = isEnabled, dimmed = owned,
                open = (activeTab == "abilities" and expandedKey == ak),
                tooltip = function(s)
                    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                    GameTooltip:SetText(an or "", 1, 1, 1)
                    if owned then
                        GameTooltip:AddLine(RCL["Managed by Polarity Mode"], 1, 0.82, 0)
                        GameTooltip:AddLine(RCL["Polarity Mode is active on Sapphiron and fires this reminder automatically."], 0.9, 0.9, 0.9, true)
                        GameTooltip:AddLine(RCL["Disable Polarity Mode to configure this ability normally."], 0.7, 0.7, 0.7, true)
                    else
                        GameTooltip:AddLine(isEnabled and RCL["ON - click to configure"] or RCL["OFF - click to configure"], 0.7, 0.7, 0.7)
                    end
                    GameTooltip:Show()
                end,
                onClick = function() AbilityTileClick(ak, owned) end,
            }
        end

        if encounterType == "boss" then
            local pageTiles = {}
            do
                local gearOn = RC:EncounterHasGearConfig(encounterSettings)
                pageTiles[#pageTiles + 1] = {
                    key = "gear", label = RCL["Gear swap"], icon = "Interface\\Icons\\INV_Chest_Plate16",
                    enabled = gearOn, tipTitle = RCL["Gear swap"], tipLine = RCL["Engage / after-death gear swaps"],
                }
            end
            if encounterName == "Loatheb" then
                local fb = encounterSettings.fungalBloom
                pageTiles[#pageTiles + 1] = {
                    key = "fungal", label = RCL["Fungal"], icon = "Interface\\Icons\\Spell_Nature_Regenerate",
                    enabled = (fb and fb.enabled) and true or false,
                    tipTitle = RCL["Fungal Bloom"], tipLine = RCL["Auto-swap gear sets when Fungal Bloom is gained or removed"],
                }
            end
            if encounterName == "Four Horsemen" then
                local anyHorse = false
                for _, horseName in ipairs(HORSEMEN) do
                    if RC:EncounterHasConfig(raidSettings.bosses[horseName]) then anyHorse = true break end
                end
                pageTiles[#pageTiles + 1] = {
                    key = "horsemen", label = RCL["Horsemen"], icon = "Interface\\Icons\\Spell_Shadow_DeathPact",
                    enabled = anyHorse, tipTitle = RCL["Horsemen"], tipLine = RCL["Per-horseman reminder config"],
                }
            end
            pageTiles[#pageTiles + 1] = {
                key = "history", label = RCL["History"], icon = "Interface\\Icons\\INV_Misc_Note_01",
                enabled = stripFightCount > 0, tipTitle = RCL["Kill history"], tipLine = RCL["Recorded kill times for this boss"],
            }

            stripTiles[#stripTiles + 1] = { divider = true }
            for _, pt in ipairs(pageTiles) do
                local key = pt.key
                pt.open = (activeTab == key)
                pt.tooltip = function(s)
                    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                    GameTooltip:SetText(pt.tipTitle, 1, 1, 1)
                    GameTooltip:AddLine(pt.tipLine, 0.7, 0.7, 0.7)
                    GameTooltip:Show()
                end
                pt.onClick = function() PageTileClick(key) end
                stripTiles[#stripTiles + 1] = pt
            end
        end

        do
            local stripH = BuildTileStrip(parent, yPos, {
                caption = (encounterType == "boss") and RCL["Boss"] or RCL["Trash"],
                tiles   = stripTiles,
                -- Only fires when a resize changes how many rows of tiles
                -- there are, which moves the panel underneath.
                onReflow = function()
                    if RC._bossStripReflowing then return end
                    RC._bossStripReflowing = true
                    C_Timer.After(0, function()
                        RC._bossStripReflowing = nil
                        if RC._lastPageFrame == frame then
                            RC:ShowInlineAbilityConfig(frame, raidName, encounterName,
                                encounterType, raidSettings, true)
                        end
                    end)
                end,
            })
            yPos = yPos - stripH - 10
        end

        if polarityActive then
            local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"
            local banner = CreateFrame("Frame", nil, parent)
            banner:SetPoint("TOPLEFT",  parent, "TOPLEFT",  18, yPos)
            banner:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -18, yPos)
            banner:SetHeight(52)
            local gold = RC:GetColor("ui", "accentGold")
            local bg   = RC:GetColor("ui", "elementBackground")
            local bfill = banner:CreateTexture(nil, "BACKGROUND")
            bfill:SetAllPoints()
            bfill:SetTexture(FLAT)
            bfill:SetVertexColor(bg.r, bg.g, bg.b, 1)
            RC.UI:CreateSimpleBorder(banner)
            local bbar = banner:CreateTexture(nil, "ARTWORK")
            bbar:SetPoint("TOPLEFT",    banner, "TOPLEFT",    0, 0)
            bbar:SetPoint("BOTTOMLEFT", banner, "BOTTOMLEFT", 0, 0)
            bbar:SetWidth(3)
            bbar:SetColorTexture(gold.r, gold.g, gold.b, 0.8)

            local slot = (self.db.polarityMode.trinketSlot == 14) and 14 or 13
            local bannerText = self:CreateFontString(banner, "OVERLAY", nil, 10)
            bannerText:SetPoint("TOPLEFT",  banner, "TOPLEFT",   12, -6)
            bannerText:SetPoint("BOTTOMRIGHT", banner, "BOTTOMRIGHT", -10, 6)
            bannerText:SetJustifyH("LEFT")
            bannerText:SetJustifyV("MIDDLE")
            bannerText:SetWordWrap(true)
            bannerText:SetText(
                RCL["|cFFFFD700Polarity Mode is active on Sapphiron.|r "] ..
                RCL["Death Wish, Recklessness, Slot "] .. slot .. RCL[" trinket, LIP, and "] ..
                RCL["Masterwork Target Dummy are handled by Polarity. Settings here "] ..
                RCL["are suppressed for those abilities."]
            )
            do local _c = self:GetColor("text", "white"); bannerText:SetTextColor(_c.r, _c.g, _c.b, _c.a) end

            yPos = yPos - 52 - 10
        end

        -- Ability panel header: the first titled card the renderer drew
        -- carries the panel title already (no double title), so the boss
        -- subtitle and the "Apply to all" button hang off that card.
        local function AttachPanelHeader(inlineSub, key)
            local card
            for _, ch in ipairs({ inlineSub:GetChildren() }) do
                if ch.title and ch.SetContentHeight then card = ch break end
            end
            if not card then
                self:DebugPrint("ShowInlineAbilityConfig: no titled card for panel header (" .. tostring(key) .. ")", "config")
                return
            end
            local subtitle = self:CreateFontString(card, "OVERLAY", nil, 10)
            subtitle:SetPoint("LEFT", card.title, "RIGHT", 8, 0)
            subtitle:SetJustifyH("LEFT")
            subtitle:SetWordWrap(false)
            subtitle:SetText(encounterName .. " \194\183 " .. AbilityDisplayName(key))
            subtitle:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])

            if isRemoteRaid then
                subtitle:SetPoint("RIGHT", card, "RIGHT", -12, 0)
                return
            end
            local short = RAID_SHORT[raidName] or raidName
            local applyBtn = self.UI:CreateStyledButton(card, RCL["Apply to all "] .. short .. RCL[" bosses"], 150, 22)
            if applyBtn.text then RC:ApplyCustomFont(applyBtn.text, 10) end
            applyBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -5)
            subtitle:SetPoint("RIGHT", applyBtn, "LEFT", -8, 0)
            applyBtn:SetScript("OnEnter", function(s)
                if s.Repaint then s:Repaint() end
                GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                GameTooltip:SetText(RCL["Apply to all "] .. short .. RCL[" bosses"], 1, 1, 1)
                GameTooltip:AddLine(RCL["Copies this ability's settings from "] .. encounterName .. RCL[" onto every other boss in the raid, replacing what they have for it."], 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            applyBtn:SetScript("OnLeave", function(s)
                if s.Repaint then s:Repaint() end
                GameTooltip:Hide()
            end)
            applyBtn:SetScript("OnClick", function()
                local abilityLabel = AbilityDisplayName(key)
                RC.UI:CreateConfirmDialog(
                    RCL["Apply to all "] .. short .. RCL[" bosses"],
                    string.format(RCL["Copy the %s settings from %s to every other %s boss? Their current %s settings will be replaced."],
                        abilityLabel, encounterName, short, abilityLabel),
                    function() ApplyAbilityToAllBosses(key) end,
                    nil, RCL["Apply"], false)
            end)
        end

        -- Renders the open ability's config as one full-width panel and
        -- returns the new yPos. Same renderer calls and fade handling as
        -- before, just no side pane.
        local function RenderAbilityPanel(y)
            local key = expandedKey
            local inlineSub = CreateFrame("Frame", nil, parent)
            inlineSub:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, y)
            inlineSub:SetPoint("RIGHT",   parent, "RIGHT",   0, 0)
            inlineSub:SetHeight(1)
            inlineSub:SetAlpha(1)
            frame._expandedAbilityFrame = inlineSub

            local commonInlineCtx = {
                parent = inlineSub,
                yPos = 0,
                settingsKey = settingsKey,
                onRefresh = function()
                    RC:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings, true)
                end,
            }
            local newY
            if key == "trinkets" then
                newY = self:ShowTrinketSlotSelection(
                    frame, raidName, encounterName, encounterType,
                    raidSettings, encounterSettings, false, commonInlineCtx)
            elseif key == "utility" then
                newY = self:ShowSidebarUtilityConfig(
                    frame, raidName, encounterName, encounterType,
                    raidSettings, encounterSettings, false, commonInlineCtx)
            elseif key == "defensives" then
                newY = self:ShowSidebarDefensivesConfig(
                    frame, raidName, encounterName, encounterType,
                    raidSettings, encounterSettings, false, commonInlineCtx)
            elseif encounterSettings.abilities
                   and encounterSettings.abilities[key]
            then
                newY = self:ShowSidebarAbilityConfig(
                    frame, raidName, encounterName, encounterType, raidSettings,
                    key, nil, false, commonInlineCtx)
            end
            if newY then y = y + newY end

            AttachPanelHeader(inlineSub, key)

            if frame._pendingFadeInBossKey == key then
                RC:FadeInInlineBody(inlineSub)
                frame._pendingFadeInBossKey = nil
            else
                inlineSub:SetAlpha(1)
            end
            return y
        end

        local function RenderEmptyPanelHint(y)
            local hint = self:CreateFontString(parent, "OVERLAY", nil, 10)
            hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, y - 4)
            hint:SetText(RCL["Pick an ability or page above to configure it."])
            hint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            return y - 24
        end

        if encounterType == "boss" then
            if activeTab == "abilities" then
                if expandedKey then
                    yPos = RenderAbilityPanel(yPos)
                else
                    yPos = RenderEmptyPanelHint(yPos)
                end

                if encounterName == "Sapphiron" and RC.BuildSapphironPolarityCard then
                    yPos = RC:BuildSapphironPolarityCard(parent, yPos, frame, raidName, encounterName)
                end

            elseif activeTab == "gear" then
                -- the gear set picker this boss can ask with, in the strip
                -- (the picker lists this character's sets: none while
                -- editing someone else's raid)
                if not isRemoteRaid then self:DeclareGearSetPromptPreview(encounterName, encounterSettings) end
                -- slot1/slot2/deathSlot1/deathSlot2 are the old trinket-only
                -- override fields; onTarget/onDeath are the current per-slot
                -- maps (any equip slot, not just trinkets). This one-time
                -- migration only seeds onTarget/onDeath from the legacy
                -- fields the first time a profile saved under the old
                -- format is opened - it does not delete the legacy fields.
                local gs0 = encounterSettings
                if not gs0.forceEquip then
                    gs0.forceEquip = { slot1 = nil, slot2 = nil, deathSlot1 = nil, deathSlot2 = nil }
                end
                if not gs0.forceEquip.onTarget then
                    gs0.forceEquip.onTarget = {}
                    if gs0.forceEquip.slot1 then gs0.forceEquip.onTarget[13] = gs0.forceEquip.slot1 end
                    if gs0.forceEquip.slot2 then gs0.forceEquip.onTarget[14] = gs0.forceEquip.slot2 end
                end
                if not gs0.forceEquip.onDeath then
                    gs0.forceEquip.onDeath = {}
                    if gs0.forceEquip.deathSlot1 then gs0.forceEquip.onDeath[13] = gs0.forceEquip.deathSlot1 end
                    if gs0.forceEquip.deathSlot2 then gs0.forceEquip.onDeath[14] = gs0.forceEquip.deathSlot2 end
                end
                if not gs0.forceEquip.onTargetEnchant then
                    gs0.forceEquip.onTargetEnchant = {}
                end
                if not gs0.forceEquip.onDeathEnchant then
                    gs0.forceEquip.onDeathEnchant = {}
                end

                if not gs0.abilities then gs0.abilities = {} end
                if not gs0.abilities.gearswap then
                    gs0.abilities.gearswap = { enabled = false, gearSet = "", postCombatSet = "", postCombatSwap = false }
                end
                local gsCfg = gs0.abilities.gearswap
                local fe    = gs0.forceEquip

                local _gold = RC:GetColor("ui", "accentGold")  or {r=0.85,g=0.65,b=0.25}

                if not frame._gearSwapActiveTab then frame._gearSwapActiveTab = "onTarget" end

                -- While remote editing, the local GearManager/ItemRack sets
                -- below belong to THIS character and are meaningless for the
                -- remote toon, so this substitutes the names fetched for
                -- them instead of falling through to the local lookups.
                local function GatherSets()
                    if isRemoteRaid and RC._remoteEditGearSetNames then
                        local names = {}
                        for _, sn in pairs(RC._remoteEditGearSetNames) do
                            if type(sn) == "string" then names[#names + 1] = sn end
                        end
                        table.sort(names)
                        return names
                    end
                    local names, seen = {}, {}
                    if RC.GearManager and RC.GearManager.sets then
                        for sn in pairs(RC.GearManager.sets) do
                            if not seen[sn] then table.insert(names, sn); seen[sn] = true end
                        end
                    end
                    if RC.db and RC.db.gearSets then
                        for sn in pairs(RC.db.gearSets) do
                            if not seen[sn] then table.insert(names, sn); seen[sn] = true end
                        end
                    end
                    if ItemRackUser and ItemRackUser.Sets then
                        for sn in pairs(ItemRackUser.Sets) do
                            if not sn:find("^~") and not seen[sn] then
                                table.insert(names, sn); seen[sn] = true
                            end
                        end
                    end
                    table.sort(names)
                    return names
                end

                -- one answer for a set's icon everywhere (Core_Gear)
                local function GetSetIcon(setName)
                    return RC:GetGearSetIcon(setName)
                end

                local function GetItemsFitForSlot(invSlot)
                    local items = {}
                    local seenKeys = {}

                    local function GetEnchantId(link)
                        if not link then return 0 end
                        return tonumber(link:match("item:%d+:(%d+)")) or 0
                    end

                    local function EnchantTextFromLink(link, eid)
                        if not link or not eid or eid == 0 then return nil end
                        RC._enchantNameCache = RC._enchantNameCache or {}
                        if RC._enchantNameCache[link] ~= nil then
                            return RC._enchantNameCache[link] or nil
                        end
                        local lines = RC.Compat.TooltipLines("hyperlink", link)
                        local result = nil
                        for i = 2, #lines do
                            local l = lines[i]
                            if l.text ~= "" and l.g and l.g > (l.r or 0)
                                    and l.g > (l.b or 0) and l.g > 0.4 then
                                result = l.text
                                break
                            end
                        end
                        RC._enchantNameCache[link] = result or false
                        return result
                    end

                    local function AddFromLink(link, slotHint, uniqueTag)
                        if not link then return end
                        local id  = tonumber(link:match("item:(%d+)"))
                        if not id then return end
                        local eid = GetEnchantId(link)
                        local key = id .. ":" .. eid .. ":" .. (uniqueTag or "?")
                        if seenKeys[key] then return end
                        seenKeys[key] = true
                        local n, _, _, _, _, _, _, _, _, tex = GetItemInfo(link)
                        local baseName = n or ("Item " .. id)
                        local enchant  = EnchantTextFromLink(link, eid)
                        local display  = enchant and (baseName .. "  (" .. enchant .. ")") or baseName
                        local icon     = tex
                            or (slotHint and (GetItemIcon(id) or GetInventoryItemTexture("player", slotHint)))
                            or GetItemIcon(id)
                        table.insert(items, {
                            itemId    = id,
                            enchantId = eid,
                            link      = link,
                            itemLink  = link,
                            name      = display,
                            icon      = icon,
                        })
                    end

                    AddFromLink(GetInventoryItemLink("player", invSlot), invSlot, "e" .. invSlot)

                    local _pairMap  = {[11]=12,[12]=11,[13]=14,[14]=13,[16]=17,[17]=16}
                    local _pairSlot = _pairMap[invSlot]
                    if _pairSlot then
                        local pLink = GetInventoryItemLink("player", _pairSlot)
                        if pLink then
                            local okPair = true
                            if invSlot == 16 or invSlot == 17 then
                                local GMp = RC.GearManager
                                local _, _, _, _, _, _, _, _, pEquipSlot = GetItemInfo(pLink)
                                okPair = ((pEquipSlot and GMp and GMp.CanItemGoInSlot)
                                          and GMp:CanItemGoInSlot(pEquipSlot, invSlot)) and true or false
                            end
                            if okPair then
                                AddFromLink(pLink, _pairSlot, "e" .. _pairSlot)
                            end
                        end
                    end

                    local GM = RC.GearManager
                    if GM and GM.CanItemGoInSlot then
                        for bag = 0, 4 do
                            local n = C_Container.GetContainerNumSlots(bag) or 0
                            for s = 1, n do
                                local link = C_Container.GetContainerItemLink(bag, s)
                                if link then
                                    local _, _, _, _, _, _, _, _, equipSlot = GetItemInfo(link)
                                    if GM:CanItemGoInSlot(equipSlot, invSlot) then
                                        AddFromLink(link, nil, "b" .. bag .. "_" .. s)
                                    end
                                end
                            end
                        end
                    end

                    table.sort(items, function(a, b) return (a.name or "") < (b.name or "") end)
                    return items
                end

                local bgsCard = self:CreateSettingsCard(parent, yPos, RCL["Boss gear swap"])
                local by = -35

                local hint = self:CreateFontString(bgsCard, "OVERLAY", nil, 10)
                hint:SetPoint("TOPLEFT", bgsCard, "TOPLEFT", 15, by)
                hint:SetWidth(bgsCard:GetWidth() - 30)
                hint:SetJustifyH("LEFT")
                hint:SetText(RCL["Pick a full gear set, override individual slots by hovering over them, or both. The full set equips first; per-slot overrides land on top so they always win. Trinket slots stay locked while the boss is alive so auto-swap won't yank them off."])
                hint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                by = by - hint:GetStringHeight() - 10

                local tabBar = CreateFrame("Frame", nil, bgsCard)
                tabBar:SetPoint("TOPLEFT", bgsCard, "TOPLEFT", 15, by)
                tabBar:SetSize(320, 26)
                by = by - 30

                local function ApplyTabStyle(b, isActive)
                    b.isConfigured = isActive
                    local handler = b:GetScript("OnLeave")
                    if handler then handler(b) end
                end

                local tabTarget = self.UI:CreateStyledButton(tabBar, RCL["When Targeting"], 155, 24)
                local tabDeath = self.UI:CreateStyledButton(tabBar, RCL["After Boss Dies"], 155, 24)
                tabDeath:SetPoint("RIGHT", tabBar, "RIGHT", 0, 0)
                tabTarget:SetPoint("RIGHT", tabDeath, "LEFT", -6, 0)

                -- Tab content holder, forward-declared; generous initial height
                -- (recomputed at end of RebuildTabContent) prevents flash-of-empty.
                local tabContent = CreateFrame("Frame", nil, bgsCard)
                tabContent:SetPoint("TOPLEFT", bgsCard, "TOPLEFT", 15, by)
                tabContent:SetPoint("RIGHT",   bgsCard, "RIGHT",  -15, 0)
                tabContent:SetHeight(470)
                local RebuildTabContent  -- forward declared

                -- The two sides are different heights and the page's scroll
                -- range was measured for the side it opened on: re-measure
                -- after a switch, or the bottom of the taller side (After
                -- Boss Dies) sits below where the page can scroll to.
                tabTarget:SetScript("OnClick", function()
                    frame._gearSwapActiveTab = "onTarget"
                    ApplyTabStyle(tabTarget, true)
                    ApplyTabStyle(tabDeath, false)
                    if RebuildTabContent then RebuildTabContent() end
                    RC:UpdateSidebarScrollbar(RC.sidebarConfigFrame)
                end)
                tabDeath:SetScript("OnClick", function()
                    frame._gearSwapActiveTab = "onDeath"
                    ApplyTabStyle(tabTarget, false)
                    ApplyTabStyle(tabDeath, true)
                    if RebuildTabContent then RebuildTabContent() end
                    RC:UpdateSidebarScrollbar(RC.sidebarConfigFrame)
                end)
                ApplyTabStyle(tabTarget, frame._gearSwapActiveTab == "onTarget")
                ApplyTabStyle(tabDeath,  frame._gearSwapActiveTab == "onDeath")

                local POPOUT_BTN  = 36
                local POPOUT_COLS = 6

                local function CreatePopoutMenu()
                    local menu = CreateFrame("Frame", nil, UIParent)
                    menu:SetSize(POPOUT_COLS * POPOUT_BTN, POPOUT_BTN)
                    menu:SetFrameStrata("FULLSCREEN_DIALOG")
                    menu:SetFrameLevel(1000)
                    menu:EnableMouse(true)
                    menu:Hide()
                    menu.itemButtons = {}

                    function menu:CancelHide()
                        if self._hideTimer then
                            self._hideTimer:Cancel()
                            self._hideTimer = nil
                        end
                    end
                    function menu:HideSoon(delay)
                        self:CancelHide()
                        local d = delay or 0.1
                        self._hideTimer = C_Timer.NewTimer(d, function()
                            if self._hideTimer then
                                self._hideTimer = nil
                                if self:IsShown() then self:Hide() end
                            end
                        end)
                    end

                    menu:SetScript("OnEnter", function(self) self:CancelHide() end)
                    menu:SetScript("OnLeave", function(self) self:HideSoon() end)

                    return menu
                end

                local function GetOrCreateItemButton(menu, index)
                    local btn = menu.itemButtons[index]
                    if btn then return btn end

                    btn = CreateFrame("Button", nil, menu)
                    btn:SetSize(POPOUT_BTN, POPOUT_BTN)
                    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

                    local icon = btn:CreateTexture(nil, "BACKGROUND")
                    icon:SetAllPoints()
                    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
                    icon:SetVertexColor(1, 1, 1, 1)
                    btn.icon = icon

                    local emptyBg = btn:CreateTexture(nil, "BACKGROUND", nil, -1)
                    emptyBg:SetAllPoints()
                    emptyBg:SetColorTexture(0.3, 0.3, 0, 0.5)
                    emptyBg:Hide()
                    btn.emptyBg = emptyBg

                    local function MakeBorder(point1, point2, h, w)
                        local t = btn:CreateTexture(nil, "OVERLAY")
                        t:SetColorTexture(0, 0, 0, 1)
                        t:SetPoint(point1, 0, 0)
                        t:SetPoint(point2, 0, 0)
                        if h then t:SetHeight(h) end
                        if w then t:SetWidth(w) end
                        return t
                    end
                    btn._borderTop    = MakeBorder("TOPLEFT",    "TOPRIGHT",    1, nil)
                    btn._borderBottom = MakeBorder("BOTTOMLEFT", "BOTTOMRIGHT", 1, nil)
                    btn._borderLeft   = MakeBorder("TOPLEFT",    "BOTTOMLEFT",  nil, 1)
                    btn._borderRight  = MakeBorder("TOPRIGHT",   "BOTTOMRIGHT", nil, 1)

                    local function MakeHoverBorder(point1, point2, h, w)
                        local t = btn:CreateTexture(nil, "OVERLAY", nil, 2)
                        t:SetColorTexture(_gold.r, _gold.g, _gold.b, 1)
                        t:SetPoint(point1, 0, 0)
                        t:SetPoint(point2, 0, 0)
                        if h then t:SetHeight(h) end
                        if w then t:SetWidth(w) end
                        t:Hide()
                        return t
                    end
                    btn._hbTop    = MakeHoverBorder("TOPLEFT",    "TOPRIGHT",    1, nil)
                    btn._hbBottom = MakeHoverBorder("BOTTOMLEFT", "BOTTOMRIGHT", 1, nil)
                    btn._hbLeft   = MakeHoverBorder("TOPLEFT",    "BOTTOMLEFT",  nil, 1)
                    btn._hbRight  = MakeHoverBorder("TOPRIGHT",   "BOTTOMRIGHT", nil, 1)

                    local hh = btn:CreateTexture(nil, "ARTWORK", nil, 7)
                    hh:SetAllPoints()
                    hh:SetColorTexture(1, 1, 1, 0.15)
                    hh:SetBlendMode("ADD")
                    hh:Hide()
                    btn._hoverHighlight = hh

                    local pushed = btn:CreateTexture(nil, "ARTWORK", nil, 6)
                    pushed:SetAllPoints()
                    pushed:SetColorTexture(0, 0, 0, 0.4)
                    btn:SetPushedTexture(pushed)
                    btn:SetPushedTextOffset(1, -1)

                    local sel = RC:CreateFontString(btn, "OVERLAY", nil, 12)
                    sel:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -2, -2)
                    sel:SetTextColor(_gold.r, _gold.g, _gold.b, 1)
                    sel:SetText("")
                    btn._sel = sel

                    menu.itemButtons[index] = btn
                    return btn
                end

                if not frame._bossGearPopout then
                    frame._bossGearPopout = CreatePopoutMenu()
                end
                local popoutMenu = frame._bossGearPopout

                local INV_SLOT_NAMES = {
                    [1]  = "HeadSlot",       [2]  = "NeckSlot",     [3]  = "ShoulderSlot",
                    [4]  = "ShirtSlot",      [5]  = "ChestSlot",    [6]  = "WaistSlot",
                    [7]  = "LegsSlot",       [8]  = "FeetSlot",     [9]  = "WristSlot",
                    [10] = "HandsSlot",      [11] = "Finger0Slot",  [12] = "Finger1Slot",
                    [13] = "Trinket0Slot",   [14] = "Trinket1Slot", [15] = "BackSlot",
                    [16] = "MainHandSlot",   [17] = "SecondaryHandSlot",
                    [18] = "RangedSlot",     [19] = "TabardSlot",
                }

                local function IsGrowDownSlot(invSlot)
                    return invSlot == 16 or invSlot == 17 or invSlot == 18
                end

                local function PopulatePopout(invSlot, slotName, selectedId, items, onPick)
                    local rows = {{ id = nil, isEmpty = true }}
                    for _, it in ipairs(items) do
                        rows[#rows + 1] = it
                    end

                    for _, b in ipairs(popoutMenu.itemButtons) do b:Hide() end

                    local cols = math.min(3, math.max(1, #rows))
                    local totalRows = math.ceil(#rows / cols)

                    local slotKey = INV_SLOT_NAMES[invSlot]
                    local emptyTex = slotKey and RC:GetSlotEmptyTexture(slotKey) or nil
                    if not emptyTex then
                        emptyTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Background"
                    end

                    for i, r in ipairs(rows) do
                        local b = GetOrCreateItemButton(popoutMenu, i)
                        b:Show()

                        local col = (i - 1) % cols
                        local row = math.floor((i - 1) / cols)
                        b:ClearAllPoints()
                        b:SetPoint("TOPLEFT", popoutMenu, "TOPLEFT", col * POPOUT_BTN, -row * POPOUT_BTN)

                        if r.isEmpty then
                            b.icon:SetTexture(emptyTex)
                            b.icon:SetDesaturated(true)
                            do local _ag=RC:GetColor("ui","accentGold"); b.icon:SetVertexColor(_ag.r,_ag.g+0.18>1 and 1 or _ag.g+0.18,_ag.b,1) end
                            b.emptyBg:Show()
                            b._currentItemId = nil
                            b._currentItemLink = nil
                            b._isEmpty = true
                        else
                            local itemLink = r.link or (select(2, GetItemInfo(r.itemId)))
                            local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(r.itemId)
                            tex = tex or r.icon or GetItemIcon(r.itemId) or "Interface\\Icons\\INV_Misc_QuestionMark"
                            b.icon:SetTexture(tex)
                            b.icon:SetDesaturated(false)
                            b.icon:SetVertexColor(1, 1, 1, 1)
                            b.emptyBg:Hide()
                            b._currentItemId   = r.itemId
                            b._currentItemLink = itemLink
                            b._isEmpty = false
                        end

                        b._sel:SetText("")

                        b:SetScript("OnEnter", function(self)
                            self._hbTop:Show(); self._hbBottom:Show()
                            self._hbLeft:Show(); self._hbRight:Show()
                            self._hoverHighlight:Show()
                            popoutMenu:CancelHide()

                            GameTooltip:Hide()
                            C_Timer.After(0.05, function()
                                if not self:IsMouseOver() then return end
                                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                                if self._isEmpty then
                                    GameTooltip:SetText(RCL["No Override"], 1, 1, 0.4)
                                    GameTooltip:AddLine(RCL["Click to clear this slot's override"], 0.8, 0.8, 0.8)
                                elseif self._currentItemLink then
                                    GameTooltip:SetHyperlink(self._currentItemLink)
                                elseif self._currentItemId then
                                    local nm = GetItemInfo(self._currentItemId) or ("Item " .. self._currentItemId)
                                    GameTooltip:SetText(nm, 1, 1, 1)
                                end
                                GameTooltip:Show()
                            end)
                        end)
                        b:SetScript("OnLeave", function(self)
                            self._hbTop:Hide(); self._hbBottom:Hide()
                            self._hbLeft:Hide(); self._hbRight:Hide()
                            self._hoverHighlight:Hide()
                            GameTooltip:Hide()
                            popoutMenu:HideSoon(0.1)
                        end)

                        local rid   = r.itemId
                        local rEnch = r.enchantId
                        b:SetScript("OnClick", function(_, mouseButton)
                            if mouseButton == "RightButton" then return end
                            onPick(rid, rEnch)
                            popoutMenu:Hide()
                        end)
                    end

                    popoutMenu:SetSize(cols * POPOUT_BTN, math.max(totalRows, 1) * POPOUT_BTN)
                end

                local function AnchorPopout(slotButton, preferLeft, growDown)
                    popoutMenu:ClearAllPoints()
                    if growDown then
                        local screenH = UIParent:GetHeight() or 720
                        local btnBottom = slotButton:GetBottom() or 0
                        local mHeight = popoutMenu:GetHeight()
                        if btnBottom - mHeight - 12 < 0 then
                            popoutMenu:SetPoint("BOTTOM", slotButton, "TOP", 0, 2)
                        else
                            popoutMenu:SetPoint("TOP", slotButton, "BOTTOM", 0, -2)
                        end
                        return
                    end

                    local screenW = UIParent:GetWidth() or 1280
                    local btnRight = slotButton:GetRight() or 0
                    local mWidth = popoutMenu:GetWidth()
                    if preferLeft or (btnRight + mWidth + 12 > screenW) then
                        popoutMenu:SetPoint("TOPRIGHT", slotButton, "TOPLEFT", -2, 0)
                    else
                        popoutMenu:SetPoint("TOPLEFT", slotButton, "TOPRIGHT", 2, 0)
                    end
                end

                RebuildTabContent = function()
                    for _, child in ipairs({tabContent:GetChildren()}) do
                        child:Hide()
                        child:SetParent(nil)
                    end
                    for _, region in ipairs({tabContent:GetRegions()}) do
                        if region.Hide then region:Hide() end
                    end

                    local _contentW = (bgsCard:GetWidth() or 0) - 30
                    if _contentW <= 0 then _contentW = 460 end

                    local activeTabKey = frame._gearSwapActiveTab or "onTarget"
                    local isOnTarget   = activeTabKey == "onTarget"
                    local slotMap      = isOnTarget and fe.onTarget or fe.onDeath
                    local enchMap      = isOnTarget and fe.onTargetEnchant or fe.onDeathEnchant
                    local fullSetField = isOnTarget and "gearSet" or "postCombatSet"
                    local legacyKey1   = isOnTarget and "slot1" or "deathSlot1"
                    local legacyKey2   = isOnTarget and "slot2" or "deathSlot2"

                    local cy = -2

                    local setLbl = RC:CreateFontString(tabContent, "OVERLAY", nil, 11)
                    setLbl:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                    setLbl:SetText(RCL["Full Gear Set:"])
                    setLbl:SetTextColor(_gold.r, _gold.g, _gold.b, 1)

                    local cur     = gsCfg[fullSetField] or ""
                    local setLabel = (cur ~= "" and cur) or "None"
                    local setDD   = self.UI:CreateScrollableDropdown(tabContent, 200, setLabel, 12)
                    setDD:SetEmptyText(RCL["No gear sets yet"], RCL["Build one on the Gear Sets page, then pick it here."])
                    local tcW = tabContent:GetWidth() or 0
                    local twoColGear = tcW >= 520
                    if twoColGear then
                        setDD:ClearAllPoints()
                        setDD:SetPoint("TOPRIGHT", tabContent, "TOPRIGHT", 0, -22)
                        setLbl:ClearAllPoints()
                        setLbl:SetPoint("BOTTOMLEFT", setDD, "TOPLEFT", 2, 4)
                    else
                        setLbl:ClearAllPoints()
                        setLbl:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                        cy = cy - 20
                        setDD:ClearAllPoints()
                        setDD:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                        cy = cy - 32
                    end
                    do
                        local setItems = { { text = RCL["None (don't swap)"], value = "" } }
                        for _, sn in ipairs(GatherSets()) do
                            table.insert(setItems, { text = sn, value = sn, icon = GetSetIcon(sn) })
                        end
                        setDD:SetItems(setItems, function(value)
                            RC:SetBossGearSet(gsCfg, fullSetField, value)
                            cur = value
                            RC:SaveConfigurationToProfile()
                        end)
                        setDD:SetSelectedValue(cur, setLabel)
                        -- a saved set that is no longer in the list still
                        -- shows an icon on the closed box
                        if cur ~= "" and setDD.SetSelectedIcon then setDD:SetSelectedIcon(GetSetIcon(cur)) end
                    end

                    local ovrLbl = RC:CreateFontString(tabContent, "OVERLAY", nil, 11)
                    ovrLbl:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                    ovrLbl:SetText(RCL["Or override individual slots:"])
                    ovrLbl:SetTextColor(_gold.r, _gold.g, _gold.b, 1)
                    cy = cy - 22

                    local ICON_SIZE      = 32
                    local ROW_HEIGHT     = 40
                    local LABEL_OFFSET_X = 5
                    local COL_WIDTH      = 130
                    local COL2_X         = COL_WIDTH

                    local layout = {
                        { invSlot = 1,  name = "Head",      x = 0,       y = 0 },
                        { invSlot = 2,  name = "Neck",      x = 0,       y = -ROW_HEIGHT },
                        { invSlot = 3,  name = "Shoulder",  x = 0,       y = -ROW_HEIGHT * 2 },
                        { invSlot = 15, name = "Back",      x = 0,       y = -ROW_HEIGHT * 3 },
                        { invSlot = 5,  name = "Chest",     x = 0,       y = -ROW_HEIGHT * 4 },
                        { invSlot = 4,  name = "Shirt",     x = 0,       y = -ROW_HEIGHT * 5 },
                        { invSlot = 19, name = "Tabard",    x = 0,       y = -ROW_HEIGHT * 6 },
                        { invSlot = 9,  name = "Wrist",     x = 0,       y = -ROW_HEIGHT * 7 },
                        { invSlot = 10, name = "Hands",     x = COL2_X,  y = 0 },
                        { invSlot = 6,  name = "Waist",     x = COL2_X,  y = -ROW_HEIGHT },
                        { invSlot = 7,  name = "Legs",      x = COL2_X,  y = -ROW_HEIGHT * 2 },
                        { invSlot = 8,  name = "Feet",      x = COL2_X,  y = -ROW_HEIGHT * 3 },
                        { invSlot = 11, name = "Ring 1",    x = COL2_X,  y = -ROW_HEIGHT * 4 },
                        { invSlot = 12, name = "Ring 2",    x = COL2_X,  y = -ROW_HEIGHT * 5 },
                        { invSlot = 13, name = "Trinket 1", x = COL2_X,  y = -ROW_HEIGHT * 6 },
                        { invSlot = 14, name = "Trinket 2", x = COL2_X,  y = -ROW_HEIGHT * 7 },
                    }
                    local maxRows = 8

                    local WEAPON_ROW_Y = -(maxRows * ROW_HEIGHT + 8)
                    table.insert(layout, { invSlot = 16, name = "Main Hand", x = 0,                              y = WEAPON_ROW_Y })
                    table.insert(layout, { invSlot = 17, name = "Off Hand",  x = math.floor(COL2_X * 0.5),       y = WEAPON_ROW_Y })
                    table.insert(layout, { invSlot = 18, name = "Ranged",    x = COL2_X,                         y = WEAPON_ROW_Y })

                    local GRID_WIDTH = COL2_X + ICON_SIZE + 70

                    local gridFrame = CreateFrame("Frame", nil, tabContent)
                    gridFrame:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                    local gridHeight = math.abs(WEAPON_ROW_Y) + ICON_SIZE + 18
                    gridFrame:SetSize(GRID_WIDTH, gridHeight)

                    local slotDataByInv = {}
                    for _, sd in ipairs(RC.GEAR_SLOT_ORDER) do
                        slotDataByInv[sd.invSlot] = sd
                    end
                    if not slotDataByInv[4] then
                        slotDataByInv[4] = { invSlot = 4, name = "Shirt",
                                             bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Shirt" }
                    end
                    if not slotDataByInv[19] then
                        slotDataByInv[19] = { invSlot = 19, name = "Tabard",
                                              bgTex = "Interface\\PaperDoll\\UI-PaperDoll-Slot-Tabard" }
                    end

                    for _, slotEntry in ipairs(layout) do
                        local invSlot  = slotEntry.invSlot
                        local slotInfo = slotDataByInv[invSlot]
                        local emptyTex = (slotInfo and slotInfo.bgTex)
                                       or "Interface\\PaperDoll\\UI-PaperDoll-Slot-Background"

                        local btn = CreateFrame("Frame", nil, gridFrame)
                        btn:SetSize(ICON_SIZE, ICON_SIZE)
                        btn:SetPoint("TOPLEFT", gridFrame, "TOPLEFT", slotEntry.x, slotEntry.y)
                        btn:EnableMouse(true)

                        local bg = btn:CreateTexture(nil, "BACKGROUND")
                        bg:SetAllPoints()
                        bg:SetColorTexture(0, 0, 0, 0.8)

                        local iconTex = btn:CreateTexture(nil, "ARTWORK")
                        iconTex:SetAllPoints()
                        iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                        local function MakeBorder(point1, point2, h, w)
                            local t = btn:CreateTexture(nil, "OVERLAY")
                            t:SetColorTexture(0, 0, 0, 1)
                            t:SetPoint(point1, 0, 0)
                            t:SetPoint(point2, 0, 0)
                            if h then t:SetHeight(h) end
                            if w then t:SetWidth(w)  end
                            return t
                        end
                        MakeBorder("TOPLEFT",    "TOPRIGHT",    1, nil)
                        MakeBorder("BOTTOMLEFT", "BOTTOMRIGHT", 1, nil)
                        MakeBorder("TOPLEFT",    "BOTTOMLEFT",  nil, 1)
                        MakeBorder("TOPRIGHT",   "BOTTOMRIGHT", nil, 1)

                        local function MakeHoverBorder(point1, point2, h, w)
                            local t = btn:CreateTexture(nil, "OVERLAY", nil, 2)
                            do local _ag=RC:GetColor("ui","accentGold"); t:SetColorTexture(_ag.r,_ag.g,_ag.b,1) end
                            t:SetPoint(point1, 0, 0)
                            t:SetPoint(point2, 0, 0)
                            if h then t:SetHeight(h) end
                            if w then t:SetWidth(w)  end
                            t:Hide()
                            return t
                        end
                        local hbTop    = MakeHoverBorder("TOPLEFT",    "TOPRIGHT",    1, nil)
                        local hbBottom = MakeHoverBorder("BOTTOMLEFT", "BOTTOMRIGHT", 1, nil)
                        local hbLeft   = MakeHoverBorder("TOPLEFT",    "BOTTOMLEFT",  nil, 1)
                        local hbRight  = MakeHoverBorder("TOPRIGHT",   "BOTTOMRIGHT", nil, 1)

                        local label = RC:CreateFontString(gridFrame, "OVERLAY", nil, 9)
                        local isWeapon = (invSlot == 16 or invSlot == 17 or invSlot == 18)
                        if isWeapon then
                            label:SetPoint("TOP", btn, "BOTTOM", 0, -2)
                            label:SetJustifyH("CENTER")
                        else
                            label:SetPoint("LEFT", btn, "RIGHT", LABEL_OFFSET_X, 0)
                            label:SetJustifyH("LEFT")
                        end
                        label:SetText(slotEntry.name)

                        local function ApplyVisualState()
                            local id = slotMap[invSlot]
                            if id and id ~= 0 then
                                local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(id)
                                tex = tex or GetItemIcon(id) or "Interface\\Icons\\INV_Misc_QuestionMark"
                                iconTex:SetTexture(tex)
                                iconTex:SetDesaturated(false)
                                iconTex:SetVertexColor(1, 1, 1, 1)
                                label:SetTextColor(TEXT.green[1], TEXT.green[2], TEXT.green[3])
                            else
                                iconTex:SetTexture(emptyTex)
                                iconTex:SetDesaturated(true)
                                do local _dc=RC:GetColor("text","disabled"); iconTex:SetVertexColor(_dc.r,_dc.g,_dc.b,1) end
                                label:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
                            end
                        end
                        ApplyVisualState()

                        local function SetSlot(newId, newEnchant)
                            if newId == 0 or newId == nil then
                                slotMap[invSlot] = nil
                                if enchMap then enchMap[invSlot] = nil end
                            else
                                slotMap[invSlot] = newId
                                if enchMap then
                                    enchMap[invSlot] = (newEnchant and newEnchant ~= 0) and newEnchant or nil
                                end
                            end
                            if invSlot == 13 then
                                fe[legacyKey1] = slotMap[invSlot]
                            elseif invSlot == 14 then
                                fe[legacyKey2] = slotMap[invSlot]
                            end
                            RC:SaveConfigurationToProfile()
                            RC:DebugPrint(string.format(
                                RCL["Boss gear swap: %s slot %d (%s) = %s (enchant %s)"],
                                activeTabKey, invSlot, slotEntry.name, tostring(newId),
                                tostring(enchMap and enchMap[invSlot] or 0)),
                                "trinket")
                            ApplyVisualState()
                        end

                        local growDown = IsGrowDownSlot(invSlot)
                        local function OpenPopoutForThisSlot()
                            popoutMenu:CancelHide()
                            local items = GetItemsFitForSlot(invSlot)
                            PopulatePopout(invSlot, slotEntry.name, slotMap[invSlot], items, SetSlot)
                            AnchorPopout(btn, false, growDown)
                            popoutMenu._currentSlotBtn = btn
                            popoutMenu:Show()
                        end

                        btn:SetScript("OnEnter", function()
                            hbTop:Show(); hbBottom:Show(); hbLeft:Show(); hbRight:Show()
                            OpenPopoutForThisSlot()
                        end)
                        btn:SetScript("OnLeave", function()
                            hbTop:Hide(); hbBottom:Hide(); hbLeft:Hide(); hbRight:Hide()
                            popoutMenu:HideSoon(0.1)
                        end)

                        btn:SetScript("OnMouseUp", function(self, mouseButton)
                            if mouseButton == "RightButton" then
                                SetSlot(nil)
                                if popoutMenu:IsShown() then popoutMenu:Hide() end
                                return
                            end
                            if popoutMenu:IsShown()
                               and popoutMenu._currentSlotBtn == self then
                                popoutMenu:Hide()
                            else
                                OpenPopoutForThisSlot()
                            end
                        end)
                    end

                    cy = cy - gridFrame:GetHeight() - 10

                    if slotMap[13] or slotMap[14] then
                        local lockHint = RC:CreateFontString(tabContent, "OVERLAY", nil, 10)
                        lockHint:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                        lockHint:SetWidth(_contentW)
                        lockHint:SetJustifyH("LEFT")
                        if isOnTarget then
                            lockHint:SetText(RCL["Trinket auto-swap is paused on the configured trinket slots while the boss is alive. The lock releases when the boss dies."])
                        else
                            lockHint:SetText(RCL["After the boss dies, the configured trinkets stay locked until you click them - so on-use trinkets don't get yanked off before you can fire them."])
                        end
                        lockHint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                        cy = cy - lockHint:GetStringHeight() - 6
                    end

                    if not isOnTarget then
                        local cfgLbl = RC:CreateFontString(tabContent, "OVERLAY", nil, 11)
                        cfgLbl:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                        cfgLbl:SetText(RCL["Switch trinket auto-swap config:"])
                        cfgLbl:SetTextColor(_gold.r, _gold.g, _gold.b, 1)
                        cy = cy - 20

                        -- The remote toon's trinketSwapSystem (custom queue
                        -- names/order) isn't available locally, so remote
                        -- editing falls back to these generic labels instead
                        -- of whatever names they actually gave their queues.
                        local CANONICAL_CFG = {
                            default = "Default", config1 = "Config 1", config2 = "Config 2",
                            config3 = "Config 3", config4 = "Config 4", config5 = "Config 5",
                        }
                        local CANONICAL_ORDER = { "default", "config1", "config2", "config3", "config4", "config5" }
                        local sys = RC.trinketSwapSystem
                        local function CfgName(key)
                            if not key or key == "" then return "None (keep current)" end
                            if isRemoteRaid then return CANONICAL_CFG[key] or key end
                            return (sys and sys.queueNames and sys.queueNames[key]) or CANONICAL_CFG[key] or key
                        end
                        local cfgItems = { { text = RCL["None (keep current)"], value = "" } }
                        local cfgOrder = (not isRemoteRaid and sys and sys.queueOrder) or CANONICAL_ORDER
                        for _, qKey in ipairs(cfgOrder) do
                            table.insert(cfgItems, { text = CfgName(qKey), value = qKey })
                        end
                        local curCfg = fe.deathConfig or ""
                        local cfgDD = self.UI:CreateScrollableDropdown(tabContent, 280, CfgName(curCfg), 7)
                        cfgDD:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                        cfgDD:SetItems(cfgItems, function(value)
                            fe.deathConfig = (value ~= "" and value) or nil
                            RC:SaveConfigurationToProfile()
                            RC:DebugPrint("Boss death config switch (" .. encounterName .. ") = "
                                .. tostring(fe.deathConfig), "trinket")
                        end)
                        cfgDD:SetSelectedValue(curCfg, CfgName(curCfg))
                        cy = cy - 32

                        local cfgHint = RC:CreateFontString(tabContent, "OVERLAY", nil, 10)
                        cfgHint:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                        cfgHint:SetWidth(_contentW)
                        cfgHint:SetJustifyH("LEFT")
                        cfgHint:SetText(RCL["When this boss dies, trinket auto-swap switches to the chosen config. Mid-combat kills switch the moment combat ends. Per-slot trinkets above still win their slots."])
                        cfgHint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                        cy = cy - cfgHint:GetStringHeight() - 8

                        -- THE GEAR SET PICKER (TE_GearSwap): for the kills
                        -- where the next set is a call made on the day, ask
                        -- instead of swapping. fe.deathPrompt is only written
                        -- once something here is actually changed.
                        local function Prompt(create)
                            if create and type(fe.deathPrompt) ~= "table" then
                                fe.deathPrompt = { enabled = false, sets = {} }
                            end
                            local dp = fe.deathPrompt
                            if type(dp) == "table" and type(dp.sets) ~= "table" then dp.sets = {} end
                            return dp
                        end
                        local dpNow = Prompt(false)

                        local askLbl = RC:CreateFontString(tabContent, "OVERLAY", nil, 11)
                        askLbl:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                        askLbl:SetText(RCL["Or ask me which set to wear:"])
                        askLbl:SetTextColor(_gold.r, _gold.g, _gold.b, 1)
                        cy = cy - 20

                        local askCb = self.UI:CreateCheckbox(tabContent,
                            RCL["Show a gear set picker when this boss dies"], dpNow and dpNow.enabled or false)
                        askCb:ClearAllPoints()
                        askCb:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                        askCb:SetScript("OnClick", function()
                            local dp = Prompt(true)
                            dp.enabled = askCb:GetChecked() and true or false
                            self:ForceCheckboxUpdate(askCb, dp.enabled)
                            RC:SaveConfigurationToProfile()
                            RC:DebugPrint("Gear set picker (" .. encounterName .. ") = " .. tostring(dp.enabled), "gear")
                        end)

                        -- the picker lists THIS character's sets, so there is
                        -- nothing to preview while editing someone else's
                        if not isRemoteRaid then
                            local pvBtn = self.UI:CreateStyledButton(tabContent, RCL["Preview"], 70, 20)
                            pvBtn:SetPoint("TOPRIGHT", tabContent, "TOPRIGHT", 0, cy + 3)
                            pvBtn:SetScript("OnClick", function()
                                local dp = Prompt(false)
                                if RC.ShowGearSetPrompt then
                                    RC:ShowGearSetPrompt(encounterName, dp and dp.sets, true)
                                end
                            end)
                        end
                        cy = cy - 24

                        local offerLbl = RC:CreateFontString(tabContent, "OVERLAY", nil, 10)
                        offerLbl:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy - 4)
                        offerLbl:SetText(RCL["Offer only:"])
                        offerLbl:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                        local chipX0 = (offerLbl:GetStringWidth() or 56) + 8
                        local chipX, chipN = chipX0, 0
                        for _, sn in ipairs(GatherSets()) do
                            local chip = self.UI:CreateStyledButton(tabContent, sn, 60, 20)
                            -- the set's icon at the left, its name after it
                            local chipIco = chip:CreateTexture(nil, "ARTWORK", nil, 2)
                            chipIco:SetSize(14, 14)
                            chipIco:SetPoint("LEFT", chip, "LEFT", 4, 0)
                            chipIco:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                            chipIco:SetTexture(GetSetIcon(sn))
                            chip.setIcon = chipIco
                            chip.text:ClearAllPoints()
                            chip.text:SetPoint("LEFT", chipIco, "RIGHT", 4, 0)
                            local w = math.max(48, (chip.text:GetStringWidth() or 40) + 30)
                            chip:SetWidth(w)
                            if chipX > chipX0 and chipX + w > _contentW then
                                chipX = chipX0
                                cy = cy - 24
                            end
                            chip:SetPoint("TOPLEFT", tabContent, "TOPLEFT", chipX, cy)
                            chipX = chipX + w + 4
                            chipN = chipN + 1
                            chip:SetActive(dpNow and dpNow.sets and dpNow.sets[sn] and true or false)
                            chip:SetScript("OnClick", function()
                                local dp = Prompt(true)
                                dp.sets[sn] = (not dp.sets[sn]) and true or nil
                                chip:SetActive(dp.sets[sn] and true or false)
                                RC:SaveConfigurationToProfile()
                                -- (a hand-made toggle: the picker's preview follows)
                                RC.UI:NotifySettingChanged("gearprompt")
                            end)
                        end
                        if chipN == 0 then
                            offerLbl:SetText(RCL["No gear sets yet - build one on the Gear Sets page."])
                        end
                        cy = cy - 28

                        local askHint = RC:CreateFontString(tabContent, "OVERLAY", nil, 10)
                        askHint:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                        askHint:SetWidth(_contentW)
                        askHint:SetJustifyH("LEFT")
                        askHint:SetText(RCL["For kills where the next set depends on the plan. The picker stays up until you pick a set, close it, or pull the next boss; picking one equips it (or queues it if you are still in combat). Highlight sets to offer only those - with none highlighted it lists them all. Place it with Edit Mode."])
                        askHint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                        cy = cy - askHint:GetStringHeight() - 8
                    end

                    local refBtn = self.UI:CreateStyledButton(tabContent, RCL["Refresh Item List"], 130, 22)
                    refBtn:SetPoint("TOPLEFT", tabContent, "TOPLEFT", 0, cy)
                    refBtn:SetScript("OnClick", function()
                        if RC.trinketSwapSystem then
                            RC.trinketSwapSystem.lastScanTime = 0
                            RC.trinketSwapSystem.bagLocationLookup = {}
                        end
                        if RC.ScanAvailableTrinkets then RC:ScanAvailableTrinkets() end
                        if RebuildTabContent then RebuildTabContent() end
                    end)
                    cy = cy - 28

                    tabContent:SetHeight(math.abs(cy) + 4)
                    bgsCard:SetContentHeight(math.abs(by) + tabContent:GetHeight() + 4)
                end

                RebuildTabContent()
                yPos = yPos - bgsCard:GetHeight() - 15

            elseif activeTab == "fungal" and encounterName == "Loatheb" then
                -- Loatheb-only: swaps gear on Fungal Bloom (spell 29232)
                -- gain/loss independently of the ability grid above; synced
                -- via GearManager:SyncFungalBloom rather than the normal
                -- forceEquip path.
                local GM = RC.GearManager
                if not encounterSettings.fungalBloom then
                    encounterSettings.fungalBloom = {
                        enabled    = false,
                        activeSet  = "",
                        falloffSet = "",
                    }
                end
                local fb = encounterSettings.fungalBloom

                local fbCard = self:CreateSettingsCard(parent, yPos, RCL["Fungal Bloom auto-swap"])
                local fcy = -35

                local hint = self:CreateFontString(fbCard, "OVERLAY", nil, 10)
                hint:SetPoint("TOPLEFT", fbCard, "TOPLEFT", 15, fcy)
                hint:SetWidth(fbCard:GetWidth() - 30)
                hint:SetJustifyH("LEFT")
                hint:SetText(RCL["Automatically swap gear sets when Fungal Bloom (spell 29232) is gained or removed. Saved per raid profile."])
                hint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                fcy = fcy - hint:GetStringHeight() - 10

                local enCb = self.UI:CreateCheckbox(fbCard, RCL["Enable Fungal Bloom auto-swap"], fb.enabled)
                enCb:SetPoint("TOPLEFT", fbCard, "TOPLEFT", 15, fcy)
                enCb:SetScript("OnClick", function()
                    fb.enabled = enCb:GetChecked()
                    self:ForceCheckboxUpdate(enCb, fb.enabled)
                    RC:SaveConfigurationToProfile()
                    if RC.GearManager and RC.GearManager.SyncFungalBloom then
                        RC.GearManager:SyncFungalBloom()
                    end
                end)
                fcy = fcy - 28
                local fbMark = self.UI:MarkCard(fbCard)

                local function BuildSetList()
                    local items = {{text=RCL["None"], value=""}}
                    local allSets = RC:GetAllGearSets()
                    for _, entry in ipairs(allSets) do
                        local label = entry.source == "ItemRack"
                            and entry.name .. " (ItemRack)"
                            or  entry.name
                        table.insert(items, {
                            text  = label,
                            value = entry.name,
                            -- the remote-edit list carries names only
                            icon  = entry.icon or RC:GetGearSetIcon(entry.name),
                        })
                    end
                    return items
                end

                local onLbl = self:CreateFontString(fbCard, "OVERLAY", nil, 11)
                onLbl:SetPoint("TOPLEFT", fbCard, "TOPLEFT", 15, fcy)
                onLbl:SetText(RCL["Set to equip when debuff GAINS:"])
                local _fbGold = RC:GetColor("ui", "accentGold") or {r=0.85,g=0.65,b=0.25}
                onLbl:SetTextColor(_fbGold.r, _fbGold.g, _fbGold.b, 1)
                fcy = fcy - 22

                local onDD = self.UI:CreateScrollableDropdown(fbCard, fbCard:GetWidth() - 30,
                    (fb.activeSet ~= "" and fb.activeSet) or RCL["None"], 10)
                onDD:SetPoint("TOPLEFT", fbCard, "TOPLEFT", 15, fcy)
                if onDD.menu then onDD.menu:SetFrameStrata("TOOLTIP"); onDD.menu:SetFrameLevel(200) end
                onDD:SetItems(BuildSetList(), function(val, _)
                    fb.activeSet = val or ""
                    RC:SaveConfigurationToProfile()
                    RC:DebugPrint("Fungal Bloom activeSet = " .. (val or "none"), "gear")
                    if RC.GearManager and RC.GearManager.SyncFungalBloom then
                        RC.GearManager:SyncFungalBloom()
                    end
                end)
                onDD:SetSelectedValue(fb.activeSet, (fb.activeSet ~= "" and fb.activeSet) or "None")
                if fb.activeSet ~= "" and onDD.SetSelectedIcon then onDD:SetSelectedIcon(RC:GetGearSetIcon(fb.activeSet)) end
                fcy = fcy - 32

                local offLbl = self:CreateFontString(fbCard, "OVERLAY", nil, 11)
                offLbl:SetPoint("TOPLEFT", fbCard, "TOPLEFT", 15, fcy)
                offLbl:SetText(RCL["Set to equip when debuff FALLS OFF:"])
                offLbl:SetTextColor(_fbGold.r, _fbGold.g, _fbGold.b, 1)
                fcy = fcy - 22

                local offDD = self.UI:CreateScrollableDropdown(fbCard, fbCard:GetWidth() - 30,
                    (fb.falloffSet ~= "" and fb.falloffSet) or RCL["None"], 10)
                offDD:SetPoint("TOPLEFT", fbCard, "TOPLEFT", 15, fcy)
                if offDD.menu then offDD.menu:SetFrameStrata("TOOLTIP"); offDD.menu:SetFrameLevel(200) end
                offDD:SetItems(BuildSetList(), function(val, _)
                    fb.falloffSet = val or ""
                    RC:SaveConfigurationToProfile()
                    RC:DebugPrint("Fungal Bloom falloffSet = " .. (val or "none"), "gear")
                    if RC.GearManager and RC.GearManager.SyncFungalBloom then
                        RC.GearManager:SyncFungalBloom()
                    end
                end)
                offDD:SetSelectedValue(fb.falloffSet, (fb.falloffSet ~= "" and fb.falloffSet) or "None")
                if fb.falloffSet ~= "" and offDD.SetSelectedIcon then offDD:SetSelectedIcon(RC:GetGearSetIcon(fb.falloffSet)) end
                fcy = fcy - 32
                -- the two sets only swap with the auto-swap on (the full-width
                -- pickers stay in their column: greyed, not set in)
                self.UI:BindDependents(enCb, self.UI:CardSince(fbCard, fbMark), { indent = 0 })


                local hasSets = (GM and GM.sets and next(GM.sets)) or
                                (RC.itemRackIntegration and RC.itemRackIntegration.sets and #RC.itemRackIntegration.sets > 0)
                if not hasSets then
                    local warnLbl = self:CreateFontString(fbCard, "OVERLAY", nil, 10)
                    warnLbl:SetPoint("TOPLEFT", fbCard, "TOPLEFT", 15, fcy)
                    warnLbl:SetText(RCL["No gear sets found - create sets in the Gear Manager or ItemRack first."])
                    do local _wc=RC:GetColor("text","buttonHover"); warnLbl:SetTextColor(_wc.r,_wc.g,_wc.b,1) end
                    fcy = fcy - 18
                end

                fbCard:SetContentHeight(math.abs(fcy))
                yPos = yPos - fbCard:GetHeight() - 15

            elseif activeTab == "horsemen" and encounterName == "Four Horsemen" then
                -- Four Horsemen has a group config (this page, keyed "Four
                -- Horsemen") AND up to 4 independent per-horseman configs (keyed by
                -- each horseman's own name, opened via hBtn's OnClick below). The
                -- group config is what fires if a horseman has no abilities enabled
                -- under their own key - see the hint text rendered above.
                local hmCard = self:CreateSettingsCard(parent, yPos, RCL["Individual Horseman config"])
                local hcy = -35

                local hmHint = self:CreateFontString(hmCard, "OVERLAY", nil, 10)
                hmHint:SetPoint("TOPLEFT", hmCard, "TOPLEFT", 15, hcy)
                hmHint:SetWidth(hmCard:GetWidth() - 30)
                hmHint:SetJustifyH("LEFT")
                hmHint:SetText(RCL["Configure reminders per horseman. If no individual abilities are enabled for a horseman, the Four Horsemen group config above applies when targeting them."])
                hmHint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                hcy = hcy - (hmHint:GetStringHeight() + 10)

                local col = 0
                local rowFrame
                for _, horseName in ipairs(HORSEMEN) do
                    local hasEnabled = false
                    if raidSettings.bosses[horseName] and raidSettings.bosses[horseName].abilities then
                        for _, abCfg in pairs(raidSettings.bosses[horseName].abilities) do
                            if abCfg.enabled then hasEnabled = true; break end
                        end
                    end

                    if col == 0 then
                        rowFrame = CreateFrame("Frame", nil, hmCard)
                        rowFrame:SetHeight(34)
                        rowFrame:SetPoint("TOPLEFT", hmCard, "TOPLEFT", 10, hcy)
                        rowFrame:SetPoint("RIGHT",   hmCard, "RIGHT",   -10, 0)
                    end

                    local hBtn = CreateFrame("Button", nil, rowFrame, "BackdropTemplate")
                    hBtn:SetHeight(34)
                    local sbSel  = RC:GetColor("sidebar", "buttonSelected")
                    local sbNorm = RC:GetColor("sidebar", "buttonNormal")
                    local sbHov  = RC:GetColor("sidebar", "buttonHover")
                    local sbCH   = RC:GetColor("buttons",  "configuredHover")
                    local txtSel = RC:GetColor("text", "menuSelected")
                    local txtNorm= RC:GetColor("text", "menuNormal")

                    if col == 0 then
                        hBtn:SetPoint("LEFT",  rowFrame, "LEFT",   0, 0)
                        hBtn:SetPoint("RIGHT", rowFrame, "CENTER", -4, 0)
                    else
                        hBtn:SetPoint("LEFT",  rowFrame, "CENTER", 4, 0)
                        hBtn:SetPoint("RIGHT", rowFrame, "RIGHT",  0, 0)
                    end

                    hBtn:SetBackdrop({ bgFile = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
                    if hasEnabled then
                        hBtn:SetBackdropColor(sbSel.r,  sbSel.g,  sbSel.b,  1)
                        do local _bn = RC:GetColor("ui", "borderNormal"); hBtn:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
                    else
                        hBtn:SetBackdropColor(sbNorm.r, sbNorm.g, sbNorm.b, 0.9)
                        do local _bn = RC:GetColor("ui", "borderNormal"); hBtn:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
                    end
                    hBtn.isEnabled = hasEnabled
                    hBtn.sbSel = sbSel; hBtn.sbNorm = sbNorm
                    hBtn.sbHov = sbHov; hBtn.sbCH   = sbCH

                    local hIcon = hBtn:CreateTexture(nil, "ARTWORK")
                    hIcon:SetSize(22, 22)
                    hIcon:SetPoint("LEFT", hBtn, "LEFT", 6, 0)
                    hIcon:SetTexture(RC.bossIcons and RC.bossIcons[horseName] or "Interface\\Icons\\Ability_Creature_Cursed_02")

                    local hLbl = self:CreateFontString(hBtn, "OVERLAY", nil, 11)
                    hLbl:SetPoint("LEFT", hIcon, "RIGHT", 6, 0)
                    hLbl:SetPoint("RIGHT", hBtn, "RIGHT", -4, 0)
                    hLbl:SetJustifyH("LEFT")
                    local shortName = horseName:gsub("Highlord ", ""):gsub("Thane ", ""):gsub("Lady ", ""):gsub("Sir ", "")
                    hLbl:SetText(shortName)
                    hLbl:SetTextColor(hasEnabled and txtSel.r or txtNorm.r, hasEnabled and txtSel.g or txtNorm.g, hasEnabled and txtSel.b or txtNorm.b)

                    hBtn:SetScript("OnEnter", function(self)
                        self:SetBackdropColor(self.isEnabled and self.sbCH.r or self.sbHov.r, self.isEnabled and self.sbCH.g or self.sbHov.g, self.isEnabled and self.sbCH.b or self.sbHov.b, 1)
                    end)
                    hBtn:SetScript("OnLeave", function(self)
                        self:SetBackdropColor(self.isEnabled and self.sbSel.r or self.sbNorm.r, self.isEnabled and self.sbSel.g or self.sbNorm.g, self.isEnabled and self.sbSel.b or self.sbNorm.b, self.isEnabled and 1 or 0.9)
                    end)
                    local _hn = horseName
                    hBtn:SetScript("OnClick", function()
                        RC:ShowInlineAbilityConfig(frame, raidName, _hn, "boss", raidSettings)
                    end)

                    col = col + 1
                    if col >= 2 then
                        col = 0
                        hcy = hcy - 38
                    end
                end
                if col > 0 then hcy = hcy - 38 end
                hcy = hcy - 8
                hmCard:SetContentHeight(math.abs(hcy))
                yPos = yPos - hmCard:GetHeight() - 15

            elseif activeTab == "history" then
                local histCard = self:CreateSettingsCard(parent, yPos, RCL["Kill history - "] .. encounterName)
                local cy = -35

                -- Flags fights whose time is more than olThresh standard
                -- deviations from the mean (needs >= 3 timed fights to
                -- compute a standard deviation at all); outliers are excluded
                -- from the avg/best/worst summary below but stay in the list.
                local outlierInfo = {}
                local olThresh = (self.executeCalculator and self.executeCalculator.mlConfig and self.executeCalculator.mlConfig.outlierThreshold) or 2.0
                if fights and #fights >= 3 then
                    local times = {}
                    for _, f in ipairs(fights) do if f.totalFightTime and f.totalFightTime > 0 then table.insert(times, f.totalFightTime) end end
                    if #times >= 3 then
                        local sum = 0; for _, v in ipairs(times) do sum = sum + v end
                        local mean = sum / #times
                        local var  = 0; for _, v in ipairs(times) do var = var + (v - mean)^2 end
                        local sd   = math.sqrt(var / #times)
                        if sd > 0 then
                            for i, f in ipairs(fights) do
                                if f.totalFightTime and math.abs((f.totalFightTime - mean) / sd) > olThresh then
                                    outlierInfo[i] = true
                                end
                            end
                        end
                    end
                end

                local fightCount = fights and #fights or 0

                if fightCount > 0 then
                    local tot, mn, mx, valid, ol = 0, math.huge, 0, 0, 0
                    for i, f in ipairs(fights) do
                        if f.totalFightTime and f.totalFightTime > 0 then
                            if outlierInfo[i] then ol = ol + 1
                            else tot = tot + f.totalFightTime; mn = math.min(mn, f.totalFightTime); mx = math.max(mx, f.totalFightTime); valid = valid + 1 end
                        end
                    end
                    if valid > 0 then
                        local avg = tot / valid
                        local s = string.format(RCL["%d kills  |  Avg: %d:%02d  |  Best: %d:%02d  |  Worst: %d:%02d"],
                            fightCount, math.floor(avg/60), math.floor(avg%60), math.floor(mn/60), math.floor(mn%60), math.floor(mx/60), math.floor(mx%60))
                        if ol > 0 then s = s .. string.format(RCL["  |cffff6666(%d outlier%s)|r"], ol, ol > 1 and "s" or "") end
                        local sl = self:CreateFontString(histCard, "OVERLAY", nil, 11)
                        sl:SetPoint("TOPLEFT", histCard, "TOPLEFT", 15, cy)
                        sl:SetText(s)
                        sl:SetTextColor(TEXT.greenBright[1], TEXT.greenBright[2], TEXT.greenBright[3])

                        -- what the reminders will actually go by
                        if self.PredictTTK then
                            local pred, _, used = self:PredictTTK(raidName, histBoss)
                            local pl = self:CreateFontString(histCard, "OVERLAY", nil, 10)
                            pl:SetPoint("TOPLEFT", sl, "BOTTOMLEFT", 0, -4)
                            if pred then
                                pl:SetText(string.format((linkedConfigs or 0) > 0
                                    and RCL["Predicted kill time: %s, from %d kills (related configs included)"]
                                    or  RCL["Predicted kill time: %s, from %d kills"],
                                    RC:FormatTime(pred), used or 0))
                            else
                                pl:SetText(RCL["Not enough kills for a prediction yet - reminders go by this pull's own speed."])
                            end
                            pl:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])
                            cy = cy - 16
                        end

                        local saygeTotal, saygeCount = 0, 0
                        for _, f in ipairs(fights) do
                            if f.hasSayge and f.totalFightTime and f.totalFightTime > 0 then
                                saygeTotal = saygeTotal + f.totalFightTime
                                saygeCount = saygeCount + 1
                            end
                        end
                        if saygeCount > 0 then
                            local saygeAvg = saygeTotal / saygeCount
                            local saygeIcon = histCard:CreateTexture(nil, "ARTWORK")
                            saygeIcon:SetSize(12, 12)
                            saygeIcon:SetPoint("TOPLEFT", histCard, "TOPLEFT", 15, cy - 18)
                            saygeIcon:SetTexture("Interface\\Icons\\inv_misc_orb_02")
                            saygeIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                            local saygeAvgText = self:CreateFontString(histCard, "OVERLAY", nil, 10)
                            saygeAvgText:SetPoint("LEFT", saygeIcon, "RIGHT", 3, 0)
                            saygeAvgText:SetText(string.format(RCL["Sayge avg: |cff00ff00%ds|r  (%d kill%s)"],
                                math.floor(saygeAvg + 0.5), saygeCount, saygeCount == 1 and "" or "s"))
                            saygeAvgText:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3])
                            cy = cy - 18
                        end
                    end
                else
                    local nl = self:CreateFontString(histCard, "OVERLAY", nil, 11)
                    nl:SetPoint("TOPLEFT", histCard, "TOPLEFT", 15, cy)
                    nl:SetText(RCL["No kills recorded yet - data is collected automatically during raids."])
                    nl:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                end
                cy = cy - 22

                if fightCount > 0 then
                    local hy = cy - 4
                    local gc = {TEXT.gray[1], TEXT.gray[2], TEXT.gray[3]}
                    local function H(x, w, t)
                        local h = self:CreateFontString(histCard, "OVERLAY", nil, 9)
                        h:SetPoint("TOPLEFT", histCard, "TOPLEFT", x, hy)
                        h:SetWidth(w); h:SetText(t); h:SetTextColor(gc[1], gc[2], gc[3])
                    end
                    H(15, 20, "#"); H(35, 56, "Time"); H(89, 80, "Date"); H(173, 50, "Source"); H(225, 30, "DMF"); H(243, 30, RCL["Class"]); H(276, 90, "Profile")
                    cy = hy - 16

                    local hintFS = self:CreateFontString(histCard, "OVERLAY", nil, 10)
                    hintFS:SetPoint("TOPLEFT", histCard, "TOPLEFT", 15, cy)
                    hintFS:SetText(RCL["Right-click a row to edit the fight time"])
                    hintFS:SetTextColor(TEXT.dimGray[1], TEXT.dimGray[2], TEXT.dimGray[3])
                    cy = cy - 14

                    local rowH   = 18
                    local maxVis = 12
                    local listH  = math.min(fightCount, maxVis) * rowH
                    local needsScroll = fightCount > maxVis
                    local sbW = needsScroll and 10 or 0

                    local sc2 = CreateFrame("Frame", nil, histCard)
                    sc2:SetPoint("TOPLEFT",  histCard, "TOPLEFT",  10, cy)
                    sc2:SetPoint("TOPRIGHT", histCard, "TOPRIGHT", -10, cy)
                    sc2:SetHeight(listH)

                    local sfRightOffset = needsScroll and -(sbW + 4) or 0
                    local sf = CreateFrame("ScrollFrame", nil, sc2)
                    sf:SetPoint("TOPLEFT",  sc2, "TOPLEFT",  0, 0)
                    sf:SetPoint("BOTTOMRIGHT", sc2, "BOTTOMRIGHT", sfRightOffset, 0)

                    local child = CreateFrame("Frame", nil, sf)
                    local initialListW = histCard:GetWidth()
                    if not initialListW or initialListW <= 0 then initialListW = 300 end
                    initialListW = initialListW - 20 - (needsScroll and sbW + 4 or 0)
                    if initialListW < 100 then initialListW = 100 end
                    child:SetSize(initialListW, fightCount * rowH)
                    sf:SetScrollChild(child)

                    local rowBGs = {}
                    sf:SetScript("OnSizeChanged", function(_, w)
                        if not w or w <= 0 then return end
                        child:SetWidth(w)
                    end)

                    local listW = initialListW

                    local maxScroll = math.max(0, fightCount * rowH - listH)

                    if needsScroll then
                        local sbTrack = CreateFrame("Frame", nil, sc2, "BackdropTemplate")
                        sbTrack:SetPoint("TOPLEFT",    sf, "TOPRIGHT",    4,  0)
                        sbTrack:SetPoint("BOTTOMLEFT", sf, "BOTTOMRIGHT", 4,  0)
                        sbTrack:SetWidth(sbW)
                        sbTrack:SetBackdrop({
                            bgFile   = "Interface\\Buttons\\WHITE8X8",
                            edgeFile = "Interface\\Buttons\\WHITE8X8",
                            edgeSize = 1,
                        })
                        local _sbTrk = RC:GetColor("scrollbar", "track")
                        local _acG = RC:GetColor("ui", "accentGold")
                        sbTrack:SetBackdropColor(_sbTrk.r, _sbTrk.g, _sbTrk.b, 0.7)
                        -- Dim gold rim, derived from the theme accent the same
                        -- way the thumb below is.
                        sbTrack:SetBackdropBorderColor(_acG.r * 0.24, _acG.g * 0.26, _acG.b * 0.40, 0.6)

                        local thumbH = math.max(16, math.floor((listH / (fightCount * rowH)) * (listH - 4)))
                        local thumbTex = sbTrack:CreateTexture(nil, "OVERLAY")
                        thumbTex:SetColorTexture(_acG.r * 0.55, _acG.g * 0.40, 0.05, 0.85)
                        thumbTex:SetSize(sbW - 4, thumbH)
                        thumbTex:SetPoint("TOPLEFT", sbTrack, "TOPLEFT", 2, -2)

                        local function UpdateThumb(scrollVal)
                            local trackRange = (listH - 4) - thumbH
                            if trackRange <= 0 then return end
                            local pct = scrollVal / maxScroll
                            thumbTex:SetPoint("TOPLEFT", sbTrack, "TOPLEFT", 2, -(2 + pct * trackRange))
                        end

                        local scrollVal = 0
                        sc2:EnableMouseWheel(true)
                        sc2:SetScript("OnMouseWheel", function(_, d)
                            scrollVal = math.max(0, math.min(maxScroll, scrollVal - d * rowH * 3))
                            sf:SetVerticalScroll(scrollVal)
                            UpdateThumb(scrollVal)
                        end)

                        sbTrack:EnableMouse(true)
                        sbTrack:SetScript("OnMouseDown", function(_, btn)
                            if btn ~= "LeftButton" then return end
                            local _, curY = GetCursorPosition()
                            curY = curY / UIParent:GetEffectiveScale()
                            local trackAbsTop = sbTrack:GetTop()
                            if not trackAbsTop then return end
                            local clickPct = math.max(0, math.min(1, (trackAbsTop - curY) / (listH - 4)))
                            scrollVal = clickPct * maxScroll
                            sf:SetVerticalScroll(scrollVal)
                            UpdateThumb(scrollVal)
                        end)
                    end

                    local activeProfileForLabel = "-"
                    if RC.GetActiveProfileNameForRaid then
                        activeProfileForLabel = RC:GetActiveProfileNameForRaid(raidName) or "-"
                    end

                    -- One-time migration, run on render: fights recorded
                    -- before per-fight profile tagging existed get labeled
                    -- with the profile of the bucket they are filed under
                    -- (never the active one: a kill filed under another
                    -- config and stamped with this one would be thrown
                    -- out as misfiled on the next reload), then saved so
                    -- this only has to run once per fight record. Kills
                    -- in the pre-profile bucket stay unnamed.
                    local backfilled = false
                    for i = 1, fightCount do
                        local f = fights[i]
                        if f and (not f.profileName or f.profileName == "") then
                            local k = fightKeyOf[f] or bossKey
                            local kp = RC.TTKKeyProfile and RC.TTKKeyProfile(k)
                            if kp and kp ~= "" then
                                f.profileName = kp
                                backfilled = true
                            end
                        end
                    end
                    if backfilled and RC.SaveExecuteSettings then
                        RC:SaveExecuteSettings()
                    end

                    for i = 1, fightCount do
                        local f    = fights[i]
                        local ry   = -((i-1) * rowH)
                        local isOl = outlierInfo[i]

                        local bg = child:CreateTexture(nil, "BACKGROUND")
                        bg:SetPoint("TOPLEFT",  child, "TOPLEFT",  0, ry + 2)
                        bg:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, ry + 2)
                        bg:SetHeight(rowH)
                        if isOl then local _ec=RC:GetColor("buttons","closeNormal"); bg:SetColorTexture(_ec.r*0.18,_ec.g*0.06,_ec.b*0.06,1)
                        else bg:SetColorTexture(i%2==0 and 0.13 or 0.07, i%2==0 and 0.12 or 0.06, i%2==0 and 0.09 or 0.05, i%2==0 and 0.55 or 0.35) end
                        rowBGs[#rowBGs + 1] = bg

                        local rowClick = CreateFrame("Frame", nil, child)
                        rowClick:SetPoint("TOPLEFT",  child, "TOPLEFT",  0, ry + 2)
                        rowClick:SetPoint("TOPRIGHT", child, "TOPRIGHT", -18, ry + 2)
                        rowClick:SetHeight(rowH)
                        rowClick:EnableMouse(true)
                        rowClick:SetFrameLevel((child:GetFrameLevel() or 0) + 1)

                        local it = self:CreateFontString(child, "OVERLAY", nil, 10)
                        it:SetPoint("TOPLEFT", child, "TOPLEFT", 5, ry); it:SetWidth(20); it:SetText(i)
                        it:SetTextColor(TEXT.dimGray[1], TEXT.dimGray[2], TEXT.dimGray[3])

                        local ft = f.totalFightTime or 0
                        local tf = RC:FormatTime(ft)
                        local tt = self:CreateFontString(child, "OVERLAY", nil, 10)
                        tt:SetPoint("TOPLEFT", child, "TOPLEFT", 25, ry); tt:SetWidth(56)
                        if isOl then local _ec=RC:GetColor("buttons","closeNormal"); tt:SetText(tf.." !"); tt:SetTextColor(_ec.r,_ec.g*0.4,_ec.b*0.4)
                        else tt:SetText(tf); tt:SetTextColor(TEXT.bright[1], TEXT.bright[2], TEXT.bright[3]) end

                        local dt = self:CreateFontString(child, "OVERLAY", nil, 10)
                        dt:SetPoint("TOPLEFT", child, "TOPLEFT", 79, ry); dt:SetWidth(80)
                        dt:SetText(f.timestamp and date("%m/%d %H:%M", f.timestamp) or "-")
                        dt:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])

                        local st2 = self:CreateFontString(child, "OVERLAY", nil, 10)
                        st2:SetPoint("TOPLEFT", child, "TOPLEFT", 163, ry); st2:SetWidth(50)
                        if f.isManualEntry then st2:SetText(RCL["Manual"]); do local _c = self:GetColor("text", "blue"); st2:SetTextColor(_c.r, _c.g, _c.b, _c.a) end
                        elseif f.isTestFight then st2:SetText(RCL["Test"]); do local _c = self:GetColor("text", "orange"); st2:SetTextColor(_c.r, _c.g, _c.b, _c.a) end
                        else st2:SetText(RCL["Combat"]); do local _c = self:GetColor("text", "green"); st2:SetTextColor(_c.r, _c.g, _c.b, _c.a) end end

                        local saygeBtn = CreateFrame("Button", nil, child)
                        saygeBtn:SetSize(14, 14)
                        saygeBtn:SetPoint("TOPLEFT", child, "TOPLEFT", 216, ry)
                        saygeBtn:SetFrameLevel((child:GetFrameLevel() or 0) + 5)
                        local saygeIco = saygeBtn:CreateTexture(nil, "ARTWORK")
                        saygeIco:SetAllPoints()
                        saygeIco:SetTexture("Interface\\Icons\\inv_misc_orb_02")
                        saygeIco:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        local saygeLit = (f.hasSayge == true) or (f.hasSayge == 1) or (f.hasSayge == "true")
                        local function PaintSayge()
                            if saygeLit then
                                saygeIco:SetDesaturated(false)
                                saygeIco:SetVertexColor(1, 1, 1)
                                saygeIco:SetAlpha(1)
                            else
                                if not saygeIco:SetDesaturated(true) then
                                    saygeIco:SetVertexColor(0.35, 0.35, 0.35)
                                end
                                saygeIco:SetAlpha(0.3)
                            end
                        end
                        PaintSayge()
                        saygeBtn:SetScript("OnEnter", function(sb)
                            GameTooltip:SetOwner(sb, "ANCHOR_RIGHT")
                            GameTooltip:SetText(RCL["Darkmoon Faire buff: "] .. (saygeLit and "yes" or "no"), 1, 1, 1)
                            GameTooltip:AddLine(RCL["Click to toggle for this kill."], 0.7, 0.7, 0.7)
                            GameTooltip:Show()
                        end)
                        saygeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
                        saygeBtn:SetScript("OnClick", function()
                            saygeLit = not saygeLit
                            f.hasSayge = saygeLit
                            PaintSayge()
                            if RC.SaveExecuteSettings then RC:SaveExecuteSettings() end
                            local MS = RC.MeshSync
                            if MS and MS.Push then MS:Push("executeCalc", nil, nil, true) end
                        end)

                        -- the class the kill was played on
                        local clsBtn = CreateFrame("Button", nil, child)
                        clsBtn:SetSize(14, 14)
                        clsBtn:SetPoint("TOPLEFT", child, "TOPLEFT", 237, ry)
                        clsBtn:SetFrameLevel((child:GetFrameLevel() or 0) + 5)
                        local clsIco = clsBtn:CreateTexture(nil, "ARTWORK")
                        clsIco:SetAllPoints()
                        local fCls = RC.FightClass and RC:FightClass(f) or nil
                        if RC.PaintClassIcon then RC:PaintClassIcon(clsIco, fCls) else clsBtn:Hide() end
                        clsBtn:SetScript("OnEnter", function(cb)
                            GameTooltip:SetOwner(cb, "ANCHOR_RIGHT")
                            if RC.ClassLabelColored then
                                if fCls then
                                    GameTooltip:SetText(RCL["Played as "] .. RC:ClassLabelColored(fCls), 1, 1, 1)
                                else
                                    GameTooltip:SetText(RCL["Class not recorded"], 1, 1, 1)
                                end
                            end
                            GameTooltip:AddLine(RCL["Right-click the row to edit this kill."], 0.7, 0.7, 0.7)
                            GameTooltip:Show()
                        end)
                        clsBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

                        local profLabel = f.profileName
                        if not profLabel or profLabel == "" then profLabel = activeProfileForLabel end
                        local profDisplay = profLabel
                        if #profDisplay > 20 then profDisplay = profDisplay:sub(1, 19) .. ".." end
                        local pf = self:CreateFontString(child, "OVERLAY", nil, 10)
                        pf:SetPoint("TOPLEFT",  child, "TOPLEFT",  257, ry)
                        pf:SetPoint("TOPRIGHT", child, "TOPRIGHT", -22, ry)
                        pf:SetText(profDisplay)
                        pf:SetJustifyH("LEFT")
                        local _c = self:GetColor("text", "gold"); pf:SetTextColor(_c.r, _c.g, _c.b, _c.a)

                        local fi = i
                        local del = self:CreateXCloseButton(child, 14, function()
                            -- out of the bucket the kill really lives in
                            -- (the list on screen is a copy)
                            local data = RC.executeCalculator and RC.executeCalculator.fightHistory
                                and RC.executeCalculator.fightHistory.data
                            local k = fightKeyOf[f] or bossKey
                            local list = data and k and data[k]
                            if type(list) == "table" then
                                for j = #list, 1, -1 do
                                    if list[j] == f then table.remove(list, j) break end
                                end
                                if #list == 0 then data[k] = nil end
                            end
                            -- a kill copied into related configs shows here
                            -- once; take the copies too, or the next one
                            -- would just step into its place
                            local Mark = RC.TTKKillMark
                            local activeProf = RC.GetActiveProfileNameForRaid and RC:GetActiveProfileNameForRaid(raidName)
                            local fam = activeProf and RC.TTKConfigFamily and RC:TTKConfigFamily(activeProf)
                            if data and Mark and RC.TTKKeyProfile and (linkedConfigs or 0) > 0 and fam then
                                local m = Mark(f)
                                local suffix = "_" .. histBoss
                                for dk, dl in pairs(data) do
                                    if type(dk) == "string" and type(dl) == "table"
                                       and dk:sub(1, #raidName + 1) == raidName .. "|" and dk:sub(-#suffix) == suffix then
                                        local kp = RC.TTKKeyProfile(dk)
                                        if kp and kp ~= "" and RC:TTKConfigFamily(kp) == fam then
                                            for j = #dl, 1, -1 do
                                                if type(dl[j]) == "table" and Mark(dl[j]) == m then table.remove(dl, j) end
                                            end
                                            if #dl == 0 then data[dk] = nil end
                                        end
                                    end
                                end
                            end
                            RC:SaveExecuteSettings()
                            RC:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings)
                        end)
                        del:SetPoint("TOPRIGHT", child, "TOPRIGHT", -2, ry + 2)

                        rowClick:SetScript("OnMouseUp", function(_, btn)
                            if btn ~= "RightButton" then return end
                            local cf = fights and fights[fi]
                            if not cf then return end
                            if RC.ShowFightEditDialog then
                                RC:ShowFightEditDialog(cf, fightKeyOf[cf] or bossKey, function()
                                    if RC.SaveExecuteSettings then RC:SaveExecuteSettings() end
                                    RC:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings)
                                end)
                            end
                        end)
                        rowClick:SetScript("OnEnter", function() local _ag=RC:GetColor("ui","accentGold"); bg:SetColorTexture(_ag.r*0.2,_ag.g*0.15,_ag.b*0.05,1) end)
                        rowClick:SetScript("OnLeave", function()
                            if isOl then local _ec=RC:GetColor("buttons","closeNormal"); bg:SetColorTexture(_ec.r*0.18,_ec.g*0.06,_ec.b*0.06,1)
                            else bg:SetColorTexture(i%2==0 and 0.13 or 0.07, i%2==0 and 0.12 or 0.06, i%2==0 and 0.09 or 0.05, i%2==0 and 0.55 or 0.35) end
                        end)
                    end

                    cy = cy - listH - 8
                end

                cy = cy - 6

                local addLbl = self:CreateFontString(histCard, "OVERLAY", nil, 10)
                addLbl:SetPoint("TOPLEFT", histCard, "TOPLEFT", 15, cy)
                addLbl:SetText(RCL["Add kill:"])
                addLbl:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])

                -- Framework backed edit boxes: flat fill, 1px black ring,
                -- gold ring while typing (was a hand-rolled BackdropTemplate
                -- pair with a literal gray border).
                local minEB = self.UI:CreateBackedEditBox(histCard, {
                    width = 30, height = 20, numeric = true, maxLetters = 2,
                    justify = "CENTER", insets = 4, fontSize = 10,
                })
                minEB:SetPoint("LEFT", addLbl, "RIGHT", 5, 0)
                minEB:SetText("1")

                local colLbl = self:CreateFontString(histCard, "OVERLAY", nil, 11)
                colLbl:SetPoint("LEFT", minEB, "RIGHT", 2, 0); colLbl:SetText(":")
                colLbl:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])

                local secEB = self.UI:CreateBackedEditBox(histCard, {
                    width = 30, height = 20, numeric = true, maxLetters = 2,
                    justify = "CENTER", insets = 4, fontSize = 10,
                })
                secEB:SetPoint("LEFT", colLbl, "RIGHT", 2, 0)
                secEB:SetText("30")

                local saygeOn = frame._addKillSayge and true or false
                frame._addKillProfile = frame._addKillProfile or {}
                local addProfile = frame._addKillProfile[raidName]
                    or (RC.GetActiveProfileNameForRaid and RC:GetActiveProfileNameForRaid(raidName))
                    or "Default"
                local _acGold = RC:GetColor("ui", "accentGold")
                local _bBlack = { r = 0, g = 0, b = 0, a = 1 }

                local saygeBtn = CreateFrame("Button", nil, histCard)
                saygeBtn:SetSize(20, 20)
                saygeBtn:SetPoint("LEFT", secEB, "RIGHT", 6, 0)
                local saygeTex = saygeBtn:CreateTexture(nil, "ARTWORK")
                saygeTex:SetPoint("TOPLEFT", 1, -1)
                saygeTex:SetPoint("BOTTOMRIGHT", -1, 1)
                saygeTex:SetTexture("Interface\\Icons\\inv_misc_orb_02")
                saygeTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                local saygeBorders = self.UI:CreateSimpleBorder(saygeBtn)

                local function ApplySaygeState()
                    saygeTex:SetDesaturated(not saygeOn)
                    saygeTex:SetAlpha(saygeOn and 1 or 0.45)
                    self.UI:UpdateBorderColor(saygeBorders, saygeOn and _acGold or _bBlack)
                end
                ApplySaygeState()

                saygeBtn:SetScript("OnClick", function()
                    saygeOn = not saygeOn
                    frame._addKillSayge = saygeOn
                    ApplySaygeState()
                end)
                saygeBtn:SetScript("OnEnter", function(s)
                    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                    GameTooltip:SetText(RCL["Darkmoon Faire buff"], 1, 1, 1)
                    GameTooltip:AddLine(RCL["When lit, kills you add are recorded as having Sayge's Dark Fortune of Damage."], 0.8, 0.8, 0.8, true)
                    GameTooltip:Show()
                end)
                saygeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

                local addBtn = self.UI:CreateStyledButton(histCard, "+", 22, 20)
                addBtn:SetPoint("LEFT", saygeBtn, "RIGHT", 6, 0)
                addBtn:SetScript("OnClick", function()
                    local m = tonumber(minEB:GetText()) or 0
                    local s = tonumber(secEB:GetText()) or 0
                    local tot2 = m * 60 + s
                    if tot2 > 0 and RC.AddManualKillTime then
                        RC:AddManualKillTime(effectiveEncounterName, tot2, raidName, true, saygeOn, addProfile)
                        RC:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings)
                    end
                end)
                minEB:SetScript("OnEnterPressed", function() secEB:SetFocus() end)
                secEB:SetScript("OnEnterPressed", function() addBtn:Click() end)
                minEB:SetScript("OnTabPressed",   function() secEB:SetFocus() end)
                secEB:SetScript("OnTabPressed",   function() minEB:SetFocus() end)

                local bulkBtn = self.UI:CreateStyledButton(histCard, RCL["Bulk"], 42, 20)
                bulkBtn:SetPoint("LEFT", addBtn, "RIGHT", 6, 0)
                bulkBtn:SetScript("OnClick", function()
                    if RC.ShowBulkKillDialog then
                        RC:ShowBulkKillDialog(raidName, effectiveEncounterName, function()
                            RC:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings)
                        end, addProfile)
                    end
                end)

                cy = cy - 26

                local supLbl = self:CreateFontString(histCard, "OVERLAY", nil, 10)
                supLbl:SetPoint("TOPLEFT", histCard, "TOPLEFT", 15, cy)
                supLbl:SetText(RCL["Save under:"])
                supLbl:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])

                local profChoices = {}
                if RC.GetRaidProfileStructure then
                    local structure = RC:GetRaidProfileStructure(raidName)
                    if structure and structure.profiles then
                        for pname in pairs(structure.profiles) do
                            table.insert(profChoices, pname)
                        end
                        table.sort(profChoices)
                    end
                end
                if #profChoices == 0 then table.insert(profChoices, addProfile) end

                local profStillExists = false
                for _, pname in ipairs(profChoices) do
                    if pname == addProfile then
                        profStillExists = true
                        break
                    end
                end
                if not profStillExists then
                    addProfile = (RC.GetActiveProfileNameForRaid and RC:GetActiveProfileNameForRaid(raidName)) or profChoices[1]
                    frame._addKillProfile[raidName] = nil
                end

                local supDD = self.UI:CreateScrollableDropdown(histCard, 140, "", 8)
                supDD:SetPoint("LEFT", supLbl, "RIGHT", 8, 0)
                local supItems = {}
                for _, pname in ipairs(profChoices) do
                    table.insert(supItems, { text = pname, value = pname })
                end
                supDD:SetItems(supItems, function(value)
                    addProfile = value
                    frame._addKillProfile[raidName] = value
                end)
                if self.UI.SetButtonText then
                    self.UI:SetButtonText(supDD, addProfile)
                elseif supDD.text and supDD.text.SetText then
                    supDD.text:SetText(addProfile)
                end

                cy = cy - 26

                local simBtn = self.UI:CreateStyledButton(histCard, RCL["Simulate"], 70, 20)
                simBtn:SetPoint("TOPLEFT", histCard, "TOPLEFT", 15, cy)
                simBtn:SetScript("OnClick", function() RC:StartBossSimulation(raidName, encounterName) end)

                local clrBtn
                if fightCount > 0 then
                    clrBtn = self.UI:CreateStyledButton(histCard, RCL["Clear All"], 65, 20)
                    clrBtn:SetPoint("LEFT", simBtn, "RIGHT", 6, 0)
                    clrBtn:SetScript("OnClick", function()
                        RC.UI:CreateConfirmDialog(
                            RCL["Clear All"],
                            ((linkedConfigs or 0) > 0)
                                and string.format(RCL["Clear this config's kill data for %s?\n\nKills saved under related configs stay."], encounterName)
                                or (RCL["Clear all kill data for "] .. encounterName .. "?"),
                            function()
                                if RC.ClearBossHistory then
                                    RC:ClearBossHistory(raidName, encounterName)
                                    RC:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings)
                                end
                            end,
                            nil, RCL["Clear"], true)
                    end)
                end

                local rbBtn = self.UI:CreateStyledButton(histCard, RCL["Raid Bulk"], 70, 20)
                rbBtn:SetPoint("LEFT", clrBtn or simBtn, "RIGHT", 6, 0)
                rbBtn:SetScript("OnClick", function()
                    if RC.ShowBulkKillDialog then
                        RC:ShowBulkKillDialog(raidName, nil, function()
                            RC:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings)
                        end, addProfile)
                    end
                end)

                cy = cy - 28
                histCard:SetContentHeight(math.abs(cy))
                yPos = yPos - histCard:GetHeight() - 15
            end

        else
            if expandedKey then
                yPos = RenderAbilityPanel(yPos)
            else
                yPos = RenderEmptyPanelHint(yPos)
            end
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end

