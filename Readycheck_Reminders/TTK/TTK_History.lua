------------------------------------------------------------------------
-- Readycheck - TTK History Store
-- Writes finished fights into executeCalculator.fightHistory.data
-- (bossKey -> array, newest first) and persists the whole table into
-- ReadycheckDB.characters[char].executeSettings on every change.
-- Also owns the execute-phase detector and the manual/bulk entry UI.
-- Mesh sync ships this table as executeSettings.fightHistory.
------------------------------------------------------------------------
local RCC = _G.Readycheck

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local GetTime = GetTime
local UnitName, UnitExists = UnitName, UnitExists
local RC = _G.Readycheck
if not RC then return end
RC._ttk = RC._ttk or {}
local _ttk = RC._ttk
    -- Sayge's Dark Fortune of Damage (Darkmoon Faire). Kills under it are
    -- stamped hasSayge so PredictTTK can compare buffed to buffed.
    local SAYGE_SPELL_ID = 23768

    -- The fortune can also sit on a character as a DEBUFF (it then stays
    -- off the 32-buff cap). It is the same damage either way, so a kill
    -- under it is a Darkmoon kill.
    function RC:HasSaygeBuff()
        return (RC.Auras:Buff(SAYGE_SPELL_ID) or RC.Auras:Debuff(SAYGE_SPELL_ID)) ~= nil
    end

    --------------------------------------------------------------------
    -- THE CLASS A KILL WAS PLAYED ON
    -- Every kill carries the class of the character that recorded it, as
    -- the client's class token (class = "WARRIOR"). Kills from before
    -- this existed carry none and read as "not recorded". The mesh and
    -- the history transfer copy whole records, so it travels with them.
    --------------------------------------------------------------------
    local CLASS_ORDER = { "WARRIOR", "ROGUE", "HUNTER", "MAGE", "WARLOCK",
                          "PRIEST", "PALADIN", "DRUID", "SHAMAN" }
    RC.TTK_CLASS_ORDER = CLASS_ORDER
    local CLASS_ICON_FILE = "Interface\\Glues\\CharacterCreate\\UI-CharacterCreate-Classes"
    local NO_CLASS_ICON   = "Interface\\Icons\\INV_Misc_QuestionMark"

    function RC:PlayerClassToken()
        local _, token = UnitClass("player")
        return token
    end

    -- the class token on a kill record, or nil when none was stamped
    function RC:FightClass(f)
        local c = type(f) == "table" and f.class
        if type(c) == "string" and c ~= "" then return c end
        return nil
    end

    function RC:ClassLabel(token)
        if not token then return RCL["Not recorded"] end
        local n = LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token]
        if n then return n end
        return token:sub(1, 1) .. token:sub(2):lower()
    end

    -- the class name in its own class colour (plain when not recorded)
    function RC:ClassLabelColored(token)
        local label = self:ClassLabel(token)
        local cc = token and RAID_CLASS_COLORS and RAID_CLASS_COLORS[token]
        if not cc then return label end
        if cc.colorStr then return "|c" .. cc.colorStr .. label .. "|r" end
        return string.format("|cff%02x%02x%02x%s|r", math.floor(cc.r * 255),
            math.floor(cc.g * 255), math.floor(cc.b * 255), label)
    end

    -- a texture as the class's icon, or a faded question mark
    function RC:PaintClassIcon(tex, token)
        if not tex then return end
        local tc = token and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[token]
        if tc then
            tex:SetTexture(CLASS_ICON_FILE)
            tex:SetTexCoord(tc[1], tc[2], tc[3], tc[4])
            tex:SetDesaturated(false)
            tex:SetVertexColor(1, 1, 1)
            tex:SetAlpha(1)
        else
            tex:SetTexture(NO_CLASS_ICON)
            tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            if not tex:SetDesaturated(true) then
                tex:SetVertexColor(0.35, 0.35, 0.35)
            end
            tex:SetAlpha(0.3)
        end
    end

    -- the tooltip lines for a kill's class icon
    function RC:AddClassTooltip(token)
        if token then
            GameTooltip:SetText(RCL["Played as "] .. self:ClassLabelColored(token), 1, 1, 1)
        else
            GameTooltip:SetText(RCL["Class not recorded"], 1, 1, 1)
            GameTooltip:AddLine(RCL["This kill is from before the class was saved with each kill."], 0.7, 0.7, 0.7, true)
        end
        GameTooltip:AddLine(RCL["Click to edit this kill."], 0.7, 0.7, 0.7)
    end

    -- dropdown items: every class, then "Not recorded" (value "")
    function RC:ClassDropdownItems()
        local items = {}
        for _, token in ipairs(CLASS_ORDER) do
            items[#items + 1] = { text = self:ClassLabelColored(token), value = token }
        end
        items[#items + 1] = { text = RCL["Not recorded"], value = "" }
        return items
    end

    -- Three detectors can report the same kill (dead-target scan, combat
    -- end, ENCOUNTER_END). Two records for the same bossKey inside 5s are
    -- the same kill and the first one in wins.
    -- The mesh merge in Mesh_Proto uses a different rule entirely
    -- (timestamp plus 5s-bucketed duration), so a fight can be deduped by
    -- one and not the other.
    local DEDUP_WINDOW = 5.0
    -- No real boss kill runs past 15 minutes; a longer "kill" is a fight
    -- that never closed properly (the same ceiling a typed-in kill has).
    local MAX_KILL_SECONDS = 900

    -- Puts a kill into a bucket at its place by time, newest first, so the
    -- order the predictions weigh by recency always matches when the kills
    -- happened. Equal times go in front, like a brand-new kill.
    function RC:InsertKillByTime(list, fightData)
        if type(list) ~= "table" then return end
        local ts = fightData.timestamp or 0
        local at = #list + 1
        for i = 1, #list do
            if (list[i].timestamp or 0) <= ts then at = i break end
        end
        table.insert(list, at, fightData)
        if self.TTKHistoryChanged then self:TTKHistoryChanged() end
    end

    -- Sole write path for automatically recorded kills; manual entries in
    -- AddManualKillTime insert directly and skip this dedup.
    function RC:RecordFightKill(bossKey, fightData, source)
        local calc = self.executeCalculator
        if not calc or not calc.fightHistory then return false end
        if not bossKey then return false end
        if fightData.totalFightTime and fightData.totalFightTime > MAX_KILL_SECONDS then
            self:DebugPrint(string.format("Kill of %.0fs on %s rejected - longer than any real kill (source '%s')",
                fightData.totalFightTime, tostring(bossKey), tostring(source)), "execute")
            return false
        end

        if not calc.fightHistory.data[bossKey] then
            calc.fightHistory.data[bossKey] = {}
        end

        local nowMono = GetTime()
        local last = calc._lastKillStamp
        if last and last.bossKey == bossKey and (nowMono - last.time) < DEDUP_WINDOW then
            self:DebugPrint(string.format(
                RCL["Dedup: rejected duplicate %s kill from '%s' (%.2fs after primary)"],
                bossKey, source or "?", nowMono - last.time), "execute")
            return false
        end

        if fightData.class == nil then fightData.class = self:PlayerClassToken() end
        table.insert(calc.fightHistory.data[bossKey], 1, fightData)
        if self.TTKHistoryChanged then self:TTKHistoryChanged() end
        calc._lastKillStamp = { bossKey = bossKey, time = nowMono }
        self:TrimFightHistory(bossKey)
        return true
    end

    -- Systems/Trigger/TE_Reminders.lua monkey-patches this at load time,
    -- wrapping the original and calling it first. Keep the signature
    -- stable and always fall through to the currentFight reset at the end.
    function RC:EndFightTracking(targetData, raidName, encounterName)
        local calc = self.executeCalculator
        local fight = calc.currentFight

        if not fight.started then return end

        if calc.staleCleanupTimer then
            calc.staleCleanupTimer:Cancel()
            calc.staleCleanupTimer = nil
        end

        local now = GetTime()

        -- A sample is only accepted on a confirmed kill, established in
        -- three descending tiers: GUID match on the reported corpse, a
        -- dead target with a matching name, or a dead name match in the
        -- 40-unit raid scan. A wipe records nothing at all, and neither
        -- does a forced close (noRecord: a wipe, a stale fight, or an
        -- ENCOUNTER_END kill that was already saved).
        local bossKilled = false
        local noRecord = fight.noRecord

        local function isBossName(name)
            if not name then return false end
            if name == fight.encounterName or name == fight.primaryBoss.name then
                return true
            end
            local cfg = self.encounterAddPhases and self.encounterAddPhases[fight.encounterName]
            if cfg and cfg.aliases and cfg.aliasesAreEncounter then
                for _, alias in ipairs(cfg.aliases) do
                    if alias == name then return true end
                end
            end
            return false
        end

        if noRecord then
            self:DebugPrint("EndFightTracking: forced close - nothing recorded", "execute")
        elseif targetData and targetData.guid then
            if targetData.guid == fight.primaryBoss.guid or isBossName(targetData.name) then
                bossKilled = true
                self:DebugPrint("Boss death confirmed via UNIT_DIED: " .. (targetData.name or "Unknown"), "execute")
            end
        end

        if not bossKilled and not noRecord and UnitExists("target") then
            local targetName = UnitName("target")
            if isBossName(targetName) and UnitIsDead("target") then
                bossKilled = true
                self:DebugPrint("Boss death confirmed via target check: " .. targetName, "execute")
            end
        end

        if not bossKilled and not noRecord then
            for i = 1, 40 do
                local unit = "raid" .. i .. "target"
                if UnitExists(unit) then
                    local name = UnitName(unit)
                    if isBossName(name) then
                        if UnitIsDead(unit) then
                            bossKilled = true
                            self:DebugPrint("Boss death detected via raid scan: " .. name, "execute")
                        end
                        break
                    end
                end
            end
        end

        -- A multi-boss encounter (Four Horsemen) is only a kill once every
        -- boss is dead. One corpse is not enough: the usual wipe is a
        -- horseman down, the raid dead, and that corpse still targeted.
        -- ENCOUNTER_END's success flag records the real kill on its own.
        if bossKilled and self.TTKMultiBossConfig then
            local mcfg = self:TTKMultiBossConfig(fight)
            if mcfg then
                local units, deadNames, alive = fight.encUnits or {}, {}, false
                for _, e in pairs(units) do
                    if (e.hp or 0) > 0 then alive = true else deadNames[e.name] = true end
                end
                local n = 0
                for _ in pairs(deadNames) do n = n + 1 end
                if alive or n < #mcfg.aliases then
                    bossKilled = false
                    self:DebugPrint("EndFightTracking: not every boss of " .. tostring(fight.historyName) .. " is known dead - not a kill", "execute")
                end
            end
        end

        if fight.bossEngaged and bossKilled and calc.collectData then
            local totalFightTime = now - fight.bossEngageTime

            local safeRaidName = raidName or "Unknown"
            -- Fold an alias kill (Lady Blaumeux) onto the canonical
            -- encounter (Four Horsemen) before keying, so all four deaths
            -- accumulate in one bucket - the one name predictions read.
            local safeEncounterName = self:TTKBossName(safeRaidName, fight.historyName or encounterName or "Unknown")
            local safeProfile = fight.profileName or self:GetActiveProfileNameForRaid(safeRaidName)

            local fightData = {
                timestamp = time(),
                encounterName = safeEncounterName,
                raidName = safeRaidName,
                profileName = safeProfile,
                totalFightTime = totalFightTime,
                executeStartHP = fight.executeStartHP,
                maxHP = fight.maxHP,
                isMultiCombat = fight.isMultiCombatEncounter,
                isTestFight = fight.isTestFight,
                hasSayge = fight.hasSayge or self:HasSaygeBuff(),
            }

            self:DebugPrint("=== FIGHT COMPLETE ===", "execute")
            self:DebugPrint(string.format(RCL["Total Fight Time: %.1fs"], totalFightTime), "execute")
            if fight.enterExecuteTime > 0 then
                local executeTime = now - fight.enterExecuteTime
                self:DebugPrint(string.format(RCL["Execute Phase: %.1fs"], executeTime), "execute")
            end

            local bossKey = self:MakeBossKey(safeRaidName, safeEncounterName, safeProfile)

            local _dc = calc.dataCollection
            local _excKey = safeRaidName .. "_" .. safeEncounterName
            if _dc and _dc.disabledBosses and _dc.disabledBosses[_excKey] then
                self:DebugPrint("EndFightTracking: " .. safeEncounterName .. " excluded from data collection — skipping save", "execute")
            else
                self:RecordFightKill(bossKey, fightData, "EndFightTracking/normal")

                local count = bossKey and calc.fightHistory.data[bossKey] and #calc.fightHistory.data[bossKey] or 0
                self:DebugPrint(string.format(RCL["Saved (Total %s kills: %d)"], safeEncounterName, count), "execute")

                if self:IsDebugEnabled("execute") then
                    local pred, conf = self:PredictTTK(safeRaidName, safeEncounterName, fight.hasSayge, safeProfile)
                    if pred then
                        self:DebugPrint(string.format(RCL["Next Kill Prediction: %.1fs (%.0f%% confidence)"],
                            pred, conf * 100), "execute")
                    end
                end

                self:SaveExecuteSettings()
            end
        -- Boss died but was never marked engaged: an add-phase encounter
        -- where no detector caught the transition. Record the whole
        -- combat duration, which includes the adds, but flag
        -- isNeverEngaged so PredictTTK discards the sample.
        -- Under 10s this is far more likely a misidentified trash pull
        -- than a real kill, so it is dropped entirely.
        elseif not fight.bossEngaged and bossKilled and calc.collectData then
            local combatDuration = now - fight.startTime

            if combatDuration >= 10 then
                local safeRaidName = raidName or "Unknown"
                local safeEncounterName = self:TTKBossName(safeRaidName, fight.historyName or encounterName or "Unknown")
                local safeProfile = fight.profileName or self:GetActiveProfileNameForRaid(safeRaidName)

                self:DebugPrint("=== FIGHT COMPLETE (Never Engaged Fallback) ===", "execute")
                self:DebugPrint(string.format(RCL["Boss: %s"], safeEncounterName), "execute")
                self:DebugPrint(string.format(RCL["Combat Duration: %.1fs (includes add phase)"], combatDuration), "execute")

                local fightData = {
                    timestamp = time(),
                    encounterName = safeEncounterName,
                    raidName = safeRaidName,
                    profileName = safeProfile,
                    totalFightTime = combatDuration,
                    executeStartHP = 0,
                    maxHP = fight.maxHP,
                    isMultiCombat = fight.isMultiCombatEncounter,
                    isTestFight = fight.isTestFight,
                    isNeverEngaged = true,
                    hasSayge = fight.hasSayge or self:HasSaygeBuff(),
                }

                local bossKey = self:MakeBossKey(safeRaidName, safeEncounterName, safeProfile)

                local _dc2 = calc.dataCollection
                local _excKey2 = safeRaidName .. "_" .. safeEncounterName
                if _dc2 and _dc2.disabledBosses and _dc2.disabledBosses[_excKey2] then
                    self:DebugPrint("EndFightTracking/neverEngaged: " .. safeEncounterName .. " excluded — skipping save", "execute")
                else
                    self:RecordFightKill(bossKey, fightData, "EndFightTracking/neverEngaged")

                    local count = calc.fightHistory.data[bossKey] and #calc.fightHistory.data[bossKey] or 0
                    self:DebugPrint(string.format(RCL["Saved (Total %s kills: %d)"], safeEncounterName, count), "execute")

                    self:SaveExecuteSettings()
                end
            else
                self:DebugPrint("Fight too short to save (< 10s)", "execute")
            end
        elseif not noRecord then
            self:DebugPrint("Fight ended without boss kill - not saving data", "execute")
        end

        if self.ResumeTrinketSwapAfterBoss then
            self:ResumeTrinketSwapAfterBoss()
        end

        -- The closed fight's clock, kept a while: when the player dies the
        -- fight closes here at combat end, and the raid's kill comes in
        -- afterwards on ENCOUNTER_END with nothing left to time it from.
        if not fight.isTestFight then
            calc.lastClosedFight = {
                historyName = fight.historyName, encounterName = fight.encounterName,
                raidName = fight.raidName, profileName = fight.profileName,
                bossEngaged = fight.bossEngaged, bossEngageTime = fight.bossEngageTime,
                encounterStartTime = fight.encounterStartTime, startTime = fight.startTime,
                hasSayge = fight.hasSayge, closedAt = now,
            }
        end

        calc.currentFight = {
            started = false,
            bossEngaged = false,
            encounterName = nil,
            raidName = nil,
            targetGUID = nil,
            targetName = nil,
            primaryBoss = { name = nil, guid = nil, isActive = false, lastHP = 0, lastMaxHP = 0, lastUpdate = 0, maxHP = 0 },
            startTime = nil,
            bossEngageTime = nil,
            encounterStartTime = nil,
            enterExecuteTime = 0,
            maxHP = 0,
            executeStartHP = 0,
            addPhasesBeforeBoss = false,
            isMultiCombatEncounter = false,
            isTestFight = false,
            hasSayge = false,
        }
    end

    -- One-shot per fight: enterExecuteTime > 0 latches it, so a boss that
    -- heals back above the threshold does not re-arm. Driven by the 0.5s
    -- combat ticker, so execute entry is caught within half a second and
    -- the stamp anchors tier 1 of GetClassicTTKPrediction.
    function RC:CheckExecutePhase()
        local calc = self.executeCalculator
        local fight = calc.currentFight

        if not fight.started or not fight.bossEngaged or fight.enterExecuteTime > 0 then
            return
        end

        -- the encounter's health: every boss summed on a multi-boss fight
        local hpPct, complete = self:GetEncounterHP()
        if not hpPct or not complete then return end

        if hpPct <= calc.executeThreshold then
            fight.enterExecuteTime = GetTime()
            fight.executeStartHP = hpPct

            self:DebugPrint(">>> EXECUTE PHASE <<<", "execute")
            self:DebugPrint(string.format("HP: %.1f%%", hpPct), "execute")

            if self:IsDebugEnabled("execute") then
                local remaining, conf = self:GetCurrentTTKPrediction()
                if remaining and remaining > 0 then
                    self:DebugPrint(string.format(RCL["Predicted Remaining: %.1fs (%.0f%%)"],
                        remaining, conf * 100), "execute")
                end
            end
        end
    end

    -- Clears both key shapes: a boss can have history under the
    -- profile-scoped key and under the pre-profile legacy key.
    function RC:ClearBossHistory(raidName, bossName)
        if not raidName or not bossName then return end
        bossName = self:TTKBossName(raidName, bossName)
        local newKey = self:MakeBossKey(raidName, bossName)
        if newKey then self.executeCalculator.fightHistory.data[newKey] = nil end
        local legacyKey = raidName .. "_" .. bossName
        self.executeCalculator.fightHistory.data[legacyKey] = nil
        self:SaveExecuteSettings()
    end

    function RC:ClearAllHistory()
        self.executeCalculator.fightHistory.data = {}
        self:SaveExecuteSettings()
    end

    -- Shared chrome for the fight-edit and bulk-add dialogs below - the
    -- same modal shell as RC.UI:CreateConfirmDialog: a full-screen dim
    -- overlay that swallows clicks behind, a flat ui.windowBackground box
    -- with a 1px black ring, a 30px flat title bar with the 15px gold
    -- title and a chromeless X, a 1px gold rule under it, and the context
    -- line below. Returns the dialog frame (with .titleText/.ctxText/
    -- .overlay set and :Open()/:Close() for the pop animation) plus the
    -- accent color so callers can style extra widgets with it.
    local FLAT = (RC.UI and RC.UI.FLAT) or "Interface\\Buttons\\WHITE8X8"

    local function CreateHistoryDialogChrome(name, width, height)
        local winBg  = (RC.GetColor and RC:GetColor("ui", "windowBackground")) or {r=0.08,g=0.08,b=0.08}
        local hdrBg  = (RC.GetColor and RC:GetColor("ui", "headerBackground")) or {r=0.12,g=0.12,b=0.12}
        local hdrTxt = (RC.GetColor and RC:GetColor("ui", "headerText"))       or {r=1,   g=0.82,b=0   }
        local accent = (RC.GetColor and RC:GetColor("ui", "accentGold"))       or {r=0.85,g=0.65,b=0.25}
        local border = (RC.GetColor and RC:GetColor("ui", "borderNormal"))     or {r=0,   g=0,   b=0   }
        local ctxCol = (RC.GetColor and RC:GetColor("text", "gray"))           or {r=0.6, g=0.6, b=0.6 }

        local dialog = CreateFrame("Frame", name, UIParent, "BackdropTemplate")
        dialog:SetSize(width, height)
        dialog:SetPoint("TOP", UIParent, "TOP", 0, -180)
        dialog:SetFrameStrata("DIALOG")
        dialog:SetFrameLevel(100)
        dialog:SetToplevel(true)
        dialog:EnableMouse(true)
        dialog:SetMovable(true)
        dialog:RegisterForDrag("LeftButton")
        dialog:SetScript("OnDragStart", function(s) s:StartMoving() end)
        dialog:SetScript("OnDragStop",  function(s) s:StopMovingOrSizing() end)
        dialog:SetScript("OnMouseDown", function(s) s:Raise() end)

        -- Modal dim: structural black at 0.45 (not a theme colour), a
        -- child of the dialog so it shows/hides and fades with it, one
        -- frame level below so the dialog itself draws on top.
        local overlay = CreateFrame("Frame", nil, dialog)
        overlay:SetFrameStrata("DIALOG")
        overlay:SetFrameLevel(99)
        overlay:SetPoint("TOPLEFT",     UIParent, "TOPLEFT",     0, 0)
        overlay:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", 0, 0)
        overlay:EnableMouse(true)
        local dim = overlay:CreateTexture(nil, "BACKGROUND")
        dim:SetAllPoints()
        dim:SetTexture(FLAT)
        dim:SetVertexColor(0, 0, 0, 0.45)
        dialog.overlay = overlay

        dialog:SetBackdrop({
            bgFile   = FLAT,
            edgeFile = FLAT,
            edgeSize = 1,
        })
        dialog:SetBackdropColor(winBg.r, winBg.g, winBg.b, 0.97)
        dialog:SetBackdropBorderColor(border.r, border.g, border.b, border.a or 1)

        local titleBar = CreateFrame("Frame", nil, dialog)
        titleBar:SetHeight(30)
        titleBar:SetPoint("TOPLEFT",  dialog, "TOPLEFT",  1, -1)
        titleBar:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -1, -1)
        local titleFill = titleBar:CreateTexture(nil, "BACKGROUND")
        titleFill:SetAllPoints()
        titleFill:SetTexture(FLAT)
        titleFill:SetVertexColor(hdrBg.r, hdrBg.g, hdrBg.b, hdrBg.a or 1)
        titleBar.bg = titleFill
        dialog.titleBar = titleBar

        local titleIcon = RC.UI:AddTitleIcon(titleBar, 16, 8)

        local titleText = RC:CreateFontString(titleBar, "OVERLAY", nil, 15, "OUTLINE")
        titleText:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
        titleText:SetTextColor(hdrTxt.r, hdrTxt.g, hdrTxt.b, 1)
        dialog.titleText = titleText

        if RC.UI and RC.UI.CreateXCloseButton then
            local x = RC.UI:CreateXCloseButton(titleBar, 22, function() dialog:Close() end)
            x:SetPoint("RIGHT", titleBar, "RIGHT", -5, 0)
            dialog.closeBtn = x
        end

        local accentLine = titleBar:CreateTexture(nil, "ARTWORK")
        accentLine:SetPoint("BOTTOMLEFT",  titleBar, "BOTTOMLEFT",  0, 0)
        accentLine:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
        accentLine:SetHeight(1)
        accentLine:SetTexture(FLAT)
        accentLine:SetVertexColor(accent.r, accent.g, accent.b, 0.6)
        dialog.accentLine = accentLine
        if RC.UI.ApplyHeaderArt then
            accentLine:Hide()
            RC.UI:ApplyHeaderArt(titleBar, { stepX = 160 })
        end

        local ctx = RC:CreateFontString(dialog, "OVERLAY", nil, 11, "OUTLINE")
        ctx:SetPoint("TOPLEFT",  dialog, "TOPLEFT",  14, -40)
        ctx:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -14, -40)
        ctx:SetJustifyH("LEFT")
        ctx:SetWordWrap(false)
        ctx:SetHeight(12)
        ctx:SetTextColor(ctxCol.r, ctxCol.g, ctxCol.b, 1)
        dialog.ctxText = ctx

        -- Pop in/out like the framework dialogs; ESC (UISpecialFrames)
        -- still plain-hides, which is fine for a cancel.
        function dialog:Open()
            if RC.UI and RC.UI.PopIn then
                RC.UI:PopIn(self, 0.12)
            else
                self:Show()
            end
            self:Raise()
        end
        function dialog:Close()
            if RC.UI and RC.UI.PopOut then
                RC.UI:PopOut(self, 0.1)
            else
                self:Hide()
            end
        end

        return dialog, accent
    end

    -- Bottom-right button row shared by both dialogs: Cancel, then the
    -- primary action wearing the active look, 10px apart, 110x22.
    local function PlaceHistoryDialogButtons(dialog, primaryBtn, cancelBtn)
        primaryBtn:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -14, 12)
        cancelBtn:SetPoint("RIGHT", primaryBtn, "LEFT", -10, 0)
        if primaryBtn.SetActive then primaryBtn:SetActive(true) end
        cancelBtn:SetScript("OnClick", function() dialog:Close() end)
    end

    -- The raid profile a history key files its kills under: "" for the
    -- pre-profile "Raid_Boss" shape, nil when the key cannot be read. A
    -- profile name with "_" in it is matched against the raid's real
    -- profiles first, longest first.
    local function KeyProfileOf(key)
        if type(key) ~= "string" then return nil end
        local rn, rest = key:match("^([^|]+)|(.+)$")
        if not rest then
            return key:find("_", 1, true) and "" or nil
        end
        local st = RC.db and RC.db.raidProfiles and RC.db.raidProfiles[rn]
        if type(st) == "table" and type(st.profiles) == "table" then
            local best
            for name in pairs(st.profiles) do
                if type(name) == "string" and #rest > #name + 1 and rest:sub(1, #name + 1) == name .. "_" then
                    if not best or #name > #best then best = name end
                end
            end
            if best then return best end
        end
        return rest:match("^(.-)_")
    end
    RC.TTKKeyProfile = KeyProfileOf

    function RC:ShowFightEditDialog(fightEntry, currentBossKey, onDone)
        if not fightEntry then return end

        local raidName = fightEntry.raidName or "Unknown"
        local bossName = fightEntry.encounterName or "Unknown"
        -- The profile is the bucket's, not the active one: a kill with no
        -- name stamped sits under whatever key it was filed under, and
        -- stamping the active profile on it would get it thrown out as
        -- misfiled on the next reload.
        local keyProfile = KeyProfileOf(currentBossKey)
        local currentProfile = ((keyProfile and keyProfile ~= "") and keyProfile)
                               or fightEntry.profileName
                               or self:GetActiveProfileNameForRaid(raidName)
                               or "Default"

        local profileChoices = {}
        if self.GetRaidProfileStructure then
            local structure = self:GetRaidProfileStructure(raidName)
            if structure and structure.profiles then
                for pname in pairs(structure.profiles) do
                    table.insert(profileChoices, pname)
                end
                table.sort(profileChoices)
            end
        end
        if #profileChoices == 0 then
            table.insert(profileChoices, currentProfile)
        end

        local dialog = RC._fightEditDialog

        if not dialog then
            dialog = CreateHistoryDialogChrome("WR_FightEditDialog", 380, 262)

            local timeLbl = RC:CreateFontString(dialog, "OVERLAY", nil, 11, "OUTLINE")
            timeLbl:SetPoint("TOPLEFT", dialog, "TOPLEFT", 14, -68)
            timeLbl:SetText(RCL["Fight time (mm:ss):"])
            local lblCol = (RC.GetColor and RC:GetColor("text", "normal")) or {r=0.9,g=0.9,b=0.9}
            timeLbl:SetTextColor(lblCol.r, lblCol.g, lblCol.b, 1)

            -- Flat 22px edit box with the framework's gold focus ring.
            local timeBox = self.UI:CreateStyledEditBox(dialog, {
                width      = 96,
                height     = 22,
                font       = 12,
                maxLetters = 10,
            })
            timeBox:SetPoint("LEFT", timeLbl, "RIGHT", 12, 0)
            local eb = timeBox.editBox
            eb:SetJustifyH("CENTER")
            dialog.timeBox = eb

            local profLbl = RC:CreateFontString(dialog, "OVERLAY", nil, 11, "OUTLINE")
            profLbl:SetPoint("TOPLEFT", dialog, "TOPLEFT", 14, -100)
            profLbl:SetText(RCL["Raid profile:"])
            profLbl:SetTextColor(lblCol.r, lblCol.g, lblCol.b, 1)

            if self.UI and self.UI.CreateScrollableDropdown then
                local dd = self.UI:CreateScrollableDropdown(dialog, 180, "", 8)
                dd:SetPoint("LEFT", profLbl, "RIGHT", 12, 0)
                dialog.profDD = dd
            end

            local clsLbl = RC:CreateFontString(dialog, "OVERLAY", nil, 11, "OUTLINE")
            clsLbl:SetPoint("TOPLEFT", dialog, "TOPLEFT", 14, -132)
            clsLbl:SetText(RCL["Played as:"])
            clsLbl:SetTextColor(lblCol.r, lblCol.g, lblCol.b, 1)

            if self.UI and self.UI.CreateScrollableDropdown then
                local dd = self.UI:CreateScrollableDropdown(dialog, 150, "", 10)
                -- in the same column as the profile dropdown above it
                if dialog.profDD then
                    dd:SetPoint("TOPLEFT", dialog.profDD, "BOTTOMLEFT", 0, -8)
                else
                    dd:SetPoint("LEFT", clsLbl, "RIGHT", 12, 0)
                end
                dialog.classDD = dd
                local ico = dialog:CreateTexture(nil, "ARTWORK")
                ico:SetSize(16, 16)
                ico:SetPoint("LEFT", dd, "RIGHT", 6, 0)
                dialog.classIco = ico
            end

            if self.UI and self.UI.CreateCheckbox then
                local saygeCB = self.UI:CreateCheckbox(dialog, RCL["Had Darkmoon Faire buff (Sayge)"], false)
                saygeCB:ClearAllPoints()
                saygeCB:SetPoint("TOPLEFT", dialog, "TOPLEFT", 14, -164)
                dialog.saygeCB = saygeCB

                local saygeIco = dialog:CreateTexture(nil, "ARTWORK")
                saygeIco:SetSize(14, 14)
                saygeIco:SetPoint("LEFT", saygeCB.Text, "RIGHT", 6, 0)
                saygeIco:SetTexture("Interface\\Icons\\inv_misc_orb_02")
                saygeIco:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                local hitW = ((saygeCB.Text and saygeCB.Text.GetStringWidth and saygeCB.Text:GetStringWidth()) or 200) + 28
                saygeCB:SetHitRectInsets(0, -hitW, 0, 0)
            end

            dialog.saveBtn   = self.UI:CreateStyledButton(dialog, RCL["Save"],   110, 22)
            dialog.cancelBtn = self.UI:CreateStyledButton(dialog, RCL["Cancel"], 110, 22)
            PlaceHistoryDialogButtons(dialog, dialog.saveBtn, dialog.cancelBtn)

            if RC.UI and RC.UI.AttachResizeGrip then
                RC.UI:AttachResizeGrip(dialog, { minW = 340, minH = 248, maxW = 640, maxH = 412 })
            end
            if RC.UI and RC.UI.RegisterEscapeClose then
                RC.UI:RegisterEscapeClose("WR_FightEditDialog")
            end

            RC._fightEditDialog = dialog
        end

        dialog.titleText:SetText(RCL["Edit Fight - "] .. bossName)
        dialog.ctxText:SetText(raidName .. RCL["  -  currently saved under profile: "] .. currentProfile)

        local cs = fightEntry.totalFightTime or 0
        dialog.timeBox:SetText(RC:FormatTime(cs))

        if dialog.saygeCB then
            dialog.saygeCB:SetChecked(fightEntry.hasSayge and true or false)
        end

        local selectedProfile = currentProfile

        local selectedClass = self:FightClass(fightEntry) or ""
        if dialog.classDD and dialog.classDD.SetItems then
            local function ShowClass(value)
                local token = (value ~= "") and value or nil
                if self.UI and self.UI.SetButtonText then
                    self.UI:SetButtonText(dialog.classDD, self:ClassLabelColored(token))
                elseif dialog.classDD.text and dialog.classDD.text.SetText then
                    dialog.classDD.text:SetText(self:ClassLabelColored(token))
                end
                self:PaintClassIcon(dialog.classIco, token)
            end
            dialog.classDD:SetItems(self:ClassDropdownItems(), function(value)
                selectedClass = value or ""
                ShowClass(selectedClass)
            end)
            ShowClass(selectedClass)
        end

        if dialog.profDD and dialog.profDD.SetItems then
            local items = {}
            for _, pname in ipairs(profileChoices) do
                table.insert(items, { text = pname, value = pname })
            end
            dialog.profDD:SetItems(items, function(value)
                selectedProfile = value
            end)
            if self.UI and self.UI.SetButtonText then
                self.UI:SetButtonText(dialog.profDD, currentProfile)
            elseif dialog.profDD.text and dialog.profDD.text.SetText then
                dialog.profDD.text:SetText(currentProfile)
            end
        end

        local function DoSave()
            local raw = dialog.timeBox:GetText() or ""
            raw = raw:gsub("^%s+",""):gsub("%s+$","")
            local newSecs
            local mm, ss = raw:match("^(%d+):(%d+)$")
            if mm and ss then
                newSecs = tonumber(mm) * 60 + tonumber(ss)
            else
                local n = tonumber(raw)
                if n then newSecs = n end
            end
            -- 1800s ceiling here, against the 900s used by
            -- AddManualKillTime and the bulk parser.
            if not newSecs or newSecs <= 0 or newSecs > 1800 then
                RC:Print(RCL["|cffff0000Invalid fight time. Use mm:ss (e.g. 2:45) or seconds (e.g. 165).|r"])
                return
            end

            fightEntry.totalFightTime = newSecs

            if dialog.saygeCB then
                fightEntry.hasSayge = dialog.saygeCB:GetChecked() and true or false
            end

            if dialog.classDD then
                fightEntry.class = (selectedClass ~= "") and selectedClass or nil
            end

            local stampTarget = selectedProfile
            if not stampTarget or stampTarget == "" then
                stampTarget = currentProfile
            end
            -- a kill in the pre-profile bucket keeps no name unless it moves
            if keyProfile ~= "" or stampTarget ~= currentProfile then
                fightEntry.profileName = stampTarget
            end

            -- Reassigning the profile moves the entry between buckets by
            -- identity, not by copy, and drops the source bucket if it
            -- empties. Callers hold a reference, hence the identity scan.
            if selectedProfile and selectedProfile ~= "" and selectedProfile ~= currentProfile then
                local calc = RC.executeCalculator
                if calc and calc.fightHistory and calc.fightHistory.data and currentBossKey then
                    local oldList = calc.fightHistory.data[currentBossKey]
                    if oldList then
                        for i = #oldList, 1, -1 do
                            if oldList[i] == fightEntry then
                                table.remove(oldList, i)
                                break
                            end
                        end
                        if #oldList == 0 then calc.fightHistory.data[currentBossKey] = nil end
                    end
                    local newKey = RC:MakeBossKey(raidName, bossName, selectedProfile)
                    if newKey then
                        if not calc.fightHistory.data[newKey] then
                            calc.fightHistory.data[newKey] = {}
                        end
                        RC:InsertKillByTime(calc.fightHistory.data[newKey], fightEntry)
                    end
                end
            end

            if RC.SaveExecuteSettings then RC:SaveExecuteSettings() end
            dialog:Close()
            if onDone then onDone() end
        end

        dialog.saveBtn:SetScript("OnClick", DoSave)
        dialog.timeBox:SetScript("OnEnterPressed",  function() DoSave() end)
        dialog.timeBox:SetScript("OnEscapePressed", function(s) s:ClearFocus(); dialog:Close() end)

        dialog:Open()
        dialog.timeBox:SetFocus()
        dialog.timeBox:HighlightText()
    end

    -- Accepts mm:ss or bare seconds, separated by whitespace, commas or
    -- semicolons. Same 5-900s bound as AddManualKillTime; anything else
    -- is counted as rejected rather than clamped.
    local function ParseBulkKillTimes(text)
        local times, rejected = {}, 0
        if type(text) ~= "string" then return times, rejected end
        for token in text:gmatch("[^%s,;]+") do
            local secs
            local mm, ss = token:match("^(%d+):(%d%d?)$")
            if mm then
                secs = tonumber(mm) * 60 + tonumber(ss)
            elseif token:match("^%d+$") then
                secs = tonumber(token)
            end
            if secs and secs >= 5 and secs <= 900 then
                times[#times + 1] = secs
            else
                rejected = rejected + 1
            end
        end
        return times, rejected
    end

    local function FormatMMSS(secs)
        return RC:FormatTime(secs)
    end

    -- One boss per line, either "Name: times" or "Name times" resolved by
    -- longest-prefix match against raidData[raid].bosses. A name that is
    -- not an exact match falls back to substring search and is only
    -- accepted when exactly one boss matches.
    local function ParseRaidBulkLines(text, raidName)
        local perBoss, invalid, total = {}, 0, 0
        if type(text) ~= "string" then return perBoss, invalid, total end
        local bossList = (RC.raidData and RC.raidData[raidName] and RC.raidData[raidName].bosses) or {}

        for line in text:gmatch("[^\r\n]+") do
            if line:match("%S") then
                local namePart, timesPart = line:match("^%s*(.-)%s*:%s*(.+)$")
                if not namePart then
                    local lower = line:lower()
                    local best, bestLen
                    for _, bn in ipairs(bossList) do
                        local bl = bn:lower()
                        if lower:sub(1, #bl) == bl and (not bestLen or #bl > bestLen) then
                            best = bn
                            bestLen = #bl
                        end
                    end
                    if best then
                        namePart  = best
                        timesPart = line:sub(bestLen + 1)
                    end
                end

                local canon
                if namePart and namePart ~= "" then
                    local nl = namePart:lower()
                    for _, bn in ipairs(bossList) do
                        if bn:lower() == nl then
                            canon = bn
                            break
                        end
                    end
                    if not canon then
                        local hit, hits = nil, 0
                        for _, bn in ipairs(bossList) do
                            if bn:lower():find(nl, 1, true) then
                                hits = hits + 1
                                hit = bn
                            end
                        end
                        if hits == 1 then canon = hit end
                    end
                end

                local times = (canon and timesPart) and ParseBulkKillTimes(timesPart) or nil
                if canon and times and #times > 0 then
                    perBoss[canon] = perBoss[canon] or {}
                    for _, t in ipairs(times) do
                        perBoss[canon][#perBoss[canon] + 1] = t
                        total = total + 1
                    end
                else
                    invalid = invalid + 1
                end
            end
        end
        return perBoss, invalid, total
    end

    function RC:ShowBulkKillDialog(raidName, bossName, onDone, initialProfile)
        if not raidName then return end

        local dialog = RC._bulkKillDialog

        if not dialog then
            dialog = CreateHistoryDialogChrome("WR_BulkKillDialog", 400, 366)
            if RC.UI and RC.UI.AttachResizeGrip then
                RC.UI:AttachResizeGrip(dialog, { minW = 340, minH = 336, maxW = 720, maxH = 590 })
            end

            local hint = RC:CreateFontString(dialog, "OVERLAY", nil, 10, "OUTLINE")
            hint:SetPoint("TOPLEFT",  dialog, "TOPLEFT",  14, -60)
            hint:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -14, -60)
            hint:SetJustifyH("LEFT")
            hint:SetWordWrap(false)
            hint:SetHeight(12)
            local hintC = (RC.GetColor and RC:GetColor("text", "disabled")) or {r=0.5,g=0.5,b=0.5}
            hint:SetTextColor(hintC.r, hintC.g, hintC.b, 1)
            dialog.hintText = hint

            local status = RC:CreateFontString(dialog, "OVERLAY", nil, 10, "OUTLINE")
            dialog.statusText = status

            local function RefreshStatus()
                local inputText = dialog.inputBox and dialog.inputBox:GetText() or ""
                local dc = (RC.GetColor and RC:GetColor("text", "disabled")) or {r=0.5,g=0.5,b=0.5}
                local gc = (RC.GetColor and RC:GetColor("text", "green"))    or {r=0.4,g=0.9,b=0.4}

                if dialog.raidMode then
                    local perBoss, invalid, total = ParseRaidBulkLines(inputText, dialog.curRaid)
                    if total == 0 then
                        status:SetText(invalid > 0
                            and string.format(RCL["No valid lines yet (%d unrecognized)"], invalid)
                            or RCL["No kills entered yet"])
                        status:SetTextColor(dc.r, dc.g, dc.b, 1)
                    else
                        local parts, bosses = {}, 0
                        local bossList = (RC.raidData and RC.raidData[dialog.curRaid] and RC.raidData[dialog.curRaid].bosses) or {}
                        for _, bn in ipairs(bossList) do
                            if perBoss[bn] then
                                bosses = bosses + 1
                                parts[#parts + 1] = bn:match("^(%S+)") .. " " .. #perBoss[bn]
                            end
                        end
                        local msg = string.format(RCL["%d kill%s / %d boss%s ready:  %s"],
                            total, total == 1 and "" or "s",
                            bosses, bosses == 1 and "" or RCL["es"],
                            table.concat(parts, ", "))
                        if invalid > 0 then
                            msg = msg .. string.format(RCL["  (%d line%s ignored)"], invalid, invalid == 1 and "" or "s")
                        end
                        status:SetText(msg)
                        status:SetTextColor(gc.r, gc.g, gc.b, 1)
                    end
                    return
                end

                local times, rejected = ParseBulkKillTimes(inputText)
                if #times == 0 then
                    status:SetText(rejected > 0
                        and string.format(RCL["No valid times (%d invalid)"], rejected)
                        or RCL["No times entered yet"])
                    status:SetTextColor(dc.r, dc.g, dc.b, 1)
                else
                    local sum = 0
                    for _, t in ipairs(times) do sum = sum + t end
                    local msg = string.format(RCL["%d kill%s ready - avg %s"],
                        #times, #times == 1 and "" or "s", FormatMMSS(sum / #times))
                    if rejected > 0 then
                        msg = msg .. string.format(RCL["  (%d invalid ignored)"], rejected)
                    end
                    status:SetText(msg)
                    status:SetTextColor(gc.r, gc.g, gc.b, 1)
                end
            end
            dialog.RefreshStatus = RefreshStatus

            local inputC = self.UI:CreateStyledEditBox(dialog, {
                multiLine     = true,
                scrollable    = true,
                scrollHeight  = 84,
                font          = 11,
                onTextChanged = RefreshStatus,
            })
            inputC:SetPoint("TOPLEFT",  dialog, "TOPLEFT",  14, -82)
            inputC:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -14, -82)
            dialog.inputBox = inputC.editBox

            status:SetPoint("TOPLEFT",  dialog, "TOPLEFT",  14, -184)
            status:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -14, -184)
            status:SetJustifyH("LEFT")

            if self.UI and self.UI.CreateCheckbox then
                local saygeCB = self.UI:CreateCheckbox(dialog, RCL["Kills had Darkmoon Faire buff (Sayge)"], false)
                saygeCB:ClearAllPoints()
                saygeCB:SetPoint("TOPLEFT", dialog, "TOPLEFT", 14, -204)
                dialog.saygeCB = saygeCB

                local saygeIco = dialog:CreateTexture(nil, "ARTWORK")
                saygeIco:SetSize(14, 14)
                saygeIco:SetPoint("LEFT", saygeCB.Text, "RIGHT", 6, 0)
                saygeIco:SetTexture("Interface\\Icons\\inv_misc_orb_02")
                saygeIco:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                local hitW = ((saygeCB.Text and saygeCB.Text.GetStringWidth and saygeCB.Text:GetStringWidth()) or 220) + 28
                saygeCB:SetHitRectInsets(0, -hitW, 0, 0)
            end

            local profLbl = RC:CreateFontString(dialog, "OVERLAY", nil, 11, "OUTLINE")
            profLbl:SetPoint("TOPLEFT", dialog, "TOPLEFT", 14, -232)
            profLbl:SetText(RCL["Save under:"])
            local lblCol = (RC.GetColor and RC:GetColor("text", "normal")) or {r=0.9,g=0.9,b=0.9}
            profLbl:SetTextColor(lblCol.r, lblCol.g, lblCol.b, 1)

            if self.UI and self.UI.CreateScrollableDropdown then
                local dd = self.UI:CreateScrollableDropdown(dialog, 180, "", 8)
                dd:SetPoint("LEFT", profLbl, "RIGHT", 12, 0)
                dialog.profDD = dd
            end

            local clsLbl = RC:CreateFontString(dialog, "OVERLAY", nil, 11, "OUTLINE")
            clsLbl:SetPoint("TOPLEFT", dialog, "TOPLEFT", 14, -262)
            clsLbl:SetText(RCL["Played as:"])
            clsLbl:SetTextColor(lblCol.r, lblCol.g, lblCol.b, 1)

            if self.UI and self.UI.CreateScrollableDropdown then
                local dd = self.UI:CreateScrollableDropdown(dialog, 150, "", 10)
                -- in the same column as the profile dropdown above it
                if dialog.profDD then
                    dd:SetPoint("TOPLEFT", dialog.profDD, "BOTTOMLEFT", 0, -8)
                else
                    dd:SetPoint("LEFT", clsLbl, "RIGHT", 12, 0)
                end
                dialog.classDD = dd
                local ico = dialog:CreateTexture(nil, "ARTWORK")
                ico:SetSize(16, 16)
                ico:SetPoint("LEFT", dd, "RIGHT", 6, 0)
                dialog.classIco = ico
            end

            dialog.addBtn    = self.UI:CreateStyledButton(dialog, RCL["Add Kills"], 110, 22)
            dialog.cancelBtn = self.UI:CreateStyledButton(dialog, RCL["Cancel"],    110, 22)
            PlaceHistoryDialogButtons(dialog, dialog.addBtn, dialog.cancelBtn)

            dialog.addBtn:SetScript("OnClick", function()
                local sayge = dialog.saygeCB and dialog.saygeCB:GetChecked() and true or false
                -- false: the kills go in with no class recorded
                local cls = dialog.selectedClass
                if cls == nil or cls == "" then cls = false end

                if dialog.raidMode then
                    local perBoss, _, total = ParseRaidBulkLines(dialog.inputBox:GetText() or "", dialog.curRaid)
                    if total == 0 then
                        RC:Print(RCL["No valid lines. Use one boss per line, e.g. Patchwerk: 1:32 105"])
                        return
                    end
                    local bossCount = 0
                    -- each kill its own second, the last one typed the newest
                    local base = time()
                    for bossName, times in pairs(perBoss) do
                        bossCount = bossCount + 1
                        for i, secs in ipairs(times) do
                            RC:AddManualKillTime(bossName, secs, dialog.curRaid, true, sayge, dialog.selectedProfile, cls,
                                base - (#times - i))
                        end
                    end
                    RC:Print(string.format(RCL["Added %d kill%s across %d boss%s in %s."],
                        total, total == 1 and "" or "s",
                        bossCount, bossCount == 1 and "" or RCL["es"], dialog.curRaid))
                    dialog:Close()
                    if dialog.onDone then dialog.onDone() end
                    return
                end

                local times = ParseBulkKillTimes(dialog.inputBox:GetText() or "")
                if #times == 0 then
                    RC:Print(RCL["No valid kill times entered. Use mm:ss (e.g. 1:32) or seconds (e.g. 92)."])
                    return
                end
                local base = time()
                for i, secs in ipairs(times) do
                    RC:AddManualKillTime(dialog.curBoss, secs, dialog.curRaid, true, sayge, dialog.selectedProfile, cls,
                        base - (#times - i))
                end
                RC:Print(string.format(RCL["Added %d kill%s for %s."],
                    #times, #times == 1 and "" or "s", dialog.curBoss))
                dialog:Close()
                if dialog.onDone then dialog.onDone() end
            end)

            if RC.UI and RC.UI.RegisterEscapeClose then
                RC.UI:RegisterEscapeClose("WR_BulkKillDialog")
            end

            RC._bulkKillDialog = dialog
        end

        local activeProfile = self:GetActiveProfileNameForRaid(raidName) or "Default"
        local startProfile  = initialProfile
        if not startProfile or startProfile == "" then startProfile = activeProfile end

        dialog.raidMode = (bossName == nil)
        dialog.curRaid = raidName
        dialog.curBoss = bossName
        dialog.onDone  = onDone
        dialog.selectedProfile = startProfile
        if dialog.raidMode then
            dialog.titleText:SetText(RCL["Bulk Add Kills - "] .. raidName)
            dialog.ctxText:SetText(RCL["All bosses - one boss per line"])
            if dialog.hintText then
                dialog.hintText:SetText(RCL["One boss per line:  Patchwerk: 1:32 105"])
            end
        else
            dialog.titleText:SetText(RCL["Bulk Add Kills - "] .. bossName)
            dialog.ctxText:SetText(raidName)
            if dialog.hintText then
                dialog.hintText:SetText(RCL["Paste times as mm:ss or seconds, e.g. 1:32 105 2:03"])
            end
        end
        dialog.inputBox:SetText("")
        if dialog.saygeCB then dialog.saygeCB:SetChecked(false) end
        if dialog.RefreshStatus then dialog.RefreshStatus() end

        -- kills added here are taken as played on this character's class
        -- unless another (or "Not recorded") is picked
        dialog.selectedClass = self:PlayerClassToken() or ""
        if dialog.classDD and dialog.classDD.SetItems then
            local function ShowClass(value)
                local token = (value ~= "") and value or nil
                if self.UI and self.UI.SetButtonText then
                    self.UI:SetButtonText(dialog.classDD, self:ClassLabelColored(token))
                elseif dialog.classDD.text and dialog.classDD.text.SetText then
                    dialog.classDD.text:SetText(self:ClassLabelColored(token))
                end
                self:PaintClassIcon(dialog.classIco, token)
            end
            dialog.classDD:SetItems(self:ClassDropdownItems(), function(value)
                dialog.selectedClass = value or ""
                ShowClass(dialog.selectedClass)
            end)
            ShowClass(dialog.selectedClass)
        end

        if dialog.profDD and dialog.profDD.SetItems then
            local profileChoices = {}
            if self.GetRaidProfileStructure then
                local structure = self:GetRaidProfileStructure(raidName)
                if structure and structure.profiles then
                    for pname in pairs(structure.profiles) do
                        table.insert(profileChoices, pname)
                    end
                    table.sort(profileChoices)
                end
            end
            if #profileChoices == 0 then
                table.insert(profileChoices, startProfile)
            end

            local items = {}
            for _, pname in ipairs(profileChoices) do
                table.insert(items, { text = pname, value = pname })
            end
            dialog.profDD:SetItems(items, function(value)
                dialog.selectedProfile = value
            end)
            if self.UI and self.UI.SetButtonText then
                self.UI:SetButtonText(dialog.profDD, startProfile)
            elseif dialog.profDD.text and dialog.profDD.text.SetText then
                dialog.profDD.text:SetText(startProfile)
            end
        end

        dialog:Open()
        dialog.inputBox:SetFocus()
    end

    --------------------------------------------------------------------
    -- MOVING OR COPYING KILLS BETWEEN RAID PROFILES
    -- A kill is filed under the raid profile that was active when it was
    -- recorded ("Raid|Profile_Boss"), and a prediction only reads the
    -- active profile's own kills - so a new or renamed profile starts
    -- from nothing. GetFightHistoryByProfile and TransferFightHistory
    -- are data only; ShowFightTransferDialog is the Data tab's
    -- "Move / Copy" button.
    --------------------------------------------------------------------

    -- raid -> this character's profile names for it, longest first.
    local function KnownProfileNames()
        local out = {}
        local rp = RC.db and RC.db.raidProfiles
        if type(rp) ~= "table" then return out end
        for raid, st in pairs(rp) do
            if type(st) == "table" and type(st.profiles) == "table" then
                local names = {}
                for name in pairs(st.profiles) do
                    if type(name) == "string" and name ~= "" then names[#names + 1] = name end
                end
                table.sort(names, function(a, b)
                    if #a ~= #b then return #a > #b end
                    return a < b
                end)
                out[raid] = names
            end
        end
        return out
    end

    -- raid, profile, boss of a history key; profile is "" for the
    -- pre-profile "Raid_Boss" shape. `known` (from KnownProfileNames) is
    -- tried first so a profile with "_" in its name is not cut at its
    -- first underscore; anything else splits there like everywhere else.
    local function SplitFightKey(k, known)
        if type(k) ~= "string" then return nil end
        if not k:find("|", 1, true) then
            local rn, bn = k:match("^(.-)_(.+)$")
            if not bn then return nil end
            return rn, "", bn
        end
        local rn, rest = k:match("^([^|]+)|(.+)$")
        if not rest then return nil end
        local names = known and known[rn]
        if names then
            for _, name in ipairs(names) do
                if #rest > #name + 1 and rest:sub(1, #name + 1) == name .. "_" then
                    return rn, name, rest:sub(#name + 2)
                end
            end
        end
        local pn, bn = rest:match("^(.-)_(.+)$")
        if not bn then return nil end
        return rn, pn, bn
    end

    -- Every kill on record, grouped by raid and by the profile it is
    -- filed under:
    --   { [raid] = { [profile] = { fights = n, bosses = { [boss] = n } } } }
    function RC:GetFightHistoryByProfile()
        local out = {}
        local calc = self.executeCalculator
        local data = calc and calc.fightHistory and calc.fightHistory.data
        if type(data) ~= "table" then return out end
        local known = KnownProfileNames()
        for key, bucket in pairs(data) do
            if type(bucket) == "table" and #bucket > 0 then
                local rn, pn, bn = SplitFightKey(key, known)
                if rn and bn then
                    if not out[rn] then out[rn] = {} end
                    local p = out[rn][pn]
                    if not p then
                        p = { fights = 0, bosses = {} }
                        out[rn][pn] = p
                    end
                    p.fights = p.fights + #bucket
                    p.bosses[bn] = (p.bosses[bn] or 0) + #bucket
                end
            end
        end
        return out
    end

    -- Copies (or, with move, moves) the kills filed under fromProfile into
    -- toProfile of the same raid - every boss, or just onlyBoss. A kill the
    -- destination already holds (same timestamp and length, the test the
    -- load-time dedupe uses) is not added twice. Each kill is restamped
    -- with the destination's name, or the load-time cleanup would drop it
    -- as filed under the wrong profile. dryRun counts without changing
    -- anything. Returns kills added, bosses touched, kills already there.
    function RC:TransferFightHistory(raidName, fromProfile, toProfile, onlyBoss, move, dryRun)
        local calc = self.executeCalculator
        local data = calc and calc.fightHistory and calc.fightHistory.data
        if type(data) ~= "table" or not raidName or not fromProfile then return 0, 0, 0 end
        if not toProfile or toProfile == "" or toProfile == fromProfile then return 0, 0, 0 end

        local known = KnownProfileNames()
        local jobs = {}
        for key, bucket in pairs(data) do
            if type(bucket) == "table" and #bucket > 0 then
                local rn, pn, bn = SplitFightKey(key, known)
                if rn == raidName and pn == fromProfile and bn and (not onlyBoss or bn == onlyBoss) then
                    jobs[#jobs + 1] = { src = key, boss = bn }
                end
            end
        end

        local function Mark(f)
            return tostring(f.timestamp or "X") .. "|" ..
                   tostring(math.floor((f.totalFightTime or 0) + 0.5))
        end

        local added, bosses, already = 0, 0, 0
        for _, job in ipairs(jobs) do
            local dstKey = self:MakeBossKey(raidName, job.boss, toProfile)
            local src = data[job.src]
            if dstKey and dstKey ~= job.src and src then
                local dst = data[dstKey]
                local seen = {}
                if type(dst) == "table" then
                    for _, f in ipairs(dst) do seen[Mark(f)] = true end
                end
                local fresh = {}
                for _, f in ipairs(src) do
                    local fp = Mark(f)
                    if seen[fp] then
                        already = already + 1
                    else
                        seen[fp] = true
                        fresh[#fresh + 1] = f
                    end
                end
                if #fresh > 0 or move then bosses = bosses + 1 end
                added = added + #fresh

                if not dryRun then
                    if #fresh > 0 then
                        if type(dst) ~= "table" then
                            dst = {}
                            data[dstKey] = dst
                        end
                        for _, f in ipairs(fresh) do
                            local entry = move and f or self.DeepCopy(f)
                            entry.profileName = toProfile
                            dst[#dst + 1] = entry
                        end
                        -- newest first, like every other writer of a bucket
                        table.sort(dst, function(a, b)
                            local ta, tb = a.timestamp or 0, b.timestamp or 0
                            if ta ~= tb then return ta > tb end
                            return (a.totalFightTime or 0) > (b.totalFightTime or 0)
                        end)
                        if self.TrimFightHistory then self:TrimFightHistory(dstKey) end
                    end
                    if move then data[job.src] = nil end
                end
            end
        end

        if not dryRun and (added > 0 or (move and bosses > 0)) then
            self:SaveExecuteSettings()
        end
        return added, bosses, already
    end

    function RC:ShowFightTransferDialog(raidName, onDone)
        local ALL = "*"
        local dialog = RC._fightTransferDialog

        if not dialog then
            dialog = CreateHistoryDialogChrome("WR_FightTransferDialog", 440, 276)

            local lblCol = (RC.GetColor and RC:GetColor("text", "normal")) or {r=0.9,g=0.9,b=0.9}
            local function Row(key, label, y)
                local lbl = RC:CreateFontString(dialog, "OVERLAY", nil, 11, "OUTLINE")
                lbl:SetPoint("TOPLEFT", dialog, "TOPLEFT", 14, y - 6)
                lbl:SetText(label)
                lbl:SetTextColor(lblCol.r, lblCol.g, lblCol.b, 1)
                local dd = self.UI:CreateScrollableDropdown(dialog, 340, "", 8)
                dd:SetPoint("TOPLEFT", dialog, "TOPLEFT", 86, y)
                dialog[key] = dd
            end
            Row("raidDD", RCL["Raid:"],   -62)
            Row("fromDD", RCL["From:"],   -92)
            Row("toDD",   RCL["To:"],     -122)
            Row("bossDD", RCL["Bosses:"], -152)

            local status = RC:CreateFontString(dialog, "OVERLAY", nil, 10, "OUTLINE")
            status:SetPoint("TOPLEFT",  dialog, "TOPLEFT",  14, -186)
            status:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -14, -186)
            status:SetJustifyH("LEFT")
            status:SetJustifyV("TOP")
            status:SetWordWrap(true)
            -- down to the button row, so a taller window gives it room
            status:SetPoint("BOTTOM", dialog, "BOTTOM", 0, 42)
            dialog.statusText = status

            dialog.copyBtn   = self.UI:CreateStyledButton(dialog, RCL["Copy"],   96, 22)
            dialog.moveBtn   = self.UI:CreateStyledButton(dialog, RCL["Move"],   96, 22)
            dialog.cancelBtn = self.UI:CreateStyledButton(dialog, RCL["Close"],  96, 22)
            dialog.copyBtn:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -14, 12)
            dialog.moveBtn:SetPoint("RIGHT", dialog.copyBtn, "LEFT", -10, 0)
            dialog.cancelBtn:SetPoint("RIGHT", dialog.moveBtn, "LEFT", -10, 0)
            if dialog.copyBtn.SetActive then dialog.copyBtn:SetActive(true) end
            dialog.cancelBtn:SetScript("OnClick", function() dialog:Close() end)

            if RC.UI and RC.UI.AttachResizeGrip then
                RC.UI:AttachResizeGrip(dialog, { minW = 440, minH = 276, maxW = 760, maxH = 460 })
            end
            if RC.UI and RC.UI.RegisterEscapeClose then
                RC.UI:RegisterEscapeClose("WR_FightTransferDialog")
            end

            -- what the four dropdowns currently say
            dialog.sel = {}

            local function ProfileLabel(name)
                if name == "" then return RCL["(no profile)"] end
                return name
            end
            local function Kills(n)
                return string.format(n == 1 and RCL["%d kill"] or RCL["%d kills"], n)
            end

            local function RefreshStatus()
                local sel = dialog.sel
                local dc = (RC.GetColor and RC:GetColor("text", "disabled")) or {r=0.5,g=0.5,b=0.5}
                local gc = (RC.GetColor and RC:GetColor("text", "green"))    or {r=0.4,g=0.9,b=0.4}
                local canCopy, canMove = false, false
                if not sel.raid or not sel.from then
                    status:SetText(RCL["No kills on record to move yet."])
                elseif not sel.to then
                    status:SetText(RCL["This raid has no other profile to move kills into. Create one on the raid's page first."])
                else
                    local boss = (sel.boss ~= ALL) and sel.boss or nil
                    local added, bosses, already = RC:TransferFightHistory(sel.raid, sel.from, sel.to, boss, false, true)
                    if added == 0 then
                        status:SetText(string.format(
                            RCL["Nothing new to copy: %s already has all %s. Move would only clear them out of %s."],
                            ProfileLabel(sel.to), Kills(already), ProfileLabel(sel.from)))
                        canMove = already > 0
                    else
                        local msg = string.format(RCL["%s on %d boss%s will go into %s."],
                            Kills(added), bosses, bosses == 1 and "" or RCL["es"], ProfileLabel(sel.to))
                        if already > 0 then
                            msg = msg .. string.format(RCL["  %s already there, skipped."], Kills(already))
                        end
                        msg = msg .. RCL["  Copy keeps them in both; Move takes them out of "] .. ProfileLabel(sel.from) .. "."
                        status:SetText(msg)
                        canCopy, canMove = true, true
                    end
                end
                local c = canCopy and gc or dc
                status:SetTextColor(c.r, c.g, c.b, 1)
                dialog.canCopy, dialog.canMove = canCopy, canMove
                dialog.copyBtn:SetAlpha(canCopy and 1 or 0.4)
                dialog.moveBtn:SetAlpha(canMove and 1 or 0.4)
            end

            local function Fill(dd, items, value, onPick)
                dd:SetItems(items, onPick)
                local shown = RCL["None"]
                for _, it in ipairs(items) do
                    if it.value == value then shown = it.text end
                end
                dd:SetSelectedValue(value, shown)
            end

            local function FillBosses()
                local sel = dialog.sel
                local entry = sel.raid and sel.from and dialog.byRaid[sel.raid]
                              and dialog.byRaid[sel.raid][sel.from]
                local items = {}
                if entry then
                    items[1] = { text = string.format(RCL["All bosses  (%s)"], Kills(entry.fights)), value = ALL }
                    local names = {}
                    for bn in pairs(entry.bosses) do names[#names + 1] = bn end
                    table.sort(names)
                    for _, bn in ipairs(names) do
                        items[#items + 1] = { text = bn .. "  (" .. entry.bosses[bn] .. ")", value = bn }
                    end
                end
                if not (entry and sel.boss and (sel.boss == ALL or entry.bosses[sel.boss])) then sel.boss = ALL end
                Fill(dialog.bossDD, items, sel.boss, function(v) sel.boss = v; RefreshStatus() end)
            end

            local function FillTo()
                local sel = dialog.sel
                local items, has = {}, {}
                -- only real profiles of this raid: kills filed under a name
                -- that is not a profile are never read by a prediction
                local st = sel.raid and RC.db and RC.db.raidProfiles and RC.db.raidProfiles[sel.raid]
                if type(st) == "table" and type(st.profiles) == "table" then
                    local names = {}
                    for name in pairs(st.profiles) do
                        if type(name) == "string" and name ~= "" and name ~= sel.from then names[#names + 1] = name end
                    end
                    table.sort(names)
                    local raidEntry = dialog.byRaid[sel.raid] or {}
                    for _, name in ipairs(names) do
                        local n = raidEntry[name] and raidEntry[name].fights or 0
                        items[#items + 1] = { text = name .. "  (" .. n .. ")", value = name }
                        has[name] = true
                    end
                    if not (sel.to and has[sel.to]) then
                        sel.to = (st.activeProfile and has[st.activeProfile]) and st.activeProfile
                                 or (items[1] and items[1].value) or nil
                    end
                else
                    sel.to = nil
                end
                if #items == 0 then sel.to = nil end
                Fill(dialog.toDD, items, sel.to, function(v) sel.to = v; RefreshStatus() end)
            end

            local function FillFrom()
                local sel = dialog.sel
                local raidEntry = sel.raid and dialog.byRaid[sel.raid] or {}
                local names = {}
                for name in pairs(raidEntry) do names[#names + 1] = name end
                table.sort(names)
                local items = {}
                for _, name in ipairs(names) do
                    items[#items + 1] = { text = ProfileLabel(name) .. "  (" .. raidEntry[name].fights .. ")", value = name }
                end
                if not (sel.from and raidEntry[sel.from]) then sel.from = names[1] end
                Fill(dialog.fromDD, items, sel.from, function(v)
                    sel.from = v
                    FillTo(); FillBosses(); RefreshStatus()
                end)
            end

            -- re-read the history and repaint all four rows, keeping
            -- whatever is still a valid choice
            function dialog:Reload(wantRaid)
                self.byRaid = RC:GetFightHistoryByProfile()
                local sel = self.sel
                local raids = {}
                for rn in pairs(self.byRaid) do raids[#raids + 1] = rn end
                table.sort(raids)
                local items = {}
                for _, rn in ipairs(raids) do items[#items + 1] = { text = rn, value = rn } end
                if wantRaid and self.byRaid[wantRaid] then sel.raid = wantRaid end
                if not (sel.raid and self.byRaid[sel.raid]) then sel.raid = raids[1] end
                Fill(self.raidDD, items, sel.raid, function(v)
                    sel.raid = v
                    FillFrom(); FillTo(); FillBosses(); RefreshStatus()
                end)
                FillFrom(); FillTo(); FillBosses(); RefreshStatus()
            end

            local function Run(move)
                local sel = dialog.sel
                local can = move and dialog.canMove or (not move and dialog.canCopy)
                if not can or not (sel.raid and sel.from and sel.to) then return end
                local boss = (sel.boss ~= ALL) and sel.boss or nil
                local added, bosses, already = RC:TransferFightHistory(sel.raid, sel.from, sel.to, boss, move, false)
                local msg = string.format(move and RCL["Moved %s on %d boss%s from %s to %s."]
                                                or RCL["Copied %s on %d boss%s from %s to %s."],
                    Kills(added), bosses, bosses == 1 and "" or RCL["es"],
                    ProfileLabel(sel.from), ProfileLabel(sel.to))
                if already > 0 then
                    msg = msg .. string.format(RCL[" %s already there."], Kills(already))
                end
                RC:Print(msg)
                dialog:Reload()
                if dialog.onDone then dialog.onDone() end
            end

            dialog.copyBtn:SetScript("OnClick", function() Run(false) end)
            dialog.moveBtn:SetScript("OnClick", function()
                local sel = dialog.sel
                if not dialog.canMove or not (sel.raid and sel.from and sel.to) then return end
                local what = (sel.boss ~= ALL) and sel.boss or RCL["every boss"]
                RC.UI:CreateConfirmDialog(
                    RCL["Move Kill Data"],
                    string.format(RCL["Move the kills for %s out of %s and into %s?"],
                        what, ProfileLabel(sel.from), ProfileLabel(sel.to)),
                    function() Run(true) end,
                    nil, RCL["Move"], false)
            end)

            RC._fightTransferDialog = dialog
        end

        dialog.onDone = onDone
        dialog.titleText:SetText(RCL["Move or Copy Kill Data"])
        dialog.ctxText:SetText(RCL["Between raid profiles on this character"])
        dialog:Reload(raidName)
        dialog:Open()
    end

    -- Fight-history keys come in two shapes: profile-scoped
    -- "Raid|Profile_Boss" and legacy "Raid_Boss". Returns raid, boss.
    -- Shared by GetAllFightDataSummary and DeduplicateFightHistory.
    local function ParseFightHistoryKey(k)
        if type(k) ~= "string" then return nil, nil end
        if k:find("|", 1, true) then
            local rn, rest = k:match("^([^|]+)|(.+)$")
            if rest then
                -- the raid's real profile names first, so "Crit_Under_Boss"
                -- reads as profile "Crit_Under", boss "Boss"
                local kp = KeyProfileOf(k)
                if kp and kp ~= "" and #rest > #kp + 1 then
                    return rn, rest:sub(#kp + 2)
                end
                local _, bn = rest:match("^(.-)_(.+)$")
                return rn, bn
            end
        else
            return k:match("^(.-)_(.+)$")
        end
        return nil, nil
    end

    function RC:GetAllFightDataSummary()
        local summary = {}

        for bossKey, fights in pairs(self.executeCalculator.fightHistory.data) do
            local raidName, bossName = ParseFightHistoryKey(bossKey)
            if raidName and bossName and #fights > 0 then
                local pred, conf = self:PredictTTK(raidName, bossName)

                table.insert(summary, {
                    raidName = raidName,
                    bossName = bossName,
                    fightCount = #fights,
                    predictedTTK = pred,
                    confidence = conf
                })
            end
        end

        return summary
    end

    -- Called after each kill and after each history edit. The kill history
    -- is handed over as the live table, not copied: a copy of every kill
    -- on every save used to run at the moment of the kill, often still in
    -- combat. Loading copies it back out (LoadExecuteSettings), and the
    -- profile loader already shares it the same way. Every save counts as
    -- a history change, so cached predictions rebuild. The shape written
    -- here is exactly what the mesh reads back as executeSettings.
    function RC:SaveExecuteSettings()
        local charKey = self:GetCharacterKey()
        if not ReadycheckDB or not ReadycheckDB.characters then return end

        if not ReadycheckDB.characters[charKey] then
            ReadycheckDB.characters[charKey] = {}
        end

        if not ReadycheckDB.characters[charKey].executeSettings then
            ReadycheckDB.characters[charKey].executeSettings = {}
        end

        local settings = ReadycheckDB.characters[charKey].executeSettings

        settings.executeThreshold = self.executeCalculator.executeThreshold
        settings.collectData = self.executeCalculator.collectData

        settings.fightHistory = self.executeCalculator.fightHistory.data
        if self.TTKHistoryChanged then self:TTKHistoryChanged() end

        settings.testModeEnabled = self.executeCalculator.testMode.enabled
        settings.classicGlobalMultiplier = self.executeCalculator.classicMultipliers.global
        settings.classicBossMultipliers = self.DeepCopy(self.executeCalculator.classicMultipliers.perBoss)

        settings.ewmaEnabled = self.executeCalculator.ewma.enabled
        settings.ewmaAlpha = self.executeCalculator.ewma.alpha
        settings.mlConfig = self.DeepCopy(self.executeCalculator.mlConfig)

        settings.mode = self.executeCalculator.mode

        if self.executeCalculator.dataCollection then
            settings.dataCollection = self.DeepCopy(self.executeCalculator.dataCollection)
        end

        if self.executeCalculator.uiSettings then
            settings.uiSettings = self.DeepCopy(self.executeCalculator.uiSettings)
        end

        self:DebugPrint("Execute settings saved to character profile", "execute")
    end

    -- Load-time repair, two passes.
    -- Pass 1: inside each bucket, drop fights sharing a fingerprint of
    -- timestamp plus duration rounded to the nearest second.
    -- Pass 2: when the same raid+boss exists under several profile-scoped
    -- keys, drop entries whose own profileName contradicts the key they
    -- sit under - the residue of moving fights between profiles.
    function RC:DeduplicateFightHistory()
        local data = self.executeCalculator and
                     self.executeCalculator.fightHistory and
                     self.executeCalculator.fightHistory.data
        if not data then return end

        local dirty = false

        local function FP(f)
            return tostring(f.timestamp or "X") .. "|" ..
                   tostring(math.floor((f.totalFightTime or 0) + 0.5))
        end

        -- the "Profile_Boss" part of a profile-scoped key, nil for legacy
        local function KeyRest(k)
            if type(k) ~= "string" then return nil end
            return k:match("^[^|]+|(.+)$")
        end

        for k, bucket in pairs(data) do
            local seen = {}
            local kept = {}
            local changed = false
            for _, f in ipairs(bucket) do
                local fp = FP(f)
                if not seen[fp] then
                    seen[fp] = true
                    table.insert(kept, f)
                else
                    changed = true
                    dirty = true
                end
            end
            if changed then data[k] = kept end
        end

        local groups = {}
        for k in pairs(data) do
            local r, b = ParseFightHistoryKey(k)
            if r and b then
                local gk = r .. "\0" .. b
                if not groups[gk] then groups[gk] = {} end
                table.insert(groups[gk], k)
            end
        end

        for _, keys in pairs(groups) do
            if #keys > 1 then
                for _, k in ipairs(keys) do
                    -- a kill is misfiled when the key does not start with its
                    -- own profile name: read that way, a profile with "_" in
                    -- its name is not cut short and its kills dropped
                    local rest = KeyRest(k)
                    if rest then
                        local bucket = data[k]
                        if bucket then
                            local kept = {}
                            local changed = false
                            for _, f in ipairs(bucket) do
                                local fp = f.profileName
                                if fp and fp ~= "" and rest:sub(1, #fp + 1) ~= fp .. "_" then
                                    changed = true
                                    dirty = true
                                else
                                    table.insert(kept, f)
                                end
                            end
                            if changed then data[k] = kept end
                        end
                    end
                end
            end
        end

        if dirty then
            self:DebugPrint("DeduplicateFightHistory: cleaned up duplicate fight entries", "execute")
        end
    end
