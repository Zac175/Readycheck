------------------------------------------------------------------------
-- Readycheck - Repair Reminder
-- Shows a floating anvil icon and fires a one-shot warning (print/sound/
-- TTS) when durability drops below db.repairReminder.threshold (default
-- 50%), checked on zone-in and around merchant visits only - no ticker,
-- no death/damage trigger. The warned flag gates repeat prints; it clears
-- when durability recovers and is force-reset on raid entry.
-- Never in combat: the anvil hides when a fight starts and the check
-- (with its print, sound and voice) waits until the fight is over.
------------------------------------------------------------------------
local function InitializeRepairReminder()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeRepairReminder)
        return
    end
    if not RC.db then
        C_Timer.After(0.2, InitializeRepairReminder)
        return
    end

    RC.repairReminder = RC.repairReminder or {}

    -- Only slots with a durability stat: armor pieces plus weapons/
    -- ranged. Rings, trinkets, neck, cloak, tabard, and shirt never
    -- have durability and are intentionally excluded.
    local DURABILITY_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 16, 17, 18 }

    function RC:InitializeRepairReminderDB()
        if not self.db.repairReminder then
            self.db.repairReminder = {}
        end
        local defaults = {
            enabled   = true,
            threshold = 50,
            playSound = false,
            soundKey  = "WR: Warning",
            soundFile = "Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg",
            tts       = false,
            weaponSkill = true,
        }
        for key, value in pairs(defaults) do
            if self.db.repairReminder[key] == nil then
                self.db.repairReminder[key] = value
            end
        end
    end

    function RC:GetDurabilityStats()
        local totalCur, totalMax = 0, 0
        local lowest
        for _, slot in ipairs(DURABILITY_SLOTS) do
            local cur, max = GetInventoryItemDurability(slot)
            if max and max > 0 then
                totalCur = totalCur + cur
                totalMax = totalMax + max
                local p = (cur / max) * 100
                if not lowest or p < lowest then lowest = p end
            end
        end
        if totalMax <= 0 then return 100, 100, false end
        return (totalCur / totalMax) * 100, (lowest or 100), true
    end

    ------------------------------------------------------------------
    -- THE ANVIL. Built by RC:BuildRepairAnvil and styled by
    -- RC:StyleRepairAnvil: the live anvil and the settings preview sample
    -- both go through them. Every look option is optional in
    -- db.repairReminder; nil is the shipped look.
    ------------------------------------------------------------------
    RC.REPAIR_ICON = "Interface\\Icons\\Trade_BlackSmithing"
    RC.REPAIR_LABEL_FONT = { size = 11, outline = "OUTLINE", shadow = true }
    RC.REPAIR_ANIM = { style = "none", duration = 0.3, easing = "easeOutQuad" }
    RC.REPAIR_ALERT_ANIM = { style = "none", duration = 0.8, easing = "easeOutQuad" }

    -- The customization standard on the anvil (repairReminder.anchors.label
    -- / .icon, repairReminder.formats.label): the caption and the icon art
    -- placeable, the caption worded. The caption gap is the label's
    -- default offset; nil = the anvil as it always was.
    RC.REPAIR_ICON_ANCHOR = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 0, y = 0,
                              point2 = "BOTTOMRIGHT", relPoint2 = "BOTTOMRIGHT", x2 = 0, y2 = 0 }
    RC.REPAIR_TARGETS = { { value = "frame", text = RCL["The anvil frame"] }, { value = "icon", text = RCL["Icon"] },
                          { value = "label", text = RCL["Caption"] } }
    RC.REPAIR_LABEL_TOKENS = { { token = "text", label = RCL["Caption text"] }, { token = "pct", label = RCL["Durability %"] } }
    local labelDef = {}
    function RC:RepairLabelAnchorDefault()
        local db = self.db and self.db.repairReminder or {}
        labelDef.point, labelDef.relPoint, labelDef.x, labelDef.y = "TOP", "BOTTOM", 0, tonumber(db.labelGap) or 8
        return labelDef
    end
    local function RepairTo(f)
        if not f._rpTo then
            f._rpTo = function(k)
                if k == "frame" then return f elseif k == "icon" then return f.icon elseif k == "label" then return f.label end
            end
        end
        return f._rpTo
    end
    local capVals, capKinds = {}, { text = "text", pct = "percent" }
    function RC:RepairCaptionText(base, pct, showPct)
        local db = self.db and self.db.repairReminder or {}
        local f = type(db.formats) == "table" and db.formats.label or nil
        if not f then
            if showPct and pct then return base .. " " .. math.floor(pct + 0.5) .. "%" end
            return base
        end
        capVals.text, capVals.pct = base, pct and math.floor(pct + 0.5) or nil
        local def = (showPct and pct) and { template = "[text] [pct]%", decimals = 0 } or { template = "[text]" }
        return RC.UI:FormatText(f, def, capVals, capKinds, "text")
    end

    function RC:RepairAnim(key, defaults)
        local db = self.db and self.db.repairReminder or {}
        return RC.Motion.Normalize(db[key], defaults or RC.REPAIR_ANIM)
    end

    -- live = the real anvil (named, above other frames); otherwise a
    -- plain sample for the preview
    function RC:BuildRepairAnvil(parent, live)
        local f = CreateFrame("Frame", live and "ReadycheckRepairAnvil" or nil, parent)
        f:SetSize(48, 48)
        if live then
            f:SetFrameStrata("HIGH")
            f:SetFrameLevel(110)
        end

        local icon = f:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        f.icon = icon

        f.edges = {}
        for i = 1, 4 do f.edges[i] = f:CreateTexture(nil, "BORDER") end

        -- 11px gold caption under the icon, the on-screen-frame title look
        -- shared with the other reminder frames.
        local label = self:CreateFontString(f, "OVERLAY", nil, 11)
        f.label = label
        if RC.UI.TagElement then RC.UI:TagElement(icon, "icon") RC.UI:TagElement(label, "label") end

        self:StyleRepairAnvil(f)
        return f
    end

    -- the anvil's states: worn below the threshold, or an item broken
    RC.REPAIR_STATES = {
        { id = "low", label = RCL["Worn (below the threshold)"] },
        { id = "broken", label = RCL["An item is broken"] },
    }
    function RC:RepairStateOf(pct)
        pct = tonumber(pct)
        return (pct and pct <= 0) and "broken" or "low"
    end

    -- pct: the durability to show when "show the percent" is on
    function RC:StyleRepairAnvil(f, pct)
        local db = self.db and self.db.repairReminder or {}
        local size = tonumber(db.iconSize) or 48
        f:SetSize(size, size)
        f.icon:SetTexture(db.icon or RC.REPAIR_ICON)

        local b = tonumber(db.borderSize) or 1
        local bc = (type(db.borderColor) == "table" and db.borderColor) or self:GetColor("ui", "borderNormal")
        local bT, bB, bL, bR = f.edges[1], f.edges[2], f.edges[3], f.edges[4]
        for _, t in ipairs(f.edges) do
            t:ClearAllPoints()
            t:SetColorTexture(bc.r, bc.g, bc.b, bc.a or 1)
            t:SetShown(db.showBorder ~= false and b > 0)
        end
        b = math.max(1, b)
        bT:SetPoint("TOPLEFT", -b, b);     bT:SetPoint("TOPRIGHT", b, b);      bT:SetHeight(b)
        bB:SetPoint("BOTTOMLEFT", -b, -b); bB:SetPoint("BOTTOMRIGHT", b, -b);  bB:SetHeight(b)
        bL:SetPoint("TOPLEFT", -b, b);     bL:SetPoint("BOTTOMLEFT", -b, -b);  bL:SetWidth(b)
        bR:SetPoint("TOPRIGHT", b, b);     bR:SetPoint("BOTTOMRIGHT", b, -b);  bR:SetWidth(b)

        local label = f.label
        self:ApplyFontSpec(label, db.labelFont, RC.REPAIR_LABEL_FONT)
        local lc = (type(db.labelColor) == "table" and db.labelColor) or self:GetColor("text", "gold")
        label:SetTextColor(lc.r, lc.g, lc.b, lc.a or 1)
        local a = type(db.anchors) == "table" and db.anchors or nil
        if a and a.label then
            RC.UI:ApplyAnchor(label, a.label, self:RepairLabelAnchorDefault(), RepairTo(f))
        else
            label:ClearAllPoints()
            label:SetPoint("TOP", f, "BOTTOM", 0, tonumber(db.labelGap) or 8)
        end
        if (a and a.icon) or f._rpIconMoved then
            local _, two = RC.UI:ApplyAnchor(f.icon, a and a.icon, RC.REPAIR_ICON_ANCHOR, RepairTo(f))
            if not two then f.icon:SetSize(size, size) end
            f._rpIconMoved = (a and a.icon) ~= nil
        end
        local txt = (type(db.labelText) == "string" and db.labelText ~= "") and db.labelText or RCL["Repair"]
        txt = self:RepairCaptionText(txt, pct, db.showPercent)
        label:SetText(txt)
        label:SetShown(db.showLabel ~= false)
        -- a look per state (db.states.low / .broken: icon tint, grey,
        -- border and caption colours); unset = the look above
        local states = type(db.states) == "table" and db.states or nil
        if states or f._rpStated then
            f._rpStated = states ~= nil
            f.icon:SetVertexColor(1, 1, 1, 1)
            f.icon:SetDesaturated(false)
            RC.UI:ApplyState(states, RC:RepairStateOf(pct), nil, { icon = f.icon, border = f.edges, text = label })
        end
        -- layer / scale / clamp, fade rules, shadow / glow (the standard;
        -- its own border stays its own)
        if RC.ApplyFrameCustom then
            RC:ApplyFrameCustom(f, function() return RC.db and RC.db.repairReminder end,
                { sample = (f ~= (RC.repairReminder and RC.repairReminder.anvil)) })
        end
    end

    -- Pinned to the reminder alert (or its saved spot), nudged by the
    -- anvil's own offset.
    function RC:PlaceRepairAnvil(f)
        local db = self.db and self.db.repairReminder or {}
        local ox, oy = tonumber(db.xOffset) or 0, tonumber(db.yOffset) or 0
        f:ClearAllPoints()
        if self.reminderFrame then
            f:SetPoint("CENTER", self.reminderFrame, "CENTER", ox, oy)
        else
            local x = (self.db and self.db.xOffset) or 0
            local y = (self.db and self.db.yOffset) or 200
            f:SetPoint("CENTER", UIParent, "CENTER", x + ox, y + oy)
        end
    end

    function RC:CreateRepairAnvil()
        if self.repairReminder.anvil then return self.repairReminder.anvil end

        -- Deliberately NOT registered with RC.UIMover: the anvil is pinned
        -- to the reminder alert (or to db.xOffset/yOffset, which is that
        -- same frame's saved position), so it moves when "Reminder Alert"
        -- is moved in the mover. Giving it its own anchor would fight that.
        local f = self:BuildRepairAnvil(UIParent, true)
        self:PlaceRepairAnvil(f)
        f:Hide()
        self.repairReminder.anvil = f
        return f
    end

    -- Restyles and re-places the live anvil after a settings change.
    function RC:RefreshRepairAnvil()
        local f = self.repairReminder and self.repairReminder.anvil
        if not f then return end
        self:StyleRepairAnvil(f, self.repairReminder.lastPct)
        if not RC.Motion.IsPlaying(f) then self:PlaceRepairAnvil(f) end
    end

    function RC:UpdateRepairAnvil(show)
        local f = self.repairReminder.anvil
        if not f then
            if not show then return end
            f = self:CreateRepairAnvil()
            if not f then return end
        end
        local M = RC.Motion
        if show then
            if f:IsShown() and not (M.IsPlaying(f) and f._rcMotion and f._rcMotion.how == "out") then return end
            M.Stop(f)
            self:StyleRepairAnvil(f, self.repairReminder.lastPct)
            self:PlaceRepairAnvil(f)
            M.Show(f, self:RepairAnim("showAnim"), function()
                if f:IsShown() then M.Play(f, self:RepairAnim("alertAnim", RC.REPAIR_ALERT_ANIM), "update") end
            end)
        elseif f:IsShown() then
            M.Hide(f, self:RepairAnim("hideAnim"))
        end
    end

    -- The page's "Show it now": the real anvil for a few seconds.
    function RC:TestRepairAnvil()
        local f = self:CreateRepairAnvil()
        self.repairReminder.testUntil = GetTime() + 6
        local avg = self:GetDurabilityStats()
        self.repairReminder.lastPct = self.repairReminder.lastPct or avg or 42
        RC.Motion.Stop(f)
        f:Hide()
        self:UpdateRepairAnvil(true)
        C_Timer.After(6.05, function()
            if GetTime() < (RC.repairReminder.testUntil or 0) then return end
            RC.repairReminder.testUntil = nil
            if RC.CheckRepairDurability then RC:CheckRepairDurability() end
        end)
    end

    function RC:CheckRepairDurability()
        local db = self.db and self.db.repairReminder
        if not db or not db.enabled then
            self:UpdateRepairAnvil(false)
            return
        end

        if MerchantFrame and MerchantFrame:IsShown() then
            self:UpdateRepairAnvil(false)
            return
        end

        -- nothing to do about it mid-fight: stay out of the way, look again after
        if InCombatLockdown() or UnitAffectingCombat("player") then
            self:UpdateRepairAnvil(false)
            self.repairReminder.afterCombat = true
            return
        end

        local avg, lowest, hasItems = self:GetDurabilityStats()
        if not hasItems then
            self:UpdateRepairAnvil(false)
            return
        end

        -- Triggers on overall average OR any single piece dropping below
        -- threshold, so one badly-worn item is enough even if the average
        -- still looks fine.
        local threshold = db.threshold or 50
        local low = (avg < threshold) or (lowest < threshold)

        self:DebugPrint(string.format(RCL["Repair check: overall %.0f%%, lowest %.0f%%, threshold %d%% -> %s"],
            avg, lowest, threshold, low and RCL["LOW (show icon)"] or RCL["ok (hide icon)"]), "system")

        self.repairReminder.lastPct = math.min(avg, lowest)
        -- the page's "Show it now" keeps the anvil up for its few seconds
        local testing = self.repairReminder.testUntil and GetTime() < self.repairReminder.testUntil
        if low or not testing then self:UpdateRepairAnvil(low) end

        if not low then
            self.repairReminder.warned = false
            return
        end

        if self.repairReminder.warned then return end
        self.repairReminder.warned = true

        local avgText = math.floor(avg + 0.5)
        local lowText = math.floor(lowest + 0.5)
        self:Print(RCL["Gear durability low - lowest item "] .. lowText .. RCL["%, overall "] .. avgText .. RCL["%. Time to repair."])

        if db.playSound then
            -- the chosen LibSharedMedia sound; the saved file if that name is gone
            if self.PlaySoundKey then
                self:PlaySoundKey(db.soundKey or "WR: Warning",
                    db.soundFile or "Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg")
            end
        end

        if db.tts and self.SpeakTTS then
            self:SpeakTTS(RCL["repair your gear"], false)
        end

        self:DebugPrint("Repair reminder fired - lowest " .. lowText .. "%, overall " .. avgText .. "% (threshold " .. threshold .. "%)", "system")
    end

    ------------------------------------------------------------------
    -- WEAPON SKILL. When zoning into a raid, every weapon in the bags (and in hand) is
    -- matched to its weapon skill; one whose skill is below the maximum,
    -- or not learned at all, is named - so a swap weapon is not carried
    -- into a raid at 287/300. Only at max level: while levelling every
    -- skill trails the cap. Skill lines are read with every header open
    -- (closed ones are opened and closed again), and matched by name:
    -- the item's type ("One-Handed Axes") against the skill ("Axes"),
    -- exact first, else the longest skill name the type ends with.
    ------------------------------------------------------------------
    local SKIP_SUBCLASS = { [14] = true, [19] = true, [20] = true }   -- misc, wands, fishing poles

    local function ReadSkillLines()
        local lines = {}
        if not (GetNumSkillLines and GetSkillLineInfo) then return lines end
        local reclose = {}
        local i = 1
        while i <= GetNumSkillLines() do
            local name, isHeader, isExpanded = GetSkillLineInfo(i)
            if isHeader and not isExpanded and ExpandSkillHeader then
                reclose[#reclose + 1] = name
                ExpandSkillHeader(i)
            end
            i = i + 1
        end
        for k = 1, GetNumSkillLines() do
            local name, isHeader, _, rank, _, modifier, maxRank = GetSkillLineInfo(k)
            if name and not isHeader then
                lines[#lines + 1] = { name = name, lname = name:lower(), rank = rank or 0, max = maxRank or 0 }
            end
        end
        -- headers go back the way they were (from the bottom, so indexes hold)
        if #reclose > 0 and CollapseSkillHeader then
            local want = {}
            for _, n in ipairs(reclose) do want[n] = true end
            for k = GetNumSkillLines(), 1, -1 do
                local name, isHeader, isExpanded = GetSkillLineInfo(k)
                if isHeader and isExpanded and want[name] then CollapseSkillHeader(k) end
            end
        end
        return lines
    end

    -- Two-handed types must match their skill exactly; a one-handed type
    -- may match by its ending ("One-Handed Axes" -> "Axes") but never a
    -- two-handed skill, so a missing "Two-Handed Swords" is not read as
    -- "Swords".
    local TWO_HANDED = { [1] = true, [5] = true, [8] = true }
    local subInfo = (C_Item and C_Item.GetItemSubClassInfo) or GetItemSubClassInfo
    local function SkillFor(lines, subType, subclassId)
        local s = subType and subType:lower()
        if not s then return nil end
        for _, l in ipairs(lines) do
            if l.lname == s then return l end
        end
        if TWO_HANDED[subclassId] then return nil end
        local twoNames = {}
        if subInfo then
            for id in pairs(TWO_HANDED) do
                local n = subInfo(2, id)
                if n then twoNames[n:lower()] = true end
            end
        end
        local best
        for _, l in ipairs(lines) do
            if not twoNames[l.lname] and #l.lname < #s and s:sub(-#l.lname) == l.lname
               and (not best or #l.lname > #best.lname) then
                best = l
            end
        end
        return best
    end

    -- Returns { { skill, rank, max, item, untrained }, ... }, one per skill.
    function RC:FindUntrainedWeapons()
        local lines = ReadSkillLines()
        local found, seen = {}, {}
        local function Look(itemId, where)
            if not itemId or not GetItemInfoInstant then return end
            local _, _, subType, _, _, classId, subclassId = GetItemInfoInstant(itemId)
            if classId ~= 2 or SKIP_SUBCLASS[subclassId] then return end
            local l = SkillFor(lines, subType, subclassId)
            local key = l and l.name or subType or tostring(itemId)
            if seen[key] then return end
            local itemName = (GetItemInfo and GetItemInfo(itemId)) or ("item " .. itemId)
            if not l then
                seen[key] = true
                found[#found + 1] = { skill = subType or "?", item = itemName, where = where, untrained = true }
            elseif l.max > 0 and l.rank < l.max then
                seen[key] = true
                found[#found + 1] = { skill = l.name, rank = l.rank, max = l.max, item = itemName, where = where }
            end
        end
        for _, slot in ipairs({ 16, 17, 18 }) do
            Look(GetInventoryItemID and GetInventoryItemID("player", slot), "equipped")
        end
        local numSlots = C_Container and C_Container.GetContainerNumSlots
        local itemAt = C_Container and C_Container.GetContainerItemID
        if numSlots and itemAt then
            for bag = 0, 4 do
                for slot = 1, numSlots(bag) or 0 do
                    Look(itemAt(bag, slot), "bags")
                end
            end
        end
        return found
    end

    function RC:CheckWeaponSkills(manual)
        local db = self.db and self.db.repairReminder
        if not db then return end
        if not manual and db.weaponSkill == false then return end
        local maxLevel = (GetMaxPlayerLevel and GetMaxPlayerLevel()) or 60
        if not manual and (UnitLevel("player") or 0) < maxLevel then return end
        local found = self:FindUntrainedWeapons()
        if #found == 0 then
            if manual then self:Print(RCL["Weapon skills: every weapon you carry is at full skill."]) end
            return
        end
        local parts = {}
        for _, w in ipairs(found) do
            if w.untrained then
                self:Print(string.format(RCL["Weapon skill: you have not learned %s yet - %s (%s) cannot be used well. A weapon master can teach it."],
                    w.skill, w.item, w.where == "equipped" and RCL["equipped"] or RCL["in your bags"]))
                parts[#parts + 1] = w.skill .. RCL[" not learned"]
            else
                self:Print(string.format(RCL["Weapon skill: %s is %d/%d - %s (%s) will miss more until you skill it up."],
                    w.skill, w.rank, w.max, w.item, w.where == "equipped" and RCL["equipped"] or RCL["in your bags"]))
                parts[#parts + 1] = w.skill .. " " .. w.rank .. "/" .. w.max
            end
        end
        if self.ShowReminderForced then
            self:ShowReminderForced(RCL["Weapon skill low: "] .. table.concat(parts, ", "), {}, 10)
        end
        if db.playSound and self.PlaySoundKey then
            self:PlaySoundKey(db.soundKey or "WR: Warning", db.soundFile)
        end
        if db.tts and self.SpeakTTS then self:SpeakTTS(RCL["weapon skill low"], false) end
    end

    function RC:ScheduleRepairCheck(delay)
        if self.repairReminder.pending then return end
        self.repairReminder.pending = true
        C_Timer.After(delay or 3.0, function()
            RC.repairReminder.pending = false
            if RC.CheckRepairDurability then RC:CheckRepairDurability() end
        end)
    end

    RC:InitializeRepairReminderDB()

    -- Only checked at zone-in and around merchant visits - there is no
    -- durability-loss event (e.g. on death) that re-triggers this mid-
    -- session, so a piece that breaks mid-raid won't re-flag until the
    -- next zone transition or repair-vendor visit.
    local didInitialCheck = false
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("MERCHANT_SHOW")
    eventFrame:RegisterEvent("MERCHANT_CLOSED")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            -- a shown anvil goes away for the fight
            local f = RC.repairReminder.anvil
            if f and f:IsShown() then
                RC.Motion.Stop(f)
                f:Hide()
                RC.repairReminder.afterCombat = true
            end
            return
        elseif event == "PLAYER_REGEN_ENABLED" then
            if RC.repairReminder.afterCombat then
                RC.repairReminder.afterCombat = false
                RC:ScheduleRepairCheck(1.0)
            end
            return
        end
        if event == "PLAYER_ENTERING_WORLD" then
            local _, instanceType = IsInInstance()
            local enteredRaid = (instanceType == "raid")
            -- Re-arms the one-shot warning on raid entry even if nothing
            -- changed, so a durability warning suppressed earlier in the
            -- session still fires again for this pull.
            if enteredRaid then
                RC.repairReminder.warned = false
            end
            if not didInitialCheck or enteredRaid then
                didInitialCheck = true
                RC:ScheduleRepairCheck(3.0)
            end
            -- Weapon skills are only checked when zoning into a raid (a
            -- reload inside one counts), never at an ordinary login.
            if enteredRaid then
                local function Try(n)
                    if InCombatLockdown() then
                        if n < 20 then C_Timer.After(10, function() Try(n + 1) end) end
                        return
                    end
                    if RC.CheckWeaponSkills then RC:CheckWeaponSkills(false) end
                end
                C_Timer.After(8, function() Try(0) end)
            end
        elseif event == "MERCHANT_SHOW" then
            if RC.UpdateRepairAnvil then RC:UpdateRepairAnvil(false) end
        elseif event == "MERCHANT_CLOSED" then
            RC:ScheduleRepairCheck(0.5)
        end
    end)

    didInitialCheck = true
    RC:ScheduleRepairCheck(3.0)

    -- The preview: the anvil itself, built and styled by the same code
    -- as the live one, at a sample durability.
    local PV_W, PV_H = 72, 76   -- update sizes the canvas to the anvil
    local function PreviewBuild(canvas, P)
        P.store.anvil = RC:BuildRepairAnvil(canvas, false)
        P.store.anvil:SetPoint("CENTER", canvas, "CENTER", 0, 8)
        P.store.token = 0
    end
    local function PreviewUpdate(canvas, P)
        local f = P.store.anvil
        local db = RC.db.repairReminder
        local size = tonumber(db.iconSize) or 48
        local sig = tostring(size)
        if P.store.sig ~= sig then
            RC.Motion.Stop(f)
            f:SetScale(1)
            P.store.sig = sig
        end
        -- the anvil at its real size with its reading under it; the
        -- canvas is that box and the strip scales it
        P.Resize(size + 24, size + 28)
        RC:StyleRepairAnvil(f, (P.mode == "broken") and 0 or 42)
    end
    -- in, the attention animation for a beat, out, back at rest
    local function PreviewReplay(canvas, P)
        local f, st, M = P.store.anvil, P.store, RC.Motion
        st.token = st.token + 1
        local t = st.token
        M.Stop(f)
        f:Hide()
        local inSpec = RC:RepairAnim("showAnim")
        M.Show(f, inSpec, function()
            if t == st.token and f:IsVisible() then
                M.Play(f, RC:RepairAnim("alertAnim", RC.REPAIR_ALERT_ANIM), "update")
            end
        end)
        local alert = RC:RepairAnim("alertAnim", RC.REPAIR_ALERT_ANIM)
        local hold = M.Duration(inSpec.duration + inSpec.delay) + M.Duration(alert.duration + alert.delay) + 1.2
        C_Timer.After(hold, function()
            if t ~= st.token or not f:IsVisible() then return end
            local outSpec = RC:RepairAnim("hideAnim")
            M.Hide(f, outSpec)
            C_Timer.After(M.Duration(outSpec.duration + outSpec.delay) + 0.4, function()
                if t ~= st.token then return end
                M.Stop(f)
                if canvas:IsVisible() then f:Show() end
            end)
        end)
    end

    local REPAIR_TABS = {
        { key = "behavior",  label = RCL["Behavior"] },
        { key = "look",      label = RCL["Look"] },
        { key = "text",      label = RCL["Text"] },
        { key = "animation", label = RCL["Animation"] },
        { key = "sound",     label = RCL["Sound"] },
        { key = "position",  label = RCL["Position"] },
    }

    function RC:ShowSidebarRepairReminderConfig(frame, preserveScroll)
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local parent = frame.scrollChild
        local yPos = -20
        local L = RC._seq and RC._seq.Look
        self:InitializeRepairReminderDB()
        local db = self.db.repairReminder

        local P = self.UI:DeclarePreview({
            key = "repair.anvil", title = RCL["Repair reminder"],
            width = PV_W, height = PV_H,
            build = PreviewBuild, update = PreviewUpdate, replay = PreviewReplay,
            modes = { { id = "low", label = RCL["Worn"] }, { id = "broken", label = RCL["Broken"] } }, modesLabel = RCL["Show"],
        })

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Repair Reminder"],
            RCL["A heads-up to repair when your gear is running low on durability"],
            "Interface\\Icons\\Trade_BlackSmithing")
        yPos = newY

        local tab = L.TabKey(frame.repairTab, REPAIR_TABS, nil, "behavior")
        frame.repairTab = tab
        local _, tabY = self.UI:CreateTabGroup(parent, { y = yPos, tabs = REPAIR_TABS, selected = tab,
            onClick = function(k) frame.repairTab = k RC:ShowSidebarRepairReminderConfig(frame, true) end,
            advance = 46 })
        yPos = tabY

        local function Apply() RC:RefreshRepairAnvil() end

        if tab == "behavior" then
            yPos = L.Card(parent, yPos, RCL["Repair reminder"], function(card, cy)
                local enableCb
                cy, enableCb = L.Check(card, cy, RCL["Remind me to repair when durability is low"], db.enabled, function(on)
                    db.enabled = on
                    RC.repairReminder.warned = false
                    RC:SaveConfigurationToProfile()
                    if RC.CheckRepairDurability then RC:CheckRepairDurability() end
                end)
                cy = cy - 6
                local enableMark = RC.UI:MarkCard(card)
                cy = L.Slider(card, cy, { label = RCL["Warn when durability drops below"], min = 5, max = 95, step = 5,
                    value = db.threshold or 50, fmt = function(v) return v .. "%" end,
                    set = function(v)
                        db.threshold = v
                        RC.repairReminder.warned = false
                        if RC.CheckRepairDurability then RC:CheckRepairDurability() end
                    end })
                cy = L.Desc(card, cy, RCL["Triggers if your overall durability OR any single item drops below this, so one worn piece is enough to flag a repair."])
                -- (the durability readout below stays as it is)
                RC.UI:BindDependents(enableCb, RC.UI:CardSince(card, enableMark))
                local avg, lowest, hasItems = self:GetDurabilityStats()
                local status = hasItems and (RCL["Current durability - overall "] .. math.floor(avg + 0.5) .. RCL["%, lowest item "] .. math.floor(lowest + 0.5) .. "%")
                    or RCL["No items with durability are equipped right now."]
                cy = L.Desc(card, cy - 4, status)
                return cy
            end)
            yPos = RC.UI:FrameVisibilityCard(parent, yPos, db, function() Apply() end)

            yPos = L.Card(parent, yPos, RCL["Weapon skill"], function(card, cy)
                local wsCheck
                cy, wsCheck = L.Check(card, cy, RCL["When I zone into a raid, warn about weapons below full skill"], db.weaponSkill ~= false, function(on)
                    db.weaponSkill = on
                    RC:SaveConfigurationToProfile()
                end)
                local wsBtn = self.UI:CreateStyledButton(card, RCL["Check Now"], 96, 22)
                wsBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -14, -30)
                wsBtn:SetScript("OnClick", function() RC:CheckWeaponSkills(true) end)
                cy = L.Desc(card, cy, RCL["Looks at every weapon in your bags and in your hands. A weapon whose skill is not maxed - or not learned at all - is named in chat, so a swap weapon never goes into a raid at 287/300. Only at max level."])
                return cy
            end)

        elseif tab == "look" then
            yPos = L.Card(parent, yPos, RCL["Icon"], function(card, cy)
                cy = L.Slider(card, cy, { label = RCL["Icon size"], min = 16, max = 128, step = 2,
                    value = db.iconSize or 48, fmt = function(v) return v .. RCL[" px"] end,
                    set = function(v) db.iconSize = v Apply() end })
                cy = L.Label(card, cy, RCL["Icon picture"])
                local swatch = CreateFrame("Frame", nil, card)
                swatch:SetSize(28, 28)
                swatch:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                swatch.tex = swatch:CreateTexture(nil, "ARTWORK")
                swatch.tex:SetAllPoints()
                swatch.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                swatch.tex:SetTexture(db.icon or RC.REPAIR_ICON)
                swatch.border = self.UI:CreateSimpleBorder(swatch)
                local pick = self.UI:CreateStyledButton(card, RCL["Choose icon"], 110, 22)
                pick:SetPoint("LEFT", swatch, "RIGHT", 10, 0)
                pick:SetScript("OnClick", function(b)
                    local GM = RC.GearManager
                    if GM and GM.ShowIconPickerGrid then
                        GM:ShowIconPickerGrid(function(iconID)
                            db.icon = iconID
                            swatch.tex:SetTexture(iconID)
                            Apply()
                            RC:SaveConfigurationToProfile()
                            RC.UI:NotifySettingChanged("icon")
                        end, db.icon or RC.REPAIR_ICON, b, "RIGHT")
                    end
                end)
                local def = self.UI:CreateStyledButton(card, RCL["Anvil"], 70, 22)
                def:SetPoint("LEFT", pick, "RIGHT", 6, 0)
                def:SetScript("OnClick", function()
                    db.icon = nil
                    swatch.tex:SetTexture(RC.REPAIR_ICON)
                    Apply()
                    RC:SaveConfigurationToProfile()
                    RC.UI:NotifySettingChanged("icon")
                end)
                return cy - 36
            end)
            yPos = L.Card(parent, yPos, RCL["Border"], function(card, cy)
                local borderCb
                cy, borderCb = L.Check(card, cy, RCL["Show a border around the icon"], db.showBorder ~= false, function(on)
                    db.showBorder = on Apply() RC:SaveConfigurationToProfile()
                end)
                local mark = RC.UI:MarkCard(card)
                cy = L.Slider(card, cy - 4, { label = RCL["Border thickness"], min = 1, max = 6, step = 1,
                    value = db.borderSize or 1, fmt = function(v) return v .. RCL[" px"] end,
                    set = function(v) db.borderSize = v Apply() end })
                cy = L.OwnColor(card, cy, db, "borderColor", RCL["Border colour"],
                    function() return RC:GetColor("ui", "borderNormal") end, Apply)
                RC.UI:BindDependents(borderCb, RC.UI:CardSince(card, mark))
                return cy
            end)
            yPos = RC.UI:FrameChromeCard(parent, yPos, db, function() Apply() end,
                { title = RCL["Shadow and glow"], fields = { shadowSize = true, shadowColor = true, glowSize = true, glowColor = true } })
            -- a look per state: worn, or an item broken
            yPos = L.Card(parent, yPos, RCL["Look per state"], function(card, cy)
                local cw = card:GetWidth() or 0
                local W = (cw > 240) and math.min(460, cw - 28) or 420
                local sg, ss = RC.UI:CustomAccess(db, "states", nil, function() RC:SaveConfigurationToProfile() Apply() end)
                RC._repairStateMem = RC._repairStateMem or {}
                local se = RC.UI:CreateCustomFold(card, { width = W, key = "states|repair",
                    label = RCL["Worn, or an item broken"],
                    changed = function() local t = sg() return type(t) == "table" and next(t) ~= nil end,
                    ctor = "CreateStateEditor",
                    args = { width = W, get = sg, set = ss, states = RC.REPAIR_STATES, remember = RC._repairStateMem,
                        fields = { color = true, desat = true, border = true, textColor = true } } })
                se:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                cy = cy - se:GetHeight() - 8
                return L.Desc(card, cy, RCL["Unset, the anvil keeps the look above. Pick Broken in the preview to see that state."])
            end)

        elseif tab == "text" then
            yPos = L.Card(parent, yPos, RCL["Caption"], function(card, cy)
                local captionCb
                cy, captionCb = L.Check(card, cy, RCL["Show a caption under the icon"], db.showLabel ~= false, function(on)
                    db.showLabel = on Apply() RC:SaveConfigurationToProfile()
                end)
                local mark = RC.UI:MarkCard(card)
                cy = L.Check(card, cy, RCL["Add the durability percent"], db.showPercent == true, function(on)
                    db.showPercent = on Apply() RC:SaveConfigurationToProfile()
                end, RCL["Shows the lowest of your overall and single-item durability, as the warning uses it."])
                cy = L.Label(card, cy - 2, RCL["Caption text"])
                local eb = self.UI:CreateStyledEditBox(card, { width = 200, height = 22, maxLetters = 24,
                    initialText = (type(db.labelText) == "string" and db.labelText) or "" })
                eb:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                local function Commit()
                    local v = eb.editBox:GetText()
                    db.labelText = (v and v ~= "") and v or nil
                    Apply()
                    RC:SaveConfigurationToProfile()
                end
                eb.editBox:HookScript("OnEnterPressed", Commit)
                eb.editBox:HookScript("OnEditFocusLost", Commit)
                cy = L.Desc(card, cy - 28, RCL["Empty: Repair."])
                cy = L.Font(card, cy, db, "labelFont", RCL["Caption font"], RC.REPAIR_LABEL_FONT, RCL["Repair"] .. " 42%", Apply)
                cy = L.OwnColor(card, cy, db, "labelColor", RCL["Caption colour"],
                    function() return RC:GetColor("text", "gold") end, Apply)
                cy = L.Slider(card, cy, { label = RCL["Caption gap"], min = -20, max = 30, step = 1,
                    value = db.labelGap or 8, fmt = function(v) return v .. RCL[" px"] end,
                    set = function(v) db.labelGap = v Apply() end })
                cy = L.Desc(card, cy, RCL["How far the caption tucks up into the icon; lower moves it down."])
                -- where it sits and how it reads (the customization standard;
                -- the gap above is its default offset)
                local cw = card:GetWidth() or 0
                local W = (cw > 240) and math.min(460, cw - 28) or 420
                local function Saved() RC:SaveConfigurationToProfile() Apply() end
                local ag, as = RC.UI:CustomAccess(db, "anchors", "label", Saved)
                local fg, fs = RC.UI:CustomAccess(db, "formats", "label", Saved)
                local te = RC.UI:CreateTextElement(card, { label = RCL["Caption place and wording"], key = "label", width = W,
                    formatGet = fg, formatSet = fs, formatKinds = { percent = true }, formatTokens = RC.REPAIR_LABEL_TOKENS,
                    formatDefaults = { decimals = 0 },
                    formatSample = function(spec)
                        local old = db.formats
                        db.formats = { label = spec }
                        local t = RC:RepairCaptionText(RCL["Repair"], 42, db.showPercent)
                        db.formats = old
                        return t
                    end,
                    anchorGet = ag, anchorSet = as, targets = { RC.REPAIR_TARGETS[1], RC.REPAIR_TARGETS[2] },
                    defaultTargetLabel = RCL["Under the icon"],
                    anchorDefaults = function() return RC:RepairLabelAnchorDefault() end })
                te:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                cy = cy - te:GetHeight() - 8
                RC.UI:BindDependents(captionCb, RC.UI:CardSince(card, mark))
                return cy
            end)

        elseif tab == "animation" then
            yPos = L.Card(parent, yPos, RCL["Animation"], function(card, cy)
                cy = L.Anim(card, cy, db, "showAnim", RCL["When it appears"], "in", RC.REPAIR_ANIM, P)
                cy = L.Anim(card, cy, db, "alertAnim", RCL["Then, to catch your eye"], "update", RC.REPAIR_ALERT_ANIM, P)
                cy = L.Anim(card, cy, db, "hideAnim", RCL["When it goes"], "out", RC.REPAIR_ANIM, P)
                return L.Desc(card, cy, RCL["Set the eye-catcher to Pulse or Flash with Repeat on to keep it moving until you repair."])
            end)

        elseif tab == "sound" then
            yPos = L.Card(parent, yPos, RCL["Sound"], function(card, cy)
                local soundCb
                cy, soundCb = L.Check(card, cy, RCL["Play a warning sound"], db.playSound, function(on)
                    db.playSound = on
                    RC:SaveConfigurationToProfile()
                end)
                if self.UI.CreateSoundPicker then
                    local repSound = self.UI:CreateSoundPicker(card, { width = 220, selected = db.soundKey or "WR: Warning",
                        onPick = function(key)
                            db.soundKey = key
                            db.soundFile = RC:GetSoundFile(key) or db.soundFile
                            RC:SaveConfigurationToProfile()
                        end })
                    repSound:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                    cy = cy - 32
                    RC.UI:BindDependents(soundCb, { repSound })

                end
                cy = L.Check(card, cy, RCL["Speak the reminder out loud"], db.tts, function(on)
                    db.tts = on
                    RC:SaveConfigurationToProfile()
                end)
                return cy
            end)

        elseif tab == "position" then
            yPos = L.Card(parent, yPos, RCL["Position"], function(card, cy)
                cy = L.Desc(card, cy, RCL["The anvil sits on the reminder alert and moves with it (move that in Edit Mode). These nudge it from there."])
                cy = L.Slider(card, cy, { label = RCL["Left / right"], min = -300, max = 300, step = 2,
                    value = db.xOffset or 0, fmt = function(v) return v .. RCL[" px"] end,
                    set = function(v) db.xOffset = v Apply() end })
                cy = L.Slider(card, cy, { label = RCL["Up / down"], min = -300, max = 300, step = 2,
                    value = db.yOffset or 0, fmt = function(v) return v .. RCL[" px"] end,
                    set = function(v) db.yOffset = v Apply() end })
                local test = self.UI:CreateStyledButton(card, RCL["Show it now"], 110, 22)
                test:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
                test:SetScript("OnClick", function() RC:TestRepairAnvil() end)
                -- the icon art inside the anvil's frame
                local cw = card:GetWidth() or 0
                local ig, is = RC.UI:CustomAccess(db, "anchors", "icon", function() RC:SaveConfigurationToProfile() Apply() end)
                local ie = RC.UI:CreateFrameElement(card, { label = RCL["Icon art"], key = "icon",
                    width = (cw > 240) and math.min(460, cw - 28) or 420,
                    anchorGet = ig, anchorSet = is, targets = { RC.REPAIR_TARGETS[1], RC.REPAIR_TARGETS[3] },
                    defaultTargetLabel = RCL["Fills the anvil frame"],
                    anchorDefaults = function() return RC.REPAIR_ICON_ANCHOR end })
                ie:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy - 34)
                local reset = self.UI:CreateStyledButton(card, RCL["Centre it"], 90, 22)
                reset:SetPoint("LEFT", test, "RIGHT", 6, 0)
                reset:SetScript("OnClick", function()
                    db.xOffset, db.yOffset = nil, nil
                    Apply()
                    RC:SaveConfigurationToProfile()
                    RC:ShowSidebarRepairReminderConfig(frame, true)
                end)
                return cy - 34 - ie:GetHeight() - 8
            end)
            yPos = RC.UI:FrameLayerCard(parent, yPos, db, function() Apply() end)
        end

        if self.UpdateSidebarScrollbar then
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
        end
    end

    RC:DebugPrint("RepairReminder module loaded", "system")
end

InitializeRepairReminder()
