------------------------------------------------------------------------
-- Readycheck - Raid Route Engine
-- Owns the RaidRoute step engine: route.steps is an ORDERED ARRAY, each
-- entry a step table. Fields: type ("kills"|"encounter"), enabled,
-- desc (label override), mob+kills or mobs={ {mob,kills}, ... } (kill
-- gate, "kills" steps only), boss+when ("start"|"end"|"wipe", "encounter"
-- steps only), actions = { gearSet, trinket1, trinket2, slots[invSlot]=
-- itemId, reminders={ {text,icon,itemId,delay,tts}, ... } }.
-- Only the active index can complete; completion advances active by one
-- (CatchUpTo lets trash kills jump active forward out of order).
-- steps syncs over the mesh as a full-array replace, not a per-key merge:
-- reordering steps on one character overwrites the whole list on peers.
-- FireStepEquips is the single chokepoint that applies a step's gear set,
-- trinkets and slot items; every completion path funnels through it.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemIcon = GetItemIcon or (RCC and RCC.Compat and RCC.Compat.GetItemIcon)
local GetItemSpell = GetItemSpell or (RCC and RCC.Compat and RCC.Compat.GetItemSpell)
local RC = _G.Readycheck
if not RC then return end
RC._rrs = RC._rrs or {}
local _rrs = RC._rrs

    -- window after a reload/relog in which saved progress is restored;
    -- past this the route just starts fresh at step 1.
    local RUNTIME_RESTORE_WINDOW = 6 * 60 * 60

    local RR = {
        raidName  = nil,
        active    = 1,
        counts    = {},
        watchMobs = nil,
        activeReminders = {},
        testRaid  = nil,
        isTest    = false,
        armed     = false,
    }
    RR.BUILD = "2026-07-14g"
    RC.RaidRoute = RR

    local function NormName(n)
        if not n then return "" end
        return n:lower():gsub("^the%s+", "")
    end

    -- same folding RC.KillWatch uses for its keys (case and all
    -- whitespace dropped), so two configured spellings of one mob that
    -- KillWatch treats as the same creature also match each other here.
    local function CanonMob(n)
        if not n then return "" end
        return (n:lower():gsub("%s+", ""))
    end

    local function IsGateStep(step)
        if not step then return false end
        if step.enabled == false then return false end
        if step.type == "encounter" and step.when == "wipe" then return false end
        if step.type == "encounter" and (not step.boss or step.boss == "") then
            return false
        end
        if step.type == "kills" and not step.mobs then
        end
        -- a "kills" step with no mob requirement only counts as a gate if
        -- it still carries a payload (gear/trinket/slots/reminders);
        -- otherwise it's an inert placeholder and NormalizeActive skips it.
        if step.type == "kills" then
            local hasMobs = (step.mobs and #step.mobs > 0)
                or (step.mob and step.mob ~= "")
            if not hasMobs then
                local a = step.actions
                local hasPayload = a and ((a.gearSet and a.gearSet ~= "")
                    or (a.trinket1 and a.trinket1 ~= 0)
                    or (a.trinket2 and a.trinket2 ~= 0)
                    or (a.slots and next(a.slots))
                    or (a.reminders and #a.reminders > 0))
                if not hasPayload then return false end
            end
        end
        return true
    end

    -- first gate step after index `from` (disabled steps, wipe triggers
    -- and inert placeholders skipped) - the step a held or reminder step
    -- looks ahead to.
    local function NextGateIdx(steps, from)
        if not steps then return nil end
        for j = (from or 0) + 1, #steps do
            if IsGateStep(steps[j]) then return j end
        end
        return nil
    end

    -- identity of a step that survives the list being rebuilt (sync,
    -- import, edited while away): kind, label override, boss and mob
    -- names. Kill counts are left out so a count tweak keeps the step.
    local function StepFingerprint(step)
        if type(step) ~= "table" then return nil end
        local parts = { tostring(step.type) }
        local reqs = RR:GetStepMobs(step)
        if step.desc and step.desc ~= "" then
            parts[#parts + 1] = step.desc
        elseif not reqs then
            parts[#parts + 1] = RR:StepLabel(step)
        end
        if step.type == "encounter" then
            parts[#parts + 1] = NormName(step.boss) .. "/" .. tostring(step.when or "end")
        end
        if reqs then
            -- sorted, so reordering the mobs inside a step keeps its identity
            local names = {}
            for _, r in ipairs(reqs) do names[#names + 1] = CanonMob(r.mob) end
            table.sort(names)
            for _, n in ipairs(names) do parts[#parts + 1] = n end
        end
        return table.concat(parts, "|")
    end

    -- index of the step matching fp, nearest to `near` when the same step
    -- appears more than once (repeated packs). Second return is how many
    -- steps matched, for callers that only trust an unambiguous match.
    local function FindByFingerprint(fp, near)
        local steps = fp and RR:GetSteps()
        if not steps then return nil, 0 end
        local best, bestD, n = nil, nil, 0
        for j = 1, #steps do
            if StepFingerprint(steps[j]) == fp then
                n = n + 1
                local d = math.abs(j - (near or j))
                if not best or d < bestD then best, bestD = j, d end
            end
        end
        return best, n
    end

    -- runtime state that stores a step INDEX rather than the step: carried
    -- to the new index when the active step moves because the list was
    -- edited; the index-keyed tallies are dropped (their indices shifted).
    local function RemapIndexState(self, oldIdx, newIdx)
        if oldIdx ~= newIdx then
            local k = self._remFiredKey
            if type(k) == "string" then
                local head, num, tail = k:match("^(.-#A?)(%d+)(!*)$")
                if num and tonumber(num) == oldIdx then
                    self._remFiredKey = head .. newIdx .. tail
                end
            end
            if self._remStepFiredIdx == oldIdx then self._remStepFiredIdx = newIdx end
        end
        self._simPulled = nil
        self._farCounts = {}
    end

    function RR:GetSettings()
        if not RC.db then return nil end
        if not RC.db.raidRoute then
            if RC.defaults and RC.defaults.raidRoute and RC.DeepCopy then
                RC.db.raidRoute = RC.DeepCopy(RC.defaults.raidRoute)
            else
                RC.db.raidRoute = { enabled = false }
            end
        end
        if not RC.db.raidRoute.offByDefaultDone then
            RC.db.raidRoute.offByDefaultDone = true
            RC.db.raidRoute.enabled = false
        end
        RC.db.raidRoute.detection = nil
        RC.db.raidRoute.reminderDuration = nil
        if RC.db.raidRoute.trackerEnabled == nil then
            RC.db.raidRoute.trackerEnabled = true
        end
        if RC.db.raidRoute.trackerShowContext == nil then
            RC.db.raidRoute.trackerShowContext = false
        end
        return RC.db.raidRoute
    end

    function RR:GetRoute(raidName)
        if not raidName then return nil end
        local rem = RC.remoteEditMode
        if rem and rem.raidKey == raidName and RC._remoteEditData then
            local red = RC._remoteEditData
            local activeName = red.activeProfile or "Default"
            red.profiles = red.profiles or {}
            local profile = red.profiles[activeName]
            if type(profile) ~= "table" then
                profile = {}
                red.profiles[activeName] = profile
            end
            if not profile.route then profile.route = { steps = {} } end
            if not profile.route.steps then profile.route.steps = {} end
            return profile.route
        end
        if not (RC.db and RC.GetActiveRaidProfile) then return nil end
        local profile = RC:GetActiveRaidProfile(raidName)
        if type(profile) ~= "table" then return nil end
        if not profile.route then profile.route = { steps = {} } end
        if not profile.route.steps then profile.route.steps = {} end
        return profile.route
    end

    function RR:ExportRouteString(raidName)
        local route = self:GetRoute(raidName)
        if not route or not route.steps or #route.steps == 0 then return nil end
        local MSm = RC.MeshSync
        if not (MSm and MSm.SerializeTable) then return nil end
        return "WRROUTE1\n" .. raidName .. "\n"
            .. MSm:SerializeTable({ steps = route.steps })
    end

    -- Pulls the raid name and the data out of pasted route text.
    -- An export is three lines - "WRROUTE1", the raid, then the data as
    -- one long line - but by the time it is pasted here it has usually
    -- been through a chat app, a text file and a clipboard, and nothing
    -- about its line breaks or its surroundings can be relied on: Windows
    -- line endings, a code-block fence or a quote mark around it, blank
    -- lines, the three lines run together, the long line hard-wrapped.
    -- (The first version demanded the exact two line breaks it wrote, and
    -- refused anything pasted from outside the game as "not a route export
    -- string".) So: the header is found wherever it is; the raid name is
    -- whatever sits between it and the first "{", which a raid name never
    -- contains; the data runs from that "{" to the last "}". Raw line
    -- breaks inside the data are wrapping, never content - the exporter
    -- writes a line break inside a step as backslash-n - so they go.
    -- Returns raid, data - or nil, nil, what is missing.
    local function ParseRouteString(str)
        str = str:gsub("^\239\187\191", "")         -- a byte-order mark
        str = str:gsub("\194\160", " ")             -- non-breaking spaces
        str = str:gsub("\r", "\n")
        local at = str:find("WRROUTE1", 1, true)
        if not at then return nil, nil, "header" end
        local rest = str:sub(at + 8)
        local open = rest:find("{", 1, true)
        if not open then return nil, nil, "data" end
        local raid = rest:sub(1, open - 1)
        raid = raid:gsub("[%s>`]+", " ")
        raid = raid:gsub("^ ", "")
        raid = raid:gsub(" $", "")
        local body = rest:sub(open)
        local last = body:match(".*()}")
        if not last then return nil, nil, "data" end
        body = body:sub(1, last)
        body = body:gsub("\n", "")
        return raid, body
    end

    function RR:ImportRouteString(raidName, str)
        if type(str) ~= "string" or not str:find("%S") then
            return false, "nothing was pasted"
        end
        local srcRaid, body, missing = ParseRouteString(str)
        if missing == "header" then
            return false, "no WRROUTE1 header in the pasted text - copy the whole export, from WRROUTE1 to the last }"
        elseif missing then
            return false, "the route data is missing - only the header was pasted"
        end
        local MSm = RC.MeshSync
        if not (MSm and MSm.DeserializeTable) then return false, "mesh codec unavailable" end
        local parsed = MSm:DeserializeTable(body)
        if type(parsed) ~= "table" then
            -- something on the way turned the straight quotes curly
            local straight = body:gsub("\226\128[\156\157]", '"')
            straight = straight:gsub("\226\128[\152\153]", "'")
            if straight ~= body then parsed = MSm:DeserializeTable(straight) end
        end
        if type(parsed) ~= "table" then
            return false, "the route data is damaged or cut short (" .. #body
                .. " characters arrived). Send it as a text file or inside a code block, not as plain chat text"
        end
        if type(parsed.steps) ~= "table" or #parsed.steps == 0 then
            return false, "no steps in string"
        end
        for _, s in ipairs(parsed.steps) do
            if type(s) ~= "table" then return false, "malformed step data" end
        end
        local route = self:GetRoute(raidName)
        if not route then return false, "no active profile for this raid" end
        local newSteps = RC.DeepCopy(parsed.steps)
        if parsed.fromLogs == true then
            newSteps = self:MergeLogRoute(route.steps or {}, newSteps)
        end
        route.steps = newSteps
        local scrubbed = RC.ScrubUnknownGearSets
            and RC:ScrubUnknownGearSets({ route = route }) or 0
        if scrubbed > 0 then
            RC:Print(RCL["Route import: "] .. scrubbed .. RCL[" gear set name(s) from the"]
                .. RCL[" exporter don't exist here - cleared; re-pick your own sets"]
                .. RCL[" on those steps."])
        end
        if srcRaid ~= "" and srcRaid ~= raidName then
            RC:Print(RCL["Note: this route string was exported from '"] .. tostring(srcRaid)
                .. RCL["' and has been applied to '"] .. raidName .. "'.")
        end
        if parsed.fromLogs == true then
            self:MoveBossStepGearToConfig(raidName, newSteps)
            -- reminders picked on the page name the item but carry no
            -- icon; give them the item's (falls back to a note if the
            -- item is not cached yet - ShowRouteReminder tries again)
            for _, st in ipairs(newSteps) do
                local rems = st.actions and st.actions.reminders
                if type(rems) == "table" then
                    for _, r in ipairs(rems) do
                        if type(r) == "table" and not r.icon
                           and type(r.itemId) == "number" and r.itemId > 0 and GetItemIcon then
                            r.icon = GetItemIcon(r.itemId)
                        end
                    end
                end
            end
        end
        return true
    end

    -- A gear set picked on the route page for a boss step (pull or kill)
    -- belongs in that boss's raid config, where every other gear picker
    -- writes it: a "start" step's set is the set for the boss, an "end"
    -- step's the one to put on after the kill. The step itself is left
    -- clean, the same as the Route page does when it opens such a step.
    function RR:MoveBossStepGearToConfig(raidName, steps)
        -- the profile being edited (the remote toon's during a remote edit)
        local profile = RC.GetEditableActiveProfile and RC:GetEditableActiveProfile(raidName)
        if type(profile) ~= "table" or type(steps) ~= "table" then return 0 end
        local moved, names = 0, {}
        for _, st in ipairs(steps) do
            local a = type(st) == "table" and st.actions
            if st.type == "encounter" and st.boss and st.boss ~= "" and type(a) == "table"
               and type(a.gearSet) == "string" and a.gearSet ~= "" then
                local key = (RC.GetEncounterNameForBoss and RC:GetEncounterNameForBoss(raidName, st.boss)) or st.boss
                profile.bosses = profile.bosses or {}
                local cfg = profile.bosses[key]
                if type(cfg) ~= "table" then
                    cfg = { enabled = false, abilities = {} }
                    profile.bosses[key] = cfg
                end
                cfg.abilities = cfg.abilities or {}
                local gs = cfg.abilities.gearswap
                if type(gs) ~= "table" then
                    gs = { enabled = false, gearSet = "", postCombatSet = "", postCombatSwap = false }
                    cfg.abilities.gearswap = gs
                end
                RC:SetBossGearSet(gs, (st.when == "start") and "gearSet" or "postCombatSet", a.gearSet)
                a.gearSet = nil
                moved = moved + 1
                names[#names + 1] = key .. (st.when == "start" and RCL[" (for the boss)"] or RCL[" (after the kill)"])
            end
        end
        if moved > 0 then
            RC:Print(RCL["Gear sets from the route page set on: "] .. table.concat(names, ", ") .. ".")
            if RC.SaveConfigurationToProfile then RC:SaveConfigurationToProfile() end
        end
        return moved
    end

    -- Which inventory slots an item of each equip location can go in
    -- (the same table the Route page's slot pickers use).
    local CHAR_EQUIPLOC_SLOTS = {
        INVTYPE_HEAD = {1}, INVTYPE_NECK = {2}, INVTYPE_SHOULDER = {3},
        INVTYPE_CLOAK = {15}, INVTYPE_CHEST = {5}, INVTYPE_ROBE = {5},
        INVTYPE_WRIST = {9}, INVTYPE_HAND = {10}, INVTYPE_WAIST = {6},
        INVTYPE_LEGS = {7}, INVTYPE_FEET = {8}, INVTYPE_FINGER = {11, 12},
        INVTYPE_TRINKET = {13, 14},
        INVTYPE_WEAPON = {16, 17}, INVTYPE_2HWEAPON = {16},
        INVTYPE_WEAPONMAINHAND = {16}, INVTYPE_WEAPONOFFHAND = {17},
        INVTYPE_SHIELD = {17}, INVTYPE_HOLDABLE = {17},
        INVTYPE_RANGED = {18}, INVTYPE_RANGEDRIGHT = {18},
        INVTYPE_THROWN = {18}, INVTYPE_RELIC = {18},
    }

    -- This character for the route page: its gear sets (the built-in
    -- ones and ItemRack's), each slot as an item id; every piece of gear
    -- it has on or in its bags (id, name, slots it fits) for trinket and
    -- single-slot swaps; and the raid consumables in its bags for "use"
    -- reminders. Nothing else about the character goes out.
    -- Returns text, set count, gear count, consumable count.
    function RR:CharacterString()
        local MSm = RC.MeshSync
        if not (MSm and MSm.SerializeTable) then return nil end
        local function ItemId(v)
            if type(v) == "number" then return v > 0 and v or nil end
            if type(v) ~= "string" then return nil end
            local id = v:match("item:(%d+)") or v:match("^(%d+)")
            id = tonumber(id)
            return id and id > 0 and id or nil
        end
        local function ItemsOf(equip)
            local items, n = {}, 0
            if type(equip) ~= "table" then return items, 0 end
            for slot, v in pairs(equip) do
                slot = tonumber(slot)
                local id = ItemId(v)
                if slot and id and slot >= 1 and slot <= 19 then
                    items[slot] = id
                    n = n + 1
                end
            end
            return items, n
        end
        local sets, seen = {}, {}
        -- the set's icon for the page: a texture path becomes its file
        -- name (ic); a file id is matched to one of the set's own items
        -- (ici), since the page can only show icons by name or by item
        local function IconOf(set, items)
            local ic = type(set) == "table" and set.icon
            if type(ic) == "string" then
                local nm = ic:match("[\\/]([^\\/]+)$") or ic
                nm = nm:gsub("%.[bB][lL][pP]$", ""):lower()
                if nm ~= "" and not nm:find("questionmark", 1, true) then return nm, nil end
            elseif type(ic) == "number" and ic ~= 134400 and GetItemIcon then
                for _, id in pairs(items) do
                    if GetItemIcon(id) == ic then return nil, id end
                end
            end
            return nil, nil
        end
        local function Add(name, src, equip, set)
            if type(name) ~= "string" or name == "" or name:find("^~") or seen[name] then return end
            local items, n = ItemsOf(equip)
            if n == 0 then return end
            seen[name] = true
            local ic, ici = IconOf(set, items)
            sets[#sets + 1] = { name = name, src = src, items = items, ic = ic, ici = ici }
        end
        local gm = RC.GearManager and RC.GearManager.sets
        if type(gm) == "table" then
            for name, set in pairs(gm) do Add(name, "rc", type(set) == "table" and set.equip, set) end
        end
        if type(RC.db) == "table" and type(RC.db.gearSets) == "table" then
            for name, set in pairs(RC.db.gearSets) do Add(name, "rc", type(set) == "table" and set.equip, set) end
        end
        if type(ItemRackUser) == "table" and type(ItemRackUser.Sets) == "table" then
            for name, set in pairs(ItemRackUser.Sets) do
                Add(name, "ir", type(set) == "table" and (set.equip or set), set)
            end
        end
        table.sort(sets, function(a, b) return a.name < b.name end)

        local gear, gearSeen = {}, {}
        local function AddGear(id)
            if type(id) ~= "number" or id <= 0 or gearSeen[id] then return end
            local name, _, _, _, _, _, _, _, loc = GetItemInfo(id)
            local slots = loc and CHAR_EQUIPLOC_SLOTS[loc]
            if not slots or type(name) ~= "string" or name == "" then return end
            gearSeen[id] = true
            local s = {}
            for i, v in ipairs(slots) do s[i] = v end
            gear[#gear + 1] = { id = id, n = name, s = s }
        end
        for slot = 1, 18 do
            if slot ~= 4 then AddGear(GetInventoryItemID("player", slot)) end
        end
        local known = {}
        for catKey, cat in pairs(RC.raidConsumables or {}) do
            if type(cat) == "table" and type(cat.items) == "table" then
                for iid, d in pairs(cat.items) do
                    if type(iid) == "number" and type(d) == "table"
                       and d.baseItemId == nil and d.slot == nil and not known[iid] then
                        known[iid] = { c = catKey, n = d.name }
                    end
                end
            end
        end
        local use, useSeen = {}, {}
        RC.Bags:Each(function(_, _, id)
            AddGear(id)
            local k = known[id]
            if k and not useSeen[id] then
                useSeen[id] = true
                local nm = k.n or GetItemInfo(id) or ("Item " .. id)
                use[#use + 1] = { id = id, n = nm, c = k.c }
            end
        end)
        table.sort(gear, function(a, b) return a.n < b.n end)
        table.sort(use, function(a, b) return a.n < b.n end)

        local _, class = UnitClass("player")
        return "WRCHAR1\n" .. RC:GetCharacterKey() .. "\n"
            .. MSm:SerializeTable({ class = class or "", sets = sets, gear = gear, use = use }),
            #sets, #gear, #use
    end

    -- A route made from a Warcraft Logs report (fromLogs) is only mobs and
    -- bosses in kill order. What the old route had on top of that is kept:
    --   * a boss step's gear, trinkets, slots, reminders, name and on/off
    --     go to the same boss and moment in the new list;
    --   * a kill step's go to the new step with the very same mobs (each
    --     new step takes one old step, in order), with its map place too;
    --   * pull and wipe steps the log cannot know about are put back just
    --     before / after that boss's kill;
    --   * steps with no mobs (reminder-only) go back after the step they
    --     followed;
    --   * everything after the last boss the log reached is put back at the
    --     end, so a log of half a raid does not wipe the other half.
    -- Old steps in the covered part that match nothing are replaced by the
    -- log's; how many, and how many of those carried gear or reminders, is
    -- said out loud.
    local function HasPayload(st)
        local a = st and st.actions
        return a and ((a.gearSet and a.gearSet ~= "")
            or (a.trinket1 and a.trinket1 ~= 0) or (a.trinket2 and a.trinket2 ~= 0)
            or (a.slots and next(a.slots))
            or (a.reminders and #a.reminders > 0)
            or (a.reminderText and a.reminderText ~= "")) and true or false
    end
    local function MobKey(st)
        local reqs = RR:GetStepMobs(st)
        if not reqs then return nil end
        local names = {}
        for _, r in ipairs(reqs) do names[#names + 1] = CanonMob(r.mob) end
        table.sort(names)
        return table.concat(names, "+")
    end
    local function BossKey(st)
        if st.type ~= "encounter" or not st.boss or st.boss == "" then return nil end
        return NormName(st.boss) .. "|" .. tostring(st.when or "end")
    end

    function RR:MergeLogRoute(oldSteps, newSteps)
        -- the new steps by what they are, in order
        local bossAt, mobList = {}, {}
        for j, st in ipairs(newSteps) do
            local bk = BossKey(st)
            if bk then
                bossAt[bk] = bossAt[bk] or j
            else
                local k = MobKey(st)
                if k then
                    mobList[k] = mobList[k] or {}
                    table.insert(mobList[k], j)
                end
            end
        end
        local claimed = {}
        local function Carry(old, j)
            local nst = newSteps[j]
            if HasPayload(old) and not HasPayload(nst) then nst.actions = RC.DeepCopy(old.actions) end
            if old.enabled == false then nst.enabled = false end
            if old.desc and old.desc ~= "" then nst.desc = old.desc end
            claimed[j] = true
        end

        -- pass 1: what each old step became (j), and the last old boss step
        -- the log reached
        local matchOf, lastBossOld, lastBossNew = {}, 0, 0
        for i, old in ipairs(oldSteps) do
            local bk = BossKey(old)
            if bk then
                local j = bossAt[bk]
                if j and not claimed[j] then
                    Carry(old, j)
                    matchOf[i] = j
                end
                local reached = j or bossAt[NormName(old.boss) .. "|end"]
                if reached then lastBossOld, lastBossNew = i, reached end
            else
                local k = MobKey(old)
                for _, j in ipairs(k and mobList[k] or {}) do
                    if not claimed[j] then
                        Carry(old, j)
                        matchOf[i] = j
                        break
                    end
                end
            end
        end

        -- the old route's later part only counts as "past the log" when the
        -- log has no boss after the last one both share
        local logGoesOn = false
        for j = lastBossNew + 1, #newSteps do
            if newSteps[j].type == "encounter" then logGoesOn = true break end
        end
        if logGoesOn or lastBossOld == 0 then lastBossOld = #oldSteps end

        -- pass 2: where the unmatched old steps go
        local before, after, tail = {}, {}, {}
        local kept, replaced, lostPayload = 0, 0, 0
        local prevJ = nil   -- new index of the last matched old step so far
        for i, old in ipairs(oldSteps) do
            local j = matchOf[i]
            if j then
                prevJ = j
                if HasPayload(old) then kept = kept + 1 end
            else
                local bk = BossKey(old)
                local home
                if i > lastBossOld then
                    home = "tail"
                elseif bk and old.when ~= "end" and bossAt[NormName(old.boss) .. "|end"] then
                    home = (old.when == "start") and "before" or "after"
                elseif not bk and not MobKey(old) then
                    home = "afterPrev"
                end
                if home == "tail" then
                    tail[#tail + 1] = RC.DeepCopy(old)
                elseif home == "before" or home == "after" then
                    local k = bossAt[NormName(old.boss) .. "|end"]
                    local list = (home == "before") and before or after
                    list[k] = list[k] or {}
                    table.insert(list[k], RC.DeepCopy(old))
                elseif home == "afterPrev" then
                    local k = prevJ or 0
                    after[k] = after[k] or {}
                    table.insert(after[k], RC.DeepCopy(old))
                else
                    replaced = replaced + 1
                    if HasPayload(old) then lostPayload = lostPayload + 1 end
                end
                if home and HasPayload(old) then kept = kept + 1 end
            end
        end

        local out = {}
        for _, a in ipairs(after[0] or {}) do out[#out + 1] = a end
        for j, st in ipairs(newSteps) do
            for _, b in ipairs(before[j] or {}) do out[#out + 1] = b end
            out[#out + 1] = st
            for _, a in ipairs(after[j] or {}) do out[#out + 1] = a end
        end
        for _, t in ipairs(tail) do out[#out + 1] = t end
        if kept > 0 or replaced > 0 or #tail > 0 then
            local msg = string.format(RCL["Route from logs: kept the gear and reminders of %d step(s)"], kept)
            if #tail > 0 then
                msg = msg .. string.format(RCL["; %d step(s) past the end of the log stay at the end"], #tail)
            end
            if replaced > 0 then
                msg = msg .. string.format(RCL["; %d old step(s) the log has no match for were replaced"], replaced)
                if lostPayload > 0 then
                    msg = msg .. string.format(RCL[" (%d with gear or reminders - export the old route first if you need them)"], lostPayload)
                end
            end
            RC:Print(msg .. ".")
        end
        return out
    end

    function RR:GetSteps()
        if not self.raidName then return nil end
        if not (RC.db and RC.GetActiveRaidProfile) then return nil end
        local profile = RC:GetActiveRaidProfile(self.raidName)
        if type(profile) ~= "table" then return nil end
        if not profile.route then profile.route = { steps = {} } end
        if not profile.route.steps then profile.route.steps = {} end
        return profile.route.steps
    end

    function RR:StepLabel(step)
        if not step then return "?" end
        if step.desc and step.desc ~= "" then return step.desc end
        if step.type == "encounter" then
            local verb = "Pull "
            if step.when == "end" then verb = "Kill " end
            if step.when == "wipe" then verb = "On wipe: " end
            return verb .. (step.boss or "?")
        end
        local reqs = self:GetStepMobs(step)
        if reqs then
            local parts = {}
            for _, r in ipairs(reqs) do
                parts[#parts + 1] = (r.kills or 1) .. "x " .. (r.mob or "?")
            end
            return table.concat(parts, " + ")
        end
        local a = step.actions
        if a and a.reminders and a.reminders[1] and a.reminders[1].text
           and a.reminders[1].text ~= "" then
            return a.reminders[1].text
        end
        return (step.kills or 1) .. "x " .. (step.mob or "?")
    end

    function RR:StepHasUseReminder(step)
        local a = step and step.actions
        local rems = a and a.reminders
        if not rems then return false end
        for _, r in ipairs(rems) do
            local iid = r.itemId
            -- "dummy" is a placeholder itemId meaning "whatever target
            -- dummy is in the zone"; 16023 (Target Dummy) is the fallback
            -- when the zone-specific dummy can't be resolved.
            if iid == "dummy" then
                iid = (RC.ResolveTargetDummy and RC:ResolveTargetDummy()) or 16023
            end
            if iid and iid ~= 0 then
                local util = RC.utilityItems and RC.utilityItems[iid]
                if util and util.spellId then return true end
                if RC.potionItemIds and RC.potionData and RC.potionData.potions then
                    local key = RC.potionItemIds[iid]
                    local p = key and RC.potionData.potions[key]
                    if p and p.spellId then return true end
                end
                local _, sid = GetItemSpell(iid)
                if sid then return true end
            end
        end
        return false
    end

    function RR:StepHoldsAfterFire(step, hasNext)
        if self._useHoldGen ~= nil and self._useHoldGen == (self._payloadGen or 0) then
            return self._useHoldActive == true
        end
        return self:StepHasUseReminder(step) == true
    end

    function RR:IsReminderStep(step)
        return step ~= nil
            and step.type == "kills"
            and step.enabled ~= false
            and self:GetStepMobs(step) == nil
            and step.actions ~= nil
            and step.actions.reminders ~= nil
            and #step.actions.reminders > 0
    end

    -- mobs (list of {mob, kills}) takes precedence over the older
    -- single-target mob/kills fields; both describe the same kill gate.
    function RR:GetStepMobs(step)
        if not step or step.type ~= "kills" then return nil end
        if step.mobs and #step.mobs > 0 then return step.mobs end
        if step.mob and step.mob ~= "" then
            return { { mob = step.mob, kills = step.kills or 1 } }
        end
        return nil
    end

    -- counts is a lifetime per-mob-name kill tally for the whole route;
    -- _stepBase snapshots it when a step becomes active so this step's
    -- progress is (counts - snapshot), not the raid's running total.

    -- every path that moves the active step to a fresh gate clears the
    -- kill tally together with the far-step tallies and the per-step
    -- snapshots; they are only meaningful as a set.
    local function ResetCounts()
        RR.counts     = {}
        RR._farCounts = {}
        RR._stepBase  = {}
    end

    function RR:EnsureBase(step)
        if not step then return end
        self._stepBase = self._stepBase or {}
        if self._stepBase[step] then return end
        local reqs = self:GetStepMobs(step)
        if not reqs then return end
        local b = {}
        for _, r in ipairs(reqs) do
            if r.mob then b[r.mob] = self.counts[r.mob] or 0 end
        end
        self._stepBase[step] = b
    end

    function RR:MobHave(step, mob)
        local c = self.counts[mob] or self.counts[string.lower(mob or "")] or 0
        local b = self._stepBase and self._stepBase[step]
        local h = c - (b and b[mob] or 0)
        if h < 0 then h = 0 end
        return h
    end

    function RR:GetStepProgress(step)
        local reqs = self:GetStepMobs(step)
        if not reqs then return 0, 0, nil end
        local cur, total, firstUnmet = 0, 0, nil
        for _, r in ipairs(reqs) do
            local need = r.kills or 1
            local have = self:MobHave(step, r.mob)
            if have > need then have = need end
            cur = cur + have
            total = total + need
            if not firstUnmet and have < need then firstUnmet = r end
        end
        return cur, total, firstUnmet
    end

    function RR:GetProgressText()
        local steps = self:GetSteps()
        local step = steps and steps[self.active]
        if not step or step.type ~= "kills" then return "" end
        local cur, total = self:GetStepProgress(step)
        return cur .. "/" .. total
    end

    function RR:ResetRuntime(raidName)
        self._unmatchedDeaths = nil
        self._transition = nil
        self._remFiredKey = nil
        self._remStepFiredIdx = nil
        self._simPulled = nil
        self._suppressPayload = nil
        self._awaitUse = nil
        self.finished = false
        self._finishAnnounce = nil
        self.raidName = raidName
        self.active   = 1
        self._restoredRun = nil
        self._lastCheckpoint = nil
        self._anchorList, self._anchorStep, self._anchorIdx = nil, nil, nil
        -- the far-step tallies and per-step snapshots belong to the old
        -- run too; left behind they give a new run a head start.
        ResetCounts()
    end

    -- active always lands on a gate step (IsGateStep); disabled steps,
    -- unconfigured encounters and payload-less kill placeholders are
    -- auto-skipped here rather than being valid stopping points.
    function RR:NormalizeActive()
        local steps = self:GetSteps()
        if not steps then return end
        while self.active <= #steps and not IsGateStep(steps[self.active]) do
            self.active = self.active + 1
        end
    end

    function RR:MarkRuntimeDirty()
        if self._rtFlushPending then return end
        self._rtFlushPending = true
        C_Timer.After(0.5, function()
            RR._rtFlushPending = nil
            RR:SaveRuntime()
        end)
    end

    function RR:SaveRuntime()
        local settings = self:GetSettings()
        if not settings then return end
        if self.raidName and not self.isTest then
            local rt = settings.runtime
            if not rt then
                rt = {}
                settings.runtime = rt
            end
            rt.raid    = self.raidName
            rt.active  = self.active
            rt.counts  = rt.counts or {}
            for k in pairs(rt.counts) do rt.counts[k] = nil end
            for k, v in pairs(self.counts) do rt.counts[k] = v end
            rt.awaitUse = self._awaitUse and true or nil
            rt.remFired = self._remFiredKey
            rt.base = nil
            local stepsA = self:GetSteps()
            local as = stepsA and stepsA[self.active]
            local ab = as and self._stepBase and self._stepBase[as]
            if ab then
                rt.base = {}
                for m, v in pairs(ab) do rt.base[m] = v end
            end
            -- which step we were on, so a restore finds it again even if
            -- the route was edited or re-synced in between.
            rt.fp = StepFingerprint(as)
            rt.v = 2
            rt.savedAt = time()
        end
    end

    -- restores saved progress only within RUNTIME_RESTORE_WINDOW and only
    -- for a matching raid + runtime format (rt.v); a stale or foreign save
    -- is ignored and the route starts clean.
    function RR:TryRestoreRuntime(raidName)
        local settings = self:GetSettings()
        local rt = settings and settings.runtime
        if rt and rt.v == 2 and rt.raid == raidName and rt.savedAt
           and (time() - rt.savedAt) < RUNTIME_RESTORE_WINDOW then
            self.active = rt.active or 1
            self._remFiredKey = rt.remFired
            -- never restore by index alone: if the route changed while we
            -- were away, find the step we were on by what it is.
            -- Only an unambiguous match is trusted: with the step gone, or
            -- present more than once (repeated packs), there is no way to
            -- tell which one we were on, so start over rather than guess.
            if rt.fp then
                local stepsF = self:GetSteps()
                if StepFingerprint(stepsF and stepsF[self.active]) ~= rt.fp then
                    local j, nMatch = FindByFingerprint(rt.fp, self.active)
                    if not j or nMatch ~= 1 then
                        self.active = 1
                        self._remFiredKey = nil
                        RC:Print(RCL["Route changed since last time - starting from the first step."])
                        return false
                    end
                    RC:DebugPrint("Route: saved step moved " .. self.active .. " -> " .. j
                        .. " (route changed since the save)", "route")
                    RemapIndexState(self, self.active, j)
                    self.active = j
                end
            end
            self._awaitUse = rt.awaitUse and true or nil
            if self._awaitUse then
                local idx = self.active
                C_Timer.After(0.3, function()
                    RR:OnRouteEquipsLanded(idx)
                end)
            end
            ResetCounts()
            if rt.counts then
                for k, v in pairs(rt.counts) do self.counts[k] = v end
                if rt.base then
                    local stepsR = self:GetSteps()
                    local asR = stepsR and stepsR[self.active]
                    if asR then
                        local b = {}
                        for m, v in pairs(rt.base) do b[m] = v end
                        self._stepBase = self._stepBase or {}
                        self._stepBase[asR] = b
                    end
                end
            elseif rt.count and rt.count > 0 then
            end
            RC:DebugPrint("Route: restored progress (step " .. self.active
                .. ") from before reload", "route")
            -- until a boss checkpoint confirms it, a restored position may
            -- belong to an earlier run (see HandleEncounter).
            self._restoredRun = true
            return true
        end
        return false
    end

    function RR:SetActiveStep(idx)
        self.finished = false
        self._finishAnnounce = nil
        self:ClearReminders()
        self.active = idx or 1
        self._restoredRun = nil
        ResetCounts()
        self:NormalizeActive()
        self:UpdateArming()
        self:SaveRuntime()
        RC:DebugPrint("Route: active step manually set to " .. tostring(self.active), "route")
        self:RefreshUI()
    end

    function RR:ResetProgress()
        self:SetActiveStep(1)
    end

    -- EDITING MID-RAID. The editor calls SnapshotActiveStep before it
    -- deletes, moves, duplicates or inserts a step and ReanchorActiveStep
    -- after, so the route stays on the same logical step rather than on
    -- the same index. Only acts when the list edited is the one being
    -- tracked (not a remote route or another raid's).
    -- editedList (optional) is the array the caller is about to change; a
    -- different array than the tracked one gets no snapshot at all.
    function RR:SnapshotActiveStep(editedList)
        local list = self.raidName and self:GetSteps()
        if not list then return nil end
        if editedList ~= nil and editedList ~= list then return nil end
        return { list = list, step = list[self.active], idx = self.active or 1 }
    end

    function RR:ReanchorActiveStep(snap)
        if not snap then return end
        local list = self:GetSteps()
        if not list or list ~= snap.list then return end
        local oldIdx = self.active or 1
        local newIdx, gone
        if snap.step then
            for j = 1, #list do
                if list[j] == snap.step then newIdx = j; break end
            end
            if not newIdx then
                gone = true
                newIdx = math.min(snap.idx, #list + 1)
            end
        else
            newIdx = #list + 1
        end
        self.active = newIdx
        RemapIndexState(self, oldIdx, newIdx)
        local skipGearOnly
        if gone then
            -- the step we were on was deleted: stay on whatever now sits
            -- at that position and fire nothing for it - mark its
            -- activation payload as already fired.
            self._awaitUse = nil
            self:ClearReminders()
            self:NormalizeActive()
            local cur = list[self.active]
            if cur then
                local rk = tostring(self.raidName) .. "#"
                if self:IsReminderStep(cur) then
                    self._remFiredKey = rk .. self.active
                    self._remStepFiredIdx = self.active
                elseif cur.type == "kills" and not self:GetStepMobs(cur) then
                    -- gear-only step: it has no gate to wait on, so marking
                    -- it fired would park the route on it for good. Pass it
                    -- silently instead (below, after the save).
                    self._remFiredKey = rk .. "A" .. self.active
                    skipGearOnly = cur
                end
                -- the step now under the pointer counts from here on: no
                -- snapshot yet means MobHave reads the raid's whole tally
                -- for its mobs. One it already has (next-step pre-credit)
                -- is its own and stays.
                self:EnsureBase(cur)
            end
        end
        if oldIdx ~= self.active then
            RC:DebugPrint("Route: step list edited - active step " .. oldIdx
                .. " -> " .. self.active .. (gone and " (was deleted)" or ""), "route")
        end
        self:UpdateArming()
        self:SaveRuntime()
        self:RefreshTracker()
        if skipGearOnly and list[self.active] == skipGearOnly then
            self._suppressPayload = true
            self:CompleteStep(skipGearOnly)
            self._suppressPayload = nil
        end
    end

    function RR:GetStatusText(viewedRaid)
        local settings = self:GetSettings()
        if not settings or not settings.enabled then
            return "Disabled"
        end
        if not self.raidName then
            return "Waiting - not inside a raid (use Track Here to test)"
        end
        local prefix = self.isTest and "[TEST] " or ""
        if viewedRaid and self.raidName ~= viewedRaid then
            return prefix .. "Tracking " .. self.raidName .. " (viewing a different raid)"
        end
        local steps = self:GetSteps()
        if not steps or #steps == 0 then
            return prefix .. "No steps configured"
        end
        if self.active > #steps then
            return prefix .. "Route complete (" .. #steps .. " steps)"
        end
        local step = steps[self.active]
        if step and step.type == "kills" then
            local reqs = self:GetStepMobs(step)
            if not reqs then
                return prefix .. "Step " .. self.active .. " of " .. #steps
                    .. ": no mob picked - counting paused"
            end
            local cur, total, unmet = self:GetStepProgress(step)
            local detail = ""
            if unmet then
                detail = " - " .. unmet.mob .. " "
                    .. self:MobHave(step, unmet.mob) .. "/" .. (unmet.kills or 1)
            end
            return prefix .. "Step " .. self.active .. " of " .. #steps .. ": "
                .. cur .. "/" .. total .. detail
        end
        if step and step.type == "encounter" and (not step.boss or step.boss == "") then
            return prefix .. "Step " .. self.active .. " of " .. #steps
                .. ": no boss picked - waiting"
        end
        return prefix .. "Step " .. self.active .. " of " .. #steps .. ": waiting for "
            .. self:StepLabel(step)
    end

    -- (no frame where the route does not run: Core_Flavor)
    local eventFrame = RC:FeatureOn("raid_route") and CreateFrame("Frame") or RC.FlavorNullFrame

    function RR:SyncBossStepsFromConfig(raidName)
        if not raidName then return end
        local prof = RC.GetActiveRaidProfile and RC:GetActiveRaidProfile(raidName)
        local bosses = prof and prof.bosses
        if not bosses then return end
        prof.route = prof.route or {}
        prof.route.steps = prof.route.steps or {}
        local steps = prof.route.steps
        prof.route.mirroredBossSteps = prof.route.mirroredBossSteps or {}
        local mirrored = prof.route.mirroredBossSteps
        for _, s in ipairs(steps) do
            if s.type == "encounter" and s.boss and s.boss ~= "" then
                mirrored[s.boss:lower() .. "|" .. tostring(s.when)] = true
            end
        end
        local order, inOrder = {}, {}
        local rd = RC.raidData and RC.raidData[raidName]
        if rd and rd.bosses then
            for _, bn in ipairs(rd.bosses) do
                if bosses[bn] then
                    order[#order + 1] = bn
                    inOrder[bn] = true
                end
            end
        end
        -- Phase entries ("C'Thun_phase2") and single horsemen are not
        -- route bosses: a step named after one never matches a pull or a
        -- kill. Their boss's own entry is what the route mirrors.
        local extras = {}
        for bn in pairs(bosses) do
            if not inOrder[bn] and RC:EncounterMenuName(bn) == bn then
                extras[#extras + 1] = bn
            end
        end
        table.sort(extras)
        for _, bn in ipairs(extras) do order[#order + 1] = bn end

        local added = 0
        for _, bossName in ipairs(order) do
            local b = bosses[bossName]
            local gs = b.abilities and b.abilities.gearswap
            local fe = b.forceEquip
            local pullCfg = (gs and gs.gearSet and gs.gearSet ~= "")
                or (fe and ((fe.onTarget and next(fe.onTarget) ~= nil)
                    or (fe.slot1 and fe.slot1 ~= 0) or (fe.slot2 and fe.slot2 ~= 0))) or false
            local killCfg = (gs and gs.postCombatSet and gs.postCombatSet ~= "")
                or (fe and ((fe.deathConfig and fe.deathConfig ~= "")
                    or fe.deathSlot1 ~= nil or fe.deathSlot2 ~= nil
                    or (fe.onDeath and next(fe.onDeath) ~= nil))) or false
            if pullCfg and not mirrored[bossName:lower() .. "|start"] then
                mirrored[bossName:lower() .. "|start"] = true
                steps[#steps + 1] = { type = "encounter", boss = bossName,
                    when = "start", enabled = false, actions = {} }
                added = added + 1
            end
            if killCfg and not mirrored[bossName:lower() .. "|end"] then
                mirrored[bossName:lower() .. "|end"] = true
                steps[#steps + 1] = { type = "encounter", boss = bossName,
                    when = "end", enabled = false, actions = {} }
                added = added + 1
            end
        end
        if added > 0 then
            RC:SaveConfigurationToProfile()
            RC:DebugPrint("Route: added " .. added
                .. " disabled boss step(s) mirroring raid config", "route")
            if self._uiRefresh then self._uiRefresh() end
        end
    end

    function RR:UpdateArming()
        -- routes run on the game versions whose raids are listed (Core_Flavor)
        if not RC:FeatureOn("raid_route") then return end
        local settings = self:GetSettings()
        local realRaid = RC.GetEffectiveRaidName and RC:GetEffectiveRaidName() or nil
        if realRaid then self.testRaid = nil end
        local raidName = realRaid or self.testRaid
        self.isTest = (realRaid == nil and self.testRaid ~= nil)

        if raidName then self:SyncBossStepsFromConfig(raidName) end

        local adoptedRealRaid = false
        local restored = false
        if raidName ~= self.raidName then
            self:ClearReminders()
            self:ResetRuntime(raidName)
            if raidName and realRaid then
                adoptedRealRaid = true
                restored = self:TryRestoreRuntime(raidName)
            end
        end

        local steps = self:GetSteps()

        -- the step LIST itself was replaced while tracking (mesh sync,
        -- import, profile switch): the old step table is gone, so find the
        -- step we were on again by fingerprint rather than by index.
        if steps and self._anchorList and self._anchorList ~= steps then
            local oldStep, oldIdx = self._anchorStep, self.active or 1
            local j
            if oldStep then
                j = FindByFingerprint(StepFingerprint(oldStep), self._anchorIdx or oldIdx)
            else
                j = #steps + 1
            end
            if j then
                local ob = self._stepBase and oldStep and self._stepBase[oldStep]
                RemapIndexState(self, oldIdx, j)
                self.active = j
                if ob and steps[j] then self._stepBase[steps[j]] = ob end
            else
                RC:Print(RCL["Route: the step you were on is no longer in this route - starting from step 1."])
                self._awaitUse = nil
                self._remFiredKey = nil
                self.active = 1
                ResetCounts()
            end
            self._anchorList = nil
            self:SaveRuntime()
        end

        self:NormalizeActive()
        self._anchorList = steps
        self._anchorIdx = self.active
        self._anchorStep = steps and steps[self.active] or nil
        local activeStep = (steps and self.active <= #steps) and steps[self.active] or nil

        if steps then
            for si = 1, #steps do
                local s = steps[si]
                if s and s.type ~= "kills" and s.type ~= "encounter" then
                    if (s.mobs and #s.mobs > 0) or (s.mob and s.mob ~= "") then
                        s.type = "kills"
                    end
                end
                if s and s.type == "encounter" and s.when == nil then
                    s.when = "end"
                end
            end
        end
        -- a reminder-only step (no kill gate) fires its payload the moment
        -- it becomes active rather than waiting on a kill; remKey dedupes
        -- so re-entering UpdateArming doesn't re-fire the same step.
        local remStep = (activeStep and self:IsReminderStep(activeStep)) and activeStep or nil
        local remKey = remStep and (tostring(raidName) .. "#" .. self.active) or nil
        if remStep and settings and settings.enabled and self._remFiredKey ~= remKey then
            self._remFiredKey = remKey
            local tr = self._transition
            local delay = tr and math.max(0, tr.expires - GetTime()) + 0.1 or 0
            local function FireIt()
                if self._remFiredKey ~= remKey then return end
                local st2 = self:GetSteps()
                if not (st2 and st2[self.active] == remStep) then return end
                if not self:IsReminderStep(remStep) then
                    RC:DebugPrint("Route: activation fire skipped - step "
                        .. self.active .. " gained a kill gate", "route")
                    return
                end
                RC:DebugPrint("Route: ACTIVATION payload fired for step "
                    .. self.active .. " (" .. self:StepLabel(remStep) .. ")", "route")
                self:FireStepEquips(remStep)
                self:FireStepReminders(remStep)
                self._remStepFiredIdx = self.active
                self:RefreshTracker()
            end
            if delay > 0 then C_Timer.After(delay, FireIt) else FireIt() end
        end

        -- a "kills" step with no mob requirement can never get kill credit,
        -- so if it has a payload it self-completes here instead of waiting.
        if activeStep and not remStep and settings and settings.enabled
           and activeStep.type == "kills"
           and self:GetStepMobs(activeStep) == nil then
            local a3 = activeStep.actions
            local hasPayload = a3 and ((a3.gearSet and a3.gearSet ~= "")
                or (a3.trinket1 and a3.trinket1 ~= 0)
                or (a3.trinket2 and a3.trinket2 ~= 0)
                or (a3.slots and next(a3.slots))
                or (a3.reminders and #a3.reminders > 0))
            if hasPayload then
                local akey = tostring(raidName) .. "#A" .. self.active
                if self._remFiredKey ~= akey
                   and self:GetStepMobs(activeStep) == nil then
                    self._remFiredKey = akey
                    self:CompleteStep(activeStep)
                    return
                end
            end
        end

        local watchStep = activeStep
        if remStep or self._awaitUse then
            local nj = NextGateIdx(steps, self.active)
            local nxt = nj and steps[nj]
            watchStep = (nxt and nxt.type == "kills" and nxt.enabled ~= false)
                and nxt or nil
        end

        local reqs = watchStep and self:GetStepMobs(watchStep) or nil
        local want = (settings ~= nil) and settings.enabled
                 and raidName ~= nil
                 and watchStep ~= nil
                 and watchStep.type == "kills"
                 and reqs ~= nil

        if want then
            local set = {}
            for _, r in ipairs(reqs) do
                if r.mob and r.mob ~= "" then set[string.lower(r.mob)] = r.mob end
            end
            self.watchMobs = next(set) and set or nil
            if not self.watchMobs then want = false end
        else
            self.watchMobs = nil
        end

        -- pre-credit the immediate next kill step: its mobs are watched
        -- alongside the current step's so a kill during the current step
        -- can already count toward the one after it (_nextKillSet).
        if settings and settings.enabled and raidName and steps then
            local nk
            for i = (self.active or 0) + 1, #steps do
                local s = steps[i]
                -- a boss step is a wall here too: trash on the far side
                -- of a boss you have not killed is never the next pack.
                if s and s.enabled ~= false and s.type == "encounter" then
                    break
                end
                if s and s.enabled ~= false and s.type == "kills" and s ~= watchStep then
                    nk = s
                    break
                end
            end
            local nreqs = nk and self:GetStepMobs(nk)
            self._nextKillSet = nil
            if nreqs then
                local set = self.watchMobs or {}
                local nset = {}
                for _, r in ipairs(nreqs) do
                    if r.mob and r.mob ~= "" then
                        local k = string.lower(r.mob)
                        if not set[k] then set[k] = r.mob end
                        nset[CanonMob(r.mob)] = r.mob
                    end
                end
                if next(set) then
                    self.watchMobs = set
                    self._nextKillSet = nset
                    self._nextKillStep = nk
                    want = true
                end
            end

            -- far steps (beyond the immediate next one) are also tallied
            -- while watched; if all their mobs die before the route gets
            -- there, CatchUpTo jumps active forward - steps can complete
            -- out of order when trash dies ahead of the route's position.
            --
            -- LIMITS. Far-credit used to look at EVERY remaining step, so a
            -- stray pull could complete a small step half the raid away:
            -- two Patchwork Golems dragged into step 3's pack fully
            -- satisfied step 30 ("2x Patchwork Golem") and the route
            -- jumped 3 -> 31. Three rules now keep it to what it is for -
            -- catching up when you pulled a pack or two ahead:
            --   * only the next FAR_KILL_STEPS kill steps past the next
            --     one are considered;
            --   * a boss step is a wall - you cannot be past a boss you
            --     have not killed, so nothing beyond one is considered;
            --   * a far step is only eligible if every mob it needs is
            --     needed by NO other kill step in the route. With the same
            --     mob in several places there is no way to know which
            --     step a stray kill belongs to, so it never far-credits.
            self._farSteps = nil
            if steps then
                local FAR_KILL_STEPS = 2
                local nameSteps = {}
                for j = 1, #steps do
                    local sj = steps[j]
                    if sj and sj.enabled ~= false and sj.type == "kills" then
                        local rj = self:GetStepMobs(sj)
                        if rj then
                            local seen = {}
                            for _, r in ipairs(rj) do
                                if r.mob and r.mob ~= "" then
                                    local k = CanonMob(r.mob)
                                    if not seen[k] then
                                        seen[k] = true
                                        nameSteps[k] = (nameSteps[k] or 0) + 1
                                    end
                                end
                            end
                        end
                    end
                end

                -- A mob named by more than one kill step is AMBIGUOUS: a
                -- kill of it before its step is reached could belong to
                -- any of them. Such kills are never pre-credited or
                -- carried (OnHostileDeath / AdvanceTail read this), so a
                -- step like "3x Deathknight Captain" followed by "4x
                -- Deathknight Captain" is never skipped by kills taken
                -- during the step before it - it starts at 0 when reached.
                -- Unique mobs keep pre-crediting, which is the catch-up.
                self._sharedMobs = nil
                for k, n in pairs(nameSteps) do
                    if n > 1 then
                        self._sharedMobs = self._sharedMobs or {}
                        self._sharedMobs[k] = true
                    end
                end

                local far, set = {}, self.watchMobs
                local budget = FAR_KILL_STEPS
                local lastIdx = #steps
                for i = (self.active or 0) + 1, lastIdx do
                    local s = steps[i]
                    if s and s.enabled ~= false and s.type == "encounter" then
                        break
                    end
                    if budget <= 0 then break end
                    if s and s.enabled ~= false and s.type == "kills" and s ~= watchStep and s ~= nk then
                        budget = budget - 1
                        local rr2 = self:GetStepMobs(s)
                        if rr2 then
                            local byName = {}
                            local shared = false
                            for _, r in ipairs(rr2) do
                                if r.mob and r.mob ~= "" then
                                    local k = string.lower(r.mob)
                                    byName[k] = (byName[k] or 0) + (r.kills or 1)
                                    if (nameSteps[CanonMob(r.mob)] or 0) > 1 then shared = true end
                                end
                            end
                            if shared then
                                if RC:IsDebugEnabled("route") and RC.db and RC.db.debugMode then
                                    RC:DebugPrint("Route: step " .. i .. " not far-creditable"
                                        .. " (a mob it needs is in another step too)", "route", 0)
                                end
                                byName = {}
                            else
                                for k in pairs(byName) do
                                    set = set or {}
                                    if not set[k] then
                                        for _, r in ipairs(rr2) do
                                            if r.mob and string.lower(r.mob) == k then
                                                set[k] = r.mob
                                                break
                                            end
                                        end
                                    end
                                end
                            end
                            if next(byName) then
                                local wings
                                local widx = self:GetMobWingIndex()
                                if widx then
                                    for k2 in pairs(byName) do
                                        local ws = widx[k2]
                                        if ws then
                                            wings = wings or {}
                                            for w in pairs(ws) do wings[w] = true end
                                        end
                                    end
                                end
                                far[#far + 1] = { idx = i, need = byName, wings = wings }
                            end
                        end
                    end
                end
                if #far > 0 and set and next(set) then
                    self.watchMobs = set
                    self._farSteps = far
                    self._farCounts = self._farCounts or {}
                    want = true
                end
            end
        end

        local wantArm = want and true or false

        -- route's sole registration with RC.KillWatch (the single CLEU
        -- death reader): watchMobs maps lowercased mob name -> the
        -- configured display name, which is what the callback receives.
        if wantArm ~= self.armed then
            if wantArm then
                RC:KillWatchRegister("route", self.watchMobs, function(cfgName)
                    RR:OnHostileDeath(cfgName)
                end)
            else
                RC:KillWatchUnregister("route")
            end
            self.armed = wantArm
            RC:DebugPrint("Route: death watch " .. (wantArm and "ON" or "OFF"), "route")
        elseif wantArm then
            RC:KillWatchRegister("route", self.watchMobs, function(cfgName)
                RR:OnHostileDeath(cfgName)
            end)
        end

        if adoptedRealRaid and settings and settings.enabled
           and steps and #steps > 0 then
            local msg = "Route active: " .. raidName .. " - " .. #steps
                .. " step" .. (#steps == 1 and "" or "s")
            if restored then
                msg = msg .. " (resumed at step " .. self.active .. ")"
            end
            RC:Print(msg)
        end

        self:RefreshTracker()

    end

    function RR:StartTest(raidName)
        if not raidName then return end
        if RC.GetEffectiveRaidName and RC:GetEffectiveRaidName() then return end
        self.testRaid = raidName
        self:UpdateArming()
        RC:DebugPrint("Route: TEST tracking started for " .. raidName, "route")
        self:RefreshUI()
    end

    function RR:StopTest()
        self.testRaid = nil
        self:UpdateArming()
        RC:DebugPrint("Route: TEST tracking stopped", "route")
        self:RefreshUI()
    end

    -- after a step completes, its just-watched mob names are guarded for a
    -- rolling 25s window so a death event that arrives late (already
    -- counted) can't also get credited to a still-watched far/next step.
    function RR:ArmSpillGuard()
        local ks = self.watchMobs
        if not ks or not next(ks) then return end
        local names = {}
        for k in pairs(ks) do names[k] = true end
        self._spillGuard = { names = names, untilT = GetTime() + 25 }
        if RC:IsDebugEnabled("route") then
            local n = 0
            for _ in pairs(names) do n = n + 1 end
            RC:DebugPrint("Route: spill-guard armed (" .. n .. " name(s), rolling 25s)", "route")
        end
    end

    local function NormWing(n)
        if not n then return "" end
        return n:lower():gsub("^the%s+", "")
    end

    function RR:GetMobWingIndex()
        if self._wingIdxRaid == self.raidName and self._wingIdx ~= nil then
            return self._wingIdx
        end
        self._wingIdxRaid = self.raidName
        self._wingIdx = false
        local rd = self.raidName and RC.raidData and RC.raidData[self.raidName]
        local ts = rd and rd.trashSections
        if ts then
            local idx = {}
            for section, mobs in pairs(ts) do
                if type(mobs) == "table" then
                    for _, m in ipairs(mobs) do
                        if type(m) == "string" then
                            local k = string.lower(m)
                            idx[k] = idx[k] or {}
                            idx[k][section] = true
                        end
                    end
                end
            end
            if next(idx) then self._wingIdx = idx end
        end
        return self._wingIdx
    end

    function RR:CurrentSection()
        local rd = self.raidName and RC.raidData and RC.raidData[self.raidName]
        local ts = rd and rd.trashSections
        if not ts then return nil end
        local sz = NormWing(GetSubZoneText() or "")
        if sz == "" then return nil end
        for section in pairs(ts) do
            local ns = NormWing(section)
            if sz == ns or sz:find(ns, 1, true) or ns:find(sz, 1, true) then
                return section
            end
        end
        return nil
    end

    function RR:WingAllows(fs)
        if not fs.wings then return true end
        local here = self:CurrentSection()
        if not here then return true end
        return fs.wings[here] == true
    end

    function RR:IsSpillGuarded(k)
        local sg = self._spillGuard
        if sg == nil or sg.names[k] == nil then return false end
        if GetTime() >= sg.untilT then return false end
        sg.untilT = GetTime() + 25
        return true
    end

    -- a mob name that appears in more than one trash wing/section can't be
    -- safely far-credited (which wing's step should get the kill is
    -- ambiguous), so this refuses far-credit unless the name is unique.
    function RR:NameFarCreditable(k)
        local widx = self:GetMobWingIndex()
        if not widx then return true end
        local ws = widx[k]
        if not ws then return true end
        local n = 0
        for _ in pairs(ws) do
            n = n + 1
            if n > 1 then return false end
        end
        return true
    end

    -- name here is the configured mob string from the matched KillWatch
    -- payload, not the live creature name off the death event - the exact
    -- string compares below ("r.mob == name") are config text vs config
    -- text, which is why they can stay case-sensitive.
    function RR:OnHostileDeath(name)
        if not name or name == "" then return end
        if not self.watchMobs or not self.watchMobs[string.lower(name)] then return end

        local steps = self:GetSteps()
        if not steps then return end
        local step = steps[self.active]
        -- compare the way KillWatch keys (case/whitespace folded) and
        -- credit under the matched step's OWN spelling, which is what
        -- EnsureBase/MobHave read; the payload may be another step's.
        local cn = CanonMob(name)

        if step and (self:IsReminderStep(step) or self._awaitUse) then
            -- the next ENABLED step: a disabled one right after a reminder
            -- step used to leave nothing to look ahead to, and it stalled.
            local nxtIdx = NextGateIdx(steps, self.active)
            local nxt = nxtIdx and steps[nxtIdx]
            local nreqs = nxt and nxt.enabled ~= false and self:GetStepMobs(nxt)
            local matched = false
            if nreqs then
                for _, r in ipairs(nreqs) do
                    if r.mob and CanonMob(r.mob) == cn then matched = r.mob; break end
                end
            end
            if matched then
            self:EnsureBase(nxt)
            self.counts[matched] = (self.counts[matched] or 0) + 1
            self:MarkRuntimeDirty()
            local cur, total = self:GetStepProgress(nxt)
            if RC:IsDebugEnabled("route") then
                if RC.db and RC.db.debugMode then
                    RC:DebugPrint("Route: " .. name .. " -> " .. cur .. "/" .. total
                        .. " (lookahead past reminder step " .. self.active .. ")", "route", 0)
                end
            end
            if cur >= total then
                if self:IsReminderStep(step) and self._remStepFiredIdx ~= self.active then
                    self:FireStepEquips(step)
                    self._remFiredKey = (self._remFiredKey or "") .. "!"
                end
                self._awaitUse = nil
                self:ArmSpillGuard()
                self.active = nxtIdx
                self:SaveRuntime()
                self:CompleteStep(nxt)
            else
                self:RefreshTracker()
            end
            return
            end
        end

        -- a held step (_awaitUse) is already complete: its kills must not
        -- count again, or each extra one re-runs CompleteStep and re-fires
        -- its gear/reminders. They fall through to the next steps instead.
        local reqs = step and step.enabled ~= false and not self._awaitUse
            and self:GetStepMobs(step)
        local matched = false
        if reqs then
            for _, r in ipairs(reqs) do
                if r.mob and CanonMob(r.mob) == cn then matched = r.mob; break end
            end
        end

        local k = string.lower(name)
        local nkMob = self._nextKillSet and self._nextKillSet[cn]
        -- an ambiguous mob (named by several kill steps) is only ever
        -- credited to the step that is active; see UpdateArming
        if nkMob and self._sharedMobs and self._sharedMobs[cn] then nkMob = nil end
        if matched then
            self:EnsureBase(step)
            self.counts[matched] = (self.counts[matched] or 0) + 1
            self:MarkRuntimeDirty()
        elseif nkMob then
            if type(nkMob) ~= "string" then nkMob = name end
            self:EnsureBase(self._nextKillStep)
            self.counts[nkMob] = (self.counts[nkMob] or 0) + 1
            self:MarkRuntimeDirty()
            if RC:IsDebugEnabled("route") and RC.db and RC.db.debugMode then
                RC:DebugPrint("Route: " .. name .. " +1 (pre-credit, next step)", "route", 0)
            end
            self:UpdateUICount()
            return
        else
            if self._farSteps then
                for _, fs in ipairs(self._farSteps) do
                    if fs.need[k] and not self:IsSpillGuarded(k)
                       and self:WingAllows(fs)
                       and self:NameFarCreditable(k) then
                        local fc = self._farCounts[fs.idx]
                        if not fc then fc = {}; self._farCounts[fs.idx] = fc end
                        local now = GetTime()
                        if fc._t0 and (now - fc._t0) > 90 then
                            for kk in pairs(fc) do fc[kk] = nil end
                        end
                        fc._t0 = fc._t0 or now
                        fc[k] = (fc[k] or 0) + 1
                        local done = true
                        for nm, need in pairs(fs.need) do
                            if (fc[nm] or 0) < need then done = false; break end
                        end
                        if RC:IsDebugEnabled("route") and RC.db and RC.db.debugMode then
                            RC:DebugPrint("Route: " .. name .. " -> far step "
                                .. fs.idx .. " tally", "route", 0)
                        end
                        if done then
                            self:CatchUpTo(fs.idx)
                        end
                        break
                    end
                end
            end
            return
        end

        local cur, total = self:GetStepProgress(step)
        if RC:IsDebugEnabled("route") then
            if RC.db and RC.db.debugMode then
                RC:DebugPrint("Route: " .. name .. " -> " .. cur .. "/" .. total
                    .. " (step " .. self.active .. ")", "route", 0)
            end
        end

        if cur >= total then
            self:CompleteStep(step)
        else
            self:UpdateUICount()
        end
    end

    function RR:OnRouteEquipsLanded(expectIdx)
        if not self._awaitUse then return end
        if expectIdx and self.active ~= expectIdx then return end
        local ss = self:GetSteps()
        local step = ss and ss[self.active]
        if not step then return end
        if self:StepHasUseReminder(step) then return end
        local a = step.actions
        local sSet = (step.type == "encounter") and self:SharedBossSet(step)
            or (a and a.gearSet)
        local hadEquips = a and ((sSet and sSet ~= "")
            or (a.trinket1 and a.trinket1 ~= 0)
            or (a.trinket2 and a.trinket2 ~= 0)
            or (a.slots and next(a.slots))) or false
        if not hadEquips then return end
        RC:DebugPrint("Route: equips landed - releasing held step "
            .. self.active, "route")
        self:AdvanceReminderStep()
    end

    function RR:AdvanceReminderStep()
        local steps = self:GetSteps()
        local step = steps and steps[self.active]
        if not step then return end
        if not (self._awaitUse or self:IsReminderStep(step)) then return end
        RC:DebugPrint("Route: use-gated step " .. self.active .. " completed (item used)", "route")
        if self:IsReminderStep(step) and self._remStepFiredIdx ~= self.active then
            self:FireStepEquips(step)
            self._remFiredKey = (self._remFiredKey or "") .. "!"
        end
        self._awaitUse = nil
        self._suppressPayload = true
        self:CompleteStep(step)
        self._suppressPayload = nil
    end

    function RR:SimulateDeath(name)
        self:OnHostileDeath(name)
    end

    function RR:SimulateStep(single)
        local steps = self:GetSteps()
        local step = steps and steps[self.active]
        if not step then return end
        if self._awaitUse or self:IsReminderStep(step) then
            self:AdvanceReminderStep()
            return
        end
        if step.type == "kills" then
            if single then
                local _, _, unmet = self:GetStepProgress(step)
                if unmet and unmet.mob and unmet.mob ~= "" then
                    self:OnHostileDeath(unmet.mob)
                end
                return
            end
            local guard = 0
            while guard < 200 do
                guard = guard + 1
                local cur, total, unmet = self:GetStepProgress(step)
                if not unmet or cur >= total then break end
                self:OnHostileDeath(unmet.mob)
                local now = self:GetSteps()
                if not now or now[self.active] ~= step then break end
            end
        else
            if not step.boss or step.boss == "" then
                RC:Print(RCL["Sim: step "] .. self.active
                    .. RCL[" has no boss picked - skipping it."])
                self._suppressPayload = true
                self:CompleteStep(step)
                self._suppressPayload = nil
                return
            end
            if step.boss and step.boss ~= "" then
                local when = step.when or "end"
                if when == "end" then
                    self._simPulled = self._simPulled or {}
                    if not self._simPulled[self.active] then
                        self._simPulled[self.active] = true
                        self:HandleEncounter(step.boss, "start", true)
                        RC:Print(RCL["Sim: pulled "] .. step.boss
                            .. RCL[" - Sim again for the kill."])
                        return
                    end
                    self._simPulled[self.active] = nil
                end
                self:HandleEncounter(step.boss, when, true)
            end
        end
    end

    function RR:PurgeEphemeralReminders()
        local n = #self.activeReminders
        for i = n, 1, -1 do
            local rec = self.activeReminders[i]
            if rec and not rec.spellId then
                table.remove(self.activeReminders, i)
            end
        end
        if #self.activeReminders ~= n then
            self:RefreshTracker()
        end
    end

    local function EquipSummary(step)
        local a = step and step.actions
        if not a then return nil end
        local parts = {}
        local lblSet = (step.type == "encounter") and RR:SharedBossSet(step)
            or a.gearSet
        if lblSet and lblSet ~= "" then
            -- the set's icon rides in front of its name
            parts[#parts + 1] = (RC.GetGearSetIconText and (RC:GetGearSetIconText(lblSet, 12) .. " ") or "") .. lblSet
        end
        if (a.trinket1 and a.trinket1 ~= 0) or (a.trinket2 and a.trinket2 ~= 0) then
            parts[#parts + 1] = "trinkets"
        end
        if a.slots and next(a.slots) then
            local n = 0
            for _ in pairs(a.slots) do n = n + 1 end
            parts[#parts + 1] = n .. (n == 1 and " slot" or " slots")
        end
        if #parts == 0 then return nil end
        return table.concat(parts, " + ")
    end

    -- filler words dropped from a mob name for compact tracker display
    -- only; the full name is still what's matched against kill events.
    local SHORT_DROP = { of = true, the = true, a = true, an = true }
    local _shortCache = {}
    local function ShortMobName(name)
        if not name then return name end
        local hit = _shortCache[name]
        if hit then return hit end
        local kept = {}
        for w in name:gmatch("%S+") do
            if not SHORT_DROP[w:lower()] then kept[#kept + 1] = w end
        end
        local out
        if name:lower():find(" the ", 1, true) then
            out = kept[1] or name
        else
            out = (#kept > 1) and kept[#kept] or (kept[1] or name)
        end
        _shortCache[name] = out
        return out
    end

    -- short label for the transient "transition hold" flash shown right
    -- after a step completes, before the tracker settles on the next step.
    local function GlanceLabel(self, step)
        if step and step.desc and step.desc ~= "" then return step.desc end
        local reqs = self:GetStepMobs(step)
        if reqs and #reqs > 1 then
            local total = 0
            for _, r in ipairs(reqs) do total = total + (r.kills or 1) end
            return total .. " mobs"
        end
        if reqs and #reqs == 1 then
            return (reqs[1].kills or 1) .. "x "
                .. ShortMobName(reqs[1].mob or "?")
        end
        return self:StepLabel(step)
    end

    function RR:SetTransitionHold(step)
        local equip = EquipSummary(step)
        -- the equip itself is already queued/deferred inside FireStepEquips;
        -- this only holds off the "Equipping: ..." tracker flash until
        -- combat ends, so it doesn't lie about gear that hasn't landed yet.
        if equip and InCombatLockdown() then
            self._pendingEquipFlash = step
            equip = nil
        end
        local prev = self._transition
        if not equip and prev and prev.equip
           and GetTime() < (prev.expires or 0) then
            equip = prev.equip
        end
        local dur = equip and 1.0 or 2.0
        if RC._ttsTrace and self._transition
           and GetTime() < (self._transition.expires or 0) then
            RC:Print(RCL["|cFFFF66FFTRANS overwritten|r (was equip="]
                .. tostring(self._transition.equip) .. ")")
        end
        self._transition = {
            label   = GlanceLabel(self, step),
            step    = step,
            equip   = equip,
            expires = GetTime() + dur,
        }
        if RC._ttsTrace then
            RC:Print(RCL["|cFFFF66FFTRANS set|r equip="] .. tostring(equip)
                .. RCL[" dur="] .. dur .. RCL[" for '"] .. self._transition.label .. "'")
        end
        self:RefreshTracker()
        C_Timer.After(dur + 0.1, function()
            if self._transition and GetTime() >= self._transition.expires then
                self._transition = nil
                self:PurgeEphemeralReminders()
                self:RefreshTracker()
            end
        end)
    end

    function RR:HandleRouteFinish(hadEquips, firedInCombat)
        self.finished = true
        local msg = "Route complete" .. (self.raidName and (": " .. self.raidName) or "")
        local function Announce()
            RC:Print(msg)
        end
        if hadEquips and firedInCombat then
            self._finishAnnounce = Announce
        elseif hadEquips then
            C_Timer.After(1.2, Announce)
        else
            C_Timer.After(0.1, Announce)
        end
    end

    -- the tail every "this step is done, move on" path shares: drop the
    -- use-hold, flash the transition, re-arm the spill guard, move active
    -- to nextActive, reset the tallies and re-normalize, then announce the
    -- finish if the route ran off the end. Callers differ only in where
    -- active lands and in what they report to HandleRouteFinish.
    --   SetTransitionHold never reads _awaitUse and ArmSpillGuard never
    --   reads active, so the slightly different statement orders the call
    --   sites used before this was extracted are all equivalent to this one.
    -- guardFinished keeps HandleEncounter's extra check against announcing
    -- a finish for a route that is already finished.
    local function AdvanceTail(self, step, nextActive, hadEquips,
                               firedInCombat, wantTracker, guardFinished)
        self._awaitUse = nil
        self:SetTransitionHold(step)
        self:ArmSpillGuard()
        local oldCounts, oldBase = self.counts, self._stepBase
        self.active = nextActive
        ResetCounts()
        self:NormalizeActive()

        -- CARRY. Kills already credited to the step we land on (next-step
        -- pre-credit, or the lookahead past a held/reminder step) used to
        -- be wiped by ResetCounts above, so pulling the next pack along
        -- with this one left the route waiting on mobs already dead.
        -- Only a completed KILL step carries (never across a boss), only
        -- onto a step that already has a snapshot, and never for a mob the
        -- completed step also needs - those kills were this step's, not
        -- the next one's.
        local landing
        if step and step.type == "kills" and oldBase then
            local ss = self:GetSteps()
            local land = ss and ss[self.active]
            local b = land and land ~= step and oldBase[land]
            local lreqs = b and self:GetStepMobs(land)
            if lreqs then
                local skip = {}
                local done = self:GetStepMobs(step)
                if done then
                    for _, r in ipairs(done) do
                        if r.mob then skip[CanonMob(r.mob)] = true end
                    end
                end
                local nb, any = {}, false
                local sharedM = self._sharedMobs
                for _, r in ipairs(lreqs) do
                    local m = r.mob
                    if m then
                        nb[m] = 0
                        if not skip[CanonMob(m)] and not (sharedM and sharedM[CanonMob(m)]) then
                            local have = (oldCounts[m] or 0) - (b[m] or 0)
                            if have > 0 then
                                self.counts[m] = have
                                any = true
                            end
                        end
                    end
                end
                if any then
                    self._stepBase[land] = nb
                    landing = land
                end
            end
        end

        if not (self:GetSteps() or {})[self.active]
           and not (guardFinished and self.finished) then
            self:HandleRouteFinish(hadEquips, firedInCombat)
        end
        self:UpdateArming()
        self:SaveRuntime()
        if wantTracker then self:RefreshTracker() end
        self:RefreshUI()

        -- the pack for the step we landed on is already dead: complete it
        -- now rather than wait for a kill that will never come. One step
        -- only - the snapshot for the step after it does not exist yet.
        if landing and not self._awaitUse then
            local ss2 = self:GetSteps()
            if ss2 and ss2[self.active] == landing then
                local cur, total = self:GetStepProgress(landing)
                if total > 0 and cur >= total then
                    RC:DebugPrint("Route: step " .. self.active
                        .. " already met by kills taken during the previous step", "route")
                    self:CompleteStep(landing)
                else
                    self:UpdateUICount()
                end
            end
        end
    end

    -- hadEquips for a step's payload: a shared gear set, either trinket or
    -- any single-slot item. Pure reads, safe to evaluate on any path.
    local function PayloadHadEquips(self, step)
        local a = step and step.actions
        if not a then return false end
        local sSet = (step.type == "encounter") and self:SharedBossSet(step)
            or a.gearSet
        return ((sSet and sSet ~= "")
            or (a.trinket1 and a.trinket1 ~= 0)
            or (a.trinket2 and a.trinket2 ~= 0)
            or (a.slots and next(a.slots))) and true or false
    end

    local function StepConfigGear(self, step)
        if not step or step.type ~= "encounter" or not step.boss
           or step.boss == "" then return nil, nil end
        local prof = RC.GetActiveRaidProfile
            and RC:GetActiveRaidProfile(self.raidName)
        local b = prof and prof.bosses and prof.bosses[step.boss]
        if not b then return nil, nil end
        local fe = b.forceEquip
        local out, seen = {}, {}
        local map = fe and ((step.when == "start") and fe.onTarget or fe.onDeath)
        if type(map) == "table" then
            for slot, id in pairs(map) do
                if id and id ~= 0 then
                    out[#out + 1] = { slot = slot, id = id }
                    seen[slot] = true
                end
            end
        end
        -- 13/14 are the trinket inventory slot IDs; deathSlot1/2 are the
        -- boss config's legacy trinket-only death-swap fields, folded in
        -- here unless the generic onDeath slot map already covers them.
        if fe and step.when ~= "start" then
            if fe.deathSlot1 and fe.deathSlot1 ~= 0 and not seen[13] then
                out[#out + 1] = { slot = 13, id = fe.deathSlot1 }
            end
            if fe.deathSlot2 and fe.deathSlot2 ~= 0 and not seen[14] then
                out[#out + 1] = { slot = 14, id = fe.deathSlot2 }
            end
        end
        table.sort(out, function(x, y) return x.slot < y.slot end)
        local ench = nil
        local emap = fe and ((step.when == "start") and fe.onTargetEnchant
            or fe.onDeathEnchant)
        if type(emap) == "table" then
            for slot, e in pairs(emap) do
                if e and e ~= 0 then
                    ench = ench or {}
                    ench[slot] = e
                end
            end
        end
        local setName = self.SharedBossSet and self:SharedBossSet(step) or nil
        return setName, out, ench
    end

    -- jumps active straight to idx: the out-of-order completion path when
    -- a far step's mobs all died before the route caught up to them.
    function RR:CatchUpTo(idx)
        local steps = self:GetSteps()
        local step = steps and steps[idx]
        if not step then return end
        -- Belt and braces for the limits in UpdateArming: a catch-up may
        -- never move backwards or carry the route across a boss step,
        -- whatever a tally left over from before a route edit says.
        local from = self.active or 0
        if idx <= from then return end
        for j = from + 1, idx - 1 do
            local sj = steps[j]
            if sj and sj.enabled ~= false and sj.type == "encounter" then
                RC:DebugPrint("Route: catch-up to step " .. idx .. " refused - boss step "
                    .. j .. " is in the way", "route")
                self._farCounts = {}
                return
            end
        end
        RC:Print(RCL["Route: catching up - kills completed step "] .. idx
            .. RCL[" while the route was at step "] .. tostring(self.active) .. ".")
        self.active = idx
        self:EnsureBase(step)
        local reqs = self:GetStepMobs(step)
        local base = self._stepBase and self._stepBase[step]
        if reqs then
            for _, r in ipairs(reqs) do
                if r.mob then
                    local b = (base and base[r.mob]) or 0
                    local target = b + (r.kills or 1)
                    if (self.counts[r.mob] or 0) < target then
                        self.counts[r.mob] = target
                    end
                end
            end
        end
        self._farCounts = {}
        self._stepBase = {}
        self:SaveRuntime()
        self:CompleteStep(step)
    end

    -- the common step-completion path: fires the step's payload (unless
    -- _suppressPayload skips it, used for sim/back-navigation bookkeeping),
    -- then advances active and re-normalizes. Equip/trinket/slot actions
    -- always go through FireStepEquips, never applied directly here.
    function RR:CompleteStep(step)
        self._speechGen = (self._speechGen or 0) + 1
        -- the route's own lines only: a consumable or reminder line that
        -- was waiting is not this step's to cancel
        if RC.StopTTS then RC:StopTTS("route") end
        RC:DebugPrint("Route: step " .. self.active .. " complete - " .. self:StepLabel(step), "route")
        local hadEquips = (not self._suppressPayload)
            and PayloadHadEquips(self, step)
        local firedInCombat = InCombatLockdown()
        -- a step really completed this session: the restored position is
        -- confirmed as this run (see HandleEncounter). Suppressed-payload
        -- completions are bookkeeping (held-step release, edit skip).
        if not self._suppressPayload then self._restoredRun = nil end
        self:ClearReminders()
        if not self._suppressPayload then
            self:FireStepEquips(step)
            self:FireStepReminders(step)
        end
        local ss = self:GetSteps()
        if not self._suppressPayload
           and self:StepHoldsAfterFire(step, ss and ss[self.active + 1] ~= nil) then
            self._awaitUse = true
            if not InCombatLockdown() then
                local idx = self.active
                C_Timer.After(0.15, function()
                    RR:OnRouteEquipsLanded(idx)
                end)
            end
            self:SaveRuntime()
            self:UpdateArming()
            self:RefreshTracker()
            self:RefreshUI()
            return
        end
        AdvanceTail(self, step, self.active + 1, hadEquips, firedInCombat,
                    false, false)
    end

    function RR:ManualAdvance()
        local settings = self:GetSettings()
        if not settings or not settings.enabled then return end
        if self.finished then return end
        local steps = self:GetSteps()
        if not steps or #steps == 0 then return end
        local step = steps[self.active]
        if not step then return end
        self._restoredRun = nil
        if self._awaitUse then
            AdvanceTail(self, step, self.active + 1, false,
                        InCombatLockdown(), true, false)
            return
        end
        self:CompleteStep(step)
    end

    function RR:ManualBack()
        local settings = self:GetSettings()
        if not settings or not settings.enabled then return end
        local steps = self:GetSteps()
        if not steps or #steps == 0 then return end
        local from = self.active or 1
        if self.finished then
            self.finished = nil
            from = #steps + 1
        end
        local i = from - 1
        while i >= 1 do
            local s = steps[i]
            if s and s.enabled ~= false
               and not (s.type == "encounter" and s.when == "wipe") then
                break
            end
            i = i - 1
        end
        if i < 1 then i = 1 end
        self._awaitUse = nil
        self._transition = nil
        self._speechGen = (self._speechGen or 0) + 1
        if RC.StopTTS then RC:StopTTS("route") end
        self.active = i
        self._restoredRun = nil
        ResetCounts()
        self:ClearReminders()
        self:NormalizeActive()
        self:UpdateArming(); self:SaveRuntime()
        self:RefreshTracker(); self:RefreshUI()
    end

    function RR:HandleEncounter(bossName, when, synthetic)
        local settings = self:GetSettings()
        if not settings or not settings.enabled then return end
        if not bossName then return end
        if not self.raidName then self:UpdateArming() end
        local steps = self:GetSteps()
        if not steps or #steps == 0 then return end

        -- every pull opens a new encounter; a checkpoint fires at most once
        -- per encounter, so a second end-of-fight event for the same fight
        -- (or a held boss step seeing its own event again) is ignored.
        -- A start while one is already open is the same pull reported
        -- twice, not a new encounter; end/wipe closes it (the serial does
        -- not move, so a repeat end/wipe still matches the fired key).
        if when == "start" then
            if not self._encOpen then self._encSerial = (self._encSerial or 0) + 1 end
            self._encOpen = true
        else
            self._encOpen = nil
        end

        -- boss name match is exact after NormName folds case and strips a
        -- leading "the " - no fuzzy/partial matching against boss names.
        local want = NormName(bossName)
        for i = 1, #steps do
            local step = steps[i]
            if step.type == "encounter"
               and step.enabled ~= false
               and (step.when or "end") == when
               and NormName(step.boss) == want then
                local cpKey = i .. "|" .. tostring(when) .. "|" .. want
                    .. "#" .. (self._encSerial or 0)
                if self._lastCheckpoint == cpKey then
                    RC:DebugPrint("Route: checkpoint '" .. self:StepLabel(step)
                        .. "' already fired for this encounter - ignored", "route")
                    return
                end
                -- a boss BEHIND a restored position fired: the saved
                -- progress was from an earlier run of this raid (the client
                -- gives no per-run id before the first kill), so treat this
                -- as a new run and carry on from this boss. Only while the
                -- restored position is unconfirmed - once the route has
                -- moved this session, an out-of-order boss never rewinds.
                if when ~= "wipe" and i < (self.active or 1) and self._restoredRun then
                    RC:Print(RCL["Route: "] .. (step.boss or "?")
                        .. RCL[" is behind the saved step - treating this as a new run."])
                    self._awaitUse = nil
                    self.finished = false
                    self._finishAnnounce = nil
                    self._remFiredKey = nil
                    self._remStepFiredIdx = nil
                    self._simPulled = nil
                    ResetCounts()
                    self.active = i
                end
                if when ~= "wipe" and i + 1 > (self.active or 1) then
                    self._restoredRun = nil
                end
                if when == "wipe" then
                    self._lastCheckpoint = cpKey
                    RC:DebugPrint("Route: wipe trigger '" .. self:StepLabel(step) .. "'", "route")
                    self:ClearReminders()
                    self._realEncounterFire = not synthetic or nil
                    self:FireStepActions(step)
                    self._realEncounterFire = nil
                    self:RefreshTracker()
                    self:RefreshUI()
                -- checkpoint already behind the active step (route was
                -- advanced past it some other way) - ignore, don't rewind.
                elseif i + 1 <= self.active then
                    RC:DebugPrint("Route: checkpoint '" .. self:StepLabel(step)
                        .. "' already passed (" .. (i + 1) .. " <= "
                        .. self.active .. ")", "route")
                    return
                else
                    self._lastCheckpoint = cpKey
                    RC:DebugPrint("Route: checkpoint '" .. self:StepLabel(step)
                        .. "' (jump " .. self.active .. " -> " .. (i + 1) .. ")", "route")
                    self._speechGen = (self._speechGen or 0) + 1
                    if RC.StopTTS then RC:StopTTS("route") end
                    self:ClearReminders()
                    self._realEncounterFire = not synthetic or nil
                    self:FireStepEquips(step)
                    self._realEncounterFire = nil
                    self._encFireOK = true
                    self:FireStepReminders(step)
                    self._encFireOK = nil
                    if self:StepHoldsAfterFire(step, steps[i + 1] ~= nil) then
                        self.active = i
                        self._awaitUse = true
                        self:ArmSpillGuard()
                        if not InCombatLockdown() then
                            local idx = i
                            C_Timer.After(0.15, function()
                                RR:OnRouteEquipsLanded(idx)
                            end)
                        end
                        ResetCounts()
                        self:NormalizeActive()
                        self:UpdateArming()
                        self:SaveRuntime()
                        self:RefreshTracker()
                        self:RefreshUI()
                        return
                    end
                    AdvanceTail(self, step, i + 1,
                                PayloadHadEquips(self, step),
                                InCombatLockdown(), false, true)
                end
                return
            end
        end
    end

    function RR:OnEncounterStart(bossName, raidName)
        self:HandleEncounter(bossName, "start")
    end

    function RR:OnEncounterEnd(bossName, success)
        if success == 1 then
            self:HandleEncounter(bossName, "end")
        elseif success == 0 then
            self:HandleEncounter(bossName, "wipe")
        end
    end

    function RR:FireStepActions(step)
        self:FireStepEquips(step)
        self:FireStepReminders(step)
    end

    function RR:SharedBossSet(step)
        if not step or step.type ~= "encounter" then return nil end
        local w = step.when or "end"
        if w ~= "start" and w ~= "end" then return nil end
        if not step.boss or step.boss == "" then return nil end
        local prof = RC.GetActiveRaidProfile and RC:GetActiveRaidProfile(self.raidName)
        local b = prof and prof.bosses and prof.bosses[step.boss]
        local gs = b and b.abilities and b.abilities.gearswap
        if not gs then return nil end
        local v = (w == "start") and gs.gearSet or gs.postCombatSet
        if v and v ~= "" then return v end
    end

    -- CHOKEPOINT: the only place in the route that actually applies gear -
    -- full sets, trinkets and single slots. Every completion path
    -- (CompleteStep, CatchUpTo, HandleEncounter, AdvanceReminderStep, the
    -- activation auto-fire in UpdateArming) calls in here rather than
    -- equipping anything itself.
    function RR:FireStepEquips(step)
        local a = (step and step.actions) or {}
        if not step then return end
        local label = RCL["Route: "] .. self:StepLabel(step)
        if RC.NoteSwapContext then RC:NoteSwapContext(label) end

        local gearSet
        if step.type == "encounter" then
            -- a real boss start/death event already applies its config'd
            -- gear via a separate hook (see _realEncounterFire callers /
            -- RC:OnBossUnitDied below); skip here to avoid a double-equip.
            -- Synthetic fires (sim, manual jump) don't have that hook, so
            -- they pull the set from config directly via SharedBossSet.
            if not self._realEncounterFire then
                gearSet = self:SharedBossSet(step)
            end
        else
            gearSet = a.gearSet
        end
        local hasSet  = (gearSet ~= nil) and (gearSet ~= "")

        -- FULL SET. EquipGearSet detects combat lockdown itself and defers
        -- via QueueGearSwap, so the set lands the moment combat drops.
        if hasSet and RC.EquipGearSet then
            RC:EquipGearSet(gearSet)
        end

        -- route trinket/slot actions use -1 to mean UNEQUIP that slot;
        -- gear sets elsewhere in the addon use 0 for the same meaning, so
        -- these two conventions are not interchangeable across systems.
        local t1 = a.trinket1
        local t2 = a.trinket2
        if (t1 and t1 ~= 0) or (t2 and t2 ~= 0) then
            local existingT = RC.pendingDeathTrinketSwap
            if existingT and existingT.src == "boss" then
                RC:DebugPrint(label .. ": trinket swap skipped - boss after-death swap already queued", "route")
            else
            RC.pendingDeathTrinketSwap = {
                slot1 = t1, slot2 = t2,
                boss = label,
                src = "route",
                isRoute = true,
                hasFullSet = hasSet and true or false,
            }
            if RC.SetTrinketIntent then
                if t1 and t1 ~= 0 then RC:SetTrinketIntent(13, "route") end
                if t2 and t2 ~= 0 then RC:SetTrinketIntent(14, "route") end
            end
            if InCombatLockdown() then
                RC:DebugPrint(label .. ": trinket swap queued - fires when combat ends", "route")
                if RC.QueueGearSwap and RC.FindTrinketInBags then
                    local function previewTrinket(itemId, invSlot)
                        if not itemId or itemId == 0 then return end
                        local loc = RC:FindTrinketInBags(itemId)
                        if loc then
                            RC:QueueGearSwap({ display = true, inventorySlot = invSlot, bag = loc.bag, slot = loc.slot })
                        end
                    end
                    previewTrinket(t1, 13)
                    previewTrinket(t2, 14)
                end
            else
                if RC.RunPendingDeathTrinketSwap then
                    RC:RunPendingDeathTrinketSwap()
                end
            end
            end
        end

        if a.slots and next(a.slots) then
            local slotsCopy = {}
            for invSlot, itemId in pairs(a.slots) do
                if itemId and itemId ~= 0 then
                    slotsCopy[invSlot] = itemId
                end
            end
            if next(slotsCopy) then
                local existingS = RC.pendingDeathSlotSwap
                if existingS and existingS.src == "boss" then
                    RC:DebugPrint(label .. ": slot swap skipped - boss after-death swap already queued", "route")
                    slotsCopy = nil
                end
            end
            if slotsCopy and next(slotsCopy) then
                RC.pendingDeathSlotSwap = {
                    slots = slotsCopy,
                    boss = label,
                    src = "route",
                    isRoute = true,
                    hasFullSet = hasSet and true or false,
                }
                if InCombatLockdown() then
                    RC:DebugPrint(label .. ": slot swap queued - fires when combat ends", "route")
                else
                    if RC.RunPendingDeathSlotSwap then
                        RC:RunPendingDeathSlotSwap()
                    end
                end
            end
        end

        if step.type == "encounter" and step.boss and step.boss ~= ""
           and not self._realEncounterFire then
            if step.when == "end" and RC.OnBossUnitDied then
                RC:OnBossUnitDied(nil, step.boss, self.raidName)
            end
            local _, cfgSlots, cfgEnch = StepConfigGear(self, step)
            if cfgSlots and #cfgSlots > 0 then
                local function OverridePass(final)
                    if InCombatLockdown() then return end
                    local GM = RC.GearManager
                    for _, o in ipairs(cfgSlots) do
                        local wantE = cfgEnch and cfgEnch[o.slot]
                        local worn = GetInventoryItemID("player", o.slot)
                        local ok = (worn == o.id)
                        if ok and wantE then
                            local lk = GetInventoryItemLink("player", o.slot)
                            local we = tonumber((lk and
                                lk:match("item:%d+:(%d*)")) or "") or 0
                            ok = (we == wantE)
                        end
                        if not ok then
                            local done = false
                            if wantE and GM and GM.FindBagCopy then
                                local b2, s2 = GM:FindBagCopy(o.id, wantE)
                                if b2 then
                                    GM:EquipBagItemToSlot(b2, s2, o.slot)
                                    done = true
                                end
                            end
                            if not done then
                                RC:FastEquipItem(o.id, o.slot)
                            end
                            RC:DebugPrint("Route: config override slot "
                                .. o.slot .. " -> item " .. tostring(o.id)
                                .. (final and " (final verify)" or ""),
                                "gear")
                        end
                    end
                end
                C_Timer.After(0.2, function() OverridePass(false) end)
                C_Timer.After(0.7, function() OverridePass(false) end)
                C_Timer.After(1.5, function() OverridePass(true) end)
            end
        end

    end

    local _potFam
    local function PotionFamily()
        if _potFam then return _potFam end
        _potFam = {}
        for iid in pairs(RC.potionItemIds or {}) do _potFam[iid] = true end
        local rc = RC.raidConsumables
        for _, key in ipairs({ "potions", "protectionPotions" }) do
            local c = rc and rc[key]
            if c and c.items then
                for iid, d in pairs(c.items) do
                    if type(iid) == "number"
                       and not (type(d) == "table" and (d.baseItemId or d.slot)) then
                        _potFam[iid] = true
                    end
                end
            end
        end
        return _potFam
    end

    -- 8959 = the built-in "ReadyCheck" sound ID, reused here as the
    -- reminder-ping alert.
    local function ReminderPing()
        local rr = RC.db and RC.db.raidRoute
        if not (rr and rr.reminderPing == true) then return end
        -- raidRoute.sounds.ping (the standard): a sound / channel / throttle
        -- of its own; unset, the ready-check ping as always
        local spec = type(rr.sounds) == "table" and rr.sounds.ping or nil
        if spec and spec.sound then
            RC.UI:PlaySoundSpec(spec, nil, "routePing")
            return
        end
        pcall(PlaySound, 8959, (spec and spec.channel) or "Master")
    end

    -- durations of 1.5s or less are the shared-cooldown/GCD flash, not a
    -- real item cooldown, so they're treated as "not on cooldown" below.
    local function ItemOnCooldown(itemId)
        if not itemId then return false end
        -- a potion: the first one of the family carried (they share one
        -- cooldown); anything else: the item itself
        local bag, slot
        if PotionFamily()[itemId] then
            for iid in pairs(PotionFamily()) do
                local b, s = RC.Bags:Find(iid)
                if b and (not bag or b < bag or (b == bag and s < slot)) then bag, slot = b, s end
            end
        else
            bag, slot = RC.Bags:Find(itemId)
        end
        if not bag then return false end
        local st, du = C_Container.GetContainerItemCooldown(bag, slot)
        if st and st > 0 and du and du > 1.5 then
            return true, math.floor(st + du - GetTime() + 0.5)
        end
        return false
    end

    -- older saved reminders stored the literal text "Use <itemId>" before
    -- item names could be resolved; this rewrites them to the real name
    -- once GetItemInfo has it cached.
    function RR:HealReminderText(r)
        if r and type(r.itemId) == "number" and type(r.text) == "string"
           and r.text:match("^Use%s+%d+$") then
            local nm = GetItemInfo(r.itemId)
            if nm then r.text = RCL["Use "] .. nm end
        end
        return r and r.text
    end

    function RR:FireStepReminders(step)
        local fireHadUsable = false
        if RC._ttsTrace and step then
            local idx = "?"
            local ss = self:GetSteps()
            if ss then
                for k = 1, #ss do if ss[k] == step then idx = k break end end
            end
            local who = (debugstack(2, 1, 0) or ""):match(":(%d+)") or "?"
            RC:Print(RCL["|cFF66CCFFRoute fire|r step "] .. idx .. " '"
                .. self:StepLabel(step) .. RCL["' (caller line "] .. who
                .. RCL[", active="] .. tostring(self.active)
                .. RCL[", awaitUse="] .. tostring(self._awaitUse ~= nil) .. ")")
        end
        local a = step and step.actions
        if not a then return end
        if a.reminders then
            local setIconRaw
            if a.gearSet and a.gearSet ~= "" and RC.GearManager
               and RC.GearManager.sets and RC.GearManager.sets[a.gearSet] then
                setIconRaw = RC.GearManager.sets[a.gearSet].icon
            end
            for _, r in ipairs(a.reminders) do
                self:HealReminderText(r)
                if r.text and r.text ~= "" then
                    local ic = r.icon
                    if (not r.itemId) and ic and setIconRaw and ic == setIconRaw then
                        ic = "Interface\\Icons\\INV_Misc_Note_01"
                    end
                    local skipCD, cdLeft = ItemOnCooldown(r.itemId)
                    if skipCD then
                        RC:DebugPrint("Route: skipped reminder '"
                            .. tostring(r.text) .. "' - item on cooldown ("
                            .. tostring(cdLeft) .. "s left)", "route")
                    else
                        if r.itemId and r.itemId ~= 0 then
                            fireHadUsable = true
                        end
                    local dly = tonumber(r.delay) or 0
                    if dly > 0 then
                        local gen = self._payloadGen or 0
                        local rt, ric, rid, rtts = r.text, ic, r.itemId, r.tts
                        C_Timer.After(dly, function()
                            if (self._payloadGen or 0) ~= gen then
                                if RC._ttsTrace then
                                    RC:Print(RCL["|cFFFFAA00TTS route>|r reminder cancelled (newer payload): "] .. tostring(rt))
                                end
                                return
                            end
                            if ItemOnCooldown(rid) then
                                if RC._ttsTrace then
                                    RC:Print(RCL["|cFFFFAA00TTS route>|r reminder skipped (item on cooldown): "] .. tostring(rt))
                                end
                                return
                            end
                            self:ShowRouteReminder(rt, ric, rid)
                            if rtts ~= false and RC.SpeakTTS then
                                local spoken
                                if rt and rt ~= "" then
                                    local rest = rt:match("^[Uu]se%s+(.+)$")
                                    spoken = rest
                                        and ("Use " .. ((RC.GetTTSName and RC:GetTTSName(rest)) or rest))
                                        or rt
                                end
                                if (not spoken or spoken == "") and rid then
                                    local iname = GetItemInfo(rid)
                                    if iname then
                                        spoken = "Use " .. ((RC.GetTTSName and RC:GetTTSName(iname)) or iname)
                                    end
                                end
                                if spoken and spoken ~= "" then
                                    ReminderPing()
                                    RC:SpeakTTS(spoken, true, "route")
                                end
                            end
                        end)
                    else
                        self:ShowRouteReminder(r.text, ic, r.itemId)
                        if (r.tts ~= false) then
                            local spoken = r.text
                            if spoken and spoken ~= "" then
                                local rest = spoken:match("^[Uu]se%s+(.+)$")
                                if rest and RC.GetTTSName then
                                    spoken = "Use " .. (RC:GetTTSName(rest) or rest)
                                end
                            elseif r.itemId then
                                local iname = GetItemInfo(r.itemId)
                                if iname then
                                    spoken = "Use " .. ((RC.GetTTSName and RC:GetTTSName(iname)) or iname)
                                end
                            end
                            if spoken and spoken ~= "" then
                                local lateGen = self._payloadGen or 0
                                local lateSpoken = spoken
                                C_Timer.After(2.2, function()
                                    if (self._payloadGen or 0) ~= lateGen then
                                        if RC._ttsTrace then
                                            RC:Print(RCL["|cFFFFAA00TTS route>|r reminder speech cancelled (newer payload): "] .. lateSpoken)
                                        end
                                        return
                                    end
                                    ReminderPing()
                                    RC:SpeakTTS(lateSpoken, true, "route")
                                end)
                            end
                        end
                    end
                    end
                end
            end
            -- NOTE: each reminder in this list speaks for itself in the
            -- non-delayed branch above (and in its own timer when delayed).
            -- An aggregated "Use X, Y and Z" line used to be built here as
            -- well; it was left unreachable by an earlier refactor and is
            -- gone. Re-adding it means removing the per-reminder speech
            -- first, or every reminder gets spoken twice.
        else
            local txt = a.reminderText
            if txt and txt ~= "" then
                self:ShowRouteReminder(txt, a.reminderIcon, a.reminderItemId)
                local gateOpen2 = true
                if step.type == "encounter" and step.when ~= "wipe"
                   and not self._encFireOK then
                    gateOpen2 = false
                end
                do
                    local reqs = (step.mobs and #step.mobs > 0 and step.mobs)
                        or (step.mob and step.mob ~= ""
                            and { { mob = step.mob, kills = step.kills or 1 } })
                        or nil
                    if reqs then
                        local cur, total = 0, 0
                        for _, r in ipairs(reqs) do
                            local need = r.kills or 1
                            local have = RR:MobHave(step, r.mob)
                            if have > need then have = need end
                            cur, total = cur + have, total + need
                        end
                        if total > 0 and cur < total then gateOpen2 = false end
                    end
                end
                if gateOpen2 and (a.tts ~= false)
                   and RC.db and RC.db.ttsEnabled and RC.SpeakTTS then
                    local spoken = txt
                    local rest = spoken:match("^[Uu]se%s+(.+)$")
                    if rest and RC.GetTTSName then
                        spoken = "Use " .. RC:GetTTSName(rest)
                    end
                    local g = self._speechGen
                    C_Timer.After(0.1, function()
                        if RR._speechGen ~= g then return end
                        if RC.SpeakTTS then RC:SpeakTTS(spoken, true, "route") end
                    end)
                end
            end
        end
        self._useHoldGen = self._payloadGen or 0
        self._useHoldActive = fireHadUsable
        self:StartTrinketReadyWatch()
    end

    function RR:StartTrinketReadyWatch()
        C_Timer.After(3, function()
            local watch = {}
            for slot = 1, 19 do
                local id = GetInventoryItemID("player", slot)
                if id and GetItemSpell and GetItemSpell(id) then
                    local st, du = Readycheck.PlainCD(GetInventoryItemCooldown("player", slot))
                    if st and st > 0 and du and du > 1.5 then
                        watch[slot] = id
                    end
                end
            end
            if not next(watch) then return end
            if self._trinketReadyTicker then
                self._trinketReadyTicker:Cancel()
                self._trinketReadyTicker = nil
            end
            local _mk = (RC.Profiler and RC.Profiler.TrackTicker)
                and function(n, iv, fn) return RC.Profiler:TrackTicker(n, iv, fn) end
                or  function(n, iv, fn) return C_Timer.NewTicker(iv, fn) end
            self._trinketReadyTicker = _mk(
                "routeTrinketReady", 1.0, function()
                    for slot, id in pairs(watch) do
                        if GetInventoryItemID("player", slot) ~= id then
                            watch[slot] = nil
                        else
                            local st2, du2 = Readycheck.PlainCD(GetInventoryItemCooldown("player", slot))
                            local left = st2 and du2 and (st2 + du2 - GetTime()) or 0
                            if not st2 or st2 == 0 or left <= 0 then
                                watch[slot] = nil
                                local st3 = RR:GetSettings()
                                local nm = GetItemInfo(id)
                                if nm and RC.SpeakTTS
                                   and (st3 == nil or st3.trinketReadyTTS ~= false) then
                                    RC:SpeakTTS((slot == 13 or slot == 14)
                                        and RCL["Trinket ready"] or RCL["Item ready"], true)
                                end
                            end
                        end
                    end
                    if not next(watch) and RR._trinketReadyTicker then
                        RR._trinketReadyTicker:Cancel()
                        RR._trinketReadyTicker = nil
                    end
                end)
        end)
    end

_rrs.ShortMobName   = ShortMobName
_rrs.StepConfigGear = StepConfigGear
_rrs.PotionFamily   = PotionFamily
_rrs.eventFrame     = eventFrame
