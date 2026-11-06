------------------------------------------------------------------------
-- Readycheck - UI Framework: the settings change signal
-- Every framework control that edits a setting (checkbox, slider,
-- dropdown, segmented control, sound picker, edit box commit, the colour
-- editor and the pickers) calls RC.UI:NotifySettingChanged(source) AFTER
-- the caller's own handler has run. Listeners (the preview pane, a
-- feature live-applying while the window is open) hear it at once and
-- must coalesce their real work - RC.UI:Coalesce gives one call on the
-- next frame however many changes land in this one.
--
--   RC.UI:NotifySettingChanged(source)   a hand-built control calls this
--   RC.UI:OnSettingsChanged(fn)          fn(source); keep it cheap
--   RC.UI:Coalesce(fn) -> run            run() asks for fn once next frame
--   RC.UI:FillDefaults(t, defaults)      only nil keys, tables copied
------------------------------------------------------------------------
local pairs, type = pairs, type
local C_Timer = C_Timer

local RC = _G.Readycheck
if not RC then return end
RC._uif = RC._uif or {}
local _uif = RC._uif

    local listeners = {}
    RC.UI.settingsStats = { notifies = 0 }

    function RC.UI:OnSettingsChanged(fn)
        if type(fn) == "function" then listeners[#listeners + 1] = fn end
    end

    function RC.UI:NotifySettingChanged(source)
        self.settingsStats.notifies = self.settingsStats.notifies + 1
        for i = 1, #listeners do
            local ok, err = pcall(listeners[i], source)
            if not ok then RC:DebugPrint("Settings listener failed: " .. tostring(err), "config") end
        end
    end

    -- One call of fn on the next frame, however often run() is called
    -- before then. C_Timer.After, not a ticker: nothing is left running.
    function RC.UI:Coalesce(fn)
        local pending = false
        local function Flush()
            pending = false
            fn()
        end
        return function()
            if pending then return end
            pending = true
            C_Timer.After(0, Flush)
        end
    end

    local function CopyValue(v)
        if type(v) ~= "table" then return v end
        local out = {}
        for k, x in pairs(v) do out[k] = CopyValue(x) end
        return out
    end
    _uif.CopyValue = CopyValue

    -- A saved false or 0 is the user's choice: only nil is filled.
    function RC.UI:FillDefaults(t, defaults)
        if type(t) ~= "table" or type(defaults) ~= "table" then return t end
        for k, v in pairs(defaults) do
            if t[k] == nil then
                t[k] = CopyValue(v)
            elseif type(v) == "table" and type(t[k]) == "table" then
                self:FillDefaults(t[k], v)
            end
        end
        return t
    end

    -- Wraps one script on one widget so whatever handler a caller installs
    -- later (SetScript) is followed by the signal. gate(self, ...) may veto
    -- (programmatic slider moves). Installs an empty handler if the caller
    -- never sets one, so the signal still fires.
    local function WrapNotify(obj, scriptName, source, gate)
        if not obj or obj._rcNotifyWrapped and obj._rcNotifyWrapped[scriptName] then return end
        obj._rcNotifyWrapped = obj._rcNotifyWrapped or {}
        obj._rcNotifyWrapped[scriptName] = true
        local rawSet = obj.SetScript
        local function Install(fn)
            rawSet(obj, scriptName, function(self, ...)
                if fn then fn(self, ...) end
                if not gate or gate(self, ...) then RC.UI:NotifySettingChanged(source) end
            end)
        end
        obj.SetScript = function(self, name, fn)
            if name == scriptName then return Install(fn) end
            return rawSet(self, name, fn)
        end
        Install(obj.GetScript and obj:GetScript(scriptName) or nil)
    end
    _uif.WrapNotify = WrapNotify

    local function Notify(source) RC.UI:NotifySettingChanged(source) end
    _uif.NotifySettingChanged = Notify
