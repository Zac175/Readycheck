------------------------------------------------------------------------
-- Readycheck - Battle Shout Reminder
-- Two frames: a small missing/low-AP warning icon, and a party roster
-- tracker listing Battle Shout status and Bloodrage per unit.
-- Both scan only warriors/rogues (BATTLE_SHOUT_CLASSES) and both poll on
-- bounded tickers rather than any per-frame or high-frequency event.
------------------------------------------------------------------------
local function InitializeBattleShoutReminder()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeBattleShoutReminder)
        return
    end

    if not RC.db then
        C_Timer.After(0.2, InitializeBattleShoutReminder)
        return
    end

    local UnitExists = UnitExists
    local UnitBuff = UnitBuff or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.UnitBuff)
    local UnitIsDeadOrGhost = UnitIsDeadOrGhost
    local UnitClass = UnitClass
    local GetTime = GetTime
    local IsInGroup = IsInGroup
    local IsInRaid = IsInRaid
    local UnitName = UnitName
    local IsInInstance = IsInInstance

    local BATTLE_SHOUT_NAME = "Battle Shout"
    local BLOODRAGE_NAME = "Bloodrage"

    local BATTLE_SHOUT_CLASSES = {
        ["WARRIOR"] = true,
        ["ROGUE"] = true,
    }

    RC.battleShoutReminder = {
        frame = nil,
        lastCheck = 0,
        checkInterval = 1.5,
        missingCount = 0,
        -- Only your own 5-man subgroup, even when IsInRaid() is true; a
        -- 40-man raid's other members are never scanned by this list.
        partyUnits = {"player", "party1", "party2", "party3", "party4"},
        lastWarningState = false
    }

    function RC:InitializeBattleShoutReminderDB()
        if not self.db.battleShoutReminder then
            self.db.battleShoutReminder = {}
        end

        local defaults = {
            enabled = false,
            locked = true,
            anchorPoint = "CENTER",
            xOffset = 200,
            yOffset = 0,
            opacity = 0.7,
            iconSize = 40,
            fontSize = 16,
            hideWhenAllBuffed = true,
            buffThreshold = 0,
            animationType = "none",
            showMissingNames = false,
            namesFontSize = 12,
            namesPosition = "right",
            shortenNames = false,
            showAPValue = false,
            playSound = false,
            soundKey = "WR: Warning",
            visibilityMode = "raids",
            -- visibilityRaids: optional { [raidName]=true } set created on
            -- demand by the settings page; absent = every raid counts.
            -- "group" = warn when anyone in your 5-man is missing a shout;
            -- "self"  = only care about the Battle Shout on you.
            trackScope = "group",
            greedMode = false,
            greedSkipIfImpCleave = false,
            rangeCheck = false,
        }

        for key, value in pairs(defaults) do
            if self.db.battleShoutReminder[key] == nil then
                self.db.battleShoutReminder[key] = value
            end
        end

        if self.db.battleShoutReminder.enableAnimation ~= nil then
            if self.db.battleShoutReminder.enableAnimation == true then
                self.db.battleShoutReminder.animationType = "none"
            end
            self.db.battleShoutReminder.enableAnimation = nil
        end
    end

    -- Only a warrior casts Battle Shout: on any other class the reminder
    -- and the party tracker stay hidden (they can still be placed with
    -- /moveui). A settings copy from a warrior used to leave them on.
    local function PlayerIsWarrior()
        local _, class = UnitClass("player")
        return class == nil or class == "WARRIOR"
    end

    function RC:ShouldShowBattleShoutReminder()
        if self._uiMoverActive then return true end
        if not PlayerIsWarrior() then return false end
        if not self.db.battleShoutReminder.enabled then
            return false
        end

        -- "Raids Only" means physically inside a raid instance. Being in a
        -- raid GROUP used to count too, so the reminder came up in
        -- Orgrimmar the moment someone converted to raid. Shared predicate
        -- so this flips on the same events as the bars. visibilityRaids
        -- (optional set keyed by RC.availableRaids names) narrows the raid
        -- case to the ticked raids; nil/empty = every raid.
        local cfg = self.db.battleShoutReminder
        local inRaidInstance = RC:IsInRaidInstance(cfg.visibilityRaids)
        local inGroup = IsInGroup()

        local mode = cfg.visibilityMode or "raids"
        if mode == "raids" then
            return inRaidInstance
        elseif mode == "instances" then
            -- a dungeon, or a raid (the raid filter still applies)
            return RC:IsInDungeonOrRaid(cfg.visibilityRaids)
        elseif mode == "group" then
            -- Any party or raid, anywhere.
            return inGroup
        elseif mode == "always" then
            return inGroup or inRaidInstance
        elseif mode == "everywhere" then
            -- Solo too: pairs naturally with "Only Me".
            return true
        end

        return false
    end

    function RC:UnitNeedsBattleShoutClass(unit)
        if not UnitExists(unit) then
            return false
        end

        local _, classToken = UnitClass(unit)
        return BATTLE_SHOUT_CLASSES[classToken] or false
    end

    -- The shout's AP as its tooltip words it. Keyed by unit with a 5s TTL
    -- when the buff has no expiration (permanent-looking auras), else
    -- keyed by expirationTime so a refreshed shout forces a re-parse.
    local _apCache = {}
    local AP_CACHE_TTL = 5

    -- A fractional figure is tried first: "(%d+)" alone reads "327.5"
    -- as 327.
    local AP_PHRASES = {
        "melee attack power by ",
        "[Aa]ttack power increased by ",
        "[Aa]ttack power by ",
    }
    local function ParseAP(txt)
        for _, phrase in ipairs(AP_PHRASES) do
            local v = txt:match(phrase .. "(%d+%.%d+)") or txt:match(phrase .. "(%d+)")
            if v then return tonumber(v) end
        end
    end

    -- Two sources, and they can disagree by the fraction. A shout with
    -- the 3-piece Wrath bonus and 5/5 Improved Battle Shout is
    -- (232 + 30) * 1.25 = 327.5: the game shows 328, but value1 can
    -- arrive cut down to 327. When the tooltip is within 1 of value1 it
    -- is the same shout better rounded, so it wins. Further apart than
    -- that the tooltip is describing something else and value1 stands.
    local function ResolveShoutAP(value1, tipAP)
        local v = (value1 and value1 > 0) and value1 or nil
        local t = (tipAP and tipAP > 0) and tipAP or nil
        local ap = v or t or 0
        if v and t and math.abs(t - v) <= 1 then ap = t end
        return math.floor(ap + 0.5)
    end

    local function GetAPFromTooltip(unit, buffIndex, expirationTime)
        local cached = _apCache[unit]
        if cached then
            if expirationTime and expirationTime > 0 then
                if cached.exp == expirationTime then
                    return cached.ap
                end
            elseif (GetTime() - cached.t) < AP_CACHE_TTL then
                return cached.ap
            end
        end
        local tt = RC:GetScanTooltip()
        tt:ClearLines()
        tt:SetUnitBuff(unit, buffIndex)
        local n = tt:GetName()
        local ap = 0
        for j = 2, tt:NumLines() do
            local line = _G[n .. "TextLeft" .. j]
            if line then
                local txt = line:GetText()
                if txt then
                    local v = ParseAP(txt)
                    if v then ap = v; break end
                end
            end
        end
        _apCache[unit] = {ap = ap, exp = expirationTime or 0, t = GetTime()}
        return ap
    end

    function RC:UnitBattleShoutStatus(unit)
        if not UnitExists(unit) then return false, 0, 0 end

        for i = 1, 40 do
            local name, _, _, _, _, expirationTime, _, _, _, _, _, _, _, _, _, value1 = UnitBuff(unit, i)
            if not name then break end

            if name == BATTLE_SHOUT_NAME then
                local remaining = 0
                if expirationTime and expirationTime > 0 then
                    remaining = math.max(0, expirationTime - GetTime())
                end

                -- Resolved once per shout per player, then cached.
                -- Keyed by name rather than unit token: raid unit ids
                -- (raid5, raid12, ...) shift on every roster change, a
                -- player's name does not.
                local apValue
                local uName = UnitName(unit) or unit
                RC._bsApCache = RC._bsApCache or {}
                local c = RC._bsApCache[uName]
                if c and c.exp == expirationTime and c.v1 == value1 and c.ap then
                    apValue = c.ap
                else
                    apValue = ResolveShoutAP(value1, GetAPFromTooltip(unit, i, expirationTime))
                    RC._bsApCache[uName] = { exp = expirationTime, v1 = value1, ap = apValue }
                end

                return true, remaining, apValue, (expirationTime or 0)
            end
        end

        return false, 0, 0, 0
    end

    function RC:UnitHasBloodrage(unit)
        if not UnitExists(unit) then return false end
        for i = 1, 40 do
            local name = UnitBuff(unit, i)
            if not name then break end
            if name == BLOODRAGE_NAME then
                return true
            end
        end
        return false
    end

    function RC:ScanBattleShoutStatus()
        local missing = 0
        local total = 0
        local outOfRange = 0
        local lowestRemaining = 999999
        local threshold = self.db.battleShoutReminder.buffThreshold or 0
        local lowestAP = 999999
        local hasWeakShout = false
        -- Below a max-rank, un-talented Battle Shout's AP value; flags a
        -- low-rank or unbuffed cast even though a buff is present.
        local WEAK_SHOUT_THRESHOLD = 290
        local wantNames = self.db.battleShoutReminder.showMissingNames
        local shorten = self.db.battleShoutReminder.shortenNames
        local doRangeCheck = self.db.battleShoutReminder.rangeCheck
        local missingNames = {}
        local lowNames = {}

        local function checkUnit(unit)
            if UnitExists(unit) and UnitIsConnected(unit) and not UnitIsDeadOrGhost(unit) then
                if self:UnitNeedsBattleShoutClass(unit) then
                    total = total + 1

                    if doRangeCheck and unit ~= "player" then
                        local _inRange, _checked = UnitInRange(unit)
                        if _checked and not _inRange then
                            outOfRange = outOfRange + 1
                            if wantNames then
                                local name = UnitName(unit)
                                if shorten and name then name = string.sub(name, 1, 3) end
                                table.insert(missingNames, "~" .. (name or "?"))
                            end
                            return
                        end
                    end

                    local hasBuff, remaining, apValue = self:UnitBattleShoutStatus(unit)

                    if not hasBuff then
                        missing = missing + 1
                        if wantNames then
                            local name = UnitName(unit)
                            if shorten and name then name = string.sub(name, 1, 3) end
                            table.insert(missingNames, name)
                        end
                    else
                        if remaining < lowestRemaining then lowestRemaining = remaining end
                        if apValue > 0 and apValue < lowestAP then lowestAP = apValue end
                        if apValue > 0 and apValue < WEAK_SHOUT_THRESHOLD then hasWeakShout = true end
                        if wantNames and threshold > 0 and remaining <= threshold then
                            local name = UnitName(unit)
                            if shorten and name then name = string.sub(name, 1, 3) end
                            table.insert(lowNames, name)
                        end
                    end
                end
            end
        end

        -- "Only me" ignores the group entirely: the reminder is about the
        -- shout on you, whoever cast it. (A shout from another warrior
        -- still counts as covered - re-shouting over it would not help.)
        local selfOnly = (self.db.battleShoutReminder.trackScope == "self")
        if not selfOnly and (IsInRaid() or IsInGroup()) then
            for _, unit in ipairs(self.battleShoutReminder.partyUnits) do
                checkUnit(unit)
            end
        else
            checkUnit("player")
        end

        local belowThreshold = 0
        if threshold > 0 and lowestRemaining <= threshold and lowestRemaining < 999999 then
            belowThreshold = 1
        end
        if lowestAP == 999999 then lowestAP = 0 end

        local allNames = {}
        for _, n in ipairs(missingNames) do table.insert(allNames, n) end
        for _, n in ipairs(lowNames) do table.insert(allNames, n) end

        return missing, total, lowestRemaining, belowThreshold, lowestAP, hasWeakShout, allNames, outOfRange
    end

    -- Stops whatever the icon is playing and puts it back at its resting
    -- scale/alpha/anchor. Every instant hide path calls it.
    function RC:StopBattleShoutAnimation(frame)
        if frame then
            if RC.Motion then RC.Motion.Stop(frame) end
            frame._bsAlert, frame._bsLeaving = nil, nil
            frame:SetScale(1.0)
            frame:SetAlpha(1)
            if frame.__rcPos then RC.Position.RestoreFrame(frame) end
        end
    end

    -- The icon's look, shared by the live frame and the settings preview.
    -- Fonts: countFont / namesFont hold face, outline and shadow; the size
    -- stays on the old fontSize / namesFontSize keys.
    RC.BATTLE_SHOUT_COUNT_FONT = { size = 16, outline = "OUTLINE", shadow = true }
    RC.BATTLE_SHOUT_NAMES_FONT = { size = 12, outline = "OUTLINE", shadow = true }
    local BS_ICON = "Interface\\Icons\\Ability_Warrior_BattleShout"

    local function FontSpec(t, key, sizeKey)
        local s = type(t[key]) == "table" and t[key] or {}
        return { face = s.face, outline = s.outline, shadow = s.shadow, size = t[sizeKey] }
    end

    -- Where every text and part of the two frames sits: Readycheck's anchor
    -- spec (RC.UI:ApplyAnchor), saved as <root>.anchors.<element> on each
    -- frame's own settings table. Each element's built-in placement -
    -- exactly the SetPoint it always had - is its defaults, so a profile
    -- without anchors draws exactly as before.
    --   reminder icon : count, names, icon          (battleShoutReminder.anchors)
    --   party tracker : title, titleIcon, rowName, rowStatus, rowIcon
    --                                                (battleShoutPartyTracker.anchors)
    -- The tracker also takes the layout family (battleShoutPartyTracker.layout:
    -- grow, spacingY, padding, sort, reverse, max) and text formats
    -- (battleShoutPartyTracker.formats.name / .time).
    local function SpecOf(db, key)
        local a = db and db.anchors
        return type(a) == "table" and a[key] or nil
    end
    local function Apply(region, spec, def, to)
        if RC.UI and RC.UI.ApplyAnchor then return RC.UI:ApplyAnchor(region, spec, def, to) end
        region:ClearAllPoints()
        region:SetPoint(def.point, def.to or region:GetParent(), def.relPoint or def.point, def.x or 0, def.y or 0)
        if def.point2 then region:SetPoint(def.point2, def.to2 or def.to or region:GetParent(), def.relPoint2 or def.point2, def.x2 or 0, def.y2 or 0) end
        if def.justify and region.SetJustifyH then region:SetJustifyH(def.justify) end
        return true, def.point2 ~= nil
    end
    local function SetDef(t, p, to, rp, x, y, j, p2, to2, rp2, x2, y2)
        t.point, t.to, t.relPoint, t.x, t.y, t.justify = p, to, rp, x, y, j
        t.point2, t.to2, t.relPoint2, t.x2, t.y2 = p2, to2, rp2, x2, y2
        return t
    end
    local BS_COUNT_DEF = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0, justify = "CENTER" }
    local BS_ICON_DEF  = { point = "TOPLEFT", relPoint = "TOPLEFT", x = 0, y = 0,
                           point2 = "BOTTOMRIGHT", relPoint2 = "BOTTOMRIGHT", x2 = 0, y2 = 0 }
    -- names: beside / above / below the icon by the gap (namesPosition, namesOffset)
    local function NamesDef(t, frame, db)
        local position = db.namesPosition or "right"
        local gap = tonumber(db.namesOffset) or 5
        if position == "left" then return SetDef(t, "RIGHT", frame, "LEFT", -gap, 0, "RIGHT") end
        if position == "above" then return SetDef(t, "BOTTOM", frame, "TOP", 0, gap, "CENTER") end
        if position == "below" then return SetDef(t, "TOP", frame, "BOTTOM", 0, -gap, "CENTER") end
        return SetDef(t, "LEFT", frame, "RIGHT", gap, 0, "LEFT")
    end
    local TR_TITLE_ICON_DEF = { point = "LEFT", relPoint = "LEFT", x = 6, y = 1 }
    local TR_STATUS_DEF     = { point = "RIGHT", relPoint = "RIGHT", x = -4, y = 0 }
    local TR_ROWICON_DEF    = { point = "LEFT", relPoint = "LEFT", x = 3, y = 0 }

    -- An element's default anchor for the settings page (points and
    -- offsets only; a scratch table, reused). which: "icon" | "tracker"
    local pageDef = {}
    function RC:BattleShoutAnchorDefaults(which, key)
        if which == "icon" then
            if key == "count" then return BS_COUNT_DEF end
            if key == "icon" then return BS_ICON_DEF end
            if key == "names" then return NamesDef(pageDef, nil, self.db.battleShoutReminder) end
        else
            if key == "titleIcon" then return TR_TITLE_ICON_DEF end
            if key == "rowStatus" then return TR_STATUS_DEF end
            if key == "rowIcon" then return TR_ROWICON_DEF end
            if key == "title" then return SetDef(pageDef, "LEFT", nil, "RIGHT", 5, 1, nil, "RIGHT", nil, "RIGHT", -38, 0) end
            if key == "rowName" then return SetDef(pageDef, "LEFT", nil, "LEFT", 4, 0, nil, "RIGHT", nil, "LEFT", -4, 0) end
        end
        return nil
    end
    -- the elements' labels and what each can hang off
    RC.BATTLE_SHOUT_ICON_TARGETS = {
        { value = "frame", text = RCL["The icon frame"] }, { value = "icon", text = RCL["Icon art"] },
        { value = "count", text = RCL["Count text"] }, { value = "names", text = RCL["Missing names"] },
    }
    RC.BATTLE_SHOUT_TITLE_TARGETS = {
        { value = "frame", text = RCL["The tracker"] }, { value = "header", text = RCL["Header bar"] },
        { value = "titleIcon", text = RCL["Title icon"] }, { value = "title", text = RCL["Title"] },
    }
    RC.BATTLE_SHOUT_ROW_TARGETS = {
        { value = "row", text = RCL["The row"] }, { value = "name", text = RCL["Name"] },
        { value = "status", text = RCL["Status"] }, { value = "icon", text = RCL["Bloodrage icon"] },
    }
    -- text formats: what each tracker text always looked like
    RC.BATTLE_SHOUT_NAME_FORMAT = { maxLen = 13, mark = "." }
    RC.BATTLE_SHOUT_TIME_FORMAT = { time = "clock" }
    -- the tracker's row orders (the layout family's "Order by")
    RC.BATTLE_SHOUT_SORTS = {
        { value = "name", text = RCL["Name"] }, { value = "time", text = RCL["Time left"] },
        { value = "status", text = RCL["Missing first"] },
    }
    local ROW_SORTS = {
        name = function(a, b) return (a.name or "") < (b.name or "") end,
        time = function(a, b)
            local ra = a.hasBuff and a.remaining or -1
            local rb = b.hasBuff and b.remaining or -1
            if ra ~= rb then return ra < rb end
            return (a.name or "") < (b.name or "")
        end,
        status = function(a, b)
            local sa = (not a.hasBuff and 0) or (a.belowThreshold and 1) or 2
            local sb = (not b.hasBuff and 0) or (b.belowThreshold and 1) or 2
            if sa ~= sb then return sa < sb end
            return (a.name or "") < (b.name or "")
        end,
    }

    -- Visual parts only: no position, mouse, events or name, so the
    -- preview can build one on its canvas.
    function RC:BuildBattleShoutIcon(parent, name)
        local frame = CreateFrame("Frame", name, parent)
        frame.bg = frame:CreateTexture(nil, "BACKGROUND")
        frame.bg:SetAllPoints()
        if RC.UI and RC.UI.CreateSimpleBorder then
            frame.border = RC.UI:CreateSimpleBorder(frame, 1)
        end
        frame.icon = frame:CreateTexture(nil, "ARTWORK")
        frame.icon:SetAllPoints()
        frame.icon:SetTexture(BS_ICON)
        frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        frame.desaturate = frame:CreateTexture(nil, "ARTWORK", nil, 1)
        frame.desaturate:SetAllPoints()
        frame.desaturate:SetTexture(BS_ICON)
        frame.desaturate:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        frame.desaturate:SetDesaturated(true)
        frame.desaturate:Hide()
        frame.countText = frame:CreateFontString(nil, "OVERLAY")
        frame.countText:SetPoint("CENTER", frame, "CENTER", 0, 0)
        frame.countText:SetJustifyH("CENTER")
        frame.namesText = frame:CreateFontString(nil, "OVERLAY")
        frame.namesText:Hide()
        frame._bsTo = function(k)
            if k == "frame" then return frame elseif k == "icon" then return frame.icon
            elseif k == "count" then return frame.countText elseif k == "names" then return frame.namesText end
        end
        frame._bsNamesDef = {}
        if RC.UI and RC.UI.TagElement then
            RC.UI:TagElement(frame.icon, "icon") RC.UI:TagElement(frame.desaturate, "icon")
            RC.UI:TagElement(frame.countText, "count") RC.UI:TagElement(frame.namesText, "names")
        end
        self:StyleBattleShoutIcon(frame, self.db.battleShoutReminder)
        return frame
    end

    -- Size, opacity, background, border thickness, fonts, names side.
    function RC:StyleBattleShoutIcon(frame, db)
        db = db or self.db.battleShoutReminder
        local size = db.iconSize or 40
        local opacity = db.opacity or 0.7
        frame:SetSize(size, size)
        local bgC = RC:GetColor("battleShoutReminder", "background")
        frame.bg:SetColorTexture(bgC.r, bgC.g, bgC.b, opacity * 0.7)
        frame.icon:SetAlpha(opacity)
        frame.desaturate:SetVertexColor(0.4, 0.4, 0.4, opacity)
        if frame.border then
            local bs = tonumber(db.borderSize) or 1
            for side, tex in pairs(frame.border) do
                if bs <= 0 then tex:Hide() else
                    tex:Show()
                    if side == "top" or side == "bottom" then tex:SetHeight(bs) else tex:SetWidth(bs) end
                end
            end
        end
        RC:ApplyFontSpec(frame.countText, FontSpec(db, "countFont", "fontSize"), RC.BATTLE_SHOUT_COUNT_FONT)
        -- the count has always worn a heavier 2px shadow
        local cs
        if type(db.countFont) == "table" then cs = db.countFont.shadow end
        if cs == nil or cs then frame.countText:SetShadowOffset(2, -2) end
        RC:ApplyFontSpec(frame.namesText, FontSpec(db, "namesFont", "namesFontSize"), RC.BATTLE_SHOUT_NAMES_FONT)
        Apply(frame.countText, SpecOf(db, "count"), BS_COUNT_DEF, frame._bsTo)
        local iconSpec = SpecOf(db, "icon")
        local _, two = Apply(frame.icon, iconSpec, BS_ICON_DEF, frame._bsTo)
        Apply(frame.desaturate, iconSpec, BS_ICON_DEF, frame._bsTo)
        if not two then
            frame.icon:SetSize(size, size)
            frame.desaturate:SetSize(size, size)
        end
        self:UpdateBattleShoutNamesPosition(frame, db)
        -- layer / scale / clamp, fade rules, shadow / glow (the standard)
        if self.ApplyFrameCustom then
            self:ApplyFrameCustom(frame, function() return RC.db and RC.db.battleShoutReminder end,
                { sample = (frame ~= (RC.battleShoutReminder and RC.battleShoutReminder.frame)) })
        end
    end

    -- One state painted onto an icon: warn (bool), the count text, the
    -- names list (or nil). Text and border colours come from the theme.
    function RC:FillBattleShoutIcon(frame, warn, text, names)
        local textColor = self:GetColor("battleShoutReminder", warn and "missingText" or "allBuffedText")
        frame.icon:SetShown(not warn)
        frame.desaturate:SetShown(warn and true or false)
        frame.countText:SetText(text or "")
        frame.countText:SetTextColor(textColor.r, textColor.g, textColor.b, textColor.a)
        if frame.border then
            local bc = self:GetColor("battleShoutReminder", warn and "missingBorder" or "normalBorder")
            for _, tex in pairs(frame.border) do
                tex:SetColorTexture(bc.r, bc.g, bc.b, bc.a)
            end
        end
        if frame.namesText then
            if names and names ~= "" then
                frame.namesText:SetText(names)
                frame.namesText:SetTextColor(textColor.r, textColor.g, textColor.b, textColor.a)
                frame.namesText:Show()
            else
                frame.namesText:Hide()
            end
        end
    end

    -- Entrance / exit / warning highlight for the live icon (showAnim,
    -- hideAnim, alertAnim; nil = none, as it has always been).
    local BS_NONE = { style = "none" }
    function RC:ShowBattleShoutIcon(frame, warn)
        local db = self.db.battleShoutReminder
        local M = RC.Motion
        local entering = (not frame:IsShown()) or frame._bsLeaving
        local function Alert()
            if warn and frame:IsShown() and not frame._bsLeaving and db.alertAnim then
                frame._bsAlert = true
                M.Play(frame, db.alertAnim, "update")
            end
        end
        if entering then
            frame._bsLeaving, frame._bsAlert = nil, nil
            if not M.Show(frame, db.showAnim or BS_NONE, Alert) then frame:Show() end
        elseif warn and not frame._bsAlert then
            Alert()
        elseif not warn and frame._bsAlert then
            frame._bsAlert = nil
            M.Stop(frame)
        end
    end

    function RC:HideBattleShoutIcon(frame)
        if not frame or not frame:IsShown() or frame._bsLeaving then return end
        local db = self.db.battleShoutReminder
        frame._bsAlert = nil
        frame._bsLeaving = true
        RC.Motion.Hide(frame, db.hideAnim or BS_NONE, function() frame._bsLeaving = nil end)
        if not frame:IsShown() then frame._bsLeaving = nil end
    end

    function RC:CreateBattleShoutReminderFrame()
        if self.battleShoutReminder.frame then
            return self.battleShoutReminder.frame
        end

        local db = self.db.battleShoutReminder
        local frame = self:BuildBattleShoutIcon(UIParent, "ReadycheckBattleShoutFrame")

        RC.Position.Bind(frame, function() return self.db.battleShoutReminder end, {
            point = "CENTER", pointKey = "anchorPoint", default = { x = 200, y = 0 },
        })
        RC.Position.RestoreFrame(frame)
        frame:SetMovable(true)
        frame:EnableMouse(not db.locked)
        frame:SetClampedToScreen(true)
        frame:SetFrameStrata("MEDIUM")
        frame:SetFrameLevel(50)

        -- the standard drag for a placed frame: unlocked, drag and drop;
        -- saved through RC.Position like the frame mover saves it
        RC.Position.MakeMovable(frame, function()
            local d = RC.db and RC.db.battleShoutReminder
            return not (d and d.locked)
        end)

        frame:Hide()
        self.battleShoutReminder.frame = frame

        return frame
    end

    function RC:ApplyBattleShoutLockState()
        local db = self.db.battleShoutReminder
        local frame = self.battleShoutReminder and self.battleShoutReminder.frame

        if frame then
            frame:EnableMouse(not db.locked)
            if db.locked and frame.unlockHint then
                frame.unlockHint:Hide()
            end
        end
    end

    -- Hide the reminder while greed mode is on and over half the shout's
    -- duration remains, so it doesn't nag about a refresh that isn't due.
    local GREED_SHOUT_THRESHOLD = 180
    function RC:PlayerHasGreedShout()
        local hasBuff, remaining = self:UnitBattleShoutStatus("player")
        return hasBuff and remaining > GREED_SHOUT_THRESHOLD
    end

    function RC:UpdateBattleShoutReminder()
        local frame = self.battleShoutReminder.frame
        if not self:ShouldShowBattleShoutReminder() then
            self:HideBattleShoutIcon(frame)
            return
        end

        if self.db.battleShoutReminder.greedMode and self:PlayerHasGreedShout() then
            self:HideBattleShoutIcon(frame)
            return
        end

        if self.db.battleShoutReminder.greedMode
           and self.db.battleShoutReminder.greedSkipIfImpCleave
           and self.HasTalent and self:HasTalent("Improved Cleave") then
            self:HideBattleShoutIcon(frame)
            return
        end

        if RC.Profiler then RC.Profiler:StartTiming("BattleShout") end

        local db = self.db.battleShoutReminder

        if not frame then
            frame = self:CreateBattleShoutReminderFrame()
        end

        local missing, total, lowestRemaining, belowThreshold, lowestAP, hasWeakShout, names, outOfRange = self:ScanBattleShoutStatus()

        self.battleShoutReminder.missingCount = missing

        if total == 0 then
            self:HideBattleShoutIcon(frame)
            if RC.Profiler then RC.Profiler:StopTiming("BattleShout") end
            return
        end

        local needsWarning = missing > 0 or belowThreshold > 0 or hasWeakShout

        if needsWarning and not self.battleShoutReminder.lastWarningState then
            if db.playSound then
                local soundKey = db.soundKey or "WR: Warning"
                local soundFile = db.soundFile
                if RC.GetSoundFile then
                    soundFile = RC:GetSoundFile(soundKey) or soundFile
                end
                soundFile = soundFile or "Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg"
                PlaySoundFile(soundFile, "Master")
                self:DebugPrint("Battle Shout warning sound played: " .. soundFile, "buff", 2)
            end

            if self.db.ttsEnabled and self.SpeakTTS then
                self:SpeakTTS(RCL["battle shout"], false)
                self:DebugPrint("Battle Shout TTS played", "buff", 2)
            end
        end

        self.battleShoutReminder.lastWarningState = needsWarning

        if db.hideWhenAllBuffed and not needsWarning then
            self:HideBattleShoutIcon(frame)
            if RC.Profiler then RC.Profiler:StopTiming("BattleShout") end
            return
        end

        local displayText, namesText = "", nil
        if needsWarning then
            -- With only yourself tracked, "1 missing" is just the icon
            -- itself, so the count is dropped and only the time is shown.
            local selfOnly = (db.trackScope == "self")

            if selfOnly then
                if hasWeakShout and db.showAPValue then
                    displayText = lowestAP .. " AP"
                elseif belowThreshold > 0 and missing == 0 then
                    displayText = tostring(math.floor(lowestRemaining))
                end
            elseif hasWeakShout and db.showAPValue then
                displayText = lowestAP .. " AP"
            elseif missing > 0 and belowThreshold > 0 then
                local timeLeft = math.floor(lowestRemaining)
                displayText = missing .. "/" .. timeLeft
            elseif missing > 0 then
                displayText = tostring(missing)
            elseif belowThreshold > 0 then
                local timeLeft = math.floor(lowestRemaining)
                displayText = tostring(timeLeft)
            end

            -- Your own name under your own icon is noise, so names are a
            -- group-mode thing only.
            if db.showMissingNames and not selfOnly and #names > 0 then
                namesText = table.concat(names, "\n")
            end
        elseif db.showAPValue and lowestAP > 0 then
            displayText = lowestAP .. " AP"
        end

        self:FillBattleShoutIcon(frame, needsWarning, displayText, namesText)
        self:ShowBattleShoutIcon(frame, needsWarning)

        self:DebugPrint("Battle Shout: " .. missing .. " missing, " .. (outOfRange or 0) .. " OOR, lowest=" .. math.floor(lowestRemaining) .. ", AP=" .. lowestAP, "buff", 2)

        if RC.Profiler then RC.Profiler:StopTiming("BattleShout") end
    end

    function RC:UpdateBattleShoutReminderAppearance()
        local frame = self.battleShoutReminder.frame
        if not frame then return end

        local db = self.db.battleShoutReminder
        self:StyleBattleShoutIcon(frame, db)
        -- re-anchoring mid-animation would fight the animation's rest
        if not RC.Motion.IsPlaying(frame) then RC.Position.RestoreFrame(frame) end

        frame:EnableMouse(not db.locked)
    end

    -- namesOffset: the gap between the icon and the names (5 px).
    function RC:UpdateBattleShoutNamesPosition(frame, db)
        if not frame or not frame.namesText then return end

        db = db or self.db.battleShoutReminder
        -- the side and gap pick the default; a saved anchor goes on top
        frame._bsNamesDef = frame._bsNamesDef or {}
        Apply(frame.namesText, SpecOf(db, "names"), NamesDef(frame._bsNamesDef, frame, db), frame._bsTo)
    end

    function RC:StartBattleShoutReminderUpdates()
        if self.battleShoutReminder.ticker then
            self.battleShoutReminder.ticker:Cancel()
            self.battleShoutReminder.ticker = nil
        end

        if not self:ShouldShowBattleShoutReminder() then
            return
        end

        local fn = function()
            if not self:ShouldShowBattleShoutReminder() then
                self:StopBattleShoutReminderUpdates()
                return
            end
            self:UpdateBattleShoutReminder()
        end
        if RC.Profiler and RC.Profiler.TrackTicker then
            self.battleShoutReminder.ticker = RC.Profiler:TrackTicker("BattleShout:MainReminder", self.battleShoutReminder.checkInterval, fn)
        else
            self.battleShoutReminder.ticker = C_Timer.NewTicker(self.battleShoutReminder.checkInterval, fn)
        end

        self:UpdateBattleShoutReminder()

        self:DebugPrint("Battle Shout Reminder started", "buff")
    end

    function RC:StopBattleShoutReminderUpdates()
        if self.battleShoutReminder.ticker then
            self.battleShoutReminder.ticker:Cancel()
            self.battleShoutReminder.ticker = nil
        end

        if self.battleShoutReminder.frame then
            self:StopBattleShoutAnimation(self.battleShoutReminder.frame)
            self.battleShoutReminder.frame:Hide()
        end

        self:DebugPrint("Battle Shout Reminder stopped", "buff")
    end

    function RC:ToggleBattleShoutReminder()
        self.db.battleShoutReminder.enabled = not self.db.battleShoutReminder.enabled

        if self.db.battleShoutReminder.enabled then
            self:StartBattleShoutReminderUpdates()
        else
            self:StopBattleShoutReminderUpdates()
        end

        self:SaveConfigurationToProfile()
    end

    -- The one re-evaluate for both frames: recomputes from scratch and
    -- starts or stops each ticker to match. Idempotent, so a burst of
    -- roster events collapsing onto it costs one pass.
    function RC:ReevaluateBattleShoutVisibility()
        if not self.db or not self.db.battleShoutReminder then return end
        if self.db.battleShoutReminder.enabled then
            if self:ShouldShowBattleShoutReminder() then
                if not self.battleShoutReminder.ticker then
                    self:StartBattleShoutReminderUpdates()
                else
                    self:UpdateBattleShoutReminder()
                end
            else
                self:StopBattleShoutReminderUpdates()
            end
        end
        if self.db.battleShoutPartyTracker and self.db.battleShoutPartyTracker.enabled then
            if self:ShouldShowPartyTracker() then
                self:StartBattleShoutPartyTrackerUpdates()
            else
                self:StopBattleShoutPartyTrackerUpdates()
            end
        end
    end

    -- Modes here are raids / in-group / everywhere, so zone and roster
    -- events are the full set. All of them go through the shared debounce
    -- (0.3s, plus a ~1s re-check after a loading screen).
    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")

    eventFrame:SetScript("OnEvent", function(self, event, arg1)
        if not RC.db or not RC.db.battleShoutReminder then
            return
        end
        RC:QueueVisibilityCheck(RC.battleShoutReminder, "ReevaluateBattleShoutVisibility",
            event == "PLAYER_ENTERING_WORLD")
    end)

    RC:InitializeBattleShoutReminderDB()

    RC.battleShoutPartyTracker = {
        frame         = nil,
        ticker        = nil,
        barTicker     = nil,
        barCache      = {},
        peakRemaining = {},
    }

    -- Row pool ceiling, sized for raid use; the scan below only ever
    -- fills 5 of these (see units table), so most rows stay hidden.
    local MAX_TRACKER_ROWS = 25

    function RC:InitializeBattleShoutPartyTrackerDB()
        if not self.db.battleShoutPartyTracker then
            self.db.battleShoutPartyTracker = {}
        end
        local db = self.db.battleShoutPartyTracker
        local defaults = {
            enabled         = false,
            locked          = true,
            xOffset         = 300,
            yOffset         = 400,
            scale           = 1.0,
            opacity         = 0.85,
            fontSize        = 11,
            visibilityMode  = "raids",
            -- visibilityRaids: optional { [raidName]=true } set created on
            -- demand by the settings page; absent = every raid counts.
            showOnlyMissing = false,
            width           = 165,
            rowHeight       = 17,
            showBackground  = true,
            showHeader      = true,
            durationStyle   = "bar",
            barMaxDuration  = 120,
            rangeCheck      = false,
            showBloodrage   = true,
            bloodrageStyle  = "both",
        }
        for k, v in pairs(defaults) do
            if db[k] == nil then db[k] = v end
        end
        -- One-time correction of an old default (300s) that no longer
        -- matches Battle Shout's actual duration.
        if db.barMaxDuration == 300 then db.barMaxDuration = 120 end
    end

    function RC:ShouldShowPartyTracker()
        if self._uiMoverActive then return true end
        if not PlayerIsWarrior() then return false end
        if not self.db.battleShoutPartyTracker or not self.db.battleShoutPartyTracker.enabled then
            return false
        end
        -- Same rule as the reminder: "Raids Only" = inside a raid instance,
        -- not merely in a raid group somewhere in the world; visibilityRaids
        -- narrows that to the ticked raids (nil/empty = every raid).
        local cfg = self.db.battleShoutPartyTracker
        local inRaidInstance = RC:IsInRaidInstance(cfg.visibilityRaids)
        local mode = cfg.visibilityMode or "raids"
        if mode == "raids"  then return inRaidInstance end
        if mode == "instances" then return RC:IsInDungeonOrRaid(cfg.visibilityRaids) end
        if mode == "group"  then return IsInGroup() end
        if mode == "always" then return IsInGroup() or inRaidInstance end
        if mode == "everywhere" then return true end
        return false
    end

    -- The tracker's fonts: rowFont (names and status; its size stays on
    -- the old fontSize key) and titleFont (its own size, else fontSize).
    RC.BATTLE_SHOUT_TRACKER_FONT = { size = 11, outline = "OUTLINE", shadow = true }

    -- Visual parts only (header, row pool): no position, mouse, handle or
    -- name, so the settings preview builds one on its canvas.
    function RC:BuildBattleShoutTracker(parent, name)
        local db = self.db.battleShoutPartyTracker
        local frame = CreateFrame("Frame", name, parent)
        frame:SetWidth(db.width or 165)
        frame:SetHeight(26)

        local bgTex = frame:CreateTexture(nil, "BACKGROUND")
        bgTex:SetAllPoints()
        frame.contentBg = bgTex

        if RC.UI and RC.UI.CreateSimpleBorder then
            frame.simpleBorder = RC.UI:CreateSimpleBorder(frame, 1)
        end

        local headerBar = CreateFrame("Frame", nil, frame)
        headerBar:SetHeight(22)
        headerBar:SetPoint("TOPLEFT",  frame, "TOPLEFT",  0, 0)
        headerBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)

        local hdrBg = headerBar:CreateTexture(nil, "BACKGROUND")
        hdrBg:SetAllPoints()
        hdrBg:SetTexture((RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8")
        headerBar.bg = hdrBg
        -- the same title bar every Readycheck window wears: gradient fill,
        -- accent rule (the fill sits over the tracker's own background)
        if RC.UI and RC.UI.ApplyHeaderArt then
            RC.UI:ApplyHeaderArt(headerBar, { fill = hdrBg, compact = true })
        else
            local hdrC = self:GetColor("battleShoutPartyTracker", "headerBackground")
            hdrBg:SetColorTexture(hdrC.r, hdrC.g, hdrC.b, 1)
        end

        local titleIcon = headerBar:CreateTexture(nil, "OVERLAY")
        titleIcon:SetSize(14, 14)
        titleIcon:SetPoint("LEFT", headerBar, "LEFT", 6, 1)
        titleIcon:SetTexture("Interface\\Icons\\Ability_Warrior_BattleShout")
        titleIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        -- template = a placeholder font until StyleBattleShoutTracker sets
        -- the real one (the client refuses SetText on a font-less string)
        local titleText = headerBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        titleText:SetPoint("LEFT",  titleIcon, "RIGHT",  5, 1)
        titleText:SetPoint("RIGHT", headerBar, "RIGHT", -38, 0)   -- room for the padlock + grip
        titleText:SetJustifyH("LEFT")
        titleText:SetWordWrap(false)
        titleText:SetText(RCL["Battle Shout"])
        headerBar.titleText = titleText
        headerBar.titleIcon = titleIcon

        frame.headerBar = headerBar
        frame._bsTo = function(k)
            if k == "frame" then return frame elseif k == "header" then return headerBar
            elseif k == "titleIcon" then return titleIcon elseif k == "title" then return titleText end
        end
        frame._bsTitleDef = {}
        frame._bsTitleIconDef = {}

        frame.rows = {}
        local rh = db.rowHeight or 17
        for i = 1, MAX_TRACKER_ROWS do
            local row = CreateFrame("Frame", nil, frame)
            row:SetHeight(rh)
            row:SetPoint("LEFT",  frame, "LEFT",   1, 0)
            row:SetPoint("RIGHT", frame, "RIGHT", -1, 0)

            local rowBg = row:CreateTexture(nil, "BACKGROUND")
            rowBg:SetAllPoints()
            row.rowBg = rowBg

            local bar = row:CreateTexture(nil, "BACKGROUND", nil, 2)
            bar:SetPoint("LEFT",   row, "LEFT",   0, 1)
            bar:SetPoint("TOP",    row, "TOP",    0, -1)
            bar:SetPoint("BOTTOM", row, "BOTTOM", 0, 1)
            bar:SetWidth(1)
            bar:Hide()
            row.durationBar = bar

            local nameText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            nameText:SetPoint("LEFT", row, "LEFT", 4, 0)
            nameText:SetWordWrap(false)
            nameText:SetJustifyH("LEFT")
            row.nameText = nameText

            local brIcon = row:CreateTexture(nil, "OVERLAY")
            brIcon:SetSize(12, 12)
            brIcon:SetPoint("LEFT", row, "LEFT", 3, 0)
            brIcon:SetTexture("Interface\\Icons\\Ability_Racial_BloodRage")
            brIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            brIcon:Hide()
            row.bloodrageIcon = brIcon

            local apText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            apText:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            apText:SetWidth(72)
            apText:SetJustifyH("RIGHT")
            apText:SetWordWrap(false)
            row.apText = apText

            nameText:SetPoint("RIGHT", apText, "LEFT", -4, 0)
            row._bsTo = function(k)
                if k == "row" then return row elseif k == "name" then return nameText
                elseif k == "status" then return apText elseif k == "icon" then return brIcon end
            end
            row._bsNameDef = {}
            if RC.UI and RC.UI.TagElement then
                RC.UI:TagElement(nameText, "rowName") RC.UI:TagElement(apText, "rowStatus")
                RC.UI:TagElement(brIcon, "rowIcon")
            end

            row:Hide()
            frame.rows[i] = row
        end
        self:StyleBattleShoutTracker(frame, db)
        return frame
    end

    -- Fonts and the static row/title colours; Layout does the rest.
    function RC:StyleBattleShoutTracker(frame, db)
        db = db or self.db.battleShoutPartyTracker
        local fsz = db.fontSize or 11
        local rowSpec = FontSpec(db, "rowFont", "fontSize")
        local tf = type(db.titleFont) == "table" and db.titleFont or {}
        local titleSpec = { face = tf.face, outline = tf.outline, shadow = tf.shadow, size = tf.size or fsz }
        local hb = frame.headerBar
        RC:ApplyFontSpec(hb.titleText, titleSpec, RC.BATTLE_SHOUT_TRACKER_FONT)
        if hb.titleIcon then
            Apply(hb.titleIcon, SpecOf(db, "titleIcon"), SetDef(frame._bsTitleIconDef or {}, "LEFT", hb, "LEFT", 6, 1), frame._bsTo)
            frame._bsTitleDef = frame._bsTitleDef or {}
            Apply(hb.titleText, SpecOf(db, "title"),
                SetDef(frame._bsTitleDef, "LEFT", hb.titleIcon, "RIGHT", 5, 1, nil, "RIGHT", hb, "RIGHT", -38, 0), frame._bsTo)
        end
        local tc = self:GetColor("battleShoutPartyTracker", "titleText")
        hb.titleText:SetTextColor(tc.r, tc.g, tc.b, tc.a)
        local rowC = self:GetColor("battleShoutPartyTracker", "rowBackground")
        local statusSpec, iconSpec = SpecOf(db, "rowStatus"), SpecOf(db, "rowIcon")
        for _, row in ipairs(frame.rows) do
            RC:ApplyFontSpec(row.nameText, rowSpec, RC.BATTLE_SHOUT_TRACKER_FONT)
            RC:ApplyFontSpec(row.apText, rowSpec, RC.BATTLE_SHOUT_TRACKER_FONT)
            if row._bsTo then
                Apply(row.apText, statusSpec, TR_STATUS_DEF, row._bsTo)
                Apply(row.bloodrageIcon, iconSpec, TR_ROWICON_DEF, row._bsTo)
            end
            row.rowBg:SetColorTexture(rowC.r, rowC.g, rowC.b, rowC.a)
        end
        frame._bsFont = fsz
        -- layer / clamp, fade rules, shadow / glow (the standard; its own
        -- scale stays its own)
        if self.ApplyFrameCustom then
            self:ApplyFrameCustom(frame, function() return RC.db and RC.db.battleShoutPartyTracker end,
                { scale = false, sample = (frame ~= (RC.battleShoutPartyTracker and RC.battleShoutPartyTracker.frame)) })
        end
    end

    function RC:CreateBattleShoutPartyTrackerFrame()
        if self.battleShoutPartyTracker.frame then return end
        local db = self.db.battleShoutPartyTracker

        local frame = self:BuildBattleShoutTracker(UIParent, "WRBattleShoutPartyTrackerFrame")
        frame:SetScale(tonumber(db.scale) or 1)      -- the saved spot is in the frame's units
        RC.Position.Bind(frame, function() return self.db.battleShoutPartyTracker end, {
            point = "TOPLEFT", legacyRel = "BOTTOMLEFT",
            default = { point = "TOPLEFT", relPoint = "BOTTOMLEFT", x = 300, y = 400 },
        })
        RC.Position.RestoreFrame(frame)

        frame:SetFrameStrata("MEDIUM")
        frame:SetFrameLevel(50)
        frame:SetClampedToScreen(true)
        frame:SetMovable(true)
        frame:EnableMouse(not db.locked)
        frame:RegisterForDrag("LeftButton")

        RC.Position.MakeMovable(frame, function() return not db.locked end)
        if RC.UI and RC.UI.AttachHudHandle then
            frame.handle = RC.UI:AttachHudHandle(frame, {
                getLocked = function() return db.locked ~= false end,
                setLocked = function(locked)
                    db.locked = locked
                    frame:EnableMouse(not locked)
                    RC:SaveConfigurationToProfile()
                end,
                inside = true, corner = "TOPRIGHT", insetX = 5, insetY = 5,
                getWidth = function() return db.width or 165 end,
                setWidth = function(w)
                    db.width = math.floor(w / 5 + 0.5) * 5   -- the settings slider's steps
                    RC:UpdateBattleShoutPartyTracker()
                end,
                onWidthEnd = function() RC:SaveConfigurationToProfile() end,
                minW = 120, maxW = 280,
            })
        end

        frame:Hide()
        self.battleShoutPartyTracker.frame = frame
        self:DebugPrint("BattleShoutPartyTracker frame created", "buff")
    end

    local function FormatDuration(secs)
        if secs <= 0 then return "0s" end
        local m = math.floor(secs / 60)
        local s = math.floor(secs % 60)
        if m > 0 then
            return string.format("%d:%02d", m, s)
        else
            return s .. "s"
        end
    end

    -- A fake party with every row state, for Edit Mode and the settings
    -- preview, so the tracker shows its real populated size.
    function RC:BattleShoutTrackerSampleRows(now, out)
        now = now or GetTime()
        local _, myClass = UnitClass("player")
        local r = out or {}
        local function Row(i, name, cls, has, rem, ap, below, oor, br)
            local t = r[i] or {}
            t.name, t.classToken, t.hasBuff, t.remaining, t.apValue = name, cls, has, rem, ap
            t.expirationTime = has and (now + rem) or 0
            t.peakMax, t.isLong, t.belowThreshold, t.outOfRange, t.hasBloodrage = 120, false, below, oor, br
            r[i] = t
        end
        Row(1, UnitName("player") or "You", myClass or "WARRIOR", true, 96, 290, false, false, true)
        Row(2, "Rowdy",  "WARRIOR", true,  61, 290, false, false, false)
        Row(3, "Stabbs", "ROGUE",   true,  14, 290, true,  false, false)
        Row(4, "Bonker", "WARRIOR", false, 0,  0,   false, false, false)
        Row(5, "Pewpew", "HUNTER",  false, 0,  0,   false, true,  false)
        for i = 6, #r do r[i] = nil end
        return r
    end

    function RC:UpdateBattleShoutPartyTracker()
        local frame = self.battleShoutPartyTracker.frame
        if not frame then return end

        if not self:ShouldShowPartyTracker() then
            RC.Motion.Stop(frame)
            frame._bsLeaving = nil
            frame:Hide()
            return
        end

        if RC.Profiler then RC.Profiler:StartTiming("BSTracker") end
        local db           = self.db.battleShoutPartyTracker
        local showMissing  = db.showOnlyMissing
        local threshold    = (self.db.battleShoutReminder and self.db.battleShoutReminder.buffThreshold) or 0
        local doRangeCheck = db.rangeCheck

        -- Same 5-man-only limitation as battleShoutReminder.partyUnits:
        -- in a raid, only your own subgroup is ever listed here.
        local units = {"player", "party1", "party2", "party3", "party4"}

        local rows = {}
        local trackBR = db.showBloodrage ~= false
        for _, unit in ipairs(units) do
            if UnitExists(unit) and UnitIsConnected(unit) and not UnitIsDeadOrGhost(unit) then
                local _, classToken = UnitClass(unit)
                if BATTLE_SHOUT_CLASSES[classToken] then
                    local hasBuff, remaining, apValue, expTime = self:UnitBattleShoutStatus(unit)
                    local belowThreshold = hasBuff and threshold > 0 and remaining <= threshold
                    local _inRng, _chkRng = UnitInRange(unit)
                    local outOfRange = doRangeCheck and unit ~= "player"
                                       and _chkRng and not _inRng

                    local hasBloodrage = false
                    if trackBR then
                        hasBloodrage = self:UnitHasBloodrage(unit)
                    end

                    local uName = UnitName(unit) or "?"
                    local pt = self.battleShoutPartyTracker.peakRemaining
                    if hasBuff then
                        if not pt[uName] or remaining > pt[uName] then
                            pt[uName] = remaining
                        end
                    else
                        pt[uName] = nil
                    end
                    local peakMax = pt[uName] or 120

                    if not showMissing or not hasBuff or belowThreshold then
                        local name = uName
                        -- a saved name format shortens at paint time instead
                        local fm = db.formats
                        if not (type(fm) == "table" and fm.name) and #name > 13 then name = name:sub(1, 12) .. "." end
                        rows[#rows+1] = {
                            name           = name,
                            classToken     = classToken,
                            hasBuff        = hasBuff,
                            remaining      = remaining,
                            apValue        = apValue,
                            expirationTime = expTime,
                            peakMax        = peakMax,
                            isLong         = hasBuff and remaining > 300,
                            belowThreshold = belowThreshold,
                            outOfRange     = outOfRange,
                            hasBloodrage   = hasBloodrage,
                        }
                    end
                end
            end
        end

        -- UI Mover preview: render a fake party so the tracker shows its
        -- real populated size and every row state while being positioned.
        if RC._uiMoverActive then
            rows = self:BattleShoutTrackerSampleRows(GetTime())
        end

        if #rows == 0 then
            self:HideBattleShoutTracker(frame)
            if RC.Profiler then RC.Profiler:StopTiming("BSTracker") end
            return
        end

        local sc = tonumber(db.scale) or 1
        if math.abs((frame:GetScale() or 1) - sc) > 0.001 and not RC.Motion.IsPlaying(frame) then
            if RC.Position.SetScaleKeepingPoint then RC.Position.SetScaleKeepingPoint(frame, sc, true)
            else frame:SetScale(sc) end
        end
        if frame.handle then frame.handle.Refresh() end

        self:LayoutBattleShoutTracker(frame, rows, db, self.battleShoutPartyTracker.barCache)

        if RC.Profiler then RC.Profiler:StopTiming("BSTracker") end
        if not frame:IsShown() or frame._bsLeaving then
            frame._bsLeaving = nil
            if not RC.Motion.Show(frame, db.showAnim or BS_NONE) then frame:Show() end
        end
    end

    function RC:HideBattleShoutTracker(frame)
        if not frame or not frame:IsShown() or frame._bsLeaving then return end
        frame._bsLeaving = true
        RC.Motion.Hide(frame, self.db.battleShoutPartyTracker.hideAnim or BS_NONE, function() frame._bsLeaving = nil end)
        if not frame:IsShown() then frame._bsLeaving = nil end
    end

    -- Paints rows onto a tracker frame: the live frame (cache = the bar
    -- ticker's barCache) and the preview sample (cache = nil) alike.
    function RC:LayoutBattleShoutTracker(frame, rows, db, cache)
        db = db or self.db.battleShoutPartyTracker
        local fontSize = db.fontSize or 11
        local width    = db.width or 165
        local showBg   = db.showBackground ~= false
        local showHdr  = db.showHeader ~= false
        local durStyle = db.durationStyle or "bar"
        local trackBR  = db.showBloodrage ~= false

        if frame._bsFont ~= fontSize then
            frame._bsFont = fontSize
            self:StyleBattleShoutTracker(frame, db)
        end

        for _, row in ipairs(frame.rows) do row:Hide() end

        local rowH    = db.rowHeight or 17
        local headerH = showHdr and 23 or 0
        local topPad  = 2
        local botPad  = 2
        -- the layout family (db.layout): order, most shown, direction,
        -- gaps. Without one the rows go exactly where they always did.
        local lay = type(db.layout) == "table" and db.layout or nil
        local nRows = #rows
        if lay and RC.UI.SortItems then
            RC.UI:SortItems(rows, lay, nil, ROW_SORTS)
            if lay.reverse then
                for i = 1, math.floor(nRows / 2) do rows[i], rows[nRows + 1 - i] = rows[nRows + 1 - i], rows[i] end
            end
            local mx = tonumber(lay.max)
            if mx and mx >= 1 and nRows > mx then nRows = mx end
        end
        if nRows > MAX_TRACKER_ROWS then nRows = MAX_TRACKER_ROWS end
        local totalH  = headerH + (#rows * rowH) + topPad + botPad
        local laySy, layPad = 0, 0
        if lay then
            laySy, layPad = tonumber(lay.spacingY) or 0, tonumber(lay.padding) or 0
            totalH = headerH + nRows * rowH + math.max(0, nRows - 1) * laySy + topPad + botPad + 2 * layPad
        end
        local fm = type(db.formats) == "table" and db.formats or nil
        local nameFmt, timeFmt = fm and fm.name, fm and fm.time
        local function Dur(secs)
            if timeFmt then return RC.UI:FormatTime(secs, timeFmt, RC.BATTLE_SHOUT_TIME_FORMAT) end
            return FormatDuration(secs)
        end

        frame:SetWidth(width)
        frame:SetHeight(totalH)

        local opacity = db.opacity or 0.85
        if frame.contentBg then
            local bgC = self:GetColor("battleShoutPartyTracker", "background")
            if showBg then
                frame.contentBg:SetColorTexture(bgC.r, bgC.g, bgC.b, bgC.a * opacity)
            else
                frame.contentBg:SetColorTexture(0, 0, 0, 0)
            end
        end

        if frame.simpleBorder then
            local borC = self:GetColor("battleShoutPartyTracker", "border")
            local ba = showBg and borC.a or 0
            local bs = tonumber(db.borderSize) or 1
            for side, tex in pairs(frame.simpleBorder) do
                tex:SetColorTexture(borC.r, borC.g, borC.b, bs > 0 and ba or 0)
                if bs > 0 then
                    if side == "top" or side == "bottom" then tex:SetHeight(bs) else tex:SetWidth(bs) end
                end
            end
        end

        if frame.headerBar then
            if showHdr then frame.headerBar:Show() else frame.headerBar:Hide() end
            local hb = frame.headerBar
            if hb.bg then hb.bg:SetShown(showBg) end
            if hb._art then hb._art.cutL:SetShown(showBg) hb._art.cutD:SetShown(showBg) end
        end

        local goodC    = self:GetColor("battleShoutPartyTracker", "apGood")
        local warnC    = self:GetColor("battleShoutPartyTracker", "apWarning")
        local missC    = self:GetColor("battleShoutPartyTracker", "apMissing")
        local brC      = self:GetColor("battleShoutPartyTracker", "bloodrageActive")
        local brStyle  = db.bloodrageStyle or "both"
        local brShowIcon  = trackBR and (brStyle == "icon"  or brStyle == "both")
        local brShowColor = trackBR and (brStyle == "color" or brStyle == "both")
        local barPx = math.max(1, width - 2)
        local barA = tonumber(db.barAlpha) or 0.45

        for i, data in ipairs(rows) do
            if i > (lay and nRows or MAX_TRACKER_ROWS) then break end
            local row = frame.rows[i]
            row:ClearAllPoints()
            if lay then
                -- grows down from under the header, or up from the bottom
                local up = lay.grow == "UP"
                local step = (i - 1) * (rowH + laySy) + layPad
                if up then
                    row:SetPoint("BOTTOMLEFT",  frame, "BOTTOMLEFT",   1 + layPad, botPad + step)
                    row:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1 - layPad, botPad + step)
                else
                    local yOff = -(headerH + topPad + step)
                    row:SetPoint("TOPLEFT",  frame, "TOPLEFT",   1 + layPad, yOff)
                    row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1 - layPad, yOff)
                end
            else
                local yOff = -(headerH + topPad + (i-1)*rowH)
                row:SetPoint("TOPLEFT",  frame, "TOPLEFT",   1, yOff)
                row:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, yOff)
            end
            row:SetHeight(rowH)
            row:Show()

            local showBR = data.hasBloodrage and brShowIcon
            if row.bloodrageIcon then
                local nd = row._bsNameDef or {}
                if showBR then
                    local iconSize = math.max(8, math.min(14, rowH - 4))
                    row.bloodrageIcon:SetSize(iconSize, iconSize)
                    row.bloodrageIcon:Show()
                    SetDef(nd, "LEFT", row.bloodrageIcon, "RIGHT", 3, 0, nil, "RIGHT", row.apText, "LEFT", -4, 0)
                else
                    row.bloodrageIcon:Hide()
                    SetDef(nd, "LEFT", row, "LEFT", 4, 0, nil, "RIGHT", row.apText, "LEFT", -4, 0)
                end
                Apply(row.nameText, SpecOf(db, "rowName"), nd, row._bsTo)
            end

            local defC = self:GetColor("text", "normal")
            local nr, ng, nb = defC.r, defC.g, defC.b
            if data.hasBloodrage and brShowColor then
                nr, ng, nb = brC.r, brC.g, brC.b
            else
                local cc = RAID_CLASS_COLORS and RAID_CLASS_COLORS[data.classToken]
                if cc then nr, ng, nb = cc.r, cc.g, cc.b end
            end
            local nm = data.name
            if nameFmt then nm = RC.UI:FormatName(nm, nameFmt, RC.BATTLE_SHOUT_NAME_FORMAT) end
            row.nameText:SetText(nm)
            row.nameText:SetTextColor(nr, ng, nb, 1)

            local col
            if not data.hasBuff then
                col = data.outOfRange and warnC or missC
            elseif data.belowThreshold then
                col = warnC
            else
                col = goodC
            end

            local apStr = ""
            if not data.hasBuff then
                apStr = data.outOfRange and "OOR" or "MISSING"
            else
                local apPart  = data.apValue > 0 and (data.apValue .. " AP") or ""
                local timPart = (durStyle == "timer" or durStyle == "both") and Dur(data.remaining) or ""
                if durStyle == "timer" then
                    apStr = apPart ~= "" and apPart or timPart
                elseif durStyle == "both" then
                    if apPart ~= "" and timPart ~= "" then
                        apStr = apPart .. "  " .. timPart
                    else
                        apStr = apPart ~= "" and apPart or timPart
                    end
                else
                    apStr = apPart ~= "" and apPart or Dur(data.remaining)
                end
            end
            row.apText:SetText(apStr)
            row.apText:SetTextColor(col.r, col.g, col.b, col.a)

            local showBar = (durStyle == "bar" or durStyle == "both") and data.hasBuff
            local effectiveMax = math.max(1, data.peakMax or 120)
            if showBar then
                local frac = math.min(1, math.max(0, data.remaining / effectiveMax))
                local barW = math.max(1, math.floor(frac * barPx))
                row.durationBar:ClearAllPoints()
                row.durationBar:SetPoint("LEFT",   row, "LEFT",   0, 0)
                row.durationBar:SetPoint("TOP",    row, "TOP",    0, 0)
                row.durationBar:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
                row.durationBar:SetWidth(barW)
                -- one flat fill, painted the same way by this scan and by
                -- the 4x/sec bar ticker below: the scan used the bar
                -- texture (darker) and the ticker a flat colour (brighter),
                -- so the bar flickered between the two every 1.5s
                row.durationBar:SetColorTexture(col.r, col.g, col.b, barA)
                row.durationBar:Show()
            else
                row.durationBar:Hide()
            end

            if cache then
                cache[i] = {
                    hasBuff        = data.hasBuff,
                    expirationTime = data.expirationTime,
                    peakMax        = effectiveMax,
                    showBar        = showBar,
                    cr = col.r, cg = col.g, cb = col.b,
                }
            end
        end

        if cache then
            local painted = lay and nRows or #rows
            for j = painted + 1, #rows + 6 do cache[j] = nil end
        end
    end

    function RC:StartBattleShoutPartyTrackerUpdates()
        if self.battleShoutPartyTracker.ticker then
            self.battleShoutPartyTracker.ticker:Cancel()
            self.battleShoutPartyTracker.ticker = nil
        end
        if self.battleShoutPartyTracker.barTicker then
            self.battleShoutPartyTracker.barTicker:Cancel()
            self.battleShoutPartyTracker.barTicker = nil
        end
        if not self:ShouldShowPartyTracker() then return end

        local scanFn = function()
            if not self:ShouldShowPartyTracker() then
                self:StopBattleShoutPartyTrackerUpdates()
                return
            end
            self:UpdateBattleShoutPartyTracker()
        end
        if RC.Profiler and RC.Profiler.TrackTicker then
            self.battleShoutPartyTracker.ticker = RC.Profiler:TrackTicker("BattleShout:PartyTrackerScan", 1.5, scanFn)
        else
            self.battleShoutPartyTracker.ticker = C_Timer.NewTicker(1.5, scanFn)
        end

        -- Runs 4x/sec but only recomputes bar width from barCache's
        -- already-scanned expirationTime - no aura/bag scan runs here.
        local barTickerFn = function()
            local frame = RC.battleShoutPartyTracker.frame
            if not frame or not frame:IsShown() then return end
            local cache = RC.battleShoutPartyTracker.barCache
            if not cache or #cache == 0 then return end
            local db = RC.db.battleShoutPartyTracker
            local durStyle = db.durationStyle or "bar"
            if durStyle ~= "bar" and durStyle ~= "both" then return end
            local barPx2 = (db.width or 165) - 2
            local now = GetTime()
            for i, entry in ipairs(cache) do
                local row = frame.rows[i]
                if row and row:IsShown() and row.durationBar and entry.showBar then
                    if entry.hasBuff and entry.expirationTime and entry.expirationTime > 0 then
                        local rem = math.max(0, entry.expirationTime - now)
                        local frac = math.min(1, math.max(0, rem / entry.peakMax))
                        local bw = math.max(1, math.floor(frac * barPx2))
                        row.durationBar:SetWidth(bw)
                        row.durationBar:Show()
                    else
                        row.durationBar:Hide()
                    end
                end
            end
        end

        if RC.Profiler and RC.Profiler.TrackTicker then
            self.battleShoutPartyTracker.barTicker =
                RC.Profiler:TrackTicker("BattleShout:PartyBars", 0.25, barTickerFn)
        else
            self.battleShoutPartyTracker.barTicker = C_Timer.NewTicker(0.25, barTickerFn)
        end

        self:UpdateBattleShoutPartyTracker()
        self:DebugPrint("BattleShoutPartyTracker started", "buff")
    end

    function RC:StopBattleShoutPartyTrackerUpdates()
        if self.battleShoutPartyTracker.ticker then
            self.battleShoutPartyTracker.ticker:Cancel()
            self.battleShoutPartyTracker.ticker = nil
        end
        if self.battleShoutPartyTracker.barTicker then
            self.battleShoutPartyTracker.barTicker:Cancel()
            self.battleShoutPartyTracker.barTicker = nil
        end
        local tf = self.battleShoutPartyTracker.frame
        if tf then
            RC.Motion.Stop(tf)
            tf._bsLeaving = nil
            tf:Hide()
        end
        self:DebugPrint("BattleShoutPartyTracker stopped", "buff")
    end

    RC:CreateBattleShoutReminderFrame()

    RC:ApplyBattleShoutLockState()

    if RC.db.battleShoutReminder.enabled then
        C_Timer.After(1, function()
            RC:StartBattleShoutReminderUpdates()
        end)
    end

    RC:InitializeBattleShoutPartyTrackerDB()
    RC:CreateBattleShoutPartyTrackerFrame()
    if RC.db.battleShoutPartyTracker and RC.db.battleShoutPartyTracker.enabled then
        C_Timer.After(1.2, function()
            RC:StartBattleShoutPartyTrackerUpdates()
        end)
    end

    RC:DebugPrint("BattleShoutReminder module loaded", "system")
end

C_Timer.After(0.5, InitializeBattleShoutReminder)
