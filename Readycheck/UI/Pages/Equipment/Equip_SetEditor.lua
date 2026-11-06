------------------------------------------------------------------------
-- Readycheck - Equipment: Gear Set Slot Editor
-- Builds the 20-slot picker body shared by the inline set editor (local
-- and remote tabs in Equip_GMConfig.lua) and the full-page editor below.
-- A slot's itemLink of 0/"0"/"EMPTY" means explicit UNEQUIP; nil/absent
-- means "leave this slot alone" (not part of the set). Writes go to
-- GM.sets[setName] + RC.db.gearSets normally, or to GM.remoteSetBuffers
-- + GM.remoteEditCallbacks when editing a remote warrior's set.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_max, math_min = math.floor, math.max, math.min
local table_insert, table_sort = table.insert, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._seq = RC._seq or {}
local _seq = RC._seq
local C, TEXT = _seq.C, _seq.TEXT
    function RC:SaveCurrentGearSetEditorState()
        local GM = self.GearManager
        if not GM or not GM.currentEditingSet or not GM.setEditorInv then return end

        local setName = GM.currentEditingSet

        local newEquip = {}
        local newTextures = {}
        for i = 0, 19 do
            local s = GM.setEditorInv[i]
            if s and s.selected and s.itemLink then
                newEquip[i] = s.itemLink
                newTextures[i] = s.texture
            end
        end

        -- Remote buffer takes priority: while editing a remote warrior's set
        -- this must not touch GM.sets, which belongs to the local profile.
        local remoteBuf = GM.remoteSetBuffers and GM.remoteSetBuffers[setName]
        if remoteBuf then
            remoteBuf.equip    = newEquip
            remoteBuf.textures = newTextures
            local cb = GM.remoteEditCallbacks and GM.remoteEditCallbacks[setName]
            if cb then cb(setName, remoteBuf) end
            return
        end

        local setData = GM.sets[setName]
        if not setData then return end

        setData.equip    = newEquip
        setData.textures = newTextures
        if not self.db.gearSets then self.db.gearSets = {} end
        self.db.gearSets[setName] = setData
        self:SaveConfigurationToProfile()
    end

    function RC:BuildGearSetEditorBody(parent, yPos, setName, setData, frame, opts)
        opts = opts or {}
        local onSave    = opts.onSave    or function() end
        local onCancel  = opts.onCancel  or function() end
        local onRefresh = opts.onRefresh or function() end

        local GM = self.GearManager
        if not GM then return yPos end

        GM.editorStates = GM.editorStates or {}
        local editorState = GM.editorStates[setName]
        if not editorState then
            editorState = { inv = {} }
            GM.editorStates[setName] = editorState
        end
        local inv = editorState.inv

        for i = 0, 19 do
            if setData.equip and setData.equip[i] then
                inv[i] = {
                    selected = true,
                    itemLink = setData.equip[i],
                    texture = setData.textures and setData.textures[i]
                }
            else
                local remoteSlot = GM.remoteEquippedBySlot and GM.remoteEquippedBySlot[i]
                inv[i] = {
                    selected = false,
                    itemLink = remoteSlot and remoteSlot.link or GetInventoryItemLink("player", i),
                    texture  = remoteSlot and remoteSlot.texture or GetInventoryItemTexture("player", i)
                }
            end
        end

        for i = 0, 19 do
            if inv[i].itemLink and type(inv[i].itemLink) == "string" then
                GetItemInfo(inv[i].itemLink)
                if C_Item and C_Item.RequestLoadItemDataByID then
                    pcall(function() C_Item.RequestLoadItemDataByID(inv[i].itemLink) end)
                end
            end
        end

        GM.currentEditingSet = setName
        GM.setEditorInv = inv
        GM.inSidebarEditorMode = true

        local idPrefix = "WRGearSetSlot_" .. (setName:gsub("[^%w]", "_")) .. "_"

        local slotNames = {
            [0] = "Ammo", [1] = "Head", [2] = "Neck", [3] = "Shoulder",
            [4] = "Shirt", [5] = "Chest", [6] = "Waist", [7] = "Legs",
            [8] = "Feet", [9] = "Wrist", [10] = "Hands", [11] = "Ring 1",
            [12] = "Ring 2", [13] = "Trinket 1", [14] = "Trinket 2",
            [15] = "Back", [16] = "Main Hand", [17] = "Off Hand", [18] = "Ranged", [19] = "Tabard"
        }

        local paneCard = self:CreateSettingsCard(parent, yPos, nil)
        local HEADER_H   = 28
        local headerY    = -10

        local cardY = -10

        local headerIconBtn = CreateFrame("Button", nil, paneCard)
        headerIconBtn:SetSize(HEADER_H, HEADER_H)
        headerIconBtn:SetPoint("TOPLEFT", paneCard, "TOPLEFT", 12, headerY)
        local headerIconTex = headerIconBtn:CreateTexture(nil, "ARTWORK")
        headerIconTex:SetAllPoints()
        headerIconTex:SetTexture(setData.icon or 134400)
        headerIconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local function MakeHeaderIconBorder(point1, point2, h, w)
            local t = headerIconBtn:CreateTexture(nil, "OVERLAY")
            t:SetColorTexture(0, 0, 0, 1)
            t:SetPoint(point1, 0, 0)
            t:SetPoint(point2, 0, 0)
            if h then t:SetHeight(h) end
            if w then t:SetWidth(w) end
        end
        MakeHeaderIconBorder("TOPLEFT",    "TOPRIGHT",    1, nil)
        MakeHeaderIconBorder("BOTTOMLEFT", "BOTTOMRIGHT", 1, nil)
        MakeHeaderIconBorder("TOPLEFT",    "BOTTOMLEFT",  nil, 1)
        MakeHeaderIconBorder("TOPRIGHT",   "BOTTOMRIGHT", nil, 1)
        headerIconBtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(RCL["Click to change icon"], 1, 1, 1)
            GameTooltip:Show()
        end)
        headerIconBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        headerIconBtn:SetScript("OnClick", function()
            if GM.ShowIconPickerGrid then
                GM:ShowIconPickerGrid(function(selectedIcon)
                    setData.icon = selectedIcon
                    local remoteBuf = GM.remoteSetBuffers and GM.remoteSetBuffers[setName]
                    if remoteBuf then
                        remoteBuf.icon = selectedIcon
                        local rcb = GM.remoteEditCallbacks and GM.remoteEditCallbacks[setName]
                        if rcb then rcb(setName, remoteBuf) end
                    else
                        if not RC.db.gearSets then RC.db.gearSets = {} end
                        RC.db.gearSets[setName] = setData
                        RC:SaveConfigurationToProfile()
                    end
                    if frame and RC.ShowSidebarGearManagerConfig then
                        RC:ShowSidebarGearManagerConfig(frame, true)
                    end
                end, setData.icon or 134400, headerIconBtn, "RIGHT")
            end
        end)

        local nameContainer = self.UI:CreateStyledEditBox(paneCard, {
            width      = 200,
            height     = HEADER_H - 4,
            maxLetters = 50,
        })
        nameContainer:SetPoint("LEFT", headerIconBtn, "RIGHT", 8, 0)
        local nameEditBox = nameContainer.editBox
        nameEditBox:SetText(setName)
        nameEditBox:SetCursorPosition(0)
        nameEditBox:SetAutoFocus(false)

        local function CommitRename()
            local newName = nameEditBox:GetText() or ""
            newName = newName:gsub("^%s+", ""):gsub("%s+$", "")
            if newName == "" or newName == setName then
                nameEditBox:SetText(setName)
                nameEditBox:ClearFocus()
                return
            end
            if GM.sets[newName] or (RC.db.gearSets and RC.db.gearSets[newName]) then
                nameEditBox:SetText(setName)
                nameEditBox:ClearFocus()
                return
            end
            local oldData = GM.sets[setName]
            if not oldData then
                nameEditBox:SetText(setName)
                nameEditBox:ClearFocus()
                return
            end
            GM.sets[newName] = oldData
            GM.sets[setName] = nil
            -- Cross-store fixup: raid boss configs reference gear sets by
            -- name, so every profile/boss must be walked to repoint any
            -- gearSwapOnTarget/gearSwapAfterCombat pointing at the old name.
            if RC.db.raidProfiles then
                for _, raidStruct in pairs(RC.db.raidProfiles) do
                    if raidStruct and raidStruct.profiles then
                        for _, rp in pairs(raidStruct.profiles) do
                            if rp and rp.bosses then
                                for _, bossConfig in pairs(rp.bosses) do
                                    if bossConfig then
                                        if bossConfig.gearSwapOnTarget == setName then
                                            bossConfig.gearSwapOnTarget = newName
                                        end
                                        if bossConfig.gearSwapAfterCombat == setName then
                                            bossConfig.gearSwapAfterCombat = newName
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
            if frame and frame._expandedSets and frame._expandedSets[setName] then
                frame._expandedSets[setName] = nil
                frame._expandedSets[newName] = true
            end
            if GM.editorStates and GM.editorStates[setName] then
                GM.editorStates[newName] = GM.editorStates[setName]
                GM.editorStates[setName] = nil
            end
            if GM.currentEditingSet == setName then
                GM.currentEditingSet = newName
            end
            if RC.SaveConfigurationToProfile then
                RC:SaveConfigurationToProfile()
            end
            if frame and RC.ShowSidebarGearManagerConfig then
                RC:ShowSidebarGearManagerConfig(frame, true)
            end
        end
        nameEditBox:SetScript("OnEnterPressed", function(self)
            CommitRename()
        end)
        nameEditBox:SetScript("OnEditFocusLost", function(self)
            CommitRename()
        end)
        nameEditBox:SetScript("OnEscapePressed", function(self)
            self:SetText(setName)
            self:ClearFocus()
        end)

        cardY = cardY - HEADER_H - 8

        local SLOT_ICON   = 32
        local SLOT_ROW_H  = 40
        local SLOT_COL_X  = 130
        local SLOT_WEAPON_Y = -(8 * SLOT_ROW_H + 12)

        local paneContainer = CreateFrame("Frame", nil, paneCard)
        paneContainer:SetSize(280, math.abs(SLOT_WEAPON_Y) + SLOT_ICON + 18)
        paneContainer:SetPoint("TOPLEFT", paneCard, "TOPLEFT", 14, cardY)

        local slotLayout = {
            {slot=1,  x=0, y=0},
            {slot=2,  x=0, y=-SLOT_ROW_H},
            {slot=3,  x=0, y=-SLOT_ROW_H * 2},
            {slot=15, x=0, y=-SLOT_ROW_H * 3},
            {slot=5,  x=0, y=-SLOT_ROW_H * 4},
            {slot=4,  x=0, y=-SLOT_ROW_H * 5},
            {slot=19, x=0, y=-SLOT_ROW_H * 6},
            {slot=9,  x=0, y=-SLOT_ROW_H * 7},
            {slot=10, x=SLOT_COL_X, y=0},
            {slot=6,  x=SLOT_COL_X, y=-SLOT_ROW_H},
            {slot=7,  x=SLOT_COL_X, y=-SLOT_ROW_H * 2},
            {slot=8,  x=SLOT_COL_X, y=-SLOT_ROW_H * 3},
            {slot=11, x=SLOT_COL_X, y=-SLOT_ROW_H * 4},
            {slot=12, x=SLOT_COL_X, y=-SLOT_ROW_H * 5},
            {slot=13, x=SLOT_COL_X, y=-SLOT_ROW_H * 6},
            {slot=14, x=SLOT_COL_X, y=-SLOT_ROW_H * 7},
            {slot=16, x=0,                    y=SLOT_WEAPON_Y},
            {slot=17, x=math.floor(SLOT_COL_X * 0.5), y=SLOT_WEAPON_Y},
            {slot=18, x=SLOT_COL_X,           y=SLOT_WEAPON_Y},
            {slot=0,  x=math.floor(SLOT_COL_X * 1.5), y=SLOT_WEAPON_Y},
        }

        local function GetSlotTexture(slot)
            local slotInfo = inv[slot]
            if not slotInfo then
                local texture = RC:GetSlotEmptyTexture(GM.slotInfo[slot].name)
                return texture, 0.5, 0.5, 0.5
            end

            local itemLink = slotInfo.itemLink

            if itemLink == nil then
                local texture = RC:GetSlotEmptyTexture(GM.slotInfo[slot].name)
                return texture, 0.5, 0.5, 0.5
            end

            -- 0/"0"/"EMPTY" all mean explicit UNEQUIP for this slot; the
            -- string variants come from ItemRack-imported sets.
            local isUnequip = (itemLink == 0) or
                             (itemLink == "0") or
                             (itemLink == "EMPTY") or
                             (itemLink == "empty") or
                             (type(itemLink) == "string" and itemLink:lower() == "empty")

            if isUnequip then
                inv[slot].itemLink = 0
                local texture = RC:GetSlotEmptyTexture(GM.slotInfo[slot].name)
                return texture, 1, 1, 0
            end

            if type(itemLink) == "string" then
                if not itemLink:match("item:") then
                    local _, texture = GetInventorySlotInfo(GM.slotInfo[slot].name)
                    return texture, 0.8, 0.5, 0.5
                end

                local texture = nil
                if slotInfo.texture then texture = slotInfo.texture end
                if not texture then
                    local equippedLink = GetInventoryItemLink("player", slot)
                    if equippedLink == itemLink then
                        texture = GetInventoryItemTexture("player", slot)
                    end
                    if not texture and GM.remoteEquippedBySlot and GM.remoteEquippedBySlot[slot] then
                        if GM.remoteEquippedBySlot[slot].link == itemLink then
                            texture = GM.remoteEquippedBySlot[slot].texture
                        end
                    end
                end
                if not texture and GM.sets[setName] then
                    local set = GM.sets[setName]
                    if set.textures and set.textures[slot] then
                        texture = set.textures[slot]
                    end
                end
                if not texture then texture = GetItemIcon(itemLink) end
                if not texture then
                    local _, slotTexture = GetInventorySlotInfo(GM.slotInfo[slot].name)
                    return slotTexture, 1, 1, 1
                end
                return texture, 1, 1, 1
            end

            local _, texture = GetInventorySlotInfo(GM.slotInfo[slot].name)
            return texture, 0.8, 0.5, 0.5
        end

        local function UpdateSlotButton(btn, slot)
            if not btn or not btn.icon then return end
            local texture, r, g, b = GetSlotTexture(slot)
            btn.icon:SetTexture(texture)
            btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            btn.icon:Show()
            if inv[slot].selected then
                btn.icon:SetDesaturated(false)
                btn.icon:SetVertexColor(r, g, b, 1)
            else
                btn.icon:SetDesaturated(true)
                local _dc = RC:GetColor("text", "disabled")
                btn.icon:SetVertexColor(_dc.r, _dc.g, _dc.b, 1)
            end
        end

        for _, layout in ipairs(slotLayout) do
            local slot = layout.slot
            local btnName = idPrefix .. slot

            local existingBtn = _G[btnName]
            if existingBtn then
                existingBtn:Hide()
                existingBtn:ClearAllPoints()
                if existingBtn.icon then existingBtn.icon:SetTexture(nil) end
                existingBtn:SetParent(nil)
                _G[btnName] = nil
            end

            local btn = CreateFrame("Frame", btnName, paneContainer)
            btn:SetSize(SLOT_ICON, SLOT_ICON)
            btn:SetPoint("TOPLEFT", paneContainer, "TOPLEFT", layout.x, layout.y)
            btn:SetID(slot)
            btn:EnableMouse(true)

            local bg = btn:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(C.blackDim[1], C.blackDim[2], C.blackDim[3], C.blackDim[4])

            local icon = btn:CreateTexture(nil, "ARTWORK")
            icon:SetAllPoints()
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            icon:SetDrawLayer("ARTWORK", 1)
            icon:Show()
            btn.icon = icon

            local borderSize = 1
            local borderTop = btn:CreateTexture(nil, "OVERLAY")
            borderTop:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
            borderTop:SetPoint("TOPLEFT", 0, 0)
            borderTop:SetPoint("TOPRIGHT", 0, 0)
            borderTop:SetHeight(borderSize)

            local borderBottom = btn:CreateTexture(nil, "OVERLAY")
            borderBottom:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
            borderBottom:SetPoint("BOTTOMLEFT", 0, 0)
            borderBottom:SetPoint("BOTTOMRIGHT", 0, 0)
            borderBottom:SetHeight(borderSize)

            local borderLeft = btn:CreateTexture(nil, "OVERLAY")
            borderLeft:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
            borderLeft:SetPoint("TOPLEFT", 0, 0)
            borderLeft:SetPoint("BOTTOMLEFT", 0, 0)
            borderLeft:SetWidth(borderSize)

            local borderRight = btn:CreateTexture(nil, "OVERLAY")
            borderRight:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
            borderRight:SetPoint("TOPRIGHT", 0, 0)
            borderRight:SetPoint("BOTTOMRIGHT", 0, 0)
            borderRight:SetWidth(borderSize)

            btn.borders = {borderTop, borderBottom, borderLeft, borderRight}

            UpdateSlotButton(btn, slot)

            local label = self:CreateFontString(paneContainer, "OVERLAY", nil, 9)
            local isWeapon = (slot == 0 or slot == 16 or slot == 17 or slot == 18)
            if isWeapon then
                label:SetPoint("TOP", btn, "BOTTOM", 0, -2)
                label:SetJustifyH("CENTER")
            else
                label:SetPoint("LEFT", btn, "RIGHT", 5, 0)
                label:SetJustifyH("LEFT")
            end
            label:SetText(slotNames[slot] or RCL["Slot "] .. slot)
            if inv[slot].selected then
                label:SetTextColor(TEXT.green[1], TEXT.green[2], TEXT.green[3])
            else
                label:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
            end

            btn:SetScript("OnMouseUp", function(self, button)
                if button == "LeftButton" then
                    local id = self:GetID()
                    GM.currentEditingSet = setName
                    GM.setEditorInv = inv
                    inv[id].selected = not inv[id].selected
                    UpdateSlotButton(self, id)
                    if inv[id].selected then
                        label:SetTextColor(TEXT.green[1], TEXT.green[2], TEXT.green[3])
                    else
                        label:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
                    end
                    RC:SaveCurrentGearSetEditorState()
                end
            end)

            btn:SetScript("OnEnter", function(self)
                local id = self:GetID()
                GM.currentEditingSet = setName
                GM.setEditorInv = inv
                GM.currentSlotButton = self
                GM:CancelHideTimer()
                local _hb = RC:GetColor("gearManager", "slotHoverBorder")
                for _, border in ipairs(self.borders) do
                    border:SetColorTexture(_hb.r, _hb.g, _hb.b, 1)
                end
                if GM.settings.showTooltips and inv[id] and inv[id].itemLink ~= nil then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    local itemLink = inv[id].itemLink
                    local isUnequip = (itemLink == 0) or
                                     (itemLink == "0") or
                                     (itemLink == "EMPTY") or
                                     (itemLink == "empty") or
                                     (type(itemLink) == "string" and itemLink:lower() == "empty")
                    if isUnequip then
                        GameTooltip:SetText(RCL["Unequip Slot"], 1, 1, 0)
                        GameTooltip:AddLine(RCL["This slot will be unequipped"], 0.8, 0.8, 0.8)
                    elseif type(itemLink) == "string" and itemLink:match("^item:") then
                        pcall(function() GameTooltip:SetHyperlink(itemLink) end)
                    end
                    GameTooltip:Show()
                end
                if GM.settings.characterSheetMenus then
                    GM:ShowMenu(id, self, "RIGHT")
                end
            end)

            btn:SetScript("OnLeave", function(self)
                for _, border in ipairs(self.borders) do
                    border:SetColorTexture(C.black[1], C.black[2], C.black[3], C.black[4])
                end
                GameTooltip:Hide()
            end)
        end

        cardY = cardY - paneContainer:GetHeight() - 8

        local optionsLabel = self:CreateFontString(paneCard, "OVERLAY", nil, 10)
        optionsLabel:SetPoint("TOPLEFT", paneCard, "TOPLEFT", 14, cardY)
        optionsLabel:SetText(RCL["When Equipping This Set"])
        optionsLabel:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
        cardY = cardY - 22

        local helmCheck = self.UI:CreateSettingCheckbox(paneCard, cardY, "Show Helm", setData.showHelm == true, function(cb)
            local v = cb:GetChecked()
            setData.showHelm = v and true or false
            local remoteBuf2 = GM.remoteSetBuffers and GM.remoteSetBuffers[setName]
            if remoteBuf2 then
                remoteBuf2.showHelm = setData.showHelm
                local rcb2 = GM.remoteEditCallbacks and GM.remoteEditCallbacks[setName]
                if rcb2 then rcb2(setName, remoteBuf2) end
            else
                if RC.db.gearSets and RC.db.gearSets[setName] then
                    RC.db.gearSets[setName].showHelm = setData.showHelm
                end
                RC:SaveConfigurationToProfile()
            end
            RC:ForceCheckboxUpdate(cb, v)
        end)
        cardY = cardY - 24

        local cloakCheck = self.UI:CreateSettingCheckbox(paneCard, cardY, "Show Cloak", setData.showCloak == true, function(cb)
            local v = cb:GetChecked()
            setData.showCloak = v and true or false
            local remoteBuf3 = GM.remoteSetBuffers and GM.remoteSetBuffers[setName]
            if remoteBuf3 then
                remoteBuf3.showCloak = setData.showCloak
                local rcb3 = GM.remoteEditCallbacks and GM.remoteEditCallbacks[setName]
                if rcb3 then rcb3(setName, remoteBuf3) end
            else
                if RC.db.gearSets and RC.db.gearSets[setName] then
                    RC.db.gearSets[setName].showCloak = setData.showCloak
                end
                RC:SaveConfigurationToProfile()
            end
            RC:ForceCheckboxUpdate(cb, v)
        end)
        cardY = cardY - 32

        local macroLabel = self:CreateFontString(paneCard, "OVERLAY", nil, 10)
        macroLabel:SetPoint("TOPLEFT", paneCard, "TOPLEFT", 14, cardY)
        macroLabel:SetText(RCL["Equip Macro"])
        macroLabel:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
        cardY = cardY - 18

        local macroHint = self:CreateFontString(paneCard, "OVERLAY", nil, 10)
        macroHint:SetPoint("TOPLEFT", paneCard, "TOPLEFT", 14, cardY)
        macroHint:SetText(RCL["Paste into a WoW macro to equip this set"])
        macroHint:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
        cardY = cardY - 16

        local macroText = "/rc gearset " .. setName
        local macroContainer = self.UI:CreateStyledEditBox(paneCard, {
            width      = 280,
            height     = 22,
            maxLetters = 256,
        })
        macroContainer:SetPoint("TOPLEFT", paneCard, "TOPLEFT", 14, cardY)
        local macroEditBox = macroContainer.editBox
        macroEditBox:SetText(macroText)
        macroEditBox:SetCursorPosition(0)
        macroEditBox:SetAutoFocus(false)
        macroEditBox:SetScript("OnEditFocusGained", function(self) self:HighlightText() end)
        macroEditBox:SetScript("OnEditFocusLost",   function(self) self:SetText(macroText); self:ClearHighlightText() end)
        macroEditBox:SetScript("OnEnterPressed",    function(self) self:ClearFocus() end)
        macroEditBox:SetScript("OnEscapePressed",   function(self) self:ClearFocus() end)
        cardY = cardY - 32

        local keybindLabel = self:CreateFontString(paneCard, "OVERLAY", nil, 10)
        keybindLabel:SetPoint("TOPLEFT", paneCard, "TOPLEFT", 14, cardY)
        keybindLabel:SetText(RCL["Keybind to Equip"])
        keybindLabel:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
        cardY = cardY - 16

        local keybindSubHint = self:CreateFontString(paneCard, "OVERLAY", nil, 10)
        keybindSubHint:SetPoint("TOPLEFT", paneCard, "TOPLEFT", 14, cardY)
        keybindSubHint:SetText(RCL["Click the button then press any key. Supports Alt, Ctrl, Shift combos."])
        keybindSubHint:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
        cardY = cardY - 20

        local currentKey = setData.keybind or ""
        local listening  = false

        local captureFrame = CreateFrame("Frame", nil, paneCard)
        captureFrame:SetAllPoints(paneCard)
        captureFrame:EnableKeyboard(false)
        captureFrame:SetPropagateKeyboardInput(false)
        captureFrame:SetFrameStrata("DIALOG")
        captureFrame:Hide()

        local keybindBtn = self.UI:CreateStyledButton(paneCard, currentKey ~= "" and currentKey or RCL["Click to bind..."], 140, 22)
        keybindBtn:SetPoint("TOPLEFT", paneCard, "TOPLEFT", 14, cardY)

        local clearBtn = self.UI:CreateStyledButton(paneCard, RCL["Clear"], 50, 22)
        clearBtn:SetPoint("LEFT", keybindBtn, "RIGHT", 6, 0)

        local keybindStatus = self:CreateFontString(paneCard, "OVERLAY", nil, 10)
        keybindStatus:SetPoint("LEFT", clearBtn, "RIGHT", 8, 0)
        keybindStatus:SetText(currentKey ~= "" and ("Bound: " .. currentKey) or "")
        keybindStatus:SetTextColor(TEXT.green[1], TEXT.green[2], TEXT.green[3])

        local function StopListening()
            listening = false
            captureFrame:EnableKeyboard(false)
            captureFrame:Hide()
            local k = setData.keybind or ""
            keybindBtn:SetText(k ~= "" and k or RCL["Click to bind..."])
            keybindStatus:SetText(k ~= "" and ("Bound: " .. k) or "")
            keybindStatus:SetTextColor(TEXT.green[1], TEXT.green[2], TEXT.green[3])
        end

        captureFrame:SetScript("OnKeyDown", function(_, key)
            if key == "ESCAPE" then StopListening(); return end
            if key == "LSHIFT" or key == "RSHIFT" or
               key == "LCTRL"  or key == "RCTRL"  or
               key == "LALT"   or key == "RALT"   then return end
            local mods = ""
            if IsShiftKeyDown()   then mods = mods .. "SHIFT-" end
            if IsControlKeyDown() then mods = mods .. "CTRL-"  end
            if IsAltKeyDown()     then mods = mods .. "ALT-"   end
            local fullKey = mods .. key
            if GM.SetSetKeybind then GM:SetSetKeybind(setName, fullKey) end
            setData.keybind = fullKey
            StopListening()
        end)

        keybindBtn:SetScript("OnClick", function()
            if listening then
                StopListening()
            else
                listening = true
                captureFrame:EnableKeyboard(true)
                captureFrame:Show()
                keybindBtn:SetText(RCL["Press a key..."])
                keybindStatus:SetText(RCL["Esc to cancel"])
                keybindStatus:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
            end
        end)

        clearBtn:SetScript("OnClick", function()
            StopListening()
            if GM.SetSetKeybind then GM:SetSetKeybind(setName, "") end
            setData.keybind = ""
            keybindBtn:SetText(RCL["Click to bind..."])
            keybindStatus:SetText("")
        end)

        cardY = cardY - 32

        paneCard:SetContentHeight(math.abs(cardY))
        return yPos - paneCard:GetHeight() - 15
    end

    function RC:ShowSidebarGearSetEditor(frame)
        self:ClearSidebarContent(self.sidebarConfigFrame)
        local parent = frame.scrollChild
        local yPos = -20

        if not frame.gearEditState or not frame.gearEditState.setName then
            self:ShowSidebarGearManagerConfig(frame)
            return
        end

        local GM = self.GearManager
        if not GM then
            self:ShowSidebarGearManagerConfig(frame)
            return
        end

        local setName = frame.gearEditState.setName
        local setData = GM.sets[setName]
        if not setData then
            self:ShowSidebarGearManagerConfig(frame)
            return
        end

        local backButton = self.UI:CreateBackButton(parent, "Back", 80, 28)
        backButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
        backButton:SetScript("OnClick", function()
            frame.gearEditState = nil
            RC:ShowSidebarGearManagerConfig(frame)
        end)

        local header = self:CreateFontString(parent, "OVERLAY", nil, 16)
        header:SetPoint("LEFT", backButton, "RIGHT", 15, 0)
        header:SetText(RCL["Edit: "] .. setName)
        header:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
        yPos = yPos - 50

        yPos = self:BuildGearSetEditorBody(parent, yPos, setName, setData, frame, {
            onSave = function()
                frame.gearEditState = nil
                RC:ShowSidebarGearManagerConfig(frame)
            end,
            onCancel = function()
                frame.gearEditState = nil
                RC:ShowSidebarGearManagerConfig(frame)
            end,
            onRefresh = function()
                RC:ShowSidebarGearSetEditor(frame)
            end,
        })

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end

    RC:DebugPrint("ConfigUI_Equipment panels loaded", "system")
