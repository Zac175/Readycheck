local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_max, math_min = math.floor, math.max, math.min
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbc = RC._sbc or {}
local _sbc = RC._sbc
local TEXT = _sbc.TEXT
------------------------------------------------------------------------
-- Readycheck - Battle Shout Reminder Settings
-- Two on-screen pieces on one page: the reminder icon
-- (db.battleShoutReminder) and the party tracker
-- (db.battleShoutPartyTracker, its own Start/Stop path). Every tab has a
-- card for each, in the standard order Behavior / Look / Text /
-- Animation / Sound / Position. Tab keys from before (general,
-- appearance, tracker) still open the right tab, so old search aliases
-- keep working. The preview pane draws both with their own builders
-- (RC:BuildBattleShoutIcon / BuildBattleShoutTracker) and sample data.
------------------------------------------------------------------------

    local K = RC._rpk
    local NONE = { style = "none" }
    local ANIM_IN  = { style = "none", duration = 0.3 }
    local ANIM_OUT = { style = "none", duration = 0.3 }
    local ANIM_ALERT = { style = "none", duration = 0.8, loop = true }
    local LEGACY_TABS = { general = "behavior", appearance = "look", tracker = "behavior" }
    local PV_W, PV_H = 280, 120   -- side by side at the defaults; update fits it

    local function BS() return RC.db.battleShoutReminder end
    local function PT() return RC.db.battleShoutPartyTracker end

    -- live repaint of the real frames after a change
    local function LiveIcon()
        if RC.UpdateBattleShoutReminderAppearance then RC:UpdateBattleShoutReminderAppearance() end
        if RC.battleShoutReminder and RC.battleShoutReminder.ticker then RC:UpdateBattleShoutReminder() end
    end
    local function LiveTracker()
        local f = RC.battleShoutPartyTracker and RC.battleShoutPartyTracker.frame
        if f and RC.StyleBattleShoutTracker then RC:StyleBattleShoutTracker(f) end
        if PT().enabled and RC.UpdateBattleShoutPartyTracker then RC:UpdateBattleShoutPartyTracker() end
    end

    ------------------------------------------------------------------
    -- The customization standard on this page (UIF_Custom / UIF_CustomUI):
    -- every text gets one CreateTextElement (font + colours + format +
    -- position), every part a CreateFrameElement, the tracker's rows a
    -- layout picker. The two helpers below are local wrappers over what
    -- Reminders_PageKit's K.Font / K.ThemeColor do, shaped as the
    -- bundle's opts (the kit itself is not edited here).
    ------------------------------------------------------------------
    local function FontOf(tbl, specKey, sizeKey, defaults, sample, onChange, minS, maxS)
        return { label = RCL["Font"], defaults = defaults, sample = sample, minSize = minS, maxSize = maxS,
            get = function() return K.FontSpec(tbl, specKey, sizeKey) end,
            set = function(spec)
                if sizeKey then
                    if spec.size then tbl[sizeKey] = math_floor(spec.size + 0.5) end
                    tbl[specKey] = { face = spec.face, outline = spec.outline, shadow = spec.shadow }
                else
                    tbl[specKey] = { face = spec.face, outline = spec.outline, shadow = spec.shadow, size = spec.size }
                end
                RC:SaveConfigurationToProfile()
                if onChange then onChange() end
            end }
    end
    local function ThemeColorOf(cat, key, label, onChange, alpha)
        return { label = label, alpha = alpha,
            get = function() return RC:GetColor(cat, key) end,
            set = function(r, g, b, a)
                local cur = RC:GetColor(cat, key)
                RC:SetColor(cat, key, r, g, b, a or (cur and cur.a) or 1)
                if onChange then onChange() end
            end,
            default = RC.defaultColors and RC.defaultColors[cat] and RC.defaultColors[cat][key],
            isChanged = function()
                local cc = RC.db and RC.db.customColors
                return cc and cc[cat] and cc[cat][key] ~= nil or false
            end,
            reset = function() RC:ResetColor(cat, key) if onChange then onChange() end end }
    end
    -- every element of the same frame but this one
    local function Others(list, self)
        local out = {}
        for _, t in ipairs(list) do if t.value ~= self then out[#out + 1] = t end end
        return out
    end
    local function CardWidth(card)
        local w = card and card.GetWidth and card:GetWidth()
        if type(w) == "number" and w > 240 then return math_min(460, w - 28) end
        return 420
    end

    ------------------------------------------------------------------
    -- Preview: the icon (two states) beside the tracker (every row state)
    ------------------------------------------------------------------
    local SAMPLE_NAMES = "Rowdy\nStabbs"

    local function PreviewBuild(canvas, P)
        local holder = CreateFrame("Frame", nil, canvas)
        holder:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        P.store.holder = holder
        P.store.icon = RC:BuildBattleShoutIcon(holder)
        P.store.tracker = RC:BuildBattleShoutTracker(holder)
        P.store.rows = {}
        P.store.token = 0
    end

    local function PreviewUpdate(canvas, P)
        local st, db, pt = P.store, BS(), PT()
        local missing = (P.mode or "missing") == "missing"
        local selfOnly = db.trackScope == "self"
        local icon, tracker = st.icon, st.tracker

        RC:StyleBattleShoutIcon(icon, db)
        local text, names = "", nil
        if missing then
            text = selfOnly and "" or "2"
            if db.showMissingNames and not selfOnly then
                names = db.shortenNames and "Row\nSta" or SAMPLE_NAMES
            end
        elseif db.showAPValue then
            text = "290 AP"
        end
        RC:FillBattleShoutIcon(icon, missing, text, names)

        -- the sample party, through the tracker's own filter
        local all = RC:BattleShoutTrackerSampleRows(GetTime(), st.all)
        st.all = all
        local rows = st.rows
        for i = #rows, 1, -1 do rows[i] = nil end
        for _, r in ipairs(all) do
            if not missing and not r.hasBuff then
                r.hasBuff, r.remaining, r.apValue, r.outOfRange = true, 80, 290, false
            end
            if not missing then r.belowThreshold = false end
            if not pt.showOnlyMissing or not r.hasBuff or r.belowThreshold then rows[#rows + 1] = r end
        end
        RC:StyleBattleShoutTracker(tracker, pt)
        RC:LayoutBattleShoutTracker(tracker, rows, pt, nil)
        tracker:SetShown(#rows > 0)

        -- geometry: the icon (names room on the side they sit) on the left,
        -- the tracker beside it, wearing its own scale; the canvas is the
        -- pair at the tracker's 100% so a scale shows (K.FitStrip)
        local size = db.iconSize or 40
        local pos = db.namesPosition or "right"
        local gap = tonumber(db.namesOffset) or 5
        local nameW = names and (icon.namesText:GetStringWidth() or 40) + gap or 0
        local nameH = names and (icon.namesText:GetStringHeight() or 24) + gap or 0
        local side = (pos == "left" or pos == "right") and nameW or 0
        local above = (pos == "above") and nameH or 0
        local below = (pos == "below") and nameH or 0
        local shown = #rows > 0
        local tsc = tonumber(pt.scale) or 1
        if tsc <= 0 then tsc = 1 end
        local tw, th = shown and (tracker:GetWidth() or 165) or 0, shown and (tracker:GetHeight() or 60) or 0
        local iconW = size + side * 2
        local iconH = above + size + below
        local trackX = 8 + iconW + (shown and 14 or 0)
        local w = trackX + tw * tsc + 8
        local h = math_max(iconH, th * tsc) + 4
        local natW = trackX + tw + 8
        local natH = math_max(iconH, th) + 4
        local sig = math_floor(w) .. ":" .. math_floor(h) .. ":" .. pos .. ":" .. math_floor(above) .. ":" .. math_floor(below) .. ":" .. tsc
        if st.geo ~= sig then
            RC.Motion.Stop(icon) RC.Motion.Stop(tracker)
            K.FitStrip(P, st.holder, w, h, 0, natW, natH)
            tracker:SetScale(tsc)
            icon:ClearAllPoints()
            icon:SetPoint("LEFT", st.holder, "LEFT", 8 + side, (below - above) / 2)
            tracker:ClearAllPoints()
            tracker:SetPoint("LEFT", st.holder, "LEFT", trackX / tsc, 0)
            st.geo = sig
        end
    end

    local function PreviewReplay(canvas, P)
        local st, db, pt = P.store, BS(), PT()
        local missing = (P.mode or "missing") == "missing"
        K.Replay(st, canvas, {
            { frame = st.icon, inSpec = db.showAnim or NONE, outSpec = db.hideAnim or NONE,
              onIn = function()
                  if missing and db.alertAnim and st.icon:IsVisible() then RC.Motion.Play(st.icon, db.alertAnim, "update") end
              end },
            { frame = st.tracker, inSpec = pt.showAnim or NONE, outSpec = pt.hideAnim or NONE },
        }, missing and 2.4 or 1.2)
    end

    ------------------------------------------------------------------
    -- Page
    ------------------------------------------------------------------
    function RC:ShowSidebarBattleShoutConfig(frame, selectedTab)
        local isTabSwitch = (selectedTab ~= nil)
        self:ClearSidebarContent(self.sidebarConfigFrame, isTabSwitch)
        selectedTab = K.Tab(selectedTab or frame.bsTab, LEGACY_TABS, "behavior")
        frame.bsTab = selectedTab

        local parent = frame.scrollChild
        local yPos = -15

        if self.InitializeBattleShoutReminderDB then
            self:InitializeBattleShoutReminderDB()
        elseif not self.db.battleShoutReminder then
            self.db.battleShoutReminder = {}
        end
        if self.InitializeBattleShoutPartyTrackerDB then
            self:InitializeBattleShoutPartyTrackerDB()
        elseif not self.db.battleShoutPartyTracker then
            self.db.battleShoutPartyTracker = {}
        end
        local db = self.db.battleShoutReminder
        local ptDb = self.db.battleShoutPartyTracker

        local P
        if self.BuildBattleShoutIcon and self.BuildBattleShoutTracker then
            P = self.UI:DeclarePreview({
                key = "battleshout.frames", title = RCL["Battle Shout"],
                width = PV_W, height = PV_H,
                build = PreviewBuild, update = PreviewUpdate, replay = PreviewReplay,
                modes = { { id = "missing", label = RCL["Someone missing"] }, { id = "buffed", label = RCL["All buffed"] } },
            })
        end
        local function Replay() if P then P.Replay() end end

        local function Save() RC:SaveConfigurationToProfile() end
        local function Rerender(tab) RC:ShowSidebarBattleShoutConfig(frame, tab or selectedTab) end

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Battle Shout Reminder"],
            RCL["Warns you when party members are missing Battle Shout"], "Interface\\Icons\\Ability_Warrior_BattleShout")
        yPos = newY

        local _, newTabY = self.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = {
                { key = "behavior",  label = RCL["Behavior"] },
                { key = "look",      label = RCL["Look"] },
                { key = "text",      label = RCL["Text"] },
                { key = "animation", label = RCL["Animation"] },
                { key = "sound",     label = RCL["Sound"] },
                { key = "position",  label = RCL["Position"] },
            },
            selected = selectedTab,
            onClick = function(tk)
                frame.bsTab = tk
                RC:ShowSidebarBattleShoutConfig(frame, tk)
            end,
            advance = 34,
        })
        yPos = newTabY

        local function Tip(widget, title, lines)
            widget:SetScript("OnEnter", function(s)
                GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                local gold, norm = RC:GetColor("text", "gold"), RC:GetColor("text", "normal")
                GameTooltip:SetText(title, gold.r, gold.g, gold.b)
                for _, l in ipairs(lines) do GameTooltip:AddLine(l, norm.r, norm.g, norm.b, true) end
                GameTooltip:Show()
            end)
            widget:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
        local function Light(fs) fs:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
        local function SmallLabel(card, x, y, text)
            local l = self:CreateFontString(card, "OVERLAY", nil, 10)
            l:SetPoint("TOPLEFT", card, "TOPLEFT", x, y)
            l:SetText(text)
            Light(l)
            return l
        end
        local function Finish(card, cardY)
            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 15
        end
        local function VisRow(card, cardY, tbl, onPick)
            -- "always" here already means "any party or raid, anywhere"
            -- (the bars' "group"); the predicate also accepts "group".
            self.UI:CreateSegmentedControl(card, {
                x = 14, y = cardY, height = 22, label = RCL["Show in:"],
                items = {
                    {key="raids",      label=RCL["Inside Raids"], tooltip=RCL["Only while you are inside a raid instance."]},
                    {key="instances",  label=RCL["Dungeons & Raids"], tooltip=RCL["Inside a dungeon or a raid instance."]},
                    {key="always",     label=RCL["Any Group"],    tooltip=RCL["In any party or raid, anywhere in the world."]},
                    {key="everywhere", label=RCL["Everywhere"],   tooltip=RCL["Even while solo."]},
                },
                selected = tbl.visibilityMode or "raids",
                onSelect = function(key) tbl.visibilityMode = key; onPick() end,
            })
            cardY = cardY - 22 - 6
            -- Shared per-raid filter (Cons_Base.lua); only under the raid modes.
            local raidGated = _sbc.RAID_GATED_MODES or { raids = true }
            if _sbc.BuildRaidFilter and raidGated[tbl.visibilityMode or "raids"] then
                cardY = _sbc.BuildRaidFilter(card, cardY, tbl, onPick)
            end
            return cardY - 4
        end

        if selectedTab == "behavior" then
            --------------------------------------------------------------
            -- Reminder icon: when it warns
            --------------------------------------------------------------
            local card = self:CreateSettingsCard(parent, yPos, RCL["Reminder icon"])
            local cardY = -32

            local enableCb = self.UI:CreateSettingCheckbox(card, cardY, RCL["Enable Battle Shout Reminder"], db.enabled, function(cb)
                local v = cb:GetChecked()
                db.enabled = v; RC:ForceCheckboxUpdate(cb, v)
                if v then RC:StartBattleShoutReminderUpdates()
                else RC:StopBattleShoutReminderUpdates() end
                Save()
            end)
            cardY = cardY - 28
            local enableMark = self.UI:MarkCard(card)

            -- db.greedMode: while your own Battle Shout still has more than
            -- three minutes left (the long 400 AP / 15-min shout), the
            -- reminder stays hidden instead of nagging for a refresh that
            -- isn't due. Not the same thing as trackScope = "self" below,
            -- which changes WHOSE shout is watched; this only mutes.
            local greedCb = self.UI:CreateSettingCheckbox(card, cardY, RCL["Stay quiet while my own long (15-min) Battle Shout is still up"], db.greedMode, function(cb)
                db.greedMode = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.greedMode); Save()
            end)
            Tip(greedCb, RCL["Long Battle Shout"], { RCL["Suppresses the reminder while you have the long 400 AP / 15-min Battle Shout on yourself."] })
            cardY = cardY - 24

            local impCleaveCb = self.UI:CreateCheckbox(card, RCL["Also skip when specced Improved Cleave"], db.greedSkipIfImpCleave)
            impCleaveCb:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            impCleaveCb:SetScript("OnClick", function(cb)
                db.greedSkipIfImpCleave = cb:GetChecked()
                RC:ForceCheckboxUpdate(cb, db.greedSkipIfImpCleave)
                Save()
            end)
            Tip(impCleaveCb, RCL["Skip if Improved Cleave"], {
                RCL["Also suppresses the reminder whenever you are specced into Improved Cleave."],
                RCL["Imp Cleave warriors typically don't want to be reminded to refresh Battle Shout mid-fight."],
                RCL["Requires the option above to be enabled."] })
            cardY = cardY - 28
            self.UI:BindDependents(greedCb, { impCleaveCb })

            local rangeCb = self.UI:CreateSettingCheckbox(card, cardY, RCL["Range Check (~28 yd)"], db.rangeCheck, function(cb)
                db.rangeCheck = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.rangeCheck); Save()
            end)
            Tip(rangeCb, RCL["Range Check"], {
                RCL["Excludes party members outside ~28 yards from the missing count."],
                RCL["Out-of-range members show as ~Name in the names list."],
                RCL["Useful so you don't get alerted for people you can't shout."] })
            cardY = cardY - 28

            self.UI:CreateSettingCheckbox(card, cardY, RCL["Hide when all party members are buffed"], db.hideWhenAllBuffed, function(cb)
                db.hideWhenAllBuffed = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.hideWhenAllBuffed)
                RC:UpdateBattleShoutReminder(); Save()
            end)
            cardY = cardY - 28

            self.UI:CreateSettingCheckbox(card, cardY, RCL["Show AP value when buffed"], db.showAPValue, function(cb)
                db.showAPValue = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.showAPValue)
                RC:UpdateBattleShoutReminder(); Save()
            end)
            cardY = cardY - 32

            -- A mode change re-renders this tab (scroll kept) so the
            -- per-raid filter block can appear or go away.
            cardY = VisRow(card, cardY, db, function()
                if db.enabled then
                    if RC:ShouldShowBattleShoutReminder() then
                        if not RC.battleShoutReminder.ticker then RC:StartBattleShoutReminderUpdates() end
                    else RC:StopBattleShoutReminderUpdates() end
                end
                Save()
                Rerender("behavior")
            end)

            -- Whose shout the reminder cares about.
            self.UI:CreateSegmentedControl(card, {
                x = 14, y = cardY, height = 22, label = RCL["Remind me about:"],
                items = {
                    {key="group", label=RCL["My Group"], tooltip=RCL["Warns when anyone in your group is missing Battle Shout."]},
                    {key="self",  label=RCL["Only Me"],  tooltip=RCL["Ignores your group and just watches the Battle Shout on you."]},
                },
                selected = db.trackScope or "group",
                onSelect = function(key)
                    db.trackScope = key
                    if RC.UpdateBattleShoutReminder then RC:UpdateBattleShoutReminder() end
                    Save()
                end,
            })
            cardY = cardY - 26
            cardY = K.Desc(card, cardY, RCL["Only Me ignores your group and just watches the Battle Shout on you."])

            cardY = K.Slider(card, cardY, RCL["Warn threshold (0 = only when missing):"], 0, 120, db.buffThreshold or 0, 5,
                function(v) return v == 0 and RCL["Missing only"] or (math_floor(v) .. "s") end,
                function(v) db.buffThreshold = v; RC:UpdateBattleShoutReminder() end)
            self.UI:BindDependents(enableCb, self.UI:CardSince(card, enableMark))
            Finish(card, cardY)

            --------------------------------------------------------------
            -- Party tracker: what it lists and when
            --------------------------------------------------------------
            local ptCard = self:CreateSettingsCard(parent, yPos, RCL["Party tracker"])
            local ptY = -32
            ptY = K.Desc(ptCard, ptY, RCL["Shows every Warrior/Rogue in your group with Battle Shout AP and status. Click-through by default."])

            local ptEnableCb = self.UI:CreateSettingCheckbox(ptCard, ptY, RCL["Enable Party Tracker"], ptDb.enabled, function(cb)
                local v = cb:GetChecked(); ptDb.enabled = v; RC:ForceCheckboxUpdate(cb, v)
                if v then RC:StartBattleShoutPartyTrackerUpdates()
                else RC:StopBattleShoutPartyTrackerUpdates() end
                Save()
            end)
            ptY = ptY - 26
            local ptMark = self.UI:MarkCard(ptCard)

            local ptMissCb = self.UI:CreateCheckbox(ptCard, RCL["Show only missing / expiring"], ptDb.showOnlyMissing)
            ptMissCb:SetPoint("TOPLEFT", ptCard, "TOPLEFT", 14, ptY)
            ptMissCb:SetScript("OnClick", function(cb)
                ptDb.showOnlyMissing = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, ptDb.showOnlyMissing)
                LiveTracker(); Save()
            end)
            ptY = ptY - 24

            local ptRangeCb = self.UI:CreateCheckbox(ptCard, RCL["Range check (OOR instead of MISSING)"], ptDb.rangeCheck)
            ptRangeCb:SetPoint("TOPLEFT", ptCard, "TOPLEFT", 14, ptY)
            ptRangeCb:SetScript("OnClick", function(cb)
                ptDb.rangeCheck = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, ptDb.rangeCheck)
                LiveTracker(); Save()
            end)
            Tip(ptRangeCb, RCL["Range Check"], { RCL["Shows OOR instead of MISSING for members outside ~28 yards."] })
            ptY = ptY - 30

            local ptBRCb = self.UI:CreateCheckbox(ptCard, RCL["Show Bloodrage indicator"], ptDb.showBloodrage ~= false)
            ptBRCb:SetPoint("TOPLEFT", ptCard, "TOPLEFT", 14, ptY)
            ptBRCb:SetScript("OnClick", function(cb)
                ptDb.showBloodrage = cb:GetChecked()
                RC:ForceCheckboxUpdate(cb, ptDb.showBloodrage)
                LiveTracker(); Save()
            end)
            Tip(ptBRCb, RCL["Bloodrage Indicator"], { RCL["Highlights any Warrior in your party (you included) who currently has Bloodrage active. Choose icon, red name, or both."] })
            ptY = ptY - 24

            local brStyle = self.UI:CreateSegmentedControl(ptCard, {
                y = ptY, height = 22, label = RCL["Bloodrage style:"],
                items = {
                    {key="icon",  label=RCL["Icon"]},
                    {key="color", label=RCL["Red Name"]},
                    {key="both",  label=RCL["Both"]},
                },
                selected = ptDb.bloodrageStyle or "both",
                onSelect = function(key)
                    ptDb.bloodrageStyle = key
                    LiveTracker(); Save()
                end,
            })
            brStyle:ClearAllPoints()
            brStyle:SetPoint("TOPLEFT",  ptCard, "TOPLEFT",  14, ptY)
            brStyle:SetPoint("TOPRIGHT", ptCard, "TOPRIGHT", -14, ptY)
            ptY = ptY - 32
            -- the style only matters while the indicator is on
            self.UI:BindDependents(ptBRCb, { brStyle })

            self.UI:CreateSegmentedControl(ptCard, {
                x = 14, y = ptY, height = 22, label = RCL["Duration display:"],
                items = {
                    {key="none",  label=RCL["None"]},  {key="bar",  label=RCL["Bar"]},
                    {key="timer", label=RCL["Timer"]}, {key="both", label=RCL["Both"]},
                },
                selected = ptDb.durationStyle or "bar",
                onSelect = function(key)
                    ptDb.durationStyle = key
                    LiveTracker(); Save()
                end,
            })
            ptY = ptY - 32

            ptY = K.Slider(ptCard, ptY, RCL["Bar max (a full bar):"], 60, 900, ptDb.barMaxDuration or 120, 30,
                function(v) return math_floor(v) .. "s" end,
                function(v) ptDb.barMaxDuration = v; LiveTracker() end)

            -- Same shape as the reminder's row; a change re-renders this tab
            -- so the per-raid filter block can come and go.
            ptY = VisRow(ptCard, ptY, ptDb, function()
                if ptDb.enabled then
                    if RC:ShouldShowPartyTracker() then RC:StartBattleShoutPartyTrackerUpdates()
                    else RC:StopBattleShoutPartyTrackerUpdates() end
                end
                Save()
                Rerender("behavior")
            end)
            self.UI:BindDependents(ptEnableCb, self.UI:CardSince(ptCard, ptMark))
            Finish(ptCard, ptY)
            -- fade rules on top of "Show in" (the customization standard)
            yPos = self.UI:FrameVisibilityCard(parent, yPos, BS, LiveIcon, { title = RCL["Icon fade and opacity"] })
            yPos = self.UI:FrameVisibilityCard(parent, yPos, PT, LiveTracker, { title = RCL["Tracker fade and opacity"] })

        elseif selectedTab == "look" then
            --------------------------------------------------------------
            -- Reminder icon: size, opacity, border, colours, names
            --------------------------------------------------------------
            local card = self:CreateSettingsCard(parent, yPos, RCL["Reminder icon"])
            local cardY = -32

            cardY = K.Slider(card, cardY, RCL["Icon size"], 20, 80, db.iconSize or 40, 1, K.Px,
                function(v) db.iconSize = v; LiveIcon() end)
            cardY = K.Slider(card, cardY, RCL["Opacity"], 0.1, 1.0, db.opacity or 0.7, 0.1, K.Pct,
                function(v) db.opacity = v; LiveIcon() end)
            cardY = K.Slider(card, cardY, RCL["Border thickness"], 0, 4, tonumber(db.borderSize) or 1, 1, K.Px,
                function(v) db.borderSize = v; LiveIcon() end)
            cardY = K.ThemeColor(card, cardY, "battleShoutReminder", "background", RCL["Background"], LiveIcon)
            cardY = K.ThemeColor(card, cardY, "battleShoutReminder", "normalBorder", RCL["Border when everyone is buffed"], LiveIcon)
            cardY = K.ThemeColor(card, cardY, "battleShoutReminder", "missingBorder", RCL["Border when someone is missing"], LiveIcon)
            cardY = cardY - 8

            self.UI:CreateSettingCheckbox(card, cardY, RCL["Show missing player names"], db.showMissingNames, function(cb)
                db.showMissingNames = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.showMissingNames)
                RC:UpdateBattleShoutReminder(); Save()
            end)
            cardY = cardY - 26

            local shortenCb = self.UI:CreateCheckbox(card, RCL["Shorten names (first 3 letters)"], db.shortenNames)
            shortenCb:SetPoint("TOPLEFT", card, "TOPLEFT", 28, cardY)
            shortenCb:SetScript("OnClick", function(cb)
                db.shortenNames = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.shortenNames)
                RC:UpdateBattleShoutReminder(); Save()
            end)
            cardY = cardY - 30

            local posL = SmallLabel(card, 14, cardY, RCL["Names sit:"])
            local posOpts = { {v="right",n=RCL["Right"]},{v="left",n=RCL["Left"]},{v="above",n=RCL["Above"]},{v="below",n=RCL["Below"]} }
            local function PosName(k) for _, o in ipairs(posOpts) do if o.v == k then return o.n end end return RCL["Right"] end
            local posDD = self.UI:CreateScrollableDropdown(card, 120, PosName(db.namesPosition or "right"), 8)
            posDD:SetPoint("LEFT", posL, "RIGHT", 10, 0)
            local posItems = {}
            for _, o in ipairs(posOpts) do posItems[#posItems + 1] = { text = o.n, value = o.v } end
            posDD:SetItems(posItems, function(value)
                db.namesPosition = value
                LiveIcon(); Save()
            end)
            posDD:SetSelectedValue(db.namesPosition or "right", PosName(db.namesPosition or "right"))
            cardY = cardY - 32

            cardY = K.Slider(card, cardY, RCL["Gap between icon and names"], 0, 20, tonumber(db.namesOffset) or 5, 1, K.Px,
                function(v) db.namesOffset = v; LiveIcon() end)
            Finish(card, cardY)

            --------------------------------------------------------------
            -- Party tracker: frame, rows, status colours
            --------------------------------------------------------------
            local ptCard = self:CreateSettingsCard(parent, yPos, RCL["Party tracker"])
            local ptY = -32

            self.UI:CreateSettingCheckbox(ptCard, ptY, RCL["Show background"], ptDb.showBackground ~= false, function(cb)
                ptDb.showBackground = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, ptDb.showBackground)
                LiveTracker(); Save()
            end)
            ptY = ptY - 24
            self.UI:CreateSettingCheckbox(ptCard, ptY, RCL["Show header"], ptDb.showHeader ~= false, function(cb)
                ptDb.showHeader = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, ptDb.showHeader)
                LiveTracker(); Save()
            end)
            ptY = ptY - 30

            ptY = K.Slider(ptCard, ptY, RCL["Background opacity"], 0.0, 1.0, ptDb.opacity or 0.85, 0.05, K.Pct,
                function(v) ptDb.opacity = v; LiveTracker() end)
            ptY = K.Slider(ptCard, ptY, RCL["Width"], 120, 280, ptDb.width or 165, 5, K.Px,
                function(v) ptDb.width = v; LiveTracker() end)
            ptY = K.Slider(ptCard, ptY, RCL["Row height"], 14, 26, ptDb.rowHeight or 17, 1, K.Px,
                function(v) ptDb.rowHeight = v; LiveTracker() end)
            ptY = K.Slider(ptCard, ptY, RCL["Border thickness"], 0, 4, tonumber(ptDb.borderSize) or 1, 1, K.Px,
                function(v) ptDb.borderSize = v; LiveTracker() end)
            ptY = K.Slider(ptCard, ptY, RCL["Duration bar opacity"], 0.1, 1.0, tonumber(ptDb.barAlpha) or 0.45, 0.05, K.Pct,
                function(v) ptDb.barAlpha = v; LiveTracker() end)

            ptY = K.ThemeColor(ptCard, ptY, "battleShoutPartyTracker", "background", RCL["Background"], LiveTracker, { alpha = true })
            ptY = K.ThemeColor(ptCard, ptY, "battleShoutPartyTracker", "border", RCL["Border"], LiveTracker)
            ptY = K.ThemeColor(ptCard, ptY, "battleShoutPartyTracker", "rowBackground", RCL["Row background"], LiveTracker, { alpha = true })
            ptY = K.ThemeColor(ptCard, ptY, "battleShoutPartyTracker", "apGood", RCL["Buffed"], LiveTracker)
            ptY = K.ThemeColor(ptCard, ptY, "battleShoutPartyTracker", "apWarning", RCL["Running out / out of range"], LiveTracker)
            ptY = K.ThemeColor(ptCard, ptY, "battleShoutPartyTracker", "apMissing", RCL["Missing"], LiveTracker)
            ptY = K.ThemeColor(ptCard, ptY, "battleShoutPartyTracker", "bloodrageActive", RCL["Bloodraging name"], LiveTracker)
            ptY = K.Desc(ptCard, ptY - 4, RCL["The status colours paint both the status text and its duration bar."])
            Finish(ptCard, ptY)
            yPos = self.UI:FrameChromeCard(parent, yPos, BS, LiveIcon, { title = RCL["Icon shadow and glow"], fields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })
            yPos = self.UI:FrameChromeCard(parent, yPos, PT, LiveTracker, { title = RCL["Tracker shadow and glow"], fields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })

        elseif selectedTab == "text" then
            -- one group per text: font, colours, format, and where it sits
            local function Saved(live) return function() RC:SaveConfigurationToProfile() live() end end
            local card = self:CreateSettingsCard(parent, yPos, RCL["Reminder icon"])
            local cardY = -32
            local W = CardWidth(card)
            local function Place(g) g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY) cardY = cardY - g:GetHeight() - 14 end
            local ag, as = self.UI:CustomAccess(db, "anchors", "count", Saved(LiveIcon))
            Place(self.UI:CreateTextElement(card, { label = RCL["Count text"], key = "count", width = W,
                font = FontOf(db, "countFont", "fontSize", RC.BATTLE_SHOUT_COUNT_FONT, "3   12   290 AP", LiveIcon, 10, 28),
                colors = {
                    ThemeColorOf("battleShoutReminder", "missingText", RCL["Text when someone is missing"], LiveIcon),
                    ThemeColorOf("battleShoutReminder", "allBuffedText", RCL["Text when everyone is buffed"], LiveIcon),
                },
                anchorGet = ag, anchorSet = as, targets = Others(RC.BATTLE_SHOUT_ICON_TARGETS, "count"),
                anchorDefaults = function() return RC:BattleShoutAnchorDefaults("icon", "count") end }))
            ag, as = self.UI:CustomAccess(db, "anchors", "names", Saved(LiveIcon))
            Place(self.UI:CreateTextElement(card, { label = RCL["Missing names"], key = "names", width = W,
                font = FontOf(db, "namesFont", "namesFontSize", RC.BATTLE_SHOUT_NAMES_FONT, "Rowdy  Stabbs  ~Pewpew", LiveIcon, 8, 20),
                anchorGet = ag, anchorSet = as, targets = Others(RC.BATTLE_SHOUT_ICON_TARGETS, "names"),
                defaultTargetLabel = RCL["Beside the icon (Look tab)"],
                anchorDefaults = function() return RC:BattleShoutAnchorDefaults("icon", "names") end }))
            cardY = K.Desc(card, cardY, RCL["The names follow the side and gap on the Look tab; a position set here goes on top of them."])
            Finish(card, cardY - 6)

            local ptCard = self:CreateSettingsCard(parent, yPos, RCL["Party tracker"])
            local ptY = -32
            W = CardWidth(ptCard)
            local function PPlace(g) g:SetPoint("TOPLEFT", ptCard, "TOPLEFT", 14, ptY) ptY = ptY - g:GetHeight() - 14 end
            local fg, fs = self.UI:CustomAccess(ptDb, "formats", "name", Saved(LiveTracker))
            ag, as = self.UI:CustomAccess(ptDb, "anchors", "rowName", Saved(LiveTracker))
            PPlace(self.UI:CreateTextElement(ptCard, { label = RCL["Names"], key = "rowName", width = W,
                font = FontOf(ptDb, "rowFont", "fontSize", RC.BATTLE_SHOUT_TRACKER_FONT, "Rowdy   290 AP  1:01", LiveTracker, 8, 18),
                formatGet = fg, formatSet = fs, formatKinds = { name = true }, formatDefaults = RC.BATTLE_SHOUT_NAME_FORMAT,
                formatSample = function(spec) return RC.UI:FormatName("Bonkersthewarrior", spec, RC.BATTLE_SHOUT_NAME_FORMAT) end,
                anchorGet = ag, anchorSet = as, targets = Others(RC.BATTLE_SHOUT_ROW_TARGETS, "name"),
                anchorDefaults = function() return RC:BattleShoutAnchorDefaults("tracker", "rowName") end }))
            fg, fs = self.UI:CustomAccess(ptDb, "formats", "time", Saved(LiveTracker))
            ag, as = self.UI:CustomAccess(ptDb, "anchors", "rowStatus", Saved(LiveTracker))
            PPlace(self.UI:CreateTextElement(ptCard, { label = RCL["Status and time"], key = "rowStatus", width = W,
                formatGet = fg, formatSet = fs, formatKinds = { time = true }, formatDefaults = RC.BATTLE_SHOUT_TIME_FORMAT,
                formatSample = function(spec) return RC.UI:FormatTime(61.4, spec, RC.BATTLE_SHOUT_TIME_FORMAT) end,
                anchorGet = ag, anchorSet = as, targets = Others(RC.BATTLE_SHOUT_ROW_TARGETS, "status"),
                anchorDefaults = function() return RC:BattleShoutAnchorDefaults("tracker", "rowStatus") end }))
            local titleDefaults = { size = ptDb.fontSize or 11, outline = "OUTLINE", shadow = true }
            ag, as = self.UI:CustomAccess(ptDb, "anchors", "title", Saved(LiveTracker))
            PPlace(self.UI:CreateTextElement(ptCard, { label = RCL["Title"], key = "title", width = W,
                font = FontOf(ptDb, "titleFont", nil, titleDefaults, RCL["Battle Shout"], LiveTracker, 8, 18),
                colors = { ThemeColorOf("battleShoutPartyTracker", "titleText", RCL["Title colour"], LiveTracker) },
                anchorGet = ag, anchorSet = as, targets = Others(RC.BATTLE_SHOUT_TITLE_TARGETS, "title"),
                anchorDefaults = function() return RC:BattleShoutAnchorDefaults("tracker", "title") end }))
            ptY = K.Desc(ptCard, ptY - 4, RCL["Names are drawn in their class colour; the status text uses the colours on the Look tab."])
            Finish(ptCard, ptY)

        elseif selectedTab == "animation" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Reminder icon"])
            local cardY = -32
            cardY = K.Anim(card, cardY, db, "showAnim", ANIM_IN, RCL["When it appears"], "in", Replay)
            cardY = K.Anim(card, cardY, db, "alertAnim", ANIM_ALERT, RCL["While someone is missing"], "update", Replay)
            cardY = K.Anim(card, cardY, db, "hideAnim", ANIM_OUT, RCL["When it goes"], "out", Replay)
            Finish(card, cardY)

            local ptCard = self:CreateSettingsCard(parent, yPos, RCL["Party tracker"])
            local ptY = -32
            ptY = K.Anim(ptCard, ptY, ptDb, "showAnim", ANIM_IN, RCL["When it appears"], "in", Replay)
            ptY = K.Anim(ptCard, ptY, ptDb, "hideAnim", ANIM_OUT, RCL["When it goes"], "out", Replay)
            ptY = K.Desc(ptCard, ptY, RCL["Appearance > Motion can turn every animation off or speed them all up."])
            Finish(ptCard, ptY)

        elseif selectedTab == "sound" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Warning sound"])
            local cardY = -32
            self.UI:CreateSettingCheckbox(card, cardY, RCL["Play sound when warning appears"], db.playSound, function(cb)
                db.playSound = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.playSound); Save()
            end)
            cardY = cardY - 28
            local sp = self.UI:CreateSoundPicker(card, {
                selected = db.soundKey or "WR: Warning", width = 240,
                onPick = function(key) db.soundKey = key; Save() end,
            })
            sp:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            cardY = cardY - 30
            cardY = K.Desc(card, cardY, RCL["Plays once each time the icon starts warning. The spoken 'battle shout' follows Reminder Settings > Sound > Enable voice alerts (TTS)."])
            Finish(card, cardY)

        elseif selectedTab == "position" then
            local card = self:CreateSettingsCard(parent, yPos, RCL["Reminder icon"])
            local cardY = -32

            local posText = self:CreateFontString(card, "OVERLAY", nil, 10)
            posText:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            posText:SetText(string.format(RCL["Current: %s (%.0f, %.0f)"], db.anchorPoint or "CENTER", db.xOffset or 0, db.yOffset or 0))
            Light(posText)
            cardY = cardY - 22
            cardY = K.Desc(card, cardY, RCL["Unlock position to drag the icon, or use /rc moveui for precise placement."])

            self.UI:CreateSettingCheckbox(card, cardY, RCL["Lock position"], db.locked, function(cb)
                db.locked = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, db.locked)
                if RC.battleShoutReminder and RC.battleShoutReminder.frame then
                    RC.battleShoutReminder.frame:EnableMouse(not db.locked)
                end
                Save()
            end)
            cardY = cardY - 30

            local resetBtn = self.UI:CreateStyledButton(card, RCL["Reset Position"], 120, 24)
            resetBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            resetBtn:SetScript("OnClick", function()
                local f = RC.battleShoutReminder and RC.battleShoutReminder.frame
                if f then
                    RC.Position.ResetFrame(f, true)
                else
                    db.anchorPoint = "CENTER"; db.xOffset = 200; db.yOffset = 0; db.centred = true
                end
                RC:UpdateBattleShoutReminderAppearance(); Save()
                Rerender("position")
            end)

            local testBtn = self.UI:CreateStyledButton(card, RCL["Show Test Display"], 150, 24)
            testBtn:SetPoint("LEFT", resetBtn, "RIGHT", 8, 0)
            testBtn:SetScript("OnClick", function()
                local bsFrame = RC.battleShoutReminder and RC.battleShoutReminder.frame
                if bsFrame then
                    RC:FillBattleShoutIcon(bsFrame, true, "3", db.showMissingNames and SAMPLE_NAMES or nil)
                    RC:ShowBattleShoutIcon(bsFrame, true)
                else
                    RC:Print(RCL["Frame not created - enable the feature first"])
                end
            end)
            cardY = cardY - 34
            Finish(card, cardY)

            local ptCard = self:CreateSettingsCard(parent, yPos, RCL["Party tracker"])
            local ptY = -32
            self.UI:CreateSettingCheckbox(ptCard, ptY, RCL["Locked (click-through)"], ptDb.locked, function(cb)
                ptDb.locked = cb:GetChecked(); RC:ForceCheckboxUpdate(cb, ptDb.locked)
                local fr = RC.battleShoutPartyTracker and RC.battleShoutPartyTracker.frame
                if fr then
                    fr:EnableMouse(not ptDb.locked)
                    if fr.handle then fr.handle.Refresh() end
                end
                Save()
            end)
            ptY = ptY - 30
            ptY = K.Slider(ptCard, ptY, RCL["Scale"], 0.5, 2.0, tonumber(ptDb.scale) or 1, 0.05, K.Pct,
                function(v) ptDb.scale = v; LiveTracker() end)
            local ptReset = self.UI:CreateStyledButton(ptCard, RCL["Reset Position"], 120, 24)
            ptReset:SetPoint("TOPLEFT", ptCard, "TOPLEFT", 14, ptY)
            ptReset:SetScript("OnClick", function()
                local f = RC.battleShoutPartyTracker and RC.battleShoutPartyTracker.frame
                if f then RC.Position.ResetFrame(f, true) end
                Save()
            end)
            ptY = ptY - 32
            ptY = K.Desc(ptCard, ptY, RCL["Edit Mode (/rc moveui) shows the tracker with a sample party so you can drag it into place."])
            Finish(ptCard, ptY)
            yPos = self.UI:FrameLayerCard(parent, yPos, BS, LiveIcon, { title = RCL["Icon layer and scale"] })
            yPos = self.UI:FrameLayerCard(parent, yPos, PT, LiveTracker, { title = RCL["Tracker layer"], scale = false })

            -- the parts inside each frame, and how the tracker's rows stack
            local function Saved(live) return function() RC:SaveConfigurationToProfile() live() end end
            local pc = self:CreateSettingsCard(parent, yPos, RCL["Parts"])
            local pY = -32
            local W = CardWidth(pc)
            local function Place(g) g:SetPoint("TOPLEFT", pc, "TOPLEFT", 14, pY) pY = pY - g:GetHeight() - 14 end
            local ag, as = self.UI:CustomAccess(db, "anchors", "icon", Saved(LiveIcon))
            Place(self.UI:CreateFrameElement(pc, { label = RCL["Icon art"], key = "icon", width = W,
                anchorGet = ag, anchorSet = as, targets = Others(RC.BATTLE_SHOUT_ICON_TARGETS, "icon"),
                defaultTargetLabel = RCL["Fills the icon frame"],
                anchorDefaults = function() return RC:BattleShoutAnchorDefaults("icon", "icon") end }))
            ag, as = self.UI:CustomAccess(ptDb, "anchors", "titleIcon", Saved(LiveTracker))
            Place(self.UI:CreateFrameElement(pc, { label = RCL["Tracker title icon"], key = "titleIcon", width = W,
                anchorGet = ag, anchorSet = as, targets = Others(RC.BATTLE_SHOUT_TITLE_TARGETS, "titleIcon"),
                anchorDefaults = function() return RC:BattleShoutAnchorDefaults("tracker", "titleIcon") end }))
            ag, as = self.UI:CustomAccess(ptDb, "anchors", "rowIcon", Saved(LiveTracker))
            Place(self.UI:CreateFrameElement(pc, { label = RCL["Bloodrage icon"], key = "rowIcon", width = W,
                anchorGet = ag, anchorSet = as, targets = Others(RC.BATTLE_SHOUT_ROW_TARGETS, "icon"),
                anchorDefaults = function() return RC:BattleShoutAnchorDefaults("tracker", "rowIcon") end }))
            pY = K.Desc(pc, pY, RCL["Reset puts a part back where it always sat."])
            Finish(pc, pY)

            local lc = self:CreateSettingsCard(parent, yPos, RCL["Tracker rows"])
            local lY = -32
            local lg, ls = self.UI:CustomAccess(ptDb, "layout", nil, Saved(LiveTracker))
            local lp = self.UI:CreateLayoutPicker(lc, { width = CardWidth(lc), get = lg, set = ls,
                defaults = { grow = "DOWN", spacingY = 0, padding = 0, max = 5 },
                fields = { grow = true, spacingY = true, padding = true, max = true, sort = true, reverse = true },
                grows = { "DOWN", "UP" }, sorts = RC.BATTLE_SHOUT_SORTS, maxItems = 5 })
            lp:SetPoint("TOPLEFT", lc, "TOPLEFT", 14, lY)
            lY = lY - lp:GetHeight() - 8
            lY = K.Desc(lc, lY, RCL["Row height is on the Look tab. Order by Default keeps your group's own order."])
            Finish(lc, lY)
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
        if isTabSwitch then self:RestoreScrollPosition(self.sidebarConfigFrame) end
    end
