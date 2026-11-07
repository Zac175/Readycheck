------------------------------------------------------------------------
-- Readycheck - Buff Cap: the counter
-- How many of the buff slots (Classic Era's 32; another version's limit
-- is measured, see ResolveCap) are really in use. The buff bar only
-- shows part of it: a warrior's stance, the Defensive State behind
-- Revenge, tracking, the second half of some trinkets and a few worn
-- items all take a slot without an icon. This counts those, learns any
-- it cannot see from the moment a buff gets pushed off, and says which
-- buff was pushed off when it happens.
--
-- Nothing here draws anything. The stats bar (CS_Buffs.lua, CS_Bar.lua,
-- CS_BuffList.lua) shows it, and another addon can hang a buff remover
-- on it (RC.BuffCap:SetRemover - ZacUI does).
--
-- COST. It only runs while something wants it (RC.BuffCap:Want). Buff
-- changes reach it through the shared aura coordinator, which already
-- throttles them; dodges and parries (UNIT_COMBAT, combat only, and only
-- for the classes that get Defensive State) only stamp a time and queue
-- one refresh for the next frame. Worn items are read only when gear
-- changes.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
local D = RC.BuffCapData
if not D then return end

local pairs, ipairs, type, tostring, pcall = pairs, ipairs, type, tostring, pcall
local math_floor, math_max = math.floor, math.max
local table_sort, table_insert, table_remove = table.sort, table.insert, table.remove
local GetTime = GetTime
local C_Timer = C_Timer

local BC = {}
RC.BuffCap = BC

local CAP = D.CAP
BC.CAP = CAP

-- Another game version's limit (D.CAP_BY_FLAVOR), read once the flavor is
-- fixed. Where none is confirmed (TBC, Forever) CAP is nil and the limit
-- is measured instead: the slots in use when a buff gets pushed off,
-- believed once two push-offs agree, kept per character and version.
-- UNMEASURED: before that, push-offs are only looked for this close to
-- Classic Era's 32 (the lowest limit any version has).
local UNMEASURED = D.CAP
local capFlavor
local function ResolveCap()
    if capFlavor or not RC.db then return end
    capFlavor = RC.Flavor and RC:Flavor() or "era"
    if capFlavor ~= "era" then
        CAP = D.CAP_BY_FLAVOR and D.CAP_BY_FLAVOR[capFlavor] or nil
        BC.CAP = CAP
    end
end

local DEFAULTS = { countHidden = true, learn = true, chatWarn = true, barText = "used" }

-- live state
local list, map, idSet = {}, {}, {}
local hidden = {}
local rawHidden = 0
local ready = false        -- false: the next refresh must not look for push-offs
local defUntil = 0
local castUntil = {}
local wake = {}
local equipHidden, equipDirty = {}, true
local defKinds             -- the avoided-attack kinds that wake Defensive State, or nil
local playerClass, playerRace

local state = { visible = 0, hidden = 0, learned = 0, used = 0, reserved = 0, cap = CAP, free = CAP }
BC.state = state

local wanted = {}
local running = false
local queued = false
local subscribers = {}
local pushListeners = {}
local remover

------------------------------------------------------------------------
-- SETTINGS AND THE PER-CHARACTER MEMORY
------------------------------------------------------------------------
function BC:Settings()
    local c = RC.db and RC.db.buffCap
    if type(c) ~= "table" then return DEFAULTS end
    return c
end

local function On(key)
    local v = BC:Settings()[key]
    if v == nil then return DEFAULTS[key] end
    return v
end
BC.Setting = function(_, key) return On(key) end

local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- What this character has measured: the unseen hidden slots, the last
-- reading (a reading is only believed once it repeats), and the buffs
-- pushed off lately - newest first, PUSH_HISTORY of them, each with the
-- buffs that landed in the same moment (what took the slot) and where.
local function Memory()
    local db = RC.db
    if not db then return nil end
    local m = db.buffCapLearned
    if type(m) ~= "table" then
        m = {}
        db.buffCapLearned = m
    end
    if type(m.learned) ~= "number" then m.learned = 0 end
    m.learned = Clamp(math_floor(m.learned), -3, 4)
    if type(m.pushes) ~= "table" then m.pushes = {} end
    return m
end

function BC:Pushes()
    local m = Memory()
    return m and m.pushes or {}
end

function BC:ClearPushes()
    local m = Memory()
    if m then m.pushes = {} end
end

-- The measured limit of this version, { cap =, last = } (only where the
-- limit is not confirmed).
local function CapMemory()
    local m = Memory()
    if not m then return nil end
    if type(m.caps) ~= "table" then m.caps = {} end
    local fl = capFlavor or "era"
    local c = m.caps[fl]
    if type(c) ~= "table" then
        c = {}
        m.caps[fl] = c
    end
    return c
end

-- The limit in use: the confirmed one, else the measured one, else nil.
local function Limit()
    if CAP then return CAP end
    local c = CapMemory()
    return c and tonumber(c.cap) or nil
end
function BC:Limit()
    ResolveCap()
    return Limit()
end
function BC:LimitMeasured()
    ResolveCap()
    return CAP == nil
end

function BC:ResetLearned()
    local m = Memory()
    if m then
        m.learned = 0
        m.last = nil
    end
    if not CAP then
        local c = CapMemory()
        if c then c.cap, c.last = nil, nil end
    end
    BC:Request()
end

------------------------------------------------------------------------
-- READING THE GAME
------------------------------------------------------------------------
local function SpellName(id)
    if not id then return nil end
    if C_Spell and C_Spell.GetSpellName then return C_Spell.GetSpellName(id) end
    return (GetSpellInfo(id))
end
BC.SpellName = SpellName

-- From the shared aura read (RC.Auras): no buff slot is read here.
local function Scan()
    local out, byKey, ids = {}, {}, {}
    for i, b in ipairs(RC.Auras:Buffs()) do
        local name, id, src, inst = b.name, b.spellId, b.source, b.instance
        local a = { id = id, name = name, icon = b.icon, dur = b.duration, exp = b.expirationTime, src = src, idx = i,
                    inst = inst, e = (id and D.BY_ID[id]) or D.BY_NAME[name] }
        local key = inst or ((id or name) .. ":" .. tostring(src))
        if byKey[key] then key = key .. "#" .. i end
        a.key = key
        out[#out + 1] = a
        byKey[key] = a
        if id then ids[id] = true end
    end
    return out, byKey, ids
end

local function Knows(ids)
    if not ids then return false end
    for _, id in ipairs(ids) do
        if (IsPlayerSpell and IsPlayerSpell(id)) or (IsSpellKnown and IsSpellKnown(id)) then return true end
    end
    return false
end

local function ReadDefensiveKinds()
    local kinds = D.DEFENSIVE_STATE[playerClass or ""]
    if kinds and D.DEFENSIVE_NEEDS[playerClass] and not Knows(D.DEFENSIVE_NEEDS[playerClass]) then
        kinds = nil
    end
    defKinds = kinds
end

local function ReadEquipped()
    equipDirty = false
    local out = {}
    if GetInventoryItemID then
        for slot = 1, 19 do
            local item = GetInventoryItemID("player", slot)
            local labels = item and D.EQUIPPED[item]
            if labels then
                for _, label in ipairs(labels) do out[#out + 1] = label end
            end
        end
    end
    equipHidden = out
end

local function Add(out, label, src, icon, untilAt)
    out[#out + 1] = { label = label, src = src, icon = icon, untilAt = untilAt }
end

local function ComputeHidden(now)
    local out = {}
    if not On("countHidden") then return out end
    if playerClass == "WARRIOR" and GetShapeshiftForm then
        local form = GetShapeshiftForm() or 0
        if form > 0 and GetShapeshiftFormInfo then
            local icon, _, _, sid = GetShapeshiftFormInfo(form)
            if not (sid and idSet[sid]) then
                Add(out, SpellName(sid) or RCL["Stance"], "stance", icon)
            end
        end
    end
    if defUntil > now then
        Add(out, RCL["Defensive State"], "defensive", nil, defUntil)
    end
    if GetTrackingTexture then
        local tex = GetTrackingTexture()
        if tex then
            local shown = false
            for _, a in ipairs(list) do
                if (a.id and D.TRACKING[a.id]) or a.icon == tex then
                    shown = true
                    break
                end
            end
            if not shown then Add(out, RCL["Tracking"], "tracking", tex) end
        end
    end
    if playerClass == "DRUID" and GetShapeshiftFormID and D.FERAL_FORMS[GetShapeshiftFormID() or 0] then
        if Knows(D.FELINE_SWIFTNESS) then Add(out, RCL["Feline Swiftness (form effect)"], "feral") end
        if Knows(D.PREDATORY_STRIKES) then Add(out, RCL["Predatory Strikes (form effect)"], "feral") end
    end
    for _, a in ipairs(list) do
        local label = a.id and D.SECOND_EFFECT[a.id]
        if label then Add(out, label, "items", a.icon) end
    end
    if equipDirty then ReadEquipped() end
    for _, label in ipairs(equipHidden) do Add(out, label, "items") end
    for id, t in pairs(castUntil) do
        if t > now then
            Add(out, D.AFTER_CAST[id][2], "items", nil, t)
        else
            castUntil[id] = nil
        end
    end
    return out
end

------------------------------------------------------------------------
-- PUSH-OFFS
-- A buff counts as pushed off when it left early (it ran a minute or
-- more and still had time), something new arrived with it, the buffs
-- were near the cap, and nothing of its own kind replaced it (a new
-- rank, a different flask, another food). Buffs that end by themselves
-- and ones another player keeps up never count.
------------------------------------------------------------------------
local function SameKind(r, a)
    if r.name == a.name then return true end
    if r.e and a.e and r.e.group and r.e.group == a.e.group then return true end
    local rf, af = r.e and r.e.family, a.e and a.e.family
    if rf and af then
        for tag in pairs(rf) do
            if af[tag] then return true end
        end
    end
    return false
end

local function ByIndex(a, b) return a.idx < b.idx end

-- Buffs the player (or a cancel button) took off on purpose in the last
-- few seconds, by spell id and by name: those are never push-offs, and
-- a refresh that saw one teaches the hidden-slot count nothing. Fed by
-- post-hooks on the game's own cancel calls (a post-hook taints nothing).
local cancelledId, cancelledName = {}, {}
local CANCEL_MEMORY = 3
local function StampCancelIndex(unit, index, filter)
    if unit ~= "player" or type(index) ~= "number" then return end
    if filter and type(filter) == "string" and not filter:find("HELPFUL", 1, true) then return end
    local a = list[index]
    local now = GetTime()
    if a then
        if a.id then cancelledId[a.id] = now end
        if a.name then cancelledName[a.name] = now end
    end
end
local function StampCancelName(name)
    if type(name) == "string" then cancelledName[name] = GetTime() end
end
if hooksecurefunc then
    if CancelUnitBuff then hooksecurefunc("CancelUnitBuff", StampCancelIndex) end
    if CancelSpellByName then hooksecurefunc("CancelSpellByName", StampCancelName) end
end

local function CancelledOnPurpose(r, now)
    local t = (r.id and cancelledId[r.id]) or (r.name and cancelledName[r.name])
    return t ~= nil and now - t < CANCEL_MEMORY
end

local function Call(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then RC:DebugPrint("BuffCap: " .. tostring(err), "charstats") end
end

local PUSH_HISTORY = 40

-- Names of the buffs that arrived with the push, at most three.
local function PusherNames(added)
    local out, seen = {}, {}
    for _, a in ipairs(added or {}) do
        local n = a.name
        if n and not seen[n] then
            seen[n] = true
            out[#out + 1] = n
            if #out >= 3 then break end
        end
    end
    return out
end

local function PushedOff(lost, before, prevHidden, exact, added)
    local m = Memory()
    local by = PusherNames(added)
    if m then
        local now = time()
        local zone = GetRealZoneText and GetRealZoneText() or nil
        for _, r in ipairs(lost) do
            table_insert(m.pushes, 1, { n = r.name, id = r.id, t = now,
                by = (#by > 0) and by or nil, z = (zone ~= "") and zone or nil })
        end
        while #m.pushes > PUSH_HISTORY do table_remove(m.pushes) end
        -- An exact swap (as many arrived as left) at the cap says how many
        -- slots were really full; believed only when two readings agree.
        if exact and On("countHidden") and On("learn") then
            if CAP then
                local surplus = Clamp(CAP - before - prevHidden, -3, 4)
                if surplus == m.last then m.learned = surplus end
                m.last = surplus
            else
                -- no confirmed limit: what was in use is the limit
                local c = CapMemory()
                local seen = before + prevHidden
                if c then
                    if seen == c.last then c.cap = seen end
                    c.last = seen
                end
            end
        end
    end
    RC:DebugPrint("BuffCap: pushed off " .. #lost .. " (visible before " .. before
        .. ", hidden " .. prevHidden .. ", exact " .. tostring(exact) .. ")", "charstats")
    for _, fn in pairs(pushListeners) do Call(fn, lost, exact, by) end
end

local function Detect(prevList, prevMap, now, gain, prevRaw)
    local removed, added = {}, {}
    for k, a in pairs(prevMap) do
        if not map[k] then removed[#removed + 1] = a end
    end
    for k, a in pairs(map) do
        if not prevMap[k] then added[#added + 1] = a end
    end
    if #removed > 1 then table_sort(removed, ByIndex) end
    if #added > 1 then table_sort(added, ByIndex) end
    if remover and remover.NoteAdded and #added > 0 then Call(remover.NoteAdded, added, now) end
    if #removed == 0 or #added + gain < #removed then return end
    if #prevList < (Limit() or UNMEASURED) - 8 or UnitIsDeadOrGhost("player") then return end
    local out = {}
    local deliberate = false
    for _, r in ipairs(removed) do
        local fine = r.dur >= 60 and r.exp - now > 3 and not (r.e and (r.e.fades or r.e.provided))
        local wanted = CancelledOnPurpose(r, now)
        if not wanted and remover then
            if remover.RecentlyCancelled and r.id then
                local okc, was = pcall(remover.RecentlyCancelled, r.id, now)
                if okc and was then wanted = true end
            end
            -- a buff the remover is set to take off went because it was asked to
            if not wanted and remover.State then
                local oks, st = pcall(remover.State, r)
                if oks and st == "r" then wanted = true end
            end
        end
        if wanted then
            fine = false
            deliberate = true
        end
        if fine then
            for _, a in ipairs(added) do
                if SameKind(r, a) then
                    fine = false
                    break
                end
            end
        end
        if fine then out[#out + 1] = r end
    end
    if #out > 0 then PushedOff(out, #prevList, prevRaw, (not deliberate) and #added + gain == #removed, added) end
end

------------------------------------------------------------------------
-- REFRESH
------------------------------------------------------------------------
local function Schedule(at, now)
    local key = math_floor(at * 10 + 0.5)
    if wake[key] then return end
    wake[key] = true
    C_Timer.After(at - now + 0.05, function()
        wake[key] = nil
        BC:Request()
    end)
end

local function ClampHidden(h, visible)
    if h < 0 then return 0 end
    local lim = Limit()
    if not lim then return h end
    local room = lim - visible
    if room < 0 then room = 0 end
    if h > room then return room end
    return h
end

local function ForgetOld(t, now)
    for k, at in pairs(t) do
        if now - at >= CANCEL_MEMORY then t[k] = nil end
    end
end

function BC:Refresh()
    local now = GetTime()
    if next(cancelledId) then ForgetOld(cancelledId, now) end
    if next(cancelledName) then ForgetOld(cancelledName, now) end
    local prevList, prevMap, prevRaw = list, map, rawHidden
    list, map, idSet = Scan()
    hidden = ComputeHidden(now)
    rawHidden = #hidden
    if ready and running then
        Detect(prevList, prevMap, now, math_max(0, rawHidden - prevRaw), prevRaw)
    end
    ready = running
    for _, h in ipairs(hidden) do
        if h.untilAt then Schedule(h.untilAt, now) end
    end
    if remover and remover.Seen then
        for _, a in ipairs(list) do
            if not a.e and a.id then Call(remover.Seen, a) end
        end
    end
    local countHidden = On("countHidden")
    local m = Memory()
    local learned = (countHidden and On("learn") and m) and m.learned or 0
    if not CAP then learned = 0 end
    state.learned = learned
    state.visible = #list
    state.hidden = ClampHidden(rawHidden + learned, #list)
    state.reserved = (countHidden and defKinds and defUntil <= now) and 1 or 0
    state.used = state.visible + state.hidden
    if CAP then
        state.cap = CAP - state.hidden - state.reserved
        state.free = state.cap - state.visible
    else
        -- a version whose limit is still being measured: no cap, no free
        local lim = Limit()
        BC.CAP = lim
        state.limit = lim
        state.cap = lim and (lim - state.hidden - state.reserved) or nil
        state.free = state.cap and (state.cap - state.visible) or nil
    end
    state.at = now
    for _, fn in pairs(subscribers) do Call(fn, state) end
    return state
end

-- One refresh on the next frame, however many ask before it runs.
function BC:Request()
    if queued or not running then return end
    queued = true
    C_Timer.After(0, function()
        queued = false
        if running then BC:Refresh() end
    end)
end

-- The numbers right now, for a tooltip or a cell: the running state, or
-- a one-off read (which never looks for push-offs) when nothing runs.
function BC:Current()
    ResolveCap()
    if running and state.at then return state end
    if not playerClass then
        playerClass = select(2, UnitClass("player"))
        ReadDefensiveKinds()
    end
    BC:Refresh()
    return state
end

function BC:List() return list end
function BC:Hidden() return hidden end
function BC:Has(id) return idSet[id] == true end
function BC:IsRunning() return running end
function BC:PlayerClass() return playerClass end
function BC:PlayerRace() return playerRace end

-- What fills the hidden slots, for tooltips: the identified ones, then
-- the learned and kept-free ones as their own lines.
function BC:HiddenLines()
    local out = {}
    for _, h in ipairs(hidden) do out[#out + 1] = h end
    for _ = 1, math_max(0, state.learned) do
        out[#out + 1] = { label = RCL["Unidentified hidden buff"], src = "learned" }
    end
    if state.reserved > 0 then
        out[#out + 1] = { label = RCL["Defensive State"], src = "reserved" }
    end
    return out
end

------------------------------------------------------------------------
-- WHO LISTENS
------------------------------------------------------------------------
-- fn(state) after every refresh
function BC:Subscribe(key, fn) subscribers[key] = fn end
-- fn(lostList, exact, byNames) when buffs are pushed off; byNames is what
-- arrived in the same moment (may be empty)
function BC:OnPushedOff(key, fn) pushListeners[key] = fn end

-- A buff remover living in another addon. Every field is optional:
--   State(a)               "k" keep, "r" remove, "s" can't be removed
--   Toggle(a)              switch a buff between keep and remove
--   Paused() SetPaused(on) a pause switch
--   RecentlyCancelled(id, now)  it took this buff off a moment ago
--   NoteAdded(list, now)   buffs that just arrived
--   Seen(a)                a buff not in the list was on the player
--   name                   what to call it in tooltips
function BC:SetRemover(api)
    remover = api
    BC:Request()
end
function BC:Remover() return remover end

-- The counter runs while at least one key wants it.
local events = CreateFrame("Frame")

local function StartCombatWatch()
    if defKinds and On("countHidden") then
        events:RegisterUnitEvent("UNIT_COMBAT", "player")
    end
end

local function StopCombatWatch()
    events:UnregisterEvent("UNIT_COMBAT")
end

local function Start()
    ResolveCap()
    running = true
    ready = false
    playerClass = select(2, UnitClass("player"))
    playerRace = select(2, UnitRace("player"))
    ReadDefensiveKinds()
    equipDirty = true
    events:RegisterEvent("PLAYER_ENTERING_WORLD")
    events:RegisterEvent("PLAYER_REGEN_DISABLED")
    events:RegisterEvent("PLAYER_REGEN_ENABLED")
    events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
    events:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
    events:RegisterEvent("SPELLS_CHANGED")
    pcall(events.RegisterEvent, events, "MINIMAP_UPDATE_TRACKING")
    events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    RC:RegisterUnitAuraCallback("BuffCap", 0.2, function() BC:Refresh() end)
    if InCombatLockdown() then StartCombatWatch() end
    BC:Refresh()
    RC:DebugPrint("BuffCap: counting", "charstats")
end

local function Stop()
    running = false
    ready = false
    events:UnregisterAllEvents()
    RC:UnregisterUnitAuraCallback("BuffCap")
    RC:DebugPrint("BuffCap: stopped", "charstats")
end

function BC:Want(key, on)
    -- off where buffs cannot be read in a fight (Core_Flavor)
    if on and not RC:FeatureOn("buff_pushoff") then on = nil end
    wanted[key] = on and true or nil
    local any = next(wanted) ~= nil
    if any and not running then
        Start()
    elseif not any and running then
        Stop()
    end
end

events:SetScript("OnEvent", function(_, event, a1, a2, a3)
    if event == "UNIT_COMBAT" then
        -- every hit on the player lands here in a fight: stamp and queue only
        local kinds = defKinds
        if not kinds then return end
        local kind
        if a2 == "DODGE" or a2 == "PARRY" or a2 == "BLOCK" then
            kind = a2
        elseif a3 == "BLOCK_REDUCED" then
            kind = "BLOCK"
        end
        if kind and kinds[kind] then
            local now = GetTime()
            local was = defUntil > now
            defUntil = now + D.DEFENSIVE_SECONDS
            -- already up: the slot count is unchanged and the wake for its
            -- old end will see the new one and wait again
            if not was then BC:Request() end
        end
        return
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local c = D.AFTER_CAST[a3]
        if c then
            castUntil[a3] = GetTime() + c[1]
            BC:Request()
        end
        return
    elseif event == "PLAYER_ENTERING_WORLD" then
        ready = false
        equipDirty = true
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        equipDirty = true
    elseif event == "SPELLS_CHANGED" then
        ReadDefensiveKinds()
    elseif event == "PLAYER_REGEN_DISABLED" then
        StartCombatWatch()
    elseif event == "PLAYER_REGEN_ENABLED" then
        StopCombatWatch()
    end
    BC:Request()
end)

-- for the settings page: settings changed, read everything again
function BC:SettingsChanged()
    if not running then return end
    StopCombatWatch()
    if InCombatLockdown() then StartCombatWatch() end
    BC:Request()
end

RC:DebugPrint("BuffCap module loaded", "charstats")
