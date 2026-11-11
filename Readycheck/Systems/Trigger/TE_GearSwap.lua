------------------------------------------------------------------------
-- Readycheck - Trigger Engine Gear Swaps
-- Owns RC.gearSwapState and the engage / post-combat gear lifecycle:
-- on-target set plus forceEquip overrides in, post-combat set out.
-- Loads first of the TE_* files (see .toc) and publishes the shared caches
-- on RC._tes that TE_Triggers and TE_Events alias at file scope.
-- Slots owned by an override (boss trinket lock, pending death or on-target
-- slot) are excluded from every set equip so a set can never clobber them.
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local GetItemCount = GetItemCount or (RCC and RCC.Compat and RCC.Compat.GetItemCount)
local GetSpellInfo = GetSpellInfo or (RCC and RCC.Compat and RCC.Compat.GetSpellInfo)
local UnitBuff = UnitBuff or (RCC and RCC.Compat and RCC.Compat.UnitBuff)
local UnitDebuff = UnitDebuff or (RCC and RCC.Compat and RCC.Compat.UnitDebuff)

local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local GetTime, UnitGUID, UnitHealth, UnitHealthMax = GetTime, UnitGUID, UnitHealth, UnitHealthMax
local UnitExists, UnitIsDead, UnitName = UnitExists, UnitIsDead, UnitName
local UnitAffectingCombat, InCombatLockdown = UnitAffectingCombat, InCombatLockdown
local GetSpellCooldown = GetSpellCooldown or (_G.Readycheck and _G.Readycheck.Compat and _G.Readycheck.Compat.GetSpellCooldown)
local C_Timer = C_Timer
local wipe = wipe
local string_format = string.format
local string_lower = string.lower
local string_find = string.find

local reuseAbilitiesToShow = {}
local reuseMacroCasts = {}
local reuseAbilitiesRemoved = {}
local RC = _G.Readycheck
if not RC then return end
RC._tes = RC._tes or {}
local _tes = RC._tes
local reuseVisibleIcons = {}

local debugTriggerEnabled = false
local debugDismissalEnabled = false
local debugGearEnabled = false

local abilityMetaCache = {}

-- Exported on RC._tes at the bottom of this file. IsAbilityReady results are
-- reused for 1s; TE_Events wipes the cache on every target change, combat
-- transition and trinket swap so a stale "ready" cannot outlive its cooldown.
local abilityReadyCache = {}
local ABILITY_READY_TTL = 1.0

    local function SyncDebugFlags()
        if RC.debugCategories then
            debugTriggerEnabled = RC.debugCategories.trigger and RC.debugCategories.trigger.enabled or false
            debugDismissalEnabled = RC.debugCategories.dismissal and RC.debugCategories.dismissal.enabled or false
            debugGearEnabled = RC.debugCategories.gear and RC.debugCategories.gear.enabled or false
        end
    end
    SyncDebugFlags()

    RC.SyncTriggerDebugFlags = SyncDebugFlags

    RC:DebugPrint("TriggerEngine initializing...", "system")

    if not RC.gearSwapTest then
        RC.gearSwapTest = {
            enabled = false,
            simulatedRaid = nil,
            simulatedBoss = nil
        }
    end

    -- _swapGen is bumped on every engage: retry timers capture it and bail once
    -- it moves. _postSwapActiveUntil is a 10s window during which engage-override
    -- retries stand down so they cannot fight the post-combat set.
    if not RC.gearSwapState then
        RC.gearSwapState = {
            lastBossTarget   = nil,
            lastEquippedSet  = nil,
            postCombatSet    = nil,
            engagedInCombat  = nil,
            engageHandledBoss = nil,
            engageHandledTime = nil,
            _swapGen         = 0,
            engagedBossGUID  = nil,
            _postSwapActiveSet   = nil,
            _postSwapActiveUntil = nil,
        }
    end

    -- Inventory slots owned by something other than a gear set: boss trinket
    -- locks, pending death swaps, pending on-target slots and the boss's onDeath
    -- map. Handed to EquipGearSetFast as excludeSlots.
    function RC:GetActiveOverrideSlots()
        local owned = {}
        local bts = RC.bossTrinketState
        if bts and bts.locked then
            if bts.locked[1] then owned[13] = true end
            if bts.locked[2] then owned[14] = true end
        end
        local pdt = RC.pendingDeathTrinketSwap
        if pdt then
            if pdt.slot1 then owned[13] = true end
            if pdt.slot2 then owned[14] = true end
        end
        local pds = RC.pendingDeathSlotSwap
        if pds and pds.slots then
            for s, id in pairs(pds.slots) do if id and id ~= 0 then owned[s] = true end end
        end
        if RC._pendingOnTargetSlots then
            for s, id in pairs(RC._pendingOnTargetSlots) do if id and id ~= 0 then owned[s] = true end end
        end
        local raidName = (bts and bts.appliedRaid)
                       or (self.GetEffectiveRaidName and self:GetEffectiveRaidName())
        local bossName = self.gearSwapState and self.gearSwapState.lastBossTarget
        if raidName and bossName then
            local resolved = (self.GetEncounterNameForBoss and self:GetEncounterNameForBoss(raidName, bossName)) or bossName
            local rp  = self.GetActiveRaidProfile and self:GetActiveRaidProfile(raidName)
            local cfg = rp and rp.bosses and rp.bosses[resolved]
            local fe  = cfg and cfg.forceEquip
            if fe then
                if (fe.deathSlot1 or (fe.onDeath and fe.onDeath[13])) then owned[13] = true end
                if (fe.deathSlot2 or (fe.onDeath and fe.onDeath[14])) then owned[14] = true end
                if fe.onDeath then
                    for s, id in pairs(fe.onDeath) do
                        if id and id ~= 0 then owned[s] = true end
                    end
                end
            end
        end
        return owned
    end

    function RC:GetEquippedIdEnchant(invSlot)
        local link = GetInventoryItemLink("player", invSlot)
        if not link then return nil, 0 end
        local id, ench = link:match("item:(%d+):?(%d*)")
        return tonumber(id), tonumber(ench) or 0
    end

    -- Same idea for the on-target direction. Also looks in rp.trash, since
    -- forceEquip.onTarget is legal on trash entries as well as boss entries.
    function RC:GetOnTargetOverrideSlots(bossName)
        local owned = {}
        local bts = RC.bossTrinketState
        if bts and bts.locked then
            if bts.locked[1] then owned[13] = true end
            if bts.locked[2] then owned[14] = true end
        end
        if RC._pendingOnTargetSlots then
            for s, id in pairs(RC._pendingOnTargetSlots) do
                if id and id ~= 0 then owned[s] = true end
            end
        end
        local raidName = (bts and bts.appliedRaid)
                       or (self.GetEffectiveRaidName and self:GetEffectiveRaidName())
        if raidName and bossName then
            local resolved = (self.GetEncounterNameForBoss and self:GetEncounterNameForBoss(raidName, bossName)) or bossName
            local rp  = self.GetActiveRaidProfile and self:GetActiveRaidProfile(raidName)
            local cfg = rp and ((rp.bosses and rp.bosses[resolved])
                             or (rp.trash and (rp.trash[resolved] or rp.trash[bossName])))
            local fe  = cfg and cfg.forceEquip
            if fe then
                if fe.slot1 or (fe.onTarget and fe.onTarget[13]) then owned[13] = true end
                if fe.slot2 or (fe.onTarget and fe.onTarget[14]) then owned[14] = true end
                if fe.onTarget then
                    for s, id in pairs(fe.onTarget) do
                        if id and id ~= 0 then owned[s] = true end
                    end
                end
            end
        end
        return owned
    end

    function RC:AttemptPostCombatGearSwap(targetSet, attempt)

        if not targetSet or targetSet == "" then
            self.gearSwapState.lastEquippedSet = nil
            self.gearSwapState.postCombatSet   = nil
            self.gearSwapState.lastBossTarget  = nil
            self.gearSwapState.engagedBossGUID = nil
            self.gearSwapState._postSwapActiveSet   = nil
            self.gearSwapState._postSwapActiveUntil = nil
            return
        end

        -- Still in combat: re-arm postCombatSet and let the PLAYER_REGEN_ENABLED
        -- handler in TE_Events call back in. Gear cannot move under lockdown.
        if UnitAffectingCombat("player") then
            if debugGearEnabled then self:DebugPrint("Still in combat - gear swap re-queued: " .. targetSet, "gear") end
            self.gearSwapState.postCombatSet = targetSet
            return
        end

        -- Any other set left in the queue would land after this one and undo it.
        if RC.gearSwapQueue then
            for qi = #RC.gearSwapQueue, 1, -1 do
                local entry = RC.gearSwapQueue[qi]
                if type(entry) == "string" and entry ~= targetSet then
                    table.remove(RC.gearSwapQueue, qi)
                    if debugGearEnabled then self:DebugPrint("Post-combat: flushed stale queued set '" .. entry .. "' so it can't clobber the post-combat set", "gear") end
                end
            end
        end
        -- 10s claim on the gear; TE_ForceEquip's engage verify reads this and
        -- aborts its retries rather than pulling slots back mid-swap.
        self.gearSwapState._postSwapActiveSet   = targetSet
        self.gearSwapState._postSwapActiveUntil = GetTime() + 10

        local myGen = self.gearSwapState._swapGen or 0

        attempt = attempt or 1
        local MAX_ATTEMPTS, RETRY_GAP = self:GearSwapRetryCfg()

        local function GetSetSlotMap(setName)
            local sd = (self.db and self.db.gearSets and self.db.gearSets[setName])
                    or (self.GearManager and self.GearManager.sets and self.GearManager.sets[setName])
            if not sd then return nil end
            local src = sd.equip or sd.items or sd.slots
            if not src then return nil end
            local map = {}
            for slot, link in pairs(src) do
                if type(slot) == "number" and link then
                    local itemId = nil
                    if type(link) == "string" then
                        itemId = tonumber(link:match("item:(%d+)")) or nil
                    elseif type(link) == "number" then
                        itemId = link
                    elseif type(link) == "table" and link.itemId then
                        itemId = link.itemId
                    end
                    if itemId then map[slot] = itemId end
                end
            end
            return map
        end

        -- Snapshot the override slots once: later attempts must use the same
        -- exclusion set or a retry could equip over a slot the first pass spared.
        if attempt == 1 then
            self.gearSwapState._postSwapOverrideSlots = self:GetActiveOverrideSlots()
        end
        local overrideSlots = self.gearSwapState._postSwapOverrideSlots or self:GetActiveOverrideSlots()

        -- A set slot saved as 0 means "unequip", so its wantId is 0 and an
        -- empty slot (which reads nil) is the match. Comparing nil to 0
        -- failed every set that strips the shirt, and the warning printed
        -- on a swap that had fully landed.
        local function Verify(setName)
            local map = GetSetSlotMap(setName)
            if not map then return true, nil end
            local mismatches = {}
            for slot, wantId in pairs(map) do
                if not overrideSlots[slot] then
                    local haveId = GetInventoryItemID and GetInventoryItemID("player", slot) or nil
                    if (haveId or 0) ~= wantId then
                        mismatches[#mismatches + 1] = slot
                    end
                end
            end
            return #mismatches == 0, mismatches
        end

        local success = self:EquipGearSetFast(targetSet, overrideSlots)
        if not success then
            if debugGearEnabled then self:DebugPrint("EquipGearSet returned false (attempt " .. attempt .. ") - will retry", "gear") end
            if attempt < MAX_ATTEMPTS then
                C_Timer.After(RETRY_GAP, function()
                    if RC.gearSwapState._swapGen ~= myGen then
                        if debugGearEnabled then RC:DebugPrint("Post-combat swap retry abandoned: new engage cycle started", "gear") end
                        return
                    end
                    if not UnitAffectingCombat("player") then
                        self:AttemptPostCombatGearSwap(targetSet, attempt + 1)
                    else
                        self.gearSwapState.postCombatSet = targetSet
                    end
                end)
            end
        end

        C_Timer.After(0.6, function()
            local ok, mismatches = Verify(targetSet)
            if ok then
                if debugGearEnabled then self:DebugPrint(string.format(RCL["Post-combat gear swap verified (attempt %d): %s"], attempt, targetSet), "gear") end
                self.gearSwapState.lastEquippedSet = nil
                self.gearSwapState.postCombatSet   = nil
                self.gearSwapState.lastBossTarget  = nil
                self.gearSwapState.engagedBossGUID = nil
                self.gearSwapState._postSwapActiveSet   = nil
                self.gearSwapState._postSwapActiveUntil = nil

                -- A locked trinket that no longer matches what is equipped was
                -- legitimately overwritten by the post-combat set, so drop the
                -- lock instead of letting it fight the next auto-swap.
                if RC.bossTrinketState and RC.bossTrinketState.locked then
                    local locked = RC.bossTrinketState.locked
                    local e13 = GetInventoryItemID and GetInventoryItemID("player", 13) or nil
                    local e14 = GetInventoryItemID and GetInventoryItemID("player", 14) or nil
                    if locked[1] and locked[1] ~= e13 then locked[1] = nil end
                    if locked[2] and locked[2] ~= e14 then locked[2] = nil end
                    if not locked[1] and not locked[2] then
                        RC.bossTrinketState.deathSwap = nil
                        RC.bossTrinketState.appliedBoss = nil
                        RC.bossTrinketState.appliedRaid = nil
                        if debugGearEnabled then self:DebugPrint("Post-combat: trinket lock fully cleared (post-combat set overwrote both slots)", "gear") end
                    end
                end
            elseif attempt < MAX_ATTEMPTS then
                if debugGearEnabled then
                    self:DebugPrint(string.format(RCL["Post-combat gear swap attempt %d incomplete (slots %s) - retrying"],
                        attempt, table.concat(mismatches or {}, ",")), "gear")
                end
                C_Timer.After(RETRY_GAP, function()
                    if RC.gearSwapState._swapGen ~= myGen then
                        if debugGearEnabled then RC:DebugPrint("Post-combat swap retry abandoned: new engage cycle started", "gear") end
                        return
                    end
                    if not UnitAffectingCombat("player") then
                        self:AttemptPostCombatGearSwap(targetSet, attempt + 1)
                    else
                        self.gearSwapState.postCombatSet = targetSet
                    end
                end)
            else
                if debugGearEnabled then
                    self:DebugPrint(string.format(RCL["Post-combat gear swap could not fully equip %s after %d attempts (slots still off: %s)"],
                        targetSet, MAX_ATTEMPTS, table.concat(mismatches or {}, ",")), "gear")
                end
                self:GearSwapWarn(RCL["post-combat set '"] .. targetSet .. "'", MAX_ATTEMPTS, mismatches)
                self.gearSwapState.lastEquippedSet = nil
                self.gearSwapState.postCombatSet   = nil
                self.gearSwapState.lastBossTarget  = nil
                self.gearSwapState.engagedBossGUID = nil
                self.gearSwapState._postSwapActiveSet   = nil
                self.gearSwapState._postSwapActiveUntil = nil
            end
        end)
    end

    --------------------------------------------------------------------
    -- THE GEAR SET PICKER
    -- Some kills have no one right set to change into: what to wear after
    -- Heigan depends on the plan for Loatheb. A boss can be set (its Gear
    -- tab, "after the boss dies") to ASK instead - when it dies a small
    -- window lists gear sets and one click equips one. It doubles as the
    -- reminder to change at all, so it stays up until a set is picked, it
    -- is closed, or the next boss is engaged.
    --   forceEquip.deathPrompt = { enabled = true, sets = { [name] = true } }
    -- sits in the boss's forceEquip block so it travels with (and is
    -- stripped with) the rest of that boss's gear. No set ticked means
    -- offer them all. Where the window sits and how big its buttons are
    -- is the character's: RC.db.gearSetPrompt = { x, y, buttonWidth,
    -- rowHeight }.
    --------------------------------------------------------------------
    -- head: title bar; top: where the first button starts; foot: room
    -- under the last one for the resize corner. col/row are the button
    -- width and the row pitch until the window is resized by its corner.
    local PROMPT = {
        head = 26, top = 50, pad = 8, foot = 12, gap = 4,
        col = 176, colMin = 110, colMax = 340,
        row = 24,  rowMin = 20,  rowMax = 46,
        oneColumn = 8,      -- more sets than this go two abreast
    }
    local promptFrame

    -- The sets to offer, in name order: every set, or only the ticked
    -- ones that still exist. If every ticked set has since been deleted
    -- the whole list is offered rather than an empty window.
    function RC:GetGearPromptSets(wanted)
        local all = (self.GetAllGearSets and self:GetAllGearSets()) or {}
        local any = false
        if type(wanted) == "table" then
            for _, on in pairs(wanted) do
                if on then any = true; break end
            end
        end
        if not any then return all end
        local out = {}
        for _, entry in ipairs(all) do
            if wanted[entry.name] then out[#out + 1] = entry end
        end
        if #out == 0 then return all end
        return out
    end

    local function PromptStore()
        if not RC.db then return nil end
        if type(RC.db.gearSetPrompt) ~= "table" then RC.db.gearSetPrompt = {} end
        return RC.db.gearSetPrompt
    end

    -- button width and row pitch: as resized, else the defaults
    local function PromptMetrics()
        local st = PromptStore()
        local colW = tonumber(st and st.buttonWidth) or PROMPT.col
        local rowH = tonumber(st and st.rowHeight) or PROMPT.row
        return math_max(PROMPT.colMin, math_min(PROMPT.colMax, colW)),
               math_max(PROMPT.rowMin, math_min(PROMPT.rowMax, rowH))
    end

    local function PromptRow(f, i)
        local row = f.rows[i]
        if row then return row end
        row = RC.UI:CreateStyledButton(f, "", PROMPT.col, PROMPT.row - 4)
        local ico = row:CreateTexture(nil, "ARTWORK", nil, 2)
        ico:SetPoint("LEFT", row, "LEFT", 2, 0)
        ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        row.setIcon = ico
        row.text:ClearAllPoints()
        row.text:SetPoint("LEFT", ico, "RIGHT", 6, 0)
        row.text:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row:SetScript("OnClick", function(self) RC:PickGearPromptSet(self.setName) end)
        -- (a settings preview's button: the same look, equips nothing)
        if f._rcSample then row:EnableMouse(false) end
        f.rows[i] = row
        return row
    end

    -- size and place the buttons in use: down, then across
    local function PlacePromptRows(f, colW, rowH)
        local perCol = f._perCol or 1
        for i = 1, (f._count or 0) do
            local row = f.rows[i]
            local col = math_floor((i - 1) / perCol)
            local line = (i - 1) % perCol
            row:SetSize(colW, rowH - 4)
            row.setIcon:SetSize(rowH - 8, rowH - 8)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", f, "TOPLEFT",
                PROMPT.pad + col * (colW + PROMPT.gap), -(PROMPT.top + line * rowH))
        end
    end

    local function PromptSize(cols, perCol, colW, rowH)
        return PROMPT.pad * 2 + cols * colW + (cols - 1) * PROMPT.gap,
               PROMPT.top + perCol * rowH + PROMPT.foot
    end

    -- one button per set, and the window sized to fit them
    local function LayoutPrompt(f, sets, subText)
        local n = #sets
        local cols = (n > PROMPT.oneColumn) and 2 or 1
        local perCol = math_max(1, math_ceil(n / cols))
        f._count, f._cols, f._perCol = n, cols, perCol
        for i, entry in ipairs(sets) do
            local row = PromptRow(f, i)
            row.setName = entry.name
            row.text:SetText(entry.name)
            row.setIcon:SetTexture(entry.icon or (RC.GetGearSetIcon and RC:GetGearSetIcon(entry.name)))
            row:Show()
        end
        for i = n + 1, #f.rows do f.rows[i]:Hide() end
        if subText then f.sub:SetText(subText) end

        local colW, rowH = PromptMetrics()
        PlacePromptRows(f, colW, rowH)
        -- the corner can drag between the smallest and largest buttons
        -- for however many are showing
        local minW, minH = PromptSize(cols, perCol, PROMPT.colMin, PROMPT.rowMin)
        local maxW, maxH = PromptSize(cols, perCol, PROMPT.colMax, PROMPT.rowMax)
        if f.SetResizeBounds then
            f:SetResizeBounds(minW, minH, maxW, maxH)
        elseif f.SetMinResize then
            f:SetMinResize(minW, minH)
            if f.SetMaxResize then f:SetMaxResize(maxW, maxH) end
        end
        f._laying = true
        f:SetSize(PromptSize(cols, perCol, colW, rowH))
        f._laying = nil
    end

    -- the window is w x h right now: what button size is that?
    local function PromptMetricsFor(f, w, h)
        local cols, perCol = f._cols or 1, f._perCol or 1
        local colW = (w - PROMPT.pad * 2 - (cols - 1) * PROMPT.gap) / cols
        local rowH = (h - PROMPT.top - PROMPT.foot) / perCol
        return math_max(PROMPT.colMin, math_min(PROMPT.colMax, math_floor(colW + 0.5))),
               math_max(PROMPT.rowMin, math_min(PROMPT.rowMax, math_floor(rowH + 0.5)))
    end

    -- The window's parts (fill, title bar, title, close, the line under
    -- it, the rows table) on f: the live picker and the settings
    -- preview's sample are the same window. A sample's close does nothing.
    local function BuildPromptParts(f, sample)
        local UI = RC.UI
        local win = RC:GetColor("ui", "windowBackground")
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(UI.FLAT)
        bg:SetVertexColor(win.r, win.g, win.b, 0.95)
        f.bg = bg
        f.border = UI:CreateSimpleBorder(f)

        local bar = CreateFrame("Frame", nil, f)
        bar:SetHeight(PROMPT.head)
        bar:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, -1)
        local hdr = RC:GetColor("ui", "headerBackground")
        local fill = bar:CreateTexture(nil, "BACKGROUND")
        fill:SetAllPoints()
        fill:SetTexture(UI.FLAT)
        fill:SetVertexColor(hdr.r, hdr.g, hdr.b, hdr.a or 1)
        bar.bg = fill
        f.titleBar = bar

        local icon = UI:AddTitleIcon(bar, 14, 7)
        local title = RC:CreateFontString(bar, "OVERLAY", nil, 12, "OUTLINE")
        title:SetPoint("LEFT", icon, "RIGHT", 6, 0)
        local ht = RC:GetColor("ui", "headerText")
        title:SetTextColor(ht.r, ht.g, ht.b, 1)
        title:SetText(RCL["Gear set?"])
        f.title = title

        local x = UI:CreateXCloseButton(bar, 18, function() if not sample then RC:HideGearSetPrompt() end end)
        x:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
        f.closeBtn = x
        if UI.ApplyHeaderArt then UI:ApplyHeaderArt(bar, { stepX = 78 }) end

        local sub = RC:CreateFontString(f, "OVERLAY", nil, 10)
        sub:SetPoint("TOPLEFT", f, "TOPLEFT", PROMPT.pad, -(PROMPT.head + 8))
        sub:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PROMPT.pad, -(PROMPT.head + 8))
        sub:SetJustifyH("LEFT")
        sub:SetWordWrap(false)
        local gray = RC:GetColor("text", "gray")
        sub:SetTextColor(gray.r, gray.g, gray.b, 1)
        f.sub = sub

        f.rows = {}
        if sample then x:EnableMouse(false) end
        -- the 5.0 popup look (UIF_Dialogs); the set buttons keep their own
        UI:SkinPopup(f, { header = bar, title = title, close = x, dims = { sub }, titleSize = 13, scan = false })
    end

    -- A sample of the picker for the settings preview, on any parent:
    -- RC.FillGearSetPromptSample(f, sets, subText) lays it out as a kill
    -- would (the saved button size, one or two columns).
    function RC.NewGearSetPromptSample(parent)
        if not (RC.UI and RC.UI.CreateStyledButton) then return nil end
        local f = CreateFrame("Frame", nil, parent)
        f:SetSize(PROMPT.pad * 2 + PROMPT.col, 120)
        f._rcSample = true
        BuildPromptParts(f, true)
        return f
    end
    function RC.FillGearSetPromptSample(f, sets, subText)
        LayoutPrompt(f, sets, subText)
        return f:GetWidth(), f:GetHeight()
    end

    -- Built on first use; also called by the mover so the window exists
    -- to be placed before any boss has asked for it.
    function RC.EnsureGearSetPrompt()
        if promptFrame then return promptFrame end
        if not (RC.UI and RC.UI.CreateStyledButton) then return nil end
        local UI = RC.UI

        local f = CreateFrame("Frame", "WR_GearSetPrompt", UIParent)
        f:SetSize(PROMPT.pad * 2 + PROMPT.col, 120)
        f:SetFrameStrata("HIGH")
        f:SetClampedToScreen(true)
        f:EnableMouse(true)
        f:Hide()

        BuildPromptParts(f)
        -- anything that shows the window other than a boss kill (the
        -- settings page's Preview, the mover) is a preview. A click
        -- there equips the set like any other click; the only difference
        -- is that no boss just died, so there is no post-combat swap for
        -- the pick to call off.
        f.preview = true

        -- The resize corner. Dragging it resizes the BUTTONS: the window
        -- is as wide as its columns and as tall as its rows, so its size
        -- is saved as a button width and a row height, and a boss with
        -- more or fewer sets gets the same buttons in a window that fits.
        -- Attached before the position is bound: the corner's handler is
        -- SET on OnSizeChanged and the position's clamp is hooked on top.
        if UI.AttachResizeGrip then
            local grip = UI:AttachResizeGrip(f, {
                onResize = function(self, w, h)
                    if self._laying or not self._sizing then return end
                    PlacePromptRows(self, PromptMetricsFor(self, w or self:GetWidth(), h or self:GetHeight()))
                end,
            })
            f.resizeGrip = grip
            if grip and grip.HookScript then
                -- __rcDragging is RC.Position's own "the user has hold
                -- of this frame" flag: while it is set the position clamp
                -- does not snap the window back to its saved spot, which
                -- it otherwise would on every size change of the drag
                grip:HookScript("OnMouseDown", function(_, btn)
                    if btn == "LeftButton" then
                        f._sizing = true
                        f.__rcDragging = true
                    end
                end)
                grip:HookScript("OnMouseUp", function()
                    if not f._sizing then return end
                    f._sizing = nil
                    f.__rcDragging = nil
                    local colW, rowH = PromptMetricsFor(f, f:GetWidth(), f:GetHeight())
                    local st = PromptStore()
                    if st then st.buttonWidth, st.rowHeight = colW, rowH end
                    -- snap the window to whole buttons and put it back on
                    -- its pinned corner (sizing leaves it loosely anchored)
                    PlacePromptRows(f, colW, rowH)
                    f._laying = true
                    f:SetSize(PromptSize(f._cols or 1, f._perCol or 1, colW, rowH))
                    f._laying = nil
                    if RC.Position and RC.Position.SaveFrame and RC.Position.IsBound(f) then
                        RC.Position.SaveFrame(f)
                        RC.Position.RestoreFrame(f)
                    elseif RC.SaveConfigurationToProfile then
                        RC:SaveConfigurationToProfile()
                    end
                end)
            end
        end

        LayoutPrompt(f, RC:GetGearPromptSets(nil), RCL["Preview - place me"])

        -- Position lives in the character profile (RC.db.gearSetPrompt).
        -- Pinned by its TOP-LEFT corner, so a boss with more sets grows
        -- the window down and right from where it was put, and the resize
        -- corner (bottom-right) leaves the pinned corner where it is.
        if RC.Position and RC.Position.Bind then
            RC.Position.Bind(f, PromptStore,
                { point = "TOPLEFT", xKey = "x", yKey = "y",
                  default = { point = "CENTER", x = 0, y = 160 },
                  -- (a fresh character: left of the character, under the must-have list)
                  gen2 = { point = "CENTER", x = -470, y = 0 } })
            RC.Position.RestoreFrame(f)
            RC.Position.MakeMovable(f)
        end
        if RC.UIMover and RC.UIMover.RegisterFrame then
            RC.UIMover:RegisterFrame("gearSetPrompt", f, "Gear Set Picker",
                { point = "CENTER", relPoint = "CENTER", x = 0, y = 160 })
        end

        promptFrame = f
        return f
    end

    -- preview: opened from the settings page rather than by a kill. It
    -- works the same - a click equips the set.
    function RC:ShowGearSetPrompt(bossName, wanted, preview)
        local sets = self:GetGearPromptSets(wanted)
        if #sets == 0 then
            if preview then self:Print(RCL["No gear sets yet - build one on the Gear Sets page first."]) end
            return false
        end
        local f = RC.EnsureGearSetPrompt()
        if not f then return false end
        f.preview = preview and true or false
        local who = bossName or RCL["Boss"]
        LayoutPrompt(f, sets, preview and (RCL["Preview - "] .. who) or (who .. RCL[" is down - pick a set"]))
        if RC.UI.PopIn then RC.UI:PopIn(f, 0.15) else f:Show() end
        if debugGearEnabled then
            self:DebugPrint("Gear set picker shown for " .. tostring(bossName) .. " (" .. #sets .. " sets)", "gear")
        end
        return true
    end

    function RC:HideGearSetPrompt()
        local f = promptFrame
        if not f or not f:IsShown() then return end
        if RC.UI and RC.UI.PopOut then RC.UI:PopOut(f, 0.1) else f:Hide() end
    end

    function RC:PickGearPromptSet(setName)
        local preview = promptFrame and promptFrame.preview
        self:HideGearSetPrompt()
        if not setName or setName == "" then return end

        -- The player has chosen after a kill. A post-combat set still
        -- waiting to land, its retries and the 5s post-kill verify would
        -- all pull the gear back, so they stand down. A preview is not a
        -- kill: whatever swap is pending belongs to something else.
        local st = self.gearSwapState
        if st and not preview then
            st.postCombatSet = nil
            st._postSwapActiveSet, st._postSwapActiveUntil = nil, nil
            st._swapGen = (st._swapGen or 0) + 1
            st._verifyGen = (st._verifyGen or 0) + 1
        end

        if InCombatLockdown() then
            self:QueueGearSwap(setName)
            self:Print(RCL["Queued gear set: "] .. setName)
        elseif not self:EquipGearSet(setName) then
            self:Print(RCL["Gear set not found: "] .. setName)
        end
    end

    -- A boss has died: ask, if this boss is set to. bossName may be an
    -- alias; several kill signals can arrive for one kill, hence the 5s
    -- guard. Returns true when the picker went up.
    function RC:CheckGearSetPrompt(bossName, raidName)
        if not bossName then return false end
        -- configured on the Classic Era boss pages (Core_Flavor)
        if not self:FeatureOn("boss_gear_prompt") then return false end
        raidName = raidName
            or (RC.bossTrinketState and RC.bossTrinketState.appliedRaid)
            or (self.GetEffectiveRaidName and self:GetEffectiveRaidName())
        if not raidName then return false end
        local resolved = (self.GetEncounterNameForBoss and self:GetEncounterNameForBoss(raidName, bossName)) or bossName
        local rp  = self.GetActiveRaidProfile and self:GetActiveRaidProfile(raidName)
        local cfg = rp and rp.bosses and rp.bosses[resolved]
        local dp  = cfg and cfg.forceEquip and cfg.forceEquip.deathPrompt
        if type(dp) ~= "table" or not dp.enabled then return false end

        local now, last = GetTime(), self._gearPromptLast
        if last and last.boss == resolved and (now - last.t) < 5 then return false end
        self._gearPromptLast = { boss = resolved, t = now }
        return self:ShowGearSetPrompt(resolved, dp.sets)
    end

    -- Single entry point for everything that fires when the engaged boss dies:
    -- deferred trinket queue switch, post-combat set, death trinkets, death slots.
    -- Called from several places, so each step must tolerate being a no-op.
    function RC:FireDeathGearSwap()
        -- every step below is set up by a Classic Era boss or route step
        -- (Core_Flavor)
        if not self:FeatureOn("boss_gear_kill") then return end
        local pendingCfg = self.pendingDeathConfigSwitch
        if pendingCfg and not InCombatLockdown() then
            self.pendingDeathConfigSwitch = nil
            if pendingCfg.config and self.SetActiveQueue
               and self.trinketSwapSystem
               and self.trinketSwapSystem.queueNames
               and self.trinketSwapSystem.queueNames[pendingCfg.config]
               and self.trinketSwapSystem.currentQueue ~= pendingCfg.config then
                if self:SetActiveQueue(pendingCfg.config) then
                    self:Print(RCL["Trinket config: "]
                        .. self.trinketSwapSystem.queueNames[pendingCfg.config]
                        .. " (" .. (pendingCfg.boss or "boss") .. RCL[" killed)"])
                end
            end
        end
        if self.HandlePostCombatGearSwap then self:HandlePostCombatGearSwap() end
        if self.RunPendingDeathTrinketSwap then self:RunPendingDeathTrinketSwap() end
        if self.RunPendingDeathSlotSwap then self:RunPendingDeathSlotSwap() end
    end

    -- Safety net run 5s after ENCOUNTER_END: re-applies whatever of the death
    -- overrides and post-combat set failed to land. vgen is the generation
    -- stamped at kill time, so a newer encounter cancels this pass.
    function RC:VerifyPostCombatGear(bossName, vgen, attempt, announce)
        attempt = attempt or 1
        if not bossName then return end
        if not self:FeatureOn("boss_gear_kill") then return end
        if RC.gearSwapState and vgen and RC.gearSwapState._verifyGen ~= vgen then return end
        -- Waits out combat at 2s intervals, capped at 20 attempts (~40s).
        if InCombatLockdown() or UnitAffectingCombat("player") then
            if attempt <= 20 then
                C_Timer.After(2, function() RC:VerifyPostCombatGear(bossName, vgen, attempt + 1, announce) end)
            end
            return
        end

        local raidName = (RC.bossTrinketState and RC.bossTrinketState.appliedRaid)
                       or (self.GetEffectiveRaidName and self:GetEffectiveRaidName())
                       or nil
        if not raidName then return end
        local resolved = (self.GetEncounterNameForBoss and self:GetEncounterNameForBoss(raidName, bossName)) or bossName
        local raidProfile = self.GetActiveRaidProfile and self:GetActiveRaidProfile(raidName)
        local bossCfg = raidProfile and raidProfile.bosses and raidProfile.bosses[resolved]
        if not bossCfg then return end

        local fe    = bossCfg.forceEquip
        local gsCfg = bossCfg.abilities and bossCfg.abilities.gearswap
        local postCombatSet = gsCfg and gsCfg.postCombatSet
        local hasPost = postCombatSet and postCombatSet ~= ""

        local deathT1 = fe and (fe.deathSlot1 or (fe.onDeath and fe.onDeath[13]))
        local deathT2 = fe and (fe.deathSlot2 or (fe.onDeath and fe.onDeath[14]))
        local deathSlotsMap = nil
        local deathEnchants = nil
        if fe and fe.onDeath then
            for invSlot, itemId in pairs(fe.onDeath) do
                if invSlot ~= 13 and invSlot ~= 14 and itemId and itemId ~= 0 then
                    deathSlotsMap = deathSlotsMap or {}
                    deathSlotsMap[invSlot] = itemId
                    local e = fe.onDeathEnchant and fe.onDeathEnchant[invSlot]
                    if e and e ~= 0 then
                        deathEnchants = deathEnchants or {}
                        deathEnchants[invSlot] = e
                    end
                end
            end
        end

        if not hasPost and not deathT1 and not deathT2 and not deathSlotsMap then
            return
        end

        local GetID = GetInventoryItemID
        local reapplied = {}

        if deathT1 or deathT2 then
            local e13 = GetID and GetID("player", 13) or nil
            local e14 = GetID and GetID("player", 14) or nil
            local miss1 = deathT1 and deathT1 ~= 0 and e13 ~= deathT1
            local miss2 = deathT2 and deathT2 ~= 0 and e14 ~= deathT2
            if miss1 or miss2 then
                RC.pendingDeathTrinketSwap = {
                    src = "boss",
                    slot1 = deathT1, slot2 = deathT2, boss = resolved,
                    hasFullSet = hasPost and true or false,
                }
                if self.RunPendingDeathTrinketSwap then self:RunPendingDeathTrinketSwap() end
                reapplied[#reapplied + 1] = "death trinkets"
            end
        end

        if deathSlotsMap then
            local anyMiss = false
            for invSlot, itemId in pairs(deathSlotsMap) do
                local have, haveEnch = self:GetEquippedIdEnchant(invSlot)
                local wantEnch = deathEnchants and deathEnchants[invSlot]
                if have ~= itemId or (wantEnch and wantEnch ~= 0 and haveEnch ~= wantEnch) then
                    anyMiss = true; break
                end
            end
            if anyMiss then
                RC.pendingDeathSlotSwap = {
                    src = "boss",
                    slots = deathSlotsMap, enchants = deathEnchants, boss = resolved,
                    hasFullSet = hasPost and true or false,
                }
                if self.RunPendingDeathSlotSwap then self:RunPendingDeathSlotSwap() end
                reapplied[#reapplied + 1] = "death slots"
            end
        end

        -- Death overrides outrank the post-combat set: any slot they own is
        -- excluded from the set mismatch scan below.
        if hasPost then
            local skip = {}
            if deathT1 and deathT1 ~= 0 then skip[13] = true end
            if deathT2 and deathT2 ~= 0 then skip[14] = true end
            if deathSlotsMap then for s in pairs(deathSlotsMap) do skip[s] = true end end

            local sd = (self.db and self.db.gearSets and self.db.gearSets[postCombatSet])
                    or (self.GearManager and self.GearManager.sets and self.GearManager.sets[postCombatSet])
            local src = sd and (sd.equip or sd.items or sd.slots)
            local setMismatch = false
            if src then
                for slot, link in pairs(src) do
                    if type(slot) == "number" and not skip[slot] and link then
                        local wantId = nil
                        if type(link) == "string" then wantId = tonumber(link:match("item:(%d+)"))
                        elseif type(link) == "number" then wantId = link
                        elseif type(link) == "table" and link.itemId then wantId = link.itemId end
                        if wantId then
                            -- wantId 0 = unequip: an empty slot is the match
                            local haveId = GetID and GetID("player", slot) or nil
                            if (haveId or 0) ~= wantId then setMismatch = true; break end
                        end
                    end
                end
                if setMismatch then
                    RC.gearSwapState = RC.gearSwapState or {}
                    RC.gearSwapState.postCombatSet = postCombatSet
                    if self.AttemptPostCombatGearSwap then self:AttemptPostCombatGearSwap(postCombatSet) end
                    reapplied[#reapplied + 1] = "set '" .. postCombatSet .. "'"
                end
            end
        end

        local resultMsg
        if #reapplied > 0 then
            resultMsg = "Post-combat gear verify (" .. resolved .. "): re-applied missing " .. table.concat(reapplied, ", ")
        else
            resultMsg = "Post-combat gear verify (" .. resolved .. "): all post-combat gear verified equipped"
        end
        if announce then
            RC:Print(resultMsg)
        else
            RC:DebugPrint(resultMsg, "gear")
        end
    end

    function RC:StartGearSwapSim(bossInput)
        if not bossInput or bossInput == "" then
            self:Print(RCL["Usage: /rc gearsim <boss name> - simulates the engage + death gear swaps using your config for that boss."])
            return
        end

        local canonicalName, raidName
        if RC.raidMobConfigs then
            local lower = bossInput:lower()
            for raid, bosses in pairs(RC.raidMobConfigs) do
                for bn in pairs(bosses) do
                    if bn:lower() == lower then canonicalName, raidName = bn, raid; break end
                end
                if canonicalName then break end
            end
        end
        if not canonicalName then
            self:Print(RCL["|cffff5555Gear Sim:|r no boss named '"] .. bossInput
                .. RCL["' found. Run '/rc encounter start' with no name to list known bosses."])
            return
        end

        local raidProfile = self.GetActiveRaidProfile and self:GetActiveRaidProfile(raidName)
        local cfg = raidProfile and raidProfile.bosses and raidProfile.bosses[canonicalName]
        if not cfg then
            self:Print(RCL["|cffff5555Gear Sim:|r no saved config for "] .. canonicalName .. " (" .. raidName .. ").")
            return
        end

        local fe      = cfg.forceEquip
        local gsCfg   = cfg.abilities and cfg.abilities.gearswap
        local onSet   = gsCfg and gsCfg.gearSet
        local postSet = gsCfg and gsCfg.postCombatSet
        local function nm(id)
            if not id or id == 0 then return nil end
            local n = GetItemInfo(id)
            return n or ("item:" .. id)
        end

        self:Print(RCL["|cff66ccffGear Sim:|r "] .. canonicalName .. " (" .. raidName
            .. RCL[") - driving the real engage + death path. This equips real gear."])
        self:Print(RCL["  On-target set: "] .. ((onSet and onSet ~= "") and onSet or "none")
            .. RCL["   Post-combat set: "] .. ((postSet and postSet ~= "") and postSet or "none"))
        if fe then
            local t1, t2 = nm(fe.slot1), nm(fe.slot2)
            if t1 or t2 then
                self:Print(RCL["  On-target trinkets: "] .. (t1 or "-") .. " / " .. (t2 or "-"))
            end
            local dt1 = nm(fe.deathSlot1 or (fe.onDeath and fe.onDeath[13]))
            local dt2 = nm(fe.deathSlot2 or (fe.onDeath and fe.onDeath[14]))
            if dt1 or dt2 then
                self:Print(RCL["  Death trinkets: "] .. (dt1 or "-") .. " / " .. (dt2 or "-"))
            end
            local function countSlots(map, skipTrinkets)
                if not map then return 0 end
                local c = 0
                for s, id in pairs(map) do
                    if id and id ~= 0 and not (skipTrinkets and (s == 13 or s == 14)) then c = c + 1 end
                end
                return c
            end
            local onN  = countSlots(fe.onTarget, false)
            local dthN = countSlots(fe.onDeath, true)
            if onN  > 0 then self:Print(RCL["  On-target slot overrides: "] .. onN) end
            if dthN > 0 then self:Print(RCL["  Death slot overrides: "] .. dthN) end
        end

        self.gearSwapState = self.gearSwapState or {}
        self.gearSwapState.postCombatSet   = (postSet and postSet ~= "") and postSet or nil
        self.gearSwapState.lastBossTarget  = nil
        self.gearSwapState.engagedInCombat = nil
        self.activeEncounterName = nil
        RC.bossTrinketState = RC.bossTrinketState or {}
        RC.bossTrinketState.appliedRaid = raidName

        local inCombat = InCombatLockdown() or UnitAffectingCombat("player")

        self:Print(RCL["|cff66ccff[1/3]|r Engaging "] .. canonicalName .. RCL[" - applying on-target gear"]
            .. (inCombat and " (in combat: queued, gear can't change yet)" or "") .. "...")
        if self.RunEngageGearSwap then
            self:RunEngageGearSwap(canonicalName, raidName, { name = canonicalName, encounterType = "boss" })
        end

        if inCombat then
            self:Print("|cff66ccff[2/3]|r " .. canonicalName .. RCL[" dies - arming death overrides + post-combat set..."])
            if self.OnBossUnitDied then self:OnBossUnitDied("gearsim-" .. canonicalName, canonicalName) end
            self:CheckGearSetPrompt(canonicalName, raidName)
            self:Print(RCL["|cffffcc00Gear Sim (in combat):|r gear cannot change in combat. The post-combat set and death "]
                .. RCL["overrides are armed - they apply the moment combat drops, exactly like Heigan once the gauntlet ends. "]
                .. RCL["Leave combat to watch them land. (/rc debugcat gear to trace.)"])
            return
        end

        C_Timer.After(2.5, function()
            self:Print("|cff66ccff[2/3]|r " .. canonicalName
                .. RCL[" dies - arming death overrides + firing post-combat swap..."])
            if self.OnBossUnitDied    then self:OnBossUnitDied("gearsim-" .. canonicalName, canonicalName) end
            if self.FireDeathGearSwap then self:FireDeathGearSwap() end
            self:CheckGearSetPrompt(canonicalName, raidName)

            C_Timer.After(4, function()
                self:Print(RCL["|cff66ccff[3/3]|r Verifying everything landed..."])
                if self.VerifyPostCombatGear then self:VerifyPostCombatGear(canonicalName, nil, nil, true) end
                self:Print(RCL["|cff66ccffGear Sim complete.|r Re-equip your normal set when you are done testing."])
            end)
        end)
    end

    -- Two paths. Out of combat everything goes through ApplyBossForceEquip.
    -- Under lockdown nothing can be equipped, so this only seeds gearSwapState
    -- and stashes the slot overrides for the regen edge to replay.
    function RC:RunEngageGearSwap(encounterName, raidName, triggerTarget)
        if not encounterName or not triggerTarget then return end
        -- configured on the Classic Era boss pages (Core_Flavor)
        if not self:FeatureOn("boss_gear_target") then return end

        local raidProfile = self.GetActiveRaidProfile and self:GetActiveRaidProfile(raidName)
        local cfg = nil
        local isBoss = false
        if raidProfile then
            local resolvedEnc = (self.GetEncounterNameForBoss
                and self:GetEncounterNameForBoss(raidName, triggerTarget.name)) or encounterName
            if raidProfile.bosses and raidProfile.bosses[resolvedEnc] then
                encounterName = resolvedEnc
                cfg = raidProfile.bosses[resolvedEnc]
                isBoss = true
            elseif raidProfile.bosses and raidProfile.bosses[encounterName] then
                cfg = raidProfile.bosses[encounterName]
                isBoss = true
            elseif raidProfile.trash then
                cfg = raidProfile.trash[encounterName]
            end
        end
        if not cfg then return end

        if not InCombatLockdown() then
            local fe          = cfg.forceEquip
            local gsCfg       = cfg.abilities and cfg.abilities.gearswap
            local gearSet     = gsCfg and gsCfg.gearSet
            local hasOnTarget = fe and fe.onTarget and next(fe.onTarget) ~= nil
            local hasFE       = fe and (fe.slot1 or fe.slot2 or hasOnTarget)
            local hasSet      = gearSet and gearSet ~= ""
            if hasFE or hasSet then
                self:ApplyBossForceEquip(fe or {}, encounterName, raidName, { gearSetName = gearSet })
            end
            return
        end

        if not isBoss then return end

        local gsCfg   = cfg.abilities and cfg.abilities.gearswap
        local gearSet = gsCfg and (gsCfg.gearSet or gsCfg.itemRackSet)
        local postSet = gsCfg and gsCfg.postCombatSet
        local hasSet  = gearSet and gearSet ~= ""
        local hasPost = postSet and postSet ~= ""

        if not (hasSet or hasPost) then return end
        self.gearSwapState = self.gearSwapState or {}

        if hasSet then
            local alreadyHandled =
                self.gearSwapState.engageHandledBoss == encounterName
                and self.gearSwapState.engageHandledTime
                and (GetTime() - self.gearSwapState.engageHandledTime) < 30
            if not alreadyHandled then
                self.gearSwapState.engageHandledBoss = encounterName
                self.gearSwapState.engageHandledTime = GetTime()
                self:EquipGearSet(gearSet)
                if self:IsDebugEnabled("gear") then
                    self:DebugPrint("In-combat boss target: queued combat set '"
                        .. gearSet .. "' for " .. encounterName, "gear")
                end
            end
        end

        local feIC = cfg.forceEquip
        if feIC and feIC.onTarget then
            local pSlots, pEnch
            for s, id in pairs(feIC.onTarget) do
                if s ~= 13 and s ~= 14 and id and id ~= 0 then
                    pSlots = pSlots or {}
                    pSlots[s] = id
                    local e = feIC.onTargetEnchant and feIC.onTargetEnchant[s]
                    if e and e ~= 0 then pEnch = pEnch or {}; pEnch[s] = e end
                end
            end
            if pSlots then
                RC._pendingOnTargetSlots    = pSlots
                RC._pendingOnTargetReason   = "in-combat engage: " .. tostring(encounterName)
                RC._pendingOnTargetEnchants = pEnch
                if self:IsDebugEnabled("gear") then
                    self:DebugPrint("In-combat engage: stashed " .. tostring(encounterName)
                        .. " slot overrides for the regen edge", "gear")
                end
            end
        end

        -- Only seed post-combat state once the boss is actually fighting;
        -- targeting an idle boss must not arm a post-combat swap.
        if UnitAffectingCombat("target") then
            if not self.gearSwapState.postCombatSet
            or self.gearSwapState.postCombatSet == "" then
                if hasPost then
                    self.gearSwapState.postCombatSet = postSet
                end
                self.gearSwapState.lastEquippedSet = gearSet or postSet
                self:DebugPrint("In-combat boss target: seeded gear state for "
                    .. encounterName, "gear")
            end
            self.gearSwapState.lastBossTarget = triggerTarget.name
            self.gearSwapState.engagedInCombat = encounterName
        end
    end

    -- The engaged boss is often not the current target, so target, mouseover,
    -- boss1-5 and every visible nameplate are checked before calling it dead.
    -- GUID match is preferred; name match is the fallback after a reload.
    function RC:IsEngagedBossAlive()
        local gs = self.gearSwapState
        if not gs then return false end
        local wantGUID = gs.engagedBossGUID
        local wantName = gs.lastBossTarget
        if not wantGUID and not wantName then
            return false
        end

        local function unitIsEngagedBoss(unit)
            if not UnitExists(unit) then return false end
            if UnitIsDead(unit) then return false end
            if wantGUID then
                return Readycheck.SafeGUID(unit) == wantGUID
            elseif wantName then
                return Readycheck.SafeName(unit) == wantName
            end
            return false
        end

        if unitIsEngagedBoss("target") then return true end
        if unitIsEngagedBoss("mouseover") then return true end
        for i = 1, 5 do
            if unitIsEngagedBoss("boss" .. i) then return true end
        end

        if C_NamePlate and C_NamePlate.GetNamePlates then
            local plates = C_NamePlate.GetNamePlates()
            if plates then
                for _, plate in ipairs(plates) do
                    local u = plate and plate.namePlateUnitToken
                    if u and unitIsEngagedBoss(u) then return true end
                end
            end
        end

        return false
    end

_tes.reuseVisibleIcons = reuseVisibleIcons
_tes.abilityMetaCache  = abilityMetaCache
_tes.abilityReadyCache = abilityReadyCache
_tes.ABILITY_READY_TTL = ABILITY_READY_TTL
