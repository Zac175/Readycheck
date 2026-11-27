------------------------------------------------------------------------
-- Readycheck - Smart Macro
-- Editor for per-macro condition/action rules that rewrite an in-game
-- macro body based on current target; RC.SmartMacro evaluates them live.
-- Settings live under RC.db.smartMacros (synced as "smartMacros" in
-- SidebarMeshSync.lua).
-- An entry of the list is an in-game macro (by name) or one slot of the
-- action bars (mac.slot; 0 until one is picked). Either can have a group
-- (mac.group) and a link to a boss ability (mac.ability).
-- Also here (2026-11-16): what the raid pages use -
--   the SWAP pickers that hand an entry, or a group of them, one item for
--   a boss or a route step (RC:BuildSmartMacroSwapCard for a boss's page,
--   RC:BuildSmartMacroSwapRow for the route's step editor); the swaps
--   themselves are raid-profile data: bosses[boss].macroSwaps and route
--   step actions.macros;
--   the LINK card under each ability of a boss's page
--   (RC:BuildSmartMacroLinkCard): which macros and bar slots are only
--   live on bosses where that ability is switched on.
-- SWITCHED ON BY RC.smartKeys, which Readycheck_Features sets
-- (SmartKeys.lua; Readycheck_Testing's until 2026-11-18): without it this
-- page is the rules editor alone, and the raid pages show none of the
-- above. The bar preview, the click-a-button slot picker and the macro
-- list those cards use live in that file too.
------------------------------------------------------------------------
local AddonName = "Readycheck"
local RC = _G[AddonName]
-- Taint-safe API local (fallback on RC.Compat, built in Core; never
-- write _G - a written Blizzard global taints its readers)
local GetItemInfo = GetItemInfo or (RC and RC.Compat and RC.Compat.GetItemInfo)
local GetSpellInfo = GetSpellInfo or (RC and RC.Compat and RC.Compat.GetSpellInfo)

-- Forward-declared so the 'function SM_RenderList/Edit' definitions below
-- assign these file-locals instead of leaking globals into _G.
local SM_RenderList, SM_RenderEdit, SM_RenderSlotEdit

local PAD    = 10
local ROW_H  = 28
local LBL_W  = 95
local COND_W = 165
local VAL_W  = 130

local COND_ITEMS = {
    { text = RCL["Default (no target)"],        value = "notarget"   },
    { text = RCL["Undead"],                     value = "undead"     },
    { text = RCL["Not Undead"],                 value = "notundead"  },
    { text = RCL["Name contains..."],           value = "named",     needsValue = true },
    { text = RCL["Specific Boss / Mob"],        value = "bossPicker", needsPicker = true },
    { text = RCL["World boss"],                 value = "boss"       },
    { text = RCL["Elite"],                      value = "elite"      },
    { text = RCL["Enemy"],                      value = "enemy"      },
    { text = RCL["Friendly"],                   value = "friendly"   },
    { text = RCL["Always (fires regardless)"],  value = "always"     },
}

local function CondLabel(condValue)
    for _, it in ipairs(COND_ITEMS) do
        if it.value == condValue then return it.text end
    end
    return "Select condition..."
end

local function CondNeedsValue(condValue)
    for _, it in ipairs(COND_ITEMS) do
        if it.value == condValue then return it.needsValue end
    end
    return false
end

local function CondNeedsPicker(condValue)
    for _, it in ipairs(COND_ITEMS) do
        if it.value == condValue then return it.needsPicker end
    end
    return false
end

local function GetBossPickerItems()
    local items = { { text = RCL["(type a custom name below)"], value = "" } }
    local raids = { "Naxxramas", "Ahn'Qiraj", "Blackwing Lair", "Molten Core" }
    -- another game version lists its own raids (RaidFlavor.lua)
    if RC._raidFlavorApplied then raids = RC:RaidNames() end
    local seen = {}
    for _, raid in ipairs(raids) do
        local cfg = RC.raidMobConfigs and RC.raidMobConfigs[raid]
        if cfg then
            local names = {}
            for bossName in pairs(cfg) do
                if not seen[bossName] then
                    seen[bossName] = true
                    names[#names + 1] = bossName
                end
            end
            table.sort(names)
            if #names > 0 then
                -- "__header__" is a non-selectable divider row; stripped out
                -- before the list is handed to the dropdown (see filteredItems below).
                items[#items + 1] = { text = "-- " .. raid .. " --", value = "__header__" }
                for _, name in ipairs(names) do
                    items[#items + 1] = { text = name, value = name }
                end
            end
        end
    end
    return items
end

local function GetRuleRaidScopeItems()
    local items = { { text = RCL["Any raid"], value = "any" } }
    for _, r in ipairs(RC.availableRaids or {}) do
        items[#items + 1] = { text = r, value = r }
    end
    return items
end

local function GetRuleProfileItems(raidName)
    local items = { { text = RCL["Any profile"], value = "any" } }
    local rp = RC.db and RC.db.raidProfiles and RC.db.raidProfiles[raidName]
    if rp and rp.profiles then
        local names = {}
        for name in pairs(rp.profiles) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            items[#items + 1] = { text = name, value = name }
        end
    end
    return items
end

local ACTION_ITEMS = {
    { text = RCL["/use  (item or spell)"], value = "use"  },
    { text = RCL["/cast (spell only)"],    value = "cast" },
}

local SM_Editor = { selectedId = nil }

local function MakeFS(parent, size, text)
    local fs = RC:CreateFontString(parent, "OVERLAY", nil, size or 11)
    if text then fs:SetText(text) end
    return fs
end

local function Btn(parent, label, w, h)
    return RC.UI:CreateStyledButton(parent, label, w or 100, h or 22)
end

local function MakeDrop(parent, x, y, w, items, currentVal, onChange)
    local label = RCL["Select..."]
    for _, it in ipairs(items) do
        if it.value == currentVal then label = it.text; break end
    end
    local d = RC.UI:CreateScrollableDropdown(parent, w, label, 12)
    d:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
    if d.menu then
        d.menu:SetFrameStrata("TOOLTIP")
        d.menu:SetFrameLevel(200)
    end
    d:SetItems(items, function(val) if onChange then onChange(val) end end)
    d:SetSelectedValue(currentVal, label)
    return d
end

------------------------------------------------------------------------
-- SWAPS: one item for a macro or a group, from a raid page
-- (2026-11-16, Zac: "i wanted it added to raid configs and have the
-- ability like if i set mrp for this boss or route step and i have a
-- smart macro for potions it will change my macro to that"; "i have
-- individual potions bound on my bar i want to be able to change all of
-- them to this potion so i dont fat finger something on accident").
-- A swap = { group = "<group>" | macro = "<macro name>", item = "<item
-- name>", itemId = n }; the engine is RC.SmartMacro (Readycheck_Features).
------------------------------------------------------------------------
local function TrimStr(v) return (type(v) == "string") and v:match("^%s*(.-)%s*$") or "" end

-- BAR SLOTS. The action bars' 120 slots are the game's own: every bar
-- addon shows the same ones, so an entry names a slot by its number.
local function SlotNumber(v)
    local n = tonumber(v)
    if n and n >= 1 and n <= 120 and n == math.floor(n) then return n end
    return nil
end
-- an entry that is a bar slot (0: none picked yet)
local function IsSlotEntry(mac) return type(mac) == "table" and mac.slot ~= nil end
-- what a slot holds, in words, and its icon (nil: empty)
function RC:ActionSlotHolds(slot)
    local kind, id = GetActionInfo(slot)
    if not kind then return nil end
    local name
    if kind == "spell" then
        name = GetSpellInfo(id)
    elseif kind == "item" then
        name = GetItemInfo(id)
    elseif kind == "macro" then
        name = C_ActionBar.GetActionText(slot)
    end
    return name or kind, C_ActionBar.GetActionTexture(slot)
end
function RC:ActionSlotLabel(slot)
    local n = SlotNumber(slot)
    if not n then return RCL["Bar slot (none picked)"] end
    local holds = RC:ActionSlotHolds(n)
    return RCL["Bar slot "] .. n .. (holds and (" - " .. holds) or "")
end
-- what an entry goes by in a list
local function EntryLabel(mac)
    if IsSlotEntry(mac) then return RC:ActionSlotLabel(mac.slot) end
    local n = TrimStr(mac.macroName)
    return n ~= "" and n or RCL["(unnamed)"]
end

-- what a swap can be aimed at: every group first, then every macro, then
-- every bar slot
function RC:SmartMacroSwapTargets()
    local out, groups, seenG, names, seenM, slots, seenS = {}, {}, {}, {}, {}, {}, {}
    for _, mac in ipairs((RC.db and RC.db.smartMacros) or {}) do
        local g = TrimStr(mac.group)
        if g ~= "" and not seenG[g:lower()] then
            seenG[g:lower()] = true
            groups[#groups + 1] = g
        end
        if IsSlotEntry(mac) then
            local sn = SlotNumber(mac.slot)
            if sn and not seenS[sn] then
                seenS[sn] = true
                slots[#slots + 1] = sn
            end
        else
            local n = TrimStr(mac.macroName)
            if n ~= "" and not seenM[n] then
                seenM[n] = true
                names[#names + 1] = n
            end
        end
    end
    table.sort(groups, function(a, b) return a:lower() < b:lower() end)
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    table.sort(slots)
    for _, g in ipairs(groups) do out[#out + 1] = { text = RCL["All of: "] .. g, value = "g:" .. g } end
    for _, n in ipairs(names) do out[#out + 1] = { text = n, value = "m:" .. n } end
    for _, sn in ipairs(slots) do out[#out + 1] = { text = RC:ActionSlotLabel(sn), value = "s:" .. sn } end
    return out
end

-- the macros and bar slots of one group, as they are listed
function RC:SmartMacroGroupMembers(group)
    local out, g = {}, TrimStr(group):lower()
    if g == "" then return out end
    for _, mac in ipairs((RC.db and RC.db.smartMacros) or {}) do
        if TrimStr(mac.group):lower() == g then
            if IsSlotEntry(mac) then
                local sn = SlotNumber(mac.slot)
                if sn then out[#out + 1] = RCL["slot "] .. sn end
            elseif TrimStr(mac.macroName) ~= "" then
                out[#out + 1] = mac.macroName
            end
        end
    end
    table.sort(out)
    return out
end

-- THE ABILITIES AN ENTRY CAN BE LINKED TO: the tiles of a boss's page
-- for this character (RC:GetAvailableAbilities), as { key, name, icon }
function RC:SmartMacroLinkAbilities()
    local out = {}
    for _, info in ipairs(RC:GetAvailableAbilities("boss") or {}) do
        out[#out + 1] = { key = info[1], name = info[2], icon = info[3] }
    end
    return out
end
local function AbilityName(key)
    for _, a in ipairs(RC:SmartMacroLinkAbilities()) do
        if a.key == key then return a.name end
    end
    return tostring(key)
end

-- The items a swap's "Pick" list offers: what you carry of the
-- consumables catalogue, potions first - each as the item really in the
-- bags (a merged row or a target dummy is whichever version is carried).
-- `all` lists the whole catalogue instead (editing another character's
-- raid: their bags are not known here), without the dummies.
local SWAP_CATS = { "potions", "protectionPotions", "utilities", "flasks", "elixirs", "food",
    "drinks", "buffs", "classItems", "special" }
function RC:SmartMacroItemChoices(all)
    local items, seen = {}, {}
    local rc = RC.raidConsumables or {}
    for _, catKey in ipairs(SWAP_CATS) do
        local cat = rc[catKey]
        if type(cat) == "table" and type(cat.items) == "table" then
            local list = {}
            for itemId, data in pairs(cat.items) do
                local row = type(data) == "table" and data or nil
                local synthetic = row and (row.baseItemId ~= nil or row.slot ~= nil)
                if type(itemId) == "number" and not synthetic then
                    local id
                    if all then
                        id = (not RC:IsTargetDummy(itemId)) and itemId or nil
                    else
                        id = RC:CarriedVersion(itemId, row)
                    end
                    if id and not seen[id] then
                        seen[id] = true
                        list[#list + 1] = { id = id, name = RC:ItemLabel(itemId, row), icon = RC:ItemLabelIcon(id, row) }
                    end
                end
            end
            table.sort(list, function(x, y) return (x.name or "") < (y.name or "") end)
            for _, t in ipairs(list) do
                items[#items + 1] = { text = t.name, value = t.id, icon = t.icon }
            end
        end
    end
    if #items == 0 then
        items[1] = { text = RCL["Nothing from the consumables list in your bags"], value = 0 }
    end
    return items
end

-- the value a swap's aim shows in its picker
local function SwapAimValue(e)
    local m = TrimStr(e.macro)
    if m ~= "" then return "m:" .. m, m end
    local sn = SlotNumber(e.slot)
    if sn then return "s:" .. sn, RC:ActionSlotLabel(sn) end
    local g = TrimStr(e.group)
    if g ~= "" then return "g:" .. g, RCL["All of: "] .. g end
    return nil
end

-- the item a swap names, for its box
local function SwapItemText(e)
    local name = TrimStr(e.item)
    if name == "" and tonumber(e.itemId) then
        name = GetItemInfo(tonumber(e.itemId)) or ("item:" .. tostring(e.itemId))
    end
    return name
end

-- One swap's controls on `parent`, top-left at (x, y):
--   [ which macro or group v ] [ item name ] [ Pick v ]
-- e is the swap's own table and is written in place. opts: targetW, itemW,
-- pickW, all (the Pick list shows the whole catalogue), onChange(e, typed)
-- after any change: the caller saves, and redraws unless `typed` - the
-- item box gave up focus with a new name in it, and redrawing then would
-- eat the click that took the focus.
-- Returns the row's height.
function RC:BuildSmartMacroSwapRow(parent, x, y, e, opts)
    opts = opts or {}
    local targetW, itemW, pickW = opts.targetW or 150, opts.itemW or 170, opts.pickW or 76
    local function Changed(typed)
        if RC.SmartMacro then RC.SmartMacro:RequestEvaluate() end
        if opts.onChange then opts.onChange(e, typed) end
    end

    local targets = RC:SmartMacroSwapTargets()
    local curVal, curLabel = SwapAimValue(e)
    local known = false
    for _, t in ipairs(targets) do if t.value == curVal then known = true break end end
    -- (a swap aimed at a macro or group that is gone still shows what it names)
    if curVal and not known then targets[#targets + 1] = { text = curLabel .. RCL[" (not set up)"], value = curVal } end
    local empty = (#targets == 0)
    local tDD = RC.UI:CreateScrollableDropdown(parent, targetW,
        empty and RCL["No smart macros yet"] or RCL["Which key..."], 10)
    tDD:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y + 2)
    tDD:SetItems(targets, function(val)
        local kind, name = tostring(val):match("^([gms]):(.+)$")
        if not kind then return end
        e.group, e.macro, e.slot = nil, nil, nil
        if kind == "g" then e.group = name elseif kind == "m" then e.macro = name else e.slot = SlotNumber(name) end
        Changed()
    end)
    if curVal then tDD:SetSelectedValue(curVal, curLabel) end

    local eb = RC.UI:CreateStyledEditBox(parent, { height = 22, width = itemW, maxLetters = 80 })
    eb:SetPoint("TOPLEFT", parent, "TOPLEFT", x + targetW + 6, y + 2)
    eb.editBox:SetText(SwapItemText(e))
    eb.editBox:SetCursorPosition(0)
    local function Commit(self, typed)
        local txt = TrimStr(self:GetText())
        if txt == SwapItemText(e) then return end
        -- typed (or shift-clicked in): the name is the item; the picked id
        -- no longer says which
        e.item, e.itemId = (txt ~= "" and txt or nil), nil
        Changed(typed)
    end
    eb.editBox:SetScript("OnEnterPressed", function(self) Commit(self) self:ClearFocus() end)
    eb.editBox:SetScript("OnEditFocusLost", function(self) Commit(self, true) end)
    -- shift-click an item anywhere to drop its name in (SmartMacro's hook)
    eb.editBox:HookScript("OnEditFocusGained", function(self)
        if RC.SmartMacro then RC.SmartMacro._lastFocusedEB = self end
    end)
    eb.editBox:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(RCL["The item the macro uses"], 1, 1, 1)
        GameTooltip:AddLine(RCL["Type its name, shift-click it in your bags while this box is active, or pick it from the list."], 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    eb.editBox:HookScript("OnLeave", function() GameTooltip:Hide() end)

    local pDD = RC.UI:CreateScrollableDropdown(parent, pickW, RCL["Pick"], 12)
    pDD:SetPoint("TOPLEFT", parent, "TOPLEFT", x + targetW + 6 + itemW + 6, y + 2)
    pDD:SetItems(RC:SmartMacroItemChoices(opts.all), function(val)
        local id = tonumber(val)
        if not id or id == 0 then return end
        -- (its real name for the macro; until the client has it, the
        -- macro goes by the item's number)
        e.itemId, e.item = id, (GetItemInfo(id))
        eb.editBox:SetText(SwapItemText(e))
        eb.editBox:SetCursorPosition(0)
        Changed()
    end)
    return 26, tDD, eb, pDD
end

-- A boss's swaps as one card on its raid page (the "Macros" tile).
-- cfg is the boss's settings table; its macroSwaps list is created on the
-- first add and removed again when the last row goes. opts: all,
-- onRerender() to redraw the page after a row is added or removed,
-- onSave() to save. Returns the new yPos.
function RC:BuildSmartMacroSwapCard(parent, yPos, cfg, opts)
    opts = opts or {}
    local grayC = RC:GetColor("text", "disabled")
    local card = RC:CreateSettingsCard(parent, yPos, RCL["Smart macros on this boss"])
    local cy = -35
    local function Line(text, col, size)
        local fs = MakeFS(card, size or 10, text)
        fs:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
        local cw = card:GetWidth() or 0
        fs:SetWidth(cw > 200 and (cw - 30) or 420)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        if col then fs:SetTextColor(col.r or col[1], col.g or col[2], col.b or col[3], 1) end
        cy = cy - math.max(14, (fs:GetStringHeight() or 12)) - 8
        return fs
    end
    Line(RCL["Hand a smart macro, a bar slot - or every one of a group - one item for this boss. From the moment you target the boss it uses that item, whatever else it is set to, until you target another enemy or the fight is over. Pick a group and every key in it becomes the same item, so no key can fire the wrong one. Nothing can change in a fight: target the boss before the pull."],
        grayC)

    local function Save()
        if opts.onSave then opts.onSave() else RC:SaveConfigurationToProfile() end
    end
    local function Rerender()
        if opts.onRerender then opts.onRerender() end
    end

    if not RC.CreateSmartMacro then
        Line(RCL["Smart macros need the Readycheck_Features addon. Enable it in your AddOns list and /reload."],
            RC:GetColor("text", "red"), 11)
    elseif #RC:SmartMacroSwapTargets() == 0 then
        Line(RCL["No smart macros or bar slots yet. Add them on the Smart Macros page (under Extras) - a macro by its exact in-game name, a bar slot by picking its button - and give the ones that belong together the same group: \"Potions\" for every potion key."],
            RC:GetColor("text", "warning"), 11)
    end

    local list = (type(cfg.macroSwaps) == "table") and cfg.macroSwaps or {}
    for i, e in ipairs(list) do
        local idx = i
        local h = RC:BuildSmartMacroSwapRow(card, 15, cy, e, {
            all = opts.all,
            onChange = function(_, typed)
                Save()
                if not typed then Rerender() end
            end,
        })
        local x = RC.UI:CreateXCloseButton(card, 18, function()
            table.remove(cfg.macroSwaps, idx)
            if #cfg.macroSwaps == 0 then cfg.macroSwaps = nil end
            if RC.SmartMacro then RC.SmartMacro:RequestEvaluate() end
            Save()
            Rerender()
        end)
        x:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, cy + 1)
        cy = cy - h
        -- a group: say which macros it covers
        local g = TrimStr(e.group)
        if g ~= "" and TrimStr(e.macro) == "" then
            local members = RC:SmartMacroGroupMembers(g)
            local txt = (#members > 0) and (g .. ": " .. table.concat(members, ", "))
                or (g .. RCL[": nothing is in this group yet"])
            local fs = MakeFS(card, 9, txt)
            fs:SetPoint("TOPLEFT", card, "TOPLEFT", 17, cy + 2)
            fs:SetPoint("TOPRIGHT", card, "TOPRIGHT", -34, cy + 2)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            if grayC then fs:SetTextColor(grayC.r, grayC.g, grayC.b, 1) end
            cy = cy - 16
        end
        cy = cy - 4
    end

    local addBtn = Btn(card, RCL["+ Add a key"], 120, 22)
    addBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
    addBtn:SetScript("OnClick", function()
        cfg.macroSwaps = (type(cfg.macroSwaps) == "table") and cfg.macroSwaps or {}
        cfg.macroSwaps[#cfg.macroSwaps + 1] = {}
        Save()
        Rerender()
    end)
    cy = cy - 30

    card:SetContentHeight(math.abs(cy))
    return yPos - card:GetHeight() - 15
end

-- THE LINK CARD under an ability of a boss's page (2026-11-16, Zac: "i
-- want the macro for each of the configurable things inside a boss
-- deathwish reck etc. ... i want to make it so my deathwish is only
-- active for bosses i should death wish on"): which macros and bar slots
-- follow this ability. A link is the entry's own (mac.ability), so it is
-- the same on every boss: live where the ability is switched on, off
-- where it is not. cfg: this boss's settings, for the line that says
-- which it is here. opts.onRerender() after a change. Returns the new yPos.
function RC:BuildSmartMacroLinkCard(parent, yPos, abilityKey, abilityName, cfg, opts)
    opts = opts or {}
    local grayC = RC:GetColor("text", "disabled")
    local card = RC:CreateSettingsCard(parent, yPos, RCL["Keys for "] .. tostring(abilityName))
    local cy = -35
    local function Line(text, col, size)
        local fs = MakeFS(card, size or 10, text)
        fs:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
        local cw = card:GetWidth() or 0
        fs:SetWidth(cw > 200 and (cw - 30) or 420)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        if col then fs:SetTextColor(col.r, col.g, col.b, 1) end
        cy = cy - math.max(14, (fs:GetStringHeight() or 12)) - 8
        return fs
    end
    local function Changed()
        RC:SaveConfigurationToProfile()
        if RC.SmartMacro then RC.SmartMacro:RequestEvaluate() end
        if opts.onRerender then opts.onRerender() end
    end

    Line(RCL["A button linked here is only live on bosses where this is switched on. Linking puts a small macro on the button in place of its spell or item - same key, same place, same icon - and nothing is ever taken off your bars. On a boss that is set up but has this off, that macro does nothing from the moment you target the boss until you target another enemy or the fight is over. On a boss with nothing set up your keys are as you made them. Unlinking puts the spell or item back."],
        grayC)
    local on = RC:EncounterAbilityOn(cfg, abilityKey)
    local item = on and RC:EncounterAbilityItem(cfg, abilityKey) or nil
    if not RC:EncounterHasConfig(cfg) then
        Line(RCL["On this boss: nothing is set up, so your keys are as you made them."], grayC, 11)
    elseif on and item then
        Line(RCL["On this boss: live, and using "] .. (GetItemInfo(item) or ("item:" .. item)) .. RCL[" (the one item set up here)."],
            RC:GetColor("text", "success"), 11)
    elseif on then
        Line(RCL["On this boss: live."], RC:GetColor("text", "success"), 11)
    else
        Line(RCL["On this boss: off (it is not switched on here)."], RC:GetColor("text", "warning"), 11)
    end

    Line(RCL["The key cannot be locked until its reminder goes off: the game lets no addon change a macro or a bar slot in a fight. Instead a linked button on your bars is dimmed and reads WAIT on the boss until this ability's reminder has gone off there."],
        grayC)

    local list = (RC.db and RC.db.smartMacros) or {}
    local linkedMacros = {}
    for _, mac in ipairs(list) do
        if not IsSlotEntry(mac) and TrimStr(mac.macroName) ~= "" and mac.ability == abilityKey then
            linkedMacros[#linkedMacros + 1] = mac
        end
    end
    local autoOn = RC:SmartKeyAutoOn(abilityKey)
    local WHY = {
        busy = RCL["A button can only be linked out of combat, with nothing on the cursor."],
        empty = RCL["That button is empty: put the spell, item or macro on it first."],
        full = RCL["No room for another macro: delete one in /macro first."],
    }
    local function LinkSlot(slot)
        local mac = RC:SmartKeyEntryOnSlot(slot)
        if mac and mac.ability == abilityKey then
            -- (one found automatically comes straight back: nothing to do)
            if mac.auto and autoOn then return end
            RC:SmartKeyUnlinkSlot(slot)
        else
            -- (by hand: it is no longer the automatic keys' to drop)
            local made, why = RC:SmartKeyLinkSlot(slot, abilityKey, false)
            if not made then RC:Print(WHY[why] or WHY.empty) end
        end
        Changed()
    end

    if not RC.CreateSmartMacro then
        Line(RCL["Smart macros need the Readycheck_Features addon. Enable it in your AddOns list and /reload."],
            RC:GetColor("text", "red"), 11)
    else
        -- AUTOMATIC: every bar button that holds this ability, found and
        -- linked without a click (SmartKeys.lua, RC:SmartKeyAutoSync)
        if RC:SmartKeyAutoOffered(abilityKey) then
            local chk = RC.UI:CreateCheckbox(card, RCL["Automatic: find it on my bars"], autoOn)
            chk:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
            chk:SetScript("OnClick", function(cb)
                local on = cb:GetChecked() and true or false
                RC:ForceCheckboxUpdate(cb, on)
                RC:SetSmartKeyAuto(abilityKey, on)
                Changed()
            end)
            cy = cy - 26
            Line(RCL["Ticked, nothing needs linking or making: every button on your bars that holds this - the spell or item itself, or a macro of yours that only casts it - is linked for you, and a button you add later is too. A macro that also casts something else is left alone."],
                grayC)
        end

        -- BAR BUTTONS: the bars as they are; a click links a button, a
        -- second click unlinks it
        Line(RCL["Your bars - click a button to link it, click it again to unlink:"], RC:GetColor("text", "normal"), 11)
        cy = cy + 2
        local h = RC:BuildBarPreview(card, 15, cy, {
            key = "link",
            lit = function(slot)
                local mac = RC:SmartKeyEntryOnSlot(slot)
                return mac ~= nil and mac.ability == abilityKey
            end,
            tip = function(slot)
                local mac = RC:SmartKeyEntryOnSlot(slot)
                if mac and mac.ability == abilityKey and mac.auto and autoOn then
                    return RCL["Found automatically. Untick Automatic to pick by hand."]
                end
                if mac and mac.ability == abilityKey then return RCL["Linked. Click to unlink (what it held is put back)."] end
                local other = mac and TrimStr(mac.ability) or ""
                if other ~= "" then return RCL["Linked to "] .. AbilityName(other) .. RCL[". Click to link it here instead."] end
                return RCL["Click to link this button."]
            end,
            onPick = LinkSlot,
        })
        cy = cy - h - 8
        local realBtn = Btn(card, RCL["Click a button on my bars"], 210, 22)
        realBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
        realBtn:SetScript("OnClick", function()
            RC:PickActionSlot(function(slot)
                if not slot then return end
                local mac = RC:SmartKeyEntryOnSlot(slot)
                if mac and mac.ability == abilityKey then return end
                LinkSlot(slot)
            end)
        end)
        cy = cy - 32

        -- MACROS: the ones linked, and the game's macros to link another
        Line(RCL["Macros:"], RC:GetColor("text", "normal"), 11)
        cy = cy + 2
        for _, mac in ipairs(linkedMacros) do
            local cap = mac
            local fs = MakeFS(card, 11, EntryLabel(mac))
            fs:SetPoint("TOPLEFT", card, "TOPLEFT", 17, cy)
            fs:SetPoint("TOPRIGHT", card, "TOPRIGHT", -40, cy)
            fs:SetJustifyH("LEFT")
            fs:SetWordWrap(false)
            local x = RC.UI:CreateXCloseButton(card, 16, function()
                RC:SmartKeyUnlink(cap)
                Changed()
            end)
            x:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, cy + 2)
            cy = cy - 20
        end
        if #linkedMacros > 0 then cy = cy - 4 end
        local dd = RC.UI:CreateScrollableDropdown(card, 260, RCL["Link one of your macros..."], 10)
        dd:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy + 2)
        dd:SetItems(RC:SmartKeyMacroChoices(), function(name)
            if type(name) ~= "string" or name == "" then return end
            RC:SmartKeyLinkMacro(name, abilityKey, false)
            Changed()
        end)
        cy = cy - 30
    end

    card:SetContentHeight(math.abs(cy))
    return yPos - card:GetHeight() - 15
end

-- preserveScroll: true from in-place edits (dropdowns, up/down, add/delete
-- condition or rule) that rebuild this same page, so the sidebar doesn't
-- jump to the top. Back/list-navigation callers omit it.
function RC:ShowSidebarSmartMacro(frame, preserveScroll)
    -- RC.SmartMacro hooks ChatEdit_InsertLink to fill whichever edit box last
    -- had focus here when an item link is shift-clicked into chat; clear it
    -- on reload so a stale box from a previous view isn't targeted.
    if RC.SmartMacro then RC.SmartMacro._lastFocusedEB = nil end

    local savedScroll = 0
    if preserveScroll and frame.contentFrame then
        savedScroll = frame.contentFrame:GetVerticalScroll() or 0
    end

    self:ClearSidebarContent(self.sidebarConfigFrame)
    local parent = frame.scrollChild

    if not RC.db.smartMacros then
        local lbl = MakeFS(parent, 12,
            RCL["Smart Macro system not yet ready. Try again in a moment."])
        lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -40)
        do local _c = RC:GetColor("text", "red"); lbl:SetTextColor(_c.r, _c.g, _c.b, 1) end
        return
    end

    -- Every Create/Get/Delete/rule call below lives in Readycheck_Features,
    -- but this panel is drawn by the base addon and its sidebar entry has no
    -- lodAddon, so with Features unticked the page used to render normally
    -- and then error on the first button press. db.smartMacros is seeded by
    -- the base profile builder, so the check above never catches this.
    -- Bailing out here covers all of them at once: nothing further down is
    -- reachable without going through this render.
    if not RC.CreateSmartMacro then
        -- Features runs its smart-macro init on a 1s timer, so opening this
        -- page immediately after login lands here with the addon perfectly
        -- healthy. Only say "enable it" when it genuinely is not loaded.
        local loading = RC.CompanionStatus
            and RC:CompanionStatus("Readycheck_Features") == "loading"
        local lbl = MakeFS(parent, 12, loading
            and RCL["Smart Macros are still starting up. Reopen this page in a moment."]
            or  RCL["Smart Macros need the Readycheck_Features addon. Enable it in your AddOns list and /reload."])
        lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -40)
        do
            local _c = loading and RC:GetColor("text", "warning") or RC:GetColor("text", "red")
            lbl:SetTextColor(_c.r, _c.g, _c.b, 1)
        end
        return
    end

    if SM_Editor.selectedId then
        local mac = RC:GetSmartMacroById(SM_Editor.selectedId)
        if mac and IsSlotEntry(mac) and not RC.smartKeys then
            SM_Editor.selectedId = nil
            SM_RenderList(frame)
        elseif mac and IsSlotEntry(mac) then
            SM_RenderSlotEdit(frame, mac)
        elseif mac then
            SM_RenderEdit(frame, mac)
        else
            SM_Editor.selectedId = nil
            SM_RenderList(frame)
        end
    else
        SM_RenderList(frame)
    end

    -- deferred a frame so UpdateSidebarScrollbar (run during the render
    -- above) has already resized the scrollbar before clamping to it.
    if savedScroll > 0 then
        C_Timer.After(0, function()
            if not frame.contentFrame then return end
            local cf = frame.contentFrame
            local sb = cf.scrollBar
            local maxScroll = 0
            if sb then
                local _, mv = sb:GetMinMaxValues()
                maxScroll = mv or 0
            end
            local target = math.min(savedScroll, maxScroll)
            cf:SetVerticalScroll(target)
            if sb then sb:SetValue(target) end
        end)
    end
end

function SM_RenderList(frame)
    local parent = frame.scrollChild
    local yPos   = -20
    local TEXT   = RC.UI and RC.UI.TEXT or {}

    local _, newY = RC:CreateSettingsPageHeader(
        parent, yPos,
        RCL["Smart Macros"],
        RCL["Rewrites a macro body automatically based on what you are targeting"],
        "Interface\\Icons\\INV_Scroll_03"
    )
    yPos = newY - 10


    local addBtn = Btn(parent, "+ Add Smart Macro", 165, 26)
    addBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
    addBtn:SetScript("OnClick", function()
        local mac = RC:CreateSmartMacro()
        SM_Editor.selectedId = mac.id
        RC:ShowSidebarSmartMacro(frame)
    end)
    -- a slot of the action bars instead of a macro (0: none picked yet)
    local keysOn = RC.smartKeys
    if keysOn then
        local addSlotBtn = Btn(parent, "+ Add Bar Slot", 140, 26)
        addSlotBtn:SetPoint("LEFT", addBtn, "RIGHT", 8, 0)
        addSlotBtn:SetScript("OnClick", function()
            local mac = RC:CreateSmartMacro()
            mac.slot = 0
            RC:SaveConfigurationToProfile()
            SM_Editor.selectedId = mac.id
            RC:ShowSidebarSmartMacro(frame)
        end)
    end
    yPos = yPos - 38

    -- (with the switch off a bar slot entry is not listed: it does nothing)
    local macros = {}
    for _, mac in ipairs(RC.db.smartMacros) do
        if keysOn or not IsSlotEntry(mac) then macros[#macros + 1] = mac end
    end
    if #macros == 0 then
        local none = MakeFS(parent, 11,
            RCL["No smart macros configured yet. Click '+ Add Smart Macro' above."])
        none:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
        do local _c = RC:GetColor("text", "disabled"); none:SetTextColor(_c.r, _c.g, _c.b, 1) end
        yPos = yPos - 24
    else
        for _, mac in ipairs(macros) do
            local isSlot = IsSlotEntry(mac)
            local ruleCount = #mac.rules
            local isUnnamed = (not isSlot and mac.macroName == "") or (isSlot and not SlotNumber(mac.slot))
            local card = RC:CreateSettingsCard(parent, yPos,
                isSlot and (SlotNumber(mac.slot) and (RCL["Bar slot "] .. mac.slot) or RCL["Bar slot (none picked)"])
                or (isUnnamed and RCL["(unnamed)"] or mac.macroName))
            local dimC = RC:GetColor("text", "disabled")
            if isUnnamed and card.title then
                card.title:SetTextColor(dimC.r, dimC.g, dimC.b, 1)
            end
            -- Rule count as its own dim label after the title, in place of
            -- an inline colour code inside the title string. (A bar slot:
            -- what it holds.)
            local countText = "- " .. ruleCount .. RCL[" rule"] .. (ruleCount ~= 1 and "s" or "")
            if isSlot then
                local holds = SlotNumber(mac.slot) and RC:ActionSlotHolds(mac.slot) or nil
                countText = SlotNumber(mac.slot) and ("- " .. (holds or RCL["empty"])) or ""
            end
            local countFS = MakeFS(card, 10, countText)
            if card.title then
                countFS:SetPoint("LEFT", card.title, "RIGHT", 6, 0)
            else
                countFS:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -9)
            end
            countFS:SetTextColor(dimC.r, dimC.g, dimC.b, 1)
            -- its group, if it has one (what a raid page can swap together)
            if keysOn and TrimStr(mac.group) ~= "" then
                local grpFS = MakeFS(card, 10, RCL["group: "] .. TrimStr(mac.group))
                grpFS:SetPoint("LEFT", countFS, "RIGHT", 10, 0)
                local gc = RC:GetColor("ui", "accentGold")
                if gc then grpFS:SetTextColor(gc.r, gc.g, gc.b, 0.9) end
            end

            local cardY = -34
            -- linked to a boss ability: only live on bosses with it on
            if keysOn and TrimStr(mac.ability) ~= "" then
                local linkFS = MakeFS(card, 10, RCL["Only on bosses with: "] .. AbilityName(mac.ability)
                    .. (mac.auto and RCL["  (found automatically)"] or ""))
                linkFS:SetPoint("TOPLEFT", card, "TOPLEFT", 90, cardY)
                local gc = RC:GetColor("ui", "accentGold")
                if gc then linkFS:SetTextColor(gc.r, gc.g, gc.b, 0.9) end
            end
            local statC = mac.enabled
                and RC:GetColor("text", "success") or RC:GetColor("text", "disabled")
            local statFS = MakeFS(card, 10, mac.enabled and "Enabled" or "Disabled")
            statFS:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
            if statC then statFS:SetTextColor(statC.r, statC.g, statC.b, 1) end
            cardY = cardY - 20

            local shown = 0
            for i, rule in ipairs(mac.rules) do
                if shown >= 3 then
                    local more = MakeFS(card, 10,
                        "... and " .. (#mac.rules - 3) .. RCL[" more"])
                    more:SetPoint("TOPLEFT", card, "TOPLEFT", 14, cardY)
                    more:SetTextColor(dimC.r, dimC.g, dimC.b, 1)
                    cardY = cardY - 16
                    break
                end
                local firstCond = (rule.conditions and rule.conditions[1]) or {}
                -- rule.condition (singular) is a fallback for rules saved before
                -- the multi-condition list existed.
                local firstType = firstCond.type or rule.condition or "?"
                local condTxt = CondLabel(firstType)
                if rule.conditions and #rule.conditions > 1 then
                    condTxt = condTxt .. " +" .. (#rule.conditions - 1)
                end
                local valSuffix = (firstType == "named" and firstCond.value and firstCond.value ~= "")
                    and (' "' .. firstCond.value .. '"') or ""
                local itemSuffix = (rule.itemCheck and rule.itemCheck ~= "")
                    and " [if " .. rule.itemCheck .. " avail.]" or ""
                -- BuildBody computes the body from buildAction/buildItem/buildConditional
                -- in Auto Build mode; falls back to the stored manual body if the
                -- SmartMacro module hasn't loaded yet.
                local effectiveBody = (RC.SmartMacro and RC.SmartMacro.BuildBody(rule)) or rule.body or ""
                local bodyShort
                if effectiveBody == "" then
                    bodyShort = "(clears macro)"
                else
                    -- the whole body on the one line, its lines side by side;
                    -- the line itself is cut where the card ends (seen in
                    -- game, 2026-11-24: 30 characters and "..." with half
                    -- the card empty beside it; a cut by bytes can also
                    -- land inside a letter on a non-English client)
                    bodyShort = effectiveBody:gsub("%s*[\r\n]+%s*", "   ")
                end
                local rowFS = MakeFS(card, 10,
                    i .. ". " .. condTxt .. valSuffix .. itemSuffix
                    .. "  ->  " .. bodyShort)
                rowFS:SetPoint("TOPLEFT",  card, "TOPLEFT",  14, cardY)
                rowFS:SetPoint("TOPRIGHT", card, "TOPRIGHT", -90, cardY)
                rowFS:SetWordWrap(false)
                if TEXT.light then
                    rowFS:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                end
                cardY = cardY - 16
                shown = shown + 1
            end

            local capId = mac.id
            local editBtn = Btn(card, "Edit", 60, 22)
            editBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -40, -8)
            editBtn:SetScript("OnClick", function()
                SM_Editor.selectedId = capId
                RC:ShowSidebarSmartMacro(frame)
            end)

            local delBtn = RC.UI:CreateXCloseButton(card, 22, function()
                RC.UI:CreateConfirmDialog(
                    RCL["Delete Smart Macro"],
                    RCL["Delete '"] .. EntryLabel(mac) .. RCL["'?\n\nThis cannot be undone."],
                    function()
                        RC:DeleteSmartMacro(capId)
                        if SM_Editor.selectedId == capId then SM_Editor.selectedId = nil end
                        RC:ShowSidebarSmartMacro(frame)
                    end,
                    nil, RCL["Delete"], true
                )
            end)
            delBtn:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -8)

            local cardH = math.abs(cardY) + 14
            card:SetHeight(cardH)
            yPos = yPos - cardH - 10
        end
    end

    -- Your macros first; the how-to below them, for when you need it.
    yPos = yPos - 6
    local infoCard = RC:CreateSettingsCard(parent, yPos, RCL["How it works"])
    local cy = -34

    local function CardText(text, size)
        local fs = MakeFS(infoCard, size or 11, text)
        fs:SetPoint("TOPLEFT",  infoCard, "TOPLEFT",  14, cy)
        fs:SetPoint("TOPRIGHT", infoCard, "TOPRIGHT", -14, cy)
        fs:SetJustifyH("LEFT"); fs:SetWordWrap(true)
        if TEXT.light then fs:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
        cy = cy - math.max(fs:GetStringHeight(), 14) - 6
    end

    CardText("1. Create an empty macro in WoW's Macro UI and give it any name (e.g. SmartBomb).")
    CardText("2. Add a Smart Macro here using that exact name, then add Rules.")
    CardText("3. Rules are checked top-to-bottom on every target change. The first rule whose " ..
        "condition matches AND whose required item (if set) is in your bags and off cooldown is applied.")
    CardText("4. If no rule fires, the macro keeps its last-written body (sticky). A rule " ..
        "with an empty body clears (blanks) the macro when it fires.")
    CardText("5. IN COMBAT THE MACRO CANNOT CHANGE. Blizzard blocks macro edits during " ..
        "combat, so a swap you trigger mid-fight is queued and applied the moment you drop " ..
        "combat. Target your next mob before the pull to get the right body.")
    CardText("6. Use 'Active in' to scope a macro to one raid (and optionally one raid " ..
        "profile). To make the SAME in-game macro do different things per raid config, add " ..
        "several Smart Macros with the same name, each scoped to a different raid/profile.")
    if keysOn then
    CardText("7. ONE ITEM FOR A BOSS OR A ROUTE STEP. A boss's page in Raid Config (the Macros " ..
        "tile) and a route step (Add action) can hand a macro one item: while that boss is " ..
        "your target, or the route is on that step, the macro uses it whatever its rules say. " ..
        "Give macros the same Group and one line swaps them all - every potion key becomes the " ..
        "same potion. When the boss or step is over the rules decide again, and a macro with " ..
        "no matching rule gets back the text it had.")
    CardText("8. ONLY ON BOSSES WHERE IT IS SWITCHED ON. Under an ability on a boss's page (Death Wish, " ..
        "Recklessness, Potion...) link the buttons that use it - click them in the preview of your bars, or tick " ..
        "Automatic and they are found for you. A linked button gets a small macro in place of its spell or item " ..
        "(same key, same icon); nothing is taken off your bars. On a boss that is set up but has the ability off, " ..
        "that macro does nothing; on a boss with nothing set up, and everywhere else, the key is as you made it. " ..
        "A key linked to Potion or Utility uses the boss's item where the boss has exactly one set up.")
    CardText("9. BAR SLOTS. '+ Add Bar Slot' adds one slot of your action bars instead of a macro, for a group: " ..
        "a boss's page or a route step can hand the slot - or its whole group - one item. Pick it by clicking " ..
        "its button, in the preview of your bars or on the bars themselves. It works with any bar addon; what " ..
        "the slot held is put back afterwards, and a slot is never emptied.")
    CardText("10. WAIT. A key linked to a boss ability cannot be locked until the ability's reminder " ..
        "goes off - the game lets no addon change a macro or a bar slot in a fight. Its button on " ..
        "your bars is dimmed and reads WAIT on the boss instead, until the reminder has gone off.")
    end

    local goldC = RC:GetColor("ui", "accentGold")
    local noteFS = MakeFS(infoCard, 10,
        "Tip: Use 'Required item' to handle shared cooldowns. Example: Name 'Crypt Stalker' + " ..
        "Req. item 'Goblin Sapper Charge' fires only when the sapper is available. " ..
        "When the sapper is on CD the rule is skipped and the next rule (Undead -> Holy Water) fires instead.")
    noteFS:SetPoint("TOPLEFT",  infoCard, "TOPLEFT",  14, cy)
    noteFS:SetPoint("TOPRIGHT", infoCard, "TOPRIGHT", -14, cy)
    noteFS:SetJustifyH("LEFT"); noteFS:SetWordWrap(true)
    if goldC then noteFS:SetTextColor(goldC.r, goldC.g, goldC.b, 0.9) end
    cy = cy - math.max(noteFS:GetStringHeight(), 14) - 8

    infoCard:SetContentHeight(math.abs(cy) + 4)
    yPos = yPos - infoCard:GetHeight() - 14

    yPos = yPos - 20
    RC:UpdateSidebarScrollbar(RC.sidebarConfigFrame, math.abs(yPos) + 40)
end

------------------------------------------------------------------------
-- The fields a macro and a bar slot share on their edit pages. Each takes
-- the setup card and the y to start at, and returns the y below it.
------------------------------------------------------------------------
-- GROUP (2026-11-16): entries that share one can be handed the same item
-- together from a boss's page or a route step. LINK: the boss ability
-- the entry follows (only live on bosses where it is switched on).
local function SetupGroupAndLink(setupCard, scY, mac, groupOnly)
    local TEXT  = RC.UI and RC.UI.TEXT or {}
    local grayC = RC:GetColor("text", "disabled")
    do
        local grpLbl = MakeFS(setupCard, 11, "Group:")
        grpLbl:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
        grpLbl:SetWidth(LBL_W)
        if TEXT.light then grpLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
        local grpEB = RC.UI:CreateStyledEditBox(setupCard, { height = 24, width = 200, maxLetters = 40 })
        grpEB:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14 + LBL_W + 6, scY)
        grpEB.editBox:SetText(mac.group or "")
        local function SaveGroup(self)
            local g = TrimStr(self:GetText())
            local was = mac.group
            mac.group = (g ~= "" and g) or nil
            if mac.group ~= was then
                RC:SaveConfigurationToProfile()
                if RC.SmartMacro then RC.SmartMacro:RequestEvaluate() end
            end
        end
        grpEB.editBox:SetScript("OnEnterPressed", function(self) SaveGroup(self) self:ClearFocus() end)
        grpEB.editBox:SetScript("OnEditFocusLost", function(self) SaveGroup(self) end)
        scY = scY - ROW_H

        local inUse, seenG = {}, {}
        for _, other in ipairs(RC.db.smartMacros or {}) do
            local g = TrimStr(other.group)
            if g ~= "" and not seenG[g:lower()] then
                seenG[g:lower()] = true
                inUse[#inUse + 1] = g
            end
        end
        table.sort(inUse, function(a, b) return a:lower() < b:lower() end)
        local grpHint = MakeFS(setupCard, 10,
            "Optional. Macros and bar slots with the same group can be given one item together from a boss's page or a route step - "
            .. "put every potion key in \"Potions\" and a boss can make them all the same potion."
            .. (#inUse > 0 and ("  Groups in use: " .. table.concat(inUse, ", ") .. ".") or ""))
        grpHint:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14 + LBL_W + 6, scY + 4)
        grpHint:SetJustifyH("LEFT")
        grpHint:SetWordWrap(true)
        if grayC then grpHint:SetTextColor(grayC.r, grayC.g, grayC.b, 0.8) end
        local cw = setupCard:GetWidth() or 0
        grpHint:SetWidth(cw > 300 and (cw - (14 + LBL_W + 6) - 14) or 300)
        scY = scY - math.max(20, (grpHint:GetStringHeight() or 14) + 8)
    end
    -- (a bar slot is linked through a macro on it: a boss's page does that)
    if groupOnly then return scY end

    local linkLbl = MakeFS(setupCard, 11, "Only on bosses with:")
    linkLbl:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
    linkLbl:SetWidth(130)
    if TEXT.light then linkLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
    local items = { { text = RCL["Every boss (not linked)"], value = "" } }
    for _, a in ipairs(RC:SmartMacroLinkAbilities()) do
        items[#items + 1] = { text = a.name, value = a.key, icon = a.icon }
    end
    MakeDrop(setupCard, 150, scY, 220, items, mac.ability or "", function(val)
        mac.ability = (val ~= "" and val) or nil
        RC:SaveConfigurationToProfile()
        if RC.SmartMacro then RC.SmartMacro:RequestEvaluate() end
    end)
    scY = scY - ROW_H
    local linkHint = MakeFS(setupCard, 10,
        "Optional. Linked, it is only live on bosses where that ability is switched on in Raid Config: on a boss "
        .. "that is set up but has it off, the macro does nothing from the moment you target the boss until you target "
        .. "another enemy. A boss with nothing set up leaves it alone. Linked to Potion or Utility, it uses the boss's "
        .. "item where the boss has exactly one.")
    linkHint:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 150, scY + 4)
    linkHint:SetJustifyH("LEFT")
    linkHint:SetWordWrap(true)
    if grayC then linkHint:SetTextColor(grayC.r, grayC.g, grayC.b, 0.8) end
    local lw = setupCard:GetWidth() or 0
    linkHint:SetWidth(lw > 300 and (lw - 150 - 14) or 300)
    scY = scY - math.max(20, (linkHint:GetStringHeight() or 14) + 8)
    return scY
end

-- ENABLED, and the raid / raid profile the entry is active in
local function SetupEnabledAndScope(frame, setupCard, scY, mac)
    local TEXT = RC.UI and RC.UI.TEXT or {}
    local enableChk = RC.UI:CreateCheckbox(setupCard, RCL["Enabled"], mac.enabled)
    enableChk:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
    enableChk:SetScript("OnClick", function(cb)
        mac.enabled = cb:GetChecked()
        RC:ForceCheckboxUpdate(cb, mac.enabled)
        RC:SaveConfigurationToProfile()
        if RC.SmartMacro then RC.SmartMacro:RequestEvaluate() end
    end)
    scY = scY - ROW_H

    local raidLbl = MakeFS(setupCard, 10, "Active in:")
    raidLbl:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
    raidLbl:SetWidth(70)
    if TEXT.light then raidLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
    local capMacRaid = mac
    MakeDrop(setupCard, 88, scY, 200, GetRuleRaidScopeItems(), mac.raidFilter or "any",
        function(val)
            capMacRaid.raidFilter = val
            if val == "any" then capMacRaid.profileFilter = "any" end
            RC:SaveConfigurationToProfile()
            -- deferred: rebuilding the page synchronously from inside the
            -- dropdown's own onChange callback would tear down the dropdown
            -- widget while it's still closing itself.
            C_Timer.After(0, function() RC:ShowSidebarSmartMacro(frame, true) end)
        end)
    scY = scY - ROW_H

    local macRaid = mac.raidFilter or "any"
    if macRaid ~= "any" and macRaid ~= "" then
        local profLbl = MakeFS(setupCard, 10, "Profile:")
        profLbl:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
        profLbl:SetWidth(70)
        if TEXT.light then profLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
        MakeDrop(setupCard, 88, scY, 200, GetRuleProfileItems(macRaid), mac.profileFilter or "any",
            function(val)
                capMacRaid.profileFilter = val
                RC:SaveConfigurationToProfile()
            end)
        scY = scY - ROW_H
    end
    return scY
end

function SM_RenderEdit(frame, mac)
    local parent = frame.scrollChild
    local yPos   = -20
    local TEXT   = RC.UI and RC.UI.TEXT or {}
    local grayC  = RC:GetColor("text", "disabled")
    local goldC  = RC:GetColor("ui", "accentGold")

    local backBtn = RC.UI:CreateBackButton(parent, "< All Smart Macros", 165, 24)
    backBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
    backBtn:SetScript("OnClick", function()
        SM_Editor.selectedId = nil
        RC:ShowSidebarSmartMacro(frame)
    end)
    yPos = yPos - 34

    local _, newY = RC:CreateSettingsPageHeader(
        parent, yPos,
        RCL["Smart Macro"],
        RCL["Configure conditions and macro body"],
        "Interface\\Icons\\INV_Scroll_03"
    )
    yPos = newY - 10

    local setupCard = RC:CreateSettingsCard(parent, yPos, RCL["Macro setup"])
    local scY = -34

    local nameLbl = MakeFS(setupCard, 11, "Macro Name:")
    nameLbl:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
    nameLbl:SetWidth(LBL_W)
    if TEXT.light then nameLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end

    local nameEB = RC.UI:CreateStyledEditBox(setupCard, { height = 24, width = 200 })
    nameEB:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14 + LBL_W + 6, scY)
    nameEB.editBox:SetText(mac.macroName or "")
    nameEB.editBox:SetScript("OnEnterPressed", function(self)
        mac.macroName = self:GetText():match("^%s*(.-)%s*$") or ""
        self:ClearFocus()
        RC:SaveConfigurationToProfile()
    end)
    nameEB.editBox:SetScript("OnEditFocusLost", function(self)
        mac.macroName = self:GetText():match("^%s*(.-)%s*$") or ""
        RC:SaveConfigurationToProfile()
    end)
    -- or picked from the game's macros
    if RC.smartKeys then
        local dd = RC.UI:CreateScrollableDropdown(setupCard, 230, RCL["Pick one of your macros..."], 12)
        dd:SetPoint("LEFT", nameEB, "RIGHT", 8, 0)
        if dd.menu then
            dd.menu:SetFrameStrata("TOOLTIP")
            dd.menu:SetFrameLevel(200)
        end
        dd:SetItems(RC:SmartKeyMacroChoices(), function(name)
            if type(name) ~= "string" or name == "" then return end
            mac.macroName = name
            RC:SaveConfigurationToProfile()
            if RC.SmartMacro then RC.SmartMacro:RequestEvaluate() end
            C_Timer.After(0, function() RC:ShowSidebarSmartMacro(frame, true) end)
        end)
    end
    scY = scY - ROW_H

    local nameHint = MakeFS(setupCard, 10,
        "Must match the in-game macro name exactly.")
    nameHint:SetPoint("TOPLEFT",  setupCard, "TOPLEFT",  14 + LBL_W + 6, scY + 4)
    nameHint:SetPoint("TOPRIGHT", setupCard, "TOPRIGHT", -14, scY + 4)
    nameHint:SetWordWrap(true)
    if grayC then nameHint:SetTextColor(grayC.r, grayC.g, grayC.b, 0.8) end
    scY = scY - 20

    if RC.smartKeys then scY = SetupGroupAndLink(setupCard, scY, mac) end
    scY = SetupEnabledAndScope(frame, setupCard, scY, mac)

    -- Same key, second macro: this macro's key also runs the one picked
    -- here, through a hidden secure button (SmartMacro.lua, SyncChains).
    do
        local alsoLbl = MakeFS(setupCard, 10, "Same key also runs:")
        alsoLbl:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
        alsoLbl:SetWidth(120)
        if TEXT.light then alsoLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
        local items = { { text = RCL["Nothing"], value = "" } }
        local seen = {}
        local nAcct, nChar = 0, 0
        if GetNumMacros then nAcct, nChar = GetNumMacros() end
        local maxAcct = MAX_ACCOUNT_MACROS or 120
        -- a smart macro that already runs a second macro would be refused
        -- (no loops), so it is not offered - unless it is the current pick
        local runsOwn = {}
        for _, other in ipairs(RC.db.smartMacros or {}) do
            if other ~= mac and other.macroName and other.alsoRun and other.alsoRun ~= "" then
                runsOwn[other.macroName] = true
            end
        end
        local function addIdx(i)
            local nm = GetMacroInfo(i)
            if nm and nm ~= "" and nm ~= mac.macroName and not seen[nm]
               and (not runsOwn[nm] or nm == mac.alsoRun) then
                seen[nm] = true
                items[#items + 1] = { text = nm, value = nm }
            end
        end
        for i = 1, nAcct or 0 do addIdx(i) end
        for i = maxAcct + 1, maxAcct + (nChar or 0) do addIdx(i) end
        table.sort(items, function(a, b)
            if a.value == "" then return true end
            if b.value == "" then return false end
            return a.text:lower() < b.text:lower()
        end)
        MakeDrop(setupCard, 140, scY, 180, items, mac.alsoRun or "",
            function(val)
                mac.alsoRun = (val ~= "" and val) or nil
                RC:SaveConfigurationToProfile()
                local SMx = RC.SmartMacro
                if SMx then
                    if SMx.SyncChains then SMx:SyncChains() end
                    if SMx._lastApplied then SMx._lastApplied[mac.macroName or ""] = nil end
                    if SMx.Evaluate then SMx:Evaluate() end
                end
                C_Timer.After(0, function() RC:ShowSidebarSmartMacro(frame, true) end)
            end)
        scY = scY - ROW_H

        local SMx = RC.SmartMacro
        local why
        if SMx and SMx.ChainTarget then _, why = SMx.ChainTarget(mac) end
        local note
        if not mac.alsoRun or mac.alsoRun == "" then
            note = "Pick a macro here and one press of this macro's key runs both, this one first."
        elseif why == "loop" then
            note = "That macro already runs a second macro of its own, so this one is not added (two macros cannot run each other)."
        elseif SMx and SMx._tooLong and SMx._tooLong[mac.id or mac] then
            note = "Not added: the rule's text plus the /click line would pass the 255-character macro limit. Shorten the rule."
        else
            note = "One press runs this macro and then that one. The second runs through a hidden button nothing can click by accident, so it needs no bar slot - keep only this macro on your bar."
        end
        local alsoHint = MakeFS(setupCard, 10, note)
        alsoHint:SetPoint("TOPLEFT",  setupCard, "TOPLEFT",  140, scY + 4)
        alsoHint:SetWordWrap(true)
        alsoHint:SetJustifyH("LEFT")
        if grayC then alsoHint:SetTextColor(grayC.r, grayC.g, grayC.b, 0.8) end
        -- a fixed width (not a right anchor), so the height is measured
        -- right even before the card's own width is laid out
        local cw = setupCard:GetWidth() or 0
        alsoHint:SetWidth(cw > 300 and (cw - 154) or 300)
        scY = scY - math.max(20, (alsoHint:GetStringHeight() or 14) + 6)
    end

    setupCard:SetContentHeight(math.abs(scY) + 6)
    yPos = yPos - setupCard:GetHeight() - 12

    local rulesCard = RC:CreateSettingsCard(parent, yPos, RCL["Rules"])
    local rcY = -34

    local hintFS = MakeFS(rulesCard, 10,
        "Rules are checked top-to-bottom. The first rule where ANY condition matches fires. " ..
        "If nothing matches, the macro keeps its current body. Swaps triggered while you are " ..
        "in combat are queued and applied when you leave combat - Blizzard blocks macro edits " ..
        "mid-fight.")
    hintFS:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14, rcY)
    hintFS:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -14, rcY)
    hintFS:SetJustifyH("LEFT"); hintFS:SetWordWrap(true)
    if grayC then hintFS:SetTextColor(grayC.r, grayC.g, grayC.b, 0.85) end
    rcY = rcY - math.max(hintFS:GetStringHeight(), 24) - 10

    local rules = mac.rules

    if #rules == 0 then
        local noneFS = MakeFS(rulesCard, 10,
            RCL["No rules yet. Click 'Add Rule' below."])
        noneFS:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14, rcY)
        if grayC then noneFS:SetTextColor(grayC.r, grayC.g, grayC.b, 1) end
        rcY = rcY - 20
    else
        for idx, rule in ipairs(rules) do
            if idx > 1 then
                local div = rulesCard:CreateTexture(nil, "ARTWORK")
                div:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14, rcY + 4)
                div:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -14, rcY + 4)
                RC.Line(div, "H", 1)
                do local _bn = RC:GetColor("ui", "borderNormal"); div:SetColorTexture(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
                rcY = rcY - 10
            end

            local capRule   = rule
            local capMac    = mac
            local capRuleId = rule.id

            local rNumFS = MakeFS(rulesCard, 10, "Rule " .. idx .. ":")
            rNumFS:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14, rcY)
            if goldC then rNumFS:SetTextColor(goldC.r, goldC.g, goldC.b, 1) end

            local delBtn = RC.UI:CreateXCloseButton(rulesCard, 20, function()
                RC:DeleteSmartMacroRule(capMac, capRuleId)
                RC:ShowSidebarSmartMacro(frame, true)
            end)
            delBtn:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -8, rcY)

            local dnBtn = Btn(rulesCard, "Dn", 34, 20)
            dnBtn:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -32, rcY)
            dnBtn:SetScript("OnClick", function()
                RC:MoveSmartMacroRule(capMac, capRuleId, 1)
                RC:ShowSidebarSmartMacro(frame, true)
            end)

            local upBtn = Btn(rulesCard, "Up", 34, 20)
            upBtn:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -70, rcY)
            upBtn:SetScript("OnClick", function()
                RC:MoveSmartMacroRule(capMac, capRuleId, -1)
                RC:ShowSidebarSmartMacro(frame, true)
            end)

            rcY = rcY - 26

            local conditions = capRule.conditions or {}
            for ci, cond in ipairs(conditions) do
                local capCi   = ci
                local capCond = cond
                local condType = cond.type or "always"

                MakeDrop(rulesCard, 14, rcY, COND_W, COND_ITEMS, condType,
                    function(val)
                        capCond.type = val
                        if not CondNeedsValue(val) then capCond.value = "" end
                        RC:SaveConfigurationToProfile()
                        -- same deferral reason as the raid-scope dropdown above.
                        C_Timer.After(0, function()
                            RC:ShowSidebarSmartMacro(frame, true)
                        end)
                    end
                )

                if CondNeedsValue(condType) then
                    local valLbl = MakeFS(rulesCard, 10, "Contains:")
                    valLbl:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14 + COND_W + 6, rcY)
                    valLbl:SetWidth(56)
                    if TEXT.light then
                        valLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                    end
                    local valEB = RC.UI:CreateStyledEditBox(rulesCard, {
                        height = 22, maxLetters = 60,
                    })
                    valEB:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14 + COND_W + 66, rcY)
                    valEB:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -30, rcY)
                    valEB.editBox:SetText(cond.value or "")
                    valEB.editBox:SetScript("OnEnterPressed", function(self)
                        capCond.value = self:GetText()
                        self:ClearFocus()
                        RC:SaveConfigurationToProfile()
                    end)
                    valEB.editBox:SetScript("OnEditFocusLost", function(self)
                        capCond.value = self:GetText()
                        RC:SaveConfigurationToProfile()
                    end)
                end

                if CondNeedsPicker(condType) then
                    local bossItems = GetBossPickerItems()
                    local capCondPicker = capCond
                    local pickerCurrentVal = capCondPicker.value or ""
                    local pickerLabel = pickerCurrentVal ~= "" and pickerCurrentVal or "Pick a boss..."
                    local pickerDrop = RC.UI:CreateScrollableDropdown(
                        rulesCard, COND_W - 2, pickerLabel, 11)
                    pickerDrop:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14 + COND_W + 4, rcY)
                    if pickerDrop.menu then
                        pickerDrop.menu:SetFrameStrata("TOOLTIP")
                        pickerDrop.menu:SetFrameLevel(200)
                    end
                    local customLbl = MakeFS(rulesCard, 10, "or type:")
                    customLbl:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14 + COND_W + 4, rcY - 30)
                    customLbl:SetWidth(52)
                    if TEXT.light then
                        customLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                    end
                    local customEB = RC.UI:CreateStyledEditBox(rulesCard, {
                        height = 22, maxLetters = 80,
                    })
                    customEB:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14 + COND_W + 60, rcY - 30)
                    customEB:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -30, rcY - 30)
                    customEB.editBox:SetText(pickerCurrentVal)
                    local function SavePickerValue(name)
                        name = (name or ""):match("^%s*(.-)%s*$")
                        capCondPicker.value = name
                        RC:SaveConfigurationToProfile()
                    end
                    customEB.editBox:SetScript("OnEnterPressed", function(self)
                        SavePickerValue(self:GetText())
                        self:ClearFocus()
                    end)
                    customEB.editBox:SetScript("OnEditFocusLost", function(self)
                        SavePickerValue(self:GetText())
                    end)
                    local filteredItems = {}
                    for _, it in ipairs(bossItems) do
                        if it.value ~= "__header__" then
                            filteredItems[#filteredItems + 1] = it
                        end
                    end
                    pickerDrop:SetItems(filteredItems, function(val)
                        if val and val ~= "" then
                            customEB.editBox:SetText(val)
                            SavePickerValue(val)
                            pickerDrop:SetSelectedValue(val, val)
                        end
                    end)
                    if pickerCurrentVal ~= "" then
                        pickerDrop:SetSelectedValue(pickerCurrentVal, pickerCurrentVal)
                    end
                    rcY = rcY - 30
                end

                if #conditions > 1 then
                    local delCondBtn = RC.UI:CreateXCloseButton(rulesCard, 18, function()
                        table.remove(capRule.conditions, capCi)
                        RC:SaveConfigurationToProfile()
                        RC:ShowSidebarSmartMacro(frame, true)
                    end)
                    delCondBtn:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -8, rcY)
                end

                rcY = rcY - 30
            end

            if #conditions < 5 then
                local addCondBtn = Btn(rulesCard, "+ Condition", 100, 22)
                addCondBtn:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14, rcY)
                addCondBtn:SetScript("OnClick", function()
                    if not capRule.conditions then capRule.conditions = {} end
                    table.insert(capRule.conditions, { type = "always" })
                    RC:SaveConfigurationToProfile()
                    RC:ShowSidebarSmartMacro(frame, true)
                end)
                rcY = rcY - 28
            else
                rcY = rcY - 4
            end

            local isAuto = (rule.buildMode ~= "manual")

            local previewFS
            local manBodyEB
            local function RefreshPreview()
                if not previewFS then return end
                local p = (RC.SmartMacro and RC.SmartMacro.BuildBody(capRule)) or ""
                if p ~= "" then
                    previewFS:SetText(p)
                    if goldC then previewFS:SetTextColor(goldC.r, goldC.g, goldC.b, 1) end
                else
                    previewFS:SetText(RCL["(fill in Name above)"])
                    if grayC then previewFS:SetTextColor(grayC.r, grayC.g, grayC.b, 1) end
                end
            end

            local modeChk = RC.UI:CreateCheckbox(rulesCard, RCL["Build macro body automatically"], isAuto)
            modeChk:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14, rcY)

            local bodySectionY = rcY - 26

            local autoSec = CreateFrame("Frame", nil, rulesCard)
            autoSec:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14,  bodySectionY)
            autoSec:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -74, bodySectionY)
            autoSec:SetHeight(112)
            if not isAuto then autoSec:Hide() end

            local actLbl = MakeFS(autoSec, 10, "Action:")
            actLbl:SetPoint("TOPLEFT", autoSec, "TOPLEFT", 0, 0)
            actLbl:SetWidth(LBL_W - 4)
            if TEXT.light then
                actLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            end

            MakeDrop(autoSec, LBL_W, 0, 140, ACTION_ITEMS,
                capRule.buildAction or "use",
                function(val)
                    capRule.buildAction = val
                    RC:SaveConfigurationToProfile()
                    RefreshPreview()
                end
            )

            local nameLbl2 = MakeFS(autoSec, 10, "Name:")
            nameLbl2:SetPoint("TOPLEFT", autoSec, "TOPLEFT", LBL_W + 146, 0)
            nameLbl2:SetWidth(42)
            if TEXT.light then
                nameLbl2:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            end

            local itemNameEB = RC.UI:CreateStyledEditBox(autoSec, {
                height = 24, maxLetters = 100
            })
            itemNameEB:SetPoint("TOPLEFT",  autoSec, "TOPLEFT",  LBL_W + 192, 0)
            itemNameEB:SetPoint("TOPRIGHT", autoSec, "TOPRIGHT", 0, 0)
            itemNameEB.editBox:SetText(capRule.buildItem or "")
            -- lets a shift-clicked chat item link auto-fill this box (see
            -- ChatEdit_InsertLink hook in Readycheck_Features/SmartMacro.lua).
            itemNameEB.editBox:SetScript("OnEditFocusGained", function(self)
                if RC.SmartMacro then RC.SmartMacro._lastFocusedEB = self end
            end)
            itemNameEB.editBox:SetScript("OnEnterPressed", function(self)
                capRule.buildItem = self:GetText():match("^%s*(.-)%s*$") or ""
                self:ClearFocus()
                RC:SaveConfigurationToProfile()
                RefreshPreview()
            end)
            itemNameEB.editBox:SetScript("OnEditFocusLost", function(self)
                capRule.buildItem = self:GetText():match("^%s*(.-)%s*$") or ""
                RC:SaveConfigurationToProfile()
                RefreshPreview()
            end)

            local condLbl2 = MakeFS(autoSec, 10, "Conditional:")
            condLbl2:SetPoint("TOPLEFT", autoSec, "TOPLEFT", 0, -30)
            condLbl2:SetWidth(LBL_W - 4)
            if TEXT.light then
                condLbl2:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            end

            local condEB = RC.UI:CreateStyledEditBox(autoSec, { height = 24, maxLetters = 80 })
            condEB:SetPoint("TOPLEFT",  autoSec, "TOPLEFT",  LBL_W, -30)
            condEB:SetPoint("TOPRIGHT", autoSec, "TOPRIGHT", 0, -30)
            condEB.editBox:SetText(capRule.buildConditional or "")
            condEB.editBox:SetScript("OnEnterPressed", function(self)
                capRule.buildConditional = self:GetText():match("^%s*(.-)%s*$") or ""
                self:ClearFocus()
                RC:SaveConfigurationToProfile()
                RefreshPreview()
            end)
            condEB.editBox:SetScript("OnEditFocusLost", function(self)
                capRule.buildConditional = self:GetText():match("^%s*(.-)%s*$") or ""
                RC:SaveConfigurationToProfile()
                RefreshPreview()
            end)

            local condHint2 = MakeFS(autoSec, 10,
                "Optional. Type without brackets: @cursor  |  mod:shift  |  @cursor,mod:shift")
            condHint2:SetPoint("TOPLEFT",  autoSec, "TOPLEFT",  LBL_W, -56)
            condHint2:SetPoint("TOPRIGHT", autoSec, "TOPRIGHT", 0, -56)
            if grayC then condHint2:SetTextColor(grayC.r, grayC.g, grayC.b, 0.75) end

            local prevLbl = MakeFS(autoSec, 10, "Preview:")
            prevLbl:SetPoint("TOPLEFT", autoSec, "TOPLEFT", 0, -72)
            prevLbl:SetWidth(LBL_W - 4)
            if TEXT.light then
                prevLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            end

            previewFS = MakeFS(autoSec, 10, "")
            previewFS:SetPoint("TOPLEFT",  autoSec, "TOPLEFT",  LBL_W, -72)
            previewFS:SetPoint("TOPRIGHT", autoSec, "TOPRIGHT", 0, -72)
            previewFS:SetWordWrap(true)
            RefreshPreview()

            local manSec = CreateFrame("Frame", nil, rulesCard)
            manSec:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14,  bodySectionY)
            manSec:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -74, bodySectionY)
            manSec:SetHeight(68)
            if isAuto then manSec:Hide() end

            local bodyLbl = MakeFS(manSec, 10, "Macro body:")
            bodyLbl:SetPoint("TOPLEFT", manSec, "TOPLEFT", 0, 0)
            bodyLbl:SetWidth(LBL_W - 4)
            if TEXT.light then
                bodyLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            end

            manBodyEB = RC.UI:CreateStyledEditBox(manSec, {
                multiLine    = true,
                scrollable   = true,
                scrollHeight = 52,
                fontSize     = 11,
                maxLetters   = 255,
            })
            manBodyEB:SetPoint("TOPLEFT",  manSec, "TOPLEFT",  LBL_W, 0)
            manBodyEB:SetPoint("TOPRIGHT", manSec, "TOPRIGHT", 0, 0)
            manBodyEB.editBox:SetText(capRule.body or "")
            manBodyEB.editBox:SetScript("OnEditFocusLost", function(self)
                capRule.body = self:GetText()
                RC:SaveConfigurationToProfile()
            end)

            modeChk:SetScript("OnClick", function(cb)
                local nowAuto = cb:GetChecked()
                RC:ForceCheckboxUpdate(cb, nowAuto)
                if nowAuto then
                    capRule.buildMode = "auto"
                    autoSec:Show()
                    manSec:Hide()
                else
                    local gen = (RC.SmartMacro and RC.SmartMacro.BuildBody(capRule)) or ""
                    if gen ~= "" then
                        capRule.body = gen
                        manBodyEB.editBox:SetText(gen)
                    end
                    capRule.buildMode = "manual"
                    autoSec:Hide()
                    manSec:Show()
                end
                RC:SaveConfigurationToProfile()
            end)

            rcY = bodySectionY - 112 - 8

            local effectiveBody = RC.SmartMacro and RC.SmartMacro.BuildBody(capRule) or ""
            if effectiveBody == "" then
                local emptyNoteFS = MakeFS(rulesCard, 10,
                    "Body is empty: when this rule matches it CLEARS the macro (blanks it). " ..
                    "Fill in the Name (auto build) or a Manual body if you want it to write instead.")
                emptyNoteFS:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14, rcY)
                emptyNoteFS:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -14, rcY)
                emptyNoteFS:SetWordWrap(true)
                if goldC then emptyNoteFS:SetTextColor(goldC.r, goldC.g, goldC.b, 1) end
                rcY = rcY - math.max(emptyNoteFS:GetStringHeight(), 28) - 6
            end

            local itemLbl = MakeFS(rulesCard, 10, "Req. item:")
            itemLbl:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14, rcY)
            itemLbl:SetWidth(LBL_W - 4)
            if TEXT.light then
                itemLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            end

            local itemEB = RC.UI:CreateStyledEditBox(rulesCard, {
                height = 24, maxLetters = 80
            })
            itemEB:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14 + LBL_W, rcY)
            itemEB:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -74, rcY)
            itemEB.editBox:SetText(rule.itemCheck or "")
            -- same item-link auto-fill hook as the Auto Build Name box above.
            itemEB.editBox:SetScript("OnEditFocusGained", function(self)
                if RC.SmartMacro then RC.SmartMacro._lastFocusedEB = self end
            end)
            itemEB.editBox:SetScript("OnEnterPressed", function(self)
                capRule.itemCheck = self:GetText():match("^%s*(.-)%s*$") or ""
                self:ClearFocus()
                RC:SaveConfigurationToProfile()
            end)
            itemEB.editBox:SetScript("OnEditFocusLost", function(self)
                capRule.itemCheck = self:GetText():match("^%s*(.-)%s*$") or ""
                RC:SaveConfigurationToProfile()
            end)
            rcY = rcY - 32

            local itemHint = MakeFS(rulesCard, 10,
                "Optional: rule skipped if this item is not in bags or is on cooldown. " ..
                "Use exact item name, e.g. 'Goblin Sapper Charge'.")
            itemHint:SetPoint("TOPLEFT",  rulesCard, "TOPLEFT",  14 + LBL_W, rcY + 4)
            itemHint:SetPoint("TOPRIGHT", rulesCard, "TOPRIGHT", -74, rcY + 4)
            itemHint:SetWordWrap(true)
            if grayC then itemHint:SetTextColor(grayC.r, grayC.g, grayC.b, 0.75) end
            rcY = rcY - math.max(itemHint:GetStringHeight(), 28) - 10

        end
    end

    rcY = rcY - 8

    local addRuleBtn = Btn(rulesCard, "+ Add Rule", 110, 24)
    addRuleBtn:SetPoint("TOPLEFT", rulesCard, "TOPLEFT", 14, rcY)
    addRuleBtn:SetScript("OnClick", function()
        RC:AddSmartMacroRule(mac)
        RC:ShowSidebarSmartMacro(frame, true)
    end)
    rcY = rcY - 34

    rulesCard:SetContentHeight(math.abs(rcY) + 8)
    yPos = yPos - rulesCard:GetHeight() - 12

    local tipsCard = RC:CreateSettingsCard(parent, yPos, RCL["Tips & examples"])
    local tcY = -34

    local tips = {
        "Each condition row is OR: if any match, the rule fires. Add multiple to group targets: [Undead, No target] -> holy water for undead mobs and when resting.",
        "Example setup: Rule 1 [Undead, No target] -> Holy Water. Rule 2 [Not Undead] -> Dynamite. Beasts hit rule 2, undead and login hit rule 1.",
        "'Always (fires regardless)' overrides everything below it. Only use it alone on a true catch-all last rule.",
        "Dense Dynamite and Holy Water share the same 1-min cooldown. The 'Req. item' check handles fallthrough automatically.",
        "Goblin Sapper Charge has a 5-min cooldown. Use it as the Req. item on a named rule and add a creature-type fallback rule below it.",
        "Leave Req. item blank on fallback rules so they always fire when the condition matches.",
    }
    for _, tip in ipairs(tips) do
        local tipFS = MakeFS(tipsCard, 10, "- " .. tip)
        tipFS:SetPoint("TOPLEFT",  tipsCard, "TOPLEFT",  14, tcY)
        tipFS:SetPoint("TOPRIGHT", tipsCard, "TOPRIGHT", -14, tcY)
        tipFS:SetJustifyH("LEFT"); tipFS:SetWordWrap(true)
        if TEXT.light then tipFS:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
        tcY = tcY - math.max(tipFS:GetStringHeight(), 14) - 6
    end

    tipsCard:SetContentHeight(math.abs(tcY) + 6)
    yPos = yPos - tipsCard:GetHeight() - 12

    yPos = yPos - 4
    local delMacBtn = Btn(parent, "Delete This Smart Macro", 195, 26)
    delMacBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
    if delMacBtn.text then local _rc = RC:GetColor("text", "red"); delMacBtn.text:SetTextColor(_rc.r, _rc.g, _rc.b, 1) end
    local delMacId = mac.id
    delMacBtn:SetScript("OnClick", function()
        RC.UI:CreateConfirmDialog(
            RCL["Delete Smart Macro"],
            RCL["Delete '"] .. (mac.macroName ~= "" and mac.macroName or "unnamed") .. RCL["'?\n\nThis cannot be undone."],
            function()
                RC:DeleteSmartMacro(delMacId)
                SM_Editor.selectedId = nil
                RC:ShowSidebarSmartMacro(frame)
            end,
            nil, RCL["Delete"], true
        )
    end)
    yPos = yPos - 38

    RC:UpdateSidebarScrollbar(RC.sidebarConfigFrame, math.abs(yPos) + 40)
end

------------------------------------------------------------------------
-- A BAR SLOT'S PAGE (2026-11-16, Zac: "i want to be able to link like
-- specific slots on my action bar as well should work with action bar
-- addons and zui"): which slot, its group, the boss ability it follows.
-- A slot has no rules: it is told what to hold by a boss's page, a route
-- step or its link, and holds what you put there the rest of the time.
------------------------------------------------------------------------
function SM_RenderSlotEdit(frame, mac)
    local parent = frame.scrollChild
    local yPos   = -20
    local TEXT   = RC.UI and RC.UI.TEXT or {}
    local grayC  = RC:GetColor("text", "disabled")
    local goldC  = RC:GetColor("ui", "accentGold")

    local backBtn = RC.UI:CreateBackButton(parent, "< All Smart Macros", 165, 24)
    backBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
    backBtn:SetScript("OnClick", function()
        RC:StopPickingActionSlot(nil)
        SM_Editor.selectedId = nil
        RC:ShowSidebarSmartMacro(frame)
    end)
    yPos = yPos - 34

    local _, newY = RC:CreateSettingsPageHeader(
        parent, yPos,
        RCL["Bar Slot"],
        RCL["One slot of your action bars, told what to hold by your raid configs"],
        "Interface\\Icons\\INV_Scroll_03"
    )
    yPos = newY - 10

    local setupCard = RC:CreateSettingsCard(parent, yPos, RCL["Slot setup"])
    local scY = -34

    local slotLbl = MakeFS(setupCard, 11, "Slot:")
    slotLbl:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY)
    slotLbl:SetWidth(LBL_W)
    if TEXT.light then slotLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end

    -- the slot changed: what the old one was told to hold is undone first
    local function SetSlot(n)
        n = SlotNumber(n) or 0
        if n == mac.slot then return end
        if RC.SmartMacro then RC.SmartMacro:Release(mac) end
        mac.swapBack = nil
        mac.slot = n
        RC:SaveConfigurationToProfile()
        if RC.SmartMacro then RC.SmartMacro:RequestEvaluate() end
        C_Timer.After(0, function() RC:ShowSidebarSmartMacro(frame, true) end)
    end

    local slotEB = RC.UI:CreateStyledEditBox(setupCard, { height = 24, width = 54, maxLetters = 3 })
    slotEB:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14 + LBL_W + 6, scY)
    slotEB.editBox:SetNumeric(true)
    slotEB.editBox:SetText(SlotNumber(mac.slot) and tostring(mac.slot) or "")
    local function Typed(self)
        SetSlot(self:GetText())
        self:SetText(SlotNumber(mac.slot) and tostring(mac.slot) or "")
    end
    slotEB.editBox:SetScript("OnEnterPressed", function(self) Typed(self) self:ClearFocus() end)
    slotEB.editBox:SetScript("OnEditFocusLost", function(self) Typed(self) end)

    local pickBtn = Btn(setupCard, RCL["Click a button on my bars"], 210, 24)
    pickBtn:SetPoint("LEFT", slotEB, "RIGHT", 8, 0)
    pickBtn:SetScript("OnClick", function()
        RC:PickActionSlot(function(slot) if slot then SetSlot(slot) end end)
    end)
    scY = scY - ROW_H

    -- what the slot holds
    do
        local n = SlotNumber(mac.slot)
        local holdsFS = MakeFS(setupCard, 11, n and (RCL["holds: "] .. (RC:ActionSlotHolds(n) or RCL["nothing (empty)"]))
            or RCL["no slot picked yet - click its button below, or on your bars"])
        holdsFS:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14 + LBL_W + 6, scY + 4)
        holdsFS:SetJustifyH("LEFT")
        holdsFS:SetWordWrap(true)
        local cw = setupCard:GetWidth() or 0
        holdsFS:SetWidth(cw > 300 and (cw - (14 + LBL_W + 6) - 14) or 300)
        local c = n and grayC or goldC
        if c then holdsFS:SetTextColor(c.r, c.g, c.b, 1) end
        scY = scY - math.max(18, (holdsFS:GetStringHeight() or 14) + 6)
    end

    -- the bars as they are: a click picks the slot
    scY = scY - RC:BuildBarPreview(setupCard, 14, scY, {
        key = "slot",
        lit = function(slot) return slot == mac.slot end,
        tip = function(slot)
            if slot == mac.slot then return RCL["This is the slot."] end
            return RCL["Click to pick this button."]
        end,
        onPick = SetSlot,
    }) - 10

    local slotHint = MakeFS(setupCard, 10,
        "The action bars have 120 slots and every bar addon shows the same ones, so this works with any of them. "
        .. "A bar that changes with your stance or form has a slot per stance: pick the button in each stance and give them one group.")
    slotHint:SetPoint("TOPLEFT", setupCard, "TOPLEFT", 14, scY + 4)
    slotHint:SetJustifyH("LEFT")
    slotHint:SetWordWrap(true)
    if grayC then slotHint:SetTextColor(grayC.r, grayC.g, grayC.b, 0.8) end
    local cw = setupCard:GetWidth() or 0
    slotHint:SetWidth(cw > 300 and (cw - 28) or 300)
    scY = scY - math.max(20, (slotHint:GetStringHeight() or 14) + 8)

    scY = SetupGroupAndLink(setupCard, scY, mac, true)
    scY = SetupEnabledAndScope(frame, setupCard, scY, mac)

    setupCard:SetContentHeight(math.abs(scY) + 6)
    yPos = yPos - setupCard:GetHeight() - 12

    local infoCard = RC:CreateSettingsCard(parent, yPos, RCL["How a bar slot behaves"])
    local icY = -34
    for _, line in ipairs({
        "A bar slot has no rules of its own. It holds what you put on it until a boss's page (the Macros tile) or a route step hands it - or its whole group - one item: the slot holds that item.",
        "When that is over the slot gets back what it held. A slot you changed by hand in the meantime is left as you made it.",
        "A slot cannot change in a fight: target the boss before the pull. A slot is never emptied: if the item cannot be put on the bar (you carry none), the slot is left as it is.",
        "To switch a button off on some bosses, link it under the ability on a boss's page instead: that puts a macro on the button and takes nothing off the bar.",
    }) do
        local fs = MakeFS(infoCard, 10, line)
        fs:SetPoint("TOPLEFT", infoCard, "TOPLEFT", 14, icY)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(true)
        local iw = infoCard:GetWidth() or 0
        fs:SetWidth(iw > 300 and (iw - 28) or 420)
        if TEXT.light then fs:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3]) end
        icY = icY - math.max(14, (fs:GetStringHeight() or 12)) - 6
    end
    infoCard:SetContentHeight(math.abs(icY) + 6)
    yPos = yPos - infoCard:GetHeight() - 12

    local delMacId = mac.id
    local delBtn = Btn(parent, "Delete This Bar Slot", 200, 26)
    delBtn:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
    do local _c = RC:GetColor("text", "red"); if delBtn.text then delBtn.text:SetTextColor(_c.r, _c.g, _c.b, 1) end end
    delBtn:SetScript("OnClick", function()
        RC.UI:CreateConfirmDialog(
            RCL["Delete Bar Slot"],
            RCL["Delete '"] .. EntryLabel(mac) .. RCL["'?\n\nWhat the slot holds is not touched."],
            function()
                RC:StopPickingActionSlot(nil)
                RC:DeleteSmartMacro(delMacId)
                SM_Editor.selectedId = nil
                RC:ShowSidebarSmartMacro(frame)
            end,
            nil, RCL["Delete"], true
        )
    end)
    yPos = yPos - 38

    RC:UpdateSidebarScrollbar(RC.sidebarConfigFrame, math.abs(yPos) + 40)
end

if RC and RC.DebugPrint then RC:DebugPrint("SidebarSmartMacro loaded", "system") end
