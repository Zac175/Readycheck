------------------------------------------------------------------------
-- Readycheck - Reminder Settings
-- Reminder Settings tabs (Behavior / Look / Text / Animation / Sound /
-- Position) edit the global reminder keys (db.iconSize, db.animationType,
-- db.fadeInTime, db.soundEnabled, db.dragEnabled, ...). The preview pane
-- shows the popup's own icons (RC:CreateReminderIcon) styled from them.
-- Tab content frames are cached per-tab in frame.reminderTabCache and just
-- shown/hidden on tab switch instead of rebuilt, which is what preserves
-- scroll position without a ClearSidebarContent round-trip.
-- The Stats Bar and Buff Pushoff pages that used to share this file now
-- live in the main addon at UI\Sidebar\Sidebar_PagesStatsBar.lua.
------------------------------------------------------------------------
-- Taint-safe API locals (fallbacks on RC.Compat, built in Core; never write _G)
local RCC = _G.Readycheck
local GetSpellTexture = GetSpellTexture or (RCC and RCC.Compat and RCC.Compat.GetSpellTexture)
local pairs, ipairs, type, tostring, tonumber = pairs, ipairs, type, tostring, tonumber
local math_floor, math_ceil, math_max, math_min = math.floor, math.ceil, math.max, math.min
local table_insert, table_remove, table_sort = table.insert, table.remove, table.sort
local string_format = string.format
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local RC = _G.Readycheck
if not RC then return end
RC._sbs = RC._sbs or {}
local _sbs = RC._sbs
local TEXT = _sbs.TEXT


    -- The preview: the popup's own icons, built and dressed by the same
    -- code as the real popup, with sample abilities. Several = one of each
    -- label state (ready, boon, remove).
    local SAMPLES = {
        one = { { key = "recklessness", icon = "Interface\\Icons\\Ability_CriticalStrike", text = "USE", color = "green" } },
        several = {
            { key = "deathwish", icon = "Interface\\Icons\\Spell_Shadow_DeathPact", text = "USE", color = "green" },
            { key = "boon", icon = "Interface\\Icons\\inv_misc_enggizmos_24", text = RCL["unboon"], color = "gold" },
            { key = "frostBlastBuff_1", icon = "Interface\\Icons\\Spell_Frost_FreezingBreath", text = "REMOVE", color = "orange" },
        },
    }
    local PV_W, PV_H = 100, 98   -- one 80 px icon; update sizes the canvas to the icons

    -- another game version (Core_Flavor) samples only what loads there:
    -- no Chronoboon (no world buffs to keep), no Kel'Thuzad's Frost Blast
    -- (Classic Era's Naxxramas); a custom alert and a plain debuff instead
    local SAMPLES_OTHER = {
        { key = "deathwish", icon = "Interface\\Icons\\Spell_Shadow_DeathPact", text = "USE", color = "green" },
        { key = "custom", icon = "Interface\\Icons\\INV_Misc_Bell_01", text = RCL["ALERT"], color = "gold" },
        { key = "debuff", icon = "Interface\\Icons\\Spell_Shadow_CurseOfTounges", text = "REMOVE", color = "orange" },
    }
    local function SampleList(P)
        local mode = (P and P.mode) or "one"
        if mode == "several" and RC.Flavor and RC:Flavor() ~= "era" then return SAMPLES_OTHER end
        return SAMPLES[mode] or SAMPLES.one
    end

    local function PreviewBuild(canvas, P)
        local holder = CreateFrame("Frame", nil, canvas)
        holder:SetPoint("CENTER", canvas, "CENTER", 0, 0)
        holder:SetSize(PV_W, PV_H)
        P.store.holder = holder
        P.store.icons = {}
        P.store.token = 0
    end

    local function PreviewUpdate(canvas, P)
        local RCx, st = RC, P.store
        local db = RCx.db
        local list = SampleList(P)
        local size = db.iconSize or 80
        if size < 8 then size = 8 end
        local spacing = db.iconSpacing or 5
        local n = #list
        -- the icons at their real size laid out as the popup lays them out
        -- (a centred row, or the layout on Position); the canvas is their
        -- box (the label hangs a few px under the ring) and the strip
        -- scales it. Re-laying out mid-animation would fight the replay's rest.
        st.slots = st.slots or {}
        local bw, bh = RCx:ReminderIconSlots(n, size, spacing, 7, st.slots)
        local sig = n .. ":" .. size .. ":" .. spacing .. ":" .. bw .. ":" .. bh
        for i = 1, n do
            local o = st.slots[i]
            sig = sig .. ":" .. tostring(o.point) .. tostring(o.x) .. "," .. tostring(o.y)
        end
        if st.sig ~= sig then
            RCx.Motion.Stop(st.holder)
            st.holder:SetSize(bw + 14, bh + 14)
            st.holder:SetScale(1)
            P.Resize(bw + 14, bh + 14)
            st.sig = sig
        end
        for i, sample in ipairs(list) do
            local icon = st.icons[i]
            if not icon then
                icon = RCx:CreateReminderIcon(st.holder, size)
                st.icons[i] = icon
                -- click a part of the sample to pick its controls
                RCx.UI:TagElement(icon.texture, "icon")
                if icon.halo then RCx.UI:TagElement(icon.halo, "glow") end
            end
            icon:SetSize(size, size)
            icon.originalSize = size
            RCx.UI:DressReadyIcon(icon, size)
            icon.texture:SetTexture(sample.icon)
            icon:ClearAllPoints()
            local o = st.slots[i]
            icon:SetPoint(o.point or "CENTER", st.holder, o.point or "CENTER", o.point and o.x or 0, o.point and o.y or 0)
            icon:SetShown(o.point ~= nil)
            if db.showIconText then
                RCx:EnsureReminderIconText(icon)
                RCx.UI:TagElement(icon.cooldownText, "label")
                icon.cooldownText:SetWidth(size)
                RCx:PlaceReminderIconText(icon)
                RCx:SetReminderIconLabel(icon, sample.text, sample.color)
                icon.cooldownText:Show()
            else
                if icon.cooldownText then icon.cooldownText:Hide() end
                RCx:ApplyReminderIconState(icon, sample.color)
            end
            RCx.UI:SetReadyIconGlow(icon, db.iconGlow or "pulse")
            RCx:PlaceReminderIconGlow(icon)
        end
        for i = n + 1, #st.icons do st.icons[i]:Hide() end
        -- the backdrop (the standard's chrome) on the sample's box
        if RCx.ApplyFrameCustom then
            RCx:ApplyFrameCustom(st.holder, function() return RCx.db.reminderPopup end, { sample = true })
        end
    end

    -- Entrance, a beat on screen, the exit, then back at rest.
    local function PreviewReplay(canvas, P)
        local RCx, st = RC, P.store
        local M = RCx.Motion
        local holder = st.holder
        st.token = st.token + 1
        local t = st.token
        local keys = {}
        for i, sample in ipairs(SampleList(P)) do keys[i] = sample.key end
        M.Stop(holder)
        holder:Hide()
        local inSpec = RCx:GetReminderMotion("in", keys)
        M.Show(holder, inSpec)
        local hold = M.Duration(inSpec.duration) + M.Duration(inSpec.delay or 0) + 1.2
        C_Timer.After(hold, function()
            if t ~= st.token or not holder:IsVisible() then return end
            local outSpec = RCx:GetReminderMotion("out", keys)
            M.Hide(holder, outSpec)
            C_Timer.After(M.Duration(outSpec.duration) + M.Duration(outSpec.delay or 0) + 0.4, function()
                if t ~= st.token then return end
                M.Stop(holder)
                if canvas:IsVisible() then holder:Show() end
            end)
        end)
    end

    function RC:ShowSidebarReminderSettings(frame, selectedTab)
        -- Tab already built: show/hide the cached content frames instead of
        -- a full ClearSidebarContent rebuild, so scroll position never moves.
        if selectedTab and frame.reminderTabCache and frame.reminderTabCache[selectedTab] then
            frame.reminderTab = selectedTab
            for k, cf in pairs(frame.reminderTabCache) do
                if k == selectedTab then cf:Show() else cf:Hide() end
            end
            if frame.reminderTabGroup then
                frame.reminderTabGroup:SetSelected(selectedTab)
            end
            if self.UpdateSidebarScrollbar and frame.reminderScrollHeight then
                self:UpdateSidebarScrollbar(self.sidebarConfigFrame,
                    frame.reminderScrollHeight[selectedTab] or 400)
            end
            self:RestoreScrollPosition(self.sidebarConfigFrame)
            return
        end

        self:ClearSidebarContent(self.sidebarConfigFrame, false)
        selectedTab             = selectedTab or frame.reminderTab or "behavior"
        frame.reminderTab       = selectedTab
        frame.reminderTabCache  = {}
        frame.reminderScrollHeight = {}

        local parent = frame.scrollChild
        local yPos   = -15

        -- the popup's customization root (RC.db.reminderPopup) and its binds
        local function PopupRoot()
            if type(RC.db.reminderPopup) ~= "table" then RC.db.reminderPopup = {} end
            return RC.db.reminderPopup
        end
        local function PopupChanged()
            RC:SaveConfigurationToProfile()
            if RC.RefreshReminderPopupLook then RC:RefreshReminderPopupLook() end
        end
        local function PopupTargets(except)
            local out = {}
            for _, t in ipairs(RC.REMINDER_ICON_TARGETS or {}) do
                if t.value ~= except then out[#out + 1] = t end
            end
            return out
        end
        local function CardW(card)
            local w = card and card.GetWidth and card:GetWidth()
            if type(w) == "number" and w > 240 then return math_min(460, w - 28) end
            return 420
        end

        local P = self.UI:DeclarePreview({
            key = "reminders.popup", title = RCL["Reminder popup"],
            width = PV_W, height = PV_H,
            build = PreviewBuild, update = PreviewUpdate, replay = PreviewReplay,
            modes = { { id = "one", label = RCL["One icon"] }, { id = "several", label = RCL["Several"] } },
        })

        local _, newY = self:CreateSettingsPageHeader(parent, yPos, RCL["Reminder Settings"],
            RCL["Behavior, look, text, animation, sound and position for all reminders"],
            "Interface\\Icons\\INV_Misc_Bell_01")
        yPos = newY

        local tabGroup, newTabY = self.UI:CreateTabGroup(parent, {
            y = yPos,
            tabs = {
                { key = "behavior",  label = RCL["Behavior"]  },
                { key = "look",      label = RCL["Look"]      },
                { key = "text",      label = RCL["Text"]      },
                { key = "animation", label = RCL["Animation"] },
                { key = "sound",     label = RCL["Sound"]     },
                { key = "position",  label = RCL["Position"]  },
            },
            selected = selectedTab,
            onClick = function(tk)
                frame.reminderTab = tk
                RC:ShowSidebarReminderSettings(frame, tk)
            end,
            advance = 38 + 8,
        })
        frame.reminderTabGroup = tabGroup
        yPos = newTabY
        -- a click on a part of the sample opens the tab with its controls
        if RC.CustomPick then
            RC.CustomPick.SetHandler("reminders.popup", function(k)
                local to = (k == "label" and "text") or (k == "glow" and "position") or "look"
                RC:ShowSidebarReminderSettings(frame, to)
            end)
        end

        local WR_SOUNDS_R = {
            {label=RCL["WR: Warning"],      key="WR: Warning",      file="Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg"},
        }
        local wrSndKeysR = {}
        for _, s in ipairs(WR_SOUNDS_R) do wrSndKeysR[s.key]=true end
        local function GetLSMSoundsR()
            if not RC.LSM then return {} end
            local all = RC.LSM:HashTable("sound") or {}
            local list = {}
            for k,v in pairs(all) do if not wrSndKeysR[k] then table.insert(list,{label=k,key=k,file=v}) end end
            table.sort(list, function(a,b) return a.label<b.label end)
            return list
        end
        local function ResolveSndLabelR(key)
            if not key then return "WR: Warning" end
            for _,s in ipairs(WR_SOUNDS_R) do if s.key==key then return s.label end end
            return key
        end
        local function ResolveSndFileR(key)
            if not key then return "Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg" end
            for _,s in ipairs(WR_SOUNDS_R) do if s.key==key then return s.file end end
            if RC.LSM then return RC.LSM:Fetch("sound",key) or "" end
            return ""
        end
        local function BuildSndItemsR()
            local items,fm = {},{}
            for _,s in ipairs(WR_SOUNDS_R) do table.insert(items,{text=s.label,value=s.key}); fm[s.key]=s.file end
            for _,s in ipairs(GetLSMSoundsR()) do table.insert(items,{text=s.label,value=s.key}); fm[s.key]=s.file end
            return items,fm
        end

        if not self.db.abilityOverrides then self.db.abilityOverrides = {} end

        local behCF = CreateFrame("Frame", nil, parent)
        behCF:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, yPos)
        behCF:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yPos)
        do
            local cy = 0
            local bCard = self:CreateSettingsCard(behCF, cy, RCL["Reminder behavior"])
            local bcy = -32

            local combatCheck = self.UI:CreateCheckbox(bCard, RCL["Show reminders in combat only"], self.db.showInCombatOnly)
            combatCheck:SetPoint("TOPLEFT", bCard, "TOPLEFT", 14, bcy)
            combatCheck:SetScript("OnClick", function()
                self.db.showInCombatOnly = combatCheck:GetChecked()
                self:ForceCheckboxUpdate(combatCheck, self.db.showInCombatOnly)
                self:SaveConfigurationToProfile()
            end)
            bcy = bcy - 26

            local clickthroughCheck = self.UI:CreateCheckbox(bCard, RCL["Click through reminders (mouse passthrough)"], self.db.clickThrough)
            clickthroughCheck:SetPoint("TOPLEFT", bCard, "TOPLEFT", 14, bcy)
            clickthroughCheck:SetScript("OnClick", function()
                self.db.clickThrough = clickthroughCheck:GetChecked()
                self:ForceCheckboxUpdate(clickthroughCheck, self.db.clickThrough)
                if self.UpdateReminderFrameMouseState then self:UpdateReminderFrameMouseState() end
                self:SaveConfigurationToProfile()
            end)
            bcy = bcy - 30

            bCard:SetContentHeight(math.abs(bcy))
            cy = cy - bCard:GetHeight() - 15

            local tCard = self:CreateSettingsCard(behCF, cy, RCL["Timing"])
            bcy = -32

            local grLbl = self:CreateFontString(tCard,"OVERLAY",nil,11); grLbl:SetPoint("TOPLEFT",tCard,"TOPLEFT",14,bcy); grLbl:SetText(RCL["Early Warning (Before Ready)"]); grLbl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3]); bcy=bcy-22
            local grS = self.UI:CreateSlider(tCard,0,10,self.db.abilityReadyGracePeriod or 0,1); grS:SetPoint("TOPLEFT",tCard,"TOPLEFT",14,bcy); grS.Text:SetText((self.db.abilityReadyGracePeriod or 0)..RCL[" seconds"])
            grS:SetScript("OnValueChanged",function(s,v) v=math.floor(v); self.db.abilityReadyGracePeriod=v; s.Text:SetText(v..RCL[" seconds"]); if s.saveTimer then s.saveTimer:Cancel() end; s.saveTimer=C_Timer.NewTimer(0.5,function() self:SaveConfigurationToProfile() end) end)
            bcy=bcy-50
            local grDesc=self:CreateFontString(tCard,"OVERLAY",nil,10); grDesc:SetPoint("TOPLEFT",tCard,"TOPLEFT",14,bcy); grDesc:SetText(RCL["Show reminders X seconds before ability is off cooldown (0 = only when ready)"]); grDesc:SetTextColor(TEXT.gray[1],TEXT.gray[2],TEXT.gray[3]); bcy=bcy-18

            tCard:SetContentHeight(math.abs(bcy))
            cy = cy - tCard:GetHeight() - 15
            cy = self.UI:FrameVisibilityCard(behCF, cy, PopupRoot, PopupChanged, { title = RCL["Popup fade and opacity"],
                note = RCL["On top of 'combat only': a rule that is not met fades the popup out."] })

            behCF:SetHeight(math.abs(cy) + 20)
            frame.reminderScrollHeight["behavior"] = math.abs(yPos) + math.abs(cy) + 20
        end

        local lookCF = CreateFrame("Frame", nil, parent)
        lookCF:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, yPos)
        lookCF:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yPos)
        do
            local cy = 0
            local iCard=self:CreateSettingsCard(lookCF, cy, RCL["Icon display"])
            local pcy=-32

            local szLbl=self:CreateFontString(iCard,"OVERLAY",nil,11); szLbl:SetPoint("TOPLEFT",iCard,"TOPLEFT",14,pcy); szLbl:SetText(RCL["Icon Size:"]); szLbl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3]); pcy=pcy-22
            local szS=self.UI:CreateSlider(iCard,0,256,self.db.iconSize or 80,1); szS:SetPoint("TOPLEFT",iCard,"TOPLEFT",14,pcy); szS.Text:SetText((self.db.iconSize or 80)..RCL[" px"])
            szS:SetScript("OnValueChanged",function(s,v) v=math.floor(v); self.db.iconSize=v; s.Text:SetText(v..RCL[" px"]); if s.saveTimer then s.saveTimer:Cancel() end; s.saveTimer=C_Timer.NewTimer(0.5,function() self:SaveConfigurationToProfile() end) end)
            pcy=pcy-48

            local spLbl=self:CreateFontString(iCard,"OVERLAY",nil,11); spLbl:SetPoint("TOPLEFT",iCard,"TOPLEFT",14,pcy); spLbl:SetText(RCL["Icon Spacing:"]); spLbl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3]); pcy=pcy-22
            local spS=self.UI:CreateSlider(iCard,0,100,self.db.iconSpacing or 5,1); spS:SetPoint("TOPLEFT",iCard,"TOPLEFT",14,pcy); spS.Text:SetText((self.db.iconSpacing or 5)..RCL[" px"])
            spS:SetScript("OnValueChanged",function(s,v) v=math.floor(v); self.db.iconSpacing=v; s.Text:SetText(v..RCL[" px"]); if s.saveTimer then s.saveTimer:Cancel() end; s.saveTimer=C_Timer.NewTimer(0.5,function() self:SaveConfigurationToProfile() end) end)
            pcy=pcy-48

            -- The look of each icon: a 1px ring on the edge (plus a black
            -- edge outside it when "Thick"), and a soft halo around it.
            -- Both colours are the "Reminder Icon Border" / "Reminder Icon
            -- Glow" entries of Appearance > Colours; the presets set the
            -- lot in one click. Every change repaints the icons already up.
            local GLOW_LABELS={ pulse=RCL["Pulsing glow"], static=RCL["Steady glow"], off=RCL["No glow"] }
            local UIX=self.UI
            local looks={}   -- widgets the presets update in place

            local function RepaintLive()
                local f=self.reminderFrame
                if not (f and f.abilityIcons and UIX.RepaintReadyIcon) then return end
                for _,icon in pairs(f.abilityIcons) do
                    UIX:RepaintReadyIcon(icon)
                    if icon:IsShown() and UIX.SetReadyIconGlow then UIX:SetReadyIconGlow(icon,self.db.iconGlow or "pulse") end
                end
            end

            -- the border colour as drawn: an unset border follows a glow
            -- colour set before the two were split (as UIF_Widgets does)
            local function LookColor(key)
                local cc=self.db.customColors and self.db.customColors.ui
                if key=="readyBorder" and cc and not cc.readyBorder and cc.readyGlow then return cc.readyGlow end
                return self:GetColor("ui",key)
            end
            local function Same(a,b)
                return math.abs((a.r or 0)-(b.r or 0))<0.01 and math.abs((a.g or 0)-(b.g or 0))<0.01 and math.abs((a.b or 0)-(b.b or 0))<0.01
            end

            -- Classic is the shipped look; its colours are the defaults.
            local PRESETS={
                classic={ border=nil, glow=nil, glowMode="pulse", edge="thick", scale=1.5 },
                clean={ border={r=0,g=0,b=0}, glow={r=1,g=1,b=1}, glowMode="pulse", edge="thin", scale=1.3 },
                minimal={ border={r=0,g=0,b=0}, glow={r=1,g=1,b=1}, glowMode="off", edge="thin" },
            }
            local PRESET_ORDER={"classic","clean","minimal"}
            local function PresetColor(p,which)
                if p[which] then return p[which] end
                local d=self.defaultColors and self.defaultColors.ui
                return d and d[which=="border" and "readyBorder" or "readyGlow"] or LookColor(which=="border" and "readyBorder" or "readyGlow")
            end
            local function CurrentPreset()
                local mode=self.db.iconGlow or "pulse"
                local edge=self.db.iconBorder or "thick"
                local scale=tonumber(self.db.iconGlowScale) or 1.5
                for _,k in ipairs(PRESET_ORDER) do
                    local p=PRESETS[k]
                    if p.glowMode==mode and p.edge==edge and Same(LookColor("readyBorder"),PresetColor(p,"border"))
                        and (mode=="off" or (Same(LookColor("readyGlow"),PresetColor(p,"glow")) and math.abs(scale-(p.scale or scale))<0.01)) then
                        return k
                    end
                end
                return nil
            end
            local function SyncLooks()
                if looks.preset then looks.preset:SetValue(CurrentPreset(),true) end
                if looks.edge then looks.edge:SetValue(self.db.iconBorder or "thick",true) end
                if looks.glow then local m=self.db.iconGlow or "pulse"; looks.glow:SetSelectedValue(m,GLOW_LABELS[m] or GLOW_LABELS.pulse) end
                if looks.scale then looks.scale.syncing=true; looks.scale:SetValue(math_floor((tonumber(self.db.iconGlowScale) or 1.5)*100+0.5)); looks.scale.syncing=nil end
                for _,row in ipairs(looks.rows or {}) do row:Sync() end
            end
            local function LookChanged()
                self:SaveConfigurationToProfile()
                RepaintLive()
                SyncLooks()
            end
            local function ApplyPreset(k)
                local p=PRESETS[k]; if not p then return end
                if p.border then self:SetColor("ui","readyBorder",p.border.r,p.border.g,p.border.b,1) else self:ResetColor("ui","readyBorder") end
                if p.glow then self:SetColor("ui","readyGlow",p.glow.r,p.glow.g,p.glow.b,1) else self:ResetColor("ui","readyGlow") end
                self.db.iconGlow=p.glowMode
                self.db.iconBorder=p.edge
                if p.scale then self.db.iconGlowScale=p.scale end
                LookChanged()
            end

            looks.preset=UIX:CreateSegmentedControl(iCard,{
                x=14, y=pcy, height=22, label=RCL["Icon look:"],
                items={
                    {key="classic", label=RCL["Classic"], tooltip=RCL["Gold ring with a black edge and a pulsing gold glow."]},
                    {key="clean",   label=RCL["Clean"],   tooltip=RCL["Thin black ring with a soft white glow."]},
                    {key="minimal", label=RCL["Minimal"], tooltip=RCL["Thin black ring, no glow."]},
                },
                selected=CurrentPreset(),
                onSelect=function(k) ApplyPreset(k) end,
            })
            pcy=pcy-30

            looks.edge=UIX:CreateSegmentedControl(iCard,{
                x=14, y=pcy, height=22, label=RCL["Icon border:"],
                items={
                    {key="thick", label=RCL["Thick"], tooltip=RCL["The coloured ring with a black edge outside it."]},
                    {key="thin",  label=RCL["Thin"],  tooltip=RCL["Just the 1px coloured ring."]},
                    {key="none",  label=RCL["None"],  tooltip=RCL["No border at all."]},
                },
                selected=self.db.iconBorder or "thick",
                onSelect=function(k) self.db.iconBorder=k; LookChanged() end,
            })
            pcy=pcy-32

            local glLbl=self:CreateFontString(iCard,"OVERLAY",nil,11); glLbl:SetPoint("TOPLEFT",iCard,"TOPLEFT",14,pcy); glLbl:SetText(RCL["Icon glow:"]); glLbl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3])
            local curGlow=self.db.iconGlow or "pulse"
            local glDD=UIX:CreateScrollableDropdown(iCard,160,GLOW_LABELS[curGlow] or GLOW_LABELS.pulse,3)
            glDD:SetPoint("LEFT",glLbl,"RIGHT",10,0)
            glDD:SetItems({
                {text=GLOW_LABELS.pulse,value="pulse"},
                {text=GLOW_LABELS.static,value="static"},
                {text=GLOW_LABELS.off,value="off"},
            },function(v) self.db.iconGlow=v; LookChanged() end)
            glDD:SetSelectedValue(curGlow,GLOW_LABELS[curGlow] or GLOW_LABELS.pulse)
            looks.glow=glDD
            pcy=pcy-30

            local gsLbl=self:CreateFontString(iCard,"OVERLAY",nil,11); gsLbl:SetPoint("TOPLEFT",iCard,"TOPLEFT",14,pcy); gsLbl:SetText(RCL["Glow size:"]); gsLbl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3]); pcy=pcy-22
            local gsCur=math_floor((tonumber(self.db.iconGlowScale) or 1.5)*100+0.5)
            local gsS=UIX:CreateSlider(iCard,110,200,gsCur,5); gsS:SetPoint("TOPLEFT",iCard,"TOPLEFT",14,pcy); gsS.Text:SetText(gsCur.."%")
            gsS:SetScript("OnValueChanged",function(s,v)
                v=math_floor(v/5+0.5)*5; s.Text:SetText(v.."%")
                if s.syncing then return end
                self.db.iconGlowScale=v/100
                RepaintLive()
                if looks.preset then looks.preset:SetValue(CurrentPreset(),true) end
                if s.saveTimer then s.saveTimer:Cancel() end
                s.saveTimer=C_Timer.NewTimer(0.5,function() self:SaveConfigurationToProfile() end)
            end)
            looks.scale=gsS
            pcy=pcy-48

            -- colour rows: click opens the colour wheel (live), Reset puts
            -- the default back
            local function ToHex(c) return string_format("%02X%02X%02X",math_floor((c.r or 0)*255+0.5),math_floor((c.g or 0)*255+0.5),math_floor((c.b or 0)*255+0.5)) end
            looks.rows={}
            local function ColorRow(key,label)
                local row=UIX:CreateColorRow(iCard)
                row:SetPoint("TOPLEFT",iCard,"TOPLEFT",10,pcy)
                row:SetPoint("RIGHT",iCard,"RIGHT",-10,0)
                local def=self.defaultColors and self.defaultColors.ui and self.defaultColors.ui[key]
                row.categoryKey="ui"; row.colorKey=key; row.defaultColor=def
                function row:Sync()
                    local c=LookColor(key)
                    self.currentColor={r=c.r,g=c.g,b=c.b,a=c.a or 1}
                    self:SetData(label,"#"..ToHex(c),c,def and not Same(c,def))
                end
                row.onClick=function(r) if RC.OpenAppearanceColorPickerLive then RC:OpenAppearanceColorPickerLive(r) end end
                row.OnPickerChanged=function() RepaintLive(); SyncLooks() end
                row.onReset=function()
                    self:ResetColor("ui",key)
                    -- a border still following an old glow colour gets the
                    -- default written so it stops following
                    if key=="readyBorder" and def and not Same(LookColor(key),def) then self:SetColor("ui",key,def.r,def.g,def.b,1) end
                    RepaintLive(); SyncLooks()
                end
                row.tooltipFn=function(r,tt)
                    local tn=self:GetColor("text","normal"); local gold=self:GetColor("ui","accentGold")
                    tt:AddLine(label,tn.r,tn.g,tn.b)
                    tt:AddLine(RCL["Click to edit"],gold.r,gold.g,gold.b)
                end
                row:Sync()
                looks.rows[#looks.rows+1]=row
                pcy=pcy-26
            end
            ColorRow("readyBorder",RCL["Border colour"])
            ColorRow("readyGlow",RCL["Glow colour"])
            pcy=pcy-6

            local ttCb=self.UI:CreateCheckbox(iCard,RCL["Show tooltips on icons"],self.db.showTooltips)
            ttCb:SetPoint("TOPLEFT",iCard,"TOPLEFT",14,pcy)
            ttCb:SetScript("OnClick",function() self.db.showTooltips=ttCb:GetChecked(); self:ForceCheckboxUpdate(ttCb,self.db.showTooltips); self:SaveConfigurationToProfile() end)
            pcy=pcy-20

            iCard:SetContentHeight(math.abs(pcy)); cy=cy-iCard:GetHeight()-15

            -- a look per label state: the text colour, the glow colour,
            -- greyed out, opacity and an animation as the state starts
            local stCard=self:CreateSettingsCard(lookCF, cy, RCL["Look per state"])
            local sy=-32
            frame._rpStateMem=frame._rpStateMem or {}
            local sg,ss=self.UI:CustomAccess(PopupRoot,"states",nil,PopupChanged)
            local se=self.UI:CreateStateEditor(stCard,{ width=CardW(stCard), get=sg, set=ss,
                states={ {id="ready",label=RCL["Ready to use (USE)"]},
                         {id="alert",label=RC:FeatureOn("chronoboon") and RCL["Boon and custom alerts"] or RCL["Custom alerts"]},
                         {id="remove",label=RCL["Remove a debuff (REMOVE)"]} },
                defaults=RC.REMINDER_STATE_DEFAULTS, remember=frame._rpStateMem,
                fields={ textColor=true, glow=true, desat=true, alpha=true, anim=true } })
            se:SetPoint("TOPLEFT",stCard,"TOPLEFT",14,sy)
            sy=sy-se:GetHeight()-8
            sy=RC.UI:CreateHelpLine(stCard,14,sy,RCL["Each state's text colour wins over the one on the Text tab. Unset: the icon as it always looks."])
            stCard:SetContentHeight(math.abs(sy)+6); cy=cy-stCard:GetHeight()-15

            cy = self.UI:FrameChromeCard(lookCF, cy, PopupRoot, PopupChanged, { title = RCL["Backdrop behind the icons"],
                note = RCL["Unset, the icons float on their own as always."] })

            lookCF:SetHeight(math.abs(cy) + 20)
            frame.reminderScrollHeight["look"] = math.abs(yPos) + math.abs(cy) + 20
        end

        -- The icon label: whether it shows, its font and its colour.
        local textCF = CreateFrame("Frame", nil, parent)
        textCF:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, yPos)
        textCF:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yPos)
        do
            local cy = 0
            local function RT()
                if type(self.db.reminderText) ~= "table" then self.db.reminderText = { font = {} } end
                return self.db.reminderText
            end
            local function Changed()
                self:SaveConfigurationToProfile()
                if self.RestyleReminderIconLabels then self:RestyleReminderIconLabels() end
            end

            local card = self:CreateSettingsCard(textCF, cy, RCL["Icon text"])
            local ty = -32
            local stCb = self.UI:CreateCheckbox(card, RCL["Show USE/REMOVE text on icons"], self.db.showIconText)
            stCb:SetPoint("TOPLEFT", card, "TOPLEFT", 14, ty)
            stCb:SetScript("OnClick", function()
                self.db.showIconText = stCb:GetChecked()
                self:ForceCheckboxUpdate(stCb, self.db.showIconText)
                self:SaveConfigurationToProfile()
            end)
            ty = ty - 28

            -- font, colour, wording and place: one group (the standard's
            -- text element); font and colour stay on db.reminderText
            local fg, fs = self.UI:CustomAccess(PopupRoot, "formats", "label", PopupChanged)
            local ag, as = self.UI:CustomAccess(PopupRoot, "anchors", "label", PopupChanged)
            local te = self.UI:CreateTextElement(card, { label = RCL["Icon text"], key = "label", width = CardW(card),
                font = { get = function() return RT().font end,
                    set = function(spec) RT().font = spec; Changed() end,
                    defaults = self.REMINDER_LABEL_FONT_DEFAULTS,
                    minSize = 6, maxSize = 32, sample = "USE   REMOVE   unboon" },
                colors = { { label = RCL["Text colour"],
                    get = function() return RT().color or self:GetColor("text", "green") end,
                    set = function(r, g, b) RT().color = { r = r, g = g, b = b, a = 1 }; Changed() end,
                    isChanged = function() return type(RT().color) == "table" end,
                    reset = function() RT().color = nil; Changed() end } },
                formatGet = fg, formatSet = fs, formatKinds = { name = true },
                formatSample = function(spec) return RC.UI:FormatText(spec, nil, { value = "REMOVE" }, { value = "name" }, "value") end,
                anchorGet = ag, anchorSet = as, targets = PopupTargets("label"),
                defaultTargetLabel = RCL["On the icon's bottom edge"],
                anchorDefaults = function() return RC.REMINDER_LABEL_ANCHOR end })
            te:SetPoint("TOPLEFT", card, "TOPLEFT", 14, ty)
            ty = ty - te:GetHeight() - 10
            -- only matters while the text shows
            self.UI:BindDependents(stCb, { te }, { indent = 0 })
            local cDesc = self:CreateFontString(card, "OVERLAY", nil, 10)
            cDesc:SetPoint("TOPLEFT", card, "TOPLEFT", 14, ty)
            cDesc:SetPoint("RIGHT", card, "RIGHT", -14, 0)
            cDesc:SetJustifyH("LEFT")
            cDesc:SetText(RCL["Until you pick one the text is coloured by what it says: green to use, gold for the boon and custom alerts, orange to remove."])
            cDesc:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            ty = ty - (cDesc:GetStringHeight() or 12) - 8

            card:SetContentHeight(math.abs(ty))
            cy = cy - card:GetHeight() - 15

            textCF:SetHeight(math.abs(cy) + 20)
            frame.reminderScrollHeight["text"] = math.abs(yPos) + math.abs(cy) + 20
        end

        -- Entrance and exit. Bound to the keys the popup has always had
        -- (animationType, fadeInTime, fadeTime) plus db.reminderMotion for
        -- the rest, so a profile from before this page reads unchanged.
        local animCF = CreateFrame("Frame", nil, parent)
        animCF:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, yPos)
        animCF:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yPos)
        do
            local cy = 0
            local M = self.Motion
            local function RM()
                local rm = self.db.reminderMotion
                if type(rm) ~= "table" then rm = {}; self.db.reminderMotion = rm end
                if type(rm.show) ~= "table" then rm.show = {} end
                if type(rm.hide) ~= "table" then rm.hide = {} end
                return rm
            end
            local function Changed()
                self:SaveConfigurationToProfile()
                if P then P.Replay() end
            end
            local LEGACY = { easing = "linear" }

            local card = self:CreateSettingsCard(animCF, cy, RCL["Popup animation"])
            local ay = -32
            local inP = self.UI:CreateAnimationPicker(card, {
                label = RCL["When it appears"], width = 460, how = "in", defaults = LEGACY,
                get = function()
                    local x = RM().show
                    return { style = M.StyleFromLegacy(self.db.animationType), duration = self.db.fadeInTime or 0.3,
                             easing = x.easing, delay = x.delay, dir = x.dir, distance = x.distance, loop = x.loop }
                end,
                set = function(s)
                    self.db.animationType = s.style
                    self.db.fadeInTime = s.duration
                    RM().show = { easing = s.easing, delay = s.delay, dir = s.dir, distance = s.distance, loop = s.loop }
                    Changed()
                end,
            })
            inP:SetPoint("TOPLEFT", card, "TOPLEFT", 14, ay)
            ay = ay - inP:GetHeight() - 14

            local outP = self.UI:CreateAnimationPicker(card, {
                label = RCL["When it goes"], width = 460, how = "out", defaults = LEGACY,
                get = function()
                    local x = RM().hide
                    local st = x.style
                    if st == nil then st = self.db.animationType end
                    return { style = M.StyleFromLegacy(st), duration = self.db.fadeTime or 0.3,
                             easing = x.easing, delay = x.delay, dir = x.dir, distance = x.distance }
                end,
                set = function(s)
                    self.db.fadeTime = s.duration
                    RM().hide = { style = s.style, easing = s.easing, delay = s.delay, dir = s.dir, distance = s.distance }
                    Changed()
                end,
            })
            outP:SetPoint("TOPLEFT", card, "TOPLEFT", 14, ay)
            ay = ay - outP:GetHeight() - 8

            local aDesc = self:CreateFontString(card, "OVERLAY", nil, 10)
            aDesc:SetPoint("TOPLEFT", card, "TOPLEFT", 14, ay)
            aDesc:SetPoint("RIGHT", card, "RIGHT", -14, 0)
            aDesc:SetJustifyH("LEFT")
            aDesc:SetText(RCL["A custom reminder set to no animation keeps none. Appearance > Motion can turn every animation off or speed them all up."])
            aDesc:SetTextColor(TEXT.gray[1], TEXT.gray[2], TEXT.gray[3])
            ay = ay - (aDesc:GetStringHeight() or 12) - 8

            card:SetContentHeight(math.abs(ay))
            cy = cy - card:GetHeight() - 15

            animCF:SetHeight(math.abs(cy) + 20)
            frame.reminderScrollHeight["animation"] = math.abs(yPos) + math.abs(cy) + 20
        end

        local sndCF = CreateFrame("Frame", nil, parent)
        sndCF:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, yPos)
        sndCF:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yPos)
        do
            local cy = 0

            local sCard = self:CreateSettingsCard(sndCF, cy, RCL["Global sound"])
            local scy = -32

            local ttsCheck = self.UI:CreateCheckbox(sCard,RCL["Enable voice alerts (TTS)"],self.db.ttsEnabled)
            ttsCheck:SetPoint("TOPLEFT",sCard,"TOPLEFT",14,scy)
            ttsCheck:SetScript("OnClick",function() self.db.ttsEnabled=ttsCheck:GetChecked(); self:ForceCheckboxUpdate(ttsCheck,self.db.ttsEnabled); self:SaveConfigurationToProfile() end)
            scy=scy-22
            local ttsDesc=self:CreateFontString(sCard,"OVERLAY",nil,10); ttsDesc:SetPoint("TOPLEFT",sCard,"TOPLEFT",35,scy); ttsDesc:SetWidth(sCard:GetWidth()-50); ttsDesc:SetJustifyH("LEFT"); ttsDesc:SetText(RCL["Master switch for the spoken voice. Turning this off silences every alert that speaks: reminders, consumables, the bars, boss notes and equipment warnings. Preview and test buttons still play so you can audition a voice."]); ttsDesc:SetTextColor(TEXT.gray[1],TEXT.gray[2],TEXT.gray[3]); scy=scy-ttsDesc:GetStringHeight()-10

            local ttsRptLbl=self:CreateFontString(sCard,"OVERLAY",nil,10)
            ttsRptLbl:SetPoint("TOPLEFT",sCard,"TOPLEFT",35,scy)
            ttsRptLbl:SetText(RCL["Repeat count"])
            ttsRptLbl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3])
            local rptCnt=math.min(self.db.ttsRepeatCount or 0,10)
            local rptCntSlider=self.UI:CreateSlider(sCard,0,10,rptCnt,1)
            rptCntSlider:SetPoint("LEFT",ttsRptLbl,"RIGHT",8,0)
            rptCntSlider:SetWidth(110)
            rptCntSlider.Text:SetText(tostring(rptCnt))
            rptCntSlider:SetScript("OnValueChanged",function(s,v)
                v=math.floor(v); RC.db.ttsRepeatCount=v; s.Text:SetText(tostring(v))
            end)
            rptCntSlider:SetScript("OnMouseUp",function() RC:SaveConfigurationToProfile() end)
            scy=scy-32

            local ttsIntLbl=self:CreateFontString(sCard,"OVERLAY",nil,10)
            ttsIntLbl:SetPoint("TOPLEFT",sCard,"TOPLEFT",35,scy)
            ttsIntLbl:SetText(RCL["Repeat reminder every"])
            ttsIntLbl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3])
            local rptInt=math.max(10,self.db.ttsRepeatInterval or 30)
            local rptIntSlider=self.UI:CreateSlider(sCard,10,120,rptInt,5)
            rptIntSlider:SetPoint("LEFT",ttsIntLbl,"RIGHT",8,0)
            rptIntSlider:SetWidth(110)
            rptIntSlider.Text:SetText(rptInt.."s")
            rptIntSlider:SetScript("OnValueChanged",function(s,v)
                v=math.floor(v/5)*5; if v<10 then v=10 end
                RC.db.ttsRepeatInterval=v; s.Text:SetText(v.."s")
            end)
            rptIntSlider:SetScript("OnMouseUp",function() RC:SaveConfigurationToProfile() end)
            scy=scy-32

            local ttsRptDesc=self:CreateFontString(sCard,"OVERLAY",nil,10)
            ttsRptDesc:SetPoint("TOPLEFT",sCard,"TOPLEFT",35,scy)
            ttsRptDesc:SetWidth(sCard:GetWidth()-50)
            ttsRptDesc:SetJustifyH("LEFT")
            ttsRptDesc:SetText(RCL["How many extra times a reminder repeats out loud while its popup is still on screen. Zero speaks it once."])
            ttsRptDesc:SetTextColor(TEXT.gray[1],TEXT.gray[2],TEXT.gray[3])
            scy=scy-ttsRptDesc:GetStringHeight()-10

            local sndCheck = self.UI:CreateCheckbox(sCard,RCL["Play reminder sounds (global)"],self.db.soundEnabled)
            sndCheck:SetPoint("TOPLEFT",sCard,"TOPLEFT",14,scy)
            sndCheck:SetScript("OnClick",function() self.db.soundEnabled=sndCheck:GetChecked(); self:ForceCheckboxUpdate(sndCheck,self.db.soundEnabled); self:SaveConfigurationToProfile() end)
            scy=scy-26

            local sndLbl=self:CreateFontString(sCard,"OVERLAY",nil,11); sndLbl:SetPoint("TOPLEFT",sCard,"TOPLEFT",14,scy); sndLbl:SetText(RCL["Global sound:"]); sndLbl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3]); scy=scy-22

            if not self.db.soundKey  then self.db.soundKey="WR: Warning" end
            if not self.db.soundFile then self.db.soundFile="Interface\\AddOns\\Readycheck\\Media\\Sounds\\announce.ogg" end
            local sndDD=self.UI:CreateScrollableDropdown(sCard,260,ResolveSndLabelR(self.db.soundKey),10)
            sndDD:SetPoint("TOPLEFT",sCard,"TOPLEFT",14,scy)
            if sndDD.menu then sndDD.menu:SetFrameStrata("TOOLTIP"); sndDD.menu:SetFrameLevel(200) end
            local sndItems,sndFM=BuildSndItemsR()
            sndDD:SetItems(sndItems,function(key,_)
                self.db.soundKey=key; self.db.soundFile=sndFM[key] or ResolveSndFileR(key)
                self:SaveConfigurationToProfile()
                local f=self.db.soundFile; if f and f~="" then PlaySoundFile(f,"Master") end
            end)
            sndDD:SetSelectedValue(self.db.soundKey,ResolveSndLabelR(self.db.soundKey))
            scy=scy-32

            local prevSndBtn=self.UI:CreateStyledButton(sCard,RCL["Preview"],90,22); prevSndBtn:SetPoint("TOPLEFT",sCard,"TOPLEFT",14,scy)
            prevSndBtn:SetScript("OnClick",function() local f=self.db.soundFile; if f and f~="" then PlaySoundFile(f,"Master") end end)
            scy=scy-30

            local ttsVolLbl = self:CreateFontString(sCard,"OVERLAY",nil,11)
            ttsVolLbl:SetPoint("TOPLEFT",sCard,"TOPLEFT",14,scy)
            ttsVolLbl:SetText(RCL["Speech volume"])
            ttsVolLbl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3])
            scy = scy - 22
            -- Writes to db.consumablesHelper (shared TTS volume used by other
            -- features too), not a reminder-only setting.
            local ttsVol = self.db.consumablesHelper and self.db.consumablesHelper.consumableTTSVolume or 100
            local ttsVolSlider = self.UI:CreateSlider(sCard,0,100,ttsVol,5)
            ttsVolSlider:SetPoint("TOPLEFT",sCard,"TOPLEFT",14,scy)
            ttsVolSlider.Text:SetText(tostring(ttsVol))
            ttsVolSlider:SetScript("OnValueChanged",function(s,v)
                v = math.floor(v/5)*5
                s.Text:SetText(tostring(v))
                if RC.db.consumablesHelper then
                    RC.db.consumablesHelper.consumableTTSVolume = v
                end
            end)
            ttsVolSlider:SetScript("OnMouseUp",function() RC:SaveConfigurationToProfile() end)
            scy = scy - 45
            local ttsVolDesc = self:CreateFontString(sCard,"OVERLAY",nil,10)
            ttsVolDesc:SetPoint("TOPLEFT",sCard,"TOPLEFT",14,scy)
            ttsVolDesc:SetWidth(sCard:GetWidth()-30)
            ttsVolDesc:SetText(RCL["Volume of the spoken voice for every reminder, note and ready call. Pick the voice itself in the TTS Voice section below."])
            ttsVolDesc:SetTextColor(TEXT.gray[1],TEXT.gray[2],TEXT.gray[3])
            ttsVolDesc:SetJustifyH("LEFT")
            scy = scy - ttsVolDesc:GetStringHeight() - 6
            -- what only matters while its switch is on: the repeat options
            -- (already set in under the voice switch) and the speech volume
            -- follow the voice switch; the sound picker the sound switch
            self.UI:BindDependents(ttsCheck, { ttsRptLbl, rptCntSlider, ttsIntLbl, rptIntSlider, ttsRptDesc }, { indent = 0 })
            self.UI:BindDependents(ttsCheck, { ttsVolLbl, ttsVolSlider, ttsVolDesc }, { indent = 0 })
            self.UI:BindDependents(sndCheck, { sndLbl, sndDD, prevSndBtn })

            sCard:SetContentHeight(math.abs(scy))

            cy = cy - sCard:GetHeight() - 15

            local voiceCard = self:CreateSettingsCard(sndCF, cy, RCL["TTS voice"])
            local vcy = -32
            local vfNote = self:CreateFontString(voiceCard,"OVERLAY",nil,10)
            vfNote:SetPoint("TOPLEFT", voiceCard, "TOPLEFT", 14, vcy)
            vfNote:SetWidth(voiceCard:GetWidth()-30)
            vfNote:SetText(RCL["This voice speaks everything the addon says."])
            vfNote:SetTextColor(TEXT.gray[1],TEXT.gray[2],TEXT.gray[3])
            vfNote:SetJustifyH("LEFT")
            vcy = vcy - 24

            local voiceHint = self:CreateFontString(voiceCard,"OVERLAY",nil,10)
            voiceHint:SetPoint("TOPLEFT",voiceCard,"TOPLEFT",14,vcy)
            voiceHint:SetWidth(voiceCard:GetWidth()-30)
            voiceHint:SetText(RCL["Choose which voice reads your alerts. Defaults to the first female voice found on your system."])
            voiceHint:SetTextColor(TEXT.gray[1],TEXT.gray[2],TEXT.gray[3])
            voiceHint:SetJustifyH("LEFT")
            vcy = vcy - voiceHint:GetStringHeight() - 8

            local voices = RC.GetTTSVoices and RC:GetTTSVoices() or {}
            if #voices > 0 then
                local voiceItems = {}
                table.insert(voiceItems, { text = RCL["System Default"], value = "__default__" })
                local savedId = self.db.consumablesHelper and self.db.consumablesHelper.ttsVoiceId
                local selectedLabel = "System Default"
                for _, v in ipairs(voices) do
                    local k = tostring(v.voiceID)
                    table.insert(voiceItems, { text = v.name, value = k })
                    if savedId and v.voiceID == savedId then
                        selectedLabel = v.name
                    end
                end
                local vLbl = self:CreateFontString(voiceCard,"OVERLAY",nil,11)
                vLbl:SetPoint("TOPLEFT",voiceCard,"TOPLEFT",14,vcy)
                vLbl:SetText(RCL["Voice:"])
                vLbl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3])
                local vDD = self.UI:CreateScrollableDropdown(voiceCard, 200, selectedLabel, 10)
                vDD:SetPoint("TOPLEFT",vLbl,"TOPRIGHT",8,2)
                vDD:SetItems(voiceItems, function(key, label)
                    if key == "__default__" then
                        if RC.db.consumablesHelper then RC.db.consumablesHelper.ttsVoiceId = nil end
                        if RC.ApplyTTSVoice then RC:ApplyTTSVoice(nil) end
                    else
                        local id = tonumber(key)
                        if RC.db.consumablesHelper then RC.db.consumablesHelper.ttsVoiceId = id end
                        if RC.ApplyTTSVoice then RC:ApplyTTSVoice(id) end
                    end
                    RC:SaveConfigurationToProfile()
                    if RC.SpeakTTSPreview then RC:SpeakTTSPreview(RCL["Testing voice"], false) end
                end)
                vDD:SetSelectedValue(savedId and tostring(savedId) or "__default__", selectedLabel)
                vcy = vcy - 32
            else
                local noVoice = self:CreateFontString(voiceCard,"OVERLAY",nil,10)
                noVoice:SetPoint("TOPLEFT",voiceCard,"TOPLEFT",14,vcy)
                noVoice:SetText(RCL["No TTS voices available on this system."])
                noVoice:SetTextColor(TEXT.gray[1],TEXT.gray[2],TEXT.gray[3])
                vcy = vcy - 20
            end
            voiceCard:SetContentHeight(math.abs(vcy) + 5)
            cy = cy - voiceCard:GetHeight() - 15

            sndCF:SetHeight(math.abs(cy) + 20)
            frame.reminderScrollHeight["sound"] = math.abs(yPos) + math.abs(cy) + 20
        end

        local posCF = CreateFrame("Frame", nil, parent)
        posCF:SetPoint("TOPLEFT",  parent, "TOPLEFT",  0, yPos)
        posCF:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, yPos)
        do
            local cy = 0

            local testCard=self:CreateSettingsCard(posCF, cy, RCL["Test reminder"])
            local pcy=-32
            local testBtn=self.UI:CreateDynamicButton(testCard,"Show Test Reminders",26,12,80)
            testBtn:SetPoint("TOPLEFT",testCard,"TOPLEFT",14,pcy)
            local function UpdateTestBtn()
                if self.reminderFrame and self.reminderFrame:IsShown() then
                    testBtn.text:SetText(RCL["Hide Reminders"])
                else
                    testBtn.text:SetText(RCL["Show Test Reminders"])
                end
                if testBtn.UpdateWidth then testBtn:UpdateWidth() end
            end
            testBtn:SetScript("OnClick",function()
                if self.reminderFrame and self.reminderFrame:IsShown() then
                    if self.HideReminder then self:HideReminder() end
                else
                    if self.ShowTestReminder then self:ShowTestReminder(true) end
                end
                C_Timer.After(0.1,UpdateTestBtn)
            end)
            UpdateTestBtn(); pcy=pcy-26-12
            testCard:SetContentHeight(math.abs(pcy)); cy=cy-testCard:GetHeight()-15

            local posCard=self:CreateSettingsCard(posCF, cy, RCL["Position"])
            pcy=-32
            local dragCheck=self.UI:CreateCheckbox(posCard,RCL["Enable dragging"],self.db.dragEnabled)
            dragCheck:SetPoint("TOPLEFT",posCard,"TOPLEFT",14,pcy)
            dragCheck:SetScript("OnClick",function() self.db.dragEnabled=dragCheck:GetChecked(); self:ForceCheckboxUpdate(dragCheck,self.db.dragEnabled); self:SaveConfigurationToProfile() end)
            pcy=pcy-28

            local dragBtn=self.UI:CreateDynamicButton(posCard,"Show Drag Frame",26,12,80)
            dragBtn:SetPoint("TOPLEFT",posCard,"TOPLEFT",14,pcy)
            local function UpdateDragBtn()
                if self.dragTestFrame and self.dragTestFrame:IsShown() then dragBtn.text:SetText(RCL["Hide Drag Frame"]) else dragBtn.text:SetText(RCL["Show Drag Frame"]) end
                if dragBtn.UpdateWidth then dragBtn:UpdateWidth() end
            end
            dragBtn:SetScript("OnClick",function()
                if not self.db.dragEnabled then self:Print(RCL["Enable dragging first"]); return end
                if self.dragTestFrame and self.dragTestFrame:IsShown() then self:HideDragTestFrame() else self:ShowDragTestFrame() end
                UpdateDragBtn()
            end)
            UpdateDragBtn(); pcy=pcy-36
            self.UI:BindDependents(dragCheck, { dragBtn })


            local coordLbl=self:CreateFontString(posCard,"OVERLAY",nil,11); coordLbl:SetPoint("TOPLEFT",posCard,"TOPLEFT",14,pcy); coordLbl:SetText(RCL["Position (X / Y from screen center):"]); coordLbl:SetTextColor(TEXT.light[1],TEXT.light[2],TEXT.light[3]); pcy=pcy-22

            local xLbl=self:CreateFontString(posCard,"OVERLAY",nil,10); xLbl:SetPoint("TOPLEFT",posCard,"TOPLEFT",14,pcy); xLbl:SetText("X:"); xLbl:SetTextColor(TEXT.normal[1],TEXT.normal[2],TEXT.normal[3])
            -- Flat framework edit boxes (1px black ring, gold while focused) in
            -- place of InputBoxTemplate; same size, numeric-as-text behaviour.
            local xEB=self.UI:CreateBackedEditBox(posCard,{width=70,height=22,fontSize=11,insets=6}); xEB:SetPoint("LEFT",xLbl,"RIGHT",8,0); xEB:SetNumeric(false); xEB:SetText(tostring(math.floor(self.db.xOffset or 0)))
            local yLbl=self:CreateFontString(posCard,"OVERLAY",nil,10); yLbl:SetPoint("LEFT",xEB,"RIGHT",20,0); yLbl:SetText("Y:"); yLbl:SetTextColor(TEXT.normal[1],TEXT.normal[2],TEXT.normal[3])
            local yEB=self.UI:CreateBackedEditBox(posCard,{width=70,height=22,fontSize=11,insets=6}); yEB:SetPoint("LEFT",yLbl,"RIGHT",8,0); yEB:SetNumeric(false); yEB:SetText(tostring(math.floor(self.db.yOffset or 200)))
            local applyBtn=self.UI:CreateDynamicButton(posCard,RCL["Apply Position"],22,10,50); applyBtn:SetPoint("LEFT",yEB,"RIGHT",12,0)
            applyBtn:SetScript("OnClick",function()
                local xv=tonumber(xEB:GetText()) or 0; local yv=tonumber(yEB:GetText()) or 200
                self:SaveReminderFramePosition(xv, yv)
                self:SyncReminderPositionUI()
            end)
            xEB:SetScript("OnEnterPressed",function() applyBtn:Click(); xEB:ClearFocus() end)
            yEB:SetScript("OnEnterPressed",function() applyBtn:Click(); yEB:ClearFocus() end)
            self.positionEditBoxes={xEditBox=xEB,yEditBox=yEB}
            pcy=pcy-35

            posCard:SetContentHeight(math.abs(pcy)); cy=cy-posCard:GetHeight()-15

            -- the parts inside each icon, and how the icons line up
            local partCard=self:CreateSettingsCard(posCF, cy, RCL["Parts"])
            pcy=-32
            local gg,gs=self.UI:CustomAccess(PopupRoot,"anchors","glow",PopupChanged)
            local ge=self.UI:CreateFrameElement(partCard,{ label=RCL["Glow"], key="glow", width=CardW(partCard),
                anchorGet=gg, anchorSet=gs, targets=PopupTargets("glow"),
                defaultTargetLabel=RCL["Around the icon"],
                anchorDefaults=function() return RC.REMINDER_GLOW_ANCHOR end })
            ge:SetPoint("TOPLEFT",partCard,"TOPLEFT",14,pcy)
            pcy=pcy-ge:GetHeight()-8
            pcy=RC.UI:CreateHelpLine(partCard,14,pcy,RCL["The icon text has its place on the Text tab. Reset puts a part back where it always sat."])
            partCard:SetContentHeight(math.abs(pcy)+6); cy=cy-partCard:GetHeight()-15

            local layCard=self:CreateSettingsCard(posCF, cy, RCL["Icon layout"])
            pcy=-32
            local lg,ls=self.UI:CustomAccess(PopupRoot,"layout",nil,PopupChanged)
            local lp=self.UI:CreateLayoutPicker(layCard,{ width=CardW(layCard), get=lg, set=ls,
                defaults=function() return RC:ReminderLayoutDefaults() end,
                fields={ grow=true, wrap=true, perLine=true, spacingX=true, spacingY=true, max=true, reverse=true },
                grows={ "CENTER", "RIGHT", "LEFT", "DOWN", "UP" }, maxItems=10 })
            lp:SetPoint("TOPLEFT",layCard,"TOPLEFT",14,pcy)
            pcy=pcy-lp:GetHeight()-8
            pcy=RC.UI:CreateHelpLine(layCard,14,pcy,RCL["Default: one row from the middle, the icon spacing from the Look tab apart."])
            layCard:SetContentHeight(math.abs(pcy)+6); cy=cy-layCard:GetHeight()-15

            cy = self.UI:FrameLayerCard(posCF, cy, PopupRoot, PopupChanged, { title = RCL["Popup layer and scale"] })

            posCF:SetHeight(math.abs(cy) + 20)
            frame.reminderScrollHeight["position"] = math.abs(yPos) + math.abs(cy) + 20
        end

        frame.reminderTabCache = {
            behavior  = behCF,
            look      = lookCF,
            text      = textCF,
            animation = animCF,
            sound     = sndCF,
            position  = posCF,
        }
        for k, cf in pairs(frame.reminderTabCache) do
            if k == selectedTab then cf:Show() else cf:Hide() end
        end

        if self.UpdateSidebarScrollbar then
            self:UpdateSidebarScrollbar(self.sidebarConfigFrame,
                frame.reminderScrollHeight[selectedTab] or 400)
        end
    end

