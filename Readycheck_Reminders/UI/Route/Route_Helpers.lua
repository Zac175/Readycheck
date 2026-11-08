------------------------------------------------------------------------
-- Readycheck - Raid Route: Shared Helpers
-- Icon/name lookups, gear/trinket source lists, the wing-map builder
-- popup, and the export/import popup, shared via RC._srr with
-- Route_Render.lua. Edits nothing directly except through those popups
-- (RC:SaveConfigurationToProfile / RC.RaidRoute).
-- Route step slot actions use itemId -1 for "Unequip" - a different
-- sentinel from gear sets, which use 0 (see Equip_SetEditor.lua).
------------------------------------------------------------------------
local RCC = _G.Readycheck
local GetItemInfo = GetItemInfo or (RCC and RCC.Compat and RCC.Compat.GetItemInfo)
local RC = _G.Readycheck
if not (RC and RC.UI and RC.CreateSettingsCard) then return end
RC._srr = RC._srr or {}
local _srr = RC._srr
    local TEXT = RC.UI.TEXT or {}
    local T_GOLD   = TEXT.gold    or {1, 0.82, 0}
    local T_NORM   = TEXT.normal  or {0.7, 0.7, 0.7}
    local T_GRAY   = TEXT.gray    or {0.5, 0.5, 0.5}
    local T_WHITE  = TEXT.white   or {1, 1, 1}
    local T_GREEN  = TEXT.green   or {0.5, 1, 0.5}

    local STEP_ICON_KILLS = "Interface\\Icons\\Ability_DualWield"
    local STEP_ICON_PULL  = "Interface\\Icons\\Ability_Warrior_Charge"
    local STEP_ICON_KILL  = "Interface\\Icons\\INV_Misc_Bone_HumanSkull_01"
    local STEP_ICON_WIPE  = "Interface\\Icons\\Ability_Rogue_FeignDeath"
    local ICON_QUESTION   = 134400

    local SLOT_LIST = {
        { 1, "Head" }, { 2, "Neck" }, { 3, "Shoulder" }, { 15, "Back" },
        { 5, "Chest" }, { 9, "Wrist" }, { 10, "Hands" }, { 6, "Waist" },
        { 7, "Legs" }, { 8, "Feet" }, { 11, "Ring 1" }, { 12, "Ring 2" },
        { 16, "Main Hand" }, { 17, "Off Hand" }, { 18, "Ranged" },
    }
    local SLOT_NAME = {}
    for _, e in ipairs(SLOT_LIST) do SLOT_NAME[e[1]] = e[2] end

    -- Maps equip locations to the inventory slot(s) they can fill; shields
    -- and holdables both resolve to the offhand slot (17).
    local EQUIPLOC_SLOTS = {
        INVTYPE_HEAD = {1}, INVTYPE_NECK = {2}, INVTYPE_SHOULDER = {3},
        INVTYPE_CLOAK = {15}, INVTYPE_CHEST = {5}, INVTYPE_ROBE = {5},
        INVTYPE_WRIST = {9}, INVTYPE_HAND = {10}, INVTYPE_WAIST = {6},
        INVTYPE_LEGS = {7}, INVTYPE_FEET = {8}, INVTYPE_FINGER = {11, 12},
        INVTYPE_WEAPON = {16, 17}, INVTYPE_2HWEAPON = {16},
        INVTYPE_WEAPONMAINHAND = {16}, INVTYPE_WEAPONOFFHAND = {17},
        INVTYPE_SHIELD = {17}, INVTYPE_HOLDABLE = {17},
        INVTYPE_RANGED = {18}, INVTYPE_RANGEDRIGHT = {18},
        INVTYPE_THROWN = {18}, INVTYPE_RELIC = {18},
    }

    local function MakeArrowButton(parentF, up, onClick, size)
        size = size or 20
        local b = CreateFrame("Button", nil, parentF)
        b:SetSize(size, size)
        local restColor = RC:GetColor("dropdown", "arrow")
        local tex = b:CreateTexture(nil, "ARTWORK")
        tex:SetSize(math.floor(size * 0.6), math.floor(size * 0.6))
        tex:SetPoint("CENTER")
        tex:SetTexture("Interface\\AddOns\\Readycheck\\Media\\arrow")
        if up then tex:SetTexCoord(0, 1, 1, 0) end
        tex:SetVertexColor(restColor.r, restColor.g, restColor.b, 1)
        b.arrow = tex
        b:SetScript("OnEnter", function()
            local ac = RC:GetColor("ui", "accentGold")
            tex:SetVertexColor(ac.r, ac.g, ac.b, 1)
        end)
        b:SetScript("OnLeave", function()
            local rc = RC:GetColor("dropdown", "arrow")
            tex:SetVertexColor(rc.r, rc.g, rc.b, 1)
        end)
        b:SetScript("OnClick", onClick)
        return b
    end

    -- Framework backed edit box (flat ui.elementBackground, 1px black
    -- ring, gold ring while focused). The focus-lost commit is hooked,
    -- not set, so the helper's own ring-restore handler keeps running.
    local function MakeEditBox(parentF, width, initial, numeric, onCommit)
        local eb = RC.UI:CreateBackedEditBox(parentF, {
            width = width, height = 22, fontSize = 11, fontFlags = "",
            insets = 6, numeric = numeric and true or false,
        })

        eb:SetText(initial or "")
        eb:SetScript("OnEnterPressed", function()
            eb:ClearFocus()
            if onCommit then onCommit(eb:GetText() or "", true, eb) end
        end)
        eb:HookScript("OnEditFocusLost", function()
            if onCommit then onCommit(eb:GetText() or "", false, eb) end
            eb:SetCursorPosition(0)
        end)
        return eb
    end

    local function BossOverrideList(raidName, step)
        if not step or step.type ~= "encounter"
           or not step.boss or step.boss == "" then return {} end
        -- Boss gear swaps live in the raid config, which is the remote
        -- character's while remote editing - the route page shares that data
        -- ("Shared with Raid Config"), so it must resolve the same way.
        local prof = RC:GetEditableActiveProfile(raidName)
        local b = prof and prof.bosses and prof.bosses[step.boss]
        local fe = b and b.forceEquip
        if not fe then return {} end
        local out, seen = {}, {}
        local map = (step.when == "start") and fe.onTarget or fe.onDeath
        if type(map) == "table" then
            for slot, id in pairs(map) do
                if id and id ~= 0 then
                    out[#out + 1] = { slot = slot, id = id }
                    seen[slot] = true
                end
            end
        end
        if step.when ~= "start" then
            if fe.deathSlot1 and not seen[13] then
                out[#out + 1] = { slot = 13, id = fe.deathSlot1 }
            end
            if fe.deathSlot2 and not seen[14] then
                out[#out + 1] = { slot = 14, id = fe.deathSlot2 }
            end
        end
        table.sort(out, function(x, y) return x.slot < y.slot end)
        return out
    end

    local function GetBossGearswap(raidName, bossName, create)
        -- Boss gear swaps live in the raid config, which is the remote
        -- character's while remote editing - the route page shares that data
        -- ("Shared with Raid Config"), so it must resolve the same way.
        -- create: the caller is about to write a set. A boss never opened
        -- on the Raid Config page has no entry yet; without one the pick
        -- used to fall back to the step itself, where nothing reads it, so
        -- the set showed on the route but never went on. The entry is made
        -- the same way the boss page makes it.
        local prof = RC.GetEditableActiveProfile and RC:GetEditableActiveProfile(raidName)
        if not (prof and bossName and bossName ~= "") then return nil end
        prof.bosses = prof.bosses or {}
        local b = prof.bosses[bossName]
        if not b then
            if not create then return nil end
            b = { enabled = false, abilities = {} }
            prof.bosses[bossName] = b
        end
        if not b.abilities then
            if not create then return nil end
            b.abilities = {}
        end
        if not b.abilities.gearswap and create then
            b.abilities.gearswap = { enabled = false, gearSet = "",
                postCombatSet = "", postCombatSwap = false }
        end
        return b.abilities.gearswap
    end

    local function GatherTrashMobs(raidName)
        local names, seen = {}, {}
        local rd = RC.raidData and RC.raidData[raidName]
        if rd and rd.trashSections then
            for _, mobs in pairs(rd.trashSections) do
                for _, m in ipairs(mobs) do
                    if not seen[m] then names[#names + 1] = m; seen[m] = true end
                end
            end
        elseif rd and rd.trash then
            for _, m in ipairs(rd.trash) do
                if not seen[m] then names[#names + 1] = m; seen[m] = true end
            end
        end
        table.sort(names)
        return names
    end

    local function GatherSets()
        local names, seen = {}, {}
        if RC.GearManager and RC.GearManager.sets then
            for sn in pairs(RC.GearManager.sets) do
                if not seen[sn] then names[#names + 1] = sn; seen[sn] = true end
            end
        end
        if RC.db and RC.db.gearSets then
            for sn in pairs(RC.db.gearSets) do
                if not seen[sn] then names[#names + 1] = sn; seen[sn] = true end
            end
        end
        if ItemRackUser and ItemRackUser.Sets then
            for sn in pairs(ItemRackUser.Sets) do
                if not sn:find("^~") and not seen[sn] then
                    names[#names + 1] = sn; seen[sn] = true
                end
            end
        end
        table.sort(names)
        return names
    end

    -- one answer for a set's icon everywhere (Core_Gear)
    local function GetSetIcon(setName)
        return RC:GetGearSetIcon(setName)
    end

    do
        local ROUTE_KW = { "route", "routes", "raid route", "kill order",
                           "route tracker", "warcraft logs" }
        local RID_RAID = { mc = "Molten Core", bwl = "Blackwing Lair",
                           aq40 = "Temple of Ahn'Qiraj", naxx = "Naxxramas" }
        -- another game version's raids (RaidFlavor.lua)
        if RC._raidFlavorApplied then
            RID_RAID = {}
            for _, r in ipairs(RC:FlavorRaids()) do RID_RAID[r.code] = r.name end
        end
        for rid, raidKey in pairs(RID_RAID) do
            RC.UI:RegisterSidebarSearch({
                keywords = ROUTE_KW,
                parentId = rid, tabKey = "route", tabLabel = RCL["Route"],
                after = function(f)
                    f.configState = f.configState or {}
                    f.configState.selectedEncounter = "Route"
                    f.configState.selectedEncounterType = "route"
                    RC:ShowInlineAbilityConfig(f, raidKey, "Route", "route", nil)
                end,
            })
        end
    end

    local UNEQUIP_ICON = "Interface\\Icons\\INV_Misc_Bag_08"

    -- Defined once in Route\RR_Tracker.lua (loads first) and shared here
    -- through RC._rrs.
    local SlotEmptyIcon = (RC._rrs and RC._rrs.SlotEmptyIcon)
        or function() return UNEQUIP_ICON end

    local function ItemIcon(itemId, invSlot)
        -- -1 is this system's UNEQUIP sentinel for a route step's slot
        -- action (gear sets use 0 for the same concept - see
        -- Equip_SetEditor.lua's isUnequip check).
        if itemId == -1 then
            return invSlot and SlotEmptyIcon(invSlot) or UNEQUIP_ICON
        end
        if not itemId or itemId == 0 then return nil end
        local _, _, _, _, _, _, _, _, _, icon = GetItemInfo(itemId)
        return icon
    end

    local function ItemName(itemId)
        if itemId == -1 then return "(Unequip)" end
        if not itemId or itemId == 0 then return "?" end
        return GetItemInfo(itemId) or ("Item " .. itemId)
    end

    local function GatherTrinketItems(configuredId)
        local map = (RC.ScanAllTrinketsInInventory and RC:ScanAllTrinketsInInventory()) or {}
        if configuredId and configuredId ~= 0 and not map[configuredId] then
            map[configuredId] = ItemName(configuredId)
        end
        local list = {}
        for itemId, name in pairs(map) do
            list[#list + 1] = { id = itemId, name = name or ("Item " .. itemId) }
        end
        table.sort(list, function(a, b) return a.name < b.name end)

        local items = { { text = RCL["None"], value = 0 } }
        for _, t in ipairs(list) do
            items[#items + 1] = { text = t.name, value = t.id, icon = ItemIcon(t.id) }
        end
        return items
    end

    local function ItemFitsSlot(itemId, invSlot)
        local _, _, _, _, _, _, _, _, equipLoc = GetItemInfo(itemId)
        local slots = equipLoc and EQUIPLOC_SLOTS[equipLoc]
        if not slots then return false end
        for _, s in ipairs(slots) do
            if s == invSlot then return true end
        end
        return false
    end

    local function SlotEnchantLabel(link, eid, bag, bagSlot)
        if eid == 911 then return "Minor Speed" end
        local lines
        if bag ~= nil then
            lines = RC.Compat.TooltipLines("bagitem", bag, bagSlot)
        elseif link then
            lines = RC.Compat.TooltipLines("hyperlink", link)
        else
            return "Enchant " .. tostring(eid)
        end
        local maxL = math.min(#lines, 12)
        for i = 2, maxL do
            local l = lines[i]
            if l.text ~= "" and l.g and l.g > 0.8
                    and (l.r or 0) < 0.4 and (l.b or 0) < 0.4 then
                return l.text
            end
        end
        for i = 2, maxL do
            local txt = lines[i].text
            if txt and (txt:find("^Enchant") or txt:find("Speed")
                or txt:find("^Minor") or txt:find("^%+%d")) then
                return txt
            end
        end
        return "Enchant " .. tostring(eid)
    end

    local function GatherSlotItems(invSlot, configuredId)
        local seen, list = {}, {}
        local variants = {}
        for bag = 0, 4 do
            local n = C_Container.GetContainerNumSlots(bag) or 0
            for s = 1, n do
                local id = C_Container.GetContainerItemID(bag, s)
                if id and ItemFitsSlot(id, invSlot) then
                    local lk = C_Container.GetContainerItemLink(bag, s)
                    local eid = tonumber((lk and lk:match("item:%d+:(%d*)")) or "") or 0
                    variants[id] = variants[id] or {}
                    if variants[id][eid] == nil then
                        variants[id][eid] = { link = lk, bag = bag, slot = s }
                    end
                end
            end
        end
        for id, vmap in pairs(variants) do
            seen[id] = true
            local cnt = 0
            for _ in pairs(vmap) do cnt = cnt + 1 end
            if cnt <= 1 then
                list[#list + 1] = { id = id, name = ItemName(id) }
            else
                for eid, loc in pairs(vmap) do
                    local base = ItemName(id)
                    local sub = (eid ~= 0) and SlotEnchantLabel(loc.link,
                        eid, loc.bag, loc.slot) or nil
                    list[#list + 1] = { id = id, ench = eid, name = base,
                        sub = sub }
                end
            end
        end
        local eq = GetInventoryItemID("player", invSlot)
        if eq and not seen[eq] then
            seen[eq] = true
            list[#list + 1] = { id = eq, name = ItemName(eq) }
        end
        if configuredId and configuredId ~= 0 and not seen[configuredId] then
            list[#list + 1] = { id = configuredId, name = ItemName(configuredId) }
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        local items = {
            { text = RCL["(Unequip - leave slot empty)"], value = -1, icon = UNEQUIP_ICON },
        }
        for _, t in ipairs(list) do
            items[#items + 1] = { text = t.name, subText = t.sub,
                value = (t.ench ~= nil) and (t.id .. ":" .. t.ench) or t.id,
                icon = ItemIcon(t.id) }
        end
        return items
    end

    local CHECKER_ORDER = { "flasks", "elixirs", "food", "drinks", "potions",
        "protectionPotions", "buffs", "utilities", "classItems", "reagents",
        "chronoboon", "special" }

    -- The route's item reminders: a Target Dummy (whichever one is in the
    -- bags when it fires), then what you are carrying. `all` lists every
    -- catalog item (editing someone else's route: their bags are unknown).
    local function GatherReminderItems(filter, all)
        local cats
        if filter == "potion" then
            cats = { "potions", "protectionPotions" }
        elseif filter == "engi" then
            cats = { "utilities" }
        else
            cats = CHECKER_ORDER
        end
        local engiIds = {}
        for id, data in pairs(RC.utilityItems or {}) do
            if type(id) == "number" and type(data) == "table" and not data.isStone then
                engiIds[id] = true
            end
        end
        local items = { { text = RCL["Pick a reminder..."], value = 0 } }
        if filter ~= "potion" then
            items[#items + 1] = { text = RCL["Target Dummy"], value = "dummy",
                icon = RC.TARGET_DUMMY_ICON }
        end
        local rc = RC.raidConsumables or {}
        local seen = {}
        for _, catKey in ipairs(cats) do
            local cat = rc[catKey]
            if cat and cat.items then
                local list = {}
                for itemId, data in pairs(cat.items) do
                    local synthetic = type(data) == "table"
                        and (data.baseItemId ~= nil or data.slot ~= nil)
                    local ok = not synthetic and not seen[itemId]
                        and not RC:IsTargetDummy(itemId)
                        and (all or RC:CarriesItem(itemId, data))
                    if ok and filter == "engi" then
                        ok = engiIds[itemId] == true
                    end
                    if ok then
                        seen[itemId] = true
                        list[#list + 1] = { id = itemId,
                            name = RC:ItemLabel(itemId, type(data) == "table" and data or nil) }
                    end
                end
                table.sort(list, function(a, b) return (a.name or "") < (b.name or "") end)
                for _, t in ipairs(list) do
                    items[#items + 1] = { text = t.name or ("Item " .. tostring(t.id)),
                        value = t.id, icon = ItemIcon(t.id) }
                end
            end
        end
        if #items == ((filter ~= "potion") and 2 or 1) then
            items[#items + 1] = { text = RCL["Nothing else in your bags"], value = 0 }
        end
        return items
    end

    local function CopyStep(s)
        local n = {
            type = s.type, mob = s.mob, kills = s.kills,
            boss = s.boss, when = s.when, desc = s.desc,
            enabled = s.enabled, actions = {},
        }
        if s.mobs then
            n.mobs = {}
            for _, e in ipairs(s.mobs) do
                n.mobs[#n.mobs + 1] = { mob = e.mob, kills = e.kills }
            end
        end
        local a, na = s.actions or {}, n.actions
        na.gearSet = a.gearSet
        na.trinket1 = a.trinket1
        na.trinket2 = a.trinket2
        na.reminderText = a.reminderText
        na.reminderIcon = a.reminderIcon
        na.reminderItemId = a.reminderItemId
        na.tts = a.tts
        if a.reminders then
            na.reminders = {}
            for _, r in ipairs(a.reminders) do
                na.reminders[#na.reminders + 1] = {
                    text = r.text, icon = r.icon, itemId = r.itemId, tts = r.tts,
                }
            end
        end
        if a.slots then
            na.slots = {}
            for k, v in pairs(a.slots) do na.slots[k] = v end
        end
        return n
    end

    local function StepSummary(step)
        if step.desc and step.desc ~= "" then return step.desc end
        if step.type == "encounter" then
            local verb = "Boss pull: "
            if step.when == "end" then verb = "Boss kill: " end
            if step.when == "wipe" then verb = "On wipe: " end
            return verb .. ((step.boss ~= "" and step.boss) or "(pick a boss)")
        end
        if step.mobs and #step.mobs > 0 then
            local parts = {}
            for _, r in ipairs(step.mobs) do
                parts[#parts + 1] = (r.kills or 1) .. "x " .. (r.mob or "?")
            end
            return "Kill " .. table.concat(parts, " + ")
        end
        local mob = (step.mob and step.mob ~= "" and step.mob) or "(pick a mob)"
        return "Kill " .. (step.kills or 1) .. "x " .. mob
    end

    local function StepIcon(step)
        if step.type == "encounter" then
            if step.when == "end" then return STEP_ICON_KILL end
            if step.when == "wipe" then return STEP_ICON_WIPE end
            return STEP_ICON_PULL
        end
        return STEP_ICON_KILLS
    end

    local _routeSharePopup
    local function ShowRouteSharePopup(mode, raidName, afterImport)
        -- Importing goes through the one import window. It knows which
        -- route page it was opened from, so a pasted route lands on THIS
        -- raid as it always has; anything else pasted here is named and
        -- imported as what it is.
        if mode ~= "export" and RC.ShowUniversalImport then
            RC:ShowUniversalImport({ from = "route", raidName = raidName,
                title = RCL["Import - "] .. raidName,
                -- a raid profile pasted here swaps the route out from
                -- under this page just as a route does
                onDone = function(res)
                    if afterImport and res and (res.kind == "route" or res.kind == "raidProfile") then
                        afterImport()
                    end
                end })
            return
        end
        if not _routeSharePopup then
            local bgC  = RC:GetColor("ui", "windowBackground")
            local ac   = RC:GetColor("ui", "accentGold")
            local hdrBg = RC:GetColor("ui", "headerBackground")
            local hdrTx = RC:GetColor("ui", "headerText")
            local bk   = RC:GetColor("ui", "borderNormal")
            local pop = CreateFrame("Frame", "WRRouteSharePopup", UIParent, "BackdropTemplate")
            pop:SetSize(480, 266)
            pop:SetFrameStrata("DIALOG")
            pop:SetFrameLevel(150)
            pop:SetClampedToScreen(true)
            pop:SetMovable(true)
            pop:RegisterForDrag("LeftButton")
            pop:SetScript("OnDragStart", function(s) s:StartMoving() end)
            pop:SetScript("OnDragStop",  function(s) s:StopMovingOrSizing() end)
            if RC.UI.RegisterEscapeClose then RC.UI:RegisterEscapeClose(pop) end
            -- Window shell: flat windowBackground, 1px black ring, 30px flat
            -- title bar with a gold rule, 15px gold title, chromeless X.
            pop:SetBackdrop({bgFile=RC.UI.FLAT, edgeFile=RC.UI.FLAT, edgeSize=1})
            pop:SetBackdropColor(bgC.r, bgC.g, bgC.b, 0.97)
            pop:SetBackdropBorderColor(bk.r, bk.g, bk.b, bk.a or 1)
            pop:SetPoint("CENTER")
            pop:SetToplevel(true)

            local titleBar = CreateFrame("Frame", nil, pop)
            titleBar:SetHeight(30)
            titleBar:SetPoint("TOPLEFT",  pop, "TOPLEFT",  1, -1)
            titleBar:SetPoint("TOPRIGHT", pop, "TOPRIGHT", -1, -1)
            local titleFill = titleBar:CreateTexture(nil, "BACKGROUND")
            titleFill:SetAllPoints()
            titleFill:SetTexture(RC.UI.FLAT)
            titleFill:SetVertexColor(hdrBg.r, hdrBg.g, hdrBg.b, hdrBg.a or 1)
            local titleRule = titleBar:CreateTexture(nil, "ARTWORK")
            titleRule:SetPoint("BOTTOMLEFT",  titleBar, "BOTTOMLEFT",  0, 0)
            titleRule:SetPoint("BOTTOMRIGHT", titleBar, "BOTTOMRIGHT", 0, 0)
            titleRule:SetHeight(1)
            titleRule:SetTexture(RC.UI.FLAT)
            titleRule:SetVertexColor(ac.r, ac.g, ac.b, 0.6)
            pop.titleBar = titleBar
            if RC.UI.ApplyHeaderArt then
                titleRule:Hide()
                RC.UI:ApplyHeaderArt(titleBar, { fill = titleFill, stepX = 160 })
            end

            local titleIcon = RC.UI:AddTitleIcon(titleBar, 16, 8)

            local titleLabel = RC:CreateFontString(titleBar, "OVERLAY", nil, 15, "OUTLINE")
            titleLabel:SetPoint("LEFT", titleIcon, "RIGHT", 8, 0)
            titleLabel:SetTextColor(hdrTx.r, hdrTx.g, hdrTx.b, 1)
            pop.titleLabel = titleLabel

            local closeX = RC.UI:CreateXCloseButton(titleBar, 22, function() RC.UI:PopOut(pop, 0.1) end)
            closeX:SetPoint("RIGHT", titleBar, "RIGHT", -5, 0)

            local descLabel = RC:CreateFontString(pop, "OVERLAY", nil, 10, "NONE")
            descLabel:SetPoint("TOPLEFT", pop, "TOPLEFT", 10, -38)
            do local _c = RC:GetColor("text", "gray"); descLabel:SetTextColor(_c.r, _c.g, _c.b, _c.a) end
            pop.descLabel = descLabel

            -- Framework scrollable text box (flat fill, 1px ring, themed
            -- scrollbar) in place of the UIPanelScrollFrameTemplate box.
            local taCon = RC.UI:CreateStyledEditBox(pop, {
                multiLine = true, scrollable = true, scrollHeight = 160, font = 10,
            })
            taCon:SetPoint("TOPLEFT",     pop, "TOPLEFT",     10, -58)
            taCon:SetPoint("BOTTOMRIGHT", pop, "BOTTOMRIGHT", -10, 38)
            pop.taEB = taCon.editBox

            local actionBtn = RC.UI:CreateStyledButton(pop, RCL["Import"], 90, 24)
            actionBtn:SetPoint("BOTTOMRIGHT", pop, "BOTTOMRIGHT", -10, 6)
            actionBtn:SetActive(true)
            pop.actionBtn = actionBtn
            -- the 5.0 popup look (UIF_Dialogs)
            RC.UI:SkinPopup(pop, { header = titleBar, title = titleLabel, close = closeX,
                dims = { descLabel }, primary = actionBtn })
            _routeSharePopup = pop
        end

        local pop = _routeSharePopup
        RC.UI:PopIn(pop, 0.12)
        pop:Raise()
        if mode == "export" then
            pop.titleLabel:SetText(RCL["Export Route - "] .. raidName)
            pop.descLabel:SetText(RCL["Copy the text below. Anyone can import it on their Route page."])
            local str = RC.RaidRoute and RC.RaidRoute:ExportRouteString(raidName)
            pop.taEB:SetText(str or RCL["(this raid's route has no steps)"])
            pop.actionBtn:Hide()
            pop.taEB:HighlightText()
            pop.taEB:SetFocus()
        else
            pop.titleLabel:SetText(RCL["Import Route - "] .. raidName)
            pop.descLabel:SetText(RCL["Paste a route export string, then click Import. Replaces this raid's route."])
            pop.taEB:SetText("")
            pop.actionBtn:Show()
            RC.UI:SetButtonText(pop.actionBtn, "Import")
            pop.actionBtn:SetScript("OnClick", function()
                local ok, err = RC.RaidRoute:ImportRouteString(raidName, pop.taEB:GetText() or "")
                if ok then
                    RC:SaveConfigurationToProfile()
                    RC:Print(RCL["Route imported for "] .. raidName .. ".")
                    RC.UI:PopOut(pop, 0.1)
                    if afterImport then afterImport() end
                else
                    RC:Print(RCL["Route import failed: "] .. tostring(err))
                end
            end)
            pop.taEB:SetFocus()
        end
    end

    _srr.BossOverrideList = BossOverrideList
    _srr.CopyStep = CopyStep
    _srr.GatherReminderItems = GatherReminderItems
    _srr.GatherSets = GatherSets
    _srr.GatherSlotItems = GatherSlotItems
    _srr.GatherTrashMobs = GatherTrashMobs
    _srr.GatherTrinketItems = GatherTrinketItems
    _srr.GetBossGearswap = GetBossGearswap
    _srr.GetSetIcon = GetSetIcon
    _srr.ICON_QUESTION = ICON_QUESTION
    _srr.ItemIcon = ItemIcon
    _srr.ItemName = ItemName
    _srr.MakeArrowButton = MakeArrowButton
    _srr.MakeEditBox = MakeEditBox
    _srr.SLOT_LIST = SLOT_LIST
    _srr.SLOT_NAME = SLOT_NAME
    _srr.ShowRouteSharePopup = ShowRouteSharePopup
    _srr.SlotEnchantLabel = SlotEnchantLabel
    _srr.StepIcon = StepIcon
    _srr.StepSummary = StepSummary
    _srr.T_GOLD = T_GOLD
    _srr.T_GRAY = T_GRAY
    _srr.T_GREEN = T_GREEN
    _srr.T_NORM = T_NORM
    _srr.T_WHITE = T_WHITE
