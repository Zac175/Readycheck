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
--
-- TOLD WHAT TO BE (2026-11-16). An entry of the list is an in-game macro
-- by name or one slot of the action bars (mac.slot). Besides a macro's
-- own rules, a raid config can tell an entry what to be:
--   * a SWAP hands it - or every entry of its GROUP (mac.group, e.g.
--     "Potions") - one item: a boss's page (cfg.macroSwaps, from the
--     moment that boss is targeted until another enemy is or its fight is
--     over) or a route step (step.actions.macros, while the route is on
--     that step or from it through a later one);
--   * its LINK to a boss ability (mac.ability): a MACRO linked to one is
--     off on a boss where that ability is not switched on, and uses the
--     boss's item where the boss names exactly one (its potion, its
--     utility item). A boss with nothing set up tells nothing: every key
--     is as you made it. A link never empties a bar slot.
-- A boss's swap beats the route's, which beats the link, which beats the
-- rules. When nothing tells it anything any more, a macro whose rules do
-- not match gets back the text it had and a slot what it held
-- (mac.swapBack). The details are with the code ("TOLD WHAT TO BE").
-- All of it is switched on by RC.smartKeys, which SmartKeys.lua (beside
-- this file) sets; it was Readycheck_Testing's until 2026-11-18.
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
            local name = (Readycheck.SafeName("target") or ""):lower()
            local pat  = (v or ""):lower()
            return pat ~= "" and name:find(pat, 1, true) ~= nil
        end,

        -- named is a case-insensitive substring test; bossPicker is an exact
        -- case-sensitive match against the name the picker stored.
        bossPicker = function(v)
            if not UnitExists("target") or not v or v == "" then return false end
            return Readycheck.SafeName("target") == v
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

    ------------------------------------------------------------------
    -- TOLD WHAT TO BE (2026-11-16). Besides its own rules, an entry of the
    -- list - an in-game macro by name, or (mac.slot) one slot of the action
    -- bars - can be told what to be from a raid config:
    --   * a SWAP hands it one item:
    --       a boss's page:  cfg.macroSwaps  (the Macros tile)
    --       a route step:   step.actions.macros, for that step or from it
    --                       through a later one (RaidRoute:ActiveMacroSwaps)
    --     A swap = { group | macro | slot, item, itemId }: every entry of a
    --     GROUP (mac.group, e.g. "Potions"), one macro by name, one bar slot.
    --   * its LINK to a boss ability (mac.ability, a tile of the boss page:
    --     "deathwish", "potion", ...): on a boss where that ability is not
    --     switched on a MACRO is OFF - it does nothing - and where the boss
    --     names exactly one item for it (its potion, its utility item) the
    --     entry uses that item. A boss with nothing set up at all tells
    --     nothing (2026-11-16, Zac: "a boss with nothing should just use
    --     defaults what i have set currently"). A bar slot is never
    --     emptied by a link ("i dont want it to completely nuke my default
    --     keybinds"): a button is switched off through a macro on it, whose
    --     text is what changes (SmartKeys.lua puts one there).
    --   * A macro can have a RESTING TEXT (mac.ownBody): what it reads
    --     whenever nothing tells it anything and no rule fires. It is
    --     written back even when the note of what it held is gone (a crash
    --     in a raid loses that note, never the resting text's own macro):
    --     a macro Readycheck made (mac.owned) always, any other when it
    --     still holds one of our texts - edited by hand, the new text is
    --     its resting text from then on.
    -- (Zac: "if i set mrp for this boss or route step and i have a smart
    -- macro for potions it will change my macro to that"; "i have
    -- individual potions bound on my bar i want to be able to change all
    -- of them to this potion so i dont fat finger something"; "i want to
    -- make it so my deathwish is only active for bosses i should death
    -- wish on"; "i want to be able to link like specific slots on my
    -- action bar as well".)
    -- What wins: a boss's swap, then the route's, then the ability link,
    -- then the entry's own rules; a swap naming the macro or the slot
    -- beats one naming its group.
    -- A macro told to use an item reads "#showtooltip <item>" / "/use
    -- <item>"; a slot holds the item. When nothing tells it anything any
    -- more, a macro whose rules do not match gets back the text it had,
    -- a slot what it held (mac.swapBack, kept with the entry so a reload
    -- does not lose it).
    -- Nothing here can happen in a fight: a macro's text and a bar slot
    -- only change out of combat, so a change due in one lands at its end.
    ------------------------------------------------------------------
    local function Trim(v) return (type(v) == "string") and v:match("^%s*(.-)%s*$") or "" end

    -- an entry that is a bar slot: its slot number
    function SM.SlotOf(mac)
        local n = type(mac) == "table" and tonumber(mac.slot) or nil
        if n and n >= 1 and n <= 120 and n == math.floor(n) then return n end
        return nil
    end
    -- what an entry goes by in _active / GetActive
    function SM.KeyOf(mac)
        local slot = SM.SlotOf(mac)
        if slot then return "slot:" .. slot end
        return mac.macroName
    end

    -- the item a swap names: its typed name, else the picked item's name
    -- (or its "item:<id>" form while the client has not loaded the name -
    -- a macro takes either)
    function SM.SwapItem(e)
        if type(e) ~= "table" then return "" end
        local name = Trim(e.item)
        if name == "" and tonumber(e.itemId) then
            name = GetItemInfo(tonumber(e.itemId)) or ("item:" .. tostring(e.itemId))
        end
        return name
    end
    -- a macro's text for one item
    local function UseBody(item) return "#showtooltip " .. item .. "\n/use " .. item end
    function SM.SwapBody(e)
        local item = SM.SwapItem(e)
        if item == "" then return nil end
        return UseBody(item)
    end
    -- a macro that is OFF: nothing to cast, so nothing happens and its
    -- button shows no spell
    SM.OFF_BODY = "#showtooltip\n/stopmacro"
    -- what a swap is aimed at: "macro", name / "slot", n / "group", name (lowercase)
    function SM.SwapAim(e)
        if type(e) ~= "table" then return nil end
        local m = Trim(e.macro)
        if m ~= "" then return "macro", m end
        local s = SM.SlotOf(e)
        if s then return "slot", s end
        local g = Trim(e.group)
        if g ~= "" then return "group", g:lower() end
        return nil
    end

    -- a list of swaps as lookups; a later entry for the same aim wins
    local function Index(list)
        if type(list) ~= "table" then return nil end
        local out
        for _, e in ipairs(list) do
            local kind, name = SM.SwapAim(e)
            if kind and SM.SwapBody(e) then
                out = out or { macro = {}, slot = {}, group = {} }
                out[kind][name] = e
            end
        end
        return out
    end
    local function Pick(idx, mac)
        if not idx then return nil end
        local slot = SM.SlotOf(mac)
        local e
        if slot then e = idx.slot[slot] else e = idx.macro[mac.macroName] end
        if e then return e end
        local g = Trim(mac.group)
        return g ~= "" and idx.group[g:lower()] or nil
    end

    -- THE BOSS IN FORCE. Read off the target: the boss its name resolves
    -- to in the raid (the boss itself, an add of its fight, a member of
    -- it). It HOLDS once that boss has been targeted - nothing can change
    -- in a fight, so dropping the target to buff someone just before the
    -- pull must not put the wrong potion back - until an enemy that is
    -- not a boss is targeted, the boss is a corpse, its fight ends
    -- (ENCOUNTER_END), or the raid is left.
    -- Returns the boss's key and its settings (nil: a boss nothing is set
    -- up on).
    SM._bossHold = nil      -- { raid, key }
    function SM:Boss()
        local raid = RC.GetEffectiveRaidName and RC:GetEffectiveRaidName() or nil
        local hold = SM._bossHold
        if not raid or (hold and hold.raid ~= raid) then
            SM._bossHold = nil
            hold = nil
        end
        if not raid then return nil end
        local rp = RC.GetActiveRaidProfile and RC:GetActiveRaidProfile(raid)
        local bosses = (type(rp) == "table" and type(rp.bosses) == "table") and rp.bosses or {}
        if UnitExists("target") then
            local name = RC.SafeName and RC.SafeName("target") or UnitName("target")
            local key = (name and name ~= "") and RC:GetEncounterNameForBoss(raid, name) or nil
            local isBoss = key ~= nil and (type(bosses[key]) == "table" or RC:IsRaidBossName(raid, key))
            if UnitIsDeadOrGhost("target") then
                -- its corpse: that boss's hold is over
                if hold and key == hold.key then SM._bossHold = nil hold = nil end
            elseif isBoss then
                hold = { raid = raid, key = key }
                SM._bossHold = hold
            elseif UnitCanAttack and UnitCanAttack("player", "target") then
                -- another enemy: the hold is over
                SM._bossHold = nil
                hold = nil
            end
        end
        if not hold then return nil end
        local cfg = bosses[hold.key]
        return hold.key, (type(cfg) == "table") and cfg or nil
    end

    -- THE ROUTE'S SWAPS: the steps' own, in step order (RR_Engine)
    function SM:RouteSwaps()
        local RR = RC.RaidRoute
        if not (RR and RR.ActiveMacroSwaps) then return nil end
        return Index(RR:ActiveMacroSwaps())
    end

    -- What an entry is told to be right now:
    --   { item = <name>, itemId = n, from = "boss" | "route" | "ability" }
    --   { off = true, from = "ability" }
    -- or nil: nothing tells it anything (its own rules, if it has any).
    function SM:Told(mac, bossKey, bossCfg, bossSwaps, routeSwaps)
        local e = Pick(bossSwaps, mac)
        local from = "boss"
        if not e then e, from = Pick(routeSwaps, mac), "route" end
        if e then return { item = SM.SwapItem(e), itemId = tonumber(e.itemId), from = from } end
        local ability = Trim(mac.ability)
        if ability == "" or not bossKey then return nil end
        -- (a boss with nothing set up: the key is as you made it)
        if not RC:EncounterHasConfig(bossCfg) then return nil end
        if not RC:EncounterAbilityOn(bossCfg, ability) then return { off = true, from = "ability" } end
        local id = RC:EncounterAbilityItem(bossCfg, ability)
        if not id then return nil end
        -- (a row that stands for several items - a target dummy - is the one carried)
        id = RC:CarriedVersion(id, RC.utilityItems and RC.utilityItems[id]) or id
        return { item = GetItemInfo(id) or ("item:" .. id), itemId = id, from = "ability" }
    end

    -- What an entry held before it was told what to be, kept on its own
    -- record so a reload in the middle still puts it back:
    --   a macro:  mac.swapBack = { who, before = <its text>, body = <ours> }
    --   a slot:   mac.swapBack = { who, was = <what it held> | false,
    --                              now = <what we put there> | false }
    -- `who` is the character it was taken on: the list travels between
    -- characters (sync, exports), and another character's note says
    -- nothing about this one's macros and bars.
    local function SwapBack(mac)
        local b = mac.swapBack
        if type(b) ~= "table" then return nil end
        if b.who ~= UnitGUID("player") then
            mac.swapBack = nil
            return nil
        end
        return b
    end

    -- Writes a macro's body (or parks it for the end of the fight). One
    -- place for a rule's body, an item's, the off text and the text put
    -- back afterwards.
    local function Write(mac, idx, body, inCombat, what)
        if SM._lastApplied[mac.macroName] == body then
            -- already there: a different text parked for the end of the
            -- fight is no longer wanted either
            SM._pending[mac.id] = nil
            return
        end
        if inCombat then
            SM._pending[mac.id] = { idx = idx, body = body }
            RC:DebugPrint("SmartMacro '" .. mac.macroName .. "': queued (in combat) " .. (what or "")
                .. " -> " .. body:sub(1, 50), "smartmacro")
        else
            EditMacro(idx, nil, nil, body)
            SM._lastApplied[mac.macroName] = body
            SM._pending[mac.id] = nil
            RC:DebugPrint("SmartMacro '" .. mac.macroName .. "': applied " .. (what or "")
                .. " -> " .. body:sub(1, 50), "smartmacro")
        end
    end

    ------------------------------------------------------------------
    -- A BAR SLOT. The action bars' 120 slots are the game's own, so this
    -- works with every bar addon: the slot is what changes, not a button.
    -- What a slot holds is { kind, id, name }: a spell or an item by its
    -- id, a macro by its name. Anything else on a slot (an equipment set,
    -- a pet action...) could not be put back, so such a slot is left
    -- alone. Never with something on the cursor: that is the player's.
    ------------------------------------------------------------------
    local function SlotHolds(slot)
        local kind, id = GetActionInfo(slot)
        if not kind then return nil end
        local name
        if kind == "macro" then
            name = C_ActionBar.GetActionText(slot)
            if not name or name == "" then name = GetMacroInfo(id) end
        end
        return { kind = kind, id = id, name = name }
    end
    local function SameHeld(a, b)
        if not a or not b then return (not a) == (not b) end
        if a.kind ~= b.kind then return false end
        if a.kind == "macro" then return a.name == b.name end
        return a.id == b.id
    end
    local function Restorable(h) return h == nil or h.kind == "spell" or h.kind == "item" or h.kind == "macro" end
    local function EmptySlot(slot)
        if GetActionInfo(slot) then
            PickupAction(slot)
            ClearCursor()
        end
    end
    -- puts h on the slot; false when it could not be picked up (an item
    -- the client does not know or will not hand out, a spell unlearned,
    -- a macro deleted)
    local function FillSlot(slot, h)
        ClearCursor()
        if h.kind == "spell" then
            C_Spell.PickupSpell(h.id)
        elseif h.kind == "item" then
            C_Item.PickupItem(h.id or h.name)
        elseif h.kind == "macro" then
            local i = GetMacroIndexByName(h.name or "")
            if i and i > 0 then PickupMacro(i) end
        end
        local got, gid = GetCursorInfo()
        if not got then return false end
        PlaceAction(slot)
        ClearCursor()       -- (what the slot held comes back on the cursor)
        return true, gid
    end
    SM._slotLib = { Holds = SlotHolds, Same = SameHeld, Empty = EmptySlot, Fill = FillSlot }

    -- a slot entry told what to be
    local function TellSlot(mac, slot, told)
        local now = SlotHolds(slot)
        local back = SwapBack(mac)
        if not back then
            if not Restorable(now) then
                RC:DebugPrint("SmartMacro slot " .. slot .. ": holds a " .. tostring(now.kind)
                    .. ", which could not be put back - left alone", "smartmacro")
                return
            end
            back = { who = UnitGUID("player"), was = now or false }
            mac.swapBack = back
        end
        -- (a slot is only ever handed an item, never emptied: one that
        -- cannot be put there - you carry none - leaves the slot as it is)
        local put = now or false
        local want = { kind = "item", id = told.itemId, name = told.item }
        if now and now.kind == "item" and want.id and now.id == want.id then
            put = now
        else
            local ok, gid = FillSlot(slot, want)
            if ok then put = { kind = "item", id = tonumber(gid) or want.id } end
        end
        back.now = put
        RC:DebugPrint("SmartMacro slot " .. slot .. ": " .. ((put and put.kind == "item" and put.id == (tonumber(want.id) or put.id)) and ("item " .. tostring(put.id)) or "left as it is")
            .. " (" .. tostring(told.from) .. ")", "smartmacro")
    end
    -- nothing tells it anything any more: what it held goes back, unless
    -- the slot was changed by hand since
    local function ReleaseSlot(mac, slot)
        local back = SwapBack(mac)
        if not back then return end
        if SameHeld(SlotHolds(slot), back.now or nil) then
            if back.was then
                if not FillSlot(slot, back.was) then
                    RC:DebugPrint("SmartMacro slot " .. slot .. ": what it held could not be put back", "smartmacro")
                end
            else
                EmptySlot(slot)
            end
        end
        mac.swapBack = nil
    end

    -- One pass asked for; a burst of asks costs a single Evaluate.
    function SM:RequestEvaluate()
        SM._evalDirty = true
        if SM._evalPending then return end
        SM._evalPending = true
        C_Timer.After(0.25, function()
            SM._evalPending = false
            if SM._evalDirty then
                SM._evalDirty = false
                SM:Evaluate()
            end
        end)
    end

    -- The route moved (RR:RefreshTracker): a pass only when the swaps in
    -- force are not the ones the last pass saw.
    function SM:RouteChanged()
        local RR = RC.RaidRoute
        local list = RR and RR.ActiveMacroSwaps and RR:ActiveMacroSwaps() or nil
        local parts = {}
        for i, e in ipairs(list or {}) do
            local kind, name = SM.SwapAim(e)
            parts[i] = tostring(kind) .. "=" .. tostring(name) .. ">" .. SM.SwapItem(e)
        end
        local sig = table.concat(parts, "|")
        if sig == SM._routeSig then return end
        SM._routeSig = sig
        SM:RequestEvaluate()
    end

    -- An entry about to be switched off or deleted: what it was told to
    -- be is undone first (out of combat; in a fight it is undone when it
    -- ends, if the entry is still there).
    function SM:Release(mac)
        if type(mac) ~= "table" or InCombatLockdown() then return end
        local slot = SM.SlotOf(mac)
        if slot then
            if not GetCursorInfo() then ReleaseSlot(mac, slot) end
            return
        end
        local back = SwapBack(mac)
        if not back then return end
        local idx = GetMacroIndexByName(mac.macroName or "")
        if idx and idx > 0 and type(back.before) == "string" and GetMacroBody(idx) == back.body then
            Write(mac, idx, back.before, false, "(back)")
        end
        mac.swapBack = nil
    end

    function SM:Evaluate()
        local macros = RC.db.smartMacros
        if not macros then return end
        local inCombat = InCombatLockdown()
        SM._active = {}
        if not inCombat then SM:SyncChains() end
        -- TOLD WHAT TO BE is switched on by RC.smartKeys (SmartKeys.lua sets
        -- it). Off, nothing is told anything -
        -- a macro runs on its rules alone and a bar slot entry is left be
        -- (anything still told from before is put back).
        local telling = RC.smartKeys == true
        local bossKey, bossCfg, bossSwaps, routeSwaps
        if telling then
            bossKey, bossCfg = SM:Boss()
            bossSwaps = bossCfg and Index(bossCfg.macroSwaps) or nil
            routeSwaps = SM:RouteSwaps()
        end
        -- (a bar slot is only touched with nothing on the cursor: one more
        -- pass a little later if the player is dragging something now.
        -- Asked once a pass, and only when the list has a bar slot.)
        local cursorBusy

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

            local live = raidOk and mac.enabled
            local slot = SM.SlotOf(mac)
            if slot then
                -- A BAR SLOT: told what to be, or given back what it held
                local told = live and telling and SM:Told(mac, bossKey, bossCfg, bossSwaps, routeSwaps) or nil
                -- (a slot is never switched off: that is a macro's to do)
                if told and told.off then told = nil end
                if told then
                    SM._active[SM.KeyOf(mac)] = { item = told.item, itemId = told.itemId, off = told.off, swap = told.from }
                end
                if cursorBusy == nil and not inCombat then cursorBusy = GetCursorInfo() ~= nil end
                if inCombat then
                    -- (after the fight: its end runs a pass)
                elseif cursorBusy then
                    if told or mac.swapBack then SM._cursorRetry = true end
                elseif told then
                    TellSlot(mac, slot, told)
                else
                    ReleaseSlot(mac, slot)
                end
            elseif mac.macroName and mac.macroName ~= "" and (live or mac.swapBack) then
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
                local told
                if live and telling and idx and idx > 0 then told = SM:Told(mac, bossKey, bossCfg, bossSwaps, routeSwaps) end
                if told then
                    -- TOLD WHAT TO BE: an item, or off - whatever the rules
                    -- say. The text the macro had goes aside first, once.
                    local body = told.off and SM.OFF_BODY or WithChain(mac, UseBody(told.item))
                    local back = SwapBack(mac)
                    if not back then
                        back = { who = UnitGUID("player") }
                        local cur = GetMacroBody and GetMacroBody(idx) or nil
                        if type(cur) == "string" and cur ~= body then back.before = cur end
                        mac.swapBack = back
                    end
                    back.body = body
                    if told.off then
                        SM._active[mac.macroName] = { off = true, body = body, swap = told.from }
                    else
                        local tName, tId, tIcon = RuleTarget({ buildMode = "auto", buildItem = told.item }, body)
                        SM._active[mac.macroName] = {
                            item = tName, itemId = tId or told.itemId, icon = tIcon,
                            body = body, swap = told.from,
                        }
                    end
                    Write(mac, idx, body, inCombat, "(" .. told.from .. ")")
                elseif idx and idx > 0 then
                    local rules = mac.rules
                    local fired = false
                    if live and rules then
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
                                    Write(mac, idx, body, inCombat)
                                    fired = true
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
                    -- NOTHING TELLS IT ANYTHING ANY MORE. A rule that fired
                    -- has put its own text there. If none did, the macro
                    -- still holds what it was told to be: it gets back the
                    -- text it had before (only while it really still holds
                    -- ours - a macro edited by hand since is left alone).
                    local back = SwapBack(mac)
                    if type(mac.ownBody) == "string" and mac.ownBody ~= "" and GetMacroBody then
                        -- ITS RESTING TEXT (see the top of this section)
                        if not fired then
                            local cur = SM._pending[mac.id] and SM._pending[mac.id].body or GetMacroBody(idx)
                            local own = WithChain(mac, mac.ownBody)
                            if cur ~= own then
                                if mac.owned or cur == SM.OFF_BODY or (back and cur == back.body) then
                                    Write(mac, idx, own, inCombat, "(resting)")
                                elseif type(cur) == "string" and cur ~= "" then
                                    mac.ownBody = cur
                                end
                            end
                        end
                        if back and (not inCombat or fired) then mac.swapBack = nil end
                    elseif back then
                        if not fired and type(back.before) == "string" and GetMacroBody then
                            local cur = SM._pending[mac.id] and SM._pending[mac.id].body or GetMacroBody(idx)
                            if cur == back.body then
                                Write(mac, idx, back.before, inCombat, "(back)")
                            end
                        end
                        -- (in a fight the text goes back when it ends: keep
                        -- what is needed for that until the write lands)
                        if not inCombat or fired then mac.swapBack = nil end
                    end
                end
            end
        end

        if SM._cursorRetry then
            SM._cursorRetry = nil
            C_Timer.After(1, function() SM:RequestEvaluate() end)
        end
    end

    -- What macroName currently resolves to, or nil if no rule matches (a
    -- bar slot goes by "slot:<n>"). An entry told what to be says by what
    -- (.swap = "boss" | "route" | "ability") and, switched off, .off.
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
    eventFrame:RegisterEvent("ENCOUNTER_END")
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
        elseif event == "ENCOUNTER_END" then
            -- the fight is over, a kill or a wipe: a boss's swaps stop
            -- holding (still targeting the boss, alive, takes them again)
            SM._bossHold = nil
        end
        -- Every path lands on the same dirty flag plus one guarded 0.25s
        -- timer, so a burst of events costs a single Evaluate pass.
        SM:RequestEvaluate()
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
                -- (what it was told to be is undone before it goes)
                SM:Release(list[i])
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
