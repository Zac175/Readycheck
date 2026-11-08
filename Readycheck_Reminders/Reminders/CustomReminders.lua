------------------------------------------------------------------------
-- Readycheck - Custom Reminders
-- User-defined rule engine: each reminder is a table with a `mode` field
-- selecting one trigger schema (aura, cooldown, health, equipment,
-- resource, status, condition, lua, event, periodic, sequence) plus a
-- matching config sub-table (r.aura, r.cdConfig, r.health, ...). Every
-- reminder also carries r.extraConditions (AND-gate on top of the mode
-- trigger), r.priority (evaluation/display order, lower first),
-- r.cooldown/r.lastFired (rearm timer), and load/scope gates (loadClass,
-- loadSpec, loadGroup, loadZone, loadZoneName, scope, bossKey).
-- EvaluateAll() runs on a 0.5s ticker: PassesLoad -> PassesScope -> mode
-- trigger -> extraConditions -> cooldown gate -> FireReminder. "event"
-- mode reminders instead rearm via CR.eventReminders[id], set by
-- HandleFrameEvent and consumed on the next tick.
------------------------------------------------------------------------

-- Taint-safe API locals (fallbacks on RC.Compat, built in Core;
-- never write _G - a written Blizzard global taints its readers)
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)
local GetSpellCooldown = GetSpellCooldown or (RCC and RCC.Compat and RCC.Compat.GetSpellCooldown)
local UnitDebuff = UnitDebuff or (RCC and RCC.Compat and RCC.Compat.UnitDebuff)
local IsSpellInRange = IsSpellInRange or (RCC and RCC.Compat and RCC.Compat.IsSpellInRange)

local pairs, ipairs, type, tostring, tonumber, select = pairs, ipairs, type, tostring, tonumber, select
local GetTime = GetTime
local UnitBuff, UnitHealth, UnitHealthMax = UnitBuff, UnitHealth, UnitHealthMax
-- WoW Forever hides other units' health in combat ("secret" values that
-- may not be compared): read as 0, so a health condition is simply not
-- met. issecretvalue does not exist on the other clients.
if issecretvalue then
    local rawHP, rawMax = UnitHealth, UnitHealthMax
    UnitHealth = function(u) local v = rawHP(u) if issecretvalue(v) then return 0 end return v end
    UnitHealthMax = function(u) local v = rawMax(u) if issecretvalue(v) then return 0 end return v end
end
local UnitPower, UnitPowerMax, UnitAffectingCombat = UnitPower, UnitPowerMax, UnitAffectingCombat
local UnitExists, UnitIsDead, UnitName, UnitClass = UnitExists, UnitIsDead, UnitName, UnitClass
local UnitIsPlayer = UnitIsPlayer
local GetInventoryItemID, GetInventoryItemCooldown = GetInventoryItemID, GetInventoryItemCooldown
local GetItemCount = GetItemCount
local UnitCastingInfo, UnitChannelInfo = UnitCastingInfo, UnitChannelInfo
local GetShapeshiftForm = GetShapeshiftForm
local IsUsableSpell = IsUsableSpell
local GetNumGroupMembers = GetNumGroupMembers
local UnitClassification, UnitLevel = UnitClassification, UnitLevel
local GetWeaponEnchantInfo = GetWeaponEnchantInfo
local UnitAttackPower, UnitAttackSpeed = UnitAttackPower, UnitAttackSpeed
local GetCritChance, GetHitModifier = GetCritChance, GetHitModifier
-- (2026-11-07) WoW Forever hands your own power, attack power, attack
-- speed and stats back hidden too, and other units' casts: a hidden number
-- reads as 0 and a hidden cast as no cast, so the condition is simply not met.
if issecretvalue then
    local function Zero(fn)
        return fn and function(...)
            local a, b, c, d, e = fn(...)
            if issecretvalue(a) then a = 0 end
            if issecretvalue(b) then b = 0 end
            if issecretvalue(c) then c = 0 end
            if issecretvalue(d) then d = 0 end
            if issecretvalue(e) then e = 0 end
            return a, b, c, d, e
        end
    end
    UnitPower, UnitPowerMax = Zero(UnitPower), Zero(UnitPowerMax)
    UnitAttackPower, UnitAttackSpeed = Zero(UnitAttackPower), Zero(UnitAttackSpeed)
    GetCritChance, GetHitModifier = Zero(GetCritChance), Zero(GetHitModifier)
    local function NoCast(fn)
        return fn and function(...)
            local t = { fn(...) }
            for i = 1, 10 do if issecretvalue(t[i]) then return nil end end
            return unpack(t, 1, 10)
        end
    end
    UnitCastingInfo, UnitChannelInfo = NoCast(UnitCastingInfo), NoCast(UnitChannelInfo)
end
local IsInRaid, IsInGroup, IsInInstance = IsInRaid, IsInGroup, IsInInstance
local C_Timer, loadstring, pcall = C_Timer, loadstring, pcall

local function InitializeCustomReminders()
    local RC = _G.Readycheck
    if not RC then C_Timer.After(0.1, InitializeCustomReminders) return end
    if not RC.db then C_Timer.After(0.2, InitializeCustomReminders) return end

    if not RC.db.customReminders then RC.db.customReminders = {reminders={}, nextId=1} end
    if not RC.db.customReminders.reminders then RC.db.customReminders.reminders = {} end
    if not RC.db.customReminders.nextId then RC.db.customReminders.nextId = 1 end

    -- One-time-per-reload schema backfill for saved reminders, not part
    -- of the runtime evaluation path (see EvaluateAll below).
    for _, r in ipairs(RC.db.customReminders.reminders) do
        if type(r.cooldown) == "table" then
            if not r.cdConfig then r.cdConfig = r.cooldown end
            r.cooldown = 10
        end
        if not r.cdConfig then
            r.cdConfig = {spellId=nil, itemId=nil, condition="ready", threshold=5}
        end
        if r.enabled == nil then r.enabled = true end
        if not r.extraConditions then r.extraConditions = {} end
        if not r.aura         then r.aura         = {unit="player",buffType="buff",spellId=nil,condition="missing",expiresIn=5,stackValue=1} end
        if not r.health       then r.health       = {unit="player",op="<",value=30} end
        if not r.resource     then r.resource     = {unit="player",powerType=1,op=">",value=80,usePercent=false} end
        if not r.status       then r.status       = {type="in_combat"} end
        if not r.eventTrigger then r.eventTrigger = {event="SPELL_CAST_SUCCESS",spellId=nil,source="player",dest=""} end
        if r.eventTrigger and not r.eventTrigger.eventCategory then
            r.eventTrigger.eventCategory = "cleu"
        end
        if not r.periodic then r.periodic = {intervalSec=30} end
        if r.priority == nil then r.priority = 5 end
        if r.animationType == nil then r.animationType = nil end
        if not r.equipment then r.equipment = {slot=16, condition="not_equipped", itemId=nil} end
        if not r.loadZoneName then r.loadZoneName = nil end
        if not r.conditions   then r.conditions   = {} end
        if not r.sequence     then r.sequence     = {step=1,steps={}} end
        if not r.lua          then r.lua          = {code="return false",compiledFn=nil,lastError=nil,errorCount=0} end
        if not r.customNpcIds    then r.customNpcIds    = {} end
        if r.continuous == nil   then r.continuous      = false end
        if not r.soundFile       then r.soundFile       = "" end
        if not r.scope           then r.scope           = "any" end
        if r.ttsEnabled == nil   then r.ttsEnabled      = false end
        if not r.ttsText         then r.ttsText         = "" end
        if not r.loadGroup       then r.loadGroup       = nil end
        if not r.loadZone        then r.loadZone        = nil end
        if not r.loadSpec        then r.loadSpec        = nil end
        if r.aura and not r.aura.untrigger then r.aura.untrigger = "auto" end
    end

    RC.CustomReminders = RC.CustomReminders or {}
    local CR = RC.CustomReminders
    CR.initialized        = true
    CR.ticker             = nil
    CR.combatStartTime    = nil
    CR.lastPotionTime     = nil
    CR.eventReminders     = {}
    CR.sortDirty          = true
    CR.hasEventReminders  = nil

    -- TTK for custom reminders: the same time left the ability reminders
    -- fire on and the TTK HUD shows (RC:GetTTKRemaining), whether or not
    -- the HUD is on and whatever is targeted.
    local function TTKLeft()
        if not RC.GetTTKRemaining then return nil end
        local rem = RC:GetTTKRemaining()
        return rem
    end
    -- How much slower than usual this pull is going, in percent (negative
    -- = faster): this pull's own projected kill time against the usual
    -- one. nil until both are known.
    local function TTKPaceSlowerPct()
        local fight = RC.executeCalculator and RC.executeCalculator.currentFight
        if not (fight and fight.started and RC.GetFightExpectedTTK and RC.GetTTKRemaining) then return nil end
        local expected = RC:GetFightExpectedTTK(fight)
        local _, _, _, _, live = RC:GetTTKRemaining()
        if not (expected and expected > 0 and live and live > 0) then return nil end
        return (live - expected) / expected * 100
    end
    CR.TTKLeft = TTKLeft

    -- A condition reminder that watches the TTK fires once per boss
    -- fight (unless set to fire continuously), not again every cooldown
    -- while it stays true - "TTK below 30" is one moment, not three.
    local TTK_CONDITIONS = {
        ttk_below = true, ttk_above = true,
        pace_slower = true, pace_faster = true,
        ttk_pace_slow = true, ttk_pace_fast = true,
    }
    local function ListHasTTK(list)
        if type(list) ~= "table" then return false end
        for _, c in ipairs(list) do
            if type(c) == "table" and TTK_CONDITIONS[c.type] then return true end
        end
        return false
    end
    local function HasTTKCondition(r)
        return ListHasTTK(r.conditions) or ListHasTTK(r.extraConditions)
    end
    CR.ttkFiredFight = setmetatable({}, { __mode = "v" })

    local pendingIconForAbility = {}
    local pendingAbilitiesForItem = {}

    local function TrackPendingIcon(abilityKey, itemId)
        pendingIconForAbility[abilityKey] = itemId
        local list = pendingAbilitiesForItem[itemId]
        if not list then
            list = {}
            pendingAbilitiesForItem[itemId] = list
        end
        local already = false
        for _, k in ipairs(list) do if k == abilityKey then already = true; break end end
        if not already then table.insert(list, abilityKey) end
    end

    local function ResolveIcon(r, abilityKey)
        if r.iconSpellId then
            local t = GetSpellTexture(r.iconSpellId)
            if t then return t end
        end
        if r.iconItemId then
            local t = GetItemIcon(r.iconItemId)
            if t then return t end
            if GetItemInfo then GetItemInfo(r.iconItemId) end
            if abilityKey then TrackPendingIcon(abilityKey, r.iconItemId) end
        end
        if r.icon and r.icon ~= "" then return r.icon end
        if r.aura and r.aura.spellId then
            local t = GetSpellTexture(r.aura.spellId)
            if t then return t end
        end
        if r.cdConfig and r.cdConfig.spellId then
            local t = GetSpellTexture(r.cdConfig.spellId)
            if t then return t end
        end
        if r.cdConfig and r.cdConfig.itemId then
            local id = r.cdConfig.itemId
            local t = GetItemIcon(id)
            if t then return t end
            if GetItemInfo then GetItemInfo(id) end
            if abilityKey then TrackPendingIcon(abilityKey, id) end
        end
        if r.equipment then
            local eqCfg = r.equipment
            if eqCfg.itemId then
                local id = eqCfg.itemId
                local t = GetItemIcon(id)
                if t then return t end
                if GetItemInfo then GetItemInfo(id) end
                if abilityKey then TrackPendingIcon(abilityKey, id) end
            end
            local slot = eqCfg.slot
            if slot and GetInventoryItemID then
                local equippedId = GetInventoryItemID("player", slot)
                if equippedId then
                    local t = GetItemIcon(equippedId)
                    if t then return t end
                    if GetItemInfo then GetItemInfo(equippedId) end
                    if abilityKey then TrackPendingIcon(abilityKey, equippedId) end
                end
            end
        end
        return "Interface\\Icons\\INV_Misc_QuestionMark"
    end
    -- the icon a reminder will show, for the settings preview
    function RC:ResolveCustomReminderIcon(r) return ResolveIcon(r, nil) end

    local function RefreshIconsForItem(itemId)
        if not itemId then return end
        local keys = pendingAbilitiesForItem[itemId]
        if not keys then return end
        local texture = GetItemIcon(itemId)
        if not texture then return end
        for _, abilityKey in ipairs(keys) do
            if RC.abilityData and RC.abilityData[abilityKey] then
                RC.abilityData[abilityKey].icon = texture
            end
            pendingIconForAbility[abilityKey] = nil
        end
        pendingAbilitiesForItem[itemId] = nil
        if RC.activeReminderData and RC.activeReminderData.abilities
           and #RC.activeReminderData.abilities > 0
           and RC.UpdateReminderWithRemainingAbilities then
            RC:UpdateReminderWithRemainingAbilities()
        end
    end

    -- GetItemIcon can return nil before the server has sent item data;
    -- rather than poll, the pending id is resolved once via this event.
    if not RC._customReminderItemInfoFrame then
        RC._customReminderItemInfoFrame = CreateFrame("Frame")
        RC._customReminderItemInfoFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
        RC._customReminderItemInfoFrame:SetScript("OnEvent", function(_, event, itemId, success)
            if event == "GET_ITEM_INFO_RECEIVED" and success then
                RefreshIconsForItem(itemId)
            end
        end)
    end

    -- The player's own auras come from the shared aura read (RC.Auras);
    -- any other unit is read here.
    local function FindAura(unit, spellId, isDebuff)
        if unit == "player" then
            local a
            if spellId then
                if isDebuff then a = RC.Auras:Debuff(spellId) else a = RC.Auras:Buff(spellId) end
            else
                a = (isDebuff and RC.Auras:Debuffs() or RC.Auras:Buffs())[1]
            end
            if a then return true, a.expirationTime, a.count end
            return false, nil, 0
        end
        local fn = isDebuff and UnitDebuff or UnitBuff
        for i = 1, 40 do
            local name, _, count, _, dur, expTime, _, _, _, sid = fn(unit, i)
            if not name then break end
            if not spellId or sid == spellId then
                return true, expTime, count
            end
        end
        return false, nil, 0
    end

    local function ApplyMessageVars(msg, r)
        if not msg or not msg:find("{") then return msg end
        if msg:find("{remaining}") then
            local cfg = r.aura
            if cfg then
                local _, expTime = FindAura(cfg.unit or "player", cfg.spellId, cfg.buffType == "debuff")
                if expTime and expTime > 0 then
                    local rem = math.max(0, math.floor(expTime - GetTime()))
                    msg = msg:gsub("{remaining}", tostring(rem).."s")
                else
                    msg = msg:gsub("{remaining}", "inf")
                end
            end
        end
        if msg:find("{stacks}") then
            local cfg = r.aura
            if cfg then
                local _, _, stacks = FindAura(cfg.unit or "player", cfg.spellId, cfg.buffType == "debuff")
                msg = msg:gsub("{stacks}", tostring(stacks or 0))
            end
        end
        if msg:find("{hp}") then
            local unit = (r.health and r.health.unit) or "target"
            if UnitExists(unit) then
                local hp, mx = UnitHealth(unit), UnitHealthMax(unit)
                local pct = (mx and mx > 0) and math.floor(hp / mx * 100) or 0
                msg = msg:gsub("{hp}", pct .. "%%")
            end
        end
        if msg:find("{power}") then
            local unit = (r.resource and r.resource.unit) or "player"
            local pt   = (r.resource and r.resource.powerType) or 1
            msg = msg:gsub("{power}", tostring(UnitPower(unit, pt) or 0))
        end
        if msg:find("{rage}") then
            msg = msg:gsub("{rage}", tostring(UnitPower("player", 1) or 0))
        end
        if msg:find("{ttk}") then
            local ttk = TTKLeft()
            if ttk and ttk > 0 then
                msg = msg:gsub("{ttk}", RC:FormatTime(ttk))
            else
                msg = msg:gsub("{ttk}", "?")
            end
        end
        if msg:find("{fight}") then
            local dur = RC.CustomReminders and RC.CustomReminders.combatStartTime
                     and math.floor(GetTime() - RC.CustomReminders.combatStartTime) or 0
            msg = msg:gsub("{fight}", RC:FormatTime(dur))
        end
        if msg:find("{name}") then
            msg = msg:gsub("{name}", UnitName("player") or "")
        end
        return msg
    end

    local function FireReminder(reminder)
        local key = "custom_" .. reminder.id
        local msg = ApplyMessageVars(reminder.message or reminder.name or "Reminder", reminder)

        if not RC.db.abilityOverrides then RC.db.abilityOverrides = {} end
        RC.db.abilityOverrides[key] = {
            animationType = reminder.animationType or RC.db.animationType or "fade",
            soundEnabled  = reminder.soundKey and reminder.soundKey ~= "",
            -- Always true: a custom reminder owns its TTS decision outright.
            -- The generic ability voice in Core_Reminders reads this and
            -- stays silent, so the block below is the only thing that can
            -- speak for this reminder - and it honours reminder.ttsEnabled
            -- and reminder.ttsText. Setting it from ttsEnabled (as it used
            -- to be) left the generic path free to speak the reminder's
            -- name whenever the box was UNchecked.
            ttsBlocked    = true,
        }

        RC.abilityData[key] = {
            name        = reminder.name or "Reminder",
            icon        = ResolveIcon(reminder, key),
            description = msg,
        }
        local dur = (reminder.duration and reminder.duration > 0) and reminder.duration or 5
        RC:ShowReminder(msg, {key}, dur)

        if reminder.soundKey and reminder.soundKey ~= "" then
            local sf = reminder.soundFile and reminder.soundFile ~= "" and reminder.soundFile
                    or (RC.LSM and RC.LSM:Fetch("sound", reminder.soundKey))
                    or reminder.soundKey
            if sf and sf ~= "" then PlaySoundFile(sf, "Master") end
        end

        -- TTS reads reminder.ttsText/name directly, never the {var}-
        -- substituted msg the display shows - a template with {remaining}
        -- etc. must be duplicated into ttsText to be spoken.
        if reminder.ttsEnabled and RC.SpeakTTS
           and RC.activeReminderData and not RC.activeReminderData.ttsPlayed
        then
            local spoken = (reminder.ttsText and reminder.ttsText ~= "")
                and reminder.ttsText
                or (reminder.name or "Reminder")
            RC:DebugPrint("CustomReminders spoke: '" .. spoken
                .. "' (reminder: " .. (reminder.name or "?") .. ")", "reminders")
            RC:SpeakTTS(spoken, false)
            RC.activeReminderData.ttsPlayed = true
        end

        reminder.lastFired = GetTime()
        RC:DebugPrint("CustomReminders: fired '" .. (reminder.name or reminder.id) .. "'", "trigger")
    end

    local function IsOnCooldown(r)
        local cd = r.cooldown
        if type(cd) ~= "number" then cd = 10 end
        return (GetTime() - (r.lastFired or 0)) < cd
    end

    local function PassesLoad(r)
        if r.loadClass and r.loadClass ~= "" then
            local _, cls = UnitClass("player")
            if cls ~= r.loadClass then return false end
        end
        if r.loadSpec and r.loadSpec ~= "" then
            local spec = RC.specDetection and RC.specDetection.currentSpec
            if spec ~= r.loadSpec then return false end
        end
        if r.loadGroup and r.loadGroup ~= "" then
            local g = r.loadGroup
            if g == "solo" and (IsInGroup() or IsInRaid()) then return false end
            if g == "party" and not (IsInGroup() and not IsInRaid()) then return false end
            if g == "raid" and not IsInRaid() then return false end
        end
        if r.loadZone and r.loadZone ~= "" then
            local inInst, instType = IsInInstance()
            if r.loadZone == "world" and inInst then return false end
            if r.loadZone == "instance" and not inInst then return false end
            if r.loadZone == "raid" and instType ~= "raid" then return false end
            if r.loadZone == "party" and instType ~= "party" then return false end
            if r.loadZone == "pvp" and instType ~= "pvp" and instType ~= "arena" then return false end
        end
        if r.loadZoneName and r.loadZoneName ~= "" then
            local zone = GetZoneText() or ""
            local subzone = GetSubZoneText() or ""
            local pattern = r.loadZoneName:lower()
            if not zone:lower():find(pattern, 1, true) and not subzone:lower():find(pattern, 1, true) then
                return false
            end
        end
        return true
    end

    local function PassesScope(r)
        local scope = r.scope or "any"
        if scope == "any" then return true end
        local fight = RC.executeCalculator and RC.executeCalculator.currentFight
        local inFight = fight and fight.started and fight.bossEngaged
        if scope == "raid" then
            return IsInRaid()
        elseif scope == "trash" then
            return IsInRaid() and not inFight
        elseif scope == "boss" then
            if not inFight then return false end

            if r.bossKey and r.bossKey ~= "" then
                local rn, bn = r.bossKey:match("^(.+)|(.+)$")
                if rn and bn then
                    return fight.raidName == rn and fight.encounterName == bn
                end
            end

            if r.customNpcIds and #r.customNpcIds > 0 then
                local guid = Readycheck.SafeGUID("target")
                if guid then
                    local npcId = tonumber(guid:match("%-(%d+)%-%x+$"))
                    if npcId then
                        for _, id in ipairs(r.customNpcIds) do
                            if id == npcId then return true end
                        end
                    end
                end
                return false
            end

            return true
        end
        return true
    end

    local function EvalAura(r)
        local cfg = r.aura
        if not cfg then return false end
        local unit = cfg.unit or "player"
        if not UnitExists(unit) or UnitIsDead(unit) then return false end

        local isDebuff = cfg.buffType == "debuff"
        local found, expTime, stacks = FindAura(unit, cfg.spellId, isDebuff)
        local cond = cfg.condition or "active"

        if cond == "active" then
            return found
        elseif cond == "missing" then
            return not found
        elseif cond == "expiring" then
            if not found or not expTime or expTime == 0 then return false end
            return (expTime - GetTime()) < (cfg.expiresIn or 5)
        elseif cond == "stacks_above" then
            return found and stacks >= (cfg.stackValue or 1)
        elseif cond == "stacks_below" then
            return found and stacks < (cfg.stackValue or 1)
        end
        return false
    end

    -- The equip slot an item was last seen in, so the 0.5s eval tick does
    -- not walk all 19 slots each time; bags go through the shared index.
    local cdEquipSlot = {}
    local function GetCooldownInfo(spellId, itemId)
        if spellId then
            local s, d = GetSpellCooldown(spellId)
            return s, d
        elseif itemId then
            local eq = cdEquipSlot[itemId]
            if eq and GetInventoryItemID("player", eq) == itemId then
                local s, d = Readycheck.PlainCD(GetInventoryItemCooldown("player", eq))
                return s, d
            end
            cdEquipSlot[itemId] = nil
            for slot = 1, 19 do
                if GetInventoryItemID("player", slot) == itemId then
                    cdEquipSlot[itemId] = slot
                    local s, d = Readycheck.PlainCD(GetInventoryItemCooldown("player", slot))
                    return s, d
                end
            end
            local bag, bagSlot = RC.Bags:Find(itemId)
            if bag then
                local s, d = C_Container.GetContainerItemCooldown(bag, bagSlot)
                return s, d
            end
        end
        return nil, nil
    end

    local function EvalCooldown(r)
        local cfg = r.cdConfig
        if not cfg then return false end
        local s, d = GetCooldownInfo(cfg.spellId, cfg.itemId)
        if not s then return false end

        local remaining = 0
        if s > 0 and d and d > 1.5 then
            remaining = s + d - GetTime()
            if remaining < 0 then remaining = 0 end
        end
        local onCD = remaining > 0
        local cond = cfg.condition or "ready"

        if cond == "ready" then return not onCD
        elseif cond == "active" then return onCD
        elseif cond == "below_n_sec" then return onCD and remaining <= (cfg.threshold or 5)
        elseif cond == "above_n_sec" then return onCD and remaining > (cfg.threshold or 10)
        end
        return false
    end

    local function EvalHealth(r)
        local cfg = r.health
        if not cfg then return false end
        local unit = cfg.unit or "player"
        if not UnitExists(unit) then return false end
        local hp, maxhp = UnitHealth(unit), UnitHealthMax(unit)
        if not maxhp or maxhp == 0 then return false end
        local pct = (hp / maxhp) * 100
        local op, val = cfg.op or "<", cfg.value or 30
        if op == "<"  then return pct < val
        elseif op == ">" then return pct > val
        elseif op == "<=" then return pct <= val
        elseif op == ">=" then return pct >= val end
        return false
    end

    local function EvalEquipment(r)
        local cfg = r.equipment
        if not cfg then return false end
        local slot = cfg.slot or 16
        local cond = cfg.condition or "not_equipped"

        if cond == "equipped" then
            local id = GetInventoryItemID("player", slot)
            if cfg.itemId then return id == cfg.itemId end
            return id ~= nil

        elseif cond == "not_equipped" then
            local id = GetInventoryItemID("player", slot)
            if cfg.itemId then return id ~= cfg.itemId end
            return id == nil

        elseif cond == "item_ready" then
            -- "Ready" only means something for an item with a use effect.
            -- A passive trinket never goes on cooldown, so it read as ready
            -- forever and the reminder fired every few seconds in combat.
            local id = GetInventoryItemID("player", slot)
            if not id then return false end
            local ItemSpell = (C_Item and C_Item.GetItemSpell) or GetItemSpell
            if ItemSpell and not ItemSpell(id) then return false end
            local start, duration = Readycheck.PlainCD(GetInventoryItemCooldown("player", slot))
            return not start or start == 0 or (GetTime() - start) >= duration

        elseif cond == "item_on_cd" then
            local start, duration = Readycheck.PlainCD(GetInventoryItemCooldown("player", slot))
            return start and start > 0 and duration and (start + duration - GetTime()) > 0

        elseif cond == "has_temp_enchant" then
            local mhEnch, _, _, _, ohEnch = GetWeaponEnchantInfo()
            if slot == 16 then return mhEnch == 1 end
            if slot == 17 then return ohEnch == 1 end
            return false

        elseif cond == "no_temp_enchant" then
            local mhEnch, _, _, _, ohEnch = GetWeaponEnchantInfo()
            if slot == 16 then return not mhEnch or mhEnch ~= 1 end
            if slot == 17 then return not ohEnch or ohEnch ~= 1 end
            return false

        elseif cond == "stat_ap_above" then
            local base, pos = UnitAttackPower("player")
            return (base + pos) > (cfg.value or 0)

        elseif cond == "stat_ap_below" then
            local base, pos = UnitAttackPower("player")
            return (base + pos) < (cfg.value or 0)

        elseif cond == "stat_crit_above" then
            local crit = GetCritChance and GetCritChance() or 0
            return crit > (cfg.value or 0)

        elseif cond == "stat_hit_above" then
            local hit = GetHitModifier and GetHitModifier() or 0
            return hit > (cfg.value or 0)

        elseif cond == "stat_hit_below" then
            local hit = GetHitModifier and GetHitModifier() or 0
            return hit < (cfg.value or 0)
        end
        return false
    end

    local function EvalResource(r)
        local cfg = r.resource
        if not cfg then return false end
        local unit = cfg.unit or "player"
        if not UnitExists(unit) then return false end
        local pt = cfg.powerType or 1
        local cur = UnitPower(unit, pt) or 0
        local mx  = UnitPowerMax(unit, pt) or 1
        local val
        if cfg.usePercent and mx > 0 then val = (cur / mx) * 100
        else val = cur end
        local threshold = cfg.value or 0
        local op = cfg.op or ">"
        if op == "<"  then return val < threshold
        elseif op == ">" then return val > threshold
        elseif op == "<=" then return val <= threshold
        elseif op == ">=" then return val >= threshold end
        return false
    end

    local function EvalStatus(r)
        local cfg = r.status
        if not cfg then return false end
        local t = cfg.type or ""
        if t == "in_combat"     then return UnitAffectingCombat("player") and true or false
        elseif t == "out_of_combat" then return not UnitAffectingCombat("player")
        elseif t == "in_raid"       then return IsInRaid()
        elseif t == "in_party"      then return IsInGroup() and not IsInRaid()
        elseif t == "solo"          then return not IsInGroup() and not IsInRaid()
        elseif t == "in_instance"   then return IsInInstance()
        elseif t == "resting"       then return IsResting and IsResting()
        elseif t == "mounted"       then return IsMounted and IsMounted()
        elseif t == "in_vehicle"    then return UnitInVehicle and UnitInVehicle("player")
        elseif t == "pvp_flagged"   then return UnitIsPVP and UnitIsPVP("player")
        elseif t == "dead"          then return UnitIsDead("player")
        elseif t == "target_exists" then return UnitExists("target") and not UnitIsDead("target")
        elseif t == "target_is_boss" then
            local fight = RC.executeCalculator and RC.executeCalculator.currentFight
            return fight and fight.started and fight.bossEngaged
        end
        return false
    end

    local function EvalCondition(cond)
        local t = cond.type
        if not t then return false end
        local unit = cond.unit or "player"

        if t == "buff_missing" then
            if not cond.spellId then return false end
            local f = FindAura(unit, cond.spellId, false)
            return not f
        elseif t == "buff_active" then
            if not cond.spellId then return false end
            return FindAura(unit, cond.spellId, false)
        elseif t == "buff_expiring" then
            if not cond.spellId then return false end
            local f, expTime = FindAura(unit, cond.spellId, false)
            if not f or not expTime or expTime == 0 then return false end
            return (expTime - GetTime()) < (cond.value or 5)
        elseif t == "debuff_active" then
            if not cond.spellId then return false end
            return FindAura(unit, cond.spellId, true)
        elseif t == "debuff_missing" then
            if not cond.spellId then return false end
            local f = FindAura(unit, cond.spellId, true)
            return not f
        elseif t == "cooldown_ready" then
            local s, d = GetCooldownInfo(cond.spellId, cond.itemId)
            if not s then return false end
            return s == 0 or (s + (d or 0) - GetTime()) <= 0
        elseif t == "cooldown_active" then
            local s, d = GetCooldownInfo(cond.spellId, cond.itemId)
            if not s or s == 0 then return false end
            return (s + (d or 0) - GetTime()) > 0
        elseif t == "hp_below" then
            if not UnitExists(unit) then return false end
            local hp, mx = UnitHealth(unit), UnitHealthMax(unit)
            return mx and mx > 0 and (hp/mx*100) < (cond.value or 30)
        elseif t == "hp_above" then
            if not UnitExists(unit) then return false end
            local hp, mx = UnitHealth(unit), UnitHealthMax(unit)
            return mx and mx > 0 and (hp/mx*100) > (cond.value or 70)
        elseif t == "power_above" then
            local pt = cond.powerType or 1
            return (UnitPower(unit, pt) or 0) > (cond.value or 0)
        elseif t == "power_below" then
            local pt = cond.powerType or 1
            return (UnitPower(unit, pt) or 0) < (cond.value or 0)
        elseif t == "in_combat"      then return UnitAffectingCombat("player") and true or false
        elseif t == "out_of_combat"  then return not UnitAffectingCombat("player")
        elseif t == "in_raid"        then return IsInRaid()
        elseif t == "in_group"       then return IsInGroup()
        elseif t == "in_instance"    then return IsInInstance()
        elseif t == "fight_duration_above" then
            return CR.combatStartTime and (GetTime() - CR.combatStartTime) > (cond.value or 60)
        elseif t == "fight_duration_below" then
            return CR.combatStartTime and (GetTime() - CR.combatStartTime) < (cond.value or 30)
        elseif t == "ttk_below" then
            local ttk = TTKLeft()
            return ttk and ttk > 0 and ttk < (cond.value or 30)
        elseif t == "ttk_above" then
            local ttk = TTKLeft()
            return ttk and ttk > (cond.value or 60)
        elseif t == "pace_slower" or t == "ttk_pace_slow" then
            local slower = TTKPaceSlowerPct()
            return slower ~= nil and slower > (cond.value or 10)
        elseif t == "pace_faster" or t == "ttk_pace_fast" then
            local slower = TTKPaceSlowerPct()
            return slower ~= nil and -slower > (cond.value or 10)
        elseif t == "item_count_below" then
            return cond.itemId and GetItemCount(cond.itemId, false) < (cond.value or 1)
        elseif t == "spec_is" then
            return RC.specDetection and RC.specDetection.currentSpec == cond.specKey
        elseif t == "target_is_player" then
            return UnitExists("target") and UnitIsPlayer("target")
        elseif t == "unit_exists" then
            return UnitExists(unit) and not UnitIsDead(unit)

        elseif t == "casting" then
            local name = UnitCastingInfo(unit) or UnitChannelInfo(unit)
            if not name then return false end
            if cond.spellName and cond.spellName ~= "" then
                return name:lower():find(cond.spellName:lower(), 1, true) ~= nil
            end
            if cond.spellId then
                local _, _, _, _, _, _, castId = UnitCastingInfo(unit)
                return castId == cond.spellId
            end
            return true
        elseif t == "not_casting" then
            return not UnitCastingInfo(unit) and not UnitChannelInfo(unit)
        elseif t == "target_casting_interruptible" then
            local _, _, _, _, _, _, _, notInterruptible = UnitCastingInfo("target")
            return UnitCastingInfo("target") ~= nil and not notInterruptible
        elseif t == "target_casting_spell" then
            local name = UnitCastingInfo("target") or UnitChannelInfo("target")
            if not name or not cond.spellName or cond.spellName == "" then return name ~= nil end
            return name:lower():find(cond.spellName:lower(), 1, true) ~= nil

        elseif t == "stance_is" then
            local form = GetShapeshiftForm and GetShapeshiftForm() or 0
            return form == (cond.stanceIndex or 0)
        elseif t == "not_in_stance" then
            local form = GetShapeshiftForm and GetShapeshiftForm() or 0
            return form == 0

        elseif t == "spell_usable" then
            if not cond.spellId then return false end
            local usable, noMana = IsUsableSpell(cond.spellId)
            local s, d = GetSpellCooldown(cond.spellId)
            local onCD = s and s > 0 and d and d > 1.5
            return usable and not onCD
        elseif t == "spell_not_usable" then
            if not cond.spellId then return false end
            local usable, noMana = IsUsableSpell(cond.spellId)
            return not usable or noMana == true

        elseif t == "item_equipped" then
            if not cond.slot then return false end
            local equipped = GetInventoryItemID("player", cond.slot)
            if cond.itemId then return equipped == cond.itemId end
            return equipped ~= nil
        elseif t == "item_not_equipped" then
            if not cond.slot then return false end
            local equipped = GetInventoryItemID("player", cond.slot)
            if cond.itemId then return equipped ~= cond.itemId end
            return equipped == nil

        elseif t == "unit_in_range" then
            local unit2 = cond.unit or "target"
            if not UnitExists(unit2) then return false end
            if cond.spellId or cond.spellName then
                local spell = cond.spellName or cond.spellId
                local inRange = spell and IsSpellInRange(spell, unit2)
                return inRange == 1
            end
            local dist = cond.value or 1
            return CheckInteractDistance and CheckInteractDistance(unit2, dist) or false
        elseif t == "unit_not_in_range" then
            local unit2 = cond.unit or "target"
            if not UnitExists(unit2) then return true end
            if cond.spellId or cond.spellName then
                local spell = cond.spellName or cond.spellId
                local inRange = spell and IsSpellInRange(spell, unit2)
                return inRange ~= 1
            end
            return not (CheckInteractDistance and CheckInteractDistance(unit2, cond.value or 1))

        elseif t == "target_is_boss" then
            if not UnitExists("target") then return false end
            local c = UnitClassification("target")
            return c == "worldboss" or c == "rareelite" or c == "elite"
        elseif t == "target_is_npc" then
            return UnitExists("target") and not UnitIsPlayer("target")
        elseif t == "target_is_elite" then
            if not UnitExists("target") then return false end
            local c = UnitClassification("target")
            return c == "elite" or c == "rareelite" or c == "worldboss"
        elseif t == "target_level_above" then
            if not UnitExists("target") then return false end
            local lvl = UnitLevel("target")
            return lvl and (lvl == -1 or lvl > (cond.value or 60))
        elseif t == "target_level_below" then
            if not UnitExists("target") then return false end
            local lvl = UnitLevel("target")
            return lvl and lvl > 0 and lvl < (cond.value or 60)

        elseif t == "party_member_hp_below" then
            for i = 1, 4 do
                local pu = "party" .. i
                if UnitExists(pu) and not UnitIsDead(pu) then
                    local hp, mx = UnitHealth(pu), UnitHealthMax(pu)
                    if mx and mx > 0 and (hp / mx * 100) < (cond.value or 30) then return true end
                end
            end
            return false
        elseif t == "all_party_alive" then
            for i = 1, 4 do
                local pu = "party" .. i
                if UnitExists(pu) and UnitIsDead(pu) then return false end
            end
            return true
        elseif t == "someone_dead" then
            for i = 1, GetNumGroupMembers() do
                local ru = IsInRaid() and "raid"..i or "party"..i
                if UnitExists(ru) and UnitIsDead(ru) then return true end
            end
            return false

        elseif t == "has_full_hp" then
            local hp, mx = UnitHealth("player"), UnitHealthMax("player")
            return mx and mx > 0 and hp >= mx
        elseif t == "is_moving" then
            return GetUnitSpeed and GetUnitSpeed("player") > 0
        elseif t == "has_mana" then
            local mana = UnitPower("player", 0)
            local maxm = UnitPowerMax("player", 0)
            if cond.usePercent and maxm and maxm > 0 then
                return (mana / maxm * 100) >= (cond.value or 10)
            end
            return mana >= (cond.value or 100)

        elseif t == "potion_not_used" then
            if not RC.CustomReminders or not RC.CustomReminders.combatStartTime then return false end
            local lastPot = RC.CustomReminders.lastPotionTime or 0
            return lastPot < RC.CustomReminders.combatStartTime
        elseif t == "cooldowns_synced" then
            if not cond.spellId or not cond.spellId2 then return false end
            local s1, d1 = GetSpellCooldown(cond.spellId)
            local s2, d2 = GetSpellCooldown(cond.spellId2)
            local r1 = not s1 or s1 == 0 or (s1 + d1 - GetTime()) <= 0
            local r2 = not s2 or s2 == 0 or (s2 + d2 - GetTime()) <= 0
            return r1 and r2
        -- ttk_pace_slow / ttk_pace_fast are handled with pace_slower /
        -- pace_faster above (the same test under two names)

        elseif t == "stat_ap_above" then
            local base, pos = UnitAttackPower("player")
            return (base + pos) > (cond.value or 0)
        elseif t == "stat_ap_below" then
            local base, pos = UnitAttackPower("player")
            return (base + pos) < (cond.value or 0)
        elseif t == "stat_crit_above" then
            local crit = GetCritChance and GetCritChance() or 0
            return crit > (cond.value or 0)
        elseif t == "stat_crit_below" then
            local crit = GetCritChance and GetCritChance() or 0
            return crit < (cond.value or 0)
        elseif t == "stat_hit_above" then
            local hit = GetHitModifier and GetHitModifier() or 0
            return hit > (cond.value or 0)
        elseif t == "stat_hit_below" then
            local hit = GetHitModifier and GetHitModifier() or 0
            return hit < (cond.value or 0)

        elseif t == "weapon_has_enchant" then
            local mhEnch, _, _, _, ohEnch = GetWeaponEnchantInfo()
            local slot = cond.slot or 16
            if slot == 16 then return mhEnch == 1 end
            if slot == 17 then return ohEnch == 1 end
            return false
        elseif t == "weapon_no_enchant" then
            local mhEnch, _, _, _, ohEnch = GetWeaponEnchantInfo()
            local slot = cond.slot or 16
            if slot == 16 then return not mhEnch or mhEnch ~= 1 end
            if slot == 17 then return not ohEnch or ohEnch ~= 1 end
            return false

        elseif t == "target_cast_remaining_below" then
            local name, _, _, startMs, endMs = UnitCastingInfo("target")
            if not name then
                name, _, _, startMs, endMs = UnitChannelInfo("target")
            end
            if not name or not endMs then return false end
            local remaining = (endMs - GetTime()*1000) / 1000
            return remaining < (cond.value or 1)
        elseif t == "target_cast_remaining_above" then
            local name, _, _, startMs, endMs = UnitCastingInfo("target")
            if not name then
                name, _, _, startMs, endMs = UnitChannelInfo("target")
            end
            if not name or not endMs then return false end
            local remaining = (endMs - GetTime()*1000) / 1000
            return remaining > (cond.value or 1)

        elseif t == "gcd_active" then
            local start, duration = GetSpellCooldown(78)
            if not start or start == 0 then return false end
            return (start + duration - GetTime()) > 0 and duration <= 1.5
        elseif t == "gcd_not_active" then
            local start, duration = GetSpellCooldown(78)
            if not start or start == 0 then return true end
            return (start + duration - GetTime()) <= 0 or duration > 1.5
        end

        return false
    end

    local function PassesExtraConditions(r)
        if not r.extraConditions or #r.extraConditions == 0 then return true end
        for _, cond in ipairs(r.extraConditions) do
            if not EvalCondition(cond) then return false end
        end
        return true
    end

    -- Sandbox for user-authored "lua" mode rules: loadstring+setfenv below
    -- runs the code with only this whitelist, no access to real _G.
    local SAFE_ENV = {
        math=math, string=string, table=table,
        tostring=tostring, tonumber=tonumber, pairs=pairs, ipairs=ipairs,
        type=type, select=select, unpack=unpack, GetTime=GetTime,
        UnitExists=UnitExists, UnitName=UnitName, UnitClass=UnitClass,
        UnitHealth=UnitHealth, UnitHealthMax=UnitHealthMax,
        UnitPower=UnitPower, UnitPowerMax=UnitPowerMax,
        UnitBuff=UnitBuff, UnitDebuff=UnitDebuff,
        UnitIsDead=UnitIsDead, UnitIsDeadOrGhost=UnitIsDeadOrGhost,
        UnitAffectingCombat=UnitAffectingCombat,
        UnitAttackSpeed=UnitAttackSpeed, UnitLevel=UnitLevel,
        UnitGUID=UnitGUID, UnitIsPlayer=UnitIsPlayer,
        UnitIsEnemy=UnitIsEnemy, UnitIsFriend=UnitIsFriend,
        GetSpellCooldown=GetSpellCooldown, GetSpellInfo=GetSpellInfo,
        GetSpellTexture=GetSpellTexture,
        GetInventoryItemID=GetInventoryItemID,
        GetItemCount=GetItemCount, GetItemInfo=GetItemInfo,
        GetItemIcon=GetItemIcon,
        IsInRaid=IsInRaid, IsInGroup=IsInGroup,
        GetNumGroupMembers=GetNumGroupMembers,
        GetNumPartyMembers=GetNumPartyMembers,
        IsInInstance=IsInInstance,
        WR_class      = function() local _,c=UnitClass("player") return c end,
        WR_spec       = function() return RC.specDetection and RC.specDetection.currentSpec end,
        WR_isWarrior  = function() local _,c=UnitClass("player") return c=="WARRIOR" end,
        WR_rage       = function() return UnitPower("player",1) or 0 end,
        WR_mana       = function() return UnitPower("player",0) or 0 end,
        WR_energy     = function() return UnitPower("player",3) or 0 end,
        WR_combo      = function() return UnitPower("player",4) or 0 end,
        WR_healthPct  = function(unit)
            unit = unit or "player"
            local hp,mx=UnitHealth(unit),UnitHealthMax(unit)
            return mx and mx>0 and (hp/mx*100) or 0
        end,
        WR_hasBuff    = function(unit,sid)
            local f=FindAura(unit or "player",sid,false)
            return f
        end,
        WR_hasDebuff  = function(unit,sid)
            local f=FindAura(unit or "player",sid,true)
            return f
        end,
        WR_cdReady    = function(sid)
            local s,d=GetSpellCooldown(sid)
            if not s then return false end
            return s==0 or (s+d-GetTime())<=0
        end,
        WR_realtimeTTK = function()
            local ttk = TTKLeft()
            return ttk and math.floor(ttk) or nil
        end,
        WR_predictedTTK = function()
            local fight = RC.executeCalculator and RC.executeCalculator.currentFight
            if not fight or not fight.raidName then return nil end
            if RC.GetFightExpectedTTK and fight.started then
                return (RC:GetFightExpectedTTK(fight))
            end
            return RC.PredictTTK and select(1, RC:PredictTTK(fight.raidName, fight.encounterName, fight.hasSayge))
        end,
        WR_fightDuration = function()
            return CR.combatStartTime and (GetTime() - CR.combatStartTime) or 0
        end,
        WR_inCombat   = function() return UnitAffectingCombat("player") and true or false end,
        WR_inRaid     = function() return IsInRaid() end,
        WR_inGroup    = function() return IsInGroup() end,
        WR_inInstance = function() return IsInInstance() end,
        WR_isCasting  = function(unit)
            unit=unit or "player"
            return UnitCastingInfo(unit) ~= nil or UnitChannelInfo(unit) ~= nil
        end,
        WR_castingSpell = function(unit)
            unit=unit or "player"
            return UnitCastingInfo(unit) or UnitChannelInfo(unit)
        end,
        WR_targetCanInterrupt = function()
            local _, _, _, _, _, _, _, notInterruptible = UnitCastingInfo("target")
            return UnitCastingInfo("target") ~= nil and not notInterruptible
        end,
        WR_stance     = function() return GetShapeshiftForm and GetShapeshiftForm() or 0 end,
        WR_inBattle   = function() return GetShapeshiftForm and GetShapeshiftForm()==1 end,
        WR_inDefensive= function() return GetShapeshiftForm and GetShapeshiftForm()==2 end,
        WR_inBerserker= function() return GetShapeshiftForm and GetShapeshiftForm()==3 end,
        WR_spellUsable = function(sid)
            if not sid then return false end
            local usable, noMana = IsUsableSpell(sid)
            local s, d = GetSpellCooldown(sid)
            return usable and not (s and s > 0 and d and d > 1.5)
        end,
        WR_equipped   = function(slot)
            return slot and GetInventoryItemID("player", slot)
        end,
        WR_itemCount  = function(itemId)
            return itemId and GetItemCount(itemId, false) or 0
        end,
        WR_inRange    = function(unit, spell)
            if not UnitExists(unit or "target") then return false end
            if spell then return IsSpellInRange(spell, unit or "target") == 1 end
            return CheckInteractDistance and CheckInteractDistance(unit or "target", 4) or false
        end,
        WR_targetIsElite = function()
            if not UnitExists("target") then return false end
            local c = UnitClassification("target")
            return c=="elite" or c=="rareelite" or c=="worldboss"
        end,
        WR_targetLevel = function() return UnitExists("target") and UnitLevel("target") or 0 end,
        WR_targetIsNPC = function() return UnitExists("target") and not UnitIsPlayer("target") end,
        WR_partyCount = function() return GetNumGroupMembers() end,
        WR_anyPartyDead = function()
            for i=1,4 do local u="party"..i; if UnitExists(u) and UnitIsDead(u) then return true end end
            return false
        end,
        WR_lowestPartyHP = function()
            local lowest=100
            for i=1,4 do
                local u="party"..i
                if UnitExists(u) and not UnitIsDead(u) then
                    local hp,mx=UnitHealth(u),UnitHealthMax(u)
                    if mx and mx>0 then
                        local pct=hp/mx*100
                        if pct<lowest then lowest=pct end
                    end
                end
            end
            return lowest
        end,
        WR_isMoving   = function() return GetUnitSpeed and GetUnitSpeed("player") > 0 end,
    }
    SAFE_ENV._G = SAFE_ENV

    local function CompileLua(r)
        if not r.lua or not r.lua.code or r.lua.code == "" then return false,"No code" end
        local chunk, err = loadstring("return function()\n" .. r.lua.code .. "\nend")
        if not chunk then return false, err end
        if setfenv then setfenv(chunk, SAFE_ENV) end
        local ok, fn = pcall(chunk)
        if not ok or type(fn) ~= "function" then return false, tostring(fn) end
        if setfenv then setfenv(fn, SAFE_ENV) end
        r.lua.compiledFn = fn
        r.lua.lastError  = nil
        r.lua.errorCount = 0
        return true
    end

    local function EvalLua(r)
        if not r.lua then return false end
        if not r.lua.compiledFn then
            local ok, err = CompileLua(r)
            if not ok then
                r.lua.lastError  = err
                r.lua.errorCount = (r.lua.errorCount or 0) + 1
                return false
            end
        end
        -- After 5 consecutive runtime errors the rule stops evaluating
        -- entirely until RecompileCustomReminder is called manually.
        if (r.lua.errorCount or 0) >= 5 then return false end
        local ok, result = pcall(r.lua.compiledFn)
        if not ok then
            r.lua.lastError  = tostring(result)
            r.lua.errorCount = (r.lua.errorCount or 0) + 1
            return false
        end
        r.lua.errorCount = 0
        return result == true
    end

    -- seq.step persists in the saved reminder across ticks and loops back
    -- to 1 after the last step fires; ResetSequences below is the only
    -- thing that rewinds it mid-loop.
    local function EvalSequence(r)
        local seq = r.sequence
        if not seq or not seq.steps or #seq.steps == 0 then return end
        seq.step      = seq.step or 1
        seq.stepEnter = seq.stepEnter or GetTime()
        if seq.step > #seq.steps then return end
        local step = seq.steps[seq.step]
        local fired = false
        if step.type == "on_combat_start" then
            fired = CR.combatStartTime ~= nil and (GetTime() - CR.combatStartTime) < 3
        elseif step.type == "timer" then
            fired = (GetTime() - seq.stepEnter) >= (step.delay or 0)
        elseif step.type == "condition" then
            fired = step.condition and EvalCondition(step.condition)
        end
        if fired then
            local savedMsg = r.message
            if step.message and step.message ~= "" then r.message = step.message end
            FireReminder(r)
            r.message = savedMsg
            seq.step      = seq.step + 1
            seq.stepEnter = GetTime()
            if seq.step > #seq.steps then seq.step = 1; seq.stepEnter = nil end
        end
    end

    -- Every new combat restarts every sequence reminder from step 1
    -- (called from PLAYER_REGEN_DISABLED below).
    local function ResetSequences()
        for _, r in ipairs(RC.db.customReminders.reminders) do
            if r.mode == "sequence" and r.sequence then
                r.sequence.step      = 1
                r.sequence.stepEnter = nil
            end
        end
    end

    local function EvaluateAll()
        local reminders = RC.db.customReminders and RC.db.customReminders.reminders
        if not reminders or #reminders == 0 then
            if RC.StopCustomReminderTicker then RC:StopCustomReminderTicker() end
            return
        end
        local hasAnyEnabled = false
        for i = 1, #reminders do
            if reminders[i].enabled then hasAnyEnabled = true; break end
        end
        if not hasAnyEnabled then
            if RC.StopCustomReminderTicker then RC:StopCustomReminderTicker() end
            return
        end

        if CR.sortDirty then
            table.sort(RC.db.customReminders.reminders, function(a,b)
                return (a.priority or 5) < (b.priority or 5)
            end)
            CR.sortDirty = false
        end
        for _, r in ipairs(RC.db.customReminders.reminders) do
            if not r.enabled then
            elseif not PassesLoad(r) then
            elseif not PassesScope(r) then
            else
                local mode = r.mode or "aura"
                local triggered = false

                if mode == "aura" then
                    triggered = EvalAura(r)
                elseif mode == "cooldown" then
                    triggered = EvalCooldown(r)
                elseif mode == "health" then
                    triggered = EvalHealth(r)
                elseif mode == "equipment" then
                    triggered = EvalEquipment(r)
                elseif mode == "resource" then
                    triggered = EvalResource(r)
                elseif mode == "status" then
                    triggered = EvalStatus(r)
                elseif mode == "condition" then
                    if r.conditions and #r.conditions > 0 then
                        triggered = true
                        for _, cond in ipairs(r.conditions) do
                            if not EvalCondition(cond) then triggered = false; break end
                        end
                    end
                elseif mode == "lua" then
                    triggered = EvalLua(r)
                elseif mode == "periodic" then
                    local interval = r.periodic and r.periodic.intervalSec or 30
                    triggered = (GetTime() - (r.lastFired or 0)) >= interval
                end

                -- "event" mode never sets triggered above (no case for it
                -- in the if-chain); it fires only through this flag, set
                -- once per qualifying frame event by HandleFrameEvent and
                -- consumed here on the next 0.5s tick.
                if CR.eventReminders[r.id] then
                    triggered = true
                    CR.eventReminders[r.id] = nil
                end

                if not triggered
                   and mode ~= "event" and mode ~= "periodic" and mode ~= "sequence"
                then
                    -- untrigger ~= "auto" keeps an aura reminder on screen
                    -- after its condition clears; every other mode always
                    -- hides once its trigger goes false.
                    local shouldHide = true
                    if mode == "aura" then
                        local cfg = r.aura
                        shouldHide = cfg and (cfg.untrigger == "auto" or not cfg.untrigger) or false
                    end
                    if shouldHide then
                        local key = "custom_" .. r.id
                        if RC.activeReminderData and RC.activeReminderData.abilities then
                            for _, a in ipairs(RC.activeReminderData.abilities) do
                                if a == key then
                                    RC:HideReminder()
                                    break
                                end
                            end
                        end
                    end
                end

                local onCD = IsOnCooldown(r)
                local ttkOnce = (mode == "condition") and not r.continuous and HasTTKCondition(r)
                local thisFight = ttkOnce and RC.executeCalculator and RC.executeCalculator.currentFight
                if ttkOnce and thisFight and CR.ttkFiredFight[r.id] == thisFight then
                    onCD = true
                end
                if mode == "sequence" then
                    if not onCD then EvalSequence(r) end
                elseif mode == "periodic" then
                    if triggered and PassesExtraConditions(r) then
                        FireReminder(r)
                    end
                elseif not onCD and triggered and PassesExtraConditions(r) then
                    if ttkOnce and thisFight then CR.ttkFiredFight[r.id] = thisFight end
                    if r.continuous then
                        -- Backdates lastFired so the cooldown gate reopens
                        -- after ~0.6s instead of the full cooldown, giving
                        -- a near-continuous re-fire pulse while true.
                        local savedDur = r.duration
                        r.duration = 1
                        FireReminder(r)
                        r.duration = savedDur
                        r.lastFired = GetTime() - (r.cooldown or 10) + 0.6
                    else
                        FireReminder(r)
                    end
                end
            end
        end
    end

    local POTION_SPELL_IDS = {
        [13442] = true, [13443] = true, [13444] = true, [13446] = true,
        [13510] = true, [3928]  = true, [6149]  = true, [6150]  = true,
        [9030]  = true, [17531] = true, [17538] = true, [9156]  = true,
    }

    local potionTrackFrame = CreateFrame("Frame")
    potionTrackFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    potionTrackFrame:SetScript("OnEvent", function(_, _, _, _, spellId)
        if not spellId then return end
        local isPot = POTION_SPELL_IDS[spellId]
            or (RC.flavorPotionSpellIds and RC.flavorPotionSpellIds[spellId])
        if not isPot and RC.IsCombatPotion then
            isPot = RC:IsCombatPotion(spellId)
        end
        if isPot and RC.CustomReminders then
            RC.CustomReminders.lastPotionTime = GetTime()
        end
    end)

    local frameEventFrame = CreateFrame("Frame")
    local registeredFrameEvents = {}

    local function HandleFrameEvent(_, event, ...)
        for _, r in ipairs(RC.db.customReminders.reminders) do
            if r.enabled and r.mode == "event" and r.eventTrigger then
                local cfg = r.eventTrigger
                if cfg.eventCategory == "frame" then
                    local evName = cfg.customEvent and cfg.customEvent ~= "" and cfg.customEvent or cfg.frameEvent
                    if evName == event then
                        local textPass = true
                        if cfg.textMatch and cfg.textMatch ~= "" then
                            local arg1 = tostring((...) or ""):lower()
                            if not arg1:find(cfg.textMatch:lower(), 1, true) then
                                textPass = false
                            end
                        end
                        local unitPass = true
                        if cfg.unitFilter and cfg.unitFilter ~= "" and event:find("^UNIT_") then
                            local eventUnit = (...)
                            if eventUnit ~= cfg.unitFilter then unitPass = false end
                        end
                        local spellPass = true
                        if cfg.spellId and event:find("SPELLCAST") then
                            local _, _, castSpell = ...
                            if castSpell ~= cfg.spellId then spellPass = false end
                        end
                        if textPass and unitPass and spellPass
                           and PassesLoad(r) and PassesScope(r) and not IsOnCooldown(r) then
                            CR.eventReminders[r.id] = true
                        end
                    end
                end
            end
        end
    end
    frameEventFrame:SetScript("OnEvent", HandleFrameEvent)

    function RC:RefreshCustomReminderEvents()
        for evt, _ in pairs(registeredFrameEvents) do
            frameEventFrame:UnregisterEvent(evt)
        end
        wipe(registeredFrameEvents)

        -- Scoping to specific unit tokens via RegisterUnitEvent (instead
        -- of RegisterEvent) cuts handler calls for events users can pick
        -- here, including high-frequency ones like UNIT_AURA. Either way
        -- HandleFrameEvent only records a flag; it never scans inline.
        local UNIT_SCOPABLE = {
            UNIT_HEALTH=true, UNIT_POWER_UPDATE=true, UNIT_AURA=true,
            UNIT_SPELLCAST_SUCCEEDED=true, UNIT_SPELLCAST_START=true,
            UNIT_SPELLCAST_STOP=true, UNIT_SPELLCAST_FAILED=true,
            UNIT_SPELLCAST_INTERRUPTED=true, UNIT_SPELLCAST_CHANNEL_STOP=true,
        }

        local eventFilters = {}
        for _, r in ipairs(RC.db.customReminders.reminders) do
            if r.enabled and r.mode == "event" and r.eventTrigger then
                local cfg = r.eventTrigger
                if cfg.eventCategory == "frame" then
                    local evName = cfg.customEvent and cfg.customEvent ~= "" and cfg.customEvent or cfg.frameEvent
                    if evName and evName ~= "" then
                        local slot = eventFilters[evName]
                        if not slot then
                            slot = { units = {}, anyWildcard = false }
                            eventFilters[evName] = slot
                        end
                        if cfg.unitFilter and cfg.unitFilter ~= "" then
                            slot.units[cfg.unitFilter] = true
                        else
                            slot.anyWildcard = true
                        end
                    end
                end
            end
        end

        for evName, slot in pairs(eventFilters) do
            local ok
            if UNIT_SCOPABLE[evName] and not slot.anyWildcard and next(slot.units) then
                local list = {}
                for u in pairs(slot.units) do list[#list+1] = u end
                ok = pcall(function() frameEventFrame:RegisterUnitEvent(evName, unpack(list)) end)
                if ok then RC:DebugPrint("CustomReminders: scoped " .. evName .. " to " .. table.concat(list, ","), "trigger") end
            else
                ok = pcall(function() frameEventFrame:RegisterEvent(evName) end)
                if ok then RC:DebugPrint("CustomReminders: registered frame event " .. evName, "trigger") end
            end
            if ok then
                registeredFrameEvents[evName] = true
            end
        end
    end

    local stateFrame = CreateFrame("Frame")
    stateFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    stateFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    stateFrame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            CR.combatStartTime = GetTime()
            ResetSequences()
            RC:StartCustomReminderTicker()
        elseif event == "PLAYER_REGEN_ENABLED" then
            CR.combatStartTime = nil
        end
    end)

    function RC:StartCustomReminderTicker()
        if CR.ticker then return end
        if RC.Profiler and RC.Profiler.TrackTicker then
            CR.ticker = RC.Profiler:TrackTicker("CustomReminders:EvaluateAll", 0.5, EvaluateAll)
        else
            CR.ticker = C_Timer.NewTicker(0.5, EvaluateAll)
        end
        RC:DebugPrint("CustomReminders: ticker started", "trigger")
    end
    function RC:StopCustomReminderTicker()
        if CR.ticker then CR.ticker:Cancel(); CR.ticker = nil end
    end
    function RC:KickCustomReminderTicker()
        if not CR.ticker then self:StartCustomReminderTicker() end
    end

    function RC:CreateCustomReminder(name, mode)
        local db = self.db.customReminders
        local id = "cr_" .. db.nextId
        db.nextId = db.nextId + 1
        local r = {
            id=id, name=name or "New Reminder", enabled=true,
            icon="", iconSpellId=nil, iconItemId=nil,
            message="", soundKey="", soundFile="", duration=5, cooldown=10, lastFired=0,
            ttsEnabled=false, ttsText="",
            continuous=false,
            priority=5,
            animationType=nil,
            mode=mode or "aura",
            periodic     = {intervalSec=30},
            equipment    = {slot=16, condition="not_equipped", itemId=nil, value=nil},
            loadClass=nil, loadGroup=nil, loadZone=nil, loadSpec=nil,
            scope="any", bossKey=nil, customNpcIds={},
            aura         = {unit="player", buffType="buff", spellId=nil, condition="missing", expiresIn=5, stackValue=1},
            cdConfig     = {spellId=nil, itemId=nil, condition="ready", threshold=5},
            health       = {unit="player", op="<", value=30},
            resource     = {unit="player", powerType=1, op=">", value=80, usePercent=false},
            status       = {type="in_combat"},
            eventTrigger = {eventCategory="frame", frameEvent="RAID_BOSS_EMOTE", customEvent="", textMatch="", unitFilter="", spellId=nil},
            conditions   = {},
            extraConditions = {},
            sequence     = {step=1, steps={}},
            lua          = {code="-- return true to fire the reminder\nreturn false", compiledFn=nil, lastError=nil, errorCount=0},
        }
        table.insert(db.reminders, r)
        self:SaveConfigurationToProfile()
        if self.RefreshCustomReminderEvents then self:RefreshCustomReminderEvents() end
        if RC.CustomReminders then RC.CustomReminders.sortDirty = true; RC.CustomReminders.hasEventReminders = nil end
        self:KickCustomReminderTicker()
        return r
    end

    function RC:DeleteCustomReminder(id)
        local db = self.db.customReminders
        for i, r in ipairs(db.reminders) do
            if r.id == id then
                table.remove(db.reminders, i)
                RC.abilityData["custom_"..id] = nil
                self:SaveConfigurationToProfile()
                if self.RefreshCustomReminderEvents then self:RefreshCustomReminderEvents() end
                return true
            end
        end
        return false
    end

    function RC:GetCustomReminder(id)
        for _, r in ipairs(self.db.customReminders.reminders) do
            if r.id == id then return r end
        end
        return nil
    end

    function RC:DuplicateCustomReminder(id)
        local src = self:GetCustomReminder(id)
        if not src then return nil end
        local db   = self.db.customReminders
        local copy = RC.DeepCopy(src)
        copy.id   = "cr_" .. db.nextId
        db.nextId = db.nextId + 1
        copy.name = (copy.name or "Reminder") .. " (copy)"
        copy.lastFired = 0
        if copy.lua then copy.lua.compiledFn=nil; copy.lua.errorCount=0 end
        if copy.sequence then copy.sequence.step=1; copy.sequence.stepEnter=nil end
        table.insert(db.reminders, copy)
        self:SaveConfigurationToProfile()
        self:KickCustomReminderTicker()
        return copy
    end

    function RC:RecompileCustomReminder(id)
        local r = self:GetCustomReminder(id)
        if r and r.lua then
            r.lua.compiledFn=nil; r.lua.errorCount=0; r.lua.lastError=nil
            CompileLua(r)
        end
    end

    function RC:TestFireCustomReminder(id)
        local r = self:GetCustomReminder(id)
        if r then
            local saved=r.lastFired; r.lastFired=0
            FireReminder(r)
            r.lastFired=saved
        end
    end

    RC.customReminderPresets = {
        {key="execute_burn", name="Execute Burn Window",
         description=RCL["Death Wish + Recklessness both ready AND target below 20%"],
         icon="Interface\\Icons\\Ability_Warrior_Rampage",
         build=function()
             return {mode="condition", message=RCL["BURN  -  Death Wish + Reck!"],
                 duration=10, cooldown=30, scope="any",
                 loadClass="WARRIOR",
                 conditions={
                     {type="hp_below",unit="target",value=20},
                     {type="cooldown_ready",spellId=12328},
                     {type="cooldown_ready",spellId=1719},
                 }}
         end},
        {key="cooldown_sync", name="Cooldown Sync",
         description=RCL["Death Wish and Recklessness both off cooldown"],
         icon="Interface\\Icons\\Ability_CriticalStrike",
         build=function()
             return {mode="condition", message=RCL["Death Wish + Reck both ready!"],
                 duration=8, cooldown=15, scope="any",
                 loadClass="WARRIOR",
                 conditions={
                     {type="cooldown_ready",spellId=12328},
                     {type="cooldown_ready",spellId=1719},
                     {type="in_combat"},
                 }}
         end},
        {key="low_mana", name="Low Mana Warning",
         description=RCL["Mana below 20%  -  works for any caster"],
         icon="Interface\\Icons\\Spell_Holy_SealOfWisdom",
         build=function()
             return {mode="resource", message=RCL["Low mana!"],
                 duration=4, cooldown=8,
                 resource={unit="player", powerType=0, op="<", value=20, usePercent=true}}
         end},
        {key="rage_cap", name="Rage Cap",
         description=RCL["Rage above 90  -  dump it before it caps"],
         icon="Interface\\Icons\\Ability_Racial_BloodRage",
         build=function()
             return {mode="resource", message=RCL["RAGE CAP  -  dump it!"],
                 duration=3, cooldown=4,
                 loadClass="WARRIOR",
                 resource={unit="player", powerType=1, op=">", value=90, usePercent=false}}
         end},
        {key="target_low_hp", name="Target Low Health",
         description=RCL["Target below 20% HP  -  for any class execute/burn phase"],
         icon="Interface\\Icons\\Ability_Warrior_Savageblow",
         build=function()
             return {mode="health", message=RCL["Target low  -  burn!"],
                 duration=5, cooldown=10,
                 health={unit="target", op="<", value=20}}
         end},
        {key="buff_missing_demo", name="Missing Buff Alert",
         description=RCL["Alert when a buff is missing  -  edit spell ID for your buff"],
         icon="Interface\\Icons\\Spell_Nature_AncientWard",
         build=function()
             return {mode="aura", message=RCL["Buff missing!"],
                 duration=6, cooldown=30,
                 aura={unit="player", buffType="buff", spellId=22888, condition="missing"}}
         end},
        {key="spell_cast_react", name="Spell Cast Reaction",
         description=RCL["React when you successfully cast a spell  -  edit event + spell ID"],
         icon="Interface\\Icons\\Spell_Holy_HolyBolt",
         build=function()
             return {mode="event", message=RCL["Spell cast!"],
                 duration=3, cooldown=2,
                 eventTrigger={event="SPELL_CAST_SUCCESS", spellId=nil, source="player", dest=""}}
         end},
        {key="opener_chain", name="Opener Sequence",
         description=RCL["Timed opener: combat start, 1s, 5s, then execute burn"],
         icon="Interface\\Icons\\Spell_Shadow_DeathPact",
         build=function()
             return {mode="sequence", message=RCL["Opener"],
                 duration=4, cooldown=180, loadClass="WARRIOR",
                 sequence={step=1, steps={
                     {type="on_combat_start", delay=0,  message=RCL["Prepot NOW!"]},
                     {type="timer",           delay=1,  message=RCL["Death Wish + Reck!"]},
                     {type="timer",           delay=4,  message=RCL["Trinket!"]},
                     {type="condition", delay=nil, message="BURN!",
                      condition={type="hp_below", unit="target", value=20}},
                 }}}
         end},
        {key="gear_mh_no_enchant", name="Missing MH Enchant",
         description=RCL["Main hand weapon has no temporary enchant (stone/oil/elixir). Fires out of combat."],
         icon="Interface\\Icons\\INV_Stone_SharpeningStone_05",
         build=function() return {mode="equipment",
             message=RCL["No Main Hand enchant  -  apply one!"],
             duration=8, cooldown=60, priority=2,
             equipment={slot=16, condition="no_temp_enchant"},
             filters={inCombat=false},
         } end},
        {key="gear_oh_no_enchant", name="Missing OH Enchant",
         description=RCL["Off hand weapon has no temporary enchant. Fires out of combat."],
         icon="Interface\\Icons\\INV_Stone_SharpeningStone_05",
         build=function() return {mode="equipment",
             message=RCL["No Off Hand enchant  -  apply one!"],
             duration=8, cooldown=60, priority=2,
             equipment={slot=17, condition="no_temp_enchant"},
             filters={inCombat=false},
         } end},
        {key="gear_trinket1_ready", name="Trinket 1 Ready",
         description=RCL["Trinket in slot 13 is off cooldown  -  fire it!"],
         icon="Interface\\Icons\\inv_trinket_naxxramas03",
         build=function() return {mode="equipment",
             message=RCL["Trinket ready  -  use it!"],
             duration=5, cooldown=2, priority=3,
             equipment={slot=13, condition="item_ready"},
             filters={inCombat=true},
         } end},
        {key="gear_wrong_ring", name="Wrong Ring Equipped",
         description=RCL["Alert if a specific item is NOT in your Ring 1 slot. Set the Item ID in the trigger."],
         icon="Interface\\Icons\\INV_Jewelry_Ring_36",
         build=function() return {mode="equipment",
             message=RCL["Wrong ring! Check Ring 1."],
             duration=8, cooldown=60, priority=1,
             equipment={slot=11, condition="not_equipped", itemId=nil},
             filters={inCombat=false},
         } end},
        {key="warrior_rage_cap", name="Rage Cap Warning",
         description=RCL["Rage above 90  -  dump it now."],
         icon="Interface\\Icons\\Ability_Racial_BloodRage",
         build=function() return {mode="resource",
             message=RCL["RAGE CAP  -  Heroic Strike / Cleave!"],
             duration=3, cooldown=5, priority=4, loadClass="WARRIOR",
             resource={unit="player", powerType=1, op=">", value=90},
             filters={inCombat=true},
         } end},
        {key="stat_low_hit", name="Low Hit Rating",
         description=RCL["Fire out of combat when hit rating is below a threshold. Edit threshold in trigger."],
         icon="Interface\\Icons\\Ability_Marksmanship",
         build=function() return {mode="equipment",
             message=RCL["Hit rating low  -  check gear!"],
             duration=8, cooldown=120, priority=2,
             equipment={slot=16, condition="stat_hit_below", value=300},
             filters={inCombat=false},
         } end},
    }

    function RC:InstallPreset(key)
        local preset
        for _, p in ipairs(RC.customReminderPresets) do
            if p.key == key then preset=p; break end
        end
        if not preset then return nil end
        local base = preset.build()
        local db   = self.db.customReminders
        local id   = "cr_" .. db.nextId
        db.nextId  = db.nextId + 1
        local r = self:CreateCustomReminder(preset.name, base.mode)
        r.id = id
        table.remove(db.reminders)
        for k, v in pairs(base) do r[k] = v end
        r.id        = id
        r.name      = preset.name
        r.enabled   = false
        r.isPreset  = true
        r.presetKey = key
        r.lastFired = 0
        if r.lua then r.lua.compiledFn=nil end
        if r.sequence then r.sequence.step=1; r.sequence.stepEnter=nil end
        table.insert(db.reminders, r)
        self:SaveConfigurationToProfile()
        return r
    end

    function RC:ListCustomReminders()
        local reminders = self.db.customReminders.reminders
        if #reminders == 0 then
            self:Print(RCL["No custom reminders. Open /rc > Custom Reminders to create one."])
            return
        end
        self:Print(RCL["|cFFFFD700Custom Reminders ("] .. #reminders .. "):|r")
        for _, r in ipairs(reminders) do
            local s = r.enabled and "|cFF44FF44ON|r" or "|cFF888888off|r"
            local pri = r.priority and ("[P"..r.priority.."]") or ""
            self:Print(string.format(RCL["  [%s] %s %s - mode: %s  cd: %ds"], s, pri, r.name or r.id, r.mode or "?", r.cooldown or 10))
        end
    end

    local function SerializeVal(v, depth)
        depth = depth or 0
        if depth > 8 then return "nil" end
        local t = type(v)
        if t == "nil"     then return "nil"
        elseif t == "boolean" then return tostring(v)
        elseif t == "number"  then return tostring(v)
        elseif t == "string"  then return string.format("%q", v)
        elseif t == "table" then
            local skip = {compiledFn=true, lastFired=true, stepEnter=true}
            local parts = {}
            local n = 0
            for k, val in pairs(v) do
                if type(k) == "number" and k == n+1 then
                    n = k; table.insert(parts, SerializeVal(val, depth+1))
                end
            end
            for k, val in pairs(v) do
                if type(k) == "string" and not skip[k] then
                    table.insert(parts, string.format("[%q]=%s", k, SerializeVal(val, depth+1)))
                elseif type(k) == "number" and k > n then
                    table.insert(parts, string.format("[%d]=%s", k, SerializeVal(val, depth+1)))
                end
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
        return "nil"
    end

    function RC:DebugEvaluateCustomReminder(id)
        local r = self:GetCustomReminder(id)
        if not r then return nil end
        local mode = r.mode or "aura"

        local triggerPass = false
        if mode=="aura"      then triggerPass = EvalAura(r)
        elseif mode=="cooldown"   then triggerPass = EvalCooldown(r)
        elseif mode=="health"     then triggerPass = EvalHealth(r)
        elseif mode=="equipment"  then triggerPass = EvalEquipment(r)
        elseif mode=="resource"   then triggerPass = EvalResource(r)
        elseif mode=="status"     then triggerPass = EvalStatus(r)
        elseif mode=="condition"  then
            triggerPass = true
            if r.conditions then
                for _, c in ipairs(r.conditions) do
                    if not EvalCondition(c) then triggerPass=false; break end
                end
            end
        elseif mode=="lua"        then triggerPass = EvalLua(r)
        elseif mode=="periodic"   then
            local interval = r.periodic and r.periodic.intervalSec or 30
            triggerPass = (GetTime() - (r.lastFired or 0)) >= interval
        elseif mode=="sequence"   then triggerPass = false
        end

        local extraPass = true
        local extraFail = nil
        if r.extraConditions and #r.extraConditions > 0 then
            for i, c in ipairs(r.extraConditions) do
                if not EvalCondition(c) then extraPass=false; extraFail=i; break end
            end
        end

        local cd = r.cooldown or 10
        local secSince = GetTime() - (r.lastFired or 0)

        return {
            enabled       = r.enabled,
            load          = PassesLoad(r),
            scope         = PassesScope(r),
            onCooldown    = IsOnCooldown(r),
            cdRemaining   = math.max(0, cd - secSince),
            trigger       = triggerPass,
            extraPass     = extraPass,
            extraFailIdx  = extraFail,
            wouldFire     = r.enabled and PassesLoad(r) and PassesScope(r) and not IsOnCooldown(r) and triggerPass and extraPass,
        }
    end

    function RC:ExportCustomReminder(id)
        local r = self:GetCustomReminder(id)
        if not r then return nil, "Not found" end
        local clean = RC.DeepCopy(r)
        clean.id = nil; clean.lastFired = 0
        if clean.lua then clean.lua.compiledFn = nil; clean.lua.errorCount = 0; clean.lua.lastError = nil end
        if clean.sequence then clean.sequence.step = 1; clean.sequence.stepEnter = nil end
        return "WR_CR:" .. SerializeVal(clean)
    end

    function RC:ImportCustomReminder(str)
        if not str or str == "" then return nil, "Empty string" end
        local data = str:match("^WR_CR:(.+)$") or str

        if #data > 65536 then
            return nil, "Import string too large"
        end

        local fn, err = loadstring("return " .. data)
        if not fn then return nil, "Parse error: " .. tostring(err) end

        setfenv(fn, {})

        local ok, tbl = pcall(fn)
        if not ok or type(tbl) ~= "table" then return nil, "Invalid data" end
        if not tbl.mode then return nil, "Not a valid WR reminder (missing mode field)" end
        local db = self.db.customReminders
        tbl.id = "cr_" .. db.nextId; db.nextId = db.nextId + 1
        tbl.name = (tbl.name or "Reminder") .. " (imported)"
        tbl.enabled = false; tbl.lastFired = 0
        if tbl.lua then tbl.lua.compiledFn = nil end
        if tbl.sequence then tbl.sequence.step = 1; tbl.sequence.stepEnter = nil end
        table.insert(db.reminders, tbl)
        self:SaveConfigurationToProfile()
        if self.RefreshCustomReminderEvents then self:RefreshCustomReminderEvents() end
        RC:DebugPrint("Imported reminder: " .. tbl.name, "config")
        return tbl
    end

    RC:StartCustomReminderTicker()
    RC:RefreshCustomReminderEvents()
    RC:DebugPrint("CustomReminders system loaded", "system")
end

InitializeCustomReminders()
