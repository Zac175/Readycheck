------------------------------------------------------------------------
-- Readycheck - Smart Macro
-- Rewrites the body of an existing in-game macro from an ordered rule
-- list. RC.db.smartMacros[i] = { id, macroName, enabled, rules,
-- nextRuleId, raidFilter, profileFilter }. Rule = { id, conditions =
-- up to five { type, value } entries ORed together, buildMode
-- "auto"|"manual", buildAction, buildItem, buildConditional, body,
-- itemCheck }. First rule whose conditions match and whose itemCheck is
-- off cooldown wins; evaluation then stops for that macro.
-- The raid / profile restriction lives on the MACRO, not on the rule -
-- rule-level raidScope and profileScope are stripped on load.
-- EditMacro is protected: in combat the new body is parked in
-- SM._pending and flushed on PLAYER_REGEN_ENABLED.
------------------------------------------------------------------------

-- Taint-safe API locals (fallbacks on RC.Compat, built in Core;
-- never write _G - a written Blizzard global taints its readers)
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)

local function InitializeSmartMacro()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializeSmartMacro) return end
    if not RC.db  then C_Timer.After(0.1, InitializeSmartMacro) return end

    RC.SmartMacro = {}
    local SM = RC.SmartMacro

    SM._lastApplied = {}

    -- macroName -> { item, itemId, icon, ruleId, body } for the rule that
    -- won the last Evaluate. Rebuilt from scratch every pass, so a macro
    -- that stops matching drops out rather than going stale. Read-only for
    -- consumers; the Warrior HUD uses it to show what the macro will fire.
    SM._active = {}

    -- Runtime: macroId -> { idx, body } for updates blocked by combat lockdown.
    -- Flushed when PLAYER_REGEN_ENABLED fires (leaving combat).
    SM._pending = {}

    SM._evalDirty = false

    SM._itemCache = {}
    -- Bag contents and cooldowns are cached for 3s. A bag change and
    -- BAG_UPDATE_COOLDOWN only zero the stamp; the rescan itself happens
    -- inside the next Evaluate, never in the event handler.
    SM._itemCacheTime = 0
    SM._ITEM_CACHE_TTL = 3.0
    SM._lastFocusedEB = nil

    -- Shift-clicking an item anywhere in the UI routes through
    -- ChatEdit_InsertLink; this catches it for whichever settings edit box
    -- last had focus and drops the plain item NAME in, since rules match
    -- items by name rather than by link or id.
    hooksecurefunc("ChatEdit_InsertLink", function(link)
        if link and SM._lastFocusedEB then
            local eb = SM._lastFocusedEB
            if eb and eb:IsVisible() then
                local itemId = tonumber(link:match("item:(%d+)"))
                if itemId then
                    local name = GetItemInfo(itemId)
                    if name then
                        eb:SetText(name)
                        local fn = eb:GetScript("OnEditFocusLost")
                        if fn then fn(eb) end
                        eb:ClearFocus()
                        SM._lastFocusedEB = nil
                    end
                end
            end
        end
    end)

    local function RebuildItemCache()
        local now = GetTime()
        if (now - SM._itemCacheTime) < SM._ITEM_CACHE_TTL then return end
        SM._itemCacheTime = now
        local cache = {}
        for bag = 0, 4 do
            local slots = C_Container.GetContainerNumSlots(bag)
            for slot = 1, slots do
                local link = C_Container.GetContainerItemLink(bag, slot)
                if link then
                    local name = link:match("%[(.-)%]")
                    if not name then
                        local id = tonumber(link:match("item:(%d+)"))
                        name = id and GetItemInfo(id)
                    end
                    if name then
                        -- Keys are lowercased and trimmed so a rule written
                        -- with stray spacing or odd casing still matches.
                        -- First stack of an item wins; a start of 0 or nil
                        -- means no cooldown is running.
                        local key = name:lower():match("^%s*(.-)%s*$")
                        if not cache[key] then
                            local start = C_Container.GetContainerItemCooldown(bag, slot)
                            cache[key] = {
                                exists    = true,
                                available = (not start or start == 0),
                            }
                        end
                    end
                end
            end
        end
        SM._itemCache = cache
    end

    local function IsItemAvailable(itemName)
        if not itemName or itemName == "" then return true end
        local key = itemName:lower():match("^%s*(.-)%s*$")
        if key == "" then return true end
        RebuildItemCache()
        local entry = SM._itemCache[key]
        return entry and entry.available
    end

    local function ItemExists(itemName)
        if not itemName or itemName == "" then return true end
        local key = itemName:lower():match("^%s*(.-)%s*$")
        if key == "" then return true end
        RebuildItemCache()
        local entry = SM._itemCache[key]
        return entry and entry.exists
    end
    local function creatureType()
        local ct = UnitExists("target") and UnitCreatureType("target")
        return ct and ct:lower() or nil
    end

    -- Condition handlers keyed by the type stored on the rule. Creature
    -- types come from UnitCreatureType, which returns the client's
    -- LOCALIZED string - these lowercase comparisons only hold on an
    -- English client. notundead deliberately requires a known type, so no
    -- target and an untyped target both read false.
    local COND_FN = {
        always     = function(_) return true end,
        undead     = function(_) return creatureType() == "undead"     end,
        notundead  = function(_)
            local ct = creatureType()
            return ct ~= nil and ct ~= "undead"
        end,
        beast      = function(_) return creatureType() == "beast"      end,
        humanoid   = function(_) return creatureType() == "humanoid"   end,
        demon      = function(_) return creatureType() == "demon"      end,
        elemental  = function(_) return creatureType() == "elemental"  end,
        dragonkin  = function(_) return creatureType() == "dragonkin"  end,
        mechanical = function(_) return creatureType() == "mechanical" end,
        giant      = function(_) return creatureType() == "giant"      end,
        critter    = function(_) return creatureType() == "critter"    end,

        named      = function(v)
            if not UnitExists("target") then return false end
            local name = (UnitName("target") or ""):lower()
            local pat  = (v or ""):lower()
            return pat ~= "" and name:find(pat, 1, true) ~= nil
        end,

        -- named is a case-insensitive substring test; bossPicker is an exact
        -- case-sensitive match against the name the picker stored.
        bossPicker = function(v)
            if not UnitExists("target") or not v or v == "" then return false end
            return UnitName("target") == v
        end,

        corpse     = function(_)
            return UnitExists("target") and UnitIsDeadOrGhost("target")
        end,
        notarget   = function(_)
            return not UnitExists("target")
        end,

        -- Level -1 is the "??" skull every raid boss reports; classification
        -- alone misses bosses the server flags as elite only.
        boss       = function(_)
            if not UnitExists("target") then return false end
            return UnitClassification("target") == "worldboss"
                or UnitLevel("target") == -1
        end,
        elite      = function(_)
            if not UnitExists("target") then return false end
            local c = UnitClassification("target")
            return c == "elite" or c == "rareelite"
        end,

        enemy      = function(_)
            return UnitExists("target") and UnitIsEnemy("player", "target")
        end,
        friendly   = function(_)
            return UnitExists("target") and UnitIsFriend("player", "target")
        end,
    }

    -- buildMode "auto" assembles a two-line macro from the item, the verb
    -- and an optional macro conditional (stored WITHOUT its brackets, which
    -- are added here); any other mode uses rule.body verbatim.
    function SM.BuildBody(rule)
        if rule.buildMode == "auto" then
            local item = (rule.buildItem or ""):match("^%s*(.-)%s*$")
            if item ~= "" then
                local action = rule.buildAction or "use"
                local cond   = (rule.buildConditional or ""):match("^%s*(.-)%s*$")
                local condStr = cond ~= "" and ("[" .. cond .. "] ") or ""
                return "#showtooltip " .. item
                    .. "\n/" .. action .. " " .. condStr .. item
            end
            return ""
        end
        return rule.body or ""
    end

    -- Conditions are ORed, not ANDed: any one of the rule's (at most five)
    -- entries matching is enough. rule.condition / rule.value are the
    -- pre-list single-condition form, still read for records not yet
    -- rewritten by the migration block at the bottom of this file.
    local function ruleMatches(rule)
        local conds = rule.conditions
        if conds and #conds > 0 then
            for _, cond in ipairs(conds) do
                local fn = COND_FN[cond.type]
                if fn and fn(cond.value) then return true end
            end
            return false
        end
        local fn = COND_FN[rule.condition]
        return fn ~= nil and fn(rule.value)
    end

    -- What the winning rule actually points at. An auto-built rule names its
    -- item directly; a manual body is read back off its #showtooltip line,
    -- which is the only reliable declaration of the action in a hand-written
    -- macro. Returns nothing when neither yields a known item.
    local function RuleTarget(rule, body)
        local name = (rule.buildMode == "auto") and rule.buildItem or nil
        if not name or name == "" then
            name = body and body:match("#showtooltip%s+([^\r\n]+)")
        end
        name = name and name:match("^%s*(.-)%s*$")
        if not name or name == "" then return nil end
        local _, link, _, _, _, _, _, _, _, icon = GetItemInfo(name)
        local id = link and tonumber(link:match("item:(%d+)"))
        return name, id, icon
    end

    ------------------------------------------------------------------
    -- SAME KEY, SECOND MACRO. A smart macro can name another macro
    -- (mac.alsoRun) to run on the same key press. The smart macro's body
    -- gets one "/click RCSMChain<id>" line; that button is a hidden secure
    -- button whose type is "macro" and whose macro is the other macro BY
    -- NAME, so it always runs that macro's current text (another smart
    -- macro's included) and needs no bar slot. Hidden, it can never be
    -- clicked by accident. Attributes only change out of combat; a change
    -- made in a fight lands when it ends.
    -- One level only: a target that itself runs a second macro is refused,
    -- so two macros can never run each other in a loop.
    ------------------------------------------------------------------
    SM._chainButtons = {}
    local function ChainButtonName(mac) return "RCSMChain" .. tostring(mac.id) end
    SM.ChainButtonName = ChainButtonName

    local function ChainTarget(mac)
        local want = mac.alsoRun
        if type(want) ~= "string" or want == "" or want == mac.macroName then return nil end
        for _, other in ipairs(RC.db.smartMacros or {}) do
            if other ~= mac and other.macroName == want and other.alsoRun and other.alsoRun ~= "" then
                return nil, "loop"
            end
        end
        return want
    end
    SM.ChainTarget = ChainTarget

    function SM:SyncChains()
        if InCombatLockdown() then
            SM._chainDirty = true
            return
        end
        SM._chainDirty = false
        local live = {}
        for _, mac in ipairs(RC.db.smartMacros or {}) do
            if mac.id ~= nil then live[mac.id] = true end
            local want = ChainTarget(mac)
            local b = SM._chainButtons[mac.id]
            if want and not b then
                b = CreateFrame("Button", ChainButtonName(mac), UIParent, "SecureActionButtonTemplate")
                b:RegisterForClicks("AnyUp", "AnyDown")
                b:SetAttribute("useOnKeyDown", false)
                b:Hide()
                SM._chainButtons[mac.id] = b
            end
            -- no target: no type either, so a leftover /click line in the
            -- macro does nothing at all
            if b and b:GetAttribute("macro") ~= want then
                b:SetAttribute("type", want and "macro" or nil)
                b:SetAttribute("macro", want)
            end
        end
        -- a deleted smart macro's button stops running anything
        for id, b in pairs(SM._chainButtons) do
            if not live[id] and b:GetAttribute("macro") ~= nil then
                b:SetAttribute("type", nil)
                b:SetAttribute("macro", nil)
            end
        end
    end

    -- the body with its chain line (once, and only if it still fits)
    local MACRO_MAX = 255
    -- macros whose chain line did not fit, by id (runtime only, not saved)
    SM._tooLong = {}
    local function WithChain(mac, body)
        SM._tooLong[mac.id or mac] = nil
        if not ChainTarget(mac) then return body end
        local line = "/click " .. ChainButtonName(mac)
        if body:find(line, 1, true) then return body end
        local out = (body ~= "" and (body .. "\n") or "") .. line
        if #out > MACRO_MAX then
            SM._tooLong[mac.id or mac] = true
            RC:DebugPrint("SmartMacro '" .. tostring(mac.macroName)
                .. "': no room for the second-macro line (" .. #out .. " > 255)", "smartmacro")
            return body
        end
        return out
    end

    function SM:Evaluate()
        local macros = RC.db.smartMacros
        if not macros then return end
        local inCombat = InCombatLockdown()
        SM._active = {}
        if not inCombat then SM:SyncChains() end

        for _, mac in ipairs(macros) do
            -- Raid and profile restriction is per MACRO, evaluated once
            -- before any of its rules. Outside a raid entirely (no
            -- effective raid name) the filter is ignored rather than
            -- failed, so a filtered macro still works out in the world.
            local raidOk = true
            if mac.raidFilter and mac.raidFilter ~= "" and mac.raidFilter ~= "any" then
                local currentRaid = RC.GetEffectiveRaidName and RC:GetEffectiveRaidName()
                if currentRaid == nil then
                    raidOk = true
                elseif currentRaid == mac.raidFilter then
                    raidOk = true
                    if mac.profileFilter and mac.profileFilter ~= "" and mac.profileFilter ~= "any" then
                        local rp = RC.db.raidProfiles and RC.db.raidProfiles[currentRaid]
                        if (rp and rp.activeProfile) ~= mac.profileFilter then
                            raidOk = false
                        end
                    end
                else
                    raidOk = false
                end
            end

            if raidOk and mac.enabled and mac.macroName and mac.macroName ~= "" then
                -- The macro must already exist in the game's macro list;
                -- nothing here creates one, it only rewrites a body.
                local idx = GetMacroIndexByName(mac.macroName)
                if not idx or idx == 0 then
                    RC:DebugPrint(
                        "SmartMacro: no in-game macro named '" .. mac.macroName
                        .. "' - nothing to update",
                        "smartmacro"
                    )
                end
                if idx and idx > 0 then
                    local rules = mac.rules
                    if rules then
                        for _, rule in ipairs(rules) do
                            if ruleMatches(rule) then
                                local body = WithChain(mac, SM.BuildBody(rule))
                                local autoBuildOK =
                                    rule.buildMode ~= "auto"
                                    or not rule.buildItem
                                    or rule.buildItem == ""
                                    or ItemExists(rule.buildItem)

                                -- Matching is not enough: an auto-built rule
                                -- whose item is gone, or one whose itemCheck
                                -- is on cooldown, falls through to the next
                                -- rule instead of writing a dead macro.
                                if autoBuildOK and IsItemAvailable(rule.itemCheck) then
                                    -- Recorded before the write, and
                                    -- outside the _lastApplied guard: the
                                    -- winning rule is still the winning
                                    -- rule on a pass that writes nothing
                                    -- because the body has not changed.
                                    local tName, tId, tIcon = RuleTarget(rule, body)
                                    SM._active[mac.macroName] = {
                                        item   = tName,
                                        itemId = tId,
                                        icon   = tIcon,
                                        ruleId = rule.id,
                                        body   = body,
                                    }
                                    -- EditMacro is protected. In combat
                                    -- the body is parked by macro id and
                                    -- written on PLAYER_REGEN_ENABLED;
                                    -- _lastApplied is deliberately not
                                    -- updated until the write lands.
                                    if SM._lastApplied[mac.macroName] ~= body then
                                        if inCombat then
                                            SM._pending[mac.id] = { idx = idx, body = body }
                                            RC:DebugPrint(
                                                "SmartMacro '" .. mac.macroName
                                                .. "': queued (in combat) -> " .. body:sub(1, 50),
                                                "smartmacro"
                                            )
                                        else
                                            EditMacro(idx, nil, nil, body)
                                            SM._lastApplied[mac.macroName] = body
                                            SM._pending[mac.id] = nil
                                            RC:DebugPrint(
                                                "SmartMacro '" .. mac.macroName
                                                .. "': applied -> " .. body:sub(1, 50),
                                                "smartmacro"
                                            )
                                        end
                                    end
                                    break
                                end
                                -- Fallthrough: the rule matched but could not
                                -- be applied (item gone or on cooldown); the
                                -- loop continues to the next rule.
                                RC:DebugPrint(
                                    "SmartMacro '" .. mac.macroName
                                    .. "': conditions matched but '"
                                    .. (rule.itemCheck or "") .. "' unavailable, trying next rule",
                                    "smartmacro"
                                )
                            end
                        end
                    end
                end
            end
        end
    end

    -- What macroName currently resolves to, or nil if no rule matches.
    -- Cheap table read; safe to call from a display refresh.
    function SM:GetActive(macroName)
        if not macroName or macroName == "" then return nil end
        return SM._active[macroName]
    end

    -- Enabled macros that have a name, for settings dropdowns.
    function SM:ListMacroNames()
        local out = {}
        for _, mac in ipairs(RC.db.smartMacros or {}) do
            if mac.macroName and mac.macroName ~= "" then
                out[#out + 1] = mac.macroName
            end
        end
        table.sort(out)
        return out
    end

    -- Apply any updates that were queued during combat.
    -- Called on PLAYER_REGEN_ENABLED (leaving combat lockdown).
    function SM:FlushPending()
        if not next(SM._pending) then return end
        local macros = RC.db.smartMacros
        if not macros then SM._pending = {} return end

        for _, mac in ipairs(macros) do
            local pending = SM._pending[mac.id]
            if pending then
                local idx = GetMacroIndexByName(mac.macroName or "")
                if idx and idx > 0 then
                    EditMacro(idx, nil, nil, pending.body)
                    SM._lastApplied[mac.macroName] = pending.body
                    RC:DebugPrint(
                        "SmartMacro '" .. mac.macroName
                        .. "': flushed pending -> " .. pending.body:sub(1, 50),
                        "smartmacro"
                    )
                end
                SM._pending[mac.id] = nil
            end
        end
    end

    local eventFrame = CreateFrame("Frame", "WRSmartMacroEventFrame")
    eventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("PLAYER_LOGIN")
    eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
    -- Dirty-flag only: the rescan happens on the next Evaluate. The bags
    -- come from the shared bag index (only real changes), cooldowns from
    -- BAG_UPDATE_COOLDOWN - without it the cached "off cooldown" flag
    -- could be up to _ITEM_CACHE_TTL seconds stale and skip a rule that
    -- is actually ready.
    RC.Bags:OnChange("SmartMacro", function() SM._itemCacheTime = 0 end)
    eventFrame:SetScript("OnEvent", function(self, event)
        if event == "BAG_UPDATE_COOLDOWN" then
            SM._itemCacheTime = 0
            return
        end
        if event == "PLAYER_REGEN_ENABLED" then
            if SM._chainDirty then SM:SyncChains() end
            SM:FlushPending()
        end
        -- Every path lands on the same dirty flag plus one guarded 0.25s
        -- timer, so a burst of events costs a single Evaluate pass.
        SM._evalDirty = true
        if not SM._evalPending then
            SM._evalPending = true
            C_Timer.After(0.25, function()
                SM._evalPending = false
                if SM._evalDirty then
                    SM._evalDirty = false
                    SM:Evaluate()
                end
            end)
        end
    end)

    if RC.db.smartMacros == nil then
        RC.db.smartMacros = {}
    end
    if RC.db.smartMacrosNextId == nil then
        RC.db.smartMacrosNextId = 1
    end

    function RC:CreateSmartMacro()
        local id = RC.db.smartMacrosNextId
        RC.db.smartMacrosNextId = id + 1
        local mac = {
            id         = id,
            macroName  = "",
            enabled    = true,
            rules      = {},
            nextRuleId = 1,
        }
        table.insert(RC.db.smartMacros, mac)
        RC:SaveConfigurationToProfile()
        return mac
    end

    function RC:DeleteSmartMacro(id)
        local list = RC.db.smartMacros
        for i = 1, #list do
            if list[i].id == id then
                local nm = list[i].macroName
                table.remove(list, i)
                if nm then SM._lastApplied[nm] = nil end
                SM._pending[id] = nil
                RC:SaveConfigurationToProfile()
                return
            end
        end
    end

    function RC:GetSmartMacroById(id)
        for _, mac in ipairs(RC.db.smartMacros) do
            if mac.id == id then return mac end
        end
        return nil
    end

    function RC:AddSmartMacroRule(mac)
        local rid = mac.nextRuleId or 1
        mac.nextRuleId = rid + 1
        local rule = {
            id               = rid,
            conditions       = { { type = "undead" } },
            body             = "",
            itemCheck        = "",
            buildMode        = "auto",
            buildAction      = "use",
            buildItem        = "",
            buildConditional = "",
        }
        table.insert(mac.rules, rule)
        RC:SaveConfigurationToProfile()
        return rule
    end

    function RC:DeleteSmartMacroRule(mac, ruleId)
        local rules = mac.rules
        for i = 1, #rules do
            if rules[i].id == ruleId then
                table.remove(rules, i)
                RC:SaveConfigurationToProfile()
                return
            end
        end
    end

    function RC:MoveSmartMacroRule(mac, ruleId, direction)
        local rules = mac.rules
        for i = 1, #rules do
            if rules[i].id == ruleId then
                local target = i + direction
                if target >= 1 and target <= #rules then
                    rules[i], rules[target] = rules[target], rules[i]
                    RC:SaveConfigurationToProfile()
                end
                return
            end
        end
    end

    -- Load-time rule normalization: folds the single-condition form into the
    -- conditions list, turns the old buildCursor boolean into an "@cursor"
    -- conditional, and clears rule-level raidScope / profileScope, which the
    -- macro-level raidFilter / profileFilter replaced.
    do
        local smartMacros = RC.db.smartMacros
        if smartMacros then
            for _, mac in ipairs(smartMacros) do
                for _, rule in ipairs(mac.rules or {}) do
                    if rule.buildCursor == true
                        and (not rule.buildConditional or rule.buildConditional == "") then
                        rule.buildConditional = "@cursor"
                    end
                    rule.buildCursor = nil
                    if not rule.conditions then
                        rule.conditions = {
                            { type  = rule.condition or "always",
                              value = rule.value or "" }
                        }
                    end
                    rule.condition = nil
                    rule.value     = nil
                    rule.clearMacro   = nil
                    rule.raidScope    = nil
                    rule.profileScope = nil
                end
            end
        end
    end

    RC:DebugPrint("SmartMacro initialized", "system")
end

C_Timer.After(1.0, InitializeSmartMacro)
