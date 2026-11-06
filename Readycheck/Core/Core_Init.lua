------------------------------------------------------------------------
-- Readycheck - SavedVariables Init / Event Registration
-- Owns RC:Initialize (WarriorReminderDB -> ReadycheckDB migration, default
-- merging into the per-character profile) and RC:RegisterEvent, the single
-- gateway every other file uses to hook a WoW event into RC:OnEvent.
------------------------------------------------------------------------
local pairs, type, tostring = pairs, type, tostring
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end

-- Recursively fills any keys missing from dst out of src (table values are
-- deep-copied via RC.DeepCopy, defined in PM_Profile.lua and available by
-- the time RC:Initialize runs). Shared by every seed-or-fill block below.
local function FillMissing(dst, src)
    if type(src) ~= "table" or type(dst) ~= "table" then return end
    for k, v in pairs(src) do
        if dst[k] == nil then
            if type(v) == "table" then
                dst[k] = RC.DeepCopy(v)
            else
                dst[k] = v
            end
        elseif type(v) == "table" and type(dst[k]) == "table" then
            FillMissing(dst[k], v)
        end
    end
end

function RC:Initialize()
    if not self.LSM and LibStub then
        self.LSM = LibStub:GetLibrary("LibSharedMedia-3.0", true)
    end

    if not self:ValidateCharacterRequirements() then
        C_Timer.After(5, function()
            if not self.playerClass then
                self:ValidateCharacterRequirements()
            end
        end)
        return false
    end

    -- One-time SavedVariables rename: old installs stored everything under
    -- WarriorReminderDB. Adopt it wholesale if ReadycheckDB doesn't exist
    -- yet, then drop the old global so it isn't re-migrated next login.
    if type(ReadycheckDB) ~= "table" and type(WarriorReminderDB) == "table" then
        ReadycheckDB = WarriorReminderDB
        self:DebugPrint("Migrated WarriorReminderDB into ReadycheckDB", "config")
    end
    WarriorReminderDB = nil

    if not ReadycheckDB then
        ReadycheckDB = {}
        self:DebugPrint("Created new ReadycheckDB", "config")
    else
        self:DebugPrint("ReadycheckDB already exists", "config")
    end

    FillMissing(ReadycheckDB, self.defaults)

    local charKey = self:GetCharacterKey()

    if not ReadycheckDB.characters then
        ReadycheckDB.characters = {}
    end

    if not ReadycheckDB.characters[charKey] then
        -- Shared new-profile shape - see RC:BuildDefaultCharacterProfile in
        -- PM_Profile.lua (the single source of truth for this table).
        ReadycheckDB.characters[charKey] = self:BuildDefaultCharacterProfile()
        FillMissing(ReadycheckDB.characters[charKey], self.defaults)
    else
        local profile = ReadycheckDB.characters[charKey]
        FillMissing(profile, self.defaults)

        do
            local count = 0
            if profile.consumablesChecker and profile.consumablesChecker.disabledItems then
                for id in pairs(profile.consumablesChecker.disabledItems) do
                    count = count + 1
                end
            end
            self:DebugPrint("Loaded consumablesChecker with " .. count .. " disabled items", "items")
        end
    end

    self.db = ReadycheckDB.characters[charKey]

    self.db.enabled = true
    self:DebugPrint("ENABLED - isWarrior = " .. tostring(self.isWarrior) .. ", db.enabled = " .. tostring(self.db.enabled), "config")

    self:InitializeSystems()

    self:CreateReminderFrame()
    self:ScanEquippedTrinkets()

    self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")

    return true
end

function RC:InitializeSystems()
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

    self.combatState = {
        inCombat = false,
        combatStartTime = 0,
        usedAbilities = {},
        lastCheck = 0
    }

    self.testingFramework = {
        active = false,
        mockData = {},
        testResults = {},
        simulatedTarget = nil,
        originalFunctions = {},
        mockRaid = nil,
        timeOffset = 0
    }

    self:RegisterEvent("PLAYER_TARGET_CHANGED")
    self:RegisterEvent("UNIT_HEALTH", "target")
    self:RegisterEvent("PLAYER_REGEN_ENABLED")
    self:RegisterEvent("PLAYER_REGEN_DISABLED")
    self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
end

-- UNIT_AURA is refused here on purpose: Core_Events.lua owns the single
-- UNIT_AURA("player") registration and fans out to subscribers via
-- RegisterUnitAuraCallback, so a second direct registration would just
-- double-fire the coalescing logic.
function RC:RegisterEvent(event, unit)
    if event == "UNIT_AURA" then
        self:DebugPrint("Blocked UNIT_AURA registration (safe mode)", "event")
        return
    end
    -- WoW Forever has no combat log for addons: registering it is an error there
    if event == "COMBAT_LOG_EVENT_UNFILTERED" and _G.READYCHECK_IS_FOREVER then return end

    -- self.events is keyed by event name only, not event+unit. If this
    -- event was already registered for one unit (e.g. UNIT_HEALTH for
    -- "target"), a later call with a different unit is silently ignored
    -- because the frame already exists - it will not also watch the new unit.
    if not self.events[event] then
        self.events[event] = CreateFrame("Frame")

        if unit and (event == "UNIT_HEALTH" or event == "UNIT_POWER_UPDATE"
                  or event == "UNIT_AURA" or event == "UNIT_SPELLCAST_SUCCEEDED") then
            self.events[event]:RegisterUnitEvent(event, unit)
        else
            self.events[event]:RegisterEvent(event)
        end

        self.events[event]:SetScript("OnEvent", function(frame, eventName, ...)
            self:OnEvent(eventName, ...)
        end)
    end
end
