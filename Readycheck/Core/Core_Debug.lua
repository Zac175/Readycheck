------------------------------------------------------------------------
-- Readycheck - Debug Printing / Category Gates
-- Owns RC:DebugPrint, RC:Print, per-category enable flags, and the timer
-- helper ScheduleTimer. Debug output is gated per-category and throttled
-- per message so noisy call sites don't spam chat.
-- Depends on Core_Boot.lua having run first (reads _G.Readycheck / _cor).
------------------------------------------------------------------------
local pairs, type, tostring = pairs, type, tostring
local GetTime = GetTime
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
local debugPrintThrottle = {}
local debugPrintThrottleCount = 0
RC.debugCategories = {
    ["core"] = {enabled = false, color = "|cff88ff88", label = "CORE"},
    ["config"] = {enabled = false, color = "|cffffaa00", label = "CONFIG"},
    ["combat"] = {enabled = false, color = "|cffff4444", label = "COMBAT"},

    ["reminder"] = {enabled = false, color = "|cff44aaff", label = "REMINDER"},
    ["trigger"] = {enabled = false, color = "|cff9966ff", label = "TRIGGER"},
    ["dismissal"] = {enabled = false, color = "|cffff66ff", label = "DISMISS"},

    ["tts"] = {enabled = false, color = "|cff00ffff", label = "TTS"},
    ["animation"] = {enabled = false, color = "|cffffcc00", label = "ANIM"},

    ["gear"] = {enabled = false, color = "|cffff8800", label = "GEAR"},
    ["trinket"] = {enabled = false, color = "|cffffaa44", label = "TRINKET"},
    ["hotswap"] = {enabled = false, color = "|cffff6644", label = "HOTSWAP"},
    ["itemrack"] = {enabled = false, color = "|cffaa66ff", label = "ITEMRACK"},
    ["items"] = {enabled = false, color = "|cff66ffaa", label = "ITEMS"},
    ["consumables"] = {enabled = false, color = "|cff44ff88", label = "CONSUMABLES"},

    ["ttk"] = {enabled = false, color = "|cffff66aa", label = "TTK"},
    ["execute"] = {enabled = false, color = "|cffff4466", label = "EXECUTE"},
    ["charstats"] = {enabled = false, color = "|cff66aaff", label = "STATS"},

    ["cooldown"] = {enabled = false, color = "|cff88ccff", label = "COOLDOWN"},
    ["timer"] = {enabled = false, color = "|cffaaaaff", label = "TIMER"},

    ["abilities"] = {enabled = false, color = "|cffffcc88", label = "ABILITY"},

    ["profile"] = {enabled = false, color = "|cffffff88", label = "PROFILE"},

    ["test"] = {enabled = false, color = "|cffffffff", label = "TEST"},
    ["system"] = {enabled = false, color = "|cffcccccc", label = "SYSTEM"},
    ["general"] = {enabled = false, color = "|cffaaaaaa", label = "DEBUG"},
    ["swing"] = {enabled = false, color = "|cffff8844", label = "SWING"},
    ["worldbuffs"] = {enabled = false, color = "|cff99ff66", label = "WBUFF"},
    ["smartmacro"] = {enabled = false, color = "|cffffcc66", label = "SMACRO"},
    ["uimover"] = {enabled = false, color = "|cffcccccc", label = "MOVER"},
    ["omnicc"] = {enabled = false, color = "|cffcccccc", label = "OMNICC"},
    ["buff"] = {enabled = false, color = "|cff88ff88", label = "BUFF"},
    ["polarity"] = {enabled = false, color = "|cff88ccff", label = "POLARITY"},
    ["meshsync"] = {enabled = false, color = "|cff66ffcc", label = "MESH"},
    ["mesh"] = {enabled = false, color = "|cff66ffcc", label = "MESH"},
    ["route"] = {enabled = false, color = "|cff88ffaa", label = "ROUTE"}
}

-- Runs once (guarded by _dbgCatsApplied) the first time self.db exists;
-- later writes to db.debugCatEnabled need a reload to take effect.
function RC:ApplySavedDebugCategories()
    if self._dbgCatsApplied or not self.db then return end
    self._dbgCatsApplied = true
    if self.db.debugCatEnabled then
        for k, v in pairs(self.db.debugCatEnabled) do
            if self.debugCategories[k] then self.debugCategories[k].enabled = v end
        end
    end
end

function RC:IsDebugEnabled(category)
    -- Debug output only exists when Readycheck_Debug is installed.
    -- Core_Stubs always defines RC.Profiler now, so test the stub marker
    -- rather than the table's presence.
    local P = self.Profiler
    if not P or P.isStub then return false end
    if not self._dbgCatsApplied then self:ApplySavedDebugCategories() end
    local cat = self.debugCategories[category]
    return cat and cat.enabled
end

function RC:BrandColorCode()
    if self.GetColor and self.defaultColors then
        -- its own colour, so titles and chat can differ (Titles/Headers
        -- before it existed)
        local c = self:GetColor("ui", "chatBrand")
        if not (c and c.r) then c = self:GetColor("ui", "headerText") end
        if c and c.r then
            return string.format("|cff%02x%02x%02x",
                math.floor((c.r or 1) * 255 + 0.5),
                math.floor((c.g or 1) * 255 + 0.5),
                math.floor((c.b or 1) * 255 + 0.5))
        end
    end
    return "|cffd6a640"
end

function RC:DebugPrint(msg, category, throttleTime)
    -- Same gate as IsDebugEnabled: no Readycheck_Debug, no debug output.
    local P = self.Profiler
    if not P or P.isStub then return end
    if not self._dbgCatsApplied then self:ApplySavedDebugCategories() end
    category = category or "general"

    if not self.debugCategories then return end

    local categoryInfo = self.debugCategories[category]
    if not categoryInfo then
        categoryInfo = self.debugCategories["general"]
        if not categoryInfo then return end
    end

    if not categoryInfo.enabled then return end

    local msgStr = tostring(msg or "")

    if msgStr == "" or msgStr == "nil" then return end
    -- Drops any message containing the substring "unknown" anywhere,
    -- not just messages that are literally "unknown" - a debug line
    -- like "item Unknown Trinket ready" would also get swallowed here.
    local lower = msgStr:lower()
    if lower == "unknown" or lower:find("unknown", 1, true) then return end

    throttleTime = throttleTime or 1
    local now = GetTime()
    local throttleKey = category .. ":" .. msgStr

    if debugPrintThrottle[throttleKey] and (now - debugPrintThrottle[throttleKey]) < throttleTime then
        return
    end

    -- Growth cap: every distinct category+message becomes a table key for
    -- the life of the session; wipe wholesale past ~500 entries.
    if debugPrintThrottle[throttleKey] == nil then
        debugPrintThrottleCount = debugPrintThrottleCount + 1
        if debugPrintThrottleCount > 500 then
            debugPrintThrottle = {}
            debugPrintThrottleCount = 1
        end
    end

    debugPrintThrottle[throttleKey] = now

    print(self:BrandColorCode() .. "Readycheck|r " .. categoryInfo.color .. "[" .. categoryInfo.label .. "]|r " .. msgStr)
end

function RC:ScheduleTimer(func, delay, ...)
    local args = {...}
    local timer = C_Timer.NewTimer(delay, function()
        if type(func) == "string" then
            self[func](self, unpack(args))
        elseif type(func) == "function" then
            func(unpack(args))
        end
    end)
    return timer
end

function RC:Print(msg)
    local msgStr = tostring(msg)

    if msgStr and type(msgStr) == "string" then
        local lower = msgStr:lower()
        if lower:find("unknown") or lower == "nil" or lower == "" then
            return
        end
    end

    print(self:BrandColorCode() .. "Readycheck|r " .. msgStr)
end

function RC:ValidateCharacterRequirements()
    local _, class = UnitClass("player")
    local level = UnitLevel("player")

    if not class or not level or level == 0 then
        C_Timer.After(1, function()
            self:ValidateCharacterRequirements()
        end)
        return false
    end

    self.playerClass = class
    self.playerLevel = level
    self.isWarrior = (class == "WARRIOR")

    if self.isWarrior then
        if level < 30 then
            self:Print(RCL["|cffffff00Warning: Level "] .. level .. RCL[" detected.|r"])
        end
    else
        if not self.nonWarriorNoticeShown then
            self.nonWarriorNoticeShown = true
            self:DebugPrint("Running in non-warrior mode. Warrior-specific features hidden.", "config")
        end
    end

    return true
end
