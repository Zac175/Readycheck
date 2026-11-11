------------------------------------------------------------------------
-- Readycheck - Custom Reminders
-- Sidebar rule-builder: trigger modes (aura/cooldown/health/resource/
-- equipment/status/event/condition/periodic/sequence/lua), extra AND
-- conditions, load conditions, drag-to-reorder list, and a test tab.
-- Edits RC.db.customReminders.reminders in place; mutations call
-- RC:SaveConfigurationToProfile() then re-render via
-- RC:ShowSidebarCustomReminders()/RC:CR_RenderTab().
------------------------------------------------------------------------
-- This file builds UI only - it reads no Blizzard unit/spell APIs itself,
-- so it carries no RC.Compat taint-safe locals. (The Lua-mode hint text
-- mentions UnitBuff/GetSpellCooldown, but that is a string for the user's
-- own snippets, not a call from here.)

local AddonName = "Readycheck"
local RC = _G[AddonName]

local LIST_W = 210
local PAD    = 8
local ROW_H  = 28
local TAB_H  = 26
local DDROP_W = 220
local NBOX_W  = 90
local LBL_W   = 110

-- Fallback content width used by DropAt() when no explicit width is given.
-- Kept in sync by ShowSidebarCustomReminders/CR_OpenEditor/CR_RenderTab
-- before they build any rows that call DropAt without a width argument.
local _EW = 400

local UNIT_ITEMS = {
    {text=RCL["Player"],value="player"},{text=RCL["Target"],value="target"},{text=RCL["Focus"],value="focus"},
    {text=RCL["Pet"],value="pet"},{text=RCL["Mouseover"],value="mouseover"},
    {text=RCL["Party 1"],value="party1"},{text=RCL["Party 2"],value="party2"},
    {text=RCL["Party 3"],value="party3"},{text=RCL["Party 4"],value="party4"},
    {text=RCL["Raid 1"],value="raid1"},{text=RCL["Raid 2"],value="raid2"},
    {text=RCL["Raid 3"],value="raid3"},{text=RCL["Raid 4"],value="raid4"},{text=RCL["Raid 5"],value="raid5"},
    {text=RCL["Boss 1"],value="boss1"},{text=RCL["Boss 2"],value="boss2"},
    {text=RCL["Boss 3"],value="boss3"},{text=RCL["Boss 4"],value="boss4"},
}
local MODE_ITEMS = {
    {text=RCL["Aura - buff / debuff"],         value="aura"},
    {text=RCL["Cooldown - spell or item"],     value="cooldown"},
    {text=RCL["Health - HP threshold"],        value="health"},
    {text=RCL["Resource - power/mana/rage"],   value="resource"},
    {text=RCL["Equipment - item / enchant / stat"], value="equipment"},
    {text=RCL["Status - combat/group/zone"],   value="status"},
    {text=RCL["Event - combat log reaction"],  value="event"},
    {text=RCL["Conditions - AND chain"],       value="condition"},
    {text=RCL["Periodic - every N seconds"],   value="periodic"},
    {text=RCL["Sequence - ordered steps"],     value="sequence"},
    {text=RCL["Lua - custom code"],            value="lua"},
}
local BUFF_TYPE_ITEMS = {{text=RCL["Buff"],value="buff"},{text=RCL["Debuff"],value="debuff"}}
local AURA_COND_ITEMS = {
    {text=RCL["Missing (show while missing)"],       value="missing"},
    {text=RCL["Active / present"],                   value="active"},
    {text=RCL["Expiring - < N sec remaining"],       value="expiring"},
    {text=RCL["Stacks >= N"],                        value="stacks_above"},
    {text=RCL["Stacks < N"],                         value="stacks_below"},
}
local AURA_UNTRIG_ITEMS = {
    {text=RCL["Auto (opposite of trigger)"],         value="auto"},
    {text=RCL["Never (show for full duration)"],     value="never"},
    {text=RCL["Custom condition"],                   value="custom"},
}
local CD_COND_ITEMS = {
    {text=RCL["Ready (off cooldown)"],               value="ready"},
    {text=RCL["On cooldown"],                        value="active"},
    {text=RCL["Below N sec remaining"],              value="below_n_sec"},
    {text=RCL["Above N sec remaining"],              value="above_n_sec"},
}
local OP_ITEMS = {
    {text=RCL["<  (less than)"],   value="<"},
    {text=RCL[">  (greater than)"],value=">"},
    {text=RCL["<= (at most)"],     value="<="},
    {text=RCL[">= (at least)"],    value=">="},
}
local POWER_ITEMS = {
    {text=RCL["Mana"],value="0"},{text=RCL["Rage"],value="1"},
    {text=RCL["Focus"],value="2"},{text=RCL["Energy"],value="3"},{text=RCL["Combo Points"],value="4"},
}
local STATUS_ITEMS = {
    {text=RCL["In combat"],value="in_combat"},{text=RCL["Out of combat"],value="out_of_combat"},
    {text=RCL["In raid"],value="in_raid"},{text=RCL["In party"],value="in_party"},
    {text=RCL["Solo (no group)"],value="solo"},{text=RCL["In instance"],value="in_instance"},
    {text=RCL["Resting"],value="resting"},{text=RCL["Mounted"],value="mounted"},
    {text=RCL["Target exists"],value="target_exists"},{text=RCL["Target is boss"],value="target_is_boss"},
    {text=RCL["PvP flagged"],value="pvp_flagged"},{text=RCL["Dead"],value="dead"},
}
local COND_TYPE_ITEMS = {
    {text=RCL["Buff missing"],                   value="buff_missing"},
    {text=RCL["Buff active"],                    value="buff_active"},
    {text=RCL["Buff expiring < N sec"],          value="buff_expiring"},
    {text=RCL["Debuff active (on unit)"],        value="debuff_active"},
    {text=RCL["Debuff missing (on unit)"],       value="debuff_missing"},
    {text=RCL["Cooldown ready"],                 value="cooldown_ready"},
    {text=RCL["Cooldown active"],                value="cooldown_active"},
    {text=RCL["Two cooldowns synced (both ready)"], value="cooldowns_synced"},
    {text=RCL["Spell is usable now"],            value="spell_usable"},
    {text=RCL["Spell is NOT usable"],            value="spell_not_usable"},
    {text=RCL["Unit HP% below N"],               value="hp_below"},
    {text=RCL["Unit HP% above N"],               value="hp_above"},
    {text=RCL["Player has full HP"],             value="has_full_hp"},
    {text=RCL["Power/Mana above N"],             value="power_above"},
    {text=RCL["Power/Mana below N"],             value="power_below"},
    {text=RCL["Has at least N mana"],            value="has_mana"},
    {text=RCL["Unit is casting (any spell)"],    value="casting"},
    {text=RCL["Unit is NOT casting"],            value="not_casting"},
    {text=RCL["Target casting (by name)"],       value="target_casting_spell"},
    {text=RCL["Target cast is interruptible"],   value="target_casting_interruptible"},
    {text=RCL["Stance is (warrior)"],            value="stance_is"},
    {text=RCL["No active stance"],               value="not_in_stance"},
    {text=RCL["Item in bag: count < N"],         value="item_count_below"},
    {text=RCL["Item equipped in slot"],          value="item_equipped"},
    {text=RCL["Item NOT equipped in slot"],      value="item_not_equipped"},
    {text=RCL["Unit in spell range"],            value="unit_in_range"},
    {text=RCL["Unit NOT in spell range"],        value="unit_not_in_range"},
    {text=RCL["Target exists and alive"],        value="unit_exists"},
    {text=RCL["Target is a player"],             value="target_is_player"},
    {text=RCL["Target is an NPC"],               value="target_is_npc"},
    {text=RCL["Target is elite / boss"],         value="target_is_elite"},
    {text=RCL["Target is a world boss"],         value="target_is_boss"},
    {text=RCL["Target level above N"],           value="target_level_above"},
    {text=RCL["Target level below N"],           value="target_level_below"},
    {text=RCL["In combat"],                      value="in_combat"},
    {text=RCL["Out of combat"],                  value="out_of_combat"},
    {text=RCL["In raid group"],                  value="in_raid"},
    {text=RCL["In any group"],                   value="in_group"},
    {text=RCL["In an instance"],                 value="in_instance"},
    {text=RCL["Player is moving"],               value="is_moving"},
    {text=RCL["Any party member HP% below N"],   value="party_member_hp_below"},
    {text=RCL["All party members alive"],        value="all_party_alive"},
    {text=RCL["Someone in group is dead"],       value="someone_dead"},
    {text=RCL["Fight duration > N sec"],         value="fight_duration_above"},
    {text=RCL["Fight duration < N sec"],         value="fight_duration_below"},
    {text=RCL["TTK estimate < N sec"],           value="ttk_below"},
    {text=RCL["TTK estimate > N sec"],           value="ttk_above"},
    {text=RCL["Pace is slow by > N%"],           value="ttk_pace_slow"},
    {text=RCL["Pace is fast by > N%"],           value="ttk_pace_fast"},
    {text=RCL["No potion used this fight"],      value="potion_not_used"},
    {text=RCL["Weapon has temp enchant"],        value="weapon_has_enchant"},
    {text=RCL["Weapon MISSING temp enchant"],    value="weapon_no_enchant"},
    {text=RCL["Attack Power above N"],           value="stat_ap_above"},
    {text=RCL["Attack Power below N"],           value="stat_ap_below"},
    {text=RCL["Crit % above N"],                 value="stat_crit_above"},
    {text=RCL["Crit % below N"],                 value="stat_crit_below"},
    {text=RCL["Hit above N"],                    value="stat_hit_above"},
    {text=RCL["Hit below N"],                    value="stat_hit_below"},
    {text=RCL["Target cast remaining < N sec"],  value="target_cast_remaining_below"},
    {text=RCL["Target cast remaining > N sec"],  value="target_cast_remaining_above"},
    {text=RCL["GCD active"],                     value="gcd_active"},
    {text=RCL["GCD not active"],                 value="gcd_not_active"},
    {text=RCL["Spec is (WR detected)"],          value="spec_is"},
}

local COND_META = {
    buff_missing      = {needsUnit=true,  needsSpellId=true},
    buff_active       = {needsUnit=true,  needsSpellId=true},
    buff_expiring     = {needsUnit=true,  needsSpellId=true, needsValue=true,  valueLabel=RCL["< N sec"]},
    debuff_active     = {needsUnit=true,  needsSpellId=true},
    debuff_missing    = {needsUnit=true,  needsSpellId=true},
    cooldown_ready    = {needsSpellId=true},
    cooldown_active   = {needsSpellId=true},
    cooldowns_synced  = {needsSpellId=true, needsSpellId2=true},
    spell_usable      = {needsSpellId=true},
    spell_not_usable  = {needsSpellId=true},
    hp_below          = {needsUnit=true,  needsValue=true,   valueLabel="HP%"},
    hp_above          = {needsUnit=true,  needsValue=true,   valueLabel="HP%"},
    has_full_hp       = {},
    power_above       = {needsUnit=true,  needsValue=true,   valueLabel=RCL["Amount"]},
    power_below       = {needsUnit=true,  needsValue=true,   valueLabel=RCL["Amount"]},
    has_mana          = {needsValue=true, valueLabel=RCL["Mana amount"]},
    casting           = {needsUnit=true,  needsSpellName=true},
    not_casting       = {needsUnit=true},
    target_casting_spell = {needsSpellName=true},
    target_casting_interruptible = {},
    stance_is         = {needsStance=true},
    not_in_stance     = {},
    item_count_below  = {needsItemId=true, needsValue=true,  valueLabel=RCL["Below N"]},
    item_equipped     = {needsSlot=true,  needsItemId=true},
    item_not_equipped = {needsSlot=true,  needsItemId=true},
    unit_in_range     = {needsUnit=true,  needsSpellName=true},
    unit_not_in_range = {needsUnit=true,  needsSpellName=true},
    unit_exists       = {needsUnit=true},
    target_is_player  = {},
    target_is_npc     = {},
    target_is_elite   = {},
    target_is_boss    = {},
    target_level_above= {needsValue=true, valueLabel=RCL["Level"]},
    target_level_below= {needsValue=true, valueLabel=RCL["Level"]},
    in_combat         = {},
    out_of_combat     = {},
    in_raid           = {},
    in_group          = {},
    in_instance       = {},
    is_moving         = {},
    party_member_hp_below = {needsValue=true, valueLabel="HP%"},
    all_party_alive   = {},
    someone_dead      = {},
    fight_duration_above = {needsValue=true, valueLabel=RCL["Seconds"]},
    fight_duration_below = {needsValue=true, valueLabel=RCL["Seconds"]},
    ttk_below         = {needsValue=true, valueLabel=RCL["Seconds"]},
    ttk_above         = {needsValue=true, valueLabel=RCL["Seconds"]},
    ttk_pace_slow     = {needsValue=true, valueLabel=RCL["% slower"]},
    ttk_pace_fast     = {needsValue=true, valueLabel=RCL["% faster"]},
    potion_not_used   = {},
    spec_is           = {needsSpec=true},
    weapon_has_enchant= {needsSlot=true},
    weapon_no_enchant = {needsSlot=true},
    stat_ap_above     = {needsValue=true, valueLabel=RCL["AP amount"]},
    stat_ap_below     = {needsValue=true, valueLabel=RCL["AP amount"]},
    stat_crit_above   = {needsValue=true, valueLabel=RCL["Crit %"]},
    stat_crit_below   = {needsValue=true, valueLabel=RCL["Crit %"]},
    stat_hit_above    = {needsValue=true, valueLabel=RCL["Hit rating"]},
    stat_hit_below    = {needsValue=true, valueLabel=RCL["Hit rating"]},
    target_cast_remaining_below = {needsValue=true, valueLabel=RCL["< N sec"]},
    target_cast_remaining_above = {needsValue=true, valueLabel=RCL["> N sec"]},
    gcd_active        = {},
    gcd_not_active    = {},
}

local SLOT_ITEMS = {
    {text=RCL["Head (1)"],       value="1"},  {text=RCL["Neck (2)"],      value="2"},
    {text=RCL["Shoulder (3)"],   value="3"},  {text=RCL["Chest (5)"],     value="5"},
    {text=RCL["Waist (6)"],      value="6"},  {text=RCL["Legs (7)"],      value="7"},
    {text=RCL["Feet (8)"],       value="8"},  {text=RCL["Wrist (9)"],     value="9"},
    {text=RCL["Hands (10)"],     value="10"}, {text=RCL["Ring 1 (11)"],   value="11"},
    {text=RCL["Ring 2 (12)"],    value="12"}, {text=RCL["Trinket 1 (13)"],value="13"},
    {text=RCL["Trinket 2 (14)"], value="14"}, {text=RCL["Back (15)"],     value="15"},
    {text=RCL["Main Hand (16)"], value="16"}, {text=RCL["Off Hand (17)"], value="17"},
    {text=RCL["Ranged (18)"],    value="18"},
}
local STANCE_ITEMS = {
    {text=RCL["No stance (0)"],       value="0"},
    {text=RCL["Battle Stance (1)"],   value="1"},
    {text=RCL["Defensive Stance (2)"],value="2"},
    {text=RCL["Berserker Stance (3)"],value="3"},
}
local SPEC_ITEMS = {
    {text=RCL["Any / N/A"],  value=""},
    {text=RCL["Fury"],       value="fury"},
    {text=RCL["Arms"],       value="arms"},
    {text=RCL["Protection"], value="prot"},
    {text=RCL["Fury/Prot"],  value="furyProt"},
}
local STEP_TYPE_ITEMS = {
    {text=RCL["On combat start"],          value="on_combat_start"},
    {text=RCL["Timer (N sec after prev)"], value="timer"},
    {text=RCL["Condition triggers"],       value="condition"},
}
local SCOPE_ITEMS = {
    {text=RCL["Anywhere"],           value="any"},
    {text=RCL["Any raid"],           value="raid"},
    {text=RCL["Boss fight"],         value="boss"},
    {text=RCL["Trash only"],         value="trash"},
}
local GROUP_ITEMS = {
    {text=RCL["Any"],value=""},{text=RCL["Solo"],value="solo"},
    {text=RCL["Party"],value="party"},{text=RCL["Raid"],value="raid"},
}
local ZONE_ITEMS = {
    {text=RCL["Any zone"],value=""},{text=RCL["Open world"],value="world"},
    {text=RCL["Any instance"],value="instance"},{text=RCL["Raid instance"],value="raid"},
    {text=RCL["Party dungeon"],value="party"},{text=RCL["PvP / Arena"],value="pvp"},
}
local CLASS_ITEMS = {
    {text=RCL["Any class"],value=""},
    {text=RCL["Druid"],value="DRUID"},{text=RCL["Hunter"],value="HUNTER"},
    {text=RCL["Mage"],value="MAGE"},{text=RCL["Paladin"],value="PALADIN"},
    {text=RCL["Priest"],value="PRIEST"},{text=RCL["Rogue"],value="ROGUE"},
    {text=RCL["Shaman"],value="SHAMAN"},{text=RCL["Warlock"],value="WARLOCK"},
    {text=RCL["Warrior"],value="WARRIOR"},
}
local CLASS_SPECS = {
    WARRIOR = {
        {text=RCL["Any"],value=""},{text=RCL["Fury"],value="fury"},
        {text=RCL["Arms"],value="arms"},{text=RCL["Prot"],value="prot"},{text=RCL["Fury/Prot"],value="furyProt"},
    },
}
local SPEC_ANY_ITEMS = {{text=RCL["Any (or N/A for non-warriors)"],value=""}}

local MODE_COLORS = {
    aura={0.4,0.8,1},cooldown={1,0.7,0.2},health={1,0.4,0.4},
    resource={0.6,0.9,0.4},status={0.8,0.6,1},event={1,0.6,0.6},
    condition={1,0.8,0.4},sequence={0.5,1,0.5},lua={1,0.5,0.9},
}

-- Module-level state; the whole scrollChild is torn down and rebuilt on
-- every ShowSidebarCustomReminders() call, so selection/tab/drag state
-- has to live outside the frame hierarchy to survive a re-render.
local CR_Editor={selectedId=nil,activeTab="general",tabContent=nil}
local CR_Drag={active=false,from=nil,to=nil,rows={},lp=nil,frame=nil}

-- Custom drag-to-reorder: WoW frames have no built-in reorder-by-drag for
-- an arbitrary row list, so this polls cursor position every frame while
-- CR_Drag.active is true and derives a target "slot" from row tops.
local _DragFrame
local function EnsureDragFrame()
    if _DragFrame then return end
    _DragFrame = CreateFrame("Frame", "WRCRDragFramePoll", UIParent)
    _DragFrame:Hide()
    _DragFrame:SetScript("OnUpdate", function(self)
        if not (RC and RC.db and CR_Drag.active) then
            local ind = _G["WRCRDragIndicator"]
            if ind then ind:Hide() end
            self:Hide()
            return
        end
        local mouseDown = IsMouseButtonDown("LeftButton")
        local rows    = CR_Drag.rows
        local numRows = rows and #rows or 0
        local _, cy   = GetCursorPosition()
        local scale   = UIParent:GetEffectiveScale()
        if numRows > 0 and scale and scale > 0 then
            local cursorY = cy / scale
            local slot    = numRows + 1
            for i = 1, numRows do
                local rf   = rows[i]
                local rTop = rf and rf:GetTop()
                -- -13 ~= half of a 26px row; cursor above the row's midline
                -- snaps the drop target to this row instead of the next.
                if rTop and cursorY >= rTop - 13 then
                    slot = i
                    break
                end
            end
            CR_Drag.to = slot
            if mouseDown then
                local lp  = CR_Drag.lp
                local ind = _G["WRCRDragIndicator"]
                if lp and ind then
                    local lpL = lp:GetLeft()
                    local lpR = lp:GetRight()
                    if lpL and lpR then
                        local anchorRow  = rows[math.min(slot, numRows)]
                        local rTop       = anchorRow and anchorRow:GetTop()
                        if rTop then
                            -- -26 drops the indicator below the last row (row
                            -- height) when the target slot is past the end.
                            local indicatorY = (slot > numRows) and (rTop - 26) or rTop
                            ind:ClearAllPoints()
                            ind:SetPoint("BOTTOMLEFT",  UIParent, "BOTTOMLEFT", lpL, indicatorY)
                            ind:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMLEFT", lpR, indicatorY)
                            ind:Show()
                        end
                    end
                end
            end
        end
        -- Mouse-up-anywhere fallback: commits the reorder into
        -- RC.db.customReminders.reminders even if the button-level
        -- grip:OnMouseUp below never fires for this release.
        if not mouseDown then
            local ind = _G["WRCRDragIndicator"]
            if ind then ind:Hide() end
            if CR_Drag.active then
                local from = CR_Drag.from
                local to   = CR_Drag.to
                if from and to and to ~= from then
                    local db = RC.db and RC.db.customReminders and RC.db.customReminders.reminders
                    if db and from >= 1 and from <= #db then
                        local item     = table.remove(db, from)
                        local insertAt = (from < to) and (to - 1) or to
                        insertAt = math.max(1, math.min(#db + 1, insertAt))
                        if item then table.insert(db, insertAt, item) end
                        RC:SaveConfigurationToProfile()
                    end
                end
                CR_Drag.active = false
                local f = CR_Drag.frame
                if f then RC:ShowSidebarCustomReminders(f) end
            end
        end
    end)
end

local function MakeFS(parent,size,outline)
    local fs=parent:CreateFontString(nil,"OVERLAY")
    if RC.ApplyCustomFont then RC:ApplyCustomFont(fs,size or 11,outline or "OUTLINE") end
    if RC.trackedFonts then table.insert(RC.trackedFonts,fs) end
    return fs
end
local function Btn(parent,text,w,h) return RC.UI:CreateStyledButton(parent,text,w or 80,h or 22) end
-- Framework backed edit box: flat ui.elementBackground fill, 1px black
-- ring, gold ring while focused. eb.box keeps the old alias to the
-- backing frame (eb.bg) for anyone who reads it.
local function Input(parent,w,h)
    local eb=RC.UI:CreateBackedEditBox(parent,{width=w or 80,height=h or 20,fontSize=10,fontFlags="",insets=4})
    eb.box=eb.bg
    return eb
end

local function Row(parent,y,label,widget,dropW,labelW)
    labelW=labelW or 110; dropW=dropW or DDROP_W
    local lbl=MakeFS(parent,10,"")
    lbl:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y)
    lbl:SetWidth(labelW)
    local gt=RC:GetColor("text","disabled");lbl:SetTextColor(gt.r,gt.g,gt.b,1);lbl:SetText(label)
    if widget then
        widget:SetPoint("TOPLEFT",parent,"TOPLEFT",labelW+PAD+PAD,y+1)
        if widget.SetWidth then widget:SetWidth(dropW) end
    end
    return y-ROW_H
end

local function SecLabel(parent,y,text)
    local lbl=MakeFS(parent,10,"OUTLINE")
    lbl:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y)
    local gc=RC:GetColor("ui","headerText");lbl:SetTextColor(gc.r*0.85,gc.g*0.85,gc.b*0.85,1);lbl:SetText(text)
    local line=parent:CreateTexture(nil,"ARTWORK");line:SetHeight(1)
    line:SetPoint("LEFT",lbl,"RIGHT",4,0)
    line:SetPoint("RIGHT",parent,"RIGHT",-PAD,0)
    local ag=RC:GetColor("ui","accentGold");line:SetColorTexture(ag.r,ag.g,ag.b,0.3)
    return y-20
end
local function HintLine(parent,y,text)
    local lbl=MakeFS(parent,9,"");lbl:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y)
    lbl:SetPoint("TOPRIGHT",parent,"TOPRIGHT",-PAD,y)
    lbl:SetWordWrap(true);local gt=RC:GetColor("text","disabled");lbl:SetTextColor(gt.r,gt.g,gt.b,0.8);lbl:SetText(text)
    return y-20
end

local function DropAt(parent,x,y,items,currentVal,w,onChange)
    local label=RCL["Select..."]
    for _,it in ipairs(items) do if it.value==currentVal then label=it.text;break end end
    if not w then
        -- Falls back to the module-level _EW rather than parent:GetWidth(),
        -- since parent may be a plain Frame without a reliable width yet.
        w = math.max(80, _EW - x - PAD)
    end
    local d=RC.UI:CreateScrollableDropdown(parent,w,label,10)
    d:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y)
    if d.menu then d.menu:SetFrameStrata("TOOLTIP");d.menu:SetFrameLevel(200) end
    d:SetItems(items,function(val) if onChange then onChange(val) end end)
    d:SetSelectedValue(currentVal,label)
    return d
end

local function DropRow(parent,y,label,items,currentVal,onChange,dropW,labelW)
    labelW=labelW or LBL_W
    local gt=RC:GetColor("text","disabled")
    local lbl=MakeFS(parent,10,"");lbl:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y)
    lbl:SetWidth(labelW);lbl:SetTextColor(gt.r,gt.g,gt.b,1);lbl:SetText(label)
    local x=labelW+PAD+PAD
    local d=DropAt(parent,x,y,items,currentVal,dropW,onChange)
    return d, y-ROW_H
end

local function RenderCondFields(parent, cond, y, save, rebuild, indentLW)
    indentLW = indentLW or 90
    local meta = COND_META[cond.type or ""] or {}
    local gt = RC:GetColor("text","disabled")
    local x = indentLW+PAD+PAD

    if meta.needsUnit then
        DropAt(parent, x, y, UNIT_ITEMS, cond.unit or "player", nil, function(v) cond.unit=v; save() end)
        local ul=MakeFS(parent,10,"");ul:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y);ul:SetWidth(indentLW);ul:SetTextColor(gt.r,gt.g,gt.b,1);ul:SetText(RCL["  Unit"])
        y=y-ROW_H
    end
    if meta.needsSpellId then
        local sb=Input(parent,NBOX_W,20);sb:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y+1)
        sb:SetText(cond.spellId and tostring(cond.spellId) or "")
        sb:SetScript("OnEnterPressed",function(self) cond.spellId=tonumber(self:GetText());self:ClearFocus();save() end)
        local sl=MakeFS(parent,10,"");sl:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y);sl:SetWidth(indentLW);sl:SetTextColor(gt.r,gt.g,gt.b,1);sl:SetText(RCL["  Spell ID"])
        y=y-ROW_H
    end
    if meta.needsSpellId2 then
        local sb=Input(parent,NBOX_W,20);sb:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y+1)
        sb:SetText(cond.spellId2 and tostring(cond.spellId2) or "")
        sb:SetScript("OnEnterPressed",function(self) cond.spellId2=tonumber(self:GetText());self:ClearFocus();save() end)
        local sl=MakeFS(parent,10,"");sl:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y);sl:SetWidth(indentLW);sl:SetTextColor(gt.r,gt.g,gt.b,1);sl:SetText(RCL["  Spell ID 2"])
        y=y-ROW_H
    end
    if meta.needsSpellName then
        local sb=Input(parent,NBOX_W,20);sb:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y+1)
        sb:SetText(cond.spellName or "")
        sb:SetScript("OnEnterPressed",function(self) cond.spellName=self:GetText();self:ClearFocus();save() end)
        local sl=MakeFS(parent,10,"");sl:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y);sl:SetWidth(indentLW);sl:SetTextColor(gt.r,gt.g,gt.b,1);sl:SetText(RCL["  Spell name"])
        y=y-ROW_H
    end
    if meta.needsItemId then
        local ib=Input(parent,NBOX_W,20);ib:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y+1)
        ib:SetText(cond.itemId and tostring(cond.itemId) or "")
        ib:SetScript("OnEnterPressed",function(self) cond.itemId=tonumber(self:GetText());self:ClearFocus();save() end)
        local il=MakeFS(parent,10,"");il:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y);il:SetWidth(indentLW);il:SetTextColor(gt.r,gt.g,gt.b,1);il:SetText(RCL["  Item ID"])
        y=y-ROW_H
    end
    if meta.needsSlot then
        DropAt(parent, x, y, SLOT_ITEMS, cond.slot and tostring(cond.slot) or "13", nil, function(v) cond.slot=tonumber(v);save() end)
        local sl=MakeFS(parent,10,"");sl:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y);sl:SetWidth(indentLW);sl:SetTextColor(gt.r,gt.g,gt.b,1);sl:SetText(RCL["  Slot"])
        y=y-ROW_H
    end
    if meta.needsValue then
        local vb=Input(parent,NBOX_W,20);vb:SetPoint("TOPLEFT",parent,"TOPLEFT",x,y+1)
        vb:SetText(cond.value and tostring(cond.value) or "")
        vb:SetScript("OnEnterPressed",function(self) cond.value=tonumber(self:GetText());self:ClearFocus();save() end)
        local lbl=meta.valueLabel or "Value (N)"
        local vl=MakeFS(parent,10,"");vl:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y);vl:SetWidth(indentLW);vl:SetTextColor(gt.r,gt.g,gt.b,1);vl:SetText("  "..lbl)
        y=y-ROW_H
    end
    if meta.needsSpec then
        DropAt(parent, x, y, SPEC_ITEMS, cond.specKey or "", nil, function(v) cond.specKey=(v=="" and nil or v);save() end)
        local sl=MakeFS(parent,10,"");sl:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y);sl:SetWidth(indentLW);sl:SetTextColor(gt.r,gt.g,gt.b,1);sl:SetText(RCL["  Spec"])
        y=y-ROW_H
    end
    if meta.needsStance then
        local sv=cond.stanceIndex and tostring(cond.stanceIndex) or "0"
        DropAt(parent, x, y, STANCE_ITEMS, sv, nil, function(v) cond.stanceIndex=tonumber(v);save() end)
        local sl=MakeFS(parent,10,"");sl:SetPoint("TOPLEFT",parent,"TOPLEFT",PAD,y);sl:SetWidth(indentLW);sl:SetTextColor(gt.r,gt.g,gt.b,1);sl:SetText(RCL["  Stance"])
        y=y-ROW_H
    end
    return y
end

local WR_SOUNDS={
    {label=RCL["WR: Warning"],key="WR: Warning",file="Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg"},
}
local wrSndKeys={}; for _,s in ipairs(WR_SOUNDS) do wrSndKeys[s.key]=true end
local function BuildSoundItems()
    local items,fm={},{}
    for _,s in ipairs(WR_SOUNDS) do table.insert(items,{text=s.label,value=s.key});fm[s.key]=s.file end
    if RC.LSM then
        local all=RC.LSM:HashTable("sound") or {};local lsmList={}
        for k,v in pairs(all) do if not wrSndKeys[k] then table.insert(lsmList,{label=k,key=k,file=v}) end end
        table.sort(lsmList,function(a,b) return a.label<b.label end)
        for _,s in ipairs(lsmList) do table.insert(items,{text=s.label,value=s.key});fm[s.key]=s.file end
    end
    return items,fm
end
local function ResolveSoundLabel(key)
    if not key or key=="" then return "None" end
    for _,s in ipairs(WR_SOUNDS) do if s.key==key then return s.label end end
    return key
end

local function BuildBossItems()
    local list={{text=RCL[" - Any boss - "],value=""}}
    local raiders={"Molten Core","Blackwing Lair","Temple of Ahn'Qiraj","Naxxramas"}
    -- (options audit 2026-11-09) another game version lists its own raids
    -- (RaidFlavor.lua): TBC's bosses on TBC, as Raids_Remote does
    if RC._raidFlavorApplied and RC.RaidNames then raiders=RC:RaidNames() end
    local cfg=RC.raidMobConfigs or {}
    for _,raid in ipairs(raiders) do
        if cfg[raid] then
            local bosses={}
            for boss,_ in pairs(cfg[raid]) do if type(boss)=="string" then table.insert(bosses,boss) end end
            table.sort(bosses)
            for _,boss in ipairs(bosses) do
                table.insert(list,{text=boss.." ("..raid:sub(1,3)..")",value=raid.."|"..boss})
            end
        end
    end
    return list
end

local function GetSpecItems(loadClass)
    if loadClass=="WARRIOR" then return CLASS_SPECS.WARRIOR end
    return SPEC_ANY_ITEMS
end

-- WoW never garbage collects a frame: hiding one and reparenting it to nil
-- takes it out of the tree but leaves it alive for the rest of the session.
-- This list used to tear itself down that way on every click (select, add,
-- delete, reorder, preset install), so a long editing session kept growing
-- the frame list. Instead the chrome is built once per scrollChild and
-- cached on the sidebar frame, and the reminder/preset rows come out of
-- pools reused by index - a render only updates what a row displays.

local function SwapReminders(i,j,frame)
    local db=RC.db and RC.db.customReminders and RC.db.customReminders.reminders
    if not db then return end
    if i<1 or j>#db then return end
    db[i],db[j]=db[j],db[i]
    -- Invalidate the runtime reminder engine's cached order/event
    -- list (separate module) so it recomputes on its next tick.
    if RC.CustomReminders then RC.CustomReminders.sortDirty=true; RC.CustomReminders.hasEventReminders=nil end
    RC:SaveConfigurationToProfile()
    RC:ShowSidebarCustomReminders(frame)
end

-- Commits a drag reorder. Shared by the grip's own OnMouseUp and the
-- poll frame's mouse-up-anywhere fallback.
local function CommitDrag(frame)
    local ind=_G["WRCRDragIndicator"]; if ind then ind:Hide() end
    local from,to=CR_Drag.from,CR_Drag.to
    if from and to and to~=from then
        local db=RC.db and RC.db.customReminders and RC.db.customReminders.reminders
        if db and from>=1 and from<=#db then
            local item=table.remove(db,from)
            local insertAt=(from<to)and(to-1)or to
            insertAt=math.max(1,math.min(#db+1,insertAt))
            if item then table.insert(db,insertAt,item) end
            RC:SaveConfigurationToProfile()
        end
    end
    CR_Drag.active=false
    RC:ShowSidebarCustomReminders(frame)
end

-- D6 row paint: selected = buttons.configuredBackground + 3px gold bar,
-- hover = buttons.hoverBackground, otherwise a white 0.03 stripe on
-- every other row (rows are pooled, so read the current index).
local function PaintRowBg(row,hot)
    local selected=(CR_Editor.selectedId==row._rid)
    if selected then
        local c=RC:GetColor("buttons",hot and "configuredHover" or "configuredBackground")
        row.bg:SetVertexColor(c.r,c.g,c.b,1)
        row.selBar:Show()
    elseif hot then
        local c=RC:GetColor("buttons","hoverBackground")
        row.bg:SetVertexColor(c.r,c.g,c.b,1)
        row.selBar:Hide()
    else
        row.bg:SetVertexColor(1,1,1,((row._idx or 0)%2==0) and 0.03 or 0)
        row.selBar:Hide()
    end
end

-- Builds one reusable list row. Everything a row can ever show is created
-- here once; UpdateRow only rewrites text/colour/scripts and shows or
-- hides the two reorder arrows. Handlers read row._rid/_idx/_frame rather
-- than closing over the render that built them, so a pooled row never
-- acts on the reminder it displayed last time.
local function BuildRow(lc)
    local rH=26
    local row=CreateFrame("Button",nil,lc)
    row:SetSize(LIST_W-1,rH)
    local rbg=row:CreateTexture(nil,"BACKGROUND");rbg:SetAllPoints();rbg:SetTexture(RC.UI.FLAT)
    row.bg=rbg
    local selBar=row:CreateTexture(nil,"ARTWORK");selBar:SetWidth(3)
    selBar:SetPoint("TOPLEFT",row,"TOPLEFT",0,0);selBar:SetPoint("BOTTOMLEFT",row,"BOTTOMLEFT",0,0)
    selBar:SetTexture(RC.UI.FLAT)
    local sag=RC:GetColor("ui","borderSelected");selBar:SetVertexColor(sag.r,sag.g,sag.b,1);selBar:Hide()
    row.selBar=selBar

    local grip=CreateFrame("Button",nil,row);grip:SetSize(9,rH-4);grip:SetPoint("LEFT",row,"LEFT",4,0)
    local gripTex=grip:CreateTexture(nil,"ARTWORK");gripTex:SetAllPoints();gripTex:SetTexture(RC.UI.FLAT)
    local gtd=RC:GetColor("text","disabled");gripTex:SetVertexColor(gtd.r,gtd.g,gtd.b,0.2)
    for di=1,3 do
        local d1=grip:CreateTexture(nil,"OVERLAY");d1:SetSize(2,2);d1:SetPoint("TOPLEFT",2,(di-1)*(-6)-4);d1:SetColorTexture(gtd.r,gtd.g,gtd.b,0.6)
        local d2=grip:CreateTexture(nil,"OVERLAY");d2:SetSize(2,2);d2:SetPoint("TOPLEFT",6,(di-1)*(-6)-4);d2:SetColorTexture(gtd.r,gtd.g,gtd.b,0.6)
    end
    row.grip=grip
    grip:SetScript("OnEnter",function() local c=RC:GetColor("text","disabled");gripTex:SetVertexColor(c.r,c.g,c.b,0.4) end)
    grip:SetScript("OnLeave",function() local c=RC:GetColor("text","disabled");gripTex:SetVertexColor(c.r,c.g,c.b,0.2) end)
    grip:SetScript("OnMouseDown",function()
        CR_Drag.active=true;CR_Drag.from=row._idx;CR_Drag.to=row._idx
        if _DragFrame then _DragFrame:Show() end
    end)
    -- Normal commit path (mouse released while still over the grip).
    grip:SetScript("OnMouseUp",function()
        if not CR_Drag.active then return end
        CommitDrag(row._frame)
    end)

    local dot=row:CreateTexture(nil,"ARTWORK");dot:SetSize(6,6);dot:SetPoint("LEFT",13,0)
    row.dot=dot
    local badge=MakeFS(row,8,"");badge:SetPoint("RIGHT",-44,0)
    row.badge=badge
    local nm=MakeFS(row,10,"OUTLINE");nm:SetPoint("LEFT",22,0);nm:SetPoint("RIGHT",badge,"LEFT",-2,0)
    nm:SetJustifyH("LEFT");nm:SetWordWrap(false)
    row.nm=nm

    local del=RC.UI:CreateXCloseButton(row,20)
    del:SetPoint("RIGHT",row,"RIGHT",-10,0)
    row.del=del

    local function ArrowBtn(tex,yOff)
        local b=CreateFrame("Button",nil,row);b:SetSize(8,8);b:SetPoint("RIGHT",del,"LEFT",-2,yOff)
        local bg=b:CreateTexture(nil,"BACKGROUND");bg:SetAllPoints();bg:SetTexture(RC.UI.FLAT)
        local gt2=RC:GetColor("text","disabled");bg:SetVertexColor(gt2.r,gt2.g,gt2.b,0.4)
        local ar=b:CreateTexture(nil,"ARTWORK");ar:SetSize(6,6);ar:SetPoint("CENTER",0,0)
        ar:SetTexture(tex);ar:SetVertexColor(gt2.r,gt2.g,gt2.b,0.8)
        b:SetScript("OnEnter",function() local ag=RC:GetColor("ui","accentGold");bg:SetVertexColor(ag.r,ag.g,ag.b,0.3);ar:SetVertexColor(ag.r,ag.g,ag.b,1) end)
        b:SetScript("OnLeave",function() local c=RC:GetColor("text","disabled");bg:SetVertexColor(c.r,c.g,c.b,0.4);ar:SetVertexColor(c.r,c.g,c.b,0.8) end)
        return b
    end
    row.upBtn=ArrowBtn("Interface\\AddOns\\Readycheck\\Media\\arrowUp",4)
    row.dnBtn=ArrowBtn("Interface\\AddOns\\Readycheck\\Media\\arrow",-4)
    row.upBtn:SetScript("OnClick",function() SwapReminders(row._idx-1,row._idx,row._frame) end)
    row.dnBtn:SetScript("OnClick",function() SwapReminders(row._idx,row._idx+1,row._frame) end)

    row:SetScript("OnEnter",function() PaintRowBg(row,true) end)
    row:SetScript("OnLeave",function() PaintRowBg(row,false) end)
    row:SetScript("OnClick",function()
        if CR_Drag.active then return end
        CR_Editor.selectedId=row._rid;CR_Editor.activeTab="general"
        RC:ShowSidebarCustomReminders(row._frame)
    end)
    return row
end

local function UpdateRow(row,r,ri,total,frame,yo)
    row._rid,row._idx,row._frame=r.id,ri,frame
    row:ClearAllPoints();row:SetPoint("TOPLEFT",0,yo)
    PaintRowBg(row,false)
    if r.enabled then
        local ok=RC:GetColor("status","success");row.dot:SetColorTexture(ok.r,ok.g,ok.b,1)
    else
        local dis=RC:GetColor("text","disabled");row.dot:SetColorTexture(dis.r,dis.g,dis.b,0.5)
    end
    local mc=MODE_COLORS[r.mode or "aura"] or {0.7,0.7,0.7}
    row.badge:SetTextColor(mc[1],mc[2],mc[3],1)
    row.badge:SetText((r.mode or "?"):upper():sub(1,4))
    local nc=RC:GetColor("text","normal")
    row.nm:SetTextColor(nc.r,nc.g,nc.b,1);row.nm:SetText(r.name or r.id)
    local rid,rname=r.id,(r.name or r.id)
    row.del:SetScript("OnClick",function()
        RC.UI:CreateConfirmDialog(RCL["Delete Reminder"],RCL["Delete '"]..rname.."'?",function()
            RC:DeleteCustomReminder(rid)
            if CR_Editor.selectedId==rid then CR_Editor.selectedId=nil end
            RC:ShowSidebarCustomReminders(frame)
        end, nil, RCL["Delete"], true)
    end)
    if ri>1 then row.upBtn:Show() else row.upBtn:Hide() end
    if ri<total then row.dnBtn:Show() else row.dnBtn:Hide() end
    row:Show()
end

local function BuildPresetRow(lc)
    local pH=24
    local prow=CreateFrame("Button",nil,lc);prow:SetSize(LIST_W-1,pH)
    local pbg=prow:CreateTexture(nil,"BACKGROUND");pbg:SetAllPoints();pbg:SetTexture(RC.UI.FLAT)
    prow.bg=pbg
    local ico=prow:CreateTexture(nil,"ARTWORK");ico:SetSize(14,14);ico:SetPoint("LEFT",4,0)
    ico:SetTexCoord(0.08,0.92,0.08,0.92)
    prow.icon=ico
    local pnm=MakeFS(prow,10,"");pnm:SetPoint("LEFT",22,0);pnm:SetPoint("RIGHT",-44,0)
    pnm:SetJustifyH("LEFT");pnm:SetWordWrap(false)
    prow.nm=pnm
    local ab=Btn(prow,"+Add",38,18);ab:SetPoint("RIGHT",-4,0)
    prow.addBtn=ab
    prow:SetScript("OnEnter",function()
        local eb2=RC:GetColor("buttons","hoverBackground");pbg:SetVertexColor(eb2.r,eb2.g,eb2.b,1)
        local nc2=RC:GetColor("text","normal");pnm:SetTextColor(nc2.r,nc2.g,nc2.b,1)
        local p=prow._preset; if not p then return end
        GameTooltip:SetOwner(prow,"ANCHOR_RIGHT");GameTooltip:SetText(p.name,1,0.82,0)
        if p.description then GameTooltip:AddLine(p.description,0.7,0.7,0.7,true) end
        GameTooltip:Show()
    end)
    prow:SetScript("OnLeave",function()
        pbg:SetVertexColor(1,1,1,((prow._idx or 0)%2==0) and 0.03 or 0)
        local gt=RC:GetColor("text","disabled");pnm:SetTextColor(gt.r,gt.g,gt.b,1)
        GameTooltip:Hide()
    end)
    ab:SetScript("OnClick",function()
        local p=prow._preset; if not p then return end
        local r=RC:InstallPreset(p.key)
        if r then
            CR_Editor.selectedId=r.id;CR_Editor.activeTab="general"
            RC:ShowSidebarCustomReminders(prow._frame)
        end
    end)
    return prow
end

local function UpdatePresetRow(prow,preset,frame,yo,pi)
    prow._preset,prow._frame,prow._idx=preset,frame,pi
    prow:ClearAllPoints();prow:SetPoint("TOPLEFT",0,yo)
    prow.bg:SetVertexColor(1,1,1,((prow._idx or 0)%2==0) and 0.03 or 0)
    if preset.icon then prow.icon:SetTexture(preset.icon);prow.icon:Show() else prow.icon:Hide() end
    local gt=RC:GetColor("text","disabled")
    prow.nm:SetTextColor(gt.r,gt.g,gt.b,1);prow.nm:SetText(preset.name)
    prow:Show()
end

-- Builds (once) and returns the persistent chrome for this sidebar frame:
-- left panel, its scroll frame/child and scrollbar, the divider and the
-- right-hand editor panel. Re-parents and re-anchors on every call so the
-- cache survives another sidebar page having cleared out scrollChild.
local function EnsureChrome(frame,sc,FH)
    local ui=frame._crUI
    if ui and ui.sc~=sc then ui=nil end
    if not ui then
        ui={sc=sc,rows={},presets={}}
        ui.lp=CreateFrame("Frame",nil,sc)
        ui.hdr=MakeFS(ui.lp,11,"OUTLINE");ui.hdr:SetPoint("TOPLEFT",PAD,-PAD)
        ui.newBtn=Btn(ui.lp,"+ New",60,20);ui.newBtn:SetPoint("TOPRIGHT",-PAD,-26)
        ui.importBtn=Btn(ui.lp,"Import",52,20);ui.importBtn:SetPoint("TOPRIGHT",ui.newBtn,"TOPLEFT",-4,0)
        ui.div=sc:CreateTexture(nil,"ARTWORK");ui.div:SetWidth(1);ui.div:SetColorTexture(0,0,0,1)
        ui.lsf=CreateFrame("ScrollFrame",nil,ui.lp)
        ui.lsf:SetPoint("TOPLEFT",0,-46);ui.lsf:SetPoint("BOTTOMRIGHT",-1,0)
        ui.lsf:EnableMouseWheel(true)
        ui.lc=CreateFrame("Frame",nil,ui.lsf);ui.lc:SetWidth(LIST_W-1);ui.lsf:SetScrollChild(ui.lc)

        local sb=CreateFrame("Slider",nil,ui.lp)
        sb:SetPoint("TOPRIGHT",ui.lp,"TOPRIGHT",-1,-46)
        sb:SetPoint("BOTTOMRIGHT",ui.lp,"BOTTOMRIGHT",-1,0)
        sb:SetWidth(8);sb:SetOrientation("VERTICAL")
        sb:SetMinMaxValues(0,0);sb:SetValue(0);sb:SetValueStep(1)
        local sbBg=sb:CreateTexture(nil,"BACKGROUND");sbBg:SetAllPoints();sbBg:SetTexture(RC.UI.FLAT)
        local stc=RC:GetColor("scrollbar","track") or RC:GetColor("ui","cardBackground")
        sbBg:SetVertexColor(stc.r,stc.g,stc.b,0.4)
        sb:SetThumbTexture("Interface\\Buttons\\WHITE8X8")
        if RC.UI and RC.UI.AddThumbBorder then RC.UI:AddThumbBorder(sb) end
        local stht=sb:GetThumbTexture();if stht then
            local ttc=RC:GetColor("scrollbar","thumb") or RC:GetColor("ui","accentGold")
            stht:SetSize(8,24);stht:SetVertexColor(ttc.r,ttc.g,ttc.b,0.8)
        end
        -- Guards against feedback: wheel scroll drives the slider value, and
        -- the slider's OnValueChanged drives the scroll frame; without this
        -- flag each one would re-trigger the other.
        local _sbUpdating=false
        ui.lsf:SetScript("OnMouseWheel",function(self,d)
            local cur=self:GetVerticalScroll();local max=self:GetVerticalScrollRange()
            local nv=d>0 and math.max(0,cur-30) or math.min(max,cur+30)
            self:SetVerticalScroll(nv);_sbUpdating=true;sb:SetValue(nv);_sbUpdating=false
        end)
        sb:SetScript("OnValueChanged",function(self,val)
            if not _sbUpdating then ui.lsf:SetVerticalScroll(val) end
        end)
        ui.sb=sb

        ui.psep=ui.lc:CreateTexture(nil,"ARTWORK");ui.psep:SetHeight(1)
        ui.phdr=MakeFS(ui.lc,9,"OUTLINE")
        ui.emptyHint=MakeFS(ui.lc,10,"");ui.emptyHint:SetWidth(LIST_W-PAD*2)
        ui.emptyHint:SetJustifyH("LEFT")

        ui.rp=CreateFrame("Frame",nil,sc)
        ui.rpHint=MakeFS(ui.rp,11,"");ui.rpHint:SetPoint("CENTER",0,20)
        ui.rpHint:SetJustifyH("CENTER")
        frame._crUI=ui
    end
    -- Re-assert parenting/anchors: another sidebar page may have orphaned
    -- these while it owned scrollChild.
    ui.lp:SetParent(sc);ui.lp:ClearAllPoints()
    ui.lp:SetPoint("TOPLEFT",0,0);ui.lp:SetSize(LIST_W,FH);ui.lp:Show()
    ui.div:ClearAllPoints()
    ui.div:SetPoint("TOPLEFT",LIST_W,0);ui.div:SetPoint("BOTTOMLEFT",LIST_W,0);ui.div:Show()
    ui.rp:SetParent(sc);ui.rp:ClearAllPoints()
    ui.rp:SetPoint("TOPLEFT",sc,"TOPLEFT",LIST_W+1,0)
    ui.rp:SetPoint("BOTTOMRIGHT",sc,"BOTTOMRIGHT",0,0);ui.rp:Show()
    return ui
end

-- The preview: the selected reminder as the popup will show it - the
-- popup's own icon (RC:CreateReminderIcon), its icon and its label - and
-- Replay plays the animation it will fire with. No selection: a sample.
local CR_SAMPLE={id=0,name="Sapper now",message="Sapper now",icon="Interface\\Icons\\INV_Misc_Bomb_08"}
local function CRSelected()
    return (CR_Editor.selectedId and RC:GetCustomReminder(CR_Editor.selectedId)) or CR_SAMPLE
end
-- mirrors FireReminder + GetReminderMotion: a custom reminder always plays
-- its own style (else the global one) both in and out
local function CRMotion(how,r)
    local spec=RC:GetReminderMotion(how,{})
    spec.style=RC.Motion.StyleFromLegacy(r.animationType or RC.db.animationType or "fade")
    return spec
end
local function CRPreviewUpdate(canvas,P)
    local st,db=P.store,RC.db
    local r=CRSelected()
    local size=math.max(8,db.iconSize or 80)
    -- the icon at its real size, its label up to twice as wide; the canvas
    -- is that box and the strip scales it
    if st.size~=size then
        RC.Motion.Stop(st.holder)
        st.holder:SetSize(size*2+8,size+14)
        st.holder:SetScale(1)
        st.size=size
    end
    P.Resize(size*2+8,size+14)
    local icon=st.icon
    if not icon then icon=RC:CreateReminderIcon(st.holder,size);st.icon=icon end
    icon:SetSize(size,size)
    icon.originalSize=size
    RC.UI:DressReadyIcon(icon,size)
    icon.texture:SetTexture((RC.ResolveCustomReminderIcon and r~=CR_SAMPLE and RC:ResolveCustomReminderIcon(r)) or r.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    icon:ClearAllPoints();icon:SetPoint("CENTER",st.holder,"CENTER",0,0)
    icon:Show()
    if db.showIconText then
        RC:EnsureReminderIconText(icon)
        local lbl=(r.message and r.message~="" and r.message) or r.name or "Alert"
        if #lbl>22 then lbl=lbl:sub(1,20)..".." end
        icon.cooldownText:SetWidth(size*2)
        RC:SetReminderIconLabel(icon,lbl,"gold")
        icon.cooldownText:Show()
    elseif icon.cooldownText then
        icon.cooldownText:Hide()
    end
    RC.UI:SetReadyIconGlow(icon,db.iconGlow or "pulse")
end
local function CRPreviewReplay(canvas,P)
    local st=P.store
    local r=CRSelected()
    local M=RC.Motion
    st.token=(st.token or 0)+1
    local t=st.token
    M.Stop(st.holder);st.holder:Hide()
    local inSpec=CRMotion("in",r)
    M.Show(st.holder,inSpec)
    C_Timer.After(M.Duration(inSpec.duration)+M.Duration(inSpec.delay or 0)+1.2,function()
        if t~=st.token or not st.holder:IsVisible() then return end
        local outSpec=CRMotion("out",r)
        M.Hide(st.holder,outSpec)
        C_Timer.After(M.Duration(outSpec.duration)+M.Duration(outSpec.delay or 0)+0.4,function()
            if t~=st.token then return end
            M.Stop(st.holder)
            if canvas:IsVisible() then st.holder:Show() end
        end)
    end)
end
function RC:CR_DeclarePreview()
    if not (self.UI and self.UI.DeclarePreview and self.CreateReminderIcon) then return nil end
    return self.UI:DeclarePreview({
        key="customreminders.popup",title=RCL["Custom reminder"],width=168,height=94,
        build=function(canvas,P)
            local h=CreateFrame("Frame",nil,canvas)
            h:SetPoint("CENTER",canvas,"CENTER",0,0)
            P.store.holder=h
        end,
        update=CRPreviewUpdate,replay=CRPreviewReplay,
    })
end

function RC:ShowSidebarCustomReminders(frame)
    if not frame or not frame.scrollChild then return end
    -- Must run before the row grips below are created: grip:OnMouseDown
    -- shows _DragFrame directly, so the poll frame has to exist first.
    EnsureDragFrame()
    if not _G["WRCRDragIndicator"] then
        local f = CreateFrame("Frame", "WRCRDragIndicator", UIParent)
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetHeight(2)
        local t = f:CreateTexture(nil, "OVERLAY"); t:SetAllPoints()
        local ac = RC:GetColor("ui", "accentGold")
        t:SetColorTexture(ac.r, ac.g, ac.b, 1)
        f:Hide()
    end
    CR_Drag.active = false
    CR_Drag.rows   = {}
    CR_Drag.lp     = nil
    local _ind = _G["WRCRDragIndicator"]; if _ind then _ind:Hide() end
    local sc=frame.scrollChild
    if not self.db or not self.db.customReminders then
        -- No cached chrome yet at this point, so nothing of ours is in
        -- scrollChild to preserve; clear it and show the placeholder.
        for _,c in pairs({sc:GetChildren()}) do c:Hide();c:SetParent(nil) end
        for _,r in pairs({sc:GetRegions()}) do r:Hide() end
        frame._crUI=nil
        local l=MakeFS(sc,11,"");l:SetPoint("CENTER")
        local gt=self:GetColor("text","disabled");l:SetTextColor(gt.r,gt.g,gt.b,1);l:SetText(RCL["Initializing..."])
        return
    end
    RC:CR_DeclarePreview()
    local FW=sc:GetWidth(); if FW<100 then FW=827 end
    local EW=FW-LIST_W-1
    _EW = EW
    local FH=math.max(frame:GetHeight()-10,500);sc:SetHeight(FH)

    local ui=EnsureChrome(frame,sc,FH)
    -- Drop anything in scrollChild that is not ours (a different sidebar
    -- page having rendered here); our own chrome stays and is reused.
    for _,c in pairs({sc:GetChildren()}) do
        if c~=ui.lp and c~=ui.rp then c:Hide();c:SetParent(nil) end
    end
    for _,r in pairs({sc:GetRegions()}) do
        if r~=ui.div then r:Hide() end
    end

    local lp=ui.lp
    CR_Drag.lp    = lp
    CR_Drag.frame = frame
    local hdr=ui.hdr
    local gc=self:GetColor("ui","headerText");hdr:SetTextColor(gc.r,gc.g,gc.b,1);hdr:SetText(RCL["Custom Reminders"])
    local newBtn=ui.newBtn
    newBtn:SetScript("OnClick",function()
        local r=RC:CreateCustomReminder("New Reminder","aura")
        CR_Editor.selectedId=r.id;CR_Editor.activeTab="general"
        RC:ShowSidebarCustomReminders(frame)
    end)
    local importBtn=ui.importBtn
    importBtn:SetScript("OnClick",function()
        -- The one import window. The input dialog this used to open holds
        -- 60 characters and one line, so no reminder string ever fitted in
        -- it. Any Readycheck export can be pasted; a reminder is selected
        -- here once it is in.
        RC:ShowUniversalImport({ from = "reminder", onDone = function(res)
            if res and res.kind == "reminder" and res.reminder then
                CR_Editor.selectedId = res.reminder.id
                CR_Editor.activeTab  = "general"
                RC:ShowSidebarCustomReminders(frame)
            end
        end })
    end)
    local lsf,lc,sb=ui.lsf,ui.lc,ui.sb

    CR_Drag.indicator = _G["WRCRDragIndicator"]
    CR_Drag.lsf       = lsf
    CR_Drag.rows      = {}

    local reminders=self.db.customReminders.reminders;local yo=-2
    if #reminders==0 then
        local hint=ui.emptyHint
        hint:ClearAllPoints();hint:SetPoint("TOPLEFT",PAD,-PAD)
        local gt=self:GetColor("text","disabled");hint:SetTextColor(gt.r,gt.g,gt.b,1)
        hint:SetText(RCL["No reminders yet.\nClick '+ New' or install\na preset below."])
        hint:Show()
        yo=yo-50
    else
        ui.emptyHint:Hide()
    end
    local nRem=#reminders
    for ri,r in ipairs(reminders) do
        local row=ui.rows[ri]
        if not row then row=BuildRow(lc);ui.rows[ri]=row end
        UpdateRow(row,r,ri,nRem,frame,yo)
        table.insert(CR_Drag.rows, row)
        yo=yo-26-1
    end
    -- park the surplus: pooled rows past the current list stay alive but
    -- hidden, ready for the next render that needs them again.
    for i=nRem+1,#ui.rows do ui.rows[i]:Hide() end

    yo=yo-6
    ui.psep:ClearAllPoints();ui.psep:SetPoint("TOPLEFT",4,yo);ui.psep:SetPoint("TOPRIGHT",-4,yo)
    local ag=self:GetColor("ui","accentGold");ui.psep:SetColorTexture(ag.r,ag.g,ag.b,0.3);ui.psep:Show();yo=yo-2
    ui.phdr:ClearAllPoints();ui.phdr:SetPoint("TOPLEFT",PAD,yo-2)
    local phc=self:GetColor("ui","headerText")
    ui.phdr:SetTextColor(phc.r*0.7,phc.g*0.7,phc.b*0.7,1);ui.phdr:SetText("PRESETS");ui.phdr:Show();yo=yo-16
    local presets=RC.customReminderPresets or {}
    for pi,preset in ipairs(presets) do
        local prow=ui.presets[pi]
        if not prow then prow=BuildPresetRow(lc);ui.presets[pi]=prow end
        UpdatePresetRow(prow,preset,frame,yo,pi)
        yo=yo-24-1
    end
    for i=#presets+1,#ui.presets do ui.presets[i]:Hide() end
    lc:SetHeight(math.abs(yo)+10)
    C_Timer.After(0,function()
        if lsf and lsf.GetVerticalScrollRange then
            local max=lsf:GetVerticalScrollRange()
            if max<0 then max=0 end
            sb:SetMinMaxValues(0,max)
            sb:SetAlpha(max>0 and 1 or 0.3)
            -- the scroll frame is reused across renders now, so a list that
            -- just got shorter can still be scrolled past its new end.
            local cur=lsf:GetVerticalScroll()
            if cur>max then lsf:SetVerticalScroll(max);cur=max end
            sb:SetValue(cur)
        end
    end)
    CR_Drag.active=false;CR_Drag.from=nil;CR_Drag.to=nil;CR_Drag.indicator=nil

    local rp=ui.rp
    rp._wrEW=EW

    if CR_Editor.selectedId then
        ui.rpHint:Hide()
        RC:CR_OpenEditor(rp,frame)
    else
        -- Nothing selected: drop whatever editor content is in the panel
        -- and show the placeholder. CR_OpenEditor owns the teardown of its
        -- own widgets, so only clear here.
        for _,c in pairs({rp:GetChildren()}) do c:Hide();c:SetParent(nil) end
        for _,r in pairs({rp:GetRegions()}) do
            if r~=ui.rpHint then r:Hide() end
        end
        CR_Editor.tabContent=nil
        local gt=RC:GetColor("text","disabled")
        ui.rpHint:SetTextColor(gt.r,gt.g,gt.b,1)
        ui.rpHint:SetText(RCL["Select a reminder to edit it,\nor click + New to create one."])
        ui.rpHint:Show()
    end
end

-- NOT pooled, unlike the list rows above: the editor's widget set changes
-- completely with the reminder's trigger mode and the selected tab, so
-- there is no stable per-index row to reuse - a pool here would have to
-- hand back frames by type and fully reset text/width/justify/scripts on
-- every handout, which is where stale-state bugs come from. The panel it
-- draws into is now persistent, so only the editor's own contents churn.
function RC:CR_OpenEditor(panel,mainFrame)
    local reminder=RC:GetCustomReminder(CR_Editor.selectedId)
    if not reminder then CR_Editor.selectedId=nil;return end
    for _,c in pairs({panel:GetChildren()}) do c:Hide();c:SetParent(nil) end
    for _,r in pairs({panel:GetRegions()}) do r:Hide() end
    local EW=panel:GetWidth()
    if EW<100 then EW=panel._wrEW or 400 end
    panel._wrEW=EW

    local hs=CreateFrame("Frame",nil,panel)
    hs:SetPoint("TOPLEFT",panel,"TOPLEFT",0,0)
    hs:SetPoint("TOPRIGHT",panel,"TOPRIGHT",0,0)
    hs:SetHeight(30)
    local hsbg=hs:CreateTexture(nil,"BACKGROUND");hsbg:SetAllPoints();hsbg:SetTexture(RC.UI.FLAT)
    local eb=RC:GetColor("ui","elementBackground");hsbg:SetVertexColor(eb.r,eb.g,eb.b,1)
    local enableCB=RC.UI:CreateCheckbox(hs,"",reminder.enabled)
    -- KickCustomReminderTicker() wakes the running evaluator immediately so
    -- a just-(re)enabled reminder starts firing without waiting for its
    -- next natural tick.
    enableCB:SetPoint("LEFT",6,0);enableCB:SetScript("OnClick",function(self) reminder.enabled=self:GetChecked();RC:ForceCheckboxUpdate(self,reminder.enabled);RC:SaveConfigurationToProfile();if reminder.enabled and RC.KickCustomReminderTicker then RC:KickCustomReminderTicker() end end)
    local nameBox=Input(hs,EW-120,20);nameBox:SetPoint("LEFT",hs,"LEFT",30,0);nameBox:SetPoint("RIGHT",hs,"RIGHT",-82,0)
    nameBox:SetText(reminder.name or "")
    nameBox:SetScript("OnEnterPressed",function(self) reminder.name=self:GetText();self:ClearFocus();RC:SaveConfigurationToProfile();RC:ShowSidebarCustomReminders(mainFrame) end)
    local dupBtn=Btn(hs,"Duplicate",72,22);dupBtn:SetPoint("RIGHT",-PAD,0)
    dupBtn:SetScript("OnClick",function() local copy=RC:DuplicateCustomReminder(reminder.id);if copy then CR_Editor.selectedId=copy.id;CR_Editor.activeTab="general";RC:ShowSidebarCustomReminders(mainFrame) end end)

    local tabDefs={{key="general",label=RCL["General"]},{key="trigger",label=RCL["Trigger"]},{key="extra",label=RCL["Conditions"]},{key="load",label=RCL["Load"]},{key="test",label=RCL["Test"]}}
    -- Framework tab row: flat tabs 1px apart, the active one wearing the
    -- green configured fill + gold ring. Replaces the hand-rolled tabs.
    local tabGroup
    local function SwitchTab(key)
        CR_Editor.activeTab=key
        if tabGroup then tabGroup:SetSelected(key) end
        RC:CR_RenderTab(panel,reminder,key,mainFrame)
    end
    tabGroup=RC.UI:CreateTabGroup(panel,{
        tabs=tabDefs,selected=CR_Editor.activeTab,
        y=-30,inset=0,height=TAB_H,tabHeight=TAB_H,fontSize=10,spacing=1,
        onClick=SwitchTab,
    })
    local tabBar=tabGroup.container

    local _contentResizePending=false
    local _lastRenderedEW=EW
    tabBar:SetScript("OnSizeChanged",function(self,w)
        tabGroup:Recalc()
        if w and w>10 and not _contentResizePending then
            _contentResizePending=true
            -- Debounce: only re-render 0.75s after resizing settles, and
            -- only if width moved more than 30px, so a drag-resize doesn't
            -- rebuild the whole tab on every intermediate frame.
            C_Timer.After(0.75,function()
                _contentResizePending=false
                if not panel:IsShown() then return end
                local nw=panel:GetWidth()
                if nw and nw>100 and math.abs(nw-_lastRenderedEW)>30 then
                    _lastRenderedEW=nw
                    panel._wrEW=nw
                    _EW=nw
                    local rem=RC:GetCustomReminder(CR_Editor.selectedId)
                    if rem then RC:CR_RenderTab(panel,rem,CR_Editor.activeTab,mainFrame) end
                end
            end)
        end
    end)

    local sep=panel:CreateTexture(nil,"ARTWORK");sep:SetHeight(1)
    sep:SetPoint("TOPLEFT",0,-(30+TAB_H));sep:SetPoint("TOPRIGHT",panel,"TOPRIGHT",0,-(30+TAB_H))
    sep:SetColorTexture(0,0,0,1)
    SwitchTab(CR_Editor.activeTab)
end

function RC:CR_RenderTab(panel,reminder,tabKey,mainFrame)
    if CR_Editor.tabContent then CR_Editor.tabContent:Hide();CR_Editor.tabContent:SetParent(nil);CR_Editor.tabContent=nil end
    local CONTENT_TOP=30+TAB_H+1
    local EW=panel:GetWidth()
    if EW<100 then EW=panel._wrEW or 400 end
    panel._wrEW=EW
    _EW=EW

    local content=CreateFrame("Frame",nil,panel)
    content:SetPoint("TOPLEFT",panel,"TOPLEFT",0,-CONTENT_TOP)
    content:SetWidth(EW)
    -- Tall placeholder; real height is measured from the cursor position
    -- and applied near the end of this function (SetHeight below).
    content:SetHeight(2000)
    CR_Editor.tabContent=content

    local LBL_W=110
    local y=-PAD

    if tabKey=="general" then
        y=SecLabel(content,y,"Display");y=y-4
        local gt=RC:GetColor("text","disabled")

        local nlbl=MakeFS(content,10,"");nlbl:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);nlbl:SetWidth(LBL_W);nlbl:SetTextColor(gt.r,gt.g,gt.b,1);nlbl:SetText(RCL["Name"])
        local nb=Input(content,200,20)
        nb:SetPoint("TOPLEFT",content,"TOPLEFT",LBL_W+PAD+PAD,y+1)
        nb:SetWidth(math.max(60, _EW-LBL_W-PAD*3))
        nb:SetText(reminder.name or "")
        nb:SetScript("OnEnterPressed",function(self) reminder.name=self:GetText();self:ClearFocus();RC:SaveConfigurationToProfile();RC:ShowSidebarCustomReminders(mainFrame) end)
        y=y-ROW_H

        local mlbl=MakeFS(content,10,"");mlbl:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);mlbl:SetWidth(LBL_W);mlbl:SetTextColor(gt.r,gt.g,gt.b,1);mlbl:SetText(RCL["Message"])
        local mb=Input(content,200,20)
        mb:SetPoint("TOPLEFT",content,"TOPLEFT",LBL_W+PAD+PAD,y+1)
        mb:SetWidth(math.max(60, _EW-LBL_W-PAD*3))
        mb:SetText(reminder.message or "")
        mb:SetScript("OnEnterPressed",function(self) reminder.message=self:GetText();self:ClearFocus();RC:SaveConfigurationToProfile() end)
        y=y-ROW_H
        y=HintLine(content,y,"Variables: {remaining}  {stacks}  {hp}  {power}  {rage}  {ttk}  {fight}  {name}")

        y=y-4;y=SecLabel(content,y,"Icon");y=y-4
        y=HintLine(content,y,"Spell ID or Item ID - auto-resolved. Blank = uses trigger's icon.")
        local isb=Input(content,NBOX_W,20);isb:SetText(reminder.iconSpellId and tostring(reminder.iconSpellId) or "")
        isb:SetScript("OnEnterPressed",function(self) reminder.iconSpellId=tonumber(self:GetText());if reminder.iconSpellId then reminder.iconItemId=nil;reminder.icon="" end;self:ClearFocus();RC:SaveConfigurationToProfile() end)
        y=Row(content,y,"Icon Spell ID",isb,NBOX_W,LBL_W)
        local iib=Input(content,NBOX_W,20);iib:SetText(reminder.iconItemId and tostring(reminder.iconItemId) or "")
        iib:SetScript("OnEnterPressed",function(self) reminder.iconItemId=tonumber(self:GetText());if reminder.iconItemId then reminder.iconSpellId=nil;reminder.icon="" end;self:ClearFocus();RC:SaveConfigurationToProfile() end)
        y=Row(content,y,"  OR Item ID",iib,NBOX_W,LBL_W)

        y=y-4;y=SecLabel(content,y,"Timing");y=y-4
        local durb=Input(content,NBOX_W,20);durb:SetText(tostring(reminder.duration or 5))
        durb:SetScript("OnEnterPressed",function(self) reminder.duration=tonumber(self:GetText()) or 5;self:ClearFocus();RC:SaveConfigurationToProfile() end)
        y=Row(content,y,"Duration sec  (0=persistent)",durb,NBOX_W,LBL_W)
        local cdb=Input(content,NBOX_W,20);cdb:SetText(tostring(reminder.cooldown or 10))
        cdb:SetScript("OnEnterPressed",function(self) reminder.cooldown=tonumber(self:GetText()) or 10;self:ClearFocus();RC:SaveConfigurationToProfile() end)
        y=Row(content,y,"Cooldown sec",cdb,NBOX_W,LBL_W)

        local contCB=RC.UI:CreateCheckbox(content,RCL["Continuous (refresh while condition is true)"],reminder.continuous or false)
        contCB:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y+1)
        contCB:SetScript("OnClick",function(self) reminder.continuous=self:GetChecked();RC:ForceCheckboxUpdate(self,reminder.continuous);RC:SaveConfigurationToProfile() end)
        y=y-ROW_H
        y=HintLine(content,y,"Leave this off for most alerts. Turn it on if you want the popup to stay pinned the entire time the condition is true (rather than fading on its own duration). Either way, reminders auto-hide the moment the condition becomes false.")

        local PRIORITY_ITEMS={}
        for i=1,10 do
            local lbl=i==1 and "1 - Highest" or i==10 and "10 - Lowest" or tostring(i)
            table.insert(PRIORITY_ITEMS,{text=lbl,value=tostring(i)})
        end
        local _,yp=DropRow(content,y,"Priority",PRIORITY_ITEMS,tostring(reminder.priority or 5),function(v)
            reminder.priority=tonumber(v) or 5;RC:SaveConfigurationToProfile()
        end,120,LBL_W);y=yp

        y=y-4;y=SecLabel(content,y,"Sound");y=y-4
        local sndItems,sndFM=BuildSoundItems()
        local PREV_RESERVED=65+PAD+PAD
        local sndDropW=math.max(80,_EW-(LBL_W+PAD+PAD)-PREV_RESERVED)
        local sndDrop=DropAt(content,LBL_W+PAD+PAD,y,sndItems,reminder.soundKey or "",sndDropW,function(val)
            reminder.soundKey=val;reminder.soundFile=sndFM[val] or "";RC:SaveConfigurationToProfile()
        end)
        sndDrop:SetSelectedValue(reminder.soundKey or "",ResolveSoundLabel(reminder.soundKey))
        Row(content,y,"Sound",nil,0,LBL_W)
        local prevBtn=Btn(content,"Preview",65,20);prevBtn:SetPoint("TOPRIGHT",content,"TOPRIGHT",-PAD,y+1)
        prevBtn:SetScript("OnClick",function()
            local f=reminder.soundFile and reminder.soundFile~="" and reminder.soundFile
                 or (RC.LSM and RC.LSM:Fetch("sound",reminder.soundKey))
            if f then PlaySoundFile(f,"Master") end
        end)
        y=y-ROW_H

        local ttsCB=RC.UI:CreateCheckbox(content,RCL["Speak with TTS when this reminder fires"],reminder.ttsEnabled or false)
        ttsCB:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y+1)
        ttsCB:SetScript("OnClick",function(self)
            reminder.ttsEnabled=self:GetChecked();RC:ForceCheckboxUpdate(self,reminder.ttsEnabled);RC:SaveConfigurationToProfile()
        end)
        y=y-ROW_H

        local ttsInputW=math.max(120,_EW-(LBL_W+PAD+PAD)-(65+PAD+PAD))
        local ttsInput=Input(content,ttsInputW,20)
        ttsInput:SetText(reminder.ttsText or "")
        ttsInput:SetScript("OnEnterPressed",function(self)
            reminder.ttsText=self:GetText() or "";self:ClearFocus();RC:SaveConfigurationToProfile()
        end)
        local origTtsFocusLost=ttsInput:GetScript("OnEditFocusLost")
        ttsInput:SetScript("OnEditFocusLost",function(self,...)
            reminder.ttsText=self:GetText() or "";RC:SaveConfigurationToProfile()
            if origTtsFocusLost then origTtsFocusLost(self,...) end
        end)
        y=Row(content,y,"TTS text",ttsInput,ttsInputW,LBL_W)
        local ttsTestBtn=Btn(content,"Test",65,20);ttsTestBtn:SetPoint("TOPRIGHT",content,"TOPRIGHT",-PAD,y+ROW_H+1)
        ttsTestBtn:SetScript("OnClick",function()
            local spoken=(reminder.ttsText and reminder.ttsText~="") and reminder.ttsText or (reminder.name or "Reminder")
            if RC.SpeakTTSPreview then RC:SpeakTTSPreview(spoken,false) end
        end)
        y=HintLine(content,y,"Leave the text blank to speak the reminder's name. Needs 'Enable voice alerts (TTS)' switched on to fire in play; the Test button previews it either way.")

        -- Every RC.Motion style; the popup plays it for this reminder in
        -- and out (abilityOverrides["custom_<id>"].animationType).
        local ANIM_ITEMS={{text=RCL["Global default"],value=""}}
        for _,st in ipairs((RC.Motion and RC.Motion.STYLES) or {}) do
            ANIM_ITEMS[#ANIM_ITEMS+1]={text=st.label,value=st.id}
        end
        local curAnim=reminder.animationType
        if curAnim and curAnim~="" and RC.Motion then curAnim=RC.Motion.StyleFromLegacy(curAnim) end
        local _,ya=DropRow(content,y,"Animation",ANIM_ITEMS,curAnim or "",function(v)
            reminder.animationType=(v=="")and nil or v
            -- the popup reads the override written at fire time; keep a
            -- reminder already up to date without waiting for it to fire
            local ao=RC.db.abilityOverrides and RC.db.abilityOverrides["custom_"..reminder.id]
            if type(ao)=="table" then ao.animationType=reminder.animationType or RC.db.animationType or "fade" end
            RC:SaveConfigurationToProfile()
        end,120,LBL_W);y=ya
        y=HintLine(content,y,"Global default plays the Reminder Settings animation. The preview's Replay shows this one.")

    elseif tabKey=="trigger" then
        y=SecLabel(content,y,"Trigger Type");y=y-4
        reminder.mode=reminder.mode or "aura"
        local modeDrop,ny=DropRow(content,y,"Mode",MODE_ITEMS,reminder.mode,function(val)
            reminder.mode=val;RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame)
        end,nil,LBL_W)
        y=ny;y=y-4

        local mode=reminder.mode

        if mode=="aura" then
            reminder.aura=reminder.aura or {unit="player",buffType="buff",spellId=nil,condition="missing",expiresIn=5,stackValue=1,untrigger="auto"}
            local cfg=reminder.aura
            y=SecLabel(content,y,"Aura Trigger");y=y-4

            local _,y2=DropRow(content,y,"Unit",UNIT_ITEMS,cfg.unit,function(v) cfg.unit=v;RC:SaveConfigurationToProfile() end,nil,LBL_W);y=y2
            local _,y3=DropRow(content,y,"Type",BUFF_TYPE_ITEMS,cfg.buffType,function(v) cfg.buffType=v;RC:SaveConfigurationToProfile() end,nil,LBL_W);y=y3

            local sidBox=Input(content,NBOX_W,20);sidBox:SetText(cfg.spellId and tostring(cfg.spellId) or "")
            sidBox:SetScript("OnEnterPressed",function(self) cfg.spellId=tonumber(self:GetText());self:ClearFocus();RC:SaveConfigurationToProfile() end)
            y=Row(content,y,"Spell ID  (blank=any)",sidBox,NBOX_W,LBL_W)

            local _,y4=DropRow(content,y,"Condition",AURA_COND_ITEMS,cfg.condition,function(v)
                cfg.condition=v;RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame)
            end,nil,LBL_W);y=y4

            if cfg.condition=="expiring" then
                local ex=Input(content,NBOX_W,20);ex:SetText(tostring(cfg.expiresIn or 5))
                ex:SetScript("OnEnterPressed",function(self) cfg.expiresIn=tonumber(self:GetText()) or 5;self:ClearFocus();RC:SaveConfigurationToProfile() end)
                y=Row(content,y,"Fire when < N sec",ex,NBOX_W,LBL_W)
            end
            if cfg.condition=="stacks_above" or cfg.condition=="stacks_below" then
                local st=Input(content,NBOX_W,20);st:SetText(tostring(cfg.stackValue or 1))
                st:SetScript("OnEnterPressed",function(self) cfg.stackValue=tonumber(self:GetText()) or 1;self:ClearFocus();RC:SaveConfigurationToProfile() end)
                y=Row(content,y,"Stack count N",st,NBOX_W,LBL_W)
            end

            y=y-4;y=SecLabel(content,y,"Untrigger (when to stop firing)");y=y-4
            cfg.untrigger=cfg.untrigger or "auto"
            local _,yu=DropRow(content,y,"Untrigger",AURA_UNTRIG_ITEMS,cfg.untrigger,function(v)
                cfg.untrigger=v;RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame)
            end,nil,LBL_W);y=yu

            if cfg.untrigger=="custom" then
                local ub=Input(content,NBOX_W,20);ub:SetText(cfg.untriggerSpellId and tostring(cfg.untriggerSpellId) or "")
                ub:SetScript("OnEnterPressed",function(self) cfg.untriggerSpellId=tonumber(self:GetText());self:ClearFocus();RC:SaveConfigurationToProfile() end)
                y=Row(content,y,"Untrig Spell ID",ub,NBOX_W,LBL_W)
            end
            y=HintLine(content,y,"Auto = opposite of trigger condition. Continuous mode uses this to dismiss the reminder.")

        elseif mode=="cooldown" then
            reminder.cdConfig=reminder.cdConfig or {spellId=nil,itemId=nil,condition="ready",threshold=5}
            local cfg=reminder.cdConfig
            y=SecLabel(content,y,"Cooldown Trigger");y=y-4
            local sb=Input(content,NBOX_W,20);sb:SetText(cfg.spellId and tostring(cfg.spellId) or "")
            sb:SetScript("OnEnterPressed",function(self) cfg.spellId=tonumber(self:GetText());self:ClearFocus();RC:SaveConfigurationToProfile() end)
            y=Row(content,y,"Spell ID",sb,NBOX_W,LBL_W)
            local ib=Input(content,NBOX_W,20);ib:SetText(cfg.itemId and tostring(cfg.itemId) or "")
            ib:SetScript("OnEnterPressed",function(self) cfg.itemId=tonumber(self:GetText());self:ClearFocus();RC:SaveConfigurationToProfile() end)
            y=Row(content,y,"  OR Item ID",ib,NBOX_W,LBL_W)
            local _,y2=DropRow(content,y,"Condition",CD_COND_ITEMS,cfg.condition,function(v)
                cfg.condition=v;RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame)
            end,nil,LBL_W);y=y2
            if cfg.condition=="below_n_sec" or cfg.condition=="above_n_sec" then
                local th=Input(content,NBOX_W,20);th:SetText(tostring(cfg.threshold or 5))
                th:SetScript("OnEnterPressed",function(self) cfg.threshold=tonumber(self:GetText()) or 5;self:ClearFocus();RC:SaveConfigurationToProfile() end)
                y=Row(content,y,"N seconds",th,NBOX_W,LBL_W)
            end

        elseif mode=="health" then
            reminder.health=reminder.health or {unit="player",op="<",value=30}
            local cfg=reminder.health
            y=SecLabel(content,y,"Health Threshold");y=y-4
            local _,y2=DropRow(content,y,"Unit",UNIT_ITEMS,cfg.unit,function(v) cfg.unit=v;RC:SaveConfigurationToProfile() end,nil,LBL_W);y=y2
            local _,y3=DropRow(content,y,"Operator",OP_ITEMS,cfg.op,function(v) cfg.op=v;RC:SaveConfigurationToProfile() end,nil,LBL_W);y=y3
            local vb=Input(content,NBOX_W,20);vb:SetText(tostring(cfg.value or 30))
            vb:SetScript("OnEnterPressed",function(self) cfg.value=tonumber(self:GetText()) or 30;self:ClearFocus();RC:SaveConfigurationToProfile() end)
            y=Row(content,y,"HP percent",vb,NBOX_W,LBL_W)

        elseif mode=="resource" then
            reminder.resource=reminder.resource or {unit="player",powerType=1,op=">",value=80,usePercent=false}
            local cfg=reminder.resource
            y=SecLabel(content,y,"Resource / Power");y=y-4
            local _,y2=DropRow(content,y,"Unit",UNIT_ITEMS,cfg.unit,function(v) cfg.unit=v;RC:SaveConfigurationToProfile() end,nil,LBL_W);y=y2
            local _,y3=DropRow(content,y,"Resource",POWER_ITEMS,tostring(cfg.powerType or 1),function(v) cfg.powerType=tonumber(v);RC:SaveConfigurationToProfile() end,nil,LBL_W);y=y3
            local _,y4=DropRow(content,y,"Operator",OP_ITEMS,cfg.op,function(v) cfg.op=v;RC:SaveConfigurationToProfile() end,nil,LBL_W);y=y4
            local vb=Input(content,NBOX_W,20);vb:SetText(tostring(cfg.value or 0))
            vb:SetScript("OnEnterPressed",function(self) cfg.value=tonumber(self:GetText()) or 0;self:ClearFocus();RC:SaveConfigurationToProfile() end)
            y=Row(content,y,"Value",vb,NBOX_W,LBL_W)
            local pctCB=RC.UI:CreateCheckbox(content,RCL["Use percent (%)"],cfg.usePercent or false)
            pctCB:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y+1)
            pctCB:SetScript("OnClick",function(self) cfg.usePercent=self:GetChecked();RC:ForceCheckboxUpdate(self,cfg.usePercent);RC:SaveConfigurationToProfile() end)
            y=y-ROW_H

        elseif mode=="status" then
            reminder.status=reminder.status or {type="in_combat"}
            y=SecLabel(content,y,"Status Condition");y=y-4
            local _,y2=DropRow(content,y,"Condition",STATUS_ITEMS,reminder.status.type,function(v) reminder.status.type=v;RC:SaveConfigurationToProfile() end,nil,LBL_W);y=y2

        elseif mode=="event" then
            reminder.eventTrigger=reminder.eventTrigger or {eventCategory="frame",frameEvent="RAID_BOSS_EMOTE",customEvent="",textMatch="",unitFilter="",spellId=nil}
            local cfg=reminder.eventTrigger
            cfg.eventCategory="frame"
            y=SecLabel(content,y,"Event Trigger");y=y-4
            y=HintLine(content,y,"React to WoW Game Events: boss emotes, unit changes, chat, encounter start/end, or any custom event you type in.")

            do
                y=SecLabel(content,y,"Game Event");y=y-4
                local FRAME_EVENT_ITEMS={
                    {text=RCL["Boss emote  (RAID_BOSS_EMOTE)"],              value="RAID_BOSS_EMOTE"},
                    {text=RCL["Boss whisper  (RAID_BOSS_WHISPER)"],           value="RAID_BOSS_WHISPER"},
                    {text=RCL["Monster yell  (CHAT_MSG_MONSTER_YELL)"],       value="CHAT_MSG_MONSTER_YELL"},
                    {text=RCL["Monster say  (CHAT_MSG_MONSTER_SAY)"],         value="CHAT_MSG_MONSTER_SAY"},
                    {text=RCL["Monster emote  (CHAT_MSG_MONSTER_EMOTE)"],     value="CHAT_MSG_MONSTER_EMOTE"},
                    {text=RCL["Encounter start  (ENCOUNTER_START)"],          value="ENCOUNTER_START"},
                    {text=RCL["Encounter end  (ENCOUNTER_END)"],              value="ENCOUNTER_END"},
                    {text=RCL["Unit aura changed  (UNIT_AURA)"],              value="UNIT_AURA"},
                    {text=RCL["Unit health  (UNIT_HEALTH)"],                  value="UNIT_HEALTH"},
                    {text=RCL["Unit cast start  (UNIT_SPELLCAST_START)"],     value="UNIT_SPELLCAST_START"},
                    {text=RCL["Unit cast done  (UNIT_SPELLCAST_SUCCEEDED)"],  value="UNIT_SPELLCAST_SUCCEEDED"},
                    {text=RCL["Entered combat  (PLAYER_REGEN_DISABLED)"],     value="PLAYER_REGEN_DISABLED"},
                    {text=RCL["Left combat  (PLAYER_REGEN_ENABLED)"],         value="PLAYER_REGEN_ENABLED"},
                    {text=RCL["Target changed  (PLAYER_TARGET_CHANGED)"],     value="PLAYER_TARGET_CHANGED"},
                    {text=RCL["Equipment changed  (PLAYER_EQUIPMENT_CHANGED)"],value="PLAYER_EQUIPMENT_CHANGED"},
                    {text=RCL["Player died  (PLAYER_DEAD)"],                  value="PLAYER_DEAD"},
                    {text=RCL["Player respawned  (PLAYER_ALIVE)"],            value="PLAYER_ALIVE"},
                    {text=RCL["Custom - type event name below"],              value="CUSTOM"},
                }
                local _,y2=DropRow(content,y,"Event",FRAME_EVENT_ITEMS,cfg.frameEvent or "RAID_BOSS_EMOTE",function(v)
                    cfg.frameEvent=v;RC:SaveConfigurationToProfile()
                    -- Event-mode reminders register their own event listeners;
                    -- changing which event to watch requires re-subscribing.
                    if RC.RefreshCustomReminderEvents then RC:RefreshCustomReminderEvents() end
                    RC:CR_RenderTab(panel,reminder,"trigger",mainFrame)
                end,nil,LBL_W);y=y2

                if cfg.frameEvent=="CUSTOM" then
                    y=y-4
                    local gt=RC:GetColor("text","disabled")
                    local evLbl=MakeFS(content,10,"");evLbl:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);evLbl:SetWidth(LBL_W);evLbl:SetTextColor(gt.r,gt.g,gt.b,1);evLbl:SetText(RCL["Event name"])
                    local evBox=Input(content,80,20);evBox:SetPoint("TOPLEFT",content,"TOPLEFT",LBL_W+PAD+PAD,y+1);evBox:SetWidth(math.max(60, _EW-LBL_W-PAD*3))
                    evBox:SetText(cfg.customEvent or "")
                    evBox:SetScript("OnEnterPressed",function(self)
                        cfg.customEvent=self:GetText():upper():gsub("%s","_");self:ClearFocus()
                        RC:SaveConfigurationToProfile()
                        if RC.RefreshCustomReminderEvents then RC:RefreshCustomReminderEvents() end
                        RC:CR_RenderTab(panel,reminder,"trigger",mainFrame)
                    end);y=y-ROW_H
                    y=HintLine(content,y,"Type any valid WoW event name (e.g. SPELL_UPDATE_COOLDOWN, PLAYER_UNGHOST). Case doesn't matter.")
                end

                local isChatEvent = cfg.frameEvent and (cfg.frameEvent:find("EMOTE") or cfg.frameEvent:find("CHAT_MSG") or cfg.frameEvent:find("WHISPER") or cfg.frameEvent:find("YELL") or cfg.frameEvent:find("SAY") or cfg.frameEvent=="CUSTOM")
                if isChatEvent then
                    y=y-4
                    local gt=RC:GetColor("text","disabled")
                    local tmLbl=MakeFS(content,10,"");tmLbl:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);tmLbl:SetWidth(LBL_W);tmLbl:SetTextColor(gt.r,gt.g,gt.b,1);tmLbl:SetText(RCL["Text match"])
                    local tmBox=Input(content,80,20);tmBox:SetPoint("TOPLEFT",content,"TOPLEFT",LBL_W+PAD+PAD,y+1);tmBox:SetWidth(math.max(60, _EW-LBL_W-PAD*3))
                    tmBox:SetText(cfg.textMatch or "")
                    tmBox:SetScript("OnEnterPressed",function(self) cfg.textMatch=self:GetText();self:ClearFocus();RC:SaveConfigurationToProfile() end)
                    y=y-ROW_H
                    y=HintLine(content,y,"Case-insensitive partial match against the event text. Example: \"Frost Blast\" catches KT's emote. Blank = any text.")
                end

                local isUnitEvent = cfg.frameEvent and cfg.frameEvent:find("^UNIT_")
                if isUnitEvent then
                    y=y-4
                    local _,yu=DropRow(content,y,"Unit filter",UNIT_ITEMS,cfg.unitFilter or "",function(v)
                        cfg.unitFilter=v;RC:SaveConfigurationToProfile()
                    end,nil,LBL_W);y=yu
                    y=HintLine(content,y,"Only fires when the event affects this unit.")
                end

                y=HintLine(content,y,"Game events fire immediately when WoW raises them. Cooldown applies between fires.")
            end

        elseif mode=="condition" then
            reminder.conditions=reminder.conditions or {}
            local cl=reminder.conditions
            y=SecLabel(content,y,"AND Conditions - all must be true (max 8)");y=y-4
            for idx,cond in ipairs(cl) do
                local i=idx
                local nm=MakeFS(content,10,"OUTLINE");nm:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y)
                local gc=RC:GetColor("ui","headerText");nm:SetTextColor(gc.r*0.8,gc.g*0.8,gc.b*0.8,1);nm:SetText(RCL["Cond "]..idx)
                local xb=RC.UI:CreateXCloseButton(content,20,function()
                    table.remove(cl,i);RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame)
                end);xb:SetPoint("TOPRIGHT",content,"TOPRIGHT",-PAD,y)
                local cdW=math.max(80,_EW-(PAD+60)-20-PAD*2)
                local cd=DropAt(content,PAD+60,y,COND_TYPE_ITEMS,cond.type,cdW,function(v)
                    cl[i].type=v;cl[i].spellId=nil;cl[i].spellId2=nil;cl[i].value=nil;cl[i].unit="player";cl[i].spellName=nil;cl[i].itemId=nil;cl[i].slot=nil;cl[i].stanceIndex=nil;cl[i].specKey=nil
                    RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame)
                end);y=y-ROW_H
                y=RenderCondFields(content,cond,y,function() RC:SaveConfigurationToProfile() end,nil,90)
                y=y-4
            end
            if #cl<8 then
                local ab=Btn(content,"+ Add Condition",130,22);ab:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y)
                ab:SetScript("OnClick",function() table.insert(cl,{type="in_combat",unit="player"});RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame) end)
                y=y-30
            end

        elseif mode=="equipment" then
            reminder.equipment=reminder.equipment or {slot=16,condition="not_equipped",itemId=nil,value=nil}
            local cfg=reminder.equipment
            y=SecLabel(content,y,"Equipment Trigger");y=y-4
            y=HintLine(content,y,"Check item in slot, weapon enchants, item cooldowns, or character stats. Great for pre-fight gear checks and consumable enchant reminders.")

            local EQUIP_SLOT_ITEMS={
                {text=RCL["Main Hand (16)"],   value="16"}, {text=RCL["Off Hand (17)"],    value="17"},
                {text=RCL["Ranged (18)"],      value="18"}, {text=RCL["Head (1)"],         value="1"},
                {text=RCL["Neck (2)"],         value="2"},  {text=RCL["Shoulder (3)"],     value="3"},
                {text=RCL["Chest (5)"],        value="5"},  {text=RCL["Waist (6)"],        value="6"},
                {text=RCL["Legs (7)"],         value="7"},  {text=RCL["Feet (8)"],         value="8"},
                {text=RCL["Wrist (9)"],        value="9"},  {text=RCL["Hands (10)"],       value="10"},
                {text=RCL["Ring 1 (11)"],      value="11"}, {text=RCL["Ring 2 (12)"],      value="12"},
                {text=RCL["Trinket 1 (13)"],   value="13"}, {text=RCL["Trinket 2 (14)"],   value="14"},
                {text=RCL["Back (15)"],        value="15"},
            }
            local EQUIP_COND_ITEMS={
                {text=RCL["Item IS equipped"],                   value="equipped"},
                {text=RCL["Item NOT equipped"],                  value="not_equipped"},
                {text=RCL["Item off cooldown (ready)"],          value="item_ready"},
                {text=RCL["Item on cooldown"],                   value="item_on_cd"},
                {text=RCL["Has temporary weapon enchant"],       value="has_temp_enchant"},
                {text=RCL["MISSING temporary weapon enchant"],   value="no_temp_enchant"},
                {text=RCL["Attack Power above N"],               value="stat_ap_above"},
                {text=RCL["Attack Power below N"],               value="stat_ap_below"},
                {text=RCL["Crit chance above N%"],               value="stat_crit_above"},
                {text=RCL["Hit rating above N"],                 value="stat_hit_above"},
                {text=RCL["Hit rating below N"],                 value="stat_hit_below"},
            }
            local _,yslot=DropRow(content,y,"Slot",EQUIP_SLOT_ITEMS,cfg.slot and tostring(cfg.slot) or "16",function(v)
                cfg.slot=tonumber(v);RC:SaveConfigurationToProfile()
            end,nil,LBL_W);y=yslot

            local _,ycond=DropRow(content,y,"Condition",EQUIP_COND_ITEMS,cfg.condition or "not_equipped",function(v)
                cfg.condition=v;RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame)
            end,nil,LBL_W);y=ycond

            local c=cfg.condition or "not_equipped"
            if c=="equipped" or c=="not_equipped" then
                local ib=Input(content,NBOX_W,20);ib:SetText(cfg.itemId and tostring(cfg.itemId) or "")
                ib:SetScript("OnEnterPressed",function(self) cfg.itemId=tonumber(self:GetText());self:ClearFocus();RC:SaveConfigurationToProfile() end)
                y=Row(content,y,"Item ID  (blank=any)",ib,NBOX_W,LBL_W)
                y=HintLine(content,y,"Leave blank to check if ANY item is in the slot. Useful for: 'Alert if Off-Hand slot is empty'.")
            elseif c=="has_temp_enchant" or c=="no_temp_enchant" then
                y=HintLine(content,y,"Checks temporary enchants: sharpening stones, wizard oil, Windfury/poisons (Shaman/Rogue). Select Main Hand or Off Hand slot.")
            elseif c:find("^stat_") then
                local vb=Input(content,NBOX_W,20);vb:SetText(cfg.value and tostring(cfg.value) or "")
                vb:SetScript("OnEnterPressed",function(self) cfg.value=tonumber(self:GetText());self:ClearFocus();RC:SaveConfigurationToProfile() end)
                y=Row(content,y,"Threshold (N)",vb,NBOX_W,LBL_W)
                y=HintLine(content,y,"Uses live character sheet values. Useful for checking if world buffs/consumables pushed your stats above a threshold.")
            end

        elseif mode=="periodic" then
            reminder.periodic=reminder.periodic or {intervalSec=30}
            local cfg=reminder.periodic
            y=SecLabel(content,y,"Periodic Trigger");y=y-4
            y=HintLine(content,y,"Fires every N seconds while the reminder is active. Load conditions and Extra Conditions still apply. Use for recurring reminders during a fight (e.g. every 30s: 'check your cooldowns').")
            local ib=Input(content,NBOX_W,20);ib:SetText(tostring(cfg.intervalSec or 30))
            ib:SetScript("OnEnterPressed",function(self)
                cfg.intervalSec=math.max(1, tonumber(self:GetText()) or 30);self:ClearFocus();RC:SaveConfigurationToProfile()
            end)
            y=Row(content,y,"Interval (sec)",ib,NBOX_W,LBL_W)
            y=HintLine(content,y,"Minimum 1 second. Unlike other triggers, no cooldown field - the interval IS the cooldown.")

        elseif mode=="sequence" then
            reminder.sequence=reminder.sequence or {step=1,steps={}}
            local steps=reminder.sequence.steps
            y=SecLabel(content,y,"Sequence Steps");y=y-4
            for sidx,step in ipairs(steps) do
                local si=sidx
                local gc=RC:GetColor("ui","headerText")
                local shdr=MakeFS(content,9,"OUTLINE");shdr:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);shdr:SetTextColor(gc.r*0.8,gc.g*0.8,gc.b*0.8,1);shdr:SetText(RCL["Step "]..sidx);y=y-16
                local xr=RC.UI:CreateXCloseButton(content,20,function() table.remove(steps,si);RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame) end)
                xr:SetPoint("TOPRIGHT",content,"TOPRIGHT",-PAD,y+16)
                local sd=DropAt(content,PAD,y,STEP_TYPE_ITEMS,step.type,nil,function(v) steps[si].type=v;RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame) end);y=y-ROW_H
                local sm=Input(content,80,20);sm:SetPoint("TOPLEFT",content,"TOPLEFT",PAD+90,y+1);sm:SetWidth(math.max(60, _EW-PAD-90-PAD));sm:SetText(step.message or "")
                Row(content,y,"  Message",nil,0,90);sm:SetScript("OnEnterPressed",function(self) steps[si].message=self:GetText();self:ClearFocus();RC:SaveConfigurationToProfile() end);y=y-ROW_H
                if step.type=="timer" then
                    local db=Input(content,NBOX_W,20);db:SetText(tostring(step.delay or 5))
                    db:SetScript("OnEnterPressed",function(self) steps[si].delay=tonumber(self:GetText()) or 5;self:ClearFocus();RC:SaveConfigurationToProfile() end)
                    y=Row(content,y,"  Delay (sec)",db,NBOX_W,90)
                end
                if step.type=="condition" then
                    step.condition=step.condition or {type="hp_below",unit="target",value=20}
                    local si2=sidx
                    local scd=DropAt(content,PAD+90,y,COND_TYPE_ITEMS,step.condition.type,nil,function(v)
                        steps[si2].condition=steps[si2].condition or {};steps[si2].condition.type=v;RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame)
                    end);Row(content,y,"  Condition",nil,0,90);y=y-ROW_H
                    local sv=Input(content,NBOX_W,20);sv:SetText(step.condition.value and tostring(step.condition.value) or "")
                    sv:SetScript("OnEnterPressed",function(self) steps[si2].condition=steps[si2].condition or {};steps[si2].condition.value=tonumber(self:GetText());self:ClearFocus();RC:SaveConfigurationToProfile() end)
                    y=Row(content,y,"  Value (N)",sv,NBOX_W,90)
                end
                y=y-4
            end
            local asb=Btn(content,"+ Add Step",100,22);asb:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y)
            asb:SetScript("OnClick",function() table.insert(steps,{type="timer",delay=5,message=""});RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame) end)

        elseif mode=="lua" then
            reminder.lua=reminder.lua or {code="return false",compiledFn=nil,lastError=nil,errorCount=0}
            local ld=reminder.lua
            y=SecLabel(content,y,"Lua Code - return true to fire");y=y-4
            y=HintLine(content,y,"WR_class() WR_spec() WR_hasBuff(unit,sid) WR_hasDebuff(unit,sid)\nWR_cdReady(sid) WR_healthPct(unit) WR_rage() WR_mana() WR_energy()\nWR_realtimeTTK() WR_predictedTTK() WR_fightDuration() WR_inCombat()\nAll WoW read-only APIs: UnitBuff, UnitHealth, GetSpellCooldown, IsInRaid...")
            y=y-38
            local csf=CreateFrame("ScrollFrame",nil,content)
            csf:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);csf:SetPoint("TOPRIGHT",content,"TOPRIGHT",-PAD,y);csf:SetHeight(160)
            local ceb=CreateFrame("EditBox",nil,csf);ceb:SetPoint("TOPLEFT",csf,"TOPLEFT",0,0);ceb:SetPoint("TOPRIGHT",csf,"TOPRIGHT",-14,0);ceb:SetHeight(160)
            ceb:SetMultiLine(true);ceb:SetAutoFocus(false);if RC.ApplyCustomFont then RC:ApplyCustomFont(ceb,10,"") end
            ceb:SetTextInsets(4,4,4,4);ceb:EnableMouse(true);csf:SetScrollChild(ceb);ceb:SetText(ld.code or RCL["return false"])
            local cbg=RC:GetColor("ui","elementBackground");local csfbg=csf:CreateTexture(nil,"BACKGROUND");csfbg:SetAllPoints()
            csfbg:SetTexture(RC.UI.FLAT);csfbg:SetVertexColor(cbg.r,cbg.g,cbg.b,1);RC.UI:CreateSimpleBorder(csf);y=y-166
            local ef=MakeFS(content,9,"");ef:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);ef:SetPoint("TOPRIGHT",content,"TOPRIGHT",-PAD,y);ef:SetJustifyH("LEFT")
            if ld.lastError then ef:SetText(RCL["|cFFFF4444Error: "]..ld.lastError.."|r")
            elseif (ld.errorCount or 0)>=5 then ef:SetText(RCL["|cFFFF8800Stopped after 5 errors - edit and Apply to reset.|r"])
            else ef:SetText(RCL["|cFF44FF44No errors|r"]) end;y=y-18
            local apb=Btn(content,"Apply & Compile",130,22);apb:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y)
            -- Clears compiledFn/errorCount so RecompileCustomReminder() must
            -- re-parse and sandbox the edited code before it runs again.
            apb:SetScript("OnClick",function() ld.code=ceb:GetText();ld.compiledFn=nil;ld.errorCount=0;ld.lastError=nil;RC:RecompileCustomReminder(reminder.id);RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"trigger",mainFrame) end)
        end

    elseif tabKey=="extra" then
        reminder.extraConditions=reminder.extraConditions or {}
        local ec=reminder.extraConditions
        y=SecLabel(content,y,"Additional AND Conditions");y=y-4
        y=HintLine(content,y,"Apply on top of ANY trigger type. All must pass. Max 8.")
        for idx,cond in ipairs(ec) do
            local i=idx
            local gc=RC:GetColor("ui","headerText")
            local nm=MakeFS(content,10,"OUTLINE");nm:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);nm:SetTextColor(gc.r*0.8,gc.g*0.8,gc.b*0.8,1);nm:SetText(RCL["Cond "]..idx)
            local xb=RC.UI:CreateXCloseButton(content,20,function() table.remove(ec,i);RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"extra",mainFrame) end)
            xb:SetPoint("TOPRIGHT",content,"TOPRIGHT",-PAD,y)
            local ecW=math.max(80,_EW-(PAD+60)-20-PAD*2)
            DropAt(content,PAD+60,y,COND_TYPE_ITEMS,cond.type,ecW,function(v)
                ec[i].type=v;ec[i].spellId=nil;ec[i].spellId2=nil;ec[i].value=nil;ec[i].unit="player";ec[i].spellName=nil;ec[i].itemId=nil;ec[i].slot=nil;ec[i].stanceIndex=nil;ec[i].specKey=nil
                RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"extra",mainFrame)
            end);y=y-ROW_H
            y=RenderCondFields(content,cond,y,function() RC:SaveConfigurationToProfile() end,nil,90)
            y=y-4
        end
        if #ec<8 then
            local ab=Btn(content,"+ Add Condition",130,22);ab:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y)
            ab:SetScript("OnClick",function() table.insert(ec,{type="in_combat",unit="player"});RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"extra",mainFrame) end)
        end

    elseif tabKey=="load" then
        y=SecLabel(content,y,"Load Conditions - when this reminder is active");y=y-4
        y=HintLine(content,y,"Prevents ALL evaluation when conditions don't match. Use for class/role-specific reminders.")

        local curClass=reminder.loadClass or ""
        local _,yc=DropRow(content,y,"Class",CLASS_ITEMS,curClass,function(v)
            reminder.loadClass=(v=="")and nil or v
            if v~="WARRIOR" then reminder.loadSpec=nil end
            RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"load",mainFrame)
        end,nil,LBL_W);y=yc

        local specItems=GetSpecItems(curClass)
        local curSpec=reminder.loadSpec or ""
        if curClass=="WARRIOR" then
            local _,ys=DropRow(content,y,"Spec (WR detected)",specItems,curSpec,function(v)
                reminder.loadSpec=(v=="")and nil or v;RC:SaveConfigurationToProfile()
            end,nil,LBL_W);y=ys
        else
            local specHint=MakeFS(content,9,"")
            specHint:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y)
            local gt=RC:GetColor("text","disabled");specHint:SetTextColor(gt.r,gt.g,gt.b,0.8)
            specHint:SetText(RCL["Spec detection only available for Warrior class."])
            y=y-18
        end

        local _,yg=DropRow(content,y,"Group type",GROUP_ITEMS,reminder.loadGroup or "",function(v) reminder.loadGroup=(v=="")and nil or v;RC:SaveConfigurationToProfile() end,nil,LBL_W);y=yg
        local _,yz=DropRow(content,y,"Zone type",ZONE_ITEMS,reminder.loadZone or "",function(v) reminder.loadZone=(v=="")and nil or v;RC:SaveConfigurationToProfile() end,nil,LBL_W);y=yz

        local znLbl=MakeFS(content,10,"");znLbl:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);znLbl:SetWidth(LBL_W)
        local gt=RC:GetColor("text","disabled");znLbl:SetTextColor(gt.r,gt.g,gt.b,1);znLbl:SetText(RCL["Zone name"])
        local znBox=Input(content,80,20);znBox:SetPoint("TOPLEFT",content,"TOPLEFT",LBL_W+PAD+PAD,y+1);znBox:SetWidth(math.max(60, _EW-LBL_W-PAD*3))
        znBox:SetText(reminder.loadZoneName or "")
        znBox:SetScript("OnEnterPressed",function(self) reminder.loadZoneName=self:GetText();if reminder.loadZoneName=="" then reminder.loadZoneName=nil end;self:ClearFocus();RC:SaveConfigurationToProfile() end)
        y=y-ROW_H
        y=HintLine(content,y,"Partial zone/subzone match (e.g. 'Naxxramas', 'Molten Core', 'Alterac'). Stacks with Zone type above.")

        y=y-4;y=SecLabel(content,y,"Fight Scope");y=y-4
        local _,ys2=DropRow(content,y,"Fires during",SCOPE_ITEMS,reminder.scope or "any",function(v)
            reminder.scope=v;if v~="boss" then reminder.bossKey=nil;reminder.customNpcIds={} end
            RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"load",mainFrame)
        end,nil,LBL_W);y=ys2

        if reminder.scope=="boss" then
            y=y-4;y=SecLabel(content,y,"Boss Restriction (optional)");y=y-4
            y=HintLine(content,y,"Select a WR-configured boss OR enter custom NPC IDs. Both optional - blank means any boss fight.")
            local _,yb=DropRow(content,y,"WR Boss",BuildBossItems(),reminder.bossKey or "",function(v)
                reminder.bossKey=(v=="")and nil or v;if v and v~="" then reminder.customNpcIds={} end
                RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"load",mainFrame)
            end,nil,LBL_W);y=yb

            local gt=RC:GetColor("text","disabled")
            local npcLbl=MakeFS(content,10,"");npcLbl:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);npcLbl:SetWidth(LBL_W);npcLbl:SetTextColor(gt.r,gt.g,gt.b,1);npcLbl:SetText(RCL["Custom NPC IDs"])
            local npcHint=MakeFS(content,9,"");npcHint:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y-14);npcHint:SetPoint("TOPRIGHT",content,"TOPRIGHT",-PAD,y-14)
            npcHint:SetTextColor(gt.r,gt.g,gt.b,0.8);npcHint:SetText(RCL["Comma-separated (e.g. 15990,15991). Overrides WR Boss above."])
            y=y-32
            local currentIds=""
            if reminder.customNpcIds and #reminder.customNpcIds>0 then
                local parts={};for _,id in ipairs(reminder.customNpcIds) do table.insert(parts,tostring(id)) end
                currentIds=table.concat(parts,", ")
            end
            local npcBox=Input(content,200,20)
            npcBox:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y)
            npcBox:SetPoint("TOPRIGHT",content,"TOPRIGHT",-PAD,y)
            npcBox:SetText(currentIds)
            npcBox:SetScript("OnEnterPressed",function(self)
                local txt=self:GetText();reminder.customNpcIds={}
                for part in txt:gmatch("[^,]+") do local id=tonumber(part:match("^%s*(%d+)%s*$"));if id then table.insert(reminder.customNpcIds,id) end end
                if #reminder.customNpcIds>0 then reminder.bossKey=nil end
                self:ClearFocus();RC:SaveConfigurationToProfile();RC:CR_RenderTab(panel,reminder,"load",mainFrame)
            end);y=y-ROW_H
        end

    elseif tabKey=="test" then
        y=SecLabel(content,y,"Test Your Reminder");y=y-8
        local nc=RC:GetColor("text","normal")
        local gt=RC:GetColor("text","disabled")
        local sum=MakeFS(content,10,"");sum:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);sum:SetPoint("TOPRIGHT",content,"TOPRIGHT",-PAD,y)
        sum:SetJustifyH("LEFT");sum:SetWordWrap(true);sum:SetTextColor(nc.r,nc.g,nc.b,1)
        local scopeTxt=reminder.scope or "any"
        if reminder.scope=="boss" then
            if reminder.bossKey and reminder.bossKey~="" then scopeTxt=reminder.bossKey:gsub("|"," / ")
            elseif reminder.customNpcIds and #reminder.customNpcIds>0 then
                local parts={};for _,id in ipairs(reminder.customNpcIds) do table.insert(parts,tostring(id)) end
                scopeTxt="NPC IDs: "..table.concat(parts,", ")
            end
        end
        sum:SetText(
            RCL["Mode: "]..(reminder.mode or "aura")..RCL["   Scope: "]..scopeTxt..RCL["   Priority: "]..(reminder.priority or 5).."\n"..
            RCL["Class: "]..(reminder.loadClass or "any")..RCL["   Group: "]..(reminder.loadGroup or "any")..RCL["   Zone: "]..(reminder.loadZoneName or reminder.loadZone or "any").."\n"..
            RCL["Enabled: "]..(reminder.enabled and "|cFF44FF44Yes|r" or "|cFF888888No|r")..
            RCL["   Duration: "]..(reminder.duration or 5)..RCL["s   Cooldown: "]..(reminder.cooldown or 10).."s\n"..
            RCL["Continuous: "]..(reminder.continuous and "|cFF44FF44Yes|r" or "No")..
            RCL["   Animation: "]..(reminder.animationType or "global default")..
            RCL["   Extra conds: "]..(reminder.extraConditions and #reminder.extraConditions or 0)
        );y=y-78
        if reminder.mode=="lua" and reminder.lua and reminder.lua.lastError then
            local ef=MakeFS(content,9,"");ef:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);ef:SetPoint("TOPRIGHT",content,"TOPRIGHT",-PAD,y)
            ef:SetJustifyH("LEFT");ef:SetText(RCL["|cFFFF4444Last error: "]..reminder.lua.lastError.."|r");y=y-28
        end

        y=y-4;y=SecLabel(content,y,"Live Condition Check");y=y-4
        local debugFS=MakeFS(content,10,"");debugFS:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y);debugFS:SetPoint("TOPRIGHT",content,"TOPRIGHT",-PAD,y)
        debugFS:SetJustifyH("LEFT");debugFS:SetWordWrap(true);debugFS:SetTextColor(nc.r,nc.g,nc.b,1)
        local function UpdateDebug()
            if not RC.DebugEvaluateCustomReminder then debugFS:SetText(RCL["|cFF888888Debug not available|r"]);return end
            local d=RC:DebugEvaluateCustomReminder(reminder.id)
            if not d then debugFS:SetText(RCL["|cFFFF4444Reminder not found|r"]);return end
            local pass="|cFF44FF44+|r "; local fail="|cFFFF4444x|r "
            local function pf(v) return v and pass or fail end
            local lines={
                pf(d.enabled).."Enabled",
                pf(d.load).."Load conditions (class/spec/group/zone)",
                pf(d.scope).."Fight scope",
                pf(not d.onCooldown).."Cooldown ("..string.format("%.1f",d.cdRemaining).."s remaining)",
                pf(d.trigger).."Trigger: "..( reminder.mode or "aura"),
                pf(d.extraPass).."Extra conditions"..(d.extraFailIdx and (" - Cond "..d.extraFailIdx.." failed") or ""),
                (d.wouldFire and "|cFF44FF44>> WOULD FIRE NOW|r" or "|cFF888888>> Would not fire|r"),
            }
            debugFS:SetText(table.concat(lines,"\n"))
        end
        UpdateDebug();y=y-112
        local chkBtn=Btn(content,"Refresh Check",110,22);chkBtn:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y)
        chkBtn:SetScript("OnClick",function() UpdateDebug() end);y=y-32

        local fb=Btn(content,"Fire Now (bypass all conditions)",220,26);fb:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y)
        fb:SetScript("OnClick",function() RC:TestFireCustomReminder(reminder.id);UpdateDebug() end);y=y-36
        local enL=reminder.enabled and "Disable" or "Enable"
        local eb3=Btn(content,enL.." Reminder",140,24);eb3:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y)
        eb3:SetScript("OnClick",function() reminder.enabled=not reminder.enabled;RC:SaveConfigurationToProfile();if reminder.enabled and RC.KickCustomReminderTicker then RC:KickCustomReminderTicker() end;RC:CR_RenderTab(panel,reminder,"test",mainFrame) end);y=y-34
        local db3=Btn(content,"Delete Reminder",120,24);db3:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y)
        if db3.text then local _rc=RC:GetColor("text","red"); db3.text:SetTextColor(_rc.r,_rc.g,_rc.b,1) end
        db3:SetScript("OnClick",function()
            RC.UI:CreateConfirmDialog(
                RCL["Delete Reminder"],
                RCL["Delete '"] .. (reminder.name or reminder.id) .. RCL["'?\n\nThis cannot be undone."],
                function() RC:DeleteCustomReminder(reminder.id);CR_Editor.selectedId=nil;RC:ShowSidebarCustomReminders(mainFrame) end,
                nil, RCL["Delete"], true
            )
        end);y=y-38

        y=y-4;y=SecLabel(content,y,"Share / Export");y=y-4
        y=HintLine(content,y,"Copy the text below and share it with others. They can paste it in Import on any reminder.")
        local exportStr=RC.ExportCustomReminder and RC:ExportCustomReminder(reminder.id) or ""
        local exBox=Input(content,EW-PAD*2-2,36)
        exBox:SetPoint("TOPLEFT",content,"TOPLEFT",PAD,y)
        exBox:SetHeight(36);exBox:SetText(exportStr or "")
        exBox:HookScript("OnEditFocusGained",function(self) self:HighlightText() end)
        y=y-44
    end
    local CONTENT_TOP=30+TAB_H+1
    local totalH=CONTENT_TOP+math.abs(y)+PAD*4
    content:SetHeight(math.max(100,math.abs(y)+PAD*4))
    if RC.UpdateSidebarScrollbar and RC.sidebarConfigFrame then
        RC:UpdateSidebarScrollbar(RC.sidebarConfigFrame,math.max(panel._wrFH or 500,totalH))
    end
end

if RC and RC.DebugPrint then RC:DebugPrint("SidebarCustomReminders loaded","system") end
