------------------------------------------------------------------------
-- Readycheck - Bulk Trash Config
-- Lets the player select several trash mobs in one quarter/section and
-- edit an ability's settings once for all of them. Edits raidSettings.
-- trash[mobName] via the GetEditableActiveProfile accessor, so this is
-- already remote-edit safe without any manual remoteEditMode branching.
-- The actual per-mob fan-out for a bulk edit (BulkSaveConfig) lives in
-- Raids_AbilityPages.lua, not here - this file only builds the mob
-- picker and decides which mob's config gets shown as the shared template.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)

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
local GetConfiguredBg, GetConfiguredHover, GetTabHoverBg, GetTabNormalBg, GetTabSelectedText, TEXT = _sbr.GetConfiguredBg, _sbr.GetConfiguredHover, _sbr.GetTabHoverBg, _sbr.GetTabNormalBg, _sbr.GetTabSelectedText, _sbr.TEXT
    function RC:ShowSidebarBulkTrashConfig(frame, raidName, preserveScroll)
        RC._lastPageFrame = frame
        if not raidName then
            raidName = frame.configState and frame.configState.selectedRaid
        end
        if not raidName then return end
        local section = frame.bulkTrashState and frame.bulkTrashState.selectedQuarter
        if not section then
            local rd = self.raidData and self.raidData[raidName]
            if rd and rd.trashSections then
                local names = {}
                for sn in pairs(rd.trashSections) do names[#names + 1] = sn end
                table.sort(names)
                section = names[1]
            else
                section = "Trash"
            end
        end
        self:ShowInlineAbilityConfig(frame, raidName, section, "trashsection", nil, preserveScroll)
    end

    function RC:RenderBulkTrashBody(frame, raidName, parent, yPos)
        -- Contributor stamping records OUR race/class into OUR profile. Merely
        -- opening a trash page while remote editing must not do that.
        local _, _, isRemoteEdit = self:GetEditableActiveProfile(raidName)
        if RC.StampRaidProfileContributor and not isRemoteEdit then
            self:StampRaidProfileContributor(raidName)
        end

        if not frame.bulkTrashState then
            frame.bulkTrashState = frame.bulkTrashState or {}
        end
        if not frame.bulkTrashState.selectedMobs then
            frame.bulkTrashState.selectedMobs = {}
        end

        local raidData = self.raidData and self.raidData[raidName]

        local trashSectionNames = {}
        if raidData and raidData.trashSections then
            for sectionName in pairs(raidData.trashSections) do
                table.insert(trashSectionNames, sectionName)
            end
            table.sort(trashSectionNames)
        end

        local currentQuarter = frame.bulkTrashState.selectedQuarter
        if not currentQuarter and #trashSectionNames > 0 then
            currentQuarter = trashSectionNames[1]
            frame.bulkTrashState.selectedQuarter = currentQuarter
        end

        local raidConfig = raidData
        if not raidConfig then
            local errorText = self:CreateFontString(parent, "OVERLAY", nil, 12)
            errorText:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
            errorText:SetText(RCL["No raid data found for "] .. raidName)
            errorText:SetTextColor(TEXT.redLight[1], TEXT.redLight[2], TEXT.redLight[3])
            return yPos - 24
        end

        local hasQuarters = raidConfig.trashSections ~= nil
        local trashMobs = {}

        if hasQuarters then
            if raidConfig.trashSections[currentQuarter] then
                for _, mobName in ipairs(raidConfig.trashSections[currentQuarter]) do
                    trashMobs[mobName] = true
                end
            end
        else
            if raidConfig.trash then
                for _, mobName in ipairs(raidConfig.trash) do
                    trashMobs[mobName] = true
                end
            end
        end

        if not next(trashMobs) then
            local errorText = self:CreateFontString(parent, "OVERLAY", nil, 12)
            errorText:SetPoint("TOPLEFT", parent, "TOPLEFT", 20, yPos)
            errorText:SetText(RCL["No trash mobs defined for "] .. (currentQuarter or raidName))
            errorText:SetTextColor(TEXT.redLight[1], TEXT.redLight[2], TEXT.redLight[3])
            return yPos - 24
        end

        local raidSettings = self:GetEditableActiveProfile(raidName)

        local selectedCount = 0
        local currentQuarterSelected = 0
        for mobName in pairs(frame.bulkTrashState.selectedMobs) do
            selectedCount = selectedCount + 1
            if trashMobs[mobName] then
                currentQuarterSelected = currentQuarterSelected + 1
            end
        end

        if selectedCount == 0 then
            frame.bulkTrashState.currentAbility = nil
            frame.bulkTrashMode = nil
        end

        local function hasSelectedMobWithAbility(abilityKey)
            if not raidSettings or not raidSettings.trash then return false end
            for _, mobSettings in pairs((raidSettings and raidSettings.trash) or {}) do
                if mobSettings and mobSettings.abilities then
                    if abilityKey == "defensives" then
                        if (mobSettings.abilities["laststand"] and mobSettings.abilities["laststand"].enabled) or
                           (mobSettings.abilities["shieldwall"] and mobSettings.abilities["shieldwall"].enabled) then
                            return true
                        end
                    elseif abilityKey == "trinkets" then
                        if (mobSettings.abilities["trinket1"] and mobSettings.abilities["trinket1"].enabled) or
                           (mobSettings.abilities["trinket2"] and mobSettings.abilities["trinket2"].enabled) then
                            return true
                        end
                    elseif abilityKey == "utility" then
                        for k, v in pairs(mobSettings.abilities) do
                            if tonumber(k) and v.enabled then
                                return true
                            end
                        end
                    elseif abilityKey == "potion" then
                        if mobSettings.abilities["potion"] and mobSettings.abilities["potion"].enabled then
                            return true
                        end
                    else
                        if mobSettings.abilities[abilityKey] and mobSettings.abilities[abilityKey].enabled then
                            return true
                        end
                    end
                end
            end
            return false
        end

        local prevSelectedCount = frame.bulkTrashState.previousSelectedCount or 0
        frame.bulkTrashState.previousSelectedCount = selectedCount

        -- Same strip-then-panel model as the boss pages: mob picker card on
        -- top, the ability tile strip under it (only once a mob is picked),
        -- and the open ability's shared config as one full-width panel
        -- below that. No side pane / vertical rail any more.
        frame._trashPageTopY = yPos
        frame._trashPane = nil
        frame._bulkExpandedFrame = nil

        local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"

        ------------------------------------------------------------------
        -- 1) Mob picker card
        ------------------------------------------------------------------
        local cardTitle = hasQuarters and ("Select trash mobs - " .. currentQuarter) or "Select trash mobs"
        local mobCard = self:CreateSettingsCard(parent, yPos, cardTitle)
        local cardY = mobCard.contentY or -32

        local selectAllBtn = self.UI:CreateStyledButton(mobCard, RCL["Select All"], 84, 22)
        selectAllBtn:SetPoint("TOPLEFT", mobCard, "TOPLEFT", 14, cardY)
        selectAllBtn:SetScript("OnClick", function()
            frame.bulkTrashState.selectedMobs =
                frame.bulkTrashState.selectedMobs or {}
            for mobName in pairs(trashMobs) do
                frame.bulkTrashState.selectedMobs[mobName] = true
            end
            RC:ShowSidebarBulkTrashConfig(frame, raidName, true)
        end)

        local selectNoneBtn = self.UI:CreateStyledButton(mobCard, RCL["Deselect"], 84, 22)
        selectNoneBtn:SetPoint("LEFT", selectAllBtn, "RIGHT", 6, 0)
        selectNoneBtn:SetScript("OnClick", function()
            if frame.bulkTrashState.selectedMobs then
                for mobName in pairs(trashMobs) do
                    frame.bulkTrashState.selectedMobs[mobName] = nil
                end
            end
            RC:ShowSidebarBulkTrashConfig(frame, raidName, true)
        end)

        cardY = cardY - 22 - 8

        local mobList = {}
        for mobName in pairs(trashMobs) do
            table.insert(mobList, mobName)
        end
        table.sort(mobList)

        local potionKeyToItemId = {
            ["mightyRagePotion"] = 13442, ["stoneshieldPotion"] = 13455,
            ["limitedInvulnerabilityPotion"] = 3387, ["freeActionPotion"] = 5634,
            ["greaterArcaneProtectionPotion"] = 13461, ["greaterFireProtectionPotion"] = 13457,
            ["greaterFrostProtectionPotion"] = 13456, ["greaterNatureProtectionPotion"] = 13458,
            ["greaterShadowProtectionPotion"] = 13459,
            ["invulnerabilityPotion"] = 3387,
            ["swiftnessPotion"] = 2459, ["fireProtectionPotion"] = 13457,
            ["frostProtectionPotion"] = 13456, ["natureProtectionPotion"] = 13458,
            ["shadowProtectionPotion"] = 13459, ["arcaneProtectionPotion"] = 13461
        }
        -- another game version's potions (RaidFlavor.lua)
        if RC._raidFlavorApplied and RC.potionData then
            for k, p in pairs(RC.potionData.potions or {}) do
                if potionKeyToItemId[k] == nil then potionKeyToItemId[k] = p.itemId end
            end
        end

        -- Row list on the ZacUI grid: 24px rows in two columns anchored to
        -- the card's centre (so they follow the card width), a white 0.03
        -- stripe on every other row, hover fill, and a selected row wears
        -- the green configured fill with a 3px muted-green bar down its left edge.
        -- A mob that already has abilities configured gets the small green
        -- square at its right edge (same marker the strip tiles use).
        local ROW_H, ROW_PAD, COL_GAP = 24, 14, 6
        local cfgBg   = self:GetColor("buttons", "configuredBackground")
        local cfgHov  = self:GetColor("buttons", "configuredHover")
        local hovBg   = self:GetColor("buttons", "hoverBackground")
        local restBg  = { r = hovBg.r, g = hovBg.g, b = hovBg.b, a = 0 }
        local gold    = self:GetColor("ui", "accentGold")
        local selBar  = self:GetColor("ui", "borderSelected")
        local stripeC = self:GetColor("text", "white")
        local txtNorm = self:GetColor("text", "normal")
        local txtSel  = self:GetColor("text", "menuSelected")
        local txtHov  = self:GetColor("ui", "accentGold")

        for mobIdx, mobName in ipairs(mobList) do
            local mobCol = (mobIdx - 1) % 2
            local rowIdx = math.floor((mobIdx - 1) / 2)

            -- Naxx trash is keyed by mob NAME across the whole raid (not
            -- per-quarter), so a mob appearing in two wings (e.g. Plagued
            -- Gargoyle in Spider + Military) already shares one config entry
            -- for free; this block only adds the "(*)" marker/tooltip so the
            -- player knows it's shared. Stoneskin Gargoyle is Plague-wing
            -- only and is a different mob, not a duplicate.
            local isNaxxDuplicate = (raidName == "Naxxramas" and self.IsNaxxDuplicateMob and self:IsNaxxDuplicateMob(mobName))
            local duplicateQuarters = nil
            if isNaxxDuplicate and self.GetQuartersForNaxxMob then
                duplicateQuarters = self:GetQuartersForNaxxMob(mobName)
            end

            local displayName = mobName
            if isNaxxDuplicate and duplicateQuarters and #duplicateQuarters > 1 then
                displayName = mobName .. " |cff888888(*)|r"
            end

            local isSelected = frame.bulkTrashState.selectedMobs
                and frame.bulkTrashState.selectedMobs[mobName] or false

            local hasConfig = (raidSettings and raidSettings.trash
                and self:EncounterHasConfig(raidSettings.trash[mobName])) or false

            local rowY = cardY - rowIdx * ROW_H
            local mobRow = CreateFrame("Button", nil, mobCard)
            mobRow:SetHeight(ROW_H)
            if mobCol == 0 then
                mobRow:SetPoint("TOPLEFT", mobCard, "TOPLEFT", ROW_PAD, rowY)
                mobRow:SetPoint("RIGHT",   mobCard, "CENTER",  -math.floor(COL_GAP / 2), 0)
            else
                mobRow:SetPoint("TOPLEFT", mobCard, "TOP",     math.ceil(COL_GAP / 2), rowY)
                mobRow:SetPoint("RIGHT",   mobCard, "RIGHT",   -ROW_PAD, 0)
            end
            mobRow.isSelected = isSelected and true or false

            mobRow.bg = mobRow:CreateTexture(nil, "BACKGROUND", nil, 0)
            mobRow.bg:SetAllPoints()
            mobRow.bg:SetTexture(FLAT)
            if isSelected then
                mobRow.bg:SetVertexColor(cfgBg.r, cfgBg.g, cfgBg.b, 1)
            else
                mobRow.bg:SetVertexColor(restBg.r, restBg.g, restBg.b, 0)
            end

            if rowIdx % 2 == 1 then
                local stripe = mobRow:CreateTexture(nil, "BACKGROUND", nil, 1)
                stripe:SetAllPoints()
                stripe:SetTexture(FLAT)
                stripe:SetVertexColor(stripeC.r, stripeC.g, stripeC.b, 0.03)
            end

            if isSelected then
                local bar = mobRow:CreateTexture(nil, "ARTWORK")
                bar:SetPoint("TOPLEFT",    mobRow, "TOPLEFT",    0, 0)
                bar:SetPoint("BOTTOMLEFT", mobRow, "BOTTOMLEFT", 0, 0)
                bar:SetWidth(3)
                bar:SetTexture(FLAT)
                bar:SetVertexColor(selBar.r, selBar.g, selBar.b, 1)
            end

            local nameText = self:CreateFontString(mobRow, "OVERLAY", nil, 11)
            nameText:SetPoint("LEFT",  mobRow, "LEFT",  10, 0)
            nameText:SetPoint("RIGHT", mobRow, "RIGHT", -14, 0)
            nameText:SetJustifyH("LEFT")
            nameText:SetWordWrap(false)
            nameText:SetText(displayName)
            local restTxt = isSelected and txtSel or txtNorm
            nameText:SetTextColor(restTxt.r, restTxt.g, restTxt.b, 1)

            -- A mob that already has abilities set reads through its
            -- label colour; a green pip on every such row turned the
            -- picker into a field of dots.
            if hasConfig and not isSelected then
                local cfgTxt = self:GetColor("text", "buttonActive")
                nameText:SetTextColor(cfgTxt.r, cfgTxt.g, cfgTxt.b, 1)
            end

            mobRow:SetScript("OnClick", function()
                local newState = not (frame.bulkTrashState.selectedMobs
                    and frame.bulkTrashState.selectedMobs[mobName])
                frame.bulkTrashState.selectedMobs =
                    frame.bulkTrashState.selectedMobs or {}
                frame.bulkTrashState.selectedMobs[mobName] = newState or nil
                RC:ShowSidebarBulkTrashConfig(frame, raidName, true)
            end)

            local function ShowMobTooltip(rowBtn)
                GameTooltip:SetOwner(rowBtn, "ANCHOR_RIGHT")
                GameTooltip:SetText(mobName, 1, 1, 1)

                if isNaxxDuplicate and duplicateQuarters and #duplicateQuarters > 1 then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(RCL["Appears in multiple quarters:"], 0.8, 0.8, 0.5)
                    for _, quarter in ipairs(duplicateQuarters) do
                        local color = (quarter == currentQuarter) and {0.5, 1, 0.5} or {0.7, 0.7, 0.7}
                        local marker = (quarter == currentQuarter) and "> " or "  "
                        GameTooltip:AddLine(marker .. quarter, color[1], color[2], color[3])
                    end
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(RCL["Settings sync across all quarters"], 0.5, 0.8, 1)
                end

                if raidSettings and raidSettings.trash and raidSettings.trash[mobName] and raidSettings.trash[mobName].abilities then
                    local configuredAbilities = {}

                    for abilityKey, abilityConfig in pairs(raidSettings.trash[mobName].abilities) do
                        if abilityConfig.enabled then
                            local abilityName = abilityKey
                            local abilityIcon = nil

                            local itemId = tonumber(abilityKey)
                            if itemId and RC.utilityItems and RC.utilityItems[itemId] then
                                abilityName = RC:ItemLabel(itemId, RC.utilityItems[itemId])
                                abilityIcon = RC:ItemLabelIcon(itemId, RC.utilityItems[itemId])
                            elseif abilityKey == "potion" and abilityConfig.potionType then
                                local potionType = abilityConfig.potionType
                                if potionKeyToItemId[potionType] then
                                    local potionItemId = potionKeyToItemId[potionType]
                                    abilityName = GetItemInfo(potionItemId) or RC.availablePotions[potionType] or potionType
                                    local _, _, _, _, _, _, _, _, _, iconTexture = GetItemInfo(potionItemId)
                                    abilityIcon = iconTexture
                                elseif RC.availablePotions and RC.availablePotions[potionType] then
                                    abilityName = RC.availablePotions[potionType]
                                    abilityIcon = "Interface\\Icons\\INV_Potion_41"
                                end
                            elseif potionKeyToItemId[abilityKey] then
                                local potionItemId = potionKeyToItemId[abilityKey]
                                abilityName = GetItemInfo(potionItemId) or abilityKey
                                local _, _, _, _, _, _, _, _, _, iconTexture = GetItemInfo(potionItemId)
                                abilityIcon = iconTexture
                            elseif abilityKey == "trinket1" then
                                abilityName = "Trinket Slot 1"
                                abilityIcon = "Interface\\Icons\\INV_Trinket_Naxxramas04"
                            elseif abilityKey == "trinket2" then
                                abilityName = "Trinket Slot 2"
                                abilityIcon = "Interface\\Icons\\INV_Trinket_Naxxramas04"
                            elseif RC.abilityData and RC.abilityData[abilityKey] then
                                abilityName = RC.abilityData[abilityKey].name
                                abilityIcon = RC.abilityData[abilityKey].icon
                            end

                            table.insert(configuredAbilities, {name = abilityName, icon = abilityIcon})
                        end
                    end

                    if #configuredAbilities > 0 then
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine(RCL["Configured Abilities:"], 0.5, 1, 0.5)

                        table.sort(configuredAbilities, function(a, b) return a.name < b.name end)
                        for _, ability in ipairs(configuredAbilities) do
                            if ability.icon then
                                GameTooltip:AddDoubleLine(ability.name, "|T" .. ability.icon .. ":16:16:0:0:64:64:4:60:4:60|t", 1, 1, 1, 1, 1, 1)
                            else
                                GameTooltip:AddLine(ability.name, 1, 1, 1)
                            end
                        end
                    else
                        if not (isNaxxDuplicate and duplicateQuarters and #duplicateQuarters > 1) then
                            GameTooltip:AddLine(RCL["No abilities configured"], 0.5, 0.5, 0.5)
                        else
                            GameTooltip:AddLine(" ")
                            GameTooltip:AddLine(RCL["No abilities configured"], 0.5, 0.5, 0.5)
                        end
                    end
                else
                    if not (isNaxxDuplicate and duplicateQuarters and #duplicateQuarters > 1) then
                        GameTooltip:AddLine(RCL["No abilities configured"], 0.5, 0.5, 0.5)
                    else
                        GameTooltip:AddLine(" ")
                        GameTooltip:AddLine(RCL["No abilities configured"], 0.5, 0.5, 0.5)
                    end
                end
                GameTooltip:Show()
            end

            -- Instant hover via the framework helper: fill swap on .bg plus
            -- gold label; the tooltip rides along in onEnter/onLeave.
            self.UI:AttachHover(mobRow,
                isSelected and cfgBg or restBg,
                isSelected and cfgHov or hovBg,
                {
                    text = nameText,
                    normTextColor  = restTxt,
                    hoverTextColor = txtHov,
                    onEnter = ShowMobTooltip,
                    onLeave = function() GameTooltip:Hide() end,
                })
        end

        local mobRows = math.ceil(#mobList / 2)
        cardY = cardY - mobRows * ROW_H - 4
        mobCard:SetContentHeight(math.abs(cardY))
        yPos = yPos - mobCard:GetHeight() - 14

        ------------------------------------------------------------------
        -- 2) Ability tile strip + 3) shared config panel
        ------------------------------------------------------------------
        frame.bulkTrashState.abilityCard = nil
        frame.bulkTrashState.abilityButtons = {}
        frame.bulkTrashState.hasSelectedMobWithAbility = hasSelectedMobWithAbility

        if selectedCount > 0 then
            local abilities = {}
            for _, e in ipairs(RC:GetAvailableAbilities("trash")) do
                abilities[#abilities + 1] = { key = e[1], name = e[2], icon = e[3] }
            end
            do
                local raceLock = { bloodfury = "Orc", berserking = "Troll" }
                local allowedRaces = self:GetRaidConfigRacialRaces(raidName, raidSettings)
                local filtered = {}
                for _, ab in ipairs(abilities) do
                    local needed = raceLock[ab.key]
                    if not needed or allowedRaces[needed] then filtered[#filtered + 1] = ab end
                end
                abilities = filtered
            end

            -- Short tile captions, same rules as the boss strip: known keys
            -- get a fixed word, the rest derive from the display name.
            local SHORT_LABELS = {
                deathwish = "Death Wish", recklessness = "Reckless.", potion = "Potion",
                trinkets = "Trinkets", utility = "Utility", defensives = "Defensives",
                bloodfury = "Racial", berserking = "Racial", gearswap = "Gear swap",
            }
            local function ShortLabel(key, name)
                if SHORT_LABELS[key] then return RCL[SHORT_LABELS[key]] end
                name = name or tostring(key)
                if #name <= 10 then return name end
                return name:sub(1, 8) .. "."
            end

            local expandedBulkKey = frame.bulkTrashState.currentAbility
            local stripTiles = {}
            for _, ability in ipairs(abilities) do
                local ak, an = ability.key, ability.name
                local hasConfig = hasSelectedMobWithAbility(ak)
                stripTiles[#stripTiles + 1] = {
                    key = ak, label = ShortLabel(ak, an), icon = ability.icon,
                    enabled = hasConfig,
                    open = (expandedBulkKey == ak),
                    tooltip = function(sb)
                        GameTooltip:SetOwner(sb, "ANCHOR_RIGHT")
                        GameTooltip:SetText(an or "", 1, 1, 1)
                        GameTooltip:AddLine(hasConfig and RCL["Configured on at least one mob"]
                            or RCL["Click to configure"], 0.7, 0.7, 0.7)
                        GameTooltip:Show()
                    end,
                    onClick = function()
                        RC:ShowSidebarBulkAbilityConfig(frame, raidName, ak)
                    end,
                }
            end

            local stripH, strip = self:BuildAbilityTileStrip(parent, yPos, {
                caption = RCL["Trash"],
                tiles   = stripTiles,
                onReflow = function()
                    if RC._bossStripReflowing then return end
                    RC._bossStripReflowing = true
                    C_Timer.After(0, function()
                        RC._bossStripReflowing = nil
                        if RC._lastPageFrame == frame and RC.ShowSidebarBulkTrashConfig then
                            RC:ShowSidebarBulkTrashConfig(frame, raidName, true)
                        end
                    end)
                end,
            })
            frame.bulkTrashState.abilityStrip = strip
            if strip and strip.tiles then
                frame.bulkTrashState.abilityButtons = strip.tiles
            end
            yPos = yPos - stripH - 10

            if prevSelectedCount == 0 and selectedCount > 0 and strip then
                strip:SetAlpha(0)
                UIFrameFadeIn(strip, 0.25, 0, 1)
            end

            if expandedBulkKey then
                frame.bulkTrashMode = {
                    active = true,
                    selectedMobs = frame.bulkTrashState.selectedMobs,
                    raidName = raidName,
                }

                -- One arbitrary selected mob (iteration order, not a stored
                -- choice) renders the shared ability config UI. Editing it
                -- writes its own encounterSettings directly here; the fan-out
                -- to every OTHER selected mob happens in Raids_AbilityPages.
                -- lua's BulkSaveConfig, which overwrites their same-slot
                -- ability entry wholesale - any per-mob customization on that
                -- slot for the other mobs is lost, not merged.
                local templateMobName
                for mobName in pairs(frame.bulkTrashState.selectedMobs) do
                    templateMobName = mobName
                    break
                end

                if not templateMobName then
                    local hint = self:CreateFontString(parent, "OVERLAY", nil, 10)
                    hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos - 4)
                    hint:SetJustifyH("LEFT")
                    hint:SetText(RCL["Pick an ability above - its settings appear here for the selected mobs."])
                    hint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                    yPos = yPos - 24
                end
                if templateMobName then
                    if not raidSettings.trash then raidSettings.trash = {} end
                    if not raidSettings.trash[templateMobName] then
                        raidSettings.trash[templateMobName] = { enabled = false, abilities = {} }
                    end
                    if not raidSettings.trash[templateMobName].abilities then
                        raidSettings.trash[templateMobName].abilities = {}
                    end
                    local encounterSettings = raidSettings.trash[templateMobName]

                    -- Full-width panel under the strip, exactly like the boss
                    -- page's RenderAbilityPanel.
                    local inlineSub = CreateFrame("Frame", nil, parent)
                    inlineSub:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, yPos)
                    inlineSub:SetPoint("RIGHT",   parent, "RIGHT",   0, 0)
                    inlineSub:SetHeight(1)
                    inlineSub:SetAlpha(1)
                    frame._bulkExpandedFrame = inlineSub

                    local bulkInlineCtx = {
                        parent = inlineSub,
                        yPos = 0,
                        settingsKey = templateMobName,
                        onRefresh = function()
                            RC:ShowSidebarBulkTrashConfig(frame, raidName, true)
                        end,
                    }

                    local newY
                    if expandedBulkKey == "trinkets" then
                        newY = self:ShowTrinketSlotSelection(frame, raidName, templateMobName, "trash",
                            raidSettings, encounterSettings, false, bulkInlineCtx)
                    elseif expandedBulkKey == "utility" then
                        newY = self:ShowSidebarUtilityConfig(frame, raidName, templateMobName, "trash",
                            raidSettings, encounterSettings, false, bulkInlineCtx)
                    elseif expandedBulkKey == "defensives" then
                        newY = self:ShowSidebarDefensivesConfig(frame, raidName, templateMobName, "trash",
                            raidSettings, encounterSettings, false, bulkInlineCtx)
                    elseif encounterSettings.abilities and encounterSettings.abilities[expandedBulkKey] then
                        newY = self:ShowSidebarAbilityConfig(frame, raidName, templateMobName, "trash",
                            raidSettings, expandedBulkKey, nil, false, bulkInlineCtx)
                    end
                    if newY then yPos = yPos + newY end

                    if frame._pendingFadeInBulkKey == expandedBulkKey then
                        RC:FadeInInlineBody(inlineSub)
                        frame._pendingFadeInBulkKey = nil
                    else
                        inlineSub:SetAlpha(1)
                    end
                end
            else
                frame.bulkTrashMode = nil
                local hint = self:CreateFontString(parent, "OVERLAY", nil, 10)
                hint:SetPoint("TOPLEFT", parent, "TOPLEFT", 18, yPos - 4)
                hint:SetJustifyH("LEFT")
                hint:SetText(RCL["Pick an ability above to configure it for the selected mobs."])
                hint:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
                yPos = yPos - 24
            end
        end

        return yPos
    end

    function RC:ShowSidebarBulkAbilityConfig(frame, raidName, abilityKey)

        frame.bulkTrashState = frame.bulkTrashState or {}
        local selectedMobs = frame.bulkTrashState.selectedMobs or {}

        local raidSettings = self:GetEditableActiveProfile(raidName)
        if not raidSettings then return end
        if not raidSettings.trash then raidSettings.trash = {} end

        for mobName in pairs(selectedMobs) do
            if not raidSettings.trash[mobName] then
                raidSettings.trash[mobName] = { enabled = false, abilities = {} }
            end
            if not raidSettings.trash[mobName].abilities then
                raidSettings.trash[mobName].abilities = {}
            end
        end

        local wasOpen = (frame.bulkTrashState.currentAbility == abilityKey)

        if not wasOpen and abilityKey ~= "trinkets" and abilityKey ~= "utility" and abilityKey ~= "defensives" then
            local templateMobName
            for mobName in pairs(selectedMobs) do
                templateMobName = mobName
                break
            end
            local es = templateMobName and raidSettings.trash[templateMobName]
            if es and not es.abilities[abilityKey] then
                local isPotionAbility = (type(abilityKey) == "string" and abilityKey:lower():find("potion"))
                local newConfig = { enabled = true, triggerType = "hp_percent", enableTTS = true }
                if isPotionAbility then
                    newConfig.potionType = RC.defaultPotionType or "mightyRagePotion"
                    newConfig.hpValue = 20
                end
                es.abilities[abilityKey] = newConfig
            end
        end

        -- These seeded trash/ability records were only ever held in memory
        -- until some unrelated save happened to flush them. Persist (and, in
        -- remote edit mode, push) them now.
        self:SaveConfigurationToProfile()

        self:CycleInlineExpansion(
            function() return frame._bulkExpandedFrame end,
            function()
                if not wasOpen then
                    frame.bulkTrashState.currentAbility = abilityKey
                    frame._pendingFadeInBulkKey = abilityKey
                end
                self:ShowSidebarBulkTrashConfig(frame, raidName, true)
            end
        )
    end

local _WRm = _G.Readycheck
if _WRm then
    _WRm._buildMarks = _WRm._buildMarks or {}
    _WRm._buildMarks["bulktrash"] = "edges+direct-toggle"
end
