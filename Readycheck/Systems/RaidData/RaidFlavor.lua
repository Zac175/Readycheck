------------------------------------------------------------------------
-- Readycheck - Raid data per game version
-- Classic Era's raids live in RaidConfigs.lua / DB_Raids.lua /
-- DB_Checker.lua and are left exactly as they are. On another version
-- that version's list (RaidConfigsTBC.lua, RaidConfigsForever.lua)
-- replaces them once, at load: Core_Runtime calls RC:ApplyRaidFlavor()
-- right after the consumables, before the companions load. The tables
-- are refilled in place, so a file that kept a reference reads the new
-- list. Saved raid profiles are keyed by raid name, so another version's
-- profiles stay saved and simply are not listed.
--
-- Files that hold their own raid tables (menus, notes, sync keys) add the
-- version's raids through RC:OnRaidFlavor(fn) (Core_Boot), which only
-- runs off Classic Era.
------------------------------------------------------------------------
local RC = _G.Readycheck
if not RC then return end
RC._raidFlavors = RC._raidFlavors or {}

local pairs, ipairs, type = pairs, ipairs, type

-- Classic Era's configured raids, in menu order (the same names, ids and
-- icons the pages already use).
RC.RAID_LIST_ERA = {
    { name = "Molten Core", code = "mc", abbr = "MC", label = "Molten Core", instanceId = 409,
      icon = "Interface\\Icons\\Spell_Fire_Incinerate" },
    { name = "Blackwing Lair", code = "bwl", abbr = "BWL", label = "Blackwing Lair", instanceId = 469,
      icon = "Interface\\Icons\\INV_Misc_Head_Dragon_Black" },
    { name = "Temple of Ahn'Qiraj", code = "aq40", abbr = "AQ40", label = "Temple of Ahn'Qiraj", instanceId = 531,
      icon = "Interface\\Icons\\INV_Misc_QirajiCrystal_05" },
    { name = "Naxxramas", code = "naxx", abbr = "Naxx", label = "Naxxramas", instanceId = 533,
      icon = "Interface\\Icons\\Achievement_Boss_KelThuzad_01" },
}

-- The configured raids of this version (Era's list until another
-- version's is applied).
function RC:FlavorRaids()
    return self._flavorRaids or self.RAID_LIST_ERA
end

function RC:RaidNames()
    local out = {}
    for i, r in ipairs(self:FlavorRaids()) do out[i] = r.name end
    return out
end

-- The raid row for a raid name, code or zone name, or nil.
function RC:RaidInfo(key)
    if not key then return nil end
    for _, r in ipairs(self:FlavorRaids()) do
        if r.name == key or r.code == key then return r end
        for _, z in ipairs(r.zones or {}) do
            if z == key then return r end
        end
    end
    return nil
end

function RC:RaidIcon(raidName)
    local r = self:RaidInfo(raidName)
    return r and r.icon or nil
end

function RC:RaidCode(raidName)
    local r = self:RaidInfo(raidName)
    return r and r.code or nil
end

function RC:RaidAbbr(raidName)
    local r = self:RaidInfo(raidName)
    return r and r.abbr or nil
end

-- True for a raid this version lists (every raid on Classic Era): pages
-- and messages leave another version's saved raids out.
function RC:RaidShownHere(raidName)
    if not self._raidFlavorApplied then return true end
    return self:RaidInfo(raidName) ~= nil
end

-- A preview sample of this version's raids (nil on Classic Era, where
-- each preview keeps its own).
function RC:RaidSample(key)
    local s = self._raidSample
    return s and s[key] or nil
end

------------------------------------------------------------------------
-- Boss lookups by name, NPC id and encounter id: { raid =, name = } for
-- the boss (the config key), or nil. Built when a version's list is
-- applied; Classic Era's data carries no ids, so these answer nil there.
------------------------------------------------------------------------
local byNpc, byEncounter, byName = {}, {}, {}

local function NormName(s)
    s = string.gsub(s, "^[Tt]he%s+", "")
    return string.lower((string.gsub(s, "[%s%-']+", "")))
end

function RC:RaidBossByNpcId(npcId)
    return npcId and byNpc[npcId] or nil
end

function RC:RaidBossByEncounterId(encounterId)
    return encounterId and byEncounter[encounterId] or nil
end

function RC:RaidBossByName(name)
    if type(name) ~= "string" then return nil end
    return byName[NormName(name)]
end

------------------------------------------------------------------------
-- Build and apply
------------------------------------------------------------------------
local function Refill(t, src)
    if type(t) ~= "table" then return end
    for k in pairs(t) do t[k] = nil end
    for k, v in pairs(src or {}) do t[k] = v end
end

local function Copy(list)
    local out = {}
    for i, v in ipairs(list or {}) do out[i] = v end
    return out
end

-- The configs, encounter table, raid data and trash packs from a
-- version's raid rows.
local function Build(src)
    local mob, phases, data, packs = {}, {}, {}, {}
    local Abilities = src.Abilities or function() return {} end
    local Trash = src.Trash or function() return { abilities = {} } end
    for _, r in ipairs(src.raids) do
        local cfg, order = {}, {}
        for _, b in ipairs(r.bosses or {}) do
            order[#order + 1] = b.name
            if b.kind == "none" then
                cfg[b.name] = { abilities = {} }
            else
                cfg[b.name] = { abilities = Abilities(b.kind, { tank = b.tank, fear = b.fear }) }
            end
            local aliases
            if b.members then
                aliases = {}
                for _, m in ipairs(b.members) do aliases[#aliases + 1] = m[1] end
            end
            local adds = Copy(b.adds)
            local busy = (#adds > 0) or (aliases ~= nil)
            phases[b.name] = {
                zone = r.name, adds = adds, aliases = aliases,
                aliasesAreEncounter = b.event or nil,
                combatContinuous = busy, trackBossDeath = busy,
                addPhasesBeforeBoss = b.addsFirst or nil,
                notes = b.notes,
            }
        end
        local sections = {}
        for _, s in ipairs(r.sections or {}) do sections[s[1]] = Copy(s[2]) end
        for name, o in pairs(r.configs or {}) do cfg[name] = Trash(o) end
        mob[r.name] = cfg
        data[r.name] = { bosses = order, trashSections = sections }
        local p = {}
        for i, pk in ipairs(r.packs or {}) do
            p[i] = { key = pk.key, label = RCL[pk.label], mobs = Copy(pk.mobs) }
        end
        packs[r.code] = p
    end
    return mob, phases, data, packs
end

local function IndexBosses(raids)
    for _, r in ipairs(raids) do
        for _, b in ipairs(r.bosses or {}) do
            local hit = { raid = r.name, name = b.name }
            byName[NormName(b.name)] = hit
            if b.encounterId then byEncounter[b.encounterId] = hit end
            for _, id in ipairs(b.npcIds or {}) do byNpc[id] = hit end
            for _, m in ipairs(b.members or {}) do
                byName[NormName(m[1])] = byName[NormName(m[1])] or hit
                if m[2] then byNpc[m[2]] = hit end
            end
        end
    end
end

-- The version's potions join the potion lists the raid pages and the
-- reminder read; they lead the potion picker.
local function AddPotions(src)
    local pd = RC.potionData
    if not (src.potions and pd and pd.potions) then return end
    for key, p in pairs(src.potions) do
        local icon = (GetItemIcon and GetItemIcon(p.itemId)) or "Interface\\Icons\\INV_Potion_41"
        pd.potions[key] = { name = p.name, itemId = p.itemId, spellId = p.spellId, icon = icon }
        if RC.potionItemIds then RC.potionItemIds[p.itemId] = key end
        if RC.potionSpellIds then RC.potionSpellIds[p.spellId] = key end
        if RC.availablePotions then RC.availablePotions[key] = p.name end
        if RC.potionIcons then RC.potionIcons[key] = icon end
        if RC.spellIdMap then RC.spellIdMap[p.spellId] = key end
        if RC.potionBuffIds then RC.potionBuffIds[p.spellId] = true end
        if RC.potionSpellToItem then RC.potionSpellToItem[p.spellId] = p.itemId end
    end
    local order = pd.displayOrder
    if type(order) == "table" and src.potionOrder then
        local rest = {}
        for _, k in ipairs(order) do rest[#rest + 1] = k end
        for i = #order, 1, -1 do order[i] = nil end
        for _, k in ipairs(src.potionOrder) do order[#order + 1] = k end
        for _, k in ipairs(rest) do
            if not src.potions[k] then order[#order + 1] = k end
        end
    end
    RC.defaultPotionType = src.defaultPotionType
end

-- The Raids group lists this version's raids (Boss & Trash Notes stays).
local function SetRaidMenu(raids)
    local menu = RC.MenuStructure
    if type(menu) ~= "table" then return end
    for _, group in ipairs(menu) do
        if group.id == "raids" and type(group.children) == "table" then
            local keep = {}
            for _, child in ipairs(group.children) do
                if not child.raidKey then keep[#keep + 1] = child end
            end
            local kids = {}
            for _, r in ipairs(raids) do
                kids[#kids + 1] = { id = r.code, name = RCL[r.label or r.name], icon = r.icon, raidKey = r.name }
            end
            for _, child in ipairs(keep) do kids[#kids + 1] = child end
            group.children = kids
            return
        end
    end
end

-- Returns true when this version's raids replaced Era's.
function RC:ApplyRaidFlavor()
    if self._raidFlavorApplied ~= nil then return self._raidFlavorApplied end
    local flavor = self.Flavor and self:Flavor() or "era"
    local src = flavor ~= "era" and self._raidFlavors[flavor]
    if not (src and type(src.raids) == "table" and #src.raids > 0) then
        self._raidFlavorApplied = false
        self._raidFlavorHooks = nil
        return false
    end
    self._raidFlavorApplied = true
    self._flavorRaids = src.raids

    local mob, phases, data, packs = Build(src)
    Refill(self.raidMobConfigs, mob)
    Refill(self.encounterAddPhases, phases)
    Refill(self.raidData, data)
    Refill(self.trashPacks, packs)
    self._encResolveCache = nil

    local zoneMap, ids, names = {}, {}, {}
    for i, r in ipairs(src.raids) do
        names[i] = r.name
        zoneMap[r.name] = r.name
        for _, z in ipairs(r.zones or {}) do zoneMap[z] = r.name end
        if r.instanceId then ids[r.name] = r.instanceId end
    end
    Refill(self.raidZoneMap, zoneMap)
    Refill(self.raidInstanceIDs, ids)
    if type(self.availableRaids) == "table" then
        for i = #self.availableRaids, 1, -1 do self.availableRaids[i] = nil end
        for i, n in ipairs(names) do self.availableRaids[i] = n end
    end
    IndexBosses(src.raids)
    AddPotions(src)
    self._raidSample = src.sample
    SetRaidMenu(src.raids)

    -- a version whose raids are now listed runs the raid features
    -- (Forever's are switched off only until its list is filled in)
    for _, f in ipairs(self.FEATURE_FLAVORS or {}) do
        if f.raidList and f.off and f.off[flavor] then
            local off = {}
            for k, v in pairs(f.off) do if k ~= flavor then off[k] = v end end
            f.off = next(off) and off or nil
        end
    end

    local hooks = self._raidFlavorHooks
    self._raidFlavorHooks = nil
    for _, fn in ipairs(hooks or {}) do
        local ok, err = pcall(fn, src.raids)
        if not ok then self:DebugPrint("Raid list hook failed: " .. tostring(err), "system") end
    end
    self:DebugPrint("Raids: " .. tostring(flavor) .. " list in use (" .. #src.raids .. " raids)", "system")
    return true
end
