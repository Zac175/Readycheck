------------------------------------------------------------------------
-- Readycheck - Trinket On-Use Scanning, OnEnable Startup Sequence, Slash Commands
-- Owns trinket-slot scanning (ScanEquippedTrinkets/CheckTrinketHasOnUse),
-- the staggered post-login startup sequence in RC:OnEnable, and the
-- entire /rc command table (RC_CMDS + the CMD() registration helper).
-- Despite the filename this is not the cooldown/aura scanner - that
-- logic lives in Core_Events.lua.
------------------------------------------------------------------------
local CP = Readycheck.Compat
local GetAddOnMetadata = GetAddOnMetadata or CP.GetAddOnMetadata
local GetItemInfo = GetItemInfo or CP.GetItemInfo

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local GetTime, UnitName, UnitExists = GetTime, UnitName, UnitExists
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end

-- Legacy per-ability potion keys stripped from raid profiles by the
-- once-per-login cleanup in RC:OnEnable (bosses and trash share this list).
local OLD_POTION_KEYS = {
    "mightyRagePotion", "stoneshieldPotion", "invulnerabilityPotion",
    "limitedInvulnerabilityPotion", "freeActionPotion", "swiftnessPotion",
    "fireProtectionPotion", "frostProtectionPotion", "natureProtectionPotion",
    "shadowProtectionPotion", "arcaneProtectionPotion", "greatRagePotion",
    "greaterArcaneProtectionPotion", "greaterFireProtectionPotion",
    "greaterFrostProtectionPotion", "greaterNatureProtectionPotion",
    "greaterShadowProtectionPotion"
}

function RC:ScanEquippedTrinkets()
    -- Slot 1 = inventory 13, slot 2 = inventory 14; identical logic per slot.
    for slotNum = 1, 2 do
        local invSlot = 12 + slotNum
        local slotData = self.trinketData["slot" .. slotNum]
        local abilityKey = "trinket" .. slotNum
        local defaultName = "Trinket Slot " .. slotNum
        local link = GetInventoryItemLink("player", invSlot)
        if link then
            local itemId = tonumber(link:match("item:(%d+)"))

            if itemId then
                GetItemInfo(itemId)
            end

            local itemName = GetItemInfo(link)

            slotData.itemId = itemId
            slotData.name = itemName or defaultName
            slotData.hasOnUse = self:CheckTrinketHasOnUse(link)

            self:DebugPrint("Trinket " .. slotNum .. ": " .. (itemName or "Unknown") .. " (ID: " .. (itemId or "none") ..
                      ", On-Use: " .. (slotData.hasOnUse and "YES" or "NO") .. ")", "trinket")

            if self.abilityData and self.abilityData[abilityKey] then
                self.abilityData[abilityKey].name = itemName or defaultName
                local _, _, _, _, _, _, _, _, _, iconTexture = GetItemInfo(link)
                if iconTexture then
                    self.abilityData[abilityKey].icon = iconTexture
                end
            end
        else
            slotData.itemId = nil
            slotData.name = "Empty Trinket Slot"
            slotData.hasOnUse = false

            self:DebugPrint("Trinket " .. slotNum .. ": Empty", "trinket")
        end
    end

    self:DebugPrint("Trinket scan complete - Slot 1: " .. (self.trinketData.slot1.hasOnUse and "USABLE" or "passive") ..
              ", Slot 2: " .. (self.trinketData.slot2.hasOnUse and "USABLE" or "passive"), "trinket")
end

function RC:CheckTrinketHasOnUse(itemLink)
    if not itemLink then
        self:DebugPrint("CheckTrinketHasOnUse: itemLink is nil", "trinket")
        return false
    end

    local itemId = tonumber(itemLink:match("item:(%d+)"))
    if not itemId then
        self:DebugPrint("CheckTrinketHasOnUse: could not extract itemId from " .. itemLink, "trinket")
        return false
    end

    if self.IsTrinketOnUse and self:IsTrinketOnUse(itemId) then
        self:DebugPrint("CheckTrinketHasOnUse: " .. itemId .. " is on-use (hardcoded or auto-detected)", "trinket")
        return true
    end

    if self.classicDpsTrinkets and self.classicDpsTrinkets[itemId] then
        self:DebugPrint("CheckTrinketHasOnUse: " .. itemId .. " found in classicDpsTrinkets", "trinket")
        return true
    end

    -- Same 7 item IDs are hardcoded again in IsTrinketSlotOnUse below;
    -- that function also additionally checks RC.onUseTrinkets, which this
    -- one does not - keep both lists and both check sets in sync if
    -- either is updated.
    local onUseTrinkets = {
        [21670] = true,
        [20130] = true,
        [19849] = true,
        [21180] = true,
        [17774] = true,
        [22954] = true,
        [23041] = true,
    }

    if onUseTrinkets[itemId] then
        self:DebugPrint("CheckTrinketHasOnUse: " .. itemId .. " found in fallback list", "trinket")
        return true
    end

    self:DebugPrint("CheckTrinketHasOnUse: " .. itemId .. " NOT found in any on-use list", "trinket")
    return false
end

function RC:IsTrinketSlotOnUse(slotNumber)
    local slotId = (slotNumber == 1) and 13 or 14
    local itemLink = GetInventoryItemLink("player", slotId)
    if not itemLink then return false end

    local itemId = tonumber(itemLink:match("item:(%d+)"))
    if not itemId then return false end

    -- Checks RC.onUseTrinkets in addition to classicDpsTrinkets, unlike
    -- CheckTrinketHasOnUse above - the two functions can disagree for an
    -- item that's only in that list.
    if self.classicDpsTrinkets and self.classicDpsTrinkets[itemId] then return true end
    if RC.onUseTrinkets and RC.onUseTrinkets[itemId] then return true end

    local onUseTrinkets = {
        [21670] = true, [20130] = true, [19849] = true,
        [21180] = true, [17774] = true, [22954] = true, [23041] = true,
    }
    return onUseTrinkets[itemId] or false
end

-- Startup work below is staggered across several C_Timer.After delays
-- (1s/2s/3s/5s/8s) rather than run inline, so login doesn't do it all in
-- one frame. Any config save triggered by that startup work in the first
-- 8s is deferred to _startupDirty and flushed once as a single save
-- instead of one write per system that finished initializing.
function RC:OnEnable()
    RC._startupPhase = true
    RC._startupDirty = false
    C_Timer.After(8, function()
        RC._startupPhase = false
        if RC._startupDirty then
            RC._startupDirty = false
            if RC.SaveConfigurationToProfile then
                RC:SaveConfigurationToProfile()
                RC:DebugPrint("Startup suppression cleared - consolidated save complete", "config")
            end
        else
            RC:DebugPrint("Startup suppression cleared - no dirty saves pending", "config")
        end
    end)
    -- SETUP2: the CVars of features that are off go back (nothing at all
    -- unless the CVar record holds something)
    if RC.CVar and RC.CVar.AtLogin then RC.CVar.AtLogin() end

    self.db.enabled = true
    self:DebugPrint("FORCED ENABLED in OnEnable - db.enabled = " .. tostring(self.db.enabled), "config")

    if self.isWarrior then
        self:Print(self:BrandColorCode() .. "v" .. self.version .. RCL["|r loaded! Use |cFF00FF00/rc|r to open config"])
    else
        self:Print(self:BrandColorCode() .. "v" .. self.version .. RCL["|r Utility Mode loaded! Use |cFF00FF00/rc|r to open config"])
    end

    do
        local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
        if isLoaded then
            local missing = {}
            local layers = {
                { "Readycheck_Reminders",   "Reminders (the reminder popup, ML predictions, TTK bar, raid route)" },
                { "Readycheck_Consumables", "Consumables (consumables, potions, weapon and trinket bars, raid checker)" },
                { "Readycheck_Features",    "Features (boss notes, nameplate auras, polarity mode, smart macros)" },
                { "Readycheck_Gear",        "Gear (gear manager, trinket swapping, hotswap, repair reminder)" },
                { "Readycheck_WorldTools",  "World Tools (buff drop timers, auto turn-ins, summon accept)" },
            }
            for _, l in ipairs(layers) do
                if not isLoaded(l[1]) then missing[#missing + 1] = l[2] end
            end
            -- A companion this session turned on for the first time may not
            -- be loadable until the client restarts. Say so plainly rather
            -- than listing it as "Disabled", which would read as the user's
            -- own doing and send them to the AddOns list for nothing.
            if RC._companionsNeedReload then
                self:Print(self:BrandColorCode() .. RCL["New Readycheck modules were switched on for you."] .. "|r"
                    .. RCL[" Type /reload once to finish loading them."])
                RC._companionsNeedReload = nil
            elseif #missing > 0 then
                self:Print(RCL["|cFFFF4444Disabled:|r "] .. table.concat(missing, " | ")
                    .. RCL[" - enable in the AddOns list to restore."])
            end
        end
    end

    if not self:InitializeCharacterProfile() then
        self:Print(RCL["ERROR: Failed to initialize character profile!"])
        return
    end

    local charKey = self:GetCharacterKey()
    if ReadycheckDB.characters and ReadycheckDB.characters[charKey] then
        self:DebugPrint("Configuration linked to character profile: " .. charKey, "config")
    end

    C_Timer.After(5, function()
        if self.CheckAndApplyRaidProfile then
            self:CheckAndApplyRaidProfile()
        end
    end)

    if not self.triggerSystem then
        self.triggerSystem = {
            currentTarget = {
                name = nil,
                guid = nil,
                currentHP = 0,
                maxHP = 0,
                currentHPPercent = 100,
                estimatedTimeToKill = 999,
                healthHistory = {}
            }
        }
    end

    if not self.combatState then
        self.combatState = {
            inCombat = false,
            combatStartTime = 0,
            usedAbilities = {},
            lastCheck = 0
        }
    end

    C_Timer.After(1, function()
        if self.ScanCurrentCooldowns then
            self:ScanCurrentCooldowns()
        end

        if self.RefreshCustomItemInfo then
            self:RefreshCustomItemInfo()
        end

        -- One-time-per-login cleanup of renamed potion ability keys
        -- (OLD_POTION_KEYS above); bosses and trash use the same loop.
        if self.db and self.db.raidProfiles then
            for raidName, raidStructure in pairs(self.db.raidProfiles) do
                if raidStructure.profiles then
                    for profileName, profileData in pairs(raidStructure.profiles) do
                        if profileData.bosses then
                            for bossName, bossConfig in pairs(profileData.bosses) do
                                if bossConfig.abilities then
                                    if bossConfig.abilities.potion and (not bossConfig.abilities.potion.potionType or bossConfig.abilities.potion.potionType == "") then
                                        bossConfig.abilities.potion.potionType = "mightyRagePotion"
                                    end

                                    for _, oldKey in ipairs(OLD_POTION_KEYS) do
                                        if bossConfig.abilities[oldKey] then
                                            bossConfig.abilities[oldKey] = nil
                                        end
                                    end
                                end
                            end
                        end

                        if profileData.trash then
                            for trashName, trashConfig in pairs(profileData.trash) do
                                if trashConfig.abilities then
                                    if trashConfig.abilities.potion and (not trashConfig.abilities.potion.potionType or trashConfig.abilities.potion.potionType == "") then
                                        trashConfig.abilities.potion.potionType = "mightyRagePotion"
                                    end

                                    for _, oldKey in ipairs(OLD_POTION_KEYS) do
                                        if trashConfig.abilities[oldKey] then
                                            trashConfig.abilities[oldKey] = nil
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end

        if self.CacheUtilityItemInfo then
            self:CacheUtilityItemInfo()
        end
    end)

    C_Timer.After(2, function()
        self:CheckItemRackAvailability()
    end)

    C_Timer.After(3, function()
        if self.UIMover and self.UIMover.Initialize then
            self.UIMover:Initialize()
        end

        if EditModeManagerFrame and EditModeManagerFrame.HookScript then
            EditModeManagerFrame:HookScript("OnShow", function()
                if RC.UIMover and RC.UIMover.EnterMoveMode then
                    RC._editModeDroveMover = true
                    RC.UIMover:EnterMoveMode({ noPanel = true })
                end
            end)
            EditModeManagerFrame:HookScript("OnHide", function()
                if RC._editModeDroveMover and RC.UIMover and RC.UIMover.ExitMoveMode then
                    RC._editModeDroveMover = nil
                    RC.UIMover:ExitMoveMode()
                end
            end)
        else
            RC:DebugPrint("Edit Mode bridge: EditModeManagerFrame not found - "
                .. "UIMover will not auto-unlock with Edit Mode", "system")
        end
    end)

    -- Setup wizard should only ever auto-open once per account, not once
    -- per character - checks every character profile's completion state
    -- (not just the current one) before deciding to show it.
    C_Timer.After(2, function()
        if not ReadycheckDB then return end
        if ReadycheckDB.setupWizardAutoShown then return end

        if ReadycheckDB.characters then
            for _, profile in pairs(ReadycheckDB.characters) do
                if profile.setupWizard and profile.setupWizard.completed then
                    ReadycheckDB.setupWizardAutoShown = true
                    return
                end
            end
        end

        if self.db and self.db.setupWizard and
           (self.db.setupWizard.completed or (self.db.setupWizard.lastStep and self.db.setupWizard.lastStep > 1)) then
            ReadycheckDB.setupWizardAutoShown = true
            return
        end

        ReadycheckDB.setupWizardAutoShown = true
        self:LoadExtras()
        if self.SetupWizard then
            self.SetupWizard:Open()
        end
    end)

    C_Timer.After(3, function()
        if not (ReadycheckDB and ReadycheckDB.account) then return end
        local meta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
        local cur = meta and meta("Readycheck", "Version") or nil
        if cur and ReadycheckDB.account.lastSeenVersion ~= cur then
            RC:LoadExtras()
        end
    end)
end

function RC:LoadExtras()
    local L = (C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn
    if L then pcall(L, "Readycheck_Extras") end
    return (self.SetupWizard ~= nil) or (self.Changelog ~= nil)
end

-- FIRST-RUN TOUR GATE. Called every time the settings window is opened
-- (Sidebar_Window). Only a fresh install carries ReadycheckDB.tutorial
-- (stamped in Core_Runtime), so for everyone else this returns at once.
-- A fresh install gets the tour on its first TUTORIAL_AUTO_OPENS opens,
-- unless it was finished or skipped; an open while the setup wizard is
-- still up is not counted, so the two never stack.
local TUTORIAL_AUTO_OPENS = 2
function RC:MaybeStartTutorial()
    local t = type(ReadycheckDB) == "table" and ReadycheckDB.tutorial or nil
    if type(t) ~= "table" or not t.fresh or t.done then return end
    if self.Tutorial and self.Tutorial.active then return end
    local wiz = _G.WRSetupWizardFrame
    if wiz and wiz:IsShown() then return end
    t.opens = (tonumber(t.opens) or 0) + 1
    if t.opens > TUTORIAL_AUTO_OPENS then return end
    self:LoadExtras()
    if not self.Tutorial then return end
    -- after the window's pop-in, so the ring fits the settled frame
    C_Timer.After(0.4, function()
        local win = RC.sidebarConfigFrame
        if type(ReadycheckDB.tutorial) ~= "table" or ReadycheckDB.tutorial.done then return end
        if RC.Tutorial and win and win:IsShown() and not RC.Tutorial.active then
            RC.Tutorial:Start("auto")
        end
    end)
end

-- /rc tutorial replays the tour for anyone; the rest is for testing it.
function RC:TutorialCommand(sub)
    self:LoadExtras()
    local T = self.Tutorial
    if not T then
        self:Print(RCL["The tour needs the Readycheck_Extras addon. Enable it in your AddOns list and /reload."])
        return
    end
    sub = (sub or ""):lower()
    if sub == "reset" then
        T:Reset()
        self:Print(RCL["Tour reset - this account now counts as a fresh install. Open /rc to see it."])
    elseif sub == "done" or sub == "off" then
        T:MarkDone()
        self:Print(RCL["Tour marked as done - it will not open by itself again."])
    elseif sub == "status" then
        self:Print(T:Status())
    else
        if not (self.sidebarConfigFrame and self.sidebarConfigFrame:IsShown()) then
            self:CreateSidebarConfigWindow()
        end
        C_Timer.After(0.4, function()
            if RC.Tutorial and not RC.Tutorial:Start("manual") then
                RC:Print(RCL["Open the settings window (/rc) and try again."])
            end
        end)
    end
end

-- /rc setup opens the first-run wizard again; a finished one starts over
-- from its first page. Completion is left alone so it never auto-opens.
function RC:SetupWizardCommand()
    self:LoadExtras()
    local W = self.SetupWizard
    if not W then
        self:Print(RCL["The setup wizard needs the Readycheck_Extras addon. Enable it in your AddOns list and /reload."])
        return
    end
    local shown = W.frame and W.frame:IsShown()
    if not shown and self.db and self.db.setupWizard and self.db.setupWizard.completed then
        self.db.setupWizard.lastStep = 1
        W.currentStep = 1
    end
    W:Open()
end

SLASH_READYCHECK1 = "/rc"
SLASH_READYCHECK2 = "/wr"
SLASH_READYCHECK3 = "/warriorreminder"

SLASH_READYCHECKCC1 = "/cc"
SlashCmdList["READYCHECKCC"] = function()
    if RC.ToggleConsumablesChecker then
        RC:ToggleConsumablesChecker()
    end
end

SLASH_READYCHECKWB1 = "/wb"
SlashCmdList["READYCHECKWB"] = function(msg)
    if msg and msg:match("%S") and RC.WorldBuffs and RC.WorldBuffs.HandleDiagCommand then
        RC.WorldBuffs:HandleDiagCommand(msg)
        return
    end
    if RC.ToggleWorldBuffMini then
        RC:ToggleWorldBuffMini()
    end
end

-- Registers one handler under one or more exact-match subcommand names
-- (e.g. CMD(fn, "wb", "worldbuffs", "worldbuff") - all three route to fn).
local RC_CMDS = {}
local function CMD(handler, ...)
    for i = 1, select("#", ...) do
        RC_CMDS[(select(i, ...))] = handler
    end
end

CMD(function(cmd, args, msg, isWarrior)
        if RC.AuditSettingsRegistry then
            RC:AuditSettingsRegistry(true)
        else
            RC:Print(RCL["Settings registry not loaded."])
        end
        return
end, "settingsaudit")

CMD(function(cmd, args, msg, isWarrior)
        if not (RC.MeshSync and RC.MeshSync.PrintStatus) then
            RC:Print(RCL["Mesh system not loaded."])
            return
        end
        local sub = (type(args) == "table" and args[2] and args[2]:lower()) or ""
        if sub == "undo" and RC.MeshSync.UndoSendChange then
            local n = RC.MeshSync:UndoSendChange()
            if n then
                RC:Print(RCL["Mesh: Restored previous Send selection ("] .. n .. RCL[" categories)."])
                if RC.SidebarState and RC.SidebarState.currentPanel == "mesh_sync"
                        and RC.sidebarConfigFrame and RC.ShowSidebarMeshSync then
                    RC:ShowSidebarMeshSync(RC.sidebarConfigFrame)
                end
            else
                RC:Print(RCL["Mesh: Nothing to undo."])
            end
            return
        end
        RC.MeshSync:PrintStatus()
        return
end, "mesh")

CMD(function(cmd, args, msg, isWarrior)
        local rp = RC.db and RC.db.raidProfiles
        if not rp then RC:Print(RCL["No raidProfiles store."]); return end
        RC:Print(RCL["=== raidprofdump ==="])
        for raidName, structure in pairs(rp) do
            if type(structure) == "table" then
                RC:Print("  " .. raidName .. RCL["  (active: "]
                    .. tostring(structure.activeProfile) .. ")")
                if type(structure.profiles) == "table" then
                    for pName, pd in pairs(structure.profiles) do
                        local n = 0
                        if type(pd) == "table" and type(pd.bosses) == "table" then
                            for _ in pairs(pd.bosses) do n = n + 1 end
                        end
                        RC:Print("    - " .. pName .. ": " .. n .. RCL[" bosses configured"]
                            .. ((pd and pd.enabled) and ", enabled" or ""))
                    end
                end
            end
        end
        return
end, "raidprofdump")

CMD(function(cmd, args, msg, isWarrior)
        local oldProf = table.concat(args, " ", 2)
        if not oldProf or oldProf == "" then
            RC:Print(RCL["Usage: /rc notesadopt <old profile name>  (copies that profile's notes into each raid's active profile)"])
            return
        end
        local db = RC.db and RC.db.bossNotes
        if not db then RC:Print(RCL["No bossNotes store."]); return end
        local shortToLong = { mc = "Molten Core", bwl = "Blackwing Lair",
            aq40 = "Temple of Ahn'Qiraj", naxx = "Naxxramas",
            zg = "Zul'Gurub", onyxia = "Onyxia's Lair",
            aq20 = "Ruins of Ahn'Qiraj" }
        local function activeFor(rl)
            local rp = RC.db.raidProfiles and RC.db.raidProfiles[rl]
            return rp and rp.activeProfile
        end
        local adopted = 0
        local moves = {}
        for k, v in pairs(db.notes) do
            if type(k) == "string" and v and v ~= "" then
                local mob, rl, prof = k:match("^(.-)|(.-)|(.-)$")
                if mob and prof == oldProf then
                    local act = activeFor(rl)
                    if act and act ~= oldProf then
                        local nk = mob .. "|" .. rl .. "|" .. act
                        if not db.notes[nk] or db.notes[nk] == "" then
                            moves[nk] = v
                        end
                    end
                end
            end
        end
        for nk, v in pairs(moves) do db.notes[nk] = v; adopted = adopted + 1 end
        for short, rl in pairs(shortToLong) do
            local act = activeFor(rl)
            if act and act ~= oldProf then
                local bOld = db.trashNotesByRaid[short .. "|" .. oldProf]
                if bOld and bOld ~= "" then
                    local nk = short .. "|" .. act
                    if not db.trashNotesByRaid[nk] or db.trashNotesByRaid[nk] == "" then
                        db.trashNotesByRaid[nk] = bOld; adopted = adopted + 1
                    end
                end
                local packs = db.trashNotesByPack[short]
                if type(packs) == "table" then
                    local pm = {}
                    for pk, v in pairs(packs) do
                        local base, prof = pk:match("^(.-)|(.-)$")
                        if base and prof == oldProf and v and v ~= "" then
                            local nk = base .. "|" .. act
                            if not packs[nk] or packs[nk] == "" then pm[nk] = v end
                        end
                    end
                    for nk, v in pairs(pm) do packs[nk] = v; adopted = adopted + 1 end
                end
                local oldList = db.trashNotesList and db.trashNotesList[short .. "|" .. oldProf]
                if type(oldList) == "table" and #oldList > 0 then
                    local lk = short .. "|" .. act
                    local cur = db.trashNotesList[lk]
                    if type(cur) ~= "table" or #cur == 0 then
                        local copy = {}
                        for i, note in ipairs(oldList) do
                            local mobs = {}
                            for mi, m in ipairs(note.mobs or {}) do mobs[mi] = m end
                            copy[i] = { text = note.text, mobs = mobs,
                                kills = note.kills, dur = note.dur,
                                trigger = note.trigger }
                        end
                        db.trashNotesList[lk] = copy
                        if type(db.trashNotesListMig) == "table" then
                            db.trashNotesListMig[lk] = true
                        end
                        adopted = adopted + 1
                    end
                end
                for _, tbl in ipairs({ db.trashNoteKills, db.trashNoteDur, db.bossNoteAdded }) do
                    if type(tbl) == "table" then
                        local tm = {}
                        for k, v in pairs(tbl) do
                            local s2, mid, prof = k:match("^(.-)|(.-)|(.-)$")
                            if s2 == short and prof == oldProf then
                                local nk = s2 .. "|" .. mid .. "|" .. act
                                if tbl[nk] == nil then tm[nk] = v end
                            end
                        end
                        for nk, v in pairs(tm) do tbl[nk] = v; adopted = adopted + 1 end
                    end
                end
            end
        end
        if adopted > 0 then
            RC:SaveConfigurationToProfile()
            RC:Print(RCL["Adopted "] .. adopted .. RCL[" note keys from '"] .. oldProf
                .. RCL["' into each raid's active profile. Open the notes page to see them."])
        else
            RC:Print(RCL["Nothing to adopt from '"] .. oldProf
                .. RCL["' - no notes under that name, or the active profiles already have their own."])
        end
        return
end, "notesadopt")

CMD(function(cmd, args, msg, isWarrior)
        local b = RC.RaidRoute and RC.RaidRoute.BUILD or "PRE-STAMP (stale file!)"
        RC:Print(RCL["RaidRoute build: "] .. b)
        return
end, "routever")

CMD(function(cmd, args, msg, isWarrior)
        local RR = RC.RaidRoute
        if not RR then RC:Print(RCL["Route not loaded."]) return end
        RR._dbgOverlay = not RR._dbgOverlay
        if RR._dbgOverlay then
            if not RR._dbgTicker then
                local tick = function() if RR.RefreshTracker then RR:RefreshTracker() end end
                if RC.Profiler and RC.Profiler.TrackTicker then
                    RR._dbgTicker = RC.Profiler:TrackTicker("Route:DbgOverlay", 0.5, tick)
                else
                    RR._dbgTicker = C_Timer.NewTicker(0.5, tick)
                end
            end
            RC:Print(RCL["Route debug overlay: ON - the engine's state renders under the tracker. Screenshot that."])
        else
            if RR._dbgTicker then RR._dbgTicker:Cancel() RR._dbgTicker = nil end
            if RR.RefreshTracker then RR:RefreshTracker() end
            RC:Print(RCL["Route debug overlay: OFF"])
        end
        return
end, "routedebug")

CMD(function(cmd, args, msg, isWarrior)
        local n = tonumber(args[2])
        if not n then
            local cur = (RC.db and RC.db.consumablesHelper and RC.db.consumablesHelper.consumableTTSVolume) or 100
            RC:Print(RCL["TTS volume is "] .. cur .. RCL[". Usage: /rc ttsvol 0-100"])
            return
        end
        if n < 0 then n = 0 elseif n > 100 then n = 100 end
        RC.db.consumablesHelper = RC.db.consumablesHelper or {}
        RC.db.consumablesHelper.consumableTTSVolume = n
        if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
        RC:Print(RCL["TTS volume set to "] .. n .. RCL[" (affects the fallback game voice only - Media/Voice files always play at full sound-engine volume)."])
        -- Preview, not an alert: the user asked to hear this volume, so it
        -- plays even with the master TTS toggle off, like /rc ttstest.
        if RC.SpeakTTSPreview then RC:SpeakTTSPreview(RCL["Volume "] .. n, true) end
        return
end, "ttsvol")

CMD(function(cmd, args, msg, isWarrior)
        local WB = RC.WorldBuffs
        if not (WB and WB.BuildAuraSnapshot) then
            RC:Print(RCL["wbself: WorldBuffSync not loaded."])
            return
        end
        local booned, buffs, frozen = WB:BuildAuraSnapshot()
        RC:Print(RCL["My parsed world-buff state (booned="] .. tostring(booned) .. "):")
        local keys = {}
        for k in pairs(buffs or {}) do keys[#keys + 1] = k end
        table.sort(keys)
        if #keys == 0 then
            RC:Print(RCL["  (none parsed)"])
        end
        for _, k in ipairs(keys) do
            RC:Print(string.format("  %-12s %dm%s", k,
                math.floor((buffs[k] or 0) / 60),
                frozen and frozen[k] and RCL[" (stored)"] or ""))
        end
        return
end, "wbself")

CMD(function(cmd, args, msg, isWarrior)
        if RC.MeshSync and RC.MeshSync.DebugHashBreakdown then
            RC.MeshSync:DebugHashBreakdown()
        else
            RC:Print(RCL["meshhash: mesh not loaded."])
        end
        return
end, "meshhash")

CMD(function(cmd, args, msg, isWarrior)
        if RC.RunTTSLoop then RC:RunTTSLoop() end
        return
end, "ttsloop")

CMD(function(cmd, args, msg, isWarrior)
        if RC.RunTTSMatrixTest then RC:RunTTSMatrixTest() end
        return
end, "ttstest")

CMD(function(cmd, args, msg, isWarrior)
        RC._ttsTrace = not RC._ttsTrace
        RC:Print(RCL["TTS trace: "] .. (RC._ttsTrace and "ON - every spoken line will print its source module." or "OFF"))
        if RC._ttsTrace then
            local vs = (RC.GetTTSVoices and RC:GetTTSVoices()) or {}
            RC:Print(RCL["TTS env: "] .. #vs .. RCL[" voice(s) installed, selected id="]
                .. tostring(RC.GetCurrentTTSVoiceId and RC:GetCurrentTTSVoiceId() or "?"))
        end
        return
end, "ttstrace")

CMD(function(cmd, args, msg, isWarrior)
        local db = RC.db and RC.db.bossNotes
        if not db then RC:Print(RCL["No bossNotes store."]); return end
        RC:Print(RCL["=== notesdump: db.notes ==="])
        local keys = {}
        for k, v in pairs(db.notes or {}) do
            if type(k) == "string" and v and v ~= "" then keys[#keys + 1] = k end
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local txt = tostring(db.notes[k]):gsub("\n", " ")
            if #txt > 28 then txt = txt:sub(1, 28) .. "..." end
            RC:Print("  " .. k .. "  ->  " .. txt)
        end
        RC:Print("  (" .. #keys .. RCL[" boss note keys)"])
        local n1, n2, n3 = 0, 0, 0
        for _ in pairs(db.trashNotesByRaid or {}) do n1 = n1 + 1 end
        for _, packs in pairs(db.trashNotesByPack or {}) do
            if type(packs) == "table" then for _ in pairs(packs) do n2 = n2 + 1 end end
        end
        for lk, lst in pairs(db.trashNotesList or {}) do
            if type(lst) == "table" then
                RC:Print(RCL["  trashList "] .. lk .. ": " .. #lst .. RCL[" notes"])
                n3 = n3 + 1
            end
        end
        RC:Print(RCL["  blanket keys: "] .. n1 .. RCL[", pack keys: "] .. n2
            .. RCL[", list keys: "] .. n3)
        local actParts = {}
        for _, rl in ipairs({ "Naxxramas", "Temple of Ahn'Qiraj", "Blackwing Lair",
                "Molten Core", "Zul'Gurub", "Onyxia's Lair", "Ruins of Ahn'Qiraj" }) do
            local rp = RC.db.raidProfiles and RC.db.raidProfiles[rl]
            if rp and rp.activeProfile then
                actParts[#actParts + 1] = rl .. "=" .. rp.activeProfile
            end
        end
        if #actParts > 0 then
            RC:Print("  ACTIVE PROFILES: " .. table.concat(actParts, ", "))
        end
        RC:Print(RCL["  flags: migrated="] .. tostring(db.profileIsolationMigrated)
            .. RCL[" repaired2="] .. tostring(db.profileIsolationRepaired2)
            .. RCL[" sprayUndone="] .. tostring(db.bossNotesSprayUndone))
        return
end, "notesdump")

CMD(function(cmd, args, msg, isWarrior)
        if RC.DebugPageSizes then RC:DebugPageSizes()
        else RC:Print(RCL["Enable the Readycheck_Debug addon for /rc pagesizes."]) end
        return
end, "pagesizes")

CMD(function(cmd, args, msg, isWarrior)
        if RC.DebugCountUpdaters then RC:DebugCountUpdaters()
        else RC:Print(RCL["Enable the Readycheck_Debug addon for /rc updaters."]) end
        return
end, "updaters")

CMD(function(cmd, args, msg, isWarrior)
        if RC.DebugToggleUIPerf then RC:DebugToggleUIPerf()
        else RC:Print(RCL["Enable the Readycheck_Debug addon for /rc uiperf."]) end
        return
end, "uiperf")

CMD(function(cmd, args, msg, isWarrior)
        if RC.DebugBuildCheck then RC:DebugBuildCheck()
        else RC:Print(RCL["Enable the Readycheck_Debug addon for /rc buildcheck."]) end
        return
end, "buildcheck")

CMD(function(cmd, args, msg, isWarrior)
        if RC.OpenConfig then RC:OpenConfig() end
        C_Timer.After(0.05, function()
            if RC.ShowSidebarCommands and RC.sidebarConfigFrame then
                RC:ShowSidebarCommands(RC.sidebarConfigFrame)
            end
        end)

end, "help")

-- /rc search <words>: the settings window with the words typed into its
-- search box and the results dropped under it (Sidebar_SearchBox);
-- bare, just the cursor in the box.
CMD(function(cmd, args, msg, isWarrior)
        local words = msg and msg:match("^%s*%S+%s*(.-)%s*$") or ""
        local SB = RC.SidebarSearchBox
        if SB and SB.Open then
            SB.Open(words)
        elseif RC.OpenConfig then
            RC:OpenConfig()
        end
end, "search", "find")

CMD(function(cmd, args, msg, isWarrior)
        if RC.UIMover then
            RC.UIMover:EnterMoveMode()
        end

end, "moveui", "unlock", "move")

CMD(function(cmd, args, msg, isWarrior)
        if RC.UIMover then
            RC.UIMover:ExitMoveMode()
        end

end, "lock")

CMD(function(cmd, args, msg, isWarrior)
        RC:TutorialCommand(args[2])
end, "tutorial", "tour")

-- /rc flavor: which client Readycheck runs as and what it switches off;
-- /rc flavor era|tbc|forever|auto sets the developer override (Core_Flavor).
CMD(function(cmd, args, msg, isWarrior)
        RC:FlavorCommand(args[2])
end, "flavor")

CMD(function(cmd, args, msg, isWarrior)
        RC:SetupWizardCommand()
end, "setup", "wizard")

-- SETUP2: /rc hints lists the one-time tips shown; /rc hints reset brings
-- them (and the first-run tour) back
CMD(function(cmd, args, msg, isWarrior)
        if not RC.Hints then RC:Print(RCL["The hints did not load."]) return end
        if (args[2] or ""):lower() == "reset" then
            RC.Hints.Reset()
            RC:Print(RCL["Hints reset - every one-time tip shows again, and the tour on your next open of the settings."])
        else
            local seen = RC.Hints.List()
            if #seen == 0 then RC:Print(RCL["No one-time hints shown yet."])
            else RC:Print(RCL["Hints shown: "] .. table.concat(seen, ", ")) end
        end
end, "hints")

-- SETUP2: /rc uninstall puts back every game setting Readycheck changed,
-- turns every Readycheck addon off and reloads (asks first)
CMD(function(cmd, args, msg, isWarrior)
        if RC.UninstallCommand then RC:UninstallCommand() else RC:Print(RCL["The uninstall helper did not load."]) end
end, "uninstall")

CMD(function(cmd, args, msg, isWarrior)
        if RC.PrintClassAbilityRoster then
            RC:PrintClassAbilityRoster()
        else
            RC:Print(RCL["Ability roster not loaded."])
        end
end, "abilities", "roster")

CMD(function(cmd, args, msg, isWarrior)
        local rest = table.concat(args, " ", 2)
        if rest ~= "" and RC.WorldBuffs and RC.WorldBuffs.HandleDiagCommand then
            RC.WorldBuffs:HandleDiagCommand(rest)
        elseif RC.ToggleWorldBuffMini then
            RC:ToggleWorldBuffMini()
        end

end, "wb", "worldbuffs", "worldbuff")

CMD(function(cmd, args, msg, isWarrior)
        local mc = ReadycheckDB and ReadycheckDB.meshSync
        if not mc then
            RC:Print(RCL["Mesh Network is not set up yet. Open Mesh Network Setup first."])
        else
            mc.crossFaction = not mc.crossFaction
            if mc.crossFaction then
                RC:Print(RCL["Cross-faction world-buff sync ENABLED. Both accounts must be online, Battle.net friends, and use the same mesh password."])
            else
                RC:Print(RCL["Cross-faction world-buff sync disabled."])
            end
        end

end, "crossfaction", "xfaction")

CMD(function(cmd, args, msg, isWarrior)
        local wb = RC.WorldBuffs
        local rem = wb and wb.removals
        if rem then
            local n = 0
            for k in pairs(rem) do rem[k] = nil; n = n + 1 end
            RC:Print(RCL["Cleared "] .. n .. RCL[" world-buff removal tombstone(s)."])
        else
            RC:Print(RCL["No world-buff removals to clear."])
        end

end, "wbclearremovals", "wbclear")

CMD(function(cmd, args, msg, isWarrior)
        local query = table.concat(args, " ", 2)
        if query == "" and UnitExists("target") then query = UnitName("target") or "" end
        query = query:lower()
        if query == "" then
            RC:Print(RCL["Usage: /rc dmfdump <boss name> (or target the boss first)"])
        else
            local calc = RC.executeCalculator
            local data = calc and calc.fightHistory and calc.fightHistory.data
            if not data then
                RC:Print(RCL["No kill history data."])
            else
                local shownKeys = {}
                local matched = 0
                for bossKey, fights in pairs(data) do
                    local raidName, bossName
                    if type(bossKey) == "string" then
                        if bossKey:find("|", 1, true) then
                            local rest
                            raidName, rest = bossKey:match("^([^|]+)|(.+)$")
                            if rest then bossName = rest:match("^.-_(.+)$") end
                        else
                            raidName, bossName = bossKey:match("^(.-)_(.+)$")
                        end
                    end
                    if bossName and type(fights) == "table" and bossName:lower():find(query, 1, true) then
                        matched = matched + 1
                        local tag = ""
                        if raidName and RC.GetFightHistoryForBoss then
                            local sk = raidName .. "\1" .. bossName
                            if shownKeys[sk] == nil then
                                local _, winKey = RC:GetFightHistoryForBoss(raidName, bossName)
                                shownKeys[sk] = winKey or false
                            end
                            if shownKeys[sk] == bossKey then
                                tag = "  |cff00ff00<- History tab shows this bucket|r"
                            end
                        end
                        RC:Print(string.format(RCL["|cffffd100%s|r  (%d kills)%s"], bossKey, #fights, tag))
                        for i, f in ipairs(fights) do
                            local ft = f.totalFightTime or 0
                            local src = f.isManualEntry and "Manual" or (f.isTestFight and "Test" or "Combat")
                            RC:Print(string.format(RCL["  %d) %d:%02d  %s  ts=%s  DMF=%s  profile=%s  class=%s  %s"],
                                i, math.floor(ft/60), math.floor(ft%60),
                                f.timestamp and date("%m/%d %H:%M:%S", f.timestamp) or "-",
                                tostring(f.timestamp or "?"),
                                f.hasSayge and "|cff00ff00YES|r" or RCL["no"],
                                tostring(f.profileName or "-"), tostring(f.class or "-"), src))
                        end
                    end
                end
                if matched == 0 then
                    RC:Print(RCL["No kill buckets found matching '"] .. query .. "'.")
                end
            end
        end

end, "dmfdump")

CMD(function(cmd, args, msg, isWarrior)
        local mc = ReadycheckDB and ReadycheckDB.meshSync
        if not mc then
            RC:Print(RCL["Mesh Network is not set up yet. Open Mesh Network Setup first."])
        else
            mc.crossFactionPeers = mc.crossFactionPeers or {}
            local tag = args[2]
            if tag and tag ~= "" then
                mc.crossFactionPeers[tag] = true
                RC:Print(RCL["Added cross-faction sync peer: "] .. tag .. RCL[". World buffs will be whispered to this account."])
            else
                local list = ""
                for t in pairs(mc.crossFactionPeers) do
                    list = (list == "") and t or (list .. ", " .. t)
                end
                if list == "" then
                    RC:Print(RCL["No cross-faction sync peers. Add one with: /rc xfpeer Name#1234"])
                else
                    RC:Print(RCL["Cross-faction sync peers: "] .. list)
                end
            end
        end

end, "xfpeer")

CMD(function(cmd, args, msg, isWarrior)
        local mc = ReadycheckDB and ReadycheckDB.meshSync
        if mc and mc.crossFactionPeers then
            local n = 0
            for k in pairs(mc.crossFactionPeers) do mc.crossFactionPeers[k] = nil; n = n + 1 end
            RC:Print(RCL["Cleared "] .. n .. RCL[" cross-faction sync peer(s)."])
        else
            RC:Print(RCL["No cross-faction sync peers to clear."])
        end
end, "xfpeerclear")

CMD(function(cmd, args, msg, isWarrior)
        RC:LoadExtras()
        if RC.Changelog and RC.Changelog.Show then
            RC.Changelog:Show()
        end

end, "changelog")

CMD(function(cmd, args, msg, isWarrior)
        RC:ShowTestReminder()

end, "test")

CMD(function(cmd, args, msg, isWarrior)
        RC:HideReminder()

end, "clear")

CMD(function(cmd, args, msg, isWarrior)
        if not isWarrior then
            return
        end

        local raidName = args[2]
        local bossName = args[3]

        if not raidName or not bossName then
            return
        end

        if args[4] then
            for i = 4, #args do
                bossName = bossName .. " " .. args[i]
            end
        end

        RC:StartBossSimulation(raidName, bossName)

end, "sim", "simulate")

CMD(function(cmd, args, msg, isWarrior)
        if RC.StopSimulation then
            RC:StopSimulation()
        end

end, "stopsim")

CMD(function(cmd, args, msg, isWarrior)
        local bossName = args[2]
        if bossName then
            for i = 3, #args do bossName = bossName .. " " .. args[i] end
        end
        if RC.StartGearSwapSim then
            RC:StartGearSwapSim(bossName)
        end

end, "gearsim")

CMD(function(cmd, args, msg, isWarrior)
        local sub = args[2] and args[2]:lower() or ""

        if sub == "start" then
            local bossName = args[3]
            if not bossName then
                RC:Print(RCL["Usage: /rc encounter start <boss name>. Known bosses:"])
                if RC.raidMobConfigs then
                    for raidName, bosses in pairs(RC.raidMobConfigs) do
                        local names = {}
                        for bn in pairs(bosses) do table.insert(names, bn) end
                        if #names > 0 then
                            RC:Print("  " .. raidName .. ": " .. table.concat(names, ", "))
                        end
                    end
                end
                return
            end
            if args[4] then
                for i = 4, #args do bossName = bossName .. " " .. args[i] end
            end

            local canonicalName, raidName = nil, nil
            if RC.raidMobConfigs then
                local lower = bossName:lower()
                for raid, bosses in pairs(RC.raidMobConfigs) do
                    for bn in pairs(bosses) do
                        if bn:lower() == lower then
                            canonicalName = bn
                            raidName = raid
                            break
                        end
                    end
                    if canonicalName then break end
                end
            end
            bossName = canonicalName or bossName
            raidName = raidName or "Unknown"

            RC.activeEncounterName = bossName
            RC.activeEncounterRaid = raidName

            if RC.UpdateBossNotes then RC:UpdateBossNotes() end

            if RC.executeCalculator and RC.OnExecuteCombatStart then
                local calc = RC.executeCalculator
                if not calc.currentFight or not calc.currentFight.started then
                    calc.pendingBossTarget = {
                        name          = bossName,
                        guid          = nil,
                        maxHP         = nil,
                        raidName      = raidName,
                        encounterName = bossName,
                    }
                end
                RC:OnExecuteCombatStart()
            end

            if RC.RunTriggerCheck then RC:RunTriggerCheck() end

        elseif sub == "end" then
            RC.activeEncounterName = nil
            RC.activeEncounterRaid = nil

            if RC.UpdateBossNotes   then RC:UpdateBossNotes()   end
            if RC.OnExecuteCombatEnd then RC:OnExecuteCombatEnd() end

        end

end, "encounter")

CMD(function(cmd, args, msg, isWarrior)
        local subcmd = args[2] and args[2]:lower() or "help"

        if subcmd == "show" then
            if RC.db then RC.db.minimapButton = RC.db.minimapButton or {} end
            if RC.db then RC.db.minimapButton.hide = false end
            if RC.ShowMinimapButton then RC:ShowMinimapButton() end
        elseif subcmd == "hide" then
            if RC.db then RC.db.minimapButton = RC.db.minimapButton or {} end
            if RC.db then RC.db.minimapButton.hide = true end
            if RC.HideMinimapButton then RC:HideMinimapButton() end
        elseif subcmd == "toggle" then
            local isHidden = RC.db and RC.db.minimapButton and RC.db.minimapButton.hide
            if isHidden then
                if RC.db then RC.db.minimapButton.hide = false end
                if RC.ShowMinimapButton then RC:ShowMinimapButton() end
            else
                if RC.db then RC.db.minimapButton = RC.db.minimapButton or {} end
                if RC.db then RC.db.minimapButton.hide = true end
                if RC.HideMinimapButton then RC:HideMinimapButton() end
            end
        elseif subcmd == "reset" then
            if RC.ResetMinimapButtonPosition then
                RC:ResetMinimapButtonPosition()
            end
        end

end, "minimap")

CMD(function(cmd, args, msg, isWarrior)
        if not RC.db.polarityMode then
            RC.db.polarityMode = {}
            if RC.InitializePolarityModeDB then RC:InitializePolarityModeDB() end
        end
        local sub = args[2] and args[2]:lower() or ""
        if sub == "on" then
            RC.db.polarityMode.enabled = true
            RC:SaveConfigurationToProfile()
            if RC.PolarityRearmThaddiusWatch then RC:PolarityRearmThaddiusWatch() end
            RC:Print(RCL["Polarity Mode: |cff00ff00ON|r"])
        elseif sub == "off" then
            RC.db.polarityMode.enabled = false
            RC:SaveConfigurationToProfile()
            if RC.PolarityReset then RC:PolarityReset() end
            if RC.PolarityStopThaddiusTimer then RC:PolarityStopThaddiusTimer() end
            if RC.PolarityRearmThaddiusWatch then RC:PolarityRearmThaddiusWatch() end
            RC:Print(RCL["Polarity Mode: |cffff0000OFF|r"])
        elseif sub == "test" or sub == "pull" then
            if not RC.db.polarityMode.enabled then
                RC:Print(RCL["Polarity Mode is OFF - turn it on first with /rc polarity on"])
            elseif RC.PolarityScheduleSequence then
                local seconds = tonumber(args[3]) or 10
                -- the pull timer on Sapphiron and the sequence it starts
                local function Pull()
                    if not (RC.db.polarityMode and RC.db.polarityMode.enabled) then return end
                    RC:Print(RCL["Polarity Mode: simulating "] .. seconds .. RCL["s pull timer (ignoring Sapphiron check)"])
                    -- Restores savedEnc after seconds+30s; running this test
                    -- command a second time before that restore fires will
                    -- capture "Sapphiron" as savedEnc instead of the real
                    -- prior encounter, losing the original value.
                    local savedEnc = RC.activeEncounterName
                    RC.activeEncounterName = "Sapphiron"
                    RC:PolarityScheduleSequence(seconds, "manual_test")
                    C_Timer.After(seconds, function()
                        if RC.PolarityFireCombatAnchored and RC.polarityMode.armed then
                            RC:PolarityFireCombatAnchored("manual_test_combat_start")
                        end
                    end)
                    C_Timer.After(seconds + 30, function() RC.activeEncounterName = savedEnc end)
                end
                -- "test" plays the night in order: Thaddius dies (the
                -- Thaddius timer, when it is on), then the pull timer on
                -- Sapphiron. "pull" is the pull timer alone.
                local thad = sub == "test" and RC.db.polarityMode.thadTimer ~= false
                    and RC.PolarityStartThaddiusTimer
                if thad then
                    local tsec = tonumber(RC.db.polarityMode.thadTimerSec) or 24
                    RC:Print(string.format(RCL["Polarity Mode test: Thaddius died - the Thaddius timer runs %ds, then a %ds pull timer on Sapphiron."],
                        tsec, seconds))
                    RC:PolarityStartThaddiusTimer(tsec, "manual_test")
                    C_Timer.After(tsec + 1, Pull)
                else
                    Pull()
                end
            end
        elseif sub == "thad" then
            if not RC.db.polarityMode.enabled then
                RC:Print(RCL["Polarity Mode is OFF - turn it on first with /rc polarity on"])
            elseif RC.PolarityStartThaddiusTimer then
                local seconds = tonumber(args[3]) or RC.db.polarityMode.thadTimerSec or 24
                RC:Print(RCL["Polarity Mode: Thaddius timer test, "] .. seconds .. "s")
                RC:PolarityStartThaddiusTimer(seconds, "manual_test")
            end
        else
            local status = (RC.db.polarityMode.enabled and "|cff00ff00ON|r" or "|cffff0000OFF|r")
            RC:Print(RCL["Polarity Mode: "] .. status .. RCL[" (DW lead="] ..
                (RC.db.polarityMode.deathWishLead or 5) .. "s, LIP=" ..
                (RC.db.polarityMode.lipTime or 5) .. "s)")
            RC:Print(RCL["Commands: /rc polarity on | off | test [seconds] | pull [seconds] | thad [seconds]"])
        end
end, "polarity")

CMD(function(cmd, args, msg, isWarrior)
        local confirm = args[2] and args[2]:lower() == "confirm"
        if RC.HandleCleanupCommand then
            RC:HandleCleanupCommand(confirm and "confirm" or "")
        end

end, "cleanup")

CMD(function(cmd, args, msg, isWarrior)
        local confirm = args[2] and args[2]:lower() == "confirm"
        if confirm then
            if RC.ResetCurrentProfile then
                RC:ResetCurrentProfile()
            end
        else
            RC:Print(RCL["|cFFFF0000WARNING: This will reset your current character's profile to defaults!|r"])
            RC:Print(RCL["Type |cFF00FFFF/rc resetprofile confirm|r to proceed"])
        end

end, "resetprofile")

CMD(function(cmd, args, msg, isWarrior)
        local setName = table.concat(args, " ", 2)
        if setName == "" then
            RC:Print(RCL["Usage: /rc gearset <set name>"])
        else
            local nowT = GetTime()
            if RC._macroSwapLockUntil and nowT < RC._macroSwapLockUntil then
                if UIErrorsFrame then
                    UIErrorsFrame:AddMessage("Gear swap in progress", 1, 0.3, 0.3)
                end
                RC:DebugPrint("Macro gearset ignored - swap in progress (" .. setName .. ")", "gear")
                return
            end
            RC._macroSwapLockUntil = nowT + 1.2
            if InCombatLockdown() then
                if RC._lastMacroQueuedSet == setName then
                    RC:DebugPrint("Macro gearset ignored - '" .. setName .. "' already queued for combat end", "gear")
                    return
                end
                RC._lastMacroQueuedSet = setName
                RC:QueueGearSwap(setName)
                RC:Print(RCL["Queued gear set: "] .. setName)
            else
                RC._lastMacroQueuedSet = nil
                local ok = RC:EquipGearSet(setName)
                if not ok then
                    RC:Print(RCL["Gear set not found: "] .. setName)
                end
            end
        end

end, "gearset", "gs")

CMD(function(cmd, args, msg, isWarrior)
        if not isWarrior then
            return
        end

        local subcmd = args[2] and args[2]:lower() or ""
        if subcmd == "bshout" then
            RC:HotswapBattleShout()
        elseif subcmd == "flask" then
            RC:HotswapDiamondFlask()
        elseif subcmd == "bloodrage" or subcmd == "br" then
            RC:HotswapBloodrage()
        end

end, "hotswap", "hs")

CMD(function(cmd, args, msg, isWarrior)
        if not isWarrior then
            return
        end

        local subcmd = args[2] and args[2]:lower() or "summary"

        if subcmd == "summary" then
            local summary = RC:GetAllFightDataSummary()
            if #summary == 0 then
                RC:Print(RCL["No TTK fight history recorded yet."])
                return
            end
            table.sort(summary, function(a, b)
                if a.raidName ~= b.raidName then return a.raidName < b.raidName end
                return a.bossName < b.bossName
            end)
            RC:Print(RCL["TTK fight history summary:"])
            for _, boss in ipairs(summary) do
                local pred = "n/a"
                if boss.predictedTTK then
                    if boss.predictedTTK >= 60 then
                        pred = string.format("%d:%02d", math.floor(boss.predictedTTK / 60), math.floor(boss.predictedTTK % 60))
                    else
                        pred = string.format("%.0fs", boss.predictedTTK)
                    end
                end
                local conf = boss.confidence
                    and string.format(" (%d%% confidence)", math.floor(boss.confidence * 100 + 0.5)) or ""
                RC:Print(string.format("  %s / %s: %d fight(s), predicted TTK %s%s",
                    boss.raidName, boss.bossName, boss.fightCount or 0, pred, conf))
            end
        elseif subcmd == "clear" then
            local bossName = args[3]
            if bossName then
                local raidName = args[4] or RC:GetEffectiveRaidName()
                RC:ClearBossHistory(raidName, bossName)
            end
        elseif subcmd == "clearall" then
            local confirm = args[3] and args[3]:lower() == "confirm"
            if confirm then
                RC:ClearAllHistory()
            end
        end

end, "ttk")

CMD(function(cmd, args, msg, isWarrior)
        if RC.ToggleBattleShoutReminder then
            RC:ToggleBattleShoutReminder()
        end

end, "battleshout", "bs")

CMD(function(cmd, args, msg, isWarrior)
        if not (RC.executeCalculator and RC.executeCalculator.fightHistory and RC.executeCalculator.fightHistory.data) then
            RC:Print(RCL["Fight history not initialized yet - try again after a /reload."])
        else
            local data = RC.executeCalculator.fightHistory.data
            local addPhaseEncounters = {}
            if RC.encounterAddPhases then
                for encName, cfg in pairs(RC.encounterAddPhases) do
                    if cfg.addPhasesBeforeBoss then
                        addPhaseEncounters[encName] = true
                    end
                end
            end

            local flagged = 0
            for bossKey, fights in pairs(data) do
                if type(fights) == "table" and #fights > 0 then
                    local encName = fights[1].encounterName
                    if encName and addPhaseEncounters[encName] then
                        local times = {}
                        for _, f in ipairs(fights) do
                            if not f.isNeverEngaged and f.totalFightTime and f.totalFightTime > 0 then
                                table.insert(times, f.totalFightTime)
                            end
                        end
                        if #times >= 2 then
                            table.sort(times)
                            local median = times[math.floor((#times + 1) / 2)]
                            local cutoff = median * 1.6
                            for _, f in ipairs(fights) do
                                if not f.isNeverEngaged
                                   and f.totalFightTime
                                   and f.totalFightTime >= cutoff
                                then
                                    f.isNeverEngaged = true
                                    flagged = flagged + 1
                                    RC:Print((RCL["  %s: flagged %.1fs kill (median %.1fs)"]):format(
                                        encName, f.totalFightTime, median))
                                end
                            end
                        end
                    end
                end
            end

            if flagged > 0 then
                if RC.SaveExecuteSettings then RC:SaveExecuteSettings() end
                RC:Print((RCL["/rc fixttk: flagged %d suspect kill(s). They stay in history but are excluded from TTK predictions."]):format(flagged))
            else
                RC:Print(RCL["/rc fixttk: no suspect add-phase kills found."])
            end
        end

end, "fixttk")

CMD(function(cmd, args, msg, isWarrior)
        if not (RC.executeCalculator and RC.executeCalculator.fightHistory and RC.executeCalculator.fightHistory.data) then
            RC:Print(RCL["Fight history not initialized yet - try again after a /reload."])
        else
            local data = RC.executeCalculator.fightHistory.data
            local before = {}
            local beforeKeyCount = 0
            for k, v in pairs(data) do
                beforeKeyCount = beforeKeyCount + 1
                before[k] = (type(v) == "table") and #v or 0
            end
            RC:Print(RCL["Fight history before merge: "] .. beforeKeyCount .. RCL[" key(s)"])
            for k, n in pairs(before) do
                RC:Print((RCL["  %s -> %d fight(s)"]):format(tostring(k), n))
            end

            if RC.MigrateFightHistoryAliases then
                RC:MigrateFightHistoryAliases()
            else
                RC:Print(RCL["MigrateFightHistoryAliases unavailable - cannot merge."])
                return
            end

            if RC.SaveExecuteSettings then RC:SaveExecuteSettings() end

            local afterKeyCount = 0
            local afterFightCount = 0
            for _, v in pairs(data) do
                afterKeyCount = afterKeyCount + 1
                if type(v) == "table" then afterFightCount = afterFightCount + #v end
            end
            local merged = beforeKeyCount - afterKeyCount
            RC:Print((RCL["Done. After merge: %d key(s), %d fight(s) total. Merged %d alias key(s)."]):format(
                afterKeyCount, afterFightCount, math.max(0, merged)))
        end

end, "fixhistory")

CMD(function(cmd, args, msg, isWarrior)
        local itemId = tonumber(args[2])
        if RC.ScanTrinketByID then
            RC:ScanTrinketByID(itemId)
        end

end, "scantrinket")

CMD(function(cmd, args, msg, isWarrior)
        if RC.ScanAllTrinkets then
            RC:ScanAllTrinkets()
        end

end, "scantrinkets", "scanall")

CMD(function(cmd, args, msg, isWarrior)
        local itemId = tonumber(args[2])
        if RC.ScanTrinketBuff then
            RC:ScanTrinketBuff(itemId)
        end

end, "scanbuff")

CMD(function(cmd, args, msg, isWarrior)
        if RC.DumpTrinketDatabase then
            RC:DumpTrinketDatabase()
        end

end, "dumptrinkets")

CMD(function(cmd, args, msg, isWarrior)
        if RC.PrintTrinketSwapHistory then
            RC:PrintTrinketSwapHistory()
        end

end, "trinketlog")

CMD(function(cmd, args, msg, isWarrior)
        if RC.PrintConsumablesReport then
            RC:PrintConsumablesReport()
        end

end, "consumreport", "cr")

CMD(function(cmd, args, msg, isWarrior)
        if RC.ToggleConsumablesChecker then
            RC:ToggleConsumablesChecker()
        end

end, "consumcheck", "cc")

CMD(function(cmd, args, msg, isWarrior)
        if RC.ListCustomReminders then
            RC:ListCustomReminders()
        end

end, "reminders")

CMD(function(cmd, args, msg, isWarrior)
        local nameSearch = table.concat(args, " ", 2):lower()
        if nameSearch == "" then
            RC:Print(RCL["Usage: /rc testreminder <name> - fires the first custom reminder matching <name>."])
        elseif RC.db and RC.db.customReminders then
            local found = false
            for _, r in ipairs(RC.db.customReminders.reminders) do
                if r.name and r.name:lower():find(nameSearch, 1, true) then
                    if RC.TestFireCustomReminder then
                        RC:TestFireCustomReminder(r.id)
                    end
                    found = true
                    break
                end
            end
            if not found then
                RC:Print(RCL["No custom reminder found matching: "] .. nameSearch)
            end
        end

end, "testreminder")

CMD(function(cmd, args, msg, isWarrior)
        if RC.OpenConfig then
            RC:OpenConfig()
        end

end, "")

SlashCmdList["READYCHECK"] = function(msg)
    local _, playerClass = UnitClass("player")
    if not playerClass then
        return
    end

    local isWarrior = (playerClass == "WARRIOR")
    local args = {}
    for word in string.gmatch(msg, "%S+") do
        table.insert(args, word)
    end

    local cmd = args[1] and args[1]:lower() or ""


    -- Handled outside RC_CMDS because it needs the item name's original
    -- case preserved for bag name matching - cmd above is already
    -- lowercased for dispatch, so this re-extracts from the raw msg via
    -- a case-insensitive character class instead of using cmd/args.
    do
        local rest = msg:match("^%s*[Ee][Qq][Uu][Ii][Pp]%s*(.+)$")
        if rest and (cmd == "equip" or cmd:sub(1, 6) == "equip(") then
            local item, slotNum = rest:match("^%(%s*(.-)%s*,%s*(%d+)%s*%)%s*$")
            if not item then
                item, slotNum = rest:match("^(.-)%s*,%s*(%d+)%s*$")
            end
            if item and slotNum and RC.MacroEquip then
                RC:MacroEquip(item, slotNum)
            else
                RC:Print(RCL["Usage: /rc equip(Item Name or itemId, slot). Example: /rc equip(Kiss of the Spider,13)"])
            end
            return
        end
    end

    local handler = RC_CMDS[cmd]
    -- a command of a feature this game version does not run is not there
    -- (Core_Flavor); it reads as an unknown command
    if handler and RC.CommandOffByFlavor and RC:CommandOffByFlavor(cmd) then handler = nil end
    if handler then
        handler(cmd, args, msg, isWarrior)
        return
    end

        -- Companion-addon commands (Readycheck_Debug registers profiler /
        -- spikes / taint here); unknown falls through to the usage line.
        local dbgHandler = RC.DebugCommands and RC.DebugCommands[cmd]
        if dbgHandler then
            dbgHandler(args)
        else
            RC:Print(RCL["Unknown command |cFFFF4444"] .. cmd .. RCL["|r - type |cFF00FF00/rc help|r for a full command list."])
        end
end
