------------------------------------------------------------------------
-- Readycheck - Raid Consume Reminders (Consumables > Raid Consume
-- Reminders)
-- In a 40-man raid, the important consumables you are NOT wearing show
-- as icons in the reminders bar's own row, so a missing flask, elixir,
-- food buff or weapon stone is in front of you the whole time it is
-- missing. Ones running out (30s or less, or from when the expiry voice
-- warns) show too, counting down.
--
-- "Important" is a per-item tick on the page. Out of the box (each game
-- version's own picks): a warrior's or rogue's Mongoose, strength and
-- attack-power slots, Zanza, stat food and both weapon stones; casters
-- their flask, mana elixirs, food and Zanza. Items that exclude each
-- other in game count as one slot: any of them up fills it; missing, the
-- icon is the first ticked one you carry. Only what is in your bags shows
-- unless the page says otherwise. Food never shows in combat.
--
-- Plain icons, not buttons; they move with the reminders bar (no spot of
-- their own). Every icon wears the framework's edge glow
-- (RC.UI:CreateEdgeGlow), styled by RC.db.consumeRemindGlow.
--
-- One half-second tracked ticker, out of everything outside a raid.
-- Settings: RC.db.consumeRemind (Database defaults, this character's
-- profile, exported and synced with the consumables bar settings). The
-- items are seeded per class on first use; RC:MigrateConsumeRemind
-- (PM_Cleanup) carries the testing-era RC.db.testConsumeRemind over once.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local CR = {}
RC.ConsumeRemind = CR

local CATEGORIES = { "flasks", "elixirs", "food", "drinks", "buffs" }
local CAT_LABEL = { flasks = RCL["Flasks"], elixirs = RCL["Elixirs"], food = RCL["Food"], drinks = RCL["Drinks & desserts"],
                    buffs = RCL["Jujus, Zanza & world-drop buffs"] }

-- Classic Era picks (Flask of the Titans left off on purpose)
local MELEE_DEFAULT = {
    [13452] = true,                                   -- Mongoose
    [9206] = true, [12451] = true,                    -- Giants / Juju Power (one slot)
    [12460] = true, [12820] = true,                   -- Juju Might / Firewater (one slot)
    [20079] = true, [20080] = true, [20081] = true,   -- the Zanzas
    [8410] = true, [8412] = true,                     -- R.O.I.D.S. / Scorpok (same slot)
    [13810] = true, [20452] = true, [21023] = true,   -- stat foods (one slot)
    mh = true, oh = true,
}
local CASTER_DEFAULT = {
    [13512] = true, [13511] = true,                   -- Supreme Power / Wisdom
    [13454] = true, [20007] = true,                   -- Greater Arcane / Mageblood
    [20079] = true, [20080] = true, [20081] = true, [8423] = true,
    [13810] = true, [20452] = true, [21023] = true, [13931] = true,
}

-- TBC / Forever: that version's own picks (DB_Consumables{TBC,Forever})
local function FlavorDefault(list)
    local t = { mh = (list == "melee") or nil, oh = (list == "melee") or nil }
    for _, id in ipairs(RC.flavorConsumeRemind[list]) do t[id] = true end
    return t
end
if RC.flavorConsumeRemind then
    MELEE_DEFAULT, CASTER_DEFAULT = FlavorDefault("melee"), FlavorDefault("caster")
    CAT_LABEL.buffs = RC:Flavor() == "tbc" and RCL["Scrolls, herbs & other buffs"] or RCL["Jujus & other buffs"]
end

local function IsMelee()
    local _, cls = UnitClass("player")
    return cls == "WARRIOR" or cls == "ROGUE"
end

-- RC.db.consumeRemind: { enabled, onlyInBags } from Database defaults;
-- items (itemId / "mh" / "oh" -> true) seeded with this class's picks the
-- first time they are missing.
local function DB()
    local db = RC.db
    if type(db) ~= "table" then return nil end
    if db.testConsumeRemind ~= nil and RC.MigrateConsumeRemind then RC:MigrateConsumeRemind(db) end
    local d = db.consumeRemind
    if type(d) ~= "table" then
        d = (RC.DeepCopy and RC.defaults and RC.DeepCopy(RC.defaults.consumeRemind)) or nil
        if type(d) ~= "table" then d = { enabled = true, onlyInBags = true } end
        db.consumeRemind = d
    end
    if type(d.items) ~= "table" then
        d.items = {}
        for k, v in pairs(IsMelee() and MELEE_DEFAULT or CASTER_DEFAULT) do d.items[k] = v end
    end
    return d
end
CR.DB = DB

-- 40-man raids only: not Zul'Gurub (309) or the Ruins of Ahn'Qiraj
-- (509), or any raid sized for 20 or fewer.
local SMALL_RAID = { [309] = true, [509] = true }
local function InBigRaid()
    if not RC:IsInRaidInstance() then return false end
    if GetInstanceInfo then
        local _, _, _, _, maxPlayers, _, _, instanceId = GetInstanceInfo()
        if instanceId and SMALL_RAID[instanceId] then return false end
        if tonumber(maxPlayers) and maxPlayers > 0 and maxPlayers <= 20 then return false end
    end
    return true
end
CR.InBigRaid = InBigRaid

-- itemId -> { data, cat } for every buff consumable the page can offer
local catalog, catalogBuilt
local function Catalog()
    if catalogBuilt then return catalog end
    catalog = {}
    local melee = IsMelee()
    for _, cat in ipairs(CATEGORIES) do
        local c = RC.raidConsumables and RC.raidConsumables[cat]
        for id, data in pairs(c and c.items or {}) do
            if type(data) == "table" and data.buffId and not data.slot
                and not (melee and data.nonWarrior) then
                catalog[id] = { data = data, cat = cat }
            end
        end
    end
    catalogBuilt = true
    return catalog
end

local SHARP = { "sword", "axe", "mace", "dagger", "polearm", "fist", "staff", "stave" }
local function Sharpenable(inv)
    local link = GetInventoryItemLink("player", inv)
    if not link then return false end
    local _, _, _, _, _, _, sub, _, _, _, _, classId = GetItemInfo(link)
    if classId ~= 2 or not sub then return false end
    sub = sub:lower()
    for _, w in ipairs(SHARP) do
        if (inv == 16 or (w ~= "polearm" and w ~= "staff" and w ~= "stave")) and sub:find(w, 1, true) then return true end
    end
    return false
end

-- RUNNING OUT: a ticked consumable that is up but has LEAD seconds or less left shows
-- too, with its seconds counting down on the icon; once it is gone it
-- stays as missing. Food still never shows in combat.
local LEAD = 30
CR.LEAD = LEAD


-- What is missing or running out right now: a list of { icon, label, left }.
local missing = {}
local shownKey = {}
local voiceList = {}
local function Missing()
    for i = #missing, 1, -1 do missing[i] = nil end
    local d = DB()
    if not d then return missing end
    local cat = Catalog()
    local inCombat = InCombatLockdown()

    -- ticked items in a steady order: category, then name
    local ids = {}
    for id, on in pairs(d.items) do
        if on and type(id) == "number" and cat[id] then ids[#ids + 1] = id end
    end
    table.sort(ids, function(a, b)
        local ca, cb = cat[a].cat, cat[b].cat
        if ca ~= cb then
            local ia, ib = 0, 0
            for i, k in ipairs(CATEGORIES) do if k == ca then ia = i end if k == cb then ib = i end end
            return ia < ib
        end
        return (cat[a].data.name or "") < (cat[b].data.name or "")
    end)

    local done = {}
    -- voice-watch keys already on screen ("b<buffId>", "mh", "oh")
    for k in pairs(shownKey) do shownKey[k] = nil end
    for _, id in ipairs(ids) do
        local g = RC.GetConflictGroup and RC:GetConflictGroup(id)
        local key = g or id
        if not done[key] then
            done[key] = true
            local members = (g and RC:ConflictMembers(g)) or { [id] = true }
            local filled, upId, left, open = false, nil, nil, false
            -- The time left comes from the same buff match HasConsumableBuff
            -- makes (by spellId, else by the buff's name). Reading the
            -- snapshot by spellId alone missed every buff whose aura id is
            -- not the item's listed one: it read as "up, no end time" and its
            -- countdown never showed.
            local function Look(mid)
                local has, l = RC:HasConsumableBuff(mid)
                if has then
                    filled = true
                    if not l or l <= 0 then open = true  -- up with no end time: fine
                    elseif not left or l > left then left, upId = l, mid end
                end
            end
            for mid in pairs(members) do Look(mid) end
            if not members[id] then Look(id) end
            local isFood = cat[id].cat == "food"
            -- running out from the same moment the voice warns (its lead
            -- for this buff), or LEAD before the voice has seen it
            local lead = LEAD
            if upId and RC.VoiceWatchLead then
                local bid = RC.GetConsumableBuffId and RC:GetConsumableBuffId(upId)
                lead = (bid and RC:VoiceWatchLead("b" .. bid)) or LEAD
                if lead < LEAD then lead = LEAD end
            end
            -- the first ticked member of this slot you carry (nil: none)
            local function Carried()
                for _, oid in ipairs(ids) do
                    if (oid == id or members[oid]) and (GetItemCount(oid) or 0) > 0 then return oid end
                end
                return nil
            end
            if filled and not open and left and left <= lead and not (isFood and inCombat) then
                -- running out: only worth a countdown when there is one to
                -- put back up (or the page says show them anyway)
                if not d.onlyInBags or Carried() then
                    local nm = cat[upId] and cat[upId].data.name or ""
                    missing[#missing + 1] = { icon = GetItemIcon(upId), left = left,
                                              label = (RC.GetTTSName and RC:GetTTSName(nm)) or nm }
                    local bid = RC.GetConsumableBuffId and RC:GetConsumableBuffId(upId)
                    if bid then shownKey["b" .. bid] = true end
                end
            elseif not filled and not (isFood and inCombat) then
                -- the icon: the first ticked member you carry
                local show = Carried()
                if show or not d.onlyInBags then
                    show = show or id
                    local nm = cat[show] and cat[show].data.name or ""
                    missing[#missing + 1] = { icon = GetItemIcon(show), label = (RC.GetTTSName and RC:GetTTSName(nm)) or nm }
                end
            end
        end
    end

    -- the weapon stones / oils / poisons
    for _, w in ipairs({ { key = "mh", slot = "mainhand", inv = 16, label = "MH" },
                         { key = "oh", slot = "offhand", inv = 17, label = "OH" } }) do
        if d.items[w.key] and Sharpenable(w.inv)
            and not (w.key == "mh" and RC.IsHordeMode and RC:IsHordeMode("consumablesHelper")) then
            local has, rem = RC:HasWeaponEnchant(nil, w.slot)
            local wlead = (RC.VoiceWatchLead and RC:VoiceWatchLead(w.key)) or LEAD
            if wlead < LEAD then wlead = LEAD end
            if has and tonumber(rem) and rem > 0 and rem <= wlead then
                local stone = RC.GetValidStoneType and RC:GetValidStoneType(w.slot)
                -- running out: only with a stone (oil, poison) in the bags
                -- to put back on, unless the page says show them anyway
                local carried = stone and (GetItemCount(stone) or 0) > 0
                if carried or not d.onlyInBags then
                    -- a poison low on charges shows its charges, not seconds
                    local ch, real, low = 0, rem, false
                    if RC.GetWeaponCharges then ch, real, low = RC:GetWeaponCharges(w.slot) end
                    missing[#missing + 1] = { icon = stone and GetItemIcon(stone) or "Interface\\Icons\\INV_Stone_02",
                                              label = w.label, left = low and math.min(real, rem) or rem,
                                              charges = low and ch or nil }
                    shownKey[w.key] = true
                end
            elseif not has then
                local stone = RC.GetValidStoneType and RC:GetValidStoneType(w.slot)
                local carried = stone and (GetItemCount(stone) or 0) > 0
                if carried or not d.onlyInBags then
                    missing[#missing + 1] = { icon = stone and GetItemIcon(stone) or "Interface\\Icons\\INV_Stone_02", label = w.label }
                end
            end
        end
    end

    -- WHAT THE VOICE IS SAYING: anything the expiry voice is warning
    -- about shows here too, counting down, from the same moment - ticked
    -- on this page or not. Same rules as the rest: one in the bags to put
    -- back up (or "only what is in my bags" off), no food in combat.
    if RC.VoiceWatchRunningOut then
        RC:VoiceWatchRunningOut(voiceList)
        for _, v in ipairs(voiceList) do
            if not shownKey[v.key] then
                local icon, carried, label
                if v.weapon then
                    local stone = RC.GetValidStoneType and RC:GetValidStoneType(v.slot)
                    carried = stone and (GetItemCount(stone) or 0) > 0
                    icon = stone and GetItemIcon(stone) or "Interface\\Icons\\INV_Stone_02"
                    label = (v.slot == "offhand") and "OH" or "MH"
                else
                    carried = type(v.itemId) == "number" and (GetItemCount(v.itemId) or 0) > 0
                    icon = type(v.itemId) == "number" and GetItemIcon(v.itemId) or nil
                    label = v.text
                end
                local isFood = cat[v.itemId] and cat[v.itemId].cat == "food"
                if (carried or not d.onlyInBags) and not (isFood and inCombat) then
                    missing[#missing + 1] = { icon = icon, label = label, left = v.left }
                    shownKey[v.key] = true
                end
            end
        end
    end
    return missing
end
CR.Missing = Missing

-- ---- the glow ----
-- the glow's settings (nil fields = the framework's glow defaults)
local function GlowSpec()
    local g = RC.db and RC.db.consumeRemindGlow
    if type(g) ~= "table" then g = {} end
    return g
end
CR.GlowSpec = GlowSpec

-- puts on, restyles or takes off one icon's glow (no work when nothing
-- changed: Configure compares first)
local function ApplyGlow(ic)
    local spec = GlowSpec()
    if spec.style ~= "none" and RC.UI and RC.UI.CreateEdgeGlow then
        if not ic.edgeGlow then
            ic.edgeGlow = RC.UI:CreateEdgeGlow(ic, spec)
            ic.rcEdgeGlow = ic.edgeGlow
        else
            ic.edgeGlow:Configure(spec)
        end
        if ic.edgeGlow and not ic.edgeGlow:IsShown() then ic.edgeGlow:Show() end
    elseif ic.edgeGlow and ic.edgeGlow:IsShown() then
        ic.edgeGlow:Hide()
    end
end
CR.ApplyGlow = ApplyGlow

-- ---- in the reminders bar ----
-- The missing consumables are icons in the
-- reminders bar's own row: the bar's icon size, spacing, ring, halo and
-- glow mode, on its spot (they move with it). With ability reminders up,
-- the row is the abilities then the consumables, centred together; with
-- none, the consumables sit where the bar's icons would. Plain icons, no
-- clicks - the consumables bars are where you click.
local function Size()
    local db = RC.db or {}
    local size = tonumber(db.iconSize) or 80
    return size, size + (tonumber(db.iconSpacing) or 5)
end

local function Bar()
    local rf = RC.reminderFrame
    if not rf and RC.CreateReminderFrame then
        pcall(RC.CreateReminderFrame, RC)
        rf = RC.reminderFrame
    end
    return rf
end

local Relayout
local hooked
local function Hook(rf)
    if hooked or not rf then return end
    hooked = true
    rf:HookScript("OnShow", function() Relayout() end)
    rf:HookScript("OnHide", function() Relayout() end)
    -- after the bar lays out its abilities, the shared row is laid again
    if type(RC.ShowReminder) == "function" then
        hooksecurefunc(RC, "ShowReminder", function() Relayout() end)
    end
    if type(RC.ShowReminderForced) == "function" then
        hooksecurefunc(RC, "ShowReminderForced", function() Relayout() end)
    end
end

local function Build()
    if CR.frame then return CR.frame end
    local rf = Bar()
    if not rf then return nil end
    local f = CreateFrame("Frame", "ReadycheckConsumeRemind", UIParent)
    f:SetSize(1, 1)
    f:SetFrameStrata("HIGH")
    f:SetFrameLevel(100)
    f:EnableMouse(false)
    f:SetPoint("CENTER", rf, "CENTER", 0, 0)
    f:Hide()
    f.icons = {}
    f.n = 0
    CR.frame = f
    Hook(rf)
    return f
end

-- One icon on any parent (the live row, or the settings preview's canvas).
local function NewIcon(parent)
    local size = Size()
    local ic = CreateFrame("Frame", nil, parent)
    ic:SetSize(size, size)
    ic:EnableMouse(false)
    ic.bg = ic:CreateTexture(nil, "BACKGROUND")
    ic.bg:SetAllPoints()
    local wb = RC:GetColor("ui", "cardBackground") or { r = 0, g = 0, b = 0 }
    ic.bg:SetColorTexture(wb.r, wb.g, wb.b, 0.9)
    ic.texture = ic:CreateTexture(nil, "ARTWORK")
    ic.texture:SetAllPoints()
    ic.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    if RC.UI and RC.UI.DressReadyIcon then RC.UI:DressReadyIcon(ic, size) end
    -- the label and the seconds sit above the glow (it is a frame of its
    -- own, drawn over the icon's regions)
    local tl = CreateFrame("Frame", nil, ic)
    tl:SetAllPoints(ic)
    tl:SetFrameLevel(ic:GetFrameLevel() + 12)
    ic.textLayer = tl
    ic.text = RC:CreateFontString(tl, "OVERLAY", nil, 12)
    ic.text:SetPoint("CENTER", ic, "BOTTOM", 0, 1)
    ic.text:SetJustifyH("CENTER")
    ic.text:SetShadowOffset(1, -1)
    ic.text:SetShadowColor(0, 0, 0, 1)
    -- the seconds left on one that is running out, big in the middle
    ic.cd = RC:CreateFontString(tl, "OVERLAY", nil, 20)
    ic.cd:SetPoint("CENTER", ic, "CENTER", 0, 2)
    ic.cd:SetJustifyH("CENTER")
    ic.cd:SetShadowOffset(1, -1)
    ic.cd:SetShadowColor(0, 0, 0, 1)
    ic.cd:Hide()
    ic.size = 0
    return ic
end
CR.NewIcon = NewIcon

local function Icon(i)
    local f = CR.frame
    local ic = f.icons[i]
    if ic then return ic end
    ic = NewIcon(f)
    f.icons[i] = ic
    return ic
end

-- Paints one icon for missing item m ({ icon, label, charges, left }) at
-- the reminder bar's size, glow and text settings (the live row and the
-- preview alike).
local function PaintIcon(ic, m)
    local size = Size()
    local glow = (RC.db and RC.db.iconGlow) or "pulse"
    local showText = not (RC.db and RC.db.showIconText == false)
    local gold = RC:GetColor("text", "gold")
    if math.abs((ic.size or 0) - size) > 0.5 then
        ic:SetSize(size, size)
        if RC.UI and RC.UI.DressReadyIcon then RC.UI:DressReadyIcon(ic, size) end
        ic.text:SetWidth(size + 20)
        if RC.ApplyCustomFont then RC:ApplyCustomFont(ic.cd, math.max(14, math.floor(size * 0.42))) end
        ic.size = size
    end
    if RC.UI and RC.UI.SetReadyIconGlow and ic.glow ~= glow then
        RC.UI:SetReadyIconGlow(ic, glow)
        ic.glow = glow
    end
    ApplyGlow(ic)
    ic.texture:SetTexture(m.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    ic.text:SetText(m.label or "")
    ic.text:SetTextColor(gold.r, gold.g, gold.b, 1)
    if showText then ic.text:Show() else ic.text:Hide() end
    if m.charges then
        ic.cd:SetText(m.charges .. "c")
        local c = RC:GetColor("text", "red")
        ic.cd:SetTextColor(c.r, c.g, c.b, 1)
        ic.cd:Show()
    elseif m.left then
        local s = math.max(0, math.ceil(m.left))
        ic.cd:SetText(s >= 60 and (math.ceil(s / 60) .. "m") or tostring(s))
        local c = (s <= 10) and RC:GetColor("text", "red") or RC:GetColor("text", "white")
        ic.cd:SetTextColor(c.r, c.g, c.b, 1)
        ic.cd:Show()
    else
        ic.cd:Hide()
    end
    ic:Show()
end
CR.PaintIcon = PaintIcon

-- the bar's ability icons that are up, in their order
local shownAb = {}
local function ShownAbilities(rf)
    for i = #shownAb, 1, -1 do shownAb[i] = nil end
    if not (rf and rf:IsShown() and rf.abilityIcons) then return shownAb end
    for i = 1, #rf.abilityIcons do
        local ic = rf.abilityIcons[i]
        if ic and ic:IsShown() then shownAb[#shownAb + 1] = ic end
    end
    return shownAb
end

-- lays the shared row: no API reads, just positions
Relayout = function()
    local f = CR.frame
    if not f then return end
    local rf = RC.reminderFrame
    local m = f.n or 0
    local ab = ShownAbilities(rf)
    local n = #ab
    local _, step = Size()
    local total = n + (f:IsShown() and m or 0)
    local function Off(j) return (j - 1 - (total - 1) / 2) * step end
    for i, ic in ipairs(ab) do
        ic:ClearAllPoints()
        ic:SetPoint("CENTER", rf, "CENTER", Off(i), 0)
    end
    if not f:IsShown() then return end
    for k = 1, m do
        local ic = f.icons[k]
        if ic then
            ic:ClearAllPoints()
            ic:SetPoint("CENTER", f, "CENTER", Off(n + k), 0)
        end
    end
end
CR.Relayout = Relayout

local function Hide()
    local f = CR.frame
    if f and f:IsShown() then
        f:Hide()
        Relayout()      -- the abilities close up again
    end
end

-- A glow setting changed: the icons up now restyle, once next frame
-- however many changes landed, and the profile is saved.
local function RestyleGlows()
    local f = CR.frame
    if f and f:IsShown() then
        for i = 1, (f.n or 0) do
            local ic = f.icons[i]
            if ic and ic:IsShown() then ApplyGlow(ic) end
        end
    end
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
end
CR.RestyleGlows = RestyleGlows
CR.GlowChanged = (RC.UI and RC.UI.Coalesce) and RC.UI:Coalesce(RestyleGlows) or RestyleGlows

local Tick
-- An error in a ticker's callback can stop the ticker for good, and with
-- it the icons, until the next /reload: every pass runs protected, and an
-- error is noted (debug "consumables", and the decision log) instead.
local tickErrors = 0
local function SafeTick()
    local ok, err = pcall(Tick)
    if not ok then
        tickErrors = tickErrors + 1
        if tickErrors <= 3 or tickErrors % 100 == 0 then
            RC:DebugPrint("Consume reminders error: " .. tostring(err), "consumables")
            if RC.DiagLog then RC:DiagLog("tts", "consume reminder icons error #%d: %s", tickErrors, tostring(err)) end
        end
    end
end

Tick = function()
    local d = DB()
    if not (d and d.enabled) then return Hide() end
    if RC.db and RC.db.enabled == false then return Hide() end
    -- the readers live in Readycheck_Consumables (load on demand)
    if not (RC.HasConsumableBuff and RC.HasWeaponEnchant and RC.performanceCache) then return Hide() end
    if not InBigRaid() or UnitIsDeadOrGhost("player") then return Hide() end
    local list = Missing()
    if #list == 0 then return Hide() end
    local f = Build()
    if not f then return end
    for i, m in ipairs(list) do PaintIcon(Icon(i), m) end
    for i = #list + 1, #f.icons do f.icons[i]:Hide() end
    f.n = #list
    f:Show()
    Relayout()
end
CR.Tick = Tick

local function Start()
    if CR.ticker then return end
    if RC.Profiler and RC.Profiler.TrackTicker then
        CR.ticker = RC.Profiler:TrackTicker("Consumables:RaidReminders", 0.5, SafeTick)
    else
        CR.ticker = C_Timer.NewTicker(0.5, SafeTick)
    end
end

-- ---- the preview: the row as it shows in the reminders bar, at the bar's
-- icon size and spacing, built by NewIcon / PaintIcon with sample items
local CR_SAMPLE = {
    { icon = "Interface\\Icons\\INV_Potion_62", label = RCL["Flask"] },
    { icon = "Interface\\Icons\\INV_Potion_32", label = RCL["Mongoose"], left = 24 },
    { icon = "Interface\\Icons\\INV_Misc_Food_64", label = RCL["Food"] },
    { icon = "Interface\\Icons\\INV_Stone_02", label = RCL["Stone"], charges = 3 },
}
local function CRPreviewBuild(canvas, P)
    P.store.holder = CreateFrame("Frame", nil, canvas)
    P.store.holder:SetPoint("CENTER", canvas, "CENTER", 0, 0)
    P.store.icons = {}
    for i = 1, #CR_SAMPLE do P.store.icons[i] = NewIcon(P.store.holder) end
end
local function CRPreviewUpdate(canvas, P)
    local st = P.store
    if not st.icons then return end
    local size, step = Size()
    local n = #CR_SAMPLE
    for i, m in ipairs(CR_SAMPLE) do
        local ic = st.icons[i]
        PaintIcon(ic, m)
        ic:ClearAllPoints()
        ic:SetPoint("CENTER", st.holder, "CENTER", (i - 1 - (n - 1) / 2) * step, 0)
    end
    local w = (n - 1) * step + size
    st.holder:SetSize(w, size)
    -- the label hangs under the icon: room for it, and for a glow that
    -- reaches further than that room
    local reach = (RC.UI.EdgeGlowReach and RC.UI:EdgeGlowReach(size, GlowSpec())) or 0
    local pad = math.max(0, reach - 10)
    P.Resize(w + 24 + 2 * pad, size + 34 + 2 * pad)
end

-- ---- the page: the Icon glow card ----
-- Style, colour, strength, size, the soft halo, the pulse, and the lines /
-- sparkles. Options a style does not use are greyed while it is picked.
-- Each control writes RC.db.consumeRemindGlow and asks for one restyle;
-- the framework's change signal gives the preview its one update.
function CR.GlowCard(self, parent, yPos)
    local gs = self.db.consumeRemindGlow
    if type(gs) ~= "table" then gs = {} self.db.consumeRemindGlow = gs end
    local DEF = self.UI.EDGE_GLOW_DEFAULTS or {}
    local function V(k)
        local v = gs[k]
        if v == nil then v = DEF[k] end
        return v
    end
    local Changed = CR.GlowChanged
    local floor = math.floor

    local card = self:CreateSettingsCard(parent, yPos, RCL["Icon glow"])
    local cardW = card:GetWidth() or 0
    if cardW < 200 then cardW = 560 end
    local gy = -34
    local binds = {}
    local function RefreshBinds() for _, b in ipairs(binds) do b:Refresh() end end
    self.UI:CreateSegmentedControl(card, {
        x = 14, y = gy, height = 22, label = RCL["Glow style:"],
        items = self.UI.EDGE_GLOW_STYLES, selected = V("style"),
        onSelect = function(k) gs.style = k RefreshBinds() Changed() end,
    })
    gy = gy - 32
    local mark = self.UI:MarkCard(card)

    local ac = self:GetColor("ui", "accentGold")
    local cp = self.UI:CreateColorPicker(card, {
        label = RCL["Glow colour"], width = math.min(420, cardW - 24),
        tooltip = RCL["Unset, the glow is Readycheck's accent colour."],
        get = function() return gs.color end,
        set = function(r, g, b) gs.color = { r = r, g = g, b = b, a = 1 } Changed() end,
        default = { r = ac.r, g = ac.g, b = ac.b, a = 1 },
        isChanged = function() return type(gs.color) == "table" end,
        reset = function() gs.color = nil Changed() end,
    })
    cp:SetPoint("TOPLEFT", card, "TOPLEFT", 10, gy)
    gy = gy - 34

    -- two sliders to a row; the second hangs off the first
    local half = floor((cardW - 14 * 3 - 16) / 2)
    local function Slider(left, lo, hi, step, cur, label, fmt, set)
        local s = self.UI:CreateSlider(card, lo, hi, cur, step)
        if left then
            s:SetPoint("TOPLEFT", left.parentFrame or left, "TOPRIGHT", 14, 0)
        else
            s:SetPoint("TOPLEFT", card, "TOPLEFT", 14, gy)
        end
        s:SetWidth(half)
        s:SetLabel(label)
        s.Text:SetText(fmt(cur))
        s:SetScript("OnValueChanged", function(sl, v)
            v = floor(v / step + 0.5) * step
            sl.Text:SetText(fmt(v))
            set(v)
            Changed()
        end)
        return s
    end
    local function Pct(v) return floor(v + 0.5) .. "%" end

    local strength = Slider(nil, 10, 100, 5, floor(V("alpha") * 100 + 0.5), RCL["Strength"], Pct,
        function(v) gs.alpha = v / 100 end)
    Slider(strength, 50, 200, 5, floor(V("size") * 100 + 0.5), RCL["Size"], Pct,
        function(v) gs.size = v / 100 end)
    gy = gy - 42

    local halo = self.UI:CreateSettingCheckbox(card, gy, RCL["Soft halo (edge glow)"], V("halo") == true, function(cb)
        gs.halo = cb:GetChecked() and true or false
        Changed()
    end)
    gy = gy - 26
    local pulse = self.UI:CreateSettingCheckbox(card, gy, RCL["Pulse in and out"], V("pulse") ~= false, function(cb)
        gs.pulse = cb:GetChecked() and true or false
        Changed()
    end)
    gy = gy - 28
    local pLen = Slider(nil, 15, 300, 5, floor(V("speed") * 100 + 0.5), RCL["Pulse length"],
        function(v) return string.format("%.2fs", v / 100) end,
        function(v) gs.speed = v / 100 end)
    local pDepth = Slider(pLen, 0, 95, 5, floor(V("depth") * 100 + 0.5), RCL["Pulse depth"], Pct,
        function(v) gs.depth = v / 100 end)
    gy = gy - 42

    local lines = Slider(nil, 1, 16, 1, V("lines"), RCL["Lines or sparkles"], tostring,
        function(v) gs.lines = v end)
    local len = Slider(lines, 2, 40, 1, floor(V("length") + 0.5), RCL["Line length"],
        function(v) return floor(v + 0.5) .. " px" end,
        function(v) gs.length = v end)
    gy = gy - 42
    local lspeed = Slider(nil, 2, 100, 1, floor(V("lineSpeed") * 100 + 0.5), RCL["Line speed"],
        function(v) return string.format("%.2f/s", v / 100) end,
        function(v) gs.lineSpeed = v / 100 end)
    gy = gy - 42
    gy = self.UI:CreateHelpLine(card, 14, gy, RCL["Line speed is laps of the icon a second; lines and sparkles share the count and speed."])
    gy = gy - 4

    -- inner pairs first: the pulse's own options, then what each style uses
    self.UI:BindDependents(pulse, { pLen, pDepth })
    local function Style() return gs.style or DEF.style end
    binds[#binds + 1] = self.UI:BindDependents(function() return Style() == "edge" end, { halo }, { indent = 0 })
    binds[#binds + 1] = self.UI:BindDependents(function()
        local st = Style()
        return st == "pixel" or st == "autocast"
    end, { lines, lspeed }, { indent = 0 })
    binds[#binds + 1] = self.UI:BindDependents(function() return Style() == "pixel" end, { len }, { indent = 0 })
    binds[#binds + 1] = self.UI:BindDependents(function() return Style() ~= "none" end,
        self.UI:CardSince(card, mark), { indent = 0 })

    card:SetHeight(math.abs(gy))
    return yPos - card:GetHeight() - 12
end

-- ---- the page ----
function RC:ShowSidebarConsumeRemind(frame, preserveScroll)
    self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
    local parent = frame.scrollChild
    if not parent then return end
    local d = DB()
    if not d then return end
    self.UI:DeclarePreview({
        key = "consumables.consumeremind", title = RCL["Raid consume reminders"],
        width = 360, height = 114,
        build = CRPreviewBuild, update = CRPreviewUpdate,
    })
    local function Save()
        if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
        Tick()
    end
    local yPos = -20
    local _, newY = self:CreateSettingsPageHeader(parent, yPos,
        RCL["Raid Consume Reminders"],
        RCL["In a raid, the important consumables you are not wearing show in your reminders bar"],
        "Interface\\Icons\\INV_Potion_62")
    yPos = newY

    local gen = self:CreateSettingsCard(parent, yPos, RCL["Reminder"])
    local cy = -34
    self.UI:CreateSettingCheckbox(gen, cy, RCL["Show missing consumables in raids"], d.enabled == true, function(cb)
        d.enabled = cb:GetChecked() and true or false
        Save()
    end)
    cy = cy - 24
    self.UI:CreateSettingCheckbox(gen, cy, RCL["Only what is in my bags"], d.onlyInBags ~= false, function(cb)
        d.onlyInBags = cb:GetChecked() and true or false
        Save()
    end)
    cy = cy - 30
    gen:SetHeight(math.abs(cy))
    yPos = yPos - gen:GetHeight() - 12

    yPos = CR.GlowCard(self, parent, yPos)

    -- one card per category, two columns of ticks
    local cat = Catalog()
    local COL_W = 250
    local function ItemCard(title, list)
        local card = self:CreateSettingsCard(parent, yPos, title)
        local row = 0
        for i, it in ipairs(list) do
            local col = (i - 1) % 2
            if col == 0 and i > 1 then row = row + 1 end
            local y = -34 - row * 24
            local cb = self.UI:CreateSettingCheckbox(card, y, it.label, d.items[it.key] == true, function(c)
                d.items[it.key] = c:GetChecked() and true or nil
                Save()
            end)
            cb:ClearAllPoints()
            cb:SetPoint("TOPLEFT", card, "TOPLEFT", 14 + col * COL_W, y)
        end
        card:SetHeight(34 + (row + 1) * 24 + 8)
        yPos = yPos - card:GetHeight() - 12
    end
    for _, c in ipairs(CATEGORIES) do
        local list = {}
        for id, e in pairs(cat) do
            if e.cat == c then list[#list + 1] = { key = id, label = e.data.name or tostring(id) } end
        end
        table.sort(list, function(a, b) return a.label < b.label end)
        if #list > 0 then ItemCard(CAT_LABEL[c] or c, list) end
    end
    ItemCard(RCL["Weapons"], { { key = "mh", label = RCL["Main-hand stone / oil / poison"] },
                               { key = "oh", label = RCL["Off-hand stone / oil / poison"] } })

    local flavor = RC:Flavor()
    local note
    if flavor == "tbc" then
        note = RCL["Items that do not stack in game share one slot: one battle elixir, one guardian elixir (a flask fills both), one food; any of them up fills it. Food never shows in combat. Shown only inside raids for more than 20 players."]
    elseif flavor == "forever" then
        note = RCL["Items that do not stack in game (Juju Power and Elixir of Greater Strength, Juju Might and the Firewaters, R.O.I.D.S. and Scorpok, the foods) share one slot: any of them up fills it. Food never shows in combat. Shown only inside raids for more than 20 players."]
    else
        note = RCL["Items that do not stack in game (Juju Power and Elixir of Giants, the Zanzas and Blasted Lands buffs, the stat foods) share one slot: any of them up fills it. Food never shows in combat. Shown only inside 40-man raids (not Zul'Gurub or the Ruins of Ahn'Qiraj)."]
    end
    -- kept whole on the page: the slot rules are the point of the note
    yPos = self.UI:CreateHelpLine(parent, 14, yPos, note, { wrap = true })
    yPos = yPos - 12
    self:UpdateSidebarScrollbar(self.sidebarConfigFrame, math.abs(yPos))
end

-- The page is listed in Sidebar_Base (Consumables, id "consumeremind").
-- The ticker starts on entering the world, or now when this companion
-- loads after login.
do
    local ev = CreateFrame("Frame")
    ev:RegisterEvent("PLAYER_ENTERING_WORLD")
    ev:SetScript("OnEvent", function()
        C_Timer.After(4, Start)
    end)
    if IsLoggedIn and IsLoggedIn() then C_Timer.After(4, Start) end
end
