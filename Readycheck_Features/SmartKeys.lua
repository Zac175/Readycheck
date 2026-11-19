------------------------------------------------------------------------
-- Readycheck Features - Smart keys
-- (2026-11-16, Zac: "i need this to be super user friendly can we add
-- like priviews of my bars and the ability to click things to pick
-- bars"; "make my death wish pressable when my ttk reminder goes off from
-- a boss". Kept in Readycheck_Testing until 2026-11-18, Zac: "move all
-- the testing stuff into the main addon".)
--
-- THE SWITCH. Everything a raid config can tell a macro or a bar slot to
-- be - a boss's Macros tile, a route step's macros, groups, the link to a
-- boss ability, bar slots - is in Readycheck's own files and does nothing
-- and shows nowhere unless RC.smartKeys is set. This file sets it: where
-- Readycheck_Features is loaded, smart keys are there.
--
-- THE PIECES THAT LIVE HERE (the pages in Readycheck call them, behind
-- that switch):
--   * the bar buttons on screen, whatever addon drew them, by slot;
--   * a preview of the action bars to click in (RC:BuildBarPreview);
--   * picking a slot by clicking its real button (RC:PickActionSlot);
--   * the list of the game's macros for a picker (RC:SmartKeyMacroChoices);
--   * linking a button: a macro is made for its spell or item and put
--     on the button in its place, so nothing is ever taken off a bar
--     (RC:SmartKeyLinkSlot, RC:SmartKeyUnlink / UnlinkSlot);
--   * AUTOMATIC: an ability ticked "Automatic" has every bar button that
--     holds it found and linked without a click (RC:SmartKeyAutoSync);
--   * the WAIT mark: a linked key's button is dimmed on a boss until the
--     ability's reminder has gone off there.
--
-- WHY A MARK AND NOT A LOCK. The game refuses, in combat, every call that
-- could change what a key does: a macro's text (EditMacro), taking
-- something off a bar slot or picking up a spell or a macro to put on one
-- (PickupAction, PickupSpell, PickupMacro), the bar's page, a key binding
-- - all since patch 2.0 / 2.2, and none of the macro conditionals reads
-- anything an addon may set in a fight. So an addon cannot switch a key
-- on at the moment a reminder goes off; it can only show that the moment
-- has come. A key is switched on or off for a boss before the pull
-- (Readycheck_Features\SmartMacro.lua); the mark is the rest.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

RC.smartKeys = true

-- Taint-safe API locals (never write _G)
local GetItemInfo = GetItemInfo or (RC.Compat and RC.Compat.GetItemInfo)
local GetSpellInfo = GetSpellInfo or (RC.Compat and RC.Compat.GetSpellInfo)

local function SlotNumber(v)
    local n = tonumber(v)
    if n and n >= 1 and n <= 120 and n == math.floor(n) then return n end
    return nil
end
local function Trim(v) return (type(v) == "string") and v:match("^%s*(.-)%s*$") or "" end
local function IsSlotEntry(mac) return type(mac) == "table" and mac.slot ~= nil end

------------------------------------------------------------------------
-- THE BARS BY NAME. The 120 slots are ten bars of twelve; a bar addon
-- numbers them the same way (its bar N is slots (N-1)*12+1 on). The
-- names beside the numbers are the game's own for its bars; a warrior's
-- seventh to ninth are what the main bar shows in each stance.
------------------------------------------------------------------------
local BAR_NAMES = {
    RCL["Main bar"], RCL["Main bar, page 2"], RCL["Right bar"], RCL["Right bar 2"],
    RCL["Bottom right bar"], RCL["Bottom left bar"],
}
local WARRIOR_BARS = { [7] = RCL["Battle Stance"], [8] = RCL["Defensive Stance"], [9] = RCL["Berserker Stance"] }
function RC:ActionBarName(bar)
    local name = BAR_NAMES[bar]
    if not name and bar >= 7 and bar <= 9 then
        local _, class = UnitClass("player")
        if class == "WARRIOR" then name = WARRIOR_BARS[bar] end
    end
    return RCL["Bar "] .. bar .. (name and (" - " .. name) or "")
end

------------------------------------------------------------------------
-- THE BAR BUTTONS ON SCREEN. A button says which slot it shows in one of
-- three ways: the game's own buttons and most bar addons keep it as
-- .action, the LibActionButton ones as _state_action (while they show an
-- action), the rest as their "action" attribute - which a pet button has
-- too, so that one only counts on a button whose type is "action".
------------------------------------------------------------------------
local function ButtonSlot(f)
    local n = SlotNumber(f.action)
    if n then return n end
    if f._state_type ~= nil then
        return f._state_type == "action" and SlotNumber(f._state_action) or nil
    end
    if f.GetAttribute then
        local t = f:GetAttribute("type")
        if t == nil or t == "action" then return SlotNumber(f:GetAttribute("action")) end
    end
    return nil
end
RC.BarButtonSlot = ButtonSlot

-- every button that shows a slot right now (hidden ones too: a bar that
-- only shows in one stance)
function RC:FindBarButtons()
    local out = {}
    if not EnumerateFrames then return out end
    local f = EnumerateFrames()
    while f do
        if not (f.IsForbidden and f:IsForbidden())
            and f.IsObjectType and f:IsObjectType("Button") and ButtonSlot(f) then
            out[#out + 1] = f
        end
        f = EnumerateFrames(f)
    end
    return out
end

------------------------------------------------------------------------
-- A COVER over a real bar button: a frame of ours on top of it. It is
-- never part of the button, so it can be shown, hidden and moved in a
-- fight. Two uses: picking a slot by a click (it takes the mouse, so the
-- click does not press the key) and the WAIT mark (it does not).
------------------------------------------------------------------------
local covers = {}       -- every cover made, reused
RC._smartKeyCovers = covers
local function GetCover(i)
    local c = covers[i]
    if c then return c end
    c = CreateFrame("Button", nil, UIParent)
    c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    c.dim = c:CreateTexture(nil, "BACKGROUND")
    c.dim:SetAllPoints()
    c.dim:SetTexture(RC.UI.FLAT)
    c.border = RC.UI:CreateSimpleBorder(c, 2)
    c.label = RC:CreateFontString(c, "OVERLAY", nil, 9)
    c.label:SetPoint("CENTER")
    c:Hide()
    covers[i] = c
    return c
end
-- puts a cover on a button, just above it in the button's own layer
local function PlaceCover(c, b)
    c.slot, c.button = ButtonSlot(b), b
    c:ClearAllPoints()
    c:SetAllPoints(b)
    c:SetFrameStrata(b:GetFrameStrata())
    c:SetFrameLevel((b:GetFrameLevel() or 0) + 10)
end
local function PaintCover(c, col, dimAlpha, text)
    local k = RC.UI.C.blackDim
    c.dim:SetVertexColor(k[1], k[2], k[3], dimAlpha)
    RC.UI:UpdateBorderColor(c.border, col, 1)
    c.label:SetText(text or "")
    c.label:SetTextColor(col.r, col.g, col.b, 1)
end
local function HideCovers(from)
    for i = from, #covers do
        local c = covers[i]
        c:Hide()
        c:ClearAllPoints()
        c.slot, c.button = nil, nil
    end
end

------------------------------------------------------------------------
-- PICK A SLOT BY CLICKING ITS BUTTON. Every bar button on screen gets a
-- gold cover; a left click on one picks its slot, a right click or Escape
-- gives up. onDone(slot | nil), once. Out of combat only, and a fight
-- ends it: the covers sit on the keys.
------------------------------------------------------------------------
local picking       -- { onDone }
local escFrame
function RC:StopPickingActionSlot(slot)
    local P = picking
    if not P then return end
    picking = nil
    HideCovers(1)
    if escFrame then escFrame:Hide() end
    RC:SmartKeyMarks()      -- (the covers are the marks' too)
    if P.onDone then P.onDone(slot) end
end
function RC:PickActionSlot(onDone)
    if InCombatLockdown() then
        RC:Print(RCL["A bar slot can only be picked out of combat."])
        return false
    end
    RC:StopPickingActionSlot(nil)
    local gold = RC:GetColor("ui", "accentGold")
    local n = 0
    for _, b in ipairs(RC:FindBarButtons()) do
        if b:IsVisible() then
            n = n + 1
            local c = GetCover(n)
            PlaceCover(c, b)
            c:EnableMouse(true)
            PaintCover(c, gold, 0.35, tostring(c.slot))
            c:SetScript("OnClick", function(self, btn)
                RC:StopPickingActionSlot(btn == "LeftButton" and self.slot or nil)
            end)
            c:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(RC:ActionSlotLabel(self.slot), 1, 1, 1)
                GameTooltip:AddLine(RCL["Click to pick this button. Right-click or Escape gives up."], 0.7, 0.7, 0.7, true)
                GameTooltip:Show()
            end)
            c:SetScript("OnLeave", function() GameTooltip:Hide() end)
            c:Show()
        end
    end
    HideCovers(n + 1)
    if n == 0 then
        RC:Print(RCL["No bar buttons found on screen. Pick the slot in the preview instead."])
        return false
    end
    if not escFrame then
        escFrame = CreateFrame("Frame", "ReadycheckSlotPicker", UIParent)
        escFrame:SetSize(1, 1)
        escFrame:SetPoint("TOPLEFT")
        escFrame:SetFrameStrata("DIALOG")
        escFrame:EnableKeyboard(true)
        escFrame:SetScript("OnKeyDown", function(self, key)
            self:SetPropagateKeyboardInput(key ~= "ESCAPE")
            if key == "ESCAPE" then RC:StopPickingActionSlot(nil) end
        end)
        escFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
        escFrame:SetScript("OnEvent", function() RC:StopPickingActionSlot(nil) end)
    end
    escFrame:Show()
    picking = { onDone = onDone }
    return true
end

------------------------------------------------------------------------
-- A PREVIEW OF THE ACTION BARS, to click in: ten rows of twelve tiles,
-- each the slot's icon, a row per bar with its name. Drawn on `parent`
-- with its top-left at (x, y).
--   opts.key     which preview this is ("link", "slot"): its 120 tiles are
--                made once and moved to each new build of the page
--   opts.width   the room it has (default: what the parent leaves)
--   opts.lit     function(slot) -> true: that tile is lit
--   opts.onPick  function(slot): a tile was clicked
--   opts.tip     function(slot) -> the grey line of a tile's tooltip
-- Returns its height.
------------------------------------------------------------------------
local TILE_GAP = 2
local tilePools = {}
function RC:BuildBarPreview(parent, x, y, opts)
    opts = opts or {}
    local S = RC.SidebarSearch
    local dry = S and S.inDryRun
    local labels, labelW = {}, 0
    for bar = 1, 10 do
        local fs = RC:CreateFontString(parent, "OVERLAY", nil, 10)
        fs:SetText(RC:ActionBarName(bar))
        local c = RC:GetColor("text", "disabled")
        fs:SetTextColor(c.r, c.g, c.b, 1)
        labels[bar] = fs
        labelW = math.max(labelW, math.ceil(fs:GetStringWidth() or 0))
    end
    local avail = opts.width or ((parent:GetWidth() or 0) - x - 14)
    local size = math.floor((avail - labelW - 10 - 11 * TILE_GAP) / 12)
    if avail <= 0 or size > 26 then size = 26 end
    if size < 14 then size = 14 end
    local rowH = size + TILE_GAP
    local pool = tilePools[opts.key or "preview"]
    if not pool then
        pool = {}
        tilePools[opts.key or "preview"] = pool
    end
    for bar = 1, 10 do
        local ry = y - (bar - 1) * rowH
        labels[bar]:SetPoint("TOPLEFT", parent, "TOPLEFT", x, ry - math.floor((size - 10) / 2))
        -- (the search's unseen build reads the words only: the tiles stay
        -- with the page that is on screen)
        for i = 1, (dry and 0 or 12) do
            local slot = (bar - 1) * 12 + i
            local tile = pool[slot]
            if not tile then
                tile = RC.UI:CreateIconToggleTile(parent, size, nil, { keepColor = true, offAlpha = 0.55 })
                pool[slot] = tile
            end
            tile.slot = slot
            tile:SetParent(parent)
            tile:ClearAllPoints()
            tile:SetSize(size, size)
            tile:SetPoint("TOPLEFT", parent, "TOPLEFT", x + labelW + 10 + (i - 1) * (size + TILE_GAP), ry)
            local _, tex = RC:ActionSlotHolds(slot)
            if tex then
                tile.icon:SetTexture(tex)
                tile.icon:Show()
            else
                tile.icon:Hide()
            end
            tile:SetOn(opts.lit and opts.lit(slot) and true or false)
            tile:SetScript("OnClick", function()
                if opts.onPick then opts.onPick(slot) end
            end)
            tile:SetScript("OnEnter", function(self)
                self:Repaint()
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(RC:ActionBarName(bar) .. RCL[", button "] .. i, 1, 1, 1)
                GameTooltip:AddLine(RC:ActionSlotLabel(slot), 0.9, 0.9, 0.9, true)
                local tip = opts.tip and opts.tip(slot)
                if tip then GameTooltip:AddLine(tip, 0.7, 0.7, 0.7, true) end
                GameTooltip:Show()
            end)
            tile:SetScript("OnLeave", function(self)
                self:Repaint()
                GameTooltip:Hide()
            end)
            tile:Show()
        end
    end
    return 10 * rowH
end

------------------------------------------------------------------------
-- THE GAME'S MACROS, for a picker: every macro of the account and of this
-- character, by name with its icon (a name used twice is listed once: a
-- macro is found by its name).
------------------------------------------------------------------------
function RC:SmartKeyMacroChoices()
    local items, seen = {}, {}
    local nAcct, nChar = 0, 0
    if GetNumMacros then nAcct, nChar = GetNumMacros() end
    local maxAcct = MAX_ACCOUNT_MACROS or 120
    local function Add(i)
        local name, icon = GetMacroInfo(i)
        if name and name ~= "" and not seen[name] then
            seen[name] = true
            items[#items + 1] = { text = name, value = name, icon = icon }
        end
    end
    for i = 1, (nAcct or 0) do Add(i) end
    for i = maxAcct + 1, maxAcct + (nChar or 0) do Add(i) end
    table.sort(items, function(a, b) return a.text:lower() < b.text:lower() end)
    if #items == 0 then
        items[1] = { text = RCL["You have no macros yet (make one with /macro)"], value = "" }
    end
    return items
end

------------------------------------------------------------------------
-- A LINK IS A MACRO ON THE BUTTON (2026-11-16, Zac: "i want this setup to
-- make macros or something for all the important action bars i dont want
-- it to completely nuke my default keybinds and stuff"). Nothing is ever
-- taken off a bar to switch a key off. Linking a button to a boss ability:
--   * a button holding a spell or an item gets a macro made for it here
--     ("RC Death Wish": #showtooltip + /cast, so the icon, tooltip and
--     cooldown are the spell's) in the same slot - same key, same place -
--     and what the slot held is noted (mac.placed[slot]) to put back;
--   * a button holding one of your own macros keeps it: that macro is
--     linked by its name.
-- Either way the list gets a macro entry linked to the ability, with its
-- RESTING TEXT (mac.ownBody: SmartMacro.lua) - what it reads on every boss
-- where the ability is on, off any boss, and on a boss with nothing set
-- up. On a boss that is set up with the ability off, the engine writes
-- the off text; afterwards the resting text comes back, also after a
-- crash or with this addon gone.
-- Unlinking puts back what each slot held and deletes the macro made.
-- Macros are made, placed and deleted out of combat only, never with
-- something on the cursor.
------------------------------------------------------------------------
local OWN_ICON = "INV_Misc_QuestionMark"
local function Entries() return (RC.db and RC.db.smartMacros) or {} end
local function CursorBusy() return GetCursorInfo ~= nil and GetCursorInfo() ~= nil end

-- the entry of the list that is this bar slot / this macro (nil: none)
function RC:SmartKeyEntryForSlot(slot)
    for _, m in ipairs(Entries()) do
        if IsSlotEntry(m) and m.slot == slot then return m end
    end
    return nil
end
function RC:SmartKeyEntryForMacro(name)
    for _, m in ipairs(Entries()) do
        if not IsSlotEntry(m) and m.macroName == name then return m end
    end
    return nil
end

-- the macro a slot holds, by name (nil: not a macro)
local function SlotMacroName(slot)
    local kind, id = GetActionInfo(slot)
    if kind ~= "macro" then return nil end
    local name = C_ActionBar.GetActionText(slot)
    if not name or name == "" then name = GetMacroInfo(id) end
    return name
end
-- the entry behind a button: the entry of the macro its slot holds
function RC:SmartKeyEntryOnSlot(slot)
    local name = SlotMacroName(slot)
    return name and RC:SmartKeyEntryForMacro(name) or nil
end
local function MacroOnBars(name)
    for slot = 1, 120 do
        if SlotMacroName(slot) == name then return true end
    end
    return false
end

local function SpellBody(name) return "#showtooltip " .. name .. "\n/cast " .. name end
local function ItemBody(id)
    local n = GetItemInfo(id) or ("item:" .. id)
    return "#showtooltip " .. n .. "\n/use " .. n
end

-- THE MACRO MADE FOR ONE SPELL OR ITEM: its entry and the game macro's
-- index. One per spell or item, whatever number of buttons hold it.
-- nil, "full" when the game has no room for another macro.
local function OwnMacro(kind, id, tile, auto)
    local what, body
    if kind == "spell" then
        what = GetSpellInfo(id)
        if not what then return nil, "unknown" end
        body = SpellBody(what)
    else
        what = GetItemInfo(id)
        body = ItemBody(id)
    end
    local key = kind .. ":" .. (kind == "spell" and what or tostring(id))
    local mac
    for _, m in ipairs(Entries()) do
        if m.owned and m.ownKey == key then mac = m break end
    end
    local fresh = false
    if not mac then
        local name = ("RC " .. (what or ("item " .. id))):sub(1, 16):gsub("%s+$", "")
        -- (a name another entry of the list already goes by: by its number)
        if RC:SmartKeyEntryForMacro(name) then name = ("RC " .. kind .. " " .. id):sub(1, 16) end
        mac = RC:CreateSmartMacro()
        mac.macroName, mac.owned, mac.ownKey, mac.ownBody = name, true, key, body
        mac.auto = auto and true or nil
        mac.placed = {}
        fresh = true
    end
    local idx = GetMacroIndexByName(mac.macroName) or 0
    if idx == 0 then
        local nAcct, nChar = 0, 0
        if GetNumMacros then nAcct, nChar = GetNumMacros() end
        if (nAcct or 0) < (MAX_ACCOUNT_MACROS or 120) then
            CreateMacro(mac.macroName, OWN_ICON, mac.ownBody, nil)
        elseif (nChar or 0) < (MAX_CHARACTER_MACROS or 18) then
            CreateMacro(mac.macroName, OWN_ICON, mac.ownBody, 1)
        end
        idx = GetMacroIndexByName(mac.macroName) or 0
    end
    if idx == 0 then
        if fresh then RC:DeleteSmartMacro(mac.id) end
        return nil, "full"
    end
    mac.ability = tile
    if not auto then mac.auto = nil end
    return mac, idx
end

-- LINK THE BUTTON OF A SLOT to a boss ability (auto: found by the
-- automatic keys, not by a click). Returns the entry, or nil and why:
-- "busy" (a fight, or something on the cursor), "empty" (nothing a key
-- could be made of), "full" (no room for a macro).
function RC:SmartKeyLinkSlot(slot, tile, auto)
    if InCombatLockdown() or CursorBusy() then return nil, "busy" end
    local kind, id = GetActionInfo(slot)
    if kind == "macro" then
        local name = SlotMacroName(slot)
        if not name or name == "" then return nil, "empty" end
        return RC:SmartKeyLinkMacro(name, tile, auto)
    elseif kind == "spell" or kind == "item" then
        local mac, idx = OwnMacro(kind, id, tile, auto)
        if not mac then return nil, idx end
        ClearCursor()
        PickupMacro(idx)
        if not GetCursorInfo() then return nil, "busy" end
        PlaceAction(slot)
        ClearCursor()           -- (what the slot held comes back on the cursor)
        mac.placed = type(mac.placed) == "table" and mac.placed or {}
        mac.placed[slot] = { kind = kind, id = id }
        return mac
    end
    return nil, "empty"
end

-- LINK ONE OF YOUR OWN MACROS by its name: its entry (added if it is not
-- on the list), with the text it has now as its resting text when it has
-- no rules of its own.
function RC:SmartKeyLinkMacro(name, tile, auto)
    if type(name) ~= "string" or name == "" then return nil, "empty" end
    local mac = RC:SmartKeyEntryForMacro(name)
    if not mac then
        mac = RC:CreateSmartMacro()
        mac.macroName = name
        mac.auto = auto and true or nil
    end
    if not auto then mac.auto = nil end
    mac.ability = tile
    if not mac.owned and #(mac.rules or {}) == 0 and not mac.swapBack then
        local idx = GetMacroIndexByName(name) or 0
        local body = idx > 0 and GetMacroBody and GetMacroBody(idx) or nil
        local SM = RC.SmartMacro
        if type(body) == "string" and body ~= "" and not (SM and body == SM.OFF_BODY) then mac.ownBody = body end
    end
    return mac
end

-- what one slot held goes back (only while it still holds the macro)
local function RestoreSlot(mac, slot)
    local placed = type(mac.placed) == "table" and mac.placed or {}
    if SlotMacroName(slot) == mac.macroName then
        local was = placed[slot]
        if not was then
            -- (no note of it: what the macro was made for)
            local kind, v = tostring(mac.ownKey or ""):match("^(%a+):(.+)$")
            if kind == "item" then
                was = { kind = "item", id = tonumber(v) }
            elseif kind == "spell" then
                local _, _, _, _, _, _, sid = GetSpellInfo(v)
                if sid then was = { kind = "spell", id = sid } end
            end
        end
        local lib = RC.SmartMacro and RC.SmartMacro._slotLib
        if was and lib then lib.Fill(slot, was) end
    end
    placed[slot] = nil
end

-- UNLINK an entry. A macro made here: every button gets back what it
-- held, and the macro and its entry go. One of your own macros: its text
-- as it was, and its entry goes too when it was only there for the link
-- (no rules, no group). false in a fight or with the cursor busy.
function RC:SmartKeyUnlink(mac)
    if type(mac) ~= "table" then return false end
    if InCombatLockdown() or CursorBusy() then
        RC:Print(RCL["A key can only be unlinked out of combat, with nothing on the cursor."])
        return false
    end
    local SM = RC.SmartMacro
    if mac.owned then
        local name = mac.macroName
        for slot = 1, 120 do
            if SlotMacroName(slot) == name then RestoreSlot(mac, slot) end
        end
        if RC.DeleteSmartMacro then RC:DeleteSmartMacro(mac.id) end
        local idx = GetMacroIndexByName(name) or 0
        if idx > 0 and not MacroOnBars(name) then DeleteMacro(idx) end
        return true
    end
    if SM then SM:Release(mac) end
    local idx = GetMacroIndexByName(mac.macroName or "") or 0
    if idx > 0 and SM and type(mac.ownBody) == "string" and GetMacroBody(idx) == SM.OFF_BODY then
        EditMacro(idx, nil, nil, mac.ownBody)
    end
    mac.ability, mac.auto, mac.ownBody = nil, nil, nil
    local bare = #(mac.rules or {}) == 0 and Trim(mac.group) == "" and Trim(mac.alsoRun) == ""
    if bare and RC.DeleteSmartMacro then
        RC:DeleteSmartMacro(mac.id)
    else
        RC:SaveConfigurationToProfile()
    end
    return true
end

-- UNLINK ONE BUTTON: a macro made here comes off that slot only (and goes
-- altogether with its last button); one of your own is unlinked.
function RC:SmartKeyUnlinkSlot(slot)
    local mac = RC:SmartKeyEntryOnSlot(slot)
    if not mac then return false end
    if InCombatLockdown() or CursorBusy() then
        RC:Print(RCL["A key can only be unlinked out of combat, with nothing on the cursor."])
        return false
    end
    if mac.owned then
        RestoreSlot(mac, slot)
        if MacroOnBars(mac.macroName) then
            RC:SaveConfigurationToProfile()
            return true
        end
    end
    return RC:SmartKeyUnlink(mac)
end

------------------------------------------------------------------------
-- AUTOMATIC (2026-11-16, Zac: "i dont really want it to be like make a
-- macro i want that all automated for me"). An ability ticked Automatic
-- on its keys card (RC.db.smartKeysAuto[tile] = true) needs no linking:
-- every button on the bars that holds it is linked by itself (the entry
-- carries mac.auto = true), and unlinked again when the tick comes off.
-- What "holds it" means:
--   * a spell tile (Death Wish, Recklessness, a racial...): the spell by
--     name, any rank; Defensives: Last Stand or Shield Wall;
--   * Potion: an item of the potion list (the boss's own potions);
--   * one of your macros whose /cast and /use lines name that one spell
--     and nothing else - a macro that also casts something else is left
--     alone, so a bigger macro is never switched off whole. (Not for
--     potions: a potion macro of yours is linked by hand.)
-- Trinkets and Utility are not offered: which button is theirs depends on
-- what is worn and carried that day.
-- Read off the bars as you made them: never in a fight, never with
-- something on the cursor, never while a boss is in force. A button you
-- linked by hand stays yours.
-- The same pass moves a link that still sits on a bar slot entry (how
-- links were kept at first) onto a macro on that slot.
------------------------------------------------------------------------
local AUTO_NOT = { trinkets = true, utility = true }
function RC:SmartKeyAutoOffered(tile) return type(tile) == "string" and not AUTO_NOT[tile] end

-- lowercase name -> tile, for what the bars can hold
local function AutoNames()
    local names, items = {}, {}
    local auto = RC.db and RC.db.smartKeysAuto
    if type(auto) ~= "table" then return names, items end
    local AD = RC.abilityData or {}
    for tile, on in pairs(auto) do
        if on and RC:SmartKeyAutoOffered(tile) then
            if tile == "defensives" then
                for _, k in ipairs({ "laststand", "shieldwall" }) do
                    if AD[k] and AD[k].name then names[AD[k].name:lower()] = tile end
                end
            elseif tile == "potion" then
                for _, p in pairs((RC.potionData and RC.potionData.potions) or {}) do
                    local id = type(p) == "table" and tonumber(p.itemId)
                    if id then
                        items[id] = tile
                        local n = GetItemInfo(id)
                        if n then names[n:lower()] = tile end
                    end
                end
            elseif AD[tile] and AD[tile].name and not AD[tile].isItem then
                names[AD[tile].name:lower()] = tile
            end
        end
    end
    return names, items
end

-- the one thing a macro casts or uses (lowercase), nil when it names
-- several or none
local function MacroCasts(body)
    if type(body) ~= "string" then return nil end
    local found
    for line in body:gmatch("[^\r\n]+") do
        local cmd, rest = line:match("^%s*/(%a+)%s+(.*)$")
        cmd = cmd and cmd:lower()
        if cmd == "castsequence" then return nil end
        if cmd == "cast" or cmd == "use" then
            for part in (rest .. ";"):gmatch("([^;]*);") do
                local name = part:gsub("%b[]", ""):gsub("^%s*!?", ""):gsub("%s*%(.-%)%s*$", ""):gsub("%s+$", ""):lower()
                if name ~= "" then
                    if found and found ~= name then return nil end
                    found = name
                end
            end
        end
    end
    return found
end
RC.SmartKeyMacroCasts = MacroCasts

-- the tile a slot's contents belong to (nil: none of the automatic ones)
local function AutoTileOfSlot(slot, names, items)
    local kind, id = GetActionInfo(slot)
    if kind == "spell" then
        local n = GetSpellInfo(id)
        return n and names[n:lower()] or nil
    elseif kind == "item" then
        return items[id]
    elseif kind == "macro" then
        local name = C_ActionBar.GetActionText(slot)
        if not name or name == "" then name = GetMacroInfo(id) end
        local idx = name and GetMacroIndexByName and GetMacroIndexByName(name) or 0
        local what = (idx and idx > 0 and GetMacroBody) and MacroCasts(GetMacroBody(idx)) or nil
        if not what then return nil end
        local viaItem = tonumber(what:match("^item:(%d+)$"))
        return names[what] or (viaItem and items[viaItem]) or nil
    end
    return nil
end

function RC:SmartKeyAutoSync()
    local SM = RC.SmartMacro
    if not (RC.smartKeys and SM and RC.db and RC.CreateSmartMacro) then return end
    if InCombatLockdown() or SM._bossHold or CursorBusy() then return end
    local list = RC.db.smartMacros
    if type(list) ~= "table" then return end
    local changed = false

    -- a link on a bar slot entry: onto a macro on that slot
    for i = #list, 1, -1 do
        local mac = list[i]
        if IsSlotEntry(mac) and Trim(mac.ability) ~= "" and not mac.swapBack then
            local slot, tile, auto = SlotNumber(mac.slot), mac.ability, mac.auto
            mac.ability, mac.auto = nil, nil
            if Trim(mac.group) == "" then RC:DeleteSmartMacro(mac.id) end
            if slot then RC:SmartKeyLinkSlot(slot, tile, auto) end
            changed = true
        end
    end

    -- the ticked abilities: every button that holds one
    local names, items = AutoNames()
    if next(names) or next(items) then
        for slot = 1, 120 do
            local tile = AutoTileOfSlot(slot, names, items)
            if tile then
                local kind = GetActionInfo(slot)
                if kind ~= "macro" then
                    if RC:SmartKeyLinkSlot(slot, tile, true) then changed = true end
                elseif tile ~= "potion" and not RC:SmartKeyEntryOnSlot(slot) then
                    -- (one of your own macros, not on the list yet)
                    if RC:SmartKeyLinkSlot(slot, tile, true) then changed = true end
                end
            end
        end
    end

    -- found keys whose ability is no longer ticked, or (a macro made
    -- here) that are on no button any more
    local auto = type(RC.db.smartKeysAuto) == "table" and RC.db.smartKeysAuto or {}
    for i = #list, 1, -1 do
        local mac = list[i]
        if mac and mac.auto and not IsSlotEntry(mac) and not mac.swapBack then
            if not auto[mac.ability] or (mac.owned and not MacroOnBars(mac.macroName)) then
                if RC:SmartKeyUnlink(mac) then changed = true end
            end
        end
    end

    if changed then
        RC:SaveConfigurationToProfile()
        SM:RequestEvaluate()
    end
    return changed
end

-- the tick on an ability's keys card
function RC:SmartKeyAutoOn(tile)
    local auto = RC.db and RC.db.smartKeysAuto
    return type(auto) == "table" and auto[tile] == true
end
function RC:SetSmartKeyAuto(tile, on)
    if not (RC.db and RC:SmartKeyAutoOffered(tile)) then return end
    if type(RC.db.smartKeysAuto) ~= "table" then RC.db.smartKeysAuto = {} end
    RC.db.smartKeysAuto[tile] = on and true or nil
    RC:SaveConfigurationToProfile()
    RC:SmartKeyAutoSync()
end

------------------------------------------------------------------------
-- THE WAIT MARK. On the boss in force (RC.SmartMacro's: the one last
-- targeted, until another enemy is or its fight is over), an entry linked
-- to an ability that is switched on there waits for that ability's
-- reminder: until it has gone off on this boss, every bar button showing
-- the entry - its slot, or a slot holding its macro - is dimmed and reads
-- WAIT. When the reminder goes off the mark turns into a lit frame for a
-- few seconds and is gone. The key itself works throughout (see the top
-- of the file): this only shows when.
------------------------------------------------------------------------
local GO_SECONDS = 4
local fired = {}        -- [tile key] and [the reminder's own key] = GetTime() it went off
local firedBoss         -- the boss they went off on
local firedCfg          -- that boss's settings (nil: nothing set up on it)
local markButtons       -- the bar buttons, looked up once per boss
local marksDirty = false

-- the tile of a boss's page an ability's reminder belongs to (the reverse
-- of RC:EncounterAbilityOn; a reminder names a potion by its type and a
-- utility item by its id)
local function TileOf(key)
    if key == "trinket1" or key == "trinket2" or key == "battleChicken" or key == "arcaniteDragonling" then
        return "trinkets"
    elseif key == "laststand" or key == "shieldwall" then
        return "defensives"
    elseif tonumber(key) then
        return "utility"
    elseif type(key) == "string" and key:lower():find("potion") then
        return "potion"
    end
    return key
end
RC.SmartKeyTileOf = TileOf

-- the slots an entry shows on
local function EntrySlots(mac, out)
    if IsSlotEntry(mac) then
        local n = SlotNumber(mac.slot)
        if n then out[n] = true end
        return
    end
    local name = Trim(mac.macroName)
    if name == "" then return end
    for slot = 1, 120 do
        local kind, id = GetActionInfo(slot)
        if kind == "macro" then
            local held = C_ActionBar.GetActionText(slot)
            if not held or held == "" then held = GetMacroInfo(id) end
            if held == name then out[slot] = true end
        end
    end
end

-- [slot] = "wait" | "go" for the boss in force
function RC:SmartKeyStates()
    local out = {}
    local SM = RC.SmartMacro
    if not (SM and SM.Boss and RC.db) then return out end
    local key, cfg = SM:Boss()
    if key ~= firedBoss then
        firedBoss = key
        fired = {}
        markButtons = nil
    end
    firedCfg = cfg
    if not key then return out end
    local now = GetTime()
    for _, mac in ipairs(RC.db.smartMacros or {}) do
        local ability = Trim(mac.ability)
        if mac.enabled and ability ~= "" and RC:EncounterAbilityOn(cfg, ability) then
            local at = fired[ability]
            local state = (not at) and "wait" or ((now - at) < GO_SECONDS and "go" or nil)
            if state then
                local slots = {}
                EntrySlots(mac, slots)
                for slot in pairs(slots) do
                    if out[slot] ~= "wait" then out[slot] = state end
                end
            end
        end
    end
    return out
end

function RC:SmartKeyMarks()
    marksDirty = false
    RC:SmartKeyAutoSync()               -- (the bars may have changed: the automatic keys follow)
    if picking then return end          -- (the covers are the picker's now)
    local states = RC:SmartKeyStates()
    if not next(states) then
        HideCovers(1)
        return
    end
    markButtons = markButtons or RC:FindBarButtons()
    local wait, go = RC:GetColor("text", "warning"), RC:GetColor("text", "success")
    local n, again = 0, false
    for _, b in ipairs(markButtons) do
        local state = b:IsVisible() and states[ButtonSlot(b) or 0] or nil
        if state then
            n = n + 1
            local c = GetCover(n)
            PlaceCover(c, b)
            c:EnableMouse(false)
            if state == "wait" then
                PaintCover(c, wait, 0.6, RCL["WAIT"])
            else
                PaintCover(c, go, 0, "")
                again = true
            end
            c:Show()
        end
    end
    HideCovers(n + 1)
    -- (a lit frame comes off by itself)
    if again then C_Timer.After(GO_SECONDS, function() RC:SmartKeyMarksSoon() end) end
end

-- one refresh asked for: a burst of asks costs a single pass, after the
-- smart macros' own (0.25 s) has read the target
function RC:SmartKeyMarksSoon()
    if marksDirty then return end
    marksDirty = true
    C_Timer.After(0.4, function()
        if marksDirty then RC:SmartKeyMarks() end
    end)
end

-- A reminder went off (TE_Triggers, RunTriggerCheck): its abilities' tiles
-- are no longer waited for on this boss.
function RC:SmartKeysReminderFired(abilities)
    if type(abilities) ~= "table" then return end
    local now, new = GetTime(), false
    for _, key in ipairs(abilities) do
        local tile = TileOf(key)
        if tile and not fired[tile] then
            fired[tile] = now
            new = true
        end
        if key ~= nil and not fired[tostring(key)] then fired[tostring(key)] = now end
    end
    if new then RC:SmartKeyMarks() end
end

-- FOR A HUD (ZacUI's Warrior HUD reads it): one ability of a boss's page
-- by its stored key ("deathwish", "trinket1", an item id...) on the boss
-- in force - "wait": switched on there and its reminder has not gone off
-- yet; "go": it went off within the last few seconds; nil: anything else
-- (no boss, not switched on there, long gone off).
function RC:SmartKeyAbilityState(key)
    local SM = RC.SmartMacro
    local hold = SM and SM._bossHold
    -- (read off what the marks' own pass last saw, a moment after every
    -- change of target: this is asked many times a second)
    if key == nil or not hold or hold.key ~= firedBoss then return nil end
    local list = type(firedCfg) == "table" and firedCfg.abilities
    local a = type(list) == "table" and (list[key] or list[tonumber(key) or false] or list[tostring(key)])
    if not (type(a) == "table" and a.enabled) then return nil end
    local at = fired[tostring(key)]
    if not at then return "wait" end
    return (GetTime() - at) < GO_SECONDS and "go" or nil
end

-- What moves a mark: the target (the boss in force), a fight starting or
-- ending, what a slot holds, the bar a button shows (stance, page).
-- Dirty flag only: the pass itself runs once, a moment later.
local markFrame = CreateFrame("Frame")
for _, ev in ipairs({ "PLAYER_TARGET_CHANGED", "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED",
    "ENCOUNTER_END", "ACTIONBAR_SLOT_CHANGED", "ACTIONBAR_PAGE_CHANGED", "UPDATE_BONUS_ACTIONBAR",
    "UPDATE_SHAPESHIFT_FORM", "PLAYER_ENTERING_WORLD" }) do
    markFrame:RegisterEvent(ev)
end
markFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_ENTERING_WORLD" then
        markButtons = nil
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- the reminders start over 3 s after a fight (Core_Events, the
        -- usedAbilities clear): so do the marks
        C_Timer.After(3, function()
            if not InCombatLockdown() then
                fired = {}
                RC:SmartKeyMarksSoon()
            end
        end)
    end
    RC:SmartKeyMarksSoon()
end)

if RC.DebugPrint then RC:DebugPrint("SmartKeys loaded", "system") end
