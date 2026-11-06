------------------------------------------------------------------------
-- Readycheck - World Tools Auto Turn-ins
-- Hands in the repeatable buff quests and clicks through the gossip that
-- guards them: Dire Maul tribute guards, the BWL orb, Sayge's fortune,
-- Winterspring E'ko, Zul'Gurub coins, Zanza potions, Rage of Ages, and
-- repairing at Rin'wosho while we are standing there anyway.
--
-- SHIFT IS THE UNIVERSAL ESCAPE. Holding shift when the dialog opens
-- skips every automation in this file, so a manual visit is always
-- possible without turning settings off.
--
-- THE HARD PART IS NOT THE CLICKING, IT IS KNOWING IF IT WORKED.
-- Unique rewards (zanzas, R.O.I.D.S.) silently fail when a copy is
-- already sitting in the bank or the mail, and the server reports that
-- exactly the same as success. So every unique pick is stamped as failed
-- BEFORE it is requested, then cleared only once the item is observed
-- arriving in the bags. A pick that vanishes leaves the stamp behind and
-- that reward is skipped for a while instead of being retried forever.
--
-- No combat gate: none of this can fire unless an NPC dialog is open.
------------------------------------------------------------------------
-- World buffs are Classic Era content: TBC and Forever never run this
-- addon (Readycheck Core_Flavor).
if _G.Readycheck and _G.Readycheck.FeatureOn and not _G.Readycheck:FeatureOn("world_tools") then return end
local RC = _G.Readycheck
if not RC then return end
local WT = RC.WorldTools
if not WT then return end

local RCC = RC.Compat or {}
local GetItemCount = GetItemCount or RCC.GetItemCount
local GetTime, ipairs, tonumber = GetTime, ipairs, tonumber

-- ============================================================
-- SHARED HELPERS
-- ============================================================
-- Creature id out of a GUID's second-to-last field.
local function NpcId(unit)
    local guid = UnitGUID(unit or "npc")
    return guid and guid:match("%-(%d+)%-[^%-]*$") or nil
end

local function Bags(itemID)
    return GetItemCount(itemID, false, false) or 0
end

local Gossip = {}

function Gossip.Count()
    if C_GossipInfo and C_GossipInfo.GetOptions then
        return #C_GossipInfo.GetOptions()
    end
    if GetGossipOptions then
        -- Legacy returns title/type pairs as varargs.
        return #{ GetGossipOptions() } / 2
    end
    return 0
end

function Gossip.Choose(index)
    if C_GossipInfo and C_GossipInfo.SelectOptionByIndex then
        C_GossipInfo.SelectOptionByIndex(index - 1)
    elseif SelectGossipOption then
        SelectGossipOption(index)
    end
end

function Gossip.Close()
    if C_GossipInfo and C_GossipInfo.CloseGossip then
        C_GossipInfo.CloseGossip()
    elseif CloseGossip then
        CloseGossip()
    end
end

-- Modern clients select a quest by id; older ones only by list position, so
-- the id has to be looked back up into an index. One helper rather than the
-- same fallback dance written out at each of the four call sites.
-- kind is "available" or "active".
local function OfferedQuests(kind)
    if not C_GossipInfo then return {} end
    local get = (kind == "active") and C_GossipInfo.GetActiveQuests
        or C_GossipInfo.GetAvailableQuests
    return (get and get()) or {}
end

local function IsOffered(questID, kind)
    for _, q in ipairs(OfferedQuests(kind)) do
        if q.questID == questID then return true end
    end
    return false
end

local function PickQuest(questID, kind)
    if not C_GossipInfo then return false end
    local byId = (kind == "active") and C_GossipInfo.SelectActiveQuest
        or C_GossipInfo.SelectAvailableQuest
    if byId then byId(questID) return true end
    local byIndex = (kind == "active") and SelectGossipActiveQuest
        or SelectGossipAvailableQuest
    if not byIndex then return false end
    for i, q in ipairs(OfferedQuests(kind)) do
        if q.questID == questID then byIndex(i) return true end
    end
    return false
end

-- Only bags with no family can hold a quest reward; a herb bag cannot.
local function HasGenericBagSpace()
    local get = (C_Container and C_Container.GetContainerNumFreeSlots)
        or GetContainerNumFreeSlots
    if not get then return true end
    for bag = 0, 4 do
        local free, family = get(bag)
        if (family == nil or family == 0) and (tonumber(free) or 0) > 0 then
            return true
        end
    end
    return false
end
WT._HasGenericBagSpace = HasGenericBagSpace

-- Watches the bags until itemID shows up or the wait runs out. A single
-- delayed check races the server and reports false failures, so this keeps
-- looking on every bag update instead of guessing at one deadline.
local function VerifyRewardLanded(itemID, onArrived, onMissing, opts)
    opts = opts or {}
    if not (itemID and C_Timer and C_Timer.After) then
        if onMissing then onMissing() end
        return
    end
    if Bags(itemID) > 0 then
        if onArrived then onArrived(Bags(itemID)) end
        return
    end

    local watcher, done = CreateFrame("Frame"), false
    local function finish()
        done = true
        watcher:UnregisterAllEvents()
        watcher:SetScript("OnEvent", nil)
    end
    watcher:RegisterEvent("BAG_UPDATE_DELAYED")
    watcher:SetScript("OnEvent", function()
        if done or Bags(itemID) <= 0 then return end
        finish()
        if onArrived then onArrived(Bags(itemID)) end
    end)
    C_Timer.After(opts.maxWait or 5, function()
        if done then return end
        finish()
        if onMissing then onMissing() end
    end)
end
WT._VerifyRewardLanded = VerifyRewardLanded

-- Wall-clock "do not retry this yet" marker. Entries expire lazily on read
-- so nothing has to sweep them. Used for both the zanzas (per item) and
-- Rage of Ages (a single reward).
local function NewCooldownSet(ttl)
    local stamps = {}
    return {
        mark   = function(key) stamps[key or 1] = GetTime() end,
        clear  = function(key) stamps[key or 1] = nil end,
        active = function(key)
            key = key or 1
            local at = stamps[key]
            if not at then return false end
            if (GetTime() - at) < ttl then return true end
            stamps[key] = nil
            return false
        end,
    }
end

local function Say(color, tag, text)
    RC:Print(("|cFF%s[%s]|r %s"):format(color, tag, text))
end

-- ============================================================
-- REPAIRING AT RIN'WOSHO
-- ============================================================
-- He sells and repairs as well as taking Honor Tokens. The repair APIs
-- only work with a merchant window open, and the gossip option opens it
-- asynchronously, so the repair itself happens on MERCHANT_SHOW.
local RINWOSHO = "14921"
-- 1.15's gossip options carry no type field; a vendor is identified by
-- its icon file id.
local VENDOR_ICON = 132060
local REPAIR_RETRY = 5

local repairArmed, lastRepairTry = false, 0

local function AnythingDamaged()
    if not GetInventoryItemDurability then return false end
    for slot = 1, 18 do
        local cur, max = GetInventoryItemDurability(slot)
        if cur and max and max > 0 and cur < max then return true end
    end
    return false
end

local function RepairNow()
    if not (CanMerchantRepair and CanMerchantRepair()) then return end
    local cost, allowed = GetRepairAllCost()
    if not allowed or not cost or cost <= 0 then return end
    local price = (GetCoinTextureString and GetCoinTextureString(cost)) or cost
    if (GetMoney and GetMoney() or 0) >= cost then
        RepairAllItems()
        Say("55FF77", "Auto-Repair", "Repaired for " .. price .. ".")
    else
        Say("FFAA55", "Auto-Repair", "Can't afford " .. price .. " to repair.")
    end
end

local function OpenRepairIfNeeded(fs)
    local aq = fs and fs.autoQuest
    if not (aq and aq.autoRepairEnabled) then return end
    if not AnythingDamaged() then return end
    if (GetTime() - lastRepairTry) < REPAIR_RETRY then return end
    if not (C_GossipInfo and C_GossipInfo.GetOptions
        and C_GossipInfo.SelectOptionByIndex) then return end

    for _, opt in ipairs(C_GossipInfo.GetOptions()) do
        local icon = opt.overrideIconID or opt.icon
        if icon == VENDOR_ICON and opt.orderIndex then
            repairArmed, lastRepairTry = true, GetTime()
            -- If MERCHANT_SHOW never arrives, disarm rather than leaving a
            -- flag set that would hijack the next manual visit.
            if C_Timer and C_Timer.After then
                C_Timer.After(3, function() repairArmed = false end)
            end
            C_GossipInfo.SelectOptionByIndex(opt.orderIndex)
            return
        end
    end
end

do
    local f = CreateFrame("Frame")
    f:RegisterEvent("MERCHANT_SHOW")
    f:SetScript("OnEvent", function()
        -- Only when WE opened it: shopping at Rin'wosho by hand is never
        -- interrupted by an automatic repair-and-close.
        if not repairArmed then return end
        repairArmed = false
        if NpcId() ~= RINWOSHO then return end
        RepairNow()
        if CloseMerchant then CloseMerchant() end
    end)
end

-- ============================================================
-- SIMPLE COLLECT-AND-HAND-IN NPCS
-- ============================================================
-- Mau'ari and Vinchaxa work identically: look down a priority list, find
-- the first set of items the player actually has, and hand that one in.
-- Both then need the same two-step progress/complete follow-up, so they
-- share one handler rather than having one each.
local COLLECTORS = {
    ["10307"] = {                       -- Mau'ari, Winterspring E'ko
        setting = "ekoEnabled",
        state   = "_mauariActiveQuest",
        offers  = {
            { quest = 4806, items = { 12436 }, need = 3 },
            { quest = 4802, items = { 12431 }, need = 3 },
            { quest = 4804, items = { 12434 }, need = 3 },
            { quest = 4803, items = { 12432 }, need = 3 },
            { quest = 4805, items = { 12435 }, need = 3 },
            { quest = 4807, items = { 12433 }, need = 3 },
            { quest = 4801, items = { 12430 }, need = 3 },
        },
    },
    ["15070"] = {                       -- Vinchaxa, Zul'Gurub coin sets
        setting = "coinsEnabled",
        state   = "_vinchaxaActiveQuest",
        -- Each set needs one of all three coins. 8240, the bijou turn-in,
        -- is deliberately absent - it is not a buff quest.
        offers  = {
            { quest = 8238, items = { 19701, 19702, 19703 }, need = 1 },
            { quest = 8239, items = { 19704, 19705, 19706 }, need = 1 },
            { quest = 8195, items = { 19698, 19699, 19700 }, need = 1 },
        },
    },
}

local function HaveAll(offer)
    for _, item in ipairs(offer.items) do
        if Bags(item) < offer.need then return false end
    end
    return true
end

local function RunCollector(npcID, def, aq)
    if not (aq and aq[def.setting]) then return end
    for _, offer in ipairs(def.offers) do
        if HaveAll(offer) then
            WT[def.state] = offer.quest
            PickQuest(offer.quest, "available")
            return
        end
    end
    WT[def.state] = nil
end

-- Shared progress/complete follow-up for both collectors.
do
    local f = CreateFrame("Frame")
    f:RegisterEvent("QUEST_PROGRESS")
    f:RegisterEvent("QUEST_COMPLETE")
    f:SetScript("OnEvent", function(_, event)
        local npcID = NpcId()
        local def = npcID and COLLECTORS[npcID]
        if not def or not WT[def.state] then return end
        local fs = WT:GetFactionSettings()
        local aq = fs and fs.autoQuest
        if not (aq and aq[def.setting]) then return end

        if event == "QUEST_PROGRESS" then
            if IsQuestCompletable and IsQuestCompletable() and CompleteQuest then
                CompleteQuest()
            end
        elseif (GetNumQuestChoices and GetNumQuestChoices() or 0) == 0
            and GetQuestReward then
            GetQuestReward()
        end
    end)
end

-- ============================================================
-- ZANZAS
-- ============================================================
-- Quest 8243 trades one Honor Token for a zanza of the player's choice.
-- They are unique, so one already stashed in the bank makes the pick fail
-- silently - hence the bank snapshot and the rejection cooldown.
local ZANZA_QUEST, ZANZA_TOKEN = 8243, 19858
local ZANZA_TTL = 30
local ZANZAS = {
    { itemID = 20081, key = "swiftness" },
    { itemID = 20079, key = "spirit" },
    { itemID = 20080, key = "sheen" },
}

local zanzaCooldown = NewCooldownSet(ZANZA_TTL)
local zanzaAttempt, zanzaPicking = nil, false

-- The client only knows what is in the bank while the bank is open, so
-- ownership there is remembered from the last time it was. Session only:
-- a stale count after a reload would be worse than no count.
local bankSeen = {}

local function SnapshotBank()
    for _, z in ipairs(ZANZAS) do
        local total = GetItemCount(z.itemID, true, false) or 0
        local held = total - Bags(z.itemID)
        bankSeen[z.itemID] = held > 0 and held or 0
    end
end

do
    local f, open = CreateFrame("Frame"), false
    f:RegisterEvent("BANKFRAME_OPENED")
    f:RegisterEvent("BANKFRAME_CLOSED")
    f:SetScript("OnEvent", function(self, event)
        if event == "BANKFRAME_OPENED" then
            open = true
            SnapshotBank()
            -- Re-snapshot on every change WHILE open. Not on close: by then
            -- the client has already forgotten the contents.
            self:RegisterEvent("BAG_UPDATE")
        elseif event == "BAG_UPDATE" then
            if open then SnapshotBank() end
        else
            open = false
            self:UnregisterEvent("BAG_UPDATE")
        end
    end)
end

local function ZanzaOwned(z)
    return Bags(z.itemID) + (bankSeen[z.itemID] or 0)
end

local function ZanzaWanted(z, picks)
    return picks[z.key] and not zanzaCooldown.active(z.itemID)
        and ZanzaOwned(z) == 0
end

local function ZanzaPicks()
    local fs = WT:GetFactionSettings()
    local aq = fs and fs.autoQuest
    if not (aq and aq.zanzaEnabled) then return nil end
    return aq.zanzaPicks or {}
end

-- Answers "is there anything here for me" without the reward page open,
-- so the gossip can be skipped entirely when there is not.
function WT:_AnyZanzaPickable()
    local picks = ZanzaPicks()
    if not picks then return false end
    for _, z in ipairs(ZANZAS) do
        if ZanzaWanted(z, picks) then return true end
    end
    return false
end

-- Highest-priority zanza that is wanted AND on offer right now.
local function ChooseZanza()
    local picks = ZanzaPicks()
    if not picks then return nil end
    local count = GetNumQuestChoices and GetNumQuestChoices() or 0
    if count == 0 then return nil end

    -- Era's GetQuestItemInfo omits the item id, so it comes from the link.
    local slotOf = {}
    for i = 1, count do
        local link = GetQuestItemLink and GetQuestItemLink("choice", i)
        local id = link and tonumber(link:match("item:(%d+)"))
        if id then slotOf[id] = i end
    end

    for _, z in ipairs(ZANZAS) do
        local slot = slotOf[z.itemID]
        if slot and ZanzaWanted(z, picks) then
            return z, slot, (GetQuestItemInfo("choice", slot)) or "Zanza"
        end
    end
    return nil
end

local bagWatch, watching = CreateFrame("Frame"), false

local function StopBagWatch()
    if not watching then return end
    watching = false
    bagWatch:UnregisterAllEvents()
    bagWatch:SetScript("OnEvent", nil)
end
WT._StopZanzaBagWatch = StopBagWatch

local function TakeZanza(z, slot, name)
    if not GetQuestReward then return end
    zanzaAttempt = { itemID = z.itemID, name = name }
    -- Stamped as failed up front. If the pick silently does nothing, the
    -- stamp survives and the next walk moves on instead of looping here.
    zanzaCooldown.mark(z.itemID)
    Say("55DDFF", "Auto-Zanza", "Picking " .. name .. ".")
    GetQuestReward(slot)
end

-- With the reward page open but everything already owned, stay open and
-- watch: the moment one is drunk it becomes pickable, with no need to
-- re-open the gossip.
local function StartBagWatch()
    if watching then return end
    watching = true
    bagWatch:RegisterEvent("BAG_UPDATE_DELAYED")
    bagWatch:SetScript("OnEvent", function()
        local z, slot, name = ChooseZanza()
        if not z then return end
        StopBagWatch()          -- before picking, so exactly one fires
        TakeZanza(z, slot, name)
    end)
end

local function ResetZanzaState()
    zanzaAttempt, zanzaPicking = nil, false
    StopBagWatch()
    -- Rejection stamps survive on purpose; they age out by wall clock.
end
WT._ResetZanzaState = ResetZanzaState

do
    local f = CreateFrame("Frame")
    f:RegisterEvent("QUEST_PROGRESS")
    f:RegisterEvent("QUEST_COMPLETE")
    f:RegisterEvent("QUEST_FINISHED")
    f:SetScript("OnEvent", function(_, event)
        if event == "QUEST_FINISHED" then
            StopBagWatch()
            -- Fires twice for a repeatable turn-in: once after completing,
            -- once after taking the reward. Only the second has an attempt
            -- attached, and only that one is worth verifying.
            local attempt = zanzaAttempt
            zanzaAttempt, zanzaPicking = nil, false
            if not attempt then return end
            VerifyRewardLanded(attempt.itemID, function()
                zanzaCooldown.clear(attempt.itemID)
                Say("55FF77", "Auto-Zanza", "Got " .. attempt.name .. ".")
            end, function()
                zanzaCooldown.mark(attempt.itemID)
                Say("FFAA55", "Auto-Zanza", attempt.name
                    .. " never arrived - probably a copy stashed elsewhere. "
                    .. ("Skipping it for %ds."):format(ZANZA_TTL))
            end)
            return
        end

        if not WT._zanzaActiveQuest then return end
        local picks = ZanzaPicks()
        if not picks then return end

        if event == "QUEST_PROGRESS" then
            -- Rin'wosho also offers 8196 and 8246, both one-token turn-ins
            -- that must never be auto-progressed.
            if NpcId() ~= RINWOSHO then return end
            if (GetQuestID and GetQuestID() or 0) ~= ZANZA_QUEST then return end
            if IsQuestCompletable and IsQuestCompletable() and CompleteQuest then
                CompleteQuest()
            end
            return
        end

        -- The npc unit is already gone by now, so identify by quest id.
        if (GetQuestID and GetQuestID() or 0) ~= ZANZA_QUEST then return end
        if zanzaPicking then return end
        zanzaPicking = true

        local z, slot, name = ChooseZanza()
        if z then
            StopBagWatch()
            TakeZanza(z, slot, name)
        else
            Say("888888", "Auto-Zanza", "Every enabled zanza is already in "
                .. "your bag or bank - drink one and I'll take a fresh copy.")
            zanzaAttempt = nil
            StartBagWatch()
        end
    end)
end

-- ============================================================
-- RAGE OF AGES
-- ============================================================
-- Quest 2582 at Bloodmage Drazial. Same unique-reward problem as the
-- zanzas, so the same cooldown treatment, but there is only one reward.
local ROIDS_QUEST, ROIDS_ITEM, ROIDS_NPC = 2582, 8410, "7505"
local ROIDS_TTL = 30
local ROIDS_COST = {
    { item = 8391, need = 3 },   -- Snickerfang Jowl
    { item = 8392, need = 2 },   -- Blasted Boar Lung
    { item = 8393, need = 1 },   -- Scorpok Pincer
}

local roidsCooldown = NewCooldownSet(ROIDS_TTL)
local roidsTaking, roidsPicking = false, false

local function ResetRoidsState()
    roidsTaking, roidsPicking = false, false
end
WT._ResetRoidsState = ResetRoidsState
function WT:_IsRoidsRejectedRecently() return roidsCooldown.active() end

-- With full bags, the turn-in only works if some reagent is held at
-- exactly the required count, because emptying that stack frees the slot
-- the reward needs.
local function RoidsFitsInBags()
    if HasGenericBagSpace() then return true end
    for _, r in ipairs(ROIDS_COST) do
        if Bags(r.item) == r.need then return true end
    end
    return false
end

do
    local f = CreateFrame("Frame")
    f:RegisterEvent("QUEST_DETAIL")
    f:RegisterEvent("QUEST_PROGRESS")
    f:RegisterEvent("QUEST_COMPLETE")
    f:RegisterEvent("QUEST_FINISHED")
    f:SetScript("OnEvent", function(_, event)
        if event == "QUEST_FINISHED" then
            -- Only verify if a reward was actually requested; a plain
            -- accept also ends here and must not read as a failure.
            local taking = roidsTaking
            roidsTaking, roidsPicking = false, false
            if not taking then return end
            VerifyRewardLanded(ROIDS_ITEM, function()
                Say("55FF77", "Auto-ROIDS", "Got R.O.I.D.S.")
            end, function()
                roidsCooldown.mark()
                Say("FFAA55", "Auto-ROIDS", "R.O.I.D.S. never arrived - "
                    .. "probably a copy stashed elsewhere. "
                    .. ("Skipping it for %ds."):format(ROIDS_TTL))
            end)
            return
        end

        if not WT._roidsActiveQuest then return end
        local fs = WT:GetFactionSettings()
        local aq = fs and fs.autoQuest
        if not (aq and aq.roidsEnabled) then return end
        if NpcId() ~= ROIDS_NPC then return end

        if event == "QUEST_DETAIL" then
            if (GetQuestID and GetQuestID() or 0) ~= ROIDS_QUEST then return end
            if AcceptQuest then
                Say("55DDFF", "Auto-ROIDS", "Accepting Rage of Ages.")
                AcceptQuest()
            end
        elseif event == "QUEST_PROGRESS" then
            if IsQuestCompletable and IsQuestCompletable() and CompleteQuest then
                CompleteQuest()
            end
        elseif not roidsPicking then
            roidsPicking = true
            if (GetNumQuestChoices and GetNumQuestChoices() or 0) == 0
                and GetQuestReward then
                roidsTaking = true
                Say("55DDFF", "Auto-ROIDS", "Picking R.O.I.D.S.")
                GetQuestReward()
            end
        end
    end)
end

-- ============================================================
-- SAYGE'S FORTUNE
-- ============================================================
-- Two pages of choices lead to one buff. Which option to click depends on
-- the buff wanted and on how many options the page is showing.
local SAYGE_NPC = "14822"
local SAYGE_PAGE = {
    -- [option count] = { [buff] = option to click }
    [4] = { Damage = 1, Resistance = 1, Armor = 1,
            Intelligence = 2, Spirit = 2,
            Agility = 3, Stamina = 3, Strength = 3 },
    [3] = { Damage = 1, Spirit = 1, Stamina = 1,
            Resistance = 2, Intelligence = 2, Strength = 2,
            Armor = 3, Agility = 3 },
}
local saygeDone = false

local function RunSayge(ag)
    -- The cookie dialog after the buff is pure flavour.
    if saygeDone then
        if ag.dmfSkipCookie then Gossip.Close() end
        return
    end

    local _, class = UnitClass("player")
    local want = (ag.dmfBuffTypes and ag.dmfBuffTypes[class]) or "Damage"

    -- Damage is option one on both pages, so every page can be clicked
    -- as it arrives (each one re-fires GOSSIP_SHOW and lands back here)
    -- instead of firing a barrage of blind timers. The deadline bounds
    -- the run so a conversation that stalls or loops stops being clicked.
    if want == "Damage" then
        local now = GetTime()
        if not WT._fastDmfRunning then
            WT._fastDmfRunning = now + 5        -- deadline for this run
        elseif now >= WT._fastDmfRunning then
            return                              -- ran out; stop clicking
        end
        Gossip.Choose(1)
        return
    end

    local count = Gossip.Count()
    local page = SAYGE_PAGE[count]
    if page then
        if count == 3 then saygeDone = true end
        local pick = page[want]
        if pick then Gossip.Choose(pick) end
    elseif count == 1 then
        Gossip.Choose(1)        -- a transitional "I am ready" page
    end
end

-- ============================================================
-- GOSSIP DISPATCH
-- ============================================================
local TRIBUTE_GUARDS = {
    ["14326"] = true,  -- Mol'dar
    ["14321"] = true,  -- Fengus
    ["14323"] = true,  -- Slip'kik
    ["14353"] = true,  -- Mizzle the Crafty
}
local KOMCRUSH, BWL_ORB = "14325", "179879"
-- Shaman class quests share the orb's gossip; auto-clicking would advance
-- them by mistake.
local ORB_CLASS_QUESTS = { 85556, 85557, 85558 }

local function OnRinwosho(fs, aq)
    if not aq then return end

    -- Turn-in disabled, or nothing to turn in: repairing may still apply.
    if not aq.zanzaEnabled or Bags(ZANZA_TOKEN) < 1 then
        OpenRepairIfNeeded(fs)
        return
    end
    -- Full bags are survivable only when the last token is being spent,
    -- because that empties its slot as the reward lands.
    if not HasGenericBagSpace() and Bags(ZANZA_TOKEN) ~= 1 then
        Say("FFAA55", "Auto-Zanza", "Bags are full - free a slot and "
            .. "re-open the dialog.")
        OpenRepairIfNeeded(fs)
        return
    end
    if not IsOffered(ZANZA_QUEST, "available") then
        OpenRepairIfNeeded(fs)
        return
    end
    if not WT:_AnyZanzaPickable() then
        Say("888888", "Auto-Zanza", "You already have every enabled zanza - "
            .. "drink one and re-open to take a fresh copy.")
        OpenRepairIfNeeded(fs)
        return
    end

    ResetZanzaState()
    WT._zanzaActiveQuest = ZANZA_QUEST
    PickQuest(ZANZA_QUEST, "available")
end

local function OnDrazial(aq)
    if not (aq and aq.roidsEnabled) then return end
    if roidsCooldown.active() then return end
    if Bags(ROIDS_ITEM) > 0 then return end
    for _, r in ipairs(ROIDS_COST) do
        if Bags(r.item) < r.need then return end
    end
    if not RoidsFitsInBags() then
        Say("FFAA55", "Auto-ROIDS", "Bags are full - free a slot and "
            .. "re-open the dialog.")
        return
    end

    ResetRoidsState()
    WT._roidsActiveQuest = ROIDS_QUEST
    -- Already accepted means it is waiting to be completed, not offered.
    local kind = IsOffered(ROIDS_QUEST, "active") and "active" or "available"
    PickQuest(ROIDS_QUEST, kind)
end

function WT:GOSSIP_SHOW()
    -- SHIFT IS THE UNIVERSAL ESCAPE (see the file header): holding it
    -- when the dialog opens skips every automation below.
    if IsShiftKeyDown() then return end
    if not WT.Store() then return end
    local npcID = NpcId()
    if not npcID then return end

    local fs = WT:GetFactionSettings()
    local ag = fs and fs.autoGossip
    if not ag then return end
    local aq = fs.autoQuest

    if ag.dmtEnabled and TRIBUTE_GUARDS[npcID] then
        Gossip.Choose(1)
    elseif ag.dmtEnabled and npcID == KOMCRUSH then
        -- One option means the tribute line; more means he is offering a
        -- quest, which is not ours to click.
        if Gossip.Count() == 1 then Gossip.Choose(1) end
    elseif ag.bwlEnabled and npcID == BWL_ORB then
        if Gossip.Count() == 1 then
            local onClassQuest = false
            if C_QuestLog and C_QuestLog.IsOnQuest then
                for _, qid in ipairs(ORB_CLASS_QUESTS) do
                    if C_QuestLog.IsOnQuest(qid) then onClassQuest = true break end
                end
            end
            if not onClassQuest then Gossip.Choose(1) end
        end
    elseif COLLECTORS[npcID] then
        RunCollector(npcID, COLLECTORS[npcID], aq)
    elseif npcID == RINWOSHO then
        OnRinwosho(fs, aq)
    elseif npcID == ROIDS_NPC then
        OnDrazial(aq)
    elseif ag.dmfEnabled and npcID == SAYGE_NPC then
        RunSayge(ag)
    end
end

do
    local f = CreateFrame("Frame")
    f:RegisterEvent("GOSSIP_SHOW")
    f:RegisterEvent("GOSSIP_CLOSED")
    f:SetScript("OnEvent", function(_, event)
        if event == "GOSSIP_SHOW" then
            WT:GOSSIP_SHOW()
        else
            saygeDone = false
            WT._fastDmfRunning = nil
        end
    end)
end
