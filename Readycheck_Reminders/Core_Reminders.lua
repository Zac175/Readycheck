------------------------------------------------------------------------
-- Readycheck - Reminder Popup Build/Show/Dismiss
-- Owns RC:ShowReminder (the main entry point that filters an ability
-- list down to what's actually usable, builds/reuses icon frames, and
-- fires sound/TTS), plus fade in/out, forced test-mode display, and
-- per-ability cooldown re-trigger monitoring.
-- Ability keys "boon", "frostBlast", "frostBlastBuff_*", "equipReminder",
-- "preTargetConsumable" are persistent markers, not real abilities - the
-- same bypass list is checked in IsAbilityReady (Core_Events.lua) and
-- here; keep both in sync if it changes.
------------------------------------------------------------------------
local CP = Readycheck.Compat
local GetSpellTexture = GetSpellTexture or CP.GetSpellTexture
local GetItemInfo = GetItemInfo or CP.GetItemInfo

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local GetTime, UnitName, UnitGUID = GetTime, UnitName, UnitGUID
local UnitExists = UnitExists
local UnitAffectingCombat = UnitAffectingCombat
local CreateFrame, UIParent = CreateFrame, UIParent
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
local _cor = RC._cor
local COLORS, ResolveSpeakName, TTSSuppressed, TTSMarkFired, ResetTTSState, _chainLastStart = _cor.COLORS, _cor.ResolveSpeakName, _cor.TTSSuppressed, _cor.TTSMarkFired, _cor.ResetTTSState, _cor._chainLastStart

-- Display-order sort priority for ShowReminder (lower shows first).
local SORT_PRIORITY = {
    deathwish = 1, recklessness = 2, bloodrage = 3,
    berserkerrage = 4, laststand = 5, shieldwall = 6,
    trinket1 = 100, trinket2 = 101,
}
local function GetSortPriority(ability)
    local p = SORT_PRIORITY[ability]
    if p then return p end
    if tonumber(ability) ~= nil then return 200 end
    if type(ability) == "string" and ability:find("Potion") then return 300 end
    return 999
end

-- Shared icon-frame constructor for ShowReminder/ShowReminderForced:
-- builds the bg/texture/cooldownText children for one icon slot and
-- hands the frame to RC.UI:DressReadyIcon for the ring, plate and halo
-- (the same dress on both paths, so the test popup is what you get).
-- icon.border is kept as an alias of the ring for older callers.
local function BuildAbilityIconFrame(self, frame, iconSize)
    local icon = CreateFrame("Frame", nil, frame)
    icon:SetSize(iconSize, iconSize)
    icon.originalSize = iconSize

    icon.bg = icon:CreateTexture(nil, "BACKGROUND")
    icon.bg:SetAllPoints()
    icon.bg:SetColorTexture(COLORS.windowBg[1], COLORS.windowBg[2], COLORS.windowBg[3], 0.9)

    icon.texture = icon:CreateTexture(nil, "ARTWORK")
    icon.texture:SetAllPoints()
    icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon.texture:SetDrawLayer("ARTWORK", 0)

    if self.UI and self.UI.DressReadyIcon then
        self.UI:DressReadyIcon(icon, iconSize)
        icon.border = icon.ring
    end

    if self.db.showIconText then
        self:EnsureReminderIconText(icon)
    end

    return icon
end

-- The icon label's font: db.reminderText.font over Readycheck's font at
-- 12 with an outline and a 1,-1 shadow (what it has always been).
local LABEL_FONT_DEFAULTS = { size = 12, outline = "OUTLINE", shadow = true }
RC.REMINDER_LABEL_FONT_DEFAULTS = LABEL_FONT_DEFAULTS

------------------------------------------------------------------------
-- The customization standard on the popup (RC.db.reminderPopup, nil
-- fields = exactly what the popup always did):
--   anchors.label   the icon's text   (centred on the icon's bottom edge)
--   anchors.glow    the halo           (centred on the icon)
--   layout          how the icons line up (a centred row, iconSpacing apart)
--   states.ready / .alert / .remove   per label state: text colour, glow
--                   colour, grey, opacity, an animation when it starts
--   formats.label   the text: case, longest, before / after it
------------------------------------------------------------------------
local EMPTY_SPEC = setmetatable({}, { __newindex = function() end })
RC.REMINDER_LABEL_ANCHOR = { point = "CENTER", relPoint = "BOTTOM", x = 0, y = 1, justify = "CENTER" }
RC.REMINDER_GLOW_ANCHOR  = { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
-- the label's colour key -> its state
RC.REMINDER_STATE_OF = { green = "ready", gold = "alert", orange = "remove" }
-- what a state looks like when nothing is picked (the icon as it always is)
RC.REMINDER_STATE_DEFAULTS = {
    ready = { desat = false, alpha = 1 }, alert = { desat = false, alpha = 1 }, remove = { desat = false, alpha = 1 },
}
RC.REMINDER_ICON_TARGETS = {
    { value = "icon", text = RCL["The icon"] }, { value = "popup", text = RCL["The popup"] },
    { value = "label", text = RCL["Icon text"] }, { value = "glow", text = RCL["Glow"] },
}

function RC:ReminderPopupSpec()
    local p = self.db and self.db.reminderPopup
    return type(p) == "table" and p or EMPTY_SPEC
end

local function PopupPart(family, key)
    local p = RC:ReminderPopupSpec()
    local t = p[family]
    if type(t) ~= "table" then return nil end
    if key then return t[key] end
    return t
end
RC.ReminderPopupPart = function(_, family, key) return PopupPart(family, key) end

-- what an icon's element keys hang off (one closure per icon, made once)
local function IconTo(icon)
    if not icon._rpTo then
        icon._rpTo = function(k)
            if k == "icon" then return icon
            elseif k == "popup" then return icon:GetParent()
            elseif k == "label" then return icon.cooldownText
            elseif k == "glow" then return icon.halo end
        end
    end
    return icon._rpTo
end

-- The label and the halo where the settings put them (default: where
-- they always were).
function RC:PlaceReminderIconText(icon)
    local t = icon and icon.cooldownText
    if not t then return end
    if self.UI and self.UI.ApplyAnchor then
        self.UI:ApplyAnchor(t, PopupPart("anchors", "label"), RC.REMINDER_LABEL_ANCHOR, IconTo(icon))
    else
        t:ClearAllPoints()
        t:SetPoint("CENTER", icon, "BOTTOM", 0, 1)
        t:SetJustifyH("CENTER")
    end
end
function RC:PlaceReminderIconGlow(icon)
    if not (icon and icon.halo) then return end
    local spec = PopupPart("anchors", "glow")
    if spec == nil and not icon._rpGlowMoved then return end
    icon._rpGlowMoved = spec ~= nil
    if self.UI and self.UI.ApplyAnchor then
        self.UI:ApplyAnchor(icon.halo, spec, RC.REMINDER_GLOW_ANCHOR, IconTo(icon))
    end
end

-- Where each of n icons sits: the centred row the popup has always drawn
-- or, with a layout set, RC.UI:LayoutItems inside `edge` px of the
-- container. Fills out[i] = { point =, x =, y = } (reused tables; point
-- nil = past the most shown) and returns the icon block's width, height.
local slotProxy = {}
local function Proxy(i, size)
    local p = slotProxy[i]
    if not p then
        p = { ClearAllPoints = function(self) self.point = nil end,
              SetPoint = function(self, pt, _, _, x, y) self.point, self.x, self.y = pt, x, y end,
              GetWidth = function(self) return self.w end, GetHeight = function(self) return self.w end,
              SetSize = function() end, SetHeight = function() end, Show = function() end }
        slotProxy[i] = p
    end
    p.w, p.point = size, nil
    return p
end
function RC:ReminderIconSlots(n, size, spacing, edge, out)
    local spec = PopupPart("layout")
    if not spec then
        for i = 1, n do
            local o = out[i] or {}
            out[i] = o
            o.point, o.x, o.y = "CENTER", (i - 1 - (n - 1) / 2) * (size + spacing), 0
        end
        return (n * size) + ((n - 1) * spacing), size
    end
    local list = {}
    for i = 1, n do list[i] = Proxy(i, size) end
    local w, h = self.UI:LayoutItems(list, n, nil, spec, self:ReminderLayoutDefaults(spacing),
        { left = edge, right = edge, top = edge, bottom = edge })
    for i = 1, n do
        local o = out[i] or {}
        out[i] = o
        o.point, o.x, o.y = list[i].point, list[i].x, list[i].y
    end
    return w, h
end
function RC:ReminderLayoutDefaults(spacing)
    local d = self._rpLayoutDef or {}
    self._rpLayoutDef = d
    local sp = spacing or (self.db and self.db.iconSpacing) or 5
    d.grow, d.spacingX, d.spacingY, d.padding = "CENTER", sp, sp, 0
    return d
end
-- the popup's icons placed from their slots
local popupSlots = {}
local function PlaceIcons(frame, icons, n, size, spacing)
    local w, h = RC:ReminderIconSlots(n, size, spacing, 20, popupSlots)
    for i = 1, n do
        local icon, o = icons[i], popupSlots[i]
        if icon then
            icon:ClearAllPoints()
            if o.point then
                icon:SetPoint(o.point, frame, o.point, o.x, o.y)
            else
                icon:SetPoint("CENTER", frame, "CENTER", 0, 0)
                icon:Hide()
            end
        end
    end
    return w, h
end

-- The label's state look (states.<ready|alert|remove>) and its text
-- format, only once something is set.
local labelValues, labelKinds = {}, { value = "name" }
local function LabelText(text)
    local f = PopupPart("formats", "label")
    if not f then return text end
    labelValues.value = text
    return RC.UI:FormatText(f, nil, labelValues, labelKinds, "value")
end
local function ApplyLabelState(icon, colorKey)
    local states = PopupPart("states")
    if not (states or icon._rpStated) then return end
    icon._rpStated = states ~= nil
    local parts = icon._rpParts
    if not parts then
        parts = { text = icon.cooldownText, icon = icon.texture, frame = icon,
            glow = function(on, r, g, b, a)
                if not icon.halo then return end
                if on then icon.halo:SetVertexColor(r, g, b, a or 1)
                elseif RC.UI.RepaintReadyIcon then RC.UI:RepaintReadyIcon(icon) end
            end }
        icon._rpParts = parts
    end
    parts.text = icon.cooldownText
    local state = RC.REMINDER_STATE_OF[colorKey] or "ready"
    RC.UI:ApplyState(states, state, RC.REMINDER_STATE_DEFAULTS, parts)
    -- the opacity the show path's failsafes put back (1 unless a state says)
    icon._rpAlpha = states and tonumber(RC.UI:StateValue(states, state, "alpha", RC.REMINDER_STATE_DEFAULTS)) or nil
end

-- An icon without its text still wears its state's look (the state is
-- the one its text would have).
local function StateColorFor(ability)
    if ability == "boon" then return "gold" end
    if ability == "frostBlast" or (type(ability) == "string" and ability:find("^frostBlastBuff_")) then return "orange" end
    if type(ability) == "string" and ability:find("^custom_") then return "gold" end
    if RC.pendingTextOverrides and RC.pendingTextOverrides[ability] then return "gold" end
    return "green"
end
function RC:ApplyReminderIconState(icon, colorKey)
    if icon then ApplyLabelState(icon, colorKey) end
end

-- The label sits on the icon's bottom edge, centred on the ring, drawn
-- above it. Made once per icon; restyled from the settings every call.
function RC:EnsureReminderIconText(icon)
    if not icon then return nil end
    if not icon.cooldownText then
        local t = self:CreateFontString(icon, "OVERLAY", nil, 12)
        t:SetPoint("CENTER", icon, "BOTTOM", 0, 1)
        t:SetWidth(icon.originalSize or icon:GetWidth() or 40)
        t:SetJustifyH("CENTER")
        t:SetDrawLayer("OVERLAY", 2)
        local cWhite = self:GetColor("text", "white")
        t:SetTextColor(cWhite.r, cWhite.g, cWhite.b, cWhite.a or 1)
        icon.cooldownText = t
    end
    local rt = self.db and self.db.reminderText
    self:ApplyFontSpec(icon.cooldownText, type(rt) == "table" and rt.font or nil, LABEL_FONT_DEFAULTS)
    self:PlaceReminderIconText(icon)
    return icon.cooldownText
end

-- Text and colour: db.reminderText.color when set, else the state colour
-- (text.<colorKey>: green ready, gold boon/custom, orange remove).
function RC:SetReminderIconLabel(icon, text, colorKey)
    local t = icon and icon.cooldownText
    if not t then return end
    icon._rcLabelRaw = text
    t:SetText(LabelText(text))
    icon._rcLabelColorKey = colorKey
    local rt = self.db and self.db.reminderText
    local c = (type(rt) == "table" and type(rt.color) == "table" and rt.color) or self:GetColor("text", colorKey)
    t:SetTextColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
    ApplyLabelState(icon, colorKey)
end

-- The boon icon's label: db.boonReminder.label (Chronoboon page > Text),
-- else "unboon" as it has always read.
function RC:GetBoonLabel()
    local b = self.db and self.db.boonReminder
    local t = b and b.label
    if type(t) == "string" and t ~= "" then return t end
    return RCL["unboon"]
end

-- Re-reads the label font and colour onto the icons already up (a
-- settings change while a reminder is showing).
function RC:RestyleReminderIconLabels()
    local f = self.reminderFrame
    if not (f and f.abilityIcons) then return end
    for _, icon in pairs(f.abilityIcons) do
        if icon.cooldownText then
            self:EnsureReminderIconText(icon)
            if icon._rcLabelColorKey then
                self:SetReminderIconLabel(icon, icon._rcLabelRaw or icon.cooldownText:GetText() or "", icon._rcLabelColorKey)
            end
        end
    end
end

-- After a popup setting changed (layout, a part's place, a state, the text
-- format): the popup up on screen follows at once.
function RC:RefreshReminderPopupLook()
    local f = self.reminderFrame
    if not (f and f.abilityIcons) then return end
    self:RestyleReminderIconLabels()
    if self.ApplyFrameCustom and f:IsShown() then
        self:ApplyFrameCustom(f, function() return RC.db and RC.db.reminderPopup end)
    end
    local n = f._rpCount or 0
    if n <= 0 or not f:IsShown() then return end
    local size = self.db.iconSize or 80
    local w, h = PlaceIcons(f, f.abilityIcons, n, size, self.db.iconSpacing or 5)
    if not (RC.Motion and RC.Motion.IsPlaying(f)) then
        f:SetSize(w + 40, h + 40)
        RC.Position.RestoreFrame(f)
    end
    for i = 1, n do
        local icon = f.abilityIcons[i]
        if icon then self:PlaceReminderIconGlow(icon) end
    end
end

-- One popup icon exactly as the popup builds it, for a preview to show.
function RC:CreateReminderIcon(parent, size)
    return BuildAbilityIconFrame(self, parent, size)
end
function RC:ShowReminder(message, abilities, duration, bypassFilter)
    self:DebugPrint("ShowReminder: self.db = " .. tostring(self.db ~= nil), "reminder")
    if self.db then
        self:DebugPrint("ShowReminder: self.db.enabled = " .. tostring(self.db.enabled), "reminder")
        self:DebugPrint("ShowReminder: showInCombatOnly = " .. tostring(self.db.showInCombatOnly), "reminder")
        self:DebugPrint("ShowReminder: inCombat = " .. tostring(self.inCombat), "reminder")
        self:DebugPrint("ShowReminder: UnitAffectingCombat = " .. tostring(UnitAffectingCombat("player")), "reminder")
    end

    if not self.db.enabled then
        self:DebugPrint("ShowReminder blocked: addon disabled", "reminder")
        return
    end

    local _isPersistent = false
    for _, a in ipairs(abilities) do
        if a == "boon" or a == "frostBlast" or a == "equipReminder" or a == "preTargetConsumable"
            or (type(a) == "string" and a:find("^frostBlastBuff_")) then
            _isPersistent = true; break
        end
    end

    if self.db.showInCombatOnly and not _isPersistent and not self.inCombat and not UnitAffectingCombat("player") then
        self:DebugPrint("Combat-only mode enabled, not in combat - skipping reminder", "reminder")
        return
    elseif not self.db.showInCombatOnly then
        self:DebugPrint("Combat-only mode disabled - showing reminder regardless of combat state", "reminder")
    end

    -- "gearswap" triggers a gear change elsewhere but has no icon of its
    -- own; strip it here so it never shows and never counts toward
    -- "are there any abilities to display".
    local filteredAbilities = {}
    for _, ability in ipairs(abilities) do
        if ability ~= "gearswap" then
            table.insert(filteredAbilities, ability)
        end
    end

    if #filteredAbilities == 0 then
        self:DebugPrint("Only gearswap in abilities list - skipping reminder display", "reminder")
        return
    end

    abilities = filteredAbilities

    local hasFrostBlast = false
    for _, a in ipairs(abilities) do if a == "frostBlast" then hasFrostBlast = true; break end end
    -- Frost Blast replaces the caller's message/abilities/duration outright
    -- rather than merging with them - anything the caller passed for these
    -- is discarded once "frostBlast" is present in the ability list.
    if hasFrostBlast and self.BuildFrostBlastReminderAbilities then
        local fbAbilities, fbMsg = self:BuildFrostBlastReminderAbilities()
        message  = fbMsg
        abilities = fbAbilities
        duration = 0
    end

    local hasPersistentAbility = false
    for _, a in ipairs(abilities) do
        if a == "boon" or a == "frostBlast" or (type(a) == "string" and a:find("^frostBlastBuff_")) then
            hasPersistentAbility = true; break
        end
    end

    local frame = self.reminderFrame
    if not frame then
        self:CreateReminderFrame()
        frame = self.reminderFrame
        if not frame then
            self:DebugPrint("ShowReminder blocked: could not create reminder frame", "reminder")
            return
        end
        self:DebugPrint("ShowReminder: Created reminder frame on-demand", "reminder")
    end

    local isInSimulation = (self.activeSimulation ~= nil)
    local usableAbilities = {}

    if bypassFilter then
        for _, ability in ipairs(abilities) do
            local alreadyAdded = false
            for _, existingAbility in ipairs(usableAbilities) do
                if existingAbility == ability then
                    alreadyAdded = true
                    break
                end
            end
            if not alreadyAdded then
                table.insert(usableAbilities, ability)
            end
        end
        self:DebugPrint("ShowReminder: bypassFilter=true, forcing " .. #usableAbilities .. " abilities", "reminder")
    else
    for _, ability in ipairs(abilities) do
        local shouldInclude = false
        local graceTime = nil

        if ability == "trinket1" then
            if isInSimulation then
                shouldInclude = true
                self:DebugPrint("ShowReminder: trinket1 included (simulation mode)", "reminder")
            else
                local hasOnUse = self.trinketData.slot1.hasOnUse
                if not hasOnUse then
                    hasOnUse = self:IsTrinketSlotOnUse(1)
                    if hasOnUse then
                        self:DebugPrint("ShowReminder: trinket1 hasOnUse=false in cache, but direct check=true", "reminder")
                        self.trinketData.slot1.hasOnUse = true
                    end
                end

                if hasOnUse then
                    local ready, grace = self:IsAbilityReady("trinket1", true)
                    if ready then
                        shouldInclude = true
                        graceTime = grace
                        self:DebugPrint("ShowReminder: trinket1 included (on-use and ready)", "reminder")
                    else
                        self:DebugPrint("ShowReminder: trinket1 not ready", "reminder")
                    end
                else
                    self:DebugPrint("ShowReminder: trinket1 filtered - no on-use effect", "reminder")
                end
            end
        elseif ability == "trinket2" then
            if isInSimulation then
                shouldInclude = true
                self:DebugPrint("ShowReminder: trinket2 included (simulation mode)", "reminder")
            else
                local hasOnUse = self.trinketData.slot2.hasOnUse
                if not hasOnUse then
                    hasOnUse = self:IsTrinketSlotOnUse(2)
                    if hasOnUse then
                        self:DebugPrint("ShowReminder: trinket2 hasOnUse=false in cache, but direct check=true", "reminder")
                        self.trinketData.slot2.hasOnUse = true
                    end
                end

                if hasOnUse then
                    local ready, grace = self:IsAbilityReady("trinket2", true)
                    if ready then
                        shouldInclude = true
                        graceTime = grace
                        self:DebugPrint("ShowReminder: trinket2 included (on-use and ready)", "reminder")
                    else
                        self:DebugPrint("ShowReminder: trinket2 not ready", "reminder")
                    end
                else
                    self:DebugPrint("ShowReminder: trinket2 filtered - no on-use effect", "reminder")
                end
            end
        else
            local ready, grace = self:IsAbilityReady(ability, true)
            if ready then
                shouldInclude = true
                graceTime = grace
            end
        end

        if shouldInclude then
            local alreadyAdded = false
            for _, existingAbility in ipairs(usableAbilities) do
                if existingAbility == ability then
                    alreadyAdded = true
                    break
                end
            end
            if not alreadyAdded then
                table.insert(usableAbilities, ability)
                if graceTime then
                    self:DebugPrint("Including " .. ability .. " (grace period: " .. math.ceil(graceTime) .. "s)", "grace")
                end
            else
                self:DebugPrint("Skipping duplicate: " .. ability, "reminder")
            end
        else
            local reason = "on cooldown or not ready"
            if ability == "trinket1" and not self.trinketData.slot1.hasOnUse then
                reason = "no on-use effect"
            elseif ability == "trinket2" and not self.trinketData.slot2.hasOnUse then
                reason = "no on-use effect"
            end
            self:DebugPrint("Filtered out " .. ability .. ": " .. reason, "reminder", 2)
        end
    end
    end

    if #usableAbilities == 0 then
        self:DebugPrint("No ready abilities to show reminder for", "reminder")
        return
    end

    table.sort(usableAbilities, function(a, b)
        return GetSortPriority(a) < GetSortPriority(b)
    end)

    local prevAbilities = self.activeReminderData.abilities or {}
    local prevHadBoon = false
    for _, k in ipairs(prevAbilities) do
        if k == "boon" then prevHadBoon = true; break end
    end
    if prevHadBoon and RC.boonReminder and RC.boonReminder.hasBoon then
        local alreadyIn = false
        for _, k in ipairs(usableAbilities) do
            if k == "boon" then alreadyIn = true; break end
        end
        if not alreadyIn then
            table.insert(usableAbilities, "boon")
        end
    end

    -- Re-reads activeReminderData.abilities (shadowing the prevAbilities
    -- above) because the boon re-insertion just above can have changed it;
    -- this comparison needs the post-boon list, not the pre-boon one.
    local prevAbilities = self.activeReminderData.abilities or {}
    if #prevAbilities == #usableAbilities and #usableAbilities > 0 then
        local same = true
        for i, a in ipairs(usableAbilities) do
            if prevAbilities[i] ~= a then same = false; break end
        end
        if same then
            self:DebugPrint("ShowReminder: same abilities, skipping rebuild", "reminder")
            return
        end
    end

    self:ForceResetReminderFrame()
    self.activeReminderData.reminderID = (self.activeReminderData.reminderID or 0) + 1
    local currentReminderID = self.activeReminderData.reminderID
    self:DebugPrint("ShowReminder called - Reminder ID: " .. currentReminderID, "reminder")
    if self.activeReminderData.dismissalTimer then
        self.activeReminderData.dismissalTimer:Cancel()
        self.activeReminderData.dismissalTimer = nil
    end

    frame.currentAbilities = usableAbilities
    frame.isTestMode = (message and message:find("TEST"))
    frame.isSimulation = (self.activeSimulation ~= nil)

    local isFromCombat = not frame.isTestMode and not frame.isSimulation and (self.inCombat or UnitAffectingCombat("player"))

    local wasFrameHidden = not self.reminderFrame:IsShown()
    local hadNoAbilities = (#self.activeReminderData.abilities == 0)
    local currentSessionID = self.activeReminderData.popupSessionID

    local isNewPopupSession = wasFrameHidden or hadNoAbilities

    if isNewPopupSession then
        ResetTTSState(self.activeReminderData)
        self.activeReminderData.popupSessionID = (currentSessionID or 0) + 1

        local reason = wasFrameHidden and "frame was hidden" or "no tracked abilities"
        self:DebugPrint("NEW POPUP SESSION #" .. self.activeReminderData.popupSessionID .. " (" .. reason .. ") - TTS state reset", "reminder")
    else
        self:DebugPrint("SAME POPUP SESSION #" .. (self.activeReminderData.popupSessionID or 0) .. " - TTS preserved (played: " .. (self.activeReminderData.ttsPlayed and "YES" or "NO") .. ")", "reminder")
    end

    self.activeReminderData.abilities = {}
    for _, ability in ipairs(usableAbilities) do
        table.insert(self.activeReminderData.abilities, ability)
    end
    self.activeReminderData.showTime = GetTime()

    if frame.abilityIcons then
        for _, icon in pairs(frame.abilityIcons) do
            icon:Hide()
            if icon.pulseTimer then
                icon.pulseTimer:Cancel()
                icon.pulseTimer = nil
            end
            if icon.animationTimer then
                icon.animationTimer:Cancel()
                icon.animationTimer = nil
            end
        end
    else
        frame.abilityIcons = {}
    end

    local iconSize = self.db.iconSize or 80
    local actualSpacing = self.db.iconSpacing or 5
    local numIcons = #usableAbilities
    local step = iconSize + actualSpacing

    -- the icon block: a centred row, or the layout set on Position
    local blockW, blockH = self:ReminderIconSlots(numIcons, iconSize, actualSpacing, 20, popupSlots)

    frame:SetSize(blockW + 40, blockH + 40)
    frame._rpCount = numIcons
    RC.Position.RestoreFrame(frame)

    local iconsShown = 0

    for i, ability in ipairs(usableAbilities) do
        local icon = frame.abilityIcons[i]
        if not icon then
            icon = BuildAbilityIconFrame(self, frame, iconSize)
            frame.abilityIcons[i] = icon
        else
            icon:SetSize(iconSize, iconSize)
            icon.originalSize = iconSize
            if self.UI and self.UI.DressReadyIcon then self.UI:DressReadyIcon(icon, iconSize) end

            if icon.cooldownText then self:EnsureReminderIconText(icon) end
        end

        local abilityData = nil
        local itemId = tonumber(ability)
        local iconTexture = nil
        local abilityName = nil
        local abilityDescription = nil

        if ability == "trinket1" or ability == "trinket2" then
            self:DebugPrint("Loading trinket: " .. ability, "trinket")

            local slotId = (ability == "trinket1") and 13 or 14
            local itemLink = GetInventoryItemLink("player", slotId)

            if itemLink then
                local trinketItemId = tonumber(itemLink:match("item:(%d+)"))
                if trinketItemId then
                    local itemName, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(trinketItemId)

                    if itemTexture then
                        iconTexture = itemTexture
                        abilityName = itemName or (ability == "trinket1" and "Trinket 1" or "Trinket 2")
                        abilityDescription = "Use trinket"
                        self:DebugPrint("Got trinket icon: " .. tostring(iconTexture), "trinket")
                    else
                        iconTexture = "Interface\\Icons\\INV_Jewelry_Trinket_01"
                        abilityName = ability == "trinket1" and "Trinket 1" or "Trinket 2"
                        abilityDescription = "Use trinket"
                        self:DebugPrint("Trinket item info not cached, using fallback icon", "trinket")
                    end

                    abilityData = {
                        name = abilityName,
                        icon = iconTexture,
                        description = abilityDescription
                    }
                else
                    iconTexture = "Interface\\Icons\\INV_Jewelry_Trinket_01"
                    abilityName = ability == "trinket1" and "Trinket 1" or "Trinket 2"
                    abilityDescription = "Use trinket"
                    abilityData = {
                        name = abilityName,
                        icon = iconTexture,
                        description = abilityDescription
                    }
                end
            else
                iconTexture = "Interface\\Icons\\INV_Jewelry_Trinket_01"
                abilityName = ability == "trinket1" and "Trinket 1" or "Trinket 2"
                abilityDescription = "Use trinket"
                abilityData = {
                    name = abilityName,
                    icon = iconTexture,
                    description = abilityDescription
                }
            end
        elseif type(ability) == "string" and ability:find("Potion") then
            self:DebugPrint("Loading potion: " .. ability, "items")

            local potionItemId = nil
            if self.cooldownTracker and self.cooldownTracker.potionItemIds then
                for id, name in pairs(self.cooldownTracker.potionItemIds) do
                    if name == ability then
                        potionItemId = id
                        break
                    end
                end
            end

            if potionItemId then
                local itemName, itemLink, itemRarity, itemLevel, itemMinLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, itemTexture = GetItemInfo(potionItemId)

                if itemTexture then
                    iconTexture = itemTexture
                    abilityName = itemName
                    abilityDescription = "Consumable Potion"
                    self:DebugPrint("Got icon for potion " .. ability .. ": " .. iconTexture, "items")
                else
                    iconTexture = "Interface\\Icons\\INV_Potion_01"
                    abilityName = ability
                    abilityDescription = "Consumable Potion"
                    self:DebugPrint("Using fallback icon for potion " .. ability, "items")
                end

                abilityData = {
                    name = abilityName,
                    icon = iconTexture,
                    description = abilityDescription
                }
            end
        elseif itemId and self.utilityItems and self.utilityItems[itemId] then
            self:DebugPrint("Loading utility item: " .. itemId, "items")

            local utilityData = self.utilityItems[itemId]

            local itemName, itemLink, itemRarity, itemLevel, itemMinLevel, itemType, itemSubType, itemStackCount, itemEquipLoc, itemTexture = GetItemInfo(itemId)

            if itemTexture then
                iconTexture = itemTexture
                abilityName = itemName or utilityData.name
                abilityDescription = utilityData.description
                self:DebugPrint("Got real icon for " .. abilityName .. ": " .. iconTexture, "items")
            else
                iconTexture = utilityData.icon
                abilityName = utilityData.name
                abilityDescription = utilityData.description
                self:DebugPrint("Using fallback icon for " .. abilityName, "items")
            end

            abilityData = {
                name = abilityName,
                icon = iconTexture,
                description = abilityDescription
            }
        else
            abilityData = self.abilityData and self.abilityData[ability]
            if abilityData then
                iconTexture = abilityData.icon
                abilityName = abilityData.name
                abilityDescription = abilityData.description
                self:DebugPrint("Loading regular ability: " .. abilityName, "abilities")

                if abilityData.spellId then
                    local spellTexture = GetSpellTexture(abilityData.spellId)
                    if spellTexture then
                        iconTexture = spellTexture
                        self:DebugPrint("Using spell texture for " .. abilityName .. ": " .. tostring(spellTexture), "abilities")
                    end
                end
            end
        end

        if not iconTexture or not abilityData then
            iconTexture = "Interface\\Icons\\INV_Misc_QuestionMark"
            abilityName = ability
            abilityDescription = "Ability ready"
            abilityData = {
                name = abilityName,
                icon = iconTexture,
                description = abilityDescription
            }
            self:DebugPrint("Using fallback for unknown ability: " .. tostring(ability), "reminder")
        end

        icon.texture:SetTexture(iconTexture)

        local textureSet = icon.texture:GetTexture()
        if not textureSet then
            if abilityData.spellId then
                local spellTexture = GetSpellTexture(abilityData.spellId)
                if spellTexture then
                    icon.texture:SetTexture(spellTexture)
                    textureSet = icon.texture:GetTexture()
                    self:DebugPrint("Recovered texture via spellId for " .. tostring(ability), "reminder")
                end
            end

            if not textureSet then
                icon.texture:SetTexture(136243)
                self:DebugPrint(string.format(RCL["Icon %d: Failed to load texture '%s', using fallback ID"], i, tostring(iconTexture)), "reminder")
            end
        end

        self:DebugPrint(string.format(RCL["Icon %d: ability='%s', texture='%s', loaded=%s"],
            i, tostring(ability), tostring(iconTexture), tostring(icon.texture:GetTexture() ~= nil)), "reminder")

        icon.abilityKey = ability

        icon:SetAlpha(1.0)
        if icon.texture then
            icon.texture:SetAlpha(1.0)
            icon.texture:Show()
            icon.texture:SetDrawLayer("ARTWORK", 1)
        end
        if icon.bg then
            icon.bg:SetAlpha(0.9)
            icon.bg:Show()
        end

        frame:SetFrameStrata("HIGH")
        frame:SetFrameLevel(100)

        if icon:GetParent() ~= frame then
            icon:SetParent(frame)
        end
        icon:SetFrameLevel(frame:GetFrameLevel() + 1)

        icon:ClearAllPoints()
        local slot = popupSlots[i]
        icon:SetPoint(slot.point or "CENTER", frame, slot.point or "CENTER", slot.point and slot.x or 0, slot.point and slot.y or 0)
        icon:Show()
        self:PlaceReminderIconGlow(icon)

        if self.db.clickThrough then
            icon:EnableMouse(false)
            icon:SetScript("OnEnter", nil)
            icon:SetScript("OnLeave", nil)
            icon:SetScript("OnMouseDown", nil)
        else
            icon:EnableMouse(true)

            if self.db.showTooltips ~= false then
                icon:SetScript("OnEnter", function()
                    local cTitle = RC:GetColor("tooltip", "titleText")
                    local cBody  = RC:GetColor("tooltip", "bodyText")
                    local cReady = RC:GetColor("text", "green")
                    GameTooltip:SetOwner(icon, "ANCHOR_TOP")
                    GameTooltip:SetText(abilityName, cTitle.r, cTitle.g, cTitle.b, 1, true)
                    GameTooltip:AddLine(abilityDescription or RCL["No description"], cBody.r, cBody.g, cBody.b, true)
                    GameTooltip:AddLine(RCL["Ready to use!"], cReady.r, cReady.g, cReady.b)
                    if frame.isTestMode then
                        local cHint = RC:GetColor("text", "blue")
                        GameTooltip:AddLine(RCL["Click to simulate usage"], cHint.r, cHint.g, cHint.b, 1)
                    end
                    GameTooltip:Show()
                end)
                icon:SetScript("OnLeave", function()
                    GameTooltip:Hide()
                end)
            else
                icon:SetScript("OnEnter", nil)
                icon:SetScript("OnLeave", nil)
            end

            if frame.isTestMode then
                icon:SetScript("OnMouseDown", function()
                    self:DebugPrint("Simulated using " .. abilityName, "test")

                    if frame.currentAbilities then
                        for j, currentAbility in ipairs(frame.currentAbilities) do
                            if currentAbility == ability then
                                table.remove(frame.currentAbilities, j)
                                break
                            end
                        end

                        if #frame.currentAbilities == 0 then
                            self:HideReminder()
                        else
                            local remainingMessage = frame.isTestMode and "TEST - Click icons to hide!" or message
                            self:ShowReminder(remainingMessage, frame.currentAbilities, duration)
                        end
                    end
                end)
            end
        end

        if icon.cooldownText then
            local isFBAbility = (ability == "frostBlast") or
                (type(ability) == "string" and ability:find("^frostBlastBuff_"))
            if ability == "boon" then
                self:SetReminderIconLabel(icon, self:GetBoonLabel(), "gold")
            elseif isFBAbility then
                self:SetReminderIconLabel(icon, "REMOVE", "orange")
            elseif type(ability) == "string" and ability:find("^custom_") then
                local lbl = (abilityData and abilityData.description) or abilityName or "Alert"
                if #lbl > 22 then lbl = lbl:sub(1,20) .. ".." end
                self:SetReminderIconLabel(icon, lbl, "gold")
                icon.cooldownText:SetWidth(math.max(iconSize, iconSize * 2))
            else
                local overrideText = RC.pendingTextOverrides and RC.pendingTextOverrides[ability]
                if overrideText then
                    self:SetReminderIconLabel(icon, overrideText, "gold")
                else
                    self:SetReminderIconLabel(icon, "USE", "green")
                end
            end
            if not (type(ability) == "string" and ability:find("^custom_")) then
                icon.cooldownText:SetWidth(iconSize)
            end
            self:PlaceReminderIconText(icon)
        else
            ApplyLabelState(icon, StateColorFor(ability))
        end

        local hasBuffIcons = false
        for _, ab in ipairs(usableAbilities) do
            if type(ab) == "string" and ab:find("^frostBlastBuff_") then
                hasBuffIcons = true; break
            end
        end
        if ability == "frostBlast" and hasBuffIcons then
            icon:Hide()
            if icon.texture then icon.texture:Hide() end
        elseif not popupSlots[i].point then
            -- past the layout's "most shown"
            icon:Hide()
        else
            self:StartIconAnimation(icon)
            iconsShown = iconsShown + 1
        end
    end

    if iconsShown == 0 then
        self:DebugPrint("No icons could be displayed - aborting reminder", "reminder")
        return
    end

    self:ShowFrameWithAnimation(frame)

    -- Both branches currently cancel the dismissal timer and set the same
    -- 86400s (24h) expire time - the persistent-vs-normal split only
    -- changes which debug line prints, not the actual behavior.
    if not frame.isTestMode then
        if hasPersistentAbility and (not duration or duration == 0) then
            if self.activeReminderData.dismissalTimer then
                self.activeReminderData.dismissalTimer:Cancel()
                self.activeReminderData.dismissalTimer = nil
            end
            self.activeReminderData.reminderExpireTime = GetTime() + 86400
            self:DebugPrint("Persistent reminder (boon/frostBlast) - no auto-dismiss timer", "reminder")
        else
            if self.activeReminderData.dismissalTimer then
                self.activeReminderData.dismissalTimer:Cancel()
                self.activeReminderData.dismissalTimer = nil
            end
            self.activeReminderData.reminderExpireTime = GetTime() + 86400
            self:DebugPrint("Reminder shown - will hide when ability used or condition clears", "reminder")
        end
        self:DebugPrint("Smart dismissal active - monitoring for ability usage via spell casts", "reminder")
    else
        if duration and duration > 0 then
            self:ScheduleTimer("HideReminder", duration)
        end
    end

    if self.db.soundEnabled then
        local perAbilitySound = nil
        for _, ab in ipairs(usableAbilities) do
            local ao = self.db.abilityOverrides and self.db.abilityOverrides[ab]
            if ao and ao.soundEnabled then
                local sf = ao.soundFile
                if ao.soundKey and self.LSM then
                    sf = self.LSM:Fetch("sound", ao.soundKey) or sf
                end
                if sf and sf ~= "" then perAbilitySound = sf; break end
            end
        end

        if perAbilitySound then
            PlaySoundFile(perAbilitySound, "Master")
        else
            local globalSoundFile = self.db.soundFile
            if self.db.soundKey and self.LSM then
                globalSoundFile = self.LSM:Fetch("sound", self.db.soundKey) or globalSoundFile
            end
            if globalSoundFile and globalSoundFile ~= "" then
                PlaySoundFile(globalSoundFile, "Master")
            else
                PlaySound(8959)
                C_Timer.After(0.2, function() PlaySound(8960) end)
            end
        end
    end

    -- ao.ttsBlocked marks an ability whose owner speaks its own line (custom
    -- reminders set it). The generic TTS below MUST stay quiet for those or
    -- it wins the race: it speaks the reminder's NAME instead of its ttsText
    -- and latches ttsPlayed, so the owner's own call is then skipped. That
    -- also made an unchecked per-reminder TTS box speak anyway.
    local ttsBlockedByOverride = false
    if self.db.abilityOverrides then
        for _, ab in ipairs(usableAbilities) do
            local ao = self.db.abilityOverrides[ab]
            if ao and (ao.ttsBlocked
                or (ao.soundEnabled and ao.soundFile and ao.soundFile ~= "")) then
                ttsBlockedByOverride = true; break
            end
        end
    end

    local suppressTTSOnce = self._suppressReminderTTSOnce
    self._suppressReminderTTSOnce = nil

    if self.db.ttsEnabled and isNewPopupSession and not self.activeReminderData.ttsPlayed and not ttsBlockedByOverride and not suppressTTSOnce then
        self.activeReminderData.ttsPlayed    = true
        self.activeReminderData.ttsPlayCount = 0

        local selectedSound = usableAbilities[1]
        if self.SelectBestTTSSound then
            selectedSound = self:SelectBestTTSSound(usableAbilities)
        end

        -- "Rail window" = worst-case time the repeat-TTS cycle below could
        -- still be running (interval * number of plays) plus 5s slack.
        -- While inside it, a re-triggered reminder must not restart the
        -- same TTS chain from play #1.
        local _railWindow = math.max(10, self.db.ttsRepeatInterval or 30)
            * (math.min(self.db.ttsRepeatCount or 0, 10) + 1) + 5
        if TTSSuppressed(selectedSound) then
            self:DebugPrint("TTS: Suppressed '" .. tostring(selectedSound) .. "' (played too recently)", "tts")
        elseif _chainLastStart[selectedSound]
           and (GetTime() - _chainLastStart[selectedSound]) < _railWindow then
            self:DebugPrint("TTS: chain rail - '" .. tostring(selectedSound)
                .. "' window still open, not restarting", "tts")
        else
            TTSMarkFired(selectedSound)
            local speakName = ResolveSpeakName(selectedSound, self.abilityData)
            self:DebugPrint("TTS: Playing for NEW popup session #" .. self.activeReminderData.popupSessionID .. " sound='" .. speakName .. "'", "tts")
            if self.SpeakTTS then
                self:SpeakTTS(speakName, false)
            end

            local repeatCount    = math.min(self.db.ttsRepeatCount or 0, 10)
            local repeatInterval = math.max(10, self.db.ttsRepeatInterval or 30)
            if repeatCount > 0 then
                _chainLastStart[selectedSound] = GetTime()
            end
            local sessionID      = self.activeReminderData.popupSessionID
            self.activeReminderData.ttsPlayCount = 1

            if repeatCount > 0 and repeatInterval > 0 then
                local ard = self.activeReminderData
                local function ScheduleNextRepeat(playsRemaining)
                    if ard.ttsRepeatTimer then
                        ard.ttsRepeatTimer:Cancel()
                        ard.ttsRepeatTimer = nil
                    end
                    if playsRemaining <= 0 then return end
                    ard.ttsRepeatTimer = C_Timer.NewTimer(repeatInterval, function()
                        ard.ttsRepeatTimer = nil
                        if ard.popupSessionID ~= sessionID then return end
                        if not RC.reminderFrame or not RC.reminderFrame:IsShown() then return end
                        if not RC.db.ttsEnabled then return end
                        ard.ttsPlayCount = ard.ttsPlayCount + 1
                        RC:DebugPrint("TTS: Repeat " .. ard.ttsPlayCount .. " of " .. (1 + repeatCount) .. " sound='" .. speakName .. "'", "tts")
                        if RC.SpeakTTS then RC:SpeakTTS(speakName, false) end
                        ScheduleNextRepeat(playsRemaining - 1)
                    end)
                end
                ScheduleNextRepeat(repeatCount)
            end
        end
    else
        if not isNewPopupSession then
            self:DebugPrint("TTS: Skipped - same popup session #" .. (self.activeReminderData.popupSessionID or 0), "tts")
        elseif self.activeReminderData.ttsPlayed then
            self:DebugPrint("TTS: Skipped - already played for this popup session", "tts")
        elseif not self.db.ttsEnabled then
            self:DebugPrint("TTS: Skipped - disabled in settings", "tts")
        end
    end

    local combatStatus = (self.inCombat or UnitAffectingCombat("player")) and " [COMBAT]" or " [OUT OF COMBAT]"
    self:DebugPrint("Showed reminder with " .. #usableAbilities .. " ready abilities (Session #" .. (self.activeReminderData.popupSessionID or 0) .. ")" .. combatStatus, "reminder")

    if not frame.isTestMode and not frame.isSimulation then
        self:SetupCooldownMonitoring(message, abilities, usableAbilities, duration, currentReminderID)
    end

    C_Timer.After(0.1, function()
        if self.reminderFrame then
            self:DebugPrint("POST-SHOW VERIFICATION: Frame visible=" .. tostring(self.reminderFrame:IsShown()) .. ", alpha=" .. self.reminderFrame:GetAlpha() .. ", parent=" .. tostring(self.reminderFrame:GetParent():GetName()), "reminder")

            if self.reminderFrame.abilityIcons then
                for i, icon in pairs(self.reminderFrame.abilityIcons) do
                    if icon and icon:IsShown() then
                        if icon.texture then
                            icon.texture:SetAlpha(1.0)
                            icon.texture:Show()
                            local currentTexture = icon.texture:GetTexture()
                            if not currentTexture then
                                icon.texture:SetTexture(136243)
                                self:DebugPrint("FAILSAFE: Icon " .. i .. " had no texture, applied fallback", "reminder")
                            end
                        end
                        if icon.bg then
                            icon.bg:SetAlpha(0.9)
                            icon.bg:Show()
                        end
                        icon:SetAlpha(icon._rpAlpha or 1.0)
                    end
                end
            end
        end
    end)

    C_Timer.After(0.5, function()
        if self.reminderFrame and self.reminderFrame:IsShown() and self.reminderFrame.abilityIcons then
            for i, icon in pairs(self.reminderFrame.abilityIcons) do
                if icon and icon:IsShown() and icon.texture then
                    local currentTexture = icon.texture:GetTexture()
                    if not currentTexture then
                        icon.texture:SetTexture(136243)
                        self:DebugPrint("LATE FAILSAFE: Icon " .. i .. " still had no texture at 0.5s", "reminder")
                    end
                end
            end
        end
    end)
end

function RC:SetupCooldownMonitoring(message, allAbilities, currentlyReadyAbilities, duration, reminderID)
    if self.activeReminderData.cooldownMonitors then
        for _, timer in ipairs(self.activeReminderData.cooldownMonitors) do
            if timer then
                timer:Cancel()
            end
        end
    end
    self.activeReminderData.cooldownMonitors = {}

    local targetGUID = UnitGUID("target")
    if not targetGUID and self.activeSimulation and self.activeSimulation.fakeGUID then
        targetGUID = self.activeSimulation.fakeGUID
        self:DebugPrint("Using simulation fakeGUID for cooldown monitoring", "cooldown")
    end

    if not targetGUID then
        self:DebugPrint("No target for cooldown monitoring", "cooldown")
        return
    end

    local abilitiesOnCooldown = {}
    for _, ability in ipairs(allAbilities) do
        local isReady = false
        for _, readyAbility in ipairs(currentlyReadyAbilities) do
            if readyAbility == ability then
                isReady = true
                break
            end
        end

        if not isReady then
            local cooldownRemaining = self:GetAbilityCooldownRemaining(ability)
            if cooldownRemaining and cooldownRemaining > 0 then
                table.insert(abilitiesOnCooldown, {
                    ability = ability,
                    cooldownEnd = cooldownRemaining
                })
                self:DebugPrint("Monitoring " .. ability .. " - ready in " .. math.ceil(cooldownRemaining) .. "s", "cooldown")
            end
        end
    end

    for _, cooldownInfo in ipairs(abilitiesOnCooldown) do
        local ability = cooldownInfo.ability
        local timeUntilReady = cooldownInfo.cooldownEnd

        local triggerDelay = timeUntilReady + 0.5

        local timer = C_Timer.NewTimer(triggerDelay, function()
            if self.activeReminderData.reminderID ~= reminderID then
                self:DebugPrint("Cooldown expired but reminder ID changed - not re-triggering", "cooldown")
                return
            end

            local currentTargetGUID = UnitGUID("target")
            if currentTargetGUID ~= targetGUID then
                self:DebugPrint("Cooldown expired but target changed - not re-triggering", "cooldown")
                return
            end

            local isReady, gracePeriod = self:IsAbilityReady(ability, false)
            if not isReady then
                self:DebugPrint("Cooldown timer fired but ability still not ready: " .. ability, "cooldown")
                return
            end

            local shouldCheckTTK = (ability == "trinket1" or ability == "trinket2" or
                                   (type(ability) == "string" and ability:find("Potion")) or
                                   tonumber(ability) ~= nil)

            if shouldCheckTTK then
                local triggerTarget = self.triggerTargets and self.triggerTargets[targetGUID]

                if triggerTarget and triggerTarget.estimatedTimeToKill then
                    -- Rough on-use buff durations (not read from real item
                    -- data): used only to decide whether re-showing the
                    -- reminder is still worthwhile before the target dies.
                    local ttk = triggerTarget.estimatedTimeToKill
                    local buffDuration = 0

                    if ability == "trinket1" or ability == "trinket2" then
                        buffDuration = 20
                    elseif type(ability) == "string" and ability:find("Potion") then
                        buffDuration = 25
                    else
                        buffDuration = 20
                    end

                    if ttk > 0 and ttk < buffDuration then
                        self:DebugPrint("Cooldown expired but TTK (" .. math.floor(ttk) .. "s) < buff duration (" .. buffDuration .. "s) - not re-triggering " .. ability, "cooldown")
                        return
                    end
                end
            end

            self:DebugPrint("Ability " .. ability .. " now ready - re-triggering reminder!", "cooldown")

            self:ShowReminder(message, allAbilities, duration)
        end)

        table.insert(self.activeReminderData.cooldownMonitors, timer)
    end

    if #abilitiesOnCooldown > 0 then
        self:DebugPrint("Set up " .. #abilitiesOnCooldown .. " cooldown monitors", "cooldown")
    end
end

-- Starts the halo on a shown icon per db.iconGlow ("pulse" breathes,
-- "static" holds, "off" hides it). The halo is an AnimationGroup on the
-- texture, not a timer; the popup's own entrance (animationType) is
-- ShowFrameWithAnimation's.
function RC:StartIconAnimation(icon)
    if not icon then return end

    if icon.pulseTimer then
        icon.pulseTimer:Cancel()
        icon.pulseTimer = nil
    end
    if icon.animationTimer then
        icon.animationTimer:Cancel()
        icon.animationTimer = nil
    end

    if self.UI and self.UI.SetReadyIconGlow then
        self.UI:SetReadyIconGlow(icon, self.db.iconGlow or "pulse")
    end
end

function RC:ShowFrameWithAnimation(frame)
    if not frame then
        self:DebugPrint(RCL["ERROR: ShowFrameWithAnimation called with nil frame!"], "reminder")
        return
    end

    self:DebugPrint("ShowFrameWithAnimation called - current alpha: " .. frame:GetAlpha() .. ", isShown: " .. tostring(frame:IsShown()), "reminder")

    self:StopReminderAnimation()

    -- layer / scale / clamp, fade rules and a backdrop behind the icons
    -- (the customization standard, db.reminderPopup; unset = as always)
    if self.ApplyFrameCustom then
        self:ApplyFrameCustom(frame, function() return RC.db and RC.db.reminderPopup end)
    end

    if self.db.clickThrough then
        frame:EnableMouse(false)
    else
        frame:EnableMouse(true)
    end

    if frame.abilityIcons then
        for i, icon in pairs(frame.abilityIcons) do
            if icon and icon:IsShown() then
                if icon.texture then
                    local currentTexture = icon.texture:GetTexture()
                    if not currentTexture then
                        icon.texture:SetTexture(136243)
                        RC:DebugPrint("ShowFrameWithAnimation: Icon " .. i .. " had no texture, applied fallback", "reminder")
                    end
                    icon.texture:SetAlpha(1.0)
                    icon.texture:Show()
                end
                if icon.bg then
                    icon.bg:SetAlpha(0.9)
                    icon.bg:Show()
                end
                icon:SetAlpha(icon._rpAlpha or 1.0)
            end
        end
    end

    self:UpdateReminderFrameMouseState()

    -- At rest (alpha 1) before the entrance poses it: Motion puts this
    -- rest back exactly when the entrance ends or is cut short.
    frame:SetAlpha(1)
    local spec = self:GetReminderMotion("in", frame.currentAbilities)
    RC.Motion.Show(frame, spec)

    local settle = RC.Motion.Duration(spec.duration) + RC.Motion.Duration(spec.delay or 0) + 0.1
    C_Timer.After(settle, function()
        if frame and frame:IsShown() and not RC.Motion.IsPlaying(frame) and frame:GetAlpha() < 1.0 then
            RC:DebugPrint("FAILSAFE: Force setting frame alpha to 1.0 (was " .. frame:GetAlpha() .. ")", "reminder")
            frame:SetAlpha(1.0)
        end
    end)
end

-- Test-mode counterpart to ShowReminder above: duplicates most of its
-- icon-building logic instead of sharing it, so a change to icon layout
-- or fallback textures generally needs to be made in both functions.
function RC:ShowReminderForced(message, abilities, duration)
    abilities = abilities or {}

    local frame = self.reminderFrame
    if not frame then
        return
    end

    if self.activeReminderData.dismissalTimer then
        self.activeReminderData.dismissalTimer:Cancel()
        self.activeReminderData.dismissalTimer = nil
    end
    self:StopReminderAnimation()

    frame.isTestMode = true
    frame.currentAbilities = abilities

    ResetTTSState(self.activeReminderData)
    self.activeReminderData.popupSessionID = (self.activeReminderData.popupSessionID or 0) + 1
    self.activeReminderData.abilities = abilities
    self.activeReminderData.showTime = GetTime()

    if frame.abilityIcons then
        for _, icon in pairs(frame.abilityIcons) do
            icon:Hide()
            if icon.pulseTimer then
                icon.pulseTimer:Cancel()
                icon.pulseTimer = nil
            end
            if icon.animationTimer then
                icon.animationTimer:Cancel()
                icon.animationTimer = nil
            end
        end
    else
        frame.abilityIcons = {}
    end

    local iconSize = self.db.iconSize or 80
    local actualSpacing = self.db.iconSpacing or 5
    local step = iconSize + actualSpacing

    local validAbilities = {}
    local abilityIcons = {}

    for _, ability in ipairs(abilities) do
        local iconTexture = nil

        if ability == "trinket1" or ability == "trinket2" then
            local slotId = (ability == "trinket1") and 13 or 14
            local itemLink = GetInventoryItemLink("player", slotId)
            if itemLink then
                local trinketItemId = tonumber(itemLink:match("item:(%d+)"))
                if trinketItemId then
                    local _, _, _, _, _, _, _, _, _, itemTexture = GetItemInfo(trinketItemId)
                    iconTexture = itemTexture or "Interface\\Icons\\INV_Jewelry_Trinket_01"
                else
                    iconTexture = "Interface\\Icons\\INV_Jewelry_Trinket_01"
                end
            else
                iconTexture = "Interface\\Icons\\INV_Jewelry_Trinket_01"
            end
        else
            local abilityData = self.abilityData and self.abilityData[ability]
            if abilityData then
                iconTexture = abilityData.icon
                if abilityData.spellId then
                    iconTexture = GetSpellTexture(abilityData.spellId) or iconTexture
                end
            end
            if not iconTexture then
                iconTexture = "Interface\\Icons\\INV_Misc_QuestionMark"
            end
        end

        table.insert(validAbilities, ability)
        abilityIcons[ability] = iconTexture
    end

    local numIcons = #validAbilities
    if numIcons == 0 then
        return
    end

    -- the icon block: a centred row, or the layout set on Position
    local blockW, blockH = self:ReminderIconSlots(numIcons, iconSize, actualSpacing, 20, popupSlots)

    frame:SetSize(blockW + 40, blockH + 40)
    frame._rpCount = numIcons
    RC.Position.RestoreFrame(frame)

    for i, ability in ipairs(validAbilities) do
        local iconTexture = abilityIcons[ability]
        local icon = frame.abilityIcons[i]
        if not icon then
            icon = BuildAbilityIconFrame(self, frame, iconSize)
            frame.abilityIcons[i] = icon
        else
            icon:SetSize(iconSize, iconSize)
            icon.originalSize = iconSize
            if self.UI and self.UI.DressReadyIcon then self.UI:DressReadyIcon(icon, iconSize) end
        end

        icon.texture:SetTexture(iconTexture)
        icon:ClearAllPoints()

        local slot = popupSlots[i]
        icon:SetPoint(slot.point or "CENTER", frame, slot.point or "CENTER", slot.point and slot.x or 0, slot.point and slot.y or 0)
        icon:Show()
        self:PlaceReminderIconGlow(icon)

        if icon.cooldownText then
            self:EnsureReminderIconText(icon)
            local isFBAbility = (ability == "frostBlast") or
                (type(ability) == "string" and ability:find("^frostBlastBuff_"))
            if ability == "boon" then
                self:SetReminderIconLabel(icon, self:GetBoonLabel(), "gold")
            elseif isFBAbility then
                self:SetReminderIconLabel(icon, "REMOVE", "orange")
            else
                self:SetReminderIconLabel(icon, "USE", "green")
            end
            icon.cooldownText:SetWidth(iconSize)
            self:PlaceReminderIconText(icon)
        else
            ApplyLabelState(icon, StateColorFor(ability))
        end

        if ability == "frostBlast" then
            icon:Hide()
        elseif not popupSlots[i].point then
            icon:Hide()
        end

        self:StartIconAnimation(icon)
    end

    self:ShowFrameWithAnimation(frame)

    if duration and duration > 0 then
        self:ScheduleTimer("HideReminder", duration)
    end

    if self.db.soundEnabled then
        local perAbilitySound = nil
        for _, ab in ipairs(validAbilities) do
            local ao = self.db.abilityOverrides and self.db.abilityOverrides[ab]
            if ao and ao.soundEnabled then
                local sf = ao.soundFile
                if ao.soundKey and self.LSM then sf = self.LSM:Fetch("sound", ao.soundKey) or sf end
                if sf and sf ~= "" then perAbilitySound = sf; break end
            end
        end
        if perAbilitySound then
            PlaySoundFile(perAbilitySound, "Master")
        else
            local globalSoundFile = self.db.soundFile
            if self.db.soundKey and self.LSM then
                globalSoundFile = self.LSM:Fetch("sound", self.db.soundKey) or globalSoundFile
            end
            if globalSoundFile and globalSoundFile ~= "" then
                PlaySoundFile(globalSoundFile, "Master")
            else
                PlaySound(8959)
                C_Timer.After(0.2, function() PlaySound(8960) end)
            end
        end
    end

    -- Same ttsBlocked contract as ShowReminder above.
    local ttsBlockedForced = false
    if self.db.abilityOverrides then
        for _, ab in ipairs(validAbilities) do
            local ao = self.db.abilityOverrides[ab]
            if ao and (ao.ttsBlocked
                or (ao.soundEnabled and ao.soundFile and ao.soundFile ~= "")) then
                ttsBlockedForced = true; break
            end
        end
    end

    if self.db.ttsEnabled and not ttsBlockedForced then
        self.activeReminderData.ttsPlayed = true

        local selectedSound = abilities[1]
        if self.SelectBestTTSSound then
            selectedSound = self:SelectBestTTSSound(abilities)
        end

        if TTSSuppressed(selectedSound) then
            self:DebugPrint("TTS: Suppressed '" .. tostring(selectedSound) .. "' (played too recently)", "tts")
        else
            TTSMarkFired(selectedSound)
            local speakName = ResolveSpeakName(selectedSound, self.abilityData)
            if self.SpeakTTS then
                self:SpeakTTS(speakName, false)
            end
        end
    end
end

function RC:ShowTestReminder(forceAll)
    self:ScanEquippedTrinkets()

    local raidName = self:GetEffectiveRaidName()
    local targetName = UnitName("target")
    local encounterName = nil
    local encounterType = "trash"

    if targetName and UnitExists("target") then
        encounterName = self:GetEncounterNameForBoss(raidName, targetName)
        if encounterName then
            encounterType = "boss"
        else
            encounterType = "trash"
            encounterName = self.GetEncounterNameForTrash
                and self:GetEncounterNameForTrash(raidName, targetName) or nil
        end
    end

    local configuredAbilities = {}

    local raidConfig = raidName and self:GetActiveRaidProfile(raidName)
    if raidConfig then
        if encounterName then
            local targetTable = encounterType == "boss" and raidConfig.bosses or raidConfig.trash
            if targetTable and targetTable[encounterName] and targetTable[encounterName].abilities then
                for abilityKey, abilitySettings in pairs(targetTable[encounterName].abilities) do
                    if abilitySettings.enabled ~= false then
                        table.insert(configuredAbilities, abilityKey)
                    end
                end
            end
        end

        if #configuredAbilities == 0 and raidConfig.bosses then
            for bossName, bossData in pairs(raidConfig.bosses) do
                if bossData.abilities then
                    for abilityKey, abilitySettings in pairs(bossData.abilities) do
                        if abilitySettings.enabled ~= false then
                            local found = false
                            for _, existingKey in ipairs(configuredAbilities) do
                                if existingKey == abilityKey then
                                    found = true
                                    break
                                end
                            end
                            if not found then
                                table.insert(configuredAbilities, abilityKey)
                            end
                        end
                    end
                end
            end
        end
    end

    if #configuredAbilities == 0 then
        configuredAbilities = {"deathwish", "recklessness", "bloodrage", "berserkerrage"}

        local hasOnUse1 = self.trinketData.slot1.hasOnUse or self:IsTrinketSlotOnUse(1)
        if hasOnUse1 then
            table.insert(configuredAbilities, "trinket1")
        end
        local hasOnUse2 = self.trinketData.slot2.hasOnUse or self:IsTrinketSlotOnUse(2)
        if hasOnUse2 then
            table.insert(configuredAbilities, "trinket2")
        end
    end

    local readyAbilities = {}
    local allAbilities = {}

    for _, ability in ipairs(configuredAbilities) do
        local ready, graceTime = self:IsAbilityReady(ability)
        if ready then
            table.insert(readyAbilities, ability)
            table.insert(allAbilities, ability)
        else
            if forceAll then
                table.insert(allAbilities, ability)
            end
        end
    end

    local abilitiesToShow = forceAll and allAbilities or readyAbilities

    if #abilitiesToShow == 0 then
        self:DebugPrint("No abilities available to show", "test")
        if not forceAll then
            self:DebugPrint("Note: All configured abilities are on cooldown or missing.", "test")
        end
        return
    end

    local duration = self.db.reminderDuration or 8
    self:ShowReminderForced("TEST - Animation Preview", abilitiesToShow, duration)

    self:DebugPrint("Test reminder displayed with current animation style", "test")
end

function RC:ForceResetReminderFrame()
    if not self.reminderFrame then return end

    self:DebugPrint("FORCE RESET: Completely resetting reminder frame to clean state", "reminder")

    if self.activeReminderData.dismissalTimer then
        self.activeReminderData.dismissalTimer:Cancel()
        self.activeReminderData.dismissalTimer = nil
    end
    self:StopReminderAnimation()

    if self.reminderFrame.abilityIcons then
        for _, icon in pairs(self.reminderFrame.abilityIcons) do
            icon:Hide()
            if icon.haloPulse then icon.haloPulse:Stop() end
            if icon.pulseTimer then
                icon.pulseTimer:Cancel()
                icon.pulseTimer = nil
            end
            if icon.animationTimer then
                icon.animationTimer:Cancel()
                icon.animationTimer = nil
            end
            if icon.originalSize then
                icon:SetSize(icon.originalSize, icon.originalSize)
            end
        end
    end

    self.reminderFrame:Hide()
    self.reminderFrame:SetAlpha(0)
    self.reminderFrame:SetScale(1.0)
    RC.Position.RestoreFrame(self.reminderFrame)

    self.activeReminderData.abilities = {}
    ResetTTSState(self.activeReminderData)
    self.activeReminderData.popupSessionID = 0
    self.activeReminderData.showTime = 0

end

function RC:UpdateReminderFrameMouseState()
    if not self.reminderFrame then return end

    local clickThrough = self.db.clickThrough or false
    local dragEnabled = self.db.dragEnabled or false

    self.reminderFrame:EnableMouse(not clickThrough or dragEnabled)

    if self.reminderFrame.abilityIcons then
        for _, icon in pairs(self.reminderFrame.abilityIcons) do
            if clickThrough then
                icon:EnableMouse(false)
                icon:SetScript("OnEnter", nil)
                icon:SetScript("OnLeave", nil)
                icon:SetScript("OnMouseDown", nil)
            else
            end
        end
    end

    self:DebugPrint("Updated reminder frame mouse state: clickThrough=" .. tostring(clickThrough) .. ", dragEnabled=" .. tostring(dragEnabled), "reminder")
end

function RC:HideReminder()
    if self.reminderFrame then
        self:StopReminderAnimation()

        if self.activeReminderData.cooldownMonitors then
            for _, timer in ipairs(self.activeReminderData.cooldownMonitors) do
                if timer then
                    timer:Cancel()
                end
            end
            self.activeReminderData.cooldownMonitors = {}
        end

        self.reminderFrame:Hide()
        self.reminderFrame:SetAlpha(1.0)
        self.reminderFrame:SetScale(1.0)

        self.activeReminderData.abilities = {}
        ResetTTSState(self.activeReminderData)
        self.activeReminderData.popupSessionID = 0
        self.activeReminderData.reminderExpireTime = 0
        if self.activeReminderData.dismissalTimer then
            self.activeReminderData.dismissalTimer:Cancel()
            self.activeReminderData.dismissalTimer = nil
        end

        if self.reminderFrame.abilityIcons then
            for _, icon in pairs(self.reminderFrame.abilityIcons) do
                if icon.pulseTimer then
                    icon.pulseTimer:Cancel()
                    icon.pulseTimer = nil
                end
                if icon.animationTimer then
                    icon.animationTimer:Cancel()
                    icon.animationTimer = nil
                end
                if icon.originalSize then
                    icon:SetSize(icon.originalSize, icon.originalSize)
                end
            end
        end
    end
end

function RC:HideAllReminders()
    self:HideReminder()
    if self.ttsFrame and self.HideTTSFrame then
        self:HideTTSFrame()
    end
end

-- CreateFontString moved to the main addon's Core\Core_Boot.lua: it is
-- the shared font-string factory for every addon in the set, so it has
-- to exist whether or not this one is loaded.
