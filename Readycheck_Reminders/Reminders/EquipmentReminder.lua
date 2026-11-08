------------------------------------------------------------------------
-- Readycheck - Fast Weapon / Gear Reminder
-- On-screen warning for fast weapons, shields, healing weapons, Wrath
-- gear, an offhand dagger, and user-defined custom/utility items.
-- ScanCurrentEquipment() is the single source of truth: the icon grid,
-- the flash/sound trigger and the TTS phrase all read its result table
-- rather than re-scanning gear themselves.
------------------------------------------------------------------------
local function InitializeEquipmentReminder()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeEquipmentReminder)
        return
    end

    if not RC.db then
        C_Timer.After(0.2, InitializeEquipmentReminder)
        return
    end

    local GetInventoryItemLink = GetInventoryItemLink
    local GetInventoryItemID = GetInventoryItemID
    local GetItemInfo = GetItemInfo or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemInfo)
    local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
    local UnitAttackSpeed = UnitAttackSpeed
    local UnitAffectingCombat = UnitAffectingCombat

    local function IsTargetBoss()
        if not UnitExists("target") then return false end
        if UnitClassification("target") == "worldboss" then return true end
        if UnitLevel("target") == -1 then return true end
        return false
    end

    RC.fastWeaponReminder = {
        frame = nil,
        currentWeaponSpeed = nil,
        currentShieldStatus = false,
        currentHealingWeaponStatus = false,
        fadeAnimation = nil,
        testMode = false,
        lastMainhandId = nil,
        lastOffhandId = nil,
        lastCombatState = false,
        lastBossTarget = false,
    }

    function RC:InitializeFastWeaponReminderDB()
        if not self.db.fastWeaponReminder then
            self.db.fastWeaponReminder = {
                enabled = false,
                locked = false,
                anchorPoint = "CENTER",
                xOffset = 0,
                yOffset = 200,
                scale = 1.0,
                iconSize = 48,
                fontSize = 14,
                showIcon = true,
                playSound = false,
                soundKey = "WR: Warning",
                ttsEnabled = false,
                ttsRepeatEnabled = false,
                ttsRepeatInterval = 5,
                ttsRepeatCount = 3,
                ttsFastWeapons     = true,
                ttsShields         = true,
                ttsHealingWeapons  = true,
                ttsWrathGear       = true,
                ttsUtilityItems    = true,
                ttsCustomItems     = true,
                ttsDaggerInOffhand = true,
                flashOnEquip = true,
                alwaysShow = true,
                detectFastWeapons = true,
                detectShields = true,
                detectHealingWeapons = true,
                detectWrathGear = true,
                detectCustomItems = true,
                detectUtilityItems = true,
                detectDaggerInOffhand = false,
                customItems = {},
                detectFastWeaponsCondition    = "always",
                detectShieldsCondition        = "always",
                detectHealingWeaponsCondition = "always",
                detectWrathGearCondition      = "always",
                detectUtilityItemsCondition   = "always",
                detectCustomItemsCondition    = "always",
                detectDaggerInOffhandCondition = "always",
            }
        end

        -- Layout fields were only written when the whole table was first
        -- created, so a table that arrived without them (older save,
        -- profile import, mesh sync) left iconSize nil and the frame
        -- builder erroring on SetSize every update. Backfill them like
        -- the detect* keys below.
        do
            local fw = self.db.fastWeaponReminder
            if type(fw.iconSize) ~= "number" then fw.iconSize = 48 end
            if type(fw.fontSize) ~= "number" then fw.fontSize = 14 end
            if type(fw.scale) ~= "number" then fw.scale = 1.0 end
            if fw.anchorPoint == nil then fw.anchorPoint = "CENTER" end
        end

        if self.db.fastWeaponReminder.alwaysShow == nil then
            self.db.fastWeaponReminder.alwaysShow = true
        end
        if self.db.fastWeaponReminder.showIcon == nil then
            self.db.fastWeaponReminder.showIcon = true
        end
        if self.db.fastWeaponReminder.detectFastWeapons == nil then
            self.db.fastWeaponReminder.detectFastWeapons = true
        end
        if self.db.fastWeaponReminder.detectShields == nil then
            self.db.fastWeaponReminder.detectShields = true
        end
        if self.db.fastWeaponReminder.detectHealingWeapons == nil then
            self.db.fastWeaponReminder.detectHealingWeapons = true
        end
        if self.db.fastWeaponReminder.detectWrathGear == nil then
            self.db.fastWeaponReminder.detectWrathGear = true
        end
        if self.db.fastWeaponReminder.detectCustomItems == nil then
            self.db.fastWeaponReminder.detectCustomItems = true
        end
        if self.db.fastWeaponReminder.detectUtilityItems == nil then
            self.db.fastWeaponReminder.detectUtilityItems = true
        end
        if self.db.fastWeaponReminder.detectDaggerInOffhand == nil then
            self.db.fastWeaponReminder.detectDaggerInOffhand = false
        end
        if self.db.fastWeaponReminder.customItems == nil then
            self.db.fastWeaponReminder.customItems = {}
        end
        if self.db.fastWeaponReminder.soundKey == nil then
            self.db.fastWeaponReminder.soundKey = "WR: Warning"
        end
        if self.db.fastWeaponReminder.ttsEnabled == nil then
            self.db.fastWeaponReminder.ttsEnabled = false
        end
        if self.db.fastWeaponReminder.ttsRepeatEnabled == nil then
            self.db.fastWeaponReminder.ttsRepeatEnabled = false
        end
        if self.db.fastWeaponReminder.ttsRepeatInterval == nil then
            self.db.fastWeaponReminder.ttsRepeatInterval = 5
        end
        if self.db.fastWeaponReminder.ttsRepeatCount == nil then
            self.db.fastWeaponReminder.ttsRepeatCount = 3
        end
        local ttsTypeKeys = {
            "ttsFastWeapons", "ttsShields", "ttsHealingWeapons", "ttsWrathGear",
            "ttsUtilityItems", "ttsCustomItems", "ttsDaggerInOffhand",
        }
        for _, k in ipairs(ttsTypeKeys) do
            if self.db.fastWeaponReminder[k] == nil then
                self.db.fastWeaponReminder[k] = true
            end
        end
        local condKeys = {
            "detectFastWeaponsCondition", "detectShieldsCondition",
            "detectHealingWeaponsCondition", "detectWrathGearCondition",
            "detectUtilityItemsCondition", "detectCustomItemsCondition",
            "detectDaggerInOffhandCondition",
        }
        for _, k in ipairs(condKeys) do
            if self.db.fastWeaponReminder[k] == nil then
                self.db.fastWeaponReminder[k] = "always"
            end
        end
    end

    -- Keyed by item id, never expired: whether an item's tooltip mentions
    -- healing/spell power is a fixed property of that item, not state.
    local healingItemCache = {}

    local WRATH_GEAR_ITEMS = {
        [16959] = "Bracelets of Wrath",
        [16960] = "Breastplate of Wrath",
        [16961] = "Pauldrons of Wrath",
        [16962] = "Waistband of Wrath",
        [16963] = "Helm of Wrath",
        [16964] = "Gauntlets of Wrath",
        [16965] = "Sabatons of Wrath",
        [16966] = "Legplates of Wrath",
    }

    local OFFHAND_DAGGER_ITEMS = {
        [22802] = {name = "Kingsfall",              short = "Kingsfall"},
        [23242] = {name = "Claw of the Frost Wyrm", short = "Claw"},
    }

    local UTILITY_ITEMS = {
        [7189]  = { name = "Goblin Rocket Boots",    short = "Rocket Boots" },
        [9452]  = { name = "Goblin Rocket Boots",    short = "Rocket Boots" },
        [7391]  = { name = "Swift Boots",            short = "Swift Boots"  },
        [4984]  = { name = "Skull of Impending Doom", short = "Skull"       },
        [2820]  = { name = "Nifty Stopwatch",        short = "Stopwatch"    },
        [4264]  = { name = "Barbaric Belt",          short = "Barb Belt"    },
        [6972]  = { name = "Fire Hardened Hauberk",  short = "Hauberk"      },
    }

    local function GetScanTooltip()
        return RC:GetScanTooltip()
    end

    C_Timer.After(0.1, function()
        GetScanTooltip()
    end)

    local ARMOR_SLOTS  = {1, 3, 5, 6, 7, 8, 9, 10}
    local WEAPON_SLOTS = {16, 17}
    local ARMOR_SLOTS_PLUS_WEAPONS = {1, 3, 5, 6, 7, 8, 9, 10, 16, 17}
    local ALL_SLOTS    = {1,2,3,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19}

    local function ItemIsHealingWeapon(itemId, slotId)
        if itemId == nil then return false end
        if healingItemCache[itemId] ~= nil then
            return healingItemCache[itemId]
        end
        local lines = RC.Compat.TooltipLines("inventory", "player", slotId)
        local result = false
        for i = 1, #lines do
            local text = lines[i].text
            do
                if text and (
                    text:find("Healing Spells") or
                    text:find("Spell Power") or
                    text:find("Spell Damage and Healing") or
                    text:find("spell damage and healing") or
                    text:find("Increases damage and healing")
                ) then
                    result = true
                    break
                end
            end
        end
        healingItemCache[itemId] = result
        return result
    end

    function RC:ScanCurrentEquipment()
        local db = self.db.fastWeaponReminder

        local needArmor   = db.detectWrathGear ~= false
        local needAll     = db.detectCustomItems ~= false and db.customItems and next(db.customItems)
        local needUtility = db.detectUtilityItems ~= false

        -- Scan only what's enabled: custom/utility items can sit in any
        -- slot and force the full 19-slot walk; otherwise stick to armor
        -- and weapon slots, or just the two weapon slots.
        local slotList = (needAll or needUtility) and ALL_SLOTS
                         or (needArmor and ARMOR_SLOTS_PLUS_WEAPONS or WEAPON_SLOTS)
        local ids = {}
        for _, slotId in ipairs(slotList) do
            local link = GetInventoryItemLink("player", slotId)
            ids[slotId] = link and tonumber(link:match("item:(%d+)")) or nil
        end

        local mainId = ids[16]
        local offId  = ids[17]

        local inCombat = UnitAffectingCombat("player")
        local function ConditionMet(condKey)
            local cond = db[condKey] or "always"
            if cond == "combat"   then return inCombat end
            if cond == "nocombat" then return not inCombat end
            if cond == "boss"     then return IsTargetBoss() end
            return true
        end

        local isFastWeapon = false
        if mainId and db.detectFastWeapons ~= false and ConditionMet("detectFastWeaponsCondition") then
            if self.IsFastWeapon then
                isFastWeapon = self:IsFastWeapon(mainId)
            elseif self.fastWeapons then
                isFastWeapon = self.fastWeapons[mainId] ~= nil
            end
        end

        local mainSpeed = UnitAttackSpeed("player")
        if RC.IsSecret(mainSpeed) then mainSpeed = nil end   -- (hidden on WoW Forever)

        local hasShield = false
        if db.detectShields ~= false and offId and ConditionMet("detectShieldsCondition") then
            local _, _, _, _, _, _, subType = GetItemInfo(offId)
            hasShield = (subType == "Shield" or subType == "Shields")
        end

        local hasHealingWeapon = false
        local healingSlot, healingLink
        if db.detectHealingWeapons ~= false and ConditionMet("detectHealingWeaponsCondition") then
            if mainId and ItemIsHealingWeapon(mainId, 16) then
                hasHealingWeapon = true
                healingSlot = 16
                healingLink  = GetInventoryItemLink("player", 16)
            elseif offId and ItemIsHealingWeapon(offId, 17) then
                hasHealingWeapon = true
                healingSlot = 17
                healingLink  = GetInventoryItemLink("player", 17)
            end
        end

        local hasWrathGear, wrathItemName = false, nil
        if needArmor and ConditionMet("detectWrathGearCondition") then
            for _, slotId in ipairs(ARMOR_SLOTS) do
                local id = ids[slotId]
                if id and WRATH_GEAR_ITEMS[id] then
                    hasWrathGear  = true
                    wrathItemName = WRATH_GEAR_ITEMS[id]
                    break
                end
            end
        end

        -- These two used to stop at the first hit, so wearing two utility
        -- items showed only one. Collect every match; the first is still
        -- reported through the singular fields so TTS and the change
        -- detection below keep working unchanged.
        local hasCustomItem, customItemName, customItemLabel, customItemId = false, nil, nil, nil
        local customItemList = {}
        if needAll and ConditionMet("detectCustomItemsCondition") then
            for _, slotId in ipairs(ALL_SLOTS) do
                local id = ids[slotId]
                if id then
                    local customData = db.customItems[id]
                    if customData then
                        customItemList[#customItemList + 1] = {
                            id    = id,
                            name  = customData.name or "Custom Item",
                            label = customData.label or "CUSTOM",
                        }
                        if not hasCustomItem then
                            hasCustomItem    = true
                            customItemName   = customData.name or "Custom Item"
                            customItemLabel  = customData.label or "CUSTOM"
                            customItemId     = id
                        end
                    end
                end
            end
        end

        local hasUtilityItem, utilityItemName, utilityItemShort, utilityItemId = false, nil, nil, nil
        local utilityItemList = {}
        if needUtility and ConditionMet("detectUtilityItemsCondition") then
            for _, slotId in ipairs(ALL_SLOTS) do
                local id = ids[slotId]
                if id and UTILITY_ITEMS[id] then
                    utilityItemList[#utilityItemList + 1] = {
                        id    = id,
                        name  = UTILITY_ITEMS[id].name,
                        short = UTILITY_ITEMS[id].short,
                    }
                    if not hasUtilityItem then
                        hasUtilityItem   = true
                        utilityItemName  = UTILITY_ITEMS[id].name
                        utilityItemShort = UTILITY_ITEMS[id].short
                        utilityItemId    = id
                    end
                end
            end
        end

        local hasDaggerInOffhand, daggerItemName = false, nil
        if db.detectDaggerInOffhand and offId and ConditionMet("detectDaggerInOffhandCondition") then
            if OFFHAND_DAGGER_ITEMS[offId] then
                hasDaggerInOffhand = true
                daggerItemName = OFFHAND_DAGGER_ITEMS[offId].short
            end
        end

        -- Everything currently matching, in the same priority order the
        -- display chain used to pick a single winner from. The frame draws
        -- all of these; index 1 is what the old code would have shown.
        local matches = {}
        local function AddMatch(icon, label, header)
            if not icon then return end
            matches[#matches + 1] = { icon = icon, label = label, header = header }
        end

        if hasShield then AddMatch(offId, "SHIELD") end
        if hasHealingWeapon then AddMatch(healingLink, "HEALING WEAPON") end
        if hasWrathGear then AddMatch("Interface\\Icons\\inv_helmet_71", "WRATH GEAR") end
        if hasDaggerInOffhand then
            AddMatch(offId, "", (daggerItemName or "Dagger") .. RCL[" Equipped"])
        end
        for _, u in ipairs(utilityItemList) do
            AddMatch(u.id, string.upper(u.short or "UTILITY"))
        end
        for _, c in ipairs(customItemList) do
            AddMatch(c.id, c.label)
        end
        if isFastWeapon then AddMatch(mainId, "FAST WEAPON") end

        return {
            matches          = matches,
            utilityItemList  = utilityItemList,
            customItemList   = customItemList,
            mainId           = mainId,
            offId            = offId,
            mainSpeed        = mainSpeed,
            isFastWeapon     = isFastWeapon,
            hasShield        = hasShield,
            hasHealingWeapon = hasHealingWeapon,
            healingSlot      = healingSlot,
            healingLink      = healingLink,
            hasWrathGear     = hasWrathGear,
            wrathItemName    = wrathItemName,
            hasCustomItem    = hasCustomItem,
            customItemName   = customItemName,
            customItemLabel  = customItemLabel,
            customItemId     = customItemId,
            hasUtilityItem   = hasUtilityItem,
            utilityItemName  = utilityItemName,
            utilityItemShort = utilityItemShort,
            utilityItemId    = utilityItemId,
            hasDaggerInOffhand = hasDaggerInOffhand,
            daggerItemName   = daggerItemName,
        }
    end

    function RC:GetCurrentEquipmentIds()
        local mainhandLink = GetInventoryItemLink("player", 16)
        local offhandLink  = GetInventoryItemLink("player", 17)
        local mainhandId = mainhandLink and tonumber(mainhandLink:match("item:(%d+)")) or nil
        local offhandId  = offhandLink  and tonumber(offhandLink:match("item:(%d+)"))  or nil
        return mainhandId, offhandId
    end

    function RC:AddCustomEquipmentItem(itemId, label)
        if not itemId then return false, "No item ID provided" end

        itemId = tonumber(itemId)
        if not itemId then return false, "Invalid item ID" end

        if not self.db.fastWeaponReminder.customItems then
            self.db.fastWeaponReminder.customItems = {}
        end

        local itemName, itemLink = GetItemInfo(itemId)
        if not itemName then
            C_Timer.After(0.5, function()
                local name = GetItemInfo(itemId)
                if name and self.db.fastWeaponReminder.customItems[itemId] then
                    self.db.fastWeaponReminder.customItems[itemId].name = name
                    self:SaveConfigurationToProfile()
                end
            end)
            itemName = "Item #" .. itemId
        end

        self.db.fastWeaponReminder.customItems[itemId] = {
            name = itemName,
            label = label or "CUSTOM"
        }

        self:SaveConfigurationToProfile()
        self:DebugPrint("Added custom equipment item: " .. itemName .. " (ID: " .. itemId .. ")", "config")

        return true, itemName
    end

    function RC:RemoveCustomEquipmentItem(itemId)
        if not itemId then return false end

        itemId = tonumber(itemId)
        if not itemId then return false end

        if self.db.fastWeaponReminder.customItems and self.db.fastWeaponReminder.customItems[itemId] then
            local name = self.db.fastWeaponReminder.customItems[itemId].name
            self.db.fastWeaponReminder.customItems[itemId] = nil
            self:SaveConfigurationToProfile()
            self:DebugPrint("Removed custom equipment item: " .. (name or itemId), "config")
            return true
        end

        return false
    end

    function RC:GetCustomEquipmentItemCount()
        if not self.db.fastWeaponReminder.customItems then return 0 end
        local count = 0
        for _ in pairs(self.db.fastWeaponReminder.customItems) do
            count = count + 1
        end
        return count
    end

    function RC:IsFastWeaponEquipped()
        if not self.db.fastWeaponReminder.enabled then return false end
        local s = self:ScanCurrentEquipment()
        local isFast = s.isFastWeapon or s.hasShield or s.hasHealingWeapon or s.hasWrathGear
                       or s.hasCustomItem or s.hasUtilityItem
        return isFast, s.mainSpeed, s.hasShield, s.hasHealingWeapon, s.isFastWeapon,
               s.hasWrathGear, s.wrathItemName, s.hasCustomItem, s.customItemName,
               s.customItemLabel, s.customItemId
    end

    -- The reminder shows every match at once, but the frame is always the
    -- square the user sized in the options - it never grows, however many
    -- items are on. The icons pack into that square as a grid instead, so
    -- the reminder takes exactly as much screen space with six items as it
    -- does with one. Anything past MAX_ICONS is dropped rather than shrunk
    -- further, since it would be unreadable.
    local MAX_ICONS = 9

    local function CreateIconCell(frame)
        local cell = CreateFrame("Frame", nil, frame)

        cell.bg = cell:CreateTexture(nil, "BACKGROUND")
        cell.bg:SetAllPoints()
        local cellBg = RC:GetColor("ui", "cardBackground")
        cell.bg:SetColorTexture(cellBg.r, cellBg.g, cellBg.b, 0.9)

        if RC.UI and RC.UI.CreateSimpleBorder then
            cell.border = RC.UI:CreateSimpleBorder(cell, 1)
        end

        cell.texture = cell:CreateTexture(nil, "ARTWORK")
        cell.texture:SetAllPoints()
        cell.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)

        cell:Hide()
        return cell
    end

    local function LayoutEquipmentIcons(frame, count)
        local db = RC.db and RC.db.fastWeaponReminder
        local size = (db and db.iconSize) or 48

        count = math.max(1, math.min(count or 1, MAX_ICONS))
        frame:SetSize(size, size)

        -- Squarest grid that holds them all, so the cells stay as large as
        -- the fixed box allows: 1 fills it, 2 sit side by side at half
        -- width, 3-4 make a 2x2, 5-9 a 3x3.
        local cols = math.ceil(math.sqrt(count))
        local rows = math.ceil(count / cols)
        local span = math.max(cols, rows)
        local cell = math.floor(size / span)
        if cell < 1 then cell = 1 end

        for i = 1, MAX_ICONS do
            local icon = frame.icons and frame.icons[i]
            if icon then
                if i <= count then
                    local r = math.floor((i - 1) / cols)
                    local c = (i - 1) % cols
                    -- Centre each row on its own so a short final row sits
                    -- under the middle of the one above it.
                    local inRow = math.min(cols, count - (r * cols))
                    local x = (-((inRow - 1) * cell) / 2) + (c * cell)
                    local y = (((rows - 1) * cell) / 2) - (r * cell)
                    icon:SetSize(cell, cell)
                    icon:ClearAllPoints()
                    icon:SetPoint("CENTER", frame, "CENTER", x, y)
                    icon:Show()
                else
                    icon:Hide()
                end
            end
        end
    end

    ------------------------------------------------------------------
    -- THE LOOK. RC:BuildEquipmentReminderFrame (the icon box and its two
    -- labels), RC:StyleEquipmentReminder (fonts, colours, cells) and
    -- RC:LayoutEquipmentReminderIcons are shared by the live reminder and
    -- the settings preview. Every look option is optional in
    -- db.fastWeaponReminder; nil is the shipped look (fontSize stays the
    -- size of both labels).
    ------------------------------------------------------------------
    RC.EQUIP_REMINDER_ANIM = { style = "none", duration = 0.3, easing = "easeOutQuad" }
    -- the old flash: down and back up over 0.8s (two 0.4s halves)
    RC.EQUIP_REMINDER_FLASH = { style = "fade", duration = 0.8, easing = "linear" }

    function RC:EquipReminderAnim(key, defaults)
        local db = self.db and self.db.fastWeaponReminder or {}
        return RC.Motion.Normalize(db[key], defaults or RC.EQUIP_REMINDER_ANIM)
    end

    function RC:EquipReminderFontDefaults()
        local db = self.db and self.db.fastWeaponReminder or {}
        return { size = tonumber(db.fontSize) or 14, outline = "OUTLINE", shadow = true }
    end

    function RC:LayoutEquipmentReminderIcons(frame, count)
        LayoutEquipmentIcons(frame, count)
    end
    RC.EQUIP_REMINDER_MAX_ICONS = MAX_ICONS

    -- live = the real reminder (named, high strata); otherwise a sample
    function RC:BuildEquipmentReminderFrame(parent, live)
        local frame = CreateFrame("Frame", live and "ReadycheckEquipmentFrame" or nil, parent)
        local db = self.db.fastWeaponReminder
        local size = tonumber(db.iconSize) or 48
        frame:SetSize(size, size)
        if live then
            frame:SetFrameStrata("HIGH")
            frame:SetFrameLevel(100)
        end

        frame.icons = {}
        for i = 1, MAX_ICONS do
            frame.icons[i] = CreateIconCell(frame)
        end
        LayoutEquipmentIcons(frame, 1)

        -- Cell 1 is the whole box when only one thing matches, which is
        -- the old single-icon look exactly. Aliased so the existing
        -- sizing and test-mode code keeps working.
        frame.itemIcon    = frame.icons[1]
        frame.iconBg      = frame.icons[1].bg
        frame.itemTexture = frame.icons[1].texture

        -- The text has to span the whole row, so it cannot live on a single
        -- icon cell any more. Font strings on the parent frame draw *under*
        -- child frames though, which buried the labels behind the icons -
        -- hence a dedicated layer above every cell.
        frame.textLayer = CreateFrame("Frame", nil, frame)
        frame.textLayer:SetAllPoints(frame)
        frame.textLayer:SetFrameLevel(frame:GetFrameLevel() + 10)

        -- templates = placeholder fonts until StyleEquipmentReminder sets
        -- the real ones (the client refuses SetText on a font-less string)
        frame.topText = frame.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        frame.topText:SetPoint("CENTER", frame, "TOP", 0, 0)
        frame.topText:SetJustifyH("CENTER")
        frame.topText:SetText("")

        frame.headerText = frame.textLayer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        frame.headerText:SetPoint("CENTER", frame, "BOTTOM", 0, 0)
        frame.headerText:SetJustifyH("CENTER")
        frame.headerText:SetText("WARNING")

        self:StyleEquipmentReminder(frame)
        return frame
    end

    function RC:StyleEquipmentReminder(frame)
        local db = self.db.fastWeaponReminder
        local fd = self:EquipReminderFontDefaults()
        local tc = (type(db.textColor) == "table" and db.textColor) or RC:GetColor("text", "red")
        for _, fs in ipairs({ frame.topText, frame.headerText }) do
            RC:ApplyFontSpec(fs, db.textFont, fd)
            local sh = type(db.textFont) == "table" and db.textFont.shadow
            if sh == nil then sh = fd.shadow end
            if sh then fs:SetShadowOffset(2, -2) fs:SetShadowColor(0, 0, 0, 1) end
            fs:SetTextColor(tc.r, tc.g, tc.b, tc.a or 1)
        end
        frame.textLayer:SetShown(db.showText ~= false)
        -- fastWeaponReminder.anchors.top / .bottom: a spec moves a label
        -- from its place (centred on the top / bottom edge)
        local anc = type(db.anchors) == "table" and db.anchors or nil
        if anc or frame._erMoved then
            frame._erDef = frame._erDef or { top = {}, bottom = {} }
            local function To(k)
                if k == "top" then return frame.topText elseif k == "bottom" then return frame.headerText
                elseif k == "icons" then return frame.icons[1] elseif k == "frame" then return frame end
            end
            frame.topText:ClearAllPoints()
            frame.topText:SetPoint("CENTER", frame, "TOP", 0, 0)
            frame.headerText:ClearAllPoints()
            frame.headerText:SetPoint("CENTER", frame, "BOTTOM", 0, 0)
            if anc then
                RC.UI:AnchorOver(frame.topText, anc.top, frame._erDef.top, "CENTER", frame, "TOP", 0, 0, To)
                RC.UI:AnchorOver(frame.headerText, anc.bottom, frame._erDef.bottom, "CENTER", frame, "BOTTOM", 0, 0, To)
            end
            frame._erMoved = anc ~= nil
        end
        local cb = (type(db.cellColor) == "table" and db.cellColor) or nil
        local cardBg = RC:GetColor("ui", "cardBackground")
        local bc = (type(db.borderColor) == "table" and db.borderColor) or RC:GetColor("ui", "borderNormal")
        for _, cell in ipairs(frame.icons) do
            if cb then cell.bg:SetColorTexture(cb.r, cb.g, cb.b, cb.a or 0.9)
            else cell.bg:SetColorTexture(cardBg.r, cardBg.g, cardBg.b, 0.9) end
            if cell.border and RC.UI.UpdateBorderColor then
                RC.UI:UpdateBorderColor(cell.border, bc)
                for _, t in pairs(cell.border) do t:SetShown(db.showBorder ~= false) end
            end
        end
        -- layer / scale / clamp, fade rules, edge (the customization standard)
        if self.ApplyFrameCustom then
            self:ApplyFrameCustom(frame, function() return RC.db and RC.db.fastWeaponReminder end,
                { sample = (frame ~= (self.fastWeaponReminder and self.fastWeaponReminder.frame)) })
        end
    end

    -- appear / go with their animations; only on a real change
    -- flash: play "Flash on equip" once it is up (after its entrance)
    function RC:ShowEquipmentReminderFrame(frame, flash)
        local M = RC.Motion
        if frame:IsShown() and not (M.IsPlaying(frame) and frame._rcMotion and frame._rcMotion.how == "out") then
            if flash then self:FlashEquipmentReminder(frame) end
            return
        end
        M.Show(frame, self:EquipReminderAnim("showAnim"), flash and function() RC:FlashEquipmentReminder(frame) end or nil)
    end
    function RC:HideEquipmentReminderFrame(frame)
        local M = RC.Motion
        if not frame:IsShown() or (M.IsPlaying(frame) and frame._rcMotion and frame._rcMotion.how == "out") then return end
        M.Hide(frame, self:EquipReminderAnim("hideAnim"))
    end
    -- "Flash on equip", once the frame is up
    function RC:FlashEquipmentReminder(frame)
        if frame:IsShown() then
            RC.Motion.Play(frame, self:EquipReminderAnim("flashAnim", RC.EQUIP_REMINDER_FLASH), "update")
        end
    end

    function RC:CreateFastWeaponReminderFrame()
        if self.fastWeaponReminder.frame then
            return self.fastWeaponReminder.frame
        end

        local db = self.db.fastWeaponReminder
        local frame = self:BuildEquipmentReminderFrame(UIParent, true)
        RC.Position.Bind(frame, function() return self.db.fastWeaponReminder end, {
            point = "CENTER", pointKey = "anchorPoint", default = { x = 0, y = 200 },
        })
        RC.Position.RestoreFrame(frame)
        frame:SetMovable(true)
        frame:EnableMouse(true)
        frame:RegisterForDrag("LeftButton")
        frame:SetClampedToScreen(true)

        frame:SetScript("OnMouseDown", function(f, button)
            if button == "LeftButton" and not db.locked then
                -- an animation ending mid-drag would put the old spot back
                RC.Motion.Stop(f)
                f.__rcDragging = true
                f:StartMoving()
            end
        end)

        frame:SetScript("OnMouseUp", function(f, button)
            if button == "LeftButton" and f.__rcDragging then
                f.__rcDragging = nil
                f:StopMovingOrSizing()
                RC.Position.SaveFrame(f)
                RC.Position.RestoreFrame(f)
            end
        end)

        self.fastWeaponReminder.frame = frame
        frame:Hide()

        return frame
    end

    function RC:UpdateEquipmentReminderIconSize()
        if not self.fastWeaponReminder.frame then return end
        local frame = self.fastWeaponReminder.frame
        LayoutEquipmentIcons(frame, frame.shownIconCount or 1)
    end

    function RC:UpdateEquipmentReminderFontSize()
        if not self.fastWeaponReminder.frame then
            return
        end
        self:StyleEquipmentReminder(self.fastWeaponReminder.frame)
    end

    function RC:ShowFastWeaponReminderTest()
        if not self.fastWeaponReminder.frame then
            self:CreateFastWeaponReminderFrame()
        end

        local frame = self.fastWeaponReminder.frame

        -- Test shows a single icon, so collapse the grid back to one cell
        -- in case a multi-match layout is still on screen.
        frame.shownIconCount = 1
        LayoutEquipmentIcons(frame, 1)
        frame.itemTexture:SetTexture(134955)

        self.fastWeaponReminder.testMode = true

        self:StyleEquipmentReminder(frame)
        self:ShowEquipmentReminderFrame(frame, self.db.fastWeaponReminder.flashOnEquip)

        if self.db and self.db.fastWeaponReminder and self.db.fastWeaponReminder.ttsEnabled then
            self:SpeakTTS(RCL["Shield"], false)
        end
    end

    function RC:HideFastWeaponReminderTest()
        self.fastWeaponReminder.testMode = false

        if self.fastWeaponReminder.frame then
            local isFast = self:IsFastWeaponEquipped()
            if not isFast then
                self:HideEquipmentReminderFrame(self.fastWeaponReminder.frame)
            else
                self:UpdateFastWeaponReminder()
            end
        end
    end

    -- RC.UpdateFastWeaponReminder is defined further down in this file;
    -- every call site resolves it at call time, after the file has loaded.

    local eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")

    local cachedResult = nil

    local pendingTimer = nil
    local function ScheduleCheck(delay)
        cachedResult = nil
        if pendingTimer then
            pendingTimer:Cancel()
            pendingTimer = nil
        end
        pendingTimer = C_Timer.NewTimer(delay or 0.5, function()
            pendingTimer = nil
            if RC.UpdateFastWeaponReminder then RC:UpdateFastWeaponReminder() end
        end)
    end

    eventFrame:SetScript("OnEvent", function(self, event, ...)
        if event == "PLAYER_EQUIPMENT_CHANGED" then
            local slot = ...
            if slot and slot >= 1 and slot <= 19 then
                ScheduleCheck(0.5)
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            C_Timer.After(0.3, function()
                for _, slotId in ipairs({16, 17}) do
                    local link = GetInventoryItemLink("player", slotId)
                    if link then
                        local itemId = tonumber(link:match("item:(%d+)"))
                        if itemId and healingItemCache[itemId] == nil then
                            ItemIsHealingWeapon(itemId, slotId)
                        end
                    end
                end
            end)
            ScheduleCheck(1.0)
        elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
            C_Timer.After(0.5, function()
                if RC.fastWeaponReminder and RC.fastWeaponReminder.frame then
                    if RC.UpdateFastWeaponReminder then RC:UpdateFastWeaponReminder() end
                end
            end)
        elseif event == "PLAYER_TARGET_CHANGED" then
            local db = RC.db and RC.db.fastWeaponReminder
            if db then
                local condKeys = {
                    "detectFastWeaponsCondition", "detectShieldsCondition",
                    "detectHealingWeaponsCondition", "detectWrathGearCondition",
                    "detectUtilityItemsCondition", "detectCustomItemsCondition",
                    "detectDaggerInOffhandCondition",
                }
                for _, k in ipairs(condKeys) do
                    if db[k] == "boss" then
                        if RC.UpdateFastWeaponReminder then RC:UpdateFastWeaponReminder() end
                        break
                    end
                end
            end
        end
    end)

    -- Order here must mirror the AddMatch order above exactly - TTS and
    -- the icon leading the grid would otherwise disagree about what
    -- triggered. Unlike the display, which draws every match, TTS only
    -- ever speaks the single highest-priority hit.
    local function BuildEquipmentTTS(s)
        if not s then return nil, nil, nil end
        if s.hasShield then
            return "Shield", "shield", "shield"
        elseif s.hasHealingWeapon then
            return "Healing weapon", "heal", "heal"
        elseif s.hasWrathGear then
            return "Wrath gear", "wrath", "wrath"
        elseif s.hasDaggerInOffhand then
            return (s.daggerItemName or "Dagger"), "dagger:" .. tostring(s.offId), "dagger"
        elseif s.hasUtilityItem then
            return (s.utilityItemName or s.utilityItemShort or "Utility item"), "util:" .. tostring(s.utilityItemId), "util"
        elseif s.hasCustomItem then
            return (s.customItemName or s.customItemLabel or "Custom item"), "custom:" .. tostring(s.customItemId), "custom"
        elseif s.isFastWeapon then
            return "Fast weapon", "fast:" .. tostring(s.mainId), "fast"
        end
        return nil, nil, nil
    end

    local EQUIP_TTS_TYPE_KEY = {
        shield = "ttsShields",
        heal   = "ttsHealingWeapons",
        wrath  = "ttsWrathGear",
        dagger = "ttsDaggerInOffhand",
        util   = "ttsUtilityItems",
        custom = "ttsCustomItems",
        fast   = "ttsFastWeapons",
    }
    local function EquipmentTTSTypeEnabled(typeKey)
        if not typeKey then return false end
        local db = RC.db and RC.db.fastWeaponReminder
        if not db then return false end
        local dbKey = EQUIP_TTS_TYPE_KEY[typeKey]
        if not dbKey then return true end
        return db[dbKey] ~= false
    end

    local function StartEquipmentTTSRepeat(phrase, gen)
        local db = RC.db and RC.db.fastWeaponReminder
        if not db or not db.ttsRepeatEnabled then return end
        local count    = tonumber(db.ttsRepeatCount) or 3
        local interval = tonumber(db.ttsRepeatInterval) or 5
        if count < 1 or interval < 1 then return end

        local function step(left)
            if left <= 0 then return end
            C_Timer.After(interval, function()
                local fwr = RC.fastWeaponReminder
                local d   = RC.db and RC.db.fastWeaponReminder
                if not fwr or not d then return end
                if fwr.ttsGen ~= gen then return end
                if not d.enabled or not d.ttsEnabled or not d.ttsRepeatEnabled then return end
                if fwr.testMode then return end
                if not (fwr.frame and fwr.frame:IsShown()) then return end
                RC:SpeakTTS(phrase, true)
                step(left - 1)
            end)
        end
        step(count)
    end

    RC.UpdateFastWeaponReminder = function(self)
        if not self.db or not self.db.fastWeaponReminder then return end

        if not self.fastWeaponReminder.frame then
            self:CreateFastWeaponReminderFrame()
        end

        if not self.db.fastWeaponReminder.enabled then
            if self.fastWeaponReminder.frame then self:HideEquipmentReminderFrame(self.fastWeaponReminder.frame) end
            return
        end

        if self.fastWeaponReminder.testMode then
            self:ShowEquipmentReminderFrame(self.fastWeaponReminder.frame)
            return
        end

        local mainhandId, offhandId = self:GetCurrentEquipmentIds()
        local currentBossTarget = IsTargetBoss()

        -- The cache used to key on the two weapon slots only, so equipping
        -- a belt, chest or trinket the reminder watches never invalidated
        -- it and the icon went stale. Signature covers every slot scanned.
        -- Only runs on equipment/target/combat events, never per frame.
        local sigParts = {}
        for i = 1, #ALL_SLOTS do
            sigParts[i] = tostring(GetInventoryItemID("player", ALL_SLOTS[i]) or 0)
        end
        local equipSig = table.concat(sigParts, ",")

        if cachedResult and
           equipSig == self.fastWeaponReminder.lastEquipSig and
           currentBossTarget == self.fastWeaponReminder.lastBossTarget then
            if cachedResult.isFast then self:ShowEquipmentReminderFrame(self.fastWeaponReminder.frame)
            else self:HideEquipmentReminderFrame(self.fastWeaponReminder.frame) end
            return
        end
        self.fastWeaponReminder.lastEquipSig = equipSig

        if RC.Profiler then RC.Profiler:StartTiming("EquipReminder") end

        self.fastWeaponReminder.lastMainhandId = mainhandId
        self.fastWeaponReminder.lastOffhandId  = offhandId
        self.fastWeaponReminder.lastBossTarget = currentBossTarget

        local s = self:ScanCurrentEquipment()
        local isFast = s.isFastWeapon or s.hasShield or s.hasHealingWeapon or s.hasWrathGear
                       or s.hasCustomItem or s.hasUtilityItem or s.hasDaggerInOffhand

        cachedResult = {
            isFast           = isFast,
            scan             = s,
        }

        local frame = self.fastWeaponReminder.frame

        if isFast then
            -- Draw every match rather than the first one that hit. The
            -- labels only fit when a single icon fills the box, so with
            -- more than one the text is dropped and the icons speak for
            -- themselves.
            local drawn = 0
            for _, m in ipairs(s.matches or {}) do
                if drawn >= MAX_ICONS then break end
                local texture = m.icon
                if type(texture) ~= "string" or not texture:find("\\") then
                    texture = GetItemIcon(m.icon)
                end
                if texture then
                    drawn = drawn + 1
                    frame.icons[drawn].texture:SetTexture(texture)
                end
            end

            if drawn == 0 then
                drawn = 1
                frame.icons[1].texture:SetTexture(nil)
            end

            frame.shownIconCount = drawn
            LayoutEquipmentIcons(frame, drawn)

            local first = (s.matches or {})[1]
            if drawn > 1 then
                frame.topText:SetText("")
                frame.headerText:SetText("WARNING")
            else
                frame.topText:SetText((first and first.label) or "")
                frame.headerText:SetText((first and first.header) or "WARNING")
                if first and first.header then frame.topText:SetText("") end
            end

            -- Covers shield/heal/wrath/custom/dagger only - a utility-item
            -- or fast-weapon-only transition does not flip this, so the
            -- flash and sound can be skipped on those changes.
            local statusChanged = (self.fastWeaponReminder.currentShieldStatus        ~= s.hasShield)        or
                                  (self.fastWeaponReminder.currentHealingWeaponStatus ~= s.hasHealingWeapon) or
                                  (self.fastWeaponReminder.currentWrathGearStatus     ~= s.hasWrathGear)     or
                                  (self.fastWeaponReminder.currentCustomItemId        ~= s.customItemId)     or
                                  (self.fastWeaponReminder.currentDaggerInOffhand     ~= s.hasDaggerInOffhand)

            local flashNow = false
            if statusChanged and self.db.fastWeaponReminder.flashOnEquip then
                flashNow = true
                if self.db.fastWeaponReminder.playSound then
                    local soundKey = self.db.fastWeaponReminder.soundKey or "WR: Warning"
                    local soundFile = self.db.fastWeaponReminder.soundFile
                    if RC.GetSoundFile then
                        soundFile = RC:GetSoundFile(soundKey) or soundFile
                    end
                    soundFile = soundFile or "Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg"
                    PlaySoundFile(soundFile, "Master")
                end
            end

            if self.db.fastWeaponReminder.ttsEnabled then
                local ttsPhrase, ttsSig, ttsType = BuildEquipmentTTS(s)
                if ttsPhrase and ttsSig and ttsSig ~= self.fastWeaponReminder.lastTTSSignature then
                    self.fastWeaponReminder.lastTTSSignature = ttsSig
                    if EquipmentTTSTypeEnabled(ttsType) then
                        self.fastWeaponReminder.ttsGen = (self.fastWeaponReminder.ttsGen or 0) + 1
                        self:SpeakTTS(ttsPhrase, false)
                        StartEquipmentTTSRepeat(ttsPhrase, self.fastWeaponReminder.ttsGen)
                    end
                end
            end

            self.fastWeaponReminder.currentWeaponSpeed            = s.mainSpeed
            self.fastWeaponReminder.currentShieldStatus           = s.hasShield
            self.fastWeaponReminder.currentHealingWeaponStatus    = s.hasHealingWeapon
            self.fastWeaponReminder.currentWrathGearStatus        = s.hasWrathGear
            self.fastWeaponReminder.currentCustomItemId           = s.customItemId
            self.fastWeaponReminder.currentDaggerInOffhand        = s.hasDaggerInOffhand

            -- the flash plays once the entrance is done, on a shown frame
            self:ShowEquipmentReminderFrame(frame, flashNow)
        else
            self.fastWeaponReminder.currentWeaponSpeed            = nil
            self.fastWeaponReminder.currentShieldStatus           = false
            self.fastWeaponReminder.currentHealingWeaponStatus    = false
            self.fastWeaponReminder.currentWrathGearStatus        = false
            self.fastWeaponReminder.currentCustomItemId           = nil
            self.fastWeaponReminder.currentDaggerInOffhand        = false
            self.fastWeaponReminder.lastTTSSignature = nil
            self.fastWeaponReminder.ttsGen = (self.fastWeaponReminder.ttsGen or 0) + 1
            self:HideEquipmentReminderFrame(frame)
        end

        if RC.Profiler then RC.Profiler:StopTiming("EquipReminder") end
    end

    RC:InitializeFastWeaponReminderDB()

    C_Timer.After(2, function()
        if RC.UpdateFastWeaponReminder then RC:UpdateFastWeaponReminder() end
    end)
end

C_Timer.After(0.5, InitializeEquipmentReminder)
