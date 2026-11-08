------------------------------------------------------------------------
-- Readycheck - One-time hints
-- A thing Readycheck says or shows once per account (the first raid entry's
-- profile picker note, the setup's own tips...), written down so it is
-- never said twice, with a reset that lets every hint come back.
--
--   RC.Hints.Once(id, fn)    runs fn the first time only; true when it ran
--   RC.Hints.Say(id, text)   the common case: one line in chat, once
--   RC.Hints.Seen(id)        has this hint been shown
--   RC.Hints.Mark(id)        count it as shown without showing anything
--   RC.Hints.Reset()         every hint may show again
--   RC.Hints.List()          the ids seen, sorted
--
-- Also here, so the General page needs only one line: RC:SetupGeneralCard
-- (the card's body: run the setup, reset the hints, uninstall).
--
-- Bookkeeping, account-wide, never exported or synced:
--   ReadycheckDB.account.setupHints = { [id] = true }
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end

local Hints = {}

local function DB()
    if type(ReadycheckDB) ~= "table" then return nil end
    if type(ReadycheckDB.account) ~= "table" then ReadycheckDB.account = {} end
    if type(ReadycheckDB.account.setupHints) ~= "table" then ReadycheckDB.account.setupHints = {} end
    return ReadycheckDB.account.setupHints
end

function Hints.Seen(id)
    local d = DB()
    return d ~= nil and d[id] == true
end

function Hints.Mark(id)
    local d = DB()
    if d and id then d[id] = true end
end

function Hints.Once(id, fn)
    if not id or Hints.Seen(id) then return false end
    local d = DB()
    if not d then return false end
    d[id] = true
    if type(fn) == "function" then
        local ok, err = pcall(fn)
        if not ok then RC:DebugPrint("hint '" .. tostring(id) .. "': " .. tostring(err), "wizard") end
    end
    return true
end

function Hints.Say(id, text)
    return Hints.Once(id, function() RC:Print(text) end)
end

-- Every hint comes back.
function Hints.Reset()
    if type(ReadycheckDB) ~= "table" then return end
    if type(ReadycheckDB.account) == "table" then ReadycheckDB.account.setupHints = {} end
end

function Hints.List()
    local out = {}
    local d = DB()
    if d then for id in pairs(d) do out[#out + 1] = id end end
    table.sort(out)
    return out
end

RC.Hints = Hints

------------------------------------------------------------------------
-- The General page's card body: Run the setup | Reset hints | Uninstall
-- (buttons only; a page build writes nothing). Returns the next y.
------------------------------------------------------------------------
-- a hover tooltip, the way the pages attach one (post-hooks, never SetScript)
local function Tip(frame, title, body)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local w = RC:GetColor("text", "white")
        GameTooltip:SetText(title, w.r, w.g, w.b)
        local g = RC:GetColor("text", "gray")
        GameTooltip:AddLine(body, g.r, g.g, g.b, true)
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end
RC.SetupTip = Tip

function RC:SetupGeneralCard(card, y)
    local UI = self.UI
    local gray = self:GetColor("text", "gray")
    local note = self:CreateFontString(card, "OVERLAY", nil, 10)
    note:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
    note:SetPoint("RIGHT", card, "RIGHT", -14, 0)
    note:SetJustifyH("LEFT")
    note:SetText(RCL["The setup runs again any time with its current values. Reset hints brings back every one-time tip. Uninstall puts back every game setting Readycheck changed and turns Readycheck off for all your characters."])
    note:SetTextColor(gray.r, gray.g, gray.b, gray.a or 1)
    y = y - math.max(12, note:GetStringHeight() or 12) - 10

    local run = UI:CreateStyledButton(card, RCL["Run the setup"], 120, 24)
    run:SetPoint("TOPLEFT", card, "TOPLEFT", 14, y)
    run:SetScript("OnClick", function() if RC.SetupWizardCommand then RC:SetupWizardCommand() end end)
    Tip(run, RCL["Run the setup"], RCL["The step-by-step setup. /rc setup does the same."])

    local hints = UI:CreateStyledButton(card, RCL["Reset hints"], 110, 24)
    hints:SetPoint("LEFT", run, "RIGHT", 8, 0)
    hints:SetScript("OnClick", function()
        Hints.Reset()
        RC:Print(RCL["Hints reset - every one-time tip shows again."])
    end)
    Tip(hints, RCL["Reset hints"], RCL["Every one-time tip shows again. /rc hints reset does the same."])

    local un = UI:CreateStyledButton(card, RCL["Uninstall Readycheck"], 150, 24)
    un:SetPoint("LEFT", hints, "RIGHT", 8, 0)
    un:SetScript("OnClick", function() if RC.UninstallCommand then RC:UninstallCommand() end end)
    Tip(un, RCL["Uninstall Readycheck"],
        RCL["Puts back every game setting Readycheck changed, turns every Readycheck addon off for all your characters and reloads. Your saved settings are kept in case you come back."])
    return y - 24 - 10
end

-- /rc uninstall and the General page: asks first, then RC.CVar.Uninstall
-- and a reload.
function RC:UninstallCommand()
    if not self.CVar then self:Print(RCL["The uninstall helper did not load."]) return end
    if InCombatLockdown and InCombatLockdown() then self:Print(RCL["Uninstall cannot run in combat."]) return end
    local function Go()
        if not RC.CVar.Uninstall() then
            RC:Print(RCL["Uninstall could not run right now (in combat?). Try again after the fight."])
            return
        end
        if type(ReloadUI) == "function" then ReloadUI()
        elseif C_UI and C_UI.Reload then C_UI.Reload() end
    end
    if self.UI and self.UI.CreateConfirmDialog then
        self.UI:CreateConfirmDialog(RCL["Uninstall Readycheck"],
            RCL["Every game setting Readycheck changed goes back to what it was, every Readycheck addon is turned off for all your characters, and the interface reloads. Your saved settings stay on disk in case you come back."],
            Go, nil, RCL["Uninstall and reload"], true)
    else
        Go()
    end
end
