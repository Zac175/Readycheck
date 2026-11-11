local RCC = _G.Readycheck
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local GetItemInfoInstant = GetItemInfoInstant or (RCC and RCC.Compat and RCC.Compat.GetItemInfoInstant)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)
local UnitDebuff = UnitDebuff or (RCC and RCC.Compat and RCC.Compat.UnitDebuff)
local AddonName = "Readycheck"
local RC = _G[AddonName]

if not RC then
    error("Readycheck core not found!")
end

local pairs, ipairs, tostring = pairs, ipairs, tostring
local GetTime = GetTime
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GetInventoryItemID = GetInventoryItemID
local C_Container = C_Container
local C_Timer = C_Timer
RC._gms = RC._gms or {}
local GM = RC.GearManager
------------------------------------------------------------------------
-- Readycheck - Gear Manager Runtime
-- GM:Initialize(): settings load/migration, event wiring, and the
-- Alt+Click-on-character-model button toggle. Also owns the button
-- cooldown ticker (StartButtonCooldownUpdates/UpdateButtonCooldowns,
-- guarded by self.buttonCooldownTimer, auto-stopped when nothing is on
-- cooldown) and the Fungal Bloom auto-swap watcher (GM:CheckFungalBloom,
-- woken by the shared aura callback only when Fungal Bloom changes).
-- High-frequency events (BAG_UPDATE_COOLDOWN, SPELL_UPDATE_COOLDOWN,
-- UNIT_INVENTORY_CHANGED) only restart that guarded ticker or flip a
-- dirty flag behind a short C_Timer - never per-event work. The PLAYER_LOGIN
-- block at the bottom is a separate system: the on-use speed-swap item
-- revert watcher (reverts a trinket/belt once its use buff ends).
------------------------------------------------------------------------
function GM:Lock()
    self.locked = true
    self.settings.buttonsLocked = true

    for slot, buttonData in pairs(self.buttonData) do
        buttonData.locked = true
    end

    self:UpdateAllLockIcons()

    if RC.SidebarState and RC.SidebarState.currentPanel == "gear_manager" then
        if RC.sidebarConfigFrame and RC.sidebarConfigFrame.scrollChild and RC.ShowSidebarGearManagerConfig then
            RC:ShowSidebarGearManagerConfig(RC.sidebarConfigFrame)
        end
    end

    self:SaveSettings()
    self:DebugPrint("All buttons LOCKED")
end

function GM:Unlock()
    self.locked = false
    self.settings.buttonsLocked = false

    for slot, buttonData in pairs(self.buttonData) do
        buttonData.locked = false
    end

    self:UpdateAllLockIcons()

    if RC.SidebarState and RC.SidebarState.currentPanel == "gear_manager" then
        if RC.sidebarConfigFrame and RC.sidebarConfigFrame.scrollChild and RC.ShowSidebarGearManagerConfig then
            RC:ShowSidebarGearManagerConfig(RC.sidebarConfigFrame)
        end
    end

    self:SaveSettings()
    self:DebugPrint("All buttons UNLOCKED")
end

function GM:UpdateAllLockIcons()
    if self.settings and self.settings.buttonsLocked ~= nil then
        self.locked = self.settings.buttonsLocked
    end

    local isLocked = self.locked or self.settings.buttonsLocked
    self:DebugPrint("UpdateAllLockIcons: isLocked = " .. tostring(isLocked) .. " (GM.locked=" .. tostring(self.locked) .. ", settings.buttonsLocked=" .. tostring(self.settings.buttonsLocked) .. ")")

    for slot, button in pairs(self.buttons) do
        if isLocked then
            if button.lockIcon then
                button.lockIcon:Hide()
            end
            if button.closeBtn then
                button.closeBtn:Hide()
            end
        else
            if button.lockIcon then
                button.lockIcon:Show()
            end
            if button.closeBtn then
                button.closeBtn:Show()
            end
        end
    end
end

function GM:SaveSettings()
    self:DebugPrint("SaveSettings CALLED")

    if not RC.db then
        self:Print(RCL["ERROR: WR.db is nil in SaveSettings!"])
        return
    end
    if not RC.db.gearManager then RC.db.gearManager = {} end
    if not RC.db.gearManager.settings then RC.db.gearManager.settings = {} end

    self.settingsLoaded = true

    -- SaveSettings runs on every options change and walks ~30 settings, so
    -- the per-setting line is only formatted when "gear" debug is on.
    local dbg = RC.IsDebugEnabled and RC:IsDebugEnabled("gear")
    for key, value in pairs(self.settings) do
        RC.db.gearManager.settings[key] = value
        if dbg then
            self:DebugPrint(string.format(RCL["Saved setting: %s = %s"], key, tostring(value)))
        end
    end

    if RC.SaveConfigurationToProfile then
        RC:SaveConfigurationToProfile()
        self:DebugPrint("Called SaveConfigurationToProfile")
    else
        self:Print(RCL["ERROR: WR.SaveConfigurationToProfile is nil!"])
    end
end

-- Loatheb's Fungal Bloom: the set for while it is up, and the set for
-- when it falls off (the boss's Loatheb profile picks both).
function GM:CheckFungalBloom()
    local bloom = RC.Auras:Debuff(29232)
    local isActive = bloom ~= nil
    local expTime  = bloom and bloom.expirationTime or 0

    GM:DebugPrint(string.format(
        RCL["UNIT_AURA fungalBloom: isActive=%s wasActive=%s expTime=%.1f"],
        tostring(isActive), tostring(GM.fungalBloomWasActive), expTime
    ), "gear")

    local activeSet  = GM.settings.fungalBloomActiveSet or ""
    local falloffSet = GM.settings.fungalBloomSet or ""

    local function FlushSetFromQueue(setName)
        if not setName or setName == "" then return end
        if RC.gearSwapQueue then
            for qi = #RC.gearSwapQueue, 1, -1 do
                if RC.gearSwapQueue[qi] == setName then
                    table.remove(RC.gearSwapQueue, qi)
                    GM:DebugPrint("FlushSetFromQueue: removed stale entry for " .. setName, "gear")
                end
            end
        end
    end

    if not GM.fungalBloomWasActive and isActive then
        GM:DebugPrint("Fungal Bloom GAINED - targeting set: " .. activeSet, "gear")
        FlushSetFromQueue(falloffSet)
        if activeSet ~= "" then
            RC:EquipGearSet(activeSet)
        end

    elseif GM.fungalBloomWasActive and not isActive then
        GM:DebugPrint("Fungal Bloom FELL OFF - queuing set: " .. falloffSet, "gear")
        FlushSetFromQueue(activeSet)
        if falloffSet ~= "" then
            RC:EquipGearSet(falloffSet)
        end
    end

    GM.fungalBloomWasActive = isActive
end

function GM:Initialize()
    if not RC or not RC.db then
        C_Timer.After(0.5, function() GM:Initialize() end)
        return
    end

    self:DebugPrint("=== GearManager Initialize START ===")
    self:DebugPrint("WR.db exists: " .. tostring(RC.db ~= nil))

    local existingSetCount = 0
    if RC.db.gearSets then
        for _ in pairs(RC.db.gearSets) do
            existingSetCount = existingSetCount + 1
        end
        self:DebugPrint("Found " .. existingSetCount .. " existing gear sets in WR.db.gearSets")
    else
        self:DebugPrint("WR.db.gearSets is nil - will create empty table")
    end

    if not RC.db.gearButtons then RC.db.gearButtons = {} end
    if not RC.db.gearButtonPositions then RC.db.gearButtonPositions = {} end
    if not RC.db.gearPinnedButtons then RC.db.gearPinnedButtons = {} end
    if not RC.db.gearManager then RC.db.gearManager = {} end
    if not RC.db.gearSets then
        RC.db.gearSets = {}
        self:DebugPrint("Created empty WR.db.gearSets table")
    end

    if RC.db.gearManager.enabled ~= nil then
        self.enabled = RC.db.gearManager.enabled
    else
        self.enabled = false
        RC.db.gearManager.enabled = false
    end

    if not RC.db.gearManager.settings then
        RC.db.gearManager.settings = {}
        self:DebugPrint("Created empty WR.db.gearManager.settings table")
    end

    for key, value in pairs(RC.db.gearManager.settings) do
        if self.settings[key] ~= nil then
            self.settings[key] = value
            self:DebugPrint(string.format(RCL["Loaded setting: %s = %s"], key, tostring(value)))
        end
    end

    -- showCooldownText is a legacy single setting now split into
    -- showCooldownTextButtons/Menus; back-fill both from it once, then
    -- clear it so this block is a no-op on every subsequent login.
    do
        local saved = RC.db.gearManager.settings
        if saved and saved.showCooldownText ~= nil then
            if saved.showCooldownTextButtons == nil then
                self.settings.showCooldownTextButtons = saved.showCooldownText
            end
            if saved.showCooldownTextMenus == nil then
                self.settings.showCooldownTextMenus = saved.showCooldownText
            end
            saved.showCooldownText = nil
            self:DebugPrint("Migrated legacy showCooldownText into split keys")
        end
    end

    -- Restored before RestoreButtonsFromProfile/UpdateGearSetButtonIcon
    -- run, so GetCurrentEquippedSet has a same-session hint to fall back
    -- on if no set matches gear exactly at login.
    if self.settings.lastEquippedSetName and self.settings.lastEquippedSetName ~= "" then
        self.lastEquippedSetName = self.settings.lastEquippedSetName
        self:DebugPrint("Restored lastEquippedSetName from profile: " .. self.lastEquippedSetName)
    end

    self.locked = self.settings.buttonsLocked or false
    self:DebugPrint("Initialize: Synchronized lock state = " .. tostring(self.locked))

    self.settingsLoaded = true
    self:DebugPrint("Initialize: Settings loaded, settingsLoaded flag set")

    function GM:SyncFungalBloom()
        local fb = nil
        if RC and RC.GetActiveRaidProfile then
            local naxxProfile = RC:GetActiveRaidProfile("Naxxramas")
            if naxxProfile and naxxProfile.bosses and naxxProfile.bosses["Loatheb"] then
                fb = naxxProfile.bosses["Loatheb"].fungalBloom
            end
        end
        if fb then
            self.settings.fungalBloomEnabled   = fb.enabled    or false
            self.settings.fungalBloomActiveSet = fb.activeSet  or ""
            self.settings.fungalBloomSet       = fb.falloffSet or ""
            self:DebugPrint(string.format(
                RCL["SyncFungalBloom: enabled=%s activeSet=%s falloffSet=%s"],
                tostring(self.settings.fungalBloomEnabled),
                tostring(self.settings.fungalBloomActiveSet),
                tostring(self.settings.fungalBloomSet)
            ), "gear")
        else
            self.settings.fungalBloomEnabled   = false
            self.settings.fungalBloomActiveSet = ""
            self.settings.fungalBloomSet       = ""
            self:DebugPrint("SyncFungalBloom: no Loatheb profile found, disabled", "gear")
        end
    end

    C_Timer.After(1.5, function() GM:SyncFungalBloom() end)

    self:LoadSets()

    C_Timer.After(0.2, function()
        for setName, setData in pairs(GM.sets) do
            GM:EnsureEquipButton(setName)
            if setData.keybind and setData.keybind ~= "" then
                local btnName = GM:GetEquipButtonName(setName)
                SetBinding(setData.keybind, "CLICK " .. btnName .. ":LeftButton")
                GM:DebugPrint("Restored keybind '" .. setData.keybind .. "' for set: " .. setName, "gear")
            end
        end
    end)

    if self.enabled then
        C_Timer.After(0.5, function()
            self:RestoreButtonsFromProfile()
            C_Timer.After(0.3, function()
                self:UpdateAllButtonIcons()
                self:ScheduleGearSetStatusRefresh()
            end)
        end)
    end

    C_Timer.After(1, function()
        local characterModel = CharacterModelFrame or CharacterModelScene
        if characterModel then
            GM.oldCharacterModelFrame_OnMouseUp = characterModel:GetScript("OnMouseUp")
            if GM.oldCharacterModelFrame_OnMouseUp then
                characterModel:SetScript("OnMouseUp", function(frame, button)
                    if IsAltKeyDown() and GM.enabled then
                        GM:DebugPrint("Alt+Click detected on character model")
                        if GM.buttons[999] then
                            GM:RemoveButton(999)
                        else
                            GM:CreateButton(999)
                        end
                    end
                    if GM.oldCharacterModelFrame_OnMouseUp then
                        GM.oldCharacterModelFrame_OnMouseUp(frame, button)
                    end
                end)
            else
                characterModel:SetScript("OnMouseUp", function(frame, button)
                    if IsAltKeyDown() and GM.enabled then
                        GM:DebugPrint("Alt+Click detected on character model")
                        if GM.buttons[999] then
                            GM:RemoveButton(999)
                        else
                            GM:CreateButton(999)
                        end
                    end
                end)
            end
            GM:DebugPrint("Character model hook installed successfully")
        else
            GM:Print(RCL["WARNING: Could not find CharacterModelFrame - Alt+Click on model will not work"])
        end
    end)

    self.frame = CreateFrame("Frame")
    self.frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    self.frame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    self.frame:RegisterEvent("PLAYER_LOGIN")
    self.frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    self.frame:RegisterEvent("BAG_UPDATE_COOLDOWN")
    self.frame:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", "player")
    self.frame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    self.frame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    self.frame:RegisterEvent("EQUIP_BIND_CONFIRM")
    -- (not every client still has this event; a missing one must not stop the rest)
    pcall(self.frame.RegisterEvent, self.frame, "EQUIP_BIND_REFUNDABLE_CONFIRM")
    self.frame:RegisterEvent("USE_BIND_CONFIRM")

    local function gearManagerOnEvent(frame, event, ...)
        if event == "PLAYER_ENTERING_WORLD" or event == "PLAYER_LOGIN" then
            GM.locked = false
            GM:DebugPrint("Reset GM.locked to false for potential character switch")

            if RC.db and RC.db.gearManager and RC.db.gearManager.settings then
                if RC.db.gearManager.settings.buttonsLocked ~= nil then
                    GM.locked = RC.db.gearManager.settings.buttonsLocked
                    GM.settings.buttonsLocked = RC.db.gearManager.settings.buttonsLocked
                    GM:DebugPrint("Early load of lock state from profile: " .. tostring(GM.locked))
                end
            end

            if RC.db and RC.db.gearButtons then
                local buttonCount = 0
                for slot, active in pairs(RC.db.gearButtons) do
                    if active then
                        buttonCount = buttonCount + 1
                    end
                end
                GM:DebugPrint("DB contains " .. buttonCount .. " button(s) - waiting for profile load to restore")
            end

            C_Timer.After(4, function()
                if RC.db and RC.db.gearManager and RC.db.gearManager.settings then
                    if RC.db.gearManager.settings.buttonsLocked ~= nil then
                        GM.locked = RC.db.gearManager.settings.buttonsLocked
                        GM.settings.buttonsLocked = RC.db.gearManager.settings.buttonsLocked
                    end
                end
                GM:UpdateAllLockIcons()
                GM:DebugPrint("Final post-login lock icon update, locked=" .. tostring(GM.locked))
            end)

            GM:StartButtonCooldownUpdates()

            -- CRITICAL: Force immediate cooldown updates after buttons are restored
            -- Multiple updates to ensure cooldowns are caught (C_Container API can be delayed)
            C_Timer.After(2, function()
                if GM.buttons[13] or GM.buttons[14] then
                    GM:UpdateButtonCooldowns()
                    GM:DebugPrint("Early cooldown update (2s)")
                end
            end)

            C_Timer.After(4, function()
                if GM.buttons[13] or GM.buttons[14] then
                    GM:UpdateButtonCooldowns()
                    GM:DebugPrint("Mid cooldown update (4s)")
                end
            end)

            C_Timer.After(6, function()
                if GM.buttons[13] or GM.buttons[14] then
                    GM:UpdateButtonCooldowns()
                    GM:DebugPrint("Login cooldown update applied")
                end
            end)

            C_Timer.After(2, function()
                GM:SetupCharacterSheetQueueIndicators()
                GM:DebugPrint("Character sheet queue indicators initialized")
            end)

            C_Timer.After(3, function()
                if GM and GM.SyncFungalBloom then
                    GM:SyncFungalBloom()
                end
            end)
        elseif event == "PLAYER_EQUIPMENT_CHANGED" then
            -- The slot that changed repaints now - one button, a couple of
            -- reads. Everything else (all icons, cooldowns, set status)
            -- still waits for the debounced pass, which is what a full
            -- set swap's burst of these events needs.
            local changedSlot = ...
            if changedSlot and GM.buttons[changedSlot] then
                GM:UpdateButtonIcon(changedSlot)
            end
            GM:ScheduleEquipmentRefresh()
            GM:ScheduleGearSetStatusRefresh()
            if not GM.buttonCooldownTimer then
                GM:StartButtonCooldownUpdates()
            end
        elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
            local unit = ...
            if unit == "player" then
                GM:StartButtonCooldownUpdates()
            end
        -- StartButtonCooldownUpdates is a no-op once the ticker is already
        -- running, so calling it on every cooldown event costs nothing.
        elseif event == "BAG_UPDATE_COOLDOWN" or event == "SPELL_UPDATE_COOLDOWN" then
            if event == "SPELL_UPDATE_COOLDOWN" and RC.Profiler and RC.Profiler.CountHit then
                RC.Profiler:CountHit("Event:SPELL_UPDATE_COOLDOWN(gear)")
            end
            GM:StartButtonCooldownUpdates()
        elseif event == "UNIT_INVENTORY_CHANGED" then
            local unit = ...
            if unit == "player" then
                if not GM.buttonCooldownTimer then
                    GM:StartButtonCooldownUpdates()
                end
                -- Coalesces bursts of UNIT_INVENTORY_CHANGED (e.g. a full
                -- bag move) into a single UpdateButtonCooldowns call.
                if not GM._invChangedPending then
                    GM._invChangedPending = true
                    C_Timer.After(0.1, function()
                        GM._invChangedPending = false
                        GM:UpdateButtonCooldowns()
                    end)
                end
            end
        elseif event == "EQUIP_BIND_CONFIRM" or event == "EQUIP_BIND_REFUNDABLE_CONFIRM" then
            local slot = ...
            GM:DebugPrint("EQUIP_BIND_CONFIRM fired for slot " .. tostring(slot) .. ", pendingEquipSlot=" .. tostring(GM.pendingEquipSlot))
            if slot and GM.pendingEquipSlot == slot then
                GM:DebugPrint("Auto-confirming equip bind for slot " .. slot)
                EquipPendingItem(slot)
                GM.pendingEquipSlot = nil
                GM.pendingEquipTime = nil
            elseif slot then
                GM:DebugPrint("Bind confirm for slot " .. slot .. " - not from GearManager, letting dialog show")
            end
        elseif event == "USE_BIND_CONFIRM" then
            local slot = ...
            if slot and GM.pendingEquipSlot == slot then
                GM:DebugPrint("Auto-confirming use bind for slot " .. slot)
                ConfirmBindOnUse()
                GM.pendingEquipSlot = nil
            end
        elseif event == "GET_ITEM_INFO_RECEIVED" then
            local itemID, success = ...
            if success and itemID then
                for slot, button in pairs(GM.buttons) do
                    if slot ~= 999 and button and button.nameText and not button.nameText:IsShown() then
                        local equippedID = GetInventoryItemID("player", slot)
                        if equippedID == itemID then
                            GM:UpdateButtonIcon(slot)
                        end
                    end
                end
            end
        end
    end

    self.frame:SetScript("OnEvent", gearManagerOnEvent)
    -- set completeness (the set button's colour) follows the bags through
    -- the shared bag index: only real changes, already coalesced
    RC.Bags:OnChange("GearManager", function() GM:ScheduleGearSetStatusRefresh() end)
    -- woken only when Fungal Bloom (29232) itself changes, not by every
    -- other aura in a raid
    RC:RegisterUnitAuraCallback("GearManagerFungalBloom", 0.1, function()
        if GM.settings.fungalBloomEnabled then GM:CheckFungalBloom() end
    end, { 29232 })

    self:DebugPrint("Ready! Alt+Click slots to create buttons | /rc hotswap bshout / flask / bloodrage for hotswap actions")
end

-- One readout formatter for all three cooldown-text paths in
-- UpdateButtonCooldowns (trinket slot, on-use item, plain item), which
-- used to carry three near-identical copies of this block.
-- buffRemaining > 0 means a use-buff is running: show the green buff
-- countdown and swirl the buff. Otherwise show the cooldown countdown
-- (minutes past 60s) and swirl the cooldown. Returns text, r, g, b.
local CD_EASE = 0.3

-- The first cooldown painted after a slot's item changed eases in behind
-- the icon's cross-fade (PlaySwapAnim, GM_Buttons.lua, stamps
-- _cdEaseUntil) instead of snapping on. If the outgoing cooldown is
-- still fading out, the fade turns round from where it is, so the swipe
-- dips and comes back as one movement. Past the window it is a plain show.
local function EaseCooldownIn(button)
    local easeUntil = button._cdEaseUntil
    if not easeUntil then return end
    button._cdEaseUntil = nil
    if GetTime() > easeUntil or not (RC.UI and RC.UI.FadeFrame) then return end
    local cd, txt = button.cooldownFrame, button.cdTextFrame
    if cd then
        RC.UI:FadeFrame(cd, cd.fadeAnimation and cd:GetAlpha() or 0, 1, CD_EASE, "easeOutQuad")
    end
    if txt then
        RC.UI:FadeFrame(txt, txt.fadeAnimation and txt:GetAlpha() or 0, 1, CD_EASE, "easeOutQuad")
    end
end

local function ResolveCooldownDisplay(button, remaining, start, duration,
                                      buffRemaining, buffStart, buffDuration)
    EaseCooldownIn(button)
    if buffRemaining and buffRemaining > 0 then
        if button.cooldownFrame and buffStart and buffDuration then
            button.cooldownFrame:SetCooldown(buffStart, buffDuration)
            button.cooldownFrame:Show()
        end
        local c = GM:LookColor("buffColor", "text", "green")
        -- gearManager.formats.timer (nil = the plain seconds)
        local fmt = GM:TimerFormatSpec()
        if fmt then return GM:CooldownText(buffRemaining, fmt), c.r, c.g, c.b end
        return tostring(math.ceil(buffRemaining)), c.r, c.g, c.b
    end

    local text
    local fmt = GM:TimerFormatSpec()
    if fmt then
        text = GM:CooldownText(remaining, fmt)
    elseif remaining >= 60 then
        text = math.ceil(remaining / 60) .. "m"
    else
        text = tostring(math.ceil(remaining))
    end

    if button.cooldownFrame then
        button.cooldownFrame:SetCooldown(start, duration)
        button.cooldownFrame:Show()
    end

    local c = GM:LookColor("timerColor", "text", "yellow")
    return text, c.r, c.g, c.b
end

function GM:UpdateButtonCooldowns()
    if RC.Profiler then RC.Profiler:StartTiming("GearBtnCooldowns") end
    if not self.fontsRefreshed then
        self.fontsRefreshed = true
        self:RefreshAllButtonFonts()
    end

    local now = GetTime()
    local hasActiveCooldown = false

    if not self.itemStates then
        self.itemStates = {}
    end

    for slot, button in pairs(self.buttons) do
        if slot ~= 999 and slot ~= 0 and not self:GetPinnedDef(slot) and button and button:IsShown() and button.cdText then
            local itemID = GetInventoryItemID("player", slot)

            -- A swap was asked for and has not landed: the icon already
            -- shows the incoming item (GM:PredictSlotItem), and what the
            -- slot reports is still the outgoing item's cooldown, which
            -- is fading out with its icon. Leave it alone and keep the
            -- ticker alive to paint the real one.
            local pred = button._predicted
            if pred and (itemID or false) ~= pred.id and now < pred.expires then
                hasActiveCooldown = true
            elseif itemID then
                if not self.itemStates[slot] then
                    self.itemStates[slot] = {
                        lastEquipTime = 0,
                        cooldownDetectedAt = 0,
                        wasOnCooldown = false,
                        itemId = nil
                    }
                end

                local state = self.itemStates[slot]

                if state.itemId ~= itemID then
                    state.itemId = itemID
                    state.lastEquipTime = GetTime()
                    state.cooldownDetectedAt = 0
                    state.wasOnCooldown = false
                end

                -- Get cooldown: use inventory API for equipped slots, bag API for others.
                -- The bag lookup goes through RC:GetItemCooldownSafe (TSS_Base.lua),
                -- which uses C_Container.GetItemCooldown when the client has it and
                -- falls back to core's bag-scan shim when it does not.
                local start, duration
                if slot >= 1 and slot <= 19 then
                    start, duration = Readycheck.PlainCD(GetInventoryItemCooldown("player", slot))
                else
                    start, duration = RC:GetItemCooldownSafe(itemID)
                end

                if start and duration and duration > 1.5 then
                    local remaining = duration - (now - start)

                    if remaining > 0 then
                        hasActiveCooldown = true

                        local text, r, g, b
                        local elapsed = now - start

                        if not state.wasOnCooldown or state.cooldownDetectedAt == 0 then
                            state.cooldownDetectedAt = GetTime()
                            state.wasOnCooldown = true
                        end

                        if (slot == 13 or slot == 14) and RC and RC.trinketSwapSystem and RC.trinketSwapSystem.trinketStates then
                            local showBuffTimer = false
                            local slotKey = slot == 13 and "slot1" or "slot2"
                            local trinketState = RC.trinketSwapSystem.trinketStates[slotKey]

                            if trinketState and trinketState.buffExpireTime and trinketState.buffExpireTime > now then
                                showBuffTimer = true
                            end

                            if not showBuffTimer and RC.itemBuffSpellIds and RC.itemBuffSpellIds[itemID] then
                                local buffSpellId = RC.itemBuffSpellIds[itemID]
                                local buffName = GetSpellInfo(buffSpellId)
                                local aura = buffName and RC.Auras:BuffNamed(buffName)
                                if aura then
                                    showBuffTimer = true
                                    trinketState = trinketState or {}
                                    trinketState.buffExpireTime = aura.expirationTime
                                end
                            end

                            if not showBuffTimer and RC.trinketCooldowns and RC.trinketCooldowns[itemID] then
                                local expectedCD = RC.trinketCooldowns[itemID]
                                local buffDuration = RC.trinketBuffDurations and RC.trinketBuffDurations[itemID] or 20

                                if math.abs(duration - expectedCD) < 5 and elapsed < buffDuration then
                                    showBuffTimer = true
                                    trinketState = trinketState or {}
                                    trinketState.buffExpireTime = start + buffDuration
                                end
                            end

                            local buffRemaining, buffStart, buffDuration
                            if showBuffTimer then
                                buffRemaining = (trinketState and trinketState.buffExpireTime or 0) - now
                                if buffRemaining > 0 and trinketState and trinketState.buffExpireTime then
                                    -- The swirl needs a start, not an end:
                                    -- back it out of the known duration.
                                    local knownDur = (RC.GetTrinketBuffDuration and RC:GetTrinketBuffDuration(itemID)) or 20
                                    buffStart    = trinketState.buffExpireTime - knownDur
                                    buffDuration = knownDur
                                end
                            end

                            text, r, g, b = ResolveCooldownDisplay(button, remaining, start, duration,
                                                                   buffRemaining, buffStart, buffDuration)
                        else
                            local hasOnUse = RC and RC.IsTrinketOnUse and RC:IsTrinketOnUse(itemID)
                            local showBuffTimer = false
                            local buffRemaining = 0

                            if hasOnUse then
                                if RC and RC.itemBuffSpellIds and RC.itemBuffSpellIds[itemID] then
                                    local buffSpellId = RC.itemBuffSpellIds[itemID]
                                    local buffName = GetSpellInfo(buffSpellId)
                                    local aura = buffName and RC.Auras:BuffNamed(buffName)
                                    if aura then
                                        showBuffTimer = true
                                        buffRemaining = aura.expirationTime - now
                                    end
                                end

                                if not showBuffTimer and RC.trinketCooldowns and RC.trinketCooldowns[itemID] then
                                    local expectedCD = RC.trinketCooldowns[itemID]
                                    local buffDuration = RC.trinketBuffDurations and RC.trinketBuffDurations[itemID] or 20

                                    if math.abs(duration - expectedCD) < 5 and elapsed < buffDuration then
                                        showBuffTimer = true
                                        buffRemaining = buffDuration - elapsed
                                    end
                                end

                            end

                            local buffStart, buffDuration
                            if hasOnUse and showBuffTimer and buffRemaining > 0 then
                                buffDuration = RC.trinketBuffDurations and RC.trinketBuffDurations[itemID] or 20
                                buffStart    = now - (buffDuration - buffRemaining)
                            else
                                buffRemaining = 0
                            end

                            text, r, g, b = ResolveCooldownDisplay(button, remaining, start, duration,
                                                                   buffRemaining, buffStart, buffDuration)
                        end

                        if (not GM.settings or GM.settings.showCooldownTextButtons ~= false) and RC:ShouldShowOwnCooldownText() then
                            button.cdTextFrame:Show()
                            button.cdText:SetText(text)
                            button.cdText:SetTextColor(r, g, b)
                            button.cdText:SetAlpha(1)
                            button.cdText:Show()
                        else
                            button.cdText:Hide()
                            if button.cdTextFrame then button.cdTextFrame:Hide() end
                        end
                    else
                        button.cdText:Hide()
                        if button.cooldownFrame then
                            button.cooldownFrame:Hide()
                        end
                        state.wasOnCooldown = false
                        state.cooldownDetectedAt = 0
                    end
                else
                    button.cdText:Hide()
                    if button.cooldownFrame then
                        button.cooldownFrame:Hide()
                    end
                    state.wasOnCooldown = false
                    state.cooldownDetectedAt = 0
                end
            else
                button.cdText:Hide()
                if button.cooldownFrame then
                    button.cooldownFrame:Hide()
                end
            end
        end
    end

    if RC.Profiler then RC.Profiler:StopTiming("GearBtnCooldowns") end
    if hasActiveCooldown then
        if not self.buttonCooldownTimer then
            self:StartButtonCooldownUpdates()
        end
    elseif self.buttonCooldownTimer then
        self:StopButtonCooldownUpdates()
        self:DebugPrint("No active cooldowns - ticker auto-stopped")
    end
end

function GM:StartButtonCooldownUpdates()
    if self.buttonCooldownTimer then
        return
    end

    local self = self

    local cb = function()
        local success, err = pcall(function()
            self:UpdateButtonCooldowns()
        end)

        if not success then
            self:DebugPrint("Ticker ERROR: " .. tostring(err))
            -- DebugPrint alone swallows real faults unless the "gear"
            -- category happens to be on, so hand the error to the normal
            -- error handler as well.
            local handler = geterrorhandler and geterrorhandler()
            if handler then handler(err) end
        end
    end

    if RC.Profiler and RC.Profiler.TrackTicker then
        self.buttonCooldownTimer = RC.Profiler:TrackTicker("GearManager:ButtonCooldowns", 0.5, cb)
    else
        self.buttonCooldownTimer = C_Timer.NewTicker(0.5, cb)
    end

    self:DebugPrint("Cooldown ticker STARTED")
end

function GM:StopButtonCooldownUpdates()
    if self.buttonCooldownTimer then
        self.buttonCooldownTimer:Cancel()
        self.buttonCooldownTimer = nil
        self:DebugPrint("Cooldown ticker STOPPED")
    end
end

function RC._GetGearManagerFadeSettings()
    local s = RC.GearManager and RC.GearManager.settings
    if not s then return nil end
    return { enabled = s.mouseoverFade, alpha = s.mouseoverFadeAlpha or 0.15 }
end

function GM:UpdateButtonsMouseoverFade()
    if not self.buttons then return end
    if not RC.ApplyMouseoverFade then return end
    for _, button in pairs(self.buttons) do
        if button then
            RC:ApplyMouseoverFade(button, RC._GetGearManagerFadeSettings)
        end
    end
end

function GM:GetEquipButtonName(setName)
    return "WRGearEquip_" .. setName:gsub("[^%w]", "_")
end

function GM:EnsureEquipButton(setName)
    local btnName = self:GetEquipButtonName(setName)
    if _G[btnName] then return _G[btnName] end
    local btn = CreateFrame("Button", btnName, UIParent)
    btn:SetSize(1, 1)
    btn:Hide()
    btn:SetScript("OnClick", function()
        if RC and RC.GearManager then
            RC.GearManager:EquipSet(setName)
        end
    end)
    return btn
end

function GM:SetSetKeybind(setName, key)
    local set = self.sets[setName]
    if not set then return end
    local btnName = self:GetEquipButtonName(setName)
    self:EnsureEquipButton(setName)
    local oldKey = set.keybind
    if oldKey and oldKey ~= "" then
        SetBinding(oldKey)
    end
    set.keybind = key
    if not RC.db.gearSets then RC.db.gearSets = {} end
    if RC.db.gearSets[setName] then
        RC.db.gearSets[setName].keybind = key
    end
    if key and key ~= "" then
        SetBinding(key, "CLICK " .. btnName .. ":LeftButton")
    end
    SaveBindings(2)
    RC:SaveConfigurationToProfile()
    self:DebugPrint("Keybind for '" .. setName .. "': '" .. tostring(key) .. "'", "gear")
end

ReadycheckGear = {
    EquipSet = function(setName) return RC.GearManager:EquipSet(setName) end,
    ToggleSet = function(setName) return RC.GearManager:ToggleSet(setName) end,
    IsSetEquipped = function(setName) return RC.GearManager:IsSetEquipped(setName) end,
    GetSets = function() return RC.GearManager:GetSetNames() end,
    SaveCurrentGear = function(setName) return RC.GearManager:SaveCurrentGear(setName) end,
}

local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_LOGIN")
initFrame:SetScript("OnEvent", function()
    -- On-use gear swap-back -----------------------------------------------
    --
    -- When a tracked on-use item goes on, the item it replaced is
    -- recorded (persisted: RC.db.speedSwapPending[slot] = {item, prev}).
    -- When that item is used, its slot is watched until the buff ends
    -- (or straight away if it grants none) and the recorded item - or the
    -- configured target - goes back on. The record is cleared only when
    -- the slot is seen holding something else, so a failed equip can be
    -- retried, and a reload or relog mid-buff is recovered from the
    -- item's running cooldown.
    do
        RC.speedSwapItems = {
            { id = 4984,  name = "Skull of Impending Doom" },
            { id = 7189,  name = "Goblin Rocket Boots" },
            { id = 10724, name = "Gnomish Rocket Boots" },
            { id = 7391,  name = "Swift Boots" },
            { id = 4264,  name = "Barbaric Belt" },
            { id = 6972,  name = "Fire Hardened Hauberk" },
        }
        -- (2026-11-09) TBC's own rocket boots
        if RC.Flavor and RC:Flavor() == "tbc" then
            table.insert(RC.speedSwapItems, { id = 23824, name = "Rocket Boots Xtreme" })
            table.insert(RC.speedSwapItems, { id = 35581, name = "Rocket Boots Xtreme Lite" })
        end
        local REVERT_ITEMS = {}
        for _, e in ipairs(RC.speedSwapItems) do REVERT_ITEMS[e.id] = true end

        local lastKnown = {}   -- slot -> worn item id
        local watches   = {}   -- slot -> { slot, item, armT, itemSpellId, spellId, expiry, ticker, timer }
        local queued    = {}   -- slot -> true, revert deferred to combat end

        local f = CreateFrame("Frame")

        local function Enabled()
            return RC.db and RC.db.gearUseRevert ~= false
        end

        local function Pending()
            if not RC.db then return nil end
            RC.db.speedSwapPending = RC.db.speedSwapPending or {}
            return RC.db.speedSwapPending
        end

        local function AnyTrackedWorn()
            for slot = 1, 19 do
                local id = GetInventoryItemID("player", slot)
                if id and REVERT_ITEMS[id] then return true end
            end
            return false
        end

        local function UpdateCastReg()
            if Enabled() and AnyTrackedWorn() then
                f:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
            else
                f:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
            end
        end
        RC.UpdateGearUseRevertReg = UpdateCastReg

        -- Use attribution ------------------------------------------------
        -- Two items can share one on-use spell (Barbaric Belt and Fire
        -- Hardened Hauberk both cast 9174), and items sharing a spell share
        -- its cooldown, so what the player pressed is the only reliable
        -- tell. A Readycheck gear button records its slot in PostClick;
        -- these hooks cover /use, macros and action bars.
        local RESOLVE_WINDOW = 0.4
        local RESOLVE_STEP = 0.05

        local function CooldownStart(slot)
            local start, dur = Readycheck.PlainCD(GetInventoryItemCooldown("player", slot))
            if start and start > 0 and dur and dur > 1.5 then return start end
            return 0
        end

        local function HasFreshCooldown(slot, before, castT)
            local start = CooldownStart(slot)
            if start <= 0 then return false end
            if start ~= (before[slot] or 0) then return true end
            return math.abs(start - castT) < 1.5
        end

        local function NoteUseSlot(slot)
            slot = tonumber(slot)
            if not slot or slot < 1 or slot > 19 then return end
            local id = GetInventoryItemID("player", slot)
            if not id or not REVERT_ITEMS[id] then return end
            RC.lastGearUseSlot = slot
            RC.lastGearUseTime = GetTime()
        end

        local function NoteUseItem(item)
            if not item then return end
            local id = tonumber(item)
            if not id and GetItemInfoInstant then
                id = select(1, GetItemInfoInstant(item))
            end
            if not id or not REVERT_ITEMS[id] then return end
            for s = 1, 19 do
                if GetInventoryItemID("player", s) == id then
                    NoteUseSlot(s)
                    return
                end
            end
        end

        if type(_G.UseInventoryItem) == "function" then
            hooksecurefunc("UseInventoryItem", NoteUseSlot)
        end
        if type(_G.UseItemByName) == "function" then
            hooksecurefunc("UseItemByName", NoteUseItem)
        end
        if type(_G.UseAction) == "function" and GetActionInfo then
            hooksecurefunc("UseAction", function(action)
                local kind, id = GetActionInfo(action)
                if kind == "item" then NoteUseItem(id) end
            end)
        end

        local function ClickedSlot(candidates, castT)
            local slot, when = RC.lastGearUseSlot, RC.lastGearUseTime
            if not slot or not when or math.abs(castT - when) > 1 then
                return nil
            end
            for _, s in ipairs(candidates) do
                if s == slot then return s end
            end
            return nil
        end

        -- Calls onResolved(slot, why) for each slot the cast is attributed
        -- to, or for none: reverting the wrong slot strands the item the
        -- player is wearing for the pull.
        local function ResolveCastSlot(candidates, before, castT, onResolved)
            local hinted = ClickedSlot(candidates, castT)
            if hinted then
                RC.lastGearUseSlot, RC.lastGearUseTime = nil, nil
                onResolved(hinted, "clicked button")
                return
            end

            local function Attempt()
                local fresh = {}
                for _, s in ipairs(candidates) do
                    if HasFreshCooldown(s, before, castT) then fresh[#fresh + 1] = s end
                end
                if #fresh == 0 then return false end
                -- Several fresh cooldowns means a shared spell; each of
                -- those slots is a tracked item with its own target, so
                -- all of them go back.
                for _, s in ipairs(fresh) do
                    onResolved(s, #fresh == 1 and "cooldown" or "shared use spell")
                end
                return true
            end

            if Attempt() then return end
            local deadline = GetTime() + RESOLVE_WINDOW
            local function Retry()
                if Attempt() then return end
                if GetTime() >= deadline then
                    RC:DebugPrint("Swapback: no cooldown appeared on any worn item"
                        .. " casting that spell - reverting nothing", "gear")
                    return
                end
                C_Timer.After(RESOLVE_STEP, Retry)
            end
            C_Timer.After(RESOLVE_STEP, Retry)
        end

        -- Revert ---------------------------------------------------------

        local function ClearRecord(slot)
            local sp = Pending()
            if sp then sp[slot] = nil end
        end

        local function DoRevert(slot, why)
            local sp = Pending()
            local rec = sp and sp[slot]
            if not rec or not Enabled() then return end
            if InCombatLockdown() then
                queued[slot] = true
                f:RegisterEvent("PLAYER_REGEN_ENABLED")
                RC:DebugPrint("Swapback queued to combat end (slot " .. slot .. ")", "gear")
                return
            end
            local worn = GetInventoryItemID("player", slot)
            if worn ~= rec.item then
                ClearRecord(slot)
                return
            end
            local target = (RC.db.speedSwapTargets and RC.db.speedSwapTargets[rec.item]) or rec.prev
            if not target or target == 0 then
                ClearRecord(slot)
                RC:DebugPrint("Swapback skipped: nothing to restore for slot " .. slot
                    .. " (no previous item, no configured target)", "gear")
                return
            end
            -- The record stays until PLAYER_EQUIPMENT_CHANGED shows the
            -- slot holding something else, so an equip that silently fails
            -- (item not in bags) is tried again on the next use or, while
            -- the cooldown still runs, the next login.
            RC:FastEquipItem(target, slot)
            RC:DebugPrint("Swapback: slot " .. slot .. " -> item " .. target .. " (" .. why .. ")", "gear")
        end

        -- Watch ----------------------------------------------------------
        -- How long to look for a buff before concluding the item grants
        -- none: the aura lands on the same frame as the cast.
        local DISCOVERY_WINDOW = 0.3

        local function StopWatch(slot)
            local w = watches[slot]
            if not w then return end
            if w.ticker then w.ticker:Cancel() end
            if w.timer then w.timer:Cancel() end
            watches[slot] = nil
            if not next(watches) then
                RC:UnregisterUnitAuraCallback("GearUseRevert")
            end
        end

        local function FinishWatch(w, why)
            StopWatch(w.slot)
            DoRevert(w.slot, why)
        end

        local function TickWatch(w)
            local now = GetTime()
            if not w.spellId then
                -- the buff lands on the cast's frame, maybe before that
                -- frame's UNIT_AURA: read afresh for this short window
                RC.Auras:Invalidate()
                for _, a in ipairs(RC.Auras:Buffs()) do
                    local dur, expTime, sid = a.duration, a.expirationTime, a.spellId
                    local startedThen = dur > 0 and math.abs((expTime - dur) - w.armT) < 1.5
                    local sameSpell = w.itemSpellId and sid == w.itemSpellId
                    if startedThen or sameSpell then
                        w.spellId, w.expiry = sid, expTime
                        break
                    end
                end
                if w.spellId then
                    -- Found: stop polling and wake once at expiry. UNIT_AURA
                    -- still covers early removal.
                    if w.ticker then w.ticker:Cancel(); w.ticker = nil end
                    if w.expiry and w.expiry > now then
                        w.timer = C_Timer.NewTimer((w.expiry - now) + 0.05, function()
                            if watches[w.slot] == w then FinishWatch(w, "buff ended") end
                        end)
                    end
                    return
                end
                if now - w.discoverFrom >= DISCOVERY_WINDOW then
                    FinishWatch(w, "no buff found")
                end
                return
            end
            local present = RC.Auras:Buff(w.spellId) ~= nil
            if not present or (w.expiry and w.expiry > 0 and now > w.expiry + 0.3) then
                FinishWatch(w, "buff ended")
            end
        end

        local function AuraTick()
            for _, w in pairs(watches) do TickWatch(w) end
        end

        local function ArmWatch(slot, itemId, armT)
            StopWatch(slot)
            local _, itemSpellId = GetItemSpell(itemId or 0)
            local w = { slot = slot, item = itemId, armT = armT or GetTime(), discoverFrom = GetTime(), itemSpellId = itemSpellId }
            watches[slot] = w
            RC:RegisterUnitAuraCallback("GearUseRevert", 0.05, AuraTick)
            local function Pulse()
                if watches[slot] == w then TickWatch(w) end
                if watches[slot] ~= w and w.ticker then w.ticker:Cancel(); w.ticker = nil end
            end
            if RC.Profiler and RC.Profiler.TrackTicker then
                w.ticker = RC.Profiler:TrackTicker("GearUseRevert", 0.05, Pulse)
            else
                w.ticker = C_Timer.NewTicker(0.05, Pulse)
            end
            C_Timer.After(0, function() if watches[slot] == w then TickWatch(w) end end)
        end

        local function Arm(slot, why)
            local worn = GetInventoryItemID("player", slot)
            local sp = Pending()
            if sp then
                if not sp[slot] then sp[slot] = { item = worn, prev = 0 } end
                sp[slot].used = true
            end
            ArmWatch(slot, worn, GetTime())
            RC:DebugPrint("Swapback: watching slot " .. slot .. " after use of item "
                .. tostring(worn) .. (why and (" (" .. why .. ")") or ""), "gear")
        end

        -- A worn tracked item is a candidate if it casts this spell, or if
        -- its spell is not yet known (item cache cold right after a
        -- reload); attribution then falls to the click or the cooldown.
        local function CastCandidates(spellId)
            local out = {}
            for s = 1, 19 do
                local worn = GetInventoryItemID("player", s)
                if worn and REVERT_ITEMS[worn] then
                    local _, isid = GetItemSpell(worn)
                    if not isid or isid == spellId then out[#out + 1] = s end
                end
            end
            return out
        end

        -- Login / zone: rebuild what is worn, drop records for slots that
        -- no longer hold their item, and re-arm any item whose cooldown is
        -- running - it was used before the reload and still needs its
        -- swap-back.
        local function Recover()
            for slot = 1, 19 do
                lastKnown[slot] = GetInventoryItemID("player", slot)
            end
            local sp = Pending()
            if not sp then return end
            for slot, rec in pairs(sp) do
                local worn = lastKnown[slot]
                if not rec or not rec.item or worn ~= rec.item then
                    sp[slot] = nil
                elseif rec.used and not watches[slot] and Enabled() then
                    local start = CooldownStart(slot)
                    if start > 0 then
                        ArmWatch(slot, rec.item, start)
                        RC:DebugPrint("Swapback: slot " .. slot .. " item " .. rec.item
                            .. " is on cooldown after login - resuming watch", "gear")
                    end
                end
            end
            for slot = 1, 19 do
                local worn = lastKnown[slot]
                if worn and REVERT_ITEMS[worn] and not sp[slot] then
                    sp[slot] = { item = worn, prev = 0 }
                end
            end
            UpdateCastReg()
        end

        f:SetScript("OnEvent", function(_, event, a1, a2, a3)
            if event == "PLAYER_EQUIPMENT_CHANGED" then
                local slot = a1
                local old = lastKnown[slot]
                local new = GetInventoryItemID("player", slot)
                lastKnown[slot] = new
                local sp = Pending()
                if sp and new ~= old then
                    local rec = sp[slot]
                    if new and REVERT_ITEMS[new] then
                        if rec and rec.item == new then
                            -- already recorded (login-time echo); keep it
                        elseif rec and old and REVERT_ITEMS[old] then
                            rec.item, rec.used = new, nil   -- tracked item swapped for another; keep prev
                        elseif Enabled() then
                            sp[slot] = { item = new, prev = old or 0 }
                        end
                    elseif rec then
                        sp[slot] = nil               -- slot holds something else: done
                        StopWatch(slot)
                    end
                end
                UpdateCastReg()

            elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
                if not Enabled() then return end
                local spellId = a3
                local castT = GetTime()
                local candidates = CastCandidates(spellId)
                if #candidates == 0 then return end
                local only = candidates[1]
                local _, onlySpell = GetItemSpell(GetInventoryItemID("player", only) or 0)
                if #candidates == 1 and onlySpell == spellId then
                    Arm(only, "only worn item with that use")
                else
                    local before = {}
                    for _, s in ipairs(candidates) do before[s] = CooldownStart(s) end
                    ResolveCastSlot(candidates, before, castT, Arm)
                end

            elseif event == "PLAYER_REGEN_ENABLED" then
                f:UnregisterEvent("PLAYER_REGEN_ENABLED")
                local q = queued
                queued = {}
                for slot in pairs(q) do DoRevert(slot, "post-combat") end

            elseif event == "PLAYER_ENTERING_WORLD" then
                Recover()
            end
        end)
        f:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
        f:RegisterEvent("PLAYER_ENTERING_WORLD")
    end

    C_Timer.After(3, function()
        GM:Initialize()
    end)
end)
