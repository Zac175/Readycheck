------------------------------------------------------------------------
-- Readycheck - Per-Ability Config Pages (Trinkets, Utility, Defensives,
-- Generic Ability)
-- Owns encounterSettings.abilities[key] for single-slot special cases
-- (trinket1/trinket2/battleChicken/arcaniteDragonling, laststand/
-- shieldwall) and the generic ShowSidebarAbilityConfig used for every
-- other ability key, plus consumable post-death reminders
-- (encounterSettings.postDeathConsumables).
-- Bulk trash editing: each page's BulkSaveConfig/BulkSaveDefensive fans a
-- save on the "template" mob (see Raids_BulkTrash.lua) out to every other
-- mob in frame.bulkTrashMode.selectedMobs by OVERWRITING that one ability
-- slot wholesale on each - any pre-existing per-mob customization on that
-- same slot for the other mobs is replaced, not merged.
-- ShowSidebarAbilityConfig re-derives the remote-edit branch inline
-- (RC.remoteEditMode/RC._remoteEditData) using raw self.db.raidProfiles
-- reads rather than the RC:GetEditableActiveProfile helper the other
-- pages in this file use - same effective behavior, just a second place
-- that must stay in sync with the remote-edit contract.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format, string_lower = string.format, string.lower
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not (RC and RC.UI) then return end
RC._sbr = RC._sbr or {}
local _sbr = RC._sbr
local GetTabHoverBg, GetTabNormalBg, GetTabSelectedBg, TEXT = _sbr.GetTabHoverBg, _sbr.GetTabNormalBg, _sbr.GetTabSelectedBg, _sbr.TEXT

-- What a TTK trigger with no number saved means - the same default the
-- reminder engine uses (TTK_Model): an offset of 3 on a trinket, 30s
-- otherwise. Kept here too for when the reminder addon is switched off.
local function DefaultTTKValue(abilityKey)
    if RC.TTKDefaultValue then return RC:TTKDefaultValue(abilityKey) end
    if abilityKey == "trinket1" or abilityKey == "trinket2" then return 3 end
    return 30
end

-- The lines under a TTK slider: what the number means, the moment it
-- fires (a trinket's own buff length added on), and how long this boss
-- usually lives, so the setting can be judged without pulling the boss.
-- Returns the new cardY and a redraw for when the slider moves.
local function AddTTKHelp(card, cardY, raidName, encounterName, encounterType, abilityKey, getValue)
    local isTrinket = (abilityKey == "trinket1" or abilityKey == "trinket2")
    local fs = RC:CreateFontString(card, "OVERLAY", nil, 10)
    fs:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
    fs:SetWidth(math_max(220, ((card.GetWidth and card:GetWidth()) or 480) - 30))
    fs:SetJustifyH("LEFT")
    fs:SetJustifyV("TOP")
    fs:SetWordWrap(true)
    fs:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])

    local function Lines(v)
        local out = {}
        if isTrinket then
            local slot = (abilityKey == "trinket1") and 13 or 14
            local dur, itemId, guessed = 20, nil, true
            if RC.GetTTKTrinketBuffDuration then dur, itemId, guessed = RC:GetTTKTrinketBuffDuration(slot) end
            local name = itemId and GetItemInfo(itemId) or nil
            if not name then name = (slot == 13) and RCL["Top trinket"] or RCL["Bottom trinket"] end
            out[#out + 1] = string_format(RCL["Fires with %ds left on the boss: %s's %ds buff + %ds."], dur + v, name, dur, v)
            if guessed then
                out[#out + 1] = RCL["Its buff length is not known, so 20s is assumed."]
            end
        else
            out[#out + 1] = string_format(RCL["Fires once the boss is expected to die within %ds."], v)
        end
        if encounterType ~= "boss" then
            out[#out + 1] = RCL["Time to Kill reminders only fire on bosses."]
        elseif RC.PredictTTK and raidName and encounterName then
            local boss = RC.TTKBossName and RC:TTKBossName(raidName, encounterName) or encounterName
            local pred, _, n = RC:PredictTTK(raidName, boss)
            local _, _, linked = nil, nil, 0
            if RC.GetLinkedFightHistoryForBoss then _, _, linked = RC:GetLinkedFightHistoryForBoss(raidName, boss) end
            if pred then
                out[#out + 1] = string_format((linked or 0) > 0
                    and RCL["This boss usually dies at %s (%d kills, related configs included)."]
                    or  RCL["This boss usually dies at %s (%d kills)."],
                    RC:FormatTime(pred), n or 0)
            else
                out[#out + 1] = RCL["No kill times for this boss yet: until there are 2, it goes by how fast this pull is going."]
            end
            out[#out + 1] = RCL["Only while you target the boss, from 5s after the pull, never during an add phase."]
        end
        return table.concat(out, "\n")
    end
    local function Redraw()
        fs:SetText(Lines(getValue() or 0))
    end
    Redraw()
    local h = (fs.GetStringHeight and fs:GetStringHeight()) or 36
    return cardY - h - 10, Redraw
end
    function RC:ShowTrinketSlotSelection(frame, raidName, encounterName, encounterType, raidSettings, encounterSettings, preserveScroll, inlineCtx)
        local isInline = (inlineCtx ~= nil)
        local function InlineRefresh()
            if isInline and inlineCtx.onRefresh then inlineCtx.onRefresh() end
        end

        if not isInline then
            self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        end

        -- Re-resolve against the profile being EDITED. While remote editing
        -- that is the other character's profile, so their trinket reminder
        -- settings are what these controls change.
        local freshRaidSettings = self:GetEditableActiveProfile(raidName)
        if freshRaidSettings then
            raidSettings = freshRaidSettings
        end

        local parent = isInline and inlineCtx.parent or frame.scrollChild
        local yPos   = isInline and inlineCtx.yPos   or -20

        if not frame.trinketTab then
            frame.trinketTab = "trinket1"
        end

        local lookupKey = encounterName
        if encounterType == "boss" then
            encounterSettings = raidSettings.bosses[lookupKey]
        else
            encounterSettings = raidSettings.trash[lookupKey]
        end

        if not encounterSettings then
            self:Print(RCL["ERROR: No encounter settings found for "] .. lookupKey)
            -- Inline callers add this to their own yPos, so every exit owes
            -- them a number. Nothing was drawn, so the height consumed is
            -- whatever we started with.
            if isInline then return yPos end
            return
        end

        if not encounterSettings.abilities then
            encounterSettings.abilities = {}
        end

        if not encounterSettings.abilities["trinket1"] then
            encounterSettings.abilities["trinket1"] = { enabled = false, triggerType = "hp_percent" }
        end
        if not encounterSettings.abilities["trinket2"] then
            encounterSettings.abilities["trinket2"] = { enabled = false, triggerType = "hp_percent" }
        end

        -- Fans out the template mob's slotKey config to every other selected
        -- mob (bulk trash editing - see Raids_BulkTrash.lua). The target
        -- mob's abilities[slotKey] is replaced wholesale (shallow copy of
        -- every field), so any setting that mob already had on this same
        -- slot is gone, not merged; other ability slots on that mob are
        -- untouched. hasAnyEnabled recomputes each mob's top-level enabled
        -- flag afterward since this can flip it independently of the UI
        -- checkbox that normally drives it.
        local function BulkSaveConfig(slotKey)
            if frame.bulkTrashMode and frame.bulkTrashMode.active then
                local selectedMobs = frame.bulkTrashMode.selectedMobs
                local bulkRaidSettings = RC:GetEditableActiveProfile(raidName)
                if bulkRaidSettings and bulkRaidSettings.trash then
                    local sourceConfig = encounterSettings.abilities[slotKey]
                    for mobName in pairs(selectedMobs) do
                        if mobName ~= encounterName then
                            if not bulkRaidSettings.trash[mobName] then
                                bulkRaidSettings.trash[mobName] = { enabled = false, abilities = {} }
                            end
                            if not bulkRaidSettings.trash[mobName].abilities then
                                bulkRaidSettings.trash[mobName].abilities = {}
                            end
                            bulkRaidSettings.trash[mobName].abilities[slotKey] = {}
                            for k, v in pairs(sourceConfig) do
                                bulkRaidSettings.trash[mobName].abilities[slotKey][k] = v
                            end
                            local hasAnyEnabled = false
                            for _, ab in pairs(bulkRaidSettings.trash[mobName].abilities) do
                                if ab.enabled then hasAnyEnabled = true break end
                            end
                            bulkRaidSettings.trash[mobName].enabled = hasAnyEnabled
                        end
                    end
                end
            end
            RC:SaveConfigurationToProfile()
            RC:RefreshSidebarProfiles()
        end

        local function RefreshThisPage()
            if isInline then
                InlineRefresh()
            else
                RC:ShowTrinketSlotSelection(frame, raidName, encounterName, encounterType, raidSettings, encounterSettings, true)
            end
        end

        if not isInline then
            local backButton = self.UI:CreateBackButton(parent, "Back", 80, 28)
            backButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
            backButton:SetScript("OnClick", function()
                if frame.bulkTrashMode and frame.bulkTrashMode.active then
                    frame.bulkTrashMode = nil
                    self:ShowSidebarBulkTrashConfig(frame, raidName)
                else
                    self:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings)
                end
            end)

            local trinketIcon = parent:CreateTexture(nil, "ARTWORK")
            trinketIcon:SetSize(28, 28)
            trinketIcon:SetPoint("LEFT", backButton, "RIGHT", 15, 0)
            trinketIcon:SetTexture("Interface\\Icons\\INV_Trinket_Naxxramas04")

            local header = self:CreateFontString(parent, "OVERLAY", nil, 16)
            header:SetPoint("LEFT", trinketIcon, "RIGHT", 10, 0)
            local mobCount = 0
            if frame.bulkTrashMode and frame.bulkTrashMode.selectedMobs then
                for _ in pairs(frame.bulkTrashMode.selectedMobs) do mobCount = mobCount + 1 end
            end
            if mobCount > 1 then
                header:SetText(RCL["Trinkets / Summons ("] .. mobCount .. RCL[" mobs)"])
            else
                header:SetText(encounterName .. RCL[" - Trinkets / Summons"])
            end
            header:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
            yPos = yPos - 50
        end

        local t1Config = encounterSettings.abilities["trinket1"]
        local t2Config = encounterSettings.abilities["trinket2"]

        if not encounterSettings.abilities["battleChicken"] then
            encounterSettings.abilities["battleChicken"] = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
        end
        if not encounterSettings.abilities["arcaniteDragonling"] then
            encounterSettings.abilities["arcaniteDragonling"] = { enabled = false, triggerType = "combat_start", combatTime = 0, equipAfterDeath = false }
        end
        local bcConfig = encounterSettings.abilities["battleChicken"]
        local adConfig = encounterSettings.abilities["arcaniteDragonling"]

        local tabConfigs = {
            { key = "trinket1", label = RCL["Trinket 1"], config = t1Config },
            { key = "trinket2", label = RCL["Trinket 2"], config = t2Config },
            { key = "battleChicken", label = RCL["Chicken"], config = bcConfig },
            { key = "arcaniteDragonling", label = RCL["Dragonling"], config = adConfig }
        }

        -- Framework tab row (was a hand-rolled 2x2 BackdropTemplate grid with
        -- "[ON]/[OFF]" colour codes in the labels). An enabled slot shows the
        -- same 6x6 ui.configured square the tiles and nav rows use.
        local tabDefs = {}
        for i, tabInfo in ipairs(tabConfigs) do
            tabDefs[i] = { key = tabInfo.key, label = tabInfo.label }
        end
        local tabGroup, tabNextY = self.UI:CreateTabGroup(parent, {
            y = yPos, tabs = tabDefs, selected = frame.trinketTab,
            inset = 18, advance = 22 + 12,
            onClick = function(key)
                frame.trinketTab = key
                RefreshThisPage()
            end,
        })
        if tabGroup then
            local onColor = RC:GetColor("ui", "configured")
            for _, tabInfo in ipairs(tabConfigs) do
                local entry = tabGroup.buttons[tabInfo.key]
                if entry and tabInfo.config and tabInfo.config.enabled then
                    local dot = entry.btn:CreateTexture(nil, "OVERLAY")
                    dot:SetSize(6, 6)
                    dot:SetPoint("TOPRIGHT", entry.btn, "TOPRIGHT", -3, -3)
                    dot:SetTexture(RC.UI.FLAT)
                    dot:SetVertexColor(onColor.r, onColor.g, onColor.b, 1)
                end
            end
        end

        yPos = tabNextY

        local currentTrinketKey = frame.trinketTab
        local currentConfig = encounterSettings.abilities[currentTrinketKey]

        local trinketLabel
        if currentTrinketKey == "trinket1" then
            trinketLabel = "Trinket Slot 1"
        elseif currentTrinketKey == "trinket2" then
            trinketLabel = "Trinket Slot 2"
        elseif currentTrinketKey == "battleChicken" then
            trinketLabel = "Battle Chicken"
        elseif currentTrinketKey == "arcaniteDragonling" then
            trinketLabel = "Arcanite Dragonling"
        else
            trinketLabel = "Unknown"
        end

        local function HasEnabledAbilities()
            if encounterSettings.abilities then
                for abilityKey, abilityConfig in pairs(encounterSettings.abilities) do
                    if abilityConfig and abilityConfig.enabled then
                        return true
                    end
                end
            end
            if encounterSettings.postDeathConsumables
               and next(encounterSettings.postDeathConsumables) then
                return true
            end
            return false
        end

        local function UpdateEncounterEnabled()
            local hasAbilities = HasEnabledAbilities()
            if encounterSettings.enabled ~= hasAbilities then
                encounterSettings.enabled = hasAbilities
            end
        end

        local configCard = self:CreateSettingsCard(parent, yPos, trinketLabel .. RCL[" configuration"])
        local cardY = -35

        -- EVERY exit from this function must go through here. It publishes
        -- the card height and hands the consumed height back to the caller.
        -- The two early returns below (summon tabs, and a slot that is
        -- switched off) used to `return` bare: the inline caller in
        -- Raids_BossConfig does `if newY then yPos = yPos + newY end`, so a
        -- nil left its yPos at 0 and the next block - the Sapphiron polarity
        -- card - was drawn straight on top of these tabs and this card.
        local function FinishConfigCard()
            configCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - configCard:GetHeight() - 20
            if not isInline then
                self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            end
            return yPos
        end

        local enableCheck = self.UI:CreateCheckbox(configCard, RCL["Enable "] .. trinketLabel .. RCL[" Reminder"], currentConfig.enabled)
        enableCheck:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
        enableCheck:SetScript("OnClick", function(cb)
            local isChecked = cb:GetChecked()
            encounterSettings.abilities[currentTrinketKey].enabled = isChecked
            encounterSettings.abilities[currentTrinketKey].enableTTS = isChecked
            UpdateEncounterEnabled()
            BulkSaveConfig(currentTrinketKey)
            RefreshThisPage()
        end)

        local ttsCheck = self.UI:CreateSettingCheckbox(configCard, cardY, "Enable Text-to-Speech", currentConfig.enableTTS or false, function(cb)
            local newState = cb:GetChecked()
            encounterSettings.abilities[currentTrinketKey].enableTTS = newState
            RC:ForceCheckboxUpdate(cb, newState)
            BulkSaveConfig(currentTrinketKey)
        end)
        ttsCheck:ClearAllPoints()
        ttsCheck:SetPoint("TOPLEFT", configCard, "TOPLEFT",
            math.max(180, math.floor((configCard:GetWidth() or 480) * 0.5)), cardY)
        cardY = cardY - 28
        -- the voice only speaks a reminder that is on (it sits beside it)
        self.UI:BindDependents(enableCheck, { ttsCheck }, { indent = 0 })

        if currentTrinketKey == "battleChicken" or currentTrinketKey == "arcaniteDragonling" then
            local equipAfterDeathCheck = self.UI:CreateSettingCheckbox(configCard, cardY, "Remind to equip after boss dies", currentConfig.equipAfterDeath or false, function(cb)
                local newState = cb:GetChecked()
                encounterSettings.abilities[currentTrinketKey].equipAfterDeath = newState
                RC:ForceCheckboxUpdate(cb, newState)
                BulkSaveConfig(currentTrinketKey)
            end)
            cardY = cardY - 22

            local equipHint = self:CreateFontString(configCard, "OVERLAY", nil, 10)
            equipHint:SetPoint("TOPLEFT", configCard, "TOPLEFT", 35, cardY)
            equipHint:SetWidth(260)
            equipHint:SetText(RCL["Shows reminder to equip "] .. trinketLabel .. RCL[" when this boss dies"])
            equipHint:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
            cardY = cardY - 20
        end
        cardY = cardY - 2

        if currentTrinketKey == "battleChicken" or currentTrinketKey == "arcaniteDragonling" then
            return FinishConfigCard()
        end

        if not currentConfig.enabled then
            local disabledText = self:CreateFontString(configCard, "OVERLAY", nil, 11)
            disabledText:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            disabledText:SetText(RCL["Enable "] .. trinketLabel .. RCL[" above to configure trigger settings"])
            disabledText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 15

            return FinishConfigCard()
        end

        cardY = cardY - 10
        local triggerLabel = self:CreateFontString(configCard, "OVERLAY", nil, 11)
        triggerLabel:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
        triggerLabel:SetText(RCL["Trigger Type:"])
        triggerLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

        local displayTriggerType = currentConfig.triggerType or "hp_percent"

        local triggerDropdown = self.UI:CreateScrollableDropdown(configCard, 280, RCL["Select Trigger..."], 12)
        triggerDropdown:SetPoint("TOPLEFT", configCard, "TOPLEFT", 140, cardY + 5)

        local currentTriggerName = self.triggerTypes and self.triggerTypes[displayTriggerType] or "Target HP %"
        do
            local triggerItems = {}
            for triggerKey, triggerName in pairs(RC.triggerTypes or {}) do
                table.insert(triggerItems, { text = triggerName, value = triggerKey })
            end
            triggerDropdown:SetItems(triggerItems, function(value)
                local cfg = encounterSettings.abilities[currentTrinketKey]
                cfg.triggerType = value
                -- save the number the page shows, so the page and the
                -- reminder can never disagree about an untouched slider
                if value == "ttk" and cfg.ttkValue == nil then
                    cfg.ttkValue = DefaultTTKValue(currentTrinketKey)
                end
                BulkSaveConfig(currentTrinketKey)
                RefreshThisPage()
            end)
            triggerDropdown:SetSelectedValue(displayTriggerType, currentTriggerName)
        end
        cardY = cardY - 45

        local triggerType = displayTriggerType

        if triggerType == "hp_percent" then
            local displayHpValue = currentConfig.hpValue or 20

            local label = self:CreateFontString(configCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Target HP %:"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])

            local slider = self.UI:CreateSlider(configCard, 1, 100, displayHpValue, 1)
            slider:SetPoint("TOPLEFT", configCard, "TOPLEFT", 140, cardY + 4)
            slider:SetScript("OnValueChanged", function(self, value)
                currentConfig.hpValue = math.floor(value)
                if self.Text then self.Text:SetText(math.floor(value) .. "%") end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig(currentTrinketKey) end)
            cardY = cardY - 40

        elseif triggerType == "ttk" then
            local displayTtkValue = currentConfig.ttkValue or DefaultTTKValue(currentTrinketKey)

            local isTrinket = (currentTrinketKey == "trinket1" or currentTrinketKey == "trinket2")
            local sliderMin = isTrinket and 0 or 5
            local sliderMax = isTrinket and 30 or 120
            local labelText = isTrinket and "TTK Offset (added to buff duration):" or "Time to Kill (seconds):"

            local label = self:CreateFontString(configCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            label:SetText(labelText)
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            local slider = self.UI:CreateSlider(configCard, sliderMin, sliderMax, displayTtkValue, 1)
            slider:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)

            local redrawHelp
            slider:SetScript("OnValueChanged", function(self, value)
                currentConfig.ttkValue = math.floor(value)
                if isTrinket then
                    if self.Text then self.Text:SetText("+" .. math.floor(value) .. "s") end
                else
                    if self.Text then self.Text:SetText(math.floor(value) .. "s") end
                end
                if redrawHelp then redrawHelp() end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig(currentTrinketKey) end)

            cardY = cardY - 38
            cardY, redrawHelp = AddTTKHelp(configCard, cardY, raidName, encounterName, encounterType, currentTrinketKey,
                function() return currentConfig.ttkValue or displayTtkValue end)

        elseif triggerType == "player_hp" then
            local displayPlayerHpValue = currentConfig.playerHpValue or 30

            local label = self:CreateFontString(configCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Player HP %:"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            local slider = self.UI:CreateSlider(configCard, 1, 100, displayPlayerHpValue, 1)
            slider:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            slider:SetScript("OnValueChanged", function(self, value)
                currentConfig.playerHpValue = math.floor(value)
                if self.Text then self.Text:SetText(math.floor(value) .. "%") end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig(currentTrinketKey) end)
            cardY = cardY - 40

        elseif triggerType == "player_hp_above" then
            local displayHpAbove = currentConfig.playerHpAboveValue or 8500

            local label = self:CreateFontString(configCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Show when player HP is above:"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            local slider = self.UI:CreateSlider(configCard, 1000, 15000, displayHpAbove, 100)
            slider:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            slider:SetScript("OnValueChanged", function(self, value)
                local rounded = math.floor(value / 100 + 0.5) * 100
                currentConfig.playerHpAboveValue = rounded
                if self.Text then self.Text:SetText(rounded) end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig(currentTrinketKey) end)
            cardY = cardY - 40

        elseif triggerType == "combat_start" then
            local displayCombatStartDelay = currentConfig.combatStartDelay or 0

            local label = self:CreateFontString(configCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Delay after combat start (seconds):"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            local slider = self.UI:CreateSlider(configCard, 0, 30, displayCombatStartDelay, 1)
            slider:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            slider:SetScript("OnValueChanged", function(self, value)
                currentConfig.combatStartDelay = math.floor(value)
                if self.Text then self.Text:SetText(math.floor(value) .. "s") end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig(currentTrinketKey) end)
            cardY = cardY - 40

        elseif triggerType == "rage_threshold" then
            if not currentConfig.rageValue then currentConfig.rageValue = 50 end

            local label = self:CreateFontString(configCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Rage Level:"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            local slider = self.UI:CreateSlider(configCard, 0, 100, currentConfig.rageValue, 1)
            slider:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            slider:SetScript("OnValueChanged", function(self, value)
                currentConfig.rageValue = math.floor(value)
                if self.Text then self.Text:SetText(math.floor(value)) end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig(currentTrinketKey) end)
            cardY = cardY - 40

        elseif triggerType == "buff_remaining" then
            if not encounterSettings.abilities[currentTrinketKey].buffRemainingValue then
                encounterSettings.abilities[currentTrinketKey].buffRemainingValue = 5
            end

            local buffLabel = self:CreateFontString(configCard, "OVERLAY", nil, 11)
            buffLabel:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            buffLabel:SetText(RCL["Buff to Watch:"])
            buffLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            local buffOptions = {
                { value = "Death Wish", label = RCL["Death Wish (Debuff)"] },
                { value = "Recklessness", label = RCL["Recklessness"] },
                { value = "Mighty Rage", label = RCL["Mighty Rage Potion"] },
                { value = "Blood Fury", label = RCL["Blood Fury (Orc)"] },
                { value = "Berserking", label = RCL["Berserking (Troll)"] },
                { value = "Enrage", label = RCL["Enrage"] },
                { value = "Flurry", label = RCL["Flurry"] },
            }

            local currentBuff = encounterSettings.abilities[currentTrinketKey].buffName or "Death Wish"
            local buffDropdown = self.UI:CreateScrollableDropdown(configCard, 200, currentBuff, 10)
            buffDropdown:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)

            local trinketKeyForBuff = currentTrinketKey
            do
                local buffItems = {}
                local currentBuffLabel = currentBuff
                for _, opt in ipairs(buffOptions) do
                    table.insert(buffItems, { text = opt.label, value = opt.value })
                    if opt.value == currentBuff then currentBuffLabel = opt.label end
                end
                buffDropdown:SetItems(buffItems, function(value)
                    encounterSettings.abilities[trinketKeyForBuff].buffName = value
                    BulkSaveConfig(currentTrinketKey)
                end)
                buffDropdown:SetSelectedValue(currentBuff, currentBuffLabel)
            end
            cardY = cardY - 35

            local label = self:CreateFontString(configCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Trigger when buff has (seconds) remaining:"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            local slider = self.UI:CreateSlider(configCard, 1, 30, encounterSettings.abilities[currentTrinketKey].buffRemainingValue, 1)
            slider:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            local trinketKey = currentTrinketKey
            slider:SetScript("OnValueChanged", function(self, value)
                encounterSettings.abilities[trinketKey].buffRemainingValue = math.floor(value)
                encounterSettings.abilities[trinketKey].buffTimeRemaining = nil
                if self.Text then self.Text:SetText(math.floor(value) .. "s") end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig(currentTrinketKey) end)
            cardY = cardY - 40

        elseif triggerType == "debuff_present" then
            local label = self:CreateFontString(configCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", configCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Debuff Spell ID or Name:"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 22

            local editBoxContainer = self.UI:CreateStyledEditBox(configCard, {
                width       = 250, height = 25,
                initialText = currentConfig.debuffSpellId or "",
                onFocusLost = function(s)
                    currentConfig.debuffSpellId = s:GetText()
                    RC:SaveConfigurationToProfile()
                end,
            })
            editBoxContainer:SetPoint("TOPLEFT", configCard, "TOPLEFT", 20, cardY)
            local editBox = editBoxContainer.editBox
            cardY = cardY - 35
        end

        cardY = cardY + 5
        return FinishConfigCard()
    end

    function RC:ShowSidebarUtilityConfig(frame, raidName, encounterName, encounterType, raidSettings, encounterSettings, preserveScroll, inlineCtx)
        local isInline = (inlineCtx ~= nil)
        local function InlineRefresh()
            if isInline and inlineCtx.onRefresh then inlineCtx.onRefresh() end
        end

        if not isInline then
            self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        end

        -- Resolve against the profile being EDITED (theirs while remote
        -- editing, ours otherwise) so these controls change the right config.
        local freshRaidSettings = self:GetEditableActiveProfile(raidName)
        if freshRaidSettings then
            raidSettings = freshRaidSettings
            local lookupKey = encounterName
            if encounterType == "boss" then
                encounterSettings = raidSettings.bosses[lookupKey]
            else
                encounterSettings = raidSettings.trash[lookupKey]
            end
        end

        -- The profile being edited may not have this encounter yet (common
        -- when it belongs to someone else). Without this the page errors on
        -- the first unguarded index below.
        if not encounterSettings then
            self:Print(RCL["ERROR: No encounter settings found for "] .. tostring(encounterName))
            -- Inline callers add this to their own yPos, so every exit owes
            -- them a number. Nothing was drawn here. Reads inlineCtx.yPos
            -- rather than the local yPos: this guard sits ABOVE the `local
            -- yPos` declaration, so that name is still a nil global here.
            if isInline then return inlineCtx.yPos end
            return
        end
        encounterSettings.abilities = encounterSettings.abilities or {}

        local parent = isInline and inlineCtx.parent or frame.scrollChild
        local yPos   = isInline and inlineCtx.yPos   or -20

        local function RefreshThisPage()
            if isInline then
                InlineRefresh()
            else
                self:ShowSidebarUtilityConfig(frame, raidName, encounterName, encounterType, raidSettings, encounterSettings, true)
            end
        end

        if not isInline then
            local backButton = self.UI:CreateBackButton(parent, "Back", 80, 28)
            backButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
            backButton:SetScript("OnClick", function()
                if frame.bulkTrashMode and frame.bulkTrashMode.active then
                    frame.bulkTrashMode = nil
                    self:ShowSidebarBulkTrashConfig(frame, raidName)
                else
                    self:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings)
                end
            end)

            local header = self:CreateFontString(parent, "OVERLAY", nil, 14)
            header:SetPoint("LEFT", backButton, "RIGHT", 15, 0)
            local mobCount = 0
            if frame.bulkTrashMode and frame.bulkTrashMode.selectedMobs then
                for _ in pairs(frame.bulkTrashMode.selectedMobs) do mobCount = mobCount + 1 end
            end
            if mobCount > 1 then
                header:SetText(RCL["Utility Items ("] .. mobCount .. RCL[" mobs)"])
            else
                header:SetText(RCL["Utility Items - "] .. encounterName)
            end
            do local _ag=RC:GetColor("ui","accentGold"); header:SetTextColor(_ag.r,_ag.g,_ag.b,1) end
            yPos = yPos - 45
        end

        local configuredUtilities = {}
        for key, config in pairs(encounterSettings.abilities) do
            local itemId = tonumber(key)
            if itemId and self.utilityItems and self.utilityItems[itemId] then
                table.insert(configuredUtilities, {id = itemId, key = key, config = config})
            end
        end

        if #configuredUtilities > 0 then
            local configuredCard = self:CreateSettingsCard(parent, yPos, RCL["Configured items"])
            local cardY = -35

            local rowBg = RC:GetColor("ui", "cardBackground")
            local rowHover = GetTabNormalBg()

            table.sort(configuredUtilities, function(a, b)
                return self:ItemLabel(a.id, self.utilityItems[a.id]) < self:ItemLabel(b.id, self.utilityItems[b.id])
            end)

            for _, utility in ipairs(configuredUtilities) do
                local itemData = self.utilityItems[utility.id]
                local utilityKeyRef = tostring(utility.id)

                local row = CreateFrame("Button", nil, configuredCard, "BackdropTemplate")
                row:SetSize(290, 24)
                row:SetPoint("TOPLEFT", configuredCard, "TOPLEFT", 15, cardY)
                row:SetBackdrop({
                    bgFile = RC.UI.FLAT,
                    edgeFile = "Interface\\Buttons\\WHITE8X8",
                    edgeSize = 1,
                })
                row:SetBackdropColor(rowBg.r, rowBg.g, rowBg.b, 1)
                do local _bn = RC:GetColor("ui", "borderNormal"); row:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1) end
                row.rowBg = rowBg
                row.rowHover = rowHover
                RC.UI:AttachHover(row, rowBg, rowHover, {
                    onEnter = function(self)
                        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                        GameTooltip:AddLine(RCL["Click to edit settings"], 1, 0.82, 0)
                        GameTooltip:Show()
                    end,
                    onLeave = function() GameTooltip:Hide() end,
                })

                row:SetScript("OnClick", function()
                    if isInline then
                        local subKey = (inlineCtx and inlineCtx.settingsKey) or encounterName
                        frame._expandedUtilityItem = frame._expandedUtilityItem or {}
                        if frame._expandedUtilityItem[subKey] == utilityKeyRef then
                            frame._expandedUtilityItem[subKey] = nil
                        else
                            frame._expandedUtilityItem[subKey] = utilityKeyRef
                        end
                        InlineRefresh()
                    else
                        self:ShowSidebarAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings, utilityKeyRef, "utility")
                    end
                end)

                local removeBtn = self:CreateXCloseButton(row, 16, function()
                    encounterSettings.abilities[utilityKeyRef] = nil
                    if frame.bulkTrashMode and frame.bulkTrashMode.active then
                        local bulkRaidSettings = RC:GetEditableActiveProfile(raidName)
                        if bulkRaidSettings and bulkRaidSettings.trash then
                            for mobName in pairs(frame.bulkTrashMode.selectedMobs) do
                                if mobName ~= encounterName then
                                    local mobAbilities = bulkRaidSettings.trash[mobName] and
                                                         bulkRaidSettings.trash[mobName].abilities
                                    if mobAbilities then
                                        mobAbilities[utilityKeyRef] = nil
                                    end
                                end
                            end
                        end
                    end
                    if frame._expandedUtilityItem then
                        local subKey = (inlineCtx and inlineCtx.settingsKey) or encounterName
                        if frame._expandedUtilityItem[subKey] == utilityKeyRef then
                            frame._expandedUtilityItem[subKey] = nil
                        end
                    end
                    self:SaveConfigurationToProfile()
                    self:RefreshSidebarProfiles()
                    RefreshThisPage()
                end)
                removeBtn:SetPoint("RIGHT", row, "RIGHT", -3, 0)

                local icon = row:CreateTexture(nil, "ARTWORK")
                icon:SetSize(18, 18)
                icon:SetPoint("LEFT", row, "LEFT", 3, 0)
                icon:SetTexture(self:ItemLabelIcon(utility.id, itemData))
                icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                icon:SetDesaturated(not utility.config.enabled)

                local nameText = self:CreateFontString(row, "OVERLAY", nil, 9)
                nameText:SetPoint("LEFT", icon, "RIGHT", 4, 0)
                nameText:SetPoint("RIGHT", removeBtn, "LEFT", -4, 0)
                nameText:SetJustifyH("LEFT")
                nameText:SetText(self:ItemLabel(utility.id, itemData))
                if utility.config.enabled then
                    nameText:SetTextColor(TEXT.white[1], TEXT.white[2], TEXT.white[3])
                else
                    nameText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                end

                cardY = cardY - 28
            end

            cardY = cardY + 5
            configuredCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - configuredCard:GetHeight() - 15
        end

        if isInline and frame._expandedUtilityItem then
            local subKey = (inlineCtx and inlineCtx.settingsKey) or encounterName
            local expandedUtilKey = frame._expandedUtilityItem[subKey]
            if expandedUtilKey
               and encounterSettings.abilities
               and encounterSettings.abilities[expandedUtilKey]
            then
                local newY = self:ShowSidebarAbilityConfig(
                    frame, raidName, encounterName, encounterType, raidSettings,
                    expandedUtilKey, nil, false,
                    {
                        parent = parent,
                        yPos = yPos,
                        onRefresh = function()
                            InlineRefresh()
                        end,
                    })
                if newY then yPos = newY end
            end
        end

        local addCard = self:CreateSettingsCard(parent, yPos, RCL["Add utility item"])
        local addCardY = -35

        local addDropdown = self.UI:CreateScrollableDropdown(addCard, 280, RCL["Select Item to Add..."], 12)
        addDropdown:SetPoint("TOPLEFT", addCard, "TOPLEFT", 15, addCardY)

        do
            -- One "Target Dummy" (whichever dummy is in the bags when it
            -- fires), then the other utility items you are carrying. While
            -- editing someone else's raid their bags are unknown, so all.
            local _rem = RC.remoteEditMode
            local showAll = (_rem and _rem.raidKey == raidName and RC._remoteEditData) and true or false
            local dummyTaken = false
            for key in pairs(encounterSettings.abilities) do
                if self:IsTargetDummy(key) then dummyTaken = true break end
            end
            local availableItems = {}
            for itemId, itemData in pairs(self.utilityItems or {}) do
                if not self:IsTargetDummy(itemId) and not encounterSettings.abilities[tostring(itemId)]
                   and (showAll or self:CarriesItem(itemId, itemData)) then
                    table.insert(availableItems, {id = itemId, data = itemData})
                end
            end
            table.sort(availableItems, function(a, b) return a.data.name < b.data.name end)

            local addItems = {}
            if not dummyTaken then
                table.insert(addItems, { text = RCL["Target Dummy"], value = "16023", icon = self.TARGET_DUMMY_ICON })
            end
            for _, item in ipairs(availableItems) do
                table.insert(addItems, {
                    text  = self:ItemLabel(item.id, item.data),
                    value = tostring(item.id),
                    icon  = self:ItemLabelIcon(item.id, item.data),
                })
            end
            if #addItems == 0 then
                table.insert(addItems, { text = RCL["Nothing else in your bags"], value = "__none__" })
            end

            addDropdown:SetItems(addItems, function(value)
                if value == "__none__" then return end
                local newKey = value
                encounterSettings.abilities[newKey] = {
                    enabled = true,
                    triggerType = "hp_percent",
                    hpValue = 90,
                    enableTTS = true,
                    utilityType = newKey
                }
                self:SaveConfigurationToProfile()
                self:RefreshSidebarProfiles()
                if isInline then
                    local subKey = (inlineCtx and inlineCtx.settingsKey) or encounterName
                    frame._expandedUtilityItem = frame._expandedUtilityItem or {}
                    frame._expandedUtilityItem[subKey] = newKey
                    InlineRefresh()
                else
                    self:ShowSidebarAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings, newKey, "utility")
                end
            end)
        end
        addCardY = addCardY - 50

        addCard:SetContentHeight(math.abs(addCardY))
        yPos = yPos - addCard:GetHeight() - 20

        if encounterType == "boss" then
            -- pdc[itemId] stores the mode string directly ("death" or
            -- "target"), not a sub-table - see MODE_LABELS below for display.
            if not encounterSettings.postDeathConsumables then
                encounterSettings.postDeathConsumables = {}
            end
            local pdc = encounterSettings.postDeathConsumables

            local pdcCard = self:CreateSettingsCard(parent, yPos, RCL["Consumable reminders"])
            local pdcCardY = -30

            local pdcHelp = self:CreateFontString(pdcCard, "OVERLAY", nil, 10)
            pdcHelp:SetPoint("TOPLEFT", pdcCard, "TOPLEFT", 15, pdcCardY)
            pdcHelp:SetText(RCL["Remind to use consumables at a configurable point around this boss."])
            pdcHelp:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            pdcCardY = pdcCardY - 20

            local hdrName = self:CreateFontString(pdcCard, "OVERLAY", nil, 10)
            hdrName:SetPoint("TOPLEFT", pdcCard, "TOPLEFT", 28, pdcCardY)
            hdrName:SetText(RCL["Item"])
            hdrName:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])

            local hdrWhen = self:CreateFontString(pdcCard, "OVERLAY", nil, 10)
            hdrWhen:SetPoint("TOPRIGHT", pdcCard, "TOPRIGHT", -42, pdcCardY)
            hdrWhen:SetText(RCL["When"])
            hdrWhen:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
            pdcCardY = pdcCardY - 16

            local configuredList = {}
            for itemId, mode in pairs(pdc) do
                local itemName = RC:ItemLabel(itemId, RC:ConsumableRow(itemId))
                local safeMode = (mode == "target") and "target" or "death"
                table.insert(configuredList, {id = itemId, name = itemName, mode = safeMode})
            end
            table.sort(configuredList, function(a, b) return a.name < b.name end)

            local MODE_LABELS = { death = "After kill", target = "On targeting" }

            for _, entry in ipairs(configuredList) do
                local rowId   = entry.id
                local rowName = entry.name
                local rowMode = entry.mode

                local row = CreateFrame("Frame", nil, pdcCard, "BackdropTemplate")
                row:SetHeight(28)
                row:SetPoint("TOPLEFT", pdcCard, "TOPLEFT", 15, pdcCardY)
                row:SetPoint("RIGHT",   pdcCard, "RIGHT",  -15, 0)
                local rowBg = RC:GetColor("ui", "cardBackground")
                row:SetBackdrop({bgFile = RC.UI.FLAT, edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
                row:SetBackdropColor(rowBg.r, rowBg.g, rowBg.b, 1)
                row:SetBackdropBorderColor(0, 0, 0, 0.5)

                local iconTex = row:CreateTexture(nil, "ARTWORK")
                iconTex:SetSize(18, 18)
                iconTex:SetPoint("LEFT", row, "LEFT", 4, 0)
                iconTex:SetTexture(RC:ItemLabelIcon(rowId, RC:ConsumableRow(rowId)))

                local capturedId = rowId
                local removeBtn = self.UI:CreateXCloseButton(row, 18, function()
                    pdc[capturedId] = nil
                    RC:SaveConfigurationToProfile()
                    RefreshThisPage()
                end)
                removeBtn:SetPoint("RIGHT", row, "RIGHT", -3, 0)

                local capturedModeId = rowId
                local currentLabel = (rowMode == "target") and "On target" or "After kill"
                local modeDropdown = self.UI:CreateScrollableDropdown(row, 88, currentLabel, 5)
                modeDropdown:SetPoint("RIGHT", removeBtn, "LEFT", -4, 0)

                do
                    local modeItems = {
                        { text = RCL["After kill"], value = "death" },
                        { text = RCL["On target"], value = "target" },
                    }
                    modeDropdown:SetItems(modeItems, function(value)
                        pdc[capturedModeId] = value
                        RC:SaveConfigurationToProfile()
                    end)
                    modeDropdown:SetSelectedValue(rowMode, currentLabel)
                end

                local rowLabel = self:CreateFontString(row, "OVERLAY", nil, 10)
                rowLabel:SetPoint("LEFT",  row, "LEFT",  26, 0)
                rowLabel:SetPoint("RIGHT", modeDropdown, "LEFT", -4, 0)
                rowLabel:SetText(rowName)
                rowLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                rowLabel:SetJustifyH("LEFT")

                pdcCardY = pdcCardY - 32
            end

            pdcCardY = pdcCardY - 6

            local addConsLabel = self:CreateFontString(pdcCard, "OVERLAY", nil, 10)
            addConsLabel:SetPoint("TOPLEFT", pdcCard, "TOPLEFT", 15, pdcCardY)
            addConsLabel:SetText(RCL["Add:"])
            addConsLabel:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            pdcCardY = pdcCardY - 20

            local pdcDropdown = self.UI:CreateScrollableDropdown(pdcCard, 400, RCL["Category > Item..."], 14)
            pdcDropdown:SetPoint("TOPLEFT", pdcCard, "TOPLEFT", 15, pdcCardY)

            local INCLUDED_CATS = {
                "flasks", "elixirs", "potions", "protectionPotions",
                "food", "drinks", "buffs", "utilities",
            }

            do
                -- What you are carrying (a target dummy always), or
                -- everything while editing someone else's raid.
                local _rem = RC.remoteEditMode
                local showAll = (_rem and _rem.raidKey == raidName and RC._remoteEditData) and true or false
                local dummyTaken = false
                for k in pairs(pdc) do
                    if RC:IsTargetDummy(k) then dummyTaken = true break end
                end
                local pdcItems = {}
                for _, catKey in ipairs(INCLUDED_CATS) do
                    local catData = RC.raidConsumables and RC.raidConsumables[catKey]
                    if catData and catData.items then
                        local sortedItems = {}
                        for itemId, itemData in pairs(catData.items) do
                            local isDummy = RC:IsTargetDummy(itemId)
                            if not pdc[itemId] and not itemData.baseItemId
                               and not (isDummy and dummyTaken)
                               and (showAll or isDummy or RC:CarriesItem(itemId, itemData)) then
                                table.insert(sortedItems, {id = itemId,
                                    name = RC:ItemLabel(itemId, itemData),
                                    icon = RC:ItemLabelIcon(itemId, itemData)})
                            end
                        end
                        table.sort(sortedItems, function(a, b) return a.name < b.name end)
                        for _, item in ipairs(sortedItems) do
                            table.insert(pdcItems, {
                                text  = catData.name .. " - " .. item.name,
                                value = item.id,
                                icon  = item.icon,
                            })
                        end
                    end
                end

                if #pdcItems == 0 then
                    table.insert(pdcItems, { text = RCL["Nothing else in your bags"], value = "__none__" })
                end

                pdcDropdown:SetItems(pdcItems, function(value)
                    if value == "__none__" then return end
                    pdc[value] = "death"
                    RC:SaveConfigurationToProfile()
                    RefreshThisPage()
                end)
            end
            pdcCardY = pdcCardY - 45

            pdcCard:SetContentHeight(math.abs(pdcCardY))
            yPos = yPos - pdcCard:GetHeight() - 20
        end

        if isInline then
            return yPos
        end
        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end

    function RC:ShowSidebarDefensivesConfig(frame, raidName, encounterName, encounterType, raidSettings, encounterSettings, preserveScroll, inlineCtx)
        local isInline = (inlineCtx ~= nil)
        local function InlineRefresh()
            if isInline and inlineCtx.onRefresh then inlineCtx.onRefresh() end
        end

        if not isInline then
            self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
        end

        -- Resolve against the profile being EDITED (theirs while remote
        -- editing, ours otherwise) so these controls change the right config.
        local freshRaidSettings = self:GetEditableActiveProfile(raidName)
        if freshRaidSettings then
            raidSettings = freshRaidSettings
            local lookupKey = encounterName
            if encounterType == "boss" then
                encounterSettings = raidSettings.bosses[lookupKey]
            else
                encounterSettings = raidSettings.trash[lookupKey]
            end
        end

        -- The profile being edited may not have this encounter yet (common
        -- when it belongs to someone else). Without this the page errors on
        -- the first unguarded index below.
        if not encounterSettings then
            self:Print(RCL["ERROR: No encounter settings found for "] .. tostring(encounterName))
            -- Inline callers add this to their own yPos, so every exit owes
            -- them a number. Nothing was drawn here. Reads inlineCtx.yPos
            -- rather than the local yPos: this guard sits ABOVE the `local
            -- yPos` declaration, so that name is still a nil global here.
            if isInline then return inlineCtx.yPos end
            return
        end
        encounterSettings.abilities = encounterSettings.abilities or {}

        local parent = isInline and inlineCtx.parent or frame.scrollChild
        local yPos   = isInline and inlineCtx.yPos   or -20

        if not isInline then
            local backButton = self.UI:CreateBackButton(parent, "Back", 80, 28)
            backButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
            backButton:SetScript("OnClick", function()
                if frame.bulkTrashMode and frame.bulkTrashMode.active then
                    frame.bulkTrashMode = nil
                    self:ShowSidebarBulkTrashConfig(frame, raidName)
                else
                    self:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings)
                end
            end)

            local iconTex = parent:CreateTexture(nil, "ARTWORK")
            iconTex:SetSize(28, 28)
            iconTex:SetPoint("LEFT", backButton, "RIGHT", 15, 0)
            iconTex:SetTexture("Interface\\Icons\\Ability_Warrior_ShieldWall")

            local header = self:CreateFontString(parent, "OVERLAY", nil, 16)
            header:SetPoint("LEFT", iconTex, "RIGHT", 10, 0)
            local mobCount = 0
            if frame.bulkTrashMode and frame.bulkTrashMode.selectedMobs then
                for _ in pairs(frame.bulkTrashMode.selectedMobs) do mobCount = mobCount + 1 end
            end
            if mobCount > 1 then
                header:SetText(RCL["Defensives ("] .. mobCount .. RCL[" mobs)"])
            else
                header:SetText(RCL["Defensives - "] .. encounterName)
            end
            header:SetTextColor(TEXT.gold[1], TEXT.gold[2], TEXT.gold[3])
            yPos = yPos - 50
        end

        -- Same wholesale-overwrite bulk fan-out as ShowTrinketSlotSelection's
        -- BulkSaveConfig above.
        local function BulkSaveDefensive(defKey)
            if frame.bulkTrashMode and frame.bulkTrashMode.active then
                local selectedMobs = frame.bulkTrashMode.selectedMobs
                local bulkRaidSettings = RC:GetEditableActiveProfile(raidName)
                if bulkRaidSettings and bulkRaidSettings.trash then
                    local sourceConfig = encounterSettings.abilities[defKey]
                    for mobName in pairs(selectedMobs) do
                        if mobName ~= encounterName then
                            if not bulkRaidSettings.trash[mobName] then
                                bulkRaidSettings.trash[mobName] = { enabled = false, abilities = {} }
                            end
                            if not bulkRaidSettings.trash[mobName].abilities then
                                bulkRaidSettings.trash[mobName].abilities = {}
                            end
                            bulkRaidSettings.trash[mobName].abilities[defKey] = {}
                            for k, v in pairs(sourceConfig) do
                                bulkRaidSettings.trash[mobName].abilities[defKey][k] = v
                            end
                            local hasAnyEnabled = false
                            for _, ab in pairs(bulkRaidSettings.trash[mobName].abilities) do
                                if ab.enabled then hasAnyEnabled = true break end
                            end
                            bulkRaidSettings.trash[mobName].enabled = hasAnyEnabled
                        end
                    end
                end
            end
            RC:SaveConfigurationToProfile()
            RC:RefreshSidebarProfiles()
        end

        local function RefreshAfterChange(defKey)
            local hasAnyAbility = false
            for _, v in pairs(encounterSettings.abilities) do
                if v and v.enabled then hasAnyAbility = true; break end
            end
            if not hasAnyAbility and encounterSettings.postDeathConsumables
               and next(encounterSettings.postDeathConsumables) then
                hasAnyAbility = true
            end
            encounterSettings.enabled = hasAnyAbility

            BulkSaveDefensive(defKey)
        end

        local function RefreshThisPage()
            if isInline then
                InlineRefresh()
            else
                self:ShowSidebarDefensivesConfig(frame, raidName, encounterName, encounterType, raidSettings, encounterSettings, true)
            end
        end

        local defCard = self:CreateSettingsCard(parent, yPos, RCL["Defensives"])
        local cardY = -35

        local function AddSectionDivider(label)
            cardY = cardY - 8
            local sep = defCard:CreateTexture(nil, "ARTWORK")
            sep:SetPoint("TOPLEFT", defCard, "TOPLEFT", 12,  cardY)
            sep:SetPoint("RIGHT",   defCard, "RIGHT",   -12, 0)
            sep:SetHeight(1)
            local _ac = RC:GetColor("ui", "accentGold") or {r=0.85,g=0.65,b=0.25}
            sep:SetColorTexture(_ac.r, _ac.g, _ac.b, 0.35)
            cardY = cardY - 12
            local lbl = self:CreateFontString(defCard, "OVERLAY", nil, 11)
            lbl:SetPoint("TOPLEFT", defCard, "TOPLEFT", 12, cardY)
            lbl:SetText(label)
            local _hd = RC:GetColor("ui", "headerText") or {r=1,g=0.82,b=0}
            lbl:SetTextColor(_hd.r, _hd.g, _hd.b)
            cardY = cardY - 18
        end

        AddSectionDivider("Last Stand")
        local lsCard = defCard

        if not encounterSettings.abilities["laststand"] then
            encounterSettings.abilities["laststand"] = { enabled = false, triggerType = "player_hp", playerHpValue = 30 }
        end
        local lsConfig = encounterSettings.abilities["laststand"]

        local lsEnable = self.UI:CreateSettingCheckbox(lsCard, cardY, "Enable Last Stand reminder", lsConfig.enabled, function(cb)
            local newState = cb:GetChecked()
            lsConfig.enabled = newState
            lsConfig.enableTTS = newState
            RefreshAfterChange("laststand")
            RefreshThisPage()
        end)
        cardY = cardY - 30

        if lsConfig.enabled then
            local triggerLabel = self:CreateFontString(lsCard, "OVERLAY", nil, 10)
            triggerLabel:SetPoint("TOPLEFT", lsCard, "TOPLEFT", 15, cardY)
            triggerLabel:SetText(RCL["Trigger when:"])
            triggerLabel:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])

            local triggerDropdown = self.UI:CreateScrollableDropdown(lsCard, 150, self.triggerTypes[lsConfig.triggerType] or RCL["Player HP %"], 8)
            triggerDropdown:SetPoint("LEFT", triggerLabel, "RIGHT", 10, 2)
            do
                local triggerOptions = {"player_hp", "combat_start"}
                local triggerItems = {}
                for _, trigType in ipairs(triggerOptions) do
                    table.insert(triggerItems, { text = self.triggerTypes[trigType] or trigType, value = trigType })
                end
                triggerDropdown:SetItems(triggerItems, function(value)
                    lsConfig.triggerType = value
                    RefreshAfterChange("laststand")
                    RefreshThisPage()
                end)
                triggerDropdown:SetSelectedValue(lsConfig.triggerType, self.triggerTypes[lsConfig.triggerType])
            end
            cardY = cardY - 35

            if lsConfig.triggerType == "player_hp" then
                local hpLabel = self:CreateFontString(lsCard, "OVERLAY", nil, 11)
                hpLabel:SetPoint("TOPLEFT", lsCard, "TOPLEFT", 15, cardY)
                hpLabel:SetText(RCL["Player HP %:"])
                hpLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                cardY = cardY - 22

                local valueSlider = self.UI:CreateSlider(lsCard, 5, 80, lsConfig.playerHpValue or 30, 1)
                valueSlider:SetPoint("TOPLEFT", lsCard, "TOPLEFT", 15, cardY)
                valueSlider:SetScript("OnValueChanged", function(slider, value)
                    lsConfig.playerHpValue = math.floor(value)
                end)
                -- save once on release, like the other sliders, not on
                -- every step of the drag
                valueSlider:SetScript("OnMouseUp", function() RefreshAfterChange("laststand") end)
                cardY = cardY - 50
            elseif lsConfig.triggerType == "combat_start" then
                local delayLabel = self:CreateFontString(lsCard, "OVERLAY", nil, 11)
                delayLabel:SetPoint("TOPLEFT", lsCard, "TOPLEFT", 15, cardY)
                delayLabel:SetText(RCL["Seconds into combat:"])
                delayLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                cardY = cardY - 22

                local valueSlider = self.UI:CreateSlider(lsCard, 0, 30, lsConfig.combatStartDelay or 5, 1)
                valueSlider:SetPoint("TOPLEFT", lsCard, "TOPLEFT", 15, cardY)
                valueSlider:SetScript("OnValueChanged", function(slider, value)
                    lsConfig.combatStartDelay = math.floor(value)
                end)
                -- save once on release, like the other sliders, not on
                -- every step of the drag
                valueSlider:SetScript("OnMouseUp", function() RefreshAfterChange("laststand") end)
                cardY = cardY - 50
            end
        end

        cardY = cardY + 5

        AddSectionDivider("Shield Wall")
        local swCard = defCard

        if not encounterSettings.abilities["shieldwall"] then
            encounterSettings.abilities["shieldwall"] = { enabled = false, triggerType = "player_hp", playerHpValue = 20 }
        end
        local swConfig = encounterSettings.abilities["shieldwall"]

        local swEnable = self.UI:CreateSettingCheckbox(swCard, cardY, "Enable Shield Wall reminder", swConfig.enabled, function(cb)
            local newState = cb:GetChecked()
            swConfig.enabled = newState
            swConfig.enableTTS = newState
            RefreshAfterChange("shieldwall")
            RefreshThisPage()
        end)
        cardY = cardY - 30

        if swConfig.enabled then
            local triggerLabel = self:CreateFontString(swCard, "OVERLAY", nil, 10)
            triggerLabel:SetPoint("TOPLEFT", swCard, "TOPLEFT", 15, cardY)
            triggerLabel:SetText(RCL["Trigger when:"])
            triggerLabel:SetTextColor(TEXT.normal[1], TEXT.normal[2], TEXT.normal[3])

            local triggerDropdown = self.UI:CreateScrollableDropdown(swCard, 150, self.triggerTypes[swConfig.triggerType] or RCL["Player HP %"], 8)
            triggerDropdown:SetPoint("LEFT", triggerLabel, "RIGHT", 10, 2)
            do
                local triggerOptions = {"player_hp", "combat_start"}
                local triggerItems = {}
                for _, trigType in ipairs(triggerOptions) do
                    table.insert(triggerItems, { text = self.triggerTypes[trigType] or trigType, value = trigType })
                end
                triggerDropdown:SetItems(triggerItems, function(value)
                    swConfig.triggerType = value
                    RefreshAfterChange("shieldwall")
                    RefreshThisPage()
                end)
                triggerDropdown:SetSelectedValue(swConfig.triggerType, self.triggerTypes[swConfig.triggerType])
            end
            cardY = cardY - 35

            if swConfig.triggerType == "player_hp" then
                local hpLabel = self:CreateFontString(swCard, "OVERLAY", nil, 11)
                hpLabel:SetPoint("TOPLEFT", swCard, "TOPLEFT", 15, cardY)
                hpLabel:SetText(RCL["Player HP %:"])
                hpLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                cardY = cardY - 22

                local valueSlider = self.UI:CreateSlider(swCard, 5, 80, swConfig.playerHpValue or 20, 1)
                valueSlider:SetPoint("TOPLEFT", swCard, "TOPLEFT", 15, cardY)
                valueSlider:SetScript("OnValueChanged", function(slider, value)
                    swConfig.playerHpValue = math.floor(value)
                end)
                -- save once on release, like the other sliders, not on
                -- every step of the drag
                valueSlider:SetScript("OnMouseUp", function() RefreshAfterChange("shieldwall") end)
                cardY = cardY - 50
            elseif swConfig.triggerType == "combat_start" then
                local delayLabel = self:CreateFontString(swCard, "OVERLAY", nil, 11)
                delayLabel:SetPoint("TOPLEFT", swCard, "TOPLEFT", 15, cardY)
                delayLabel:SetText(RCL["Seconds into combat:"])
                delayLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
                cardY = cardY - 22

                local valueSlider = self.UI:CreateSlider(swCard, 0, 30, swConfig.combatStartDelay or 5, 1)
                valueSlider:SetPoint("TOPLEFT", swCard, "TOPLEFT", 15, cardY)
                valueSlider:SetScript("OnValueChanged", function(slider, value)
                    swConfig.combatStartDelay = math.floor(value)
                end)
                -- save once on release, like the other sliders, not on
                -- every step of the drag
                valueSlider:SetScript("OnMouseUp", function() RefreshAfterChange("shieldwall") end)
                cardY = cardY - 50
            end
        end

        cardY = cardY + 5
        defCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - defCard:GetHeight() - 20

        if isInline then
            return yPos
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end

    -- ABILITY REMINDER PREVIEW: this ability's reminder icon, drawn by the
    -- reminder popup's own constructors (Readycheck_Reminders) with the
    -- global icon look; Replay plays its entrance as this ability resolves
    -- it (its own animation override, else the global one). Only on the
    -- ability's own page, and only with the reminders addon loaded.
    local AB_W, AB_H = 94, 94   -- one 80 px icon; update sizes the canvas to it
    local function AbilityIconTexture(key)
        local d = RC.abilityData and RC.abilityData[key]
        local tex = d and d.icon
        if d and d.spellId and GetSpellTexture then tex = GetSpellTexture(d.spellId) or tex end
        return tex or "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    local function AbPreviewBuild(canvas, P)
        local holder = CreateFrame("Frame", nil, canvas)
        holder:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        holder:SetSize(AB_W - 20, AB_H - 20)
        P.store.holder = holder
        P.store.token = 0
    end
    local function AbPreviewUpdate(canvas, P)
        local st, db = P.store, RC.db
        if not RC.CreateReminderIcon then return end
        local size = math.max(8, db.iconSize or 80)
        -- the icon at its real size (its label hangs a few px under the
        -- ring); the canvas is that box and the strip scales it
        if st.size ~= size then
            RC.Motion.Stop(st.holder)
            st.holder:SetScale(1)
            st.holder:SetSize(size + 14, size + 14)
            st.size = size
        end
        if P.Resize then P.Resize(size + 14, size + 14) end
        if not st.icon then st.icon = RC:CreateReminderIcon(st.holder, size) end
        local icon = st.icon
        icon:SetSize(size, size)
        icon.originalSize = size
        RC.UI:DressReadyIcon(icon, size)
        icon.texture:SetTexture(AbilityIconTexture(RC._abPreviewKey))
        icon:ClearAllPoints()
        icon:SetPoint("CENTER", st.holder, "CENTER", 0, 0)
        icon:Show()
        if db.showIconText and RC.EnsureReminderIconText then
            RC:EnsureReminderIconText(icon)
            icon.cooldownText:SetWidth(size)
            RC:SetReminderIconLabel(icon, RC._abPreviewKey == "frostBlast" and "REMOVE" or "USE",
                RC._abPreviewKey == "frostBlast" and "orange" or "green")
            icon.cooldownText:Show()
        elseif icon.cooldownText then
            icon.cooldownText:Hide()
        end
        RC.UI:SetReadyIconGlow(icon, db.iconGlow or "pulse")
    end
    local function AbPreviewReplay(canvas, P)
        local st = P.store
        if not (st.holder and RC.GetReminderMotion) then return end
        local M = RC.Motion
        st.token = st.token + 1
        local t = st.token
        M.Stop(st.holder)
        st.holder:Hide()
        local inSpec = RC:GetReminderMotion("in", { RC._abPreviewKey })
        M.Show(st.holder, inSpec)
        C_Timer.After(M.Duration(inSpec.duration) + M.Duration(inSpec.delay or 0) + 1.2, function()
            if t ~= st.token or not st.holder:IsVisible() then return end
            local outSpec = RC:GetReminderMotion("out", { RC._abPreviewKey })
            M.Hide(st.holder, outSpec)
            C_Timer.After(M.Duration(outSpec.duration) + M.Duration(outSpec.delay or 0) + 0.4, function()
                if t ~= st.token then return end
                M.Stop(st.holder)
                if canvas:IsVisible() then st.holder:Show() end
            end)
        end)
    end

    function RC:ShowSidebarAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings, abilityKey, returnTo, preserveScroll, inlineCtx)
        local isInline = (inlineCtx ~= nil)
        local function InlineRefresh()
            if isInline and inlineCtx.onRefresh then inlineCtx.onRefresh() end
        end

        if not isInline then
            self:ClearSidebarContent(self.sidebarConfigFrame, preserveScroll)
            if self.CreateReminderIcon and type(abilityKey) == "string" then
                self._abPreviewKey = abilityKey
                self.UI:DeclarePreview({
                    key = "raids.ability", title = RCL["This reminder"],
                    width = AB_W, height = AB_H,
                    build = AbPreviewBuild, update = AbPreviewUpdate, replay = AbPreviewReplay,
                })
            end
        end

        if returnTo and not isInline then
            frame.abilityConfigReturnTo = returnTo
        end
        local currentReturnTo = frame.abilityConfigReturnTo

        local parent = isInline and inlineCtx.parent or frame.scrollChild
        local yPos   = isInline and inlineCtx.yPos   or -20

        -- The profile being edited: the remote toon's while a remote edit
        -- of this raid is open, otherwise ours (RaidProfilesSystem.lua).
        do
            local p = self:GetEditableActiveProfile(raidName)
            if p then raidSettings = p end
        end

        local effectiveEncounterName = encounterName

        local encounterSettings
        if encounterType == "boss" then
            encounterSettings = raidSettings.bosses[effectiveEncounterName]
        else
            encounterSettings = raidSettings.trash[effectiveEncounterName]
        end

        if not encounterSettings or not encounterSettings.abilities then
            self:Print(RCL["ERROR: No encounter settings for "] .. effectiveEncounterName)
            -- Inline callers add this to their own yPos, so every exit owes
            -- them a number. Nothing was drawn here.
            if isInline then return yPos end
            return
        end

        local isPotionAbility = (type(abilityKey) == "string" and abilityKey:lower():find("potion") and abilityKey ~= "freeActionPotion")

        if isPotionAbility then
            local existingConfig = encounterSettings.abilities[abilityKey]
            if existingConfig then
                self:DebugPrint(string.format(RCL["POTION CONFIG LOAD (BEFORE): %s | enabled=%s | triggerType=%s | potionType=%s | hpValue=%s | combatStartDelay=%s"],
                    abilityKey,
                    tostring(existingConfig.enabled),
                    tostring(existingConfig.triggerType),
                    tostring(existingConfig.potionType),
                    tostring(existingConfig.hpValue),
                    tostring(existingConfig.combatStartDelay)), "config")
            else
                self:DebugPrint(string.format(RCL["POTION CONFIG LOAD: %s does NOT exist yet"], abilityKey), "config")
            end
        end

        if not encounterSettings.abilities[abilityKey] then
            local newConfig = { enabled = true, triggerType = "hp_percent" }
            if isPotionAbility then
                newConfig.potionType = "mightyRagePotion"
                newConfig.hpValue = 20
            end
            encounterSettings.abilities[abilityKey] = newConfig
        elseif isPotionAbility and not encounterSettings.abilities[abilityKey].potionType then
            encounterSettings.abilities[abilityKey].potionType = "mightyRagePotion"
            self:SaveConfigurationToProfile()
        end
        local abilityConfig = encounterSettings.abilities[abilityKey]

        -- Same wholesale-overwrite bulk fan-out as ShowTrinketSlotSelection's
        -- BulkSaveConfig above, keyed on abilityKey instead of a fixed slot.
        local function BulkSaveConfig()
            if frame.bulkTrashMode and frame.bulkTrashMode.active then
                local selectedMobs = frame.bulkTrashMode.selectedMobs
                local bulkRaidName = frame.bulkTrashMode.raidName
                local bulkRaidSettings = RC:GetEditableActiveProfile(bulkRaidName)
                if bulkRaidSettings and bulkRaidSettings.trash then
                    for mobName in pairs(selectedMobs) do
                        if mobName ~= encounterName then
                            if not bulkRaidSettings.trash[mobName] then
                                bulkRaidSettings.trash[mobName] = { enabled = false, abilities = {} }
                            end
                            if not bulkRaidSettings.trash[mobName].abilities then
                                bulkRaidSettings.trash[mobName].abilities = {}
                            end
                            bulkRaidSettings.trash[mobName].abilities[abilityKey] = {}
                            for k, v in pairs(abilityConfig) do
                                bulkRaidSettings.trash[mobName].abilities[abilityKey][k] = v
                            end
                            local hasAnyEnabled = false
                            for _, ab in pairs(bulkRaidSettings.trash[mobName].abilities) do
                                if ab.enabled then hasAnyEnabled = true break end
                            end
                            bulkRaidSettings.trash[mobName].enabled = hasAnyEnabled
                        end
                    end
                end
            end
            RC:SaveConfigurationToProfile()
            RC:RefreshSidebarProfiles()
        end

        frame.BulkSaveConfig = BulkSaveConfig

        local abilityData = self.abilityData and self.abilityData[abilityKey] or nil
        local displayName = abilityData and abilityData.name or abilityKey
        local abilityIcon = abilityData and abilityData.icon or nil

        local itemId = tonumber(abilityKey)
        if itemId and self.utilityItems and self.utilityItems[itemId] then
            local itemData = self.utilityItems[itemId]
            displayName = self:ItemLabel(itemId, itemData)
            abilityIcon = self:ItemLabelIcon(itemId, itemData)
        elseif abilityKey == "potion" or (type(abilityKey) == "string" and abilityKey:lower():find("potion") and abilityKey ~= "freeActionPotion") then
            displayName = "Consumable Potion"
            abilityIcon = "Interface\\Icons\\INV_Potion_41"
        elseif abilityKey == "freeActionPotion" then
            displayName = "Free Action Potion"
            abilityIcon = "Interface\\Icons\\INV_Potion_04"
        elseif abilityKey == "utility" then
            displayName = "Utility Item"
            abilityIcon = "Interface\\Icons\\INV_Misc_Bomb_08"
        elseif abilityKey == "gearswap" then
            displayName = "Gear Swap"
            abilityIcon = "Interface\\Icons\\INV_Chest_Chain_05"
        end

        if not isInline then
            local backButton = self.UI:CreateBackButton(parent, "Back", 80, 28)
            backButton:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
            backButton:SetScript("OnClick", function()
                frame.abilityConfigReturnTo = nil

                if frame.bulkTrashMode and frame.bulkTrashMode.active then
                    frame.bulkTrashMode = nil
                    self:ShowSidebarBulkTrashConfig(frame, raidName)
                elseif currentReturnTo == "utility" then
                    self:ShowSidebarUtilityConfig(frame, raidName, encounterName, encounterType, raidSettings, encounterSettings)
                elseif currentReturnTo == "trinket" then
                    self:ShowTrinketSlotSelection(frame, raidName, encounterName, encounterType, raidSettings, encounterSettings)
                elseif currentReturnTo == "defensives" then
                    self:ShowSidebarDefensivesConfig(frame, raidName, encounterName, encounterType, raidSettings, encounterSettings)
                else
                    self:ShowInlineAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings)
                end
            end)

            local headerFrame = CreateFrame("Frame", nil, parent)
            headerFrame:SetPoint("TOPLEFT",  parent, "TOPLEFT",  20, yPos)
            headerFrame:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -10, yPos)
            headerFrame:SetHeight(54)

            local BACK_W = 70
            backButton:SetParent(headerFrame)
            backButton:ClearAllPoints()
            backButton:SetPoint("TOPLEFT", headerFrame, "TOPLEFT", 0, -4)
            backButton:SetSize(BACK_W, 26)

            local contentX = BACK_W + 12
            if abilityIcon then
                local iconTex = headerFrame:CreateTexture(nil, "ARTWORK")
                iconTex:SetSize(30, 30)
                iconTex:SetPoint("TOPLEFT", headerFrame, "TOPLEFT", contentX, -2)
                iconTex:SetTexture(abilityIcon)
                iconTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                contentX = contentX + 38
            end

            local header = self:CreateFontString(headerFrame, "OVERLAY", nil, 17)
            header:SetPoint("TOPLEFT", headerFrame, "TOPLEFT", contentX, -2)
            header:SetPoint("RIGHT",   headerFrame, "RIGHT",   -10, 0)
            header:SetJustifyH("LEFT")
            header:SetText(displayName)
            local _hdrCol = RC:GetColor("ui", "headerText") or {r=1, g=0.82, b=0}
            header:SetTextColor(_hdrCol.r, _hdrCol.g, _hdrCol.b, 1)

            local subtitleText = abilityData and abilityData.description
            if subtitleText and subtitleText ~= "" and abilityData.cooldown then
                subtitleText = subtitleText .. "   |cFF808080(" .. abilityData.cooldown .. "s CD)|r"
            end
            if not subtitleText or subtitleText == "" then
                local bossLabel = encounterName or "this encounter"
                subtitleText = (encounterType == "boss" and "Per-boss configuration - " or "Per-mob configuration - ") .. bossLabel
            end
            local sub = self:CreateFontString(headerFrame, "OVERLAY", nil, 11)
            sub:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -2)
            sub:SetPoint("RIGHT",   headerFrame, "RIGHT",  -10, 0)
            sub:SetJustifyH("LEFT")
            sub:SetWordWrap(false)
            sub:SetText(subtitleText)
            sub:SetTextColor(1, 1, 1, 1)
            local _grayCol = RC:GetColor("text", "gray") or {r=0.6, g=0.6, b=0.6}
            if not (abilityData and abilityData.description and abilityData.description ~= "") then
                sub:SetTextColor(_grayCol.r, _grayCol.g, _grayCol.b, 1)
            end

            local accentLine = headerFrame:CreateTexture(nil, "ARTWORK")
            accentLine:SetPoint("BOTTOMLEFT",  headerFrame, "BOTTOMLEFT",  0, 0)
            accentLine:SetPoint("BOTTOMRIGHT", headerFrame, "BOTTOMRIGHT", 0, 0)
            accentLine:SetHeight(1)
            local _accent = RC:GetColor("ui", "accentGold") or {r=0.85, g=0.65, b=0.25, a=0.6}
            accentLine:SetColorTexture(_accent.r, _accent.g, _accent.b, _accent.a or 0.6)

            yPos = yPos - 60
        end

        local function HasEnabledAbilities()
            if encounterSettings.abilities then
                for k, v in pairs(encounterSettings.abilities) do
                    if v and v.enabled then return true end
                end
            end
            if encounterSettings.postDeathConsumables
               and next(encounterSettings.postDeathConsumables) then
                return true
            end
            return false
        end

        local function UpdateEncounterEnabled()
            local hasAbilities = HasEnabledAbilities()
            if encounterSettings.enabled ~= hasAbilities then
                encounterSettings.enabled = hasAbilities
            end
        end

        local cfgCard = self:CreateSettingsCard(parent, yPos, displayName)
        local cardY = -35

        local function AddSectionDivider(label)
            cardY = cardY - 8
            local sep = cfgCard:CreateTexture(nil, "ARTWORK")
            sep:SetPoint("TOPLEFT", cfgCard, "TOPLEFT", 12,  cardY)
            sep:SetPoint("RIGHT",   cfgCard, "RIGHT",   -12, 0)
            sep:SetHeight(1)
            local _ac = RC:GetColor("ui", "accentGold") or {r=0.85,g=0.65,b=0.25}
            sep:SetColorTexture(_ac.r, _ac.g, _ac.b, 0.35)
            cardY = cardY - 12
            local lbl = self:CreateFontString(cfgCard, "OVERLAY", nil, 11)
            lbl:SetPoint("TOPLEFT", cfgCard, "TOPLEFT", 12, cardY)
            lbl:SetText(label)
            local _hd = RC:GetColor("ui", "headerText") or {r=1,g=0.82,b=0}
            lbl:SetTextColor(_hd.r, _hd.g, _hd.b)
            cardY = cardY - 18
        end

        local function CloseConfigCard()
            cardY = cardY - 5
            cfgCard:SetContentHeight(math.abs(cardY))
            yPos = yPos - cfgCard:GetHeight() - 15
        end

        -- A setting's label in front of its control on the same row when
        -- it fits there, else on its own row above it (long labels). The
        -- control then goes at rowX. offY lines the label up with the
        -- control: a dropdown's text, or a slider's track.
        local CTRL_X = 175
        local rowX = 15
        local function LabelRow(label, offY)
            local w = label.GetStringWidth and label:GetStringWidth() or 999
            if w > 0 and w <= CTRL_X - 30 then
                label:ClearAllPoints()
                label:SetPoint("TOPLEFT", cfgCard, "TOPLEFT", 15, cardY - (offY or 5))
                rowX = CTRL_X
                return cardY
            end
            rowX = 15
            return cardY - 22
        end

        local basicCard = cfgCard

        local enableCheck = self.UI:CreateCheckbox(basicCard, RCL["Enable "] .. displayName, abilityConfig.enabled)
        enableCheck:SetPoint("TOPLEFT", basicCard, "TOPLEFT", 15, cardY)
        enableCheck:SetScript("OnClick", function(cb)
            local newState = cb:GetChecked()
            abilityConfig.enabled = newState
            abilityConfig.enableTTS = newState
            RC:DebugPrint(abilityKey .. " enabled = " .. tostring(newState) .. ", TTS = " .. tostring(newState), "config")
            UpdateEncounterEnabled()
            BulkSaveConfig()
            if isInline then
                InlineRefresh()
            else
                RC:ShowSidebarAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings, abilityKey, nil, true)
            end
        end)

        local ttsCheck = self.UI:CreateSettingCheckbox(basicCard, cardY, "Enable Text-to-Speech", abilityConfig.enableTTS or false, function(cb)
            local newState = cb:GetChecked()
            encounterSettings.abilities[abilityKey].enableTTS = newState
            RC:ForceCheckboxUpdate(cb, newState)
            BulkSaveConfig()
        end)
        ttsCheck:ClearAllPoints()
        ttsCheck:SetPoint("TOPLEFT", basicCard, "TOPLEFT",
            math.max(180, math.floor((basicCard:GetWidth() or 480) * 0.5)), cardY)
        cardY = cardY - 30
        self.UI:BindDependents(enableCheck, { ttsCheck }, { indent = 0 })

        if not abilityConfig.enabled then
            local disabledText = self:CreateFontString(basicCard, "OVERLAY", nil, 11)
            disabledText:SetPoint("TOPLEFT", basicCard, "TOPLEFT", 15, cardY)
            disabledText:SetText(RCL["Enable "] .. displayName .. RCL[" above to configure trigger settings"])
            disabledText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            cardY = cardY - 15
            CloseConfigCard()

            if isInline then
                return yPos
            end
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            return
        end

        -- The text on the icon: one row, label in front, a gray "USE" in
        -- the empty box standing for the default. Saved on Enter and when
        -- the box loses focus. Last on the page - the trigger comes first.
        local function AddReminderText()
            AddSectionDivider("Reminder Text")
            local textCard = cfgCard
            local tLbl = self:CreateFontString(textCard, "OVERLAY", nil, 11)
            tLbl:SetPoint("TOPLEFT", textCard, "TOPLEFT", 15, cardY)
            tLbl:SetText(RCL["Text on the icon:"])
            tLbl:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = LabelRow(tLbl, 5)

            local tbBg = self:GetColor("ui","cardBackground")
            local textBox = self.UI:CreateBackedEditBox(textCard, {
                height = 24, fontSize = 11, fontFlags = "", insets = 6,
                bgColor = { tbBg.r * 0.6, tbBg.g * 0.6, tbBg.b * 0.6, 1 },
            })
            textBox:SetPoint("TOPLEFT", textCard, "TOPLEFT", rowX, cardY)
            textBox:SetPoint("TOPRIGHT", textCard, "TOPRIGHT", -87, cardY)
            textBox:SetText(abilityConfig.textOverride or "")

            local ph = self:CreateFontString(textBox, "OVERLAY", nil, 11)
            ph:SetPoint("LEFT", textBox, "LEFT", 6, 0)
            ph:SetText(RCL["USE (default)"])
            ph:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            local function SyncPlaceholder()
                ph:SetShown((textBox:GetText() or "") == "" and not textBox:HasFocus())
            end
            local function SaveText()
                local txt = textBox:GetText() or ""
                local new = (txt ~= "") and txt or nil
                if abilityConfig.textOverride ~= new then
                    abilityConfig.textOverride = new
                    BulkSaveConfig()
                end
            end
            textBox:SetScript("OnEnterPressed", function()
                SaveText()
                textBox:ClearFocus()
            end)
            textBox:HookScript("OnEditFocusGained", SyncPlaceholder)
            textBox:HookScript("OnEditFocusLost", function() SaveText(); SyncPlaceholder() end)
            textBox:HookScript("OnTextChanged", SyncPlaceholder)
            textBox:HookScript("OnEnter", function(eb)
                GameTooltip:SetOwner(eb, "ANCHOR_TOP")
                GameTooltip:SetText(RCL["Text on the icon"], 1, 1, 1)
                GameTooltip:AddLine(RCL["Shown under the icon when this reminder fires. Leave it empty for the default (\"USE\")."], 0.8, 0.8, 0.8, true)
                GameTooltip:Show()
            end)
            textBox:HookScript("OnLeave", function() GameTooltip:Hide() end)
            SyncPlaceholder()

            local clearBtn = self.UI:CreateStyledButton(textCard, RCL["Clear"], 60, 22)
            clearBtn:SetPoint("TOPRIGHT", textCard, "TOPRIGHT", -15, cardY)
            clearBtn:SetScript("OnClick", function()
                abilityConfig.textOverride = nil
                textBox:SetText("")
                textBox:ClearFocus()
                SyncPlaceholder()
                BulkSaveConfig()
            end)

            cardY = cardY - 32
        end

        if type(abilityKey) == "string" and abilityKey:lower():find("potion") and abilityKey ~= "freeActionPotion" then
            AddSectionDivider("Potion Type")
            local potionCard = cfgCard

            local potionLabel = self:CreateFontString(potionCard, "OVERLAY", nil, 11)
            potionLabel:SetPoint("TOPLEFT", potionCard, "TOPLEFT", 15, cardY)
            potionLabel:SetText(RCL["Potion:"])
            potionLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = LabelRow(potionLabel, 5)

            local potionDropdown = self.UI:CreateScrollableDropdown(potionCard, 280, RCL["Select Potion..."], 12)
            potionDropdown:SetPoint("TOPLEFT", potionCard, "TOPLEFT", rowX, cardY)

            local currentPotion = abilityConfig.potionType
            self:DebugPrint(string.format(RCL["POTION LOAD: %s.potionType = %s"],
                tostring(abilityKey), tostring(currentPotion)), "config")
            if not currentPotion or currentPotion == "" or currentPotion == "potion" then
                currentPotion = "mightyRagePotion"
            end
            local potionName = RC.availablePotions and RC.availablePotions[currentPotion] or currentPotion
            do
                local potionOrder = RC.potionDisplayOrder or {}
                if #potionOrder == 0 and RC.availablePotions then
                    for k in pairs(RC.availablePotions) do
                        table.insert(potionOrder, k)
                    end
                end
                local potionItems = {}
                for _, potionKey in ipairs(potionOrder) do
                    local potionDisplayName = RC.availablePotions and RC.availablePotions[potionKey]
                    if potionDisplayName then
                        table.insert(potionItems, {
                            text  = potionDisplayName,
                            value = potionKey,
                            icon  = RC.potionIcons and RC.potionIcons[potionKey] or nil,
                        })
                    end
                end
                potionDropdown:SetItems(potionItems, function(value)
                    RC:DebugPrint(string.format("=== POTION SAVE START ==="), "config")
                    RC:DebugPrint(string.format(RCL["  BEFORE: potionType=%s triggerType=%s hpValue=%s combatStartDelay=%s"],
                        tostring(abilityConfig.potionType),
                        tostring(abilityConfig.triggerType),
                        tostring(abilityConfig.hpValue),
                        tostring(abilityConfig.combatStartDelay)), "config")

                    abilityConfig.potionType = value

                    RC:DebugPrint(string.format(RCL["  AFTER: potionType=%s triggerType=%s hpValue=%s combatStartDelay=%s"],
                        tostring(abilityConfig.potionType),
                        tostring(abilityConfig.triggerType),
                        tostring(abilityConfig.hpValue),
                        tostring(abilityConfig.combatStartDelay)), "config")
                    RC:DebugPrint(string.format("=== POTION SAVE END ==="), "config")
                    BulkSaveConfig()
                end)
                potionDropdown:SetSelectedValue(currentPotion, potionName)
            end
            cardY = cardY - 34
        end

        if abilityKey == "gearswap" then
            AddSectionDivider("Gear Swap Settings")
            local gearCard = cfgCard

            local preGearLabel = self:CreateFontString(gearCard, "OVERLAY", nil, 11)
            preGearLabel:SetPoint("TOPLEFT", gearCard, "TOPLEFT", 15, cardY)
            preGearLabel:SetText(RCL["When Targeting "] .. encounterName .. ":")
            preGearLabel:SetTextColor(TEXT.yellowLight[1], TEXT.yellowLight[2], TEXT.yellowLight[3])
            cardY = cardY - 22

            local currentSet = abilityConfig.gearSet or abilityConfig.itemRackSet or ""
            local displayText = currentSet ~= "" and currentSet or "None (Don't swap)"

            local DEFAULT_SET_ICON = "Interface\\Icons\\INV_Chest_Plate16"
            local function BuildGearSetItems(currentVal, noneText)
                local items = { { text = noneText, value = "" } }
                local GM = RC.GearManager
                if GM and GM.sets then
                    local sortedSets = {}
                    for setName in pairs(GM.sets) do table.insert(sortedSets, setName) end
                    table.sort(sortedSets)
                    for _, setName in ipairs(sortedSets) do
                        local setData = GM.sets[setName]
                        table.insert(items, { text = setName, value = setName, icon = RC:GetGearSetIcon(setName) or DEFAULT_SET_ICON })
                    end
                end
                if ItemRackUser and ItemRackUser.Sets then
                    local sortedSets = {}
                    for setName in pairs(ItemRackUser.Sets) do
                        if not setName:find("^~") then table.insert(sortedSets, setName) end
                    end
                    table.sort(sortedSets)
                    for _, setName in ipairs(sortedSets) do
                        local irSet = ItemRackUser.Sets[setName]
                        table.insert(items, { text = setName .. " (ItemRack)", value = "ItemRack:" .. setName, icon = RC:GetGearSetIcon(setName) or DEFAULT_SET_ICON })
                    end
                end
                return items
            end

            local gearSetDropdown = self.UI:CreateScrollableDropdown(gearCard, 280, displayText, 12)
            gearSetDropdown:SetEmptyText(RCL["No gear sets yet"], RCL["Build one on the Gear Sets page, then pick it here."])
            gearSetDropdown:SetPoint("TOPLEFT", gearCard, "TOPLEFT", 15, cardY)
            gearSetDropdown:SetItems(BuildGearSetItems(currentSet, "None (Don't swap)"), function(value)
                if value == "" then
                    abilityConfig.gearSet = ""
                    abilityConfig.itemRackSet = nil
                elseif value:find("^ItemRack:") then
                    abilityConfig.gearSet = value
                    abilityConfig.itemRackSet = value:gsub("^ItemRack:", "")
                else
                    abilityConfig.gearSet = value
                    abilityConfig.itemRackSet = value
                end
                BulkSaveConfig()
            end)
            gearSetDropdown:SetSelectedValue(currentSet, displayText)
            if currentSet ~= "" and gearSetDropdown.SetSelectedIcon then gearSetDropdown:SetSelectedIcon(RC:GetGearSetIcon(currentSet)) end
            cardY = cardY - 45

            local postGearLabel = self:CreateFontString(gearCard, "OVERLAY", nil, 11)
            postGearLabel:SetPoint("TOPLEFT", gearCard, "TOPLEFT", 15, cardY)
            postGearLabel:SetText(RCL["After "] .. encounterName .. RCL[" Dies:"])
            postGearLabel:SetTextColor(TEXT.yellowLight[1], TEXT.yellowLight[2], TEXT.yellowLight[3])
            cardY = cardY - 22

            local currentPostSet = abilityConfig.postCombatSet or ""
            local postDisplayText = currentPostSet ~= "" and currentPostSet or "Keep Current Gear"

            local postGearDropdown = self.UI:CreateScrollableDropdown(gearCard, 280, postDisplayText, 12)
            postGearDropdown:SetEmptyText(RCL["No gear sets yet"], RCL["Build one on the Gear Sets page, then pick it here."])
            postGearDropdown:SetPoint("TOPLEFT", gearCard, "TOPLEFT", 15, cardY)
            postGearDropdown:SetItems(BuildGearSetItems(currentPostSet, "Keep Current Gear"), function(value)
                if value == "" then
                    abilityConfig.postCombatSet = nil
                    abilityConfig.postCombatSwap = false
                else
                    abilityConfig.postCombatSet = value
                    abilityConfig.postCombatSwap = true
                end
                BulkSaveConfig()
            end)
            postGearDropdown:SetSelectedValue(currentPostSet, postDisplayText)
            if currentPostSet ~= "" and postGearDropdown.SetSelectedIcon then postGearDropdown:SetSelectedIcon(RC:GetGearSetIcon(currentPostSet)) end
            cardY = cardY - 45

            local gearHelpText = self:CreateFontString(gearCard, "OVERLAY", nil, 10)
            gearHelpText:SetPoint("TOPLEFT", gearCard, "TOPLEFT", 15, cardY)
            gearHelpText:SetWidth(280)
            gearHelpText:SetText(RCL["Gear swaps only work out of combat. Target boss before pulling."])
            gearHelpText:SetTextColor(TEXT.medGray[1], TEXT.medGray[2], TEXT.medGray[3])
            cardY = cardY - 30

            AddReminderText()
            CloseConfigCard()
            if isInline then
                return yPos
            end
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
            return
        end

        AddSectionDivider("When to Remind")
        local triggerCard = cfgCard

        local triggerLabel = self:CreateFontString(triggerCard, "OVERLAY", nil, 11)
        triggerLabel:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", 15, cardY)
        triggerLabel:SetText(RCL["Trigger:"])
        triggerLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
        cardY = LabelRow(triggerLabel, 5)

        local displayTriggerType = abilityConfig.triggerType or "hp_percent"

        local triggerDropdown = self.UI:CreateScrollableDropdown(triggerCard, 280, RCL["Select Trigger..."], 12)
        triggerDropdown:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", rowX, cardY)

        local currentTriggerName = self.triggerTypes and self.triggerTypes[displayTriggerType] or "Target HP %"
        do
            local triggerItems = {}
            -- Hardcoded per-ability trigger allowlist: a new ability that
            -- needs its trigger-type choices restricted has to be added here
            -- explicitly, there's no data-driven list to extend instead.
            for triggerKey, triggerName in pairs(RC.triggerTypes or {}) do
                local showTrigger = true
                if abilityKey == "freeActionPotion" and triggerKey ~= "debuff_present" and triggerKey ~= "hp_percent" then
                    showTrigger = false
                elseif abilityKey == "frostBlast" and triggerKey ~= "player_hp_above" then
                    showTrigger = false
                end
                if showTrigger then
                    table.insert(triggerItems, { text = triggerName, value = triggerKey })
                end
            end
            triggerDropdown:SetItems(triggerItems, function(value)
                abilityConfig.triggerType = value
                -- save the number the page shows, so the page and the
                -- reminder can never disagree about an untouched slider
                if value == "ttk" and abilityConfig.ttkValue == nil then
                    abilityConfig.ttkValue = DefaultTTKValue(abilityKey)
                end
                BulkSaveConfig()
                if isInline then
                    InlineRefresh()
                else
                    RC:ShowSidebarAbilityConfig(frame, raidName, encounterName, encounterType, raidSettings, abilityKey, nil, true)
                end
            end)
            triggerDropdown:SetSelectedValue(displayTriggerType, currentTriggerName)
        end
        cardY = cardY - 34

        local triggerType = displayTriggerType

        if triggerType == "hp_percent" then
            local displayHpValue = abilityConfig.hpValue or 20

            local label = self:CreateFontString(triggerCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Target HP %:"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = LabelRow(label, 16)

            local slider = self.UI:CreateSlider(triggerCard, 1, 100, displayHpValue, 1)
            slider:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", rowX, cardY)
            slider:SetScript("OnValueChanged", function(self, value)
                abilityConfig.hpValue = math.floor(value)
                if self.Text then self.Text:SetText(math.floor(value) .. "%") end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig() end)
            cardY = cardY - 40

        elseif triggerType == "ttk" then
            local displayTtkValue = abilityConfig.ttkValue or DefaultTTKValue(abilityKey)

            local isTrinket = (abilityKey == "trinket1" or abilityKey == "trinket2")
            local sliderMin = isTrinket and 0 or 5
            local sliderMax = isTrinket and 30 or 120
            local labelText = isTrinket and "TTK Offset (added to buff duration):" or "Time to Kill (seconds):"

            local label = self:CreateFontString(triggerCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", 15, cardY)
            label:SetText(labelText)
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = LabelRow(label, 16)

            local slider = self.UI:CreateSlider(triggerCard, sliderMin, sliderMax, displayTtkValue, 1)
            slider:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", rowX, cardY)

            local redrawHelp
            slider:SetScript("OnValueChanged", function(self, value)
                abilityConfig.ttkValue = math.floor(value)
                if isTrinket then
                    if self.Text then self.Text:SetText("+" .. math.floor(value) .. "s") end
                else
                    if self.Text then self.Text:SetText(math.floor(value) .. "s") end
                end
                if redrawHelp then redrawHelp() end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig() end)

            cardY = cardY - 38
            cardY, redrawHelp = AddTTKHelp(triggerCard, cardY, raidName, encounterName, encounterType, abilityKey,
                function() return abilityConfig.ttkValue or displayTtkValue end)

        elseif triggerType == "player_hp" then
            local displayPlayerHpValue = abilityConfig.playerHpValue or 30

            local label = self:CreateFontString(triggerCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Player HP %:"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = LabelRow(label, 16)

            local slider = self.UI:CreateSlider(triggerCard, 1, 100, displayPlayerHpValue, 1)
            slider:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", rowX, cardY)
            slider:SetScript("OnValueChanged", function(self, value)
                abilityConfig.playerHpValue = math.floor(value)
                if self.Text then self.Text:SetText(math.floor(value) .. "%") end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig() end)
            cardY = cardY - 40

        elseif triggerType == "player_hp_above" then
            local displayHpAbove = abilityConfig.playerHpAboveValue or 8500

            local label = self:CreateFontString(triggerCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Show when player HP is above:"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = LabelRow(label, 16)

            local slider = self.UI:CreateSlider(triggerCard, 1000, 15000, displayHpAbove, 100)
            slider:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", rowX, cardY)
            slider:SetScript("OnValueChanged", function(self, value)
                local rounded = math.floor(value / 100 + 0.5) * 100
                abilityConfig.playerHpAboveValue = rounded
                if self.Text then self.Text:SetText(rounded) end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig() end)
            cardY = cardY - 40

            local hintText = self:CreateFontString(triggerCard, "OVERLAY", nil, 10)
            hintText:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", 15, cardY)
            hintText:SetText(RCL["Hides automatically when your HP drops to or below this value"])
            hintText:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            hintText:SetWidth(triggerCard:GetWidth() - 30)
            cardY = cardY - 20

        elseif triggerType == "combat_start" then
            local displayDelay = abilityConfig.combatStartDelay or 0

            local label = self:CreateFontString(triggerCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Delay after combat start (seconds):"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = LabelRow(label, 16)

            local slider = self.UI:CreateSlider(triggerCard, 0, 30, displayDelay, 1)
            slider:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", rowX, cardY)
            slider:SetScript("OnValueChanged", function(self, value)
                abilityConfig.combatStartDelay = math.floor(value)
                if self.Text then self.Text:SetText(math.floor(value) .. "s") end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig() end)
            cardY = cardY - 40

        elseif triggerType == "rage_threshold" then
            local displayRageValue = abilityConfig.rageValue or 50

            local label = self:CreateFontString(triggerCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Rage Level:"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = LabelRow(label, 16)

            local slider = self.UI:CreateSlider(triggerCard, 0, 100, displayRageValue, 1)
            slider:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", rowX, cardY)
            slider:SetScript("OnValueChanged", function(self, value)
                abilityConfig.rageValue = math.floor(value)
                if self.Text then self.Text:SetText(math.floor(value)) end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig() end)
            cardY = cardY - 40

        elseif triggerType == "buff_remaining" then
            if not encounterSettings.abilities[abilityKey].buffRemainingValue then
                encounterSettings.abilities[abilityKey].buffRemainingValue = 5
            end

            local buffLabel = self:CreateFontString(triggerCard, "OVERLAY", nil, 11)
            buffLabel:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", 15, cardY)
            buffLabel:SetText(RCL["Buff to Watch:"])
            buffLabel:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = LabelRow(buffLabel, 6)

            local buffOptions = {
                { value = "Death Wish", label = RCL["Death Wish (Debuff)"] },
                { value = "Recklessness", label = RCL["Recklessness"] },
                { value = "Mighty Rage", label = RCL["Mighty Rage Potion"] },
                { value = "Blood Fury", label = RCL["Blood Fury (Orc)"] },
                { value = "Berserking", label = RCL["Berserking (Troll)"] },
                { value = "Enrage", label = RCL["Enrage"] },
                { value = "Flurry", label = RCL["Flurry"] },
            }

            local currentBuff = encounterSettings.abilities[abilityKey].buffName or "Death Wish"
            local buffDropdown = self.UI:CreateScrollableDropdown(triggerCard, 200, currentBuff, 10)
            buffDropdown:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", rowX, cardY)

            do
                local buffItems = {}
                local currentBuffLabel = currentBuff
                for _, opt in ipairs(buffOptions) do
                    table.insert(buffItems, { text = opt.label, value = opt.value })
                    if opt.value == currentBuff then currentBuffLabel = opt.label end
                end
                buffDropdown:SetItems(buffItems, function(value)
                    encounterSettings.abilities[abilityKey].buffName = value
                    BulkSaveConfig()
                end)
                buffDropdown:SetSelectedValue(currentBuff, currentBuffLabel)
            end
            cardY = cardY - 35

            local label = self:CreateFontString(triggerCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Trigger when buff has (seconds) remaining:"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = LabelRow(label, 16)

            local slider = self.UI:CreateSlider(triggerCard, 1, 30, encounterSettings.abilities[abilityKey].buffRemainingValue, 1)
            slider:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", rowX, cardY)
            slider:SetScript("OnValueChanged", function(self, value)
                encounterSettings.abilities[abilityKey].buffRemainingValue = math.floor(value)
                encounterSettings.abilities[abilityKey].buffTimeRemaining = nil
                if self.Text then self.Text:SetText(math.floor(value) .. "s") end
            end)
            slider:SetScript("OnMouseUp", function() BulkSaveConfig() end)
            cardY = cardY - 40

        elseif triggerType == "debuff_present" then
            local label = self:CreateFontString(triggerCard, "OVERLAY", nil, 11)
            label:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", 15, cardY)
            label:SetText(RCL["Debuff Spell ID or Name:"])
            label:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = LabelRow(label, 6)

            local editBoxContainer = self.UI:CreateStyledEditBox(triggerCard, {
                width       = 250, height = 25,
                initialText = abilityConfig.debuffSpellId or "",
                onFocusLost = function(s)
                    abilityConfig.debuffSpellId = s:GetText()
                    BulkSaveConfig()
                end,
            })
            editBoxContainer:SetPoint("TOPLEFT", triggerCard, "TOPLEFT", rowX, cardY)
            local editBox = editBoxContainer.editBox
            cardY = cardY - 35

        end

        cardY = cardY + 5

        if abilityKey == "frostBlast" then
            if not RC.db.frostBlastConfig then
                RC.db.frostBlastConfig = { alsoShowWhenDebuffed = false }
            end
            local fbCfg = RC.db.frostBlastConfig

            local MACRO_BODY = "#showtooltip\n/cancelaura Flask of the Titans\n/cancelaura Spirit of Zanza\n/cancelaura Power Word: Fortitude\n/cancelaura Prayer of Fortitude"

            AddSectionDivider("Frost Blast Reminder")
            local card = cfgCard

            local descLbl = self:CreateFontString(card, "OVERLAY", nil, 10)
            descLbl:SetPoint("TOPLEFT",  card, "TOPLEFT",  15, cardY)
            descLbl:SetPoint("TOPRIGHT", card, "TOPRIGHT", -15, cardY)
            descLbl:SetJustifyH("LEFT")
            descLbl:SetWordWrap(true)
            descLbl:SetText(RCL["The reminder figures out which stamina buffs to cancel automatically. It only fires when your max HP is meaningfully over the threshold, and if you're close enough (within 500) it leaves you alone."])
            descLbl:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            local descH = math.max(26, descLbl:GetStringHeight() + 4)
            cardY = cardY - descH - 6

            local previewBtn = self.UI:CreateStyledButton(card, RCL["Fire Preview (4s)"], 140, 24)
            previewBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
            previewBtn:SetScript("OnClick", function()
                local threshold = abilityConfig.playerHpAboveValue or 8500
                local maxHP     = UnitHealthMax("player") or 0
                local msg       = string.format(RCL["Max HP %d (target < %d)"], maxHP, threshold)
                RC:ShowReminder(msg, {"frostBlast"}, 4)
            end)
            cardY = cardY - 34

            local debuffCb = self.UI:CreateSettingCheckbox(card, cardY, "Also show when you are Frost Blasted (debuff)", fbCfg.alsoShowWhenDebuffed, function(s)
                fbCfg.alsoShowWhenDebuffed = s:GetChecked()
                RC:ForceCheckboxUpdate(s, fbCfg.alsoShowWhenDebuffed)
                RC:SaveConfigurationToProfile()
            end)
            cardY = cardY - 30

            local macHdr = self:CreateFontString(card, "OVERLAY", nil, 10)
            macHdr:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
            macHdr:SetText(RCL["Cancel macro (safe any time - no-op if a buff isn't present):"])
            macHdr:SetTextColor(TEXT.light[1], TEXT.light[2], TEXT.light[3])
            cardY = cardY - 18

            local macBg = CreateFrame("Frame", nil, card, "BackdropTemplate")
            macBg:SetHeight(70)
            macBg:SetPoint("TOPLEFT",  card, "TOPLEFT",  15, cardY)
            macBg:SetPoint("TOPRIGHT", card, "TOPRIGHT", -15, cardY)
            macBg:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8X8", edgeFile="Interface\\Buttons\\WHITE8X8", edgeSize=1})
            do
                local _eb = RC:GetColor("ui", "elementBackground")
                local _bn = RC:GetColor("ui", "borderNormal")
                macBg:SetBackdropColor(_eb.r, _eb.g, _eb.b, 1)
                macBg:SetBackdropBorderColor(_bn.r, _bn.g, _bn.b, _bn.a or 1)
            end

            local macEB = RC.UI:CreateEditBox(macBg, {
                padX = 4, padTopY = 4, padBottomY = 4, multiLine = true,
                fontSize = 11, textColor = TEXT.normal,
            })
            macEB:SetText(MACRO_BODY)
            macEB:SetScript("OnEditFocusGained", function(s) s:HighlightText() end)
            macEB:SetScript("OnEscapePressed",   function(s) s:ClearFocus() end)
            cardY = cardY - 78

            local createBtn = self.UI:CreateStyledButton(card, RCL["Create WoW Macro"], 150, 24)
            createBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cardY)
            createBtn:SetScript("OnClick", function()
                local mName = "FrostBlast"
                local mIcon = "INV_Misc_QuestionMark"
                local gCount, cCount = GetNumMacros()
                local existIdx = nil
                for i = 1, gCount do if (GetMacroInfo(i)) == mName then existIdx = i; break end end
                if not existIdx then
                    for i = 121, 120 + cCount do if (GetMacroInfo(i)) == mName then existIdx = i; break end end
                end
                if existIdx then EditMacro(existIdx, mName, mIcon, MACRO_BODY)
                elseif gCount < 120 then CreateMacro(mName, mIcon, MACRO_BODY, nil)
                elseif cCount < 18  then CreateMacro(mName, mIcon, MACRO_BODY, 1) end
            end)
            cardY = cardY - 32

            if frame.fbTab then frame.fbTab = nil end
        end

        AddReminderText()
        CloseConfigCard()

        if isInline then
            return yPos
        end

        self:UpdateSidebarScrollbar(self.sidebarConfigFrame)
    end

local _WRm = _G.Readycheck
if _WRm then
    _WRm._buildMarks = _WRm._buildMarks or {}
    _WRm._buildMarks["abilitypages"] = "row-merge"
end
