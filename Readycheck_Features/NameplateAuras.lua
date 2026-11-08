------------------------------------------------------------------------
-- Readycheck - Nameplate Debuff Auras
-- Draws debuff icons, stack counts and timers on enemy nameplates.
-- getBar() resolves the health bar in a fixed order: ZacUI
-- (plate._zuiNP.health) FIRST, because ZacUI hides Blizzard's UnitFrame
-- and the Blizzard path would anchor to an invisible frame with the
-- wrong geometry; then Plater (unitFrame.healthBar); then Blizzard
-- (plate.UnitFrame.healthBar); then the plate root as a last resort.
-- Every offsetX/offsetY is measured from that bar's CENTRE.
-- Icons host on one shared frame at strata DIALOG, frame level 100;
-- anything else drawing over nameplates positions relative to that.
-- Group schema: id, name, mode "single"|"row", attach "top"|"center"|
-- "bottom", offsetX/offsetY, growDir "right"|"left"|"up"|"down" (row
-- mode only), members (ordered catalog keys), memberOn[key] = false
-- mutes a member, fontSize, timerSize, timerGap, timerPos, enabled,
-- showIcon / showCount / showTimer.
------------------------------------------------------------------------

-- Taint-safe API locals (fallbacks on RC.Compat, built in Core;
-- never write _G - a written Blizzard global taints its readers)
local RCC = _G.Readycheck
local UnitDebuff = UnitDebuff or (RCC and RCC.Compat and RCC.Compat.UnitDebuff)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)

-- spellID is only a lookup seed: resolveCatalog() turns it into the
-- localized spell NAME and matching happens on that exact name string,
-- so every rank and every caster of the same spell resolves to one key.
-- variant groups keys that must not preview twice (the two Faerie Fires).
local CATALOG = {
    sunder          = { spellID = 7405,  stack = true },
    expose          = { spellID = 8647, label = "E" },
    cor             = { spellID = 704 },
    faeriefire      = { spellID = 770,   variant = "faeriefire" },
    faeriefireferal = { spellID = 16857, variant = "faeriefire" },
    demoshout       = { spellID = 1160 },
    demoroar        = { spellID = 99 },
    curseofweakness = { spellID = 702 },
    thunderclap     = { spellID = 6343 },
    thunderfury     = { spellID = 21992 },
    disarm          = { spellID = 676 },
    scorch          = { spellID = 22959, stack = true },
    curseofelements = { spellID = 1490 },
    curseofshadow   = { spellID = 17862 },
    judgelight      = { spellID = 20185 },
    judgewisdom     = { spellID = 20186 },
    huntersmark     = { spellID = 1130 },
    overpower       = { spellID = 7384, proc = true },
    execute         = { spellID = 5308, proc = true },
    -- Taunt effects match by aura name, so every rank and every caster is
    -- covered - including NPC casts like the Razuvious understudy Taunt
    -- (29060), which shares the "Taunt" name with the warrior spell.
    taunt            = { spellID = 355 },
    growl            = { spellID = 6795 },
    mockingblow      = { spellID = 694 },
    challengingshout = { spellID = 1161 },
    challengingroar  = { spellID = 5209 },
}

-- Anchor-point pair for a group's attach edge ("top"/"bottom"/"center").
-- Shared by the live nameplate renderer and the settings-page preview.
local function anchorPoints(group)
    local a = group.attach or "center"
    if a == "top" then return "BOTTOM", "TOP" end
    if a == "bottom" then return "TOP", "BOTTOM" end
    return "CENTER", "CENTER"
end

local function InitializeNameplateAuras()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeNameplateAuras)
        return
    end
    if not RC.db then
        C_Timer.After(0.2, InitializeNameplateAuras)
        return
    end
    if RC.nameplateAuras and RC.nameplateAuras.initialized then
        return
    end

    local GetSpellInfo = GetSpellInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetSpellInfo)
    local GetTime = GetTime
    local UnitGUID, UnitExists, IsUsableSpell = UnitGUID, UnitExists, IsUsableSpell
    local UnitHealth, UnitHealthMax = UnitHealth, UnitHealthMax
    local UnitClassification, UnitLevel = UnitClassification, UnitLevel
    local ceil = math.ceil
    local floor = math.floor
    local format = string.format

    local NA = RC.nameplateAuras or {}
    RC.nameplateAuras = NA
    NA.initialized = true
    NA.activeUnits = {}
    NA.friendly    = {}
    NA.dirty       = {}
    NA.hasDirty    = false
    NA.ticker      = nil
    NA.catalog     = CATALOG
    NA.isWarrior   = select(2, UnitClass("player")) == "WARRIOR"

    -- Level -1 is the client's "??" skull, which every raid boss reports;
    -- classification alone misses bosses the server marks as elite only.
    local function isBossUnit(unit)
        return UnitClassification(unit) == "worldboss" or UnitLevel(unit) == -1
    end

    local function defaultGroups()
        return {
            { id = "armor", name = "Sunder / Expose", mode = "single", attach = "center", timerPos = "beside", offsetX = 0, offsetY = 22, enabled = true, fontSize = 11, timerSize = 7, timerGap = 0,
              showIcon = true, showCount = true, showTimer = true,
              members = { "sunder", "expose", "scorch" }, memberOn = { scorch = false } },
            { id = "armorextra", name = "Faerie Fire / Curse", mode = "row", attach = "center", timerPos = "beside", growDir = "right", offsetX = 0, offsetY = 40, enabled = true, fontSize = 11, timerSize = 7, timerGap = 0,
              showIcon = true, showCount = false, showTimer = true,
              members = { "faeriefire", "faeriefireferal", "cor", "curseofelements", "curseofshadow" },
              memberOn = { curseofelements = false, curseofshadow = false } },
            { id = "other", name = "Other Debuffs", mode = "row", attach = "center", timerPos = "beside", growDir = "right", offsetX = 0, offsetY = -22, enabled = true, fontSize = 11, timerSize = 7, timerGap = 0,
              showIcon = true, showCount = false, showTimer = true,
              members = { "demoshout", "demoroar", "curseofweakness", "thunderclap", "thunderfury", "disarm", "judgelight", "judgewisdom", "huntersmark" },
              memberOn = { judgelight = false, judgewisdom = false, huntersmark = false } },
            { id = "taunts", name = "Taunts", mode = "single", attach = "center", timerPos = "beside", offsetX = -78, offsetY = 0, enabled = true, fontSize = 11, timerSize = 7, timerGap = 0,
              showIcon = true, showCount = false, showTimer = true,
              members = { "taunt", "growl", "mockingblow", "challengingshout", "challengingroar" } },
            { id = "overpower", name = "Overpower Proc", mode = "single", attach = "center", timerPos = "beside", offsetX = 0, offsetY = -40, enabled = true, fontSize = 11, timerSize = 7, timerGap = 0,
              showIcon = true, showCount = false, showTimer = true,
              members = { "overpower" } },
            { id = "execute", name = "Execute Range", mode = "single", attach = "center", timerPos = "beside", offsetX = 0, offsetY = 58, enabled = true, fontSize = 11, timerSize = 7, timerGap = 0,
              showIcon = true, showCount = false, showTimer = false, bossOnly = false,
              members = { "execute" } },
        }
    end

    local function cfg()
        local c = RC.db and RC.db.nameplateAuras
        if not c then
            c = { enabled = false, fontSize = 11, groups = defaultGroups() }
            if RC.db then RC.db.nameplateAuras = c end
        end
        if not c.groups then c.groups = defaultGroups() end
        if not c.fontSize then c.fontSize = 11 end
        -- Each _np* flag below is a one-shot marker written into the saved
        -- profile: the block runs once per profile, never again. Adding a
        -- group or member to defaultGroups() alone will not reach profiles
        -- that already exist - it needs a new flagged block here too.
        if not c._npMigrated then
            c._npMigrated = true
            for _, g in ipairs(c.groups) do
                if not g.fontSize then g.fontSize = c.fontSize or 11 end
                if not g.timerSize then g.timerSize = math.max(7, math.floor((g.fontSize or 11) * 0.6)) end
                if g.timerGap == nil then g.timerGap = 0 end
                if g.growDir == nil then g.growDir = "right" end
            end
            if not c.ffCurseRowDone then
                c.ffCurseRowDone = true
                for _, g in ipairs(c.groups) do
                    if g.id == "armorextra" and g.mode ~= "row" then g.mode = "row" end
                end
            end
        end
        if not c._npProcGroupsAdded then
            c._npProcGroupsAdded = true
            local present = {}
            for _, g in ipairs(c.groups) do present[g.id] = true end
            if not present.overpower then
                c.groups[#c.groups + 1] = {
                    id = "overpower", name = "Overpower Proc", mode = "single", attach = "center",
                    timerPos = "beside", offsetX = 0, offsetY = -40, enabled = true,
                    fontSize = 11, timerSize = 7, timerGap = 0,
                    showIcon = true, showCount = false, showTimer = true,
                    members = { "overpower" },
                }
            end
            if not present.execute then
                c.groups[#c.groups + 1] = {
                    id = "execute", name = "Execute Range", mode = "single", attach = "center",
                    timerPos = "beside", offsetX = 0, offsetY = 58, enabled = true,
                    fontSize = 11, timerSize = 7, timerGap = 0,
                    showIcon = true, showCount = false, showTimer = false, bossOnly = false,
                    members = { "execute" },
                }
            end
        end
        if not c._npExtraDebuffsV2 then
            c._npExtraDebuffsV2 = true
            local byId = {}
            for _, g in ipairs(c.groups) do byId[g.id] = g end
            local function removeFromAll(key)
                for _, g in ipairs(c.groups) do
                    if g.members then
                        for i = #g.members, 1, -1 do
                            if g.members[i] == key then table.remove(g.members, i) end
                        end
                    end
                    if g.memberOn then g.memberOn[key] = nil end
                end
            end
            -- relocate = true moves the key even if the user already filed
            -- it elsewhere; false only seeds it when it is in no group at
            -- all, so a hand-placed member is never yanked out from under
            -- the user. New members always land muted (memberOn = false).
            local function place(group, key, relocate)
                if not group then return end
                if relocate then
                    removeFromAll(key)
                else
                    for _, g in ipairs(c.groups) do
                        for _, m in ipairs(g.members or {}) do
                            if m == key then return end
                        end
                    end
                end
                group.members = group.members or {}
                group.members[#group.members + 1] = key
                group.memberOn = group.memberOn or {}
                group.memberOn[key] = false
            end
            place(byId.armor,      "scorch",          false)
            place(byId.armorextra, "curseofelements", true)
            place(byId.armorextra, "curseofshadow",   true)
            place(byId.other,      "judgelight",      false)
            place(byId.other,      "judgewisdom",     false)
            place(byId.other,      "huntersmark",     false)
        end
        if not c._npTauntGroupAdded then
            c._npTauntGroupAdded = true
            local present = {}
            for _, g in ipairs(c.groups) do present[g.id] = true end
            if not present.taunts then
                c.groups[#c.groups + 1] = {
                    id = "taunts", name = "Taunts", mode = "single", attach = "center",
                    timerPos = "beside", offsetX = -78, offsetY = 0, enabled = true,
                    fontSize = 11, timerSize = 7, timerGap = 0,
                    showIcon = true, showCount = false, showTimer = true,
                    members = { "taunt", "growl", "mockingblow", "challengingshout", "challengingroar" },
                }
            end
        end
        if not c._npTauntPosV2 then
            -- The first taunt default (+76) sat outside the settings preview's
            -- clipped area; move untouched groups to the visible left-side spot.
            c._npTauntPosV2 = true
            for _, g in ipairs(c.groups) do
                if g.id == "taunts" and (g.offsetX or 0) == 0 and (g.offsetY or 0) == 76 then
                    g.offsetX = -78
                    g.offsetY = 0
                end
            end
        end
        return c
    end
    NA.cfg = cfg

    local function memberEnabled(group, key)
        return group.memberOn == nil or group.memberOn[key] ~= false
    end
    NA.memberEnabled = memberEnabled

    local function gsize(group)
        return (group and group.fontSize) or 11
    end

    -- Timer text defaults to 60% of the group font, floored at 7pt: below
    -- that the OUTLINE flag eats the glyphs and the digits go unreadable.
    local function tsize(group)
        return (group and group.timerSize) or math.max(7, math.floor(gsize(group) * 0.6))
    end

    local function resolveCatalog()
        local cd = RC.db and RC.db.nameplateAuras and RC.db.nameplateAuras.custom
        if cd then
            for key, def in pairs(cd) do
                if type(def) == "table" and def.spellID then
                    local e = CATALOG[key]
                    if not e then e = {}; CATALOG[key] = e end
                    e.spellID = def.spellID
                    e.stack = def.stack and true or nil
                    e.custom = true
                end
            end
        end
        NA.byName = {}
        for key, entry in pairs(CATALOG) do
            local nm, _, icon = GetSpellInfo(entry.spellID)
            entry.name = nm or entry.name or key
            entry.icon = icon or entry.icon or "Interface\\Icons\\INV_Misc_QuestionMark"
            NA.byName[entry.name] = key
        end
        NA.opName = (CATALOG.overpower and CATALOG.overpower.name) or NA.opName
        NA.opGroup, NA.execGroup = nil, nil
        for _, g in ipairs(cfg().groups) do
            if g.id == "overpower" then NA.opGroup = g
            elseif g.id == "execute" then NA.execGroup = g end
        end
        if NA.UpdateOPClog then NA.UpdateOPClog() end
    end
    NA.ResolveCatalog = resolveCatalog

    local function col(key, fr, fg, fb)
        if RC.GetColor then
            local c = RC:GetColor("nameplate", key)
            if c then return c.r, c.g, c.b end
        end
        return fr, fg, fb
    end

    local function stackColor(cnt)
        local lr, lg, lb = col("sunderLow", 1, 0.25, 0.25)
        local hr, hg, hb = col("sunderHigh", 0.3, 1, 0.3)
        -- Divisor 4 = the 5-stack cap on Sunder Armor and Improved Scorch
        -- minus one, so 1 stack sits on sunderLow and 5 on sunderHigh.
        local t = (cnt - 1) / 4
        if t < 0 then t = 0 elseif t > 1 then t = 1 end
        return lr + (hr - lr) * t, lg + (hg - lg) * t, lb + (hb - lb) * t
    end

    -- The customization standard (nameplateAuras.formats.timer,
    -- nameplateAuras.anchors.count / .timer): the timer worded, and on the
    -- icon the count and timer placeable. Each text's default is where its
    -- group's own choices (timer beside / under, the gap) put it.
    RC.NAMEPLATE_TIMER_FORMAT = { time = "short" }
    local fmtVals, fmtKinds = {}, { value = "time" }
    local function fmtTime(rem)
        local c = RC.db and RC.db.nameplateAuras
        local f = c and type(c.formats) == "table" and c.formats.timer or nil
        if f then
            fmtVals.value = rem
            return RC.UI:FormatText(f, RC.NAMEPLATE_TIMER_FORMAT, fmtVals, fmtKinds, "value")
        end
        if rem >= 60 then return format("%dm", ceil(rem / 60)) end
        return format("%ds", ceil(rem))
    end
    RC.NameplateTimerText = function(_, rem) return fmtTime(rem) end
    RC.NAMEPLATE_TEXT_TARGETS = { { value = "icon", text = RCL["Icon"] }, { value = "count", text = RCL["Stack count"] },
                                  { value = "timer", text = RCL["Timer"] } }
    local npDef = { count = {}, timer = {} }
    local function placeIconTexts(elem, countFS, timerFS)
        local c = RC.db and RC.db.nameplateAuras
        local a = c and type(c.anchors) == "table" and c.anchors or nil
        if not a then return end
        local to = function(k)
            if k == "icon" then return elem.icon elseif k == "count" then return countFS elseif k == "timer" then return timerFS end
        end
        -- The defaults come from where renderInto just put each text (it
        -- re-places them every render), never from GetPoint: a text on a
        -- nameplate can't be measured - the client throws in instances.
        for key, fs in pairs({ count = countFS or false, timer = timerFS or false }) do
            local spec = a[key]
            local d = npDef[key]
            if fs and spec and d.point then
                RC.UI:ApplyAnchor(fs, spec, d, to)
            end
        end
    end
    -- what renderInto chose for each text this render (the defaults above)
    local function noteDef(key, point, to, relPoint, x, y)
        local d = npDef[key]
        d.point, d.to, d.relPoint, d.x, d.y = point, to, relPoint, x, y
    end
    -- a text's default for the settings page (centred on the icon)
    function RC:NameplateTextAnchorDefault(key)
        return { point = "CENTER", relPoint = "CENTER", x = 0, y = 0 }
    end

    local function iconSize(group)
        return gsize(group) + 2
    end

    -- The font file in use right now, resolved at most once per frame:
    -- ensurePlate styles every element of a plate in one go and they all
    -- want the same answer.
    local fontAt, fontNow
    local function currentFont()
        local now = GetTime()
        if fontAt ~= now then
            fontAt = now
            fontNow = (RC.GetFontPath and RC:GetFontPath()) or ""
        end
        return fontNow
    end

    -- Nameplates are recycled constantly in a big pull, and every return
    -- re-styles all of a plate's elements. The fonts are only applied
    -- again when the font file or either size actually differs from what
    -- the element already wears; an unchanged element costs three
    -- comparisons instead of two SetFont/GetFont round trips.
    -- The page's look settings (nameplateAuras.look); every nil field is
    -- the original look. lookSig changes whenever they do, so the cheap
    -- per-element comparison below notices a new font or border.
    local function look()
        local c = RC.db and RC.db.nameplateAuras
        local l = c and c.look
        return type(l) == "table" and l or {}
    end
    NA.Look = look
    NA.lookSig = 0
    NA.SHOW_ANIM = { style = "none", duration = 0.25 }
    NA.EXPIRE_ANIM = { style = "none", duration = 0.6, loop = true }
    -- styles that only touch alpha: the renderer re-anchors elements every
    -- second, which a moving or scaling animation would fight
    NA.ANIM_STYLES = { "none", "fade", "flash" }

    local function styleElem(elem, group)
        local fSize = gsize(group)
        local sz = iconSize(group)
        local smallSize = tsize(group)
        elem.box:SetSize(sz, sz)
        local font = currentFont()
        if elem._wrFont ~= font or elem._wrMainSize ~= fSize
           or elem._wrSubSize ~= smallSize or elem._wrSig ~= NA.lookSig then
            local l = look()
            RC:ApplyFontSpec(elem.main, l.font, { size = fSize, outline = "OUTLINE" })
            RC:ApplyFontSpec(elem.sub, l.timerFont or l.font, { size = smallSize, outline = "OUTLINE" })
            local b = l.borderSize or 1
            local bc = l.borderColor
            elem.iconBorder:SetColorTexture(bc and bc.r or 0, bc and bc.g or 0, bc and bc.b or 0, bc and (bc.a or 1) or 1)
            elem.iconBorder:ClearAllPoints()
            elem.iconBorder:SetPoint("TOPLEFT", elem.icon, "TOPLEFT", -b, b)
            elem.iconBorder:SetPoint("BOTTOMRIGHT", elem.icon, "BOTTOMRIGHT", b, -b)
            elem.iconBorder:SetShown(b > 0 and elem.icon:IsShown())
            local z = l.zoom or 0.08
            elem.icon:SetTexCoord(z, 1 - z, z, 1 - z)
            elem._wrFont, elem._wrMainSize, elem._wrSubSize, elem._wrSig = font, fSize, smallSize, NA.lookSig
        end
    end

    -- One host for every plate's icons, parented to UIParent rather than to
    -- the plate: nameplate frames are recycled by the client, so anything
    -- parented to them inherits another mob's alpha and scale on reuse.
    -- Strata DIALOG / level 100 is the layer other features draw against.
    local function ensureHost()
        if not NA.host then
            local h = CreateFrame("Frame", "ReadycheckNameplateHost", UIParent)
            h:SetFrameStrata("DIALOG")
            h:SetFrameLevel(100)
            NA.host = h
        end
        return NA.host
    end

    local function getBar(plate)
        if not plate then return plate end
        -- ZacUI's nameplate engine FIRST: it hides Blizzard's UnitFrame,
        -- so the capital-U path below would anchor everything to an
        -- invisible bar with the wrong geometry.
        if plate._zuiNP and plate._zuiNP.health then
            return plate._zuiNP.health
        end
        -- Lowercase unitFrame is the Plater layout; Blizzard's own frame is
        -- capital-U UnitFrame. One check each - the old Plater-gated test
        -- duplicated the ungated lowercase fallback below it.
        if plate.unitFrame and plate.unitFrame.healthBar then
            return plate.unitFrame.healthBar
        end
        local uf = plate.UnitFrame
        if uf and uf.healthBar then return uf.healthBar end
        if not NA._barPathWarned then
            NA._barPathWarned = true
            RC:DebugPrint("NameplateAuras: health bar not found on plate - "
                .. "anchoring to plate root (nameplate structure changed?)", "system")
        end
        return plate
    end

    -- One element: a small frame (the box, which animations play on)
    -- holding the icon, its border and the two texts. The box is placed
    -- where the icon goes; text-only mode anchors the texts to the bar
    -- and keeps the box shown with its icon hidden.
    local function newElem(parent)
        local e = {}
        e.box = CreateFrame("Frame", nil, parent)
        e.box:SetSize(13, 13)
        e.box:Hide()
        e.iconBorder = e.box:CreateTexture(nil, "OVERLAY")
        e.iconBorder:SetDrawLayer("OVERLAY", 0)
        e.iconBorder:SetColorTexture(0, 0, 0, 1)
        e.icon = e.box:CreateTexture(nil, "OVERLAY")
        e.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        e.icon:SetDrawLayer("OVERLAY", 1)
        e.icon:SetAllPoints(e.box)
        e.iconBorder:SetPoint("TOPLEFT", e.icon, "TOPLEFT", -1, 1)
        e.iconBorder:SetPoint("BOTTOMRIGHT", e.icon, "BOTTOMRIGHT", 1, -1)
        e.iconBorder:Hide()
        -- templates = placeholder fonts until styleElem applies the real
        -- ones (hiding an element blanks its text, which the client
        -- refuses on a font-less string)
        e.main = e.box:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
        e.main:SetDrawLayer("OVERLAY", 7)
        e.sub = e.box:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        e.sub:SetDrawLayer("OVERLAY", 7)
        if RC.UI.TagElement then
            RC.UI:TagElement(e.main, "count") RC.UI:TagElement(e.sub, "timer") RC.UI:TagElement(e.icon, "icon")
        end
        return e
    end

    local function placeBox(e, ep, anchorTo, rp, x, y)
        e.box:ClearAllPoints()
        e.box:SetPoint(ep, anchorTo, rp, x, y)
    end

    -- A hidden element coming on plays the entrance (none by default).
    local function showElem(e)
        if e.box:IsShown() then return end
        local spec = look().showAnim
        if spec and spec.style and spec.style ~= "none" then
            RC.Motion.Show(e.box, RC.Motion.Normalize(spec, NA.SHOW_ANIM))
        else
            e.box:Show()
        end
    end

    -- The expiring highlight: a repeating alpha animation while the timer
    -- is at or under look.expireAt seconds (off by default).
    local function expireCheck(e, rem)
        local l = look()
        local spec = l.expireAnim
        local on = rem and spec and spec.style and spec.style ~= "none" and rem > 0 and rem <= (l.expireAt or 5)
        if on then
            if not e._wrExpiring then
                e._wrExpiring = true
                local s2 = RC.Motion.Normalize(spec, NA.EXPIRE_ANIM)
                s2.loop = true
                RC.Motion.Play(e.box, s2, "update")
            end
        elseif e._wrExpiring then
            e._wrExpiring = nil
            RC.Motion.Stop(e.box)
        end
    end

    local function positionGroup(plate, group)
        local g = plate.wrGroups[group.id]
        styleElem(g, group)
        local ep, rp = anchorPoints(group)
        placeBox(g, ep, plate.wrBar or plate, rp, group.offsetX or 0, group.offsetY or 0)
    end

    -- The anchor hangs off the UIParent-scaled host but is positioned
    -- against a plate that carries the nameplate scale, so it has to
    -- counter-scale by bar/host effective scale or every offset drifts
    -- as soon as the user changes nameplate or UI scale.
    local function refreshScale(plate)
        local anchor = plate.wrAnchor
        if not (anchor and NA.host) then return end
        local bar = plate.wrBar or plate
        local be = (bar.GetEffectiveScale and bar:GetEffectiveScale()) or 1
        local he = (NA.host.GetEffectiveScale and NA.host:GetEffectiveScale()) or 1
        if not be or be <= 0 then be = 1 end
        if not he or he <= 0 then he = 1 end
        local s = be / he
        if anchor._wrScale ~= s then
            anchor._wrScale = s
            anchor:SetScale(s)
        end
    end

    local function ensurePlate(plate)
        if not plate.wrAura then plate.wrAura = {} end
        if not plate.wrGroups then plate.wrGroups = {} end
        plate.wrBar = getBar(plate)
        if not plate.wrAnchor then
            local a = CreateFrame("Frame", nil, ensureHost())
            a:SetAllPoints(plate)
            plate.wrAnchor = a
        end
        refreshScale(plate)
        for _, group in ipairs(cfg().groups) do
            local g = plate.wrGroups[group.id]
            if not g then
                g = newElem(plate.wrAnchor)
                g.slots = {}
                plate.wrGroups[group.id] = g
            end
            positionGroup(plate, group)
            if g.slots then for _, s in ipairs(g.slots) do styleElem(s, group) end end
        end
    end

    local function ensureSlot(plate, group, i)
        local g = plate.wrGroups[group.id]
        g.slots = g.slots or {}
        if not g.slots[i] then g.slots[i] = newElem(plate.wrAnchor) end
        styleElem(g.slots[i], group)
    end

    -- Shared scratch arrays, refilled on every collectActive call: read the
    -- results out before calling it again for another group or plate.
    local _ak, _as = {}, {}
    local function collectActive(plate, group)
        local n = 0
        local aura = plate.wrAura
        for _, key in ipairs(group.members) do
            if memberEnabled(group, key) then
                local st = aura[key]
                if st and st.present then
                    n = n + 1
                    _ak[n] = key
                    _as[n] = st
                end
            end
        end
        return n
    end

    local function setFS(fs, str)
        if str ~= fs.lastText then fs:SetText(str); fs.lastText = str end
        fs:Show()
    end
    local function hideFS(fs)
        if fs.lastText ~= "" then fs:SetText(""); fs.lastText = "" end
        fs:Hide()
    end
    local function hideElem(e)
        if not e then return end
        e.icon:Hide(); hideFS(e.main); hideFS(e.sub)
        if e.iconBorder then e.iconBorder:Hide() end
        if e.box:IsShown() or e._wrExpiring then
            e._wrExpiring = nil
            RC.Motion.Stop(e.box)
            e.box:Hide()
        end
    end

    local function renderInto(elem, key, st, group, now)
        local entry = CATALOG[key]
        local countStr
        if entry.stack and group.showCount then countStr = tostring(st.count or 1) end
        local timerStr, rem
        if group.showTimer and st.expiration and st.expiration > 0 then
            rem = st.expiration - now
            if rem < 0 then rem = 0 end
            timerStr = fmtTime(rem)
        end
        local cr, cg, cb = stackColor(st.count or 1)
        local tr, tg, tb = col("exposeArmor", 0.85, 0.85, 0.85)
        local beside = (group.timerPos ~= "under")
        showElem(elem)
        expireCheck(elem, rem)
        local fSize  = gsize(group)
        local smallSize = tsize(group)
        -- Icon tracks the main text size plus a 2px ring so the border
        -- texture has somewhere to sit; baseDrop nudges the smaller timer
        -- up onto the count's baseline instead of its frame bottom.
        local compact = fSize + 2
        local baseDrop = math.floor((fSize - smallSize) * 0.2 + 0.5)

        elem.icon:SetTexture(entry.icon)
        elem.icon:Show()
        elem.iconBorder:SetShown((look().borderSize or 1) > 0)
        elem.main:ClearAllPoints(); elem.sub:ClearAllPoints()
        if countStr and timerStr then
            elem.main:SetTextColor(cr, cg, cb); setFS(elem.main, countStr)
            elem.sub:SetTextColor(tr, tg, tb); setFS(elem.sub, timerStr)
            elem.box:SetSize(compact, compact)
            elem.main:SetPoint("CENTER", elem.icon, "CENTER", 0, 0)
            noteDef("count", "CENTER", elem.icon, "CENTER", 0, 0)
            if beside then
                elem.sub:SetPoint("BOTTOMLEFT", elem.main, "BOTTOMRIGHT", (group.timerGap or 0), baseDrop)
                noteDef("timer", "BOTTOMLEFT", elem.main, "BOTTOMRIGHT", (group.timerGap or 0), baseDrop)
            else
                elem.sub:SetPoint("TOP", elem.main, "BOTTOM", 0, -1)
                noteDef("timer", "TOP", elem.main, "BOTTOM", 0, -1)
            end
        elseif countStr then
            elem.box:SetSize(compact, compact)
            elem.main:SetPoint("CENTER", elem.icon, "CENTER", 0, 0)
            noteDef("count", "CENTER", elem.icon, "CENTER", 0, 0)
            elem.main:SetTextColor(cr, cg, cb); setFS(elem.main, countStr)
            hideFS(elem.sub)
        elseif timerStr then
            elem.box:SetSize(compact, compact)
            hideFS(elem.main)
            elem.sub:SetPoint("CENTER", elem.icon, "CENTER", 0, 0)
            noteDef("timer", "CENTER", elem.icon, "CENTER", 0, 0)
            elem.sub:SetTextColor(tr, tg, tb); setFS(elem.sub, timerStr)
        else
            elem.box:SetSize(compact, compact)
            hideFS(elem.main); hideFS(elem.sub)
        end
        -- a count / timer the settings moved
        placeIconTexts(elem, countStr and elem.main or nil, timerStr and elem.sub or nil)
    end

    -- Hard cap on icons per row: ten at default size already spans a full
    -- nameplate width, and slots are pooled per plate for the session.
    local ROW_MAX = 10
    local function renderGroup(plate, group, now)
        local g = plate.wrGroups and plate.wrGroups[group.id]
        if not g then return end

        if not group.enabled then
            hideElem(g)
            if g.slots then for _, s in ipairs(g.slots) do hideElem(s) end end
            g.activeKey, g.expiration = nil, 0
            return
        end

        local n = collectActive(plate, group)
        local anchorTo = plate.wrBar or plate

        if (group.mode or "single") == "row" then
            -- Row mode never draws the group's own element - slots 1..n do
            -- the drawing - so it is hidden rather than left stale.
            hideElem(g)
            g.activeKey, g.expiration = nil, 0
            -- Insertion sort by firstSeen (oldest applied first). Icons must
            -- hold their slot as neighbours expire, otherwise the row
            -- reshuffles under the cursor every time one debuff drops.
            for i = 2, n do
                local ak, as = _ak[i], _as[i]
                local fa = as.firstSeen or 0
                local j = i - 1
                while j >= 1 and (_as[j].firstSeen or 0) > fa do
                    _ak[j + 1] = _ak[j]; _as[j + 1] = _as[j]
                    j = j - 1
                end
                _ak[j + 1] = ak; _as[j + 1] = as
            end
            if n > ROW_MAX then n = ROW_MAX end
            local sz = gsize(group) + 2
            local gap = 2
            local step = sz + gap
            local ep, rp = anchorPoints(group)
            local dir = group.growDir or "right"
            local horiz = (dir == "left" or dir == "right")
            local sign  = (dir == "left" or dir == "down") and -1 or 1
            -- Half an icon of lead-in so the configured offset lands on the
            -- row's leading EDGE, matching where the single-icon mode of the
            -- same offset puts its centre.
            local baseX = (group.offsetX or 0) + (horiz and (sign * sz / 2) or 0)
            local baseY = (group.offsetY or 0) + (horiz and 0 or (sign * sz / 2))
            for i = 1, n do
                if not (g.slots and g.slots[i]) then ensureSlot(plate, group, i) end
                local s = g.slots[i]
                local off = sign * (i - 1) * step
                placeBox(s, ep, anchorTo, rp, baseX + (horiz and off or 0), baseY + (horiz and 0 or off))
                renderInto(s, _ak[i], _as[i], group, now)
            end
            if g.slots then
                for i = n + 1, #g.slots do hideElem(g.slots[i]) end
            end
            return
        end

        if g.slots then for _, s in ipairs(g.slots) do hideElem(s) end end
        if n == 0 then
            hideElem(g)
            g.activeKey, g.expiration = nil, 0
            return
        end
        local key, st = _ak[1], _as[1]
        g.activeKey  = key
        g.expiration = st.expiration or 0

        if group.showIcon then
            local ep, rp = anchorPoints(group)
            placeBox(g, ep, anchorTo, rp, group.offsetX or 0, group.offsetY or 0)
            renderInto(g, key, st, group, now)
        else
            g.icon:Hide()
            if g.iconBorder then g.iconBorder:Hide() end
            showElem(g)
            local ep, rp = anchorPoints(group)
            local entry = CATALOG[key]
            local countStr
            if entry.stack and group.showCount then
                countStr = tostring(st.count or 1)
            elseif entry.label and group.showCount then
                countStr = entry.label
            end
            local timerStr, rem
            if group.showTimer and st.expiration and st.expiration > 0 then
                rem = st.expiration - now
                if rem < 0 then rem = 0 end
                timerStr = fmtTime(rem)
            end
            expireCheck(g, rem)
            local cr, cg, cb = stackColor(st.count or 1)
            local tr, tg, tb = col("exposeArmor", 0.85, 0.85, 0.85)
            if countStr then
                g.main:ClearAllPoints()
                g.main:SetPoint(ep, anchorTo, rp, group.offsetX or 0, group.offsetY or 0)
                g.main:SetTextColor(cr, cg, cb)
                setFS(g.main, countStr)
                if timerStr then
                    local fSize = gsize(group)
                    local smallSize = tsize(group)
                    local baseDrop = math.floor((fSize - smallSize) * 0.2 + 0.5)
                    g.sub:ClearAllPoints()
                    g.sub:SetPoint("BOTTOMLEFT", g.main, "BOTTOMRIGHT", (group.timerGap or 0), baseDrop)
                    g.sub:SetTextColor(tr, tg, tb)
                    setFS(g.sub, timerStr)
                else
                    hideFS(g.sub)
                end
            elseif timerStr then
                g.main:ClearAllPoints()
                g.main:SetPoint(ep, anchorTo, rp, group.offsetX or 0, group.offsetY or 0)
                g.main:SetTextColor(tr, tg, tb)
                setFS(g.main, timerStr)
                hideFS(g.sub)
            else
                hideFS(g.main); hideFS(g.sub)
            end
        end
    end

    local function scanPlate(unit)
        local plate = NA.activeUnits[unit]
        if not plate then return false end
        local aura = plate.wrAura
        for _, st in pairs(aura) do
            st._wp = st.present; st._wc = st.count; st._we = st.expiration
            st.present = false
        end
        local now = GetTime()
        -- 40 is the client's aura index ceiling; nm going nil ends the list.
        -- Matching is an exact lookup of the localized aura name in
        -- NA.byName, so a renamed or reworded aura simply stops resolving.
        for i = 1, 40 do
            local nm, _, count, _, duration, expiration = UnitDebuff(unit, i)
            if not nm then break end
            local key = NA.byName[nm]
            if key then
                local st = aura[key]
                if not st then st = {}; aura[key] = st end
                if not st.firstSeen then
                    -- Back-date to the real application time so row order
                    -- survives a plate that only came into view mid-debuff.
                    if duration and duration > 0 and expiration and expiration > 0 then
                        st.firstSeen = expiration - duration
                    else
                        st.firstSeen = now
                    end
                end
                st.present = true
                st.count = count or 1
                st.expiration = expiration or 0
            end
        end
        for _, st in pairs(aura) do
            if not st.present then st.firstSeen = nil end
        end

        local op = aura.overpower
        if NA.opGUID and Readycheck.SafeGUID(unit) == NA.opGUID and (NA.opUntil or 0) > now then
            if not op then op = {}; aura.overpower = op end
            if not op.present then op.firstSeen = (NA.opUntil or now) - 5 end
            op.present = true
            op.count = 1
            op.expiration = NA.opUntil or 0
        elseif op then
            op.present = false
            op.firstSeen = nil
        end

        local ex = aura.execute
        if plate.wrExecOn then
            if not ex then ex = {}; aura.execute = ex end
            if not ex.present then ex.firstSeen = now end
            ex.present = true
            ex.count = 1
            ex.expiration = 0
        elseif ex then
            ex.present = false
            ex.firstSeen = nil
        end

        -- _wp/_wc/_we snapshot the pre-scan state; the diff below is what
        -- keeps a 0.2s ticker from re-laying out every plate every tick.
        local changed = false
        for _, st in pairs(aura) do
            if st.present ~= st._wp
               or (st.present and (st.count ~= st._wc or st.expiration ~= st._we)) then
                changed = true
            end
            st._wp = nil; st._wc = nil; st._we = nil
        end
        return changed
    end

    local function rescanAndRender(unit, now)
        local plate = NA.activeUnits[unit]
        if not plate then return end
        if scanPlate(unit) or plate._wrForceRender then
            plate._wrForceRender = nil
            for _, group in ipairs(cfg().groups) do
                local g = plate.wrGroups[group.id]
                if g then g.lastSec = nil; g.rowSec = nil end
                renderGroup(plate, group, now)
            end
        end
    end

    local function updateOverpower()
        if not NA.opName then return end
        if not (NA.opGroup and NA.opGroup.enabled) then return end
        local guid = UnitExists("target") and Readycheck.SafeGUID("target")
        if guid and not isBossUnit("target") then guid = nil end
        local usable, noPower = false, false
        if guid then usable, noPower = IsUsableSpell(NA.opName) end
        -- Form 1 is Battle Stance, the only stance Overpower is castable in.
        -- Out of it IsUsableSpell always says no, so the 5s dodge window has
        -- to be carried by hand until the warrior stances back.
        local outOfStance = GetShapeshiftForm() ~= 1
        local windowAlive = outOfStance and NA.opGUID == guid and (NA.opUntil or 0) > GetTime()
        local clog = guid and NA.opDodgeGUID == guid and (NA.opDodgeUntil or 0) > GetTime()
        local proc = guid and ((usable or noPower) or windowAlive or clog) and true or false
        local prevGUID = NA.opGUID
        if proc then
            -- 5s is the Overpower proc window after a dodge.
            if not NA.opActive or NA.opGUID ~= guid then
                NA.opUntil = GetTime() + 5
            end
            NA.opGUID = guid
        else
            NA.opGUID = nil
            NA.opUntil = 0
        end
        NA.opActive = proc
        if prevGUID ~= NA.opGUID then
            if prevGUID then NA:MarkDirtyByGUID(prevGUID) end
            if NA.opGUID then NA:MarkDirtyByGUID(NA.opGUID) end
        end
    end

    -- CLEU is registered only while a warrior in Battle Stance is in combat
    -- with a boss target, and unregistered the moment any of that stops.
    -- Project rule reserves COMBAT_LOG_EVENT_UNFILTERED for RC.KillWatch;
    -- this is the one other reader, kept narrow by the gate below.
    local function updateOPClog()
        local want = NA.isWarrior and NA.opGroup and NA.opGroup.enabled
                     and GetShapeshiftForm() ~= 1
                     and UnitAffectingCombat("player")
                     and UnitExists("target") and isBossUnit("target")
                     and not _G.READYCHECK_IS_FOREVER   -- (no combat log on WoW Forever)
                     and RC:FeatureOn("overpower_dodge")
        if want and not NA.opClogOn then
            NA.frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            NA.opClogOn = true
        elseif not want and NA.opClogOn then
            NA.frame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            NA.opClogOn = false
            NA.opDodgeGUID, NA.opDodgeUntil = nil, 0
        end
    end
    NA.UpdateOPClog = updateOPClog

    local function updateExecute()
        if not (NA.execGroup and NA.execGroup.enabled) then return end
        for unit, plate in pairs(NA.activeUnits) do
            if plate.wrIsBoss then
                -- 20% is the Execute threshold; health is polled from the
                -- ticker rather than driven off UNIT_HEALTH, which storms.
                -- (nil while Forever hides the health in combat)
                local hp, hpMax = RC:SafeHealth(unit)
                local execOn = (hp and hpMax and hpMax > 0 and (hp / hpMax) <= 0.20) or false
                if plate.wrExecOn ~= execOn then
                    plate.wrExecOn = execOn
                    NA.dirty[unit] = true
                    NA.hasDirty = true
                end
            end
        end
    end

    local function tick()
        local now = GetTime()
        local secNow = floor(now)

        updateOverpower()
        updateExecute()

        -- All the real work lives here in the 0.2s ticker. UNIT_AURA only
        -- flags a unit dirty; at most 12 plates are rescanned per tick and
        -- the rest carry over to the next one, so a pull that lights up
        -- forty plates at once cannot spike a single frame.
        if NA.hasDirty then
            NA.hasDirty = false
            local dirty = NA.dirty
            local budget = 12
            for unit in pairs(dirty) do
                dirty[unit] = nil
                rescanAndRender(unit, now)
                budget = budget - 1
                if budget <= 0 then
                    if next(dirty) then NA.hasDirty = true end
                    break
                end
            end
        end

        local groups = cfg().groups
        for _, plate in pairs(NA.activeUnits) do
            local pg = plate.wrGroups
            if pg then
                -- Scale and timer text are both refreshed at most once per
                -- whole second per plate; secNow is the gate that stops the
                -- 0.2s ticker doing five identical redraws for each of them.
                if plate._wrScaleSec ~= secNow then
                    plate._wrScaleSec = secNow
                    refreshScale(plate)
                end
                for _, group in ipairs(groups) do
                    if group.enabled and group.showTimer then
                        local g = pg[group.id]
                        if g then
                            if (group.mode or "single") == "row" then
                                if g.rowSec ~= secNow then
                                    g.rowSec = secNow
                                    renderGroup(plate, group, now)
                                end
                            elseif g.activeKey and g.expiration > 0 then
                                local sec = ceil(g.expiration - now)
                                if sec ~= g.lastSec then
                                    g.lastSec = sec
                                    renderGroup(plate, group, now)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Everything this module draws - armor debuffs, taunts, the Overpower
    -- and Execute cues - belongs on something you can hit. A raid with
    -- friendly nameplates on has as many friendly plates as mob plates,
    -- and tracking those meant building icons for forty raid members and
    -- spending the 12-plates-a-tick scan budget on their debuffs while
    -- the mobs' sunder counts waited. Friendly plates are only remembered
    -- (NA.friendly) so a reaction change - mind control, a duel - can
    -- bring the unit in; UNIT_FACTION re-asks.
    local function tracksUnit(unit)
        return (UnitCanAttack("player", unit) or not UnitIsFriend("player", unit))
            and true or false
    end

    function NA:OnAdded(unit)
        if not (C_NamePlate and C_NamePlate.GetNamePlateForUnit) then return end
        local plate = C_NamePlate.GetNamePlateForUnit(unit)
        if not plate then return end
        if not tracksUnit(unit) then
            if self.activeUnits[unit] then self:OnRemoved(unit) end
            self.friendly[unit] = true
            return
        end
        self.friendly[unit] = nil
        self.activeUnits[unit] = plate
        plate.wrIsBoss = isBossUnit(unit)
        plate.wrExecOn = false
        plate._wrForceRender = true
        ensurePlate(plate)
        self.dirty[unit] = true
        self.hasDirty = true
    end

    local function hideAll(plate)
        if plate.wrGroups then
            for _, g in pairs(plate.wrGroups) do
                hideElem(g)
                if g.slots then for _, s in ipairs(g.slots) do hideElem(s) end end
                g.activeKey, g.expiration = nil, 0
            end
        end
    end

    function NA:OnRemoved(unit)
        local plate = self.activeUnits[unit]
        if plate then hideAll(plate) end
        self.activeUnits[unit] = nil
        self.friendly[unit] = nil
        self.dirty[unit] = nil
    end

    function NA:MarkDirty(unit)
        if self.activeUnits[unit] then
            self.dirty[unit] = true
            self.hasDirty = true
        end
    end

    function NA:MarkDirtyByGUID(guid)
        if not guid then return end
        for unit in pairs(self.activeUnits) do
            if Readycheck.SafeGUID(unit) == guid then
                self.dirty[unit] = true
                self.hasDirty = true
            end
        end
    end

    function NA:RefreshAll()
        if not (C_NamePlate and C_NamePlate.GetNamePlates) then return end
        for _, p in ipairs(C_NamePlate.GetNamePlates()) do
            local unit = p.namePlateUnitToken
            if unit and tracksUnit(unit) then
                self.friendly[unit] = nil
                self.activeUnits[unit] = p
                p.wrIsBoss = isBossUnit(unit)
                p.wrExecOn = false
                p._wrForceRender = true
                ensurePlate(p)
                self.dirty[unit] = true
            elseif unit then
                if self.activeUnits[unit] then self:OnRemoved(unit) end
                self.friendly[unit] = true
            end
        end
        self.hasDirty = true
    end

    function NA:ApplyVisualSettings()
        NA.lookSig = NA.lookSig + 1
        resolveCatalog()
        for unit, plate in pairs(self.activeUnits) do
            ensurePlate(plate)
            self.dirty[unit] = true
        end
        self.hasDirty = true
    end

    ------------------------------------------------------------------
    -- THE SETTINGS SAMPLE: the same renderer (newElem, styleElem,
    -- renderGroup) drawing every group onto a fake plate - a holder and a
    -- bar on the preview canvas - with made-up debuffs: a 5-stack, a
    -- timer, the first enabled member of each single group, up to three
    -- (one per variant) of each row group. Registers nothing, joins no
    -- live list, never ticks.
    ------------------------------------------------------------------
    function NA.NewSample(holder, bar)
        return { wrAnchor = holder, wrBar = bar, wrGroups = {}, wrAura = {}, sample = true }
    end

    -- expiring = true puts every timer inside the expiring window.
    function NA.DrawSample(fake, expiring)
        resolveCatalog()
        NA.lookSig = NA.lookSig + 1
        local now = GetTime()
        local aura = fake.wrAura
        for _, st in pairs(aura) do st.present = false end
        local groups = cfg().groups
        for _, group in ipairs(groups) do
            local want = ((group.mode or "single") == "row") and 3 or 1
            local n, seenVariant = 0, {}
            for _, key in ipairs(group.members or {}) do
                local entry = CATALOG[key]
                if entry and memberEnabled(group, key) and n < want then
                    local v = entry.variant
                    if not (v and seenVariant[v]) then
                        if v then seenVariant[v] = true end
                        n = n + 1
                        local st = aura[key] or {}
                        aura[key] = st
                        st.present = true
                        st.count = entry.stack and 5 or 1
                        local secs = expiring and (1.5 + n) or (16.5 + n)
                        st.expiration = entry.proc and (key == "execute" and 0 or now + 3.5) or now + secs
                        st.firstSeen = n
                    end
                end
            end
        end
        for _, group in ipairs(groups) do
            local g = fake.wrGroups[group.id]
            if not g then
                g = newElem(fake.wrAnchor)
                g.slots = {}
                fake.wrGroups[group.id] = g
            end
            positionGroup(fake, group)
            for _, sl in ipairs(g.slots) do styleElem(sl, group) end
            renderGroup(fake, group, now)
        end
        -- groups since removed
        for id, g in pairs(fake.wrGroups) do
            local live = false
            for _, group in ipairs(groups) do if group.id == id then live = true break end end
            if not live then
                hideElem(g)
                for _, sl in ipairs(g.slots or {}) do hideElem(sl) end
            end
        end
    end

    -- Replays the entrance on every element showing.
    function NA.ReplaySample(fake)
        local spec = RC.Motion.Normalize(look().showAnim, NA.SHOW_ANIM)
        local function one(e)
            if e and e.box:IsShown() then
                e._wrExpiring = nil
                RC.Motion.Stop(e.box)
                e.box:Hide()
                RC.Motion.Show(e.box, spec)
            end
        end
        for _, g in pairs(fake.wrGroups) do
            one(g)
            for _, sl in ipairs(g.slots or {}) do one(sl) end
        end
    end

    NA.frame = NA.frame or CreateFrame("Frame")
    NA.frame:SetScript("OnEvent", function(_, event, arg1)
        if event == "NAME_PLATE_UNIT_ADDED" then
            NA:OnAdded(arg1)
        elseif event == "NAME_PLATE_UNIT_REMOVED" then
            NA:OnRemoved(arg1)
        -- High-frequency event: flag only, never scan here.
        elseif event == "UNIT_AURA" then
            NA:MarkDirty(arg1)
        -- A plate changed sides while it was up: let OnAdded decide again.
        elseif event == "UNIT_FACTION" then
            if NA.friendly[arg1] or NA.activeUnits[arg1] then NA:OnAdded(arg1) end
        elseif event == "PLAYER_TARGET_CHANGED" then
            updateOverpower()
            updateOPClog()
        elseif event == "SPELL_UPDATE_USABLE" then
            updateOverpower()
        elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
            local _, sub, _, srcGUID, _, _, _, dstGUID = CombatLogGetCurrentEventInfo()
            if srcGUID == NA.playerGUID then
                local tg = UnitExists("target") and Readycheck.SafeGUID("target")
                if tg and dstGUID == tg then
                    -- missType sits at payload arg 1 for both, which is
                    -- absolute index 12 for SWING_* and 15 for the SPELL_*
                    -- and RANGE_* forms (spellId, name, school take 3).
                    local miss
                    if sub == "SWING_MISSED" then
                        miss = select(12, CombatLogGetCurrentEventInfo())
                    elseif sub == "SPELL_MISSED" or sub == "RANGE_MISSED" then
                        miss = select(15, CombatLogGetCurrentEventInfo())
                    end
                    if miss == "DODGE" then
                        NA.opDodgeGUID, NA.opDodgeUntil = tg, GetTime() + 5
                        updateOverpower()
                    end
                end
            end
        elseif event == "UPDATE_SHAPESHIFT_FORM" then
            updateOPClog()
        elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
            updateOPClog()
        elseif event == "PLAYER_ENTERING_WORLD" then
            NA.playerGUID = UnitGUID("player")
            updateOPClog()
            NA:RefreshAll()
        end
    end)

    function NA:Start()
        if not cfg().enabled then self:Stop(); return end
        resolveCatalog()
        local f = self.frame
        f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
        f:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
        f:RegisterEvent("UNIT_AURA")
        f:RegisterEvent("UNIT_FACTION")
        f:RegisterEvent("PLAYER_TARGET_CHANGED")
        f:RegisterEvent("SPELL_UPDATE_USABLE")
        f:RegisterEvent("PLAYER_ENTERING_WORLD")
        f:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
        f:RegisterEvent("PLAYER_REGEN_DISABLED")
        f:RegisterEvent("PLAYER_REGEN_ENABLED")
        self.playerGUID = UnitGUID("player")
        -- Single 0.2s ticker drives every scan, timer tick and rescale for
        -- all plates; nothing in this file redraws straight off an event.
        if not self.ticker then
            if RC.Profiler and RC.Profiler.TrackTicker then
                self.ticker = RC.Profiler:TrackTicker("NameplateAuras", 0.2, tick)
            else
                self.ticker = C_Timer.NewTicker(0.2, tick)
            end
        end
        self:RefreshAll()
        updateOPClog()
    end

    function NA:Stop()
        self.frame:UnregisterAllEvents()
        if self.ticker then self.ticker:Cancel(); self.ticker = nil end
        for _, plate in pairs(self.activeUnits) do hideAll(plate) end
        self.activeUnits = {}
        self.friendly = {}
        self.dirty = {}
        self.hasDirty = false
        self.opGUID = nil
        self.opUntil = 0
        self.opActive = false
        self.opClogOn = false
        self.opDodgeGUID = nil
        self.opDodgeUntil = 0
    end

    function NA:SetEnabled(on)
        local c = cfg()
        c.enabled = on and true or false
        if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
        if c.enabled then self:Start() else self:Stop() end
    end

    function NA:ResetGroups()
        cfg().groups = defaultGroups()
        if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
        self:ApplyVisualSettings()
    end

    function NA:DropGroup(id)
        if not id then return end
        for _, plate in pairs(self.activeUnits) do
            local g = plate.wrGroups and plate.wrGroups[id]
            if g then
                hideElem(g)
                if g.slots then for _, s in ipairs(g.slots) do hideElem(s) end end
                plate.wrGroups[id] = nil
            end
        end
    end

    function NA:AddCustomDebuff(spellID, stack)
        spellID = tonumber(spellID)
        if not spellID or spellID <= 0 then return nil, "invalid" end
        local name = GetSpellInfo(spellID)
        if not name then return nil, "unknown" end
        local key = "cd" .. spellID
        local c = cfg()
        c.custom = c.custom or {}
        c.custom[key] = { spellID = spellID, stack = stack and true or false }
        local e = CATALOG[key] or {}
        e.spellID = spellID
        e.stack = stack and true or nil
        e.custom = true
        CATALOG[key] = e
        resolveCatalog()
        if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
        self:ApplyVisualSettings()
        return key, name
    end

    function NA:RemoveCustomDebuff(key)
        if not key then return end
        local c = cfg()
        if c.custom then c.custom[key] = nil end
        for _, g in ipairs(c.groups) do
            if g.members then
                for i = #g.members, 1, -1 do
                    if g.members[i] == key then table.remove(g.members, i) end
                end
            end
            if g.memberOn then g.memberOn[key] = nil end
        end
        CATALOG[key] = nil
        resolveCatalog()
        if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
        self:ApplyVisualSettings()
    end

    resolveCatalog()
    if cfg().enabled then NA:Start() end
end

InitializeNameplateAuras()

local function InitializeNameplateAurasUI()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.2, InitializeNameplateAurasUI)
        return
    end

    -- NAMEPLATE PREVIEW: a stand-in nameplate (a bar and a name) with
    -- every group drawn on it by the live renderer (NA.NewSample /
    -- NA.DrawSample). Expiring puts every timer in the highlight window.
    local NP_W, NP_H = 200, 70   -- update sizes the canvas to what is drawn
    local function NPPreviewBuild(canvas, P)
        local NA = RC.nameplateAuras
        if not (NA and NA.NewSample) then return end
        local holder = CreateFrame("Frame", nil, canvas)
        holder:SetSize(10, 10)   -- only a parent: everything is placed off the bar
        holder:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        local bar = CreateFrame("StatusBar", nil, holder)
        bar:SetSize(120, 10)
        bar:SetPoint("CENTER", holder, "CENTER", 0, 0)
        bar:SetMinMaxValues(0, 1)
        bar:SetValue(0.7)
        bar.bg = bar:CreateTexture(nil, "BACKGROUND")
        bar.bg:SetAllPoints()
        bar.bg:SetTexture(RC.UI.FLAT)
        bar.border = RC.UI:CreateSimpleBorder(bar, 1)
        bar.name = RC:CreateFontString(holder, "OVERLAY", nil, 10)
        bar.name:SetPoint("BOTTOM", bar, "TOP", 0, 2)
        bar.name:SetText(RCL["Target"])
        P.store.holder, P.store.bar = holder, bar
        P.store.fake = NA.NewSample(holder, bar)
    end
    local function NPPreviewUpdate(canvas, P)
        local NA, st = RC.nameplateAuras, P.store
        if not (NA and st.fake) then return end
        RC:ApplyBarTexture(st.bar, nil)
        local r = RC:GetColor("text", "red")
        st.bar:SetStatusBarColor(r.r, r.g, r.b, 1)
        local e = RC:GetColor("ui", "elementBackground")
        st.bar.bg:SetVertexColor(e.r, e.g, e.b, 1)
        local g = RC:GetColor("text", "gold")
        st.bar.name:SetTextColor(g.r, g.g, g.b, 1)
        NA.DrawSample(st.fake, P.mode == "expiring")
        -- the canvas is the plate and its groups (where the settings put
        -- them), centred; the strip scales it
        local cx, cy, w, h = P.Measure(st.holder)
        if cx then
            st.holder:ClearAllPoints()
            st.holder:SetPoint("CENTER", canvas, "CENTER", -cx, -cy)
            P.Resize(w + 2, h + 2)
        end
    end
    local function NPPreviewReplay(canvas, P)
        local NA, st = RC.nameplateAuras, P.store
        if NA and st.fake then NA.ReplaySample(st.fake) end
    end

    function RC:ShowSidebarNameplates(frame, preserveScroll)
        self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        local parent = frame.scrollChild
        local yPos = -20
        local cardY

        local K = RC._disp
        local tab = self._npTab or "auras"
        if tab == "range" and not self.BuildTargetRangeCard then tab = "auras" end
        local P
        if tab ~= "range" then
            P = self.UI:DeclarePreview({
                key = "nameplates.auras", title = RCL["Nameplate debuffs"],
                width = NP_W, height = NP_H,
                build = NPPreviewBuild, update = NPPreviewUpdate, replay = NPPreviewReplay,
                modes = { { id = "normal", label = RCL["Debuffs"] }, { id = "expiring", label = RCL["Expiring"] } },
            })
        end
        -- the title first, then the tabs (the title pins above the preview strip)
        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Nameplates"],
            RCL["Debuff tracking and nameplate behavior for enemy plates"],
            "Interface\\Icons\\Ability_Warrior_Sunder")
        yPos = newY

        do
            local tabs = {
                { "auras", RCL["Debuffs"] }, { "look", RCL["Look"] }, { "text", RCL["Text"] },
                { "animation", RCL["Animation"] },
            }
            if self.BuildTargetRangeCard then tabs[#tabs + 1] = { "range", RCL["Target Range"] } end
            yPos = K.Tabs(parent, yPos, tabs, tab, function(k)
                RC._npTab = k
                RC:ShowSidebarNameplates(frame, true)
            end)
            if tab == "range" then
                yPos = self:BuildTargetRangeCard(parent, yPos, frame)
                if self.UpdateSidebarScrollbar then
                    self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
                end
                return
            end
        end

        local TEXT = (RC.UI and RC.UI.TEXT) or {}
        TEXT.light = TEXT.light or { 0.85, 0.85, 0.85, 1 }
        TEXT.gray  = TEXT.gray  or { 0.6, 0.6, 0.6, 1 }

        local NA = RC.nameplateAuras
        if NA and NA.ResolveCatalog then NA.ResolveCatalog() end
        local catalog = (NA and NA.catalog) or {}
        local c = (NA and NA.cfg and NA.cfg()) or (RC.db and RC.db.nameplateAuras) or {}
        local groups = c.groups or {}

        local function memberOn(group, key)
            if NA and NA.memberEnabled then return NA.memberEnabled(group, key) end
            return group.memberOn == nil or group.memberOn[key] ~= false
        end
        local function groupHasStack(group)
            for _, k in ipairs(group.members) do
                local e = catalog[k]
                if e and e.stack then return true end
            end
            return false
        end
        local function firstEnabled(group)
            for _, k in ipairs(group.members) do
                if memberOn(group, k) then return k end
            end
            return group.members[1]
        end
        local function apply()
            if RC.nameplateAuras then RC.nameplateAuras:ApplyVisualSettings() end
        end
        local function rebuild()
            RC:ShowSidebarNameplates(frame, true)
        end

        local function newGroupId()
            local n = 1
            while true do
                local id = "custom" .. n
                local used = false
                for _, g in ipairs(groups) do if g.id == id then used = true; break end end
                if not used then return id end
                n = n + 1
            end
        end

        local function removeMemberFromAll(key)
            for _, g in ipairs(groups) do
                if g.members then
                    for i = #g.members, 1, -1 do
                        if g.members[i] == key then table.remove(g.members, i) end
                    end
                end
                if g.memberOn then g.memberOn[key] = nil end
            end
        end

        local function nameInput(card, group, y)
            -- Framework widget: themed backdrop/border and focus highlight
            -- come from CreateStyledEditBox instead of hand-rolled colors.
            local cont = self.UI:CreateStyledEditBox(card, {
                width = 210, height = 22, font = 11, maxLetters = 40,
                initialText = group.name or RCL["Group"],
            })
            cont:SetPoint("TOPLEFT", card, "TOPLEFT", 52, y + 3)
            local eb = cont.editBox
            eb:SetScript("OnEnterPressed", function(s)
                local t = (s:GetText() or "")
                t = t:match("^%s*(.-)%s*$") or t
                if t == "" then t = group.name or "Group" end
                group.name = t
                s:ClearFocus()
                RC:SaveConfigurationToProfile()
                rebuild()
            end)
            eb:SetScript("OnEscapePressed", function(s) s:ClearFocus(); s:SetText(group.name or RCL["Group"]) end)
            local lbl = self:CreateFontString(card, "OVERLAY", nil, 10)
            lbl:SetPoint("RIGHT", cont, "LEFT", -6, 0)
            lbl:SetText(RCL["Name"])
            lbl:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            return cont
        end


        if tab == "auras" then
        local enableCard = self:CreateSettingsCard(parent, yPos, RCL["Nameplate debuffs"])
        cardY = -35

        local enableCheck = self.UI:CreateCheckbox(enableCard, RCL["Show debuffs on enemy nameplates"], c.enabled)
        enableCheck:SetPoint("TOPLEFT", enableCard, "TOPLEFT", 15, cardY)
        enableCheck:SetScript("OnClick", function(cb)
            local on = cb:GetChecked()
            RC:ForceCheckboxUpdate(cb, on)
            if RC.nameplateAuras then RC.nameplateAuras:SetEnabled(on) end
            RC:ShowSidebarNameplates(frame, true)
        end)
        cardY = cardY - 28

        local note = self:CreateFontString(enableCard, "OVERLAY", nil, 10)
        note:SetPoint("TOPLEFT", enableCard, "TOPLEFT", 15, cardY)
        note:SetWidth(enableCard:GetWidth() - 30)
        note:SetJustifyH("LEFT")
        note:SetText(RCL["Requires enemy nameplates to be on (default key: V). Only the nameplates currently on screen are tracked."])
        note:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
        cardY = cardY - 34

        local resetBtn = RC.UI:CreateStyledButton(enableCard, RCL["Reset groups to defaults"], 220, 24)
        resetBtn:SetPoint("TOPLEFT", enableCard, "TOPLEFT", 15, cardY)
        resetBtn:SetScript("OnClick", function()
            RC.UI:CreateConfirmDialog(RCL["Reset Groups"],
                RCL["Put every debuff group back to the defaults?\n\nGroups you made and any group positions are lost. This cannot be undone."],
                function()
                    if RC.nameplateAuras and RC.nameplateAuras.ResetGroups then
                        RC.nameplateAuras:ResetGroups()
                    end
                    RC:ShowSidebarNameplates(frame, true)
                end,
                nil, RCL["Reset"], true)
        end)
        cardY = cardY - 32

        enableCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - enableCard:GetHeight() - 15
        -- the debuff groups below only show with the nameplate debuffs on:
        -- their cards are greyed with the switch (not set in)
        local groupsMark = RC.UI:MarkCard(parent)

        frame.npExpanded = frame.npExpanded or {}
        for _, group in ipairs(groups) do
            local expanded = frame.npExpanded[group.id]
            local card = self:CreateSettingsCard(parent, yPos, nil)
            cardY = -14

            local hdr = CreateFrame("Button", nil, card)
            hdr:SetPoint("TOPLEFT",  card, "TOPLEFT",  10, cardY)
            hdr:SetPoint("TOPRIGHT", card, "TOPRIGHT", -120, cardY)
            hdr:SetHeight(20)
            local caret = hdr:CreateTexture(nil, "ARTWORK")
            caret:SetSize(10, 10)
            caret:SetPoint("LEFT", hdr, "LEFT", 0, 0)
            caret:SetTexture("Interface\\AddOns\\Readycheck\\Media\\" .. (expanded and "arrow" or "arrowRight"))
            local gold = RC:GetColor("ui", "accentGold") or { r = 1, g = 0.82, b = 0 }
            caret:SetVertexColor(gold.r, gold.g, gold.b)
            local hname = self:CreateFontString(hdr, "OVERLAY", nil, 12)
            hname:SetPoint("LEFT", caret, "RIGHT", 8, 0)
            hname:SetText(group.name or RCL["Group"])
            local htc = RC:GetColor("ui", "headerText") or { r = 1, g = 0.82, b = 0 }
            hname:SetTextColor(htc.r, htc.g, htc.b)
            local summ = self:CreateFontString(hdr, "OVERLAY", nil, 10)
            summ:SetPoint("LEFT", hname, "RIGHT", 10, 0)
            summ:SetText(#group.members .. RCL[" debuff"] .. (#group.members == 1 and "" or "s")
                .. (group.enabled and "" or "  -  off"))
            do local _dc = RC:GetColor("text", "disabled"); summ:SetTextColor(_dc.r, _dc.g, _dc.b, 1) end
            hdr:SetScript("OnClick", function()
                frame.npExpanded[group.id] = not expanded
                RC:ShowSidebarNameplates(frame, true)
            end)

            local onoff = self.UI:CreateStyledButton(card, group.enabled and RCL["On"] or RCL["Off"], 40, 20)
            onoff:SetPoint("TOPRIGHT", card, "TOPRIGHT", -38, cardY)
            onoff:SetScript("OnClick", function()
                group.enabled = not group.enabled
                RC:SaveConfigurationToProfile()
                apply()
                RC:ShowSidebarNameplates(frame, true)
            end)

            local delBtn = self.UI:CreateRemoveButton(card, 20, function()
                self.UI:CreateConfirmDialog(
                    RCL["Delete group"],
                    RCL["Delete the \""] .. (group.name or "group") .. RCL["\" group? Its debuffs become unassigned -- you can add them to another group afterward."],
                    function()
                        for i = #groups, 1, -1 do
                            if groups[i].id == group.id then table.remove(groups, i) end
                        end
                        if RC.nameplateAuras and RC.nameplateAuras.DropGroup then
                            RC.nameplateAuras:DropGroup(group.id)
                        end
                        RC:SaveConfigurationToProfile()
                        apply(); rebuild()
                    end,
                    nil, RCL["Delete"], true)
            end)
            delBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, cardY + 2)
            cardY = cardY - 26

            if expanded then
            nameInput(card, group, cardY)
            cardY = cardY - 28

            local iconChk = self.UI:CreateCheckbox(card, RCL["Show icon"], group.showIcon)
            iconChk:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
            iconChk:SetScript("OnClick", function(cb)
                local on = cb:GetChecked()
                RC:ForceCheckboxUpdate(cb, on)
                group.showIcon = on
                RC:SaveConfigurationToProfile()
                apply()
            end)

            local timerChk = self.UI:CreateCheckbox(card, RCL["Show timer"], group.showTimer)
            timerChk:SetPoint("TOPLEFT", card, "TOPLEFT", 130, cardY)
            timerChk:SetScript("OnClick", function(cb)
                local on = cb:GetChecked()
                RC:ForceCheckboxUpdate(cb, on)
                group.showTimer = on
                RC:SaveConfigurationToProfile()
                apply()
            end)
            cardY = cardY - 28

            if groupHasStack(group) then
                local cntChk = self.UI:CreateCheckbox(card, RCL["Show stack count"], group.showCount)
                cntChk:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                cntChk:SetScript("OnClick", function(cb)
                    local on = cb:GetChecked()
                    RC:ForceCheckboxUpdate(cb, on)
                    group.showCount = on
                    RC:SaveConfigurationToProfile()
                    apply()
                end)
                cardY = cardY - 28

                local tpLabel = self:CreateFontString(card, "OVERLAY", nil, 10)
                tpLabel:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                tpLabel:SetText(RCL["Remaining time position"])
                tpLabel:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY = cardY - 18
                -- Stored config VALUES ("beside", "row", "right", "center")
                -- are plain literals and must never index RCL; only the
                -- display labels go through RCL.
                local tpNames = { under = RCL["Under the count"], beside = RCL["Next to the count"] }
                local tpDD = self.UI:CreateScrollableDropdown(card, 180, tpNames[group.timerPos or "beside"] or RCL["Next to the count"], 2)
                tpDD:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                tpDD:SetItems({
                    { text = RCL["Under the count"], value = "under" },
                    { text = RCL["Next to the count"], value = "beside" },
                }, function(value)
                    group.timerPos = value
                    RC:SaveConfigurationToProfile()
                    apply()
                end)
                if tpDD.SetSearchEnabled then tpDD:SetSearchEnabled(false) end
                cardY = cardY - 40
            end

            local rowChk = self.UI:CreateCheckbox(card, RCL["Icon row (grows with the number of active debuffs)"], (group.mode or "single") == "row")
            rowChk:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
            rowChk:SetScript("OnClick", function(cb)
                local on = cb:GetChecked()
                RC:ForceCheckboxUpdate(cb, on)
                group.mode = on and "row" or "single"
                RC:SaveConfigurationToProfile()
                apply(); rebuild()
            end)
            cardY = cardY - 28

            if (group.mode or "single") == "row" then
                local gdLabel = self:CreateFontString(card, "OVERLAY", nil, 10)
                gdLabel:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                gdLabel:SetText(RCL["Row grows toward"])
                gdLabel:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY = cardY - 18
                local gdNames = { right = RCL["Right"], left = RCL["Left"], up = RCL["Up"], down = RCL["Down"] }
                local gdDD = self.UI:CreateScrollableDropdown(card, 140, gdNames[group.growDir or "right"] or RCL["Right"], 4)
                gdDD:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                gdDD:SetItems({
                    { text = RCL["Right"], value = "right" },
                    { text = RCL["Left"], value = "left" },
                    { text = RCL["Up"], value = "up" },
                    { text = RCL["Down"], value = "down" },
                }, function(value)
                    group.growDir = value
                    RC:SaveConfigurationToProfile()
                    apply()
                end)
                if gdDD.SetSearchEnabled then gdDD:SetSearchEnabled(false) end
                cardY = cardY - 40
            end

            local attachLabel = self:CreateFontString(card, "OVERLAY", nil, 10)
            attachLabel:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
            attachLabel:SetText(RCL["Attach to nameplate (stays put as nameplates resize)"])
            attachLabel:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 18
            local attachNames = { top = RCL["Top edge"], center = RCL["Center"], bottom = RCL["Bottom edge"] }
            local attachDD = self.UI:CreateScrollableDropdown(card, 160, attachNames[group.attach or "center"] or RCL["Center"], 3)
            attachDD:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
            attachDD:SetItems({
                { text = RCL["Top edge"], value = "top" },
                { text = RCL["Center"], value = "center" },
                { text = RCL["Bottom edge"], value = "bottom" },
            }, function(value)
                group.attach = value
                RC:SaveConfigurationToProfile()
                apply()
            end)
            if attachDD.SetSearchEnabled then attachDD:SetSearchEnabled(false) end
            cardY = cardY - 40

            do
                local isCountGroup = groupHasStack(group)

                local szLbl = self:CreateFontString(card, "OVERLAY", nil, 10)
                szLbl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                szLbl:SetText(isCountGroup and RCL["Number text size (icon scales to match)"] or RCL["Text size (icon scales to match)"])
                szLbl:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY = cardY - 16
                local szVal = group.fontSize or c.fontSize or 11
                local szS = self.UI:CreateSlider(card, 8, 30, szVal, 1)
                szS:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                szS.Text:SetText(szVal .. RCL[" pt"])
                szS:SetScript("OnValueChanged", function(sl, v)
                    v = math.floor(v)
                    sl.Text:SetText(v .. RCL[" pt"])
                    group.fontSize = v
                    if sl.saveTimer then sl.saveTimer:Cancel() end
                    sl.saveTimer = C_Timer.NewTimer(0.4, function() RC:SaveConfigurationToProfile() end)
                    apply()
                end)
                cardY = cardY - 40

                local tLbl = self:CreateFontString(card, "OVERLAY", nil, 10)
                tLbl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                tLbl:SetText(RCL["Timer text size"])
                tLbl:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY = cardY - 16
                local tVal = group.timerSize or math.max(7, math.floor((group.fontSize or 11) * 0.6))
                local tS = self.UI:CreateSlider(card, 6, 30, tVal, 1)
                tS:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                tS.Text:SetText(tVal .. RCL[" pt"])
                tS:SetScript("OnValueChanged", function(sl, v)
                    v = math.floor(v)
                    sl.Text:SetText(v .. RCL[" pt"])
                    group.timerSize = v
                    if sl.saveTimer then sl.saveTimer:Cancel() end
                    sl.saveTimer = C_Timer.NewTimer(0.4, function() RC:SaveConfigurationToProfile() end)
                    apply()
                end)
                cardY = cardY - 40

                if isCountGroup then
                    local gLbl = self:CreateFontString(card, "OVERLAY", nil, 10)
                    gLbl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                    gLbl:SetText(RCL["Number / timer gap"])
                    gLbl:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                    cardY = cardY - 16
                    local gVal = group.timerGap or 0
                    local gS = self.UI:CreateSlider(card, -5, 20, gVal, 1)
                    gS:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                    gS.Text:SetText(gVal .. RCL[" px"])
                    gS:SetScript("OnValueChanged", function(sl, v)
                        v = math.floor(v)
                        sl.Text:SetText(v .. RCL[" px"])
                        group.timerGap = v
                        if sl.saveTimer then sl.saveTimer:Cancel() end
                        sl.saveTimer = C_Timer.NewTimer(0.4, function() RC:SaveConfigurationToProfile() end)
                        apply()
                    end)
                    cardY = cardY - 40
                end
            end

            local function offsetSlider(labelText, field, minV, maxV)
                local lbl = self:CreateFontString(card, "OVERLAY", nil, 10)
                lbl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                lbl:SetText(labelText)
                lbl:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY = cardY - 16
                local val = group[field] or 0
                local s = self.UI:CreateSlider(card, minV, maxV, val, 1)
                s:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
                s.Text:SetText(val .. RCL[" px"])
                s:SetScript("OnValueChanged", function(sl, v)
                    v = math.floor(v)
                    sl.Text:SetText(v .. RCL[" px"])
                    group[field] = v
                    if sl.saveTimer then sl.saveTimer:Cancel() end
                    sl.saveTimer = C_Timer.NewTimer(0.4, function() RC:SaveConfigurationToProfile() end)
                    apply()
                end)
                cardY = cardY - 40
            end
            offsetSlider("Horizontal offset", "offsetX", -150, 150)
            offsetSlider("Vertical offset", "offsetY", -100, 100)

            local memLabel = self:CreateFontString(card, "OVERLAY", nil, 10)
            memLabel:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
            memLabel:SetText(RCL["Debuffs in this group (checkbox mutes, X removes):"])
            memLabel:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 20

            for _, key in ipairs(group.members) do
                local entry = catalog[key]
                local nm = (entry and entry.name) or key
                local mChk = self.UI:CreateCheckbox(card, nm, memberOn(group, key))
                mChk:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cardY)
                local mkey = key
                mChk:SetScript("OnClick", function(cb)
                    local on = cb:GetChecked()
                    RC:ForceCheckboxUpdate(cb, on)
                    group.memberOn = group.memberOn or {}
                    group.memberOn[mkey] = on
                    RC:SaveConfigurationToProfile()
                    apply()
                end)
                local rmBtn = self.UI:CreateRemoveButton(card, 16, function()
                    for i = #group.members, 1, -1 do
                        if group.members[i] == mkey then table.remove(group.members, i) end
                    end
                    if group.memberOn then group.memberOn[mkey] = nil end
                    RC:SaveConfigurationToProfile()
                    apply(); rebuild()
                end)
                rmBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -14, cardY - 1)
                cardY = cardY - 26
            end

            do
                local keyGroupName = {}
                for _, g in ipairs(groups) do
                    for _, m in ipairs(g.members or {}) do keyGroupName[m] = g.name end
                end
                local avail = {}
                for k, e in pairs(catalog) do
                    local here = false
                    for _, m in ipairs(group.members) do if m == k then here = true; break end end
                    if not here then
                        local sortk = (e and e.name) or k
                        local label = sortk
                        if keyGroupName[k] then label = label .. "  (in " .. keyGroupName[k] .. ")" end
                        avail[#avail + 1] = { text = label, value = k, sortk = sortk }
                    end
                end
                table.sort(avail, function(a, b) return a.sortk < b.sortk end)
                if #avail > 0 then
                    local addDD = self.UI:CreateScrollableDropdown(card, 240, RCL["+ Add a debuff..."], 8)
                    addDD:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cardY)
                    -- A debuff belongs to exactly one group: adding it here
                    -- pulls it out of whatever group currently holds it.
                    addDD:SetItems(avail, function(value)
                        removeMemberFromAll(value)
                        group.members[#group.members + 1] = value
                        if group.memberOn then group.memberOn[value] = nil end
                        RC:SaveConfigurationToProfile()
                        apply(); rebuild()
                    end)
                    cardY = cardY - 40
                else
                    local allNote = self:CreateFontString(card, "OVERLAY", nil, 10)
                    allNote:SetPoint("TOPLEFT", card, "TOPLEFT", 25, cardY)
                    allNote:SetText(RCL["Every available debuff is already in this group."])
                    allNote:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                    cardY = cardY - 22
                end
            end
            cardY = cardY - 6
            end

            card:SetContentHeight(math.abs(cardY))
            yPos = yPos - card:GetHeight() - 15
        end

        do
            local cc = self:CreateSettingsCard(parent, yPos, RCL["Custom debuffs"])
            cardY = -35
            local cnote = self:CreateFontString(cc, "OVERLAY", nil, 10)
            cnote:SetPoint("TOPLEFT", cc, "TOPLEFT", 15, cardY)
            cnote:SetWidth(cc:GetWidth() - 30)
            cnote:SetJustifyH("LEFT")
            cnote:SetText(RCL["Track any debuff by its spell ID. Once added it appears in every group's \"Add a debuff\" list, so you can place it in any group."])
            cnote:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 32

            c.custom = c.custom or {}
            local customList = {}
            for key, def in pairs(c.custom) do
                if type(def) == "table" and def.spellID then
                    local e = catalog[key]
                    local nm = (e and e.name) or ("Spell " .. def.spellID)
                    customList[#customList + 1] = {
                        key = key,
                        label = nm .. "  (" .. def.spellID .. ")" .. (def.stack and "  [stacks]" or ""),
                        sortk = nm,
                    }
                end
            end
            table.sort(customList, function(a, b) return a.sortk < b.sortk end)
            if #customList > 0 then
                local yl = self:CreateFontString(cc, "OVERLAY", nil, 10)
                yl:SetPoint("TOPLEFT", cc, "TOPLEFT", 15, cardY)
                yl:SetText(RCL["Your custom debuffs:"])
                yl:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                cardY = cardY - 20
                for _, item in ipairs(customList) do
                    local t = self:CreateFontString(cc, "OVERLAY", nil, 10)
                    t:SetPoint("TOPLEFT", cc, "TOPLEFT", 25, cardY)
                    t:SetText(item.label)
                    t:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                    local x = self.UI:CreateRemoveButton(cc, 16, function()
                        if RC.nameplateAuras and RC.nameplateAuras.RemoveCustomDebuff then
                            RC.nameplateAuras:RemoveCustomDebuff(item.key)
                        end
                        rebuild()
                    end)
                    x:SetPoint("TOPRIGHT", cc, "TOPRIGHT", -14, cardY - 1)
                    cardY = cardY - 24
                end
                cardY = cardY - 6
            end

            -- Framework widget (see nameInput above).
            local idCont = self.UI:CreateStyledEditBox(cc, {
                width = 90, height = 22, font = 11, maxLetters = 8,
            })
            idCont:SetPoint("TOPLEFT", cc, "TOPLEFT", 80, cardY + 3)
            local idBox = idCont.editBox
            idBox:SetNumeric(true)
            local idLbl = self:CreateFontString(cc, "OVERLAY", nil, 10)
            idLbl:SetPoint("RIGHT", idCont, "LEFT", -6, 0)
            idLbl:SetText(RCL["Spell ID"])
            idLbl:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 28

            local stackChk = self.UI:CreateCheckbox(cc, RCL["Tracks a stack count"], false)
            stackChk:SetPoint("TOPLEFT", cc, "TOPLEFT", 15, cardY)
            cardY = cardY - 28

            local status = self:CreateFontString(cc, "OVERLAY", nil, 10)
            local addCustomBtn = RC.UI:CreateStyledButton(cc, RCL["Add debuff"], 130, 24)
            addCustomBtn:SetPoint("TOPLEFT", cc, "TOPLEFT", 15, cardY)
            local errC = RC:GetColor("text", "red")
            local function submitCustom()
                local id = tonumber(idBox:GetText())
                if not id or id <= 0 then
                    status:SetText(RCL["Enter a spell ID number."]); status:SetTextColor(errC.r, errC.g, errC.b)
                    return
                end
                if RC.nameplateAuras and RC.nameplateAuras.AddCustomDebuff then
                    local key, nameOrErr = RC.nameplateAuras:AddCustomDebuff(id, stackChk:GetChecked())
                    if key then
                        rebuild()
                    elseif nameOrErr == "unknown" then
                        status:SetText(RCL["No spell found with that ID on this realm."]); status:SetTextColor(errC.r, errC.g, errC.b)
                    else
                        status:SetText(RCL["That spell ID isn't valid."]); status:SetTextColor(errC.r, errC.g, errC.b)
                    end
                end
            end
            addCustomBtn:SetScript("OnClick", submitCustom)
            idBox:SetScript("OnEnterPressed", function(s) s:ClearFocus(); submitCustom() end)
            idBox:SetScript("OnEscapePressed", function(s) s:ClearFocus() end)
            status:SetPoint("LEFT", addCustomBtn, "RIGHT", 10, 0)
            status:SetWidth(190)
            status:SetJustifyH("LEFT")
            cardY = cardY - 32

            cc:SetContentHeight(math.abs(cardY))
            yPos = yPos - cc:GetHeight() - 15
        end

        do
            local addCard = self:CreateSettingsCard(parent, yPos, RCL["Add a group"])
            cardY = -35
            local aNote = self:CreateFontString(addCard, "OVERLAY", nil, 10)
            aNote:SetPoint("TOPLEFT", addCard, "TOPLEFT", 15, cardY)
            aNote:SetWidth(addCard:GetWidth() - 30)
            aNote:SetJustifyH("LEFT")
            aNote:SetText(RCL["Create your own group, then add debuffs to it and position it anywhere on the nameplate."])
            aNote:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 30
            local addBtn = RC.UI:CreateStyledButton(addCard, RCL["New group"], 160, 24)
            addBtn:SetPoint("TOPLEFT", addCard, "TOPLEFT", 15, cardY)
            addBtn:SetScript("OnClick", function()
                local g = {
                    id = newGroupId(),
                    name = "New Group",
                    mode = "row", attach = "center", timerPos = "beside", growDir = "right",
                    offsetX = 0, offsetY = -60,
                    enabled = true, fontSize = 11, timerSize = 7, timerGap = 0,
                    showIcon = true, showCount = true, showTimer = true,
                    members = {},
                }
                groups[#groups + 1] = g
                RC:SaveConfigurationToProfile()
                apply(); rebuild()
            end)
            cardY = cardY - 32
            addCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - addCard:GetHeight() - 15
        end
        RC.UI:BindDependents(enableCheck, RC.UI:CardSince(parent, groupsMark), { indent = 0 })

        elseif tab == "look" then

            local function L() return K.Look(c, "look") end
            local function Apply() if RC.nameplateAuras then RC.nameplateAuras:ApplyVisualSettings() end end
            yPos = K.Card(parent, yPos, RCL["Icons"], function(card, y)
                y = K.Slider(card, y, RCL["Icon border"], 0, 4, L().borderSize or 1, 1,
                    function(v) return v .. RCL[" px"] end,
                    function(v) L().borderSize = v RC:SaveConfigurationToProfile() Apply() end)
                y = K.LookColor(card, y, RCL["Border colour"], L, "borderColor",
                    function() return RC:GetColor("ui", "borderNormal") end, Apply, true)
                y = K.Slider(card, y - 4, RCL["Icon crop"], 0, 0.25, L().zoom or 0.08, 0.01,
                    function(v) return math.floor(v * 100 + 0.5) .. "%" end,
                    function(v) L().zoom = v RC:SaveConfigurationToProfile() Apply() end, 100)
                return K.Desc(card, y + 6, RCL["How much of each icon's edge is trimmed away. Icon size follows each group's text size (Debuffs tab)."])
            end)
            yPos = K.Card(parent, yPos, RCL["Colors"], function(card, y)
                y = K.Desc(card, y, RCL["Stack counts fade from low to high. Other debuff text uses the third color."])
                y = K.ThemeColor(card, y, RCL["Stack low"], "nameplate", "sunderLow", Apply)
                y = K.ThemeColor(card, y, RCL["Stack high"], "nameplate", "sunderHigh", Apply)
                y = K.ThemeColor(card, y, RCL["Debuff text"], "nameplate", "exposeArmor", Apply)
                return y - 4
            end)
        elseif tab == "text" then
            local function L() return K.Look(c, "look") end
            local function Apply() if RC.nameplateAuras then RC.nameplateAuras:ApplyVisualSettings() end end
            yPos = K.Card(parent, yPos, RCL["Text"], function(card, y)
                y = K.Desc(card, y, RCL["Font face, outline and shadow for every group. Sizes are set per group on the Debuffs tab; a size picked here wins over them."])
                y = K.Font(card, y, RCL["Stack count"], function() return L().font end,
                    function(spec) L().font = spec Apply() end, { size = 11, outline = "OUTLINE" }, "5   4   3", 6, 30)
                y = K.Font(card, y, RCL["Timer"], function() return L().timerFont end,
                    function(spec) L().timerFont = spec Apply() end, { size = 7, outline = "OUTLINE" }, "18s  2m", 6, 30)
                return K.Desc(card, y + 4, RCL["The timer uses the stack count's font until it has its own."])
            end)
            -- on the icon: where the count and the timer sit, and how the
            -- timer reads (the customization standard)
            yPos = K.Card(parent, yPos, RCL["Text positions"], function(card, y)
                local cw = card:GetWidth() or 0
                local W = (cw > 240) and math.min(460, cw - 28) or 420
                local function Saved() RC:SaveConfigurationToProfile() Apply() end
                local function Others(ex)
                    local out = {}
                    for _, t in ipairs(RC.NAMEPLATE_TEXT_TARGETS) do if t.value ~= ex then out[#out + 1] = t end end
                    return out
                end
                local ag, as = self.UI:CustomAccess(c, "anchors", "count", Saved)
                local g = self.UI:CreateTextElement(card, { label = RCL["Stack count"], key = "count", width = W,
                    anchorGet = ag, anchorSet = as, targets = Others("count"),
                    defaultTargetLabel = RCL["Where the group puts it"],
                    anchorDefaults = function() return RC:NameplateTextAnchorDefault("count") end })
                g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                y = y - g:GetHeight() - 14
                ag, as = self.UI:CustomAccess(c, "anchors", "timer", Saved)
                local fg, fs = self.UI:CustomAccess(c, "formats", "timer", Saved)
                g = self.UI:CreateTextElement(card, { label = RCL["Timer"], key = "timer", width = W,
                    formatGet = fg, formatSet = fs, formatKinds = { time = true }, formatDefaults = RC.NAMEPLATE_TIMER_FORMAT,
                    formatSample = function(spec) return RC.UI:FormatText(spec, RC.NAMEPLATE_TIMER_FORMAT, { value = 18 }, { value = "time" }, "value") end,
                    anchorGet = ag, anchorSet = as, targets = Others("timer"),
                    defaultTargetLabel = RCL["Where the group puts it"],
                    anchorDefaults = function() return RC:NameplateTextAnchorDefault("timer") end })
                g:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
                y = y - g:GetHeight() - 14
                return K.Desc(card, y + 4, RCL["Places apply to groups that show icons; each group's beside / under choice stays the default."])
            end)
        elseif tab == "animation" then
            local function L() return K.Look(c, "look") end
            local NAx = RC.nameplateAuras
            yPos = K.Card(parent, yPos, RCL["Animation"], function(card, y)
                y = K.Anim(card, y, RCL["When a debuff appears"], "in",
                    function() return L().showAnim end, function(s2) L().showAnim = s2 end,
                    NAx and NAx.SHOW_ANIM, NAx and NAx.ANIM_STYLES, P)
                y = K.Anim(card, y, RCL["While it runs out"], "update",
                    function() return L().expireAnim end, function(s2) L().expireAnim = s2 end,
                    NAx and NAx.EXPIRE_ANIM, NAx and NAx.ANIM_STYLES, nil)
                y = K.Slider(card, y, RCL["Runs out at"], 1, 15, L().expireAt or 5, 1,
                    function(v) return v .. "s" end,
                    function(v) L().expireAt = v RC:SaveConfigurationToProfile() end)
                return K.Desc(card, y + 6, RCL["Only fades and flashes: the icons move with the nameplate, so nothing here slides or grows. Pick Expiring in the preview to see the second one. Appearance > Motion can turn every animation off."])
            end)
        end

        if self.UpdateSidebarScrollbar then
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
        end
    end
end

InitializeNameplateAurasUI()
