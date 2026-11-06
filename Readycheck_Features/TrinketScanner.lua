------------------------------------------------------------------------
-- Readycheck - Trinket Scanner
-- Learns trinkets the hardcoded RC.onUseTrinkets table does not list:
-- on-use spell from GetItemSpell, cooldown parsed out of the tooltip,
-- and the buff correlated from what lands right after the trinket fires.
-- Results live in RC.db.autoDetectedTrinkets, keyed by itemId, and any
-- entry the hardcoded table later covers is purged on load.
-- Tooltip reads go through RC:GetScanTooltip() - one hidden, reusable
-- GameTooltip named WRScanTooltip that is owned once and read by the
-- global font strings WRScanTooltipTextLeft<i>. It is shared rather than
-- per-item because a fresh tooltip frame per scan can never be freed in
-- Lua, and each new one costs another set of permanent globals.
------------------------------------------------------------------------

-- Taint-safe API locals (fallbacks on RC.Compat, built in Core;
-- never write _G - a written Blizzard global taints its readers)
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local UnitBuff = UnitBuff or (RCC and RCC.Compat and RCC.Compat.UnitBuff)

local function InitializeTrinketScanner()
    local RC = _G.Readycheck
    if not RC then
        C_Timer.After(0.1, InitializeTrinketScanner)
        return
    end

    RC.TrinketScanner = {
        autoDetectedTrinkets = {},
        pendingBuffCapture = {},
        lastTrinketUse = 0,
        equippedTrinketSpells = {},
        initialized = false,
    }

    function RC:InitializeTrinketScannerData()
        -- Once per session: PLAYER_ENTERING_WORLD re-fires on every loading
        -- screen, but the purge and the follow-up AutoScan only need to run
        -- on the first successful pass.
        if self.TrinketScanner and self.TrinketScanner.initialized then return end
        if not self.db then
            C_Timer.After(0.5, function() self:InitializeTrinketScannerData() end)
            return
        end

        if not self.db.autoDetectedTrinkets then
            self.db.autoDetectedTrinkets = {}
        end

        self.TrinketScanner.autoDetectedTrinkets = self.db.autoDetectedTrinkets
        self.TrinketScanner.initialized = true

        -- The hardcoded table wins: once a trinket ships there, its learned
        -- copy is dropped so a bad guess cannot outlive the fix.
        local purged = 0
        for itemId, _ in pairs(self.db.autoDetectedTrinkets) do
            if self.onUseTrinkets and self.onUseTrinkets[itemId] then
                self.db.autoDetectedTrinkets[itemId] = nil
                purged = purged + 1
            end
        end
        if purged > 0 then
            self:DebugPrint("Purged " .. purged .. " stale auto-detected trinket(s) now in hardcoded DB", "trinket")
        end

        local count = self:TableCount(self.db.autoDetectedTrinkets)
        self:DebugPrint("Trinket Scanner loaded " .. count .. " auto-detected trinkets", "trinket")

        C_Timer.After(2.0, function()
            self:AutoScanTrinkets()
        end)

        self:DebugPrint("Trinket Scanner initialized", "system")
    end

    function RC:ScanAllTrinketsInInventory()
        local trinkets = {}

        RC.Bags:Each(function(_, _, itemId)
            if not trinkets[itemId] then
                local itemName, _, _, _, _, _, _, _, itemEquipLoc = GetItemInfo(itemId)
                if itemEquipLoc == "INVTYPE_TRINKET" then
                    trinkets[itemId] = itemName
                end
            end
        end)

        -- Inventory slots 13 and 14 are the two trinket slots; equipped
        -- items skip the INVTYPE check because the slot already proves it.
        for slot = 13, 14 do
            local itemId = GetInventoryItemID("player", slot)
            if itemId then
                local itemName = GetItemInfo(itemId)
                if itemName and not trinkets[itemId] then
                    trinkets[itemId] = itemName
                end
            end
        end

        return trinkets
    end

    function RC:AutoScanTrinkets()
        if RC.Profiler then RC.Profiler:StartTiming("TrinketScanner") end

        local trinkets = self:ScanAllTrinketsInInventory()

        local newCount = 0
        for itemId, _ in pairs(trinkets) do
            local isHardcoded = self.onUseTrinkets and self.onUseTrinkets[itemId]
            local alreadyDetected = self.TrinketScanner.autoDetectedTrinkets[itemId]

            if not isHardcoded and not alreadyDetected then
                local data = self:AutoDetectTrinketProperties(itemId)
                if data then
                    self.TrinketScanner.autoDetectedTrinkets[itemId] = data
                    newCount = newCount + 1

                    local itemName = GetItemInfo(itemId)
                    self:DebugPrint("Auto-detected: " .. (itemName or itemId) .. " (" .. (data.isOnUse and "ON-USE" or "PASSIVE") .. ")", "trinket")
                end
            end
        end

        if newCount > 0 then
            self:DebugPrint("Auto-detected " .. newCount .. " new trinket" .. (newCount > 1 and "s" or ""), "trinket")
        end

        if RC.Profiler then RC.Profiler:StopTiming("TrinketScanner") end
    end

    function RC:AutoDetectTrinketProperties(itemId)
        local itemName, itemLink = GetItemInfo(itemId)
        if not itemName then return nil end

        local data = {
            itemId = itemId,
            name = itemName,
            isOnUse = false,
            spellId = nil,
            cooldown = nil,
            detectedAt = time(),
        }

        local spellName, spellId = GetItemSpell(itemId)
        if spellName and spellId then
            data.isOnUse = true
            data.spellId = spellId
        end

        -- Shared scan tooltip: ClearLines before every SetItem, because the
        -- frame is reused and stale lines would otherwise be re-parsed.
        local tooltip = RC:GetScanTooltip()
        tooltip:ClearLines()
        tooltip:SetItemByID(itemId)

        for i = 1, tooltip:NumLines() do
            local line = _G["WRScanTooltipTextLeft" .. i]
            if line then
                local text = line:GetText()
                if text then
                    -- Exact English tooltip wording; a localized client
                    -- prints something else and the cooldown stays nil.
                    local minCD = text:match("(%d+) min cooldown")
                    local secCD = text:match("(%d+) sec cooldown")
                    if minCD then
                        data.cooldown = tonumber(minCD) * 60
                    elseif secCD then
                        data.cooldown = tonumber(secCD)
                    end
                end
            end
        end

        tooltip:Hide()

        return data
    end

    function RC:RefreshEquippedTrinketSpells()
        local TS = self.TrinketScanner
        if not TS then return end
        if not TS.equippedTrinketSpells then TS.equippedTrinketSpells = {} end
        wipe(TS.equippedTrinketSpells)

        local needRetry = false
        for slot = 13, 14 do
            local itemId = GetInventoryItemID("player", slot)
            if itemId then
                local _, spellId = GetItemSpell(itemId)
                if spellId then
                    TS.equippedTrinketSpells[spellId] = itemId
                    if TS.autoDetectedTrinkets and not TS.autoDetectedTrinkets[itemId] then
                        TS.autoDetectedTrinkets[itemId] = {
                            itemId = itemId,
                            name = GetItemInfo(itemId),
                            isOnUse = true,
                            spellId = spellId,
                            detectedAt = time(),
                        }
                        self:DebugPrint("Auto-detected equipped trinket: " .. (GetItemInfo(itemId) or itemId), "trinket")
                    end
                -- Item data is not cached yet, so the missing spell is not
                -- proof the trinket is passive; retry rather than record.
                elseif not GetItemInfo(itemId) then
                    needRetry = true
                end
            end
        end

        if needRetry then
            TS._equipSpellRetries = (TS._equipSpellRetries or 0) + 1
            if TS._equipSpellRetries <= 5 and not TS._equipSpellRetryPending then
                TS._equipSpellRetryPending = true
                C_Timer.After(0.5, function()
                    if not RC.TrinketScanner then return end
                    RC.TrinketScanner._equipSpellRetryPending = false
                    RC:RefreshEquippedTrinketSpells()
                end)
            end
        else
            TS._equipSpellRetries = 0
        end
    end

    local trinketUseFrame = CreateFrame("Frame")
    trinketUseFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    trinketUseFrame:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    trinketUseFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    function RC:CorrelateTrinketBuffs()
        local TS = self.TrinketScanner
        if not TS then return end
        -- Capture window is 4s from the use; past that any new buff is
        -- unrelated and the pending set is abandoned rather than guessed at.
        local now = GetTime()
        if (now - TS.lastTrinketUse) > 4 then
            TS.pendingBuffCapture = {}
            return
        end
        if not next(TS.pendingBuffCapture) then return end

        local buffs = {}
        for _, a in ipairs(RC.Auras:Buffs()) do
            local duration = a.duration
            -- Candidates only: a trinket proc is finite and short, so
            -- anything over 90s or without a duration is not one.
            if a.spellId and duration > 0 and duration <= 90 then
                buffs[#buffs + 1] = {
                    spell   = a.spellId,
                    name    = a.name,
                    appTime = a.expirationTime - duration,
                    dur     = math.floor(duration),
                    player  = (a.source == "player"),
                }
            end
        end

        for itemId, anchor in pairs(TS.pendingBuffCapture) do
            local data = TS.autoDetectedTrinkets[itemId]
            if not (data and not data.buffId) then
                TS.pendingBuffCapture[itemId] = nil
            else
                local bestSpell, bestDur, bestName, bestScore
                for _, b in ipairs(buffs) do
                    -- Correlate by application time against the moment the
                    -- trinket fired: 1.5s either side, then the closest
                    -- wins. The +5 penalty pushes anything not cast by the
                    -- player behind every self-applied candidate.
                    local delta = b.appTime - anchor
                    if delta > -1.5 and delta < 1.5 then
                        local score = math.abs(delta) + (b.player and 0 or 5)
                        if not bestScore or score < bestScore then
                            bestScore, bestSpell, bestDur, bestName = score, b.spell, b.dur, b.name
                        end
                    end
                end
                if bestSpell then
                    data.buffId = bestSpell
                    data.buffDuration = bestDur
                    data.buffName = bestName
                    local itemName = GetItemInfo(itemId)
                    self:DebugPrint("Auto-learned buff for " .. (itemName or itemId) ..
                        ": " .. (bestName or "?") .. " / Spell " .. bestSpell .. " (" .. bestDur .. "s)", "trinket")
                    TS.pendingBuffCapture[itemId] = nil
                end
            end
        end
    end

    function RC:NotifyTrinketUsedForCapture(itemId, useTime)
        local TS = self.TrinketScanner
        if not itemId or not TS or not TS.initialized then return end

        local data = TS.autoDetectedTrinkets[itemId]
        if not data then
            local _, spellId = GetItemSpell(itemId)
            data = {
                itemId = itemId,
                name = GetItemInfo(itemId),
                isOnUse = true,
                spellId = spellId,
                detectedAt = time(),
            }
            TS.autoDetectedTrinkets[itemId] = data
        end

        if data.buffId then return end

        TS.pendingBuffCapture[itemId] = useTime or GetTime()
        TS.lastTrinketUse = GetTime()
        self:CorrelateTrinketBuffs()
    end

    -- UNIT_AURA comes through the shared callback, already coalesced to one
    -- call per 0.1s; it only matters for 4s after a trinket was used.
    RC:RegisterUnitAuraCallback("TrinketScanner", 0.1, function()
        if (GetTime() - RC.TrinketScanner.lastTrinketUse) > 4 then
            RC.TrinketScanner.pendingBuffCapture = {}
            return
        end
        RC:CorrelateTrinketBuffs()
    end)

    trinketUseFrame:SetScript("OnEvent", function(self, event, ...)
        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            local unit, _, spellId = ...
            if unit ~= "player" or not spellId then return end

            local trinketId = RC.TrinketScanner.equippedTrinketSpells[spellId]
            if trinketId then
                RC.TrinketScanner.pendingBuffCapture[trinketId] = GetTime()
                RC.TrinketScanner.lastTrinketUse = GetTime()
                RC:DebugPrint("Detected trinket use: " .. trinketId .. ", watching for buff...", "trinket")
            end

        elseif event == "PLAYER_EQUIPMENT_CHANGED" then
            local slot = ...
            if slot == 13 or slot == 14 then
                RC:RefreshEquippedTrinketSpells()
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            RC:RefreshEquippedTrinketSpells()
        end
    end)

    local bagScanFrame = CreateFrame("Frame")
    bagScanFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    bagScanFrame:SetScript("OnEvent", function()
        RC:InitializeTrinketScannerData()
    end)

    -- A rescan 0.5s after the bags really changed (shared bag index), one
    -- pending at a time. The old 5s gate dropped any loot that landed
    -- within 5s of the previous one, so a trinket picked up in a looting
    -- burst was not scanned until the bags next changed.
    local scanPending = false
    RC.Bags:OnChange("TrinketScanner", function()
        if scanPending then return end
        scanPending = true
        C_Timer.After(0.5, function()
            scanPending = false
            if RC.TrinketScanner.initialized then
                RC:AutoScanTrinkets()
            end
        end)
    end)

    function RC:ScanTrinketByID(itemId)
        if not itemId then
            self:Print(RCL["Usage: /rc scantrinket <itemID>"])
            return
        end

        local itemName, itemLink = GetItemInfo(itemId)
        if not itemName then
            self:Print(RCL["Item ID "] .. itemId .. RCL[" not found. Make sure it's in your bags/bank or cached."])
            return
        end

        self:Print(RCL["=== Scanning Trinket: "] .. itemLink .. " ===")
        self:Print(RCL["Item ID: "] .. itemId)

        local spellName, spellId = GetItemSpell(itemId)
        local isOnUse = (spellName ~= nil)

        if isOnUse then
            self:Print(RCL["Type: ON-USE"])
            self:Print(RCL["Spell Name: "] .. (spellName or "Unknown"))
            self:Print(RCL["Spell ID: "] .. (spellId or "Unknown"))
        else
            self:Print(RCL["Type: PASSIVE"])
        end

        if self.TrinketScanner.autoDetectedTrinkets[itemId] then
            local data = self.TrinketScanner.autoDetectedTrinkets[itemId]
            self:Print(RCL["Auto-Detected Data:"])
            if data.cooldown then
                self:Print(RCL["  Cooldown: "] .. data.cooldown .. "s")
            end
            if data.buffId then
                self:Print(RCL["  Buff ID: "] .. data.buffId)
                self:Print(RCL["  Buff Duration: "] .. data.buffDuration .. "s")
            end
        end

        -- Anything at or under 1.5s is the global cooldown bleeding
        -- through, not the trinket's own.
        local cdDur = 0
        local s, d = RC.Bags:Cooldown(itemId)
        if s > 0 and d > 1.5 then cdDur = d end
        if cdDur > 1.5 then
            local cdSeconds = math.floor(cdDur)
            local cdMinutes = math.floor(cdSeconds / 60)
            self:Print(RCL["Current Cooldown: "] .. cdSeconds .. RCL[" seconds ("] .. cdMinutes .. RCL[" min)"])
        end

        local tooltip = RC:GetScanTooltip()
        tooltip:ClearLines()
        tooltip:SetItemByID(itemId)

        for i = 1, tooltip:NumLines() do
            local line = _G["WRScanTooltipTextLeft" .. i]
            if line then
                local text = line:GetText()
                if text then
                    if text:find("min cooldown") or text:find("sec cooldown") then
                        self:Print(RCL["Tooltip Cooldown: "] .. text)
                    end
                    if text:find("charges") or text:find("Charges") then
                        self:Print(RCL["Charges: "] .. text)
                    end
                    if text:find("for %d+ sec") then
                        self:Print(RCL["Duration: "] .. text)
                    end
                end
            end
        end

        tooltip:Hide()

        self:Print(RCL["--- Copy/Paste This ---"])
        self:Print("[" .. itemId .. RCL["] = true, -- "] .. itemName .. (isOnUse and " (on-use)" or " (passive)"))

        if isOnUse and spellId then
            self:Print(RCL["-- Spell ID: "] .. spellId .. RCL[" for buff tracking"])
        end

        self:Print(RCL["=== Scan Complete ==="])
    end

    function RC:ScanAllTrinkets()
        self:Print(RCL["=== Scanning All Trinkets In Bags ==="])

        local trinkets = self:ScanAllTrinketsInInventory()

        local count = 0
        for itemId, itemName in pairs(trinkets) do
            count = count + 1

            local spellName, spellId = GetItemSpell(itemId)
            local isOnUse = (spellName ~= nil)
            local typeStr = isOnUse and "ON-USE" or "PASSIVE"

            self:Print(itemName .. " (" .. itemId .. ") - " .. typeStr)

            if isOnUse and spellId then
                self:Print(RCL["  Spell ID: "] .. spellId)
            end

            if self.TrinketScanner.autoDetectedTrinkets[itemId] then
                local data = self.TrinketScanner.autoDetectedTrinkets[itemId]
                if data.buffId then
                    self:Print(RCL["  Auto-learned buff: "] .. data.buffId .. " (" .. data.buffDuration .. "s)")
                end
            end
        end

        self:Print(RCL["=== Found "] .. count .. RCL[" trinkets ==="])
        self:Print(RCL["Use /rc scantrinket <itemID> for detailed info on a specific trinket"])
    end

    function RC:ScanTrinketBuff(itemId)
        if not itemId then
            self:Print(RCL["Usage: /rc scanbuff <itemID>"])
            self:Print(RCL["Use this AFTER activating the trinket to capture the buff spell ID"])
            return
        end

        local itemName, itemLink = GetItemInfo(itemId)
        if not itemName then
            self:Print(RCL["Item ID "] .. itemId .. RCL[" not found"])
            return
        end

        self:Print(RCL["=== Scanning Active Buffs for "] .. itemLink .. " ===")

        local foundBuff = false
        local now = GetTime()

        for i = 1, 40 do
            local name, icon, count, debuffType, duration, expirationTime, source, isStealable, nameplateShowPersonal, spellId = UnitBuff("player", i)
            if not name then break end

            -- "Recent" = applied within the last 2 seconds, i.e. still
            -- carrying all but 2s of its full duration.
            if expirationTime and (expirationTime - now) > (duration - 2) then
                self:Print(RCL["Recent Buff: "] .. name .. RCL[" (Spell ID: "] .. spellId .. ")")
                self:Print(RCL["  Duration: "] .. math.floor(duration) .. RCL[" seconds"])
                self:Print(RCL["  Expires in: "] .. math.floor(expirationTime - now) .. RCL[" seconds"])
                self:Print(RCL["--- Add This Line ---"])
                self:Print("[" .. itemId .. RCL["] = {buffId = "] .. spellId .. RCL[", duration = "] .. math.floor(duration) .. "}, -- " .. itemName)
                foundBuff = true
            end
        end

        if not foundBuff then
            self:Print(RCL["No recently applied buffs found. The addon should auto-capture this when you use the trinket."])
        end
    end

    function RC:DumpTrinketDatabase()
        self:Print(RCL["=== Trinket Database ==="])

        self:Print(RCL["|cffFFAA00Hardcoded Trinkets:|r"])
        local sorted = {}
        for itemId, _ in pairs(self.onUseTrinkets or {}) do
            table.insert(sorted, itemId)
        end
        table.sort(sorted)

        local hardcodedCount = 0
        for _, itemId in ipairs(sorted) do
            local itemName = GetItemInfo(itemId)
            if itemName then
                self:Print("  [" .. itemId .. "] " .. itemName)
                hardcodedCount = hardcodedCount + 1
            end
        end
        self:Print(RCL["Total: "] .. hardcodedCount)

        self:Print(" ")
        self:Print(RCL["|cffFFAA00Auto-Detected Trinkets:|r"])
        local autoSorted = {}
        for itemId, _ in pairs(self.TrinketScanner.autoDetectedTrinkets) do
            table.insert(autoSorted, itemId)
        end
        table.sort(autoSorted)

        local autoCount = 0
        for _, itemId in ipairs(autoSorted) do
            local data = self.TrinketScanner.autoDetectedTrinkets[itemId]
            local itemName = data.name or GetItemInfo(itemId) or "Unknown"
            local typeStr = data.isOnUse and "ON-USE" or "PASSIVE"
            self:Print("  [" .. itemId .. "] " .. itemName .. " (" .. typeStr .. ")")
            if data.buffId then
                self:Print(RCL["    Buff: "] .. data.buffId .. " (" .. data.buffDuration .. "s)")
            end
            autoCount = autoCount + 1
        end
        self:Print(RCL["Total: "] .. autoCount)
    end

    RC:DebugPrint("Trinket Scanner loaded (automatic mode)", "system")
end

InitializeTrinketScanner()
