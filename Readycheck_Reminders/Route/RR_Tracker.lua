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
    local HOLD_ROWS = 3           -- standing reminders (RR.HOLD_MAX): the rows after those
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

    ------------------------------------------------------------------
    -- DOCKED IN THE CHAT BOX (raidRoute.trackerChatDock, off unless
    -- ticked; 2026-11-12, Zac: "improvements to my routes in my chat also
    -- give users the option to enable this"). With ZacUI's raid chat on
    -- (the raid frames sitting in the chat box: _G.ZacUIRaidChat) the
    -- tracker becomes the bar along the top of that box: bar style, no
    -- box of its own, left aligned, at 100%, as wide as the box, pinned
    -- to its top-left corner - and ZacUI is told how much room the
    -- tallest step needs, so the raid frames start under it. Until now
    -- only Zac's own layout addon set this up, by rewriting the tracker's
    -- saved settings; here NOTHING saved is changed. The tracker draws
    -- from a view of the settings with those few laid over them, so
    -- unticking the option (or switching raid chat off) puts it back
    -- exactly where and how it was.
    --   RR:ChatDockArea(st)   left, right, top of the box (UIParent
    --                         units) while docking applies, else nil
    --   RR:TrackerSettings()  what the tracker draws with: the saved
    --                         settings, or the docked view of them; then
    --                         the area when docked
    --   RR:SyncChatDock(...)  keeps ZacUI's reserved room right
    ------------------------------------------------------------------
    function RR:ChatDockArea(st)
        st = st or self:GetSettings()
        if not (st and st.trackerChatDock == true) then return nil end
        local RCh = _G.ZacUIRaidChat
        if not (RCh and RCh.Enabled and RCh.Area) then return nil end
        local okE, on = pcall(RCh.Enabled)
        if not (okE and on) then return nil end
        local ok, l, r, t = pcall(RCh.Area, false)
        if not (ok and type(l) == "number" and type(r) == "number" and type(t) == "number") then return nil end
        if r - l < 180 then return nil end          -- (narrower than the bar can be)
        return l, r, t
    end
    RR.DOCK_OVER = { trackerBand = true, trackerNoBg = true, trackerAlignRight = false, trackerScale = 1,
                     trackerUnlocked = false }
    function RR:TrackerSettings()
        local st = self:GetSettings()
        if not st then return nil end
        local l, r, t = self:ChatDockArea(st)
        if not l then return st end
        local v = rawget(self, "_dockView")
        if not v then
            v = { over = {} }
            for k, val in pairs(RR.DOCK_OVER) do v.over[k] = val end
            v.proxy = setmetatable({}, {
                __index = function(_, k)
                    local o = v.over[k]
                    if o ~= nil then return o end
                    return v.base[k]
                end,
                __newindex = function(_, k, val) v.base[k] = val end,
            })
            rawset(self, "_dockView", v)
        end
        v.base = st
        v.over.trackerW = math.floor(r - l + 0.5)
        return v.proxy, l, r, t
    end
    -- The room ZacUI keeps clear above the raid frames: the tallest step
    -- of the routes this character has, measured only when something that
    -- changes it has (the raid, the number of steps, what the bar shows,
    -- its width) - and given back when the dock ends, if it was ours.
    function RR:SyncChatDock(docked, width)
        local RCh = _G.ZacUIRaidChat
        if not (RCh and RCh.SetReserveTop) then return end
        if not docked then
            if self._dockReserve then
                self._dockReserve, self._dockSig = nil, nil
                pcall(RCh.SetReserveTop, 0)
            end
            return
        end
        local st = self:GetSettings()
        local steps = self:GetSteps()
        local sig = table.concat({ tostring(self.raidName), steps and #steps or 0, tostring(st and st.trackerShowContext),
            tostring(st and st.trackerNextCount), tostring(st and st.trackerBasic), tostring(st and st.trackerBandSwaps),
            tostring(st and st.trackerBandGear), math.floor(width or 0) }, ":")
        if sig == self._dockSig then return end
        self._dockSig = sig
        C_Timer.After(0, function()
            if RR._measuring or not RR.MeasureTracker then return end
            if not RR:ChatDockArea() then return end
            local tall = RR:MeasureTracker()
            RR._dockReserve = true
            pcall(RCh.SetReserveTop, (tall and tall > 0) and (tall + 3) or 0)
        end)
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
        for i = 1, REM_ROWS + HOLD_ROWS do
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
                -- (docked in the chat box it is not a thing to drag or widen)
                getLocked = function()
                    local st = RR:GetSettings()
                    return f._rcDocked or not (st and st.trackerUnlocked == true)
                end,
                setLocked = function(locked)
                    local st = RR:GetSettings()
                    if not st or f._rcDocked then return end
                    st.trackerUnlocked = not locked
                    if RR.ApplyTrackerLock then RR:ApplyTrackerLock() end
                    RC:SaveConfigurationToProfile()
                    RR:RefreshTracker()
                end,
                getWidth = function() return f:GetWidth() end,
                setWidth = function(w)
                    local st = RR:GetSettings()
                    if st and not f._rcDocked then st.trackerW = w end
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
            return st and st.trackerUnlocked == true and not f._rcDocked
        end)
        function RR:ApplyTrackerLock()
            local st = self:GetSettings()
            f:EnableMouse(st ~= nil and st.trackerUnlocked == true and not f._rcDocked)
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
        if f.gear then f.gear:Hide() end
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
    -- GEAR SWAPS ON THE BAR (bar style, trackerBandSwaps, on unless
    -- switched off): when Readycheck has put gear on, the title row says
    -- so in one place - a tick and "Frost Resist equipped", straight after
    -- the step's name and count (the icons of what this step will put on
    -- next keep the row's far end) - bright as it lands, settling after a
    -- few seconds, kept while the step lasts.
    -- (2026-11-12, Zac: "i like the kill tracking progress but it showing
    -- swaps just doesnt make any sense that needs to be cleaned up a
    -- lot".) Until then this was a line of its own under the bar: the
    -- set's name and every piece as a pair of 12px icons, old (grey) then
    -- new (ringed), for four seconds, then "Frost Resist equipped - 6
    -- pieces" - and the line's room was kept the whole time, so under the
    -- bar sat an empty strip for most of a raid. Three readings of one
    -- event (with "Equipping: ..." before it) and a blank row to hold
    -- them. Now: one confirmation, no row, and the bar is a row shorter
    -- (whatever it is docked over gets that room).
    -- Swaps come from the swap notice's collector (RC:OnSwapFeed); waves
    -- of one step (the set, then the trinkets) merge into one.
    ------------------------------------------------------------------
    local SWAP_H, SWAP_ICON, SWAP_ACTIVE, SWAP_MERGE = 14, 12, 4, 3
    local CHECK_TEX = "Interface\\AddOns\\Readycheck\\Media\\Checkmark"
    -- THE GEAR ROW (trackerBandGear, on unless switched off; 2026-11-12,
    -- Zac: "maybe do something like an actual mock character pane that
    -- will show the swaps on the pane" - "it needs to fit in my chat. so
    -- find a way to do that"). For the few seconds a swap is fresh the
    -- line of mob names gives way to what you are wearing, laid out as the
    -- character window has it turned on its side - its left column, its
    -- right column, the weapons - with the slots that just changed lit
    -- and ringed in gold and the rest dimmed. The kill bar and the count
    -- stay; the row takes the room the names had (the tallest step is
    -- measured with it, so a docked bar never grows over what is under it).
    -- inventory slots in the character window's order
    local DOLL = { 1, 2, 3, 15, 5, 4, 19, 9,   10, 6, 7, 8, 11, 12, 13, 14,   16, 17, 18 }
    local DOLL_BREAK = { [9] = true, [17] = true }      -- a wider gap before these
    local DOLL_MAX, DOLL_MIN = 17, 10                   -- icon size: what fits, between these
    local DOLL_GAP_MIN, DOLL_GAP_MAX, DOLL_GROUP = 2, 4, 6
    local GEAR_LINE, GEAR_OUT = 14, 0.25                -- the names' room; the fade as it leaves

    function RC:SwapFeedWanted()
        local s = RR.TrackerSettings and RR:TrackerSettings()
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
        -- what is worn now, slot by slot, for the gear row (read here,
        -- once per swap - never from a refresh)
        cur.freshGear = true
        cur.gear = cur.gear or {}
        if GetInventoryItemTexture then
            for _, slot in ipairs(DOLL) do
                cur.gear[slot] = GetInventoryItemTexture("player", slot) or false
            end
        end
        local at = cur.at
        -- the gear row bows out just before the names come back
        C_Timer.After(SWAP_ACTIVE - GEAR_OUT, function()
            local f = RR.trackerFrame
            if RR._swapFeed and RR._swapFeed.at == at and f and f.gear and f.gear:IsShown() then
                RC.Motion.Play(f.gear, { style = "fade", duration = GEAR_OUT, easing = "easeInOutQuad" }, "out")
            end
        end)
        C_Timer.After(SWAP_ACTIVE + 0.05, function()
            if RR._swapFeed and RR._swapFeed.at == at then RR:RefreshTracker() end
        end)
        RR:RefreshTracker()
    end

    local function SwapRow(f)
        if f.swap then return f.swap end
        local r = CreateFrame("Frame", nil, f)
        r:SetHeight(SWAP_H)
        r.tick = r:CreateTexture(nil, "OVERLAY")
        r.tick:SetSize(SWAP_ICON, SWAP_ICON)
        r.tick:SetTexture(CHECK_TEX)
        r.tick:SetPoint("LEFT", r, "LEFT", 0, 0)
        r.label = Shadow(RC:CreateFontString(r, "OVERLAY", nil, 10))
        r.label:SetWordWrap(false)
        r.label:SetJustifyH("LEFT")
        r.label:SetPoint("LEFT", r.tick, "RIGHT", 4, 0)
        r:Hide()
        f.swap = r
        return r
    end

    -- Fills the confirmation for the swap that belongs on the bar now and
    -- returns how wide it wants to be (0: nothing to say). Placed by
    -- PlaceSwapChip once the bar's width is known.
    local function FillSwapChip(self, f)
        local r = SwapRow(f)
        -- a re-layout mid-slide would fight the slide's rest
        RC.Motion.Stop(r)
        r:Hide()
        local feed = self._swapFeed
        -- a finished route's last swap (the after-kill gear) belongs to no
        -- step any more: it is the one that landed as the route ran out
        local lastOne = feed and self.finished and self._finAt and feed.at >= self._finAt - 1
        if not feed or (feed.step ~= self.active and not lastOne) then return 0 end
        local ht = RC:GetColor("ui", "headerText")
        local gold = RC:GetColor("ui", "accentGold")
        local active = (GetTime() - feed.at) < SWAP_ACTIVE
        local headline = (RC.SwapToast and RC.SwapToast.Headline and RC.SwapToast.Headline(feed.label))
            or SwapLabel(feed.label)
        r.tick:SetVertexColor(gold.r, gold.g, gold.b, 1)
        r.label:SetWidth(0)
        r.label:SetText(headline)
        if active then r.label:SetTextColor(gold.r, gold.g, gold.b)
        else r.label:SetTextColor(ht.r, ht.g, ht.b) end
        r._textW = r.label:GetStringWidth() or 0
        r._active = active
        return SWAP_ICON + 4 + r._textW
    end

    -- room: what the title row has left for it. The whole thing when it
    -- fits, the name cut short when it does not, the tick alone when
    -- there is hardly any, nothing when there is none.
    local function PlaceSwapChip(self, f, room, after)
        local r = f.swap
        if not r then return end
        if room < SWAP_ICON then r:Hide() return end
        local textW = math.min(r._textW or 0, room - SWAP_ICON - 4)
        if textW < 28 then
            r.label:Hide()
            textW = 0
        else
            r.label:SetWidth(textW)
            r.label:Show()
        end
        r:SetWidth(SWAP_ICON + (textW > 0 and (4 + textW) or 0))
        r:ClearAllPoints()
        r:SetPoint("LEFT", after[1], after[2], after[3], after[4] or 0)
        r:SetAlpha(r._active and 1 or 0.75)
        r:Show()
        local feed = self._swapFeed
        if feed and feed.fresh then
            feed.fresh = nil
            RC.Motion.Play(r, RR:SwapLineMotion(), "in")
        end
    end

    local function GearRow(f)
        if f.gear then return f.gear end
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(10, DOLL_MAX)
        r.icons = {}
        for i = 1, #DOLL do r.icons[i] = Icon(r, DOLL_MAX) end
        r:Hide()
        f.gear = r
        return r
    end

    -- Is the gear row up for this pass? While the landed swap is fresh -
    -- and on every step of a measuring pass, so the room a docked bar is
    -- given already has the row in it.
    local function GearRowUp(self, settings, f)
        if not (settings.trackerBand == true and settings.trackerBandSwaps ~= false
                and settings.trackerBandGear ~= false) then return false end
        if self._measuring then return true end
        local feed = self._swapFeed
        local lastOne = feed and self.finished and self._finAt and feed.at >= self._finAt - 1
        if not feed or (feed.step ~= self.active and not lastOne) then return false end
        return (GetTime() - feed.at) < SWAP_ACTIVE
    end

    -- Second pass, once the bar's width is known: the icons as big as 19
    -- of them fit (DOLL_MIN..DOLL_MAX; narrower than that and the row is
    -- left out - the tick on the title row still says it), from the text
    -- edge.
    local function LayGearRow(self, f, w, alignR)
        local g = f._gear
        local r = GearRow(f)
        RC.Motion.Stop(r)
        r:SetAlpha(1)
        r:Hide()
        if not g or self._measuring then return end
        local inner = w - 2 * PAD
        local n = #DOLL
        local size = math.floor((inner - 2 * DOLL_GROUP - (n - 3) * DOLL_GAP_MIN) / n)
        if size > DOLL_MAX then size = DOLL_MAX end
        if size < DOLL_MIN then return end
        local gap = (inner - 2 * DOLL_GROUP - n * size) / (n - 3)
        if gap > DOLL_GAP_MAX then gap = DOLL_GAP_MAX end
        local total = n * size + (n - 3) * gap + 2 * DOLL_GROUP
        local feed = self._swapFeed or {}
        local changed = {}
        for _, it in ipairs(feed.items or {}) do
            if it.slot then changed[it.slot] = it.icon or true end
        end
        local gold = RC:GetColor("ui", "accentGold")
        local bc = RC:GetColor("ui", "borderNormal")
        local el = RC:GetColor("ui", "elementBackground")
        local x = 0
        for i, slot in ipairs(DOLL) do
            if i > 1 then x = x + (DOLL_BREAK[i] and DOLL_GROUP or gap) end
            local ic = r.icons[i]
            local lit = changed[slot]
            local tex = (type(lit) == "string" and lit) or (feed.gear and feed.gear[slot]) or nil
            ic:SetSize(size, size)
            ic:ClearAllPoints()
            ic:SetPoint("TOPLEFT", r, "TOPLEFT", x, 0)
            if tex then
                ShowIcon(ic, tex, true)
                ic:SetVertexColor(1, 1, 1, 1)
                ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            else
                -- nothing in the slot: its place, empty
                ShowIcon(ic, RC.UI.FLAT, true)
                ic:SetVertexColor(el.r + 0.04, el.g + 0.04, el.b + 0.04, 1)
            end
            if ic.SetDesaturated then ic:SetDesaturated((tex and not lit) and true or false) end
            ic:SetAlpha(lit and 1 or (tex and 0.45 or 0.7))
            if lit then ic.bd:SetColorTexture(gold.r, gold.g, gold.b, 1)
            else ic.bd:SetColorTexture(bc.r, bc.g, bc.b, 1) end
            ic.bd:SetAlpha(lit and 1 or 0.6)
            ic._lit = lit and true or false
            x = x + size
        end
        r:SetSize(total, size)
        r:ClearAllPoints()
        if alignR then r:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, g.y)
        else r:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, g.y) end
        r:Show()
        if feed.freshGear then
            feed.freshGear = nil
            RC.Motion.Play(r, { style = "fade", duration = 0.2, easing = "easeOutCubic" }, "in")
        end
    end

    -- The confirmation's entrance when a swap lands: raidRoute.trackerSwapAnim,
    -- else what the swap line always did - a 14px slide in from the text
    -- side's far end with a fade, 0.25s.
    function RR:SwapLineDefaults()
        local s = self:TrackerSettings()
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
        -- (the saved settings, or the docked view of them with the chat
        -- box's left, right and top)
        local settings, dockL, dockR, dockT = self:TrackerSettings()
        if not settings then return end
        -- the standing reminders that are up (a measuring pass only looks)
        local holds = self._measuring and self:ActiveHolds() or self:SyncHolds()
        local alignR = settings.trackerAlignRight == true
        -- (2026-11-12) ticked and the count never touched is ONE step, as
        -- the page's slider shows: the old line read a count that was
        -- never saved as 0 ("x and nil or 0"), so "show the next step
        -- below" drew nothing until the slider was moved - on the tracker
        -- and on the settings preview (Zac: "the preview on this page
        -- looks weird": the box kept its room and the line was not there).
        local ctxCount = 0
        if settings.trackerShowContext == true then
            ctxCount = tonumber(settings.trackerNextCount) or 1
        end
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
            -- into or out of the chat dock the saved spot is NOT rescaled:
            -- it stays in the units of the saved scale, which is what it
            -- is put back with (a rescale here would be saved against a
            -- scale setting that never changed, and compound every login)
            if dockL or f._rcDocked then f:SetScale(sc)
            elseif RC.Position.SetScaleKeepingPoint then RC.Position.SetScaleKeepingPoint(f, sc, true)
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
        f._gear = nil
        local gearUp = GearRowUp(self, settings, f)

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
                if gearUp then
                    -- what you are wearing, where the names were (2px
                    -- closer to the kill bar: the icons are taller)
                    f._gear = { y = y + 2 }
                    y = y - GEAR_LINE
                elseif #reqs > 1 then
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
        -- no kill bar on this step (a boss, the route's end, gear going
        -- on): the gear row is the body, in the plain line's place - only
        -- "Use item to continue" keeps its line over it
        if gearUp and not f._gear then
            if not self._awaitUse then detail = nil end
        end
        if detail then
            PT(f.detail, PAD, y)
            f.detail:SetText(detail)
            f.detail:Show()
            Wide(f.detail:GetStringWidth() or 0)
            y = y - 16
            bodyLines = bodyLines + 1
        end
        if gearUp and not f._gear then
            f._gear = { y = y }
            y = y - DOLL_MAX - 2
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
        -- standing reminders: up for as long as their steps run, under
        -- whatever is asking to be used right now
        if step and #holds > 0 then
            local warnC, plainC = RC:GetColor("text", "orange"), RC:GetColor("text", "normal")
            for i = 1, math.min(#holds, HOLD_ROWS) do
                local h = holds[i]
                local r = f.rems[REM_ROWS + i]
                PT(r.icon, PAD, y)
                ShowIcon(r.icon, h.icon or "Interface\\Icons\\INV_Misc_Note_01", true)
                r.fs:ClearAllPoints()
                if alignR then r.fs:SetPoint("RIGHT", r.icon, "LEFT", -6, 0)
                else r.fs:SetPoint("LEFT", r.icon, "RIGHT", 6, 0) end
                r.fs:SetText(h.text)
                local c = h.warn and warnC or plainC
                r.fs:SetTextColor(c.r, c.g, c.b)
                r.fs:SetWidth(wrapW - 2 * PAD - 22)
                r.fs:Show()
                Wide(22 + (r.fs:GetStringWidth() or 0))
                y = y - 19
                bodyLines = bodyLines + 1
            end
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
        local bandIconsW, swapChipW = 0, 0
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
            -- the landed swap's confirmation, on the same row (placed
            -- below, once the width is known)
            if (step or (self.finished and self._finAt)) and settings.trackerBandSwaps ~= false then
                swapChipW = FillSwapChip(self, f)
                if swapChipW > 0 then Wide(titleW + 16 + bandIconsW + swapChipW + (bandIconsW > 0 and 12 or 0)) end
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
        if swapChipW > 0 then
            -- what the row has left once the step's name, its count and
            -- the coming gear's icons have theirs
            local tagW = f.tag:IsShown() and (f.tag:GetWidth() + 10) or 0
            local nameW = math.min(f.title:GetStringWidth() or 0, f.title:GetWidth() or 0)
            local gap = bandIconsW > 0 and 12 or 0
            local room = w - 2 * PAD - HANDLE_W - nameW - tagW - bandIconsW - gap - 14
            -- It stands with the step it reports on - straight after the
            -- name and the count - and NOT beside the coming gear at the
            -- row's far end: "Frost Resist equipped" next to "when this
            -- is done" reads as one sentence, and a wrong one.
            if f.tag:IsShown() then
                PlaceSwapChip(self, f, room, { f.tag, "RIGHT", 14, 0 })
            elseif alignR then
                PlaceSwapChip(self, f, room, { f.head, "LEFT", PAD, 1 })
            else
                PlaceSwapChip(self, f, room, { f.title, "LEFT", nameW + 14, 0 })
            end
        end
        LayGearRow(self, f, w, alignR)
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
        -- the live tracker, docked: pinned to the chat box's top-left
        -- corner (nothing saved); leaving the dock, back to its own spot
        if f == RR.trackerFrame and self == RR then
            if dockL then
                f:ClearAllPoints()
                f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", dockL, dockT)
                if not f._rcDocked then
                    f._rcDocked = true
                    if self.ApplyTrackerLock then self:ApplyTrackerLock() end
                end
            elseif f._rcDocked then
                f._rcDocked = nil
                RC.Position.RestoreFrame(f)
                if self.ApplyTrackerLock then self:ApplyTrackerLock() end
            end
            if not self._measuring then self:SyncChatDock(dockL ~= nil, w) end
        end
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
        self._measuring = true
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
        self._measuring = nil
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
        local live = self:TrackerSettings()
        if live.trackerBasic == true then return end
        -- the bar style lays its segments out from the counts: redo it
        if live.trackerBand == true then return self:RefreshTracker() end
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
                    if live.trackerAlignRight then m.fill:SetPoint("TOPRIGHT", m.track, "TOPRIGHT", 0, 0)
                    else m.fill:SetPoint("TOPLEFT", m.track, "TOPLEFT", 0, 0) end
                    m.fill:SetWidth(math.max(1, (w - 2 * PAD) * frac))
                    m.fill:Show()
                else
                    m.fill:Hide()
                end
            end
        end
    end
