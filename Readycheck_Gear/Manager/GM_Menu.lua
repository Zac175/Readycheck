local RCC = _G.Readycheck
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)
local AddonName = "Readycheck"
local RC = _G[AddonName]

if not RC then
    error("Readycheck core not found!")
end

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local GetTime = GetTime
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GetInventoryItemLink = GetInventoryItemLink
local GetInventoryItemID = GetInventoryItemID
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
local C_Container = C_Container
local C_Timer = C_Timer
RC._gms = RC._gms or {}
local _gms = RC._gms
local GM = RC.GearManager
local C, GetGMSlotHoverBorder = _gms.C, _gms.GetGMSlotHoverBorder
local TruncateToWidth = _gms.TruncateToWidth
------------------------------------------------------------------------
-- Readycheck - Gear Manager Menu
-- The hover flyout (equipment choices per slot / gear-set picker) and
-- the docked-button drag-to-dock system: CheckAndDock/ApplyDocking snap
-- buttons together and record dockTo/dockSide, which LoadButtonPosition
-- (GM_Buttons.lua) replays on the next login to rebuild the layout.
------------------------------------------------------------------------
------------------------------------------------------------------------
-- Hidden menu entries. Ctrl+Right-click hides an item or a set from
-- dockable buttons' hover menus. Items are told apart by item, enchant
-- and random suffix, so the unenchanted Goblin Rocket Boots can go while
-- the enchanted pair stays (copies identical in all three cannot be told
-- apart by the game, so they hide together). Both trinket or ring docks
-- agree, since the key does not include the slot. holding the reveal key over an open menu shows them faded, and
-- Ctrl+<reveal>+Right-click on a faded one brings it back. The character sheet
-- menus, the set editor and remote views always show everything.
------------------------------------------------------------------------
local REVEAL_KEYS = { SHIFT = IsShiftKeyDown, CTRL = IsControlKeyDown, ALT = IsAltKeyDown }

function GM:IsMenuRevealHeld()
    local test = REVEAL_KEYS[(self.settings and self.settings.menuRevealKey) or "SHIFT"]
    return (test and test()) and true or false
end

function GM:MenuHidesApply(anchor)
    if not anchor or self.remoteItemsOverride then return false end
    if self:IsCharSheetAnchor(anchor) then return false end
    local n = anchor.GetName and anchor:GetName() or ""
    return not n:match("^WRGearSetSlot")
end

-- "itemID:enchantID:suffixID" from an item link.
function GM:MenuItemKey(link)
    if type(link) ~= "string" then return nil end
    local str = link:match("item:([%-%d:]+)")
    if not str then return nil end
    local f, i = {}, 0
    for part in (str .. ":"):gmatch("([^:]*):") do
        i = i + 1
        f[i] = part
        if i >= 7 then break end
    end
    local id = tonumber(f[1])
    if not id then return nil end
    local ench = tonumber(f[2]) or 0
    local suffix = tonumber(f[7]) or 0
    return id .. ":" .. ench .. ":" .. suffix, id
end

-- A bare item ID key (the first version of this) still hides every copy.
function GM:IsMenuItemHidden(link)
    local t = self.settings and self.settings.hiddenMenuItems
    if not t then return false end
    local key, id = self:MenuItemKey(link)
    return ((key and t[key]) or (id and t[id])) and true or false
end

function GM:IsMenuSetHidden(name)
    local t = self.settings and self.settings.hiddenMenuSets
    return (t and name and t[name]) and true or false
end

-- key: a MenuItemKey string (or an old bare item ID).
function GM:SetMenuItemHidden(key, hidden)
    if not key then return end
    if type(self.settings.hiddenMenuItems) ~= "table" then self.settings.hiddenMenuItems = {} end
    local t = self.settings.hiddenMenuItems
    t[key] = hidden and true or nil
    -- showing one copy again also lifts an old hide-every-copy entry
    if not hidden and type(key) == "string" then
        local id = tonumber(key:match("^(%d+)"))
        if id then t[id] = nil end
    end
    self:SaveSettings()
end

function GM:SetMenuSetHidden(name, hidden)
    if not name then return end
    if type(self.settings.hiddenMenuSets) ~= "table" then self.settings.hiddenMenuSets = {} end
    self.settings.hiddenMenuSets[name] = hidden and true or nil
    self:SaveSettings()
end

-- Redraw the open menu in place (ShowMenu skips a slot that is already up).
function GM:RefreshOpenMenu()
    local slot, anchor = self.currentMenuSlot, self.currentMenuAnchor
    if not (slot and anchor and self.menuFrame and self.menuFrame:IsShown()) then return end
    self.currentMenuSlot = nil
    self:ShowMenu(slot, anchor)
end

local REVEAL_LABEL = { SHIFT = "Shift", CTRL = "Ctrl", ALT = "Alt" }
function GM:MenuRevealKeyLabel()
    return REVEAL_LABEL[(self.settings and self.settings.menuRevealKey) or "SHIFT"] or "Shift"
end

-- What to press on a faded entry: the hide click plus the held reveal key.
function GM:MenuUnhideComboLabel()
    local k = (self.settings and self.settings.menuRevealKey) or "SHIFT"
    if k == "CTRL" then return "Ctrl+Right-click" end
    return "Ctrl+" .. self:MenuRevealKeyLabel() .. "+Right-click"
end

-- The tooltip lines every dockable menu entry carries. countOnly: just
-- the "N hidden here" line (the empty-slot tile cannot be hidden).
function GM:AddMenuHideTooltip(btn, countOnly)
    if not self:MenuHidesApply(self.currentMenuAnchor) then return end
    if countOnly then
        local n = self.menuHiddenCount or 0
        if n > 0 then
            GameTooltip:AddLine(string.format(RCL["%d hidden here: hold |cFFFFFF00%s|r to see them, then |cFFFFFF00%s|r one to bring it back"],
                n, self:MenuRevealKeyLabel(), self:MenuUnhideComboLabel()), 0.6, 0.6, 0.6, true)
        end
        return
    end
    if btn.isHiddenEntry then
        GameTooltip:AddLine("|cFFFFFF00" .. self:MenuUnhideComboLabel() .. "|r" .. RCL[" to show it in this menu again"], 0.8, 0.8, 0.8)
    else
        GameTooltip:AddLine(RCL["|cFFFFFF00Ctrl+Right-click|r to hide it from this menu"], 0.8, 0.8, 0.8)
        local n = self.menuHiddenCount or 0
        if n > 0 then
            GameTooltip:AddLine(string.format(RCL["%d hidden here: hold |cFFFFFF00%s|r to see them, then |cFFFFFF00%s|r one to bring it back"],
                n, self:MenuRevealKeyLabel(), self:MenuUnhideComboLabel()), 0.6, 0.6, 0.6, true)
        end
    end
end

-- Returns true when the click was a hide/unhide.
local hideHintShown = false
function GM:ToggleMenuEntryHidden(btn)
    if btn.setName then
        local now = not self:IsMenuSetHidden(btn.setName)
        self:SetMenuSetHidden(btn.setName, now)
    elseif btn.itemData and not btn.itemData.isEmpty and btn.itemData.itemLink then
        local key = self:MenuItemKey(btn.itemData.itemLink)
        if not key then return false end
        self:SetMenuItemHidden(key, not self:IsMenuItemHidden(btn.itemData.itemLink))
    else
        return false
    end
    if not hideHintShown then
        hideHintShown = true
        self:Print(string.format(RCL["Hidden from this menu. To bring it back: hold %s over the menu so hidden ones show faded, then %s it. Or use Gear Manager > Dockable & Macros."],
            self:MenuRevealKeyLabel(), self:MenuUnhideComboLabel()))
    end
    GameTooltip:Hide()
    self:RefreshOpenMenu()
    return true
end

-- One line on the menu's far side from its button whenever something is
-- hidden here. Tooltips are off by default, so the menu itself says it.
function GM:UpdateMenuHint()
    local menu = self.menuFrame
    if not menu then return end
    local n = self.menuHiddenCount or 0
    if not self:MenuHidesApply(self.currentMenuAnchor) or n == 0 then
        if menu.hint then menu.hint:Hide() end
        return
    end
    if not menu.hint then
        local h = CreateFrame("Frame", nil, menu)
        h.bg = h:CreateTexture(nil, "BACKGROUND")
        h.bg:SetAllPoints()
        h.bg:SetTexture(RC.UI.FLAT)
        local bg = RC:GetColor("gearManager", "frameBackground")
        h.bg:SetVertexColor(bg.r, bg.g, bg.b, bg.a or 0.95)
        h.borders = RC.UI:CreateSimpleBorder(h, 1)
        RC.UI:UpdateBorderColor(h.borders, RC:GetColor("gearManager", "frameBorder"))
        h.text = RC:CreateFontString(h, "OVERLAY", nil, 9)
        h.text:SetPoint("TOPLEFT", 4, -3)
        h.text:SetPoint("TOPRIGHT", -4, -3)
        h.text:SetJustifyH("CENTER")
        h.text:SetWordWrap(true)
        menu.hint = h
    end
    local h = menu.hint
    local gray = RC:GetColor("text", "disabled")
    h.text:SetTextColor(gray.r, gray.g, gray.b)
    if self.menuRevealShown then
        h.text:SetText(string.format(RCL["%s a faded one to show it again"], self:MenuUnhideComboLabel()))
    else
        h.text:SetText(string.format(RCL["%d hidden - hold %s to see"], n, self:MenuRevealKeyLabel()))
    end
    local w = math.max(menu:GetWidth(), 110)
    h:SetWidth(w)
    h.text:SetWidth(w - 8)
    h:SetHeight((h.text:GetStringHeight() or 10) + 6)
    h:ClearAllPoints()
    local point = menu:GetPoint(1)
    if point == "BOTTOM" then
        h:SetPoint("BOTTOM", menu, "TOP", 0, -1)
    else
        h:SetPoint("TOP", menu, "BOTTOM", 0, 1)
    end
    h:Show()
end

-- Faded look for a hidden entry the reveal key is showing.
local function StyleHiddenTile(btn, hidden)
    btn.isHiddenEntry = hidden or nil
    if hidden and btn.icon then
        btn.icon:SetDesaturated(true)
        btn.icon:SetVertexColor(0.6, 0.6, 0.6, 0.55)
    end
    if btn.nameText then btn.nameText:SetAlpha(hidden and 0.55 or 1) end
end

-- A swap is a round trip to the server: a flyout opened before it lands
-- would list the items where they were. While a flyout is up, gear and bag
-- changes (and items unlocking once a move lands) redraw it, coalesced.
local function QueueMenuRefresh()
    if GM._menuRefreshPending then return end
    GM._menuRefreshPending = true
    C_Timer.After(0.05, function()
        GM._menuRefreshPending = nil
        GM:RefreshOpenMenu()
    end)
end

function GM:CreateMenuFrame()
    if self.menuFrame then return self.menuFrame end

    local menu = CreateFrame("Frame", "WRGearMenu", UIParent)
    menu:SetSize(100, 100)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetFrameLevel(1000)
    menu:EnableMouse(true)
    menu:Hide()

    -- Flat panel fill and a 1px edge behind the tile grid, so a row that
    -- is not fully filled reads as a panel rather than floating tiles.
    local panelBg = RC:GetColor("gearManager", "frameBackground")
    menu.bg = menu:CreateTexture(nil, "BACKGROUND", nil, -8)
    menu.bg:SetAllPoints()
    menu.bg:SetTexture(RC.UI.FLAT)
    menu.bg:SetVertexColor(panelBg.r, panelBg.g, panelBg.b, panelBg.a or 0.95)

    menu.borders = RC.UI:CreateSimpleBorder(menu, 1)
    RC.UI:UpdateBorderColor(menu.borders, RC:GetColor("gearManager", "frameBorder"))

    menu.autoHideTimer = nil
    menu.cooldownUpdateTimer = nil

    menu:SetScript("OnEnter", function()
        GM:CancelHideTimer()
        if menu.fadeTimer then
            menu.fadeTimer:Cancel()
            menu.fadeTimer = nil
        end
        menu:SetAlpha(1)
    end)

    -- No OnLeave handler: hiding is driven by the notHoveredCount poll in
    -- the OnUpdate installed by OnShow below.

    -- Holding or releasing the reveal key redraws the open menu; so does
    -- gear landing in a slot or an item unlocking after a move.
    menu:SetScript("OnEvent", function(_, event)
        if event == "MODIFIER_STATE_CHANGED" then
            if GM:MenuHidesApply(GM.currentMenuAnchor)
               and GM:IsMenuRevealHeld() ~= (GM.menuRevealShown or false) then
                GM:RefreshOpenMenu()
            end
        else
            QueueMenuRefresh()
        end
    end)

    menu:SetScript("OnShow", function()
        menu:RegisterEvent("MODIFIER_STATE_CHANGED")
        menu:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
        menu:RegisterEvent("ITEM_LOCK_CHANGED")
        if RC.Bags then RC.Bags:OnChange("gearMenu", QueueMenuRefresh) end
        GM:StartMenuCooldownUpdates()

        menu.notHoveredCount = 0
        menu.lastHoverCheckTime = GetTime()

        menu:SetScript("OnUpdate", function(self, elapsed)
            local now = GetTime()

            if (now - (self.lastHoverCheckTime or 0)) < 0.1 then
                return
            end
            self.lastHoverCheckTime = now

            if GM.currentMenuAnchor then
                if GM:IsCharSheetAnchor(GM.currentMenuAnchor) then
                    if not CharacterFrame or not CharacterFrame:IsShown() then
                        GM:HideMenu()
                        return
                    end
                end
                if not GM.currentMenuAnchor:IsShown() then
                    GM:HideMenu()
                    return
                end
            end

            local mouseOver = GM:IsMouseOverMenuSystem()

            if not mouseOver then
                self.notHoveredCount = (self.notHoveredCount or 0) + 1
                if self.notHoveredCount >= 3 then
                    GM:HideMenu()
                    return
                end
            else
                self.notHoveredCount = 0
            end
        end)
    end)

    menu:SetScript("OnHide", function()
        menu:UnregisterEvent("MODIFIER_STATE_CHANGED")
        menu:UnregisterEvent("PLAYER_EQUIPMENT_CHANGED")
        menu:UnregisterEvent("ITEM_LOCK_CHANGED")
        if RC.Bags then RC.Bags:OnChange("gearMenu", nil) end
        GM:StopMenuCooldownUpdates()
        menu:SetScript("OnUpdate", nil)
        if menu.fadeTimer then
            menu.fadeTimer:Cancel()
            menu.fadeTimer = nil
        end
        menu:SetAlpha(1)
    end)

    self.menuFrame = menu
    self.menuButtons = {}
    return menu
end

-- Panel colours (Appearance > Colors, Gear Manager) on every show.
function GM:StyleMenuFrame(menu)
    local panelBg = RC:GetColor("gearManager", "frameBackground")
    menu.bg:SetVertexColor(panelBg.r, panelBg.g, panelBg.b, panelBg.a or 0.95)
    RC.UI:UpdateBorderColor(menu.borders, RC:GetColor("gearManager", "frameBorder"))
end

-- Shows the menu with its "When a menu opens" animation (none unless
-- picked); a menu already up just stays.
function GM:ShowMenuFrame(menu)
    self:StyleMenuFrame(menu)
    if menu:IsShown() or not RC.Motion then
        menu:Show()
        return
    end
    RC.Motion.Show(menu, RC.Motion.Normalize(self:Look().menuAnim, GM.MENU_ANIM))
end

function GM:ShowMenu(slot, anchor)
    local menu = self:CreateMenuFrame()
    -- re-anchoring under a running entrance would be undone when it ends
    if RC.Motion and RC.Motion.IsPlaying(menu) then RC.Motion.Stop(menu) end

    self:CancelHideTimer()

    if menu.fadeTimer then
        menu.fadeTimer:Cancel()
        menu.fadeTimer = nil
    end

    menu:SetAlpha(1)

    if menu:IsShown() and self.currentMenuSlot == slot then
        return
    end

    self.currentMenuSlot = slot
    self.currentMenuAnchor = anchor

    for _, btn in ipairs(self.menuButtons) do
        btn:Hide()
        btn.itemData = nil
        btn.setName = nil
    end

    local hides = self:MenuHidesApply(anchor)
    local reveal = hides and self:IsMenuRevealHeld()
    self.menuRevealShown = reveal

    if slot == 999 then
        local setNames = self:GetSetNames()
        self.menuHiddenCount = 0
        if hides then
            local kept = {}
            for _, n in ipairs(setNames) do
                if self:IsMenuSetHidden(n) then
                    self.menuHiddenCount = self.menuHiddenCount + 1
                    if reveal then kept[#kept + 1] = n end
                else
                    kept[#kept + 1] = n
                end
            end
            setNames = kept
        end
        if #setNames == 0 then
            self:HideMenu()
            return
        end

        for _, btn in ipairs(self.menuButtons) do
            btn:Hide()
        end

        local cols = math.min(3, #setNames)
        local rows = math.ceil(#setNames / cols)
        local btnSize = self:GetButtonUnitSize()

        menu:SetSize(cols * btnSize, rows * btnSize)

        for i, setName in ipairs(setNames) do
            local btn = self:GetOrCreateMenuButton(i)
            btn:SetSize(btnSize, btnSize)

            local col = (i - 1) % cols
            local row = math.floor((i - 1) / cols)
            btn:SetPoint("TOPLEFT", menu, "TOPLEFT", col * btnSize, -row * btnSize)

            if btn.icon then
                local set = self.sets[setName]
                if set and set.icon then
                    btn.icon:SetTexture(set.icon)
                    btn.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
                else
                    btn.icon:SetTexture("Interface\\Icons\\INV_Chest_Plate16")
                    btn.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
                end

                btn.icon:SetDesaturated(false)
                btn.icon:SetVertexColor(1, 1, 1, 1)
                btn.icon:Show()
            end

            if btn.nameText then
                if self.settings.showMenuNames ~= false then
                    TruncateToWidth(btn.nameText, setName, self:NameWidth(btn))

                    if self:IsSetComplete(setName) then
                        btn.nameText:SetTextColor(C.white[1], C.white[2], C.white[3], C.white[4])
                    else
                        btn.nameText:SetTextColor(C.red[1], C.red[2], C.red[3], C.red[4])
                    end
                    btn.nameText:Show()
                else
                    btn.nameText:Hide()
                end
            end

            btn.setName = setName
            btn.itemData = nil
            StyleHiddenTile(btn, hides and self:IsMenuSetHidden(setName))
            btn:Show()
        end

        menu:ClearAllPoints()

        local anchorTop = anchor:GetTop()
        local anchorBottom = anchor:GetBottom()
        local screenHeight = UIParent:GetHeight()

        if anchorTop and (screenHeight - anchorTop) > 100 then
            menu:SetPoint("BOTTOM", anchor, "TOP", 0, 2)
        elseif anchorBottom and anchorBottom > 100 then
            menu:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
        else
            menu:SetPoint("LEFT", anchor, "RIGHT", 2, 0)
        end

        menu:SetFrameStrata("TOOLTIP")
        self:ShowMenuFrame(menu)
        menu.showTime = GetTime()
        self:UpdateMenuHint()

        return
    end

    local items = self:GetItemsForSlot(slot)

    local emptyTexture = RC:GetSlotEmptyTexture(self.slotInfo[slot].name)

    self:DebugPrint("Empty slot texture for slot " .. slot .. ": " .. tostring(emptyTexture))

    local emptySlotItem = {
        texture = emptyTexture or "Interface\\Icons\\INV_Misc_QuestionMark",
        itemLink = nil,
        equipped = false,
        bag = nil,
        slot = nil,
        isEmpty = true
    }
    table.insert(items, 1, emptySlotItem)

    self.menuHiddenCount = 0
    if hides then
        local kept = {}
        for _, it in ipairs(items) do
            if not it.isEmpty and self:IsMenuItemHidden(it.itemLink) then
                self.menuHiddenCount = self.menuHiddenCount + 1
                if reveal then kept[#kept + 1] = it end
            else
                kept[#kept + 1] = it
            end
        end
        items = kept
    end

    for _, btn in ipairs(self.menuButtons) do
        btn:Hide()
    end

    local cols = math.min(3, math.max(1, #items))
    local rows = math.ceil(#items / cols)
    local btnSize = self:GetButtonUnitSize()
    local padding = 0

    menu:SetSize(cols * btnSize, rows * btnSize)

    for i, itemData in ipairs(items) do
        local btn = self:GetOrCreateMenuButton(i)
        btn:SetSize(btnSize, btnSize)

        local col = (i - 1) % cols
        local row = math.floor((i - 1) / cols)
        btn:SetPoint("TOPLEFT", menu, "TOPLEFT", col * btnSize, -row * btnSize)

        if btn.icon then
            btn.icon:SetTexture(itemData.texture)
            btn.icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

            if itemData.isEmpty then
                btn.icon:SetDesaturated(true)
                btn.icon:SetVertexColor(1, 1, 0.4, 1)

                if not btn.emptyBg then
                    btn.emptyBg = btn:CreateTexture(nil, "BACKGROUND", nil, -1)
                    btn.emptyBg:SetAllPoints()
                    btn.emptyBg:SetColorTexture(C.brownHint[1], C.brownHint[2], C.brownHint[3], C.brownHint[4])
                end
                btn.emptyBg:Show()
            else
                btn.icon:SetDesaturated(false)
                btn.icon:SetVertexColor(1, 1, 1, 1)

                if btn.emptyBg then
                    btn.emptyBg:Hide()
                end
            end
            btn.icon:Show()
        end

        btn.itemData = itemData
        btn.setName = nil

        if btn.nameText then
            local isCharacterSheet = self:IsCharSheetAnchor(anchor)
            local showName = false

            if isCharacterSheet then
                showName = self.settings.showCharPaneNames ~= false
            else
                showName = self.settings.showMenuNames ~= false
            end

            if showName and itemData.itemLink and not itemData.isEmpty then
                local itemName = GetItemInfo(itemData.itemLink)
                if itemName then
                    local abbrevName = RC.GetItemAbbreviation and RC:GetItemAbbreviation(itemName) or itemName:sub(1, 5) .. "."
                    btn.nameText:SetText(abbrevName)
                    btn.nameText:SetTextColor(C.white[1], C.white[2], C.white[3], C.white[4])
                    btn.nameText:Show()
                else
                    btn.nameText:Hide()
                end
            else
                btn.nameText:Hide()
            end
        end

        StyleHiddenTile(btn, hides and not itemData.isEmpty and self:IsMenuItemHidden(itemData.itemLink))
        btn:Show()
    end

    menu:ClearAllPoints()

    local anchorName = anchor:GetName() or ""
    local isCharacterSheet = self:IsCharSheetAnchor(anchor)
    local isGearSetEditor = string.match(anchorName, "^WRGearSetSlot")

    -- Ammo/weapon/ranged slots sit at the paper doll's bottom edge, so
    -- their flyout has to grow downward instead of sideways like the rest.
    local growDownSlots = {[0] = true, [16] = true, [17] = true, [18] = true}

    if isCharacterSheet or isGearSetEditor then
        if growDownSlots[slot] then
            menu:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
        else
            menu:SetPoint("LEFT", anchor, "RIGHT", 2, 0)
        end
    else
        local anchorTop = anchor:GetTop()
        local anchorBottom = anchor:GetBottom()
        local screenHeight = UIParent:GetHeight()

        if anchorTop and (screenHeight - anchorTop) > 100 then
            menu:SetPoint("BOTTOM", anchor, "TOP", 0, 2)
        elseif anchorBottom and anchorBottom > 100 then
            menu:SetPoint("TOP", anchor, "BOTTOM", 0, -2)
        else
            menu:SetPoint("LEFT", anchor, "RIGHT", 2, 0)
        end
    end

    menu:SetFrameStrata("TOOLTIP")
    self:ShowMenuFrame(menu)
    menu.showTime = GetTime()
    self:UpdateMenuHint()

    if menu.autoHideTimer then
        menu.autoHideTimer:Cancel()
        menu.autoHideTimer = nil
    end
end

-- A hover-menu tile's parts (icon, timer, name, the two rings, hover
-- lift, pushed shade): the live menu and the settings preview build
-- their tiles with this. name: global prefix for a live tile, or nil.
function GM:BuildMenuTile(btn, buttonName)
    local function N(suffix) return buttonName and (buttonName .. suffix) or nil end
    local iconBg = btn:CreateTexture(N("IconBg"), "BACKGROUND", nil, -8)
    iconBg:SetAllPoints(btn)
    iconBg:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
    btn.iconBg = iconBg

    local icon = btn:CreateTexture(N("Icon"), "BACKGROUND")
    icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetVertexColor(1, 1, 1, 1)
    btn.icon = icon

    local cdText = RC:CreateFontString(btn, "OVERLAY", nil, 14)
    cdText:SetPoint("CENTER", 0, 0)
    cdText:SetTextColor(1, 1, 0, 1)
    cdText:SetShadowOffset(2, -2)
    cdText:SetShadowColor(0, 0, 0, 1)
    cdText:Hide()
    btn.cdText = cdText

    local nameText = RC:CreateFontString(btn, "OVERLAY", nil, 8)
    nameText:SetPoint("BOTTOM", 0, 2)
    nameText:SetWidth(34)
    nameText:SetHeight(10)
    nameText:SetTextColor(1, 1, 1, 1)
    nameText:SetJustifyH("CENTER")
    nameText:SetJustifyV("BOTTOM")
    nameText:SetWordWrap(false)
    nameText:SetShadowOffset(1, -1)
    nameText:SetShadowColor(0, 0, 0, 1)
    nameText:Hide()
    btn.nameText = nameText

    -- Same two 1px rings the gear buttons use (GM_Buttons.lua), built
    -- by the core helper; explicit sublevels keep the hover ring above
    -- the base ring rather than relying on creation order.
    local borders = RC.UI:CreateSimpleBorder(btn, 1, 0)
    btn.borders = borders

    local hoverBorder = RC.UI:CreateSimpleBorder(btn, 1, 2)
    RC.UI:UpdateBorderColor(hoverBorder, GetGMSlotHoverBorder())
    for _, side in pairs(hoverBorder) do
        side:Hide()
    end
    btn.hoverBorder = hoverBorder

    -- Same additive lift (white 0.05) and pushed shade (black 0.35)
    -- as the framework's styled buttons, so tiles and buttons agree.
    local lift = RC.UI.C.whiteHint
    local hoverHighlight = btn:CreateTexture(nil, "ARTWORK", nil, 7)
    hoverHighlight:SetAllPoints()
    hoverHighlight:SetColorTexture(lift[1], lift[2], lift[3], lift[4])
    hoverHighlight:SetBlendMode("ADD")
    hoverHighlight:Hide()
    btn.hoverHighlight = hoverHighlight

    local pushed = btn:CreateTexture(nil, "ARTWORK", nil, 6)
    pushed:SetAllPoints()
    pushed:SetColorTexture(0, 0, 0, 0.35)
    btn:SetPushedTexture(pushed)

    btn:SetPushedTextOffset(1, -1)

    btn.isMenuTile = true
    GM:StyleButtonFace(btn)
    return btn
end

function GM:GetOrCreateMenuButton(index)
    local buttonName = "WRGearMenuButton" .. index
    local btn = self.menuButtons[index]

    if not btn then
        btn = CreateFrame("Button", buttonName, self.menuFrame)
        btn:SetSize(36, 36)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

        GM:BuildMenuTile(btn, buttonName)

        btn:SetScript("OnClick", function(self, button)
            if button == "RightButton" and IsControlKeyDown() and not self.editorGearData
               and GM:MenuHidesApply(GM.currentMenuAnchor) then
                if GM:ToggleMenuEntryHidden(self) then return end
            end
            if self.setName then
                if button == "LeftButton" and IsAltKeyDown() then
                    GM:PinSet(self.setName)
                    GM:HideMenu()
                    return
                end

                if button == "RightButton" then return end

                if InCombatLockdown() then
                    if RC and RC.QueueGearSwap then
                        RC:QueueGearSwap(self.setName)
                        GM:HideMenu()
                    else
                        GM:Print(RCL["Cannot equip sets in combat"])
                    end
                    return
                end
                GM:EquipSet(self.setName)
                GM:HideMenu()
                return
            end

            if self.editorGearData then
                local itemData = self.itemData
                if itemData then
                    if itemData.isUnequip then
                        self.editorGearData[self.editorSlot] = 0
                        if self.editorUpdateCallback then
                            self.editorUpdateCallback()
                        end
                        GM:DebugPrint("Set slot " .. self.editorSlot .. " to unequip (0)")
                        GM:HideMenu()
                        return
                    end

                    if itemData.isRemove then
                        self.editorGearData[self.editorSlot] = nil
                        if self.editorUpdateCallback then
                            self.editorUpdateCallback()
                        end
                        GM:DebugPrint("Removed slot " .. self.editorSlot .. " from set via menu")
                        GM:HideMenu()
                        return
                    end

                    if itemData.itemLink then
                        self.editorGearData[self.editorSlot] = itemData.itemLink
                        if self.editorUpdateCallback then
                            self.editorUpdateCallback()
                        end
                        GM:DebugPrint("Set slot " .. self.editorSlot .. " to item: " .. (itemData.name or "unknown"))
                        GM:HideMenu()
                        return
                    end
                end
            end

            local itemData = self.itemData

            local inConfigMode = GM.currentMenuAnchor and
                                 GM.currentMenuAnchor:GetName() and
                                 string.match(GM.currentMenuAnchor:GetName(), "^WRGearSetSlot")

            if button == "LeftButton" and IsAltKeyDown() and not inConfigMode
               and itemData and not itemData.isEmpty
               and (itemData.link or itemData.itemLink) then
                GM:PinItem(itemData.link or itemData.itemLink, GM.currentMenuSlot)
                GM:HideMenu()
                return
            end

            if inConfigMode then
                if itemData then
                    if itemData.isEmpty then
                        GM.setEditorInv[GM.currentMenuSlot].itemLink = 0
                        GM.setEditorInv[GM.currentMenuSlot].selected = true

                        local slotButton = GM.currentSlotButton or _G["WRGearSetSlot" .. GM.currentMenuSlot]
                        if slotButton and slotButton.icon then
                            local texture = RC:GetSlotEmptyTexture(GM.slotInfo[GM.currentMenuSlot].name)
                            slotButton.icon:SetTexture(texture)
                            slotButton.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                            slotButton.icon:SetVertexColor(0.7, 0.7, 0.7, 1)
                            slotButton.icon:SetDesaturated(true)
                        end
                    elseif itemData.itemLink then
                        GM.setEditorInv[GM.currentMenuSlot].itemLink = itemData.itemLink
                        GM.setEditorInv[GM.currentMenuSlot].selected = true

                        local texture = itemData.texture
                        if not texture then
                            texture = GetItemIcon(itemData.itemLink)
                        end
                        if not texture then
                            texture = select(10, GetItemInfo(itemData.itemLink))
                        end
                        if not texture then
                            local equippedLink = GetInventoryItemLink("player", GM.currentMenuSlot)
                            if equippedLink == itemData.itemLink then
                                texture = GetInventoryItemTexture("player", GM.currentMenuSlot)
                            end
                        end

                        GM.setEditorInv[GM.currentMenuSlot].texture = texture

                        if GM.currentEditingSet and GM.sets[GM.currentEditingSet] then
                            local set = GM.sets[GM.currentEditingSet]
                            if not set.textures then set.textures = {} end
                            if texture then
                                set.textures[GM.currentMenuSlot] = texture
                            end
                        end

                        local slotButton = GM.currentSlotButton or _G["WRGearSetSlot" .. GM.currentMenuSlot]
                        if slotButton and slotButton.icon then
                            if texture then
                                slotButton.icon:SetTexture(texture)
                                slotButton.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                                slotButton.icon:SetVertexColor(1, 1, 1, 1)
                                slotButton.icon:SetDesaturated(false)
                            end
                        end
                    end

                    if RC.SaveCurrentGearSetEditorState then
                        RC:SaveCurrentGearSetEditorState()
                    end

                    C_Timer.After(0.05, function()
                        if GM.currentMenuAnchor and GM.currentMenuSlot then
                            GM:ShowMenu(GM.currentMenuSlot, GM.currentMenuAnchor)
                        end
                    end)
                end
            else
                if itemData and itemData.isEmpty and InCombatLockdown() then
                    -- one queued unequip (it finds a free bag when it runs),
                    -- replacing any pick still waiting for this slot
                    RC:DropQueuedPicksForSlot(GM.currentMenuSlot)
                    GM:SafeUnequipToSlot(GM.currentMenuSlot)
                    GM:HideMenu()
                elseif itemData and itemData.isEmpty then
                    local placed = false
                    for bag = 0, 4 do
                        if not placed then
                            for bagSlot = 1, C_Container.GetContainerNumSlots(bag) do
                                local bagItemLink = C_Container.GetContainerItemLink(bag, bagSlot)
                                if not bagItemLink then
                                    placed = GM:SafeUnequipToSlot(GM.currentMenuSlot, bag, bagSlot)
                                    if placed then
                                        break
                                    end
                                end
                            end
                        end
                    end
                    GM:HideMenu()

                    C_Timer.After(0.1, function()
                        if GM.currentMenuAnchor and GM.currentMenuSlot and
                           GM:IsCharSheetAnchor(GM.currentMenuAnchor) then
                            GM:ShowMenu(GM.currentMenuSlot, GM.currentMenuAnchor)
                        end
                    end)
                elseif itemData and itemData.pairedSlot then
                    local targetSlot = GM.currentMenuSlot
                    if (GM.settings and GM.settings.trinketDockSplitClick)
                       and (GM.currentMenuSlot == 13 or GM.currentMenuSlot == 14)
                       and not GM:IsCharSheetAnchor(GM.currentMenuAnchor) then
                        targetSlot = (button == "RightButton") and 14 or 13
                    end
                    -- the two slots trade items (queued if combat blocks it)
                    if targetSlot ~= itemData.pairedSlot then
                        if InCombatLockdown() then
                            RC:DropQueuedPicksForSlot(itemData.pairedSlot, targetSlot)
                        end
                        GM:SafeSwapSlotToSlot(itemData.pairedSlot, targetSlot)
                    end
                    GM:HideMenu()

                    C_Timer.After(0.1, function()
                        if GM.currentMenuAnchor and GM.currentMenuSlot and
                           GM:IsCharSheetAnchor(GM.currentMenuAnchor) then
                            GM:ShowMenu(GM.currentMenuSlot, GM.currentMenuAnchor)
                        end
                    end)
                elseif itemData and not itemData.equipped and itemData.bag and itemData.slot then
                    local targetSlot = GM.currentMenuSlot
                    -- When enabled, a docked (non-character-sheet) trinket
                    -- flyout sends left-clicks to slot 13 and right-clicks
                    -- to slot 14 instead of always targeting the hovered slot.
                    if (GM.settings and GM.settings.trinketDockSplitClick)
                       and (GM.currentMenuSlot == 13 or GM.currentMenuSlot == 14) then
                        if not GM:IsCharSheetAnchor(GM.currentMenuAnchor) then
                            targetSlot = (button == "RightButton") and 14 or 13
                        end
                    end
                    -- in combat it queues, replacing any pick (here or on
                    -- the trinket bar) still waiting for that slot
                    if InCombatLockdown() then RC:DropQueuedPicksForSlot(targetSlot) end
                    GM:SafeSwapBagToSlot(itemData.bag, itemData.slot, targetSlot, itemData.link)
                    GM:HideMenu()

                    C_Timer.After(0.1, function()
                        if GM.currentMenuAnchor and GM.currentMenuSlot and
                           GM:IsCharSheetAnchor(GM.currentMenuAnchor) then
                            GM:ShowMenu(GM.currentMenuSlot, GM.currentMenuAnchor)
                        end
                    end)
                end
            end
        end)

        btn:SetScript("OnEnter", function(self)
            if self.hoverBorder then
                self.hoverBorder.top:Show()
                self.hoverBorder.bottom:Show()
                self.hoverBorder.left:Show()
                self.hoverBorder.right:Show()
            end

            if self.hoverHighlight then
                self.hoverHighlight:Show()
            end

            GameTooltip:Hide()
            GM:CancelHideTimer()

            C_Timer.After(0.05, function()
                if not self:IsMouseOver() then return end
                if not GM:TooltipsAllowed() then return end

                if self.setName then
                    GM:AnchorTooltip(self)
                    GameTooltip:SetText((RC.GetGearSetIconText and (RC:GetGearSetIconText(self.setName, 14) .. " ") or "")
                        .. self.setName, 1, 1, 1)
                    GameTooltip:AddLine(" ")

                    local set = GM.sets[self.setName]
                    if set and set.equip then
                        local equippedCount = {}
                        for s = 0, 19 do
                            local eLink = GetInventoryItemLink("player", s)
                            local eId = eLink and GM:GetItemID(eLink)
                            if eId then equippedCount[eId] = (equippedCount[eId] or 0) + 1 end
                        end
                        local itemCount, anyMissing = 0, false
                        for slot, itemLink in pairs(set.equip) do
                            if itemLink and itemLink ~= 0 then
                                local itemName = GetItemInfo(itemLink)
                                if itemName then
                                    local id = GM:GetItemID(itemLink)
                                    local have = id and ((GetItemCount(id) or 0) + (equippedCount[id] or 0)) or 0
                                    if have >= 1 then
                                        GameTooltip:AddLine(GM.slotInfo[slot].real .. ": " .. itemName, 1, 1, 1)
                                    else
                                        GameTooltip:AddLine(GM.slotInfo[slot].real .. ": " .. itemName .. RCL[" (missing)"], C.red[1], C.red[2], C.red[3])
                                        anyMissing = true
                                    end
                                    itemCount = itemCount + 1
                                end
                            end
                        end
                        if itemCount == 0 then
                            GameTooltip:AddLine(RCL["(Empty set)"], 0.7, 0.7, 0.7)
                        elseif anyMissing or not GM:IsSetComplete(self.setName) then
                            GameTooltip:AddLine(" ")
                            GameTooltip:AddLine(RCL["Missing gear - can't fully equip this set"], C.red[1], C.red[2], C.red[3])
                        end
                    end

                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(RCL["|cFFFFFF00Click to equip|r"], 0.8, 0.8, 0.8)
                    GameTooltip:AddLine(RCL["|cFFFFFF00Alt+Click|r to pin this set as its own button on screen"], 0.8, 0.8, 0.8)
                    GM:AddMenuHideTooltip(self)
                    GameTooltip:Show()
                elseif self.itemData and self.itemData.isUnequip then
                    GM:AnchorTooltip(self)
                    GameTooltip:SetText(RCL["Unequip Slot"], 1, 1, 1)
                    GameTooltip:AddLine(RCL["Click to make this slot unequip when set is activated"], 0.8, 0.8, 0.8)
                    GameTooltip:Show()
                elseif self.itemData and self.itemData.isRemove then
                    GM:AnchorTooltip(self)
                    GameTooltip:SetText(RCL["Remove from Set"], 1, 0.5, 0.5)
                    GameTooltip:AddLine(RCL["Click to remove this slot from the gear set completely"], 0.8, 0.8, 0.8)
                    GameTooltip:Show()
                elseif self.itemData and self.itemData.isEmpty then
                    GM:AnchorTooltip(self)
                    GameTooltip:SetText(RCL["Unequip Slot"], 1, 1, 1)
                    GameTooltip:AddLine(RCL["Click to remove item from this slot"], 0.8, 0.8, 0.8)
                    GM:AddMenuHideTooltip(self, true)
                    GameTooltip:Show()
                elseif self.itemData and self.itemData.itemLink then
                    if GM:TooltipsAllowed() then
                        GM:AnchorTooltip(self)

                        if self.itemData.itemLink == 0 then
                            GameTooltip:SetText(RCL["Unequip Slot"], 1, 1, 1)
                            GameTooltip:AddLine(RCL["This slot will be unequipped"], 0.8, 0.8, 0.8)
                        elseif type(self.itemData.itemLink) == "string" then
                            GameTooltip:SetHyperlink(self.itemData.itemLink)

                            if self.itemData.equipped then
                                GameTooltip:AddLine(" ")
                                GameTooltip:AddLine(RCL["|cFF808080(Currently equipped)|r"], 0.7, 0.7, 0.7)
                            end

                            if not self.editorGearData
                                    and not ((GM.currentMenuAnchor and GM.currentMenuAnchor:GetName() or ""):match("^WRGearSetSlot")) then
                                GameTooltip:AddLine(" ")
                                GameTooltip:AddLine(RCL["|cFFFFFF00Alt+Click|r to pin this item as its own button on screen"], 0.8, 0.8, 0.8)
                                GM:AddMenuHideTooltip(self)
                            end
                        end

                        GameTooltip:Show()
                    end
                end
            end)
        end)

        btn:SetScript("OnLeave", function(self)
            if self.hoverBorder then
                self.hoverBorder.top:Hide()
                self.hoverBorder.bottom:Hide()
                self.hoverBorder.left:Hide()
                self.hoverBorder.right:Hide()
            end

            if self.hoverHighlight then
                self.hoverHighlight:Hide()
            end

            GameTooltip:Hide()
        end)

        self.menuButtons[index] = btn
    end

    return btn
end

function GM:HideMenu()
    self:CancelHideTimer()

    if self.menuShowTimer then
        self.menuShowTimer:Cancel()
        self.menuShowTimer = nil
    end

    if self.menuFrame then
        if self.menuFrame.fadeTimer then
            self.menuFrame.fadeTimer:Cancel()
            self.menuFrame.fadeTimer = nil
        end
        if self.menuFrame.safetyTimer then
            self.menuFrame.safetyTimer:Cancel()
            self.menuFrame.safetyTimer = nil
        end
        if RC.Motion then RC.Motion.Stop(self.menuFrame) end
        self.menuFrame:SetAlpha(1)
        self.menuFrame:Hide()

        if self.menuButtons then
            for _, btn in ipairs(self.menuButtons) do
                if btn then
                    btn:Hide()
                end
            end
        end
    end

    GameTooltip:Hide()

    self.currentMenuSlot = nil
    self.currentMenuAnchor = nil
end

function GM:UpdateMenuCooldowns()
    if not self.menuFrame or not self.menuFrame:IsShown() then
        return
    end

    for _, btn in ipairs(self.menuButtons) do
        if btn and btn:IsShown() and btn.cdText and btn.itemData and btn.itemData.itemLink then
            local itemID = self:GetItemID(btn.itemData.itemLink)
            if itemID then
                local start, duration
                if btn.itemData.invSlot and btn.itemData.invSlot >= 1 then
                    start, duration = Readycheck.PlainCD(GetInventoryItemCooldown("player", btn.itemData.invSlot))
                else
                    start, duration = RC:GetItemCooldownSafe(itemID)
                end
                if start and duration and duration > 0 then
                    local remaining = math.ceil(duration - (GetTime() - start))
                    if remaining > 0 and (not GM.settings or GM.settings.showCooldownTextMenus ~= false) then
                        if remaining >= 60 then
                            btn.cdText:SetText(math.ceil(remaining / 60) .. "m")
                        else
                            btn.cdText:SetText(remaining .. "s")
                        end
                        btn.cdText:Show()
                    else
                        btn.cdText:Hide()
                    end
                else
                    btn.cdText:Hide()
                end
            else
                btn.cdText:Hide()
            end
        end
    end
end

function GM:StartMenuCooldownUpdates()
    self:StopMenuCooldownUpdates()

    local function updateTick()
        if self.menuFrame and self.menuFrame:IsShown() then
            self:UpdateMenuCooldowns()
            self.menuFrame.cooldownUpdateTimer = C_Timer.NewTimer(0.5, updateTick)
        end
    end

    updateTick()
end

function GM:StopMenuCooldownUpdates()
    if self.menuFrame and self.menuFrame.cooldownUpdateTimer then
        self.menuFrame.cooldownUpdateTimer:Cancel()
        self.menuFrame.cooldownUpdateTimer = nil
    end
end

function GM:GetItemsForSlot(slot)
    if self.remoteItemsOverride then
        return self:GetRemoteItemsForSlot(slot)
    end

    local items = {}

    local equippedLink = GetInventoryItemLink("player", slot)
    local equippedID = self:GetItemID(equippedLink)

    local isCharacterSheet = self:IsCharSheetAnchor(self.currentMenuAnchor)

    local inGearSetEditor = (self.currentMenuAnchor and
                             self.currentMenuAnchor:GetName() and
                             string.match(self.currentMenuAnchor:GetName(), "^WRGearSetSlot"))

    if equippedLink then
        local name, _, quality, _, _, _, _, _, _, texture = GetItemInfo(equippedLink)
        if not texture then
            texture = GetInventoryItemTexture("player", slot)
        end

        local isInSet = false
        if inGearSetEditor and self.setEditorInv and self.setEditorInv[slot] then
            if self.setEditorInv[slot].itemLink == equippedLink and self.setEditorInv[slot].selected then
                isInSet = true
            end
        end

        table.insert(items, {
            itemLink = equippedLink,
            name = name or "Loading...",
            texture = texture or "Interface\\Icons\\INV_Misc_QuestionMark",
            quality = quality,
            equipped = (not inGearSetEditor) or isInSet,
        })
    end

    local _pairedMap = {[11]=12, [12]=11, [13]=14, [14]=13, [16]=17, [17]=16}
    local _pairedSlot = _pairedMap[slot]
    local _pairedShowID = nil
    if _pairedSlot then
        local pairedLink = GetInventoryItemLink("player", _pairedSlot)
        local pairedID   = pairedLink and self:GetItemID(pairedLink)
        -- locked = mid-swap: it is on its way out, so it waits for the
        -- redraw once the move lands
        if pairedLink and pairedID and not IsInventoryItemLocked(_pairedSlot) then
            local pName, _, pQuality, _, _, _, _, _, pEquipSlot, pTexture = GetItemInfo(pairedLink)
            if self:CanItemGoInSlot(pEquipSlot, slot) then
                if not pTexture then
                    pTexture = GetInventoryItemTexture("player", _pairedSlot)
                end
                table.insert(items, {
                    itemLink = pairedLink,
                    name     = pName or "Loading...",
                    texture  = pTexture or "Interface\\Icons\\INV_Misc_QuestionMark",
                    quality  = pQuality,
                    equipped = false,
                    -- worn in the other slot of the pair: a click moves it
                    -- across (the two swap)
                    pairedSlot = _pairedSlot,
                })
                _pairedShowID = pairedID
            end
        end
    end

    local equippedItems = {}

    local setItems = {}
    if inGearSetEditor and self.setEditorInv then
        for i = 0, 19 do
            if self.setEditorInv[i] and self.setEditorInv[i].selected and self.setEditorInv[i].itemLink then
                local itemID = self:GetItemID(self.setEditorInv[i].itemLink)
                if itemID then
                    setItems[itemID] = true
                end
            end
        end
    end

    for bag = 0, 4 do
        for bagSlot = 1, C_Container.GetContainerNumSlots(bag) do
            local itemLink = C_Container.GetContainerItemLink(bag, bagSlot)
            local itemInfo = itemLink and C_Container.GetContainerItemInfo(bag, bagSlot)
            -- a locked bag item is mid-move (just sent to a slot): left out
            -- until the redraw once the move lands
            if itemLink and not (itemInfo and itemInfo.isLocked) then
                local _, _, _, _, _, _, _, _, equipSlot, texture = GetItemInfo(itemLink)

                if not texture then
                    texture = GetItemIcon(itemLink)
                end

                -- IMPROVED: Use C_Container.GetContainerItemInfo as backup for texture
                if not texture and itemInfo then
                    texture = itemInfo.iconFileID
                end

                if self:CanItemGoInSlot(equipSlot, slot) then
                    local itemID = self:GetItemID(itemLink)
                    if not equippedItems[itemID] then
                        local name, _, quality = GetItemInfo(itemLink)

                        local isInCurrentSet = inGearSetEditor and setItems[itemID]

                        table.insert(items, {
                            itemLink = itemLink,
                            name = name or "Loading...",
                            texture = texture or "Interface\\Icons\\INV_Misc_QuestionMark",
                            quality = quality,
                            bag = bag,
                            slot = bagSlot,
                            equipped = isInCurrentSet,
                        })
                    end
                end
            end
        end
    end

    return items
end

-- Feeds the same flyout UI from another unit's inspected gear instead of
-- the player's own bags/equipment, set up by whatever populates
-- remoteItemsOverride/remoteEquippedBySlot (outside this file).
function GM:GetRemoteItemsForSlot(slot)
    local items = {}
    local override = self.remoteItemsOverride
    if not override then return items end

    local setEditorInv = self.setEditorInv

    local setItemIds = {}
    if setEditorInv then
        for i = 0, 19 do
            local s = setEditorInv[i]
            if s and s.selected and s.itemLink and type(s.itemLink) == "string" then
                local id = tonumber(s.itemLink:match("item:(%d+)"))
                if id then setItemIds[id] = true end
            end
        end
    end

    local thisSlotItem = setEditorInv and setEditorInv[slot]
    if thisSlotItem and thisSlotItem.selected and thisSlotItem.itemLink
            and type(thisSlotItem.itemLink) == "string" then
        local name = GetItemInfo(thisSlotItem.itemLink) or thisSlotItem.itemLink:match("item:(%d+)")
        items[#items+1] = {
            itemLink = thisSlotItem.itemLink,
            name     = name or "Loading...",
            texture  = thisSlotItem.texture or "Interface\\Icons\\INV_Misc_QuestionMark",
            equipped = true,
        }
    end

    local candidates = {}
    for _, item in ipairs(override) do
        if self:CanItemGoInSlot(item.equipLoc or "", slot) then
            local id = item.id
            local inThisSlot = thisSlotItem and thisSlotItem.selected
                and thisSlotItem.itemLink and type(thisSlotItem.itemLink) == "string"
                and tonumber(thisSlotItem.itemLink:match("item:(%d+)")) == id
            if not inThisSlot then
                candidates[#candidates+1] = {
                    itemLink = item.link or ("item:" .. id),
                    name     = item.name or ("item:" .. id),
                    texture  = item.icon or "Interface\\Icons\\INV_Misc_QuestionMark",
                    equipped = setItemIds[id] and true or false,
                }
            end
        end
    end
    table.sort(candidates, function(a,b) return (a.name or "") < (b.name or "") end)
    for _, c in ipairs(candidates) do items[#items+1] = c end

    return items
end

function GM:CanItemGoInSlot(equipSlot, invSlot)
    if not equipSlot then return false end

    local slotMap = {
        ["INVTYPE_HEAD"] = {1}, ["INVTYPE_NECK"] = {2}, ["INVTYPE_SHOULDER"] = {3},
        ["INVTYPE_BODY"] = {4}, ["INVTYPE_CHEST"] = {5}, ["INVTYPE_ROBE"] = {5},
        ["INVTYPE_WAIST"] = {6}, ["INVTYPE_LEGS"] = {7}, ["INVTYPE_FEET"] = {8},
        ["INVTYPE_WRIST"] = {9}, ["INVTYPE_HAND"] = {10}, ["INVTYPE_FINGER"] = {11, 12},
        ["INVTYPE_TRINKET"] = {13, 14}, ["INVTYPE_CLOAK"] = {15},
        ["INVTYPE_WEAPON"] = {16, 17}, ["INVTYPE_SHIELD"] = {17}, ["INVTYPE_2HWEAPON"] = {16},
        ["INVTYPE_WEAPONMAINHAND"] = {16}, ["INVTYPE_WEAPONOFFHAND"] = {17}, ["INVTYPE_HOLDABLE"] = {17},
        ["INVTYPE_RANGED"] = {18}, ["INVTYPE_RANGEDRIGHT"] = {18}, ["INVTYPE_THROWN"] = {18},
        ["INVTYPE_RELIC"] = {18}, ["INVTYPE_TABARD"] = {19}, ["INVTYPE_AMMO"] = {0},
    }

    local slots = slotMap[equipSlot]
    if not slots then return false end

    for _, s in ipairs(slots) do
        if s == invSlot then return true end
    end
    return false
end

function GM:UpdateButtonUseAction(slot, button)
    if slot == 999 then return end
    button = button or self.buttons[slot]
    if not button then return end
    if InCombatLockdown() then return end
    local info = self.slotInfo[slot]
    local invSlot = info and info.invSlot
    if invSlot and GetInventoryItemID("player", invSlot) then
        button:SetAttribute("type1", "item")
        button:SetAttribute("item1", invSlot)
        button:SetAttribute("type2", "item")
        button:SetAttribute("item2", invSlot)
    else
        button:SetAttribute("type1", nil)
        button:SetAttribute("item1", nil)
        button:SetAttribute("type2", nil)
        button:SetAttribute("item2", nil)
    end
end
