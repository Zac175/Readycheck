------------------------------------------------------------------------
-- Readycheck - Consumables State
-- Owns the runtime state tables for all four bars (consumablesHelper,
-- potionsBar, weaponsBar, trinketBar), RC.performanceCache, the palette,
-- and every db default / migration for those bars.
-- RC.performanceCache holds the short-TTL caches the hot path reads
-- instead of hitting WoW APIs; the TTLs here set the whole bar's
-- staleness budget. Loads before Frames/Refresh, which assume these
-- tables already exist.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local UnitAura = UnitAura or (RCC and RCC.Compat and RCC.Compat.UnitAura)
local WRF = _G.Readycheck
if not WRF then return end
WRF._chInit = WRF._chInit or {}
WRF._chs = WRF._chs or {}
WRF._chInit[#WRF._chInit + 1] = function()
    local RC = _G.Readycheck

-- trinketBar is deliberately absent: its buttons carry trinketData, not
-- itemData, so the generic per-button sweeps in EachBar would mis-handle it.
RC.BAR_KEYS = { "consumablesHelper", "potionsBar", "weaponsBar" }
function RC:EachBar()
    local i = 0
    return function()
        i = i + 1
        local k = RC.BAR_KEYS[i]
        if k then return k, RC[k] end
    end
end
    local GetTime = GetTime
    local GetItemCount = GetItemCount or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemCount)
    local GetItemIcon = GetItemIcon or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetItemIcon)
    local UnitBuff = UnitBuff or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.UnitBuff)
    local GetWeaponEnchantInfo = GetWeaponEnchantInfo
    local IsInInstance = IsInInstance
    local IsInRaid = IsInRaid
    local IsResting = IsResting
    local InCombatLockdown = InCombatLockdown
    local UnitGetTotalAbsorbs = UnitGetTotalAbsorbs
    local UnitGUID = UnitGUID
    local UnitCastingInfo = UnitCastingInfo
    local UnitChannelInfo = UnitChannelInfo
    local GetSpellCooldown = GetSpellCooldown or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetSpellCooldown)
    local math_floor = math.floor
    local math_ceil = math.ceil
    local math_max = math.max
    local math_min = math.min
    local math_abs = math.abs
    local string_format = string.format
    local string_lower = string.lower
    local pairs = pairs
    local ipairs = ipairs
    local type = type

    local _chs = WRF._chs
    -- Bar state. Hot-path fields: isRebuilding suppresses ticker work
    -- mid-rebuild; pendingRebuildOnCombatEnd queues secure-button work;
    -- stableStateReached stays false until 2s after a loading screen so
    -- the login burst does no bag-driven rebuilds (Consumables_Events).
    RC.consumablesHelper = {
        frame = nil,
        buttons = {},
        sortedOrder = {},
        placeholder = nil,
        isRebuilding = false,
        initializing = true,
        lastUpdate = 0,
        stableStateReached = false,
        updateThrottle = 0,
        lastZoneCheck = 0,
        cachedShouldShow = nil,
        lastVisibleCount = 0,
        buffExpiredInCombat = false,
        lastBuffCheck = {},
        pendingRebuildOnCombatEnd = false,
        persistentItemCountCache = nil,
        categories = {
            "flasks",
            "elixirs",
            "potions",
            "protectionPotions",
            "food",
			"drinks",
            "buffs",
            "utilities",
            "classItems",
            "chronoboon",
            "special"
        }
    }

    -- Staleness budget for the hot path. Every TTL here is longer than one
    -- 0.2s ticker interval, so a ticker pass costs at most one real API call
    -- per cache even when BAG_UPDATE/UNIT_AURA are firing 20x a second.
    RC.performanceCache = {
        buffs = {},
        buffCacheTTL = 0.25,

        -- "mainhand"/"offhand" are the canonical slot keys addon-wide. Both
        -- entries are always written together from one API call; a reader
        -- inventing another key ("mh", 16) silently duplicates the state.
        weaponEnchants = {
            mainhand = { hasEnchant = false, timeRemaining = 0, enchantId = nil, cacheTime = 0 },
            offhand = { hasEnchant = false, timeRemaining = 0, enchantId = nil, cacheTime = 0 },
        },
        weaponEnchantCacheTTL = 0.5,

        conflictGroups = {},
        conflictGroupCacheTTL = 0.5,

        -- Row/col -> button map used to suppress doubled 1px borders between
        -- adjacent buttons. Dirtied by every rebuild, rebuilt lazily out of
        -- combat only (UpdateButtonStates), never on a per-event path.
        buttonGrid = nil,
        buttonGridDirty = true,

        allBuffs = {},
        allBuffsCacheTime = 0,

        inCombatUpdateInterval = 0.2,
        outOfCombatUpdateInterval = 0.1,
    }

    -- The same consumable buff carries several spellIds across ranks and
    -- server builds, so fall back to matching by localized name - but
    -- refuse a spellId that is tracked as a DIFFERENT consumable, or two
    -- items sharing a buff name claim each other's timers.
    function RC:ResolveConsumableBuff(tbl, buffId)
        if not tbl or not buffId then return nil end
        local hit = tbl[buffId]
        if hit then return hit end
        local want = self._buffNameById and self._buffNameById[buffId]
        if not want then return nil end
        local named = self._namedBuffMatch and self._namedBuffMatch[buffId]
        if named then return self:ResolveNamedConsumableBuff(tbl, named) end
        for sid, bd in pairs(tbl) do
            if bd.name and bd.name:lower() == want then
                local set = self._trackedBuffIdSet
                if not set then
                    set = {}
                    for _, cat in pairs(self.raidConsumables or {}) do
                        if cat.items then
                            for _, idata in pairs(cat.items) do
                                if idata.buffId then set[idata.buffId] = true end
                            end
                        end
                    end
                    self._trackedBuffIdSet = set
                end
                if not (set[sid] and sid ~= buffId) then
                    return bd
                end
            end
        end
        return nil
    end

    -- NAME MATCH (Forever). A row whose aura id is not known (the Forever
    -- foods) carries buffId -itemId and is matched by the buff's name;
    -- when the row names its stat (n = the number, w = the stat word), the
    -- buff's tooltip must show it too, so two foods that both give "Well
    -- Fed" are told apart. A tooltip that cannot be read matches on the
    -- name alone. Read once per buff per aura change, by the coalesced
    -- readers (the bars' passes, the voice watch), never by UNIT_AURA.
    local tipText = setmetatable({}, { __mode = "k" })
    local function BuffTooltip(bd)
        local t = tipText[bd]
        if t == nil then
            t = false
            local lines = bd.index and RC.Compat and RC.Compat.TooltipLines
                and RC.Compat.TooltipLines("unitbuff", "player", bd.index)
            if type(lines) == "table" and #lines > 0 then
                local parts = {}
                for i, l in ipairs(lines) do parts[i] = type(l) == "table" and (l.leftText or l.text or "") or tostring(l) end
                t = table.concat(parts, " "):lower()
            end
            tipText[bd] = t
        end
        return t
    end
    -- the number stands alone ("40" is not in "140" or "400"; "1%" ends
    -- on its own sign)
    local function ShowsStat(text, named)
        local n = named.n
        local pat = "%f[%d]" .. n:gsub("%%", "%%%%")
        if n:find("%d$") then pat = pat .. "%f[^%d]" end
        if not text:find(pat) then return false end
        return text:find(named.w, 1, true) ~= nil
    end
    function RC:ResolveNamedConsumableBuff(tbl, named)
        for sid, bd in pairs(tbl) do
            if bd.name and bd.name:lower() == named.name then
                if not named.n then return bd end
                local text = BuffTooltip(bd)
                if not text or ShowsStat(text, named) then return bd end
            end
        end
        return nil
    end

    -- spellId -> { name, duration, expirationTime } for every buff on the
    -- player, built from the shared aura read (RC.Auras) once per aura
    -- change and shared by the bars, the drain, the rebuild and the voice
    -- watch. Read-only: every reader gets the same table until the next
    -- change. performanceCache.allBuffs / allBuffsCacheTime mirror it.
    -- (index: the buff's slot, kept only where a name match reads tooltips)
    local buffMapVersion
    function RC:SnapshotAllBuffs()
        local cache = self.performanceCache
        local v = RC.Auras:Version()
        if buffMapVersion == v then return cache.allBuffs end
        local map = {}
        local keepIndex = self._namedBuffMatch ~= nil
        for _, a in ipairs(RC.Auras:Buffs()) do
            if a.spellId then
                map[a.spellId] = { name = a.name, duration = a.duration, expirationTime = a.expirationTime }
                if keepIndex then map[a.spellId].index = a.index end
            end
        end
        buffMapVersion = v
        cache.allBuffs, cache.allBuffsCacheTime = map, GetTime()
        return map
    end

    -- Fixed {r,g,b,a} arrays for button states only. Anything user-themable
    -- goes through RC:GetColor() (the Get*Bar* helpers below); these are the
    -- semantic constants the state machine compares against by identity.
    local C = {
        black       = {0,    0,    0,    1},
        white       = {1,    1,    1,    1},
        whiteDim    = {1,    1,    1,    0.7},
        transparent = {0,    0,    0,    0},
        gold        = {1,    0.82, 0,    1},
        green       = {0.2,  0.8,  0.2,  1},
        greenBright = {0.4,  1,    0.4,  1},
        greenDark   = {0.1,  0.5,  0.1,  1},
        red         = {1,    0.2,  0.2,  1},
        redBright   = {1,    0.4,  0.4,  1},
        redMed      = {0.9,  0.3,  0.3,  1},
        redDark     = {0.6,  0.1,  0.1,  1},
        yellow      = {1,    1,    0,    1},
        yellowLight = {1,    1,    0.6,  1},
        blue        = {0.3,  0.6,  1,    1},
        cyan        = {0.3,  1,    1,    1},
    }

    local function GetConsBarBg()
        return RC:GetColor("consumablesBar", "frameBackground")
    end
    local function GetConsBarBorder()
        return RC:GetColor("consumablesBar", "frameBorder")
    end
    local function GetConsBarTitle()
        return RC:GetColor("consumablesBar", "titleText")
    end
    local function GetPotBarBg()
        return RC:GetColor("potionsBar", "frameBackground")
    end
    local function GetPotBarBorder()
        return RC:GetColor("potionsBar", "frameBorder")
    end
    local function GetPotBarTitle()
        return RC:GetColor("potionsBar", "titleText")
    end
    local function GetWeapBarBg()
        return RC:GetColor("weaponBar", "frameBackground")
    end
    local function GetWeapBarBorder()
        return RC:GetColor("weaponBar", "frameBorder")
    end
    local function GetWeapBarTitle()
        return RC:GetColor("weaponBar", "titleText")
    end
    local function GetStoneColor(stoneType)
        if stoneType == "elemental" then
            return RC:GetColor("weaponBar", "elementalStone")
        elseif stoneType == "consecrated" then
            return RC:GetColor("weaponBar", "consecratedStone")
        elseif stoneType == "dense" then
            return RC:GetColor("weaponBar", "denseStone")
        elseif stoneType == "frost" then
            return RC:GetColor("weaponBar", "frostOil")
        end
        return {r = 0, g = 1, b = 0.5}
    end

    RC.potionsBar = {
        frame = nil,
        buttons = {},
        sortedOrder = {},
        placeholder = nil,
        isRebuilding = false,
        initializing = true,
        lastUpdate = 0,
        stableStateReached = false,
        updateThrottle = 0,
        lastZoneCheck = 0,
        cachedShouldShow = nil,
        lastVisibleCount = 0
    }

    RC.weaponsBar = {
        frame = nil,
        buttons = {},
        sortedOrder = {},
        placeholder = nil,
        isRebuilding = false,
        initializing = true,
        lastUpdate = 0,
        stableStateReached = false,
        updateThrottle = 0,
        lastZoneCheck = 0,
        cachedShouldShow = nil,
        lastVisibleCount = 0
    }

    RC.trinketBar = {
        frame = nil,
        buttons = {},
        pendingEquip = {},
        lastUpdate = 0,
        stableStateReached = false,
        updateThrottle = 0.1,
        lastZoneCheck = 0,
        cachedShouldShow = nil,
        trinketCache = {},
        lastScanTime = 0
    }

    RC.consumableCooldown = {
        active = false,
        endTime = 0,
        duration = 0
    }

    RC.elixirCooldown = {
        active = false,
        endTime = 0,
        duration = 0
    }

    RC.modifierPreview = {
        hoveredButton = nil,
        hoveredConflictGroup = nil,
        hoveredOriginalItemId = nil,
        hoveredOriginalTexture = nil,
        hoveredOriginalItemName = nil,
        lastModifierState = nil,
        tickerHandle = nil,
    }

    function RC:GetConflictGroupQuickUse(groupName, modifier)
        if not self.db.consumablesHelper.conflictGroupQuickUse then return nil end
        if not self.db.consumablesHelper.conflictGroupQuickUse[groupName] then return nil end
        return self.db.consumablesHelper.conflictGroupQuickUse[groupName][modifier]
    end

    function RC:SetConflictGroupQuickUse(groupName, modifier, itemId)
        if not self.db.consumablesHelper.conflictGroupQuickUse then
            self.db.consumablesHelper.conflictGroupQuickUse = {}
        end
        if not self.db.consumablesHelper.conflictGroupQuickUse[groupName] then
            self.db.consumablesHelper.conflictGroupQuickUse[groupName] = {}
        end
        self.db.consumablesHelper.conflictGroupQuickUse[groupName][modifier] = itemId
        self:SaveConfigurationToProfile()
    end

    function RC:GetCurrentModifierState()
        if IsControlKeyDown() then return "ctrl"
        elseif IsAltKeyDown() then return "alt"
        elseif IsShiftKeyDown() then return "shift"
        else return "none"
        end
    end

    function RC:GetModifierKeyName(state)
        if state == "ctrl" then return "ctrlClick"
        elseif state == "alt" then return "altClick"
        elseif state == "shift" then return "shiftClick"
        else return "click"
        end
    end

    -- Swaps a conflict-group button's icon to the modifier-bound alternative
    -- while hovered, so ctrl/alt/shift previews what the click will use.
    function RC:UpdateModifierPreviewIcon()
        local preview = self.modifierPreview
        if not preview.hoveredButton or not preview.hoveredConflictGroup then return end

        local modState = self:GetCurrentModifierState()

        -- Edge trigger: the driving ticker runs at 20Hz, so without this the
        -- SetAttribute below would fire on every tick.
        if modState == preview.lastModifierState then return end
        preview.lastModifierState = modState

        local button = preview.hoveredButton
        if not button or not button.icon then return end

        local modKey = self:GetModifierKeyName(modState)
        local quickItemId = self:GetConflictGroupQuickUse(preview.hoveredConflictGroup, modKey)

        if not quickItemId then
            if preview.hoveredOriginalTexture then
                button.icon:SetTexture(preview.hoveredOriginalTexture)
            end
            -- Secure button: the "item" attribute cannot be written in
            -- combat. The icon still updates, so the preview goes visually
            -- stale rather than erroring; the click falls back to the base item.
            if not InCombatLockdown() and preview.hoveredOriginalItemName then
                button:SetAttribute("item", preview.hoveredOriginalItemName)
            end
            return
        end

        local quickIcon = GetItemIcon(quickItemId)
        if quickIcon then
            button.icon:SetTexture(quickIcon)
        end

        if not InCombatLockdown() then
            local quickItemName = GetItemInfo(quickItemId)
            if quickItemName then
                button:SetAttribute("item", quickItemName)
            end
        end
    end

    function RC:RestoreModifierPreviewIcon()
        local preview = self.modifierPreview
        if preview.hoveredButton then
            if preview.hoveredButton.icon and preview.hoveredOriginalTexture then
                preview.hoveredButton.icon:SetTexture(preview.hoveredOriginalTexture)
            end
            if not InCombatLockdown() and preview.hoveredOriginalItemName then
                preview.hoveredButton:SetAttribute("item", preview.hoveredOriginalItemName)
            end
        end

        preview.hoveredButton = nil
        preview.hoveredConflictGroup = nil
        preview.hoveredOriginalItemId = nil
        preview.hoveredOriginalTexture = nil
        preview.hoveredOriginalItemName = nil
        preview.lastModifierState = nil
    end

    function RC:StartModifierPreview(button, conflictGroup, originalItemId)
        if not self.db.consumablesHelper.groupConflictButtons then return end

        local preview = self.modifierPreview
        preview.hoveredButton = button
        preview.hoveredConflictGroup = conflictGroup
        preview.hoveredOriginalItemId = originalItemId
        preview.hoveredOriginalTexture = button.icon and button.icon:GetTexture()
        preview.hoveredOriginalItemName = button:GetAttribute("item")
        preview.lastModifierState = nil

        -- The only sub-0.2s ticker here, and bounded: it exists only between
        -- OnEnter and OnLeave, and cancels itself when hoveredButton clears.
        if not preview.tickerHandle then
            local tickerFn = function()
                if not RC.modifierPreview.hoveredButton or not RC.db.consumablesHelper.groupConflictButtons then
                    RC:StopModifierPreview()
                    return
                end
                RC:UpdateModifierPreviewIcon()
            end
            if RC.Profiler and RC.Profiler.TrackTicker then
                preview.tickerHandle = RC.Profiler:TrackTicker("ConsumablesHelper:ModifierPreview", 0.05, tickerFn)
            else
                preview.tickerHandle = C_Timer.NewTicker(0.05, tickerFn)
            end
        end
    end

    function RC:StopModifierPreview()
        local preview = self.modifierPreview

        if preview.tickerHandle then
            preview.tickerHandle:Cancel()
            preview.tickerHandle = nil
        end

        self:RestoreModifierPreviewIcon()
    end

    RC.absorbTracking = {
        updateThrottle = 0.2,
    }

    RC.potionAbsorbSpells = {}

    -- Classic Era reports no live absorb value for these, so the bar shows
    -- the item's documented min/max range and its midpoint instead.
    function RC:InitializeAbsorbSpells()
        if not self.raidConsumables then return end

        if self.raidConsumables.protectionPotions then
            for itemId, itemData in pairs(self.raidConsumables.protectionPotions.items) do
                if itemData.buffId and itemData.minAbsorb and itemData.maxAbsorb then
                    self.potionAbsorbSpells[itemId] = {
                        spellId = itemData.buffId,
                        minAbsorb = itemData.minAbsorb,
                        maxAbsorb = itemData.maxAbsorb,
                        average = math_floor(itemData.minAbsorb + ((itemData.maxAbsorb - itemData.minAbsorb) / 2)),
                        school = itemData.school
                    }
                end
            end
        end

        -- 13455 = Greater Stoneshield Potion: the one absorb potion filed
        -- under "potions" rather than "protectionPotions", so it misses the
        -- category sweep above and is picked up by id here.
        if self.raidConsumables.potions and self.raidConsumables.potions.items[13455] then
            local stoneShieldData = self.raidConsumables.potions.items[13455]
            if stoneShieldData.buffId and stoneShieldData.minAbsorb and stoneShieldData.maxAbsorb then
                self.potionAbsorbSpells[13455] = {
                    spellId = stoneShieldData.buffId,
                    minAbsorb = stoneShieldData.minAbsorb,
                    maxAbsorb = stoneShieldData.maxAbsorb,
                    average = math_floor(stoneShieldData.minAbsorb + ((stoneShieldData.maxAbsorb - stoneShieldData.minAbsorb) / 2)),
                    school = nil
                }
            end
        end

        RC.potionAbsorbSpellIds = {}
        for itemId, data in pairs(self.potionAbsorbSpells) do
            if data.spellId then
                RC.potionAbsorbSpellIds[data.spellId] = itemId
            end
        end
    end

    -- Intentionally empty: Classic Era exposes no absorb-remaining API.
    -- Kept because Consumables_Runtime calls it on a post-login timer.
    function RC:LoadCurrentAbsorbs()
    end

    -- db defaults and migrations, run once per login before any frame
    -- exists. Each `== nil` guard backfills one key; plain `or` would
    -- clobber a deliberate `false`.
    if not RC.db.consumablesHelper then
        RC.db.consumablesHelper = {
            enabled = true,
            locked = false,
            showOnlyAvailable = false,
            hideWhenActive = true,
            hideConflictingBuffs = true,
            showBeforeExpiry = 60,
            buttonSize = 36,
            buttonsPerRow = 2,
            anchorPoint = "TOPRIGHT",
            xOffset = -10,
            yOffset = -200,
            hideInCombat = false,
            showTooltips = false,
            showCount = true,
            showExpiryTimer = true,
            showItemNames = false,
            scale = 1.0,
            growDirection = "DOWN",
            hiddenItems = {},
            visibilityMode = "always",
            showBackground = true,
            iconSpacing = 4,
            selfCastJujus = true,
            showWeaponIcons = true,
            showBagWeapons = false,
            selectedStoneType = 18262
        }
    end

    if RC.db.consumablesHelper.showOnlyAvailable == nil then
        RC.db.consumablesHelper.showOnlyAvailable = false
    end

    if RC.db.consumablesHelper.selfCastJujus == nil then
        RC.db.consumablesHelper.selfCastJujus = true
    end

    if RC.db.consumablesHelper.showExpiryTimer == nil then
        RC.db.consumablesHelper.showExpiryTimer = true
    end

    if not RC.db.consumablesHelper.hiddenItems then
        RC.db.consumablesHelper.hiddenItems = {}
    end

    if not RC.db.consumablesHelper.hiddenWeapons then
        RC.db.consumablesHelper.hiddenWeapons = {}
    end

    if not RC.db.potionsBar then
        RC.db.potionsBar = {
            enabled = false,
            locked = false,
            showOnlyAvailable = false,
            hideWhenActive = true,
            hideConflictingBuffs = false,
            showBeforeExpiry = 60,
            buttonSize = 36,
            buttonsPerRow = 2,
            anchorPoint = "TOPRIGHT",
            xOffset = -10,
            yOffset = -400,
            hideInCombat = false,
            showTooltips = false,
            showCount = true,
            showExpiryTimer = true,
            showItemNames = false,
            scale = 1.0,
            growDirection = "DOWN",
            hiddenItems = {},
            visibilityMode = "always",
            showBackground = true,
            iconSpacing = 4
        }
    end

    if RC.db.potionsBar.showExpiryTimer == nil then
        RC.db.potionsBar.showExpiryTimer = true
    end

    if RC.db.potionsBar.showOnlyAvailable == nil then
        RC.db.potionsBar.showOnlyAvailable = false
    end

    RC.db.consumablesHelper.hiddenItems = RC.db.consumablesHelper.hiddenItems or {}
    RC.db.consumablesHelper.visibilityMode = RC.db.consumablesHelper.visibilityMode or "always"
    -- visibilityRaids ({ [raidName]=true }, optional) narrows the raid modes
    -- to the ticked raids; nil/empty = every raid, so no default is seeded.
    RC.db.consumablesHelper.iconSpacing = RC.db.consumablesHelper.iconSpacing or 4
    RC.db.consumablesHelper.buttonSize = RC.db.consumablesHelper.buttonSize or 36
    RC.db.consumablesHelper.buttonsPerRow = RC.db.consumablesHelper.buttonsPerRow or 2
    RC.db.consumablesHelper.growDirection = RC.db.consumablesHelper.growDirection or "DOWN"
    if RC.db.consumablesHelper.consumableTTSEnabled == nil then
        RC.db.consumablesHelper.consumableTTSEnabled = false
    end
    -- 100 to match RC.defaults; this used to seed 50 on profiles that
    -- predate the default, so the same setting had two different values
    -- depending on how old the character was.
    RC.db.consumablesHelper.consumableTTSVolume = RC.db.consumablesHelper.consumableTTSVolume or 100
    if RC.db.consumablesHelper.potionReadyTTS == nil then
        RC.db.consumablesHelper.potionReadyTTS = false
    end

    -- ttsNameOverrides is keyed by localized item name, unstable across
    -- locales. Re-key into consumableTTSSettings by itemId, then nil the
    -- old table so this runs at most once per character.
    do
        local ov = RC.db.consumablesHelper.ttsNameOverrides
        if ov then
            local ts = RC.db.consumablesHelper.consumableTTSSettings or {}
            RC.db.consumablesHelper.consumableTTSSettings = ts
            local nameToId = {}
            for _, cat in pairs(RC.raidConsumables or {}) do
                if cat.items then
                    for id, d in pairs(cat.items) do
                        if d.name then nameToId[d.name] = id end
                    end
                end
            end
            for name, val in pairs(ov) do
                local builtIn = (RC.ttsSpokenNames and RC.ttsSpokenNames[name])
                    or (RC.ShortenConsumableName and RC.ShortenConsumableName(name))
                if val and val ~= "" and val ~= builtIn then
                    local id = nameToId[name]
                    if id then
                        local k = tostring(id)
                        ts[k] = ts[k] or {}
                        if not ts[k].ttsText or ts[k].ttsText == "" then
                            ts[k].ttsText = val
                        end
                    end
                end
            end
            RC.db.consumablesHelper.ttsNameOverrides = nil
        end
    end
    if RC.db.potionsBar then
        if RC.db.potionsBar.ttsEnabled == nil then RC.db.potionsBar.ttsEnabled = false end
    end
    if RC.db.weaponsBar then
        if RC.db.weaponsBar.ttsEnabled == nil then RC.db.weaponsBar.ttsEnabled = false end
    end
    if RC.db.consumablesHelper.showItemNames == nil then
        RC.db.consumablesHelper.showItemNames = false
    end
    if RC.db.consumablesHelper.groupConflictButtons == nil then
        RC.db.consumablesHelper.groupConflictButtons = true
    end
    RC.db.potionsBar.hiddenItems = RC.db.potionsBar.hiddenItems or {}
    RC.db.potionsBar.visibilityMode = RC.db.potionsBar.visibilityMode or "always"
    -- visibilityRaids ({ [raidName]=true }, optional) narrows the raid modes
    -- to the ticked raids; nil/empty = every raid, so no default is seeded.
    RC.db.potionsBar.iconSpacing = RC.db.potionsBar.iconSpacing or 4
    RC.db.potionsBar.buttonSize = RC.db.potionsBar.buttonSize or 36
    RC.db.potionsBar.buttonsPerRow = RC.db.potionsBar.buttonsPerRow or 2
    RC.db.potionsBar.growDirection = RC.db.potionsBar.growDirection or "DOWN"
    if RC.db.potionsBar.showItemNames == nil then
        RC.db.potionsBar.showItemNames = false
    end

    if not RC.db.weaponsBar then
        RC.db.weaponsBar = {
            enabled = false,
            locked = false,
            buttonSize = 36,
            buttonsPerRow = 4,
            anchorPoint = "TOPRIGHT",
            xOffset = -10,
            yOffset = -300,
            hideInCombat = false,
            showTooltips = false,
            showCount = true,
            scale = 1.0,
            growDirection = "RIGHT",
            visibilityMode = "always",
            showBackground = true,
            iconSpacing = 4,
            showExpiryTimer = true,
            showBeforeExpiry = 60,
            showEquippedWeapons = true,
            showBagWeapons = false
        }
    end
    RC.db.weaponsBar.visibilityMode = RC.db.weaponsBar.visibilityMode or "always"
    -- visibilityRaids ({ [raidName]=true }, optional) narrows the raid modes
    -- to the ticked raids; nil/empty = every raid, so no default is seeded.
    RC.db.weaponsBar.iconSpacing = RC.db.weaponsBar.iconSpacing or 4
    RC.db.weaponsBar.buttonSize = RC.db.weaponsBar.buttonSize or 36
    RC.db.weaponsBar.buttonsPerRow = RC.db.weaponsBar.buttonsPerRow or 4
    RC.db.weaponsBar.growDirection = RC.db.weaponsBar.growDirection or "RIGHT"
    if RC.db.weaponsBar.showExpiryTimer == nil then
        RC.db.weaponsBar.showExpiryTimer = true
    end
    if RC.db.weaponsBar.showBeforeExpiry == nil then
        RC.db.weaponsBar.showBeforeExpiry = 60
    end
    if RC.db.weaponsBar.showItemNames == nil then
        RC.db.weaponsBar.showItemNames = false
    end
    if RC.db.weaponsBar.showBackground == nil then
        RC.db.weaponsBar.showBackground = true
    end
    if RC.db.weaponsBar.showCount == nil then
        RC.db.weaponsBar.showCount = true
    end
    -- Horde Mode is read through RC:IsHordeMode (below), never stored as
    -- one flag: see there.
    if RC.db.weaponsBar.showEquippedWeapons == nil then
        RC.db.weaponsBar.showEquippedWeapons = true
    end
    if RC.db.weaponsBar.showBagWeapons == nil then
        RC.db.weaponsBar.showBagWeapons = true
    end
    if not RC.db.weaponsBar.hiddenWeapons then
        RC.db.weaponsBar.hiddenWeapons = {}
    end

    if not RC.db.trinketBar then
        RC.db.trinketBar = {
            enabled = false,
            locked = false,
            buttonSize = 36,
            buttonsPerRow = 4,
            anchorPoint = "TOPRIGHT",
            xOffset = -10,
            yOffset = -400,
            hideInCombat = false,
            showTooltips = false,
            scale = 1.0,
            growDirection = "RIGHT",
            visibilityMode = "always",
            showBackground = true,
            iconSpacing = 4,
            showCooldownText = true,
            showSlotNumbers = true,
            showEquippedOnly = false,
            hiddenTrinkets = {}
        }
    end
    RC.db.trinketBar.visibilityMode = RC.db.trinketBar.visibilityMode or "always"
    -- visibilityRaids ({ [raidName]=true }, optional) narrows the raid modes
    -- to the ticked raids; nil/empty = every raid, so no default is seeded.
    RC.db.trinketBar.iconSpacing = RC.db.trinketBar.iconSpacing or 4
    RC.db.trinketBar.buttonSize = RC.db.trinketBar.buttonSize or 36
    RC.db.trinketBar.buttonsPerRow = RC.db.trinketBar.buttonsPerRow or 4
    RC.db.trinketBar.maxRows = RC.db.trinketBar.maxRows or 5
    RC.db.trinketBar.growDirection = RC.db.trinketBar.growDirection or "RIGHT"
    if RC.db.trinketBar.showBackground == nil then
        RC.db.trinketBar.showBackground = true
    end
    if RC.db.trinketBar.showCooldownText == nil then
        RC.db.trinketBar.showCooldownText = true
    end
    if RC.db.trinketBar.showSlotNumbers == nil then
        RC.db.trinketBar.showSlotNumbers = true
    end
    if RC.db.trinketBar.showEquippedOnly == nil then
        RC.db.trinketBar.showEquippedOnly = false
    end
    if RC.db.trinketBar.showBagOnly == nil then
        RC.db.trinketBar.showBagOnly = false
    end
    if not RC.db.trinketBar.hiddenTrinkets then
        RC.db.trinketBar.hiddenTrinkets = {}
    end

    if RC.db.consumablesHelper.showWeaponIcons == nil then
        RC.db.consumablesHelper.showWeaponIcons = true
    end
    if RC.db.consumablesHelper.showBagWeapons == nil then
        RC.db.consumablesHelper.showBagWeapons = false
    end
    -- 18262 = Elemental Sharpening Stone, the default weapon enchant choice.
    if RC.db.consumablesHelper.selectedStoneType == nil then
        RC.db.consumablesHelper.selectedStoneType = 18262
    end
    -- _chs is the cross-file upvalue bag: these are consumed by Frames,
    -- Refresh and Buttons, which cannot see this file's locals.
    _chs.C = C
    _chs.GetConsBarBg = GetConsBarBg
    _chs.GetConsBarBorder = GetConsBarBorder
    _chs.GetConsBarTitle = GetConsBarTitle
    _chs.GetPotBarBg = GetPotBarBg
    _chs.GetPotBarBorder = GetPotBarBorder
    _chs.GetPotBarTitle = GetPotBarTitle
    _chs.GetWeapBarBg = GetWeapBarBg
    _chs.GetWeapBarBorder = GetWeapBarBorder
    _chs.GetWeapBarTitle = GetWeapBarTitle
    _chs.GetStoneColor = GetStoneColor
end

------------------------------------------------------------------------
-- HORDE MODE - hides the main-hand stone and oil buttons (Horde warriors
-- run Windfury Totem on the main hand). Kept PER BAR ("weaponsBar",
-- "consumablesHelper") and PER FACTION: db[bar].hordeByFaction =
-- { Horde = true|false, Alliance = true|false }, unset meaning "on for
-- Horde, off for Alliance". It used to be one flag; settings travel
-- between characters (sync, copy, import), so a Horde character's "on"
-- reached Alliance characters and stuck there. Now each faction's choice
-- only ever applies to that faction, and each bar's only to that bar.
------------------------------------------------------------------------
local function PlayerFaction()
    local f = UnitFactionGroup and UnitFactionGroup("player")
    if f == "Horde" or f == "Alliance" then return f end
    return nil
end

function WRF:IsHordeMode(barKey)
    -- (2026-11-09) not on TBC: both factions have Windfury Totem there
    if self.Flavor and self:Flavor() == "tbc" then return false end
    local faction = PlayerFaction()
    local db = self.db and self.db[barKey]
    local set = db and type(db.hordeByFaction) == "table" and db.hordeByFaction or nil
    local v = set and faction and set[faction]
    if v == nil then return faction == "Horde" end
    return v and true or false
end

function WRF:SetHordeMode(barKey, on)
    if not self.db then return end
    self.db[barKey] = self.db[barKey] or {}
    local db = self.db[barKey]
    if type(db.hordeByFaction) ~= "table" then db.hordeByFaction = {} end
    local faction = PlayerFaction()
    if faction then db.hordeByFaction[faction] = on and true or false end
end
