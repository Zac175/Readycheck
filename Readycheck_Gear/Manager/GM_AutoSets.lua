------------------------------------------------------------------------
-- Readycheck - Gear Manager: automatic sets
-- (2026-11-20, Zac: "can we get the option to do gear sets based on like
-- warrior stance or spec and do the same for all other classes as well")
--
-- RULES. Each rule says: in this stance / form (or any), with this spec
-- (or any), wear this gear set. When your stance, form or spec CHANGES,
-- the rule that fits best is found (a rule naming both beats one naming
-- only the stance, which beats one naming only the spec, which beats a
-- rule for "any / any"; ties go to the one higher in the list) and its
-- set is put on. Nothing happens while nothing changes: a set you put on
-- by hand stays until the next change. A stance with no rule keeps what
-- you are wearing.
--
-- EVERY CLASS, NO LISTS OF SPELLS. The stances and forms are read from
-- the client's own stance bar (GetNumShapeshiftForms /
-- GetShapeshiftFormInfo): warrior stances, druid forms, rogue stealth,
-- priest Shadowform, paladin auras, shaman Ghost Wolf - whatever this
-- character has on this game version. "No form" is its own choice for the
-- classes that can be out of one. A rule remembers the form by its spell
-- id and its name, so a new rank (Stealth, an aura) still fits, and Dire
-- Bear Form is the Bear Form rule (FAMILY). Specs come from Spec Detection
-- (RC:DetectWarriorSpec, which reads every class).
--
-- IN A FIGHT (fact, not a choice). The game lets an addon change gear in
-- a fight only as the direct result of a key press, and then only
-- weapons. A stance change is an event, not a key press, so nothing is
-- moved in a fight: the change is remembered, and when the fight ends the
-- set for the stance you are IN THEN is put on (afterCombat; one swap,
-- not one per stance change). For weapons mid-fight, a rule can make a
-- macro (AS.MacroBody / AS.MakeMacro): your stance and that set's
-- weapons on one key, which is a key press and so allowed.
--
-- WHO ELSE MOVES GEAR.
--   * A boss gear swap (target set, post-combat set, boss trinket lock):
--     it comes first while it is active (bossFirst), because equipping a
--     set by hand releases the boss's lock (GM:EquipSet).
--   * A set asked for during the fight by anything else (a click on a set,
--     a route step, the boss swap) is queued by RC:QueueGearSwap and goes
--     on when the fight ends: that asked-for set wins, the rule stands
--     down for that fight.
--   * A hotswap (a temporary boost set that is put back): the rule waits
--     until it is over, looking once a second (a guarded ticker, only
--     while something is waiting).
--   * Dead: waits for PLAYER_ALIVE / PLAYER_UNGHOST.
--
-- TWO THINGS LIVE HERE. (1) What a set or an item is FOR - the specs
-- and stances / forms it shows under in the dockable buttons' hover
-- menus (further down: "WHAT A SET OR AN ITEM IS FOR"). That is what was
-- asked for first: menus that only list what fits what you are doing.
-- (2) Putting a set on by itself, the rules described above, off until
-- switched on.
--
-- ONE PLACE, ONE SWITCH. Everything here is set on Gear Manager > Spec &
-- Stance and nowhere else, under one switch (AS.Master, saved as `use`)
-- that is OFF until turned on. A new rule is for everything until it is
-- narrowed.
--
-- SAVED: RC.db.gearAutoSets = { use, enabled, rules = { { form, formName, spec,
-- set, on } }, afterCombat, bossFirst, delay, atLogin, announce }.
-- A setting that is nil is its shipped value (AS.DEFAULTS). Off until
-- switched on, and with no rules nothing ever happens.
--
-- COST. Events only set a flag and start one short timer
-- (UPDATE_SHAPESHIFT_FORM can come in bursts); the work is one small
-- table walk after the wait. Nothing runs while it is switched off.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
local GM = RC.GearManager
if not GM then return end

-- (the game's own where it has them, Readycheck's stand-ins where it does not: WoW Forever)
local function GetSpellInfo(id)
    local fn = _G.GetSpellInfo or (RC.Compat and RC.Compat.GetSpellInfo)
    if fn then return fn(id) end
end
local function GetItemInfo(item)
    local fn = _G.GetItemInfo or (RC.Compat and RC.Compat.GetItemInfo)
    if fn then return fn(item) end
end
local InCombatLockdown, GetTime, C_Timer = InCombatLockdown, GetTime, C_Timer
local type, pairs, ipairs, tostring, tonumber = type, pairs, ipairs, tostring, tonumber

local AS = {}
RC.AutoSets = AS
GM.AutoSets = AS

AS.DEFAULTS = {
    afterCombat = true,     -- after a fight, wear the set for the stance you ended it in
    bossFirst   = true,     -- stand down while a boss gear swap is active
    delay       = 0.3,      -- seconds waited after a change before swapping (a quick there-and-back does nothing)
    atLogin     = false,    -- also apply when you log in or reload
    announce    = false,    -- a chat line for each automatic swap
}
AS.DELAY_MIN, AS.DELAY_MAX = 0, 3

-- one rule for a form and what replaces it later
local FAMILY = { [9634] = 5487 }        -- Dire Bear Form is the Bear Form rule

-- what a class calls them, and what being out of one is called
local WORD = { WARRIOR = "stance", PALADIN = "aura" }
local NO_FORM = {
    DRUID = "Caster form (no shapeshift)", ROGUE = "Not stealthed", PRIEST = "Not in Shadowform",
    PALADIN = "No aura", SHAMAN = "Not in Ghost Wolf",
}
-- the weapons a key press may change in a fight
local WEAPON_SLOTS = { 16, 17, 18 }
-- casting these again takes you OUT of the form, so the macro casts only when not in it
local TOGGLES = { DRUID = true, ROGUE = true, PRIEST = true, SHAMAN = true }

local function Class()
    local _, class = UnitClass("player")
    return class or "WARRIOR"
end
AS.Class = Class

local pending = false               -- a change the game would not let us act on yet

------------------------------------------------------------------------
-- SETTINGS
------------------------------------------------------------------------
-- the saved table, made when missing
function AS.DB()
    local db = RC.db
    if type(db) ~= "table" then return nil end
    if type(db.gearAutoSets) ~= "table" then db.gearAutoSets = { use = false, enabled = false, rules = {} } end
    local s = db.gearAutoSets
    if type(s.rules) ~= "table" then s.rules = {} end
    -- "use" is not among the shipped values on purpose (they are filled into
    -- every saved table, which would answer this before it is asked): not
    -- decided yet is off, except for a setup made on a build from before the
    -- one switch, which stays on.
    if s.use == nil then
        local function Limited(st)
            return type(st) == "table"
                and ((type(st.menuScopeSets) == "table" and next(st.menuScopeSets) ~= nil)
                  or (type(st.menuScopeItems) == "table" and next(st.menuScopeItems) ~= nil))
        end
        s.use = (s.enabled == true or #s.rules > 0 or Limited(GM.settings)
            or Limited(type(db.gearManager) == "table" and db.gearManager.settings)) and true or false
    end
    return s
end
local function Save()
    if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
end
-- nil saved = what Readycheck ships
function AS.Opt(key)
    local s = AS.DB()
    local v = s and s[key]
    if v == nil then return AS.DEFAULTS[key] end
    return v
end
function AS.SetOpt(key, v)
    local s = AS.DB()
    if not s or AS.DEFAULTS[key] == nil then return end
    if key == "delay" then
        v = tonumber(v) or AS.DEFAULTS.delay
        if v < AS.DELAY_MIN then v = AS.DELAY_MIN elseif v > AS.DELAY_MAX then v = AS.DELAY_MAX end
    end
    if v == AS.DEFAULTS[key] then s[key] = nil else s[key] = v end
    Save()
end
-- THE ONE SWITCH for all of it (2026-11-20, Zac: "just have all of that
-- off by default in general with a way to turn it all on later"). Off:
-- no menu leaves anything out, nothing is put on by itself, and what was
-- picked stays saved for when it is turned on.
function AS.Master()
    local s = AS.DB()
    return (s and s.use == true) or false
end
function AS.SetMaster(on)
    local s = AS.DB()
    if not s then return end
    s.use = on and true or false
    pending = false
    if on then AS.Sync() end
    Save()
    if GM.RefreshOpenMenu then GM:RefreshOpenMenu() end
end
-- sets that go on by themselves: their own tick under the one switch
function AS.AutoOn()
    local s = AS.DB()
    return (s and s.enabled == true) or false
end
function AS.Enabled()
    return AS.Master() and AS.AutoOn()
end
function AS.Rules()
    local s = AS.DB()
    return s and s.rules or {}
end

------------------------------------------------------------------------
-- STANCES, FORMS, SPECS (read from the client, for whatever class this is)
------------------------------------------------------------------------
function AS.Word() return WORD[Class()] or "form" end
function AS.NoFormLabel() return RCL[NO_FORM[Class()] or "No form"] end
-- a warrior is always in a stance; everyone else can be out of form
function AS.CanBeFormless() return Class() ~= "WARRIOR" end

-- { { index, id, name, icon } } for every stance / form this character has
function AS.Forms()
    local out = {}
    local n = (GetNumShapeshiftForms and GetNumShapeshiftForms()) or 0
    for i = 1, n do
        local icon, _, _, spellID = GetShapeshiftFormInfo(i)
        if spellID then
            local name, _, spellIcon = nil, nil, nil
            name, _, spellIcon = GetSpellInfo(spellID)
            -- (the stance bar's own icon turns into the "active" swirl while you are in the form)
            out[#out + 1] = { index = i, id = spellID, name = name or ("#" .. spellID), icon = spellIcon or icon }
        end
    end
    return out
end
function AS.HasForms()
    return ((GetNumShapeshiftForms and GetNumShapeshiftForms()) or 0) > 0
end

-- the form you are in: its spell id, 0 = none, nil = not known right now
function AS.CurrentForm()
    if not GetShapeshiftForm then return 0 end
    local idx = GetShapeshiftForm()
    if not idx or idx == 0 then return 0 end
    local _, _, _, spellID = GetShapeshiftFormInfo(idx)
    return spellID
end
function AS.CurrentSpec()
    if not RC.DetectWarriorSpec then return nil end
    return RC:DetectWarriorSpec()
end

function AS.FormName(id)
    if id == nil then return nil end
    if id == 0 then return AS.NoFormLabel() end
    return (GetSpellInfo(id))
end
-- { { key, name, icon } } for this class
function AS.Specs()
    local sd = RC.specDetection
    local out = {}
    if not sd then return out end
    local class = Class()
    if class == "WARRIOR" then
        for _, key in ipairs({ "arms", "fury", "furyProt", "prot" }) do
            local s = sd.specs and sd.specs[key]
            if s then out[#out + 1] = { key = key, name = s.name or key, icon = s.icon } end
        end
    else
        local list = sd.classSpecs and sd.classSpecs[class]
        for i = 1, 3 do
            local s = list and list[i]
            if s then out[#out + 1] = { key = s.key, name = s.name or s.key, icon = s.icon } end
        end
    end
    return out
end
function AS.SpecName(key)
    if key == nil then return nil end
    for _, s in ipairs(AS.Specs()) do
        if s.key == key then return s.name end
    end
    return tostring(key)
end

------------------------------------------------------------------------
-- RULES
------------------------------------------------------------------------
-- does the rule's form fit the form you are in (id, its name)?
local function FormFits(rule, id, name)
    local want = rule.form
    if want == nil then return true end
    if want == id then return true end
    if want == 0 or id == 0 or id == nil then return false end
    if (FAMILY[want] or want) == (FAMILY[id] or id) then return true end
    -- another rank of the same spell (Stealth, a paladin aura)
    if rule.formName and name and rule.formName == name then return true end
    return false
end

function AS.SetExists(name)
    if type(name) ~= "string" or name == "" then return false end
    if GM.sets and GM.sets[name] then return true end
    local ir = RC.itemRackIntegration
    if ir and type(ir.sets) == "table" then
        for _, n in ipairs(ir.sets) do
            if n == name then return true end
        end
    end
    return false
end

-- the rule for this form and spec, and its place in the list
function AS.Resolve(formId, spec)
    local formName = (formId and formId ~= 0) and GetSpellInfo(formId) or nil
    local best, bestScore, bestIndex
    for i, r in ipairs(AS.Rules()) do
        if type(r) == "table" and r.on ~= false and type(r.set) == "string" and r.set ~= ""
           and FormFits(r, formId, formName) and (r.spec == nil or r.spec == spec) then
            local score = (r.form ~= nil and 2 or 0) + (r.spec ~= nil and 1 or 0)
            if not best or score > bestScore then best, bestScore, bestIndex = r, score, i end
        end
    end
    return best, bestIndex
end

-- "Defensive Stance, Fury" - what a rule is for, in words
function AS.RuleText(rule)
    local parts = {}
    if rule.form ~= nil then
        parts[#parts + 1] = (rule.form == 0 and AS.NoFormLabel()) or AS.FormName(rule.form) or rule.formName or RCL["Unknown form"]
    end
    if rule.spec ~= nil then parts[#parts + 1] = AS.SpecName(rule.spec) end
    if #parts == 0 then return RCL["Always"] end
    return table.concat(parts, ", ")
end

-- A new rule is for EVERYTHING (any stance or form, any spec) until it is
-- narrowed (2026-11-20, Zac: "default should be everything"). With a set
-- picked, that is the set worn whenever no narrower rule fits.
function AS.AddRule(setName)
    local s = AS.DB()
    if not s then return nil end
    local rule = { on = true, set = (type(setName) == "string") and setName or "" }
    s.rules[#s.rules + 1] = rule
    Save()
    return rule, #s.rules
end

function AS.RemoveRule(index)
    local s = AS.DB()
    if not s or not s.rules[index] then return end
    table.remove(s.rules, index)
    Save()
end
function AS.MoveRule(index, dir)
    local rules = AS.Rules()
    local to = index + dir
    if not rules[index] or not rules[to] then return false end
    rules[index], rules[to] = rules[to], rules[index]
    Save()
    return true
end
-- form: nil = any, 0 = none, or a spell id
function AS.SetRuleForm(rule, form)
    rule.form = form
    rule.formName = (form and form ~= 0) and AS.FormName(form) or nil
    Save()
end
function AS.SetRuleSpec(rule, spec) rule.spec = spec Save() end
function AS.SetRuleSet(rule, set) rule.set = set or "" Save() end
function AS.SetRuleOn(rule, on) rule.on = on and true or false Save() end

-- is this rule's form one this character has right now?
function AS.RuleFormKnown(rule)
    if rule.form == nil or rule.form == 0 then return true end
    for _, f in ipairs(AS.Forms()) do
        if FormFits(rule, f.id, f.name) then return true, f end
    end
    return false
end

------------------------------------------------------------------------
-- WHAT A SET OR AN ITEM IS FOR (the hover menus)
-- (2026-11-20, Zac: "mainly wanted it for like dockable menu gear sets
-- so they dont get super cluttered based on if im dpsing or tanking and
-- maybe do the same with like trinkets and stuff as well give the option")
--
-- Every gear set, and every item a dockable button's menu can show, may
-- be limited to some specs and / or some stances / forms. Where it does
-- not fit, it is left out of the dockable buttons' hover menus exactly
-- like an entry hidden by hand (GM_Menu.lua): counted in the menu's
-- "N hidden" line and shown faded while the reveal key is held. Nothing
-- is limited until you limit it: no entry = everything. This only
-- decides what a MENU lists; it never puts gear on (that is the rules
-- above, which are off until switched on).
--   scope = { specs = { [spec key] = true }, forms = { [spell id] = name, [0] = true } }
--   a part that is nil = any. Saved in GM.settings.menuScopeSets[set
--   name] / menuScopeItems[GM:MenuItemKey]; menuScopeOn = false switches
--   the whole thing off without losing what was picked.
-- The character sheet menus and the set editor always list everything.
------------------------------------------------------------------------
local function ScopeTable(kind, make)
    local st = GM.settings
    if not st then return nil end
    local field = (kind == "set") and "menuScopeSets" or "menuScopeItems"
    if type(st[field]) ~= "table" then
        if not make then return nil end
        st[field] = {}
    end
    return st[field]
end
-- (under the one switch: AS.Master)
function GM:MenuScopeOn()
    return AS.Master() and not (self.settings and self.settings.menuScopeOn == false)
end
-- the menus' own tick, whatever the one switch says
function GM:MenuScopeWanted()
    return not (self.settings and self.settings.menuScopeOn == false)
end
function GM:SetMenuScopeOn(on)
    self.settings.menuScopeOn = on and true or false
    self:SaveSettings()
    if self.RefreshOpenMenu then self:RefreshOpenMenu() end
end
-- kind: "set" (key = the set's name) or "item" (key = GM:MenuItemKey)
function GM:GetMenuScope(kind, key)
    local t = ScopeTable(kind)
    local sc = t and key and t[key]
    return (type(sc) == "table") and sc or nil
end
-- every spec key, and every form id, this character could be limited to
local function AllSpecs()
    local out = {}
    for _, sp in ipairs(AS.Specs()) do out[#out + 1] = sp.key end
    return out
end
local function AllForms()
    local out = {}
    for _, f in ipairs(AS.Forms()) do out[#out + 1] = f end
    if AS.HasForms() and AS.CanBeFormless() then out[#out + 1] = { id = 0, name = AS.NoFormLabel() } end
    return out
end
AS.AllForms = AllForms
-- does a scope's form list hold this form (by id, by family, or another rank by name)?
local function FormIn(forms, id, name)
    if forms[id] ~= nil then return true end
    if id == 0 or id == nil then return false end
    for want, wantName in pairs(forms) do
        if want ~= 0 then
            if (FAMILY[want] or want) == (FAMILY[id] or id) then return true end
            if name and type(wantName) == "string" and wantName == name then return true end
        end
    end
    return false
end
-- is a spec / a form ticked in this scope? (nil scope or nil part = everything)
function GM:MenuScopeHas(scope, what, id)
    if type(scope) ~= "table" then return true end
    if what == "spec" then
        return scope.specs == nil or scope.specs[id] == true
    end
    if scope.forms == nil then return true end
    return FormIn(scope.forms, id, (id and id ~= 0) and AS.FormName(id) or nil)
end
-- Ticks or unticks one spec or one stance / form for a set or an item.
-- All ticked again = everything = nothing saved.
function GM:SetMenuScopePart(kind, key, what, id, on)
    if not key then return end
    local t = ScopeTable(kind, true)
    local sc = (type(t[key]) == "table") and t[key] or {}
    if what == "spec" then
        local specs = {}
        for _, k in ipairs(AllSpecs()) do
            if self:MenuScopeHas(sc, "spec", k) then specs[k] = true end
        end
        specs[id] = on and true or nil
        local all = true
        for _, k in ipairs(AllSpecs()) do if not specs[k] then all = false end end
        sc.specs = (not all) and specs or nil
    else
        local forms = {}
        for _, f in ipairs(AllForms()) do
            if self:MenuScopeHas(sc, "form", f.id) then forms[f.id] = (f.id ~= 0 and f.name) or true end
        end
        if on then
            forms[id] = (id ~= 0 and AS.FormName(id)) or true
        else
            forms[id] = nil
            -- (a form kept under another id of its family, or an older rank's)
            for want in pairs(forms) do
                if want ~= 0 and id ~= 0 and (FAMILY[want] or want) == (FAMILY[id] or id) then forms[want] = nil end
            end
        end
        local all = true
        for _, f in ipairs(AllForms()) do if not FormIn(forms, f.id, f.name) then all = false end end
        sc.forms = (not all) and forms or nil
    end
    t[key] = (sc.specs or sc.forms) and sc or nil
    self:SaveSettings()
    if self.RefreshOpenMenu then self:RefreshOpenMenu() end
end
function GM:ClearMenuScope(kind, key)
    local t = ScopeTable(kind)
    if t and key then t[key] = nil end
    self:SaveSettings()
    if self.RefreshOpenMenu then self:RefreshOpenMenu() end
end
-- does the scope fit where you are right now? (what is not known yet fits)
function GM:MenuScopeFits(scope)
    if type(scope) ~= "table" then return true end
    if scope.specs then
        local spec = AS.CurrentSpec()
        if spec ~= nil and not scope.specs[spec] then return false end
    end
    if scope.forms then
        local form = AS.CurrentForm()
        -- (a warrior is never out of stance: 0 is the client between two answers)
        if form ~= nil and not (form == 0 and not AS.CanBeFormless()) then
            if not FormIn(scope.forms, form, form ~= 0 and AS.FormName(form) or nil) then return false end
        end
    end
    return true
end
-- left out of the dock menus right now because it is for another spec / stance?
function GM:IsMenuSetScopedOut(name)
    if not self:MenuScopeOn() then return false end
    local sc = self:GetMenuScope("set", name)
    return (sc ~= nil) and not self:MenuScopeFits(sc)
end
function GM:IsMenuItemScopedOut(link)
    if not self:MenuScopeOn() then return false end
    local t = ScopeTable("item")
    if not t or next(t) == nil then return false end
    local key, id = self:MenuItemKey(link)
    local sc = (key and t[key]) or nil
    return (type(sc) == "table") and not self:MenuScopeFits(sc)
end
-- "Fury, Arms - Defensive Stance", or "Everything"
function GM:MenuScopeText(scope)
    if type(scope) ~= "table" or not (scope.specs or scope.forms) then return RCL["Everything"] end
    local parts = {}
    if scope.specs then
        local names = {}
        for _, sp in ipairs(AS.Specs()) do
            if scope.specs[sp.key] then names[#names + 1] = sp.name end
        end
        -- (specs of another class: a profile brought over from another character)
        if #names == 0 then names[1] = RCL["another class's spec"] end
        parts[#parts + 1] = table.concat(names, ", ")
    end
    if scope.forms then
        local names, seenName = {}, {}
        for _, f in ipairs(AllForms()) do
            if FormIn(scope.forms, f.id, f.name) then names[#names + 1] = f.name seenName[f.name] = true end
        end
        if #names == 0 then
            for id, nm in pairs(scope.forms) do
                if type(nm) == "string" and not seenName[nm] then names[#names + 1] = nm seenName[nm] = true end
            end
        end
        if #names == 0 then names[1] = RCL["another class's form"] end
        parts[#parts + 1] = table.concat(names, ", ")
    end
    return table.concat(parts, " - ")
end

------------------------------------------------------------------------
-- APPLYING
------------------------------------------------------------------------
local state = { known = false }     -- the stance / form and spec last acted on
local queuedInFight = false         -- something else asked for a set during this fight: it wins
local formTimer, specTimer, loginTimer, menuTimer = false, false, false, false
local retry, retryN = nil, 0

local function BossBusy()
    local gs = RC.gearSwapState
    if gs then
        if gs.lastBossTarget or (gs.postCombatSet and gs.postCombatSet ~= "") then return true end
        if gs._postSwapActiveUntil and GetTime() < gs._postSwapActiveUntil then return true end
    end
    local bt = RC.bossTrinketState
    if bt and bt.appliedBoss then return true end
    return false
end
local function HotswapBusy()
    local HS = RC.Hotswap
    if not HS then return false end
    return (HS.queueSet ~= nil or HS.restorePending == true or HS.combatQueue ~= nil) and true or false
end
AS.BossBusy, AS.HotswapBusy = BossBusy, HotswapBusy

local function StopRetry()
    if retry then retry:Cancel() retry = nil end
    retryN = 0
end
local function StartRetry()
    if retry or not (RC.Profiler and RC.Profiler.TrackTicker) then return end
    retryN = 0
    retry = RC.Profiler:TrackTicker("AutoSets:Retry", 1.0, function()
        retryN = retryN + 1
        if not pending or retryN > 20 then
            pending = false
            StopRetry()
            return
        end
        if AS.Apply("retry") ~= "wait" then StopRetry() end
    end)
end

-- Puts on the set the rules give for where you are now.
-- Returns what happened: "done", "same" (already wearing it), "none" (no
-- rule fits), "missing" (the rule's set is gone), "wait" (a fight, dead,
-- a hotswap in flight: tried again by itself), "boss" (a boss gear swap
-- comes first), "off", "unknown" (the client has not said the form yet).
local function Tell()
    -- (the settings page's "right now" line, while it is on show)
    if AS.OnState then pcall(AS.OnState) end
end
local ApplyNow
function AS.Apply(why)
    local result = ApplyNow(why)
    Tell()
    return result
end
ApplyNow = function(why)
    if not AS.Enabled() then pending = false return "off" end
    local form, spec = AS.CurrentForm(), AS.CurrentSpec()
    if form == nil then return "unknown" end
    local rule = AS.Resolve(form, spec)
    if not rule then pending = false return "none" end
    if not AS.SetExists(rule.set) then pending = false return "missing" end
    if InCombatLockdown() or (UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")) then
        pending = true
        StopRetry()                 -- (the end of the fight, or coming back to life, tries again)
        return "wait"
    end
    if AS.Opt("bossFirst") and BossBusy() then pending = false return "boss" end
    if HotswapBusy() then
        pending = true
        StartRetry()
        return "wait"
    end
    pending = false
    if GM.sets and GM.sets[rule.set] and GM.IsSetEquipped and GM:IsSetEquipped(rule.set) then
        return "same"
    end
    local text = AS.RuleText(rule)
    -- the swap notice's second line says why
    if RC.NoteSwapContext then RC:NoteSwapContext(text) end
    AS.last = { set = rule.set, why = text, at = GetTime() }
    RC:EquipGearSet(rule.set)
    if AS.Opt("announce") and RC.Print then
        RC:Print(string.format(RCL["Auto set: %s (%s)"], rule.set, text))
    end
    if RC.DebugPrint then RC:DebugPrint("AutoSets: " .. tostring(rule.set) .. " for " .. text .. " (" .. tostring(why) .. ")", "gear") end
    return "done"
end

-- after the wait: has the stance, form or spec really changed?
local function Changed(first)
    if not AS.Enabled() then return end
    local form, spec = AS.CurrentForm(), AS.CurrentSpec()
    if form == nil then return end
    -- (a warrior is never out of stance: 0 is the client between two answers)
    if form == 0 and not AS.CanBeFormless() then return end
    if state.known and form == state.form and spec == state.spec then return end
    local wasKnown = state.known
    state.form, state.spec, state.known = form, spec, true
    if not wasKnown and not AS.Opt("atLogin") then Tell() return end
    AS.Apply(first and "login" or "change")
end
local function TouchForm(wait)
    if formTimer then return end
    formTimer = true
    C_Timer.After(wait or AS.Opt("delay") or 0, function()
        formTimer = false
        Changed()
    end)
end
-- (talents read as they were for a moment after the event: Spec Detection waits 0.5 s itself)
local function TouchSpec()
    if specTimer then return end
    specTimer = true
    C_Timer.After(1.0, function()
        specTimer = false
        Changed()
    end)
end

-- where you are now, taken as the starting point (no swap)
function AS.Sync()
    local form = AS.CurrentForm()
    if form == nil or (form == 0 and not AS.CanBeFormless()) then
        state.known = false
        return
    end
    state.form, state.spec, state.known = form, AS.CurrentSpec(), true
end
function AS.SetEnabled(on)
    local s = AS.DB()
    if not s then return end
    s.enabled = on and true or false
    pending = false
    StopRetry()
    if on then AS.Sync() end
    Save()
end
-- for the settings page: what the rules say about right now
function AS.Status()
    local form, spec = AS.CurrentForm(), AS.CurrentSpec()
    local rule, index = nil, nil
    if form ~= nil then rule, index = AS.Resolve(form, spec) end
    return { form = form, spec = spec, rule = rule, index = index, pending = pending,
             boss = BossBusy(), combat = InCombatLockdown() and true or false }
end
-- (tests)
function AS._State() return state, pending end

------------------------------------------------------------------------
-- THE MACRO: your stance and the rule's weapons on one key
------------------------------------------------------------------------
local function ItemName(link)
    if type(link) == "string" then
        local name = link:match("%[(.-)%]")
        if name and name ~= "" then return name end
    end
    if link and link ~= 0 then return (GetItemInfo(link)) end
    return nil
end
-- Returns the macro's text, or nil and why not:
-- "form" (the rule names no stance), "unknown" (a stance this character
-- does not have), "set" (not one of Readycheck's own sets), "weapons"
-- (the set holds no weapon), "long" (over the game's 255 letters).
function AS.MacroBody(rule)
    if type(rule) ~= "table" or rule.form == nil or rule.form == 0 then return nil, "form" end
    local known, form = AS.RuleFormKnown(rule)
    if not known or not form then return nil, "unknown" end
    local set = GM.sets and GM.sets[rule.set]
    if not (set and type(set.equip) == "table") then return nil, "set" end
    local cast = "/cast "
    if TOGGLES[Class()] then cast = cast .. "[nostance:" .. form.index .. "] " end
    local lines = { "#showtooltip " .. form.name, cast .. form.name }
    local weapons = 0
    for _, slot in ipairs(WEAPON_SLOTS) do
        local name = ItemName(set.equip[slot])
        if name then
            lines[#lines + 1] = "/equipslot " .. slot .. " " .. name
            weapons = weapons + 1
        end
    end
    if weapons == 0 then return nil, "weapons" end
    local body = table.concat(lines, "\n")
    if #body > 255 then
        table.remove(lines, 1)                      -- (the tooltip line is the one to go)
        body = table.concat(lines, "\n")
        if #body > 255 then return nil, "long" end
    end
    return body, form
end
-- Makes (or rewrites) the macro. Returns its name, or nil and why not
-- ("combat", "full", or one of MacroBody's).
function AS.MakeMacro(rule)
    local body, form = AS.MacroBody(rule)
    if not body then return nil, form end
    if InCombatLockdown() then return nil, "combat" end
    local name = form.name:sub(1, 16)
    local icon = "INV_Misc_QuestionMark"            -- (the question mark: #showtooltip gives it the stance's own)
    local gCount, cCount = GetNumMacros()
    local index
    -- (account macros are 1-120, this character's 121-138: one with the same name is rewritten)
    for i = 1, gCount do if (GetMacroInfo(i)) == name then index = i break end end
    if not index then
        for i = 121, 120 + cCount do if (GetMacroInfo(i)) == name then index = i break end end
    end
    if index then
        EditMacro(index, name, icon, body)
    elseif cCount < 18 then
        CreateMacro(name, icon, body, 1)            -- (this character's: the sets are this character's)
    elseif gCount < 120 then
        CreateMacro(name, icon, body, nil)
    else
        return nil, "full"
    end
    return name
end

------------------------------------------------------------------------
-- EVENTS
------------------------------------------------------------------------
-- a set asked for in a fight by anything else is queued; that one wins
if RC.QueueGearSwap and hooksecurefunc then
    hooksecurefunc(RC, "QueueGearSwap", function(_, what)
        if type(what) == "string" and InCombatLockdown() then queuedInFight = true end
    end)
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "UPDATE_SHAPESHIFT_FORM", "UPDATE_SHAPESHIFT_FORMS",
                     "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_ALIVE", "PLAYER_UNGHOST",
                     "CHARACTER_POINTS_CHANGED", "PLAYER_TALENT_UPDATE", "ACTIVE_TALENT_GROUP_CHANGED" }) do
    -- (not every client has every one of these)
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_REGEN_DISABLED" then
        queuedInFight = false
        return
    end
    -- an open hover menu lists what fits the stance or spec you are in now
    -- (whether or not automatic sets are on): redrawn once, a moment later
    if event ~= "PLAYER_REGEN_ENABLED" and event ~= "PLAYER_ALIVE" and event ~= "PLAYER_UNGHOST"
       and GM.menuFrame and GM.menuFrame:IsShown() and not menuTimer then
        menuTimer = true
        C_Timer.After(0.3, function()
            menuTimer = false
            if GM.menuFrame and GM.menuFrame:IsShown() and GM.RefreshOpenMenu then GM:RefreshOpenMenu() end
        end)
    end
    if not AS.Enabled() then return end
    if event == "UPDATE_SHAPESHIFT_FORM" or event == "UPDATE_SHAPESHIFT_FORMS" then
        TouchForm()
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- (talents and the stance bar are not readable at once; Spec Detection primes itself at 2 s)
        if not loginTimer then
            loginTimer = true
            C_Timer.After(3, function() loginTimer = false Changed(true) end)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pending then
            if queuedInFight or not AS.Opt("afterCombat") then
                pending = false
            else
                -- (after the queued swaps and the boss system's own, which land in the first second)
                C_Timer.After(0.6, function()
                    if pending then AS.Apply("after the fight") end
                end)
            end
        end
        queuedInFight = false
    elseif event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        if pending then
            C_Timer.After(0.5, function()
                if pending then AS.Apply("alive") end
            end)
        end
    else
        TouchSpec()
    end
end)
