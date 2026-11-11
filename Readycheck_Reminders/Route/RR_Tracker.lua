------------------------------------------------------------------------
-- Readycheck - Raid Route Tracker Frame
-- Renders the floating "current/next step" tracker UI for RR_Engine's
-- route: current-step label + progress, gear/reminder icon row, and
-- optional look-ahead ("Next: ...") / look-behind context lines.
-- Read-only view onto RR state; all step advancement lives in RR_Engine.
-- Registers with RC.UIMover so it is user-moveable like other frames.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local RC = _G.Readycheck
if not RC then return end
RC._rrs = RC._rrs or {}
local _rrs = RC._rrs
local RR = RC.RaidRoute
local ShortMobName, StepConfigGear = _rrs.ShortMobName, _rrs.StepConfigGear
    -- max gear/trinket/slot/reminder icons shown in the current-step row.
    local TRACKER_MAX_ICONS = 5

    local function TrackerSetIcon(setName)
        -- 134400 is Blizzard's generic question-mark placeholder texture
        -- ID; treat it as "no real icon" so the fallback chest icon is
        -- used instead of a blank question mark.
        local function clean(ic)
            if ic == 134400 then return nil end
            if type(ic) == "string" and ic:lower():find("questionmark", 1, true) then
                return nil
            end
            return ic
        end
        if RC.GearManager and RC.GearManager.sets and RC.GearManager.sets[setName]
           and clean(RC.GearManager.sets[setName].icon) then
            return clean(RC.GearManager.sets[setName].icon)
        end
        if ItemRackUser and ItemRackUser.Sets and ItemRackUser.Sets[setName]
           and clean(ItemRackUser.Sets[setName].icon) then
            return clean(ItemRackUser.Sets[setName].icon)
        end
        return "Interface\\Icons\\INV_Chest_Plate16"
    end

    local function TrackerItemIcon(itemId)
        -- -1 is the route's UNEQUIP sentinel for this slot; show an empty-
        -- bag icon rather than trying to look up a real item.
        if itemId == -1 then return "Interface\\Icons\\INV_Misc_Bag_08" end
        if not itemId or itemId == 0 then return nil end
        local _, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemId)
        return icon
    end

    local function TrackerEncLabel(step, relBoss)
        if step.type ~= "encounter" or (step.desc and step.desc ~= "") then
            return nil
        end
        local verb = "Target"
        if step.when == "end" then verb = "Kill" end
        if step.when == "wipe" then verb = "On wipe:" end
        local boss = step.boss or "?"
        if relBoss and relBoss == boss then return verb end
        return verb .. " " .. ShortMobName(boss)
    end

    -- The step's title and, for a kill step, its progress as a second
    -- value ("0/6") so the tracker can draw it as its own gold badge.
    local function TrackerGateText(self, step)
        if step.type == "kills" then
            local reqs = self:GetStepMobs(step)
            local cur, total = self:GetStepProgress(step)
            local prog = (total > 0) and (cur .. "/" .. total) or nil
            if step.desc and step.desc ~= "" then
                return self.active .. ". " .. step.desc, prog
            end
            if reqs and #reqs > 1 then
                return self.active .. ". Kill " .. total .. " mobs", prog
            end
            local label
            if reqs and #reqs == 1 and (not step.desc or step.desc == "") then
                label = (reqs[1].kills or 1) .. "x "
                    .. ShortMobName(reqs[1].mob or "?")
            else
                label = self:StepLabel(step):gsub("^%l", string.upper)
            end
            return self.active .. ". " .. label, prog
        end
        local enc = TrackerEncLabel(step)
        local label = enc or self:StepLabel(step):gsub("^%l", string.upper)
        return self.active .. ". " .. label, nil
    end

    -- multi-mob step detail line, e.g. "Add A 2/3  -  Add B 1/1"; single-
    -- mob steps show progress inline on the main label instead.
    local function CompactMobProgress(self, step)
        if not step or step.type ~= "kills" then return nil end
        local reqs = self:GetStepMobs(step)
        if not reqs or #reqs < 2 then return nil end
        local shorts, seenShort, collide = {}, {}, {}
        for _, r in ipairs(reqs) do
            local sn = ShortMobName(r.mob or "?")
            if seenShort[sn] then collide[sn] = true end
            seenShort[sn] = true
            shorts[#shorts + 1] = sn
        end
        local parts = {}
        for i, r in ipairs(reqs) do
            local sn = shorts[i]
            if #shorts <= 2 then sn = r.mob or sn end
            if collide[sn] then
                local full = r.mob or "?"
                local two = full:match("(%S+%s+%S+)$")
                sn = two or full
            end
            parts[#parts + 1] = sn .. " "
                .. self:MobHave(step, r.mob) .. "/" .. (r.kills or 1)
        end
        if #parts <= 2 then
            return table.concat(parts, "  -  ")
        end
        local rows = {}
        for i = 1, #parts, 2 do
            rows[#rows + 1] = parts[i]
                .. (parts[i + 1] and ("  -  " .. parts[i + 1]) or "")
        end
        return table.concat(rows, "\n")
    end

    local SLOT_TOKEN = {
        [1]="HeadSlot",[2]="NeckSlot",[3]="ShoulderSlot",[4]="ShirtSlot",
        [5]="ChestSlot",[6]="WaistSlot",[7]="LegsSlot",[8]="FeetSlot",
        [9]="WristSlot",[10]="HandsSlot",[11]="Finger0Slot",[12]="Finger1Slot",
        [13]="Trinket0Slot",[14]="Trinket1Slot",[15]="BackSlot",
        [16]="MainHandSlot",[17]="SecondaryHandSlot",[18]="RangedSlot",
        [19]="TabardSlot",
    }
    local _slotTexCache = {}
    -- icon shown for a slot targeted by an UNEQUIP (-1) action: the
    -- game's own "nothing equipped here" texture for that slot type.
    local function SlotEmptyIcon(inv)
        local hit = _slotTexCache[inv]
        if hit then return hit end
        local tex
        local token = SLOT_TOKEN[inv]
        if token and GetInventorySlotInfo then
            local ok, _, t = pcall(GetInventorySlotInfo, token)
            if ok and t then tex = t end
        end
        tex = tex or "Interface\\Icons\\INV_Misc_Bag_08"
        _slotTexCache[inv] = tex
        return tex
    end
    _rrs.SlotEmptyIcon = SlotEmptyIcon

    local function CtxLabel(self, step)
        if step.desc and step.desc ~= "" then return step.desc end
        if step.type == "kills" then
            local reqs = self:GetStepMobs(step)
            if reqs and #reqs > 1 then
                local total = 0
                for _, r in ipairs(reqs) do total = total + (r.kills or 1) end
                return "Kill " .. total .. " mobs"
            end
            if reqs and #reqs == 1 then
                return "Kill " .. (reqs[1].kills or 1) .. "x "
                    .. ShortMobName(reqs[1].mob or "?")
            end
        end
        local cur = self:GetSteps()
        cur = cur and cur[self.active]
        local enc = TrackerEncLabel(step,
            cur and cur.type == "encounter" and cur.boss or nil)
        if enc then return enc end
        return self:StepLabel(step):gsub("^%l", string.upper)
    end

    local function FillStepIcons(step, pool)
        local n = 0
        local a = step and step.actions
        -- sharedSlots tracks inv slots already iconed from the boss's
        -- config-driven forceEquip map so the step's own actions.slots
        -- (or the legacy deathSlot1/2 fields) don't draw a duplicate icon
        -- for the same slot.
        local sharedSlots = {}
        local seenTex = {}
        local function Add(tex)
            if tex == 134400 or tex == "134400" or (type(tex) == "string"
               and tex:lower():find("questionmark", 1, true)) then
                tex = "Interface\\Icons\\INV_Misc_Note_01"
            end
            if not tex or n >= #pool then return end
            if seenTex[tex] then return end
            seenTex[tex] = true
            n = n + 1
            pool[n]:SetTexture(tex)
            pool[n]:Show()
            if pool[n].bd then pool[n].bd:Show() end
        end
        if step and step.type == "encounter" and step.boss and step.boss ~= "" then
            local sset = RR:SharedBossSet(step)
            if sset then Add(TrackerSetIcon(sset)) end
            local prof = RC.GetActiveRaidProfile and RC:GetActiveRaidProfile(RR.raidName)
            local b = prof and prof.bosses and prof.bosses[step.boss]
            local fe = b and b.forceEquip
            if fe then
                local map = (step.when == "start") and fe.onTarget or fe.onDeath
                if type(map) == "table" then
                    for slot, itemId in pairs(map) do
                        if itemId and itemId ~= 0 then
                            sharedSlots[slot] = true
                            Add(TrackerItemIcon(itemId))
                        end
                    end
                end
                if step.when ~= "start" then
                    if fe.deathSlot1 and not sharedSlots[13] then
                        sharedSlots[13] = true
                        Add(TrackerItemIcon(fe.deathSlot1))
                    end
                    if fe.deathSlot2 and not sharedSlots[14] then
                        sharedSlots[14] = true
                        Add(TrackerItemIcon(fe.deathSlot2))
                    end
                end
            end
        end
        if a then
            if a.gearSet and a.gearSet ~= "" then Add(TrackerSetIcon(a.gearSet)) end
            if a.trinket1 and a.trinket1 ~= 0 and not sharedSlots[13] then Add(TrackerItemIcon(a.trinket1)) end
            if a.trinket2 and a.trinket2 ~= 0 and not sharedSlots[14] then Add(TrackerItemIcon(a.trinket2)) end
            if a.slots then
                for invSlot, itemId in pairs(a.slots) do
                    if sharedSlots[invSlot] then
                    elseif itemId == -1 then Add(SlotEmptyIcon(invSlot))
                    elseif itemId and itemId ~= 0 then Add(TrackerItemIcon(itemId)) end
                end
            end
            if a.reminders then
                for _, r in ipairs(a.reminders) do
                    RR:HealReminderText(r)
                    if r.text and r.text ~= "" then
                        Add(r.icon or "Interface\\Icons\\INV_Misc_Note_01")
                    end
                end
            elseif a.reminderText and a.reminderText ~= "" then
                Add(a.reminderIcon or "Interface\\Icons\\INV_Misc_Note_01")
            end
        end
        for k = n + 1, #pool do
            pool[k]:Hide()
            if pool[k].bd then pool[k].bd:Hide() end
        end
        if step and step.type == "encounter" then
            local cfgSet, cfgSlots = StepConfigGear(RR, step)
            if cfgSet then Add(TrackerSetIcon(cfgSet)) end
            for _, o in ipairs(cfgSlots or {}) do
                Add(TrackerItemIcon(o.id))
            end
        end
        return n
    end

    ------------------------------------------------------------------
    -- THE PANEL
    -- A small Readycheck panel: the title bar wears the same header art
    -- as every Readycheck window (gradient fill, accent rule) with the
    -- step as its title and the kill count in a flat gold tag at the
    -- right; the body lists each mob of the pack with its own thin bar;
    -- the footer holds the step's gear and reminders as icons with one
    -- quiet label saying when they fire; look-ahead lines sit under
    -- that, dimmer. Fonts through RC:CreateFontString, colours through
    -- RC:GetColor, the bar texture the user picked for Readycheck.
    ------------------------------------------------------------------
    local PAD = 8                 -- inner padding
    local HEAD_H = 22             -- title bar
    local ICON = 20               -- footer icons
    local ICON_GAP = 3
    local CTX_ICON = 12
    local MIN_W, MAX_W = 200, 360
    RR.TRACKER_SCALE = 0.85       -- the default scale: a side panel, not a window
    local MOB_ROWS = 6            -- mob rows pooled
    local REM_ROWS = 4            -- matches REMINDER_MAX in RR_UseWatch
    local CTX_ROWS = 4            -- 3 next + 1 prev

    local function Shadow(fs)
        fs:SetShadowOffset(1, -1)
        fs:SetShadowColor(0, 0, 0, 0.9)
        return fs
    end

    local function BarTexture()
        return (RC.GetTexturePath and RC:GetTexturePath()) or RC.UI.FLAT
    end

    local function Ring(f, ic)
        local bc = RC:GetColor("ui", "borderNormal")
        local bd = f:CreateTexture(nil, "ARTWORK", nil, -1)
        bd:SetPoint("TOPLEFT", ic, "TOPLEFT", -1, 1)
        bd:SetPoint("BOTTOMRIGHT", ic, "BOTTOMRIGHT", 1, -1)
        bd:SetColorTexture(bc.r, bc.g, bc.b, 1)
        bd:Hide()
        ic.bd = bd
        return ic
    end

    local function Icon(f, size)
        local ic = Ring(f, f:CreateTexture(nil, "ARTWORK"))
        ic:SetSize(size, size)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ic:Hide()
        return ic
    end

    local function ShowIcon(ic, tex, on)
        if on then ic:SetTexture(tex) ic:Show() ic.bd:Show()
        else ic:Hide() ic.bd:Hide() end
    end

    function RR:EnsureTrackerFrame()
        if self.trackerFrame then return self.trackerFrame end
        if not (RC.UI and RC.GetColor and RC.CreateFontString) then return nil end
        return self:BuildTrackerFrame(UIParent)
    end

    -- The panel. On UIParent it is the live tracker (position, mover, nav
    -- arrows, padlock); on any other parent it is the settings preview's
    -- sample: the same parts and look, nothing bound or clickable.
    function RR:BuildTrackerFrame(parent)
        local isSample = parent ~= UIParent
        local f = CreateFrame("Frame", (not isSample) and "ReadycheckRouteTracker" or nil, parent)
        f:SetSize(240, 60)
        if not isSample then
        -- Pinned by its text edge - TOPLEFT, or TOPRIGHT when the text is
        -- right-aligned - because its width changes with the step and a
        -- centre-pinned frame would grow out of both sides and wander.
        -- An old centre-pinned save is converted in place the first time.
        local function TrackerStore()
            local st = RR:GetSettings()
            if not st then return nil end
            st.trackerPos = st.trackerPos or {}
            local tp = st.trackerPos
            if tp.point == nil and tp.centred then tp.point = "CENTER" end
            return tp
        end
        local function TrackerPoint()
            local st = RR:GetSettings()
            return (st and st.trackerAlignRight == true) and "TOPRIGHT" or "TOPLEFT"
        end
        -- Never placed: it starts under the minimap, in the top-right
        -- corner where quest trackers live - out of the way, in view,
        -- and right-aligned so a wider step grows towards the screen's
        -- middle, not off its edge. A saved spot keeps its own alignment.
        do
            local st = RR:GetSettings()
            local tp = st and st.trackerPos
            if st and st.trackerAlignRight == nil and not (type(tp) == "table" and type(tp.x) == "number") then
                st.trackerAlignRight = true
            end
        end
        -- the saved spot is in the frame's own units, so the scale it was
        -- saved at goes on BEFORE the spot is applied
        do
            local st = RR:GetSettings()
            local sc = tonumber(st and st.trackerScale) or RR.TRACKER_SCALE
            if sc < 0.6 then sc = 0.6 elseif sc > 1.6 then sc = 1.6 end
            f:SetScale(sc)
        end
        RC.Position.Bind(f, TrackerStore, { point = TrackerPoint(), xKey = "x", yKey = "y",
            pointKey = "point", default = { point = "TOPRIGHT", relPoint = "TOPRIGHT", x = -12, y = -210 },
            -- (a fresh character: beside the quest tracker, not on it;
            -- the numbers are in the tracker's own 85% units)
            gen2 = { point = "TOPRIGHT", relPoint = "TOPRIGHT", x = -318, y = -210 } })
        RC.Position.RestoreFrame(f)
        function RR:ApplyTrackerAlign()
            local want = TrackerPoint()
            local b = f.__rcPos
            if not b or b.point == want then return end
            local x, y = RC.Position.Capture(f, want)
            b.point = want
            if x then RC.Position.SetFrame(f, x, y, true) end
        end
        f:SetFrameStrata("MEDIUM")
        f:SetClampedToScreen(true)
        f:Hide()
        end

        -- the panel: card fill, 1px ring
        local cardBg = RC:GetColor("ui", "cardBackground")
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(RC.UI.FLAT)
        bg:SetVertexColor(cardBg.r, cardBg.g, cardBg.b, 0.94)
        f.bg = bg
        f.border = RC.UI:CreateSimpleBorder(f)

        -- the title bar, in Readycheck's header art
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

        local title = Shadow(RC:CreateFontString(head, "OVERLAY", nil, 12))
        title:SetPoint("LEFT", head, "LEFT", PAD, 1)
        title:SetJustifyH("LEFT")
        title:SetWordWrap(false)
        local ht = RC:GetColor("ui", "headerText")
        title:SetTextColor(ht.r, ht.g, ht.b)
        f.title = title

        -- the count: gold digits at the other end of the title bar
        local tag = CreateFrame("Frame", nil, head)
        tag:SetHeight(14)
        tag:SetPoint("RIGHT", head, "RIGHT", -PAD, 1)
        local tagText = Shadow(RC:CreateFontString(tag, "OVERLAY", nil, 12))
        tagText:SetPoint("CENTER", tag, "CENTER", 0, 0)
        tagText:SetJustifyH("CENTER")
        tag.text = tagText
        tag:Hide()
        f.tag = tag
        if RC.UI.TagElement then RC.UI:TagElement(title, "title") RC.UI:TagElement(tagText, "count") end

        -- body: mob rows (name, count, thin bar)
        f.mobs = {}
        for i = 1, MOB_ROWS do
            local name = Shadow(RC:CreateFontString(f, "OVERLAY", nil, 11))
            name:SetJustifyH("LEFT")
            name:SetWordWrap(false)
            local cnt = Shadow(RC:CreateFontString(f, "OVERLAY", nil, 11))
            cnt:SetJustifyH("RIGHT")
            local track = f:CreateTexture(nil, "ARTWORK")
            track:SetTexture(RC.UI.FLAT)
            track:SetHeight(3)
            local fill = f:CreateTexture(nil, "ARTWORK", nil, 1)
            fill:SetHeight(3)
            name:Hide() cnt:Hide() track:Hide() fill:Hide()
            f.mobs[i] = { name = name, cnt = cnt, track = track, fill = fill }
        end
        -- a plain body line: "Equipping: X", "Use item to continue", or an
        -- encounter step's verb ("Target Anub'Rekhan")
        local detail = Shadow(RC:CreateFontString(f, "OVERLAY", nil, 11))
        detail:SetJustifyH("LEFT")
        detail:SetWordWrap(false)
        detail:Hide()
        f.detail = detail
        if RC.UI.TagElement then RC.UI:TagElement(detail, "detail") end
        -- reminders: icon + text
        f.rems = {}
        for i = 1, REM_ROWS do
            local ic = Icon(f, 16)
            local fs = Shadow(RC:CreateFontString(f, "OVERLAY", nil, 11))
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            fs:Hide()
            f.rems[i] = { icon = ic, fs = fs }
        end

        -- footer: rule, icons, the when-label
        local rule = f:CreateTexture(nil, "ARTWORK")
        rule:SetTexture(RC.UI.FLAT)
        rule:SetHeight(1)
        rule:Hide()
        f.rule = rule
        f.icons = {}
        for i = 1, TRACKER_MAX_ICONS do f.icons[i] = Icon(f, ICON) end
        local when = Shadow(RC:CreateFontString(f, "OVERLAY", nil, 10))
        when:SetJustifyH("LEFT")
        when:SetWordWrap(false)
        when:Hide()
        f.when = when
        if RC.UI.TagElement then RC.UI:TagElement(when, "when") end

        -- look-ahead / look-behind
        f.ctx = {}
        for i = 1, CTX_ROWS do
            local fs = Shadow(RC:CreateFontString(f, "OVERLAY", nil, 10))
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            fs:Hide()
            local icons = {}
            for k = 1, 4 do icons[k] = Icon(f, CTX_ICON) end
            f.ctx[i] = { fs = fs, icons = icons }
        end

        f.dbg = Shadow(RC:CreateFontString(f, "OVERLAY", nil, 9))
        f.dbg:SetJustifyH("LEFT")
        f.dbg:SetWordWrap(true)
        f.dbg:Hide()

        -- step arrows (back / complete), a hover-only strip above the panel
        local nav = CreateFrame("Frame", nil, isSample and f or UIParent)
        nav:SetSize(28, 11)
        nav:SetAlpha(0.4)
        nav:SetFrameStrata(f:GetFrameStrata())
        nav:SetFrameLevel(f:GetFrameLevel() + 5)
        f:HookScript("OnShow", function() nav:Show() end)
        f:HookScript("OnHide", function() nav:Hide() end)
        nav:SetShown(f:IsShown())
        f.navHolder = nav
        local dropArrow = RC:GetColor("dropdown", "arrow") or { r = 0.6, g = 0.6, b = 0.6 }
        local function NavArrow(rot)
            local btn = CreateFrame("Button", nil, nav)
            btn:SetSize(13, 11)
            local tex = btn:CreateTexture(nil, "ARTWORK")
            tex:SetSize(10, 10)
            tex:SetPoint("CENTER", btn, "CENTER", 0, 0)
            tex:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrow")
            tex:SetRotation(rot)
            tex:SetVertexColor(dropArrow.r, dropArrow.g, dropArrow.b, 1)
            -- the whole strip lights on hover (the padlock and grip share it)
            btn:SetScript("OnEnter", function() nav:SetAlpha(1) end)
            btn:SetScript("OnLeave", function() if not nav:IsMouseOver() then nav:SetAlpha(nav.idleAlpha or 0) end end)
            return btn
        end
        local btnPrev = NavArrow(math.rad(-90))
        local btnNext = NavArrow(math.rad(90))
        btnPrev:SetPoint("LEFT", nav, "LEFT", 0, 0)
        btnNext:SetPoint("RIGHT", nav, "RIGHT", 0, 0)
        if not isSample then
        btnPrev:SetScript("OnClick", function() RR:ManualBack() end)
        btnNext:SetScript("OnClick", function() RR:ManualAdvance() end)
        end
        btnPrev:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(RCL["Back one step"], 1, 1, 1)
            GameTooltip:AddLine(RCL["Pointer only - nothing fires."], 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        btnNext:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(RCL["Complete current step"], 1, 1, 1)
            GameTooltip:AddLine(RCL["Fires its gear and reminders, then advances."], 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        btnPrev:HookScript("OnLeave", function() GameTooltip:Hide() end)
        btnNext:HookScript("OnLeave", function() GameTooltip:Hide() end)
        f.btnPrev, f.btnNext = btnPrev, btnNext
        -- padlock + width grip on the title bar's far end, always faintly
        -- there, bright on hover; the drag sets the panel's width
        -- (trackerW), the layout flows inside it
        if isSample then return f end
        if RC.UI.AttachHudHandle then
            f.handle = RC.UI:AttachHudHandle(f, {
                inside = true, corner = "TOPRIGHT", insetX = 7, insetY = 6,
                getLocked = function() local st = RR:GetSettings() return not (st and st.trackerUnlocked == true) end,
                setLocked = function(locked)
                    local st = RR:GetSettings()
                    if not st then return end
                    st.trackerUnlocked = not locked
                    if RR.ApplyTrackerLock then RR:ApplyTrackerLock() end
                    RC:SaveConfigurationToProfile()
                    RR:RefreshTracker()
                end,
                getWidth = function() return f:GetWidth() end,
                setWidth = function(w)
                    local st = RR:GetSettings()
                    if st then st.trackerW = w end
                    RR:RefreshTracker()
                end,
                onWidthEnd = function() RC:SaveConfigurationToProfile() end,
                minW = 180, maxW = 480,
            })
        end

        self.trackerFrame = f
        f:SetMovable(true)
        f:RegisterForDrag("LeftButton")
        f:EnableMouse(false)
        RC.Position.MakeMovable(f, function()
            local st = RR:GetSettings()
            return st and st.trackerUnlocked == true
        end)
        function RR:ApplyTrackerLock()
            local st = self:GetSettings()
            f:EnableMouse(st ~= nil and st.trackerUnlocked == true)
            if f.handle then f.handle.Refresh() end
        end
        RR:ApplyTrackerLock()
        if RC.UIMover and RC.UIMover.RegisterFrame then
            RC.UIMover:RegisterFrame("routeTracker", f, "Route Next Step",
                { point = "CENTER", relPoint = "CENTER", x = 0, y = 280 })
        end
        return f
    end

    -- Repaints the theme colours (the settings' colour page calls the
    -- window-wide refresh; this keeps the panel in step).
    local function Paint(f)
        local cardBg = RC:GetColor("ui", "cardBackground")
        f.bg:SetVertexColor(cardBg.r, cardBg.g, cardBg.b, 0.94)
        if f.head.RepaintArt then f.head:RepaintArt() end
        local ht = RC:GetColor("ui", "headerText")
        f.title:SetTextColor(ht.r, ht.g, ht.b)
        local gold = RC:GetColor("ui", "accentGold")
        f.tag.text:SetTextColor(gold.r, gold.g, gold.b, 1)
        local nt = RC:GetColor("text", "normal")
        local gr = RC:GetColor("text", "gray")
        local el = RC:GetColor("ui", "elementBackground")
        local tex = BarTexture()
        for _, m in ipairs(f.mobs) do
            m.name:SetTextColor(nt.r, nt.g, nt.b)
            m.cnt:SetTextColor(gr.r, gr.g, gr.b)
            m.track:SetVertexColor(el.r + 0.06, el.g + 0.06, el.b + 0.06, 1)
            m.fill:SetTexture(tex)
            m.fill:SetVertexColor(gold.r, gold.g, gold.b, 1)
        end
        f.detail:SetTextColor(gr.r, gr.g, gr.b)
        for _, r in ipairs(f.rems) do r.fs:SetTextColor(ht.r, ht.g, ht.b) end
        local ru = RC:GetColor("ui", "headerAccent") or gold
        f.rule:SetVertexColor(ru.r, ru.g, ru.b, ru.a or 0.6)
        f.when:SetTextColor(gr.r, gr.g, gr.b)
        for _, c in ipairs(f.ctx) do c.fs:SetTextColor(gr.r, gr.g, gr.b) end
        local dg = RC:GetColor("text", "green")
        f.dbg:SetTextColor(dg.r, dg.g, dg.b)
    end

    local function HideAll(f)
        f.tag:Hide()
        for _, m in ipairs(f.mobs) do m.name:Hide() m.cnt:Hide() m.track:Hide() m.fill:Hide() end
        f.detail:Hide()
        for _, r in ipairs(f.rems) do ShowIcon(r.icon, nil, false) r.fs:Hide() end
        f.rule:Hide()
        for _, ic in ipairs(f.icons) do ShowIcon(ic, nil, false) end
        f.when:Hide()
        for _, c in ipairs(f.ctx) do c.fs:Hide() for _, ic in ipairs(c.icons) do ShowIcon(ic, nil, false) end end
        f.dbg:Hide()
        for _, s in ipairs(f.segs or {}) do s:Hide() end
        if f.mobLine then f.mobLine:Hide() end
        if f.swap then f.swap:Hide() end
    end

    ------------------------------------------------------------------
    -- THE BAR STYLE (trackerBand): the same step in a strip instead of
    -- a panel - one row with the step, its gold count and its gear and
    -- reminder icons; under it the pack as a bar of one segment per kill
    -- (a plain bar past 40); then one line of per-mob counts when the
    -- pack has more than one kind of mob. Detail and live reminders as
    -- in the panel. For a tracker docked along the top of something.
    ------------------------------------------------------------------
    local SEG_MAX, SEG_GAP, SEG_H = 40, 2, 6
    local BAND_ICON = 16
    local function Seg(f, i)
        f.segs = f.segs or {}
        local s = f.segs[i]
        if not s then
            s = f:CreateTexture(nil, "ARTWORK")
            s:SetTexture(RC.UI.FLAT)
            s:SetHeight(SEG_H)
            s:Hide()
            f.segs[i] = s
        end
        return s
    end
    local function MobLine(f)
        if not f.mobLine then
            local fs = Shadow(RC:CreateFontString(f, "OVERLAY", nil, 10))
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            fs:Hide()
            f.mobLine = fs
        end
        return f.mobLine
    end
    local function GoldHex()
        local g = RC:GetColor("ui", "accentGold")
        return string.format("%02x%02x%02x", math.floor(g.r * 255 + 0.5), math.floor(g.g * 255 + 0.5), math.floor(g.b * 255 + 0.5))
    end

    -- what the footer's icons do, for the label beside them
    local function WhenLabel(step)
        if step.type == "encounter" then
            if step.when == "start" then return RCL["on pull"] end
            if step.when == "wipe" then return RCL["on wipe"] end
            return RCL["after the kill"]
        end
        return RCL["when this is done"]
    end


    ------------------------------------------------------------------
    -- GEAR SWAPS UNDER THE BAR (bar style, trackerBandSwaps, on unless
    -- switched off): one line under the bar for the gear Readycheck just
    -- put on - the set's name, then each piece as old -> new (the old
    -- one dim and grey, the new one ringed) sliding in as it lands. A few
    -- seconds after the last piece it settles into one line, "Frost
    -- Resist equipped · 6 pieces", kept while the step lasts. The line's
    -- room is always kept in this style, so the bar never changes height.
    -- Swaps come from the swap notice's collector (RC:OnSwapFeed); waves
    -- of one step (the set, then the trinkets) merge into one line.
    ------------------------------------------------------------------
    local SWAP_H, SWAP_ICON, SWAP_ACTIVE, SWAP_MERGE = 14, 12, 4, 3
    local CHECK_TEX = "Interface\\AddOns\\Readycheck\\Media\\Checkmark"

    function RC:SwapFeedWanted()
        local s = RR.GetSettings and RR:GetSettings()
        return (s and s.enabled and s.trackerEnabled ~= false and s.trackerBand == true
            and s.trackerBandSwaps ~= false) and true or false
    end

    local function SwapLabel(label)
        local set = label and label:match("^" .. RCL["Gear set: "] .. "(.+)$")
        return set or label or RCL["Gear swap"]
    end

    function RC:OnSwapFeed(entry)
        if not (RC:SwapFeedWanted() and entry and entry.items and #entry.items > 0) then return end
        local cur = RR._swapFeed
        local generic = RC.SwapToast and RC.SwapToast.GENERIC or {}
        if cur and cur.step == RR.active and (entry.at - cur.at) <= SWAP_MERGE then
            local bySlot = {}
            for i, it in ipairs(cur.items) do if it.slot then bySlot[it.slot] = i end end
            for _, it in ipairs(entry.items) do
                local i = it.slot and bySlot[it.slot]
                if i then
                    -- the same slot twice: keep where it started, show where it ended
                    local was = cur.items[i]
                    it.oldIcon, it.oldId = was.oldIcon, was.oldId
                    cur.items[i] = it
                else
                    cur.items[#cur.items + 1] = it
                    if it.slot then bySlot[it.slot] = #cur.items end
                end
            end
            if generic[cur.label] and not generic[entry.label] then cur.label = entry.label end
            cur.at = entry.at
        else
            cur = { label = entry.label, items = {}, at = entry.at, step = RR.active }
            for i, it in ipairs(entry.items) do cur.items[i] = it end
            RR._swapFeed = cur
        end
        cur.fresh = true
        local at = cur.at
        C_Timer.After(SWAP_ACTIVE + 0.05, function()
            if RR._swapFeed and RR._swapFeed.at == at then RR:RefreshTracker() end
        end)
        RR:RefreshTracker()
    end

    local function SwapRow(f)
        if f.swap then return f.swap end
        local r = CreateFrame("Frame", nil, f)
        r:SetHeight(SWAP_H)
        r.rule = r:CreateTexture(nil, "ARTWORK")
        r.rule:SetTexture(RC.UI.FLAT)
        r.rule:SetHeight(1)
        r.rule:SetPoint("TOPLEFT", r, "TOPLEFT", 0, 2)
        r.rule:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, 2)
        r.tick = r:CreateTexture(nil, "OVERLAY")
        r.tick:SetSize(SWAP_ICON, SWAP_ICON)
        r.tick:SetTexture(CHECK_TEX)
        r.label = Shadow(RC:CreateFontString(r, "OVERLAY", nil, 10))
        r.label:SetWordWrap(false)
        r.more = Shadow(RC:CreateFontString(r, "OVERLAY", nil, 10))
        r.more:SetWordWrap(false)
        r.pairs = {}
        r:Hide()
        f.swap = r
        return r
    end

    local function SwapPair(r, i)
        local p = r.pairs[i]
        if p then return p end
        p = { old = Icon(r, SWAP_ICON), new = Icon(r, SWAP_ICON) }
        p.old:SetDesaturated(true)
        r.pairs[i] = p
        return p
    end

    -- lays the line out at y; returns nothing (its room is kept either way)
    local function RenderSwapRow(self, f, y, rowW, alignR)
        local r = SwapRow(f)
        -- a re-layout mid-slide would fight the slide's rest
        RC.Motion.Stop(r)
        for _, p in ipairs(r.pairs) do ShowIcon(p.old, nil, false) ShowIcon(p.new, nil, false) end
        r.tick:Hide() r.more:Hide() r.label:Hide()
        local feed = self._swapFeed
        -- a finished route's last swap (the after-kill gear) belongs to no
        -- step any more: it is the one that landed as the route ran out
        local lastOne = feed and self.finished and self._finAt and feed.at >= self._finAt - 1
        if not feed or (feed.step ~= self.active and not lastOne) then r:Hide() return end
        r:ClearAllPoints()
        r:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
        r:SetWidth(rowW)
        local ru = RC:GetColor("ui", "headerAccent")
        r.rule:SetVertexColor(ru.r, ru.g, ru.b, 0.35)
        local ht = RC:GetColor("ui", "headerText")
        local gr = RC:GetColor("text", "gray")
        local gold = RC:GetColor("ui", "accentGold")
        local active = (GetTime() - feed.at) < SWAP_ACTIVE
        -- the pieces from the line's start: { element, width, gap before }
        local seq = {}
        if active then
            r.label:SetText(SwapLabel(feed.label))
            r.label:SetTextColor(ht.r, ht.g, ht.b)
            r.label:Show()
            seq[1] = { r.label, r.label:GetStringWidth() or 0, 0 }
            local used = seq[1][2]
            local n = #feed.items
            local fit = math.max(1, math.floor((rowW - used - 40) / (2 * SWAP_ICON + 1 + 6)))
            local shown = math.min(n, fit, 12)
            for i = 1, shown do
                local it, p = feed.items[i], SwapPair(r, i)
                ShowIcon(p.old, it.oldIcon, true)
                p.old:SetAlpha(0.45)
                ShowIcon(p.new, it.icon, true)
                p.new.bd:SetColorTexture(gold.r, gold.g, gold.b, 1)
                seq[#seq + 1] = { p.old, SWAP_ICON, i == 1 and 8 or 6 }
                seq[#seq + 1] = { p.new, SWAP_ICON, 2 }
            end
            if n > shown then
                r.more:SetText("+" .. (n - shown))
                r.more:SetTextColor(gr.r, gr.g, gr.b)
                r.more:Show()
                seq[#seq + 1] = { r.more, r.more:GetStringWidth() or 0, 6 }
            end
        else
            local headline = (RC.SwapToast and RC.SwapToast.Headline and RC.SwapToast.Headline(feed.label))
                or SwapLabel(feed.label)
            local n = #feed.items
            r.tick:Show()
            seq[1] = { r.tick, SWAP_ICON, 0 }
            r.label:SetText(headline .. "  |cff" .. string.format("%02x%02x%02x",
                math.floor(gr.r * 255 + 0.5), math.floor(gr.g * 255 + 0.5), math.floor(gr.b * 255 + 0.5))
                .. "· " .. (n == 1 and RCL["1 piece"] or string.format(RCL["%d pieces"], n)) .. "|r")
            r.label:SetTextColor(ht.r, ht.g, ht.b)
            r.label:Show()
            seq[2] = { r.label, r.label:GetStringWidth() or 0, 4 }
        end
        local total = 0
        for _, e in ipairs(seq) do total = total + e[3] + e[2] end
        local x = alignR and math.max(0, rowW - total) or 0
        for _, e in ipairs(seq) do
            x = x + e[3]
            e[1]:ClearAllPoints()
            e[1]:SetPoint("LEFT", r, "LEFT", x, 0)
            x = x + e[2]
        end
        r:SetAlpha(active and 1 or 0.75)
        r:Show()
        if feed.fresh then
            feed.fresh = nil
            RC.Motion.Play(r, RR:SwapLineMotion(), "in")
        end
    end

    -- The swap line's entrance when a piece lands: raidRoute.trackerSwapAnim,
    -- else what it has always done - a 14px slide in from the text side's
    -- far end with a fade, 0.25s.
    function RR:SwapLineDefaults()
        local s = self:GetSettings()
        local alignR = s and s.trackerAlignRight == true
        return { style = "slide", duration = 0.25, easing = "easeOutQuad", distance = 14,
                 dir = alignR and "left" or "right" }
    end
    function RR:SwapLineMotion()
        local s = self:GetSettings()
        local spec = s and s.trackerSwapAnim
        if type(spec) == "table" then return spec end
        return self:SwapLineDefaults()
    end

    function RR:RefreshTracker()
        local settings = self:GetSettings()
        if not settings then return end
        local alignR = settings.trackerAlignRight == true
        local ctxCount = (settings.trackerShowContext == true)
            and tonumber(settings.trackerNextCount) or 0
        if ctxCount == nil then ctxCount = 1 end
        if ctxCount < 0 then ctxCount = 0 elseif ctxCount > 3 then ctxCount = 3 end
        local showCtx = ctxCount > 0

        local steps = self:GetSteps()
        local step = steps and self.active <= #steps and steps[self.active] or nil
        local visible = settings.enabled
                    and (settings.trackerEnabled ~= false)
                    and self.raidName ~= nil
                    and (step ~= nil or self.finished)
        -- BAR STYLE, ROUTE DONE: the bar shows the last swap (the after-kill
        -- gear) for its few seconds, or "Route complete" for two when there
        -- is none, then folds away so whatever it is docked to gets its
        -- room back. A swap that lands a little later brings it back for
        -- that swap; anything a minute after the finish does not.
        if not self.finished then self._finAt, self._foldAt = nil, nil end
        if visible and not step and self.finished and settings.trackerBand == true then
            local now = GetTime()
            if not self._finAt then self._finAt = now end
            local foldAt = self._finAt + 2
            local feed = self._swapFeed
            if feed and feed.at >= self._finAt - 1 and feed.at - self._finAt <= 60 then
                foldAt = math.max(foldAt, feed.at + SWAP_ACTIVE + 0.3)
            end
            if now >= foldAt then
                visible = false
            elseif self._foldAt ~= foldAt then
                self._foldAt = foldAt
                C_Timer.After(foldAt - now + 0.05, function()
                    if self._foldAt == foldAt then self:RefreshTracker() end
                end)
            end
        end
        local hasRems = #self.activeReminders > 0
        if not visible and not hasRems then
            if self.trackerFrame then self.trackerFrame:Hide() end
            return
        end
        -- not tracking here (no raid, route off): the panel only carries
        -- the live reminders
        if not visible then step = nil end
        local f = self:EnsureTrackerFrame()
        if not f then return end
        HideAll(f)
        Paint(f)

        -- scale, box, alignment
        local sc = tonumber(settings.trackerScale) or RR.TRACKER_SCALE
        if sc < 0.6 then sc = 0.6 elseif sc > 1.6 then sc = 1.6 end
        if math.abs((f:GetScale() or 1) - sc) > 0.001 then
            if RC.Position.SetScaleKeepingPoint then RC.Position.SetScaleKeepingPoint(f, sc, true)
            else f:SetScale(sc) end
        end
        local noBg = settings.trackerNoBg == true
        f.bg:SetShown(not noBg)
        if f.border then
            if RC.UI.SetBorderShown then RC.UI:SetBorderShown(f.border, not noBg)
            else for _, t in pairs(f.border) do if type(t) == "table" and t.SetShown then t:SetShown(not noBg) end end end
        end
        -- without the box the title bar's gradient and its cut-outs go
        -- too; the accent rule under the title and the thin bars stay,
        -- which reads as a clean floating list rather than a broken panel
        f.head.fill:SetShown(not noBg)
        if f.head._art then
            f.head._art.cutL:SetShown(not noBg)
            f.head._art.cutD:SetShown(not noBg)
        end
        f.rule:SetAlpha(noBg and 0.5 or 1)
        local J = alignR and "RIGHT" or "LEFT"
        f.title:SetJustifyH(J)
        f.detail:SetJustifyH(J)
        f.when:SetJustifyH(J)
        for _, c in ipairs(f.ctx) do c.fs:SetJustifyH(J) end
        for _, r in ipairs(f.rems) do r.fs:SetJustifyH(J) end
        -- the nav strip
        do
            local nv = f.navHolder
            local unlocked = settings.trackerUnlocked == true
            nv.idleAlpha = tonumber(settings.trackerNavAlpha) or 0
            if not nv:IsMouseOver() then nv:SetAlpha(nv.idleAlpha) end
            for _, bb in ipairs({ f.btnPrev, f.btnNext }) do
                if bb and not bb:IsMouseOver() then bb:SetAlpha(1) end
            end
            nv:SetScale(f:GetScale())
            nv:ClearAllPoints()
            local mode = settings.trackerNavPos or "auto"
            if mode == "auto" then mode = alignR and "tl" or "tr" end
            if mode == "tl" then nv:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 1)
            elseif mode == "tr" then nv:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, 1)
            elseif mode == "bl" then nv:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, -1)
            else nv:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -1) end
        end

        -- anchors run from the text edge; x is the inset from that edge
        local function PT(el, x, y)
            el:ClearAllPoints()
            if alignR then el:SetPoint("TOPRIGHT", f, "TOPRIGHT", -x, y)
            else el:SetPoint("TOPLEFT", f, "TOPLEFT", x, y) end
        end
        -- the panel is as wide as the user dragged it; untouched, it is as
        -- wide as its content needs (MIN_W..MAX_W)
        local fixedW = tonumber(settings.trackerW)
        local band = settings.trackerBand == true
        -- a docked bar may be as wide as what it is docked to
        if fixedW and (fixedW < 180 or fixedW > (band and 1000 or 480)) then fixedW = nil end
        local natW = MIN_W
        local function Wide(w) if w + 2 * PAD > natW then natW = w + 2 * PAD end end
        local wrapW = fixedW or MAX_W            -- what texts may run to
        -- the title bar's far end holds the padlock and grip
        local HANDLE_W = f.handle and 34 or 0

        -- ---- title bar
        local trans = self._transition
        if trans and GetTime() >= trans.expires then trans = nil self._transition = nil end
        local equipTrans = trans and trans.equip or nil
        local basic = settings.trackerBasic == true
        local titleText, progText
        if not step then
            titleText = self.finished and RCL["Route complete"] or RCL["Reminders"]
        elseif basic then
            titleText = (step.desc and step.desc ~= "" and step.desc) or self:StepLabel(step)
        else
            titleText, progText = TrackerGateText(self, step)
        end
        f.title:SetText(titleText or "")
        f.title:ClearAllPoints()
        if alignR then f.title:SetPoint("RIGHT", f.head, "RIGHT", -(PAD + HANDLE_W), 1)
        else f.title:SetPoint("LEFT", f.head, "LEFT", PAD, 1) end
        local titleW = (f.title:GetStringWidth() or 0) + HANDLE_W
        if progText and not basic then
            f.tag.text:SetText(progText)
            f.tag:SetWidth((f.tag.text:GetStringWidth() or 20) + 2)
            f.tag:ClearAllPoints()
            if alignR then f.tag:SetPoint("LEFT", f.head, "LEFT", PAD, 1)
            elseif band then f.tag:SetPoint("LEFT", f.title, "LEFT", math.min(f.title:GetStringWidth() or 0, wrapW - 80) + 8, 0)
            else f.tag:SetPoint("RIGHT", f.head, "RIGHT", -(PAD + HANDLE_W), 1) end
            f.tag:Show()
            titleW = titleW + 10 + f.tag:GetWidth()
        end
        Wide(titleW)
        f.title:SetWidth(wrapW)
        local y = -(HEAD_H + 1) - 6
        f._band = nil

        -- ---- body
        local bodyLines = 0
        if step and not basic then
            -- the kill rows
            local reqs = step.type == "kills" and self:GetStepMobs(step) or nil
            if band and reqs and #reqs > 0 and not equipTrans then
                -- one segment per kill, then the per-mob counts
                local have, need = 0, 0
                local parts, gold = {}, GoldHex()
                for _, r in ipairs(reqs) do
                    local h, n = self:MobHave(step, r.mob), (r.kills or 1)
                    have, need = have + math.min(h, n), need + n
                    parts[#parts + 1] = (r.mob or "?") .. " |cff" .. gold .. h .. "/" .. n .. "|r"
                end
                f._band = { y = y, have = have, need = need }
                y = y - SEG_H - 5
                bodyLines = bodyLines + 1
                if #reqs > 1 then
                    local ml = MobLine(f)
                    PT(ml, PAD, y)
                    ml:SetText(table.concat(parts, "    "))
                    ml:SetWidth(wrapW - 2 * PAD)
                    ml:Show()
                    Wide(ml:GetStringWidth() or 0)
                    y = y - 14
                end
            elseif reqs and #reqs > 0 and not equipTrans then
                for i = 1, math.min(#reqs, MOB_ROWS) do
                    local r, m = reqs[i], f.mobs[i]
                    local have, need = self:MobHave(step, r.mob), (r.kills or 1)
                    m.name:SetText(r.mob or "?")
                    m.cnt:SetText(have .. "/" .. need)
                    m.name:ClearAllPoints() m.cnt:ClearAllPoints()
                    if alignR then
                        m.cnt:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
                        m.name:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
                        m.name:SetJustifyH("RIGHT")
                    else
                        m.name:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y)
                        m.cnt:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
                        m.name:SetJustifyH("LEFT")
                    end
                    m.name:SetWidth(math.max(40, wrapW - 2 * PAD - 12 - (m.cnt:GetStringWidth() or 0)))
                    m.name:Show() m.cnt:Show()
                    Wide((m.name:GetStringWidth() or 0) + 12 + (m.cnt:GetStringWidth() or 0))
                    m.track:ClearAllPoints()
                    m.track:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, y - 14)
                    m.track:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y - 14)
                    m.track:Show()
                    local frac = need > 0 and math.min(1, have / need) or 0
                    m.fill:ClearAllPoints()
                    if frac > 0 then
                        if alignR then m.fill:SetPoint("TOPRIGHT", m.track, "TOPRIGHT", 0, 0)
                        else m.fill:SetPoint("TOPLEFT", m.track, "TOPLEFT", 0, 0) end
                        m.fill.frac = frac
                        m.fill:Show()
                    else
                        m.fill:Hide()
                    end
                    y = y - 21
                    bodyLines = bodyLines + 1
                end
            end
        end
        -- a plain line: equipping / waiting / an encounter verb
        local detail
        if equipTrans then detail = RCL["Equipping: "] .. equipTrans
        elseif self._awaitUse then detail = RCL["Use item to continue"]
        elseif step and step.type == "encounter" and not basic then
            -- the title names the boss; the body says what we wait for
            local w = step.when or "end"
            detail = (w == "start" and RCL["Target"]) or (w == "wipe" and RCL["On wipe"]) or RCL["Kill"]
            if not (step.desc and step.desc ~= "") then
                -- the title is "Target Anub'Rekhan" already
                detail = nil
            end
        end
        if detail then
            PT(f.detail, PAD, y)
            f.detail:SetText(detail)
            f.detail:Show()
            Wide(f.detail:GetStringWidth() or 0)
            y = y - 16
            bodyLines = bodyLines + 1
        end
        -- live reminders
        for i = 1, REM_ROWS do
            local rec = (not equipTrans) and self.activeReminders[i] or nil
            if rec then
                local r = f.rems[i]
                PT(r.icon, PAD, y)
                ShowIcon(r.icon, rec.icon or "Interface\\Icons\\INV_Misc_Note_01", true)
                r.fs:ClearAllPoints()
                if alignR then r.fs:SetPoint("RIGHT", r.icon, "LEFT", -6, 0)
                else r.fs:SetPoint("LEFT", r.icon, "RIGHT", 6, 0) end
                r.fs:SetText(rec.text)
                r.fs:SetWidth(wrapW - 2 * PAD - 22)
                r.fs:Show()
                Wide(22 + (r.fs:GetStringWidth() or 0))
                y = y - 19
                bodyLines = bodyLines + 1
            end
        end
        -- bar style: the line for gear swaps (its room always kept)
        if band and (step or (self.finished and self._finAt)) and settings.trackerBandSwaps ~= false then
            RenderSwapRow(self, f, y - 2, wrapW - 2 * PAD, alignR)
            y = y - SWAP_H - 4
            bodyLines = bodyLines + 1
        end
        if bodyLines == 0 then y = y + 2 end

        -- ---- footer: the step's gear and reminders as icons
        local n = 0
        if step and not equipTrans then
            local seen = {}
            local function Add(tex)
                if not tex or n >= TRACKER_MAX_ICONS or seen[tex] then return end
                seen[tex] = true
                n = n + 1
                ShowIcon(f.icons[n], tex, true)
            end
            local a = step.actions
            if a then
                if a.gearSet and a.gearSet ~= "" then Add(TrackerSetIcon(a.gearSet)) end
                if a.trinket1 and a.trinket1 ~= 0 then Add(TrackerItemIcon(a.trinket1)) end
                if a.trinket2 and a.trinket2 ~= 0 then Add(TrackerItemIcon(a.trinket2)) end
                if a.slots then
                    for invSlot, itemId in pairs(a.slots) do
                        if itemId == -1 then Add(SlotEmptyIcon(invSlot))
                        elseif itemId and itemId ~= 0 then Add(TrackerItemIcon(itemId)) end
                    end
                end
                local live = {}
                for _, rec in ipairs(self.activeReminders) do if rec.text then live[rec.text] = true end end
                if a.reminders then
                    for _, r in ipairs(a.reminders) do
                        if r.text and r.text ~= "" and not live[r.text] then
                            Add(r.icon or "Interface\\Icons\\INV_Misc_Note_01")
                        end
                    end
                elseif a.reminderText and a.reminderText ~= "" and not live[a.reminderText] then
                    Add(a.reminderIcon or "Interface\\Icons\\INV_Misc_Note_01")
                end
            end
            if step.type == "encounter" then
                local cfgSet, cfgSlots = StepConfigGear(self, step)
                if cfgSet then Add(TrackerSetIcon(cfgSet)) end
                for _, o in ipairs(cfgSlots or {}) do Add(TrackerItemIcon(o.id)) end
            end
        end
        local bandIconsW = 0
        if band then
            local x = PAD + HANDLE_W
            for i = n, 1, -1 do
                local ic = f.icons[i]
                ic:SetSize(BAND_ICON, BAND_ICON)
                ic:ClearAllPoints()
                ic:SetPoint("RIGHT", f.head, "RIGHT", -x, 1)
                x = x + BAND_ICON + ICON_GAP
            end
            if n > 0 then
                f.when:SetText(WhenLabel(step))
                f.when:ClearAllPoints()
                f.when:SetPoint("RIGHT", f.icons[1], "LEFT", -6, 0)
                f.when:Show()
                bandIconsW = x - PAD - HANDLE_W + 6 + (f.when:GetStringWidth() or 0)
                Wide(titleW + 16 + bandIconsW)
            end
            y = y - 2
        elseif n > 0 then
            for i = 1, n do f.icons[i]:SetSize(ICON, ICON) end
            y = y - 2
            f.rule:ClearAllPoints()
            f.rule:SetPoint("TOPLEFT", f, "TOPLEFT", 1, y)
            f.rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, y)
            f.rule:Show()
            y = y - 7
            for i = 1, n do
                f.icons[i]:ClearAllPoints()
                if alignR then f.icons[i]:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(PAD + (i - 1) * (ICON + ICON_GAP)), y)
                else f.icons[i]:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + (i - 1) * (ICON + ICON_GAP), y) end
            end
            f.when:SetText(WhenLabel(step))
            f.when:ClearAllPoints()
            if alignR then f.when:SetPoint("RIGHT", f.icons[n], "LEFT", -8, 0)
            else f.when:SetPoint("LEFT", f.icons[n], "RIGHT", 8, 0) end
            f.when:Show()
            Wide(n * (ICON + ICON_GAP) - ICON_GAP + 8 + (f.when:GetStringWidth() or 0))
            y = y - ICON - 7
        else
            y = y - 4
        end

        -- ---- look-ahead / look-behind
        if showCtx and steps and step then
            local rows = 0
            local function CtxRow(prefix, idx, s)
                rows = rows + 1
                local c = f.ctx[rows]
                if not c then return end
                c.fs:SetText(prefix .. idx .. ". " .. CtxLabel(self, s))
                c.fs:SetAlpha(prefix == RCL["Prev: "] and 0.35 or (rows == 1 and 0.6 or 0.45))
                PT(c.fs, PAD, y)
                c.fs:SetWidth(wrapW - 2 * PAD - 60)
                c.fs:Show()
                local icN = FillStepIcons(s, c.icons)
                local tw = math.min(c.fs:GetStringWidth() or 0, wrapW - 2 * PAD - 60)
                if icN > 0 then
                    c.icons[1]:ClearAllPoints()
                    if alignR then c.icons[1]:SetPoint("RIGHT", c.fs, "RIGHT", -(tw + 4) - (icN - 1) * (CTX_ICON + 2), 0)
                    else c.icons[1]:SetPoint("LEFT", c.fs, "LEFT", tw + 4, 0) end
                    for k = 2, icN do
                        c.icons[k]:ClearAllPoints()
                        c.icons[k]:SetPoint("LEFT", c.icons[k - 1], "RIGHT", 2, 0)
                    end
                end
                Wide(tw + (icN > 0 and (4 + icN * (CTX_ICON + 2)) or 0))
                y = y - 15
            end
            local shown = 0
            for k = self.active + 1, #steps do
                local s = steps[k]
                if s and s.enabled ~= false and not (s.type == "encounter" and s.when == "wipe") then
                    CtxRow(shown == 0 and RCL["Next: "] or "", k, s)
                    shown = shown + 1
                    if shown >= ctxCount then break end
                end
            end
            for k = self.active - 1, 1, -1 do
                local ps = steps[k]
                if ps and ps.enabled ~= false and not (ps.type == "encounter" and ps.when == "wipe") then
                    CtxRow(RCL["Prev: "], k, ps)
                    break
                end
            end
            if rows > 0 then y = y - 3 end
        end

        -- debug overlay (not a saved setting)
        if RR._dbgOverlay then
            local tr = self._transition
            local trs = "-"
            if tr then
                trs = (tr.equip and ("equip:" .. tr.equip) or "done")
                    .. string.format(" %.1fs", math.max(0, (tr.expires or 0) - GetTime()))
            end
            local cparts = {}
            for k, v in pairs(self.counts or {}) do cparts[#cparts + 1] = tostring(k) .. "=" .. tostring(v) end
            local nItem = 0
            for _, rec in ipairs(self.activeReminders) do if rec.spellId then nItem = nItem + 1 end end
            PT(f.dbg, PAD, y)
            f.dbg:SetWidth(wrapW - 2 * PAD)
            f.dbg:SetText("ENGINE " .. (RR.BUILD or "?") .. " | active=" .. tostring(self.active)
                .. " armed=" .. tostring(self.armed and 1 or 0) .. " awaitUse=" .. tostring(self._awaitUse and 1 or 0)
                .. " fin=" .. tostring(self.finished and 1 or 0) .. "\ntrans=" .. trs
                .. " | rems=" .. #self.activeReminders .. "(" .. nItem .. " item)"
                .. " | counts: " .. (next(self.counts or {}) and table.concat(cparts, " ") or "-"))
            f.dbg:Show()
            y = y - ((f.dbg:GetStringHeight() or 18) + 4)
        end

        -- ---- size, then the bars (they need the final width)
        local w = fixedW or math.min(MAX_W, math.max(MIN_W, natW))
        f:SetSize(w, -y + PAD - 2)
        f.title:SetWidth(math.max(40, w - 2 * PAD - HANDLE_W - (f.tag:IsShown() and (f.tag:GetWidth() + 10) or 0) - bandIconsW))
        if f._band then
            local bd = f._band
            local inner = w - 2 * PAD
            local gold = RC:GetColor("ui", "accentGold")
            local el = RC:GetColor("ui", "elementBackground")
            local function Paint1(s, lit)
                if lit then s:SetVertexColor(gold.r, gold.g, gold.b, 1)
                else s:SetVertexColor(el.r + 0.06, el.g + 0.06, el.b + 0.06, 1) end
            end
            if bd.need > 0 and bd.need <= SEG_MAX then
                local sw = (inner - (bd.need - 1) * SEG_GAP) / bd.need
                for i = 1, bd.need do
                    local s = Seg(f, i)
                    s:ClearAllPoints()
                    local k = alignR and (bd.need - i) or (i - 1)
                    s:SetPoint("TOPLEFT", f, "TOPLEFT", PAD + k * (sw + SEG_GAP), bd.y)
                    s:SetWidth(math.max(1, sw))
                    Paint1(s, i <= bd.have)
                    s:Show()
                end
            else
                local track, fill = Seg(f, 1), Seg(f, 2)
                track:ClearAllPoints()
                track:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, bd.y)
                track:SetWidth(inner)
                Paint1(track, false)
                track:Show()
                local frac = bd.need > 0 and math.min(1, bd.have / bd.need) or 0
                if frac > 0 then
                    fill:ClearAllPoints()
                    if alignR then fill:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, bd.y)
                    else fill:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, bd.y) end
                    fill:SetWidth(math.max(1, inner * frac))
                    fill:SetDrawLayer("ARTWORK", 1)
                    Paint1(fill, true)
                    fill:Show()
                end
            end
        end
        f.detail:SetWidth(w - 2 * PAD)
        self:ApplyTrackerAnchors(f, settings)
        -- layer / clamp, fade rules, shadow / glow (the standard; its own
        -- scale setting stays its own)
        if RC.ApplyFrameCustom then
            RC:ApplyFrameCustom(f, function() return RC.db and RC.db.raidRoute end,
                { scale = false, sample = (f ~= (RC.RaidRoute and RC.RaidRoute.trackerFrame)) })
        end
        if f.handle then f.handle.Refresh() end
        for _, m in ipairs(f.mobs) do
            if m.fill:IsShown() then m.fill:SetWidth(math.max(1, (w - 2 * PAD) * (m.fill.frac or 0))) end
        end
        f:Show()
    end

    ------------------------------------------------------------------
    -- The customization standard on the panel (raidRoute.anchors.<text>):
    -- the title, the count, the body line and the when-label placeable.
    -- Each one's default is where the flow above just put it (left or
    -- right aligned, the rows it follows), so a spec goes on top of that.
    ------------------------------------------------------------------
    RR.TEXT_ELEMENTS = {
        { key = "title", label = RCL["Title"], get = function(f) return f.title end },
        { key = "count", label = RCL["Count"], get = function(f) return f.tag end },
        { key = "detail", label = RCL["Body line"], get = function(f) return f.detail end },
        { key = "when", label = RCL["When-label"], get = function(f) return f.when end },
    }
    RR.TEXT_TARGETS = { { value = "panel", text = RCL["The panel"] }, { value = "head", text = RCL["Title bar"] },
        { value = "title", text = RCL["Title"] }, { value = "count", text = RCL["Count"] } }
    local function CaptureDef(f, key, region)
        f._rrDef = f._rrDef or {}
        local d = f._rrDef[key] or {}
        f._rrDef[key] = d
        d.point, d.to, d.relPoint, d.x, d.y = region:GetPoint(1)
        d.point2, d.to2, d.relPoint2, d.x2, d.y2 = nil, nil, nil, nil, nil
        if (region:GetNumPoints() or 0) >= 2 then d.point2, d.to2, d.relPoint2, d.x2, d.y2 = region:GetPoint(2) end
        d.justify = region.GetJustifyH and region:GetJustifyH() or nil
        return d
    end
    function RR:ApplyTrackerAnchors(f, settings)
        local a = settings and type(settings.anchors) == "table" and settings.anchors or nil
        if not f._rrTo then
            f._rrTo = function(k)
                if k == "panel" then return f elseif k == "head" then return f.head
                elseif k == "title" then return f.title elseif k == "count" then return f.tag end
            end
        end
        for _, e in ipairs(self.TEXT_ELEMENTS) do
            local region = e.get(f)
            if region and (region:GetNumPoints() or 0) > 0 then
                local d = CaptureDef(f, e.key, region)
                local spec = a and a[e.key]
                if spec then RC.UI:ApplyAnchor(region, spec, d, f._rrTo) end
            end
        end
        -- the pooled rows: one spec for every mob row's name / count and
        -- every reminder row's text, each row's default where the flow
        -- put it (RR.ROW_ELEMENTS)
        if not a then return end
        for _, e in ipairs(self.ROW_ELEMENTS) do
            local spec = a[e.key]
            if spec then
                for i, row in ipairs(f[e.list] or {}) do
                    local region = row[e.field]
                    if region and region:IsShown() and (region:GetNumPoints() or 0) > 0 then
                        if not row._rrTo then
                            row._rrTo = function(k)
                                if k == "panel" then return f elseif k == "name" then return row.name
                                elseif k == "count" then return row.cnt elseif k == "track" then return row.track
                                elseif k == "icon" then return row.icon elseif k == "text" then return row.fs end
                            end
                        end
                        local d = CaptureDef(f, e.key .. i, region)
                        RC.UI:ApplyAnchor(region, spec, d, row._rrTo)
                    end
                end
            end
        end
    end
    RR.ROW_ELEMENTS = {
        { key = "mobName", list = "mobs", field = "name", label = RCL["Mob row: name"],
          targets = { { value = "count", text = RCL["Its count"] }, { value = "track", text = RCL["Its bar"] } } },
        { key = "mobCount", list = "mobs", field = "cnt", label = RCL["Mob row: count"],
          targets = { { value = "name", text = RCL["Its name"] }, { value = "track", text = RCL["Its bar"] } } },
        { key = "remText", list = "rems", field = "fs", label = RCL["Reminder row: text"],
          targets = { { value = "icon", text = RCL["Its icon"] } } },
    }
    function RR:TrackerAnchorDefault(key, sample)
        local f = self.trackerFrame or sample
        local d = f and f._rrDef and (f._rrDef[key] or f._rrDef[key .. "1"])
        return d or { point = "TOPLEFT", relPoint = "TOPLEFT", x = 0, y = 0 }
    end

    -- cheap partial refresh for per-kill count updates: the tag and the
    -- mob rows in place, no relayout.
    -- The tallest and widest the panel gets for the routes this character
    -- has: every step of every raid's active profile rendered once, out of
    -- sight, with the live settings (scale, context lines, width). For a
    -- layout that parks the panel above something else. Returns height,
    -- width in UIParent units, or nil when no route has a step.
    function RR:MeasureTracker()
        local settings = self:GetSettings()
        if not (settings and RC.db and type(RC.db.raidProfiles) == "table") then return nil end
        local f = self:EnsureTrackerFrame()
        if not f then return nil end
        local names = {}
        for name, structure in pairs(RC.db.raidProfiles) do
            local p = type(structure) == "table" and RC.GetActiveRaidProfile and RC:GetActiveRaidProfile(name)
            if type(p) == "table" and type(p.route) == "table" and type(p.route.steps) == "table"
               and #p.route.steps > 0 then
                names[#names + 1] = name
            end
        end
        if #names == 0 then return nil end
        local sRaid, sActive, sFin = self.raidName, self.active, self.finished
        local sEn, sTE = settings.enabled, settings.trackerEnabled
        local wasShown, alpha = f:IsShown(), f:GetAlpha()
        settings.enabled, settings.trackerEnabled = true, true
        f:SetAlpha(0)
        local maxH, maxW = 0, 0
        local k = (f:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
        for _, name in ipairs(names) do
            self.raidName = name
            local steps = self:GetSteps()
            for i = 1, (steps and #steps or 0) do
                self.active, self.finished = i, false
                self:RefreshTracker()
                if f:IsShown() then
                    k = (f:GetEffectiveScale() or 1) / (UIParent:GetEffectiveScale() or 1)
                    local h, w = (f:GetHeight() or 0) * k, (f:GetWidth() or 0) * k
                    if h > maxH then maxH = h end
                    if w > maxW then maxW = w end
                end
            end
        end
        self.raidName, self.active, self.finished = sRaid, sActive, sFin
        settings.enabled, settings.trackerEnabled = sEn, sTE
        f:SetAlpha(alpha)
        self:RefreshTracker()
        if not wasShown and f:IsShown() then f:Hide() end
        if maxH <= 0 then return nil end
        return maxH, maxW
    end

    function RR:UpdateTrackerCount()
        local f = self.trackerFrame
        if not f or not f:IsShown() then return end
        local steps = self:GetSteps()
        local step = steps and steps[self.active]
        if not step or step.type ~= "kills" then return end
        if self:GetSettings().trackerBasic == true then return end
        -- the bar style lays its segments out from the counts: redo it
        if self:GetSettings().trackerBand == true then return self:RefreshTracker() end
        local _, progText = TrackerGateText(self, step)
        if progText and f.tag:IsShown() then f.tag.text:SetText(progText) end
        local reqs = self:GetStepMobs(step)
        if not reqs then return end
        local w = f:GetWidth() or MIN_W
        for i = 1, math.min(#reqs, MOB_ROWS) do
            local r, m = reqs[i], f.mobs[i]
            if m.name:IsShown() then
                local have, need = self:MobHave(step, r.mob), (r.kills or 1)
                m.cnt:SetText(have .. "/" .. need)
                local frac = need > 0 and math.min(1, have / need) or 0
                if frac > 0 then
                    m.fill.frac = frac
                    m.fill:ClearAllPoints()
                    if self:GetSettings().trackerAlignRight then m.fill:SetPoint("TOPRIGHT", m.track, "TOPRIGHT", 0, 0)
                    else m.fill:SetPoint("TOPLEFT", m.track, "TOPLEFT", 0, 0) end
                    m.fill:SetWidth(math.max(1, (w - 2 * PAD) * frac))
                    m.fill:Show()
                else
                    m.fill:Hide()
                end
            end
        end
    end
