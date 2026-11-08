------------------------------------------------------------------------
-- Readycheck - Target Nameplate Range
-- Per-mob nameplate distance: while you target a listed mob, the
-- nameplate view distance switches to that mob's configured range and
-- restores when the target drops or changes. The settings card renders
-- on the Nameplates page (Target Range tab, built by NameplateAuras).
-- Storage: account-wide ReadycheckDB.personalTargeting, shared with the
-- Testing soft-target tools, which read our override state through
-- RC.TargetRange.HasOverride so the two never fight over the cvar.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

RC.TargetRange = RC.TargetRange or {}
local TR = RC.TargetRange

local RANGE_MIN, RANGE_MAX, RANGE_DEFAULT = 5, 41, 20

local function Store()
    if not ReadycheckDB then return nil end
    if type(ReadycheckDB.personalTargeting) ~= "table" then
        ReadycheckDB.personalTargeting = {}
    end
    local s = ReadycheckDB.personalTargeting
    if s.rangeEnabled == nil then s.rangeEnabled = true end
    if type(s.entries) ~= "table" then s.entries = {} end
    return s
end
TR.Store = Store

local baseline = nil

local function InCombat()
    return InCombatLockdown and InCombatLockdown()
end

-- The soft-target tools hold nameplate distance at max while armed, but
-- must never stomp an active per-mob override; they check this.
function TR.HasOverride()
    return baseline ~= nil
end

-- SetCVar is blocked during combat lockdown; skip and let
-- PLAYER_REGEN_ENABLED retry once combat drops.
-- SETUP2: the distance is a HOLD in the CVar record (RC.CVar): the value
-- from before goes back on release, when the feature is off and on
-- uninstall. Without the record (an older core) the plain writes stand.
local OWNER = "targetrange"
local function RestoreRange()
    if baseline and not InCombat() then
        if RC.CVar then
            if not RC.CVar.Release("nameplateMaxDistance", OWNER) then
                RC.CVar.Set("nameplateMaxDistance", baseline, OWNER)
            end
        else
            pcall(SetCVar, "nameplateMaxDistance", baseline)
        end
        baseline = nil
    end
end

local function ApplyForTarget()
    local s = Store()
    if not s or not s.rangeEnabled then RestoreRange(); return end
    local name = UnitExists("target") and Readycheck.SafeName("target") or nil
    if Readycheck.IsSecret(name) then name = nil end   -- (WoW Forever hides an enemy's name in a fight)
    local entry = name and s.entries[name:lower()] or nil
    if entry and entry.range then
        if InCombat() then return end
        if not baseline then
            baseline = tonumber(GetCVar("nameplateMaxDistance")) or RANGE_MAX
            if RC.CVar then RC.CVar.Hold("nameplateMaxDistance", entry.range, OWNER) return end
        end
        if RC.CVar then RC.CVar.Set("nameplateMaxDistance", entry.range, OWNER)
        else pcall(SetCVar, "nameplateMaxDistance", entry.range) end
    else
        RestoreRange()
    end
end
if RC.CVar and RC.CVar.OwnerCheck then
    RC.CVar.OwnerCheck(OWNER, function() local s = Store() return not (s and s.rangeEnabled) end)
end
TR.ApplyForTarget = ApplyForTarget

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:RegisterEvent("PLAYER_LOGOUT")
f:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGOUT" then
        RestoreRange()
        return
    end
    ApplyForTarget()
end)

local function GatherKnownMobs()
    local names, seen = {}, {}
    local function add(m)
        if type(m) == "string" and m ~= "" and not seen[m] then
            seen[m] = true; names[#names + 1] = m
        end
    end
    local rd = RC.raidData
    if type(rd) == "table" then
        for raidName, data in pairs(rd) do
            if type(data) == "table" then
                if type(data.trashSections) == "table" then
                    for _, mobs in pairs(data.trashSections) do
                        if type(mobs) == "table" then
                            for _, m in ipairs(mobs) do add(m) end
                        end
                    end
                end
                if type(data.trash) == "table" then
                    for _, m in ipairs(data.trash) do add(m) end
                end
            end
            -- pcall guards against GetActiveRaidProfile before the raid
            -- profile system has finished initializing.
            local ok, prof = pcall(function()
                return RC.GetActiveRaidProfile and RC:GetActiveRaidProfile(raidName)
            end)
            if ok and type(prof) == "table" and type(prof.bosses) == "table" then
                for bn in pairs(prof.bosses) do add(bn) end
            end
        end
    end
    table.sort(names)
    return names
end

function RC:BuildTargetRangeCard(parent, yPos, frame)
    local s = Store()
    if not s then return yPos end
    local gray = RC:GetColor("text", "gray") or { r = 0.5, g = 0.5, b = 0.5 }
    local norm = RC:GetColor("text", "normal") or { r = 0.8, g = 0.8, b = 0.8 }

    local function Dim(card, text, x, y)
        local fs = RC:CreateFontString(card, "OVERLAY", nil, 10)
        fs:SetPoint("TOPLEFT", card, "TOPLEFT", x, y)
        fs:SetPoint("RIGHT", card, "RIGHT", -15, 0)
        fs:SetJustifyH("LEFT")
        fs:SetText(text)
        fs:SetTextColor(gray.r, gray.g, gray.b)
        return fs
    end

    local card = self:CreateSettingsCard(parent, yPos, "Target nameplate range")
    local cy = -30

    local en = self.UI:CreateCheckbox(card, "Change nameplate distance while targeting listed mobs", s.rangeEnabled)
    en:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
    en:SetScript("OnClick", function()
        s.rangeEnabled = en:GetChecked() and true or false
        RC:ForceCheckboxUpdate(en, s.rangeEnabled)
        ApplyForTarget()
    end)
    cy = cy - 22
    Dim(card, "Distance restores when the target drops or changes. This client blocks cvar changes IN combat, so switches apply when you target before the pull (or right as combat ends).", 15, cy)
    cy = cy - 30

    local keys = {}
    for k in pairs(s.entries) do keys[#keys + 1] = k end
    table.sort(keys)
    if #keys == 0 then
        Dim(card, "No mobs added yet - use the picker below.", 15, cy)
        cy = cy - 22
    else
        for _, k in ipairs(keys) do
            local e = s.entries[k]
            local fs = RC:CreateFontString(card, "OVERLAY", nil, 11)
            fs:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
            fs:SetText((e.name or k) .. "  |cff777777-  " .. (e.range or RANGE_DEFAULT) .. " yd|r")
            fs:SetTextColor(norm.r, norm.g, norm.b)
            local rm = self.UI:CreateStyledButton(card, "Remove", 70, 22)
            rm:SetPoint("TOPRIGHT", card, "TOPRIGHT", -15, cy + 3)
            local kk = k
            rm:SetScript("OnClick", function()
                s.entries[kk] = nil
                ApplyForTarget()
                RC:ShowSidebarNameplates(frame, true)
            end)
            cy = cy - 24
        end
    end

    cy = cy - 8

    local rlbl = RC:CreateFontString(card, "OVERLAY", nil, 10)
    rlbl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
    rlbl:SetText("Range (yd):")
    rlbl:SetTextColor(gray.r, gray.g, gray.b)
    local rangeBox = self.UI:CreateStyledEditBox(card, {
        width = 44, height = 24, maxLetters = 2, initialText = tostring(RANGE_DEFAULT),
    })
    rangeBox:SetPoint("TOPLEFT", card, "TOPLEFT", 82, cy + 4)

    local function ClampRange()
        local r = tonumber(rangeBox.editBox:GetText() or "")
        if not r then r = RANGE_DEFAULT end
        if r < RANGE_MIN then r = RANGE_MIN elseif r > RANGE_MAX then r = RANGE_MAX end
        return r
    end
    local function AddMob(nm)
        nm = nm and nm:match("^%s*(.-)%s*$") or ""
        if nm == "" then RC:Print("Nameplates: no mob to add."); return end
        s.entries[nm:lower()] = { name = nm, range = ClampRange() }
        ApplyForTarget()
        RC:ShowSidebarNameplates(frame, true)
    end

    local tgtBtn = self.UI:CreateStyledButton(card, "Add current target", 150, 24)
    tgtBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 140, cy + 4)
    tgtBtn:SetScript("OnClick", function()
        if not UnitExists("target") then RC:Print("Nameplates: target a mob first."); return end
        AddMob(Readycheck.SafeName("target"))
    end)
    cy = cy - 32

    local nmLbl = RC:CreateFontString(card, "OVERLAY", nil, 10)
    nmLbl:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
    nmLbl:SetText("Or type a name:")
    nmLbl:SetTextColor(gray.r, gray.g, gray.b)
    local nameBox = self.UI:CreateStyledEditBox(card, {
        width = 170, height = 24, maxLetters = 48, initialText = "",
    })
    nameBox:SetPoint("TOPLEFT", card, "TOPLEFT", 110, cy + 4)
    local addBtn = self.UI:CreateStyledButton(card, "Add", 60, 24)
    addBtn:SetPoint("TOPLEFT", card, "TOPLEFT", 288, cy + 4)
    addBtn:SetScript("OnClick", function()
        AddMob(nameBox.editBox and nameBox.editBox:GetText() or "")
    end)
    if nameBox.editBox then
        nameBox.editBox:SetScript("OnEnterPressed", function(eb)
            AddMob(eb:GetText())
            eb:ClearFocus()
        end)
    end
    cy = cy - 32

    local known = GatherKnownMobs()
    if #known > 0 then
        local items = {}
        for _, nm in ipairs(known) do
            if not s.entries[nm:lower()] then
                items[#items + 1] = { text = nm, value = nm }
            end
        end
        if #items > 0 then
            local dd = self.UI:CreateScrollableDropdown(card, 260, "Pick a known raid mob...", 8)
            dd:SetPoint("TOPLEFT", card, "TOPLEFT", 15, cy)
            dd:SetItems(items, function(value) AddMob(value) end)
            cy = cy - 34
        end
    else
        Dim(card, "Tip: the known-mob dropdown fills in once raid data has loaded; the target button always works.", 15, cy)
        cy = cy - 26
    end

    card:SetContentHeight(math.abs(cy))
    yPos = yPos - card:GetHeight() - 15

    return yPos
end
