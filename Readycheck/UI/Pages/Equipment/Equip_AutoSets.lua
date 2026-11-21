------------------------------------------------------------------------
-- Readycheck - Equipment: gear by spec and stance
-- The "Spec & Stance" tab of the Gear Manager page. EVERYTHING about
-- gear by spec and stance / form is here and nowhere else (2026-11-20,
-- Zac: "i dont really like where you put the options for the gear stuff
-- can we somehow do it better and just have all of that off by default
-- in general with a way to turn it all on later"):
--   * ONE switch at the top, off until turned on. Off: this tab is that
--     one tick and a line saying what it does; nothing else in the addon
--     shows or does anything about it.
--   * What each gear set is for, and what each item is for: a grid, one
--     row per set / item, one tick per spec and per stance / form. All
--     ticked is everything, which is how every row starts. Where a row is
--     not ticked, the dockable buttons' hover menus leave it out.
--   * Sets that go on by themselves: its own tick (off), then the rules,
--     the fight card and the details.
-- The engine is Readycheck_Gear/Manager/GM_AutoSets.lua (RC.AutoSets and
-- the GM:MenuScope* functions); this page only calls its setters and is
-- rebuilt after each change.
--   RC:BuildGearAutoSetsTab(parent, yPos, frame) -> yPos
------------------------------------------------------------------------
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._seq = RC._seq or {}
local _seq = RC._seq

local ipairs, pairs, type, tostring, tonumber, pcall = ipairs, pairs, type, tostring, tonumber, pcall
local string_format = string.format
local ANY = "any"       -- (a dropdown value cannot be nil)

local function Col(cat, key)
    local c = RC:GetColor(cat, key)
    return c.r or 1, c.g or 1, c.b or 1
end

-- the rule pickers' lists
local function FormItems(AS, rule)
    local items = { { text = string_format(RCL["Any %s"], RCL[AS.Word()]), value = ANY } }
    local found = (rule.form == nil or rule.form == 0)
    local known, fit = AS.RuleFormKnown(rule)
    for _, f in ipairs(AS.Forms()) do
        items[#items + 1] = { text = f.name, value = f.id, icon = f.icon }
        if known and fit and fit.id == f.id then found = true end
    end
    if AS.CanBeFormless() then items[#items + 1] = { text = AS.NoFormLabel(), value = 0 } end
    -- a rule made on another character, or for a form not learned yet: still listed, so it is not lost
    if not found then
        items[#items + 1] = { text = string_format(RCL["%s (not on this character)"], rule.formName or ("#" .. tostring(rule.form))), value = rule.form }
    end
    return items, known, fit
end
local function SpecItems(AS)
    local items = { { text = RCL["Any spec"], value = ANY } }
    for _, s in ipairs(AS.Specs()) do
        items[#items + 1] = { text = s.name, value = s.key, icon = s.icon }
    end
    return items
end
local function Pick(dd, items, value)
    for _, it in ipairs(items) do
        if it.value == value then
            dd:SetSelectedValue(it.value, it.text)
            if it.icon and dd.SetSelectedIcon then dd:SetSelectedIcon(it.icon) end
            return
        end
    end
end
local function Tip(widget, title, body)
    widget:HookScript("OnEnter", function(w)
        GameTooltip:SetOwner(w, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        if body then GameTooltip:AddLine(body, 0.7, 0.7, 0.7, true) end
        GameTooltip:Show()
    end)
    widget:HookScript("OnLeave", function() GameTooltip:Hide() end)
end
local function Text(card, x, y, text, size, cat, key)
    local fs = RC:CreateFontString(card, "OVERLAY", nil, size or 11)
    fs:SetPoint("TOPLEFT", card, "TOPLEFT", x, y)
    fs:SetText(text)
    fs:SetTextColor(Col(cat or "text", key or "normal"))
    return fs
end

------------------------------------------------------------------------
-- THE GRID: one row per set or item, one tick per spec and per stance /
-- form. The columns are headed by the spec's and the form's own icons
-- (their names are the tooltips); a click on a heading ticks or unticks
-- that whole column. rows = { { key, name, icon, quality, note } }.
------------------------------------------------------------------------
local NAME_X, NAME_W, COL_W, GROUP_GAP, ROW_H = 38, 150, 24, 14, 22
local NO_FORM_ICON = "Interface\\Icons\\Spell_Nature_WispSplode"
local function Columns(AS)
    local cols = {}
    for _, sp in ipairs(AS.Specs()) do
        cols[#cols + 1] = { what = "spec", id = sp.key, name = sp.name, icon = sp.icon }
    end
    local nSpec = #cols
    for _, f in ipairs(AS.AllForms()) do
        cols[#cols + 1] = { what = "form", id = f.id, name = f.name, icon = f.icon or NO_FORM_ICON }
    end
    local x = NAME_X + NAME_W + 12
    for i, c in ipairs(cols) do
        if i == nSpec + 1 and nSpec > 0 then x = x + GROUP_GAP end
        c.x = x
        x = x + COL_W
    end
    return cols, nSpec
end
local function Grid(card, cy, kind, rows, Rebuild)
    local AS, GM, UI = RC.AutoSets, RC.GearManager, RC.UI
    local cols, nSpec = Columns(AS)
    if #cols == 0 then
        local L = _seq.Look
        return L.Desc(card, cy, RCL["This character has no specs or stances to pick from yet."])
    end
    -- the two groups' names, then the icon headings
    if nSpec > 0 then Text(card, cols[1].x, cy, RCL["Spec"], 10, "text", "gray") end
    if #cols > nSpec then
        local w = AS.Word()
        Text(card, cols[nSpec + 1].x, cy, RCL[w == "stance" and "Stance" or (w == "aura" and "Aura" or "Form")], 10, "text", "gray")
    end
    cy = cy - 14
    for _, c in ipairs(cols) do
        local h = CreateFrame("Button", nil, card)
        h:SetSize(18, 18)
        h:SetPoint("TOPLEFT", card, "TOPLEFT", c.x, cy)
        h.icon = h:CreateTexture(nil, "ARTWORK")
        h.icon:SetAllPoints()
        h.icon:SetTexture(c.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        h.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        h.border = UI:CreateSimpleBorder(h)
        h._rcLabel = "Column " .. tostring(c.name)
        Tip(h, c.name, RCL["Click to tick or untick this for every row."])
        h:SetScript("OnClick", function()
            local allOn = true
            for _, r in ipairs(rows) do
                if not GM:MenuScopeHas(GM:GetMenuScope(kind, r.key), c.what, c.id) then allOn = false end
            end
            for _, r in ipairs(rows) do GM:SetMenuScopePart(kind, r.key, c.what, c.id, not allOn) end
            Rebuild()
        end)
    end
    cy = cy - 24
    for _, r in ipairs(rows) do
        local scope = GM:GetMenuScope(kind, r.key)
        local ic = card:CreateTexture(nil, "ARTWORK")
        ic:SetSize(18, 18)
        ic:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        ic:SetTexture(r.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local nm = RC:CreateFontString(card, "OVERLAY", nil, 11)
        nm:SetPoint("TOPLEFT", card, "TOPLEFT", NAME_X, cy - 3)
        nm:SetWidth(NAME_W)
        nm:SetJustifyH("LEFT")
        nm:SetWordWrap(false)
        nm:SetText(r.note and (r.name .. " (" .. r.note .. ")") or r.name)
        local qc = r.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[r.quality]
        if qc then nm:SetTextColor(qc.r, qc.g, qc.b) else nm:SetTextColor(Col("text", "normal")) end
        for _, c in ipairs(cols) do
            local cb = UI:CreateCheckbox(card, "", GM:MenuScopeHas(scope, c.what, c.id))
            cb:SetPoint("TOPLEFT", card, "TOPLEFT", c.x + 1, cy - 1)
            cb._rcLabel = tostring(r.name) .. " for " .. tostring(c.name)
            cb:SetScript("OnClick", function(b)
                local on = b:GetChecked() and true or false
                RC:ForceCheckboxUpdate(b, on)
                GM:SetMenuScopePart(kind, r.key, c.what, c.id, on)
                Rebuild()
            end)
            Tip(cb, r.name, string_format(RCL["Ticked: listed in the menus as %s. Unticked: left out there."], c.name))
        end
        cy = cy - ROW_H
    end
    return cy - 4
end

-- the rows: every gear set of Readycheck's own
local function SetRows(GM)
    local rows = {}
    for _, n in ipairs(GM:GetSetNames()) do
        if not n:match("^~") then
            rows[#rows + 1] = { key = n, name = n, icon = RC:GetGearSetIcon(n) or "Interface\\Icons\\INV_Chest_Plate16" }
        end
    end
    return rows
end
-- the rows: every item you carry that fits the slot (one per copy the game
-- can tell apart), and any item limited earlier that is not in the bags now
local function ItemRows(GM, slot)
    local rows, seen = {}, {}
    -- (the menu's own list, asked as a plain button would: not as the
    -- character sheet, the set editor or another character's gear)
    local savedAnchor, savedRemote = GM.currentMenuAnchor, GM.remoteItemsOverride
    GM.currentMenuAnchor, GM.remoteItemsOverride = nil, nil
    local ok, list = pcall(GM.GetItemsForSlot, GM, slot)
    GM.currentMenuAnchor, GM.remoteItemsOverride = savedAnchor, savedRemote
    for _, it in ipairs(ok and list or {}) do
        local key, id = GM:MenuItemKey(it.itemLink)
        if key and not seen[key] then
            seen[key] = true
            rows[#rows + 1] = { key = key, name = GetItemInfo(it.itemLink) or it.name or ("item " .. tostring(id)),
                icon = it.texture, quality = it.quality }
        end
    end
    for key in pairs(GM.settings.menuScopeItems or {}) do
        local id = type(key) == "string" and tonumber(key:match("^(%d+)"))
        if id and not seen[key] then
            local name, _, q, _, _, _, _, _, equipSlot, tex = GetItemInfo(id)
            if name and GM.CanItemGoInSlot and GM:CanItemGoInSlot(equipSlot, slot) then
                seen[key] = true
                rows[#rows + 1] = { key = key, name = name, icon = tex, quality = q, note = RCL["not in bags"] }
            end
        end
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    return rows
end

-- the tab's name, in the class's own word: "Spec & Stance" for a warrior,
-- "Spec & Form", "Spec & Aura", and "Spec" where the client's stance bar is
-- empty. Also written into the settings search, so a search result names the
-- tab as the tab is named.
function RC:GearSpecTabName()
    local AS = RC.AutoSets
    local name = RCL["Spec & Stance"]
    if AS and AS.HasForms and AS.Word then
        if not AS.HasForms() then
            name = RCL["Spec"]
        else
            local w = AS.Word()
            name = RCL[w == "stance" and "Spec & Stance" or (w == "aura" and "Spec & Aura" or "Spec & Form")]
        end
    end
    for _, sub in ipairs(RC.SUBPANEL_ALIASES or {}) do
        if sub.parentId == "gear_manager" and sub.tabKey == "auto" then sub.tabLabel = name end
    end
    return name
end

function RC:BuildGearAutoSetsTab(parent, yPos, frame)
    local L = _seq.Look
    local AS = RC.AutoSets
    if not (AS and AS.DB and AS.DB()) then
        return (L.Card(parent, yPos, RCL["Gear by spec and stance"], function(card, cy)  -- (the Gear addon is off: no class word to read)
            return L.Desc(card, cy, RCL["The Gear addon (Readycheck_Gear) is not loaded. Enable it in your AddOns list and /reload."])
        end))
    end
    local UI = self.UI
    local function Rebuild() RC:ShowSidebarGearManagerConfig(frame, true) end
    local word = AS.Word()                      -- "stance" | "form" | "aura"
    local hasForms = AS.HasForms()
    -- the same sentences for a class with nothing on its stance bar: by spec alone
    local specAnd  = hasForms and string_format(RCL["spec and %s"], RCL[word]) or RCL["spec"]
    local specOr   = hasForms and string_format(RCL["spec or %s"], RCL[word]) or RCL["spec"]
    local specsAnd = hasForms and string_format(RCL["specs and %ss"], RCL[word]) or RCL["specs"]
    local changeOf = hasForms and string_format(RCL["%s or spec"], RCL[word]) or RCL["spec"]
    local oneOf    = hasForms and RCL[word] or RCL["spec"]

    local GM = RC.GearManager
    ------------------------------------------------------------------
    -- 1. THE ONE SWITCH. Off: this card is all there is.
    ------------------------------------------------------------------
    local master = AS.Master()
    yPos = L.Card(parent, yPos, string_format(RCL["Gear by %s"], specAnd), function(card, cy)
        cy = L.Check(card, cy, string_format(RCL["Use my %s for my gear"], specAnd), master, function(on)
            AS.SetMaster(on)
            Rebuild()
        end)
        if not master then
            return L.Desc(card, cy + 2, string_format(RCL["Off: every menu lists everything and nothing is put on by itself. Turn it on to say which %s each gear set and item is for, so the dockable buttons' menus only list what fits what you are doing - and, if you want, to have a set go on by itself."], specsAnd), 38)
        end
        cy = L.Desc(card, cy + 2, RCL["On. Below: what each gear set and each item is for, and (off until ticked) sets that go on by themselves. Untick this and all of it stops; what you picked is kept."], 38)
        cy = L.Check(card, cy - 2, string_format(RCL["Leave out of the dockable buttons' menus what is for another %s"], specOr), GM:MenuScopeWanted(), function(on)
            GM:SetMenuScopeOn(on)
            Rebuild()
        end, string_format(RCL["What is left out counts as hidden: hold %s over an open menu to see it, faded. The character sheet menus and the set editor always list everything."], GM.MenuRevealKeyLabel and GM:MenuRevealKeyLabel() or "Shift"))
        return cy
    end)
    if not master then return yPos end

    ------------------------------------------------------------------
    -- 2. what each gear set is for
    ------------------------------------------------------------------
    yPos = L.Card(parent, yPos, RCL["What each gear set is for"], function(card, cy)
        local rows = SetRows(GM)
        if #rows == 0 then
            return L.Desc(card, cy, RCL["No gear sets yet. Make one on the Sets tab and it shows up here."])
        end
        cy = L.Desc(card, cy, string_format(RCL["A row per set, a tick per %s. Every set starts with all of them ticked (everything). Untick the ones a set is not for."], specAnd))
        return Grid(card, cy - 2, "set", rows, Rebuild)
    end)

    ------------------------------------------------------------------
    -- 3. what each item is for (trinkets, weapons, any slot)
    ------------------------------------------------------------------
    yPos = L.Card(parent, yPos, RCL["What each item is for"], function(card, cy)
        -- (the two rings and the two trinkets hold the same items: one entry each)
        RC.gmScopeSlot = RC.gmScopeSlot or 13
        local PAIR = { [11] = RCL["Rings"], [13] = RCL["Trinkets"] }
        local items = {}
        for sl = 0, 19 do
            local info = GM.slotInfo and GM.slotInfo[sl]
            if info and sl ~= 12 and sl ~= 14 then
                items[#items + 1] = { text = PAIR[sl] or RCL[info.real], value = sl }
            end
        end
        Text(card, 14, cy - 6, RCL["Slot"])
        local dd = UI:CreateScrollableDropdown(card, 180, "", 10)
        dd:SetPoint("TOPLEFT", card, "TOPLEFT", 50, cy)
        dd:SetItems(items, function(value)
            RC.gmScopeSlot = value
            Rebuild()
        end)
        Pick(dd, items, RC.gmScopeSlot)
        if dd.SetSearchEnabled then dd:SetSearchEnabled(false) end
        dd._rcLabel = RCL["Slot"]
        cy = cy - 34
        local rows = ItemRows(GM, RC.gmScopeSlot)
        if #rows == 0 then
            return L.Desc(card, cy, RCL["Nothing you carry fits this slot."])
        end
        return Grid(card, cy, "item", rows, Rebuild)
    end)

    ------------------------------------------------------------------
    -- 4. sets that go on by themselves: its own tick, off until ticked
    ------------------------------------------------------------------
    local auto = AS.AutoOn()
    yPos = L.Card(parent, yPos, RCL["Sets that go on by themselves"], function(card, cy)
        cy = L.Check(card, cy, string_format(RCL["Put a gear set on by itself when my %s changes"], changeOf), auto, function(on)
            AS.SetEnabled(on)
            Rebuild()
        end)
        if not auto then
            return L.Desc(card, cy + 2, string_format(RCL["Off: Readycheck never changes your gear because of this tab. Ticked, you make rules below: this set for this %s."], specOr), 38)
        end
        cy = L.Desc(card, cy + 2, string_format(RCL["A rule puts its set on when your %s CHANGES to it. A set you put on by hand stays until the next change, and a %s with no rule keeps what you are wearing."], changeOf, oneOf), 38)

        -- right now (kept current while the page is on show: AS.OnState)
        local function Now()
            local st = AS.Status()
            if #AS.Rules() == 0 then return RCL["No rules yet: add one below."] end
            local where = {}
            if hasForms and st.form ~= nil then where[#where + 1] = AS.FormName(st.form) or RCL["Unknown form"] end
            if st.spec then where[#where + 1] = AS.SpecName(st.spec) end
            local now = (#where > 0) and table.concat(where, ", ") or RCL["Unknown"]
            if not st.rule then
                return string_format(RCL["Right now: %s. No rule fits, so nothing changes."], now)
            end
            local line = string_format(RCL["Right now: %s. Rule %d fits: %s."], now, st.index or 0, st.rule.set)
            if st.combat then line = line .. " " .. RCL["In a fight it waits until the fight ends."] end
            if st.boss and AS.Opt("bossFirst") then line = line .. " " .. RCL["A boss gear swap is active and comes first."] end
            return line
        end
        local fs = Text(card, 14, cy - 4, Now(), 11, "ui", "accentGold")
        fs:SetPoint("RIGHT", card, "RIGHT", -14, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        AS.OnState = function()
            if fs:IsVisible() then fs:SetText(Now()) end
        end
        cy = cy - 4 - math.max(14, fs:GetStringHeight() or 14) - 6
        return cy
    end)
    if not auto then return yPos end

    ------------------------------------------------------------------
    -- 5. the rules
    ------------------------------------------------------------------
    local function SetItems()
        local items = { { text = RCL["Choose a set"], value = "" } }
        for _, e in ipairs(RC:GetAllGearSets()) do
            items[#items + 1] = { text = (e.source == "ItemRack") and (e.name .. " (ItemRack)") or e.name,
                value = e.name, icon = e.icon or RC:GetGearSetIcon(e.name) }
        end
        return items
    end
    local MACRO_WHY = {
        form = RCL["Pick one %s for this rule first: a macro casts one."],
        unknown = RCL["This character does not have that %s."],
        set = RCL["Macros are made from Readycheck's own sets. Pick one of those (ItemRack sets cannot be read)."],
        weapons = RCL["That set holds no weapon, so there is nothing a key press could change in a fight."],
        long = RCL["The weapon names are too long for one macro (the game allows 255 letters)."],
        combat = RCL["Macros cannot be made in a fight. Try again after it."],
        full = RCL["Your macro list is full. Delete one and try again."],
    }

    yPos = L.Card(parent, yPos, RCL["Rules"], function(card, cy)
        local rules = AS.Rules()
        if #rules == 0 then
            cy = L.Desc(card, cy, string_format(RCL["No rules yet. Add one and pick the set to wear; it is for everything until you pick a %s or a spec."], RCL[word]))
        end
        local setItems, specItems = SetItems(), SpecItems(AS)
        for i, rule in ipairs(rules) do
            local capI = i
            -- line 1: on / off, the stance or form, the spec
            local cb = UI:CreateCheckbox(card, "", rule.on ~= false)
            cb:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy - 2)
            cb:SetScript("OnClick", function()
                local on = cb:GetChecked() and true or false
                RC:ForceCheckboxUpdate(cb, on)
                AS.SetRuleOn(rule, on)
                Rebuild()
            end)
            Tip(cb, string_format(RCL["Rule %d"], i), RCL["Untick to keep the rule but stop it swapping."])
            local x = 42
            local items, known
            if hasForms or rule.form ~= nil then
                Text(card, x, cy - 6, RCL["In"])
                x = x + 20
                items, known = FormItems(AS, rule)
                local fdd = UI:CreateScrollableDropdown(card, 190, "", 10)
                fdd:SetPoint("TOPLEFT", card, "TOPLEFT", x, cy)
                fdd:SetItems(items, function(value)
                    if value == ANY then value = nil end
                    AS.SetRuleForm(rule, value)
                    Rebuild()
                end)
                Pick(fdd, items, rule.form == nil and ANY or rule.form)
                fdd._rcLabel = string_format(RCL["Rule %d: %s"], i, RCL[word])
                x = x + 198
                Text(card, x, cy - 6, RCL["as"])
                x = x + 20
            else
                Text(card, x, cy - 6, RCL["As"])
                x = x + 22
            end
            local sdd = UI:CreateScrollableDropdown(card, 150, "", 6)
            sdd:SetPoint("TOPLEFT", card, "TOPLEFT", x, cy)
            sdd:SetItems(specItems, function(value)
                if value == ANY then value = nil end
                AS.SetRuleSpec(rule, value)
                Rebuild()
            end)
            Pick(sdd, specItems, rule.spec == nil and ANY or rule.spec)
            if sdd.SetSearchEnabled then sdd:SetSearchEnabled(false) end
            sdd._rcLabel = string_format(RCL["Rule %d: spec"], i)
            cy = cy - 30

            -- line 2: the set, the macro, order, remove
            Text(card, 42, cy - 6, RCL["wear"])
            local gdd = UI:CreateScrollableDropdown(card, 200, "", 10)
            gdd:SetPoint("TOPLEFT", card, "TOPLEFT", 78, cy)
            gdd:SetItems(setItems, function(value)
                AS.SetRuleSet(rule, value or "")
                Rebuild()
            end)
            Pick(gdd, setItems, rule.set or "")
            gdd._rcLabel = string_format(RCL["Rule %d: gear set"], i)

            local note                                   -- what the macro button answered
            local macro = UI:CreateStyledButton(card, RCL["Macro"], 62, 22)
            macro:SetPoint("TOPLEFT", card, "TOPLEFT", 286, cy - 1)
            macro:SetScript("OnClick", function()
                local name, why = AS.MakeMacro(rule)
                if name then
                    note:SetText(string_format(RCL["Made the macro \"%s\". It is in your macro list (/m): drag it to a bar and use it in place of the %s button."], name, RCL[word]))
                    note:SetTextColor(Col("text", "green"))
                    if ShowMacroFrame and not InCombatLockdown() then pcall(ShowMacroFrame) end
                else
                    note:SetText(string_format(MACRO_WHY[why] or RCL["The macro could not be made."], RCL[word]))
                    note:SetTextColor(Col("text", "red"))
                end
            end)
            Tip(macro, RCL["Make a macro for this rule"],
                string_format(RCL["In a fight the game only lets a key press change weapons, so the rule itself has to wait for the fight to end. This makes a macro that goes into the %s AND equips this set's weapons on one key. The rest of the set still goes on after the fight."], RCL[word]))

            local up = UI:CreateStyledButton(card, "^", 22, 22)
            up:SetPoint("LEFT", macro, "RIGHT", 6, 0)
            up:SetScript("OnClick", function() if AS.MoveRule(capI, -1) then Rebuild() end end)
            Tip(up, RCL["Move up"], RCL["When two rules fit equally well, the higher one wins."])
            local down = UI:CreateStyledButton(card, "v", 22, 22)
            down:SetPoint("LEFT", up, "RIGHT", 4, 0)
            down:SetScript("OnClick", function() if AS.MoveRule(capI, 1) then Rebuild() end end)
            Tip(down, RCL["Move down"], RCL["When two rules fit equally well, the higher one wins."])
            local remove = UI:CreateStyledButton(card, RCL["Remove"], 62, 22)
            remove:SetPoint("LEFT", down, "RIGHT", 6, 0)
            remove:SetScript("OnClick", function()
                AS.RemoveRule(capI)
                Rebuild()
            end)
            cy = cy - 28

            -- what is wrong with it, if anything; and the macro's answer
            local warn, warnKey = nil, "red"
            if rule.set == nil or rule.set == "" then
                warn = RCL["Pick a set: without one this rule does nothing."]
            elseif not AS.SetExists(rule.set) then
                warn = string_format(RCL["The set \"%s\" no longer exists: pick another."], rule.set)
            elseif rule.form ~= nil and rule.form ~= 0 and known == false then
                warn = string_format(RCL["This character does not have that %s, so this rule never fits here."], RCL[word])
            elseif rule.form == nil and rule.spec == nil then
                warn, warnKey = RCL["Fits everything: it is used whenever no other rule fits better."], "gray"
            end
            note = Text(card, 42, cy, warn or "", 10, "text", warnKey)
            note:SetPoint("RIGHT", card, "RIGHT", -14, 0)
            note:SetJustifyH("LEFT")
            note:SetWordWrap(true)
            cy = cy - 16
            -- a hairline between rules
            if i < #rules then
                local line = card:CreateTexture(nil, "ARTWORK")
                line:SetTexture(RC.UI.FLAT)
                local r, g, b = Col("text", "gray")
                line:SetVertexColor(r, g, b, 0.18)
                line:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy - 3)
                line:SetPoint("RIGHT", card, "RIGHT", -14, 0)
                line:SetHeight(1)
                if RC.Line then RC.Line(line, "H", 1) end
            end
            cy = cy - 10
        end
        local add = UI:CreateStyledButton(card, RCL["Add a rule"], 110, 24)
        add:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy)
        add:SetScript("OnClick", function()
            AS.AddRule()
            Rebuild()
        end)
        Tip(add, RCL["Add a rule"], string_format(RCL["A new rule is for everything (any %s, any spec). Pick its set, then narrow it if you want."], RCL[word]))
        cy = cy - 30
        if not hasForms then
            cy = L.Desc(card, cy, RCL["This class has no stances or forms on this game version, so its rules go by spec."])
        end
        return cy
    end)

    ------------------------------------------------------------------
    -- 6. in a fight
    ------------------------------------------------------------------
    yPos = L.Card(parent, yPos, RCL["In a fight"], function(card, cy)
        cy = L.Desc(card, cy, string_format(RCL["The game does not let an addon change gear in a fight by itself: only a key press may, and then only weapons. So a %s change in a fight is remembered, not acted on. For weapons mid-fight use a rule's Macro button."], RCL[word]))
        cy = L.Check(card, cy - 2, string_format(RCL["When the fight ends, put on the set for the %s I am in"], RCL[word]), AS.Opt("afterCombat") ~= false, function(on)
            AS.SetOpt("afterCombat", on)
        end, RCL["One swap, for where you ended up - not one for every change during the fight. A set you (or a boss swap, or a route step) asked for during the fight goes on instead."])
        return cy
    end)

    ------------------------------------------------------------------
    -- 7. the details, each one a setting
    ------------------------------------------------------------------
    yPos = L.Card(parent, yPos, RCL["Details"], function(card, cy)
        cy = L.Check(card, cy, RCL["Boss gear swaps come first"], AS.Opt("bossFirst") ~= false, function(on)
            AS.SetOpt("bossFirst", on)
        end, RCL["While a boss's own gear set or trinkets are in force (and until its after-fight set is on), the rules stand down. Untick and a rule can replace the boss's set - which also releases the boss's trinket lock."])
        cy = L.Slider(card, cy - 4, { label = RCL["Wait before swapping"], min = AS.DELAY_MIN, max = AS.DELAY_MAX, step = 0.1, scale = 10,
            value = AS.Opt("delay"), fmt = function(v) return string_format("%.1fs", v) end,
            set = function(v) AS.SetOpt("delay", v) end })
        cy = L.Desc(card, cy + 6, string_format(RCL["A %s you only pass through for less than this does not swap anything."], RCL[word]))
        cy = L.Check(card, cy - 2, RCL["Also apply the rules when I log in or reload"], AS.Opt("atLogin") == true, function(on)
            AS.SetOpt("atLogin", on)
        end)
        cy = L.Check(card, cy, RCL["Say each automatic swap in chat"], AS.Opt("announce") == true, function(on)
            AS.SetOpt("announce", on)
        end, RCL["The gear swap notice already says why a set went on (Gear Manager > Settings > Swap notices)."])
        local reset = UI:CreateStyledButton(card, RCL["Reset these details"], 150, 22)
        reset:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cy - 4)
        reset:SetScript("OnClick", function()
            for key in pairs(AS.DEFAULTS) do AS.SetOpt(key, AS.DEFAULTS[key]) end
            Rebuild()
        end)
        Tip(reset, RCL["Reset these details"], RCL["The four choices above and the wait go back to how Readycheck ships. Your rules stay."])
        return cy - 32
    end)

    return yPos
end
